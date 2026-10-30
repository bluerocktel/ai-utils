#!/bin/bash
# Offline regression test for dtask's AGENTS section (one line per published
# routine, with its state), the helpers behind it (schedule_period_sec,
# agent_memory_summary), and the guarantee that a tree with no routine renders
# exactly what the previous dtask rendered.
#
# Builds a throwaway HOME, TASKS_DIR and agents root, and runs a copy of the
# scripts with its own config. Never touches the live tree.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
export TASKS_DIR="$tmp/tasks"
export NO_COLOR=1
T="$TASKS_DIR"
A="$tmp/agents"
S="$T/scheduled"
mkdir -p "$HOME" "$T"/{projects,inbox,run,review,done,briefs,backlog-for-review} "$S/.state" "$A"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

APP="$tmp/app"
mkdir -p "$APP"
cp "$REPO_DIR/dtask" "$REPO_DIR/lib.sh" "$APP/"
printf 'default_runner=nonexistent\nagents_root=%s\n' "$A" > "$APP/config"
D() { "$APP/dtask" 2>/dev/null; }
# The dashboard minus the two lines that carry the current time.
stable() { grep -vE '^ai-dash|^Updated:'; }

# ── helpers ────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$REPO_DIR/lib.sh"
SCHED_STATE_DIR="$S/.state"
[ "$(schedule_period_sec daily)" = 86400 ] || fail "daily period"
[ "$(schedule_period_sec weekly-fri)" = 604800 ] || fail "weekly-fri period"
[ "$(schedule_period_sec every:6h)" = 21600 ] || fail "every:6h period"
schedule_period_sec hourly >/dev/null && fail "hourly must be rejected"
schedule_period_sec every:0h >/dev/null && fail "every:0h must be rejected"
schedule_period_sec every:xh >/dev/null && fail "every:xh must be rejected"
[ -z "$(agent_memory_summary no-such 7)" ] || fail "missing ledger must print nothing"

ago() { date -d "$1 ago" '+%Y-%m-%d %H:%M'; }
ledger() {  # ledger <slug> <age> <signal> <outcome>
    printf '%s | perm=propose | signal=%s | %s\n' "$(ago "$2")" "$3" "$4" >> "$S/.state/$1.memory.md"
}
stamp() { date -d "$2 ago" +%s > "$S/.state/$1.run"; }
routine() {  # routine <agent> <slug> <schedule> [permission] [published-age]
    mkdir -p "$A/$1/routines"
    printf '## Kind: monitor\n## Schedule: %s\n## Agent: %s\n' "$3" "$1" > "$A/$1/routines/$2.md"
    [ -n "${4:-}" ] && printf '## Permission: %s\n' "$4" >> "$A/$1/routines/$2.md"
    if [ -n "${5:-}" ]; then
        cp "$A/$1/routines/$2.md" "$S/$2.md"
        touch -d "$5 ago" "$S/$2.md"
    fi
}

ledger sum-a "10 days" yes "messages=1"
ledger sum-a "2 days" no nothing
ledger sum-a "3 hours" yes "briefs=x"
ledger sum-a "1 hour" no nothing
IFS=$'\t' read -r r s c lt lo <<< "$(agent_memory_summary sum-a 7)"
[ "$r $s $c" = "3 1 0" ] || fail "summary counts: got '$r $s $c'"
[ "$lt" = "$(ago "3 hours")" ] || fail "summary last signal time: got '$lt'"
[ "$lo" = "briefs=x" ] || fail "summary last signal outcome: got '$lo'"

# ── no routine at all: byte-identical to the previous dtask ─────────────────
git -C "$REPO_DIR" show HEAD:dtask > "$APP/dtask.old" 2>/dev/null && chmod +x "$APP/dtask.old" || true
if [ -x "$APP/dtask.old" ] && ! grep -q 'ag_rows' "$APP/dtask.old"; then
    cmp -s <(D | stable) <("$APP/dtask.old" 2>/dev/null | stable) \
        || fail "a tree with no routine must render as before"
fi
[[ "$(D)" == *AGENTS* ]] && fail "no routine must print no AGENTS header"

