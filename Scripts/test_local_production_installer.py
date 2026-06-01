#!/usr/bin/env python3
"""Focused regression tests for the local production installer."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
PINNED_CERTIFICATE_NAME = "RepoPrompt CE Local Self-Signed Code Signing"


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
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    printf '%s\\n' "$CONFIRM_LOCAL_PRODUCTION_INSTALL" > "$LAUNCHER_CAPTURE"
                    printf '%s\\n' "$@" >> "$LAUNCHER_CAPTURE"
                    """
                ),
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
        self.assertIn(
            'read -r -p "Build and replace $TARGET_APP? [y/N] "',
            launcher.read_text(encoding="utf-8"),
        )

    def test_finder_launcher_decline_does_not_invoke_conductor(self) -> None:
        launcher = ROOT_DIR / "Install RepoPrompt CE Local Production.command"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            copied_launcher = root / launcher.name
            shutil.copy2(launcher, copied_launcher)
            capture = root / "capture.txt"
            conductor = root / "conductor"
            conductor.write_text(
                "#!/bin/bash\nprintf 'invoked\\n' > \"$LAUNCHER_CAPTURE\"\n",
                encoding="utf-8",
            )
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

    def test_finder_launcher_falls_back_to_direct_installer_without_python3(self) -> None:
        launcher = ROOT_DIR / "Install RepoPrompt CE Local Production.command"

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            copied_launcher = root / launcher.name
            shutil.copy2(launcher, copied_launcher)
            scripts = root / "Scripts"
            scripts.mkdir()
            capture = root / "capture.txt"
            direct_installer = scripts / "install_local_production.sh"
            direct_installer.write_text(
                "#!/bin/bash\nprintf '%s\\n' \"$CONFIRM_LOCAL_PRODUCTION_INSTALL\" > \"$LAUNCHER_CAPTURE\"\n",
                encoding="utf-8",
            )
            direct_installer.chmod(0o755)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            dirname = shutil.which("dirname")
            self.assertIsNotNone(dirname)
            os.symlink(dirname, bin_dir / "dirname")

            env = os.environ.copy()
            env["PATH"] = str(bin_dir)
            env["LAUNCHER_CAPTURE"] = str(capture)
            result = subprocess.run(
                ["/bin/bash", str(copied_launcher)],
                env=env,
                input="y\n\n",
                text=True,
                capture_output=True,
                timeout=10,
            )
            captured_lines = capture.read_text(encoding="utf-8").splitlines()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(captured_lines, ["1"])
        self.assertIn("Mode:    direct (python3 unavailable - running without the dev daemon)", result.stdout)

    def test_local_entitlements_keep_runtime_capabilities_without_developer_id_identity_keys(self) -> None:
        template = ROOT_DIR / "AppBundle" / "RepoPrompt.local-self-signed.entitlements.template"
        with template.open("rb") as handle:
            entitlements = plistlib.load(handle)

        self.assertEqual(
            entitlements,
            {
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.temporary-exception.mach-lookup.global-name": [
                    "__BUNDLE_ID__-spks",
                    "__BUNDLE_ID__-spki",
                ],
            },
        )

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        self.assertIn('LOCAL_SELF_SIGNED_CERTIFICATE_NAME="RepoPrompt CE Local Self-Signed Code Signing"', package_script)
        self.assertIn('phase "Rendering local self-signed entitlements"', package_script)
        self.assertIn('APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")', package_script)

    def test_failed_replacement_restores_prior_app_and_preserves_spaces_in_keychain_path(self) -> None:
        result, install_dir = self.run_installer(fail_final_install_move=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((install_dir / "RepoPrompt CE.app" / "payload.txt").read_text(encoding="utf-8"), "old\n")
        self.assertEqual(list(install_dir.glob(".RepoPrompt CE.app.backup.*")), [])

    def test_successful_replacement_removes_backup(self) -> None:
        result, install_dir = self.run_installer(fail_final_install_move=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((install_dir / "RepoPrompt CE.app" / "payload.txt").read_text(encoding="utf-8"), "new\n")
        self.assertEqual(list(install_dir.glob(".RepoPrompt CE.app.backup.*")), [])
        self.assertEqual(list(install_dir.glob(".RepoPrompt CE.app.installing.*")), [])

    def test_certificate_minting_omits_legacy_when_openssl_does_not_support_it(self) -> None:
        result, _ = self.run_installer(
            fail_final_install_move=False,
            existing_identity=False,
            openssl_rejects_legacy=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def run_installer(
        self,
        *,
        fail_final_install_move: bool,
        existing_identity: bool = True,
        openssl_rejects_legacy: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "install_local_production.sh", scripts / "install_local_production.sh")
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

        (scripts / "package_app.sh").write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                app="$FAKE_BUILD_DIR/RepoPrompt.app"
                mkdir -p "$app/Contents"
                printf 'new\\n' > "$app/payload.txt"
                cat > "$app/Contents/Info.plist" <<'EOF'
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict><key>RepoPromptSigningMode</key><string>local-self-signed</string></dict></plist>
                EOF
                """
            ),
            encoding="utf-8",
        )
        (scripts / "package_app.sh").chmod(0o755)

        bin_dir = temp_dir / "bin"
        bin_dir.mkdir()
        self.write_stub(
            bin_dir,
            "security",
            """\
            case "$1" in
                default-keychain) printf '    "%s"\\n' "$FAKE_KEYCHAIN" ;;
                find-identity)
                    if [[ "$FAKE_EXISTING_IDENTITY" == "1" || -f "$FAKE_IMPORTED_IDENTITY" ]]; then
                        printf '  1) ABCDEF "%s"\\n' "$PINNED_CERTIFICATE_NAME"
                    fi
                    ;;
                import) : > "$FAKE_IMPORTED_IDENTITY" ;;
                *) exit 0 ;;
            esac
            """,
        )
        self.write_stub(bin_dir, "swift", 'printf "%s\\n" "$FAKE_BUILD_DIR"\n')
        self.write_stub(
            bin_dir,
            "plutil",
            """\
            if [[ "$1" == "-extract" ]]; then
                printf 'local-self-signed\\n'
            fi
            """,
        )
        self.write_stub(bin_dir, "codesign", "exit 0\n")
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
            "mv",
            """\
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
                "LOCAL_SELF_SIGNED_CERTIFICATE_NAME": "divergent override",
                "FAKE_BUILD_DIR": str(build_dir),
                "FAKE_KEYCHAIN": str(keychain),
                "FAKE_EXISTING_IDENTITY": "1" if existing_identity else "0",
                "FAKE_IMPORTED_IDENTITY": str(temp_dir / "imported-identity"),
                "OPENSSL_REJECTS_LEGACY": "1" if openssl_rejects_legacy else "0",
                "PINNED_CERTIFICATE_NAME": PINNED_CERTIFICATE_NAME,
                "FAIL_FINAL_INSTALL_MOVE": "1" if fail_final_install_move else "0",
            }
        )
        result = subprocess.run(
            ["bash", str(scripts / "install_local_production.sh")],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        return result, install_dir

    @staticmethod
    def write_stub(bin_dir: Path, name: str, body: str) -> None:
        path = bin_dir / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
