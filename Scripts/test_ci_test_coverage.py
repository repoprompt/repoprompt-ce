#!/usr/bin/env python3
"""Coverage assertions must reject green zero/partial/crashed/wrong-target runs."""
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import ci_test_coverage as coverage
import ci_app_test_runner as runner

FIXTURES = Path(__file__).parent / 'Fixtures/ci-test-coverage'
TESTS = ['CoreTests.ExampleTests/testOne', 'CoreTests.ExampleTests/testTwo']


class ExecutionTests(unittest.TestCase):
    def test_pass_and_skip_are_accounted_separately(self):
        receipt = coverage.verify_execution(TESTS, (FIXTURES / 'pass.txt').read_text(), 0)
        self.assertEqual(receipt['executed'], TESTS)
        self.assertEqual(receipt['skipped'], [TESTS[1]])

    def test_zero_fewer_crash_and_missing_terminal_fail_even_with_exit_zero(self):
        for name in ['zero', 'fewer', 'crash']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                coverage.verify_execution(TESTS, (FIXTURES / f'{name}.txt').read_text(), 0)

    def test_signal_failure_is_not_ignored_even_with_complete_output(self):
        with self.assertRaisesRegex(ValueError, 'failed/crashed'):
            coverage.verify_execution(TESTS, (FIXTURES / 'pass.txt').read_text(), -6)

    def test_equal_count_wrong_method_or_duplicate_cannot_pass(self):
        text = (FIXTURES / 'pass.txt').read_text()
        for method in ['testThree', 'testOne']:
            with self.subTest(method=method), self.assertRaisesRegex(ValueError, 'identities'):
                coverage.verify_execution(TESTS, text.replace('testTwo', method), 0)

    def test_failure_with_forged_zero_exit_and_count_fails(self):
        text = (FIXTURES / 'pass.txt').read_text().replace('skipped (', 'failed (')
        with self.assertRaises(ValueError):
            coverage.verify_execution(TESTS, text, 0)

    def test_strict_listing_rejects_empty_malformed_and_duplicates(self):
        for text in ['', 'noise/a', TESTS[0] + '\n' + TESTS[0]]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                coverage.listed_tests(text)

    def test_ci_local_no_match_is_failure_not_silent_success(self):
        with mock.patch.dict('os.environ', {'CI': 'true'}), \
                mock.patch.object(runner.subprocess, 'run', return_value=mock.Mock(returncode=0)):
            self.assertNotEqual(runner.run_local_tests(swift_binary='swift', cwd=None,
                               test_filter='RenamedTests', direct_command=lambda **_: ()), 0)

    def test_missing_test_target_fails_even_with_package_bundle(self):
        with self.assertRaisesRegex(ValueError, 'target coverage'):
            coverage.validate_targets(TESTS, ['CoreTests', 'MissingTests'])

    def test_runner_failure_removes_stale_receipt_and_never_publishes_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / 'shard-1.json'
            receipt.write_text('{}')
            with mock.patch.object(runner, 'execute_logged', return_value=(0, (FIXTURES / 'zero.txt').read_text())):
                status = runner.run_selected_suites(
                    ['CoreTests.ExampleTests'], swift_binary='swift', cwd=root,
                    bundle_selection=runner.BundleSelection(root / 'PackageTests.xctest', {}, ('xctest',)),
                    sandbox_root=root / 'sandbox', suite_methods={'CoreTests.ExampleTests': TESTS},
                    receipt_path=receipt, output=io.StringIO())
            self.assertNotEqual(status, 0)
            self.assertFalse(receipt.exists())

    def test_runner_publishes_receipt_only_after_verified_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / 'shard-1.json'
            with mock.patch.object(runner, 'execute_logged', return_value=(0, (FIXTURES / 'pass.txt').read_text())):
                status = runner.run_selected_suites(
                    ['CoreTests.ExampleTests'], swift_binary='swift', cwd=root,
                    bundle_selection=runner.BundleSelection(root / 'PackageTests.xctest', {}, ('xctest',)),
                    sandbox_root=root / 'sandbox', suite_methods={'CoreTests.ExampleTests': TESTS},
                    receipt_path=receipt, output=io.StringIO())
            self.assertEqual(status, 0)
            coverage.verify_shards(TESTS, ['CoreTests'], [json.loads(receipt.read_text())], 1)


class UnionTests(unittest.TestCase):
    def setUp(self):
        self.tests = sorted(TESTS + ['OtherTests.ExampleTests/testOne'])
        self.targets = ['CoreTests', 'OtherTests']
        self.receipts = [
            {'schema': 1, 'shard_index': index, 'shard_count': 2,
             'listing_sha256': coverage.listing_digest(self.tests),
             'assigned': assigned, 'executed': assigned[:], 'skipped': []}
            for index, assigned in [(1, TESTS), (2, [self.tests[-1]])]
        ]

    def test_complete_partition_passes(self):
        coverage.verify_shards(self.tests, self.targets, self.receipts, 2)

    def test_missing_duplicate_stale_partial_overlap_and_wrong_assignment_fail(self):
        variants = [self.receipts[:1], [self.receipts[0], self.receipts[0]]]
        for key, value in [('listing_sha256', 'stale'), ('executed', []),
                           ('assigned', [TESTS[0]]), ('shard_count', 3), ('schema', 2)]:
            mutated = copy.deepcopy(self.receipts)
            mutated[0][key] = value
            variants.append(mutated)
        overlap = copy.deepcopy(self.receipts)
        overlap[1]['assigned'] = overlap[1]['executed'] = TESTS
        variants.append(overlap)
        for receipts in variants:
            with self.subTest(receipts=receipts), self.assertRaises(ValueError):
                coverage.verify_shards(self.tests, self.targets, receipts, 2)


if __name__ == '__main__':
    unittest.main()
