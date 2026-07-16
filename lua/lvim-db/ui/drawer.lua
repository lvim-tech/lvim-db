-- lvim-db.ui.drawer: the persistent connections/schema side panel.
--
-- Built on lvim-ui.surface in NATIVE-SPLIT mode (the same window class as
-- lvim-files' tree — never a raw nvim_open_win), pinned to one edge and
-- registered as a `panel_ft` so lvim-utils.cursor hides the cursor while it is
-- the current window. The tree is three levels: saved CONNECTION → SCHEMA →
-- TABLE/VIEW/COLLECTION (a table expands once more to its COLUMNS). Each connection also carries a
-- "Queries" BRANCH listing its saved queries from lvim-db's own store (metadata, so it shows even when
-- the connection is disconnected); <CR> on a query loads it into the SQL editor, the delete key removes
-- it. Per-node actions: connect/expand (l or <CR>), collapse/disconnect (h), run a preview select on a
-- table (<CR>), add/edit/delete a connection, refresh. All schema data comes from the daemon through the
-- client API — the drawer holds no SQL.
--
---@module "lvim-db.ui.drawer"

local api = vim.api
local surface = require("lvim-ui.surface")
local config = require("lvim-db.config")

local M = {}

-- kind → { icon, highlight } for the lead glyph + label (Nerd Font, single width).
local KIND = {
    connection = { icon = "", hl = "LvimDbConnection" }, -- saved, disconnected (nf-fa-plug U+F1E6)
    connection_open = { icon = "", hl = "LvimDbConnectionOpen" }, -- connected, live (nf-fa-database U+F1C0)
    schema = { icon = "", hl = "LvimDbSchema" }, -- nf-fa-sitemap U+F0E8
    queries = { icon = "", hl = "LvimDbQueries" }, -- saved-queries BRANCH (nf-fa-bookmark U+F02E)
    query = { icon = "", hl = "LvimDbQuery" }, -- one saved query (nf-fa-file-code-o U+F1C9)
    table = { icon = "", hl = "LvimDbTable" }, -- nf-fa-table U+F0CE
    view = { icon = "", hl = "LvimDbView" }, -- nf-fa-eye U+F06E
    collection = { icon = "", hl = "LvimDbCollection" }, -- nf-fa-cubes U+F1B3
    column = { icon = "", hl = "LvimDbColumn" }, -- nf-fa-columns U+F0DB
    key = { icon = "", hl = "LvimDbKey" }, -- redis key (nf-fa-key U+F084)
    string = { icon = "", hl = "LvimDbKey" }, -- redis string (nf-fa-quote-left U+F10D)
    list = { icon = "", hl = "LvimDbKey" }, -- redis list (nf-fa-list-ul U+F0CA)
    hash = { icon = "", hl = "LvimDbKey" }, -- redis hash (nf-fa-hashtag U+F292)
    set = { icon = "", hl = "LvimDbKey" }, -- redis set (nf-fa-th U+F00A)
    zset = { icon = "", hl = "LvimDbKey" }, -- redis sorted set (nf-fa-sort-numeric-asc U+F162)
}
local CARET_OPEN = "" -- nf-fa-caret_down U+F0D7
local CARET_CLOSED = "" -- nf-fa-caret_right U+F0DA

---@class LvimDbDrawerState
local state = {
    surface = nil, ---@type table?
    buf = nil, ---@type integer?
    win = nil, ---@type integer?
    rows = {}, ---@type table[]  the flat list of visible rows (1-based → row descriptor)
    ---@type table<string, LvimDbDrawerConn>  connection name → live drawer state
    conns = {},
    ns = api.nvim_create_namespace("LvimDbDrawer"),
    content_hls = {}, ---@type table[]  the last render's fg spans ({line, col_start, col_end, group}); re-applied by paint()
    nrows = 0, ---@type integer  how many rows the last render wrote (so paint() can stripe them)
    footer_ctx = nil, ---@type "connected"|"disconnected"|"none"|nil  the focused row's state the footer was last built for
}

