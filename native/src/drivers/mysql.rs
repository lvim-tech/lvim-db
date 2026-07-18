// lvim-db-native/drivers/mysql: the MySQL / MariaDB driver.
//
// One impl serves both the `mariadb` and `mysql` registry kinds — the wire
// protocol is the same; they differ only in display/defaults. Values come back
// through mysql_async's typed Value and are rendered as text (bytes decoded as
// UTF-8 when they are, else base64) so every column shows in the grid. Query
// cancellation is a `KILL QUERY <conn-id>` issued on a SEPARATE connection, so a
// running statement can be stopped while its own connection is busy.

use async_trait::async_trait;
use base64::Engine as _;
use mysql_async::prelude::*;
use mysql_async::{Conn, Opts, OptsBuilder, Row};

use crate::driver::{CancelHandle, Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column, ConnSpec, DriverMeta, Index, Node, ObjRef, ParamSpec, ParamType, TableColumn,
    Value,
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
        default: Some("3306"),
    },
    ParamSpec {
        key: "database",
        label: "Database",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: None,
    },
];

const AUTH: &[AuthKind] = &[AuthKind::None, AuthKind::Password, AuthKind::ClientCert];

const CAPS: Caps = Caps {
    sql: true,
    schemas: true,
    cancel: true,
    tls: true,
    tunnel: true,
    multi_db: true,
    kv: false,
    indexes: true,
    ddl: true, // information_schema.STATISTICS / SHOW CREATE TABLE
};

const MARIADB_META: DriverMeta = DriverMeta {
    kind: "mariadb",
    display: "MariaDB",
    default_port: Some(3306),
    params: PARAMS,
    auth: AUTH,
    caps: CAPS,
};

const MYSQL_META: DriverMeta = DriverMeta {
    kind: "mysql",
    display: "MySQL",
    default_port: Some(3306),
    params: PARAMS,
    auth: AUTH,
    caps: CAPS,
};

/// The MySQL-wire driver, serving both the `mariadb` and `mysql` kinds.
pub struct MysqlDriver {
    meta: &'static DriverMeta,
}

impl MysqlDriver {
    #[cfg(feature = "mariadb")]
    pub fn mariadb() -> Self {
        Self { meta: &MARIADB_META }
    }

    #[cfg(feature = "mysql")]
    pub fn mysql() -> Self {
        Self { meta: &MYSQL_META }
    }
}

/// Derive (user, password) from a spec's auth, resolving the password template.
async fn credentials(spec: &ConnSpec) -> anyhow::Result<(String, Option<String>)> {
    match &spec.auth {
        AuthSpec::Password { user, password } => Ok((user.clone(), Some(password.resolve().await?))),
        AuthSpec::ClientCert { user, .. } => Ok((user.clone(), None)),
        _ => Ok((spec.param_opt("user").unwrap_or("root").to_string(), None)),
    }
}

/// Build mysql_async SslOpts from a TlsSpec (rustls under the hood): root CA /
/// accept-any + hostname skip per mode, and a client identity for mutual X.509.
fn ssl_opts_for(tls: &crate::spec::TlsSpec) -> mysql_async::SslOpts {
    let mut ssl = mysql_async::SslOpts::default()
        .with_danger_accept_invalid_certs(!tls.verifies_cert())
        .with_danger_skip_domain_validation(!tls.verifies_hostname());
    if let Some(ca) = &tls.ca {
        ssl = ssl.with_root_certs(vec![std::path::PathBuf::from(ca).into()]);
    }
    if let (Some(cert), Some(key)) = (&tls.client_cert, &tls.client_key) {
        ssl = ssl.with_client_identity(Some(mysql_async::ClientIdentity::new(
            std::path::PathBuf::from(cert).into(),
            std::path::PathBuf::from(key).into(),
        )));
    }
    ssl
}

