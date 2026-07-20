-- lvim-db.ui.workspace: the dedicated TABPAGE that hosts the whole db UI.
--
-- `:LvimDb open` moves the entire client into its OWN tabpage (never over your code): the connections drawer on
-- the left, the result dock below, and — in a later stage — the query editor on the right. `:LvimDb close` tears
-- the tab down and returns to where you were, WITHOUT wiping the in-memory session: the drawer's expand/connect
-- state, the current result page and the call log all live in their modules and survive the close, so `toggle`
-- (or a second `open`) restores the workspace exactly as you left it. The daemon holds the live connections in
-- its own process, so a re-open never re-connects.
--
-- The tab is marked with a tab-scoped var (`t:lvim_db_workspace`) so the module can find it again — never by a
-- stored handle, which a `:tabclose` from elsewhere would leave dangling.
--
---@module "lvim-db.ui.workspace"

local api = vim.api

local M = {}

-- The workspace regions are REAL tiled windows in a two-row layout: a TOP row of `[tree | editor]` (the
-- drawer top-left, the editor top-right) and, once a query runs, a FULL-WIDTH RESULT docked at the bottom
-- (spanning under both). Docking the result at the far tabpage edge wraps the top row into
-- `[ [tree | editor] / result ]`, so the tree stops being full-height and its footer stays visible ABOVE the
-- result. They navigate as ONE via directional window nav: the drawer/editor bind `<C-h/j/k/l>` to
-- `<C-w>h/j/k/l` (below), so `<C-j>` from EITHER top window descends onto the result (the chassis WinEnter
-- hook enters the docked panel), `<C-k>` from the result's top sector steps back up to whichever of
-- tree/editor is above the cursor column (the chassis `escape_to_neighbor`), and `<C-h>`/`<C-l>` move between
-- the tree and the editor in the top row. The result keeps its own `<C-j/k/h/l>` sector/panel nav.
--
-- The editor buffer itself (a real editable `sql` scratch) is owned by `lvim-db.ui.editor`; this module only
-- places it in the top-right window and re-finds that window by the buffer's `lvim_db_editor` marker var
-- (never by filetype — the buffer is genuine `sql`, so treesitter / LSP / lvim-cmp work on it).
local EDITOR_MARK = "lvim_db_editor"

-- Forward declaration: `db_tab` (the tab-marker lookup) is defined below but referenced by the region
-- helpers above it.
local db_tab

---@class LvimDbWorkspaceState
local state = {
    origin_tab = nil, ---@type integer?  the tabpage to return to on close
    editor_win = nil, ---@type integer?  the top-right editor window
    augroup = nil, ---@type integer?  the chrome-guard autocmd group (see below)
}

-- The workspace's two-row layout (`[tree | editor] / result`) needs a GLOBAL statusline (`laststatus = 3`):
-- with per-window statuslines (`laststatus = 2`) each top window grows its OWN bar at its bottom — mid-screen,
-- ABOVE the docked result — so the status line "splits in two" under the tree and the editor and the result
-- is pushed below them. That is exactly what happens opening the workspace from the dashboard: the dashboard
-- runs with `laststatus = 0` and, on teardown, restores the value it captured at STARTUP — before the user's
-- config set 3 — which can be Neovim's built-in default (2). The workspace would inherit that 2 and split.
--
-- So the workspace OWNS its statusline: it forces `laststatus = 3` on open and re-asserts it whenever its tab
-- becomes current (another tab — the dashboard — may set it to 0 globally while focused). It does NOT save +
-- restore the prior value: that value can be the stale 2, and 3 is the configured normal anyway; on close the
-- origin tab (the dashboard) re-asserts its own chrome through its own autocmds.
local function guard_chrome()
    vim.o.laststatus = 3
    if not state.augroup then
        state.augroup = api.nvim_create_augroup("LvimDbWorkspaceChrome", { clear = true })
        api.nvim_create_autocmd("TabEnter", {
            group = state.augroup,
            callback = function()
                if db_tab() == api.nvim_get_current_tabpage() then
                    vim.o.laststatus = 3
                end
            end,
        })
    end
end

--- Drop the chrome guard (on close).
local function unguard_chrome()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
end

--- The top-right EDITOR window of the db workspace tab. Resolved by the cached handle, else by finding the
--- workspace tab's window whose buffer carries the `lvim_db_editor` marker var (survives a re-open on a fresh
--- tab) — so a re-open reuses the same window instead of stacking a second editor. nil outside a workspace.
---@return integer?
function M.editor_win()
    local tab = db_tab()
    if not tab then
        return nil
    end
    if state.editor_win and api.nvim_win_is_valid(state.editor_win) then
        local ok, wt = pcall(api.nvim_win_get_tabpage, state.editor_win)
        if ok and wt == tab then
            return state.editor_win
        end
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
        local buf = api.nvim_win_get_buf(w)
        if api.nvim_buf_is_valid(buf) and vim.b[buf][EDITOR_MARK] then
            state.editor_win = w
            return w
        end
    end
    return nil
