#!/usr/bin/env bash
# A private Kallos session beside the live one: kallosd --wm kosmos --overlay
# hajime, with its own runtime dir, its own session bus and a scratch HOME.
#
#   scripts/rig.sh start [window|headless] [debug|release]
#   scripts/rig.sh env      print the exports that reach the rig
#   scripts/rig.sh stop
#
# window    kosmos opens as a window on the live desktop (the wayland backend,
#           so the nested modifier is Alt). The rig's kallosd still reads
#           /dev/input directly, so a gamepad drives it whatever has focus.
# headless  no window; drive it with the rig's kallosctl and grim -o HEADLESS-1.
#
# What keeps it off the live session:
#   - XDG_RUNTIME_DIR is redirected, so kallosctl and hajime talk to the rig's
#     daemon only, and kosmos's wayland-N socket lives in the rig.
#   - dbus-run-session gives kallosd a private session bus. session_activate
#     (activation env, systemd user env, graphical-session target) and every
#     bus name kallosd claims land there, not on the real bus.
#   - HOME is a scratch copy of ~/.config/kallos; the startup file is emptied
#     so the user's autostart does not run twice.
#   - It is stopped by pid. Never pkill: the live kosmos/kallosd/hajime share
#     the same comm names.
#
# RIG_DIR overrides the scratch dir (keep it short: the daemon socket must fit
# in sun_path).
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"

R="${RIG_DIR:-/tmp/kallos-rig}"
uid=$(id -u)

rig_env() {
	[ -f "$R/pid" ] || die "no rig running (no $R/pid)"
	local w
	w=$(sed -n 's/.*session display registered: WAYLAND_DISPLAY=\([a-z0-9-]*\).*/\1/p' "$R/log" | tail -1)
	echo "export XDG_RUNTIME_DIR=$R/rt"
	echo "export WAYLAND_DISPLAY=$w"
	echo "export DBUS_SESSION_BUS_ADDRESS=$(cat "$R/bus" 2>/dev/null)"
}

stop() {
	[ -f "$R/pid" ] || { note "no rig running"; return 0; }
	local pid
	pid=$(cat "$R/pid")
	# Only ever the pid we started, and only if it is still that kallosd.
	if [ -d "/proc/$pid" ] && [ "$(readlink "/proc/$pid/exe")" -ef "$(cat "$R/exe")" ]; then
		kill "$pid"
		for _ in $(seq 1 50); do [ -d "/proc/$pid" ] || break; sleep 0.1; done
		[ -d "/proc/$pid" ] && err "kallosd $pid did not exit" || act "stopped kallosd $pid"
	else
		note "kallosd $pid already gone"
	fi
	# kallosd leaves its compositor running on SIGTERM (a real session ends
	# from the compositor's side), so stop the rig's kosmos too, by the pid
	# kallosd logged, checked against the binary the rig started.
	local kp
	kp=$(sed -n "s/.*spawned compositor '\([^ ']*\).*(pid \([0-9]*\)).*/\1 \2/p" "$R/log" | tail -1)
	if [ -n "$kp" ]; then
		set -- $kp
		if [ -d "/proc/$2" ] && [ "$(readlink "/proc/$2/exe")" -ef "$1" ]; then
			kill "$2"
			for _ in $(seq 1 50); do [ -d "/proc/$2" ] || break; sleep 0.1; done
			act "stopped kosmos $2"
		fi
	fi
	rm -f "$R/pid"
}

start() {
	local mode="${1:-window}" cfg="${2:-debug}"
	case "$mode" in window|headless) ;; *) die "mode: window|headless" ;; esac
	local KD="$root/kallosd/target/$cfg/kallosd"
	local KOSMOS="$root/kosmos/builds/$cfg/src/kosmos"
	local HAJIME="$root/hajime/target/$cfg/hajime"
	for b in "$KD" "$KOSMOS" "$HAJIME"; do
		[ -x "$b" ] || die "missing $b — run scripts/build.sh $cfg"
	done
	if [ -f "$R/pid" ] && [ -d "/proc/$(cat "$R/pid")" ]; then
		die "a rig is already running (scripts/rig.sh stop)"
	fi

	rm -rf "$R"
	mkdir -p "$R/rt" "$R/home/.config/kallos"
	chmod 700 "$R/rt"
	cp "$HOME/.config/kallos/"* "$R/home/.config/kallos/" 2>/dev/null || true
	: > "$R/home/.config/kallos/startup"
	echo "$KD" > "$R/exe"

	local -a env=(
		HOME="$R/home"
		XDG_RUNTIME_DIR="$R/rt"
		PULSE_SERVER="unix:/run/user/$uid/pulse/native"
		KALLOS_LOG_TARGET=stderr
		KWM_IDLE_MS=0
	)
	if [ "$mode" = window ]; then
		local outer="${WAYLAND_DISPLAY:-wayland-0}"
		# Absolute, or the wayland backend looks in the redirected runtime dir.
		case "$outer" in /*) ;; *) outer="/run/user/$uid/$outer" ;; esac
		[ -S "$outer" ] || die "no outer compositor at $outer"
		env+=(WAYLAND_DISPLAY="$outer" WLR_BACKENDS=wayland)
	else
		env+=(WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=vulkan)
	fi

	# The inner sh records the bus address and its own pid, then becomes
	# kallosd: the pid file names kallosd itself, and when it exits
	# dbus-run-session takes the private bus down with it.
	nohup env -u XDG_CONFIG_HOME -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY "${env[@]}" \
		dbus-run-session -- sh -c '
			echo "$DBUS_SESSION_BUS_ADDRESS" > "$0/bus"
			echo $$ > "$0/pid"
			exec "$1" --verbose --wm "$2 --verbose" --overlay "$3"
		' "$R" "$KD" "$KOSMOS" "$HAJIME" >"$R/log" 2>&1 &

	for _ in $(seq 1 60); do
		grep -q 'session display registered' "$R/log" 2>/dev/null && break
		sleep 0.5
	done
	grep -q 'session display registered' "$R/log" \
		|| { err "kosmos never registered — see $R/log"; stop; exit 1; }
	act "rig up ($mode, $cfg): kallosd $(cat "$R/pid"), log $R/log"
	rig_env
}

case "${1:-}" in
	start) shift; start "$@" ;;
	stop) stop ;;
	env) rig_env ;;
	*) die "usage: scripts/rig.sh start [window|headless] [debug|release] | env | stop" ;;
esac
