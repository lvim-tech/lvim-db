-- proto.lua: the version gate, the typed metadata, and the template rendering.
--
-- The declarations below are the ones the engine really sends (`rpc.hello`,
-- `src/drivers/*.rs`), trimmed to what each test needs. They are written out
-- rather than captured from a running engine because these tests are about the
-- RENDERING — that the client fills the driver's holes and invents no words — and
-- that question has the same answer with no engine installed. Whether the engine
-- still declares them is `engine_spec`'s question.

local SQLITE = {
    kind = "sqlite",
    hint = "SELECT * FROM table LIMIT 100",
    caps = { sql = true, edit = true, ddl = true, indexes = true },
    browse = "SELECT {columns} FROM {qualified} {clauses} LIMIT {limit};",
    browse_by_kind = {},
    count = "SELECT COUNT(*) AS n FROM {qualified};",
    browse_form = {
        { key = "filter", label = "Where", fragment = "WHERE {value}" },
        { key = "order", label = "Order by", fragment = "ORDER BY {value}" },
    },
    query_form = {},
    query_template = "",
    types = {
        { name = "integer", args = 0, note = "" },
        { name = "text", args = 0, note = "" },
        { name = "numeric", args = 2, note = "" },
    },
    ddl_ops = {
        {
            op = "add_column",
            label = "Add a column…",
            template = "ALTER TABLE {qualified} ADD COLUMN {column} {type};",
            asks = {
                { key = "column", label = "Name", kind = "text", suggest = "" },
                { key = "type", label = "Type", kind = "type", suggest = "" },
            },
            scope = "column",
        },
        {
            op = "create_index",
            label = "Index these columns…",
            template = "CREATE {unique} INDEX {index} ON {qualified} ({columns});",
            asks = {
                { key = "index", label = "Name", kind = "text", suggest = "idx_{table}_{column}" },
                { key = "columns", label = "Columns", kind = "columns", suggest = "{column}" },
                { key = "unique", label = "Unique", kind = { flag = { on = "UNIQUE", off = "" } }, suggest = "" },
            },
            scope = "column",
        },
        {
            op = "drop_index",
            label = "Drop this index",
            template = "DROP INDEX {index};",
            asks = { { key = "index", label = "Index", kind = "index", suggest = "{index}" } },
            scope = "index",
        },
        {
            op = "create_table",
            label = "New table…",
            template = "CREATE TABLE {qualified} ({columns});",
            asks = {
                { key = "name", label = "Name", kind = "text", suggest = "" },
                {
                    key = "columns",
                    label = "Columns",
                    kind = {
                        rows = {
                            row = {
                                template = "{name} {type}{null}{key}",
                                asks = {
                                    { key = "name", label = "Name", kind = "text", suggest = "" },
                                    { key = "type", label = "Type", kind = "type", suggest = "" },
                                    {
                                        key = "null",
                                        label = "Not null",
                                        kind = { flag = { on = " NOT NULL", off = "" } },
                                        suggest = "",
                                    },
                                    {
                                        key = "key",
                                        label = "Key",
                                        kind = { flag = { on = " PRIMARY KEY", off = "" } },
                                        suggest = "",
                                    },
                                },
                                join = ", ",
                            },
                        },
                    },
                    suggest = "",
                },
            },
            scope = "new",
        },
        {
            op = "drop_table",
            label = "Drop this table",
            template = "DROP TABLE {qualified};",
            asks = {},
            scope = "object",
        },
    },
    inspectors = {},
}

local REDIS = {
    kind = "redis",
    hint = "GET key",
    caps = { sql = false, kv = true, edit = true },
    browse = "TYPE {name}",
    count = "",
    browse_by_kind = {
        { "string", "GET {name}" },
        { "hash", "HGETALL {name}" },
        { "zset", "ZRANGE {name} 0 {limit} WITHSCORES" },
    },
    browse_form = {},
    ddl_ops = {},
    types = {},
}

local MONGO = {
    kind = "mongodb",
    hint = '{"find": "collection", "limit": 50}',
    caps = { sql = false, kv = true, edit = true },
    browse = '{"find": "{name}", "limit": {limit}}',
    count = '{"count": "{name}"}',
    query_form = {
        { key = "filter", label = "Filter", fragment = '"filter": {value}' },
        { key = "limit", label = "Limit", fragment = '"limit": {value}', default = "50" },
    },
    query_template = '{"find": "{name}"{fragments}}',
    browse_form = {},
    ddl_ops = {},
    types = {},
}

local ALL = { SQLITE, REDIS, MONGO }

describe("proto: the version gate")

it("answers false before the handshake, because nothing is known yet", function()
    local proto = fake_daemon(nil, {})
    eq(false, proto.has(1))
    eq(false, proto.has(27))
end)

