// lvim-db-native/spec: the wire data model shared by the RPC layer, the driver
// trait, and every driver impl.
//
// These types are the CONTRACT with the Lua side: a `ConnSpec` is what the
// connection form produces (driver kind + a typed param map + a typed auth
// method + TLS + optional SSH tunnel), and `DriverMeta` is what the Lua side
// reads back from `rpc.hello` to BUILD that form dynamically — so adding a DB
// type never edits any Lua. Secrets live here as templates (see secret.rs);
// they are resolved in the daemon at connect time only, never logged.

// This module is the WIRE CONTRACT: its auth variants, TLS/tunnel fields and
// Value cell types are consumed incrementally as each driver phase lands, so
// some are not yet constructed by the single compiled driver of an early build.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};

use crate::secret::Secret;

/// A capability bitset a driver advertises so the UI can adapt (label the editor
/// SQL vs command, show the schema tree, offer cancel, allow a tunnel, …).
#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct Caps {
    pub sql: bool,      // statements are SQL (vs commands / JSON)
    pub schemas: bool,  // has a schema → object tree to browse
    pub cancel: bool,   // supports protocol-level query cancellation
    pub tls: bool,      // supports TLS to the server
    pub tunnel: bool,   // a TCP endpoint that an SSH tunnel can front
    pub multi_db: bool, // exposes multiple databases on one connection
    pub kv: bool,       // key/value or document store (not relational SQL)
    // Per-object INTROSPECTION beyond the columns every schema driver already serves. Advertised
    // separately because support is genuinely uneven and NOT implied by `schemas`: a document/KV store has
    // no DDL to show at all, and several SQL engines expose indexes but no server-side "CREATE statement"
    // (there the honest answer is "cannot", not a hand-assembled approximation). The drawer offers a helper
    // ONLY where its driver claims it, so no engine ever grows a row that dead-ends.
    pub indexes: bool, // can list an object's indexes (`schema.indexes`)
    pub ddl: bool,     // can return an object's CREATE statement (`schema.ddl`)
}

/// The kinds of auth a driver can accept. A driver lists the subset it supports
/// in `DriverMeta.auth`; the connection form then renders only those methods'
/// fields for the chosen driver — no hardcoded field set anywhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    None,
    Password,
    ClientCert, // TLS mutual / X.509 (also Snowflake key-pair JWT key file)
    Provider,   // IAM / OAuth / OIDC bearer, driver-native
    Kerberos,   // GSSAPI where the driver implements it natively
}

/// One typed field in the connection form (host, port, database, file, url, …).
/// `secret = true` marks a field whose value is a Secret TEMPLATE.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct ParamSpec {
    pub key: &'static str,
    pub label: &'static str,
    #[serde(rename = "type")]
    pub kind: ParamType,
    pub required: bool,
    pub secret: bool,
    pub default: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ParamType {
    String,
    Int,
    Bool,
    File,
    Enum,
}

/// Static, driver-declared metadata. Serialized to Lua verbatim by `rpc.hello`,
/// so the Lua side lists driver kinds and builds each connection form from it.
#[derive(Debug, Clone, Serialize)]
pub struct DriverMeta {
    pub kind: &'static str,
    pub display: &'static str,
    pub default_port: Option<u16>,
    pub params: &'static [ParamSpec],
    pub auth: &'static [AuthKind],
    pub caps: Caps,
}

// ── the incoming connection spec (built by the Lua form) ─────────────────────

/// Everything needed to open one connection. `params` is a free-form string map
/// keyed by the driver's ParamSpec keys (the daemon interprets them per driver);
/// `auth`, `tls`, `tunnel` are typed.
#[derive(Debug, Clone, Deserialize)]
pub struct ConnSpec {
    pub driver: String,
    #[serde(default)]
    pub params: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub auth: AuthSpec,
    #[serde(default)]
    pub tls: TlsSpec,
    #[serde(default)]
    pub tunnel: Option<TunnelSpec>,
}

