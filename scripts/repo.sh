#!/usr/bin/env bash
# The repo engine: everything that moves a submodule's HEAD, publishes it, or
# reports on where it is. Backs `./dev status`, `./dev pull`, `./dev push` and
# the `sync` step inside `./dev install`.
#
# THE MODEL, in one paragraph. This tree is a superproject: nine submodules and
# a recorded commit ("pin") for each. Day to day there are exactly two verbs.
# `pull` brings every submodule to its own origin/main and brings the root up
# to date with the root's origin/main. `push` publishes every submodule, then
# records the new pins in one root commit whose message is written for you, and
# pushes that. Everything else — sync, pin, the ordering between them — is an
# implementation detail of those two, not something to think about.
#
# The three rules this file exists to enforce:
#
#   1. `git submodule update` is used exactly ONCE per submodule — to
#      materialize a directory that isn't there yet — and never again.
#      `--force` and `--remote --merge` are the only ways to lose work in a
#      superproject and neither appears here.
#
#   2. A submodule on a branch that is not `main` stops the run. Not a warning
#      you can scroll past: pull and push both refuse to touch the tree until
#      it is back on main, because every other guarantee here assumes main.
#
#   3. Uncommitted work stops a `push` and is reported by everything else.
#      Publishing a pin that silently excludes the edit you were in the middle
#      of is the exact surprise this tool exists to prevent.
#
# Usage: scripts/repo.sh <status|pull|push|sync> [args]
#   status              a table plus what to do next; fetches, changes nothing
#   pull                every submodule to its origin/main, root to its own
#   push                publish submodules, pin them, commit, push the root
#   sync [--latest]     move each submodule to its recorded pin (what `up` runs)
# Env:
#   DRY=1               report what would happen; touch nothing
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"

# The nine. kbrowser has no remote yet, so it stays a plain sibling clone,
# ignored by the root (see .gitignore).
mods=(kosmos kallos-lib kallosd kallosctl hajime yggdrasil torrential renzoku phylax)

# One row per submodule. These shadow nothing in lib/out.sh: the plain labels
# there take a message, these take a name and a detail, so they get their own
# names rather than quietly meaning something different in this one file.
# MOVE is green because it is the work being done, not a warning.
r_ok()   { row_grn OK   "$1" "${2-}"; }
r_move() { row_grn MOVE "$1" "${2-}"; }
r_skip() { row_ylw SKIP "$1" "${2-}"; bad=$((bad + 1)); }
r_fail() { row_red FAIL "$1" "${2-}"; bad=$((bad + 1)); }
ylw="$_ylw"; dim="$_dim"; off="$_off"
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

# Tracked changes only. Untracked files do NOT count as dirty — every repo here
# ignores its build outputs, but .bugs/items/*.toml and scratch files are
# routine and would otherwise wedge every operation permanently.
is_dirty() {
	! git -C "$1" diff --quiet || ! git -C "$1" diff --cached --quiet
}

# The gitlink the superproject records for this path. Empty before the root's
# initial commit, or for a path that isn't a submodule yet.
pinned_of() {
	git rev-parse -q --verify "HEAD:$1" 2>/dev/null || true
}

# Put local `main` on the remote as its upstream. Most of these repos were
# cloned or created without it, which is why `git log @{u}..` errors across the
# tree today — and why ahead/behind could not be reported before this.
fix_upstream() {
	local m=$1 rem=$2
	git -C "$m" rev-parse --verify -q main >/dev/null || return 0
	[ "$(git -C "$m" config --get branch.main.remote || true)" = "$rem" ] &&
		[ "$(git -C "$m" config --get branch.main.merge || true)" = refs/heads/main ] &&
		return 0
	git -C "$m" branch --set-upstream-to="$rem/main" main >/dev/null 2>&1 || true
}

