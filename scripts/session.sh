#!/usr/bin/env bash
# The login screen, and the boot-time GPU it depends on — the machine-level
# setup that turns an installed Kallos into one that greets you at power-on.
#
# This is the part scripts/install.sh deliberately will not do. That script
# only COPIES: it drops phylax's greetd config next to the others but refuses
# to overwrite an existing /etc/greetd/config.toml, and it never enables a
# unit, because taking tty1 from getty is a reboot-scale change and an
# installer that did it silently would be lying about the state of the machine.
# None of that stops it being ASKED, which is what this file is: the same
# checks, each one offering to do the thing rather than printing a command to
# retype.
#
# Two checks, and they are a pair:
#
#   1. the login screen — /etc/greetd/config.toml is phylax's rather than the
#      agreety one Arch's package ships, and greetd is enabled.
#   2. the GPU in the initramfs — delegated to `scripts/boot.sh initramfs`,
#      which owns that knowledge; there is no second copy of it here.
#
# They are a pair because phylax's greetd drop-in (data/systemd/greetd-kallos.conf)
# stopped ordering greetd after udev-settle on the grounds that the DRM device
# already exists at boot — which is true only once (2) is done. Enabling the
# login screen without it is what the drop-in's restart budget is a safety net
# for, and a safety net is not the plan.
#
# Everything here is reported first and only then offered. Nothing happens
# without a `y`, and on a non-terminal (CI, a pipe) it degrades to the report
# and exits 0 — same contract as scripts/deps.sh's package prompt.
#
# Usage: scripts/session.sh [check|apply]   (default: apply)
#   check   report only; never prompt, never write        (this is what
#           `./kallos doctor` runs)
#   apply   report, then offer to fix what is outstanding
#   YES=1   don't prompt; assume yes
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"
. "$root/scripts/lib/detect.sh"

mode="${1:-apply}"
case "$mode" in
	check|apply) ;;
	*) err "usage: scripts/session.sh [check|apply]"; exit 2 ;;
esac

bak=".bak-kallos"

# What to say under a todo. In `check` nothing is coming, so name the command.
# In `apply` the offer is a few lines below and naming a command as well would
# read as though the prompt were not going to handle it.
fixnote() { [ "$mode" = check ] && note "run: $*"; return 0; }

src_conf="$root/phylax/data/greetd/config.toml"
etc_conf="${GREETD_CONF:-/etc/greetd/config.toml}"

# What needs doing. Each entry is a key; the actions are dispatched off them
# below, so the report and the fix cannot drift apart. Named `pending` rather
# than the obvious `todo` because lib/out.sh already has a todo() that prints a
# label — bash would keep the two apart, but a reader would not.
pending=()

hdr "session"

sec "login screen"

if ! command -v greetd >/dev/null; then
	skip "greetd is not installed (scripts/deps.sh installs it)"
elif [ ! -x "${PREFIX:-/usr/local}/bin/phylax-greeter" ]; then
	# Ordering guard, not a style check. The config below names
	# `phylax-greeter`; enabling greetd before that binary exists arms a login
	# screen that cannot start, and the failure lands at the next boot rather
	# than here. In `./kallos up` this is always satisfied — install runs first.
	skip "${PREFIX:-/usr/local}/bin/phylax-greeter is not installed yet"
	note "run the install first: ./kallos install"
