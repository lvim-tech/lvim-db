-- lvim-db.query: the one statement this client still builds itself.
--
-- WHAT IS NO LONGER HERE is the whole point of the file. Browsing an object, counting it, writing a row back,
-- deciding whether a statement is destructive, where one statement ends and the next begins, and every DDL
-- template — all of them were written here, once per driver NAME, and all of them are the engine's now:
-- `browse` / `browse_by_kind` / `count` / `ddl_ops` as declarations (see `proto.lua`), `row.write` with bound
-- values, `query.classify`, `query.split`. The engine has twenty dialects and two clients; this file had one
-- copy of some of them, and it was wrong about Redis.
--
-- What is left is the one write the engine cannot express.
--
---@module "lvim-db.query"

local M = {}

--- REPLACE a whole MongoDB document, addressed by its `_id`. `doc` is the edited document as decoded
--- extended JSON (`_id` as `{ ["$oid"] = … }`, dates as `{ ["$date"] = … }`, etc.) — exactly what the
--- driver's `Bson::try_from` reads back into real BSON. The replacement `u` carries NO update operators, so
--- mongo treats it as a full document replacement; `multi = false` keeps it to the one addressed document.
---
--- Mongo only: no other engine has a whole-row "replace this document" that a JSON edit maps onto (a SQL row
--- is columns, each written through `row.write`).
---
--- The ONE write still built here, because `row.write` cannot say it: the engine
--- sets top-level fields (`$set`), so a field REMOVED from the edited document
--- would silently stay in the stored one. A replacement says the document is now
--- exactly this. It goes through `query.execute` like any other command — which
--- also means it is classified and audited like any other command.
---@param driver string
---@param object string          the collection
---@param doc table              the edited document (decoded extended JSON)
---@return string?, string?      the command, or nil + why
function M.replace_document(driver, object, doc)
    if driver ~= "mongodb" then
        return nil, "whole-document replace is a MongoDB operation"
    end
    if type(doc) ~= "table" then
        return nil, "the document is not a JSON object"
    end
    local id = doc._id
    if id == nil then
        return nil, "the document has no _id — it cannot be addressed for replacement"
    end
    return vim.json.encode({
        update = object,
        updates = { { q = { _id = id }, u = doc, multi = false } },
    })
end


return M
