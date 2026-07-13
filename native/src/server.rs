// lvim-db-native/server: request dispatch + the live daemon state.
//
// Holds the driver registry, the open connections (each behind its own async
// mutex, addressed by conn_id), and the running/finished calls (addressed by
// call_id). A `query.execute` returns its call_id IMMEDIATELY and runs the
// statement in a background task; when it finishes the task emits a `query.state`
// notification and the Lua side pages the buffered result. Cancellation uses the
// driver's detached cancel handle, so a running query can be stopped even while
// its connection is busy.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde::Deserialize;
use serde_json::{json, Value as Json};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::Mutex as AsyncMutex;

use crate::driver::{CancelHandle, Connection, ResultStream};
use crate::net::NetContext;
use crate::registry::Registry;
use crate::rpc::{self, Request};
use crate::spec::{AuthSpec, Column, ConnSpec, DriverMeta, ObjRef, ParamType, Value};

type Conn = Arc<AsyncMutex<Box<dyn Connection>>>;

/// How long `conn.test`'s endpoint stage waits for a TCP socket before calling
/// the host unreachable — long enough for a slow remote, short enough that a
/// blackholed address does not hang the form's Test button.
const DIAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Expand a leading `~` in a file-param path. The daemon is the one that opens
/// the file, so it — not the Lua form — resolves the shorthand the user typed.
fn expand_tilde(path: &str) -> String {
    match path.strip_prefix("~") {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => match std::env::var("HOME") {
            Ok(home) => format!("{home}{rest}"),
            Err(_) => path.to_string(),
        },
        _ => path.to_string(),
    }
}

/// A live connection plus the NetContext that owns its SSH tunnel (if any) — the
/// tunnel stays up as long as this entry lives, and is torn down on disconnect.
struct ConnEntry {
    conn: Conn,
    _net: NetContext,
}

/// The lifecycle of one executed statement.
#[derive(Clone, Copy, PartialEq, Eq)]
enum CallStatus {
    Running,
    Done,
    Failed,
    Cancelled,
}

impl CallStatus {
    fn as_str(&self) -> &'static str {
        match self {
            CallStatus::Running => "running",
            CallStatus::Done => "done",
            CallStatus::Failed => "failed",
            CallStatus::Cancelled => "cancelled",
        }
    }
}

/// One call's server-side state: its result stream, a growing buffer of pulled
/// rows (so the UI can page backwards), and a cancel handle while it runs.
struct Call {
    status: CallStatus,
    columns: Vec<Column>,
    stream: Option<Box<dyn ResultStream>>,
    buffer: Vec<Vec<Value>>,
    exhausted: bool,
    affected: Option<u64>,
    error: Option<String>,
    cancel: Option<Box<dyn CancelHandle>>,
}

impl Call {
    fn new() -> Self {
        Call {
            status: CallStatus::Running,
            columns: Vec::new(),
            stream: None,
            buffer: Vec::new(),
            exhausted: false,
            affected: None,
            error: None,
            cancel: None,
        }
    }
}

/// The daemon. Cloneable Arc handle shared by every dispatch task.
#[derive(Clone)]
pub struct Server {
    inner: Arc<Inner>,
}

struct Inner {
    registry: Registry,
    conns: Mutex<HashMap<u64, ConnEntry>>,
    calls: Mutex<HashMap<u64, Arc<AsyncMutex<Call>>>>,
    next_conn: AtomicU64,
    next_call: AtomicU64,
    out: UnboundedSender<String>,
}

impl Server {
    pub fn new(out: UnboundedSender<String>) -> Self {
        Server {
            inner: Arc::new(Inner {
                registry: Registry::new(),
                conns: Mutex::new(HashMap::new()),
                calls: Mutex::new(HashMap::new()),
                next_conn: AtomicU64::new(1),
                next_call: AtomicU64::new(1),
                out,
            }),
        }
    }

    fn send(&self, line: String) {
        let _ = self.inner.out.send(line);
    }

    fn conn(&self, id: u64) -> anyhow::Result<Conn> {
        self.inner
            .conns
            .lock()
            .unwrap()
            .get(&id)
            .map(|e| e.conn.clone())
            .ok_or_else(|| anyhow::anyhow!("no such connection {id}"))
    }