branch_of() { git -C "$1" symbolic-ref -q --short HEAD || echo "(detached)"; }
on_main()   { [ "$(branch_of "$1")" = main ]; }
sha()       { git -C "$1" rev-parse "${2:-HEAD}" 2>/dev/null; }
is_anc()    { git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; }
count()     { git -C "$1" rev-list --count "$2" 2>/dev/null || echo 0; }

# "1 commit", "4 commits". Worth the three lines: "commit(s)" in a generated
# commit message reads as a template nobody filled in, which is most of what
# made the old hand-written pin messages feel like noise.
plural()    { [ "$1" = 1 ] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }

# Commits reachable from HEAD or main but not from the remote's main — i.e.
# work that exists only on this machine. This is the number that makes a pin
# unclonable, so it gates every worktree write below.
unique_of() {
	local m=$1 rem=$2 refs=(HEAD)
	git -C "$m" rev-parse --verify -q main >/dev/null && refs+=(main)
	git -C "$m" rev-list --count "^$rem/main" "${refs[@]}" 2>/dev/null || echo 0
}

# Changes to the root's OWN files — scripts/, README, .gitmodules. Deliberately
# not the gitlinks: a moved pin is the normal state between a pull and a push
# and is what `push` is for, while an edited script is work that needs its own
# commit and its own message.
root_own_changes() {
	local f skip
	git diff --name-only HEAD 2>/dev/null | while read -r f; do
		skip=0
		for m in "${mods[@]}"; do [ "$f" = "$m" ] && skip=1; done
		[ "$skip" = 1 ] || echo "$f"
	done
}

# The first few of a newline-separated list, as one line. A guard that dumps
# eleven paths across two wrapped terminal lines stops being a thing you read.
few() {
	local n; n=$(printf '%s\n' "$1" | grep -c .)
	local head; head=$(printf '%s\n' "$1" | head -4 | tr '\n' ' ')
	head="${head% }"
	[ "$n" -le 4 ] && printf '%s' "$head" || printf '%s +%d more' "$head" "$((n - 4))"
}

root_remote() { git remote get-url origin >/dev/null 2>&1 && echo origin || return 1; }

# ---- guards ---------------------------------------------------------------
# Rule 2, in one place. Every submodule that exists must be on main or on a
# detached HEAD that pull/sync is allowed to attach. A named branch that is not
# main means somebody is mid-something, and guessing what to do with it is
# exactly the kind of cleverness that loses work.
guard_branches() {
	local m br n=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		br=$(branch_of "$m")
		[ "$br" = main ] || [ "$br" = "(detached)" ] || {
			r_fail "$m" "on branch '$br', not main"
			n=$((n + 1))
		}
	done
	[ "$n" = 0 ] && return 0
	act "$(plural "$n" submodule) off main — this tree only tracks main"
	note "finish or park that branch, then switch back:"
	note "  git -C <submodule> switch main"
	return 1
}

# Rule 3. Reports every dirty repo with the command that commits it — and the
# root gets different advice from a submodule, because `git -C <submodule>` is
# wrong for it and following wrong advice is worse than getting none.
guard_clean() {
	local m n=0 subs=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		is_dirty "$m" && { r_fail "$m" "uncommitted changes"; n=$((n + 1)); subs=$((subs + 1)); }
	done
	local own; own=$(root_own_changes)
	[ -z "$own" ] || { r_fail "(root)" "uncommitted changes: $(few "$own")"; n=$((n + 1)); }
	[ "$n" = 0 ] && return 0
	act "uncommitted work in $(plural "$n" repo)"
	note "commit it where it lives, then run push again:"
	[ "$subs" = 0 ] || note "  git -C <submodule> add -A && git -C <submodule> commit"
	[ -z "$own" ]   || note "  git commit -a                 # this repo's own files"
	return 1
}

# ---- pull -----------------------------------------------------------------

