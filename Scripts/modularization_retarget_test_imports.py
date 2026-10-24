#!/usr/bin/env python3
"""Retarget @testable RepoPromptApp imports in explicitly listed test files."""

from __future__ import annotations

import argparse
import difflib
import re
from pathlib import Path

from modularization_move_audit import code_line_mask

IMPORT = re.compile(r"(?m)^([ \t]*@testable[ \t]+import[ \t]+)RepoPromptApp([ \t]*)$")


def retarget(text: str, module: str) -> str:
    return "".join(IMPORT.sub(lambda match: match.group(1) + module + match.group(2), line)
                   if code else line
                   for line, code in zip(text.splitlines(keepends=True), code_line_mask(text)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    if not re.fullmatch(r"[A-Za-z_]\w*", args.module) or not (root / "Sources" / args.module).is_dir():
        parser.error("--module must name a first-party Sources target")
    for path in args.files:
        resolved = path.resolve()
        if not resolved.is_relative_to(root / "Tests") or path.suffix != ".swift":
            parser.error(f"not a Swift test file under Tests/: {path}")
        before = path.read_text(encoding="utf-8")
        after = retarget(before, args.module)
        print("".join(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True),
                                           fromfile=str(path), tofile=str(path))), end="")
        if args.apply and before != after:
            path.write_text(after, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
