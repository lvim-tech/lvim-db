-- lvim-db test runner. No framework: a dependency for a handful of files of
-- asserts is a worse trade than twenty lines of harness.
--
--     nvim --headless -u NONE -l tests/run.lua
--
-- or, from the plugin root, `make test`. Point $LODE_DAEMON at a built `loded`
-- and the engine specs run against it as well; without it they skip.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = table.concat({
    root .. "/lua/?.lua",
    root .. "/lua/?/init.lua",
    package.path,
}, ";")

-- The views are drawn by lvim-ui and lean on lvim-utils, so the specs that
-- render need them on the runtimepath: an explicit $LVIM_UI_DIR / $LVIM_UTILS_DIR
-- first, else the sibling checkout a developer actually has.
for _, dep in ipairs({ { "LVIM_UI_DIR", "lvim-ui" }, { "LVIM_UTILS_DIR", "lvim-utils" } }) do
    local dir = vim.env[dep[1]]
    if not dir or dir == "" then
        dir = vim.fs.normalize(root .. "/../" .. dep[2])
    end
    if vim.uv.fs_stat(dir) then
        vim.opt.runtimepath:prepend(dir)
        package.path = table.concat({
            dir .. "/lua/?.lua",
            dir .. "/lua/?/init.lua",
            package.path,
        }, ";")
    end
end

local passed, failed, skipped = 0, 0, 0
local current = "?"

--- Name the group the next tests belong to.
---@param name string
function _G.describe(name)
    current = name
    io.write("\n", name, "\n")
end

--- Run one test; a failure is reported and the run continues.
---@param name string
---@param fn fun()
function _G.it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  ok   ", name, "\n")
    else
        failed = failed + 1
        io.write("  FAIL ", current, " / ", name, "\n       ", (tostring(err):gsub("\n", "\n       ")), "\n")
    end
end

--- Say that a test could not be run here, and why. Counted apart from a pass:
--- "the engine is not built" must never read as "the engine works".
---@param name string
---@param why string
function _G.skip(name, why)
    skipped = skipped + 1
    io.write("  skip ", name, " — ", why, "\n")
end

--- Assert deep equality, showing both sides when they differ.
---@param expected any
---@param got any
---@param what? string
function _G.eq(expected, got, what)
    if not vim.deep_equal(expected, got) then
        error(
            ("%sexpected %s\n     got %s"):format(
                what and (what .. ": ") or "",
                vim.inspect(expected),
                vim.inspect(got)
            ),
            2
        )
    end
end

--- Assert truthiness.
---@param value any
---@param what? string
function _G.truthy(value, what)
    if not value then
        error((what or "expected a truthy value") .. (", got " .. vim.inspect(value)), 2)
    end
end

--- Pretend the handshake happened: `proto.lua` reads the engine through
--- `daemon.proto()` / `daemon.drivers()`, so a spec about TEMPLATES can hand it a
--- protocol number and a driver list without a process anywhere.
---@param proto integer?
---@param drivers table[]?
function _G.fake_daemon(proto, drivers)
    package.loaded["lvim-db.daemon"] = {
        proto = function()
            return proto
        end,
        drivers = function()
            return drivers or {}
        end,
        request = function(_, _, cb)
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
    package.loaded["lvim-db.proto"] = nil
    return require("lvim-db.proto")
end

for _, spec in ipairs({ "load_spec.lua", "proto_spec.lua", "rules_spec.lua", "ddl_spec.lua", "keys_spec.lua", "engine_spec.lua" }) do
    dofile(root .. "/tests/" .. spec)
end

io.write(("\n%d passed, %d failed, %d skipped\n"):format(passed, failed, skipped))
os.exit(failed > 0 and 1 or 0)
