-- lvim-db.ui.editor: the top-right SQL EDITOR of the workspace tab.
--
-- A genuine EDITABLE scratch buffer (filetype `sql`, so treesitter / LSP / lvim-cmp all work on it),
-- kept as a nofile scratch that PERSISTS across `:LvimDb close`/reopen — the module holds the buffer
-- handle, so its unsaved SQL survives a workspace teardown. The user writes SQL here and runs it:
--   • NORMAL <CR>  — run the STATEMENT UNDER THE CURSOR (the buffer is split into statements on `;`,
--                    respecting string literals and comments; the one spanning the cursor line runs).
--   • VISUAL <CR>  — run the current selection verbatim.
--   • run_buffer   — run the WHOLE buffer as one statement.
-- Every run goes through `result.run_guarded`, so the destructive-statement guard + call-log/history
-- apply exactly as for any other run.
--
-- ACTIVE CONNECTION model — the editor runs against ONE bound connection, the "active" one:
--   • Expanding / selecting a connection in the drawer binds it (drawer calls `M.set_active`).
--   • Loading a saved query binds that query's connection.
--   • The bound connection is shown in the editor's WINBAR ("editor → <conn>") and is (re)bindable
--     anytime from the tree. When nothing is bound, a run offers a canonical picker of saved
--     connections (or, with none saved, tells the user to add one) — the "which connection?"
--     question is answered explicitly, never guessed.
--
-- Saved queries live in lvim-db's OWN sqlite store (the `queries` table, scoped per connection), not
-- as files — `save_query` upserts the buffer under a name; the drawer's per-connection "Queries"
-- branch lists them and loads one back with `M.load_query`.
--
---@module "lvim-db.ui.editor"

local api = vim.api
local ui = require("lvim-ui")
local config = require("lvim-db.config")

local M = {}

-- The buffer-local marker (a var, NOT the filetype — the filetype is real `sql`) by which the
-- workspace re-finds the editor window on a reopen.
local MARK = "lvim_db_editor"
-- The buffer-local var remembering which saved query (name) the buffer was last loaded from, so
-- `save_query` can default to that name.
local QNAME = "lvim_db_query_name"

---@class LvimDbEditorState
local state = {
    buf = nil, ---@type integer?  the persistent scratch SQL buffer
    active = nil, ---@type string?  the bound ("active") connection name
}

-- ── statement splitting ───────────────────────────────────────────────────────

