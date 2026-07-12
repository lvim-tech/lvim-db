// lvim-db-native/drivers/redis: the Redis driver.
//
// Redis is a key/value store, not SQL: the query editor's "statement" is a Redis
// command line (e.g. `GET greeting`, `LRANGE fruits 0 -1`, `HGETALL user:1`).
// The reply is rendered as a grid — a scalar is one row, an array/set is one row
// per element, a map/hash is key/value rows; nested structures become JSON. The
// schema tree is the keyspace: a bounded SCAN lists keys with their type as the
// node kind. Databases are the numbered logical DBs (SELECT switches).

use async_trait::async_trait;
use base64::Engine as _;
use redis::{aio::MultiplexedConnection, Value as RValue};
use serde_json::json;

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column, ConnSpec, DriverMeta, Node, ObjRef, ParamSpec, ParamType, Value,
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
        default: Some("6379"),
    },
    ParamSpec {
        key: "db",
        label: "DB index",
        kind: ParamType::Int,
        required: false,
        secret: false,
        default: Some("0"),
    },
];

const META: DriverMeta = DriverMeta {
    kind: "redis",
    display: "Redis",
    default_port: Some(6379),
    params: PARAMS,
    auth: &[AuthKind::None, AuthKind::Password],
    caps: Caps {
        sql: false,
        schemas: true,
        cancel: false,
        tls: true,
        tunnel: true,
        multi_db: true,
        kv: true,
    },
};

/// The Redis driver.
pub struct RedisDriver;

impl RedisDriver {
    pub fn new() -> Self {
        RedisDriver
    }
}

#[async_trait]
impl Driver for RedisDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let host = spec.param("host")?;
        let port = spec.port(6379);
        let db = spec.param_opt("db").unwrap_or("0");
        let addr = net.resolve(host, port).await?;
        let (rhost, rport) = addr
            .rsplit_once(':')
            .ok_or_else(|| anyhow::anyhow!("net resolved a malformed address"))?;

        // Build the redis:// URL, embedding credentials when present.
        let auth = match &spec.auth {
            AuthSpec::Password { user, password } => {
                let pw = password.resolve().await?;
                if user.is_empty() {
                    format!(":{pw}@")
                } else {
                    format!("{user}:{pw}@")
                }
            }
            _ => String::new(),
        };
        let tls = &spec.tls;
        // rediss:// negotiates TLS; the "#insecure" fragment skips verification for
        // the encrypt-only modes. A CA / mutual cert would use build_with_tls (a
        // later add); noted in findings.
        let scheme = if tls.wanted() { "rediss" } else { "redis" };
        let frag = if tls.wanted() && !tls.verifies_cert() {
            "#insecure"
        } else {
            ""
        };
        let url = format!("{scheme}://{auth}{rhost}:{rport}/{db}{frag}");

        async fn open_con(url: &str) -> anyhow::Result<MultiplexedConnection> {
            let client = redis::Client::open(url.to_string()).map_err(|e| anyhow::anyhow!("redis url invalid: {e}"))?;
            client
                .get_multiplexed_async_connection()
                .await
                .map_err(|e| anyhow::anyhow!("redis connect failed: {e}"))
        }

        if !tls.wanted() {
            return Ok(Box::new(RedisConnection {
                con: open_con(&url).await?,
                encrypted: false,
            }));
        }
        match open_con(&url).await {
            Ok(con) => Ok(Box::new(RedisConnection { con, encrypted: true })),
            Err(e) => {
                if tls.required() {
                    Err(anyhow::anyhow!("redis: TLS is required but the connection failed: {e}"))
                } else {
                    let plain = format!("redis://{auth}{rhost}:{rport}/{db}");
                    Ok(Box::new(RedisConnection {
                        con: open_con(&plain).await?,
                        encrypted: false,
                    }))
                }
            }
        }
    }
}

/// A live Redis connection (the multiplexed connection is cheaply cloned per call).
struct RedisConnection {
    con: MultiplexedConnection,
    encrypted: bool,
}

/// A Redis reply value → JSON (for nested arrays/maps rendered in one cell).
fn rvalue_to_json(v: &RValue) -> serde_json::Value {
    match v {
        RValue::Nil => serde_json::Value::Null,
        RValue::Int(i) => json!(i),
        RValue::Double(d) => json!(d),
        RValue::Boolean(b) => json!(b),
        RValue::BulkString(b) => json!(String::from_utf8_lossy(b)),
        RValue::SimpleString(s) => json!(s),
        RValue::Okay => json!("OK"),
        RValue::Array(a) | RValue::Set(a) => serde_json::Value::Array(a.iter().map(rvalue_to_json).collect()),
        RValue::Map(m) => {
            let mut obj = serde_json::Map::new();
            for (k, val) in m {
                obj.insert(rvalue_to_json(k).to_string(), rvalue_to_json(val));
            }
            serde_json::Value::Object(obj)
        }
        other => json!(format!("{other:?}")),
    }
}

