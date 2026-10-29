#!/usr/bin/env python3
"""Validate the first-party module catalog, allowed edges, imports, and placement."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from swift_imports import SwiftImportScanError, imported_modules

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path('Scripts/modularization/modules.json')
SUPPORTED_PLATFORMS = {'macos', 'linux'}


def host_platform() -> str:
    if sys.platform == 'darwin':
        return 'macos'
    if sys.platform.startswith('linux'):
        return 'linux'
    raise ValueError(f'unsupported module catalog host platform: {sys.platform}')


def modules_for_platform(catalog: dict, platform: str | None = None) -> dict:
    """Explicit platform membership; portable modules remain required on both hosts."""
    platform = platform or host_platform()
    if platform not in SUPPORTED_PLATFORMS:
        raise ValueError(f'unsupported module catalog platform: {platform}')
    active = {}
    for name, entry in catalog['modules'].items():
        platforms = entry.get('platforms', sorted(SUPPORTED_PLATFORMS))
        if (not isinstance(platforms, list) or not platforms or
                any(not isinstance(value, str) or value not in SUPPORTED_PLATFORMS for value in platforms)):
            raise ValueError(f'{name}: invalid catalog platforms {platforms!r}')
        if platform in platforms:
            active[name] = entry
    return active


def added_swift_paths(root: Path) -> set[str]:
    """New files in the PR range and working tree; clean main has no PR additions."""
    base = subprocess.run(
        ['git', 'merge-base', 'HEAD', 'origin/main'], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    changed = subprocess.run(
        ['git', 'diff', '--name-status', '-M', base], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    result = set()
    for line in changed:
        fields = line.split('\t')
        if fields[0].startswith(('A', 'R', 'C')):
            result.add(fields[-1])
    untracked = subprocess.run(
        ['git', 'ls-files', '--others', '--exclude-standard'], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    result.update(untracked)
    return {path for path in result if path.endswith('.swift')}


def target_dependency_names(target: dict, errors: list[str]) -> set[str]:
    names = set()
    for dependency in target.get('dependencies', []):
        if not isinstance(dependency, dict) or len(dependency) != 1:
            errors.append(f"{target['name']}: unrecognized dependency {dependency!r}")
            continue
        kind, value = next(iter(dependency.items()))
        valid_shape = isinstance(value, list) and bool(value) and isinstance(value[0], str)
        if kind not in {'byName', 'target', 'product'} or not valid_shape:
            errors.append(f"{target['name']}: unrecognized dependency {dependency!r}")
            continue
        if kind != 'product':
            names.add(value[0])
    return names


def check(root: Path, package: dict, catalog: dict, platform: str | None = None) -> list[str]:
    errors: list[str] = []
    all_modules = catalog['modules']
    try:
        modules = modules_for_platform(catalog, platform)
    except ValueError as error:
        return [str(error)]
    targets = {target['name']: target for target in package['targets']}
    actual_edges = {name: target_dependency_names(target, errors) for name, target in targets.items()}
    if set(modules) != set(targets):
        errors.append(f"catalog target drift: missing {sorted(set(targets)-set(modules))}; removed {sorted(set(modules)-set(targets))}")
    for name, entry in modules.items():
        target = targets.get(name)
        if target is None:
            continue
        if entry['source_root'] != target.get('path'):
            errors.append(f"{name}: source root changed from {entry['source_root']} to {target.get('path')}")
        declared = actual_edges[name]
        allowed = set(entry['allowed_dependencies'])
        if declared != allowed:
            errors.append(f"{name}: direct edges {sorted(declared)} do not match allowed {sorted(allowed)}")
        if entry.get('app_free_tests'):
            test_target = entry.get('test_target')
            if not test_target or test_target not in modules:
                errors.append(f"{name}: app-free owning test target missing")
            else:
                pending = [test_target]
                seen = set()
                while pending:
                    current = pending.pop()
                    if current in seen:
                        continue
                    seen.add(current)
                    pending.extend(actual_edges.get(current, set()))
                if 'RepoPromptApp' in seen:
                    errors.append(f"{name}: owning tests transitively build RepoPromptApp")
        source_root = root / entry['source_root']
        if not source_root.is_dir():
            continue
        for path in source_root.rglob('*.swift'):
            try:
                imports = imported_modules(path.read_text(encoding='utf-8', errors='replace'))
            except SwiftImportScanError as error:
                errors.append(f"{path.relative_to(root)}: import scan failed closed: {error}")
                continue
            for imported in imports:
                if imported in all_modules and imported != name and imported not in declared:
                    errors.append(f"{path.relative_to(root)}: undeclared first-party import {imported}")
    added = added_swift_paths(root)
    for family, entry in catalog.get('moved_families', {}).items():
        owner = entry['owner']
        # Placement ownership is a repository-wide rule, including modules whose
        # sources are intentionally excluded from this host's product graph.
        if owner not in all_modules:
            errors.append(f"{family}: unknown owner {owner}")
        for path in sorted(added):
            if path in entry.get('former_app_files', []) or any(
                path.startswith(old.rstrip('/') + '/') for old in entry.get('former_app_roots', [])
            ):
                errors.append(f"{family}: new Swift source belongs in {owner}, not {path}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    root = args.root.resolve()
    catalog = json.loads((root / CATALOG).read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(prefix='repoprompt-module-catalog-') as scratch:
        package = json.loads(subprocess.check_output(
            ['swift', 'package', '--scratch-path', scratch, 'dump-package'], cwd=root, text=True,
        ))
    errors = check(root, package, catalog)
    for error in errors:
        print(f'modules: {error}', file=sys.stderr)
    if errors:
        return 1
    print(f'modules: {len(package["targets"])} active target rows and placement rules ok ({host_platform()})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