# The root, first. It has to move before the submodules do: once the submodules
# are at their tips the root's gitlinks read as modified, and git then refuses
# to fast-forward over them. Doing the root first means it merges against a
# tree whose only drift is drift we are about to overwrite anyway.
pull_root() {
	local rem ahead behind
	rem=$(root_remote) || { r_skip "(root)" "no remote yet"; return 0; }
	git rev-parse --verify -q HEAD >/dev/null || { r_skip "(root)" "no commits yet"; return 0; }
	git fetch --prune --quiet "$rem" 2>/dev/null || true
	git rev-parse --verify -q "$rem/main" >/dev/null || { r_skip "(root)" "no $rem/main"; return 0; }

	ahead=$(count . "$rem/main..HEAD")
	behind=$(count . "HEAD..$rem/main")
	[ "$behind" = 0 ] && { r_ok "(root)" "${dim}up to date${off}"; return 0; }

	if [ "${DRY:-0}" = 1 ]; then
		[ "$ahead" = 0 ] &&
			r_move "(root)" "would fast-forward $(plural "$behind" commit)" ||
			r_move "(root)" "would rebase $(plural "$ahead" "local commit") onto $behind new"
		return 0
	fi

	if [ "$ahead" = 0 ]; then
		# Pure fast-forward. `merge --ff-only` still refuses when a gitlink is
		# locally modified, and drifted gitlinks are the normal state here, so
		# fall back to a hard reset — safe *because* guard_clean has already
		# established the root's own files are clean and because a reset does
		# not recurse into submodule worktrees (submodule.recurse is off).
		if git merge --ff-only --quiet "$rem/main" >/dev/null 2>&1 ||
		   git reset --hard --quiet "$rem/main" >/dev/null 2>&1; then
			r_move "(root)" "fast-forwarded $(plural "$behind" commit)"
		else
			r_fail "(root)" "could not fast-forward — resolve by hand"
		fi
		return
	fi

	# Diverged: local pin commits and remote pin commits. Rebase, resolving any
	# gitlink collision to whatever this machine's submodule is currently at —
	# the value is irrelevant, because the pins get recomputed from the tips a
	# few lines below and rewritten by the next push. A collision in a real
	# file is different work and stops the run.
	if git rebase --quiet "$rem/main" >/dev/null 2>&1; then
		r_move "(root)" "rebased $(plural "$ahead" "local commit") onto $behind new"
		return
	fi
	while [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; do
		local stuck resolved=1 f
		stuck=$(git diff --name-only --diff-filter=U)
		[ -n "$stuck" ] || { resolved=0; }
		for f in $stuck; do
			case " ${mods[*]} " in
				*" $f "*) git update-index --cacheinfo "160000,$(sha "$f"),$f" ;;
				*) resolved=0 ;;
			esac
		done
		[ "$resolved" = 1 ] || break
		GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || break
	done
	if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
		git rebase --abort >/dev/null 2>&1 || true
		r_fail "(root)" "conflict in the root's own files — resolve by hand"
		note "  git rebase $rem/main"
		return
	fi
	r_move "(root)" "rebased $(plural "$ahead" "local commit") onto $behind new"
}

