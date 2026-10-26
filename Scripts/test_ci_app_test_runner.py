#!/usr/bin/env python3
"""Pure self-tests for the CI app-test runner."""

from __future__ import annotations

import io
import contextlib
import hashlib
import json
import os
import signal
import socket
import time
import tarfile
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import ci_app_test_runner as runner  # noqa: E402
import modularization_ci_artifact as artifact  # noqa: E402
import swift_imports  # noqa: E402

_REAL_INHERITED_STORAGE_READER = runner.read_inherited_storage_preference


def setUpModule() -> None:
    # Pure self-tests never read the machine's real defaults; the reader has dedicated fakes below.
    runner.read_inherited_storage_preference = lambda *args, **kwargs: None


def tearDownModule() -> None:
    runner.read_inherited_storage_preference = _REAL_INHERITED_STORAGE_READER


class LoggedSuiteDeadlineTests(unittest.TestCase):
    def assert_process_stopped(self, pid):
        result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
        self.assertFalse(result.stderr, 'process inspection must succeed: ' + result.stderr)
        self.assertTrue(result.returncode != 0 or result.stdout.strip().startswith('Z'), result.stdout)

    def run_logged(self, source, *, seconds='1'):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'suite.log'
            started = time.monotonic()
            command = [sys.executable, '-u', '-c', source]
            with contextlib.redirect_stdout(io.StringIO()):
                status, transcript = runner.execute_logged(
                    command, None, {**os.environ, 'CI_SUITE_TIMEOUT_SECONDS': seconds}, log,
                )
            self.assertEqual(log.read_text(), '$ ' + ' '.join(command) + '\n' + transcript)
            self.assertLess(time.monotonic() - started, 10)
            return status, transcript

    def test_silent_suite_has_a_wall_deadline(self):
        status, transcript = self.run_logged('import time; time.sleep(60)')
        self.assertEqual(status, 124)
        self.assertIn('exceeded 1s', transcript)
        self.assertIn('no test case start observed', transcript)

    def test_timeout_reports_last_start_and_kills_pipe_holding_descendant(self):
        # Foundation Process children own a process group but share their parent's session.
        source = '''
import os, signal, sys, time
pid = os.fork()
if pid == 0:
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('grandchild=' + str(os.getpid()), flush=True)
    while True: signal.pause()
print('leader=' + str(os.getpid()), flush=True)
print("Test Case '-[Fixture testHung]' started.", flush=True)
print('partial output', end='', flush=True)
while True: signal.pause()
'''
        status, transcript = self.run_logged(source)
        self.assertEqual(status, 124)
        self.assertIn("last started: Test Case '-[Fixture testHung]' started.", transcript)
        self.assertIn('partial output', transcript)
        for line in transcript.splitlines():
            if line.startswith(('leader=', 'grandchild=')):
                pid = int(line.split('=')[1])
                # A killed orphan can briefly remain a zombie pending init's reap;
                # it must never be executing or retain the group's output pipe.
                self.assert_process_stopped(pid)

    def test_ordinary_exit_stops_own_group_descendant_without_signaling_another_session(self):
        source = '''
import os, signal
reader, writer = os.pipe()
if os.fork() == 0:
    os.close(reader)
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('grandchild=' + str(os.getpid()), flush=True)
    os.close(1)
    os.close(2)
    os.write(writer, b'ready')
    os.close(writer)
    while True: signal.pause()
os.close(writer)
os.read(reader, 5)
os.close(reader)
os._exit(7)
'''
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                                     start_new_session=True)
        child_pid = None
        try:
            status, transcript = self.run_logged(source)
            child_pid = int(next(line.split('=')[1] for line in transcript.splitlines()
                                 if line.startswith('grandchild=')))
            self.assertEqual(status, 7)
            self.assertIsNone(unrelated.poll(), 'a suite must not signal another session')
            self.assert_process_stopped(child_pid)
        finally:
            unrelated.kill()
            unrelated.wait(timeout=5)
            if child_pid is not None:
                try:
                    os.kill(child_pid, 9)
                except ProcessLookupError:
                    pass

    def test_leader_exit_does_not_disable_deadline_for_inherited_pipe(self):
        status, transcript = self.run_logged('''
import os, signal
if os.fork() == 0:
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: signal.pause()
os._exit(0)
''')
        self.assertEqual(status, 124)
        self.assertIn('exceeded 1s', transcript)

    def test_ordinary_exit_preserves_status_stdout_stderr_and_partial_line(self):
        status, transcript = self.run_logged(
            "import sys; print('stdout', flush=True); print('stderr', file=sys.stderr, flush=True); "
            "sys.stdout.write('tail'); sys.exit(7)", seconds='5')
        self.assertEqual(status, 7)
        self.assertEqual(transcript, 'stdout\nstderr\ntail')

    def test_runner_sigterm_cleans_up_detached_suite_and_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'suite.log'
            source = '''
import os, signal
pid = os.fork()
if pid == 0:
    os.setpgrp()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('grandchild=' + str(os.getpid()), flush=True)
    while True: signal.pause()
print('leader=' + str(os.getpid()), flush=True)
while True: signal.pause()
'''
            wrapper = (
                'import ci_app_test_runner as r, os; from pathlib import Path; '
                f'r.execute_logged({[sys.executable, "-u", "-c", source]!r}, None, '
                f'dict(os.environ), Path({str(log)!r}))'
            )
            process = subprocess.Popen(
                [sys.executable, '-c', wrapper], cwd=SCRIPT_DIR,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            try:
                # Every child prints before parking. A bounded pipe wait, not a timing sleep.
                import selectors
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    observed = ''
                    deadline = time.monotonic() + 5
                    while 'grandchild=' not in observed or 'leader=' not in observed:
                        self.assertGreater(deadline, time.monotonic(), observed)
                        for key, _ in selector.select(max(0, deadline - time.monotonic())):
                            observed += os.read(key.fd, 65536).decode()
                process.terminate()
                output, _ = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 143, observed + output)
                for line in observed.splitlines():
                    if line.startswith(('leader=', 'grandchild=')):
                        self.assert_process_stopped(line.split('=')[1])
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)

    def test_repeated_cancellation_cannot_interrupt_owned_session_cleanup(self):
        cases = ((True, signal.SIGTERM, 143), (True, signal.SIGINT, 143),
                 (False, signal.SIGTERM, 143), (False, signal.SIGINT, 130))
        for already_cancelling, repeated_signal, expected_status in cases:
            with self.subTest(already_cancelling=already_cancelling, repeated_signal=repeated_signal), \
                    tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / 'suite.log'
                control, barrier = socket.socketpair()
                control.settimeout(5)
                source = (
                    "import os, signal; print('leader=' + str(os.getpid()), flush=True); "
                    "os.close(1); os.close(2); " + ("signal.pause()" if already_cancelling else "os._exit(7)")
                )
                wrapper = f'''
import ci_app_test_runner as runner, os, socket
from pathlib import Path
barrier = socket.socket(fileno={barrier.fileno()})
inventory = runner.process_session.session_process_groups
def gated_inventory(session_id):
    runner.process_session.session_process_groups = inventory
    barrier.sendall(b'R')
    barrier.recv(1)
    return inventory(session_id)
runner.process_session.session_process_groups = gated_inventory
runner.execute_logged({[sys.executable, '-u', '-c', source]!r}, None,
                      dict(os.environ), Path({str(log)!r}))
'''
                process = subprocess.Popen([sys.executable, '-c', wrapper], cwd=SCRIPT_DIR,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           pass_fds=(barrier.fileno(),))
                barrier.close()
                child_pid = None
                try:
                    import selectors
                    with selectors.DefaultSelector() as selector:
                        selector.register(process.stdout, selectors.EVENT_READ)
                        observed = b''
                        deadline = time.monotonic() + 5
                        while b'\n' not in observed:
                            self.assertGreater(deadline, time.monotonic(), observed)
                            for key, _ in selector.select(max(0, deadline - time.monotonic())):
                                observed += os.read(key.fd, 65536)
                    child_pid = int(observed.split(b'leader=')[1].splitlines()[0])
                    if already_cancelling:
                        process.terminate()
                    self.assertEqual(control.recv(1), b'R')
                    os.kill(process.pid, repeated_signal)
                    control.sendall(b'G')
                    output, _ = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, expected_status, observed + output)
                    self.assert_process_stopped(child_pid)
                finally:
                    control.close()
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)
                    if child_pid is not None:
                        try:
                            os.kill(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_timed_out_suite_removes_stale_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / 'shard-1.json'
            receipt.write_text('stale success')
            command = (sys.executable, '-c', 'import time; time.sleep(60)')
            with mock.patch.object(runner, 'command_for_suite', return_value=command), \
                    mock.patch.dict(os.environ, {'CI_SUITE_TIMEOUT_SECONDS': '0.1'}), \
                    contextlib.redirect_stdout(io.StringIO()):
                status = runner.run_selected_suites(
                    ['Fixture.Suite'], swift_binary='unused', cwd=None,
                    bundle_selection=runner.BundleSelection(None, {}, None),
                    sandbox_root=root / 'sandbox', suite_methods={'Fixture.Suite': ['Fixture.Suite/testHung']},
                    receipt_path=receipt, output=io.StringIO(),
                )
            self.assertEqual(status, 124)
            self.assertFalse(receipt.exists(), 'a timeout must never attest successful execution')
            self.assertIn('exceeded 0.1s', receipt.with_suffix('.log').read_text())

    def test_invalid_deadline_is_rejected_before_spawn(self):
        for value in ('0', '-1', 'nan', 'inf', '1201', 'not-a-number'):
            with self.subTest(value=value), mock.patch.object(runner.subprocess, 'Popen') as spawn:
                with self.assertRaisesRegex(ValueError, 'CI_SUITE_TIMEOUT_SECONDS'):
                    runner.execute_logged(['unused'], None, {'CI_SUITE_TIMEOUT_SECONDS': value}, Path('unused'))
                spawn.assert_not_called()

    def test_unverified_cleanup_stops_the_shard_without_a_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = root / 'shard-1.json'
            receipt.write_text('stale success')
            with mock.patch.object(runner, 'command_for_suite',
                                   return_value=(sys.executable, '-c', 'pass')) as commands, \
                    mock.patch.object(runner.process_session, 'session_process_groups',
                                      side_effect=RuntimeError('inventory failed')), \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, 'inventory failed'):
                    runner.run_selected_suites(
                        ['Fixture.First', 'Fixture.Second'], swift_binary='unused', cwd=None,
                        bundle_selection=runner.BundleSelection(None, {}, None),
                        sandbox_root=root / 'sandbox',
                        suite_methods={'Fixture.First': ['Fixture.First/testClean'],
                                       'Fixture.Second': ['Fixture.Second/testClean']},
                        receipt_path=receipt, output=io.StringIO(),
                    )
            commands.assert_called_once()
            self.assertFalse(receipt.exists())


