#!/usr/bin/env bash
# Verify the Rust cutover without owning the TTY or the session.
#
# Two things make this possible:
#
#  1. **A redirected runtime dir.** The daemon is single-instance (an flock
#     under $XDG_RUNTIME_DIR/kallos), so kallosd and the C kdaemon cannot both
#     hold the real one. Give each its own XDG_RUNTIME_DIR and both run at
#     once — then point the *same* client at each in turn and diff. Every
#     LIST_REPLY coming out byte-identical is a far stronger signal than
#     eyeballing fields.
#
#  2. **A headless compositor.** WLR_BACKENDS=headless gives kosmos outputs with
#     no DRM and no seat, so `kallosd --wm --overlay` can bring up a real
#     session — SESSION register, overlay spawn, startup commands, supervision
#     — on a machine that is doing something else.
#
# Two things it cannot redirect, and therefore does not test:
#
#  * **The session bus.** `media`, `power`, `display` and `overlay` commands
#    reach the real desktop through it, so the command sweep leaves them out.
#    The D-Bus *names* (portal / Notifications / ScreenSaver) are likewise
#    real: this script claims them, which is why it refuses to run alongside a
#    live session.
#  * **Device state.** Wi-Fi connect, Bluetooth pair and storage mount change
#    the machine. Enumeration is compared; the write paths are not touched.
#
# Usage: scripts/verify.sh [debug|release]   (default: debug)
#   VDIR=<path>   scratch dir (default /tmp/kallos-verify) — must be SHORT, the
#                 socket path underneath it has to fit in sockaddr_un.sun_path
#   FORCE=1       run even if something Kallos-shaped is already running
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

cfg="${1:-debug}"
V="${VDIR:-/tmp/kallos-verify}"
kosmos_src="${KWM_SRC:-$root/kosmos}"
c_src="${C_SRC:-$root/kstart}"   # the C daemon + CLI, the parity oracle

KD_R="$root/kallosd/target/$cfg/kallosd"
CTL_R="$root/kallosctl/target/$cfg/kallosctl"
HAJIME="$root/hajime/target/$cfg/hajime"
KOSMOS="$kosmos_src/builds/$cfg/src/kosmos"
KD_C="$c_src/builds/$cfg/apps/kdaemon/kdaemon"   # optional: the parity oracle
CTL_C="$c_src/builds/$cfg/apps/kallosctl/kallosctl"

pass=0 fail=0 skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$*"; skip=$((skip + 1)); }
head_() { printf '\n== %s\n' "$*"; }

# ---- preflight ------------------------------------------------------------
for b in "$KD_R" "$CTL_R" "$HAJIME"; do
	[ -x "$b" ] || { echo "!! missing $b — run scripts/build.sh $cfg" >&2; exit 1; }
done

# A live session would fight this script for the D-Bus names and take the
# overlay pushes onto the user's real desktop.
if [ "${FORCE:-0}" != 1 ] && pgrep -x kosmos >/dev/null; then
	echo "!! a compositor is running — this script claims session-bus names and" >&2
	echo "!! pushes overlay verbs. Stop the session, or FORCE=1 to override." >&2
	exit 1
fi

