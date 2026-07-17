-- lvim-db.query: driver-aware statement helpers.
-- Small, pure helpers that build the correct statement shape for a given driver
-- kind — a preview SELECT for SQL engines, a find document for MongoDB, a key
-- lookup for Redis — so the UI can offer a "preview this object" action without
-- hardcoding one dialect.
--
---@module "lvim-db.query"

local M = {}

--- Quote a SQL identifier for a driver family.
---@param driver string
---@param ident string
---@return string
local function quote(driver, ident)
    if driver == "mysql" or driver == "mariadb" then
        return "`" .. ident:gsub("`", "``") .. "`"
    end
    -- ANSI double-quote for postgres/cockroachdb/duckdb/sqlite/sqlserver/clickhouse/snowflake
    return '"' .. ident:gsub('"', '""') .. '"'
end

--- A bounded "preview the first rows of this object" statement for `driver`.
---@param driver string
---@param schema string?
---@param object string
---@param limit integer
---@return string
function M.preview_statement(driver, schema, object, limit)
    if driver == "mongodb" then
        return vim.json.encode({ find = object, limit = limit })
    end
    if driver == "redis" then
        -- In Redis the "object" is a key; a type-agnostic peek.
        return "TYPE " .. object
    end
    local qualified
    if driver == "sqlite" or driver == "duckdb" or driver == "firebird" then
        qualified = quote(driver, object)
    elseif schema and schema ~= "" then
        qualified = quote(driver, schema) .. "." .. quote(driver, object)
    else
        qualified = quote(driver, object)
    end
    if driver == "sqlserver" then
        return ("SELECT TOP %d * FROM %s"):format(limit, qualified)
    end
    if driver == "cassandra" or driver == "scylla" then
        return ("SELECT * FROM %s LIMIT %d"):format(qualified, limit)
    end
    return ("SELECT * FROM %s LIMIT %d"):format(qualified, limit)
end

-- ─── DDL templates ────────────────────────────────────────────────────────────
--
-- These BUILD a statement; they never run one. The drawer drops the result into the SQL editor for the user
-- to read and execute — so a generated ALTER is reviewed by a human before it touches a schema, and the
-- destructive guard still applies on the way out. That is the whole point: the plugin knows the dialect, the
-- user keeps the decision.
--
-- Why templates and not a form-with-Apply: `ALTER` dialects diverge far more than `SELECT`, and some engines
-- cannot do what a generic form would imply. SQLite has no ALTER COLUMN at all — changing a column's type
-- means rebuilding the table and copying the data, which a tidy "type: TEXT → INTEGER" dropdown would have to
-- do silently. Generating the statement keeps that impossible to hide.

--- Qualify an object for `driver`, matching `preview_statement`'s rules (the file-based engines have no
--- schema to qualify with).
---@param driver string
---@param schema string?
---@param object string
---@return string
local function qualify(driver, schema, object)
    if driver == "sqlite" or driver == "duckdb" or driver == "firebird" then
        return quote(driver, object)
    end
    if schema and schema ~= "" then
        return quote(driver, schema) .. "." .. quote(driver, object)
    end
    return quote(driver, object)
end

--- `ALTER TABLE … ADD COLUMN` for `driver`, or nil when the engine has no such statement.
--- `type_name` is left as the user typed it: a type is the one part of this no dialect table can normalise.
---@param driver string
---@param schema string?
---@param object string
---@param column string
---@param type_name string
---@return string?
function M.add_column(driver, schema, object, column, type_name)
    if driver == "mongodb" or driver == "redis" then
        return nil -- schemaless: a field appears when a document carries it
    end
    local t = qualify(driver, schema, object)
    local c = quote(driver, column)
    if driver == "sqlserver" then
        -- T-SQL spells it without the COLUMN keyword.
        return ("ALTER TABLE %s ADD %s %s;"):format(t, c, type_name)
    end
    if driver == "cassandra" or driver == "scylla" or driver == "firebird" then
        -- CQL and Firebird both spell it without the COLUMN keyword.
        return ("ALTER TABLE %s ADD %s %s;"):format(t, c, type_name)
    end
    return ("ALTER TABLE %s ADD COLUMN %s %s;"):format(t, c, type_name)
end

