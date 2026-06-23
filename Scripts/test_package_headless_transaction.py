#!/usr/bin/env python3
"""Deterministic no-build tests for transactional Headless packaging."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Scripts" / "package_headless.sh"
MANIFEST_TOOL = ROOT / "Scripts" / "headless_artifact_manifest.py"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o700)


def release_metadata() -> tuple[str, str]:
    values: dict[str, str] = {}
    for raw_line in (ROOT / "version.env").read_text(encoding="utf-8").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values["MARKETING_VERSION"], values["BUILD_NUMBER"]


class HeadlessPackagingTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="headless-package-transaction-")
        self.root = Path(self.temporary.name)
        self.tools_root = self.root / "HeadlessTools"
        self.tools_root.mkdir()
        self.target = self.tools_root / "Release"
        self.unrelated_candidate = self.tools_root / ".Release.candidate.other-invocation"
        self.unrelated_candidate.mkdir()
        (self.unrelated_candidate / "keep").write_text("unrelated\n", encoding="utf-8")

        self.version, self.build = release_metadata()
        self.input_binary = self.root / "input-repoprompt-headless"
        write_executable(
            self.input_binary,
            f"""#!/bin/sh
if [ "${{1:-}}" = "--version" ]; then
    printf '%s\\n' 'repoprompt-headless {self.version} (build {self.build})'
    exit 0
fi
exit 64
""",
        )

        self.codesign_tool = self.root / "codesign"
        write_executable(self.codesign_tool, "#!/bin/sh\nexit 0\n")
        self.lipo_tool = self.root / "lipo"
        write_executable(self.lipo_tool, "#!/bin/sh\nprintf '%s\\n' 'arm64 x86_64'\n")

        self.symbol_count = self.root / "symbol-count"
        self.symbols_tool = self.root / "verify-symbols.py"
        write_executable(
            self.symbols_tool,
            """#!/usr/bin/env python3
import os
import sys
from pathlib import Path

count_path = Path(os.environ["HEADLESS_TEST_SYMBOL_COUNT"])
count = int(count_path.read_text(encoding="utf-8")) + 1 if count_path.exists() else 1
count_path.write_text(str(count), encoding="utf-8")
mode = os.environ.get("HEADLESS_TEST_MODE", "success")
if mode == "candidate-failure" and count == 1:
    print("injected candidate verification failure", file=sys.stderr)
    raise SystemExit(41)
if mode in ("final-failure", "first-install-final-failure") and count == 2:
    print("injected final verification failure", file=sys.stderr)
    raise SystemExit(42)
""",
        )

        self.promotion_tool = self.root / "promote.py"
        write_executable(
            self.promotion_tool,
            """#!/usr/bin/env python3
import os
import signal
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
mode = os.environ.get("HEADLESS_TEST_MODE", "success")
is_candidate = ".candidate." in source.name
if mode == "promotion-failure" and is_candidate:
    print("injected directory promotion failure", file=sys.stderr)
    raise SystemExit(43)
os.rename(source, destination)
if mode == "signal" and is_candidate:
    os.kill(os.getppid(), signal.SIGTERM)
    raise SystemExit(143)
