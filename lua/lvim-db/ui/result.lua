-- lvim-db.ui.result: the query result dock.
--
-- A bottom-docked lvim-ui.surface (never a raw float): the content panel renders
-- the current page as an aligned text grid (a highlighted header row + zebra
-- body, NULL/number tints from the theme factory), and the surface FOOTER carries
-- the pagination band + yank/export/close buttons. The whole result is buffered
-- in the daemon; this dock only ever holds one page and pages through the client
-- API (query.page). Executes go through here so the call is recorded in history
-- and the destructive-statement guard is applied by the caller.
--
---@module "lvim-db.ui.result"

local api = vim.api
local surface = require("lvim-ui.surface")
local config = require("lvim-db.config")

local M = {}

local state = {
    surface = nil, ---@type table?
    buf = nil, ---@type integer?
    ns = api.nvim_create_namespace("LvimDbResult"),
    view = "result", ---@type "result"|"log"  which tab is shown
    call_id = nil, ---@type integer?
    conn_id = nil, ---@type integer?
    conn = nil, ---@type string?
    driver = nil, ---@type string?
    offset = 0,
    page = nil, ---@type table?  the current page { columns, rows, from, has_more, total, affected }
    ---@type table[]  the session CALL LOG (newest last): { call_id, conn_id, conn, driver, statement, state, ms, rows }
    calls = {},
    log_rows = {}, ---@type table[]  line → call descriptor for the log view
    ---@type table?  where the current rows CAME FROM — `{ schema, object, key }` — set only when the run was
    --- a single-OBJECT preview (the drawer's `Data` facet). nil for an ad-hoc statement, and that is not a
    --- gap: an arbitrary query has no answer to "which table is this cell", so its rows are not addressable
    --- and the grid stays read-only. `key` is the object's identifying columns, resolved lazily (see
    --- `resolve_key`): the PRIMARY-key index's columns for SQL, `_id` for mongo.
    origin = nil,
}

---@return boolean
local function is_open()
    return state.surface ~= nil and state.buf ~= nil and api.nvim_buf_is_valid(state.buf)
end

--- Render one cell value to a display string + a highlight group.
---@param v any
---@return string text, string? hl
local function cell_display(v)
    if v == nil or v == vim.NIL then
        return "NULL", "LvimDbCellNull"
    end
    local t = type(v)
    if t == "number" then
        return tostring(v), "LvimDbCellNumber"
    elseif t == "boolean" then
        return tostring(v), "LvimDbCellNumber"
    elseif t == "table" then
        return vim.json.encode(v), nil
    end
    return tostring(v), nil
end

--- Write lines + extmark highlights into the dock buffer.
---@param lines string[]
---@param hls table[]  { line, col_start, col_end, group }
local function write_buf(lines, hls)
    vim.bo[state.buf].modifiable = true
    api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_set_extmark, state.buf, state.ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
end

-- state → highlight group for the call-log accent.
local STATE_HL = {
    running = "LvimDbStateRunning",
    done = "LvimDbStateDone",
    failed = "LvimDbStateFailed",
    cancelled = "LvimDbStateCancelled",
}