impl ConnSpec {
    /// A required string param, or an error naming the missing key.
    pub fn param(&self, key: &str) -> anyhow::Result<&str> {
        self.params
            .get(key)
            .map(String::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| anyhow::anyhow!("missing required parameter '{key}'"))
    }

    /// An optional string param.
    pub fn param_opt(&self, key: &str) -> Option<&str> {
        self.params.get(key).map(String::as_str).filter(|s| !s.is_empty())
    }

    /// An optional param parsed as a port, falling back to `default`.
    pub fn port(&self, default: u16) -> u16 {
        self.param_opt("port").and_then(|s| s.parse().ok()).unwrap_or(default)
    }
}

/// A typed auth method. `password` and the various key/token fields carry Secret
/// TEMPLATES (`{{ env "VAR" }}` / `{{ cmd "…" }}` / literal), resolved only at
/// connect time and never logged.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AuthSpec {
    #[default]
    None,
    Password {
        #[serde(default)]
        user: String,
        #[serde(default)]
        password: Secret,
    },
    ClientCert {
        cert: String,
        key: String,
        #[serde(default)]
        key_password: Secret,
        #[serde(default)]
        user: String,
    },
    Provider {
        /// e.g. "aws" | "oauth" | "oidc" — interpreted per driver.
        provider: String,
        #[serde(default)]
        token: Secret,
        #[serde(default)]
        user: String,
    },
    Kerberos {
        #[serde(default)]
        principal: Option<String>,
    },
}

/// TLS to the server — orthogonal to auth, negotiated with rustls (no OpenSSL).
/// The SAFE default is `Prefer`: encryption is attempted and used whenever the
/// server supports it, and a link that ends up unencrypted is surfaced (never
/// silently accepted). `ca` verifies the server; `client_cert`/`client_key`
/// enable mutual X.509 (client-certificate authentication).
#[derive(Debug, Clone, Deserialize)]
pub struct TlsSpec {
    #[serde(default)]
    pub mode: TlsMode,
    #[serde(default)]
    pub ca: Option<String>,
    #[serde(default)]
    pub client_cert: Option<String>,
    #[serde(default)]
    pub client_key: Option<String>,
}

impl Default for TlsSpec {
    fn default() -> Self {
        Self {
            mode: TlsMode::Prefer,
            ca: None,
            client_cert: None,
            client_key: None,
        }
    }
}

impl TlsSpec {
    /// Whether TLS must be negotiated (a plaintext-only server is rejected).
    pub fn required(&self) -> bool {
        matches!(self.mode, TlsMode::Require | TlsMode::VerifyCa | TlsMode::VerifyFull)
    }

    /// Whether TLS should be attempted at all.
    pub fn wanted(&self) -> bool {
        !matches!(self.mode, TlsMode::Disable)
    }

    /// Whether the server certificate chain is verified against `ca` / system roots.
    pub fn verifies_cert(&self) -> bool {
        matches!(self.mode, TlsMode::VerifyCa | TlsMode::VerifyFull)
    }

    /// Whether the server hostname is verified (VerifyFull only).
    pub fn verifies_hostname(&self) -> bool {
        matches!(self.mode, TlsMode::VerifyFull)
    }
}

/// TLS posture, from least to most strict. The default is `Prefer`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TlsMode {
    /// Explicit opt-out: no encryption attempted (the only unencrypted path).
    Disable,
    /// Try TLS; use it when the server supports it, else plaintext (surfaced).
    #[default]
    Prefer,
    /// Encryption REQUIRED, but the server certificate is not verified.
    Require,
    /// Encryption required + the certificate chain is verified against the CA.
    VerifyCa,
    /// Encryption required + chain AND hostname verified (the strictest).
    VerifyFull,
}

