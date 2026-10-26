#!/usr/bin/env python3
"""Exercise the shipped source-layout resource check with synthetic manifests."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("source_layout_guardrails.sh")


class ResourceGuardTests(unittest.TestCase):
    def run_guard(self, manifest: str) -> subprocess.CompletedProcess[str]:
        script = SCRIPT.read_text(encoding="utf-8")
        helper = script[script.index("print_matches() {"):].split("\n}\n", 1)[0] + "\n}\n"
        check = script[script.index('print_matches \\\n  "production target declares SwiftPM resources'):]
        check = check.split("\nprint_matches \\\n", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Package.swift").write_text(manifest, encoding="utf-8")
            return subprocess.run(
                ["bash", "-c", "failures=0; fail() { failures=$((failures + 1)); }; " +
                 helper + check + "\nexit $failures"],
                cwd=directory, text=True, capture_output=True, check=False,
            )

    def test_production_resources_fail(self) -> None:
        result = self.run_guard('.target(\n name: "Production",\n resources: [.copy("Resources")]\n)\n')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("resources:", result.stderr)

    def test_test_resources_pass(self) -> None:
        result = self.run_guard('.testTarget(\n name: "FixtureTests",\n resources: [.copy("Fixtures")]\n)\n')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
