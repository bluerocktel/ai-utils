"""Dependency location lookup must recognize queued .task.md files."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DependencyLocationTests(unittest.TestCase):
    def test_task_md_parent_in_inbox_is_waiting_then_done(self):
        with tempfile.TemporaryDirectory() as temp:
            tasks = Path(temp)
            inbox = tasks / 'inbox'
            done = tasks / 'done'
            inbox.mkdir()
            done.mkdir()
            parent = '2026-11-12_brteladmin-billing-invoice-state'
            (inbox / f'{parent}.task.md').write_text('# parent\n')
            child = inbox / '2026-11-12_brteladmin-billing-batch-run-identity.task.md'
            child.write_text(f'## Depends-on\n{parent}\n')
            script = f'source "{ROOT / "lib.sh"}"; blocked_inbox_tasks'
            env = dict(os.environ, TASKS_DIR=temp)

            waiting = subprocess.run(['bash', '-c', script], env=env,
                                     capture_output=True, text=True, check=True)
            self.assertIn(f'\t{parent}\tinbox', waiting.stdout)

            (tasks / 'run').mkdir()
            (inbox / f'{parent}.task.md').rename(tasks / 'run' / f'{parent}.task.md')
            (done / f'2026-11-12_21-30_{parent}.task.md').write_text('# result preamble\n')
            running = subprocess.run(['bash', '-c', script], env=env,
                                     capture_output=True, text=True, check=True)
            self.assertIn(f'\t{parent}\trun', running.stdout)

            (tasks / 'run' / f'{parent}.task.md').rename(done / f'2026-11-12_21-31_{parent}.task.md')
            completed = subprocess.run(['bash', '-c', script], env=env,
                                       capture_output=True, text=True, check=True)
            self.assertEqual(completed.stdout, '')


if __name__ == '__main__':
    unittest.main()
