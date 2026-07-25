-- lvim-db.ui.workspace: the dedicated TABPAGE that hosts the whole db UI.
--
-- `:LvimDb open` moves the entire client into its OWN tabpage (never over your code): the connections drawer on
-- the left, the query editor top-right, and — once a query runs — the result dock. `:LvimDb close` tears the tab
-- down and returns to where you were, WITHOUT wiping the in-memory session: the drawer's expand/connect state,
-- the current result page and the call log all live in their modules and survive the close, so `toggle` (or a
-- second `open`) restores the workspace exactly as you left it. The daemon holds the live connections in its own
-- process, so a re-open never re-connects.
--
-- The tab lifecycle, the editor pane, the `laststatus = 3` chrome guard and the two-state layout toggle are the
-- SHARED `lvim-ui.workspace` shell (the same primitive lvim-rest / lvim-git / lvim-forge use). This module fills
-- the regions: the drawer (left sidebar) and the result (dock). The default layout is "full" — the result docks
-- FULL WIDTH across the bottom, tree+editor on top — and `:LvimDb dock` toggles it to "editor" (result under the
-- editor, tree full-height), the shared State-1 ⟷ State-2 switch.
--
---@module "lvim-db.ui.workspace"

local api = vim.api
local workspace = require("lvim-ui.workspace")

local M = {}

-- The shared-shell id (its tab marker).
local ID = "lvim-db"

-- The editor buffer marks itself with `b:lvim_db_editor` (set in `lvim-db.ui.editor.ensure_buf`), so the editor
-- WINDOW is re-found by that buffer marker — never by filetype (the buffer is genuine `sql`, so treesitter / LSP
-- / lvim-cmp work on it) and never by a stored handle (survives a re-open on a fresh tab).
local EDITOR_MARK = "lvim_db_editor"

---@class LvimDbWorkspaceState
local state = {
    editor_win = nil, ---@type integer?  the top-right editor window (cached; re-found by marker when stale)
}

--- The top-right EDITOR window of the db workspace tab. Resolved by the cached handle, else by finding the
--- workspace tab's window whose buffer carries the `lvim_db_editor` marker var. nil outside a workspace.
---@return integer?
function M.editor_win()
    local tab = workspace.tab_for(ID)
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

--- Host the editor in `win`: place the `lvim-db.ui.editor` scratch buffer (a real editable `sql` buffer, owned +
--- persisted by that module, so its unsaved SQL survives a close/reopen) and paint its winbar + footer bar.
--- The buffer set is idempotent (the shared shell already parked it via `spec.editor.buf`).
---@param win integer?
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

--- Whether the workspace tab is open.
---@return boolean
function M.is_open()
    return workspace.is_open(ID)
end

--- Open the workspace: switch to the db tab if it already exists, else create a fresh one (via the shared shell)
--- and build the regions inside it — the drawer (left), the editor (top-right, hosted here) and the restored
--- result (dock). Idempotent; the session state (drawer expansion, last result, call log) is restored either way.
function M.open()
    if M.is_open() then
        workspace.focus(ID)
        setup_editor(M.editor_win() or api.nvim_get_current_win())
        require("lvim-db.ui.drawer").open(true)
        require("lvim-db.ui.result").reopen()
        return
    end
    local handle = workspace.open({
        id = ID,
        -- db's canonical arrangement is state 2: the result docks FULL WIDTH under tree+editor. `:LvimDb dock`
        -- toggles to "editor" (result under the editor, tree full-height).
        layout = "full",
        -- Appear in the shared <Leader>m dock menu; restorable (reopen) even after it was closed.
        menu = { name = "Database", icon = (require("lvim-db.config").icons or {}).database },
        restore = function()
            M.open()
        end,
        -- The editor pane hosts the persisted `sql` scratch (marks itself `b:lvim_db_editor`).
        editor = {
            buf = function()
                return require("lvim-db.ui.editor").ensure_buf()
            end,
            name = "Database",
        },
        sidebar = function()
            require("lvim-db.ui.drawer").open(true)
        end,
        dock = function()
            require("lvim-db.ui.result").reopen() -- only paints if a result / call log survives
        end,
    })
    setup_editor(handle.editor) -- winbar + footer (the buffer is already parked by the shell)
end

--- Close the workspace: tear the surfaces down (their `on_close` keeps the DATA state), then the shared shell
--- drops the tab and returns to where you came from. Nothing session-level is discarded — a later `open` restores
--- it. The editor window handle is dropped; the editor BUFFER is held by `lvim-db.ui.editor` (unsaved SQL kept).
function M.close()
    if not M.is_open() then
        return
    end
    workspace.close(ID, function()
        pcall(function()
            require("lvim-db.ui.result").close()
        end)
        pcall(function()
            require("lvim-db.ui.drawer").close()
        end)
        state.editor_win = nil
    end)
end

--- Toggle the workspace tab (open ⇄ close, keeping the session state).
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

--- Toggle the RESULT dock between the two shared layout states — "full" (full-width across the bottom,
--- tree+editor on top — db's default) and "editor" (under the editor, tree full-height). Rebuilds the result
--- dock in the new arrangement, keeping the current page/call log. No-op outside the workspace.
function M.toggle_dock()
    if not M.is_open() then
        vim.notify("lvim-db: the dock layout toggle is a workspace-only feature", vim.log.levels.WARN)
        return
    end
    workspace.toggle_layout(ID, function(new_state)
        local result = require("lvim-db.ui.result")
        result.close()
        result.reopen() -- rebuilds the dock in the new state's geometry (no-op if nothing has run yet)
        vim.notify("lvim-db: dock layout → " .. new_state, vim.log.levels.INFO)
    end)
end

return M
