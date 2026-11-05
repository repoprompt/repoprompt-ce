#!/usr/bin/env python3
"""Failure visibility must survive missing admission outputs and skipped dependents."""
import unittest
import re
import os
import io
import tempfile
import json
import subprocess
import textwrap
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

    def test_matrix_diagnostics_keep_each_shards_failure_output(self):
        needs = self.needs()
        with tempfile.TemporaryDirectory() as directory:
            for shard in range(1, 5):
                output = Path(directory) / f'output-{shard}'
                env = {'SHARD_INDEX': str(shard), 'GITHUB_OUTPUT': str(output),
                       'GITHUB_STEP_SUMMARY': str(Path(directory) / 'summary'),
                       'STEPS_CONTEXT': json.dumps({'run-root-test-shard-without-compiling': {'outcome': 'failure'}}),
                       'GITHUB_SERVER_URL': 'https://github.com', 'GITHUB_REPOSITORY': 'owner/repo',
                       'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '2'}
                with mock.patch.dict(os.environ, env), mock.patch('sys.stdout', new_callable=io.StringIO):
                    self.assertEqual(diagnostics.run('job'), 0)
                key, value = output.read_text().strip().split('=', 1)
                self.assertEqual(key, f'failure_{shard}')
                needs['build-and-test']['outputs'][key] = value
        needs['build-and-test']['result'] = 'failure'
        text, passed = diagnostics.prerequisite_report(needs, 'pull_request')
        self.assertFalse(passed)
        for shard in range(1, 5):
            self.assertIn(f'shard {shard}: run-root-test-shard-without-compiling', text)

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

    def test_failed_build_step_preserves_exit_and_reports_noncompiler_gate(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/ci.yml').read_text()
        step = workflow.split('      - name: Build root test bundles with import and type-check gates\n', 1)[1].split('      - name:', 1)[0]
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        report = {'schema': 1, 'policy': 'clean-enforcing', 'build_exit_code': 0,
                  'budget': {'function_bodies_1000ms': 10, 'expressions_500ms': 6},
                  'counts': {'function_body': 20, 'expression': 7},
                  'first_party_warnings': {'budget': {'first_party_unique': 430}, 'unique': 417}}
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            (checkout / 'Scripts').symlink_to(root / 'Scripts', target_is_directory=True)
            timing = checkout / '.build/modularization/typecheck-timing.json'
            timing.parent.mkdir(parents=True)
            log = checkout / 'conductor.log'
            log.write_text('early.swift:1: error: fixture compiler failure\n' + 'later warning\n' * 100
                           + 'type-check ratchet: app bodies >=1000ms 20/10; expressions >=500ms 7/6\ntype-check ratchet regressed\n')
            conductor = checkout / 'conductor'
            conductor.write_text('#!/bin/sh\nprintf "Log: %s/conductor.log\\n" "$PWD"\nexit 17\n')
            conductor.chmod(0o755)
            summary = checkout / 'summary.md'
            failed_copy_bin = checkout / 'failed-copy-bin'
            failed_copy_bin.mkdir()
            failed_copy = failed_copy_bin / 'cp'
            failed_copy.write_text('#!/bin/sh\nexit 9\n')
            failed_copy.chmod(0o755)
            cases = ((json.dumps(report), '20 | 10', False),
                     ('not json', 'diagnostics unavailable', False),
                     (None, 'diagnostics unavailable', False),
                     (json.dumps(report), '20 | 10', True))
            for payload, expected, copy_fails in cases:
                with self.subTest(payload=payload, copy_fails=copy_fails):
                    timing.unlink(missing_ok=True)
                    if payload is not None:
                        timing.write_text(payload)
                    summary.unlink(missing_ok=True)
                    env = {**os.environ, 'RUNNER_TEMP': directory, 'GITHUB_STEP_SUMMARY': str(summary)}
                    if copy_fails:
                        env['PATH'] = str(failed_copy_bin) + os.pathsep + env['PATH']
                    result = subprocess.run(['bash', '-c', command], cwd=checkout, capture_output=True, text=True,
                                            env=env)
                    self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                    self.assertIn('early.swift:1: error: fixture compiler failure', result.stdout)
                    self.assertIn('type-check ratchet regressed', result.stdout)
                    self.assertIn(expected, result.stdout)
                    if payload == json.dumps(report):
                        self.assertIn('Type-check ratchet exceeded', summary.read_text())
                        self.assertIn('7 | 6', summary.read_text())
                        self.assertIn('417 | 430', summary.read_text())

    def test_build_report_distinguishes_compile_timing_and_warning_failures(self):
        data = {'schema': 1, 'policy': 'clean-enforcing', 'build_exit_code': 0,
                'budget': {'function_bodies_1000ms': 10, 'expressions_500ms': 6},
                'counts': {'function_body': 20, 'expression': 7},
                'first_party_warnings': {'budget': {'first_party_unique': 430}, 'unique': 431}}
        text = diagnostics.build_report(data)
        self.assertIn('Type-check ratchet exceeded', text)
        self.assertIn('Warning ratchet exceeded', text)
        data['build_exit_code'] = 1
        text = diagnostics.build_report(data)
        self.assertIn('Compiler/build process failed', text)
        self.assertNotIn('Type-check ratchet exceeded', text)
        data['build_exit_code'] = 0
        data['policy'] = 'incremental-report-only'
        self.assertIn('report-only', diagnostics.build_report(data))
        self.assertNotIn('Type-check ratchet exceeded', diagnostics.build_report(data))
        data['counts']['function_body'] = '::error:: untrusted'
        with self.assertRaises(ValueError):
            diagnostics.build_report(data)

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