it("answers by the engine's number, not by this client's wishes", function()
    local proto = fake_daemon(5, ALL)
    truthy(proto.has(5))
    truthy(proto.has(4))
    eq(false, proto.has(27))
end)

describe("proto: the typed metadata")

it("gives an unknown driver empty lists rather than nil", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("nosuchdriver")
    eq({}, m.ddl_ops)
    eq({}, m.types)
    eq({}, m.inspectors)
    eq({}, m.browse_form)
    eq({}, m.caps)
    eq(nil, proto.caps("nosuchdriver").edit, "an absent capability reads as false")
end)

it("reads an operation with no scope as a column change, which is what 23-25 meant", function()
    local proto = fake_daemon(25, {
        { kind = "old", ddl_ops = { { op = "add_column", template = "ALTER {qualified};" } } },
    })
    local m = proto.meta("old")
    eq("column", m.ddl_ops[1].scope)
    eq({}, m.ddl_ops[1].asks)
    eq(1, #proto.ops_for(m, "column"))
    eq({}, proto.ops_for(m, "new"), "a dialect that declares no new-object op is offered none")
end)

it("does not change what the engine sent", function()
    local proto = fake_daemon(27, ALL)
    proto.meta("sqlite").ddl_ops[1].scope = "tampered"
    eq("column", proto.meta("sqlite").ddl_ops[1].scope)
end)

describe("proto: reading one object")

it("browses with the driver's own template", function()
    local proto = fake_daemon(27, ALL)
    eq("SELECT * FROM users LIMIT 200;", proto.render_browse(proto.meta("sqlite"), "table", {}, "users", nil, 200))
    eq(
        "SELECT * FROM public.users LIMIT 50;",
        proto.render_browse(proto.meta("sqlite"), "table", {}, "users", "public", 50)
    )
end)

it("reads a Redis key by WHAT IT IS, and falls back where the kind is unknown", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("redis")
    eq("HGETALL h:1", proto.render_browse(m, "hash", {}, "h:1", nil, 200))
    eq("ZRANGE z 0 10 WITHSCORES", proto.render_browse(m, "zset", {}, "z", nil, 10))
    eq("TYPE k", proto.render_browse(m, "whatever", {}, "k", nil, 10))
end)

it("takes a VALUE from the browse form and never a syntax", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("sqlite")
    eq(
        "SELECT * FROM t WHERE name LIKE '%a-b%' ORDER BY id DESC LIMIT 200;",
        proto.render_browse(m, "table", { filter = "name LIKE '%a-b%'", order = "id DESC" }, "t", nil, 200),
        "a % is a value's character, not a Lua pattern"
    )
    eq(
        "SELECT * FROM t WHERE a<0 LIMIT 200;",
        proto.render_browse(m, "table", { filter = "a<0" }, "t", nil, 200),
        "one clause leaves no double space behind"
    )
    eq("SELECT * FROM t LIMIT 200;", proto.render_browse(m, "table", { filter = "   " }, "t", nil, 200))
end)

it("leaves nothing to browse with where the engine declared none", function()
    local proto = fake_daemon(27, { { kind = "mute" } })
    eq("", proto.render_browse(proto.meta("mute"), "table", {}, "t", nil, 10))
end)

describe("proto: counting one object")

it("fills the driver's count template, and takes an empty one as 'do not ask'", function()
    local proto = fake_daemon(28, ALL)
    eq(
        "SELECT COUNT(*) AS n FROM public.people;",
        proto.render_full(proto.meta("sqlite").count, { name = "people", schema = "public" })
    )
    local mongo = proto.render_full(proto.meta("mongodb").count, { name = "people" })
    eq('{"count": "people"}', mongo)
    truthy((pcall(vim.json.decode, mongo)), "a document store counts with a command")
    eq("", proto.meta("redis").count, "no cheap count is said by saying nothing")
end)

describe("proto: the structured bar")

it("assembles a skeleton that is valid with nothing filled in", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("mongodb")
    truthy(proto.is_structured(m))
    local skeleton = proto.render_query(m, "people", nil, 200, {})
    eq('{"find": "people"}', skeleton)
    truthy((pcall(vim.json.decode, skeleton)))
    local filled = proto.render_query(m, "people", nil, 200, { filter = '{"a": 1}', limit = "5" })
    truthy((pcall(vim.json.decode, filled)))
    eq('{"find": "people", "filter": {"a": 1}, "limit": 5}', filled)
end)

it("says a SQL driver wants a text box, not a bar", function()
    local proto = fake_daemon(27, ALL)
    eq(false, proto.is_structured(proto.meta("sqlite")))
    eq("", proto.render_query(proto.meta("sqlite"), "t", nil, 10, {}))
end)

describe("proto: schema changes, generated")

it("writes a change in the driver's words", function()
    local proto = fake_daemon(27, ALL)
    eq(
        "ALTER TABLE users ADD COLUMN note text;",
        proto.render_ddl(proto.meta("sqlite"), "add_column", "users", nil, { column = "note", type = "text" })
    )
end)

it("leaves no gap where a flag is off", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("sqlite")
    eq(
        "CREATE INDEX idx_users_a ON users (a, b);",
        proto.render_ddl(m, "create_index", "users", nil, { index = "idx_users_a", columns = "a, b", unique = "" })
    )
    eq(
        "CREATE UNIQUE INDEX i ON users (a);",
        proto.render_ddl(m, "create_index", "users", nil, { index = "i", columns = "a", unique = "UNIQUE" })
    )
end)

it("keeps the braces of a hole nobody filled, so it cannot be run by mistake", function()
    local proto = fake_daemon(27, ALL)
    eq(
        "ALTER TABLE users ADD COLUMN note {type};",
        proto.render_ddl(proto.meta("sqlite"), "add_column", "users", nil, { column = "note" })
    )
end)

it("writes a new table from the dialect's own column template", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("sqlite")
    local spec = proto.op(m, "create_table")
    local shape
    for _, ask in ipairs(spec.asks) do
        local kind, carried = proto.ask_kind(ask)
        if kind == "rows" then
            shape = carried.row
        end
    end
    truthy(shape, "the create op declares a repeating group")
    local columns = proto.render_ddl_rows(shape, {
        { name = "id", type = "integer", null = "", key = " PRIMARY KEY" },
        { name = "email", type = "text", null = " NOT NULL", key = "" },
        { name = "", type = "text", null = "", key = "" },
    })
    eq("id integer PRIMARY KEY, email text NOT NULL", columns, "a row with no name is not a column called ''")
    eq(
        "CREATE TABLE people (id integer PRIMARY KEY, email text NOT NULL);",
        proto.render_ddl(m, "create_table", "", nil, { name = "people", columns = columns }),
        "a new object is named by its own ask, or the statement reads CREATE TABLE .people"
    )
    eq(
        "CREATE TABLE main.people (id integer);",
        proto.render_ddl(m, "create_table", "", "main", { name = "people", columns = "id integer" })
    )
end)

it("offers nothing where the dialect has no such operation", function()
    local proto = fake_daemon(27, ALL)
    eq(nil, proto.render_ddl(proto.meta("redis"), "add_column", "k", nil, {}))
    eq(0, #proto.types("redis"), "a store with no column types says so by saying nothing")
    truthy(#proto.types("sqlite") > 0)
end)

it("filters a menu by scope instead of by an operation's name", function()
    local proto = fake_daemon(27, ALL)
    local m = proto.meta("sqlite")
    eq(2, #proto.ops_for(m, "column"))
    eq("drop_index", proto.ops_for(m, "index")[1].op)
    eq("drop_table", proto.ops_for(m, "object")[1].op)
    eq("create_table", proto.ops_for(m, "new")[1].op)
    eq(5, #proto.ops_for(m), "with no scope, all of them")
end)

it("suggests a name made out of what the cursor is on", function()
    local proto = fake_daemon(27, ALL)
    local ask = proto.op(proto.meta("sqlite"), "create_index").asks[1]
    eq("idx_users_email", proto.suggest(ask, { table = "users", column = "email" }))
    eq("idx_users_", proto.suggest(ask, { table = "users" }))
end)

it("reads both shapes of a declared kind, and an unknown one as a box", function()
    local proto = fake_daemon(27, ALL)
    local asks = proto.op(proto.meta("sqlite"), "create_index").asks
    eq("text", (proto.ask_kind(asks[1])))
    eq("columns", (proto.ask_kind(asks[2])))
    local kind, carried = proto.ask_kind(asks[3])
    eq("flag", kind)
    eq("UNIQUE", carried.on)
    eq("", carried.off)
    eq(
        "something_new",
        (proto.ask_kind({ kind = "something_new" })),
        "a kind this build never heard of is REPORTED, and the form draws a box for it"
    )
    eq("text", (proto.ask_kind({})), "an ask from before kinds existed is free text")
end)

describe("proto: the space squeeze")

it("squeezes between tokens and never inside a quoted string", function()
    local proto = fake_daemon(27, ALL)
    eq("SELECT a FROM t;", proto.collapse_spaces("SELECT   a  FROM t ;"))
    eq("SELECT 'a  b' FROM t;", proto.collapse_spaces("SELECT 'a  b'   FROM t ;"))
end)
