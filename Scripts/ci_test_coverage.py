#!/usr/bin/env python3
"""Fail-closed XCTest execution receipts and cross-shard coverage verification."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

TEST_ID = re.compile(r'^[A-Za-z_][\w.]*\.[A-Za-z_][\w.]*/[^\s/]+$')
CASE = re.compile(r"Test Case '-\[([^\s]+) ([^\]]+)\]' (passed|skipped|failed) \(")
SUMMARY = re.compile(r'Executed (\d+) tests?, with (?:\d+ tests? skipped and )?(\d+) failures?')
TERMINAL = re.compile(r"Test Suite '(Selected tests|All tests)' passed at")


def listed_tests(listing: str) -> list[str]:
    tests = [line.strip() for line in listing.splitlines() if line.strip()]
    if not tests or any(not TEST_ID.fullmatch(test) for test in tests):
        raise ValueError('empty or malformed test listing')
    if len(tests) != len(set(tests)):
        raise ValueError('duplicate test identities in listing')
    return sorted(tests)


def validate_targets(tests: list[str], targets: list[str]) -> None:
    actual = {test.split('.', 1)[0] for test in tests}
    if not targets or len(targets) != len(set(targets)) or actual != set(targets):
        raise ValueError(f'test target coverage mismatch: missing={sorted(set(targets) - actual)}, '
                         f'unexpected={sorted(actual - set(targets))}')


def verify_execution(expected: list[str], text: str, returncode: int) -> dict:
    if returncode:
        raise ValueError(f'test process failed/crashed: exit {returncode}')
    cases = CASE.findall(text)
    executed = [f'{suite}/{method}' for suite, method, _ in cases]
    summaries = SUMMARY.findall(text)
    # A clean exit alone is insufficient: require XCTest's terminal suite and count too.
    if not TERMINAL.search(text) or not summaries:
        raise ValueError('missing terminal XCTest success/count (possible early exit)')
    if int(summaries[-1][0]) != len(expected) or int(summaries[-1][1]) != 0:
        raise ValueError(f'executed count mismatch: expected={len(expected)}, summary={summaries[-1]}')
    if Counter(executed) != Counter(expected) or any(status == 'failed' for _, _, status in cases):
        raise ValueError(f'executed identities mismatch: assigned={len(expected)}, executed={len(executed)}, '
                         f'missing={sorted(set(expected) - set(executed))[:10]}, '
                         f'unexpected={sorted(set(executed) - set(expected))[:10]}')
    return {'assigned': sorted(expected), 'executed': sorted(executed),
            'skipped': sorted(f'{suite}/{method}' for suite, method, status in cases if status == 'skipped')}


def listing_digest(tests: list[str]) -> str:
    return hashlib.sha256(('\n'.join(tests) + '\n').encode()).hexdigest()


def verify_shards(tests: list[str], targets: list[str], receipts: list[dict], shard_count: int) -> None:
    from ci_app_test_runner import assign_suites_to_shards, parse_suite_methods
    validate_targets(tests, targets)
    suites = parse_suite_methods('\n'.join(tests))
    shards, _ = assign_suites_to_shards({suite: len(methods) for suite, methods in suites.items()}, shard_count)
    if len(receipts) != shard_count or {r['shard_index'] for r in receipts} != set(range(1, shard_count + 1)):
        raise ValueError('missing or duplicate shard receipts')
    union: list[str] = []
    for receipt in receipts:
        if receipt['schema'] != 1 or receipt['shard_count'] != shard_count or receipt['listing_sha256'] != listing_digest(tests):
            raise ValueError('stale or incompatible shard receipt')
        assigned = sorted(test for suite in shards[receipt['shard_index'] - 1] for test in suites[suite])
        if not assigned or receipt['assigned'] != assigned or receipt['executed'] != assigned:
            raise ValueError('shard executed != deterministic assignment')
        union.extend(receipt['executed'])
    if Counter(union) != Counter(tests):
        raise ValueError('shard union != full built listing')
    print(f'Coverage verified: expected={len(tests)}, executed={len(union)}, targets={len(targets)}, shards={shard_count}')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=Path, required=True)
    parser.add_argument('--receipts', type=Path, required=True)
    parser.add_argument('--shard-count', type=int, required=True)
    args = parser.parse_args()
    try:
        tests = listed_tests((args.metadata / 'ci-test-list.txt').read_text())
        manifest = json.loads((args.metadata / 'test-targets.json').read_text())
        receipts = [json.loads(path.read_text()) for path in sorted(args.receipts.glob('shard-*.json'))]
        verify_shards(tests, manifest['targets'], receipts, args.shard_count)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        parser.exit(1, f'Coverage verification failed: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
