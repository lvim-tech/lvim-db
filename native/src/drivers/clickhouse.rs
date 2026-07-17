// lvim-db-native/drivers/clickhouse: the ClickHouse driver (HTTP interface).
//
// ClickHouse's native transport is columnar/typed; a database CLIENT needs
// DYNAMIC result columns for arbitrary SQL, which the HTTP interface gives
// directly: POST the statement with `default_format=JSONCompact` and parse the
// `{ meta:[{name,type}], data:[[…]] }` response. That is the root-cause-correct
// seam for this use (not the typed `clickhouse` crate, which is built around
// compile-time row structs). TLS (https) and the SSH tunnel apply to the HTTP
// endpoint like any other; wired in the remote/auth phase.

use async_trait::async_trait;
use serde::Deserialize;

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column, ConnSpec, DriverMeta, Index, Node, ObjRef, ParamSpec, ParamType, Value,
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
        label: "HTTP port",
        kind: ParamType::Int,
        required: false,
        secret: false,
        default: Some("8123"),
    },
    ParamSpec {
        key: "database",
        label: "Database",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: Some("default"),
    },
];

const META: DriverMeta = DriverMeta {
    kind: "clickhouse",
    display: "ClickHouse",
    default_port: Some(8123),
    params: PARAMS,
    auth: &[AuthKind::None, AuthKind::Password],
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false, // HTTP query cancel (KILL QUERY by query_id) is a later add
        tls: true,
        tunnel: true,
        multi_db: true,
        kv: false,
        indexes: true,
        ddl: true, // system.data_skipping_indices / SHOW CREATE TABLE
    },
};

/// The ClickHouse driver.
pub struct ClickhouseDriver;

impl ClickhouseDriver {
    pub fn new() -> Self {
        ClickhouseDriver
    }
}

#[async_trait]
impl Driver for ClickhouseDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let host = spec.param("host")?;
        let port = spec.port(8123);
        let addr = net.resolve(host, port).await?;
        let (user, password) = match &spec.auth {
            AuthSpec::Password { user, password } => (user.clone(), password.resolve().await?),
            _ => (String::new(), String::new()),
        };
        let tls = &spec.tls;
        let database = spec.param_opt("database").unwrap_or("default").to_string();

        // HTTPS when TLS is wanted (ClickHouse's TLS is HTTPS on its secure port).
        let build = |encrypted: bool| -> anyhow::Result<ClickhouseConnection> {
            let mut cb = reqwest::Client::builder();
            if encrypted {
                if !tls.verifies_cert() {
                    cb = cb.danger_accept_invalid_certs(true);
                }
                if !tls.verifies_hostname() {
                    cb = cb.danger_accept_invalid_hostnames(true);
                }
                if let Some(ca) = &tls.ca {
                    let pem = std::fs::read(ca).map_err(|e| anyhow::anyhow!("cannot read CA '{ca}': {e}"))?;
                    let cert =
                        reqwest::Certificate::from_pem(&pem).map_err(|e| anyhow::anyhow!("bad CA certificate: {e}"))?;
                    cb = cb.add_root_certificate(cert);
                }
                if let (Some(cert), Some(key)) = (&tls.client_cert, &tls.client_key) {
                    let mut pem = std::fs::read(cert).map_err(|e| anyhow::anyhow!("cannot read cert: {e}"))?;
                    pem.extend_from_slice(&std::fs::read(key).map_err(|e| anyhow::anyhow!("cannot read key: {e}"))?);
                    let id =
                        reqwest::Identity::from_pem(&pem).map_err(|e| anyhow::anyhow!("bad client identity: {e}"))?;
                    cb = cb.identity(id);
                }
            }
            Ok(ClickhouseConnection {
                client: cb.build().map_err(|e| anyhow::anyhow!("http client: {e}"))?,
                base: format!("{}://{addr}", if encrypted { "https" } else { "http" }),
                user: user.clone(),
                password: password.clone(),
                database: database.clone(),
                encrypted,
            })
        };

        if !tls.wanted() {
            let conn = build(false)?;
            conn.query_json("SELECT 1").await?;
            return Ok(Box::new(conn));
        }
        let conn = build(true)?;
        match conn.query_json("SELECT 1").await {
            Ok(_) => Ok(Box::new(conn)),
            Err(e) => {
                if tls.required() {
                    Err(anyhow::anyhow!(
                        "clickhouse: TLS is required but the connection failed: {e}"
                    ))
                } else {
                    let plain = build(false)?;
                    plain.query_json("SELECT 1").await?;
                    Ok(Box::new(plain))
                }
            }
        }
    }
}

/// The shape of a ClickHouse JSONCompact response.
#[derive(Deserialize)]
struct JsonCompact {
    meta: Vec<Meta>,
    data: Vec<Vec<serde_json::Value>>,
}

#[derive(Deserialize)]
struct Meta {
    name: String,
    #[serde(rename = "type")]
    type_name: String,
}

