#!/bin/bash
# Provider adapter for the `claude` CLI (runner name: `claude`).
#
# This file, and its sibling providers, are the ONLY place in the repo allowed
# to name a vendor, a vendor CLI, a vendor model id, or a vendor JSON field.
# Everything downstream (ai-task, ai-eval, ai-brief, the dashboard) calls the
# six functions below and never touches the CLI or a JSON field name directly.
# The contract is `providers/CONTRACT.md`; read it before changing a signature.
#
# Sourced, never executed: no `set -euo pipefail` here, because the caller's
# shell options are the caller's business and a provider that flipped them
# would change behaviour for every line after the source.

# ── 1. ai_run ────────────────────────────────────────────────────────────────
# ai_run PROMPT MODEL_ID WORKDIR TIMEOUT_SEC JSON_OUT ERR_OUT
#
# Runs one headless call to completion. Nothing on stdout: the CLI's stdout
# (the JSON document) goes to JSON_OUT, its stderr to ERR_OUT.
#
# Returns the CLI's exit status VERBATIM, including 124 from `timeout`. The
# caller distinguishes "timed out" (124, deferred without burning a retry)
# from "failed", so normalising it to 1 would silently start consuming retries
# on tasks that never got to finish.
ai_run() {
    local prompt="$1" model_id="$2" workdir="$3" timeout_sec="$4" json_out="$5" err_out="$6"
    local status had_e=0

    # Flags live in an ARRAY, never an unquoted string. The 1M-context model id
    # contains brackets (claude-opus-5[1m]) and there is no bracket-free
    # spelling the CLI accepts, so an unquoted flag was subject to pathname
    # expansion: a file named `claude-opus-51` in the task's working directory
    # silently rewrote --model to that filename. Verified under bash.
    local -a model_args=()
    [ -n "$model_id" ] && model_args=(--model "$model_id")

    # This CLI has no working-directory flag, so the provider cd's instead. The
    # cd happens in a subshell so the caller's $PWD survives the call.
    # A workdir that is not a directory is ignored rather than fatal: the caller
    # resolved it from a project file that may point at a repo not cloned here,
    # and refusing to run would strand the task.
    #
    # stdout and stderr go to two SEPARATE files, never 2>&1. Merged stderr
    # prepends warnings (workspace-trust notices, deprecations) to the JSON, jq
    # then fails, and the result report silently comes out empty. Auth
    # detection scans both files, which is why both must survive separately.
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    (
        if [ -n "$workdir" ] && [ -d "$workdir" ]; then
            cd "$workdir" || exit 126
        fi
        exec timeout "$timeout_sec" \
            claude --dangerously-skip-permissions "${model_args[@]}" \
            -p "$prompt" \
            --output-format json
    ) > "$json_out" 2> "$err_out"
    status=$?
    [ "$had_e" -eq 1 ] && set -e
    return "$status"
}

# ── 2. ai_json_text ──────────────────────────────────────────────────────────
# ai_json_text JSON_FILE  →  the agent's response text on stdout.
#
# This CLI puts the answer in `.result`. Empty output when the field is absent
# or null, or when the file is not valid JSON: that is the NORMAL shape of an
# interrupted or killed run and must not be an error.
#
# Deliberately no fallback to the other provider's field. A capture that came
# out of the wrong CLI must read as empty here, so a mis-routed task is caught
# as "no result" instead of being silently reported as a success.
#
# Returns 0 whenever the file was readable, even for empty text; non-zero only
# when JSON_FILE does not exist.
ai_json_text() {
    local json_file="${1:-}"
    [ -f "$json_file" ] || return 1
    jq -r '.result // empty' "$json_file" 2>/dev/null || true
    return 0
}

# ── 3. ai_usage_table ────────────────────────────────────────────────────────
# ai_usage_table JSON_FILE OUT_FILE
#
# Writes a self-contained `## Token Usage` fragment to OUT_FILE (no leading
# blank line: ai-task splices it straight into the report).
#
# ALWAYS returns 0. Cost reporting must never fail a task that did real work,
# so every value carries a `// "n/a"` fallback and a missing `modelUsage`
# still produces a placeholder row rather than a dangling header.
ai_usage_table() {
    local json="${1:-}" out="${2:-}"
    [ -n "$out" ] || return 0
    {
        echo "## Token Usage"
        echo ""
        echo "| Model | Input | Output | Cache Read | Cache Write | Cost |"
        echo "|-------|-------|--------|------------|-------------|------|"
        if jq -e '(.modelUsage // empty) | length > 0' "$json" >/dev/null 2>&1; then
            jq -r '
                .modelUsage | to_entries[] |
                "| \(.key) | \(.value.inputTokens // .value.input_tokens // "n/a") | \(.value.outputTokens // .value.output_tokens // "n/a") | \(.value.cacheReadInputTokens // .value.cache_read_input_tokens // "n/a") | \(.value.cacheCreationInputTokens // .value.cache_creation_input_tokens // "n/a") | $\(.value.costUSD // .value.cost_usd // "n/a") |"
            ' "$json" 2>/dev/null || echo "| (unparseable) | n/a | n/a | n/a | n/a | \$n/a |"
        else
            echo "| (none reported) | n/a | n/a | n/a | n/a | \$n/a |"
        fi
        echo ""
        echo "**Total cost:** \$$(jq -r '.total_cost_usd // "n/a"' "$json" 2>/dev/null || echo 'n/a')"
        echo ""
        # Turns is the actionable size signal: cache-read tokens dominate cost
        # and scale with turns x context, so a high turn count flags a task
        # that should have been split even when it touched few files.
        echo "**Turns:** $(jq -r '.num_turns // "n/a"' "$json" 2>/dev/null || echo 'n/a')"
    } > "$out" 2>/dev/null
    return 0
}

