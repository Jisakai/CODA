import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "export_ui_screenshots.py"
SPEC = importlib.util.spec_from_file_location("export_ui_screenshots", SCRIPT)
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class ScreenshotExportTests(unittest.TestCase):
    def run_export(self, source, destination, *options):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--source", str(source),
             "--destination", str(destination), *options],
            capture_output=True, text=True,
        )

    def make_attachment(self, source, name, index):
        # xcresulttool exports hashed filenames, identified by manifest entries.
        filename = f"attachment-{index}.png"
        (source / filename).write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        return {"suggestedHumanReadableName": name, "exportedFileName": filename}

    def test_success_resolves_manifest_names_and_exports_only_allowlisted_images(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            names = (*exporter.EXPECTED, exporter.DIAGNOSTICS[0], "unrelated.png")
            entries = [self.make_attachment(source, name, i) for i, name in enumerate(names)]
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({p.name for p in destination.iterdir()}, set(names[:-1]))

    def test_failed_run_exports_diagnostics_without_all_review_fixtures(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            entries = [self.make_attachment(source, exporter.DIAGNOSTICS[0], 0)]
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, destination, "--allow-missing-review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([p.name for p in destination.iterdir()], [exporter.DIAGNOSTICS[0]])

    def test_success_path_still_requires_every_review_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            entries = [self.make_attachment(source, exporter.DIAGNOSTICS[0], 0)]
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required named UI attachments", result.stderr)
            self.assertTrue((destination / exporter.DIAGNOSTICS[0]).is_file())

    def test_failure_export_still_rejects_invalid_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            (source / exporter.DIAGNOSTICS[0]).write_bytes(b"not a png image")
            result = self.run_export(source, destination, "--allow-missing-review")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a PNG", result.stderr)


if __name__ == "__main__":
    unittest.main()
