#!/usr/bin/env python3
import contextlib
import io
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import unittest
from unittest import mock
import ci_resolve_packages as resolver


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
        with mock.patch.object(resolver, 'session_process_groups', side_effect=RuntimeError('inventory failed')):
            with self.assertRaisesRegex(RuntimeError, 'inventory failed'):
                resolver.terminate_resolution(process)

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

        with mock.patch.object(resolver, 'session_process_groups', side_effect=inventory), \
                mock.patch.object(resolver.os, 'killpg', side_effect=send_signal) as signals, \
                mock.patch.object(resolver.time, 'monotonic', side_effect=lambda: clock), \
                mock.patch.object(resolver.time, 'sleep', side_effect=sleep):
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
