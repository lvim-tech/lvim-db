-- lvim-db.ui.form: the add/edit connection form — ONE lvim-ui.tabs panel.
--
-- DriverMeta-driven: the driver list and each driver's typed params + accepted
-- auth methods come from the daemon (rpc.hello), so a new database type appears
-- in the form with no change here. After choosing the driver (a canonical
-- lvim-ui.select), the whole connection is entered in a SINGLE tabs panel with
-- typed rows across four tabs — Connection / Auth / Encryption / Tunnel — and the
-- result (a name→value map) is assembled into a store template. Secrets stay as
-- templates (e.g. {{ env "PGPASSWORD" }}); encryption defaults to Prefer.
--
---@module "lvim-db.ui.form"

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
        srow("a_password", 'Password (literal or {{ env "VAR" }})', sa.password),
        srow("a_cert", "Client certificate path (X.509 auth)", sa.cert),
        srow("a_key", "Client key path", sa.key),
        srow("a_provider", "Provider (aws / oauth / oidc)", sa.provider),
        srow("a_token", 'Token (literal or {{ cmd "…" }})', sa.token),
    }

    local tabs = {
        { label = "Connection", rows = conn_rows },
        { label = "Auth", rows = auth_rows },
    }

    -- A typed-row form has no whole-form <CR> (that edits the focused row), so
    -- each tab ends with a SAVE action row: <CR> on it closes the form with
    -- confirmed=true, and lvim-ui collects every tab's values into the callback.
    local save_seq = 0
    local function save_row()
        save_seq = save_seq + 1
        return {
            type = "action",
            name = "__save_" .. save_seq,
            icon = "",
            label = "Save connection",
            run = function(_, close)
                close(true)
            end,
        }
    end

    if network then
        tabs[#tabs + 1] = {
            label = "Encryption",
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
            rows = {
                {
                    type = "select",
                    name = "k_mode",
                    label = "SSH tunnel",
                    value = (stun and stun.auth and stun.auth.kind) or "none",
                    options = { "none", "key", "password" },
                },
                srow("k_host", "SSH host", stun and stun.host),
                srow("k_port", "SSH port", stun and tostring(stun.port) or "22"),
                srow("k_user", "SSH user", stun and stun.user),
                srow("k_path", "SSH private key path (key auth)", stun and stun.auth and stun.auth.path),
                srow("k_secret", 'SSH passphrase/password ({{ env "VAR" }})', ""),
            },
        }
    end

    -- Append the Save action row to every tab so the form is submittable from any.
    for _, t in ipairs(tabs) do
        t.rows[#t.rows + 1] = { type = "spacer" }
        t.rows[#t.rows + 1] = save_row()
    end

    ui.tabs({
        title = existing and ("Edit connection: " .. existing.name)
            or ("New connection: " .. (meta.display or meta.kind)),
        title_pos = "center",
        tabs = tabs,
        -- A multi-tab typed form is a centred MODAL (canon §2: float), not the
        -- short cmdline/area zone which would clip the rows.
        layout = "float",
        footer_hints = true,
        callback = function(confirmed, result)
            if not confirmed or type(result) ~= "table" then
                return
            end
            local name = vim.trim(result.__name or "")
            if name == "" then
                vim.notify("lvim-db: a connection name is required", vim.log.levels.WARN)
                return
            end

            -- Params.
            local params = {}
            for _, p in ipairs(meta.params) do
                local v = result["p_" .. p.key]
                if v and v ~= "" then
                    params[p.key] = v
                end
            end

            -- Auth (only the selected method's fields).
            local kind = result.a_kind or "none"
            local auth = { kind = kind }
            if kind == "password" then
                auth.user, auth.password = result.a_user or "", result.a_password or ""
            elseif kind == "client_cert" then
                auth.cert, auth.key, auth.user = result.a_cert or "", result.a_key or "", result.a_user or ""
            elseif kind == "provider" then
                auth.provider, auth.token, auth.user =
                    result.a_provider or "", result.a_token or "", result.a_user or ""
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

            require("lvim-db").store.save_connection(name, meta.kind, spec)
            local enc = (spec.tls and spec.tls.mode ~= "disable") or spec.tunnel ~= nil
            vim.notify(
                ("lvim-db: saved '%s' (%s)"):format(name, enc and "encrypted" or "PLAINTEXT — no TLS/tunnel"),
                enc and vim.log.levels.INFO or vim.log.levels.WARN
            )
            local drawer = require("lvim-db.ui.drawer")
            if drawer.is_open() then
                drawer.open()
                drawer.refresh()
            end
        end,
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
