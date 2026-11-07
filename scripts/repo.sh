#!/usr/bin/env bash
# The repo engine: everything that moves a submodule's HEAD, publishes it, or
# reports on where it is. Backs `./dev status`, `./dev pull`, `./dev push` and
# the `sync` step inside `./dev install`.
#
# THE MODEL, in one paragraph. This tree is a superproject: ten submodules and
# a recorded commit ("pin") for each. Day to day there are exactly two verbs.
# `pull` brings every submodule to its own origin/main and brings the root up
# to date with the root's origin/main. `push` publishes every submodule, then
# records the new pins in one root commit whose message is written for you, and
# pushes that. Everything else — sync, pin, the ordering between them — is an
# implementation detail of those two, not something to think about.
#
# FEATURES. Work that spans several submodules gets a branch of one name in the
# root and in each submodule it touches — and that is the whole record: a
# submodule is in feature `foo` exactly when it has a branch called `foo`,
# locally or on its remote. The ROOT'S branch is the current feature, and every
# other submodule stays on main. `switch` moves the tree between features,
# `pull` rebases each feature branch onto its origin/main, `push` publishes the
# feature branches and pins them on the root's feature branch, and `land`
# fast-forwards each submodule's main to its feature and records the lot in one
# root merge commit. Feature branches are rebased, so they are pushed with
# --force-with-lease; main never is.
#
# The three rules this file exists to enforce:
#
#   1. `git submodule update` is used exactly ONCE per submodule — to
#      materialize a directory that isn't there yet — and never again.
#      `--force` and `--remote --merge` are the only ways to lose work in a
#      superproject and neither appears here.
#
#   2. A submodule on any branch but the one it should be on — the feature if
#      it is in it, main otherwise — stops the run. Not a warning you can
#      scroll past: pull, push and land all refuse to touch the tree until it
#      is back, because every other guarantee here assumes it.
#
#   3. Uncommitted work stops a `push`, a `switch` and a `land`, and is
#      reported by everything else. Publishing a pin that silently excludes the
#      edit you were in the middle of is the exact surprise this tool exists to
#      prevent.
#
# Usage: scripts/repo.sh <status|pull|push|sync|switch|land> [args]
#   status              a table plus what to do next; fetches, changes nothing
#   pull                every submodule to its origin/main, root to its own
#   push                publish submodules, pin them, commit, push the root
#   sync [--latest|--keep-ahead]
#                       move each submodule to its recorded pin; --keep-ahead
#                       (what `./dev install` runs) leaves one that is published
#                       and ahead of its pin where it is
#   switch [<feature> [<submodule>...]]
#                       move the tree to a feature (or `main`); naming
#                       submodules starts the feature in them. No args lists
#   land                merge the current feature into main everywhere
# Env:
#   DRY=1               report what would happen; touch nothing
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
. "$root/scripts/lib/out.sh"

# The ten. kbrowser has no remote yet, so it stays a plain sibling clone,
# ignored by the root (see .gitignore).
mods=(kosmos kallos-lib kallosd kallosctl hajime yggdrasil torrential renzoku phylax library)

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

# Fetch, and say so when it fails. Swallowing this error is how a pull once
# reported every repo "up to date" against week-old refs while offline, and the
# push straight after was rejected all down the list. On failure the reason —
# git's first line, minus its "fatal: " — is left in $fetch_err.
fetch_err=""
fetch() {
	local out
	out=$(git -C "$1" fetch --prune --quiet "$2" 2>&1 >/dev/null) && { fetch_err=""; return 0; }
	fetch_err=$(printf '%s\n' "$out" | sed -n '/./{s/^fatal: //;p;q}')
	fetch_err=${fetch_err:-git fetch failed}
	return 1
}

# The remote has no main at all: a repo created on GitHub and never pushed to.
# Only meaningful straight after a successful fetch, which prunes the ref.
no_main()   { ! git -C "$1" rev-parse --verify -q "$2/main" >/dev/null; }

# "1 commit", "4 commits". Worth the three lines: "commit(s)" in a generated
# commit message reads as a template nobody filled in, which is most of what
# made the old hand-written pin messages feel like noise.
plural()    { [ "$1" = 1 ] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }

# Commits reachable from HEAD or the submodule's branch (main, or the feature)
# but not from anything published — i.e. work that exists only on this machine.
# This is the number that makes a pin unclonable, so it gates every worktree
# write below. A feature branch never pushed is measured against main: every
# commit it has over main is local.
unique_of() {
	local m=$1 rem=$2 b=${3:-$(want_of "$1")} refs=(HEAD)
	git -C "$m" rev-parse --verify -q "$b" >/dev/null && refs+=("$b")
	if [ -n "$(rref_of "$m" "$rem" "$b")" ]; then refs+=("^$rem/$b")
	# No remote main yet means nothing is published: every commit is unique.
	elif ! no_main "$m" "$rem"; then refs+=("^$rem/main")
	fi
	git -C "$m" rev-list --count "${refs[@]}" 2>/dev/null || echo 0
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

# ---- features -------------------------------------------------------------
# The root's branch IS the current feature; main is the absence of one. A
# detached root (mid-rebase, or checked out by hand) counts as main, which makes
# every guard below behave exactly as it did before features existed.
feat=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo main)

