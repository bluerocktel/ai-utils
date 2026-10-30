#!/bin/bash
# Offline regression test for the worktree-isolation helpers in lib.sh.
#
# Builds a throwaway HOME, TASKS_DIR and git repository in a temp directory and
# exercises every helper against them. Never touches the live tree: lib.sh
# derives every pipeline path from TASKS_DIR, which is set before it is sourced.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
export TASKS_DIR="$tmp/tasks"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME" "$TASKS_DIR/projects" "$TASKS_DIR/inbox" "$TASKS_DIR/run" "$TASKS_DIR/review"

# shellcheck source=/dev/null
. "$REPO_DIR/lib.sh"

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

REPO="$HOME/Projects/demo"
mkdir -p "$REPO/sub"
git -C "$REPO" init -q -b main
echo one > "$REPO/file.txt"
echo sub > "$REPO/sub/inner.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# ── 1. project_isolation ───────────────────────────────────────────────────
printf '## Working Directory\n`~/Projects/demo/`\n' > "$TASKS_DIR/projects/plain.md"
printf '## Working Directory\n`~/Projects/demo/`\n\n## Aliases\n- `iso-alias`\n\n## Isolation: worktree\n' > "$TASKS_DIR/projects/iso.md"
printf '## Isolation\n`Worktree`\n' > "$TASKS_DIR/projects/nextline.md"
printf '## Isolation: sandbox\n' > "$TASKS_DIR/projects/bogus.md"
[ "$(project_isolation plain)" = shared ] || fail "absent ## Isolation should be shared"
[ "$(project_isolation iso)" = worktree ] || fail "inline worktree not recognised"
[ "$(project_isolation nextline)" = worktree ] || fail "next-line, backticked, capitalised worktree not recognised"
[ "$(project_isolation missing-project)" = shared ] || fail "missing project file should be shared"
[ "$(project_isolation '')" = shared ] || fail "no project should be shared"
# An alias has no project file of its own: callers must resolve it first,
# exactly as the project lock does, or an alias-written task escapes isolation.
[ "$(project_isolation iso-alias)" = shared ] || fail "raw alias unexpectedly found a project file"
[ "$(project_isolation "$(canonical_project ISO-Alias)")" = worktree ] || fail "alias did not resolve to the isolated project"
if out=$(project_isolation bogus 2>/dev/null); then fail "unknown ## Isolation must return 1"; fi
[ -z "${out:-}" ] || fail "unknown ## Isolation must print nothing on stdout"

