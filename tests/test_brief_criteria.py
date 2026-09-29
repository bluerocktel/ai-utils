"""Offline brief validation and repair tests; no real provider calls."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NAME = "2026-09-20_report.md"


def draft(criterion, name=NAME):
    return (f"===TASK_FILE_BEGIN: {name}===\n## Project\ndemo\n"
            "## Tasks\n1. Write report.md.\n## Acceptance Criteria\n"
            f"{criterion}\n===TASK_FILE_END===\n")


class BriefCriteriaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ai-brief-criteria-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        for name in ("ai-brief", "lib.sh"):
            shutil.copy2(ROOT / name, self.repo / name)
        (self.repo / "config").write_text("default_runner=fake\nbrief_timeout_min=1\n")
        providers = self.repo / "providers"
        providers.mkdir()
        (providers / "fake.sh").write_text('''
ai_run() {
    local n=0
    [ ! -f "$CALLS" ] || n=$(cat "$CALLS")
    n=$((n + 1)); printf '%s' "$n" > "$CALLS"
    printf '%s' "$1" > "$FIXTURES/prompt-$n"
    cp "$FIXTURES/draft-$n" "$5"
    : > "$6"
    if [ "$n" = 2 ]; then
        [ "${REPAIR_AUTH:-0}" = 0 ] || echo AUTH_FAILURE > "$6"
        return "${REPAIR_EXIT:-0}"
    fi
}
ai_json_text() { cat "$1"; }
ai_usage_table() { :; }
ai_is_auth_failure() { grep -q AUTH_FAILURE "$1"; }
ai_model_alias() { printf '%s' "$1"; }
ai_preamble_extra() { :; }
''')
        self.tasks = self.root / "tasks"
        (self.tasks / "run").mkdir(parents=True)
        self.brief = self.tasks / "run" / "example.md"
        self.brief.write_text("## Project\ndemo\n## Tasks\nWrite a report.\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        notify = self.bin / "notify-send"
        notify.write_text("#!/bin/sh\nexit 0\n")
        notify.chmod(0o755)
        self.env = dict(os.environ, TASKS_DIR=str(self.tasks),
                        CALLS=str(self.root / "calls"), FIXTURES=str(self.root),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        source = (ROOT / "ai-brief").read_text()
        start = source.index("brief_criteria_issues() {")
        end = source.index("\n}\n", start) + 3
        self.fn = self.root / "validator.sh"
        self.fn.write_text(source[start:end])

    def issues(self, text):
        path = self.root / "input.md"
        path.write_text(text)
        result = subprocess.run(["bash", "-c", 'source "$1"; brief_criteria_issues "$2"',
                                 "test", str(self.fn), str(path)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def run_brief(self, original, repaired=""):
        (self.root / "draft-1").write_text(original)
        (self.root / "draft-2").write_text(repaired)
        return subprocess.run(["bash", str(self.repo / "ai-brief"), "--run", str(self.brief)],
                              env=self.env, text=True, capture_output=True)

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.tasks / "briefs/example.md").exists())
        self.assertFalse(list((self.tasks / "backlog-for-review").glob("*.md")))
        self.assertTrue(list((self.tasks / "run").glob("*.raw")))
        self.assertFalse((self.tasks / "inbox").exists())

    def test_git_variants_and_multiline(self):
        for check in (
            "- `git diff -- src/ | wc -l` returns 0",
            "1. `git -C /repo diff -- src/ |\n   wc -l` returns `0`",
            "* Report `git status --porcelain`; it must be clean",
            "- `git -C /repo status --porcelain | grep src/` returns no output",
            "- `git diff --quiet -- src/` exits 0",
        ):
            with self.subTest(check=check):
                self.assertIn("git working-tree assertion", self.issues(draft(check)))

    def test_valid_counts_reporting_and_content_checks(self):
        for check in (
            "- `grep -c '^Q1:' report.md` prints 1",
            "- Record `git -C /repo status --porcelain` output for diagnosis",
            "- `git diff -- src/ | grep -c forbiddenMarker` returns 0",
            "- `git diff -- src/ | grep -q expectedMarker` exits 0",
            "- Record matching execution-time SHA-256 fingerprints for config",
            "- `pdftotext report.pdf - | tr '\\n' ' ' | grep -F 'Two Words'` exits 0",
            "- `pdftotext report.pdf - | grep -F 'Word'` exits 0",
        ):
            with self.subTest(check=check):
                self.assertEqual(self.issues(draft(check)), "")

    def test_wrapping_and_incomplete_checks(self):
        self.assertIn("phrase search", self.issues(draft(
            "- `pdftotext out.pdf - | grep -F 'Two Words'` exits 0")))
        self.assertIn("abbreviated command", self.issues(draft("- `grep -c Sources ...` returns 1")))
        self.assertIn("missing nonempty", self.issues(draft("")))
        self.assertIn("malformed task delimiters", self.issues(draft("- exists").replace("===TASK_FILE_END===", "")))

    def test_validator_never_executes_commands(self):
        marker = self.root / "should-not-exist"
        self.issues(draft(f"- `touch {marker}` succeeds"))
        self.assertFalse(marker.exists())

    def test_valid_draft_uses_one_call(self):
        result = self.run_brief(draft("- `test -f report.md` succeeds"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "calls").read_text(), "1")
        self.assertTrue((self.tasks / "briefs/done/example.md").exists())

    def test_repair_publishes_only_corrected_tasks(self):
        result = self.run_brief(draft("- `git diff | wc -l` returns 0"),
                                draft("- Record matching execution-time fingerprints for config"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "calls").read_text(), "2")
        output = (self.tasks / "backlog-for-review" / NAME).read_text()
        self.assertNotIn("git diff", output)
        self.assertIn("## Runner\nfake", output)
        prompt = (self.root / "prompt-2").read_text()
        self.assertIn("SOURCE BRIEF:", prompt)
        self.assertIn("git working-tree assertion", prompt)
        self.assertFalse((self.tasks / "inbox").exists())

    def test_failed_validation_restores_brief_and_retains_diagnostics(self):
        bad = draft("- `git diff | wc -l` returns 0")
        self.assert_rejected(self.run_brief(bad, bad))
        self.assertEqual((self.root / "calls").read_text(), "2")
        raw = next((self.tasks / "run").glob("*.raw")).read_text()
        self.assertIn("Initial criteria validation", raw)
        self.assertIn("Repair output", raw)

    def test_empty_repair_is_rejected(self):
        self.assert_rejected(self.run_brief(draft("- `git diff | wc -l` returns 0")))

    def test_renamed_repair_is_rejected(self):
        self.assert_rejected(self.run_brief(draft("- `git diff | wc -l` returns 0"),
                                           draft("- Report exists", "different.md")))

    def test_repair_timeout_does_not_publish_partial_output(self):
        self.env["REPAIR_EXIT"] = "124"
        self.assert_rejected(self.run_brief(draft("- `git diff | wc -l` returns 0"),
                                           draft("- Report exists")))

    def test_exhausted_budget_does_not_start_repair(self):
        (self.repo / "config").write_text("default_runner=fake\nbrief_timeout_min=0\n")
        self.assert_rejected(self.run_brief(draft("- `git diff | wc -l` returns 0")))
        self.assertEqual((self.root / "calls").read_text(), "1")

    def test_repair_auth_sets_cooldown(self):
        self.env["REPAIR_AUTH"] = "1"
        self.assert_rejected(self.run_brief(draft("- `git diff | wc -l` returns 0"),
                                           draft("- Report exists")))
        self.assertTrue((self.tasks / ".auth-cooldown-fake").exists())


if __name__ == "__main__":
    unittest.main()
