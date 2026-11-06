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
| `dtask` | read-only dashboard across every runner (plus a `WORKTREES` section when a project opts into worktree isolation, and an `AGENTS` section when routines are defined). |
| `ai-history` | per-project history and current state. Facts rebuilt on each run; one cached agent paragraph in `$TASKS_DIR/.history/`, its only write. |
| `ai-ask` | ask one agent about its own work, from its charter and its routines' state. One agent call, writes nothing. |
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
      lib.sh init ai-task ai-eval ai-brief ai-briefs ai-scheduled dtask ai-agent \
      ai-history ai-ask
  ```
  Hits in comments that describe the abstraction are acceptable; a hit in
  executed code is a bug.
- Symlink names in `~/bin/` matter: `init` is exposed as `ai-init` to avoid
  clashing with system commands. Installing them is the user's manual step.

## The provider contract

Project instruction references are resolved by `project_instructions` in
`lib.sh` and embedded by `ai-task`, `ai-brief`, and agent-based `ai-eval`.
The legacy `## CLAUDE.md` metadata heading is an intentional exception to the
vendor-name rule in shared code: it names an existing instruction reference,
not a runner or CLI feature. `## Instructions` is the neutral alternative and
takes precedence. Resolve relative paths beside the project definition, retain
spaces, and never evaluate shell expressions. Missing references are a no-op;
unreadable explicitly referenced files warn in stderr and in the prompt.

The `codex` adapter additionally supports JSONL captures from `codex exec`.
Keep event parsing inside `providers/codex.sh`: completed-turn gating prevents
progress text from becoming a report, and structured error-event filtering
keeps tool output quoting a 401 from pausing the queue. Model strings are
passed through; an unset model uses the CLI configuration. Regression tests
are in `tests/test_codex.py` (offline, including evaluator integration), run
with `python3 -m unittest discover -s tests -v`. No shared orchestration or
live routing changes are required to load this provider.

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

## The six gotchas

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

- **The lock name is `canonical_project "$PROJECT"`, not the raw `## Project`
  token.** A project file declares aliases, and every alias is the same
  repository under another spelling (`demo-proj`, `demoproj`, `demo-project`:
  one working directory). The raw token gave each spelling its **own lock
  file**, which is a hole straight through the one guarantee this lock exists
  to provide. `canonical_project` in `lib.sh` sanitises the value (`basename` +
  `[A-Za-z0-9._-]`, since it is interpolated into a path under `$LOCK_DIR`),
  returns it unchanged when `projects/<value>.md` exists so the common case
  pays for no scan, otherwise matches it case-insensitively against every
  project's `## Aliases` bullets, and otherwise passes it through unchanged.
  `ai-task` echoes one line whenever the resolved name differs, so the
  divergence is visible in `cron.log` rather than being silent. The live tree
  really does carry values this changes — a declared hyphenation variant of one
  project and a case variant of another, lock filenames being case-sensitive —
  so this is not a hypothetical.

  Two things not to widen. **`$PROJECT` still means the raw token everywhere
  else:** the `$PROJECTS_DIR/${PROJECT}.md` read, the prompt, the log,
  `DONE.md`. A task written with a non-canonical alias also fails to *load its
  project file* today, which is the same root cause and a real defect, but
  fixing it changes the prompt delivered to tasks already sitting in the queue,
  so it is a separate task and still open. And **`project_from_task` is not the
  place for this:** it stays byte-identical, as gotcha 4's reasoning requires
  of all three parsers.

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

### 6. `ai_is_auth_failure` is TIERED. Generic 401 wording is not enough.

The circuit breaker scans the CLI's **stdout** capture as well as stderr, and
stdout holds the agent's own report. So any task that talks to a third-party API
and quotes its 401 was matching the breaker's own patterns.

That happened: `colt-unrated-live-test-0561` put COLT's refusal body
(`message: " Authentication error"`) in a results table. The breaker read it as
*this* CLI being logged out, dropped `.auth-cooldown-claude`, and paused the
runner queue. Three consecutive full re-runs of a 25-turn task, each ending in
`DEFERRED (auth failure)`, before the task reached `review/` on an unrelated
criterion. The old comment claiming "a false positive only costs a cooldown" was
wrong and has been corrected in both providers.

