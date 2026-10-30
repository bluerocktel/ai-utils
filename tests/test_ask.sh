#!/bin/bash
# Offline regression test for ai-ask.
#
# Builds a throwaway HOME, TASKS_DIR, agents root and journal, and runs a copy
# of the scripts with its own config. The answer comes from a fake codex on
# PATH, so no test can reach a real CLI; it records each call and its prompt.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
export TASKS_DIR="$tmp/tasks"
T="$TASKS_DIR"
A="$tmp/agents"
S="$T/scheduled"
J="$tmp/brain/personal/journal"
mkdir -p "$HOME" "$S/.state" "$A" "$J"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

APP="$tmp/app"
mkdir -p "$APP/providers" "$tmp/bin"
cp "$REPO_DIR/ai-ask" "$REPO_DIR/lib.sh" "$APP/"
cp "$REPO_DIR/providers/codex.sh" "$APP/providers/"
printf 'default_runner=nonexistent\nask_runner=codex\nauth_cooldown_min=30\nagents_root=%s\nbrain_root=%s\n' \
    "$A" "$tmp/brain" > "$APP/config"
cat > "$tmp/bin/codex" <<'FAKE'
#!/bin/bash
echo call >> "$CALLS"
cat > "$PROMPT_OUT"
printf '%s' "${FAKE_STDERR:-}" >&2
[ -n "${FAKE_EMPTY:-}" ] || jq -cn --arg t "${FAKE_ANSWER:-It ran on 2026-10-05.}" \
    '{type:"turn.started"},
     {type:"item.completed", item:{type:"agent_message", text:$t}},
     {type:"turn.completed", usage:{input_tokens:1, output_tokens:1}}'
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$tmp/bin/codex"
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" PROMPT_OUT="$tmp/prompt"
: > "$CALLS"
calls() { wc -l < "$CALLS" | tr -d ' '; }
Q() { "$APP/ai-ask" "$@" </dev/null; }

# ── fixtures ───────────────────────────────────────────────────────────────
mkdir -p "$A/mail/routines" "$A/idle"
printf '## Domain: Customer mail into briefs\n## Permission-Ceiling: propose\n\nCHARTER-BODY\n' > "$A/mail/AGENT.md"
printf '## Domain: Nothing yet\n' > "$A/idle/AGENT.md"
printf '## Kind: monitor\n## Schedule: every:1h\n## Agent: mail\n\nDEFINITION-DRAFT\n' > "$A/mail/routines/inbound.md"
printf '## Kind: monitor\n## Schedule: every:1h\n## Agent: mail\n\nDEFINITION-PUBLISHED\n' > "$S/inbound.md"
printf '## Kind: monitor\n## Schedule: daily\n## Agent: mail\n\nDEFINITION-WEEKLY\n' > "$A/mail/routines/weekly.md"
printf '2026-10-05 20:08 | perm=propose | signal=no | nothing\n2026-10-05 20:13 | perm=propose | signal=yes | messages=2, briefs=b1, report=monitor-inbound-2026-10-05.md\n' \
    > "$S/.state/inbound.memory.md"
date -d '2026-10-05 20:13' +%s > "$S/.state/inbound.run"
{ echo SNAPSHOT-START; head -c 9000 /dev/zero | tr '\0' 'x'; echo; } > "$S/.state/inbound.snapshot.md"
echo REPORT-BODY > "$J/monitor-inbound-2026-10-05.md"

# ── listing ────────────────────────────────────────────────────────────────
OUT=$(Q)
printf '%s\n' "$OUT" | grep -qE '^  mail +2 routine\(s\), 1 published +Customer mail into briefs' \
    || fail "listing of mail: $OUT"
printf '%s\n' "$OUT" | grep -qE '^  idle +0 routine\(s\), 0 published' || fail "listing of idle"
[ "$(calls)" -eq 0 ] || fail "listing must make no call"

# ── refusals: no call, exit 2 ───────────────────────────────────────────────
rc=0; Q nosuch "hi" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown agent must exit 2 (got $rc)"
rc=0; Q ../mail "hi" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "a path as agent name must exit 2 (got $rc)"
rc=0; Q mail >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "no question must exit 2 (got $rc)"
[ "$(calls)" -eq 0 ] || fail "refusals must make no call"

# ── --context: what the agent is given, no call ────────────────────────────
CTX=$(Q mail --context)
for want in CHARTER-BODY DEFINITION-PUBLISHED DEFINITION-WEEKLY REPORT-BODY SNAPSHOT-START \
        'Status: published; last run 2026-10-05 20:13' 'Status: NOT published' \
        'signal=yes | messages=2, briefs=b1' '[truncated: 4000 of'; do
    [[ "$CTX" == *"$want"* ]] || fail "context lacks '$want'"
done
[[ "$CTX" == *DEFINITION-DRAFT* ]] && fail "a published routine must show its published copy"
[ "$(calls)" -eq 0 ] || fail "--context must make no call"

# ── a question, by argument and by stdin ───────────────────────────────────
OUT=$(Q mail when did you last find something)
[ "$OUT" = "It ran on 2026-10-05." ] || fail "answer not printed: '$OUT'"
[ "$(calls)" -eq 1 ] || fail "one question must be one call"
grep -q 'QUESTION: when did you last find something' "$tmp/prompt" || fail "question not in prompt"
grep -q CHARTER-BODY "$tmp/prompt" || fail "context not in prompt"
grep -q 'using ONLY this material' "$tmp/prompt" || fail "grounding rule not in prompt"
OUT=$(echo "what is overdue" | "$APP/ai-ask" mail)
grep -q 'QUESTION: what is overdue' "$tmp/prompt" || fail "stdin question not used"

# ── failures: exit 1, no cooldown marker, nothing written ──────────────────
before=$(find "$T" "$A" "$tmp/brain" -printf '%p %T@\n' | sort)
rc=0; ERR=$(FAKE_EMPTY=1 FAKE_STDERR='Please run codex login' Q mail "hi" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] || fail "auth failure must exit 1 (got $rc)"
[[ "$ERR" == *"auth failure"* ]] || fail "auth failure not reported: $ERR"
[ ! -e "$T/.auth-cooldown-codex" ] || fail "ai-ask must not create a cooldown marker"
rc=0; FAKE_EMPTY=1 Q mail "hi" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "empty answer must exit 1 (got $rc)"
[ "$before" = "$(find "$T" "$A" "$tmp/brain" -printf '%p %T@\n' | sort)" ] || fail "ai-ask wrote something"

touch "$T/.auth-cooldown-codex"
n=$(calls)
rc=0; ERR=$(Q mail "hi" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] && [ "$(calls)" -eq "$n" ] || fail "a runner in cooldown must not be called"
[[ "$ERR" == *"auth cooldown"* ]] || fail "cooldown not reported"

if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: ai-ask"
    exit 0
fi
echo "$FAILURES failure(s)" >&2
exit 1
