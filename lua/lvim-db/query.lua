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

--- Read this object's rows for `driver`. `limit` bounds it (a peek); `limit = nil` reads the WHOLE object —
--- the daemon streams it and the grid pages on demand, so an unbounded browse never loads more than a page
--- at a time. The drawer's Data facet passes nil (browse the table); a caller that only wants a peek passes a
--- number.
---@param driver string
---@param schema string?
---@param object string
---@param limit integer?
---@return string
function M.preview_statement(driver, schema, object, limit)
    if driver == "mongodb" then
        local cmd = { find = object }
        if limit then
            cmd.limit = limit
        end
        return vim.json.encode(cmd)
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
        return limit and ("SELECT TOP %d * FROM %s"):format(limit, qualified) or ("SELECT * FROM %s"):format(qualified)
    end
    return limit and ("SELECT * FROM %s LIMIT %d"):format(qualified, limit) or ("SELECT * FROM %s"):format(qualified)
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

--- A "how many rows does this object hold" statement for `driver`, or nil when the engine has no cheap count
--- (redis). The result is ONE row whose value is the total — read by `range_text`'s total fetch. Aliased
--- `AS n` where the dialect allows, but the reader takes the first numeric cell, so an un-aliasable count
--- (CQL) still works.
---@param driver string
---@param schema string?
---@param object string
---@return string?
function M.count_statement(driver, schema, object)
    if driver == "mongodb" then
        return vim.json.encode({ count = object }) -- → { n, ok }
    end
    if driver == "redis" then
        return nil
    end
    local qualified = qualify(driver, schema, object)
    if driver == "cassandra" or driver == "scylla" then
        return ("SELECT COUNT(*) FROM %s"):format(qualified) -- CQL has no column alias here
    end
    return ("SELECT COUNT(*) AS n FROM %s"):format(qualified)
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
        -- T-SQL has no ALTER … RENAME; sp_rename is the documented way. Both @objname and @newname are
        -- passed as string LITERALS, so any `'` in an identifier has to be '-doubled (same rule as
        -- `M.literal`) or it would break out of the quotes. @objname is the schema-qualified column
        -- (schema.table.column) — sp_rename parses it as a multi-part name; @newname is taken literally
        -- (it must be the bare new column name, unquoted), so it is only escaped, never qualified.
        local function esc(s)
            return (s:gsub("'", "''"))
        end
        local objname = (schema and schema ~= "") and ("%s.%s.%s"):format(schema, object, from)
            or ("%s.%s"):format(object, from)
        return ("EXEC sp_rename '%s', '%s', 'COLUMN';"):format(esc(objname), esc(to))
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

-- ─── writing one row back ─────────────────────────────────────────────────────
--
-- The grid's inline editor sends exactly ONE statement per save: an `UPDATE … SET <changed> WHERE <key>`.
-- Only the CHANGED cells are in the SET — a minimal update, so a cell the user never touched is never
-- rewritten (that also keeps a display-TRUNCATED cell out of the statement, which is what stops the grid
-- from writing a "…"-ended prefix over the real value).
--
-- The daemon executes a STATEMENT, not a prepared call (`Connection::execute(&str)`) — there is no bind
-- channel — so the values are rendered as literals here, per dialect. That makes `literal()` the one place
-- where quoting correctness lives.

--- Can this engine update a single addressed row at all? Returns false + the honest reason when not, so a
--- caller can say WHY a grid is read-only instead of offering an edit that silently matches nothing.
---@param driver string
---@return boolean, string?
function M.can_update_row(driver)
    if driver == "redis" then
        return false, "redis has no addressable row to update"
    end
    return true
end

--- Render `v` as MongoDB EXTENDED JSON — the form the server matches and updates on.
---
--- The whole point is `__oid`: the daemon tags an ObjectId (`Value::Oid`) instead of flattening it to its
--- hex, because `{_id: "<hex>"}` matches no real ObjectId — it would report success and change nothing. Here
--- that tag becomes `{"$oid": …}`, which the driver parses back into a true ObjectId (see its `dispatch`).
---@param v any
---@return any  a value ready for `vim.json.encode`
local function ext_json(v)
    if v == nil or v == vim.NIL then
        return vim.NIL
    end
    if type(v) == "table" then
        if type(v.__oid) == "string" then
            return { ["$oid"] = v.__oid }
        end
        -- Bytes / a nested document or array: already the shape the driver produced, pass it through.
        return v
    end
    return v