# One submodule, to its own origin/main.
pull_one() {
	local m=$1 rem head target ahead behind br

	if [ ! -e "$m/.git" ]; then
		if [ "${DRY:-0}" = 1 ]; then r_move "$m" "would clone"; return; fi
		# The ONLY `submodule update` in this file — the path a plain
		# `git clone` (no --recursive) lands on.
		git submodule update --init -- "$m" >/dev/null ||
			{ r_fail "$m" "clone failed"; return; }
	fi

	rem=$(remote_of "$m") || { r_fail "$m" "no usable remote — add one named 'origin'"; return; }
	git -C "$m" fetch --prune --quiet "$rem" 2>/dev/null || true
	target=$(sha "$m" "$rem/main") || { r_fail "$m" "no $rem/main"; return; }
	head=$(sha "$m")
	br=$(branch_of "$m")

	# A detached HEAD is what `submodule update --init` leaves behind, and it is
	# hostile to the reason this repo is a superproject at all — pushing from
	# one machine and pulling on another. Attach it, unless there are commits
	# here that exist nowhere else, in which case attaching would pick a side.
	if [ "$br" = "(detached)" ]; then
		if [ "$(unique_of "$m" "$rem")" != 0 ]; then
			r_fail "$m" "detached HEAD with local-only commits — resolve by hand"
			return
		fi
		[ "${DRY:-0}" = 1 ] && { r_move "$m" "would attach to main"; return; }
		git -C "$m" switch -q -C main "$target" 2>/dev/null || {
			r_fail "$m" "checkout blocked (untracked file in the way?)"; return; }
		fix_upstream "$m" "$rem"
		r_move "$m" "attached to main ${dim}${target:0:8}${off}"
		return
	fi

	[ "${DRY:-0}" = 1 ] || fix_upstream "$m" "$rem"
	ahead=$(count "$m" "$rem/main..HEAD")
	behind=$(count "$m" "HEAD..$rem/main")

	if [ "$behind" = 0 ]; then
		if is_dirty "$m"; then
			r_ok "$m" "${dim}${head:0:8}${off} ${ylw}(uncommitted changes)${off}"
		elif [ "$ahead" != 0 ]; then
			r_ok "$m" "${dim}${head:0:8}${off} ${ylw}($ahead to push)${off}"
		else
			r_ok "$m" "${dim}${head:0:8}${off}"
		fi
		return
	fi

	if [ "${DRY:-0}" = 1 ]; then
		[ "$ahead" = 0 ] &&
			r_move "$m" "would fast-forward $(plural "$behind" commit)" ||
			r_move "$m" "would rebase $(plural "$ahead" "local commit") onto $behind new"
		return
	fi

	if [ "$ahead" = 0 ]; then
		# Straight fast-forward. An uncommitted edit to a file the new commits
		# also touch is the one case this can't do, and `merge --ff-only` says
		# so itself — report it and move on rather than stashing behind the
		# user's back.
		if git -C "$m" merge --ff-only --quiet "$rem/main" >/dev/null 2>&1; then
			r_move "$m" "${dim}${head:0:8} -> ${target:0:8}${off} ($(plural "$behind" commit))"
		else
			r_skip "$m" "uncommitted changes block the update — commit them, then pull again"
		fi
		return
	fi

	# Diverged. Rebasing the local commits onto the tip is what "work with
	# latest main" means, and --autostash keeps an in-progress edit through it.
	# A conflict aborts cleanly: --autostash restores the worktree on abort too,
	# so a failed rebase leaves the submodule exactly as it was found.
	if git -C "$m" rebase --autostash --quiet "$rem/main" >/dev/null 2>&1; then
		r_move "$m" "rebased $(plural "$ahead" "local commit") onto $behind new"
	else
		git -C "$m" rebase --abort >/dev/null 2>&1 || true
		r_fail "$m" "conflict rebasing $(plural "$ahead" "local commit") onto $rem/main"
		note "  git -C $m rebase $rem/main    # resolve, then run pull again"
	fi
}

cmd_pull() {
	hdr "pull$([ "${DRY:-0}" = 1 ] && echo " (dry run)")"
	guard_branches || return 1
	pull_root
	for m in "${mods[@]}"; do pull_one "$m"; done

	local moved=0 m
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		[ "$(pinned_of "$m")" = "$(sha "$m")" ] || moved=$((moved + 1))
	done
	if [ "$bad" -gt 0 ]; then
		act "attention needed in $(plural "$bad" repo) — see above"
	elif [ "$moved" -gt 0 ]; then
		act "$(plural "$moved" pin) moved ahead of what this repo records"
		note "that is expected after a pull; ./dev push records them"
		note "run ./dev install to rebuild and install the new code"
	else
		act "everything is at its latest main"
	fi
	return $((bad > 0))
}

