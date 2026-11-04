#!/usr/bin/env python3
"""Exercise recovery decisions, candidate leases and GitHub trust boundaries."""
from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import ci_recovery as recovery

REPOSITORY = 'repoprompt/repoprompt-ce'
SHA = 'a' * 40
BASE = 'b' * 40
MERGE = 'c' * 40
STARTUP = 'The job was not acquired by Runner of type hosted even after multiple attempts'
SELECT = 'Select the successful root producer and verify toolchain'
DRIFT = 'Admission failed: toolchain-drift: worker Swift/Xcode differs from the root build.'


def source(**overrides):
    value = {'id': 101, 'workflow_id': 501, 'run_attempt': 1, 'event': 'push',
             'head_sha': SHA, 'head_branch': 'main', 'path': recovery.WORKFLOW,
             'status': 'completed', 'conclusion': 'failure',
             'repository': {'full_name': REPOSITORY}, 'head_repository': {'full_name': REPOSITORY},
             'pull_requests': []}
    value.update(overrides)
    return value


def event(run):
    return {'action': 'completed', 'repository': {'full_name': REPOSITORY}, 'workflow_run': deepcopy(run)}


def job(name, identity, conclusion='success', failed=None, assigned=True, **overrides):
    value = {'id': identity, 'name': name, 'status': 'completed', 'conclusion': conclusion,
             'runner_id': 9 if assigned else 0, 'runner_name': 'hosted' if assigned else '',
             'check_run_url': f'https://api.github.com/repos/{REPOSITORY}/check-runs/{identity + 9000}',
             'started_at': '2026-11-04T12:00:00Z', 'completed_at': '2026-11-04T12:01:00Z',
             'steps': [{'name': failed or 'Set up job', 'conclusion': 'failure' if failed else 'success'}]
                      if assigned else []}
    value.update(overrides)
    return value


def aggregate():
    return job('Style', 40, 'failure', 'Report prerequisites and release eligibility')


def worker_failure(step):
    return [job(recovery.ROOT, 10), job(recovery.WORKER, 20, 'failure', step), aggregate()]


