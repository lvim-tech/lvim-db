-- lvim-db.ui.result: the query result dock.
--
-- A bottom-docked lvim-ui.surface (never a raw float): the content panel renders
-- the current page as an aligned text grid (zebra body, NULL/number tints from
-- the theme factory), and the surface FOOTER carries the pagination band +
-- edit/yank/export/close buttons. The whole result is buffered in the daemon;
-- this dock only ever holds one page and pages through the client API
-- (query.page). Executes go through here so the call is recorded in history and
-- the destructive-statement guard is applied by the caller.
--
-- Three things about the grid are worth knowing before changing it:
--
--   • WIDTHS AND OFFSETS ARE DISPLAY CELLS, never bytes. See "cells, not bytes".
--   • The COLUMN HEADER is the window's winbar, not a line in the buffer — that
--     is what makes it stick while the rows scroll under it (see `M.winbar`),
--     and it also makes buffer line `ri` exactly result row `ri`.
--   • A row can be EDITED only when the dock knows both where the rows came from
--     (`state.origin`) and how to name one (`resolve_key`); everything else is
--     honestly read-only. See "addressing a row" and "editing a row".
--   • Nothing is ever typed INTO the grid buffer. The cells show a padded,
--     truncated, flattened rendering of the values — editing that text would be
--     editing a picture of the data. Fields are edited in a popup holding the
--     real value. See "editing a row".
--
---@module "lvim-db.ui.result"

local api = vim.api
local surface = require("lvim-ui.surface")
local config = require("lvim-db.config")

local M = {}

-- The separator between two columns, and the widest a cell may render before it is cut. `SEP` is 3 display
-- CELLS and 5 bytes — the exact discrepancy that makes the cells-vs-bytes rule below non-negotiable.
local SEP = " │ "
local SEP_CELLS = 3
local MAX_CELL = 60

