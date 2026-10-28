#!/usr/bin/env python3
"""Regression checks for contribution preflight path selection."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


PREFLIGHT = Path(__file__).resolve().parent.parent / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"


class PathSelectionTests(unittest.TestCase):
    def test_shared_test_support_selects_root_tests(self) -> None:
        script = PREFLIGHT.read_text(encoding="utf-8")
        match = re.search(r"local root_test_paths_pattern='([^']+)'", script)
        self.assertIsNotNone(match)
        pattern = match.group(1)
        for path in (
            "Tests/RepoPromptTestSupport/RepoRoot.swift",
            "Tests/RepoPromptTests/Helpers/RepoRoot.swift",
            "Tests/RepoPromptMCPCoreTests/MCPTests.swift",
        ):
            result = subprocess.run(
                ["bash", "-c", '[[ "$1" =~ $2 ]]', "selector", path, pattern], check=False,
            )
            self.assertEqual(result.returncode, 0, path)
        result = subprocess.run(
            ["bash", "-c", '[[ "$1" =~ $2 ]]', "selector", "Sources/RepoPromptMCPCore/MCPCLIProcess.swift", pattern],
            check=False,
        )
        self.assertEqual(result.returncode, 1)

    def _assert_path_selection(self, selector: str, cases: tuple[tuple[str, int], ...]) -> None:
        script = PREFLIGHT.read_text(encoding="utf-8")
        match = re.search(rf"local {selector}='([^']+)'", script)
        self.assertIsNotNone(match)
        pattern = match.group(1)
        for path, expected_returncode in cases:
            with self.subTest(selector=selector, path=path):
                result = subprocess.run(
                    ["bash", "-c", '[[ "$1" =~ $2 ]]', "selector", path, pattern], check=False,
                )
                self.assertEqual(result.returncode, expected_returncode)

    def test_conductor_test_family_selects_selftests(self) -> None:
        self._assert_path_selection("control_plane_paths_pattern", (
            ("Scripts/test_conductor_diagnostics.py", 0),
            ("Scripts/test_conductor_heavy_admission.py", 0),
            ("Scripts/test_conductor_job_phases.py", 0),
            ("Scripts/test_conductor_job_timings.py", 0),
            ("Scripts/test_conductor_cache_retry.py", 0),
            ("Scripts/test_conductor_future_probe.py", 0),
            ("Scripts/test_conductor_lifecycle.py", 0),
            ("Scripts/test_conductor_output.py", 0),
            ("Scripts/test_conductor_high_output.py", 0),
        ))

    def test_conductor_test_family_rejects_out_of_scope_paths(self) -> None:
        self._assert_path_selection("control_plane_paths_pattern", (
            ("Scripts/test_conductor_.py", 1),
            ("Scripts/test_conductor_nested/probe.py", 1),
            ("Scripts/nested/test_conductor_probe.py", 1),
            ("Scripts/test_conductor.py", 1),
            ("Scripts/test_conductor_probe.pyc", 1),
            ("Scripts/test_conductor_probe.py.bak", 1),
            ("Scripts/test_conductor_probeXpy", 1),
            ("Other/Scripts/test_conductor_probe.py", 1),
            ("./Scripts/test_conductor_probe.py", 1),
            ("Scripts/test_cache_inventory.py", 1),
            ("Scripts/test_ci_app_test_runner.py", 1),
            ("Tests/test_conductor_probe.py", 1),
        ))

    def test_existing_selection_routes_remain_unchanged(self) -> None:
        self._assert_path_selection("control_plane_paths_pattern", (
            ("Scripts/conductor.py", 0),
            ("Scripts/conductor_diagnostics.py", 0),
            ("Scripts/guardrails.sh", 0),
            ("Scripts/test_contribution_preflight.py", 0),
            (".agents/skills/rpce-contribution-check/scripts/preflight.sh", 0),
            (".agents/skills/rpce-contribution-check/scripts/preflight_timing.py", 0),
            ("Makefile", 0),
            ("Scripts/ci_app_test_runner.py", 1),
            (".github/workflows/ci.yml", 1),
        ))
        self._assert_path_selection("ci_app_test_runner_paths_pattern", (
            ("Scripts/ci_app_test_runner.py", 0),
            ("Scripts/test_ci_app_test_runner.py", 0),
            ("Scripts/ci_process_session.py", 0),
            ("Scripts/ci_resolve_packages.py", 0),
            ("Scripts/test_ci_resolve_packages.py", 0),
            (".github/workflows/ci.yml", 0),
            ("Scripts/test_conductor_future_probe.py", 1),
            ("Scripts/ci_process_session.py.bak", 1),
        ))
        self._assert_path_selection("xcode_full_validation_paths_pattern", (
            ("Makefile", 0),
            ("Scripts/test_conductor_future_probe.py", 1),
        ))


if __name__ == "__main__":
    unittest.main()
