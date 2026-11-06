"""Offline launcher tests; tmux is stubbed and no agents are executed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PickerHarness:
    """Throwaway tree, stub providers and stub tmux; holds no tests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('ai-task', 'lib.sh'):
            shutil.copy2(ROOT / name, self.root / name)
        providers = self.root / 'providers'
        providers.mkdir()
        for runner in ('alpha', 'beta'):
            (providers / f'{runner}.sh').write_text('\n'.join(
                f'{fn}() {{ :; }}' for fn in (
                    'ai_run', 'ai_json_text', 'ai_usage_table',
                    'ai_is_auth_failure', 'ai_model_alias', 'ai_preamble_extra')))
        (self.root / 'config').write_text('default_runner=alpha\n')
        self.tasks = self.root / 'tasks'
        self.inbox = self.tasks / 'inbox'
        self.inbox.mkdir(parents=True)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        tmux = bin_dir / 'tmux'
        tmux.write_text('''#!/bin/bash
if [ "$1" = has-session ]; then
    [ "$3" = "${ACTIVE_SESSION:-}" ]
else
    printf '%s\\n' "$@" > "$TMUX_CAPTURE"
fi
''')
        tmux.chmod(0o755)
        self.env = dict(os.environ, TASKS_DIR=str(self.tasks),
                        PATH=f'{bin_dir}:{os.environ["PATH"]}',
                        TMUX_CAPTURE=str(self.root / 'tmux.txt'))

    def task(self, name, runner=None, extra=''):
        path = self.inbox / f'{name}.md'
        path.write_text(f'# {name}\n' + (f'\n## Runner\n{runner}\n' if runner else '') + extra)
        os.utime(path, (100 + len(list(self.inbox.iterdir())),) * 2)
        return path

    def call(self, *args):
        return subprocess.run([str(self.root / 'ai-task'), *args],
                              env=self.env, capture_output=True, text=True)


class TaskPickerTests(PickerHarness, unittest.TestCase):
    def test_automatic_dispatch_records_and_passes_task_runner(self):
        task = self.task('first', 'beta')
        dry = self.call('--dry-run')
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn('runner: beta', dry.stdout)
        self.assertTrue(task.exists())
        result = self.call()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(task.exists())
        self.assertIn('runner=beta', (self.tasks / 'run/first.state').read_text())
        launched = (self.root / 'tmux.txt').read_text()
        self.assertIn('ai-beta-first', launched)
        self.assertIn('--runner beta', launched)

    def test_explicit_filter_and_default_fallback(self):
        other = self.task('first', 'beta')
        default = self.task('second')
        result = self.call('--runner', 'alpha', '--dry-run')
        self.assertIn(f'would claim: {default}', result.stdout)
        self.assertTrue(other.exists())

    def test_cooldown_is_per_candidate(self):
        self.task('first', 'alpha')
        second = self.task('second', 'beta')
        (self.tasks / '.auth-cooldown-alpha').touch()
        result = self.call('--dry-run')
        self.assertIn(f'would claim: {second}', result.stdout)
        (self.tasks / '.auth-cooldown-beta').touch()
        self.assertEqual(self.call('--dry-run').returncode, 1)

    def test_session_check_uses_task_runner(self):
        self.task('first', 'beta')
        second = self.task('second', 'alpha')
        self.env['ACTIVE_SESSION'] = 'ai-beta-first'
        self.assertIn(f'would claim: {second}', self.call('--dry-run').stdout)

    def test_unknown_provider_does_not_strand_or_block_other_tasks(self):
        invalid = self.task('first', 'missing')
        second = self.task('second', 'beta')
        result = self.call('--dry-run')
        self.assertIn("unknown runner 'missing'", result.stderr)
        self.assertIn(f'would claim: {second}', result.stdout)
        self.assertTrue(invalid.exists())

    def test_named_task_does_not_need_valid_default_and_allows_override(self):
        (self.root / 'config').write_text('default_runner=missing\n')
        task = self.task('first', 'beta')
        self.assertIn('runner: beta', self.call('--dry-run').stdout)
        result = self.call(str(task), '--runner', 'alpha')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('runner=alpha', (self.tasks / 'run/first.state').read_text())

    def test_dependency_and_grader_cooldown_are_preserved(self):
        self.task('first', 'beta', '\n## Depends-on\nmissing\n')
        self.task('second', 'beta', '\n## Awaiting-Eval\nreport.md\n')
        third = self.task('third', 'beta')
        with (self.root / 'config').open('a') as f:
            f.write('eval_runner=alpha\n')
        (self.tasks / '.auth-cooldown-alpha').touch()
        self.assertIn(f'would claim: {third}', self.call('--dry-run').stdout)


