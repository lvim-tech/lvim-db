-- lvim-db.store: lvim-db's OWN persistence — saved connections + query history.
--
-- A real relational store (connections are the data), so it uses the sqlite
-- backend of the shared lvim-utils.store seam, in lvim-db's OWN database file
-- under stdpath("data")/lvim-db/ — never a shared db (the set's persistence
-- canon: shared CODE, per-plugin FILE). Only the connection TEMPLATE is stored:
-- the `spec` column holds the params/auth/tls/tunnel JSON with secrets as
-- templates (`{{ env … }}`), never resolved credentials — resolution happens in
-- the daemon at connect time. sqlite.lua missing ⇒ the store opens closed and
-- every op degrades to nil/false, so callers never have to guard it.
--
---@module "lvim-db.store"

local config = require("lvim-db.config")

local M = {}

-- Bump on any schema change; `migrations` (below) transforms an older on-disk db. v2 ADDED the
-- `queries` table — a brand-new table needs no data transform (its sqlite.tbl handle CREATEs it on
-- open), so there is no migration step for it; the bump only stamps the user_version.
local SCHEMA_VERSION = 2

-- A saved connection. `spec` is the JSON connection template the form produced.
local CONNECTIONS = "connections"
-- One executed statement, for the call-log / history tab.
local HISTORY = "history"
-- A saved query, scoped PER CONNECTION (the `conn` column is the connection name). Replaces the
-- old file-based per-connection notes: the editor saves/loads SQL here and the drawer lists them
-- under each connection's "Queries" branch. Column names avoid SQL reserved words (`sql` is fine;
-- `name`/`conn` are already used by the other tables without issue).
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

---@type table? the live store handle (nil until opened)
local store

--- Open the store (idempotent). Returns the handle, or nil when sqlite is absent.
---@return table?
local function open()
    if store then
        return store
    end
    local ok, mod = pcall(require, "lvim-utils.store")
    if not ok then
        return nil
    end
    local dir = config.data_dir or (vim.fn.stdpath("data") .. "/lvim-db")
    store = mod.new({
        backend = "sqlite",
        name = "lvim-db",
        dir = dir,
        version = SCHEMA_VERSION,
        tables = TABLES,
        migrations = {}, -- filled as the schema evolves past v1
    })
    return store
end

--- Whether persistence is available (sqlite.lua present and the db opened).
---@return boolean
function M.available()
    local s = open()
    return s ~= nil and s:is_open()
end

-- ─── connections ─────────────────────────────────────────────────────────────

---@class LvimDbConnection
---@field id integer
---@field name string
---@field driver string
---@field spec table  { params, auth, tls, tunnel } — secrets are templates
---@field created integer?

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

--- All saved connections, newest first.
---@return LvimDbConnection[]
function M.list_connections()
    local s = open()
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

--- One saved connection by name, or nil.
---@param name string
---@return LvimDbConnection?
function M.get_connection(name)
    local s = open()
    if not s then
        return nil
    end
    local rows = s:find(CONNECTIONS, { name = name })
    if type(rows) == "table" and rows[1] then
        return decode_conn(rows[1])
    end
    return nil
end

--- Insert or update a saved connection (keyed by `name`). Returns success.
---@param name string
---@param driver string
---@param spec table  { params, auth, tls, tunnel } — secrets kept as templates
---@return boolean
function M.save_connection(name, driver, spec)
    local s = open()
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

--- Delete a saved connection by name. Returns success.
---@param name string
---@return boolean
function M.remove_connection(name)
    local s = open()
    if not s then
        return false
    end
    return s:remove(CONNECTIONS, { name = name })
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
    local s = open()
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

--- One saved query by (conn, name), or nil.
---@param conn string
---@param name string
---@return LvimDbSavedQuery?
function M.get_query(conn, name)
    local s = open()
    if not s then
        return nil
    end
    local rows = s:find(QUERIES, { conn = conn, name = name })
    if type(rows) == "table" and rows[1] then
        return rows[1]
    end
    return nil
end

--- Insert or update a saved query (keyed by the (conn, name) pair). Returns success.
---@param conn string
---@param name string
---@param sql string
---@return boolean
function M.save_query(conn, name, sql)
    local s = open()
    if not s then
        return false
    end
    local existing = s:find(QUERIES, { conn = conn, name = name })
    if type(existing) == "table" and existing[1] then
        return s:update(QUERIES, { conn = conn, name = name }, { sql = sql, updated_at = os.time() })
    end
    return s:insert(QUERIES, { conn = conn, name = name, sql = sql, updated_at = os.time() }) ~= false
end

--- Delete a saved query by (conn, name). Returns success.
---@param conn string
---@param name string
---@return boolean
function M.delete_query(conn, name)
    local s = open()
    if not s then
        return false
    end
    return s:remove(QUERIES, { conn = conn, name = name })
end

-- ─── history ─────────────────────────────────────────────────────────────────

--- Record one executed statement in the call log.
---@param entry { conn: string?, driver: string?, statement: string, state: string?, ms: integer?, rows: integer? }
---@return boolean
function M.record(entry)
    local s = open()
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

--- The most recent history entries, newest first (capped at `limit`, default 200).
---@param limit integer?
---@return table[]
function M.history(limit)
    local s = open()
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

--- Close the store (releases the sqlite handle). Idempotent.
function M.close()
    if store then
        store:close()
        store = nil
    end
end

return M
