// lvim-db-native/rpc: the transport — newline-delimited JSON on stdio.
//
// One JSON object per line. The Lua side sends REQUESTS; the daemon sends a
// RESPONSE per request (correlated by `id`) plus unsolicited NOTIFICATIONS
// (no id) for query state and logs. This is a minimal, OURS-only protocol (the
// only client is lvim-db's Lua), so it stays deliberately small rather than full
// JSON-RPC 2.0 envelope machinery.
//
//   request       {"id":N,"method":"…","params":{…}}
//   response ok   {"id":N,"ok":true,"result":{…}}
//   response err  {"id":N,"ok":false,"error":"…"}
//   notification  {"method":"…","params":{…}}

use serde::Deserialize;
use serde_json::json;

/// The protocol version. The Lua side accepts any daemon reporting `proto >=
/// PROTO_MIN` (the lvim-fuzzy ABI discipline applied to the RPC protocol), so a
/// newer daemon stays compatible with older Lua as long as this only grows
/// additively.
pub const PROTO: u32 = 1;

/// One decoded incoming request.
#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Serialize a successful response line.
pub fn response_ok(id: u64, result: serde_json::Value) -> String {
    json!({ "id": id, "ok": true, "result": result }).to_string()
}

/// Serialize an error response line.
pub fn response_err(id: u64, error: &str) -> String {
    json!({ "id": id, "ok": false, "error": error }).to_string()
}

/// Serialize a notification line (no id).
pub fn notification(method: &str, params: serde_json::Value) -> String {
    json!({ "method": method, "params": params }).to_string()
}
