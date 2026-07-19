-- lvim-db.ui.form: the add/edit connection form — ONE lvim-ui.tabs panel.
--
-- DriverMeta-driven: the driver list and each driver's typed params + accepted
-- auth methods come from the daemon (rpc.hello), so a new database type appears
-- in the form with no change here. After choosing the driver (a canonical
-- lvim-ui.select), the whole connection is entered in a SINGLE tabs panel with
-- typed rows across four tabs — Connection / Auth / Encryption / Tunnel — and the
-- result is assembled into a store template. Secrets stay as templates (e.g.
-- {{ env "PGPASSWORD" }}); encryption defaults to Prefer.
--
-- Each tab carries its OWN footer band (lvim-ui's per-tab `footer`): a TEST button
-- that dry-runs exactly the layer that tab configures (the file / the endpoint,
-- the credentials, the TLS posture, the SSH tunnel — all executed in the daemon,
-- which owns the network) and the SAVE button that writes the connection. The
-- footer is the ONLY submit path: a typed-row form has no whole-form <CR> (that
-- edits the focused row), so the buttons must live in the footer band — action
-- ROWS would be swallowed by the key-hint legend and never render.
--
---@module "lvim-db.ui.form"

local config = require("lvim-db.config")
local ui = require("lvim-ui")

local M = {}

--- Coerce a value to a display string, treating nil / JSON-null (vim.NIL) as "".
---@param v any
---@return string
local function str(v)
    if v == nil or v == vim.NIL then
        return ""
    end
    return tostring(v)
end

--- A plain string row.
---@param name string
---@param label string
---@param value any
---@return table
local function srow(name, label, value)
    return { type = "string", name = name, label = label, value = str(value) }
end

--- The SSH secret a stored tunnel spec carries, whichever auth method it used.
--- (Seeding this row empty would silently WIPE the secret on the next save.)
---@param tun table?
---@return string
local function tunnel_secret(tun)
    local a = tun and tun.auth or nil
    if not a then
        return ""
    end
    return str(a.passphrase ~= nil and a.passphrase ~= vim.NIL and a.passphrase or a.password)
end

--- Build and open the tabs panel for `meta`, seeded from an existing connection.
---@param meta table
---@param existing table?
local function open_tabs(meta, existing)
    local seed = existing and existing.spec or {}
    local sa, stls, stun = seed.auth or {}, seed.tls or {}, seed.tunnel
    local network = not (meta.kind == "sqlite" or meta.kind == "duckdb")

    -- Connection tab: name + each declared param.
    local conn_rows = { srow("__name", "Connection name *", existing and existing.name or "") }
    for _, p in ipairs(meta.params) do
        local def = (seed.params and seed.params[p.key]) or p.default or ""
        conn_rows[#conn_rows + 1] = srow("p_" .. p.key, p.label .. (p.required and " *" or ""), def)
    end

    -- Auth tab: a method select + every possible field (only the relevant ones
    -- are read back per the chosen method).
    local method_opts = {}
    for _, k in ipairs(meta.auth or { "none" }) do
        method_opts[#method_opts + 1] = k
    end
    local auth_rows = {
        {
            type = "select",
            name = "a_kind",
            label = "Method",
            value = sa.kind or method_opts[1],
            options = method_opts,
        },
        srow("a_user", "User", sa.user),
        srow("a_password", 'Password (literal, {{ env "VAR" }} or {{ vault "db/x" }})', sa.password),
        srow("a_cert", "Client certificate path (X.509 auth)", sa.cert),
        srow("a_key", "Client key path", sa.key),
        srow("a_provider", "Provider (aws / oauth / oidc)", sa.provider),
        srow("a_token", 'Token (literal, {{ cmd "…" }} or {{ vault "…" }})', sa.token),
    }

    local tabs = {
        { label = "Connection", rows = conn_rows, stage = "endpoint" },
        { label = "Auth", rows = auth_rows, stage = "auth" },
    }

    if network then
        tabs[#tabs + 1] = {
            label = "Encryption",
            stage = "tls",
            rows = {
                {
                    type = "select",
                    name = "t_mode",
                    label = "TLS mode",
                    value = stls.mode or "prefer",
                    options = { "prefer", "require", "verify_ca", "verify_full", "disable" },
                },
                srow("t_ca", "CA certificate path (verify modes)", stls.ca),
                srow("t_cc", "TLS client cert (mutual X.509)", stls.client_cert),
                srow("t_ck", "TLS client key", stls.client_key),
            },
        }
        tabs[#tabs + 1] = {
            label = "Tunnel",
            stage = "tunnel",
            rows = {
                {
                    type = "select",
                    name = "k_mode",
                    label = "SSH tunnel",
                    value = (stun and stun.auth and stun.auth.kind) or "none",
                    options = { "none", "key", "password" },
                },
                srow("k_host", "SSH host", stun and stun.host),
                srow("k_port", "SSH port", stun and stun.port and tostring(stun.port) or "22"),
                srow("k_user", "SSH user", stun and stun.user),
                srow("k_path", "SSH private key path (key auth)", stun and stun.auth and stun.auth.path),
                srow("k_secret", 'SSH passphrase/password ({{ env "VAR" }})', tunnel_secret(stun)),
            },
        }
    end

    --- The LIVE row values, keyed by row name. lvim-ui edits each typed row's
    --- `value` in place on the very tables built above, so this reads what the
    --- user has typed so far — across every tab, not just the focused one.
    ---@return table<string, any>
    local function values()
        local v = {}
        for _, t in ipairs(tabs) do
            for _, r in ipairs(t.rows) do
                if r.name then
                    v[r.name] = r.value
                end
            end
        end
        return v
    end

    --- Assemble the connection spec (the store template) from the live values.
    ---@return table
    local function build_spec()
        local result = values()

        local params = {}
        for _, p in ipairs(meta.params) do
            local v = result["p_" .. p.key]
            if v and v ~= "" then
                params[p.key] = v
            end
        end

        -- Auth: only the selected method's fields.
        local kind = result.a_kind or "none"
        local auth = { kind = kind }
        if kind == "password" then
            auth.user, auth.password = result.a_user or "", result.a_password or ""
        elseif kind == "client_cert" then
            auth.cert, auth.key, auth.user = result.a_cert or "", result.a_key or "", result.a_user or ""
        elseif kind == "provider" then
            auth.provider, auth.token, auth.user = result.a_provider or "", result.a_token or "", result.a_user or ""
        elseif kind == "kerberos" then
            auth.principal = (result.a_user and result.a_user ~= "") and result.a_user or nil
        end

        local spec = { params = params, auth = auth }

        if network then
            local tls = { mode = result.t_mode or "prefer" }
            if result.t_ca and result.t_ca ~= "" then
                tls.ca = result.t_ca
            end
            if result.t_cc and result.t_cc ~= "" then
                tls.client_cert = result.t_cc
            end
            if result.t_ck and result.t_ck ~= "" then
                tls.client_key = result.t_ck
            end
            spec.tls = tls

            local tmode = result.k_mode or "none"
            if tmode ~= "none" then
                local tauth = { kind = tmode }
                if tmode == "key" then
                    tauth.path = result.k_path or ""
                    tauth.passphrase = result.k_secret or ""
                else
                    tauth.password = result.k_secret or ""
                end
                spec.tunnel = {
                    host = result.k_host or "",
                    port = tonumber(result.k_port) or 22,
                    user = result.k_user or "",
                    auth = tauth,
                }
            end
        end

        return spec
    end

    --- Dry-run one layer of the spec in the daemon and report the verdict. The
    --- panel STAYS OPEN (the point is to fix what failed and retry), so the
    --- outcome is reported as a notification rather than by closing.
    ---@param stage "endpoint"|"tunnel"|"tls"|"auth"
    local function test(stage)
        local db = require("lvim-db")
        local spec = build_spec()
        spec.driver = meta.kind
        vim.notify(("lvim-db: testing %s…"):format(stage), vim.log.levels.INFO)
        db.test(spec, stage, function(detail, err, ms)
            if err then
                vim.notify(("lvim-db: %s test failed — %s"):format(stage, err), vim.log.levels.ERROR)
                return
            end
            vim.notify(("lvim-db: %s ok (%dms) — %s"):format(stage, ms or 0, detail), vim.log.levels.INFO)
        end)
    end

    --- Write the connection to the store and refresh the drawer. Returns false
    --- (and keeps the panel open) when the form is not yet submittable.
    ---@return boolean
    local function save()
        local name = vim.trim(str(values().__name))
        if name == "" then
            vim.notify("lvim-db: a connection name is required", vim.log.levels.WARN)
            return false
        end
        local spec = build_spec()
        local store = require("lvim-db").store
        -- A failed write must never masquerade as a save: the store degrades to
        -- `false` when sqlite is absent (or the insert is rejected), and claiming
        -- success there is how a connection silently vanishes.
        if not store.save_connection(name, meta.kind, spec) then
            vim.notify(
                ("lvim-db: could not save '%s' — the store is %s"):format(
                    name,
                    store.available() and "reachable but rejected the write" or "unavailable (sqlite.lua missing?)"
                ),
                vim.log.levels.ERROR
            )
            return false
        end
        -- An embedded file engine has no network link, so a TLS/tunnel verdict is meaningless — just confirm
        -- the save. Only the network engines get the encrypted / PLAINTEXT-warning distinction.
        local is_network = not (meta.kind == "sqlite" or meta.kind == "duckdb")
        if not is_network then
            vim.notify(("lvim-db: saved '%s'"):format(name), vim.log.levels.INFO)
        else
            local enc = (spec.tls and spec.tls.mode ~= "disable") or spec.tunnel ~= nil
            vim.notify(
                ("lvim-db: saved '%s' (%s)"):format(name, enc and "encrypted" or "PLAINTEXT — no TLS/tunnel"),
                enc and vim.log.levels.INFO or vim.log.levels.WARN
            )
        end
        local drawer = require("lvim-db.ui.drawer")
        if drawer.is_open() then
            drawer.open()
            drawer.refresh()
        end
        return true
    end

    ---@type table? the ui.tabs handle (captured below) — lets `store_in_keyring` repaint the rewritten field
    local handle

    --- Store the Auth secret (password, or the provider token) in the lvim-keyring wallet under
    --- `db/<connection-name>`, then rewrite that field to `{{ vault "db/<name>" }}` — so the secret lives
    --- ENCRYPTED in the wallet and the store keeps only the template. Requires lvim-keyring installed +
    --- unlocked; a name is required first (it is the vault key), and an already-templated field is left alone.
    local function store_in_keyring()
        local v = values()
        local name = vim.trim(str(v.__name))
        if name == "" then
            vim.notify("lvim-db: enter a connection name first (it is the wallet key)", vim.log.levels.WARN)
            return
        end
        local field = (v.a_kind == "provider") and "a_token" or "a_password"
        local secret = str(v[field])
        if secret == "" then
            vim.notify("lvim-db: no value in the Auth field to store", vim.log.levels.WARN)
            return
        end
        if secret:match("^%s*{{") then
            vim.notify("lvim-db: the field is already a {{ … }} template", vim.log.levels.INFO)
            return
        end
        local ok_kr, kr = pcall(require, "lvim-keyring")
        if not ok_kr then
            vim.notify("lvim-db: lvim-keyring is not installed", vim.log.levels.WARN)
            return
        end
        local vault_name = "db/" .. name
        kr.ensure_unlocked(function(unlocked, uerr)
            if not unlocked then
                if uerr and uerr ~= "" then
                    vim.notify("lvim-db: " .. uerr, vim.log.levels.WARN)
                end
                return
            end
            kr.set(vault_name, secret, nil, function(sok, serr)
                if not sok then
                    vim.notify("lvim-db: keyring — " .. (serr or "store failed"), vim.log.levels.WARN)
                    return
                end
                -- Rewrite the field to the vault template (in place) and repaint.
                local template = ('{{ vault "%s" }}'):format(vault_name)
                for _, t in ipairs(tabs) do
                    for _, r in ipairs(t.rows) do
                        if r.name == field then
                            r.value = template
                        end
                    end
                end
                if handle and handle.render then
                    handle.render()
                end
                vim.notify(("lvim-db: stored in the keyring — field set to %s"):format(template), vim.log.levels.INFO)
            end)
        end)
    end

    -- Per-tab footer band: TEST this tab's layer • SAVE • close (keys from
    -- config.keys.form; a `false` key drops that button). Every tab can save (the
    -- form is submittable from wherever the user finishes), while the test button
    -- is the one thing that differs per tab.
    --
    -- The defaults are PLAIN LETTERS, like every other lvim-tech panel footer (q
    -- close, a add, …): the panel is modal and its body binds only j/k, <CR>, ←/→
    -- and ⌫, so letters are free — and, unlike a chord such as <C-s>, a letter
    -- cannot be intercepted upstream (a multiplexer prefix, terminal flow control)
    -- and never reach Neovim.
    local fk = config.keys.form
    for _, t in ipairs(tabs) do
        -- A file-backed driver has no endpoint to dial — its Connection tab tests the FILE.
        local test_label = t.stage == "endpoint" and (network and "test endpoint" or "test file")
            or ("test " .. t.stage)
        local footer = {}
        if fk.test then
            footer[#footer + 1] = {
                key = fk.test,
                label = test_label,
                run = function()
                    test(t.stage)
                end,
            }
        end
        if fk.save then
            footer[#footer + 1] = {
                key = fk.save,
                label = "save",
                run = function(st)
                    if save() then
                        st.close()
                    end
                end,
            }
        end
        -- Auth tab only: offer to move the typed secret into the lvim-keyring wallet (when installed).
        if t.stage == "auth" and fk.keyring and pcall(require, "lvim-keyring") then
            footer[#footer + 1] = {
                key = fk.keyring,
                label = "store in keyring",
                run = function()
                    store_in_keyring()
                end,
            }
        end
        if fk.close then
            -- Label-only: the frame already closes on this key (a real mapping here
            -- would only shadow it).
            footer[#footer + 1] = { key = fk.close, label = "close", no_hotkey = true }
        end
        t.footer = footer
    end

    handle = ui.tabs({
        title = existing and ("Edit connection: " .. existing.name)
            or ("New connection: " .. (meta.display or meta.kind)),
        title_pos = "center",
        tabs = tabs,
        -- A multi-tab typed form is a centred MODAL (canon §2: float), not the
        -- short cmdline/area zone which would clip the rows.
        layout = "float",
    })
end

--- Open the connection form. With `edit_name`, seed from that saved connection.
---@param edit_name string?
function M.open(edit_name)
    local db = require("lvim-db")
    db.drivers(function(drivers, err)
        if err or #drivers == 0 then
            vim.notify("lvim-db: backend unavailable — cannot add a connection", vim.log.levels.ERROR)
            return
        end
        local existing = edit_name and db.store.get_connection(edit_name) or nil

        local items = {}
        local current
        for i, d in ipairs(drivers) do
            items[#items + 1] = { label = d.display or d.kind, meta = d }
            if existing and existing.driver == d.kind then
                current = i
            end
        end
        ui.select({
            title = edit_name and ("Edit connection: " .. edit_name) or "New connection — driver",
            items = items,
            current_item = current,
            callback = function(confirmed, idx)
                if not confirmed then
                    return
                end
                open_tabs(items[idx].meta, existing)
            end,
        })
    end)
end

return M
