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
        -- Drawer node kinds — the FOUR tree LEVELS are each a clearly distinct, readable hue so
        -- connection ⇄ database ⇄ object ⇄ field read apart at a glance (no two kinds that can appear
        -- in the SAME tree share a colour):
        --   CONNECTION  magenta when disconnected → green (live) once connected — state also in the icon
        --   DATABASE    schema is blue
        --   OBJECTS     table yellow · view cyan · collection orange (all distinct from each other)
        --   FIELDS      columns take the full foreground (a real readable colour, not the old near-bg dim)
        LvimDbConnection = { fg = c.magenta, bold = true }, -- a saved, DISCONNECTED connection
        LvimDbConnectionOpen = { fg = c.green, bold = true }, -- a CONNECTED (live) connection
        LvimDbSchema = { fg = c.blue, bold = true }, -- a schema / database
        LvimDbTable = { fg = c.yellow }, -- a table
        LvimDbView = { fg = c.cyan }, -- a view
        LvimDbCollection = { fg = c.orange }, -- a (mongo) collection
        LvimDbColumn = { fg = c.fg }, -- a column / field — readable, not dim
        LvimDbKey = { fg = c.orange }, -- a redis key (its own driver context)
        -- The per-object FACET rows (Data / Columns / Indexes / DDL). They are one tier BELOW an object and
        -- are chrome, not data, so they take the same teal family — distinct from every object hue above them
        -- (yellow/cyan/orange) and from the columns/indexes they reveal below.
        LvimDbData = { fg = c.teal }, -- the "Data" facet (runs the preview)
        LvimDbIndex = { fg = c.teal }, -- the "Indexes" facet + each index leaf
        LvimDbDdl = { fg = c.teal }, -- the "DDL" facet
        -- Saved queries — PURPLE, a hue used by no other drawer kind (so a connection's Queries branch and
        -- its query leaves read apart from schemas/objects/columns that can sit in the same tree).
        LvimDbQueries = { fg = c.purple, bold = true }, -- the saved-queries BRANCH
        LvimDbQuery = { fg = c.purple }, -- one saved query leaf

        -- Drawer full-row WASH per node kind — BACKGROUND-ONLY (no fg): a `line_hl_group` carrying a fg would
        -- override the node's label colour, so each row is tinted only in the bg with ITS OWN accent (the
        -- "тинт" canon) while the distinct node-type fg + devicon read intact over it. Container rows
        -- (connection / schema / objects) get the wash; OBJECT rows additionally alternate two depths (a
        -- zebra) so adjacent same-type objects stay apart; COLUMN/field rows stay plain (the leaf tier, so the
        -- washed containers stand out). The SELECTED row of ANY kind gets the stronger `LvimDbRowSel` bg as
        -- its cursor marker. Tint depths sit in the ecosystem-list range (~0.08 base / 0.13 alt / 0.16 sel,
        -- blended toward the accent); override any bg to retint.
        LvimDbBgConnection = { bg = mtint(c.magenta, 0.08) }, -- a disconnected connection row
        LvimDbBgConnectionOpen = { bg = mtint(c.green, 0.08) }, -- a connected connection row
        LvimDbBgSchema = { bg = mtint(c.blue, 0.08) }, -- a schema / database row
        LvimDbBgTable = { bg = mtint(c.yellow, 0.08) }, -- an object row: table (odd)
        LvimDbBgTableAlt = { bg = mtint(c.yellow, 0.13) }, -- table (even, the zebra alt)
        LvimDbBgView = { bg = mtint(c.cyan, 0.08) }, -- view (odd)
        LvimDbBgViewAlt = { bg = mtint(c.cyan, 0.13) }, -- view (even)
        LvimDbBgCollection = { bg = mtint(c.orange, 0.08) }, -- collection (odd)
        LvimDbBgCollectionAlt = { bg = mtint(c.orange, 0.13) }, -- collection (even)
        LvimDbBgKey = { bg = mtint(c.orange, 0.08) }, -- a redis key row (odd)
        LvimDbBgKeyAlt = { bg = mtint(c.orange, 0.13) }, -- a redis key row (even)
        LvimDbBgQueries = { bg = mtint(c.purple, 0.08) }, -- the saved-queries branch row (a container)
        LvimDbBgQuery = { bg = mtint(c.purple, 0.08) }, -- a saved-query leaf (odd)
        LvimDbBgQueryAlt = { bg = mtint(c.purple, 0.13) }, -- a saved-query leaf (even, the zebra alt)
        LvimDbRowSel = { bg = mtint(c.blue, 0.16) }, -- the cursor row (any kind) — bg-only marker
        LvimDbGuide = { fg = hl.blend(c.fg_dark, c.bg, 0.6) }, -- tree guides / carets
        LvimDbCount = { fg = c.comment }, -- a "(12)" child count
        LvimDbEmpty = { fg = c.comment, italic = true },
        LvimDbDriver = { fg = c.yellow }, -- a driver-kind badge

        -- SQL editor winbar ("editor → <conn>"): the icon, the "editor" label, the bound connection name
        -- (green — matches a live connection), and the "(no connection)" placeholder when nothing is bound.
        LvimDbEditorIcon = { fg = c.blue },
        LvimDbEditorLabel = { fg = c.fg_dark },
        LvimDbEditorConn = { fg = c.green, bold = true },
        LvimDbEditorNone = { fg = c.comment, italic = true },

        -- result grid
        LvimDbHeader = { fg = c.blue, bg = mtint(c.blue, 0.2), bold = true }, -- column header row
        LvimDbHeaderActive = { fg = c.blue, bg = mtint(c.blue, 0.4), bold = true },
        -- The dock's header TAB reflecting the active view (Result ⇄ Call log). A SOLID bg across the whole
        -- button — badge, label and padding all wear this one group, so the active tab reads as a filled block
        -- (not a fg-only accent), independent of which sector has focus. The inactive tab keeps the plain
        -- footer colours. `bg` chosen a touch below the column-header active so the two blues don't compete.
        LvimDbTabActive = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
        LvimDbCellNull = { fg = c.comment, italic = true }, -- a NULL cell
        LvimDbCellNumber = { fg = c.orange }, -- numeric cells
        LvimDbRowAlt = { bg = hl.blend(c.fg, c.bg, 0.03) }, -- zebra striping
        -- The row LOCKED for editing, and within it a field CHANGED but not yet written. Yellow — the set's
        -- "in progress, not yet committed" accent — at depths well clear of the zebra (0.03), so a locked row
        -- cannot be mistaken for a striped one and a pending field cannot be mistaken for a saved one. Both
        -- are bg-only washes (the "тинт" canon): the per-cell NULL/number fg colours must survive on them,
        -- since those are exactly what the user is reading while deciding what to change.
        LvimDbEditRow = { bg = mtint(c.yellow, 0.18) },
        LvimDbEditCell = { bg = mtint(c.yellow, 0.38) },

        -- call / query states (the call-log accents)
        LvimDbStateRunning = { fg = c.yellow, bg = mtint(c.yellow, 0.2) },
        LvimDbStateDone = { fg = c.green, bg = mtint(c.green, 0.2) },
        LvimDbStateFailed = { fg = c.red, bg = mtint(c.red, 0.2) },
        LvimDbStateCancelled = { fg = c.comment, bg = mtint(c.comment, 0.2) },
    }
end

return M
