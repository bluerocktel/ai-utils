# Configuration

Every `ai-*` script reads one `config` file that sits beside the scripts. This
page lists every key, then explains runners, split grading and referenced
project instructions.

Paths on this page such as `~/tasks/` and `~/Scripts/ai-utils/` are examples:
use wherever you put the task tree and the clone.

## The config file

```sh
cd ~/Scripts/ai-utils
cp config.example config      # config is gitignored; config.example is the template
$EDITOR config                # at least set default_runner=
```

- It is sourced as shell `key=value`.
- Every key is optional except `default_runner`, and every key has a built-in
  default, so a nearly empty `config` still runs.
- `TASKS_DIR` is not a config key: it is an environment variable, default
  `~/tasks`. Every script honours it, which is how you keep a test run off your
  real tree: `TASKS_DIR=/tmp/ai-utils-smoke ./ai-task --runner claude`.
- Sections in a task file override config where they overlap. See
  [task file fields](reference.md#task-file-fields).

## Keys

### Running tasks

| Key | Default | What it controls | More |
|---|---|---|---|
| `default_runner` | `claude` in the template, no built-in | The runner a task with no `## Runner` section runs under. Must match a provider file, `providers/<runner>.sh`. There is no "any runner" value: with this unset and no `## Runner` on the task, the task is reported as unroutable rather than guessed. | [Runners](#runners-and-providers) |
| `default_model` | unset | Model used when a task has no `## Model` section. Unset means the provider decides, and providers differ on what that means: see `ai_model_alias` in [the provider contract](../providers/CONTRACT.md). | |
| `max_retries` | `3` | Evaluation FAILs a task may collect before it moves to `review/`. Deferrals do not count. | [reference: outcomes](reference.md#outcomes) |
| `auth_cooldown_min` | `30` | Minutes a runner's unattended queue pauses after an auth failure. The marker is `$TASKS_DIR/.auth-cooldown-<runner>`, per runner: a 401 on one provider never pauses another. Naming a task file explicitly bypasses the pause. | [reference: locks](reference.md#locks-and-markers) |
| `task_timeout_min` | `45` | Wall-clock cap on the main agent run of one task. An overrun (exit `124`) is a deferral and burns no retry. | |
| `project_lock_wait_min` | `60` | How long a task waits for `$TASKS_DIR/.locks/<project>.lock`. The lock is shared by all runners. A timeout is a deferral, not a failure. | [reference: locks](reference.md#locks-and-markers) |
| `precondition_timeout_sec` | `30` | Cap per `## Precondition` command. A timeout counts as not met: the task keeps waiting in `inbox/`, no retry burned. Checks run before the inbox lock is taken, so a slow one never stalls another launcher. | [reference: preconditions](reference.md#preconditions) |
| `review_proposals` | `1` | When grading sends a task to `review/`, start `ai-propose` to draft the fix. One agent call on the task's runner, detached, never applied by itself. `0` turns it off. | [reviewing tasks](reviewing-tasks.md#fix-proposals) |
| `propose_timeout_min` | `10` | Cap on that call. A timeout writes no proposal and changes nothing else. | |
| `brief_timeout_min` | `45` | Cap on one `ai-brief` decomposition run, repair pass included. A timeout puts the brief back in `briefs/`. | [reference: ai-brief](reference.md#ai-brief-and-ai-briefs) |

### Grading

| Key | Default | What it controls | More |
|---|---|---|---|
| `test_timeout_min` | `20` | Cap per `## Test Command` line in `ai-eval`. A timeout is exit `4`: inconclusive, no retry burned, queue not paused. Fractions work (`0.05`), so a test config can cap tests at a few seconds. | [reference: test commands](reference.md#test-commands) |
| `eval_runner` | unset | Runner that grades a finished task. Unset: the runner that did the work grades it. | [Split grading](#split-grading) |
| `eval_model` | unset | Model the grader uses. Ranks above the task's `## Model`. Unset: the task's `## Model`, then `default_model`. | [Split grading](#split-grading) |
| `eval_timeout_min` | unset | Cap on the grader's own agent call. Unset: `task_timeout_min`, then a built-in `45`. Set it only to make grading time out sooner than the work. | |

### Follow-up suggestions

| Key | Default | What it controls | More |
|---|---|---|---|
| `suggest_enabled` | `1` | After a task passes, `ai-task` proposes follow-up task stubs into `suggestions/`. `0` turns the extra call off. Nothing in `suggestions/` runs until you move it into `inbox/`. | [Suggestions](#follow-up-suggestions) |
| `suggest_max` | `3` | Most stubs written per task. A stub may only target the task's own project or one listed under its `## Relationships`; this is enforced when the stub is written. | [reference: project fields](reference.md#project-file-fields) |

### Recurring jobs (`ai-scheduled`)

| Key | Default | What it controls | More |
|---|---|---|---|
| `scheduled_enabled` | `1` | Master switch. `0` stops every recurring job without touching cron or the job files. | [scheduled jobs](scheduled-jobs.md) |
| `scheduled_timeout_min` | `30` | Cap on one `monitor` or `planner` run. `template` makes no agent call and ignores it. | [scheduled jobs: kinds](scheduled-jobs.md#kinds) |
| `plan_ahead_max` | `5` | Most stubs one `planner` run may write. Dropped stubs are logged. | [scheduled jobs: kinds](scheduled-jobs.md#kinds) |
| `brain_root` | `$HOME/Brain` | Root of the notes folder where a `monitor` writes its dated reports (a journal folder under this root). | [scheduled jobs: kinds](scheduled-jobs.md#kinds) |

### Project history (`ai-history`)

| Key | Default | What it controls | More |
|---|---|---|---|
| `history_runner` | unset | Runner that writes the WHERE THINGS STAND paragraph of `ai-history PROJECT`. Unset: `default_runner`. The paragraph is cached in `$TASKS_DIR/.history/<project>.md` and rewritten only when the project's tasks change. An auth failure shows the previous paragraph as stale and pauses nothing. | [reference: scripts](reference.md#scripts) |
| `history_model` | unset | Model for that paragraph. Unset: the CLI's own default model, not `default_model`. A small model is enough. | |

### Asking an agent (`ai-ask`)

| Key | Default | What it controls | More |
|---|---|---|---|
| `ask_runner` | unset | Runner that answers `ai-ask AGENT "question"`. Unset: `default_runner`. One call per question; nothing is written. An auth failure is reported and pauses nothing. | [reference: ai-ask](reference.md#ai-ask) |
| `ask_model` | unset | Model for those answers. Unset: the CLI's own default model. | |

### Agent layer

| Key | Default | What it controls | More |
|---|---|---|---|
| `agents_root` | unset | Folder holding agent charters and routine files. Unset: this repository's `agents/`. Point it at a private repository to keep your definitions out of this public one. Only `ai-agent`, `dtask` and `ai-ask` read it. Set but not a directory: a warning and an empty listing, never a fallback. | [where definitions live](scheduled-jobs.md#where-definitions-live) |
| `agent_memory_lines` | `40` | Lines of a routine's memory ledger fed back into its prompt, and the size the ledger is trimmed to. A non-numeric or zero value falls back to `40`. Only jobs with `## Agent` have a ledger. | [memory ledger](scheduled-jobs.md#the-memory-ledger) |
| `agent_mail_to` | unset | The only recipient of a routine's `===MESSAGE===` blocks: you. Unset disables the message route. | [operator routes](scheduled-jobs.md#operator-routes) |
| `agent_mail_reply_to` | unset | Reply-To on those messages. Give it its own address so replies can be filtered and read back by the routine. | [operator routes](scheduled-jobs.md#operator-routes) |
| `agent_mail_cmd` | `s-nail` | Mail command, called with s-nail syntax (`-s SUBJECT`, `-S reply-to=ADDR`, `-.`). A non-zero exit makes the run inconclusive. The sender is the command's own configured `from`. | [operator routes](scheduled-jobs.md#operator-routes) |
| `agent_messages_max` | `3` | Most messages one routine run may send. Extras are dropped and logged. | [operator routes](scheduled-jobs.md#operator-routes) |
| `agent_briefs_max` | `2` | Most briefs one routine run may write. Extras are dropped and logged. | [operator routes](scheduled-jobs.md#operator-routes) |

## Runners and providers

A **runner** is a name such as `claude`, `grok` or `codex`. Each runner is one
file, `providers/<runner>.sh`, implementing six functions. See
[providers/CONTRACT.md](../providers/CONTRACT.md) to add one.

The runner a task runs under is resolved in this order:

1. `--runner NAME` on the `ai-task` command line;
2. the task's own `## Runner` section;
3. `default_runner` from `config`.

An empty `## Runner`, or the literal `any`, means `default_runner`. A runner
whose provider file is missing is refused, never replaced by another.

To route one task, add the section to the task file:

```markdown
## Runner
codex
```

Scheduled jobs use the inline form, `## Runner: codex`.

### Codex runner

`providers/codex.sh` drives `codex exec --json`. It needs no SDK and no new
runtime dependency. The adapter's flags were checked against `codex-cli
0.154.0`.

```sh
codex --version
codex login
```

- `codex`, `jq` and `timeout` must be on the `PATH` that cron and tmux see.
- To make it the default, set `default_runner=codex`. Keep your current default
  if existing jobs depend on another CLI's tools: Codex uses its own MCP
  servers and skills.
- Leave `## Model` and `default_model` unset to use Codex's configured model,
  or give an exact model ID your installation accepts. Model strings pass
  through unchanged; another provider's aliases are not translated.
- For cross-provider grading with `eval_runner=codex`, set `eval_model` to a
  Codex model ID, otherwise the grader inherits the task's model, which may be
  another provider's alias.
- Like the other providers, it runs without interactive approvals: it passes
  `--dangerously-bypass-approvals-and-sandbox`, which also disables Codex's
  sandbox. It works in folders outside Git.
- Raw captures stay JSONL. Only the last agent message of a completed turn
  becomes the result; interrupted progress messages are not reports.
- Usage reports input, output and cached input tokens. Model name and dollar
  cost are marked unavailable, because the completion event does not report
  them.

See the [official non-interactive documentation](https://developers.openai.com/codex/noninteractive/)
for the event format. The offline tests are listed in
[reference: tests](reference.md#offline-tests).

## Split grading

By default the runner that did the work also grades it. Set `eval_runner` to
another provider to get a second opinion whose mistakes are independent of the
executor's.

```sh
# config
eval_runner=codex
eval_model=<a model id that runner accepts>
```

How `ai-eval` picks its runner and model:

| | Runner | Model |
|---|---|---|
| 1 | `--runner` | `--model` |
| 2 | `AI_RUNNER` (exported by `ai-task`: who executed) | `eval_model` |
| 3 | `eval_runner` from `config` | the task's `## Model` |
| 4 | `default_runner` | `default_model` |

- `ai-task` always passes `--runner`, so in the automatic path the grader is
  `eval_runner` when set, else the executing runner. A hand-run `ai-eval` with
  no flags still picks up `eval_runner`.
- `eval_model` ranks above the task's `## Model`: `## Model` is what the work
  needs, and grading is a smaller job.
- `## Test Command` runs before the grader is called, so objective failures
  never cost a grading call.
- Keep the grader fixed rather than alternating, so verdicts stay comparable
  from one attempt to the next.
- A grader runner that cannot be loaded exits `3` (inconclusive), not `1`, so a
  missing adapter never burns retries across the queue.
- A cross-provider FAIL costs a retry like any other.

### When the grader hits an auth failure

If the work finished but the grader could not log in:

1. the report is already in `done/`;
2. the **grader's** runner is paused (its cooldown marker), never the
   executor's;
3. the task goes back to `inbox/` with this section, naming the report:

```markdown
## Awaiting-Eval
2026-08-25_18-33_my-task.md
```

On the next claim `ai-task` skips the work and only grades that report. No
retry is burned.

- The archived pair keeps the report's original timestamp, so
  `<ts>_<task>.md` and `<ts>_<task>.task.md` still match.
- If the named report is gone, the section is removed, the reason is printed,
  and the task runs normally.
- The picker skips such a task while its grader is in cooldown, so one task
  waiting on a paused grader cannot block the queue behind it.

If no `ai-eval` is installed at all, `ai-task` records the run as ungraded, not
failed.

## Follow-up suggestions

When a task passes, `ai-task` makes one more agent call that may propose
follow-up task stubs into `suggestions/`, then archives the task.

- It reads the task file and its report, never a git diff (a diff would include
  other tasks' changes).
- `suggestions/` is its only destination. Nothing there runs until you move it
  into `inbox/`.
- `NONE` or an empty answer is normal and writes nothing. A suggester that
  fails or times out never keeps a passing task out of `done/`.
- At most `suggest_max` stubs per task. A stub may target the task's own
  project, or a project listed in that project's `## Relationships` (see
  [project file fields](reference.md#project-file-fields)). Anything else, or a
  project with no file in `projects/`, is refused and logged.
- A task with no `## Project` gets no suggestions. A slug that already exists
  anywhere in the pipeline is skipped.

Reading and promoting suggestions is covered in the reviewing guide.

## Referenced project instructions

A project file can point at an instruction file (for example the repository's
own agent notes). `ai-task`, `ai-brief` and the agent part of `ai-eval` paste
its contents into their prompts, so it works for every runner, including ones
that do not discover such files on their own.

```markdown
## Instructions
`~/Scripts/example/AGENTS.md`
```

- The legacy heading `## CLAUDE.md` is also read. `## Instructions` wins when
  both are present.
- Put one path on the first non-empty line. Absolute paths, `~/` paths and
  paths relative to the project file's folder all work, including spaces and
  surrounding backticks.
- Shell expressions and environment variables are not evaluated. The file is
  included as-is; references inside it are not followed.
- No reference: nothing is added. A reference to a file that cannot be read:
  a warning on stderr and a visible "missing context" notice in the prompt; the
  run continues and is told to report it.
- The evaluator's test-only paths are unchanged.
