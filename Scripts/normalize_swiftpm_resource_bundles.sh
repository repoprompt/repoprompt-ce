#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle>"

python3 - "$APP_BUNDLE" <<'PYTHON'
import shutil
import sys
from pathlib import Path

app = Path(sys.argv[1])
required_bundles = ["KeyboardShortcuts_KeyboardShortcuts.bundle"]


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_file(path: Path) -> None:
    if not path.is_file():
        fail(f"missing SwiftPM resource bundle file: {path}")


def normalize_bundle(bundle: Path) -> None:
    if not bundle.is_dir():
        fail(f"missing SwiftPM resource bundle directory: {bundle}")

    canonical_info = bundle / "Contents" / "Info.plist"
    canonical_strings = bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.strings"
    if canonical_info.exists() or (bundle / "Contents").exists():
        require_file(canonical_info)
        require_file(canonical_strings)
        return

    flat_info = bundle / "Info.plist"
    flat_strings = bundle / "en.lproj" / "Localizable.strings"
    require_file(flat_info)
    require_file(flat_strings)

    temporary = bundle / ".repoprompt-normalize-tmp"
    if temporary.exists():
        fail(f"stale SwiftPM resource bundle normalization directory: {temporary}")

    resources = temporary / "Contents" / "Resources"
    resources.mkdir(parents=True)
    shutil.move(str(flat_info), str(temporary / "Contents" / "Info.plist"))
    for entry in list(bundle.iterdir()):
        if entry.name == ".repoprompt-normalize-tmp":
            continue
        shutil.move(str(entry), str(resources / entry.name))

    for entry in list((temporary / "Contents").iterdir()):
        shutil.move(str(entry), str(bundle / "Contents" / entry.name))
    (temporary / "Contents").rmdir()
    temporary.rmdir()


for bundle_name in required_bundles:
    normalize_bundle(app / "Contents" / "Resources" / bundle_name)

print("OK: normalized SwiftPM resource bundle layout.")
PYTHON
