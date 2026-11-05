#!/usr/bin/env python3
"""Immutable identity/policy for the existing CI DAG, not a success registry."""
from __future__ import annotations

import argparse
import json
import os
import platform
from pathlib import Path
import re
import subprocess

# v3 separates the immutable event from the attempt that produced its build.
# A partial rerun may consume a successful ancestor, never a different build.
PROFILE = 'integration-v3'
# The enforcing wall-clock ratchet is measured on native ARM, not interchangeable
# runner pools. A platform change needs an explicit policy/evidence review.
ROOT_ARCHITECTURE = 'arm64'
METADATA = Path('.build/modularization/admission.json')
SHA = re.compile(r'^[0-9a-f]{40}$')
POSITIVE = re.compile(r'^[1-9][0-9]*$')
RECOVERY = 'Re-run Build and Static Gates (and dependents), or Re-run all jobs; do not bypass Style.'


class CandidateMismatch(ValueError):
    """A deterministic identity/policy failure, not a reason to retry builds."""


def positive(value: str) -> int:
    if not isinstance(value, str) or not POSITIVE.fullmatch(value):
        raise ValueError('invalid run/attempt identity')
    return int(value)


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def candidate(event_name: str, event: dict, sha: str, ref: str,
              run_id: str, attempt: str, tree: str) -> dict:
    if not all(SHA.fullmatch(value) and value != '0' * 40 for value in (sha, tree)):
        raise ValueError('candidate commit/tree must be full nonzero object IDs')
    positive(run_id)
    positive(attempt)
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
    return {'schema': 2, 'profile': PROFILE, 'event': event_name, 'head': sha, 'base': base,
            'ref': ref, 'tree': tree, 'run_id': run_id,
            'timing_policy': 'clean-enforcing', 'root_architecture': ROOT_ARCHITECTURE,
            'products': 'sentry-privacy'}


def verify(context: dict, root: Path, run_id: str, attempt: str) -> None:
    positive(run_id)
    positive(attempt)
    if not isinstance(context, dict) or context.get('schema') != 2 or context.get('profile') != PROFILE:
        raise CandidateMismatch('unknown admission profile')
    if context.get('run_id') != run_id or 'attempt' in context:
        raise CandidateMismatch('candidate run identity mismatch')
    if (context.get('timing_policy') != 'clean-enforcing' or context.get('products') != 'sentry-privacy'
            or context.get('root_architecture') != ROOT_ARCHITECTURE):
        raise CandidateMismatch('incomplete admission policy or wrong root measurement architecture')
    if git(root, 'rev-parse', 'HEAD') != context['head'] or git(root, 'rev-parse', 'HEAD^{tree}') != context['tree']:
        raise CandidateMismatch('admission candidate commit/tree does not match checkout')


def toolchain(root: Path) -> dict:
    try:
        versions = {name: subprocess.check_output(command, cwd=root, text=True).strip()
                    for name, command in (('swift', ['swift', '--version']), ('xcode', ['xcodebuild', '-version']))}
    except (OSError, subprocess.CalledProcessError) as error:
        selected = os.environ.get('DEVELOPER_DIR', '<system default>')
        raise CandidateMismatch(
            f'cannot inspect the selected Swift/Xcode toolchain (DEVELOPER_DIR={selected!r}). '
            'Check the installed reviewed pin and runner image; do not rerun unchanged configuration') from error
    return {**versions, 'architecture': platform.machine()}


def producer_context(context: dict, attempt: str, versions: dict) -> dict:
    positive(attempt)
    result = {'candidate': context, 'attempt': attempt, 'toolchain': versions}
    verify_producer(result, context, attempt)
    return result


def verify_producer(producer: dict, context: dict, current_attempt: str) -> None:
    if not isinstance(producer, dict) or producer.get('candidate') != context:
        raise ValueError('root producer candidate mismatch or missing output')
    if positive(producer.get('attempt')) > positive(current_attempt):
        raise ValueError('root producer is from a future attempt')
    versions = producer.get('toolchain')
    if (not isinstance(versions, dict) or set(versions) != {'swift', 'xcode', 'architecture'}
            or any(not isinstance(v, str) or not v.strip() for v in versions.values())):
        raise ValueError('missing root producer toolchain')
    if (context.get('root_architecture') != ROOT_ARCHITECTURE
            or versions['architecture'] != ROOT_ARCHITECTURE):
        raise CandidateMismatch(
            f'root build requires the {ROOT_ARCHITECTURE} measurement platform; '
            f'observed {versions["architecture"]!r}. Restore the intended runner; do not raise timing budgets')


