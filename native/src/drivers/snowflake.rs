// lvim-db-native/drivers/snowflake: the Snowflake driver (HTTP SQL REST API).
//
// Snowflake has no native wire protocol — it is HTTP + JSON. Auth folds into the
// AuthSpec model: KEY-PAIR JWT (a PEM private key file → an RS256 token via
// snowflake-jwt) or an OAuth BEARER token. Statements POST to /api/v2/statements
// and the `resultSetMetaData.rowType` + `data` give dynamic columns + rows.
// NOTE: implemented and compile-checked, but NOT runtime-verified (Snowflake is a
// cloud service; no account was available in this build environment).

use async_trait::async_trait;
use serde::Deserialize;

use crate::driver::{Connection, Driver, ResultStream};
use crate::net::NetContext;
use crate::spec::{
    AuthKind, AuthSpec, Caps, Column, ConnSpec, DriverMeta, Node, ObjRef, ParamSpec, ParamType, Value,
};

const PARAMS: &[ParamSpec] = &[
    ParamSpec {
        key: "account",
        label: "Account identifier",
        kind: ParamType::String,
        required: true,
        secret: false,
        default: None,
    },
    ParamSpec {
        key: "user",
        label: "User",
        kind: ParamType::String,
        required: true,
        secret: false,
        default: None,
    },
    ParamSpec {
        key: "database",
        label: "Database",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: None,
    },
    ParamSpec {
        key: "schema",
        label: "Schema",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: Some("PUBLIC"),
    },
    ParamSpec {
        key: "warehouse",
        label: "Warehouse",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: None,
    },
    ParamSpec {
        key: "role",
        label: "Role",
        kind: ParamType::String,
        required: false,
        secret: false,
        default: None,
    },
];

const META: DriverMeta = DriverMeta {
    kind: "snowflake",
    display: "Snowflake",
    default_port: None,
    // ClientCert = the key-pair JWT private-key file; Provider = an OAuth bearer token.
    auth: &[AuthKind::ClientCert, AuthKind::Provider],
    params: PARAMS,
    caps: Caps {
        sql: true,
        schemas: true,
        cancel: false,
        tls: true, // always HTTPS
        tunnel: false,
        multi_db: true,
        kv: false,
    },
};

/// The Snowflake driver.
pub struct SnowflakeDriver;

impl SnowflakeDriver {
    pub fn new() -> Self {
        SnowflakeDriver
    }
}

#[async_trait]
impl Driver for SnowflakeDriver {
    fn meta(&self) -> &'static DriverMeta {
        &META
    }

    async fn connect(&self, spec: &ConnSpec, _net: NetContext) -> anyhow::Result<Box<dyn Connection>> {
        let account = spec.param("account")?.to_string();
        let user = spec.param("user")?.to_string();

        // Build the bearer token + its type from the chosen auth method.
        let (token, token_type) = match &spec.auth {
            AuthSpec::ClientCert { key, .. } => {
                let pem = std::fs::read_to_string(key)
                    .map_err(|e| anyhow::anyhow!("snowflake: cannot read key file '{key}': {e}"))?;
                // Snowflake expects the full identifier "ACCOUNT.USER" (uppercase).
                let full_id = format!("{}.{}", account.to_uppercase(), user.to_uppercase());
                let jwt = snowflake_jwt::generate_jwt_token(&pem, &full_id)
                    .map_err(|e| anyhow::anyhow!("snowflake: JWT generation failed: {e}"))?;
                (jwt, "KEYPAIR_JWT")
            }
            AuthSpec::Provider { token, .. } => (token.resolve().await?, "OAUTH"),
            _ => return Err(anyhow::anyhow!("Snowflake requires key-pair (JWT) or OAuth auth")),
        };

        let conn = SnowflakeConnection {
            client: reqwest::Client::new(),
            base: format!("https://{account}.snowflakecomputing.com"),
            token,
            token_type: token_type.to_string(),
            database: spec.param_opt("database").map(|s| s.to_string()),
            schema: spec.param_opt("schema").map(|s| s.to_string()),
            warehouse: spec.param_opt("warehouse").map(|s| s.to_string()),
            role: spec.param_opt("role").map(|s| s.to_string()),
        };
        conn.query("SELECT 1").await?; // validate the credentials/endpoint
        Ok(Box::new(conn))
    }
}

