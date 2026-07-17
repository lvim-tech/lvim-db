// lvim-db-native/drivers/mssql: the Microsoft SQL Server driver (TDS, tiberius).
//
// tiberius is runtime-agnostic; a tokio TcpStream is adapted to its futures-io
// with tokio-util's compat shim. Cells are rendered text-first by trying the
// common FromSql conversions in order (the generic, always-available `try_get`
// API), so any column shows without a per-type match on tiberius's internal
// ColumnData. NOTE: implemented and compile-checked, but NOT runtime-verified in
// this build environment (no SQL Server instance was available).

use async_trait::async_trait;
use base64::Engine as _;
use tiberius::{AuthMethod, Client, Config};
use tokio::net::TcpStream;
use tokio_util::compat::{Compat, TokioAsyncWriteCompatExt};

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column, ConnSpec, DriverMeta, Index, Node, ObjRef, TableColumn, ParamSpec, ParamType, Value,
};

const PARAMS: &[ParamSpec] = &[
    ParamSpec {
        key: "host",
        label: "Host",
        kind: ParamType::String,
        required: true,
        secret: false,
        default: Some("127.0.0.1"),
    },
    ParamSpec {
        key: "port",
        label: "Port",
        kind: ParamType::Int,
        required: false,
        secret: false,
        default: Some("1433"),
    },
    ParamSpec {
        key: "database",
        label: "Database",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: Some("master"),
    },
];

const META: DriverMeta = DriverMeta {
    kind: "sqlserver",
    display: "SQL Server",
    default_port: Some(1433),
    params: PARAMS,
    auth: &[AuthKind::Password],
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false,
        tls: true,
        tunnel: true,
        multi_db: true,
        kv: false,
        indexes: true,
        ddl: false, // sys.indexes; SQL Server scripts CREATE client-side (SSMS), no server command
    },
};

/// The SQL Server driver.
pub struct MssqlDriver;

impl MssqlDriver {
    pub fn new() -> Self {
        MssqlDriver
    }
}

#[async_trait]
impl Driver for MssqlDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let host = spec.param("host")?;
        let port = spec.port(1433);
        let addr = net.resolve(host, port).await?;
        let (rhost, rport) = addr
            .rsplit_once(':')
            .ok_or_else(|| anyhow::anyhow!("net resolved a malformed address"))?;

        let (user, password) = match &spec.auth {
            AuthSpec::Password { user, password } => (user.clone(), password.resolve().await?),
            _ => return Err(anyhow::anyhow!("SQL Server requires password authentication")),
        };

        let mut config = Config::new();
        config.host(rhost);
        config.port(rport.parse().unwrap_or(port));
        config.authentication(AuthMethod::sql_server(&user, &password));
        if let Some(db) = spec.param_opt("database") {
            config.database(db);
        }
        // Encryption posture (tiberius/rustls). Required modes mandate it;
        // Disable turns it off; the verify modes pin a CA (else trust-any).
        let tls = &spec.tls;
        config.encryption(match tls.mode {
            crate::spec::TlsMode::Disable => tiberius::EncryptionLevel::Off,
            crate::spec::TlsMode::Prefer => tiberius::EncryptionLevel::On,
            _ => tiberius::EncryptionLevel::Required,
        });
        if tls.verifies_cert() {
            if let Some(ca) = &tls.ca {
                config.trust_cert_ca(ca);
            }
        } else {
            config.trust_cert();
        }
        let encrypted = tls.wanted();

        let tcp = TcpStream::connect(config.get_addr())
            .await
            .map_err(|e| anyhow::anyhow!("sqlserver tcp connect failed: {e}"))?;
        tcp.set_nodelay(true).ok();
        let client = Client::connect(config, tcp.compat_write())
            .await
            .map_err(|e| anyhow::anyhow!("sqlserver connect failed: {e}"))?;
        Ok(Box::new(MssqlConnection { client, encrypted }))
    }
}

/// A live SQL Server connection.
struct MssqlConnection {
    client: Client<Compat<TcpStream>>,
    encrypted: bool,
}

/// Render one cell by trying the common FromSql conversions in order.
fn render_cell(row: &tiberius::Row, i: usize) -> Value {
    if let Ok(Some(v)) = row.try_get::<i32, _>(i) {
        return Value::Int(v as i64);
    }
    if let Ok(Some(v)) = row.try_get::<i64, _>(i) {
        return Value::Int(v);
    }
    if let Ok(Some(v)) = row.try_get::<f64, _>(i) {
        return Value::Float(v);
    }
    if let Ok(Some(v)) = row.try_get::<bool, _>(i) {
        return Value::Bool(v);
    }
    if let Ok(Some(v)) = row.try_get::<&str, _>(i) {
        return Value::Text(v.to_string());
    }
    if let Ok(Some(v)) = row.try_get::<chrono::NaiveDateTime, _>(i) {
        return Value::Timestamp(v.to_string());
    }
    if let Ok(Some(v)) = row.try_get::<&[u8], _>(i) {
        return Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(v),
            len: v.len(),
        };
    }
    Value::Null
}

