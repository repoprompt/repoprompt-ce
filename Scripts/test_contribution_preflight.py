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


if __name__ == "__main__":
    unittest.main()
