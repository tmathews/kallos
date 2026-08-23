#!/usr/bin/env bash
# The submodule engine: everything that moves a submodule's HEAD, or reports on
# where it is. Backs `./kallos sync`, `status`, `pin` and `push`.
#
# The one rule this file exists to enforce:
#
#     `git submodule update` is used exactly ONCE per submodule — to materialize
#     a directory that isn't there yet — and never again.
#
# `git submodule update --force` and `--remote --merge` are the only ways to
# lose work in a superproject, and neither appears here. Everything after the
# initial clone goes through sync_one(), which refuses to write to a worktree
# that has local changes or local commits.
#
# The other thing it exists for: `git submodule update --init` leaves every
# submodule at DETACHED HEAD, which is hostile to the reason this repo is a
# superproject at all — pushing from one machine and pulling on another. So
# sync_one() always lands a submodule on a real local `main` with upstream
# tracking, never on a detached HEAD.
#
# Usage: scripts/sync.sh <sync|status|pin|push> [args]
#   sync [--latest]     move each submodule to its pin (or to origin/main)
#   status              a table; no writes at all
#   pin [-m MSG]        stage the gitlinks at the submodules' current HEADs
#   push                push each submodule's main, then the root
# Env:
#   DRY=1               report what sync would do; touch nothing
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

# The nine. kstart is frozen legacy and kbrowser has no remote yet; both stay
# as plain sibling clones, ignored by the root (see .gitignore).
mods=(kosmos kallos-lib kallosd kallosctl hajime yggdrasil torrential renzoku phylax)

red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'
ok()  { printf '  %sOK%s   %-12s %s\n'   "$grn" "$off" "$1" "${2-}"; }
act() { printf '  %sMOVE%s %-12s %s\n'   "$grn" "$off" "$1" "${2-}"; }
warn(){ printf '  %sSKIP%s %-12s %s\n'   "$ylw" "$off" "$1" "${2-}"; bad=$((bad + 1)); }
err() { printf '  %sFAIL%s %-12s %s\n'   "$red" "$off" "$1" "${2-}"; bad=$((bad + 1)); }
bad=0

# ---- helpers --------------------------------------------------------------

# Which remote to talk to. Prefer origin; fall back to the only one there is.
# renzoku's remote was named `gh` for a while, which is exactly the case this
# covers — a submodule cloned fresh always gets `origin`, but one adopted in
# place keeps whatever name it had.
remote_of() {
	local m=$1
	git -C "$m" remote get-url origin >/dev/null 2>&1 && { echo origin; return; }
	local rs; rs=$(git -C "$m" remote)
	[ "$(echo "$rs" | wc -l)" = 1 ] && [ -n "$rs" ] && { echo "$rs"; return; }
	return 1
}

# Tracked changes only. Untracked files do NOT block a sync — every repo here
# ignores its build outputs, but .bugs/items/*.toml and scratch files are
# routine and would otherwise wedge every submodule permanently.
is_dirty() {
	! git -C "$1" diff --quiet || ! git -C "$1" diff --cached --quiet
}

# The gitlink the superproject records for this path. Empty before the root's
# initial commit, or for a path that isn't a submodule yet — both are ordinary
# states during the migration, so this must not be an error.
pinned_of() {
	git rev-parse -q --verify "HEAD:$1" 2>/dev/null || true
}

# Put local `main` on the remote as its upstream. Most of these repos were
# cloned or created without it, which is why `git log @{u}..` errors across the
# tree today — and why `status` could not tell you ahead/behind before this.
fix_upstream() {
	local m=$1 rem=$2
	git -C "$m" rev-parse --verify -q main >/dev/null || return 0
	[ "$(git -C "$m" config --get branch.main.remote || true)" = "$rem" ] &&
		[ "$(git -C "$m" config --get branch.main.merge || true)" = refs/heads/main ] &&
		return 0
	git -C "$m" branch --set-upstream-to="$rem/main" main >/dev/null 2>&1 || true
}

on_main()  { [ "$(git -C "$1" symbolic-ref -q --short HEAD || true)" = main ]; }
sha()      { git -C "$1" rev-parse "${2:-HEAD}" 2>/dev/null; }
is_anc()   { git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; }

# Commits reachable from HEAD or main but not from the remote's main — i.e.
# work that exists only on this machine. This is the number that makes a pin
# unclonable, so it gates every worktree write below.
unique_of() {
	local m=$1 rem=$2 refs=(HEAD)
	git -C "$m" rev-parse --verify -q main >/dev/null && refs+=(main)
	git -C "$m" rev-list --count "^$rem/main" "${refs[@]}" 2>/dev/null || echo 0
}