class InheritedStoragePreferenceTests(unittest.TestCase):
    """The pre-run storage preference is read, never written, and handed to the test process."""

    @staticmethod
    def fake_defaults(returncode: int, stdout: str):
        calls: list[list[str]] = []

        def run(command, **_kwargs):
            calls.append(list(command))
            return subprocess.CompletedProcess(command, returncode, stdout=stdout, stderr="")

        return run, calls

    @unittest.skipUnless(sys.platform == "darwin", "macOS defaults only")
    def test_reader_only_reads_the_preference(self) -> None:
        run, calls = self.fake_defaults(0, "/var/folders/x/T/old-run/Workspaces\n")
        self.assertEqual(_REAL_INHERITED_STORAGE_READER(run=run), "/var/folders/x/T/old-run/Workspaces")
        self.assertEqual([call[1] for call in calls], ["read"], "never writes or deletes defaults")
        run, _ = self.fake_defaults(1, "")
        self.assertIsNone(_REAL_INHERITED_STORAGE_READER(run=run))

    def test_suite_environment_hands_the_inherited_value_to_the_test_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            environment = runner.isolated_suite_environment(
                Path(directory), "local", {runner.INHERITED_STORAGE_PREFERENCE_ENV: "stale-parent-value"},
                inherited_storage_preference=lambda: "/var/folders/x/T/old-run/Workspaces",
            )
            self.assertEqual(environment[runner.INHERITED_STORAGE_PREFERENCE_ENV], "/var/folders/x/T/old-run/Workspaces")
            cleared = runner.isolated_suite_environment(
                Path(directory), "local", {runner.INHERITED_STORAGE_PREFERENCE_ENV: "stale-parent-value"},
                inherited_storage_preference=lambda: None,
            )
            self.assertNotIn(runner.INHERITED_STORAGE_PREFERENCE_ENV, cleared)


