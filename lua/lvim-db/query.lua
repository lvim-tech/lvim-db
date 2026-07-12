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

return M