# Whether a submodule has branch $2, here or on its remote. Its remote ref only
# counts after a fetch — which is why every verb that asks fetches first.
has_branch() {
	local m=$1 b=$2 rem
	git -C "$m" rev-parse --verify -q "refs/heads/$b" >/dev/null && return 0
	rem=$(remote_of "$m") || return 1
	git -C "$m" rev-parse --verify -q "refs/remotes/$rem/$b" >/dev/null
}

# The branch a submodule should be on: the feature if it is in it, main if not.
want_of() {
	[ "$feat" != main ] && has_branch "$1" "$feat" && { echo "$feat"; return; }
	echo main
}
in_feat()   { [ "$(want_of "$1")" != main ]; }
on_want()   { [ "$(branch_of "$1")" = "$(want_of "$1")" ]; }
# The remote ref a branch is published as, if it is. Empty before its first push.
rref_of()   { git -C "$1" rev-parse --verify -q "refs/remotes/$2/$3" >/dev/null && echo "$2/$3"; return 0; }

# ---- guards ---------------------------------------------------------------
# Rule 2, in one place. Every submodule that exists must be on the branch it
# should be on (see want_of), or on a detached HEAD that pull/sync is allowed to
# attach. Anything else means somebody is mid-something, and guessing what to
# do with it is exactly the kind of cleverness that loses work.
guard_branches() {
	local m br want n=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		br=$(branch_of "$m"); want=$(want_of "$m")
		[ "$br" = "$want" ] || [ "$br" = "(detached)" ] || {
			r_fail "$m" "on branch '$br', not $want"
			n=$((n + 1))
		}
	done
	[ "$n" = 0 ] && return 0
	if [ "$feat" = main ]; then
		act "$(plural "$n" submodule) off main — this tree only tracks main"
	else
		act "$(plural "$n" submodule) off feature '$feat' — each should be on '$feat' if it has one, main if not"
	fi
	note "finish or park that branch, then put the tree back:"
	note "  ./dev switch $feat"
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
	note "commit it where it lives, then run that again:"
	[ "$subs" = 0 ] || note "  git -C <submodule> add -A && git -C <submodule> commit"
	[ -z "$own" ]   || note "  git commit -a                 # this repo's own files"
	return 1
}

# ---- pull -----------------------------------------------------------------

# Bring the root to $1, which it is an ancestor of. `merge --ff-only` refuses
# when a gitlink is locally modified, and drifted gitlinks are the normal state
# here, so it falls back to a hard reset — which does not recurse into
# submodule worktrees (submodule.recurse is off), and which is only allowed
# when the root's own files are clean, because a reset would take those too.
root_ff() {
	git merge --ff-only --quiet "$1" >/dev/null 2>&1 && return 0
	[ -z "$(root_own_changes)" ] || return 1
	git reset --hard --quiet "$1" >/dev/null 2>&1
}

