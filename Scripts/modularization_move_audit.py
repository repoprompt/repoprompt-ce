#!/usr/bin/env python3
"""Fail-closed audit of mechanical Swift module moves between two Git revisions."""

from __future__ import annotations

import argparse
from collections import Counter
import difflib
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ALLOWED_NON_SWIFT = {
    "Package.swift",
    "Scripts/modularization/modules.json",
    "docs/architecture/modules.md",
    "Scripts/source_layout_guardrails.sh",
    "docs/migrations/build-modularization/ratchets.json",
    "docs/migrations/build-modularization/ledger.md",
    "Scripts/conductor.py",  # conductor module index
    "Scripts/generate_xcode_workspace.py",
}
IMPORT = re.compile(r"^\s*(?:(?:@testable|@preconcurrency|public|internal|package)\s+)*import\s+([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)?\s*$")
DECLARATION = re.compile(r"\b(?:struct|class|enum|protocol|actor|extension|func|var|let|typealias|init|subscript|associatedtype|operator|precedencegroup)\b")
# Consume one required separator only; the audit must not hide formatting edits.
ACCESS = re.compile(r"(?<![\w.])(?:open|public|package|internal)(?:[ \t])(?!\()")
PREFIX_TOKEN = re.compile(r"(?:@\w+(?:\([^)]*\))?|final|static|class|override|nonisolated|required|convenience|mutating|nonmutating|lazy|weak|unowned|open|public|package|internal|private|fileprivate)\s*")


def git(*args: str, cwd: Path | None = None) -> bytes:
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE)


def git_paths(data: bytes) -> list[str]:
    return [os.fsdecode(path) for path in data.split(b"\0") if path]


def module_allowlist(base: str, head: str, cwd: Path) -> set[str]:
    modules: set[str] = set()
    for ref in (base, head):
        for root in ("Sources", "Tests"):
            paths = git_paths(git("ls-tree", "-r", "-z", "--name-only", ref, "--", root, cwd=cwd))
            modules.update(path.split("/")[1] for path in paths if len(path.split("/")) > 2)
        try:
            package = git("show", f"{ref}:Package.swift", cwd=cwd).decode()
        except subprocess.CalledProcessError:
            continue
        modules.update(re.findall(r"\.(?:target|testTarget|executableTarget)\s*\(\s*name:\s*\"([A-Za-z_]\w*)\"", package))
    return modules


def code_line_mask(text: str) -> list[bool]:
    """Conservatively classify physical lines that start outside strings/comments."""
    result: list[bool] = []
    block_depth = 0
    quotes = 0
    hashes = 0
    opaque = False
    for line in text.splitlines(keepends=True):
        result.append(not opaque and block_depth == 0 and quotes == 0)
        index = 0
        while index < len(line) and not opaque:
            if quotes:
                if hashes and line.startswith("\\" + "#" * hashes + "(", index):
                    opaque = True  # Raw interpolation needs a Swift parser.
                    break
                if not hashes and line[index] == "\\":
                    if line.startswith("\\(", index):
                        opaque = True  # Interpolation needs a Swift parser.
                        break
                    index += 2
                    continue
                if hashes and line.startswith("\\" + "#" * hashes, index):
                    index += hashes + 2
                    continue
                closing = '"' * quotes + "#" * hashes
                if line.startswith(closing, index):
                    index += len(closing)
                    quotes = hashes = 0
                    continue
            elif block_depth:
                if line.startswith("/*", index):
                    block_depth += 1
                    index += 2
                    continue
                if line.startswith("*/", index):
                    block_depth -= 1
                    index += 2
                    continue
            else:
                if line.startswith("//", index):
                    break
                if line.startswith("/*", index):
                    block_depth += 1
                    index += 2
                    continue
                if line.startswith("#/", index):
                    opaque = True  # Regex literals are not classified by this scanner.
                    break
                start = index
                while start < len(line) and line[start] == "#":
                    start += 1
                if start < len(line) and line[start] == '"':
                    hashes = start - index
                    quotes = 3 if line.startswith('"""', start) else 1
                    index = start + quotes
                    continue
            index += 1
    return result


def attribute_prefix_end(line: str) -> int | None:
    """Return the end of leading Swift attributes, or fail closed on an incomplete head."""
    index = len(line) - len(line.lstrip(" \t"))
    while index < len(line) and line[index] == "@":
        name = re.match(r"@[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", line[index:])
        if not name:
            return None
        index += name.end()
        if index < len(line) and line[index] == "(":
            depth = 0
            quoted = False
            escaped = False
            while index < len(line):
                char = line[index]
                if quoted:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        quoted = False
                elif char == '"':
                    quoted = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        index += 1
                        break
                index += 1
            if depth != 0 or quoted:
                return None
        if index >= len(line) or line[index] not in " \t":
            return None
        while index < len(line) and line[index] in " \t":
            index += 1
    return index


