#!/usr/bin/env python3
"""Unit tests for the hosted CI app-test runner."""

from __future__ import annotations

import io
import json
import tempfile
import threading
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
    def write_policy(self, directory: Path, groups: dict[str, dict[str, str]] | None = None) -> Path:
        path = directory / "policy.json"
        path.write_text(
            json.dumps(
                {
                    "version": 1,
                    "default_mode": "parallel_eligible",
                    "groups": groups
                    or {
                        "WindowStatesManager": {
                            "lane": "app_window_state",
                            "reason": "shared windows",
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        return path

    def write_ledger(self, directory: Path, rows: list[dict[str, str]]) -> Path:
        path = directory / "ledger.tsv"
        columns = [
            "method_id",
            "target",
            "file",
            "suite",
            "method",
            "domain",
            "primary_contract_id",
            "secondary_contract_tags",
            "validation_class",
            "layer",
            "execution_tier",
            "scenario_count",
            "fixture_ids",
            "observable_oracle",
            "failure_risk",
            "runtime_seconds",
            "resource_cost_tags",
            "shared_state_tags",
            "lifecycle_owner",
            "current_disposition",
            "replacement_method_id",
            "preserved_scenario_delta",
            "notes",
        ]
        with path.open("w", encoding="utf-8", newline="") as handle:
            handle.write("\t".join(columns) + "\n")
            for row in rows:
                values = {column: "" for column in columns}
                values.update(row)
                handle.write("\t".join(values[column] for column in columns) + "\n")
        return path

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

    def test_serial_group_policy_accepts_valid_config(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = self.write_policy(Path(temp))

            policy = ci_app_test_runner.load_serial_group_policy(path)

        self.assertEqual(policy["WindowStatesManager"].lane, "app_window_state")

    def test_serial_group_policy_rejects_unknown_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "policy.json"
            path.write_text(
                json.dumps({"version": 99, "default_mode": "parallel_eligible", "groups": {}}),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "unsupported serial group policy version"):
                ci_app_test_runner.load_serial_group_policy(path)

    def test_serial_group_policy_rejects_malformed_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "policy.json"
            path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "default_mode": "parallel_eligible",
                        "groups": {"WindowStatesManager": {"lane": "app_window_state"}},
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "must define a non-empty reason"):
                ci_app_test_runner.load_serial_group_policy(path)

    def test_ledger_aggregation_classifies_suites_by_serial_policy_tags(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ledger = self.write_ledger(
                root,
                [
                    {
                        "method_id": "root/RepoPromptTests.A/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.A",
                        "method": "testOne",
                        "execution_tier": "routine",
                        "runtime_seconds": "1.5",
                        "shared_state_tags": "WindowStatesManager;GlobalSettingsStore",
                        "resource_cost_tags": "temp_directory;git_subprocess",
                    },
                    {
                        "method_id": "root/RepoPromptTests.A/testTwo",
                        "target": "root",
                        "suite": "RepoPromptTests.A",
                        "method": "testTwo",
                        "execution_tier": "diagnostic",
                        "runtime_seconds": "2.0",
                        "shared_state_tags": "WindowStatesManager",
                    },
                    {
                        "method_id": "root/RepoPromptTests.B/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.B",
                        "method": "testOne",
                        "execution_tier": "routine",
                        "runtime_seconds": "0.5",
                        "resource_cost_tags": "UserDefaults.standard",
                    },
                ],
            )
            policy = self.write_policy(
                root,
                {
                    "WindowStatesManager": {
                        "lane": "app_window_state",
                        "reason": "shared windows",
                    },
                    "UserDefaults.standard": {
                        "lane": "user_defaults",
                        "reason": "shared defaults",
                    },
                },
            )

            plan = ci_app_test_runner.build_suite_plan(
                ["RepoPromptTests.B", "RepoPromptTests.A"],
                ledger_suites=ci_app_test_runner.read_ledger_suites(ledger),
                serial_policy=ci_app_test_runner.load_serial_group_policy(policy),
            )

        self.assertEqual(
            [suite.suite for suite in plan.pinned_serial],
            ["RepoPromptTests.A", "RepoPromptTests.B"],
        )
        self.assertEqual([suite.suite for suite in plan.parallel_eligible], [])
        self.assertEqual(plan.pinned_serial[0].estimated_runtime_seconds, 3.5)
        self.assertTrue(plan.pinned_serial[0].heavy_tier_present)
        self.assertEqual(plan.pinned_serial[1].matched_serial_tags, ("UserDefaults.standard",))

    def test_main_print_suite_plan_json_emits_stable_groups(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ledger = self.write_ledger(
                root,
                [
                    {
                        "method_id": "root/RepoPromptTests.Pinned/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.Pinned",
                        "method": "testOne",
                        "execution_tier": "routine",
                        "shared_state_tags": "WindowStatesManager",
                    },
                    {
                        "method_id": "root/RepoPromptTests.Free/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.Free",
                        "method": "testOne",
                        "execution_tier": "routine",
                    },
                ],
            )
            policy = self.write_policy(root)
            output = io.StringIO()

            with (
                mock.patch.object(
                    ci_app_test_runner,
                    "list_suites",
                    return_value=["RepoPromptTests.Pinned", "RepoPromptTests.Free"],
                ),
                mock.patch("sys.stdout", output),
            ):
                exit_code = ci_app_test_runner.main(
                    [
                        "--ledger",
                        str(ledger),
                        "--serial-group-policy",
                        str(policy),
                        "--print-suite-plan-json",
                    ]
                )

        self.assertEqual(exit_code, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(
            [suite["suite"] for suite in payload["pinned_serial"]],
            ["RepoPromptTests.Pinned"],
        )
        self.assertEqual(
            [suite["suite"] for suite in payload["parallel_eligible"]],
            ["RepoPromptTests.Free"],
        )

    def test_main_reports_missing_ledger_file(self) -> None:
        output = io.StringIO()
        with (
            tempfile.TemporaryDirectory() as temp,
            mock.patch.object(ci_app_test_runner, "list_suites", return_value=["RepoPromptTests.A"]),
            mock.patch("sys.stdout", output),
        ):
            policy = self.write_policy(Path(temp))
            exit_code = ci_app_test_runner.main(
                [
                    "--ledger",
                    str(Path(temp) / "missing.tsv"),
                    "--serial-group-policy",
                    str(policy),
                    "--print-suite-plan-json",
                ]
            )

        self.assertEqual(exit_code, 1)
        self.assertIn("ledger file does not exist", output.getvalue())

    def test_main_reports_missing_serial_group_policy_file(self) -> None:
        output = io.StringIO()
        with (
            tempfile.TemporaryDirectory() as temp,
            mock.patch.object(ci_app_test_runner, "list_suites", return_value=["RepoPromptTests.A"]),
            mock.patch("sys.stdout", output),
        ):
            ledger = self.write_ledger(
                Path(temp),
                [
                    {
                        "method_id": "root/RepoPromptTests.A/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.A",
                        "method": "testOne",
                        "execution_tier": "routine",
                    },
                ],
            )
            exit_code = ci_app_test_runner.main(
                [
                    "--ledger",
                    str(ledger),
                    "--serial-group-policy",
                    str(Path(temp) / "missing.json"),
                    "--print-suite-plan-json",
                ]
            )

        self.assertEqual(exit_code, 1)
        self.assertIn("serial group policy file does not exist", output.getvalue())

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

    def test_workers_one_preserves_current_serial_execution_order(self) -> None:
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
                workers=1,
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(calls, ["RepoPromptTests.A", "RepoPromptTests.B"])

    def test_workers_never_schedule_pinned_suites_in_worker_pool(self) -> None:
        pinned = ci_app_test_runner.PlannedSuite(
            suite="RepoPromptTests.Pinned",
            classification="pinned_serial",
            serial_lanes=("app_window_state",),
            matched_serial_tags=("WindowStatesManager",),
            shared_state_tags=("WindowStatesManager",),
            resource_cost_tags=(),
            execution_tiers=("routine",),
            estimated_runtime_seconds=1.0,
            method_count=1,
            heavy_tier_present=False,
        )
        eligible = ci_app_test_runner.PlannedSuite(
            suite="RepoPromptTests.Free",
            classification="parallel_eligible",
            serial_lanes=(),
            matched_serial_tags=(),
            shared_state_tags=(),
            resource_cost_tags=(),
            execution_tiers=("routine",),
            estimated_runtime_seconds=1.0,
            method_count=1,
            heavy_tier_present=False,
        )
        buffered_calls: list[str] = []
        direct_calls: list[str] = []

        def fake_buffered(group, **kwargs):
            buffered_calls.append(group.label)
            return (
                ci_app_test_runner.SuiteRunResult(
                    suite=group.label,
                    state="passed",
                    exit_code=0,
                    elapsed_seconds=0.2,
                    output_seen=True,
                    first_failure_line=None,
                    last_started_test=None,
                    timed_out_after_seconds=None,
                    attempts=1,
                ),
                f"{group.label} buffered\n",
            )

        def fake_direct(group, **kwargs):
            direct_calls.append(group.label)
            return ci_app_test_runner.SuiteRunResult(
                suite=group.label,
                state="passed",
                exit_code=0,
                elapsed_seconds=0.1,
                output_seen=True,
                first_failure_line=None,
                last_started_test=None,
                timed_out_after_seconds=None,
                attempts=1,
            )

        with (
            mock.patch.object(ci_app_test_runner, "run_suite_buffered", side_effect=fake_buffered),
            mock.patch.object(
                ci_app_test_runner,
                "run_suite_group_and_report",
                side_effect=fake_direct,
            ),
        ):
            exit_code = ci_app_test_runner.run_all_suites(
                ["RepoPromptTests.Pinned", "RepoPromptTests.Free"],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=io.StringIO(),
                suite_plan=ci_app_test_runner.SuitePlan((eligible, pinned)),
                workers=2,
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(direct_calls, ["RepoPromptTests.Pinned"])
        self.assertEqual(buffered_calls, ["RepoPromptTests.Free"])

    def test_parallel_fail_fast_stops_submitting_new_eligible_work(self) -> None:
        suites = [
            ci_app_test_runner.PlannedSuite(
                suite=name,
                classification="parallel_eligible",
                serial_lanes=(),
                matched_serial_tags=(),
                shared_state_tags=(),
                resource_cost_tags=(),
                execution_tiers=("routine",),
                estimated_runtime_seconds=1.0,
                method_count=1,
                heavy_tier_present=False,
            )
            for name in ["RepoPromptTests.AFail", "RepoPromptTests.BNotSubmitted", "RepoPromptTests.CAlsoNotSubmitted"]
        ]
        calls: list[str] = []

        def fake_buffered(group, **kwargs):
            calls.append(group.label)
            state = "failed" if group.label == "RepoPromptTests.AFail" else "passed"
            return (
                ci_app_test_runner.SuiteRunResult(
                    suite=group.label,
                    state=state,
                    exit_code=7 if state == "failed" else 0,
                    elapsed_seconds=0.1,
                    output_seen=True,
                    first_failure_line=None,
                    last_started_test=None,
                    timed_out_after_seconds=None,
                    attempts=1,
                ),
                f"{group.label} {state}\n",
            )

        with mock.patch.object(ci_app_test_runner, "run_suite_buffered", side_effect=fake_buffered):
            exit_code = ci_app_test_runner.run_all_suites(
                [suite.suite for suite in suites],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=io.StringIO(),
                suite_plan=ci_app_test_runner.SuitePlan(tuple(suites)),
                workers=1 + 1,
            )

        self.assertEqual(exit_code, 7)
        self.assertIn("RepoPromptTests.AFail", calls)
        self.assertNotIn("RepoPromptTests.CAlsoNotSubmitted", calls)

    def test_parallel_fail_fast_ignores_cancelled_peers_for_first_failure(self) -> None:
        """Cancelled worker results must not steal first_failure / exit code.

        When workers>1, peers observe the cancellation event and return
        state=cancelled with exit 130. Those results can land in the same
        futures batch as the real failure and sort first by group label.
        Attribution must stay with the non-cancelled failure.
        """
        suites = [
            ci_app_test_runner.PlannedSuite(
                suite=name,
                classification="parallel_eligible",
                serial_lanes=(),
                matched_serial_tags=(),
                shared_state_tags=(),
                resource_cost_tags=(),
                execution_tiers=("routine",),
                estimated_runtime_seconds=1.0,
                method_count=1,
                heavy_tier_present=False,
            )
            for name in ["RepoPromptTests.APeer", "RepoPromptTests.ZFail"]
        ]

        def fake_buffered(group, **kwargs):
            if group.label == "RepoPromptTests.ZFail":
                return (
                    ci_app_test_runner.SuiteRunResult(
                        suite=group.label,
                        state="failed",
                        exit_code=7,
                        elapsed_seconds=0.1,
                        output_seen=True,
                        first_failure_line="XCTAssert failed: real failure",
                        last_started_test=None,
                        timed_out_after_seconds=None,
                        attempts=1,
                    ),
                    f"{group.label} failed\n",
                )
            # Peer cancelled due to fail-fast; label sorts before ZFail.
            return (
                ci_app_test_runner.SuiteRunResult(
                    suite=group.label,
                    state="cancelled",
                    exit_code=130,
                    elapsed_seconds=0.05,
                    output_seen=True,
                    first_failure_line=None,
                    last_started_test=None,
                    timed_out_after_seconds=None,
                    attempts=1,
                ),
                f"{group.label} cancelled\n",
            )

        with mock.patch.object(ci_app_test_runner, "run_suite_buffered", side_effect=fake_buffered):
            exit_code = ci_app_test_runner.run_all_suites(
                [suite.suite for suite in suites],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=io.StringIO(),
                suite_plan=ci_app_test_runner.SuitePlan(tuple(suites)),
                workers=2,
            )

        self.assertEqual(exit_code, 7)

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
                "list_suites",
                return_value=["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"],
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
                "list_suites",
                return_value=["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"],
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
                "list_suites",
                return_value=["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"],
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
                "list_suites",
                return_value=["RepoPromptTests.A", "RepoPromptWorkspaceTests.B"],
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
                "list_suites",
                return_value=["RepoPromptWorkspaceTests.A"],
            ),
            mock.patch.object(ci_app_test_runner, "discover_test_bundle", return_value=None),
            mock.patch.object(ci_app_test_runner, "run_all_suites") as run_all_suites,
            mock.patch("sys.stdout", output),
        ):
            exit_code = ci_app_test_runner.main(["--test-bundle-name", "RepoPromptWorkspaceTests"])

        self.assertEqual(exit_code, 1)
        self.assertIn("did not match any built XCTest bundle", output.getvalue())
        run_all_suites.assert_not_called()

    def write_ledger(self, directory: Path, rows: list[dict[str, str]]) -> Path:
        header = [
            "method_id",
            "target",
            "file",
            "suite",
            "method",
            "domain",
            "primary_contract_id",
            "secondary_contract_tags",
            "validation_class",
            "layer",
            "execution_tier",
            "scenario_count",
            "fixture_ids",
            "observable_oracle",
            "failure_risk",
            "runtime_seconds",
            "resource_cost_tags",
            "shared_state_tags",
            "lifecycle_owner",
            "current_disposition",
            "replacement_method_id",
            "preserved_scenario_delta",
            "notes",
        ]
        path = directory / "ledger.tsv"
        lines = ["\t".join(header)]
        for row in rows:
            complete = {key: "" for key in header}
            complete.update(
                {
                    "method_id": f"root/{row['suite']}/{row['method']}",
                    "target": "root",
                    "file": "Tests/Fake.swift",
                    "domain": "Root",
                    "primary_contract_id": "contract",
                    "validation_class": "unit",
                    "layer": "root_swiftpm",
                    "execution_tier": "fast",
                    "scenario_count": "1",
                    "observable_oracle": "oracle",
                    "failure_risk": "low",
                    "lifecycle_owner": "owner",
                    "current_disposition": "retain",
                    "preserved_scenario_delta": "0",
                }
            )
            complete.update(row)
            lines.append("\t".join(complete[key] for key in header))
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def test_plan_selected_suites_uses_runtime_balanced_shard_and_slow_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = self.write_ledger(Path(tmp), [
                {"suite": "RepoPromptTests.Slow", "method": "testOne", "runtime_seconds": "10.0"},
                {"suite": "RepoPromptTests.Medium", "method": "testOne", "runtime_seconds": "6.0"},
                {"suite": "RepoPromptTests.Fast", "method": "testOne", "runtime_seconds": "1.0"},
            ])
            selected, plan = ci_app_test_runner.plan_selected_suites(
                ["RepoPromptTests.Fast", "RepoPromptTests.Medium", "RepoPromptTests.Slow"],
                ledger=ledger,
                shard_count=2,
                shard_index=2,
                strict_ledger=True,
                slow_first=True,
                batch_max_seconds=5.0,
                require_runtime_for_batching=True,
            )

        self.assertIsNotNone(plan)
        self.assertEqual(
            [entry.suite for entry in selected],
            ["RepoPromptTests.Medium", "RepoPromptTests.Fast"],
        )

    def test_strict_ledger_rejects_missing_discovered_suite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = self.write_ledger(Path(tmp), [
                {"suite": "RepoPromptTests.Known", "method": "testOne", "runtime_seconds": "1.0"},
            ])
            with self.assertRaisesRegex(ValueError, "missing discovered suites"):
                ci_app_test_runner.plan_selected_suites(
                    ["RepoPromptTests.Known", "RepoPromptTests.Unknown"],
                    ledger=ledger,
                    shard_count=1,
                    shard_index=1,
                    strict_ledger=True,
                    slow_first=False,
                    batch_max_seconds=5.0,
                    require_runtime_for_batching=True,
                )

    def test_workers_greater_than_one_enables_strict_ledger(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = self.write_ledger(Path(tmp), [
                {"suite": "RepoPromptTests.Known", "method": "testOne", "runtime_seconds": "1.0"},
            ])
            output = io.StringIO()
            exit_code = ci_app_test_runner.run_all_suites(
                ["RepoPromptTests.Known", "RepoPromptTests.Unknown"],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
                workers=2,
                ledger=ledger,
                strict_ledger=False,
            )

        self.assertEqual(exit_code, 1)
        text = output.getvalue()
        self.assertIn("enables --strict-ledger", text)
        self.assertIn("missing discovered suites", text)

    def test_non_strict_ledger_includes_missing_discovered_suite_with_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = self.write_ledger(Path(tmp), [
                {"suite": "RepoPromptTests.Known", "method": "testOne", "runtime_seconds": "1.0"},
            ])
            selected, plan = ci_app_test_runner.plan_selected_suites(
                ["RepoPromptTests.Known", "RepoPromptTests.Unknown"],
                ledger=ledger,
                shard_count=1,
                shard_index=1,
                strict_ledger=False,
                slow_first=False,
                batch_max_seconds=5.0,
                require_runtime_for_batching=True,
            )

        self.assertIsNotNone(plan)
        self.assertEqual(
            [entry.suite for entry in selected],
            ["RepoPromptTests.Known", "RepoPromptTests.Unknown"],
        )
        missing = next(entry for entry in selected if entry.suite == "RepoPromptTests.Unknown")
        self.assertEqual(missing.estimated_seconds, 1.0)
        self.assertFalse(missing.batch_eligible)

    def test_batch_suite_entries_groups_only_adjacent_eligible_same_bundle(self) -> None:
        entries = [
            ci_app_test_runner.SuitePlanEntry("RepoPromptTests.A", 1.0, True),
            ci_app_test_runner.SuitePlanEntry("RepoPromptTests.B", 1.5, True),
            ci_app_test_runner.SuitePlanEntry("RepoPromptTests.C", 1.0, False),
            ci_app_test_runner.SuitePlanEntry("OtherTests.D", 1.0, True),
        ]
        groups = ci_app_test_runner.batch_suite_entries(
            entries,
            batch_fast_suites=True,
            batch_max_suites=4,
            batch_max_seconds=5.0,
            bundle_selector=lambda suite: (
                Path("/fake/RepoPromptTests.xctest")
                if suite.startswith("RepoPrompt")
                else Path("/fake/OtherTests.xctest")
            ),
        )

        self.assertEqual(
            [group.suites for group in groups],
            [
                ("RepoPromptTests.A", "RepoPromptTests.B"),
                ("RepoPromptTests.C",),
                ("OtherTests.D",),
            ],
        )

    def test_create_suite_group_process_uses_single_comma_separated_xctest_filter_for_batch(self) -> None:
        captured_args: list[list[str]] = []

        class FakePopen:
            def __init__(self, args, **kwargs) -> None:
                captured_args.append(args)
                self.pid = -1
                self.stdout = None
                self.returncode = 0

        bundle = Path("/fake/Tests.xctest")
        with mock.patch.object(ci_app_test_runner.subprocess, "Popen", side_effect=FakePopen):
            ci_app_test_runner.create_suite_group_process(
                ["RepoPromptTests.A", "RepoPromptTests.B"],
                swift_binary="swift",
                cwd=None,
                test_bundle=bundle,
                xctest_binary=["/usr/bin/xctest"],
            )

        self.assertEqual(
            captured_args[0],
            [
                "/usr/bin/xctest",
                "-XCTest",
                "RepoPromptTests.A,RepoPromptTests.B",
                str(bundle),
            ],
        )

    def test_run_all_suites_batches_multiple_xctest_filters_through_one_process(self) -> None:
        launched: list[tuple[tuple[str, ...], Path | None]] = []

        def fake_create_suite_group_process(suites, **kwargs):
            launched.append((tuple(suites), kwargs["test_bundle"]))
            return FakeProcess([
                "Test Case '-[RepoPromptTests.A testOne]' started.\n",
                "Test Case '-[RepoPromptTests.B testOne]' started.\n",
            ], returncode=0)

        entries = [
            ci_app_test_runner.SuitePlanEntry("RepoPromptTests.A", 1.0, True),
            ci_app_test_runner.SuitePlanEntry("RepoPromptTests.B", 1.0, True),
        ]
        output = io.StringIO()
        with (
            mock.patch.object(
                ci_app_test_runner,
                "plan_selected_suites",
                return_value=(entries, None),
            ),
            mock.patch.object(
                ci_app_test_runner,
                "create_suite_group_process",
                side_effect=fake_create_suite_group_process,
            ),
        ):
            exit_code = ci_app_test_runner.run_all_suites(
                ["RepoPromptTests.A", "RepoPromptTests.B"],
                timeout_seconds=1.0,
                silent_timeout_retries=0,
                swift_binary="swift",
                cwd=None,
                output=output,
                test_bundle=Path("/fake/RepoPromptCEPackageTests.xctest"),
                xctest_binary=["/usr/bin/xctest"],
                batch_fast_suites=True,
                batch_max_suites=4,
                batch_max_seconds=5.0,
            )

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            launched,
            [(("RepoPromptTests.A", "RepoPromptTests.B"), Path("/fake/RepoPromptCEPackageTests.xctest"))],
        )
        self.assertIn("::group::RepoPromptTests.A+RepoPromptTests.B", output.getvalue())
        self.assertIn("RepoPromptTests.B testOne", output.getvalue())

    def test_suite_filter_regex_matches_swiftpm_suite_method_identifiers(self) -> None:
        pattern = ci_app_test_runner.suite_filter_regex(["RepoPromptTests.A", "RepoPromptTests.B"])

        self.assertRegex("RepoPromptTests.A/testOne", pattern)
        self.assertRegex("RepoPromptTests.B/testTwo", pattern)
        self.assertRegex("RepoPromptTests.A", pattern)
        self.assertNotRegex("RepoPromptTests.Ab/testOne", pattern)
        self.assertNotRegex("OtherTests.A/testOne", pattern)

    def test_create_suite_group_process_uses_suite_prefix_swift_filter_without_bundle(self) -> None:
        captured_args: list[list[str]] = []

        class FakePopen:
            def __init__(self, args, **kwargs) -> None:
                captured_args.append(args)
                self.pid = -1
                self.stdout = None
                self.returncode = 0

        with mock.patch.object(ci_app_test_runner.subprocess, "Popen", side_effect=FakePopen):
            ci_app_test_runner.create_suite_group_process(
                ["RepoPromptTests.A", "RepoPromptTests.B"],
                swift_binary="swift",
                cwd=None,
            )

        self.assertEqual(
            captured_args[0],
            [
                "swift",
                "test",
                "--skip-build",
                "--filter",
                "^(?:RepoPromptTests\\.A|RepoPromptTests\\.B)(/|$)",
            ],
        )


if __name__ == "__main__":
    unittest.main()
