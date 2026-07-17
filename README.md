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
            collapse = "h", -- collapse the row (visual only — keeps the live link)
            disconnect = "<C-q>", -- close the live connection on the focused connection row
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

- `:LvimDb open` — open the db **workspace**: the whole client moves into its own dedicated
  tabpage — a top row of the connections drawer (top-left) and the query editor (top-right), with
  the result as a **full-width** dock along the bottom — never drawn over your code.
  Idempotent — a second `open` just switches to the tab.
- `:LvimDb toggle` — toggle the workspace tab (open ⇄ close), keeping the session state.
- `:LvimDb close` — close the workspace tab and return to where you were. The in-memory session
  (the drawer's expanded/connected connections and the current result/call log) is **preserved**,
  so the next `open`/`toggle` restores the workspace exactly as you left it.
- `:LvimDb add` — add a saved connection (the DriverMeta-driven `lvim-ui.tabs` form)
- `:LvimDb notes` — open the notes picker for a saved connection
- `:LvimDb log` — show the call-log tab in the result dock
- `:LvimDb status` — a one-line backend/store status snapshot
- `:LvimDb health` — open `:checkhealth lvim-db`

### Browsing an object

Expanding a table / view / collection shows its **facets** — one row per thing you can ask about it — and
each facet either opens or acts:

```
users
   Data          run a bounded preview into the result dock
  Columns        expands to the columns, with their types
  Indexes        expands to the indexes: name, unique/pk, and the columns (in index order)
   DDL           load the object's CREATE statement into the SQL editor
```

`Indexes` and `DDL` appear **only where the driver has them**, from the capabilities the daemon reports —
so no engine grows a row that dead-ends. A document store has no `DDL`; PostgreSQL and SQL Server list
indexes but have no server-side `CREATE` statement to show (their tooling reconstructs it client-side);
Redis has neither.

| | indexes | DDL |
| --- | --- | --- |
| SQLite · MySQL · MariaDB · ClickHouse · DuckDB | ✓ | ✓ |
| PostgreSQL · SQL Server · MongoDB · Cassandra · Firebird | ✓ | — |
| Snowflake | — (micro-partitions) | ✓ |
| Redis | — | — |

### Changing a schema

On the schema rows, `a` / `e` / `x` mean what they already mean for a connection — add / edit / delete **the
thing under the cursor** — one tier down:

| row | `a` | `e` | `x` |
| --- | --- | --- | --- |
| `Columns` | add a column | — | — |
| a column | — | rename it | drop it |
| `Indexes` | create an index | — | — |
| an index | — | — | drop it |

Each **generates the statement into the SQL editor** in your engine's dialect — it never runs it. You read
it and run it yourself (where the destructive guard still applies). That is deliberate: `ALTER` dialects
diverge far more than `SELECT`, and some engines cannot do what a tidy form would imply — SQLite has no
`ALTER COLUMN` at all, so changing a column's type means rebuilding the table and copying the data. A
generated statement makes that impossible to do silently.

### The workspace tab

`:LvimDb open` hosts the client in its OWN tabpage (marked internally so it is always found again,
never over your buffers). Its three regions are **real tiled windows** in a two-row layout — a top
row of the tree (top-left) and the query editor (top-right), and a **full-width result** docked
along the bottom (spanning under both, so the tree shrinks to the top row and its footer stays
visible above the result). They navigate as **one coherent set**:

- `<C-j>` / `<C-k>` move between the top row and the result — from **either** the tree or the editor
  `<C-j>` **descends** onto the full-width result, and `<C-k>` from the result's top steps back up.
- `<C-h>` / `<C-l>` move between the tree and the editor in the top row.

Inside the drawer, `q` (close) tears the **whole workspace** down — so you never strand an empty
tab — while the result dock's `q` closes just the result panel and leaves you in the workspace.
The live database connections live in the daemon process, so closing and re-opening the workspace
never re-connects.

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
- `h` — collapse the row (visual only — does **not** drop the live link)
- `<C-q>` — **disconnect** the focused connection (closes the live link; the row flips back to
  the disconnected icon/colour)
- `a` — add · `e` — edit · `x` — delete · `r` — refresh schema · `n` — notes · `q` — close

The bottom **key-hint bar is context-aware**: on a disconnected connection it shows a `⏎ connect`
chip, on a connected one a `C-q disconnect` chip (plus the always-present help / close chips),
swapping as the cursor moves.

The tree carries a Nerd Font glyph per node kind — a **plug** for a disconnected connection that
becomes a **database** once connected (with a **lock** / **open-lock** suffix for the link's
encryption posture), a **sitemap** for a schema, a **table** / **eye** (view) / **cubes**
(collection) for its objects, and per-type glyphs for Redis keys. The four levels are each a
**distinct, readable colour** — connection (magenta → green when live), database/schema (blue),
objects (table yellow · view cyan · collection orange), and columns/fields (full foreground) — so
they read apart at a glance. Every **container row** is also washed in a subtle **background tint of
its own colour** (connection magenta/green, schema blue, objects in their object colour with an
odd/even **zebra** depth so adjacent same-type objects stay apart); column/field rows stay plain (the
leaf tier, so the washed containers stand out). The wash is **background-only** (`LvimDbBg*` groups),
so each row's fg + devicon read intact over it. The **cursor row** is marked on every kind by a
stronger background-only tint (`LvimDbRowSel`) — all groups are config-overridable. The hardware
cursor is hidden while the panel is focused (shown again in the code beside it).

### Result dock

A bottom dock with **no drawn border** — a blank breathing inset (the shared `content_border`
ring) rather than a box. Two tabs — the **result grid** and the **call log** — switchable with
`1`/`2` (or `r`/`L`):

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
