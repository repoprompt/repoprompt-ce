#!/usr/bin/env python3
"""Read-only, attempt-specific Actions job timing; requires authenticated gh."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import re
import subprocess


def timestamp(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.year < 2000:
        raise ValueError('invalid sentinel timestamp')
    if result.tzinfo is None:
        raise ValueError('timing requires timezone-aware timestamps')
    return result


def seconds(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    duration = (timestamp(end) - timestamp(start)).total_seconds()
    # Do not turn inconsistent API timestamps into apparently valid zero durations.
    return round(duration, 3) if duration >= 0 else None


def job_timing(job: dict, observed_at: str) -> dict:
    runner_id = job['runner_id']
    if runner_id is not None and (type(runner_id) is not int or runner_id < 0):
        raise ValueError('invalid runner identity')
    assigned = bool(runner_id)
    status = job['status']
    if status not in ('queued', 'waiting', 'pending', 'requested', 'in_progress', 'completed'):
        raise ValueError('unknown job status')
    started = job.get('started_at') if assigned and status in ('in_progress', 'completed') else None
    completed = job.get('completed_at')
    # GitHub can supply started_at for unassigned jobs: it isn't execution.
    queue_end = started or (observed_at if status in ('queued', 'waiting', 'pending', 'requested', 'in_progress') else None)
    execution_end = completed if status == 'completed' else observed_at
    return {
        'id': job['id'], 'name': job['name'], 'url': job.get('html_url'),
        'status': status, 'conclusion': job.get('conclusion'),
        'labels': job.get('labels', []), 'runner_id': runner_id, 'runner_assigned': assigned,
        'created_at': job.get('created_at'), 'started_at': started, 'completed_at': completed,
        'queue_seconds': seconds(job.get('created_at'), queue_end),
        'execution_seconds': seconds(started, execution_end),
        'timing_censored': status != 'completed',
    }


def report(run: dict, jobs: list[dict], observed_at: str) -> dict:
    if len({job['id'] for job in jobs}) != len(jobs):
        raise ValueError('duplicate job IDs in API pages')
    if any(job.get('run_id') != run['id'] for job in jobs):
        raise ValueError('wrong job run identity')
    if any(job.get('run_attempt') != run['run_attempt'] for job in jobs):
        raise ValueError('mixed or missing job attempt identity')
    timings = [job_timing(job, observed_at) for job in jobs]
    mac = [job for job in timings if any(label.lower().startswith('macos-') or label.lower() == 'macos' for label in job['labels'])]
    return {
        'run_id': run['id'], 'attempt': run['run_attempt'], 'url': run['html_url'],
        'workflow': run['name'], 'head_sha': run['head_sha'], 'event': run['event'],
        'status': run['status'], 'conclusion': run['conclusion'],
        'run_created_at': run['created_at'],
        'observed_at': observed_at,
        'jobs_total': len(jobs),
        'queue_unknown_count': sum(j['queue_seconds'] is None for j in timings),
        'execution_unknown_count': sum(j['execution_seconds'] is None for j in timings),
        'censored_count': sum(j['timing_censored'] for j in timings),
        'observed_macos_jobs': len(mac),
        'running_macos_jobs': sum(j['status'] == 'in_progress' and j['runner_assigned'] for j in mac),
        'unassigned_macos_jobs': sum(j['status'] != 'completed' and not j['runner_assigned'] for j in mac),
        'sum_observed_macos_execution_seconds': round(sum(j['execution_seconds'] or 0 for j in mac), 3),
        'jobs': timings,
    }


def api(endpoint: str, *, pages: bool = False):
    command = ['gh', 'api', '--method', 'GET', endpoint]
    if pages:
        command += ['--paginate', '--slurp']
    result = subprocess.run(command, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError(f'GitHub GET failed (exit {result.returncode}); check gh authentication/access')
    return json.loads(result.stdout)


def collect(repo: str, run_id: int) -> dict:
    endpoint = f'repos/{repo}/actions/runs/{run_id}'
    run = api(endpoint)
    if run['id'] != run_id:
        raise ValueError('wrong run identity')
    fetch_started_at = datetime.now(timezone.utc).isoformat()
    # Pin the attempt: never mix an older attempt's successful prerequisites.
    pages = api(f"{endpoint}/attempts/{run['run_attempt']}/jobs?per_page=100", pages=True)
    if not pages or any(not isinstance(p, dict) or not isinstance(p.get('jobs'), list) for p in pages):
        raise ValueError('malformed job pages')
    jobs = [job for page in pages for job in page['jobs']]
    if any(page.get('total_count') != len(jobs) for page in pages):
        raise ValueError('job inventory changed or was truncated; collect again')
    observed_at = datetime.now(timezone.utc).isoformat()
    result = report(run, jobs, observed_at)
    latest = api(endpoint)
    if latest['run_attempt'] != run['run_attempt']:
        raise ValueError(f'run {run_id} changed attempt during collection; collect again')
    if latest['id'] != run_id or latest['head_sha'] != run['head_sha']:
        raise ValueError('run identity changed during collection')
    result['fetch_started_at'] = fetch_started_at
    result['run_status_at_end'] = latest['status']
    result['run_conclusion_at_end'] = latest['conclusion']
    result['run_state_changed_during_collection'] = (latest['status'], latest['conclusion']) != (run['status'], run['conclusion'])
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='repoprompt/repoprompt-ce')
    parser.add_argument('--run', type=int, action='append', required=True, help='repeat for comparison')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or any(p in ('.', '..') for p in args.repo.split('/')) or any(i <= 0 for i in args.run):
        parser.error('use owner/repository and positive run IDs')
    try:
        results = [collect(args.repo, run_id) for run_id in dict.fromkeys(args.run)]
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, TypeError) as error:
        parser.exit(1, f'Cannot produce complete timing report: {error}\n')
    print(json.dumps({'schema': 1, 'notes': [
        'Snapshot only: dependent jobs not yet created are absent; in-progress timings are approximate snapshots, subject to API races and clock skew.',
        'Summed execution is runner time, not critical-path latency, billed time, or organization utilization.',
        'Unassigned terminal jobs have unknown queue duration and no execution duration.',
        'Mixed job attempt IDs are rejected; this diagnostic does not certify admission or partial-rerun lineage.',
        'Queue means job created_at to actual start; approval/concurrency waits are not necessarily runner-capacity delays.',
    ], 'runs': results}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
