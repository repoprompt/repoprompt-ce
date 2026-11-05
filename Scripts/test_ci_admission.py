#!/usr/bin/env python3
"""Reruns reuse only successful, exact producer evidence; never an unrelated build."""
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
import ci_job_diagnostics as diagnostics
import modularization_ci_build as ci_build
import modularization_ci_artifact as artifact


class WorkerSchedulingTests(unittest.TestCase):
    def test_one_worker_retains_four_fail_closed_logical_shards(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/ci.yml').read_text()
        worker = workflow.split('\n  build-and-test:\n', 1)[1].split('\n  style:\n', 1)[0]
        self.assertNotIn('matrix:', worker)
        self.assertNotIn('continue-on-error:', worker)
        self.assertEqual(worker.count('uses: actions/download-artifact@'), 1)
        self.assertIn('id: verified-build', worker)
        commands = []
        for step in worker.split('      - name: ')[1:]:
            if not step.startswith('Run root test shard '):
                continue
            self.assertIn("if: ${{ !cancelled() && steps.verified-build.outcome == 'success' }}", step)
            self.assertIn('timeout-minutes: 32', step)
            commands.append(step.split('run: ', 1)[1].strip())
        self.assertEqual(commands, [
            f'./conductor ci-shard --shard-count 4 --shard-index {i} --timeout 1800 --full-log'
            for i in range(1, 5)])
        self.assertIn('artifact=shard-execution-all-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT', worker)
        self.assertIn('name: ${{ steps.execution.outputs.artifact }}', worker)
        self.assertIn('path: .build/ci-test-results/shard-*', worker)
        self.assertIn("if: ${{ always() && steps.execution.outcome == 'success' }}", worker)
        aggregate = workflow.split('\n  style:\n', 1)[1].split('\n  secret-scan:\n', 1)[0]
        self.assertIn('toJSON(needs)', aggregate)
        self.assertIn('name: ${{ steps.selected.outputs.receipt_artifact }}', aggregate)
        self.assertIn('--shard-count 4 --admission-context', aggregate)

    def test_all_integration_producers_and_consumers_retain_native_arm_validation(self):
        root = Path(__file__).resolve().parent.parent
        for name, count in [('ci.yml', 2), ('ci-integration-products.yml', 1), ('xcode-workspace.yml', 1)]:
            text = (root / '.github/workflows' / name).read_text()
            mac_labels = [line.strip().split(': ', 1)[1] for line in text.splitlines()
                          if line.strip().startswith('runs-on: macos')]
            self.assertEqual(mac_labels, ['macos-26'] * count, name)
            self.assertEqual(text.count('DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer'), count, name)
        producer = (root / '.github/workflows/ci.yml').read_text().split('\n  build-test-bundles:\n', 1)[1].split('\n  build-and-test:\n', 1)[0]
        self.assertLess(producer.index('ci_admission.py produce'), producer.index('Run compiler-dependent repository guardrails'))
        self.assertLess(producer.index('ci_admission.py produce'), producer.index('Resolve dependency downloads'))
        # Publication retains native ARM builds and both oldest-runtime architectures.
        compatibility = (root / '.github/workflows/macos-compatibility.yml').read_text()
        self.assertIn('runner: macos-15\n', compatibility)
        self.assertIn('runner: macos-15-intel\n', compatibility)
        self.assertIn('runs-on: macos-26\n', (root / '.github/workflows/main-tip.yml').read_text())


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
                self.assertEqual(context['products'], 'sentry-privacy')

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

    def producer(self, context, attempt='1'):
        return admission.producer_context(context, attempt, {'swift': 'Swift fixture', 'xcode': 'Xcode fixture', 'architecture': 'arm64'})

    def test_root_producer_rejects_uncalibrated_architecture_before_emitting_evidence(self):
        context = self.context()
        self.assertEqual(context['root_architecture'], 'arm64')
        output = self.root / 'producer-output'
        argv = ['admission', 'produce', '--root', str(self.root), '--run-id', '42', '--attempt', '1',
                '--context', json.dumps(context), '--output', str(output)]
        for architecture in ('x86_64', 'arm64'):
            output.unlink(missing_ok=True)
            versions = {'swift': 'Swift fixture', 'xcode': 'Xcode fixture', 'architecture': architecture}
            with self.subTest(architecture=architecture), mock.patch('sys.argv', argv), \
                    mock.patch.object(admission, 'toolchain', return_value=versions), \
                    mock.patch('sys.stderr', new_callable=io.StringIO) as errors, \
                    mock.patch('sys.stdout', new_callable=io.StringIO) as logs:
                if architecture != 'arm64':
                    with self.assertRaises(SystemExit) as failed:
                        admission.main()
                    self.assertEqual(failed.exception.code, 1)
                    self.assertIn('Restore the intended runner; do not raise timing budgets', errors.getvalue())
                    self.assertNotIn('Re-run all jobs', errors.getvalue())
                    self.assertFalse(output.exists())
                    self.assertIn('root_measurement_toolchain', logs.getvalue())
                    self.assertIn('Swift fixture', logs.getvalue())
                else:
                    self.assertEqual(admission.main(), 0)
                    self.assertIn('root_measurement_toolchain', logs.getvalue())
                    self.assertIn('root-build-42-1', output.read_text())
        wrong = {**self.producer(context), 'toolchain': {**versions, 'architecture': 'x86_64'}}
        with self.assertRaises(admission.CandidateMismatch):
            admission.verify_producer(wrong, context, '2')

    def test_unavailable_pinned_toolchain_is_a_configuration_failure_not_a_rebuild_hint(self):
        context = self.context()
        output = self.root / 'producer-output'
        argv = ['admission', 'produce', '--root', str(self.root), '--run-id', '42', '--attempt', '1',
                '--context', json.dumps(context), '--output', str(output)]
        for error in (FileNotFoundError('xcodebuild'), subprocess.CalledProcessError(1, ['xcodebuild', '-version'])):
            with self.subTest(error=type(error).__name__), mock.patch('sys.argv', argv), \
                    mock.patch.dict('os.environ', {'DEVELOPER_DIR': '/Applications/MissingXcode.app/Contents/Developer'}), \
                    mock.patch('sys.stderr', new_callable=io.StringIO) as errors:
                # Isolate toolchain discovery; checkout validation has separate executable tests.
                with mock.patch.object(admission, 'verify'), \
                        mock.patch.object(admission.subprocess, 'check_output', side_effect=error), \
                        self.assertRaises(SystemExit) as failed:
                    admission.main()
                self.assertEqual(failed.exception.code, 1)
                self.assertIn('MissingXcode.app', errors.getvalue())
                self.assertIn('do not rerun unchanged configuration', errors.getvalue())
                self.assertNotIn('Re-run Build and Static Gates', errors.getvalue())
                self.assertFalse(output.exists())

    def test_native_partial_rerun_keeps_candidate_but_selects_actual_producer_attempt(self):
        first = self.context()
        self.assertNotIn('attempt', first)
        self.assertEqual(self.context('2'), first)
        self.assertEqual(self.command('verify', '2', context=json.dumps(first)).returncode, 0)
        producer = self.producer(first)
        output = self.root / 'selection'
        for attempt, receipt in [('2', 'shard-execution-all-42-2'), ('10', 'shard-execution-all-42-2')]:
            result = self.command('select', attempt, context=json.dumps(first), producer_context=json.dumps(producer),
                                  receipt_artifact=receipt, output=output)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(outputs, {'build_artifact': 'root-build-42-1', 'coverage_artifact': 'expected-coverage-42-1', 'receipt_artifact': receipt})
        # A new producer is distinct even on the same candidate. Old receipts
        # cannot be relabelled as evidence for a rebuild.
        second = self.producer(first, '2')
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            admission.verify_build_identity({'producer': 'build-test-bundles', 'context': producer}, second)
        self.assertNotEqual(self.command('bind', '2', context=json.dumps(first), producer_context=json.dumps(producer)).returncode, 0)

    def test_real_coverage_cli_accepts_retried_worker_but_rejects_receipts_after_rebuild(self):
        import ci_test_coverage as coverage
        from ci_app_test_runner import assign_suites_to_shards, parse_suite_methods
        context = self.context()
        producer = self.producer(context)
        bound = self.command('bind', context=json.dumps(context), producer_context=json.dumps(producer))
        self.assertEqual(bound.returncode, 0, bound.stderr)
        metadata = self.root / admission.METADATA.parent
        tests = [f'CoreTests.Suite{index}/testOne' for index in range(4)]
        (metadata / 'ci-test-list.txt').write_text('\n'.join(tests) + '\n')
        (metadata / 'test-targets.json').write_text(json.dumps({'targets': ['CoreTests']}))
        # Worker attempt 2 consumes the successful attempt-1 build. Style attempt
        # 3 may in turn consume these exact receipts; consumer attempt is not authority.
        receipts = self.root / 'shard-execution-all-42-2'
        receipts.mkdir()
        suites = parse_suite_methods('\n'.join(tests))
        shards, _ = assign_suites_to_shards({suite: len(methods) for suite, methods in suites.items()}, 4)
        for index, shard in enumerate(shards, 1):
            assigned = sorted(test for suite in shard for test in suites[suite])
            (receipts / f'shard-{index}.json').write_text(json.dumps({
                'schema': 1, 'shard_count': 4, 'shard_index': index,
                'listing_sha256': coverage.listing_digest(tests), 'assigned': assigned,
                'executed': assigned, 'skipped': [], 'admission': producer, 'producer': f'build-and-test-{index}'}))
        args = [sys.executable, str(Path(coverage.__file__).resolve()), '--metadata', str(metadata),
                '--receipts', str(receipts), '--shard-count', '4', '--admission-context']
        self.assertEqual(subprocess.run([*args, json.dumps(producer)], capture_output=True).returncode, 0)
        rebuilt = self.producer(context, '3')
        rebound = self.command('bind', '3', context=json.dumps(context), producer_context=json.dumps(rebuilt))
        self.assertEqual(rebound.returncode, 0, rebound.stderr)
        rejected = subprocess.run([*args, json.dumps(rebuilt)], capture_output=True, text=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('identity mismatch', rejected.stderr)
        (receipts / 'shard-4.json').unlink()
        self.assertNotEqual(subprocess.run([*args, json.dumps(rebuilt)], capture_output=True).returncode, 0)

    def test_selection_rejects_missing_wrong_run_candidate_future_or_malformed_producer(self):
        context = self.context()
        producer = self.producer(context)
        cases = [None, {}, {**producer, 'attempt': '3'}, {**producer, 'attempt': '0'},
                 {**producer, 'attempt': '١'}, {**producer, 'attempt': '1\n'}, {**producer, 'toolchain': {}},
                 {**producer, 'candidate': {**context, 'run_id': '43'}},
                 {**producer, 'candidate': {**context, 'base': 'a' * 40}}]
        for bad in cases:
            with self.subTest(producer=bad):
                output = self.root / 'selection'
                result = self.command('select', '2', context=json.dumps(context), producer_context=json.dumps(bad), output=output)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Re-run all jobs', result.stderr)
                self.assertFalse(output.exists())
        for bad in ('', 'shard-execution-all-43-1', 'shard-execution-all-42-3', 'latest', '../root-build-42-1'):
            with self.subTest(artifact=bad):
                output = self.root / 'selection'
                result = self.command('select', '2', context=json.dumps(context), producer_context=json.dumps(producer),
                                      receipt_artifact=bad, output=output)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
        with self.assertRaises(ValueError):
            admission.verify_receipt_artifact('shard-execution-all-42-1', '42', '3', build_attempt='2')

    def test_toolchain_drift_blocks_reuse_with_rebuild_instructions(self):
        context = self.context()
        producer = self.producer(context)
        argv = ['admission', 'select', '--root', str(self.root), '--run-id', '42', '--attempt', '2',
                '--context', json.dumps(context), '--producer-context', json.dumps(producer),
                '--check-toolchain', '--output', str(self.root / 'selection')]
        with mock.patch('sys.argv', argv), mock.patch.object(admission, 'toolchain', return_value={'swift': 'new', 'xcode': 'new', 'architecture': 'arm64'}), \
                mock.patch('sys.stderr', new_callable=io.StringIO) as errors, self.assertRaises(SystemExit):
            admission.main()
        self.assertIn('toolchain-drift', errors.getvalue())
        self.assertIn('Re-run Build and Static Gates', errors.getvalue())
        self.assertFalse((self.root / 'selection').exists())

    def test_worker_rejects_other_architecture_even_with_identical_swift_and_xcode(self):
        context = self.context()
        producer = self.producer(context)
        output = self.root / 'selected'
        argv = ['admission', 'select', '--root', str(self.root), '--run-id', '42', '--attempt', '2',
                '--context', json.dumps(context), '--producer-context', json.dumps(producer),
                '--check-toolchain', '--output', str(output)]
        for architecture, expected in [('arm64', 0), ('x86_64', 1)]:
            output.unlink(missing_ok=True)
            installed = {**producer['toolchain'], 'architecture': architecture}
            with self.subTest(architecture=architecture), mock.patch('sys.argv', argv), \
                    mock.patch.object(admission, 'toolchain', return_value=installed), \
                    mock.patch('sys.stderr', new_callable=io.StringIO) as errors:
                if expected:
                    with self.assertRaises(SystemExit) as failure:
                        admission.main()
                    self.assertEqual(failure.exception.code, expected)
                    self.assertIn('violates the declared arm64 platform', errors.getvalue())
                    self.assertNotIn('toolchain-drift', errors.getvalue())
                    self.assertNotIn('Re-run Build and Static Gates', errors.getvalue())
                    self.assertFalse(output.exists())
                else:
                    self.assertEqual(admission.main(), 0)
                    self.assertIn('root-build-42-1', output.read_text())

    def test_legacy_release_profile_cannot_be_relabelled_as_current_integration(self):
        context = self.context()
        # Profile and obligations must move together. Neither a legacy receipt
        # nor a hybrid may be consumed under the new integration guarantee.
        for fields in (
            {'profile': 'integration-v1', 'products': 'sentry-privacy-and-release-smoke'},
            {'profile': 'integration-v1'},
            {'profile': 'integration-v2', 'schema': 1},
            {'products': 'sentry-privacy-and-release-smoke'},
            {'products': ''},
            {'root_architecture': None},
            {'root_architecture': 'x86_64'},
        ):
            with self.subTest(fields=fields):
                result = self.command('verify', context=json.dumps({**context, **fields}))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Admission failed:', result.stderr)
        self.assertEqual(self.command('verify', context=json.dumps(context)).returncode, 0)

    def test_binding_rejects_other_tree_commit_run_profile_and_producer(self):
        context = self.context()
        producer = self.producer(context)
        bound = self.command('bind', context=json.dumps(context), producer_context=json.dumps(producer))
        self.assertEqual(bound.returncode, 0, bound.stderr)
        identity = admission.build_identity(self.root)
        admission.verify_build_identity(identity, producer)
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
            admission.verify_build_identity(None, producer)

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
            baseline.write_text(json.dumps({'typecheck': {}, 'warnings': {'first_party_unique': 0}}))
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
                    'function_bodies_1000ms': 0, 'expressions_500ms': budget},
                    'warnings': {'first_party_unique': 0}}))
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
                # Exercise the reporter against the real producer's schema, not only hand-written JSON.
                summary = diagnostics.build_report(report)
                self.assertIn(f'| Expressions >=500ms | 1 | {budget} |', summary)
                if build_status:
                    self.assertIn('Compiler/build process failed', summary)
                    self.assertNotIn('Type-check ratchet exceeded', summary)
                elif budget == 0:
                    self.assertIn('Type-check ratchet exceeded', summary)
                else:
                    self.assertIn('Recorded measurements do not explain this failure', summary)
                self.assertEqual(report['locations'], [{
                    'path': 'Sources/RepoPrompt/App/X.swift', 'line': 3, 'column': 4,
                    'kind': 'expression', 'duration_ms': 502}])