class InterpreterCompatibilityTests(unittest.TestCase):
    def test_script_help_runs_with_current_interpreter(self) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT_DIR / "ci_app_test_runner.py"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Run deterministic RepoPrompt CE XCTest suites.", result.stdout)


class HostedShardTests(unittest.TestCase):
    def test_list_uses_skip_build_for_transferred_artifact(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout='RepoPromptTests.ExampleTests/testOne\n')
        with mock.patch.object(runner.subprocess, 'run', return_value=completed) as run:
            found = runner.list_suite_methods('swift', Path('/checkout'), skip_build=True)
        self.assertEqual(found, {'RepoPromptTests.ExampleTests': ('RepoPromptTests.ExampleTests/testOne',)})
        self.assertEqual(run.call_args.args[0], ['swift', 'test', 'list', '--skip-build'])


class TransferredBuildTests(unittest.TestCase):
    def test_archive_contains_only_runnable_products_and_gate_attestations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'source'
            copy = Path(temporary) / 'copy'
            app = source / 'Sources/RepoPrompt/App'
            app.mkdir(parents=True)
            (app / 'Main.swift').write_text('struct Main {}\n')
            test_source = source / 'Tests/RepoPromptTests/ExampleTests.swift'
            test_source.parent.mkdir(parents=True)
            test_source.write_text('import XCTest\n')
            metadata = source / '.build/modularization'
            metadata.mkdir(parents=True)
            digest = hashlib.sha256((app / 'Main.swift').read_bytes()).hexdigest()
            for name in ('app-source-sha256.json', 'index-check.json'):
                (metadata / name).write_text(json.dumps({'source_sha256': {'App/Main.swift': digest}}))
            (metadata / 'ci-test-list.txt').write_text('RepoPromptTests.ExampleTests/testOne\n')
            (source / 'Package.swift').write_text('// fixture manifest')
            (metadata / 'test-targets.json').write_text(json.dumps({
                'targets': ['RepoPromptTests'],
                'package_sha256': hashlib.sha256((source / 'Package.swift').read_bytes()).hexdigest(),
            }))
            (metadata / 'test-source-sha256.json').write_text(
                json.dumps({'source_sha256': {'RepoPromptTests/ExampleTests.swift':
                                             hashlib.sha256(test_source.read_bytes()).hexdigest()}}))
            products = source / '.build/out/Products/Debug'
            bundle = products / 'RepoPromptTests.xctest'
            bundle.mkdir(parents=True)
            (bundle / 'test-binary').write_bytes(b'test')
            (bundle / 'alias').symlink_to('test-binary')
            resource = products / 'Example.bundle'
            resource.mkdir()
            (resource / 'resource').write_bytes(b'data')
            (products / 'unused.o').write_bytes(b'object')
            for excluded in ('ModuleCache', 'RepoPromptApp.build', 'index/store'):
                item = products / excluded
                item.mkdir(parents=True)
                (item / 'payload').write_bytes(b'intermediate')
            checkout = source / '.build/checkouts/example'
            checkout.mkdir(parents=True)
            (checkout / 'source.swift').write_text('not transferred')
            archive = Path(temporary) / 'build.tar.gz'
            artifact.pack(source, archive)
            copy.mkdir()
            (copy / 'Package.swift').write_text('// fixture manifest')
            (copy / 'Sources/RepoPrompt/App').mkdir(parents=True)
            (copy / 'Sources/RepoPrompt/App/Main.swift').write_text('struct Main {}\n')
            copied_test = copy / 'Tests/RepoPromptTests/ExampleTests.swift'
            copied_test.parent.mkdir(parents=True)
            copied_test.write_text('import XCTest\n')
            with tarfile.open(archive, 'r:gz') as stream:
                self.assertFalse(any('ModuleCache' in member.name or
                                     'RepoPromptApp.build' in member.name or
                                     'index/store' in member.name for member in stream.getmembers()))
                stream.extractall(copy, filter='data')
            self.assertTrue((copy / '.build/out/Products/Debug/RepoPromptTests.xctest/alias').is_symlink())
            self.assertFalse((copy / '.build/out/Products/Debug/unused.o').exists())
            self.assertFalse((copy / '.build/checkouts').exists())
            self.assertIsNone(runner.verify_transferred_build(copy))
            copied_test.write_text('import Testing\n')
            self.assertIn('test sources do not match', runner.verify_transferred_build(copy))
            (copy / '.build/modularization/test-source-sha256.json').write_text(
                json.dumps({'source_sha256': {'RepoPromptTests/ExampleTests.swift':
                                             hashlib.sha256(copied_test.read_bytes()).hexdigest()}}))
            self.assertIn('cannot run Swift Testing', runner.verify_transferred_build(copy))
            copied_test.write_text('import XCTest\n')
            (copy / '.build/modularization/test-source-sha256.json').write_text(
                json.dumps({'source_sha256': {'RepoPromptTests/ExampleTests.swift':
                                             hashlib.sha256(copied_test.read_bytes()).hexdigest()}}))
            discovered = runner.discover_test_bundles('swift', copy, prebuilt_bin_path=artifact.validate(copy))
            self.assertIn('RepoPromptTests', discovered)
            (copy / 'Sources/RepoPrompt/App/Main.swift').write_text('struct Other {}\n')
            self.assertIn('do not match', runner.verify_transferred_build(copy))
            (copy / 'Sources/RepoPrompt/App/Main.swift').write_text('struct Main {}\n')
            (copy / '.build/modularization/index-check.json').unlink()
            self.assertIn('metadata missing', runner.verify_transferred_build(copy))
            (metadata / 'index-check.json').unlink()
            with self.assertRaises(ValueError):
                artifact.pack(source, archive)


