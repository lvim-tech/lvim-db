-- lvim-db: a full database client for Neovim, backed by an out-of-process Rust
-- daemon (native/), spoken to over JSON-RPC on stdio.
--
-- This module is the plugin's public entry point and the thin CLIENT layer over
-- the daemon: setup/config, connection open/close, schema browse, and statement
-- execution with paged results + a destructive-statement guard. The windowed UI
-- (drawer panel, connection form, result dock, call log) is built on top of this
-- API through lvim-ui in a later phase; everything here is UI-agnostic so it can
-- be driven headless and by that UI alike.
--
-- Extensible by construction: this file hardcodes NO database type. The set of
-- drivers comes from the daemon's rpc.hello (require("lvim-db").drivers()), and a
-- connection is just a driver kind + a param/auth/tls/tunnel spec — so a new DB
-- type added in the Rust backend appears here with no Lua change.
--
---@module "lvim-db"

local config = require("lvim-db.config")
local daemon = require("lvim-db.daemon")
local store = require("lvim-db.store")

local M = {}

---@type boolean whether the query.state router has been installed
local state_routed = false
---@type table<integer, fun(state: table)> call_id → state-notification callback
local call_watchers = {}

--- Install the single query.state notification router (idempotent). It fans each
--- notification out to the per-call watcher registered by `execute`.
local function ensure_state_router()
    if state_routed then
        return
    end
    state_routed = true
    daemon.on("query.state", function(params)
        if type(params) ~= "table" or params.call_id == nil then
            return
        end
        local cb = call_watchers[params.call_id]
        if cb then
            call_watchers[params.call_id] = nil
            pcall(cb, params)
        end
    end)
    -- On daemon death, fail every pending watcher so its call-log entry flips out of "running" (a stuck
    -- RUNNING row's cancel key would otherwise no-op forever) and the watcher table does not leak.
    daemon.on_teardown(function(err)
        local dead = call_watchers
        call_watchers = {}
        for _, cb in pairs(dead) do
            pcall(cb, { state = "failed", error = err or "daemon stopped" })
        end
    end)
end

-- ─── setup ───────────────────────────────────────────────────────────────────

--- Merge user options into the live config (in place).
---@param opts? LvimDbConfig
function M.setup(opts)
    local ok_utils, utils = pcall(require, "lvim-utils.utils")
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        for k, v in pairs(opts) do
            config[k] = v
        end
    end
    ensure_state_router()
    -- Surface daemon logs (notably the "NOT encrypted" warning) in the editor —
    -- the user's requirement that an unencrypted link is never silent.
    daemon.on("daemon.log", function(params)
        if type(params) ~= "table" or not params.message then
            return
        end
        local level = ({ warn = vim.log.levels.WARN, error = vim.log.levels.ERROR })[params.level]
            or vim.log.levels.INFO
        vim.schedule(function()
            vim.notify("lvim-db: " .. params.message, level)
        end)
    end)
    -- Self-theme from the live palette (re-applied on ColorScheme / palette sync).
    local ok_hl, hl = pcall(require, "lvim-utils.highlight")
    if ok_hl and hl.bind then
        hl.bind(require("lvim-db.highlights").build)
    end
    -- Register the `db/` parent with the wallet (if installed), so `:LvimKeyring` renders db connection
    -- secrets under a database icon + accent. pcall-guarded: lvim-db never hard-depends on lvim-keyring.
    pcall(function()
        require("lvim-keyring").register_namespace("db", { icon = "", accent = "red" })
    end)
    -- Self-register the plugin's PANELS with the shared cursor module as `panel_ft` (persistent side
    -- panels: the hardware cursor is hidden ONLY while the drawer / result dock is the CURRENT window, and
    -- shown again in the code beside it) — so the user's central cursor config need not name our filetypes.
    local ok_cursor, cursor = pcall(require, "lvim-utils.cursor")
    if ok_cursor and cursor.register then
        cursor.register({ panel_ft = { "lvim-db-drawer", "lvim-db-result" } })
    end
    require("lvim-db.commands").setup()
end

-- ─── introspection ───────────────────────────────────────────────────────────

--- The DriverMeta list the backend was built with (empty until the daemon is up;
--- pass `cb` to receive it after the handshake).
---@param cb? fun(drivers: table[], err: string?)
---@return table[]
function M.drivers(cb)
    if cb then
        daemon.ensure(function(ok, err)
            cb(ok and daemon.drivers() or {}, err)
        end)
    end
    return daemon.drivers()
end