/// Build mysql_async Opts for `spec`, dialing through `net`. `with_tls` decides
/// whether the built opts negotiate TLS (used for the prefer/require attempts).
async fn build_opts(spec: &ConnSpec, net: &NetContext, with_tls: bool) -> anyhow::Result<Opts> {
    let host = spec.param("host")?;
    let port = spec.port(3306);
    let (user, password) = credentials(spec).await?;

    let addr = net.resolve(host, port).await?;
    let (rhost, rport) = addr
        .rsplit_once(':')
        .ok_or_else(|| anyhow::anyhow!("net resolved a malformed address"))?;

    let mut b = OptsBuilder::default()
        .ip_or_hostname(rhost.to_string())
        .tcp_port(rport.parse().unwrap_or(port))
        .user(if user.is_empty() { None } else { Some(user) })
        .pass(password);
    if let Some(db) = spec.param_opt("database") {
        b = b.db_name(Some(db.to_string()));
    }
    b = b.ssl_opts(if with_tls { Some(ssl_opts_for(&spec.tls)) } else { None });
    Ok(Opts::from(b))
}

/// Convert one mysql_async Value into our text-first cell Value.
fn cell(v: &mysql_async::Value) -> Value {
    use mysql_async::Value as V;
    match v {
        V::NULL => Value::Null,
        V::Int(i) => Value::Int(*i),
        V::UInt(u) => {
            if *u <= i64::MAX as u64 {
                Value::Int(*u as i64)
            } else {
                Value::Text(u.to_string())
            }
        }
        V::Float(f) => Value::Float(*f as f64),
        V::Double(d) => Value::Float(*d),
        V::Bytes(b) => match std::str::from_utf8(b) {
            Ok(s) => Value::Text(s.to_string()),
            Err(_) => Value::Bytes {
                b64: base64::engine::general_purpose::STANDARD.encode(b),
                len: b.len(),
            },
        },
        // Dates/times come back as their MySQL text form.
        other => Value::Text(other.as_sql(true).trim_matches('\'').to_string()),
    }
}

#[async_trait]
impl Driver for MysqlDriver {
    fn meta(&self) -> &'static DriverMeta {
        self.meta
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let tls = &spec.tls;
        // Explicit opt-out → plaintext.
        if !tls.wanted() {
            let opts = build_opts(spec, &net, false).await?;
            let conn = Conn::new(opts.clone())
                .await
                .map_err(|e| anyhow::anyhow!("mysql connect failed: {e}"))?;
            return Ok(Box::new(MysqlConnection {
                conn,
                opts,
                encrypted: false,
            }));
        }
        // Encrypted attempt.
        let opts = build_opts(spec, &net, true).await?;
        match Conn::new(opts.clone()).await {
            Ok(conn) => Ok(Box::new(MysqlConnection {
                conn,
                opts,
                encrypted: true,
            })),
            Err(e) => {
                if tls.required() {
                    Err(anyhow::anyhow!(
                        "mysql: TLS is required but the server did not accept it: {e}"
                    ))
                } else {
                    // Prefer: fall back to plaintext (surfaced via encrypted=false).
                    let opts = build_opts(spec, &net, false).await?;
                    let conn = Conn::new(opts.clone())
                        .await
                        .map_err(|e| anyhow::anyhow!("mysql connect failed: {e}"))?;
                    Ok(Box::new(MysqlConnection {
                        conn,
                        opts,
                        encrypted: false,
                    }))
                }
            }
        }
    }
}

/// A live MySQL/MariaDB connection. Keeps its Opts so the cancel handle can open
/// a second connection to KILL the running query.
struct MysqlConnection {
    conn: Conn,
    opts: Opts,
    encrypted: bool,
}

impl MysqlConnection {
    /// Run a statement, collecting text-rendered rows + columns + affected count.
    async fn run(&mut self, sql: &str) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>, Option<u64>)> {
        let mut result = self.conn.query_iter(sql).await.map_err(|e| anyhow::anyhow!("{e}"))?;

        let mut columns: Vec<Column> = Vec::new();
        if let Some(cols) = result.columns() {
            columns = cols
                .iter()
                .map(|c| Column {
                    name: c.name_str().to_string(),
                    type_name: format!("{:?}", c.column_type()),
                })
                .collect();
        }
        let rows: Vec<Row> = result.collect().await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let affected = result.affected_rows();

        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            let mut r = Vec::with_capacity(row.len());
            for i in 0..row.len() {
                let v = row.as_ref(i).cloned().unwrap_or(mysql_async::Value::NULL);
                r.push(cell(&v));
            }
            out.push(r);
        }
        let affected = if out.is_empty() { Some(affected) } else { None };
        Ok((columns, out, affected))
    }
}

