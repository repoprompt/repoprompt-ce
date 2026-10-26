#!/usr/bin/env python3
"""Lift only explicitly internal declarations with an exact first-party swiftc note."""

from __future__ import annotations

import argparse
import difflib
import re
from pathlib import Path

from modularization_move_audit import PREFIX_TOKEN, attribute_prefix_end, code_line_mask

DIAGNOSTIC = re.compile(r"^(.*?\.swift):\d+:\d+: error: (?:'([^']+)' is inaccessible due to 'internal' protection level|cannot find (?:type )?'?([^' ]+)'? in scope)", re.MULTILINE)
DECL = re.compile(r"\b(?:struct|class|enum|actor|protocol|func|var|let|typealias|init|subscript|associatedtype)\s+([A-Za-z_]\w*)\b")
EXPLICIT_ACCESS = re.compile(r"\b(?:open|public|package|private|fileprivate)\b")
DECLARATION_NOTE = re.compile(r"(?m)^(.+?\.swift):(\d+):\d+: note: '([^']+)' declared here")


def owner(path: Path, root: Path) -> str | None:
    try:
        relative = path.resolve().relative_to((root / "Sources").resolve())
    except ValueError:
        return None
    return "RepoPromptApp" if relative.parts[0] == "RepoPrompt" else relative.parts[0]


def lift_line(line: str, symbol: str) -> str | None:
    lead = attribute_prefix_end(line)
    if lead is None:
        return None
    declaration = DECL.search(line, lead)
    if not declaration or declaration.group(1) != symbol:
        return None
    prefix = line[lead:declaration.start()]
    if EXPLICIT_ACCESS.search(prefix):
        return None
    offset = 0
    while offset < len(prefix):
        token = PREFIX_TOKEN.match(prefix, offset)
        if not token or token.end() == offset:
            return None
        offset = token.end()
    internal = re.search(r"\binternal(?=[ \t])", prefix)
    if not internal:
        return None  # Implicit access may come from an enclosing declaration.
    start = lead + internal.start()
    return line[:start] + "package" + line[start + len("internal"):]


def proposals(log: str, root: Path) -> tuple[dict[Path, str], list[str]]:
    sources = root / "Sources"
    files = [path for path in sorted(sources.rglob("*.swift")) if owner(path, root) is not None]
    original = {path: path.read_text(encoding="utf-8") for path in files}
    changes = dict(original)
    notes: list[str] = []
    seen: set[tuple[str, str]] = set()
    diagnostics = list(DIAGNOSTIC.finditer(log))
    for diagnostic_index, match in enumerate(diagnostics):
        location, inaccessible, missing = match.groups()
        symbol = inaccessible or missing
        if "." in symbol:
            symbol = symbol.rsplit(".", 1)[-1]
        key = (location, symbol)
        if key in seen:
            continue
        seen.add(key)
        diagnostic_path = Path(location)
        if not diagnostic_path.is_absolute():
            diagnostic_path = root / diagnostic_path
        consumer_owner = owner(diagnostic_path, root)
        if consumer_owner is None:
            notes.append(f"{symbol}: diagnostic is outside first-party Sources")
            continue
        end = diagnostics[diagnostic_index + 1].start() if diagnostic_index + 1 < len(diagnostics) else len(log)
        declaration_notes = [note for note in DECLARATION_NOTE.finditer(log, match.end(), end)
                             if note.group(3).split("(", 1)[0].rsplit(".", 1)[-1] == symbol]
        if len(declaration_notes) != 1:
            notes.append(f"{symbol}: requires one exact first-party declaration note")
            continue
        declaration_note = declaration_notes[0]
        path = Path(declaration_note.group(1))
        if not path.is_absolute():
            path = root / path
        path = next((candidate for candidate in changes if candidate.resolve() == path.resolve()), None)
        if path is None or owner(path, root) == consumer_owner:
            notes.append(f"{symbol}: declaration note is not in a different first-party module")
            continue
        lines = changes[path].splitlines(keepends=True)
        index = int(declaration_note.group(2)) - 1
        if index < 0 or index >= len(lines) or not code_line_mask(changes[path])[index]:
            notes.append(f"{symbol}: declaration note does not identify code")
            continue
        replacement = lift_line(lines[index], symbol)
        if replacement is None:
            notes.append(f"{symbol}: declaration is not explicitly internal on its line")
            continue
        lines[index] = replacement
        changes[path] = "".join(lines)
    return {path: text for path, text in changes.items() if text != original[path]}, notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="swiftc build log")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--apply", action="store_true", help="write proposed changes")
    args = parser.parse_args()
    root = args.root.resolve()
    original = {path: path.read_text(encoding="utf-8") for path in (root / "Sources").rglob("*.swift")}
    changes, notes = proposals(args.log.read_text(encoding="utf-8"), root)
    for path, proposed in changes.items():
        relative = path.relative_to(root)
        print("".join(difflib.unified_diff(original[path].splitlines(keepends=True), proposed.splitlines(keepends=True),
                                           fromfile=str(relative), tofile=str(relative))), end="")
        if args.apply:
            path.write_text(proposed, encoding="utf-8")
    for note in notes:
        print(f"SKIP: {note}")
    print(f"{'Applied' if args.apply else 'Proposed'} {len(changes)} file(s); skipped {len(notes)} diagnostic(s).")
    return 0 if not notes else 1


if __name__ == "__main__":
    raise SystemExit(main())
