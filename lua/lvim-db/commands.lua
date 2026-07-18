-- lvim-db.commands: the `:LvimDb` user command.
-- Registered from setup(). A single command with subcommands (the lvim-tech
-- convention — no plugin/ bootstrap file; setup() owns command creation). The
-- windowed subcommands (open / connect / query …) are wired to the lvim-ui UI in
-- a later phase; the foundation ships `status` and `health` so the backend and
-- store can be inspected from the editor immediately.
--
---@module "lvim-db.commands"

local M = {}

---@type table<string, fun(args: string[])>
local subcommands = {
    --- Echo a one-line backend/store status snapshot.
    status = function()
        local db = require("lvim-db")
        local s = db.status()
        local parts = {
            "binary: " .. (s.binary or "NOT BUILT"),
            "running: " .. tostring(s.running),
            "proto: " .. tostring(s.proto or "-"),
            "drivers: " .. tostring(s.drivers),
            "store: " .. tostring(s.store),
        }
        vim.notify("lvim-db  " .. table.concat(parts, "  |  "), vim.log.levels.INFO)
    end,

    --- Open :checkhealth for this plugin.
    health = function()
        vim.cmd("checkhealth lvim-db")
    end,

    --- Open the db workspace: move the whole client into its OWN tabpage (drawer + result + editor). Idempotent.
    open = function()
        require("lvim-db.ui.workspace").open()
    end,

    --- Toggle the db workspace tab (open ⇄ close, keeping the session state).
    toggle = function()
        require("lvim-db.ui.workspace").toggle()
    end,

    --- Add a new saved connection (the DriverMeta-driven form).
    add = function()
        require("lvim-db.ui.form").open()
    end,

    --- Close the db workspace tab, returning to where you were (the session state is preserved for a re-open).
    close = function()
        require("lvim-db.ui.workspace").close()
    end,

    --- Show the call-log tab in the result dock.
    log = function()
        require("lvim-db.ui.result").show_log()
    end,

    --- Scan saved connections for PLAINTEXT secrets and offer to move them into the lvim-keyring wallet
    --- (rewriting each to `{{ vault "db/<name>" }}`).
    ["keyring-migrate"] = function()
        require("lvim-db.keyring").migrate()
    end,
}

--- Register the `:LvimDb` command (idempotent).
function M.setup()
    if vim.g.lvim_db_command_registered then
        return
    end
    vim.g.lvim_db_command_registered = true

    vim.api.nvim_create_user_command("LvimDb", function(opts)
        local args = opts.fargs
        local sub = args[1] or "status"
        local fn = subcommands[sub]
        if not fn then
            vim.notify(("lvim-db: unknown subcommand '%s'"):format(sub), vim.log.levels.ERROR)
            return
        end
        table.remove(args, 1)
        fn(args)
    end, {
        nargs = "*",
        desc = "lvim-db database client",
        complete = function(arglead)
            local out = {}
            for name in pairs(subcommands) do
                if name:find(arglead, 1, true) == 1 then
                    out[#out + 1] = name
                end
            end
            table.sort(out)
            return out
        end,
    })
end

return M
