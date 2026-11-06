#!/bin/bash
# Offline regression test for ai-propose. A stub provider returns a canned
# answer; nothing calls a real agent and the live tree is never touched.
#
# What must hold: only edits that target this task or a pending task of the
# SAME brief, whose old text occurs exactly once and sits above the evaluator
# history, are offered; --apply re-checks and is all-or-nothing; a failed or
# empty call writes no proposal and touches no cooldown marker.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" TASKS_DIR="$tmp/tasks"
T="$TASKS_DIR"
mkdir -p "$HOME" "$T"/{inbox,review,done,run,backlog-for-review,briefs/done,.locks}
APP="$tmp/app"; mkdir -p "$APP/providers"
cp "$REPO_DIR/ai-propose" "$REPO_DIR/lib.sh" "$APP/"
printf 'default_runner=stub\n' > "$APP/config"
cat > "$APP/providers/stub.sh" <<'EOF'
ai_run() { [ -n "${STUB_RC:-}" ] && return "$STUB_RC"; jq -n --rawfile r "$STUB_ANSWER" '{result: $r}' > "$5"; : > "$6"; }
ai_json_text() { jq -r '.result // empty' "$1" 2>/dev/null; }
ai_usage_table() { :; }
ai_is_auth_failure() { grep -q 'STUB-AUTH-FAIL' "$1" 2>/dev/null; }
ai_model_alias() { printf '%s\n' "$1"; }
ai_preamble_extra() { :; }
EOF
export STUB_ANSWER="$tmp/answer"
P() { "$APP/ai-propose" "$@"; }

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

B="$T/briefs/done/demo-brief.md"
cat > "$T/review/2026-11-06_first.md" <<EOF
## Project
demo

## Brief
$B

## Acceptance Criteria
- sed -n '31,62p' cols prints 32 names
- dup line
- dup line

## Evaluator Feedback (Attempt 1)
- [FAIL] sed -n '31,62p' starts at the CREATE line

## Retries
1
EOF
cat > "$T/inbox/2026-11-06_second.md" <<EOF
## Brief
$B

## Acceptance Criteria
- sed -n '31,62p' cols again
EOF
cat > "$T/inbox/2026-11-06_other.md" <<EOF
## Brief
$T/briefs/done/another-brief.md

## Acceptance Criteria
- sed -n '31,62p' unrelated
EOF
cp "$T/inbox/2026-11-06_other.md" "$tmp/other.before"

cat > "$STUB_ANSWER" <<'EOF'
===CAUSE===
category: bad-criterion
Line 31 is the CREATE TABLE line; the columns are on 32-63.
===EDIT 2026-11-06_first.md===
---OLD---
- sed -n '31,62p' cols prints 32 names
---NEW---
- sed -n '32,63p' cols prints 32 names
===END EDIT===
===EDIT 2026-11-06_second.md===
---OLD---
- sed -n '31,62p' cols again
---NEW---
- sed -n '32,63p' cols again
===END EDIT===
===EDIT 2026-11-06_first.md===
---OLD---
- dup line
---NEW---
- single line
===END EDIT===
===EDIT 2026-11-06_other.md===
---OLD---
- sed -n '31,62p' unrelated
---NEW---
- changed
===END EDIT===
===EDIT 2026-11-06_first.md===
---OLD---
- [FAIL] sed -n '31,62p' starts at the CREATE line
---NEW---
- [PASS] rewritten history
===END EDIT===
===EDIT ../../etc/2026-11-06_first.md===
---OLD---
## Project
demo
---NEW---
## Project
DEMO
===END EDIT===
===COMMANDS===
none
===END===
EOF

# ── draft ──────────────────────────────────────────────────────────────────
out=$(P first 2>&1) || fail "draft exited non-zero: $out"
PR="$T/review/2026-11-06_first.proposal"; PJ="$PR.json"
[ -f "$PR" ] && [ -f "$PJ" ] || fail "proposal files missing"
grep -q '3 edit(s) kept, 3 rejected' <<< "$out" || fail "expected 3 kept, 3 rejected: $out"
[ "$(jq '.edits | length' "$PJ")" = 3 ] || fail "json should hold 3 edits"
grep -q 'occurs 2 times' "$PR" || fail "duplicate old text not rejected"
grep -q 'not this task or a pending task of the same brief' "$PR" || fail "other brief not rejected"
grep -q 'evaluator history' "$PR" || fail "history edit not rejected"
grep -q '^category: bad-criterion' "$PR" || fail "cause missing"
grep -q "^+- sed -n '32,63p'" "$PR" || fail "diff missing"
grep -q "31,62p' cols prints" "$T/review/2026-11-06_first.md" || fail "drafting must not edit the task"

