#!/usr/bin/env python3
"""One clean CI build of root test bundles with import, type-check, and warning ratchets."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from modularization_ci_artifact import test_source_hashes
from ci_admission import invalidate_build_identity
from swift_imports import sources_import_module
from ci_test_coverage import listed_tests, validate_targets
import hashlib

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / 'docs/migrations/build-modularization/build-ratchets.json'
APP_WARNING = re.compile(r'(?:^|[/ ])(Sources/RepoPrompt/[^:\n]+\.swift):(\d+):(\d+): warning: (.+)')
DURATION = re.compile(r'\b(\d+)ms\b')
ANSI_CSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
SOURCE_WARNING = re.compile(
    r'^\s*(?P<path>/[^:\n]+\.(?:swift|c|h|m|mm|cpp)):(?P<line>\d+):(?P<column>\d+): warning:\s*(?P<message>.+?)\s*$')
# Swift's diagnostic-group links are OSC 8 hyperlinks: ESC ] 8 ; ; url ST.
ANSI_OSC = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
TYPECHECK_TIMING = re.compile(r'took \d+ms to type-check')
FIRST_PARTY_ROOTS = ('Sources/', 'Tests/', 'Packages/')


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


def first_party_warning(line: str, root: Path) -> tuple[str, str, str, str] | None:
    """Identity of a repository-owned source warning, or None.

    The compiler repeats a diagnostic once per frontend job that type-checks the
    file (#519), so the identity is path, line, column, and message. Type-check
    timing warnings are induced by this build's -warn-long-* flags and belong to
    the type-check ratchet, not this one. Dependency checkouts live under .build.
    """
    match = SOURCE_WARNING.match(ANSI_CSI.sub('', ANSI_OSC.sub('', line)))
    if not match or TYPECHECK_TIMING.search(match['message']):
        return None
    path = Path(match['path'])
    for base in (root, root.resolve()):
        try:
            relative = path.relative_to(base).as_posix()
            break
        except ValueError:
            continue
    else:
        return None
    if not relative.startswith(FIRST_PARTY_ROOTS) or '/.build/' in f'/{relative}':
        return None
    return relative, match['line'], match['column'], match['message']


def warning_summary(warnings: set[tuple[str, str, str, str]], limit: int = 10) -> list[str]:
    by_file: dict[str, int] = {}
    for path, _, _, _ in warnings:
        by_file[path] = by_file.get(path, 0) + 1
    ranked = sorted(by_file.items(), key=lambda item: (-item[1], item[0]))[:limit]
    return [f'  {count:4d}  {path}' for path, count in ranked]


def report_warning_ratchet(warnings: set[tuple[str, str, str, str]], budget: dict) -> bool:
    """Print the unique first-party warning count against its ceiling; True when above it.

    A clean build sees every warning; an incremental build can only undercount.
    """
    ceiling = budget['first_party_unique']
    print(f'warning ratchet: first-party unique warnings {len(warnings)}/{ceiling}', flush=True)
    for summary in warning_summary(warnings):
        print(summary, flush=True)
    return len(warnings) > ceiling


def timing_counts(durations: dict[tuple[str, str, str, str], int]) -> dict[str, int]:
    counts = {'function_body': 0, 'expression': 0}
    for (_, _, _, kind), duration in durations.items():
        if duration >= (1000 if kind == 'function_body' else 500):
            counts[kind] += 1
    return counts


def write_timing_report(root: Path, durations: dict, baseline: dict, enforce: bool, exit_code: int,
                        warnings: set[tuple[str, str, str, str]] | None = None,
                        warning_budget: dict | None = None) -> None:
    """Keep per-location maximums on success AND failure; never change the timing budget."""
    destination = root / '.build/modularization/typecheck-timing.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    report = {
        'schema': 1, 'policy': 'clean-enforcing' if enforce else 'incremental-report-only',
        'build_exit_code': exit_code, 'budget': baseline, 'counts': timing_counts(durations),
        'locations': [dict(path=path, line=int(line), column=int(column), kind=kind, duration_ms=duration)
                      for (path, line, column, kind), duration in sorted(durations.items())],
    }
    if warnings is not None:
        report['first_party_warnings'] = {
            'budget': warning_budget, 'unique': len(warnings),
            'locations': [dict(path=path, line=int(line), column=int(column), message=message)
                          for path, line, column, message in sorted(warnings)],
        }
    destination.write_text(json.dumps(report, sort_keys=True) + '\n', encoding='utf-8')


def main() -> int:
    invalidate_build_identity(ROOT)
    ratchets = json.loads(BASELINE.read_text(encoding='utf-8'))
    baseline = ratchets['typecheck']
    warning_budget = ratchets['warnings']
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
    warnings: set[tuple[str, str, str, str]] = set()
    print('$ ' + ' '.join(command), flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end='', flush=True)
        record_warning(line, durations)
        warning = first_party_warning(line, ROOT)
        if warning:
            warnings.add(warning)
    code = process.wait()
    write_timing_report(ROOT, durations, baseline, enforce_timing, code, warnings, warning_budget)
    if code:
        return code
    warnings_regressed = report_warning_ratchet(warnings, warning_budget)
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
    if warnings_regressed and enforce_timing:
        print('warning ratchet regressed: fix the new first-party warnings '
              '(lower first_party_unique in build-ratchets.json after a verified cleanup)', file=sys.stderr)
    if (regressed or warnings_regressed) and enforce_timing:
        return 1
    if regressed:
        print('::warning::type-check timing exceeds baseline (report-only on this run)', flush=True)
    if warnings_regressed:
        print('::warning::first-party warnings exceed baseline (report-only on this run)', flush=True)
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