/// A live ClickHouse connection (HTTP; stateless per request, plus a current db).
struct ClickhouseConnection {
    client: reqwest::Client,
    base: String,
    user: String,
    password: String,
    database: String,
    encrypted: bool,
}

/// Map a JSON scalar (as ClickHouse emits it in JSONCompact) to a cell.
fn cell(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Int(i)
            } else {
                Value::Float(n.as_f64().unwrap_or(0.0))
            }
        }
        serde_json::Value::String(s) => Value::Text(s.clone()),
        other => Value::Json(other.clone()),
    }
}

impl ClickhouseConnection {
    /// Run a query, requesting JSONCompact, and parse the columns + rows.
    async fn query_json(&self, sql: &str) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>)> {
        let resp = self
            .client
            .post(&self.base)
            .query(&[("database", self.database.as_str()), ("default_format", "JSONCompact")])
            .header("X-ClickHouse-User", &self.user)
            .header("X-ClickHouse-Key", &self.password)
            .body(sql.to_string())
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("clickhouse request failed: {e}"))?;

        let status = resp.status();
        let text = resp.text().await.map_err(|e| anyhow::anyhow!("{e}"))?;
        if !status.is_success() {
            return Err(anyhow::anyhow!(text.trim().to_string()));
        }
        // A statement with no result set (DDL/INSERT) returns an empty body.
        if text.trim().is_empty() {
            return Ok((Vec::new(), Vec::new()));
        }
        let parsed: JsonCompact =
            serde_json::from_str(&text).map_err(|e| anyhow::anyhow!("bad clickhouse response: {e}"))?;
        let columns = parsed
            .meta
            .into_iter()
            .map(|m| Column {
                name: m.name,
                type_name: m.type_name,
            })
            .collect();
        let rows = parsed.data.iter().map(|r| r.iter().map(cell).collect()).collect();
        Ok((columns, rows))
    }

    /// Run a statement returning a single scalar column of strings.
    async fn string_column(&self, sql: &str) -> anyhow::Result<Vec<String>> {
        let (_c, rows) = self.query_json(sql).await?;
        Ok(rows
            .into_iter()
            .filter_map(|r| match r.into_iter().next() {
                Some(Value::Text(s)) => Some(s),
                _ => None,
            })
            .collect())
    }
}

#[async_trait]
impl Connection for ClickhouseConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        self.string_column("SELECT name FROM system.databases ORDER BY name")
            .await
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.database = db.to_string();
        Ok(())
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows) = self
            .query_json(
                "SELECT database, name, engine FROM system.tables \
                 WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema') \
                 ORDER BY database, name",
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
            let engine = get(2);
            let kind = if engine.contains("View") { "view" } else { "table" };
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
        let db = obj.schema.clone().unwrap_or_else(|| self.database.clone());
        let sql = format!(
            "SELECT name, type FROM system.columns WHERE table = '{}' AND database = '{}' ORDER BY position",
            obj.name.replace('\'', "''"),
            db.replace('\'', "''")
        );
        let (_c, rows) = self.query_json(&sql).await?;
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
        // ClickHouse has no b-tree indexes: what it calls an index is a DATA-SKIPPING index, in
        // system.data_skipping_indices. `expr` is the indexed EXPRESSION, not a column vector, so it is shown
        // whole rather than parsed apart. A MergeTree's real access path is its ORDER BY / primary key, which
        // lives in the CREATE statement — that is what the DDL facet is for. Nothing here claims unique or
        // primary, because a skipping index is neither.
        let db = match &obj.schema {
            Some(sc) => sc.replace('\'', "''"),
            None => self.database.replace('\'', "''"),
        };
        let sql = format!(
            "SELECT name, 0, 0, expr FROM system.data_skipping_indices \
             WHERE table = '{}' AND database = '{}' ORDER BY name",
            obj.name.replace('\'', "''"),
            db
        );
        let (_c, rows) = self.query_json(&sql).await?;
        Ok(super::group_indexes(rows))
    }

    async fn ddl(&mut self, obj: &ObjRef) -> anyhow::Result<Option<String>> {
        // SHOW CREATE TABLE is the server's own text, and on ClickHouse it is the only place the engine,
        // ORDER BY and partitioning appear — the parts that actually define how the table behaves.
        let qname = match &obj.schema {
            Some(sc) => format!("`{}`.`{}`", sc.replace('`', "``"), obj.name.replace('`', "``")),
            None => format!("`{}`", obj.name.replace('`', "``")),
        };
        let (_c, rows) = self.query_json(&format!("SHOW CREATE TABLE {qname}")).await?;
        Ok(rows.first().and_then(|r| match r.first() {
            Some(Value::Text(s)) => Some(s.clone()),
            _ => None,
        }))
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows) = self.query_json(stmt).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, None)))
    }

    fn encrypted(&self) -> bool {
        self.encrypted
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
