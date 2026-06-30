#!/usr/bin/env python3
"""Unit tests for the hosted CI app-test runner."""

from __future__ import annotations

import io
import time
import unittest

import ci_app_test_runner


class FakeProcess:
    next_pid = 1000

    def __init__(self, lines: list[str] | None = None, *, returncode: int | None = None) -> None:
        self.lines = lines or []
        self.returncode = returncode
        self.pid = FakeProcess.next_pid
        FakeProcess.next_pid += 1
        self.stdout = iter(self.lines)
        self.kill_called = False
        self.wait_called = False

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        self.wait_called = True
        if self.returncode is None:
            deadline = None if timeout is None else time.monotonic() + timeout
            while self.returncode is None:
                if deadline is not None and time.monotonic() >= deadline:
                    raise TimeoutError("fake process did not exit")
                time.sleep(0.001)
        return self.returncode

    def kill(self) -> None:
        self.kill_called = True
        self.returncode = -9


class CIAppTestRunnerTests(unittest.TestCase):
    def stop_fake_process(self, stopped: list[FakeProcess]):
        def stop(process: FakeProcess) -> None:
            stopped.append(process)
            process.returncode = -15

        return stop

    def test_parse_suites_returns_unique_sorted_suite_names(self) -> None:
        output = "\n".join(
            [
                "RepoPromptTests.B/testTwo",
                "RepoPromptTests.A/testOne",
                "RepoPromptTests.B/testThree",
                "noise without slash",
                "",
            ]
        )

        self.assertEqual(
            ci_app_test_runner.parse_suites(output),
            ["RepoPromptTests.A", "RepoPromptTests.B"],
        )

    def test_xctest_failure_detection_matches_xctest_issue_lines_only(self) -> None:
        self.assertTrue(
            ci_app_test_runner.is_xctest_failure_line(
                "/tmp/File.swift:10: error: -[RepoPromptTests.S testExample] : XCTAssert failed\n"
            )
        )
        self.assertTrue(
            ci_app_test_runner.is_xctest_failure_line(
                "/tmp/File.swift:10:2: error: -[RepoPromptTests.S testExample] : XCTAssert failed\n"
            )
        )
        self.assertFalse(
            ci_app_test_runner.is_xctest_failure_line(
                "2026-06-29T12:00:00Z error com.repoprompt ordinary application log\n"
            )
        )

    def test_started_test_parser_tracks_last_xctest_method(self) -> None:
        self.assertEqual(
            ci_app_test_runner.parse_started_test(
                "Test Case '-[RepoPromptTests.S testExample]' started.\n"
            ),
            "RepoPromptTests.S testExample",
        )
        self.assertIsNone(ci_app_test_runner.parse_started_test("Test Suite started.\n"))

    def test_cleanup_groups_never_include_runner_process_group(self) -> None:
        original_getpgrp = ci_app_test_runner.os.getpgrp
        original_getpgid = ci_app_test_runner.os.getpgid
        try:
            ci_app_test_runner.os.getpgrp = lambda: 42
            ci_app_test_runner.os.getpgid = lambda _: 42
            self.assertEqual(
                ci_app_test_runner.process_groups_for_cleanup(1000, {42, 84}),
                {84},
            )

            ci_app_test_runner.os.getpgid = lambda _: 77
            self.assertEqual(
                ci_app_test_runner.process_groups_for_cleanup(1000, {42, 84}),
                {77, 84},
            )
        finally:
            ci_app_test_runner.os.getpgrp = original_getpgrp
            ci_app_test_runner.os.getpgid = original_getpgid

    def test_fail_fast_stops_after_first_xctest_issue(self) -> None:
        stopped: list[FakeProcess] = []
        output = io.StringIO()
        fake = FakeProcess(
            [
                "Test Case '-[RepoPromptTests.S testExample]' started.\n",
                "/tmp/File.swift:10: error: -[RepoPromptTests.S testExample] : XCTAssert failed\n",
                "line that would have appeared before a hang\n",
            ]
        )

        result = ci_app_test_runner.run_suite(
            "RepoPromptTests.S",
            timeout_seconds=1.0,
            silent_timeout_retries=0,
            process_factory=lambda suite: fake,
            stop_process_tree_func=self.stop_fake_process(stopped),
            output=output,
            poll_interval_seconds=0.001,
        )

        self.assertEqual(result.state, "failed")
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(result.last_started_test, "RepoPromptTests.S testExample")
        self.assertIn("XCTAssert failed", result.first_failure_line or "")
        self.assertEqual(stopped, [fake])

    def test_nonzero_process_exit_returns_process_status(self) -> None:
        result = ci_app_test_runner.run_suite(
            "RepoPromptTests.S",
            timeout_seconds=1.0,
            silent_timeout_retries=0,
            process_factory=lambda suite: FakeProcess(returncode=7),
            stop_process_tree_func=self.stop_fake_process([]),
            output=io.StringIO(),
            poll_interval_seconds=0.001,
        )

        self.assertEqual(result.state, "failed")
        self.assertEqual(result.exit_code, 7)
        self.assertIsNone(result.first_failure_line)

    def test_timeout_with_output_does_not_retry(self) -> None:
        attempts: list[FakeProcess] = []
        stopped: list[FakeProcess] = []

        def factory(_: str) -> FakeProcess:
            process = FakeProcess(["some XCTest output\n"])
            attempts.append(process)
            return process

        result = ci_app_test_runner.run_suite(
            "RepoPromptTests.S",
            timeout_seconds=0.02,
            silent_timeout_retries=1,
            process_factory=factory,
            stop_process_tree_func=self.stop_fake_process(stopped),
            output=io.StringIO(),
            poll_interval_seconds=0.001,
        )

        self.assertEqual(result.state, "timed_out")
        self.assertEqual(result.exit_code, ci_app_test_runner.TIMEOUT_EXIT_CODE)
        self.assertTrue(result.output_seen)
        self.assertEqual(result.attempts, 1)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(stopped, attempts)

    def test_silent_timeout_retries_once_and_can_pass(self) -> None:
        attempts = [FakeProcess([]), FakeProcess(returncode=0)]
        stopped: list[FakeProcess] = []

        result = ci_app_test_runner.run_suite(
            "RepoPromptTests.S",
            timeout_seconds=0.02,
            silent_timeout_retries=1,
            process_factory=lambda suite: attempts.pop(0),
            stop_process_tree_func=self.stop_fake_process(stopped),
            output=io.StringIO(),
            poll_interval_seconds=0.001,
        )

        self.assertEqual(result.state, "passed")
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.attempts, 2)
        self.assertEqual(len(stopped), 1)


if __name__ == "__main__":
    unittest.main()
