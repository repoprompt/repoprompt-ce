#!/usr/bin/env python3
"""Failure visibility must survive missing admission outputs and skipped dependents."""
import unittest
import re
import os
import io
import tempfile
from unittest import mock
from pathlib import Path
import ci_job_diagnostics as diagnostics


class DiagnosticsTests(unittest.TestCase):
    def needs(self):
        return {name: {'result': 'success', 'outputs': {}} for name in diagnostics.JOBS}

    def test_actual_failed_step_is_reported_without_claiming_it_is_flaky(self):
        text, output = diagnostics.job_report({'run-conductor-tests': {'outcome': 'failure'},
                                              'build-root': {'outcome': 'skipped'},
                                              'secret-scan': {'outcome': 'success'}})
        self.assertEqual(output, 'run-conductor-tests')
        self.assertIn('run-conductor-tests', text)
        self.assertNotIn('build-root', text)
        self.assertIn('rerunning the same code is not a fix', text)
        self.assertNotIn('flaky', text)

    def test_missing_candidate_output_does_not_hide_real_prerequisite_failure(self):
        needs = self.needs()
        needs['workflow-contracts'] = {'result': 'failure', 'outputs': {'failure': 'test-workflow-contracts'}}
        needs['build-test-bundles'] = {'result': 'skipped'}
        text, passed = diagnostics.prerequisite_report(needs, 'push')
        self.assertFalse(passed)
        self.assertIn('test-workflow-contracts', text)
        self.assertIn('Automatic Tip release is blocked', text)
        self.assertIn('Stable/manual releases have separate gates', text)
        self.assertIn('Skipped dependents are consequences', text)
        self.assertIn('7 days', text)

    def test_only_complete_successful_prerequisites_allow_evidence_validation(self):
        self.assertTrue(diagnostics.prerequisite_report(self.needs(), 'pull_request')[1])
        for job in diagnostics.JOBS:
            for state in ('failure', 'cancelled', 'skipped', 'unknown'):
                needs = self.needs()
                needs[job]['result'] = state
                self.assertFalse(diagnostics.prerequisite_report(needs, 'push')[1])
            needs = self.needs()
            del needs[job]
            self.assertFalse(diagnostics.prerequisite_report(needs, 'push')[1])
        text, passed = diagnostics.prerequisite_report(self.needs(), 'pull_request')
        self.assertIn('not authority to publish', text)
        self.assertIn('not the final verdict', text)

    def test_unexpected_dependency_fails_closed(self):
        needs = self.needs()
        needs['new-security-check'] = {'result': 'failure'}
        text, passed = diagnostics.prerequisite_report(needs, 'pull_request')
        self.assertFalse(passed)
        self.assertIn('missing/unexpected job', text)

    def test_report_failure_never_overrides_job_but_prerequisite_gate_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            for mode, expected in [('job', 0), ('prerequisites', 1)]:
                for bad in ('not json', 'null', '[]'):
                    with self.subTest(mode=mode, bad=bad), \
                            mock.patch.dict(os.environ, {'STEPS_CONTEXT': bad, 'NEEDS_CONTEXT': bad, 'HOME': directory}, clear=True), \
                            mock.patch('sys.argv', ['diagnostics', mode]), mock.patch('sys.stdout', new_callable=io.StringIO) as output:
                        self.assertEqual(diagnostics.main(), expected)
                        self.assertNotIn(bad, output.getvalue())
            with mock.patch.dict(os.environ, {'STEPS_CONTEXT': '{}', 'GITHUB_OUTPUT': directory}, clear=True), \
                    mock.patch('sys.argv', ['diagnostics', 'job']), mock.patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(diagnostics.main(), 0)  # Unwritable output must not create a new CI failure.

    def test_failed_outputs_are_bounded_display_not_markdown_or_commands(self):
        result = diagnostics.safe_ids('$(echo bad)\n::error:: [bad](https://bad) ' * 1000)
        self.assertNotIn('$', result)
        self.assertNotIn('\n', result)
        self.assertNotIn('(', result)
        self.assertLess(len(result), 1000)

    def test_every_workflow_step_is_identified_and_reports_always_run(self):
        root = Path(__file__).resolve().parent.parent
        for filename in ('ci.yml', 'ci-integration-products.yml'):
            text = (root / '.github/workflows' / filename).read_text()
            for step in re.split(r'      - (?=name:|uses:)', text)[1:]:
                self.assertIn('\n        id: ', step)
            self.assertIn('id: diagnostics\n        if: always()', text)
            self.assertIn('steps.diagnostics.outputs.failure', text)


if __name__ == '__main__':
    unittest.main()
