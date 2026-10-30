# README map

Temporary working file for the README split: one row per real heading of `README.md` (HEAD 5b31d89, 1921 lines), saying where its content goes. It drives tasks 2 to 4 of the split and is deleted by the last task. Headings that contain a long dash are written here with ':' instead.

| Line | Heading | Destination | Status | Reason |
|---|---|---|---|---|
| 1 | # ai-utils | README.md | moved | One-paragraph intro for the new README; drop the claude-utils/grok-utils origin and the private `~/tasks/projects/ai-utils.md` pointer (line 10). |
| 13 | ## The pipeline | README.md | moved | Both loop diagrams stay in the README; the push-side diagram is also repeated in docs/scheduled-jobs.md, with the `<brain_root>/personal/journal/` path made generic. |
| 75 | ## Scripts | docs/reference.md | moved | Full scripts table to reference.md, short list in README; the dtask "owns the bare name as of 2026-08-25" note goes to the history page. |
| 93 | ## Setup | docs/getting-started.md | moved | Install steps (init, config, TASKS_DIR override for throwaway trees); the 3-line quick start is also shown in the README. |
| 108 | ## Referenced project instructions | docs/configuration.md | moved | Brief puts referenced project instructions in configuration.md; the `## Instructions` / `## CLAUDE.md` project fields are listed in reference.md. |
| 133 | ## Codex runner | docs/configuration.md | merged into docs/configuration.md | Becomes a subsection of "Runners and providers"; the offline test command goes to reference.md. |
| 188 | ## Configuration | docs/configuration.md | moved | Every config key row moves verbatim; the "per-task sections override config" sentence (221) goes to reference.md task fields. |
| 224 | ## `ai-task` | docs/reference.md | moved | Every ai-task flag (--runner, path, --dry-run, --unblock, --prune-worktrees, --run) goes to the reference scripts and flags section. |
| 240 | ### The `--runner` flag | docs/reference.md | merged into docs/reference.md | Runner resolution order and tmux session naming merge into the ai-task flags section; the rule itself is already in CLAUDE.md gotcha 4. |
| 257 | ### New behaviour 1: runner filtering in the picker | docs/reference.md | merged into docs/reference.md | Picker behaviour (oldest eligible task, per-runner availability, explicit path bypasses filter) kept; the "new behaviour" framing is history and dropped. |
| 270 | ### New behaviour 2: atomic inbox claim | docs/reference.md | merged into docs/reference.md | One line on the inbox claim lock goes to Locks and markers; the "previously" story and ai-task line numbers are already covered by CLAUDE.md gotcha 3. |
| 284 | ### Locks and markers | docs/reference.md | moved | Lock and marker table, as is. |
| 292 | ### Outcomes | docs/reviewing-tasks.md | moved | Outcome and retry table is what a reviewer needs; reference.md links to it. |
| 304 | #### Alias-safe project locks | docs/reference.md | merged into docs/reference.md | User rule (aliases share one lock) goes to Locks and `## Aliases` field; design story already in CLAUDE.md gotcha 3; the old-orchestrator transition limitation (340) goes to the history page; DONE.md Runner/Graded by lines and run/<task>.state sidecar (348-352) go to reference.md. |
| 354 | ### Follow-up suggestions (`suggest_enabled`, `suggest_max`) | docs/reviewing-tasks.md | moved | Suggestions are a reading pile the reviewer handles; keys in configuration.md, `## Relationships` field in reference.md; line 380 needs a generic rewrite. |
| 397 | ### Worktree isolation (`## Isolation: worktree`) | docs/worktrees.md | moved | Whole section incl. per-brief base branch; the Composer/Pest incident is already in CLAUDE.md worktree point 7, keep only the "copy, never symlink" rule. |
| 515 | ### `## Awaiting-Eval`: never execute finished work twice | docs/configuration.md | merged into docs/configuration.md | User behaviour goes to the split grading section; the field goes to reference.md task fields; the dangling-pointer rule is not in CLAUDE.md (see notes). |
| 550 | ## `ai-eval` | docs/reference.md | moved | ai-eval usage and flags (TASK_FILE RESULT_FILE [out], --runner, --model). |
| 561 | ### Exit codes | docs/reference.md | moved | Exit codes 0 to 5 table, verbatim, plus the exit 3 no-verdict-line rule. |
| 582 | ### Test commands | docs/reference.md | moved | `## Test Command` field semantics (order, timeout, fence skip, backslash continuation); the brief writer page links here. |
| 599 | ### The evaluator's stance | docs/writing-briefs.md | moved | Criteria are graded literally, which is what a brief writer must know; the hostile-prompt detail is not in CLAUDE.md (see notes). |
| 613 | ### Unsatisfiable criteria (exit `5`) | docs/reviewing-tasks.md | moved | What exit 5 means for a reviewer and how to fix the task file; the 7/7 and 0/6 history and evidence gate reasoning are already in CLAUDE.md, exit code row in reference.md. |
| 669 | ### The `--runner` flag | docs/configuration.md | merged into docs/configuration.md | Grader runner/model resolution table belongs to split grading; the --runner/--model flags are listed in reference.md; reasoning already in CLAUDE.md Split grading. |
| 712 | ## `ai-brief` / `ai-briefs` | docs/reference.md | moved | Flags to reference.md; the daily "drop a brief, run ai-brief" usage is shown in docs/writing-briefs.md. |
| 729 | ### The flow, and the review gate | docs/reviewing-tasks.md | moved | The review gate is the reviewer's job; ai-brief line numbers and filename sanitising are already in CLAUDE.md, brief archive/restore behaviour kept. |
| 756 | ### `## Runner` on every emitted task | docs/reference.md | moved | Stamped-runner resolution table goes with the `## Runner` field; reasoning already in CLAUDE.md. |
| 787 | ### Acceptance criteria must be measured, not predicted | docs/writing-briefs.md | moved | Becomes the first checklist item (Criteria Baseline, DEFERRED); the 16 of 21 statistics are already in CLAUDE.md. |
| 816 | ### Acceptance criteria must be scoped to the task | docs/writing-briefs.md | moved | The don't/write-instead table becomes the checklist; incident stories go to CLAUDE.md where missing (see notes); repair pass and lint warnings split: user view in writing-briefs.md, design in CLAUDE.md; lines 828 and 841-843 need rewriting. |
| 926 | ### One parent per task | docs/writing-briefs.md | moved | One-line rule plus example in the checklist; reasoning already in CLAUDE.md gotcha 5. |
| 939 | ### Dead dependency chains | docs/reviewing-tasks.md | moved | What a blocked task looks like in dtask and what to do; helper design already in CLAUDE.md; the sample output slugs need a generic rewrite. |
| 994 | ### Clearing a dead chain: `ai-task --unblock` | docs/reviewing-tasks.md | moved | --unblock usage and behaviour table; flag also listed in reference.md. |
| 1026 | ### `repair_brief_task_graph` | docs/reference.md | moved | Graph problem/outcome table; the grok-utils origin remark is history and dropped. |
| 1043 | ### Notes | docs/configuration.md | merged into docs/configuration.md | brief_timeout_min to the config key table; ai_preamble_extra note already in CLAUDE.md; "symlinks and cron are manual" goes to getting-started.md. |
| 1055 | ## `ai-scheduled` | docs/scheduled-jobs.md | moved | Intro and flags (--job, --force, --dry-run, --runner); flags also listed in reference.md. |
| 1075 | ### Job files | docs/scheduled-jobs.md | moved | Job file fields; the dirty-git-trees story is already in CLAUDE.md engine point 9 and goes to the history page, keep only the ".md required" rule. |
| 1098 | ### Schedules | docs/scheduled-jobs.md | moved | Schedule values table, as is. |
| 1111 | ### Kinds | docs/scheduled-jobs.md | moved | template, monitor, planner; brain_root path made generic. |
| 1145 | ### State | docs/scheduled-jobs.md | moved | State file table; the "same format as the replaced engine" sentence goes to the history page. |
| 1162 | ### The review gate, and its one exception | docs/scheduled-jobs.md | moved | `## Automation: auto` behaviour; the project field is also listed in reference.md. |
| 1174 | ### Runners and cooldown | docs/scheduled-jobs.md | moved | Runner resolution and per-runner cooldown for jobs; subshell detail already in CLAUDE.md engine point 4. |
| 1192 | ### Adding a job | docs/scheduled-jobs.md | moved | Example job and dry-run check, with `~/tasks/` stated as an example path. |
| 1210 | ## The agent layer (`ai-agent`) | docs/scheduled-jobs.md | moved | Agent layer intro, second half of the page. |
| 1229 | ### Layout | docs/scheduled-jobs.md | moved | Definitions layout and slug rules; links to agents/CONTRACT.md. |
| 1252 | ### Where definitions live | docs/scheduled-jobs.md | moved | agents_root usage; the key row is in configuration.md; reasoning already in CLAUDE.md agent layer point 6. |
| 1288 | ### The charter, `<agents-root>/<agent>/AGENT.md` | docs/scheduled-jobs.md | moved | Charter fields table. |
| 1310 | ### Routine files, `<agents-root>/<agent>/routines/<slug>.md` | docs/scheduled-jobs.md | moved | Routine fields table (Agent, Permission, Routes). |
| 1345 | ### The three permission levels | docs/scheduled-jobs.md | moved | Levels table and enforcement; reasoning already in CLAUDE.md agent layer points 2 and 3. |
| 1383 | ### Operator routes | docs/scheduled-jobs.md | moved | Block format and delivery rules; agent_mail_* keys in configuration.md. |
| 1429 | ### The memory ledger | docs/scheduled-jobs.md | moved | Ledger format and agent_memory_lines bound. |
| 1453 | ### `ai-agent` | docs/scheduled-jobs.md | moved | ai-agent flags and what --validate checks; flags also listed in reference.md. |
| 1478 | ### Publishing is a manual step | docs/scheduled-jobs.md | moved | Publish procedure; the "until Step 2 of the cutover" warning is obsolete and dropped from this page. |
| 1502 | ### What is next | docs/scheduled-jobs.md | merged into docs/scheduled-jobs.md | Becomes a short "adding an agent" paragraph; the "no engine change" property is already in CLAUDE.md agent layer intro. |
| 1514 | ## `dtask` | docs/reference.md | moved | Usage, keys and sections; the DONE.md runner resolution story goes to CLAUDE.md (see notes); the four replaced dashboards and the symlink collision go to the history page. |
| 1583 | # Cutover | docs/history/cutover-2026-08.md | moved | Marked historical and out of date at the top (its status box says cron is not done; ai-task now runs from cron). |
| 1605 | ## Step 1: install the new symlinks | docs/history/cutover-2026-08.md | moved | Historical record; the generic symlink/PATH instructions are rewritten fresh in getting-started.md. |
| 1638 | ## Step 2: replace exactly three cron lines | docs/history/cutover-2026-08.md | moved | Historical record; generic cron lines (shown, never installed) are rewritten in getting-started.md. |
| 1685 | ### The four cron entries that must NOT change | docs/history/cutover-2026-08.md | moved | Historical; the same list is already in CLAUDE.md "What stays in claude-utils". |
| 1727 | ## Step 3: the `dtask` name collision | docs/history/cutover-2026-08.md | moved | Historical record of the symlink repoint. |
| 1765 | ## Step 4: retire the superseded pipeline symlinks | docs/history/cutover-2026-08.md | moved | Historical record. |
| 1797 | ## Step 5: retire `cursor-utils` | docs/history/cutover-2026-08.md | moved | Historical record. |
| 1831 | ## Step 6: verify the cutover | docs/history/cutover-2026-08.md | moved | Historical record. |
| 1850 | ## Rollback | docs/history/cutover-2026-08.md | moved | Historical record. |
| 1861 | # Known issues elsewhere | docs/history/cutover-2026-08.md | moved | Dated incident notes go to the history page. |
| 1867 | ## `~/tasks/scheduled/dirty-git-trees` has been silently skipped since 2026-07-31 | docs/history/cutover-2026-08.md | moved | Dated incident; the resulting warning rule is already in CLAUDE.md engine point 9. |
| 1905 | ## `tmux has-session -t NAME` prefix-matches | docs/history/cutover-2026-08.md | moved | Dated note; the open bug is already tracked in CLAUDE.md "Other things to watch out for". |
| 1915 | ## `claude-auth-alert` will not see a post-cutover auth stall | docs/history/cutover-2026-08.md | moved | Dated note about a tool outside this repo; CLAUDE.md only lists the alert, not this gap (see notes). |

