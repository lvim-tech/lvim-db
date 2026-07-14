-- lvim-db.ui.drawer: the persistent connections/schema side panel.
--
-- Built on lvim-ui.surface in NATIVE-SPLIT mode (the same window class as
-- lvim-files' tree — never a raw nvim_open_win), pinned to one edge and
-- registered as a `panel_ft` so lvim-utils.cursor hides the cursor while it is
-- the current window. The tree is three levels: saved CONNECTION → SCHEMA →
-- TABLE/VIEW/COLLECTION (a table expands once more to its COLUMNS). Per-node
-- actions: connect/expand (l or <CR>), collapse/disconnect (h), run a preview
-- select on a table (<CR>), add/edit/delete a connection, refresh. All schema
-- data comes from the daemon through the client API — the drawer holds no SQL.
--
---@module "lvim-db.ui.drawer"

local api = vim.api
local surface = require("lvim-ui.surface")
local config = require("lvim-db.config")

local M = {}

-- kind → { icon, highlight } for the lead glyph + label (Nerd Font, single width).
local KIND = {
    connection = { icon = "", hl = "LvimDbConnection" },
    connection_open = { icon = "", hl = "LvimDbConnectionOpen" },
    schema = { icon = "", hl = "LvimDbSchema" },
    table = { icon = "", hl = "LvimDbTable" },
    view = { icon = "", hl = "LvimDbView" },
    collection = { icon = "", hl = "LvimDbCollection" },
    column = { icon = "", hl = "LvimDbColumn" },
    key = { icon = "", hl = "LvimDbKey" },
    string = { icon = "", hl = "LvimDbKey" },
    list = { icon = "", hl = "LvimDbKey" },
    hash = { icon = "", hl = "LvimDbKey" },
    set = { icon = "", hl = "LvimDbKey" },
    zset = { icon = "", hl = "LvimDbKey" },
}
local CARET_OPEN = ""
local CARET_CLOSED = ""

---@class LvimDbDrawerState
local state = {
    surface = nil, ---@type table?
    buf = nil, ---@type integer?
    win = nil, ---@type integer?
    rows = {}, ---@type table[]  the flat list of visible rows (1-based → row descriptor)
    ---@type table<string, LvimDbDrawerConn>  connection name → live drawer state
    conns = {},
    ns = api.nvim_create_namespace("LvimDbDrawer"),
}

---@class LvimDbDrawerConn
---@field name string
---@field driver string
---@field conn_id integer?    daemon connection id once connected
---@field encrypted boolean?  whether the live link negotiated TLS
---@field tunneled boolean?   whether the live link rides an SSH tunnel
---@field expanded boolean
---@field nodes table[]?      schema tree from the daemon (schema → children)
---@field open table<string, boolean>  expand state keyed by "schema" / "schema.table"

--- The live config.
local function ns()
    return state.ns
end

--- The live daemon conn_id for a saved connection name, if it is connected in
--- the drawer right now (so notes / ad-hoc runs reuse the open connection).
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
            lock = (conn.encrypted or conn.tunneled) and " " or "  "
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
    api.nvim_buf_clear_namespace(state.buf, ns(), 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_set_extmark, state.buf, ns(), h[1], h[2], {
            end_col = h[3],
            hl_group = h[4],
        })
    end
end

--- Public: re-render if open (used after an async data fetch resolves).
function M.refresh()
    if M.is_open() then
        vim.schedule(render)
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

--- Connect (if needed) then fetch + expand a connection's schema.
---@param conn LvimDbDrawerConn
local function expand_connection(conn)
    local db = require("lvim-db")
    if conn.conn_id then
        conn.expanded = true
        render()
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
            conn.expanded = true
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
    { "collapse", "collapse (disconnect)" },
    { "add", "add a connection" },
    { "edit", "edit the focused connection" },
    { "delete", "delete the focused connection" },
    { "refresh", "re-read the schema" },
    { "notes", "open the notes picker" },
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
    map(k.notes, function()
        local row = current_row()
        if row and row.conn then
            require("lvim-db.ui.notes").pick(row.conn.name)
        end
    end)
    map(k.close, M.close)
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
        cursorline = true,
        filetype = "lvim-db-drawer",
        size = function()
            local width = config.drawer_width or 36
            return math.max(24, width), 1
        end,
        update = function(pan)
            state.buf, state.win = pan.buf, pan.win
            vim.bo[pan.buf].buftype = "nofile"
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
        -- A key-hint bar pinned to the drawer's bottom row: the panel had NONE, so its keys — and the
        -- cheatsheet itself — were undiscoverable. Real `surface.button`s, no ● separators (the drawer is 36
        -- columns wide and they would cost the chips their place).
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button(
                            { name = "help", key = config.keys.drawer.help or "g?", style = "action", run = show_help },
                            "action"
                        ),
                        surface.button({
                            name = "close",
                            key = config.keys.drawer.close or "q",
                            style = "action",
                            run = function()
                                M.close()
                            end,
                        }, "action"),
                    },
                },
            },
        },
    })
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
