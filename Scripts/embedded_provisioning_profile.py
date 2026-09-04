#!/usr/bin/env python3
"""Install and validate the embedded release provisioning profile."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import tempfile
from pathlib import Path

DEPLOYED_MODE = 0o644


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def validate_profile(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing embedded provisioning profile: {path}")
    if not stat.S_ISREG(mode):
        fail(f"embedded provisioning profile must be a regular, non-symlink file: {path}")

    deployed_mode = stat.S_IMODE(mode)
    if deployed_mode != DEPLOYED_MODE:
        fail(
            "embedded provisioning profile must use deployed-readable mode "
            f"0644, got {deployed_mode:04o}: {path}"
        )


def install_profile(source: Path, destination: Path) -> None:
    try:
        source_mode = source.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing provisioning profile source: {source}")
    if not stat.S_ISREG(source_mode):
        fail(f"provisioning profile source must be a regular, non-symlink file: {source}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.",
            dir=destination.parent,
        )
        os.close(descriptor)
        temporary_path = Path(temporary_name)
        shutil.copyfile(source, temporary_path)
        os.chmod(temporary_path, DEPLOYED_MODE)
        validate_profile(temporary_path)
        os.replace(temporary_path, destination)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

    validate_profile(destination)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser(
        "install", help="copy a profile into the app bundle using mode 0644"
    )
    install_parser.add_argument("source", type=Path)
    install_parser.add_argument("destination", type=Path)

    validate_parser = subparsers.add_parser(
        "validate", help="require a regular embedded profile with mode 0644"
    )
    validate_parser.add_argument("path", type=Path)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "install":
        install_profile(args.source, args.destination)
    else:
        validate_profile(args.path)


if __name__ == "__main__":
    main()
