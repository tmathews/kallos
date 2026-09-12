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
# Usage: scripts/boot.sh [check|apply|revert|initramfs]   (default: check)
#   KEEP_MENU=1  leave loader.conf's timeout alone
#   YES=1        don't prompt
#   REPORT_ONLY=1  in `initramfs` mode, never prompt — report and exit
#   NO_HEADER=1    in `initramfs` mode, let the caller print the section header
#
# `initramfs` is the odd one out: just the GPU-in-the-initramfs check and fix,
# none of the console changes, no ESP needed. It is separable because it is the
# one piece another part of the tree depends on — phylax's greetd drop-in — so
# `./kallos up` can offer it without dragging the rest of this file in.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$PWD/scripts/lib/out.sh"
. "$PWD/scripts/lib/detect.sh"

mode="${1:-check}"
case "$mode" in
	check|apply|revert|initramfs) ;;
	*) err "usage: scripts/boot.sh [check|apply|revert|initramfs]"; exit 2 ;;
esac

esp="${ESP:-/boot}"
bak=".bak-kallos"

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

# The modules that have to be in the initramfs for that driver to bring up KMS,
# which is not always the one name sysfs reports.
#
# mkinitcpio's MODULES pulls in each named module's own dependencies — the
# things it needs — but never its dependents. For the in-tree drivers that is
# the whole story: `amdgpu` IS the DRM driver, so naming it is enough.
#
# NVIDIA is four separate modules stacked the other way up. sysfs names the
# bottom one (`nvidia`, what the PCI device is bound to), but the DRM node comes
# from `nvidia_drm` at the TOP: nvidia_drm -> nvidia_modeset -> nvidia. Adding
# only what sysfs said would put the base module in the initramfs and still
# leave /dev/dri empty at that point, which is exactly the failure the greetd
# drop-in stops ordering around. Name the whole stack.
#
# nvidia_drm.modeset=1 is not needed here: it has defaulted to on since driver
# 545, and this tree targets far newer.
kms_modules() {
	local d
	d=$(kms_driver) || return 1
	case "$d" in
		nvidia) echo "nvidia nvidia_modeset nvidia_uvm nvidia_drm" ;;
		*)      echo "$d" ;;
	esac
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

driver=$(kms_driver || true)
modules=$(kms_modules || true)
# Overridable so this can be exercised against a fixture without touching the
# real /etc; ESP does the same for /boot.
mkconf="${MKINITCPIO_CONF:-/etc/mkinitcpio.conf}"
loader="$esp/loader/loader.conf"

# Which of this machine's KMS modules are NOT in MODULES yet. Printed
# space-separated; empty output means there is nothing to do.
#
# Each module is checked on its own, so a half-done list (nvidia in, nvidia_drm
# not — the state a machine is left in by naming only what sysfs reported) gets
# finished rather than skipped. That also rules out a substring test: `nvidia`
# occurs inside `nvidia_drm`, so matching on the raw line would call the set
# complete when only the base module is there. Pull the list out and compare
# whole words against it instead.
kms_missing() {
	local m cur out=""
	cur=" $(sed -nE 's|^MODULES=\((.*)\).*|\1|p' "$mkconf" | head -1) "
	for m in $modules; do
		case "$cur" in *" $m "*) ;; *) out="$out $m" ;; esac
	done
	echo "${out# }"
}

# Is any initramfs image older than the config that generates it? That is the
# state you are left in by editing MODULES and not rebuilding — and it also
# catches the gap between `mkinitcpio -P` finishing and the reboot that
# actually boots the new image. MODULES saying the right thing is not the same
# as the running machine having it, and reporting the first as OK is how you
# end up rebooting into the old initramfs and wondering what you missed.
#
# mtime, not contents: reading an image needs lsinitcpio and root, and this
# runs unprivileged.
initramfs_stale() {
	local img
	for img in "$esp"/initramfs-*.img /boot/initramfs-*.img; do
		[ -e "$img" ] || continue
		[ "$mkconf" -nt "$img" ] && return 0
	done
	# No images, or every one of them newer than the config: either way there is
	# nothing to report. Finding none is not evidence of staleness.
	return 1
}

# The initramfs section, shared by the full report and `initramfs` mode.
# Prints its own lines; returns 1 when there is something to do.
initramfs_report() {
	local miss
	if [ -z "$modules" ]; then
		skip "no KMS driver bound to a display device; nothing to add"
	elif [ "$(initramfs_tool)" != mkinitcpio ]; then
		# Only mkinitcpio is driven here. Naming what this machine actually uses
		# beats the old guess of "not Arch?" — dracut and booster both do this,
		# just not with a MODULES= line in mkinitcpio.conf.
		case "$(initramfs_tool)" in
			none) skip "no initramfs generator found — put '$modules' in yours by hand" ;;
			*)    skip "this machine uses $(initramfs_tool), not mkinitcpio"
			      note "add '$modules' to its config and regenerate" ;;
		esac
	elif [ -z "$(kms_missing)" ]; then
		if initramfs_stale; then
			pend "$modules are in MODULES, but the initramfs is older than $mkconf"
			note "run: sudo mkinitcpio -P   (then reboot)"
			return 1
		fi
		ok "$modules already in MODULES"
	else
		miss=$(kms_missing)
		todo "add '$miss' to MODULES in $mkconf, then mkinitcpio -P"
		[ "$miss" = "$modules" ] ||
			note "'$modules' is the full set for $driver; the rest is already there"
		return 1
	fi
	return 0
}

