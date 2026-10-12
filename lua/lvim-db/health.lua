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
        h.warn("no database engine found — database connections are unavailable")
        h.info(
            "install lode (https://github.com/lvim-tech/lode): clone it, run `scripts/build`, then put "
                .. "`loded` on $PATH or set `daemon_path`. Needs a Rust toolchain (cargo)."
        )
        h.info("probed, in order: daemon_path, $LODE_DAEMON, $LVIM_DB_DAEMON, loded on $PATH, a lode checkout")
        return
    end
    h.ok("engine binary: " .. bin)

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
    -- WHICH engine is on the other end of the pipe. The plugin accepts both the
    -- lode engine and the daemon that used to ship inside it, and they are not
    -- equivalent — only lode carries the shared saved state — so the report
    -- names the one that actually answered rather than just its protocol number.
    local eng = daemon.engine()
    if eng and not eng.legacy then
        h.ok(("engine: %s %s, protocol %d"):format(eng.name, eng.version, eng.proto or 0))
    elseif eng then
        h.warn(("engine: %s, protocol %d"):format(eng.name, eng.proto or 0))
        h.info(
            "this is the OLD in-plugin daemon (native/). It still works, but the saved connections, queries "
                .. "and history stay local to Neovim — install lode to share them with the desktop client."
        )
    else
        h.ok(("backend protocol %d (running)"):format(daemon.proto() or 0))
    end

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

        -- Per-object introspection is UNEVEN across engines and the drawer offers a facet only where its
        -- driver claims the capability — so report which engines answer what, rather than leaving the user to
        -- wonder why `Indexes` is missing on one connection and present on another.
        local idx, ddl, neither = {}, {}, {}
        for _, m in ipairs(metas) do
            local c = m.caps or {}
            local name = m.display or m.kind
            if c.indexes then
                idx[#idx + 1] = name
            end
            if c.ddl then
                ddl[#ddl + 1] = name
            end
            if not c.indexes and not c.ddl then
                neither[#neither + 1] = name
            end
        end
        table.sort(idx)
        table.sort(ddl)
        table.sort(neither)
        h.info(("object indexes: %s"):format(#idx > 0 and table.concat(idx, ", ") or "none"))
        h.info(("object DDL: %s"):format(#ddl > 0 and table.concat(ddl, ", ") or "none"))
        if #neither > 0 then
            h.info(
                ("no per-object introspection (by design): %s"):format(table.concat(neither, ", "))
                    .. " — a KV store has no indexes and no schema to describe"
            )
        end

        -- Which engines can have a ROW written back from the grid. Same reasoning as the facets above: the
        -- editor is offered per-engine, so a user who finds `e` read-only on one connection and live on
        -- another should be able to read WHY here instead of guessing.
        -- The driver's OWN claim (`caps.edit`), not a list of driver names here: a driver claims it only if
        -- it binds every value and can roll back a write that turned out to match more than one row.
        local rw, ro = {}, {}
        for _, m in ipairs(metas) do
            local name = m.display or m.kind
            if (m.caps or {}).edit then
                rw[#rw + 1] = name
            else
                ro[#ro + 1] = ("%s (the driver does not claim it)"):format(name)
            end
        end
        table.sort(rw)
        table.sort(ro)
        h.info(("grid row editing: %s"):format(#rw > 0 and table.concat(rw, ", ") or "none"))
        for _, r in ipairs(ro) do
            h.info("grid row editing unavailable: " .. r)
        end
        h.info("a row is editable only from an object's Data facet, and only when the object has a key")
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
    -- WHERE the saved state lives is now a real question with two answers, and
    -- the user needs to know which one they got: in the engine (shared with any
    -- other lode client) or in the old Neovim-local file.
    local backend = store.backend()
    if backend == "engine" then
        h.ok("saved state: in the lode engine — shared with any other lode client")
        local eng = daemon.engine()
        if eng and eng.legacy then
            h.warn("…but the running backend reports no engine name; this should not happen")
        end
        local dir = config.data_dir or (vim.fn.stdpath("data") .. "/lvim-db")
        local marker = dir .. "/migrated-to-lode"
        if vim.uv.fs_stat(marker) then
            local lines = vim.fn.readfile(marker)
            h.info("migration: " .. (lines[1] or "done"))
        elseif vim.uv.fs_stat(dir .. "/lvim-db.db") then
            h.warn("an old local store is still at " .. dir .. "/lvim-db.db and has NOT been imported yet")
            h.info("it is imported automatically the first time the engine store is used, in this session")
        end
    elseif backend == "legacy" then
        h.warn("saved state: in the OLD Neovim-local file — not shared with other clients")
        h.info(
            "the running backend carries no store (protocol < 2, or none found), so lvim-db kept using its "
                .. "own database. Install lode and the data is imported on the next start."
        )
        local ok, s = pcall(require, "lvim-utils.store")
        if ok and s.health then
            s.health(h, false)
        end
    else
        h.info("saved state unavailable (saved connections / queries / history disabled)")
        h.info("needs either the lode engine (protocol ≥ 2) or sqlite.lua for the local fallback")
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
