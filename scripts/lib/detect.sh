# What this machine actually is. Sourced, never executed.
#
#   . "$(dirname "$0")/lib/detect.sh"        # from scripts/
#
# Kallos is developed on Arch and `scripts/deps.sh` speaks pacman, but nothing
# in the suite itself requires Arch, systemd, or any particular bootloader —
# kosmos asks libseat for a seat and libseat asks whatever is there. The scripts
# used to assume otherwise in a dozen small places, so a machine that was merely
# *different* got told it was *wrong*: deps.sh exited on a missing pacman,
# the seat checklist asked systemd about seatd whether or not systemd existed,
# and the greetd drop-in pulled seatd in on machines already using logind.
#
# Everything here is a QUESTION, never an assertion. Each function prints one
# word and returns 0, or prints "none"/"unknown" — no function in this file
# fails, exits, or writes anything, so a caller can always ask and then decide.
#
# The rule the callers follow: detect, adapt, and say which way it went. Never
# refuse to run because a machine answered differently.

# ---- init ------------------------------------------------------------------

# /run/systemd/system is the canonical "systemd is running as PID 1" test — the
# one systemd itself documents (sd_booted(3)). Deliberately not `ps -p 1`, which
# is true inside a container whose PID 1 is something else entirely, and not
# `command -v systemctl`, which is true on any machine that merely has the
# package installed.
have_systemd() { [ -d /run/systemd/system ]; }

init_system() {
	if have_systemd; then echo systemd
	elif [ -d /run/openrc ]; then echo openrc
	elif [ -d /run/runit ]; then echo runit
	elif [ -d /run/s6 ] || [ -d /run/service ]; then echo s6
	elif [ -e /sbin/init ] || [ -e /usr/sbin/init ]; then echo sysvinit
	else echo unknown
	fi
}

# ---- seat management -------------------------------------------------------

# Which backend libseat will pick, worked out the way libseat itself does it.
#
# libseat has the backends compiled in and tries them in a fixed order, taking
# the first that opens: seatd's socket first, then logind. LIBSEAT_BACKEND in
# the environment forces one and skips the search. So the honest way to answer
# "what will the compositor use" is to look for the same things in the same
# order — NOT to ask the service manager whether a unit is enabled, which is a
# different question with a different answer (a unit can be enabled and not
# running, or running because something else pulled it in).
#
# This is what makes the `seat` group conditional: seatd gates its socket by
# group membership (`seatd -g seat`), logind grants access to whoever owns the
# active session on the seat and needs no group at all. Asking for the group on
# a logind machine is asking for something that will never be consulted.
# LIBSEAT_BACKEND, when set, is matched against the compiled-in backend NAMES
# and nothing else is tried. A value that matches none of them is not "ignored"
# — libseat skips every backend and opens no seat at all, so the compositor
# fails to start with nothing in the log to say why. That is worth its own
# answer rather than quietly falling through to the detection below and
# reporting a backend that will never be reached.
#
# The names are the ones in libseat 0.9.x: seatd, logind, and noop (a stub that
# opens nothing, for tests).
seat_backend() {
	case "${LIBSEAT_BACKEND:-}" in
		"")     ;;   # not forced — fall through to the search below
		seatd)  echo seatd;  return 0 ;;
		logind) echo logind; return 0 ;;
		noop)   echo noop;   return 0 ;;
		*)      echo invalid; return 0 ;;
	esac
	[ -S "${SEATD_SOCK:-/run/seatd.sock}" ] && { echo seatd; return 0; }
	# logind, or elogind — the same D-Bus interface, and libseat's logind
	# backend talks to either. elogind is how a machine without systemd still
	# gets logind semantics, which is exactly the case worth detecting.
	if [ -d /run/systemd/seats ] || [ -d /run/elogind/seats ]; then
		echo logind; return 0
	fi
	echo none
}

# Does the seat backend in play gate access by group membership? Only seatd
# does. Callers use this to decide whether the `seat` group is worth mentioning.
seat_needs_group() { [ "$(seat_backend)" = seatd ]; }

# Was the backend chosen by LIBSEAT_BACKEND rather than found? Callers say so,
# because "logind" meaning "this machine has logind" and "logind" meaning
# "someone pinned it" are worth telling apart when something is wrong.
seat_forced() { [ -n "${LIBSEAT_BACKEND:-}" ]; }

# ---- packaging -------------------------------------------------------------

# The package manager, for reporting and for the one case we can actually drive.
# Only pacman gets an install path: the lists in scripts/deps.sh are Arch
# package names, and translating them to five other distros would be a mapping
# that silently rots every time one of them renames or splits a package. Naming
# the manager is still worth doing — it tells a reader we noticed, and it lets
# deps.sh say something useful instead of exiting.
pkg_manager() {
	local m
	for m in pacman apt-get dnf zypper apk xbps-install emerge; do
		command -v "$m" >/dev/null 2>&1 && { echo "${m%-*}"; return 0; }
	done
	echo none
}

# ---- boot ------------------------------------------------------------------

# Which initramfs generator this machine uses. scripts/boot.sh can only drive
# mkinitcpio; the others are named so its message can be specific about what to
# do by hand rather than guessing "not Arch?".
initramfs_tool() {
	if command -v mkinitcpio >/dev/null 2>&1; then echo mkinitcpio
	elif command -v dracut >/dev/null 2>&1; then echo dracut
	elif command -v booster >/dev/null 2>&1; then echo booster
	else echo none
	fi
}
