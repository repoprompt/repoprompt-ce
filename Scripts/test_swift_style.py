#!/usr/bin/env python3
"""Focused regression tests for changed-file Swift style selection."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent


class SwiftStyleTests(unittest.TestCase):
    def git(self, root: Path, *args: str) -> None:
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True)

    def fixture(self, root: Path) -> tuple[Path, dict[str, str], Path]:
        repo = root / "repo"
        (repo / "Scripts").mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "Scripts/swift_style.sh", repo / "Scripts/swift_style.sh")
        shutil.copy2(REPO_ROOT / ".swiftformat", repo / ".swiftformat")
        shutil.copy2(REPO_ROOT / ".swiftlint.yml", repo / ".swiftlint.yml")
        for path in [
            "Package.swift", "Sources/RepoPrompt/Base.swift",
            "Sources/RepoPromptExecutable/Main.swift", "Sources/RepoPromptMCP/MCP.swift",
            "Sources/RepoPromptShared/Shared.swift", "Tests/RepoPromptTests/BaseTests.swift",
            "Packages/RepoPromptAgentProviders/Package.swift",
            "Packages/RepoPromptAgentProviders/Sources/Provider.swift",
            "Packages/RepoPromptAgentProviders/Tests/ProviderTests.swift",
        ]:
            target = repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// base\n", encoding="utf-8")
        self.git(repo, "init", "-b", "main")
        self.git(repo, "config", "user.name", "Style Tests")
        self.git(repo, "config", "user.email", "style@example.invalid")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", "base")
        self.git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        self.git(repo, "checkout", "-b", "feature")

        bin_dir = root / "bin"
        bin_dir.mkdir()
        log = root / "tools.log"
        for tool in ("swiftformat", "swiftlint"):
            stub = bin_dir / tool
            stub.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\n"
                f"printf '{tool}\\n' >> \"$STYLE_TOOL_LOG\"\n"
                "printf 'arg=%s\\n' \"$@\" >> \"$STYLE_TOOL_LOG\"\n",
                encoding="utf-8",
            )
            stub.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        env["STYLE_TOOL_LOG"] = str(log)
        return repo, env, log

    def run_style(self, repo: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "Scripts/swift_style.sh", "lint", "--changed", "default"],
            cwd=repo, env=env, text=True, capture_output=True,
        )

    def test_changed_lint_unions_branch_staged_unstaged_untracked_in_one_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, env, log = self.fixture(Path(tmp))
            branch = repo / "Sources/RepoPrompt/Branch.swift"
            branch.write_text("// branch\n", encoding="utf-8")
            self.git(repo, "add", str(branch.relative_to(repo)))
            self.git(repo, "commit", "-m", "branch")
            staged = repo / "Sources/RepoPrompt/Staged.swift"
            staged.write_text("// staged\n", encoding="utf-8")
            self.git(repo, "add", str(staged.relative_to(repo)))
            (repo / "Sources/RepoPrompt/Base.swift").write_text("// unstaged\n", encoding="utf-8")
            (repo / "Tests/RepoPromptTests/UntrackedTests.swift").write_text("// untracked\n", encoding="utf-8")
            outside = Path(tmp) / "Outside.swift"
            outside.write_text("// outside\n", encoding="utf-8")
            (repo / "Sources/RepoPrompt/Linked.swift").symlink_to(outside)
            (repo / "Scratch.swift").write_text("// out of scope\n", encoding="utf-8")

            result = self.run_style(repo, env)
            output = log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = output.splitlines()
        self.assertEqual(lines.count("swiftformat"), 1)
        self.assertEqual(lines.count("swiftlint"), 1)
        for path in ["Branch.swift", "Staged.swift", "Base.swift", "UntrackedTests.swift"]:
            self.assertIn(path, output)
        self.assertNotIn("Linked.swift", output)
        self.assertNotIn("Scratch.swift", output)

    def test_changed_style_config_falls_back_to_full_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo, env, log = self.fixture(Path(tmp))
            (repo / ".swiftformat").write_text("# changed\n", encoding="utf-8")

            result = self.run_style(repo, env)
            output = log.read_text(encoding="utf-8")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("requires full Swift style scope", result.stdout)
        self.assertIn("Sources/RepoPrompt/Base.swift", output)
        self.assertIn("Packages/RepoPromptAgentProviders/Sources/Provider.swift", output)


if __name__ == "__main__":
    unittest.main()
