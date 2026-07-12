-- lvim-db.highlights: every LvimDb* highlight group, derived from the live
-- lvim-utils palette. build() is a FACTORY (called per application) so each run
-- reads the palette of the moment; init.lua binds it through
-- lvim-utils.highlight.bind, which re-applies on ColorScheme and on palette sync.
-- Tints follow the canon: a coloured cell is its accent mtint-ed toward the bg.
--
---@module "lvim-db.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the editor bg — the shared "mtint" convention.
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- The LvimDb* groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- drawer node kinds (the tree lead icon + label colour per kind)
        LvimDbConnection = { fg = c.purple, bold = true }, -- a saved connection
        LvimDbConnectionOpen = { fg = c.green, bold = true }, -- a connected connection
        LvimDbSchema = { fg = c.blue, bold = true },
        LvimDbTable = { fg = c.green },
        LvimDbView = { fg = c.cyan },
        LvimDbCollection = { fg = c.cyan },
        LvimDbColumn = { fg = hl.blend(c.fg, c.bg, 0.7) },
        LvimDbKey = { fg = c.orange }, -- a redis key
        LvimDbGuide = { fg = hl.blend(c.fg_dark, c.bg, 0.6) }, -- tree guides / carets
        LvimDbCount = { fg = c.comment }, -- a "(12)" child count
        LvimDbEmpty = { fg = c.comment, italic = true },
        LvimDbDriver = { fg = c.yellow }, -- a driver-kind badge

        -- result grid
        LvimDbHeader = { fg = c.blue, bg = mtint(c.blue, 0.2), bold = true }, -- column header row
        LvimDbHeaderActive = { fg = c.blue, bg = mtint(c.blue, 0.4), bold = true },
        LvimDbCellNull = { fg = c.comment, italic = true }, -- a NULL cell
        LvimDbCellNumber = { fg = c.orange }, -- numeric cells
        LvimDbRowAlt = { bg = hl.blend(c.fg, c.bg, 0.03) }, -- zebra striping

        -- call / query states (the call-log accents)
        LvimDbStateRunning = { fg = c.yellow, bg = mtint(c.yellow, 0.2) },
        LvimDbStateDone = { fg = c.green, bg = mtint(c.green, 0.2) },
        LvimDbStateFailed = { fg = c.red, bg = mtint(c.red, 0.2) },
        LvimDbStateCancelled = { fg = c.comment, bg = mtint(c.comment, 0.2) },
    }
end

return M
