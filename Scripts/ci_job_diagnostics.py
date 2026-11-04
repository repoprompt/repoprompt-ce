#!/usr/bin/env python3
"""Bounded, read-only CI explanations. Evidence checks, not this report, grant success."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re

JOBS = {
    'candidate': 'Candidate declaration',
    'workflow-contracts': 'Portable checks',
    'build-test-bundles': 'Build and Static Gates',
    'build-and-test': 'Root test shards',
    'secret-scan': 'Secret Scan',
    'integration-products': 'Sentry build / privacy',
}
RECOVERY = '''### Recovery (no gate bypass)
- Open the failed job/step above. Skipped dependents are consequences, not root causes.
- Code, assertion, lint or coverage failure: fix the source and update the PR; rerunning the same code is not a fix.
- See **CI Recovery** for automatic recovery of verified runner startup failures and missing build evidence. Automatic recovery is bounded to three total attempts and never retries an assertion, lint, compiler or coverage failure.
- Confirmed transient runner/network failure outside automatic recovery: **Re-run failed jobs** or the failed job and its dependents. Successful ancestors remain bound to their original candidate and build.
- Missing/expired artifact or Swift/Xcode drift: recovery rebuilds the successful root producer once when the failure is positively identified. If recovery is exhausted or producer output is missing, **Re-run Build and Static Gates** and dependents. Evidence artifacts expire after 7 days.
- An obsolete pending main job may be superseded to preserve capacity. Its secret scan still runs. The current candidate is recovered if an out-of-order old request evicts it; ordinary user cancellation is respected.
- A rerun uses the original SHA/base, not today's main. Update the PR branch to test new integration code. Runs created before integration-v3 still require Re-run all jobs.
- Cancellation/runner loss may prevent a job report. Inspect the run timeline; absence of a report or a skipped job is never passing evidence.
'''


def safe_ids(value: str) -> str:
    # Outputs/step IDs are untrusted display data, never shell or Markdown.
    return ', '.join(re.findall(r'[A-Za-z0-9_-]{1,80}', str(value))[:12]) or 'not reported; inspect job log'


def job_report(steps: dict) -> tuple[str, str]:
    failed = [name for name, step in steps.items() if step.get('outcome') in ('failure', 'cancelled')]
    failure = safe_ids(' '.join(failed)) if failed else ''
    text = '## Job diagnostics\n\n'
    text += f'Failed/cancelled step IDs: **{failure}**.\n\n' if failed else 'No failed steps were reported to this reporter; the job result and final evidence gate remain authoritative.\n\n'
    if failed:
        text += RECOVERY
    return text, failure


def prerequisite_report(needs: dict, event: str) -> tuple[str, bool]:
    text = '## CI prerequisite results\n\n| Gate | Result | Failed step IDs |\n|---|---|---|\n'
    passed = set(needs) == set(JOBS)
    if not passed:
        text += '| Dependency contract | missing/unexpected job | inspect workflow dependency list |\n'
    for key, label in JOBS.items():
        job = needs.get(key, {})
        result = job.get('result', 'missing')
        if result not in ('success', 'failure', 'cancelled', 'skipped'):
            result = 'missing'
        passed &= result == 'success'
        failure = safe_ids(job.get('outputs', {}).get('failure', '')) if result == 'failure' else '—'
        text += f'| {label} | {result} | {failure} |\n'
    text += '\n**Prerequisites are not the final verdict:** exact build identity and complete test receipts must also pass below.\n'
    if event == 'push':
        text += '\n**Automatic Tip release is blocked unless main CI succeeds.** Tip selects the newest successful main-push CI source still on protected main, so a newer untested commit cannot strand an already qualified source. It then runs signed-artifact qualification. Stable/manual releases have separate gates.\n'
    else:
        text += '\nThis PR/queue run is integration evidence, not authority to publish a release.\n'
    return text + '\n' + RECOVERY, passed


def run(mode: str) -> int:
    if mode == 'job':
        text, failure = job_report(json.loads(os.environ['STEPS_CONTEXT']))
        output = os.environ.get('GITHUB_OUTPUT')
        if output:
            with Path(output).open('a') as stream:
                stream.write('failure=' + failure + '\n')
        passed = True  # Do not mask the original failed step with the reporter.
    else:
        text, passed = prerequisite_report(json.loads(os.environ['NEEDS_CONTEXT']), os.environ.get('GITHUB_EVENT_NAME', ''))
    run = (os.environ['GITHUB_SERVER_URL'] + '/' + os.environ['GITHUB_REPOSITORY']
           + '/actions/runs/' + os.environ['GITHUB_RUN_ID'] + '/attempts/' + os.environ['GITHUB_RUN_ATTEMPT'])
    text += f'\n[Run attempt and job logs]({run})\n'
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as stream:
        stream.write(text)
    print(text)
    if not passed:
        print('::error::CI prerequisite failed/cancelled/skipped. See the prerequisite table and failed step IDs; Style is the aggregate, not the original cause.')
    return 0 if passed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('job', 'prerequisites'))
    args = parser.parse_args()
    try:
        return run(args.mode)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Do not print input JSON/environment in an error; it is not trusted data.
        if args.mode == 'job':
            print('::warning::Job diagnostics unavailable; inspect the original job result/log. No success is inferred.')
            return 0
        print('::error::Prerequisite diagnostics invalid/unavailable; refusing evidence acceptance.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
