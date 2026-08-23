#!/usr/bin/env bash
# The boot configuration that gets Kallos from the power button to the login
# screen without a console in between — and the one place it is written down.
#
# This is the half of the boot work that cannot live in a commit: kernel command
# line, initramfs contents, bootloader timeout. `phylax/docs/boot.md` explains
# why each of these is here and what it measured; this applies them.
#
# **Optional, and never run by `./kallos up`.** It edits /etc and /boot and its
# effects appear at the next reboot, which is not something an idempotent
# "update my machine" command should do behind your back. Run it deliberately,
# once, on a machine you want to boot like ours does.
#
# What it changes, and why (measured on an AMD 780M laptop, 16.8s -> 14.6s from
# power-on to the login screen):
#
#   quiet loglevel=3        Nothing prints, so fbcon DEFERS taking the console
#                           and the firmware's own logo stays on screen. It also
#                           means fbcon never owns the console across the
#                           simpledrm->real-driver handover, which is what used
#                           to cause a 0.76s black flash mid-boot.
#   vt.global_cursor_default=0   No blinking block cursor.
#   systemd.show_status=false    No "[ OK ] Started ..." unit status.
#   fbcon=vc:2-6            fbcon manages VT2-6 only, so nothing ever paints
#                           text on VT1 where the compositor lives. This is what
#                           stops stray console output being flashed back on
#                           screen every time DRM master changes hands.
#   MODULES=(<kms driver>)  The GPU in the initramfs. Without it udev loads it
#                           off the root filesystem ~3s into userspace and
#                           everything needing a DRM device waits — it is also
#                           the assumption phylax's greetd drop-in makes when it
#                           declines to wait on systemd-udev-settle.
#   timeout 0               systemd-boot stops waiting at the menu. Hold Space
#                           during boot to get it back. KEEP_MENU=1 skips this.
#
# Two things it deliberately does NOT do:
#
#   * touch the fallback boot entry. It stays fully verbose with fbcon on VT1,
#     so there is always a way in when the graphical stack does not come up.
#   * trim the initramfs. `MODULES=(amdgpu)` pulls 667 firmware blobs because
#     mkinitcpio has no per-ASIC filter, but the whole loader phase measured
#     610ms, so the ~28M of waste costs a fraction of a second. See boot.md.
#
# **After this, the rescue console is Ctrl+Alt+F2.** VT1 will have no text
# console at all.
#
# Usage: scripts/boot.sh [check|apply|revert]   (default: check)
#   KEEP_MENU=1  leave loader.conf's timeout alone
#   YES=1        don't prompt
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-check}"
case "$mode" in
	check|apply|revert) ;;
	*) echo "!! usage: scripts/boot.sh [check|apply|revert]" >&2; exit 2 ;;
esac

esp="${ESP:-/boot}"
bak=".bak-kallos"
say() { printf '   %s\n' "$*"; }
act() { printf '>> %s\n' "$*"; }

# The flags, in one place. Order is the order they are appended.
FLAGS=(quiet loglevel=3 vt.global_cursor_default=0 systemd.show_status=false fbcon=vc:2-6)

# ---- discovery ------------------------------------------------------------

# The KMS driver actually bound to a display device on THIS machine — amdgpu,
# i915, xe, nouveau. Read from sysfs rather than guessed from lspci, and never
# hardcoded: the whole point is that a different laptop gets its own answer.
kms_driver() {
	local c d
	for c in /sys/class/drm/card*/device/driver; do
		[ -e "$c" ] || continue
		d=$(basename "$(readlink -f "$c")")
		[ -n "$d" ] && { echo "$d"; return 0; }
	done
	return 1
}

