#!/usr/bin/env python3
"""Pure self-tests for the CI app-test runner."""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import ci_app_test_runner as runner  # noqa: E402


class TestDiscoveryTests(unittest.TestCase):
    def test_parse_suite_methods_deduplicates_and_sorts(self) -> None:
        output = "\n".join(
            [
                "RepoPromptTests.SecondTests/testB",
                "noise",
                "RepoPromptTests.FirstTests/testZ",
                "RepoPromptTests.FirstTests/testA",
                "RepoPromptTests.FirstTests/testA",
            ]
        )

        self.assertEqual(
            runner.parse_suite_methods(output),
            {
                "RepoPromptTests.FirstTests": (
                    "RepoPromptTests.FirstTests/testA",
                    "RepoPromptTests.FirstTests/testZ",
                ),
                "RepoPromptTests.SecondTests": (
                    "RepoPromptTests.SecondTests/testB",
                ),
            },
        )

    def test_invalid_shard_arguments_are_rejected(self) -> None:
        invalid_arguments = ((0, 1), (2, 0), (2, 3))
        for shard_count, shard_index in invalid_arguments:
            with self.subTest(
                shard_count=shard_count,
                shard_index=shard_index,
            ):
                with self.assertRaises(ValueError):
                    runner.validate_shard_args(shard_count, shard_index)

        with self.assertRaisesRegex(ValueError, "greater than zero"):
            runner.assign_suites_to_shards({}, 0)

    def test_lpt_sharding_is_deterministic_balanced_and_exhaustive(self) -> None:
        counts = {
            "RepoPromptTests.A": 8,
            "RepoPromptTests.B": 7,
            "RepoPromptTests.C": 4,
            "RepoPromptTests.D": 3,
            "RepoPromptTests.E": 2,
        }

        shards, loads = runner.assign_suites_to_shards(counts, 2)

        self.assertEqual(loads, (13, 11))
        self.assertLessEqual(max(loads) - min(loads), 2)
        self.assertEqual(set(shards[0] + shards[1]), set(counts))
        self.assertEqual(
            runner.assign_suites_to_shards(dict(reversed(counts.items())), 2),
            (shards, loads),
        )

class TestBundleResolutionTests(unittest.TestCase):
    def test_discover_test_bundles_parses_show_bin_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bin_path = Path(directory)
            first = bin_path / "RepoPromptTests.xctest"
            second = bin_path / "RepoPromptCodeMapCoreTests.xctest"
            first.mkdir()
            second.mkdir()
            completed = subprocess.CompletedProcess(
                args=["swift", "build", "--show-bin-path"],
                returncode=0,
                stdout=f"{bin_path}\n",
                stderr="",
            )
            with mock.patch.object(runner.subprocess, "run", return_value=completed):
                discovered = runner.discover_test_bundles("swift", None)

        self.assertEqual(
            discovered,
            {
                "RepoPromptCodeMapCoreTests": second,
                "RepoPromptTests": first,
            },
        )

    def test_unique_package_bundle_is_preferred(self) -> None:
        package_bundle = Path("/tmp/RepoPromptPackageTests.xctest")
        discovered = {
            "RepoPromptPackageTests": package_bundle,
            "RepoPromptTests": Path("/tmp/RepoPromptTests.xctest"),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )

        self.assertEqual(selection.package_bundle, package_bundle)
        self.assertEqual(selection.target_bundles, {})

    def test_target_bundle_resolution_and_missing_target_diagnostic(self) -> None:
        root_bundle = Path("/tmp/RepoPromptTests.xctest")
        discovered = {
            "RepoPromptTests": root_bundle,
            "RepoPromptCodeMapCoreTests": Path(
                "/tmp/RepoPromptCodeMapCoreTests.xctest"
            ),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )
            with self.assertRaisesRegex(
                ValueError,
                r"missing XCTest bundles for selected targets: \['MissingTests'\]",
            ):
                runner.resolve_bundle_selection(
                    swift_binary="swift",
                    cwd=None,
                    suites=("MissingTests.ParserTests",),
                )

        self.assertEqual(
            selection.target_bundles,
            {"RepoPromptTests": root_bundle},
        )

    def test_command_construction_uses_xctest_or_swift_fallback(self) -> None:
        xctest_selection = runner.BundleSelection(
            None,
            {"RepoPromptTests": Path("/tmp/RepoPromptTests.xctest")},
            ("/usr/bin/xctest",),
        )
        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="swift",
                bundle_selection=xctest_selection,
            ),
            (
                "/usr/bin/xctest",
                "-XCTest",
                "RepoPromptTests.ParserContractTests",
                "/tmp/RepoPromptTests.xctest",
            ),
        )

        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="custom-swift",
                bundle_selection=runner.BundleSelection(None, {}, None),
            ),
            (
                "custom-swift",
                "test",
                "--skip-build",
                "--filter",
                "RepoPromptTests.ParserContractTests",
            ),
        )


class TestExecutionTests(unittest.TestCase):
    def empty_bundle_selection(self) -> runner.BundleSelection:
        return runner.BundleSelection(None, {}, None)

    def test_suite_environment_preserves_inherited_values_and_replaces_state(self) -> None:
        inherited = {
            "PATH": "/usr/bin",
            "CUSTOM_TOKEN": "preserved",
            "HOME": "/old/home",
            "CFFIXED_USER_HOME": "/old/fixed-home",
            "TMPDIR": "/old/tmpdir",
            "TMP": "/old/tmp",
            "TEMP": "/old/temp",
            "XDG_CONFIG_HOME": "/old/config",
            "XDG_CACHE_HOME": "/old/cache",
            "XDG_DATA_HOME": "/old/data",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.FirstTests",
                inherited,
            )
            second = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.SecondTests",
                inherited,
            )

            self.assertNotEqual(first["HOME"], second["HOME"])
            self.assertEqual(first["HOME"], first["CFFIXED_USER_HOME"])
            self.assertEqual(first["TMPDIR"], first["TMP"])
            self.assertEqual(first["TMPDIR"], first["TEMP"])
            self.assertEqual(first["PATH"], "/usr/bin")
            self.assertEqual(first["CUSTOM_TOKEN"], "preserved")
            for key in (
                "HOME",
                "TMPDIR",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "XDG_DATA_HOME",
            ):
                self.assertTrue(Path(first[key]).is_dir(), key)
                self.assertNotEqual(first[key], inherited[key])

    def test_runner_stops_on_first_failure(self) -> None:
        calls: list[tuple[str, ...]] = []

        def executor(command, _cwd, _environment) -> int:
            calls.append(tuple(command))
            return 9

        with tempfile.TemporaryDirectory() as directory:
            result = runner.run_selected_suites(
                ("RepoPromptTests.FirstTests", "RepoPromptTests.SecondTests"),
                swift_binary="swift",
                cwd=None,
                bundle_selection=self.empty_bundle_selection(),
                sandbox_root=Path(directory),
                executor=executor,
                output=io.StringIO(),
            )

        self.assertEqual(result, 9)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], "RepoPromptTests.FirstTests")

if __name__ == "__main__":
    unittest.main()