# Rebase the root onto $@ (an upstream, optionally after --fork-point),
# resolving any gitlink collision to whatever this machine's submodule is
# currently at — the value is irrelevant, because the pins get recomputed from
# the tips by the next push. A collision in a real file is different work: the
# rebase is aborted and this returns 1, leaving the root as it was.
root_rebase() {
	git rebase --quiet "$@" >/dev/null 2>&1 && return 0
	# Refused before it started — an edit to a root file is in the way.
	[ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] || return 1
	# `--continue` fails again whenever the NEXT commit also collides on a
	# gitlink — every pin commit on a feature branch does — so a failure there
	# is not a stop, only another lap. The lap cap is what keeps a continue
	# that fails for some other reason from spinning forever.
	local laps=0
	while { [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; } && [ "$laps" -lt 500 ]; do
		laps=$((laps + 1))
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
		GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
	done
	if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
		git rebase --abort >/dev/null 2>&1 || true
		return 1
	fi
}

# The root, first. It has to move before the submodules do: once the submodules
# are at their tips the root's gitlinks read as modified, and git then refuses
# to fast-forward over them. Doing the root first means it merges against a
# tree whose only drift is drift we are about to overwrite anyway.
pull_root() {
	local rem ahead behind
	rem=$(root_remote) || { r_skip "(root)" "no remote yet"; return 0; }
	git rev-parse --verify -q HEAD >/dev/null || { r_skip "(root)" "no commits yet"; return 0; }
	fetch . "$rem" || { r_fail "(root)" "fetch failed — $fetch_err"; return 0; }
	git rev-parse --verify -q "$rem/main" >/dev/null || { r_skip "(root)" "no $rem/main"; return 0; }
	[ "$feat" = main ] || { pull_feat "." "(root)" "$rem"; return; }

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
		if root_ff "$rem/main"; then
			r_move "(root)" "fast-forwarded $(plural "$behind" commit)"
		else
			r_fail "(root)" "could not fast-forward — resolve by hand"
		fi
		return
	fi

	# Diverged: local pin commits and remote pin commits.
	if root_rebase "$rem/main"; then
		r_move "(root)" "rebased $(plural "$ahead" "local commit") onto $behind new"
	else
		r_fail "(root)" "conflict in the root's own files — resolve by hand"
		note "  git rebase $rem/main"
	fi
}

# A feature branch — the root's, or a submodule's — in two moves. First what
# another machine pushed to the feature: a fast-forward, or a --fork-point
# rebase, which is what copes with that machine having rebased the branch
# before pushing it. Then onto the latest main, which is what keeps `land` a
# fast-forward. $1 is the repo dir, $2 its row label, $3 its remote.
pull_feat() {
	local d=$1 label=$2 rem=$3 rf behind did=()
	if no_main "$d" "$rem"; then r_fail "$label" "no $rem/main to base '$feat' on"; return; fi
	if [ "$(branch_of "$d")" != "$feat" ]; then
		r_fail "$label" "detached, not on '$feat' — run ./dev switch $feat"
		return
	fi
	if feat_gone "$d" "$rem"; then
		r_fail "$label" "$rem/$feat is gone — landed elsewhere? run ./dev switch main"
		return
	fi
	rf=$(rref_of "$d" "$rem" "$feat")
	local took=0 rebased=0
	if [ -n "$rf" ] && ! is_anc "$d" "$rf" HEAD; then
		is_anc "$d" HEAD "$rf" && took=$(count "$d" "HEAD..$rf") || rebased=1
	fi
	if [ "${DRY:-0}" = 1 ]; then
		[ "$took" = 0 ] || did+=("would take $took from $rf")
		[ "$rebased" = 0 ] || did+=("would rebase onto $rf")
		behind=$(count "$d" "HEAD..$rem/main")
		[ "$behind" = 0 ] || did+=("would rebase onto $(plural "$behind" "new commit") on main")
	else
		if [ "$took" != 0 ]; then
			if [ "$d" = . ]; then root_ff "$rf"; else git -C "$d" merge --ff-only --quiet "$rf" >/dev/null 2>&1; fi ||
				{ r_skip "$label" "uncommitted changes block taking $rf — commit them, then pull again"; return; }
			did+=("took $took from $rf")
		fi
		if [ "$rebased" = 1 ]; then
			feat_rebase "$d" --fork-point "$rf" || {
				r_fail "$label" "conflict rebasing onto $rf"
				note "  git -C $d rebase $rf    # resolve, then run pull again"
				return; }
			did+=("rebased onto $rf")
		fi
		behind=$(count "$d" "HEAD..$rem/main")
		if [ "$behind" != 0 ]; then
			feat_rebase "$d" "$rem/main" || {
				r_fail "$label" "conflict rebasing '$feat' onto $rem/main"
				note "  git -C $d rebase $rem/main    # resolve, then run pull again"
				return; }
			did+=("rebased onto $(plural "$behind" "new commit") on main")
		fi
	fi
	if [ "${#did[@]}" -gt 0 ]; then
		r_move "$label" "$(IFS=';'; echo "${did[*]}" | sed 's/;/; /g')"
		return
	fi
	local head n; head=$(sha "$d"); n=$(count "$d" "$rem/main..HEAD")
	if [ "$d" != . ] && is_dirty "$d"; then
		r_ok "$label" "${dim}${head:0:8}${off} ${ylw}(uncommitted changes)${off}"
	else
		r_ok "$label" "${dim}${head:0:8} '$feat' +$n on main${off}"
	fi
}

# The root rebases with its gitlink resolver; a submodule with --autostash,
# which restores the worktree on abort too, so a failed rebase leaves the
# submodule exactly as it was found.
feat_rebase() {
	local d=$1; shift
	[ "$d" = . ] && { root_rebase "$@"; return; }
	git -C "$d" rebase --autostash --quiet "$@" >/dev/null 2>&1 && return 0
	git -C "$d" rebase --abort >/dev/null 2>&1 || true
	return 1
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
	fetch "$m" "$rem" || { r_fail "$m" "fetch failed — $fetch_err"; return; }
	in_feat "$m" && { pull_feat "$m" "$m" "$rem"; return; }
	head=$(sha "$m")
	br=$(branch_of "$m")
	# An empty remote is a repo that has not been published yet, not a fault:
	# there is nothing to pull, and `push` makes the first one.
	if no_main "$m" "$rem"; then
		if [ "$br" = main ]; then
			r_ok "$m" "${dim}${head:0:8}${off} ${ylw}($(unique_of "$m" "$rem") to push — $rem is empty)${off}"
		else
			r_fail "$m" "no $rem/main, and not on main to publish one"
		fi
		return
	fi
	target=$(sha "$m" "$rem/main")

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
	elif [ "$feat" = main ]; then
		act "everything is at its latest main"
	else
		act "feature '$feat' is on the latest main, everything else at it"
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
#
# With --land the new pins are read from the index rather than the worktrees —
# the merged tree `land` is about to commit — and the subject is always
# "land <feature>: ...": a feature's name is the one thing its submodules' logs
# don't already say.
pin_message() {
	local land=0; [ "${1-}" = --land ] && land=1
	local m old new n sub names=() total=0 body="" first_sub="" changed=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		old=$(pinned_of "$m")
		if [ "$land" = 1 ]; then new=$(git rev-parse -q --verify ":$m" 2>/dev/null || true); else new=$(sha "$m"); fi
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
	if [ "$land" = 1 ]; then
		subject="land $feat: $(IFS=, ; echo "${names[*]}" | sed 's/,/, /g')"
	elif [ "$changed" = 1 ] && [ -n "$first_sub" ]; then
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

# Whether this machine has taken in everything on the published feature branch
# $3 — i.e. some past position of the local branch (its reflog) contains it.
# A rebased feature branch no longer has its published tip as an ancestor, so
# plain ancestry cannot tell "I rebased what you pushed" from "you pushed
# something I never saw"; the reflog can, because `pull` passes through the
# published tip on its way to rebasing onto main.
integrated() {
	local d=$1 b=$2 rf=$3 c
	is_anc "$d" "$rf" "$b" && return 0
	for c in $(git -C "$d" reflog --format=%H "refs/heads/$b" -- 2>/dev/null | head -200); do
		is_anc "$d" "$rf" "$c" && return 0
	done
	return 1
}

# The feature branch was published once — it tracks a remote branch — and that
# remote branch is gone: `land` ran on another machine, or somebody deleted it.
# Either way pulling or pushing it would resurrect it, so both stop instead.
feat_gone() {
	local d=$1 rem=$2
	[ -n "$(git -C "$d" config --get "branch.$feat.merge" || true)" ] &&
		[ -z "$(rref_of "$d" "$rem" "$feat")" ]
}

# Whether branch $3 of repo $1 is already in $2/main in substance: an ancestor,
# or — for a copy from before somebody rebased and landed it — every commit has
# an equivalent there (a submodule), or every file it touched reads the same
# there (the root, whose pin commits never match patch for patch).
landed_in() {
	local d=$1 r=$2 b=$3 base files
	is_anc "$d" "refs/heads/$b" "$r/main" && return 0
	if [ "$d" != . ]; then
		! git -C "$d" cherry "$r/main" "refs/heads/$b" 2>/dev/null | grep -q '^+'
		return
	fi
	base=$(git merge-base "$r/main" "refs/heads/$b" 2>/dev/null) || return 1
	files=$(git diff --name-only "$base" "refs/heads/$b" -- . "${mods[@]/#/:!}")
	[ -z "$files" ] || git diff --quiet "refs/heads/$b" "$r/main" -- $files
}

# Publish feature branch $feat of repo $1 to remote $2. Rebased branches need a
# forced push; the lease names the exact published tip this machine took in, so
# a push from another machine in the meantime is rejected, never overwritten.
# Prints what happened; returns 0 pushed, 1 failed, 2 nothing to push.
push_feat() {
	local d=$1 rem=$2 rf local_tip lease
	feat_gone "$d" "$rem" && { echo "$rem/$feat is gone — landed elsewhere? ./dev switch main"; return 1; }
	local_tip=$(sha "$d" "refs/heads/$feat")
	rf=$(rref_of "$d" "$rem" "$feat")
	if [ -n "$rf" ]; then
		[ "$(sha "$d" "$rf")" = "$local_tip" ] && return 2
		integrated "$d" "$feat" "$rf" ||
			{ echo "$rf has commits this machine never pulled — run ./dev pull first"; return 1; }
		lease="--force-with-lease=refs/heads/$feat:$(sha "$d" "$rf")"
	else
		# Never published: the lease is "the branch must not exist yet".
		lease="--force-with-lease=refs/heads/$feat:"
	fi
	if [ "${DRY:-0}" = 1 ]; then echo "would push '$feat'"; return 0; fi
	if git -C "$d" push -q "$lease" -u "$rem" "refs/heads/$feat:refs/heads/$feat" 2>/dev/null; then
		echo "pushed '$feat'"; return 0
	fi
	echo "push rejected — $rem/$feat moved; run ./dev pull first"
	return 1
}

cmd_push() {
	hdr "push"
	guard_branches || return 1
	guard_clean || return 1

	# 1. The submodules first, always. A pin is only clonable once the commit
	#    it names is on a remote, so this ordering is not a preference.
	local m rem n out rc pushed=0
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || { r_fail "$m" "no remote"; continue; }
		if in_feat "$m"; then
			rc=0; out=$(push_feat "$m" "$rem") || rc=$?
			case "$rc" in
				0) r_move "$m" "$out"; pushed=$((pushed + 1)) ;;
				1) r_fail "$m" "$out" ;;
			esac
			continue
		fi
		n=$(unique_of "$m" "$rem")
		[ "$n" -gt 0 ] || continue
		if [ "${DRY:-0}" = 1 ]; then r_move "$m" "would push $(plural "$n" commit)"; pushed=$((pushed + 1)); continue; fi
		if git -C "$m" push -q "$rem" main 2>/dev/null; then
			# The push wrote $rem/main locally; on a first push that is the
			# first time the ref exists, so main can only now track it.
			fix_upstream "$m" "$rem"
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
		if [ "${DRY:-0}" != 1 ] && rem=$(remote_of "$m") && ! is_anc "$m" "$(sha "$m")" "$rem/$(want_of "$m")"; then
			r_fail "$m" "HEAD is not on $rem/$(want_of "$m") — cannot pin it"
			continue
		fi
		[ "$(pinned_of "$m")" = "$(sha "$m")" ] && continue
		# Behind its pin: this machine never pulled what the root already
		# records — likely after a switch, whose pins can be newer than the
		# local main. Pinning it would quietly roll that submodule back.
		if [ -n "$(pinned_of "$m")" ] && is_anc "$m" "$(sha "$m")" "$(pinned_of "$m")"; then
			r_fail "$m" "behind its pin by $(count "$m" "HEAD..$(pinned_of "$m")") — run ./dev pull first"
			continue
		fi
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
	if [ "$feat" != main ]; then
		rc=0; out=$(push_feat . "$rrem") || rc=$?
		case "$rc" in
			0) r_move "(root)" "$out"; act "feature '$feat' is published" ;;
			1) r_fail "(root)" "$out"; return 1 ;;
			2) r_ok "(root)" "${dim}nothing to push${off}"
			   [ "$pushed" = 0 ] && [ "$staged" = 0 ] && act "nothing to push — everything is already published" ;;
		esac
		return 0
	fi
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
	# than a report. A failed fetch still leaves a table worth printing, but
	# one that is as stale as the machine is — so it is named, not hidden.
	local stale=() stale_err=""
	fetch . origin || { stale+=("(root)"); stale_err=$fetch_err; }
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || continue
		fetch "$m" "$rem" || { stale+=("$m"); stale_err=$fetch_err; }
	done

	[ "$feat" = main ] || printf 'feature: %s\n\n' "$feat"
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
		[ "$br" = "$(want_of "$m")" ] || n_branch=$((n_branch + 1))
		state=clean; is_dirty "$m" && { state=DIRTY; n_dirty=$((n_dirty + 1)); }
		ahead=?; behind=?
		if rem=$(remote_of "$m") && git -C "$m" rev-parse --verify -q "$rem/main" >/dev/null; then
			ahead=$(count "$m" "$rem/main..HEAD"); behind=$(count "$m" "HEAD..$rem/main")
			# A feature's commits over main are the point of it, not unpushed
			# work; what is unpushed is whatever its own remote branch lacks.
			if in_feat "$m"; then
				local rf; rf=$(rref_of "$m" "$rem" "$feat")
				[ -n "$rf" ] && [ "$(sha "$m" "$rf")" = "$(sha "$m" "refs/heads/$feat")" ] ||
					n_ahead=$((n_ahead + 1))
			else
				[ "$ahead" = 0 ] || n_ahead=$((n_ahead + 1))
			fi
			[ "$behind" = 0 ] || n_behind=$((n_behind + 1))
		elif [ -n "${rem:-}" ] && [[ " ${stale[*]} " != *" $m "* ]]; then
			# Fetched fine and still no main: an empty remote, all of it ahead.
			ahead=$(unique_of "$m" "$rem"); behind=0
			[ "$ahead" = 0 ] || n_ahead=$((n_ahead + 1))
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
	if [ "${#stale[@]}" -gt 0 ]; then
		fail "fetch failed for ${stale[*]} — the numbers above are stale"
		note "$stale_err"
		acted=1
	fi
	if [ "$n_branch" -gt 0 ]; then
		if [ "$feat" = main ]; then
			fail "$(plural "$n_branch" submodule) not on main — pull and push both refuse to run"
		else
			fail "$(plural "$n_branch" submodule) not on the branch feature '$feat' expects — pull and push both refuse to run"
		fi
		note "run: ./dev switch $feat"
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
	if [ "$feat" != main ] && in_feat kallos-lib; then
		warn "kallos-lib is in '$feat' — every Rust binary builds against it, in the feature or not"
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
	if [ "$acted" = 0 ]; then
		[ "$feat" = main ] && ok "everything is on main, committed, published and pinned" ||
			ok "feature '$feat' is committed, published and pinned — ./dev land when it is done"
	fi
}

