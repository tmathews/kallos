#!/usr/bin/env bash
# Install Kallos — the five binaries plus the data files that are still live.
# Nothing else.
#
# There is no asset tree under share/kallos: hajime and the apps bake their
# icons, fonts and shaders in with include_bytes!, and nothing in any tree
# resolves a path under share/kallos. The portal and systemd files are the only
# data that survives, and they live in kallosd/data/ because they are kallosd's
# contract; phylax's greetd and PAM files are the same story for the greeter.
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
. "$root/scripts/lib/out.sh"
. "$root/scripts/lib/detect.sh"
kosmos_src="${KWM_SRC:-$root/kosmos}"
kosmos_bin="$kosmos_src/builds/$cfg/src/kosmos"

# name -> built path. The Rust four come from their own crate target dirs.
crates=(kallosd kallosctl hajime phylax)

# APPS=1 adds the three opt-in apps, exactly as scripts/build.sh does — build
# and install must agree or the preflight below fails on binaries that were
# never asked for. They install as plain binaries and nothing else: their icons
# and shaders are include_bytes!'d, and none of them ships a .desktop file.
[ "${APPS:-0}" = 1 ] && crates+=(yggdrasil torrential renzoku) || true

# Pre-flight: everything must already be built.
missing=0
for c in "${crates[@]}"; do
	[ -x "$root/$c/target/$cfg/$c" ] || { err "missing $root/$c/target/$cfg/$c"; missing=1; }
done
[ -x "$kosmos_bin" ] || { err "missing $kosmos_bin (the compositor)"; missing=1; }
[ "$missing" -eq 0 ] || die "build first: scripts/build.sh $cfg"

bindir="$destdir$prefix/bin"
portaldir="$destdir$prefix/share/xdg-desktop-portal"
systemduserdir="$destdir$prefix/share/systemd/user"

hdr "binaries — $cfg -> ${destdir:+$destdir (staged) }$prefix"

# Binaries -> bin/. No rpath fixup: kosmos static-links its private deps and the
# Rust binaries link only system shared libs, all on the default loader path.
# kallosd resolves `kosmos` and `hajime` as SIBLINGS of itself (spawn::sibling),
# which is why all five land in one directory and `kallosd --wm --overlay`
# needs no paths.
install -d "$bindir"
install -m755 "$kosmos_bin" "$bindir/kosmos"
ok "bin/kosmos"
for c in "${crates[@]}"; do
	install -m755 "$root/$c/target/$cfg/$c" "$bindir/$c"
	ok "bin/$c"
done

# xdg-desktop-portal integration for kallosd's Settings backend. The
# `[preferred]` entry in kallos-portals.conf must stay the LIST `kallos;gtk;` —
# naming us alone strips every GNOME namespace from sandboxed apps.
install -d "$portaldir/portals"
install -m644 "$root/kallosd/data/portal/kallos.portal" "$portaldir/portals/kallos.portal"
install -m644 "$root/kallosd/data/portal/kallos-portals.conf" "$portaldir/kallos-portals.conf"
ok "share/xdg-desktop-portal/"

# systemd user unit: the session target kallosd starts once the compositor
# registers (activating graphical-session.target, so xdg-desktop-portal can
# run). $prefix/share is on systemd's user-unit search path for both prefixes.
# A running user manager needs `systemctl --user daemon-reload` to see a freshly
# installed unit; a fresh login picks it up automatically.
install -d "$systemduserdir"
install -m644 "$root/kallosd/data/systemd/kallos-session.target" "$systemduserdir/kallos-session.target"
ok "share/systemd/user/kallos-session.target"

# PAM service for `phylax --lock`. Under /etc, never $prefix: PAM reads only
# /etc/pam.d, so a user-prefix install cannot place it and says so — the
# locker then fails every password until it is installed by hand.
pamdir="$destdir/etc/pam.d"
if [ -d "$pamdir" ] && [ -w "$pamdir" ] || [ -n "$destdir" ]; then
	install -d "$pamdir"
	install -m644 "$root/phylax/data/pam/phylax" "$pamdir/phylax"
	ok "/etc/pam.d/phylax"
	# greetd's greeter-session service, which Arch's package does not ship.
	install -m644 "$root/phylax/data/pam/greetd-greeter" "$pamdir/greetd-greeter"
	ok "/etc/pam.d/greetd-greeter"
