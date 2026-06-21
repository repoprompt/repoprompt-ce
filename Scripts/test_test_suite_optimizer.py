#!/usr/bin/env python3
"""Deterministic tests for test_suite_optimizer.py."""

from __future__ import annotations

import csv
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
    def test_test_target_vocabulary_reserves_all_seven_prefixes(self) -> None:
        self.assertEqual(
            optimizer.TEST_TARGET_PREFIXES,
            (
                "root",
                "provider",
                "core",
                "core-macos",
                "posix",
                "syntax-c-bridge",
                "headless",
            ),
        )
        self.assertEqual(
            optimizer.TEST_TARGETS["syntax-c-bridge"].target_name,
            "RepoPromptSyntaxCBridgeTests",
        )
        self.assertEqual(
            optimizer.TEST_TARGETS["headless"].source_root,
            "Tests/RepoPromptHeadlessTests",
        )

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

    def test_parse_test_list_rejects_wrong_target_module(self) -> None:
        with self.assertRaisesRegex(optimizer.OptimizerError, "outside expected module"):
            optimizer.parse_test_list(
                "RepoPromptTests.ExampleTests/testWrongModule\n",
                "core",
            )

    def test_dump_package_targets_rejects_invalid_manifest_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            completed = optimizer.subprocess.CompletedProcess(
                args=["swift", "package", "dump-package"],
                returncode=0,
                stdout="not-json",
                stderr="",
            )
            with mock.patch.object(optimizer, "run_command", return_value=completed):
                with self.assertRaisesRegex(optimizer.OptimizerError, "returned invalid JSON"):
                    optimizer.dump_package_targets(root, "Package.swift")

    def test_run_conductor_wraps_missing_lane_with_target_and_operation(self) -> None:
        completed = optimizer.subprocess.CompletedProcess(
            args=["conductor", "headless-test"],
            returncode=2,
            stdout="",
            stderr="unknown operation",
        )
        with mock.patch.object(optimizer, "run_command", return_value=completed):
            with self.assertRaisesRegex(
                optimizer.OptimizerError,
                "headless test target RepoPromptHeadlessTests requires conductor operation 'headless-test'",
            ):
                optimizer.run_conductor(Path("/repo"), "headless", list_mode=True)


class TimingTests(unittest.TestCase):
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

    def test_suite_ranking_uses_median_aggregate_seconds(self) -> None:
        def sample(index: int, a: float, b: float) -> optimizer.Sample:
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
                timings=[
                    optimizer.TestCaseTiming("RepoPromptTests.A", "testOne", "passed", a),
                    optimizer.TestCaseTiming("RepoPromptTests.B", "testTwo", "passed", b),
                ],
            )

        ranking = optimizer.suite_ranking([sample(1, 1.0, 4.0), sample(2, 5.0, 4.0)])

        self.assertEqual(ranking[0]["suite"], "RepoPromptTests.B")
        self.assertEqual(ranking[0]["median_aggregate_seconds"], 4.0)
        self.assertEqual(ranking[1]["median_aggregate_seconds"], 3.0)
        self.assertEqual(ranking[1]["max_method_seconds"], 5.0)


