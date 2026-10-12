-- rules.lua: the decisions that are the client's own.

local rules = require("lvim-db.rules")

local COLUMNS = {
    { name = "id", kind = "integer", primary = true },
    { name = "name", kind = "text" },
    { name = "score", kind = "float" },
    { name = "active", kind = "bool" },
    { name = "meta", kind = "json" },
    { name = "made", kind = "timestamp" },
}

describe("rules: what a box holds")

it("types a value by what the COLUMN holds, not by what the driver calls it", function()
    eq(2, rules.parse_cell("2", "integer"))
    eq(1.5, rules.parse_cell("1.5", "float"))
    eq(true, rules.parse_cell("true", "bool"))
    eq(true, rules.parse_cell("1", "bool"))
    eq(false, rules.parse_cell("FALSE", "bool"))
    eq("ann", rules.parse_cell("ann", "text"))
    eq({ a = 1 }, rules.parse_cell('{"a": 1}', "json"))
    eq("2026-10-12", rules.parse_cell("2026-10-12", "timestamp"), "a timestamp goes as the text somebody typed")
end)

it("passes text the kind cannot take STRAIGHT THROUGH, for the server to refuse", function()
    eq("abc", rules.parse_cell("abc", "integer"), "the server says what it wanted; this client does not guess")
    eq("maybe", rules.parse_cell("maybe", "bool"))
    eq("{oops", rules.parse_cell("{oops", "json"))
end)

it("writes NULL for the word, and survives being encoded", function()
    eq(vim.NIL, rules.parse_cell("null", "text"))
    eq(vim.NIL, rules.parse_cell("NULL", "integer"))
    eq("null", vim.json.encode(rules.parse_cell("null", "text")), "a Lua nil would have vanished here")
end)

it("takes a column with no declared kind as text", function()
    eq("7", rules.parse_cell("7", nil), "an engine older than 28 says nothing, and nothing is not a number")
    eq("7", rules.parse_cell("7", "unknown"))
end)

describe("rules: what a new row carries")

it("leaves an empty box OUT and writes null as NULL", function()
    local set = rules.insert_set(COLUMNS, { id = "", name = "ann", score = "null", active = "", meta = "" })
    eq({ { name = "name", value = "ann" }, { name = "score", value = vim.NIL } }, set)
end)

it("counts whitespace as empty, because a space is not a value somebody meant", function()
    eq({}, rules.insert_set(COLUMNS, { id = "   ", name = "\t" }))
end)

it("keeps the object's own column order, so the statement comes out the same twice", function()
    local set = rules.insert_set(COLUMNS, { meta = '{"a":1}', id = "3", name = "bo" })
    eq({ "id", "name", "meta" }, { set[1].name, set[2].name, set[3].name })
    eq(3, set[1].value, "and each value is typed by its column")
end)

it("says a form with nothing in it is nothing, rather than an empty row", function()
    eq({}, rules.insert_set(COLUMNS, {}))
    eq({}, rules.insert_set({}, { id = "1" }), "a column nobody declared is not a column to write")
end)
