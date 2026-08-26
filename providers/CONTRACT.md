# Provider contract

Every runner is one file: `providers/<runner>.sh`, sourced by `ai-task` / `ai-eval`
/ `ai-brief` after `lib.sh` and after `load_config`. The runner name comes from
`runner_from_task` (a `## Runner` section on the task, defaulting to
`default_runner` in `config`), so the file name **is** the runner name:
`providers/claude.sh` → runner `claude`, `providers/grok.sh` → runner `grok`.

A provider file must define exactly these six functions and nothing else that
the callers rely on. It must not read task files, move files, write to
`DONE.md`, or touch the cooldown marker: that orchestration stays in `ai-*`.

Nothing outside `providers/` may name a vendor, a vendor CLI, a vendor model id,
or a vendor JSON field. Two consequences worth stating up front, because they
are the two things the forks got wrong most often:

* **The result field differs per provider.** Claude's headless JSON puts the
  agent's answer in `.result`. Grok's puts it in `.text`. Neither string may
  appear outside `providers/`; callers only ever call `ai_json_text`.
* **Captures must always separate stdout and stderr.** Always
  `> "$json_out" 2> "$err_out"`, **never** `2>&1`. Merged stderr prepends
  warnings (workspace-trust notices, deprecation warnings) to the JSON, `jq`
  then fails, and the result report silently comes out empty. Auth detection
  scans both files, which is why both must survive as separate files.

---

## 1. `ai_run`

Run one headless agent call to completion and capture it.

```
ai_run PROMPT MODEL_ID WORKDIR TIMEOUT_SEC JSON_OUT ERR_OUT
```

| arg | meaning |
|-----|---------|
| `PROMPT` | full prompt text (preamble + task body), passed as one argument |
| `MODEL_ID` | model id or alias, already resolved by the caller from `## Model` / `default_model`; **empty string means "provider default"** |
| `WORKDIR` | absolute working directory for the run, or empty for "do not set one" |
| `TIMEOUT_SEC` | hard wall-clock cap in seconds; the provider wraps its CLI in `timeout` |
| `JSON_OUT` | path the provider writes the CLI's raw stdout (the JSON document) to |
| `ERR_OUT` | path the provider writes the CLI's raw stderr to |

**stdout:** nothing. Everything goes to `JSON_OUT` / `ERR_OUT`.

**return code:** the CLI's exit status, verbatim and unmodified, including
`124` from `timeout`. Callers depend on `124` to distinguish "timed out" from
"failed"; a provider must not normalise it to 1. `set +e` around the call and
`set -e` after is the provider's responsibility, not the caller's.

The provider owns every vendor flag: the permission-bypass flag
(`--dangerously-skip-permissions` for Claude, `--always-approve` for Grok), the
model flag, the working-directory flag (Claude has none, so the provider `cd`s
or exports; Grok passes `--cwd`), and the JSON output flag
(`--output-format json` for both today). It passes the model flag only when
`MODEL_ID` is non-empty, and builds flags in a bash array so a value never
undergoes word splitting or globbing.

## 2. `ai_json_text`

Extract the agent's response text from a captured JSON file.

```
ai_json_text JSON_FILE
```

**stdout:** the response text, possibly multi-line, with no trailing decoration.
Empty output when the file is missing, is not valid JSON, or the field is
absent or `null` — this is the normal case for an interrupted or killed run and
must not be an error.

**return code:** `0` whenever the file was readable, even if the text is empty;
non-zero only if `JSON_FILE` does not exist. Callers test emptiness with
`[ -n "$(ai_json_text "$f")" ]`, so they never depend on the exit code to mean
"had text".

Implementation is one `jq -r` per provider: `.result // empty` for Claude,
`.text // empty` for Grok. A provider may keep the other provider's field as a
secondary fallback (`.text // .result // empty`) to survive a mis-routed
capture, but its own field must come first.

## 3. `ai_usage_table`

Render a markdown `## Token Usage` section for the result report.

```
ai_usage_table JSON_FILE OUT_FILE
```

**stdout:** nothing; the section is written to `OUT_FILE`, overwriting it.

**return code:** `0` always, including when the JSON carries no usage data.
Cost reporting must never fail a task. When `modelUsage` is missing or empty
the provider still emits a well-formed table with a placeholder row, so the
report never contains a dangling header.

