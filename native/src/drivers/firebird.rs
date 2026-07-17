// lvim-db-native/drivers/firebird: the Firebird driver (rsfbclient, pure-Rust).
//
// Uses rsfbclient's PURE-RUST wire-protocol backend (no libfbclient at runtime),
// so it stays in the self-contained standard build; the native-client backend is
// the opt-in `firebird-native` feature. rsfbclient is synchronous, so every call
// runs on `spawn_blocking` behind the async trait. NOTE: implemented and
// compile-checked, but NOT runtime-verified in this build environment (no
// Firebird server was available).

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use base64::Engine as _;
use rsfbclient::{Column, Queryable, Row, SimpleConnection, SqlType};

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column as SpecColumn, ConnSpec, DriverMeta, Index, Node, ObjRef,
    ParamSpec, ParamType, Value,
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
        default: Some("3050"),
    },
    ParamSpec {
        key: "database",
        label: "Database path",
        kind: ParamType::String,
        required: true,
        secret: false,
        default: None,
    },
];

const META: DriverMeta = DriverMeta {
    kind: "firebird",
    display: "Firebird",
    default_port: Some(3050),
    params: PARAMS,
    auth: &[AuthKind::Password],
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false,
        tls: false,
        tunnel: true,
        multi_db: false,
        kv: false,
        indexes: true,
        ddl: false, // RDB$INDICES; Firebird has no server-side CREATE statement
    },
};

/// The Firebird driver.
pub struct FirebirdDriver;

impl FirebirdDriver {
    pub fn new() -> Self {
        FirebirdDriver
    }
}

#[async_trait]
impl Driver for FirebirdDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(
        &self,
        spec: &ConnSpec,
        net: NetContext,
    ) -> anyhow::Result<Box<dyn Connection>> {
        let host = spec.param("host")?.to_string();
        let port = spec.port(3050);
        let db = spec.param("database")?.to_string();
        let addr = net.resolve(&host, port).await?;
        let (rhost, rport) = addr
            .rsplit_once(':')
            .map(|(h, p)| (h.to_string(), p.parse().unwrap_or(port)))
            .unwrap_or((host.clone(), port));
        let (user, password) = match &spec.auth {
            AuthSpec::Password { user, password } => (
                if user.is_empty() {
                    "SYSDBA".to_string()
                } else {
                    user.clone()
                },
                password.resolve().await?,
            ),
            _ => ("SYSDBA".to_string(), String::new()),
        };

        let conn: SimpleConnection = tokio::task::spawn_blocking(move || {
            rsfbclient::builder_pure_rust()
                .host(rhost)
                .port(rport)
                .db_name(db)
                .user(user)
                .pass(password)
                .connect()
                .map(SimpleConnection::from)
        })
        .await?
        .map_err(|e| anyhow::anyhow!("firebird connect failed: {e}"))?;

        Ok(Box::new(FirebirdConnection {
            conn: Arc::new(Mutex::new(conn)),
        }))
    }
}

/// Convert one rsfbclient Column to our text-first cell Value (matching its
/// public SqlType value directly).
fn cell(col: &Column) -> Value {
    match &col.value {
        SqlType::Null => Value::Null,
        SqlType::Text(t) => Value::Text(t.clone()),
        SqlType::Integer(i) => Value::Int(*i),
        SqlType::Floating(f) => Value::Float(*f),
        SqlType::Boolean(b) => Value::Bool(*b),
        SqlType::Timestamp(ts) => Value::Timestamp(ts.to_string()),
        SqlType::Binary(b) => Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(b),
            len: b.len(),
        },
    }
}

/// A live Firebird connection (synchronous engine behind a mutex; driven on
/// spawn_blocking with a 'static handle).
struct FirebirdConnection {
    conn: Arc<Mutex<SimpleConnection>>,
}

