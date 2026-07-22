#!/usr/bin/env python3
"""Offline tests for the pinned Codex standalone-package artifact pipeline."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "Scripts" / "codex_runtime_artifact.py"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def directory_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class CodexRuntimeArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="codex-artifact-test-"))
        self.addCleanup(lambda: shutil.rmtree(self.temp, ignore_errors=True))
        self.archives = self.temp / "archives"
        self.archives.mkdir()
        self.cache = self.temp / "cache"
        self.bundle = self.temp / "Codex"
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.lipo = self.bin / "lipo"
        self.codesign = self.bin / "codesign"
        write_executable(
            self.lipo,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_ARCH:-}" ]]; then printf '%s\\n' "$FAKE_ARCH"; exit 0; fi
sed -n 's/^ARCH=//p' "$2" | head -1
""",
        )
        write_executable(
            self.codesign,
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "--verify" ]]; then
    [[ "${FAKE_SIGNATURE_FAILURE:-0}" != "1" ]]
    exit
fi
path="${!#}"
identifier="$(basename "$path")"
team_identifier="2DC432GLL2"
authority="Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)"
if [[ "${FAKE_SIGNATURE_METADATA_FAILURE:-0}" == "1" ]]; then identifier=wrong; fi
case "${FAKE_SIGNATURE_PREFIX_COLLISION:-}" in
  identifier) identifier="${identifier}-collision" ;;
  team) team_identifier="${team_identifier}-collision" ;;
  authority) authority="${authority} Collision" ;;
esac
cat >&2 <<EOF
Identifier=$identifier
CodeDirectory flags=${FAKE_CODE_DIRECTORY_FLAGS:-0x10000(runtime)}
Authority=$authority
TeamIdentifier=$team_identifier
EOF
if [[ "${FAKE_OMIT_TIMESTAMP:-0}" != "1" ]]; then
    printf 'Timestamp=%s\n' "${FAKE_TIMESTAMP:-Jul 18, 2026 at 22:31:39}" >&2