# ---- the pin message ------------------------------------------------------
# The whole reason for the "I never know what to write" problem: nobody should
# have to write this. A pin commit describes work that is already described —
# in the submodules' own commit messages — so the message is derived from them,
# never invented.
#
#   pin kosmos +4, phylax +1
#
#   kosmos   a1b2c3de..9f8e7d6c  4 commits
#       Fix damage tracking on rotated outputs
#       ...
#
# One module with one commit gets that commit's subject as the subject line,
# because "pin kosmos +1" is strictly less informative than what it is pinning.
pin_message() {
	local m old new n sub names=() total=0 body="" first_sub="" changed=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		old=$(pinned_of "$m"); new=$(sha "$m")
		[ "$new" != "$old" ] || continue
		changed=$((changed + 1))
		if [ -n "$old" ] && is_anc "$m" "$old" "$new"; then
			n=$(count "$m" "$old..$new")
			sub=$(git -C "$m" log --format='%s' "$old..$new" 2>/dev/null | head -20 | sed 's/^/    /')
			names+=("$m +$n"); total=$((total + n))
			body+="$m  ${old:0:8}..${new:0:8}  $(plural "$n" commit)"$'\n'"$sub"$'\n\n'
			[ "$n" = 1 ] && first_sub=$(git -C "$m" log -1 --format='%s' "$new")
		elif [ -z "$old" ]; then
			names+=("$m new")
			body+="$m  new at ${new:0:8}"$'\n\n'
		else
			# The pin moved sideways: the submodule was rebased, or a commit
			# was reverted, so the old pin is not an ancestor of the new one
			# and `old..new` would be a lie. The merge base still gives an
			# honest range — the commits that are on the new pin and were not
			# on the old — which is what somebody reading this wants to see.
			local base
			if base=$(git -C "$m" merge-base "$old" "$new" 2>/dev/null); then
				n=$(count "$m" "$base..$new")
				sub=$(git -C "$m" log --format='%s' "$base..$new" 2>/dev/null | head -20 | sed 's/^/    /')
				names+=("$m ~$n"); total=$((total + n))
				body+="$m  ${old:0:8} -> ${new:0:8}  $(plural "$n" commit), history rewritten"$'\n'"$sub"$'\n\n'
			else
				names+=("$m moved")
				body+="$m  ${old:0:8} -> ${new:0:8}  (unrelated histories)"$'\n\n'
			fi
		fi
	done
	[ "$changed" != 0 ] || return 1

	local subject
	if [ "$changed" = 1 ] && [ -n "$first_sub" ]; then
		subject="${names[0]%% *}: $first_sub"
	else
		subject="pin $(IFS=, ; echo "${names[*]}" | sed 's/,/, /g')"
		[ "$total" -gt 0 ] && subject="$subject  ($(plural "$total" commit))"
	fi
	# git's own soft limit. A long list of modules is the case that overruns it.
	[ "${#subject}" -le 72 ] || subject="${subject:0:69}..."

	printf '%s\n\n%s' "$subject" "$body"
}

# ---- push -----------------------------------------------------------------

