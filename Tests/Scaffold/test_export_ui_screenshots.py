import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid


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
        filename = f"attachments/attachment-{index}.png"
        (source / "attachments").mkdir(exist_ok=True)
        (source / filename).write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        return {
            "testIdentifier": "CodaUITests/CodaLaunchTests",
            "attachments": [{
                "payloadRef": {"id": str(index), "name": name},
                "exportedFileName": filename,
            }],
        }

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

    def test_real_xctest_index_uuid_diagnostic_alias_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            expected = exporter.DIAGNOSTICS[5]
            exported = "E29D079D-F7E6-436D-A234-9C15578A1439.png"
            (source / exported).write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            entry = [{
                "testIdentifier": "CodaLaunchTests/testActualSessionPlayPauseAndChordMuteControls()",
                "attachments": [{
                    "exportedFileName": exported,
                    "suggestedHumanReadableName": (
                        "M1-diagnostic-testActualSessionPlayPauseAndChordMuteControls_0_"
                        "F3DE2D3F-B8E9-4A33-B110-DB53FA165B58.png"
                    ),
                }],
            }]
            (source / "manifest.json").write_text(json.dumps(entry))
            result = self.run_export(source, destination, "--allow-missing-review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([path.name for path in destination.iterdir()], [expected])

    def test_diagnostic_alias_rejects_non_uuid_suffix(self):
        expected = exporter.DIAGNOSTICS[5]
        self.assertFalse(exporter.matches_expected_label(
            "M1-diagnostic-testActualSessionPlayPauseAndChordMuteControls_0_latest.png", expected
        ))
        self.assertFalse(exporter.matches_expected_label(
            "prefix-M1-diagnostic-testActualSessionPlayPauseAndChordMuteControls_0_"
            "F3DE2D3F-B8E9-4A33-B110-DB53FA165B58.png", expected
        ))

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

    def test_repeated_popup_failures_preserve_each_context_pair_with_real_xctest_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            destination = source / "output"
            entries = []
            # Both icon surfaces can fail all three taps, then fail again in
            # the separate anchor test. These must remain distinct pairs.
            captures = [
                f"M1-settings-{surface}-{context}"
                for surface in ("appSettings", "projectSettings")
                for context in ("coordinate-center", "coordinate-left-padding",
                                "coordinate-bottom-padding", "invoking-control")
            ] + ["M1-settings-keyScale-invoking-control", "M1-settings-tempo-invoking-control",
                 "M1-mute-restore"]
            names = [f"{capture}-{suffix}" for capture in captures
                     for suffix in ("before-assertion.png", "AX-before-assertion.txt")]
            self.assertEqual(set(names), set((*exporter.SETTINGS_DIAGNOSTICS, *exporter.MUTE_DIAGNOSTICS)))
            expected_payloads = {}
            for index, expected in enumerate(names):
                suffix = pathlib.Path(expected).suffix
                payload = f"{str(uuid.uuid5(uuid.NAMESPACE_URL, expected)).upper()}{suffix}"
                capture = captures[index // 2]
                data = (b"\x89PNG\r\n\x1a\n" + capture.encode() if suffix == ".png"
                        else f"AX tree for {capture}\nUI events: anchor → action".encode())
                expected_payloads[expected] = data
                (source / payload).write_bytes(data)
                test = ("testSettingsIconCenterAndPaddingPresentProductionPopups" if "-coordinate-" in capture
                        else "testEverySettingsPopupStaysNearItsOwnInvokingControl" if "M1-settings-" in capture
                        else "testActualSessionPlayPauseAndChordMuteControls")
                entries.append({"testIdentifier": f"CodaLaunchTests/{test}()", "attachments": [{
                    "exportedFileName": payload,
                    "suggestedHumanReadableName": (
                        f"{pathlib.Path(expected).stem}_0_"
                        f"{str(uuid.uuid5(uuid.NAMESPACE_DNS, expected)).upper()}{suffix}"
                    ),
                }]})
            for unexpected in ("M1-settings-other-before-assertion.png",
                               "M1-settings-appSettings-unrelated.txt", "arbitrary.txt"):
                (source / unexpected).write_text("not allowlisted")
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, destination, "--allow-missing-review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({p.name for p in destination.iterdir()}, set(names))
            for expected, data in expected_payloads.items():
                self.assertEqual((destination / expected).read_bytes(), data, expected)

    def test_popup_test_fallback_diagnostics_export_exact_xctest_uuid_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            names = [f"M1-diagnostic-{test}.png" for test in (
                "testSettingsIconCenterAndPaddingPresentProductionPopups",
                "testEverySettingsPopupStaysNearItsOwnInvokingControl",
            )]
            entries = []
            for index, expected in enumerate(names):
                self.assertIn(expected, exporter.DIAGNOSTICS)
                alias = f"{pathlib.Path(expected).stem}_0_2C2D39DE-950D-46B0-AE8C-789285A26CA6.png"
                entries.append(self.make_attachment(source, alias, index))
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, source / "output", "--allow-missing-review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({p.name for p in (source / "output").iterdir()}, set(names))

    def test_repeated_exact_review_name_still_fails_instead_of_selecting_a_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            entries = [self.make_attachment(source, exporter.EXPECTED[0], index) for index in range(2)]
            (source / "manifest.json").write_text(json.dumps(entries))
            result = self.run_export(source, source / "output", "--allow-missing-review")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ambiguous named attachment", result.stderr)

    def test_failure_report_text_requires_bounded_utf8_without_binary_nuls(self):
        for content, message in ((b"x" * (exporter.MAX_TEXT_BYTES + 1), "256 KiB"),
                                 (b"", "256 KiB"), (b"\xffbad text", "UTF-8"),
                                 (b"AX\x00binary", "binary NUL")):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                source = pathlib.Path(temporary)
                (source / exporter.SETTINGS_DIAGNOSTICS[1]).write_bytes(content)
                result = self.run_export(source, source / "output", "--allow-missing-review")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_popup_png_is_size_limited_and_signature_checked(self):
        for data, message in ((b"\x89PNG\r\n\x1a\n" + b"x" * exporter.MAX_BYTES, "2 MiB"),
                              (b"not a screenshot", "not a PNG")):
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                source = pathlib.Path(temporary)
                (source / exporter.SETTINGS_DIAGNOSTICS[0]).write_bytes(data)
                result = self.run_export(source, source / "output", "--allow-missing-review")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_manifest_payload_paths_cannot_escape_or_alias_an_unrelated_file(self):
        for unsafe in ("../outside.txt", "nested/../../outside.txt", "/tmp/outside.txt",
                       "C:\\outside.txt", "..\\outside.txt"):
            with self.subTest(path=unsafe), tempfile.TemporaryDirectory() as temporary:
                source = pathlib.Path(temporary)
                (source / "manifest.json").write_text(json.dumps([{"attachments": [{
                    "exportedFileName": unsafe,
                    "suggestedHumanReadableName": exporter.SETTINGS_DIAGNOSTICS[1],
                }]}]))
                result = self.run_export(source, source / "output", "--allow-missing-review")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsafe attachment path", result.stderr)

    def test_nested_manifest_resolves_its_own_payload_and_rejects_suffix_guessing(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = pathlib.Path(temporary)
            nested = source / "test"
            nested.mkdir()
            expected = exporter.SETTINGS_DIAGNOSTICS[1]
            (nested / "payload.txt").write_text("expected AX report")
            (source / f"unrelated-{exporter.SETTINGS_DIAGNOSTICS[0]}").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
            (nested / "manifest.json").write_text(json.dumps([{"attachments": [{
                "exportedFileName": "payload.txt", "suggestedHumanReadableName": expected,
            }]}]))
            result = self.run_export(source, source / "output", "--allow-missing-review")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([p.name for p in (source / "output").iterdir()], [expected])

    def test_external_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "export"
            source.mkdir()
            outside = root / "private.txt"
            outside.write_text("outside report")
            link = source / exporter.SETTINGS_DIAGNOSTICS[1]
            try:
                link.symlink_to(outside)
            except OSError:
                self.skipTest("Creating symlinks is unavailable on this host")
            result = self.run_export(source, source / "output", "--allow-missing-review")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("escapes export directory", result.stderr)

    def test_workflow_uploads_exact_failure_names_without_broad_attachment_paths(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/unsigned-ipa.yml").read_text(encoding="utf-8")
        upload = workflow.split("      - name: Upload named M1 UI diagnostics even after test failure\n", 1)[1]
        upload = upload.split("\n      - name:", 1)[0]
        for name in (*exporter.SETTINGS_DIAGNOSTICS, *exporter.MUTE_DIAGNOSTICS):
            self.assertIn(f"            build/artifacts/ui-screenshots/{name}\n", upload)
        self.assertNotIn("ui-attachments/*", upload)
        self.assertNotIn(".xcresult", upload)
        self.assertNotIn("M1-settings-*", upload)


if __name__ == "__main__":
    unittest.main()
