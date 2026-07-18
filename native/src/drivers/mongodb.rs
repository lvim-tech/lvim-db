// lvim-db-native/drivers/mongodb: the MongoDB driver.
//
// MongoDB has no SQL. The query editor's "statement" is a JSON document:
//   { "find": "coll", "filter": {…}, "sort": {…}, "limit": N, "projection": {…} }
//   { "aggregate": "coll", "pipeline": [ … ] }
//   any other document → run as a raw database command (db.runCommand).
// find/aggregate stream a live cursor (real server-side paging); a document is
// rendered as one grid row per top-level field, with a trailing `_document`
// column holding the whole document JSON (so nothing is lost when documents are
// heterogeneous). Schema browsing maps a database→collections; columns are
// sampled from one document (MongoDB is schemaless).

use async_trait::async_trait;
use base64::Engine as _;
use futures_util::StreamExt;
use mongodb::bson::{Bson, Document};
use mongodb::options::{ClientOptions, Credential, ServerAddress};
use mongodb::{Client, Cursor};

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
        default: Some("27017"),
    },
    ParamSpec {
        key: "database",
        label: "Database",
        kind: ParamType::String,
        required: true,
        secret: false,
        default: Some("test"),
    },
    ParamSpec {
        key: "auth_source",
        label: "Auth database",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: Some("admin"),
    },
];

const AUTH: &[AuthKind] = &[
    AuthKind::None,
    AuthKind::Password,
    AuthKind::ClientCert,
    AuthKind::Provider,
];

const MONGO_META: DriverMeta = DriverMeta {
    kind: "mongodb",
    display: "MongoDB",
    default_port: Some(27017),
    params: PARAMS,
    auth: AUTH,
    caps: Caps {
        sql: false,
        schemas: true,
        cancel: false, // no protocol-level query cancel in this phase (killOp is a later add)
        tls: true,
        tunnel: true,
        multi_db: true,
        kv: true,
        indexes: true, // listIndexes
        ddl: false,    // a document store has no CREATE statement to show
    },
};

/// The MongoDB driver.
pub struct MongoDriver;

impl MongoDriver {
    pub fn new() -> Self {
        MongoDriver
    }
}

/// Build the credential from a spec's auth, resolving the password template.
async fn credential(spec: &ConnSpec) -> anyhow::Result<Option<Credential>> {
    match &spec.auth {
        AuthSpec::Password { user, password } => {
            let pw = password.resolve().await?;
            Ok(Some(
                Credential::builder()
                    .username(user.clone())
                    .password(pw)
                    .source(spec.param_opt("auth_source").map(|s| s.to_string()))
                    .build(),
            ))
        }
        _ => Ok(None),
    }
}

#[async_trait]
impl Driver for MongoDriver {
    fn meta(&self) -> &'static DriverMeta {
        &MONGO_META
    }

    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let host = spec.param("host")?;
        let port = spec.port(27017);
        let db = spec.param("database")?.to_string();

        let addr = net.resolve(host, port).await?;
        let (rhost, rport) = addr
            .rsplit_once(':')
            .ok_or_else(|| anyhow::anyhow!("net resolved a malformed address"))?;

        let mut opts = ClientOptions::default();
        opts.hosts = vec![ServerAddress::Tcp {
            host: rhost.to_string(),
            port: rport.parse().ok(),
        }];
        opts.credential = credential(spec).await?;
        // A single mongod is a standalone; connect directly (no replica-set discovery).
        opts.direct_connection = Some(true);
        opts.app_name = Some("lvim-db".to_string());

        let tls = &spec.tls;
        // Try encrypted first when TLS is wanted.
        let mut encrypted = false;
        if tls.wanted() {
            let mut topts = mongodb::options::TlsOptions::default();
            if let Some(ca) = &tls.ca {
                topts.ca_file_path = Some(ca.into());
            }
            topts.allow_invalid_certificates = Some(!tls.verifies_cert());
            // Mutual X.509: MongoDB expects a single PEM holding cert+key.
            if let Some(cert) = &tls.client_cert {
                topts.cert_key_file_path = Some(cert.into());
            }
            let mut tls_opts = opts.clone();
            tls_opts.tls = Some(mongodb::options::Tls::Enabled(topts));
            match MongoConnection::probe(tls_opts, &db).await {
                Ok(client) => {
                    return Ok(Box::new(MongoConnection {
                        client,
                        db,
                        encrypted: true,
                    }))
                }
                Err(e) => {
                    if tls.required() {
                        return Err(anyhow::anyhow!(
                            "mongodb: TLS is required but the connection failed: {e}"
                        ));
                    }
                    // Prefer: fall through to a plaintext attempt.
                    encrypted = false;
                }
            }
        }

        let client = MongoConnection::probe(opts, &db).await?;
        Ok(Box::new(MongoConnection { client, db, encrypted }))
    }
}

