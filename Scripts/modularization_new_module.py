#!/usr/bin/env python3
"""Print the minimal checklist for a new first-party SwiftPM module."""

import argparse
import re


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--family", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z_]\w*", args.name) or not re.fullmatch(r"[A-Za-z_][\w/-]*", args.family):
        parser.error("NAME and FAMILY must be safe identifiers/path fragments")
    print(f"New module checklist: {args.name} ({args.family})")
    print(f"[ ] Move the intended Sources/{args.name}/ files and Tests/{args.name}Tests/ tests")
    print("[ ] Add to Package.swift:")
    print(f'    .target(name: "{args.name}", path: "Sources/{args.name}"),')
    print(f'    .testTarget(name: "{args.name}Tests", dependencies: ["{args.name}"], path: "Tests/{args.name}Tests"),')
    print(f"[ ] Catalog row (T1): {args.name} | {args.family} | Sources/{args.name} | {args.name}Tests")
    print(f"[ ] Guardrail stanza: reject {args.family} files in the old App path; forbid RepoPromptApp imports in {args.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
