#!/usr/bin/env python3
"""Immutable identity/policy for the existing CI DAG, not a success registry."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

PROFILE = 'integration-v1'
METADATA = Path('.build/modularization/admission.json')
SHA = re.compile(r'^[0-9a-f]{40}$')


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def candidate(event_name: str, event: dict, sha: str, ref: str,
              run_id: str, attempt: str, tree: str) -> dict:
    if not all(SHA.fullmatch(value) and value != '0' * 40 for value in (sha, tree)):
        raise ValueError('candidate commit/tree must be full nonzero object IDs')
    if not run_id.isdecimal() or not attempt.isdecimal() or min(int(run_id), int(attempt)) < 1:
        raise ValueError('invalid run/attempt identity')
    if event_name == 'pull_request':
        base = event['pull_request']['base']['sha']
        if event['pull_request']['base']['ref'] != 'main' or not re.fullmatch(r'refs/pull/[0-9]+/merge', ref):
            raise ValueError('PR admission requires the synthetic merge into main')
    elif event_name == 'merge_group':
        group = event['merge_group']
        if (event['action'] != 'checks_requested' or group['base_ref'] != 'refs/heads/main'
                or group['head_sha'] != sha or group['head_ref'] != ref):
            raise ValueError('merge-group candidate/ref does not match the requested main integration')
        base = group['base_sha']
    elif event_name == 'push' and ref == 'refs/heads/main':
        if event['after'] != sha or event['ref'] != ref:
            raise ValueError('push candidate/ref mismatch')
        base = event['before']
    else:
        raise ValueError('unsupported admission event/target')
    if not SHA.fullmatch(base) or base == '0' * 40:
        raise ValueError('admission requires a real base commit; no unbounded scan fallback')
    return {'schema': 1, 'profile': PROFILE, 'event': event_name, 'head': sha, 'base': base,
            'ref': ref, 'tree': tree, 'run_id': run_id, 'attempt': attempt,
            'timing_policy': 'clean-enforcing', 'products': 'sentry-privacy-and-release-smoke'}


def verify(context: dict, root: Path, run_id: str, attempt: str) -> None:
    if context.get('schema') != 1 or context.get('profile') != PROFILE:
        raise ValueError('unknown admission profile')
    if context.get('run_id') != run_id or context.get('attempt') != attempt:
        raise ValueError('Partial/failed-jobs-only reruns are unsupported: select Re-run all jobs for a full profile attempt')
    if context.get('timing_policy') != 'clean-enforcing' or context.get('products') != 'sentry-privacy-and-release-smoke':
        raise ValueError('incomplete admission policy')
    if git(root, 'rev-parse', 'HEAD') != context['head'] or git(root, 'rev-parse', 'HEAD^{tree}') != context['tree']:
        raise ValueError('admission candidate commit/tree does not match checkout')


def invalidate_build_identity(root: Path) -> None:
    # A cache is acceleration, never evidence. Even a failed clean/rebuild must
    # not leave the previous candidate's binding available to a local runner.
    (root / METADATA).unlink(missing_ok=True)
    # An early producer failure must not upload a cached sample as this attempt.
    (root / METADATA).with_name('typecheck-timing.json').unlink(missing_ok=True)


def build_identity(root: Path) -> dict | None:
    path = root / METADATA
    if not path.exists():
        return None  # Non-hosted/local runners do not claim hosted admission.
    identity = json.loads(path.read_text())
    if identity['producer'] != 'build-test-bundles':
        raise ValueError('unexpected root build producer')
    context = identity['context']
    verify(context, root, context['run_id'], context['attempt'])
    return identity


def verify_build_identity(identity: dict, context: dict) -> None:
    if identity != {'producer': 'build-test-bundles', 'context': context}:
        raise ValueError('root build admission identity mismatch')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'verify', 'bind', 'invalidate'))
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--context', help='explicit immutable candidate JSON; never read GITHUB_* inside conductor')
    parser.add_argument('--event-path', type=Path)
    parser.add_argument('--event-name')
    parser.add_argument('--sha')
    parser.add_argument('--ref')
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--attempt', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            context = candidate(args.event_name, json.loads(args.event_path.read_text()), args.sha,
                                args.ref, args.run_id, args.attempt, git(args.root, 'rev-parse', 'HEAD^{tree}'))
            verify(context, args.root, args.run_id, args.attempt)
            # Fail on incomplete history or an unrelated base, rather than scanning a different range.
            subprocess.run(['git', 'merge-base', '--is-ancestor', context['base'], context['head']],
                           cwd=args.root, check=True)
            if args.output is None:
                raise ValueError('prepare requires --output (GitHub job outputs)')
            with args.output.open('a') as output:
                output.write('context=' + json.dumps(context, sort_keys=True) + '\n')
                output.write('range=' + context['base'] + '..' + context['head'] + '\n')
            print(json.dumps(context, sort_keys=True))
        else:
            context = json.loads(args.context)
            verify(context, args.root, args.run_id, args.attempt)
            if args.command == 'invalidate':
                invalidate_build_identity(args.root)
            if args.command == 'bind':
                path = args.root / METADATA
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({'producer': 'build-test-bundles', 'context': context}, sort_keys=True) + '\n')
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Admission failed: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