# ---- sync -----------------------------------------------------------------
# Move each submodule TO ITS RECORDED PIN. This is what a fresh clone needs; it
# is not part of the daily push/pull loop, which always goes to the tips. Kept
# as its own verb because "give me exactly the combination this repo says
# works" is a real thing to want after a bad pull.
#
# `./dev install` runs it as --keep-ahead: a submodule already past its pin on
# published commits — the state `pull` leaves behind — stays where it is. Plain
# sync would reset it back to the pin, and the install straight after a pull
# would build the code from before it.
sync_one() {
	local m=$1 mode=$2 rem target head n

	if [ ! -e "$m/.git" ]; then
		if [ "${DRY:-0}" = 1 ]; then r_move "$m" "would clone"; return; fi
		git submodule update --init -- "$m" >/dev/null ||
			{ r_fail "$m" "clone failed"; return; }
	fi

	rem=$(remote_of "$m") || { r_fail "$m" "no usable remote — add one named 'origin'"; return; }
	local fetched=1
	fetch "$m" "$rem" || fetched=0

	if [ "$mode" = latest ]; then
		[ "$fetched" = 1 ] || { r_fail "$m" "fetch failed — $fetch_err"; return; }
		target=$(sha "$m" "$rem/$(want_of "$m")") || { r_fail "$m" "no $rem/$(want_of "$m")"; return; }
	else
		target=$(pinned_of "$m")
		[ -n "$target" ] || { r_skip "$m" "no pin recorded yet — run ./dev push"; return; }
		# A pin already on this machine needs no network: an offline install
		# still works. Only a pin we would have had to download is a failure.
		[ "$fetched" = 1 ] || git -C "$m" cat-file -e "$target^{commit}" 2>/dev/null ||
			{ r_fail "$m" "fetch failed — $fetch_err"; return; }
	fi
	head=$(sha "$m")

	# Nothing to do, and already in a shape that's good to work in. Note any
	# local changes on the way past: they are not a problem here — nothing needs
	# to move — but a bare OK next to a half-finished edit reads as "this
	# submodule is untouched", which is the opposite of true.
	local want; want=$(want_of "$m")
	if [ "$head" = "$target" ] && on_want "$m" &&
	   { [ "$want" != main ] || [ -n "$(git -C "$m" config --get branch.main.remote || true)" ]; }; then
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
				on_want "$m" || git -C "$m" switch -q "$want" 2>/dev/null || true
				fix_upstream "$m" "$rem"
			fi
			r_skip "$m" "$(plural "$n" "unpushed commit") — run ./dev push"
		else
			r_fail "$m" "diverged from $rem/$want — run ./dev pull"
		fi
		return
	fi

	# Ahead of the pin, every commit of it published: the tip a pull brought
	# in, which ./dev push will record. Moving it back is --keep-ahead's to
	# refuse.
	if [ "$mode" = keep ] && [ "$head" != "$target" ] && on_want "$m" &&
	   is_anc "$m" "$target" "$head"; then
		r_ok "$m" "${dim}${head:0:8}${off} ${ylw}($(count "$m" "$target..$head") ahead of the pin — ./dev push records it)${off}"
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
	if ! git -C "$m" switch -q -C "$want" "$target" 2>/dev/null; then
		r_fail "$m" "checkout blocked (untracked file in the way?)"
		return
	fi
	fix_upstream "$m" "$rem"
	if [ "$head" = "$target" ]; then
		r_move "$m" "attached to $want ${dim}${target:0:8}${off}"
	else
		r_move "$m" "${dim}${head:0:8} -> ${target:0:8}${off}"
	fi
}