--- A high-level status snapshot (for :checkhealth and :LvimDb status).
---@return { binary: string?, running: boolean, proto: integer?, drivers: integer, store: boolean }
function M.status()
    return {
        binary = daemon.binary_path(),
        running = daemon.is_running(),
        proto = daemon.proto(),
        drivers = #daemon.drivers(),
        store = store.available(),
    }
end

-- ─── connections ─────────────────────────────────────────────────────────────

--- Open a connection from a spec `{ driver, params, auth?, tls?, tunnel? }` (the
--- shape the connection form / a saved connection produces). `cb(conn_id, err)`.
--- A `{{ vault "…" }}` credential resolves in the daemon against the lvim-keyring agent; if the wallet
--- is locked, the KEYRING parks the resolve and pops its own master-password prompt (lvim-db does
--- nothing special — the wallet owns that), then the connect proceeds transparently.
---@param spec table
---@param cb fun(conn_id: integer?, err: string?, info: { encrypted: boolean, tunneled: boolean }?)
function M.connect(spec, cb)
    daemon.request("conn.connect", spec, function(result, err)
        if err or type(result) ~= "table" then
            cb(nil, err or "connect failed")
            return
        end
        cb(result.conn_id, nil, { encrypted = result.encrypted == true, tunneled = result.tunneled == true })
    end)
end

--- Open a SAVED connection by name (looked up in the store).
---@param name string
---@param cb fun(conn_id: integer?, err: string?, info: { encrypted: boolean, tunneled: boolean }?)
function M.connect_saved(name, cb)
    local conn = store.get_connection(name)
    if not conn then
        cb(nil, ("no saved connection named '%s'"):format(name))
        return
    end
    local spec = vim.tbl_extend("keep", { driver = conn.driver }, conn.spec or {})
    M.connect(spec, cb)
end

--- Dry-run ONE layer of a spec without opening anything that stays open — what
--- the connection form's per-tab Test button calls. The daemon owns the network,
--- TLS and SSH, so every stage is exercised THERE, against the real machinery:
---   • "endpoint" — the file is readable, or host:port answers (through the SSH
---                  tunnel when the spec carries one)
---   • "tunnel"   — the SSH session authenticates and the local forward comes up
---   • "tls"      — a full connect, reporting the encryption posture
---   • "auth"     — a full connect, reporting the accepted identity
--- `cb(detail, err, ms)`: on success `detail` is the human-readable outcome.
---@param spec table
---@param stage "endpoint"|"tunnel"|"tls"|"auth"
---@param cb fun(detail: string?, err: string?, ms: integer?)
function M.test(spec, stage, cb)
    daemon.request("conn.test", { stage = stage, spec = spec }, function(result, err)
        if err or type(result) ~= "table" then
            cb(nil, err or "test failed")
            return
        end
        cb(result.detail or "ok", nil, result.ms)
    end)
end

--- Close a connection.
---@param conn_id integer
---@param cb? fun(err: string?)
function M.disconnect(conn_id, cb)
    daemon.request("conn.disconnect", { conn_id = conn_id }, function(_, err)
        if cb then
            cb(err)
        end
    end)
end

--- List the databases visible on a connection.
---@param conn_id integer
---@param cb fun(databases: string[]?, err: string?)
function M.databases(conn_id, cb)
    daemon.request("conn.databases", { conn_id = conn_id }, function(result, err)
        cb(result and result.databases or nil, err)
    end)
end

--- Switch the active database on a connection.
---@param conn_id integer
---@param database string
---@param cb? fun(err: string?)
function M.switch_database(conn_id, database, cb)
    daemon.request("conn.switch_database", { conn_id = conn_id, database = database }, function(_, err)
        if cb then
            cb(err)
        end
    end)
end

-- ─── schema ──────────────────────────────────────────────────────────────────

--- The schema → object tree for a connection.
---@param conn_id integer
---@param cb fun(nodes: table[]?, err: string?)
function M.structure(conn_id, cb)
    daemon.request("schema.structure", { conn_id = conn_id }, function(result, err)
        cb(result and result.nodes or nil, err)
    end)
end

--- The columns of one object `{ name, schema? }`.
---@param conn_id integer
---@param object { name: string, schema: string? }
---@param cb fun(columns: table[]?, err: string?)
function M.columns(conn_id, object, cb)
    daemon.request("schema.columns", { conn_id = conn_id, object = object }, function(result, err)
        cb(result and result.columns or nil, err)
    end)
end

