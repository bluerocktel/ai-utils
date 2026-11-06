# Getting started

Install the pipeline on a fresh machine, write a first project file and a first
brief, and see them on the dashboard.

The paths on this page are examples: the repository at `~/Scripts/ai-utils/`
and the task tree at `~/tasks/`. You can put the repository anywhere, and the
task tree goes wherever `TASKS_DIR` points (default `~/tasks`). Every script
honours a `TASKS_DIR` override.

Related pages: [writing briefs](writing-briefs.md),
[reviewing tasks](reviewing-tasks.md), [configuration](configuration.md),
[reference](reference.md).

## 1. Dependencies

- `bash`, `tmux`, `jq`, `flock` and `timeout` (the last two come with
  util-linux and coreutils on most Linux systems), and `git`.
- Python 3, only for the live view `dtask -w`.
- The command-line tool of each provider you want to run, installed, logged in
  and on `PATH`: `claude`, `grok` or `codex`. You need at least one. Each
  provider is a file in `providers/`, and its file name is the runner name you
  write in `config` and in tasks.

Check the basics:

```sh
for c in bash tmux jq flock timeout git; do command -v "$c" >/dev/null || echo "missing: $c"; done
```

This prints nothing when everything is installed.

## 2. Clone

```sh
git clone <repository-url> ~/Scripts/ai-utils
cd ~/Scripts/ai-utils
```

## 3. Config

`config` sits next to the scripts and is not tracked by git. Start from the
template:

```sh
cp config.example config
grep '^default_runner' config
```

Set `default_runner` to the provider you use (`claude`, `grok` or `codex`).
A task with no `## Runner` section runs on this runner. Every other key has a
working default; they are all described in [configuration](configuration.md).

## 4. Create the task tree

```sh
./init
```

`init` creates `~/tasks/` with `briefs/`, `briefs/done/`,
`backlog-for-review/`, `inbox/`, `run/`, `done/`, `review/`, `projects/`,
`scheduled/`, `suggestions/` and `DONE.md`. It only ever adds: running it again
is harmless. Once the symlinks below are installed it is also available as
`ai-init`.

To try things out without touching your real tree, use a throwaway one:

```sh
TASKS_DIR=$(mktemp -d) ./init
```

A throwaway tree also gets a sample task and an example project file.

## 5. Put the scripts on your PATH

Nothing in the pipeline installs symlinks or cron lines for you. Run these
yourself:

```sh
mkdir -p ~/bin
ln -s ~/Scripts/ai-utils/init         ~/bin/ai-init
for s in ai-task ai-eval ai-brief ai-briefs ai-scheduled ai-agent ai-history ai-ask ai-propose dtask; do
    ln -s ~/Scripts/ai-utils/$s ~/bin/$s
done
export PATH="$HOME/bin:$PATH"   # add this line to your shell profile too
```

`init` is installed as `ai-init` so it does not clash with the system `init`.
Keep the name `ai-task` exactly: it starts its own tmux child as
`~/bin/ai-task --run`.

Check:

```sh
ls -l ~/bin/ai-init ~/bin/ai-task ~/bin/dtask
```

## 6. A first project file

A project file tells the agent where the code lives and how to work in it. The
file name is the project name. Create `~/tasks/projects/demo.md`:

```sh
mkdir -p ~/Projects/demo
cat > ~/tasks/projects/demo.md <<'EOF'
# demo

## Type
code

## Aliases
- `demo`

## Working Directory
`~/Projects/demo/`

## Stack
Short notes for the agent: language, framework, how to run the tests.

## Relationships
(none)
EOF
```

The fields are listed in [reference: project file fields](reference.md#project-file-fields),
and the template is explained in [writing briefs](writing-briefs.md#project-file-template).

## 7. A first brief

A brief is a short description of a feature in plain words. `ai-brief` turns
it into a chain of tasks. Create `~/tasks/briefs/demo-hello.md`:

```sh
cat > ~/tasks/briefs/demo-hello.md <<'EOF'
# demo: hello script

## Project
demo

## Context
The project has no entry point yet. Add a small script that prints a greeting.

## Task/tasks to create
1. Add hello.sh at the repository root that prints 'hello, world' and exits 0.
2. Add a README.md section that shows how to run it.

## Acceptance criteria guidance
- bash hello.sh prints exactly 'hello, world'.
EOF
```

How to write a good brief, and the rules for acceptance criteria, are in
[writing briefs](writing-briefs.md).

## 8. Look at the dashboard

```sh
dtask
```

`dtask` reads the tree and writes nothing, so it is always safe to run. It
shows the brief waiting in `briefs/`, the pipeline counts and recent activity.
`dtask -w` is a live view that refreshes every 30 seconds.

`ai-agent` is the other read-only script. It lists agent routines, and with a
fresh clone it has none to show:

```sh
ai-agent --validate
```

## 9. Run the loop by hand

These commands call an agent, so they use your provider account:

```sh
ai-brief          # makes an agent call: brief -> tasks in backlog-for-review/
dtask             # read the new tasks under NEEDS ATTENTION
mv ~/tasks/backlog-for-review/<task>.md ~/tasks/inbox/   # promote the ones you approve
ai-task           # makes an agent call: runs and grades the oldest task
```

`ai-task` also calls `ai-eval` (which makes an agent call) to grade the
result. What to check before promoting a task, and what to do with a task that
fails, is in [reviewing tasks](reviewing-tasks.md).

## 10. Cron lines

Once the loop works by hand, let cron run it. The pipeline never edits your
crontab: open it with `crontab -e` and add lines like these yourself.

```cron
PATH=/usr/local/bin:/usr/bin:/bin
*/15 * * * * $HOME/bin/ai-task      >> $HOME/tasks/cron.log 2>&1
*/15 * * * * $HOME/bin/ai-briefs    >> $HOME/tasks/cron.log 2>&1
*/30 * * * * $HOME/bin/ai-scheduled >> $HOME/tasks/cron.log 2>&1
```

- Cron starts with a minimal `PATH`. Make sure the `PATH` line includes the
  folder of each provider's command-line tool, and of `tmux` and `jq`.
- `ai-task` runs one task per call, on its own runner. To give a runner its own
  rhythm, add one line per runner with `--runner NAME`.
- `ai-briefs` is optional: leave it out if you prefer to start decompositions
  by hand.
- `ai-scheduled` is only needed for recurring jobs; see
  [scheduled jobs](scheduled-jobs.md).
- Every script exits quietly when there is nothing to do, so `cron.log` stays
  small.

## Next

- [Writing briefs](writing-briefs.md): templates and the acceptance criteria
  checklist.
- [Reviewing tasks](reviewing-tasks.md): the review queue, retries, `review/`.
- [Configuration](configuration.md): every config key, runners, split grading.
- [Worktrees](worktrees.md): one git worktree per brief for a project.
