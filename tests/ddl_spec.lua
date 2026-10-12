-- ui/ddl.lua: a declared schema change becomes a form.
--
-- The judgement under test is the MAPPING — a flag becomes an on/off whose words
-- are the driver's, a type becomes a box with something to pick from, a repeating
-- group becomes a list — and it is judgement about a DECLARATION, which is why it
-- can be tested without a window or an engine.

local ADD_COLUMN = {
    op = "add_column",
    label = "Add a column…",
    template = "ALTER TABLE {qualified} ADD COLUMN {column} {type};",
    asks = {
        { key = "column", label = "Name", kind = "text", suggest = "" },
        { key = "type", label = "Type", kind = "type", suggest = "" },
    },
    scope = "column",
}

local CREATE_INDEX = {
    op = "create_index",
    label = "Index these columns…",
    template = "CREATE {unique} INDEX {index} ON {qualified} ({columns});",
    asks = {
        { key = "index", label = "Name", kind = "text", suggest = "idx_{table}_{column}" },
        { key = "columns", label = "Columns", kind = "columns", suggest = "{column}" },
        { key = "unique", label = "Unique", kind = { flag = { on = "UNIQUE", off = "" } }, suggest = "" },
    },
    scope = "column",
}

local ROW = {
    template = "{name} {type}{null}{key}",
    asks = {
        { key = "name", label = "Name", kind = "text", suggest = "" },
        { key = "type", label = "Type", kind = "type", suggest = "" },
        { key = "null", label = "Not null", kind = { flag = { on = " NOT NULL", off = "" } }, suggest = "" },
        { key = "key", label = "Key", kind = { flag = { on = " PRIMARY KEY", off = "" } }, suggest = "" },
    },
    join = ", ",
}

local CREATE_TABLE = {
    op = "create_table",
    label = "New table…",
    template = "CREATE TABLE {qualified} ({columns});",
    asks = {
        { key = "name", label = "Name", kind = "text", suggest = "" },
        { key = "columns", label = "Columns", kind = { rows = { row = ROW } }, suggest = "" },
    },
    scope = "new",
}

local CTX = {
    schema = "main",
    table = "users",
    column = "email",
    index = "idx_users_email",
    types = { { name = "text", args = 0 }, { name = "varchar", args = 1 }, { name = "numeric", args = 2 } },
    columns = { "id", "email" },
    indexes = { "idx_users_email" },
}

local ddl = require("lvim-db.ui.ddl")

describe("ddl: the form a declaration asks for")

it("makes one row per ask, in the driver's order", function()
    local rows = ddl.rows_for(ADD_COLUMN, CTX)
    eq({ "column", "type" }, { rows[1].name, rows[2].name })
    eq({ "Name", "Type" }, { rows[1].label, rows[2].label })
end)

it("offers the dialect's types with the arity it declared, and stays a BOX", function()
    local rows = ddl.rows_for(ADD_COLUMN, CTX)
    eq("string", rows[2].type, "a closed list would refuse numeric(12, 2)")
    eq({ "text", "varchar(n)", "numeric(p, s)" }, rows[2]._picks)
end)

it("seeds a hole from what the cursor is on", function()
    local rows = ddl.rows_for(CREATE_INDEX, CTX)
    eq("idx_users_email", rows[1].value)
    eq("email", rows[2].value)
    eq({ "id", "email" }, rows[2]._picks, "a column list picks from the object's columns")
end)

it("makes a flag an on/off that carries the DRIVER's words", function()
    local rows = ddl.rows_for(CREATE_INDEX, CTX)
    local flag = rows[3]
    eq("bool", flag.type)
    eq("UNIQUE", flag._on)
    eq("", flag._off)
    eq(false, flag.value, "a flag starts off: a UNIQUE index is not what somebody asked for by default")
end)

it("gives a flag's OWN word to the statement, never the key's name", function()
    local rows = ddl.rows_for(CREATE_INDEX, CTX)
    eq("", ddl.values_of(rows).unique)
    rows[3].value = true
    eq("UNIQUE", ddl.values_of(rows).unique, "`unique` → `UNIQUE` was right once and wrong for NOT NULL")
end)

it("lifts a repeating group out of the rows, with its own template", function()
    local rows, group = ddl.rows_for(CREATE_TABLE, CTX)
    eq(1, #rows, "the group is not a box")
    eq("name", rows[1].name)
    truthy(group, "the group is reported")
    eq("columns", group.key)
    eq("{name} {type}{null}{key}", group.row.template, "each row is written in the dialect's words")
    eq(4, #group.row.asks)
end)

it("offers nothing to pick where the engine declared nothing", function()
    local bare = { types = {}, columns = {}, indexes = {} }
    local rows = ddl.rows_for(ADD_COLUMN, bare)
    eq(nil, rows[2]._picks, "a store with no column types is offered no type")
end)