#[async_trait]
impl Connection for MysqlConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        let (_c, rows, _a) = self
            .run("SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")
            .await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| match r.into_iter().next() {
                Some(Value::Text(s)) => Some(s),
                _ => None,
            })
            .collect())
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.conn
            .query_drop(format!("USE `{}`", db.replace('`', "``")))
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        // Group tables/views under their schema (database), excluding the system schemas.
        let (_c, rows, _a) = self
            .run(
                "SELECT table_schema, table_name, table_type \
                 FROM information_schema.tables \
                 WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') \
                 ORDER BY table_schema, table_name",
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
        // COLUMN_KEY = 'PRI' is mysql's own per-column primary-key marker.
        let schema_pred = match &obj.schema {
            Some(s) => format!("AND table_schema = '{}'", s.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT column_name, column_type, IF(column_key = 'PRI', 1, 0) \
             FROM information_schema.columns \
             WHERE table_name = '{}' {} ORDER BY ordinal_position",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows, _a) = self.run(&sql).await?;
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
                primary: match r.get(2) {
                    Some(Value::Int(i)) => *i != 0,
                    Some(Value::Text(s)) => s == "1",
                    _ => false,
                },
            })
            .collect())
    }
    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // information_schema.STATISTICS yields one row per index COLUMN in SEQ_IN_INDEX order — the shape
        // `group_indexes` folds. NON_UNIQUE is inverted (0 = unique), and mysql has no is_primary column:
        // the primary-key index is the one it always names "PRIMARY".
        let schema_pred = match &obj.schema {
            Some(sc) => format!(" AND TABLE_SCHEMA = '{}'", sc.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT INDEX_NAME, IF(NON_UNIQUE = 0, 1, 0), IF(INDEX_NAME = 'PRIMARY', 1, 0), COLUMN_NAME \
             FROM information_schema.STATISTICS \
             WHERE TABLE_NAME = '{}'{} ORDER BY INDEX_NAME, SEQ_IN_INDEX",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows, _a) = self.run(&sql).await?;
        Ok(super::group_indexes(rows))
    }

    async fn ddl(&mut self, obj: &ObjRef) -> anyhow::Result<Option<String>> {
        // SHOW CREATE is the server's own answer; the statement is column 1. A view answers only to
        // SHOW CREATE VIEW, so both are tried rather than assuming the object's kind.
        let qname = match &obj.schema {
            Some(sc) => format!("`{}`.`{}`", sc.replace('`', "``"), obj.name.replace('`', "``")),
            None => format!("`{}`", obj.name.replace('`', "``")),
        };
        for kind in ["TABLE", "VIEW"] {
            if let Ok((_c, rows, _a)) = self.run(&format!("SHOW CREATE {kind} {qname}")).await {
                if let Some(Value::Text(s)) = rows.first().and_then(|r| r.get(1)) {
                    return Ok(Some(s.clone()));
                }
            }
        }
        Ok(None)
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows, affected) = self.run(stmt).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, affected)))
    }

    fn cancel_token(&self) -> Option<Box<dyn CancelHandle>> {
        Some(Box::new(MysqlCancel {
            opts: self.opts.clone(),
            conn_id: self.conn.id(),
        }))
    }

    fn encrypted(&self) -> bool {
        self.encrypted
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        let _ = self.conn.disconnect().await;
        Ok(())
    }
}

/// MySQL cancel: `KILL QUERY <id>` on a fresh connection (the busy one can't take it).
struct MysqlCancel {
    opts: Opts,
    conn_id: u32,
}

#[async_trait]
impl CancelHandle for MysqlCancel {
    async fn cancel(&self) -> anyhow::Result<()> {
        let mut c = Conn::new(self.opts.clone())
            .await
            .map_err(|e| anyhow::anyhow!("cancel connect failed: {e}"))?;
        let r = c
            .query_drop(format!("KILL QUERY {}", self.conn_id))
            .await
            .map_err(|e| anyhow::anyhow!("cancel failed: {e}"));
        let _ = c.disconnect().await;
        r
    }
}
