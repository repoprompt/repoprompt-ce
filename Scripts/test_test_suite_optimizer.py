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
        self.assertEqual(rows[0]["scenario_count"], "1")
        self.assertEqual(rows[0]["current_disposition"], "retain_pending_review")

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
            ) -> optimizer.ConductorRun:
                nonlocal run_count
                run_count += 1
                self.assertFalse(list_mode)
                self.assertEqual((target, filter_value), ("root", "RepoPromptTests.ExampleTests"))
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
            guard: str = optimizer.SOURCE_GUARD_CONTENT,
        ) -> Path:
            path = root / f"{name}.json"
            path.write_text(
                json.dumps(
                    {
                        "target": "root",
                        "scope": scope,
                        "filter": filter_value,
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
            metadata = artifact(root, "metadata", guard=optimizer.SOURCE_GUARD_METADATA)

            with self.assertRaisesRegex(optimizer.OptimizerError, "one scope"):
                optimizer.combine_baselines([complete, focused])
            with self.assertRaisesRegex(optimizer.OptimizerError, "one filter"):
                optimizer.combine_baselines([focused, focused_other])
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
            "primary_metric_eligible": False,
            "source_guard": {"kind": optimizer.SOURCE_GUARD_METADATA},
            "command": ["./conductor", "provider-test", "--json"],
            "git": {"commit": "a" * 40, "working_tree": ""},
            "samples": [
                {
                    "index": 1,
                    "valid": True,
                    "execution_seconds": 1.0,
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
