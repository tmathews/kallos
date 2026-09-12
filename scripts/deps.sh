#!/usr/bin/env bash
# The Kallos dependency checklist for Arch, and the one place it is written down.
#
# This supersedes kosmos/docs/building.md's "Quick install" block, which is
# stale: it still lists `wireless_tools` for a cc.find_library('iw') that no
# longer exists in kosmos/meson.build, plus cairo, openssl, libnghttp2, libpulse
# and dbus as *compositor* build deps. libpulse belongs to kallosd and openssl
# to torrential; the rest belong to nothing here any more. The lists below were
# read off kosmos/meson.build, kosmos/src/meson.build, the wlroots 0.18.2
# subproject wrap and each crate's Cargo.lock.
#
# Arch is the paved road, not a requirement. The lists below are pacman package
# names and there is no attempt to translate them — a mapping to apt/dnf/apk
# names is a thing that rots silently every time one of those distros renames or
# splits a package, and it would be maintained without any CI on those distros
# to catch it. So on anything else this script REPORTS rather than exits: it
# names the package manager it found, prints what Kallos needs, and hands over.
# The build is the real test, and it fails with a pkg-config error that names
# the missing module far more precisely than any list here could.
#
# Three things this script deliberately does NOT install:
#
#   * a Vulkan ICD (vulkan-radeon / vulkan-intel / nvidia-utils) — which one is
#     a property of the hardware, not of Kallos.
#   * xwayland-satellite — AUR, and pacman can't reach it.
#   * seatd's enablement and the seat/input group memberships — they need a
#     re-login to take effect, so a script that "fixed" them would be lying
#     about the state of the running session. Reported as a checklist instead.
#
# muon is not packaged on Arch at all; it is built from source. That knowledge
# lives in kosmos/scripts/muon-bootstrap.sh and is delegated to, never copied.
#
# Usage: scripts/deps.sh [check|install]   (default: install)
#   YES=1     don't prompt; assume yes
#   NO_MUON=1 skip the muon bootstrap
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"
. "$root/scripts/lib/detect.sh"

mode="${1:-install}"
case "$mode" in
	check|install) ;;
	*) err "usage: scripts/deps.sh [check|install]"; exit 2 ;;
esac

# ---- the lists ------------------------------------------------------------
# Split by who needs them, so that when a component moves or dies it is obvious
# which packages leave with it.

# Toolchain. clang >= 19 for #embed (kcore/version.c); the tree targets 22.
build=(base-devel clang git pkgconf glslang rust)

# kosmos and the wlroots 0.18.2 it builds as a subproject. libseat comes from
# seatd, libudev from systemd-libs, and gbm/EGL/GLESv2 from mesa — those three
# are pkg-config module names rather than package names, hence the mapping.
# libdisplay-info and hwdata are wlroots' own hard deps; libliftoff and lcms2
# are its optional ones and live in `optional` below.
kosmos=(wayland wayland-protocols libxkbcommon pixman libdrm libinput seatd
        systemd-libs mesa vulkan-headers vulkan-icd-loader fontconfig
        harfbuzz freetype2 hwdata libdisplay-info)

# System libraries the Rust half links. kallosd -> libpulse-sys; hajime's
# rodio -> cpal -> alsa-sys. Everything else in the Rust tree is either pure
# Rust (zbus for D-Bus, rustls+ring for TLS) or dlopened at runtime (the Vulkan
# loader, via ash).
rust=(libpulse alsa-lib)

# The opt-in apps. torrential's librqbit pulls native-tls -> openssl-sys, which
# is NOT vendored. yggdrasil and renzoku need nothing beyond the shared set.
apps=(openssl)

# Needed by a running session rather than by the build: the portal pair
# (kallos-portals.conf names `kallos;gtk;`, so the gtk backend is the
# fallthrough and is not optional), a PulseAudio-compatible server for
# kallosd's mixer, and the D-Bus services kallosd talks to — udisks2 for
# storage, bluez for Bluetooth, and **iwd** (`net.connman.iwd`) for Wi-Fi.
# Wi-Fi is iwd, not NetworkManager: see kallosd/src/sys/wifi.rs.
runtime=(xdg-desktop-portal xdg-desktop-portal-gtk pipewire-pulse bluez
         bluez-utils udisks2 iwd noto-fonts noto-fonts-cjk
         noto-fonts-emoji xorg-xwayland pciutils greetd)

# Nice to have: a fallback locker (phylax is the default now) and a terminal,
# yggdrasil's clipboard and file handlers, `lspci` for kallosd's sysinfo, and
# wlroots' optional plane-offload and colour-management deps.
optional=(swaylock foot wl-clipboard imv mpv libliftoff lcms2)

# ---- what's missing -------------------------------------------------------
# pacman -T is the right tool: it needs no root, and prints exactly the
# arguments that are NOT satisfied (by a package or by a provides). It exits 127
# when there are unsatisfied deps, which is success for our purposes, so it has
# to be guarded against set -e.
missing() { pacman -T "$@" 2>/dev/null || true; }

