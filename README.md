# ai-utils

Provider-agnostic autonomous task pipeline. Unifies `claude-utils` and `grok-utils`.

One `~/tasks/` tree serves every runner: the runner is a field on the task
(`## Runner`), not a separate directory tree. Anything vendor-specific lives in
`providers/<runner>.sh` behind the six-function contract in
`providers/CONTRACT.md`; nothing outside `providers/` may name a vendor.

See `~/tasks/projects/ai-utils.md` for scope and boundaries, `CLAUDE.md` for the
repo's working notes, and `providers/CONTRACT.md` for the provider contract.

## The pipeline

```
   briefs/                        a loose, high-level feature brief
      │
      │  ai-brief / ai-briefs     one agent call decomposes it into a chain
      ▼
   backlog-for-review/            structured tasks, each stamped ## Runner
      │
      │  ═══ HUMAN REVIEW ═══     you read them and move the good ones by hand
      ▼                           (ai-brief has NO write path into inbox/)
   inbox/                         ready to run
      │
      │  ai-task                  claims the oldest eligible task for its runner,
      ▼                           atomically, under .locks/inbox.lock
   run/                           in flight, with a <task>.state sidecar
      │
      │  providers/<runner>.sh    one headless agent call, in a detached tmux
      │  ai-eval                  grades it against ## Acceptance Criteria,
      ▼                           after running any ## Test Command
   ┌──────────── verdict ────────────┐
   │                                 │
  PASS                             FAIL
   │                                 │
   ▼                    ┌────────────┴────────────┐
 done/               retries left            max_retries
 + DONE.md               │                        │
                         ▼                        ▼
                     inbox/                   review/
                  (with evaluator          (parked for you;
                   feedback appended)       burns no further work)
```

Deferrals (auth failure, project lock timeout, interrupt, timeout, empty
result) requeue to `inbox/` **unchanged** and burn **no** retry. Only a real
FAIL verdict costs a retry.

`dtask` renders this whole picture, read-only, across every runner.

Everything above is the **pull** side: work happens only because a file is
sitting in `inbox/`. `ai-scheduled` is the **push** side, and it feeds the same
queues rather than a parallel universe of its own:

```
   scheduled/*.md                 recurring job definitions
      │
      │  ai-scheduled             cron fires it often; it decides what is due
      │
      ├── kind: template ────────▶ backlog-for-review/   (then the human gate,
      │                                                   exactly as a brief)
      ├── kind: monitor ─────────▶ <brain_root>/personal/journal/  on a signal
      │                            + suggestions/        one follow-up stub
      └── kind: planner ─────────▶ suggestions/          a ranked set of stubs
```

`suggestions/` is a reading pile, not a queue: nothing there runs until you move
it into `inbox/` yourself.

## Scripts

| Script | Symlink as | What it does |
|---|---|---|
| `init` | `ai-init` | create the pipeline tree under `TASKS_DIR`. Idempotent, additive only. |
| `ai-task` | `ai-task` | claim one queued task, run it, evaluate it, archive it. |
| `ai-eval` | `ai-eval` | grade one finished task. Exit code is the interface. |
| `ai-brief` | `ai-brief` | decompose one brief into a chain of tasks, into the review queue. |
| `ai-briefs` | `ai-briefs` | fan out `ai-brief` over every brief in `briefs/`. |
| `ai-scheduled` | `ai-scheduled` | the push side: dispatch the recurring jobs in `scheduled/` that are due. |
| `ai-agent` | `ai-agent` | read-only view of the agent layer: list, show, validate, and print the publish plan. Reads the definitions root resolved from `agents_root`. Writes nothing, so it is safe against the live tree. |
| `dtask` | `dtask` | read-only dashboard across every runner. It owns the bare name as of 2026-08-25; see Step 3 under Cutover. |
| `lib.sh` | — | shared helpers, sourced. Provider-neutral by contract. |
| `providers/<runner>.sh` | — | the only files allowed to name a vendor. |

Requires `bash`, `tmux`, `jq`, `flock`, `timeout`, plus each provider's CLI on
`PATH`.

## Setup

```sh
./init                      # create the pipeline tree under ~/tasks
TASKS_DIR=/tmp/t ./init     # or a throwaway tree for smoke tests
cp config.example config    # then set default_runner=
```

`TASKS_DIR` defaults to `~/tasks`. Every script honours an override, which is
how a smoke run is kept off the live tree:

```sh
TASKS_DIR=/tmp/ai-utils-smoke ./ai-task --runner claude
```

## Configuration

`config` lives beside the scripts and is sourced as shell `key=value`. It is
gitignored; `config.example` is the tracked template. Every key below is
optional except `default_runner`, and every one has a built-in default, so an
empty `config` still runs.

| Key | Default | What it controls |
|---|---|---|
| `default_runner` | `claude` (in the template; no built-in) | The runner a task with no `## Runner` section runs under. Must match a provider file name, `providers/<runner>.sh`. **There is no "any runner" value.** With this unset *and* a task carrying no `## Runner`, `runner_from_task` fails rather than guessing, and the task is reported as unroutable. |
| `max_retries` | `3` | Evaluation FAILs a task may accumulate before it moves to `review/`. Deferrals do not count. |
| `auth_cooldown_min` | `30` | Minutes the launcher pauses a runner's unattended queue after an auth failure. The marker is `$TASKS_DIR/.auth-cooldown-<runner>`, **per runner**: a 401 on one provider never pauses another's queue. An explicit task argument bypasses the pause. |
| `task_timeout_min` | `45` | Hard wall-clock cap on the main headless run per task. An overrun is exit `124`, which defers without burning a retry. |
| `project_lock_wait_min` | `60` | How long a task waits for `$TASKS_DIR/.locks/<project>.lock`. The lock is **shared across runners**. A wait timeout is a deferral, not a failure. |
| `test_timeout_min` | `20` | Per-command cap on each `## Test Command` line in `ai-eval`. A timeout is exit `4`: inconclusive, no retry burned, queue **not** paused. Accepts a fractional minute (`0.05`) so a throwaway config can cap tests at a few seconds. |
| `brief_timeout_min` | `45` | Hard cap on an `ai-brief` decomposition run. A timeout restores the brief to `briefs/`. |
| `default_model` | unset (commented out) | Model used when a task has no `## Model` section. Unset means the provider decides, and providers differ on what "unset" means: see `ai_model_alias` in `providers/CONTRACT.md`. |
| `eval_runner` | unset (commented out) | Runner that **grades** a finished task. Unset means the task is graded by the runner that executed it. Setting it to a *different provider* is the point: a grader that shares the executor's training shares its blind spots. An auth failure on this runner pauses **this** runner and requeues the task with `## Awaiting-Eval`, so finished work is graded later rather than executed again. |
| `eval_model` | unset (commented out) | Model the grader uses. Sits **above** the task's own `## Model`, because `## Model` says what it takes to *do* the work and grading is a smaller job. Unset, the grader falls back to the task's `## Model`, then `default_model`. |
| `scheduled_enabled` | `1` | Master switch for `ai-scheduled`. `0` disables every recurring job without touching cron or the job files. |
| `scheduled_timeout_min` | `30` | Hard cap on one agentic scheduled run (`monitor` or `planner`). The `template` kind makes no agent call and ignores it. |
| `plan_ahead_max` | `5` | Cap on suggestion stubs one `planner` run may write. A run that hits the cap logs what it dropped. |
| `agent_memory_lines` | `40` | How many lines of an agent routine's memory ledger (`scheduled/.state/<slug>.memory.md`) are fed back into its prompt, and the length the ledger is trimmed to after each conclusive run. Bounded on purpose: an unbounded ledger grows the prompt until the routine can no longer see its own recent history. Only a job carrying `## Agent` has a memory; a plain job ignores this. |
| `agents_root` | unset (commented out) | Root holding the agent-layer **definitions**, the charters and routine files. Unset means this repository's own `agents/`. Point it at a separate repository to keep definitions out of this one: this repository is public, and a charter names a real business domain. Only `ai-agent` and `dtask` read it; the engine runs the *published* copy in `scheduled/`, so it is never consulted during a run. Set but not a directory warns and lists nothing, never a silent fallback to `agents/`. |
| `brain_root` | `$HOME/Brain` | Root of the notes tree a `monitor` writes dated reports into (`<brain_root>/personal/journal/`). |
| `eval_timeout_min` | unset (commented out) | Cap on the evaluator's own agent call. Unset, it inherits `task_timeout_min`, then a built-in `45`, because grading is the same kind of headless call as the work. Set it only to make grading time out sooner than the task it grades. |

