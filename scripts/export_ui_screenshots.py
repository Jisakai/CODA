"""Copy only named, bounded review images and failure reports from an xcresult export."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path, PurePosixPath, PureWindowsPath


EXPECTED = (
    "M1-empty-editor.png",
    "M1-four-bar-fixture.png",
    "M1-synth-drawer.png",
    "M1-radial-edge-fixture.png",
    "M1-radial-primary-fixture.png",
)
MAX_BYTES = 2 * 1024 * 1024
MAX_TEXT_BYTES = 256 * 1024
DIAGNOSTICS = tuple(
    f"M1-diagnostic-{test}.png"
    for test in (
        "testLaunchShowsEmptyEditorAndLocksLandscape",
        "testEmptyEditorScreenshotAttachment",
        "testFourBarSeededFixtureScreenshotAttachment",
        "testFingerMusicRegionTapDoesNotEditOrCreateHistory",
        "testDrawerAndAllThreeProductionPresetsAreReachable",
        "testActualSessionPlayPauseAndChordMuteControls",
        "testEdgePositionedAllQualityRadialScreenshotFixture",
        "testPrimaryRadialScreenshotFixture",
        "testSettingsIconCenterAndPaddingPresentProductionPopups",
        "testEverySettingsPopupStaysNearItsOwnInvokingControl",
        "testKnobValueCapsulesAreOutsideActualDialsAndFingerDragStillWorks",
    )
)
SETTINGS_DIAGNOSTICS = tuple(
    f"M1-settings-{surface}-{context}-{suffix}"
    for surface, contexts in (
        ("appSettings", ("coordinate-center", "coordinate-left-padding", "coordinate-bottom-padding", "invoking-control", "invoking-control-snapshot")),
        ("projectSettings", ("coordinate-center", "coordinate-left-padding", "coordinate-bottom-padding", "invoking-control", "invoking-control-snapshot")),
        ("keyScale", ("invoking-control", "invoking-control-snapshot")),
        ("tempo", ("invoking-control", "invoking-control-snapshot")),
    )
    for context in contexts
    for suffix in ("before-assertion.png", "AX-before-assertion.txt")
)
MUTE_DIAGNOSTICS = (
    "M1-mute-restore-before-assertion.png",
    "M1-mute-restore-AX-before-assertion.txt",
)
ALLOWLIST = ("M1b-pattern-overlay.png", *EXPECTED, *DIAGNOSTICS, *SETTINGS_DIAGNOSTICS, *MUTE_DIAGNOSTICS)


def exported_name(value: str) -> str:
    return Path(value.replace("\\", "/")).name


def matches_expected_label(label: str, expected: str) -> bool:
    if expected not in ALLOWLIST:
        return False
    if exported_name(label) == expected:
        return True
    stem = re.escape(Path(expected).stem)
    suffix = re.escape(Path(expected).suffix)
    return re.fullmatch(rf"{stem}_[0-9]+_[0-9A-Fa-f]{{8}}(?:-[0-9A-Fa-f]{{4}}){{3}}-[0-9A-Fa-f]{{12}}{suffix}",
                        exported_name(label)) is not None


def safe_payload(source: Path, parent: Path, filename: str) -> Path:
    relative = PurePosixPath(filename.replace("\\", "/"))
    if relative.is_absolute() or PureWindowsPath(filename).drive or ".." in relative.parts:
        raise ValueError(f"unsafe attachment path: {filename}")
    path = parent.joinpath(*relative.parts)
    if not path.resolve().is_relative_to(source.resolve()) or path.is_symlink():
        raise ValueError(f"attachment escapes export directory or is a symlink: {filename}")
    return path


def manifest_candidates(source: Path) -> dict[str, set[str]]:
    matches = {name: set() for name in ALLOWLIST}
    for manifest in source.rglob("manifest.json"):
        safe_payload(source, manifest.parent, manifest.name)
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue

        def visit(node: object, inherited_labels: tuple[str, ...] = ()) -> None:
            if isinstance(node, dict):
                values = {str(key).lower(): value for key, value in node.items()}
                labels = [
                    str(values[key])
                    for key in ("suggestedhumanreadablename", "originalfilename", "attachmentname", "name")
                    if isinstance(values.get(key), str)
                ]
                payload = values.get("payloadref")
                if isinstance(payload, dict):
                    labels.extend(
                        str(payload[key])
                        for key in ("name", "suggestedhumanreadablename", "originalfilename")
                        if isinstance(payload.get(key), str)
                    )
                labels = [*inherited_labels, *labels]
                exported = [
                    str(values[key])
                    for key in ("exportedfilename", "exportedfile", "filename", "path")
                    if isinstance(values.get(key), str)
                ]
                for expected in matches:
                    if any(matches_expected_label(label, expected) for label in labels):
                        for filename in exported:
                            path = safe_payload(source, manifest.parent, filename)
                            matches[expected].add(path.relative_to(source).as_posix())
                for child in node.values():
                    visit(child, tuple(labels))
            elif isinstance(node, list):
                for child in node:
                    visit(child, inherited_labels)

        visit(data)
    return matches


def locate(source: Path, expected: str, aliases: set[str]) -> Path | None:
    candidates = {safe_payload(source, source, alias) for alias in aliases}
    candidates.update(path for path in source.rglob(expected) if path.is_file())
    files = []
    for path in candidates:
        safe_payload(source, path.parent, path.name)
        if path.is_file():
            files.append(path)
    if len(files) > 1:
        raise ValueError(f"ambiguous named attachment: {expected}")
    return files[0] if files else None


def validate_attachment(path: Path, expected: str) -> None:
    size = path.stat().st_size
    if expected.endswith(".txt"):
        if not 0 < size <= MAX_TEXT_BYTES:
            raise ValueError(f"text attachment size is outside the 256 KiB limit: {path.name}")
        try:
            report = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError(f"attachment is not UTF-8 text: {path.name}") from error
        if "\x00" in report:
            raise ValueError(f"attachment contains binary NUL: {path.name}")
    else:
        if not 8 < size <= MAX_BYTES:
            raise ValueError(f"screenshot size is outside the 2 MiB limit: {path.name} ({size} bytes)")
        with path.open("rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                raise ValueError(f"attachment is not a PNG: {path.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--allow-missing-review", action="store_true",
                        help="Export available diagnostics after failed tests; CI still fails.")
    args = parser.parse_args()
    if not args.source.is_dir():
        parser.error(f"xcresult attachment export is missing: {args.source}")

    try:
        aliases = manifest_candidates(args.source)
    except ValueError as error:
        parser.error(str(error))
    manifests = sorted(args.source.rglob("manifest.json"))
    exported_files = sorted(path.name for path in args.source.rglob("*") if path.is_file())
    print(f"xcresult manifests: {len(manifests)}; exported files: {len(exported_files)}")
    for manifest in manifests:
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            entries = data.get("attachments", data) if isinstance(data, dict) else data
            count = len(entries) if isinstance(entries, list) else 0
        except (OSError, json.JSONDecodeError):
            count = 0
        print(f"manifest {manifest.relative_to(args.source)}: {count} attachment entries")
    args.destination.mkdir(parents=True, exist_ok=True)
    missing = []
    for expected in ALLOWLIST:
        try:
            source = locate(args.source, expected, aliases[expected])
            if source is not None:
                validate_attachment(source, expected)
        except ValueError as error:
            parser.error(str(error))
        if source is None:
            if expected in EXPECTED and not args.allow_missing_review:
                missing.append(expected)
            continue
        target = args.destination / expected
        if target.is_symlink() or not target.resolve().is_relative_to(args.destination.resolve()):
            parser.error(f"unsafe attachment destination: {expected}")
        shutil.copyfile(source, args.destination / expected)
    if missing:
        parser.error(f"required named UI attachments were not exported: {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
