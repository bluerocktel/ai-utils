"""Offline provider and evaluator regressions: python3 -m unittest discover -s tests."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CodexProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ai-utils-codex-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.capture = self.work / "events.jsonl"
        self.env = dict(os.environ, TASKS_DIR=str(self.work / "tasks"))

    def events(self, *events):
        self.capture.write_text("".join(json.dumps(e) + "\n" for e in events))

    def call(self, script, *args):
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; source "$1/lib.sh"; '
             'load_provider codex; shift; ' + script, "test", str(ROOT), *map(str, args)],
            env=self.env, text=True, capture_output=True, cwd=self.work,
        )

    def completed(self, text="VERDICT: PASS"):
        self.events(
            {"type": "turn.started"},
            {"type": "item.completed", "item": {"type": "agent_message", "text": "Working"}},
            {"type": "item.completed", "item": {"type": "agent_message", "text": text}},
            {"type": "turn.completed", "usage": {
                "input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 80}},
        )

    def test_final_message_and_usage(self):
        self.completed()
        result = self.call('ai_json_text "$1"', self.capture)
        self.assertEqual((result.returncode, result.stdout), (0, "VERDICT: PASS\n"))
        out = self.work / "usage.md"
        self.assertEqual(self.call('ai_usage_table "$1" "$2"', self.capture, out).returncode, 0)
        self.assertIn("| (not reported) | 100 | 20 | 80 |", out.read_text())
        self.assertIn("**Total cost:** $n/a", out.read_text())

    def test_incomplete_failed_and_malformed_are_empty(self):
        for ending in ([], [{"type": "turn.failed", "error": {"message": "failed"}}]):
            self.events({"type": "item.completed", "item": {
                "type": "agent_message", "text": "VERDICT: PASS"}}, *ending)
            self.assertEqual(self.call('ai_json_text "$1"', self.capture).stdout, "")
        self.completed()
        with self.capture.open("a") as stream:
            stream.write('{"type":')
        self.assertEqual(self.call('ai_json_text "$1"', self.capture).stdout, "")
        self.assertEqual(self.call('ai_json_text "$1"', self.work / "missing").returncode, 1)

    def test_new_turn_does_not_reuse_old_answer(self):
        self.completed()
        with self.capture.open("a") as stream:
            stream.write('{"type":"turn.started"}\n')
        self.assertEqual(self.call('ai_json_text "$1"', self.capture).stdout, "")

    def test_auth_errors_only_not_agent_or_tool_output(self):
        self.completed("API returned 401 Unauthorized; documentation mentions codex login")
        self.assertEqual(self.call('ai_is_auth_failure "$1"', self.capture).returncode, 1)
        self.events({"type": "item.completed", "item": {
            "type": "command_execution", "aggregated_output": "401 Unauthorized"}})
        self.assertEqual(self.call('ai_is_auth_failure "$1"', self.capture).returncode, 1)
        for event in ({"type": "error", "message": "401 Unauthorized"},
                      {"type": "turn.failed", "error": {"message": "refresh_token_reused"}}):
            self.events(event)
            self.assertEqual(self.call('ai_is_auth_failure "$1"', self.capture).returncode, 0)
        self.capture.write_text("Please run codex login\n")
        self.assertEqual(self.call('ai_is_auth_failure "$1"', self.capture).returncode, 0)
        self.capture.write_text("429 rate limit\n")
        self.assertEqual(self.call('ai_is_auth_failure "$1"', self.capture).returncode, 1)

    def fake_cli(self):
        binary = self.work / "codex"
        binary.write_text('#!/bin/bash\n'
                          'printf "%s\\0" "$@" > "$ARGS_OUT"\n'
                          'cat > "$PROMPT_OUT"\n'
                          'echo "CLI warning" >&2\n'
                          'cat "$EVENTS_IN"\n'
                          'sleep "${FAKE_SLEEP:-0}"\n'
                          'exit "${FAKE_EXIT:-0}"\n')
        binary.chmod(0o755)
        self.env.update(PATH=str(self.work) + os.pathsep + self.env["PATH"],
                        ARGS_OUT=str(self.work / "args"), PROMPT_OUT=str(self.work / "prompt"),
                        EVENTS_IN=str(self.capture))

    def test_invocation_quoting_streams_status_and_shell_options(self):
        self.completed()
        self.fake_cli()
        directory = self.work / "directory with spaces"
        directory.mkdir()
        prompt = "-literal $(not-a-command)\nsecond line"
        out, err = self.work / "out", self.work / "err"
        result = self.call('ai_run "$1" "$2" "$3" 5 "$4" "$5"; [[ $- == *e* ]]',
                           prompt, "model [literal]", directory, out, err)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(out.read_text(), self.capture.read_text())
        self.assertEqual(err.read_text(), "CLI warning\n")
        self.assertEqual((self.work / "prompt").read_text(), prompt + "\n")
        args = (self.work / "args").read_bytes().split(b"\0")[:-1]
        self.assertIn(b"model [literal]", args)
        self.assertIn(str(directory).encode(), args)
        self.assertIn(b"--dangerously-bypass-approvals-and-sandbox", args)
        self.env["FAKE_EXIT"] = "7"
        result = self.call('set +e; ai_run prompt "" "" 5 "$1" "$2"; '
                           'rc=$?; [[ $- != *e* ]] || exit 99; exit "$rc"', out, err)
        self.assertEqual(result.returncode, 7)
        self.assertNotIn(b"--model", (self.work / "args").read_bytes())
        self.env["FAKE_SLEEP"] = "2"
        self.assertEqual(self.call('ai_run prompt "" "" 0.1 "$1" "$2"', out, err).returncode, 124)

    def test_missing_usage_and_model_passthrough(self):
        out = self.work / "usage"
        self.assertEqual(self.call('ai_usage_table "$1" "$2"', self.capture, out).returncode, 0)
        self.assertIn("| (not reported) | n/a | n/a | n/a |", out.read_text())
        self.assertEqual(self.call('ai_model_alias ""').stdout.strip(), "")
        self.assertEqual(self.call('ai_model_alias "custom-model"').stdout.strip(), "custom-model")

    def test_evaluator_accepts_provider_result_and_defers_auth(self):
        self.completed()
        self.fake_cli()
        task, report, verdict = [self.work / name for name in ("task.md", "report.md", "verdict.md")]
        projects = Path(self.env["TASKS_DIR"]) / "projects"
        projects.mkdir(parents=True)
        instructions = self.work / "project rules.md"
        instructions.write_text("PROJECT RULE: preserve the existing database.\n")
        (projects / "example.md").write_text(f"## CLAUDE.md\n`{instructions}`\n")
        task.write_text("## Project\nexample\n## Acceptance Criteria\n- The work is complete\n")
        report.write_text("## Summary\nThe work is complete\n")
        command = [str(ROOT / "ai-eval"), "--runner", "codex", str(task), str(report), str(verdict)]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VERDICT: PASS", verdict.read_text())
        self.assertIn(instructions.read_text(), (self.work / "prompt").read_text())
        self.events({"type": "turn.failed", "error": {"message": "401 Unauthorized"}})
        result = subprocess.run(command, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 3, result.stderr)

    def test_project_instruction_resolution(self):
        projects = Path(self.env["TASKS_DIR"]) / "projects"
        projects.mkdir(parents=True)
        project = projects / "example.md"
        rules = projects / "rules with spaces.md"
        rules.write_text("Unique project instructions\nSecond line\n")
        for reference in (str(rules), "rules with spaces.md"):
            project.write_text(f"## CLAUDE.md\n\n`{reference}`\n\n## Notes\nOther context\n")
            result = self.call('project_instructions example')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(rules.read_text(), result.stdout)
            self.assertNotIn("Other context", result.stdout)
        self.env["HOME"] = str(projects)
        project.write_text("## CLAUDE.md\n`~/rules with spaces.md`\n")
        self.assertIn(rules.read_text(), self.call('project_instructions example').stdout)
        project.write_text("## Instructions\n`rules with spaces.md`\n## CLAUDE.md\nmissing\n")
        self.assertIn(rules.read_text(), self.call('project_instructions example').stdout)
        project.write_text("## CLAUDE.md\n`$(touch injected)`\n")
        result = self.call('project_instructions example')
        self.assertEqual(result.returncode, 0)
        self.assertIn("could not be read", result.stdout)
        self.assertIn("unavailable", result.stderr)
        self.assertFalse((self.work / "injected").exists())
        project.write_text("## Notes\nNo instruction reference\n")
        self.assertEqual(self.call('project_instructions example').stdout, "")
        self.assertEqual(self.call('project_instructions absent').stdout, "")


if __name__ == "__main__":
    unittest.main()
