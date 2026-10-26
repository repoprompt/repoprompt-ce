#!/usr/bin/env python3
"""Validate that a file contains one complete JSON value."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <json-file>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    try:
        with path.open(encoding="utf-8") as stream:
            json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"error: invalid JSON file {path}: {error}", file=sys.stderr)
        return 1

    print(f"Valid JSON: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