--- Split SQL `text` into statements on top-level `;`, tracking each statement's 1-based line span.
--- A `;` inside a single/double/back-quoted string or a `--` line / `/* */` block comment does NOT
--- split — so a semicolon in a literal or comment never mis-cuts a statement.
---@param text string
---@return { sql: string, sline: integer, eline: integer }[]
local function split_statements(text)
    local stmts = {}
    local n = #text
    local line = 1
    local seg = {} ---@type string[]  chars of the current statement
    local seg_start = nil ---@type integer?  line of the first non-blank char
    -- lexer state: single-quote, double-quote, back-quote, line-comment, block-comment
    local sq, dq, bq, lc, bc = false, false, false, false, false

    local function push(ch)
        seg[#seg + 1] = ch
        if seg_start == nil and not ch:match("%s") then
            seg_start = line
        end
    end
    local function flush(endline)
        local sql = vim.trim(table.concat(seg))
        if sql ~= "" then
            stmts[#stmts + 1] = { sql = sql, sline = seg_start or endline, eline = endline }
        end
        seg = {}
        seg_start = nil
    end

    local i = 1
    while i <= n do
        local ch = text:sub(i, i)
        local nx = text:sub(i + 1, i + 1)
        if lc then
            push(ch)
            if ch == "\n" then
                lc = false
            end
        elseif bc then
            push(ch)
            if ch == "*" and nx == "/" then
                push(nx)
                i = i + 1
                bc = false
            end
        elseif sq then
            push(ch)
            if ch == "'" then
                sq = false -- a doubled '' re-enters on the next char, so string state stays correct
            end
        elseif dq then
            push(ch)
            if ch == '"' then
                dq = false
            end
        elseif bq then
            push(ch)
            if ch == "`" then
                bq = false
            end
        elseif ch == "-" and nx == "-" then
            push(ch)
            push(nx)
            i = i + 1
            lc = true
        elseif ch == "/" and nx == "*" then
            push(ch)
            push(nx)
            i = i + 1
            bc = true
        elseif ch == "'" then
            push(ch)
            sq = true
        elseif ch == '"' then
            push(ch)
            dq = true
        elseif ch == "`" then
            push(ch)
            bq = true
        elseif ch == ";" then
            flush(line)
        else
            push(ch)
        end
        if ch == "\n" then
            line = line + 1
        end
        i = i + 1
    end
    flush(line) -- the trailing statement (no terminating `;`)
    return stmts
end

--- The statement (text) spanning `cursor_line` in `buf`: the one whose line span contains the
--- cursor, else the nearest statement starting at or before the cursor, else the first. nil when
--- the buffer holds no statement.
---@param buf integer
---@param cursor_line integer  1-based
---@return string?
local function statement_at(buf, cursor_line)
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local stmts = split_statements(text)
    if #stmts == 0 then
        return nil
    end
    for _, s in ipairs(stmts) do
        if cursor_line >= s.sline and cursor_line <= s.eline then
            return s.sql
        end
    end
    -- Cursor in a blank gap: prefer the last statement starting at/before it, else the first.
    local best
    for _, s in ipairs(stmts) do
        if s.sline <= cursor_line then
            best = s
        end
    end
    return (best or stmts[1]).sql
end

-- ── active connection ─────────────────────────────────────────────────────────

--- The currently bound ("active") connection name, or nil.
---@return string?
function M.active_conn()
    return state.active
end

--- Resolve a LIVE daemon connection for `conn_name` — reusing the drawer's open connection when
--- present, else connecting from the store — then `cb(conn_id, driver)`.
---@param conn_name string
---@param cb fun(conn_id: integer, driver: string)
local function with_conn(conn_name, cb)
    local db = require("lvim-db")
    local live, driver = require("lvim-db.ui.drawer").live_conn(conn_name)
    if live then
        cb(live, driver or "")
        return
    end
    db.connect_saved(conn_name, function(conn_id, err)
        if err or not conn_id then
            vim.schedule(function()
                vim.notify("lvim-db: connect '" .. conn_name .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
            return
        end
        local saved = db.store.get_connection(conn_name)
        cb(conn_id, saved and saved.driver or "")
    end)
end

--- The editor window's winbar string for the current active connection.
---@return string
local function winbar_text()
    local ico = "" -- nf-fa-terminal (U+F120): the editor
    local arrow = "➤" -- the set-wide separator/pointer
    if state.active then
        return (" %%#LvimDbEditorIcon#%s %%#LvimDbEditorLabel#editor %s %%#LvimDbEditorConn#%s"):format(
            ico,
            arrow,
            (state.active:gsub("%%", "%%%%")) -- escape % so a connection named `a%b` can't corrupt the winbar
        )
    end
    return (" %%#LvimDbEditorIcon#%s %%#LvimDbEditorLabel#editor %s %%#LvimDbEditorNone#(no connection)"):format(
        ico,
        arrow
    )
end

--- Repaint the editor window's winbar (no-op when the workspace / editor window is not present).
function M.update_winbar()
    local win = require("lvim-db.ui.workspace").editor_win()
    if win and api.nvim_win_is_valid(win) then
        pcall(function()
            vim.wo[win].winbar = winbar_text()
        end)
    end
end

--- Bind `conn_name` as the editor's active connection and refresh the winbar. nil clears it.
---@param conn_name string?
function M.set_active(conn_name)
    state.active = conn_name
    M.update_winbar()
end

-- ── running ───────────────────────────────────────────────────────────────────

--- Run free-text `statement` against the active connection (guarded). With no active connection,
--- open a canonical picker of saved connections to bind one first (or tell the user to add one).
---@param statement string
local function run(statement)
    statement = vim.trim(statement or "")
    if statement == "" then
        vim.notify("lvim-db: nothing to run", vim.log.levels.WARN)
        return
    end
    local conn_name = state.active
    if conn_name then
        with_conn(conn_name, function(conn_id, driver)
            require("lvim-db.ui.result").run_guarded(conn_id, conn_name, driver, statement)
        end)
        return
    end
    -- No active connection — answer "which connection?" explicitly through the canonical picker.
    local conns = require("lvim-db").store.list_connections()
    if #conns == 0 then
        vim.notify(
            "lvim-db: no active connection — add one with :LvimDb add, then connect it in the tree",
            vim.log.levels.WARN
        )
        return
    end
    local items = {}
    for _, cn in ipairs(conns) do
        items[#items + 1] = { label = ("  %s (%s)"):format(cn.name, cn.driver), name = cn.name }
    end
    ui.select({
        title = "Run against connection",
        items = items,
        callback = function(confirmed, idx)
            if not confirmed then
                return
            end
            local name = items[idx].name
            M.set_active(name)
            with_conn(name, function(conn_id, driver)
                require("lvim-db.ui.result").run_guarded(conn_id, name, driver, statement)
            end)
        end,
    })
end

--- Run the statement under the cursor (NORMAL <CR>).
function M.run_statement()
    local buf = M.ensure_buf()
    local win = require("lvim-db.ui.workspace").editor_win()
    local line = (win and api.nvim_win_is_valid(win)) and api.nvim_win_get_cursor(win)[1]
        or api.nvim_win_get_cursor(0)[1]
    local stmt = statement_at(buf, line)
    if not stmt then
        vim.notify("lvim-db: no statement under the cursor", vim.log.levels.WARN)
        return
    end
    run(stmt)
end

--- Run the current visual selection (VISUAL <CR>).
function M.run_selection()
    local buf = api.nvim_get_current_buf()
    local s = api.nvim_buf_get_mark(buf, "<")
    local e = api.nvim_buf_get_mark(buf, ">")
    local lines = api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false)
    run(table.concat(lines, "\n"))
end

--- Run the whole buffer as one statement.
function M.run_buffer()
    local buf = M.ensure_buf()
    run(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end

-- ── saving / loading queries ──────────────────────────────────────────────────

--- Save the buffer's SQL as a named query under the active connection (upsert; confirm-overwrite).
function M.save_query()
    local buf = M.ensure_buf()
    local sql = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(sql) == "" then
        vim.notify("lvim-db: nothing to save (the editor is empty)", vim.log.levels.WARN)
        return
    end
    local conn_name = state.active
    if not conn_name then
        vim.notify(
            "lvim-db: no active connection — connect/select one in the tree to save a query under it",
            vim.log.levels.WARN
        )
        return
    end
    local default = vim.b[buf][QNAME]
    ui.input({
        title = ("Save query — %s"):format(conn_name),
        default = default or "",
        callback = function(ok, name)
            if not ok or not name or vim.trim(name) == "" then
                return
            end
            name = vim.trim(name)
            local db = require("lvim-db")
            local function do_save()
                db.store.save_query(conn_name, name, sql)
                vim.b[buf][QNAME] = name
                require("lvim-db.ui.drawer").refresh()
                vim.notify(("lvim-db: saved query '%s' for '%s'"):format(name, conn_name), vim.log.levels.INFO)
            end
            -- Confirm an overwrite ONLY when it would clobber a DIFFERENT existing query (renaming the
            -- currently-loaded one onto itself is just a re-save, no prompt).
            if name ~= default and db.store.get_query(conn_name, name) then
                ui.confirm({
                    title = "Overwrite query",
                    message = ("A query named '%s' already exists for '%s'. Overwrite it?"):format(name, conn_name),
                    callback = function(yes)
                        if yes then
                            do_save()
                        end
                    end,
                })
            else
                do_save()
            end
        end,
    })
end

--- Load a saved query into the editor buffer (replacing its content), bind that query's connection
--- as active, remember the name (so a later save defaults to it), and focus the editor window.
---@param conn_name string
---@param name string
function M.load_query(conn_name, name)
    local q = require("lvim-db").store.get_query(conn_name, name)
    if not q then
        vim.notify(("lvim-db: no saved query '%s' for '%s'"):format(name, conn_name), vim.log.levels.WARN)
        return
    end
    local buf = M.ensure_buf()
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(q.sql or "", "\n", { plain = true }))
    vim.b[buf][QNAME] = name
    M.set_active(conn_name)
    require("lvim-db.ui.workspace").focus_editor()
end

--- Load arbitrary TEXT into the editor buffer (replacing its content), bind `conn_name` as active, and
--- focus the editor. The generic half of `load_query`: the drawer's `DDL` facet drops a CREATE statement in
--- here, so it lands in the one place that already syntax-highlights, yanks and re-runs SQL — instead of a
--- read-only float that can do none of those.
---
--- The query NAME is cleared: this text did not come from a saved query, and leaving the previous name bound
--- would make the next save silently overwrite THAT query with this DDL.
---@param conn_name string
---@param text string
function M.load_text(conn_name, text)
    local buf = M.ensure_buf()
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    vim.b[buf][QNAME] = nil
    M.set_active(conn_name)
    require("lvim-db.ui.workspace").focus_editor()
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. Built from the LIVE `config.keys.editor`, so a rebind
-- shows and a key set to `false` drops its row.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "run_statement", "run the statement under the cursor" },
    { "run_selection", "run the visual selection" },
    { "run_buffer", "run the whole buffer" },
    { "save_query", "save the buffer as a named query" },
    { "help", "this help" },
}

--- The editor's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows/striping/
--- colours/window; this only supplies the plugin's LIVE keys.
local function show_help()
    local k = config.keys.editor
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = k[e[1]]
        if lhs then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    ui.help({
        title = "SQL editor keymaps",
        items = items,
        close_keys = { "q", "<Esc>", k.help or "<localleader>?" },
    })
end

-- ── buffer setup ──────────────────────────────────────────────────────────────

--- Install the editor's buffer-local keymaps (all from `config.keys.editor`; a `false` value leaves
--- the key unbound). The editor is an EDITABLE buffer, so the run/save keys are chords or leader
--- sequences (never bare letters, which would collide with typing); `<CR>` is the primary run gesture
--- (normal = statement under cursor, visual = the selection) matching the drawer/result `<CR>` action.
---@param buf integer
local function set_keys(buf)
    local k = config.keys.editor
    local function nmap(lhs, fn, desc)
        if lhs then
            vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
        end
    end
    nmap(k.run_statement, M.run_statement, "lvim-db: run statement under cursor")
    if k.run_selection then
        vim.keymap.set("x", k.run_selection, function()
            -- Leave visual mode so the '< / '> marks are set, then run the selection.
            api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
            M.run_selection()
        end, { buffer = buf, nowait = true, silent = true, desc = "lvim-db: run selection" })
    end
    nmap(k.run_buffer, M.run_buffer, "lvim-db: run whole buffer")
    nmap(k.save_query, M.save_query, "lvim-db: save query")
    nmap(k.help, show_help, "lvim-db: editor keymaps")
    -- Region navigation: the tree, editor and full-width result are one coherent set of tiled windows
    -- (see the workspace), so `<C-h/j/k/l>` step between them — matching the drawer/result chords.
    for lhs, nav in pairs({ ["<C-h>"] = "h", ["<C-j>"] = "j", ["<C-k>"] = "k", ["<C-l>"] = "l" }) do
        vim.keymap.set("n", lhs, function()
            pcall(vim.cmd, "wincmd " .. nav)
        end, { buffer = buf, nowait = true, silent = true, desc = "lvim-db: focus " .. nav .. " region" })
    end
end

--- Ensure the persistent editor scratch buffer exists (creating + configuring it once) and return
--- it. A nofile `sql` scratch marked with `MARK`, seeded with a hint comment and the run/save keys.
---@return integer
function M.ensure_buf()
    if state.buf and api.nvim_buf_is_valid(state.buf) then
        return state.buf
    end
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "sql" -- REAL sql, so treesitter / LSP / lvim-cmp all work here
    vim.b[buf][MARK] = true
    api.nvim_buf_set_lines(buf, 0, -1, false, {
        "-- lvim-db SQL editor",
        "-- <CR> runs the statement under the cursor · visual <CR> runs the selection",
        "",
        "",
    })
    set_keys(buf)
    state.buf = buf
    return buf
end

return M
