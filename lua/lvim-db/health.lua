-- lvim-db.health: :checkhealth lvim-db.
-- Reports whether the Rust daemon binary is built and where it was found, the
-- negotiated protocol version and the driver set the backend was compiled with,
-- and whether the persistence store (sqlite.lua) is available. The daemon is
-- probed SYNCHRONOUSLY here (spawn + handshake, briefly waited on) so the report
-- reflects a real backend, not just a binary on disk. Read-only.
--
---@module "lvim-db.health"

local config = require("lvim-db.config")
local daemon = require("lvim-db.daemon")
local store = require("lvim-db.store")

local M = {}

--- Validate the config values, reporting each problem.
---@param h table  the vim.health reporter
local function check_config(h)
    local ok = true
    if type(config.page_size) ~= "number" or config.page_size <= 0 then
        h.error("config.page_size must be a number > 0")
        ok = false
    end
    if type(config.confirm_destructive) ~= "boolean" then
        h.error("config.confirm_destructive must be a boolean")
        ok = false
    end
    if config.daemon_path ~= nil and type(config.daemon_path) ~= "string" then
        h.error("config.daemon_path must be a string path or nil")
        ok = false
    end
    if ok then
        h.ok("config is valid")
    end
end

--- Spawn + handshake the daemon, waiting briefly, then report what it advertised.
---@param h table
local function check_daemon(h)
    local bin = daemon.binary_path()
    if not bin then
        h.warn("daemon binary not found — database connections are unavailable")
        h.info("build it with `sh native/build.sh` (needs a Rust toolchain: cargo)")
        return
    end
    h.ok("daemon binary: " .. bin)

    -- Drive the handshake and wait for it (checkhealth is allowed to block briefly).
    local done, ok_flag, err_msg = false, false, nil
    daemon.ensure(function(ok, err)
        done, ok_flag, err_msg = true, ok, err
    end)
    vim.wait(config.connect_timeout_ms or 15000, function()
        return done
    end, 20)

    if not ok_flag then
        h.error("daemon failed to start / handshake: " .. tostring(err_msg))
        return
    end
    h.ok(("backend protocol %d (running)"):format(daemon.proto() or 0))

    local metas = daemon.drivers()
    if #metas == 0 then
        h.warn("backend reported no drivers")
    else
        local kinds = {}
        for _, m in ipairs(metas) do
            kinds[#kinds + 1] = m.display or m.kind
        end
        table.sort(kinds)
        h.ok(("%d driver%s: %s"):format(#metas, #metas == 1 and "" or "s", table.concat(kinds, ", ")))
    end

    -- Encryption posture (the standard build ships rustls TLS + the SSH tunnel).
    h.ok("encryption: rustls TLS + SSH tunnel — safe default is 'prefer' (encrypt when available)")
    h.info(
        "set a connection's tls.mode to 'require'/'verify_ca'/'verify_full' to mandate encryption "
            .. "(a plaintext-only server is then rejected); an unencrypted link is always surfaced, never silent"
    )
end

--- Report the persistence store. Not mandatory: lvim-db works without it, only
--- losing saved connections / call-log history.
---@param h table
local function check_store(h)
    local ok, s = pcall(require, "lvim-utils.store")
    if ok and s.health then
        s.health(h, false)
    elseif store.available() then
        h.ok("persistence store available")
    else
        h.info("persistence store unavailable (saved connections / history disabled)")
    end
end

--- Entry point for `:checkhealth lvim-db`.
function M.check()
    local h = vim.health
    h.start("lvim-db")

    check_config(h)
    check_daemon(h)
    check_store(h)
end

return M
