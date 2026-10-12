-- lvim-db.proto: what the ENGINE says about each driver, and the templates it says it in.
--
-- Every dialect fact this plugin needs arrives at `rpc.hello` as part of each
-- `DriverMeta`: the language an empty editor should suggest (`hint`), how to read
-- one object (`browse`, `browse_by_kind`), how to narrow that read
-- (`browse_form`), the fields a document engine wants instead of a text box
-- (`query_form`, `query_template`), the schema changes the dialect can be asked
-- to write out (`ddl_ops`, each with its `asks` and its `scope`), the types its
-- columns can have (`types`), and what it can be asked about itself
-- (`inspectors`).
--
-- This module is the ONLY place that reads them, for the reason the engine
-- declares them at all: a client that writes `SELECT * FROM …` itself is a
-- client that sends SQL to MongoDB, `SELECT TOP` nowhere near SQL Server, and
-- `GET` to a Redis hash. The words belong to the driver; what this module does is
-- fill the holes the driver left — and nothing else.
--
-- The substitution is deliberately the SAME as the desktop client's
-- (`crates/lode-proto/src/lib.rs`: `render_full`, `render_ddl`, `collapse`), down
-- to the order of the replacements and the space squeeze, because two clients
-- rendering one template two ways is two answers to a question that has one.
--
-- It is also where the VERSION gate lives. The protocol only ever grows
-- additively, so `has(n)` is the whole of compatibility: ask before using
-- something, and an older engine loses that one feature instead of breaking.
--
-- Nothing here runs a statement or asks the engine anything: every value is
-- already in the client's hands, and a round trip to format a string is a round
-- trip to format a string.
--
-- Public API:
--   • proto.has(n)                        is the engine at least this protocol?
--   • proto.meta(kind)                    the DriverMeta, with its lists filled in
--   • proto.caps(kind) / proto.hint(kind) the capability set / the editor's language
--   • proto.render_browse(…)              the statement that reads one object
--   • proto.ops_for(meta, scope)          the declared schema changes, by scope
--   • proto.render_ddl(…)                 one of them, written out
--
---@module "lvim-db.proto"

local daemon = require("lvim-db.daemon")

local M = {}

-- ─── the version gate ────────────────────────────────────────────────────────

--- Is the running engine at protocol `n` or newer?
---
--- The one question compatibility needs. The protocol grows ADDITIVELY — a field
--- or a method is added, nothing changes shape — so a client asks before it uses
--- something and an older engine simply does not get that feature. False before
--- the handshake, which is the safe answer: nothing is known yet.
---@param n integer
---@return boolean
function M.has(n)
    local p = daemon.proto()
    return p ~= nil and p >= n
end

-- ─── the declarations ────────────────────────────────────────────────────────

--- The lists every `DriverMeta` carries, so a reader can iterate without `or {}`
--- on each one. An unknown driver answers with all of them empty rather than
--- `nil`: "this engine has no such thing" is a list with nothing in it.
local EMPTY = {
    params = {},
    auth = {},
    caps = {},
    browse_by_kind = {},
    query_form = {},
    browse_form = {},
    builder_ops = {},
    ddl_ops = {},
    types = {},
    inspectors = {},
}

--- The `DriverMeta` for a driver KIND, with its lists filled in and its declared
--- operations normalised. Never nil — an unknown kind (or a handshake that has
--- not happened yet) answers with the empty shape.
---
--- `scope` is defaulted to `"column"` for an engine between protocols 23 and 25,
--- where every declared operation WAS a column change: that is what those
--- engines meant, and it is better than filtering them out of a menu because a
--- field they never had is missing.
---@param kind string
---@return table
function M.meta(kind)
    local found
    for _, m in ipairs(daemon.drivers() or {}) do
        if m.kind == kind then
            found = m
            break
        end
    end
    local out = {}
    for k, v in pairs(found or {}) do
        out[k] = v
    end
    for k, v in pairs(EMPTY) do
        if type(out[k]) ~= "table" then
            out[k] = v
        end
    end
    out.kind = out.kind or kind
    local ops = {}
    for i, op in ipairs(out.ddl_ops) do
        local one = {}
        for k, v in pairs(op) do
            one[k] = v
        end
        one.scope = one.scope or "column"
        one.asks = type(one.asks) == "table" and one.asks or {}
        ops[i] = one
    end
    out.ddl_ops = ops
    return out
end