class LocalExecutionTests(unittest.TestCase):
    def test_conductor_routes_root_tests_through_sandbox_runner(self) -> None:
        import conductor

        root = SCRIPT_DIR.parent
        argv, lanes, cwd, _, _ = conductor.OperationRegistry(root).prepare({
            "operation": "test",
            "args": {"filter": "WorkspaceRootRemovalTests/testCaseOnlyMissIsANoOp", "testProduct": "RepoPromptPackageTests"},
        })
        self.assertEqual(argv, [
            sys.executable, str(SCRIPT_DIR / "ci_app_test_runner.py"), "--local",
            "--test-product", "RepoPromptPackageTests",
            "--filter", "WorkspaceRootRemovalTests/testCaseOnlyMissIsANoOp",
        ])
        self.assertEqual(lanes, ["build"])
        self.assertEqual(cwd, root)

    def test_job_ticket_reaches_only_the_operation_runner(self) -> None:
        import conductor

        registry = conductor.OperationRegistry(SCRIPT_DIR.parent)
        internal = registry._internal_argv("swift_build_all", {})
        self.assertTrue(conductor.argv_is_operation_runner(internal))
        test_argv, _, _, _, _ = registry.prepare({"operation": "test", "args": {"filter": "X"}})
        self.assertFalse(conductor.argv_is_operation_runner(test_argv))
        self.assertFalse(conductor.argv_is_operation_runner(["swift", "build", "--product", "RepoPrompt"]))

        environ = {conductor.CONDUCTOR_JOB_TICKET_ENV: "ticket-1", "PATH": "/usr/bin"}
        self.assertEqual(conductor.capture_job_ticket(environ), "ticket-1")
        self.assertEqual(conductor.current_job_ticket(), "ticket-1")
        self.assertEqual(environ, {"PATH": "/usr/bin"})

    def test_local_build_then_sandboxed_execution_preserves_selection_and_exit(self) -> None:
        calls = []
        sandbox = None

        def execute(command, cwd, environment):
            nonlocal sandbox
            calls.append(tuple(command))
            self.assertEqual(cwd, SCRIPT_DIR.parent)
            if len(calls) == 1:
                self.assertEqual(dict(environment), {"PATH": "/usr/bin"})
                return 0
            sandbox = Path(environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
            self.assertTrue((sandbox / runner.SANDBOX_MARKER_NAME).is_file())
            self.assertEqual(Path(environment["HOME"]), sandbox / "home")
            self.assertEqual(environment["CFFIXED_USER_HOME"], environment["HOME"])
            self.assertEqual(Path(environment["TMPDIR"]), sandbox / "tmp")
            self.assertEqual(environment["PATH"], "/usr/bin")
            return 17

        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin"}, clear=True):
            result = runner.run_local_tests(
                swift_binary="swift", cwd=SCRIPT_DIR.parent,
                test_filter="Suite/testMethod", test_product="RepoPromptPackageTests",
                executor=execute,
            )
        self.assertEqual(result, 17)
        self.assertEqual(calls, [
            ("swift", "build", "--build-tests"),
            ("swift", "test", "--skip-build", "--test-product", "RepoPromptPackageTests", "--filter", "Suite/testMethod"),
        ])
        self.assertIsNotNone(sandbox)
        self.assertFalse(sandbox.exists())

    def test_measurement_scratch_and_build_args_reach_build_discovery_and_fallback(self) -> None:
        executor = mock.Mock(return_value=0)
        seen = {}

        def direct(**kwargs):
            seen.update(kwargs)
            return None

        scratch = Path("/r/.build/measure/x")
        runner.run_local_tests(
            swift_binary="swift", cwd=None, test_filter="S", executor=executor, direct_command=direct,
            scratch_path=scratch, build_args=("-Xlinker", "-no_deduplicate"),
        )
        swiftpm = ("--scratch-path", str(scratch), "-Xlinker", "-no_deduplicate")
        self.assertEqual(executor.call_args_list[0].args[0], ("swift", "build", "--build-tests", *swiftpm))
        self.assertEqual(seen["scratch_path"], scratch)
        self.assertEqual(executor.call_args_list[1].args[0], ("swift", "test", "--skip-build", *swiftpm, "--filter", "S"))

    def test_measurement_build_args_require_scratch_path(self) -> None:
        executor = mock.Mock(return_value=0)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(runner.run_local_tests(
                swift_binary="swift", cwd=None, executor=executor, build_args=("-Xlinker", "-x"),
            ), 2)
        executor.assert_not_called()
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            for argv in (
                ["--local", "--build-arg=-Xlinker"],
                ["--local", "--module", "XTests", "--scratch-path", "/s"],
                ["--scratch-path", "/s"],
            ):
                with self.subTest(argv=argv), self.assertRaises(SystemExit):
                    runner.parse_args(argv)
        parsed = runner.parse_args(["--local", "--scratch-path", "/s", "--build-arg=-Xswiftc", "--build-arg=-v"])
        self.assertEqual(parsed.build_args, ["-Xswiftc", "-v"])

    def test_discovery_uses_the_measurement_scratch_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            completed = subprocess.CompletedProcess([], 0, stdout=f"{tmp}\n")
            with mock.patch.object(runner.subprocess, "run", return_value=completed) as run:
                runner.discover_test_bundles("swift", None, Path("/s"))
                runner.discover_test_bundles("swift", None)
        self.assertEqual(run.call_args_list[0].args[0], ["swift", "build", "--scratch-path", "/s", "--show-bin-path"])
        self.assertEqual(run.call_args_list[1].args[0], ["swift", "build", "--show-bin-path"])

    def test_local_build_failure_does_not_launch_tests(self) -> None:
        executor = mock.Mock(return_value=9)
        self.assertEqual(runner.run_local_tests(
            swift_binary="swift", cwd=None, executor=executor,
        ), 9)
        executor.assert_called_once()


class DirectXCTestExecutionTests(unittest.TestCase):
    LISTED = [
        "RepoPromptTests.AlphaTests/testOne",
        "RepoPromptTests.AlphaTests/testTwo",
        "RepoPromptTests.BetaTests/testOne",
        "RepoPromptRegexCoreTests.RegexTests/testMatch",
    ]

    def test_flatten_listed_tests_matches_swiftpm_specifiers(self) -> None:
        document = {"name": "All Tests", "tests": [{"name": "RepoPromptCEPackageTests.xctest", "tests": [
            {"name": "RepoPromptTests.AlphaTests", "tests": [{"name": "testTwo"}, {"name": "testOne"}]},
            {"name": "RepoPromptTests.EmptyTests", "tests": []},
        ]}]}
        self.assertEqual(runner.flatten_listed_tests(document), [
            "RepoPromptTests.AlphaTests/testOne", "RepoPromptTests.AlphaTests/testTwo",
        ])

    def test_flatten_ignores_bundles_containing_only_empty_suites(self) -> None:
        document = {"name": "All Tests", "tests": [{"name": "Pkg.xctest", "tests": [
            {"name": "M.EmptyA", "tests": []},
            {"name": "M.EmptyB", "tests": []},
        ]}]}
        self.assertEqual(runner.flatten_listed_tests(document), [])

    def test_select_specifiers_uses_regex_search_and_collapses_whole_suites(self) -> None:
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, "AlphaTests"), ["RepoPromptTests.AlphaTests"])
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, "testOne"), [
            "RepoPromptTests.AlphaTests/testOne", "RepoPromptTests.BetaTests",
        ])
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, "RepoPromptRegexCoreTests"), [
            "RepoPromptRegexCoreTests.RegexTests",
        ])
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, "Alpha|Regex"), [
            "RepoPromptRegexCoreTests.RegexTests", "RepoPromptTests.AlphaTests",
        ])
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, None), ["All"])
        self.assertEqual(runner.select_xctest_specifiers(self.LISTED, "Nope"), [])
        self.assertIsNone(runner.select_xctest_specifiers(self.LISTED, "(unclosed"))

    def direct(self, root: Path, **overrides):
        options = dict(
            swift_binary="swift", cwd=root, test_filter="AlphaTests", environment={"HOME": "/sandbox"},
            lister=lambda bundle, env: list(self.LISTED),
            bundle_discovery=lambda swift, cwd: {"RepoPromptCEPackageTests": Path("/b/RepoPromptCEPackageTests.xctest")},
            xctest_binary=lambda: ("/x/xctest",),
        )
        options.update(overrides)
        return runner.direct_xctest_command(**options)

    def test_direct_command_runs_bundle_with_selectors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.direct(Path(tmp)), (
                "/x/xctest", "-XCTest", "RepoPromptTests.AlphaTests", "/b/RepoPromptCEPackageTests.xctest",
            ))
            self.assertEqual(self.direct(Path(tmp), test_filter="Nope"), ())

    def test_direct_command_falls_back_when_equivalence_is_not_guaranteed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertIsNone(self.direct(root, bundle_discovery=lambda swift, cwd: {}))
            self.assertIsNone(self.direct(root, lister=lambda bundle, env: None))
            self.assertIsNone(self.direct(root, test_filter="(bad"))
            tests = root / "Tests" / "NewTests"
            tests.mkdir(parents=True)
            (tests / "SwiftTestingTests.swift").write_text("import Testing\n@Test func works() {}\n")
            self.assertIsNone(self.direct(root))

    def test_run_local_tests_uses_direct_command_in_sandbox(self) -> None:
        calls = []

        def execute(command, cwd, environment):
            calls.append((tuple(command), environment.get("HOME")))
            return 0

        def direct(**kwargs):
            self.assertIn("rpce-local-tests-", kwargs["environment"]["HOME"])
            return ("/x/xctest", "-XCTest", "S", "/b.xctest")

        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin", "HOME": "/real"}, clear=True):
            self.assertEqual(runner.run_local_tests(
                swift_binary="swift", cwd=None, test_filter="S", executor=execute, direct_command=direct,
            ), 0)
        self.assertEqual(calls[0], (("swift", "build", "--build-tests"), "/real"))
        self.assertEqual(calls[1][0], ("/x/xctest", "-XCTest", "S", "/b.xctest"))
        self.assertIn("rpce-local-tests-", calls[1][1])

    def test_run_local_tests_reports_no_match_without_launching(self) -> None:
        executor = mock.Mock(return_value=0)
        with mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(runner.run_local_tests(
                swift_binary="swift", cwd=None, test_filter="Nope", executor=executor,
                direct_command=lambda **kwargs: (),
            ), 0)
        executor.assert_called_once()
        self.assertIn("No matching test cases were run", stdout.getvalue())

    def test_run_local_tests_falls_back_to_swiftpm(self) -> None:
        executor = mock.Mock(return_value=0)
        runner.run_local_tests(
            swift_binary="swift", cwd=None, test_filter="S", executor=executor,
            direct_command=lambda **kwargs: None,
        )
        self.assertEqual(executor.call_args_list[1].args[0], ("swift", "test", "--skip-build", "--filter", "S"))


class ModuleExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for module in ("RepoPromptMCPCoreTests", "XTests", "MixedTests", "OtherTests"):
            (self.root / "Tests" / module).mkdir(parents=True)
            (self.root / "Tests" / module / "A.swift").write_text("import XCTest\n")
        (self.root / "Tests" / "MixedTests" / "B.swift").write_text("@testable import Lib\nimport Testing\n")

    def run_mixed(self, *, statuses, listed=("MixedTests.XCSuite/testA",), test_filter="Suite", **overrides):
        calls = []
        results = list(statuses)

        def execute(command, cwd, environment):
            calls.append((tuple(command), dict(environment)))
            return results.pop(0)

        options = dict(
            swift_binary="swift", cwd=self.root, module="MixedTests", test_filter=test_filter, executor=execute,
            bundle_locator=lambda swift, cwd, module: Path("/b/MixedTests.xctest"),
            lister=lambda bundle, env: list(listed),
            xctest_binary=lambda: ("/x/xctest",),
            testing_helper=lambda swift: Path("/tc/swiftpm-testing-helper"),
            testing_environment=lambda env: {**env, "DYLD_FRAMEWORK_PATH": "/dev/Frameworks"},
        )
        options.update(overrides)
        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin", "HOME": "/real"}, clear=True), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            return runner.run_module_tests(**options), calls

    def test_module_run_builds_only_its_product_and_runs_bundle(self) -> None:
        calls = []

        def execute(command, cwd, environment):
            calls.append((tuple(command), environment.get("HOME")))
            return 0

        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin", "HOME": "/real"}, clear=True):
            result = runner.run_module_tests(
                swift_binary="swift", cwd=self.root, module="RepoPromptMCPCoreTests", test_filter="CLIMode",
                executor=execute,
                bundle_locator=lambda swift, cwd, module: Path("/b/RepoPromptMCPCoreTests.xctest"),
                lister=lambda bundle, env: ["RepoPromptMCPCoreTests.CLIModeParsingTests/testA"],
                xctest_binary=lambda: ("/x/xctest",),
                testing_helper=lambda swift: self.fail("XCTest-only targets must not look up Swift Testing"),
            )
        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], (("swift", "build", "--build-system", "swiftbuild", "--scratch-path",
                                     ".build/swiftbuild", "--product", "RepoPromptMCPCoreTests"), "/real"))
        self.assertEqual(calls[1][0], ("/x/xctest", "-XCTest", "RepoPromptMCPCoreTests.CLIModeParsingTests",
                                       "/b/RepoPromptMCPCoreTests.xctest"))
        self.assertIn("rpce-module-tests-", calls[1][1])

    def test_module_run_rejects_non_test_targets_and_missing_bundles(self) -> None:
        executor = mock.Mock(return_value=0)
        with mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(runner.run_module_tests(swift_binary="swift", cwd=self.root, module="RepoPromptApp",
                                                     executor=executor), 2)
            self.assertEqual(runner.run_module_tests(swift_binary="swift", cwd=self.root, module="MissingTests",
                                                     executor=executor), 2)
            executor.assert_not_called()
            self.assertEqual(runner.run_module_tests(swift_binary="swift", cwd=self.root, module="XTests",
                                                     executor=executor,
                                                     bundle_locator=lambda *a: None), 2)

    def test_module_run_executes_swift_testing_like_swiftpm(self) -> None:
        result, calls = self.run_mixed(statuses=[0, 0, 0])
        self.assertEqual(result, 0)
        self.assertEqual(calls[1][0], ("/x/xctest", "-XCTest", "MixedTests.XCSuite", "/b/MixedTests.xctest"))
        binary = "/b/MixedTests.xctest/Contents/MacOS/MixedTests"
        self.assertEqual(calls[2][0], (
            "/tc/swiftpm-testing-helper", "--test-bundle-path", binary, "--build-system", "swiftbuild",
            "--filter", "Suite", binary, "--testing-library", "swift-testing",
        ))
        self.assertIn("rpce-module-tests-", calls[2][1]["HOME"])
        self.assertEqual(calls[2][1]["DYLD_FRAMEWORK_PATH"], "/dev/Frameworks")
        self.assertEqual(calls[1][1]["SWIFT_TESTING_ENABLED"], "0", "xctest must not also host Swift Testing")
        self.assertNotIn("SWIFT_TESTING_ENABLED", calls[2][1])

    def test_module_run_swift_testing_exit_codes_match_swift_test(self) -> None:
        self.assertEqual(self.run_mixed(statuses=[0, 0, runner.SWIFT_TESTING_NO_TESTS_EXIT])[0], 0)
        self.assertEqual(self.run_mixed(statuses=[0, 0, 1])[0], 1)
        result, calls = self.run_mixed(statuses=[0, 1, 0])
        self.assertEqual(result, 1)
        self.assertEqual(len(calls), 3, "Swift Testing still runs after an XCTest failure")

    def test_module_run_without_xctest_matches_runs_only_swift_testing(self) -> None:
        result, calls = self.run_mixed(statuses=[0, 0], listed=("MixedTests.Other/testA",))
        self.assertEqual(result, 0)
        self.assertEqual([call[0][0] for call in calls], ["swift", "/tc/swiftpm-testing-helper"])
        result, calls = self.run_mixed(statuses=[0, 0], test_filter=None, listed=())
        self.assertEqual(calls[1][0][-5:], ("--build-system", "swiftbuild",
                                            "/b/MixedTests.xctest/Contents/MacOS/MixedTests",
                                            "--testing-library", "swift-testing"))

    def test_qualified_swift_testing_only_target_runs_failing_test(self) -> None:
        (self.root / "Tests" / "MixedTests" / "B.swift").write_text(
            "internal import Testing\n@Test func fails() { #expect(false) }\n"
        )
        for prefix in ("internal", "public", "@_exported"):
            self.assertIn('Testing', swift_imports.imported_modules(f"{prefix} import Testing\n"))
        result, calls = self.run_mixed(statuses=[0, 1], listed=(), test_filter=None)
        self.assertEqual(result, 1)
        self.assertEqual([call[0][0] for call in calls], ["swift", "/tc/swiftpm-testing-helper"])

    def test_module_run_fails_closed_when_swift_testing_cannot_run_equivalently(self) -> None:
        result, calls = self.run_mixed(statuses=[], testing_helper=lambda swift: None)
        self.assertEqual((result, calls), (2, []))
        result, calls = self.run_mixed(statuses=[0, 0], testing_environment=lambda env: None)
        self.assertEqual(result, 2)
        self.assertEqual(len(calls), 2)
        result, calls = self.run_mixed(statuses=[], test_filter=r"Suite\d")
        self.assertEqual((result, calls), (2, []))

    def test_swift_testing_detection_is_scoped_to_the_module_and_shared_with_the_aggregate_path(self) -> None:
        self.assertTrue(runner.sources_import_swift_testing(self.root / "Tests" / "MixedTests"))
        self.assertFalse(runner.sources_import_swift_testing(self.root / "Tests" / "OtherTests"))
        self.assertFalse(runner.sources_import_swift_testing(self.root / "Tests" / "MissingTests"))
        self.assertTrue(runner.package_uses_swift_testing(self.root))
        with mock.patch.object(runner, "sources_import_swift_testing", return_value=False) as shared:
            self.assertFalse(runner.package_uses_swift_testing(self.root))
        shared.assert_called_once_with(self.root / "Tests")

    def test_portable_filters(self) -> None:
        for portable in ("RepoPromptDomainRuntimeTests", "Alpha|Beta", "^Mod\\.Suite/test(One|Two)$",
                         "test[A-Z]x", "a.*b+c?", "inSuite\\(\\)"):
            self.assertTrue(runner.is_portable_filter(portable), portable)
        for unportable in ("\\d", "\\QA\\E", "(?i)abc", "(?=a)", "a{2}", "[[a]]", "[a&&b]", "[a--b]", "[]a]",
                           "[^]a]", "(unclosed", "[open", "trailing\\"):
            self.assertFalse(runner.is_portable_filter(unportable), unportable)
        self.assertIsNone(runner.select_xctest_specifiers(["M.S/testA"], "test\\w"))

    def test_developer_library_environment_prepends_platform_paths(self) -> None:
        with tempfile.TemporaryDirectory() as platform:
            (Path(platform) / "Developer").mkdir()
            completed = subprocess.CompletedProcess([], 0, stdout=f"{platform}\n")
            with mock.patch.object(runner.subprocess, "run", return_value=completed):
                environment = runner.developer_library_environment({"HOME": "/h", "DYLD_LIBRARY_PATH": "/mine"})
        developer = f"{platform}/Developer"
        self.assertEqual(environment["DYLD_FRAMEWORK_PATH"],
                         f"{developer}/Library/Frameworks:{developer}/Library/PrivateFrameworks")
        self.assertEqual(environment["DYLD_LIBRARY_PATH"], f"{developer}/usr/lib:/mine")
        self.assertEqual(environment["HOME"], "/h")
        with mock.patch.object(runner.subprocess, "run", side_effect=OSError):
            self.assertIsNone(runner.developer_library_environment({}))

    def test_conductor_forwards_module_and_skips_build_cache(self) -> None:
        import conductor

        argv, lanes, _, _, _ = conductor.OperationRegistry(SCRIPT_DIR.parent).prepare({
            "operation": "test", "args": {"module": "RepoPromptMCPCoreTests", "filter": "X"},
        })
        self.assertEqual(argv[2:], ["--local", "--module", "RepoPromptMCPCoreTests", "--filter", "X"])
        self.assertEqual(lanes, ["build"])
        self.assertFalse(conductor.BuildCacheManager.eligible("test", {"module": "RepoPromptMCPCoreTests"}))
        self.assertTrue(conductor.BuildCacheManager.eligible("test", {}))

    def test_conductor_measurement_builds_use_a_separate_scratch_path(self) -> None:
        import conductor

        root = SCRIPT_DIR.parent
        registry = conductor.OperationRegistry(root)
        scratch = str(root / ".build" / "measure" / "p05")
        argv, lanes, _, _, _ = registry.prepare({"operation": "swift-build", "args": {
            "product": "RepoPrompt", "scratch": "p05",
            "swiftcFlags": ["-Xfrontend", "-warn-long-function-bodies=200"], "linkerFlags": ["-no_deduplicate"],
        }})
        self.assertEqual(argv, [
            "swift", "build", "--product", "RepoPrompt", "--scratch-path", scratch,
            "-Xswiftc", "-Xfrontend", "-Xswiftc", "-warn-long-function-bodies=200", "-Xlinker", "-no_deduplicate",
        ])
        self.assertEqual(lanes, ["build"])
        argv, _, _, _, _ = registry.prepare({"operation": "test", "args": {
            "filter": "X", "scratch": "p05", "linkerFlags": ["-no_deduplicate"],
        }})
        self.assertEqual(argv[2:], [
            "--local", "--scratch-path", scratch, "--build-arg=-Xlinker", "--build-arg=-no_deduplicate", "--filter", "X",
        ])
        plain, _, _, _, _ = registry.prepare({"operation": "swift-build", "args": {"product": "RepoPrompt"}})
        self.assertEqual(plain, ["swift", "build", "--product", "RepoPrompt"])
        self.assertFalse(conductor.BuildCacheManager.eligible("swift-build", {"product": "RepoPrompt", "scratch": "p05"}))
        self.assertFalse(conductor.BuildCacheManager.eligible("test", {"scratch": "p05"}))

    def test_conductor_rejects_unsafe_measurement_requests(self) -> None:
        import conductor

        registry = conductor.OperationRegistry(SCRIPT_DIR.parent)
        rejected = (
            ("swift-build", {"product": "RepoPrompt", "swiftcFlags": ["-v"]}),
            ("test", {"linkerFlags": ["-no_deduplicate"]}),
            ("swift-build", {"product": "all", "scratch": "p05"}),
            ("test", {"module": "RepoPromptMCPCoreTests", "scratch": "p05"}),
            ("swift-build", {"product": "RepoPrompt", "scratch": "../escape"}),
            ("swift-build", {"product": "RepoPrompt", "scratch": "a/b"}),
        )
        for operation, args in rejected:
            with self.subTest(operation=operation, args=args), self.assertRaises(conductor.ConductorError):
                registry.prepare({"operation": operation, "args": args})

    def test_seed_sanitizing_drops_measurement_scratch(self) -> None:
        import conductor

        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / ".build"
            (build / "measure" / "p05").mkdir(parents=True)
            (build / "measure" / "p05" / "build.db").write_text("x")
            (build / "debug").mkdir()
            conductor.BuildCacheManager._sanitize_seed(build)
            self.assertFalse((build / "measure").exists())
            self.assertTrue((build / "debug").is_dir())

    def test_seed_sanitizing_drops_module_test_scratch(self) -> None:
        import conductor

        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / ".build"
            (build / "swiftbuild" / "arm64-apple-macosx").mkdir(parents=True)
            (build / "swiftbuild" / "arm64-apple-macosx" / "build.db").write_text("x")
            (build / "debug").mkdir()
            conductor.BuildCacheManager._sanitize_seed(build)
            self.assertFalse((build / "swiftbuild").exists())
            self.assertTrue((build / "debug").is_dir())


