# Cutover of August 2026 (historical)

> **Historical record. Do not follow it as instructions.** This page is the
> cutover plan written when this pipeline replaced two older per-provider
> pipelines on the original author's machine, in August 2026. Every path,
> symlink, cron line and tool named below is specific to that machine. It is
> also out of date: the status box below (2026-08-25) says the cron step is not
> done, but `ai-task` has since been running from cron. To install the pipeline
> on your own machine, start from the [README](../../README.md), and see
> [reference](../reference.md) for the current scripts and flags.

Three notes moved here from other README sections, for the same reason:

- `dtask` took the bare `dtask` name on 2026-08-25 (Step 3 below). It replaced
  four per-provider dashboards of the previous generation (`dtask`, `ltask`,
  `vtask`, `mtask`).
- `ai-scheduled` reads and writes the same `scheduled/.state/<slug>.run`
  epoch-seconds format as the engine it replaced, so both engines see each
  other's stamps. That is what made the cutover a one-line cron swap: no job
  re-fired because its state was reset, and none double-fired.
- Until the cron swap, the previous orchestrator kept the old project lock
  naming (the raw `## Project` token). A task using an alias dispatched by it
  and a task using the canonical name dispatched by `ai-task` could take
  different lock files and collide. The swap closed this.

## Cutover

> **⚠️ STATUS, 2026-08-25: steps 1 and 3 are DONE at the user's explicit
> request. Step 2 (cron) is NOT.**
>
> | Step | State |
> |---|---|
> | 1 · symlinks | **done**: `ai-init`, `ai-task`, `ai-eval`, `ai-brief`, `ai-briefs` installed under their bare names |
> | 3 · `dtask` collision | **done**: `~/bin/dtask` repointed at this repo; `ai-dtask` was skipped entirely |
> | 2 · cron | **not done**: the crontab is byte-for-byte unchanged, and every `*-task` / `*-brief` line in it is still commented out |
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

### Step 1: install the new symlinks

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

### Step 2: replace exactly three cron lines

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
re-fires or double-fires across the swap, but with both lines active, whichever
fires first claims each job and the other renders nothing, which reads as a job
that mysteriously stopped working.

Three things changed on purpose:

- **One binary, two invocations.** The intervals are carried over unchanged
  (`*/15` for Claude, `*/10` for Grok) so queue latency does not shift on
  cutover day. Each invocation only ever claims tasks whose resolved runner
  matches its `--runner`; a task belonging to the other runner is left in the
  inbox untouched, never silently retargeted.
- **`--runner` pins these separate schedules.** Without it either invocation
  can dispatch tasks for any configured runner.
- **Both log to `$HOME/tasks/cron.log`.** There is one tree now, so
  `$HOME/tasks-grok/cron.log` stops being written. Leave the old
  `~/tasks-grok/` directory alone until you have satisfied yourself the new
  lines are working; it is history, not state.

#### The four cron entries that must NOT change

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

### Step 3: the `dtask` name collision

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

### Step 4: retire the superseded pipeline symlinks

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

Leave these `claude-utils` symlinks in place: they are the four remaining live
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

### Step 5: retire `cursor-utils`

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
`cursor-preps` and `cursor-review-alert`: 5 + 8 = 13.

The directory itself is a separate decision, and a slower one. Archive rather
than delete, so an old task file that references a `cursor-*` path can still be
read:

```sh
mv ~/Scripts/cursor-utils ~/Scripts/.retired-cursor-utils-2026-05
```

### Step 6: verify the cutover

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

### Rollback

Nothing above is destructive to the pipeline's *state*: the `~/tasks/` tree,
`DONE.md`, every task file, and `scheduled/.state/` are untouched by any of it
(the scheduled state format is shared by both engines, so it survives a swap in
either direction). To back out, restore the three original cron lines and remove
the `ai-*` symlinks. `claude-utils` and
`grok-utils` are unmodified by this repo and remain fully functional.

## Known issues elsewhere

Found while building this repo. Both live **outside** `ai-utils` and are
deliberately **not** fixed here: `claude-utils` is read-only reference for this
project, and `claude-task` is the orchestrator that ran these very tasks.

### `~/tasks/scheduled/dirty-git-trees` has been silently skipped since 2026-07-31

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

### `tmux has-session -t NAME` prefix-matches

Not elsewhere: this one is inherited **into** this repo from both forks, and is
recorded here so it is not mistaken for a fix that landed. `ai-task:610` and
`ai-task:659` pass a bare session name, and `tmux -t NAME` matches a running
`NAME-2`. A distinct task can therefore be skipped as "already running". The fix
is `-t "=NAME"`. It did not bite either smoke run (the two sessions had
unrelated names) and is left as-is rather than changed unverified in a
documentation task.

### `claude-auth-alert` will not see a post-cutover auth stall

Covered under Step 2 above: it watches the old global
`~/tasks/.auth-cooldown`, and `ai-task` writes per-runner
`~/tasks/.auth-cooldown-<runner>` markers instead. Teaching it the new marker
shape means editing `claude-utils`, so it is a follow-up rather than part of
this cutover.
