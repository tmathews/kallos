#!/usr/bin/env bash
# The Kallos dependency checklist for Arch, and the one place it is written down.
#
# This supersedes kosmos/docs/building.md's "Quick install" block, which went
# stale at the Rust cutover: it still lists `wireless_tools` for a
# cc.find_library('iw') that no longer exists in kosmos/meson.build, plus cairo,
# openssl, libnghttp2, libpulse and dbus as *compositor* build deps. libpulse
# belongs to kallosd now and openssl to torrential; the rest left with the C
# code. The lists below were read off kosmos/meson.build, kosmos/src/meson.build,
# the wlroots 0.18.2 subproject wrap and each crate's Cargo.lock.
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

mode="${1:-install}"
case "$mode" in
	check|install) ;;
	*) echo "!! usage: scripts/deps.sh [check|install]" >&2; exit 2 ;;
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

command -v pacman >/dev/null || {
	echo "!! no pacman — this script is Arch-only; install the deps by hand" >&2
	echo "   the lists are in $root/scripts/deps.sh" >&2
	exit 1
}

required=("${build[@]}" "${kosmos[@]}" "${rust[@]}" "${runtime[@]}")
[ "${APPS:-0}" = 1 ] && required+=("${apps[@]}")

need=($(missing "${required[@]}"))
want=($(missing "${optional[@]}"))

if [ ${#need[@]} -eq 0 ]; then
	echo ">> all required packages present"
else
	echo ">> missing ${#need[@]} required package(s):"
	printf '   %s\n' "${need[@]}"
fi
[ ${#want[@]} -eq 0 ] || {
	echo ">> optional, not installed: ${want[*]}"
	echo "   (not required to build or start a session)"
}

if [ ${#need[@]} -gt 0 ]; then
	cmd=(sudo pacman -S --needed "${need[@]}")
	echo ">> ${cmd[*]}"
	if [ "$mode" = check ]; then
		: # report only
	elif [ "${YES:-0}" = 1 ]; then
		"${cmd[@]}"
	elif [ -t 0 ]; then
		read -rp "   run it? [y/N] " a
		case "$a" in [yY]*) "${cmd[@]}" ;; *) echo ">> skipped" ;; esac
	else
		echo ">> not a terminal and YES=1 not set — skipped"
	fi
fi

# ---- muon -----------------------------------------------------------------
# kosmos/scripts/build.sh hard-fails without it, so this is not optional; it is
# just not a package. The bootstrap clones muon, self-builds it with clang and
# installs to ~/.local/bin. samurai ships inside it (`muon samu`), so there is
# no separate ninja to find.
if [ "${NO_MUON:-0}" != 1 ] && ! command -v muon >/dev/null; then
	echo ">> muon not found (it is not packaged on Arch — it builds from source)"
	if [ "$mode" = check ]; then
		echo "   run: kosmos/scripts/muon-bootstrap.sh"
	elif [ ! -x "$root/kosmos/scripts/muon-bootstrap.sh" ]; then
		echo "!! no $root/kosmos/scripts/muon-bootstrap.sh — sync the submodules first" >&2
		exit 1
	else
		"$root/kosmos/scripts/muon-bootstrap.sh"
	fi
fi
# The bootstrap installs to ~/.local/bin, which is not on a default Arch PATH.
case ":$PATH:" in
	*":$HOME/.local/bin:"*) ;;
	*) [ -x "$HOME/.local/bin/muon" ] &&
		echo ">> note: $HOME/.local/bin holds muon but is not on PATH" ;;
esac

# ---- session checklist ----------------------------------------------------
# Reported, never changed. Each of these needs a re-login to take effect, and a
# script that silently "fixed" one would leave you believing the running
# session had it.
note=0
say() { note=1; printf '   %s\n' "$*"; }

echo ">> session checklist"
systemctl is-enabled --quiet seatd 2>/dev/null ||
	say "seatd not enabled     -> sudo systemctl enable --now seatd"
id -nG | grep -qw seat ||
	say "not in group 'seat'   -> sudo usermod -aG seat $USER   (re-login)"
id -nG | grep -qw input || {
	say "not in group 'input'  -> sudo usermod -aG input $USER   (re-login)"
	say "                         without it kosmos's evdev lid probe returns UNKNOWN"
	say "                         and falls back to /proc/acpi — not fatal"
}
[ -n "${XDG_RUNTIME_DIR:-}" ] ||
	say "XDG_RUNTIME_DIR unset -> expected from pam_systemd at login"
# The login screen. greetd takes the VT from getty when enabled, which is a
# reboot-scale change — reported, never done. Its `greeter` user needs the
# same seat access kosmos needs (the `seat` group under seatd).
if command -v greetd >/dev/null; then
	systemctl is-enabled --quiet greetd 2>/dev/null ||
		say "greetd not enabled    -> sudo systemctl enable greetd   (takes tty1 at next boot)"
	id -nG greeter 2>/dev/null | grep -qw seat ||
		say "greeter not in 'seat' -> sudo usermod -aG seat greeter"
fi
# The network stack under kallosd's Wi-Fi pane. iwd only associates: without
# systemd-networkd nothing asks for a lease, and unless /etc/resolv.conf is the
# symlink to systemd-resolved's stub, a captive-portal login hangs for minutes
# rather than loading. scripts/net.sh sets all of it up in one go; this only
# reports, like everything else here.
netbad=()
[ -L /etc/resolv.conf ] ||
	netbad+=("/etc/resolv.conf is a file, not the resolved stub - portals hang")
compgen -G "/etc/systemd/network/*.network" >/dev/null ||
	netbad+=("no .network files - networkd would hand out no leases")
for u in systemd-networkd systemd-resolved iwd; do
	systemctl is-enabled --quiet "$u" 2>/dev/null || netbad+=("$u not enabled")
done
if [ ${#netbad[@]} -gt 0 ]; then
	say "network not set up    -> ./kallos net   (reports; then ./kallos net apply)"
	for b in "${netbad[@]}"; do say "                         $b"; done
fi
pacman -T vulkan-driver >/dev/null 2>&1 ||
	say "no Vulkan ICD         -> install vulkan-radeon / vulkan-intel / nvidia-utils"
command -v xwayland-satellite >/dev/null ||
	say "no xwayland-satellite -> AUR; or set KWM_XWAYLAND=off to run without X11"
[ "$note" -eq 0 ] && echo "   nothing to do" || true

exit 0
