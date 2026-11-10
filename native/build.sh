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
#
# PORTABLE BY DEFAULT ON LINUX, WHEN `zig` IS INSTALLED. A daemon built against
# this machine's glibc asks for the newest symbol versions it has (a rolling
# distribution: GLIBC_2.39 for pidfd_spawnp, GLIBC_2.38 for the C23 strtol family
# the C/C++ dependencies pick up from the new headers), and refuses to start on
# an older system — a server opened with `:connect ssh://`, which has no cargo to
# build its own. With zig as the C/C++ compiler and the linker, the whole daemon
# is built against glibc $LVIM_DB_GLIBC (2.28 by default: Debian 10, RHEL 8 and
# everything newer), and its C++ parts link zig's own libc++ statically. It goes
# to <target>/portable, so the ordinary build's cache is left alone.
#
#   LVIM_DB_PORTABLE=0 sh native/build.sh   # the plain build against this glibc
#   LVIM_DB_GLIBC=2.31 sh native/build.sh   # another baseline
#
# When the portable build fails, the plain one runs instead, and says so.
#
# The compile cache goes to $CARGO_TARGET_DIR when it is set (lvim-pack sets it to
# a cache directory outside the plugin), else to native/target.
set -e
cd "$(dirname "$0")"

GLIBC="${LVIM_DB_GLIBC:-2.28}"
TARGET="${CARGO_TARGET_DIR:-$PWD/target}"

# The cargo target triple and the zig target for this machine, or nothing when a
# portable build does not apply here.
portable_targets() {
    [ "${LVIM_DB_PORTABLE:-1}" = 1 ] || return 1
    command -v zig >/dev/null 2>&1 || return 1
    [ "$(uname -s)" = Linux ] || return 1
    case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) return 1 ;;
    esac
    triple="$arch-unknown-linux-gnu"
    ztarget="$arch-linux-gnu.$GLIBC"
}

# Small wrappers, because cargo and cc-rs take one executable, not a command line.
# cc-rs adds `--target=<rust triple>`, which zig does not know (it takes -target);
# Rust's std asks for `-lgcc_s`, which zig provides as libunwind.
write_wrappers() {
    wrap="$TARGET/zig-wrap"
    mkdir -p "$wrap"
    for tool in cc c++; do
        cat >"$wrap/$tool" <<EOF
#!/bin/sh
for a do
    shift
    case "\$a" in
    --target=*) ;;
    -lgcc_s) set -- "\$@" -lunwind ;;
    *) set -- "\$@" "\$a" ;;
    esac
done
exec zig $tool -target $ztarget "\$@"
EOF
        chmod +x "$wrap/$tool"
    done
    cat >"$wrap/ar" <<'EOF'
#!/bin/sh
exec zig ar "$@"
EOF
    chmod +x "$wrap/ar"
}

# Called as an `if` condition, where `set -e` does not apply: every failure returns explicitly, or the
# function would answer with the status of its last line and a failed build would look like a success.
build_portable() {
    write_wrappers || return 1
    up=$(echo "$triple" | tr 'a-z-' 'A-Z_')
    low=$(echo "$triple" | tr '-' '_')
    env \
        "CC_$low=$wrap/cc" \
        "CXX_$low=$wrap/c++" \
        "AR_$low=$wrap/ar" \
        "CXXSTDLIB_$low=c++" \
        "CARGO_TARGET_${up}_LINKER=$wrap/cc" \
        cargo build --release --target "$triple" --target-dir "$TARGET/portable" "$@" || return 1
    out="$TARGET/portable/$triple/release/lvim-db-daemon"
}

out=""
if portable_targets; then
    echo "building a portable daemon (glibc $GLIBC, zig $(zig version))"
    if ! build_portable "$@"; then
        echo "the portable build failed; building against this system's glibc instead" >&2
        out=""
    fi
fi
if [ -z "$out" ]; then
    cargo build --release --target-dir "$TARGET" "$@"
    out="$TARGET/release/lvim-db-daemon"
fi

mkdir -p build
cp -f "$out" build/lvim-db-daemon
echo "installed build/lvim-db-daemon"
