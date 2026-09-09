# CLAUDE.md - ai-utils

See `README.md` for user-facing documentation (every script, every config key, the
cutover commands). See `providers/CONTRACT.md` for the six-function provider
contract. This file is the working notes for an agent editing this repo.

## For an agent: working in this repo

### What this repo is

Shell scripts that drive autonomous agent task execution, **provider-agnostic**.
It is the merge of two forks of the same design, `~/Scripts/claude-utils`
(mature, ~2.7k lines) and `~/Scripts/grok-utils` (~1.9k lines), which differed
only in a thin vendor surface of roughly 5% of their lines. Keeping two copies
meant every fix had to be applied twice, and in practice was not.

The scope is deliberately the `grok-utils` surface: the brief-to-task loop
actually in daily use, plus a dashboard, plus the recurring-job engine that
pushes work into that loop.

```
scheduled/ ──ai-scheduled──> backlog-for-review/   (kind: template)
           └─────────────── > suggestions/          (kind: monitor | planner)

briefs/ ──ai-brief──> backlog-for-review/ ──(HUMAN REVIEW)──> inbox/
                                                                │
                                                            ai-task
                                                                │
                                                         (agent runs)
                                                                │
                                                             ai-eval
                                                          ┌─────┴─────┐
                                                        PASS         FAIL
                                                          │            │
                                                        done/     inbox/ (retry)
                                                                       │
                                                            max_retries reached
                                                                       │
                                                                   review/
```

**The runner is a field on the task, not a separate directory tree.** One
`~/tasks/` tree, one lock namespace, one `projects/` directory, one `DONE.md`.
That is the whole architectural bet: the previous generation had `~/tasks/` and
`~/tasks-grok/` as parallel universes, which meant two dashboards, two
`DONE.md` files, and no way to see the queue as a whole.

### Layout

| Path | Role |
|---|---|
| `lib.sh` | shared helpers, sourced by every script. **Provider-neutral by contract.** |
| `providers/<runner>.sh` | the only files allowed to name a vendor. File name **is** the runner name. |
| `providers/CONTRACT.md` | the six-function contract. Read before changing a signature. |
| `init` | creates the pipeline tree. Idempotent, additive only. |
| `ai-task` | claim one queued task, run it, evaluate it, archive it. |
| `ai-eval` | grade one finished task. Exit code is the whole interface (0/1/2/3/4). |
| `ai-brief` / `ai-briefs` | decompose a brief into a chain of tasks, into the review queue. |
| `ai-scheduled` | the push side: dispatch the due recurring jobs in `scheduled/`. |
| `ai-agent` | read-only view of the agent layer: list, show, validate, publish plan. Writes nothing, anywhere. |
| `dtask` | read-only dashboard across every runner. |
| `agents/CONTRACT.md` | the agent-layer contract: layout, headers, the three permission levels, and a worked example. **The only thing under `agents/`:** this repo ships no agents, see The agent layer. |
| `<agents-root>/<agent>/AGENT.md` | one agent's charter: `## Domain`, `## Sources`, `## Permission-Ceiling`. Lives wherever `agents_dir` resolves. |
| `<agents-root>/<agent>/routines/<slug>.md` | one routine: an `ai-scheduled` job file plus `## Agent` and `## Permission`. |
| `config` | sourced key=value. Gitignored; `config.example` is the tracked template. |

### Conventions

- All scripts: `#!/bin/bash` with `set -euo pipefail`. External deps: `tmux`,
  `jq`, `flock`, `timeout`, plus each provider's CLI.
- Every script must be safe against an empty or partially-missing source tree:
  exit `0`, no noise. They run on timers; anything else floods `cron.log`.
- `config` is sourced as key=value. Never hardcode user-specific values.
- **Nothing outside `providers/` may name a vendor, a vendor CLI, a vendor model
  id, or a vendor JSON field.** This is checkable, and worth checking after any
  edit:
  ```sh
  grep -rniE '\bgrok\b|\bclaude\b|\bxai\b|\banthropic\b' \
      lib.sh init ai-task ai-eval ai-brief ai-briefs ai-scheduled dtask ai-agent
  ```
  Hits in comments that describe the abstraction are acceptable; a hit in
  executed code is a bug.