# ── one routine per state ──────────────────────────────────────────────────
routine ops f-badsched hourly "" "1 hour"
routine ops g-badperm daily admin "1 hour"
routine mail c-overdue every:1h "" "30 days"
stamp c-overdue "3 days"
routine mail e-neverold daily "" "5 days"
routine mail b-signal daily "" "10 days"
stamp b-signal "1 hour"
ledger b-signal "2 hours" yes "messages=2, briefs=x-brief,y-brief, report=r.md"
ledger b-signal "1 hour" no nothing
routine pa d-never daily "" "1 hour"
routine pa a-quiet every:1h "" "10 days"
stamp a-quiet "10 minutes"
ledger a-quiet "3 hours" no nothing
ledger a-quiet "2 hours" no nothing
routine pa h-capped every:1h "" "10 days"
stamp h-capped "5 minutes"
for i in $(seq 40 -1 1); do ledger h-capped "$i hours" no nothing; done
routine pa u-one daily
routine pa u-two daily

out=$(D)
ag=$(printf '%s\n' "$out" | sed -n '/^  AGENTS/,/^$/p')
line() { printf '%s\n' "$ag" | grep -E "^  . $1 " || true; }

line f-badsched | grep -q "✗ .*will not run: invalid schedule 'hourly'" || fail "invalid schedule line"
line g-badperm  | grep -q "✗ .*will not run: unrecognised permission 'admin'" || fail "bad permission line"
line c-overdue  | grep -q "⚠ .*overdue: runs every 1h, last run 3 days ago (is ai-scheduled in cron?)" \
    || fail "overdue line: $(line c-overdue)"
line e-neverold | grep -q "⚠ .*overdue: runs daily, published 5 days ago and never run" \
    || fail "never-run overdue line: $(line e-neverold)"
line b-signal   | grep -q "✉ .*found something 2h ago: 2 messages, brief x-brief, y-brief, report" \
    || fail "signal line: $(line b-signal)"
line b-signal   | grep -q '7d: 2 runs, 1 signals' || fail "signal stats: $(line b-signal)"
line d-never    | grep -q "⏳ .*published, waiting for its first run" || fail "waiting line"
line a-quiet    | grep -q "✓ .*nothing to report (ran 10m ago)" || fail "quiet line: $(line a-quiet)"
line a-quiet    | grep -q '7d: 2 runs, 0 signals' || fail "quiet stats"
line h-capped   | grep -q '7d: 40+ runs, 0 signals' || fail "capped stats: $(line h-capped)"
line c-overdue  | grep -q '7d:' && fail "no runs in the window must show no stats"
printf '%s\n' "$ag" | grep -q '· 2 routines defined, not published: ai-agent --publish-plan' \
    || fail "unpublished fold line"
printf '%s\n' "$ag" | grep -qE 'u-one|u-two' && fail "unpublished routines must not get a line"
printf '%s\n' "$ag" | grep -q 'mail' || fail "the agent name must be shown"

# Most urgent first: will not run, overdue, found something, waiting, quiet.
order=$(printf '%s\n' "$ag" | grep -oE '^  . [a-z]-[a-z]+' | awk '{print $2}' | cut -c1 | tr -d '\n')
[ "$order" = "fgcebdah" ] || fail "rank order: got '$order'"

att=$(printf '%s\n' "$out" | sed -n '/NEEDS ATTENTION/,/^$/p;/NEEDS ATTENTION/,/PIPELINE/p')
for s in f-badsched g-badperm c-overdue e-neverold; do
    printf '%s\n' "$att" | grep -q "⚠ $s .*see AGENTS)" || fail "$s missing from NEEDS ATTENTION"
done
for s in b-signal d-never a-quiet h-capped; do
    printf '%s\n' "$att" | grep -q " $s " && fail "$s must not be in NEEDS ATTENTION"
done
printf '%s\n' "$out" | grep -q '4 item(s) require your input' || fail "attention count"

# Singular fold, and only unpublished routines still print the section.
rm -rf "$A"/* "$S"/*.md
routine pa u-one daily
[[ "$(D)" == *'· 1 routine defined, not published'* ]] || fail "singular fold line"

# Read-only: the dashboard wrote nothing under the tree or the agents root.
before=$(find "$T" "$A" -printf '%p %T@\n' | sort)
D >/dev/null
[ "$before" = "$(find "$T" "$A" -printf '%p %T@\n' | sort)" ] || fail "dtask wrote something"

if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: dtask agents view"
    exit 0
fi
echo "$FAILURES failure(s)" >&2
exit 1
