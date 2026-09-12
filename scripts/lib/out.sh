# The output vocabulary every Kallos script shares. Sourced, never executed.
#
#   . "$(dirname "$0")/lib/out.sh"        # from scripts/
#   . "$(dirname "$0")/scripts/lib/out.sh"   # from the tree root
#
# Before this existed each script had invented its own: `>>` meant "doing a
# thing" in one and "here is a summary" in the next, headers were `==` in three
# styles, and only two of them had colour at all. The rules are now one file:
#
#   hdr    a phase — the big bold thing, with a blank line above it
#   sec    a section inside a phase
#   ok / warn / todo / skip / fail / pass
#          one checked thing, as an aligned coloured label and a message
#   pend   done, but not in effect until a re-login or a reboot — the state
#          that is NOT a todo, however much it looks like one
#   note   a continuation line under the label above it, dim
#   act    something is being DONE right now, as opposed to reported
#   err    a problem, on stderr; `die` also exits
#
# Colour is a courtesy, never information: every line reads the same with it
# stripped, so a pipe, a log file, CI or NO_COLOR=1 lose nothing. The labels
# carry the meaning and the alignment survives, because the escapes are
# zero-width and the padding is inside the format string, not in the label.
#
# Green is "nothing to do here", yellow is "your attention, not your alarm"
# (todo/wait/warn), red is only ever a real failure. Nothing else gets a colour,
# so red actually means something when it appears.
#
# One rule for the note() under a todo: it starts with "run:" when the reader
# has to type something, and says so plainly when they do not. A continuation
# that could be read either as an instruction or as an explanation is the one
# bug this vocabulary exists to prevent.

# Colour when stdout is a terminal and nobody asked otherwise. NO_COLOR is the
# informal standard (no-color.org): any non-empty value disables it.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	_bld=$'\033[1m'; _dim=$'\033[2m'
	_red=$'\033[31m'; _grn=$'\033[32m'; _ylw=$'\033[33m'; _cyn=$'\033[36m'
	_off=$'\033[0m'
else
	_bld=''; _dim=''; _red=''; _grn=''; _ylw=''; _cyn=''; _off=''
fi

# stderr is gated on its own: `./dev install 2>build.log` on a terminal would
# otherwise write escapes into the log while the screen stayed clean.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	_ered=$'\033[31m'; _eoff=$'\033[0m'
else
	_ered=''; _eoff=''
fi

# A phase: `./dev install`'s steps, and the top of a script run by hand.
hdr() { printf '\n%s== %s%s\n' "$_bld" "$*" "$_off"; }

# A section inside a phase. Indented under the header, not a header itself, so
# a phase with three sections still reads as one block.
sec() { printf '\n%s%s%s\n' "$_bld" "$*" "$_off"; }

# One checked thing. The label column is four wide and the message starts at
# column 8, so labels and continuations line up whatever the mix.
_st() { printf '  %s%-4s%s  %s\n' "$1" "$2" "$_off" "$3"; }
ok()   { _st "$_grn" OK   "$*"; }
pass() { _st "$_grn" PASS "$*"; }
warn() { _st "$_ylw" WARN "$*"; }
todo() { _st "$_ylw" TODO "$*"; }
skip() { _st "$_dim" SKIP "$*"; }
fail() { _st "$_red" FAIL "$*"; }
# Configured, but the running system has not picked it up yet. Distinct from
# todo on purpose: a todo is answered by running something, a WAIT is answered
# by logging out or rebooting, and telling them apart is the whole point —
# otherwise you run the same command twice and see the same line twice.
pend() { _st "$_ylw" WAIT "$*"; }

# A status label plus a fixed-width name column, for the per-item tables
# scripts/repo.sh prints (one row per submodule). Same label geometry as _st,
# so a table and a plain list still line up when a script prints both.
row() { printf '  %s%-4s%s  %-12s %s\n' "$1" "$2" "$_off" "$3" "${4-}"; }
row_grn() { row "$_grn" "$@"; }
row_ylw() { row "$_ylw" "$@"; }
row_red() { row "$_red" "$@"; }

# A continuation of the line above: the why, the command to run, the caveat.
# Dim, and aligned under the message rather than the label.
note() { printf '        %s%s%s\n' "$_dim" "$*" "$_off"; }

# Something is happening — a file being written, a unit being enabled. Distinct
# from a status label because it is an action, not a finding.
act() { printf '%s>>%s %s\n' "$_cyn" "$_off" "$*"; }

# Plain indented prose: prompts, preambles, the paragraph before a question.
say() { printf '   %s\n' "$*"; }

# Problems. `err` reports; `die` reports and stops.
err() { printf '%s!!%s %s\n' "$_ered" "$_eoff" "$*" >&2; }
die() { err "$@"; exit 1; }
