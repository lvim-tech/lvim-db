-- lvim-db.store: saved connections, saved queries and the call-log history.
--
-- These used to live HERE, in a Lua-side SQLite file, and that was the one thing
-- stopping lvim-db from sharing state with anything else: the editor had its own
-- list of connections, and a second client (the lode desktop GUI) would have had
-- its own. So the data moved into the ENGINE — `lode`'s `store.*` RPC, backed by
-- its own SQLite database — and this module became a thin client over it.
--
-- Two backends, chosen ONCE and then sticky:
--
--   • "engine"  the engine answers `store.status` and reports `proto >= 2`. The
--               engine owns the data; both clients see one set.
--   • "legacy"  no engine binary, or an engine too old to carry a store. The old
--               Lua-side SQLite file (through the shared `lvim-utils.store`
--               seam) is used exactly as before, so a user without a built
--               engine keeps every saved connection and loses nothing.
--
-- The CHOICE is made once per session rather than per call: the answer cannot
-- change while Neovim runs (an engine does not grow a store mid-session), and
-- re-deciding per call would mean a store that silently moved under the user
-- after a transient hiccup — the worst possible failure for data they expect to
-- find where they left it.
--
-- MIGRATION. The first time the engine backend is used, the legacy file (if
-- there is one) is imported into the engine — additively and idempotently, see
-- `store.import` in lode — and a marker is written so it is not attempted again.
-- THE LEGACY FILE IS ONLY READ. Nothing deletes it, so dropping back to an older
-- lvim-db still finds the data it expects.
--
-- The public API is SYNCHRONOUS, unchanged from when this was a local database:
-- every caller in the plugin (the drawer, the form, the editor, the result dock)
-- uses a return value in the next line. The RPC underneath is asynchronous, so
-- each call pumps the event loop with `vim.wait` until its answer lands. That is
-- affordable precisely because the engine's store is a LOCAL SQLite file on the
-- other side of a pipe — microseconds of work, not a network round trip — and it
-- keeps the change to this one file instead of rewriting six UI modules.
--
---@module "lvim-db.store"

local config = require("lvim-db.config")

local M = {}

-- The first protocol version whose engine carries the store (`store.*`).
local STORE_PROTO = 2

-- How long one store RPC may take before it is given up on. Generous for what
-- it is (a local SQLite statement), because the ONLY thing a shorter timeout
-- would buy is a half-answered UI.
local RPC_TIMEOUT_MS = 5000

---@type "engine"|"legacy"|"none"|nil  the resolved backend (nil = not yet decided)
local mode

-- ─── the legacy backend: the old Lua-side SQLite file ────────────────────────
--
-- Kept verbatim, schema and all, because it is still the live store for anyone
-- without a built engine AND the source the migration reads.

-- Bump on any schema change. v2 ADDED the `queries` table — a brand-new table needs no data
-- transform (its sqlite.tbl handle CREATEs it on open), so the bump only stamps the user_version.
local SCHEMA_VERSION = 2

local CONNECTIONS = "connections"
local HISTORY = "history"
local QUERIES = "queries"

local TABLES = {
    [CONNECTIONS] = {
        id = { "integer", primary = true, autoincrement = true },
        name = { "text", required = true, unique = true },
        driver = { "text", required = true },
        spec = { "text", required = true }, -- JSON: { params, auth, tls, tunnel }
        created = { "integer" },
    },
    [HISTORY] = {
        id = { "integer", primary = true, autoincrement = true },
        conn = { "text" }, -- connection name (nullable: ad-hoc runs)
        driver = { "text" },
        statement = { "text", required = true },
        state = { "text" }, -- "done" | "failed" | "cancelled"
        ms = { "integer" },
        rows = { "integer" },
        ts = { "integer" },
    },
    [QUERIES] = {
        id = { "integer", primary = true, autoincrement = true },
        conn = { "text", required = true }, -- connection name — the per-connection scope
        name = { "text", required = true }, -- the saved query's name (unique WITHIN a conn; enforced by upsert)
        sql = { "text", required = true }, -- the SQL body
        updated_at = { "integer" }, -- last save (unix seconds)
    },
}

---@type table? the live legacy store handle (nil until opened)
local legacy_store

--- The directory the legacy store lives in (also where the migration marker goes).
---@return string
local function legacy_dir()
    return config.data_dir or (vim.fn.stdpath("data") .. "/lvim-db")
