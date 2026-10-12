-- The connection form may only change what it SHOWS.
--
-- A connection carries fields this form has no row for — the write `policy`, the
-- `hooks`, a proxy, and a tunnel PROFILE (a saved SSH tunnel the engine holds by
-- name, which several connections share). A spec rebuilt from the visible rows
-- alone deleted every one of them: saving a tunnelled connection from here left
-- it dialling 127.0.0.1 locally, where nothing answers.

local form = require("lvim-db.ui.form")

local META = {
    kind = "redis",
    params = {
        { key = "host", label = "Host" },
        { key = "port", label = "Port" },
    },
}

--- The row values a person would have in front of them for `seed`.
local function values(over)
    return vim.tbl_extend("force", {
        p_host = "127.0.0.1",
        p_port = "6380",
        a_kind = "password",
        a_user = "someone",
        a_password = "{{ vault \"db/redis\" }}",
        t_mode = "verify_ca",
        t_ca = "/home/x/.config/ca.pem",
        k_mode = "profile",
        k_profile = "neterra",
    }, over or {})
end

local SEED = {
    params = { host = "127.0.0.1", port = "6380" },
    auth = { kind = "password", user = "someone", password = "{{ vault \"db/redis\" }}" },
    tls = { mode = "verify_ca", ca = "/home/x/.config/ca.pem" },
    tunnel_profile = "neterra",
    policy = "confirm",
    hooks = {},
}

describe("the connection form keeps what it does not show")

it("carries the policy and the hooks through an edit", function()
    local spec = form.spec_of(META, true, SEED, values())
    eq("confirm", spec.policy, "the write policy")
    eq({}, spec.hooks, "the hooks")
end)

it("keeps the saved tunnel profile", function()
    local spec = form.spec_of(META, true, SEED, values())
    eq("neterra", spec.tunnel_profile)
    truthy(spec.tunnel == nil, "a profile and an inline tunnel are never both set")
end)

it("replaces the profile when an inline tunnel is chosen instead", function()
    local spec = form.spec_of(
        META,
        true,
        SEED,
        values({ k_mode = "key", k_host = "h", k_user = "u", k_port = "22", k_path = "/k" })
    )
    truthy(spec.tunnel_profile == nil, "the profile is gone")
    eq("h", spec.tunnel.host)
    eq("key", spec.tunnel.auth.kind)
end)

it("stores no profile when there is none to choose", function()
    local spec = form.spec_of(META, true, SEED, values({ k_profile = "(no saved tunnels)" }))
    truthy(spec.tunnel_profile == nil, "the placeholder is not the name of a profile")
end)

it("drops the tunnel entirely when the answer is none", function()
    local spec = form.spec_of(META, true, SEED, values({ k_mode = "none" }))
    truthy(spec.tunnel_profile == nil and spec.tunnel == nil)
end)

it("still writes what the form DOES own", function()
    local spec = form.spec_of(META, true, SEED, values({ p_port = "6381", t_mode = "require", t_ca = "" }))
    eq("6381", spec.params.port)
    eq("require", spec.tls.mode)
    truthy(spec.tls.ca == nil, "an emptied CA box clears the CA rather than keeping the seed's")
end)

it("a file engine gets no TLS and no tunnel at all", function()
    local spec = form.spec_of({ kind = "sqlite", params = { { key = "file" } } }, false, nil, { p_file = "/tmp/a.db" })
    truthy(spec.tls == nil and spec.tunnel == nil, "a file has no network to secure")
    eq("/tmp/a.db", spec.params.file)
end)