class TestDiscoveryTests(unittest.TestCase):
    def test_parse_suite_methods_deduplicates_and_sorts(self) -> None:
        output = "\n".join(
            [
                "RepoPromptTests.SecondTests/testB",
                "noise",
                "RepoPromptTests.FirstTests/testZ",
                "RepoPromptTests.FirstTests/testA",
                "RepoPromptTests.FirstTests/testA",
            ]
        )

        self.assertEqual(
            runner.parse_suite_methods(output),
            {
                "RepoPromptTests.FirstTests": (
                    "RepoPromptTests.FirstTests/testA",
                    "RepoPromptTests.FirstTests/testZ",
                ),
                "RepoPromptTests.SecondTests": (
                    "RepoPromptTests.SecondTests/testB",
                ),
            },
        )

    def test_invalid_shard_arguments_are_rejected(self) -> None:
        invalid_arguments = ((0, 1), (2, 0), (2, 3))
        for shard_count, shard_index in invalid_arguments:
            with self.subTest(
                shard_count=shard_count,
                shard_index=shard_index,
            ):
                with self.assertRaises(ValueError):
                    runner.validate_shard_args(shard_count, shard_index)

        with self.assertRaisesRegex(ValueError, "greater than zero"):
            runner.assign_suites_to_shards({}, 0)

    def test_lpt_sharding_is_deterministic_balanced_and_exhaustive(self) -> None:
        counts = {
            "RepoPromptTests.A": 8,
            "RepoPromptTests.B": 7,
            "RepoPromptTests.C": 4,
            "RepoPromptTests.D": 3,
            "RepoPromptTests.E": 2,
        }

        shards, loads = runner.assign_suites_to_shards(counts, 2)

        self.assertEqual(loads, (13, 11))
        self.assertLessEqual(max(loads) - min(loads), 2)
        self.assertEqual(set(shards[0] + shards[1]), set(counts))
        self.assertEqual(
            runner.assign_suites_to_shards(dict(reversed(counts.items())), 2),
            (shards, loads),
        )

