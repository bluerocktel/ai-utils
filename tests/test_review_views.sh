#!/bin/bash
# Offline regression test for two dtask rows: a task waiting on its
# ## Precondition, and a review/ task with an ai-propose proposal, plus the
# SUGGESTIONS section (absent with no stub, newest first, capped at five). dtask only
# READS .precondition/<task> (written by ai-task's pre-claim pass) and never
# runs a check itself; proposal files are not .md, so they are never listed as
# tasks. A tree with neither renders exactly what the previous dtask rendered.
#
# Builds a throwaway HOME and TASKS_DIR and runs a copy of the scripts with its
# own config. Never touches the live tree.
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
mkdir -p "$HOME" "$T"/{projects,inbox,run,review,done,briefs,backlog-for-review}

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

APP="$tmp/app"
mkdir -p "$APP"
cp "$REPO_DIR/dtask" "$REPO_DIR/lib.sh" "$APP/"
printf 'default_runner=nonexistent\n' > "$APP/config"
D() { "$APP/dtask" 2>/dev/null; }
stable() { grep -vE '^ai-dash|^Updated:'; }

printf '# t\n\n## Precondition\ntouch %s/ran\n' "$tmp" > "$T/inbox/wait-task.md"
printf '# t\n' > "$T/inbox/plain-task.md"

# ── no status file: byte-identical to the previous dtask ─────────────────────
if git -C "$REPO_DIR" show HEAD:dtask > "$APP/dtask.old" 2>/dev/null \
    && ! grep -q 'precond_rows' "$APP/dtask.old"; then
    chmod +x "$APP/dtask.old"
    cmp -s <(D | stable) <("$APP/dtask.old" 2>/dev/null | stable) \
        || fail "no status file: output differs from the previous dtask"
fi
[ -e "$tmp/ran" ] && fail "dtask ran a precondition command"

# ── a waiting task, plus a stale file whose task has left inbox/ ─────────────
mkdir -p "$T/.precondition"
printf 'since: 2026-11-06 05:56\nchecked: 2026-11-06 06:10\ncommand: false\nexit: 124 (timed out after 30s)\n' \
    > "$T/.precondition/wait-task"
printf 'since: 2026-11-01 00:00\nexit: 1\n' > "$T/.precondition/gone-task"
out=$(D)
grep -q '⏸ wait-task .*waiting: precondition since 2026-11-06 05:56, exit 124 (timed out after 30s), see .precondition/wait-task' <<< "$out" \
    || fail "waiting row missing or malformed"
grep -q 'gone-task' <<< "$out" && fail "stale status file was rendered"
grep -q '1 item(s) require your input' <<< "$out" || fail "attention count should be 1"
[ -e "$tmp/ran" ] && fail "dtask ran a precondition command"

# ── review rows: proposal hints, and proposal files are never tasks ──────────
printf '# r\n' > "$T/review/2026-11-06_with-edits.md"
printf 'x\n' > "$T/review/2026-11-06_with-edits.proposal"
printf '{}\n' > "$T/review/2026-11-06_with-edits.proposal.json"
printf '# r\n' > "$T/review/2026-11-06_no-edits.md"
printf 'x\n' > "$T/review/2026-11-06_no-edits.proposal"
printf '# r\n' > "$T/review/2026-11-06_bare.md"
out=$(D)
grep -q 'with-edits .*(failed, needs review, fix proposed: ai-propose --apply with-edits)' <<< "$out" \
    || fail "proposal-ready hint missing"
grep -q 'no-edits .*(failed, needs review, see 2026-11-06_no-edits.proposal)' <<< "$out" \
    || fail "proposal-without-edits hint missing"
grep -q 'bare .*(failed, needs review)$' <<< "$out" || fail "plain review row changed"
[ "$(grep -c 'failed, needs review' <<< "$out")" = 3 ] || fail "a proposal file was listed as a task"

# ── suggestions: absent when empty, newest first, capped, warns on a pile ────
D | grep -q 'SUGGESTIONS' && fail "SUGGESTIONS shown with no suggestions/ folder"
mkdir -p "$T/suggestions"
D | grep -q 'SUGGESTIONS' && fail "SUGGESTIONS shown with an empty folder"
printf '# s\n\n## Project\ndemo\n' > "$T/suggestions/old-stub.md"
touch -d '20 days ago' "$T/suggestions/old-stub.md"
for i in 1 2 3 4 5; do
    printf '# s\n\n## Project: demo%s\n' "$i" > "$T/suggestions/new-stub-$i.md"
    touch -d "$i hours ago" "$T/suggestions/new-stub-$i.md"
done
printf 'x\n' > "$T/suggestions/not-a-stub.raw"
out=$(D)
grep -q '^  6 stubs  · 5 new in the last 7 days · oldest 20d$' <<< "$out" \
    || fail "suggestions summary line missing or wrong"
rows=$(grep '✦' <<< "$out" || true)
[ "$(wc -l <<< "$rows")" = 5 ] || fail "should list exactly 5 stubs"
head -n1 <<< "$rows" | grep -q '\[demo1\]  new-stub-1$' || fail "newest stub (inline Project) not first"
grep -q 'old-stub' <<< "$rows" && fail "oldest stub listed beyond the cap"
grep -q 'not-a-stub' <<< "$out" && fail "a non-.md file was listed"
printf '# s\n\n## Project\ndemo\n' > "$T/suggestions/z.md"
touch "$T/suggestions/z.md"
grep -q '\[demo\]  z$' <<< "$(D)" || fail "next-line Project not read"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)" >&2
    exit 1
fi
echo "OK: precondition view"