local state = {
    surface = nil, ---@type table?
    buf = nil, ---@type integer?
    win = nil, ---@type integer?  the grid PANEL window (owns the sticky header's winbar)
    ns = api.nvim_create_namespace("LvimDbResult"),
    -- A SECOND namespace, deliberately: `ns` carries the grid's own paint and is cleared and rewritten on
    -- every render, while these marks belong to the LOCKED row and must outlive that.
    ns_edit = api.nvim_create_namespace("LvimDbResultEdit"),
    -- A THIRD namespace for the CURSOR ROW. `cursorline` alone cannot show it: the zebra stripe
    -- (`LvimDbRowAlt`) is a background extmark, and extmarks paint OVER the window's CursorLine — so the
    -- hover vanished on exactly the striped (even) rows. Re-painting the row here as an extmark above the
    -- stripe makes it win on every row. Its own namespace so a cursor move clears just this mark, never the
    -- grid paint (`ns`) or the locked-row marks (`ns_edit`).
    ns_cursor = api.nvim_create_namespace("LvimDbResultCursor"),
    view = "result", ---@type "result"|"log"  which tab is shown
    call_id = nil, ---@type integer?
    conn_id = nil, ---@type integer?
    conn = nil, ---@type string?
    driver = nil, ---@type string?
    statement = nil, ---@type string?  the statement the current page came from (re-run to refresh after a write)
    offset = 0,
    ---@type table?  the rendered grid's LAYOUT — see `render_result`. The sticky header, the column jump and
    --- the inline editor all read it; nil whenever the grid is not showing a result.
    grid = nil,
    active_col = 1, ---@type integer  the column the cursor is in (its header cell is tinted)
    ---@type LvimDbEdit?  the row LOCKED for editing — see `start_edit`. nil when not editing.
    edit = nil,
    page = nil, ---@type table?  the current page { columns, rows, from, has_more, total, affected }
    ---@type table[]  the session CALL LOG (newest last): { call_id, conn_id, conn, driver, statement, state, ms, rows }
    calls = {},
    log_rows = {}, ---@type table[]  line → call descriptor for the log view
    ---@type table?  where the current rows CAME FROM — `{ schema, object, key }` — set only when the run was
    --- a single-OBJECT preview (the drawer's `Data` facet). nil for an ad-hoc statement, and that is not a
    --- gap: an arbitrary query has no answer to "which table is this cell", so its rows are not addressable
    --- and the grid stays read-only. `key` is the object's identifying columns, resolved lazily (see
    --- `resolve_key`): the PRIMARY-key index's columns for SQL, `_id` for mongo.
    origin = nil,
}

---@return boolean
local function is_open()
    return state.surface ~= nil and state.buf ~= nil and api.nvim_buf_is_valid(state.buf)
end

-- ── cells, not bytes ─────────────────────────────────────────────────────────
--
-- The grid has ONE coordinate system for width and position: display CELLS. That is not tidiness, it is the
-- only system the pieces agree in — `leftcol` (what the sticky header has to track) is in cells, `│` is 3
-- bytes and 1 cell, and a Cyrillic letter is 2 bytes and 1 cell. The first cut of this grid mixed all three:
-- header widths in BYTES, truncation slicing BYTES, padding in CELLS. On ASCII the three agree and it looked
-- right; on the user's own data it did not — a Cyrillic header made its column its byte-length too wide, and
-- a byte-sliced value rendered as `<d1>` (a character cut in half). Any header sliced against `leftcol` on
-- top of that model was measuring one thing and cutting another, which is why it drifted on a real grid.
--
-- Bytes appear below ONLY where the API demands them (extmark columns), and are converted explicitly.

local strwidth = api.nvim_strwidth

--- Flatten a display string: every ASCII control character becomes a space. A raw newline would split the
--- row and a tab would expand to a tabstop — either way the column stops being the width we measured.
--- The class is written out as an explicit ASCII range rather than `%c`: Lua's character classes are
--- byte-wise and locale-bound, so `%c` can match UTF-8 continuation bytes (0x80-0xBF) and shred a
--- multibyte character — the very bug this section exists to prevent.
---@param s string
---@return string
local function flatten(s)
    return (s:gsub("[%z\1-\31\127]", " "))
end

--- The first `n` display CELLS of `s`. A wide character straddling the edge is dropped whole and replaced by
--- spaces for the cells it would have covered, so the result is EXACTLY `n` cells wide — dropping it
--- silently would shift everything after it a cell to the left.
---@param s string
---@param n integer
---@return string
local function take_cells(s, n)
    if n <= 0 then
        return ""
    end
    if strwidth(s) <= n then
        return s
    end
    local pos = vim.str_utf_pos(s)
    local w = 0
    for i = 1, #pos do
        local b = pos[i]
        local e = (pos[i + 1] or (#s + 1)) - 1
        local cw = strwidth(s:sub(b, e))
        if w + cw > n then
            return s:sub(1, b - 1) .. string.rep(" ", n - w)
        end
        w = w + cw
    end
    return s
end

--- Cut `s` to at most `max` display CELLS, marking the cut with `…`. Never splits a character.
---@param s string
---@param max integer
---@return string text, boolean truncated
local function cut_cells(s, max)
    if strwidth(s) <= max then
        return s, false
    end
    return take_cells(s, max - 1) .. "…", true -- the ellipsis costs a cell of its own
end

--- Drop the first `n` display CELLS off `s` — the horizontal-scroll slice. A wide character straddling the
--- cut contributes its overhanging cells as spaces, so what remains stays aligned with the rows below it.
---@param s string
---@param n integer
---@return string
local function drop_cells(s, n)
    if n <= 0 then
        return s
    end
    local pos = vim.str_utf_pos(s)
    local w = 0
    for i = 1, #pos do
        local b = pos[i]
        if w >= n then
            return s:sub(b)
        end
        local e = (pos[i + 1] or (#s + 1)) - 1
        w = w + strwidth(s:sub(b, e))
        if w > n then
            return string.rep(" ", w - n) .. s:sub(e + 1)
        end
    end
    return ""
end

--- Pad `s` to `w` display CELLS.
---@param s string
---@param w integer
---@return string
local function pad_cells(s, w)
    return s .. string.rep(" ", math.max(0, w - strwidth(s)))
end

--- Drop trailing spaces. The grid pads every cell to its column width, so a cell's trailing run of spaces is
--- indistinguishable from its padding — see `save_edit`, which compares TRIMMED text on both sides so a
--- value that genuinely ends in a space is read as unchanged (and left alone) rather than silently rewritten
--- without it.
---@param s string
---@return string
local function rtrim(s)
    return (s:gsub("%s+$", ""))
end

--- Re-indent a COMPACT json string (what `vim.json.encode` emits — no whitespace) into a readable one.
--- A string REFORMATTER, not a re-encoder: it walks the valid json text and inserts newlines + 2-space
--- indent around structural punctuation, leaving values byte-for-byte intact. Working on the text (rather
--- than re-encoding a Lua table) sidesteps the array-vs-object ambiguity of an empty Lua table, and keeps
--- extended-JSON forms (`{"$oid": …}`) exactly as they were.
---@param s string
---@return string
local function pretty_json(s)
    local out, indent, i, n = {}, 0, 1, #s
    local in_str, esc = false, false
    local function nl()
        out[#out + 1] = "\n" .. string.rep("  ", indent)
    end
    while i <= n do
        local c = s:sub(i, i)
        if in_str then
            out[#out + 1] = c
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                in_str = false
            end
        elseif c == '"' then
            in_str = true
            out[#out + 1] = c
        elseif c == "{" or c == "[" then
            local nxt = s:sub(i + 1, i + 1)
            if nxt == "}" or nxt == "]" then
                out[#out + 1] = c .. nxt -- an empty container stays on one line
                i = i + 1
            else
                indent = indent + 1
                out[#out + 1] = c
                nl()
            end
        elseif c == "}" or c == "]" then
            indent = math.max(0, indent - 1)
            nl()
            out[#out + 1] = c
        elseif c == "," then
            out[#out + 1] = c
            nl()
        elseif c == ":" then
            out[#out + 1] = ": "
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

-- Per-VALUE type icons for the row popup's field keys (all single-width Nerd codepoints, verified). Built
-- with nr2char so the glyphs are never mangled in source; a field shows WHAT KIND of value it holds.
---@type table<string, string>
local TYPE_ICON = {
    key = vim.fn.nr2char(0xEA93), -- ObjectId / id
    number = vim.fn.nr2char(0xEA90), -- number
    date = vim.fn.nr2char(0xF00ED), -- date/time
    bool = vim.fn.nr2char(0xEA8F), -- boolean
    string = vim.fn.nr2char(0xEB8D), -- string
    json = vim.fn.nr2char(0xEB0F), -- nested document / array / json
    null = vim.fn.nr2char(0xEABD), -- null / bytes
}

--- The type icon for a raw cell value — ObjectId, number, date, bool, document, null, or plain string.
---@param raw any
---@return string
local function value_icon(raw)
    if raw == nil or raw == vim.NIL then
        return TYPE_ICON.null
    end
    local t = type(raw)
    if t == "number" then
        return TYPE_ICON.number
    end
    if t == "boolean" then
        return TYPE_ICON.bool
    end
    if t == "table" then
        if raw.__oid ~= nil then
            return TYPE_ICON.key
        end
        if raw.__int ~= nil then
            return TYPE_ICON.number
        end
        if raw.__ext ~= nil then
            return raw.__ext == "$date" and TYPE_ICON.date or TYPE_ICON.number
        end
        if raw.__bytes ~= nil then
            return TYPE_ICON.null
        end
        return TYPE_ICON.json -- a nested document or array
    end
    return TYPE_ICON.string
end

--- Render one cell value to a display string + a highlight group.
---@param v any
---@return string text, string? hl
local function cell_display(v)
    if v == nil or v == vim.NIL then
        return "NULL", "LvimDbCellNull"
    end
    local t = type(v)
    if t == "number" then
        return tostring(v), "LvimDbCellNumber"
    elseif t == "boolean" then
        return tostring(v), "LvimDbCellNumber"
    elseif t == "table" then
        -- A TAGGED value from the daemon — a value whose TYPE had to survive the trip because two different
        -- things would otherwise render the same. It still shows as the plain thing a human wants to read
        -- (an ObjectId as its hex); the tag exists so the row can be addressed, not to be looked at.
        if type(v.__oid) == "string" then
            return v.__oid, "LvimDbCellNumber"
        end
        if type(v.__int) == "string" then
            -- a big integer the daemon sent as exact decimal TEXT (JSON numbers lose precision above 2^53)
            return v.__int, "LvimDbCellNumber"
        end
        if type(v.__ext) == "string" then
            -- a tagged date/decimal (`{ __ext = "$date"|"$numberDecimal", v = text }`): show the readable
            -- value; a decimal takes the number tint.
            return tostring(v.v), v.__ext == "$numberDecimal" and "LvimDbCellNumber" or nil
        end
        if type(v.__bytes) == "string" then
            return ("<%d bytes>"):format(tonumber(v.len) or 0), "LvimDbCellNull"
        end
        return vim.json.encode(v), nil
    end
    return tostring(v), nil
end

---@type fun()  forward declaration: paint_edit is defined far below but render_result (above it) re-applies it
local paint_edit

--- Write lines + extmark highlights into the dock buffer.
---@param lines string[]
---@param hls table[]  { line, col_start, col_end, group }
local function write_buf(lines, hls)
    vim.bo[state.buf].modifiable = true
    api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    -- ALSO clear the edit namespace: any buffer rewrite (e.g. switching to the call log) must not leave the
    -- lock/pending-cell tints painted over the new content; render_result re-applies them when state.edit is set.
    api.nvim_buf_clear_namespace(state.buf, state.ns_edit, 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_set_extmark, state.buf, state.ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
end

--- Paint the CURSOR ROW so it wins over the zebra stripe. `cursorline` is drawn UNDER buffer extmarks, so on
--- a striped (even) row `LvimDbRowAlt`'s background hid the hover completely — the row under the cursor read
--- as untinted every other line. Re-painting it as a `line_hl_group` extmark above the grid paint restores it
--- on every row; the group is the same `LvimDbCursorLine`, so the rows where the built-in cursorline already
--- showed look unchanged. Cheap: one mark, cleared and re-set per cursor move.
local function paint_cursor_row()
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    api.nvim_buf_clear_namespace(state.buf, state.ns_cursor, 0, -1)
    if state.view ~= "result" or not state.grid then
        return
    end
    if not (state.win and api.nvim_win_is_valid(state.win)) then
        return
    end
    local ok, cur = pcall(api.nvim_win_get_cursor, state.win)
    if not ok then
        return
    end
    pcall(api.nvim_buf_set_extmark, state.buf, state.ns_cursor, cur[1] - 1, 0, {
        line_hl_group = "LvimDbCursorLine",
        -- Above the stripe and the cell marks (default extmark priority 4096) so this background is the one
        -- that lands; those cell groups carry only a foreground, which still merges through.
        priority = 5000,
    })
end

-- state → highlight group for the call-log accent.
local STATE_HL = {
    running = "LvimDbStateRunning",
    done = "LvimDbStateDone",
    failed = "LvimDbStateFailed",
    cancelled = "LvimDbStateCancelled",
}

--- Render the session CALL LOG: one row per call with a state accent.
local function render_log()
    state.log_rows = {}
    local lines, hls = {}, {}
    if #state.calls == 0 then
        write_buf({ "", "  no calls yet" }, { { 1, 0, 14, "LvimDbEmpty" } })
        return
    end
    -- newest first
    for i = #state.calls, 1, -1 do
        local c = state.calls[i]
        local st = (c.state or "running"):upper()
        -- Pad/cut by DISPLAY CELLS (not bytes) so a Cyrillic conn name or SQL literal never misaligns the
        -- columns or gets shredded mid-UTF-8 (the "cells, not bytes" canon).
        local meta = ("%-9s %5sms  %s"):format(st, tostring(c.ms or "·"), pad_cells(c.conn or "", 10))
        local stmt = (cut_cells((c.statement or ""):gsub("[\n\r]+", " "), 90))
        local line = " " .. meta .. "  " .. stmt
        local lineno = #lines
        lines[#lines + 1] = line
        hls[#hls + 1] = { lineno, 0, 1 + #st, STATE_HL[c.state] or "LvimDbStateRunning" }
        state.log_rows[lineno + 1] = c
    end
    write_buf(lines, hls)
end

--- Point the grid window's sticky header at `M.winbar` (or clear it — the call log has no columns).
--- Re-asserted from `render_result` rather than set once at open: a panel that is re-opened / re-docked gets
--- a FRESH window, and a fresh window has no winbar.
---@param on boolean
local function set_winbar(on)
    if not (state.win and api.nvim_win_is_valid(state.win)) then
        return
    end
    -- `%!` = evaluate on every redraw of THIS window. Every group the bar paints is named inline (`%#…#`),
    -- including its padding, so the window's own WinBar group never shows through and lvim-ui's winhighlight
    -- is left exactly as the chassis set it.
    vim.wo[state.win].winbar = on and "%!v:lua.require'lvim-db.ui.result'.winbar()" or ""
end

--- Render the current page into the dock buffer as an aligned grid, and build `state.grid` — the layout the
--- sticky header, the column jump and the inline editor all read.
---
--- The COLUMN HEADER is deliberately NOT a line in this buffer: it is the window's winbar (see `M.winbar`).
--- A winbar cannot scroll, which is the whole point — and it also makes buffer line `ri` exactly result row
--- `ri`, so no caller has to remember to add one for a header line.
local function render_result()
    if not is_open() then
        return
    end
    state.grid = nil
    local page = state.page or { columns = {}, rows = {} }
    local cols = page.columns or {}
    local rows = page.rows or {}

    -- affected-count / empty statements have no columns
    if #cols == 0 then
        set_winbar(false)
        local msg = page.affected ~= nil and (("%d row(s) affected"):format(page.affected)) or "(no result)"
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_lines(state.buf, 0, -1, false, { "", "  " .. msg })
        vim.bo[state.buf].modifiable = false
        return
    end

    -- Column widths — CELLS on both sides of the max. (`#col.name` counted BYTES, so every non-ASCII header
    -- made its own column that many cells too wide.)
    local gcols, cells = {}, {}
    for ci, col in ipairs(cols) do
        gcols[ci] = { name = col.name, type = col.type, label = flatten(col.name), width = 0 }
        gcols[ci].width = strwidth(gcols[ci].label)
    end
    for ri, row in ipairs(rows) do
        cells[ri] = {}
        for ci = 1, #cols do
            local disp, hl = cell_display(row[ci])
            local text, truncated = cut_cells(flatten(disp), MAX_CELL)
            cells[ri][ci] = { text = text, hl = hl, truncated = truncated }
            gcols[ci].width = math.max(gcols[ci].width, strwidth(text))
        end
    end

    -- Each column's first display CELL in a row line. Uniform across rows — that IS the alignment — which is
    -- what lets the winbar slice the header by `leftcol` and land on the same columns as the rows below.
    --   line = " " col1 SEP col2 SEP … " "
    local at = 1 -- the leading space
    for ci = 1, #gcols do
        gcols[ci].start = at
        at = at + gcols[ci].width + SEP_CELLS
    end

    local lines, hls = {}, {}
    for ri, row in ipairs(cells) do
        local parts, bpos = {}, 1 -- byte offset within the line (past the leading space)
        for ci = 1, #gcols do
            parts[ci] = pad_cells(row[ci].text, gcols[ci].width)
            -- BYTE geometry, per row: a padded cell's byte length depends on its own characters, so unlike
            -- `start` this cannot be shared. The inline editor anchors its extmarks on exactly this range.
            row[ci].bstart, row[ci].blen = bpos, #parts[ci]
            bpos = bpos + #parts[ci] + #SEP
        end
        local line = " " .. table.concat(parts, SEP) .. " "
        local lineno = #lines
        lines[#lines + 1] = line
        if ri % 2 == 0 then
            hls[#hls + 1] = { lineno, 0, #line, "LvimDbRowAlt" }
        end
        for ci = 1, #gcols do
            local hl = row[ci].hl
            if hl then
                hls[#hls + 1] = { lineno, row[ci].bstart, row[ci].bstart + row[ci].blen, hl }
            end
        end
    end

    state.grid = { cols = gcols, rows = cells }
    if state.active_col > #gcols then
        state.active_col = 1
    end
    write_buf(lines, hls)
    set_winbar(true)
    -- A locked/edited row must survive a view round-trip (r ⇄ L) VISIBLY: re-apply the edit tints after the
    -- grid repaint (write_buf cleared ns_edit). `M.run` owns killing state.edit, so this only fires mid-edit.
    if state.edit then
        paint_edit()
    end
end

--- The STICKY column header — Neovim evaluates this on every redraw of the grid window (its `winbar` is
--- `%!v:lua.…`), so it is a pure function of where the grid is scrolled RIGHT NOW.
---
--- That is what makes it correct rather than merely usually-correct: there is no event to subscribe to, no
--- cached position to invalidate and nothing to keep in step — the header cannot lag the rows because it is
--- recomputed from them. MEASURED against the real grid: exactly one evaluation per horizontal scroll, with
--- `leftcol` stepping 0 → 40 → 65 in lockstep.
---
--- `g:statusline_winid` is the window being drawn. Reading `leftcol` from the CURRENT window instead is the
--- classic way this goes wrong — the grid is often not focused while it redraws.
---@return string
function M.winbar()
    local g = state.grid
    local win = vim.g.statusline_winid
    if not (g and win and win ~= 0 and api.nvim_win_is_valid(win)) then
        return ""
    end
    local leftcol = api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    local width = api.nvim_win_get_width(win)

    -- Emit the header a segment at a time, in CELLS: skip what is scrolled off to the left, stop at the
    -- window's right edge, and pad the remainder — so the bar is exactly `width` cells and never depends on
    -- statusline truncation (which cuts at the START by default and would shift the header off the columns).
    local out, used, skip = {}, 0, leftcol
    local function emit(text, group)
        if used >= width then
            return
        end
        local w = strwidth(text)
        if skip >= w then
            skip = skip - w
            return
        end
        if skip > 0 then
            text = drop_cells(text, skip)
            w = strwidth(text)
            skip = 0
        end
        if used + w > width then
            text = take_cells(text, width - used)
            w = strwidth(text)
        end
        used = used + w
        -- a `%` in a column name is a statusline ITEM introducer — escape it or the header goes haywire
        out[#out + 1] = "%#" .. group .. "#" .. text:gsub("%%", "%%%%")
    end

    -- The active column's bright bg covers ONLY its own label+padding; the `│` separators and the leading /
    -- trailing pad stay the normal header blue. (An earlier try extended the bright over the flanking
    -- separators to read as a solid block, but that made the active column bleed into its neighbours —
    -- reverted at the user's call.)
    emit(" ", "LvimDbHeader")
    for ci, col in ipairs(g.cols) do
        if ci > 1 then
            emit(SEP, "LvimDbHeader")
        end
        emit(pad_cells(col.label, col.width), ci == state.active_col and "LvimDbHeaderActive" or "LvimDbHeader")
    end
    emit(" ", "LvimDbHeader")
    if used < width then
        out[#out + 1] = "%#LvimDbHeader#" .. string.rep(" ", width - used)
    end
    return table.concat(out)
end

--- Render whichever tab is active.
local function render()
    if not is_open() then
        return
    end
    if state.view == "log" then
        render_log()
    else
        render_result()
    end
    -- The rewrite above replaced the lines the cursor mark was anchored to — re-assert it.
    paint_cursor_row()
end

--- The dock TITLE (left of the header): which database + object the current rows came from — `db ➤ object`
--- (`➤` the set-wide breadcrumb separator). Falls back to the connection name for an ad-hoc query (no
--- object), and names the call-log view when it is showing.
---@return string
local function title_left()
    if state.view == "log" then
        return ("Call log  (%d calls)"):format(#state.calls)
    end
    local o = state.origin
    if o and o.object then
        local db = (o.schema and o.schema ~= "") and o.schema or (state.conn or "")
        return db ~= "" and ("%s ➤ %s"):format(db, o.object) or o.object
    end
    return state.conn or "Result"
end

--- The dock COUNTER (right of the header): which records of the total are shown — "1–20/536". Empty in the
--- call-log view and before any page has loaded. `total` shows `?` when the driver did not report a count.
---@return string
local function range_text()
    if state.view ~= "result" then
        return ""
    end
    local page = state.page
    if not (page and page.rows) then
        return ""
    end
    local n = #page.rows
    if n == 0 then
        return "0"
    end
    local from = (page.from or 0) + 1
    local to = (page.from or 0) + n
    -- Total, best source first: the object's COUNT (`fetch_total`, shown immediately for a table browse), else
    -- the daemon's own count once it has streamed to the END (an ad-hoc query has no object to count), else
    -- `?` while it is genuinely unknown. Never the raw `vim.NIL` sentinel.
    local o = state.origin
    local total = (o and type(o.count) == "number" and tostring(o.count))
        or (type(page.total) == "number" and tostring(page.total))
        or "?"
    return ("%d–%d/%s"):format(from, to, total)
end

--- The header tab-bar spec, marking the CURRENT view's tab active — declared here, defined with the other
--- bar specs below (it needs `set_view` as the tabs' action, which is defined just above).
---@type fun(): table
local header_spec

--- Switch the active tab and re-render + re-title. Rebuilds the header too, so the ACTIVE tab (a solid
--- highlight, see `header_spec`) follows the view — the tab is the persistent "which view am I in" marker,
--- independent of which sector has focus.
---@param view "result"|"log"
local function set_view(view)
    state.view = view
    render()
    -- The header carries BOTH the title/counter (a `title_counter` band) and the tabs, so rebuilding it is
    -- the single "refresh the top of the dock" call — the active tab, the `db ➤ object` title and the range
    -- counter all re-derive from the new view.
    if state.surface and state.surface.set_header then
        pcall(state.surface.set_header, header_spec())
    end
end

--- Fetch a page at `offset` and re-render.
---@param offset integer
local function goto_page(offset)
    if not state.call_id then
        return
    end
    require("lvim-db").page(state.call_id, offset, config.page_size, function(page, err)
        if err or not page or not page.ready then
            return
        end
        state.offset = page.from or offset
        state.page = page
        vim.schedule(function()
            render()
            -- rebuild the header so the range counter (1–20/536) follows the new page
            if state.surface and state.surface.set_header then
                pcall(state.surface.set_header, header_spec())
            end
        end)
    end)
end

--- Yank the whole current page as TSV to the clipboard.
local function yank_page()
    local page = state.page
    if not page or not page.columns then
        return
    end
    local out = {}
    local head = {}
    for _, c in ipairs(page.columns) do
        head[#head + 1] = c.name
    end
    out[1] = table.concat(head, "\t")
    for _, row in ipairs(page.rows or {}) do
        local r = {}
        for ci = 1, #page.columns do
            r[ci] = (cell_display(row[ci]))
        end
        out[#out + 1] = table.concat(r, "\t")
    end
    local text = table.concat(out, "\n")
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    vim.notify(("lvim-db: yanked %d rows (TSV)"):format(#(page.rows or {})), vim.log.levels.INFO)
end

--- Export the current page to a temp TSV file and open it.
local function export_page()
    local page = state.page
    if not page then
        return
    end
    yank_page() -- reuse the TSV builder via the register
    local text = vim.fn.getreg('"')
    local path = vim.fn.stdpath("state") .. "/lvim-db/export-" .. os.time() .. ".tsv"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(text, "\n"), path)
    vim.notify("lvim-db: exported to " .. path, vim.log.levels.INFO)
end

-- ── addressing a row (what makes editing possible at all) ────────────────────
--
-- To change or delete ONE row, the grid must be able to name that row and no other. Two things are needed
-- and BOTH can be absent, in which case the honest answer is "read-only", not a best guess:
--
--   1. an ORIGIN — these rows are one object's. An arbitrary JOIN has no answer to "which table does this
--      cell belong to", so only the drawer's `Data` facet marks a result as addressable.
--   2. a KEY — the object's identifying columns. Without one, `UPDATE … WHERE question = '…'` could match
--      several rows and quietly rewrite them all; that is data loss wearing a helpful face.
--
-- The key comes from the COLUMNS (`Column.primary`), not from the primary INDEX. They disagree, and the
-- disagreement is not exotic: sqlite makes NO index for `id INTEGER PRIMARY KEY` — that column is the rowid
-- alias — so an index-derived key calls an obviously-keyed table unaddressable (measured; it was the first
-- design here and it failed on the user's own database). Every engine reports the key per column instead:
-- sqlite/duckdb `PRAGMA table_info.pk`, mysql `COLUMN_KEY='PRI'`, postgres `pg_index.indisprimary`, mssql
-- `sys.indexes.is_primary_key`, CQL `kind IN (partition_key, clustering)`, mongo `_id`.

--- Resolve the current origin's KEY columns, then call `cb(key|nil)`. Cached on the origin: it is a property
--- of the object, and re-asking on every keystroke would put a round-trip in the edit path.
---@param cb fun(key: string[]?)
local function resolve_key(cb)
    local o = state.origin
    if not (o and state.conn_id) then
        return cb(nil)
    end
    if o.key then
        return cb(#o.key > 0 and o.key or nil)
    end
    require("lvim-db").columns(state.conn_id, { name = o.object, schema = o.schema }, function(cols, err)
        -- Do NOT cache a key on an RPC error — an empty result would remember the object as keyless
        -- (read-only) forever. Surface the reason and leave `o.key` nil so the next attempt retries.
        if err then
            vim.notify("lvim-db: could not resolve key: " .. tostring(err), vim.log.levels.WARN)
            return cb(nil)
        end
        local key = {}
        for _, c in ipairs(cols or {}) do
            if c.primary then
                key[#key + 1] = c.name
            end
        end
        o.key = key -- remember even when EMPTY: "this object has no key" is an answer worth not re-asking
        cb(#key > 0 and key or nil)
    end)
end

--- Why the current result cannot be edited, or nil when it can. A sentence, not a boolean: the user should
--- learn WHY a grid is read-only instead of finding the keys silently inert.
---@return string?
local function readonly_reason()
    local o = state.origin
    if not o then
        return "this result is not one object's rows — open a table's Data facet to edit"
    end
    -- Ask the DIALECT before the data: an engine that cannot express "update this one row" makes the key
    -- question moot, and saying so up front beats letting the user type an edit that could never be sent.
    local ok, why = require("lvim-db.query").can_update_row(state.driver)
    if not ok then
        return why
    end
    if o.key and #o.key == 0 then
        return ("'%s' has no primary key — a row cannot be addressed uniquely"):format(o.object)
    end
    return nil
end

--- Count the origin object's TOTAL rows (COUNT(*) / mongo `count`) and stash it on the origin, then rebuild
--- the header so the counter reads `1–N / <total>` right away instead of `?` (the daemon only learns the
--- total by streaming to the END, which for a big table never happens on the first page). Runs through the
--- LOW-LEVEL `db.execute` — NOT `M.run` — so this background count never appears in the call log or replaces
--- the visible result. Cached on the origin (a property of the object); a driver with no cheap count (redis)
--- returns no statement and the counter stays `?`.
---@param origin table  the SAME table set on `state.origin` (identity-checked before it is used, so a later
---       run's count cannot land on this one)
local function fetch_total(origin)
    if not (state.conn_id and state.driver) then
        return
    end
    local stmt = require("lvim-db.query").count_statement(state.driver, origin.schema, origin.object)
    if not stmt then
        return
    end
    local db = require("lvim-db")
    local cid
    db.execute(state.conn_id, stmt, function(st)
        if st.state ~= "done" or not cid then
            return
        end
        db.page(cid, 0, 1, function(page)
            local row = page and page.rows and page.rows[1]
            if row then
                -- the count is the first NUMBER in the one result row (SQL `COUNT(*) AS n`, mongo `{ n, ok }`, …)
                local total
                for _, v in ipairs(row) do
                    if type(v) == "number" then
                        total = v
                        break
                    end
                end
                if type(total) == "number" and state.origin == origin then
                    origin.count = total
                    vim.schedule(function()
                        if state.surface and state.surface.set_header then
                            pcall(state.surface.set_header, header_spec())
                        end
                    end)
                end
            end
            -- the count call is a throwaway; free its server-side buffer immediately.
            require("lvim-db").release(cid)
        end)
    end, function(call_id)
        cid = call_id
    end)
end

-- ── moving by COLUMN ─────────────────────────────────────────────────────────
--
-- Every column is rendered, always. Paging the grid sideways a screen at a time was considered and dropped:
-- a column you cannot see is a column you forget the table has, and the widths are already known — so the
-- grid stays one wide surface and the CURSOR does the travelling.

--- Which column display cell `cell` falls in (the last column whose `start` it has reached).
---@param cell integer
---@return integer
local function column_at(cell)
    local g = state.grid
    if not g then
        return 1
    end
    local ci = 1
    for i, col in ipairs(g.cols) do
        if cell >= col.start then
            ci = i
        end
    end
    return ci
end

--- The column the cursor is in, from its DISPLAY cell (`virtcol` is 1-based, `col.start` is 0-based-ish in
--- the same run of cells — hence the -1).
---@return integer
local function cursor_column()
    if not (state.win and api.nvim_win_is_valid(state.win)) then
        return 1
    end
    return column_at(api.nvim_win_call(state.win, function()
        return vim.fn.virtcol(".") - 1
    end))
end

--- Track the active column as the cursor moves and re-tint the header when it changes. `redrawstatus`
--- re-evaluates the winbar (Neovim redraws the status line AND the window bar) — needed because a cursor
--- move WITHIN a line does not otherwise force the bar to re-run.
local function track_column()
    if state.view ~= "result" or not state.grid then
        return
    end
    local ci = cursor_column()
    if ci ~= state.active_col then
        state.active_col = ci
        pcall(vim.cmd, "redrawstatus")
    end
end

--- Jump the cursor to column `ci`'s first cell and scroll that column fully into view.
---@param ci integer
local function goto_column(ci)
    local g = state.grid
    if not (g and g.cols[ci] and state.win and api.nvim_win_is_valid(state.win)) then
        return
    end
    local col = g.cols[ci]
    api.nvim_win_call(state.win, function()
        local lnum = api.nvim_win_get_cursor(state.win)[1]
        -- CELLS → the byte column of that cell on THIS row: the two differ per row (Cyrillic is 2 bytes and 1
        -- cell), and `virtcol2col` is the conversion Neovim already owns — recomputing it here would be a
        -- second, worse copy of it.
        local bcol = vim.fn.virtcol2col(state.win, lnum, col.start + 1)
        api.nvim_win_set_cursor(state.win, { lnum, math.max(0, bcol - 1) })
        -- Position the VIEW, not just the cursor: landing the cursor scrolls only far enough to show the
        -- cursor itself, which leaves the rest of a wide column off the right edge. Show the whole column
        -- when it fits; otherwise put its first cell at the left edge.
        local view = vim.fn.winsaveview()
        local width = api.nvim_win_get_width(state.win)
        local left, right = col.start, col.start + col.width
        local leftcol = view.leftcol
        if left < leftcol then
            -- The FIRST column owns the grid's leading margin, so reaching it means scrolling fully home —
            -- landing on `start` instead would clip that margin and leave the grid looking scrolled when it
            -- is not.
            leftcol = ci == 1 and 0 or left
        elseif right > leftcol + width then
            leftcol = math.min(left, math.max(0, right - width))
        end
        if leftcol ~= view.leftcol then
            view.leftcol = leftcol
            vim.fn.winrestview(view)
        end
    end)
    state.active_col = ci
    pcall(vim.cmd, "redrawstatus")
end

--- `next_column`: the column after the cursor's, wrapping at the last.
local function next_column()
    local g = state.grid
    if state.view ~= "result" or not g or #g.cols == 0 then
        return
    end
    goto_column(cursor_column() % #g.cols + 1)
end

--- `prev_column`: the column before the cursor's, wrapping at the first.
local function prev_column()
    local g = state.grid
    if state.view ~= "result" or not g or #g.cols == 0 then
        return
    end
    goto_column((cursor_column() - 2) % #g.cols + 1)
end

-- ── editing a row ────────────────────────────────────────────────────────────
--
-- `e` LOCKS the focused row: the row is pinned to the key values it had at that moment and tinted so it
-- reads as the one live row. `<CR>` on a cell opens that ONE field in a popup, holding the value itself;
-- `S` writes exactly one `UPDATE … SET … WHERE key=…` carrying every field that changed; `c` throws the
-- whole edit away.
--
-- NOTHING is typed into the grid buffer, and that is the design, not a shortcut. What the grid shows is a
-- PADDED, TRUNCATED, FLATTENED rendering of a value — a `…` prefix, spaces that may be padding or may be
-- data, a tab drawn as a space, a whole BSON document reduced to one line of JSON. Typing on that text means
-- editing a picture of the value and hoping it can be read back into the thing it depicts; for a truncated
-- cell it cannot (writing it back writes the prefix over the real value), and for a document it never could.
-- So the value is edited where the value actually is: in a field seeded from the raw row data.
--
-- The lock is by KEY, not by line: the WHERE is built from the key values captured when the row was locked,
-- so editing a key field re-points nothing — the statement still addresses the row the user chose. (Reading
-- the key back at save time would let a typo in the id field silently rewrite a DIFFERENT row.)
--
-- Only CHANGED fields reach the SET, so a field the user never opened is never rewritten.

--- The LOCKED row. `where` is captured once, when the row is locked, and never re-read — that is what makes
--- the lock a lock: the statement addresses the row the user chose, whatever they then type into a key field.
---@class LvimDbEdit
---@field ri integer                            the result row (== the buffer line) being edited
---@field where { name: string, value: any }[]  the key columns and the values they had at lock time
---@field row any[]                             the row's RAW values, as the page delivered them
---@field pending table<integer, { value: any }>  ci → the new value, for fields changed but not yet written

--- A column whose value has no faithful SCALAR text round-trip on `driver`, keyed on the engine's OWN type
--- name (`col.type`) rather than the received `Value` shape. Some hazards the shape cannot reveal: a Snowflake
--- VARIANT/OBJECT/ARRAY and a Postgres BYTEA both arrive as plain text, so the shape-based `field_editable`
--- would wave them through — but writing the text back as a bare `'…'` literal stores a QUOTED STRING on a
--- VARIANT (Snowflake needs `PARSE_JSON`) or hand-mangled hex on BYTEA. View-only, like the Bytes/structured
--- guard. Returns the reason it is view-only, or nil when the type is freely editable (the common case).
---@param driver string
---@param coltype string?
---@return string?
local function structured_type(driver, coltype)
    if type(coltype) ~= "string" or coltype == "" then
        return nil
    end
    local t = coltype:upper()
    if driver == "snowflake" then
        -- Semi-structured (VARIANT/OBJECT/ARRAY) prints as JSON but is stored parsed; a plain string literal
        -- would land as a VARIANT-wrapped STRING, not the structure. BINARY has no text surface.
        if t == "VARIANT" or t == "OBJECT" or t == "ARRAY" then
            return "semi-structured value — view only (needs a typed constructor to write back)"
        end
        if t == "BINARY" then
            return "binary value — view only"
        end
    elseif driver == "postgres" then
        -- bytea prints as `\x…` hex; editing that by hand is a footgun with no faithful UX (arrays and
        -- json/jsonb DO round-trip: their text form is the engine's own input form, which it re-parses).
        if t == "BYTEA" then
            return "binary value — view only"
        end
    end
    return nil
end

--- The value to write for a re-typed field. The popup edits TEXT, so the new text is read against the
--- ORIGINAL value's type — a number stays a number, and `NULL` is the same sentinel the grid displays for
--- one. Anything else goes to the engine as a string literal for IT to coerce: it is the authority on its own
--- column types, and a second type system here could only disagree with it. `coltype` (the engine's declared
--- column type) closes the gaps a value SHAPE cannot — see `structured_type`; this is the last-line guard the
--- popup save relies on, since it coerces without a pre-open `field_editable` check.
---@param text string
---@param orig any
---@param driver string
---@param coltype string?
---@param colname string?
---@return any value, string? err
local function coerce(text, orig, driver, coltype, colname)
    if driver == "mongodb" and colname == "_document" then
        return nil, "synthetic whole-document column — view only"
    end
    local sty = structured_type(driver, coltype)
    if sty then
        return nil, sty
    end
    if text == "NULL" then
        return nil
    end
    if type(orig) == "number" then
        return tonumber(text) or text
    elseif type(orig) == "boolean" then
        local l = text:lower()
        if l == "true" or l == "1" then
            return true
        elseif l == "false" or l == "0" then
            return false
        end
        return text
    elseif type(orig) == "table" then
        -- A tagged / structured value. An ObjectId is edited as its hex (the daemon re-checks it via
        -- `Bson::try_from`); a nested document/array is edited as EXTENDED JSON and PARSED here — the parse is
        -- the syntax gate (Lua's job) and also how the value re-enters the statement as structure, not a
        -- string, so the daemon's `Bson::try_from` reconstructs its BSON types (`$oid`/`$date`/…). Binary and
        -- a structured value on a non-mongo engine have no faithful text round-trip — refused (see
        -- `field_editable`, which stops these before the field even opens; this is the last-line guard).
        if type(orig.__oid) == "string" then
            return { __oid = vim.trim(text) }
        end
        if type(orig.__int) == "string" then
            -- keep the edited digits as an exact-integer tag so M.literal emits them verbatim (unquoted)
            return { __int = vim.trim(text) }
        end
        if type(orig.__ext) == "string" then
            -- a tagged date/decimal: re-wrap the edited text under its extended-JSON key so the daemon's
            -- `Bson::try_from` reconstructs the BSON type ({ "$date" = … } / { "$numberDecimal" = … }).
            return { [orig.__ext] = vim.trim(text) }
        end
        if type(orig.__bytes) == "string" then
            return nil, "binary value cannot be edited as text"
        end
        if driver == "mongodb" then
            local ok, parsed = pcall(vim.json.decode, text)
            if not ok then
                return nil, "not valid JSON — " .. (tostring(parsed):gsub("^.-:%s*", ""))
            end
            return parsed
        end
        return nil, "structured value cannot be edited as text on this engine"
    end
    return text
end

--- Can this field be edited AND written back faithfully, for `driver`? The client can only judge by the
--- `Value` SHAPE it received (not the real column type). Binary (`{__bytes}`) has no text surface. A
--- structured value (a nested document / array, a `{__oid}` aside) round-trips only where the write path
--- reconstructs it: mongo, via extended JSON → `Bson::try_from`. The same structure on any other engine
--- (e.g. a ClickHouse Array/Tuple/Map, which arrives as JSON) cannot be written back from a JSON-string edit
--- to the engine's native literal, so it is VIEW-ONLY. Scalars are always editable — the ENGINE validates
--- the literal. (Driver-side rendering losses that masquerade as a scalar — a decimal shown as NULL, a date
--- shown as a Rust Debug string — are NOT catchable here; they are separate driver fixes.)
---@param raw any
---@param driver string
---@param coltype string?
---@param colname string?
---@return boolean ok, string? reason
local function field_editable(raw, driver, coltype, colname)
    -- Mongo's synthetic trailing `_document` cell is the WHOLE document; editing it would write a literal
    -- `_document` FIELD into the doc instead of replacing it. Its type is a normal json, so refuse by NAME.
    if driver == "mongodb" and colname == "_document" then
        return false, "synthetic whole-document column — view only"
    end
    -- A type-name guard first: it catches hazards the value SHAPE hides (a Snowflake VARIANT / Postgres bytea
    -- both arrive as plain text). `structured_type` is nil for the common editable case.
    local sty = structured_type(driver, coltype)
    if sty then
        return false, sty
    end
    if type(raw) ~= "table" then
        return true
    end
    if type(raw.__bytes) == "string" then
        return false, "binary value — view only"
    end
    if type(raw.__oid) == "string" then
        return true -- an ObjectId, edited as its hex
    end
    if type(raw.__int) == "string" then
        return true -- a big integer edited as its exact decimal digits
    end
    if driver == "mongodb" then
        return true -- a nested document / array, edited as extended JSON
    end
    return false, "structured value — view only (no faithful text form on this engine)"
end

--- Swap the dock's footer between browsing and editing — declared here, defined with the footer specs below
--- (it needs the browse bar, which needs `edit_row`).
---@type fun()
local refresh_footer

--- Paint the locked row: its own tint, plus a stronger one on every field the user has changed but not yet
--- written. A pending change has to be VISIBLE — it lives only in `state.edit` until `S`, and an edit you
--- cannot see is an edit you lose.
function paint_edit()
    local e, g = state.edit, state.grid
    if not (e and g and is_open()) then
        return
    end
    api.nvim_buf_clear_namespace(state.buf, state.ns_edit, 0, -1)
    api.nvim_buf_set_extmark(state.buf, state.ns_edit, e.ri - 1, 0, { line_hl_group = "LvimDbEditRow" })
    for ci, cell in ipairs(g.rows[e.ri]) do
        if e.pending[ci] then
            pcall(api.nvim_buf_set_extmark, state.buf, state.ns_edit, e.ri - 1, cell.bstart, {
                end_col = cell.bstart + cell.blen,
                hl_group = "LvimDbEditCell",
            })
        end
    end
end

--- Leave edit mode and drop everything pending.
local function cancel_edit()
    if not state.edit then
        return
    end
    state.edit = nil
    if is_open() then
        api.nvim_buf_clear_namespace(state.buf, state.ns_edit, 0, -1)
        render()
    end
    refresh_footer()
end

--- Lock `ri` for editing, keyed on `key`.
---@param ri integer      the result row (== the buffer line)
---@param row table       the row's RAW values (not the display strings)
---@param key string[]    its key columns
local function start_edit(ri, row, key)
    local g = state.grid
    if not (g and g.rows[ri]) then
        return
    end
    local index = {}
    for ci, c in ipairs(g.cols) do
        index[c.name] = ci
    end
    -- Capture the key's ORIGINAL values now — this is the "locked by its key" part.
    local where = {}
    for _, name in ipairs(key) do
        local ci = index[name]
        if not ci then
            -- The key is not in this result (a projection, not `SELECT *`): there is nothing to address the
            -- row by, and guessing one would be a rewrite of some other row.
            vim.notify(
                ("lvim-db: key column '%s' is not in this result — cannot address the row"):format(name),
                vim.log.levels.WARN
            )
            return
        end
        where[#where + 1] = { name = name, value = row[ci] }
    end
    -- `pending[ci] = { value = … }` — a BOX, not the bare value: setting a field to NULL means a pending
    -- `nil`, and a bare nil in a Lua table is indistinguishable from "never touched", so the NULL would be
    -- dropped on the way to the statement.
    state.edit = { ri = ri, where = where, row = row, pending = {} }
    paint_edit()
    refresh_footer()
    vim.notify(
        ("lvim-db: row locked — %s edits a field, %s saves, %s cancels"):format(
            tostring(config.keys.result.edit_cell),
            tostring(config.keys.result.save_edit),
            tostring(config.keys.result.cancel_edit)
        ),
        vim.log.levels.INFO
    )
end

--- `edit_row`: lock the focused row, once it is established that it CAN be addressed. `after` runs once the
--- lock is held — resolving the key is a round trip, so "lock, then open this field" cannot be two statements
--- at the call site.
---@param after fun()?
local function edit_row(after)
    if state.view ~= "result" or state.edit then
        return
    end
    local why = readonly_reason()
    if why then
        vim.notify("lvim-db: read-only — " .. why, vim.log.levels.WARN)
        return
    end
    local ri = api.nvim_win_get_cursor(0)[1]
    local row = state.page and state.page.rows and state.page.rows[ri]
    if not (row and state.grid and state.grid.rows[ri]) then
        return
    end
    resolve_key(function(key)
        if not key then
            vim.notify("lvim-db: read-only — " .. (readonly_reason() or "no key"), vim.log.levels.WARN)
            return
        end
        start_edit(ri, row, key)
        if after and state.edit then
            after()
        end
    end)
end

--- `edit_cell`: the field under the cursor, in a popup ON the cell.
---
--- `bare` + `at` is the one popup shape that can sit on a grid cell (lvim-ui built it for exactly this): no
--- title row and no footer, so the popup IS the field — one row, over the value it edits. A titled popup
--- would be several rows of chrome anchored to the cell, with the field itself landing over the wrong row.
--- Seeded from the RAW value, never from the rendered cell, so a truncated or flattened value is edited
--- whole.
--- Which edit surface fits a value — see `edit_cell`. The rule the user asked for: a value that fits the
--- CELL edits in the cell; one that overflows the cell but still fits the whole ROW edits across the row;
--- anything longer, or MULTI-LINE / a document (JSON, code, paragraphs), edits in the full bottom PANEL.
---@param disp string       the value's display text (may contain newlines)
---@param is_doc boolean    a formatted value (document / json / multi-line) — always the panel
---@param col_width integer the cell's column width, in cells
---@param row_width integer the whole grid's usable width, in cells
---@return "cell"|"row"|"panel"
local function edit_mode(disp, is_doc, col_width, row_width)
    if is_doc or disp:find("\n") then
        return "panel"
    end
    local w = strwidth(flatten(disp))
    if w <= col_width then
        return "cell"
    end
    if w <= row_width then
        return "row"
    end
    return "panel"
end

local function edit_cell()
    local e, g = state.edit, state.grid
    if not (e and g and state.win and api.nvim_win_is_valid(state.win)) then
        return
    end
    local ci = cursor_column()
    local col, cell = g.cols[ci], g.rows[e.ri][ci]
    if not (col and cell) then
        return
    end
    -- A pending BOX exists precisely so a pending nil (NULL) / false is distinguishable — an `and/or` would
    -- collapse it and re-seed the ORIGINAL value, silently undoing a NULL on re-open.
    local box = e.pending[ci]
    local raw
    if box then
        raw = box.value
    else
        raw = e.row[ci]
    end

    -- Mongo's synthetic `_document` cell is the WHOLE document (relaxed extended JSON). It is not a per-field
    -- edit — it opens as pretty JSON in the panel editor and saves as a document REPLACE (by `_id`), a path
    -- of its own that never touches the per-column pending set.
    if state.driver == "mongodb" and col.name == "_document" then
        local o = state.origin
        if not (o and o.object) then
            vim.notify("lvim-db: this result has no addressable collection", vim.log.levels.WARN)
            return
        end
        local pretty = pretty_json((vim.json.encode(raw)))
        require("lvim-ui").input({
            title = "_document (JSON)",
            -- A TALL bottom dock, not an anchor over the grid: the grid window is only as tall as its
            -- current rows, so anchoring to it made a stubby editor. Docked to the bottom edge at a fixed
            -- FRACTION OF THE SCREEN, the JSON editor is full-height whatever the grid holds.
            position = "bottom",
            width = 1.0,
            height = math.max(10, math.floor(vim.o.lines * 0.7)),
            -- Above the docked splits' own decoration layer, so nothing (a drawer/result active-row band)
            -- shows over the editor.
            zindex = 250,
            -- Edit the document as JSON CODE: treesitter highlighting + a json LSP (validation/format) if one
            -- attaches on the `json` filetype.
            filetype = "json",
            default = pretty,
            callback = function(ok, value)
                if not ok or not state.edit then
                    return
                end
                local ok_json, doc = pcall(vim.json.decode, value)
                if not ok_json or type(doc) ~= "table" then
                    vim.notify("lvim-db: not valid JSON — the document was not saved", vim.log.levels.WARN)
                    return
                end
                local stmt, jwhy = require("lvim-db.query").replace_document(state.driver, o.object, doc)
                if not stmt then
                    vim.notify("lvim-db: " .. tostring(jwhy), vim.log.levels.WARN)
                    return
                end
                cancel_edit()
                M.write(stmt)
            end,
        })
        return
    end

    -- Guard the field BEFORE opening: a binary / non-mongo-structured cell has no faithful text edit, so say
    -- so and do nothing rather than open a field whose save could only be refused or corrupt the value.
    local ok_edit, why = field_editable(raw, state.driver, col.type, col.name)
    if not ok_edit then
        vim.notify("lvim-db: " .. tostring(why), vim.log.levels.WARN)
        return
    end

    --- The one write path all three surfaces funnel into: coerce the typed text, stash it pending, and
    --- repaint the cell (cut to the column width so the row stays aligned). Identical whichever editor
    --- produced `value` — only the editor's geometry differs between the modes.
    ---@param ok boolean
    ---@param value any
    local function apply(ok, value)
        if not ok or not state.edit then
            return
        end
        local coerced, cerr = coerce(value, e.row[ci], state.driver, col.type, col.name)
        if cerr then
            vim.notify("lvim-db: " .. cerr, vim.log.levels.WARN)
            return
        end
        e.pending[ci] = { value = coerced }
        local text = cut_cells(flatten((cell_display(e.pending[ci].value))), col.width)
        vim.bo[state.buf].modifiable = true
        api.nvim_buf_set_text(
            state.buf,
            e.ri - 1,
            cell.bstart,
            e.ri - 1,
            cell.bstart + cell.blen,
            { pad_cells(text, col.width) }
        )
        vim.bo[state.buf].modifiable = false
        -- the byte length of this cell just changed; re-derive the row's geometry so the marks and the
        -- next edit land on the right bytes
        local bpos = 1
        for i = 1, #g.cols do
            g.rows[e.ri][i].bstart = bpos
            if i == ci then
                g.rows[e.ri][i].blen = #pad_cells(text, col.width)
                g.rows[e.ri][i].text = text
            end
            bpos = bpos + g.rows[e.ri][i].blen + #SEP
        end
        paint_edit()
    end

    local disp = (cell_display(raw))
    local win_w = api.nvim_win_get_width(state.win)
    -- A document/json cell (a NESTED table, or a json/jsonb column) always earns the panel — its text is
    -- formatted and a one-line field cannot show it. But a TAGGED SCALAR is also a table (`{__oid}` for an
    -- ObjectId, `{__int}` a big int, `{__ext}` a date/decimal, `{__bytes}`) and renders as a SHORT string —
    -- it is not a document and must be placed by width like any scalar, so an `_id` edits on its cell, not in
    -- the panel. A plain string is placed purely by how wide it is.
    local tagged_scalar = type(raw) == "table"
        and (raw.__oid ~= nil or raw.__int ~= nil or raw.__ext ~= nil or raw.__bytes ~= nil)
    local is_doc = (type(raw) == "table" and not tagged_scalar)
        or (type(col.type) == "string" and col.type:upper():find("JSON") ~= nil)
        or disp:find("\n") ~= nil
    local mode = edit_mode(disp, is_doc, col.width, win_w - 2)

    if mode == "panel" then
        -- A TALL bottom-docked editor for a long or formatted value (code, JSON, paragraphs). Docked at a
        -- fraction of the SCREEN rather than anchored over the grid window (which is only as tall as its
        -- current rows), so it is full-height regardless. A JSON value (a document, or a `{`/`[`-leading
        -- string) opens PRETTY-PRINTED so it reads as code; the engine re-parses the whitespace on save.
        local seed, ft = disp, nil
        if type(raw) == "table" or disp:match("^%s*[%[{]") then
            local okp, pj = pcall(pretty_json, disp)
            if okp then
                seed, ft = pj, "json" -- edit as JSON code (treesitter + a json LSP if one attaches)
            end
        end
        require("lvim-ui").input({
            title = col.name,
            position = "bottom",
            width = 1.0,
            height = math.max(10, math.floor(vim.o.lines * 0.7)),
            zindex = 250,
            filetype = ft,
            default = seed,
            callback = apply,
        })
    elseif mode == "row" then
        -- The full row width: the value overflows its cell but is a single line that fits the grid — a bare
        -- field spanning the row, so the whole value is visible while typing. Anchored at the grid's current
        -- LEFTCOL (the leftmost VISIBLE column), not text column 0: when the grid is scrolled right, column 0
        -- is off-screen and a col-0 anchor would land the field off the left edge. Leftcol pins it to the
        -- window's left edge whatever the scroll.
        local leftcol = api.nvim_win_call(state.win, function()
            return vim.fn.winsaveview().leftcol
        end)
        require("lvim-ui").input({
            bare = true,
            at = { win = state.win, row = e.ri - 1, col = leftcol },
            width = win_w - 2,
            default = disp,
            callback = apply,
        })
    else
        -- On the cell: the field sits EXACTLY on the column, aligned with the value it edits.
        require("lvim-ui").input({
            bare = true,
            at = { win = state.win, row = e.ri - 1, col = col.start },
            width = col.width,
            default = disp,
            callback = apply,
        })
    end
end

--- `save_edit`: write every changed field as ONE statement.
local function save_edit()
    local e = state.edit
    local g = state.grid
    local o = state.origin
    -- `readonly_reason` already cleared these when the row was locked; re-established here so the statement
    -- builder is handed real values, not maybes.
    if not (e and g and o and o.object and state.driver and is_open()) then
        return
    end
    local set = {}
    for ci in ipairs(g.cols) do
        if e.pending[ci] then
            set[#set + 1] = { name = g.cols[ci].name, value = e.pending[ci].value }
        end
    end
    if #set == 0 then
        vim.notify("lvim-db: nothing changed", vim.log.levels.INFO)
        cancel_edit()
        return
    end
    local stmt, why = require("lvim-db.query").update_row(state.driver, o.schema, o.object, set, e.where)
    if not stmt then
        vim.notify("lvim-db: " .. tostring(why), vim.log.levels.WARN)
        return
    end
    cancel_edit()
    M.write(stmt)
end

-- ── editing a row in a POPUP (every column at once) ──────────────────────────

--- The whole focused row as a typed form — one row per column, seeded with the FULL values.
---
--- Opens even when the row CANNOT be written (`readonly`): a row is worth SEEING whole whether or not you
--- may change it — the grid truncates at `MAX_CELL` and flattens a document to one line, so this is the only
--- place some values are legible at all. A read-only row simply gets no save button and says why in its
--- title, instead of the key refusing to show you your own data.
---@param ri integer      the result row
---@param row any[]       its RAW values
---@param key string[]?   its key columns — nil when the row cannot be addressed
---@param readonly string?  why it cannot be written, or nil when it can
local function open_row_popup(ri, row, key, readonly)
    local g = state.grid
    local o = state.origin
    if not (g and row) then
        return
    end
    local index, keyed = {}, {}
    for ci, c in ipairs(g.cols) do
        index[c.name] = ci
    end
    local where = {}
    for _, name in ipairs(key or {}) do
        local ci = index[name]
        if not ci then
            vim.notify(
                ("lvim-db: key column '%s' is not in this result — cannot address the row"):format(name),
                vim.log.levels.WARN
            )
            return
        end
        keyed[name] = true
        where[#where + 1] = { name = name, value = row[ci] }
    end
    do
        -- One typed row per column, holding the value as TEXT. `cell_display` (not tostring) so a NULL shows
        -- as the same `NULL` sentinel the grid uses and round-trips through `coerce` unchanged.
        local rows, orig = {}, {}
        -- Every label is PADDED to one width, so the coloured key boxes form a single uniform column (the
        -- tint reaches the same right edge on every row) and the values line up beside them — a keymap
        -- cheatsheet, not ragged tags. Width is measured in display cells (a Cyrillic column name counts).
        local key_w = 0
        for _, col in ipairs(g.cols) do
            local name = col.name .. (keyed[col.name] and "  (key)" or "")
            key_w = math.max(key_w, strwidth(name))
        end
        for ci, col in ipairs(g.cols) do
            local raw = row[ci]
            local text = (cell_display(raw))
            orig[ci] = text
            local name = col.name .. (keyed[col.name] and "  (key)" or "")
            -- A field is JSON/document when its value is a NESTED table (not a tagged scalar like an
            -- ObjectId/date) or a json column — same rule as the grid cell editor. Those get the SPECIAL
            -- float (tall, bottom-docked, treesitter-highlighted, pretty-printed); everything else gets a
            -- WIDER single-line input than the default.
            local tagged = type(raw) == "table"
                and (raw.__oid ~= nil or raw.__int ~= nil or raw.__ext ~= nil or raw.__bytes ~= nil)
            local is_json = (type(raw) == "table" and not tagged)
                or (type(col.type) == "string" and col.type:upper():find("JSON") ~= nil)
                or (col.name == "_document")
            local edit
            if is_json then
                local okp, pj = pcall(pretty_json, text)
                edit = {
                    position = "bottom",
                    width = 1.0,
                    height = math.max(10, math.floor(vim.o.lines * 0.7)),
                    zindex = 250,
                    filetype = "json",
                    default = okp and pj or text,
                }
            else
                -- FULL width, matching the row popup it opens over — both cover the drawer, so its icons
                -- never peek beside them, and the whole width makes a long value easy to read/edit.
                edit = { width = 1.0, width_fixed = true }
            end
            rows[#rows + 1] = {
                type = "string",
                name = "c" .. ci,
                -- A per-VALUE type icon (flat: it REPLACES the generic string glyph), so the key column shows
                -- what kind each field is — an ObjectId, a date, a number, a document, … The icon wears its
                -- own YELLOW box that runs from the row start, cushioned by a space on each side.
                flat = true,
                icon = " " .. value_icon(raw) .. " ",
                icon_hl = "LvimDbRowIcon",
                -- the key columns are marked (a `(key)` suffix): they are what addresses the row, and the
                -- WHERE uses the value they had on open regardless of what is typed here.
                -- The name is a RED key box, padded to ONE width and cushioned by a space on each side (air
                -- inside the tint); every box is the same width AND the same tint, so they form one column.
                label = " " .. pad_cells(name, key_w) .. " ",
                value = text,
                edit = edit,
                text_hl = "LvimDbRowKey",
            }
        end

        local fk = config.keys.result
        require("lvim-ui").tabs({
            -- The title carries the READ-ONLY reason: the popup is open precisely so the row can be read, so
            -- "why can't I save this" has to be answerable without closing it and pressing something else.
            title = readonly and ("Row — %s  (read-only: %s)"):format(o and o.object or "", readonly)
                or ("Edit row — %s"):format(o and o.object or ""),
            title_pos = "center",
            layout = "float",
            -- Above the docked grid/drawer splits' decoration layer, so their active-row band never draws
            -- over this popup.
            zindex = 250,
            -- FULL editor width. A centred canonical float (0.9) leaves the left DRAWER split's columns
            -- visible beside it, and its bright devicons read as covering the popup's left edge. Full width
            -- reaches column 0, so the drawer is covered rather than peeking. (The BACKDROP is still the
            -- canonical float veil from the central geometry — only the width is overridden here.)
            width = 1.0,
            -- No body lead pad: the field rows are icon/name BOXES that carry their own padding, so the tint
            -- starts right after the frame border instead of two indent spaces in.
            pad = 0,
            tabs = {
                {
                    label = "Row",
                    rows = rows,
                    footer = {
                        not readonly
                                and fk.save_edit
                                and {
                                    key = fk.save_edit,
                                    label = "save",
                                    run = function(st)
                                        -- `readonly` being nil already established these (that is what the check
                                        -- MEANS); re-stated so the statement builder is handed real values.
                                        if not (o and o.object and state.driver) then
                                            return
                                        end
                                        local set = {}
                                        for ci in ipairs(g.cols) do
                                            local now = rows[ci].value
                                            if now ~= orig[ci] then
                                                -- Coerce per field; a field with no faithful text round-trip (binary,
                                                -- non-mongo structured) or invalid JSON aborts the WHOLE save — never
                                                -- send a partial/corrupt update.
                                                local val, cerr =
                                                    coerce(now, row[ci], state.driver, g.cols[ci].type, g.cols[ci].name)
                                                if cerr then
                                                    vim.notify(
                                                        ("lvim-db: '%s' — %s"):format(g.cols[ci].name, cerr),
                                                        vim.log.levels.WARN
                                                    )
                                                    return
                                                end
                                                set[#set + 1] = { name = g.cols[ci].name, value = val }
                                            end
                                        end
                                        if #set == 0 then
                                            vim.notify("lvim-db: nothing changed", vim.log.levels.INFO)
                                            st.close()
                                            return
                                        end
                                        local stmt, err = require("lvim-db.query").update_row(
                                            state.driver,
                                            o.schema,
                                            o.object,
                                            set,
                                            where
                                        )
                                        if not stmt then
                                            vim.notify("lvim-db: " .. tostring(err), vim.log.levels.WARN)
                                            return
                                        end
                                        st.close()
                                        M.write(stmt)
                                    end,
                                }
                            or nil,
                        fk.close and { key = fk.close, label = "close", no_hotkey = true } or nil,
                    },
                },
            },
        })
    end
end

--- `edit_popup`: the focused row, every field at once.
local function edit_popup()
    if state.view ~= "result" or state.edit then
        return
    end
    local g = state.grid
    local ri = api.nvim_win_get_cursor(0)[1]
    local row = state.page and state.page.rows and state.page.rows[ri]
    if not (row and g and g.rows[ri]) then
        return
    end
    local why = readonly_reason()
    if why then
        return open_row_popup(ri, row, nil, why) -- readable, just not writable
    end
    resolve_key(function(key)
        open_row_popup(ri, row, key, key and nil or (readonly_reason() or "no key"))
    end)
end

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. Built from the LIVE `config.keys.result`, so a rebind shows up
-- and a key the user set to `false` drops its row.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "result_tab", "show the RESULT view (header tab)" },
    { "log_tab", "show the CALL LOG view (header tab)" },
    { "view_result", "switch to the result view" },
    { "view_log", "switch to the call-log view" },
    { "rerun", "call log: re-run the focused call" },
    { "cancel", "call log: cancel the running call" },
    { "next_page", "result: next page" },
    { "prev_page", "result: previous page" },
    { "next_column", "result: jump to the next column" },
    { "prev_column", "result: jump to the previous column" },
    { "edit_row", "result: lock the focused row for editing" },
    { "edit_popup", "result: edit the focused row in a popup (every field)" },
    { "edit_cell", "editing: open the field under the cursor" },
    { "insert_cell", "result: start editing the field under the cursor" },
    { "save_edit", "editing: write every changed field back (one UPDATE)" },
    { "cancel_edit", "editing: discard the edit" },
    { "yank", "result: yank the page as TSV" },
    { "export", "result: export the page to a file" },
    { "help", "this help" },
    { "close", "close the dock" },
}

--- The result dock's keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping,
--- the colours and the window; this only supplies the plugin's LIVE keys.
local function show_help()
    local k = config.keys.result
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = k[e[1]]
        if type(lhs) == "table" then
            lhs = table.concat(lhs, " / ") -- a key bound to several lhs (i / a) shows all of them
        end
        if lhs then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    require("lvim-ui").help({
        title = "Result keymaps",
        items = items,
        close_keys = { "q", "<Esc>", k.help or "g?" },
    })
end

-- ── the footer bands (browsing ⇄ editing) ────────────────────────────────────
--
-- The dock has TWO footers and swaps between them, because it has two modes. That swap is also what binds
-- and unbinds `S`/`c`: `set_footer` re-derives the bar hotkeys (lvim-ui `map_hotkeys`), so the save/cancel
-- keys exist exactly while a row is locked and the browse keys come back the moment it is not — no keymap of
-- our own to leak, and the bar can never advertise a key that is not live.

-- (declared above `set_view`, which rebuilds the header on a view switch)
-- The two header tabs, with the CURRENT view's tab marked `active` — the badge and the label each DEEPEN to
-- their own selected tint (blue / yellow), so the active tab reads as the stronger block and shows which view
-- is open regardless of focus, instead of only lighting up while the header bar is the focused sector. The
-- `active` render, unlike hover, does not bracket the label, so nothing eats the side padding.
function header_spec()
    local k = config.keys.result
    -- ACTIVE = the SELECTED tint of the shared footer canon: each box KEEPS ITS OWN HUE — blue key badge,
    -- yellow label — and merely DEEPENS, exactly like every other button's hover/selected pair. This used to
    -- point BOTH boxes at one blue group, which turned the active tab's LABEL blue instead of a stronger
    -- yellow (the badge and the caption then read as the same colour).
    local ACTIVE = {
        icon = { active = "LvimUiFooterKeyHover" },
        text = { active = "LvimUiFooterLabelHover" },
    }
    return {
        bars = {
            -- The TITLE row: `db ➤ object` on the LEFT, the range counter (1–20/536) pushed to the RIGHT — a
            -- `title_counter` band (title_pos "left", `count` a live function re-read on every chrome render).
            -- This replaces the old centred brand: the title now says WHICH object the rows are, and the
            -- counter says WHICH of the total is on screen.
            {
                title_counter = true,
                text = title_left(),
                count = range_text,
                -- No `hl`/`text_hl`: the band takes the canon — a blue strip that deepens while the dock has
                -- focus, with the title fg-only ON it — and the counter keeps its green badge.
                count_hl = "LvimUiPeekCounter",
                title_pos = "left",
            },
            surface.bar({ { "result_tab", "log_tab" } }, {
                result_tab = {
                    name = "result",
                    key = k.result_tab or nil,
                    active = state.view == "result",
                    hl = state.view == "result" and ACTIVE or nil,
                    run = function()
                        set_view("result")
                    end,
                },
                log_tab = {
                    name = "call log",
                    key = k.log_tab or nil,
                    active = state.view == "log",
                    hl = state.view == "log" and ACTIVE or nil,
                    run = function()
                        set_view("log")
                    end,
                },
            }),
        },
    }
end

--- The BROWSE footer: paging, the row editors, yank/export, help, close.
---@return table
local function browse_footer()
    local k = config.keys.result
    return {
        bars = {
            surface.bar({ { "prev", "next" }, { "edit", "edit_popup" }, { "yank", "export" }, { "help", "close" } }, {
                prev = {
                    name = "prev",
                    key = k.prev_page or nil,
                    run = function()
                        goto_page(math.max(0, state.offset - config.page_size))
                    end,
                },
                next = {
                    name = "next",
                    key = k.next_page or nil,
                    run = function()
                        if state.page and state.page.has_more then
                            goto_page(state.offset + config.page_size)
                        end
                    end,
                },
                -- Wrapped, never `run = edit_row` directly: the bar invokes `run(surface_state)`, and
                -- `edit_row`'s first param is now `after` (a continuation) — the state table would be called
                -- as one. `edit_popup` ignores extra args, but wrap it too for symmetry.
                edit = {
                    name = "edit",
                    key = k.edit_row or nil,
                    run = function()
                        edit_row()
                    end,
                },
                edit_popup = {
                    name = "edit row",
                    key = k.edit_popup or nil,
                    run = function()
                        edit_popup()
                    end,
                },
                yank = { name = "yank", key = k.yank or nil, run = yank_page },
                export = { name = "export", key = k.export or nil, run = export_page },
                -- The dock's keys are not discoverable from the grid, so the bar has to say where the
                -- cheatsheet is (the key itself is bound in `set_keys`, through the chassis).
                help = { name = "help", key = k.help or nil, run = show_help },
                close = {
                    name = "close",
                    key = k.close or nil,
                    run = function(s)
                        s.close()
                    end,
                },
            }),
        },
    }
end

--- The EDIT-MODE footer — the two keys that end the edit, and nothing else.
---@return table
local function edit_footer()
    local k = config.keys.result
    return {
        bars = {
            surface.bar({ { "save", "cancel" } }, {
                save = { name = "save", key = k.save_edit or nil, run = save_edit },
                cancel = { name = "cancel", key = k.cancel_edit or nil, run = cancel_edit },
            }),
        },
    }
end

-- (declared above `cancel_edit`, which swaps the footer back)
function refresh_footer()
    if state.surface and state.surface.set_footer then
        pcall(state.surface.set_footer, state.edit and edit_footer() or browse_footer())
    end
end

--- Open (or refresh) the dock with the current result.
local function open_dock()
    if is_open() then
        render()
        if state.surface and state.surface.set_header then
            pcall(state.surface.set_header, header_spec())
        end
        return
    end
    -- Buffer-local keys (all from config.keys.result): switch views, and in the
    -- call-log view re-open a call (re-runs its statement) or cancel a running one.
    -- A key set to `false` is left unbound.
    local k = config.keys.result
    -- Bind THROUGH the chassis `map` (the provider's `keys` hook), never with a raw `vim.keymap.set`: only
    -- the keys the chassis binds itself land in its `used` set, and that set is what makes the panel OWN a
    -- chord PREFIX (the `g` of `g?`) — otherwise a `g?` typed at human speed falls through to the builtin
    -- `g` once `timeoutlen` expires.
    ---@param chassis_map fun(lhs: string|string[], fn: fun())
    local function set_keys(chassis_map)
        local function map(lhs, fn)
            if not lhs then
                return
            end
            chassis_map(lhs, fn)
        end
        map(k.help, show_help)
        map(k.view_result, function()
            set_view("result")
        end)
        map(k.view_log, function()
            set_view("log")
        end)
        -- `<CR>` is the "act on what is under the cursor" key, and what that means depends on what the dock is
        -- showing: a call in the log → re-run it; a field of a LOCKED row → open it. Sharing the key keeps
        -- both as the same gesture instead of inventing a second one for the grid.
        map(k.rerun, function()
            if state.view == "result" then
                if state.edit then
                    edit_cell()
                end
                return
            end
            local c = state.log_rows[api.nvim_win_get_cursor(0)[1]]
            if c and c.conn_id then
                M.run(c.conn_id, c.conn, c.driver, c.statement)
            end
        end)
        map(k.cancel, function()
            if state.view ~= "log" then
                return
            end
            local c = state.log_rows[api.nvim_win_get_cursor(0)[1]]
            if c and c.state == "running" and c.call_id then
                require("lvim-db").cancel(c.call_id)
            end
        end)
        map(k.next_column, next_column)
        map(k.prev_column, prev_column)
        map(k.edit_row, function()
            edit_row()
        end)
        map(k.edit_popup, edit_popup)
        -- "start typing here", the way i/a mean it everywhere else: open the field under the cursor, taking
        -- the row lock first if it is not held. Bound rather than left alone BECAUSE the grid is read-only —
        -- an unbound `i` falls through to the builtin insert and raises E21 on every press.
        map(k.insert_cell, function()
            if state.edit then
                edit_cell()
            else
                edit_row(edit_cell)
            end
        end)
    end

    local provider = {
        -- A visible cursor line (a blue wash) — the neutral default `LvimUiCursorLine` is the faintest tint
        -- in the set and vanishes against the grid, so name a distinct group.
        cursorline = "LvimDbCursorLine",
        filetype = "lvim-db-result",
        -- The grid is a cursor-VISIBLE panel the user scrolls but never types into (edits go through the
        -- popups). `readonly` tells the chassis to nop the builtin EDIT operators (o / dd / p / s / …) while
        -- keeping the motions — else, on the nomodifiable buffer, every unbound edit key raises
        -- `E21: Cannot make changes` (a bare `s` did, expecting to save).
        readonly = true,
        update = function(pan)
            state.buf, state.win = pan.buf, pan.win
            vim.bo[pan.buf].buftype = "nofile"
            render()
        end,
        keys = function(map)
            set_keys(map)
        end,
        on_close = function()
            state.surface, state.buf, state.win, state.edit, state.grid = nil, nil, nil, nil, nil
        end,
    }
    -- Dock FULL WIDTH at the bottom of the tab (the chassis splits the far tabpage edge → the result spans
    -- under BOTH the tree and the editor). This wraps the existing top row `[tree | editor]` into
    -- `[ [tree | editor] / result ]`, so the tree shrinks to the top-left and its footer stays visible ABOVE
    -- the result. The docked split keeps the full chrome (header tabs · grid · footer) and its own `<C-j/k>`
    -- sector nav, whose TOP-edge `<C-k>` steps back up to the tree or editor above the cursor column
    -- (escape_to_neighbor). A `<C-j>` from either top window descends onto the result (the chassis WinEnter
    -- hook enters the docked panel).
    state.surface = surface.open({
        mode = "split",
        dock = "below",
        -- No `title` on the surface: the title lives in the header's FIRST band (a `title_counter` row —
        -- `db ➤ object` left, the 1–20/536 counter right — see `header_spec`), so a separate centred brand
        -- would only duplicate it.
        size = { height = { fixed = math.max(8, math.floor(vim.o.lines * 0.35)) } },
        -- NO panel border on the result grid — `border = "none"` (not CONTENT_BORDER, the shared blank " "
        -- ring every other content panel uses). The ring's 1-cell side inset is what stopped the STICKY HEADER
        -- (the winbar) from reaching the window edge: its blue filled the text area but not the gutter, so the
        -- header read as "not edge to edge". With no ring the winbar spans the full width, blue edge-to-edge,
        -- and it keeps its OWN 1-cell padding inside (its leading/trailing blue space) so the labels don't butt
        -- the edge. The ROWS keep their inset too — they already pad themselves (`" " .. cells .. " "`), so
        -- dropping the ring moves only the header out to the edge, not the row text. (`"none"` is explicit: a
        -- block with NO border key falls back to a drawn rounded ring.)
        content = { blocks = { { id = "result", provider = provider, border = "none" } } },
        header = header_spec(),
        footer = browse_footer(),
        close_keys = k.close and { k.close } or {},
        -- Vertical layer nav, past the dock's own edges: `<C-j>` off the BOTTOM sector descends into the
        -- message zone below (lvim-msgarea), `<C-k>` off the TOP sector is already handled by the chassis
        -- (escape_to_neighbor → the editor/tree above). The dock is the bottom LAYER of the workspace, and the
        -- msgarea is the layer under it, so this closes the down half of the "layer after layer" chain the
        -- user expects. Guarded + optional: no lvim-msgarea (or nothing to descend into) ⇒ `focus_content`
        -- returns false and the chassis just stops at the edge, exactly as before. Cross-plugin optional dep,
        -- so the require is inline (never hoisted).
        on_escape_below = function()
            local ok, msg = pcall(require, "lvim-msgarea")
            return ok and msg.focus_content and msg.focus_content() == true
        end,
    })

    -- Track which column the cursor is in, so the sticky header can tint it. A cursor move within a line does
    -- not re-run the winbar on its own; `track_column` forces it only when the column actually CHANGES, so
    -- moving down a column costs nothing.
    api.nvim_create_autocmd("CursorMoved", {
        buffer = state.buf,
        callback = function()
            track_column()
            paint_cursor_row()
        end,
    })
end

--- Re-open the dock over a preserved session (used when the workspace tab is re-opened): if a result page
--- or any call log survives in the module state, rebuild the dock and re-render it so the last result — or
--- at least the call log — comes back exactly as it was. A no-op when nothing has run yet, so the dock only
--- appears once there is something to show.
function M.reopen()
    if state.page == nil and #state.calls == 0 then
        return
    end
    open_dock()
    render()
end

--- Execute `statement` on `conn_id` and show its first page in the dock. Records
--- the call in both the session call log and the persisted history. Does NOT
--- apply the destructive guard — use `M.run_guarded` for that.
---@param conn_id integer
---@param conn_name string
---@param driver string
---@param statement string
---@param origin? table  `{ schema, object }` when these rows ARE one object's — the drawer's `Data` facet
---       passes it; an ad-hoc statement passes nothing and its result stays read-only.
---@param offset? integer  which page to land on (default 0). The refresh after a row is written passes the
---       page the user was ON, so saving an edit does not throw them back to the top of a long table.
function M.run(conn_id, conn_name, driver, statement, origin, offset)
    local db = require("lvim-db")
    -- A LOCKED row belongs to the result being replaced. Its `where` was captured from THAT object's key, so
    -- carrying it into a new result would let `S` build an UPDATE addressing the old table with the new
    -- grid's columns — a write to something the user is no longer even looking at. The lock dies with the
    -- result it locked. (Measured: without this, running another object's preview left the edit footer up and
    -- `e` inert, because the stale lock was still held.)
    cancel_edit()
    state.conn, state.driver, state.conn_id, state.call_id, state.page, state.offset =
        conn_name, driver, conn_id, nil, nil, 0
    state.statement = statement
    -- Rebound on EVERY run: a result is only editable while it is showing the object it came from, so a
    -- later ad-hoc query must clear this rather than inherit the last preview's identity.
    state.origin = origin and { schema = origin.schema, object = origin.object } or nil
    -- Count the object's total in the background so the header reads `1–N / <total>` right away (see
    -- `fetch_total`). Only for an object browse — an ad-hoc query has nothing to count.
    if state.origin then
        fetch_total(state.origin)
    end

    -- A pending entry in the session call log (accent = running until it resolves).
    local entry = {
        call_id = nil,
        conn_id = conn_id,
        conn = conn_name,
        driver = driver,
        statement = statement,
        state = "running",
        ms = nil,
        rows = nil,
    }
    state.calls[#state.calls + 1] = entry
    if #state.calls > 200 then
        table.remove(state.calls, 1)
    end
    local function relog()
        if is_open() and state.view == "log" then
            vim.schedule(render)
        end
    end
    relog()

    db.execute(conn_id, statement, function(st)
        entry.state = st.state
        entry.ms = st.ms
        entry.rows = st.affected
        db.store.record({
            conn = conn_name,
            driver = driver,
            statement = statement,
            state = st.state,
            ms = st.ms,
            rows = st.affected,
        })
        relog()
        if st.state ~= "done" then
            vim.schedule(function()
                vim.notify(
                    ("lvim-db: query %s%s"):format(st.state, st.error and (": " .. st.error) or ""),
                    st.state == "failed" and vim.log.levels.ERROR or vim.log.levels.WARN
                )
            end)
            return
        end
        vim.schedule(function()
            state.view = "result"
            open_dock()
            goto_page(offset or 0)
        end)
    end, function(call_id, err)
        if err then
            vim.schedule(function()
                vim.notify("lvim-db: execute failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
            return
        end
        -- Release the PREVIOUS result's server-side buffer — only the current call_id is ever paged again, and
        -- the call log reruns by statement, so a replaced call's buffered rows are dead weight on the daemon.
        local prev = state.call_id
        entry.call_id = call_id
        state.call_id = call_id
        if prev and prev ~= call_id then
            require("lvim-db").release(prev)
        end
    end)
end

--- Execute a WRITE the grid built (the row editors' single `UPDATE`), then re-read the page so the grid
--- shows what the engine actually holds.
---
--- It does NOT re-render from what we sent: a trigger, a default, or the engine's own type coercion can all
--- make the stored row differ from the literal in the statement, and painting our version over it would make
--- the grid quietly lie about the database. The re-read costs one round trip and is the only way the rows on
--- screen are the rows in the table.
---
--- The destructive guard is not applied here and does not need to be: the statement is generated, always
--- carries a key WHERE, and touches exactly one row (`is_destructive` exists for free-text statements — see
--- `M.run_guarded`).
---@param statement string
function M.write(statement)
    local db = require("lvim-db")
    local conn_id, conn_name, driver = state.conn_id, state.conn, state.driver
    if not (conn_id and conn_name and driver) then
        return
    end
    local entry = {
        conn_id = conn_id,
        conn = conn_name,
        driver = driver,
        statement = statement,
        state = "running",
    }
    state.calls[#state.calls + 1] = entry
    if #state.calls > 200 then
        table.remove(state.calls, 1)
    end
    db.execute(conn_id, statement, function(st)
        entry.state, entry.ms, entry.rows = st.state, st.ms, st.affected
        db.store.record({
            conn = conn_name,
            driver = driver,
            statement = statement,
            state = st.state,
            ms = st.ms,
            rows = st.affected,
        })
        vim.schedule(function()
            if st.state ~= "done" then
                vim.notify(
                    ("lvim-db: write %s%s"):format(st.state, st.error and (": " .. st.error) or ""),
                    vim.log.levels.ERROR
                )
                return
            end
            vim.notify(("lvim-db: %d row(s) updated"):format(st.affected or 0), vim.log.levels.INFO)
            -- back to the page the user was on, showing the engine's version of the row
            if state.statement then
                local o = state.origin
                M.run(
                    conn_id,
                    conn_name,
                    driver,
                    state.statement,
                    o and { schema = o.schema, object = o.object } or nil,
                    state.offset
                )
            end
        end)
    end, function(_, err)
        if err then
            vim.schedule(function()
                vim.notify("lvim-db: write failed: " .. tostring(err), vim.log.levels.ERROR)
            end)
        end
    end)
end

--- Execute `statement`, first applying the destructive-statement guard: a DROP /
--- TRUNCATE / unqualified DELETE|UPDATE prompts a confirm (config
--- `confirm_destructive`) before it runs. This is THE entry point for free-text
--- statements (the SQL editor, ad-hoc runs); the drawer preview (a SELECT) may use it too.
---@param conn_id integer
---@param conn_name string
---@param driver string
---@param statement string
function M.run_guarded(conn_id, conn_name, driver, statement, origin)
    local db = require("lvim-db")
    if db.is_destructive(statement) then
        require("lvim-ui").confirm({
            title = "Destructive statement",
            message = "This looks destructive (DROP / TRUNCATE / DELETE|UPDATE without WHERE):\n\n"
                .. statement:sub(1, 200)
                .. "\n\nRun it anyway?",
            callback = function(yes)
                if yes then
                    M.run(conn_id, conn_name, driver, statement, origin)
                end
            end,
        })
    else
        M.run(conn_id, conn_name, driver, statement, origin)
    end
end

--- Open the call-log tab (creating the dock if needed).
function M.show_log()
    open_dock()
    set_view("log")
end

--- Close the dock.
function M.close()
    local s = state.surface
    if s then
        state.surface = nil
        pcall(function()
            s.close()
        end)
    end
end

return M
