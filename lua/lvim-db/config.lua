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
---@field drawer_width     integer                 Width (columns) of the connections drawer side panel
---@field confirm_destructive boolean              Confirm before running a statement matching `destructive_patterns`
---@field destructive_patterns string[]            Lua patterns (case-insensitive) that trigger the destructive guard
---@field data_dir         string?                 Base dir for lvim-db's own store (connections/history/queries); nil = stdpath("data")/lvim-db
---@field connect_timeout_ms integer               How long a connect / handshake may take before it is abandoned
---@field warn_on_missing  boolean                 Notify once (INFO) when the daemon binary is not built
---@field keys             LvimDbKeys              Every key lvim-db binds in its own UI surfaces

--- The keys lvim-db binds inside its OWN windows (the drawer, the result dock, the
--- connection form) — buffer-local to those panels, so they never touch the editor's
--- global maps. Each is a single `lhs`; set one to `false` to leave that key unbound.
---@class LvimDbKeys
---@field drawer LvimDbDrawerKeys
---@field result LvimDbResultKeys
---@field editor LvimDbEditorKeys
---@field form   LvimDbFormKeys

---@class LvimDbDrawerKeys
---@field help     string|false  Open the drawer's keymap cheatsheet
---@field expand   string|false  Expand the row / connect the connection
---@field collapse string|false  Collapse the row (visual only — does NOT drop the live link)
---@field disconnect string|false Close the live connection on the focused connection row (real disconnect)
---@field action   string|false  Default action (connect, expand, or preview a table's first rows)
---@field add      string|false  Open the connection form to ADD a connection
---@field edit     string|false  Open the connection form on the focused connection
---@field delete   string|false  Delete the focused saved connection (confirmed)
---@field refresh  string|false  Re-read the focused connection's schema
---@field close    string|false  Close the drawer

---@class LvimDbResultKeys
---@field help       string|false  Open the result dock's keymap cheatsheet
---@field result_tab string|false  Show the RESULT view (header button)
---@field log_tab    string|false  Show the CALL LOG view (header button)
---@field view_result string|false Switch to the result view (body key)
---@field view_log   string|false  Switch to the call-log view (body key)
---@field rerun      string|false  Call log: re-run the focused call
---@field cancel     string|false  Call log: cancel the focused running call
---@field next_page  string|false  Result: next page
---@field prev_page  string|false  Result: previous page
---@field yank       string|false  Result: yank the page as TSV
---@field export     string|false  Result: export the page
---@field close      string|false  Close the dock

--- The SQL editor is an EDITABLE buffer, so its keys are chords / leader sequences (never bare
--- letters, which would collide with typing). `<CR>` is the primary run gesture — NORMAL runs the
--- statement under the cursor, VISUAL runs the selection.
---@class LvimDbEditorKeys
---@field run_statement string|false  NORMAL: run the statement under the cursor
---@field run_selection string|false  VISUAL: run the selection (same key, visual mode)
---@field run_buffer    string|false  Run the whole buffer as one statement
---@field save_query    string|false  Save the buffer as a named query (under the active connection)
---@field help          string|false  Open the editor's keymap cheatsheet

---@class LvimDbFormKeys
---@field test  string|false  Test the ACTIVE tab's layer (endpoint / auth / tls / tunnel)
---@field save  string|false  Save the connection (from any tab) and close the form
---@field close string|false  Close the form without saving

---@type LvimDbConfig
return {
    -- Absolute path to the daemon binary. nil ⇒ probe (in order): $LVIM_DB_DAEMON,
    -- the plugin's own native/build/, then native/target/release/ (a local dev build).
    daemon_path = nil,
    -- Rows the result grid pulls per page. The daemon buffers the whole result and
    -- serves slices, so this only bounds how much Neovim holds/redraws at once.
    page_size = 200,
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
    -- lvim-db's OWN store (connections + query history + saved queries) — its own SQLite db, never a
    -- shared one. nil ⇒ stdpath("data")/lvim-db/.
    data_dir = nil,
    -- Abandon a connect/handshake that takes longer than this (a wrong host hangs otherwise).
    connect_timeout_ms = 15000,
    -- Emit a single INFO notification the first time an action needs the daemon but the
    -- binary is not built (so a user without a Rust toolchain knows to run native/build.sh).
    warn_on_missing = true,
    -- The keys lvim-db binds INSIDE its own panels (buffer-local — nothing global is
    -- touched). Any of them may be remapped, or set to `false` to leave it unbound.
    -- They are deliberately plain letters: a panel key must survive the terminal and the
    -- multiplexer, and a chord like <C-s> can be swallowed upstream (it is tmux's default
    -- prefix in many setups) and never reach Neovim at all.
    keys = {
        drawer = {
            help = "g?", -- the set-wide cheatsheet chord (the panel owns the `g` prefix — see lvim-ui)
            expand = "l",
            collapse = "h", -- VISUAL collapse only (keeps the live link); use `disconnect` to close it
            disconnect = "<C-q>", -- close the live connection on the focused connection row
            action = "<CR>",
            add = "a",
            edit = "e",
            delete = "x",
            refresh = "r",
            close = "q",
        },
        result = {
            help = "g?", -- the set-wide cheatsheet chord
            result_tab = "1",
            log_tab = "2",
            view_result = "r",
            view_log = "L",
            rerun = "<CR>",
            cancel = "x",
            next_page = "n",
            prev_page = "p",
            yank = "y",
            export = "e",
            close = "q",
        },
        -- the SQL editor (an editable `sql` buffer — chords / leader sequences, never bare letters)
        editor = {
            run_statement = "<CR>", -- NORMAL: run the statement under the cursor
            run_selection = "<CR>", -- VISUAL: run the selection (same key, visual mode)
            run_buffer = "<localleader>R", -- run the whole buffer as one statement
            save_query = "<localleader>w", -- save the buffer as a named query (active connection)
            help = "<localleader>?", -- the editor's keymap cheatsheet
        },
        form = {
            test = "t",
            save = "s",
            close = "q",
        },
    },
}
