#!/usr/bin/env python3
"""Reject known Swift overlay imports unavailable on supported macOS runtimes.

This is a bounded denylist, not a complete deployment-target compatibility audit.
Inspect linked imports so all first-party targets and static dependencies are
covered, even when the SDK omits the API's availability annotation (issue #1603).
"""

from __future__ import annotations

import argparse
import plistlib
import subprocess
import sys
from pathlib import Path


# These os.Logger members have no member-level SDK availability annotation, but
# older supported runtimes (including macOS 26.3) do not export them. OSLog's
# isEnabled(type:) and Logger.init(_:) provide the compatible enabled check.
UNSUPPORTED_SYMBOLS = {
    "$s2os6LoggerV9isEnabled4typeSbSo0a5_log_E2_ta_tF": "os.Logger.isEnabled(type:)",
    "$s2os6LoggerV8disabledACvgZ": "os.Logger.disabled",
}


class ValidationError(Exception):
    pass


def validate_app(app: Path) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream).get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or executable in {".", ".."} or "/" in executable:
        raise ValidationError("missing or invalid CFBundleExecutable")

    failures = []
    for name in dict.fromkeys((executable, "repoprompt-mcp")):
        binary = app / "Contents/MacOS" / name
        if not binary.is_file() or binary.is_symlink():
            raise ValidationError(f"expected non-symlink executable: {binary}")
        # Explicitly inspect every slice; the host-default architecture alone
        # would miss a regression confined to the other half of a universal app.
        result = subprocess.run(
            ["xcrun", "nm", "-arch", "all", "-u", "-j", str(binary)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise ValidationError(f"could not inspect {binary}: {result.stderr.strip()}")
        imports = {line.strip().removeprefix("_") for line in result.stdout.splitlines()}
        for symbol in sorted(imports & UNSUPPORTED_SYMBOLS.keys()):
            failures.append(f"{name}: {UNSUPPORTED_SYMBOLS[symbol]} ({symbol})")
    if failures:
        raise ValidationError(
            "imports unavailable on supported macOS runtimes:\n  " + "\n  ".join(failures)
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="packaged app bundle to inspect")
    args = parser.parse_args()
    try:
        validate_app(args.app)
    except (ValidationError, OSError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        print(f"ERROR: macOS runtime symbol validation failed: {error}", file=sys.stderr)
        return 1
    print("OK: app and MCP helper have no known unsupported macOS runtime imports (all architectures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