required=("${build[@]}" "${kosmos[@]}" "${rust[@]}" "${runtime[@]}")
[ "${APPS:-0}" = 1 ] && required+=("${apps[@]}")

hdr "dependencies"

pm=$(pkg_manager)
if [ "$pm" != pacman ]; then
	# Not a failure. The package names below are Arch's and mean nothing here,
	# but everything else in this tree works the same on any Linux — so say what
	# is needed, say what this machine appears to use, and get out of the way.
	skip "no pacman — the package names in this script are Arch's"
	[ "$pm" = none ] && note "no known package manager found either" \
	                 || note "this machine looks like: $pm"
	note "Kallos needs, by component:"
	note "  build    ${build[*]}"
	note "  kosmos   ${kosmos[*]}"
	note "  rust     ${rust[*]}"
	note "  runtime  ${runtime[*]}"
	note "install the equivalents, then re-run with --no-deps"
	note "the build is the real check — pkg-config names whatever is still missing"
else
	need=($(missing "${required[@]}"))
	want=($(missing "${optional[@]}"))

	if [ ${#need[@]} -eq 0 ]; then
		ok "all required packages present"
	else
		todo "missing ${#need[@]} required package(s)"
		note "${need[*]}"
	fi
	[ ${#want[@]} -eq 0 ] || {
		skip "optional, not installed: ${want[*]}"
		note "not required to build or start a session"
	}

	if [ ${#need[@]} -gt 0 ]; then
		cmd=(sudo pacman -S --needed "${need[@]}")
		note "run: ${cmd[*]}"
		if [ "$mode" = check ]; then
			: # report only
		elif [ "${YES:-0}" = 1 ]; then
			"${cmd[@]}"
		elif [ -t 0 ]; then
			say ""
			read -rp "   run it? [y/N] " a
			case "$a" in [yY]*) "${cmd[@]}" ;; *) act "skipped" ;; esac
		else
			act "not a terminal and YES=1 not set — skipped"
		fi
	fi
fi

# ---- muon -----------------------------------------------------------------
# kosmos/scripts/build.sh hard-fails without it, so this is not optional; it is
# just not a package. The bootstrap clones muon, self-builds it with clang and
# installs to ~/.local/bin. samurai ships inside it (`muon samu`), so there is
# no separate ninja to find.
if [ "${NO_MUON:-0}" != 1 ] && ! command -v muon >/dev/null; then
	todo "muon not found (it is not packaged on Arch — it builds from source)"
	if [ "$mode" = check ]; then
		note "run: kosmos/scripts/muon-bootstrap.sh"
	elif [ ! -x "$root/kosmos/scripts/muon-bootstrap.sh" ]; then
		die "no $root/kosmos/scripts/muon-bootstrap.sh — sync the submodules first"
	else
		"$root/kosmos/scripts/muon-bootstrap.sh"
	fi
fi
# The bootstrap installs to ~/.local/bin, which is not on a default Arch PATH.
case ":$PATH:" in
	*":$HOME/.local/bin:"*) ;;
	*) [ -x "$HOME/.local/bin/muon" ] &&
		warn "$HOME/.local/bin holds muon but is not on PATH" ;;
esac

# ---- session checklist ----------------------------------------------------
# Reported, never changed. Each of these needs a re-login or a reboot to take
# effect, so a script that silently "fixed" one would leave you believing the
# running session had it.
items=0
item() { items=$((items + 1)); todo "$*"; }
waits=0
later() { waits=$((waits + 1)); pend "$*"; }

# Two ways to ask about a group, and the difference between them is the whole
# reason this section used to be confusing.
#
#   in_group_now   this process's credentials — a snapshot taken at login that
#                  never changes for the life of the session.
#   in_group_file  /etc/group, which usermod rewrites immediately.
#
# They disagree for exactly as long as it takes to log out and back in. A check
# that only asked the first one reports "run usermod" at someone who just ran
# usermod, so they run it again and see the same line.
in_group_now()  { id -nG | tr ' ' '\n' | grep -qx "$1"; }
in_group_file() { getent group "$1" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$USER"; }

group_check() {   # group, why-it-matters
	local g="$1"
	in_group_now "$g" && return 0
	if in_group_file "$g"; then
		later "you are in the '$g' group, but this session started before that"
		note "log out and back in — there is nothing left to run"
	else
		item "you are not in the '$g' group"
		note "run: sudo usermod -aG $g $USER"
		note "then log out and back in"
	fi
	[ -n "${2-}" ] && note "$2"
	return 0
}

sec "session checklist"

# Seat management: who hands the compositor the GPU and the input devices.
#
# There are two implementations of that one job and kosmos picks NEITHER —
# libseat does, at runtime, trying seatd's socket first and falling back to
# logind. They are alternatives, not a pair. lib/detect.sh asks the same
# questions in the same order, so what it reports is what the compositor will
# actually get, rather than what a service manager says about a unit.
#
# Which one is in play decides whether the `seat` group means anything: seatd
# gates its socket by group membership, logind grants access to whoever owns
# the active session. This used to report both as outstanding on every machine,
# including the systemd ones where neither would ever be consulted.
case "$(seat_backend)" in
	seatd)
		ok "seat management: seatd"
		seat_forced && note "pinned by LIBSEAT_BACKEND=$LIBSEAT_BACKEND"
		group_check seat "seatd gates its socket by group membership"
		;;
	logind)
		ok "seat management: logind"
		seat_forced && note "pinned by LIBSEAT_BACKEND=$LIBSEAT_BACKEND"
		note "seatd and the 'seat' group are the alternative for machines without"
		note "logind — libseat falls back to this one, so neither is needed here"
		;;
	noop)
		item "LIBSEAT_BACKEND=noop — libseat will open no seat at all"
		note "that backend is a test stub; unset it for a real session"
		;;
	invalid)
		# Not a typo we can shrug at: libseat matches the name against its
		# backends and tries NOTHING when none match, so the compositor fails to
		# open a seat and the reason never reaches a log.
		item "LIBSEAT_BACKEND=$LIBSEAT_BACKEND is not a backend libseat knows"
		note "it accepts: seatd, logind, noop — anything else opens no seat at all"
		note "unset it to let libseat choose"
		;;
	none)
		# No socket and no logind. On systemd this means logind is not running,
		# which is its own problem; anywhere else, seatd is the answer and how you
		# start it depends on an init system we should not guess at.
		item "no seat manager: no seatd socket, and no logind seats"
		if have_systemd; then
			note "run: sudo systemctl enable --now seatd"
			note "(or find out why systemd-logind is not running)"
		else
			note "start seatd under $(init_system), or install elogind for the logind path"
		fi
		note "without one, kosmos cannot open the GPU or the input devices"
		;;
