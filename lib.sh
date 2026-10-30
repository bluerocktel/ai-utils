#!/bin/bash
# Shared helpers for ai-utils. Sourced by every `ai-*` script (ai-task,
# ai-eval, ai-brief, ai-briefs, the dashboard, ...).
#
# This file is PROVIDER-NEUTRAL by contract: it must never name a vendor, a
# vendor CLI, a vendor model id, or a vendor JSON field. Anything that differs
# between runners (how the CLI is invoked, which JSON field holds the result
# text, what a usage table looks like, what an auth failure looks like, model
# aliases, preamble additions) lives in `providers/<runner>.sh` behind the
# six-function contract documented in `providers/CONTRACT.md`.

# Root of the pipeline. One shared tree for every runner: the runner is a field
# on the task, not a separate directory tree. The override exists so smoke
# tests can point at a throwaway tree under /tmp.
TASKS_DIR="${TASKS_DIR:-$HOME/tasks}"

INBOX="$TASKS_DIR/inbox"
RUN_DIR="$TASKS_DIR/run"
DONE_DIR="$TASKS_DIR/done"
REVIEW_DIR="$TASKS_DIR/review"
PROJECTS_DIR="$TASKS_DIR/projects"
BRIEFS_DIR="$TASKS_DIR/briefs"
BRIEFS_DONE_DIR="$TASKS_DIR/briefs/done"
BACKLOG_REVIEW_DIR="$TASKS_DIR/backlog-for-review"
LOCK_DIR="$TASKS_DIR/.locks"
LOG="$TASKS_DIR/DONE.md"

# Recurring-job engine (ai-scheduled). All four of these already exist in the
# live tree: they are referenced here, never created as new pipeline stages.
#   scheduled/         job definitions, one <slug>.md per job
#   scheduled/.state/  per-job bookkeeping: <slug>.run (epoch seconds of the
#                      last successful dispatch) and <slug>.snapshot.md
#   suggestions/       machine-proposed follow-up stubs, for the human to read
#   backlog/           read-only here: it belongs to a flow this repo does not
#                      implement, and is consulted only so slug_exists can see
#                      work that is already tracked there.
SCHEDULED_DIR="$TASKS_DIR/scheduled"
SCHED_STATE_DIR="$TASKS_DIR/scheduled/.state"
SUGGEST_DIR="$TASKS_DIR/suggestions"
BACKLOG_DIR="$TASKS_DIR/backlog"