Per-task sections override config where they overlap: `## Runner`, `## Model`,
`## Project`, `## Depends-on`, `## Test Command`, `## Acceptance Criteria`.

## `ai-task`

Runs one queued task autonomously in a detached tmux session, evaluates the
result, and either archives it to `done/`, requeues it to `inbox/`, or parks it
in `review/`.

```sh
ai-task                          # pick the oldest eligible inbox task for the default runner
ai-task --runner grok            # ... acting as a specific runner
ai-task path/to/task.md          # run one named file (skips the queue filter)
ai-task --runner grok --dry-run  # show what would be claimed; claims nothing, launches nothing
ai-task --run FILE               # internal mode used by tmux; do not call directly
```

### The `--runner` flag

`--runner NAME` sets the runner this invocation *acts as*. It must match a
provider file name (`providers/NAME.sh`). Without the flag, the invocation acts
as `default_runner` from `config`.

Resolution order for the runner a task actually runs under:

1. `--runner NAME`, when given
2. the task's own `## Runner` section
3. `default_runner` from `config`

An unset `## Runner` means `default_runner`, never "any runner". The tmux
session name embeds the runner (`ai-<runner>-<task>`), so two runners polling
the same tree can never collide on a session name.

### New behaviour 1: runner filtering in the picker

The queue picker now selects the oldest inbox task that is unblocked **and**
whose resolved runner matches this invocation's runner. A task belonging to
another runner is left in the inbox untouched, never picked up and never
silently retargeted; the "nothing runnable" report lists those separately so a
misfiled `## Runner` is visible rather than mysterious.

Naming a task file explicitly bypasses the filter: an explicit path is a direct
instruction, not a queue-picking decision.

### New behaviour 2: atomic inbox claim

Selecting a candidate and moving it to `run/` happens under an exclusive
`flock` on `$TASKS_DIR/.locks/inbox.lock`. Previously the select and the `mv`
were separate unguarded steps, so two invocations could both select the same
file and both proceed to run it. With one runner on one cron interval that was
merely unlikely; with two runners polling one inbox on different intervals it
would become routine.

The lock covers **only** select + move + state marker and is released when the
claim subshell exits (`ai-task:679-682`), long before the agent call
(`ai-task:254`, reached in the separate `--run` process launched at
`ai-task:790`). It is held for milliseconds and never serialises real work.

### Locks and markers

| Lock / marker | Path | Scope |
|---|---|---|
| Inbox claim | `$TASKS_DIR/.locks/inbox.lock` | shared; held for milliseconds |
| Per-project | `$TASKS_DIR/.locks/<project>.lock` | **shared across runners** on purpose: two agents must never be inside the same repo at once. A wait timeout is DEFERRED, not a failure, and burns no retry. |
| Auth cooldown | `$TASKS_DIR/.auth-cooldown-<runner>` | **per runner**: a 401 on one provider never pauses another provider's queue. An **evaluator** auth failure touches the marker of the runner that was *grading*, which with `eval_runner` set is not the runner that executed. |

### Outcomes

| Situation | Outcome | Retry burned |
|---|---|---|
| Evaluation passes | archived to `done/` | — |
| Evaluation fails, retries left | requeued to `inbox/` with evaluator feedback; a strategy pass is appended from the second failure on | yes |
| Evaluation fails, `max_retries` reached | moved to `review/` | — |
| Auth failure during the run | requeued to `inbox/`, cooldown marker touched for the **executing** runner | **no** |
| Auth failure while **grading** | requeued to `inbox/` with `## Awaiting-Eval`; cooldown touched for the **grading** runner | **no** |
| Project lock wait times out | requeued to `inbox/` | **no** |
| Run killed, timed out, or produced no parseable text | requeued to `inbox/` | **no** |

Every `DONE.md` entry carries a `**Runner:**` line, plus a `**Graded by:**`
line whenever the grader differs from the executor — without it the log cannot
explain a verdict. An in-flight task gets a `run/<task>.state` sidecar naming
its runner and tmux session, so a unified tree stays readable. The sidecar is
removed when the run ends.

### `## Awaiting-Eval`: never execute finished work twice

A task carries this section in exactly one situation: its work **completed**,
the report was written to `done/`, and then grading could not happen because
the grader hit an auth failure. The value is the report's basename.

```markdown
## Awaiting-Eval
2026-08-25_18-33_my-task.md
```

On the next claim, `ai-task` sees the section, finds that report, **skips the
whole work phase**, and goes straight to grading. Without this, a grader outage
would silently convert a finished run into a full re-run, which is the one
thing that would make a separate `eval_runner` cost more than it is worth.

Three details that make it safe:

* **The archived pair keeps its original timestamp.** The resume reuses the
  report's prefix so `<ts>_<task>.md` and `<ts>_<task>.task.md` still match; a
  fresh timestamp would split the pair and break the `*_<slug>.task.md` lookups
  that `slug_exists` and `locate_dep_slug` depend on.
* **A dangling pointer never wedges a task.** If the named report is gone, the
  section is stripped, the reason is printed, and the task runs normally.
* **The picker skips such a task while its grader is in cooldown.** This is a
  starvation guard, not an optimisation: the picker returns the *first* eligible
  task and a grade-only resume defers again within seconds, so without the check
  one task waiting on a down judge would be claimed every sweep and nothing
  behind it would ever run.

No retry is burned on this path: it is the continuation of a deferral.

`ai-task` degrades gracefully when no `ai-eval` is installed yet: the run is
recorded ungraded rather than failed.

## `ai-eval`

Grades one finished task against its `## Acceptance Criteria`, after first
running any `## Test Command` in the task file.

```sh
ai-eval TASK_FILE RESULT_FILE                 # verdict on stdout
ai-eval TASK_FILE RESULT_FILE verdict.md      # verdict written to a file
ai-eval --runner grok TASK_FILE RESULT_FILE   # grade with a specific runner
```

### Exit codes

The exit code is the whole interface: `ai-task` branches on every one of these
to decide whether the attempt burns a retry, so none of them may be renumbered.

| Code | Meaning | Burns a retry |
|---|---|---|
| `0` | PASS | — |
| `1` | FAIL (a `## Test Command` failed, or the evaluator returned `VERDICT: FAIL`) | yes |
| `2` | Nothing to grade: no `## Acceptance Criteria` and no passing `## Test Command`. Also covers a usage error and a missing task or result file, so a bad invocation is never read as a failed task. `ai-task` treats it as "the run stands, ungraded". | — |
| `3` | Inconclusive: evaluator auth failure, or an empty verdict. **No** retry burned; `ai-task` requeues the task and touches that runner's cooldown marker. | **no** |
| `4` | Inconclusive: a `## Test Command` timed out. **No** retry burned and the queue is **not** paused, because a slow test says nothing about credentials. | **no** |

