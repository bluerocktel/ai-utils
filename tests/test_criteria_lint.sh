#!/bin/bash
# Offline regression test for lint_task_criteria's fifth shape: a multi-word
# phrase greped against raw extracted document text with no line join.
#
# Extracts the function out of ai-brief rather than sourcing the script, which
# would run the launcher. Builds fixture task files in a temp directory and
# asserts on the ## Criteria Warnings section the lint appends.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")
BRIEF="$REPO_DIR/ai-brief"

[ -f "$BRIEF" ] || { echo "FAIL: ai-brief not found at $BRIEF" >&2; exit 1; }

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

awk '/^lint_task_criteria\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$BRIEF" > "$tmp/lint_fn.sh"
[ -s "$tmp/lint_fn.sh" ] || { echo "FAIL: could not extract lint_task_criteria" >&2; exit 1; }
# shellcheck source=/dev/null
. "$tmp/lint_fn.sh"

FAILURES=0
SHAPE_MARK='phrase grep on extracted text'

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

# Writes a fixture holding the given criterion lines under ## Acceptance Criteria.
make_fixture() {
    local path="$1"; shift
    {
        echo "## Project"
        echo "demo"
        echo ""
        echo "## Tasks"
        echo "1. Regenerate the PDF."
        echo ""
        echo "## Acceptance Criteria"
        local c
        for c in "$@"; do echo "$c"; done
    } > "$path"
}

# Count of appended warnings naming the extraction shape.
shape_hits() {
    grep -cF "$SHAPE_MARK" "$1" || true
}

# ── 1. the raw, unjoined phrase grep warns ─────────────────────────────────
f="$tmp/raw.md"
make_fixture "$f" "- \`pdftotext out.pdf - | grep -F -q 'Two Words'\` exits 0"
lint_task_criteria "$f" || fail "lint returned non-zero on the raw fixture"
grep -q '^## Criteria Warnings' "$f" || fail "raw fixture: no ## Criteria Warnings section appended"
[ "$(shape_hits "$f")" -eq 1 ] || fail "raw fixture: expected exactly 1 extraction-shape warning, got $(shape_hits "$f")"

# ── 2. the same criterion with a tr join warns for no such shape ────────────
f="$tmp/joined.md"
make_fixture "$f" "- \`pdftotext out.pdf - | tr '\\n' ' ' | grep -F -q 'Two Words'\` exits 0"
lint_task_criteria "$f" || fail "lint returned non-zero on the joined fixture"
[ "$(shape_hits "$f")" -eq 0 ] || fail "joined fixture: extraction shape fired despite the tr join"

# ── 3. a single-token pattern cannot wrap and must stay silent ──────────────
f="$tmp/single.md"
make_fixture "$f" "- \`pdftotext out.pdf - | grep -F -q 'Handover'\` exits 0"
lint_task_criteria "$f" || fail "lint returned non-zero on the single-word fixture"
[ "$(shape_hits "$f")" -eq 0 ] || fail "single-word fixture: extraction shape fired on a pattern that cannot wrap"

# ── 4. no ## Acceptance Criteria section: returns 0, appends nothing ────────
f="$tmp/nocrit.md"
{
    echo "## Project"
    echo "demo"
    echo ""
    echo "## Tasks"
    echo "1. Do the thing."
} > "$f"
before=$(sha256sum < "$f")
lint_task_criteria "$f" || fail "lint returned non-zero on a file with no ## Acceptance Criteria"
after=$(sha256sum < "$f")
[ "$before" = "$after" ] || fail "file with no ## Acceptance Criteria was modified"

# ── 5. the real regression: both forms in one file yields exactly one hit ───
f="$tmp/both.md"
make_fixture "$f" \
    "- \`pdftotext report.pdf - | grep -c 'Conclusion and Handover'\` returns 1 or more" \
    "- \`pdftotext report.pdf - | tr '\\n' ' ' | grep -c 'Conclusion and Handover'\` returns 1 or more"
lint_task_criteria "$f" || fail "lint returned non-zero on the mixed fixture"
[ "$(shape_hits "$f")" -eq 1 ] || fail "mixed fixture: expected exactly 1 extraction-shape warning, got $(shape_hits "$f")"

# ── 6. shapes 1 to 4 still fire: the git working-tree assertion ─────────────
f="$tmp/gitstate.md"
make_fixture "$f" "- \`git diff -- src/ | grep -E '^[+-]' | wc -l\` returns 0"
lint_task_criteria "$f" || fail "lint returned non-zero on the git-state fixture"
grep -qF 'git working-tree state' "$f" || fail "git-state fixture: shape 4 no longer fires"
[ "$(shape_hits "$f")" -eq 0 ] || fail "git-state fixture: extraction shape fired on a criterion with no extraction command"

if [ "$FAILURES" -ne 0 ]; then
    echo "test_criteria_lint: $FAILURES check(s) failed" >&2
    exit 1
fi
echo "test_criteria_lint: all checks passed"
