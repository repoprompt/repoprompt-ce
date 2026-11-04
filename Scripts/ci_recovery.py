#!/usr/bin/env python3
"""Bounded CI recovery from trusted workflow code and read-only GitHub evidence."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode

WORKFLOW = '.github/workflows/ci.yml'
PRODUCT_WORKFLOW = '.github/workflows/ci-integration-products.yml'
MAX_ATTEMPTS = 3
ROOT = 'Build and Static Gates'
WORKER = 'Test Root Shards (No Build)'
AGGREGATE_STEPS = {'Report prerequisites and release eligibility', 'Fail if a prerequisite failed or was skipped'}
DOWNLOADS = {
    (WORKER, 'Download the single root build'): 'root-build',
    ('Style', 'Download expected coverage'): 'expected-coverage',
    ('Style', 'Download all shard execution receipts'): 'shard-execution-all',
}
EVICTION = re.compile(r"cancel(?:ing|ling) since a higher priority waiting request for (?P<quote>['\"]?)"
                     r"(?P<stage>ci-build-main|ci-tests-main|ci-sentry-main)(?P=quote) exists", re.I)
STAGE_GROUPS = {ROOT: 'ci-build-main', WORKER: 'ci-tests-main',
                'integration-products': 'ci-sentry-main',
                'integration-products / Sentry Build and Privacy': 'ci-sentry-main'}
STARTUP = re.compile(r'the job was not acquired by runner of type hosted even after multiple attempts'
                     r'|failed to provision (?:a |the )?hosted runner', re.I)
NON_TRANSIENT = re.compile(r'manually cancel|cancelled by|canceled by|spending limit|payments? (?:have )?failed'
                           r'|billing|insufficient permissions|not authorized', re.I)
MISSING = re.compile(r'Artifact not found for name:\s*[\'\"]?([A-Za-z0-9_-]+)', re.I)
TRANSPORT = re.compile(r'artifact download failed after [1-9][0-9]* retries', re.I)
DRIFT_MESSAGES = ('Admission failed: toolchain-drift: worker Swift/Xcode differs from the root build',
                  'Admission failed: toolchain-drift: worker architecture/Swift/Xcode differs from the root build')


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str
    job_id: int | None = None


class EvidenceError(RuntimeError):
    pass


class SubmissionError(RuntimeError):
    pass


def positive(value: object) -> int:
    if isinstance(value, bool) or not re.fullmatch(r'[1-9][0-9]*', str(value)):
        raise EvidenceError('Missing positive GitHub identity')
    return int(str(value))


def path_matches(value: str) -> bool:
    return isinstance(value, str) and value.split('@', 1)[0] == WORKFLOW


def event_guard(event: dict, run: dict, repository: str, workflow: dict) -> str | None:
    source = event.get('workflow_run') or {}
    if event.get('action') != 'completed' or (event.get('repository') or {}).get('full_name') != repository:
        return 'Not a completed event from this repository.'
    if (not path_matches(run.get('path')) or not path_matches(workflow.get('path'))
            or run.get('workflow_id') != workflow.get('id') or workflow.get('state') != 'active'):
        return 'Not the active CI workflow.'
    if ((run.get('repository') or {}).get('full_name') != repository
            or (run.get('head_repository') or {}).get('full_name') != repository):
        return 'Fork or unrelated repository; automatic recovery is not authorized.'
    if any(run.get(key) != source.get(key) for key in ('id', 'run_attempt', 'head_sha', 'event', 'workflow_id')):
        return 'A newer attempt or changed run identity superseded this event.'
    if run.get('status') != 'completed' or run.get('conclusion') not in ('failure', 'cancelled'):
        return 'The source run is not a completed failure or cancellation.'
    if run.get('event') not in ('push', 'pull_request'):
        return 'Only main pushes and same-repository pull requests have automatic recovery.'
    if not re.fullmatch(r'[0-9a-f]{40}', str(run.get('head_sha', ''))):
        return 'Invalid candidate commit.'
    return None


def failed_steps(job: dict) -> set[str]:
    return {step.get('name', '') for step in job.get('steps', [])
            if step.get('conclusion') in ('failure', 'cancelled', 'timed_out')}


def unassigned(job: dict) -> bool:
    return not job.get('runner_id') and not job.get('runner_name') and not job.get('steps')


def classify_job(job: dict, evidence: str, run: dict, artifacts: list[dict]) -> str | None:
    if NON_TRANSIENT.search(evidence):
        return None
    if unassigned(job) and job.get('conclusion') in ('cancelled', 'failure', 'startup_failure'):
        eviction = EVICTION.search(evidence)
        if (eviction and eviction['stage'].lower() == STAGE_GROUPS.get(job.get('name'))
                and run.get('event') == 'push' and run.get('head_branch') == 'main'):
            return 'evicted'
        if STARTUP.search(evidence) and run.get('conclusion') == 'failure':
            return 'startup'
    if job.get('conclusion') != 'failure':
        return None
    steps = failed_steps(job)
    if (job.get('name') == WORKER
            and steps == {'Select the successful root producer and verify toolchain'}
            and any(message in evidence for message in DRIFT_MESSAGES)):
        return 'rebuild'
    if len(steps) != 1:
        return None
    prefix = DOWNLOADS.get((job.get('name'), next(iter(steps))))
    if prefix is None:
        return None
    missing = MISSING.search(evidence)
    if missing:
        name = missing[1]
        match = re.fullmatch(re.escape(prefix) + '-' + str(positive(run['id'])) + r'-([1-9][0-9]*)', name)
        if match and int(match[1]) <= positive(run['run_attempt']):
            found = [artifact for artifact in artifacts if artifact.get('name') == name]
            if not found or all(artifact.get('expired') is True for artifact in found):
                return 'rebuild'
        return None
    if TRANSPORT.search(evidence):
        return 'transport'
    return None


def plan(run: dict, jobs: list[dict], diagnostics: dict[int, str], artifacts: list[dict],
         history: list[dict]) -> Decision:
    if run.get('status') != 'completed' or run.get('conclusion') not in ('failure', 'cancelled'):
        return Decision('none', 'The source run is not a completed failure or cancellation.')
    if not jobs or any(job.get('status') != 'completed' for job in jobs):
        return Decision('none', 'Job evidence is incomplete or execution has already resumed.')
    bad = [job for job in jobs if job.get('conclusion') not in ('success', 'skipped')]
    causes: list[tuple[dict, str]] = []
    for job in bad:
        steps = failed_steps(job)
        if (job.get('name') == 'Style' and job.get('conclusion') == 'failure'
                and steps and steps <= AGGREGATE_STEPS and any(j.get('name') != 'Style' for j in bad)):
            continue
        cause = classify_job(job, diagnostics.get(positive(job['id']), ''), run, artifacts)
        if cause is None:
            return Decision('none', 'A source/test/security failure, manual cancellation, or unclassified failure needs diagnosis.')
        causes.append((job, cause))
    if not causes:
        return Decision('none', 'No positively identified recoverable failure.')
    if positive(run['run_attempt']) >= MAX_ATTEMPTS:
        return Decision('none', 'Automatic recovery exhausted after three attempts; inspect the failed job before an explicit retry.')
    if run.get('conclusion') == 'cancelled' and any(cause != 'evicted' for _, cause in causes):
        return Decision('none', 'Cancelled workflows are not retried without exact current-main concurrency-eviction evidence.')
    if any(cause == 'rebuild' for _, cause in causes):
        if any(job.get('name') not in (WORKER, 'Style') for job, _ in causes):
            return Decision('none', 'Independent failures also block recovery; inspect them before rebuilding the root and dependents.')
        roots = [job for job in jobs if job.get('name') == ROOT and job.get('conclusion') == 'success']
        executions = {(job.get('started_at'), job.get('completed_at')) for job in history
                      if job.get('name') == ROOT and job.get('conclusion') == 'success'
                      and job.get('runner_id') and job.get('steps')}
        if len(roots) != 1 or not executions or any(None in times for times in executions):
            return Decision('none', 'Cannot prove the successful root producer and its execution history.')
        if len(executions) > 1:
            return Decision('none', 'The root producer has already been rebuilt; automatic rebuild is limited to once.')
        return Decision('rebuild', 'Missing/expired evidence or Swift/Xcode drift requires fresh root evidence and all its dependents.',
                        positive(roots[0]['id']))
    if any(cause == 'evicted' for _, cause in causes):
        if len(causes) != 1:
            return Decision('none', 'More than one independent failure prevents an isolated concurrency recovery.')
        return Decision('retry_job', 'The current main candidate was evicted from a pending CI stage; retry uses its own run group.',
                        positive(causes[0][0]['id']))
    return Decision('retry_failed', 'Only confirmed runner startup or artifact transport failures remain; retain successful jobs.')


class GitHub:
    def __init__(self, repository: str):
        if (not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository)
                or any(part in ('.', '..') for part in repository.split('/'))):
            raise EvidenceError('Invalid repository name')
        self.repository = repository

    def request(self, path: str, method: str = 'GET', raw: bool = False):
        try:
            result = subprocess.run(['gh', 'api', '--hostname', 'github.com', '--method', method,
                                     '-H', 'Accept: application/vnd.github+json',
                                     '-H', 'X-GitHub-Api-Version: 2022-11-28',
                                     f'repos/{self.repository}/{path}'],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False)
        except subprocess.TimeoutExpired as error:
            if method == 'POST':
                raise SubmissionError('Recovery submission outcome is unknown') from error
            raise
        if result.returncode:
            if method == 'POST':
                raise SubmissionError('Recovery submission was not confirmed')
            raise EvidenceError('GitHub request failed; no recovery decision is inferred from missing evidence')
        if len(result.stdout) > 8 * 1024 * 1024:
            raise EvidenceError('GitHub evidence exceeded the bounded response size')
        value = result.stdout.decode('utf-8-sig')
        return value if raw or method == 'POST' else json.loads(value)

    def pages(self, path: str, key: str | None = None) -> list[dict]:
        values: list[dict] = []
        separator = '&' if '?' in path else '?'
        for page in range(1, 21):
            payload = self.request(f'{path}{separator}per_page=100&page={page}')
            items = payload[key] if key else payload
            if not isinstance(items, list):
                raise EvidenceError('Invalid paginated GitHub response')
            values.extend(items)
            if len(items) < 100:
                if key and payload.get('total_count', len(values)) > len(values):
                    raise EvidenceError('GitHub returned incomplete paginated evidence')
                return values
        raise EvidenceError('GitHub evidence exceeds the bounded pagination limit')


def candidate_guard(api: GitHub, run: dict) -> str | None:
    if run['event'] == 'push':
        if run.get('head_branch') != 'main':
            return 'Not a protected-main push.'
        if api.request('git/ref/heads/main')['object']['sha'] != run['head_sha']:
            return 'A newer main commit superseded this candidate.'
    else:
        pulls = run.get('pull_requests', [])
        if len(pulls) != 1:
            return 'Cannot identify one current pull request.'
        number = positive(pulls[0]['number'])
        pull = api.request(f'pulls/{number}')
        head, base = pull.get('head') or {}, pull.get('base') or {}
        if (pull.get('state') != 'open' or pull.get('merged')
                or head.get('sha') != run['head_sha'] or head.get('ref') != run.get('head_branch')
                or (head.get('repo') or {}).get('full_name') != api.repository
                or base.get('ref') != 'main' or (base.get('repo') or {}).get('full_name') != api.repository):
            return 'The pull request closed, moved, changed repository, or has a newer candidate.'
        references = [item for item in run.get('referenced_workflows', [])
                      if item.get('path', '').split('@', 1)[0] == api.repository + '/' + PRODUCT_WORKFLOW
                      and item.get('ref') == f'refs/pull/{number}/merge']
        if len(references) != 1 or not re.fullmatch(r'[0-9a-f]{40}', str(references[0].get('sha', ''))):
            return 'The original PR merge candidate is unavailable or ambiguous; update the PR instead of retrying unknown evidence.'
        merge = api.request(f'git/commits/{references[0]["sha"]}')
        parents = [parent.get('sha') for parent in merge.get('parents', [])]
        if (merge.get('sha') != references[0]['sha']
                or parents != [base.get('sha'), run['head_sha']]):
            return 'The PR base or merge candidate changed; update the PR instead of retrying obsolete merge evidence.'
    query = urlencode({'event': run['event'], 'branch': run['head_branch'], 'per_page': 1})
    latest = api.request(f'actions/workflows/{positive(run["workflow_id"])}/runs?{query}')['workflow_runs']
    if not latest or latest[0]['id'] != run['id']:
        return 'A newer CI run superseded this candidate.'
    return None


def collect_diagnostics(api: GitHub, run: dict, jobs: list[dict]) -> dict[int, str]:
    result = {}
    for job in jobs:
        if job.get('conclusion') not in ('failure', 'cancelled', 'startup_failure'):
            continue
        job_id = positive(job['id'])
        if unassigned(job):
            check = re.fullmatch(re.escape(f'https://api.github.com/repos/{api.repository}/check-runs/')
                                 + r'([1-9][0-9]*)', str(job.get('check_run_url', '')))
            if not check:
                raise EvidenceError('Missing or unrelated check-run annotation identity')
            annotations = api.pages(f'check-runs/{positive(check[1])}/annotations')
            result[job_id] = '\n'.join(str(item.get('message', '')) for item in annotations
                                       if item.get('annotation_level') == 'failure')
        elif (job.get('name') in (WORKER, 'Style')
              and (failed_steps(job) == {'Select the successful root producer and verify toolchain'}
                   or any((job.get('name'), step) in DOWNLOADS for step in failed_steps(job)))):
            result[job_id] = api.request(f'actions/jobs/{job_id}/logs', raw=True)
    return result


def recover(api: GitHub, event: dict, execute: bool) -> tuple[Decision, dict]:
    run_id = positive(event.get('workflow_run', {}).get('id'))
    run = api.request(f'actions/runs/{run_id}')
    workflow = api.request('actions/workflows/ci.yml')
    rejection = event_guard(event, run, api.repository, workflow)
    if rejection:
        return Decision('none', rejection), run
    rejection = candidate_guard(api, run)
    if rejection:
        return Decision('none', rejection), run
    if positive(run['run_attempt']) >= MAX_ATTEMPTS:
        return Decision('none', 'Automatic recovery exhausted after three attempts; inspect the failed job before an explicit retry.'), run
    jobs = api.pages(f'actions/runs/{run_id}/jobs?filter=latest', 'jobs')
    diagnostics = collect_diagnostics(api, run, jobs)
    artifacts = api.pages(f'actions/runs/{run_id}/artifacts', 'artifacts')
    history = api.pages(f'actions/runs/{run_id}/jobs?filter=all', 'jobs')
    decision = plan(run, jobs, diagnostics, artifacts, history)
    if execute and decision.action != 'none':
        refreshed = api.request(f'actions/runs/{run_id}')
        rejection = event_guard(event, refreshed, api.repository, workflow) or candidate_guard(api, refreshed)
        if rejection:
            return Decision('none', rejection), refreshed
        if decision.action == 'retry_failed':
            api.request(f'actions/runs/{run_id}/rerun-failed-jobs', method='POST')
        else:
            api.request(f'actions/jobs/{positive(decision.job_id)}/rerun', method='POST')
    return decision, run


def write_summary(path: Path | None, decision: Decision, run: dict, repository: str, execute: bool) -> None:
    text = '## Bounded CI recovery\n\n'
    text += f'Action: **{decision.action}**' + (' (dry run)' if not execute else '') + '.\n\n'
    text += decision.reason + '\n\n'
    text += f'Automatic recovery stops after {MAX_ATTEMPTS} total source-run attempts and at most one successful-producer rebuild. '
    text += 'It never changes test results, accepts missing evidence, or publishes a release.\n\n'
    if run.get('id') and run.get('run_attempt'):
        text += f'[Source CI attempt](https://github.com/{repository}/actions/runs/{positive(run["id"])}/attempts/{positive(run["run_attempt"])})\n'
    if path:
        with path.open('a') as stream:
            stream.write(text)
    print(json.dumps(asdict(decision), sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event-path', type=Path, required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--summary', type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    run = {}
    try:
        if args.execute and (os.environ.get('GITHUB_EVENT_NAME') != 'workflow_run'
                             or os.environ.get('GITHUB_REF') != 'refs/heads/main'):
            raise EvidenceError('Execution requires the trusted default-branch workflow_run controller')
        decision, run = recover(GitHub(args.repository), json.loads(args.event_path.read_text()), args.execute)
        write_summary(args.summary, decision, run, args.repository, args.execute)
        return 0
    except SubmissionError:
        decision = Decision('none', 'The recovery request outcome is unconfirmed. Inspect the source run before submitting another retry.')
        write_summary(args.summary, decision, {}, args.repository, args.execute)
        return 1
    except (EvidenceError, KeyError, ValueError, TypeError, AttributeError, OSError, subprocess.TimeoutExpired):
        decision = Decision('none', 'Recovery evidence/API unavailable or invalid; no retry was submitted. Inspect this controller and the source run.')
        write_summary(args.summary, decision, {}, args.repository, args.execute)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