A passing `## Test Command` with no `## Acceptance Criteria` is a `0`, not a
`2`: tests alone can carry a PASS.

Exit `3` never emits a verdict line. An empty evaluator response is inconclusive,
not a FAIL, and any partial text is reported with its `VERDICT:` lines stripped
so the caller's grep cannot mistake a half-finished run for a decision.

### Test commands

Every line under `## Test Command` runs in order under
`timeout $((test_timeout_min * 60))`, and the first non-zero exit stops the
sequence and produces the FAIL. Fence lines are skipped. A trailing backslash
continues a command onto the next line, and the pieces are assembled into **one**
command before running, so

```
cd some/repo && \
make check
```

runs as a single shell with the `cd` still in effect, rather than as two
unrelated commands. `test_timeout_min` accepts a fractional minute (`0.05`) so a
throwaway config can cap tests at a few seconds.

### The evaluator's stance

The prompt is deliberately hostile: be critical, give no benefit of the doubt,
an unverifiable criterion is a FAIL, no praise, and tools may be used to check
claims rather than taking the result report's word for it.

It also requires each criterion to be graded **as written**, not as charitably
reinterpreted. A criterion that names a specific file, path, command, service,
table, flag or value means that exact thing: an agent that quietly substituted
an equivalent-looking one and reported success has failed the criterion, however
well the substitute works. This is the check that catches the most expensive
class of false success, where the work is real but not the work that was asked
for.

### The `--runner` flag

`--runner NAME` chooses the runner that *grades*, independently of the runner
the task *ran* on. Resolution order:

| | Runner | Model |
|---|---|---|
| 1 | `--runner` | `--model` |
| 2 | `AI_RUNNER` (exported by `ai-task`; records who **executed**) | `eval_model` |
| 3 | `eval_runner` from `config` | the task's `## Model` |
| 4 | `default_runner` | `default_model` |

`ai-task` passes `--runner` explicitly, so in the automated path the grader is
`eval_runner` when set and the executing runner otherwise. A hand-run `ai-eval`
with no flags still picks up `eval_runner` on its own.

The model order is deliberately *not* the same as the runner order:
`eval_model` outranks the task's `## Model` because `## Model` is a statement
about what it takes to **do** the work, while grading means reading the
criteria, reading the report, and weighing the `## Test Command` output.
Inheriting the executor's model priced every verdict at the cost of the work.

**Why a different provider is worth it:** the value of a second opinion is that
its failure modes are independent. A grader sharing the executor's training
shares its blind spots — a hallucinated path, a test that asserts nothing, a
confident "done" for work that isn't. There is deliberately no logic that adapts
the prompt to a cross-runner pairing: the prompt grades a report against
acceptance criteria, which is provider-neutral.

A cross-provider FAIL costs a retry like any other, and a stricter judge
therefore costs real money in re-runs. Two things bound that: `## Test Command`
runs **before** the grading call, so objective failures never reach the judge;
and the judge should stay fixed rather than alternating, so verdicts remain
comparable across attempts.

A runner that cannot be loaded exits `3`, not `1`: a missing adapter is a
configuration fault, and burning a retry on every task in the queue for it
would be the worse failure.

The evaluator's own agent call goes through `ai_run` / `ai_json_text` /
`ai_is_auth_failure`; no vendor CLI or JSON field is named outside
`providers/`.

## `ai-brief` / `ai-briefs`

Decomposes one high-level brief into several well-scoped task files. This is
the entry point actually used day to day.

```sh
ai-brief                             # oldest brief in briefs/
ai-brief briefs/my-feature.md        # a named brief
ai-brief --runner NAME               # decompose with a specific runner
ai-briefs                            # fan out over every brief in briefs/
ai-brief --run FILE                  # internal mode used by tmux; do not call directly
```

`ai-briefs` launches one detached tmux session per brief, all in parallel. An
empty `briefs/` directory exits `0` and prints nothing, so it is safe on a
timer.

### The flow, and the review gate

```
briefs/ → ai-brief → backlog-for-review/ → (HUMAN REVIEW) → inbox/ → ai-task
```

**The human review gate is the single most important property of the pipeline,
and `ai-brief` never bypasses it.** Emitted tasks land in
`backlog-for-review/` and stop there. Nothing runs until a human reads a task
and moves it into `inbox/` by hand.

`ai-brief` has no write path into `inbox/` at all:

* The only directory it ever writes task files to is `$BACKLOG_REVIEW_DIR`
  (`ai-brief:443`); `inbox/` is deliberately absent even from the `mkdir -p`
  list at `ai-brief:232`.
* The extraction step strips every path component off the model-proposed
  filename and then reduces it to `[A-Za-z0-9._-]`, so no agent output can
  steer a write out of the review queue, whatever it emits as a filename.
* `$INBOX` appears in this script only inside the closing message that tells
  the human where to move a task they have approved.

The brief itself is archived to `briefs/done/` on success and restored to
`briefs/` on every failure path (timeout, empty output, no task blocks, invalid
graph, auth failure), so a failed decomposition is always retryable and never
loses the brief.

### `## Runner` on every emitted task

Every emitted task file carries an explicit `## Runner` section naming the
runner that will execute it. It is stamped by `ai-brief` after extraction
(`ai-brief:497`), not left to the model: routing that depends on the model
having remembered to write a section is routing that silently regresses. A
`## Runner` the model wrote itself is discarded and replaced.

Resolution order for the stamped value:

1. a `## Runner` section in the **source brief**, when present
2. the `--runner NAME` flag
3. `default_runner` from `config`

The brief wins because a brief decomposed by one runner is often meant for
another, and because an implicit runner makes the eventual routing invisible to
the human reviewing the batch. So the two runners in play are separate on
purpose:

| | resolved from |
|---|---|
| the runner that **decomposes** now | `--runner`, else `default_runner` |
| the runner **stamped** on the batch | brief's `## Runner`, else `--runner`, else `default_runner` |

The stamp target is validated against `providers/<runner>.sh` *before* the
agent call: a stamp naming a provider that does not exist would produce a whole
batch of tasks no `ai-task` invocation can ever claim, and the failure would
otherwise only surface after the human review pass. The run also asserts that
the stamp landed on every file in the batch and rolls the batch back if it did
not.

### Acceptance criteria must be scoped to the task

The decomposition prompt forbids a class of criterion that reads as rigorous and
is actually unpassable. Three rules, all learned from one task that burned every
retry it had:

| Don't write | Write instead |
|---|---|
| `Item::count() == 439 + 143` (a measured baseline plus a predicted delta) | `142 rows carrying marker M exist` |
| `no duplicate X anywhere` (a global invariant the task does not own) | `no duplicate X among the rows this task created` |
| `re-run leaves count at 582` (idempotency restated as an absolute) | `a second run creates nothing new (created-count 0)` |

Both halves of a baseline-plus-delta criterion are unsafe. The **baseline moves**
if anything else touches the data between decomposition and execution, and the
**delta is a guess** exploration cannot fully verify — in the case that prompted
this rule, two product labels differing only in one letter's case folded into a
single row under a case-insensitive collation, so 143 new items were only ever
going to be 142.

The failure mode is the expensive part. A criterion that cannot pass is
indistinguishable, to an autonomous retry, from a criterion that has not passed
*yet*. That task ran four times: the first attempt was correct and honest, the
second forced both numbers by creating a case-duplicate catalogue row and
hard-deleting four pre-existing rows, the third undid that damage, and the
fourth re-reported the same conflict. Three of those four runs existed only
because of the arithmetic in two lines of text.

Hence the final rule in the prompt: **if satisfying a criterion would require
changing data, files, or schema the task was not asked to touch, the criterion
is wrong.** A correct implementation must be able to pass.