end

--- Open the legacy store (idempotent). Returns the handle, or nil when sqlite is absent.
---@return table?
local function legacy_open()
    if legacy_store then
        return legacy_store
    end
    local ok, mod = pcall(require, "lvim-utils.store")
    if not ok then
        return nil
    end
    legacy_store = mod.new({
        backend = "sqlite",
        name = "lvim-db",
        dir = legacy_dir(),
        version = SCHEMA_VERSION,
        tables = TABLES,
        migrations = {}, -- filled as the schema evolves past v1
    })
    return legacy_store
end

--- Decode a stored row into a connection table with its spec parsed.
---@param row table
---@return LvimDbConnection
local function decode_conn(row)
    local ok, spec = pcall(vim.json.decode, row.spec or "{}")
    return {
        id = row.id,
        name = row.name,
        driver = row.driver,
        spec = ok and spec or {},
        created = row.created,
    }
end

local legacy = {}

function legacy.available()
    local s = legacy_open()
    return s ~= nil and s:is_open()
end

function legacy.list_connections()
    local s = legacy_open()
    if not s then
        return {}
    end
    local rows = s:find(CONNECTIONS)
    if type(rows) ~= "table" then
        return {}
    end
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = decode_conn(r)
    end
    table.sort(out, function(a, b)
        return (a.created or 0) > (b.created or 0)
    end)
    return out
end

function legacy.get_connection(name)
    local s = legacy_open()
    if not s then
        return nil
    end
    local rows = s:find(CONNECTIONS, { name = name })
    if type(rows) == "table" and rows[1] then
        return decode_conn(rows[1])
    end
    return nil
end

function legacy.save_connection(name, driver, spec)
    local s = legacy_open()
    if not s then
        return false
    end
    local payload = { driver = driver, spec = vim.json.encode(spec) }
    local existing = s:find(CONNECTIONS, { name = name })
    if type(existing) == "table" and existing[1] then
        return s:update(CONNECTIONS, { name = name }, payload)
    end
    payload.name = name
    payload.created = os.time()
    return s:insert(CONNECTIONS, payload) ~= false
end

function legacy.remove_connection(name)
    local s = legacy_open()
    if not s then
        return false
    end
    return s:remove(CONNECTIONS, { name = name })
end

