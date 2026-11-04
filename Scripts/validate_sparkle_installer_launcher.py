#!/usr/bin/env python3
"""Reject Sparkle's sandbox-only installer launcher in a non-sandboxed app (#42).

`SUEnableInstallerLauncherService` is for sandboxed applications. RepoPrompt CE
1.0.0 shipped with it enabled while unsandboxed, and its in-app update failed
with "An error occurred while connecting to the installer". The running app's
configuration controls the update, so a later fixed release cannot repair it.
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path

LAUNCHER_KEY = "SUEnableInstallerLauncherService"
SANDBOX_ENTITLEMENT = "com.apple.security.app-sandbox"


def load_plist(path: Path, label: str) -> dict[str, object]:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise SystemExit(f"ERROR: {label}: unreadable property list {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: {label}: {path} is not a property-list dictionary")
    return value


def violation(info: dict[str, object], entitlements: dict[str, object]) -> str | None:
    # Any present, non-false value may enable the launcher; only absence or an
    # explicit boolean false is safe for an unsandboxed app.
    if LAUNCHER_KEY not in info or info[LAUNCHER_KEY] is False:
        return None
    if entitlements.get(SANDBOX_ENTITLEMENT) is True:
        return None
    return (
        f"{LAUNCHER_KEY} is set ({info.get(LAUNCHER_KEY)!r}) but the app is not sandboxed "
        f"({SANDBOX_ENTITLEMENT} is not true); Sparkle's installer launcher is for sandboxed apps "
        "and breaks in-app updates otherwise. Remove the key from the app Info.plist."
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info-plist", type=Path, required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    parser.add_argument("--label", default="Sparkle installer launcher")
    args = parser.parse_args(argv)
    info = load_plist(args.info_plist, args.label)
    entitlements = load_plist(args.entitlements, args.label)
    problem = violation(info, entitlements)
    if problem:
        print(f"ERROR: {args.label}: {problem}", file=sys.stderr)
        return 1
    print(f"OK: {args.label}: no sandbox-only Sparkle installer launcher in a non-sandboxed app.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
