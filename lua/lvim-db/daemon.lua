-- lvim-db.daemon: the engine process lifecycle + JSON-RPC client.
--
-- The database work happens in a SEPARATE process — the `lode` engine, binary
-- `loded` (https://github.com/lvim-tech/lode) — spawned once per Neovim and
-- spoken to over newline-delimited JSON on its stdin/stdout.
--
-- The engine used to live in this repository, under `native/`. It is its own
-- project now because it is no longer only ours to use: the same binary backs
-- the lode desktop GUI, and the saved connections / queries / history live
-- INSIDE it (see store.lua), so the two clients share one set. lvim-db is a
-- CLIENT of that engine and nothing more. A pre-lode `native/` build is still
-- accepted for the transition (see `candidate_paths`).
--
-- This module owns that process:
-- it probes the binary, spawns it, performs the `rpc.hello` handshake (recording
-- the protocol version + the driver set the backend was built with), correlates
-- responses to requests by id, and routes unsolicited notifications
-- (`query.state`) to registered handlers.
--
-- Out-of-process (not an FFI cdylib like lvim-fuzzy) because DB drivers need a
-- tokio runtime, pools, TLS and cancellation, and a driver/C-dep crash must take
-- down the engine — NOT the editor. If the binary is missing the plugin still
-- loads and every action degrades gracefully with one INFO notification (install
-- lode and run its `scripts/build`); there is no pure-Lua fallback because a
-- faked DB client would be a hack, not a fallback.
--
-- Public API:
--   • require("lvim-db.daemon").ensure(cb)          start + handshake, cb(ok, err)
--   • require("lvim-db.daemon").request(m, p, cb)   one RPC call, cb(result, err)
--   • require("lvim-db.daemon").on(method, handler) subscribe to a notification
--   • require("lvim-db.daemon").drivers()           the backend's DriverMeta list
--   • require("lvim-db.daemon").proto()             the negotiated protocol version
--   • require("lvim-db.daemon").engine()            which engine/version is running
--   • require("lvim-db.daemon").is_running()        whether the process is up
--   • require("lvim-db.daemon").dispatching()       whether a message is being handled now
--
---@module "lvim-db.daemon"

local uv = vim.uv
local config = require("lvim-db.config")

local M = {}

-- The minimum backend protocol this Lua understands (the lvim-fuzzy ABI-min
-- discipline applied to the RPC protocol): a daemon reporting `proto >=
-- PROTO_MIN` is accepted; additive protocol growth keeps older Lua working.
local PROTO_MIN = 1

---@type integer? the running job id (vim.fn.jobstart handle), or nil
local job
---@type boolean whether the rpc.hello handshake has completed
local ready = false
---@type integer? the negotiated protocol version
local proto
---@type LvimDbEngine? what the backend identified itself as at hello
local engine
---@type string? the binary path the running backend was spawned from
local engine_path
---@type table[] the DriverMeta list the backend reported at hello
local driver_metas = {}
---@type string the partial trailing line carried between stdout chunks
local stdout_tail = ""
---@type integer monotonically increasing request id
local id_seq = 0
---@type table<integer, fun(result: any, err: string?)> id → pending response callback
local pending = {}
---@type table<string, fun(params: any)> method → notification handler
local handlers = {}
---@type fun(ok: boolean, err: string?)[] callbacks waiting for the handshake
local ensure_waiters = {}
---@type boolean one-shot guard for the "daemon not built" notification
local warned_missing = false

-- ─── binary discovery ────────────────────────────────────────────────────────

--- Candidate paths for the engine binary, in probe order.
---
--- The backend is now a SEPARATE project — `lode` (https://github.com/lvim-tech/lode),
--- binary `loded` — shared with the lode desktop GUI, so the probe looks for an
--- INSTALLED engine first: an explicit config path, `$LODE_DAEMON`, then `loded`
--- on `$PATH`, then a checkout next to this plugin.
---
--- The two `native/` paths stay at the END of the list, for the transition: a
--- user who has built the old in-plugin daemon keeps working with it until they
--- install lode. They are the LAST resort rather than the first, so an installed
--- engine always wins over a stale bundled build.
---
--- `$LVIM_DB_DAEMON` is still honoured (it is in people's configs) but `$LODE_DAEMON`
--- is checked first, since it names the thing that actually exists now.
---@return string[]
local function candidate_paths()
    local paths = {}
    if config.daemon_path and config.daemon_path ~= "" then
        paths[#paths + 1] = config.daemon_path
    end
    for _, var in ipairs({ "LODE_DAEMON", "LVIM_DB_DAEMON" }) do
        local env = vim.env[var]
        if env and env ~= "" then
            paths[#paths + 1] = env
        end
    end
    -- An installed engine on $PATH — the normal case once lode is packaged.
    local on_path = vim.fn.exepath("loded")
    if on_path and on_path ~= "" then
        paths[#paths + 1] = on_path
    end
    -- this file is <root>/lua/lvim-db/daemon.lua → strip to the plugin root
    local src = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
    local root = src:gsub("/lua/lvim%-db/daemon%.lua$", "")
    -- A lode checkout beside this one, or beside the whole plugin tree — the two
    -- shapes a developer actually has (plugins/ next to lode/, or lua/ next to rust/).
    for _, rel in ipairs({
        "/../lode/build/loded",
        "/../lode/target/release/loded",
        "/../../rust/lode/build/loded",
        "/../../rust/lode/target/release/loded",
    }) do
        paths[#paths + 1] = vim.fs.normalize(root .. rel)
    end
    -- Transition only: the daemon that used to be bundled in this plugin.
    paths[#paths + 1] = root .. "/native/build/lvim-db-daemon"
    paths[#paths + 1] = root .. "/native/target/release/lvim-db-daemon"
    return paths
end

--- The first existing daemon binary path, or nil.
---@return string?
function M.binary_path()
    for _, p in ipairs(candidate_paths()) do
        if uv.fs_stat(p) then
            return p
        end
    end
    return nil
end

--- Notify once (INFO) that the daemon binary is not built, if configured.
local function warn_missing()
    if config.warn_on_missing and not warned_missing then
        warned_missing = true
        vim.schedule(function()
            vim.notify(
                "lvim-db: no database engine found — install lode (https://github.com/lvim-tech/lode): clone it "
                    .. "and run `scripts/build`, then put `loded` on $PATH or set `daemon_path`. Needs a Rust "
                    .. "toolchain.",
                vim.log.levels.INFO
            )
        end)
    end
end

-- ─── stdout parsing ──────────────────────────────────────────────────────────

---@type integer how deep we are inside a message handler (nested dispatch is possible: a
--- handler that sends a request whose answer is already in the same stdout burst)
local dispatch_depth = 0

--- Whether a daemon message is being handled RIGHT NOW.
---
--- The one fact a caller needs to know before it waits for an answer: while a
--- handler runs, nvim cannot deliver the next message on this channel, so an
--- answer sent from in here cannot arrive until we return. Code that waits
--- anyway does not wait — it hangs until its own timeout, every time. The store
--- asks this before it blocks (see `store.rpc`), and so must anything else that
--- means to.
---@return boolean
function M.dispatching()
    return dispatch_depth > 0
end

--- Handle one decoded message line from the daemon.
---@param msg table
local function on_message(msg)
    dispatch_depth = dispatch_depth + 1
    local ok, err = pcall(function()
        if msg.id ~= nil then
            local cb = pending[msg.id]
            pending[msg.id] = nil
            if cb then
                if msg.ok then
                    cb(msg.result, nil)
                else
                    cb(nil, msg.error or "unknown error")
                end
            end
        elseif msg.method then
            local h = handlers[msg.method]
            if h then
                pcall(h, msg.params)
            end
        end
    end)
    dispatch_depth = dispatch_depth - 1
    -- The depth must come back down even when a callback throws — otherwise one
    -- error would leave the client believing it is dispatching forever, and every
    -- synchronous store call after it would refuse.
    if not ok then
        error(err, 0)
    end
end

--- jobstart on_stdout: reassemble newline-delimited JSON across chunk boundaries.
--- vim's channel splits on "\n" but the final element of each burst may be a
--- partial line continued in the next burst, so we carry a tail.
---@param data string[]
local function on_stdout(data)
    if not data then
        return
    end
    -- The first element completes the carried tail; the last element is a new tail.
    data[1] = stdout_tail .. data[1]
    stdout_tail = table.remove(data)
    for _, line in ipairs(data) do
        line = vim.trim(line)
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" then
                on_message(msg)
            end
        end
    end
end

---@type fun(err: string?)[] callbacks run when the daemon tears down (e.g. to fail in-flight call watchers)
local teardown_hooks = {}

--- Register a callback invoked whenever the daemon tears down (crash / exit / failed start). Used by the
--- client layer to fail state watchers that `pending` (request callbacks) does not cover.
---@param cb fun(err: string?)
function M.on_teardown(cb)
    teardown_hooks[#teardown_hooks + 1] = cb
end

--- Tear down all state after the process exits or fails to start.
---@param err string?
local function teardown(err)
    ready = false
    job = nil
    engine = nil
    engine_path = nil
    stdout_tail = ""
    -- fail every in-flight request so callers never hang
    local dead = pending
    pending = {}
    for _, cb in pairs(dead) do
        pcall(cb, nil, err or "daemon stopped")
    end
    -- fail everyone waiting on the handshake
    local waiters = ensure_waiters
    ensure_waiters = {}
    for _, cb in ipairs(waiters) do
        pcall(cb, false, err or "daemon stopped")
    end
    -- let the client layer fail anything requests/waiters do not cover (e.g. query.state watchers)
    for _, hook in ipairs(teardown_hooks) do
        pcall(hook, err)
    end
end

-- ─── lifecycle ───────────────────────────────────────────────────────────────

--- Send a raw request object. Callers only reach this once the daemon is up, but the handle is
--- re-checked here rather than assumed: `stop()` clears it, and a queued send must not index nil.
---@param obj table
local function send(obj)
    if not job then
        return
    end
    vim.fn.chansend(job, vim.json.encode(obj) .. "\n")
end

--- Perform the rpc.hello handshake, then flush the ensure waiters.
local function handshake()
    id_seq = id_seq + 1
    local hid = id_seq
    pending[hid] = function(result, err)
        local waiters = ensure_waiters
        ensure_waiters = {}
        if err or type(result) ~= "table" then
            local msg = err or "handshake failed"
            teardown(msg)
            -- teardown flushes the (now-empty) module list, so the CAPTURED waiters must be answered here —
            -- else every ensure/request caller hangs forever on a bad/malformed hello.
            for _, cb in ipairs(waiters) do
                pcall(cb, false, msg)
            end
            return
        end
        proto = tonumber(result.proto)
        if not proto or proto < PROTO_MIN then
            local msg = ("backend protocol %s is too old (need ≥ %d)"):format(tostring(proto), PROTO_MIN)
            teardown(msg)
            for _, cb in ipairs(waiters) do
                pcall(cb, false, msg)
            end
            return
        end
        driver_metas = result.drivers or {}
        -- WHICH backend is this? lode reports `engine` + `version`; the old
        -- in-plugin daemon reported neither, so an absent `engine` means a
        -- legacy build and is recorded as such rather than guessed at.
        engine = {
            name = type(result.engine) == "string" and result.engine or "lvim-db-daemon (legacy)",
            version = type(result.version) == "string" and result.version or "unknown",
            proto = proto,
            path = engine_path or "?",
            legacy = type(result.engine) ~= "string",
        }
        ready = true
        for _, cb in ipairs(waiters) do
            pcall(cb, true, nil)
        end
    end
    send({ id = hid, method = "rpc.hello", params = vim.empty_dict() })
end

--- Ensure the daemon is spawned and handshaken. `cb(ok, err)` fires when ready
--- (or on failure). Safe to call repeatedly; concurrent callers coalesce.
---@param cb fun(ok: boolean, err: string?)
function M.ensure(cb)
    if ready and job then
        cb(true, nil)
        return
    end
    ensure_waiters[#ensure_waiters + 1] = cb
    if job then
        return -- a spawn is already in flight; this caller waits with the rest
    end

    local bin = M.binary_path()
    if not bin then
        warn_missing()
        local waiters = ensure_waiters
        ensure_waiters = {}
        for _, w in ipairs(waiters) do
            pcall(w, false, "daemon binary not found")
        end
        return
    end

    local ok, handle = pcall(vim.fn.jobstart, { bin }, {
        on_stdout = function(_, data, _)
            on_stdout(data)
        end,
        on_exit = function(_, _, _)
            teardown("daemon exited")
        end,
        stdout_buffered = false,
    })
    if not ok or type(handle) ~= "number" or handle <= 0 then
        job = nil
        local waiters = ensure_waiters
        ensure_waiters = {}
        for _, w in ipairs(waiters) do
            pcall(w, false, "failed to spawn daemon")
        end
        return
    end
    job = handle
    engine_path = bin
    handshake()
end

--- Issue one RPC request. `cb(result, err)` fires with the decoded result or an
--- error string. Ensures the daemon is up first (so callers need not).
---@param method string
---@param params table?
---@param cb fun(result: any, err: string?)
function M.request(method, params, cb)
    M.ensure(function(ok, err)
        if not ok then
            cb(nil, err)
            return
        end
        id_seq = id_seq + 1
        local rid = id_seq
        pending[rid] = cb
        send({ id = rid, method = method, params = params or vim.empty_dict() })
    end)
end

--- Subscribe to a notification method (e.g. "query.state"). One handler per method.
---@param method string
---@param handler fun(params: any)
function M.on(method, handler)
    handlers[method] = handler
end

--- The DriverMeta list the backend reported (empty until the handshake completes).
---@return table[]
function M.drivers()
    return driver_metas
end

--- The negotiated protocol version, or nil before the handshake.
---@return integer?
function M.proto()
    return proto
end

---@class LvimDbEngine
---@field name string     "lode", or "lvim-db-daemon (legacy)" for a pre-lode backend
---@field version string  the engine's own version, "unknown" on a legacy backend
---@field proto integer   the protocol version it reported
---@field path string     the binary it was spawned from
---@field legacy boolean  true when the backend did not identify itself (pre-lode)

--- Which backend is actually running: name, version, protocol and the binary it
--- came from. nil before the handshake completes.
---
--- The plugin can be talking to EITHER the lode engine or the daemon that used
--- to ship inside it, and the two are not interchangeable (lode carries the
--- saved state; the old one does not), so "which one am I on" has to be
--- answerable — `:checkhealth lvim-db` prints it.
---@return LvimDbEngine?
function M.engine()
    return engine
end

--- Whether the daemon process is currently running and handshaken.
---@return boolean
function M.is_running()
    return ready and job ~= nil
end

--- Stop the daemon (closes its stdin → it exits). Idempotent.
function M.stop()
    if job then
        pcall(vim.fn.chanclose, job, "stdin")
        pcall(vim.fn.jobstop, job)
    end
    teardown("daemon stopped")
end

return M