    /// Handle one request and emit its response line.
    pub async fn handle(&self, req: Request) {
        let id = req.id;
        let result = self.dispatch(&req.method, req.params).await;
        let line = match result {
            Ok(v) => rpc::response_ok(id, v),
            Err(e) => rpc::response_err(id, &e.to_string()),
        };
        self.send(line);
    }

    async fn dispatch(&self, method: &str, params: Json) -> anyhow::Result<Json> {
        match method {
            "rpc.hello" => self.hello(),
            "conn.connect" => self.connect(params).await,
            "conn.test" => self.test(params).await,
            "conn.disconnect" => self.disconnect(params).await,
            "conn.databases" => self.databases(params).await,
            "conn.switch_database" => self.switch_database(params).await,
            "schema.structure" => self.structure(params).await,
            "schema.columns" => self.columns(params).await,
            "query.execute" => self.execute(params).await,
            "query.page" => self.page(params).await,
            "query.cancel" => self.cancel(params).await,
            "query.cell" => self.cell(params).await,
            other => Err(anyhow::anyhow!("unknown method '{other}'")),
        }
    }

    // ── handshake ────────────────────────────────────────────────────────────

    fn hello(&self) -> anyhow::Result<Json> {
        Ok(json!({
            "proto": rpc::PROTO,
            "drivers": self.inner.registry.metas(),
        }))
    }

    // ── connections ──────────────────────────────────────────────────────────

    async fn connect(&self, params: Json) -> anyhow::Result<Json> {
        let spec: ConnSpec = serde_json::from_value(params)?;
        let driver = self.inner.registry.get(&spec.driver)?;
        let net = NetContext::new(spec.tunnel.clone());
        let conn = driver.connect(&spec, net.clone()).await?;
        // Encryption status: native TLS negotiated OR the link rides an SSH tunnel.
        let encrypted = conn.encrypted() || net.tunneled();
        let tunneled = net.tunneled();
        let id = self.inner.next_conn.fetch_add(1, Ordering::Relaxed);
        self.inner.conns.lock().unwrap().insert(
            id,
            ConnEntry {
                conn: Arc::new(AsyncMutex::new(conn)),
                _net: net,
            },
        );
        // Surface a clear warning when a network link ended up UNENCRYPTED (never
        // silent): the client shows it and health flags it.
        if !encrypted {
            self.send(rpc::notification(
                "daemon.log",
                json!({
                    "level": "warn",
                    "message": format!("connection {id} to driver '{}' is NOT encrypted (no TLS negotiated and no SSH tunnel)", spec.driver),
                }),
            ));
        }
        Ok(json!({ "conn_id": id, "encrypted": encrypted, "tunneled": tunneled }))
    }

    /// Dry-run ONE stage of a connection spec, without keeping anything open —
    /// what the form's per-tab Test button calls. Each stage exercises the REAL
    /// machinery of the layer it names (no simulation): the endpoint stage dials
    /// the TCP socket (through the SSH tunnel when one is configured), the tunnel
    /// stage stands the SSH forward up on its own, and the tls/auth stages open a
    /// full driver connection and close it again. An unusable spec surfaces as an
    /// RPC error carrying the underlying message — the client shows it verbatim.
    async fn test(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            stage: String,
            spec: ConnSpec,
        }
        let p: P = serde_json::from_value(params)?;
        let meta = self
            .inner
            .registry
            .metas()
            .into_iter()
            .find(|m| m.kind == p.spec.driver)
            .ok_or_else(|| anyhow::anyhow!("unknown driver '{}'", p.spec.driver))?;