end

--- Render `v` as a SQL literal for `driver`. `nil` / JSON-null become NULL.
---@param driver string
---@param v any
---@return string
function M.literal(driver, v)
    if v == nil or v == vim.NIL then
        return "NULL"
    end
    if type(v) == "number" then
        return tostring(v)
    end
    if type(v) == "boolean" then
        -- sqlite has no boolean type — it stores 1/0 and would take TRUE as an unknown identifier.
        if driver == "sqlite" then
            return v and "1" or "0"
        end
        return v and "TRUE" or "FALSE"
    end
    local s = tostring(v)
    -- MySQL/MariaDB and ClickHouse interpret BACKSLASH escapes inside a string literal (the ANSI engines do
    -- not), so a lone backslash there would swallow the character after it — double it first, then the ANSI
    -- '' doubling handles the quote for every engine.
    if driver == "mysql" or driver == "mariadb" or driver == "clickhouse" then
        s = s:gsub("\\", "\\\\")
    end
    return "'" .. s:gsub("'", "''") .. "'"
end

--- `UPDATE <object> SET <set> WHERE <where>` for `driver` — one row, addressed by its key.
--- Both `set` and `where` are ORDERED lists of `{ name, value }` so the emitted statement is deterministic
--- (a map would reorder between runs and make the call log unreadable).
---@param driver string
---@param schema string?
---@param object string
---@param set { name: string, value: any }[]     the CHANGED columns and their new values
---@param where { name: string, value: any }[]   the key columns and their ORIGINAL values
---@return string?, string?  the statement, or nil + why this engine cannot express it
function M.update_row(driver, schema, object, set, where)
    local ok, why = M.can_update_row(driver)
    if not ok then
        return nil, why
    end
    if #set == 0 then
        return nil, "nothing changed"
    end
    if #where == 0 then
        return nil, "no key columns — the row cannot be addressed"
    end
    if driver == "mongodb" then
        -- A document update is a COMMAND, not a statement — the same `update`/`$set` shape the other mongo
        -- templates here use. `multi = false`: this addresses ONE document, and a `_id` filter can only ever
        -- match one, but saying so means a filter that somehow widened still cannot rewrite the collection.
        local q, u = {}, {}
        for _, w in ipairs(where) do
            q[w.name] = ext_json(w.value)
        end
        for _, s in ipairs(set) do
            u[s.name] = ext_json(s.value)
        end
        return vim.json.encode({
            update = object,
            updates = { { q = q, u = { ["$set"] = u }, multi = false } },
        })
    end
    local t = qualify(driver, schema, object)
    local sets, conds = {}, {}
    for _, s in ipairs(set) do
        sets[#sets + 1] = ("%s = %s"):format(quote(driver, s.name), M.literal(driver, s.value))
    end
    for _, w in ipairs(where) do
        -- A NULL key value cannot be matched with `=` (NULL = NULL is unknown). A key column is NOT NULL by
        -- definition, so this is a can't-happen — but expressed rather than assumed.
        if w.value == nil or w.value == vim.NIL then
            return nil, ("key column '%s' is NULL — the row cannot be addressed"):format(w.name)
        end
        conds[#conds + 1] = ("%s = %s"):format(quote(driver, w.name), M.literal(driver, w.value))
    end
    local body = ("%s SET %s WHERE %s"):format(t, table.concat(sets, ", "), table.concat(conds, " AND "))
    if driver == "clickhouse" then
        -- ClickHouse has no plain UPDATE: a row change is a MUTATION spelled `ALTER TABLE … UPDATE`, and it is
        -- ASYNCHRONOUS by default — the statement returns before the row is actually changed, so the grid's
        -- re-read after a save would show the STALE value. `SETTINGS mutations_sync = 1` makes it BLOCK until
        -- the mutation is applied, so the write is done (and the re-read fresh) by the time `M.write` returns.
        return ("ALTER TABLE %s SETTINGS mutations_sync = 1;"):format(body)
    end
    return ("UPDATE %s;"):format(body)
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