## Notes for the next tasks

Content needing a generic rewrite before it reaches a user page (public repository):

- Lines 379 and 380: both `## Relationships` example targets are real private project names. Use `demo-site` / `demo-admin` style names.
- Lines 841 to 843: the two task slugs and the `.env` path name a customer integration. Keep the story out of user pages (CLAUDE.md already names that integration); use a generic `.env` example in the checklist (line 827 uses the same path).
- Lines 828 and 853 to 859: the greped phrase and the two task slugs come from a personal domain. The checklist example should use a neutral phrase such as `'Annual Report Summary'`.
- Lines 967 to 968 and 997 to 1002: the sample dtask and --unblock output uses real task slugs from a business domain. Use `demo-fix` / `demo-follow-up`.
- Line 10: pointer to the private `~/tasks/projects/ai-utils.md`. Drop it.
- Lines 67 and 1123, and the `brain_root` key (218): `<brain_root>/personal/journal/` is a personal notes layout. Describe it as "a notes folder under brain_root"; the key and its default stay documented.
- History page (from 1583): it names the author's crontab, `~/bin/` symlinks and private tools (`ltask-cost`, `morning-briefing`, `claude-prep`, `x-post`, `email-triage`). It is allowed as a historical record, but scrub anything naming a customer, and say at the top that the paths are the original author's machine.
- Write `~/tasks/` and `~/Scripts/ai-utils/` as example paths a reader can change, and say so once (brief rule).