--- `ALTER TABLE … RENAME COLUMN` for `driver`, or nil where the engine has none.
---@param driver string
---@param schema string?
---@param object string
---@param from string
---@param to string
---@return string?
function M.rename_column(driver, schema, object, from, to)
    if driver == "mongodb" then
        -- Mongo renames a FIELD across documents, not a column: an update, not a DDL.
        return vim.json.encode({
            update = object,
            updates = { { q = vim.empty_dict(), u = { ["$rename"] = { [from] = to } }, multi = true } },
        })
    end
    if driver == "redis" then
        return nil
    end
    local t = qualify(driver, schema, object)
    if driver == "sqlserver" then
        -- T-SQL has no ALTER … RENAME; sp_rename is the documented way.
        return ("EXEC sp_rename '%s.%s', '%s', 'COLUMN';"):format(object, from, to)
    end
    if driver == "firebird" then
        return ("ALTER TABLE %s ALTER COLUMN %s TO %s;"):format(t, quote(driver, from), quote(driver, to))
    end
    if driver == "cassandra" or driver == "scylla" then
        return ("ALTER TABLE %s RENAME %s TO %s;"):format(t, quote(driver, from), quote(driver, to))
    end
    return ("ALTER TABLE %s RENAME COLUMN %s TO %s;"):format(t, quote(driver, from), quote(driver, to))
end

--- `ALTER TABLE … DROP COLUMN` for `driver`, or nil where the engine has none.
---@param driver string
---@param schema string?
---@param object string
---@param column string
---@return string?
function M.drop_column(driver, schema, object, column)
    if driver == "mongodb" then
        -- Again a field, across documents.
        return vim.json.encode({
            update = object,
            updates = { { q = vim.empty_dict(), u = { ["$unset"] = { [column] = "" } }, multi = true } },
        })
    end
    if driver == "redis" then
        return nil
    end
    local t = qualify(driver, schema, object)
    local c = quote(driver, column)
    if driver == "cassandra" or driver == "scylla" or driver == "firebird" then
        return ("ALTER TABLE %s DROP %s;"):format(t, c)
    end
    return ("ALTER TABLE %s DROP COLUMN %s;"):format(t, c)
end

--- `CREATE INDEX` for `driver`. `columns` is a list; `unique` is ignored by engines that have no such notion.
---@param driver string
---@param schema string?
---@param object string
---@param name string
---@param columns string[]
---@param unique boolean?
---@return string?
function M.create_index(driver, schema, object, name, columns, unique)
    if driver == "mongodb" then
        local keys = {}
        for _, c in ipairs(columns) do
            keys[c] = 1
        end
        return vim.json.encode({
            createIndexes = object,
            indexes = { { key = keys, name = name, unique = unique or nil } },
        })
    end
    if driver == "redis" then
        return nil
    end
    local t = qualify(driver, schema, object)
    local cols = {}
    for _, c in ipairs(columns) do
        cols[#cols + 1] = quote(driver, c)
    end
    local collist = table.concat(cols, ", ")
    if driver == "clickhouse" then
        -- ClickHouse indexes are data-SKIPPING indexes and are added through ALTER; a type is required, so
        -- the template names the most generally useful one rather than inventing a default silently.
        return ("ALTER TABLE %s ADD INDEX %s (%s) TYPE bloom_filter GRANULARITY 1;"):format(
            t,
            quote(driver, name),
            collist
        )
    end
    if driver == "cassandra" or driver == "scylla" then
        -- CQL secondary indexes take exactly one target and are never unique.
        return ("CREATE INDEX %s ON %s (%s);"):format(quote(driver, name), t, cols[1] or "")
    end
    return ("CREATE %sINDEX %s ON %s (%s);"):format(unique and "UNIQUE " or "", quote(driver, name), t, collist)
end

--- `DROP INDEX` for `driver` — the one statement whose shape differs most: some engines address an index
--- globally, others only through its table.
---@param driver string
---@param schema string?
---@param object string
---@param name string
---@return string?
function M.drop_index(driver, schema, object, name)
    if driver == "mongodb" then
        return vim.json.encode({ dropIndexes = object, index = name })
    end
    if driver == "redis" then
        return nil
    end
    local t = qualify(driver, schema, object)
    local n = quote(driver, name)
    if driver == "mysql" or driver == "mariadb" or driver == "sqlserver" then
        return ("DROP INDEX %s ON %s;"):format(n, t)
    end
    if driver == "clickhouse" then
        return ("ALTER TABLE %s DROP INDEX %s;"):format(t, n)
    end
    if driver == "postgres" or driver == "cockroachdb" then
        -- Postgres indexes live in a schema, not on the table.
        local qn = (schema and schema ~= "") and (quote(driver, schema) .. "." .. n) or n
        return ("DROP INDEX %s;"):format(qn)
    end
    return ("DROP INDEX %s;"):format(n)
end

return M