cmd_push() {
	hdr "push"
	guard_branches || return 1
	guard_clean || return 1

	# 1. The submodules first, always. A pin is only clonable once the commit
	#    it names is on a remote, so this ordering is not a preference.
	local m rem n pushed=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || { r_fail "$m" "no remote"; continue; }
		n=$(unique_of "$m" "$rem")
		[ "$n" -gt 0 ] || continue
		if [ "${DRY:-0}" = 1 ]; then r_move "$m" "would push $(plural "$n" commit)"; pushed=$((pushed + 1)); continue; fi
		if git -C "$m" push -q "$rem" main 2>/dev/null; then
			r_move "$m" "pushed $(plural "$n" commit)"; pushed=$((pushed + 1))
		else
			r_fail "$m" "push rejected — $rem/main moved; run ./dev pull first"
		fi
	done
	[ "$bad" = 0 ] || { act "nothing was pinned"; return 1; }

	# 2. Record where they all are now. The ancestry check is the one that
	#    prevents the failure that only shows up on someone else's machine:
	#    "fetched in submodule path 'x', but it did not contain <sha>".
	local staged=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		# Under DRY the pushes above did not happen, so this check would fail
		# on exactly the submodules the dry run just said it would publish.
		# The premise of a dry run is that the step before it worked.
		if [ "${DRY:-0}" != 1 ] && rem=$(remote_of "$m") && ! is_anc "$m" "$(sha "$m")" "$rem/main"; then
			r_fail "$m" "HEAD is not on $rem/main — cannot pin it"
			continue
		fi
		[ "$(pinned_of "$m")" = "$(sha "$m")" ] && continue
		[ "${DRY:-0}" = 1 ] || git add -- "$m"
		staged=$((staged + 1))
	done
	[ "$bad" = 0 ] || { [ "${DRY:-0}" = 1 ] || git reset -q -- "${mods[@]}"; act "nothing was pinned"; return 1; }

	# 3. One root commit, message written from the submodule logs.
	local msg=""
	if [ "$staged" -gt 0 ]; then
		msg=$(pin_message) || msg=""
	fi
	if [ "${DRY:-0}" = 1 ]; then
		[ -n "$msg" ] && { act "would commit:"; printf '%s\n' "$msg" | sed 's/^/        /'; }
		[ "$staged" = 0 ] && act "no pins to record"
		return 0
	fi
	if [ -n "$msg" ]; then
		git commit -q -m "$msg"
		r_move "(root)" "pinned $(plural "$staged" submodule)"
		printf '%s\n' "$msg" | sed "s/^/        ${dim}/;s/\$/${off}/"
	fi

	# 4. Publish the root. A rejection here means another machine pinned in the
	#    meantime; pull knows how to merge two sets of pins, so say so rather
	#    than leaving a commit stranded with no explanation.
	local rrem; rrem=$(root_remote) || { act "no root remote — submodules published"; return 0; }
	local rahead; rahead=$(count . "$rrem/main..HEAD" 2>/dev/null || echo 0)
	if [ "$rahead" = 0 ]; then
		[ "$pushed" = 0 ] && [ "$staged" = 0 ] && act "nothing to push — everything is already published"
		[ "$rahead" = 0 ] && r_ok "(root)" "${dim}nothing to push${off}"
		return 0
	fi
	if git push -q "$rrem" main 2>/dev/null; then
		r_move "(root)" "pushed $(plural "$rahead" commit)"
		act "everything is published"
	else
		r_fail "(root)" "push rejected — $rrem/main moved"
		note "run: ./dev pull    (it merges two sets of pins), then ./dev push"
		return 1
	fi
}