def artifact_names(producer: dict) -> dict:
    suffix = producer['candidate']['run_id'] + '-' + producer['attempt']
    return {'build_artifact': 'root-build-' + suffix, 'coverage_artifact': 'expected-coverage-' + suffix}


def verify_receipt_artifact(name: str, run_id: str, attempt: str, build_attempt: str = '1') -> None:
    match = re.fullmatch(r'shard-execution-all-([1-9][0-9]*)-([1-9][0-9]*)', name)
    if not match or match[1] != run_id or not positive(build_attempt) <= positive(match[2]) <= positive(attempt):
        raise ValueError('missing or wrong run/attempt shard artifact output')


def write_outputs(path: Path, values: dict) -> None:
    if path is None:
        raise ValueError('command requires --output (GitHub job outputs)')
    with path.open('a') as output:
        for key, value in values.items():
            output.write(key + '=' + (json.dumps(value, sort_keys=True) if isinstance(value, dict) else value) + '\n')


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
    producer = identity['context']
    context = producer['candidate']
    # Structural/local checkout check only. Hosted consumers also compare this
    # exact identity with the successful producer's needs output, not itself.
    verify(context, root, context['run_id'], producer['attempt'])
    verify_producer(producer, context, producer['attempt'])
    return identity


def verify_build_identity(identity: dict, context: dict) -> None:
    if identity != {'producer': 'build-test-bundles', 'context': context}:
        raise ValueError('root build admission identity mismatch')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'verify', 'produce', 'select', 'bind', 'invalidate'))
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--context', help='explicit immutable candidate JSON; never read GITHUB_* inside conductor')
    parser.add_argument('--producer-context', help='successful root producer job output')
    parser.add_argument('--receipt-artifact', help='successful worker job output (required by the final gate)')
    parser.add_argument('--check-toolchain', action='store_true')
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
            write_outputs(args.output, {'context': context, 'range': context['base'] + '..' + context['head']})
            print(json.dumps(context, sort_keys=True))
        else:
            context = json.loads(args.context)
            verify(context, args.root, args.run_id, args.attempt)
            if args.command == 'invalidate':
                invalidate_build_identity(args.root)
            if args.command == 'produce':
                installed = toolchain(args.root)
                print(json.dumps({'root_measurement_toolchain': installed}, sort_keys=True))
                producer = producer_context(context, args.attempt, installed)
                write_outputs(args.output, {'context': producer, **artifact_names(producer)})
            if args.command in ('bind', 'select'):
                producer = json.loads(args.producer_context)
                verify_producer(producer, context, args.attempt)
                if args.check_toolchain:
                    installed = toolchain(args.root)
                    if installed['architecture'] != ROOT_ARCHITECTURE:
                        raise CandidateMismatch(
                            f'worker architecture {installed["architecture"]!r} violates the declared '
                            f'{ROOT_ARCHITECTURE} platform; restore the intended runner, not the root build')
                    if producer['toolchain'] != installed:
                        raise ValueError('toolchain-drift: worker Swift/Xcode differs from the root build')
                if args.command == 'bind':
                    if producer['attempt'] != args.attempt:
                        raise ValueError('cannot bind an earlier producer as a new build')
                    path = args.root / METADATA
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(json.dumps({'producer': 'build-test-bundles', 'context': producer}, sort_keys=True) + '\n')
                else:
                    outputs = artifact_names(producer)
                    if args.receipt_artifact is not None:
                        verify_receipt_artifact(args.receipt_artifact, args.run_id, args.attempt, producer['attempt'])
                        outputs['receipt_artifact'] = args.receipt_artifact
                    write_outputs(args.output, outputs)
                    print(f"Selected root build attempt {producer['attempt']} for consumer attempt {args.attempt}; exact candidate/run and producer-bound receipts required.")
    except CandidateMismatch as error:
        parser.exit(1, f'Admission failed: {error}. Inspect the original event/profile and update the PR for the intended candidate; rerunning cannot change its SHA/base.\n')
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Admission failed: {error}. {RECOVERY}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
