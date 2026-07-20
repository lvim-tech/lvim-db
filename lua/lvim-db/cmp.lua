-- lvim-db.cmp: the lvim-cmp completion source for the query editor — schema-aware
-- completion fed by lvim-db's OWN daemon, not an external SQL language server. The daemon
-- already knows the ACTIVE connection's real structure (schemas → tables/views/collections,
-- per-object columns) for every driver — including MongoDB and Redis, which no SQL LSP
-- covers — and it never needs credentials handed to a third-party server (secrets resolve
-- only inside the daemon, per the security model).
--
--   • plain keyword → schema + object (table/view/collection) names of the active connection
--   • after a `.`   → the named object's COLUMNS (`users.` → id, name, …), fetched on demand
--
-- Both are cached per `conn_id`: a reconnect gets a fresh conn_id from the daemon, so the
-- cache can never serve a dead connection's schema. Only the LIVE connection is asked —
-- completion never opens a connection as a side effect (an unconnected active connection
-- simply completes nothing).
--
-- Registered from `setup()` (pcall — lvim-cmp is optional); disable it via lvim-cmp's own
-- per-source config: `sources = { ["lvim-db"] = { enabled = false } }`.
--
---@module "lvim-db.cmp"

local M = {}

M.name = "lvim-db"

-- LSP CompletionItemKind per drawer node kind (Module / Class / Interface; columns = Field).
---@type table<string, integer>
local NODE_KIND = { table = 7, view = 8, collection = 7, key = 6 }
local KIND_SCHEMA = 9 -- Module
local KIND_COLUMN = 5 -- Field

---@class LvimDbCmpCache
---@field nodes table[]?                     the daemon's schema tree, once fetched
---@field nodes_pending fun(nodes: table[])[]?  callbacks parked on an in-flight structure fetch
---@field cols table<string, table[]|false>  per-`schema.object` columns (false = fetch in flight)
---@field cols_pending table<string, fun(cols: table[])[]>  callbacks parked per in-flight columns fetch

---@type table<integer, LvimDbCmpCache>  per-conn_id schema cache (a reconnect = a new conn_id)
local cache = {}

--- The live conn_id of the editor's active connection, or nil (never connects as a side effect).
---@return integer? conn_id
local function live_conn_id()
    local active = require("lvim-db.ui.editor").active_conn()
    if not active then
        return nil
    end
    local conn_id = require("lvim-db.ui.drawer").live_conn(active)
    return conn_id
end