- Symlink names in `~/bin/` matter: `init` is exposed as `ai-init` to avoid
  clashing with system commands. Installing them is the user's manual step.

## The provider contract

Six functions, in one file per runner, sourced after `lib.sh` and after
`load_config`. `load_provider` refuses to run a provider that is missing any of
the six rather than falling back to a default, because a silent fallback sends
the task to the wrong vendor.

| Function | Returns |
|---|---|
| `ai_run PROMPT MODEL_ID WORKDIR TIMEOUT_SEC JSON_OUT ERR_OUT` | the CLI's exit status **verbatim**, including `124` from `timeout` |
| `ai_json_text JSON_FILE` | the response text on stdout; empty is normal, not an error |
| `ai_usage_table JSON_FILE OUT_FILE` | always `0`; writes a `## Token Usage` fragment |
| `ai_is_auth_failure FILE` | `0` if the capture shows an auth failure |
| `ai_model_alias RAW` | a model id on stdout; always `0` |
| `ai_preamble_extra TASK_FILE` | text appended to the shared preamble; `TASK_FILE` is **read only** |

A provider must not read task files, move files, write to `DONE.md`, or touch a
cooldown marker. That orchestration stays in `ai-*`. It also must not set shell
options: it is sourced, so `set -euo pipefail` there would change behaviour for
every line after the source in the caller.

`ai_run` must not normalise `124`. Callers branch on it to distinguish "timed
out" (deferred, no retry burned) from "failed" (retry burned). Normalising it
starts consuming retries on tasks that never got to finish.

## The five gotchas

These are the five things the forks got wrong most often, and the five things
most likely to be reintroduced by a well-meaning edit.

### 1. Separate stdout and stderr. Never `2>&1`.

Every headless capture MUST be `> "$json_out" 2> "$err_out"`. **Never** `2>&1`.

Both CLIs print warnings to stderr. Claude prints
`Ignoring N permissions.allow entries ... this workspace has not been trusted`;
the `grok` CLI prints `Shell cwd was reset to ...` (observed on every smoke
run). Merged into stdout, that text prepends non-JSON to the JSON document,
`jq` fails to parse, and the result text and usage table come back **empty**.

The failure is silent and expensive. In the fork this was ported from it
produced blank task reports *and* blank evaluator verdicts, and a blank verdict
was read as FAIL, sending a task that had actually passed through ten retries
into `review/`.

The two files must also survive **as separate files**, because
`ai_is_auth_failure` is called on both: a 401 can appear on either stream
depending on the CLI and the code path.

### 2. The auth cooldown marker is PER RUNNER.

The marker is `$TASKS_DIR/.auth-cooldown-<runner>`, built by `cooldown_path`
in `lib.sh`. There is deliberately **no** single shared `COOLDOWN` variable to
reach for.

A 401 on one provider must never pause another provider's queue. With one
shared tree and a global marker, an expired Claude token would stop Grok work
that had nothing wrong with it, and the dashboard would report a system-wide
pause when only half the system was down. `dtask` renders the banner per runner
for the same reason.

An auth failure means **no work happened**, so it never burns a retry.

### 3. The per-project flock is SHARED ACROSS RUNNERS.