cmd_sync() {
	local mode=pin
	case "${1-}" in
		--latest) mode=latest ;;
		--keep-ahead) mode=keep ;;
	esac
	# Not ${DRY:+...}: DRY=0 is set-and-non-empty, so that would always fire.
	hdr "submodules — $([ "$mode" = keep ] && echo "pin, or ahead of it" || echo "$mode")$([ "${DRY:-0}" = 1 ] && echo " (dry run)")"
	guard_branches || return 1
	for m in "${mods[@]}"; do sync_one "$m" "$mode"; done
	[ "$bad" -eq 0 ] || act "attention needed in $(plural "$bad" submodule) — see above"
	return $((bad > 0))
}

# ---- switch ---------------------------------------------------------------
# Move the whole tree to a feature, or back to main. A submodule goes to the
# feature's branch if it has one and to main if it does not; naming submodules
# creates the branch in them, from their main, which is how a feature starts and
# how one grows. Nothing here merges or rebases — it only checks branches out,
# and it refuses to do even that over uncommitted work.

# Every feature anybody has: the root's branches other than main, local or
# published, and the submodules that have each.
list_features() {
	local b m in cur rem
	fetch . origin || warn "(root) fetch failed — $fetch_err; the list may be stale"
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] && rem=$(remote_of "$m") && fetch "$m" "$rem" || true
	done
	local all; all=$( { git for-each-ref --format='%(refname:short)' refs/heads
		git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin; } |
		grep -vx -e main -e HEAD | sort -u || true)
	if [ -z "$all" ]; then
		act "no features — start one: ./dev switch <name> <submodule>..."
		return 0
	fi
	for b in $all; do
		in=()
		for m in "${mods[@]}"; do
			[ -e "$m/.git" ] && has_branch "$m" "$b" && in+=("$m")
		done
		cur="  "; [ "$b" = "$feat" ] && cur="${_grn}* ${off}"
		printf '%b%-24s %s\n' "$cur" "$b" "${in[*]:-${dim}(no submodules)${off}}"
	done
	[ "$feat" = main ] && note "on main"
	return 0
}