class PlannerTests(unittest.TestCase):
    def test_startup_failure_retries_failed_jobs_and_retains_successes(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False), aggregate()]
        self.assertEqual(recovery.plan(source(), jobs, {10: STARTUP}, [], jobs).action, 'retry_failed')

    def test_unassigned_without_annotation_is_not_a_startup_diagnosis(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False), aggregate()]
        self.assertEqual(recovery.plan(source(), jobs, {}, [], jobs).action, 'none')

    def test_manual_cancellation_and_billing_never_retry(self):
        for text in ('Cancelled by baron. ' + STARTUP, 'Billing spending limit. ' + STARTUP,
                     'The operation was canceled.'):
            with self.subTest(text=text):
                jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False), aggregate()]
                self.assertEqual(recovery.plan(source(), jobs, {10: text}, [], jobs).action, 'none')

    def test_cancelled_run_is_not_retried_for_startup_annotation(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False)]
        self.assertEqual(recovery.plan(source(conclusion='cancelled'), jobs, {10: STARTUP}, [], jobs).action, 'none')

    def test_main_pending_eviction_reruns_only_that_job_and_dependents(self):
        for name, group in recovery.STAGE_GROUPS.items():
            for conclusion in ('failure', 'cancelled'):
                for quote in ('', "'", '"'):
                    with self.subTest(name=name, conclusion=conclusion, quote=quote):
                        jobs = [job(name, 10, 'cancelled', assigned=False)]
                        text = f"Canceling since a higher priority waiting request for {quote}{group}{quote} exists"
                        decision = recovery.plan(source(conclusion=conclusion), jobs, {10: text}, [], jobs)
                        self.assertEqual((decision.action, decision.job_id), ('retry_job', 10))

    def test_eviction_rejects_mismatched_quotes_and_group_suffixes(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False)]
        for group in ("'ci-build-main\"", '\"ci-build-main\'', "'ci-build-main", "ci-build-main'",
                      '\"ci-build-main', 'ci-build-main\"', 'ci-build-main-other', "'ci-build-main-other'",
                      '\"ci-build-main-other\"'):
            with self.subTest(group=group):
                text = f"Canceling since a higher priority waiting request for {group} exists"
                decision = recovery.plan(source(conclusion='cancelled'), jobs, {10: text}, [], jobs)
                self.assertEqual(decision.action, 'none')

    def test_reusable_caller_eviction_requires_exact_name_and_annotation(self):
        text = 'Canceling since a higher priority waiting request for ci-sentry-main exists'
        for name, evidence, assigned, expected in (
                ('integration-products', text, False, 'retry_job'),
                ('integration-products-other', text, False, 'none'),
                ('integration-products', text.replace('ci-sentry-main', 'ci-build-main'), False, 'none'),
                ('integration-products', '', False, 'none'),
                ('integration-products', text, True, 'none')):
            with self.subTest(name=name, evidence=evidence, assigned=assigned):
                jobs = [job(recovery.ROOT, 10), job(recovery.WORKER, 20),
                        job(name, 30, 'cancelled', assigned=assigned), aggregate()]
                decision = recovery.plan(source(), jobs, {30: evidence}, [], jobs)
                self.assertEqual(decision.action, expected)
                if expected == 'retry_job':
                    self.assertEqual(decision.job_id, 30)

    def test_eviction_requires_the_exact_stage_group_and_main(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False)]
        for run, group in ((source(event='pull_request'), 'ci-build-main'),
                           (source(), 'ci-build-other'), (source(), 'ci-tests-main')):
            with self.subTest(run=run['event'], group=group):
                text = f"Canceling since a higher priority waiting request for '{group}' exists"
                self.assertEqual(recovery.plan(run, jobs, {10: text}, [], jobs).action, 'none')

    def test_source_failure_blocks_even_a_simultaneous_startup_failure(self):
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False),
                job('Portable Checks', 11, 'failure', 'Run conductor tests'), aggregate()]
        self.assertEqual(recovery.plan(source(), jobs, {10: STARTUP}, [], jobs).action, 'none')

    def test_artifact_words_inside_a_failing_test_cannot_trigger_recovery(self):
        jobs = worker_failure('Run root test shard 1 without compiling')
        for text in (STARTUP, DRIFT, 'Artifact not found for name: root-build-101-1',
                     'Artifact download failed after 5 retries.'):
            with self.subTest(text=text):
                self.assertEqual(recovery.plan(source(), jobs, {20: text}, [], jobs).action, 'none')

    def test_missing_build_rebuilds_successful_root_and_dependents(self):
        jobs = worker_failure('Download the single root build')
        decision = recovery.plan(source(), jobs, {20: 'Artifact not found for name: root-build-101-1'}, [], jobs)
        self.assertEqual((decision.action, decision.job_id), ('rebuild', 10))

    def test_expired_coverage_and_receipts_rebuild_the_root(self):
        for step, name in (('Download expected coverage', 'expected-coverage-101-1'),
                           ('Download all shard execution receipts', 'shard-execution-all-101-1')):
            with self.subTest(step=step):
                jobs = [job(recovery.ROOT, 10), job(recovery.WORKER, 20), job('Style', 40, 'failure', step)]
                decision = recovery.plan(source(), jobs, {40: 'Artifact not found for name: ' + name},
                                         [{'name': name, 'expired': True}], jobs)
                self.assertEqual((decision.action, decision.job_id), ('rebuild', 10))

    def test_available_wrong_run_future_or_empty_artifacts_do_not_rebuild(self):
        jobs = worker_failure('Download the single root build')
        for name, inventory in (('root-build-101-1', [{'name': 'root-build-101-1', 'expired': False}]),
                                ('root-build-102-1', []), ('root-build-101-2', []), ('', []),
                                ('expected-coverage-101-1', [])):
            with self.subTest(name=name):
                decision = recovery.plan(source(), jobs, {20: 'Artifact not found for name: ' + name}, inventory, jobs)
                self.assertEqual(decision.action, 'none')

    def test_toolchain_drift_rebuilds_but_identity_errors_do_not(self):
        jobs = worker_failure(SELECT)
        for text in recovery.DRIFT_MESSAGES:
            self.assertEqual(recovery.plan(source(), jobs, {20: text}, [], jobs).action, 'rebuild')
        self.assertEqual(recovery.plan(source(), jobs, {20: 'Admission failed: root producer candidate mismatch'}, [], jobs).action, 'none')

    def test_pure_artifact_transport_failure_reuses_successful_root(self):
        jobs = worker_failure('Download the single root build')
        decision = recovery.plan(source(), jobs, {20: 'Artifact download failed after 5 retries.'}, [], jobs)
        self.assertEqual(decision.action, 'retry_failed')

    def test_second_successful_producer_rebuild_is_refused(self):
        jobs = worker_failure(SELECT)
        older = job(recovery.ROOT, 1, started_at='2026-11-03T12:00:00Z', completed_at='2026-11-03T12:01:00Z')
        decision = recovery.plan(source(run_attempt=2), jobs, {20: DRIFT}, [], [older] + jobs)
        self.assertEqual(decision.action, 'none')
        self.assertIn('already been rebuilt', decision.reason)

    def test_retained_job_copies_are_not_counted_as_new_producers(self):
        jobs = worker_failure(SELECT)
        retained_copy = job(recovery.ROOT, 1)
        decision = recovery.plan(source(run_attempt=2), jobs, {20: DRIFT}, [], [retained_copy] + jobs)
        self.assertEqual(decision.action, 'rebuild')

    def test_no_rebuild_without_producer_execution_history(self):
        jobs = worker_failure(SELECT)
        self.assertEqual(recovery.plan(source(), jobs, {20: DRIFT}, [], []).action, 'none')

    def test_attempt_cap_applies_to_startup_eviction_and_rebuild(self):
        jobs = worker_failure(SELECT)
        decision = recovery.plan(source(run_attempt=3), jobs, {20: DRIFT}, [], jobs)
        self.assertEqual(decision.action, 'none')
        self.assertIn('exhausted', decision.reason)
        jobs = [job(recovery.ROOT, 10, 'cancelled', assigned=False)]
        for text in (STARTUP, "Canceling since a higher priority waiting request for 'ci-build-main' exists"):
            self.assertEqual(recovery.plan(source(run_attempt=3), jobs, {10: text}, [], jobs).action, 'none')

    def test_never_reruns_success_in_progress_or_missing_jobs(self):
        for run, jobs in ((source(conclusion='success'), worker_failure(SELECT)),
                          (source(status='in_progress'), worker_failure(SELECT)), (source(), [])):
            self.assertEqual(recovery.plan(run, jobs, {20: DRIFT}, [], jobs).action, 'none')

    def test_independent_failure_prevents_an_incomplete_root_only_retry(self):
        jobs = worker_failure(SELECT) + [job('Secret Scan', 30, 'cancelled', assigned=False)]
        self.assertEqual(recovery.plan(source(), jobs, {20: DRIFT, 30: STARTUP}, [], jobs).action, 'none')


