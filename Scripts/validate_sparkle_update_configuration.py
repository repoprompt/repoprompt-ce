#!/usr/bin/env python3
"""Validate Sparkle updater plist semantics against app sandbox entitlements."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import Any

SANDBOX_ENTITLEMENT_KEY = "com.apple.security.app-sandbox"
SPARKLE_SANDBOX_SERVICE_KEYS = ("SUEnableInstallerLauncherService",)


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_plist(path: Path) -> dict[str, Any]:
    try:
        value = plistlib.loads(path.read_bytes())
    except FileNotFoundError:
        fail(f"missing plist: {path}")
    except plistlib.InvalidFileException as error:
        fail(f"invalid plist {path}: {error}")
    except OSError as error:
        fail(f"could not read plist {path}: {error}")

    if not isinstance(value, dict):
        fail(f"plist root must be a dictionary: {path}")
    return value


def require_optional_bool(plist: dict[str, Any], key: str, path: Path) -> bool | None:
    if key not in plist:
        return None
    value = plist[key]
    if type(value) is not bool:
        fail(f"{path}: {key} must be a Boolean when present, got {type(value).__name__}")
    return value


def validate(info_plist_path: Path, entitlement_paths: list[Path]) -> None:
    info_plist = load_plist(info_plist_path)
    for key in SPARKLE_SANDBOX_SERVICE_KEYS:
        require_optional_bool(info_plist, key, info_plist_path)

    sandbox_states: list[tuple[Path, bool]] = []
    for entitlement_path in entitlement_paths:
        entitlements = load_plist(entitlement_path)
        sandbox_value = require_optional_bool(entitlements, SANDBOX_ENTITLEMENT_KEY, entitlement_path)
        sandbox_states.append((entitlement_path, sandbox_value is True))

    derived_states = {state for _, state in sandbox_states}
    if len(derived_states) != 1:
        details = ", ".join(f"{path}={'sandboxed' if state else 'non-sandboxed'}" for path, state in sandbox_states)
        fail(f"entitlement profiles disagree on sandbox state: {details}")

    is_sandboxed = next(iter(derived_states))
    installer_launcher_enabled = info_plist.get("SUEnableInstallerLauncherService") is True

    if is_sandboxed and not installer_launcher_enabled:
        fail("sandboxed apps must set SUEnableInstallerLauncherService to true for Sparkle installer-launcher support")
    if not is_sandboxed and installer_launcher_enabled:
        fail("non-sandboxed apps must not enable SUEnableInstallerLauncherService")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate Sparkle updater configuration against sandbox entitlements."
    )
    parser.add_argument("info_plist", type=Path, help="Info.plist or Info.plist template to validate")
    parser.add_argument(
        "entitlements",
        nargs="+",
        type=Path,
        help="One or more entitlement plist/template files that must agree on sandbox state",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    validate(args.info_plist, args.entitlements)
    print("OK: Sparkle update configuration is compatible with entitlement sandbox state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
