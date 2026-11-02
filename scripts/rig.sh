#!/usr/bin/env bash
# A private Kallos session beside the live one: kallosd --wm kosmos --overlay
# hajime, with its own runtime dir, its own session bus and a scratch HOME.
#
#   scripts/rig.sh start [window|headless|tty] [debug|release]
#   scripts/rig.sh env      print the exports that reach the rig
#   scripts/rig.sh stop
#   scripts/rig.sh verify [debug|release]   the session checks, headless
#
# window    kosmos opens as a window on the live desktop (the wayland backend,
#           so the nested modifier is Alt). The rig's kallosd still reads
#           /dev/input directly, so a gamepad drives it whatever has focus.
# headless  no window; drive it with the rig's kallosctl and grim -o HEADLESS-1.
# tty       kosmos on the real displays (DRM), for hardware checks. Start it
#           from a text login on another VT (Ctrl+Alt+F2): it takes that VT's
#           logind session, and the live session on tty1 just pauses — switch
#           back with Ctrl+Alt+F1. RIG_IDLE_MS sets the display-off timeout
#           (default 0, off).
# verify    a scripted run of its own, in its own scratch dir (RIG_DIR with
#           -verify appended), so it neither needs nor disturbs a rig you have
#           up: a bare daemon, then a headless two-output session taken through
#           startup, overlay, hot corners, the display domain, the locker and
#           crash recovery. Exits non-zero if any check fails.
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
#     the same comm names. Where a pid is not written down anywhere (a
#     respawned compositor, the overlay, the locker), a process is the rig's
#     when it carries the rig's XDG_RUNTIME_DIR in its environment.
#
# What it still cannot isolate: device state and logind. Wi-Fi connect,
# Bluetooth pair, storage mount and `power` change the machine, so verify
# enumerates those and never touches the write paths.
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

# The binary /proc/$1 runs is $2 — even if $2 was rebuilt since (the kernel
# then reports the old inode as "<path> (deleted)").
runs() {
	[ -d "/proc/$1" ] || return 1
	local e
	e=$(readlink "/proc/$1/exe") || return 1
	[ "$e" -ef "$2" ] || [ "${e% (deleted)}" = "$2" ]
}

# The pids named $1 that belong to this rig: the comm, and the rig's runtime dir
# in the environment they were started with. Every child of the rig's kallosd
# inherits it, and nothing in the live session can have it.
rpids() {
	local p
	for p in $(pgrep -x "$1" || true); do
		grep -qzxF "XDG_RUNTIME_DIR=$R/rt" "/proc/$p/environ" 2>/dev/null && echo "$p"
	done
	return 0
}
# sed, not head: head exits early, and under pipefail the SIGPIPE it leaves
# rpids with fails the assignment.
rpid() { rpids "$1" | sed -n 1p; }
ralive() { [ -n "$(rpids "$1")" ]; }

stop() {
	[ -f "$R/pid" ] || { note "no rig running"; return 0; }
	local pid
	pid=$(cat "$R/pid")
	# Only ever the pid we started, and only if it is still that kallosd.
	if runs "$pid" "$(cat "$R/exe")"; then
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
		if runs "$2" "$1"; then
			kill "$2"
			for _ in $(seq 1 50); do [ -d "/proc/$2" ] || break; sleep 0.1; done
			act "stopped kosmos $2"
		fi
	fi
	rm -f "$R/pid"
}

