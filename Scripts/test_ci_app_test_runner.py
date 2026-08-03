#!/usr/bin/env python3
"""Unit tests for the hosted CI app-test runner."""

from __future__ import annotations

import io
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import ci_app_test_runner


class FakeProcess:
    next_pid = 1000

    def __init__(
        self,
        lines: list[str] | None = None,
        *,
        returncode: int | None = None,
        returncode_after_output: int | None = None,
    ) -> None:
        self.lines = lines or []
        self.returncode = returncode
        self.returncode_after_output = returncode_after_output
        self.pid = FakeProcess.next_pid
        FakeProcess.next_pid += 1
        self.stdout = self.iter_lines()
        self.kill_called = False
        self.wait_called = False

    def iter_lines(self):
        yield from self.lines
        if self.returncode_after_output is not None:
            self.returncode = self.returncode_after_output

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

    def test_parse_suite_method_counts_returns_unique_sorted_counts(self) -> None:
        output = "\n".join(
            [
                "RepoPromptTests.B/testTwo",
                "RepoPromptTests.A/testOne",
                "RepoPromptTests.B/testThree",
                "RepoPromptTests.B/testTwo",
                "noise without slash",
                "RepoPromptTests.Empty/",
                "",
            ]
        )

        self.assertEqual(
            ci_app_test_runner.parse_suite_method_counts(output),
            {
                "RepoPromptTests.A": 1,
                "RepoPromptTests.B": 2,
            },
        )

        self.assertEqual(
            ci_app_test_runner.parse_suite_methods(output),
            {
                "RepoPromptTests.A": ("RepoPromptTests.A/testOne",),
                "RepoPromptTests.B": (
                    "RepoPromptTests.B/testThree",
                    "RepoPromptTests.B/testTwo",
                ),
            },
        )

    def test_lpt_sharding_is_deterministic_with_stable_name_ties(self) -> None:
        method_counts = {
            "RepoPromptTests.E": 1,
            "RepoPromptTests.D": 2,
            "RepoPromptTests.C": 3,
            "RepoPromptTests.B": 5,
            "RepoPromptTests.A": 5,
        }

        first = ci_app_test_runner.assign_suites_to_shards(method_counts, 3)
        second = ci_app_test_runner.assign_suites_to_shards(dict(reversed(list(method_counts.items()))), 3)

        self.assertEqual(first, second)
        self.assertEqual(
            first,
            (
                [["RepoPromptTests.A", "RepoPromptTests.E"], ["RepoPromptTests.B"], ["RepoPromptTests.C", "RepoPromptTests.D"]],
                [6, 5, 5],
            ),
        )

    def test_four_lpt_shards_are_disjoint_and_cover_every_discovered_suite(self) -> None:
        method_counts = {
            f"RepoPromptTests.Suite{index:02d}": (index % 5) + 1
            for index in range(17)
        }

        shards, loads = ci_app_test_runner.assign_suites_to_shards(method_counts, 4)
        flattened = [suite for shard in shards for suite in shard]

        self.assertEqual(len(shards), 4)
        self.assertEqual(len(loads), 4)
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertEqual(set(flattened), set(method_counts))
        self.assertEqual(sum(loads), sum(method_counts.values()))

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

    def test_xctest_assertion_does_not_stop_suite_process_early(self) -> None:
        stopped: list[FakeProcess] = []
        output = io.StringIO()
        fake = FakeProcess(
            [
                "Test Case '-[RepoPromptTests.S testExample]' started.\n",
                "/tmp/File.swift:10: error: -[RepoPromptTests.S testExample] : XCTAssert failed\n",
                "Test Case '-[RepoPromptTests.S testLater]' started.\n",
                "/tmp/File.swift:20: error: -[RepoPromptTests.S testLater] : XCTAssertEqual failed\n",
            ],
            returncode_after_output=1,
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
        self.assertEqual(result.last_started_test, "RepoPromptTests.S testLater")
        self.assertIn("XCTAssert failed", result.first_failure_line or "")
        self.assertIn("XCTAssertEqual failed", output.getvalue())
        self.assertEqual(stopped, [])

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

    def test_cancellation_event_stops_running_suite_process(self) -> None:
        stopped: list[FakeProcess] = []
        cancellation = threading.Event()
        process = FakeProcess(["Test Case '-[RepoPromptTests.S testExample]' started.\n"])
        timer = threading.Timer(0.02, cancellation.set)
        timer.start()
        try:
            result = ci_app_test_runner.run_suite(
                "RepoPromptTests.S",
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                process_factory=lambda suite: process,
                stop_process_tree_func=self.stop_fake_process(stopped),
                output=io.StringIO(),
                poll_interval_seconds=0.001,
                cancellation_event=cancellation,
            )
        finally:
            timer.cancel()

        self.assertEqual(result.state, "cancelled")
        self.assertEqual(result.exit_code, 130)
        self.assertEqual(stopped, [process])

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

    def test_discover_test_bundles_returns_map_by_test_target_name(self) -> None:
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
                    fake_bin_dir / "RepoPromptTests.xctest",
                    fake_bin_dir / "RepoPromptWorkspaceTests.xctest",
                ]):
                    bundles = ci_app_test_runner.discover_test_bundles("swift", None)

        self.assertEqual(
            bundles,
            {
                "RepoPromptTests": fake_bin_dir / "RepoPromptTests.xctest",
                "RepoPromptWorkspaceTests": fake_bin_dir / "RepoPromptWorkspaceTests.xctest",
            },
        )

    def test_bundle_for_suite_selects_matching_test_target(self) -> None:
        bundles = {
            "RepoPromptTests": Path("/fake/RepoPromptTests.xctest"),
            "RepoPromptWorkspaceTests": Path("/fake/RepoPromptWorkspaceTests.xctest"),
        }

        self.assertEqual(
            ci_app_test_runner.bundle_for_suite("RepoPromptWorkspaceTests.WorkspaceTests", bundles),
            Path("/fake/RepoPromptWorkspaceTests.xctest"),
        )
        self.assertIsNone(ci_app_test_runner.bundle_for_suite("MissingTarget.Tests", bundles))

    def test_target_bundles_for_suites_ignores_stale_bundles_when_targets_covered(self) -> None:
        bundles = {
            "RepoPromptTests": Path("/fake/RepoPromptTests.xctest"),
            "RepoPromptCEPackageTests": Path("/fake/RepoPromptCEPackageTests.xctest"),
            "StaleTests": Path("/fake/StaleTests.xctest"),
        }

        self.assertEqual(
            ci_app_test_runner.target_bundles_for_suites(
                bundles,
                ["RepoPromptTests.A", "RepoPromptTests.B"],
            ),
            {"RepoPromptTests": Path("/fake/RepoPromptTests.xctest")},
        )

    def test_package_test_bundle_selects_unambiguous_combined_swiftpm_bundle(self) -> None:
        bundle = Path("/fake/RepoPromptCEPackageTests.xctest")
        self.assertEqual(
            ci_app_test_runner.package_test_bundle({
                "RepoPromptCEPackageTests": bundle,
                "StaleTests": Path("/fake/StaleTests.xctest"),
            }),
            bundle,
        )
        self.assertIsNone(ci_app_test_runner.package_test_bundle({
            "OnePackageTests": Path("/fake/OnePackageTests.xctest"),
            "TwoPackageTests": Path("/fake/TwoPackageTests.xctest"),
        }))

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

    def test_discover_test_bundle_selects_exact_requested_bundle_name(self) -> None:
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
                    fake_bin_dir / "RepoPromptTests.xctest",
                    fake_bin_dir / "RepoPromptWorkspaceTests.xctest",
                ]):
                    bundle = ci_app_test_runner.discover_test_bundle(
                        "swift",
                        None,
                        "RepoPromptWorkspaceTests",
                    )

        self.assertEqual(bundle, fake_bin_dir / "RepoPromptWorkspaceTests.xctest")

    def test_discover_test_bundle_returns_none_when_requested_bundle_missing(self) -> None:
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
                    fake_bin_dir / "RepoPromptTests.xctest",
                ]):
                    bundle = ci_app_test_runner.discover_test_bundle(
                        "swift",
                        None,
                        "RepoPromptWorkspaceTests.xctest",
                    )

        self.assertIsNone(bundle)

    def test_run_all_suites_uses_bundle_matching_each_suite_target(self) -> None:
        selected: list[tuple[str, Path | None]] = []

        def fake_create_suite_process(suite, **kwargs):
            selected.append((suite, kwargs["test_bundle"]))
            return FakeProcess(returncode=0)

        output = io.StringIO()
        with mock.patch.object(
            ci_app_test_runner,
            "create_suite_process",
            side_effect=fake_create_suite_process,
        ):
            exit_code = ci_app_test_runner.run_all_suites(
                [
                    "RepoPromptTests.ModelPickerStringOrderingTests",
                    "RepoPromptWorkspaceTests.WorkspaceCodemapBindingEngineTests",
                ],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
                test_bundles={
                    "RepoPromptTests": Path("/fake/RepoPromptTests.xctest"),
                    "RepoPromptWorkspaceTests": Path("/fake/RepoPromptWorkspaceTests.xctest"),
                },
                xctest_binary=["/usr/bin/xctest"],
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            selected,
            [
                ("RepoPromptTests.ModelPickerStringOrderingTests", Path("/fake/RepoPromptTests.xctest")),
                (
                    "RepoPromptWorkspaceTests.WorkspaceCodemapBindingEngineTests",
                    Path("/fake/RepoPromptWorkspaceTests.xctest"),
                ),
            ],
        )
        self.assertIn("Using xcrun xctest bundles by suite target", output.getvalue())

    def test_run_all_suites_fails_when_bundle_map_lacks_suite_target(self) -> None:
        output = io.StringIO()
        exit_code = ci_app_test_runner.run_all_suites(
            ["UnknownTarget.SomeTests"],
            timeout_seconds=1.0,
            silent_timeout_retries=0,
            swift_binary="swift",
            cwd=None,
            output=output,
            test_bundles={
                "RepoPromptTests": Path("/fake/RepoPromptTests.xctest"),
            },
            xctest_binary=["/usr/bin/xctest"],
        )

        self.assertEqual(exit_code, 1)
        self.assertIn("No XCTest bundle found for suite target UnknownTarget", output.getvalue())

    def test_run_all_suites_preserves_deterministic_serial_order(self) -> None:
        calls: list[str] = []

        def fake_run_suite(suite, **kwargs):
            calls.append(suite)
            return ci_app_test_runner.SuiteRunResult(
                suite=suite,
                state="passed",
                exit_code=0,
                elapsed_seconds=0.1,
                output_seen=True,
                first_failure_line=None,
                last_started_test=None,
                timed_out_after_seconds=None,
                attempts=1,
            )

        output = io.StringIO()
        with mock.patch.object(ci_app_test_runner, "run_suite", side_effect=fake_run_suite):
            exit_code = ci_app_test_runner.run_all_suites(
                ["RepoPromptTests.B", "RepoPromptTests.A"],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(calls, ["RepoPromptTests.A", "RepoPromptTests.B"])

    def test_run_all_suites_method_isolates_process_global_smoke_suite(self) -> None:
        calls: list[str] = []

        def fake_run_suite(suite, **kwargs):
            calls.append(suite)
            return ci_app_test_runner.SuiteRunResult(
                suite=suite,
                state="passed",
                exit_code=0,
                elapsed_seconds=0.1,
                output_seen=True,
                first_failure_line=None,
                last_started_test=None,
                timed_out_after_seconds=None,
                attempts=1,
            )

        suite = "RepoPromptTests.WorktreeAPISmokeHarnessTests"
        methods = (
            f"{suite}/testContextBuilderExport",
            f"{suite}/testManageWorktreeAndAgentRun",
        )
        output = io.StringIO()
        with mock.patch.object(ci_app_test_runner, "run_suite", side_effect=fake_run_suite):
            exit_code = ci_app_test_runner.run_all_suites(
                [suite],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
                method_counts={suite: len(methods)},
                suite_methods={suite: methods},
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(calls, list(methods))
        self.assertIn("Method-isolating", output.getvalue())

    def test_run_all_suites_collects_failures_and_continues(self) -> None:
        calls: list[str] = []

        def fake_run_suite(suite, **kwargs):
            calls.append(suite)
            if suite == "RepoPromptTests.A":
                return ci_app_test_runner.SuiteRunResult(
                    suite=suite,
                    state="failed",
                    exit_code=1,
                    elapsed_seconds=0.1,
                    output_seen=True,
                    first_failure_line="A failed",
                    last_started_test="RepoPromptTests.A testFailure",
                    timed_out_after_seconds=None,
                    attempts=1,
                )
            if suite == "RepoPromptTests.C":
                return ci_app_test_runner.SuiteRunResult(
                    suite=suite,
                    state="timed_out",
                    exit_code=ci_app_test_runner.TIMEOUT_EXIT_CODE,
                    elapsed_seconds=1.0,
                    output_seen=True,
                    first_failure_line=None,
                    last_started_test="RepoPromptTests.C testTimeout",
                    timed_out_after_seconds=1.0,
                    attempts=1,
                )
            return ci_app_test_runner.SuiteRunResult(
                suite=suite,
                state="passed",
                exit_code=0,
                elapsed_seconds=0.2,
                output_seen=True,
                first_failure_line=None,
                last_started_test=None,
                timed_out_after_seconds=None,
                attempts=1,
            )

        output = io.StringIO()
        with mock.patch.object(ci_app_test_runner, "run_suite", side_effect=fake_run_suite):
            exit_code = ci_app_test_runner.run_all_suites(
                ["RepoPromptTests.C", "RepoPromptTests.B", "RepoPromptTests.A"],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
            )

        self.assertEqual(exit_code, 1)
        self.assertEqual(
            calls,
            ["RepoPromptTests.A", "RepoPromptTests.B", "RepoPromptTests.C"],
        )
        summary = output.getvalue().split("Failed app test suites:\n", 1)[1]
        self.assertIn("2 failed suite(s)", output.getvalue())
        self.assertIn("RepoPromptTests.A: failed", summary)
        self.assertIn("RepoPromptTests.C: timed_out", summary)

    def test_run_all_suites_executes_only_the_selected_lpt_shard(self) -> None:
        calls: list[str] = []

        def fake_run_suite(suite, **kwargs):
            calls.append(suite)
            return ci_app_test_runner.SuiteRunResult(
                suite=suite,
                state="passed",
                exit_code=0,
                elapsed_seconds=0.1,
                output_seen=True,
                first_failure_line=None,
                last_started_test=None,
                timed_out_after_seconds=None,
                attempts=1,
            )

        method_counts = {
            "RepoPromptTests.A": 8,
            "RepoPromptTests.B": 5,
            "RepoPromptTests.C": 3,
            "RepoPromptTests.D": 2,
        }
        expected, _ = ci_app_test_runner.select_shard(
            method_counts,
            shard_count=2,
            shard_index=2,
        )
        with mock.patch.object(ci_app_test_runner, "run_suite", side_effect=fake_run_suite):
            exit_code = ci_app_test_runner.run_all_suites(
                method_counts,
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=io.StringIO(),
                method_counts=method_counts,
                shard_count=2,
                shard_index=2,
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(calls, expected)

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

    def test_main_routes_discovered_multiple_bundles_without_explicit_name(self) -> None:
        captured: dict[str, object] = {}

        def fake_run_all_suites(suites, **kwargs):
            captured["suites"] = list(suites)
            captured["test_bundle"] = kwargs["test_bundle"]
            captured["test_bundles"] = kwargs["test_bundles"]
            captured["xctest_binary"] = kwargs["xctest_binary"]
            return 0

        bundles = {
            "RepoPromptTests": Path("/fake/RepoPromptTests.xctest"),
            "RepoPromptWorkspaceTests": Path("/fake/RepoPromptWorkspaceTests.xctest"),
        }
        with (
            mock.patch.object(
                ci_app_test_runner,
                "list_suite_methods",
                return_value={
                    "RepoPromptTests.A": ("RepoPromptTests.A/testOne",),
                    "RepoPromptWorkspaceTests.B": ("RepoPromptWorkspaceTests.B/testOne",),
                },
            ),
            mock.patch.object(ci_app_test_runner, "discover_test_bundles", return_value=bundles),
            mock.patch.object(ci_app_test_runner, "xctest_binary_path", return_value=["/usr/bin/xctest"]),
            mock.patch.object(ci_app_test_runner, "run_all_suites", side_effect=fake_run_all_suites),
        ):
            exit_code = ci_app_test_runner.main([])

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured["suites"], ["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"])
        self.assertIsNone(captured["test_bundle"])
        self.assertEqual(captured["test_bundles"], bundles)
        self.assertEqual(captured["xctest_binary"], ["/usr/bin/xctest"])

    def test_main_prefers_combined_package_bundle_when_cache_contains_stale_bundle(self) -> None:
        captured: dict[str, object] = {}

        def fake_run_all_suites(suites, **kwargs):
            captured["suites"] = list(suites)
            captured["test_bundle"] = kwargs["test_bundle"]
            captured["test_bundles"] = kwargs["test_bundles"]
            captured["xctest_binary"] = kwargs["xctest_binary"]
            return 0

        with (
            mock.patch.object(
                ci_app_test_runner,
                "list_suite_methods",
                return_value={
                    "RepoPromptTests.A": ("RepoPromptTests.A/testOne",),
                    "RepoPromptWorkspaceTests.B": ("RepoPromptWorkspaceTests.B/testOne",),
                },
            ),
            mock.patch.object(
                ci_app_test_runner,
                "discover_test_bundles",
                return_value={
                    "RepoPromptCEPackageTests": Path("/fake/RepoPromptCEPackageTests.xctest"),
                    "RepoPromptTests": Path("/fake/stale/RepoPromptTests.xctest"),
                    "RepoPromptWorkspaceTests": Path("/fake/stale/RepoPromptWorkspaceTests.xctest"),
                    "StaleTests": Path("/fake/StaleTests.xctest"),
                },
            ),
            mock.patch.object(ci_app_test_runner, "xctest_binary_path", return_value=["/usr/bin/xctest"]),
            mock.patch.object(ci_app_test_runner, "run_all_suites", side_effect=fake_run_all_suites),
        ):
            exit_code = ci_app_test_runner.main([])

        self.assertEqual(exit_code, 0)
        self.assertEqual(captured["suites"], ["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"])
        self.assertEqual(
            captured["test_bundle"], Path("/fake/RepoPromptCEPackageTests.xctest")
        )
        self.assertIsNone(captured["test_bundles"])
        self.assertEqual(captured["xctest_binary"], ["/usr/bin/xctest"])

    def test_main_uses_single_discovered_bundle_for_all_suite_targets(self) -> None:
        # SwiftPM emits one combined ``<PackageName>PackageTests.xctest`` bundle
        # whose name does not match any individual test target, so a single
        # discovered bundle must be used for every suite regardless of name.
        captured: dict[str, object] = {}

        def fake_run_all_suites(suites, **kwargs):
            captured["suites"] = list(suites)
            captured["test_bundle"] = kwargs["test_bundle"]
            captured["test_bundles"] = kwargs["test_bundles"]
            captured["xctest_binary"] = kwargs["xctest_binary"]
            return 0

        with (
            mock.patch.object(
                ci_app_test_runner,
                "list_suite_methods",
                return_value={
                    "RepoPromptTests.A": ("RepoPromptTests.A/testOne",),
                    "RepoPromptWorkspaceTests.B": ("RepoPromptWorkspaceTests.B/testOne",),
                },
            ),
            mock.patch.object(
                ci_app_test_runner,
                "discover_test_bundles",
                return_value={"RepoPromptCEPackageTests": Path("/fake/RepoPromptCEPackageTests.xctest")},
            ),
            mock.patch.object(ci_app_test_runner, "xctest_binary_path", return_value=["/usr/bin/xctest"]),
            mock.patch.object(ci_app_test_runner, "run_all_suites", side_effect=fake_run_all_suites),
        ):
            exit_code = ci_app_test_runner.main([])

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            captured["suites"], ["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"]
        )
        self.assertEqual(
            captured["test_bundle"], Path("/fake/RepoPromptCEPackageTests.xctest")
        )
        self.assertIsNone(captured["test_bundles"])
        self.assertEqual(captured["xctest_binary"], ["/usr/bin/xctest"])

    def test_main_rejects_bundle_name_when_list_contains_other_targets(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(
                ci_app_test_runner,
                "list_suite_methods",
                return_value={
                    "RepoPromptTests.A": ("RepoPromptTests.A/testOne",),
                    "RepoPromptWorkspaceTests.B": ("RepoPromptWorkspaceTests.B/testOne",),
                },
            ),
            mock.patch("sys.stdout", output),
        ):
            exit_code = ci_app_test_runner.main(["--test-bundle-name", "RepoPromptTests"])

        self.assertEqual(exit_code, 1)
        self.assertIn("cannot run suites from other targets", output.getvalue())

    def test_main_rejects_missing_explicit_bundle_name(self) -> None:
        output = io.StringIO()
        with (
            mock.patch.object(
                ci_app_test_runner,
                "list_suite_methods",
                return_value={"RepoPromptWorkspaceTests.A": ("RepoPromptWorkspaceTests.A/testOne",)},
            ),
            mock.patch.object(ci_app_test_runner, "discover_test_bundle", return_value=None),
            mock.patch.object(ci_app_test_runner, "run_all_suites") as run_all_suites,
            mock.patch("sys.stdout", output),
        ):
            exit_code = ci_app_test_runner.main(["--test-bundle-name", "RepoPromptWorkspaceTests"])

        self.assertEqual(exit_code, 1)
        self.assertIn("did not match any built XCTest bundle", output.getvalue())
        run_all_suites.assert_not_called()



if __name__ == "__main__":
    unittest.main()
