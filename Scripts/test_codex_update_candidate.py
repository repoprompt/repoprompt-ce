#!/usr/bin/env python3
"""Offline tests for guarded Codex runtime update candidate preparation."""

from __future__ import annotations

import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import codex_runtime_artifact as artifact
import codex_update_candidate as candidate
import test_codex_runtime_artifact as artifact_fixtures


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "Scripts" / "codex_update_candidate.py"
BASELINE = ROOT / "Vendor" / "Codex" / "manifest.json"
VERSION = "0.148.0"
TAG = f"rust-v{VERSION}"
TARGETS = (
    ("aarch64-apple-darwin", "arm64"),
    ("x86_64-apple-darwin", "x86_64"),
)


class CodexUpdateCandidateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="codex-update-candidate-test-"))
        self.addCleanup(lambda: shutil.rmtree(self.temp, ignore_errors=True))
        self.assets = self.temp / "assets"
        self.assets.mkdir()
        self.sources = self.temp / "sources"
        self.sources.mkdir()
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.lipo = self.bin / "lipo"
        self.codesign = self.bin / "codesign"
        self._write_fake_tools()
        for target, architecture in TARGETS:
            self._write_package(target, architecture)
        self._rebuild_assets_and_release()

    def _write_fake_tools(self) -> None:
        artifact_fixtures.write_executable(
            self.lipo,
            """#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  *aarch64-apple-darwin*) printf 'arm64\\n' ;;
  *x86_64-apple-darwin*) printf 'x86_64\\n' ;;
  *) printf 'unknown\\n' ;;
esac
""",
        )
        artifact_fixtures.write_executable(
            self.codesign,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "--remove-signature" ]]; then exit 1; fi
if [[ "$1" == "--verify" ]]; then exit 0; fi
if [[ "$*" == *"--entitlements"* ]]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>com.apple.security.cs.allow-jit</key><true/><key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/></dict></plist>\n'
    exit 0