`$TASKS_DIR/.locks/<project>.lock`, held for the whole run including
evaluation (the eval's `## Test Command` hits the same tree).

Making it per runner would be the obvious "symmetry" fix and would be exactly
wrong. **This lock is the whole reason the unified tree is safe:** two agents
must never be inside the same git working tree and DB at once, and it does not
matter one bit which vendor they came from. A Claude task and a Grok task on the
same `## Project` race precisely as hard as two Claude tasks do.

Contrast with the two other locks:

| Lock / marker | Scope | Held for |
|---|---|---|
| `.locks/inbox.lock` | shared, all runners | milliseconds (select + move + state marker only) |
| `.locks/<project>.lock` | **shared, all runners** | the whole run + eval |
| `.auth-cooldown-<runner>` | **per runner** | `auth_cooldown_min` |

A project-lock wait timeout is a **deferral**, not a failure: requeued
unchanged, no retry burned.

### 4. An unset `## Runner` resolves to `default_runner`, never to "any runner".

`runner_from_task` in `lib.sh` maps an absent, empty, or literal `any` value to
`default_runner` from `config`.

This is the common case, not the edge case. There are **2267** existing task
files with no `## Runner` section, and `claude-scheduled` (which stays in
`claude-utils`, see Hard boundaries) keeps emitting more into
`backlog-for-review/` and `inbox/` with no runner field. All of them must keep
behaving exactly as they do today.

"Any runner" is not a value and must never become one. It would mean two
runners polling on different cron intervals could both claim the same task;
the atomic inbox claim prevents the double-run, but the routing would still be
a coin flip, and a task's cost and capability profile would stop being
predictable from its file.

When the section is unset **and** `default_runner` is unset,
`runner_from_task` returns `1` and prints nothing. That is a config error the
caller must surface, not guess at.

`--runner NAME` on an invocation sets the runner it *acts as*. Full resolution
order for a task's runner: `--runner`, then the task's `## Runner`, then
`default_runner`.

### 5. `## Depends-on` takes exactly ONE parent.

`depends_on_from_task` reads **only the first token of the first line** under
the heading. A task therefore has at most one parent, and `ai-brief`'s
decomposition prompt states this explicitly and demands a linear chain
(`A → B → C`) or a forest of independent chains, never a join.

It has to be a prompt-level constraint because **nothing downstream can catch a
violation.** `repair_brief_task_graph` detects a cycle and a missing root, but a
join reads as a single dependency and the second parent is **silently
discarded**. The task then starts before work it needs has finished, and the
failure surfaces as a mysterious quality problem in an unrelated task.

If you ever need a real join, it is a change to `depends_on_from_task`, the
`dep_satisfied` check, `locate_dep_slug`, the dashboard, and the decomposition
prompt. Do not half-build it by relaxing only the prompt.

## Other things to watch out for

- **Every deferral path in `ai-task --run` goes through `requeue_task`,** which
  no-ops when source and destination are the same path. The launcher normally
  moves the task into `run/` first, but a direct `--run` on a file still in
  `inbox/` makes them identical, `mv` errors, and under `set -e` the abort
  happens *before* the log line and the notification — leaving a bare `mv`
  complaint and no sign the task is still queued. Same hardening, same reason,
  as `restore_brief` in `ai-brief`. Do not reintroduce a raw `mv "$TASK_FILE"
  "$INBOX/..."`.
- **`ai-task` calls itself** for the internal tmux execution: `$HOME/bin/ai-task
  --run`, falling back to `$SCRIPT_DIR/ai-task` when the symlink is not
  installed yet. If you rename the script, update the self-reference.
- **`TASKS_DIR` is passed explicitly into the tmux command line.** The tmux
  server has its own environment, so a tree override on the parent invocation
  would otherwise be lost and the child would work against the **live** tree.
  That is what makes a `TASKS_DIR=/tmp/...` smoke run safe; do not "simplify" it
  away.
- **`tmux has-session -t NAME` prefix-matches.** `ai-task:610` and `ai-task:659`
  pass a bare name, so a running session `ai-claude-foo-2` answers a check for
  `ai-claude-foo`, and a distinct task is skipped as "already running". The fix
  is `-t "=NAME"`. Inherited from both forks; still present here.
- **`ai-eval`'s exit codes are the interface.** `0` PASS, `1` FAIL, `2` nothing
  to grade, `3` inconclusive/auth (no retry, pauses that runner), `4` test
  timeout (no retry, does **not** pause). Keep `3` and `4` distinct. Do not
  renumber any of them: `ai-task` branches on every one.
- **`ai-task`'s follow-up suggester writes to `suggestions/` and nowhere else.**
  `generate_suggestions` runs on the verified-success path only, and it runs
  **before** the archival `mv "$TASK_FILE" "$DONE_DIR/..."` because it reads the
  task file in place: move the call after the `mv` and it reads a path that no
  longer exists. It is called as `generate_suggestions || true`, so a failed,
  timed-out or garbage suggester can never keep a task that passed out of
  `done/` — silence is a correct outcome, and `NONE` and an empty response are
  both treated as zero stubs. It is cross-project (deliberately unlike the fork
  it came from), bounded by the ORIGIN project's `## Relationships`, and **that
  bound is enforced in `write_stub`, not in the prompt**: `write_stub`'s third
  argument is the permitted target set, and a stub whose `project:` is outside
  it, or names a project with no file in `$PROJECTS_DIR`, is refused and
  logged. A rule that lives only in prompt text is a rule the model can talk
  itself out of, and a routine reads the world. Verb handling is the mirror
  image: permissive, because the live tree already carries a `host` verb that a
  hardcoded `mirror|content` list would silently drop, and the verb only
  becomes the stub's `kind:` on a file a human still has to promote.
  `project_relationship_targets` accepts both `→` (what every project file
  actually uses) and `->` (what `ai-scheduled:621` advertises), and rewrites no
  project file either way.
- **`write_stub` lives in `lib.sh` and is shared by `ai-task` and
  `ai-scheduled`.** It logs through `STUB_LOG_PREFIX` rather than a `log()`
  that only `ai-scheduled` defines; `ai-scheduled` sets the prefix to
  `"ai-scheduled: "` so its stdout is byte-identical to when the function lived
  in that file. Its third argument is optional and an EMPTY value keeps the
  pre-existing behaviour exactly, which is what `ai-scheduled`'s two call sites
  rely on. Do not change the wording of its messages: they are the moved
  function's contract with the older caller.
- **`ai-brief` has no write path into `inbox/`.** The human review gate is the
  single most important property of the pipeline. `inbox/` is deliberately
  absent even from its `mkdir -p` list, and the model-proposed filename is
  stripped of every path component and reduced to `[A-Za-z0-9._-]` so no agent
  output can steer a write out of the review queue. Do not add a convenience
  flag that bypasses this.
- **The decomposition prompt is ONE double-quoted bash string, and its body
  contains no `"` characters.** Keep it that way: an inner double quote closes
  the string, and because the text around it contains spaces the assignment
  breaks into words — bash then tries to RUN the next token as a command and
  `PREAMBLE` ends up empty. `bash -n` cannot see this (the quotes still
  balance), and the only symptom is a decomposition run with no instructions.
  Use single quotes for quoted examples inside the prompt, as the rest of it
  does. Verified failure: `V="a "X == 1" b"` prints `==: command not found` and
  assigns nothing.
- **Both of `ai-task`'s prompts tell the agent not to force an unsatisfiable
  criterion.** The autonomous preamble says: do the task correctly, change
  nothing outside its stated scope to make a check pass, never create a record
  whose only purpose is to move a count, undo any such change a previous attempt
  made, and report the conflict in the `## Summary` with the arithmetic. The
  strategy pass says: when the recurring failure is a criterion that cannot be
  satisfied, recommend stopping and name the decision the user must make, rather
  than proposing a workaround. These two paragraphs exist because an attempt
  hard-deleted four production rows and manufactured a duplicate catalogue entry
  to turn two red checks green — both harder to undo than the shortfall they hid.
- **`ai-task`'s prompt bodies also contain no `"` characters**, for the same
  reason as `ai-brief`'s, and the same fix applies (single quotes for quoted
  examples). Three lines of prompt *content* additionally sit at column 0 inside
  those strings — the `PROJECT CONTEXT` paragraph, the `$EXTRA` block and the
  `$(cat "$TASK_FILE")` interpolation. A whitespace-only reindent of the work
  phase silently indented all three, changing the delivered prompt. If you
  reindent that block again, check the rendered prompt for lines starting with a
  space, not just that `bash -n` passes.
