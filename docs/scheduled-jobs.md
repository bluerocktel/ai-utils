# Scheduled jobs and agents

`ai-task` only runs what is already in `inbox/`. `ai-scheduled` is the **push**
side: recurring jobs that put work into the same queues on a schedule. The
agent layer on top of it names who owns those jobs and what they may do.

Paths such as `~/tasks/` are examples: use your own `TASKS_DIR`. Related:
[configuration](configuration.md), [reference](reference.md),
[agents/CONTRACT.md](../agents/CONTRACT.md).

```
   scheduled/*.md                 recurring job definitions
      │
      │  ai-scheduled             cron fires it often; it decides what is due
      │
      ├── kind: template ────────▶ backlog-for-review/   (then the human gate,
      │                                                   exactly as a brief)
      ├── kind: monitor ─────────▶ a notes folder under brain_root, on a signal
      │                            + suggestions/        one follow-up stub
      └── kind: planner ─────────▶ suggestions/          a ranked set of stubs
```

`suggestions/` is a reading pile, not a queue: nothing there runs until you
move it into `inbox/` yourself.

## ai-scheduled

One cron line runs it often. The script decides which jobs are due from the
time of their last run, so a job's schedule lives in the job file, not in
crontab.

```sh
ai-scheduled                          # dispatch every due job
ai-scheduled --job SLUG               # only that job (still checks it is due)
ai-scheduled --force                  # ignore due-ness
ai-scheduled --dry-run                # report only: no writes, no agent call, no state
ai-scheduled --dry-run --show-prompt  # also print each rendered prompt
ai-scheduled --runner NAME            # act as this runner for every job
```

- An empty or missing `scheduled/` exits `0` silently, so it is safe on a timer.
- `--dry-run` writes nothing, so it is safe against your real tree.
- `scheduled_enabled=0` in `config` stops every job without touching cron.

## Job files

One file per job, `scheduled/<slug>.md`. The slug names its state, snapshot
and rendered tasks.

```markdown
## Kind: template | monitor | planner
## Schedule: daily | weekly | weekly-<dow> | monthly | every:<N>h
## Project: <alias>       (optional)
## Model: <alias|id>      (optional; template makes no agent call)
## Runner: <name>         (optional; unset means default_runner)

<Markdown body>
```

- Job headers use the inline form `## Field: value`. Task files use `## Field`
  with the value on the next line. Both forms are read in both places.
- **The `.md` extension is required.** A file without it is ignored, and each
  sweep prints a warning for a file that looks like a job (it has `## Kind` or
  `## Schedule`). Dropping the extension is how you disable a job.

## Schedules

| Value | Due when |
|---|---|
| `daily` | at least 23 h since the last run (not 24 h, so cron jitter cannot skip a day) |
| `weekly` | at least 6 d 23 h since the last run |
| `weekly-mon` to `weekly-sun` | today is that weekday and the job has not run today |
| `monthly` | the calendar month changed, or at least 28 d passed |
| `every:<N>h` | at least N hours since the last run |

A job that has never run is due. An invalid or missing `## Schedule` is
reported and skipped, never treated as due.

## Kinds

**`template`**: a fixed recurring task. No agent call. The body is copied into
`backlog-for-review/` with `## Project` and a stamped `## Runner` added. Use it
whenever the work is the same each time.

**`monitor`**: an agent that watches something. One call does the watch,
compares with the snapshot from last time, and returns fixed blocks:
`===SNAPSHOT===`, `===SIGNAL===`, and on a signal `===REPORT===` plus optionally
`===SUGGESTION===`.

- On a signal it writes a dated report into a journal folder under
  `brain_root`, and one suggestion stub when the job has a `## Project`.
- With no change it writes nothing, but still refreshes the snapshot. The diff
  is always against the last run, so a change that reverts is not reported
  twice.
- Each run is capped by `scheduled_timeout_min`.

**`planner`**: an agent that proposes work. It reads recent `done/` summaries,
project files, the queues and `review/` failures, then writes at most
`plan_ahead_max` ranked stubs into `suggestions/`.

