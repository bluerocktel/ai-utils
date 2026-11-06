# Reference

Scripts and flags, `ai-eval` exit codes, file fields, locks and markers.
Paths such as `~/tasks/` are examples: the task tree is wherever `TASKS_DIR`
points (default `~/tasks`).

Related pages: [configuration](configuration.md), [worktrees](worktrees.md),
[scheduled jobs and agents](scheduled-jobs.md),
[provider contract](../providers/CONTRACT.md).

## Scripts

Requires `bash`, `tmux`, `jq`, `flock`, `timeout`, and each provider's CLI on
`PATH`.

| Script | Install as | What it does | Flags |
|---|---|---|---|
| `init` | `ai-init` | Create the pipeline tree under `TASKS_DIR`. Idempotent, only adds. Exposed as `ai-init` to avoid clashing with system commands. | none |
| `ai-task` | `ai-task` | Claim one queued task, run it, grade it, archive it. | `--runner NAME`, `--dry-run`, `--unblock SLUG`, `--prune-worktrees`, a task path, `--run FILE` (internal) |
| `ai-eval` | `ai-eval` | Grade one finished task. The exit code is the interface. | `--runner NAME`, `--model ID`, `TASK_FILE RESULT_FILE [OUT_FILE]` |
| `ai-brief` | `ai-brief` | Turn one brief into a chain of tasks in `backlog-for-review/`. | `--runner NAME`, a brief path, `--run FILE` (internal) |
| `ai-briefs` | `ai-briefs` | Run `ai-brief` on every brief in `briefs/`, in parallel. | `--runner NAME` |
| `ai-scheduled` | `ai-scheduled` | Dispatch the recurring jobs in `scheduled/` that are due. | `--job SLUG`, `--force`, `--dry-run`, `--show-prompt`, `--runner NAME` |
| `ai-agent` | `ai-agent` | Read-only view of the agent layer: list, show, validate, print the publish command. | `--list`, `--show SLUG`, `--validate`, `--publish-plan [SLUG]` |
| `dtask` | `dtask` | Read-only dashboard of the whole tree, across every runner. | `-w` |
| `ai-history` | `ai-history` | What was done on a project and where it stands. Facts are rebuilt on each run; only the summary paragraph is written by an agent and cached. | `PROJECT`, `--facts`, `--refresh`, `-n N` |
| `ai-propose` | `ai-propose` | Draft the task-file fix for a task in `review/`, and apply it on request. Started by `ai-task` automatically; install the symlink only to run it by hand. | `SLUG`, `--apply SLUG`, `--context SLUG` |
| `ai-ask` | `ai-ask` | Ask one agent a question about its own work, answered from its charter and its routines' state. Writes nothing. | `AGENT QUESTION`, `AGENT --context` |

Supporting files: `lib.sh` (shared helpers, sourced, names no vendor) and
`providers/<runner>.sh` (the only files that name a vendor).

Only `init`, `dtask`, `ai-agent`, `ai-history --facts` and
`ai-scheduled --dry-run` are safe to point at a tree you care about while
testing: they make no agent call and move no task. `ai-history` and `ai-ask`
make one agent call but move no task either: `ai-history` writes only its
cache in `.history/`, and `ai-ask` writes nothing. For anything else, use a
throwaway tree:

```sh
TASKS_DIR=$(mktemp -d) ./init
```

Installing symlinks and cron lines is always your own manual step; no script
does it.

## ai-task

Runs one queued task in a detached tmux session, grades it, then archives it to
`done/`, requeues it to `inbox/`, or parks it in `review/`.

```sh
ai-task                          # oldest eligible inbox task, on its own runner
ai-task --runner grok            # only tasks that resolve to this runner
ai-task path/to/task.md          # run this file now (skips the queue filter)
ai-task --runner grok --dry-run  # show what would be claimed; claims nothing
ai-task --unblock SLUG           # review/ back to inbox/, ## Retries reset to 0
ai-task --prune-worktrees        # remove worktrees of finished tasks (branches kept)
ai-task --run FILE               # internal mode used by tmux; do not call it
```

- **Runner.** `--runner NAME` must match `providers/NAME.sh`. Resolution:
  `--runner`, then the task's `## Runner`, then `default_runner`. Unset never
  means "any runner".
