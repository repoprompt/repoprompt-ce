#!/usr/bin/env python3
"""Cache recovery must distinguish compilation failures from completed test builds."""

import json
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

import conductor
import ci_app_test_runner


class CacheRetryTests(unittest.TestCase):
    def run_fixture(self, root: Path, build_status: int, test_status: int,
                    *, hang_tests: bool = False) -> tuple[int, dict, int, list[str]]:
        build = root / '.build'
        build.mkdir()
        key = 'a' * 64
        (build / '.conductor-cache-provenance.json').write_text(json.dumps({'key': key}))
        sentinel = build / 'keep-cache'
        sentinel.touch()
        calls = root / 'calls'
        script = f'''
import os
import sys
from pathlib import Path
sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})
from ci_app_test_runner import run_local_tests

def execute(command, cwd, environment):
    assert 'REPOPROMPT_CONDUCTOR_TEST_BUILD_RECEIPT' not in environment
    assert 'REPOPROMPT_CONDUCTOR_TEST_BUILD_RECEIPT' not in os.environ
    with Path({str(calls)!r}).open('a') as output:
        output.write(command[1] + '\\n')
    if command[1] != 'build' and {hang_tests!r}:
        import time
        time.sleep(60)
    return {build_status} if command[1] == 'build' else {test_status}

sys.exit(run_local_tests(swift_binary='fixture-swift', cwd=Path.cwd(),
                        test_product='FixtureTests', executor=execute))
'''
        outcome_path = root / 'result.json'
        with mock.patch.dict(os.environ, {}, clear=False), \
                mock.patch.object(conductor, '_remove_cache_build_for_retry', return_value=True) as remove:
            # Never inherit a gate belonging to an enclosing conductor invocation.
            os.environ.pop('REPOPROMPT_CONDUCTOR_CACHE_WRAPPER_GATE_FD', None)
            status = conductor.operation_cache_retry(root, {
                'argv': [sys.executable, '-c', script], 'key': key, 'testBuildReceipt': True,
                'outcomePath': str(outcome_path), 'ticket': 'fixture',
                'attemptRecordPath': str(root / 'fixture.cache-attempt.json'),
                'attemptTimeout': 15 if hang_tests else 20,
            })
        self.assertTrue(sentinel.exists())
        self.assertFalse((root / 'fixture.cache-attempt.json').exists())
        outcome = json.loads(outcome_path.read_text()) if outcome_path.exists() else {}
        return status, outcome, remove.call_count, calls.read_text().splitlines()

    def test_assertion_failure_after_build_preserves_cache_and_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            status, outcome, removals, calls = self.run_fixture(Path(directory), 0, 1)
        self.assertEqual(status, 1)
        self.assertFalse(outcome['coldRetryAttempted'])
        self.assertEqual(removals, 0)
        self.assertEqual(calls, ['build', 'test'])

    def test_post_build_timeout_preserves_cache_and_reports_execution_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            status, outcome, removals, calls = self.run_fixture(Path(directory), 0, 0, hang_tests=True)
        self.assertEqual(status, 124)
        self.assertTrue(outcome['seededTimedOut'])
        self.assertTrue(outcome['testBuildSucceeded'])
        self.assertFalse(outcome['coldRetryAttempted'])
        self.assertEqual(removals, 0)
        self.assertEqual(calls, ['build', 'test'])
        job = mock.Mock()
        conductor.DaemonState._apply_cache_retry_outcome_locked(job, outcome)
        self.assertEqual(job.exit_code, 124)
        self.assertTrue(job.timed_out)
        self.assertEqual(job.error, 'post-build test execution timed out after 15.0s')

    def test_receipt_write_failure_does_not_replace_test_result(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.dict(os.environ, {
                    'REPOPROMPT_CONDUCTOR_TEST_BUILD_RECEIPT': str(Path(directory) / 'missing-parent' / 'receipt')}):
            execute = mock.Mock(side_effect=[0, 7])
            status = ci_app_test_runner.run_local_tests(
                swift_binary='fixture', cwd=Path(directory), test_product='FixtureTests', executor=execute)
        self.assertEqual(status, 7)
        self.assertEqual(execute.call_count, 2)

    def test_non_test_attempt_does_not_allocate_receipt_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(conductor.tempfile, 'TemporaryDirectory') as temporary, \
                    mock.patch.object(conductor, '_run_cache_attempt', return_value=(0, False)):
                self.assertEqual(conductor.operation_cache_retry(root, {
                    'argv': ['fixture'], 'key': 'a' * 64,
                    'outcomePath': str(root / 'result.json'), 'ticket': 'fixture',
                    'attemptRecordPath': str(root / 'fixture.cache-attempt.json'),
                }), 0)
            temporary.assert_not_called()

    def test_daemon_enables_receipt_only_for_seeded_test_jobs(self):
        # Drive the real daemon wiring up to wrapper construction; stop before
        # heavy-slot admission or launching any command/cache mutation.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Package.swift').touch()
            for operation in ('test', 'swift-build', 'build', 'package', 'install-debug-cli'):
                with self.subTest(operation=operation):
                    state = mock.MagicMock()
                    state.lock = threading.RLock()
                    state.condition = threading.Condition(state.lock)
                    state.paths.repo_root = root
                    job = conductor.Job(
                        ticket='fixture', request_key=None, fingerprint='fixture', operation=operation,
                        args={}, lanes=[], timeout=None, verbose=False, env={}, created_at=0,
                        log_path=root / 'fixture.log')
                    state.jobs = {'fixture': job}
                    state.registry.prepare.return_value = (['fixture'], [], root, {}, None)
                    context = SimpleNamespace(
                        seeded=True, status={}, snapshot=SimpleNamespace(key='a' * 64))
                    state._build_cache_manager.return_value.prepare.return_value = context
                    state.registry._internal_argv.side_effect = RuntimeError('stop before launch')
                    conductor.DaemonState._run_job(state, 'fixture')
                    state.registry._internal_argv.assert_called_once()
                    kind, args = state.registry._internal_argv.call_args.args
                    self.assertEqual(kind, 'cache_retry')
                    self.assertIs(args['testBuildReceipt'], operation == 'test')

    def test_compile_failure_retains_one_cold_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            status, outcome, removals, calls = self.run_fixture(Path(directory), 2, 0)
        self.assertEqual(status, 2)
        self.assertTrue(outcome['coldRetryAttempted'])
        self.assertEqual(removals, 1)
        self.assertEqual(calls, ['build', 'build'])

    def test_success_needs_no_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            status, outcome, removals, calls = self.run_fixture(Path(directory), 0, 0)
        self.assertEqual((status, outcome, removals), (0, {}, 0))
        self.assertEqual(calls, ['build', 'test'])


if __name__ == '__main__':
    unittest.main()