# Add the missing modules and rebuild. Assumes initramfs_report said there was
# something to do.
initramfs_apply() {
	local miss
	miss=$(kms_missing)
	[ -n "$miss" ] || return 0
	[ -e "$mkconf$bak" ] || sudo cp -a "$mkconf" "$mkconf$bak"
	act "MODULES += $miss"
	# Works for both MODULES=() and MODULES=(already here): insert before the
	# closing paren, with a separating space only when the list is non-empty.
	sudo sed -i -E "s|^MODULES=\((.*)\)|MODULES=(\1 $miss)|; s|^MODULES=\( |MODULES=(|" "$mkconf"
	act "rebuilding the initramfs (this grows it — the firmware comes too)"
	sudo mkinitcpio -P
}

# ---- initramfs only -------------------------------------------------------
# Just the GPU-in-the-initramfs half, check and fix, with none of the console
# changes the other modes make. This is the piece phylax's greetd drop-in
# ASSUMES — it declines to order after udev-settle on the grounds that the DRM
# device already exists — so `./kallos up` offers this one on its own, while
# the rest of boot.sh stays the deliberate opt-in it has always been.
#
# No ESP preflight: nothing here reads a boot entry, and a machine on GRUB or a
# UKI still wants its GPU in the initramfs.
if [ "$mode" = initramfs ]; then
	# NO_HEADER: scripts/session.sh prints its own "boot-time GPU" section around
	# this call, and two headers in a row with nothing between them reads as a
	# mistake. Standalone, the section is this script's to announce.
	[ "${NO_HEADER:-0}" = 1 ] || sec "initramfs"
	if initramfs_report; then
		exit 0
	fi
	# REPORT_ONLY is how scripts/session.sh asks for the check half in its own
	# `check` mode, where a prompt would be wrong and "not a terminal" would be
	# a confusing thing to say about a deliberate choice.
	[ "${REPORT_ONLY:-0}" = 1 ] && exit 1
	if [ -z "${YES:-}" ]; then
		[ -t 0 ] || { echo; act "not a terminal and YES=1 not set — reporting only"; exit 1; }
		echo
		say "This edits $mkconf and rebuilds the initramfs, which takes a"
		say "moment and grows /boot. It takes effect at the next reboot."
		read -r -p "   Apply? [y/N] " a
		case "$a" in y|Y|yes|YES) ;; *) act "skipped"; exit 1 ;; esac
	fi
	echo
	initramfs_apply
	echo
	act "applied — reboot to see it"
	say "the original is kept alongside as $(basename "$mkconf")$bak"
	exit 0
fi

# Everything below edits boot entries, so from here on the ESP has to be real.
if [ ! -d "$esp/loader/entries" ]; then
	err "no $esp/loader/entries — this script only knows systemd-boot."
	note "GRUB: put the flags in GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
	note "UKI:  put them in /etc/kernel/cmdline and rebuild."
	die "Either way the flags are listed at the top of this file."
fi

mapfile -t entries < <(primary_entries)
[ "${#entries[@]}" -gt 0 ] || die "no non-fallback entries in $esp/loader/entries"

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
	[ "$n" -gt 0 ] || { ok "nothing to revert (no $bak files)"; exit 0; }
	if [ -n "$driver" ] && [ "$(initramfs_tool)" = mkinitcpio ]; then
		act "rebuilding the initramfs"
		sudo mkinitcpio -P
	fi
	act "reverted $n file(s) — reboot to take effect"
	exit 0
fi

# ---- report ---------------------------------------------------------------

want_menu=0; [ -n "${KEEP_MENU:-}" ] && want_menu=1
# `pending`, not `todo`: lib/out.sh has a todo() that prints a label, and while
# bash keeps a function and a variable of the same name apart, a reader should
# not have to know that to follow this.
pending=0

hdr "boot configuration"

sec "kernel command line"
for f in "${entries[@]}"; do
	opts=$(sed -n 's/^options[[:space:]]*//p' "$f" | head -1)
	miss=()
	for flag in "${FLAGS[@]}"; do
		key="${flag%%=*}"
		if has_key "$opts" "$key"; then :; else miss+=("$flag"); fi
	done
	if [ "${#miss[@]}" -eq 0 ]; then
		ok "$(basename "$f")"
	else
		todo "$(basename "$f") <- ${miss[*]}"
		pending=1
	fi
done
note "fallback entries are left alone on purpose — that is the way back in"

sec "initramfs"
initramfs_report || pending=1

sec "bootloader"
if [ "$want_menu" = 1 ]; then
	skip "KEEP_MENU=1 — leaving loader.conf alone"
elif grep -qE '^timeout[[:space:]]+0[[:space:]]*$' "$loader" 2>/dev/null; then
	ok "timeout 0"
else
	todo "set 'timeout 0' in $loader"
	note "hold Space at boot to get the menu back"
	pending=1
fi

if [ "$mode" = check ]; then
	echo
	[ "$pending" = 0 ] && act "nothing to do" || act "run: scripts/boot.sh apply"
	exit 0
fi

# ---- apply ----------------------------------------------------------------

[ "$pending" = 0 ] && { echo; act "already applied; nothing to do"; exit 0; }

if [ -z "${YES:-}" ]; then
	echo
	say "This edits $esp and /etc, and takes effect at the next reboot."
	say "After it, VT1 has no text console: the rescue console is Ctrl+Alt+F2,"
	say "and the fallback boot entry stays verbose as the way back in."
	read -r -p "   Apply? [y/N] " a
	case "$a" in y|Y|yes|YES) ;; *) act "aborted"; exit 1 ;; esac
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

if [ -n "$modules" ] && [ "$(initramfs_tool)" = mkinitcpio ]; then
	initramfs_apply
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
note "originals kept alongside as *$bak; scripts/boot.sh revert puts them back"
