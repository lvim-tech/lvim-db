// lvim-db-daemon: the out-of-process database backend for lvim-db.
//
// Neovim spawns this binary and speaks newline-delimited JSON (see rpc.rs) over
// its stdin/stdout. A tokio multi-thread runtime drives every driver's async
// I/O; each incoming request is handled on its own task, so a slow query never
// blocks the handshake, another connection, or a cancel. A single writer task
// serialises all output lines (responses + notifications) so they never
// interleave. When stdin reaches EOF (Neovim exited) the daemon shuts down.
//
// The daemon is CRASH-ISOLATED from the editor: a driver panic or a C-dependency
// abort takes down this process, not Neovim — the Lua side notices the pipe
// close, notifies, and can respawn.

mod driver;
mod drivers;
mod net;
mod registry;
mod rpc;
mod secret;
mod server;
mod spec;
#[cfg(feature = "tls")]
mod tls;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::rpc::Request;
use crate::server::Server;

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    // Install the process-wide rustls crypto provider once, before any TLS use.
    #[cfg(feature = "tls")]
    tls::install_crypto_provider();

    // The single output writer: every task sends its response/notification line
    // here, and this task writes them to stdout in order.
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if stdout.write_all(b"\n").await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    let server = Server::new(tx);

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match serde_json::from_str::<Request>(line) {
            Ok(req) => {
                let server = server.clone();
                tokio::spawn(async move {
                    server.handle(req).await;
                });
            }
            Err(_) => {
                // A malformed line has no id to correlate a response to; ignore it
                // rather than guessing (the Lua side only sends well-formed JSON).
            }
        }
    }

    // stdin closed → Neovim is gone. Drop the server (closing connections' tasks
    // as their Arcs die) and let the writer drain.
    drop(server);
    let _ = writer.await;
}
