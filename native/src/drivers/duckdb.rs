// lvim-db-native/drivers/duckdb: the DuckDB driver.
//
// DuckDB is DuckDB is the analytics sibling of SQLite: an embedded, synchronous
// engine, so — like sqlite.rs — every call runs on `spawn_blocking`. The
// connection is a file path (":memory:" for in-memory). DuckDB's richer type
// system is rendered text-first; the common scalar types map to typed cells and
// anything else (decimals, temporal, nested) falls back to its text form.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use base64::Engine as _;
use duckdb::types::Value as DuckValue;
use duckdb::Connection as DuckConn;

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, Caps, Column, ConnSpec, DriverMeta, Index, Node, ObjRef, ParamSpec, ParamType, Value,
};

const PARAMS: &[ParamSpec] = &[ParamSpec {
    key: "file",
    label: "Database file",
    kind: ParamType::File,
    required: true,
    secret: false,
    default: Some(":memory:"),
}];

const META: DriverMeta = DriverMeta {
    kind: "duckdb",
    display: "DuckDB",
    default_port: None,
    params: PARAMS,
    auth: &[AuthKind::None],
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false,
        tls: false,
        tunnel: false,
        multi_db: false,
        kv: false,
        indexes: true,
        ddl: true, // duckdb_indexes() / duckdb_tables().sql
    },
};

/// The DuckDB driver.
pub struct DuckdbDriver;

impl DuckdbDriver {
    pub fn new() -> Self {
        DuckdbDriver
    }
}

#[async_trait]
impl Driver for DuckdbDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(
        &self,
        spec: &ConnSpec,
        _net: NetContext,
    ) -> anyhow::Result<Box<dyn Connection>> {
        let file = spec.param("file")?.to_string();
        let conn = tokio::task::spawn_blocking(move || {
            if file == ":memory:" {
                DuckConn::open_in_memory()
            } else {
                DuckConn::open(&file)
            }
        })
        .await?
        .map_err(|e| anyhow::anyhow!("duckdb open failed: {e}"))?;
        Ok(Box::new(DuckdbConnection {
            conn: Arc::new(Mutex::new(conn)),
        }))
    }
}

/// Convert an owned DuckDB Value to our text-first cell Value.
fn cell(v: DuckValue) -> Value {
    match v {
        DuckValue::Null => Value::Null,
        DuckValue::Boolean(b) => Value::Bool(b),
        DuckValue::TinyInt(i) => Value::Int(i as i64),
        DuckValue::SmallInt(i) => Value::Int(i as i64),
        DuckValue::Int(i) => Value::Int(i as i64),
        DuckValue::BigInt(i) => Value::Int(i),
        DuckValue::UTinyInt(i) => Value::Int(i as i64),
        DuckValue::USmallInt(i) => Value::Int(i as i64),
        DuckValue::UInt(i) => Value::Int(i as i64),
        DuckValue::UBigInt(i) => {
            if i <= i64::MAX as u64 {
                Value::Int(i as i64)
            } else {
                Value::Text(i.to_string())
            }
        }
        DuckValue::Float(f) => Value::Float(f as f64),
        DuckValue::Double(f) => Value::Float(f),
        DuckValue::Text(s) => Value::Text(s),
        DuckValue::Blob(b) => Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(&b),
            len: b.len(),
        },
        // Decimals, temporal types, lists, structs, enums, … render as their text form.
        other => Value::Text(format!("{other:?}")),
    }
}

/// A live DuckDB connection.
struct DuckdbConnection {
    conn: Arc<Mutex<DuckConn>>,
}