class StatusReportTests(unittest.TestCase):
    def test_queue_and_execution_require_actual_runner_assignment(self):
        from ci_status_report import job_timing
        job = {'id': 1, 'name': 'test', 'status': 'in_progress', 'runner_id': 0,
               'created_at': '2026-11-04T10:00:00Z', 'started_at': '2026-11-04T10:00:01Z'}
        now = '2026-11-04T10:10:00Z'
        pending = job_timing(job, now)
        self.assertEqual(pending['queue_seconds'], 600)
        self.assertIsNone(pending['execution_seconds'])
        running = job_timing({**job, 'runner_id': 5, 'started_at': '2026-11-04T10:04:00Z'}, now)
        self.assertEqual((running['queue_seconds'], running['execution_seconds']), (240, 360))
        done = job_timing({**job, 'runner_id': 5, 'status': 'completed',
                           'completed_at': '2026-11-04T10:06:00Z'}, now)
        self.assertEqual(done['execution_seconds'], 359)
        self.assertFalse(done['timing_censored'])
        for conclusion in ('cancelled', 'skipped', 'failure'):
            terminal = job_timing({**job, 'status': 'completed', 'conclusion': conclusion}, now)
            self.assertIsNone(terminal['queue_seconds'])
            self.assertIsNone(terminal['execution_seconds'])

    def test_report_rejects_mixed_attempts_and_duplicate_pages(self):
        from ci_status_report import report, seconds
        run = {'id': 42, 'run_attempt': 2}
        with self.assertRaisesRegex(ValueError, 'attempt'):
            report(run, [{'id': 1, 'run_id': 42, 'run_attempt': 1}], '2026-11-04T10:00:00Z')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            report(run, [{'id': 1}, {'id': 1}], '2026-11-04T10:00:00Z')
        self.assertIsNone(seconds('2026-11-04T10:01:00Z', '2026-11-04T10:00:00Z'))

    def test_collection_pins_attempt_paginates_and_detects_rerun(self):
        import ci_status_report as status
        run = {'id': 42, 'run_attempt': 2, 'html_url': 'https://example.invalid/42',
               'name': 'CI', 'head_sha': 'a' * 40, 'event': 'push', 'status': 'completed',
               'conclusion': 'success', 'created_at': '2026-11-04T10:00:00Z'}
        job = {'id': 1, 'run_id': 42, 'run_attempt': 2, 'name': 'test', 'status': 'completed',
               'runner_id': 3, 'labels': ['macos-26'], 'created_at': run['created_at'],
               'started_at': '2026-11-04T10:01:00Z', 'completed_at': '2026-11-04T10:03:00Z'}
        with mock.patch.object(status, 'api', side_effect=[run, [{'total_count': 2, 'jobs': [job]}, {'total_count': 2, 'jobs': [{**job, 'id': 2}]}], run]) as api:
            result = status.collect('owner/repo', 42)
        self.assertEqual(result['observed_macos_jobs'], 2)
        self.assertEqual(result['sum_observed_macos_execution_seconds'], 240)
        self.assertEqual(api.call_args_list[1], mock.call('repos/owner/repo/actions/runs/42/attempts/2/jobs?per_page=100', pages=True))
        with mock.patch.object(status, 'api', side_effect=[run, [{'total_count': 1, 'jobs': [job]}], {**run, 'run_attempt': 3}]):
            with self.assertRaisesRegex(ValueError, 'changed attempt'):
                status.collect('owner/repo', 42)

    def test_invalid_job_state_and_incomplete_pagination_are_not_silent(self):
        import ci_status_report as status
        job = {'id': 1, 'name': 'test', 'runner_id': 8, 'status': 'queued',
               'created_at': '2026-11-04T10:00:00Z', 'started_at': '2026-11-04T10:00:01Z'}
        self.assertIsNone(status.job_timing(job, '2026-11-04T10:05:00Z')['execution_seconds'])
        with self.assertRaises(ValueError):
            status.job_timing({**job, 'status': 'surprise'}, '2026-11-04T10:05:00Z')
        for bad in ('bad', '2026-11-04T10:00:00', '0001-01-01T00:00:00Z'):
            with self.assertRaises(ValueError):
                status.timestamp(bad)
        with mock.patch.object(status, 'api', side_effect=[{'id': 42, 'run_attempt': 1},
                                                         [{'total_count': 2, 'jobs': []}]]):
            with self.assertRaisesRegex(ValueError, 'truncated'):
                status.collect('owner/repo', 42)

    def test_api_uses_get_and_does_not_print_debug_stderr(self):
        import ci_status_report as status
        with mock.patch.object(status.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout='[]')) as run:
            self.assertEqual(status.api('repos/owner/repo/actions/runs', pages=True), [])
        self.assertEqual(run.call_args.args[0], ['gh', 'api', '--method', 'GET',
                         'repos/owner/repo/actions/runs', '--paginate', '--slurp'])
        with mock.patch.object(status.subprocess, 'run', return_value=mock.Mock(returncode=1, stderr='private-marker')):
            with self.assertRaises(ValueError) as failure:
                status.api('repos/owner/repo/actions/runs')
        self.assertNotIn('private-marker', str(failure.exception))


if __name__ == '__main__':
    unittest.main()
