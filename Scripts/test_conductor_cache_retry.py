#!/usr/bin/env python3
"""Cache recovery must distinguish compilation failures from completed test builds."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import conductor


class CacheRetryTests(unittest.TestCase):
    def run_fixture(self, root: Path, build_status: int, test_status: int) -> tuple[int, dict, int, list[str]]:
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
                'attemptTimeout': 20,
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