--- Run `cb(nodes)` with the connection's schema tree — from the cache, or after ONE
--- daemon fetch (concurrent callers park on the same request).
---@param conn_id integer
---@param cb fun(nodes: table[])
local function with_structure(conn_id, cb)
    local c = cache[conn_id]
    if c and c.nodes then
        cb(c.nodes)
        return
    end
    if c and c.nodes_pending then
        c.nodes_pending[#c.nodes_pending + 1] = cb
        return
    end
    cache[conn_id] = { nodes_pending = { cb }, cols = {}, cols_pending = {} }
    require("lvim-db").structure(conn_id, function(nodes)
        local entry = cache[conn_id]
        if not entry then
            return
        end
        entry.nodes = nodes or {}
        local parked = entry.nodes_pending or {}
        entry.nodes_pending = nil
        for _, f in ipairs(parked) do
            f(entry.nodes)
        end
    end)
end

--- Run `cb(columns)` with the columns of `obj` (from `schema`) — cached per object, one
--- daemon fetch per object with concurrent callers parked. An RPC error answers `{}` but is
--- NOT cached, so the next trigger retries.
---@param conn_id integer
---@param schema string
---@param obj string
---@param cb fun(cols: table[])
local function with_columns(conn_id, schema, obj, cb)
    local entry = cache[conn_id]
    if not entry then
        cb({})
        return
    end
    local key = schema .. "." .. obj
    local cached = entry.cols[key]
    if type(cached) == "table" then
        cb(cached)
        return
    end
    if cached == false then
        entry.cols_pending[key][#entry.cols_pending[key] + 1] = cb
        return
    end
    entry.cols[key] = false
    entry.cols_pending[key] = { cb }
    require("lvim-db").columns(conn_id, { name = obj, schema = schema ~= "" and schema or nil }, function(cols, err)
        local e = cache[conn_id]
        if not e then
            return
        end
        if err or not cols then
            e.cols[key] = nil -- do not cache a failure as "no columns"; the next trigger retries
        else
            e.cols[key] = cols
        end
        local parked = e.cols_pending[key] or {}
        e.cols_pending[key] = nil
        for _, f in ipairs(parked) do
            f(cols or {})
        end
    end)
end

--- The object name a `.`-completion refers to: the identifier immediately before the dot
--- that precedes the keyword (quoting stripped; of a dotted chain, the LAST component —
--- `public.users.` completes the columns of `users`).
---@param ctx table  LvimCmpContext
---@return string?
local function object_before_dot(ctx)
    local before = ctx.line:sub(1, ctx.bounds.s)
    local raw = before:match("([^%s,%(%)=<>%+%-%*/;]+)%.$")
    if not raw then
        return nil
    end
    local name = raw:gsub("[\"'`%[%]]", "")
    return name:match("([^%.]+)$")
end

--- Whether this source serves the context: only the lvim-db editor buffer, and only with an
--- active connection bound (there is no schema to complete from otherwise).
---@param ctx table  LvimCmpContext
---@return boolean
function M.enabled(ctx)
    if not vim.b[ctx.bufnr].lvim_db_editor then
        return false
    end
    return require("lvim-db.ui.editor").active_conn() ~= nil
end

--- `.` opens column completion for the object before it.
---@param bufnr integer
---@return table<string, boolean>
function M.trigger_chars(bufnr)
    local _ = bufnr
    return { ["."] = true }
end

--- Build one completion item.
---@param label string
---@param kind integer
---@param detail string?
---@return table item  LvimCmpItem
local function item(label, kind, detail)
    return {
        raw = { label = label, kind = kind, detail = detail },
        source_name = M.name,
        label = label,
        filter_text = label,
        sort_text = label,
        kind = kind,
    }
end

--- Serve the context: columns of the dotted object, else schema + object names.
---@param ctx table  LvimCmpContext
---@param cb fun(items: table[], incomplete: boolean)  items are LvimCmpItem-shaped
---@return fun()? cancel
function M.get(ctx, cb)
    local conn_id = live_conn_id()
    if not conn_id then
        vim.schedule(function()
            cb({}, false)
        end)
        return nil
    end
    local dotted = object_before_dot(ctx)
    with_structure(conn_id, function(nodes)
        if dotted then
            -- The FIRST object of that name across schemas (an unqualified name is ambiguous
            -- anyway; the engine resolves it the same way — by search order).
            for _, schema in ipairs(nodes) do
                for _, obj in ipairs(schema.children or {}) do
                    if obj.name == dotted then
                        with_columns(conn_id, schema.name or "", obj.name, function(cols)
                            local items = {}
                            for _, col in ipairs(cols) do
                                items[#items + 1] = item(col.name, KIND_COLUMN, col.type ~= "" and col.type or nil)
                            end
                            cb(items, false)
                        end)
                        return
                    end
                end
            end
            cb({}, false)
            return
        end
        local items, seen = {}, {}
        for _, schema in ipairs(nodes) do
            if schema.name and schema.name ~= "" and not seen[schema.name] then
                seen[schema.name] = true
                items[#items + 1] = item(schema.name, KIND_SCHEMA, "schema")
            end
            for _, obj in ipairs(schema.children or {}) do
                if not seen[obj.name] then
                    seen[obj.name] = true
                    items[#items + 1] = item(obj.name, NODE_KIND[obj.kind] or 7, schema.name)
                end
            end
        end
        cb(items, false)
    end)
    return nil
end

--- Drop a connection's cached schema (called on disconnect; a reconnect's fresh conn_id
--- would sidestep the stale entry anyway — this just frees it eagerly).
---@param conn_id integer?
function M.invalidate(conn_id)
    if conn_id then
        cache[conn_id] = nil
    end
end

return M
