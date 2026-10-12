-- lvim-db.ui.ddl: the schema changes a dialect declares, as a form.
--
-- Nothing in this file knows what a schema change IS. The engine declares each
-- one (`DriverMeta.ddl_ops`): a stable word (`add_column`), a label a person
-- reads, the statement as a TEMPLATE, what the template needs filled in
-- (`asks`), and what the operation is done TO (`scope`). This module shows the
-- list for a row's scope, collects what the asks want, and writes the statement
-- out with `proto.render_ddl`.
--
-- Which is why there are no dialect names here and no `if driver == …`. The
-- client used to hold five generators and decide by name that `rename_column`
-- is standard SQL unless it is SQL Server, in which case it is `sp_rename` with
-- a quoted triple — and that list was wrong for every engine added after it was
-- written.
--
-- GENERATED, NEVER RUN. The statement goes into the SQL editor, where it is read
-- and changed before anybody runs it: a schema change that happens because
-- somebody picked a menu item is a schema change nobody reviewed. The
-- destructive guard then applies on the way out, like any other statement.
--
---@module "lvim-db.ui.ddl"

local proto = require("lvim-db.proto")

local M = {}

--- A type as it is offered: `text`, `varchar(n)`, `numeric(p, s)` — the arity the
--- driver declared, so what lands in the box is something to finish rather than
--- something to remember.
---@param ty table
---@return string
local function type_label(ty)
    local args = tonumber(ty.args) or 0
    if args == 1 then
        return ("%s(n)"):format(ty.name)
    end
    if args >= 2 then
        return ("%s(p, s)"):format(ty.name)
    end
    return ty.name
end

