#!/usr/bin/env python3
"""Create and verify the unsigned, iPad-only coda IPA on the macOS CI runner."""

import argparse
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


FONT_FILES = [
    "PlusJakartaSans-Light.ttf",
    "PlusJakartaSans-Regular.ttf",
    "PlusJakartaSans-Medium.ttf",
    "PlusJakartaSans-SemiBold.ttf",
    "PlusJakartaSans-Bold.ttf",
    "PlusJakartaSans-ExtraBold.ttf",
]
EXPECTED_ORIENTATIONS = [
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]
EXPECTED_SUPPORTED_PLATFORMS = ["iPhoneOS"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"IPA verification failed: {message}")


def load_info_plist(path: pathlib.Path) -> dict:
    with path.open("rb") as handle:
        value = plistlib.load(handle)
    require(isinstance(value, dict), f"{path} is not a plist dictionary")
    return value


def verify_info(info: dict, app_root: pathlib.Path) -> tuple[str, str]:
    require(info.get("CFBundleDisplayName") == "coda", "display name must be coda")
    require(info.get("CFBundleIdentifier") == "com.coda.sketchpad", "bundle ID mismatch")
    require(info.get("MinimumOSVersion") == "27.2", "minimum OS must be iPadOS 27.2")
    require(
        info.get("CFBundleSupportedPlatforms") == EXPECTED_SUPPORTED_PLATFORMS,
        "archived app must target iPhoneOS only",
    )
    require(info.get("UIDeviceFamily") == [2], "UIDeviceFamily must contain iPad only (2)")
    require(info.get("UIRequiresFullScreen") is True, "full-screen requirement is missing")
    require(info.get("UIUserInterfaceStyle") == "Dark", "dark interface style is missing")
    require(
        info.get("UISupportedInterfaceOrientations~ipad") == EXPECTED_ORIENTATIONS,
        "supported iPad orientations must be landscape left and right only",
    )
    registered_fonts = info.get("UIAppFonts")
    require(registered_fonts == FONT_FILES, "UIAppFonts does not match the six required weights")
    for filename in FONT_FILES:
        require((app_root / filename).is_file(), f"bundled font is missing: {filename}")
    require((app_root / "OFL.txt").is_file(), "the bundled font OFL license is missing")
    forbidden_permissions = ("NSMicrophoneUsageDescription", "NSCameraUsageDescription")
    require(
        not any(key in info for key in forbidden_permissions),
        "microphone or camera usage description was added",
    )
    require(not (app_root / "_CodeSignature").exists(), "signed code directory found")
    require(not (app_root / "embedded.mobileprovision").exists(), "embedded profile found")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable, "CFBundleExecutable is missing")
    return info["CFBundleIdentifier"], executable


def verify_ipa(ipa_path: pathlib.Path, app_info: dict, executable: str) -> None:
    with zipfile.ZipFile(ipa_path) as archive:
        bad_member = archive.testzip()
        require(bad_member is None, f"corrupt ZIP member: {bad_member}")
        names = set(archive.namelist())
        info_name = "Payload/coda.app/Info.plist"
        executable_name = f"Payload/coda.app/{executable}"
        require(info_name in names, "IPA must contain Payload/coda.app/Info.plist")
        require(executable_name in names, "app executable is missing from IPA")
        zipped_info = plistlib.loads(archive.read(info_name))
        require(zipped_info == app_info, "archived app Info.plist differs from IPA Info.plist")
        for filename in FONT_FILES + ["OFL.txt"]:
            require(
                f"Payload/coda.app/{filename}" in names,
                f"IPA is missing bundled resource {filename}",
            )
        roots = {name.split("/", 1)[0] for name in names if name}
        require(roots == {"Payload"}, f"unexpected IPA top-level contents: {sorted(roots)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--xcode-version", required=True)
    parser.add_argument("--ios-sdk-version", required=True)
    parser.add_argument("--xcodegen-version", required=True)
    args = parser.parse_args()

    # Resolve at the CLI boundary: ditto runs with cwd set to a temporary staging directory.
    archive_path = args.archive.resolve()
    output_dir = args.output_dir.resolve()
    app = archive_path / "Products" / "Applications" / "coda.app"
    require(app.is_dir(), f"archive app not found at {app}")
    info = load_info_plist(app / "Info.plist")
    bundle_id, executable_name = verify_info(info, app)

    executable = app / executable_name
    architectures = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", os.fspath(executable)], text=True
    ).strip().split()
    require("arm64" in architectures, f"device executable is not arm64: {architectures}")

    output_dir.mkdir(parents=True, exist_ok=True)
    ipa_path = output_dir / "App.ipa"
    if ipa_path.exists():
        ipa_path.unlink()

    with tempfile.TemporaryDirectory(prefix="coda-ipa-") as temporary_directory:
        staging = pathlib.Path(temporary_directory)
        payload = staging / "Payload"
        app_copy = payload / "coda.app"
        app_copy.parent.mkdir(parents=True)
        shutil.copytree(app, app_copy, symlinks=True)
        subprocess.run(
            ["/usr/bin/ditto", "-c", "-k", "--keepParent", "Payload", os.fspath(ipa_path)],
            cwd=staging,
            check=True,
        )

    verify_ipa(ipa_path, info, executable_name)
    digest = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    report = [
        "coda unsigned iPad IPA verification",
        f"Xcode: {args.xcode_version}",
        f"iOS SDK: {args.ios_sdk_version}",
        f"XcodeGen: {args.xcodegen_version}",
        f"Bundle ID: {bundle_id}",
        "Display name: coda",
        "Device family: iPad only (UIDeviceFamily 2)",
        f"Supported platforms: {', '.join(EXPECTED_SUPPORTED_PLATFORMS)}",
        f"Orientations: {', '.join(EXPECTED_ORIENTATIONS)}",
        "Full screen: required",
        f"Architectures: {', '.join(architectures)}",
        f"Registered fonts: {', '.join(FONT_FILES)}",
        "Font license: OFL.txt bundled",
        "IPA layout: Payload/coda.app",
        f"IPA bytes: {ipa_path.stat().st_size}",
        f"IPA SHA-256: {digest}",
        "Result: passed archive metadata, device platform, arm64, resource, ZIP structure, and checksum checks",
    ]
    (output_dir / "App-verification.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))


if __name__ == "__main__":
    main()