impl DuckdbConnection {
    async fn run(
        &self,
        sql: String,
    ) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>, Option<u64>)> {
        let arc = self.conn.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
            let conn = arc.lock().unwrap();
            let mut stmt = conn.prepare(&sql).map_err(|e| anyhow::anyhow!("{e}"))?;
            let mut rows = stmt.query([]).map_err(|e| anyhow::anyhow!("{e}"))?;

            // Column names are known after the statement is stepped once; pull the
            // first row, derive columns from it, then continue.
            let mut out: Vec<Vec<Value>> = Vec::new();
            let mut columns: Vec<Column> = Vec::new();
            let mut ncol = 0usize;
            let mut first = true;
            while let Some(r) = rows.next().map_err(|e| anyhow::anyhow!("{e}"))? {
                if first {
                    let stmt_ref = r.as_ref();
                    ncol = stmt_ref.column_count();
                    columns = (0..ncol)
                        .map(|i| Column {
                            name: stmt_ref
                                .column_name(i)
                                .map(|s| s.to_string())
                                .unwrap_or_default(),
                            type_name: String::new(),
                        })
                        .collect();
                    first = false;
                }
                let mut row = Vec::with_capacity(ncol);
                for i in 0..ncol {
                    let v: DuckValue = r.get(i).map_err(|e| anyhow::anyhow!("{e}"))?;
                    row.push(cell(v));
                }
                out.push(row);
            }
            // No rows: derive columns from the prepared statement itself (a DDL/DML
            // statement has none — report it as an affected op instead).
            if columns.is_empty() {
                let cc = stmt.column_count();
                if cc == 0 {
                    return Ok((Vec::new(), Vec::new(), Some(0)));
                }
                columns = (0..cc)
                    .map(|i| Column {
                        name: stmt
                            .column_name(i)
                            .map(|s| s.to_string())
                            .unwrap_or_default(),
                        type_name: String::new(),
                    })
                    .collect();
            }
            Ok((columns, out, None))
        })
        .await?
    }
}

#[async_trait]
impl Connection for DuckdbConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        Ok(vec!["main".to_string()])
    }

    async fn switch_database(&mut self, _db: &str) -> anyhow::Result<()> {
        Err(anyhow::anyhow!(
            "DuckDB has a single database per connection"
        ))
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows, _a) = self
            .run(
                "SELECT table_schema, table_name, table_type FROM information_schema.tables \
                 ORDER BY table_schema, table_name"
                    .to_string(),
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

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Column>> {
        let schema_pred = match &obj.schema {
            Some(s) => format!("AND table_schema = '{}'", s.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT column_name, data_type FROM information_schema.columns \
             WHERE table_name = '{}' {} ORDER BY ordinal_position",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows, _a) = self.run(sql).await?;
        Ok(rows
            .into_iter()
            .map(|r| Column {
                name: match r.first() {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
                type_name: match r.get(1) {
                    Some(Value::Text(s)) => s.clone(),
                    _ => String::new(),
                },
            })
            .collect())
    }

    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // duckdb_indexes() is the catalog view; it exposes the index's SQL rather than a column vector, so
        // the column list is not reconstructed here — `expressions` is a duckdb-internal rendering, and
        // guessing columns out of it would be parsing, not reading. Name + unique/primary are exact.
        let schema_pred = match &obj.schema {
            Some(sc) => format!("AND schema_name = '{}'", sc.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT index_name, is_unique, is_primary, NULL FROM duckdb_indexes() \
             WHERE table_name = '{}' {} ORDER BY index_name",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows, _a) = self.run(sql).await?;
        Ok(super::group_indexes(rows))
    }

    async fn ddl(&mut self, obj: &ObjRef) -> anyhow::Result<Option<String>> {
        // duckdb_tables()/duckdb_views() carry the engine's own CREATE text in `sql`.
        let esc = obj.name.replace('\'', "''");
        let sql = format!(
            "SELECT sql FROM duckdb_tables() WHERE table_name = '{esc}' \
             UNION ALL SELECT sql FROM duckdb_views() WHERE view_name = '{esc}'"
        );
        let (_c, rows, _a) = self.run(sql).await?;
        Ok(rows.first().and_then(|r| match r.first() {
            Some(Value::Text(s)) => Some(s.clone()),
            _ => None,
        }))
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows, affected) = self.run(stmt.to_string()).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(
            columns, rows, affected,
        )))
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