# ---- status ---------------------------------------------------------------
# Fetches, then reports, then tells you which of the two verbs to run. It never
# touches a worktree, an index or a commit. This is the command to run on the
# machine you just sat down at.
cmd_status() {
	local m br rem ahead behind state pin head drift
	local n_branch=0 n_dirty=0 n_ahead=0 n_behind=0 n_drift=0 n_absent=0

	# Fetch first. This is the one write this command makes, and it only moves
	# remote-tracking refs — no worktree, no index, nothing recoverable at
	# stake. Without it "behind" is measured against whenever you last fetched,
	# and a status that says +0/-0 while the tips have moved is a trap rather
	# than a report. Offline, every fetch fails quietly and the numbers are
	# simply as stale as the machine is.
	git fetch --prune --quiet origin 2>/dev/null || true
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") && git -C "$m" fetch --prune --quiet "$rem" 2>/dev/null || true
	done

	printf '%-12s %-16s %-7s %-9s %s\n' SUBMODULE BRANCH STATE AHEAD/BEH PIN
	for m in "${mods[@]}"; do
		if [ ! -e "$m/.git" ]; then
			printf '%-12s %s\n' "$m" "${ylw}absent — ./dev pull${off}"
			n_absent=$((n_absent + 1)); continue
		fi
		# Plain text in the columns, deliberately: padding with %-Ns counts the
		# bytes of an ANSI escape too, so colouring a padded field misaligns the
		# whole table. Colour goes on the trailing PIN field only.
		br=$(branch_of "$m")
		[ "$br" = main ] || n_branch=$((n_branch + 1))
		state=clean; is_dirty "$m" && { state=DIRTY; n_dirty=$((n_dirty + 1)); }
		ahead=?; behind=?
		if rem=$(remote_of "$m") && git -C "$m" rev-parse --verify -q "$rem/main" >/dev/null; then
			ahead=$(count "$m" "$rem/main..HEAD"); behind=$(count "$m" "HEAD..$rem/main")
			[ "$ahead" = 0 ] || n_ahead=$((n_ahead + 1))
			[ "$behind" = 0 ] || n_behind=$((n_behind + 1))
		fi
		pin=$(pinned_of "$m"); head=$(sha "$m")
		if   [ -z "$pin" ];        then drift="${dim}unpinned${off}"; n_drift=$((n_drift + 1))
		elif [ "$pin" = "$head" ]; then drift="${dim}${pin:0:8}${off}"
		else                            drift="${ylw}DRIFT${off} ${dim}pinned ${pin:0:8}${off}"; n_drift=$((n_drift + 1))
		fi
		printf '%-12s %-16s %-7s %-9s %b\n' "$m" "$br" "$state" "+$ahead/-$behind" "$drift"
	done
	echo "${dim}   ahead/behind is vs the submodule's own origin/main; PIN is what this repo records${off}"

	# The part that matters: what to do about it.
	sec "what to do"
	local acted=0
	if [ "$n_branch" -gt 0 ]; then
		fail "$(plural "$n_branch" submodule) not on main — pull and push both refuse to run"
		note "run: git -C <submodule> switch main"
		acted=1
	fi
	if [ "$n_dirty" -gt 0 ]; then
		todo "uncommitted work in $(plural "$n_dirty" submodule)"
		note "commit it where it lives: git -C <submodule> commit -a"
		acted=1
	fi
	local own; own=$(root_own_changes)
	if [ -n "$own" ]; then
		todo "this repo's own files are modified: $(few "$own")"
		note "commit them here before pushing"
		acted=1
	fi
	if [ "$n_behind" -gt 0 ] || [ "$n_absent" -gt 0 ]; then
		todo "$(plural $((n_behind + n_absent)) submodule) behind origin/main"
		note "run: ./dev pull"
		acted=1
	fi
	if [ "$n_ahead" -gt 0 ] || [ "$n_drift" -gt 0 ]; then
		todo "unpushed commits in $(plural "$n_ahead" submodule), $(plural "$n_drift" pin) stale"
		note "run: ./dev push    (publishes, pins and commits in one go)"
		acted=1
	fi
	[ "$acted" = 1 ] || ok "everything is on main, committed, published and pinned"
}