def normalize_access(line: str) -> str:
    """Remove only an access token in the head of a declaration, never body text."""
    lead = attribute_prefix_end(line)
    if lead is None:
        return line
    declaration = next((match for match in DECLARATION.finditer(line, lead)
                        if match.group() != "class" or not re.match(
                            r"[ \t]+(?:(?:open|public|package|internal|private|fileprivate|final|static|override)"
                            r"[ \t]+)*(?:func|var|subscript)\b", line[match.end():])), None)
    if not declaration:
        return line
    prefix = line[lead:declaration.start()]
    offset = 0
    while offset < len(prefix):
        match = PREFIX_TOKEN.match(prefix, offset)
        if not match or match.end() == offset:
            return line
        offset = match.end()
    return line[:lead] + ACCESS.sub("", prefix) + line[declaration.start():]


def normalized(data: bytes) -> str | None:
    if b"\0" in data:
        return None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    lines = []
    for line, code in zip(text.splitlines(keepends=True), code_line_mask(text)):
        if code and re.match(r"^[ \t]*(?:@\w+[ \t]+)*import\b", line):
            continue
        lines.append(normalize_access(line) if code else line)
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def import_delta_ok(left: bytes, right: bytes, modules: set[str]) -> bool:
    def imports(data: bytes) -> Counter[str]:
        text = data.decode("utf-8")
        return Counter(line for line, code in zip(text.splitlines(), code_line_mask(text))
                       if code and re.match(r"^[ \t]*(?:@\w+[ \t]+)*import\b", line))

    before, after = imports(left), imports(right)
    for line in list((before - after)) + list((after - before)):
        match = IMPORT.fullmatch(line)
        if not match or match.group(1) not in modules:
            return False
    return True


def content(ref: str, path: str, cwd: Path) -> bytes:
    return git("show", f"{ref}:{path}", cwd=cwd)


def line_class_ok(base: str, head: str, path: str, modules: set[str], cwd: Path) -> bool:
    left, right = content(base, path, cwd), content(head, path, cwd)
    left_hash, right_hash = normalized(left), normalized(right)
    if left_hash is None or left_hash != right_hash or not import_delta_ok(left, right, modules):
        return False
    diff = git("diff", "--no-ext-diff", "--no-textconv", "-U0", base, head, "--", path, cwd=cwd).decode("utf-8", "replace")
    hunks: list[tuple[list[str], list[str]]] = []
    old: list[str] = []
    new: list[str] = []
    for line in diff.splitlines(keepends=True):
        if line.startswith("@@"):
            if old or new:
                hunks.append((old, new))
            old, new = [], []
        elif line.startswith("-") and not line.startswith("---"):
            old.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            new.append(line[1:])
    if old or new:
        hunks.append((old, new))

    def filtered(lines: list[str]) -> list[str] | None:
        result = []
        for line in lines:
            if re.match(r"^\s*(?:@\w+\s+)*import\b", line):
                match = IMPORT.fullmatch(line.rstrip("\r\n"))
                if not match or match.group(1) not in modules:
                    return None
            else:
                result.append(normalize_access(line))
        return result

    return bool(hunks) and all(filtered(before) is not None and filtered(before) == filtered(after)
                               for before, after in hunks)