class TestBundleResolutionTests(unittest.TestCase):
    def test_discover_test_bundles_parses_show_bin_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bin_path = Path(directory)
            first = bin_path / "RepoPromptTests.xctest"
            second = bin_path / "RepoPromptCodeMapCoreTests.xctest"
            first.mkdir()
            second.mkdir()
            completed = subprocess.CompletedProcess(
                args=["swift", "build", "--show-bin-path"],
                returncode=0,
                stdout=f"{bin_path}\n",
                stderr="",
            )
            with mock.patch.object(runner.subprocess, "run", return_value=completed):
                discovered = runner.discover_test_bundles("swift", None)

        self.assertEqual(
            discovered,
            {
                "RepoPromptCodeMapCoreTests": second,
                "RepoPromptTests": first,
            },
        )

    def test_unique_package_bundle_is_preferred(self) -> None:
        package_bundle = Path("/tmp/RepoPromptPackageTests.xctest")
        discovered = {
            "RepoPromptPackageTests": package_bundle,
            "RepoPromptTests": Path("/tmp/RepoPromptTests.xctest"),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )

        self.assertEqual(selection.package_bundle, package_bundle)
        self.assertEqual(selection.target_bundles, {})

    def test_target_bundle_resolution_and_missing_target_diagnostic(self) -> None:
        root_bundle = Path("/tmp/RepoPromptTests.xctest")
        discovered = {
            "RepoPromptTests": root_bundle,
            "RepoPromptCodeMapCoreTests": Path(
                "/tmp/RepoPromptCodeMapCoreTests.xctest"
            ),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )
            with self.assertRaisesRegex(
                ValueError,
                r"missing XCTest bundles for selected targets: \['MissingTests'\]",
            ):
                runner.resolve_bundle_selection(
                    swift_binary="swift",
                    cwd=None,
                    suites=("MissingTests.ParserTests",),
                )

        self.assertEqual(
            selection.target_bundles,
            {"RepoPromptTests": root_bundle},
        )

    def test_command_construction_uses_xctest_or_swift_fallback(self) -> None:
        xctest_selection = runner.BundleSelection(
            None,
            {"RepoPromptTests": Path("/tmp/RepoPromptTests.xctest")},
            ("/usr/bin/xctest",),
        )
        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="swift",
                bundle_selection=xctest_selection,
            ),
            (
                "/usr/bin/xctest",
                "-XCTest",
                "RepoPromptTests.ParserContractTests",
                "/tmp/RepoPromptTests.xctest",
            ),
        )

        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="custom-swift",
                bundle_selection=runner.BundleSelection(None, {}, None),
            ),
            (
                "custom-swift",
                "test",
                "--skip-build",
                "--filter",
                "RepoPromptTests.ParserContractTests",
            ),
        )