        let started = Instant::now();
        let detail = match p.stage.as_str() {
            "endpoint" => Self::test_endpoint(&p.spec, meta).await?,
            "tunnel" => Self::test_tunnel(&p.spec, meta).await?,
            "tls" | "auth" => self.test_connect(&p.spec, &p.stage).await?,
            other => return Err(anyhow::anyhow!("unknown test stage '{other}'")),
        };
        Ok(json!({
            "ok": true,
            "ms": started.elapsed().as_millis() as u64,
            "detail": detail,
        }))
    }

    /// Endpoint stage — is the thing we would dial actually there? A file-backed
    /// driver (its meta declares a `File` param) checks the path; a TCP driver
    /// opens a socket to host:port, THROUGH the tunnel when one is configured (so
    /// a green endpoint on a tunnelled spec means the whole path is up). A driver
    /// with neither (an HTTPS API like Snowflake) has nothing to probe short of a
    /// real connect, and says so.
    async fn test_endpoint(spec: &ConnSpec, meta: &'static DriverMeta) -> anyhow::Result<String> {
        if let Some(fp) = meta.params.iter().find(|p| matches!(p.kind, ParamType::File)) {
            let raw = spec.param(fp.key)?;
            let path = expand_tilde(raw);
            let md = std::fs::metadata(&path).map_err(|e| anyhow::anyhow!("cannot stat '{path}': {e}"))?;
            if !md.is_file() {
                return Err(anyhow::anyhow!("'{path}' is not a regular file"));
            }
            std::fs::File::open(&path).map_err(|e| anyhow::anyhow!("cannot open '{path}' for reading: {e}"))?;
            return Ok(format!("{path} — readable, {} bytes", md.len()));
        }

        let Some(host) = spec.param_opt("host") else {
            return Err(anyhow::anyhow!(
                "'{}' has no TCP endpoint to probe — use the Auth tab's test (a full connect)",
                meta.kind
            ));
        };
        let port = spec.port(meta.default_port.unwrap_or(0));
        if port == 0 {
            return Err(anyhow::anyhow!("no port set and '{}' declares no default", meta.kind));
        }
        let net = NetContext::new(spec.tunnel.clone());
        let addr = net.resolve(host, port).await?;
        tokio::time::timeout(DIAL_TIMEOUT, tokio::net::TcpStream::connect(&addr))
            .await
            .map_err(|_| anyhow::anyhow!("timed out dialling {host}:{port} after {}s", DIAL_TIMEOUT.as_secs()))?
            .map_err(|e| anyhow::anyhow!("cannot reach {host}:{port}: {e}"))?;
        Ok(if net.tunneled() {
            format!("{host}:{port} reachable through the SSH tunnel (local {addr})")
        } else {
            format!("{host}:{port} reachable (plain TCP)")
        })
    }

    /// Tunnel stage — stand the SSH session + local forward up on their own, so a
    /// tunnel problem (host, user, key, passphrase) is reported as a TUNNEL error
    /// rather than hiding behind a driver connect failure. The forward is torn
    /// down when `net` drops at the end of this call.
    async fn test_tunnel(spec: &ConnSpec, meta: &'static DriverMeta) -> anyhow::Result<String> {
        let Some(t) = spec.tunnel.clone() else {
            return Err(anyhow::anyhow!("no SSH tunnel configured on this connection"));
        };
        // The forward needs a target: the DB endpoint the tunnel would front.
        let host = spec
            .param_opt("host")
            .ok_or_else(|| anyhow::anyhow!("a tunnel needs a host to forward to — fill the Connection tab first"))?;
        let port = spec.port(meta.default_port.unwrap_or(0));
        if port == 0 {
            return Err(anyhow::anyhow!("no port set and '{}' declares no default", meta.kind));
        }
        let user = t.user.clone();
        let (shost, sport) = (t.host.clone(), t.port);
        let net = NetContext::new(Some(t));
        let addr = net.resolve(host, port).await?;
        Ok(format!(
            "ssh {user}@{shost}:{sport} authenticated — forwarding {addr} → {host}:{port}"
        ))
    }

    /// TLS / auth stages — a REAL driver connect (tunnel, TLS handshake and
    /// credentials all exercised end to end), closed again immediately. The two
    /// stages differ only in what they report: the encryption posture, or the
    /// accepted identity.
    async fn test_connect(&self, spec: &ConnSpec, stage: &str) -> anyhow::Result<String> {
        let driver = self.inner.registry.get(&spec.driver)?;
        let net = NetContext::new(spec.tunnel.clone());
        let conn = driver.connect(spec, net.clone()).await?;
        let native = conn.encrypted();
        let tunneled = net.tunneled();
        let _ = conn.close().await;

        if stage == "tls" {
            return Ok(match (native, tunneled) {
                (true, true) => "encrypted — native TLS negotiated, and the link also rides the SSH tunnel".into(),
                (true, false) => "encrypted — native TLS negotiated".into(),
                (false, true) => "encrypted — no native TLS, but the link rides the SSH tunnel".into(),
                (false, false) => {
                    return Err(anyhow::anyhow!(
                        "connected but the link is PLAINTEXT — no TLS negotiated and no SSH tunnel"
                    ))
                }
            });
        }
        let who = match &spec.auth {
            AuthSpec::None => "no credentials (anonymous)".to_string(),
            AuthSpec::Password { user, .. } => format!("password auth accepted for '{user}'"),
            AuthSpec::ClientCert { user, .. } if !user.is_empty() => {
                format!("client-certificate auth accepted for '{user}'")
            }
            AuthSpec::ClientCert { .. } => "client-certificate auth accepted".to_string(),
            AuthSpec::Provider { provider, user, .. } if !user.is_empty() => {
                format!("{provider} token accepted for '{user}'")
            }
            AuthSpec::Provider { provider, .. } => format!("{provider} token accepted"),
            AuthSpec::Kerberos { principal } => match principal {
                Some(p) => format!("kerberos accepted for '{p}'"),
                None => "kerberos accepted".to_string(),
            },
        };
        Ok(format!(
            "connected — {who}; link {}",
            if native || tunneled { "encrypted" } else { "PLAINTEXT" }
        ))
    }

    async fn disconnect(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
        }
        let p: P = serde_json::from_value(params)?;
        let entry = self.inner.conns.lock().unwrap().remove(&p.conn_id);
        if let Some(entry) = entry {
            // Reclaim the Box out of the Arc<Mutex> to call the by-value close().
            // Dropping `entry._net` afterwards tears down any SSH tunnel.
            if let Ok(mutex) = Arc::try_unwrap(entry.conn) {
                let boxed = mutex.into_inner();
                let _ = boxed.close().await;
            }
        }
        Ok(json!({}))
    }

    async fn databases(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
        }
        let p: P = serde_json::from_value(params)?;
        let conn = self.conn(p.conn_id)?;
        let dbs = conn.lock().await.databases().await?;
        Ok(json!({ "databases": dbs }))
    }

    async fn switch_database(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
            database: String,
        }
        let p: P = serde_json::from_value(params)?;
        let conn = self.conn(p.conn_id)?;
        conn.lock().await.switch_database(&p.database).await?;
        Ok(json!({}))
    }

    // ── schema ───────────────────────────────────────────────────────────────

    async fn structure(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
        }
        let p: P = serde_json::from_value(params)?;
        let conn = self.conn(p.conn_id)?;
        let nodes = conn.lock().await.structure().await?;
        Ok(json!({ "nodes": nodes }))
    }

    async fn columns(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
            object: ObjRef,
        }
        let p: P = serde_json::from_value(params)?;
        let conn = self.conn(p.conn_id)?;
        let cols = conn.lock().await.columns(&p.object).await?;
        Ok(json!({ "columns": cols }))
    }

    // ── query ────────────────────────────────────────────────────────────────

    async fn execute(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            conn_id: u64,
            statement: String,
        }
        let p: P = serde_json::from_value(params)?;
        let conn = self.conn(p.conn_id)?;

        let call_id = self.inner.next_call.fetch_add(1, Ordering::Relaxed);
        let call = Arc::new(AsyncMutex::new(Call::new()));
        self.inner.calls.lock().unwrap().insert(call_id, call.clone());

        // Run the statement in the background; respond with the call_id now.
        let server = self.clone();
        tokio::spawn(async move {
            let started = Instant::now();
            let mut guard = conn.lock().await;
            // Register a cancel handle before running, so query.cancel can stop it.
            if let Some(tok) = guard.cancel_token() {
                call.lock().await.cancel = Some(tok);
            }
            let outcome = guard.execute(&p.statement).await;
            drop(guard);

            let ms = started.elapsed().as_millis() as u64;
            let mut c = call.lock().await;
            if c.status == CallStatus::Cancelled {
                server.notify_state(call_id, CallStatus::Cancelled, ms, None, None);
                return;
            }
            match outcome {
                Ok(stream) => {
                    c.columns = stream.columns().to_vec();
                    c.affected = stream.affected();
                    c.stream = Some(stream);
                    c.status = CallStatus::Done;
                    let affected = c.affected;
                    server.notify_state(call_id, CallStatus::Done, ms, None, affected);
                }
                Err(e) => {
                    c.status = CallStatus::Failed;
                    c.error = Some(e.to_string());
                    server.notify_state(call_id, CallStatus::Failed, ms, Some(e.to_string()), None);
                }
            }
        });

        Ok(json!({ "call_id": call_id }))
    }

    fn notify_state(&self, call_id: u64, status: CallStatus, ms: u64, error: Option<String>, affected: Option<u64>) {
        let mut params = json!({
            "call_id": call_id,
            "state": status.as_str(),
            "ms": ms,
        });
        if let Some(e) = error {
            params["error"] = json!(e);
        }
        if let Some(a) = affected {
            params["affected"] = json!(a);
        }
        self.send(rpc::notification("query.state", params));
    }

    fn call(&self, id: u64) -> anyhow::Result<Arc<AsyncMutex<Call>>> {
        self.inner
            .calls
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no such call {id}"))
    }

    async fn page(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            call_id: u64,
            #[serde(default)]
            from: usize,
            #[serde(default = "default_n")]
            n: usize,
        }
        let p: P = serde_json::from_value(params)?;
        let call = self.call(p.call_id)?;
        let mut c = call.lock().await;

        match c.status {
            CallStatus::Running => return Ok(json!({ "ready": false })),
            CallStatus::Failed => {
                return Err(anyhow::anyhow!(c.error.clone().unwrap_or_else(|| "query failed".into())))
            }
            CallStatus::Cancelled => return Err(anyhow::anyhow!("query was cancelled")),
            CallStatus::Done => {}
        }

        // Pull from the stream into the buffer until it holds `from + n` rows
        // (or the stream is exhausted) — this supports backward paging too.
        let need = p.from + p.n;
        while !c.exhausted && c.buffer.len() < need {
            let want = need - c.buffer.len();
            let pulled = match c.stream.as_mut() {
                Some(s) => s.next_page(want).await?,
                None => break,
            };
            match pulled {
                Some(mut rows) => c.buffer.append(&mut rows),
                None => c.exhausted = true,
            }
        }

        let total = if c.exhausted { Some(c.buffer.len()) } else { None };
        let start = p.from.min(c.buffer.len());
        let end = need.min(c.buffer.len());
        let rows = &c.buffer[start..end];
        let has_more = !c.exhausted || end < c.buffer.len();

        Ok(json!({
            "ready": true,
            "columns": c.columns,
            "rows": rows,
            "from": start,
            "has_more": has_more,
            "total": total,
            "affected": c.affected,
        }))
    }

    async fn cancel(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            call_id: u64,
        }
        let p: P = serde_json::from_value(params)?;
        let call = self.call(p.call_id)?;
        let handle = {
            let mut c = call.lock().await;
            if c.status == CallStatus::Running {
                c.status = CallStatus::Cancelled;
            }
            c.cancel.take()
        };
        if let Some(h) = handle {
            h.cancel().await?;
        }
        Ok(json!({}))
    }

    async fn cell(&self, params: Json) -> anyhow::Result<Json> {
        #[derive(Deserialize)]
        struct P {
            call_id: u64,
            row: usize,
            col: usize,
        }
        let p: P = serde_json::from_value(params)?;
        let call = self.call(p.call_id)?;
        let c = call.lock().await;
        let value = c.buffer.get(p.row).and_then(|r| r.get(p.col)).cloned();
        match value {
            Some(v) => Ok(json!({ "value": v })),
            None => Err(anyhow::anyhow!("cell out of range")),
        }
    }
}

fn default_n() -> usize {
    200
}
