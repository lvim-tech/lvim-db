-- lvim-db — register the docker test bed as saved connections, so the drawer shows every engine the
-- compose file brings up and each driver can be exercised from the real UI (not just an RPC probe).
--
--   docker compose -f docker/compose.yaml up -d
--   :luafile docker/seed.lua
--
-- Every connection is named `t-<engine>` so they sort together and are obvious as throwaways next to real
-- ones. Re-running is safe: saving an existing name overwrites it. Remove them with `x` on the row, or
-- `:luafile docker/seed.lua` after editing this list.
--
-- The credentials match docker/compose.yaml exactly and are deliberately trivial — a localhost test bed.

local db = require("lvim-db")

---@type { name: string, driver: string, spec: table }[]
local CONNS = {
    -- Embedded engines: a file, no server. `/tmp/lvim-db-test.*` so they are as throwaway as the containers.
    {
        name = "t-sqlite",
        driver = "sqlite",
        spec = { params = { file = "/tmp/lvim-db-test.sqlite" } },
    },
    {
        name = "t-duckdb",
        driver = "duckdb",
        spec = { params = { file = "/tmp/lvim-db-test.duckdb" } },
    },
    {
        name = "t-postgres",
        driver = "postgres",
        spec = {
            params = { host = "127.0.0.1", port = "55432", database = "lvimdb" },
            auth = { kind = "password", user = "postgres", password = "lvimdb" },
        },
    },
    {
        name = "t-mysql",
        driver = "mysql",
        spec = {
            params = { host = "127.0.0.1", port = "53306", database = "lvimdb" },
            auth = { kind = "password", user = "root", password = "lvimdb" },
        },
    },
    {
        name = "t-mariadb",
        driver = "mariadb",
        spec = {
            params = { host = "127.0.0.1", port = "53307", database = "lvimdb" },
            auth = { kind = "password", user = "root", password = "lvimdb" },
        },
    },
    {
        name = "t-mongodb",
        driver = "mongodb",
        spec = {
            params = { host = "127.0.0.1", port = "57017", database = "lvimdb" },
            auth = { kind = "password", user = "lvimdb", password = "lvimdb" },
        },
    },
    {
        name = "t-redis",
        driver = "redis",
        spec = { params = { host = "127.0.0.1", port = "56379" } },
    },
    {
        name = "t-clickhouse",
        driver = "clickhouse",
        spec = {
            params = { host = "127.0.0.1", port = "58123", database = "lvimdb" },
            auth = { kind = "password", user = "default", password = "lvimdb" },
        },
    },
    {
        name = "t-mssql",
        driver = "sqlserver",
        spec = {
            params = { host = "127.0.0.1", port = "51433", database = "master" },
            auth = { kind = "password", user = "sa", password = "LvimDb!2345" },
        },
    },
    {
        name = "t-cassandra",
        driver = "cassandra",
        spec = { params = { host = "127.0.0.1", port = "9042", database = "system" } },
    },
    {
        name = "t-firebird",
        driver = "firebird",
        spec = {
            -- The user is UPPERCASE on purpose: Firebird's SRP auth matches the name case-sensitively, and
            -- `lvimdb` is rejected with "user name and password are not defined" while `LVIMDB` connects.
            -- The database is the full SERVER-side path — the image registers no alias.
            params = { host = "127.0.0.1", port = "53050", database = "/var/lib/firebird/data/lvimdb.fdb" },
            auth = { kind = "password", user = "LVIMDB", password = "lvimdb" },
        },
    },
}

local added = {}
for _, c in ipairs(CONNS) do
    if db.store.save_connection(c.name, c.driver, c.spec) then
        added[#added + 1] = c.name
    end
end

vim.notify(
    ("lvim-db: registered %d test connections (%s)"):format(#added, table.concat(added, ", ")),
    vim.log.levels.INFO
)

if package.loaded["lvim-db.ui.drawer"] then
    require("lvim-db.ui.drawer").refresh()
end