class TestExecutionTests(unittest.TestCase):
    def empty_bundle_selection(self) -> runner.BundleSelection:
        return runner.BundleSelection(None, {}, None)

    def test_suite_environment_preserves_inherited_values_and_replaces_state(self) -> None:
        inherited = {
            "PATH": "/usr/bin",
            "CUSTOM_TOKEN": "preserved",
            "HOME": "/old/home",
            "CFFIXED_USER_HOME": "/old/fixed-home",
            "TMPDIR": "/old/tmpdir",
            "TMP": "/old/tmp",
            "TEMP": "/old/temp",
            "XDG_CONFIG_HOME": "/old/config",
            "XDG_CACHE_HOME": "/old/cache",
            "XDG_DATA_HOME": "/old/data",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.FirstTests",
                inherited,
            )
            second = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.SecondTests",
                inherited,
            )

            self.assertNotEqual(first["HOME"], second["HOME"])
            self.assertEqual(first["HOME"], first["CFFIXED_USER_HOME"])
            self.assertEqual(first["TMPDIR"], first["TMP"])
            self.assertEqual(first["TMPDIR"], first["TEMP"])
            self.assertEqual(first["PATH"], "/usr/bin")
            self.assertEqual(first["CUSTOM_TOKEN"], "preserved")
            sandbox = Path(first["REPOPROMPT_TEST_SANDBOX_ROOT"])
            self.assertTrue((sandbox / runner.SANDBOX_MARKER_NAME).is_file())
            self.assertEqual(Path(first["HOME"]), sandbox / "home")
            self.assertEqual(Path(first["TMPDIR"]), sandbox / "tmp")
            self.assertEqual(Path(first["TMP"]), sandbox / "tmp")
            self.assertEqual(Path(first["TEMP"]), sandbox / "tmp")
            for key in (
                "HOME",
                "TMPDIR",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "XDG_DATA_HOME",
            ):
                self.assertTrue(Path(first[key]).is_dir(), key)
                self.assertNotEqual(first[key], inherited[key])

    def test_runner_attempts_each_isolated_suite_once_and_preserves_first_failure(self) -> None:
        calls: list[tuple[str, ...]] = []
        statuses = iter([9, 3, 0])

        def executor(command, _cwd, _environment) -> int:
            calls.append(tuple(command))
            return next(statuses)

        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            result = runner.run_selected_suites(
                ("RepoPromptTests.FirstTests", "RepoPromptTests.SecondTests", "RepoPromptTests.ThirdTests"),
                swift_binary="swift",
                cwd=None,
                bundle_selection=self.empty_bundle_selection(),
                sandbox_root=Path(directory),
                executor=executor,
                output=output,
            )

        self.assertEqual(result, 9)
        self.assertEqual([call[-1] for call in calls], [
            "RepoPromptTests.FirstTests", "RepoPromptTests.SecondTests", "RepoPromptTests.ThirdTests",
        ])
        self.assertIn('2 of 3 suites failed', output.getvalue())
        self.assertEqual(output.getvalue().count('::endgroup::'), 3)

if __name__ == "__main__":
    unittest.main()
