# Reviewing tasks

You are the gate of the pipeline. Nothing an agent proposes runs until you
move it into `inbox/`, and anything that fails too often comes back to you in
`review/`. This page covers both ends, plus follow-up suggestions.

Paths such as `~/tasks/` are examples; the tree is wherever `TASKS_DIR` points.

Related pages: [writing briefs](writing-briefs.md),
[reference: ai-task](reference.md#ai-task), [dtask](reference.md#dtask).

```
briefs/ -> ai-brief -> backlog-for-review/ -> (YOU) -> inbox/ -> ai-task -> done/
                                                                    |
                                                         fails max_retries times
                                                                    v
                                                                 review/ -> (YOU)
```

`dtask` lists everything waiting for you under **NEEDS ATTENTION**.

## The review queue: backlog-for-review/

`ai-brief` writes every task it produces into `backlog-for-review/` and stops
there. It has no way to write into `inbox/`. Tasks rendered by `ai-scheduled`
template jobs land here too.

For each task, check:

- **Scope.** `## Tasks` does one thing, small enough for one run, in the right
  project.
- **Criteria.** Each item under `## Acceptance Criteria` passes the
  [checklist](writing-briefs.md#acceptance-criteria-checklist). Read any
  `## Criteria Warnings` section: it points at a risky criterion.
- **Baseline.** `## Criteria Baseline` shows what each count or absence was
  when the task was written. A criterion that contradicts its own baseline is
  wrong.
- **Chain.** `## Depends-on` names one parent, and that parent is in the same
  batch or already done.
- **Runner.** `## Runner` names the provider you want to pay for this task.

Edit the file freely: fix a criterion, delete one, tighten the scope. Then
promote it:

```sh
mv ~/tasks/backlog-for-review/<task>.md ~/tasks/inbox/
```

Delete a task you do not want. A dependent of a deleted task will never start
(see [dead dependency chains](#dead-dependency-chains)).

## Retries

`ai-task` claims the oldest runnable task in `inbox/`, runs it, and has
`ai-eval` grade it against its acceptance criteria.

- **PASS:** the task and its report go to `done/`, with an entry in `DONE.md`.
- **FAIL:** the task goes back to `inbox/` with the evaluator's feedback
  appended as `## Evaluator Feedback (Attempt N)`, and `## Retries` goes up by
  one. From the second failure, a strategy note is appended too.
- **FAIL `max_retries` times** (default `3`, see
  [configuration](configuration.md)): the task moves to `review/` and burns no
  further work.

Only a real FAIL costs a retry. An auth failure, a project lock timeout, a
timeout, a killed run or an empty result puts the task back in `inbox/`
unchanged, at no cost. Full table: [reference: outcomes](reference.md#outcomes).

## review/

A task lands in `review/` for one of two reasons:

1. It failed `max_retries` times. Read the evaluator feedback sections at the
   bottom of the task file and the reports in `done/` with the same slug.
   Usually either the work needs a better instruction, or a criterion is wrong.
2. The evaluator found an **unsatisfiable criterion** (`ai-eval` exit `5`).
   This burns no retry. The report in `done/` (named in the `DONE.md` entry,
   which reads `NEEDS REVIEW (unsatisfiable acceptance criteria)`) ends with an
   `## Evaluator (unsatisfiable acceptance criteria)` section: for each bad
   criterion, the command and output that prove no correct run could pass it.

For exit `5`, **the task file is what needs fixing, not the code.** Re-run the
evidence command to confirm, then edit or delete the criterion. The evaluator
only gives this verdict when every other criterion passes (or is itself proven
impossible) and the evidence is shown; otherwise it is a normal FAIL.

When the file is fixed, send it back with `--unblock`.

## Fix proposals

When grading sends a task to `review/`, `ai-task` starts `ai-propose` in the
background (`review_proposals=1`, the default). One agent call reads the task
with all its evaluator feedback, its latest report, and the tasks of the same
brief still in `inbox/` or `backlog-for-review/`, and writes
`review/<task>.proposal`:

- the cause, as one of `bad-criterion`, `wrong-assumption`,
  `missing-precondition`, `implementation`;
- the proposed edits, as diffs, for this task and for any pending task of the
  same brief with the same defect;
- edits it refused, and why;
- anything else you need to do (for a precondition: what to install).

You get a notification when it is ready, and `dtask` shows
`fix proposed: ai-propose --apply <slug>` on the task.

```sh
less ~/tasks/review/<task>.proposal
ai-propose --apply <slug>
ai-task --unblock <slug>
```

The edits offered are checked before you see them, not just trusted: each one
must target this task or a pending task of the same brief, its old text must
occur exactly once, and it must sit above the first evaluator section, which
is history and never rewritten. `--apply` checks them again (you may have
edited the file since), applies all or nothing, and takes `inbox.lock` for the
tasks in `inbox/`. It never unblocks: that is still your call.

No proposal (auth failure, timeout, empty answer) changes nothing about the
task. To draft one by hand, for a task already in `review/`:
`ai-propose <slug>`; `ai-propose --context <slug>` prints what the agent
would be given.

## ai-task --unblock

```sh
$ ai-task --unblock demo-fix
Unblocked: 2026-09-18_demo-fix.md
  review/ → inbox/
  ## Retries reset: 3 → 0
  also unblocks:
  - 2026-09-18_demo-follow-up
Note: nothing here checked the task file. If the reason it reached
review/ is still in it, the next evaluation sends it straight back.
```

`--unblock SLUG` is the one supported way out of `review/`. It makes no agent
call. It moves the task to `inbox/` and resets `## Retries` to `0`, so a
repaired task gets a full retry budget instead of returning to `review/` on its
first FAIL.

**Fix the task file first.** `--unblock` does not check that you did.

| Situation | Behaviour |
|---|---|
| slug is in `review/` | moved to `inbox/`, `## Retries` reset to `0`, the dependents it frees are listed |
| slug is elsewhere in the pipeline | refused; the message says which folder it is in |
| slug matches two files in `review/` | refused, both named: two dated attempts of one task, and picking one would be a guess. Remove the stale one by hand |
| argument contains a path | the path is stripped before the lookup, so it can only ever move a file out of `review/` |

## Waiting on a precondition

`dtask` shows `⏸ waiting: precondition since <time>` for a task in `inbox/`
whose `## Precondition` fails. Nothing is wrong with the task: it is waiting
for something only you can supply. `cat ~/tasks/.precondition/<task>` shows the
failing command and its output. Provide what is missing; the next sweep claims
the task. To run it anyway, name the file: `ai-task ~/tasks/inbox/<task>.md`.

## Dead dependency chains

A task with `## Depends-on` waits until its parent is in `done/`. A parent in
`review/` never gets there on its own, so every task downstream of it waits
forever. `ai-task` silently skips a blocked task and runs the next one, so
without help you would never notice.

`dtask` shows these blocks under NEEDS ATTENTION, and counts them on the
pipeline line:

```
⚑  NEEDS ATTENTION
  2 item(s) require your input

  ● demo-fix                                  [claude]  (failed, needs review)
  ⊘ demo-follow-up                            [claude]  (blocked: dep 'demo-fix' is in review/)

  PIPELINE
  briefs(0) → prep-review(0) → inbox(5) → running(1) → review(1)   ⊘ blocked(1)
```

| Parent is in | Kind | What to do |
|---|---|---|
| `review/` | dead | Fix the parent, then `ai-task --unblock <parent>`. |
| nowhere | dead | The slug was mistyped or the parent was deleted. Fix or remove the `## Depends-on` line in the dependent. |
| `inbox/`, `run/`, `backlog-for-review/` | waiting | Normal queue order. Not shown. |

`blocked(N)` is not a separate stage: those tasks are still in `inbox/` and
counted there. `ai-task` also prints dead chains in its log on every run.

A parent in `review/` is never treated as done: its work did not pass, and a
dependent built on it would build on failed work.

## suggestions/

When a task passes, `ai-task` may propose up to `suggest_max` follow-up task
stubs into `suggestions/`. Monitor and planner jobs from `ai-scheduled` write
stubs there too.

`suggestions/` is a reading pile, not a queue. Nothing in it runs, so `dtask`
shows it in a SUGGESTIONS section: the count (yellow above 30), how many
arrived in the last 7 days, and the 5 newest stubs. To act on a
stub, turn it into a full task (or a brief) and move it yourself:

```sh
mv ~/tasks/suggestions/<stub>.md ~/tasks/backlog-for-review/   # review it like any task
mv ~/tasks/suggestions/<stub>.md ~/tasks/briefs/               # or decompose it as a brief
```

Delete the stubs you do not want. A stub may only target the task's own project
or a project listed under `## Relationships` in its project file; anything else
is refused when it is written. Settings: `suggest_enabled`, `suggest_max`, see
[configuration: follow-up suggestions](configuration.md#follow-up-suggestions).
