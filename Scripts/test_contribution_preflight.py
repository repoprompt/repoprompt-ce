#!/usr/bin/env python3
"""Regression tests for the RepoPrompt CE contribution preflight lanes."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
PREFLIGHT_SOURCE = REPO_ROOT / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"

GUARDRAILS_TARGET = "guardrails"
CONDUCTOR_SELFTEST_TARGET = "conductor-selftest"
CI_APP_TEST_RUNNER_SELFTEST_TARGET = "ci-app-test-runner-selftest"
SWIFT_LINT_TARGET = "dev-lint"
ROOT_TEST_TARGET = "dev-test"
PROVIDER_TEST_TARGET = "dev-provider-test"
REPOPROMPT_BUILD_TARGET = "dev-swift-build PRODUCT=RepoPrompt"
MCP_BUILD_TARGET = "dev-swift-build PRODUCT=repoprompt-mcp"
XCODE_GENERATOR_TEST_TARGET = "xcode-generator-test"
XCODE_VALIDATE_TARGET = "xcode-validate"
HEAVYWEIGHT_MAKE_TARGETS = [
    CONDUCTOR_SELFTEST_TARGET,
    CI_APP_TEST_RUNNER_SELFTEST_TARGET,
    SWIFT_LINT_TARGET,
    ROOT_TEST_TARGET,
    PROVIDER_TEST_TARGET,
    REPOPROMPT_BUILD_TARGET,
    MCP_BUILD_TARGET,
    XCODE_GENERATOR_TEST_TARGET,
    XCODE_VALIDATE_TARGET,
]


class ContributionPreflightTests(unittest.TestCase):
    def run_git(self, repo: Path, *args: str) -> None:
        subprocess.run(["git", *args], cwd=repo, check=True, text=True, capture_output=True)

    def write_stub(self, bin_dir: Path, name: str, log_env_name: str) -> None:
        stub = bin_dir / name
        stub.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"printf '%s\\n' \"$*\" >> \"${{{log_env_name}:?}}\"\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)

    def create_repo(self, root: Path, *, outgoing_path: str | None = None) -> tuple[Path, Path, dict[str, str]]:
        repo = root / "work"
        repo.mkdir()
        self.run_git(repo, "init", "-b", "main")
        self.run_git(repo, "config", "user.name", "Preflight Tests")
        self.run_git(repo, "config", "user.email", "preflight-tests@example.invalid")

        preflight = repo / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"
        preflight.parent.mkdir(parents=True)
        shutil.copy2(PREFLIGHT_SOURCE, preflight)
        preflight.chmod(0o755)
        (repo / "README.md").write_text("fixture\n", encoding="utf-8")
        self.run_git(repo, "add", ".")
        self.run_git(repo, "commit", "-m", "initial")
        self.run_git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.run_git(repo, "checkout", "-b", "feature")

        if outgoing_path is not None:
            target = repo / outgoing_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// fixture\n", encoding="utf-8")
            self.run_git(repo, "add", outgoing_path)
            self.run_git(repo, "commit", "-m", "feature change")

        bin_dir = root / "bin"
        bin_dir.mkdir()
        make_log = root / "make.log"
        gitleaks_log = root / "gitleaks.log"
        self.write_stub(bin_dir, "make", "RPCE_STUB_MAKE_LOG")
        self.write_stub(bin_dir, "gitleaks", "RPCE_STUB_GITLEAKS_LOG")

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        env["RPCE_STUB_MAKE_LOG"] = str(make_log)
        env["RPCE_STUB_GITLEAKS_LOG"] = str(gitleaks_log)
        env["TMPDIR"] = str(root)
        return repo, preflight, env

    def run_preflight(self, repo: Path, preflight: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(preflight), *args],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def log_lines(self, env: dict[str, str], name: str) -> list[str]:
        path = Path(env[name])
        if not path.exists():
            return []
        return path.read_text(encoding="utf-8").splitlines()

    def make_lines(self, env: dict[str, str]) -> list[str]:
        return self.log_lines(env, "RPCE_STUB_MAKE_LOG")

    def gitleaks_lines(self, env: dict[str, str]) -> list[str]:
        return self.log_lines(env, "RPCE_STUB_GITLEAKS_LOG")

    def assert_make_lines_equal(self, env: dict[str, str], expected: list[str]) -> None:
        self.assertEqual(self.make_lines(env), expected)

    def assert_no_heavyweight_make_targets(self, make_lines: list[str]) -> None:
        for target in HEAVYWEIGHT_MAKE_TARGETS:
            self.assertNotIn(target, make_lines)

    def test_default_push_is_safety_only_for_swift_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "push")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            make_lines = self.make_lines(env)
            self.assertEqual(make_lines, [GUARDRAILS_TARGET])
            self.assert_no_heavyweight_make_targets(make_lines)
            self.assertTrue(any(line.startswith("git ") and "--log-opts=" in line for line in self.gitleaks_lines(env)))
            self.assertIn("pr-ready", result.stdout)
            self.assertIn("Heavyweight lint/test/build lanes were not run", result.stdout)

    def test_pr_ready_runs_path_selected_heavyweight_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(
                env,
                [
                    GUARDRAILS_TARGET,
                    SWIFT_LINT_TARGET,
                    ROOT_TEST_TARGET,
                    REPOPROMPT_BUILD_TARGET,
                ],
            )
            self.assertIn("PR-ready preflight passed", result.stdout)

    def test_pr_ready_runs_conductor_selftest_for_preflight_control_plane_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Scripts/test_contribution_preflight.py"
            )

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET, CONDUCTOR_SELFTEST_TARGET])

    def test_pr_ready_runs_ci_app_test_runner_selftest_for_hosted_ci_runner_changes(self) -> None:
        cases = [
            ("runner", "Scripts/ci_app_test_runner.py"),
            ("runner tests", "Scripts/test_ci_app_test_runner.py"),
            ("hosted workflow", ".github/workflows/ci.yml"),
        ]

        for name, outgoing_path in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as tmp:
                    repo, preflight, env = self.create_repo(Path(tmp), outgoing_path=outgoing_path)

                    result = self.run_preflight(repo, preflight, env, "pr-ready")

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assert_make_lines_equal(env, [GUARDRAILS_TARGET, CI_APP_TEST_RUNNER_SELFTEST_TARGET])
                    self.assertIn("PR-ready preflight passed", result.stdout)

    def test_pr_ready_runs_xcode_validation_for_workspace_boundary_changes(self) -> None:
        cases = [
            (
                "generator",
                "Scripts/generate_xcode_workspace.py",
                [GUARDRAILS_TARGET, XCODE_GENERATOR_TEST_TARGET, XCODE_VALIDATE_TARGET],
            ),
            (
                "workflow wrapper",
                "Scripts/xcode_developer_workflow.sh",
                [GUARDRAILS_TARGET, XCODE_GENERATOR_TEST_TARGET, XCODE_VALIDATE_TARGET],
            ),
            (
                "package lockfile",
                "Package.resolved",
                [GUARDRAILS_TARGET, XCODE_GENERATOR_TEST_TARGET, XCODE_VALIDATE_TARGET],
            ),
            (
                "hosted workflow",
                ".github/workflows/xcode-workspace.yml",
                [GUARDRAILS_TARGET, XCODE_GENERATOR_TEST_TARGET, XCODE_VALIDATE_TARGET],
            ),
            (
                "package manifest",
                "Package.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, XCODE_GENERATOR_TEST_TARGET, XCODE_VALIDATE_TARGET],
            ),
            (
                "makefile targets",
                "Makefile",
                [
                    GUARDRAILS_TARGET,
                    CONDUCTOR_SELFTEST_TARGET,
                    XCODE_GENERATOR_TEST_TARGET,
                    XCODE_VALIDATE_TARGET,
                ],
            ),
        ]

        for name, outgoing_path, expected_make_lines in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as tmp:
                    repo, preflight, env = self.create_repo(Path(tmp), outgoing_path=outgoing_path)

                    result = self.run_preflight(repo, preflight, env, "pr-ready")

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assert_make_lines_equal(env, expected_make_lines)
                    self.assertIn("PR-ready preflight passed", result.stdout)

    def test_pr_ready_runs_generator_tests_only_for_generator_test_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Scripts/test_xcode_workspace_generator.py"
            )

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET, XCODE_GENERATOR_TEST_TARGET])
            self.assertNotIn(XCODE_VALIDATE_TARGET, self.make_lines(env))

    def test_pr_ready_keeps_xcode_architecture_docs_guardrails_only_locally(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="docs/architecture/xcode-workspace.md"
            )

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET])
            self.assertNotIn(XCODE_GENERATOR_TEST_TARGET, self.make_lines(env))
            self.assertNotIn(XCODE_VALIDATE_TARGET, self.make_lines(env))

    def test_pr_ready_selects_expected_heavyweight_targets_by_changed_path(self) -> None:
        cases = [
            (
                "provider Swift path",
                "Packages/RepoPromptAgentProviders/Sources/Example.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, PROVIDER_TEST_TARGET],
            ),
            (
                "root test Swift path",
                "Tests/RepoPromptTests/ExampleTests.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, ROOT_TEST_TARGET],
            ),
            (
                "MCP Swift path",
                "Sources/RepoPromptMCP/Example.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, MCP_BUILD_TARGET],
            ),
            (
                "shared Swift path",
                "Sources/RepoPromptShared/MCP/Example.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, MCP_BUILD_TARGET],
            ),
            (
                "non-selected docs path",
                "docs/preflight-note.md",
                [GUARDRAILS_TARGET],
            ),
        ]

        for name, outgoing_path, expected_make_lines in cases:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as tmp:
                    repo, preflight, env = self.create_repo(Path(tmp), outgoing_path=outgoing_path)

                    result = self.run_preflight(repo, preflight, env, "pr-ready")

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assert_make_lines_equal(env, expected_make_lines)
                    self.assertIn("PR-ready preflight passed", result.stdout)

    def test_commit_scans_staged_index_without_push_or_heavy_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(Path(tmp))
            staged = repo / "staged.txt"
            staged.write_text("fixture\n", encoding="utf-8")
            self.run_git(repo, "add", "staged.txt")

            result = self.run_preflight(repo, preflight, env, "commit")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            make_lines = self.make_lines(env)
            self.assertEqual(make_lines, [GUARDRAILS_TARGET])
            self.assert_no_heavyweight_make_targets(make_lines)
            gitleaks_lines = self.gitleaks_lines(env)
            self.assertTrue(any(line.startswith("dir ") for line in gitleaks_lines))
            self.assertFalse(any(line.startswith("git ") for line in gitleaks_lines))

    def test_extra_arguments_fail_instead_of_silently_ignoring_full_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )

            result = self.run_preflight(repo, preflight, env, "push", "--full")

            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            self.assertIn("usage:", result.stderr + result.stdout)
            self.assertEqual(self.make_lines(env), [])
            self.assertEqual(self.gitleaks_lines(env), [])


if __name__ == "__main__":
    unittest.main()
