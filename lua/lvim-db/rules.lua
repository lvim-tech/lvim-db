-- lvim-db.rules: the small decisions a view makes, as plain functions.
--
-- Pure, and deliberately so: each takes simple tables (a column list, what
-- somebody typed) and returns a value. Nothing here touches `state`, a window or
-- the daemon, which is the whole reason these decisions can be TESTED — and they
-- are the decisions worth testing, because each one is a rule about somebody's
-- data rather than a matter of drawing.
--
-- The dialect is NOT a rule in here. What a statement looks like is the engine's
-- (see `proto.lua`); what is in this file is what the client legitimately
-- decides: whether an empty box means NULL or "leave it alone", which columns a
-- new row carries, and what the text in a box is as a VALUE.
--
---@module "lvim-db.rules"

local M = {}

--- What the text in a box IS, given what the column holds.
---
--- `kind` is the engine's own word for the column's values — `integer`, `float`,
--- `bool`, `json`, `text`, `timestamp`, `binary`, `unknown` — derived in ONE
--- table in the engine from eighteen drivers' vocabularies (`schema.columns`
--- carries it from protocol 28). A client that read the driver's type NAME
--- instead would have to know that `int8`, `BIGINT`, `Int64` and `NUMBER(38,0)`
--- are one idea, and would send `"2"` to a column that wanted `2`.
---
--- `null` is the WORD for NULL, and is the only way to write one from a box:
--- `vim.NIL` survives `vim.json.encode` where a Lua `nil` would vanish. The cost
--- is that a column cannot be given the literal text "null" this way, which is
--- worth it — a form in which NULL is unreachable is a form that cannot write a
--- row most tables accept.
---
--- Text the kind cannot take (`abc` in an integer column) is passed through AS
--- TYPED, on purpose: the SERVER then refuses it and says what it wanted, which
--- is a better answer than this client inventing one from a type name.
---@param text string
---@param kind string?
---@return any
function M.parse_cell(text, kind)
    local t = vim.trim(text or "")
    if t:lower() == "null" then
        return vim.NIL
    end
    if kind == "integer" or kind == "float" then
        return tonumber(t) or t
    end
    if kind == "bool" then
        local l = t:lower()
        if l == "true" or l == "1" then
            return true
        end
        if l == "false" or l == "0" then
            return false
        end
        return t
    end
    if kind == "json" then
        local ok, parsed = pcall(vim.json.decode, t)
        if ok then
            return parsed
        end
        return t
    end
    return t
end

--- The columns a NEW row carries, from the object's columns and what was typed.
---
--- THE ONE RULE: an EMPTY box is left out of the row entirely, and `null` writes
--- NULL. Those are different things and a form that confused them would be
--- unusable — a column with a default, a counter, a generated id and a `NOT NULL
--- DEFAULT now()` all need "say nothing about this one", while a nullable column
--- sometimes needs an explicit NULL. Leaving the column out is how the TABLE
--- gets to fill it in.
---
--- Ordered pairs, in the object's own column order, because that is what the
--- engine's `row.write` takes and what makes the statement it shows come out the
--- same way twice.
---@param columns { name: string, kind: string? }[]  the OBJECT's columns (not the result's)
---@param typed table<string, string>                box text, keyed by column name
---@return { name: string, value: any }[]
function M.insert_set(columns, typed)
    local set = {}
    for _, c in ipairs(columns or {}) do
        local text = (typed or {})[c.name]
        if text ~= nil and vim.trim(text) ~= "" then
            set[#set + 1] = { name = c.name, value = M.parse_cell(text, c.kind) }
        end
    end
    return set
end

return M