def audit(base: str, head: str, cwd: Path, before: int | None = None, after: int | None = None) -> dict:
    requested_base = git("rev-parse", "--verify", f"{base}^{{commit}}", cwd=cwd).decode().strip()
    head_sha = git("rev-parse", "--verify", f"{head}^{{commit}}", cwd=cwd).decode().strip()
    comparison_base = git("merge-base", requested_base, head_sha, cwd=cwd).decode().strip()
    modules = module_allowlist(comparison_base, head_sha, cwd)
    fields = git("diff", "--name-status", "-z", "-M100%", comparison_base, head_sha, cwd=cwd).split(b"\0")
    changes: list[list[str]] = []
    index = 0
    while index < len(fields) and fields[index]:
        status = fields[index].decode("ascii")
        count = 2 if status.startswith(("R", "C")) else 1
        changes.append([status, *(os.fsdecode(path) for path in fields[index + 1:index + 1 + count])])
        index += count + 1
    violations: list[str] = []
    moves: list[dict] = []
    manifest = [{"status": row[0], "paths": row[1:]} for row in changes]
    deleted: list[str] = []
    added: list[str] = []
    for row in changes:
        status, *paths = row
        if status.startswith("R"):
            source, target = paths
            if source.endswith(".swift") != target.endswith(".swift"):
                violations.append(f"{source} -> {target}: cross-type move")
                continue
            entry = {"from": source, "to": target, "similarity": int(status[1:])}
            if source.endswith(".swift"):
                left = content(comparison_base, source, cwd)
                right = content(head_sha, target, cwd)
                entry["base_sha256"] = normalized(left)
                entry["head_sha256"] = normalized(right)
                if status == "R100" and left == right and entry["base_sha256"] is None:
                    entry["base_sha256"] = entry["head_sha256"] = hashlib.sha256(left).hexdigest()
                    entry["hash_kind"] = "raw"
                elif entry["base_sha256"] is None or entry["head_sha256"] is None:
                    violations.append(f"{source} -> {target}: non-text Swift move cannot be classified")
                elif not import_delta_ok(left, right, modules):
                    violations.append(f"{source} -> {target}: non-first-party import edit")
                if entry["base_sha256"] != entry["head_sha256"]:
                    violations.append(f"{source} -> {target}: normalized hashes differ")
            elif source not in ALLOWED_NON_SWIFT or target not in ALLOWED_NON_SWIFT:
                violations.append(f"{source} -> {target}: non-Swift path not allowed")
            moves.append(entry)
        elif all(path in ALLOWED_NON_SWIFT for path in paths):
            continue
        elif status == "D" and paths[0].endswith(".swift"):
            deleted.append(paths[0])
        elif status == "A" and paths[0].endswith(".swift"):
            added.append(paths[0])
        elif status == "M" and paths[0].endswith(".swift"):
            if not line_class_ok(comparison_base, head_sha, paths[0], modules, cwd):
                violations.append(f"{paths[0]}: non-access/import edit")
        else:
            violations.append(f"{' -> '.join(paths)}: non-Swift path not allowed")
    available = set(added)
    for source in deleted:
        left = content(comparison_base, source, cwd)
        left_hash = normalized(left)
        candidates = []
        for target in sorted(available):
            right = content(head_sha, target, cwd)
            if left_hash is not None and normalized(right) == left_hash:
                candidates.append(target)
        if not candidates:
            violations.append(f"{source}: deleted Swift file has no normalized-equal addition")
            continue
        target = candidates[0]
        available.remove(target)
        right = content(head_sha, target, cwd)
        head_hash = normalized(right)
        if not import_delta_ok(left, right, modules):
            violations.append(f"{source} -> {target}: non-first-party import edit")
        moves.append({"from": source, "to": target, "similarity": round(100 * difflib.SequenceMatcher(None, left, right).ratio()),
                      "base_sha256": left_hash, "head_sha256": head_hash})
    for target in sorted(available):
        violations.append(f"{target}: added Swift file has no normalized-equal deletion")
    if before is not None and before < 0 or after is not None and after < 0:
        violations.append("test discovery counts must be nonnegative")
    if (before is None) != (after is None):
        violations.append("both --tests-before and --tests-after are required")
    elif before is not None and before != after:
        violations.append(f"test discovery changed: {before} -> {after}")
    return {"base": base, "requested_base_sha": requested_base, "comparison_base": comparison_base,
            "head": head, "head_sha": head_sha, "manifest": manifest, "moves": moves,
            "tests_before": before, "tests_after": after, "violations": violations}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--tests-before", type=int)
    parser.add_argument("--tests-after", type=int)
    args = parser.parse_args()
    try:
        report = audit(args.base, args.head, Path.cwd(), args.tests_before, args.tests_after)
    except (subprocess.CalledProcessError, UnicodeDecodeError) as exc:
        parser.error(str(exc))
    print(f"Move audit: {args.base}...{args.head} (merge base {report['comparison_base'][:12]})")
    for move in report["moves"]:
        print(f"  {move['similarity']}% {move['from']} -> {move['to']}")
        if "base_sha256" in move:
            print(f"    {move.get('hash_kind', 'normalized')} SHA-256: {move['base_sha256']} / {move['head_sha256']}")
    for violation in report["violations"]:
        print(f"  VIOLATION: {violation}")
    print(f"Result: {'FAIL' if report['violations'] else 'PASS'} ({len(report['moves'])} moves, {len(report['violations'])} violations)")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 1 if report["violations"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