- `NONE` is a successful run and stamps state.
- It complements the per-task suggester (see
  [configuration](configuration.md#follow-up-suggestions)): that one sees a
  single finished task; the planner connects several, follows a roadmap, or
  rethinks a failure.
- A stub whose slug already exists in the pipeline is skipped, except in
  `review/`: a failed task is exactly what a planner may propose a new approach
  for.

## State

| File | Holds |
|---|---|
| `scheduled/.state/<slug>.run` | epoch seconds of the last **successful** dispatch |
| `scheduled/.state/<slug>.snapshot.md` | a monitor's last snapshot |
| `scheduled/.state/<slug>.memory.md` | an agent routine's [memory ledger](#the-memory-ledger) |

A run that did not happen never stamps state. An auth failure, a timeout, an
empty result or a missing `===SNAPSHOT===` block leave the marker alone, so the
job is due again on the next sweep.

## The review gate and its one exception

A `template` job lands in `backlog-for-review/` and waits for you, like a
brief. The one exception: if the job's project file has
`## Automation: auto`, its rendered tasks go straight to `inbox/`.

- It is off by default.
- It is the only write path into `inbox/` in the pipeline. It is acceptable
  only because a template body is written by a human and copied verbatim.
  `ai-brief` has no such option.

## Runners and cooldown

- A job's runner: `--runner`, then the job's `## Runner`, then
  `default_runner`. Never "any runner".
- The runner is checked against `providers/<runner>.sh` before dispatch.
- The auth cooldown is per runner: a 401 on one provider never pauses another
  provider's jobs.
- `template` makes no agent call, ignores the cooldown, and keeps running while
  a runner is paused.
- Each agent job runs in its own subshell, so one job's provider cannot leak
  into the next.

## Adding a job

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

## The agent layer

An **agent** owns one domain of work. A **routine** is one small, explicit job
it performs on a schedule. The layer adds no engine: a routine is an
`ai-scheduled` job file with two more headers, its output enters the pipeline
through the existing routes (a stub in `suggestions/`, a task in
`backlog-for-review/`), and from there it is reviewed, run and graded like
everything else.

The full contract, with a worked example, is
[agents/CONTRACT.md](../agents/CONTRACT.md).

### Layout

```
agents/CONTRACT.md                          the contract
<agents-root>/<agent>/AGENT.md              the charter: the domain this agent owns
<agents-root>/<agent>/routines/<slug>.md    one routine, one file, one job
```

- Definitions live in git, never in `~/tasks/`. The only state is the per-job
  state `ai-scheduled` already keeps in `scheduled/.state/`.
- `<agent>` and `<slug>` are kebab-case, `[a-z0-9-]` only.
- The routine slug is its identity everywhere: file name, published job name,
  and state files. Renaming a routine starts it with no memory.

### Where definitions live

This repository ships **no agents**: `agents/` holds only the contract. Real
charters describe real work, so keep them in a private repository and point
`agents_root` at it:

```sh
# ~/Scripts/ai-utils/config   (gitignored)
agents_root=$HOME/my-agents
```

- Unset, `agents_root` means this repository's `agents/`.
- Only `ai-agent`, `dtask` and `ai-ask` read it. The engine runs the **published copy**
  in `scheduled/`, so where a definition lives never affects a run.
- Set but not a directory: a warning on stderr and an empty listing, never a
  fallback to `agents/`.
- Reverting a routine in git restores its instructions, not its state.
- A routine edited in place in `scheduled/` is no longer the file that
  `ai-agent --validate` checked.

### The charter

`<agents-root>/<agent>/AGENT.md`:

```markdown
## Domain: <one line: the domain this agent owns>
## Sources: <comma-separated internal sources its routines may read>
## Permission-Ceiling: read | propose | act

<Markdown body>
```

| Header | Value |
|---|---|
| `## Domain:` | one line: the domain this agent owns |
| `## Sources:` | comma-separated sources its routines may read, for example `email, crm, support-tickets, repositories, pipeline-state` |
| `## Permission-Ceiling:` | `read`, `propose` or `act`: the highest permission any of its routines may declare |

The body says what the domain covers, what is out of scope, and what the agent
does when something is above its scope or ceiling.

### Routine files

`<agents-root>/<agent>/routines/<slug>.md` is a job file plus agent headers, so
publishing it is a plain copy:

```markdown
## Kind: template | monitor | planner
## Schedule: daily | weekly | weekly-<dow> | monthly | every:<N>h
## Agent: <agent>          (required: marks the file as agent-layer)
## Permission: read | propose | act   (optional; unset means propose)
## Project: <alias>        (optional)
## Model: <alias|id>       (optional)
## Runner: <name>          (optional; unset means default_runner)
## Routes: message, brief  (optional; monitors at propose/act only)

<Markdown body>
```

| Header | Value | Required |
|---|---|---|
| `## Kind:` | `template`, `monitor` or `planner` | yes |
| `## Agent:` | the owning `<agent>` folder name | yes |
| `## Permission:` | `read`, `propose` or `act` | no, default `propose` |
| `## Routes:` | `message`, `brief` | no; absent grants neither |

- Every agent behaviour depends on `## Agent`. A job file without it behaves
  exactly as a plain job: same prompt, same state, same outputs.
- The body must state what it may read (within the charter's `## Sources`),
  what it produces, which tools it may use, and what it must never do.

### The three permission levels

A level is about what a routine may **cause**, not what it may read.

| Level | May cause |
|---|---|
| `read` | Nothing. Observe and report only: no file, no record, no stub, no external action. |
| `propose` | `read`, plus work into the existing pipeline: a stub in `suggestions/`, a task in `backlog-for-review/`, and, for a monitor that opts in with `## Routes`, a message to you or a brief in `briefs/`. Everything still passes human review. |
| `act` | `propose`, plus the specific external actions its own body names. Nothing implied. |

- No `## Permission` means `propose`. An unrecognised value is not a default:
  the job is logged and skipped until a human fixes it.
- `act` is granted per routine, by a human editing that one file. Raising a
  charter's ceiling grants nothing by itself: a ceiling only permits.
- **At validate time**, `ai-agent --validate` fails a routine whose
  permission is above its charter's ceiling.
- **At run time**, `ai-scheduled` adds a permission contract to monitor and
  planner prompts (only for jobs with `## Agent`): it names the agent and
  level, ranks above the body, and says that nothing read during the run can
  raise the level.
- `read` is also enforced in code: a monitor at `read` gets no suggestion
  route even with a `## Project`, and a planner at `read` is skipped before the
  agent call.

### Operator routes

A monitor at `propose` or `act` whose file says `## Routes: message, brief` can
mail you and file a brief. For example: read an incoming request, mail you a
draft brief with its open questions, read your replies on later runs, and write
the brief into `briefs/` once you say go. The model only emits blocks; the
engine delivers them:

```
===MESSAGE===
subject: <one line>
---
<plain-text body>
===END===

===BRIEF===
slug: <kebab-case-name>
---
<brief body>
===END===
```

- A **message** is sent with `agent_mail_cmd` (default `s-nail`) to
  `agent_mail_to`, with `agent_mail_reply_to` as Reply-To and `[<agent>]`
  before the subject. The recipient always comes from `config`, never from the
  model. Unset `agent_mail_to` removes the route.
- A **brief** is written to `briefs/<slug>-brief.md`, slug reduced to
  `[A-Za-z0-9._-]`. An existing name in `briefs/` or `briefs/done/` is refused.
  Nothing reaches `inbox/`.
- Routes are opt-in per routine and refused in code when not granted, at
  `read`, or for a plain job.
- A **failed send** makes the run inconclusive: no snapshot, memory line, state
  stamp or brief, so the next run starts from the same place.
- At most `agent_messages_max` (3) messages and `agent_briefs_max` (2) briefs
  per run. Extras are dropped and logged.
- Give `agent_mail_reply_to` its own address (a `+agents` plus-address with a
  mail filter works) so replies stay out of your inbox. The routine reads that
  address, read-only.

`tests/test_operator_routes.py` covers these rules offline.

### The memory ledger

`scheduled/.state/<slug>.memory.md`, one line per conclusive run:

```
2026-08-26 07:04 | perm=propose | signal=yes | stubs=2
```

- Only jobs with `## Agent` have one.
- The last `agent_memory_lines` lines (default 40) are fed back into the prompt
  as PRIOR RUNS, and the file is trimmed to that length after each run. This is
  how a routine knows what it already did.
- Nothing is appended on a run that did not happen (auth failure, timeout,
  empty result, cooldown skip): a false line would make the next run skip real
  work.

### ai-agent

```sh
ai-agent                        # list every routine, grouped by agent
ai-agent --list                 # same
ai-agent --show SLUG            # charter headers, then that routine verbatim
ai-agent --validate             # check every charter and routine; exit 1 on any error
ai-agent --publish-plan [SLUG]  # print the cp command(s) to publish; runs nothing
```

`--validate` checks each charter's three headers, and for each routine: slug
shape, `## Kind`, `## Schedule`, that `## Agent` names its own parent folder,
that `## Permission` parses and is within the ceiling, that `## Project` and
`## Runner` exist, that no two routines share a slug, and that the slug does
not collide with a plain job already in `scheduled/`.

`ai-agent` writes nothing: no agent call, no provider loaded, no file moved.
`dtask`'s AGENTS section shows what each published routine is doing
(overdue, found something, quiet), and `ai-ask AGENT "question"` asks an agent
about its own runs. See [reference: dtask](reference.md#the-agents-section)
and [reference: ai-ask](reference.md#ai-ask).

### Publishing is a manual step

```sh
ai-agent --validate
ai-agent --publish-plan stale-branches
# then run the printed command yourself:
cp <agents-root>/release-hygiene/routines/stale-branches.md \
   ~/tasks/scheduled/stale-branches.md
```

A routine copied into `scheduled/` is **live on the next sweep**, unattended,
at whatever permission its file declares. Read it before you copy it.
`--publish-plan` prints the real resolved path, and prints nothing until
`agents_root` points at a repository with routines.

### Adding an agent

A new domain is a folder under the definitions root: a charter, a `routines/`
folder, one file per routine, `ai-agent --validate`, and a publish once the
routine has earned it. Nothing in `ai-scheduled`, `ai-task` or `ai-eval`
changes. A question worth asking every week is worth an agent; a question asked
once is a brief.