# The ../../etc edit is reduced to its basename, which names this task, so it
# can only ever reach this task: that is why it is kept.
jq -r '.edits[].file' "$PJ" | grep -vqxE '2026-11-06_(first|second)\.md' && fail "edit outside the brief kept"

# ── apply ──────────────────────────────────────────────────────────────────
P --apply first >/dev/null || fail "apply failed"
grep -q "32,63p' cols prints" "$T/review/2026-11-06_first.md" || fail "task not edited"
grep -q "31,62p' starts at the CREATE" "$T/review/2026-11-06_first.md" || fail "history was changed"
grep -q "32,63p' cols again" "$T/inbox/2026-11-06_second.md" || fail "sibling not edited"
cmp -s "$tmp/other.before" "$T/inbox/2026-11-06_other.md" || fail "other brief's task was changed"
[ -f "$PJ" ] && fail "json should be removed after apply"
grep -q '^_Applied ' "$PR" || fail "proposal not marked applied"

# ── apply refuses stale edits, all or nothing ──────────────────────────────
P first >/dev/null 2>&1 || true   # the old text is gone now: nothing kept
[ -f "$PJ" ] && fail "no edit should be kept once applied"
cat > "$STUB_ANSWER" <<'EOF'
===CAUSE===
category: bad-criterion
x
===EDIT 2026-11-06_first.md===
---OLD---
- single line A
---NEW---
- B
===END EDIT===
===END===
EOF
sed -i 's/^- dup line$/- single line A/; 0,/^- single line A$/! s/^- single line A$/- dup line/' "$T/review/2026-11-06_first.md"
P first >/dev/null 2>&1 || fail "second draft failed"
[ -f "$PJ" ] || fail "second draft kept nothing"
sed -i 's/^- single line A$/- edited by hand/' "$T/review/2026-11-06_first.md"
before=$(sha256sum "$T/review/2026-11-06_first.md")
P --apply first >/dev/null 2>&1 && fail "stale apply should fail"
[ "$before" = "$(sha256sum "$T/review/2026-11-06_first.md")" ] || fail "stale apply changed the file"

# ── failures write nothing and pause nothing ───────────────────────────────
rm -f "$PR" "$PJ"
: > "$STUB_ANSWER"
P first >/dev/null 2>&1 && fail "empty answer should exit 1"
[ -e "$PR" ] && fail "empty answer wrote a proposal"
echo 'STUB-AUTH-FAIL' > "$STUB_ANSWER"
P first >/dev/null 2>&1 && fail "auth failure should exit 1"
[ -e "$PR" ] && fail "auth failure wrote a proposal"
ls "$T"/.auth-cooldown-* >/dev/null 2>&1 && fail "a cooldown marker was touched"
STUB_RC=124 P first >/dev/null 2>&1 && fail "timeout should exit 1"

# ── orphan proposals are cleared ───────────────────────────────────────────
printf 'x\n' > "$T/review/2026-11-06_gone.proposal"
printf '{}\n' > "$T/review/2026-11-06_gone.proposal.json"
cp "$tmp/answer" "$tmp/answer.bak"; printf '===CAUSE===\ncategory: implementation\nx\n===END===\n' > "$STUB_ANSWER"
P first >/dev/null 2>&1 || fail "implementation-only draft failed"
[ -e "$T/review/2026-11-06_gone.proposal" ] && fail "orphan proposal kept"
grep -q '^(none)$' "$PR" || fail "no-edit proposal should say (none)"
[ -e "$PJ" ] && fail "no-edit proposal must not leave json"

# ── slug resolution ────────────────────────────────────────────────────────
P nothing-here >/dev/null 2>&1 && fail "unknown slug should fail"
P ../inbox/2026-11-06_second >/dev/null 2>&1 && fail "a path must not reach outside review/"

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)" >&2; exit 1; }
echo "OK: ai-propose"