fi
""",
        )
        self.manifest_path = self.make_fixture()

    def package_tree(self, target: str, architecture: str) -> Path:
        root = self.temp / f"source-{target}"
        metadata = {
            "layoutVersion": 1,
            "version": "0.144.6",
            "target": target,
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path",
        }
        (root / "bin").mkdir(parents=True)
        (root / "codex-path").mkdir()
        (root / "codex-resources" / "zsh" / "bin").mkdir(parents=True)
        (root / "codex-package.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        for relative in (
            "bin/codex",
            "bin/codex-code-mode-host",
            "codex-path/rg",
            "codex-resources/zsh/bin/zsh",
        ):
            write_executable(root / relative, f"ARCH={architecture}\nfixture={relative}\n")
        return root

    @staticmethod
    def tree_contract(root: Path) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            if path.is_dir():
                result.append({"path": relative, "kind": "directory"})
            else:
                result.append(
                    {
                        "path": relative,
                        "kind": "file",
                        "sha256": digest(path),
                        "executable": bool(path.stat().st_mode & 0o111),
                    }
                )
        return result

    @staticmethod
    def make_archive(
        source: Path,
        destination: Path,
        extra_member: str | None = None,
        *,
        files_first: bool = False,
    ) -> None:
        paths = sorted(source.rglob("*"))
        if files_first:
            paths.sort(key=lambda path: (path.is_dir(), path.as_posix()))
        with tarfile.open(destination, "w:gz") as tar:
            for path in paths:
                tar.add(path, arcname=path.relative_to(source).as_posix(), recursive=False)
            if extra_member is not None:
                info = tarfile.TarInfo(extra_member)
                info.size = 1
                tar.addfile(info, fileobj=__import__("io").BytesIO(b"x"))

    def write_manifest(self, packages: dict[str, dict[str, object]]) -> Path:
        sums = self.archives / "codex-package_SHA256SUMS"
        sums.write_text(
            "".join(f"{package['sha256']}  {package['archive']}\n" for package in packages.values()),
            encoding="utf-8",
        )
        manifest = {
            "schemaVersion": 1,
            "version": "0.144.6",
            "tag": "rust-v0.144.6",
            "releaseURL": "https://github.com/openai/codex/releases/tag/rust-v0.144.6",
            "checksums": {
                "asset": sums.name,
                "url": "https://github.com/openai/codex/releases/download/rust-v0.144.6/codex-package_SHA256SUMS",
                "sha256": digest(sums),
            },
            "packages": packages,
            "requiredLayout": [
                "codex-package.json",
                "bin/codex",
                "bin/codex-code-mode-host",
                "codex-resources",
                "codex-path",
            ],
            "machOFiles": [
                "bin/codex",
                "bin/codex-code-mode-host",
                "codex-path/rg",
                "codex-resources/zsh/bin/zsh",
            ],
            "signedExecutables": [
                {
                    "path": "bin/codex",
                    "identifier": "codex",
                    "teamIdentifier": "2DC432GLL2",
                    "authority": "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)",
                    "requiresHardenedRuntime": True,
                    "requiresTimestamp": True,
                },
                {
                    "path": "bin/codex-code-mode-host",
                    "identifier": "codex-code-mode-host",
                    "teamIdentifier": "2DC432GLL2",
                    "authority": "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)",
                    "requiresHardenedRuntime": True,
                    "requiresTimestamp": True,
                },
            ],
        }
        path = self.temp / "manifest.json"
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        return path

    def make_fixture(self) -> Path:
        packages: dict[str, dict[str, object]] = {}
        for target, architecture in (
            ("aarch64-apple-darwin", "arm64"),
            ("x86_64-apple-darwin", "x86_64"),
        ):
            source = self.package_tree(target, architecture)
            archive_name = f"codex-package-{target}.tar.gz"
            archive = self.archives / archive_name
            self.make_archive(source, archive)
            packages[target] = {
                "archive": archive_name,
                "url": f"https://github.com/openai/codex/releases/download/rust-v0.144.6/{archive_name}",
                "sha256": digest(archive),
                "architecture": architecture,
                "tree": self.tree_contract(source),
            }
        return self.write_manifest(packages)

    def run_tool(self, *arguments: str, env: dict[str, str] | None = None, expected: int = 0) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(TOOL),
            "--manifest",
            str(self.manifest_path),
            "--lipo",
            str(self.lipo),
            "--codesign",
            str(self.codesign),
            *arguments,
        ]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, **(env or {})})
        self.assertEqual(result.returncode, expected, msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result

    def acquire_all(self) -> None:
        self.run_tool(
            "acquire",
            "--arch",
            "all",
            "--archive-dir",
            str(self.archives),
            "--cache-root",
            str(self.cache),
        )

    def test_offline_acquire_and_status_verify_both_complete_packages(self) -> None:
        self.acquire_all()
        result = self.run_tool("status", "--cache-root", str(self.cache))
        self.assertIn("aarch64-apple-darwin", result.stdout)
        self.assertIn("x86_64-apple-darwin", result.stdout)
        packaged = self.cache / "0.144.6" / "aarch64-apple-darwin"
        self.assertTrue((packaged / "bin" / "codex-code-mode-host").is_file())
        self.assertTrue((packaged / "codex-resources" / "zsh" / "bin" / "zsh").is_file())

    def test_stage_and_verify_universal_bundle_uses_exact_target_directories(self) -> None:
        self.acquire_all()
        self.run_tool(
            "stage-bundle",
            "--arch",
            "all",
            "--cache-root",
            str(self.cache),
            "--bundle",
            str(self.bundle),
        )

        self.assertEqual(
            {path.name for path in self.bundle.iterdir()},
            {"aarch64-apple-darwin", "x86_64-apple-darwin"},
        )
        self.assertEqual(
            (self.bundle / "aarch64-apple-darwin" / "bin" / "codex").read_text(encoding="utf-8").splitlines()[0],
            "ARCH=arm64",
        )
        self.assertEqual(
            (self.bundle / "x86_64-apple-darwin" / "bin" / "codex").read_text(encoding="utf-8").splitlines()[0],
            "ARCH=x86_64",
        )
        self.run_tool("verify-bundle", "--arch", "all", "--bundle", str(self.bundle))

    def test_acquired_and_staged_package_roots_are_mode_0755(self) -> None:
        self.acquire_all()
        targets = ("aarch64-apple-darwin", "x86_64-apple-darwin")
        for target in targets:
            self.assertEqual(directory_mode(self.cache / "0.144.6" / target), 0o755)

        self.run_tool(
            "stage-bundle", "--arch", "all", "--cache-root", str(self.cache),
            "--bundle", str(self.bundle),
        )

        self.assertEqual(directory_mode(self.bundle), 0o755)
        for target in targets:
            self.assertEqual(directory_mode(self.bundle / target), 0o755)

    def test_verification_rejects_mode_0700_directories(self) -> None:
        self.acquire_all()
        package = self.cache / "0.144.6" / "aarch64-apple-darwin"
        package.chmod(0o700)
        invalid_package = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package), expected=1,
        )
        self.assertIn("directory mode must be 0755", invalid_package.stderr)
        self.assertIn("got 0700", invalid_package.stderr)
        package.chmod(0o755)

        self.run_tool(
            "stage-bundle", "--arch", "all", "--cache-root", str(self.cache),
            "--bundle", str(self.bundle),
        )
        for directory in (self.bundle, self.bundle / "x86_64-apple-darwin" / "codex-resources"):
            with self.subTest(directory=directory.relative_to(self.bundle)):
                directory.chmod(0o700)
                invalid_bundle = self.run_tool(
                    "verify-bundle", "--arch", "all", "--bundle", str(self.bundle), expected=1,
                )
                self.assertIn("directory mode must be 0755", invalid_bundle.stderr)
                self.assertIn("got 0700", invalid_bundle.stderr)
                directory.chmod(0o755)

    def test_verify_universal_bundle_rejects_missing_or_extra_target(self) -> None:
        self.acquire_all()
        self.run_tool(
            "stage-bundle", "--arch", "all", "--cache-root", str(self.cache),
            "--bundle", str(self.bundle),
        )
        shutil.rmtree(self.bundle / "x86_64-apple-darwin")
        missing = self.run_tool(
            "verify-bundle", "--arch", "all", "--bundle", str(self.bundle), expected=1,
        )
        self.assertIn("missing=['x86_64-apple-darwin']", missing.stderr)

        (self.bundle / "unexpected").mkdir()
        extra = self.run_tool(
            "verify-bundle", "--arch", "arm64", "--bundle", str(self.bundle), expected=1,
        )
        self.assertIn("extra=['unexpected']", extra.stderr)

    def test_stage_single_target_bundle_keeps_non_public_packaging_coherent(self) -> None:
        self.run_tool(
            "acquire", "--arch", "x86_64", "--archive-dir", str(self.archives),
            "--cache-root", str(self.cache),
        )
        self.run_tool(
            "stage-bundle", "--arch", "x86_64", "--cache-root", str(self.cache),
            "--bundle", str(self.bundle),
        )

        self.assertEqual([path.name for path in self.bundle.iterdir()], ["x86_64-apple-darwin"])
        self.run_tool("verify-bundle", "--arch", "x86_64", "--bundle", str(self.bundle))

    def test_verified_cache_hit_requires_no_source_or_network(self) -> None:
        self.acquire_all()
        shutil.rmtree(self.archives)
        self.run_tool(
            "acquire", "--arch", "all", "--archive-dir", str(self.archives),
            "--cache-root", str(self.cache),
        )

    def test_archive_checksum_mismatch_fails_without_cache(self) -> None:
        archive = self.archives / "codex-package-aarch64-apple-darwin.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"corrupt")
        result = self.run_tool(
            "acquire",
            "--arch",
            "arm64",
            "--archive-dir",
            str(self.archives),
            "--cache-root",
            str(self.cache),
            expected=1,
        )
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse((self.cache / "0.144.6" / "aarch64-apple-darwin").exists())

    def test_official_checksum_must_agree_with_repository_pin(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        sums = self.archives / "codex-package_SHA256SUMS"
        sums.write_text(sums.read_text(encoding="utf-8").replace(manifest["packages"]["aarch64-apple-darwin"]["sha256"], "0" * 64), encoding="utf-8")
        manifest["checksums"]["sha256"] = digest(sums)
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        result = self.run_tool(
            "acquire", "--arch", "arm64", "--archive-dir", str(self.archives),
            "--cache-root", str(self.cache), expected=1,
        )
        self.assertIn("official checksum and repository-pinned archive digest disagree", result.stderr)

    def test_manifest_requires_exact_official_release_and_asset_urls(self) -> None:
        mutations = (
            (
                "releaseURL",
                lambda manifest: manifest.__setitem__(
                    "releaseURL",
                    "https://github.com/openai/codex/releases/tag/rust-v0.144.7",
                ),
            ),
            (
                "checksum asset URL",
                lambda manifest: manifest["checksums"].__setitem__(
                    "url",
                    "https://github.com/openai/codex/releases/download/rust-v0.144.7/codex-package_SHA256SUMS",
                ),
            ),
            (
                "package asset URL",
                lambda manifest: manifest["packages"]["aarch64-apple-darwin"].__setitem__(
                    "url",
                    "https://example.invalid/codex-package-aarch64-apple-darwin.tar.gz",
                ),
            ),
        )
        baseline = self.manifest_path.read_text(encoding="utf-8")
        for label, mutate in mutations:
            with self.subTest(label=label):
                manifest = json.loads(baseline)
                mutate(manifest)
                self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
                result = self.run_tool("validate-manifest", expected=1)
                self.assertIn("URL", result.stderr)

    def test_manifest_version_drives_packaging_cache_path(self) -> None:
        result = self.run_tool("manifest-version")
        self.assertEqual(result.stdout.strip(), "0.144.6")
        source = (ROOT / "Scripts" / "package_app.sh").read_text(encoding="utf-8")
        self.assertIn('CODEX_VERSION="$(python3 "$CODEX_ARTIFACT_TOOL"', source)
        self.assertIn('stage-bundle', source)
        self.assertIn('--cache-root "$CODEX_CACHE_ROOT"', source)
        self.assertNotIn("CODEX_CACHE_ROOT/0.144.6", source)

    def test_archive_accepts_file_members_before_explicit_parent_directories(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        target = "aarch64-apple-darwin"
        package = manifest["packages"][target]
        archive = self.archives / package["archive"]
        self.make_archive(
            self.temp / f"source-{target}",
            archive,
            files_first=True,
        )
        package["sha256"] = digest(archive)
        self.manifest_path = self.write_manifest(manifest["packages"])

        self.run_tool(
            "acquire",
            "--arch",
            "arm64",
            "--archive-dir",
            str(self.archives),
            "--cache-root",
            str(self.cache),
        )

        self.assertTrue((self.cache / "0.144.6" / target / "bin" / "codex").is_file())

    def test_unpinned_archive_member_is_rejected(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        target = "aarch64-apple-darwin"
        package = manifest["packages"][target]
        archive = self.archives / package["archive"]
        self.make_archive(self.temp / f"source-{target}", archive, extra_member="unexpected-resource")
        package["sha256"] = digest(archive)
        self.manifest_path = self.write_manifest(manifest["packages"])
        result = self.run_tool(
            "acquire",
            "--arch",
            "arm64",
            "--archive-dir",
            str(self.archives),
            "--cache-root",
            str(self.cache),
            expected=1,
        )
        self.assertIn("unpinned member", result.stderr)

    def test_cached_tree_drift_is_rejected(self) -> None:
        self.acquire_all()
        binary = self.cache / "0.144.6" / "aarch64-apple-darwin" / "bin" / "codex"
        binary.write_bytes(binary.read_bytes() + b"drift")
        result = self.run_tool("status", "--cache-root", str(self.cache), expected=1)
        self.assertIn("package tree does not match pinned manifest", result.stdout)

    def test_version_metadata_mismatch_is_rejected_even_when_tree_is_repinned(self) -> None:
        self.acquire_all()
        target = "aarch64-apple-darwin"
        package = self.cache / "0.144.6" / target
        metadata_path = package / "codex-package.json"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["version"] = "0.144.7"
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        entry = next(item for item in manifest["packages"][target]["tree"] if item["path"] == "codex-package.json")
        entry["sha256"] = digest(metadata_path)
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        result = self.run_tool("verify", "--arch", "arm64", "--package", str(package), expected=1)
        self.assertIn("codex-package.json metadata mismatch", result.stderr)

    def test_architecture_and_signature_mismatch_are_rejected(self) -> None:
        self.acquire_all()
        package = self.cache / "0.144.6" / "aarch64-apple-darwin"
        arch = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package),
            env={"FAKE_ARCH": "x86_64"}, expected=1,
        )
        self.assertIn("architectures", arch.stderr)
        signature = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package),
            env={"FAKE_SIGNATURE_METADATA_FAILURE": "1"}, expected=1,
        )
        self.assertIn("signature metadata", signature.stderr)
        invalid_signature = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package),
            env={"FAKE_SIGNATURE_FAILURE": "1"}, expected=1,
        )
        self.assertIn("signature check", invalid_signature.stderr)
        no_runtime = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package),
            env={"FAKE_CODE_DIRECTORY_FLAGS": "0x2(adhoc)"}, expected=1,
        )
        self.assertIn("hardened-runtime signing flag", no_runtime.stderr)
        no_timestamp = self.run_tool(
            "verify", "--arch", "arm64", "--package", str(package),
            env={"FAKE_OMIT_TIMESTAMP": "1"}, expected=1,
        )
        self.assertIn("trusted signing timestamp", no_timestamp.stderr)

    def test_none_signing_timestamps_are_rejected(self) -> None:
        self.acquire_all()
        package = self.cache / "0.144.6" / "aarch64-apple-darwin"
        for timestamp in ("none", "  NoNe  "):
            with self.subTest(timestamp=timestamp):
                result = self.run_tool(
                    "verify",
                    "--arch",
                    "arm64",
                    "--package",
                    str(package),
                    env={"FAKE_TIMESTAMP": timestamp},
                    expected=1,
                )
                self.assertIn("trusted signing timestamp", result.stderr)

    def test_signing_metadata_prefix_collisions_are_rejected(self) -> None:
        self.acquire_all()
        package = self.cache / "0.144.6" / "aarch64-apple-darwin"
        for field in ("identifier", "team", "authority"):
            with self.subTest(field=field):
                result = self.run_tool(
                    "verify",
                    "--arch",
                    "arm64",
                    "--package",
                    str(package),
                    env={"FAKE_SIGNATURE_PREFIX_COLLISION": field},
                    expected=1,
                )
                self.assertIn("must equal", result.stderr)

    def test_package_script_embeds_before_outer_sign_and_never_resigns_codex(self) -> None:
        source = (ROOT / "Scripts" / "package_app.sh").read_text(encoding="utf-8")
        embed = source.index('phase "Embedding verified Codex $CODEX_VERSION target package artifacts"')
        sign = source.index('phase "Signing app bundle"')
        post_sign = source.index("# The outer signature seals the resource tree")
        self.assertLess(embed, sign)
        self.assertGreater(post_sign, sign)
        signing_section = source[sign:post_sign]
        self.assertNotIn('sign_path "$CODEX_APP_DIR"', signing_section)
        self.assertIn("Contents/Resources/BundledRuntimes/Codex", source)
        self.assertIn('stage-bundle', source)
        self.assertIn('verify-bundle', source)
        self.assertIn('CODEX_BUNDLE_ARCH="all"', source)


if __name__ == "__main__":
    unittest.main()