- **Picker.** Selects the oldest unblocked inbox task whose runner is
  available: provider file present, no auth cooldown, no tmux session already
  running for it. One unavailable runner does not stop the others. With
  `--runner`, other runners' tasks stay in the inbox and are listed separately
  in the "nothing runnable" report. An explicit task path bypasses the filter.
- **tmux session** names embed the runner, `ai-<runner>-<task>`, so two runners
  never collide.
- **Self call.** The tmux child is `~/bin/ai-task --run`, falling back to the
  script's own folder when the symlink is not installed.
- **Dead chains.** Every sweep reports tasks blocked behind a parent in
  `review/`, or behind a slug that exists nowhere. `dtask` shows them under
  NEEDS ATTENTION.
- **`--unblock SLUG`** is the only supported way out of `review/`. It makes no
  agent call, strips any path from the argument, refuses a slug found elsewhere
  in the pipeline or matching two files in `review/`, and names the dependents
  it frees. It does not check that you fixed the task file.

### Outcomes

| Situation | Outcome | Retry burned |
|---|---|---|
| Grading passes | archived to `done/`, entry in `DONE.md` | no |
| Grading fails, retries left | back to `inbox/` with the evaluator's feedback; from the second failure a strategy pass is appended | yes |
| Grading fails, `max_retries` reached | moved to `review/` | no |
| Unsatisfiable criteria (`ai-eval` exit `5`) | moved to `review/` with the evaluator's evidence | no |
| Auth failure during the run | back to `inbox/`; the executing runner's cooldown starts | no |
| Auth failure while grading | back to `inbox/` with `## Awaiting-Eval`; the grading runner's cooldown starts | no |
| Project lock wait times out | back to `inbox/`, unchanged | no |
| Run killed, timed out, or produced no readable text | back to `inbox/`, unchanged | no |
| `## Worktree Setup` failed | back to `inbox/`, unchanged | no |
| Unknown `## Isolation` value | moved to `review/` | no |

Only a real FAIL verdict costs a retry.

### Records

- Every `DONE.md` entry has a `**Runner:**` line, plus `**Graded by:**` when
  the grader differs from the executor, and `**Branch:**` for a
  [worktree](worktrees.md) task.
- The task file is archived beside its report as `done/<ts>_<task>.task.md`
  next to `done/<ts>_<task>.md`.
- A running task has a `run/<task>.state` sidecar naming its runner and tmux
  session. It is removed when the run ends.

## Locks and markers

| Lock / marker | Path | Scope |
|---|---|---|
| Inbox claim | `$TASKS_DIR/.locks/inbox.lock` | Shared by all runners. Held for milliseconds: select, move to `run/`, write the state marker. Two invocations can never claim the same task. |
| Per project | `$TASKS_DIR/.locks/<canonical-project>.lock` | Shared by all runners, held for the whole run and grading: two agents must never be in the same repository at once. A wait timeout is a deferral. |
| Waiting on a precondition | `$TASKS_DIR/.precondition/<task>` | Per task. Written by `ai-task` when the task's `## Precondition` fails, removed when it passes or the task leaves `inbox/`. Read by the picker and `dtask`. |
| Auth cooldown | `$TASKS_DIR/.auth-cooldown-<runner>` | Per runner: a 401 on one provider never pauses another. A grading auth failure touches the grader's marker. Lasts `auth_cooldown_min`. |

**Aliases share one lock.** The project lock name goes through
`canonical_project`:

1. strip any path and keep only `[A-Za-z0-9._-]`;
2. if `projects/<value>.md` exists, use it;
3. else match the value, ignoring case, against every project's `## Aliases`
   and use that project's file name;
4. else use the cleaned value unchanged.

When the resolved name differs, `ai-task` prints one line saying so. Only the
lock name changes: `## Project` still means the raw value for loading the
project file, the prompt, the log and `DONE.md`. So a task written with an
undeclared spelling still does not load its project file: use the canonical
name.

### Preconditions

A task may carry a `## Precondition` section: shell commands, one per line,
that must all exit `0` before the task can be claimed. It is for what only you
can supply (a secret, a credential file, an access grant), never for work
another task produces (that is `## Depends-on`).