else
	if [ ! -e "$etc_conf" ]; then
		todo "$etc_conf does not exist"
		fixnote "sudo install -m644 $src_conf $etc_conf"
		pending+=(conf)
	elif cmp -s "$src_conf" "$etc_conf"; then
		ok "$etc_conf is phylax's"
	else
		todo "$etc_conf is not phylax's — it would still greet you with agreety"
		fixnote "sudo install -m644 $src_conf $etc_conf"
		pending+=(conf)
	fi

	# Starting greetd at boot is the init system's job, and only systemd's
	# version of that job is one this script knows how to do. The config above is
	# greetd's own and is the same file whatever starts it, so it stays outside
	# this guard — a runit or OpenRC machine still gets the phylax login screen
	# installed and configured, and arranges the starting itself.
	if ! have_systemd; then
		skip "greetd is installed; starting it is $(init_system)'s business"
		note "arrange for greetd to run on tty1 under your init, then reboot"
	elif ! systemctl is-enabled --quiet greetd 2>/dev/null; then
		todo "greetd is not enabled"
		fixnote "sudo systemctl enable greetd"
		note "it then takes tty1 and greets from the next boot"
		pending+=(enable)
	elif systemctl is-active --quiet greetd 2>/dev/null; then
		ok "greetd is enabled and running"
	else
		# Enabled and running are different answers, and the gap between them is a
		# reboot: enabling greetd does not take tty1 from the getty already holding
		# it. Reporting "enabled" as done leaves you at a text login wondering
		# which command you missed. There is none.
		pend "greetd is enabled but has not taken tty1 yet"
		note "reboot — getty holds tty1 until then, and there is nothing left to run"
	fi

	# The greeter's seat access, but only when seatd is what actually arbitrates
	# the seat. seatd gates its socket by group membership; logind grants the
	# greeter access by way of its session and needs no group at all. Asked from
	# lib/detect.sh rather than from the service manager, so this is right on a
	# machine with no systemd to ask. See the comment at the top of
	# phylax/data/greetd/config.toml.
	if seat_needs_group && ! id -nG greeter 2>/dev/null | grep -qw seat; then
		todo "the 'greeter' user is not in the 'seat' group, and seatd arbitrates the seat"
		fixnote "sudo usermod -aG seat greeter"
		pending+=(seatgrp)
	fi
fi

# ---- the fix --------------------------------------------------------------

if [ "${#pending[@]}" -gt 0 ] && [ "$mode" = apply ]; then
	if [ "${YES:-0}" != 1 ] && [ ! -t 0 ]; then
		echo
		act "not a terminal and YES=1 not set — reporting only"
	else
		echo
		say "Enabling the login screen takes tty1 from getty at the next boot."
		say "If it does not come up, the way back in is Ctrl+Alt+F2 — and the"
		say "fallback boot entry stays verbose on purpose."
		[[ " ${pending[*]} " == *" conf "* ]] && [ -e "$etc_conf" ] &&
			say "Your current $etc_conf is kept alongside as $(basename "$etc_conf")$bak."
		agreed=0
		if [ "${YES:-0}" = 1 ]; then
			agreed=1
		else
			read -r -p "   Set up the phylax login screen? [y/N] " a
			case "$a" in y|Y|yes|YES) agreed=1 ;; *) act "skipped" ;; esac
		fi
		if [ "$agreed" = 1 ]; then
			echo
			for t in "${pending[@]}"; do
				case "$t" in
					conf)
						# Back up whatever was there — it is the admin's file,
						# and install.sh's refusal to touch it is the reason
						# this needs asking in the first place.
						if [ -e "$etc_conf" ] && [ ! -e "$etc_conf$bak" ]; then
							sudo cp -a "$etc_conf" "$etc_conf$bak"
						fi
						act "installing $etc_conf"
						sudo install -d "$(dirname "$etc_conf")"
						sudo install -m644 "$src_conf" "$etc_conf"
						;;
					enable)
						act "systemctl enable greetd"
						sudo systemctl enable greetd
						;;
					seatgrp)
						act "usermod -aG seat greeter"
						sudo usermod -aG seat greeter
						;;
				esac
			done
		fi
	fi
fi

# ---- the GPU in the initramfs ---------------------------------------------
# Delegated, never reimplemented: scripts/boot.sh owns which modules this
# machine needs and how to get them in. `initramfs` is its one separable mode —
# the GPU, with none of the console changes the rest of that script makes.
sec "boot-time GPU"
if [ "$mode" = check ]; then
	REPORT_ONLY=1 NO_HEADER=1 "$root/scripts/boot.sh" initramfs || true
else
	NO_HEADER=1 "$root/scripts/boot.sh" initramfs || true
fi

exit 0
