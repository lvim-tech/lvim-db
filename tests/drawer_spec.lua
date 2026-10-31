-- The drawer is a cursor-VISIBLE panel over a `nomodifiable` buffer, which is the exact
-- shape in which an unbound builtin edit key reaches the editor itself: `s`, `o`, `p` and
-- `dd` are not mappings, so nothing the panel binds can stop them, and each one answers
-- with `E21: Cannot make changes, 'modifiable' is off` — a message about the plugin's own
-- buffer, in the user's message history, for a keystroke that did nothing.
--
-- The result grid already declares `readonly` for this reason (lvim-ui's `lock_readonly`:
-- keep the motions, nop everything else); the drawer did not, and the E21 it raised showed
-- up in a real session's log. This spec is that keystroke, pressed.

local function open_drawer()
    vim.o.columns, vim.o.lines = 160, 48
    require("lvim-db").setup({})
    local drawer = require("lvim-db.ui.drawer")
    drawer.open(true)
    return drawer
end

--- Press `key` as a user does (mappings applied) and hand back the error it raised, if any.
---@param key string
---@return string
local function press(key)
    vim.v.errmsg = ""
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key .. "<Esc>", true, false, true), "x", false)
    return vim.v.errmsg
end

describe("drawer: a key that is not bound cannot edit the buffer")

it("answers an unbound edit key with nothing at all, not E21", function()
    local drawer = open_drawer()
    truthy(drawer.is_open(), "the drawer did not open")
    truthy(not vim.bo[vim.api.nvim_get_current_buf()].modifiable, "the drawer buffer is modifiable")
    -- One of each shape the builtin offers: substitute, open a line, put, and an operator.
    for _, key in ipairs({ "s", "o", "O", "p", "P", "x", "dd", "cc", "J", "~" }) do
        local err = press(key)
        truthy(err == "", ("pressing %q in the drawer raised: %s"):format(key, err))
    end
    drawer.close()
end)

it("keeps the motions that a tree is read with", function()
    local drawer = open_drawer()
    local buf = vim.api.nvim_get_current_buf()
    -- `lock_readonly` nops the printable range EXCEPT the motion whitelist and what the panel
    -- itself binds. A motion must therefore still be the builtin — no buffer mapping at all.
    for _, key in ipairs({ "j", "k", "G", "}", "w" }) do
        local m = vim.fn.maparg(key, "n", false, true)
        truthy(
            not (m and m.buffer == 1),
            ("%q is mapped in the drawer; the motions must stay the builtin ones"):format(key)
        )
    end
    truthy(vim.api.nvim_buf_is_valid(buf))
    drawer.close()
end)