else
	warn "/etc/pam.d/phylax not installed (no write access) — phylax --lock needs it"
	note "sudo install -m644 $root/phylax/data/pam/phylax /etc/pam.d/phylax"
fi

# The login screen under greetd: the greeter session script beside the
# binaries (greetd's PATH finds it), and a config.toml only if greetd has
# none yet — once it exists it is the admin's. Nothing is enabled here:
# `systemctl enable greetd` takes the VT from getty and needs a re-login,
# which is scripts/session.sh's business, never an installer's. That script
# asks about both — the config and the enable — right after this one runs.
install -m755 "$root/phylax/data/greetd/phylax-greeter" "$bindir/phylax-greeter"
ok "bin/phylax-greeter"
# greetd's unit: a restart budget that outlasts a slow GPU probe, and no
# ordering guess. It assumes the machine's KMS driver is in the initramfs —
# see the drop-in's comment, which is the other half of that change.
# A systemd drop-in, so it goes in only where systemd is running — on a runit
# or OpenRC machine it is an inert file in a directory nothing reads. A staged
# install (DESTDIR) always gets it: the machine being packaged FOR is not this
# one, and leaving it out would ship an incomplete package.
greetd_dropin="$destdir/etc/systemd/system/greetd.service.d"
if [ -n "$destdir" ] || { have_systemd && [ -w /etc/systemd/system ]; }; then
	install -d "$greetd_dropin"
	install -m644 "$root/phylax/data/systemd/greetd-kallos.conf" "$greetd_dropin/kallos.conf"
	ok "/etc/systemd/system/greetd.service.d/kallos.conf"
	[ -n "$destdir" ] || note "systemctl daemon-reload to apply"
elif ! have_systemd; then
	skip "greetd systemd drop-in — this machine runs $(init_system)"
	note "it only sets greetd's restart budget and its ordering after seatd"
fi
# logind: end the session's processes with the session, so a compositor crash
# does not leave survivors holding the logind session open and the next login
# inheriting the dead session's user manager. See the drop-in's comment; the
# other half of that fix is kallosd's session activation.
# Same rule as the greetd drop-in above: it configures logind, so it goes in
# where logind is what is running. A staged install always gets it.
logind_dropin="$destdir/etc/systemd/logind.conf.d"
if [ -n "$destdir" ] || { have_systemd && [ -w /etc/systemd ]; }; then
	install -d "$logind_dropin"
	install -m644 "$root/kallosd/data/systemd/logind-kallos.conf" "$logind_dropin/kallos.conf"
	ok "/etc/systemd/logind.conf.d/kallos.conf"
	[ -n "$destdir" ] || note "systemctl restart systemd-logind to apply"
elif ! have_systemd; then
	skip "logind drop-in — this machine runs $(init_system)"
	note "it ends the session's processes with the session; find your init's equivalent"
else
	warn "/etc/systemd/logind.conf.d/kallos.conf not installed (no write access)"
	note "sudo install -Dm644 $root/kallosd/data/systemd/logind-kallos.conf /etc/systemd/logind.conf.d/kallos.conf"
fi
greetd_conf="$destdir/etc/greetd/config.toml"
if [ -e "$greetd_conf" ]; then
	# Arch's greetd package ships one (agreety, the text greeter), so on a
	# fresh install this is the line you will see. Overwriting it is a
	# question, not an install step — scripts/session.sh is where it gets
	# asked, and it backs the existing file up before answering yes.
	skip "/etc/greetd/config.toml exists — left alone (it is the admin's file)"
	if ! cmp -s "$root/phylax/data/greetd/config.toml" "$greetd_conf"; then
		note "it is not phylax's; './dev install' offers to replace it"
	fi
elif [ -d "$destdir/etc/greetd" ] && [ -w "$destdir/etc/greetd" ] || [ -n "$destdir" ]; then
	install -d "$destdir/etc/greetd"
	install -m644 "$root/phylax/data/greetd/config.toml" "$greetd_conf"
	ok "/etc/greetd/config.toml"
else
	warn "/etc/greetd/config.toml not installed (greetd absent, or no write access)"
fi

act "done — ensure $prefix/bin is on PATH"