The function now splits its patterns:

- **strong** — only this CLI's own auth layer emits them (`API Error: 401`,
  `please run claude login`, `OAuth token expired|revoked`, `ANTHROPIC_API_KEY`;
  for grok, `XAI_API_KEY` and the session-start failure). Scanned in every
  capture.
- **broad** — generic 401/authorisation wording any vendor can emit (`HTTP 401`,
  `Unauthorized`, `authentication error`, `credentials invalid`, ...). Scanned
  **only** when the capture is not a completed result envelope.

"Completed result envelope" means `jq -r '.result'` is non-empty: proof the CLI
authenticated and the agent ran, so auth wording inside it is the agent quoting
someone else. stderr, and an empty or absent `.result`, still get the full set,
because a genuine auth failure produces no result. The signature is unchanged,
so all four call sites (`ai-task`, `ai-brief`, `ai-scheduled` x2) get the fix
without edits. `tests/fixtures/third-party-401-result.json` is the real capture
that caused this, kept as a regression case.

When adding a pattern, decide which tier it belongs in. A pattern a vendor's
error body could plausibly contain is **broad**, not strong.

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
  timeout (no retry, does **not** pause), `5` unsatisfiable criteria (no retry,
  does **not** pause, straight to `review/`). Keep `3` and `4` distinct. Do not
  renumber any of them: `ai-task` branches on every one.
- **An `UNSATISFIABLE` verdict (exit `5`) means the TASK FILE is wrong, and a
  human must fix the criterion. Retrying cannot help.** That is the entire
  reason it exists as a separate code rather than a FAIL: a criterion that
  compares against a branch nobody has moved since 2022, or asserts a count
  measured *before* the edit in a task whose job is to change what is counted,
  is a defect in the file. Graded as a FAIL it costs `max_retries` full runs to
  rediscover the same defect three times, and reaches `review/` anyway. Four
  things to keep right:
  - **The evidence gate is enforced in `ai-eval`, not only in the prompt.**
    `VERDICT: UNSATISFIABLE` earns exit `5` only when an
    `## Unsatisfiable Criteria` section is also present; without it the verdict
    falls through to `1`. Exit `5` skips the whole retry loop, so a verdict a
    human cannot re-check must not be able to reach it — otherwise the code is a
    way for an agent to declare work impossible instead of doing it. The
    fall-through direction is the safe one: it costs one retry, where the reverse
    mistake costs the task its grading entirely.
  - **The two pre-existing grading rules stay exactly as they are.** "Grade
    every criterion AS WRITTEN" and "if a criterion cannot be verified from the
    result, mark it FAIL" are both still in the prompt and are not weakened.
    *Cannot be verified* and *is demonstrably false* are different findings, and
    only the second one earns the new verdict. Softening either line turns a
    narrow exception into a charitable reinterpretation of every criterion.
  - **Partial work plus an impossible criterion is FAIL, but a SECOND
    impossible criterion is not.** Condition (c) of the prompt reads "every
    *other* criterion either PASSES, or independently satisfies (a) and (b)".
    The half it exists to enforce is the first one: without it the verdict
    becomes a way to abandon a half-finished task by finding one bad criterion
    in it. The half that was wrong until 2026-09-11 was reading it as "exactly
    one criterion may be bad", which is backwards — a task file with two false
    premises is more broken than one with a single false premise, not less.
    Measured over the 21 tasks that reached `review/`: **a single bad criterion
    earned exit `5` seven times out of seven, and two or more earned it zero
    times out of six**, and two evaluator reports name condition (c) as the
    reason in so many words. Those six tasks each spent their whole retry
    budget re-proving the same premises false. What keeps the widened condition
    honest is that evidence is **per criterion** — `## Unsatisfiable Criteria`
    takes one entry per offending criterion, each with its own command and
    output, so claiming N of them costs N demonstrations. Do not let one
    argument cover several.
  - **The `EVAL_STATUS -eq 5` branch in `ai-task` neither reads nor writes
    `## Retries`.** Do not "for consistency" add a counter bump: the attempt
    that produced the evidence did its job, and the next thing that has to
    happen is a human editing the criterion. The branch is also ordered before
    the exit-`2` normalisation, and note that the tail of that chain treats any
    *unrecognised* status as a PASS — so a new code must always get its own
    branch, never be left to fall through.
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
- **The same string must contain no unescaped `$` either.** It is expanded, so a
  `$` in prompt *content* is a parameter expansion, and under `set -u` an
  unbound name aborts the script on the spot. This has happened: an acceptance-
  criteria rule illustrating a PHP call site wrote `'if ($x = helperName('` and
  every `ai-brief --run` died with `x: unbound variable` at the closing line of
  the assignment — before `restore_brief` is ever called, so the brief was left
  stranded in `run/` with no `.raw` and no notification, and the tmux window
  closed in under a second with the message nowhere. `bash -n` passes.
  Write `\$` for a literal dollar, and note that the interpolations the prompt
  legitimately needs (`${TODAY}`, `${STAMP_RUNNER}`, `${BRIEF_ARCHIVE}`,
  `$PROJECTS_DIR`) are the only bare ones that belong there.