cmd_switch() {
	[ $# -gt 0 ] || { list_features; return; }
	local to=$1; shift
	local add=("$@") m
	git check-ref-format --branch "$to" >/dev/null 2>&1 || die "'$to' is not a usable branch name"
	[ "$to" != main ] || [ "${#add[@]}" = 0 ] || die "main is not a feature — name one: ./dev switch <name> ${add[*]}"
	for m in "${add[@]+"${add[@]}"}"; do
		[[ " ${mods[*]} " == *" $m "* ]] || die "no submodule named '$m' (one of: ${mods[*]})"
		[ -e "$m/.git" ] || die "$m is not cloned yet — run ./dev pull first"
	done

	hdr "switch to $to$([ "${DRY:-0}" = 1 ] && echo " (dry run)")"
	guard_clean || return 1

	# Fetch everything first: a feature started on another machine exists
	# here only as remote branches, and only a fetch shows them.
	local rem
	fetch . origin >/dev/null 2>&1 || warn "(root) fetch failed — $fetch_err"
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || continue
		fetch "$m" "$rem" || warn "$m fetch failed — $fetch_err; its remote branches may be stale"
	done

	# The root, which is the record of which feature we are on.
	local root_has=0 starting=0
	if [ "$to" = main ] || git rev-parse --verify -q "refs/heads/$to" >/dev/null ||
	   git rev-parse --verify -q "refs/remotes/origin/$to" >/dev/null; then
		root_has=1
	fi
	if [ "$root_has" = 0 ]; then
		[ "${#add[@]}" -gt 0 ] || {
			fail "no feature '$to' here or on origin"
			note "start it by naming the submodules it changes:"
			note "  ./dev switch $to kosmos kallos-lib ..."
			return 1; }
		starting=1
	fi
	if [ "${DRY:-0}" != 1 ]; then
		if [ "$starting" = 1 ]; then
			git switch -q -c "$to" main 2>/dev/null || { r_fail "(root)" "could not create '$to'"; return 1; }
		else
			git switch -q "$to" 2>/dev/null || { r_fail "(root)" "could not switch to '$to'"; return 1; }
		fi
	fi
	if [ "${DRY:-0}" = 1 ]; then
		r_move "(root)" "$([ "$starting" = 1 ] && echo "would start '$to' from main" || echo "would switch to '$to'")"
	else
		r_move "(root)" "$([ "$starting" = 1 ] && echo "started '$to' from main" || echo "on '$to'")"
	fi
	# From here on every helper reads the new feature.
	local left=$feat
	feat=$to

	local br want started in=()
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		br=$(branch_of "$m")
		started=0
		if [[ " ${add[*]+"${add[*]}"} " == *" $m "* ]] && ! has_branch "$m" "$to"; then
			started=1; want=$to
		else
			want=$(want_of "$m")
			# A branch of this name the user did not ask for joins the feature
			# all the same — that is what the branch-is-the-record model means
			# — so say so the moment it happens.
			if [ "$starting" = 1 ] && [ "$want" != main ] && [[ " ${add[*]} " != *" $m "* ]]; then
				warn "$m already has a branch '$to' — it joins the feature"
			fi
		fi
		[ "$want" = main ] || in+=("$m")
		if [ "$br" = "$want" ] && [ "$started" = 0 ]; then
			r_ok "$m" "${dim}$want${off}"; continue
		fi
		if [ "${DRY:-0}" = 1 ]; then
			[ "$started" = 1 ] && r_move "$m" "would start '$to' from main" || r_move "$m" "would switch $br -> $want"
			continue
		fi
		if [ "$started" = 1 ]; then
			git -C "$m" switch -q -c "$to" main 2>/dev/null ||
				{ r_fail "$m" "could not create '$to' from main"; continue; }
			r_move "$m" "started '$to' from main"
		else
			# `switch <name>` makes a tracking branch from <remote>/<name> on
			# its own when only the remote one exists.
			git -C "$m" switch -q "$want" 2>/dev/null ||
				{ r_fail "$m" "could not switch $br -> $want (untracked file in the way?)"; continue; }
			r_move "$m" "$br -> $want"
		fi
	done

	# The feature just left, if it was landed elsewhere: its branches tracked a
	# remote branch that is now gone, and every commit on them is in that
	# remote's main. Then they are leftovers, not work, and they go — otherwise
	# a later `switch` to the same name would quietly resurrect them.
	# The root goes last, and only if no submodule kept its branch: the root's
	# copy holds the pins that tie those branches together as one feature.
	if [ "$left" != main ] && [ "$left" != "$to" ] && [ "${DRY:-0}" != 1 ]; then
		local d label r kept=0
		for d in "${mods[@]}" .; do
			[ -e "$d/.git" ] || continue
			label=$d; [ "$d" = . ] && label="(root)"
			git -C "$d" rev-parse --verify -q "refs/heads/$left" >/dev/null || continue
			[ "$d" != . ] || [ "$kept" = 0 ] || continue
			r=origin; [ "$d" = . ] || r=$(remote_of "$d") || { kept=1; continue; }
			if [ -n "$(git -C "$d" config --get "branch.$left.merge" || true)" ] &&
			   [ -z "$(rref_of "$d" "$r" "$left")" ] && landed_in "$d" "$r" "$left" &&
			   git -C "$d" branch -q -D "$left" >/dev/null 2>&1; then
				r_move "$label" "deleted '$left' — it was landed"
			else
				kept=1
			fi
		done
	fi

	if [ "$bad" -gt 0 ]; then
		act "attention needed in $(plural "$bad" repo) — fix, then run ./dev switch $to again"
		return 1
	fi
	if [ "${DRY:-0}" = 1 ]; then
		act "would be on $([ "$to" = main ] && echo main || echo "feature '$to': ${in[*]:-no submodules yet}")"
		return 0
	fi
	if [ "$to" = main ]; then
		act "everything is on main"
	else
		act "on feature '$to': ${in[*]:-no submodules yet}"
		[[ " ${in[*]} " != *" kallos-lib "* ]] ||
			note "kallos-lib is in it — every Rust binary builds against the feature's copy"
		note "./dev pull and ./dev push work on the feature; ./dev land merges it"
	fi
	note "run ./dev install to build what is checked out now"
}

# ---- land -----------------------------------------------------------------
# Finish a feature: every submodule's main fast-forwards to its feature branch
# and is pushed, then the root gets ONE merge commit — "land foo: kosmos +3,
# kallos-lib +1" — so the root's history says the feature happened while the
# submodules' stay linear. Then the feature branches go, here and on the remotes.
#
# It is all fast-forwards because `pull` keeps each feature branch rebased on
# its origin/main; a branch that is behind main is the one thing that stops it,
# and the answer is a pull, not anything clever here.
cmd_land() {
	[ "$feat" != main ] || die "on main — nothing to land. ./dev switch <feature> first"
	hdr "land $feat$([ "${DRY:-0}" = 1 ] && echo " (dry run)")"
	guard_branches || return 1
	guard_clean || return 1

	local m rem rrem in=()
	rrem=$(root_remote) || die "the root has no remote to land on"
	fetch . "$rrem" || { r_fail "(root)" "fetch failed — $fetch_err"; return 1; }
	for m in "${mods[@]}"; do
		[ -e "$m/.git" ] || continue
		rem=$(remote_of "$m") || continue
		fetch "$m" "$rem" || { r_fail "$m" "fetch failed — $fetch_err"; continue; }
		in_feat "$m" && in+=("$m")
	done
	[ "$bad" = 0 ] || return 1

	# 1. Every precondition, before anything moves: each feature branch holds
	#    its origin/main and its local main (so both fast-forward), and the
	#    root's does the same.
	local d label
	for d in . "${in[@]+"${in[@]}"}"; do
		label=$d; [ "$d" = . ] && label="(root)"
		rem=$rrem; [ "$d" = . ] || rem=$(remote_of "$d")
		if ! is_anc "$d" "$rem/main" "refs/heads/$feat"; then
			r_fail "$label" "'$feat' is behind $rem/main — run ./dev pull first"
		elif git -C "$d" rev-parse --verify -q refs/heads/main >/dev/null &&
		     ! is_anc "$d" refs/heads/main "refs/heads/$feat"; then
			r_fail "$label" "local main has commits '$feat' lacks — push or drop them first"
		fi
	done
	[ "$bad" = 0 ] || { act "nothing was landed"; return 1; }
	[ "${#in[@]}" -gt 0 ] || warn "no submodule has a '$feat' branch — landing the root's alone"

	if [ "${DRY:-0}" = 1 ]; then
		for m in "${in[@]+"${in[@]}"}"; do
			r_move "$m" "would fast-forward main by $(count "$m" "$(remote_of "$m")/main..refs/heads/$feat") and push it"
		done
		r_move "(root)" "would merge '$feat' into main, push, and delete '$feat' everywhere"
		return 0
	fi

	# 2. The submodules: main to the feature, published. A failure stops the
	#    run here, before the root records pins nobody can fetch.
	for m in "${in[@]+"${in[@]}"}"; do
		rem=$(remote_of "$m")
		local n; n=$(count "$m" "$rem/main..refs/heads/$feat")
		if git -C "$m" switch -q main 2>/dev/null &&
		   git -C "$m" merge -q --ff-only "refs/heads/$feat" >/dev/null 2>&1 &&
		   git -C "$m" push -q "$rem" main 2>/dev/null; then
			fix_upstream "$m" "$rem"
			r_move "$m" "main +$n, pushed"
		else
			r_fail "$m" "could not fast-forward and push main"
		fi
	done
	if [ "$bad" -gt 0 ]; then
		act "stopped before the root — nothing is recorded yet"
		note "fix the above, then: ./dev switch $feat && ./dev land"
		return 1
	fi

	# 3. The root: one merge commit, its pins the feature tips just pushed.
	git switch -q main 2>/dev/null || { r_fail "(root)" "could not switch to main"; return 1; }
	root_ff "$rrem/main" || { r_fail "(root)" "could not bring main to $rrem/main"; return 1; }
	git merge -q --no-ff --no-commit "refs/heads/$feat" >/dev/null 2>&1 ||
		{ git merge --abort >/dev/null 2>&1 || true; r_fail "(root)" "merging '$feat' did not go cleanly — resolve by hand"; return 1; }
	for m in "${in[@]+"${in[@]}"}"; do git add -- "$m"; done
	local msg own
	msg=$(pin_message --land) || msg="land $feat"
	own=$(git log --format='    %s' "HEAD..refs/heads/$feat" -- . "${mods[@]/#/:!}" 2>/dev/null || true)
	[ -z "$own" ] || msg+=$'\n\n'"(root)"$'\n'"$own"
	git commit -q -m "$msg" || { r_fail "(root)" "commit failed"; return 1; }
	r_move "(root)" "merged '$feat'"
	printf '%s\n' "$msg" | sed "s/^/        ${dim}/;s/\$/${off}/"
	if git push -q "$rrem" main 2>/dev/null; then
		r_move "(root)" "pushed"
	else
		r_fail "(root)" "push rejected — $rrem/main moved"
		note "the submodules are landed; run ./dev pull, then ./dev push, to record them"
		note "the '$feat' branches are left in place until then"
		return 1
	fi

	# 4. The branches. -d, not -D: every one is merged by now, and git
	#    checking that is the cheapest insurance there is.
	for d in . "${in[@]+"${in[@]}"}"; do
		label=$d; [ "$d" = . ] && label="(root)"
		rem=$rrem; [ "$d" = . ] || rem=$(remote_of "$d")
		git -C "$d" branch -q -d "$feat" >/dev/null 2>&1 || r_skip "$label" "local '$feat' not deleted"
		if [ -n "$(rref_of "$d" "$rem" "$feat")" ]; then
			git -C "$d" push -q "$rem" --delete "$feat" 2>/dev/null || r_skip "$label" "$rem/$feat not deleted"
		fi
	done
	feat=main
	act "landed — everything is on main"
	note "run ./dev install to build it"
}

case "${1-}" in
	status) shift; cmd_status "$@" ;;
	pull)   shift; cmd_pull "$@" ;;
	push)   shift; cmd_push "$@" ;;
	sync)   shift; cmd_sync "$@" ;;
	switch) shift; cmd_switch "$@" ;;
	land)   shift; cmd_land "$@" ;;
	*) err "usage: scripts/repo.sh <status|pull|push|sync|switch|land>"; exit 2 ;;
esac
