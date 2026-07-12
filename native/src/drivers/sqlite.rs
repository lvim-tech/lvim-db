// lvim-db-native/drivers/sqlite: the SQLite driver.
//
// SQLite is an embedded, SYNCHRONOUS engine (a C library), so every operation
// runs on `spawn_blocking` — off the async runtime's worker threads — while the
// same async trait the network drivers use is preserved. The connection is a
// file path (":memory:" for an in-memory database); there is no host/port/auth.
// Values come back through rusqlite's owned Value and render as text.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use base64::Engine as _;
use rusqlite::types::Value as SqlValue;
use rusqlite::Connection as SqliteConn;

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{AuthKind, Caps, Column, ConnSpec, DriverMeta, Node, ObjRef, ParamSpec, ParamType, Value};

const PARAMS: &[ParamSpec] = &[ParamSpec {
    key: "file",
    label: "Database file",
    kind: ParamType::File,
    required: true,
    secret: false,
    default: Some(":memory:"),
}];

const META: DriverMeta = DriverMeta {
    kind: "sqlite",
    display: "SQLite",
    default_port: None,
    params: PARAMS,
    auth: &[AuthKind::None],
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false, // embedded + fast; no async cancel channel
        tls: false,
        tunnel: false,
        multi_db: false,
        kv: false,
    },
};

/// The SQLite driver.
pub struct SqliteDriver;

impl SqliteDriver {
    pub fn new() -> Self {
        SqliteDriver
    }
}

#[async_trait]
impl Driver for SqliteDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(&self, spec: &ConnSpec, _net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let file = spec.param("file")?.to_string();
        let conn = tokio::task::spawn_blocking(move || {
            if file == ":memory:" {
                SqliteConn::open_in_memory()
            } else {
                SqliteConn::open(&file)
            }
        })
        .await?
        .map_err(|e| anyhow::anyhow!("sqlite open failed: {e}"))?;
        Ok(Box::new(SqliteConnection {
            conn: Arc::new(Mutex::new(conn)),
        }))
    }
}

/// Convert an owned rusqlite Value to our text-first cell Value.
fn cell(v: SqlValue) -> Value {
    match v {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(i) => Value::Int(i),
        SqlValue::Real(f) => Value::Float(f),
        SqlValue::Text(s) => Value::Text(s),
        SqlValue::Blob(b) => Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(&b),
            len: b.len(),
        },
    }
}

/// A live SQLite connection. The engine is behind a mutex so blocking calls run
/// on spawn_blocking with a 'static handle.
struct SqliteConnection {
    conn: Arc<Mutex<SqliteConn>>,
}

impl SqliteConnection {
    /// Run one statement on a blocking thread. A statement that returns no columns
    /// (DDL/DML) reports its changed-row count as `affected`.
    async fn run(&self, sql: String) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>, Option<u64>)> {
        let arc = self.conn.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
            let conn = arc.lock().unwrap();
            let mut stmt = conn.prepare(&sql).map_err(|e| anyhow::anyhow!("{e}"))?;
            let ncol = stmt.column_count();
            if ncol == 0 {
                let affected = stmt.execute([]).map_err(|e| anyhow::anyhow!("{e}"))?;
                return Ok((Vec::new(), Vec::new(), Some(affected as u64)));
            }
            let columns: Vec<Column> = stmt
                .column_names()
                .into_iter()
                .map(|n| Column {
                    name: n.to_string(),
                    type_name: String::new(),
                })
                .collect();
            let mut out: Vec<Vec<Value>> = Vec::new();
            let mut rows = stmt.query([]).map_err(|e| anyhow::anyhow!("{e}"))?;
            while let Some(r) = rows.next().map_err(|e| anyhow::anyhow!("{e}"))? {
                let mut row = Vec::with_capacity(ncol);
                for i in 0..ncol {
                    let v: SqlValue = r.get(i).map_err(|e| anyhow::anyhow!("{e}"))?;
                    row.push(cell(v));
                }
                out.push(row);
            }
            Ok((columns, out, None))
        })
        .await?
    }
}

#[async_trait]
impl Connection for SqliteConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        let (_c, rows, _a) = self.run("PRAGMA database_list".to_string()).await?;
        // PRAGMA database_list → (seq, name, file); the name is column 1.
        Ok(rows
            .into_iter()
            .filter_map(|r| match r.get(1) {
                Some(Value::Text(s)) => Some(s.clone()),
                _ => None,
            })
            .collect())
    }

    async fn switch_database(&mut self, _db: &str) -> anyhow::Result<()> {
        Err(anyhow::anyhow!("SQLite has a single database per connection"))
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows, _a) = self
            .run(
                "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') \
                 AND name NOT LIKE 'sqlite_%' ORDER BY name"
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
                let kind = match r.get(1) {
                    Some(Value::Text(s)) if s == "view" => "view",
                    _ => "table",
                };
                Node {
                    name,
                    kind: kind.to_string(),
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

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Column>> {
        let sql = format!("PRAGMA table_info('{}')", obj.name.replace('\'', "''"));
        let (_c, rows, _a) = self.run(sql).await?;
        // table_info → (cid, name, type, notnull, dflt, pk); name=1, type=2.
        Ok(rows
            .into_iter()
            .map(|r| Column {
                name: match r.get(1) {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
                type_name: match r.get(2) {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
            })
            .collect())
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows, affected) = self.run(stmt.to_string()).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, affected)))
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