- **And no backticks, for the third time the same way.** A backtick in prompt
  *content* is command substitution, so the text between a pair of them is
  **executed** and replaced by its output. Writing a template field as
  `` `exact command` -> observed value `` made `ai-brief` print
  `exact: command not found` and deliver the field with the phrase silently
  deleted. `bash -n` passes, and the prompt still looks right in the source.
  Markdown habit is what makes this one likely — backticks are the natural way
  to mark a command in the prose you are writing — so note that the whole
  existing prompt contains **zero** backticks and use single quotes, as the
  rest of it does. The check that catches all three hazards is to render the
  assignment rather than read it: extract the `PREAMBLE=` block, `source` it
  with the four interpolations set, and confirm it prints no error and
  `${#PREAMBLE}` is the length you expect.
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
  the task does not own, no assertion about git working-tree state in any
  form — not whole-tree, not path-scoped, not piped through grep (every task
  shares one tree with concurrent tasks from other batches that run while it
  runs, so a path clean at generation time is dirty at execution time and no
  `## Criteria Baseline` line can license the check; assert changed-line content,
  or a `sha256sum` recorded and re-checked by the run, instead), and
  idempotency stated as "a second run creates nothing new" rather than as an
  absolute count. A criterion that a correct
  implementation cannot pass is indistinguishable from one that has not passed
  yet, so the retry loop spends every attempt on it — and an agent under
  pressure to satisfy it may mutate data outside the task's scope. See the
  README section "Acceptance criteria must be scoped to the task" for the
  case that produced this rule.
