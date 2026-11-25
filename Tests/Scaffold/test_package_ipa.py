import importlib.util
import os
import pathlib
import plistlib
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE_SCRIPT = ROOT / "scripts" / "package_ipa.py"
SPEC = importlib.util.spec_from_file_location("package_ipa", PACKAGE_SCRIPT)
package_ipa = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = package_ipa
SPEC.loader.exec_module(package_ipa)


class PackageVerificationTests(unittest.TestCase):
    def make_info(self):
        return {
            "CFBundleDisplayName": "coda",
            "CFBundleIdentifier": "com.coda.sketchpad",
            "MinimumOSVersion": "27.2",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [2],
            "UIRequiresFullScreen": True,
            "UIUserInterfaceStyle": "Dark",
            "UISupportedInterfaceOrientations~ipad": package_ipa.EXPECTED_ORIENTATIONS,
            "UIAppFonts": package_ipa.FONT_FILES,
            "CFBundleExecutable": "coda",
        }

    def test_verifies_required_app_metadata_and_resources(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = pathlib.Path(temp_dir) / "coda.app"
            app.mkdir()
            for filename in package_ipa.FONT_FILES + ["OFL.txt"]:
                (app / filename).write_bytes(b"resource")
            bundle_id, executable = package_ipa.verify_info(self.make_info(), app)
            self.assertEqual(bundle_id, "com.coda.sketchpad")
            self.assertEqual(executable, "coda")

    def test_verifies_ipa_layout_and_embedded_plist(self):
        info = self.make_info()
        with tempfile.TemporaryDirectory() as temp_dir:
            ipa = pathlib.Path(temp_dir) / "App.ipa"
            with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/coda.app/Info.plist", plistlib.dumps(info))
                archive.writestr("Payload/coda.app/coda", b"arm64 executable")
                for filename in package_ipa.FONT_FILES + ["OFL.txt"]:
                    archive.writestr(f"Payload/coda.app/{filename}", b"resource")
            package_ipa.verify_ipa(ipa, info, "coda")

    def test_rejects_iphone_or_universal_device_family(self):
        info = self.make_info()
        info["UIDeviceFamily"] = [1, 2]
        with tempfile.TemporaryDirectory() as temp_dir:
            app = pathlib.Path(temp_dir) / "coda.app"
            app.mkdir()
            with self.assertRaises(SystemExit):
                package_ipa.verify_info(info, app)

    def test_rejects_simulator_platform_even_when_binary_is_arm64(self):
        info = self.make_info()
        info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        with tempfile.TemporaryDirectory() as temp_dir:
            app = pathlib.Path(temp_dir) / "coda.app"
            app.mkdir()
            with self.assertRaises(SystemExit):
                package_ipa.verify_info(info, app)

    def test_rejects_portrait_orientation(self):
        info = self.make_info()
        info["UISupportedInterfaceOrientations~ipad"] = ["UIInterfaceOrientationPortrait"]
        with tempfile.TemporaryDirectory() as temp_dir:
            app = pathlib.Path(temp_dir) / "coda.app"
            app.mkdir()
            with self.assertRaises(SystemExit):
                package_ipa.verify_info(info, app)

    def test_main_resolves_relative_output_before_ditto_changes_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            original_cwd = pathlib.Path.cwd()
            try:
                os.chdir(temp_dir)
                archive = pathlib.Path("archive") / "coda.xcarchive"
                app = archive / "Products" / "Applications" / "coda.app"
                app.mkdir(parents=True)
                (app / "Info.plist").write_bytes(plistlib.dumps(self.make_info()))
                (app / "coda").write_bytes(b"fixture executable")
                for filename in package_ipa.FONT_FILES + ["OFL.txt"]:
                    (app / filename).write_bytes(b"fixture resource")

                expected_ipa = pathlib.Path("build/artifacts/App.ipa").resolve()

                def fake_ditto(command, cwd, check):
                    destination = pathlib.Path(command[-1])
                    self.assertTrue(destination.is_absolute())
                    self.assertEqual(destination, expected_ipa)
                    self.assertTrue(pathlib.Path(cwd).name.startswith("coda-ipa-"))
                    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
                        for entry in (pathlib.Path(cwd) / "Payload").rglob("*"):
                            if entry.is_file():
                                bundle.write(entry, entry.relative_to(cwd).as_posix())

                with (
                    patch.object(
                        sys,
                        "argv",
                        [
                            str(PACKAGE_SCRIPT),
                            "--archive",
                            str(archive),
                            "--output-dir",
                            "build/artifacts",
                            "--xcode-version",
                            "27.2",
                            "--ios-sdk-version",
                            "27.2",
                            "--xcodegen-version",
                            "fixture",
                        ],
                    ),
                    patch.object(package_ipa.subprocess, "check_output", return_value="arm64\n"),
                    patch.object(package_ipa.subprocess, "run", side_effect=fake_ditto),
                ):
                    package_ipa.main()

                self.assertTrue(expected_ipa.is_file())
                self.assertTrue(expected_ipa.with_name("App-verification.txt").is_file())
            finally:
                os.chdir(original_cwd)


if __name__ == "__main__":
    unittest.main()
