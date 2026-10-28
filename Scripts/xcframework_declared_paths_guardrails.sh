#!/usr/bin/env bash
set -euo pipefail

# Fails if a vendored XCFramework Info.plist declares a LibraryPath or
# DebugSymbolsPath that is missing on disk. Xcode 27 rejects such frameworks,
# and a broad .gitignore rule (for example `*.dSYM/`) can silently drop them.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PYTHON'
import plistlib
import sys
from pathlib import Path

errors = []
found = 0
for info in sorted(Path("Vendor").glob("**/*.xcframework/Info.plist")):
    found += 1
    framework = info.parent
    with info.open("rb") as handle:
        plist = plistlib.load(handle)
    for library in plist.get("AvailableLibraries", []):
        identifier = library.get("LibraryIdentifier")
        if not identifier:
            errors.append(f"{info}: library entry missing LibraryIdentifier")
            continue
        base = framework / identifier
        for key in ("LibraryPath", "DebugSymbolsPath"):
            value = library.get(key)
            if value is None:
                continue
            declared = base / value
            if not declared.exists():
                errors.append(f"{info}: {identifier} declares {key} = {value}, but {declared} does not exist")
            elif key == "DebugSymbolsPath" and not any(declared.iterdir()):
                errors.append(f"{info}: {identifier} {key} {declared} is empty")

if found == 0:
    errors.append("no vendored XCFramework Info.plist files found under Vendor/")
if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    sys.exit(1)
print(f"OK: {found} vendored XCFramework(s) declare only existing paths.")
PYTHON
