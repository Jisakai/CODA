"""Copy allowlisted review and per-test diagnostic PNGs from an xcresult export."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path


EXPECTED = (
    "M1-empty-editor.png",
    "M1-four-bar-fixture.png",
    "M1-synth-drawer.png",
    "M1-radial-edge-fixture.png",
)
MAX_BYTES = 2 * 1024 * 1024
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
    )
)


def exported_name(value: str) -> str:
    return Path(value.replace("\\", "/")).name


def matches_expected_label(label: str, expected: str) -> bool:
    if exported_name(label) == expected:
        return True
    if expected not in DIAGNOSTICS:
        return False
    stem = re.escape(expected.removesuffix(".png"))
    return re.fullmatch(rf"{stem}_[0-9]+_[0-9A-Fa-f]{{8}}(?:-[0-9A-Fa-f]{{4}}){{3}}-[0-9A-Fa-f]{{12}}\.png",
                        exported_name(label)) is not None


def manifest_candidates(source: Path) -> dict[str, set[str]]:
    matches = {name: set() for name in (*EXPECTED, *DIAGNOSTICS)}
    for manifest in source.rglob("manifest.json"):
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
                            matches[expected].add(exported_name(filename))
                for child in node.values():
                    visit(child, tuple(labels))
            elif isinstance(node, list):
                for child in node:
                    visit(child, inherited_labels)

        visit(data)
    return matches


def locate(source: Path, expected: str, aliases: set[str]) -> Path | None:
    names = {expected, *aliases}
    files = [path for path in source.rglob("*") if path.is_file()]
    for path in files:
        if path.name in names:
            return path
    for path in files:
        if path.suffix.lower() == ".png" and any(path.name.endswith(name) for name in names):
            return path
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--allow-missing-review", action="store_true",
                        help="Export available diagnostics after failed tests; CI still fails.")
    args = parser.parse_args()
    if not args.source.is_dir():
        parser.error(f"xcresult attachment export is missing: {args.source}")

    aliases = manifest_candidates(args.source)
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
    print("exported filenames: " + (", ".join(exported_files) if exported_files else "(none)"))
    args.destination.mkdir(parents=True, exist_ok=True)
    missing = []
    for expected in (*EXPECTED, *DIAGNOSTICS):
        source = locate(args.source, expected, aliases[expected])
        if source is None:
            if expected in EXPECTED and not args.allow_missing_review:
                missing.append(expected)
            continue
        size = source.stat().st_size
        if size <= 8 or size > MAX_BYTES:
            parser.error(f"screenshot size is outside the 2 MiB limit: {source.name} ({size} bytes)")
        with source.open("rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                parser.error(f"attachment is not a PNG: {source.name}")
        shutil.copyfile(source, args.destination / expected)
    if missing:
        parser.error(f"required named UI attachments were not exported: {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
