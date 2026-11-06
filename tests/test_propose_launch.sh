#!/bin/bash
# End-to-end check of ai-task's launch of ai-propose when grading sends a task
# to review/: the proposal runs DETACHED and does NOT hold the project lock,
# and review_proposals=0 turns it off. Stub provider, stub ai-eval (exit 5,
# UNSATISFIABLE), stub ai-propose. Throwaway tree only.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home" TASKS_DIR="$tmp/tasks"
T="$TASKS_DIR"
mkdir -p "$HOME" "$T"/{inbox,review,done,run,projects,.locks} "$tmp/work"
APP="$tmp/app"; mkdir -p "$APP/providers"
cp "$REPO_DIR/ai-task" "$REPO_DIR/lib.sh" "$APP/"
cat > "$APP/providers/stub.sh" <<'EOF'
ai_run() { printf '{"result":"## Summary\\ndone"}\n' > "$5"; : > "$6"; }
ai_json_text() { jq -r '.result // empty' "$1" 2>/dev/null; }
ai_usage_table() { :; }
ai_is_auth_failure() { return 1; }
ai_model_alias() { printf '%s\n' "$1"; }
ai_preamble_extra() { :; }
EOF
cat > "$APP/ai-eval" <<'EOF'
#!/bin/bash
printf '## Unsatisfiable Criteria\n- x: `true` -> 0\n\nVERDICT: UNSATISFIABLE\n'
exit 5
EOF
cat > "$APP/ai-propose" <<EOF
#!/bin/bash
# Records whether the project lock is free while the proposal runs.
if flock -n "$T/.locks/demo.lock" true; then echo free > "$tmp/lock-state"
else echo held > "$tmp/lock-state"; fi
echo "\$1" > "$tmp/proposed"
EOF
chmod +x "$APP/ai-eval" "$APP/ai-propose"
printf '# demo\n\n## Working Directory\n%s\n' "$tmp/work" > "$T/projects/demo.md"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

run_task() {
    printf '## Project\ndemo\n\n## Tasks\n1. x\n\n## Acceptance Criteria\n- x\n' > "$T/run/$1.md"
    "$APP/ai-task" --run "$T/run/$1.md" --runner stub >/dev/null 2>&1 || true
}
wait_for() { for _ in $(seq 50); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }

printf 'default_runner=stub\n' > "$APP/config"
run_task 2026-11-06_first
[ -f "$T/review/2026-11-06_first.md" ] || fail "task not moved to review/"
wait_for "$tmp/proposed" || fail "ai-propose was not launched"
[ "$(cat "$tmp/proposed" 2>/dev/null)" = 2026-11-06_first ] || fail "wrong task name passed"
[ "$(cat "$tmp/lock-state" 2>/dev/null)" = free ] || fail "project lock held by the proposal"

rm -f "$tmp/proposed" "$tmp/lock-state"
printf 'default_runner=stub\nreview_proposals=0\n' > "$APP/config"
run_task 2026-11-06_second
[ -f "$T/review/2026-11-06_second.md" ] || fail "second task not moved to review/"
sleep 1
[ -e "$tmp/proposed" ] && fail "review_proposals=0 still launched ai-propose"

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)" >&2; exit 1; }
echo "OK: ai-task launches ai-propose"
