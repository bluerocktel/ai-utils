#!/bin/bash
# Provider adapter for the `grok` CLI (runner name: `grok`).
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

    # Flags live in ARRAYS, never unquoted strings, so a model id or a path
    # containing a space, a bracket or a glob character stays one argument.
    local -a model_args=() cwd_args=()
    [ -n "$model_id" ] && model_args=(--model "$model_id")

    # This CLI takes the working directory as a flag, so no cd is needed.
    # A workdir that is not a directory is ignored rather than fatal: the
    # caller resolved it from a project file that may point at a repo not
    # cloned here, and refusing to run would strand the task.
    [ -n "$workdir" ] && [ -d "$workdir" ] && cwd_args=(--cwd "$workdir")

    # stdout and stderr go to two SEPARATE files, never 2>&1. Merged stderr
    # prepends warnings to the JSON, jq then fails, and the result report
    # silently comes out empty. Auth detection scans both files, which is why
    # both must survive as separate files.
    case "$-" in *e*) had_e=1 ;; esac
    set +e
    timeout "$timeout_sec" \
        grok -p "$prompt" \
        --always-approve \
        "${model_args[@]}" \
        "${cwd_args[@]}" \
        --output-format json > "$json_out" 2> "$err_out"
    status=$?
    [ "$had_e" -eq 1 ] && set -e
    return "$status"
}

# ── 2. ai_json_text ──────────────────────────────────────────────────────────
# ai_json_text JSON_FILE  →  the agent's response text on stdout.
#
# This CLI puts the answer in `.text`. Empty output when the field is absent or
# null, or when the file is not valid JSON: that is the NORMAL shape of an
# interrupted or killed run and must not be an error.
#
# Deliberately no fallback to the other provider's field (the fork this was
# ported from tried `.text // .result`). A capture that came out of the wrong
# CLI must read as empty here, so a mis-routed task is caught as "no result"
# instead of being silently reported as a success.
#
# Returns 0 whenever the file was readable, even for empty text; non-zero only
# when JSON_FILE does not exist.
ai_json_text() {
    local json_file="${1:-}"
    [ -f "$json_file" ] || return 1
    jq -r '.text // empty' "$json_file" 2>/dev/null || true
    return 0
}

# ── 3. ai_usage_table ────────────────────────────────────────────────────────
# ai_usage_table JSON_FILE OUT_FILE
#
# Writes a self-contained `## Token Usage` fragment to OUT_FILE (no leading
# blank line: ai-task splices it straight into the report).
#
# ALWAYS returns 0. This CLI reports usage under `modelUsage` in BOTH camelCase
# and snake_case depending on the code path, and omits cost entirely on some
# auth paths, so every value is read through a `//` chain ending in "n/a" and a
# missing `modelUsage` still produces a placeholder row rather than a dangling
# header. Cost reporting must never fail a task that did real work.
#
# No cache-write column: this CLI does not report it reliably, and an always
# "n/a" column reads as a bug rather than as an absent metric.
ai_usage_table() {
    local json="${1:-}" out="${2:-}"
    [ -n "$out" ] || return 0
    {
        echo "## Token Usage"
        echo ""
        echo "| Model | Input | Output | Cache Read | Cost |"
        echo "|-------|-------|--------|------------|------|"
        if jq -e '(.modelUsage // empty) | length > 0' "$json" >/dev/null 2>&1; then
            jq -r '
                .modelUsage | to_entries[] |
                "| \(.key) | \(.value.inputTokens // .value.input_tokens // "n/a") | \(.value.outputTokens // .value.output_tokens // "n/a") | \(.value.cacheReadInputTokens // .value.cache_read_input_tokens // "n/a") | $\(.value.costUSD // .value.cost_usd // "n/a") |"
            ' "$json" 2>/dev/null || echo "| (unparseable) | n/a | n/a | n/a | \$n/a |"
        else
            echo "| (none reported) | n/a | n/a | n/a | \$n/a |"
        fi
        echo ""
        echo "**Total cost:** \$$(jq -r '.total_cost_usd // .totalCostUSD // "n/a"' "$json" 2>/dev/null || echo 'n/a')"
        if jq -e '.sessionId // .session_id' "$json" >/dev/null 2>&1; then
            echo ""
            echo "**Session:** $(jq -r '.sessionId // .session_id // "n/a"' "$json" 2>/dev/null || echo 'n/a')"
        fi
    } > "$out" 2>/dev/null
    return 0
}

# ── 4. ai_is_auth_failure ────────────────────────────────────────────────────
# ai_is_auth_failure FILE  →  0 if the capture shows an auth/credentials
# failure, 1 otherwise (including a missing file, so an absent capture is
# never read as an auth failure).
#
# This is the circuit breaker: a hit means NO WORK HAPPENED, so the task is
# requeued without burning a retry and only this runner's queue is paused.
#
# Pattern set carried over verbatim from the fork it was ported from: it already
# covers the API-key variable, 401 wording in both HTTP and prose form, and the
# session-start failure this CLI emits when credentials are refused before any
# request goes out. Deliberately broad, because a false negative burns retries
# on a task that never ran, while a false positive only costs a cooldown.
ai_is_auth_failure() {
    local file="${1:-}"
    [ -f "$file" ] || return 1
    grep -qiE \
        'API Error: 401|HTTP 401|status.?401|Invalid authentication|authentication (failed|error|required)|Failed to authenticate|not authenticated|Unauthorized|OAuth token|XAI_API_KEY|invalid.?api.?key|missing.?api.?key|auth.*(expired|invalid)|couldn.?t (start|create) session' \
        "$file"
}

# ── 5. ai_model_alias ────────────────────────────────────────────────────────
# ai_model_alias RAW  →  model id for ai_run, on stdout. Always returns 0.
#
# Empty RAW maps to EMPTY, not to a default: this CLI is left to pick its own
# model and ai_run then passes no --model flag at all. This is the one place
# the two providers genuinely disagree (the other resolves empty to an explicit
# default), which is exactly why the caller must not special-case the empty
# value itself.
#
# An unrecognised value is echoed back unchanged, not an error: a task may name
# any model id the CLI accepts without this table having to know it.
ai_model_alias() {
    local raw="${1:-}"
    case "$raw" in
        "")     printf '' ;;
        build)  printf '%s\n' 'grok-build' ;;
        *)      printf '%s\n' "$raw" ;;
    esac
    return 0
}

# ── 6. ai_preamble_extra ─────────────────────────────────────────────────────
# ai_preamble_extra TASK_FILE  →  text appended to the shared preamble.
#
# Empty today. This CLI has no agents directory and no skills mechanism, so the
# shared vendor-neutral preamble in ai-task is the whole preamble. The function
# still exists because the caller checks all six names are defined and refuses
# to run a provider that is missing one, rather than falling back to a default
# and silently sending the task to the wrong vendor.
#
# TASK_FILE is READ ONLY: this function must never modify the task.
ai_preamble_extra() {
    local task_file="${1:-}"
    : "$task_file"
    return 0
}