- **Acceptance criteria in the decomposition prompt must be scoped to what the
  task creates.** No baseline-plus-predicted-delta totals, no global invariants
  the task does not own, and idempotency stated as "a second run creates nothing
  new" rather than as an absolute count. A criterion that a correct
  implementation cannot pass is indistinguishable from one that has not passed
  yet, so the retry loop spends every attempt on it — and an agent under
  pressure to satisfy it may mutate data outside the task's scope. See the
  README section "Acceptance criteria must be scoped to the task" for the
  case that produced this rule.
- **`ai_preamble_extra` is deliberately NOT appended to the decomposition
  prompt** in `ai-brief`, unlike `ai-task`. The provider extras describe the
  shape of a *result report*, which contradicts that prompt's "output only the
  delimited task blocks" contract and breaks extraction.
- **`ai-brief` stamps `## Runner` itself** (after extraction), discarding any
  the model wrote. Routing that depends on the model remembering to write a
  section is routing that silently regresses. The stamp target is validated
  against `providers/<runner>.sh` *before* the agent call, because a stamp
  naming a nonexistent provider produces a whole batch no `ai-task` can ever
  claim, and that would only surface after the human review pass.
- **A model flag must be a bash array,** expanded as `"${model_args[@]}"`.
  Never a plain string expanded unquoted. Some model ids contain brackets
  (`claude-opus-5[1m]`) and there is no bracket-free spelling the CLI accepts;
  unquoted, bash treats it as a glob, and a file in the task's working
  directory can silently rewrite the flag to that filename. Verified
  reproducible in the fork.
