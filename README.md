# ai-utils

Shell scripts that turn a short written brief into a chain of tasks, run each
task headlessly with a coding agent (Claude, Grok or Codex), grade the result
against the task's acceptance criteria, and retry or park it for you. Nothing
runs before a human has read it: every generated task waits in a review queue
until you move it into the inbox. The scripts are plain bash, run on your own
machine from cron or by hand, and keep all their state in one folder of
markdown files. The provider is a field on each task, so several providers can
share one queue, one dashboard and one set of project locks.

## The loop

```
   briefs/                        a loose, high-level feature brief
      │  ai-brief                 one agent call decomposes it into a chain
      ▼
   backlog-for-review/            structured tasks, each stamped ## Runner
      │  ═══ HUMAN REVIEW ═══     you read them and move the good ones by hand
      ▼
   inbox/                         ready to run
      │  ai-task                  claims the oldest eligible task for its runner
      ▼
   run/                           one headless agent call, in a detached tmux
      │  ai-eval                  grades it against ## Acceptance Criteria,
      ▼                           after running any ## Test Command
   ┌──────────── verdict ────────────┐
  PASS                             FAIL
   │                    ┌────────────┴────────────┐
   ▼               retries left              max_retries
 done/                  │                         │
 + DONE.md              ▼                         ▼
   │                 inbox/                    review/
   │              (evaluator feedback        (parked for you)
   │               appended)
   └──▶ suggestions/              follow-up ideas, a reading pile you promote
```

A deferral (provider auth failure, busy project, timeout) puts the task back in
`inbox/` unchanged and costs no retry. Only a real FAIL verdict costs a retry.

The optional push side, `ai-scheduled`, runs recurring jobs and feeds the same
queues: a `template` job writes a task into `backlog-for-review/`, a `monitor`
or `planner` job writes follow-up ideas into `suggestions/`. See
[scheduled jobs and agents](docs/scheduled-jobs.md).

## Requirements

- Linux (or another system with GNU coreutils and util-linux).
- `bash`, `tmux`, `jq`, `flock`, `timeout` and `git`.
- Python 3, only for the live dashboard `dtask -w`.
- At least one provider's command-line tool, installed, logged in and on
  `PATH`: `claude`, `grok` or `codex`. Each provider is a file in
  `providers/`, and its file name is the runner name.

## Getting started

The paths below are examples: the repository at `~/Scripts/ai-utils/` and the
task tree at `~/tasks/`. Put either wherever you like; every script honours a
`TASKS_DIR` override.

```sh
git clone <repository-url> ~/Scripts/ai-utils
cd ~/Scripts/ai-utils
cp config.example config        # then set default_runner=claude|grok|codex
./init                          # creates ~/tasks/ (safe to re-run)
TASKS_DIR=$(mktemp -d) ./init   # or a throwaway tree to try things out
```

Put the scripts on your `PATH` (nothing here installs symlinks for you):

```sh
mkdir -p ~/bin
ln -s ~/Scripts/ai-utils/init ~/bin/ai-init
for s in ai-task ai-eval ai-brief ai-briefs ai-scheduled ai-agent ai-history dtask; do
    ln -s ~/Scripts/ai-utils/$s ~/bin/$s
done
```

Then write a project file in `~/tasks/projects/` (where the code lives, how to
work in it), drop a brief in `~/tasks/briefs/`, and run `dtask` to see it.
[docs/getting-started.md](docs/getting-started.md) walks through every step on
a fresh machine, with templates and the cron lines to add yourself.

## Daily use

```sh
# 1. write a brief
$EDITOR ~/tasks/briefs/demo-hello.md

# 2. decompose it (agent call): tasks land in backlog-for-review/
ai-brief

# 3. review: read each task, promote the ones you approve
dtask
mv ~/tasks/backlog-for-review/<task>.md ~/tasks/inbox/

# 4. run and grade the oldest eligible task (agent call); cron usually does this
ai-task

# 5. check the outcome
dtask
```

- `dtask` is a read-only dashboard: it never moves a file, so run it any time.
- A task that keeps failing ends up in `review/`. Fix its criterion, then
  `ai-task --unblock SLUG`. See [reviewing tasks](docs/reviewing-tasks.md).
- Most failures come from acceptance criteria a correct run cannot pass. The
  checklist in [writing briefs](docs/writing-briefs.md) prevents them.

## Scripts

| Script | What it does |
|---|---|
| `init` (as `ai-init`) | create the task tree. Idempotent, additive only. |
| `ai-brief` / `ai-briefs` | decompose one brief, or every brief, into tasks for review. |
| `ai-task` | claim one queued task, run it, grade it, archive it. |
| `ai-eval` | grade one finished task; its exit code is the interface. |
| `ai-scheduled` | dispatch the recurring jobs in `scheduled/` that are due. |
| `ai-agent` | read-only view of the agent layer: list, show, validate. |
| `ai-history` | what was done on a project and where it stands. |
| `dtask` | read-only dashboard across every runner. |

Every flag is in [the reference](docs/reference.md).

## Documentation

For users:

- [Getting started](docs/getting-started.md): full install, a first project
  file and brief, cron lines.
- [Writing briefs](docs/writing-briefs.md): brief and project file templates,
  the acceptance criteria checklist.
- [Reviewing tasks](docs/reviewing-tasks.md): the review queue, retries,
  `review/`, `--unblock`, dead dependency chains, suggestions.
- [Worktree isolation](docs/worktrees.md): one git worktree and branch per
  brief, base branches.
- [Scheduled jobs and agents](docs/scheduled-jobs.md): `ai-scheduled`, job
  files, the agent layer and `ai-agent`.
- [Configuration](docs/configuration.md): every config key, runners and
  providers, split grading, referenced project instructions.
- [Reference](docs/reference.md): scripts and flags, `ai-eval` exit codes,
  task, job and project file fields, locks and markers, `dtask`.

For maintainers and contributors:

- [CLAUDE.md](CLAUDE.md): working notes for anyone (human or agent) editing
  this repository: design reasoning, the gotchas, hard boundaries.
- [providers/CONTRACT.md](providers/CONTRACT.md): the six functions a provider
  file must implement. Read it to add a provider.
- [agents/CONTRACT.md](agents/CONTRACT.md): the agent-layer contract, with a
  worked example.
- [docs/history/cutover-2026-08.md](docs/history/cutover-2026-08.md): the
  original migration from the two earlier forks. Historical, not instructions.
