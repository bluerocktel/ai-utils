#!/bin/bash
# Offline regression test for ai-history (facts view).
#
# Builds a throwaway HOME and TASKS_DIR and runs the script against them.
# Never touches the live tree: lib.sh derives every pipeline path from
# TASKS_DIR, which is set before the script runs.
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
mkdir -p "$HOME" "$T"/{projects,inbox,run,review,done,briefs/done,backlog-for-review,suggestions}

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
H() { "$REPO_DIR/ai-history" "$@"; }

# ── fixtures ───────────────────────────────────────────────────────────────
printf '## Working Directory\n`~/Projects/demo/`\n\n## Aliases\n- `demo-alias`\n' > "$T/projects/demo.md"
printf '## Working Directory\n`~/Projects/other/`\n' > "$T/projects/other.md"
printf '## Working Directory\n`~/Projects/idle/`\n' > "$T/projects/idle.md"

task() {  # task <file> <project token> [brief]
    { printf '# t\n\n## Project\n%s\n' "$2"
      [ -n "${3:-}" ] && printf '\n## Brief\n%s\n' "$3"
      printf '\n## Context\nx\n'; } > "$1"
}
B="$T/briefs/done/demo-feature-brief.md"

# Two finished tasks of one brief, one under an alias spelled in another case.
task "$T/done/2026-10-01_10-00_2026-10-01_first-step.task.md" demo "$B"
printf '# r\n\n## Summary\n- **Done:** long summary. More text.\n\n## Suggested Commit Message\n```\ndemo: add the first step\n\nbody\n```\n' \
    > "$T/done/2026-10-01_10-00_2026-10-01_first-step.md"
task "$T/done/2026-10-02_09-30_2026-10-02_second-step.task.md" DEMO-Alias "\`$B\`"
printf '# r\n\n## Summary\nThe second step works. Details follow.\n' \
    > "$T/done/2026-10-02_09-30_2026-10-02_second-step.md"
# A failed attempt's report, with no .task.md beside it: not a finished task.
printf '# r\n\n## Summary\nattempt that failed.\n' > "$T/done/2026-10-02_08-00_2026-10-02_second-step.md"
# A hand-written task whose ## Brief is free text, not a path.
task "$T/done/2026-09-01_08-00_2026-09-01_old-task.task.md" demo "see the dossier brief, task 2"
printf '# r\n\n## Summary\nOld.\n' > "$T/done/2026-09-01_08-00_2026-09-01_old-task.md"
# Queue state.
task "$T/inbox/2026-10-03_third-step.md" demo "$B"
task "$T/review/2026-10-02_broken.md" demo
task "$T/backlog-for-review/2026-10-03_proposal.md" demo
printf '# Suggested follow-up\n\n## Project\ndemo-alias\n' > "$T/suggestions/follow-up.md"
# Another project, finished later, and tokens that resolve to no project.
task "$T/done/2026-10-05_12-00_2026-10-05_elsewhere.task.md" other
printf '# r\n\n## Summary\nOther.\n' > "$T/done/2026-10-05_12-00_2026-10-05_elsewhere.md"
task "$T/done/2026-10-05_12-30_2026-10-05_stray.task.md" '../@@@'
task "$T/done/2026-10-05_12-40_2026-10-05_unknown.task.md" not-a-project

before=$(find "$T" -type f -printf '%p %s %T@\n' | sort | sha256sum)

# ── every project ──────────────────────────────────────────────────────────
OUT=$(H) || fail "listing exited non-zero"
first=$(printf '%s\n' "$OUT" | sed -n 2p | awk '{print $1}')
[ "$first" = other ] || fail "most recently active project should be listed first, got '$first'"
printf '%s\n' "$OUT" | grep -qE '^demo +10-02 09:30 +2$' || fail "demo line should show last done 10-02 09:30 and 2 open: $(printf '%s\n' "$OUT" | grep '^demo')"
printf '%s\n' "$OUT" | grep -qE '^idle +never +0$' || fail "a project with no task should read never"

# ── one project ────────────────────────────────────────────────────────────
OUT=$(H demo) || fail "project view exited non-zero"
printf '%s\n' "$OUT" | grep -q 'queued 1 · in review 1 · awaiting your review 1 · suggestions 1' \
    || fail "NOW counts wrong: $(printf '%s\n' "$OUT" | grep queued)"
printf '%s\n' "$OUT" | grep -q '✗ broken' || fail "review task not listed"
printf '%s\n' "$OUT" | grep -q 'Suggested follow-up' || fail "suggestion filed under an alias not listed"
printf '%s\n' "$OUT" | grep -q 'first-step .*demo: add the first step$' \
    || fail "commit subject should describe a finished task"
printf '%s\n' "$OUT" | grep -q 'second-step .*The second step works\.$' \
    || fail "alias-filed task should fall back to the summary's first sentence"
[ "$(printf '%s\n' "$OUT" | grep -c 'second-step')" -eq 1 ] || fail "a failed attempt's report must not be listed"
printf '%s\n' "$OUT" | grep -qE 'feature +2/3 done' || fail "brief progress should read 2/3: $(printf '%s\n' "$OUT" | grep done$)"
[ "$(printf '%s\n' "$OUT" | grep -cE '[0-9]+/[0-9]+ done$')" -eq 1 ] \
    || fail "only the stamped brief may be listed: a free-text ## Brief is not a brief"
printf '%s\n' "$OUT" | grep -q 'elsewhere' && fail "another project's task leaked in"
[ "$(H demo -n 1 | grep -c '✓')" -eq 1 ] || fail "-n 1 should list one finished task"
[ "$(H DEMO-ALIAS | head -1 | awk '{print $1}')" = demo ] || fail "an alias argument should open the project"

# ── refusals ───────────────────────────────────────────────────────────────
H no-such-project >/dev/null 2>&1 && fail "unknown project should exit non-zero"
H demo -n 0 >/dev/null 2>&1 && fail "-n 0 should be refused"
H demo --bogus >/dev/null 2>&1 && fail "unknown option should be refused"

# ── the alias table agrees with canonical_project ──────────────────────────
# ai-history keeps its own copy of the rule for speed; it must not drift.
# shellcheck source=/dev/null
. "$REPO_DIR/lib.sh"
for tok in demo demo-alias DEMO-Alias other not-a-project '../@@@' '@@@' 'a/b/demo'; do
    want=$(canonical_project "$tok")
    got=$(TOK="$tok" bash -c '
        set -euo pipefail
        src=$(sed -n "/^# Raw ## Project token -> canonical project/,/^# Every task file of the tree/p" "$1")
        . "$2/lib.sh"
        eval "$src"
        _canon "$TOK"
        printf "%s" "$CANON_OUT"' _ "$REPO_DIR/ai-history" "$REPO_DIR")
    [ "$got" = "$want" ] || fail "alias table says '$got' for '$tok', canonical_project says '$want'"
done

# ── read-only ──────────────────────────────────────────────────────────────
after=$(find "$T" -type f -printf '%p %s %T@\n' | sort | sha256sum)
[ "$before" = "$after" ] || fail "ai-history wrote into TASKS_DIR"

# ── empty tree ─────────────────────────────────────────────────────────────
EMPTY="$tmp/empty"
mkdir -p "$EMPTY"
out=$(TASKS_DIR="$EMPTY" "$REPO_DIR/ai-history" 2>&1) || fail "empty tree should exit 0"
[ -z "$out" ] || fail "empty tree should print nothing, got: $out"

if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: ai-history"
    exit 0
fi
echo "$FAILURES failure(s)" >&2
exit 1