# ---- sync -----------------------------------------------------------------
# One submodule. $2 is "pin" or "latest".
sync_one() {
	local m=$1 mode=$2 rem target head n

	# 0. Materialize. The ONLY `submodule update` in this file — this is the
	#    path a plain `git clone` (no --recursive) lands on.
	if [ ! -e "$m/.git" ]; then
		if [ "${DRY:-0}" = 1 ]; then
			act "$m" "would clone"
			return
		fi
		git submodule update --init -- "$m" >/dev/null ||
			{ err "$m" "clone failed"; return; }
	fi

	rem=$(remote_of "$m") || { err "$m" "no usable remote — add one named 'origin'"; return; }
	[ "${DRY:-0}" = 1 ] || git -C "$m" fetch --prune --quiet "$rem" 2>/dev/null || true

	if [ "$mode" = latest ]; then
		target=$(sha "$m" "$rem/main") || { err "$m" "no $rem/main"; return; }
	else
		target=$(pinned_of "$m")
		[ -n "$target" ] || { warn "$m" "no pin recorded yet — run ./kallos pin"; return; }
	fi
	head=$(sha "$m")

	# 3. Nothing to do, and already in a shape that's good to work in. Note any
	#    local changes on the way past: they are not a problem here — nothing
	#    needs to move — but a bare OK next to a half-finished edit reads as
	#    "this submodule is untouched", which is the opposite of true.
	if [ "$head" = "$target" ] && on_main "$m" &&
	   [ -n "$(git -C "$m" config --get branch.main.remote || true)" ]; then
		if is_dirty "$m"; then
			ok "$m" "${dim}${head:0:8}${off} ${ylw}(local changes, left alone)${off}"
		else
			ok "$m" "${dim}${head:0:8}${off}"
		fi
		return
	fi

	# 4. Guard: local changes. Never stash, never reset — the whole point of a
	#    dev checkout is that an interrupted edit survives an update.
	if is_dirty "$m"; then
		[ "${DRY:-0}" = 1 ] || fix_upstream "$m" "$rem"
		warn "$m" "local changes — commit or stash, then re-run"
		return
	fi

	# 5. Guard: commits that exist only here. Moving HEAD would orphan them,
	#    and pinning them would produce a superproject nobody else can clone.
	n=$(unique_of "$m" "$rem")
	if [ "$n" -gt 0 ]; then
		if is_anc "$m" "$target" "$head"; then
			# Ahead of the target, in a straight line: safe to attach to main
			# so the commits are on a branch, but don't move HEAD.
			if [ "${DRY:-0}" != 1 ]; then
				on_main "$m" || git -C "$m" switch -q main 2>/dev/null || true
				fix_upstream "$m" "$rem"
			fi
			warn "$m" "$n unpushed commit(s) — ./kallos push, then ./kallos pin"
		else
			err "$m" "diverged from $rem/main — resolve by hand"
		fi
		return
	fi

	# 6. Clean, and nothing local-only exists on HEAD or main. `switch -C` is
	#    safe *because* of that, and it handles both directions with one
	#    command: a fresh `--init` leaves HEAD detached at the pin while local
	#    `main` sits at the remote tip, so when the pin is OLDER than the tip
	#    a fast-forward cannot reach it and only a reset will do.
	if [ "${DRY:-0}" = 1 ]; then
		act "$m" "would move ${dim}${head:0:8} -> ${target:0:8}${off}"
		return
	fi
	if ! git -C "$m" switch -q -C main "$target" 2>/dev/null; then
		# The one expected failure: an untracked file in the way of a file the
		# target commit adds. Report it rather than letting set -e kill the
		# run halfway through the suite.
		err "$m" "checkout blocked (untracked file in the way?)"
		return
	fi
	fix_upstream "$m" "$rem"
	# A fresh clone lands here with head == target already: `submodule update`
	# left it detached at the pin, and the only thing that changed is that it
	# is now on a branch. Saying "da31c35 -> da31c35" would be noise.
	if [ "$head" = "$target" ]; then
		act "$m" "attached to main ${dim}${target:0:8}${off}"
	else
		act "$m" "${dim}${head:0:8} -> ${target:0:8}${off}"
	fi
}