The section starts with the literal line `## Token Usage`, then a blank line,
then a markdown table, then a `**Total cost:** $<n>` line. Columns are the
provider's choice, because the providers genuinely report different fields:
Claude has both cache-read and cache-write plus `num_turns`, Grok reports
neither reliably. Every value is read with a `// "n/a"` fallback. Any extra
trailing lines the provider wants (session id, turns) come after the total.

`ai-task` inserts the file's contents into the result report immediately before
`## Suggested Commit Message`, or appends it at the end when that heading is
absent, so `OUT_FILE` must be a self-contained fragment with no leading blank
line.

## 4. `ai_is_auth_failure`

Decide whether a captured file shows an authentication or credentials failure.

```
ai_is_auth_failure FILE
```

Called once on the JSON capture and once on the stderr capture; either hit
means "auth failure". This is the circuit breaker: an auth failure means **no
work happened**, so the task is requeued to `inbox/` without burning a retry
and `cooldown_path <runner>` is touched to pause only that runner's queue.

**stdout:** nothing.

**return code:** `0` if the file exists and matches an auth-failure signature,
`1` otherwise — including when the file does not exist, so a missing capture is
never read as an auth failure.

The signature set is per provider and deliberately broad, since a false
negative burns retries on a task that never ran. Claude's live patterns:
`API Error: 401`, `Invalid authentication credentials`,
`OAuth token (has )?expired`, `Failed to authenticate`. Grok's add xAI and
generic HTTP wording: `HTTP 401`, `status.?401`, `Unauthorized`,
`XAI_API_KEY`, `invalid.?api.?key`, `missing.?api.?key`,
`auth.*(expired|invalid)`, `couldn.?t (start|create) session`. Match
case-insensitively (`grep -qiE`).

## 5. `ai_model_alias`

Map a short alias from a task's `## Model` section to a real model id.

```
ai_model_alias RAW
```

**stdout:** the model id to hand to `ai_run`, or empty for "use the provider
default". `RAW` is already whitespace-stripped by `model_from_task`.

**return code:** `0` always. An unrecognised value is not an error: it is
echoed back unchanged, so a task can name any model id the CLI accepts without
the alias table having to know it.

This is where the fork-specific tables move to. Claude's:
`opus`→`opus`, `opus1m`→`claude-opus-5[1m]`, `sonnet`→`sonnet`,
`haiku`→`haiku`, `fable`→`fable`, empty→`opus` (Claude always passes an
explicit `--model`). Grok's: `build`→`grok-build`, empty→empty (no `--model`
flag at all, let the CLI pick). Note the two differ on the empty case, which is
exactly why the caller must not special-case it.

## 6. `ai_preamble_extra`

Provider-specific additions to the autonomous-mode preamble.

```
ai_preamble_extra TASK_FILE
```

**stdout:** text to append to the shared preamble, or nothing. Multi-line is
fine. The caller joins it to the shared preamble with a blank line and does not
inspect it.

**return code:** `0` always, empty output included.

The shared preamble in `ai-task` stays vendor-neutral: no-questions, no-waiting,
`## Summary`, `## Suggested Commit Message`, and the never-revert-other-tasks'-work
rule. Anything that names a vendor feature belongs here. Claude's: the
`## Tools Used` section listing invoked agents and skills (Grok has no
`~/.claude/agents/`), the instruction to check skills before starting, and the
`ultracode: ` workflow prefix when the task carries a `## Workflow` section.
Grok's is empty today.

`TASK_FILE` is passed so the provider can inspect task sections (that is how
the `## Workflow` prefix is detected). The provider must only read it, never
modify it.

---

## Loading

```bash
RUNNER=$(runner_from_task "$TASK_FILE") || { echo "no runner and no default_runner in config"; exit 1; }
PROVIDER="$SCRIPT_DIR/providers/${RUNNER}.sh"
[ -f "$PROVIDER" ] || { echo "unknown runner '$RUNNER' (no $PROVIDER)"; exit 1; }
# shellcheck disable=SC1090
source "$PROVIDER"
```

A provider that fails to define all six functions is a broken provider; callers
may check with `declare -F ai_run` and refuse to run rather than fall back to a
default, since falling back would silently send a task to the wrong vendor.