/// An SSH tunnel fronting the DB's TCP endpoint — orthogonal to both auth and
/// TLS, applied by the net layer before the driver dials. Wired with russh in
/// the remote/auth phase.
#[derive(Debug, Clone, Deserialize)]
pub struct TunnelSpec {
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    pub user: String,
    pub auth: TunnelAuth,
}

fn default_ssh_port() -> u16 {
    22
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TunnelAuth {
    Agent,
    Key {
        path: String,
        #[serde(default)]
        passphrase: Secret,
    },
    Password {
        #[serde(default)]
        password: Secret,
    },
}

// ── result model (uniform across every driver) ───────────────────────────────

/// One result column.
#[derive(Debug, Clone, Serialize)]
pub struct Column {
    pub name: String,
    #[serde(rename = "type")]
    pub type_name: String,
}

/// A schema-tree node (schema → table/view/collection). `kind` drives the icon.
#[derive(Debug, Clone, Serialize)]
pub struct Node {
    pub name: String,
    pub kind: String, // "schema" | "table" | "view" | "collection" | "column" | …
    pub schema: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Node>,
}

/// One index on a browsable object. Deliberately a SMALL common shape: every engine that has indexes has a
/// name, the columns it covers, and the unique/primary distinction — everything past that (method, partial
/// predicates, collation, storage options) is per-engine and belongs in the DDL, not in a lowest-common
/// struct that would be mostly `None`.
#[derive(Debug, Clone, Serialize)]
pub struct Index {
    pub name: String,
    pub columns: Vec<String>,
    pub unique: bool,
    pub primary: bool,
}

/// A reference to a browsable object (for `schema.columns` / `schema.indexes` / `schema.ddl`).
#[derive(Debug, Clone, Deserialize)]
pub struct ObjRef {
    pub name: String,
    #[serde(default)]
    pub schema: Option<String>,
}

/// A single result cell. Serializes to a plain JSON value the Lua grid can
/// render directly: scalars as scalars, bytes/timestamp as a tagged object so
/// the grid can show a marker and fetch the full value via `query.cell`.
#[derive(Debug, Clone)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Bytes { b64: String, len: usize },
    Json(serde_json::Value),
    Timestamp(String),
}

impl Serialize for Value {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        match self {
            Value::Null => s.serialize_none(),
            Value::Bool(b) => s.serialize_bool(*b),
            Value::Int(i) => s.serialize_i64(*i),
            Value::Float(f) => s.serialize_f64(*f),
            Value::Text(t) => s.serialize_str(t),
            Value::Timestamp(t) => s.serialize_str(t),
            Value::Json(j) => j.serialize(s),
            Value::Bytes { b64, len } => {
                let mut m = s.serialize_map(Some(2))?;
                m.serialize_entry("__bytes", b64)?;
                m.serialize_entry("len", len)?;
                m.end()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_serializes_as_plain_json() {
        assert_eq!(serde_json::to_string(&Value::Null).unwrap(), "null");
        assert_eq!(serde_json::to_string(&Value::Int(7)).unwrap(), "7");
        assert_eq!(serde_json::to_string(&Value::Text("hi".into())).unwrap(), "\"hi\"");
        let b = Value::Bytes {
            b64: "AA==".into(),
            len: 1,
        };
        assert_eq!(serde_json::to_string(&b).unwrap(), "{\"__bytes\":\"AA==\",\"len\":1}");
    }

    #[test]
    fn connspec_deserializes_auth_variants() {
        let j = r#"{"driver":"postgres","params":{"host":"h","port":"5432","database":"d"},
                    "auth":{"kind":"password","user":"u","password":"p"}}"#;
        let spec: ConnSpec = serde_json::from_str(j).unwrap();
        assert_eq!(spec.driver, "postgres");
        assert_eq!(spec.param("host").unwrap(), "h");
        assert_eq!(spec.port(5432), 5432);
        assert!(matches!(spec.auth, AuthSpec::Password { .. }));
    }
}
