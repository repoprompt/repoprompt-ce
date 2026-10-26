#!/usr/bin/env python3
"""One clean CI build of root test bundles with import and type-check ratchets."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from modularization_ci_artifact import test_source_hashes
from swift_imports import sources_import_module
from ci_test_coverage import listed_tests, validate_targets
import hashlib

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / 'docs/migrations/build-modularization/build-ratchets.json'
APP_WARNING = re.compile(r'(?:^|[/ ])(Sources/RepoPrompt/[^:\n]+\.swift):(\d+):(\d+): warning: (.+)')
DURATION = re.compile(r'\b(\d+)ms\b')
ANSI_CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def classify_warning(line: str) -> tuple[str, int, tuple[str, str, str, str]] | None:
    match = APP_WARNING.search(ANSI_CSI.sub('', line))
    if not match:
        return None
    message = match.group(4)
    duration = DURATION.search(message)
    if not duration or 'type-check' not in message:
        return None
    kind = 'expression' if 'expression' in message.lower() else 'function_body'
    path, line_number, column, _ = match.groups()
    return kind, int(duration.group(1)), (path, line_number, column, kind)


def record_warning(
    line: str,
    durations: dict[tuple[str, str, str, str], int],
) -> None:
    warning = classify_warning(line)
    if not warning:
        return
    _, duration, key = warning
    durations[key] = max(duration, durations.get(key, 0))


def timing_counts(durations: dict[tuple[str, str, str, str], int]) -> dict[str, int]:
    counts = {'function_body': 0, 'expression': 0}
    for (_, _, _, kind), duration in durations.items():
        if duration >= (1000 if kind == 'function_body' else 500):
            counts[kind] += 1
    return counts


def main() -> int:
    baseline = json.loads(BASELINE.read_text(encoding='utf-8'))['typecheck']
    enforce_timing = os.environ.get('TYPECHECK_RATCHET_ENFORCE', '1') == '1'
    if enforce_timing:
        clean = subprocess.run(['swift', 'package', 'clean'], cwd=ROOT, check=False)
        if clean.returncode:
            return clean.returncode
    command = [
        'swift', 'build', '--build-tests', '--explicit-target-dependency-import-check', 'error',
        '-Xswiftc', '-Xfrontend', '-Xswiftc', '-warn-long-function-bodies=999',
        '-Xswiftc', '-Xfrontend', '-Xswiftc', '-warn-long-expression-type-checking=499',
    ]
    durations: dict[tuple[str, str, str, str], int] = {}
    print('$ ' + ' '.join(command), flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end='', flush=True)
        record_warning(line, durations)
    code = process.wait()
    if code:
        return code
    counts = timing_counts(durations)
    print(f'type-check ratchet: app bodies >=1000ms {counts["function_body"]}/{baseline["function_bodies_1000ms"]}; '
          f'expressions >=500ms {counts["expression"]}/{baseline["expressions_500ms"]}', flush=True)
    for (path, line_number, column, kind), duration in sorted(durations.items()):
        if duration >= (1000 if kind == 'function_body' else 500):
            print(f'  {path}:{line_number}:{column}: {kind} {duration}ms', flush=True)
    regressed = (counts['function_body'] > baseline['function_bodies_1000ms'] or
                 counts['expression'] > baseline['expressions_500ms'])
    if regressed and enforce_timing:
        print('type-check ratchet regressed', file=sys.stderr)
        return 1
    if regressed:
        print('::warning::type-check timing exceeds baseline (report-only on this run)', flush=True)
    if sources_import_module(ROOT / 'Tests', 'Testing'):
        print('CI shard direct XCTest runner cannot run Swift Testing; add a separate runner before introducing it',
              file=sys.stderr)
        return 1
    listing = subprocess.run(['swift', 'test', 'list', '--skip-build'], cwd=ROOT,
                             capture_output=True, text=True)
    if listing.returncode:
        print(listing.stderr, file=sys.stderr)
        return listing.returncode
    try:
        tests = listed_tests(listing.stdout)
        manifest = json.loads(subprocess.run(['swift', 'package', 'dump-package'], cwd=ROOT,
                              check=True, capture_output=True, text=True).stdout)
        targets = sorted(target['name'] for target in manifest['targets'] if target['type'] == 'test')
        validate_targets(tests, targets)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'test target/listing coverage failed: {error}', file=sys.stderr)
        return 1
    destination = ROOT / '.build/modularization/ci-test-list.txt'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('\n'.join(tests) + '\n', encoding='utf-8')
    (destination.parent / 'test-targets.json').write_text(json.dumps({
        'targets': targets, 'package_sha256': hashlib.sha256((ROOT / 'Package.swift').read_bytes()).hexdigest(),
    }, sort_keys=True) + '\n')
    print(f'Expected coverage: {len(tests)} tests across {len(targets)} test targets: {targets}', flush=True)
    (destination.parent / 'test-source-sha256.json').write_text(
        json.dumps({'source_sha256': test_source_hashes(ROOT)}, sort_keys=True) + '\n', encoding='utf-8')
    print(f'captured {len(listing.stdout.splitlines())} test-list lines at {destination}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
