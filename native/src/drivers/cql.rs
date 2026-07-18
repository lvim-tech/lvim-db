// lvim-db-native/drivers/cql: the Cassandra / ScyllaDB driver (CQL, scylla crate).
//
// One impl serves both the `cassandra` and `scylla` registry kinds — the scylla
// driver is a production CQL client, Cassandra-compatible. A CQL keyspace maps
// to a "schema" and tables to its children. Values come back as CqlValue and are
// rendered text-first. NOTE: implemented and compile-checked against the scylla
// crate, but NOT runtime-verified in this build environment (no Cassandra/Scylla
// node was available).

use async_trait::async_trait;
use base64::Engine as _;
use scylla::client::session::Session;
use scylla::client::session_builder::SessionBuilder;
use scylla::value::{CqlValue, Row};

use crate::driver::{Connection, Driver, ResultStream};
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
        default: Some("9042"),
    },
    ParamSpec {
        key: "keyspace",
        label: "Keyspace",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: None,
    },
];

const AUTH: &[AuthKind] = &[AuthKind::None, AuthKind::Password];

const CAPS: Caps = Caps {
    sql: true,
    schemas: true,
    cancel: false,
    tls: true,
    tunnel: true,
    multi_db: true,
    kv: false,
    indexes: true,
    ddl: false, // system_schema.indexes; DESCRIBE is reconstructed CLIENT-side in CQL
};

const CASSANDRA_META: DriverMeta = DriverMeta {
    kind: "cassandra",
    display: "Cassandra",
    default_port: Some(9042),
    params: PARAMS,
    auth: AUTH,
    caps: CAPS,
};

const SCYLLA_META: DriverMeta = DriverMeta {
    kind: "scylla",
    display: "ScyllaDB",
    default_port: Some(9042),
    params: PARAMS,
    auth: AUTH,
    caps: CAPS,
};

/// The CQL driver, serving both the `cassandra` and `scylla` kinds.
pub struct CqlDriver {
    meta: &'static DriverMeta,
}

impl CqlDriver {
    #[cfg(feature = "cassandra")]
    pub fn cassandra() -> Self {
        Self { meta: &CASSANDRA_META }
    }

    #[cfg(feature = "scylla")]
    pub fn scylla() -> Self {
        Self { meta: &SCYLLA_META }
    }
}

#[async_trait]
impl Driver for CqlDriver {
    fn meta(&self) -> &'static DriverMeta {
        self.meta
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        // Native CQL TLS is not yet wired (scylla's rustls TLS context). Rather
        // than silently send credentials in the clear, a REQUIRED-encryption
        // connection is refused — use an SSH tunnel for an encrypted CQL link
        // meanwhile. (Not runtime-verified: no Cassandra/Scylla node available.)
        if spec.tls.required() && !net.tunneled() {
            return Err(anyhow::anyhow!(
                "CQL native TLS is not implemented in this build; use an SSH tunnel for encryption, \
                 or set tls.mode=disable to connect in the clear explicitly"
            ));
        }
        let host = spec.param("host")?;
        let port = spec.port(9042);
        let addr = net.resolve(host, port).await?;

        let mut builder = SessionBuilder::new().known_node(addr);
        if let AuthSpec::Password { user, password } = &spec.auth {
            builder = builder.user(user.clone(), password.resolve().await?);
        }
        if let Some(ks) = spec.param_opt("keyspace") {
            builder = builder.use_keyspace(ks.to_string(), false);
        }
        let session = builder
            .build()
            .await
            .map_err(|e| anyhow::anyhow!("cql connect failed: {e}"))?;
        Ok(Box::new(CqlConnection {
            session,
            keyspace: spec.param_opt("keyspace").map(|s| s.to_string()),
        }))
    }
}

/// Convert a CqlValue to our text-first cell Value.
fn cell(v: &CqlValue) -> Value {
    match v {
        CqlValue::Ascii(s) | CqlValue::Text(s) => Value::Text(s.clone()),
        CqlValue::Boolean(b) => Value::Bool(*b),
        CqlValue::TinyInt(i) => Value::Int(*i as i64),
        CqlValue::SmallInt(i) => Value::Int(*i as i64),
        CqlValue::Int(i) => Value::Int(*i as i64),
        CqlValue::BigInt(i) => Value::Int(*i),
        CqlValue::Float(f) => Value::Float(*f as f64),
        CqlValue::Double(f) => Value::Float(*f),
        CqlValue::Blob(b) => Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(b),
            len: b.len(),
        },
        // Everything else (uuid/timeuuid, inet, date/time/timestamp/duration, counter, decimal/varint,
        // list/set/map/tuple/UDT/vector) → the crate's OWN `Display`, which renders CQL-literal forms
        // (`'2026-07-18'`, `[1,2]`, `{'k':'v'}`, a uuid's hex). This replaces `format!("{:?}")` (Rust Debug:
        // `Map([(Text("k"),Text("v"))])`, `CqlTimestamp(...)`) — never the value, never a valid literal.
        // Decimal/Varint still show as `blobAsDecimal(0x…)`/`blobAsVarint(0x…)` (the crate's choice — a valid
        // CQL expression, not a plain number), but that is honest and round-trippable, unlike the Debug form.
        other => Value::Text(other.to_string()),
    }
}