# Path of the auth-cooldown marker for one runner.
#   cooldown_path <runner>  →  $TASKS_DIR/.auth-cooldown-<runner>
#
# PER RUNNER on purpose: an auth failure on one provider must never pause the
# queue of another. There is deliberately no single shared COOLDOWN variable.
cooldown_path() {
    local runner="${1:-}"
    runner=$(printf '%s' "$runner" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$runner" ] || return 1
    printf '%s\n' "$TASKS_DIR/.auth-cooldown-${runner}"
}

# Resolve ## Runner from a task file to a runner name.
# Reads the section exactly like model_from_task reads ## Model: first
# non-heading line under the heading, whitespace stripped, lowercased.
#
# An absent, empty, or literal "any" value resolves to `default_runner` from
# config — NEVER to "any" and never to "every runner". The vast majority of
# existing task files carry no ## Runner section (and the scheduled-job engine
# keeps emitting more), so the unset case is the common case and must land on
# the configured default.
#
# Returns 1 and prints nothing when the section is unset AND `default_runner`
# is unset, which is a config error the caller must surface rather than guess
# at. Call load_config before this.
runner_from_task() {
    local task_file="$1" raw
    # A missing/unreadable task file must not resolve silently to the default:
    # that would route work to a runner on the strength of a typo'd path.
    [ -r "$task_file" ] || return 1
    raw=$(awk '/^## Runner/{found=1; next} found && /^[^#]/{print $1; exit} found && /^##/{exit}' "$task_file" \
        | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        ""|any) raw="${default_runner:-}" ;;
    esac
    [ -n "$raw" ] || return 1
    printf '%s\n' "$raw"
}

# Read one "## Field" value from a file, accepting BOTH header spellings:
#
#   ## Kind: monitor          inline form, used by scheduled job files
#   ## Kind monitor           inline form, space separator
#   ## Project\nbrteladmin     next-line form, used by task files
#
# The field name is matched case-insensitively. Prints the trimmed value on
# stdout; empty output means the field is absent, which is not an error.
#
# This is an ADDITION, never a replacement for runner_from_task /
# model_from_task / project_from_task. Those read the next-line form only and
# must keep behaving exactly as they do today: thousands of existing task files
# depend on their precise semantics, and a "unification" here would change how
# every one of them is parsed.
field_from_task() {
    local field="$1" file="$2" line val
    [ -r "$file" ] || return 0

    # grep exits 1 when the field is absent, which is the common case and must
    # not abort a caller running under `set -e`.
    line=$(grep -m1 -iE "^##[[:space:]]+${field}[:[:space:]]" "$file" 2>/dev/null || true)
    val=""
    if [ -n "$line" ]; then
        val=$(printf '%s' "$line" | sed -E "s/^##[[:space:]]+${field}[:[:space:]]*//I")
        val=$(printf '%s' "$val" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    fi

    # An inline heading whose value is empty ("## Project " with a trailing
    # space) is a next-line heading that happened to match the inline pattern.
    # Fall through rather than reporting the field as absent.
    if [ -z "$val" ]; then
        # The heading is compared with its trailing whitespace trimmed: a
        # "## Project " line (trailing space) matched the inline pattern above
        # and yielded nothing, and an exact-equality test here would then miss
        # it too, reporting a field that is plainly present as absent.
        val=$(awk -v f="$field" '
            BEGIN { want = tolower("## " f) }
            { line = tolower($0); sub(/[[:space:]]+$/, "", line) }
            line == want { getline; if ($0 !~ /^#/) print; exit }
        ' "$file")
    fi

    printf '%s' "$val" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}
# Print every line of one "## Section" of a file: everything after the heading
# up to the next line beginning with "##", or EOF.
#
#   section_from_task Relationships ~/tasks/projects/brteladmin.md
#
# Companion to field_from_task, not a replacement for it: field_from_task
# returns ONE line (the inline value, else the line after the heading), which
# is right for ## Runner / ## Model / ## Project and wrong for a multi-line
# bullet block like ## Relationships.
#
# The heading match is case-insensitive and tolerates both "## Name" and
# "## Name:". An absent section prints nothing and returns 0: callers run under
# `set -e`, and a project file with no such section is the common case.
section_from_task() {
    local field="$1" file="$2"
    [ -r "$file" ] || return 0
    awk -v f="$field" '
        /^##/ {
            line = tolower($0)
            sub(/[[:space:]]+$/, "", line)
            sub(/:$/, "", line)
            insec = (line == tolower("## " f))
            next
        }
        insec { print }
    ' "$file" | tr -d '\r'
    return 0
}

# Outbound propagation targets declared by one project, one per line, as
# "verb<TAB>alias":
#
#   project_relationship_targets brteladmin
#   → mirror<TAB>oryn
#     content<TAB>brtelsite
#     content<TAB>marketing
#
# Reads the ## Relationships section of $PROJECTS_DIR/<project>.md and matches
# bullets of the form "- <verb> <arrow> <alias>: <prose>".
#
# VERB HANDLING IS PERMISSIVE, TARGET HANDLING IS STRICT. Any verb is passed
# through rather than being checked against a hardcoded mirror|content list:
# the live tree already carries a `host` verb, and a closed list drops it
# silently. What gets validated is the TARGET, by the caller, against this set
# plus the existence of the target's own project file. A verb this repo has
# never seen is a label on a proposal a human still has to promote; an
# unvalidated target is a write attributed to a project that may not exist.
#
# Both arrow spellings are accepted: the real project files use the Unicode
# arrow (U+2192), while ai-scheduled's planner prompt advertises the ASCII
# "->". No project file is rewritten either way.
#
# Prints nothing and returns 0 when the project file is missing, has no
# ## Relationships section, or declares "(none ...)" — the last case falls out
# for free, since it is not a bullet.
project_relationship_targets() {
    local project="${1:-}" file
    [ -n "$project" ] || return 0
    # A path component in the alias would read a project file outside the tree.
    project=$(basename "$project" | tr -cd '[:alnum:]._-')
    [ -n "$project" ] || return 0
    file="$PROJECTS_DIR/${project}.md"
    [ -r "$file" ] || return 0

    section_from_task Relationships "$file" \
        | sed 's/\xe2\x86\x92/->/g' \
        | awk '
            /^[[:space:]]*-[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*->[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*:/ {
                line = $0
                sub(/^[[:space:]]*-[[:space:]]+/, "", line)
                split(line, part, /[[:space:]]*->[[:space:]]*/)
                verb = part[1]
                sub(/[[:space:]]+$/, "", verb)
                rest = part[2]
                alias = substr(rest, 1, index(rest, ":") - 1)
                gsub(/[[:space:]]/, "", alias)
                if (verb != "" && alias != "") printf "%s\t%s\n", verb, alias
            }
        '
    return 0
}

# Resolve the runner for a scheduled JOB file (## Runner, either spelling).
#
# Identical resolution rule to runner_from_task, for the identical reason: an
# absent, empty, or literal "any" value means `default_runner` from config and
# never "every runner". A job whose runner is implicit still routes
# predictably, and the live email-triage job (which has no ## Runner section)
# keeps running on the configured default with no edit to the job file.
#
# Returns 1 and prints nothing when the section is unset AND `default_runner`
# is unset. Call load_config first.
runner_from_job() {
    local file="$1" raw
    [ -r "$file" ] || return 1
    raw=$(field_from_task Runner "$file" | awk '{print $1}' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        ""|any) raw="${default_runner:-}" ;;
    esac
    [ -n "$raw" ] || return 1
    printf '%s\n' "$raw"
}

# ── Agent layer ─────────────────────────────────────────────────────────────
# Three readers for the agent layer documented in agents/CONTRACT.md. They live
# here, next to runner_from_job, because they read the same inline
# "## Field: value" job-file headers through the same field_from_task.
#
# They are ADDITIONS. runner_from_task / model_from_task / project_from_task /
# field_from_task / runner_from_job are untouched: thousands of existing task
# files depend on their exact semantics.
#
# All three are safe under `set -euo pipefail` in every caller: an absent field
# is the common case here and never aborts.

# Owning agent of a scheduled JOB file, from its ## Agent header.
#   agent_from_job <file>  →  first token, lowercased, reduced to [a-z0-9-]
#
# Prints nothing and returns 0 when the header is absent, empty, or reduces to
# nothing. That empty result is the signal "this is a plain job, not an agent
# routine", and EVERY agent-layer behaviour must be gated on it. That gate is
# what keeps the job files already living in scheduled/ behaving byte-for-byte
# as they do today: none of them carries a ## Agent header, so none of them can
# accidentally acquire an agent's permissions, sources or memory.
agent_from_job() {
    local file="${1:-}" raw
    [ -n "$file" ] && [ -r "$file" ] || return 0
    raw=$(field_from_task Agent "$file" \
        | awk 'NR == 1 { print $1 }' \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd 'a-z0-9-')
    [ -n "$raw" ] || return 0
    printf '%s\n' "$raw"
}

# Permission level of a scheduled JOB file, from its ## Permission header.
#   permission_from_job <file>  →  exactly one of: read | propose | act
#
# Absent or empty prints `propose`. This is the ONE place the default lives:
# agents/CONTRACT.md documents it, nothing else may re-implement it. A new
# routine defaults to READ + PROPOSE so it cannot act on the world by omission.
#
# An unrecognised value prints NOTHING and returns 1. That has to be a hard
# skip upstream, never a silent downgrade to `read` (which would quietly stop a
# routine the human believes is running) and never a silent upgrade. An
# unreadable file is the same case: a permission that cannot be read is not a
# permission of `propose`.
permission_from_job() {
    local file="${1:-}" raw
    [ -n "$file" ] && [ -r "$file" ] || return 1
    raw=$(field_from_task Permission "$file" \
        | awk 'NR == 1 { print $1 }' \
        | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        "")                 printf 'propose\n' ;;
        read|propose|act)   printf '%s\n' "$raw" ;;
        *)                  return 1 ;;
    esac
}

# Path of one routine's persistent memory file.
#   agent_memory_path <slug>  →  $SCHED_STATE_DIR/<slug>.memory.md
#
# ADDITIVE state file in an EXISTING directory: scheduled/.state/ already holds
# <slug>.run and <slug>.snapshot.md. ~/tasks/ gains no new directory, and only
# `ai-*` scripts ever touch this file.
#
# Rejects an empty slug with return 1 rather than building a path with a hole
# in it, exactly like cooldown_path: ".memory.md" in the state directory would
# be a shared file every slugless caller wrote to.
agent_memory_path() {
    local slug="${1:-}"
    slug=$(printf '%s' "$slug" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$slug" ] || return 1
    printf '%s\n' "$SCHED_STATE_DIR/${slug}.memory.md"
}

# Root directory holding the agent-layer DEFINITIONS (agents/CONTRACT.md).
#   agents_dir  →  absolute path on stdout; always returns 0
#
# Definitions are charters and routines, not state: a routine's state stays in
# scheduled/.state/ and is reached through agent_memory_path. This resolves the
# DEFINITION root only, and only the two read-only viewers (ai-agent, dtask)
# ever call it. The engine never does: ai-scheduled reads the PUBLISHED job file
# in scheduled/, so where the definition came from cannot affect a run.
#
# Resolution order:
#   1. `agents_root` from config, when set and non-empty. Used VERBATIM.
#   2. $SCRIPT_DIR/agents, the in-repo default, when it exists.
#   3. $AI_LIB_DIR/agents, for a caller sourcing lib.sh from another directory.
#
# An explicit `agents_root` gets NO existence fallback, deliberately. Definitions
# are meant to be able to live outside this repo (a private repository, while
# this one is public), and falling back to the bundled agents/ when that path is
# unmounted or misspelled would silently list, validate and print publish plans
# for the wrong set of routines. Same reason load_provider refuses an unknown
# runner instead of defaulting: a silent fallback acts on the wrong thing. It
# warns once on stderr and still prints the path, so the caller renders its
# normal empty-tree output rather than aborting under `set -e`.
agents_dir() {
    local root="${agents_root:-}"
    if [ -n "$root" ]; then
        root="${root%/}"
        [ -d "$root" ] || echo "agents_dir: agents_root is set but '$root' is not a directory" >&2
        printf '%s\n' "$root"
        return 0
    fi
    root="${SCRIPT_DIR:-$AI_LIB_DIR}/agents"
    [ -d "$root" ] || root="$AI_LIB_DIR/agents"
    printf '%s\n' "$root"
}

# Resolve ## Model from a task file to a model id (empty = runner's default).
# Aliases are NOT expanded here: alias mapping is per provider (ai_model_alias).
model_from_task() {
    awk '/^## Model/{found=1; next} found && /^[^#]/{print; exit}' "$1" | tr -d '[:space:]'
}

# First non-heading line under ## Project.
project_from_task() {
    awk '/^## Project/{found=1; next} found && /^[^#]/{print $1; exit} found && /^##/{exit}' "$1"
}

# Canonical project name to use for the PER-PROJECT LOCK.
# Given a project file demo-proj.md whose ## Aliases lists demo-proj, demoproj
# and demo-project:
#   canonical_project demo-proj        -> demo-proj   (file exists, no scan)
#   canonical_project demoproj         -> demo-proj   (declared alias)
#   canonical_project DemoProj         -> demo-proj   (case-insensitive)
#   canonical_project totally-unknown  -> totally-unknown (passthrough)
#
# THE LOCK NAME MUST BE ONE PER REPOSITORY, and an alias is the same repository
# under another spelling. project_from_task prints the ## Project token
# verbatim, so a task written with a declared alias took a DIFFERENT lock file
# from a canonical one and the two could run inside the same git working tree at
# once. That is the single guarantee the unified tree rests on.
#
# This is an ADDITION. project_from_task / runner_from_task / model_from_task
# are untouched, and nothing else about what $PROJECT means changes: the
# project-file read, the prompt, the log and DONE.md all keep the raw value.
#
# SANITISES FIRST, before any lookup: the result is interpolated straight into
# a path under $LOCK_DIR, so a value carrying `/` or `..` would place the lock
# outside it. Same rule, same reason, as ai-brief's filename handling and
# write_stub's slug handling.
#
# Empty input prints nothing and returns 1 (a caller with no project takes no
# lock at all). Every other input prints a non-empty value containing no `/`
# and returns 0, including when $PROJECTS_DIR does not exist: a missing
# projects/ directory must degrade to today's behaviour, not abort a sweep.
canonical_project() {
    local raw="${1:-}" value lower stem file
    [ -n "$raw" ] || return 1

    value=$(basename "$raw" | tr -cd '[:alnum:]._-')
    # A value that sanitises away entirely (`///`, `@@@`) must still name a
    # lock: sharing one over-broad lock is safe, an empty name is not.
    [ -n "$value" ] || { printf '%s\n' "_unnamed"; return 0; }

    # The common case, and it must not pay for a scan.
    [ -f "$PROJECTS_DIR/${value}.md" ] && { printf '%s\n' "$value"; return 0; }

    [ -d "$PROJECTS_DIR" ] || { printf '%s\n' "$value"; return 0; }

    lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    for file in "$PROJECTS_DIR"/*.md; do
        [ -f "$file" ] || continue
        stem=$(basename "$file" .md)
        # Bullets look like "- `demo-proj`": leading dash, optional backticks,
        # optional whitespace. Compared case-insensitively, because lock
        # filenames are case-sensitive and the live tree really does carry a
        # value that differs from its project only in case. Hyphens stay
        # significant: `demo-proj` and `demoproj` are two distinct aliases that
        # a project file has to list separately.
        if section_from_task Aliases "$file" \
            | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/`//g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
            | tr '[:upper:]' '[:lower:]' \
            | grep -qxF -- "$lower"; then
            printf '%s\n' "$stem"
            return 0
        fi
    done

    # Matches nothing: today's behaviour, unchanged.
    printf '%s\n' "$value"
    return 0
}

# First non-heading line under ## Depends-on (first token only).
depends_on_from_task() {
    # Still "first token of the first line" (see CLAUDE.md section 5) - this does
    # NOT introduce joins. It only sanitises that token, which is almost always
    # written with markdown decoration:
    #     `2026-09-12_some-task.md` - why this task needs it
    # Keep only characters that can occur in a task filename, so backticks,
    # quotes, brackets and emphasis markers cannot leak into the slug and make
    # dep_satisfied() search for "*_`slug.md`.task.md", which can never match.
    awk '
        /^## Depends-on/ { found = 1; next }
        found && /^##/   { exit }
        found && /^[^#]/ {
            dep = $1
            gsub(/[^A-Za-z0-9._-]/, "", dep)
            if (dep != "") { print dep; exit }
        }
    ' "$1"
}

# Short slug from a task filename: strip .md and an optional YYYY-MM-DD_ prefix.
#   2026-08-13_c1-ch01.md  →  c1-ch01
#   c1-ch01.md             →  c1-ch01
task_slug_from_name() {
    local base
    base=$(basename "$1" .md)
    printf '%s\n' "$base" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}_//'
}

# True if dir contains slug + suffix, or *_slug + suffix (date-prefixed names).
slug_file_in_dir() {
    local dir="$1" suffix="$2" slug="$3"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    [ -n "$slug" ] || return 1
    [ -f "${dir}/${slug}${suffix}" ] && return 0
    find "$dir" -maxdepth 1 -type f -name "*_${slug}${suffix}" 2>/dev/null | grep -q .
}

# Where a ## Depends-on slug currently lives.
# Prints one of: none | done | review | inbox | run | backlog | missing
locate_dep_slug() {
    local slug="${1:-}"
    slug="${slug%.md}"
    if [ -z "$slug" ]; then
        echo none
        return 0
    fi
    if slug_file_in_dir "$DONE_DIR" ".task.md" "$slug"; then
        echo done
        return 0
    fi
    if slug_file_in_dir "$REVIEW_DIR" ".md" "$slug"; then
        echo review
        return 0
    fi
    if slug_file_in_dir "$INBOX" ".md" "$slug"; then
        echo inbox
        return 0
    fi
    if slug_file_in_dir "$RUN_DIR" ".md" "$slug"; then
        echo run
        return 0
    fi
    if slug_file_in_dir "$BACKLOG_REVIEW_DIR" ".md" "$slug"; then
        echo backlog
        return 0
    fi
    echo missing
}

# ── Blocked inbox tasks ────────────────────────────────────────────────────
#
# One TSV line per inbox/ task whose ## Depends-on is not satisfied:
#
#     <task-basename>\t<dep-slug>\t<location>
#
# <location> is locate_dep_slug's answer for the dep, and it sorts blocks into
# two kinds that need opposite responses from a human:
#
#   review | missing    DEAD. Nothing still moving through the pipeline can
#                       ever satisfy this dep, so the task waits forever.
#                       `review` is the common one: dep_satisfied accepts only
#                       done/*_<slug>.task.md, and a parent that reached
#                       review/ (failed evaluation, or an unsatisfiable
#                       criterion) never produces one.
#   inbox | run | backlog
#                       WAITING. Ordinary queue order, resolves on its own.
#
# A task whose dep is in done/ is not printed at all: it is runnable. So is a
# task with no ## Depends-on.
#
# This is the classification ai-task already performs inline on its "nothing
# eligible" branch. It lives here so the dashboard and the launcher cannot
# drift into disagreeing about what "blocked" means — a dashboard that called
# a task blocked while the launcher was happily claiming it would be worse
# than neither of them reporting anything.
#
# Deliberately NOT runner-aware, and it must stay that way. runner_matches is
# scoped to one invocation's --runner, while the dashboard reports across every
# runner at once; ai-task layers its own runner partition on top of this.
#
# Order is mtime, oldest first, matching inbox_by_age: the launcher reports in
# the order it would have claimed, and that is the order a reader expects.
blocked_inbox_tasks() {
    local f dep loc
    [ -d "$INBOX" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        dep=$(depends_on_from_task "$f")
        dep="${dep%.md}"
        [ -n "$dep" ] || continue
        loc=$(locate_dep_slug "$dep")
        [ "$loc" = "done" ] && continue
        printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$dep" "$loc"
    done < <(find "$INBOX" -maxdepth 1 -type f -name '*.md' -printf '%T@ %p\n' 2>/dev/null \
                 | sort -n | cut -d' ' -f2-)
}

# ── Awaiting-Eval (a finished run whose grading was deferred) ──────────────
#
# A task carries this section only in one situation: its work COMPLETED, the
# report was written, and then grading could not happen (the grader hit an auth
# failure). The value is the basename of the report in done/ that still needs a
# verdict.
#
# The point is that the next claim GRADES that report instead of executing the
# task again. Without it, a grader outage silently turns a finished run into a
# full re-run, which is the one thing that would make a separate `eval_runner`
# cost more than it is worth.

# First token of the first line under ## Awaiting-Eval.
awaiting_eval_from_task() {
    awk '/^## Awaiting-Eval/{found=1; next} found && /^[^#]/{print $1; exit} found && /^##/{exit}' "$1"
}

# Remove a ## Awaiting-Eval section (heading through the next ## heading).
strip_awaiting_eval_section() {
    local file="$1" tmp
    [ -f "$file" ] || return 1
    tmp=$(mktemp)
    awk '
        /^## Awaiting-Eval([[:space:]]|$)/ { skip=1; next }
        skip && /^## / { skip=0 }
        skip { next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Point a task at the report awaiting a verdict.
#   set_awaiting_eval <task-file> <report-basename>
#
# Any existing section is replaced, so a second deferral cannot leave two.
# The value is reduced to a bare basename over [A-Za-z0-9._-]: it is used to
# build a path under done/, and a value carrying path components would let a
# stale or hand-edited task file name a file anywhere on disk.
set_awaiting_eval() {
    local file="$1" report="${2:-}"
    [ -f "$file" ] || return 1
    report=$(basename "$report" | tr -cd '[:alnum:]._-')
    [ -n "$report" ] || return 1
    strip_awaiting_eval_section "$file" || return 1
    printf '\n## Awaiting-Eval\n%s\n' "$report" >> "$file"
}

# Remove a ## Depends-on section (heading through the next ## heading).
strip_depends_on_section() {
    local file="$1" tmp
    [ -f "$file" ] || return 1
    tmp=$(mktemp)
    awk '
        /^## Depends-on([[:space:]]|$)/ { skip=1; next }
        skip && /^## / { skip=0 }
        skip { next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Repair / validate a batch of just-emitted brief tasks.
# MANIFEST: one filename (basename) per line, files live in DIR.
# Strips ## Depends-on whose slug was not emitted. Fails on no root or a cycle.
# stdout: human-readable notes (dangling strips, errors).
# return 0 = runnable graph, 1 = fatal.
repair_brief_task_graph() {
    local manifest="$1" dir="$2"
    local file base slug dep short
    local -A emitted=()
    local -A dep_of=()
    local dangling=0 roots=0

    [ -f "$manifest" ] || return 1
    [ -d "$dir" ] || return 1

    while IFS= read -r base || [ -n "$base" ]; do
        [ -z "$base" ] && continue
        file="$dir/$base"
        [ -f "$file" ] || continue
        slug=$(task_slug_from_name "$base")
        emitted["$slug"]=1
        emitted["$(basename "$base" .md)"]=1
    done < "$manifest"

    while IFS= read -r base || [ -n "$base" ]; do
        [ -z "$base" ] && continue
        file="$dir/$base"
        [ -f "$file" ] || continue
        slug=$(task_slug_from_name "$base")
        dep=$(depends_on_from_task "$file")
        dep="${dep%.md}"
        [ -z "$dep" ] && continue
        if [ -z "${emitted[$dep]:-}" ]; then
            echo "stripped dangling Depends-on '$dep' from $base (slug was not emitted)"
            strip_depends_on_section "$file"
            dangling=$((dangling + 1))
        fi
    done < "$manifest"

    while IFS= read -r base || [ -n "$base" ]; do
        [ -z "$base" ] && continue
        file="$dir/$base"
        [ -f "$file" ] || continue
        slug=$(task_slug_from_name "$base")
        dep=$(depends_on_from_task "$file")
        dep="${dep%.md}"
        if [ -z "$dep" ]; then
            dep_of["$slug"]=""
            roots=$((roots + 1))
            continue
        fi
        short=$(task_slug_from_name "$dep")
        dep_of["$slug"]="$short"
    done < "$manifest"

    if [ "$roots" -eq 0 ]; then
        echo "invalid graph: every task has ## Depends-on (no root that can run first)"
        return 1
    fi

    local node walked_str
    for slug in "${!dep_of[@]}"; do
        node="$slug"
        walked_str="|"
        while [ -n "$node" ]; do
            case "$walked_str" in
                *"|$node|"*)
                    echo "invalid graph: dependency cycle involving '$slug'"
                    return 1
                    ;;
            esac
            walked_str="${walked_str}${node}|"
            node="${dep_of[$node]:-}"
        done
    done

    if [ "$dangling" -gt 0 ]; then
        echo "repaired $dangling dangling Depends-on; $roots root task(s) remain"
    fi
    return 0
}

# First non-heading line under ## Retries.
retries_from_task() {
    awk '/^## Retries/{found=1; next} found && /^[0-9]+$/{print; exit} found && /^##/{exit}' "$1" | tr -d '[:space:]'
}

# Write the ## Retries counter on a task file, appending the section when the
# file has none. Shared by ai-task's FAIL path (bump) and --unblock (reset to
# 0) so the two cannot drift into writing the counter differently: a requeue
# that left a stale count would spend the remaining budget on a task a human
# has just finished repairing.
set_retries() {
    local file="$1" n="$2"
    if grep -q "^## Retries" "$file"; then
        awk -v n="$n" '/^## Retries/{print; getline; print n; next} {print}' \
            "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        printf "\n## Retries\n%s\n" "$n" >> "$file"
    fi
}

# Extract Working Directory path from a project file (strip backticks).
project_working_dir() {
    local proj="$1" raw
    [ -f "$PROJECTS_DIR/${proj}.md" ] || return 1
    raw=$(awk '/^## Working Directory/{found=1; next} found && /^[^#]/{print; exit} found && /^##/{exit}' "$PROJECTS_DIR/${proj}.md")
    raw=$(printf '%s' "$raw" | tr -d '`' | tr -d '[:space:]')
    # Expand leading ~
    case "$raw" in
        "~/"*) raw="$HOME/${raw#"~/"}" ;;
        "~")  raw="$HOME" ;;
    esac
    [ -n "$raw" ] || return 1
    printf '%s\n' "$raw"
}

# Render explicitly referenced project instructions into a prompt. The legacy
# CLAUDE.md heading is project metadata, not a provider selection. Instructions
# is also accepted for projects that use a provider-neutral heading.
# Relative references resolve beside the project definition; never eval paths.
project_instructions() {
    local proj="${1:-}" project_file raw path contents
    [ -n "$proj" ] || return 0
    project_file="$PROJECTS_DIR/${proj}.md"
    [ -r "$project_file" ] || return 0
    raw=$(section_from_task 'Instructions' "$project_file")
    [ -n "$raw" ] || raw=$(section_from_task 'CLAUDE.md' "$project_file")
    raw=$(printf '%s\n' "$raw" | awk 'NF {print; exit}' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^`(.*)`$/\1/')
    [ -n "$raw" ] || return 0
    case "$raw" in
        \~/*) path="$HOME/${raw#\~/}" ;;
        /*) path="$raw" ;;
        *) path="$(dirname "$project_file")/$raw" ;;
    esac
    printf '\n--- BEGIN PROJECT INSTRUCTIONS ---\nSource: %s\n\n' "$path"
    if [ -f "$path" ] && [ -r "$path" ] && contents=$(cat -- "$path"); then
        printf '%s\n' "$contents"
    else
        printf 'Project instructions unavailable: %s\n' "$path" >&2
        printf 'The referenced instruction file could not be read. Report this missing context explicitly; do not claim to have followed it.\n'
    fi
    printf '\n--- END PROJECT INSTRUCTIONS ---\n'
    return 0
}

# ── Worktree isolation (opt-in per project) ────────────────────────────────
#
# A project file declaring "## Isolation: worktree" gets one git worktree per
# task, on branch ai/<slug>, at <repo>/.ai-worktrees/<slug>/. Every other
# project keeps the shared working tree exactly as before: the 2267 task files
# with no notion of isolation must keep behaving as they do today.
#
# The worktree lives INSIDE the repository on purpose: a container that mounts
# the repository (docker exec ... cd /var/www/<repo>) sees it without a new
# mount, which is what lets existing ## Test Command lines keep working once
# rewrite_workdir_paths has pointed them at it. It is hidden from git through
# the repository's own info/exclude, never through a tracked .gitignore.
#
# These helpers move no task file and take no lock: that orchestration stays
# in ai-task. Every git call's own output goes to stderr, because the callers
# read a path from stdout.

WORKTREE_DIRNAME=".ai-worktrees"

# How a project's tasks are isolated: prints "shared" or "worktree".
#
# An absent or empty ## Isolation, a missing project file, or no project at all
# is "shared", which is today's behaviour. An UNRECOGNISED value prints nothing
# and returns 1: guessing "shared" would quietly put a task into a tree its
# human meant to protect, and guessing "worktree" would hand a branch to a
# project that never asked for one. Same rule as permission_from_job.
project_isolation() {
    local proj="${1:-}" file val
    file="$PROJECTS_DIR/${proj}.md"
    if [ -z "$proj" ] || [ ! -r "$file" ]; then
        printf 'shared\n'
        return 0
    fi
    val=$(field_from_task Isolation "$file" | tr -d '`' | tr '[:upper:]' '[:lower:]')
    case "$val" in
        ""|shared) printf 'shared\n' ;;
        worktree)  printf 'worktree\n' ;;
        *)
            echo "project '$proj': unrecognised ## Isolation '$val' (expected worktree or shared)" >&2
            return 1
            ;;
    esac
}

# One single-line field of a project file, backticks stripped.
#   project_field brteladmin 'Base Branch'     ->  dev-2.x
#   project_field brteladmin 'Container Path'  ->  /var/www/bluerockteladmin
# Absent prints nothing and returns 0.
project_field() {
    local proj="${1:-}" field="$2"
    [ -n "$proj" ] || return 0
    field_from_task "$field" "$PROJECTS_DIR/${proj}.md" | tr -d '`'
}

# The ## Base Branch a task's worktree starts from. First match wins:
#   1. the task file's own ## Base Branch;
#   2. the ## Base Branch of the brief it was decomposed from (its ## Brief
#      path, stamped by ai-brief), so one line in a brief routes the whole
#      batch without the decomposing model having to copy it into each task;
#   3. the project's ## Base Branch.
# Prints nothing when none is set (worktree_base_ref then uses HEAD). A brief
# that cannot be read falls through to the project: the brief is archived
# after decomposition and is metadata here, not something to refuse a task on.
# A value that does not resolve is still refused, by worktree_base_ref.
#
#   task_base_branch ~/tasks/inbox/2026-10-30_fix.md brteladmin  ->  feature/0044
task_base_branch() {
    local file="$1" proj="${2:-}" base brief
    base=$(field_from_task 'Base Branch' "$file" | tr -d '`')
    if [ -z "$base" ]; then
        brief=$(field_from_task Brief "$file" | tr -d '`')
        case "$brief" in
            "~/"*) brief="$HOME/${brief#"~/"}" ;;
        esac
        [ -n "$brief" ] && base=$(field_from_task 'Base Branch' "$brief" | tr -d '`')
    fi
    [ -n "$base" ] || base=$(project_field "$proj" 'Base Branch')
    printf '%s\n' "$base"
}

# A task slug reduced to what is safe in both a path and a branch name.
# Returns 1 on a value that sanitises away entirely, or that git would refuse
# as a branch: there is no safe default worktree to fall back to.
worktree_slug() {
    local slug
    slug=$(task_slug_from_name "${1:-}" | tr -cd '[:alnum:]._-')
    slug="${slug#.}"
    [ -n "$slug" ] || return 1
    git check-ref-format --branch "ai/$slug" >/dev/null 2>&1 || return 1
    printf '%s\n' "$slug"
}

# The worktree key of one task: the name of its worktree directory and, as
# ai/<key>, of its branch. Every task decomposed from one brief shares ONE
# branch, keyed on the basename of its ## Brief (stamped by ai-brief), so the
# brief lands as one stack of per-task commits whether or not the decomposer
# wrote a correct ## Depends-on chain. A task with no usable ## Brief (written
# by hand) keeps its own slug, exactly as before.
#
#   worktree_key ~/tasks/inbox/2026-10-29_step-2.md   ->  my-refactor-brief
#
# The result is a fixed point of worktree_slug, because ai-task hands it to
# worktree_ensure / worktree_remove, which slug their name argument again: a
# brief named 2026-09-12_08-15_x.md would otherwise lose one date per pass.
worktree_key() {
    local file="$1" brief key next i
    brief=$(field_from_task Brief "$file" | tr -d '`')
    key=""
    if [ -n "$brief" ]; then
        key=$(worktree_slug "$(basename "$brief")" 2>/dev/null) || key=""
    fi
    if [ -z "$key" ]; then
        key=$(worktree_slug "$file") || return 1
    fi
    for i in 1 2 3; do
        next=$(worktree_slug "$key") || return 1
        [ "$next" = "$key" ] && break
        key="$next"
    done
    printf '%s\n' "$key"
}

# True (0) when <branch> carries a change that <base> does not have yet.
#   branch_unmerged <repo> <branch> <base>
#
# "Merged" means PATCH-EQUIVALENT, not ancestor. A human who merges a task
# branch and then runs `git pull --rebase` replays the task's commit under a
# new hash: ancestry then says "never merged" forever, and a dependent task
# would branch from the stale ai/<parent> instead of the base. `git cherry`
# compares patch ids, so a rebased or cherry-picked copy counts as merged,
# and since the pipeline lands exactly one commit per task, so does a squash
# merge of an untouched task branch.
#
# Conservative by design: a commit whose patch changed on the way in (a
# conflict resolved differently, an amend) still reads as unmerged, and so
# does any git error. Calling a branch merged when it is not would branch a
# dependent task from the wrong place; the opposite costs a stale listing.
branch_unmerged() {
    local repo="$1" branch="$2" base="$3" out
    out=$(git -C "$repo" cherry "$base" "$branch" 2>/dev/null) || return 0
    printf '%s\n' "$out" | grep -q '^+'
}

# The ref a new task branch starts from:
#   - the parent's ai/<parent-slug> branch when it exists and is not yet merged
#     into the base (branch_unmerged: by patch, so a rebased merge counts), so
#     a chain A -> B -> C builds on itself without a human merging in between;
#   - otherwise the task's base branch (task_base_branch: task, brief, project);
#   - otherwise the main tree's current HEAD.
# Returns 1 when an explicitly named base branch does not resolve: branching a
# task from somewhere else than the human wrote would be a silent guess.
worktree_base_ref() {
    local workdir="$1" parent="${2:-}" base="${3:-}" pslug pbranch
    if [ -n "$base" ]; then
        git -C "$workdir" rev-parse --verify --quiet "${base}^{commit}" >/dev/null || {
            echo "base branch '$base' does not resolve in $workdir" >&2
            return 1
        }
    else
        base=HEAD
    fi
    if [ -n "$parent" ] && pslug=$(worktree_slug "$parent"); then
        pbranch="ai/$pslug"
        if git -C "$workdir" show-ref --verify --quiet "refs/heads/$pbranch" \
            && branch_unmerged "$workdir" "$pbranch" "$base"; then
            printf '%s\n' "$pbranch"
            return 0
        fi
    fi
    printf '%s\n' "$base"
}

# True when <path> is a worktree git currently knows about in <repo-top>.
worktree_registered() {
    git -C "$1" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $2"
}

# Create, or reuse, the worktree for one task. Prints the directory inside it
# that corresponds to <workdir>: the worktree root when the project's working
# directory is the repository top, the same subdirectory otherwise.
#
#   worktree_ensure <workdir> <task-name> [base-ref]
#
# REUSE IS THE NORMAL CASE, not an edge: a retry, a task moved back by
# --unblock, and a grade-only resume all find their worktree already there,
# with the previous attempt's changes in it, exactly as the shared tree kept
# them. A branch that outlived its worktree is checked out again rather than
# recreated, so committed work on it is never orphaned.
#
# A directory at the target path that git does NOT know as a worktree is
# refused, never removed: it is somebody's files.
#
# --relative-paths keeps the worktree's .git link valid inside a container that
# mounts the repository at another path.
#
# Exit: 0 ok, 1 not a git repository or bad slug, 3 git refused.
worktree_ensure() {
    local workdir="$1" name="$2" base="${3:-}" slug top prefix wt branch common excl
    slug=$(worktree_slug "$name") || { echo "no usable worktree slug for '$name'" >&2; return 1; }
    top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || {
        echo "$workdir is not inside a git repository" >&2
        return 1
    }
    prefix=$(git -C "$workdir" rev-parse --show-prefix)
    wt="$top/$WORKTREE_DIRNAME/$slug"
    branch="ai/$slug"

    common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir) || return 3
    excl="$common/info/exclude"
    mkdir -p "$common/info"
    grep -qxF "/$WORKTREE_DIRNAME/" "$excl" 2>/dev/null \
        || printf '/%s/\n' "$WORKTREE_DIRNAME" >> "$excl"

    # A worktree whose directory was deleted by hand is still registered and
    # would block the add below.
    git -C "$top" worktree prune >&2 2>/dev/null || true

    if worktree_registered "$top" "$wt"; then
        :
    elif [ -e "$wt" ]; then
        echo "refusing: $wt exists but is not a registered worktree" >&2
        return 3
    elif git -C "$top" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$top" worktree add --relative-paths "$wt" "$branch" >&2 || return 3
    else
        git -C "$top" worktree add --relative-paths -b "$branch" "$wt" "${base:-HEAD}" >&2 || return 3
    fi
    printf '%s\n' "${wt}${prefix:+/${prefix%/}}"
}

# Per-worktree bookkeeping lives in the worktree's own git directory
# (.git/worktrees/<slug>/), never in the checkout, where it would show up as an
# untracked file and end up in the task's commit.
worktree_gitdir() {
    git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null
}

# Run a project's ## Worktree Setup once per worktree (symlink vendor/, copy
# .env, ...). The section is one bash script run with -e from <wt-dir>, with
# AI_MAIN_WORKDIR and AI_WORKTREE exported; code fences are dropped.
#
#   worktree_setup <wt-dir> <main-workdir> <script> [timeout-sec]
#
# Whatever the setup leaves UNTRACKED is recorded, so worktree_commit and
# worktree_dirty can tell a vendor symlink from the task's own work: a setup
# artefact committed onto the task branch would be merged into the project.
#
# A failure leaves no marker, so the next claim runs the setup again.
# Exit: 0 done (or nothing to do), 2 setup failed.
worktree_setup() {
    local wt="$1" main="$2" script="${3:-}" limit="${4:-600}" gitdir before after rc
    gitdir=$(worktree_gitdir "$wt") || return 2
    [ -f "$gitdir/ai-setup-done" ] && return 0
    script=$(printf '%s\n' "$script" | grep -vE '^[[:space:]]*(```|~~~)' || true)
    if [ -n "${script//[[:space:]]/}" ]; then
        before=$(git -C "$wt" ls-files --others --exclude-standard --directory --full-name :/ 2>/dev/null | sort)
        rc=0
        ( cd "$wt" && AI_MAIN_WORKDIR="$main" AI_WORKTREE="$wt" \
            timeout "$limit" bash -e -c "$script" ) >&2 || rc=$?
        [ "$rc" -eq 0 ] || { echo "worktree setup failed (exit $rc) in $wt" >&2; return 2; }
        after=$(git -C "$wt" ls-files --others --exclude-standard --directory --full-name :/ 2>/dev/null | sort)
        comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") \
            | sed -E 's#/$##' | grep -v '^$' > "$gitdir/ai-setup-paths" || true
    fi
    : > "$gitdir/ai-setup-done"
}

# Uncommitted changes in a worktree that are NOT setup artefacts, as
# porcelain lines on stdout. Returns 0 when there are any (dirty), 1 when the
# worktree holds nothing a removal would lose. An unreadable status counts as
# dirty: the safe answer to "may I delete this?" is no.
worktree_dirty() {
    local wt="$1" gitdir st
    gitdir=$(worktree_gitdir "$wt") || return 0
    st=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || return 0
    if [ -s "$gitdir/ai-setup-paths" ]; then
        st=$(printf '%s\n' "$st" | awk -v list="$gitdir/ai-setup-paths" '
            BEGIN { while ((getline p < list) > 0) skip[p] = 1 }
            { path = substr($0, 4); sub(/\/$/, "", path); if (!(path in skip)) print }')
    fi
    st=$(printf '%s\n' "$st" | grep -v '^$' || true)
    [ -n "$st" ] || return 1
    printf '%s\n' "$st"
}

# Commit everything the task changed in its worktree, setup artefacts excepted.
#   worktree_commit <wt-dir> <message-file>
# Nothing to commit is success. Hooks are NOT bypassed: a hook that rejects
# the commit returns 1 and the worktree stays as it was, for a human to read.
worktree_commit() {
    local wt="$1" msg="$2" gitdir p
    gitdir=$(worktree_gitdir "$wt") || return 1
    git -C "$wt" add -A :/ >&2 || return 1
    if [ -s "$gitdir/ai-setup-paths" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] && git -C "$wt" reset -q -- ":(top)$p" >&2 2>/dev/null
        done < "$gitdir/ai-setup-paths"
    fi
    if ! git -C "$wt" diff --cached --quiet; then
        git -C "$wt" commit -q -F "$msg" >&2 || return 1
    fi
    rm -f "$gitdir/ai-owner"
}

# The task whose uncommitted changes a shared (per-brief) worktree holds.
# ai-owner, in the worktree's git dir, is written by worktree_claim when a task
# starts working and removed by worktree_commit once its work has landed.
#
#   worktree_claim <wt-dir> <task-slug>
#
# Refused (1, the owner on stdout) only while ANOTHER task owns the worktree
# AND it is still dirty: starting there would build on, and then commit, the
# other task's unfinished work. A retry of the owner itself is the normal case
# and is allowed. A stale owner over a clean tree (a human discarded its
# changes) is simply replaced. Exit 2 when the git dir cannot be found.
worktree_claim() {
    local wt="$1" slug="$2" gitdir owner
    gitdir=$(worktree_gitdir "$wt") || return 2
    owner=$(cat "$gitdir/ai-owner" 2>/dev/null || true)
    if [ -n "$owner" ] && [ "$owner" != "$slug" ] && worktree_dirty "$wt" >/dev/null; then
        printf '%s\n' "$owner"
        return 1
    fi
    printf '%s\n' "$slug" > "$gitdir/ai-owner"
}

# The current owner of a worktree, empty when none. Read-only, for dtask.
worktree_owner() {
    local gitdir
    gitdir=$(worktree_gitdir "$1") || return 0
    cat "$gitdir/ai-owner" 2>/dev/null || true
}

# The ONE place that decides whether a queued task must wait for a sibling of
# its brief: prints the owning task's slug and returns 0 when the task's
# shared worktree holds another task's uncommitted changes, returns 1
# otherwise. Read by ai-task's picker and by dtask, so the two cannot
# disagree. The picker needs it as a starvation guard: worktree_claim would
# defer such a task in seconds, and select_candidate returns the FIRST
# eligible task, so without it the blocked task is claimed every sweep and
# nothing behind it ever runs.
#   worktree_blocker <task-file>
# Cheap on the common path: a task without ## Brief, or outside an isolated
# project, returns 1 before any git call.
worktree_blocker() {
    local f="$1" proj wd top key wt owner
    [ -n "$(field_from_task Brief "$f")" ] || return 1
    proj=$(project_from_task "$f")
    [ -n "$proj" ] || return 1
    proj=$(canonical_project "$proj")
    [ "$(project_isolation "$proj" 2>/dev/null)" = worktree ] || return 1
    wd=$(project_working_dir "$proj") || return 1
    top=$(git -C "$wd" rev-parse --show-toplevel 2>/dev/null) || return 1
    key=$(worktree_key "$f") || return 1
    wt="$top/$WORKTREE_DIRNAME/$key"
    worktree_registered "$top" "$wt" || return 1
    owner=$(worktree_owner "$wt")
    [ -n "$owner" ] || return 1
    [ "$owner" != "$(worktree_slug "$f")" ] || return 1
    worktree_dirty "$wt" >/dev/null || return 1
    printf '%s\n' "$owner"
}

# Remove one task's worktree, keeping its branch. Refuses (returns 1) while
# the worktree holds uncommitted work: --force is only ever used to clear the
# setup artefacts worktree_dirty already ignores.
#   worktree_remove <workdir> <task-name>
worktree_remove() {
    local workdir="$1" slug top wt
    slug=$(worktree_slug "$2") || return 1
    top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 1
    wt="$top/$WORKTREE_DIRNAME/$slug"
    worktree_registered "$top" "$wt" || return 0
    if worktree_dirty "$wt" >/dev/null; then
        echo "keeping $wt: it holds uncommitted changes" >&2
        return 1
    fi
    git -C "$top" worktree remove --force "$wt" >&2
}

# Worktree keys of every task still in flight (inbox/, run/, review/), one per
# line, computed exactly as worktree_key computes them. A worktree whose key
# is not here belongs to tasks that all finished or were deleted; a brief's
# worktree stays while any one of its tasks is still in flight.
#   active_task_keys [exclude-file]
# The optional file is left out, so a task can ask whether anything ELSE
# still needs its worktree.
active_task_keys() {
    local exclude="${1:-}" dir f
    for dir in "$INBOX" "$RUN_DIR" "$REVIEW_DIR"; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.md; do
            [ -f "$f" ] || continue
            [ -n "$exclude" ] && [ "$f" -ef "$exclude" ] && continue
            worktree_key "$f" 2>/dev/null || true
        done
    done
}

# Remove the worktrees of one repository whose task is no longer in flight.
# Prints each removed slug. A dirty worktree is reported and kept: its changes
# are the only copy. Branches are never deleted.
#   worktree_prune <workdir>
worktree_prune() {
    local workdir="$1" top active d slug
    top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || return 0
    [ -d "$top/$WORKTREE_DIRNAME" ] || return 0
    active=$(active_task_keys)
    for d in "$top/$WORKTREE_DIRNAME"/*/; do
        [ -d "$d" ] || continue
        slug=$(basename "$d")
        printf '%s\n' "$active" | grep -qxF -- "$slug" && continue
        worktree_registered "$top" "${d%/}" || continue
        if worktree_remove "$top" "$slug"; then
            printf '%s\n' "$slug"
        fi
    done
    git -C "$top" worktree prune >&2 2>/dev/null || true
}

# Filter stdin to stdout, pointing every reference to a project's working
# directory at a task's worktree instead.
#
#   rewrite_workdir_paths <workdir> <wt-dir> [container-path]
#
# This is what lets an existing task file, whose criteria and ## Test Command
# say ~/Projects/<repo>/..., grade the worktree rather than the main tree. It
# rewrites the ~/, $HOME/, ${HOME}/ and absolute spellings, plus, when the
# project declares a ## Container Path, that path to the same place inside the
# container (only when the working directory is the repository top: a mount
# of a subdirectory cannot see .ai-worktrees/).
#
# A match must be a whole path component: ~/Projects/foo does not rewrite
# ~/Projects/foo-old. A path already inside .ai-worktrees/ is left alone, so
# the filter is idempotent.
rewrite_workdir_paths() {
    local workdir="${1%/}" wt="${2%/}" container="${3%/}" real rel froms="" tos="" sep=$'\034'
    _rw_add_pair() { froms="${froms}${froms:+$sep}$1"; tos="${tos}${tos:+$sep}$2"; }

    real=$(realpath -m "$workdir")
    _rw_add_pair "$workdir" "$wt"
    [ "$real" != "$workdir" ] && _rw_add_pair "$real" "$wt"
    case "$workdir" in
        "$HOME"/*)
            rel="${workdir#"$HOME"/}"
            _rw_add_pair "~/$rel" "$wt"
            _rw_add_pair "\$HOME/$rel" "$wt"
            _rw_add_pair "\${HOME}/$rel" "$wt"
            ;;
    esac
    if [ -n "$container" ]; then
        case "$wt" in
            "$real"/*) _rw_add_pair "$container" "$container/${wt#"$real"/}" ;;
            *) echo "## Container Path ignored: $workdir is not the repository top" >&2 ;;
        esac
    fi

    RW_FROMS="$froms" RW_TOS="$tos" RW_GUARD="/$WORKTREE_DIRNAME/" awk '
        BEGIN {
            n = split(ENVIRON["RW_FROMS"], F, "\034")
            split(ENVIRON["RW_TOS"], T, "\034")
            guard = ENVIRON["RW_GUARD"]
        }
        # First position >= 1 where F[i] occurs as a whole path, or 0.
        function find(s, i,    off, rest, p, ap, before, after) {
            off = 0; rest = s
            while ((p = index(rest, F[i])) > 0) {
                ap = off + p
                before = (ap > 1) ? substr(s, ap - 1, 1) : ""
                after = substr(s, ap + length(F[i]), 1)
                if (before !~ /[A-Za-z0-9._\/~$-]/ && after !~ /[A-Za-z0-9._-]/ \
                    && substr(s, ap + length(F[i]), length(guard)) != guard)
                    return ap
                off = ap; rest = substr(s, ap + 1)
            }
            return 0
        }
        {
            s = $0; out = ""
            while (1) {
                best = 0; bp = 0
                for (i = 1; i <= n; i++) {
                    p = find(s, i)
                    if (p && (!bp || p < bp || (p == bp && length(F[i]) > length(F[best])))) {
                        best = i; bp = p
                    }
                }
                if (!best) { out = out s; break }
                out = out substr(s, 1, bp - 1) T[best]
                s = substr(s, bp + length(F[best]))
            }
            print out
        }'
}

# ── Recurring jobs (ai-scheduled) ──────────────────────────────────────────

# Is a job due to run?
#   is_due <slug> <schedule>  →  0 due, 1 not due, 2 invalid/missing schedule
#
# Interval-since-last-run bookkeeping, NOT cron expressions: the engine is
# fired often by one cron line and decides for itself what actually runs. State
# is $SCHED_STATE_DIR/<slug>.run holding the epoch seconds of the last
# successful dispatch.
#
# The epoch-seconds format is deliberately unchanged from the engine this
# replaces, so both read and write the same markers. That is what makes the
# cutover a one-line cron swap: no job re-fires because its state was reset,
# and none double-fires because the other engine could not see the stamp.
#
# The schedule grammar is validated BEFORE the state lookup, so a typo'd
# schedule on a never-run job is reported as invalid rather than silently
# treated as due (a never-run job has no stamp, and "no stamp" means due).
#
# Three-way exit status, so `if is_due ...` is wrong: "not due" and "invalid"
# are different outcomes and only the second one deserves a log line.
#
# A non-zero return is normal here (most jobs are not due on most sweeps), so
# under `set -e` the ONLY safe call is to absorb it:
#
#     rc=0; is_due "$slug" "$schedule" || rc=$?
#
# A bare `is_due "$slug" "$schedule"; rc=$?` reads correctly and works in a
# script without `set -e`, but every script in this repo sets it, and there the
# first not-due job kills the whole sweep before the remaining jobs are ever
# looked at.
is_due() {
    local slug="$1" schedule="$2"
    local statefile="$SCHED_STATE_DIR/$slug.run"
    local now last elapsed

    case "$schedule" in
        daily|weekly|weekly-mon|weekly-tue|weekly-wed|weekly-thu|weekly-fri|weekly-sat|weekly-sun|monthly) ;;
        every:*h)
            local nn="${schedule#every:}"; nn="${nn%h}"
            case "$nn" in ''|*[!0-9]*) return 2 ;; esac
            [ "$nn" -gt 0 ] 2>/dev/null || return 2
            ;;
        *) return 2 ;;
    esac

    now=$(date +%s)
    last=""
    if [ -f "$statefile" ]; then
        last=$(head -n1 "$statefile" 2>/dev/null | tr -dc '0-9')
    fi
    [ -n "$last" ] || return 0                      # never run → due
    elapsed=$(( now - last ))

    case "$schedule" in
        daily)
            # ~23h, not 24h: cron jitter must not push a daily job to every
            # other day.
            [ "$elapsed" -ge 82800 ] && return 0 || return 1
            ;;
        weekly)
            [ "$elapsed" -ge 601200 ] && return 0 || return 1        # ~6d23h
            ;;
        weekly-mon|weekly-tue|weekly-wed|weekly-thu|weekly-fri|weekly-sat|weekly-sun)
            local target_u today_u today_date last_date
            case "${schedule#weekly-}" in
                mon) target_u=1 ;; tue) target_u=2 ;; wed) target_u=3 ;; thu) target_u=4 ;;
                fri) target_u=5 ;; sat) target_u=6 ;; sun) target_u=7 ;;
            esac
            today_u=$(date +%u)                     # 1=Mon … 7=Sun, locale-independent
            today_date=$(date +%Y-%m-%d)
            last_date=$(date -d "@$last" +%Y-%m-%d 2>/dev/null || true)
            [ "$today_u" = "$target_u" ] && [ "$today_date" != "$last_date" ] && return 0
            return 1
            ;;
        monthly)
            local this_month last_month
            this_month=$(date +%Y-%m)
            last_month=$(date -d "@$last" +%Y-%m 2>/dev/null || true)
            { [ "$this_month" != "$last_month" ] || [ "$elapsed" -ge 2419200 ]; } && return 0
            return 1
            ;;
        every:*h)
            local n="${schedule#every:}"; n="${n%h}"
            [ "$elapsed" -ge $(( n * 3600 )) ] && return 0 || return 1
            ;;
    esac
    return 2
}

# Stamp a job as having run now. Called ONLY on a dispatch that actually
# happened: a deferral (auth failure, timeout, empty result) must leave the
# stamp alone so the job retries on the next sweep.
stamp_job_run() {
    local slug="${1:-}"
    [ -n "$slug" ] || return 1
    mkdir -p "$SCHED_STATE_DIR" || return 1
    date +%s > "$SCHED_STATE_DIR/$slug.run"
}

# True if a task with this slug is already anywhere in the pipeline, so a
# proposed stub is never a duplicate of work that is already queued, running,
# or finished. Matches a bare <slug>.md and a date-prefixed *_<slug>.md, never
# a mere substring.
#
# run/ is included, which the engine this replaces omitted: a task that has
# been claimed has left inbox/, so without run/ a sweep landing mid-run
# re-proposes work that is executing at that moment. review/ is deliberately
# NOT included: a task that failed evaluation is exactly the kind of thing a
# planner should be free to propose a fresh approach for.
slug_exists() {
    local slug="${1:-}" d
    [ -n "$slug" ] || return 1
    slug="${slug%.md}"
    for d in "$INBOX" "$SUGGEST_DIR" "$BACKLOG_DIR" "$BACKLOG_REVIEW_DIR" "$RUN_DIR"; do
        slug_file_in_dir "$d" ".md" "$slug" && return 0
    done
    slug_file_in_dir "$DONE_DIR" ".task.md" "$slug" && return 0
    return 1
}
# ── Suggestion stubs ────────────────────────────────────────────────────────
# A stub is the machine's proposal for follow-up work; a human reads
# suggestions/ and promotes what is worth doing. Write one file per stub, named
# by its own slug, skipping any slug already anywhere in the pipeline.
#
#   write_stub <stub-text> <origin-slug> [<permitted-targets>]
#
# The slug is reduced to [A-Za-z0-9-] and stripped of every path component, so
# no agent output can steer a write out of suggestions/ (same rule as
# ai-brief's filename handling).
#
# PERMITTED TARGETS is a newline-separated set of project aliases this stub may
# be attributed to. When it is non-empty the stub's `project:` line must be one
# of them AND $PROJECTS_DIR/<alias>.md must exist, or the stub is refused with
# a log line naming the rejected target. Enforced here rather than only in the
# prompt that produced the stub: a rule that lives in prompt text is a rule the
# model can talk itself out of, and the whole point of a bounded cross-project
# reflex is that the bound holds. An EMPTY argument keeps the pre-existing
# behaviour exactly, which is what the two ai-scheduled call sites rely on.
#
# Messages go to stdout prefixed with $STUB_LOG_PREFIX, rather than through a
# log() that only one caller defines. ai-scheduled sets it to its own prefix so
# its output is unchanged by this function having moved here.
STUB_LOG_PREFIX="${STUB_LOG_PREFIX:-}"

write_stub() {
    local stub="$1" jobslug="$2" allowed="${3:-}" slug body target
    slug=$(printf '%s' "$stub" | awk -F': *' '/^slug:/{print $2; exit}')
    slug=$(basename "${slug:-}" | tr -cd '[:alnum:]-')
    if [ -z "$slug" ]; then
        echo "${STUB_LOG_PREFIX}job '$jobslug': suggestion had no usable slug — not written"
        return 1
    fi
    if slug_exists "$slug"; then
        echo "${STUB_LOG_PREFIX}job '$jobslug': skip stub '$slug' (already in the pipeline)"
        return 1
    fi
    if [ -n "$allowed" ]; then
        target=$(printf '%s' "$stub" | awk -F': *' '/^project:/{print $2; exit}')
        target=$(basename "${target:-}" | tr -cd '[:alnum:]._-')
        if [ -z "$target" ] \
            || ! printf '%s\n' "$allowed" | grep -qxF -- "$target" \
            || [ ! -f "$PROJECTS_DIR/${target}.md" ]; then
            echo "${STUB_LOG_PREFIX}job '$jobslug': refuse stub '$slug' — target project '${target:-none}' is not a permitted target"
            return 1
        fi
    fi
    mkdir -p "$SUGGEST_DIR"
    # Body is everything after the first '---' separator line.
    body=$(printf '%s\n' "$stub" | awk 'p{print} /^---$/{p=1}')
    if [ -z "${body//[[:space:]]/}" ]; then
        echo "${STUB_LOG_PREFIX}job '$jobslug': suggestion '$slug' had an empty body — not written"
        return 1
    fi
    printf '%s\n' "$body" > "$SUGGEST_DIR/${slug}.md"
    echo "${STUB_LOG_PREFIX}job '$jobslug': wrote suggestion → $slug"
    return 0
}

# Print the body of one fenced block from stdin: everything strictly between a
# line equal to the start marker (e.g. ===SNAPSHOT===) and the first following
# ===END=== line. Used to split an agentic job's machine-parseable response.
extract_block() {
    awk -v start="$1" '
        $0 == start { inblk = 1; next }
        inblk && /^===END===/ { exit }
        inblk { print }
    '
}

# Desktop notification if notify-send exists; otherwise no-op.
notify() {
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "$@"
    fi
}

# Load key=value config into the caller's environment (safe defaults set by caller first).
load_config() {
    local script_dir config
    script_dir="$(dirname "$(realpath "${BASH_SOURCE[1]:-$0}")")"
    # Prefer the sourcing script's directory when SCRIPT_DIR is already set.
    if [ -n "${SCRIPT_DIR:-}" ]; then
        config="$SCRIPT_DIR/config"
    else
        config="$script_dir/config"
    fi
    [ -f "$config" ] || return 0
    # shellcheck disable=SC1090
    source "$config"
}

# Directory holding this library, resolved once at source time. `providers/` is
# a sibling of lib.sh, so this stays correct even when a caller sources lib.sh
# through a relative path or from another working directory.
AI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the provider adapter for one runner into the current shell.
#   load_provider <runner>  →  sources providers/<runner>.sh
#
# The runner name IS the file name, so an unknown runner is a hard error with a
# message naming it, never a silent fallback to a default: falling back would
# send a task to the wrong provider, which is the one failure mode that cannot
# be undone after the fact. Same reason for verifying all six contract
# functions are defined before returning success — a half-defined adapter would
# fail deep inside a run, after the task file had already been moved.
#
# Returns 0 on success; non-zero (with a message on stderr) for an empty name,
# a name that is not a plain identifier, an unknown runner, a provider file
# that fails to source, or a provider missing a contract function.
load_provider() {
    local runner="${1:-}" base provider fn
    runner=$(printf '%s' "$runner" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    if [ -z "$runner" ]; then
        echo "load_provider: no runner given" >&2
        return 1
    fi

    # The runner name becomes a path component, so refuse anything that could
    # escape the providers directory or name a file outside it.
    case "$runner" in
        *[!a-z0-9_-]*)
            echo "load_provider: invalid runner name '$runner' (expected [a-z0-9_-]+)" >&2
            return 1
            ;;
    esac

    # Honour a caller-set SCRIPT_DIR (same convention as load_config), then fall
    # back to this library's own directory.
    base="${SCRIPT_DIR:-$AI_LIB_DIR}"
    provider="$base/providers/${runner}.sh"
    if [ ! -f "$provider" ]; then
        provider="$AI_LIB_DIR/providers/${runner}.sh"
    fi
    if [ ! -f "$provider" ]; then
        echo "load_provider: unknown runner '$runner' (no providers/${runner}.sh under $base)" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    if ! source "$provider"; then
        echo "load_provider: failed to source provider for runner '$runner' ($provider)" >&2
        return 1
    fi

    for fn in ai_run ai_json_text ai_usage_table ai_is_auth_failure ai_model_alias ai_preamble_extra; do
        if ! declare -F "$fn" >/dev/null; then
            echo "load_provider: provider '$runner' does not define $fn (broken provider, refusing to run)" >&2
            return 1
        fi
    done

    return 0
}
