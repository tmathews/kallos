#!/usr/bin/env bash
# Install Kallos — the four binaries plus the two data files that are still
# live. Nothing else.
#
# This is the Rust cutover: the session runs `kallosd` and the Rust
# `kallosctl`. The C `kdaemon` and the C `kallosctl` are NOT installed, and
# both binaries being called `kallosctl` is exactly why — they collide in
# $PREFIX/bin. They keep building in kstart/ for side-by-side comparison; see
# scripts/verify.sh.
#
# What is deliberately NOT installed any more, vs kstart/scripts/install.sh:
#   share/kallos/data/  — the deleted C overlay's asset tree (SVG icons, sfx/).
#     hajime bakes its own assets in, and nothing in any tree resolves a path
#     under share/kallos any more (grep says so). Only the portal and systemd
#     files survived; they live in kallosd/data/ now, since they are kallosd's
#     contract, and are installed below.
#
# This script only COPIES. Everything it installs is built by
# scripts/build.sh beforehand — deliberately, so cargo never runs under the
# sudo a system prefix needs.
#
# Usage:
#   scripts/install.sh [debug|release]      # default: release
#   PREFIX=$HOME/.local scripts/install.sh  # user prefix (no sudo)
#   DESTDIR=/tmp/stage scripts/install.sh   # staged install (packaging)
#   KWM_SRC=<path>                          # where the compositor tree lives
#   APPS=1                                  # also install yggdrasil/torrential/renzoku
# System prefixes (the default /usr/local) need write access — run under sudo.
set -euo pipefail

cfg="${1:-release}"
prefix="${PREFIX:-/usr/local}"
destdir="${DESTDIR:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
kwm_src="${KWM_SRC:-$root/kosmos}"
kwm_bin="$kwm_src/builds/$cfg/src/kwm"

# name -> built path. The Rust three come from their own crate target dirs.
crates=(kallosd kallosctl hajime)

# APPS=1 adds the three opt-in apps, exactly as scripts/build.sh does — build
# and install must agree or the preflight below fails on binaries that were
# never asked for. They install as plain binaries and nothing else: their icons
# and shaders are include_bytes!'d, and none of them ships a .desktop file.
[ "${APPS:-0}" = 1 ] && crates+=(yggdrasil torrential renzoku) || true

# Pre-flight: everything must already be built.
missing=0
for c in "${crates[@]}"; do
	[ -x "$root/$c/target/$cfg/$c" ] || { echo "!! missing $root/$c/target/$cfg/$c" >&2; missing=1; }
done
[ -x "$kwm_bin" ] || { echo "!! missing $kwm_bin (the compositor)" >&2; missing=1; }
[ "$missing" -eq 0 ] || { echo "!! build first: scripts/build.sh $cfg" >&2; exit 1; }

bindir="$destdir$prefix/bin"
portaldir="$destdir$prefix/share/xdg-desktop-portal"
systemduserdir="$destdir$prefix/share/systemd/user"

echo ">> installing Kallos ($cfg) -> ${destdir:+$destdir:}$prefix"

# Binaries -> bin/. No rpath fixup: kwm static-links its private deps and the
# Rust binaries link only system shared libs, all on the default loader path.
# kallosd resolves `kwm` and `hajime` as SIBLINGS of itself (spawn::sibling),
# which is why all four land in one directory and `kallosd --wm --overlay`
# needs no paths.
install -d "$bindir"
install -m755 "$kwm_bin" "$bindir/kwm"
echo "   bin/kwm"
for c in "${crates[@]}"; do
	install -m755 "$root/$c/target/$cfg/$c" "$bindir/$c"
	echo "   bin/$c"
done

# xdg-desktop-portal integration for kallosd's Settings backend. The
# `[preferred]` entry in kallos-portals.conf must stay the LIST `kallos;gtk;` —
# naming us alone strips every GNOME namespace from sandboxed apps.
install -d "$portaldir/portals"
install -m644 "$root/kallosd/data/portal/kallos.portal" "$portaldir/portals/kallos.portal"
install -m644 "$root/kallosd/data/portal/kallos-portals.conf" "$portaldir/kallos-portals.conf"
echo "   share/xdg-desktop-portal/"

# systemd user unit: the session target kallosd starts once the compositor
# registers (activating graphical-session.target, so xdg-desktop-portal can
# run). $prefix/share is on systemd's user-unit search path for both prefixes.
# A running user manager needs `systemctl --user daemon-reload` to see a freshly
# installed unit; a fresh login picks it up automatically.
install -d "$systemduserdir"
install -m644 "$root/kallosd/data/systemd/kallos-session.target" "$systemduserdir/kallos-session.target"
echo "   share/systemd/user/kallos-session.target"

# The cutover leaves the pre-Rust binaries behind, and a stale `kdaemon` on
# PATH is the one thing that can quietly re-run the old session. Point at them
# rather than deleting: what to remove is the user's call.
stale=()
for old in kdaemon kstart; do
	[ -e "$bindir/$old" ] && stale+=("$old")
done
if [ ${#stale[@]} -gt 0 ]; then
	echo ">> note: pre-cutover binaries still in $prefix/bin: ${stale[*]}"
	echo "   they are no longer installed by this script; remove when you're done with them."
fi

echo ">> done — ensure $prefix/bin is on PATH"