esac

# Independent of seat management: kosmos opens evdev directly to probe the lid
# switch, which is a plain group-permission read rather than anything libseat
# hands over.
group_check input "without it kosmos's lid probe returns UNKNOWN and falls back to /proc/acpi — not fatal"

[ -n "${XDG_RUNTIME_DIR:-}" ] || {
	item "XDG_RUNTIME_DIR is unset"
	note "expected from pam_systemd at login"
}
# The login screen is NOT checked here any more. greetd's config, its
# enablement and the greeter's seat access moved to scripts/session.sh, which
# offers to do each rather than printing a command to retype — and it has to
# run after the install, since the config it writes names a `phylax-greeter`
# that only exists once the binaries are in place. This script runs first in
# `./kallos up`, so a check here would report a state the same run is about to
# change. `./kallos doctor` runs both.
# A Vulkan ICD, tested by looking for the manifests the loader itself reads
# rather than by asking a package manager. Every distro installs them to the
# same place because the Vulkan loader hardcodes it, so this is one of the few
# checks here that is genuinely the same everywhere — and `pacman -T
# vulkan-driver` was not: off Arch it failed for lack of pacman and then
# reported a missing ICD that was sitting right there.
# Counted in the shell rather than with `ls ... | wc -l`: one of these two
# directories usually does not exist, ls exits 2 for it, and `set -o pipefail`
# hands that 2 to the assignment, where `set -e` ends the script. Silently, and
# several checks early.
icds=0
for f in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do
	[ -e "$f" ] && icds=$((icds + 1))
done
if [ "$icds" -eq 0 ]; then
	item "no Vulkan ICD — nothing in /usr/share/vulkan/icd.d"
	if [ "$pm" = pacman ]; then
		note "run: sudo pacman -S vulkan-radeon | vulkan-intel | nvidia-utils"
		note "(whichever matches this GPU — it is a property of the hardware)"
	else
		note "install your GPU's Vulkan driver; kosmos renders through it"
	fi
fi
# The network stack under kallosd's Wi-Fi pane. iwd only associates: without
# systemd-networkd nothing asks for a lease, and unless /etc/resolv.conf is the
# symlink to systemd-resolved's stub, a captive-portal login hangs for minutes
# rather than loading. scripts/net.sh sets all of it up in one go; this only
# reports, like everything else here.
#
# networkd and resolved are systemd's own, and so is net.sh's idea of applying
# them, so the whole check is skipped where systemd is not what is running. The
# need is real on any init; the names for it are not.
if have_systemd; then
	netbad=()
	[ -L /etc/resolv.conf ] ||
		netbad+=("/etc/resolv.conf is a file, not the resolved stub — portals hang")
	compgen -G "/etc/systemd/network/*.network" >/dev/null ||
		netbad+=("no .network files — networkd would hand out no leases")
	for u in systemd-networkd systemd-resolved iwd; do
		systemctl is-enabled --quiet "$u" 2>/dev/null || netbad+=("$u is not enabled")
	done
	if [ ${#netbad[@]} -gt 0 ]; then
		item "the network stack is not set up"
		for b in "${netbad[@]}"; do note "$b"; done
		note "run: ./kallos net        (reports; then ./kallos net apply)"
	fi
fi
command -v xwayland-satellite >/dev/null || {
	item "no xwayland-satellite"
	note "AUR; or set KWM_XWAYLAND=off to run without X11"
}
[ $((items + waits)) -eq 0 ] && ok "nothing to do" || true

exit 0