function legacy.list_queries(conn)
    local s = legacy_open()
    if not s then
        return {}
    end
    local rows = s:find(QUERIES, { conn = conn })
    if type(rows) ~= "table" then
        return {}
    end
    table.sort(rows, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return rows
end

function legacy.get_query(conn, name)
    local s = legacy_open()
    if not s then
        return nil
    end
    local rows = s:find(QUERIES, { conn = conn, name = name })
    if type(rows) == "table" and rows[1] then
        return rows[1]
    end
    return nil
end

function legacy.save_query(conn, name, sql)
    local s = legacy_open()
    if not s then
        return false
    end
    local existing = s:find(QUERIES, { conn = conn, name = name })
    if type(existing) == "table" and existing[1] then
        return s:update(QUERIES, { conn = conn, name = name }, { sql = sql, updated_at = os.time() })
    end
    return s:insert(QUERIES, { conn = conn, name = name, sql = sql, updated_at = os.time() }) ~= false
end

function legacy.delete_query(conn, name)
    local s = legacy_open()
    if not s then
        return false
    end
    return s:remove(QUERIES, { conn = conn, name = name })
end

function legacy.record(entry)
    local s = legacy_open()
    if not s then
        return false
    end
    return s:insert(HISTORY, {
        conn = entry.conn,
        driver = entry.driver,
        statement = entry.statement,
        state = entry.state,
        ms = entry.ms,
        rows = entry.rows,
        ts = os.time(),
    }) ~= false
end

function legacy.history(limit)
    local s = legacy_open()
    if not s then
        return {}
    end
    local rows = s:find(HISTORY)
    if type(rows) ~= "table" then
        return {}
    end
    table.sort(rows, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    local n = limit or 200
    if #rows > n then
        for i = #rows, n + 1, -1 do
            rows[i] = nil
        end
    end
    return rows
end

-- ─── the engine backend ──────────────────────────────────────────────────────

--- One store RPC, waited on. Returns `result, err`.
---
--- `daemon.request` already ensures the engine is up, so this also covers the
--- very first call of a session (which carries the spawn + handshake, hence the
--- generous timeout).
---@param method string
---@param params table?
---@return table?, string?
local function rpc(method, params)
    local daemon = require("lvim-db.daemon")
    -- A SYNCHRONOUS call cannot be made from inside a daemon message handler.
    -- nvim delivers one message at a time per channel, so the answer to this
    -- request cannot arrive until the handler returns — and the handler is
    -- waiting for it. `vim.wait` then pumps the loop for nothing and gives up
    -- after RPC_TIMEOUT_MS, EVERY TIME. (Measured: five seconds on every single
    -- query, because the history write sits in the query's own state callback.)
    --
    -- Refusing immediately is the honest answer and the loud one: five seconds
    -- of nothing reads as "the database is slow", while this says what it is and
    -- where. A caller that does not need the answer uses `fire` instead.
    if daemon.dispatching() then
        return nil,
            ("store: '%s' cannot be waited for from inside a daemon callback — it would hang until it timed out"):format(
                method
            )
    end
    local done, result, err = false, nil, nil
    daemon.request(method, params, function(r, e)
        done, result, err = true, r, e
    end)
    if not vim.wait(RPC_TIMEOUT_MS, function()
        return done
    end, 5) then
        return nil, ("store: '%s' timed out after %dms"):format(method, RPC_TIMEOUT_MS)
    end
    return result, err
end

---@type boolean one-shot guard so a broken store is reported once, not per keystroke
local warned = false

--- Report a store failure ONCE per session. A store error is not worth a
--- notification per call — the drawer alone would raise a dozen opening a tree —
--- but it must not be silent either, or saved connections simply vanish with no
--- explanation.
---@param err string
local function warn_once(err)
    if warned then
        return
    end
    warned = true
    vim.schedule(function()
        vim.notify("lvim-db: saved state is unavailable — " .. tostring(err), vim.log.levels.WARN)
    end)
end

--- One store RPC that is NOT waited for. The answer only reports a failure, so
--- it is warned about and dropped.
---
--- For writes nobody reads back: a history row is written and the person carries
--- on. It is also the only shape that is safe from inside a daemon callback,
--- which is exactly where the history write happens.
---@param method string
---@param params table?
local function fire(method, params)
    require("lvim-db.daemon").request(method, params, function(_, err)
        if err then
            warn_once(err)
        end
    end)
end

--- Run one store RPC, warning once on failure. Returns the result or nil.
---@param method string
---@param params table?
---@return table?
local function call(method, params)
    local result, err = rpc(method, params)
    if err then
        warn_once(err)
        return nil
    end
    return result
end

--- Import the legacy Lua-side file into the engine, once.
---
--- Guarded by a marker file next to the legacy database rather than by a flag in
--- the engine: the engine's store is shared, and "has THIS client's old file been
--- imported" is a fact about this machine's lvim-db, not about the engine. The
--- import itself is idempotent anyway (see lode's `store.import`), so the marker
--- is an optimisation and a record, not the correctness guarantee.
local function migrate_once()
    local dir = legacy_dir()
    local marker = dir .. "/migrated-to-lode"
    if vim.uv.fs_stat(marker) then
        return
    end
    local legacy_db = dir .. "/lvim-db.db"
    if not vim.uv.fs_stat(legacy_db) then
        -- Nothing to migrate. Still mark it, so a later empty-file check is free.
        pcall(vim.fn.writefile, { "no legacy store to import" }, marker)
        return
    end
    local result, err = rpc("store.import", { path = legacy_db })
    if err or type(result) ~= "table" then
        -- Leave the marker ABSENT so the next session retries: a failed import
        -- must not be mistaken for a completed one.
        vim.schedule(function()
            vim.notify(
                "lvim-db: could not import the old saved state into the engine — " .. tostring(err),
                vim.log.levels.WARN
            )
        end)
        return
    end
    local n = (result.connections or 0) + (result.queries or 0) + (result.history or 0)
    pcall(vim.fn.writefile, {
        ("imported %d connection(s), %d saved quer(ies), %d history row(s) from %s on %s"):format(
            result.connections or 0,
            result.queries or 0,
            result.history or 0,
            legacy_db,
            os.date("%Y-%m-%d %H:%M:%S")
        ),
        "the source file was only READ — it is still there, untouched",
    }, marker)
    if n > 0 then
        vim.schedule(function()
            vim.notify(
                ("lvim-db: moved %d saved item(s) into the lode engine — they are now shared with any other lode client"):format(
                    n
                ),
                vim.log.levels.INFO
            )
        end)
    end
end

--- Decide which backend to use. Sticky: resolved once per session.
---@return "engine"|"legacy"|"none"
local function resolve()
    if mode then
        return mode
    end
    local daemon = require("lvim-db.daemon")
    if not daemon.binary_path() then
        -- No engine at all. The legacy file is the only store there is, and
        -- that is exactly the pre-engine behaviour.
        mode = legacy.available() and "legacy" or "none"
        return mode
    end
    local status, err = rpc("store.status", vim.empty_dict())
    local proto = daemon.proto() or 0
    if err or proto < STORE_PROTO or type(status) ~= "table" or not status.available then
        -- An engine that is there but has no usable store: fall back rather than
        -- lose the data. `err` is NOT warned here — a missing engine binary is a
        -- normal state the plugin already reports its own way.
        mode = legacy.available() and "legacy" or "none"
        return mode
    end
    mode = "engine"
    migrate_once()
    return mode
end

-- ─── public API ──────────────────────────────────────────────────────────────

--- Which backend is in use: "engine" (lode owns the data), "legacy" (the old
--- local file) or "none" (no persistence at all). Health reports it.
---@return "engine"|"legacy"|"none"
function M.backend()
    return resolve()
end

--- Whether persistence is available at all.
---@return boolean
function M.available()
    return resolve() ~= "none"
end

-- ─── connections ─────────────────────────────────────────────────────────────

---@class LvimDbConnection
---@field id integer
---@field name string
---@field driver string
---@field spec table  { params, auth, tls, tunnel } — secrets are templates
---@field created integer?

--- All saved connections, newest first.
---@return LvimDbConnection[]
function M.list_connections()
    local m = resolve()
    if m == "legacy" then
        return legacy.list_connections()
    elseif m == "none" then
        return {}
    end
    local r = call("store.connections.list")
    return (r and r.connections) or {}
end

--- One saved connection by name, or nil.
---@param name string
---@return LvimDbConnection?
function M.get_connection(name)
    local m = resolve()
    if m == "legacy" then
        return legacy.get_connection(name)
    elseif m == "none" then
        return nil
    end
    local r = call("store.connections.get", { name = name })
    -- `vim.NIL` is what a JSON null decodes to; a caller testing truthiness
    -- would take it for a found connection.
    local c = r and r.connection
    if c == nil or c == vim.NIL then
        return nil
    end
    return c
end

--- Insert or update a saved connection (keyed by `name`). Returns success.
---@param name string
---@param driver string
---@param spec table  { params, auth, tls, tunnel } — secrets kept as templates
---@return boolean
function M.save_connection(name, driver, spec)
    local m = resolve()
    if m == "legacy" then
        return legacy.save_connection(name, driver, spec)
    elseif m == "none" then
        return false
    end
    local r = call("store.connections.save", { name = name, driver = driver, spec = spec })
    return r ~= nil and r.saved == true
end

--- Delete a saved connection by name. Returns success.
---@param name string
---@return boolean
function M.remove_connection(name)
    local m = resolve()
    if m == "legacy" then
        return legacy.remove_connection(name)
    elseif m == "none" then
        return false
    end
    local r = call("store.connections.remove", { name = name })
    return r ~= nil and r.removed == true
end

-- ─── saved queries (per connection) ──────────────────────────────────────────

---@class LvimDbSavedQuery
---@field id integer
---@field conn string       the connection name this query is scoped to
---@field name string
---@field sql string
---@field updated_at integer?

--- All saved queries for a connection, ordered by name (stable for the tree listing).
---@param conn string  connection name
---@return LvimDbSavedQuery[]
function M.list_queries(conn)
    local m = resolve()
    if m == "legacy" then
        return legacy.list_queries(conn)
    elseif m == "none" then
        return {}
    end
    local r = call("store.queries.list", { conn = conn })
    return (r and r.queries) or {}
end

--- One saved query by (conn, name), or nil.
---@param conn string
---@param name string
---@return LvimDbSavedQuery?
function M.get_query(conn, name)
    local m = resolve()
    if m == "legacy" then
        return legacy.get_query(conn, name)
    elseif m == "none" then
        return nil
    end
    local r = call("store.queries.get", { conn = conn, name = name })
    local q = r and r.query
    if q == nil or q == vim.NIL then
        return nil
    end
    return q
end

--- Insert or update a saved query (keyed by the (conn, name) pair). Returns success.
---@param conn string
---@param name string
---@param sql string
---@return boolean
function M.save_query(conn, name, sql)
    local m = resolve()
    if m == "legacy" then
        return legacy.save_query(conn, name, sql)
    elseif m == "none" then
        return false
    end
    local r = call("store.queries.save", { conn = conn, name = name, sql = sql })
    return r ~= nil and r.saved == true
end

--- Delete a saved query by (conn, name). Returns success.
---@param conn string
---@param name string
---@return boolean
function M.delete_query(conn, name)
    local m = resolve()
    if m == "legacy" then
        return legacy.delete_query(conn, name)
    elseif m == "none" then
        return false
    end
    local r = call("store.queries.remove", { conn = conn, name = name })
    return r ~= nil and r.removed == true
end

-- ─── network profiles (tunnels, proxies, access providers) ───────────────────
--
-- A PROFILE is a reusable piece of network kept by NAME in the engine: an SSH
-- tunnel, a proxy, an access provider. Several connections point at one, and the
-- engine resolves it at connect time — a connection that names a missing profile
-- FAILS rather than quietly going direct.
--
-- They live in the engine and are shared with every other lode client, so this
-- is a reader, not a second home for them. Writing one is the desktop client's
-- job for now; what this client must not do is pretend they do not exist, which
-- is what it did before: the form showed "SSH tunnel: none" for a connection
-- tunnelled through a profile, and saving it threw the profile away.

---@class LvimDbProfile
---@field name string
---@field kind string   "tunnel" | "proxy" | "access" | "driver"
---@field spec table    the profile's own fields (an SSH tunnel's host/user/port/auth, …)

--- The saved profiles of one kind, as the ENGINE holds them.
---
--- Empty on a legacy store or no store at all: profiles have never lived
--- anywhere but the engine, so there is nothing to fall back to and an empty
--- list is the honest answer.
---@param kind "tunnel"|"proxy"|"access"|"driver"
---@return LvimDbProfile[]
function M.list_profiles(kind)
    if resolve() ~= "engine" then
        return {}
    end
    local r = call("store.profiles.list", { kind = kind })
    return (r and r.profiles) or {}
end

-- ─── history ─────────────────────────────────────────────────────────────────

--- Record one executed statement in the call log. FIRE-AND-FORGET.
---
--- The one store write nobody waits for, and the only one that is made from
--- inside a daemon callback: it is the query's own state callback that records
--- the query. So it does not wait — it cannot, from in there (see `rpc`), and it
--- has no reason to: nothing on screen depends on the answer, and a failure is
--- reported by `fire` like any other.
---
--- The backend is resolved OUTSIDE the callback when it is not known yet
--- (`vim.schedule`), because resolving it is itself a synchronous call. That
--- defers the record by one loop turn and never by five seconds.
---@param entry { conn: string?, driver: string?, statement: string, state: string?, ms: integer?, rows: integer? }
---@return boolean  whether the record was handed on (not whether it was stored)
function M.record(entry)
    if mode == nil and require("lvim-db.daemon").dispatching() then
        vim.schedule(function()
            M.record(entry)
        end)
        return true
    end
    local m = resolve()
    if m == "legacy" then
        return legacy.record(entry)
    elseif m == "none" then
        return false
    end
    fire("store.history.record", {
        conn = entry.conn,
        driver = entry.driver,
        statement = entry.statement,
        state = entry.state,
        ms = entry.ms,
        rows = entry.rows,
    })
    return true
end

--- The most recent history entries, newest first (capped at `limit`, default 200).
---@param limit integer?
---@return table[]
function M.history(limit)
    local m = resolve()
    if m == "legacy" then
        return legacy.history(limit)
    elseif m == "none" then
        return {}
    end
    local r = call("store.history.list", { limit = limit or 200 })
    return (r and r.history) or {}
end

--- Close the store. Only the legacy backend holds a handle of its own — the
--- engine's database closes with the engine process.
function M.close()
    if legacy_store then
        legacy_store:close()
        legacy_store = nil
    end
end

return M