The executing side is guarded too, because a bad criterion will still reach some
task eventually. `ai-task`'s autonomous preamble tells the agent that criteria
define done but are not a licence to change anything outside the task's scope:
force nothing, create no record whose only purpose is to move a count, undo any
such change a previous attempt made, and report the conflict in the `## Summary`
with the arithmetic that disproves the criterion. The strategy pass (from the
second failure on) is told to recommend **stopping** when the blocker is an
unsatisfiable criterion, naming the decision the user has to make, instead of
proposing a workaround.

The division of labour: `ai-brief` tries not to write the bad criterion,
`ai-task` refuses to do damage in service of one, and `ai-eval` still grades it
as written — so the task lands in `review/` with a precise explanation rather
than a quietly mutated database.

### One parent per task

`depends_on_from_task` reads **only the first token of the first line** under
`## Depends-on`, so a task can have exactly **one** parent. The decomposition
prompt states this rule explicitly and requires a linear chain (`A → B → C`) or
a forest of independent chains, never a join where one task depends on two
others.

This is a prompt-level constraint because nothing downstream can catch a
violation: `repair_brief_task_graph` detects cycles and a missing root, but a
join simply reads as a single dependency and the second parent is silently
discarded, and the task would then start before work it needs has finished.

### `repair_brief_task_graph`

Called on the emitted batch at `ai-brief:507`, before the brief is archived.
This is a `grok-utils` feature with no `claude-utils` equivalent, kept
deliberately.

| Graph problem | Outcome |
|---|---|
| `## Depends-on` names a slug that was never emitted | the section is **stripped**, a note names the slug, the batch still ships (return `0`) |
| a dependency cycle | **fatal**: return non-zero |
| no root (every task has a `## Depends-on`) | **fatal**: return non-zero |

A fatal graph deletes the whole emitted batch, appends the graph notes to the
debug capture in `run/`, and restores the brief. Nothing half-valid reaches the
review queue: a batch with no root would sit there looking fine and then never
start.

### Notes

`brief_timeout_min` in `config` caps the decomposition run; a timeout restores
the brief. The auth-cooldown guard and marker are per runner, exactly as in
`ai-task`. `ai_preamble_extra` is deliberately **not** appended to the
decomposition prompt (unlike `ai-task`): the provider extras describe the shape
of a *result report*, which would contradict this prompt's "output only the
delimited task blocks" contract and break extraction.

Symlinks into `~/bin/` and cron entries are a **manual** step for the user;
nothing here installs either.

## `ai-scheduled`

The push side. One cron line fires it often; the script itself decides which of
the recurring jobs in `scheduled/` are actually due, using
interval-since-last-run bookkeeping rather than cron expressions. Cron only asks
"anything to do?", so a job's schedule lives in the job file, where you can read
and change it without touching crontab.

```sh
ai-scheduled                  # evaluate every job, dispatch the due ones
ai-scheduled --job SLUG       # only that job (still honours due-ness)
ai-scheduled --force          # ignore due-ness
ai-scheduled --dry-run        # report only: no writes, no agent call, no state
ai-scheduled --runner NAME    # act as this runner for every job
```

An empty or absent `scheduled/` exits `0` and prints nothing, so it is safe on a
timer. `--dry-run` is the one invocation that is safe against the live tree,
because it writes nothing at all.

### Job files

`scheduled/<slug>.md`. The slug is the job's identity: its state, its snapshot
and its rendered task names all derive from it.

```markdown
## Kind: template | monitor | planner
## Schedule: daily | weekly | weekly-<dow> | monthly | every:<N>h
## Project: <alias>       (optional)
## Model: <alias|id>      (optional; template makes no agent call)
## Runner: <name>         (optional; unset means default_runner)

<Markdown body>
```

Headers here use the inline `## Field: value` form, unlike task files which use
`## Field` on one line and the value on the next. `field_from_task` accepts both
spellings, so either works, in a job file or a task file.

**A job file needs the `.md` extension.** `scheduled/dirty-git-trees` has none
and was skipped in silence for a month with no state marker to hint at it, so
every sweep now prints a warning for a job-shaped file the glob cannot see.

### Schedules

| Value | Due when |
|---|---|
| `daily` | ≥ 23h since the last run (not 24h: cron jitter must not turn a daily job into an alternate-day job) |
| `weekly` | ≥ 6d23h since the last run |
| `weekly-mon` … `weekly-sun` | today is that weekday and the job has not run today |
| `monthly` | the calendar month changed, or ≥ 28d elapsed |
| `every:<N>h` | ≥ N hours since the last run |

A job that has never run is due, so a new job fires on the next sweep. An
invalid or missing `## Schedule` is reported and skipped, never treated as due.

### Kinds

**`template`** — a deterministic recurring task. No agent call at all: the body
is rendered verbatim into `backlog-for-review/`, with `## Project` and a stamped
`## Runner` prepended. This is the cheap kind, and the right one whenever the
work is the same every time.

**`monitor`** — an agentic watcher. One headless call performs the watch,
compares its findings against the snapshot saved from last time, and returns a
fixed block structure (`===SNAPSHOT===`, `===SIGNAL===`, and on a signal
`===REPORT===` plus optionally `===SUGGESTION===`). On a signal it writes a
dated report into `<brain_root>/personal/journal/` and, when the job names a
`## Project`, one suggestion stub. When nothing changed it writes **nothing** but
still refreshes the snapshot. That silence is the entire value: a monitor that
reported "nothing changed" every hour would be ignored within a week.

The snapshot is refreshed on every conclusive run, signal or not, because the
diff is against the **last run**, not the last signal. Diffing against the last
signal would report a change, and then report its reversion as a second change.

**`planner`** — an agentic synthesiser. Reads recent `done/` summaries, project
files, the live queues and `review/` failures, then proposes at most
`plan_ahead_max` ranked stubs into `suggestions/`. It is told that silence is
acceptable, and `NONE` is a successful run that stamps state. Its whole purpose
is synthesis a per-task reflex cannot do: connecting several finished tasks,
advancing a roadmap, or rethinking a failure.

A stub whose slug already exists anywhere in the pipeline is skipped, so the
same idea is not proposed twice. `review/` is deliberately excluded from that
check: a task that failed evaluation is exactly what a planner should be free to
propose a fresh approach for.

### State

| File | Holds |
|---|---|
| `scheduled/.state/<slug>.run` | epoch seconds of the last **successful** dispatch |
| `scheduled/.state/<slug>.snapshot.md` | a monitor's last snapshot |

The epoch-seconds format is unchanged from the engine this replaces, so both
read and write the same markers. That is what makes the cutover a one-line cron
swap: no job re-fires because its state was reset, and none double-fires because
the other engine could not see the stamp.

**A run that did not happen never stamps state.** An auth failure, a timeout, an
empty result or a missing `===SNAPSHOT===` block all leave the marker alone, so
the job is still due on the next sweep. Only a dispatch that actually produced
its output stamps.

### The review gate, and its one exception

A `template` job renders into `backlog-for-review/` and stops there, exactly
like a brief. The exception: if the job's `## Project` file carries
`## Automation: auto`, its rendered tasks go straight to `inbox/`.

That is the only write path into `inbox/` in this repo, and it is off by default
(no project currently sets it). It is defensible here and nowhere else, because
a template body is written by a human and rendered verbatim, whereas
`ai-brief`'s output is composed by an agent. `ai-brief` has no such flag and
must never get one.

### Runners and cooldown

Resolution order for a job's runner: `--runner`, then the job's `## Runner`,
then `default_runner`. An unset section resolves to the default and never to
"any runner", identically to a task file. The runner is validated against
`providers/<runner>.sh` **before** dispatch, because a `template` job stamps
that name onto a task file and a stamp naming a provider that does not exist
produces work no `ai-task` can ever claim.

