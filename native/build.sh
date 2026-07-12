#!/bin/sh
# Build the lvim-db daemon into native/build/lvim-db-daemon — the path the Lua
# loader (lua/lvim-db/daemon.lua) probes first. Requires a Rust toolchain
# (cargo). Without the daemon the plugin still loads but every action reports
# that the backend must be built (see :checkhealth lvim-db).
#
#   sh native/build.sh
#
# By default it builds the standard driver set. To include an opt-in driver that
# needs a system library at runtime (Oracle Instant Client, the Firebird native
# client), pass its feature:
#
#   sh native/build.sh --features oracle
set -e
cd "$(dirname "$0")"

cargo build --release "$@"

mkdir -p build
cp -f target/release/lvim-db-daemon build/lvim-db-daemon
echo "installed build/lvim-db-daemon"
