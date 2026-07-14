# lvim-db

A full database client for Neovim — connections, schema browsing, a query editor,
a paged results grid, and a call log — backed by an **out-of-process Rust daemon**.

Unlike an in-process approach, the database work runs in a separate `lvim-db-daemon`
process that Neovim spawns once and talks to over newline-delimited JSON-RPC on
stdio. Database drivers need an async runtime, connection pools, TLS and query
cancellation, and a driver (or a native C dependency) crashing must take down the
daemon — **not the editor**. If the daemon binary is not built the plugin still
loads and every action degrades gracefully with a single notification.

Database types are **plugin types**: each driver lives behind one trait + a
registry in the Rust backend, and the Lua side discovers the available drivers
(and builds each connection form) from the backend at runtime — so a new database
type is added without touching the core or any Lua.

Connections are **encrypted by default** — every network driver negotiates real
rustls TLS, and an SSH tunnel provides an encrypted channel for engines without
native TLS. A plaintext link is never silent (see Encryption below).

## Databases

The standard build ships these driver kinds (all behind one uniform trait):

PostgreSQL, MariaDB, MySQL, MongoDB, SQLite, DuckDB, SQL Server, Redis,
ClickHouse, Cassandra, ScyllaDB, CockroachDB, Firebird (pure-Rust wire
protocol), Snowflake (HTTP SQL REST API) — 14 driver kinds in the standard
build.

Oracle is available as an opt-in build feature (it needs the Oracle Instant Client
at runtime, so it is excluded from the self-contained standard build):

```sh
sh native/build.sh --features oracle
```

## Requirements

- Neovim 0.10+
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) — palette, store, UI helpers
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) — the windowed UI primitives
- A Rust toolchain (`cargo`) to build the daemon
- `sqlite.lua` (optional) — enables saved connections + query history

## Install

Install with the lvim-tech installer (**lvim-installer**) or Neovim's native
`vim.pack`, then build the daemon.

Native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-db" },
})