class FakeGitHub:
    repository = REPOSITORY

    def __init__(self, run=None, jobs=None):
        self.run = deepcopy(run or source())
        self.workflow = {'id': 501, 'path': recovery.WORKFLOW, 'state': 'active'}
        self.jobs = jobs or [job(recovery.ROOT, 10, 'cancelled', assigned=False), aggregate()]
        self.history = deepcopy(self.jobs)
        self.artifacts = []
        self.annotations = [{'annotation_level': 'failure', 'message': STARTUP}]
        self.log = ''
        self.main = self.run['head_sha']
        self.latest = self.run['id']
        self.pull = {'state': 'open', 'merged': False,
                     'head': {'sha': SHA, 'ref': 'fix/ci', 'repo': {'full_name': REPOSITORY}},
                     'base': {'sha': BASE, 'ref': 'main', 'repo': {'full_name': REPOSITORY}}}
        self.merge = {'sha': MERGE, 'parents': [{'sha': BASE}, {'sha': SHA}]}
        self.refreshed = None
        self.reads = []
        self.writes = []
        self.run_reads = 0

    def request(self, path, method='GET', raw=False):
        if method == 'POST':
            self.writes.append(path)
            return ''
        self.reads.append(path)
        if path == 'actions/runs/101':
            self.run_reads += 1
            return deepcopy(self.refreshed if self.refreshed and self.run_reads > 1 else self.run)
        if path == 'actions/workflows/ci.yml':
            return self.workflow
        if path == 'git/ref/heads/main':
            return {'object': {'sha': self.main}}
        if path.startswith('actions/workflows/501/runs?'):
            return {'workflow_runs': [{'id': self.latest}]}
        if path == 'pulls/7':
            return self.pull
        if path == 'git/commits/' + MERGE:
            return self.merge
        if path.startswith('actions/jobs/') and path.endswith('/logs'):
            self.assert_raw = raw
            return self.log
        raise AssertionError(path)

    def pages(self, path, key=None):
        self.reads.append(path)
        if path == 'actions/runs/101/jobs?filter=latest':
            return self.jobs
        if path == 'actions/runs/101/jobs?filter=all':
            return self.history
        if path == 'actions/runs/101/artifacts':
            return self.artifacts
        if path == 'check-runs/9010/annotations':
            return self.annotations
        raise AssertionError(path)


