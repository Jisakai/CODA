import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReviewExportShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = (ROOT / ".github/workflows/unsigned-ipa.yml").read_text(
            encoding="utf-8"
        )
        step = workflow.split("      - name: Export only named M1 review screenshots\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        cls.script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        cls.bash = shutil.which("bash")
        if cls.bash is None:
            raise unittest.SkipTest("Bash is required to execute the workflow shell regression")

    def run_export_step(self, outcome, exporter_status=0, lane="ui-a"):
        # Execute the actual workflow body; no Apple tools or filesystem writes needed.
        mocks = """
mkdir() { :; }
xcrun() { :; }
python3() {
    case "$-" in *e*u*) ;; *) return 99 ;; esac
    [[ "$(set -o)" =~ pipefail[[:space:]]+on ]] || return 98
    printf '%s\\n' "$@"
    return "$EXPORTER_STATUS"
}
"""
        with tempfile.TemporaryDirectory() as temporary:
            return subprocess.run(
                [self.bash, "--noprofile", "--norc", "-c", mocks + self.script],
                cwd=temporary,
                env={**os.environ, "M1_TEST_OUTCOME": outcome, "CI_LANE": lane,
                     "EXPORTER_STATUS": str(exporter_status)},
                capture_output=True, text=True,
            )

    def test_arguments_are_bash3_safe_even_with_no_optional_arguments(self):
        # Newer Bash accepts empty arrays under nounset, so execution there alone
        # cannot catch the macOS Bash 3 regression. Guard the positional handoff.
        self.assertRegex(self.script, r"(?m)^set --$")
        self.assertIn('"$@"', self.script)
        self.assertNotRegex(self.script, r"\$\{[^}]*\[@\]\}")

    def test_success_is_strict_and_failure_only_adds_allow_missing_review(self):
        expected = [
            "scripts/export_ui_screenshots.py",
            "--source", "build/generated/ui-attachments",
            "--destination", "build/artifacts/ui-screenshots",
        ]
        for outcome, options in (
            ("success", []),
            ("failure", ["--allow-missing-review"]),
        ):
            with self.subTest(outcome=outcome):
                result = self.run_export_step(outcome)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected + options)

    def test_exporter_failure_still_fails_the_step_in_both_branches(self):
        for outcome in ("success", "failure"):
            with self.subTest(outcome=outcome):
                result = self.run_export_step(outcome, exporter_status=23)
                self.assertEqual(result.returncode, 23, result.stderr)

    def test_second_shard_exports_available_diagnostics_but_propagates_failure(self):
        for outcome in ("success", "failure"):
            with self.subTest(outcome=outcome):
                result = self.run_export_step(outcome, lane="ui-b")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], "--allow-missing-review")
                result = self.run_export_step(outcome, exporter_status=23, lane="ui-b")
                self.assertEqual(result.returncode, 23, result.stderr)


if __name__ == "__main__":
    unittest.main()