require("lvim-db").setup()
```

Then build the backend once (from the plugin directory):

```sh
sh native/build.sh
```

This compiles `lvim-db-daemon` into `native/build/` (git-ignored). Run
`:checkhealth lvim-db` to confirm the backend is found and to see the driver set
it was built with.

## Configuration

`setup()` merges your options into the live config. The full default config:

```lua
require("lvim-db").setup({
    -- Absolute path to the daemon binary. nil ⇒ probe: $LVIM_DB_DAEMON, then the
    -- plugin's own native/build/, then native/target/release/ (a local dev build).
    daemon_path = nil,
    -- Rows the result grid pulls per page. The daemon buffers the whole result and
    -- serves slices, so this only bounds how much Neovim holds/redraws at once.
    page_size = 200,
    -- Default window layout for lvim-db's UI surfaces: "area" | "float" | "bottom".
    layout = "area",
    -- Width (columns) of the connections drawer side panel.
    drawer_width = 36,
    -- Prompt before running a statement that matches destructive_patterns.
    confirm_destructive = true,
    -- Case-insensitive Lua patterns marking a statement as destructive. By default:
    -- any DROP/TRUNCATE, and a DELETE/UPDATE with no WHERE clause.
    destructive_patterns = {
        "^%s*drop%s",
        "^%s*truncate%s",
        "^%s*delete%s+from%s+[^;]-%s*;?%s*$",
        "^%s*update%s+[^;]-%s+set%s+[^;]-%s*;?%s*$",
    },
    -- Per-connection scratch notes live as real files here.
    -- nil ⇒ stdpath("state")/lvim-db/notes/<conn>/.
    notes_dir = nil,
    -- lvim-db's OWN store (saved connections + query history) — its own SQLite db.
    -- nil ⇒ stdpath("data")/lvim-db/.
    data_dir = nil,
    -- Abandon a connect/handshake that takes longer than this (ms).
    connect_timeout_ms = 15000,
    -- Notify once (INFO) the first time an action needs the daemon but it is not built.
    warn_on_missing = true,
    -- The keys lvim-db binds INSIDE its own panels (buffer-local — nothing global is
    -- touched). Remap any of them, or set one to `false` to leave it unbound.
    keys = {
        -- the connections drawer
        drawer = {
            help = "g?", -- the keymap CHEATSHEET (also a `help` chip on the drawer's bar)
            expand = "l", -- expand the row / connect
            collapse = "h", -- collapse the row / disconnect
            action = "<CR>", -- connect, expand, or preview a table's first rows
            add = "a", -- open the connection form (add)
            edit = "e", -- open the connection form on the focused connection
            delete = "x", -- delete the focused saved connection (confirmed)
            refresh = "r", -- re-read the focused connection's schema
            notes = "n", -- open the notes picker
            close = "q",
        },
        -- the result dock (grid + call log)
        result = {
            help = "g?", -- the keymap CHEATSHEET (also a `help` chip on the dock's bar)
            result_tab = "1", -- header button: the result view
            log_tab = "2", -- header button: the call-log view
            view_result = "r", -- body key: switch to the result view
            view_log = "L", -- body key: switch to the call-log view
            rerun = "<CR>", -- call log: re-run the focused call
            cancel = "x", -- call log: cancel the focused running call
            next_page = "n",
            prev_page = "p",
            yank = "y", -- yank the page as TSV
            export = "e",
            close = "q",
        },
        -- the connection form (one footer band per tab)
        form = {
            test = "t", -- test the ACTIVE tab's layer
            save = "s", -- save the connection (from any tab)
            close = "q",
        },
    },
})
```

Both panels carry a **`help` chip** on their bottom bar (`g?`): it opens the keymap CHEATSHEET —
every key of that panel, built from the live `keys` config above (rebind one and the cheatsheet
follows). `q` / `<Esc>` / `g?` close it.

The panel keys are deliberately **plain letters**: a key must survive the terminal and
the multiplexer to reach Neovim at all — a chord like `<C-s>` is tmux's default prefix in
many setups (and XON/XOFF flow control in others), so it can be swallowed upstream and
never arrive.

## Encryption (TLS + SSH tunnel)

Connections are encrypted by default. Every network driver negotiates real
**rustls TLS** (no OpenSSL), and the posture is set per connection with an
sslmode-style `tls.mode`:

| mode | meaning |
|---|---|
| `prefer` (default) | encrypt when the server supports it; a plaintext fallback is **surfaced**, never silent |
| `require` | encryption is mandatory — a plaintext-only server is **rejected** |
| `verify_ca` | require + verify the server certificate chain against the CA |
| `verify_full` | require + verify the chain **and** the hostname (strictest) |
| `disable` | explicit opt-out — the only unencrypted path |

`tls.ca` pins a CA certificate; `tls.client_cert` + `tls.client_key` enable
mutual **X.509** (client-certificate authentication). A connection that ends up
unencrypted is always surfaced — a warning notification, a `daemon.log` entry,
and an open-lock marker in the drawer — so plaintext is never silent.

For engines without native TLS (or as defence in depth for those with it), an
**SSH tunnel** (`tunnel`, via russh) forwards the connection over an encrypted
`direct-tcpip` channel — so even a plaintext database is reached only over an
encrypted link. Key, key+passphrase, password, and agent auth are supported. A
required tunnel is never silently bypassed: if the SSH session can't be
established, the connection fails.

```lua
-- example saved-connection spec (produced by :LvimDb add)
local example = {
    driver = "postgres",
    params = { host = "db.internal", port = "5432", database = "app" },
    auth = { kind = "password", user = "app", password = '{{ env "PGPASSWORD" }}' },
    tls = { mode = "verify_full", ca = "/etc/ssl/db-ca.pem" },
    tunnel = {
        host = "bastion.example.com",
        port = 22,
        user = "deploy",
        auth = { kind = "key", path = "~/.ssh/id_ed25519" },
    },
}
```

## Credentials

Passwords, key passphrases and tokens are stored as **templates**, resolved by the
daemon at connect time only — never persisted or logged as plain values:

- `{{ env "VAR" }}` — the value of an environment variable
- `{{ cmd "pass show db/prod" }}` — the stdout of a command (trimmed)
- literal text — used verbatim

This also covers token-style provider auth, e.g. an AWS RDS IAM token:
`{{ cmd "aws rds generate-db-auth-token …" }}`.

## Commands

- `:LvimDb open` — toggle the connections drawer (side panel)
- `:LvimDb add` — add a saved connection (the DriverMeta-driven `lvim-ui.tabs` form)
- `:LvimDb notes` — open the notes picker for a saved connection
- `:LvimDb log` — show the call-log tab in the result dock
- `:LvimDb close` — close the drawer and the result dock
- `:LvimDb status` — a one-line backend/store status snapshot
- `:LvimDb health` — open `:checkhealth lvim-db`

### Connection form

`:LvimDb add` (or `a` in the drawer; `e` edits) first picks the driver, then opens one
`lvim-ui.tabs` panel whose rows are built from that driver's `DriverMeta` — **Connection**,
**Auth**, and, for a networked engine, **Encryption** and **Tunnel**.

Each tab's footer carries the same two buttons:

- `t` — **test THIS tab's layer**, without saving anything. Every stage runs in the
  daemon (it owns the network, TLS and SSH), against the real machinery:
  - _Connection_ → the file is readable (SQLite / DuckDB), or `host:port` answers —
    dialled **through the SSH tunnel** when the spec configures one
  - _Auth_ → a full connect, reporting the identity the server accepted
  - _Encryption_ → a full connect, reporting the encryption posture (native TLS, tunnel,
    or a plaintext link — which fails the test)
  - _Tunnel_ → the SSH session authenticates and the local forward comes up on its own,
    so a bad host / key / passphrase is reported as a **tunnel** error, not a driver one
- `s` — **save** the connection (from any tab) and close the panel
- `q` — close without saving

A failing test leaves the panel open with everything typed so far, so it can be fixed and
retried. Secrets are saved as templates (see [Credentials](#credentials)), never resolved.

### Drawer keys

- `l` / `<CR>` — connect / expand a node (a table's `<CR>` previews its first rows)
- `h` — collapse / disconnect
- `a` — add · `e` — edit · `x` — delete · `r` — refresh schema · `n` — notes · `q` — close

### Result dock

Two tabs — the **result grid** and the **call log** — switchable with `1`/`2` (or `r`/`L`):

- Result: `n` / `p` — next / previous page · `y` — yank the page as TSV · `e` — export · `q` — close
- Call log: one row per call with a state accent (running / done / failed); `<CR>` re-runs a call,
  `x` cancels a running one.

### Notes / scratch SQL

Per-connection notes are real files under `stdpath("state")/lvim-db/notes/<conn>/` (opened as ordinary
`sql` buffers). In a note buffer the run maps execute SQL against that connection:

- `<Plug>(LvimDbRunBuffer)` — run the whole buffer (default `<localleader>r`)
- `<Plug>(LvimDbRunSelection)` — run the visual selection (default `<localleader>r` in visual mode)

Every free-text run passes the **destructive-statement guard**: a `DROP` / `TRUNCATE`, or a `DELETE` /
`UPDATE` with no `WHERE`, prompts a confirm before it executes (config `confirm_destructive`).

## How it works

```
Neovim (Lua)                         lvim-db-daemon (Rust, tokio)
  lvim-db.daemon  ── JSON-RPC ─────►  registry + Driver/Connection traits
  (spawn, stdio)  ◄── (stdout) ────   one driver per database type
                                       async connect / schema / execute / page / cancel
```

Every driver presents results as uniform, paged tables of typed cells, so the grid
renders any database identically. The whole result is buffered in the daemon and
paged out to Neovim a page at a time (the editor only ever holds one page).

## License

BSD-3-Clause. See `LICENSE`.