class ControllerTests(unittest.TestCase):
    def test_execute_submits_once_after_rechecking_candidate(self):
        api = FakeGitHub()
        decision, _ = recovery.recover(api, event(api.run), True)
        self.assertEqual(decision.action, 'retry_failed')
        self.assertEqual(api.writes, ['actions/runs/101/rerun-failed-jobs'])
        self.assertEqual(api.run_reads, 2)
        self.assertIn('check-runs/9010/annotations', api.reads)
        self.assertNotIn('check-runs/10/annotations', api.reads)

    def test_dry_run_never_mutates(self):
        api = FakeGitHub()
        self.assertEqual(recovery.recover(api, event(api.run), False)[0].action, 'retry_failed')
        self.assertEqual(api.writes, [])

    def test_newer_attempt_between_read_and_submission_revokes_the_lease(self):
        api = FakeGitHub()
        api.refreshed = source(run_attempt=2, status='in_progress', conclusion=None)
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')
        self.assertEqual(api.writes, [])

    def test_source_identity_changes_or_inactive_workflow_never_mutate(self):
        for update in ({'head_repository': {'full_name': 'attacker/fork'}}, {'head_repository': None},
                       {'path': '.github/workflows/other.yml'},
                       {'workflow_id': 777}, {'event': 'workflow_dispatch'}, {'head_branch': 'other'}):
            with self.subTest(update=update):
                api = FakeGitHub(source(**update))
                self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')
                self.assertEqual(api.writes, [])
        api = FakeGitHub()
        api.workflow['state'] = 'disabled_manually'
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')

    def test_workflow_path_suffix_is_accepted(self):
        api = FakeGitHub(source(path=recovery.WORKFLOW + '@main'))
        self.assertEqual(recovery.recover(api, event(api.run), False)[0].action, 'retry_failed')

    def test_old_events_old_main_and_superseded_runs_never_retry(self):
        for kind in ('attempt', 'main', 'latest'):
            with self.subTest(kind=kind):
                api = FakeGitHub()
                payload = event(api.run)
                if kind == 'attempt':
                    payload['workflow_run']['run_attempt'] = 2
                elif kind == 'main':
                    api.main = BASE
                else:
                    api.latest = 102
                self.assertEqual(recovery.recover(api, payload, True)[0].action, 'none')
                self.assertEqual(api.writes, [])

    def test_pr_head_base_and_open_state_are_current(self):
        reference = {'path': REPOSITORY + '/' + recovery.PRODUCT_WORKFLOW + '@' + MERGE,
                     'sha': MERGE, 'ref': 'refs/pull/7/merge'}
        run = source(event='pull_request', head_branch='fix/ci', pull_requests=[{'number': 7}],
                     referenced_workflows=[reference])
        self.assertEqual(recovery.recover(FakeGitHub(run), event(run), False)[0].action, 'retry_failed')
        for kind in ('head', 'base', 'closed', 'fork', 'missing_merge', 'ambiguous_merge', 'wrong_parents'):
            with self.subTest(kind=kind):
                api = FakeGitHub(run)
                if kind == 'head':
                    api.pull['head']['sha'] = 'c' * 40
                elif kind == 'base':
                    api.pull['base']['sha'] = 'c' * 40
                elif kind == 'closed':
                    api.pull['state'] = 'closed'
                elif kind == 'fork':
                    api.pull['head']['repo']['full_name'] = 'attacker/fork'
                elif kind == 'missing_merge':
                    api.run['referenced_workflows'] = []
                elif kind == 'ambiguous_merge':
                    api.run['referenced_workflows'] *= 2
                else:
                    api.merge['parents'][1]['sha'] = BASE
                self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')
                self.assertEqual(api.writes, [])

    def test_mutable_pr_snapshot_cannot_hide_a_changed_base(self):
        current_base = 'd' * 40
        reference = {'path': REPOSITORY + '/' + recovery.PRODUCT_WORKFLOW + '@' + MERGE,
                     'sha': MERGE, 'ref': 'refs/pull/7/merge'}
        run = source(event='pull_request', head_branch='fix/ci',
                     pull_requests=[{'number': 7, 'base': {'sha': current_base}}],
                     referenced_workflows=[reference])
        api = FakeGitHub(run)
        api.pull['base']['sha'] = current_base
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')
        self.assertEqual(api.writes, [])

    def test_check_run_url_must_belong_to_the_same_repository(self):
        for url in ('', 'https://api.github.com/repos/attacker/fork/check-runs/9010',
                    'https://example.com/repos/repoprompt/repoprompt-ce/check-runs/9010',
                    'https://api.github.com/repos/repoprompt/repoprompt-ce/check-runs/9010?other=1'):
            with self.subTest(url=url):
                api = FakeGitHub()
                api.jobs[0]['check_run_url'] = url
                with self.assertRaises(recovery.EvidenceError):
                    recovery.recover(api, event(api.run), True)
                self.assertEqual(api.writes, [])

    def test_warning_annotations_do_not_authorize_a_retry(self):
        api = FakeGitHub()
        api.annotations[0]['annotation_level'] = 'warning'
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'none')

    def test_attempt_cap_precedes_expensive_evidence_reads(self):
        api = FakeGitHub(source(run_attempt=3))
        self.assertIn('exhausted', recovery.recover(api, event(api.run), True)[0].reason)
        self.assertFalse(any('/jobs' in path or '/annotations' in path for path in api.reads))
        self.assertEqual(api.writes, [])

    def test_rebuild_posts_successful_root_job_once(self):
        api = FakeGitHub(jobs=worker_failure(SELECT))
        api.log = DRIFT
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'rebuild')
        self.assertEqual(api.writes, ['actions/jobs/10/rerun'])

    def test_current_main_eviction_can_recover_cancelled_run(self):
        api = FakeGitHub(source(conclusion='cancelled'))
        api.annotations[0]['message'] = "Canceling since a higher priority waiting request for 'ci-build-main' exists"
        self.assertEqual(recovery.recover(api, event(api.run), True)[0].action, 'retry_job')
        self.assertEqual(api.writes, ['actions/jobs/10/rerun'])


