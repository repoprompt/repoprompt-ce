#!/usr/bin/env python3
"""Select app-free owning test targets affected by a PR's target changes."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def select(root: Path, paths: list[str], catalog: dict) -> list[str]:
    modules = catalog['modules']
    test_targets = {entry['test_target'] for entry in modules.values()
                    if entry.get('app_free_tests') and entry.get('test_target')}
    if any(path in {'Package.swift', 'Package.resolved', 'Scripts/modularization/modules.json'} or
           path.startswith(('.github/', 'Scripts/conductor', 'Scripts/ci_app_test_runner')) for path in paths):
        return sorted(test_targets)
    changed = {
        name for name, entry in modules.items()
        if any(path == entry['source_root'] or path.startswith(entry['source_root'].rstrip('/') + '/') for path in paths)
    }
    # Propagate changes only toward direct dependents, never upstream to dependencies.
    affected = set(changed)
    while True:
        added = {name for name, entry in modules.items()
                 if set(entry['allowed_dependencies']) & affected}
        if added <= affected:
            break
        affected |= added
    return sorted(target for target in test_targets if target in affected or
                  any(name in affected and entry.get('test_target') == target
                      for name, entry in modules.items()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base')
    parser.add_argument('--all', action='store_true')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    root = args.root.resolve()
    catalog = json.loads((root / 'Scripts/modularization/modules.json').read_text(encoding='utf-8'))
    if args.all or not args.base or set(args.base) == {'0'}:
        targets = select(root, ['Package.swift'], catalog)
    else:
        changed = subprocess.run(
            ['git', 'diff', '--name-only', '-M', args.base, args.head], cwd=root,
            check=True, capture_output=True, text=True,
        ).stdout.splitlines()
        targets = select(root, changed, catalog)
    print(json.dumps({'include': [{'module': target} for target in targets]}, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
