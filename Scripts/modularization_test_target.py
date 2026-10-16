#!/usr/bin/env python3
"""Resolve an exact test suite filter to its owning app-free test target."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUITE_DECLARATION = r'\b(?:class|struct|actor|enum)\s+{name}\b'


def resolve(root: Path, filter_value: str) -> str | None:
    # Regex and method-only filters retain SwiftPM's aggregate semantics.
    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(?:/[A-Za-z_][A-Za-z_0-9]*)?', filter_value):
        return None
    suite = filter_value.split('/', 1)[0]
    catalog = json.loads((root / 'Scripts/modularization/modules.json').read_text(encoding='utf-8'))
    owners = []
    for name, entry in catalog['modules'].items():
        if not entry['source_root'].startswith('Tests/') or name == 'RepoPromptTestSupport':
            continue
        directory = root / entry['source_root']
        for path in directory.rglob('*.swift') if directory.is_dir() else ():
            if path.stem != suite and not re.search(
                SUITE_DECLARATION.format(name=re.escape(suite)),
                path.read_text(encoding='utf-8', errors='replace'),
            ):
                continue
            owners.append(name)
            break
    if len(owners) > 1:
        raise ValueError(f'{suite} is declared in multiple test targets: {sorted(owners)}; specify MODULE=')
    if not owners:
        return None
    owner = owners[0]
    production = next(
        (entry for entry in catalog['modules'].values() if entry.get('test_target') == owner), None
    )
    return owner if production and production.get('app_free_tests') else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('filter')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        print(resolve(args.root.resolve(), args.filter) or '')
    except ValueError as error:
        print(f'test target resolution: {error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