The auth cooldown is checked **per runner** (`.auth-cooldown-<runner>`): a 401
on one provider never pauses another provider's jobs. The `template` kind makes
no agent call and so ignores the cooldown entirely, and keeps running while a
runner is paused.

Each agentic job is dispatched inside a subshell, so the provider functions one
job sources cannot leak into the next job in the same sweep, which may belong to
a different runner.

### Adding a job

```sh
cat > ~/tasks/scheduled/my-job.md <<'EOF'
## Kind: template
## Schedule: weekly-mon

# Weekly dependency audit

## Tasks
1. ...

## Acceptance Criteria
- ...
EOF
ai-scheduled --dry-run --job my-job     # confirm it parses and is due
```

## The agent layer (`ai-agent`)

The pipeline is pull-based: `ai-task` claims whatever is already in `inbox/`,
and `ai-scheduled` is the push side that puts work there on a trigger. But a
job file only answers *when* something runs. Something still has to decide
**what is worth pushing at all**, and to keep deciding it week after week for
one part of the business. An **agent** owns a business domain and answers that
question for it; a **routine** is one small, explicit job the agent performs on
a trigger.

This layer adds no engine. `ai-scheduled` already owns the trigger, the three
kinds, the per-job state and the routes into the pipeline. What the agent layer
adds is vocabulary, a permission model and validation. A routine's output enters
the pipeline through the **existing** routes only, a suggestion stub into
`suggestions/` or a rendered task into `backlog-for-review/`, and from there it
is reviewed, claimed, executed, graded and retried by exactly the same machinery
as everything else. It complements the brief-to-task loop; it replaces no part
of it.

### Layout

```
agents/CONTRACT.md                          the contract: vocabulary, permissions, rules
<agents-root>/<agent>/AGENT.md              the charter: the domain this agent owns
<agents-root>/<agent>/routines/<slug>.md    one routine, one file, one job
```

Definitions live in **git**, versioned, and never in `~/tasks/`. The pipeline
tree gains no directory: a routine's only persistence is the per-job state
`ai-scheduled` already keeps under `scheduled/.state/`. A definition that lives
in git can be reviewed, diffed and reverted; one that lives in the tree cannot.

`<agents-root>` is this repository's `agents/` directory by default, or the
`agents_root` config key when definitions live in a repository of their own. See
**Where definitions live** below.

`<agent>` and `<slug>` are kebab-case, `[a-z0-9-]` only. The routine `<slug>` is
its identity everywhere: the file name here, the job file name once published,
and the key of `scheduled/.state/<slug>.run`, `<slug>.snapshot.md` and
`<slug>.memory.md`. One name, one job, one history, so a renamed routine is a
routine with no memory and renaming is a deliberate act.

### Where definitions live

This repository ships **no agents**: `agents/` holds the contract and a worked
example, nothing more.

That is deliberate. A charter names the business domain its owner actually works
in, and a routine names the paths, the reports and the obligations it reads, so
real definitions generally belong in a **private** repository while this one is
public. Point `agents_root` at it:

```sh
# ~/Scripts/ai-utils/config   (gitignored, so the path never ships here)
agents_root=$HOME/my-agents
```

Three homes, each with one reason to exist: the **engine** public in git,
**definitions** in git where they can be diffed and reverted, and **state** in
`~/tasks/`. The split is resolved by `agents_dir` in `lib.sh`, and only the two
read-only viewers ever call it, `ai-agent` and `dtask`. The engine never does:
`ai-scheduled` runs the **published copy** of a routine in `scheduled/`, so where
a definition came from cannot affect a run, and moving definitions changes
nothing about how anything executes.

An `agents_root` that is set but is not a directory warns on stderr and lists
nothing. It does **not** fall back to `agents/` here: listing, validating and
printing publish plans for the wrong set of routines is worse than an empty
listing, for the same reason `load_provider` refuses an unknown runner instead
of defaulting to one.

Two properties do not survive the split, and both are worth knowing. A revert in
the definitions repository restores a routine's instructions but not its state,
so it is not a rollback of what the routine believes about its own past runs. And
`ai-agent --validate` reads the definitions while the engine runs the published
copy, so a routine edited in place in `scheduled/` is no longer the file that was
validated.

### The charter, `<agents-root>/<agent>/AGENT.md`

```markdown
## Domain: <one line: the business domain this agent owns>
## Sources: <comma-separated internal sources its routines may read>
## Permission-Ceiling: read | propose | act

<Markdown body>
```

| Header | Value |
|---|---|
| `## Domain:` | one line: the business domain this agent owns |
| `## Sources:` | comma-separated internal sources its routines may read, e.g. `email, crm, support-tickets, repositories, pipeline-state` |
| `## Permission-Ceiling:` | `read` \| `propose` \| `act`: the highest permission any of its routines may declare |

The body is prose: what the domain covers, what is explicitly out of scope, and
the escalation rule the agent follows when it meets something above its scope or
its ceiling. An agent owns a domain rather than being a generic autonomous
employee, and the charter is where that is written down: a routine that does not
belong to the stated domain belongs to a different agent, or to no agent at all.

### Routine files, `<agents-root>/<agent>/routines/<slug>.md`

A routine file **is** an `ai-scheduled` job file plus two agent-layer headers,
which is why publishing one is a copy and nothing else.

```markdown
## Kind: template | monitor | planner
## Schedule: daily | weekly | weekly-<dow> | monthly | every:<N>h
## Agent: <agent>          (required: its presence marks the file agent-layer)
## Permission: read | propose | act   (optional; unset means propose)
## Project: <alias>        (optional)
## Model: <alias|id>       (optional)
## Runner: <name>          (optional; unset means default_runner)

<Markdown body>
```

| Header | Value | Required |
|---|---|---|
| `## Kind:` | `template` \| `monitor` \| `planner`, unchanged from any other job file | yes |
| `## Agent:` | the owning `<agent>` directory name | **yes** |
| `## Permission:` | `read` \| `propose` \| `act` | no, default `propose` |

`## Agent` is what marks a job file as agent-layer, and every agent-layer
behaviour is gated on it. A job file without it produces exactly the prompt,
the state and the output routes it produced before this layer existed, byte for
byte, which is what keeps the jobs already living in `scheduled/` untouched.