impl FirebirdConnection {
    async fn run(&self, sql: String) -> anyhow::Result<(Vec<SpecColumn>, Vec<Vec<Value>>)> {
        let arc = self.conn.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
            let mut conn = arc.lock().unwrap();
            let rows: Vec<Row> = conn.query(&sql, ()).map_err(|e| anyhow::anyhow!("{e}"))?;
            let mut columns: Vec<SpecColumn> = Vec::new();
            let mut out: Vec<Vec<Value>> = Vec::new();
            for row in &rows {
                if columns.is_empty() {
                    columns = row
                        .cols
                        .iter()
                        .map(|c| SpecColumn {
                            name: c.name.clone(),
                            type_name: String::new(),
                        })
                        .collect();
                }
                out.push(row.cols.iter().map(cell).collect());
            }
            Ok((columns, out))
        })
        .await?
    }
}

#[async_trait]
impl Connection for FirebirdConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        // Firebird has one database per connection.
        Ok(vec!["main".to_string()])
    }

    async fn switch_database(&mut self, _db: &str) -> anyhow::Result<()> {
        Err(anyhow::anyhow!(
            "Firebird has a single database per connection"
        ))
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows) = self
            .run(
                "SELECT TRIM(RDB$RELATION_NAME), RDB$VIEW_BLR FROM RDB$RELATIONS \
                 WHERE RDB$SYSTEM_FLAG = 0 ORDER BY RDB$RELATION_NAME"
                    .to_string(),
            )
            .await?;
        let children = rows
            .into_iter()
            .map(|r| {
                let name = match r.first() {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                };
                // RDB$VIEW_BLR non-null ⇒ a view.
                let is_view = !matches!(r.get(1), Some(Value::Null) | None);
                Node {
                    name,
                    kind: if is_view { "view" } else { "table" }.to_string(),
                    schema: Some("main".to_string()),
                    children: Vec::new(),
                }
            })
            .collect();
        Ok(vec![Node {
            name: "main".to_string(),
            kind: "schema".to_string(),
            schema: None,
            children,
        }])
    }

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<SpecColumn>> {
        let sql = format!(
            "SELECT TRIM(RF.RDB$FIELD_NAME) FROM RDB$RELATION_FIELDS RF \
             WHERE RF.RDB$RELATION_NAME = '{}' ORDER BY RF.RDB$FIELD_POSITION",
            obj.name.to_uppercase().replace('\'', "''")
        );
        let (_c, rows) = self.run(sql).await?;
        Ok(rows
            .into_iter()
            .map(|r| SpecColumn {
                name: match r.first() {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
                type_name: String::new(),
            })
            .collect())
    }

    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // RDB$INDEX_SEGMENTS is the per-column table ordered by RDB$FIELD_POSITION — the fold shape.
        // Firebird pads catalog CHAR columns, so every name is TRIMmed. A primary key is read from
        // RDB$RELATION_CONSTRAINTS rather than guessed out of the index name.
        let sql = format!(
            "SELECT TRIM(i.RDB$INDEX_NAME), COALESCE(i.RDB$UNIQUE_FLAG, 0), \
                    CASE WHEN rc.RDB$CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 1 ELSE 0 END, \
                    TRIM(s.RDB$FIELD_NAME) \
             FROM RDB$INDICES i \
             LEFT JOIN RDB$INDEX_SEGMENTS s ON s.RDB$INDEX_NAME = i.RDB$INDEX_NAME \
             LEFT JOIN RDB$RELATION_CONSTRAINTS rc ON rc.RDB$INDEX_NAME = i.RDB$INDEX_NAME \
             WHERE TRIM(i.RDB$RELATION_NAME) = '{}' \
             ORDER BY i.RDB$INDEX_NAME, s.RDB$FIELD_POSITION",
            obj.name.replace('\'', "''")
        );
        let (_c, rows) = self.run(sql).await?;
        Ok(super::group_indexes(rows))
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows) = self.run(stmt.to_string()).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(
            columns, rows, None,
        )))
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
