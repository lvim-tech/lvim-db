-- The keys the dock binds: that no two of them are the same key.
--
-- Worth a test because the collision is invisible in review and loud in use: the
-- second binding wins silently, so the key that still LOOKS bound in the config
-- and in the cheatsheet does something else. Adding "remove the focused row" is
-- exactly the change that nearly took `x`, which the call-log view already uses
-- to cancel a running statement.

local config = require("lvim-db.config")

--- Every lhs a surface binds, as a flat list of `{ id, lhs }`. A key set to
--- `false` is unbound and not a binding; a key bound to several lhs (`i` / `a`)
--- contributes each of them.
---@param keys table<string, string|string[]|false>
---@return { [1]: string, [2]: string }[]
local function bindings(keys)
    local out = {}
    for id, lhs in pairs(keys) do
        if type(lhs) == "string" then
            out[#out + 1] = { id, lhs }
        elseif type(lhs) == "table" then
            for _, one in ipairs(lhs) do
                out[#out + 1] = { id, one }
            end
        end
    end
    table.sort(out, function(a, b)
        return a[1] < b[1]
    end)
    return out
end

describe("keys: the result dock")

it("binds no key twice, apart from the one <CR> that is one gesture in two modes", function()
    -- `rerun` (a call in the log) and `edit_cell` (a field of a locked row) share `<CR>` deliberately: it is
    -- the "act on what is under the cursor" key, and the dock has two different things under it. Every other
    -- collision is a bug.
    local SHARED = { rerun = true, edit_cell = true }
    local seen = {}
    for _, b in ipairs(bindings(config.keys.result)) do
        local id, lhs = b[1], b[2]
        if not SHARED[id] then
            truthy(not seen[lhs], ("%s and %s are both bound to %s"):format(tostring(seen[lhs]), id, lhs))
            seen[lhs] = id
        end
    end
end)

it("gives adding and removing a row their own keys", function()
    local k = config.keys.result
    truthy(k.new_row, "a row can be added")
    truthy(k.delete_row, "a row can be removed")
    truthy(k.new_row ~= k.insert_cell, "`a` already means start typing in this field")
    truthy(k.delete_row ~= k.cancel, "`x` already means cancel the running call")
    for _, lhs in ipairs({ k.new_row, k.delete_row }) do
        eq(lhs:upper(), lhs, "a write key is a capital, so it is never one keystroke from a motion")
    end
end)

describe("keys: every surface")

it("binds no key twice in the drawer, the editor or the form", function()
    -- The editor's `<CR>` is bound in NORMAL and in VISUAL — "run the statement under the cursor" and "run
    -- the selection" are the same gesture asked of two different amounts of text, and two modes are not a
    -- collision. Everything else sharing a key inside one surface is.
    local SHARED = { editor = { run_statement = true, run_selection = true } }
    for _, surface in ipairs({ "drawer", "editor", "form" }) do
        local allowed = SHARED[surface] or {}
        local seen = {}
        for _, b in ipairs(bindings(config.keys[surface] or {})) do
            local id, lhs = b[1], b[2]
            if not allowed[id] then
                truthy(
                    not seen[lhs],
                    ("%s: %s and %s are both bound to %s"):format(surface, tostring(seen[lhs]), id, lhs)
                )
                seen[lhs] = id
            end
        end
    end
end)