```
## Precondition
ssh -o BatchMode=yes -p 65022 fedora@worker-001.example 'grep -q "^SFTP_PASS=." ~/app/.env'
```

- Each command runs with `timeout bash -c` (`precondition_timeout_sec`) in
  the project's working directory, like `## Test Command`.
- The checks run on every sweep, **before** the inbox lock, and only for tasks
  the picker could otherwise take: a task blocked by its dependency is not
  checked.
- A failing check leaves the task in `inbox/` unchanged: no retry, no feedback
  section. The picker moves on to the next task. The failure is written to
  `.precondition/<task>` (time it started waiting, last check, failing command,
  exit status, last 5 output lines) and `dtask` shows the task as
  `⏸ waiting: precondition`.
- One notification when a task starts waiting; one log line per sweep.
- `--dry-run` checks into a temporary directory and writes nothing.
- A task named on the command line runs anyway, with a warning: same rule as
  the auth cooldown.
- Never print the secret in a check: test for presence (`grep -q`, `test -s`).

## ai-eval

Grades one finished task against its `## Acceptance Criteria`, after running
any `## Test Command`.

```sh
ai-eval TASK_FILE RESULT_FILE                 # verdict on stdout
ai-eval TASK_FILE RESULT_FILE verdict.md      # verdict written to a file
ai-eval --runner grok TASK_FILE RESULT_FILE   # grade with a specific runner
ai-eval --model ID TASK_FILE RESULT_FILE      # and a specific model
```

