#!/usr/bin/env python3
"""Deterministic tests for test_suite_optimizer.py."""

from __future__ import annotations

import contextlib
import csv
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import test_suite_optimizer as optimizer  # noqa: E402


class TestListParsingTests(unittest.TestCase):
    def test_parse_test_list_keeps_target_subtotals_separate(self) -> None:
        root = optimizer.parse_test_list(
            "Building for debugging...\nRepoPromptTests.ExampleTests/testOne\nRepoPromptTests.ExampleTests/testTwo\n",
            "root",
        )
        provider = optimizer.parse_test_list(
            "RepoPromptClaudeCompatibleProviderTests.CodecTests/testRoundTrip\n",
            "provider",
        )

        self.assertEqual([test.method_id for test in root], [
            "root/RepoPromptTests.ExampleTests/testOne",
            "root/RepoPromptTests.ExampleTests/testTwo",
        ])
        self.assertEqual(
            provider[0].method_id,
            "provider/RepoPromptClaudeCompatibleProviderTests.CodecTests/testRoundTrip",
        )

    def test_parse_test_list_rejects_duplicate_identifiers(self) -> None:
        text = "RepoPromptTests.ExampleTests/testOne\nRepoPromptTests.ExampleTests/testOne\n"
        with self.assertRaisesRegex(optimizer.OptimizerError, "duplicate listed test identifier"):
            optimizer.parse_test_list(text, "root")

    def test_parse_test_list_requires_xctest_methods(self) -> None:
        with self.assertRaisesRegex(optimizer.OptimizerError, "no discoverable XCTest methods"):
            optimizer.parse_test_list("RepoPromptTests.ExampleTests/example\n", "root")


class TimingTests(unittest.TestCase):
    def make_sample(
        self,
        index: int,
        timings: list[optimizer.TestCaseTiming],
    ) -> optimizer.Sample:
        return optimizer.Sample(
            index=index,
            target="root",
            command=[],
            process_exit_code=0,
            state="completed",
            exit_code=0,
            queue_wait_seconds=0.0,
            execution_seconds=1.0,
            timed_out=False,
            measurement_invalid=False,
            diagnostic_paths=[],
            log_path=f"/{index}.log",
            invalid_reasons=[],
            timings=timings,
        )

    def test_parse_xctest_timings_supports_objc_and_dotted_formats(self) -> None:
        text = "\n".join(
            [
                "Test Case '-[RepoPromptTests.ExampleTests testOld]' passed (0.125 seconds).",
                "Test Case 'RepoPromptTests.ExampleTests.testNew' passed after 0.250 seconds.",
                "Test Case 'RepoPromptTests.ExampleTests.testSkipped' skipped (0.010 seconds).",
            ]
        )

        timings = optimizer.parse_xctest_timings(text)

        self.assertEqual([timing.method for timing in timings], ["testOld", "testNew", "testSkipped"])
        self.assertEqual([timing.seconds for timing in timings], [0.125, 0.25, 0.01])
        self.assertEqual(timings[-1].status, "skipped")

    def test_statistics_use_nearest_rank_and_relative_mad(self) -> None:
        values = [10.0, 11.0, 12.0, 13.0, 30.0]
        self.assertEqual(optimizer.nearest_rank_p95(values), 30.0)
        self.assertAlmostEqual(optimizer.relative_mad(values), 1.0 / 12.0)
        self.assertEqual(optimizer.noise_classification(0.05), "stable")
        self.assertEqual(optimizer.noise_classification(0.08), "noisy")
        self.assertEqual(optimizer.noise_classification(0.11), "unstable")

    def test_invalid_sample_classification_retains_all_reasons(self) -> None:
        reasons = optimizer.sample_invalid_reasons(
            70,
            {
                "state": "failed",
                "exitCode": 70,
                "timedOut": True,
                "measurementInvalid": True,
                "cancelRequested": True,
                "executionSeconds": None,
            },
            source_changed=True,
        )

        self.assertIn("conductor process exit 70", reasons)
        self.assertIn("terminal state failed", reasons)
        self.assertIn("timed out", reasons)
        self.assertIn("conductor marked measurement invalid", reasons)
        self.assertIn("measurement source changed during execution", reasons)
        self.assertIn("missing conductor execution timing", reasons)

    def test_filtered_sample_without_timings_is_invalid(self) -> None:
        run = optimizer.ConductorRun(
            command=["/repo/conductor", "test", "--filter", "RepoPromptTests.Empty", "--json"],
            process_exit_code=0,
            stdout="{}",
            stderr="",
            result={
                "state": "completed",
                "exitCode": 0,
                "queueWaitSeconds": 0.0,
                "executionSeconds": 1.0,
                "timedOut": False,
                "measurementInvalid": False,
                "logPath": "/tmp/empty.log",
            },
            log_text="",
        )

        sample = optimizer.sample_from_run(
            1,
            "root",
            run,
            source_changed=False,
            source_guard_kind=optimizer.SOURCE_GUARD_METADATA,
            require_timings=True,
        )

        self.assertFalse(sample.valid)
        self.assertEqual(sample.source_guard_kind, optimizer.SOURCE_GUARD_METADATA)
        self.assertIn("filtered baseline produced no parsed XCTest timings", sample.invalid_reasons)

    def test_baseline_summary_separates_build_and_test_seconds(self) -> None:
        samples = [
            self.make_sample(1, []),
            self.make_sample(2, []),
            self.make_sample(3, []),
        ]
        samples[0].execution_seconds = 10.0
        samples[1].execution_seconds = 12.0
        samples[2].execution_seconds = 14.0
        samples[0].build = {"execution_seconds": 3.0}
        samples[1].build = {"execution_seconds": 5.0}
        samples[2].build = {"execution_seconds": 7.0}

        summary = optimizer.baseline_summary(samples)

        self.assertEqual(summary["median_seconds"], 12.0)
        self.assertEqual(summary["median_build_execution_seconds"], 5.0)
        self.assertEqual(summary["observed_p95_build_execution_seconds"], 7.0)
        self.assertEqual(summary["median_total_build_plus_test_seconds"], 17.0)

    def test_suite_ranking_uses_median_aggregate_seconds(self) -> None:
        ranking = optimizer.suite_ranking([
            self.make_sample(
                1,
                [
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testOne", "passed", 1.0),
                    optimizer.TestCaseTiming("RepoPromptTests.B", "testTwo", "passed", 4.0),
                ],
            ),
            self.make_sample(
                2,
                [
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testOne", "passed", 5.0),
                    optimizer.TestCaseTiming("RepoPromptTests.B", "testTwo", "passed", 4.0),
                ],
            ),
        ])

        self.assertEqual(ranking[0]["suite"], "RepoPromptTests.B")
        self.assertEqual(ranking[0]["median_aggregate_seconds"], 4.0)
        self.assertEqual(ranking[1]["median_aggregate_seconds"], 3.0)
        self.assertEqual(ranking[1]["max_method_seconds"], 5.0)

    def test_test_ranking_uses_median_p95_and_stable_ties(self) -> None:
        samples = [
            self.make_sample(
                1,
                [
                    optimizer.TestCaseTiming("RepoPromptTests.B", "testSlow", "passed", 5.0),
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testSlow", "passed", 5.0),
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testFast", "passed", 1.0),
                ],
            ),
            self.make_sample(
                2,
                [
                    optimizer.TestCaseTiming("RepoPromptTests.B", "testSlow", "skipped", 7.0),
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testSlow", "passed", 7.0),
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testFast", "passed", 2.0),
                ],
            ),
        ]

        ranking = optimizer.test_ranking(samples)

        self.assertEqual((ranking[0]["suite"], ranking[0]["method"]), ("RepoPromptTests.A", "testSlow"))
        self.assertEqual((ranking[1]["suite"], ranking[1]["method"]), ("RepoPromptTests.B", "testSlow"))
        self.assertEqual(ranking[0]["median_seconds"], 6.0)
        self.assertEqual(ranking[0]["observed_p95_seconds"], 7.0)
        self.assertEqual(ranking[1]["failure_or_skip_count"], 1)


