#!/usr/bin/env bash
# ai_is_auth_failure (providers/claude.sh) on the expired-login wording seen on
# 2026-11-25, where the error text came back as the JSON .result.
set -u
cd "$(dirname "$0")/.." || exit 1
source providers/claude.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
msg='Failed to authenticate: this login reached its time limit and cannot be renewed. Run `claude auth login` to sign in again, or use `claude setup-token` and set CLAUDE_CODE_OAUTH_TOKEN for unattended jobs'
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected $2, got $3)"; fi; }
jq -n --arg r "$msg" '{type:"result", result:$r}' > "$tmp/json"; ai_is_auth_failure "$tmp/json"; check "expired login as .result" 0 $?
printf '%s\n' "$msg" > "$tmp/stderr"; ai_is_auth_failure "$tmp/stderr"; check "expired login on stderr" 0 $?
jq -n '{type:"result", result:"I fixed the bug and the tests pass."}' > "$tmp/ok"; ai_is_auth_failure "$tmp/ok"; check "normal result" 1 $?
jq -n '{type:"result", result:"The report mentions Unauthorized access handling in the controller."}' > "$tmp/quote"; ai_is_auth_failure "$tmp/quote"; check "broad word quoted in a real result" 1 $?
echo "SUMMARY: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