- **`dtask` is the only script here safe to run against the live tree,** because
  it is read-only: no agent call, no file move, no write into `$TASKS_DIR`.

## Split grading (`eval_runner`)

`config` may name a different runner and model for **grading** than for
**executing**: `eval_runner` / `eval_model`. Unset, everything behaves as it
did (the executor grades its own work). The useful configuration is a different
*provider*, because the value of a second opinion is that its failure modes are
independent. Six things to keep right:

1. **An evaluator auth failure pauses the GRADER, never the executor.**
   `ai-task` touches `cooldown_path "$EVAL_RUNNER"`. Before the split these were
   the same runner and the distinction was invisible; get it wrong now and an
   expired judge token stops a queue whose credentials are fine, which is what
   the per-runner marker exists to prevent (gotcha 2).

2. **A finished run is never executed twice.** On an evaluator auth failure the
   report is already on disk, so the task is stamped `## Awaiting-Eval
   <report-basename>` and the next claim GRADES that report instead of running
   the task again. Without this a grader outage silently doubles execution cost,
   and the split stops being worth having.

3. **The grade-only resume reuses the report's timestamp.** `done/` pairs
   `<ts>_<task>.md` with `<ts>_<task>.task.md`, and `slug_exists` /
   `locate_dep_slug` match on `*_<slug>.task.md`. A fresh timestamp on the
   resume splits the pair.

4. **The picker skips an awaiting-eval task whose grader is in cooldown**
   (`grader_available`). This is a starvation guard: `select_candidate` returns
   the FIRST eligible task and a grade-only resume defers again in seconds, so
   without it one task waiting on a down judge is claimed every sweep and
   nothing behind it ever runs.

5. **Anything read after the work phase must be set OUTSIDE it.** The work phase
   is wrapped in `if [ "$GRADE_ONLY" -eq 0 ]`, and a grade-only resume skips all
   of it. `STATUS` and `MODEL_ID` are therefore initialised before the branch:
   `STATUS` is read when the verdict is logged, and `MODEL_ID` is used by the
   strategy pass on the FAIL path, which a resumed task can reach. Both were
   real `set -u` aborts during development — one archived nothing and left the
   task graded-but-unfiled in `inbox/`, the other stranded it in `run/`. If you
   add code to the work phase, check with:
   ```sh
   # every VAR assigned inside the work phase and read after it
   ```
   and hoist anything that leaks.

6. **`eval_model` outranks the task's `## Model`.** `## Model` says what it
   takes to DO the work; grading is a smaller job. Inheriting the executor's
   model priced every verdict at the cost of the work. The task's value is still
   the fallback, so a tree that sets neither key is unaffected.

The strategy pass on the second failure deliberately stays on the **executor**:
it produces advice the executor must then act on, and it runs where the
executor's provider is already loaded.

## The recurring-job engine (`ai-scheduled`)