class SourceAndLedgerTests(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        tests = root / "Tests" / "RepoPromptTests" / "MCP"
        tests.mkdir(parents=True)
        (tests / "ExampleTests.swift").write_text(
            "import XCTest\nfinal class ExampleTests: XCTestCase {\n"
            "    func testOne() {}\n}\n",
            encoding="utf-8",
        )

    def test_conductor_command_adds_filter_before_json(self) -> None:
        command = optimizer.conductor_command(
            Path("/repo"),
            "root",
            filter_value="RepoPromptTests.ExampleTests/testOne",
        )

        self.assertEqual(
            command,
            [
                "/repo/conductor",
                "test",
                "--filter",
                "RepoPromptTests.ExampleTests/testOne",
                "--json",
            ],
        )
        with self.assertRaisesRegex(optimizer.OptimizerError, "--filter cannot be used with list mode"):
            optimizer.conductor_command(Path("/repo"), "provider", list_mode=True, filter_value="Suite")

    def test_conductor_command_adds_test_product_before_filter(self) -> None:
        command = optimizer.conductor_command(
            Path("/repo"),
            "root",
            filter_value="WorkspaceTests",
            test_product="RepoPromptWorkspaceTests",
        )

        self.assertEqual(
            command,
            [
                "/repo/conductor",
                "test",
                "--test-product",
                "RepoPromptWorkspaceTests",
                "--filter",
                "WorkspaceTests",
                "--json",
            ],
        )
        with self.assertRaisesRegex(optimizer.OptimizerError, "--test-product cannot be used with list mode"):
            optimizer.conductor_command(
                Path("/repo"),
                "root",
                list_mode=True,
                test_product="RepoPromptWorkspaceTests",
            )

    def test_metadata_source_guard_changes_on_add_modify_and_delete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root)
            tests = root / "Tests" / "RepoPromptTests" / "MCP"
            initial = optimizer.measurement_source_metadata_fingerprint(root)

            new_file = tests / "AnotherTests.swift"
            new_file.write_text("final class AnotherTests {}\n", encoding="utf-8")
            after_add = optimizer.measurement_source_metadata_fingerprint(root)

            new_file.write_text("final class AnotherTests { func testTwo() {} }\n", encoding="utf-8")
            after_modify = optimizer.measurement_source_metadata_fingerprint(root)

            new_file.unlink()
            after_delete = optimizer.measurement_source_metadata_fingerprint(root)

        self.assertNotEqual(initial, after_add)
        self.assertNotEqual(after_add, after_modify)
        self.assertEqual(initial, after_delete)
        with self.assertRaisesRegex(optimizer.OptimizerError, "unsupported source change guard"):
            optimizer.measurement_source_guard_fingerprint(root, "unknown")

    def test_source_mapping_and_ledger_scaffold_are_complete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root)
            tests = [optimizer.ListedTest("root", "RepoPromptTests.ExampleTests", "testOne")]

            locations = optimizer.map_test_sources(root, tests)
            rows = optimizer.ledger_rows(tests, locations)

        self.assertEqual(locations[tests[0].method_id].file, "Tests/RepoPromptTests/MCP/ExampleTests.swift")
        self.assertEqual(rows[0]["domain"], "MCP")
        self.assertEqual(rows[0]["execution_tier"], "routine")
        self.assertEqual(rows[0]["scenario_count"], "1")
        self.assertEqual(rows[0]["current_disposition"], "retain_pending_review")

    def write_ledger(self, path: Path, rows: list[dict[str, str]]) -> None:
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=optimizer.LEDGER_COLUMNS,
                delimiter="\t",
                lineterminator="\n",
            )
            writer.writeheader()
            for partial in rows:
                row = {column: "" for column in optimizer.LEDGER_COLUMNS}
                row.update(partial)
                if not row.get("execution_tier"):
                    row["execution_tier"] = "routine"
                writer.writerow(row)

    def test_read_ledger_rows_rejects_unknown_execution_tier(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / "ledger.tsv"
            self.write_ledger(
                ledger,
                [{
                    "method_id": "root/RepoPromptTests.ExampleTests/testOne",
                    "target": "root",
                    "suite": "RepoPromptTests.ExampleTests",
                    "method": "testOne",
                    "execution_tier": "sometimes",
                }],
            )

            with self.assertRaisesRegex(optimizer.OptimizerError, "unsupported execution_tier"):
                optimizer.read_ledger_rows(ledger)

    def test_impacted_tests_selects_test_file_smoke_floor_and_skips_heavy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            self.write_ledger(
                ledger,
                [
                    {
                        "method_id": "root/RepoPromptTests.ExampleTests/testOne",
                        "target": "root",
                        "file": "Tests/RepoPromptTests/MCP/ExampleTests.swift",
                        "suite": "RepoPromptTests.ExampleTests",
                        "method": "testOne",
                        "domain": "MCP",
                        "layer": "root_swiftpm",
                        "execution_tier": "routine",
                    },
                    {
                        "method_id": "root/RepoPromptTests.SmokeTests/testSmoke",
                        "target": "root",
                        "file": "Tests/RepoPromptTests/SmokeTests.swift",
                        "suite": "RepoPromptTests.SmokeTests",
                        "method": "testSmoke",
                        "domain": "Root",
                        "layer": "root_swiftpm",
                        "execution_tier": "fast",
                    },
                    {
                        "method_id": "root/RepoPromptTests.ScaleTests/testScale",
                        "target": "root",
                        "file": "Tests/RepoPromptTests/MCP/ScaleTests.swift",
                        "suite": "RepoPromptTests.ScaleTests",
                        "method": "testScale",
                        "domain": "MCP",
                        "layer": "root_swiftpm",
                        "execution_tier": "scale",
                    },
                ],
            )

            with mock.patch.object(
                optimizer,
                "changed_files_for_range",
                return_value=[
                    "Tests/RepoPromptTests/MCP/ExampleTests.swift",
                    "Sources/RepoPrompt/Infrastructure/MCP/Router.swift",
                ],
            ):
                payload = optimizer.impacted_tests(
                    root,
                    ledger,
                    "origin/main...HEAD",
                    smoke_floor_suites=["RepoPromptTests.SmokeTests"],
                    validate_live_list=False,
                )

        self.assertFalse(payload["full_root_required"])
        self.assertEqual(payload["selected_count"], 2)
        self.assertEqual(
            [entry["method_id"] for entry in payload["selected"]],
            [
                "root/RepoPromptTests.ExampleTests/testOne",
                "root/RepoPromptTests.SmokeTests/testSmoke",
            ],
        )
        self.assertEqual(payload["skipped_heavy_or_opt_in"][0]["method_id"], "root/RepoPromptTests.ScaleTests/testScale")
        self.assertIn(r"RepoPromptTests\.ExampleTests/testOne", payload["filter"])

    def test_impacted_tests_uses_full_root_for_broad_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            self.write_ledger(
                ledger,
                [{
                    "method_id": "root/RepoPromptTests.ExampleTests/testOne",
                    "target": "root",
                    "suite": "RepoPromptTests.ExampleTests",
                    "method": "testOne",
                    "execution_tier": "routine",
                }],
            )

            with mock.patch.object(optimizer, "changed_files_for_range", return_value=["Package.swift"]):
                payload = optimizer.impacted_tests(root, ledger, "HEAD", validate_live_list=False)

        self.assertTrue(payload["full_root_required"])
        self.assertIsNone(payload["filter"])

    def test_impacted_tests_validates_against_live_root_list(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            self.write_ledger(
                ledger,
                [{
                    "method_id": "root/RepoPromptTests.ExampleTests/testOne",
                    "target": "root",
                    "file": "Tests/RepoPromptTests/MCP/ExampleTests.swift",
                    "suite": "RepoPromptTests.ExampleTests",
                    "method": "testOne",
                    "domain": "MCP",
                    "execution_tier": "routine",
                }],
            )
            run = optimizer.ConductorRun(
                command=["/repo/conductor", "test", "--list", "--json"],
                process_exit_code=0,
                stdout="{}",
                stderr="",
                result={"state": "completed", "exitCode": 0, "logPath": "/tmp/root-list.log"},
                log_text="RepoPromptTests.ExampleTests/testOne\n",
                ticket="list-ticket",
            )

            with (
                mock.patch.object(optimizer, "run_conductor", return_value=run),
                mock.patch.object(
                    optimizer,
                    "changed_files_for_range",
                    return_value=["Tests/RepoPromptTests/MCP/ExampleTests.swift"],
                ),
            ):
                payload = optimizer.impacted_tests(root, ledger, "HEAD")

        self.assertEqual(payload["live_root_test_count"], 1)
        self.assertEqual(payload["list_log_path"], "/tmp/root-list.log")
        self.assertEqual(payload["selected_count"], 1)

    def test_shard_root_tests_balances_by_runtime_and_excludes_heavy_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / "ledger.tsv"
            self.write_ledger(
                ledger,
                [
                    {
                        "method_id": "root/RepoPromptTests.A/testOne",
                        "target": "root",
                        "suite": "RepoPromptTests.A",
                        "method": "testOne",
                        "execution_tier": "routine",
                        "runtime_seconds": "9",
                        "shared_state_tags": "TempDirectory",
                    },
                    {
                        "method_id": "root/RepoPromptTests.B/testTwo",
                        "target": "root",
                        "suite": "RepoPromptTests.B",
                        "method": "testTwo",
                        "execution_tier": "routine",
                        "runtime_seconds": "1",
                    },
                    {
                        "method_id": "root/RepoPromptTests.C/testScale",
                        "target": "root",
                        "suite": "RepoPromptTests.C",
                        "method": "testScale",
                        "execution_tier": "scale",
                        "runtime_seconds": "100",
                    },
                ],
            )

            payload = optimizer.shard_root_tests(ledger, 2)

        self.assertEqual(payload["shard_count"], 2)
        self.assertEqual(sum(shard["method_count"] for shard in payload["shards"]), 2)
        self.assertNotIn("RepoPromptTests.C/testScale", json.dumps(payload))
        self.assertIn("shared_state_tag_counts", payload["shards"][0])
        self.assertIn("parallelization_warning", payload)

    def test_source_mapping_supports_multiple_root_test_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "Tests" / "RepoPromptTests" / "MCP"
            second = root / "Tests" / "RepoPromptWorkspaceTests" / "WorkspaceContext"
            first.mkdir(parents=True)
            second.mkdir(parents=True)
            (first / "ExampleTests.swift").write_text(
                "final class ExampleTests { func testOne() {} }\n",
                encoding="utf-8",
            )
            (second / "WorkspaceExampleTests.swift").write_text(
                "final class WorkspaceExampleTests { func testTwo() {} }\n",
                encoding="utf-8",
            )
            tests = [
                optimizer.ListedTest("root", "RepoPromptWorkspaceTests.WorkspaceExampleTests", "testTwo")
            ]

            locations = optimizer.map_test_sources(root, tests)

        self.assertEqual(
            locations[tests[0].method_id].file,
            "Tests/RepoPromptWorkspaceTests/WorkspaceContext/WorkspaceExampleTests.swift",
        )
        self.assertEqual(locations[tests[0].method_id].domain, "WorkspaceContext")

    def test_source_mapping_rejects_ambiguous_method_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tests_root = root / "Tests" / "RepoPromptTests" / "MCP"
            tests_root.mkdir(parents=True)
            for name in ("One.swift", "Two.swift"):
                (tests_root / name).write_text("func testShared() {}\n", encoding="utf-8")
            tests = [optimizer.ListedTest("root", "RepoPromptTests.UnknownTests", "testShared")]

            with self.assertRaisesRegex(optimizer.OptimizerError, "expected one source file"):
                optimizer.map_test_sources(root, tests)

    def test_ledger_verification_rejects_schema_and_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ledger.tsv"
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=optimizer.LEDGER_COLUMNS,
                    delimiter="\t",
                    lineterminator="\n",
                )
                writer.writeheader()
                row = {column: "" for column in optimizer.LEDGER_COLUMNS}
                row["method_id"] = "root/Suite/testOne"
                writer.writerow(row)
                writer.writerow(row)

            with self.assertRaisesRegex(optimizer.OptimizerError, "duplicate method_id"):
                optimizer.read_ledger_ids(path)

    def test_verify_ledger_emits_progress_and_checks_completed_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            with ledger.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=optimizer.LEDGER_COLUMNS,
                    delimiter="\t",
                    lineterminator="\n",
                )
                writer.writeheader()
                for method_id, target, suite, method in [
                    ("root/RepoPromptTests.ExampleTests/testOne", "root", "RepoPromptTests.ExampleTests", "testOne"),
                    (
                        "provider/RepoPromptClaudeCompatibleProviderTests.CodecTests/testRoundTrip",
                        "provider",
                        "RepoPromptClaudeCompatibleProviderTests.CodecTests",
                        "testRoundTrip",
                    ),
                ]:
                    row = {column: "" for column in optimizer.LEDGER_COLUMNS}
                    row.update({
                        "method_id": method_id,
                        "target": target,
                        "suite": suite,
                        "method": method,
                        "execution_tier": "routine" if target == "root" else "fast",
                    })
                    writer.writerow(row)
            runs = {
                "root": optimizer.ConductorRun(
                    command=["/repo/conductor", "test", "--list", "--json"],
                    process_exit_code=0,
                    stdout="{}",
                    stderr="",
                    result={"state": "completed", "exitCode": 0, "logPath": "/tmp/root.log"},
                    log_text="RepoPromptTests.ExampleTests/testOne\n",
                    ticket="root-ticket",
                ),
                "provider": optimizer.ConductorRun(
                    command=["/repo/conductor", "provider-test", "--list", "--json"],
                    process_exit_code=0,
                    stdout="{}",
                    stderr="",
                    result={"state": "completed", "exitCode": 0, "logPath": "/tmp/provider.log"},
                    log_text="RepoPromptClaudeCompatibleProviderTests.CodecTests/testRoundTrip\n",
                    ticket="provider-ticket",
                ),
            }
            events: list[dict[str, object]] = []

            def fake_run_conductor(repo_root, target, list_mode=False, filter_value=None, timeout_seconds=None):
                self.assertTrue(list_mode)
                self.assertEqual(timeout_seconds, 12)
                return runs[target]

            with mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor):
                payload = optimizer.verify_ledger_with_progress(
                    root,
                    ledger,
                    lambda event: events.append(dict(event)),
                    list_timeout_seconds=12,
                )

        self.assertEqual(payload["count"], 2)
        self.assertEqual(
            [event["event"] for event in events],
            [
                "verify_ledger_list_start",
                "verify_ledger_list_end",
                "verify_ledger_list_start",
                "verify_ledger_list_end",
            ],
        )
        self.assertEqual(events[0]["timeout_seconds"], 12)
        self.assertEqual(events[1]["ticket"], "root-ticket")
        self.assertEqual(events[3]["ticket"], "provider-ticket")

    def test_verify_ledger_rejects_missing_list_log(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            with ledger.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=optimizer.LEDGER_COLUMNS,
                    delimiter="\t",
                    lineterminator="\n",
                )
                writer.writeheader()
            run = optimizer.ConductorRun(
                command=["/repo/conductor", "test", "--list", "--json"],
                process_exit_code=0,
                stdout="{}",
                stderr="",
                result={"state": "completed", "exitCode": 0, "logPath": "/missing/root.log"},
                log_text="",
                ticket="root-ticket",
            )

            with mock.patch.object(optimizer, "run_conductor", return_value=run):
                with self.assertRaisesRegex(optimizer.OptimizerError, "list log missing or empty"):
                    optimizer.verify_ledger_with_progress(root, ledger, None)

    def test_verify_ledger_rejects_non_positive_list_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ledger = root / "ledger.tsv"
            ledger.write_text("\t".join(optimizer.LEDGER_COLUMNS) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(optimizer.OptimizerError, "must be greater than zero"):
                optimizer.verify_ledger_with_progress(root, ledger, None, list_timeout_seconds=0)


class ProgressOutputTests(unittest.TestCase):
    def test_emit_progress_event_uses_stderr_compact_json_and_ignores_pipe_errors(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            optimizer.emit_progress_event({"z": 1, "event": "unit", "a": None})

        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(
            stderr.getvalue(),
            f'{optimizer.PROGRESS_PREFIX}{{"a":null,"event":"unit","z":1}}\n',
        )

        class BrokenStderr:
            def write(self, text: str) -> int:
                raise BrokenPipeError()

            def flush(self) -> None:
                raise OSError()

        with contextlib.redirect_stderr(BrokenStderr()):
            optimizer.emit_progress_event({"event": "unit"})

    def test_conductor_ticket_helper_uses_current_ticket_only(self) -> None:
        self.assertEqual(
            optimizer.conductor_ticket_from_payload({"ticket": "top"}, {"ticket": "result"}),
            "result",
        )
        self.assertEqual(optimizer.conductor_ticket_from_payload({"ticket": "top"}, {}), "top")
        self.assertEqual(optimizer.conductor_ticket_from_payload({}, {"ticket": 123}), "123")
        self.assertIsNone(optimizer.conductor_ticket_from_payload({"ticket": ""}, {}))
        self.assertIsNone(
            optimizer.conductor_ticket_from_payload({}, {"supersededByTicket": "old-ticket"})
        )


class BaselineProgressTests(unittest.TestCase):
    def make_run(self, index: int, *, exit_code: int = 0) -> optimizer.ConductorRun:
        result = {
            "state": "completed",
            "exitCode": exit_code,
            "queueWaitSeconds": 0.25,
            "executionSeconds": 10.0 + index,
            "timedOut": False,
            "measurementInvalid": False,
            "logPath": f"/tmp/test-suite-optimizer-sample-{index}.log",
        }
        return optimizer.ConductorRun(
            command=["/repo/conductor", "test", "--json"],
            process_exit_code=0,
            stdout=json.dumps({"result": result}),
            stderr="",
            result=result,
            log_text="Test Case 'RepoPromptTests.ExampleTests.testOne' passed after 1.000 seconds.\n",
            ticket=f"ticket-{index}",
        )

    def test_baseline_progress_events_are_ordered_and_include_invalid_reasons(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            filter_value = "RepoPromptTests.ExampleTests"
            expected_command = optimizer.conductor_command(root, "root", filter_value=filter_value)
            events: list[dict[str, object]] = []
            operations: list[tuple[str, object]] = []
            run_count = 0
            runs = [self.make_run(1, exit_code=1), self.make_run(2)]

            def progress_sink(event: dict[str, object]) -> None:
                operations.append(("progress", event["event"]))
                events.append(dict(event))

            def fake_run_conductor(
                repo_root: Path,
                target: str,
                list_mode: bool = False,
                filter_value: str | None = None,
                test_product: str | None = None,
            ) -> optimizer.ConductorRun:
                nonlocal run_count
                run_count += 1
                self.assertFalse(list_mode)
                self.assertEqual((target, filter_value), ("root", "RepoPromptTests.ExampleTests"))
                self.assertIsNone(test_product)
                operations.append(("run", run_count))
                return runs.pop(0)

            with (
                mock.patch.object(optimizer, "git_metadata", return_value={"commit": "a" * 40, "working_tree": ""}),
                mock.patch.object(optimizer, "measurement_source_guard_fingerprint", return_value="same-source"),
                mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor),
                mock.patch.object(optimizer, "utc_now", return_value="2026-07-01T00:00:00+00:00"),
            ):
                payload = optimizer.baseline(
                    repo_root=root,
                    target="root",
                    samples_requested=2,
                    label="progress-test",
                    scoreboard=root / "scoreboard.md",
                    output=root / "baseline.json",
                    method_counts=None,
                    source_change_guard=optimizer.SOURCE_GUARD_METADATA,
                    filter_value=filter_value,
                    progress_sink=progress_sink,
                )

        self.assertEqual(
            [event["event"] for event in events],
            [
                "baseline_sample_start",
                "baseline_sample_end",
                "baseline_sample_start",
                "baseline_sample_end",
            ],
        )
        self.assertEqual(operations[0], ("progress", "baseline_sample_start"))
        self.assertEqual(operations[1], ("run", 1))
        self.assertEqual(payload["summary"]["valid_samples"], 1)
        self.assertEqual(payload["summary"]["invalid_samples"], 1)

        start = events[0]
        self.assertEqual(start["command"], expected_command)
        self.assertEqual(start["target"], "root")
        self.assertEqual(start["scope"], "filtered")
        self.assertEqual(start["filter"], filter_value)
        self.assertIsNone(start["test_product"])
        self.assertEqual(start["source_guard"], optimizer.SOURCE_GUARD_METADATA)
        self.assertEqual(start["sample_index"], 1)
        self.assertEqual(start["sample_count"], 2)
        self.assertIsNone(start["ticket"])
        self.assertIsNone(start["log_path"])

        invalid_end = events[1]
        self.assertEqual(invalid_end["ticket"], "ticket-1")
        self.assertEqual(invalid_end["log_path"], "/tmp/test-suite-optimizer-sample-1.log")
        self.assertEqual(invalid_end["process_exit_code"], 0)
        self.assertEqual(invalid_end["state"], "completed")
        self.assertEqual(invalid_end["exit_code"], 1)
        self.assertEqual(invalid_end["execution_seconds"], 11.0)
        self.assertEqual(invalid_end["measurement_invalid"], False)
        self.assertEqual(invalid_end["source_changed"], False)
        self.assertEqual(invalid_end["valid"], False)
        self.assertEqual(invalid_end["invalid_reasons"], ["test exit 1"])
        self.assertEqual(events[3]["valid"], True)
        self.assertEqual(events[3]["invalid_reasons"], [])

    def test_baseline_build_before_samples_emits_build_progress(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            events: list[dict[str, object]] = []
            operations: list[str] = []
            build_result = {
                "state": "completed",
                "exitCode": 0,
                "queueWaitSeconds": 0.1,
                "executionSeconds": 3.0,
                "measurementInvalid": False,
                "logPath": "/tmp/build.log",
            }
            build_run = optimizer.ConductorRun(
                command=["/repo/conductor", "swift-build", "--product", "all", "--json"],
                process_exit_code=0,
                stdout="{}",
                stderr="",
                result=build_result,
                log_text="",
                ticket="build-ticket",
            )

            def fake_build(repo_root: Path, target: str) -> optimizer.ConductorRun:
                operations.append("build")
                return build_run

            def fake_run_conductor(
                repo_root: Path,
                target: str,
                list_mode: bool = False,
                filter_value: str | None = None,
                test_product: str | None = None,
            ) -> optimizer.ConductorRun:
                operations.append("test")
                self.assertIsNone(test_product)
                return self.make_run(1)

            with (
                mock.patch.object(optimizer, "git_metadata", return_value={"commit": "b" * 40, "working_tree": ""}),
                mock.patch.object(optimizer, "measurement_source_guard_fingerprint", return_value="same-source"),
                mock.patch.object(optimizer, "run_conductor_build", side_effect=fake_build),
                mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor),
                mock.patch.object(optimizer, "utc_now", return_value="2026-07-01T00:00:00+00:00"),
            ):
                payload = optimizer.baseline(
                    repo_root=root,
                    target="root",
                    samples_requested=1,
                    label="build-progress-test",
                    scoreboard=root / "scoreboard.md",
                    output=root / "baseline.json",
                    method_counts=None,
                    build_before_samples=True,
                    progress_sink=lambda event: events.append(dict(event)),
                )

        self.assertEqual(operations, ["build", "test"])
        self.assertEqual(
            [event["event"] for event in events],
            [
                "baseline_sample_start",
                "baseline_build_start",
                "baseline_build_end",
                "baseline_sample_end",
            ],
        )
        self.assertEqual(events[2]["ticket"], "build-ticket")
        self.assertEqual(events[2]["execution_seconds"], 3.0)
        self.assertEqual(payload["summary"]["median_build_execution_seconds"], 3.0)

    def test_baseline_records_test_product_and_keeps_primary_metric_separate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            expected_product = "RepoPromptWorkspaceTests"
            expected_command = optimizer.conductor_command(root, "root", test_product=expected_product)
            events: list[dict[str, object]] = []

            def fake_run_conductor(
                repo_root: Path,
                target: str,
                list_mode: bool = False,
                filter_value: str | None = None,
                test_product: str | None = None,
            ) -> optimizer.ConductorRun:
                self.assertEqual((target, list_mode, filter_value, test_product), ("root", False, None, expected_product))
                return self.make_run(1)

            with (
                mock.patch.object(optimizer, "git_metadata", return_value={"commit": "c" * 40, "working_tree": ""}),
                mock.patch.object(optimizer, "measurement_source_guard_fingerprint", return_value="same-source"),
                mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor),
                mock.patch.object(optimizer, "utc_now", return_value="2026-07-01T00:00:00+00:00"),
            ):
                payload = optimizer.baseline(
                    repo_root=root,
                    target="root",
                    samples_requested=1,
                    label="workspace-product",
                    scoreboard=root / "scoreboard.md",
                    output=root / "baseline.json",
                    method_counts=None,
                    test_product=expected_product,
                    progress_sink=lambda event: events.append(dict(event)),
                )
                scoreboard = (root / "scoreboard.md").read_text(encoding="utf-8")

        self.assertEqual(payload["command"], expected_command)
        self.assertEqual(payload["test_product"], expected_product)
        self.assertEqual(payload["scope"], "test-product")
        self.assertFalse(payload["primary_metric_eligible"])
        self.assertEqual(events[0]["test_product"], expected_product)
        self.assertEqual(events[0]["scope"], "test-product")
        self.assertEqual(events[1]["test_product"], expected_product)
        self.assertEqual(events[1]["scope"], "test-product")
        self.assertIn("### Focused:", scoreboard)
        self.assertIn("Scope/filter: test-product", scoreboard)
        self.assertIn(f"Test product: `{expected_product}`", scoreboard)

    def test_baseline_rejects_provider_build_before_samples_before_progress(self) -> None:
        events: list[dict[str, object]] = []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(optimizer.OptimizerError, "supports only --target root"):
                optimizer.baseline(
                    repo_root=root,
                    target="provider",
                    samples_requested=1,
                    label="provider-build",
                    scoreboard=root / "scoreboard.md",
                    output=root / "baseline.json",
                    method_counts=None,
                    build_before_samples=True,
                    progress_sink=lambda event: events.append(dict(event)),
                )

        self.assertEqual(events, [])

    def test_baseline_rejects_test_product_build_before_samples_before_progress(self) -> None:
        events: list[dict[str, object]] = []
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(optimizer.OptimizerError, "cannot be combined with --test-product"):
                optimizer.baseline(
                    repo_root=root,
                    target="root",
                    samples_requested=1,
                    label="product-build",
                    scoreboard=root / "scoreboard.md",
                    output=root / "baseline.json",
                    method_counts=None,
                    test_product="RepoPromptWorkspaceTests",
                    build_before_samples=True,
                    progress_sink=lambda event: events.append(dict(event)),
                )

        self.assertEqual(events, [])


class FocusedCostTests(unittest.TestCase):
    def make_run(
        self,
        root: Path,
        index: int,
        *,
        exit_code: int = 0,
        log_text: str | None = None,
        result_extra: dict[str, object] | None = None,
    ) -> optimizer.ConductorRun:
        log_path = root / f"focused-{index}.log"
        if log_text is None:
            log_text = "Test Case 'RepoPromptTests.ExampleTests.testOne' passed after 1.500 seconds.\n"
        log_path.write_text(log_text, encoding="utf-8")
        result = {
            "state": "completed",
            "exitCode": exit_code,
            "queueWaitSeconds": 0.5,
            "executionSeconds": 12.0 + index,
            "timedOut": False,
            "measurementInvalid": False,
            "logPath": str(log_path),
        }
        if result_extra:
            result.update(result_extra)
        return optimizer.ConductorRun(
            command=["/repo/conductor", "test", "--filter", "RepoPromptTests.ExampleTests", "--json"],
            process_exit_code=0,
            stdout=json.dumps({"result": result}),
            stderr="",
            result=result,
            log_text=log_text,
            ticket=f"ticket-{index}",
        )

    def test_focused_cost_records_diagnostic_artifact_shape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            filter_value = "RepoPromptTests.ExampleTests"
            output = root / "focused-cost.json"
            scoreboard = root / "scoreboard.md"
            events: list[dict[str, object]] = []
            runs = [
                self.make_run(root, 1, result_extra={"diagnostics": [{"swiftFrontendMaxRSSBytes": 42_000}]}),
                self.make_run(root, 2, exit_code=1, log_text=""),
            ]

            def fake_run_conductor(
                repo_root: Path,
                target: str,
                list_mode: bool = False,
                filter_value: str | None = None,
            ) -> optimizer.ConductorRun:
                self.assertEqual(repo_root, root)
                self.assertEqual(target, "root")
                self.assertFalse(list_mode)
                self.assertEqual(filter_value, "RepoPromptTests.ExampleTests")
                return runs.pop(0)

            with (
                mock.patch.object(optimizer, "git_metadata", return_value={"commit": "b" * 40, "working_tree": ""}),
                mock.patch.object(optimizer, "measurement_source_guard_fingerprint", return_value="same-source"),
                mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor),
                mock.patch.object(optimizer, "utc_now", return_value="2026-07-03T00:00:00+00:00"),
            ):
                payload = optimizer.focused_cost(
                    repo_root=root,
                    target="root",
                    filter_value=filter_value,
                    samples_requested=2,
                    label="unit-focused",
                    scoreboard=scoreboard,
                    output=output,
                    source_change_guard=optimizer.SOURCE_GUARD_METADATA,
                    progress_sink=lambda event: events.append(dict(event)),
                )

            artifact = json.loads(output.read_text(encoding="utf-8"))
            scoreboard_text = scoreboard.read_text(encoding="utf-8")

        self.assertEqual(payload, artifact)
        self.assertEqual(artifact["diagnostic_kind"], "focused-cost")
        self.assertEqual(artifact["command"], optimizer.conductor_command(root, "root", filter_value=filter_value))
        self.assertFalse(artifact["primary_metric_eligible"])
        self.assertEqual(artifact["source_guard"], {"kind": optimizer.SOURCE_GUARD_METADATA})
        self.assertEqual(artifact["samples"][0]["queue_wait_seconds"], 0.5)
        self.assertEqual(artifact["samples"][0]["total_execution_seconds"], 13.0)
        self.assertEqual(artifact["samples"][0]["parsed_xctest_seconds"], 1.5)
        self.assertEqual(artifact["samples"][0]["inferred_overhead_seconds"], 11.5)
        self.assertEqual(artifact["samples"][0]["max_rss_bytes"], 42_000)
        self.assertFalse(artifact["samples"][0]["source_changed"])
        self.assertEqual(artifact["samples"][0]["invalid_reasons"], [])
        self.assertIn("test exit 1", artifact["samples"][1]["invalid_reasons"])
        self.assertIn("filtered baseline produced no parsed XCTest timings", artifact["samples"][1]["invalid_reasons"])
        self.assertEqual(artifact["summary"]["valid_samples"], 1)
        self.assertEqual(artifact["summary"]["median_total_execution_seconds"], 13.0)
        self.assertEqual(artifact["summary"]["median_parsed_xctest_seconds"], 1.5)
        self.assertEqual(artifact["summary"]["median_inferred_overhead_seconds"], 11.5)
        self.assertEqual(artifact["summary"]["max_rss_bytes"], 42_000)
        self.assertFalse(artifact["summary"]["reliable"])
        self.assertTrue(artifact["summary"]["diagnostic_only"])
        self.assertEqual(
            [event["event"] for event in events],
            [
                "focused_cost_sample_start",
                "focused_cost_sample_end",
                "focused_cost_sample_start",
                "focused_cost_sample_end",
            ],
        )
        self.assertIn("Focused cost diagnostic", scoreboard_text)
        self.assertIn("Primary metric eligible: no", scoreboard_text)
        self.assertIn("unit-focused", scoreboard_text)
        self.assertIn("Summary:", scoreboard_text)
        self.assertIn("| Valid | Invalid | Median total execution seconds |", scoreboard_text)
        self.assertIn("| 1 | 1 | 13.000 | 13.000 | 0.0000 | stable | 1.500 | 11.500 | 42000 | yes | no |", scoreboard_text)

    def test_focused_cost_rejects_zero_valid_samples_without_writing_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "focused-cost.json"
            scoreboard = root / "scoreboard.md"
            runs = [
                self.make_run(root, 1, exit_code=1, log_text=""),
                self.make_run(root, 2, exit_code=2, log_text=""),
            ]

            def fake_run_conductor(
                repo_root: Path,
                target: str,
                list_mode: bool = False,
                filter_value: str | None = None,
            ) -> optimizer.ConductorRun:
                self.assertEqual(repo_root, root)
                self.assertEqual(target, "root")
                self.assertFalse(list_mode)
                self.assertEqual(filter_value, "RepoPromptTests.ExampleTests")
                return runs.pop(0)

            with (
                mock.patch.object(optimizer, "git_metadata", return_value={"commit": "c" * 40, "working_tree": ""}),
                mock.patch.object(optimizer, "measurement_source_guard_fingerprint", return_value="same-source"),
                mock.patch.object(optimizer, "run_conductor", side_effect=fake_run_conductor),
                mock.patch.object(optimizer, "utc_now", return_value="2026-07-03T00:00:00+00:00"),
                self.assertRaisesRegex(optimizer.OptimizerError, "focused-cost produced no valid samples") as raised,
            ):
                optimizer.focused_cost(
                    repo_root=root,
                    target="root",
                    filter_value="RepoPromptTests.ExampleTests",
                    samples_requested=2,
                    label="zero-valid",
                    scoreboard=scoreboard,
                    output=output,
                    progress_sink=None,
                )

            message = str(raised.exception)
            self.assertIn("sample 1: test exit 1", message)
            self.assertIn("filtered baseline produced no parsed XCTest timings", message)
            self.assertIn("sample 2: test exit 2", message)
            self.assertFalse(output.exists())
            self.assertFalse(scoreboard.exists())

    def test_focused_cost_requires_filter_and_positive_samples(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(optimizer.OptimizerError, "--filter is required"):
                optimizer.focused_cost(
                    repo_root=root,
                    target="root",
                    filter_value="",
                    samples_requested=1,
                    label="missing-filter",
                    scoreboard=root / "scoreboard.md",
                    output=root / "out.json",
                    progress_sink=None,
                )
            with self.assertRaisesRegex(optimizer.OptimizerError, "--samples must be greater than zero"):
                optimizer.focused_cost(
                    repo_root=root,
                    target="root",
                    filter_value="RepoPromptTests.ExampleTests",
                    samples_requested=0,
                    label="zero-samples",
                    scoreboard=root / "scoreboard.md",
                    output=root / "out.json",
                    progress_sink=None,
                )

    def test_parser_exposes_focused_cost_options(self) -> None:
        help_text = io.StringIO()
        parser = optimizer.build_parser()
        with contextlib.redirect_stdout(help_text), self.assertRaises(SystemExit) as raised:
            parser.parse_args(["focused-cost", "--help"])

        self.assertEqual(raised.exception.code, 0)
        text = help_text.getvalue()
        for option in (
            "--target",
            "--filter",
            "--samples",
            "--label",
            "--scoreboard",
            "--output",
            "--source-change-guard",
        ):
            self.assertIn(option, text)


class CombinedBaselineTests(unittest.TestCase):
    def test_combine_baselines_marks_fewer_than_three_valid_samples_unreliable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_one = root / "one.log"
            log_two = root / "two.log"
            log_one.write_text("Test Case 'RepoPromptTests.Suite.testOne' passed after 2.000 seconds.\n", encoding="utf-8")
            log_two.write_text("Test Case 'RepoPromptTests.Suite.testOne' passed after 4.000 seconds.\n", encoding="utf-8")
            paths = []
            for index, (seconds, valid, log) in enumerate(
                [(10.0, True, log_one), (20.0, False, root / "invalid.log"), (14.0, True, log_two)],
                start=1,
            ):
                path = root / f"baseline-{index}.json"
                path.write_text(
                    json.dumps(
                        {
                            "target": "root",
                            "samples": [
                                {
                                    "command": ["./conductor", "test", "--json"],
                                    "process_exit_code": 0 if valid else 130,
                                    "state": "completed" if valid else "canceled",
                                    "exit_code": 0 if valid else 130,
                                    "execution_seconds": seconds,
                                    "valid": valid,
                                    "log_path": str(log),
                                    "invalid_reasons": [] if valid else ["canceled"],
                                }
                            ],
                        }
                    ),
                    encoding="utf-8",
                )
                paths.append(path)

            combined = optimizer.combine_baselines(paths)

        self.assertEqual(combined["summary"]["attempts"], 3)
        self.assertEqual(combined["summary"]["valid_samples"], 2)
        self.assertFalse(combined["summary"]["reliable"])
        self.assertEqual(combined["scope"], "complete")
        self.assertIsNone(combined["filter"])
        self.assertEqual(combined["source_guard"]["kind"], optimizer.SOURCE_GUARD_CONTENT)
        self.assertEqual(combined["summary"]["median_seconds"], 12.0)
        self.assertEqual(combined["summary"]["observed_p95_seconds"], 14.0)
        self.assertEqual(combined["slowest_suites"][0]["median_aggregate_seconds"], 3.0)
        self.assertEqual(combined["slowest_tests"][0]["median_seconds"], 3.0)

    def test_combine_baselines_rejects_mixed_scope_filter_or_guard(self) -> None:
        def artifact(
            root: Path,
            name: str,
            *,
            scope: str = "complete",
            filter_value: str | None = None,
            test_product: str | None = None,
            guard: str = optimizer.SOURCE_GUARD_CONTENT,
        ) -> Path:
            path = root / f"{name}.json"
            path.write_text(
                json.dumps(
                    {
                        "target": "root",
                        "scope": scope,
                        "filter": filter_value,
                        "test_product": test_product,
                        "source_guard": {"kind": guard},
                        "samples": [
                            {
                                "command": ["/repo/conductor", "test", "--json"],
                                "process_exit_code": 0,
                                "state": "completed",
                                "exit_code": 0,
                                "execution_seconds": 10.0,
                                "valid": True,
                                "log_path": str(root / "missing.log"),
                                "invalid_reasons": [],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            return path

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            complete = artifact(root, "complete")
            focused = artifact(root, "focused", scope="filtered", filter_value="RepoPromptTests.A")
            focused_other = artifact(root, "focused-other", scope="filtered", filter_value="RepoPromptTests.B")
            workspace_product = artifact(root, "workspace-product", test_product="RepoPromptWorkspaceTests")
            mcp_product = artifact(root, "mcp-product", test_product="RepoPromptMCPTests")
            metadata = artifact(root, "metadata", guard=optimizer.SOURCE_GUARD_METADATA)

            with self.assertRaisesRegex(optimizer.OptimizerError, "one scope"):
                optimizer.combine_baselines([complete, focused])
            with self.assertRaisesRegex(optimizer.OptimizerError, "one filter"):
                optimizer.combine_baselines([focused, focused_other])
            with self.assertRaisesRegex(optimizer.OptimizerError, "one test product"):
                optimizer.combine_baselines([workspace_product, mcp_product])
            with self.assertRaisesRegex(optimizer.OptimizerError, "one source change guard"):
                optimizer.combine_baselines([complete, metadata])

    def test_compare_baselines_reports_fractional_deltas(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before = root / "before.json"
            after = root / "after.json"
            before.write_text(json.dumps({"summary": {"median_seconds": 100, "observed_p95_seconds": 120}}), encoding="utf-8")
            after.write_text(json.dumps({"summary": {"median_seconds": 90, "observed_p95_seconds": 108}}), encoding="utf-8")

            comparison = optimizer.compare_baselines(before, after)

        self.assertEqual(comparison["median_delta_seconds"], -10.0)
        self.assertAlmostEqual(comparison["median_delta_fraction"], -0.1)
        self.assertAlmostEqual(comparison["p95_delta_fraction"], -0.1)


class AppendOnlyArtifactTests(unittest.TestCase):
    def payload(self, timestamp: str, log_path: str) -> dict:
        return {
            "timestamp": timestamp,
            "target": "provider",
            "label": "warm-baseline",
            "artifact": "/tmp/provider-baseline.json",
            "inventory": "/tmp/inventory.json",
            "scope": "complete",
            "filter": None,
            "build_before_samples": False,
            "primary_metric_eligible": False,
            "source_guard": {"kind": optimizer.SOURCE_GUARD_METADATA},
            "command": ["./conductor", "provider-test", "--json"],
            "git": {"commit": "a" * 40, "working_tree": ""},
            "samples": [
                {
                    "index": 1,
                    "valid": True,
                    "execution_seconds": 1.0,
                    "build": None,
                    "queue_wait_seconds": 0.1,
                    "state": "completed",
                    "exit_code": 0,
                    "measurement_invalid": False,
                    "log_path": log_path,
                    "invalid_reasons": [],
                }
            ],
            "summary": {
                "valid_samples": 1,
                "invalid_samples": 0,
                "median_seconds": 1.0,
                "observed_p95_seconds": 1.0,
                "relative_mad": 0.0,
                "noise_classification": "stable",
            },
            "slowest_suites": [],
            "slowest_tests": [],
        }

    def test_scoreboard_appends_without_rewriting_prior_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "scoreboard.md"
            optimizer.append_baseline_scoreboard(path, self.payload("2026-06-16T10:00:00Z", "/one.log"), {"root": 2, "provider": 1})
            first = path.read_text(encoding="utf-8")
            optimizer.append_baseline_scoreboard(path, self.payload("2026-06-16T11:00:00Z", "/two.log"), {"root": 2, "provider": 1})
            second = path.read_text(encoding="utf-8")

        self.assertTrue(second.startswith(first))
        self.assertIn("/one.log", second)
        self.assertIn("/two.log", second)
        self.assertIn("Source-change guard: `metadata`", second)
        self.assertIn("Test product: ``", second)
        self.assertIn("Build before samples: no", second)
        self.assertIn("| Sample | Valid | Build seconds | Test execution seconds |", second)
        self.assertIn("Primary metric eligible: no", second)

    def test_json_artifacts_refuse_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "artifact.json"
            optimizer.write_json_new(path, {"one": 1})
            with self.assertRaisesRegex(optimizer.OptimizerError, "refusing to overwrite"):
                optimizer.write_json_new(path, {"two": 2})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"one": 1})


if __name__ == "__main__":
    unittest.main()
