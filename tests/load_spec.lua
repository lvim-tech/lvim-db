-- Every module loads.
--
-- The cheapest guardrail there is, and it catches the one mistake that review
-- does not: a module that only breaks when something requires it. The views are
-- not rendered here — loading is the whole test — so lvim-ui and lvim-utils have
-- to be on the runtimepath, which `tests/run.lua` arranges.

local MODULES = {
    "lvim-db",
    "lvim-db.config",
    "lvim-db.daemon",
    "lvim-db.proto",
    "lvim-db.rules",
    "lvim-db.query",
    "lvim-db.store",
    "lvim-db.health",
    "lvim-db.cmp",
    "lvim-db.commands",
    "lvim-db.highlights",
    "lvim-db.keyring",
    "lvim-db.ui.ddl",
    "lvim-db.ui.result",
    "lvim-db.ui.drawer",
    "lvim-db.ui.editor",
    "lvim-db.ui.form",
    "lvim-db.ui.workspace",
}

describe("every module loads")

for _, m in ipairs(MODULES) do
    it(m, function()
        -- A fresh load each time: a module cached by an earlier spec would make
        -- this pass without having been read.
        package.loaded[m] = nil
        local ok, err = pcall(require, m)
        truthy(ok, tostring(err))
    end)
end