--- What there is to PICK from for one ask, or nil when it is free text.
---
--- A list, never a closed choice: `numeric(12, 2)` is in nobody's list, and a
--- list that cannot be typed past is a list that is wrong for somebody. The pick
--- fills the box; the box stays editable.
---@param kind string
---@param ctx { types: table[], columns: string[], indexes: string[] }
---@return string[]?
local function picks(kind, ctx)
    if kind == "type" then
        local out = {}
        for _, ty in ipairs(ctx.types or {}) do
            out[#out + 1] = type_label(ty)
        end
        return #out > 0 and out or nil
    end
    if kind == "column" or kind == "columns" then
        return #(ctx.columns or {}) > 0 and ctx.columns or nil
    end
    if kind == "index" then
        return #(ctx.indexes or {}) > 0 and ctx.indexes or nil
    end
    return nil
end

--- The form rows for one declared operation, in the order the driver asked.
---
--- PURE: it takes the operation and what is around it and returns rows. That is
--- what makes the mapping testable — "a flag becomes a bool row, a type becomes a
--- box with a picker, a repeating group becomes a list" is the whole of this
--- module's judgement, and it is judgement about a DECLARATION rather than about
--- a dialect.
---
--- Each row carries `_ask` (the declaration it came from) so the writer can ask
--- the row what it fills instead of matching on its name.
---@param spec table                                     the `DdlOp`
---@param ctx table                                      { table, column, index, types, columns, indexes }
---@return table[] rows, table? group  the repeating group's ask, when the op has one
function M.rows_for(spec, ctx)
    local rows, group = {}, nil
    for _, ask in ipairs(spec.asks or {}) do
        local kind, carried = proto.ask_kind(ask)
        if kind == "flag" then
            -- The WORDS are the driver's (`on` / `off`), so the row is a plain
            -- on/off and the text it becomes is never derived from the key.
            rows[#rows + 1] = {
                type = "bool",
                name = ask.key,
                label = ask.label,
                value = false,
                _ask = ask,
                _on = carried and carried.on or "",
                _off = carried and carried.off or "",
            }
        elseif kind == "rows" then
            -- A repeating group: its own template, its own asks, one level down.
            -- The rows it collects live beside the form, because a column of a new
            -- table is not one value and cannot be one box.
            group = { key = ask.key, label = ask.label, row = carried and carried.row or nil }
        else
            local list = picks(kind, ctx)
            rows[#rows + 1] = {
                type = "string",
                name = ask.key,
                label = ask.label,
                value = proto.suggest(ask, ctx),
                suffix = list and ("(" .. #list .. " to pick from)") or nil,
                _ask = ask,
                _picks = list,
            }
        end
    end
    return rows, group
end

--- What the filled form says, keyed by the hole each row fills.
---
--- A flag contributes the DRIVER's word for on or off — never the key's name,
--- which was right once (`unique` → `UNIQUE`) and wrong for `NOT NULL`,
--- `PRIMARY KEY` and for a command document that wants `true`.
---@param rows table[]
---@return table<string, string>
function M.values_of(rows)
    local values = {}
    for _, r in ipairs(rows) do
        if r.name then
            if r.type == "bool" then
                values[r.name] = r.value and r._on or r._off
            else
                values[r.name] = tostring(r.value or "")
            end
        end
    end
    return values
end

--- Open the form for one declared operation, then put the statement in the editor.
---@param conn table   the drawer's connection row ({ name, driver })
---@param ctx table    { schema?, table?, column?, index?, types, columns, indexes }
---@param spec table   the `DdlOp`
function M.open(conn, ctx, spec)
    local ui = require("lvim-ui")
    local meta = proto.meta(conn.driver)
    local rows, group = M.rows_for(spec, ctx)
    ---@type table<string, string>[] the repeating group's finished rows
    local group_rows = {}

    -- One line per column somebody has added, written with the GROUP's own row
    -- template — so what the form shows is what the statement will say.
    local function group_lines()
        local out = {}
        for _, values in ipairs(group_rows) do
            local one = group and group.row and proto.render_ddl_row(group.row, values)
            if one then
                out[#out + 1] = { type = "spacer", flat = true, tight = true, label = "  " .. one }
            end
        end
        return out
    end

    local handle
    local function rebuild()
        local all = {}
        for _, r in ipairs(rows) do
            all[#all + 1] = r
        end
        if group then
            all[#all + 1] = {
                type = "spacer",
                flat = true,
                tight = true,
                label = ("%s (%d)"):format(group.label or "Rows", #group_rows),
            }
            vim.list_extend(all, group_lines())
            all[#all + 1] = {
                type = "action",
                name = "__add_group_row",
                label = "+ add",
                run = function()
                    M.ask_group_row(group.row, ctx, function(values)
                        group_rows[#group_rows + 1] = values
                        rebuild()
                    end)
                end,
            }
            if #group_rows > 0 then
                all[#all + 1] = {
                    type = "action",
                    name = "__clear_group",
                    label = "clear them",
                    run = function()
                        group_rows = {}
                        rebuild()
                    end,
                }
            end
        end
        -- A box with something to pick from gets its picker as the row BELOW it: a
        -- closed list would refuse `numeric(12, 2)`, and a box with no list leaves
        -- somebody guessing at what this dialect calls things.
        local withpicks = {}
        for _, r in ipairs(all) do
            withpicks[#withpicks + 1] = r
            if r._picks then
                local box = r
                withpicks[#withpicks + 1] = {
                    type = "action",
                    name = "__pick_" .. tostring(r.name),
                    label = ("pick %s…"):format(string.lower(r.label or r.name or "one")),
                    run = function()
                        local items = {}
                        for _, p in ipairs(box._picks) do
                            items[#items + 1] = { label = "  " .. p, text = p }
                        end
                        ui.select({
                            title = box.label or box.name,
                            items = items,
                            callback = function(confirmed, idx)
                                if not (confirmed and items[idx]) then
                                    return
                                end
                                local kind = proto.ask_kind(box._ask)
                                if kind == "columns" and vim.trim(tostring(box.value or "")) ~= "" then
                                    -- A list of columns grows rather than being replaced: picking the
                                    -- second one means "and this one too".
                                    box.value = box.value .. ", " .. items[idx].text
                                else
                                    box.value = items[idx].text
                                end
                                if handle and handle.render then
                                    handle.render()
                                end
                            end,
                        })
                    end,
                }
            end
        end
        if handle and handle.set_rows then
            handle.set_rows(withpicks)
            return
        end
        handle = ui.tabs({
            title = ("%s — %s"):format(spec.label or spec.op, ctx.table ~= "" and ctx.table or conn.name),
            title_pos = "center",
            layout = "float",
            tabs = {
                {
                    label = "Change",
                    rows = withpicks,
                    footer = {
                        {
                            key = "w",
                            label = "write it",
                            run = function(st)
                                local values = M.values_of(rows)
                                if group then
                                    values[group.key] = proto.render_ddl_rows(group.row, group_rows)
                                end
                                local stmt = proto.render_ddl(meta, spec.op, ctx.table or "", ctx.schema, values)
                                if not stmt or stmt == "" then
                                    vim.notify(
                                        ("lvim-db: %s has no '%s' statement"):format(conn.driver, spec.op),
                                        vim.log.levels.WARN
                                    )
                                    return
                                end
                                st.close()
                                -- To the EDITOR, never to the server.
                                require("lvim-db.ui.editor").load_text(conn.name, stmt)
                            end,
                        },
                        { key = "q", label = "close", no_hotkey = true },
                    },
                },
            },
        })
    end
    rebuild()
end

--- Ask for ONE row of a repeating group, one declared ask at a time.
---
--- A prompt chain rather than a nested form: a column of a new table is a name, a
--- type and some flags, and the dialect says which — so the questions are the
--- declaration's, asked in its order, and `cb` gets the values keyed by the holes
--- they fill.
---@param row table   the `DdlRow`
---@param ctx table
---@param cb fun(values: table<string, string>)
function M.ask_group_row(row, ctx, cb)
    local ui = require("lvim-ui")
    local values = {}
    local asks = row and row.asks or {}
    local function step(i)
        local ask = asks[i]
        if not ask then
            return cb(values)
        end
        local kind, carried = proto.ask_kind(ask)
        if kind == "flag" then
            ui.select({
                title = ask.label,
                items = { { label = "  no", on = false }, { label = "  yes", on = true } },
                callback = function(confirmed, idx)
                    if not confirmed then
                        return -- abandoning one question abandons the row, not the form
                    end
                    values[ask.key] = (idx == 2) and (carried and carried.on or "") or (carried and carried.off or "")
                    step(i + 1)
                end,
            })
            return
        end
        local list = picks(kind, ctx)
        ui.input({
            title = ask.label .. (list and (" (" .. list[1] .. ", " .. (list[2] or "…") .. ", …)") or ""),
            default = proto.suggest(ask, ctx),
            callback = function(ok, value)
                if not ok then
                    return
                end
                values[ask.key] = vim.trim(value or "")
                step(i + 1)
            end,
        })
    end
    step(1)
end

--- The declared operations for a row's SCOPE, as a menu, then the form.
---
--- The LABELS are the driver's ("New table…", "Drop this table", "Add a column…"),
--- because the operation list is the driver's. An empty list says this dialect has
--- nothing to change there, which is the honest answer for a key/value store and
--- is said rather than left as a menu that opens empty.
---@param conn table   { name, driver }
---@param ctx table    { schema?, table?, column?, index? }
---@param scope string "column" | "index" | "object" | "new"
function M.menu(conn, ctx, scope)
    local meta = proto.meta(conn.driver)
    local ops = proto.ops_for(meta, scope)
    if #ops == 0 then
        vim.notify(
            ("lvim-db: %s declares no schema changes here"):format(conn.driver),
            vim.log.levels.INFO
        )
        return
    end
    -- What there is to pick from, gathered once for the form: the dialect's types,
    -- and this object's columns and indexes.
    ctx.types = proto.types(conn.driver)
    local function with_lists(cb)
        if not (ctx.table and ctx.table ~= "" and conn.conn_id) then
            ctx.columns, ctx.indexes = ctx.columns or {}, ctx.indexes or {}
            return cb()
        end
        local db = require("lvim-db")
        local obj = { name = ctx.table, schema = ctx.schema }
        db.columns(conn.conn_id, obj, function(cols)
            local names = {}
            for _, c in ipairs(cols or {}) do
                names[#names + 1] = c.name
            end
            ctx.columns = names
            if not proto.caps(conn.driver).indexes then
                ctx.indexes = {}
                return cb()
            end
            db.indexes(conn.conn_id, obj, function(idx)
                local inames = {}
                for _, i in ipairs(idx or {}) do
                    inames[#inames + 1] = i.name
                end
                ctx.indexes = inames
                cb()
            end)
        end)
    end
    local items = {}
    for _, op in ipairs(ops) do
        items[#items + 1] = { label = "  " .. (op.label or op.op), spec = op }
    end
    require("lvim-ui").select({
        title = "Schema change",
        items = items,
        callback = function(confirmed, idx)
            if not (confirmed and items[idx]) then
                return
            end
            with_lists(function()
                M.open(conn, ctx, items[idx].spec)
            end)
        end,
    })
end

return M
