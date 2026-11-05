#!/usr/bin/env python3
"""Artifact/host fences and publication dependencies for older macOS smoke."""
from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import smoke_macos_compatibility as smoke

ROOT = Path(__file__).resolve().parent.parent


class CompatibilitySmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "RepoPrompt.zip"
        self.manifest = self.root / "RepoPrompt-artifact-manifest.json"
        self.archive.write_bytes(b"transferred release archive")
        self.manifest.write_text("{}")
        self.write_checksums()

    def write_checksums(self):
        (self.root / "SHA256SUMS").write_text("".join(
            f"{smoke.digest(path)}  {path.name}\n" for path in (self.archive, self.manifest)
        ))

    def test_requires_actual_requested_runtime_and_architecture(self):
        for version, architecture in (("26.7.2", "arm64"), ("14.8.9", "arm64"), ("15.8", "x86_64")):
            with self.subTest(version=version, architecture=architecture):
                with self.assertRaises(ValueError):
                    smoke.verify_host(version, architecture, 15, "arm64")
        smoke.verify_host("15.8.2", "arm64", 15, "arm64")
        smoke.verify_host("14.8.9", "arm64", 14, "arm64")

    def test_checksums_bind_both_archive_and_manifest(self):
        for path in (self.archive, self.manifest):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(b"changed after transfer")
                with self.assertRaisesRegex(ValueError, "SHA256SUMS mismatch"):
                    smoke.release_inputs(self.root)
                path.write_bytes(original)

    def test_ambiguous_or_symlink_inputs_are_rejected(self):
        other = self.root / "extra.pkg"
        other.write_bytes(b"unexpected second enclosure")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            smoke.release_inputs(self.root)
        other.unlink()
        self.archive.unlink()
        self.archive.symlink_to(self.manifest)
        with self.assertRaisesRegex(ValueError, "non-symlink"):
            smoke.release_inputs(self.root)

    def test_duplicate_checksum_entries_are_rejected(self):
        checksums = self.root / "SHA256SUMS"
        checksums.write_text(checksums.read_text() * 2)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            smoke.release_inputs(self.root)

    def test_checksum_failure_stops_before_extraction_or_launch(self):
        self.archive.write_bytes(b"wrong transferred bytes")
        with patch.object(smoke.subprocess, "check_output", return_value="15.8.2\n"), \
                patch.object(smoke.platform, "machine", return_value="arm64"), \
                patch.object(smoke.subprocess, "run") as extract, \
                patch.object(smoke, "smoke_process") as launch:
            with self.assertRaisesRegex(ValueError, "SHA256SUMS mismatch"):
                smoke.check_artifact(self.root, 15, "arm64", {}, self.root / "diagnostics")
            extract.assert_not_called()
            launch.assert_not_called()

    def run_fixture(self, *, enclosure=".zip", fail=False):
        if enclosure == ".pkg":
            self.archive = self.archive.rename(self.archive.with_suffix(enclosure))
            self.write_checksums()
        report = {}
        commands = []

        def execute(command, **_kwargs):
            commands.append(command)
            if command[0] == "/usr/bin/ditto":
                extracted = Path(command[-1])
            elif command[0].endswith("build_identity_transition_pkg.sh"):
                extracted = Path(command[-1])
                self.assertNotIn("install", command)
            else:
                return subprocess.CompletedProcess(command, 0)
            contents = extracted / "RepoPrompt CE.app/Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0"}))
            return subprocess.CompletedProcess(command, 0)

        def roundtrip(command, environment):
            commands.append(command)
            self.assertEqual(Path(command[-1]), self.manifest)
            self.assertNotIn("GH_TOKEN", environment)
            self.assertNotIn("SENTRY_AUTH_TOKEN", environment)
            self.assertEqual(environment["REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"], "240")
            if fail:
                raise subprocess.CalledProcessError(1, command)

        with patch.object(smoke.subprocess, "check_output", return_value="15.8.2\n"), \
                patch.object(smoke.platform, "machine", return_value="arm64"), \
                patch.object(smoke.subprocess, "run", side_effect=execute), \
                patch.object(smoke, "smoke_process", side_effect=roundtrip), \
                patch.dict(os.environ, GH_TOKEN="fixture-not-forwarded", SENTRY_AUTH_TOKEN="fixture-not-forwarded"):
            smoke.check_artifact(self.root, 15, "arm64", report, self.root / "diagnostics")
        self.assertEqual(report["artifact"]["sha256"], smoke.digest(self.archive))
        self.assertEqual(report["host"], {"macos": "15.8.2", "architecture": "arm64"})
        self.assertTrue(any(command[0].endswith("smoke_packaged_mcp_roundtrip.sh") for command in commands))
        self.assertFalse(any("swift" in Path(command[0]).name for command in commands))

    def test_transferred_zip_is_verified_and_smoked_without_building(self):
        self.run_fixture()

    def test_transition_package_payload_is_verified_without_installing(self):
        self.run_fixture(enclosure=".pkg")

    def test_launch_failure_propagates(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_fixture(fail=True)

    def test_wrong_runtime_replaces_stale_success_receipt(self):
        report = self.root / "result.json"
        report.write_text('{"result":"passed"}')
        args = ["smoke", str(self.root), "--expected-major", "15", "--expected-arch", "arm64", "--report", str(report)]
        with patch.object(sys, "argv", args), \
                patch.object(smoke.subprocess, "check_output", return_value="26.7.2\n"), \
                patch.object(smoke.platform, "machine", return_value="arm64"), \
                patch.object(smoke, "smoke_process") as launch:
            self.assertEqual(smoke.main(), 1)
            launch.assert_not_called()
        self.assertEqual(json.loads(report.read_text())["result"], "failed")


class CompatibilityWorkflowTests(unittest.TestCase):
    def job(self, workflow, name):
        source = (ROOT / ".github/workflows" / workflow).read_text()
        match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:\n|\Z)", source, re.M | re.S)
        self.assertIsNotNone(match, name)
        return match[1]

    def test_manual_candidate_qualifies_exact_archive_without_entering_style(self):
        job = self.job("release-candidate.yml", "compatibility")
        self.assertIn("needs: artifact", job)
        self.assertIn("uses: ./.github/workflows/macos-compatibility.yml", job)
        self.assertIn("artifact-name: ${{ needs.artifact.outputs.artifact-name }}", job)
        self.assertNotIn("github.run_attempt", job)
        self.assertIn("tooling-ref: ${{ github.sha }}", job)
        producer = self.job("release-candidate.yml", "artifact")
        self.assertIn("ARTIFACT_NAME: RepoPrompt-CE-release-candidate-${{ github.run_id }}-${{ github.run_attempt }}", producer)
        self.assertIn("artifact-name: ${{ steps.archive-name.outputs.name }}", producer)
        self.assertIn("name: ${{ steps.archive-name.outputs.name }}", producer)
        self.assertIn("smoke_packaged_mcp_roundtrip.sh", producer)
        self.assertIn("if-no-files-found: error", producer)
        self.assertNotIn("continue-on-error", producer)
        integration = (ROOT / ".github/workflows/ci-integration-products.yml").read_text()
        self.assertNotIn("macos-compatibility.yml", integration)
        self.assertNotIn("release artifact", integration)
        style = self.job("ci.yml", "style")
        self.assertIn("integration-products", style)
        self.assertIn('ci_job_diagnostics.py prerequisites', style)
        # Every non-success Sentry result is exercised through this actual
        # command by test_style_command_rejects_each_failed_cancelled_or_skipped_obligation.

    def test_publication_waits_for_older_runtime_compatibility(self):
        for workflow, publisher in (("main-tip.yml", "publish"), ("release-promote.yml", "promote")):
            with self.subTest(workflow=workflow):
                self.assertRegex(self.job(workflow, publisher), r"(?m)^      - compatibility$")
                self.assertIn("uses: ./.github/workflows/macos-compatibility.yml", self.job(workflow, "compatibility"))

    def test_both_hosted_architectures_are_required_and_use_fixed_tooling(self):
        source = (ROOT / ".github/workflows/macos-compatibility.yml").read_text()
        for runner in ("macos-15", "macos-15-intel"):
            self.assertIn(f"runner: {runner}\n", source)
        self.assertIn("ref: ${{ inputs.tooling-ref }}", source)
        self.assertIn("name: ${{ inputs.artifact-name }}", source)
        self.assertIn('ci_admission.py verify --context "$ADMISSION_CONTEXT"', source)
        self.assertIn("working-directory: tooling", source)
        self.assertNotIn("continue-on-error:", source)
        self.assertNotIn("secrets: inherit", source)

    def test_packaged_test_process_does_not_emit_production_telemetry(self):
        source = (ROOT / "Scripts/smoke_packaged_mcp_roundtrip.sh").read_text()
        launch = source.split('log_phase "$SMOKE_LABEL launching packaged app"', 1)[1].split("APP_PID=$!", 1)[0]
        self.assertIn("REPOPROMPT_TELEMETRY_DISABLED=1", launch)


if __name__ == "__main__":
    unittest.main()