end

--- Focus the editor window (opening the workspace first if it is closed).
function M.focus_editor()
    if not M.is_open() then
        M.open()
    end
    local win = M.editor_win()
    if win and api.nvim_win_is_valid(win) then
        api.nvim_set_current_win(win)
    end
end

--- Host the editor in the workspace tab's top-right window: place the `lvim-db.ui.editor` scratch buffer (a
--- real editable `sql` buffer, owned + persisted by that module) and paint its winbar. Idempotent — reuses
--- the one editor buffer, so its unsaved SQL survives a `:LvimDb close`/reopen.
---@param win integer  the window to host the editor (the tab's non-drawer window)
local function setup_editor(win)
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    state.editor_win = win
    local editor = require("lvim-db.ui.editor")
    api.nvim_win_set_buf(win, editor.ensure_buf())
    editor.update_winbar()
    editor.attach_footer(win) -- the button bar riding the window's bottom row (lvim-ui.winfooter)
end

--- The db workspace tabpage, if one is open. Found by its tab-scoped marker (never a cached handle).
---@return integer? tabpage
db_tab = function()
    for _, t in ipairs(api.nvim_list_tabpages()) do
        local ok, v = pcall(api.nvim_tabpage_get_var, t, "lvim_db_workspace")
        if ok and v == true then
            return t
        end
    end
    return nil
end

--- Whether the workspace tab is open.
---@return boolean
function M.is_open()
    return db_tab() ~= nil
end

--- Open the workspace: switch to the db tab if it already exists, else create a fresh tabpage, mark it, and
--- build the layout inside it (drawer + the restored result, if any). Idempotent.
function M.open()
    local existing = db_tab()
    if existing then
        api.nvim_set_current_tabpage(existing)
        guard_chrome()
        setup_editor(M.editor_win() or api.nvim_get_current_win())
        require("lvim-db.ui.drawer").open(true)
        require("lvim-db.ui.result").reopen()
        return
    end
    state.origin_tab = api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    -- `tabnew` opens a fresh listed [No Name] buffer; setup_editor swaps the editor scratch into the window
    -- below, orphaning it — wipe it so repeated toggles don't leak a dead [No Name] per cycle.
    local blank = api.nvim_get_current_buf()
    api.nvim_tabpage_set_var(api.nvim_get_current_tabpage(), "lvim_db_workspace", true)
    guard_chrome() -- one GLOBAL statusline in the tab, never per-window bars that split the layout (see above)
    -- The fresh tab's window becomes the EDITOR placeholder (captured BEFORE the drawer splits off the left,
    -- so it stays the top-right window). The drawer is the top-left tree (a left native split); a full-width
    -- result later docks at the bottom, wrapping the top row. Restore the previous result, if there was one.
    setup_editor(api.nvim_get_current_win())
    -- the editor scratch has replaced `blank` in the window; wipe the orphan if nothing else shows it
    if api.nvim_buf_is_valid(blank) and blank ~= api.nvim_get_current_buf() then
        local name = api.nvim_buf_get_name(blank)
        if name == "" and not vim.bo[blank].modified and #vim.fn.win_findbuf(blank) == 0 then
            pcall(api.nvim_buf_delete, blank, {})
        end
    end
    require("lvim-db.ui.drawer").open(true)
    require("lvim-db.ui.result").reopen()
end

--- Close the workspace: tear the surfaces down (their `on_close` keeps the DATA state), return to the tab you
--- came from, then close the db tab. Idempotent. Nothing session-level is discarded — a later `open` restores it.
function M.close()
    local t = db_tab()
    if not t then
        return
    end
    unguard_chrome()
    pcall(function()
        require("lvim-db.ui.result").close()
    end)
    pcall(function()
        require("lvim-db.ui.drawer").close()
    end)
    if api.nvim_tabpage_is_valid(t) then
        -- Leave the tab BEFORE closing it, so focus lands where the user came from (not on nvim's default
        -- neighbour), when the db tab is the current one.
        if api.nvim_get_current_tabpage() == t then
            if state.origin_tab and api.nvim_tabpage_is_valid(state.origin_tab) then
                api.nvim_set_current_tabpage(state.origin_tab)
            end
        end
        pcall(function()
            vim.cmd(api.nvim_tabpage_get_number(t) .. "tabclose")
        end)
    end
    state.origin_tab = nil
    -- The tab (and its editor window) is gone; drop the window handle. The editor BUFFER is held by
    -- `lvim-db.ui.editor`, so its unsaved SQL survives — a re-open restores the same editor content.
    state.editor_win = nil
end

--- Toggle the workspace tab.
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

return M
