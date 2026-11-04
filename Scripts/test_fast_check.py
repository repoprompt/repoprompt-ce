#!/usr/bin/env python3
"""The local iteration command is bounded, serial, and fails before later work."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
STEPS = ['git diff --check', 'git diff --cached --check', 'guardrails',
         'python3 Scripts/test_ci_admission.py', 'python3 Scripts/test_ci_job_diagnostics.py',
         'python3 Scripts/test_modularization_tooling.py', 'python3 Scripts/test_ci_app_test_runner.py',
         'python3 Scripts/test_ci_test_coverage.py', 'python3 Scripts/test_ci_resolve_packages.py']


class FastCheckTests(unittest.TestCase):
    def run_check(self, fail=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Makefile').write_text((ROOT / 'Makefile').read_text())
            (root / 'Scripts').mkdir()
            (root / 'bin').mkdir()
            for path, command in [('bin/git', 'git $*'), ('bin/python3', 'python3 $*'),
                                  ('Scripts/guardrails.sh', 'guardrails')]:
                stub = root / path
                stub.write_text('#!/bin/sh\nstep="' + command + '"\n'
                                'printf "%s\\n" "$step" >> "$TRACE"\n'
                                '[ "$step" != "$FAIL_STEP" ] || exit 7\n')
                stub.chmod(0o755)
            trace = root / 'trace'
            env = {**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                   'TRACE': str(trace), 'FAIL_STEP': fail}
            # Prove -j cannot run later phases before an earlier failure.
            result = subprocess.run(['make', '--no-print-directory', '-j4', 'check-fast'],
                                    cwd=root, env=env, capture_output=True, text=True)
            return result, trace.read_text().splitlines()

    def test_only_declared_lightweight_checks_execute_in_order(self):
        result, trace = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, STEPS)
        self.assertEqual(result.stdout.splitlines()[-1],
                         'Fast checks passed. Swift lint/tests/builds, secret scans and release qualification were NOT run.')
        self.assertTrue(result.stdout.endswith('\n'))

    def test_each_failure_stops_later_phases_and_never_claims_success(self):
        for index, step in enumerate(STEPS):
            with self.subTest(step=step):
                result, trace = self.run_check(fail=step)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(trace, STEPS[:index + 1])
                self.assertNotIn('Fast checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
