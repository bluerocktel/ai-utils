"""Offline tests for the monitor's operator routes (===MESSAGE=== / ===BRIEF===).

A stub provider returns a canned response and a stub mail command records each
call, so no agent and no mail relay is ever reached.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

PROVIDER = '''
ai_run() { cat "$FAKE_RESPONSE" > "$5"; return 0; }
ai_json_text() { cat "$1"; }
ai_usage_table() { :; }
ai_is_auth_failure() { return 1; }
ai_model_alias() { printf '%s\\n' "$1"; }
ai_preamble_extra() { :; }
'''

MAILER = '''#!/bin/bash
n=$(ls "$MAIL_LOG" 2>/dev/null | wc -l)
d="$MAIL_LOG/$n"; mkdir -p "$d"
printf '%s\\n' "$@" > "$d/args"
cat > "$d/body"
exit "${MAIL_EXIT:-0}"
'''

SNAPSHOT = '===SNAPSHOT===\nstate\n===END===\n===SIGNAL===\nno\n===END===\n'


class OperatorRouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('ai-scheduled', 'lib.sh'):
            shutil.copy2(ROOT / name, self.root / name)
        (self.root / 'providers').mkdir()
        (self.root / 'providers' / 'fake.sh').write_text(PROVIDER)
        mailer = self.root / 'fakemail'
        mailer.write_text(MAILER)
        mailer.chmod(0o755)
        self.config('agent_mail_to=op@example.test\nagent_mail_reply_to=op+agent@example.test\n')
        self.tasks = self.root / 'tasks'
        self.sched = self.tasks / 'scheduled'
        self.sched.mkdir(parents=True)
        self.state = self.sched / '.state'
        self.briefs = self.tasks / 'briefs'
        self.mail_log = self.root / 'mail'
        self.response = self.root / 'response.txt'
        self.env = dict(os.environ, TASKS_DIR=str(self.tasks),
                        FAKE_RESPONSE=str(self.response),
                        MAIL_LOG=str(self.mail_log), HOME=str(self.root))

    def config(self, extra=''):
        (self.root / 'config').write_text(
            'default_runner=fake\n'
            f'brain_root={self.root}/brain\n'
            f'agent_mail_cmd={self.root}/fakemail\n' + extra)

    def job(self, perm='propose', agent=True, routes='Message, brief'):
        head = '## Kind: monitor\n## Schedule: daily\n'
        if agent:
            head += f'## Agent: liaison\n## Permission: {perm}\n'
            if routes is not None:
                head += f'## Routes: {routes}\n'
        (self.sched / 'watch.md').write_text(head + '\nWatch something.\n')

    def run_job(self, response, *extra):
        self.response.write_text(response)
        return subprocess.run([str(self.root / 'ai-scheduled'), '--force', *extra],
                              env=self.env, capture_output=True, text=True)

    def mails(self):
        if not self.mail_log.exists():
            return []
        return [((d / 'args').read_text().splitlines(), (d / 'body').read_text())
                for d in sorted(self.mail_log.iterdir())]

    def prompt(self):
        r = self.run_job('', '--dry-run', '--show-prompt')
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    # ── prompt gating ───────────────────────────────────────────────────────
    def test_routes_offered_only_to_agent_routines_above_read(self):
        self.job('propose')
        self.assertIn('5. OPERATOR ROUTES', self.prompt())
        self.job('read')
        self.assertNotIn('OPERATOR ROUTES', self.prompt())
        self.job(agent=False)
        self.assertNotIn('OPERATOR ROUTES', self.prompt())

    def test_routes_are_opt_in_per_routine(self):
        self.job('propose', routes=None)
        self.assertNotIn('OPERATOR ROUTES', self.prompt())
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                         '===BRIEF===\nslug: x\n---\nb\n===END===\n')
        self.assertIn("no 'message' in ## Routes", r.stdout)
        self.assertIn("no 'brief' in ## Routes", r.stdout)
        self.assertEqual(self.mails(), [])
        self.assertFalse(self.briefs.exists())

    def test_single_route_grants_only_itself(self):
        self.job('propose', routes='brief, bogus')
        p = self.prompt()
        self.assertIn('This routine has no message route', p)
        self.assertIn('===BRIEF===\nslug:', p)
        self.run_job(SNAPSHOT +
                     '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                     '===BRIEF===\nslug: only\n---\nb\n===END===\n')
        self.assertEqual(self.mails(), [])
        self.assertTrue((self.briefs / 'only-brief.md').exists())

    def test_routes_header_not_fed_back_as_instructions(self):
        self.job('propose')
        self.assertNotIn('## Routes', self.prompt())

    def test_message_route_withdrawn_when_unconfigured(self):
        self.config()
        self.job('propose')
        p = self.prompt()
        self.assertIn('No message route is configured', p)
        self.assertNotIn('===MESSAGE===\nsubject:', p)

    # ── delivery ────────────────────────────────────────────────────────────
    def test_messages_and_brief_delivered(self):
        self.job('propose')
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: [conv-1] draft\n---\nHello\n===END===\n'
                         '===BRIEF===\nslug: demo-topic\n---\n# Brief\nbody\n===END===\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        mails = self.mails()
        self.assertEqual(len(mails), 1)
        args, body = mails[0]
        self.assertEqual(args, ['-s', '[liaison] [conv-1] draft',
                                '-S', 'reply-to=op+agent@example.test',
                                '-.', 'op@example.test'])
        self.assertEqual(body, 'Hello\n')
        self.assertEqual((self.briefs / 'demo-topic-brief.md').read_text(), '# Brief\nbody\n')
        memory = (self.state / 'watch.memory.md').read_text()
        self.assertIn('messages=1, briefs=demo-topic', memory)
        self.assertTrue((self.state / 'watch.run').exists())

    def test_brief_name_cannot_escape_briefs(self):
        self.job('propose')
        self.run_job(SNAPSHOT + '===BRIEF===\nslug: ../../inbox/evil.md\n---\nx\n===END===\n')
        self.assertFalse((self.tasks / 'inbox').exists())
        self.assertEqual([p.name for p in self.briefs.iterdir()], ['evil-brief.md'])

    def test_existing_brief_never_overwritten(self):
        self.job('propose')
        (self.briefs / 'done').mkdir(parents=True)
        (self.briefs / 'done' / 'old-brief.md').write_text('original\n')
        r = self.run_job(SNAPSHOT + '===BRIEF===\nslug: old\n---\nnew\n===END===\n')
        self.assertIn('already exists', r.stdout)
        self.assertFalse((self.briefs / 'old-brief.md').exists())
        self.assertEqual((self.briefs / 'done' / 'old-brief.md').read_text(), 'original\n')

    def test_caps_are_enforced(self):
        self.config('agent_mail_to=op@example.test\nagent_messages_max=1\nagent_briefs_max=1\n')
        self.job('propose')
        msg = '===MESSAGE===\nsubject: s{0}\n---\nb\n===END===\n'
        brief = '===BRIEF===\nslug: b{0}\n---\nb\n===END===\n'
        self.run_job(SNAPSHOT + msg.format(1) + msg.format(2) + brief.format(1) + brief.format(2))
        self.assertEqual(len(self.mails()), 1)
        self.assertEqual([p.name for p in self.briefs.iterdir()], ['b1-brief.md'])

    def test_failed_send_makes_run_inconclusive(self):
        self.job('propose')
        self.env['MAIL_EXIT'] = '1'
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                         '===BRIEF===\nslug: later\n---\nb\n===END===\n')
        self.assertIn('FAILED to send', r.stdout)
        self.assertFalse(self.briefs.exists())
        self.assertFalse((self.state / 'watch.run').exists())
        self.assertFalse((self.state / 'watch.snapshot.md').exists())
        self.assertFalse((self.state / 'watch.memory.md').exists())

    def test_read_permission_refuses_routes(self):
        self.job('read')
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                         '===BRIEF===\nslug: x\n---\nb\n===END===\n')
        self.assertIn('refused', r.stdout)
        self.assertEqual(self.mails(), [])
        self.assertFalse(self.briefs.exists())

    def test_plain_job_output_is_never_scanned(self):
        self.job(agent=False)
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                         '===BRIEF===\nslug: x\n---\nb\n===END===\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.mails(), [])
        self.assertFalse(self.briefs.exists())
        self.assertNotIn('brief', r.stdout)

    def test_unconfigured_mail_refuses_message_but_writes_brief(self):
        self.config()
        self.job('propose')
        r = self.run_job(SNAPSHOT +
                         '===MESSAGE===\nsubject: s\n---\nb\n===END===\n'
                         '===BRIEF===\nslug: kept\n---\nb\n===END===\n')
        self.assertIn('no agent_mail_to configured', r.stdout)
        self.assertEqual(self.mails(), [])
        self.assertTrue((self.briefs / 'kept-brief.md').exists())


if __name__ == '__main__':
    unittest.main()
