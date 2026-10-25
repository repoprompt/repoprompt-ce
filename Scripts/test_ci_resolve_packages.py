#!/usr/bin/env python3
import contextlib
import io
import os
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import unittest
from unittest import mock
import ci_resolve_packages as resolver
import ci_process_session as process_session


class ResolutionCancellationTests(unittest.TestCase):
    def assert_process_stopped(self, pid):
        result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
        self.assertFalse(result.stderr, 'process inspection must succeed: ' + result.stderr)
        self.assertTrue(result.returncode != 0 or result.stdout.strip().startswith('Z'), result.stdout)

    def run_owned_attempt(self, *, initial_signal=None, cleanup_signal=None,
                         launch_gate=False, timeout_cleanup=False):
        with tempfile.TemporaryDirectory() as temporary:
            control, barrier = socket.socketpair()
            control.settimeout(5)
            source = '''
import os, signal
reader, writer = os.pipe()
if os.fork() == 0:
    os.close(reader)
    os.setpgrp()
    print('descendant=' + str(os.getpid()), flush=True)
    os.close(1)
    os.close(2)
    os.write(writer, b'R')
    os.close(writer)
    while True: signal.pause()
os.close(writer)
os.read(reader, 1)
os.close(reader)
print('leader=' + str(os.getpid()), flush=True)
os.close(1)
os.close(2)
''' + ('while True: signal.pause()\n' if initial_signal is not None or timeout_cleanup else 'os._exit(0)\n')
            wrapper = f'''
import ci_resolve_packages as resolver, ci_process_session, signal, socket
from pathlib import Path
before = {{sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}}
if {launch_gate!r}:
    barrier = socket.socket(fileno={barrier.fileno()})
    launch = resolver.subprocess.Popen
    def gated_launch(*args, **kwargs):
        resolver.subprocess.Popen = launch
        process = launch(*args, **kwargs)
        barrier.sendall(b'R')
        barrier.recv(1)
        return process
    resolver.subprocess.Popen = gated_launch
if {cleanup_signal is not None!r}:
    barrier = socket.socket(fileno={barrier.fileno()})
    inventory = ci_process_session.session_process_groups
    def gated_inventory(session_id):
        ci_process_session.session_process_groups = inventory
        barrier.sendall(b'R')
        barrier.recv(1)
        return inventory(session_id)
    ci_process_session.session_process_groups = gated_inventory
def run(_command, **kwargs):
    return resolver.run_resolution({[sys.executable, '-u', '-c', source]!r}, **kwargs)
def forbid_retry(_seconds):
    raise AssertionError('a cancelled or successful attempt must not retry')
try:
    raise SystemExit(resolver.resolve(Path({temporary!r}), run=run, sleep=forbid_retry,
                                     timeout={1 if timeout_cleanup else 300}))
finally:
    assert before == {{sig: signal.getsignal(sig) for sig in before}}, 'signal handlers must be restored'
'''
            process = subprocess.Popen(
                [sys.executable, '-u', '-c', wrapper], cwd=Path(__file__).resolve().parent,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, pass_fds=(barrier.fileno(),),
            )
            barrier.close()
            pids = {}
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    observed = b''
                    deadline = time.monotonic() + 5
                    while len(pids) < 2:
                        self.assertGreater(deadline, time.monotonic(), observed)
                        for key, _ in selector.select(max(0, deadline - time.monotonic())):
                            observed += os.read(key.fd, 65536)
                        for line in observed.splitlines():
                            if line.startswith((b'leader=', b'descendant=')) and line + b'\n' in observed:
                                name, raw_pid = line.split(b'=')
                                pids[name] = int(raw_pid)
                if launch_gate:
                    self.assertEqual(control.recv(1), b'R')
                if initial_signal is not None:
                    os.kill(process.pid, initial_signal)
                if launch_gate:
                    control.sendall(b'G')
                if cleanup_signal is not None:
                    self.assertEqual(control.recv(1), b'R')
                    os.kill(process.pid, cleanup_signal)
                    control.sendall(b'G')
                output, _ = process.communicate(timeout=10)
                expected = (-signal.SIGINT if initial_signal == signal.SIGINT else
                            128 + initial_signal if initial_signal is not None else
                            128 + cleanup_signal if cleanup_signal is not None else 0)
                self.assertEqual(process.returncode, expected, observed + output)
                self.assertNotIn(b'Dependency resolution attempt 2/', observed + output)
                for pid in pids.values():
                    self.assert_process_stopped(pid)
            finally:
                control.close()
                if process.poll() is None:
                    process.kill()
                # A red regression must still stop only its exact owned fixture groups.
                for pid in pids.values():
                    try:
                        if os.getsid(pid) == pids.get(b'leader'):
                            os.killpg(os.getpgid(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.communicate(timeout=5)

    def test_cancelled_attempt_stops_its_session_without_retry(self):
        for initial in (signal.SIGTERM, signal.SIGINT):
            for repeated in (None, signal.SIGINT if initial == signal.SIGTERM else signal.SIGTERM):
                with self.subTest(initial=initial, repeated=repeated):
                    self.run_owned_attempt(initial_signal=initial, cleanup_signal=repeated)

    def test_successful_attempt_drains_children_and_honors_cancellation_during_cleanup(self):
        for cancellation in (None, signal.SIGTERM, signal.SIGINT):
            with self.subTest(cancellation=cancellation):
                self.run_owned_attempt(cleanup_signal=cancellation)

    def test_cancellation_while_launch_is_handing_back_ownership_stops_the_attempt(self):
        for cancellation in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(cancellation=cancellation):
                self.run_owned_attempt(initial_signal=cancellation, launch_gate=True)

    def test_cancellation_during_timeout_cleanup_aborts_without_retry(self):
        for cancellation in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(cancellation=cancellation):
                self.run_owned_attempt(cleanup_signal=cancellation, timeout_cleanup=True)

    def test_failed_spawn_restores_handlers_and_preserves_the_error(self):
        before = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        with mock.patch.object(resolver.subprocess, 'Popen', side_effect=FileNotFoundError('missing resolver')), \
                mock.patch.object(resolver, 'terminate_resolution') as cleanup:
            with self.assertRaisesRegex(FileNotFoundError, 'missing resolver'):
                resolver.run_resolution(['missing'], cwd=None, check=False, timeout=1)
        self.assertEqual(before, {sig: signal.getsignal(sig) for sig in before})
        cleanup.assert_not_called()


class ResolutionTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        capture = contextlib.redirect_stdout(self.output)
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def test_transient_failure_recovers_with_bounded_backoff(self):
        run = mock.Mock(side_effect=[subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0)])
        sleep = mock.Mock()
        self.assertEqual(resolver.resolve(Path('/repo'), '.build/swiftbuild', run=run, sleep=sleep), 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args.args[0], ['swift', 'package', '--scratch-path', '.build/swiftbuild', 'resolve'])
        self.assertEqual(run.call_args.kwargs['timeout'], 300)
        sleep.assert_called_once_with(10)

    def test_existing_lockfile_cannot_be_rewritten_by_resolution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Package.resolved').write_text('{}')
            run = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            self.assertEqual(resolver.resolve(root, run=run), 0)
            self.assertIn('--force-resolved-versions', run.call_args.args[0])

    def test_permanent_failure_remains_failure_and_stops_after_three(self):
        run = mock.Mock(return_value=subprocess.CompletedProcess([], 1))
        sleep = mock.Mock()
        self.assertEqual(resolver.resolve(Path('/repo'), run=run, sleep=sleep), 1)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(sleep.call_args_list, [mock.call(10), mock.call(20)])
        self.assertIn('::error::Dependency resolution/download failed', self.output.getvalue())

    def test_timeouts_fail_closed(self):
        run = mock.Mock(side_effect=subprocess.TimeoutExpired(['swift'], 300))
        self.assertEqual(resolver.resolve(Path('/repo'), run=run, sleep=mock.Mock()), 124)
        self.assertEqual(run.call_count, 3)

    def test_timeout_terminates_spawned_child_before_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / 'ticks'
            child = "import time; from pathlib import Path; p=Path(" + repr(str(marker)) + "); "
            child += "\nwhile True: p.write_text(str(time.time())); time.sleep(0.02)"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]); time.sleep(60)"
            with self.assertRaises(subprocess.TimeoutExpired):
                resolver.run_resolution([sys.executable, '-c', parent], cwd=root, check=False, timeout=3)
            self.assertTrue(marker.exists())
            last_tick = marker.read_text()
            time.sleep(0.1)
            self.assertEqual(marker.read_text(), last_tick)

    def test_timeout_terminates_children_in_their_own_process_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / 'ticks'
            identity = root / 'child-pid'
            child = "import os,time; from pathlib import Path; Path(" + repr(str(identity)) + ").write_text(str(os.getpid())); "
            child += "p=Path(" + repr(str(marker)) + "); "
            child += "\nwhile True: p.write_text(str(time.time())); time.sleep(0.02)"
            parent = "import os,subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]"
            parent += ",preexec_fn=os.setpgrp); time.sleep(60)"
            unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    resolver.run_resolution([sys.executable, '-c', parent], cwd=root, check=False, timeout=3)
                self.assertTrue(marker.exists())
                last_tick = marker.read_text()
                time.sleep(0.1)
                self.assertEqual(marker.read_text(), last_tick)
                self.assertIsNone(unrelated.poll(), 'cleanup must not signal other sessions')
            finally:
                unrelated.kill()
                unrelated.wait()
                if identity.exists():
                    try:
                        os.kill(int(identity.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_process_inventory_failure_cannot_be_treated_as_a_retryable_timeout(self):
        process = mock.Mock(pid=123)
        with mock.patch.object(process_session, 'session_process_groups', side_effect=RuntimeError('inventory failed')):
            with self.assertRaisesRegex(RuntimeError, 'inventory failed'):
                resolver.terminate_resolution(process)

    def test_empty_group_permission_error_requires_a_confirmed_empty_inventory(self):
        with mock.patch.object(process_session, 'session_process_groups', side_effect=[{456}, set()]), \
                mock.patch.object(process_session.os, 'killpg', side_effect=PermissionError):
            process_session.signal_session(123, signal.SIGKILL)

    def test_live_group_permission_error_cannot_be_treated_as_successful_cleanup(self):
        with mock.patch.object(process_session, 'session_process_groups', return_value={456}), \
                mock.patch.object(process_session.os, 'killpg', side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                process_session.signal_session(123, signal.SIGKILL)

    def test_slow_inventory_does_not_consume_signal_grace_period(self):
        process = mock.Mock(pid=123)
        clock = 0.0
        child_alive = True
        observed_exit = False

        def inventory(session_id):
            nonlocal clock, observed_exit
            self.assertEqual(session_id, process.pid)
            # A valid ps inventory can exceed the one-second SIGKILL grace.
            clock += 2.0
            observed_exit = not child_alive
            return {456} if child_alive else set()

        def send_signal(group, sig):
            nonlocal child_alive
            self.assertEqual(group, 456)
            if sig == signal.SIGKILL:
                child_alive = False

        def sleep(seconds):
            nonlocal clock
            clock += seconds

        with mock.patch.object(process_session, 'session_process_groups', side_effect=inventory), \
                mock.patch.object(process_session.os, 'killpg', side_effect=send_signal) as signals, \
                mock.patch.object(process_session.time, 'monotonic', side_effect=lambda: clock), \
                mock.patch.object(process_session.time, 'sleep', side_effect=sleep):
            resolver.terminate_resolution(process)

        signals.assert_any_call(456, signal.SIGTERM)
        signals.assert_any_call(456, signal.SIGKILL)
        self.assertFalse(child_alive)
        self.assertTrue(observed_exit, 'cleanup must confirm exit after sending SIGKILL')
        process.wait.assert_called_once_with(timeout=1)

    def test_failed_launcher_cleans_up_reparented_child_before_returning(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / 'ticks'
            identity = root / 'child-pid'
            child = "import os,time; from pathlib import Path; Path(" + repr(str(identity)) + ").write_text(str(os.getpid())); "
            child += "p=Path(" + repr(str(marker)) + "); "
            child += "\nwhile True: p.write_text(str(time.time())); time.sleep(0.02)"
            parent = "import os,subprocess,sys,time; from pathlib import Path; "
            parent += "subprocess.Popen([sys.executable,'-c'," + repr(child) + "],preexec_fn=os.setpgrp); "
            parent += "p=Path(" + repr(str(marker)) + ")\nwhile not p.exists(): time.sleep(0.01)\nsys.exit(7)"
            try:
                result = resolver.run_resolution([sys.executable, '-c', parent], cwd=root, check=False, timeout=3)
                self.assertEqual(result.returncode, 7)
                last_tick = marker.read_text()
                time.sleep(0.1)
                self.assertEqual(marker.read_text(), last_tick)
            finally:
                if identity.exists():
                    try:
                        os.kill(int(identity.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_process_inventory_timeout_aborts_instead_of_starting_another_attempt(self):
        process = mock.Mock(pid=123)
        process.wait.side_effect = subprocess.TimeoutExpired(['swift'], 300)
        with mock.patch.object(resolver.subprocess, 'Popen', return_value=process) as launch, \
                mock.patch.object(resolver.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['ps'], 5)):
            with self.assertRaisesRegex(RuntimeError, 'Cannot inventory'):
                resolver.resolve(Path('/repo'), sleep=mock.Mock())
        self.assertEqual(launch.call_count, 1)

    def test_retry_budget_cannot_be_unbounded(self):
        with self.assertRaises(ValueError):
            resolver.resolve(Path('/repo'), attempts=0)
        with self.assertRaises(ValueError):
            resolver.resolve(Path('/repo'), timeout=601)


if __name__ == '__main__':
    unittest.main()
