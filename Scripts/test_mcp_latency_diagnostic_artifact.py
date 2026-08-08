#!/usr/bin/env python3
"""Focused guardrails for the isolated optimized MCP latency app manifest."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "Scripts/write_mcp_latency_diagnostic_manifest.py"


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


manifest_writer = load_module("mcp_latency_manifest_writer", MODULE_PATH)
fingerprint = load_module("source_tree_fingerprint", ROOT / "Scripts/source_tree_fingerprint.py")


class MCPLatencyDiagnosticArtifactTests(unittest.TestCase):
    def test_source_fingerprint_tracks_nonignored_worktree_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
            (repo / "tracked.txt").write_text("one", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", ".gitignore", "tracked.txt"], check=True)
            first = fingerprint.source_tree_fingerprint(repo)
            (repo / "tracked.txt").write_text("two", encoding="utf-8")
            second = fingerprint.source_tree_fingerprint(repo)
            self.assertNotEqual(first, second)
            (repo / "ignored.txt").write_text("ignored mutation", encoding="utf-8")
            self.assertEqual(second, fingerprint.source_tree_fingerprint(repo))

    def test_optimized_server_surface_is_a_closed_timing_only_allowlist(self) -> None:
        source = (ROOT / "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+MCPLatencyDiagnostics.swift").read_text(encoding="utf-8")
        operations = set(re.findall(r'case \w+ = "([^"]+)"', source))
        self.assertEqual(operations, {
            "mcp_latency_server_identity",
            "mcp_read_search_capture_begin",
            "mcp_read_search_capture_snapshot",
        })
        for forbidden in (
            "restart", "shutdown", "seed", "sleep", "fault", "large_response",
            "sparkle", "routing", "workspace", "runtime_snapshot", "admission_snapshot",
        ):
            self.assertNotIn(f'case {forbidden}', source.lower())

        package = (ROOT / "Scripts/package_app.sh").read_text(encoding="utf-8")
        self.assertIn("Ordinary release packaging refuses MCP latency diagnostic compile gates", package)
        self.assertIn('COMPAT_APP_BUNDLE="$APP_BUNDLE"', package)
        self.assertIn('SIGN_IDENTITY="-"', package)

    def make_artifact(self, root: Path) -> tuple[Path, Path, Path]:
        app = root / "RepoPrompt.app"
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir(parents=True)
        for name, payload in (("RepoPrompt", b"optimized-server"), ("repoprompt-mcp", b"optimized-client")):
            executable = macos / name
            executable.write_bytes(payload)
            os.chmod(executable, 0o755)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.pvncher.repoprompt.ce.mcp-latency-diagnostic",
                "CFBundleExecutable": "RepoPrompt",
                "RepoPromptSigningMode": "mcp-latency-diagnostic-adhoc",
                "RepoPromptDebugSecureStorageBackend": "alternate-in-memory",
            }, handle)
        provenance = {
            "schema_version": 1,
            "artifact_id": "artifact-identity",
            "artifact_kind": manifest_writer.ARTIFACT_KIND,
            "ordinary_release_artifact": False,
            "swift_configuration": "release",
            "server_diagnostic_configuration": "optimized_diagnostic",
            "diagnostic_surface": "mcp_latency_v1",
            "enabled_defines_by_target": manifest_writer.EXPECTED_DEFINES,
            "commit": "a" * 40,
            "dirty": True,
            "source_fingerprint_sha256": "b" * 64,
        }
        provenance_path = resources / manifest_writer.PROVENANCE_NAME
        provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
        return app, root / "artifact-manifest.json", provenance_path

    def test_manifest_records_exact_isolated_release_optimized_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, output, _provenance = self.make_artifact(root)
            payload = manifest_writer.build_manifest(app, output, root)

        self.assertEqual(payload["artifact_kind"], manifest_writer.ARTIFACT_KIND)
        self.assertEqual(payload["swift_configuration"], "release")
        self.assertEqual(payload["server_diagnostic_configuration"], "optimized_diagnostic")
        self.assertEqual(payload["enabled_defines_by_target"], manifest_writer.EXPECTED_DEFINES)
        self.assertEqual(set(payload["enabled_defines_by_target"]), {
            "RepoPromptApp", "RepoPromptDomainRuntime", "RepoPromptMCP", "RepoPromptShared",
        })
        self.assertFalse(any(
            "DEBUG" in defines for defines in payload["enabled_defines_by_target"].values()
        ))
        self.assertFalse(payload["ordinary_release_artifact"])
        self.assertEqual(payload["source_fingerprint_sha256"], "b" * 64)
        self.assertEqual(payload["signing_mode"], "mcp-latency-diagnostic-adhoc")
        self.assertEqual(payload["secure_storage_backend"], "alternate-in-memory")
        self.assertEqual(len(payload["executable_sha256"]), 64)
        self.assertEqual(len(payload["embedded_cli_sha256"]), 64)
        self.assertTrue(payload["bundle_identifier"].endswith(".mcp-latency-diagnostic"))

    def test_manifest_rejects_escaping_output_and_tampered_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app, output, provenance_path = self.make_artifact(root)
            with self.assertRaisesRegex(manifest_writer.ManifestError, "escapes"):
                manifest_writer.build_manifest(app, root.parent / "escaped.json", root)

            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["enabled_defines_by_target"]["RepoPromptApp"].append("DEBUG")
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(manifest_writer.ManifestError, "target defines"):
                manifest_writer.build_manifest(app, output, root)


if __name__ == "__main__":
    unittest.main()