/// A live CQL session.
struct CqlConnection {
    session: Session,
    keyspace: Option<String>,
}

impl CqlConnection {
    async fn run(&self, cql: &str) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>)> {
        let result = self
            .session
            .query_unpaged(cql, &[])
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        // A statement with no result set (DDL/DML) has no rows.
        let rows_result = match result.into_rows_result() {
            Ok(r) => r,
            Err(_) => return Ok((Vec::new(), Vec::new())),
        };
        let columns: Vec<Column> = rows_result
            .column_specs()
            .iter()
            .map(|s| Column {
                name: s.name().to_string(),
                type_name: format!("{:?}", s.typ()),
            })
            .collect();
        let mut out: Vec<Vec<Value>> = Vec::new();
        for row in rows_result.rows::<Row>().map_err(|e| anyhow::anyhow!("{e}"))? {
            let row = row.map_err(|e| anyhow::anyhow!("{e}"))?;
            let cells = row
                .columns
                .iter()
                .map(|c| match c {
                    Some(v) => cell(v),
                    None => Value::Null,
                })
                .collect();
            out.push(cells);
        }
        Ok((columns, out))
    }
}

#[async_trait]
impl Connection for CqlConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        let (_c, rows) = self.run("SELECT keyspace_name FROM system_schema.keyspaces").await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| match r.into_iter().next() {
                Some(Value::Text(s)) => Some(s),
                _ => None,
            })
            .collect())
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.session
            .use_keyspace(db, false)
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        self.keyspace = Some(db.to_string());
        Ok(())
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        // Group tables under their keyspace (the user keyspaces).
        let (_c, rows) = self
            .run(
                "SELECT keyspace_name, table_name FROM system_schema.tables \
                 WHERE keyspace_name NOT IN ('system','system_schema','system_auth',\
                 'system_distributed','system_traces') ALLOW FILTERING",
            )
            .await?;
        let mut schemas: Vec<Node> = Vec::new();
        for r in rows {
            let get = |i: usize| match r.get(i) {
                Some(Value::Text(s)) => s.clone(),
                _ => String::new(),
            };
            let ks = get(0);
            let name = get(1);
            let node = Node {
                name,
                kind: "table".to_string(),
                schema: Some(ks.clone()),
                children: Vec::new(),
            };
            match schemas.iter_mut().find(|s| s.name == ks) {
                Some(s) => s.children.push(node),
                None => schemas.push(Node {
                    name: ks.clone(),
                    kind: "schema".to_string(),
                    schema: None,
                    children: vec![node],
                }),
            }
        }
        Ok(schemas)
    }

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<TableColumn>> {
        // In CQL a row is identified by its PARTITION KEY plus its CLUSTERING columns — together the
        // PRIMARY KEY. `kind` names each one, so both count; a plain `regular` column does not.
        let ks = obj.schema.clone().or_else(|| self.keyspace.clone()).unwrap_or_default();
        let sql = format!(
            "SELECT column_name, type, kind FROM system_schema.columns \
             WHERE keyspace_name = '{}' AND table_name = '{}'",
            ks.replace('\'', "''"),
            obj.name.replace('\'', "''")
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
                primary: matches!(r.get(2), Some(Value::Text(k)) if k == "partition_key" || k == "clustering"),
            })
            .collect())
    }
    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // system_schema.indexes is the cluster's own catalog. A CQL secondary index has exactly ONE target
        // (options['target']) and is never unique nor primary — the partition key is not an index — so those
        // flags are honestly false rather than invented.
        let ks = match &obj.schema {
            Some(sc) => sc.replace('\'', "''"),
            None => return Ok(Vec::new()),
        };
        let sql = format!(
            "SELECT index_name, options FROM system_schema.indexes \
             WHERE keyspace_name = '{}' AND table_name = '{}'",
            ks,
            obj.name.replace('\'', "''")
        );
        let (_c, rows) = self.run(&sql).await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| {
                let name = match r.first() {
                    Some(Value::Text(s)) => s.clone(),
                    _ => return None,
                };
                // `options` is a CQL map<text,text>, now rendered by the crate's `Display` as a CQL map
                // literal: `{'target':'email','class_name':'exams'}` (keys/values single-quoted). Find the
                // `target` key and take its quoted value. (This tracks the cell() render above — when that was
                // Rust Debug this sliced `Text("target")` instead; both were updated together.)
                let target = match r.get(1) {
                    Some(Value::Text(s)) => s
                        .split_once("'target':'")
                        .and_then(|(_, rest)| rest.split_once('\'').map(|(v, _)| v.to_string())),
                    _ => None,
                };
                Some(Index {
                    name,
                    columns: target.into_iter().filter(|t| !t.is_empty()).collect(),
                    unique: false,
                    primary: false,
                })
            })
            .collect())
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows) = self.run(stmt).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, None)))
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
