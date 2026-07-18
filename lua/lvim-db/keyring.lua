-- lvim-db.keyring: migrate PLAINTEXT connection secrets into the lvim-keyring wallet.
--
-- lvim-db owns its store (saved connections in sqlite), so it can DETECT its own plaintext secrets: a
-- credential field is a `Secret` TEMPLATE, and a "plaintext" one is a literal string that is not a
-- `{{ … }}` template (env/cmd/vault) and not empty. This module scans the saved connections, hands the
-- literals to lvim-keyring's universal `migrate` seam (which confirms + stores them under `db/<name>`),
-- and then REWRITES each migrated field in the stored spec to `{{ vault "db/<name>" }}` — so the store
-- keeps only the template and the real secret lives encrypted in the wallet. pcall-guarded: no hard
-- dependency on lvim-keyring.
--
---@module "lvim-db.keyring"

local store = require("lvim-db.store")

local M = {}

--- A field is a plaintext candidate: a non-empty string that is NOT already a `{{ … }}` template.
---@param v any
---@return boolean
local function is_plaintext(v)
    return type(v) == "string" and v ~= "" and not v:match("^%s*{{")
end

---@class LvimDbSecretHit
---@field conn string        the connection name
---@field driver string
---@field spec table         the (shared) decoded spec — mutated in place on rewrite
---@field path string[]      the field path inside spec (e.g. { "auth", "password" })
---@field value string       the literal secret
---@field vault_name string  the wallet key (`db/<conn>` / `db/<conn>-tunnel`)

--- Scan every saved connection for plaintext credential fields.
---@return LvimDbSecretHit[]
function M.scan()
    local hits = {}
    for _, c in ipairs(store.list_connections()) do
        local spec = c.spec or {}
        local auth = spec.auth or {}
        -- the main auth secret (whichever method the connection uses)
        for _, f in ipairs({ "password", "token", "key_password" }) do
            if is_plaintext(auth[f]) then
                hits[#hits + 1] = {
                    conn = c.name,
                    driver = c.driver,
                    spec = spec,
                    path = { "auth", f },
                    value = auth[f],
                    vault_name = "db/" .. c.name,
                }
            end
        end
        -- the SSH tunnel secret (a separate wallet entry, so both can be templated independently)
        local tauth = spec.tunnel and spec.tunnel.auth or nil
        if tauth then
            for _, f in ipairs({ "passphrase", "password" }) do
                if is_plaintext(tauth[f]) then
                    hits[#hits + 1] = {
                        conn = c.name,
                        driver = c.driver,
                        spec = spec,
                        path = { "tunnel", "auth", f },
                        value = tauth[f],
                        vault_name = "db/" .. c.name .. "-tunnel",
                    }
                end
            end
        end
    end
    return hits
end

--- Set the value at `spec` under `path` (e.g. { "auth", "password" }).
---@param spec table
---@param path string[]
---@param value string
local function set_path(spec, path, value)
    local t = spec
    for i = 1, #path - 1 do
        t = t[path[i]]
    end
    t[path[#path]] = value
end

--- Scan → migrate to the wallet → rewrite the migrated fields to `{{ vault "…" }}`.
function M.migrate()
    local ok_kr, kr = pcall(require, "lvim-keyring")
    if not ok_kr then
        vim.notify("lvim-db: lvim-keyring is not installed", vim.log.levels.WARN)
        return
    end
    if not store.available() then
        vim.notify("lvim-db: the connection store is unavailable (sqlite.lua?)", vim.log.levels.WARN)
        return
    end
    local hits = M.scan()
    if #hits == 0 then
        vim.notify("lvim-db: no plaintext secrets in saved connections", vim.log.levels.INFO)
        return
    end
    local candidates = {}
    for _, h in ipairs(hits) do
        candidates[#candidates + 1] = { name = h.vault_name, value = h.value }
    end
    kr.migrate(candidates, function(outcome, err)
        if not outcome then
            if err and err ~= "cancelled" then
                vim.notify("lvim-db: keyring — " .. err, vim.log.levels.WARN)
            end
            return
        end
        -- Rewrite every field whose secret was STORED (or was already present, i.e. skipped — the wallet
        -- has it either way, so the store should reference it). Group by connection: save once per spec.
        local landed = {}
        for _, n in ipairs(outcome.stored) do
            landed[n] = true
        end
        for _, n in ipairs(outcome.skipped) do
            landed[n] = true
        end
        local touched = {}
        for _, h in ipairs(hits) do
            if landed[h.vault_name] then
                set_path(h.spec, h.path, ('{{ vault "%s" }}'):format(h.vault_name))
                touched[h.conn] = { driver = h.driver, spec = h.spec }
            end
        end
        local n = 0
        for name, cd in pairs(touched) do
            if store.save_connection(name, cd.driver, cd.spec) then
                n = n + 1
            end
        end
        vim.notify(
            ("lvim-db: migrated %d secret(s) to the keyring; %d connection spec(s) now use {{ vault … }}%s"):format(
                #outcome.stored,
                n,
                #outcome.failed > 0 and (" (%d failed)"):format(#outcome.failed) or ""
            ),
            vim.log.levels.INFO
        )
        local drawer = require("lvim-db.ui.drawer")
        if drawer.is_open() then
            drawer.refresh()
        end
    end)
end

return M