# ---- sync -----------------------------------------------------------------
# Move each submodule TO ITS RECORDED PIN. This is what `./dev install` runs and what
# a fresh clone needs; it is not part of the daily push/pull loop, which always
# goes to the tips. Kept as its own verb because "give me exactly the
# combination this repo says works" is a real thing to want after a bad pull.
sync_one() {
	local m=$1 mode=$2 rem target head n

	if [ ! -e "$m/.git" ]; then
		if [ "${DRY:-0}" = 1 ]; then r_move "$m" "would clone"; return; fi
		git submodule update --init -- "$m" >/dev/null ||
			{ r_fail "$m" "clone failed"; return; }
	fi

	rem=$(remote_of "$m") || { r_fail "$m" "no usable remote — add one named 'origin'"; return; }
	git -C "$m" fetch --prune --quiet "$rem" 2>/dev/null || true

	if [ "$mode" = latest ]; then
		target=$(sha "$m" "$rem/main") || { r_fail "$m" "no $rem/main"; return; }
	else
		target=$(pinned_of "$m")
		[ -n "$target" ] || { r_skip "$m" "no pin recorded yet — run ./dev push"; return; }
	fi
	head=$(sha "$m")

	# Nothing to do, and already in a shape that's good to work in. Note any
	# local changes on the way past: they are not a problem here — nothing needs
	# to move — but a bare OK next to a half-finished edit reads as "this
	# submodule is untouched", which is the opposite of true.
	if [ "$head" = "$target" ] && on_main "$m" &&
	   [ -n "$(git -C "$m" config --get branch.main.remote || true)" ]; then
		if is_dirty "$m"; then
			r_ok "$m" "${dim}${head:0:8}${off} ${ylw}(local changes, left alone)${off}"
		else
			r_ok "$m" "${dim}${head:0:8}${off}"
		fi
		return
	fi

	# Guard: local changes. Never stash, never reset — the whole point of a dev
	# checkout is that an interrupted edit survives an update.
	if is_dirty "$m"; then
		[ "${DRY:-0}" = 1 ] || fix_upstream "$m" "$rem"
		r_skip "$m" "local changes — commit or stash, then re-run"
		return
	fi

	# Guard: commits that exist only here. Moving HEAD would orphan them, and
	# pinning them would produce a superproject nobody else can clone.
	n=$(unique_of "$m" "$rem")
	if [ "$n" -gt 0 ]; then
		if is_anc "$m" "$target" "$head"; then
			if [ "${DRY:-0}" != 1 ]; then
				on_main "$m" || git -C "$m" switch -q main 2>/dev/null || true
				fix_upstream "$m" "$rem"
			fi
			r_skip "$m" "$(plural "$n" "unpushed commit") — run ./dev push"
		else
			r_fail "$m" "diverged from $rem/main — run ./dev pull"
		fi
		return
	fi

	# Clean, and nothing local-only exists on HEAD or main. `switch -C` is safe
	# *because* of that, and it handles both directions with one command: a
	# fresh `--init` leaves HEAD detached at the pin while local `main` sits at
	# the remote tip, so when the pin is OLDER than the tip a fast-forward
	# cannot reach it and only a reset will do.
	if [ "${DRY:-0}" = 1 ]; then
		r_move "$m" "would move ${dim}${head:0:8} -> ${target:0:8}${off}"
		return
	fi
	if ! git -C "$m" switch -q -C main "$target" 2>/dev/null; then
		r_fail "$m" "checkout blocked (untracked file in the way?)"
		return
	fi
	fix_upstream "$m" "$rem"
	if [ "$head" = "$target" ]; then
		r_move "$m" "attached to main ${dim}${target:0:8}${off}"
	else
		r_move "$m" "${dim}${head:0:8} -> ${target:0:8}${off}"
	fi
}

cmd_sync() {
	local mode=pin
	[ "${1-}" = --latest ] && mode=latest
	# Not ${DRY:+...}: DRY=0 is set-and-non-empty, so that would always fire.
	hdr "submodules — $mode$([ "${DRY:-0}" = 1 ] && echo " (dry run)")"
	guard_branches || return 1
	for m in "${mods[@]}"; do sync_one "$m" "$mode"; done
	[ "$bad" -eq 0 ] || act "attention needed in $(plural "$bad" submodule) — see above"
	return $((bad > 0))
}

case "${1-}" in
	status) shift; cmd_status "$@" ;;
	pull)   shift; cmd_pull "$@" ;;
	push)   shift; cmd_push "$@" ;;
	sync)   shift; cmd_sync "$@" ;;
	*) err "usage: scripts/repo.sh <status|pull|push|sync>"; exit 2 ;;
esac
