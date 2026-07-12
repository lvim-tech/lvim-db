-- lvim-db.ui.notes: per-connection scratch notes + the run-selection flow.
--
-- Notes are REAL files (no window magic) under stdpath("state")/lvim-db/notes/
-- <conn>/, opened as ordinary buffers so all of Neovim's editing works. A notes
-- PICKER (lvim-ui.select) lists a connection's notes (+ "new"). In a note buffer
-- the run maps execute SQL against that connection through the guarded runner —
-- so a DROP / DELETE-without-WHERE trips the destructive-statement confirm before
-- anything runs. Which connection a buffer targets is remembered in a buffer var.
--
-- Maps (buffer-local, set when a note opens):
--   <Plug>(LvimDbRunBuffer)     — run the whole buffer     (default <localleader>r)
--   <Plug>(LvimDbRunSelection)  — run the visual selection (default <localleader>r in visual)
--
---@module "lvim-db.ui.notes"

local ui = require("lvim-ui")
local config = require("lvim-db.config")

local M = {}

--- The base notes directory.
---@return string
local function notes_root()
    return vim.fs.normalize(config.notes_dir or (vim.fn.stdpath("state") .. "/lvim-db/notes"))
end

--- A connection's notes directory (created on demand). Name is filesystem-safe.
---@param conn_name string
---@return string
local function conn_dir(conn_name)
    local safe = conn_name:gsub("[^%w%-_%.]", "_")
    local dir = notes_root() .. "/" .. safe
    vim.fn.mkdir(dir, "p")
    return dir
end

-- ── running ──────────────────────────────────────────────────────────────────

--- Resolve a live daemon connection for `conn_name` (reusing the drawer's open
--- connection when present, else connecting from the store), then `cb(conn_id,
--- driver)`.
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
            vim.notify("lvim-db: connect '" .. conn_name .. "' failed: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        local saved = db.store.get_connection(conn_name)
        cb(conn_id, saved and saved.driver or "")
    end)
end

--- Run a statement from buffer `buf` against its bound connection (guarded).
---@param buf integer
---@param statement string
local function run(buf, statement)
    statement = vim.trim(statement or "")
    if statement == "" then
        return
    end
    local conn_name = vim.b[buf].lvim_db_conn
    if not conn_name then
        vim.notify("lvim-db: this buffer is not bound to a connection", vim.log.levels.WARN)
        return
    end
    with_conn(conn_name, function(conn_id, driver)
        require("lvim-db.ui.result").run_guarded(conn_id, conn_name, driver, statement)
    end)
end

--- Run the whole current buffer.
function M.run_buffer()
    local buf = vim.api.nvim_get_current_buf()
    run(buf, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end

--- Run the current visual selection (from the '< / '> marks).
function M.run_selection()
    local buf = vim.api.nvim_get_current_buf()
    local s = vim.api.nvim_buf_get_mark(buf, "<")
    local e = vim.api.nvim_buf_get_mark(buf, ">")
    local lines = vim.api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false)
    run(buf, table.concat(lines, "\n"))
end

-- ── opening notes ────────────────────────────────────────────────────────────

--- Open a note file as a normal buffer, bind it to `conn_name`, and install the
--- run maps.
---@param path string
---@param conn_name string
local function open_note(path, conn_name)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.b[buf].lvim_db_conn = conn_name
    if vim.bo[buf].filetype == "" then
        vim.bo[buf].filetype = "sql"
    end
    -- Buffer-local default maps → the global <Plug> targets (installed in setup()).
    vim.keymap.set("n", "<localleader>r", "<Plug>(LvimDbRunBuffer)", { buffer = buf, silent = true })
    vim.keymap.set("x", "<localleader>r", "<Plug>(LvimDbRunSelection)", { buffer = buf, silent = true })
    vim.notify(
        ("lvim-db: note for '%s' — <localleader>r runs the buffer (or selection in visual mode)"):format(conn_name),
        vim.log.levels.INFO
    )
end

--- Pick (or create) a note for `conn_name` via the canonical select, then open it.
---@param conn_name string
function M.pick(conn_name)
    local dir = conn_dir(conn_name)
    local files = vim.fn.globpath(dir, "*.sql", false, true)
    local items = { { label = "  New note…", new = true } }
    for _, f in ipairs(files) do
        items[#items + 1] = { label = "  " .. vim.fn.fnamemodify(f, ":t"), path = f }
    end
    ui.select({
        title = ("Notes — %s"):format(conn_name),
        items = items,
        callback = function(confirmed, idx)
            if not confirmed then
                return
            end
            local it = items[idx]
            if it.new then
                ui.input({
                    title = "New note name",
                    default = os.date("%Y%m%d-%H%M") .. ".sql",
                    callback = function(ok, name)
                        if not ok or not name or name == "" then
                            return
                        end
                        if not name:match("%.sql$") then
                            name = name .. ".sql"
                        end
                        open_note(dir .. "/" .. name, conn_name)
                    end,
                })
            else
                open_note(it.path, conn_name)
            end
        end,
    })
end

--- Install the global <Plug> run maps (idempotent; called from setup()).
function M.setup()
    if vim.g.lvim_db_notes_plugs then
        return
    end
    vim.g.lvim_db_notes_plugs = true
    vim.keymap.set("n", "<Plug>(LvimDbRunBuffer)", M.run_buffer, { silent = true })
    vim.keymap.set("x", "<Plug>(LvimDbRunSelection)", function()
        -- leave visual mode so the '< / '> marks are set, then run
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        M.run_selection()
    end, { silent = true })
end

return M
