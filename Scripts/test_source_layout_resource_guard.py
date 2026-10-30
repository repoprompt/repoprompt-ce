#!/usr/bin/env python3
"""Exercise shipped source-layout resource and neutral-provider boundary checks."""

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


class DomainRuntimeProviderGuardTests(unittest.TestCase):
    def test_only_complete_neutral_token_is_exempt_even_on_mixed_lines(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        helpers = "\n".join(
            script[script.index(name + "() {"):].split("\n}\n", 1)[0] + "\n}\n"
            for name in ("print_matches", "domain_runtime_implementation_matches")
        )
        check = script[script.index('  print_matches \\\n    "RepoPromptDomainRuntime contains app/UI/provider implementation"'):]
        check = check.split("\n  print_matches \\\n", 1)[0]
        cases = [
            ("let kind: AgentProviderKind", 0),
            ("let kind: AgentProviderKind; let factory: AgentProviderFactory", 1),
            ("let kind: AgentProviderKind; class WindowState {}", 1),
            ("let kind: AgentProviderKindSuffix", 1),
            ("let kind: OtherAgentProviderKind", 1),
            ("import RepoPromptCodexProvider; let kind: AgentProviderKind", 1),
        ]
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory, "runtime")
            runtime.mkdir()
            for source, expected_exit in cases:
                with self.subTest(source=source):
                    Path(runtime, "Model.swift").write_text(source + "\n", encoding="utf-8")
                    result = subprocess.run(
                        ["bash", "-c", "set -o pipefail; failures=0; "
                         "fail() { failures=$((failures + 1)); }; domain_runtime_source_dir=runtime; " +
                         helpers + check + "\nexit $failures"],
                        cwd=directory, text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(result.returncode, expected_exit, result.stderr)


if __name__ == "__main__":
    unittest.main()