Not yet covered by CLAUDE.md, to append in task 4 (append only, do not rewrite existing sections):

- The baseline-plus-delta incident behind the first scoping rule (lines 830 to 835): `439 + 143`, two labels differing in case folded into one row under a case-insensitive collation, so 143 new items could only ever be 142. CLAUDE.md has the four-run damage story but not this cause.
- CLAUDE.md's "Acceptance criteria in the decomposition prompt" bullet points readers to the README section "Acceptance criteria must be scoped to the task" for the case. That section is leaving the README: repoint the reference to the new CLAUDE.md text (or docs/writing-briefs.md).
- The ai-brief repair pass (lines 861 to 883): one repair call on a draft with risky criteria or malformed delimiters, same provider and model, shared `brief_timeout_min` budget; on failure or a filename change nothing is extracted, the brief returns to `briefs/` and the draft plus findings go to a `.raw` in `run/`; an auth failure sets the cooldown. Not in CLAUDE.md.
- `dtask` RECENT ACTIVITY runner resolution order (lines 1562 to 1573): archived `<base>.task.md` `## Runner`, then the result file's `**Runner:**`, then `default_runner`; resolving the `**Result:**` path directly rendered every entry as the default runner, caught by the smoke run. Not in CLAUDE.md.
- `## Awaiting-Eval` dangling pointer (line 537): if the named report is gone the section is stripped, the reason printed, and the task runs normally. Not in CLAUDE.md.
- ai-eval details (lines 578 to 580, 704 to 706): exit 3 never emits a verdict line and partial text has its `VERDICT:` lines stripped; a runner that cannot be loaded exits 3, not 1, so a missing adapter never burns retries queue-wide. Not in CLAUDE.md.
- Cross-provider grading cost (lines 698 to 702): `## Test Command` runs before the judge, and the judge should stay fixed rather than alternate so verdicts stay comparable. Not in CLAUDE.md.
- `ai-task` with no `ai-eval` installed records the run ungraded rather than failed (line 547). Not in CLAUDE.md.
- `claude-auth-alert` still watches the old global `.auth-cooldown` marker, so it does not see per-runner stalls (lines 1721 to 1725, 1915 to 1921): an open follow-up outside this repo, worth one line in CLAUDE.md since the history page is not where open work should live.
- Nothing in this map is "dropped, obsolete" as a whole heading: every config key, flag, exit code and file field has a destination. Only sentences are dropped (the "new behaviour" framing, the grok-utils origin of `repair_brief_task_graph`, the cutover Step 2 warning in "Publishing is a manual step").
