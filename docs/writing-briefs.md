# Writing briefs

A brief is a short, plain description of a piece of work. `ai-brief` reads it,
looks at the project, and writes a chain of tasks into `backlog-for-review/`
for you to read before anything runs. This page gives the two templates you
write by hand (brief and project file) and the checklist for acceptance
criteria, which is where most failed tasks go wrong.

Paths such as `~/tasks/` are examples; the tree is wherever `TASKS_DIR` points.

Related pages: [getting started](getting-started.md),
[reviewing tasks](reviewing-tasks.md),
[reference: task file fields](reference.md#task-file-fields),
[reference: ai-brief](reference.md#ai-brief-and-ai-briefs).

## Daily use

```sh
$EDITOR ~/tasks/briefs/my-feature.md   # write the brief
ai-brief                               # makes an agent call: oldest brief in briefs/
ai-brief ~/tasks/briefs/my-feature.md  # makes an agent call: this brief
ai-briefs                              # makes an agent call per brief, in parallel
```

On success the brief moves to `briefs/done/` and the tasks land in
`backlog-for-review/`. On any failure the brief goes back to `briefs/`, so you
can fix it and run again.

## Brief template

```markdown
# <project>: <one-line title>

## Project
<project name, the file name in ~/tasks/projects/ without .md>

## Runner
<optional: the runner that will execute the tasks; unset means default_runner>

## Context
What exists today, what is wrong or missing, and why it matters. Name the
files, tables or commands involved when you know them.

## Task/tasks to create
1. First step, small enough for one agent run.
2. Second step, which builds on the first.

## Acceptance criteria guidance
- What must be true when the work is done, as a command and its expected
  output where possible.
```

- `## Project` is required: it tells `ai-brief` where to look, and every task
  inherits it.
- `## Runner` in the brief wins over `--runner` and `default_runner` for the
  tasks it produces. `ai-brief` writes `## Runner` into every task itself.
- `## Model` (optional) picks the model for the decomposition and the tasks.
- `## Base Branch: <branch>` (optional) applies to [worktree](worktrees.md)
  projects only.
- Say whether the steps form a chain. Each task can depend on at most one
  other task (see the checklist below).

## Project file template

One file per project, in `~/tasks/projects/<name>.md`. The file name is the
project name used in `## Project`.

```markdown
# <name>

## Type
code

## Aliases
- `<name>`
- `<other spelling>`

## Working Directory
`~/Projects/<name>/`

## Instructions
`~/Projects/<name>/AGENTS.md`

## Stack
Language, framework, how to run the tests, anything an agent must know.

## Conventions
- Rules the agent must follow in this repository.

## Relationships
(none)
```

- `## Working Directory` is where the agent runs, and where `ai-brief` measures
  criteria.
- `## Aliases` lists other spellings. They all share one project lock.
- `## Instructions` (optional) points at a file that is pasted into every
  prompt. See [configuration](configuration.md#referenced-project-instructions).
- `## Relationships` bounds where follow-up suggestions may go. `(none)` keeps
  them in this project.
- `## Isolation: worktree` (optional) gives each brief its own git worktree.
  See [worktrees](worktrees.md).

All fields: [reference: project file fields](reference.md#project-file-fields).

## How criteria are graded

`ai-eval` grades each acceptance criterion literally, with no benefit of the
doubt:

- A criterion it cannot verify is a FAIL.
- A criterion that names a file, path, command, table, flag or value means
  that exact one. A look-alike substitute fails it.
- It may run commands to check what the report claims.

A criterion that no correct run can pass is not a harder test: it fails every
attempt, the task ends in `review/`, and a human has to fix the task file. The
checklist below is how to avoid writing one. `ai-brief` applies the same rules
when it writes criteria, so use it to review the tasks it produces too.

## Acceptance criteria checklist

- [ ] **Measure before you assert.** Run any check that names a count, an
  absence or a git state before writing it, and record the command and its
  output under `## Criteria Baseline`, above `## Acceptance Criteria`. A check
  on something that does not exist yet is marked `DEFERRED`.
  Example: `- grep -c 'retry' src/job.sh: 1 (measured)`, then
  `- grep -c 'retry' src/job.sh prints 2 or more`.

- [ ] **Assert what the task creates, not baseline plus a predicted delta.**
  Both halves move: the baseline changes if anything else touches the data,
  and the delta is a guess.
  Example: not `Item::count() == 439 + 143`, but `142 rows carrying marker M
  exist`.

- [ ] **Scope invariants to the task's own rows or files.**
  Example: not `no duplicate X anywhere`, but `no duplicate X among the rows
  this task created`.

- [ ] **State idempotency as "creates nothing new", not as an absolute.**
  Example: not `re-run leaves count at 582`, but `a second run creates nothing
  new (created-count 0)`.

- [ ] **Never assert git working-tree state.** Other tasks share the tree and
  run at the same time, so a clean path at writing time is dirty at run time.
  Assert changed-line content, or a checksum the run records and re-checks.
  Example: not `git diff --stat .env shows no change`, but `record sha256sum
  .env first, re-check it last, require a match`.

- [ ] **Count matching lines, not all changed lines.** A `git diff` piped into
  `wc -l` measures tree state again; end the pipeline in `grep -c <pattern>`.
  Example: not `git diff -- src/ | grep '^[+-]' | wc -l returns 0`, but
  `git diff -- src/ | grep -c '^+.*legacy_call' returns 0`.

- [ ] **Join extracted document text before searching for a phrase.**
  `pdftotext` and similar tools wrap lines, so a phrase can be split in two.
  Example: not `pdftotext report.pdf - | grep -c 'Annual Report Summary'`, but
  `pdftotext report.pdf - | tr '\n' ' ' | grep -c 'Annual Report Summary'
  returns 1`, or grep a single word.

- [ ] **Write the full command and the expected result.** No ellipsis, no
  "as appropriate": a command, its target and its output or exit status.
  Example: not `run the tests ...`, but `bash tests/run.sh exits 0`.

- [ ] **Do not demand more matches from one file than the task adds.** Check
  what the file already contains first.
  Example: not `grep -c 'TODO' notes.md prints 3` on a file that already has
  two, but measure it and assert the line the task adds.

- [ ] **Require a removal check only for something the task removes.**
  Example: not `grep -r 'old_api' . prints nothing` over code the task never
  owned, but `grep -c 'old_api' src/client.sh prints 0` for the file it edits.

- [ ] **Keep each criterion passable by a correct implementation.** If passing
  it would require changing data, files or schema the task was not asked to
  touch, the criterion is wrong.
  Example: not `the users table has exactly 10 rows`, but `the import added 10
  rows with source = 'csv-2026'`.

- [ ] **One parent per task.** `## Depends-on` reads only the first slug, so a
  second parent is silently ignored. Build a chain (A, then B, then C) or
  separate chains, never a join.
  Example: `## Depends-on` followed by the single line `demo-add-schema`.

## What ai-brief adds

- `## Criteria Warnings`, appended to a task whose criteria match a risky shape
  from the checklist. It warns and never deletes: read it before promoting.
- One repair pass when the draft has a risky criterion or broken task
  delimiters. If the repair fails, the brief goes back to `briefs/` and the
  draft is kept in `run/` as a `.raw` file.
- `## Precondition` on a task that needs something only you can supply (a
  password, a credential file, an access). The task then waits in `inbox/`,
  without using a retry, until the check passes, instead of running, hitting a
  STOP step and failing. Say in the brief what you will have to provide, so the
  decomposer can write the check. See
  [reference: preconditions](reference.md#preconditions).
- A dependency check: a `## Depends-on` that names a task that was not emitted
  is removed; a cycle or a chain with no starting task rejects the whole batch.

Details: [reference: criteria checks and the repair pass](reference.md#criteria-checks-and-the-repair-pass).