class GitHubBoundaryTests(unittest.TestCase):
    def test_reads_every_job_page_including_retained_ancestors(self):
        api = recovery.GitHub(REPOSITORY)
        with mock.patch.object(api, 'request', side_effect=[{'total_count': 101, 'jobs': [{}] * 100},
                                                          {'total_count': 101, 'jobs': [{'name': recovery.ROOT}]}]) as request:
            items = api.pages('actions/runs/101/jobs?filter=all', 'jobs')
        self.assertEqual(len(items), 101)
        self.assertEqual(items[-1]['name'], recovery.ROOT)
        self.assertIn('filter=all&per_page=100&page=2', request.call_args_list[-1].args[0])

    def test_incomplete_pagination_fails_closed(self):
        api = recovery.GitHub(REPOSITORY)
        with mock.patch.object(api, 'request', return_value={'total_count': 2, 'jobs': [{}]}):
            with self.assertRaises(recovery.EvidenceError):
                api.pages('actions/runs/101/jobs?filter=latest', 'jobs')

    def test_gh_receives_arguments_without_shell_or_event_interpolation(self):
        api = recovery.GitHub(REPOSITORY)
        with mock.patch('ci_recovery.subprocess.run', return_value=subprocess.CompletedProcess([], 0, b'{}', b'')) as run:
            api.request('actions/runs/101')
        self.assertNotIn('shell', run.call_args.kwargs)
        self.assertEqual(run.call_args.args[0][-1], 'repos/repoprompt/repoprompt-ce/actions/runs/101')

    def test_failed_or_timed_out_post_has_an_unconfirmed_outcome(self):
        api = recovery.GitHub(REPOSITORY)
        with mock.patch('ci_recovery.subprocess.run', return_value=subprocess.CompletedProcess([], 1, b'', b'error')):
            with self.assertRaises(recovery.SubmissionError):
                api.request('actions/jobs/10/rerun', method='POST')
        with mock.patch('ci_recovery.subprocess.run', side_effect=subprocess.TimeoutExpired('gh', 60)):
            with self.assertRaises(recovery.SubmissionError):
                api.request('actions/jobs/10/rerun', method='POST')

    def test_cli_cannot_execute_outside_trusted_workflow_run_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary) / 'event.json'
            payload.write_text(json.dumps(event(source())))
            with mock.patch.dict('os.environ', {}, clear=True), mock.patch('ci_recovery.recover') as recover, \
                    mock.patch('builtins.print'), \
                    mock.patch('sys.argv', ['ci_recovery.py', '--event-path', str(payload),
                                            '--repository', REPOSITORY, '--execute']):
                self.assertEqual(recovery.main(), 1)
            recover.assert_not_called()

    def test_workflow_uses_only_default_branch_controller_and_minimal_permissions(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/ci-recovery.yml').read_text()
        self.assertIn('ref: ${{ github.sha }}', workflow)
        self.assertNotIn('ref: ${{ github.event.workflow_run.head_sha }}', workflow)
        self.assertNotIn('download-artifact', workflow)
        self.assertIn('actions: write', workflow)
        self.assertIn('contents: read', workflow)
        self.assertIn('checks: read', workflow)
        self.assertIn('pull-requests: read', workflow)
        self.assertIn('runs-on: ubuntu-24.04', workflow)


if __name__ == '__main__':
    unittest.main()
