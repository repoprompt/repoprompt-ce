#!/usr/bin/env python3
"""Pack only runnable CI test products, not SwiftPM checkouts or build intermediates."""

from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
from pathlib import Path
from swift_imports import sources_import_module
from ci_test_coverage import listed_tests, validate_targets

ROOT = Path(__file__).resolve().parent.parent
METADATA = Path('.build/modularization')


def test_source_hashes(root: Path) -> dict[str, str]:
    tests = root / 'Tests'
    return {path.relative_to(tests).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in tests.rglob('*.swift')}


def product_directory(root: Path) -> Path | None:
    swiftbuild = root / '.build/out/Products/Debug'
    if swiftbuild.is_dir():
        return swiftbuild
    candidates = sorted(path for path in root.glob('.build/*/debug') if path.is_dir())
    return candidates[0] if len(candidates) == 1 else None


def validate(root: Path) -> Path:
    metadata = root / METADATA
    try:
        fingerprints = json.loads((metadata / 'app-source-sha256.json').read_text(encoding='utf-8'))['source_sha256']
        index = json.loads((metadata / 'index-check.json').read_text(encoding='utf-8'))['source_sha256']
        listing = (metadata / 'ci-test-list.txt').read_text(encoding='utf-8')
        targets = json.loads((metadata / 'test-targets.json').read_text(encoding='utf-8'))
        if targets['package_sha256'] != hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest():
            raise ValueError('CI artifact manifest does not match checkout')
        validate_targets(listed_tests(listing), targets['targets'])
        test_fingerprints = json.loads((metadata / 'test-source-sha256.json').read_text(encoding='utf-8'))['source_sha256']
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f'CI artifact gate metadata missing or invalid: {error}') from error
    source_root = root / 'Sources/RepoPrompt'
    actual = {
        path.relative_to(source_root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in source_root.rglob('*.swift')
    }
    if not actual or fingerprints != actual or index != actual:
        raise ValueError('CI artifact build/index attestations do not match checked-out app source bytes')
    if test_fingerprints != test_source_hashes(root):
        raise ValueError('CI artifact test sources do not match the built test bundles')
    if sources_import_module(root / 'Tests', 'Testing'):
        raise ValueError('CI shard direct XCTest runner cannot run Swift Testing; add a separate runner before introducing it')
    suites = {line.strip().split('/', 1)[0] for line in listing.splitlines() if '/' in line.strip()}
    if not suites:
        raise ValueError('CI artifact has no listed tests')
    products = product_directory(root)
    if products is None:
        raise ValueError('CI artifact test products directory is missing')
    bundles = {path.stem for path in products.glob('*.xctest') if path.is_dir()}
    if not bundles:
        raise ValueError('CI artifact has no XCTest bundles')
    if not any(name.endswith('PackageTests') for name in bundles):
        missing = sorted({suite.split('.', 1)[0] for suite in suites} - bundles)
        if missing:
            raise ValueError(f'CI artifact is missing test bundles for {missing}')
    return products


def pack(root: Path, output: Path) -> int:
    products = validate(root)
    members = [root / METADATA / name for name in
               ('app-source-sha256.json', 'index-check.json', 'ci-test-list.txt', 'test-source-sha256.json', 'test-targets.json')]
    members += sorted(path for path in products.iterdir()
                      if (path.is_dir() and path.suffix in {'.xctest', '.bundle', '.framework'})
                      or (path.is_file() and path.suffix == '.dylib'))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w:gz', compresslevel=1, dereference=False) as archive:
        for path in members:
            archive.add(path, arcname=path.relative_to(root).as_posix(), recursive=True)
    print(f'CI artifact: {len(members)} metadata/product entries, {output.stat().st_size / 1024**2:.1f} MiB compressed')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('pack', 'verify'))
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        if args.command == 'verify':
            print(f'CI artifact verified: {validate(root)}')
            return 0
        if args.output is None:
            parser.error('pack requires --output')
        return pack(root, args.output.resolve())
    except ValueError as error:
        parser.exit(2, f'CI artifact: {error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
