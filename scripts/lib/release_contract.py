#!/usr/bin/env python3
"""Deterministic local contracts for the ReleaseKit App Store release action."""

from __future__ import annotations

import json
import plistlib
import re
import sys
import zipfile
from pathlib import Path


LOCALE_FILE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\.txt$")
MAX_RELEASE_NOTE_CHARACTERS = 4_000


def fail(message: str) -> None:
    raise SystemExit(message)


def ipa_identity(ipa_path: Path) -> dict[str, str]:
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            candidates = [
                name
                for name in archive.namelist()
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)
            ]
            if len(candidates) != 1:
                fail(
                    "IPA must contain exactly one top-level Payload/<App>.app/Info.plist; "
                    f"found {len(candidates)}"
                )
            info = plistlib.loads(archive.read(candidates[0]))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        fail(f"Unable to inspect IPA: {error}")

    fields = {
        "bundle_id": info.get("CFBundleIdentifier"),
        "marketing_version": info.get("CFBundleShortVersionString"),
        "build_number": info.get("CFBundleVersion"),
    }
    missing = [name for name, value in fields.items() if not isinstance(value, str) or not value]
    if missing:
        fail(f"IPA Info.plist is missing required value(s): {', '.join(missing)}")
    return fields


def release_notes(notes_dir: Path, expected_locales_json: str | None) -> dict[str, object]:
    if not notes_dir.is_dir():
        fail(f"Store Release Notes directory not found: {notes_dir}")

    entries = sorted(notes_dir.iterdir(), key=lambda path: path.name)
    if not entries:
        fail("Store Release Notes directory is empty")

    notes: dict[str, str] = {}
    for path in entries:
        if not path.is_file() or path.is_symlink() or not LOCALE_FILE.fullmatch(path.name):
            fail(f"Malformed Store Release Note entry: {path.name}; expected <locale>.txt files")
        locale = path.stem
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            fail(f"Store Release Note is not valid UTF-8: {path.name}")
        if not text.strip():
            fail(f"Store Release Note is empty: {path.name}")
        if len(text) > MAX_RELEASE_NOTE_CHARACTERS:
            fail(
                f"Store Release Note {path.name} exceeds Apple's 4,000-character limit "
                f"({len(text)} characters)"
            )
        notes[locale] = text

    locales = sorted(notes)
    if expected_locales_json is not None:
        try:
            expected = sorted(json.loads(expected_locales_json))
        except (json.JSONDecodeError, TypeError):
            fail("Unable to parse enabled App Store locales from asc output")
        if not all(isinstance(locale, str) for locale in expected):
            fail("Enabled App Store locale response contains a non-string locale")
        missing = sorted(set(expected) - set(locales))
        extra = sorted(set(locales) - set(expected))
        if missing or extra:
            details = []
            if missing:
                details.append(f"missing: {', '.join(missing)}")
            if extra:
                details.append(f"extra: {', '.join(extra)}")
            fail(f"Store Release Note locales do not exactly match App Store Connect ({'; '.join(details)})")

    return {"locales": locales, "notes": notes}


def main() -> None:
    if len(sys.argv) < 3:
        fail("Usage: release_contract.py <ipa-identity|validate-notes> <path> [expected-locales-json]")
    command = sys.argv[1]
    path = Path(sys.argv[2])
    if command == "ipa-identity":
        result = ipa_identity(path)
    elif command == "validate-notes":
        expected = sys.argv[3] if len(sys.argv) > 3 else None
        result = release_notes(path, expected)
    else:
        fail(f"Unknown command: {command}")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