Runner and model resolution is in
[configuration: split grading](configuration.md#split-grading).

### ai-eval exit codes

`ai-task` branches on every code, so none may be renumbered.

| Code | Meaning | Burns a retry |
|---|---|---|
| `0` | PASS. A passing `## Test Command` with no `## Acceptance Criteria` is also a PASS. | no |
| `1` | FAIL: a `## Test Command` failed, or the evaluator returned `VERDICT: FAIL`. | yes |
| `2` | Nothing to grade: no criteria and no passing test command. Also a usage error or a missing file. `ai-task` keeps the run, ungraded. | no |
| `3` | Inconclusive: grader auth failure, empty verdict, or a runner that cannot be loaded. `ai-task` requeues and pauses that runner. | no |
| `4` | Inconclusive: a `## Test Command` timed out. The queue is not paused. | no |
| `5` | Unsatisfiable criteria: `VERDICT: UNSATISFIABLE` together with an `## Unsatisfiable Criteria` section. Straight to `review/`. | no |

- Exit `3` never prints a verdict line. Partial text is shown with its
  `VERDICT:` lines removed.
- `VERDICT: UNSATISFIABLE` without the `## Unsatisfiable Criteria` evidence
  section is exit `1`, not `5`.
- On exit `5`, `ai-task` appends the report under
  `## Evaluator (unsatisfiable acceptance criteria)` and does not touch
  `## Retries`. Fix the criterion, then `ai-task --unblock SLUG`.

### Test commands

- Every line under `## Test Command` runs in order, each under
  `timeout` of `test_timeout_min` minutes.
- The first non-zero exit stops the sequence and is a FAIL.
- Code fence lines are skipped.
- A trailing backslash joins a line to the next, and the joined command runs in
  one shell, so a `cd` stays in effect:

```
cd some/repo && \
make check
```

### How the evaluator grades

- Critical by default: no benefit of the doubt, a criterion it cannot verify is
  a FAIL, and it may use tools to check claims.
- Every criterion is graded as written. A criterion naming a file, path,
  command, table, flag or value means that exact one; a look-alike substitute
  fails it.
- For a [worktree](worktrees.md) project it grades the worktree, never the main
  tree.

## ai-brief and ai-briefs

Turns one brief into several task files in `backlog-for-review/`. Nothing it
writes runs until you move it into `inbox/` yourself: `ai-brief` has no write
path into `inbox/`.

```sh
ai-brief                             # oldest brief in briefs/
ai-brief briefs/my-feature.md        # a named brief
ai-brief --runner NAME               # decompose with a specific runner
ai-briefs                            # every brief in briefs/, one tmux session each
ai-brief --run FILE                  # internal mode used by tmux; do not call it
```

- An empty `briefs/` exits `0` silently, so both are safe on a timer.
- The decomposition runs inside the project's working directory, so the agent
  can measure criteria (`## Criteria Baseline`) before writing them.
- Success archives the brief to `briefs/done/`. Every failure (timeout, empty
  output, no task blocks, invalid graph, auth failure) puts it back in
  `briefs/`, with a `.raw` debug capture in `run/`.
- Emitted filenames are reduced to `[A-Za-z0-9._-]`, with no path.
- The auth cooldown is per runner, as in `ai-task`.

### Runner stamped on every task

`ai-brief` writes `## Runner` into every emitted task itself, replacing any the
model wrote.

| | Resolved from |
|---|---|
| runner that **decomposes** now | `--runner`, else `default_runner` |
| runner **stamped** on the tasks | the brief's `## Runner`, else `--runner`, else `default_runner` |

The stamped runner is checked against `providers/<runner>.sh` before the agent
call. If the stamp is missing from any file afterwards, the batch is rolled
back.

### Criteria checks and the repair pass

- `ai-brief` appends a `## Criteria Warnings` section to a task whose criteria
  look risky: an asserted integer, a `grep -c` on a pattern the task itself
  writes, more than one match demanded from one file, a git working-tree
  assertion, or a multi-word phrase greped against unjoined extracted text. It
  warns, never deletes.
- Before extraction it asks for **one repair pass** when a draft has a clean
  git-state assertion, a phrase search on wrapped extracted text, a command
  shortened with an ellipsis, a missing acceptance checklist, or malformed task
  delimiters. Same provider and model, same `brief_timeout_min` budget.
- If the repair fails, still has findings, or renames tasks, nothing is
  extracted: the brief goes back to `briefs/` and the draft and findings are
  saved to a `.raw` in `run/`. An auth failure starts that runner's cooldown.

### Dependency graph check

`repair_brief_task_graph` runs on the emitted batch before the brief is
archived.

| Graph problem | Outcome |
|---|---|
| `## Depends-on` names a slug that was not emitted | the section is removed, a note names the slug, the batch ships |
| a dependency cycle | fatal |
| no root (every task has a `## Depends-on`) | fatal |

A fatal graph deletes the whole batch, adds the notes to the debug capture in
`run/`, and restores the brief.

## ai-scheduled

```sh
ai-scheduled                          # dispatch every due job
ai-scheduled --job SLUG               # only that job (still checks it is due)
ai-scheduled --force                  # ignore due-ness
ai-scheduled --dry-run                # report only: no writes, no agent call
ai-scheduled --dry-run --show-prompt  # also print each rendered prompt
ai-scheduled --runner NAME            # act as this runner for every job
```

`--show-prompt` only works with `--dry-run`. Job file fields, schedules, kinds
and state are in [scheduled jobs](scheduled-jobs.md).

## ai-agent

```sh
ai-agent                        # list every routine, grouped by agent
ai-agent --list                 # same
ai-agent --show SLUG            # charter headers, then that routine
ai-agent --validate             # check every charter and routine; exit 1 on error
ai-agent --publish-plan [SLUG]  # print the cp command to publish; runs nothing
```

Writes nothing, anywhere. Details in
[scheduled jobs: ai-agent](scheduled-jobs.md#ai-agent).

## ai-history

```sh
ai-history                    # every project, with its last activity
ai-history PROJECT            # WHERE THINGS STAND, then NOW, RECENT, BRIEFS
ai-history PROJECT --facts    # facts only: no agent call, nothing written
ai-history PROJECT --refresh  # rewrite the paragraph even if nothing changed
ai-history PROJECT -n N       # show the last N finished tasks (default 15)
```

For when you come back to a project after a while. Everything except the
first paragraph is rebuilt from the tree on each run: finished tasks (from
`done/`, with the subject of each report's suggested commit message), what is
queued, running or in review, brief progress, and each `ai/` branch with
whether it still has to be merged into its base.

- **WHERE THINGS STAND** is a short paragraph an agent writes from those facts
  and the latest report summaries. It is cached in
  `$TASKS_DIR/.history/<project>.md` and rewritten only when the project's
  tasks or branches change, so opening an unchanged project costs nothing.
- A failed, timed-out or unauthenticated call shows the previous paragraph
  marked stale, or no paragraph yet. It never touches a cooldown marker, so it
  pauses no queue.
- The cache is for you only: no task prompt ever reads it.
- Runner and model: `history_runner`, `history_model`
  ([configuration](configuration.md#project-history-ai-history)).

## ai-ask

```sh
ai-ask                          # the agents you can ask
ai-ask AGENT "your question"    # one question, one agent call
echo "question" | ai-ask AGENT  # the question on stdin
ai-ask AGENT --context          # print what AGENT is given; no agent call
```

Asks one agent about its own work: what a routine saw, why it flagged
something, whether it is running. The answer comes only from what the agent
layer already keeps, each part capped in size: the charter and, for every
routine of the agent, its published copy (else its definition, marked not
published), its memory ledger, its last snapshot and its latest report.

- **Writes nothing**, not even a cache. The call runs in an empty temporary
  directory.
- **An auth failure, a timeout or an empty answer exits `1`** with the reason
  on stderr. A runner in auth cooldown is not called. `ai-ask` never touches a
  cooldown marker.
- **An unknown agent, a name that is not a plain agent name, or no question
  exits `2`** without a call.
- **Read-only is enforced by the empty directory and the prompt**, not by the
  provider, which runs with its usual permissions. Use `--context` to see
  exactly what the agent is given.
- Runner and model: `ask_runner`, `ask_model`
  ([configuration](configuration.md#asking-an-agent-ai-ask)).

## dtask

Read-only dashboard: no agent call, no file moved, nothing written.

```sh
dtask       # print once
dtask -w    # scrollable live view, refreshed every 30 s
```

Live view keys: Up/Down or j/k scroll, Page Up/Page Down (or b/Space) move a
page, Home/End (or g/G) jump, Left/Right read wide lines, r refreshes, q quits.
It needs Python 3 with its standard `curses` module. Redirected output is one
plain snapshot. `NO_COLOR` turns colours off.

Sections, top to bottom:

| Section | Shows |
|---|---|
| auth cooldown banner | one line per runner currently paused, with minutes left |
| NEEDS ATTENTION | tasks in `backlog-for-review/` and `review/`, dead dependency chains (`⊘`), worktree branches ready to merge or holding orphaned changes, and agent routines that will not run or are overdue |
| PIPELINE | counts per stage, plus `⊘ blocked(N)` for dead chains (these tasks are also counted in `inbox/`) |
| RUNNING | tasks in `run/`, with runner and tmux session from the `.state` sidecar |
| WORKTREES | only when a project uses [worktree isolation](worktrees.md#the-worktrees-section-in-dtask) |
| TODAY | completed, retried, deferred, failed and needs-review counts from `DONE.md` |
| BY RUNNER / BY PROJECT | stage counts per runner and per project |
| RECENT ACTIVITY | latest `DONE.md` entries, with a `[runner]` column |
| AGENTS | what each published agent routine is doing, one line each (see below); nothing when no routine is defined |

- Every task shows its resolved runner in `[brackets]`; an unset `## Runner`
  shows as `default_runner`.
- Runners are discovered from `providers/*.sh` and any `.auth-cooldown-*`
  marker present.
- RECENT ACTIVITY takes the runner from the archived `<base>.task.md`, then the
  report's `**Runner:**` line, then `default_runner`.
- A dead chain is a task whose `## Depends-on` parent is in `review/` or exists
  nowhere. A parent still queued is ordinary waiting and is not shown.

### The AGENTS section

One line per **published** routine, most urgent first:

| Line | When |
|---|---|
| `✗ will not run` | the published file has a schedule or a permission `ai-scheduled` rejects |
| `⚠ overdue` | no run for more than two periods plus an hour; usually `ai-scheduled` is not in cron |
| `✉ found something` | a run in the last 7 days signalled, with what it produced (messages, briefs, report, suggestions) |
| `⏳ waiting for its first run` | published, never run, not yet overdue |
| `✓ nothing to report` | everything else, with the time of the last run |

- After each line, `7d: N runs, K signals` counts the memory ledger's lines of
  the last 7 days. The ledger keeps only its last `agent_memory_lines` lines,
  so a busy routine shows `N+`.
- The ledger records conclusive runs only, so a routine whose runs keep failing
  shows as overdue, not as failed.
- Routines defined but not published fold into one line.
- Will not run and overdue also appear under NEEDS ATTENTION.
- Kind, schedule and permission are in `ai-agent`'s listing.

## Task file fields

A task is a markdown file in `inbox/`. Field headings are `## Field` with the
value on the next line. Newer fields such as `## Base Branch` also accept the
inline `## Field: value` form. Sections in a task override `config` where they
overlap.

| Field | Meaning |
|---|---|
| `## Project` | Project name: loads `projects/<name>.md` and selects the project lock. |
| `## Runner` | Runner that executes it. Unset, empty or `any`: `default_runner`. Stamped by `ai-brief`. |
| `## Model` | Model for the work. Unset: `default_model`, then the provider's choice. |
| `## Brief` | Path of the brief the task came from. Stamped by `ai-brief`; keys the [worktree](worktrees.md) and supplies a brief-level `## Base Branch`. |
| `## Depends-on` | ONE parent slug: only the first token of the first line is read. The task waits until `done/*_<slug>.task.md` exists. |
| `## Context`, `## Tasks` | Free text for the agent. |
| `## Criteria Baseline` | Commands run at decomposition time and what they returned, written before the criteria. Read by humans and the grader; no parser uses it. |
| `## Acceptance Criteria` | What the grader checks, each item as written. |
| `## Test Command` | Shell lines `ai-eval` runs before grading. See [test commands](#test-commands). |
| `## Base Branch` | Override of the worktree base branch for this task. See [worktrees](worktrees.md#base-branch). |
| `## Retries` | Failure counter written by `ai-task`. Reset to `0` by `--unblock`. |
| `## Evaluator Feedback (Attempt N)` | Appended by `ai-task` after each FAIL. |
| `## Awaiting-Eval` | Report name of finished work waiting for its grader. See [configuration](configuration.md#when-the-grader-hits-an-auth-failure). |
| `## Criteria Warnings` | Appended by `ai-brief` when a criterion looks risky. |

## Job file fields

Job files in `scheduled/<slug>.md` use the inline form, `## Field: value`:
`## Kind`, `## Schedule`, `## Project`, `## Model`, `## Runner`, and for agent
routines `## Agent`, `## Permission`, `## Routes`. Full description in
[scheduled jobs: job files](scheduled-jobs.md#job-files).

## Project file fields

A project file is `projects/<name>.md`. The file name is the canonical project
name.

| Field | Meaning |
|---|---|
| `## Working Directory` | Where the agent runs, for example `` `~/Projects/demo/` ``. |
| `## Aliases` | Bullets of other spellings of the name. All share the project lock. |
| `## Instructions` | Path of an instruction file pasted into prompts. `## CLAUDE.md` is the legacy spelling. See [configuration](configuration.md#referenced-project-instructions). |
| `## Relationships` | Other projects a follow-up suggestion may target (see below). |
| `## Automation: auto` | Lets this project's `template` jobs skip the review gate. See [scheduled jobs](scheduled-jobs.md#the-review-gate-and-its-one-exception). |
| `## Isolation: worktree` | One git worktree per brief. Absent or `shared`: the normal shared tree. |
| `## Base Branch`, `## Container Path`, `## Worktree Setup` | Worktree settings. See [worktrees](worktrees.md). |

`## Relationships` lists one target per bullet, as `verb → project: note`
(`->` also works):

```markdown
## Relationships

- mirror → demo-admin: the rewrite of the same domain.
- content → docs-site: a user-facing feature may warrant a matching page.
```

`mirror` means a code task in the target, `content` a writing task; any verb is
accepted and becomes the stub's `kind:`. Only the target is checked. `(none)`
means same-project suggestions only.

## Offline tests

No API calls, no real tasks:

```sh
python3 -m unittest discover -s tests -v   # codex provider, operator routes, brief criteria, dashboard, picker
bash tests/test_criteria_lint.sh           # the criteria lint
bash tests/test_worktree.sh                # worktree helpers
bash tests/test_history.sh                 # ai-history
bash tests/test_agents_view.sh             # dtask AGENTS section
bash tests/test_ask.sh                     # ai-ask
```
