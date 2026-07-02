#!/usr/bin/env python3
"""Unit tests for the hosted CI app-test runner."""

from __future__ import annotations

import io
import time
import unittest
from pathlib import Path
from unittest import mock

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

    def test_silent_startup_timeout_kills_before_full_suite_timeout(self) -> None:
        attempts = [FakeProcess([]), FakeProcess(returncode=0)]
        stopped: list[FakeProcess] = []

        start = time.monotonic()
        result = ci_app_test_runner.run_suite(
            "RepoPromptTests.S",
            timeout_seconds=2.0,
            silent_timeout_retries=1,
            process_factory=lambda suite: attempts.pop(0),
            stop_process_tree_func=self.stop_fake_process(stopped),
            output=io.StringIO(),
            poll_interval_seconds=0.001,
            silent_startup_seconds=0.02,
        )
        elapsed = time.monotonic() - start

        self.assertEqual(result.state, "passed")
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.attempts, 2)
        self.assertEqual(len(stopped), 1)
        # The silent startup timeout (0.02s) must fire well before the full suite
        # timeout (2.0s); otherwise the retry would not happen until the whole budget
        # elapsed.
        self.assertLess(elapsed, 1.0)

    def test_discover_test_bundle_finds_xctest_in_bin_path(self) -> None:
        fake_bin_dir = Path("/fake/.build/arm64-apple-macosx/debug")

        class FakeCompletedProcess:
            def __init__(self, stdout: str) -> None:
                self.stdout = stdout
                self.stderr = ""
                self.returncode = 0

        def fake_run(args, **kwargs):
            if "build" in args and "--show-bin-path" in args:
                return FakeCompletedProcess(str(fake_bin_dir) + "\n")
            raise AssertionError(f"unexpected call: {args}")

        with mock.patch.object(ci_app_test_runner.subprocess, "run", side_effect=fake_run):
            with mock.patch.object(ci_app_test_runner.Path, "is_dir", return_value=True):
                with mock.patch.object(ci_app_test_runner.Path, "glob", return_value=[
                    fake_bin_dir / "RepoPromptCEPackageTests.xctest",
                ]):
                    bundle = ci_app_test_runner.discover_test_bundle("swift", None)

        self.assertEqual(bundle, fake_bin_dir / "RepoPromptCEPackageTests.xctest")

    def test_discover_test_bundle_returns_none_when_bin_path_missing(self) -> None:
        class FakeCompletedProcess:
            def __init__(self, stdout: str) -> None:
                self.stdout = stdout
                self.stderr = ""
                self.returncode = 0

        def fake_run(args, **kwargs):
            return FakeCompletedProcess("/nonexistent/path\n")

        with mock.patch.object(ci_app_test_runner.subprocess, "run", side_effect=fake_run):
            with mock.patch.object(ci_app_test_runner.Path, "is_dir", return_value=False):
                bundle = ci_app_test_runner.discover_test_bundle("swift", None)

        self.assertIsNone(bundle)

    def test_discover_test_bundle_returns_none_on_swift_failure(self) -> None:
        import subprocess as sp

        def fake_run(args, **kwargs):
            raise sp.CalledProcessError(returncode=1, cmd=args)

        with mock.patch.object(ci_app_test_runner.subprocess, "run", side_effect=fake_run):
            bundle = ci_app_test_runner.discover_test_bundle("swift", None)

        self.assertIsNone(bundle)

    def test_create_suite_process_uses_xctest_when_bundle_provided(self) -> None:
        captured_args: list[list[str]] = []

        class FakePopen:
            def __init__(self, args, **kwargs) -> None:
                captured_args.append(args)
                self.pid = -1
                self.stdout = None
                self.returncode = 0

        bundle = Path("/fake/Tests.xctest")
        with mock.patch.object(ci_app_test_runner.subprocess, "Popen", side_effect=FakePopen):
            ci_app_test_runner.create_suite_process(
                "RepoPromptTests.S",
                swift_binary="swift",
                cwd=None,
                test_bundle=bundle,
                xctest_binary=["/usr/bin/xctest"],
            )

        self.assertEqual(len(captured_args), 1)
        self.assertEqual(captured_args[0], ["/usr/bin/xctest", "-XCTest", "RepoPromptTests.S", str(bundle)])

    def test_create_suite_process_xctest_fallback_uses_xcrun_xctest_prefix(self) -> None:
        captured_args: list[list[str]] = []

        class FakePopen:
            def __init__(self, args, **kwargs) -> None:
                captured_args.append(args)
                self.pid = -1
                self.stdout = None
                self.returncode = 0

        bundle = Path("/fake/Tests.xctest")
        with mock.patch.object(ci_app_test_runner.subprocess, "Popen", side_effect=FakePopen):
            ci_app_test_runner.create_suite_process(
                "RepoPromptTests.S",
                swift_binary="swift",
                cwd=None,
                test_bundle=bundle,
                xctest_binary=["xcrun", "xctest"],
            )

        self.assertEqual(len(captured_args), 1)
        self.assertEqual(
            captured_args[0],
            ["xcrun", "xctest", "-XCTest", "RepoPromptTests.S", str(bundle)],
        )

    def test_xctest_binary_path_returns_resolved_path_as_single_element_list(self) -> None:
        class FakeCompletedProcess:
            def __init__(self, stdout: str) -> None:
                self.stdout = stdout
                self.stderr = ""
                self.returncode = 0

        with mock.patch.object(
            ci_app_test_runner.subprocess,
            "run",
            return_value=FakeCompletedProcess("/usr/bin/xctest\n"),
        ):
            result = ci_app_test_runner.xctest_binary_path()

        self.assertEqual(result, ["/usr/bin/xctest"])

    def test_xctest_binary_path_falls_back_to_xcrun_xctest_prefix(self) -> None:
        import subprocess as sp

        def fake_run(args, **kwargs):
            raise sp.CalledProcessError(returncode=1, cmd=args)

        with mock.patch.object(ci_app_test_runner.subprocess, "run", side_effect=fake_run):
            result = ci_app_test_runner.xctest_binary_path()

        self.assertEqual(result, ["xcrun", "xctest"])

    def test_discover_test_bundle_fails_when_multiple_bundles_found(self) -> None:
        fake_bin_dir = Path("/fake/.build/arm64-apple-macosx/debug")

        class FakeCompletedProcess:
            def __init__(self, stdout: str) -> None:
                self.stdout = stdout
                self.stderr = ""
                self.returncode = 0

        def fake_run(args, **kwargs):
            if "build" in args and "--show-bin-path" in args:
                return FakeCompletedProcess(str(fake_bin_dir) + "\n")
            raise AssertionError(f"unexpected call: {args}")

        with mock.patch.object(ci_app_test_runner.subprocess, "run", side_effect=fake_run):
            with mock.patch.object(ci_app_test_runner.Path, "is_dir", return_value=True):
                with mock.patch.object(ci_app_test_runner.Path, "glob", return_value=[
                    fake_bin_dir / "RepoPromptCEPackageTests.xctest",
                    fake_bin_dir / "OtherTests.xctest",
                ]):
                    with self.assertRaises(ValueError):
                        ci_app_test_runner.discover_test_bundle("swift", None)

    def test_create_suite_process_falls_back_to_swift_test_without_bundle(self) -> None:
        captured_args: list[list[str]] = []

        class FakePopen:
            def __init__(self, args, **kwargs) -> None:
                captured_args.append(args)
                self.pid = -1
                self.stdout = None
                self.returncode = 0

        with mock.patch.object(ci_app_test_runner.subprocess, "Popen", side_effect=FakePopen):
            ci_app_test_runner.create_suite_process(
                "RepoPromptTests.S",
                swift_binary="swift",
                cwd=None,
            )

        self.assertEqual(len(captured_args), 1)
        self.assertEqual(captured_args[0], ["swift", "test", "--skip-build", "--filter", "RepoPromptTests.S"])


if __name__ == "__main__":
    unittest.main()
