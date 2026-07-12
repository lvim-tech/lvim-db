-- lvim-db.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every require("lvim-db.config") reader sees the
-- effective values. The daemon path and driver set are discovered at runtime
-- (see daemon.lua / the backend's rpc.hello), so there is nothing DB-specific to
-- configure here — only how lvim-db spawns the backend and presents its UI.
--
---@module "lvim-db.config"

---@class LvimDbConfig
---@field daemon_path      string?                 Explicit path to the lvim-db-daemon binary; nil = auto-probe
---@field page_size        integer                 Rows fetched per result page (the pagination band's page)
---@field layout           "area"|"float"|"bottom" Default window layout for lvim-db's UI surfaces
---@field drawer_width     integer                 Width (columns) of the connections drawer side panel
---@field confirm_destructive boolean              Confirm before running a statement matching `destructive_patterns`
---@field destructive_patterns string[]            Lua patterns (case-insensitive) that trigger the destructive guard
---@field notes_dir        string?                 Base dir for per-connection scratch notes; nil = stdpath("state")/lvim-db/notes
---@field data_dir         string?                 Base dir for lvim-db's own store (connections/history); nil = stdpath("data")/lvim-db
---@field connect_timeout_ms integer               How long a connect / handshake may take before it is abandoned
---@field warn_on_missing  boolean                 Notify once (INFO) when the daemon binary is not built

---@type LvimDbConfig
return {
    -- Absolute path to the daemon binary. nil ⇒ probe (in order): $LVIM_DB_DAEMON,
    -- the plugin's own native/build/, then native/target/release/ (a local dev build).
    daemon_path = nil,
    -- Rows the result grid pulls per page. The daemon buffers the whole result and
    -- serves slices, so this only bounds how much Neovim holds/redraws at once.
    page_size = 200,
    -- Default layout token for lvim-db's windows; a command may override per-invocation.
    layout = "area",
    -- Width (columns) of the connections drawer side panel.
    drawer_width = 36,
    -- Guard destructive statements: prompt via lvim-ui.confirm before executing one
    -- that matches a pattern below (dbee has no such guard — this is lvim-db's safety add).
    confirm_destructive = true,
    -- Case-insensitive Lua patterns marking a statement as ALWAYS destructive
    -- (matched against the lowercased statement). DROP / TRUNCATE by default; a
    -- DELETE / UPDATE without a WHERE clause is detected separately (see
    -- `require("lvim-db").is_destructive`) because "no WHERE" needs a negative check.
    destructive_patterns = {
        "^%s*drop%s",
        "^%s*truncate%s",
    },
    -- Per-connection scratch notes live as REAL files here (opened as normal buffers).
    -- nil ⇒ stdpath("state")/lvim-db/notes/<conn>/.
    notes_dir = nil,
    -- lvim-db's OWN store (connections + query history) — its own SQLite db, never a
    -- shared one. nil ⇒ stdpath("data")/lvim-db/.
    data_dir = nil,
    -- Abandon a connect/handshake that takes longer than this (a wrong host hangs otherwise).
    connect_timeout_ms = 15000,
    -- Emit a single INFO notification the first time an action needs the daemon but the
    -- binary is not built (so a user without a Rust toolchain knows to run native/build.sh).
    warn_on_missing = true,
}
