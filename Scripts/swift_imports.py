#!/usr/bin/env python3
"""Scan first-party Swift imports, including attributed and scoped imports."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Mask non-code text before matching; whitespace from comments is legal between
# an import attribute/access modifier and `import` (including across lines).
IMPORT = re.compile(
    r'(?:^|;)[ \t]*(?:(?:@[A-Za-z_]\w*(?:\([^)]*\))?|'
    r'(?:public|internal|private|fileprivate|package))\s+)*'
    r'import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?'
    r'(?:`([A-Za-z_]\w*)`|([A-Za-z_]\w*)\b)',
    re.M,
)
UI_MODULES = frozenset({'AppKit', 'SwiftUI'})
SPECIAL = re.compile(r'[/#"]')


class SwiftImportScanError(ValueError):
    """A lexical construct could not be safely classified."""


def mask_non_code(source: str) -> str:
    """Replace Swift comments, strings, and raw regex literals with whitespace.

    Preserve newlines and all code offsets so import locations remain accurate.
    Unterminated constructs fail closed instead of returning a partial scan.
    """
    masked = list(source)
    length = len(source)

    def blank(start: int, end: int) -> None:
        for position in range(start, end):
            if source[position] != '\n':
                masked[position] = ' '

    def quoted_end(start: int, quote_at: int, hashes: int, opener: str) -> int:
        terminator = opener + '#' * hashes
        position = quote_at + len(opener)
        while position < length:
            # A matching escape can contain a quote that is not a terminator.
            escape = '\\' + '#' * hashes
            if source.startswith(escape, position):
                position += len(escape)
                if position < length:
                    position += 1
                continue
            if source.startswith(terminator, position):
                end = position + len(terminator)
                blank(start, end)
                return end
            position += 1
        raise SwiftImportScanError(f'unterminated string or raw regex at offset {start}')

    position = 0
    while match := SPECIAL.search(source, position):
        position = match.start()
        if source.startswith('//', position):
            end = source.find('\n', position)
            if end < 0:
                end = length
            blank(position, end)
            position = end
            continue
        if source.startswith('/*', position):
            start = position
            depth = 1
            position += 2
            while position < length and depth:
                if source.startswith('/*', position):
                    depth += 1
                    position += 2
                elif source.startswith('*/', position):
                    depth -= 1
                    position += 2
                else:
                    position += 1
            if depth:
                raise SwiftImportScanError(f'unterminated block comment at offset {start}')
            blank(start, position)
            continue
        hashes = 0
        if source[position] == '#':
            while position + hashes < length and source[position + hashes] == '#':
                hashes += 1
        quote_at = position + hashes
        if quote_at < length and source[quote_at] == '"':
            opener = '"""' if source.startswith('"""', quote_at) else '"'
            position = quoted_end(position, quote_at, hashes, opener)
            continue
        if hashes and quote_at < length and source[quote_at] == '/':
            position = quoted_end(position, quote_at, hashes, '/')
            continue
        position += 1
    return ''.join(masked)


def strip_bom(source: str) -> str:
    """swiftc accepts a leading UTF-8 BOM; strip it so imports after it stay visible."""
    return source[1:] if source.startswith('\ufeff') else source


def scan_imports(source: str) -> list[tuple[int, str]]:
    source = strip_bom(source)
    masked = mask_non_code(source)
    return [(source.count('\n', 0, match.start(1) if match.group(1) else match.start(2)) + 1,
             match.group(1) or match.group(2))
            for match in IMPORT.finditer(masked)]


def imported_modules(source: str) -> list[str]:
    return [module for _, module in scan_imports(source)]


def sources_import_module(root: Path, module: str) -> bool:
    """Fail closed when a test source cannot be read or classified."""
    for path in root.rglob('*.swift'):
        try:
            if module in imported_modules(path.read_text(encoding='utf-8')):
                return True
        except (OSError, UnicodeError, SwiftImportScanError):
            return True
    return False


def forbidden_ui_imports(roots: list[Path]) -> list[str]:
    violations = []
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob('*.swift')):
            source = path.read_text(encoding='utf-8', errors='replace')
            try:
                imports = scan_imports(source)
            except SwiftImportScanError as error:
                raise SwiftImportScanError(f'{path}: {error}') from error
            lines = source.splitlines()
            for number, module in imports:
                if module in UI_MODULES:
                    violations.append(f'{path}:{number}: {lines[number - 1].strip()}')
    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--forbid-ui', action='store_true', required=True)
    parser.add_argument('roots', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        violations = forbidden_ui_imports(args.roots)
    except SwiftImportScanError as error:
        print(f'import scan failed closed: {error}', file=sys.stderr)
        return 2
    for violation in violations:
        print(violation)
    return 1 if violations else 0


if __name__ == '__main__':
    raise SystemExit(main())
