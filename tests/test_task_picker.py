"""Offline launcher tests; tmux is stubbed and no agents are executed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TaskPickerTests(unittest.TestCase):
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
