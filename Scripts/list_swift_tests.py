#!/usr/bin/env python3
"""List exact XCTest IDs for one SwiftPM test module."""

from __future__ import annotations

import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: list_swift_tests.py <module>", file=sys.stderr)
        return 2

    module = sys.argv[1]
    completed = subprocess.run(
        ["swift", "test", "list"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.stderr:
        sys.stderr.write(completed.stderr)
    if completed.returncode != 0:
        if completed.stdout:
            sys.stdout.write(completed.stdout)
        return completed.returncode

    prefix = module + "."
    matches = [line for line in completed.stdout.splitlines() if line.startswith(prefix)]
    if not matches:
        print(f"no XCTest IDs found for module {module}", file=sys.stderr)
        return 1
    sys.stdout.write("\n".join(matches) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