class PreconditionTests(PickerHarness, unittest.TestCase):
    """## Precondition: checked before the inbox lock, waiting burns nothing."""

    def setUp(self):
        super().setUp()
        notify = self.root / 'bin' / 'notify-send'
        notify.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$NOTIFY_LOG"\n')
        notify.chmod(0o755)
        self.notify_log = self.root / 'notify.txt'
        self.env['NOTIFY_LOG'] = str(self.notify_log)
        self.state = self.tasks / '.precondition'

    def precond(self, name, command):
        return self.task(name, 'beta', f'\n## Precondition\n{command}\n\n## Tasks\n1. work\n')

    def notifications(self):
        return self.notify_log.read_text().splitlines() if self.notify_log.exists() else []

    def test_passing_precondition_is_claimable(self):
        task = self.precond('first', 'true')
        self.assertIn(f'would claim: {task}', self.call('--dry-run').stdout)

    def test_failing_precondition_waits_without_touching_the_task(self):
        flag = self.root / 'secret'
        waiting = self.precond('first', f'test -f {flag}')
        before = waiting.read_text()
        second = self.task('second', 'beta')
        result = self.call()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Waiting on precondition: first', result.stdout)
        self.assertFalse(second.exists())          # the next task was claimed
        self.assertEqual(waiting.read_text(), before)  # no retry, no feedback
        marker = (self.state / 'first').read_text()
        self.assertIn(f'command: test -f {flag}', marker)
        self.assertIn('exit: 1', marker)
        since = marker.splitlines()[0]
        self.assertEqual(len(self.notifications()), 1)

        # A second sweep keeps the first-seen time and does not notify again.
        self.call()
        self.assertEqual((self.state / 'first').read_text().splitlines()[0], since)
        self.assertEqual(len(self.notifications()), 1)

        # Once the human supplies what was missing, the task is claimable.
        flag.touch()
        result = self.call()
        self.assertIn('Precondition met, task claimable again: first', result.stdout)
        self.assertFalse((self.state / 'first').exists())
        self.assertFalse(waiting.exists())

    def test_timeout_counts_as_failure(self):
        with (self.root / 'config').open('a') as f:
            f.write('precondition_timeout_sec=1\n')
        self.precond('first', 'sleep 5')
        self.assertEqual(self.call('--dry-run').returncode, 1)
        self.call()
        self.assertIn('exit: 124 (timed out after 1s)',
                      (self.state / 'first').read_text())

    def test_dry_run_writes_no_status_file(self):
        self.precond('first', 'false')
        self.assertIn('would claim: (nothing eligible)', self.call('--dry-run').stdout)
        self.assertFalse(self.state.exists() and any(self.state.iterdir()))
        self.assertEqual(self.notifications(), [])

    def test_blocked_dependency_is_not_checked(self):
        probe = self.root / 'probe'
        self.task('first', 'beta',
                  f'\n## Depends-on\nmissing\n\n## Precondition\ntouch {probe}\n')
        self.call('--dry-run')
        self.assertFalse(probe.exists())

    def test_status_file_of_a_task_that_left_inbox_is_removed(self):
        self.state.mkdir(parents=True)
        (self.state / 'gone').write_text('since: x\n')
        self.task('other', 'beta')
        self.call()
        self.assertFalse((self.state / 'gone').exists())

    def test_named_task_runs_with_a_warning(self):
        task = self.precond('first', 'false')
        result = self.call(str(task))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('## Precondition fails for first.md', result.stderr)
        self.assertTrue((self.tasks / 'run/first.state').exists())