# The systemd-boot entries we are willing to edit: everything that is not a
# fallback. Matched on both the filename and the title, because either one is
# how a distro marks the rescue entry.
primary_entries() {
	local f
	for f in "$esp"/loader/entries/*.conf; do
		[ -e "$f" ] || continue
		case "$f" in *fallback*|*rescue*|*"$bak"*) continue ;; esac
		grep -qiE '^title.*(fallback|rescue)' "$f" && continue
		echo "$f"
	done
}

# Is `key` already present on an options line, with any value?
has_key() { case " $1 " in *" $2 "*|*" $2="*) return 0 ;; *) return 1 ;; esac; }

# ---- preflight ------------------------------------------------------------

if [ ! -d "$esp/loader/entries" ]; then
	echo "!! no $esp/loader/entries — this script only knows systemd-boot." >&2
	echo "   GRUB: put the flags in GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub" >&2
	echo "   UKI:  put them in /etc/kernel/cmdline and rebuild." >&2
	echo "   Either way the flags are listed at the top of this file." >&2
	exit 1
fi

mapfile -t entries < <(primary_entries)
[ "${#entries[@]}" -gt 0 ] || { echo "!! no non-fallback entries in $esp/loader/entries" >&2; exit 1; }

driver=$(kms_driver || true)
# Overridable so this can be exercised against a fixture without touching the
# real /etc; ESP does the same for /boot.
mkconf="${MKINITCPIO_CONF:-/etc/mkinitcpio.conf}"
loader="$esp/loader/loader.conf"

# ---- revert ---------------------------------------------------------------

if [ "$mode" = revert ]; then
	n=0
	for f in "${entries[@]}" "$mkconf" "$loader"; do
		if [ -e "$f$bak" ]; then
			act "restoring $f"
			sudo cp -a "$f$bak" "$f" && sudo rm -f "$f$bak"
			n=$((n + 1))
		fi
	done
	[ "$n" -gt 0 ] || { say "nothing to revert (no $bak files)"; exit 0; }
	if [ -n "$driver" ] && command -v mkinitcpio >/dev/null; then
		act "rebuilding the initramfs"
		sudo mkinitcpio -P
	fi
	act "reverted $n file(s) — reboot to take effect"
	exit 0
fi

# ---- report ---------------------------------------------------------------

want_menu=0; [ -n "${KEEP_MENU:-}" ] && want_menu=1
todo=0

echo "== kernel command line =="
for f in "${entries[@]}"; do
	opts=$(sed -n 's/^options[[:space:]]*//p' "$f" | head -1)
	miss=()
	for flag in "${FLAGS[@]}"; do
		key="${flag%%=*}"
		if has_key "$opts" "$key"; then :; else miss+=("$flag"); fi
	done
	if [ "${#miss[@]}" -eq 0 ]; then
		say "OK    $(basename "$f")"
	else
		say "TODO  $(basename "$f") <- ${miss[*]}"
		todo=1
	fi
done
say "(fallback entries are left alone on purpose — that is the way back in)"

echo "== initramfs =="
if [ -z "$driver" ]; then
	say "SKIP  no KMS driver bound to a display device; nothing to add"
elif ! command -v mkinitcpio >/dev/null; then
	say "SKIP  no mkinitcpio (not Arch?) — put '$driver' in your initramfs by hand"
elif grep -qE "^MODULES=\(.*\b$driver\b.*\)" "$mkconf"; then
	say "OK    $driver already in MODULES"
else
	say "TODO  add '$driver' to MODULES in $mkconf, then mkinitcpio -P"
	todo=1
fi

echo "== bootloader =="
if [ "$want_menu" = 1 ]; then
	say "SKIP  KEEP_MENU=1 — leaving loader.conf alone"
elif grep -qE '^timeout[[:space:]]+0[[:space:]]*$' "$loader" 2>/dev/null; then
	say "OK    timeout 0"
else
	say "TODO  set 'timeout 0' in $loader   (hold Space at boot for the menu)"
	todo=1
fi

if [ "$mode" = check ]; then
	echo
	[ "$todo" = 0 ] && act "nothing to do" || act "run: scripts/boot.sh apply"
	exit 0
fi

# ---- apply ----------------------------------------------------------------

[ "$todo" = 0 ] && { echo; act "already applied; nothing to do"; exit 0; }

if [ -z "${YES:-}" ]; then
	echo
	echo "   This edits $esp and /etc, and takes effect at the next reboot."
	echo "   After it, VT1 has no text console: the rescue console is Ctrl+Alt+F2,"
	echo "   and the fallback boot entry stays verbose as the way back in."
	read -r -p "   Apply? [y/N] " a
	case "$a" in y|Y|yes|YES) ;; *) echo ">> aborted"; exit 1 ;; esac
fi

echo
for f in "${entries[@]}"; do
	opts=$(sed -n 's/^options[[:space:]]*//p' "$f" | head -1)
	add=()
	for flag in "${FLAGS[@]}"; do
		key="${flag%%=*}"
		has_key "$opts" "$key" || add+=("$flag")
	done
	[ "${#add[@]}" -gt 0 ] || continue
	[ -e "$f$bak" ] || sudo cp -a "$f" "$f$bak"
	act "$(basename "$f") += ${add[*]}"
	sudo sed -i "/^options[[:space:]]/ s|\$| ${add[*]}|" "$f"
done

if [ -n "$driver" ] && command -v mkinitcpio >/dev/null \
	&& ! grep -qE "^MODULES=\(.*\b$driver\b.*\)" "$mkconf"; then
	[ -e "$mkconf$bak" ] || sudo cp -a "$mkconf" "$mkconf$bak"
	act "MODULES += $driver"
	# Works for both MODULES=() and MODULES=(already here): insert before the
	# closing paren, with a separating space only when the list is non-empty.
	sudo sed -i -E "s|^MODULES=\((.*)\)|MODULES=(\1 $driver)|; s|^MODULES=\( |MODULES=(|" "$mkconf"
	act "rebuilding the initramfs (this grows it — the firmware comes too)"
	sudo mkinitcpio -P
fi

if [ "$want_menu" = 0 ] && ! grep -qE '^timeout[[:space:]]+0[[:space:]]*$' "$loader" 2>/dev/null; then
	[ -e "$loader$bak" ] || sudo cp -a "$loader" "$loader$bak"
	act "timeout 0"
	if grep -qE '^timeout' "$loader" 2>/dev/null; then
		sudo sed -i -E 's|^timeout.*|timeout 0|' "$loader"
	else
		echo 'timeout 0' | sudo tee -a "$loader" >/dev/null
	fi
fi

echo
act "applied — reboot to see it"
say "originals kept alongside as *$bak; scripts/boot.sh revert puts them back"
