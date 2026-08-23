#!/usr/bin/env python3
"""Regression tests for the RepoPrompt CE contribution preflight lanes."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
PREFLIGHT_SOURCE = REPO_ROOT / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"
PREFLIGHT_TIMING_SOURCE = (
    REPO_ROOT / ".agents/skills/rpce-contribution-check/scripts/preflight_timing.py"
)

PHASE_IDS = [
    "whitespace_checks",
    "staged_index_secret_scan",
    "repository_guardrails",
    "clean_worktree_check",
    "outgoing_range_resolution",
    "outgoing_range_secret_scan",
    "path_selection",
    "conductor_selftests",
    "ci_app_test_runner_selftests",
    "swift_lint",
    "root_tests",
    "provider_tests",
    "portable_tests",
    "repoprompt_build",
    "mcp_build",
    "xcode_generator_tests",
    "xcode_workspace_validation",
]

GUARDRAILS_TARGET = "guardrails"
CONDUCTOR_SELFTEST_TARGET = "conductor-selftest"
CI_APP_TEST_RUNNER_SELFTEST_TARGET = "ci-app-test-runner-selftest"
SWIFT_LINT_TARGET = "dev-lint"
ROOT_TEST_TARGET = "dev-test"
PROVIDER_TEST_TARGET = "dev-provider-test"
PORTABLE_TEST_TARGET = "dev-portable-test"
REPOPROMPT_BUILD_TARGET = "dev-swift-build PRODUCT=RepoPrompt"
MCP_BUILD_TARGET = "dev-swift-build PRODUCT=repoprompt-mcp"
XCODE_GENERATOR_TEST_TARGET = "xcode-generator-test"
XCODE_VALIDATE_TARGET = "xcode-validate"
ORDINARY_SUBPROCESS_TIMEOUT_SECONDS = 90
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

    def git_output(self, repo: Path, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=repo, check=True, text=True, capture_output=True
        ).stdout.strip()

    def write_stub(self, bin_dir: Path, name: str, log_env_name: str) -> None:
        stub = bin_dir / name
        controls = ""
        if name == "make":
            controls = (
                "if [[ -n \"${RPCE_STUB_MAKE_OUTPUT:-}\" ]]; then\n"
                "  printf '%s\\n' \"$RPCE_STUB_MAKE_OUTPUT\"\n"
                "fi\n"
                "if [[ -n \"${RPCE_STUB_REMOVE_TIMING_HELPER_ON_TARGET:-}\" "
                "&& \"$*\" == \"$RPCE_STUB_REMOVE_TIMING_HELPER_ON_TARGET\" ]]; then\n"
                "  rm -f -- \"${RPCE_STUB_TIMING_HELPER:?}\"\n"
                "fi\n"
                "if [[ -n \"${RPCE_STUB_FAIL_MAKE_TARGET:-}\" "
                "&& \"$*\" == \"$RPCE_STUB_FAIL_MAKE_TARGET\" ]]; then\n"
                "  exit \"${RPCE_STUB_FAIL_MAKE_EXIT_CODE:-1}\"\n"
                "fi\n"
            )
        stub.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"printf '%s\\n' \"$*\" >> \"${{{log_env_name}:?}}\"\n"
            + controls,
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
        shutil.copy2(PREFLIGHT_TIMING_SOURCE, preflight.parent / "preflight_timing.py")
        (repo / ".gitignore").write_text(".build/\n", encoding="utf-8")
        (repo / "README.md").write_text("fixture\n", encoding="utf-8")
        self.run_git(repo, "add", ".")
        self.run_git(repo, "commit", "-m", "initial")
        self.run_git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.run_git(repo, "checkout", "-b", "feature")

        if outgoing_path is not None:
            target = repo / outgoing_path
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                target.write_text(target.read_text(encoding="utf-8") + "\n# fixture change\n", encoding="utf-8")
            else:
                target.write_text("// fixture\n", encoding="utf-8")
            self.run_git(repo, "add", outgoing_path)
            self.run_git(repo, "commit", "-m", "feature change")

        bin_dir = root / "bin"
        bin_dir.mkdir()
        make_log = root / "make.log"
        gitleaks_log = root / "gitleaks.log"
        self.write_stub(bin_dir, "make", "RPCE_STUB_MAKE_LOG")
        self.write_stub(bin_dir, "gitleaks", "RPCE_STUB_GITLEAKS_LOG")
        fixture_python = Path("/usr/bin/python3")
        if sys.platform != "darwin" or not fixture_python.exists():
            fixture_python = Path(sys.executable)
        (bin_dir / "python3").symlink_to(fixture_python)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        env["RPCE_STUB_MAKE_LOG"] = str(make_log)
        env["RPCE_STUB_GITLEAKS_LOG"] = str(gitleaks_log)
        env["RPCE_STUB_PYTHON"] = str(fixture_python)
        env["RPCE_STUB_TIMING_HELPER"] = str(preflight.parent / "preflight_timing.py")
        env["TMPDIR"] = str(root)
        return repo, preflight, env

    def run_preflight(self, repo: Path, preflight: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(preflight), *args],
            cwd=repo,
            env=env,
            text=True,
            capture_output=True,
            timeout=ORDINARY_SUBPROCESS_TIMEOUT_SECONDS,
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

    def receipt_paths(self, repo: Path) -> list[Path]:
        return sorted((repo / ".build/validation-artifacts/pr-ready").glob("*.json"))

    def timing_temp_paths(self, root: Path) -> list[Path]:
        return sorted(root.glob("rpce-pr-ready-timing.*"))

    def install_failing_python_transition(
        self, env: dict[str, str], *, fail_invocation: int
    ) -> None:
        python_stub = Path(env["PATH"].split(os.pathsep, 1)[0]) / "python3"
        python_stub.unlink()
        counter = python_stub.parent.parent / "python-count"
        env["RPCE_STUB_PYTHON_COUNT"] = str(counter)
        env["RPCE_STUB_PYTHON_FAIL_INVOCATION"] = str(fail_invocation)
        python_stub.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "count=0\n"
            "[[ ! -f \"$RPCE_STUB_PYTHON_COUNT\" ]] || count=$(cat \"$RPCE_STUB_PYTHON_COUNT\")\n"
            "count=$((count + 1))\n"
            "printf '%s\\n' \"$count\" > \"$RPCE_STUB_PYTHON_COUNT\"\n"
            "if [[ \"$count\" == \"$RPCE_STUB_PYTHON_FAIL_INVOCATION\" ]]; then exit 42; fi\n"
            "exec \"$RPCE_STUB_PYTHON\" \"$@\"\n",
            encoding="utf-8",
        )
        python_stub.chmod(0o755)

    def load_only_receipt(self, repo: Path) -> tuple[Path, dict[str, object]]:
        paths = self.receipt_paths(repo)
        self.assertEqual(len(paths), 1, paths)
        return paths[0], json.loads(paths[0].read_text(encoding="utf-8"))

    def phase_map(self, receipt: dict[str, object]) -> dict[str, dict[str, object]]:
        phases = receipt["phases"]
        self.assertIsInstance(phases, list)
        return {phase["id"]: phase for phase in phases}  # type: ignore[index]

    def load_timing_module(self):
        spec = importlib.util.spec_from_file_location("preflight_timing_test", PREFLIGHT_TIMING_SOURCE)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

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
            self.assertNotIn("PR-ready timing receipt:", result.stdout)
            self.assertEqual(self.receipt_paths(repo), [])

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

    def test_pr_ready_receipt_has_stable_schema_order_and_selected_lane_timings(self) -> None:
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
            receipt_path, receipt = self.load_only_receipt(repo)
            self.assertRegex(
                receipt_path.name,
                r"^\d{8}T\d{6}Z-[0-9a-f]{32}\.json$",
            )
            self.assertIn(
                f"PR-ready timing receipt: .build/validation-artifacts/pr-ready/{receipt_path.name}",
                result.stdout,
            )
            self.assertEqual(
                set(receipt),
                {
                    "schema_version",
                    "kind",
                    "run_id",
                    "started_at",
                    "finished_at",
                    "elapsed_seconds",
                    "status",
                    "exit_code",
                    "signal",
                    "mode",
                    "provenance",
                    "selection",
                    "phases",
                },
            )
            self.assertEqual(receipt["schema_version"], 1)
            self.assertEqual(receipt["kind"], "rpce_pr_ready_timing")
            self.assertEqual(receipt["mode"], "pr-ready")
            self.assertEqual(receipt["status"], "passed")
            self.assertEqual(receipt["exit_code"], 0)
            self.assertIsNone(receipt["signal"])
            self.assertRegex(receipt["started_at"], r"Z$")
            self.assertRegex(receipt["finished_at"], r"Z$")
            self.assertGreaterEqual(receipt["elapsed_seconds"], 0)
            self.assertEqual(
                receipt["provenance"],
                {
                    "head_commit": self.git_output(repo, "rev-parse", "HEAD"),
                    "outgoing_base_kind": "origin_main_fallback",
                    "outgoing_commit_count": 1,
                },
            )
            self.assertEqual(
                receipt["selection"],
                {
                    "changed_path_count": 1,
                    "selected_lane_count": 3,
                    "selected_lane_ids": ["swift_lint", "root_tests", "repoprompt_build"],
                },
            )
            phases = receipt["phases"]
            self.assertEqual([phase["id"] for phase in phases], PHASE_IDS)
            phase_map = self.phase_map(receipt)
            for phase_id in PHASE_IDS[:7] + ["swift_lint", "root_tests", "repoprompt_build"]:
                self.assertEqual(phase_map[phase_id]["status"], "passed")
                self.assertGreaterEqual(phase_map[phase_id]["elapsed_seconds"], 0)
            for phase_id in set(PHASE_IDS[7:]) - {"swift_lint", "root_tests", "repoprompt_build"}:
                self.assertEqual(phase_map[phase_id]["status"], "skipped")
                self.assertEqual(phase_map[phase_id]["elapsed_seconds"], 0.0)

    def test_pr_ready_zero_outgoing_keeps_success_and_records_downstream_skips(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(Path(tmp))

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET])
            self.assertIn("No outgoing commits", result.stdout)
            _, receipt = self.load_only_receipt(repo)
            self.assertEqual(receipt["status"], "passed")
            self.assertEqual(receipt["provenance"]["outgoing_commit_count"], 0)
            self.assertEqual(receipt["selection"]["selected_lane_count"], 0)
            phase_map = self.phase_map(receipt)
            for phase_id in PHASE_IDS[:5]:
                self.assertEqual(phase_map[phase_id]["status"], "passed")
            for phase_id in PHASE_IDS[5:]:
                self.assertEqual(phase_map[phase_id]["status"], "skipped")

    def test_pr_ready_failure_preserves_exit_and_records_partial_active_phase(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="Sources/RepoPrompt/Example.swift"
            )
            env["RPCE_STUB_FAIL_MAKE_TARGET"] = GUARDRAILS_TARGET
            env["RPCE_STUB_FAIL_MAKE_EXIT_CODE"] = "37"

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 37, result.stderr + result.stdout)
            _, receipt = self.load_only_receipt(repo)
            self.assertEqual(receipt["status"], "failed")
            self.assertEqual(receipt["exit_code"], 37)
            self.assertIsNone(receipt["signal"])
            phase_map = self.phase_map(receipt)
            self.assertEqual(phase_map["whitespace_checks"]["status"], "passed")
            self.assertEqual(phase_map["staged_index_secret_scan"]["status"], "passed")
            self.assertEqual(phase_map["repository_guardrails"]["status"], "failed")
            self.assertIsNotNone(phase_map["repository_guardrails"]["finished_at"])
            self.assertEqual(phase_map["clean_worktree_check"]["status"], "skipped")

    def test_pr_ready_helper_init_failure_is_warning_only_and_keeps_selected_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, preflight, env = self.create_repo(root)
            timing_helper = preflight.parent / "preflight_timing.py"
            timing_helper.write_text("this is not valid python (\n", encoding="utf-8")
            self.run_git(repo, "add", str(timing_helper.relative_to(repo)))
            self.run_git(repo, "commit", "-m", "break timing helper fixture")

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET, CONDUCTOR_SELFTEST_TARGET])
            self.assertEqual(result.stderr.count("WARNING: PR-ready timing receipt unavailable"), 1)
            self.assertEqual(self.receipt_paths(repo), [])
            self.assertEqual(self.timing_temp_paths(root), [])

    def test_pr_ready_transition_failure_is_warning_only_and_keeps_selected_lanes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, preflight, env = self.create_repo(
                root, outgoing_path="Sources/RepoPrompt/Example.swift"
            )
            self.install_failing_python_transition(env, fail_invocation=3)

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assert_make_lines_equal(
                env,
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, ROOT_TEST_TARGET, REPOPROMPT_BUILD_TARGET],
            )
            self.assertEqual(result.stderr.count("WARNING: PR-ready timing receipt unavailable"), 1)
            self.assertEqual(self.receipt_paths(repo), [])
            self.assertEqual(self.timing_temp_paths(root), [])

    def test_pr_ready_publish_failure_preserves_original_nonzero_result(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, preflight, env = self.create_repo(root)
            blocked_artifact_dir = repo / ".build/validation-artifacts/pr-ready"
            blocked_artifact_dir.parent.mkdir(parents=True)
            blocked_artifact_dir.write_text("not a directory\n", encoding="utf-8")
            env["RPCE_STUB_FAIL_MAKE_TARGET"] = GUARDRAILS_TARGET
            env["RPCE_STUB_FAIL_MAKE_EXIT_CODE"] = "37"

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 37, result.stderr + result.stdout)
            self.assert_make_lines_equal(env, [GUARDRAILS_TARGET])
            self.assertEqual(result.stderr.count("WARNING: PR-ready timing receipt unavailable"), 1)
            self.assertEqual(self.receipt_paths(repo), [])
            self.assertEqual(self.timing_temp_paths(root), [])

    def test_pr_ready_receipt_excludes_paths_commands_output_and_sensitive_environment(self) -> None:
        with tempfile.TemporaryDirectory(prefix="private-user-receipt-") as tmp:
            repo, preflight, env = self.create_repo(
                Path(tmp), outgoing_path="docs/private-filename-token.md"
            )
            sensitive = "credential-shaped-sensitive-value"
            env["RPCE_STUB_MAKE_OUTPUT"] = sensitive
            env["PRIVATE_SIGNING_VALUE"] = sensitive
            self.run_git(repo, "remote", "add", "private-origin", f"https://example.invalid/{sensitive}.git")

            result = self.run_preflight(repo, preflight, env, "pr-ready")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            _, receipt = self.load_only_receipt(repo)
            serialized = json.dumps(receipt, sort_keys=True)
            for forbidden in [
                str(repo),
                str(Path(tmp)),
                "private-filename-token.md",
                sensitive,
                "example.invalid",
                "make dev-",
                "--log-opts",
                "conductor ticket",
            ]:
                self.assertNotIn(forbidden, serialized)

    def test_signal_traps_and_direct_execution_remain_unchanged(self) -> None:
        source = PREFLIGHT_SOURCE.read_text(encoding="utf-8")
        for expected in [
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
        ]:
            self.assertIn(expected, source)
        for forbidden in ["run_foreground", "signal-relay", "set -m", "kill -s"]:
            self.assertNotIn(forbidden, source)

    def test_timing_writes_are_atomic_and_final_publication_never_overwrites(self) -> None:
        timing = self.load_timing_module()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "receipt.json"
            with mock.patch.object(timing.os, "replace", side_effect=OSError("forced replace failure")):
                with self.assertRaises(OSError):
                    timing.atomic_write_json(target, {"schema_version": 1})
            self.assertFalse(target.exists())
            self.assertEqual(list(Path(tmp).glob(".receipt.json.*.tmp")), [])

            target.write_text("original\n", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                timing.publish_json_exclusive(target, {"schema_version": 1})
            self.assertEqual(target.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(list(Path(tmp).glob(".receipt.json.*.tmp")), [])

    def test_pr_ready_runs_conductor_selftest_for_preflight_control_plane_changes(self) -> None:
        cases = [
            (
                "preflight tests",
                "Scripts/test_contribution_preflight.py",
                [GUARDRAILS_TARGET, CONDUCTOR_SELFTEST_TARGET, PORTABLE_TEST_TARGET],
            ),
            (
                "preflight timing helper",
                ".agents/skills/rpce-contribution-check/scripts/preflight_timing.py",
                [GUARDRAILS_TARGET, CONDUCTOR_SELFTEST_TARGET],
            ),
            (
                "guardrails aggregator",
                "Scripts/guardrails.sh",
                [GUARDRAILS_TARGET, CONDUCTOR_SELFTEST_TARGET],
            ),
        ]

        for name, outgoing_path, expected in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                repo, preflight, env = self.create_repo(Path(tmp), outgoing_path=outgoing_path)

                result = self.run_preflight(repo, preflight, env, "pr-ready")

                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assert_make_lines_equal(env, expected)

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
                "split root test Swift path",
                "Tests/RepoPromptWorkspaceTests/ExampleTests.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, ROOT_TEST_TARGET],
            ),
            (
                "MCP Swift path",
                "Sources/RepoPromptMCP/Example.swift",
                [GUARDRAILS_TARGET, SWIFT_LINT_TARGET, MCP_BUILD_TARGET],
            ),
            (
                "portable shared Swift path",
                "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/Example.swift",
                [
                    GUARDRAILS_TARGET,
                    SWIFT_LINT_TARGET,
                    ROOT_TEST_TARGET,
                    PORTABLE_TEST_TARGET,
                    REPOPROMPT_BUILD_TARGET,
                    MCP_BUILD_TARGET,
                ],
            ),
            (
                "portable Desktop workflow mapping owner",
                "Sources/RepoPrompt/Features/AgentMode/Models/AgentWorkflow.swift",
                [
                    GUARDRAILS_TARGET,
                    SWIFT_LINT_TARGET,
                    ROOT_TEST_TARGET,
                    PORTABLE_TEST_TARGET,
                    REPOPROMPT_BUILD_TARGET,
                ],
            ),
            (
                "portable Desktop settings mapping owner",
                "Sources/RepoPrompt/Features/Settings/Models/GlobalSettingsDocument.swift",
                [
                    GUARDRAILS_TARGET,
                    SWIFT_LINT_TARGET,
                    ROOT_TEST_TARGET,
                    PORTABLE_TEST_TARGET,
                    REPOPROMPT_BUILD_TARGET,
                ],
            ),
            (
                "portable Desktop MCP projection owner",
                "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunSessionStore.swift",
                [
                    GUARDRAILS_TARGET,
                    SWIFT_LINT_TARGET,
                    ROOT_TEST_TARGET,
                    PORTABLE_TEST_TARGET,
                    REPOPROMPT_BUILD_TARGET,
                ],
            ),
            (
                "portable dependency guard",
                "Scripts/validate_portable_dependency_graph.py",
                [GUARDRAILS_TARGET, PORTABLE_TEST_TARGET],
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
            self.assertNotIn("PR-ready timing receipt:", result.stdout)
            self.assertEqual(self.receipt_paths(repo), [])

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