/// The relevant slice of a Snowflake statements response.
#[derive(Deserialize)]
struct SfResponse {
    #[serde(rename = "resultSetMetaData")]
    result_set_meta_data: Option<SfMeta>,
    data: Option<Vec<Vec<Option<String>>>>,
    message: Option<String>,
}

#[derive(Deserialize)]
struct SfMeta {
    #[serde(rename = "rowType")]
    row_type: Vec<SfCol>,
}

#[derive(Deserialize)]
struct SfCol {
    name: String,
    #[serde(rename = "type")]
    type_name: String,
}

/// A live Snowflake "connection" (stateless HTTP + a bearer token).
struct SnowflakeConnection {
    client: reqwest::Client,
    base: String,
    token: String,
    token_type: String,
    database: Option<String>,
    schema: Option<String>,
    warehouse: Option<String>,
    role: Option<String>,
}

impl SnowflakeConnection {
    async fn query(&self, sql: &str) -> anyhow::Result<(Vec<Column>, Vec<Vec<Value>>)> {
        let mut body = serde_json::json!({ "statement": sql, "timeout": 60 });
        if let Some(d) = &self.database {
            body["database"] = serde_json::json!(d);
        }
        if let Some(s) = &self.schema {
            body["schema"] = serde_json::json!(s);
        }
        if let Some(w) = &self.warehouse {
            body["warehouse"] = serde_json::json!(w);
        }
        if let Some(r) = &self.role {
            body["role"] = serde_json::json!(r);
        }

        let resp = self
            .client
            .post(format!("{}/api/v2/statements", self.base))
            .bearer_auth(&self.token)
            .header("X-Snowflake-Authorization-Token-Type", &self.token_type)
            .header("Accept", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("snowflake request failed: {e}"))?;

        let status = resp.status();
        let parsed: SfResponse = resp
            .json()
            .await
            .map_err(|e| anyhow::anyhow!("bad snowflake response: {e}"))?;
        if !status.is_success() {
            return Err(anyhow::anyhow!(parsed
                .message
                .unwrap_or_else(|| format!("snowflake error {status}"))));
        }

        let columns = parsed
            .result_set_meta_data
            .map(|m| {
                m.row_type
                    .into_iter()
                    .map(|c| Column {
                        name: c.name,
                        type_name: c.type_name,
                    })
                    .collect()
            })
            .unwrap_or_default();
        let rows = parsed
            .data
            .unwrap_or_default()
            .into_iter()
            .map(|r| {
                r.into_iter()
                    .map(|cell| match cell {
                        Some(s) => Value::Text(s),
                        None => Value::Null,
                    })
                    .collect()
            })
            .collect();
        Ok((columns, rows))
    }

    async fn string_column(&self, sql: &str) -> anyhow::Result<Vec<String>> {
        let (_c, rows) = self.query(sql).await?;
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
impl Connection for SnowflakeConnection {
    async fn databases(&mut self) -> anyhow::Result<Vec<String>> {
        self.string_column("SELECT DATABASE_NAME FROM INFORMATION_SCHEMA.DATABASES ORDER BY DATABASE_NAME")
            .await
    }

    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()> {
        self.database = Some(db.to_string());
        Ok(())
    }

    async fn structure(&mut self) -> anyhow::Result<Vec<Node>> {
        let (_c, rows) = self
            .query(
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

    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Column>> {
        let schema_pred = match &obj.schema {
            Some(s) => format!("AND TABLE_SCHEMA = '{}'", s.replace('\'', "''")),
            None => String::new(),
        };
        let sql = format!(
            "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS \
             WHERE TABLE_NAME = '{}' {} ORDER BY ORDINAL_POSITION",
            obj.name.replace('\'', "''"),
            schema_pred
        );
        let (_c, rows) = self.query(&sql).await?;
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

    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>> {
        let (columns, rows) = self.query(stmt).await?;
        Ok(Box::new(super::buffered::BufferedStream::new(columns, rows, None)))
    }

    fn encrypted(&self) -> bool {
        true // Snowflake is always HTTPS
    }

    async fn close(self: Box<Self>) -> anyhow::Result<()> {
        Ok(())
    }
}
