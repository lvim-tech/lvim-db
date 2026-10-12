-- The engine, for real: the handshake, a connection, a statement, and a row written
-- back through `row.write`.
--
-- This is the Lua side of `lode`'s own `tests/row.sh` — the same refusals, asked
-- through `daemon.lua` instead of through a shell, because what matters here is
-- that THIS client builds the plan the engine accepts. A spec that faked the
-- engine would pass with a plan the engine refuses.
--
-- Skipped, loudly, without a built engine: `$LODE_DAEMON` names one, or the suite
-- says what it could not check rather than counting it as a pass.

local DAEMON = vim.env.LODE_DAEMON

describe("the engine")

if not DAEMON or DAEMON == "" or not vim.uv.fs_stat(DAEMON) then
    skip("the engine specs", "$LODE_DAEMON does not name a built loded")
    return
end
if vim.fn.executable("sqlite3") ~= 1 then
    skip("the engine specs", "sqlite3 is needed to prepare the fixture")
    return
end

-- A throwaway database, prepared with the shell tool so the fixture is not made
-- by the thing under test. `loose` has no key on purpose: it is what proves an
-- insert needs none and an edit cannot be addressed.
local DB = vim.fn.tempname() .. ".sqlite"
vim.fn.system({
    "sqlite3",
    DB,
    [[
      CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, note TEXT);
      INSERT INTO people (id, name, note) VALUES (1, 'ann', 'first');
      CREATE TABLE loose (a TEXT, b TEXT);
    ]],
})

package.loaded["lvim-db.daemon"] = nil
package.loaded["lvim-db.proto"] = nil
require("lvim-db.config").daemon_path = DAEMON
local daemon = require("lvim-db.daemon")
local proto = require("lvim-db.proto")

--- Run one request and wait for it. Returns `result, err` — the callback shape
--- flattened, because a spec reads better as a sequence than as a staircase.
---@param method string
---@param params table
---@return any, string?
local function call(method, params)
    local done, res, err = false, nil, nil
    daemon.request(method, params, function(r, e)
        res, err, done = r, e, true
    end)
    vim.wait(10000, function()
        return done
    end, 20)
    return res, err
end

