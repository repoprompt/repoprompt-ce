#!/usr/bin/env python3
"""Cross-target self-tests for the CI source policy."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import ci_test_policy as policy  # noqa: E402


class CrossTargetSourcePolicyTests(unittest.TestCase):
    def test_scans_every_root_test_target_with_the_correct_suite_namespace(self) -> None:
        sources = {
            "RepoPromptTests/AppTimerTests.swift": (
                "final class AppTimerTests: XCTestCase {\n"
                "    func testTimer() async { Task.sleep(nanoseconds: 1) }\n"
                "}\n"
            ),
            "RepoPromptDomainRuntimeTests/DomainTimerTests.swift": (
                "final class DomainTimerTests: XCTestCase {\n"
                "    func testTimer() async { Task.sleep(nanoseconds: 1) }\n"
                "}\n"
            ),
            "RepoPromptCodeMapCoreTests/ParserTests.swift": (
                "final class ParserTests: XCTestCase {\n"
                "    func testParse() {}\n"
                "}\n"
            ),
        }

        with synthetic_repository(sources) as repository_root:
            source_policy = policy.scan_source_test_policy(repository_root)

        self.assertEqual(
            tuple(source_policy.integration_reasons),
            (
                "RepoPromptDomainRuntimeTests.DomainTimerTests",
                "RepoPromptTests.AppTimerTests",
            ),
        )
        self.assertEqual(
            {
                occurrence.path.parent.name: occurrence.suites
                for occurrence in source_policy.wait_occurrences
            },
            {
                "RepoPromptDomainRuntimeTests": (
                    "RepoPromptDomainRuntimeTests.DomainTimerTests",
                ),
                "RepoPromptTests": ("RepoPromptTests.AppTimerTests",),
            },
        )
        self.assertEqual(source_policy.unmapped_wait_occurrences, ())
        self.assertEqual(
            policy.classify_suite(
                "RepoPromptDomainRuntimeTests.DomainTimerTests",
                source_policy.integration_reasons,
            ).tier,
            policy.INTEGRATION_TIER,
        )
        self.assertEqual(
            policy.classify_suite(
                "RepoPromptCodeMapCoreTests.ParserTests",
                source_policy.integration_reasons,
            ).tier,
            policy.CONTRACT_TIER,
        )

    def test_extension_only_source_uses_its_own_test_target(self) -> None:
        sources = {
            "RepoPromptDomainRuntimeTests/DomainTiming.swift": (
                "extension DomainRuntimeTests {\n"
                "    func testTiming() async { Task.sleep(nanoseconds: 1) }\n"
                "}\n"
            ),
        }

        with synthetic_repository(sources) as repository_root:
            source_policy = policy.scan_source_test_policy(repository_root)

        self.assertEqual(
            tuple(source_policy.integration_reasons),
            ("RepoPromptDomainRuntimeTests.DomainRuntimeTests",),
        )
        self.assertEqual(
            source_policy.wait_occurrences[0].suites,
            ("RepoPromptDomainRuntimeTests.DomainRuntimeTests",),
        )

    def test_files_outside_a_test_target_remain_unmapped(self) -> None:
        sources = {
            "LooseTimer.swift": "Task.sleep(nanoseconds: 1)\n",
            "Fixtures/TimerFixture.swift": "Task.sleep(nanoseconds: 1)\n",
        }

        with synthetic_repository(sources) as repository_root:
            source_policy = policy.scan_source_test_policy(repository_root)

        self.assertEqual(source_policy.integration_reasons, {})
        self.assertEqual(len(source_policy.unmapped_wait_occurrences), 2)
        self.assertTrue(
            all(
                occurrence.suites == ()
                for occurrrence in source_policy.unmapped_wait_occurrences
            )
        )


class MissingTestsRootTests(unittest.TestCase):
    def test_missing_tests_root_reports_the_complete_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository_root = Path(directory)
            with self.assertRaisesRegex(FileNotFoundError, r"missing tests root: .*Tests"):
                policy.scan_source_test_policy(repository_root)


def synthetic_repository(sources: dict[str, str]):
    class SyntheticRepository:
        def __enter__(self) -> Path:
            self.temporary_directory = tempfile.TemporaryDirectory()
            repository_root = Path(self.temporary_directory.name)
            tests_root = repository_root / policy.TESTS_ROOT
            tests_root.mkdir(parents=True)
            for relative_path, source in sources.items():
                path = tests_root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")
            self.repository_root = repository_root
            return repository_root

        def __exit__(self, exc_type, exc_value, traceback) -> None:
            self.temporary_directory.cleanup()

    return SyntheticRepository()


if __name__ == "__main__":
    unittest.main()