# ── 4. ai_is_auth_failure ────────────────────────────────────────────────────
# ai_is_auth_failure FILE  →  0 if the capture shows an auth/credentials
# failure, 1 otherwise (including a missing file, so an absent capture is
# never read as an auth failure).
#
# This is the circuit breaker: a hit means NO WORK HAPPENED, so the task is
# requeued without burning a retry and only this runner's queue is paused. The
# pattern set is deliberately broad, because a false negative burns retries on
# a task that never ran, while a false positive only costs a cooldown.
ai_is_auth_failure() {
    local file="${1:-}"
    [ -f "$file" ] || return 1
    grep -qiE \
        'API Error: 401|HTTP 401|status.?401|Invalid authentication|authentication (failed|error|required)|Failed to authenticate|not authenticated|Unauthorized|OAuth token( has)? expired|OAuth token revoked|credentials? (expired|invalid|missing)|please run .?claude login|ANTHROPIC_API_KEY' \
        "$file"
}

# ── 5. ai_model_alias ────────────────────────────────────────────────────────
# ai_model_alias RAW  →  model id for ai_run, on stdout. Always returns 0.
#
# Aliases stay BARE ('opus', 'sonnet', ...) rather than pinned dated ids: the
# CLI resolves a bare alias to the latest model of that tier, so this table
# stops going stale. Pinning `opus` to a dated id meant a task declaring
# `## Model: opus` got an OLDER model than a task declaring nothing.
#
# An empty RAW yields an EXPLICIT default, never an empty string. Letting an
# empty ## Model inherit the session default put ~86% of all spend on the 1M
# context tier that no task had asked for. Standard-tier Opus is identical in
# quality below 200k context, which every task should be under given the
# file-count and phase-count size rules; `opus1m` is the opt-in escape hatch
# for a task that genuinely needs the big window.
#
# An unrecognised value is echoed back unchanged, not an error: a task may name
# any model id the CLI accepts without this table having to know it.
ai_model_alias() {
    local raw="${1:-}"
    case "$raw" in
        opus)               printf '%s\n' 'opus' ;;
        opus1m)             printf '%s\n' 'claude-opus-5[1m]' ;;
        sonnet)             printf '%s\n' 'sonnet' ;;
        haiku)              printf '%s\n' 'haiku' ;;
        fable)              printf '%s\n' 'fable' ;;
        "")                 printf '%s\n' 'opus' ;;
        *)                  printf '%s\n' "$raw" ;;
    esac
    return 0
}

# ── 6. ai_preamble_extra ─────────────────────────────────────────────────────
# ai_preamble_extra TASK_FILE  →  text appended to the shared preamble.
#
# Everything vendor-neutral (no-questions, no-waiting, ## Summary,
# ## Suggested Commit Message, never-revert-other-tasks'-work) stays in
# ai-task. Only what names a vendor feature belongs here.
#
# TASK_FILE is READ ONLY: this function must never modify the task.
ai_preamble_extra() {
    local task_file="${1:-}"

    echo "After the ## Summary, always add a ## Tools Used section listing: (1) Agents: any agents from ~/.claude/agents/ that were invoked (list by name, or 'none'); (2) Skills: any skills that were invoked (list by name, or 'none'). Put ## Tools Used before ## Suggested Commit Message."
    echo ""
    echo "Before starting work, check whether any available skill (listed in the system-reminder) matches this task type and invoke the relevant one via the Skill tool."

    # A `## Workflow` section opts the task into multi-agent orchestration. The
    # keyword has to appear in the prompt text for the harness to pick it up;
    # this function can only append, so it is emitted as its own line rather
    # than as a literal prefix. Same effect, since detection scans the prompt.
    if [ -n "$task_file" ] && [ -f "$task_file" ] && grep -q '^## Workflow' "$task_file"; then
        echo ""
        echo "ultracode: this task carries a ## Workflow section, so run it as a dynamic multi-agent workflow rather than solo."
    fi
    return 0
}
