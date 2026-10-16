#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import unittest
from unittest import mock
import ci_resolve_packages as resolver


class ResolutionTests(unittest.TestCase):
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

    def test_retry_budget_cannot_be_unbounded(self):
        with self.assertRaises(ValueError):
            resolver.resolve(Path('/repo'), attempts=0)
        with self.assertRaises(ValueError):
            resolver.resolve(Path('/repo'), timeout=601)


if __name__ == '__main__':
    unittest.main()