""",
        )

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(ROOT),
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(ROOT / "Scripts"),
                "REPOPROMPT_HEADLESS_TOOLS_ROOT": str(self.tools_root),
                "REPOPROMPT_HEADLESS_PACKAGE_INPUT_BINARY": str(self.input_binary),
                "REPOPROMPT_HEADLESS_PACKAGE_EXPECTED_ARCHITECTURES": "arm64,x86_64",
                "REPOPROMPT_HEADLESS_CODESIGN_TOOL": str(self.codesign_tool),
                "REPOPROMPT_HEADLESS_LIPO_TOOL": str(self.lipo_tool),
                "REPOPROMPT_HEADLESS_TREE_SITTER_SYMBOLS_TOOL": str(self.symbols_tool),
                "REPOPROMPT_HEADLESS_PROMOTION_TOOL": str(self.promotion_tool),
                "HEADLESS_TEST_SYMBOL_COUNT": str(self.symbol_count),
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def seed_prior_generation(self) -> dict[str, tuple[int, int, int, bytes | None]]:
        self.target.mkdir(mode=0o751)
        binary = self.target / "repoprompt-headless"
        write_executable(binary, "#!/bin/sh\nprintf 'prior generation\\n'\n")
        binary.chmod(0o711)
        manifest = self.target / "artifact-manifest.json"
        manifest.write_bytes(b'{"prior":true}\n')
        manifest.chmod(0o640)
        return self.snapshot(self.target)

    def snapshot(self, root: Path) -> dict[str, tuple[int, int, int, bytes | None]]:
        result: dict[str, tuple[int, int, int, bytes | None]] = {}
        for path in [root, *sorted(root.rglob("*"))]:
            relative = "." if path == root else str(path.relative_to(root))
            info = path.lstat()
            contents = path.read_bytes() if stat.S_ISREG(info.st_mode) else None
            result[relative] = (info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode), contents)
        return result

    def run_package(self, mode: str) -> subprocess.CompletedProcess[str]:
        environment = dict(self.environment)
        environment["HEADLESS_TEST_MODE"] = mode
        return subprocess.run(
            [str(PACKAGE), "release"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def assert_prior_restored(
        self, expected: dict[str, tuple[int, int, int, bytes | None]]
    ) -> None:
        self.assertTrue(self.target.is_dir())
        self.assertEqual(self.snapshot(self.target), expected)

    def assert_transaction_cleanup(self) -> None:
        self.assertTrue(self.unrelated_candidate.is_dir())
        self.assertEqual(
            (self.unrelated_candidate / "keep").read_text(encoding="utf-8"),
            "unrelated\n",
        )
        leftovers = [
            path.name
            for path in self.tools_root.iterdir()
            if path.name.startswith((".Release.candidate.", ".Release.backup."))
            and path != self.unrelated_candidate
        ]
        self.assertEqual(leftovers, [])

    def test_success_promotes_verified_pair_with_fixed_manifest_path_and_schema(self) -> None:
        expected_prior = self.seed_prior_generation()

        result = self.run_package("success")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.snapshot(self.target), expected_prior)
        binary = self.target / "repoprompt-headless"
        manifest_path = self.target / "artifact-manifest.json"
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(manifest_path.stat().st_mode), 0o600)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(
            set(manifest),
            {
                "artifact",
                "build",
                "configuration",
                "displayName",
                "generatedAt",
                "product",
                "protocolVersion",
                "schemaVersion",
                "source",
                "target",
                "version",
            },
        )
        self.assertEqual(
            set(manifest["artifact"]),
            {
                "architectures",
                "mode",
                "ownerUID",
                "path",
                "sha256",
                "size",
                "versionOutput",
            },
        )
        self.assertEqual(manifest["artifact"]["path"], str(binary.resolve()))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assert_transaction_cleanup()

    def test_unexpected_existing_generation_entry_is_refused_unchanged(self) -> None:
        self.seed_prior_generation()
        unexpected = self.target / "unmanaged-entry"
        unexpected.write_text("must survive refusal\n", encoding="utf-8")
        expected = self.snapshot(self.target)

        result = self.run_package("success")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace unmanaged Headless artifact directory", result.stderr)
        self.assertIn("unmanaged-entry", result.stderr)
        self.assert_prior_restored(expected)
        self.assertFalse(self.symbol_count.exists())
        self.assert_transaction_cleanup()

    def test_missing_existing_generation_leaf_is_refused_unchanged(self) -> None:
        self.seed_prior_generation()
        (self.target / "artifact-manifest.json").unlink()
        expected = self.snapshot(self.target)

        result = self.run_package("success")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace unmanaged Headless artifact directory", result.stderr)
        self.assertIn("artifact-manifest.json", result.stderr)
        self.assert_prior_restored(expected)
        self.assertFalse(self.symbol_count.exists())
        self.assert_transaction_cleanup()

    def test_symlink_existing_generation_leaf_is_refused_unchanged(self) -> None:
        self.seed_prior_generation()
        manifest = self.target / "artifact-manifest.json"
        outside_manifest = self.root / "outside-manifest.json"
        outside_manifest.write_text('{"outside":true}\n', encoding="utf-8")
        manifest.unlink()
        manifest.symlink_to(outside_manifest)
        expected = self.snapshot(self.target)

        result = self.run_package("success")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace unmanaged Headless artifact directory", result.stderr)
        self.assertIn("artifact-manifest.json", result.stderr)
        self.assert_prior_restored(expected)
        self.assertEqual(outside_manifest.read_text(encoding="utf-8"), '{"outside":true}\n')
        self.assertFalse(self.symbol_count.exists())
        self.assert_transaction_cleanup()

    def test_artifact_path_rejects_relative_and_non_normalized_inputs(self) -> None:
        invalid_paths = {
            "relative": "relative/repoprompt-headless",
            "non-normalized": f"{self.root}/fixed/../target/repoprompt-headless",
        }
        for label, artifact_path in invalid_paths.items():
            with self.subTest(label=label):
                output = self.root / f"manifest-{label}.json"
                result = subprocess.run(
                    [
                        "python3",
                        str(MANIFEST_TOOL),
                        "write",
                        "--binary",
                        str(self.input_binary),
                        "--artifact-path",
                        artifact_path,
                        "--output",
                        str(output),
                        "--source-root",
                        str(ROOT),
                        "--configuration",
                        "release",
                        "--version",
                        self.version,
                        "--build",
                        self.build,
                        "--expected-architectures",
                        "arm64,x86_64",
                        "--lipo-tool",
                        str(self.lipo_tool),
                    ],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("must be an absolute normalized path", result.stderr)
                self.assertFalse(output.exists())

    def test_candidate_failure_never_touches_prior_generation(self) -> None:
        expected = self.seed_prior_generation()

        result = self.run_package("candidate-failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected candidate verification failure", result.stderr)
        self.assert_prior_restored(expected)
        self.assert_transaction_cleanup()

    def test_promotion_failure_restores_exact_prior_generation(self) -> None:
        expected = self.seed_prior_generation()

        result = self.run_package("promotion-failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected directory promotion failure", result.stderr)
        self.assert_prior_restored(expected)
        self.assert_transaction_cleanup()

    def test_final_verification_failure_restores_exact_prior_generation(self) -> None:
        expected = self.seed_prior_generation()

        result = self.run_package("final-failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected final verification failure", result.stderr)
        self.assert_prior_restored(expected)
        self.assert_transaction_cleanup()

    def test_first_install_failure_leaves_no_public_pair(self) -> None:
        result = self.run_package("first-install-final-failure")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("injected final verification failure", result.stderr)
        self.assertFalse(self.target.exists())
        self.assert_transaction_cleanup()

    def test_signal_after_directory_promotion_restores_exact_prior_generation(self) -> None:
        expected = self.seed_prior_generation()

        result = self.run_package("signal")

        self.assertEqual(result.returncode, 143, f"{result.stdout}\n{result.stderr}")
        self.assert_prior_restored(expected)
        self.assert_transaction_cleanup()


if __name__ == "__main__":
    unittest.main()