# A fresh scratch dir: the runtime dir, and a HOME seeded from the real config
# with the startup file emptied.
prep() {
	local sock="$R/rt/kallos/kdaemon.sock"
	# sockaddr_un.sun_path is 108 bytes: a long scratch path fails at listen(),
	# which is a confusing way to learn this.
	[ ${#sock} -lt 100 ] || die "RIG_DIR too long: $sock would not fit in sun_path"
	rm -rf "$R"
	mkdir -p "$R/rt" "$R/home/.config/kallos"
	chmod 700 "$R/rt"
	cp "$HOME/.config/kallos/"* "$R/home/.config/kallos/" 2>/dev/null || true
	: > "$R/home/.config/kallos/startup"
}

# Run "$@" (a kallosd command line) under a private session bus with the rig's
# environment, plus whatever VAR=value the caller put in `extra`. Logs to
# $R/log; $R/pid names kallosd once it is up.
#
# The inner sh records the bus address and its own pid, then becomes kallosd:
# the pid file names kallosd itself, and when it exits dbus-run-session takes
# the private bus down with it. Which also means kallosd must stay in the
# foreground — one that daemonizes leaves dbus-run-session nothing to wait on.
launch() {
	local -a env=(
		HOME="$R/home"
		XDG_RUNTIME_DIR="$R/rt"
		PULSE_SERVER="unix:/run/user/$uid/pulse/native"
		KALLOS_LOG_TARGET=stderr
		"${extra[@]}"
	)
	rm -f "$R/pid"
	echo "$1" > "$R/exe"
	nohup env -u XDG_CONFIG_HOME -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY "${env[@]}" \
		dbus-run-session -- sh -c '
			echo "$DBUS_SESSION_BUS_ADDRESS" > "$0/bus"
			echo $$ > "$0/pid"
			exec "$@"
		' "$R" "$@" >"$R/log" 2>&1 &
	for _ in $(seq 1 50); do [ -s "$R/pid" ] && break; sleep 0.1; done
	[ -s "$R/pid" ] || die "the rig never started — see $R/log"
}

# Wait for kosmos to register over SESSION; true once it has.
registered() {
	for _ in $(seq 1 60); do
		grep -q 'session display registered' "$R/log" 2>/dev/null && return 0
		sleep 0.5
	done
	return 1
}

start() {
	local mode="${1:-window}" cfg="${2:-debug}"
	case "$mode" in window|headless|tty) ;; *) die "mode: window|headless|tty" ;; esac
	if [ "$mode" = tty ] && [ -z "${XDG_VTNR:-}" ]; then
		die "tty mode needs a text login on a VT (Ctrl+Alt+F2), not this shell"
	fi
	local KD="$root/kallosd/target/$cfg/kallosd"
	local KOSMOS="$root/kosmos/builds/$cfg/src/kosmos"
	local HAJIME="$root/hajime/target/$cfg/hajime"
	for b in "$KD" "$KOSMOS" "$HAJIME"; do
		[ -x "$b" ] || die "missing $b — run scripts/build.sh $cfg"
	done
	if [ -f "$R/pid" ] && [ -d "/proc/$(cat "$R/pid")" ]; then
		die "a rig is already running (scripts/rig.sh stop)"
	fi

	prep
	local -a extra=(KWM_IDLE_MS="${RIG_IDLE_MS:-0}")
	if [ "$mode" = window ]; then
		local outer="${WAYLAND_DISPLAY:-wayland-0}"
		# Absolute, or the wayland backend looks in the redirected runtime dir.
		case "$outer" in /*) ;; *) outer="/run/user/$uid/$outer" ;; esac
		[ -S "$outer" ] || die "no outer compositor at $outer"
		extra+=(WAYLAND_DISPLAY="$outer" WLR_BACKENDS=wayland)
	elif [ "$mode" = headless ]; then
		extra+=(WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=vulkan)
	fi

	launch "$KD" --verbose --wm "$KOSMOS --verbose" --overlay "$HAJIME"
	registered || { err "kosmos never registered — see $R/log"; stop; exit 1; }
	act "rig up ($mode, $cfg): kallosd $(cat "$R/pid"), log $R/log"
	rig_env
}

# ---- verify ---------------------------------------------------------------
# The lock checks need phylax-type (`cargo build --features devtools` in
# phylax/); without it they are skipped, not failed. Likewise the hot-corner and
# display checks without kosmos's hotcorner-client and displays-client.
verify() {
	local cfg="${1:-debug}"
	R="${RIG_DIR:-/tmp/kallos-rig}-verify"
	local KD="$root/kallosd/target/$cfg/kallosd"
	local CTL="$root/kallosctl/target/$cfg/kallosctl"
	local HAJIME="$root/hajime/target/$cfg/hajime"
	local PHYLAX="$root/phylax/target/$cfg/phylax"
	# The key injector, built only with `cargo build --features devtools`.
	local PTYPE="$root/phylax/target/$cfg/phylax-type"
	local KOSMOS="$root/kosmos/builds/$cfg/src/kosmos"
	local HCC="$root/kosmos/builds/$cfg/apps/hotcorner-client/hotcorner-client"
	local DC="$root/kosmos/builds/$cfg/apps/displays-client/displays-client"
	local b
	for b in "$KD" "$CTL" "$HAJIME" "$PHYLAX"; do
		[ -x "$b" ] || die "missing $b — run scripts/build.sh $cfg"
	done

	# The tallies. `pass`/`fail`/`skip` in lib/out.sh print; these wrap them
	# to count as well, so the summary at the bottom cannot drift from the
	# lines above it.
	local n_pass=0 n_fail=0 n_skip=0
	yes() { pass "$*"; n_pass=$((n_pass + 1)); }
	no()  { fail "$*"; n_fail=$((n_fail + 1)); }
	skp() { skip "$*"; n_skip=$((n_skip + 1)); }

	# Every client reaches the rig through these, never through an export:
	# rpids tells the rig's processes from the live session's by exactly this
	# variable, so the script's own environment stays the real one.
	ctl() { XDG_RUNTIME_DIR="$R/rt" timeout 10 "$CTL" "$@"; }
	local wd=""
	onrig() { XDG_RUNTIME_DIR="$R/rt" WAYLAND_DISPLAY="$wd" "$@"; }

	# Whatever the rig started, by pid. kallosd first, so a compositor it
	# supervises is not respawned on the way out.
	reap() {
		local c p
		for c in kallosd kosmos hajime phylax; do
			for p in $(rpids "$c"); do kill "$p" 2>/dev/null || true; done
			for _ in $(seq 1 30); do ralive "$c" || break; sleep 0.1; done
		done
	}
	trap reap EXIT
	# A run that was interrupted leaves its session behind; the scratch dir is
	# about to go, and with it the only way to tell those processes are ours.
	reap
	prep
	# The real startup file would spawn the user's input method into this
	# session; swap in something observable instead.
	printf '/usr/bin/touch %s/startup-marker\n' "$R" > "$R/home/.config/kallos/startup"
	# The locker under test, with its fake authenticator: "ok" unlocks.
	# Appended, so it overrides whatever the seeded settings say.
	printf 'locker = %s --lock --dry\n' "$PHYLAX" >> "$R/home/.config/kallos/settings"
	# Hot corners fire an action, so the only way to observe one from outside
	# is to make that action observable. Both top corners touch the same
	# marker; the checks unlink it between gestures.
	printf 'corner_tl = spawn touch %s\ncorner_tr = spawn touch %s\n' \
		"$R/hotcorner-marker" "$R/hotcorner-marker" \
		>> "$R/home/.config/kallos/settings"

	hdr "verify — the $cfg build"
	note "scratch dir $R"

	# ---- 1. the daemon answers --------------------------------------------
	# There is one daemon and nothing to diff it against, so these checks say
	# what they can say on their own: it listens, the lists render through the
	# real consumer, and no verb takes it down.
	sec "the daemon answers"
	local -a extra=()
	launch "$KD" --verbose --foreground
	for _ in $(seq 1 50); do [ -S "$R/rt/kallos/kdaemon.sock" ] && break; sleep 0.1; done
	sleep 2   # let it finish connecting to PulseAudio and priming its caches

	[ -S "$R/rt/kallos/kdaemon.sock" ] && yes "kallosd is listening" || no "kallosd never listened"

	# Every list, through the real consumer. Not compared against anything —
	# just that hajime can ask and the daemon can answer without either
	# hanging.
	local m
	for m in --lists --apps; do
		if XDG_RUNTIME_DIR="$R/rt" timeout 10 "$HAJIME" $m >"$R/lists$m" 2>&1; then
			yes "hajime $m rendered $(wc -l <"$R/lists$m") line(s)"
		else
			no "hajime $m failed or hung:"; sed 's/^/       /' "$R/lists$m" | head -10
		fi
	done

	# The command surface. Several of these are MEANT to fail (`bt confirm`
	# with nothing pending, `run something` with no such binary), so the exit
	# status is not the check — surviving them is. A verb that panics the
	# daemon takes the socket with it, which the probe after the sweep is what
	# catches. `media` and `overlay` are safe here because the bus is the
	# rig's: no player to drive, no overlay to push to. `power` is not — it is
	# logind, on the system bus — and `display` waits for a compositor below.
	local -a cases=(
		"config reload" "appearance theme dark" "appearance theme auto"
		"appearance accent #FF8800" "noti clear" "wifi" "bt" "storage" "apps"
		"bt confirm" "run something" "media playpause" "overlay toggle"
	)
	local c
	for c in "${cases[@]}"; do
		# shellcheck disable=SC2086
		ctl $c >/dev/null 2>&1 || true
	done
	if ctl config reload >/dev/null 2>&1; then
		yes "the daemon survived all ${#cases[@]} commands"
	else
		no "the daemon stopped answering during the command sweep"
	fi

	# ---- 2. the poller parks ----------------------------------------------
	sec "the poller parks at 0% CPU with no subscribers"
	local pid t0 t1
	pid=$(cat "$R/pid")
	ticks() { awk '{print $14 + $15}' "/proc/$1/stat"; }
	t0=$(ticks "$pid"); sleep 10; t1=$(ticks "$pid")
	if [ $((t1 - t0)) -le 1 ]; then
		yes "kallosd used $((t1 - t0)) tick(s) over 10s idle"
	else
		no "kallosd used $((t1 - t0)) ticks over 10s idle — the poller is not parking"
	fi

	reap
	mv "$R/log" "$R/daemon.log"

	# ---- 3. the session root (M10) ----------------------------------------
	sec "session root: kallosd --wm --overlay on a headless compositor"
	if [ ! -x "$KOSMOS" ]; then
		skp "no kosmos built — session checks skipped"
		hdr "verify — $n_pass passed, $n_fail failed, $n_skip skipped"
		[ "$n_fail" -eq 0 ]
		return
	fi
	rm -f "$R/startup-marker"
	local log="$R/log"
	extra=(WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2)
	launch "$KD" --verbose --wm "$KOSMOS" --overlay "$HAJIME"
	# The compositor needs a moment to bring up Vulkan and register.
	registered || true
	wd=$(sed -n 's/.*WAYLAND_DISPLAY=\([a-z0-9-]*\).*/\1/p' "$log" | head -1)

	grep -q 'session display registered' "$log" \
		&& yes "compositor registered its WAYLAND_DISPLAY over SESSION" \
		|| no "no SESSION register — see $log"
	ralive hajime \
		&& yes "overlay spawned on the compositor's display" \
		|| no "overlay never spawned"
	grep -q "layer surface 'hajime'" "$log" \
		&& yes "overlay mapped its OVERLAY layer surface" \
		|| no "overlay surface never mapped"
	[ -e "$R/startup-marker" ] \
		&& yes "startup commands ran on the SESSION register" \
		|| no "startup commands did not run"

	# Invariant: spawned children get a reset signal mask. The daemon blocks
	# SIGCHLD for its signalfd, and that mask survives exec — a real bug once,
	# where a terminal spawned from the session had no working Ctrl+C.
	local hp blk
	hp=$(rpid hajime)
	blk=$(awk '/^SigBlk/{print $2}' "/proc/$hp/status" 2>/dev/null || echo missing)
	[ "$blk" = "0000000000000000" ] \
		&& yes "spawned child has an empty signal mask" \
		|| no "spawned child inherited SigBlk=$blk"

	# Overlay control, end to end: the verb reaches the resident overlay as a
	# TOPIC_OVERLAY push and the compositor sees the surface map and unmap.
	ctl overlay show >/dev/null; sleep 2
	ctl overlay hide >/dev/null; sleep 1
	ctl overlay toggle >/dev/null; sleep 1
	[ "$(grep -c 'overlay verb=' "$log")" -ge 3 ] \
		&& yes "overlay show/hide/toggle reached the resident overlay" \
		|| no "overlay verbs did not reach a subscriber"

	# Startup commands are once per daemon lifetime — a config reload must
	# not re-run them (niri's spawn-at-startup, not sway's exec_always).
	rm -f "$R/startup-marker"
	ctl config reload >/dev/null; sleep 1
	[ ! -e "$R/startup-marker" ] \
		&& yes "config reload did not re-run the startup commands" \
		|| no "config reload re-ran the startup commands"

	# ---- hot corners ------------------------------------------------------
	# Before the display block, which leaves the two outputs stacked
	# vertically — these checks are about the seam between a LEFT and a
	# RIGHT screen, which is the arrangement the headless backend starts in.
	if [ ! -x "$HCC" ]; then
		skp "no hotcorner-client built — hot-corner checks skipped"
	elif onrig "$HCC" "$R/hotcorner-marker" > "$R/hotcorner.txt" 2>&1; then
		yes "hot corners: a cross-monitor sweep never fires, a flick does"
	else
		no "hot-corner gate failed"
		sed 's/^/       /' "$R/hotcorner.txt"
	fi
	rm -f "$R/hotcorner-marker"

	# ---- the display domain -----------------------------------------------
	# Reachable here, and only here: `display` verbs go to the compositor
	# this block owns. Position is client-observable via xdg-output, so
	# displays-client watches from the outside rather than asking kosmos what
	# it believes it did.
	if [ ! -x "$DC" ]; then
		skp "no displays-client built — arrangement checks skipped"
	else
		dc() { onrig "$DC" "$@"; }
		# Where the two headless outputs start, before anything moves them.
		# The layout is kept anchored to the origin (see the normalisation
		# check below), so these move the output that is NOT at 0,0 — that
		# way the requested coordinates are also the resulting ones, and the
		# checks stay about placement rather than about normalisation.
		local base h2
		base=$(dc --print 2>/dev/null || true)
		h2=$(printf '%s\n' "$base" | awk '$1=="HEADLESS-2"{print $2}')

		ctl display HEADLESS-1 position 2000 100 >/dev/null
		if dc --expect "HEADLESS-1=2000,100,1280x720" >/dev/null; then
			yes "an explicit position lands where asked"
		else
			no "position did not apply"
		fi
		# The regression that makes this worth testing: placing one output
		# explicitly re-packs every output still auto-positioned, so without
		# the pin the neighbour is dragged along by the move.
		if dc --expect "HEADLESS-2=$h2,1280x720" >/dev/null; then
			yes "the other output did not drift"
		else
			no "moving one output moved the other (the pin-before-move rule)"
		fi

		ctl display HEADLESS-1 transform 90 >/dev/null
		if dc --expect "HEADLESS-1=2000,100,720x1280" >/dev/null; then
			yes "a 90 transform swaps the logical size"
		else
			no "transform did not swap logical width/height"
		fi
		ctl display HEADLESS-1 transform normal >/dev/null

		# saved_pos (the disable/enable restore) is a second record of where
		# everything sits; a move while it is live has to write through, or
		# stale coordinates resurrect here.
		ctl display HEADLESS-1 disable >/dev/null
		sleep 1
		ctl display HEADLESS-1 enable >/dev/null
		if dc --expect "HEADLESS-1=2000,100,1280x720" --expect "HEADLESS-2=$h2,1280x720" >/dev/null; then
			yes "disable then enable restored both positions"
		else
			no "disable/enable lost the arrangement"
		fi

		# The arrangement was written back to the config on the user's
		# behalf, without eating the rest of the file.
		local dpy_cfg="$R/home/.config/kallos/displays"
		if grep -q 'position 2000 100' "$dpy_cfg" 2>/dev/null; then
			yes "the arrangement persisted itself to the displays config"
		else
			no "the arrangement was not written to $dpy_cfg"
		fi

		# The arrangement must keep its top-left corner at the layout origin.
		# X screens start at (0,0) and cannot go negative, so an arrangement
		# that starts anywhere else hands XWayland a screen with a dead
		# region in its top-left and leaves X11 apps with unusable pointer
		# input. Dragging monitors walks the layout off the origin very
		# easily.
		ctl display HEADLESS-1 position 2000 500 >/dev/null
		ctl display HEADLESS-2 position 2000 1220 >/dev/null
		sleep 1
		if dc --print | awk '{split($2,p,","); if (p[1]==0 && p[2]==0) found=1}
		                    END {exit !found}'; then
			yes "the arrangement stays anchored to the layout origin"
		else
			no "the layout drifted off the origin — XWayland input would break"
			dc --print | sed 's/^/       /'
		fi
	fi

	# ---- the locker -------------------------------------------------------
	# `power lock` spawns phylax as the daemon's child — the one `power` verb
	# that stays inside the rig; the rest are logind's. The compositor's
	# ext-session-lock relay tells the daemon when it is locked. phylax-type
	# types through virtual-keyboard-v1, so a wrong then a right password is
	# a script, not a person.
	if [ ! -x "$PTYPE" ]; then
		skp "no phylax-type built (cargo build --features devtools) — lock checks skipped"
	else
		ctl power lock >/dev/null; sleep 3
		grep -qF '[kallosd] session locked' "$log" \
			&& yes "power lock locked the session (compositor relay seen)" \
			|| no "no session-locked relay after power lock"
		onrig "$PTYPE" 'wrong\n' >/dev/null; sleep 2
		ralive phylax && ! grep -qF '[kallosd] session unlocked' "$log" \
			&& yes "a wrong password left it locked" \
			|| no "a wrong password unlocked, or the locker died"
		onrig "$PTYPE" 'ok\n' >/dev/null; sleep 2
		grep -qF '[kallosd] session unlocked' "$log" && ! ralive phylax \
			&& yes "the right password unlocked and the locker exited" \
			|| no "the right password did not unlock"
		# A locker that dies with the lock held is respawned.
		ctl power lock >/dev/null; sleep 3
		kill -SEGV "$(rpid phylax)" 2>/dev/null; sleep 2
		ralive phylax && grep -q 'respawning locker' "$log" \
			&& yes "a crashed locker was respawned with the session still locked" \
			|| no "locker crash was not recovered"
		onrig "$PTYPE" 'ok\n' >/dev/null; sleep 2
	fi

	# ---- crash recovery ---------------------------------------------------
	# The contract from suite #4, stated positively: a compositor that DIES is
	# an accident the daemon recovers from — a new compositor, a new overlay,
	# and the session left standing with everything systemd holds for it.
	# Only a compositor that was *asked* to go (exit 0: Super+Escape, or a
	# SIGTERM it handled) ends the session.
	#
	# SIGKILL, not SIGTERM, is the crash here. kosmos registers its SIGTERM
	# handler after the process is multithreaded, so the signal lands on a
	# thread with the default disposition and it dies at 143 without ever
	# reaching the handler (kosmos #70) — which makes SIGTERM a crash today
	# and a clean exit 0 the day #70 is fixed, i.e. the other branch of
	# on_wm_exit. SIGKILL cannot be handled, so it means the same thing before
	# and after, and this check keeps asking the question it means to ask.
	local wm0 wm1 ov0 ov1
	wm0=$(rpid kosmos)
	ov0=$(rpid hajime)
	[ -n "$wm0" ] && kill -KILL "$wm0" 2>/dev/null || true
	for _ in $(seq 1 30); do
		wm1=$(rpid kosmos)
		[ -n "$wm1" ] && [ "$wm1" != "$wm0" ] && break
		sleep 1
	done
	if [ -n "$wm1" ] && [ "$wm1" != "$wm0" ] && ralive kallosd; then
		yes "a crashed compositor was respawned ($wm0 -> $wm1), session intact"
	else
		no "compositor crash was not recovered — see $log"
	fi

	# The overlay was a client of the compositor that died, so it died too.
	# `overlay_pending` re-arms it and the SESSION register launches it again;
	# a new pid is the whole point — the old one surviving would mean an
	# orphan holding a dead socket.
	for _ in $(seq 1 15); do
		ov1=$(rpid hajime)
		[ -n "$ov1" ] && [ "$ov1" != "$ov0" ] && break
		sleep 1
	done
	if [ -n "$ov1" ] && [ "$ov1" != "$ov0" ]; then
		yes "the overlay was relaunched onto the new display ($ov0 -> $ov1)"
	else
		no "the overlay did not come back with the compositor"
	fi

	# ---- recovery gives up ------------------------------------------------
	# The budget is WM_RESPAWN_MAX (3), reset only by WM_HEALTHY_UPTIME (60s)
	# of uptime — so a compositor killed the moment it appears walks it down
	# instead of resetting it. One death happened above; deaths two and three
	# are respawned, and the fourth is the one with no budget left, which
	# ends the session. That is the half of #4 that must still reach the
	# greeter: recovery that cannot recover has to stop flickering at the
	# user.
	local kills=0 wm new
	while [ "$kills" -lt 3 ]; do
		wm=$(rpid kosmos)
		[ -n "$wm" ] || break
		kill -KILL "$wm" 2>/dev/null || true
		kills=$((kills + 1))
		# Its replacement, or the daemon giving up — either ends the wait.
		for _ in $(seq 1 15); do
			ralive kallosd || break
			new=$(rpid kosmos)
			[ -n "$new" ] && [ "$new" != "$wm" ] && break
			sleep 1
		done
	done
	for _ in $(seq 1 10); do ralive kallosd || break; sleep 1; done
	if ! ralive kallosd && ! ralive hajime; then
		yes "a crash loop exhausted the budget, ending the session and reaping the overlay"
	else
		no "the session outlived four compositor deaths — the budget did not end it"
	fi

	hdr "verify — $n_pass passed, $n_fail failed, $n_skip skipped"
	[ "$n_fail" -eq 0 ]
}

case "${1:-}" in
	start) shift; start "$@" ;;
	stop) stop ;;
	env) rig_env ;;
	verify) shift; verify "$@" ;;
	*) die "usage: scripts/rig.sh start [window|headless|tty] [debug|release] | env | stop | verify [debug|release]" ;;
esac
