#!/usr/bin/env python3
"""Unit tests for the conductor smoke flow's launch/restore readiness handling (issue #294)."""

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path
from typing import List, Tuple
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402

BLOCKED_BY_RESTORE = (
    'Error: [-32600] Invalid Request: Workspace switch to "repoprompt-ce" is blocked by a active switch '
    'to "repoprompt-ce" (reason: restore, phase: hydrating roots, total age: 1.2s, phase age: 0.4s).\n'
)
BLOCKED_BY_STALE = (
    'Workspace switch to "repoprompt-ce" is blocked by a stale switch to "other" '
    "(reason: restore, phase: restoring state, total age: 61.0s, phase age: 60.0s).\n"
)


class WorkspaceSwitchBlockedDetectionTests(unittest.TestCase):
    def test_detects_active_and_stale_switch_refusals(self) -> None:
        self.assertTrue(conductor.is_workspace_switch_blocked_by_active_switch(BLOCKED_BY_RESTORE))
        self.assertTrue(conductor.is_workspace_switch_blocked_by_active_switch(BLOCKED_BY_STALE))

    def test_ignores_other_refusals(self) -> None:
        self.assertFalse(conductor.is_workspace_switch_blocked_by_active_switch(""))
        self.assertFalse(conductor.is_workspace_switch_blocked_by_active_switch('Already on workspace "repoprompt-ce"\n'))
        self.assertFalse(conductor.is_workspace_switch_blocked_by_active_switch("Error: Cannot connect to RepoPrompt\n"))
        self.assertFalse(conductor.is_workspace_switch_blocked_by_active_switch('Workspace "missing" not found\n'))


class WorkspaceSwitchReadinessRetryTests(unittest.TestCase):
    def _run(
        self,
        results: List[Tuple[int, str, str]],
        clock: List[float],
        deadline: float,
    ) -> Tuple[Tuple[int, str, str], int, List[float]]:
        calls = 0
        sleeps: List[float] = []

        def fake_run(name, argv, cwd, env=None, allow_exit_codes=None, timeout=None):
            nonlocal calls
            self.assertEqual(name, "workspace switch")
            self.assertEqual(allow_exit_codes, {0, 1})
            result = results[min(calls, len(results) - 1)]
            calls += 1
            return result

        def fake_now() -> float:
            return clock[0]

        def fake_sleep(seconds: float) -> None:
            sleeps.append(seconds)
            clock[0] += seconds

        with mock.patch.object(conductor, "run_operation_command", side_effect=fake_run), \
                mock.patch.object(conductor, "now", side_effect=fake_now), \
                mock.patch.object(conductor.time, "sleep", side_effect=fake_sleep), \
                contextlib.redirect_stdout(io.StringIO()):
            outcome = conductor.run_workspace_switch_with_readiness_retry(
                "workspace switch",
                ["rpce-cli-debug", "-w", "1", "-e", "workspace switch repoprompt-ce"],
                "repoprompt-ce",
                Path("/tmp"),
                None,
                readiness_deadline=deadline,
                poll_seconds=2.0,
            )
        return outcome, calls, sleeps

    def test_retries_while_blocked_by_restore_then_succeeds(self) -> None:
        outcome, calls, sleeps = self._run(
            [(1, "", BLOCKED_BY_RESTORE), (1, "", BLOCKED_BY_RESTORE), (0, "switched\n", "")],
            clock=[100.0],
            deadline=190.0,
        )
        self.assertEqual(outcome[0], 0)
        self.assertEqual(calls, 3)
        self.assertEqual(sleeps, [2.0, 2.0])

    def test_already_on_workspace_after_restore_is_success(self) -> None:
        outcome, calls, _sleeps = self._run(
            [(1, "", BLOCKED_BY_RESTORE), (1, "", 'Already on workspace "repoprompt-ce"\n')],
            clock=[100.0],
            deadline=190.0,
        )
        self.assertEqual(outcome[0], 0)
        self.assertEqual(calls, 2)

    def test_gives_up_at_readiness_deadline_with_original_failure(self) -> None:
        outcome, calls, sleeps = self._run(
            [(1, "", BLOCKED_BY_RESTORE)],
            clock=[100.0],
            deadline=105.0,
        )
        self.assertEqual(outcome[0], 1)
        self.assertIn("blocked by a active switch", outcome[2])
        # 100 -> 102 -> 104 retried; at 106 the deadline has passed and the failure is returned.
        self.assertEqual(sleeps, [2.0, 2.0, 2.0])
        self.assertEqual(calls, 4)

    def test_unrelated_refusal_is_not_retried(self) -> None:
        outcome, calls, sleeps = self._run(
            [(1, "", 'Workspace "repoprompt-ce" not found\n'), (0, "", "")],
            clock=[100.0],
            deadline=190.0,
        )
        self.assertEqual(outcome[0], 1)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])

    def test_connection_failure_exit_code_is_not_retried(self) -> None:
        outcome, calls, sleeps = self._run(
            [(73, "", "Error: Cannot connect to RepoPrompt\n"), (0, "", "")],
            clock=[100.0],
            deadline=190.0,
        )
        self.assertEqual(outcome[0], 73)
        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main()