/// A scalar Redis reply → cell.
fn scalar(v: &RValue) -> Value {
    match v {
        RValue::Nil => Value::Null,
        RValue::Int(i) => Value::Int(*i),
        RValue::Double(d) => Value::Float(*d),
        RValue::Boolean(b) => Value::Bool(*b),
        RValue::Okay => Value::Text("OK".to_string()),
        RValue::SimpleString(s) => Value::Text(s.clone()),
        RValue::BulkString(b) => match std::str::from_utf8(b) {
            Ok(s) => Value::Text(s.to_string()),
            Err(_) => Value::Bytes {
                b64: base64::engine::general_purpose::STANDARD.encode(b),
                len: b.len(),
            },
        },
        nested => Value::Json(rvalue_to_json(nested)),
    }
}

/// Tokenise a Redis command line (double-quote aware).
fn tokenize(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_q = false;
    for ch in line.trim().chars() {
        match ch {
            '"' => in_q = !in_q,
            c if c.is_whitespace() && !in_q => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

impl RedisConnection {
    async fn command(&self, tokens: &[String]) -> anyhow::Result<RValue> {
        if tokens.is_empty() {
            return Err(anyhow::anyhow!("empty command"));
        }
        let mut c = redis::cmd(&tokens[0]);
        for a in &tokens[1..] {
            c.arg(a);
        }
        let mut con = self.con.clone();
        c.query_async(&mut con).await.map_err(|e| anyhow::anyhow!("{e}"))
    }
}

/// Render a Redis reply into (columns, rows).
fn render(v: RValue) -> (Vec<Column>, Vec<Vec<Value>>) {
    let value_col = vec![Column {
        name: "value".to_string(),
        type_name: String::new(),
    }];
    match v {
        RValue::Array(a) | RValue::Set(a) => (value_col, a.iter().map(|e| vec![scalar(e)]).collect()),
        RValue::Map(m) => {
            let cols = vec![
                Column {
                    name: "key".to_string(),
                    type_name: String::new(),
                },
                Column {
                    name: "value".to_string(),
                    type_name: String::new(),
                },
            ];
            let rows = m.iter().map(|(k, val)| vec![scalar(k), scalar(val)]).collect();
            (cols, rows)
        }
        scalar_v => (value_col, vec![vec![scalar(&scalar_v)]]),
    }
}

#[async_trait]
impl Connection for RedisConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        // CONFIG GET databases → ["databases", "16"].
        let reply = self
            .command(&["CONFIG".into(), "GET".into(), "databases".into()])
            .await
            .ok();
        let count = match reply {
            Some(RValue::Array(a)) => a
                .get(1)
                .and_then(|v| match v {
                    RValue::BulkString(b) => std::str::from_utf8(b).ok().and_then(|s| s.parse::<usize>().ok()),
                    RValue::Int(i) => Some(*i as usize),
                    _ => None,
                })
                .unwrap_or(16),
            _ => 16,
        };
        Ok((0..count).map(|i| i.to_string()).collect())
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.command(&["SELECT".into(), db.to_string()]).await?;
        Ok(())
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        // One bounded SCAN pass → keys, each labelled by its Redis type.
        let reply = self
            .command(&["SCAN".into(), "0".into(), "COUNT".into(), "300".into()])
            .await?;
        let keys: Vec<String> = match reply {
            RValue::Array(a) => match a.get(1) {
                Some(RValue::Array(ks)) => ks
                    .iter()
                    .filter_map(|k| match k {
                        RValue::BulkString(b) => Some(String::from_utf8_lossy(b).into_owned()),
                        _ => None,
                    })
                    .collect(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        };
        let mut children = Vec::with_capacity(keys.len());
        for key in keys {
            let t = self.command(&["TYPE".into(), key.clone()]).await.ok();
            let kind = match t {
                Some(RValue::SimpleString(s)) => s,
                _ => "key".to_string(),
            };
            children.push(Node {
                name: key,
                kind,
                schema: Some("keyspace".to_string()),
                children: Vec::new(),
            });
        }
        Ok(vec![Node {
            name: "keyspace".to_string(),
            kind: "schema".to_string(),
            schema: None,
            children,
        }])
    }

    async fn columns(&mut self, _obj: &ObjRef) -> anyhow::Result<Vec<Column>> {
        Ok(Vec::new())
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let tokens = tokenize(stmt);
        let reply = self.command(&tokens).await?;
        let (columns, rows) = render(reply);
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, None)))
    }

    fn encrypted(&self) -> bool {
        self.encrypted
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