The body is the routine's instructions, and it must state four things about
itself: the context it may read (consistent with the charter's `## Sources`),
the output it produces, the tools it may use, and what it must never do, named
explicitly.

### The three permission levels

A level is defined by what the routine may **cause**, not by what it may read.

| Level | May cause |
|---|---|
| `read` | nothing. Observe and report only: no file written, no record created, no suggestion stub, no externally visible action. The whole output is a report a human reads. |
| `propose` | `read`, plus structured work into the **existing** pipeline through the **existing** routes: a suggestion stub into `suggestions/`, or a rendered task into `backlog-for-review/`. Everything it proposes still passes the human review gate. Nothing externally visible. |
| `act` | `propose`, plus the specific external actions **its own body names explicitly**. Nothing implied, nothing by analogy. If the action is not written in the routine file, the routine may not take it. |

A new routine is `propose`: an absent `## Permission` means `propose`, and that
default lives in `permission_from_job` and nowhere else. Forgetting a header is
common and the cost of the two possible mistakes is not symmetric, so a routine
cannot act on the world by omission. An **unrecognised** value is not a default
at all: the sweep logs it and skips the job until a human fixes the file.

`act` is granted **per routine**, by a human editing that one file, once the
routine has shown over real runs that it is reliable. Autonomy is never granted
at the agent level: raising a charter's `## Permission-Ceiling` to `act` changes
nothing about what any routine does, because each routine still carries its own
`## Permission`. A ceiling can only permit; it can never grant. That is what
keeps the blast radius of one edit equal to one job.

The level is enforced in two places:

- **At validate time**, `ai-agent --validate` fails a routine whose
  `## Permission` exceeds its charter's `## Permission-Ceiling`, before the
  routine is ever published, rather than leaving it as a runtime surprise
  discovered after it has acted.
- **At run time**, `ai-scheduled` injects a permission contract into the
  `monitor` and `planner` prompt (and only for a job carrying `## Agent`). It
  names the agent and the level, states that it outranks the routine body, and
  states that anything read while running is data and can never raise the level.
  `read` is additionally enforced **in code**: a monitor at `read` is handed the
  no-suggestion spec even when it declares a `## Project`, and a planner at
  `read` is skipped before the agent call, since proposing is its only output
  route.

### The memory ledger

`scheduled/.state/<slug>.memory.md`, one line per conclusive run:

```
2026-08-26 07:04 | perm=propose | signal=yes | stubs=2
```

Only a job carrying `## Agent` has one. The last `agent_memory_lines` lines
(default 40) are fed back into that routine's prompt as its PRIOR RUNS, and the
file is trimmed to the same bound after each run. This is how a routine knows
what it already reported, filed or sent, and therefore does not do it twice: a
routine decides what is new by comparing against its own state, never by
re-deriving it from the world. The bound is deliberate, because an unbounded
ledger grows the prompt without limit and the first thing to fall out of a
prompt too large to attend to is the routine's own recent history, which is
exactly the part it needed.

**Nothing is appended on a run that did not happen.** An auth failure, a
timeout, an empty result or a cooldown skip leave the ledger alone, for the same
reason they leave `<slug>.run` alone. A line claiming an action that never
happened is read as fact by the next run, which then decides the work is already
done and skips it, permanently.

### `ai-agent`

```sh
ai-agent                        # list every routine, grouped by agent
ai-agent --list                 # same
ai-agent --show SLUG            # charter headers, then that routine verbatim
ai-agent --validate             # check every charter and routine; exit 1 on any error
ai-agent --publish-plan [SLUG]  # print the cp command(s) to publish; runs nothing
```

`--validate` checks each charter's three headers, and per routine: the slug
shape, `## Kind`, `## Schedule` (through the same `is_due`), that `## Agent`
names its own parent directory, that `## Permission` parses and is within the
charter's ceiling, that `## Project` and `## Runner` name things that exist, that
no two routines share a slug, and that a slug does not collide with a
non-agent job already published under that name.

`ai-agent` writes nothing: no agent call, no provider loaded, no file moved,
nothing created under `$TASKS_DIR` or anywhere else. It is, with `dtask`, one of
the two scripts in this repo safe to run against the live tree.

The dashboard shows the same inventory in its AGENTS section: one line per
routine with its kind, schedule, permission and published state, plus how long
ago a published routine last ran.

### Publishing is a manual step

```sh
ai-agent --validate
ai-agent --publish-plan stale-branches
# then run the printed command yourself, with the path --publish-plan printed:
cp <agents-root>/release-hygiene/routines/stale-branches.md \
   ~/tasks/scheduled/stale-branches.md
```

`ai-agent --publish-plan` prints the `cp` and runs nothing, exactly like the cutover
commands below. Copying a routine into `~/tasks/scheduled/` makes it **live on
the next sweep** of a scheduler that is already in cron, running unattended on
whatever permission its file declares. Worse, until Step 2 of the cutover below
is done that sweep is run by the previous engine, which has no notion of
`## Agent` or `## Permission`: it would execute the routine body with no
permission contract in the prompt, no `read` enforcement in code, and no memory
ledger, which is precisely the autonomy this layer exists to bound. So
publishing is a deliberate human step, taken after reading the routine.

`--publish-plan` prints the real resolved path, so the command is copyable as
printed. This repository defines no routines of its own, so it prints nothing
until `agents_root` names a repository that has some.

### What is next

A new domain is a directory under the definitions root: a charter, a
`routines/` directory, one routine file per job, `ai-agent --validate`, and a
publish when the routine has earned it. **Nothing in `ai-scheduled`, `ai-task`
or `ai-eval` changes to add an agent**, and that is the property to preserve. A
domain worth an agent is one where the same question is worth asking every week;
anything asked once is a brief, and belongs in `briefs/`.

Adding an agent is therefore content work, not engine work, which is why the
definitions can live in a repository of their own without the engine noticing.

## `dtask`

Dashboard view of the whole pipeline across every runner. Read-only: it never
calls an agent, never moves a file, and never writes into `$TASKS_DIR`. It is
the one script in this repo safe to run against the live tree, since reading
is safe and writing is not.

```sh
dtask       # render once
dtask -w    # live refresh every 30s (exec's `watch -n 30`)
```

One `~/tasks/` tree now serves every runner, so every listed task shows its
resolved runner in `[brackets]`: the ⚑ NEEDS ATTENTION and RUNNING sections
annotate each item, and a BY RUNNER section breaks pipeline-stage counts down
the same way BY PROJECT does. Resolution goes through `runner_from_task` from
`lib.sh`: an unset `## Runner` renders as `default_runner` from `config`, never
as blank or "unknown". A `RUNNING` item whose runner claimed it via `ai-task`
reads its exact runner and tmux session from the `.state` sidecar file
(ground truth); anything else falls back to resolving the task's own
`## Runner`.

An AGENTS section lists the agent-layer routines found under the definitions
root (`agents_root`, or this repository's `agents/`), grouped by agent, with each routine's kind, schedule, permission
(`act` coloured apart from `read` and `propose`, since it is the level that
reaches outside the pipeline) and whether it is published into
`scheduled/`, plus how long ago a published one last ran. It reads the
definitions and `scheduled/.state/<slug>.run` and writes nothing, and it prints
nothing at all when no routine is defined.

The auth-cooldown banner is per runner, not global: `ai-task` / `ai-brief`
touch a separate `.auth-cooldown-<runner>` marker per provider, so a 401 on one
runner's queue is shown for that runner only, and never reads as a
system-wide pause. `dtask` discovers which runners to check from
`providers/*.sh` on disk plus any `.auth-cooldown-*` marker actually present in
`$TASKS_DIR` — runner names are never hardcoded in this script (`grep -qiE
'\bgrok\b|\bclaude\b|\bxai\b' dtask` finds nothing outside `providers/`).

`NO_COLOR` and `tput` fallbacks, pipeline-stage counts, and safe behaviour
against an empty or partially-missing tree are all preserved from the
dashboard this was ported from. The recent-activity feed from `DONE.md` also
carries a `[runner]` column. Each entry resolves its runner from the `##
Runner` of the **archived task file** (`<base>.task.md`, stored beside the
result by `ai-task`), then from the result file's own `**Runner:**` field if
that companion has been moved away, and only then falls back to
`default_runner` the same way every other section does.

That order is load-bearing. The `**Result:**` path in `DONE.md` names the
*result* file, which carries the runner as a bold field rather than a `##
Runner` heading, so resolving it directly found nothing and every archived
entry rendered as `default_runner` regardless of what it actually ran on. The
end-to-end smoke run caught this: a task that had genuinely run on `grok`
displayed as `[claude]`.

This replaces four separate per-provider dashboards from the previous
generation of this pipeline (their equivalents were named `dtask`, `ltask`,
`vtask`, `mtask`). The eventual `~/bin/dtask` symlink collides with an
existing symlink of the same name; resolving that collision is a manual
cutover step, not something this script does.

---

# Cutover

> **⚠️ STATUS, 2026-08-25: steps 1 and 3 are DONE at the user's explicit
> request. Step 2 (cron) is NOT.**
>
> | Step | State |
> |---|---|
> | 1 · symlinks | **done** — `ai-init`, `ai-task`, `ai-eval`, `ai-brief`, `ai-briefs` installed under their bare names |
> | 3 · `dtask` collision | **done** — `~/bin/dtask` repointed at this repo; `ai-dtask` was skipped entirely |
> | 2 · cron | **not done** — the crontab is byte-for-byte unchanged, and every `*-task` / `*-brief` line in it is still commented out |
>
> Nothing in the repo did this on its own: the user asked for each symlink
> explicitly. `~/Scripts/cursor-utils/` is still on disk, and the old
> `claude-*` / `grok-*` symlinks are still in `~/bin/` as the rollback path.
> The remaining commands are yours to run by hand. Order still matters: cron
> last.

The end state: `ai-task` replaces **two** task scripts (`claude-task` and
`grok-task`), `ai-scheduled` replaces `claude-scheduled`, one shared `~/tasks/`
tree serves both runners, and four Claude-specific cron jobs carry on untouched
in `claude-utils`.

## Step 1 — install the new symlinks

`ai-task` re-invokes itself as `$HOME/bin/ai-task --run` for the tmux child, so
**the symlink must be named exactly `ai-task`**. (It falls back to its own
directory when the symlink is absent, which is what made the smoke test work
without installing anything, but do not rely on that in cron.)

```sh
# already installed (2026-08-25)
ln -s ~/Scripts/ai-utils/init      ~/bin/ai-init
ln -s ~/Scripts/ai-utils/ai-task   ~/bin/ai-task
ln -s ~/Scripts/ai-utils/ai-eval   ~/bin/ai-eval
ln -s ~/Scripts/ai-utils/ai-brief  ~/bin/ai-brief
ln -s ~/Scripts/ai-utils/ai-briefs ~/bin/ai-briefs
ln -s ~/Scripts/ai-utils/dtask     ~/bin/dtask      # bare name, see Step 3

# still to install
ln -s ~/Scripts/ai-utils/ai-scheduled ~/bin/ai-scheduled
```

`init` is exposed as `ai-init`, not `init`, to avoid clashing with system
commands. `dtask` took the bare name directly rather than the `ai-dtask` interim
name this document originally planned; see Step 3.

Verify, then check the config is present (it is gitignored, so a fresh clone
has none):

```sh
ls -l ~/bin/ai-*
test -f ~/Scripts/ai-utils/config || cp ~/Scripts/ai-utils/config.example ~/Scripts/ai-utils/config
grep '^default_runner' ~/Scripts/ai-utils/config
```

## Step 2 — replace exactly three cron lines

`claude-task` and `grok-task` are replaced by `ai-task`; `claude-scheduled` is
replaced by `ai-scheduled`. Edit with `crontab -e`.

**Remove these three lines:**

```cron
*/15 * * * * $HOME/bin/claude-task        >> $HOME/tasks/cron.log 2>&1
*/10 * * * * $HOME/bin/grok-task           >> $HOME/tasks-grok/cron.log 2>&1
*/30 * * * * $HOME/bin/claude-scheduled    >> $HOME/tasks/cron.log 2>&1
```

**Add these three in their place:**

```cron
*/15 * * * * $HOME/bin/ai-task --runner claude >> $HOME/tasks/cron.log 2>&1
*/10 * * * * $HOME/bin/ai-task --runner grok   >> $HOME/tasks/cron.log 2>&1
*/30 * * * * $HOME/bin/ai-scheduled            >> $HOME/tasks/cron.log 2>&1
```

`ai-scheduled` takes no `--runner` on purpose: each job resolves its own runner
from its `## Runner` section, falling back to `default_runner`. The live
`email-triage` job has no such section, so it keeps running on `claude` with no
edit to the job file. Pinning `--runner` on the cron line would override every
job at once and is only useful for a deliberate one-off sweep.

**The two engines must never both be in cron.** They share
`~/tasks/scheduled/.state/`, so the state stamps are compatible and no job
re-fires or double-fires across the swap — but with both lines active, whichever
fires first claims each job and the other renders nothing, which reads as a job
that mysteriously stopped working.

Three things changed on purpose:

- **One binary, two invocations.** The intervals are carried over unchanged
  (`*/15` for Claude, `*/10` for Grok) so queue latency does not shift on
  cutover day. Each invocation only ever claims tasks whose resolved runner
  matches its `--runner`; a task belonging to the other runner is left in the
  inbox untouched, never silently retargeted.
- **`--runner` is not optional here.** Without it an invocation acts as
  `default_runner`, so both lines would poll as `claude` and the Grok queue
  would never drain.
- **Both log to `$HOME/tasks/cron.log`.** There is one tree now, so
  `$HOME/tasks-grok/cron.log` stops being written. Leave the old
  `~/tasks-grok/` directory alone until you have satisfied yourself the new
  lines are working; it is history, not state.

### The four cron entries that must NOT change

Do **not** touch these. They are not part of the brief-to-task pipeline, they
are Claude-specific by nature (they call `mcp__claude_ai_Gmail__*` tools that
have no Grok equivalent), and they keep pointing at `claude-utils` and reading
the same `~/tasks/` tree:

```cron
*/30 * * * * $HOME/bin/claude-review-alert >> $HOME/tasks/cron.log 2>&1
*/30 * * * * $HOME/bin/claude-auth-alert   >> $HOME/tasks/cron.log 2>&1
0 8 * * 1    $HOME/bin/ltask-cost       >> $HOME/logs/ltask-cost.log 2>&1
0 7 * * *    $HOME/bin/morning-briefing    >> $HOME/tasks/cron.log 2>&1
```

| Entry | Why it stays |
|---|---|
| `claude-review-alert` | outbound alerting on `review/`; no `ai-*` equivalent exists |
| `claude-auth-alert` | the outbound half of the auth circuit-breaker |
| `ltask-cost` | weekly spend report |
| `morning-briefing` | daily 07:00 briefing |

`claude-scheduled` used to be a fifth entry on this list, on the grounds that
its monitor jobs are Claude-specific. That reasoning applied to the **jobs**,
not to the **engine**: the Gmail dependency lives in `email-triage.md`'s body,
and `ai-scheduled` runs that job on `claude` like its predecessor did. So the
engine is replaced (Step 2) and the job file is untouched.

Any remaining crontab entries (backups, site monitors, per-customer jobs, other
per-project utilities) are unrelated to this work. Leave them alone too.

**Consequence worth knowing:** `ai-scheduled`'s `template` jobs, like
`claude-scheduled`'s before them, emit task files whose `## Runner` resolves
from the job rather than being invented per task. Task files that carry **no
`## Runner` section at all** still resolve to `default_runner`; there are ~2267
such files already, and that is the normal case, not an edge case.

Also note `claude-auth-alert` watches `~/tasks/.auth-cooldown` (the old global
marker), while `ai-task` writes `~/tasks/.auth-cooldown-<runner>` (per runner).
After cutover the alerting no longer sees a pipeline auth stall. Wiring it to
the per-runner markers is a follow-up, not a cutover step; `dtask` shows the
per-runner banner in the meantime.

## Step 3 — the `dtask` name collision

`~/bin/dtask` currently points at `claude-utils/dtask`, and this repo ships its
own `dtask`. They cannot both own the bare name.

**Resolved on 2026-08-25: the new `ai-utils/dtask` took the bare name
directly.** This document originally planned an `ai-dtask` interim step so both
dashboards could coexist while you built confidence; the user chose to skip it.
The new one is a superset anyway: it reports every runner in one view, whereas
the old one only ever saw the Claude tree.

What was run, for the record:

```sh
readlink ~/bin/dtask                              # was: claude-utils/dtask
ln -sfn ~/Scripts/ai-utils/dtask ~/bin/dtask
```

Nothing else depended on the name: no cron line referenced `dtask`, and no
script called it.

**What happens to the old one:** the `claude-utils/dtask` *file* stays exactly
where it is and is not deleted; only the `~/bin/dtask` symlink stops pointing
at it. It remains reachable as `~/Scripts/claude-utils/dtask` if you ever want
it back, and `ln -sf ~/Scripts/claude-utils/dtask ~/bin/dtask` reverses the
step.

The new `dtask` also replaces the three other per-provider dashboards, so these
symlinks become redundant at the same time. They are safe to remove **only
after** you have repointed `dtask` above:

```sh
rm ~/bin/ltask ~/bin/vtask ~/bin/mtask ~/bin/gdtask
```

`~/bin/ltask-cost` is a **different script** and must survive: it is still in
cron (Mon 08:00). Do not let a `rm ~/bin/ltask*` glob eat it.

## Step 4 — retire the superseded pipeline symlinks

Only after a few successful `ai-task` cron passes. These are the entry points
`ai-utils` now covers:

```sh
# replaced by ai-task
rm ~/bin/claude-task ~/bin/claude-tasks ~/bin/grok-task
# replaced by ai-eval
rm ~/bin/claude-eval ~/bin/grok-eval
# replaced by ai-brief / ai-briefs
rm ~/bin/claude-brief ~/bin/claude-briefs ~/bin/grok-brief ~/bin/grok-briefs
# replaced by ai-init
rm ~/bin/claude-init ~/bin/grok-init
```

Leave these `claude-utils` symlinks in place — they are the four remaining live
cron jobs plus scripts with no `ai-*` equivalent:

```
claude-auth-alert  claude-review-alert
ltask-cost  morning-briefing
claude-prep  claude-preps  claude-draft  x-post
```

`claude-scheduled` is no longer on this list: `ai-scheduled` replaces it. Keep
its symlink until Step 2's cron swap has run for a full cycle, then it is
removable like the rest.

`claude-prep` / `claude-preps` drive the older `backlog/` → `claude-prep` flow,
which `ai-utils` deliberately did not port; keep them if you still use it.

## Step 5 — retire `cursor-utils`

`~/Scripts/cursor-utils/` has been dead since May 2026 (15 files, last modified
2026-05-19) and appears in no cron entry. Its symlinks are pure clutter.

> **Correction to the plan this repo was built from:** that plan named **five**
> `cursor-*` symlinks (`cursor-task`, `cursor-tasks`, `cursor-ltask`,
> `cursor-mtask`, `cursor-vtask`). There are actually **thirteen**. The full
> list is below; verify with `ls ~/bin/cursor-*` before running anything.

```sh
# look first
ls -l ~/bin/cursor-*

# then remove all thirteen
rm ~/bin/cursor-draft ~/bin/cursor-eval ~/bin/cursor-init \
   ~/bin/cursor-ltask ~/bin/cursor-mtask ~/bin/cursor-plan \
   ~/bin/cursor-plans ~/bin/cursor-prep ~/bin/cursor-preps \
   ~/bin/cursor-review-alert ~/bin/cursor-task ~/bin/cursor-tasks \
   ~/bin/cursor-vtask
```

All five the plan named do exist. The eight it missed are `cursor-draft`,
`cursor-eval`, `cursor-init`, `cursor-plan`, `cursor-plans`, `cursor-prep`,
`cursor-preps` and `cursor-review-alert` — 5 + 8 = 13.

The directory itself is a separate decision, and a slower one. Archive rather
than delete, so an old task file that references a `cursor-*` path can still be
read:

```sh
mv ~/Scripts/cursor-utils ~/Scripts/.retired-cursor-utils-2026-05
```

## Step 6 — verify the cutover

```sh
crontab -l | grep -c .                   # entry count unchanged
crontab -l | grep -E 'ai-task'           # two lines, one per runner
crontab -l | grep -E 'ai-scheduled'      # one line, no --runner
ls -l ~/bin/ai-*                         # six symlinks, all resolving
dtask                                    # the new dashboard owns this name now
tail -f ~/tasks/cron.log                 # watch the next */10 and */15 pass
ls ~/tasks/run/                          # should not accumulate stale files
```

Confirm the push side survived the swap: `~/tasks/scheduled/email-triage.md`
should keep getting a fresh timestamp in
`~/tasks/scheduled/.state/email-triage.run` every hour, now written by
`ai-scheduled` instead of `claude-scheduled`. `ai-scheduled --dry-run` reports
what it would do without writing anything, which is the safe way to check the
job is still seen at all.

## Rollback

Nothing above is destructive to the pipeline's *state*: the `~/tasks/` tree,
`DONE.md`, every task file, and `scheduled/.state/` are untouched by any of it
(the scheduled state format is shared by both engines, so it survives a swap in
either direction). To back out, restore the three original cron lines and remove
the `ai-*` symlinks. `claude-utils` and
`grok-utils` are unmodified by this repo and remain fully functional.

---

# Known issues elsewhere

Found while building this repo. Both live **outside** `ai-utils` and are
deliberately **not** fixed here: `claude-utils` is read-only reference for this
project, and `claude-task` is the orchestrator that ran these very tasks.

## `~/tasks/scheduled/dirty-git-trees` has been silently skipped since 2026-07-31

The file has **no `.md` extension**. `claude-scheduled:227` globs
`"$SCHEDULED_DIR"/*.md` with no other filter and no warning on either side, so
the job has simply not existed as far as the scheduler is concerned since it
was created. It is still sitting in the directory looking active.

Evidence: the file is dated `2026-07-31 08:21`, the glob is
`jobs=("$SCHEDULED_DIR"/*.md)` with no other filter, and
`~/tasks/scheduled/.state/` holds **no `dirty-git-trees.run` marker at all**.
State is stamped only on a successful dispatch, so its absence means the job has
never once been dispatched, not merely that it is overdue. It is also the only
non-`.md` entry in that directory.

Dropping the extension is a legitimate way to disable a job, which is exactly
why this is easy to do by accident and impossible to notice: a disabled job and
a missing job look identical, and neither logs anything.

**`ai-scheduled` closes this hole.** Every sweep checks the non-`.md` files in
`scheduled/` and prints a warning for any that carry a `## Kind` or
`## Schedule` header, naming the file and saying it is being ignored. The glob
itself is unchanged, so dropping the extension still disables a job; it just
stops being silent about it. Verified against the live tree with
`ai-scheduled --dry-run`, which named `dirty-git-trees` on the first run.

Fix, if the job is still wanted (a **manual** step, in `claude-utils`
territory):

```sh
mv ~/tasks/scheduled/dirty-git-trees ~/tasks/scheduled/dirty-git-trees.md
```

Check the rest of the directory for the same problem first:

```sh
ls -A ~/tasks/scheduled/ | grep -v '\.md$'
```

## `tmux has-session -t NAME` prefix-matches

Not elsewhere — this one is inherited **into** this repo from both forks, and is
recorded here so it is not mistaken for a fix that landed. `ai-task:610` and
`ai-task:659` pass a bare session name, and `tmux -t NAME` matches a running
`NAME-2`. A distinct task can therefore be skipped as "already running". The fix
is `-t "=NAME"`. It did not bite either smoke run (the two sessions had
unrelated names) and is left as-is rather than changed unverified in a
documentation task.

## `claude-auth-alert` will not see a post-cutover auth stall

Covered under Cutover Step 2: it watches the old global
`~/tasks/.auth-cooldown`, and `ai-task` writes per-runner
`~/tasks/.auth-cooldown-<runner>` markers instead. Teaching it the new marker
shape means editing `claude-utils`, so it is a follow-up rather than part of
this cutover.
