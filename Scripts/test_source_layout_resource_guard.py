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


class M8ProviderGuardTests(unittest.TestCase):
    def test_provider_policy_and_neutral_consumer_boundaries(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        helper = script[script.index("print_matches() {"):].split("\n}\n", 1)[0] + "\n}\n"
        check = script.split("# M8 provider policy", 1)[1].split("# Swift class runtime names", 1)[0]
        check = "# M8 provider policy" + check
        targets = (
            "RepoPromptAIContracts", "RepoPromptAgentProviderContracts",
            "RepoPromptClaudeProvider", "RepoPromptCodexProvider",
            "RepoPromptACPProviders", "RepoPromptHTTPProviders",
        )
        consumers = (
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ClaudeIntegratedAgentModeRunner.swift",
            "Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeControllerEventListener.swift",
        )
        cases = [(f"Sources/{target}/Policy.swift", "let defaults = UserDefaults.standard", 1)
                 for target in targets]
        cases += [(path, f"import {target}", 1) for path in consumers
                  for target in (*targets[2:], "RepoPromptClaudeCompatibleProvider")]
        cases += [(path, source, 1) for path in consumers
                  for source in ("import struct RepoPromptClaudeCompatibleProvider.ClaudeCompatibleRuntimeConfig",
                                 "import RepoPromptClaudeCompatibleProvider;")]
        cases += [(path, "import RepoPromptAgentProviderContracts", 0) for path in consumers]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for target in targets:
                (root / "Sources" / target).mkdir(parents=True)
            for path in consumers:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("", encoding="utf-8")
            for path, source, expected in cases:
                with self.subTest(path=path, source=source):
                    fixture = root / path
                    fixture.write_text(source + "\n", encoding="utf-8")
                    result = subprocess.run(
                        ["bash", "-c", "failures=0; fail() { failures=$((failures + 1)); }; " +
                         helper + check + "\nexit $failures"],
                        cwd=root, text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)
                    fixture.write_text("", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