--- The indexes on one object `{ name, schema? }` — each `{ name, columns, unique, primary }`.
--- Only meaningful where the driver advertises `caps.indexes`; a driver without it answers with an empty
--- list (the daemon's trait default), so the caller gates on the CAPABILITY rather than on an empty reply —
--- "no indexes" and "cannot tell you" are different answers and must not render the same.
---@param conn_id integer
---@param object { name: string, schema: string? }
---@param cb fun(indexes: table[]?, err: string?)
function M.indexes(conn_id, object, cb)
    daemon.request("schema.indexes", { conn_id = conn_id, object = object }, function(result, err)
        cb(result and result.indexes or nil, err)
    end)
end

--- The CREATE statement for one object `{ name, schema? }`, or nil when the engine has none to give.
--- Gated on `caps.ddl` at the call site, for the same reason as `M.indexes`.
---@param conn_id integer
---@param object { name: string, schema: string? }
---@param cb fun(ddl: string?, err: string?)
function M.ddl(conn_id, object, cb)
    daemon.request("schema.ddl", { conn_id = conn_id, object = object }, function(result, err)
        cb(result and result.ddl or nil, err)
    end)
end

--- The capability set of a driver KIND (`caps.indexes` / `caps.ddl` / `caps.sql` …), from the daemon's
--- `rpc.hello` metadata. Empty table for an unknown kind, so a caller can index it without guarding.
--- The drawer offers a per-object helper ONLY where its driver claims the capability — so no engine ever
--- grows a row that dead-ends.
---@param kind string
---@return table
function M.caps(kind)
    for _, meta in ipairs(daemon.drivers() or {}) do
        if meta.kind == kind then
            return meta.caps or {}
        end
    end
    return {}
end

-- ─── statements ──────────────────────────────────────────────────────────────

--- Whether `statement` matches the configured destructive patterns (DROP /
--- TRUNCATE / unqualified DELETE|UPDATE). Callers gate on this to prompt first.
---@param statement string
---@return boolean
function M.is_destructive(statement)
    if not config.confirm_destructive then
        return false
    end
    local s = statement:lower()
    -- Always-destructive patterns (DROP / TRUNCATE).
    for _, pat in ipairs(config.destructive_patterns or {}) do
        if s:find(pat) then
            return true
        end
    end
    -- A DELETE / UPDATE with NO where clause is destructive (affects every row).
    -- "No WHERE" is a negative condition, so it can't be a single Lua pattern.
    if not s:find("%swhere[%s%(]") then
        if s:find("^%s*delete%s+from%s") then
            return true
        end
        if s:find("^%s*update%s+.-%sset%s") then
            return true
        end
    end
    return false
end

--- Execute a statement. Returns the `call_id` via `cb(call_id, err)` immediately;
--- when the statement finishes, `on_state(state)` fires with the query.state
--- notification (`{ state = "done"|"failed"|"cancelled", ms, affected?, error? }`).
--- Does NOT prompt — apply `is_destructive` + your own confirm before calling.
---@param conn_id integer
---@param statement string
---@param on_state fun(state: table)
---@param cb? fun(call_id: integer?, err: string?)
function M.execute(conn_id, statement, on_state, cb)
    ensure_state_router()
    daemon.request("query.execute", { conn_id = conn_id, statement = statement }, function(result, err)
        if err or type(result) ~= "table" then
            if cb then
                cb(nil, err or "execute failed")
            end
            return
        end
        call_watchers[result.call_id] = on_state
        if cb then
            cb(result.call_id, nil)
        end
    end)
end

--- Fetch a page of a finished call's result. `cb(page, err)` where page =
--- `{ ready, columns, rows, from, has_more, total?, affected? }` (ready=false
--- while the statement is still running — page again after its done state).
---@param call_id integer
---@param from integer  0-based row offset
---@param n integer?    rows to fetch (defaults to config.page_size)
---@param cb fun(page: table?, err: string?)
function M.page(call_id, from, n, cb)
    daemon.request("query.page", { call_id = call_id, from = from, n = n or config.page_size }, function(result, err)
        cb(result, err)
    end)
end

--- Fetch the full, untruncated value of one result cell (for yank/export).
---@param call_id integer
---@param row integer  0-based
---@param col integer  0-based
---@param cb fun(value: any, err: string?)
function M.cell(call_id, row, col, cb)
    daemon.request("query.cell", { call_id = call_id, row = row, col = col }, function(result, err)
        cb(result and result.value, err)
    end)
end

--- Release a finished call's server-side buffer (frees its paged rows on the daemon). Fire-and-forget.
---@param call_id integer
function M.release(call_id)
    daemon.request("query.release", { call_id = call_id }, function() end)
end

--- Cancel a running statement.
---@param call_id integer
---@param cb? fun(err: string?)
function M.cancel(call_id, cb)
    daemon.request("query.cancel", { call_id = call_id }, function(_, err)
        if cb then
            cb(err)
        end
    end)
end

--- The saved-connection / history store (require("lvim-db").store).
M.store = store

return M