--- The capability set of a driver kind. Empty for an unknown kind, so every
--- caller can index it without guarding — an absent capability reads as false,
--- which is the safe direction.
---@param kind string
---@return table
function M.caps(kind)
    return M.meta(kind).caps
end

--- What an empty editor should suggest, IN THIS ENGINE'S LANGUAGE. Empty when the
--- engine said nothing, and the caller then shows nothing rather than inviting
--- SQL into a MongoDB connection.
---@param kind string
---@return string
function M.hint(kind)
    return M.meta(kind).hint or ""
end

--- The types this dialect's columns can be declared with (`{ name, args, note }`).
--- Empty where the store has no column types at all — a document or key/value
--- store says so by saying nothing, and a form then offers no type where there is
--- none to give.
---@param kind string
---@return table[]
function M.types(kind)
    return M.meta(kind).types
end

--- The live views this engine can be asked about. Empty means it has nothing to
--- show, which is the honest answer for SQLite.
---@param kind string
---@return table[]
function M.inspectors(kind)
    return M.meta(kind).inspectors
end

--- Does this engine want a structured bar instead of a free-text editor? True
--- only when it declared BOTH the fields and the statement they assemble into —
--- MongoDB does, every SQL driver does not.
---@param meta table
---@return boolean
function M.is_structured(meta)
    return #(meta.query_form or {}) > 0 and (meta.query_template or "") ~= ""
end

-- ─── filling a template ──────────────────────────────────────────────────────

