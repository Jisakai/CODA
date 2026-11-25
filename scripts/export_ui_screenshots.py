"""Copy only the four review screenshots out of an xcresult attachment export."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


EXPECTED = (
    "M1-empty-editor.png",
    "M1-four-bar-fixture.png",
    "M1-synth-drawer.png",
    "M1-radial-edge-fixture.png",
)
MAX_BYTES = 2 * 1024 * 1024


def exported_name(value: str) -> str:
    return Path(value.replace("\\", "/")).name


def manifest_candidates(source: Path) -> dict[str, set[str]]:
    matches = {name: set() for name in EXPECTED}
    for manifest in source.rglob("manifest.json"):
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue

        def visit(node: object) -> None:
            if isinstance(node, dict):
                values = {str(key).lower(): value for key, value in node.items()}
                labels = [
                    str(values[key])
                    for key in ("suggestedhumanreadablename", "originalfilename", "attachmentname", "name")
                    if isinstance(values.get(key), str)
                ]
                exported = [
                    str(values[key])
                    for key in ("exportedfilename", "exportedfile", "filename", "path")
                    if isinstance(values.get(key), str)
                ]
                for expected in EXPECTED:
                    if any(exported_name(label) == expected for label in labels):
                        for filename in exported:
                            matches[expected].add(exported_name(filename))
                for child in node.values():
                    visit(child)
            elif isinstance(node, list):
                for child in node:
                    visit(child)

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
    args = parser.parse_args()
    if not args.source.is_dir():
        parser.error(f"xcresult attachment export is missing: {args.source}")

    aliases = manifest_candidates(args.source)
    args.destination.mkdir(parents=True, exist_ok=True)
    for expected in EXPECTED:
        source = locate(args.source, expected, aliases[expected])
        if source is None:
            parser.error(f"required named UI attachment was not exported: {expected}")
        size = source.stat().st_size
        if size <= 8 or size > MAX_BYTES:
            parser.error(f"screenshot size is outside the 2 MiB limit: {source.name} ({size} bytes)")
        with source.open("rb") as image:
            if image.read(8) != b"\x89PNG\r\n\x1a\n":
                parser.error(f"attachment is not a PNG: {source.name}")
        shutil.copyfile(source, args.destination / expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