class SourceAndLedgerTests(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        tests = root / "Tests" / "RepoPromptTests" / "MCP"
        tests.mkdir(parents=True)
        (tests / "ExampleTests.swift").write_text(
            "import XCTest\nfinal class ExampleTests: XCTestCase {\n"
            "    func testOne() {}\n}\n",
            encoding="utf-8",
        )

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

    def test_source_mapping_uses_dedicated_target_root_domain_and_layer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tests_root = root / "Tests" / "RepoPromptCoreTests" / "Models"
            tests_root.mkdir(parents=True)
            (tests_root / "CoreValueTests.swift").write_text(
                "import XCTest\nfinal class CoreValueTests: XCTestCase {\n"
                "    func testRoundTrip() {}\n}\n",
                encoding="utf-8",
            )
            tests = [
                optimizer.ListedTest(
                    "core",
                    "RepoPromptCoreTests.CoreValueTests",
                    "testRoundTrip",
                )
            ]

            locations = optimizer.map_test_sources(root, tests)
            rows = optimizer.ledger_rows(tests, locations)

        self.assertEqual(
            locations[tests[0].method_id].file,
            "Tests/RepoPromptCoreTests/Models/CoreValueTests.swift",
        )
        self.assertEqual(rows[0]["domain"], "Core/Models")
        self.assertEqual(rows[0]["layer"], "core_swiftpm")

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
                row["method_id"] = "root/RepoPromptTests.Suite/testOne"
                row["target"] = "root"
                writer.writerow(row)
                writer.writerow(row)

            with self.assertRaisesRegex(optimizer.OptimizerError, "duplicate method_id"):
                optimizer.read_ledger_ids(path)

    def test_ledger_accepts_all_reserved_prefixes_and_rejects_target_mismatch(self) -> None:
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
                for prefix in optimizer.TEST_TARGET_PREFIXES:
                    row = {column: "" for column in optimizer.LEDGER_COLUMNS}
                    module = optimizer.TEST_TARGETS[prefix].target_name
                    row["method_id"] = f"{prefix}/{module}.Suite/testOne"
                    row["target"] = prefix
                    writer.writerow(row)

            self.assertEqual(len(optimizer.read_ledger_ids(path)), 7)

            rows = path.read_text(encoding="utf-8").replace(
                "headless/RepoPromptHeadlessTests.Suite/testOne\theadless\t",
                "headless/RepoPromptHeadlessTests.Suite/testOne\troot\t",
            )
            path.write_text(rows, encoding="utf-8")
            with self.assertRaisesRegex(optimizer.OptimizerError, "does not match method_id prefix"):
                optimizer.read_ledger_ids(path)

    def test_ledger_rejects_prefix_with_wrong_target_module(self) -> None:
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
                row["method_id"] = "core/RepoPromptTests.Suite/testWrongModule"
                row["target"] = "core"
                writer.writerow(row)
            with self.assertRaisesRegex(optimizer.OptimizerError, "expected module"):
                optimizer.read_ledger_ids(path)


class ManifestAwareInventoryTests(unittest.TestCase):
    def make_manifests(self, root: Path, root_targets: list[str], provider: bool = True) -> None:
        self.root_targets = root_targets
        self.provider_declared = provider
        declarations = ",\n".join(
            f'        .testTarget(\n            name: "{name}", dependencies: []\n        )'
            for name in root_targets
        )
        (root / "Package.swift").write_text(
            f"let package = Package(targets: [\n{declarations}\n])\n",
            encoding="utf-8",
        )
        provider_manifest = root / "Packages" / "RepoPromptAgentProviders" / "Package.swift"
        provider_manifest.parent.mkdir(parents=True)
        provider_declaration = (
            '.testTarget(name: "RepoPromptClaudeCompatibleProviderTests", dependencies: [])'
            if provider
            else ""
        )
        provider_manifest.write_text(
            f"let package = Package(targets: [{provider_declaration}])\n",
            encoding="utf-8",
        )

    def dumped_targets(self, repo_root: Path, manifest: str) -> dict[str, dict]:
        names = (
            ["RepoPromptClaudeCompatibleProviderTests"]
            if manifest.startswith("Packages/") and self.provider_declared
            else self.root_targets if manifest == "Package.swift" else []
        )
        result: dict[str, dict] = {}
        for name in names:
            config = next(item for item in optimizer.TEST_TARGET_CONFIGS if item.target_name == name)
            package_root = (repo_root / manifest).parent
            path = (repo_root / config.source_root).relative_to(package_root)
            result[name] = {"name": name, "type": "test", "path": str(path)}
        return result

    def make_source(self, root: Path, relative_root: str, suite: str, method: str) -> None:
        source_root = root / relative_root
        source_root.mkdir(parents=True, exist_ok=True)
        (source_root / f"{suite}.swift").write_text(
            f"final class {suite}: XCTestCase {{\n    func {method}() {{}}\n}}\n",
            encoding="utf-8",
        )

    def make_run(self, target: str, listed_id: str) -> optimizer.ConductorRun:
        return optimizer.ConductorRun(
            command=["conductor", optimizer.TEST_TARGETS[target].conductor_operation, "--list", "--json"],
            process_exit_code=0,
            stdout="",
            stderr="",
            result={"state": "completed", "exitCode": 0, "logPath": f"/{target}.log"},
            log_text=listed_id + "\n",
        )

    def test_inventory_lists_only_declared_targets_and_reports_reserved_zero_counts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_manifests(root, ["RepoPromptTests"])
            self.make_source(root, "Tests/RepoPromptTests", "RootTests", "testRoot")
            self.make_source(
                root,
                "Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests",
                "ProviderTests",
                "testProvider",
            )
            runs = {
                "root": self.make_run("root", "RepoPromptTests.RootTests/testRoot"),
                "provider": self.make_run(
                    "provider",
                    "RepoPromptClaudeCompatibleProviderTests.ProviderTests/testProvider",
                ),
            }
            ledger = root / "generated.tsv"

            with (
                mock.patch.object(optimizer, "dump_package_targets", side_effect=self.dumped_targets),
                mock.patch.object(
                    optimizer,
                    "run_conductor",
                    side_effect=lambda repo, target, list_mode: runs[target],
                ) as run_conductor,
            ):
                payload = optimizer.inventory(root, ledger, None, force=False)

        self.assertEqual(payload["declared_targets"], ["root", "provider"])
        self.assertEqual(payload["counts"]["root"], 1)
        self.assertEqual(payload["counts"]["provider"], 1)
        self.assertEqual(payload["counts"]["core"], 0)
        self.assertEqual(payload["counts"]["headless"], 0)
        self.assertEqual(payload["counts"]["total"], 2)
        self.assertEqual(
            [call.args[1] for call in run_conductor.call_args_list],
            ["root", "provider"],
        )

    def test_declared_target_requires_nonempty_authoritative_list(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_manifests(root, ["RepoPromptTests", "RepoPromptCoreTests"], provider=False)
            self.make_source(root, "Tests/RepoPromptTests", "RootTests", "testRoot")
            runs = {
                "root": self.make_run("root", "RepoPromptTests.RootTests/testRoot"),
                "core": self.make_run("core", "build completed without test identifiers"),
            }

            with (
                mock.patch.object(optimizer, "dump_package_targets", side_effect=self.dumped_targets),
                mock.patch.object(
                    optimizer,
                    "run_conductor",
                    side_effect=lambda repo, target, list_mode: runs[target],
                ),
            ):
                with self.assertRaisesRegex(
                    optimizer.OptimizerError,
                    "no discoverable XCTest methods found in core test list",
                ):
                    optimizer.inventory(root, root / "generated.tsv", None, force=False)

    def test_declared_target_reports_missing_conductor_lane_by_reserved_operation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_manifests(root, ["RepoPromptCoreTests"], provider=False)
            failed = optimizer.ConductorRun(
                command=["conductor", "core-test", "--list", "--json"],
                process_exit_code=2,
                stdout="",
                stderr="unknown operation",
                result={"state": "failed", "exitCode": 2, "logPath": "/core.log"},
                log_text="",
            )
            with (
                mock.patch.object(optimizer, "dump_package_targets", side_effect=self.dumped_targets),
                mock.patch.object(optimizer, "run_conductor", return_value=failed),
            ):
                with self.assertRaisesRegex(
                    optimizer.OptimizerError,
                    "conductor operation 'core-test'",
                ):
                    optimizer.inventory(root, root / "generated.tsv", None, force=False)

    def test_declared_target_rejects_wrong_type_or_source_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_manifests(root, ["RepoPromptCoreTests"], provider=False)
            wrong_type = {
                "RepoPromptCoreTests": {
                    "name": "RepoPromptCoreTests",
                    "type": "regular",
                    "path": "Tests/RepoPromptCoreTests",
                }
            }
            with mock.patch.object(optimizer, "dump_package_targets", return_value=wrong_type):
                with self.assertRaisesRegex(optimizer.OptimizerError, "expected 'test'"):
                    optimizer.declared_test_targets(root)

            wrong_path = {
                "RepoPromptCoreTests": {
                    "name": "RepoPromptCoreTests",
                    "type": "test",
                    "path": "Tests/Wrong",
                }
            }
            with mock.patch.object(optimizer, "dump_package_targets", return_value=wrong_path):
                with self.assertRaisesRegex(optimizer.OptimizerError, "expected 'Tests/RepoPromptCoreTests'"):
                    optimizer.declared_test_targets(root)


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
        self.assertEqual(combined["summary"]["median_seconds"], 12.0)
        self.assertEqual(combined["summary"]["observed_p95_seconds"], 14.0)
        self.assertEqual(combined["slowest_suites"][0]["median_aggregate_seconds"], 3.0)

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
    def test_inventory_counts_load_all_reserved_targets_without_double_counting_total(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "inventory.json"
            counts = {prefix: index for index, prefix in enumerate(optimizer.TEST_TARGET_PREFIXES, start=1)}
            path.write_text(
                json.dumps({"counts": {**counts, "total": sum(counts.values())}}),
                encoding="utf-8",
            )

            self.assertEqual(optimizer.load_counts(path), counts)

    def payload(self, timestamp: str, log_path: str) -> dict:
        return {
            "timestamp": timestamp,
            "target": "provider",
            "label": "warm-baseline",
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

    def test_json_artifacts_refuse_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "artifact.json"
            optimizer.write_json_new(path, {"one": 1})
            with self.assertRaisesRegex(optimizer.OptimizerError, "refusing to overwrite"):
                optimizer.write_json_new(path, {"two": 2})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"one": 1})


if __name__ == "__main__":
    unittest.main()
