#!/usr/bin/env python3
"""Compatibility key for secret-free SwiftPM intermediates, never release evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


POLICY_FILES = (
    'Scripts/ci_release_cache.py',
    'Scripts/build_swiftpm_release_products.sh',
    'Scripts/patch_keyboard_shortcuts_resource_lookup.sh',
    'Scripts/run_without_github_tokens.sh',
    'Scripts/compare_swiftpm_release_resources.py',
    'Scripts/package_app.sh',
    'Scripts/release.sh',
    'Scripts/main_tip_release.sh',
    'Scripts/release_sentry_symbols.sh',
    'Scripts/conductor.py',
    'Vendor/Sparkle/SHA256SUMS',
    '.github/workflows/ci-integration-products.yml',
    '.github/workflows/ci.yml',
    '.github/workflows/main-tip.yml',
    '.github/workflows/release.yml',
)


def _package_directories(source: Path):
    for name in ('Packages', 'Vendor'):
        yield from os.walk(source / name)


def key(source: Path, tooling: Path, sentry: bool, toolchain: dict) -> str:
    files = {}
    for path in ('Package.swift', 'Package.resolved'):
        files['source/' + path] = (source / path).read_bytes().hex()
    # Never walk restored dependency/build trees: their manifests are not policy.
    for directory, children, names in _package_directories(source):
        children[:] = [name for name in children if not name.startswith('.')]
        for name in ('Package.swift', 'Package.resolved'):
            if name in names:
                path = Path(directory) / name
                files['source/' + path.relative_to(source).as_posix()] = path.read_bytes().hex()
    for name in POLICY_FILES:
        files['tooling/' + name] = (tooling / name).read_bytes().hex()
    for path in sorted((tooling / 'Scripts/patches').glob('*.patch')):
        files['tooling/' + path.relative_to(tooling).as_posix()] = path.read_bytes().hex()
    identity = {'schema': 1, 'source_path': str(source.resolve()),
                'tooling_path': str(tooling.resolve()), 'sentry': sentry,
                'toolchain': toolchain, 'files': files}
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return 'swiftpm-release-v2-' + digest


def installed_toolchain() -> dict:
    def output(*command):
        return subprocess.check_output(command, text=True).strip()
    return {'architecture': platform.machine(), 'os': platform.mac_ver()[0],
            'image_os': os.environ.get('ImageOS', ''),
            'image_version': os.environ.get('ImageVersion', ''),
            'xcode': output('xcodebuild', '-version'),
            'swift': output('xcrun', 'swift', '--version'),
            'sdk_path': output('xcrun', '--sdk', 'macosx', '--show-sdk-path'),
            'sdk_version': output('xcrun', '--sdk', 'macosx', '--show-sdk-version')}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path.cwd())
    parser.add_argument('--tooling-root', type=Path, default=Path.cwd())
    parser.add_argument('--sentry', choices=('0', '1'), required=True)
    args = parser.parse_args()
    print(key(args.source_root.resolve(), args.tooling_root.resolve(),
              args.sentry == '1', installed_toolchain()))


if __name__ == '__main__':
    main()
