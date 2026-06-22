#!/usr/bin/env python3
"""Verify linked Tree-sitter entrypoint ownership in RepoPrompt binaries."""

from __future__ import annotations

import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Mapping


REQUIRED_TREE_SITTER_SYMBOLS = (
    "tree_sitter_c",
    "tree_sitter_c_sharp",
    "tree_sitter_cpp",
    "tree_sitter_dart",
    "tree_sitter_go",
    "tree_sitter_java",
    "tree_sitter_javascript",
    "tree_sitter_php",
    "tree_sitter_python",
    "tree_sitter_ruby",
    "tree_sitter_rust",
    "tree_sitter_swift",
    "tree_sitter_tsx",
    "tree_sitter_typescript",
)
REQUIRED_TREE_SITTER_SYMBOL_SET = frozenset(REQUIRED_TREE_SITTER_SYMBOLS)
HEX_ADDRESS_RE = re.compile(r"^[0-9A-Fa-f]+$")
EXTERNAL_SCANNER_MARKER = "_external_scanner_"


class VerificationError(RuntimeError):
    pass


def normalized_symbol(raw_symbol: str) -> str:
    """Normalize the one leading underscore used by Mach-O external symbols."""
    return raw_symbol[1:] if raw_symbol.startswith("_") else raw_symbol


def parse_defined_global_symbols(output: str) -> collections.Counter[str]:
    """Parse standard `nm` output and retain defined global tree_sitter_* symbols."""
    symbols: collections.Counter[str] = collections.Counter()
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            continue
        parts = line.split()
        if parts and parts[0].endswith(":"):
            parts = parts[1:]
        if len(parts) < 3 or not HEX_ADDRESS_RE.fullmatch(parts[-3]):
            # Undefined output is normally `U _symbol` and is deliberately ignored.
            continue
        kind, raw_symbol = parts[-2], parts[-1]
        if len(kind) != 1 or not kind.isupper() or kind == "U":
            continue
        symbol = normalized_symbol(raw_symbol)
        if symbol.startswith("tree_sitter_"):
            symbols[symbol] += 1
    return symbols


def validation_errors(
    counts: Mapping[str, int],
    expectation: str,
    *,
    label: str,
    architecture: str,
) -> list[str]:
    prefix = f"{label} [{architecture}]"
    observed = set(counts)
    parser_entrypoints = {
        symbol for symbol in observed if EXTERNAL_SCANNER_MARKER not in symbol
    }
    if expectation == "absent":
        leaked = sorted(parser_entrypoints)
        if leaked:
            return [f"{prefix}: proxy must export no Tree-sitter parser entrypoints; found {leaked}"]
        return []
    if expectation != "exact":
        raise ValueError(f"unknown expectation: {expectation}")

    errors: list[str] = []
    missing = sorted(REQUIRED_TREE_SITTER_SYMBOL_SET - observed)
    unexpected = sorted(parser_entrypoints - REQUIRED_TREE_SITTER_SYMBOL_SET)
    duplicates = sorted(
        symbol
        for symbol in REQUIRED_TREE_SITTER_SYMBOL_SET
        if counts.get(symbol, 0) > 1
    )
    if missing:
        errors.append(f"{prefix}: missing required Tree-sitter definitions: {missing}")
    if duplicates:
        rendered = {symbol: counts[symbol] for symbol in duplicates}
        errors.append(f"{prefix}: Tree-sitter definitions must be unique: {rendered}")
    if unexpected:
        errors.append(f"{prefix}: unexpected Tree-sitter parser entrypoints: {unexpected}")
    return errors


def run_output(argv: list[str]) -> str:
    completed = subprocess.run(argv, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "no diagnostic"
        raise VerificationError(f"command failed ({completed.returncode}): {' '.join(argv)}: {detail}")
    return completed.stdout


def binary_architectures(binary: Path, lipo: str) -> list[str]:
    output = run_output([lipo, "-archs", str(binary)])
    architectures = output.split()
    if not architectures:
        raise VerificationError(f"could not determine architectures for {binary}")
    if len(set(architectures)) != len(architectures):
        raise VerificationError(f"duplicate architecture reported for {binary}: {architectures}")
    return architectures


def nm_output_by_architecture(binary: Path, *, lipo: str, nm: str) -> Iterable[tuple[str, str]]:
    architectures = binary_architectures(binary, lipo)
    if len(architectures) == 1:
        yield architectures[0], run_output([nm, "-gU", str(binary)])
        return

    with tempfile.TemporaryDirectory(prefix="repoprompt-tree-sitter-symbols-") as temporary:
        temporary_root = Path(temporary)
        for architecture in architectures:
            thin_binary = temporary_root / f"{binary.name}-{architecture}"
            run_output([lipo, str(binary), "-thin", architecture, "-output", str(thin_binary)])
            yield architecture, run_output([nm, "-gU", str(thin_binary)])


def verify_binary(binary: Path, expectation: str, *, label: str, lipo: str, nm: str) -> None:
    if not binary.is_file():
        raise VerificationError(f"missing binary: {binary}")
    all_errors: list[str] = []
    architectures: list[str] = []
    for architecture, output in nm_output_by_architecture(binary, lipo=lipo, nm=nm):
        architectures.append(architecture)
        counts = parse_defined_global_symbols(output)
        all_errors.extend(
            validation_errors(counts, expectation, label=label, architecture=architecture)
        )
    if all_errors:
        raise VerificationError("\n".join(all_errors))
    expected_description = (
        "exact fourteen entrypoint definitions"
        if expectation == "exact"
        else "no parser entrypoint definitions"
    )
    print(
        f"OK: {label} exports {expected_description} for architectures "
        f"{','.join(architectures)} ({binary})"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--expect", required=True, choices=("exact", "absent"))
    parser.add_argument("--label")
    parser.add_argument("--lipo", default=os.environ.get("LIPO", "/usr/bin/lipo"))
    parser.add_argument("--nm", default=os.environ.get("NM", "/usr/bin/nm"))
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        verify_binary(
            args.binary,
            args.expect,
            label=args.label or args.binary.name,
            lipo=args.lipo,
            nm=args.nm,
        )
    except VerificationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