/// A live MongoDB connection with a current database.
struct MongoConnection {
    client: Client,
    db: String,
    encrypted: bool,
}

impl MongoConnection {
    /// Build a client from options and ping so a bad host/auth/TLS fails now.
    async fn probe(opts: ClientOptions, db: &str) -> anyhow::Result<Client> {
        let client = Client::with_options(opts).map_err(|e| anyhow::anyhow!("mongodb connect failed: {e}"))?;
        client
            .database(db)
            .run_command(mongodb::bson::doc! { "ping": 1 })
            .await
            .map_err(|e| anyhow::anyhow!("mongodb ping failed: {e}"))?;
        Ok(client)
    }
}

/// Convert one Bson value into our text-first cell Value.
fn cell(b: &Bson) -> Value {
    match b {
        Bson::Null | Bson::Undefined => Value::Null,
        Bson::Boolean(v) => Value::Bool(*v),
        Bson::Int32(i) => Value::Int(*i as i64),
        Bson::Int64(i) => Value::Int(*i),
        Bson::Double(d) => Value::Float(*d),
        Bson::String(s) => Value::Text(s.clone()),
        // TAGGED, not Text: an ObjectId rendered to its bare hex is indistinguishable from a string `_id`
        // by the time it reaches the grid, and the grid needs that difference to address the document at
        // all — `{_id: "<hex>"}` matches no real ObjectId. It still DISPLAYS as the hex (see the Lua
        // `cell_display`); only the type travels with it.
        Bson::ObjectId(oid) => Value::Oid(oid.to_hex()),
        // DateTime and Decimal128 are TAGGED (`Value::Ext`, like ObjectId) rather than left as a bare string:
        // a top-level date/decimal otherwise reaches the grid as plain text and an edit writes it back as a
        // string — the wrong BSON type. `Ext` shows the readable value AND, on edit, round-trips through the
        // extended-JSON key (`$date` / `$numberDecimal`) that `Bson::try_from` (see `dispatch`) reads back.
        Bson::DateTime(dt) => Value::Ext {
            text: dt.try_to_rfc3339_string().unwrap_or_else(|_| dt.to_string()),
            key: "$date".to_string(),
        },
        Bson::Decimal128(d) => Value::Ext {
            text: d.to_string(),
            key: "$numberDecimal".to_string(),
        },
        Bson::Binary(bin) => Value::Bytes {
            b64: base64::engine::general_purpose::STANDARD.encode(&bin.bytes),
            len: bin.bytes.len(),
        },
        Bson::Document(_) | Bson::Array(_) => Value::Json(b.clone().into_relaxed_extjson()),
        other => Value::Text(other.to_string()),
    }
}

/// Derive a stable column order from a document: `_id` first, then the remaining
/// keys in document order; a synthetic `_document` column always trails so a
/// heterogeneous document set is never truncated.
fn column_order(doc: &Document) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    if doc.contains_key("_id") {
        keys.push("_id".to_string());
    }
    for (k, _) in doc.iter() {
        if k != "_id" {
            keys.push(k.clone());
        }
    }
    keys
}

/// Map a document to a grid row for `keys` (missing keys → Null), plus the full
/// document JSON in the trailing `_document` column.
fn doc_to_row(doc: &Document, keys: &[String]) -> Vec<Value> {
    let mut row = Vec::with_capacity(keys.len() + 1);
    for k in keys {
        row.push(doc.get(k).map(cell).unwrap_or(Value::Null));
    }
    row.push(Value::Json(Bson::Document(doc.clone()).into_relaxed_extjson()));
    row
}

