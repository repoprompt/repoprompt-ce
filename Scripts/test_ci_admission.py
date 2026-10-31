#!/usr/bin/env python3
"""Reject wrong integration trees and mixed attempts before hosted evidence is consumed."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import io
import contextlib

import ci_admission as admission
import modularization_ci_build as ci_build
import modularization_ci_artifact as artifact


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.base, self.head, self.tree = 'a' * 40, 'b' * 40, 'c' * 40

    def prepare(self, name, event, ref):
        return admission.candidate(name, event, self.head, ref, '42', '1', self.tree)

    def test_pr_group_and_push_declare_same_complete_policy_and_correct_range(self):
        cases = [
            ('pull_request', {'pull_request': {'base': {'sha': self.base, 'ref': 'main'}}}, 'refs/pull/9/merge'),
            ('merge_group', {'action': 'checks_requested', 'merge_group': {
                'base_sha': self.base, 'head_sha': self.head,
                'base_ref': 'refs/heads/main', 'head_ref': 'refs/heads/gh-readonly-queue/main/pr-9'}},
                'refs/heads/gh-readonly-queue/main/pr-9'),
            ('push', {'before': self.base, 'after': self.head, 'ref': 'refs/heads/main'}, 'refs/heads/main'),
        ]
        for name, event, ref in cases:
            with self.subTest(event=name):
                context = self.prepare(name, event, ref)
                self.assertEqual((context['head'], context['base'], context['tree']),
                                 (self.head, self.base, self.tree))
                self.assertEqual(context['profile'], admission.PROFILE)
                self.assertEqual(context['timing_policy'], 'clean-enforcing')
                self.assertEqual(context['products'], 'sentry-privacy-and-release-smoke')

    def test_reject_wrong_queue_head_ref_action_base_and_zero_base(self):
        group = {'base_sha': self.base, 'head_sha': self.head,
                 'base_ref': 'refs/heads/main', 'head_ref': 'refs/heads/queue'}
        for field, value in [('head_sha', self.base), ('head_ref', 'refs/heads/other'),
                             ('base_ref', 'refs/heads/other'), ('base_sha', '0' * 40)]:
            changed = {**group, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.prepare('merge_group', {'action': 'checks_requested', 'merge_group': changed}, 'refs/heads/queue')
        with self.assertRaises(ValueError):
            self.prepare('merge_group', {'action': 'destroyed', 'merge_group': group}, 'refs/heads/queue')
        with self.assertRaises(ValueError):
            self.prepare('pull_request', {'pull_request': {'base': {'sha': self.base, 'ref': 'main'}}}, 'refs/heads/topic')
        with self.assertRaises(ValueError):
            self.prepare('push', {'before': self.base, 'after': self.base, 'ref': 'refs/heads/main'}, 'refs/heads/main')


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        admission.git(self.root, 'init', '-q')
        admission.git(self.root, 'config', 'user.email', 'test@example.invalid')
        admission.git(self.root, 'config', 'user.name', 'Admission Test')
        (self.root / 'file').write_text('base')
        admission.git(self.root, 'add', '.')
        admission.git(self.root, 'commit', '-qm', 'base')
        self.base = admission.git(self.root, 'rev-parse', 'HEAD')
        (self.root / 'file').write_text('candidate')
        admission.git(self.root, 'commit', '-qam', 'candidate')
        self.head = admission.git(self.root, 'rev-parse', 'HEAD')
        self.event = {'before': self.base, 'after': self.head, 'ref': 'refs/heads/main'}
        self.event_path = self.root / 'event.json'
        self.event_path.write_text(json.dumps(self.event))

    def command(self, command, attempt='1', **kwargs):
        args = [sys.executable, str(Path(admission.__file__).resolve()), command, '--root', str(self.root),
                '--run-id', '42', '--attempt', attempt]
        for key, value in kwargs.items():
            args.extend(['--' + key.replace('_', '-'), str(value)])
        return subprocess.run(args, capture_output=True, text=True)

    def context(self, attempt='1'):
        output = self.root / 'outputs'
        result = self.command('prepare', attempt, event_path=self.event_path, event_name='push',
                              sha=self.head, ref='refs/heads/main', output=output)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = dict(line.split('=', 1) for line in output.read_text().splitlines())
        self.assertEqual(lines['range'], f'{self.base}..{self.head}')
        return json.loads(lines['context'])

    def test_full_profile_rerun_passes_but_failed_jobs_only_cannot_reuse_context(self):
        first = self.context()
        self.assertEqual(self.command('verify', context=json.dumps(first)).returncode, 0)
        partial = self.command('verify', '2', context=json.dumps(first))
        self.assertNotEqual(partial.returncode, 0)
        self.assertIn('Re-run all jobs', partial.stderr)
        second = self.context('2')
        self.assertEqual(self.command('verify', '2', context=json.dumps(second)).returncode, 0)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            admission.verify_build_identity({'producer': 'build-test-bundles', 'context': first}, second)

    def test_binding_rejects_other_tree_commit_run_profile_and_producer(self):
        context = self.context()
        bound = self.command('bind', context=json.dumps(context))
        self.assertEqual(bound.returncode, 0, bound.stderr)
        identity = admission.build_identity(self.root)
        admission.verify_build_identity(identity, context)
        for field, value in [('tree', self.base), ('head', self.base), ('run_id', '41'),
                             ('profile', 'unknown'), ('timing_policy', 'report-only')]:
            changed = {**context, field: value}
            with self.subTest(field=field):
                self.assertNotEqual(self.command('verify', context=json.dumps(changed)).returncode, 0)
        wrong = copy.deepcopy(identity)
        wrong['producer'] = 'other-job'
        (self.root / admission.METADATA).write_text(json.dumps(wrong))
        with self.assertRaisesRegex(ValueError, 'producer'):
            admission.build_identity(self.root)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            admission.verify_build_identity(None, context)

    def test_stale_cache_is_invalidated_but_hosted_boundary_requires_fresh_binding(self):
        context = self.context()
        path = self.root / admission.METADATA
        path.parent.mkdir(parents=True)
        path.write_text('{malformed old cache')
        timing = path.with_name('typecheck-timing.json')
        timing.write_text('{stale measurement')
        with self.assertRaises(ValueError):
            admission.build_identity(self.root)  # Malformed is not the optional-local fallback.
        result = self.command('invalidate', context=json.dumps(context))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(timing.exists())
        self.assertIsNone(admission.build_identity(self.root))
        for mode in ('pack', 'verify'):
            result = subprocess.run([
                sys.executable, str(Path(artifact.__file__).resolve()), mode, '--root', str(self.root),
                '--admission-context', json.dumps(context), '--output', str(self.root / 'build.tar.gz')],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('identity mismatch', result.stderr)

    def test_unrelated_base_fails_instead_of_scanning_another_range(self):
        # A real object is insufficient: it must be an ancestor of the candidate.
        admission.git(self.root, 'checkout', '--orphan', 'unrelated')
        admission.git(self.root, 'commit', '-qam', 'unrelated')
        self.event['before'] = admission.git(self.root, 'rev-parse', 'HEAD')
        self.event_path.write_text(json.dumps(self.event))
        admission.git(self.root, 'checkout', '--detach', self.head)
        result = self.command('prepare', event_path=self.event_path, event_name='push', sha=self.head,
                              ref='refs/heads/main', output=self.root / 'outputs')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'outputs').exists())


class TimingProtocolTests(unittest.TestCase):
    def test_failed_clean_cannot_leave_cached_identity_or_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / admission.METADATA
            metadata.parent.mkdir(parents=True)
            metadata.write_text('{stale cache')
            timing = metadata.with_name('typecheck-timing.json')
            timing.write_text('{stale measurement')
            baseline = root / 'baseline.json'
            baseline.write_text(json.dumps({'typecheck': {}}))
            with mock.patch.object(ci_build, 'ROOT', root), mock.patch.object(ci_build, 'BASELINE', baseline), \
                    mock.patch.dict('os.environ', {'TYPECHECK_RATCHET_ENFORCE': '1'}), \
                    mock.patch.object(ci_build.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2)):
                self.assertEqual(ci_build.main(), 2)
            self.assertFalse(metadata.exists())
            self.assertFalse(timing.exists())
            self.assertIsNone(admission.build_identity(root))

    def test_clean_enforcing_build_retains_success_failure_and_ratchet_failure(self):
        warning = 'Sources/RepoPrompt/App/X.swift:3:4: warning: expression took 502ms to type-check\n'
        for build_status, budget, expected in [(0, 1, 0), (2, 1, 2), (0, 0, 1)]:
            with self.subTest(build=build_status, budget=budget), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                baseline = root / 'baseline.json'
                baseline.write_text(json.dumps({'typecheck': {
                    'function_bodies_1000ms': 0, 'expressions_500ms': budget}}))
                process = mock.Mock(stdout=io.StringIO(warning + warning))
                process.wait.return_value = build_status
                listing = subprocess.CompletedProcess([], 0, stdout='CoreTests.Example/testOne\n')
                manifest = subprocess.CompletedProcess([], 0, stdout=json.dumps({
                    'targets': [{'name': 'CoreTests', 'type': 'test'}]}))
                (root / 'Package.swift').write_text('// fixture')
                with mock.patch.object(ci_build, 'ROOT', root), \
                        mock.patch.object(ci_build, 'BASELINE', baseline), \
                        mock.patch.dict('os.environ', {'TYPECHECK_RATCHET_ENFORCE': '1'}), \
                        mock.patch.object(ci_build.subprocess, 'Popen', return_value=process), \
                        mock.patch.object(ci_build.subprocess, 'run', side_effect=[
                            subprocess.CompletedProcess([], 0), listing, manifest]) as run, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(ci_build.main(), expected)
                self.assertEqual(run.call_args_list[0].args[0], ['swift', 'package', 'clean'])
                report = json.loads((root / '.build/modularization/typecheck-timing.json').read_text())
                self.assertEqual(report['policy'], 'clean-enforcing')
                self.assertEqual(report['build_exit_code'], build_status)
                self.assertEqual(report['budget']['expressions_500ms'], budget)
                self.assertEqual(report['counts'], {'expression': 1, 'function_body': 0})
                self.assertEqual(report['locations'], [{
                    'path': 'Sources/RepoPrompt/App/X.swift', 'line': 3, 'column': 4,
                    'kind': 'expression', 'duration_ms': 502}])


if __name__ == '__main__':
    unittest.main()