Ported from `claude-scheduled` on 2026-08-25. Same job-file format, same
`scheduled/.state/<slug>.run` epoch-seconds format (so both engines read each
other's stamps and the cutover is a one-line cron swap), three kinds:
`template` (no agent call), `monitor` (watch + snapshot diff), `planner`
(synthesise + propose). Nine things to keep right:

1. **`is_due` returns THREE statuses and every script here runs `set -e`.**
   `0` due, `1` not due, `2` invalid schedule. "Not due" is the common case, so
   the only safe call is `rc=0; is_due "$slug" "$sched" || rc=$?`. A bare
   `is_due ...; rc=$?` reads fine and is what the unported original did, but it
   had no `set -e`; here it kills the sweep at the first job that is not due,
   and every later job silently never runs.

2. **A run that did not happen must never stamp state.** Auth failure, timeout,
   empty result, cooldown skip: all leave `<slug>.run` alone so the job is
   still due next sweep. Stamping on a failure is how a monitor goes quiet for
   a week without anyone noticing.

3. **The cooldown check is per runner, and `template` ignores it entirely.**
   `template` makes no agent call, so it must keep dispatching while a runner
   is paused. Gating it on the cooldown would stop deterministic work for a
   credential problem that cannot affect it.

4. **Each agentic job dispatches inside a subshell.** `( dispatch_monitor ... )`.
   Two jobs in one sweep may name different runners, and `load_provider` sources
   into the *current* shell: without the subshell, job B would inherit job A's
   provider functions and, if B's provider failed to load, would run on A's
   provider while logging B's name.

5. **`## Automation: auto` is the ONLY write path into `inbox/` in this repo.**
   It is a per-project opt-in that sends a `template` job's rendered task
   straight to `inbox/`, bypassing human review. It is defensible only because
   a template body is human-written and rendered verbatim. `ai-brief` has no
   such flag and must never get one; do not "unify" the two behaviours.

6. **`field_from_task` is an addition, not a replacement.** Job files use the
   inline `## Kind: value` form, task files use `## Field` + next line.
   `field_from_task` reads both, but `runner_from_task` / `model_from_task` /
   `project_from_task` must stay exactly as they are: 2267 existing task files
   depend on their precise semantics, and rerouting them through a more liberal
   parser changes how every one of them is read.

7. **`ai_preamble_extra` is deliberately NOT appended**, same as in `ai-brief`
   and for the same reason: the monitor and planner prompts have strict
   `===BLOCK===` output contracts, and the provider extras describe the shape of
   a result report, which breaks extraction.

8. **A monitor's snapshot refreshes on every conclusive run, signal or not.**
   The diff is against the last *run*, not the last *signal*. Refresh only on a
   signal and a change gets reported once when it happens and again when it
   reverts.

9. **A job file needs its `.md` extension.** The glob is `scheduled/*.md` and
   that has not changed, so dropping the extension still disables a job. What
   changed: every sweep now warns about a non-`.md` file carrying a `## Kind` or
   `## Schedule` header. `scheduled/dirty-git-trees` was invisible for a month
   because a disabled job and a missing job looked identical.

## The agent layer

Added 2026-08-26. An **agent** owns a business domain, a **routine** is one job
it performs on a trigger, and both are markdown files in git, resolved by
`agents_dir` (see point 6: **this repo ships none of them**). See
`agents/CONTRACT.md` for the full contract and `README.md` for the user-facing
description. The layer adds **no engine**: `ai-scheduled` already owns the
trigger, the kinds, the state and the routes into the pipeline. What this layer
adds is naming, a permission model and validation, so a routine file is an
`ai-scheduled` job file plus `## Agent` and `## Permission`, and publishing one
is a `cp`. Six things to keep right:

1. **Every agent-layer behaviour is gated on `## Agent` being present.** A job
   file without it must produce a **byte-identical** prompt to the pre-agent
   engine, plus the same state and the same output routes. `agent_from_job`
   prints nothing for such a file, `permission_block` and `agent_memory_block`
   return before emitting a single byte (they supply their own leading blank
   line, so an empty value adds literally nothing), and no memory line is
   written. `~/tasks/scheduled/email-triage.md` is 12KB of hand-tuned
   production prompt with no `## Agent` header; injecting a permission block or
   a PRIOR RUNS section into it would silently change a live job's behaviour,
   and the change would surface as degraded triage, not as an error.

2. **An unrecognised `## Permission` is a hard skip, never a default.**
   `permission_from_job` prints nothing and returns `1`, and the sweep logs the
   job and moves on. Defaulting would be a guess about what a routine may do to
   the world, and the two possible guesses fail in opposite, equally bad
   directions: down to `read` quietly stops a routine the human believes is
   running, up to `act` grants autonomy nobody wrote down. The default
   `propose` applies **only to an ABSENT header**, and it lives in
   `permission_from_job` alone: nothing else may re-implement it.

3. **`read` is enforced in code, not only in prose.** A monitor at `read` gets
   the no-suggestion `stub_spec` even when it declares a `## Project`, so the
   stub template is never put in front of it; a planner at `read` is skipped
   **before** the agent call, since a proposal is its only output route, and it
   stamps neither state nor memory because nothing happened. A permission that
   exists only as a sentence in a prompt is a permission the model can talk
   itself out of, and a routine reads the world, so text that arrives from there
   would be arguing with it.

4. **The memory ledger is appended only on a conclusive run, and only tail-fed
   into the prompt.** `append_agent_memory` is called exactly where
   `stamp_job_run` already is, never on a dry run, and never after an auth
   failure, a timeout, an empty result or a cooldown skip. A line claiming an
   action that never happened is read as fact by the next run, which decides the
   work is done and skips it permanently. The read side is always
   `tail -n "$AGENT_MEMORY_LINES"`, and the file is trimmed to the same bound
   after each append: an unbounded ledger grows the prompt until the routine can
   no longer see its own recent history, which is the one part it needed. A
   non-numeric or zero `agent_memory_lines` falls back to `40` rather than
   failing, because a typo in one config key must not disable every routine.

5. **`ai-agent` writes nothing and must stay that way.** No agent call, no
   `load_provider`, no file moved, nothing created under `$TASKS_DIR`, including
   in `--publish-plan`, which PRINTS the `cp` and never runs it. It is the
   second script here (with `dtask`) that is safe against the live tree, and
   that property is only worth having if it holds unconditionally: a flag that
   published "just this once" would make every future invocation something a
   human has to think about first. Publishing stays a human `cp`, because a
   routine copied into `scheduled/` is live on the next sweep, and until the
   cron swap in the cutover that sweep runs on an engine with no notion of
   `## Agent` or `## Permission`.

6. **The definitions root is resolved, not hardcoded, and this repo ships no
   agents.** `agents_dir` in `lib.sh` returns `agents_root` from `config` when
   set, otherwise this repo's `agents/`. **This repository is published
   publicly**, and a charter names a real business domain while a routine names
   the paths and reports it reads, so the real definitions live in a private
   repository and `agents/` here holds only `CONTRACT.md` and its worked
   example. Three consequences:

   - **Only `ai-agent` and `dtask` may call `agents_dir`.** The engine must not:
     `ai-scheduled` runs the **published copy** in `scheduled/`, which is what
     makes the location of a definition irrelevant to a run. A reader added to
     `ai-scheduled` or `ai-task` would couple execution to a repository that may
     not be present, and would make a routine's behaviour depend on which
     machine ran it.
   - **An explicit `agents_root` gets NO existence fallback.** Set but not a
     directory warns on stderr and returns the path anyway, so the caller
     renders its normal empty output instead of aborting under `set -e`. Falling
     back to `agents/` here would silently list, validate and print publish
     plans for the wrong set of routines. Same reason `load_provider` refuses an
     unknown runner instead of defaulting to one.
   - **Keep this repo free of real definitions, and free of the private path.**
     `config` is gitignored and is the only place that path belongs. Do not add
     an agent here to "have an example": the example in `CONTRACT.md` is
     synthetic on purpose, and it is extracted and run through
     `ai-agent --validate` to prove it is a legal routine.

The same reasoning as `ai-brief`: `ai-agent --validate` catches a routine whose
`## Permission` exceeds its charter's `## Permission-Ceiling` **before** it can
be published, because a ceiling violation discovered at run time has already
been acted on. `~/tasks/` gains no directory for any of this:
`agent_memory_path` is an additive file in the existing `scheduled/.state/`, and
definitions live in git where they can be diffed and reverted.

## Hard boundaries

These are not style preferences. Each one exists because violating it damages
something live.

- **NEVER modify anything under `~/Scripts/claude-utils/` or
  `~/Scripts/grok-utils/`.** They are read-only reference. `claude-task` is the
  orchestrator currently running these tasks from cron every 15 minutes;
  editing it mid-run is self-modification. `claude-utils` also carries
  pre-existing uncommitted work of the user's, which is expected and correct.
- **NEVER modify the user's crontab.**
- **NEVER create, move or delete symlinks in `~/bin/`.**
- **NEVER change the layout of `~/tasks/`** (no new or renamed pipeline
  directories). New state files must be additive and touched only by `ai-*`
  scripts, which are not yet in cron.
- **NEVER run `ai-task`, `ai-brief` or `ai-eval` against the live `~/tasks/`
  tree.** Smoke tests use a throwaway `TASKS_DIR` under `/tmp`. `dtask` and
  `ai-agent` are the exceptions, being read-only.
- **THIS REPOSITORY IS PUBLISHED PUBLICLY.** Nothing added here may name a
  customer, a private path, a credential, or a business domain the user actually
  works in. That is why the agent definitions live elsewhere (see The agent
  layer, point 6): a charter or a routine belongs in the private repository
  `agents_root` names, never here. `config` is gitignored and is the only place
  in this tree where that path belongs.
- **NEVER raise a routine's `## Permission`, or an agent's
  `## Permission-Ceiling`, on your own initiative,** in whichever repository the
  definitions live. Autonomy is granted per routine by a human editing that one
  file. Raising a ceiling to make a routine validate inverts the check: the
  ceiling exists to fail the routine, not to be widened until it passes.
- **Cutover is a MANUAL step for the user** (symlinks, cron lines, retiring
  `cursor-utils`). Document the exact commands in `README.md`; never execute
  them.

## What stays in claude-utils (do not port, do not delete)

Four live cron entries are **not** part of the brief-to-task pipeline and are
Claude-specific by nature: they call `mcp__claude_ai_Gmail__*` tools that have
no equivalent on the other provider.

| Entry | Schedule |
|---|---|
| `morning-briefing` | daily 07:00 |
| `ltask-cost` | weekly Mon 08:00 |
| `claude-auth-alert` | `*/30` |
| `claude-review-alert` | `*/30` |

They keep reading the same `~/tasks/` tree.

`claude-task` and `grok-task` are replaced by `ai-task`; `claude-scheduled` is
replaced by `ai-scheduled`.

**`claude-scheduled` used to be on the list above, and no longer is.** The
stated reason was that its monitor jobs are Claude-specific, and that is true of
the *jobs* but never was of the *engine*: the Gmail dependency lives in
`~/tasks/scheduled/email-triage.md`'s body, and that job has no `## Runner`
section, so `ai-scheduled` resolves it to `default_runner` and runs it on
exactly the provider it always ran on. The engine is ported (2026-08-25, at the
user's request); the job file is untouched, and must stay untouched, which is
another reason gotcha 4 must hold.

## Adding a script

1. Write it in this directory, `#!/bin/bash` + `set -euo pipefail`.
2. Source `lib.sh`, then `load_config`, then `load_provider` if it makes an
   agent call.
3. `chmod +x scriptname`
4. `bash -n scriptname`, and check it against an empty `TASKS_DIR`.
5. Verify it names no vendor (the `grep -rniE` above).
6. Document it in `README.md` (user-facing) and note any gotcha here. Adding
   an **agent or a routine** is work in the *definitions* repository, not this
   one, and the same rule applies there: run `ai-agent --validate` (it must
   print `OK:` for every charter and routine and exit `0`), document it in that
   repository's own `README.md`, and do **not** publish it into
   `~/tasks/scheduled/`: that is the human `cp` from `ai-agent --publish-plan`.
7. Do **not** install a symlink or a cron line. Document the command instead.
