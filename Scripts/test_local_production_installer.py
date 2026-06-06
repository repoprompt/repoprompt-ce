#!/usr/bin/env python3
"""Focused offline regression tests for the local production installer."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
PINNED_CERTIFICATE_NAME = "RepoPrompt CE Local Self-Signed Code Signing"
SHA1_A = "1" * 40
SHA1_B = "2" * 40
SHA1_C = "3" * 40
SHA256_A = "A" * 64
SHA256_B = "B" * 64
SHA256_C = "C" * 64


def certificate(
    sha1: str,
    sha256: str,
    *,
    private_key: bool = True,
    expired: bool = False,
    name: str = PINNED_CERTIFICATE_NAME,
) -> dict[str, Any]:
    return {
        "certificateName": name,
        "sha1": sha1,
        "sha256": sha256,
        "notAfter": "2020-01-01T00:00:00Z" if expired else "2099-01-01T00:00:00Z",
        "hasPrivateKey": private_key,
        "isExpired": expired,
    }


class LocalProductionIdentityToolTests(unittest.TestCase):
    def test_command_inventory_parses_all_exact_name_identities_independent_of_output_order(self) -> None:
        spec = importlib.util.spec_from_file_location("local_signing_identity", SCRIPT_DIR / "local_signing_identity.py")
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        pem_b = b"-----BEGIN CERTIFICATE-----\nCERT-B\n-----END CERTIFICATE-----\n"
        pem_a = b"-----BEGIN CERTIFICATE-----\nCERT-A\n-----END CERTIFICATE-----\n"
        pem_without_key = b"-----BEGIN CERTIFICATE-----\nCERT-C\n-----END CERTIFICATE-----\n"
        identity_output = (
            f'  1) {SHA1_B} "{PINNED_CERTIFICATE_NAME}"\n'
            f'  2) {SHA1_A} "{PINNED_CERTIFICATE_NAME}"\n'
            f'  3) {SHA1_C} "{PINNED_CERTIFICATE_NAME} Copy"\n'
        ).encode()

        def fake_run_command(arguments: list[str], *, input_data: bytes | None = None) -> bytes:
            if arguments[:2] == ["security", "find-identity"]:
                return identity_output
            self.assertEqual(arguments[:3], ["openssl", "x509", "-noout"])
            marker = "A" if b"CERT-A" in (input_data or b"") else "B" if b"CERT-B" in (input_data or b"") else "C"
            values = {
                "A": (SHA1_A, SHA256_A),
                "B": (SHA1_B, SHA256_B),
                "C": (SHA1_C, SHA256_C),
            }
            if "-subject" in arguments:
                return f"subject=O=RepoPrompt,CN={PINNED_CERTIFICATE_NAME}\n".encode()
            if "-enddate" in arguments:
                return b"notAfter=Jan  1 00:00:00 2099 GMT\n"
            fingerprint = values[marker][0 if "-sha1" in arguments else 1]
            label = "SHA1" if "-sha1" in arguments else "sha256"
            return f"{label} Fingerprint={fingerprint}\n".encode()

        certificate_result = subprocess.CompletedProcess(
            ["security"],
            0,
            stdout=pem_b + pem_without_key + pem_a,
            stderr=b"",
        )
        with mock.patch.object(module, "run_command", side_effect=fake_run_command), mock.patch.object(
            module.subprocess,
            "run",
            return_value=certificate_result,
        ):
            inventory = module.inventory_from_commands(
                PINNED_CERTIFICATE_NAME,
                "/fixture/login.keychain-db",
                module.evaluation_time("2030-01-01T00:00:00Z"),
            )

        self.assertEqual([item["sha256"] for item in inventory["candidates"]], [SHA256_A, SHA256_B])
        by_fingerprint = {item["sha256"]: item for item in inventory["matchingCertificates"]}
        self.assertFalse(by_fingerprint[SHA256_C]["hasPrivateKey"])

    def test_offline_inventory_filters_exact_name_private_key_and_expiry_and_sorts(self) -> None:
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT_DIR / "local_signing_identity.py"),
                "inventory",
                "--certificate-name",
                PINNED_CERTIFICATE_NAME,
                "--keychain",
                "/unused",
                "--fixture",
                str(SCRIPT_DIR / "Fixtures" / "local_signing_identity_inventory.json"),
                "--at",
                "2030-01-01T00:00:00Z",
            ],
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        inventory = json.loads(result.stdout)
        self.assertEqual([item["sha256"] for item in inventory["candidates"]], [SHA256_A, SHA256_B])
        by_fingerprint = {item["sha256"]: item for item in inventory["matchingCertificates"]}
        self.assertFalse(by_fingerprint[SHA256_C]["hasPrivateKey"])
        self.assertTrue(by_fingerprint["D" * 64]["isExpired"])
        self.assertNotIn("E" * 64, by_fingerprint)

    def test_registry_reader_rejects_symlinks_like_runtime_loader(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target.json"
            target.write_text("{}", encoding="utf-8")
            target.chmod(0o600)
            link = root / "local-signing-identity-v1.json"
            link.symlink_to(target)
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT_DIR / "local_signing_identity.py"),
                    "read-registry",
                    "--path",
                    str(link),
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("not a regular file", result.stderr)

    def test_registry_write_is_atomic_owner_only_and_versioned(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Application Support" / "RepoPrompt CE" / "local-signing-identity-v1.json"
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT_DIR / "local_signing_identity.py"),
                    "write-registry",
                    "--path",
                    str(path),
                    "--certificate-name",
                    PINNED_CERTIFICATE_NAME,
                    "--fingerprint",
                    SHA256_A.lower(),
                    "--generation",
                    "3",
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8")),
                {
                    "schemaVersion": 1,
                    "certificateName": PINNED_CERTIFICATE_NAME,
                    "certificateSHA256": SHA256_A,
                    "serviceGeneration": 3,
                },
            )
            self.assertEqual(list(path.parent.glob(f".{path.name}.*")), [])


class LocalProductionInstallerTests(unittest.TestCase):
    def test_finder_launcher_routes_confirmed_install_through_conductor(self) -> None:
        launcher = ROOT_DIR / "Install RepoPrompt CE Local Production.command"
        self.assertTrue(os.access(launcher, os.X_OK))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            copied_launcher = root / launcher.name
            shutil.copy2(launcher, copied_launcher)
            capture = root / "capture.txt"
            conductor = root / "conductor"
            conductor.write_text(
                "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$CONFIRM_LOCAL_PRODUCTION_INSTALL\" > \"$LAUNCHER_CAPTURE\"\nprintf '%s\\n' \"$@\" >> \"$LAUNCHER_CAPTURE\"\n",
                encoding="utf-8",
            )
            conductor.chmod(0o755)

            env = os.environ.copy()
            env["LAUNCHER_CAPTURE"] = str(capture)
            result = subprocess.run(
                ["bash", str(copied_launcher)],
                env=env,
                input="y\n\n",
                text=True,
                capture_output=True,
                timeout=10,
            )
            captured_lines = capture.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(captured_lines, ["1", "release", "local-install"])
        self.assertIn("replaces any existing app at", result.stdout)

    def test_finder_launcher_decline_does_not_invoke_conductor(self) -> None:
        launcher = ROOT_DIR / "Install RepoPrompt CE Local Production.command"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            copied_launcher = root / launcher.name
            shutil.copy2(launcher, copied_launcher)
            capture = root / "capture.txt"
            conductor = root / "conductor"
            conductor.write_text("#!/bin/bash\nprintf 'invoked\\n' > \"$LAUNCHER_CAPTURE\"\n", encoding="utf-8")
            conductor.chmod(0o755)
            env = os.environ.copy()
            env["LAUNCHER_CAPTURE"] = str(capture)
            result = subprocess.run(
                ["bash", str(copied_launcher)],
                env=env,
                input="n\n",
                text=True,
                capture_output=True,
                timeout=10,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(capture.exists())
        self.assertIn("Install canceled.", result.stdout)

    def test_local_entitlements_and_packaging_require_fingerprint_metadata(self) -> None:
        template = ROOT_DIR / "AppBundle" / "RepoPrompt.local-self-signed.entitlements.template"
        with template.open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(
            entitlements,
            {
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.cs.disable-library-validation": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.temporary-exception.mach-lookup.global-name": [
                    "__BUNDLE_ID__-spks",
                    "__BUNDLE_ID__-spki",
                ],
            },
        )
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        self.assertIn("LOCAL_SIGNING_CERTIFICATE_SHA256", package_script)
        info_template = (ROOT_DIR / "AppBundle" / "Info.plist.template").read_text(encoding="utf-8")
        self.assertIn("RepoPromptLocalSigningCertificateSHA256", info_template)
        self.assertIn("RepoPromptLocalSecureStorageGeneration", info_template)
        self.assertIn("--extract-certificates", package_script)
        self.assertIn("Extracted designated requirement", package_script)

    def test_first_use_adopts_sole_identity_and_writes_registry(self) -> None:
        result, context = self.run_installer([certificate(SHA1_A, SHA256_A)], expected_sha1=SHA1_A)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        generation = self.registry(context)["serviceGeneration"]
        self.assertGreaterEqual(generation, 1 << 61)
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertIn(f"Selected local certificate SHA-256: {SHA256_A}", result.stdout)
        self.assertIn(f'certificate leaf = H"{SHA1_A}"', result.stdout)
        self.assertEqual(
            context["package_capture"].read_text(encoding="utf-8").strip(),
            f"{SHA1_A}|{SHA256_A}|{generation}",
        )
        self.assertNotIn("find-identity", context["security_log"].read_text(encoding="utf-8"))

    def test_multiple_first_use_candidates_fail_with_fingerprints_and_explicit_selection_succeeds(self) -> None:
        failed, _ = self.run_installer(
            [certificate(SHA1_B, SHA256_B), certificate(SHA1_A, SHA256_A)],
            expected_sha1=SHA1_A,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(SHA256_A, failed.stderr)
        self.assertIn(SHA256_B, failed.stderr)
        self.assertIn("LOCAL_SIGNING_IDENTITY_SHA256=<fingerprint>", failed.stderr)

        selected, context = self.run_installer(
            [certificate(SHA1_B, SHA256_B), certificate(SHA1_A, SHA256_A)],
            selected=SHA256_B,
            expected_sha1=SHA1_B,
        )
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_B)

    def test_registered_missing_expired_or_private_keyless_identity_fails_without_reminting(self) -> None:
        scenarios = [
            ([], "is missing"),
            ([certificate(SHA1_A, SHA256_A, expired=True)], "expired"),
            ([certificate(SHA1_A, SHA256_A, private_key=False)], "does not have an available private key"),
        ]
        for certificates, expected_message in scenarios:
            with self.subTest(expected_message=expected_message):
                result, context = self.run_installer(
                    certificates,
                    registry={"fingerprint": SHA256_A, "generation": 2},
                    expected_sha1=SHA1_A,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_message, result.stderr)
                self.assertFalse(context["import_log"].exists())
                self.assertEqual(self.registry(context)["serviceGeneration"], 2)

    def test_first_use_with_certificate_without_private_key_mints_exactly_one_identity(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A, private_key=False)],
            after_mint=[
                certificate(SHA1_A, SHA256_A, private_key=False),
                certificate(SHA1_C, SHA256_C),
            ],
            expected_sha1=SHA1_C,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_C)
        self.assertTrue(context["import_log"].exists())

    def test_explicit_rotation_advances_generation_and_preserves_prior_service_generation(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_B)
        self.assertEqual(self.registry(context)["serviceGeneration"], 5)
        self.assertIn("prior local secure-storage generation inaccessible", result.stderr)
        self.assertEqual(context["package_capture"].read_text(encoding="utf-8").strip(), f"{SHA1_B}|{SHA256_B}|5")

    def test_rotation_without_selection_mints_one_new_identity(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A)],
            registry={"fingerprint": SHA256_A, "generation": 1},
            rotate=True,
            after_mint=[certificate(SHA1_A, SHA256_A), certificate(SHA1_C, SHA256_C)],
            expected_sha1=SHA1_C,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_C)
        self.assertEqual(self.registry(context)["serviceGeneration"], 2)

    def test_two_consecutive_installs_keep_fingerprint_generation_and_designated_requirement(self) -> None:
        first, context = self.run_installer([certificate(SHA1_A, SHA256_A)], expected_sha1=SHA1_A)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_requirement = self.requirement_line(first.stdout)
        first_generation = self.registry(context)["serviceGeneration"]
        second = self.invoke(context)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        self.assertEqual(self.registry(context)["serviceGeneration"], first_generation)
        self.assertEqual(self.requirement_line(second.stdout), first_requirement)
        self.assertFalse(context["import_log"].exists())

    def test_existing_install_lock_fails_closed_without_removing_other_owner_lock(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A)],
            expected_sha1=SHA1_A,
            preexisting_lock=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another local production install is active", result.stderr)
        self.assertTrue(Path(f"{context['registry']}.lock").is_dir())

    def test_failed_registry_backup_preserves_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
            fail_registry_backup_copy=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        self.assertEqual(self.registry(context)["serviceGeneration"], 4)
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_registry_write_restores_prior_app_and_exact_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
            fail_registry_write=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        self.assertEqual(self.registry(context)["serviceGeneration"], 4)
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_app_backup_preserves_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
            fail_app_backup_move=True,
            fail_registry_restore_copy=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        self.assertEqual(self.registry(context)["serviceGeneration"], 4)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_registry_restore_preserves_snapshot_for_manual_recovery(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
            fail_registry_write=True,
            fail_registry_restore_copy=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(context["registry"].read_text(encoding="utf-8"), "damaged registry\n")
        match = re.search(r"Preserving failed transaction snapshot for manual recovery: ([^\n]+)", result.stderr)
        self.assertIsNotNone(match, result.stderr)
        preserved = Path(match.group(1))
        self.addCleanup(shutil.rmtree, preserved, True)
        snapshot = preserved / "local-signing-identity-registry.backup"
        self.assertTrue(snapshot.is_file())
        self.assertEqual(json.loads(snapshot.read_text(encoding="utf-8"))["certificateSHA256"], SHA256_A)

    def test_failed_postwrite_registry_verification_restores_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A), certificate(SHA1_B, SHA256_B)],
            registry={"fingerprint": SHA256_A, "generation": 4},
            selected=SHA256_B,
            rotate=True,
            expected_sha1=SHA1_B,
            fail_registry_verification=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context)["certificateSHA256"], SHA256_A)
        self.assertEqual(self.registry(context)["serviceGeneration"], 4)

    def test_failed_replacement_restores_prior_app_and_does_not_write_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, SHA256_A)],
            expected_sha1=SHA1_A,
            fail_final_install_move=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertFalse(context["registry"].exists())

    def test_certificate_minting_omits_legacy_when_openssl_does_not_support_it(self) -> None:
        result, _ = self.run_installer(
            [],
            after_mint=[certificate(SHA1_C, SHA256_C)],
            expected_sha1=SHA1_C,
            openssl_rejects_legacy=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_installer(
        self,
        certificates: list[dict[str, Any]],
        *,
        expected_sha1: str,
        registry: dict[str, Any] | None = None,
        selected: str | None = None,
        rotate: bool = False,
        after_mint: list[dict[str, Any]] | None = None,
        fail_final_install_move: bool = False,
        fail_app_backup_move: bool = False,
        fail_registry_backup_copy: bool = False,
        fail_registry_write: bool = False,
        fail_registry_restore_copy: bool = False,
        openssl_rejects_legacy: bool = False,
        preexisting_lock: bool = False,
        fail_registry_verification: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        installer_tmp = temp_dir / "tmp"
        installer_tmp.mkdir()
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "install_local_production.sh", scripts / "install_local_production.sh")
        shutil.copy2(SCRIPT_DIR / "local_signing_identity.py", scripts / "local_signing_identity.py")
        if fail_registry_verification or fail_registry_write:
            real_tool = scripts / "local_signing_identity_real.py"
            shutil.move(scripts / "local_signing_identity.py", real_tool)
            (scripts / "local_signing_identity.py").write_text(
                textwrap.dedent(
                    """\
                    import os
                    import subprocess
                    import sys
                    from pathlib import Path

                    marker = os.environ["FAIL_REGISTRY_READ_MARKER"]
                    real_tool = os.path.join(os.path.dirname(__file__), "local_signing_identity_real.py")
                    command = sys.argv[1] if len(sys.argv) > 1 else ""
                    if command == "write-registry" and os.environ.get("FAIL_REGISTRY_WRITE") == "1":
                        path = Path(sys.argv[sys.argv.index("--path") + 1])
                        path.write_text("damaged registry\\n", encoding="utf-8")
                        path.chmod(0o644)
                        print("ERROR: simulated registry write failure", file=sys.stderr)
                        raise SystemExit(2)
                    if command == "read-registry" and os.path.exists(marker):
                        print("ERROR: simulated post-write registry verification failure", file=sys.stderr)
                        raise SystemExit(2)
                    result = subprocess.run([sys.executable, real_tool, *sys.argv[1:]])
                    if command == "write-registry" and result.returncode == 0:
                        open(marker, "w", encoding="utf-8").close()
                    raise SystemExit(result.returncode)
                    """
                ),
                encoding="utf-8",
            )
        (root / "version.env").write_text(
            'APP_NAME=RepoPrompt\nDISPLAY_NAME="RepoPrompt CE"\nBUNDLE_ID=com.pvncher.repoprompt.ce\n',
            encoding="utf-8",
        )

        build_dir = temp_dir / "build"
        install_dir = temp_dir / "Applications"
        installed_app = install_dir / "RepoPrompt CE.app"
        installed_app.mkdir(parents=True)
        (installed_app / "payload.txt").write_text("old\n", encoding="utf-8")
        keychain = temp_dir / "Library" / "Keychains" / "login keychain-db"
        keychain.parent.mkdir(parents=True)
        keychain.touch()
        fixture = temp_dir / "inventory.json"
        fixture.write_text(json.dumps({"certificates": certificates}), encoding="utf-8")
        after_fixture = temp_dir / "inventory-after-mint.json"
        after_fixture.write_text(json.dumps({"certificates": after_mint or certificates}), encoding="utf-8")
        registry_path = temp_dir / "Application Support" / "RepoPrompt CE" / "local-signing-identity-v1.json"
        if registry:
            registry_path.parent.mkdir(parents=True)
            registry_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "certificateName": PINNED_CERTIFICATE_NAME,
                        "certificateSHA256": registry["fingerprint"],
                        "serviceGeneration": registry["generation"],
                    }
                ),
                encoding="utf-8",
            )
            registry_path.chmod(0o600)
        if preexisting_lock:
            lock_path = Path(f"{registry_path}.lock")
            lock_path.mkdir(parents=True)
            (lock_path / "pid").write_text("99999\n", encoding="utf-8")

        package_capture = temp_dir / "package-capture.txt"
        (scripts / "package_app.sh").write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                app="$FAKE_BUILD_DIR/RepoPrompt.app"
                mkdir -p "$app/Contents"
                printf 'new\\n' > "$app/payload.txt"
                printf '%s|%s|%s\\n' "$LOCAL_SIGNING_CERTIFICATE_SHA1" "$LOCAL_SIGNING_CERTIFICATE_SHA256" "$LOCAL_SIGNING_SERVICE_GENERATION" >> "$PACKAGE_CAPTURE"
                cat > "$app/Contents/Info.plist" <<EOF
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>RepoPromptSigningMode</key><string>local-self-signed</string>
                  <key>RepoPromptLocalSigningCertificateSHA256</key><string>$LOCAL_SIGNING_CERTIFICATE_SHA256</string>
                  <key>RepoPromptLocalSecureStorageGeneration</key><string>$LOCAL_SIGNING_SERVICE_GENERATION</string>
                </dict></plist>
                EOF
                """
            ),
            encoding="utf-8",
        )
        (scripts / "package_app.sh").chmod(0o755)

        bin_dir = temp_dir / "bin"
        bin_dir.mkdir()
        security_log = temp_dir / "security.log"
        import_log = temp_dir / "imported-identity"
        self.write_stub(
            bin_dir,
            "security",
            """\
            printf '%s\\n' "$*" >> "$SECURITY_LOG"
            case "$1" in
                default-keychain) printf '    "%s"\\n' "$FAKE_KEYCHAIN" ;;
                import)
                    cp "$FAKE_AFTER_MINT_FIXTURE" "$FAKE_INVENTORY_FIXTURE"
                    : > "$FAKE_IMPORTED_IDENTITY"
                    ;;
                *) exit 0 ;;
            esac
            """,
        )
        self.write_stub(bin_dir, "swift", 'printf "%s\\n" "$FAKE_BUILD_DIR"\n')
        self.write_stub(
            bin_dir,
            "codesign",
            """\
            if [[ "$1" == "-d" && "$2" == "-r-" ]]; then
                printf 'designated => identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"%s"\\n' "$FAKE_DESIGNATED_SHA1" >&2
            fi
            exit 0
            """,
        )
        self.write_stub(
            bin_dir,
            "openssl",
            """\
            if [[ "$1" == "rand" ]]; then
                printf '0123456789abcdef0123456789abcdef0123456789abcdef\\n'
            elif [[ "$1" == "pkcs12" && "${2:-}" == "-help" ]]; then
                printf 'usage: pkcs12\\n'
            elif [[ "$1" == "pkcs12" && "$OPENSSL_REJECTS_LEGACY" == "1" ]]; then
                for argument in "$@"; do
                    [[ "$argument" != "-legacy" ]] || exit 64
                done
            fi
            exit 0
            """,
        )
        self.write_stub(bin_dir, "pgrep", "exit 1\n")
        self.write_stub(bin_dir, "ditto", 'cp -R "$1" "$2"\n')
        self.write_stub(
            bin_dir,
            "cp",
            """\
            if [[ "${FAIL_REGISTRY_BACKUP_COPY:-0}" == "1" && "$#" == "3" && "$1" == "-p" && "$2" == "$FAKE_REGISTRY_PATH" ]]; then
                exit 29
            fi
            if [[ "${FAIL_REGISTRY_RESTORE_COPY:-0}" == "1" && "$#" == "3" && "$1" == "-p" && "$2" == *"local-signing-identity-registry.backup" ]]; then
                exit 30
            fi
            exec /bin/cp "$@"
            """,
        )
        self.write_stub(
            bin_dir,
            "mv",
            """\
            if [[ "${FAIL_APP_BACKUP_MOVE:-0}" == "1" && "$1" == "$FAKE_INSTALLED_APP" && "$2" == *".backup."*"/RepoPrompt CE.app" ]]; then
                exit 24
            fi
            if [[ "${FAIL_FINAL_INSTALL_MOVE:-0}" == "1" && "$1" == *".installing."*"/RepoPrompt CE.app" && "$2" == *"/RepoPrompt CE.app" ]]; then
                exit 23
            fi
            exec /bin/mv "$@"
            """,
        )

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "CONFIRM_LOCAL_PRODUCTION_INSTALL": "1",
                "LOCAL_PRODUCTION_INSTALL_DIR": str(install_dir),
                "LOCAL_SIGNING_IDENTITY_REGISTRY_PATH": str(registry_path),
                "LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE": str(fixture),
                "LOCAL_SIGNING_IDENTITY_EVALUATED_AT": "2030-01-01T00:00:00Z",
                "FAKE_BUILD_DIR": str(build_dir),
                "FAKE_KEYCHAIN": str(keychain),
                "FAKE_INVENTORY_FIXTURE": str(fixture),
                "FAKE_AFTER_MINT_FIXTURE": str(after_fixture),
                "FAKE_IMPORTED_IDENTITY": str(import_log),
                "FAKE_DESIGNATED_SHA1": expected_sha1,
                "SECURITY_LOG": str(security_log),
                "PACKAGE_CAPTURE": str(package_capture),
                "OPENSSL_REJECTS_LEGACY": "1" if openssl_rejects_legacy else "0",
                "FAIL_FINAL_INSTALL_MOVE": "1" if fail_final_install_move else "0",
                "FAIL_APP_BACKUP_MOVE": "1" if fail_app_backup_move else "0",
                "FAIL_REGISTRY_BACKUP_COPY": "1" if fail_registry_backup_copy else "0",
                "FAIL_REGISTRY_WRITE": "1" if fail_registry_write else "0",
                "FAIL_REGISTRY_RESTORE_COPY": "1" if fail_registry_restore_copy else "0",
                "FAIL_REGISTRY_READ_MARKER": str(temp_dir / "fail-registry-read"),
                "TMPDIR": str(installer_tmp),
                "FAKE_REGISTRY_PATH": str(registry_path),
                "FAKE_INSTALLED_APP": str(installed_app),
            }
        )
        if selected:
            env["LOCAL_SIGNING_IDENTITY_SHA256"] = selected
        if rotate:
            env["ROTATE_LOCAL_SIGNING_IDENTITY"] = "1"

        context = {
            "command": ["bash", str(scripts / "install_local_production.sh")],
            "env": env,
            "install_dir": install_dir,
            "registry": registry_path,
            "package_capture": package_capture,
            "security_log": security_log,
            "import_log": import_log,
            "tmp_root": installer_tmp,
        }
        return self.invoke(context), context

    @staticmethod
    def invoke(context: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            context["command"],
            env=context["env"],
            text=True,
            capture_output=True,
            timeout=15,
        )

    @staticmethod
    def registry(context: dict[str, Any]) -> dict[str, Any]:
        return json.loads(context["registry"].read_text(encoding="utf-8"))

    @staticmethod
    def requirement_line(output: str) -> str:
        return next(line for line in output.splitlines() if line.startswith("Packaged designated requirement:"))

    @staticmethod
    def write_stub(bin_dir: Path, name: str, body: str) -> None:
        path = bin_dir / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