# sockaddr_un.sun_path is 108 bytes: a long scratch path fails at listen(),
# which is a confusing way to learn this.
sock="$V/rt-r/kallos/kdaemon.sock"
[ ${#sock} -lt 100 ] || { echo "!! VDIR too long: $sock would not fit in sun_path" >&2; exit 1; }

rm -rf "$V"
mkdir -p "$V/rt-r" "$V/rt-c" "$V/home/.config/kallos"
chmod 700 "$V/rt-r" "$V/rt-c"

# A scratch HOME so `appearance` writes, the hidden-apps set and the overlay's
# state land here and not in the user's config. Seed it from the real config so
# the lists have something realistic to compare.
cp /dev/null "$V/home/.config/kallos/settings"
if [ -d "$HOME/.config/kallos" ]; then
	cp "$HOME/.config/kallos/"* "$V/home/.config/kallos/" 2>/dev/null || true
fi
# The real startup file would spawn the user's input method into this test
# session; swap in something observable instead.
printf '/usr/bin/touch %s/startup-marker\n' "$V" > "$V/home/.config/kallos/startup"

export HOME="$V/home"
# $XDG_RUNTIME_DIR is redirected, and PulseAudio lives in it — without this the
# sound server simply vanishes and every audio field reads empty.
export PULSE_SERVER="${PULSE_SERVER:-unix:/run/user/$(id -u)/pulse/native}"

cleanup() { pkill -x kallosd 2>/dev/null || true; pkill -x kdaemon 2>/dev/null || true
            pkill -x kosmos 2>/dev/null || true; pkill -x hajime 2>/dev/null || true; }
trap cleanup EXIT

echo ">> verifying the $cfg build; scratch dir $V"

# ---- 1. parity against the C daemon ---------------------------------------
head_ "parity: kallosd vs kdaemon"
XDG_RUNTIME_DIR="$V/rt-r" "$KD_R" --verbose
have_c=0
if [ -x "$KD_C" ] && [ -x "$CTL_C" ]; then
	have_c=1
	XDG_RUNTIME_DIR="$V/rt-c" "$KD_C" --verbose
fi
sleep 2   # let both finish connecting to PulseAudio and priming their caches

[ -S "$V/rt-r/kallos/kdaemon.sock" ] && ok "kallosd is listening" || no "kallosd never listened"

if [ "$have_c" = 1 ]; then
	# Every list, through the real consumer. Byte counts included, so a
	# one-field difference cannot hide inside a matching record count.
	for m in --lists --apps; do
		XDG_RUNTIME_DIR="$V/rt-c" "$HAJIME" $m >"$V/lists.c" 2>&1 || true
		XDG_RUNTIME_DIR="$V/rt-r" "$HAJIME" $m >"$V/lists.r" 2>&1 || true
		if cmp -s "$V/lists.c" "$V/lists.r"; then
			ok "hajime $m byte-identical across daemons"
		else
			no "hajime $m differs:"; diff "$V/lists.c" "$V/lists.r" | head -20
		fi
	done

	# The command surface. Deliberately no media/power/display/overlay: the
	# session bus is not redirected and those reach the real desktop.
	cases=(
		"config reload" "appearance theme dark" "appearance theme auto"
		"appearance accent #FF8800" "noti clear" "wifi" "bt" "storage" "apps"
		"bt confirm" "run something"
	)
	diffs=0
	for c in "${cases[@]}"; do
		# `&& rc=0 || rc=$?` rather than `; rc=$?`: a non-zero exit is data
		# here (some of these commands are meant to fail), and a bare command
		# substitution would trip `set -e`.
		# shellcheck disable=SC2086
		XDG_RUNTIME_DIR="$V/rt-c" "$CTL_R" $c >"$V/a.out" 2>"$V/a.err" && rca=0 || rca=$?
		# shellcheck disable=SC2086
		XDG_RUNTIME_DIR="$V/rt-r" "$CTL_R" $c >"$V/b.out" 2>"$V/b.err" && rcb=0 || rcb=$?
		if ! cmp -s "$V/a.out" "$V/b.out" || ! cmp -s "$V/a.err" "$V/b.err" || [ $rca != $rcb ]; then
			no "daemons differ on '$c' (rc $rca vs $rcb)"; diff "$V/a.out" "$V/b.out" | head -5
			diffs=$((diffs + 1))
		fi
	done
	[ $diffs -eq 0 ] && ok "${#cases[@]} commands identical across daemons" || true
else
	skp "no C kdaemon built — parity comparison skipped"
fi

# ---- 2. the poller parks --------------------------------------------------
head_ "invariant: the poller parks at 0% CPU with no subscribers"
pid=$(pgrep -x kallosd | head -1)
ticks() { awk '{print $14 + $15}' "/proc/$1/stat"; }
t0=$(ticks "$pid"); sleep 10; t1=$(ticks "$pid")
if [ $((t1 - t0)) -le 1 ]; then
	ok "kallosd used $((t1 - t0)) tick(s) over 10s idle"
else
	no "kallosd used $((t1 - t0)) ticks over 10s idle — the poller is not parking"
fi

pkill -x kallosd || true; pkill -x kdaemon || true; sleep 1

# ---- 3. the session root (M10) --------------------------------------------
head_ "session root: kallosd --wm --overlay on a headless compositor"
if [ ! -x "$KOSMOS" ]; then
	skp "no kosmos built — session test skipped"
else
	rm -f "$V/startup-marker"
	log="$V/session.log"
	XDG_RUNTIME_DIR="$V/rt-r" WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 \
		nohup "$KD_R" --verbose --wm "$KOSMOS" --overlay "$HAJIME" >"$log" 2>&1 &
	# The compositor needs a moment to bring up Vulkan and register.
	for _ in $(seq 1 30); do grep -q 'session display registered' "$log" && break; sleep 1; done

	grep -q 'session display registered' "$log" \
		&& ok "compositor registered its WAYLAND_DISPLAY over SESSION" \
		|| no "no SESSION register — see $log"
	pgrep -x hajime >/dev/null \
		&& ok "overlay spawned on the compositor's display" \
		|| no "overlay never spawned"
	grep -q "layer surface 'hajime'" "$log" \
		&& ok "overlay mapped its OVERLAY layer surface" \
		|| no "overlay surface never mapped"
	[ -e "$V/startup-marker" ] \
		&& ok "startup commands ran on the SESSION register" \
		|| no "startup commands did not run"

	# Invariant: spawned children get a reset signal mask. The daemon blocks
	# SIGCHLD for its signalfd, and that mask survives exec — kstart bug #25,
	# where a terminal's Ctrl+C stopped working.
	hp=$(pgrep -x hajime | head -1)
	blk=$(awk '/^SigBlk/{print $2}' "/proc/$hp/status" 2>/dev/null || echo missing)
	[ "$blk" = "0000000000000000" ] \
		&& ok "spawned child has an empty signal mask" \
		|| no "spawned child inherited SigBlk=$blk"

	# Overlay control, end to end: the verb reaches the resident overlay as a
	# TOPIC_OVERLAY push and the compositor sees the surface map and unmap.
	XDG_RUNTIME_DIR="$V/rt-r" "$CTL_R" overlay show >/dev/null; sleep 2
	XDG_RUNTIME_DIR="$V/rt-r" "$CTL_R" overlay hide >/dev/null; sleep 1
	XDG_RUNTIME_DIR="$V/rt-r" "$CTL_R" overlay toggle >/dev/null; sleep 1
	[ "$(grep -c 'overlay verb=' "$log")" -ge 3 ] \
		&& ok "overlay show/hide/toggle reached the resident overlay" \
		|| no "overlay verbs did not reach a subscriber"

	# Startup commands are once per daemon lifetime — a config reload must not
	# re-run them (niri's spawn-at-startup, not sway's exec_always).
	rm -f "$V/startup-marker"
	XDG_RUNTIME_DIR="$V/rt-r" "$CTL_R" config reload >/dev/null; sleep 1
	[ ! -e "$V/startup-marker" ] \
		&& ok "config reload did not re-run the startup commands" \
		|| no "config reload re-ran the startup commands"

	# A primary compositor dying is the session being over.
	kill -TERM "$(pgrep -x kosmos | head -1)" 2>/dev/null || true
	for _ in $(seq 1 10); do pgrep -x kallosd >/dev/null || break; sleep 1; done
	if ! pgrep -x kallosd >/dev/null && ! pgrep -x hajime >/dev/null; then
		ok "compositor death ended the session and reaped the overlay"
	else
		no "children survived the compositor"
	fi
fi

printf '\n>> %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