--- Replace every occurrence of `needle` with `repl`, both taken LITERALLY.
---
--- Not `gsub`: a template hole is `{limit}` and a value is somebody's typed text,
--- and both `%` (in `LIKE '%ok%'`) and `-` would be read as pattern syntax. One
--- misread `%` turns a filled statement into a different one.
---@param s string
---@param needle string
---@param repl string
---@return string
local function plain(s, needle, repl)
    local out, from = {}, 1
    while true do
        local a, b = s:find(needle, from, true)
        if not a then
            out[#out + 1] = s:sub(from)
            return table.concat(out)
        end
        out[#out + 1] = s:sub(from, a - 1)
        out[#out + 1] = repl
        from = b + 1
    end
end

M.plain = plain

--- Squeeze runs of spaces, so a filled template reads like a statement somebody
--- wrote. Between tokens only — NEVER inside a quoted string, where a double
--- space is part of the value.
---
--- A template is written to stand up with its holes empty (`SELECT * FROM t
--- {clauses} LIMIT 200;`), which is exactly what leaves the gaps this removes.
---@param s string
---@return string
function M.collapse_spaces(s)
    local out, quote, last_space = {}, nil, false
    for i = 1, #s do
        local c = s:sub(i, i)
        if quote then
            out[#out + 1] = c
            if c == quote then
                quote = nil
            end
        elseif c == "'" or c == '"' then
            quote = c
            out[#out + 1] = c
            last_space = false
        elseif c == " " then
            if not last_space then
                out[#out + 1] = c
            end
            last_space = true
        else
            out[#out + 1] = c
            last_space = false
        end
    end
    return vim.trim(plain(table.concat(out), " ;", ";"))
end

---@class LvimDbRenderOpts
---@field name string?        the object's own name
---@field schema string?      its schema, or nil/"" where the engine has none
---@field limit integer?      how many rows the read is bounded to
---@field fragments string[]? the structured bar's non-empty fragments
---@field clauses string[]?   the browse form's non-empty clauses
---@field columns string?     the projection, or nil for every column

--- Fill an engine-supplied statement template.
---
--- `{qualified}` is the schema-qualified name (the bare name where there is no
--- schema), then `{name}`, `{schema}`, `{limit}`, `{columns}`, and the two kinds
--- of addition a dialect takes: `{fragments}` is comma-joined AND comma-prefixed
--- (so a JSON skeleton reads `{"find": "x"{fragments}}` and is valid with none),
--- while `{clauses}` is space-joined and collapses to nothing, because
--- `WHERE a, ORDER BY b` is not a statement.
---
--- `{qualified}` goes in BEFORE `{name}`, or substituting the shorter hole would
--- eat the longer one's braces.
---@param template string
---@param o LvimDbRenderOpts?
---@return string
function M.render_full(template, o)
    o = o or {}
    local name = o.name or ""
    local schema = o.schema
    if schema == "" then
        schema = nil
    end
    local qualified = schema and (schema .. "." .. name) or name
    local fragments = o.fragments or {}
    local joined = #fragments > 0 and (", " .. table.concat(fragments, ", ")) or ""
    local columns = (o.columns and o.columns ~= "") and o.columns or "*"
    local out = template
    out = plain(out, "{columns}", columns)
    out = plain(out, "{clauses}", table.concat(o.clauses or {}, " "))
    out = plain(out, "{qualified}", qualified)
    out = plain(out, "{name}", name)
    out = plain(out, "{schema}", schema or "")
    out = plain(out, "{limit}", tostring(o.limit or ""))
    out = plain(out, "{fragments}", joined)
    return M.collapse_spaces(out)
end

-- ─── reading one object ──────────────────────────────────────────────────────

--- The browse template for a node of this `kind`, falling back to the driver's
--- general one.
---
--- Most engines need no override: a table is a table. Redis needs six, because
--- reading a key depends on what the key IS — a string is `GET`, a hash is
--- `HGETALL`, a sorted set is `ZRANGE … WITHSCORES` — and the driver is also what
--- labelled the node, so the node's own kind picks the right template.
---@param meta table
---@param kind string?
---@return string
function M.browse_for(meta, kind)
    for _, pair in ipairs(meta.browse_by_kind or {}) do
        if pair[1] == kind then
            return pair[2]
        end
    end
    return meta.browse or ""
end

--- The statement that reads one object, narrowed by whatever the browse form
--- holds. `values` is keyed by each `browse_form` field's `key`; an empty or
--- absent value contributes nothing, so a browse with an untouched form is the
--- plain browse.
---
--- "" when the engine declared no browse for this driver, which a caller must
--- treat as "cannot" rather than as an empty statement.
---@param meta table
---@param kind string?
---@param values table<string, string>?
---@param name string
---@param schema string?
---@param limit integer?
---@return string
function M.render_browse(meta, kind, values, name, schema, limit)
    local template = M.browse_for(meta, kind)
    if template == "" then
        return ""
    end
    local clauses = {}
    for _, f in ipairs(meta.browse_form or {}) do
        local v = vim.trim((values or {})[f.key] or "")
        if v ~= "" and (f.fragment or "") ~= "" then
            clauses[#clauses + 1] = plain(f.fragment, "{value}", v)
        end
    end
    return M.render_full(template, { name = name, schema = schema, limit = limit, clauses = clauses })
end

--- The statement a STRUCTURED bar assembles, from the fields the driver declared.
--- `values` is keyed by each `query_form` field's `key`; an empty field adds
--- nothing, so the skeleton alone is a valid statement.
---@param meta table
---@param name string
---@param schema string?
---@param limit integer?
---@param values table<string, string>?
---@return string
function M.render_query(meta, name, schema, limit, values)
    if not M.is_structured(meta) then
        return ""
    end
    local fragments = {}
    for _, f in ipairs(meta.query_form or {}) do
        local v = vim.trim((values or {})[f.key] or "")
        if v ~= "" and (f.fragment or "") ~= "" then
            fragments[#fragments + 1] = plain(f.fragment, "{value}", v)
        end
    end
    return M.render_full(meta.query_template, { name = name, schema = schema, limit = limit, fragments = fragments })
end

-- ─── schema changes: GENERATED, never run ────────────────────────────────────
--
-- A declared operation is a template plus what it needs filled in. The client
-- collects the values and writes the statement into the editor, where it is read
-- and changed before it runs: a schema change that happens because somebody
-- picked a menu item is a schema change nobody reviewed.
--
-- What the client must NOT do is invent the words. Standard SQL renames a column
-- one way, MySQL before 8 wanted `CHANGE`, SQL Server wants `sp_rename` with a
-- quoted triple — and none of that is in this plugin any more.

--- The declared schema changes of one `scope` (`"column"`, `"index"`, `"object"`,
--- `"new"`), or all of them when `scope` is nil.
---
--- Scope is what makes a menu a FILTER instead of a list of special cases: the
--- client used to decide where an operation belonged by looking at its name,
--- which is a guess from one op and wrong for the next one any dialect declares.
---@param meta table
---@param scope string?
---@return table[]
function M.ops_for(meta, scope)
    local out = {}
    for _, op in ipairs(meta.ddl_ops or {}) do
        if not scope or op.scope == scope then
            out[#out + 1] = op
        end
    end
    return out
end

--- One declared operation by its stable `op` word, or nil where this dialect has
--- no such thing — which is how a key/value store answers "add a column".
---@param meta table
---@param op string
---@return table?
function M.op(meta, op)
    for _, d in ipairs(meta.ddl_ops or {}) do
        if d.op == op then
            return d
        end
    end
    return nil
end

--- What KIND of value a hole wants, plus whatever the kind carries with it.
---
--- The wire shape is serde's external tagging: a plain word for the simple kinds
--- (`"text"`, `"type"`, `"column"`, `"columns"`, `"index"`) and a one-key table
--- for the two that bring words of their own — `{ flag = { on = " NOT NULL",
--- off = "" } }` and `{ rows = { row = … } }`. Both shapes are read HERE so no
--- caller has to know there are two.
---@param ask table
---@return string kind, table? carried
function M.ask_kind(ask)
    local k = ask and ask.kind
    if type(k) == "string" then
        return k, nil
    end
    if type(k) == "table" then
        for name, carried in pairs(k) do
            return name, carried
        end
    end
    -- No kind at all — an engine old enough to have declared only `{key, label,
    -- suggest}` — is free text, which is what those asks were.
    --
    -- A kind this build has never HEARD of is returned as the engine said it: the
    -- word is reported, and the form draws a plain box for anything it does not
    -- recognise. Translating it to "text" here would make a new kind invisible,
    -- and the form needs that fallback for its own sake anyway.
    return "text", nil
end

--- What to put in a hole before anybody types, with `{table}`, `{column}` and
--- `{index}` filled in from what the cursor is on — so an index is offered a name
--- made out of what it is being created on.
---@param ask table
---@param ctx { table?: string, column?: string, index?: string }?
---@return string
function M.suggest(ask, ctx)
    ctx = ctx or {}
    local s = (ask and ask.suggest) or ""
    s = plain(s, "{table}", ctx.table or "")
    s = plain(s, "{column}", ctx.column or "")
    s = plain(s, "{index}", ctx.index or "")
    return s
end

--- ONE row of a repeating group, written with the row's own template.
---
--- The same rule as `render_ddl`, one level down: the template is the DRIVER's and
--- the values are what somebody typed into that row. A row whose `name` is empty
--- is nothing — not a column called "" — so it is left out, which is what makes a
--- half-typed last row in a form harmless.
---@param row table                     the `DdlRow` (template, asks, join)
---@param values table<string, string>  keyed by the row's ask keys
---@return string?
function M.render_ddl_row(row, values)
    if vim.trim((values or {}).name or "") == "" then
        return nil
    end
    local out = row.template or ""
    for key, value in pairs(values) do
        out = plain(out, "{" .. key .. "}", value or "")
    end
    return M.collapse_spaces(out)
end

--- Every row of a repeating group, joined the way the driver said to join them —
--- the value its hole then takes.
---@param row table
---@param rows table<string, string>[]
---@return string
function M.render_ddl_rows(row, rows)
    local written = {}
    for _, values in ipairs(rows or {}) do
        local one = M.render_ddl_row(row, values)
        if one then
            written[#written + 1] = one
        end
    end
    return table.concat(written, row.join or ", ")
end

--- Write out a schema change, in the words the DRIVER declared.
---
--- `values` is keyed by each ask's `key`; a repeating group's hole takes the text
--- `render_ddl_rows` produced. `{qualified}`, `{table}` and `{schema}` come from
--- the object — except for a `new` operation, where there IS no object and the
--- name comes from the ask called `name`, without which a client writes
--- `CREATE TABLE .users`.
---
--- A hole nobody filled KEEPS its braces rather than becoming a gap: a statement
--- with `{type}` still in it cannot be run by mistake.
---
--- nil when this dialect has no such operation — a client then draws nothing
--- rather than a statement it made up.
---@param meta table
---@param op string
---@param name string                    the object, or "" for a `new` operation
---@param schema string?
---@param values table<string, string>
---@return string?
function M.render_ddl(meta, op, name, schema, values)
    local spec = M.op(meta, op)
    if not spec then
        return nil
    end
    values = values or {}
    if spec.scope == "new" then
        name = vim.trim(values.name or "")
    end
    if schema == "" then
        schema = nil
    end
    local qualified = schema and (schema .. "." .. name) or name
    local out = spec.template or ""
    out = plain(out, "{qualified}", qualified)
    out = plain(out, "{table}", name)
    out = plain(out, "{schema}", schema or "")
    -- Then whatever the op asked for, under the key it asked by. This client does
    -- not know what the keys mean and does not need to: it collected them because
    -- the driver said to.
    for key, value in pairs(values) do
        out = plain(out, "{" .. key .. "}", value or "")
    end
    return M.collapse_spaces(out)
end

return M
