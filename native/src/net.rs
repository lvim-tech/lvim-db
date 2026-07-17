// lvim-db-native/net: the network seam a driver dials through — plain or SSH.
//
// Every TCP driver asks the NetContext for the address to connect to. With no
// tunnel it returns the server's own host:port. With an SSH tunnel it stands up
// a LOCAL forwarder (a 127.0.0.1 listener) whose every accepted connection is
// bridged over an SSH `direct-tcpip` channel to the real DB endpoint — so the
// driver dials a local port and its whole DB conversation rides an ENCRYPTED SSH
// channel, with ZERO per-driver code. This is the encrypted path for engines
// with no native TLS (and a defence-in-depth option for those that have it).
//
// A required tunnel is NEVER silently bypassed: if the SSH session can't be
// established, connect fails rather than falling back to a direct link.

#[cfg(feature = "tunnel")]
use std::sync::Arc;

use crate::spec::TunnelSpec;

/// Resolves the address a driver should dial, applying an SSH tunnel when one is
/// configured. Cheap to clone/pass by value; the established tunnel (if any) is
/// held behind a shared cell and moved out by the server to live for the whole
/// connection.
#[derive(Clone, Default)]
pub struct NetContext {
    tunnel: Option<TunnelSpec>,
    #[cfg(feature = "tunnel")]
    established: Arc<tokio::sync::Mutex<Option<tunnel::TunnelGuard>>>,
}

impl NetContext {
    pub fn new(tunnel: Option<TunnelSpec>) -> Self {
        Self {
            tunnel,
            #[cfg(feature = "tunnel")]
            established: Arc::new(tokio::sync::Mutex::new(None)),
        }
    }

    /// The `host:port` a TCP driver should connect to for the server endpoint
    /// `(host, port)` — the endpoint itself, or a local forwarded port when an
    /// SSH tunnel is configured (established lazily on first use, then reused).
    pub async fn resolve(&self, host: &str, port: u16) -> anyhow::Result<String> {
        match &self.tunnel {
            None => Ok(format!("{host}:{port}")),
            #[cfg(feature = "tunnel")]
            Some(spec) => {
                let mut guard = self.established.lock().await;
                if guard.is_none() {
                    *guard = Some(tunnel::TunnelGuard::open(spec, host, port).await?);
                }
                Ok(guard.as_ref().unwrap().local_addr().to_string())
            }
            #[cfg(not(feature = "tunnel"))]
            Some(_) => Err(anyhow::anyhow!(
                "this daemon build has no SSH-tunnel support (build with the 'tunnel' feature)"
            )),
        }
    }

    /// Whether this context carries an SSH tunnel (its link is encrypted end to
    /// end regardless of the driver's native TLS).
    pub fn tunneled(&self) -> bool {
        self.tunnel.is_some()
    }
}

#[cfg(feature = "tunnel")]
mod tunnel {
    use std::sync::Arc;

    use russh::client::{self, Handler};
    use russh::keys::PublicKey;
    use tokio::net::TcpListener;

    use crate::spec::{TunnelAuth, TunnelSpec};

    /// A running SSH local-forward. Holds the SSH session + the accept task; on
    /// drop the task is aborted and the session closes.
    pub struct TunnelGuard {
        local_addr: String,
        task: tokio::task::JoinHandle<()>,
        _session: Arc<client::Handle<ClientHandler>>,
    }

    impl Drop for TunnelGuard {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    impl TunnelGuard {
        pub fn local_addr(&self) -> &str {
            &self.local_addr
        }

        /// Establish the SSH session, authenticate, and start forwarding a fresh
        /// local port to `(db_host, db_port)` over the tunnel.
        pub async fn open(spec: &TunnelSpec, db_host: &str, db_port: u16) -> anyhow::Result<Self> {
            let config = Arc::new(client::Config::default());
            let mut session =
                client::connect(config, (spec.host.as_str(), spec.port), ClientHandler)
                    .await
                    .map_err(|e| {
                        anyhow::anyhow!("ssh connect to {}:{} failed: {e}", spec.host, spec.port)
                    })?;

            // Authenticate with the chosen method.
            let authed = match &spec.auth {
                TunnelAuth::Password { password } => {
                    let pw = password.resolve().await?;
                    session
                        .authenticate_password(&spec.user, pw)
                        .await
                        .map_err(|e| anyhow::anyhow!("ssh password auth failed: {e}"))?
                        .success()
                }
                TunnelAuth::Key { path, passphrase } => {
                    let pass = passphrase.resolve().await?;
                    let pass_opt = if pass.is_empty() {
                        None
                    } else {
                        Some(pass.as_str())
                    };
                    let key = russh::keys::load_secret_key(path, pass_opt)
                        .map_err(|e| anyhow::anyhow!("cannot load ssh key '{path}': {e}"))?;
                    let with_hash = russh::keys::PrivateKeyWithHashAlg::new(Arc::new(key), None);
                    session
                        .authenticate_publickey(&spec.user, with_hash)
                        .await
                        .map_err(|e| anyhow::anyhow!("ssh key auth failed: {e}"))?
                        .success()
                }
                TunnelAuth::Agent => {
                    let mut agent = russh::keys::agent::client::AgentClient::connect_env()
                        .await
                        .map_err(|e| anyhow::anyhow!("ssh agent unavailable: {e}"))?;
                    let identities = agent
                        .request_identities()
                        .await
                        .map_err(|e| anyhow::anyhow!("ssh agent has no identities: {e}"))?;
                    let mut ok = false;
                    for id in identities {
                        let res = session
                            .authenticate_publickey_with(&spec.user, id, None, &mut agent)
                            .await;
                        if let Ok(r) = res {
                            if r.success() {
                                ok = true;
                                break;
                            }
                        }
                    }
                    ok
                }
            };
            if !authed {
                return Err(anyhow::anyhow!("ssh authentication was rejected"));
            }

            let session = Arc::new(session);
            let listener = TcpListener::bind("127.0.0.1:0")
                .await
                .map_err(|e| anyhow::anyhow!("cannot bind local forward port: {e}"))?;
            let local_addr = listener.local_addr()?.to_string();

            let host = db_host.to_string();
            let sess = session.clone();
            let task = tokio::spawn(async move {
                loop {
                    let (mut inbound, _peer) = match listener.accept().await {
                        Ok(v) => v,
                        Err(_) => break,
                    };
                    let sess = sess.clone();
                    let host = host.clone();
                    tokio::spawn(async move {
                        // Each local connection gets its own direct-tcpip channel.
                        let channel = match sess
                            .channel_open_direct_tcpip(host, db_port as u32, "127.0.0.1", 0)
                            .await
                        {
                            Ok(c) => c,
                            Err(_) => return,
                        };
                        let mut stream = channel.into_stream();
                        let _ = tokio::io::copy_bidirectional(&mut inbound, &mut stream).await;
                    });
                }
            });

            Ok(TunnelGuard {
                local_addr,
                task,
                _session: session,
            })
        }
    }

    /// The SSH client handler. Server-key acceptance is permissive for now (the
    /// channel is still fully encrypted); strict known_hosts verification is a
    /// follow-up (noted in findings.md).
    pub struct ClientHandler;

    impl Handler for ClientHandler {
        type Error = russh::Error;

        async fn check_server_key(
            &mut self,
            _server_public_key: &PublicKey,
        ) -> Result<bool, Self::Error> {
            Ok(true)
        }
    }
}