cmd_sync() {
	local mode=pin
	[ "${1-}" = --latest ] && mode=latest
	# Not ${DRY:+...}: DRY=0 is set-and-non-empty, so that would always fire.
	echo ">> syncing submodules ($mode$([ "${DRY:-0}" = 1 ] && echo ", dry run"))"
	for m in "${mods[@]}"; do sync_one "$m" "$mode"; done
	if [ "$mode" = latest ] && [ "${DRY:-0}" != 1 ]; then
		echo ">> pins are now stale by construction; review and record them:"
		echo "   git submodule summary"
		echo "   ./kallos pin -m 'bump submodules'"
	fi
	[ "$bad" -eq 0 ] || echo ">> $bad submodule(s) need attention"
	return $((bad > 0))
}

# ---- status ---------------------------------------------------------------
# Read-only. This is the command to run on the machine you just sat down at.
cmd_status() {
	printf '%-12s %-16s %-7s %-9s %s\n' SUBMODULE BRANCH STATE AHEAD/BEH PIN
	for m in "${mods[@]}"; do
		if [ ! -e "$m/.git" ]; then
			printf '%-12s %s\n' "$m" "${ylw}absent — ./kallos sync${off}"
			continue
		fi
		# Plain text in the columns, deliberately: padding with %-Ns counts the
		# bytes of an ANSI escape too, so colouring a padded field misaligns
		# the whole table. Colour goes on the trailing PIN field only.
		local br rem ahead behind state pin head drift
		br=$(git -C "$m" symbolic-ref -q --short HEAD || echo "(detached)")
		state=clean; is_dirty "$m" && state=DIRTY
		ahead=?; behind=?
		if rem=$(remote_of "$m") && git -C "$m" rev-parse --verify -q "$rem/main" >/dev/null; then
			ahead=$(git -C "$m" rev-list --count "$rem/main..HEAD" 2>/dev/null || echo ?)
			behind=$(git -C "$m" rev-list --count "HEAD..$rem/main" 2>/dev/null || echo ?)
		fi
		pin=$(pinned_of "$m"); head=$(sha "$m")
		if   [ -z "$pin" ];          then drift="${dim}unpinned${off}"
		elif [ "$pin" = "$head" ];   then drift="${dim}${pin:0:8}${off}"
		else                              drift="${ylw}DRIFT${off} ${dim}pinned ${pin:0:8}${off}"
		fi
		printf '%-12s %-16s %-7s %-9s %b\n' "$m" "$br" "$state" "+$ahead/-$behind" "$drift"
	done
	echo "${dim}   ahead/behind is vs the submodule's own origin/main; PIN is what this repo records${off}"
}

# ---- pin ------------------------------------------------------------------
# Record wherever the submodules currently are. Refuses to record a SHA that
# isn't on the remote — that is the failure that makes a fresh clone die with
# "fetched in submodule path 'x', but it did not contain <sha>", and it is much
# easier to prevent here than to debug on the new machine.
cmd_pin() {
	local msg="" m rem staged=0
	[ "${1-}" = -m ] && { msg="${2-}"; }
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		if rem=$(remote_of "$m"); then
			if ! git -C "$m" merge-base --is-ancestor HEAD "$rem/main" 2>/dev/null; then
				err "$m" "HEAD is not on $rem/main — ./kallos push first"
				continue
			fi
		fi
		git add -- "$m"
		staged=$((staged + 1))
	done
	[ "$bad" -eq 0 ] || { echo ">> nothing pinned"; return 1; }
	echo ">> staged $staged gitlink(s)"
	git -c color.ui=always diff --cached --submodule=log -- "${mods[@]}" 2>/dev/null |
		head -40 || true
	if [ -n "$msg" ]; then
		git commit -q -m "$msg"
		echo ">> committed: $msg"
	else
		echo ">> staged only; commit when you're happy with the summary above"
	fi
	return 0
}

# ---- push -----------------------------------------------------------------
cmd_push() {
	local m rem n
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || { err "$m" "no remote"; continue; }
		n=$(unique_of "$m" "$rem")
		[ "$n" -gt 0 ] || { ok "$m" "${dim}nothing to push${off}"; continue; }
		on_main "$m" || { warn "$m" "$n local commit(s) but HEAD is detached"; continue; }
		if git -C "$m" push -q "$rem" main; then
			act "$m" "pushed $n commit(s)"
		else
			err "$m" "push failed"
		fi
	done
	[ "$bad" -eq 0 ] || { echo ">> fix the above before pinning"; return 1; }
	echo ">> all submodules published"
}

case "${1-}" in
	sync)   shift; cmd_sync "$@" ;;
	status) shift; cmd_status "$@" ;;
	pin)    shift; cmd_pin "$@" ;;
	push)   shift; cmd_push "$@" ;;
	*) echo "!! usage: scripts/sync.sh <sync|status|pin|push>" >&2; exit 2 ;;
esac