/// The column set for a `keys` order (adds the trailing `_document`).
fn columns_for(keys: &[String]) -> Vec<Column> {
    let mut cols: Vec<Column> = keys
        .iter()
        .map(|k| Column {
            name: k.clone(),
            type_name: String::new(),
        })
        .collect();
    cols.push(Column {
        name: "_document".to_string(),
        type_name: "json".to_string(),
    });
    cols
}

impl MongoConnection {
    /// Open a find/aggregate cursor (returning a live streaming result), or run a
    /// raw command (returning a buffered result).
    async fn dispatch(&self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        // EXTENDED JSON, not plain: `bson::to_document` is a straight serde conversion, so `{"$oid": "…"}`
        // would land as a literal sub-document with a `$oid` KEY and match nothing. `Bson::try_from` reads
        // the extended-JSON forms (`$oid`, `$date`, `$numberLong`, …) into their real BSON types — which is
        // both what every other mongo client speaks and the only way a caller can name an ObjectId in a
        // filter. That is what makes an addressed update possible (see `Value::Oid`).
        let json: serde_json::Value =
            serde_json::from_str(stmt).map_err(|e| anyhow::anyhow!("statement must be a JSON document: {e}"))?;
        let doc: Document = match Bson::try_from(json) {
            Ok(Bson::Document(d)) => d,
            Ok(_) => anyhow::bail!("statement must be a JSON object"),
            Err(e) => anyhow::bail!("invalid command document: {e}"),
        };
        let db = self.client.database(&self.db);

        if let Ok(coll) = doc.get_str("find") {
            let filter = doc.get_document("filter").cloned().unwrap_or_default();
            let handle = db.collection::<Document>(coll);
            let mut f = handle.find(filter);
            if let Ok(sort) = doc.get_document("sort") {
                f = f.sort(sort.clone());
            }
            if let Some(limit) = doc
                .get_i64("limit")
                .ok()
                .or_else(|| doc.get_i32("limit").ok().map(|i| i as i64))
            {
                f = f.limit(limit);
            }
            if let Ok(proj) = doc.get_document("projection") {
                f = f.projection(proj.clone());
            }
            let cursor = f.await.map_err(|e| anyhow::anyhow!("{e}"))?;
            return MongoCursorStream::open(cursor).await;
        }

        if let Ok(coll) = doc.get_str("aggregate") {
            let pipeline: Vec<Document> = match doc.get_array("pipeline") {
                Ok(arr) => arr.iter().filter_map(|b| b.as_document().cloned()).collect(),
                Err(_) => Vec::new(),
            };
            let handle = db.collection::<Document>(coll);
            let cursor = handle.aggregate(pipeline).await.map_err(|e| anyhow::anyhow!("{e}"))?;
            return MongoCursorStream::open(cursor).await;
        }

        // Raw command: run it and render the single result document.
        let result = db.run_command(doc).await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let keys = column_order(&result);
        let row = doc_to_row(&result, &keys);
        Ok(Box::new(super::buffered::BufferedStream::new(
            columns_for(&keys),
            vec![row],
            None,
        )))
    }
}

