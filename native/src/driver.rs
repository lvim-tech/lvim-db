// lvim-db-native/driver: the extensible driver architecture — the centerpiece.
//
// A new DB type is added by writing ONE `drivers/<kind>.rs` that impls `Driver`
// (+ its `Connection` and `ResultStream`) and registering it in registry.rs
// behind a cargo feature. Nothing in the core, the RPC layer, or the Lua side
// changes: the Lua UI discovers driver kinds and builds each connection form
// from the `DriverMeta` returned by `rpc.hello`.
//
// Every driver — SQL or not — presents results as uniform tabular PAGES of
// `Value`, so the result grid renders them identically. Sync engines (sqlite,
// duckdb, oracle) live behind the same async traits via spawn_blocking.

use async_trait::async_trait;

use crate::net::NetContext;
use crate::spec::{Column, ConnSpec, DriverMeta, Index, Node, ObjRef, Value};

/// A registered database type. Immutable, cheap; holds the static metadata and
/// knows how to open a connection.
#[async_trait]
pub trait Driver: Send + Sync {
    /// Static metadata (kind, form params, accepted auth, capabilities).
    fn meta(&self) -> &'static DriverMeta;

    /// Open one connection. `net` has already resolved any SSH tunnel, so the
    /// driver dials the address `net` hands it — tunnelling is transparent.
    async fn connect(&self, spec: &ConnSpec, net: NetContext) -> anyhow::Result<Box<dyn Connection>>;
}

/// A live connection. Held server-side behind a mutex and addressed by a numeric
/// `conn_id`; mutable so stateful drivers (a current database, a session) work.
#[async_trait]
pub trait Connection: Send {
    /// Databases visible on this connection (for `MULTI_DB` drivers).
    async fn databases(&mut self) -> anyhow::Result<Vec<String>>;

    /// Switch the active database.
    async fn switch_database(&mut self, db: &str) -> anyhow::Result<()>;

    /// The schema → object tree (schemas, tables, views, collections …).
    async fn structure(&mut self) -> anyhow::Result<Vec<Node>>;

    /// The columns of one object.
    async fn columns(&mut self, obj: &ObjRef) -> anyhow::Result<Vec<Column>>;

    /// The indexes on one object (`Caps::indexes`). Defaults to "this engine has none to show" so a driver
    /// opts IN by implementing it — the same shape as `cancel_token` — rather than every driver being forced
    /// to write a stub. A driver that implements this MUST also set `Caps::indexes`, since the UI offers the
    /// helper off the capability, not off a probe.
    async fn indexes(&mut self, _obj: &ObjRef) -> anyhow::Result<Vec<Index>> {
        Ok(Vec::new())
    }

    /// The CREATE statement for one object (`Caps::ddl`), or `None` when the engine has no server-side way to
    /// produce it. Returning the engine's OWN answer is the whole point: re-assembling a CREATE from column
    /// metadata would silently drop constraints, defaults and storage clauses, and would read as authoritative
    /// while being wrong — so a driver that cannot ask the server for it does not claim the capability.
    async fn ddl(&mut self, _obj: &ObjRef) -> anyhow::Result<Option<String>> {
        Ok(None)
    }

    /// Execute a statement, returning a paged result stream.
    async fn execute(&mut self, stmt: &str) -> anyhow::Result<Box<dyn ResultStream>>;

    /// A protocol-level cancel handle for a running query, if the driver supports
    /// one (`Caps::cancel`). It uses a SEPARATE channel to the server, so it can
    /// cancel an in-flight statement even while this connection is busy. `None`
    /// on drivers with no cancellation.
    fn cancel_token(&self) -> Option<Box<dyn CancelHandle>> {
        None
    }

    /// Whether the link to the server is ENCRYPTED (native TLS negotiated, or the
    /// connection rides an SSH tunnel). Surfaced to the client so an unencrypted
    /// link is never silently accepted. Default false (embedded/local engines).
    fn encrypted(&self) -> bool {
        false
    }

    /// Close the connection, releasing its resources.
    async fn close(self: Box<Self>) -> anyhow::Result<()>;
}

/// A detachable cancel handle for one connection's running query. Held by the
/// daemon's call registry so `query.cancel` can stop a statement mid-flight.
#[async_trait]
pub trait CancelHandle: Send + Sync {
    async fn cancel(&self) -> anyhow::Result<()>;
}

/// A uniform, paged result. `columns()` is known once the stream is opened;
/// `next_page(n)` pulls up to `n` more rows (None = exhausted). The daemon
/// buffers pulled rows so the UI's pagination band can page backwards too.
#[async_trait]
pub trait ResultStream: Send {
    fn columns(&self) -> &[Column];

    /// The affected-row count for a non-query statement (INSERT/UPDATE/DDL), if
    /// the driver reports one and there are no result rows.
    fn affected(&self) -> Option<u64> {
        None
    }

    /// Pull up to `n` more rows. `Ok(None)` once the stream is exhausted.
    async fn next_page(&mut self, n: usize) -> anyhow::Result<Option<Vec<Vec<Value>>>>;
}