fi
path="${!#}"
cat >&2 <<EOF
Identifier=$(basename "$path")
CodeDirectory flags=0x10000(runtime)
Authority=${FAKE_AUTHORITY:-Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)}
TeamIdentifier=${FAKE_TEAM_IDENTIFIER:-2DC432GLL2}
Timestamp=Jul 25, 2026 at 12:00:00
EOF
""",
        )

    def _write_package(self, target: str, architecture: str) -> None:
        root = self.sources / target
        for directory in (
            root / "bin",
            root / "codex-path",
            root / "codex-resources" / "zsh" / "bin",
        ):
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o755)
        metadata = {
            "layoutVersion": 1,
            "version": VERSION,
            "target": target,
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path",
        }
        (root / "codex-package.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        for relative in (
            "bin/codex",
            "bin/codex-code-mode-host",
            "codex-path/rg",
            "codex-resources/zsh/bin/zsh",
        ):
            artifact_fixtures.write_mach_o_fixture(
                root / relative,
                architecture,
                f"candidate={VERSION}\ntarget={target}\npath={relative}\n".encode(),
            )

    @staticmethod
    def _make_archive(source: Path, destination: Path) -> None:
        with tarfile.open(destination, "w:gz") as tar:
            for path in sorted(source.rglob("*")):
                tar.add(path, arcname=path.relative_to(source).as_posix(), recursive=False)

    def _rebuild_assets_and_release(self) -> None:
        archive_names: list[str] = []
        for target, _architecture in TARGETS:
            archive_name = f"codex-package-{target}.tar.gz"
            archive_names.append(archive_name)
            self._make_archive(self.sources / target, self.assets / archive_name)
        sums = self.assets / "codex-package_SHA256SUMS"
        sums.write_text(
            "".join(
                f"{artifact.sha256(self.assets / name)}  {name}\n"
                for name in archive_names
            ),
            encoding="utf-8",
        )
        names = [sums.name, *archive_names]
        release = {
            "tag_name": TAG,
            "name": f"Codex {VERSION}",
            "html_url": f"https://github.com/openai/codex/releases/tag/{TAG}",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": name,
                    "browser_download_url": f"https://github.com/openai/codex/releases/download/{TAG}/{name}",
                    "size": (self.assets / name).stat().st_size,
                }
                for name in names
            ],
        }
        self.release_path = self.temp / "release.json"
        self.release_path.write_text(json.dumps(release, indent=2) + "\n", encoding="utf-8")

    def _release(self) -> dict[str, object]:
        return json.loads(self.release_path.read_text(encoding="utf-8"))

    def _write_release(self, release: dict[str, object]) -> None:
        self.release_path.write_text(json.dumps(release, indent=2) + "\n", encoding="utf-8")

    def _run(
        self,
        output: Path,
        *,
        selector: tuple[str, ...] = ("--version", VERSION),
        env: dict[str, str] | None = None,
        expected: int = 0,
        fixture_mode: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(TOOL),
            *selector,
            *(["--fixture-mode"] if fixture_mode else []),
            "--release-json",
            str(self.release_path),
            "--asset-dir",
            str(self.assets),
            "--output-dir",
            str(output),
            "--lipo",
            str(self.lipo),
            "--codesign",
            str(self.codesign),
        ]
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, **(env or {})},
        )
        self.assertEqual(result.returncode, expected, msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result

    def _run_raw(self, *arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(TOOL), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ,
        )
        self.assertEqual(result.returncode, expected, msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result

    def test_happy_path_is_deterministic_non_promotable_and_preserves_live_manifest(self) -> None:
        original_manifest = BASELINE.read_bytes()
        first = self.temp / "candidate-first"
        second = self.temp / "candidate-second"
        tagged = self.temp / "candidate-tagged"
        self._run(first)
        self._run(second)
        self._run(tagged, selector=("--tag", TAG))

        manifest_name = "NON_PROMOTABLE_TEST_FIXTURE-candidate-manifest.json"
        expected_files = {
            manifest_name,
            "candidate-provenance.json",
            "candidate-report.md",
            "release-metadata.json",
            "upstream-codex-package_SHA256SUMS",
            "NON_PROMOTABLE_TEST_FIXTURE.txt",
            "EVIDENCE_SHA256SUMS",
        }
        self.assertEqual({path.name for path in first.iterdir()}, expected_files)
        self.assertEqual({path.name for path in second.iterdir()}, expected_files)
        self.assertEqual({path.name for path in tagged.iterdir()}, expected_files)
        for name in expected_files:
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes(), name)

        provenance = json.loads((first / "candidate-provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(provenance["evidenceMode"], "test-fixture-non-promotable")
        self.assertTrue(provenance["nonPromotableTestFixture"])
        self.assertEqual(provenance["selectionMode"], "explicit-version")
        self.assertEqual(provenance["releaseMetadataSource"], str(self.release_path.resolve()))
        self.assertEqual(provenance["assetSources"], [str(self.assets.resolve())])
        self.assertEqual(provenance["baselineManifest"]["path"], "Vendor/Codex/manifest.json")
        self.assertEqual(provenance["baselineManifest"]["sha256"], artifact.sha256(BASELINE))
        self.assertEqual(provenance["verificationTools"]["lipo"], str(self.lipo.resolve()))
        self.assertEqual(provenance["verificationTools"]["codesign"], str(self.codesign.resolve()))
        tagged_provenance = json.loads((tagged / "candidate-provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(tagged_provenance["selectionMode"], "explicit-tag")

        verified = artifact.load_manifest(first / manifest_name, expected_version=VERSION)
        self.assertEqual(verified["tag"], TAG)
        report = (first / "candidate-report.md").read_text(encoding="utf-8")
        for required in (
            "NON-PROMOTABLE TEST FIXTURE",
            "test-fixture-non-promotable",
            "Schema-gate work",
            "memory_mode",
            "thread/start",
            "thread/resume",
            "mcp__RepoPromptCE",
            "minimumExternalVersion",
            "License and NOTICE review",
            "Manual approval and soak",
            "0.147.0",
            str(self.lipo),
            str(self.codesign),
        ):
            self.assertIn(required, report)
        self.assertEqual(BASELINE.read_bytes(), original_manifest)

    def test_fixture_mode_and_provenance_boundaries_fail_closed(self) -> None:
        offline_without_mode = self._run_raw(
            "--version",
            VERSION,
            "--release-json",
            str(self.release_path),
            "--asset-dir",
            str(self.assets),
            "--output-dir",
            str(self.temp / "unmarked-offline"),
            expected=1,
        )
        self.assertIn("--fixture-mode is required", offline_without_mode.stderr)

        latest_fixture = self._run(
            self.temp / "fixture-latest",
            selector=("--latest-stable",),
            expected=1,
        )
        self.assertIn("--latest-stable is unavailable in fixture mode", latest_fixture.stderr)

        baseline_copy = self.temp / "baseline.json"
        shutil.copyfile(BASELINE, baseline_copy)
        for label, override in (
            ("baseline", ("--baseline-manifest", str(baseline_copy))),
            ("lipo", ("--lipo", str(self.lipo))),
            ("codesign", ("--codesign", str(self.codesign))),
        ):
            with self.subTest(label=label):
                rejected = self._run_raw(
                    "--version",
                    VERSION,
                    *override,
                    "--output-dir",
                    str(self.temp / f"official-override-{label}"),
                    expected=1,
                )
                self.assertIn("--fixture-mode is required", rejected.stderr)

    def test_release_name_is_json_encoded_before_markdown_rendering(self) -> None:
        release = self._release()
        release["name"] = "unsafe` name\n## INJECTED [link](https://example.invalid)"
        self._write_release(release)
        output = self.temp / "encoded-name"
        self._run(output)
        report = (output / "candidate-report.md").read_text(encoding="utf-8")
        self.assertNotIn("\n## INJECTED", report)
        self.assertIn("\\n## INJECTED", report)
        self.assertIn("\\u0060", report)

    def test_online_download_and_archive_expansion_are_bounded(self) -> None:
        class FakeResponse(io.BytesIO):
            def __init__(self, payload: bytes, content_length: str | None = None) -> None:
                super().__init__(payload)
                self.headers = {} if content_length is None else {"Content-Length": content_length}

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *_args: object) -> None:
                self.close()

            @staticmethod
            def geturl() -> str:
                return "https://release-assets.githubusercontent.com/candidate"

        oversized_output = self.temp / "oversized-download"
        with mock.patch.object(
            candidate.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"12345"),
        ):
            with self.assertRaisesRegex(candidate.CandidateError, "exceeded release metadata size"):
                candidate.download_asset("https://github.com/openai/codex/asset", oversized_output, 4)
        self.assertFalse(oversized_output.exists())

        wrong_length_output = self.temp / "wrong-content-length"
        with mock.patch.object(
            candidate.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"1234", content_length="5"),
        ):
            with self.assertRaisesRegex(candidate.CandidateError, "response size disagrees"):
                candidate.download_asset("https://github.com/openai/codex/asset", wrong_length_output, 4)
        self.assertFalse(wrong_length_output.exists())

        archive = self.assets / "codex-package-aarch64-apple-darwin.tar.gz"
        with mock.patch.object(candidate, "MAX_EXPANDED_ARCHIVE_SIZE", 1):
            with self.assertRaisesRegex(candidate.CandidateError, "expanded size"):
                candidate.archive_paths(archive)
        with mock.patch.object(candidate, "MAX_ARCHIVE_MEMBERS", 1):
            with self.assertRaisesRegex(candidate.CandidateError, "member safety limit"):
                candidate.archive_paths(archive)

    def test_release_metadata_rejects_draft_prerelease_mismatch_missing_and_duplicate_assets(self) -> None:
        baseline = self._release()
        checksum_asset = copy.deepcopy(baseline["assets"][0])
        mutations = {
            "draft": lambda value: value.__setitem__("draft", True),
            "prerelease": lambda value: value.__setitem__("prerelease", True),
            "tag mismatch": lambda value: value.__setitem__("tag_name", "rust-v0.147.1"),
            "missing asset": lambda value: value["assets"].pop(),
            "duplicate asset": lambda value: value["assets"].append(copy.deepcopy(checksum_asset)),
            "wrong asset URL": lambda value: value["assets"][0].__setitem__(
                "browser_download_url", "https://example.invalid/codex-package_SHA256SUMS"
            ),
        }
        for index, (label, mutate) in enumerate(mutations.items()):
            with self.subTest(label=label):
                release = copy.deepcopy(baseline)
                mutate(release)
                self._write_release(release)
                self._run(self.temp / f"rejected-{index}", expected=1)
                self.assertFalse((self.temp / f"rejected-{index}").exists())
        self._write_release(baseline)

    def test_checksum_disagreement_fails_without_candidate_output(self) -> None:
        sums = self.assets / "codex-package_SHA256SUMS"
        lines = sums.read_text(encoding="utf-8").splitlines()
        lines[0] = f"{'0' * 64}  {lines[0].split()[1]}"
        sums.write_text("\n".join(lines) + "\n", encoding="utf-8")
        release = self._release()
        release["assets"][0]["size"] = sums.stat().st_size
        self._write_release(release)
        output = self.temp / "checksum-rejected"
        result = self._run(output, expected=1)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(output.exists())

    def test_package_layout_drift_fails_closed(self) -> None:
        unexpected = self.sources / "aarch64-apple-darwin" / "unexpected-runtime-file"
        unexpected.write_text("drift\n", encoding="utf-8")
        self._rebuild_assets_and_release()
        output = self.temp / "layout-rejected"
        result = self._run(output, expected=1)
        self.assertIn("package layout drift", result.stderr)
        self.assertFalse(output.exists())

    def test_signing_identity_drift_fails_closed(self) -> None:
        output = self.temp / "signature-rejected"
        result = self._run(output, env={"FAKE_TEAM_IDENTIFIER": "WRONGTEAM"}, expected=1)
        self.assertIn("TeamIdentifier", result.stderr)
        self.assertFalse(output.exists())

    def test_selector_and_output_safety_fail_closed(self) -> None:
        malformed = self._run(
            self.temp / "malformed",
            selector=("--version", "0.147.0-rc.1"),
            expected=1,
        )
        self.assertIn("stable numeric triplet", malformed.stderr)

        not_newer = self._run(
            self.temp / "not-newer",
            selector=("--version", "0.147.0"),
            expected=1,
        )
        self.assertIn("must be newer", not_newer.stderr)

        vendor_output = ROOT / "Vendor" / "Codex" / "candidate-test-output"
        self.assertFalse(vendor_output.exists())
        rejected = self._run(vendor_output, expected=1)
        self.assertIn("must not be written under Vendor", rejected.stderr)
        self.assertFalse(vendor_output.exists())

        existing = self.temp / "existing"
        existing.mkdir()
        rejected = self._run(existing, expected=1)
        self.assertIn("already exists", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
