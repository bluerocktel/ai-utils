#!/bin/bash
# Codex CLI adapter. Sourced after lib.sh; see CONTRACT.md.
# Raw stdout is JSONL, never mixed with stderr. No SDK or extra runtime needed.

ai_run() {
    local prompt="$1" model_id="$2" workdir="$3" timeout_sec="$4" json_out="$5" err_out="$6"
    local status
    local -a args=(exec --json --color never --skip-git-repo-check
        --dangerously-bypass-approvals-and-sandbox)
    [ -n "$model_id" ] && args+=(--model "$model_id")
    [ -n "$workdir" ] && [ -d "$workdir" ] && args+=(--cd "$workdir")

    # A conditional preserves the caller's shell options and the exact status.
    # stdin avoids argument-size limits and treats leading '-' as prompt data.
    if timeout "$timeout_sec" codex "${args[@]}" - \
        > "$json_out" 2> "$err_out" <<< "$prompt"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

ai_json_text() {
    local file="${1:-}"
    [ -f "$file" ] || return 1
    # Never return commentary from an interrupted/failed turn. Slurping also
    # makes a truncated JSON line yield no output rather than partial success.
    jq -sr '
        reduce .[] as $e ({text: "", complete: false};
            if $e.type == "turn.started" then {text: "", complete: false}
            elif $e.type == "item.completed" and $e.item.type == "agent_message"
                then .text = ($e.item.text // "")
            elif $e.type == "turn.completed" then .complete = true
            elif $e.type == "turn.failed" then .complete = false
            else . end)
        | select(.complete) | .text | select(type == "string")
    ' "$file" 2>/dev/null || true
    return 0
}

ai_usage_table() {
    local file="${1:-}" out="${2:-}" row
    [ -n "$out" ] || return 0
    # The last completion carries cumulative usage; summing would double-count.
    row=$(jq -sr '
        [.[] | select(.type == "turn.completed") | .usage] | last // {}
        | "| (not reported) | \(.input_tokens // "n/a") | \(.output_tokens // "n/a") | \(.cached_input_tokens // "n/a") |"
    ' "$file" 2>/dev/null) || row='| (not reported) | n/a | n/a | n/a |'
    {
        printf '## Token Usage\n\n'
        printf '| Model | Input | Output | Cache Read |\n'
        printf '|-------|-------|--------|------------|\n%s\n\n' "$row"
        # The event stream does not report billed dollars or a resolved model.
        printf '**Total cost:** \u0024%s\n' 'n/a'
    } > "$out" 2>/dev/null || true
    return 0
}

ai_is_auth_failure() {
    local file="${1:-}" errors
    [ -f "$file" ] || return 1
    # Inspect only CLI error events in JSONL, never agent prose or command
    # output (even a failed task may legitimately quote an HTTP 401).
    if jq -se 'length > 0 and all(.[]; type == "object" and has("type"))' \
        "$file" >/dev/null 2>&1; then
        errors=$(jq -sr '.[] | if .type == "error" then .message
            elif .type == "turn.failed" then .error.message
            else empty end | strings' "$file" 2>/dev/null) || errors=""
    else
        # stderr and incomplete captures are plain text.
        errors=$(cat "$file")
    fi
    printf '%s\n' "$errors" | grep -qiE \
        '(^|[^0-9])401([^0-9]|$)|unauthorized|invalid.?api.?key|incorrect.?api.?key|missing.?api.?key|authentication (failed|required|error)|failed to (authenticate|refresh.*token)|refresh_token_(reused|expired|invalidated)|token.*(expired|revoked)|not (logged|signed) in|please.*(log in|login|sign in)|codex login'
}

ai_model_alias() {
    # No cross-vendor aliases or pinned default: use the configured CLI model.
    printf '%s\n' "${1:-}"
    return 0
}

ai_preamble_extra() {
    # Keep the shared report format; repository instructions and available
    # skills are loaded by Codex itself. No vendor-specific workflow keyword.
    return 0
}
