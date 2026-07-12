#!/usr/bin/env python3
"""Tests for cache_inventory scratch identity and lifecycle planning."""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import cache_inventory
import conductor


SCRIPT_DIR = Path(__file__).resolve().parent


class CacheInventoryTests(unittest.TestCase):
    def test_default_identity_points_to_dot_build(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text('// swift-tools-version:5.9\n', encoding="utf-8")
            identity = cache_inventory.resolve_swiftpm_cache_identity(root, "debug", {})
        self.assertEqual(identity.source, cache_inventory.CacheSource.DEFAULT)
        self.assertEqual(identity.effective_path, root / ".build")
        self.assertIsNone(identity.developer_root)
        self.assertIn("debug", identity.key())

    def test_exact_env_identity_uses_provided_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exact = root / "exact" / "scratch"
            exact.mkdir(parents=True)
            env = {"REPOPROMPT_SWIFTPM_SCRATCH_PATH": str(exact)}
            identity = cache_inventory.resolve_swiftpm_cache_identity(root, "debug", env)
        self.assertEqual(identity.source, cache_inventory.CacheSource.EXACT_ENV)
        self.assertEqual(identity.effective_path, exact)

    def test_developer_root_identity_is_keyed_under_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text('// swift-tools-version:5.9\n', encoding="utf-8")
            dev_root = root / "dev-cache"
            dev_root.mkdir()
            env = {"REPOPROMPT_DEVELOPER_SWIFTPM_SCRATCH_ROOT": str(dev_root)}
            identity = cache_inventory.resolve_swiftpm_cache_identity(root, "debug", env)
        self.assertEqual(identity.source, cache_inventory.CacheSource.DEVELOPER_ROOT)
        self.assertEqual(identity.developer_root, str(dev_root))
        self.assertTrue(cache_inventory.is_path_within(identity.effective_path, dev_root))
        self.assertIn(cache_inventory.repo_hash(root)[:8], identity.key())

    def test_managed_worktree_container_detects_worktree_layout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            repo_root = container / "wt-a"
            repo_root.mkdir(parents=True)
            self.assertEqual(cache_inventory.managed_worktree_container(repo_root), container)

    def test_managed_worktree_repo_roots_includes_siblings_and_current(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            other = container / "not-a-repo"
            current.mkdir(parents=True)
            sibling.mkdir(parents=True)
            other.mkdir(parents=True)
            (current / ".build").mkdir()
            (sibling / ".build").mkdir()
            roots = cache_inventory.managed_worktree_repo_roots(current)
        self.assertEqual(roots, [current, sibling])

    def test_cleanup_plan_skips_current_and_marks_siblings_eligible(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            current.mkdir(parents=True)
            sibling.mkdir(parents=True)
            (current / ".build" / "debug").mkdir(parents=True)
            (sibling / ".build" / "debug").mkdir(parents=True)
            (current / "Package.swift").write_text("", encoding="utf-8")
            (sibling / "Package.swift").write_text("", encoding="utf-8")

            plan = cache_inventory.plan_build_cache_cleanup(current)

        self.assertEqual(len(plan.entries), 2)
        current_entry = next(e for e in plan.entries if e.repo_root == current)
        sibling_entry = next(e for e in plan.entries if e.repo_root == sibling)
        self.assertTrue(current_entry.current)
        self.assertIn("current", current_entry.skip_reasons)
        self.assertFalse(sibling_entry.current)
        self.assertEqual(sibling_entry.skip_reasons, [])
        self.assertEqual(len(plan.eligible_entries), 1)
        self.assertEqual(plan.eligible_entries[0].repo_root, sibling)

    def test_cleanup_plan_respects_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling1 = container / "wt-b"
            sibling2 = container / "wt-c"
            for d in (current, sibling1, sibling2):
                d.mkdir(parents=True)
                (d / ".build" / "debug").mkdir(parents=True)
                (d / "Package.swift").write_text("", encoding="utf-8")

            plan = cache_inventory.plan_build_cache_cleanup(current, limit=1)

        eligible = [e for e in plan.entries if not e.current]
        self.assertEqual(len(eligible), 1)

    def test_cleanup_apply_requires_confirm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            current.mkdir(parents=True)
            sibling.mkdir(parents=True)
            (current / ".build" / "debug").mkdir(parents=True)
            (sibling / ".build" / "debug").mkdir(parents=True)
            (current / "Package.swift").write_text("", encoding="utf-8")
            (sibling / "Package.swift").write_text("", encoding="utf-8")

            plan = cache_inventory.plan_build_cache_cleanup(
                current, dry_run=False, apply=True, confirm=False
            )
            self.assertEqual(len(plan.eligible_entries), 1)
            rc = cache_inventory.execute_build_cache_cleanup(plan)
            self.assertEqual(rc, 1)

    def test_cleanup_apply_confirm_removes_eligible_siblings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            container = root / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            current.mkdir(parents=True)
            sibling.mkdir(parents=True)
            (current / ".build" / "debug").mkdir(parents=True)
            (sibling / ".build" / "debug").mkdir(parents=True)
            (current / "Package.swift").write_text("", encoding="utf-8")
            (sibling / "Package.swift").write_text("", encoding="utf-8")

            plan = cache_inventory.plan_build_cache_cleanup(
                current, dry_run=False, apply=True, confirm=True
            )
            rc = cache_inventory.execute_build_cache_cleanup(plan)
            self.assertEqual(rc, 0)
            self.assertTrue((current / ".build").exists())
            self.assertFalse((sibling / ".build").exists())

    def test_cleanup_plan_skips_symlinked_cache_without_resolving_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            target = container / "shared-cache"
            for directory in (current, sibling, target):
                directory.mkdir(parents=True)
            (current / "Package.swift").write_text("", encoding="utf-8")
            (sibling / "Package.swift").write_text("", encoding="utf-8")
            (current / ".build").mkdir()
            (sibling / ".build").symlink_to(target, target_is_directory=True)

            plan = cache_inventory.plan_build_cache_cleanup(sibling)
            entry = next(e for e in plan.entries if e.path == sibling / ".build")

        self.assertIn("symlink", entry.skip_reasons)
        self.assertNotEqual(entry.path, target.resolve())

    def test_diagnostics_build_cache_reports_identity_and_worktrees(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / ".repoprompt-worktrees" / "group"
            current = container / "wt-a"
            sibling = container / "wt-b"
            current.mkdir(parents=True)
            sibling.mkdir(parents=True)
            (current / ".build" / "debug").mkdir(parents=True)
            (sibling / ".build" / "debug").mkdir(parents=True)
            (sibling / ".build" / "debug" / "large.bin").write_bytes(b"x" * 2000)
            (current / "Package.swift").write_text("", encoding="utf-8")
            (sibling / "Package.swift").write_text("", encoding="utf-8")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rc = cache_inventory.operation_diagnostics_build_cache(current, {"limit": 2})
            text = output.getvalue()

        self.assertEqual(rc, 0)
        self.assertIn("Cache identity:", text)
        self.assertIn("Build cache diagnostics", text)
        self.assertIn("Worktree .build total:", text)
        self.assertIn("Top .build directories:", text)
        self.assertIn("wt-b", text)

    def test_conductor_registry_swift_build_adds_scratch_path_from_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = root / "external" / "scratch"
            scratch.mkdir(parents=True)
            env = {"REPOPROMPT_DEVELOPER_SWIFTPM_SCRATCH_ROOT": str(scratch)}
            registry = conductor.OperationRegistry(root)
            argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {
                    "operation": "swift-build",
                    "args": {"product": "RepoPrompt"},
                    "env": env,
                }
            )
        self.assertIn("--scratch-path", argv)
        self.assertTrue(any(str(scratch) in a for a in argv), argv)

    def test_conductor_registry_swift_build_omits_scratch_path_for_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry = conductor.OperationRegistry(root)
            argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "swift-build", "args": {"product": "RepoPrompt"}}
            )
        self.assertNotIn("--scratch-path", argv)

    def test_conductor_registry_build_sets_scratch_path_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scratch = root / "external" / "scratch"
            scratch.mkdir(parents=True)
            env = {"REPOPROMPT_DEVELOPER_SWIFTPM_SCRATCH_ROOT": str(scratch)}
            registry = conductor.OperationRegistry(root)
            argv, _lanes, _cwd, out_env, _timeout = registry.prepare(
                {"operation": "build", "args": {}, "env": env}
            )
        self.assertIn("package_app.sh", argv[0])
        expected_path = scratch / cache_inventory.resolve_swiftpm_cache_identity(root, "debug", env).key()
        self.assertEqual(out_env["REPOPROMPT_SWIFTPM_SCRATCH_PATH"], str(expected_path))

    def test_conductor_registry_cache_cleanup_delegates_internal_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry = conductor.OperationRegistry(root)
            argv, _lanes, _cwd, _env, _timeout = registry.prepare(
                {"operation": "cache", "args": {"subcommand": "cleanup", "apply": True, "confirm": True, "limit": 3}}
            )
        self.assertIn("__operation_runner", argv)
        payload = argv[-1]
        self.assertIn('"kind":"cache_cleanup"', payload)
        self.assertIn('"apply":true', payload)
        self.assertIn('"confirm":true', payload)

    def test_cli_identity_and_path_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text("", encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT_DIR / "cache_inventory.py"), "--repo-root", str(root), "--configuration", "debug", "--format", "identity"],
                text=True,
                capture_output=True,
            )
        self.assertEqual(result.returncode, 0)
        self.assertIn("source=default", result.stdout)


if __name__ == "__main__":
    unittest.main()
