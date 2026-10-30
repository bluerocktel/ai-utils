# Worktree isolation

By default every task of a project works in the project's one working
directory, one task at a time, next to whatever uncommitted work is already
there. A project can instead give each **brief** its own git worktree and
branch, so the agent never touches your checkout. Nothing is merged for you.

Related: [reference: project file fields](reference.md#project-file-fields),
[configuration](configuration.md).

## Turning it on

Add these sections to the project file, `projects/<name>.md`:

```markdown
## Working Directory
`~/Projects/demo/`

## Isolation: worktree

## Base Branch: main

## Container Path: /var/www/demo

## Worktree Setup
cp -a "$AI_MAIN_WORKDIR/vendor" vendor
ln -s ../../.env .env
```

| Section | Meaning |
|---|---|
| `## Isolation` | `worktree` opts in. Absent or `shared` is the normal shared tree. Any other value sends the task to `review/` (no retry burned) rather than guessing. |
| `## Base Branch` | Where a new branch starts. Unset: the main tree's current `HEAD`. A name that does not resolve is an error, never a fallback. A brief or a task can override it, see [Base branch](#base-branch). |
| `## Container Path` | Where a container mounts the working directory, so `docker exec ... cd /var/www/demo` lines point at the worktree too. Only used when the working directory is the repository top. |
| `## Worktree Setup` | One bash script, run with `-e` from the worktree, once per worktree, for what git does not carry: dependency folders, `.env`. `AI_MAIN_WORKDIR` and `AI_WORKTREE` are exported. What it leaves untracked is recorded and never committed. |

Before enabling it:

- Requires git 2.48 or later (`git worktree add --relative-paths`).
- **Copy a dependency folder, never symlink it.** Some tools (Composer's
  autoloader, for example) resolve their real path, so a symlinked `vendor/`
  loads the main checkout's code and the tests grade code the task never
  wrote. `cp -a` is fast and the copy goes when the worktree goes. Run a real
  install when the task changes the dependency manifest.
- A symlink is fine for a plain file such as `.env`. Make it **relative**: an
  absolute one breaks inside a container.
- Tools that scan `.` (static analysers, formatters) may now see the copies
  under `.ai-worktrees/`. Exclude that folder in their config.

## What happens to a task

1. **Claim.** After taking the project lock, `ai-task` creates or reuses
   `<repo>/.ai-worktrees/<key>/` on branch `ai/<key>`.
   - **The key is the brief.** Every task carrying `## Brief` (stamped by
     `ai-brief`) uses the brief file's name, so all tasks of one brief stack
     their commits on one branch, in the order they run. A task with no
     `## Brief` uses its own slug.
   - A retry, an `--unblock` and a grade-only resume find the previous
     attempt's changes still there.
   - The first task of a brief whose `## Depends-on` parent is not yet merged
     starts from the parent's branch, so a chain builds on itself.
   - The folder is hidden through `.git/info/exclude`. No tracked file changes.
2. **Run.** The agent works in the worktree. Every reference to the working
   directory in the task text (`~/...`, `$HOME/...`, absolute, and the
   container path) is rewritten to the worktree, and the prompt says so.
3. **Grade.** `ai-eval` applies the same rewrite, runs `## Test Command` inside
   the worktree, and starts the grader there.
4. **Land.** On PASS the work is committed on `ai/<key>` with the report's
   suggested commit message and an `AI-Task:` trailer naming the task. The
   worktree is removed unless another task of the brief is still in flight.
   **The branch is kept. Merging is yours.** The report and `DONE.md` get a
   `**Branch:**` line.
5. **Review or requeue.** On FAIL or `review/`, the worktree is kept for the
   next attempt or for you to inspect.

### One owner per worktree

A brief's worktree belongs to the task whose uncommitted changes it holds.
While that task is unfinished (being retried, or in `review/`), the brief's
other tasks are skipped by the picker, and deferred with no retry if run
directly. They resume when the owner passes, or when you throw its changes
away:

```sh
git -C <worktree> checkout -- . && git -C <worktree> clean -fd
```

### Clean-up

- A failed `## Worktree Setup` is a deferral: requeued, no retry burned.
- Every `ai-task` sweep removes worktrees whose tasks are all gone from
  `inbox/`, `run/` and `review/`. It skips projects whose lock is held and any
  worktree with uncommitted changes. `ai-task --prune-worktrees` does the same
  on demand.
- Branches are never deleted.
- Tasks of one project still run **one at a time**: a worktree isolates files,
  not the database, containers or test ports.

## Base branch

The base branch is the first one found:

1. the task file's own `## Base Branch`;
2. `## Base Branch` in the brief named by the task's `## Brief`;
3. the project's `## Base Branch`;
4. the main tree's current `HEAD`.

To start one brief from another branch, for example a fix that must start from
a release branch, put the line in the brief rather than editing the project
file:

```markdown
# demo task

## Project
demo

## Base Branch: release/2.4
```

- `ai-brief` stamps `## Brief` on every task, so the decomposition does not
  need to copy the line.
- A brief that can no longer be read falls back to the project's value.
- A name that does not resolve sends the task to `review/`, never to another
  branch.
- All tasks of a brief share one branch, so the value only matters to the
  brief's first task.
- `dtask` compares branches with the **project's** `## Base Branch`, so a branch
  started elsewhere shows as "ready to merge" until that other branch is
  merged into the project's base.

## The WORKTREES section in dtask

`dtask` shows a WORKTREES section when at least one project uses
`## Isolation: worktree`. It has **one line per `ai/*` branch** (or per
worktree left without a branch), sorted most urgent first:

```
  WORKTREES
  demo  login-fix     ✗ demo-login-fix-2 failed review: fix it, then ai-task --unblock demo-login-fix-2
  demo  export-csv    ⇢ ready to merge into main: git merge ai/demo-export-csv-brief
  demo  api-cleanup   ⏳ 2 tasks still to run, nothing to do yet
  demo  +5 merged branches  ✓ can be deleted: git branch -d ai/…
```

Each line is the project, the short brief name (without the `ai/` prefix, the
project name and the `-brief` suffix), then an icon, the status in plain words
and what to run. The status is decided by `worktree_action` in `lib.sh`, which
checks in this order and stops at the first match: a task in `review/`, tasks
still queued or running, a worktree on disk (dirty or clean), unmerged work,
merged. Lines are sorted in the order of this table:

| Icon | Status | When | What you do |
|---|---|---|---|
| `✗` | failed review: fix it, then `ai-task --unblock <slug>` | a task of the brief is in `review/` | Fix that task file, then `ai-task --unblock <slug>`. Or discard the worktree's changes (command above). Until then the brief's other tasks wait. |
| `⚠` | changes left uncommitted, no task left: commit or discard in `<worktree path>` | the worktree holds changes and no task of the brief is left to commit them | Look at the changes, then commit them on the branch or discard them. The sweep never removes a dirty worktree. |
| `⇢` | ready to merge into `<base>`: `git merge ai/<key>` | the branch holds work its base does not have | Review the branch and merge it. |
| `·` | finished, worktree removed by the next sweep | a clean worktree nothing needs any more | Nothing. |
| `⏳` | N task(s) still to run, nothing to do yet | tasks of the brief are still in `inbox/` or `run/` | Nothing. |
| `✓` | merged, can be deleted: `git branch -d ai/<key>` | the branch's changes are in its base | Optionally delete the branch. The pipeline never does. |

- "Merged" means the branch's patches are in the base, not that the commits
  are ancestors, so a merge followed by `git pull --rebase` still counts.
- Past three merged branches in one repository, they fold into one line,
  `+N merged branches`.
- Branches **ready to merge** and worktrees with **uncommitted changes and no
  task left** also appear in NEEDS ATTENTION, marked `see WORKTREES`. A task in
  `review/` is already listed there as a failed task, so it is not repeated.
- `dtask` stays read-only here: it runs git with `GIT_OPTIONAL_LOCKS=0` so not
  even the index is refreshed.