local hello = call("rpc.hello", vim.empty_dict())
it("shakes hands and says what it is", function()
    truthy(hello, "the engine answered rpc.hello")
    truthy(hello.proto >= 5, "protocol " .. tostring(hello.proto))
    truthy(#(hello.drivers or {}) > 0)
end)

it("declares a browse template and a type list for sqlite", function()
    truthy(proto.has(3))
    local m = proto.meta("sqlite")
    truthy(m.browse ~= "", "the driver says how to read one object")
    truthy(#m.types > 0, "the driver says what its columns can be")
    truthy(m.caps.edit, "sqlite claims it can write one row")
    eq(
        "SELECT * FROM people LIMIT 100;",
        proto.render_browse(m, "table", {}, "people", nil, 100),
        "the rendered browse is the engine's words with our number in it"
    )
end)

local conn = call("conn.connect", {
    driver = "sqlite",
    name = "lvim-db-spec",
    params = { file = DB },
    auth = { kind = "none" },
})
local conn_id = conn and conn.conn_id

it("opens a connection", function()
    truthy(conn_id, "a connection id came back")
end)

--- Read one value with a statement, so a write can be checked against the TABLE
--- rather than against what the client thinks it wrote.
---@param statement string
---@return any
local function read_one(statement)
    local run = call("query.execute", { conn_id = conn_id, statement = statement })
    local call_id = run and run.call_id
    if not call_id then
        return nil
    end
    local page
    for _ = 1, 100 do
        page = call("query.page", { call_id = call_id, from = 0, n = 1 })
        if page and page.ready then
            break
        end
        vim.wait(20)
    end
    call("query.release", { call_id = call_id })
    return page and page.rows and page.rows[1] and page.rows[1][1]
end

it("runs a statement and pages its result", function()
    eq("ann", read_one("SELECT name FROM people WHERE id = 1;"))
end)

it("declares how to count an object, and the count is the table's real total", function()
    truthy(proto.has(28), "protocol " .. tostring(daemon.proto()) .. " declares a count template")
    local m = proto.meta("sqlite")
    truthy(m.count ~= "", "sqlite says how to count one object")
    eq(1, read_one(proto.render_full(m.count, { name = "people" })), "one row in the table, one in the count")
    eq("", proto.meta("redis").count, "a key/value store declares none, which is an answer")
end)

it("calls a DROP destructive, in its own words", function()
    local res = call("query.classify", { driver = "sqlite", statement = "DROP TABLE people;" })
    truthy(res.dangerous, "the engine says a DROP is destructive")
    truthy(type(res.reason) == "string" and #res.reason > 0, "and says why: " .. tostring(res.reason))
    eq(false, call("query.classify", { driver = "sqlite", statement = "SELECT 1;" }).dangerous)
end)

describe("the engine: writing one row")

local function write(plan, confirm)
    return call("row.write", {
        conn_id = conn_id,
        obj = plan.obj,
        key = plan.key or {},
        set = plan.set or {},
        delete = plan.delete == true,
        insert = plan.insert == true,
        confirm = confirm == true,
    })
end

local function write_err(plan, confirm)
    local _, err = write(plan, confirm)
    return err
end

local PEOPLE = { name = "people" }

it("writes nothing when it is not confirmed, and shows what it would run", function()
    local res = write({ obj = PEOPLE, key = { { "id", 1 } }, set = { { "note", "changed" } } }, false)
    eq(false, res.applied)
    truthy(res.statement:find("UPDATE", 1, true), res.statement)
    eq("first", read_one("SELECT note FROM people WHERE id = 1;"), "the row is untouched")
end)

it("writes exactly one row when it is", function()
    local res = write({ obj = PEOPLE, key = { { "id", 1 } }, set = { { "note", "changed" } } }, true)
    eq(1, res.affected)
    eq("changed", read_one("SELECT note FROM people WHERE id = 1;"))
end)

it("stores a value that looks like SQL as a value", function()
    write({ obj = PEOPLE, key = { { "id", 1 } }, set = { { "note", "'; DROP TABLE people; --" } } }, true)
    eq("'; DROP TABLE people; --", read_one("SELECT note FROM people WHERE id = 1;"))
    eq(1, read_one("SELECT count(*) FROM people;"), "the table is still there")
end)

it("refuses a key that is not the object's key", function()
    local err = write_err({ obj = PEOPLE, key = { { "name", "ann" } }, set = { { "note", "x" } } }, true)
    truthy(err and err:find("key", 1, true), tostring(err))
end)

it("refuses to write a row it cannot address", function()
    local err = write_err({ obj = { name = "loose" }, key = { { "a", "x" } }, set = { { "b", "y" } } }, true)
    truthy(err, "a table with no key has no addressable row")
end)

it("refuses a new row that carries a key", function()
    local err = write_err({ obj = PEOPLE, key = { { "id", 9 } }, set = { { "name", "new" } }, insert = true }, false)
    truthy(err and err:find("not addressed by a key", 1, true), tostring(err))
end)

it("refuses a new row with nothing in it", function()
    local err = write_err({ obj = PEOPLE, set = {}, insert = true }, false)
    truthy(err and err:find("nothing to insert", 1, true), tostring(err))
end)

it("refuses to add and remove in one plan", function()
    local err = write_err({ obj = PEOPLE, set = { { "name", "x" } }, insert = true, delete = true }, false)
    truthy(err and err:find("not two of those", 1, true), tostring(err))
end)

it("adds a row, and the one left-out column comes from the table", function()
    local before = read_one("SELECT count(*) FROM people;")
    local shown = write({ obj = PEOPLE, set = { { "id", 2 }, { "name", "bob" } }, insert = true }, false)
    eq(false, shown.applied)
    truthy(shown.statement:find("INSERT", 1, true), shown.statement)
    eq(before, read_one("SELECT count(*) FROM people;"), "nothing was added by being shown")
    local res = write({ obj = PEOPLE, set = { { "id", 2 }, { "name", "bob" } }, insert = true }, true)
    eq(1, res.affected)
    eq(before + 1, read_one("SELECT count(*) FROM people;"))
    eq(0, read_one("SELECT count(*) FROM people WHERE id = 2 AND note IS NOT NULL;"), "note was left to the table")
end)

it("adds a row to a table with no key, because an insert addresses nothing", function()
    local res = write({ obj = { name = "loose" }, set = { { "a", "1" }, { "b", "2" } }, insert = true }, true)
    eq(1, res.affected)
    eq(1, read_one("SELECT count(*) FROM loose;"))
end)

it("lets the TABLE refuse a key that is taken", function()
    local err = write_err({ obj = PEOPLE, set = { { "id", 2 }, { "name", "again" } }, insert = true }, true)
    truthy(err, "the database refuses a duplicate key; the client does not pretend to know")
    eq(1, read_one("SELECT count(*) FROM people WHERE id = 2;"))
end)

it("removes a row by its key", function()
    local res = write({ obj = PEOPLE, key = { { "id", 2 } }, delete = true }, true)
    eq(1, res.affected)
    eq(0, read_one("SELECT count(*) FROM people WHERE id = 2;"))
end)

it("writes NULL where the plan carries one", function()
    write({ obj = PEOPLE, key = { { "id", 1 } }, set = { { "note", vim.NIL } } }, true)
    eq(1, read_one("SELECT count(*) FROM people WHERE id = 1 AND note IS NULL;"))
end)

describe("the engine: the history a query writes")

-- The one store write made from INSIDE a daemon callback, and the reason the
-- client stopped waiting for it (a wait in there can only time out — see
-- store_spec). Fire-and-forget is only honest if the row actually lands, so this
-- fires one and reads it back.
it("takes a fired history record without the client waiting for the answer", function()
    local store = require("lvim-db.store")
    if store.backend() ~= "engine" then
        return -- a machine without the engine's store has nothing to prove here
    end
    local marker = ("SELECT 'fired-%d-%d';"):format(os.time(), math.random(1000, 9999))
    local t = vim.uv.hrtime()
    store.record({ conn = "lvim-db tests", driver = "sqlite", statement = marker, state = "done", ms = 1, rows = 0 })
    local ms = (vim.uv.hrtime() - t) / 1e6
    truthy(ms < 500, ("the record blocked for %.0f ms"):format(ms))
    local landed = false
    vim.wait(2000, function()
        for _, r in ipairs(store.history(50)) do
            if r.statement == marker then
                landed = true
            end
        end
        return landed
    end, 50)
    truthy(landed, "the fired row reached the engine's history")
end)

call("conn.disconnect", { conn_id = conn_id })
daemon.stop()
vim.fn.delete(DB)
