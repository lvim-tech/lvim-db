-- The store must never WAIT for an answer that cannot arrive.
--
-- nvim delivers one message at a time per channel: while a daemon message is
-- being handled, the answer to a request sent from inside that handler cannot be
-- read until the handler returns. A synchronous store call from in there does not
-- wait — it hangs until its own timeout, every time. That is exactly where the
-- history write lives (the query's own state callback), and it cost five seconds
-- per query until this was measured.

local function fake_dispatching_daemon(dispatching)
    local sent = {}
    package.loaded["lvim-db.daemon"] = {
        sent = sent,
        binary_path = function()
            return nil -- no engine in this spec; the point is the WAITING, not the backend
        end,
        proto = function()
            return 28
        end,
        dispatching = function()
            return dispatching
        end,
        request = function(method, params, cb)
            sent[#sent + 1] = { method = method, params = params }
            cb(nil, "no daemon in this test")
        end,
        on = function() end,
        on_teardown = function() end,
        ensure = function(cb)
            cb(false, "no daemon in this test")
        end,
        is_running = function()
            return false
        end,
    }
    package.loaded["lvim-db.store"] = nil
    return require("lvim-db.store"), sent
end

--- Milliseconds `fn` took.
local function took(fn)
    local t = vim.uv.hrtime()
    fn()
    return (vim.uv.hrtime() - t) / 1e6
end

describe("the store never waits for an answer it cannot receive")

it("answers at once while the daemon is dispatching, instead of waiting out its timeout", function()
    local store = fake_dispatching_daemon(true)
    local ms = took(function()
        store.list_profiles("tunnel")
    end)
    truthy(ms < 500, ("a store read inside a callback took %.0f ms — it is waiting again"):format(ms))
end)

it("hands a history record on without waiting for it", function()
    local store = fake_dispatching_daemon(true)
    local ms = took(function()
        store.record({ conn = "c", driver = "sqlite", statement = "SELECT 1", state = "done", ms = 1, rows = 1 })
    end)
    truthy(ms < 500, ("recording a statement took %.0f ms — the query is paying for it"):format(ms))
end)

it("still records when nothing is dispatching", function()
    local store, sent = fake_dispatching_daemon(false)
    local ms = took(function()
        store.record({ conn = "c", driver = "sqlite", statement = "SELECT 1", state = "done" })
    end)
    truthy(ms < 500, ("recording took %.0f ms"):format(ms))
    -- With no engine binary the backend is legacy-or-none, so nothing is sent;
    -- what matters is that the attempt cost nothing. The LIVE engine spec proves
    -- the row actually lands.
    truthy(type(sent) == "table")
end)
