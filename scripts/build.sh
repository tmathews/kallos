#!/usr/bin/env bash
# Build the whole Kallos suite from the top of the tree.
#
# The suite is now four Rust binaries and one C one:
#
#   kallosd    the system daemon and session root   (Rust)
#   kallosctl  the control CLI                      (Rust)
#   hajime     the overlay                          (Rust)
#   phylax     the locker and greeter               (Rust)
#   kosmos     the compositor                       (C, ./kosmos)
#
# kosmos is the last C component and has its own tree here — ./kosmos, the
# compositor's own name. It is built by
# delegating to kosmos/scripts/build.sh, which owns the muon setup, the wlroots
# subproject and the vendored wlroots patches — there is no second copy of that
# knowledge here. KWM_SRC relocates it.
#
# Everything is built UNPRIVILEGED, before scripts/install.sh runs under the
# sudo a system prefix needs: cargo under sudo would leave root-owned artifacts
# in each crate's target/ and break the next unprivileged build. install.sh
# only copies.
#
# Usage: scripts/build.sh [debug|release]   (default: debug)
#   KWM_SRC=<path>   where the compositor tree lives (default: ./kosmos)
#   KWM=0            skip the compositor (Rust-only build)
#   APPS=1           also build yggdrasil, torrential and renzoku
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"

BT="${1:-debug}"
case "$BT" in
	release) CFG=release ;;
	debug) CFG=debug ;;
	*) err "usage: scripts/build.sh [debug|release]"; exit 2 ;;
esac

# The Rust crates, in dependency order. kallos-lib is not listed: it is a path
# dependency of all four and cargo builds it as needed.
crates=(kallosd kallosctl hajime phylax)

# The apps are opt-in, so the session-suite iteration loop — which is what
# test.sh and everyday work run — stays as short as it is. They are ordinary
# cargo binaries with their assets baked in via include_bytes!, so appending
# them here is all it takes; install.sh appends the same three.
[ "${APPS:-0}" = 1 ] && crates+=(yggdrasil torrential renzoku) || true

hdr "build — $CFG${APPS:+, with apps}"

# ---- kosmos (C, via its own muon build) --------------------------------------
# Builds the compositor and its eight synthetic test clients.
KWM_SRC="${KWM_SRC:-$root/kosmos}"
if [ "${KWM:-1}" = 0 ]; then
	skip "kosmos (KWM=0)"
elif [ ! -x "$KWM_SRC/scripts/build.sh" ]; then
	die "no compositor tree at $KWM_SRC — set KWM_SRC=<path>, or KWM=0 to skip"
else
	act "building kosmos ($CFG) in $KWM_SRC"
	"$KWM_SRC/scripts/build.sh" "$BT"
fi

# ---- the Rust suite -------------------------------------------------------
# cargo's profile directory names happen to match our config names, which is
# what lets install.sh use one $CFG for both halves of the tree.
command -v cargo >/dev/null || die "cargo not found"
for c in "${crates[@]}"; do
	[ -f "$root/$c/Cargo.toml" ] || die "missing $root/$c/Cargo.toml"
	act "building $c ($CFG)"
	( cd "$root/$c" && cargo build $([ "$CFG" = release ] && echo --release) )
done

sec "built"
[ "${KWM:-1}" = 0 ] || ok "$KWM_SRC/builds/$CFG/src/kosmos"
for c in "${crates[@]}"; do ok "$root/$c/target/$CFG/$c"; done
