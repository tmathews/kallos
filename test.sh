#!/usr/bin/env bash
# Build + install + run a primary-TTY Kallos session with verbose kosmos logging.
# This is THE session script: the whole suite, rooted at the Rust daemon
# (kallosd --wm --overlay). kstart/test.sh is the rollback twin that brings the
# session up on the C kdaemon instead.
#
# Plane offload (the underlay) is ON by default — no env needed; KWM_PLANES=0
# is the kill switch if the plane stack is ever suspect.
#
# Usage: ./test.sh [debug|release]   (default: debug)
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
PREFIX="${PREFIX:-/usr/local}"

# build.sh builds all four binaries — the three cargo crates plus kosmos through
# its own muon tree in ./kosmos — so the session always runs the current tree. It
# runs unprivileged; only the install needs sudo. Nothing here reads ./kstart:
# that tree is the parity oracle for scripts/verify.sh, not part of a session.
scripts/build.sh "$MODE"
sudo scripts/install.sh "$MODE"

# KWM_PLANES_DUMP=1 -> dump each window's surface tree (which subsurface is a
#   dmabuf, its format/modifier) — the first thing to look at when a video
#   doesn't engage. --verbose -> WLR_DEBUG (floods the log; keep runs short).
# --wm points at the freshly installed binary so the flags reach kosmos.
# --overlay takes no argument: the default IS the sibling hajime, spawned bare
#   (resident + hidden; summon with `kallosctl overlay toggle`).
KWM_PLANES_DUMP=1 \
	kallosd --wm "$PREFIX/bin/kosmos --verbose" \
	        --overlay >/tmp/test.log 2>&1

# After it exits (or you stop it), check:
#   grep -E "ENGAGED|flip-only|not scannable|commit failed" /tmp/test.log
#   coredumpctl list kosmos        # should show NO new crash
# Note kosmos's SIGTERM teardown still aborts on a wlroots wlr_session_lock_v1
# assertion — a known pre-existing bug, not a regression from the cutover.
#
# hajime's own output is detached to /dev/null by the daemon spawn; its crash
# handler writes a backtrace to stderr, so run it by hand under the session if
# it ever dies silently (kallosd logs the respawn).
#
# To run a scratch build of the overlay against this session without installing
# it, pass the command explicitly:
#   kallosd --wm ... --overlay "$PWD/hajime/target/debug/hajime"
#
# To check the daemon rather than the session — parity against the C kdaemon, a
# headless session, the startup/supervision invariants — use
# scripts/verify.sh, which needs neither sudo nor the TTY.