- **`lint_task_criteria` now carries a fourth shape: the git working-tree
  assertion.** The prompt rule above has been in place and still let one
  through, because the shape that got past it was the *permitted* form with its
  teeth pulled: `git diff -- <paths> | grep -E '^[+-]' | grep -v '^[+-][+-]' |
  wc -l` returns `0`. Variant (a) ends in `grep -c <pattern>` and asserts
  changed-line CONTENT; swap that last stage for `wc -l` and it counts every
  changed line again, which is tree state wearing the approved form's clothes.
  The lint only flagged it as an "asserted integer", the human read that as the
  mild warning it usually is, and `2026-09-16_june-minutes-pdf` reached `review/`
  having done its work correctly and completely: the tree held a months-old
  uncommitted `header.tex` fix that the conversion itself depended on, so the
  command returned `10` before the task started and reverting it failed the
  task's first criterion instead. So the lint fires on a `git diff|status|
  ls-files` criterion that ends in `| wc -l`, or that demands git report
  nothing (`is clean`, `lists nothing`, `no output`, `unchanged`,
  `byte-identical`), and stays silent when the line says `report`/`record`/
  `observe`, which is the one legitimate use of `git status` in a criterion.
  **Keep the `wc -l` / `grep -c` distinction when editing this rule:** it is
  the whole discriminator between the forbidden shape and the permitted one,
  and a rule that fired on both would warn on every correctly written criterion
  and be ignored accordingly.
- **And a fifth shape: a multi-word phrase greped against raw extracted
  document text.** `pdftotext` and its family hard-wrap what they emit, so a
  phrase that renders perfectly in the document arrives split across two output
  lines and the grep returns `0` for every correct run. `2026-09-17_agm-report-
  regenerate-pdf` asserted `pdftotext ... | grep -c 'Lions Christmas Party'`
  returns 1 or more; pandoc broke the line between `Christmas` and `Party`, the
  task froze the markdown, the conversion script and `header.tex` so no correct
  run could move the wrap, and it reached `review/` on exit `5` having done its
  work correctly. The fix is to join the extraction first
  (`pdftotext ... | tr '\n' ' ' | grep -c ...` returns `1`) or to grep a single
  word that cannot wrap. The lint fires on an extraction command
  (`pdftotext`/`pdftoppm`/`pdfinfo`/`catdoc`/`antiword`) piped into a `grep`
  whose pattern contains a **space**, and stays silent when the pipeline joins
  lines first (`tr` with a newline argument, `tr -d`, `paste -sd`, `grep -z`,
  `awk` with `RS=`, `sed -z`). **Keep the space in the pattern as the
  discriminator:** a single-token pattern cannot wrap, and a rule that fired on
  one would warn on every PDF task and be ignored like the asserted-integer
  one. `tests/test_criteria_lint.sh` is the offline regression test; it
  extracts the function rather than sourcing `ai-brief`, which would run the
  launcher.
- **Above those shape rules sits one measurement rule, and it is the one that
  generalises.** `MEASURE BEFORE YOU ASSERT` requires the decomposing agent to
  RUN any criterion that names a count, an absence or a git state before
  writing it, and to record the command and what it returned in a
  `## Criteria Baseline` section emitted **before** `## Acceptance Criteria`,
  so the measurements are written before the assertions that depend on them.
  The shape rules enumerate the ways criteria have gone wrong so far; of the
  21 tasks that reached `review/`, **16 were blocked by a bad criterion and
  only 1 by a genuinely wrong implementation**, across nine distinct shapes.
  Enumeration cannot keep up with that, and `ai-brief` already runs the
  decomposition inside the project working directory (`WORKDIR`, `ai-brief`
  around line 423), so the agent can simply check. One command would have
  caught each of the three worst cases: a `grep -c` asserted to return `1` on a
  file that already contained one match, a branch-range `git diff` asserted to
  list six files where it already listed 73, and a negative `grep` over paths
  the task never owned.
  Two knock-on effects, both deliberate. The section is inert to every parser
  (`section_from_task` and friends match on their own headers, and the lint
  bounds `## Acceptance Criteria` at the next `## `), and `ai-eval` passes the
  **whole** task file to the evaluator, so a recorded baseline lands in the
  grading prompt for free — which is exactly the command-and-output evidence
  that gate (a) of UNSATISFIABLE demands. Two tasks burned a retry each purely
  because attempt 1 argued impossibility in prose with no command output.
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
- **A task in `review/` permanently blocks everything downstream of it, and
  `blocked_inbox_tasks` in `lib.sh` is the ONE place that decides what counts as
  blocked.** `dep_satisfied` accepts only `done/*_<slug>.task.md`, which a
  parent in `review/` never produces, and `select_candidate` skips the
  dependent in silence — so with any other runnable work in the queue the block
  is invisible. `dtask` and `ai-task` both read the helper. Do not give either
  one its own copy of the classification: a dashboard calling a task blocked
  while the launcher is claiming it is worse than neither reporting anything.
  Three things to keep right:
  - **The helper is not runner-aware and must stay that way.** `runner_matches`
    is scoped to one invocation's `--runner`; `dtask` reports across every
    runner at once. `ai-task` layers its own runner partition on top, inside
    `report_blocked_chains`.
  - **`report_blocked_chains dead-only` must never notify.** It runs after a
    successful claim, on every sweep. A chain that is dead now will still be
    dead in fifteen minutes, so a `notify -u critical` there fires every cron
    interval until a human acts, and gets muted long before they do. The `full`
    mode on the idle branch keeps the notifications, and its output is
    byte-identical to before the extraction apart from one added hint line.
  - **`dep_satisfied` stays strict.** Accepting a parent in `review/` would
    "fix" the block by letting dependents build on work that failed evaluation.
    The block is correct; only its invisibility was the defect.