/// The suffix mongo puts after a field in a DERIVED index name: the direction for a numeric key (`1`/`-1`),
/// else the index TYPE as a string (`"text"`, `"2dsphere"`, `hashed`). Only used when the server returned an
/// index with no explicit name.
fn bson_key_suffix(v: &Bson) -> String {
    match v {
        Bson::Int32(i) => i.to_string(),
        Bson::Int64(i) => i.to_string(),
        Bson::Double(f) => (*f as i64).to_string(),
        Bson::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[async_trait]
impl Connection for MongoConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        self.client
            .list_database_names()
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.db = db.to_string();
        Ok(())
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let names = self
            .client
            .database(&self.db)
            .list_collection_names()
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let children = names
            .into_iter()
            .map(|name| Node {
                name,
                kind: "collection".to_string(),
                schema: Some(self.db.clone()),
                children: Vec::new(),
            })
            .collect();
        Ok(vec![Node {
            name: self.db.clone(),
            kind: "schema".to_string(),
            schema: None,
            children,
        }])
    }

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<TableColumn>> {
        // Schemaless: sample one document and expose its top-level fields. `_id` is mongo's primary key —
        // every document has one, it is unique, and it is immutable — so it is the field the grid addresses
        // a row by. That is a property of the STORE, not of this sample, hence the flat name check.
        let coll = self.client.database(&self.db).collection::<Document>(&obj.name);
        let sample = coll
            .find_one(Document::new())
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        match sample {
            Some(doc) => Ok(columns_for(&column_order(&doc))
                .into_iter()
                .map(|c| TableColumn {
                    primary: c.name == "_id",
                    name: c.name,
                    type_name: c.type_name,
                })
                .collect()),
            None => Ok(Vec::new()),
        }
    }
    async fn indexes(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        // `listIndexes` is the engine's own answer, so a compound/unique index reads exactly as the server
        // holds it. The key DOCUMENT preserves field order, which IS the index order — so the keys are taken
        // in document order rather than sorted.
        let coll = self.client.database(&self.db).collection::<Document>(&obj.name);
        let mut cur = coll.list_indexes().await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let mut out = Vec::new();
        while let Some(m) = cur.next().await {
            let m = m.map_err(|e| anyhow::anyhow!("{e}"))?;
            let keys = &m.keys;
            let columns: Vec<String> = keys.keys().map(|k| k.to_string()).collect();
            let opts = m.options.as_ref();
            let name = opts
                .and_then(|o| o.name.clone())
                // mongo only omits the name when the client did not set one; the server then derives
                // "<field>_<dir>_…" itself, so fall back to the same shape rather than showing a blank row.
                .unwrap_or_else(|| {
                    keys.iter()
                        .map(|(k, v)| format!("{k}_{}", bson_key_suffix(v)))
                        .collect::<Vec<_>>()
                        .join("_")
                });
            let unique = opts.and_then(|o| o.unique).unwrap_or(false);
            // A collection's `_id` index is mongo's primary key: always present, never droppable.
            let primary = columns.len() == 1 && columns[0] == "_id";
            out.push(Index {
                name,
                columns,
                unique: unique || primary,
                primary,
            });
        }
        Ok(out)
    }

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        self.dispatch(stmt).await
    }

    fn encrypted(&self) -> bool {
        self.encrypted
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}

/// A live cursor result. The first document is read at open (to derive the stable
/// column order); it is then yielded first and the rest streamed on demand.
struct MongoCursorStream {
    cursor: Cursor<Document>,
    keys: Vec<String>,
    columns: Vec<Column>,
    first: Option<Document>,
    done: bool,
}

impl MongoCursorStream {
    async fn open(mut cursor: Cursor<Document>) -> anyhow::Result<Box<dyn ResultStream>> {
        let first = match cursor.next().await {
            Some(Ok(doc)) => Some(doc),
            Some(Err(e)) => return Err(anyhow::anyhow!("{e}")),
            None => None,
        };
        let keys = first.as_ref().map(column_order).unwrap_or_default();
        let columns = columns_for(&keys);
        Ok(Box::new(MongoCursorStream {
            cursor,
            keys,
            columns,
            first,
            done: false,
        }))
    }
}

#[async_trait]
impl ResultStream for MongoCursorStream {
    fn columns(&self) -> &[Column] {
        &self.columns
    }

    async fn next_page(&mut self, n: usize) -> anyhow::Result<Option<Vec<Vec<Value>>>> {
        if self.done && self.first.is_none() {
            return Ok(None);
        }
        let mut rows: Vec<Vec<Value>> = Vec::new();
        if let Some(doc) = self.first.take() {
            rows.push(doc_to_row(&doc, &self.keys));
        }
        while rows.len() < n && !self.done {
            match self.cursor.next().await {
                Some(Ok(doc)) => rows.push(doc_to_row(&doc, &self.keys)),
                Some(Err(e)) => return Err(anyhow::anyhow!("{e}")),
                None => self.done = true,
            }
        }
        if rows.is_empty() {
            Ok(None)
        } else {
            Ok(Some(rows))
        }
    }
}