--- Render the session CALL LOG: one row per call with a state accent.
local function render_log()
    state.log_rows = {}
    local lines, hls = {}, {}
    if #state.calls == 0 then
        write_buf({ "", "  no calls yet" }, { { 1, 0, 14, "LvimDbEmpty" } })
        return
    end
    -- newest first
    for i = #state.calls, 1, -1 do
        local c = state.calls[i]
        local st = (c.state or "running"):upper()
        local meta = ("%-9s %5sms  %-10s"):format(st, tostring(c.ms or "·"), c.conn or "")
        local stmt = (c.statement or ""):gsub("[\n\r]+", " ")
        if #stmt > 90 then
            stmt = stmt:sub(1, 87) .. "…"
        end
        local line = " " .. meta .. "  " .. stmt
        local lineno = #lines
        lines[#lines + 1] = line
        hls[#hls + 1] = { lineno, 0, 1 + #st, STATE_HL[c.state] or "LvimDbStateRunning" }
        state.log_rows[lineno + 1] = c
    end
    write_buf(lines, hls)
end

--- Render the current page into the dock buffer as an aligned grid.
local function render_result()
    if not is_open() then
        return
    end
    local page = state.page or { columns = {}, rows = {} }
    local cols = page.columns or {}
    local rows = page.rows or {}

    -- affected-count / empty statements have no columns
    if #cols == 0 then
        local msg = page.affected ~= nil and (("%d row(s) affected"):format(page.affected)) or "(no result)"
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, 0, -1, false, { "", "  " .. msg })
        vim.bo[state.buf].modifiable = false
        return
    end

    -- column widths = max of header + cell strings (capped)
    local widths = {}
    local cell_strs = {}
    for ci, col in ipairs(cols) do
        widths[ci] = #col.name
    end
    for ri, row in ipairs(rows) do
        cell_strs[ri] = {}
        for ci = 1, #cols do
            local disp, hl = cell_display(row[ci])
            disp = disp:gsub("[\n\r]", " ")
            if #disp > 60 then
                disp = disp:sub(1, 57) .. "…"
            end
            cell_strs[ri][ci] = { disp, hl }
            widths[ci] = math.max(widths[ci], vim.fn.strdisplaywidth(disp))
        end
    end

    local function pad(s, w)
        local sw = vim.fn.strdisplaywidth(s)
        return s .. string.rep(" ", math.max(0, w - sw))
    end

    local lines, hls = {}, {}
    -- header
    local hparts = {}
    for ci, col in ipairs(cols) do
        hparts[ci] = pad(col.name, widths[ci])
    end
    local header = " " .. table.concat(hparts, " │ ") .. " "
    lines[1] = header
    hls[#hls + 1] = { 0, 0, #header, "LvimDbHeader" }
    -- body
    for ri, row in ipairs(cell_strs) do
        local parts, offsets, pos = {}, {}, 1 -- pos in bytes (leading space)
        for ci = 1, #cols do
            offsets[ci] = pos
            parts[ci] = pad(row[ci][1], widths[ci])
            pos = pos + #parts[ci] + #" │ "
        end
        local line = " " .. table.concat(parts, " │ ") .. " "
        local lineno = #lines
        lines[#lines + 1] = line
        if ri % 2 == 0 then
            hls[#hls + 1] = { lineno, 0, #line, "LvimDbRowAlt" }
        end
        for ci = 1, #cols do
            local hl = row[ci][2]
            if hl then
                local s = offsets[ci] -- 1-based byte offset within " " + parts
                hls[#hls + 1] = { lineno, s, s + #parts[ci], hl }
            end
        end
    end

    write_buf(lines, hls)
end

--- Render whichever tab is active.
local function render()
    if not is_open() then
        return
    end
    if state.view == "log" then
        render_log()
    else
        render_result()
    end
end

--- Title string with the page/row counter.
---@return string
local function title()
    if state.view == "log" then
        return ("Call log  (%d calls)  [Result: r]"):format(#state.calls)
    end
    local page = state.page
    if not page then
        return "Result  [Call log: L]"
    end
    local from = (page.from or 0) + 1
    local to = (page.from or 0) + #(page.rows or {})
    local total = page.total and tostring(page.total) or "?"
    return ("Result  %s  rows %d–%d / %s  [Call log: L]"):format(state.conn or "", from, to, total)
end

--- Switch the active tab and re-render + re-title.
---@param view "result"|"log"
local function set_view(view)
    state.view = view
    render()
    if state.surface and state.surface.set_title then
        pcall(state.surface.set_title, title())
    end
end

--- Fetch a page at `offset` and re-render.
---@param offset integer
local function goto_page(offset)
    if not state.call_id then
        return
    end
    require("lvim-db").page(state.call_id, offset, config.page_size, function(page, err)
        if err or not page or not page.ready then
            return
        end
        state.offset = page.from or offset
        state.page = page
        vim.schedule(function()
            render()
            if state.surface and state.surface.set_title then
                pcall(state.surface.set_title, title())
            end
        end)
    end)
end

--- Yank the whole current page as TSV to the clipboard.
local function yank_page()
    local page = state.page
    if not page or not page.columns then
        return
    end
    local out = {}
    local head = {}
    for _, c in ipairs(page.columns) do
        head[#head + 1] = c.name
    end
    out[1] = table.concat(head, "\t")
    for _, row in ipairs(page.rows or {}) do
        local r = {}
        for ci = 1, #page.columns do
            r[ci] = (cell_display(row[ci]))
        end
        out[#out + 1] = table.concat(r, "\t")
    end
    local text = table.concat(out, "\n")
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    vim.notify(("lvim-db: yanked %d rows (TSV)"):format(#(page.rows or {})), vim.log.levels.INFO)
end

--- Export the current page to a temp TSV file and open it.
local function export_page()
    local page = state.page
    if not page then
        return
    end
    yank_page() -- reuse the TSV builder via the register
    local text = vim.fn.getreg('"')
    local path = vim.fn.stdpath("state") .. "/lvim-db/export-" .. os.time() .. ".tsv"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(text, "\n"), path)
    vim.notify("lvim-db: exported to " .. path, vim.log.levels.INFO)
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. Built from the LIVE `config.keys.result`, so a rebind shows up
-- and a key the user set to `false` drops its row.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "result_tab", "show the RESULT view (header tab)" },
    { "log_tab", "show the CALL LOG view (header tab)" },
    { "view_result", "switch to the result view" },
    { "view_log", "switch to the call-log view" },
    { "rerun", "call log: re-run the focused call" },
    { "cancel", "call log: cancel the running call" },
    { "next_page", "result: next page" },
    { "prev_page", "result: previous page" },
    { "yank", "result: yank the page as TSV" },
    { "export", "result: export the page" },
    { "help", "this help" },
    { "close", "close the dock" },
}

--- The result dock's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping,
--- the colours and the window; this only supplies the plugin's LIVE keys.
local function show_help()
    local k = config.keys.result
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = k[e[1]]
        if lhs then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    require("lvim-ui").help({
        title = "Result keymaps",
        items = items,
        close_keys = { "q", "<Esc>", k.help or "g?" },
    })
end

--- Open (or refresh) the dock with the current result.
local function open_dock()
    if is_open() then
        render()
        if state.surface and state.surface.set_title then
            pcall(state.surface.set_title, title())
        end
        return
    end
    -- Buffer-local keys (all from config.keys.result): switch views, and in the
    -- call-log view re-open a call (re-runs its statement) or cancel a running one.
    -- A key set to `false` is left unbound.
    local k = config.keys.result
    -- Bind THROUGH the chassis `map` (the provider's `keys` hook), never with a raw `vim.keymap.set`: only
    -- the keys the chassis binds itself land in its `used` set, and that set is what makes the panel OWN a
    -- chord PREFIX (the `g` of `g?`) — otherwise a `g?` typed at human speed falls through to the builtin
    -- `g` once `timeoutlen` expires.
    ---@param chassis_map fun(lhs: string|string[], fn: fun())
    local function set_keys(chassis_map)
        local function map(lhs, fn)
            if not lhs then
                return
            end
            chassis_map(lhs, fn)
        end
        map(k.help, show_help)
        map(k.view_result, function()
            set_view("result")
        end)
        map(k.view_log, function()
            set_view("log")
        end)
        map(k.rerun, function()
            if state.view ~= "log" then
                return
            end
            local c = state.log_rows[api.nvim_win_get_cursor(0)[1]]
            if c and c.conn_id then
                M.run(c.conn_id, c.conn, c.driver, c.statement)
            end
        end)
        map(k.cancel, function()
            if state.view ~= "log" then
                return
            end
            local c = state.log_rows[api.nvim_win_get_cursor(0)[1]]
            if c and c.state == "running" and c.call_id then
                require("lvim-db").cancel(c.call_id)
            end
        end)
    end

    local provider = {
        cursorline = true,
        filetype = "lvim-db-result",
        update = function(pan)
            state.buf = pan.buf
            vim.bo[pan.buf].buftype = "nofile"
            render()
        end,
        keys = function(map)
            set_keys(map)
        end,
        on_close = function()
            state.surface, state.buf = nil, nil
        end,
    }
    -- Dock FULL WIDTH at the bottom of the tab (the chassis splits the far tabpage edge → the result spans
    -- under BOTH the tree and the editor). This wraps the existing top row `[tree | editor]` into
    -- `[ [tree | editor] / result ]`, so the tree shrinks to the top-left and its footer stays visible ABOVE
    -- the result. The docked split keeps the full chrome (header tabs · grid · footer) and its own `<C-j/k>`
    -- sector nav, whose TOP-edge `<C-k>` steps back up to the tree or editor above the cursor column
    -- (escape_to_neighbor). A `<C-j>` from either top window descends onto the result (the chassis WinEnter
    -- hook enters the docked panel).
    state.surface = surface.open({
        mode = "split",
        dock = "below",
        title = title(),
        size = { height = { fixed = math.max(8, math.floor(vim.o.lines * 0.35)) } },
        -- Blank " " ring on the result panel (no drawn border): the CONTENT_BORDER marker resolves at open
        -- time to the LIVE `config.content_border` (the shared { " ", … } ring), so the dock gets a 1-cell
        -- breathing inset with no glyph — matching every other content panel — instead of the default rounded
        -- ring a block with no border falls back to. A theme/border change to that one key flows through here.
        content = { blocks = { { id = "result", provider = provider, border = surface.CONTENT_BORDER } } },
        header = {
            bars = {
                surface.bar({ { "result_tab", "log_tab" } }, {
                    result_tab = {
                        name = "result_tab",
                        key = k.result_tab or nil,
                        run = function()
                            set_view("result")
                        end,
                    },
                    log_tab = {
                        name = "log_tab",
                        key = k.log_tab or nil,
                        run = function()
                            set_view("log")
                        end,
                    },
                }),
            },
        },
        footer = {
            bars = {
                surface.bar({ { "prev", "next", "yank", "export" }, { "help", "close" } }, {
                    prev = {
                        name = "prev",
                        key = k.prev_page or nil,
                        run = function()
                            goto_page(math.max(0, state.offset - config.page_size))
                        end,
                    },
                    next = {
                        name = "next",
                        key = k.next_page or nil,
                        run = function()
                            if state.page and state.page.has_more then
                                goto_page(state.offset + config.page_size)
                            end
                        end,
                    },
                    yank = { name = "yank", key = k.yank or nil, run = yank_page },
                    export = { name = "export", key = k.export or nil, run = export_page },
                    -- The dock's keys are not discoverable from the grid, so the bar has to say where the
                    -- cheatsheet is (the key itself is bound in `set_keys`, through the chassis).
                    help = { name = "help", key = k.help or nil, run = show_help },
                    close = {
                        name = "close",
                        key = k.close or nil,
                        run = function(s)
                            s.close()
                        end,
                    },
                }),
            },
        },
        close_keys = k.close and { k.close } or {},
    })
end

--- Re-open the dock over a preserved session (used when the workspace tab is re-opened): if a result page
--- or any call log survives in the module state, rebuild the dock and re-render it so the last result — or
--- at least the call log — comes back exactly as it was. A no-op when nothing has run yet, so the dock only
--- appears once there is something to show.
function M.reopen()
    if state.page == nil and #state.calls == 0 then
        return
    end
    open_dock()
    render()
end

-- ── addressing a row (what makes editing possible at all) ────────────────────
--
-- To change or delete ONE row, the grid must be able to name that row and no other. Two things are needed
-- and BOTH can be absent, in which case the honest answer is "read-only", not a best guess:
--
--   1. an ORIGIN — these rows are one object's. An arbitrary JOIN has no answer to "which table does this
--      cell belong to", so only the drawer's `Data` facet marks a result as addressable.
--   2. a KEY — the object's identifying columns. Without one, `UPDATE … WHERE question = '…'` could match
--      several rows and quietly rewrite them all; that is data loss wearing a helpful face.
--
-- The key comes from the COLUMNS (`Column.primary`), not from the primary INDEX. They disagree, and the
-- disagreement is not exotic: sqlite makes NO index for `id INTEGER PRIMARY KEY` — that column is the rowid
-- alias — so an index-derived key calls an obviously-keyed table unaddressable (measured; it was the first
-- design here and it failed on the user's own database). Every engine reports the key per column instead:
-- sqlite/duckdb `PRAGMA table_info.pk`, mysql `COLUMN_KEY='PRI'`, postgres `pg_index.indisprimary`, mssql
-- `sys.indexes.is_primary_key`, CQL `kind IN (partition_key, clustering)`, mongo `_id`.

--- Resolve the current origin's KEY columns, then call `cb(key|nil)`. Cached on the origin: it is a property
--- of the object, and re-asking on every keystroke would put a round-trip in the edit path.
---@param cb fun(key: string[]?)
local function resolve_key(cb)
    local o = state.origin
    if not (o and state.conn_id) then
        return cb(nil)
    end
    if o.key then
        return cb(#o.key > 0 and o.key or nil)
    end
    require("lvim-db").columns(state.conn_id, { name = o.object, schema = o.schema }, function(cols)
        local key = {}
        for _, c in ipairs(cols or {}) do
            if c.primary then
                key[#key + 1] = c.name
            end
        end
        o.key = key -- remember even when EMPTY: "this object has no key" is an answer worth not re-asking
        cb(#key > 0 and key or nil)
    end)
end

--- Why the current result cannot be edited, or nil when it can. A sentence, not a boolean: the user should
--- learn WHY a grid is read-only instead of finding the keys silently inert.
---@return string?
local function readonly_reason()
    local o = state.origin
    if not o then
        return "this result is not one object's rows — open a table's Data facet to edit"
    end
    if o.key and #o.key == 0 then
        return ("'%s' has no primary key — a row cannot be addressed uniquely"):format(o.object)
    end
    return nil
end

--- Execute `statement` on `conn_id` and show its first page in the dock. Records
--- the call in both the session call log and the persisted history. Does NOT
--- apply the destructive guard — use `M.run_guarded` for that.
---@param conn_id integer
---@param conn_name string
---@param driver string
---@param statement string
---@param origin? table  `{ schema, object }` when these rows ARE one object's — the drawer's `Data` facet
---       passes it; an ad-hoc statement passes nothing and its result stays read-only.
function M.run(conn_id, conn_name, driver, statement, origin)
    local db = require("lvim-db")
    state.conn, state.driver, state.conn_id, state.call_id, state.page, state.offset =
        conn_name, driver, conn_id, nil, nil, 0
    -- Rebound on EVERY run: a result is only editable while it is showing the object it came from, so a
    -- later ad-hoc query must clear this rather than inherit the last preview's identity.
    state.origin = origin and { schema = origin.schema, object = origin.object } or nil

    -- A pending entry in the session call log (accent = running until it resolves).
    local entry = {
        call_id = nil,
        conn_id = conn_id,
        conn = conn_name,
        driver = driver,
        statement = statement,
        state = "running",
        ms = nil,
        rows = nil,
    }
    state.calls[#state.calls + 1] = entry
    if #state.calls > 200 then
        table.remove(state.calls, 1)
    end
    local function relog()
        if is_open() and state.view == "log" then
            vim.schedule(render)
        end
    end
    relog()

    db.execute(conn_id, statement, function(st)
        entry.state = st.state
        entry.ms = st.ms
        entry.rows = st.affected
        db.store.record({
            conn = conn_name,
            driver = driver,
            statement = statement,
            state = st.state,
            ms = st.ms,
            rows = st.affected,
        })
        relog()
        if st.state ~= "done" then
            vim.schedule(function()
                vim.notify(
                    ("lvim-db: query %s%s"):format(st.state, st.error and (": " .. st.error) or ""),
                    st.state == "failed" and vim.log.levels.ERROR or vim.log.levels.WARN
                )
            end)
            return
        end
        vim.schedule(function()
            state.view = "result"
            open_dock()
            goto_page(0)
        end)
    end, function(call_id, err)
        if err then
            vim.schedule(function()
                vim.notify("lvim-db: execute failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
            return
        end
        entry.call_id = call_id
        state.call_id = call_id
    end)
end

--- Execute `statement`, first applying the destructive-statement guard: a DROP /
--- TRUNCATE / unqualified DELETE|UPDATE prompts a confirm (config
--- `confirm_destructive`) before it runs. This is THE entry point for free-text
--- statements (the SQL editor, ad-hoc runs); the drawer preview (a SELECT) may use it too.
---@param conn_id integer
---@param conn_name string
---@param driver string
---@param statement string
function M.run_guarded(conn_id, conn_name, driver, statement, origin)
    local db = require("lvim-db")
    if db.is_destructive(statement) then
        require("lvim-ui").confirm({
            title = "Destructive statement",
            message = "This looks destructive (DROP / TRUNCATE / DELETE|UPDATE without WHERE):\n\n"
                .. statement:sub(1, 200)
                .. "\n\nRun it anyway?",
            callback = function(yes)
                if yes then
                    M.run(conn_id, conn_name, driver, statement, origin)
                end
            end,
        })
    else
        M.run(conn_id, conn_name, driver, statement, origin)
    end
end

--- Open the call-log tab (creating the dock if needed).
function M.show_log()
    open_dock()
    set_view("log")
end

--- Close the dock.
function M.close()
    local s = state.surface
    if s then
        state.surface = nil
        pcall(function()
            s.close()
        end)
    end
end

return M