- **`ai-task --unblock` is the only supported way out of `review/`, and it
  deliberately does not inspect the task file.** It moves the file and resets
  `## Retries` to `0`; whether the criterion was actually repaired is the
  human's business, and an untouched one simply returns to `review/` on the
  next grade. The reset is the point: without it a task that burned
  `max_retries` before a human fixed its criterion lands back in `review/` on
  its first FAIL. Two things not to change. The counter is written by
  `set_retries` in `lib.sh`, **shared with the FAIL path** so a bump and a reset
  cannot drift into writing the section differently. And an ambiguous slug (two
  dated attempts of one task in `review/`) is **refused, never resolved**:
  picking one would requeue an arbitrary half of the history. It makes no agent
  call, loads no provider, and takes `.locks/inbox.lock` for the move like every
  other write into `inbox/`.
- **`## Precondition` is checked BEFORE `inbox.lock`, never inside it.**
  Added 2026-11-06 after `globeo-sftp-deploy-worker001` spent three full runs
  stopping at the same STOP step because a password only the user could
  install was missing. A check can be an ssh that takes seconds, and
  `select_candidate` runs under a lock meant to be held for milliseconds, so
  `refresh_preconditions` in `ai-task` runs the checks first and leaves
  `.precondition/<task>`; the picker only tests that the file exists, and
  `dtask` only reads it. Four things to keep right:
  - **Waiting burns nothing.** The task file is not touched, no retry, no
    feedback section. Do not "record the wait" in the task: a human promoting
    it later would read it as a failed attempt.
  - **Only tasks the picker could take are checked** (dependency met, runner
    matching). A dead chain must not ssh somewhere every sweep.
  - **One notification per wait, keyed on the status file's absence.** The
    `since:` line is carried over on every rewrite; lose it and the
    notification fires every sweep, the same reason `report_blocked_chains
    dead-only` never notifies.
  - **`dtask` never runs a check.** Opening the dashboard must not reach
    another host. `--dry-run` checks into a temporary directory, since it
    must write nothing into the tree.
  `ai-brief`'s prompt tells the decomposer to use the section instead of a
  STOP step for anything only the human can supply. Tests:
  `tests/test_task_picker.py` (`PreconditionTests`),
  `tests/test_precondition_view.sh`.
- **`dtask` is the only script here safe to run against the live tree,** because
  it is read-only: no agent call, no file move, no write into `$TASKS_DIR`.

## Worktree isolation (`## Isolation: worktree`)

Added 2026-10-29. A project file declaring `## Isolation: worktree` gets one git
worktree per BRIEF at `<repo>/.ai-worktrees/<key>/` on branch `ai/<key>`, where
the key is `worktree_key` (the `## Brief` file's name, else the task slug); see
the README section of the same name for the user-facing contract. The helpers
are in `lib.sh` (`project_isolation` through `rewrite_workdir_paths`), the
wiring in `ai-task`, `ai-eval` and `ai-brief`, the view in `dtask`, and the
offline test is `tests/test_worktree.sh`. Ten things to keep right:

1. **Everything is gated on the project opting in.** A shared project's
   `ai-task` prompt, `ai-eval` prompt, `ai-brief` prompt and `dtask` output
   are byte-identical to before. That was checked with `cmp` against the
   previous scripts, and is worth re-checking after any edit here: 2267 task
   files predate this and must not notice it. An unrecognised `## Isolation`
   value is a hard refusal to `review/`, never a default, for the same reason
   as an unrecognised `## Permission`.
2. **The project lock is NOT relaxed.** A worktree isolates files; the database,
   the container and the test ports are still shared, so gotcha 3 holds in
   full. Parallel tasks within one project would be a separate change (lock
   slots, plus per-slot databases), not a removal of the lock.
3. **Worktree state is set OUTSIDE the work phase**, right after the project
   lock, for the reason in Split grading point 5: a grade-only resume skips the
   work phase and must still grade the worktree. `AI_WORKTREE`,
   `AI_MAIN_WORKDIR` and `AI_CONTAINER_PATH` are exported there for `ai-eval`.
4. **`ai-eval` never grades the main tree for an isolated task.** It reads a
   rewritten COPY of the task file (`EVAL_TASK`), held in its own
   `EVAL_TASK_TMP` so no cleanup path can ever name the real task file. A set
   but missing `AI_WORKTREE` exits `2` rather than falling back.
5. **The path rewrite is the compatibility layer, so keep its boundaries
   strict.** It matches whole path components only (`~/Projects/demo` must not
   rewrite `~/Projects/demo-old`), never rewrites a path already under
   `.ai-worktrees/` (it must stay idempotent), and only rewrites the container
   path when the working directory is the repository top. Each of these has a
   case in `tests/test_worktree.sh`.
6. **Removal never loses work.** `worktree_remove` and `worktree_prune` refuse
   a worktree with uncommitted changes (setup artefacts excepted), branches are
   never deleted, and a directory at the target path that git does not know as
   a worktree is refused, never cleared. A commit refused by a hook keeps the
   task PASSED and the worktree on disk. Do not add `--no-verify`.
7. **Setup artefacts are recorded, not guessed.** `worktree_setup` records what
   it left untracked in the worktree's own git dir (`ai-setup-paths`, next to
   the `ai-setup-done` marker), and both `worktree_commit` and
   `worktree_dirty` read that list. Keeping bookkeeping out of the checkout is
   what stops it landing in the task's commit. Any documented setup example
   must COPY a dependency folder, never symlink it: Composer resolves its own
   real path, so a symlinked `vendor/` loads the main checkout's classes and
   the worktree's tests grade code the task never wrote. The first real run
   failed exactly this way (2026-10-29).