impl MssqlConnection {
    async fn run(&mut self, sql: &str) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>)> {
        let stream = self.client.query(sql, &[]).await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let rows = stream.into_first_result().await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let mut columns = Vec::new();
        if let Some(r0) = rows.first() {
            columns = r0
                .columns()
                .iter()
                .map(|c| Column {
                    name: c.name().to_string(),
                    type_name: format!("{:?}", c.column_type()),
                })
                .collect();
        }
        let ncol = columns.len();
        let out = rows
            .iter()
            .map(|r| (0..ncol).map(|i| render_cell(r, i)).collect())
            .collect();
        Ok((columns, out))
    }
}

#[async_trait]
impl Connection for MssqlConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        let (_c, rows) = self.run("SELECT name FROM sys.databases ORDER BY name").await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| match r.into_iter().next() {
                Some(Value::Text(s)) => Some(s),
                _ => None,
            })
            .collect())
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.client
            .execute(format!("USE [{}]", db.replace(']', "]]")), &[])
            .await
            .map(|_| ())
            .map_err(|e| anyhow::anyhow!("{e}"))
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows) = self
            .run(
                "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES \
                 ORDER BY TABLE_SCHEMA, TABLE_NAME",
            )
            .await?;
        let mut schemas: Vec<Node> = Vec::new();
        for r in rows {
            let get = |i: usize| match r.get(i) {
                Some(Value::Text(s)) => s.clone(),
                _ => String::new(),
            };
            let schema = get(0);
            let name = get(1);
            let ttype = get(2);
            let kind = if ttype.to_uppercase().contains("VIEW") {
                "view"
            } else {
                "table"
            };
            let node = Node {
                name,
                kind: kind.to_string(),
                schema: Some(schema.clone()),
                children: Vec::new(),
            };
            match schemas.iter_mut().find(|s| s.name == schema) {
                Some(s) => s.children.push(node),
                None => schemas.push(Node {
                    name: schema.clone(),
                    kind: "schema".to_string(),
                    schema: None,
                    children: vec![node],
                }),
            }
        }
        Ok(schemas)
    }

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<TableColumn>> {
        // The primary flag comes from sys.indexes/index_columns: INFORMATION_SCHEMA.COLUMNS has no key info.
        let schema_pred = match &obj.schema {
            Some(s) => format!("AND s.name = '{}'", s.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT c.name, TYPE_NAME(c.user_type_id), \
                    CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END \
             FROM sys.columns c \
             JOIN sys.tables t ON t.object_id = c.object_id \
             JOIN sys.schemas s ON s.schema_id = t.schema_id \
             LEFT JOIN ( \
               SELECT ic.object_id, ic.column_id FROM sys.index_columns ic \
               JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id \
               WHERE i.is_primary_key = 1 \
             ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id \
             WHERE t.name = '{}' {} ORDER BY c.column_id",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows) = self.run(&sql).await?;
        Ok(rows
            .into_iter()
            .map(|r| TableColumn {
                name: match r.first() {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
                type_name: match r.get(1) {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
                primary: matches!(r.get(2), Some(Value::Int(i)) if *i != 0),
            })
            .collect())
    }
    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // sys.index_columns is the per-column table, ordered by key_ordinal — the fold shape. A heap has an
        // unnamed index_id 0 row, which is not an index and is excluded.
        let schema_pred = match &obj.schema {
            Some(sc) => format!("AND s.name = '{}'", sc.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT i.name, CAST(i.is_unique AS INT), CAST(i.is_primary_key AS INT), c.name \
             FROM sys.indexes i \
             JOIN sys.tables t ON t.object_id = i.object_id \
             JOIN sys.schemas s ON s.schema_id = t.schema_id \
             LEFT JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id \
             LEFT JOIN sys.columns c ON c.object_id = i.object_id AND c.column_id = ic.column_id \
             WHERE t.name = '{}' {} AND i.name IS NOT NULL \
             ORDER BY i.name, ic.key_ordinal",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows) = self.run(&sql).await?;
        Ok(super::group_indexes(rows))
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows) = self.run(stmt).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, None)))
    }

    fn encrypted(&self) -> bool {
        self.encrypted
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