---@class LvimDbDrawerConn
---@field name string
---@field driver string
---@field conn_id integer?    daemon connection id once connected
---@field encrypted boolean?  whether the live link negotiated TLS
---@field tunneled boolean?   whether the live link rides an SSH tunnel
---@field expanded boolean
---@field queries_open boolean?  whether the connection's saved-queries branch is expanded
---@field nodes table[]?      schema tree from the daemon (schema → children)
---@field open table<string, boolean>  expand state keyed by "schema" / "schema.table"

--- The live config.
local function ns()
    return state.ns
end

--- The live daemon conn_id for a saved connection name, if it is connected in
--- the drawer right now (so the editor / ad-hoc runs reuse the open connection).
---@param name string
---@return integer? conn_id
---@return string? driver
function M.live_conn(name)
    local c = state.conns[name]
    if c and c.conn_id then
        return c.conn_id, c.driver
    end
    return nil, c and c.driver or nil
end

--- Whether the drawer is open.
---@return boolean
function M.is_open()
    return state.surface ~= nil and state.win ~= nil and api.nvim_win_is_valid(state.win)
end

-- ── render ───────────────────────────────────────────────────────────────────

--- Append one visual row and record its descriptor.
---@param lines string[]
---@param hls table[]   {line, col_start, col_end, group}
---@param descr table   the row descriptor (kind, ref, depth, …)
---@param depth integer
---@param caret string?  the expand caret ("" when a leaf)
---@param icon string
---@param icon_hl string
---@param label string
---@param label_hl string
---@param suffix string?  a dim trailing note (e.g. child count)
local function push_row(lines, hls, descr, depth, caret, icon, icon_hl, label, label_hl, suffix)
    local indent = string.rep("  ", depth)
    local caret_str = caret ~= "" and (caret .. " ") or "  "
    local text = indent .. caret_str .. icon .. " " .. label .. (suffix and (" " .. suffix) or "")
    local lineno = #lines
    lines[#lines + 1] = text
    local base = #indent
    -- caret
    if caret ~= "" then
        hls[#hls + 1] = { lineno, base, base + #caret, "LvimDbGuide" }
    end
    local icon_start = base + #caret_str
    hls[#hls + 1] = { lineno, icon_start, icon_start + #icon, icon_hl }
    local label_start = icon_start + #icon + 1
    hls[#hls + 1] = { lineno, label_start, label_start + #label, label_hl }
    if suffix then
        local suf_start = label_start + #label + 1
        hls[#hls + 1] = { lineno, suf_start, suf_start + #suffix, "LvimDbCount" }
    end
    state.rows[lineno + 1] = descr
end

-- object `obj.kind` → its bg WASH group base (the "Alt" variant is the zebra even-row). Redis key kinds all
-- share the key wash. Anything unmapped falls back to the table wash.
local OBJ_BG = {
    table = "LvimDbBgTable",
    view = "LvimDbBgView",
    collection = "LvimDbBgCollection",
    key = "LvimDbBgKey",
    string = "LvimDbBgKey",
    list = "LvimDbBgKey",
    hash = "LvimDbBgKey",
    set = "LvimDbBgKey",
    zset = "LvimDbBgKey",
}

--- The full-row bg WASH group for a row descriptor — its OWN accent tint (bg-only). Object rows alternate a
--- base/"Alt" pair (the zebra, keyed by `alt`); connection rows switch on the live link; column / empty rows
--- get no wash (nil → plain panel bg). The colour is bg-only so the node's label fg still reads over it.
---@param descr table?  the row descriptor from render()
---@param alt boolean   the zebra even-row (object rows only)
---@return string?
local function wash_group(descr, alt)
    if not descr then
        return nil
    end
    local kind = descr.kind
    if kind == "connection" then
        return (descr.conn and descr.conn.conn_id) and "LvimDbBgConnectionOpen" or "LvimDbBgConnection"
    elseif kind == "schema" then
        return "LvimDbBgSchema"
    elseif kind == "queries" then
        return "LvimDbBgQueries" -- the saved-queries BRANCH (a container row)
    elseif kind == "query" then
        return alt and "LvimDbBgQueryAlt" or "LvimDbBgQuery" -- saved-query leaves zebra like objects
    elseif kind == "object" then
        local base = OBJ_BG[descr.obj and descr.obj.kind] or "LvimDbBgTable"
        return alt and (base .. "Alt") or base
    end
    return nil -- column / empty → plain
end

--- Paint the drawer buffer: the full-row bg WASH per node kind UNDER the content fg spans the last
--- `render()` produced. Split out from `render()` because it must also run on CursorMoved so the selected
--- marker follows the cursor WITHOUT rebuilding the lines — and because a re-render rewrites the buffer and
--- wipes every extmark, the wash has to be (re)applied here, never set once on the side.
---
--- Wash policy (why bg-only, why per-kind colour):
---   • Every CONTAINER row (connection / schema / object) is tinted in ITS OWN accent (the "тинт" canon) so
---     the colour reads on both the label AND the row bg; COLUMN/field rows stay plain (leaf tier).
---   • The tint is bg-ONLY — a `line_hl_group` carrying a fg (as the shared msgarea groups do) would
---     override every label's colour, which is exactly why distinct colours would not read.
---   • OBJECT rows additionally alternate two depths (a zebra), keyed by OBJECT-row index (not absolute line
---     parity) so a run of sibling objects alternates cleanly even across an expanded table's column rows.
---   • The SELECTED row of ANY kind takes the stronger bg-only `LvimDbRowSel` as its cursor marker, so the
---     cursor is visible on a connection / schema / column row too — without wiping that row's node colour.
local function paint()
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    api.nvim_buf_clear_namespace(state.buf, ns(), 0, -1)
    local sel
    if state.win and api.nvim_win_is_valid(state.win) then
        sel = api.nvim_win_get_cursor(state.win)[1]
    end
    local obj_i, q_i = 0, 0
    for lineno = 0, state.nrows - 1 do
        local descr = state.rows[lineno + 1]
        local alt = false
        if descr and descr.kind == "object" then
            obj_i = obj_i + 1 -- advance for EVERY object row (even a selected one) so the zebra stays stable
            alt = (obj_i % 2) == 0
        elseif descr and descr.kind == "query" then
            q_i = q_i + 1 -- the saved-query leaves get their OWN zebra counter
            alt = (q_i % 2) == 0
        end
        local group = (sel == lineno + 1) and "LvimDbRowSel" or wash_group(descr, alt)
        if group then
            pcall(api.nvim_buf_set_extmark, state.buf, ns(), lineno, 0, { line_hl_group = group })
        end
    end
    for _, h in ipairs(state.content_hls) do
        pcall(api.nvim_buf_set_extmark, state.buf, ns(), h[1], h[2], {
            end_col = h[3],
            hl_group = h[4],
            priority = 220,
        })
    end
end

-- Forward declaration: the footer is rebuilt context-aware (connect ⇄ disconnect chip) from CursorMoved
-- and after a connect/disconnect flips a row's state — both of which run through code defined above this
-- point (M.refresh, render callbacks), so the name has to exist before them.
local update_footer

--- Rebuild the flat row list + render into the drawer buffer.
local function render()
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    state.rows = {}
    local lines, hls = {}, {}

    local names = vim.tbl_keys(state.conns)
    table.sort(names)
    if #names == 0 then
        lines[1] = "  no connections"
        hls[1] = { 0, 0, #lines[1], "LvimDbEmpty" }
        state.rows[1] = { kind = "empty" }
    end

    for _, name in ipairs(names) do
        local conn = state.conns[name]
        local connected = conn.conn_id ~= nil
        local kind = connected and "connection_open" or "connection"
        local caret = conn.expanded and CARET_OPEN or CARET_CLOSED
        -- Surface the encryption status once connected: a lock glyph (encrypted
        -- or tunnelled) or an open-lock warning (plaintext) — never silent.
        local lock = ""
        if connected then
            lock = (conn.encrypted or conn.tunneled) and " " or " " -- lock (nf-fa-lock U+F023) when encrypted/tunnelled, open lock (nf-fa-unlock U+F09C) plaintext
        end
        local suffix = ("(%s)%s"):format(conn.driver, lock)
        push_row(
            lines,
            hls,
            { kind = "connection", conn = conn },
            0,
            caret,
            KIND[kind].icon,
            KIND[kind].hl,
            name,
            KIND[kind].hl,
            suffix
        )

        -- The saved-queries BRANCH — metadata, so it shows under an expanded connection REGARDLESS of the
        -- live link (even disconnected). Its leaves come from lvim-db's own store, scoped to this connection.
        if conn.expanded then
            local queries = require("lvim-db").store.list_queries(name)
            local qcaret = (#queries > 0) and (conn.queries_open and CARET_OPEN or CARET_CLOSED) or ""
            push_row(
                lines,
                hls,
                { kind = "queries", conn = conn },
                1,
                qcaret,
                KIND.queries.icon,
                KIND.queries.hl,
                "Queries",
                KIND.queries.hl,
                ("(%d)"):format(#queries)
            )
            if conn.queries_open then
                for _, q in ipairs(queries) do
                    push_row(
                        lines,
                        hls,
                        { kind = "query", conn = conn, query = q },
                        2,
                        "",
                        KIND.query.icon,
                        KIND.query.hl,
                        q.name,
                        KIND.query.hl
                    )
                end
            end
        end

        if conn.expanded and conn.nodes then
            for _, schema in ipairs(conn.nodes) do
                local skey = schema.name
                local sopen = conn.open[skey]
                local scaret = (#(schema.children or {}) > 0) and (sopen and CARET_OPEN or CARET_CLOSED) or ""
                push_row(
                    lines,
                    hls,
                    { kind = "schema", conn = conn, schema = schema },
                    1,
                    scaret,
                    KIND.schema.icon,
                    KIND.schema.hl,
                    schema.name,
                    KIND.schema.hl,
                    ("(%d)"):format(#(schema.children or {}))
                )
                if sopen then
                    for _, obj in ipairs(schema.children or {}) do
                        local okey = skey .. "." .. obj.name
                        local km = KIND[obj.kind] or KIND.table
                        local ocaret = conn.open[okey] and CARET_OPEN or CARET_CLOSED
                        push_row(
                            lines,
                            hls,
                            { kind = "object", conn = conn, schema = schema, obj = obj },
                            2,
                            ocaret,
                            km.icon,
                            km.hl,
                            obj.name,
                            km.hl
                        )
                        if conn.open[okey] and obj.columns then
                            for _, col in ipairs(obj.columns) do
                                push_row(
                                    lines,
                                    hls,
                                    { kind = "column", conn = conn },
                                    3,
                                    "",
                                    KIND.column.icon,
                                    KIND.column.hl,
                                    col.name,
                                    KIND.column.hl,
                                    col.type ~= "" and col.type or nil
                                )
                            end
                        end
                    end
                end
            end
        end
    end

    vim.bo[state.buf].modifiable = true
    api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    -- Hand the fg spans + row count to paint(), which lays the stripes down and re-applies these on top —
    -- the same code path CursorMoved uses, so the render and the cursor-follow selection never diverge.
    state.content_hls = hls
    state.nrows = #lines
    paint()
end

--- Public: re-render if open (used after an async data fetch resolves). Also refreshes the context footer,
--- since an async resolve (a connect completing) flips the focused row's connect-state under a stationary
--- cursor — so the connect chip must become the disconnect chip without a cursor move.
function M.refresh()
    if M.is_open() then
        vim.schedule(function()
            render()
            if update_footer then
                update_footer()
            end
        end)
    end
end

-- ── data / actions ───────────────────────────────────────────────────────────

--- Load saved connections from the store into the drawer state (preserving any
--- live connection ids / expand state for names that still exist).
local function load_connections()
    local db = require("lvim-db")
    local saved = db.store.list_connections()
    local seen = {}
    for _, s in ipairs(saved) do
        seen[s.name] = true
        if not state.conns[s.name] then
            state.conns[s.name] = { name = s.name, driver = s.driver, expanded = false, open = {} }
        else
            state.conns[s.name].driver = s.driver
        end
    end
    for name in pairs(state.conns) do
        if not seen[name] then
            state.conns[name] = nil
        end
    end
end

--- The row descriptor under the cursor.
---@return table?
local function current_row()
    if not state.win then
        return nil
    end
    local line = api.nvim_win_get_cursor(state.win)[1]
    return state.rows[line]
end

--- Expand a connection (connecting + fetching its schema if needed). Expanding a connection also SELECTS it:
--- it becomes the SQL editor's active connection. The row expands IMMEDIATELY (so the saved-queries branch
--- shows at once — it needs no live link); the schema tree fills in asynchronously once the connect resolves.
---@param conn LvimDbDrawerConn
local function expand_connection(conn)
    local db = require("lvim-db")
    -- Selecting/connecting a connection binds it as the editor's active connection.
    require("lvim-db.ui.editor").set_active(conn.name)
    conn.expanded = true
    render()
    if conn.conn_id then
        return
    end
    db.connect_saved(conn.name, function(conn_id, err, info)
        if err or not conn_id then
            vim.notify("lvim-db: connect '" .. conn.name .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        conn.conn_id = conn_id
        conn.encrypted = info and info.encrypted or false
        conn.tunneled = info and info.tunneled or false
        db.structure(conn_id, function(nodes, serr)
            if serr then
                vim.notify("lvim-db: schema failed: " .. tostring(serr), vim.log.levels.ERROR)
                return
            end
            conn.nodes = nodes or {}
            M.refresh()
        end)
    end)
end

--- Toggle expand/collapse (or connect) on the row under the cursor.
---@param open boolean  true = expand/connect, false = collapse
local function toggle(open)
    local row = current_row()
    if not row then
        return
    end
    if row.kind == "connection" then
        if open then
            expand_connection(row.conn)
        else
            row.conn.expanded = false
            render()
        end
    elseif row.kind == "queries" then
        row.conn.queries_open = open or nil
        render()
    elseif row.kind == "query" then
        if open then
            require("lvim-db.ui.editor").load_query(row.conn.name, row.query.name)
        end
    elseif row.kind == "schema" then
        row.conn.open[row.schema.name] = open or nil
        render()
    elseif row.kind == "object" then
        local key = row.schema.name .. "." .. row.obj.name
        if open and not row.obj.columns then
            require("lvim-db").columns(
                row.conn.conn_id,
                { name = row.obj.name, schema = row.schema.name },
                function(cols)
                    row.obj.columns = cols or {}
                    row.conn.open[key] = true
                    M.refresh()
                end
            )
        else
            row.conn.open[key] = open or nil
            render()
        end
    end
end

--- The default action: connect/expand a connection, run a preview on a table.
local function default_action()
    local row = current_row()
    if not row then
        return
    end
    if row.kind == "connection" then
        expand_connection(row.conn)
    elseif row.kind == "queries" then
        toggle(not row.conn.queries_open)
    elseif row.kind == "query" then
        -- Load the saved query into the editor (replacing its content) and focus the editor window.
        require("lvim-db.ui.editor").load_query(row.conn.name, row.query.name)
    elseif row.kind == "schema" then
        toggle(not row.conn.open[row.schema.name])
    elseif row.kind == "object" then
        -- Run a bounded preview select and show it in the result dock (through the
        -- guarded runner for consistency — a SELECT never trips the guard).
        local result = require("lvim-db.ui.result")
        local q = require("lvim-db.query")
        local stmt = q.preview_statement(row.conn.driver, row.schema.name, row.obj.name, config.page_size)
        result.run_guarded(row.conn.conn_id, row.conn.name, row.conn.driver, stmt)
    end
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. Built from the LIVE `config.keys.drawer`, so a rebind shows up
-- and a key the user set to `false` drops its row.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "action", "connect / expand / preview the row" },
    { "expand", "expand (connect the connection)" },
    { "collapse", "collapse the row (visual)" },
    { "disconnect", "disconnect the connection" },
    { "add", "add a connection" },
    { "edit", "edit the focused connection" },
    { "delete", "delete the focused connection" },
    { "refresh", "re-read the schema" },
    { "help", "this help" },
    { "close", "close the drawer" },
}

--- The drawer's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping, the
--- colours and the window; this only supplies the plugin's LIVE keys.
local function show_help()
    local k = config.keys.drawer
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = k[e[1]]
        if lhs then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    require("lvim-ui").help({
        title = "Databases keymaps",
        items = items,
        close_keys = { "q", "<Esc>", k.help or "g?" },
    })
end

-- ── keymaps ──────────────────────────────────────────────────────────────────

--- The drawer's `close` action. When the drawer lives inside the db workspace tab (the normal case), `q`
--- must tear the WHOLE workspace down — otherwise closing the drawer would strand an empty tab. Routed
--- through `workspace.close()`, which teardown-calls `M.close()` (the surface path) directly, so there is
--- no recursion back into this handler. Outside a workspace it just closes the drawer.
local function request_close()
    local ws = require("lvim-db.ui.workspace")
    if ws.is_open() then
        ws.close()
    else
        M.close()
    end
end

--- Close the LIVE connection on the focused connection row (a real disconnect, not the visual `collapse`).
--- Tells the daemon to drop the link, then optimistically clears the drawer's live state for that
--- connection so it flips straight back to the disconnected icon/colour (the daemon closes async and we
--- never reuse the stale id). A no-op unless the cursor is on a CONNECTED connection row.
local function disconnect_row()
    local row = current_row()
    if not (row and row.kind == "connection" and row.conn and row.conn.conn_id) then
        return
    end
    local conn = row.conn
    require("lvim-db").disconnect(conn.conn_id, function(err)
        if err then
            vim.schedule(function()
                vim.notify("lvim-db: disconnect '" .. conn.name .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
        end
    end)
    -- Drop the live link + schema tree, but KEEP the connection expanded: its saved-queries branch is
    -- metadata (not a live thing), so it stays visible after a disconnect. Re-expand/connect refills schema.
    conn.conn_id, conn.nodes = nil, nil
    conn.encrypted, conn.tunneled = nil, nil
    render()
    if update_footer then
        update_footer() -- the row flipped connected → disconnected under a stationary cursor
    end
end

--- The focused row's connect-state, for the context footer: a DISCONNECTED / CONNECTED connection row, or
--- "none" for anything else (a schema / object / column / the empty state).
---@return "connected"|"disconnected"|"none"
local function focused_ctx()
    local row = current_row()
    if not (row and row.kind == "connection" and row.conn) then
        return "none"
    end
    return row.conn.conn_id and "connected" or "disconnected"
end

--- Build the drawer footer band for a given focused-row context: the CONTEXT chip first (⏎ connect on a
--- disconnected connection, C-q disconnect on a connected one, nothing otherwise), then the always-present
--- help + close chips. Returns the `surface.open` `footer` spec.
---@param ctx "connected"|"disconnected"|"none"
---@return table
local function build_footer(ctx)
    local k = config.keys.drawer
    local items = {}
    if ctx == "disconnected" and k.action then
        items[#items + 1] =
            surface.button({ name = "connect", key = k.action, style = "action", run = default_action }, "action")
    elseif ctx == "connected" and k.disconnect then
        items[#items + 1] = surface.button(
            { name = "disconnect", key = k.disconnect, style = "action", run = disconnect_row },
            "action"
        )
    end
    items[#items + 1] =
        surface.button({ name = "help", key = k.help or "g?", style = "action", run = show_help }, "action")
    items[#items + 1] =
        surface.button({ name = "close", key = k.close or "q", style = "action", run = request_close }, "action")
    -- LEFT-aligned (not centered): the leading CONTEXT chip is the priority action, so on the narrow 36-col
    -- drawer it stays fully readable and the responsive bar overflows only the trailing help/close hints (their
    -- keys still work) — instead of a centered bar clipping the important chip's own key badge to "q>".
    return { bars = { { align = "left", items = items } } }
end

--- Rebuild the context footer IF the focused row's connect-state changed since the last build (so it is not
--- rebuilt on every cursor move, only when the connect/disconnect chip actually needs to swap). Reused by the
--- CursorMoved autocmd (alongside the stripe repaint) and after a connect/disconnect flips a row.
update_footer = function()
    if not (M.is_open() and state.surface and state.surface.set_footer) then
        return
    end
    local ctx = focused_ctx()
    if ctx == state.footer_ctx then
        return
    end
    state.footer_ctx = ctx
    state.surface.set_footer(build_footer(ctx))
end

--- Bind the drawer's keys THROUGH the chassis `map` (the provider's `keys` hook), never with a raw
--- `vim.keymap.set`: only the keys the chassis binds itself land in its `used` set, and that set is what
--- makes the panel OWN a chord PREFIX (the `g` of `g?`) — otherwise a `g?` typed at human speed falls
--- through to the builtin `g` once `timeoutlen` expires.
---@param chassis_map fun(lhs: string|string[], fn: fun())
local function set_keys(chassis_map)
    local k = config.keys.drawer
    -- `false` on any key leaves it unbound (the user's opt-out), so every map is guarded.
    local function map(lhs, fn)
        if not lhs then
            return
        end
        chassis_map(lhs, fn)
    end
    map(k.help, show_help)
    map(k.expand, function()
        toggle(true)
    end)
    map(k.collapse, function()
        toggle(false)
    end)
    map(k.disconnect, disconnect_row)
    map(k.action, default_action)
    map(k.add, function()
        require("lvim-db.ui.form").open()
    end)
    map(k.edit, function()
        local row = current_row()
        if row and row.kind == "connection" then
            require("lvim-db.ui.form").open(row.conn.name)
        end
    end)
    map(k.delete, function()
        local row = current_row()
        if row and row.kind == "connection" then
            require("lvim-ui").confirm({
                title = "Delete connection",
                message = ("Delete saved connection '%s'?"):format(row.conn.name),
                callback = function(yes)
                    if yes then
                        require("lvim-db").store.remove_connection(row.conn.name)
                        load_connections()
                        render()
                    end
                end,
            })
        elseif row and row.kind == "query" then
            require("lvim-ui").confirm({
                title = "Delete query",
                message = ("Delete saved query '%s' (connection '%s')?"):format(row.query.name, row.conn.name),
                callback = function(yes)
                    if yes then
                        require("lvim-db").store.delete_query(row.conn.name, row.query.name)
                        render()
                    end
                end,
            })
        end
    end)
    map(k.refresh, function()
        local row = current_row()
        if row and row.conn and row.conn.conn_id then
            require("lvim-db").structure(row.conn.conn_id, function(nodes)
                row.conn.nodes = nodes or {}
                M.refresh()
            end)
        end
    end)
    map(k.close, request_close)
    -- Region navigation: the tree, the editor and the full-width result are one coherent set of tiled
    -- windows, so `<C-h/j/k/l>` move between them (directional `<C-w>` nav — the tree is top-left, so `<C-l>`
    -- reaches the editor and `<C-j>` descends onto the result below). `h`/`l` remain the tree's own
    -- collapse/expand — only the Ctrl chords navigate. Matches the lvim-ui chassis sector-nav convention.
    for lhs, nav in pairs({ ["<C-h>"] = "h", ["<C-j>"] = "j", ["<C-k>"] = "k", ["<C-l>"] = "l" }) do
        chassis_map(lhs, function()
            pcall(vim.cmd, "wincmd " .. nav)
        end)
    end
end

-- ── open / close ─────────────────────────────────────────────────────────────

--- Open the drawer (idempotent). `enter` focuses it.
---@param enter boolean?
function M.open(enter)
    if M.is_open() then
        if enter then
            api.nvim_set_current_win(state.win)
        end
        return
    end
    load_connections()

    local provider = {
        -- No 'cursorline': the SELECTED-row look is the shared `LvimUiMsgAreaSel*` tint painted by paint(),
        -- moved by the CursorMoved autocmd below — a themed selection that matches the rest of the ecosystem
        -- instead of the plain CursorLine bar (and never doubles a bg with the stripes).
        cursorline = false,
        filetype = "lvim-db-drawer",
        size = function()
            local width = config.drawer_width or 36
            return math.max(24, width), 1
        end,
        update = function(pan)
            state.buf, state.win = pan.buf, pan.win
            vim.bo[pan.buf].buftype = "nofile"
            -- On every cursor move: repaint the stripes/selection so the selected tint tracks the cursor row
            -- (paint() only re-lays extmarks — no line rebuild), AND refresh the context footer so its
            -- connect/disconnect chip matches the focused row (update_footer no-ops unless the state changed).
            -- Buffer-scoped + cleared first so a re-open on a fresh buffer never stacks duplicate autocmds.
            local aug = api.nvim_create_augroup("LvimDbDrawerPaint", { clear = false })
            api.nvim_clear_autocmds({ group = aug, buffer = pan.buf })
            api.nvim_create_autocmd("CursorMoved", {
                group = aug,
                buffer = pan.buf,
                callback = function()
                    paint()
                    update_footer()
                end,
            })
            render()
        end,
        keys = function(map, pan)
            state.buf, state.win = pan.buf, pan.win
            set_keys(map)
        end,
        on_close = function()
            state.surface, state.win, state.buf, state.rows = nil, nil, nil, {}
        end,
    }

    state.surface = surface.open({
        mode = "split",
        native = true,
        dock = "left",
        enter = enter == true,
        persistent = true,
        normal_hl = "NormalSB",
        title = "Databases",
        size = { width = { fixed = config.drawer_width or 36 } },
        content = { blocks = { { id = "drawer", provider = provider } } },
        close_keys = {},
        -- A key-hint bar pinned to the drawer's bottom row (the panel had NONE, so its keys were
        -- undiscoverable). CONTEXT-AWARE: `build_footer` prepends a `⏎ connect` / `C-q disconnect` chip for
        -- the focused connection row before the always-present help + close chips; the CursorMoved autocmd
        -- swaps it via `set_footer` when the focused row's connect-state changes.
        footer = build_footer("none"),
    })
    state.footer_ctx = "none"
    -- The cursor opens on the first row (often a connection) — sync the chip to it once the surface exists.
    if update_footer then
        vim.schedule(update_footer)
    end
end

--- Close the drawer. Idempotent.
function M.close()
    local s = state.surface
    if s then
        state.surface = nil
        pcall(function()
            s.close()
        end)
    end
end

--- Toggle the drawer.
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open(true)
    end
end

return M