8. **Nothing here merges.** Landing is commit-on-branch only; the main tree is
   never touched by `ai-task`. "Merged", wherever the pipeline asks (`dtask`'s list, a
   dependent task's base), means PATCH-equivalent via `branch_unmerged`, never
   ancestry: the user merges and then pulls with `--rebase`, which rewrites the
   hash. The `ai-brief` criteria rules are deliberately
   unchanged for isolated projects, including the ban on working-tree
   assertions: relaxing them is a decision for after a pilot, and would need
   `lint_task_criteria` changed with them.
9. **One branch per brief, and a shared worktree has ONE owner.** Keyed per
   brief since 2026-10-30, after the first refactoring brief came back with
   no `## Depends-on` at all: its seven per-task branches each started from
   the base and refactored the same method four divergent ways. Keying on
   `## Brief` stacks a brief's commits whatever the decomposer wrote. Three
   things follow:
   - **`worktree_claim` guards the shared tree.** `ai-owner` (in the
     worktree's git dir, cleared by `worktree_commit`) names the task whose
     uncommitted work it holds; another task of the brief is refused while
     that tree is dirty, and a stale owner over a clean tree is replaced. Do
     not drop the dirty condition: it is how a human releases a brief by
     discarding a failed task's changes.
   - **`worktree_blocker` is the ONE rule for "waiting on a sibling",** read
     by the picker and by `dtask`, like `blocked_inbox_tasks`. The picker
     needs it as a starvation guard (same reason as `grader_available`): the
     claim would defer in seconds and `select_candidate` returns the first
     eligible task, so without it nothing behind a blocked task would run.
   - **A parent's branch is looked up by its key first, then by its slug.**
     Branches created before the per-brief key are named after the task, and
     a chain started then must keep finding them. `worktree_key` returns a
     fixed point of `worktree_slug`, because `worktree_ensure` and
     `worktree_remove` slug their argument again.
10. **The base branch is resolved by `task_base_branch`, task then brief then
    project.** Added 2026-10-30 for a customer fix that had to start from
    that customer's branch rather than the project's base. Three things:
    - **The brief is read through the task's `## Brief` path, so `ai-brief`
      is untouched.** Relying on the decomposing model to copy the line into
      every task is routing that silently regresses (same reason `ai-brief`
      stamps `## Runner` itself).
    - **An unreadable brief falls back to the project; an unresolvable name
      does not.** The first is missing metadata, the second is a branch a
      human named that does not exist, and `worktree_base_ref` refuses it
      exactly as it refuses a bad project value. Do not add a fallback there.
    - **`dtask` reads the base recorded per branch** (`branch_base`, in
      the repository's git config as `branch.ai/<key>.aiBase`), written by
      `ai-task` the first time it uses the branch, first value wins. It is
      not kept in the worktree's git dir because the worktree is pruned
      before the human merges, and it is never re-resolved from task files
      that may be archived. A branch with no record falls back to the
      project's base.

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
is a `cp`. Seven things to keep right:

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

   - **Only the viewers (`ai-agent`, `dtask`, `ai-ask`) may call
     `agents_dir`.** `ai-ask` makes an agent call but never runs a routine,
     so it is a viewer here. The engine must not:
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

7. **The operator routes (`===MESSAGE===`, `===BRIEF===`) are opt-in per
   routine, engine-delivered, and fixed-recipient.** Added 2026-10-05 so a
   routine can hold a brief-drafting conversation with the operator by email.
   A route exists only when the routine's own `## Routes` lists it, only for a
   monitor at `propose`/`act`, and is refused **in code** otherwise: do not make
   them implicit for `propose`, or every routine at that level gains a way to
   send mail without its file changing. The recipient is `agent_mail_to` from
   `config` and must never become a block field: that is the whole argument for
   these routes being `propose` rather than `act`. Messages are delivered
   **before** the snapshot is written and a failed send returns early, so the
   run stamps nothing and writes no brief; reorder that and a conversation is
   recorded as advanced when the operator was never told. Briefs go to
   `briefs/` only, never `inbox/` (the review gate), never overwriting, name
   sanitised like `ai-brief`'s. A plain job's prompt is byte-identical, and the
   gate is checked by rendering `email-triage.md` with `--dry-run
   --show-prompt` before and after. Tests: `tests/test_operator_routes.py`.

The same reasoning as `ai-brief`: `ai-agent --validate` catches a routine whose
`## Permission` exceeds its charter's `## Permission-Ceiling` **before** it can
be published, because a ceiling violation discovered at run time has already
been acted on. `~/tasks/` gains no directory for any of this:
`agent_memory_path` is an additive file in the existing `scheduled/.state/`, and
definitions live in git where they can be diffed and reverted.

## Views for the human (`ai-history`, `ai-ask`, dtask AGENTS)

Added 2026-10-30. Three ways for the user to see what the pipeline and the
agents did without reading state files. None of them feeds anything back into
a run. Tests: `tests/test_history.sh`, `tests/test_ask.sh`,
`tests/test_agents_view.sh`. Things to keep right:

1. **The `.history/` cache is written only by `ai-history`, and no task or
   routine prompt may read it.** The paragraph can be stale by design (it is
   rewritten only when the fingerprint changes, and kept when a call fails), so
   it must never become an agent's fact. The fingerprint leaves suggestions
   out: they arrive constantly and do not change where a project stands.
2. **Neither `ai-history` nor `ai-ask` touches a cooldown marker.** They are
   conveniences; an auth failure in one must not pause a queue. Both skip a
   runner that is already in cooldown, and both run their call in an empty
   temporary directory with stdout and stderr captured separately (gotcha 1).
3. **`ai-history` counts only `done/*.task.md` as finished,** and gives each
   branch the base of its brief, like `task_base_branch`.
4. **`ai-ask` writes nothing, and its read-only property is the empty
   directory plus the prompt, not the provider.** Both providers run headless
   with permissions bypassed. Do not describe it as more than that; a true
   no-tools mode is a provider-contract change. It shows a routine's
   PUBLISHED copy when there is one (that is what runs), caps each part of
   the context so one large snapshot cannot crowd out the rest, and refuses
   any agent name outside `[a-z0-9-]` before building a path.
5. **dtask AGENTS judges the published copy and reads only existing state**
   (`<slug>.run`, the memory ledger via `agent_memory_summary`). Overdue means
   no run for two periods (`schedule_period_sec`) plus an hour. The ledger
   records conclusive runs only, so a failing routine shows as overdue; adding
   a "failed" state needs a new stamp written by `ai-scheduled`, not a guess
   from `cron.log`. A tree with no routine must render byte-identically, which
   the test checks against the previous `dtask`.
6. **dtask rows are joined by `$US` (0x1f), not a tab.** A tab is IFS
   whitespace, so `read` merges an empty field (the colour, under `NO_COLOR`)
   with its neighbour and shifts every field after it. WORKTREES had exactly
   this bug.

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
  `ai-agent` are the exceptions, being read-only. `ai-history` (writes only
  its cache in `.history/`) and `ai-ask` (writes nothing) move no task either,
  but each costs one agent call.
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

## Notes moved from the old README (2026-10-30)

The README was split into a short page plus `docs/` on 2026-10-30. User rules
now live in `docs/`; the design reasoning below left the README with them and
was not yet written down here. Two references earlier in this file still point
at README sections that no longer exist:

- "See the README section 'Acceptance criteria must be scoped to the task'"
  (in Other things to watch out for): the user checklist is now
  `docs/writing-briefs.md`, and the case behind the first scoping rule is the
  first bullet below.
- "Document the exact commands in `README.md`" (Hard boundaries, cutover): the
  original cutover is now the historical page `docs/history/cutover-2026-08.md`,
  and the generic symlink and cron commands for a new install are in
  `docs/getting-started.md`. Document new manual steps there.

The reasoning that moved:

- **Why baseline-plus-delta criteria are banned.** Both halves are unsafe. The
  baseline moves if anything else touches the data between decomposition and
  execution, and the delta is a guess exploration cannot fully verify. The
  case that prompted the rule asserted `439 + 143`: two product labels that
  differed only in one letter's case folded into a single row under a
  case-insensitive collation, so 143 new items could only ever be 142.
- **The `ai-brief` repair pass.** Before extraction, `ai-brief` validates the
  draft and makes ONE repair call when it finds a risky criterion (a clean git
  state assertion, including `git -C` and multiline checklist items; a phrase
  search on wrapped extracted text; an abbreviated command with an ellipsis; a
  missing acceptance checklist) or malformed task delimiters. The repair uses
  the same provider and model, gets the brief, the draft and the findings, and
  shares the original `brief_timeout_min` budget, so an ordinary valid draft
  still costs one call. If the repair fails, still trips validation, or
  changes task filenames, nothing is extracted: the brief returns to
  `briefs/` and the draft plus findings go to a `.raw` file under `run/`. An
  auth failure during repair sets that provider's cooldown. A repaired draft
  goes through the normal runner stamp, graph check and human review gate.
  It is a check for known risky shapes, not a proof that every criterion is
  satisfiable.
- **`dtask` RECENT ACTIVITY resolves each entry's runner in a fixed order:**
  the `## Runner` of the archived `<base>.task.md` beside the result, then the
  result file's own `**Runner:**` line, then `default_runner`. The order is
  load-bearing. `DONE.md`'s `**Result:**` path names the result file, which
  carries the runner as a bold field, not a `## Runner` heading; resolving it
  directly found nothing and rendered every archived entry as
  `default_runner`. The end-to-end smoke run caught it: a task that ran on one
  provider displayed as the other.
- **A dangling `## Awaiting-Eval` pointer never wedges a task.** If the named
  report is gone, the section is stripped, the reason printed, and the task
  runs normally. Leaving it in place would make every claim a grade-only
  resume of a report that cannot be found.
- **`ai-eval` exit `3` never emits a verdict line.** An empty evaluator
  response is inconclusive, not a FAIL, and partial text is reported with its
  `VERDICT:` lines stripped so the caller's grep cannot mistake a half-finished
  run for a decision.
- **A grader runner that cannot be loaded exits `3`, not `1`.** A missing
  adapter is a configuration fault; exit `1` would burn a retry on every task
  in the queue for it.
- **Cross-provider grading costs real retries, and two things bound it.**
  `## Test Command` runs before the grading call, so objective failures never
  reach the judge. And the judge should stay fixed rather than alternate
  between providers, so verdicts stay comparable from one attempt to the next.
- **`ai-task` with no `ai-eval` installed records the run ungraded, not
  failed.** A missing grader is not evidence that the work is wrong.
- **Open follow-up outside this repo: the auth alert watches the old marker.**
  The `claude-auth-alert` cron entry (see What stays in claude-utils) watches
  the old global `$TASKS_DIR/.auth-cooldown`, while `ai-task` writes
  `.auth-cooldown-<runner>`. Since the cutover it does not see a pipeline auth
  stall; `dtask`'s per-runner banner is the only signal until the alert is
  taught the per-runner markers, which means editing `claude-utils` and is
  therefore the user's call.