# ── 2. worktree_slug ───────────────────────────────────────────────────────
[ "$(worktree_slug 2026-10-29_add-thing.md)" = add-thing ] || fail "date prefix not stripped"
[ "$(worktree_slug "$TASKS_DIR/inbox/2026-10-29_x\`y.md")" = xy ] || fail "slug not sanitised"
if worktree_slug '@@@' >/dev/null 2>&1; then fail "empty slug must return 1"; fi

# ── 3. worktree_ensure: create, then reuse ─────────────────────────────────
WT=$(worktree_ensure "$REPO/" 2026-10-29_alpha.md 2>/dev/null) || fail "ensure failed"
[ "$WT" = "$REPO/.ai-worktrees/alpha" ] || fail "unexpected worktree path: $WT"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = ai/alpha ] || fail "worktree not on ai/alpha"
grep -qxF '/.ai-worktrees/' "$REPO/.git/info/exclude" || fail "exclude entry missing"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "main tree dirty after ensure"
echo changed >> "$WT/file.txt"
WT2=$(worktree_ensure "$REPO" alpha 2>/dev/null) || fail "reuse failed"
[ "$WT2" = "$WT" ] || fail "reuse returned a different path"
grep -q changed "$WT/file.txt" || fail "reuse lost the previous attempt's change"
[ "$(grep -cxF '/.ai-worktrees/' "$REPO/.git/info/exclude")" -eq 1 ] || fail "exclude entry duplicated"
grep -q '^gitdir: \.\.' "$WT/.git" || fail "worktree .git link is not relative"

mkdir -p "$REPO/.ai-worktrees/squatter"
rc=0; worktree_ensure "$REPO" squatter >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "unregistered directory at target must be refused with 3, got $rc"
[ -d "$REPO/.ai-worktrees/squatter" ] || fail "refused directory was removed"
rmdir "$REPO/.ai-worktrees/squatter"

rc=0; worktree_ensure "$tmp" x >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "non-repository must return 1, got $rc"

# ── 4. worktree_setup ──────────────────────────────────────────────────────
mkdir -p "$REPO/vendor-src"
SETUP='```sh
ln -s ../../vendor-src vendor
echo run >> "$AI_MAIN_WORKDIR/../setup-count"
```'
worktree_setup "$WT" "$REPO" "$SETUP" 2>/dev/null || fail "setup failed"
[ -L "$WT/vendor" ] || fail "setup did not create the symlink"
worktree_setup "$WT" "$REPO" "$SETUP" 2>/dev/null || fail "second setup call failed"
[ "$(wc -l < "$HOME/Projects/setup-count")" -eq 1 ] || fail "setup ran more than once"
grep -qxF vendor "$(worktree_gitdir "$WT")/ai-setup-paths" || fail "setup artefact not recorded"

WTF=$(worktree_ensure "$REPO" failing 2>/dev/null)
rc=0; worktree_setup "$WTF" "$REPO" 'false' 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "failing setup must return 2, got $rc"
[ ! -f "$(worktree_gitdir "$WTF")/ai-setup-done" ] || fail "failed setup left a done marker"

# ── 5. worktree_dirty / worktree_commit ────────────────────────────────────
worktree_dirty "$WT" >/dev/null || fail "modified worktree reported clean"
worktree_dirty "$WT" | grep -q vendor && fail "setup symlink reported as dirty"
printf 'Add change\n\nbody\n' > "$tmp/msg"
worktree_commit "$WT" "$tmp/msg" 2>/dev/null || fail "commit failed"
git -C "$REPO" log -1 --format=%s ai/alpha | grep -qx 'Add change' || fail "commit not on ai/alpha"
git -C "$REPO" show --stat --format= ai/alpha | grep -q vendor && fail "setup artefact committed"
worktree_dirty "$WT" >/dev/null && fail "worktree dirty after commit"
worktree_commit "$WT" "$tmp/msg" 2>/dev/null || fail "nothing-to-commit must succeed"

# ── 6. worktree_remove / re-checkout of a surviving branch ─────────────────
echo wip > "$WT/new.txt"
if worktree_remove "$REPO" alpha 2>/dev/null; then fail "dirty worktree was removed"; fi
[ -f "$WT/new.txt" ] || fail "dirty worktree lost its file"
rm "$WT/new.txt"
worktree_remove "$REPO" alpha 2>/dev/null || fail "clean worktree not removed"
[ ! -d "$WT" ] || fail "worktree directory still present"
git -C "$REPO" show-ref --verify --quiet refs/heads/ai/alpha || fail "branch deleted with worktree"
WT=$(worktree_ensure "$REPO" alpha 2>/dev/null) || fail "re-ensure failed"
grep -q changed "$WT/file.txt" || fail "re-ensure did not check out the existing branch"

# ── 7. worktree_base_ref ───────────────────────────────────────────────────
[ "$(worktree_base_ref "$REPO" alpha main)" = ai/alpha ] || fail "unmerged parent branch not chosen"
[ "$(worktree_base_ref "$REPO" '' main)" = main ] || fail "base branch not chosen"
[ "$(worktree_base_ref "$REPO" never-ran '')" = HEAD ] || fail "HEAD fallback not chosen"
if worktree_base_ref "$REPO" '' no-such-branch >/dev/null 2>&1; then fail "missing base must return 1"; fi
git -C "$REPO" merge -q --ff-only ai/alpha
[ "$(worktree_base_ref "$REPO" alpha main)" = main ] || fail "merged parent should fall back to base"
branch_unmerged "$REPO" ai/alpha main && fail "fast-forward merged branch reported unmerged"

# ── 7b. merged by patch: a rebased merge counts, an altered one does not ──
# Simulates `git pull --rebase` after merging: the task's commit lands on
# main under a NEW hash, on top of a commit that arrived from elsewhere.
git -C "$REPO" branch -q ai/rebased main
git -C "$REPO" worktree add -q "$tmp/rb" ai/rebased
echo rebased > "$tmp/rb/rebased.txt"
git -C "$tmp/rb" add -A && git -C "$tmp/rb" commit -qm "task commit"
branch_unmerged "$REPO" ai/rebased main || fail "unmerged branch reported merged"
echo upstream > "$REPO/upstream.txt"
git -C "$REPO" add upstream.txt && git -C "$REPO" commit -qm "someone else's commit"
git -C "$REPO" cherry-pick ai/rebased >/dev/null
git -C "$REPO" merge-base --is-ancestor ai/rebased main && fail "fixture: rebased copy should not be an ancestor"
branch_unmerged "$REPO" ai/rebased main && fail "rebased merge (same patch, new hash) reported unmerged"
[ "$(worktree_base_ref "$REPO" rebased main)" = main ] || fail "rebased-merged parent should fall back to base"

# The same commit with its content changed on the way in stays unmerged.
git -C "$REPO" branch -q ai/altered "$(git -C "$REPO" rev-parse 'main~2')"
git -C "$REPO" worktree add -q "$tmp/alt" ai/altered
echo original > "$tmp/alt/altered.txt"
git -C "$tmp/alt" add -A && git -C "$tmp/alt" commit -qm "task commit"
echo edited-while-merging > "$REPO/altered.txt"
git -C "$REPO" add altered.txt && git -C "$REPO" commit -qm "task commit"
branch_unmerged "$REPO" ai/altered main || fail "altered patch reported merged"
[ "$(worktree_base_ref "$REPO" altered main)" = ai/altered ] || fail "altered parent should still be the base ref"
branch_unmerged "$REPO" no/such/branch main || fail "git error must read as unmerged"
git -C "$REPO" worktree remove --force "$tmp/rb"
git -C "$REPO" worktree remove --force "$tmp/alt"

# ── 8. worktree_prune ──────────────────────────────────────────────────────
touch "$TASKS_DIR/review/2026-10-29_alpha.md"
worktree_ensure "$REPO" beta >/dev/null 2>&1
worktree_ensure "$REPO" gamma >/dev/null 2>&1
echo wip > "$REPO/.ai-worktrees/gamma/wip.txt"
PRUNED=$(worktree_prune "$REPO" 2>/dev/null)
printf '%s\n' "$PRUNED" | grep -qx beta || fail "finished task's worktree not pruned"
printf '%s\n' "$PRUNED" | grep -qx failing || fail "finished task's (failed setup) worktree not pruned"
[ -d "$REPO/.ai-worktrees/alpha" ] || fail "in-flight task's worktree pruned"
[ -d "$REPO/.ai-worktrees/gamma" ] || fail "dirty worktree pruned"
git -C "$REPO" show-ref --verify --quiet refs/heads/ai/beta || fail "prune deleted a branch"

# ── 9. rewrite_workdir_paths ───────────────────────────────────────────────
W="$REPO/.ai-worktrees/alpha"
rw() { printf '%s\n' "$1" | rewrite_workdir_paths "$REPO/" "$W" "${2:-}" 2>/dev/null; }
[ "$(rw 'grep x ~/Projects/demo/app/A.php')" = "grep x $W/app/A.php" ] || fail "~ form not rewritten"
[ "$(rw "cat $REPO/file.txt")" = "cat $W/file.txt" ] || fail "absolute form not rewritten"
[ "$(rw 'cd $HOME/Projects/demo && ls')" = "cd $W && ls" ] || fail "\$HOME form not rewritten"
[ "$(rw 'cd ${HOME}/Projects/demo')" = "cd $W" ] || fail "\${HOME} form not rewritten"
[ "$(rw '`git -C ~/Projects/demo diff`')" = "\`git -C $W diff\`" ] || fail "backticked path not rewritten"
[ "$(rw 'ls ~/Projects/demo-old/x')" = 'ls ~/Projects/demo-old/x' ] || fail "sibling directory rewritten"
[ "$(rw "ls $W/x")" = "ls $W/x" ] || fail "worktree path rewritten twice"
[ "$(rw 'a ~/Projects/demo b ~/Projects/demo/c')" = "a $W b $W/c" ] || fail "second occurrence missed"
[ "$(rw 'docker exec w bash -c "cd /var/www/demo && pest"' /var/www/demo)" \
    = 'docker exec w bash -c "cd /var/www/demo/.ai-worktrees/alpha && pest"' ] || fail "container path not rewritten"
[ "$(rw 'cd /srv/var/www/demo' /var/www/demo)" = 'cd /srv/var/www/demo' ] || fail "container path matched mid-path"
[ "$(rw 'nothing to see')" = 'nothing to see' ] || fail "unrelated line changed"

# ── 10. a working directory below the repository top ──────────────────────
WTS=$(worktree_ensure "$REPO/sub" delta 2>/dev/null) || fail "ensure from subdirectory failed"
[ "$WTS" = "$REPO/.ai-worktrees/delta/sub" ] || fail "subdirectory not mirrored: $WTS"
[ -f "$WTS/inner.txt" ] || fail "subdirectory content missing"
out=$(printf 'cd /var/www/demo\n' | rewrite_workdir_paths "$REPO/sub" "$WTS" /var/www/demo 2>/dev/null)
[ "$out" = 'cd /var/www/demo' ] || fail "container path rewritten for a subdirectory workdir"

# ── 11. worktree_key: one branch per brief ─────────────────────────────────
printf '## Project\niso\n\n## Brief\n/x/briefs/done/my-refactor-brief.md\n' > "$tmp/step1.md"
printf '## Brief\n`/x/briefs/2026-09-12_08-15_dated-brief.md`\n' > "$tmp/dated.md"
printf '## Project\niso\n' > "$tmp/2026-10-30_hand-written.md"
printf '## Brief\n@@@\n' > "$tmp/2026-10-30_bad-brief.md"
[ "$(worktree_key "$tmp/step1.md")" = my-refactor-brief ] || fail "brief key not used"
[ "$(worktree_key "$tmp/2026-10-30_hand-written.md")" = hand-written ] || fail "task without ## Brief must keep its slug"
[ "$(worktree_key "$tmp/2026-10-30_bad-brief.md")" = bad-brief ] || fail "unusable ## Brief must fall back to the task slug"
k=$(worktree_key "$tmp/dated.md")
[ "$(worktree_slug "$k")" = "$k" ] || fail "key is not a fixed point of worktree_slug: $k"

# ── 12. worktree_claim / worktree_owner ────────────────────────────────────
WB=$(worktree_ensure "$REPO" my-refactor-brief 2>/dev/null) || fail "brief ensure failed"
worktree_claim "$WB" step-1 >/dev/null || fail "first claim refused"
[ "$(worktree_owner "$WB")" = step-1 ] || fail "owner not recorded"
echo step1 > "$WB/step1.txt"
worktree_claim "$WB" step-1 >/dev/null || fail "owner's own retry refused"
if out=$(worktree_claim "$WB" step-2); then fail "claim over another task's dirty work allowed"; fi
[ "$out" = step-1 ] || fail "refusal did not name the owner: $out"
[ -f "$WB/step1.txt" ] || fail "refused claim touched the worktree"
printf 'Step 1\n' > "$tmp/msg1"
worktree_commit "$WB" "$tmp/msg1" 2>/dev/null || fail "step-1 commit failed"
[ -z "$(worktree_owner "$WB")" ] || fail "commit did not clear the owner"
worktree_claim "$WB" step-2 >/dev/null || fail "claim after the owner landed refused"
echo step2 > "$WB/step2.txt"
printf 'Step 2\n' > "$tmp/msg2"
worktree_commit "$WB" "$tmp/msg2" 2>/dev/null || fail "step-2 commit failed"
[ "$(git -C "$REPO" log --format=%s main..ai/my-refactor-brief | tr '\n' ,)" = 'Step 2,Step 1,' ] \
    || fail "brief branch is not one stack of per-task commits"
# A stale owner over a clean tree (its changes were discarded) does not block.
worktree_claim "$WB" step-3 >/dev/null
worktree_claim "$WB" step-4 >/dev/null || fail "stale owner over a clean tree blocked a claim"

# ── 13. a brief's worktree survives while any of its tasks is in flight ────
rm -f "$TASKS_DIR"/review/*.md "$TASKS_DIR"/inbox/*.md
cp "$tmp/step1.md" "$TASKS_DIR/inbox/2026-10-30_step-2.md"
cp "$tmp/step1.md" "$TASKS_DIR/run/2026-10-30_step-1.md"
printf '%s\n' "$(active_task_keys)" | grep -qx my-refactor-brief || fail "brief key not active"
printf '%s\n' "$(active_task_keys "$TASKS_DIR/run/2026-10-30_step-1.md")" | grep -qx my-refactor-brief \
    || fail "excluding one task hid its in-flight sibling"
PRUNED=$(worktree_prune "$REPO" 2>/dev/null)
printf '%s\n' "$PRUNED" | grep -qx my-refactor-brief && fail "in-flight brief worktree pruned"
rm "$TASKS_DIR/inbox/2026-10-30_step-2.md"
printf '%s\n' "$(active_task_keys "$TASKS_DIR/run/2026-10-30_step-1.md")" | grep -qx my-refactor-brief \
    && fail "excluded task still counted"
rm "$TASKS_DIR/run/2026-10-30_step-1.md"
PRUNED=$(worktree_prune "$REPO" 2>/dev/null)
printf '%s\n' "$PRUNED" | grep -qx my-refactor-brief || fail "finished brief worktree not pruned"
git -C "$REPO" show-ref --verify --quiet refs/heads/ai/my-refactor-brief || fail "prune deleted the brief branch"

# ── 14. worktree_blocker: the picker's view of a shared worktree ───────────
cp "$tmp/step1.md" "$TASKS_DIR/inbox/2026-10-30_step-1.md"
cp "$tmp/step1.md" "$TASKS_DIR/inbox/2026-10-30_step-2.md"
printf '## Project\nplain\n\n## Brief\n/x/my-refactor-brief.md\n' > "$TASKS_DIR/inbox/2026-10-30_shared.md"
worktree_blocker "$TASKS_DIR/inbox/2026-10-30_step-2.md" >/dev/null && fail "blocked before any worktree exists"
WB=$(worktree_ensure "$REPO" my-refactor-brief 2>/dev/null)
worktree_claim "$WB" step-1 >/dev/null
worktree_blocker "$TASKS_DIR/inbox/2026-10-30_step-2.md" >/dev/null && fail "blocked by a clean worktree"
echo wip > "$WB/wip.txt"
[ "$(worktree_blocker "$TASKS_DIR/inbox/2026-10-30_step-2.md")" = step-1 ] || fail "sibling not blocked by the owner's dirty work"
worktree_blocker "$TASKS_DIR/inbox/2026-10-30_step-1.md" >/dev/null && fail "owner blocked by its own work"
worktree_blocker "$TASKS_DIR/inbox/2026-10-30_shared.md" >/dev/null && fail "shared project task blocked"
worktree_blocker "$TASKS_DIR/inbox/2026-10-30_hand-written.md" >/dev/null 2>&1 && fail "task without ## Brief blocked"
rm "$WB/wip.txt" "$TASKS_DIR"/inbox/*.md

# ── task_base_branch: task, then brief, then project ───────────────────────
mkdir -p "$TASKS_DIR/briefs/done"
printf '## Isolation: worktree\n\n## Base Branch: main\n' > "$TASKS_DIR/projects/based.md"
printf '# brief\n\n## Base Branch: `feature/x`\n' > "$TASKS_DIR/briefs/done/based-brief.md"
printf '# brief without a base\n' > "$TASKS_DIR/briefs/done/plain-brief.md"
BT="$TASKS_DIR/inbox"
printf '## Project\nbased\n\n## Base Branch\nfeature/task\n\n## Brief\n%s\n' \
    "$TASKS_DIR/briefs/done/based-brief.md" > "$BT/2026-10-30_own.md"
printf '## Project\nbased\n\n## Brief\n%s\n' \
    "$TASKS_DIR/briefs/done/based-brief.md" > "$BT/2026-10-30_from-brief.md"
cp "$TASKS_DIR/briefs/done/based-brief.md" "$HOME/home-brief.md"
printf '## Project\nbased\n\n## Brief\n`~/home-brief.md`\n' > "$BT/2026-10-30_tilde.md"
printf '## Project\nbased\n\n## Brief\n%s\n' \
    "$TASKS_DIR/briefs/done/plain-brief.md" > "$BT/2026-10-30_plain.md"
printf '## Project\nbased\n\n## Brief\n%s\n' \
    "$TASKS_DIR/briefs/done/gone-brief.md" > "$BT/2026-10-30_gone.md"
printf '## Project\nbased\n' > "$BT/2026-10-30_none.md"
printf '## Project\nplain\n' > "$BT/2026-10-30_unset.md"
[ "$(task_base_branch "$BT/2026-10-30_own.md" based)" = feature/task ] || fail "task's own base must win"
[ "$(task_base_branch "$BT/2026-10-30_from-brief.md" based)" = feature/x ] || fail "brief's base not used"
[ "$(task_base_branch "$BT/2026-10-30_tilde.md" based)" = feature/x ] || fail "~/ brief path not expanded"
[ "$(task_base_branch "$BT/2026-10-30_plain.md" based)" = main ] || fail "brief without base must fall to project"
[ "$(task_base_branch "$BT/2026-10-30_gone.md" based)" = main ] || fail "unreadable brief must fall to project"
[ "$(task_base_branch "$BT/2026-10-30_none.md" based)" = main ] || fail "no brief must fall to project"
[ -z "$(task_base_branch "$BT/2026-10-30_unset.md" plain)" ] || fail "unset everywhere must print nothing"
# A brief naming a branch the repository lacks is refused downstream, never
# replaced by the project's base.
if worktree_base_ref "$REPO" '' "$(task_base_branch "$BT/2026-10-30_from-brief.md" based)" >/dev/null 2>&1; then
    fail "unresolvable brief base must be refused"
fi
rm "$BT"/*.md "$HOME/home-brief.md"

# ── worktree_action: one next step per branch, first match wins ────────────
WA=$(worktree_ensure "$REPO" act-open 2>/dev/null) || fail "act-open ensure failed"
[ "$(worktree_action "$REPO" act-open main 0 1)" = fix ] || fail "a task in review must be fix"
[ "$(worktree_action "$REPO" act-open main 2 1)" = fix ] || fail "review must win over tasks in flight"
[ "$(worktree_action "$REPO" act-open main 2 0)" = wait ] || fail "tasks in flight must be wait"
[ "$(worktree_action "$REPO" act-open main 0 0)" = prune ] || fail "clean worktree, nothing left, must be prune"
echo wip > "$WA/wip.txt"
[ "$(worktree_action "$REPO" act-open main 0 0)" = commit ] || fail "dirty worktree, nothing left, must be commit"
[ "$(worktree_action "$REPO" act-open main 1 0)" = wait ] || fail "dirty worktree with a task in flight must be wait"
git -C "$WA" add wip.txt && git -C "$WA" commit -q -m wip
git -C "$REPO" worktree remove "$WA"
[ "$(worktree_action "$REPO" act-open main 0 0)" = merge ] || fail "unmerged branch without worktree must be merge"
git -C "$REPO" cherry-pick ai/act-open >/dev/null
[ "$(worktree_action "$REPO" act-open main 0 0)" = done ] || fail "patch-merged branch must be done"
[ "$(worktree_action "$REPO" no-such-key main 0 0)" = done ] || fail "missing branch must be done"

# ── branch_base: the merge target recorded per branch ──────────────────────
[ "$(branch_base "$REPO" bb-key main)" = main ] || fail "unrecorded base must fall back"
[ "$(branch_base "$REPO" bb-key)" = HEAD ] || fail "unrecorded base, no fallback, must be HEAD"
branch_base_record "$REPO" bb-key '' || fail "empty base must be a no-op"
[ "$(branch_base "$REPO" bb-key main)" = main ] || fail "empty base must record nothing"
git -C "$REPO" branch -q feature/x main
git -C "$REPO" branch -q ai/bb-key main
branch_base_record "$REPO" bb-key feature/x || fail "recording a base failed"
branch_base_record "$REPO" bb-key other || fail "second record must not fail"
[ "$(branch_base "$REPO" bb-key main)" = feature/x ] || fail "first recorded base must win"
# Survives the worktree: recorded in the repository, not in .git/worktrees/.
WB=$(worktree_ensure "$REPO" bb-key 2>/dev/null) || fail "bb-key ensure failed"
echo b > "$WB/b.txt"; git -C "$WB" add b.txt && git -C "$WB" commit -q -m b
git -C "$REPO" worktree remove "$WB"
[ "$(branch_base "$REPO" bb-key main)" = feature/x ] || fail "base must survive worktree removal"
# Merged into its own base, not the project's: done, though main lacks it.
git -C "$REPO" checkout -q feature/x && git -C "$REPO" merge -q ai/bb-key
git -C "$REPO" checkout -q main
[ "$(worktree_action "$REPO" bb-key "$(branch_base "$REPO" bb-key main)" 0 0)" = done ] \
    || fail "branch merged into its recorded base must be done"
[ "$(worktree_action "$REPO" bb-key main 0 0)" = merge ] || fail "against the project base it is still unmerged"
git -C "$REPO" branch -q -D ai/bb-key
[ "$(branch_base "$REPO" bb-key main)" = main ] || fail "deleting the branch must drop the record"

if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: worktree helpers"
    exit 0
fi
echo "$FAILURES failure(s)" >&2
exit 1
