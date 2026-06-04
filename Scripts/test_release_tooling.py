#!/usr/bin/env python3
"""Regression tests for trusted release-control helpers."""

from __future__ import annotations

import base64
import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


class ReleaseToolingTests(unittest.TestCase):
    def test_custom_packaging_resigns_sparkle_helpers_without_recursive_entitlement_propagation(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        info_plist = plistlib.loads((SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_bytes())

        for script in (package_script, staged_signing_script):
            self.assertIn('sign_path "$framework/Versions/B/XPCServices/Installer.xpc"', script)
            self.assertIn(
                'sign_path "$framework/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements',
                script,
            )
            self.assertIn('sign_path "$framework/Versions/B/Autoupdate"', script)
            self.assertIn('sign_path "$framework/Versions/B/Updater.app"', script)
            self.assertIn('sign_path "$framework"', script)

        self.assertIn('APP_SIGN_ARGS=()', package_script)
        self.assertNotIn('APP_SIGN_ARGS=(--deep)', package_script)
        self.assertNotIn('sign_path "$APP_BUNDLE" --deep', staged_signing_script)
        self.assertNotIn("SUEnableInstallerLauncherService", info_plist)
        self.assertIn("trap 'finish $?' EXIT", package_script)
        self.assertIn('local status="$1" now total', package_script)

    def test_release_paths_use_static_validation_in_privileged_contexts_and_token_stripped_local_smoke(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        public_update_script = (SCRIPT_DIR / "publish_public_update_test.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")

        package_outer_sign = package_script.index('sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"')
        package_layout = package_script.index('"$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"')
        package_smoke = package_script.index(
            '"$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"'
        )
        self.assertLess(package_outer_sign, package_layout)
        self.assertLess(package_layout, package_smoke)

        for privileged_script in (staged_signing_script, promote_script, public_update_script):
            self.assertIn("validate_embedded_mcp_helper_layout.sh", privileged_script)
            self.assertNotIn("smoke_embedded_mcp_helper.sh", privileged_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"', release_script)

    def test_embedded_mcp_helper_smoke_rejects_exit_137(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        helper = temp_dir / "RepoPrompt.app" / "Contents" / "MacOS" / "repoprompt-mcp"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/usr/bin/env bash\nexit 137\n", encoding="utf-8")
        helper.chmod(0o755)

        result = subprocess.run(
            [str(SCRIPT_DIR / "smoke_embedded_mcp_helper.sh"), str(temp_dir / "RepoPrompt.app"), "Fixture helper"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fixture helper failed --version smoke (exit 137)", result.stderr)

    def test_embedded_mcp_helper_layout_validator_accepts_canonical_layout(self) -> None:
        app = self.make_embedded_helper_layout()

        result = self.run_layout_validation(app)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matches the embedded MCP helper layout policy", result.stdout)

    def test_embedded_mcp_helper_layout_validator_rejects_invalid_metadata(self) -> None:
        def helper_symlink(app: Path) -> None:
            helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
            helper.unlink()
            helper.symlink_to("RepoPrompt")

        def non_executable_helper(app: Path) -> None:
            (app / "Contents" / "MacOS" / "repoprompt-mcp").chmod(0o644)

        def missing_resources_link(app: Path) -> None:
            (app / "Contents" / "Resources" / "repoprompt-mcp").unlink()

        def missing_bin_link(app: Path) -> None:
            (app / "Contents" / "Resources" / "bin" / "repoprompt-mcp").unlink()

        def alternate_in_app_target(app: Path) -> None:
            link = app / "Contents" / "Resources" / "repoprompt-mcp"
            link.unlink()
            link.symlink_to("../MacOS/RepoPrompt")

        for label, mutate in (
            ("helper symlink", helper_symlink),
            ("non-executable helper", non_executable_helper),
            ("missing resources link", missing_resources_link),
            ("missing bin link", missing_bin_link),
            ("alternate in-app target", alternate_in_app_target),
        ):
            with self.subTest(label=label):
                app = self.make_embedded_helper_layout()
                mutate(app)
                result = self.run_layout_validation(app)
                self.assertNotEqual(result.returncode, 0)

    def test_release_workflows_isolate_executable_helper_smoke_and_harden_p12_cleanup(self) -> None:
        release_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        promote_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release-promote.yml").read_text(
            encoding="utf-8"
        )
        signed_test_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "signed-test-build.yml").read_text(
            encoding="utf-8"
        )
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")

        publish_job = release_workflow.split("\n  publish:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        publish_staged = "        run: ./trusted-control-plane/Scripts/release.sh publish-staged"
        cleanup_step = "      - name: Remove ephemeral keychain"
        upload_step = "      - name: Upload signed release ZIP for secret-free smoke"
        self.assertLess(publish_job.index(publish_staged), publish_job.index(cleanup_step))
        self.assertLess(publish_job.index(cleanup_step), publish_job.index(upload_step))
        signed_upload = publish_job.split(upload_step, 1)[1]
        self.assertIn("release-source/dist/*.zip", signed_upload)
        self.assertIn("release-source/dist/SHA256SUMS", signed_upload)

        signed_smoke = release_workflow.split("\n  smoke-signed-helper:", 1)[1]
        self.assertNotIn("environment: release", signed_smoke)
        self.assertIn("RepoPrompt-CE-signed-release-zip", signed_smoke)
        self.assertIn("manifests=(signed-release/*SHA256SUMS)", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum manifest", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum entry", signed_smoke)
        self.assertIn("shasum -a 256 -c", signed_smoke)
        self.assertLess(signed_smoke.index("shasum -a 256 -c"), signed_smoke.index("ditto -x -k"))
        self.assertIn("validate_embedded_mcp_helper_layout.sh", signed_smoke)
        self.assertIn("env -i", signed_smoke)
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", signed_smoke)
        self.assertIn('HOME="$HOME"', signed_smoke)
        self.assertIn('TMPDIR="$RUNNER_TEMP"', signed_smoke)

        reviewed_smoke = promote_workflow.split("\n  smoke-reviewed-helper:", 1)[1].split("\n  promote:", 1)[0]
        self.assertNotIn("environment: release", reviewed_smoke)
        self.assertIn("contents: write", reviewed_smoke)
        self.assertIn("GH_TOKEN: ${{ github.token }}", reviewed_smoke)
        self.assertIn("reviewed_checksums_sha256", reviewed_smoke)
        self.assertIn("validate_embedded_mcp_helper_layout.sh", reviewed_smoke)
        self.assertIn("env -i", reviewed_smoke)
        promote_job = promote_workflow.split("\n  promote:", 1)[1]
        self.assertIn("- smoke-reviewed-helper", promote_job)
        self.assertIn("environment: release", promote_job)

        p12_import = release_workflow.split("      - name: Import Developer ID certificate", 1)[1].split(
            "      - name: Prepare provisioning profile and notarization key", 1
        )[0]
        self.assertIn("umask 077", p12_import)
        self.assertLess(
            p12_import.index("trap cleanup_certificate_and_failed_keychain EXIT"),
            p12_import.index("base64 --decode"),
        )
        self.assertIn('rm -f "$CERTIFICATE_PATH"', p12_import)
        self.assertIn('security delete-keychain "$KEYCHAIN_PATH" || true', p12_import)
        final_cleanup = publish_job.split(cleanup_step, 1)[1].split(upload_step, 1)[0]
        self.assertIn("if: always()", final_cleanup)
        self.assertIn('KEYCHAIN_PATH="$RUNNER_TEMP/repoprompt-release.keychain-db"', final_cleanup)
        self.assertIn('CERTIFICATE_PATH="$RUNNER_TEMP/repoprompt-release.p12"', final_cleanup)
        self.assertIn('rm -f "$CERTIFICATE_PATH"', final_cleanup)
        self.assertIn('rm -rf "$RUNNER_TEMP/repoprompt-release-secrets"', final_cleanup)

        self.assertIn("group: signed-test-build", signed_test_workflow)
        self.assertIn("verify_signed_test_build_ref.sh", signed_test_workflow)
        self.assertIn("reachable_refs: ${{ steps.source-ref.outputs.reachable_refs }}", signed_test_workflow)
        self.assertIn("upstream-reachable SHA", signed_test_workflow)
        self.assertIn("source_ref must not start with '-'", signed_test_workflow)
        self.assertIn("source_ref must be a single line", signed_test_workflow)
        self.assertIn("GITHUB_SERVER_URL", signed_test_workflow)
        self.assertNotIn("branch, tag, or SHA to build and sign", signed_test_workflow)

        signed_test_stage = signed_test_workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]
        self.assertNotIn("environment: release", signed_test_stage)
        self.assertIn("persist-credentials: false", signed_test_stage)
        self.assertIn("release.sh stage-test-build", signed_test_stage)
        self.assertIn("RepoPrompt-CE-staged-signed-test-build", signed_test_stage)

        signed_test_sign = signed_test_workflow.split("\n  sign:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        self.assertIn("environment: release", signed_test_sign)
        self.assertIn("- stage", signed_test_sign)
        self.assertIn("RepoPrompt-CE-staged-signed-test-build", signed_test_sign)
        self.assertIn("release.sh publish-test-build", signed_test_sign)
        self.assertIn("release-source/dist/*.zip", signed_test_sign)
        self.assertIn("release-source/dist/*.dmg", signed_test_sign)
        self.assertIn("release-source/dist/*-signed-test-provenance.json", signed_test_sign)
        self.assertIn("Revalidate source ref after release approval", signed_test_sign)
        self.assertIn("id: sign-source-ref", signed_test_sign)
        self.assertIn("Require sign-time source ref to match validated commit", signed_test_sign)
        self.assertLess(signed_test_sign.index("Revalidate source ref after release approval"), signed_test_sign.index("Import Developer ID certificate"))
        self.assertIn("SIGNED_TEST_SOURCE_REF", signed_test_sign)
        self.assertIn("SIGNED_TEST_REACHABLE_REFS: ${{ steps.sign-source-ref.outputs.reachable_refs }}", signed_test_sign)
        self.assertNotIn("SIGNED_TEST_REACHABLE_REFS: ${{ needs.validate-ref.outputs.reachable_refs }}", signed_test_sign)
        self.assertIn("SIGNED_TEST_TOOLING_COMMIT", signed_test_sign)
        self.assertIn("SIGNED_TEST_WORKFLOW_RUN_URL", signed_test_sign)
        self.assertNotIn("gh release create", signed_test_sign)
        self.assertNotIn("SPARKLE_PRIVATE_KEY", signed_test_sign)

        signed_test_smoke = signed_test_workflow.split("\n  smoke-signed-helper:", 1)[1]
        self.assertNotIn("environment: release", signed_test_smoke)
        self.assertIn("RepoPrompt-CE-signed-test-build", signed_test_smoke)
        self.assertIn("provenances=(signed-test-build/*-signed-test-provenance.json)", signed_test_smoke)
        self.assertIn("Expected exactly one signed test provenance file", signed_test_smoke)
        self.assertIn("EXPECTED_REQUESTED_REF: ${{ inputs.source_ref }}", signed_test_smoke)
        self.assertIn('os.environ["EXPECTED_REQUESTED_REF"]', signed_test_smoke)
        self.assertNotIn('provenance["requested_ref"] != "${{ inputs.source_ref }}"', signed_test_smoke)
        self.assertIn("Provenance requested ref mismatch", signed_test_smoke)
        self.assertIn("Provenance source commit mismatch", signed_test_smoke)
        self.assertIn("Provenance workflow run URL mismatch", signed_test_smoke)
        self.assertIn("Provenance reachable refs must be a non-empty list", signed_test_smoke)
        self.assertIn("developer-id-signed-test-build", signed_test_smoke)
        self.assertIn("validate_embedded_mcp_helper_layout.sh", signed_test_smoke)
        self.assertIn("env -i", signed_test_smoke)

        stage_test = release_script.split("stage_signed_test_build() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("unset GH_TOKEN GITHUB_TOKEN SOURCE_GH_TOKEN", stage_test)
        self.assertIn("RELEASE_ALLOW_ADHOC_SIGNING=1", stage_test)
        self.assertIn('SIGNED_TEST_PROVENANCE="$DIST_DIR/$ARCHIVE_BASENAME-signed-test-provenance.json"', release_script)
        self.assertIn("write_signed_test_build_provenance", release_script)
        self.assertIn("SIGNED_TEST_SOURCE_REF", release_script)
        self.assertIn("SIGNED_TEST_REACHABLE_REFS", release_script)
        self.assertIn("SIGNED_TEST_STAGED_ARCHIVE_SHA256", release_script)
        self.assertIn("developer-id-signed-test-build", release_script)
        self.assertIn('"staged_source_archive"', release_script)
        publish_test = release_script.split("publish_signed_test_build() {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("gh release create", publish_test)
        self.assertNotIn("SPARKLE_PRIVATE_KEY", publish_test)
        self.assertIn('shasum -a 256', publish_test)

    def test_staged_release_extractor_rejects_alternate_in_app_cli_target(self) -> None:
        for relative, alternate_target in (
            ("Contents/Resources/repoprompt-mcp", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-mcp", "../../MacOS/RepoPrompt"),
        ):
            with self.subTest(relative=relative):
                temp_dir = Path(tempfile.mkdtemp())
                self.addCleanup(shutil.rmtree, temp_dir, True)
                archive = temp_dir / "stage.zip"
                destination = temp_dir / "extract"
                info = zipfile.ZipInfo(f".build/release/RepoPrompt.app/{relative}")
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr(info, alternate_target)

                result = subprocess.run(
                    [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
                    text=True,
                    capture_output=True,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected or escaping staged archive symlink", result.stderr)

    def test_staged_release_validator_rejects_alternate_in_app_cli_target(self) -> None:
        for relative, alternate_target in (
            ("Contents/Resources/repoprompt-mcp", "../MacOS/RepoPrompt"),
            ("Contents/Resources/bin/repoprompt-mcp", "../../MacOS/RepoPrompt"),
        ):
            with self.subTest(relative=relative):
                approved, staged, scripts = self.make_staged_release_fixture()
                link = staged / ".build" / "release" / "RepoPrompt.app" / relative
                link.unlink()
                link.symlink_to(alternate_target)

                result = self.run_staged_validation(approved, staged, scripts)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected or escaping staged symlink", result.stderr)

    def test_runtime_bundle_verifier_is_removed_without_changing_sparkle_or_anti_debug_startup(self) -> None:
        app_delegate = (SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "AppDelegate.swift").read_text(
            encoding="utf-8"
        )
        application_security = (
            SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "ApplicationSecurity.swift"
        ).read_text(encoding="utf-8")
        sparkle_manager = (
            SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "App" / "Sparkle" / "SparkleUpdateManager.swift"
        ).read_text(encoding="utf-8")
        security_root = SCRIPT_DIR.parent / "Sources" / "RepoPrompt" / "Infrastructure" / "Security"
        runtime_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (SCRIPT_DIR.parent / "Sources" / "RepoPrompt").rglob("*.swift")
        )

        self.assertNotIn("BundleVerificationService", app_delegate)
        self.assertNotIn("Application integrity check failed", app_delegate)
        self.assertFalse((security_root / "BundleVerificationService.swift").exists())
        self.assertFalse((security_root / "BundleVerifier.swift").exists())
        self.assertEqual(app_delegate.count("sparkleManager.startUpdater()"), 2)
        self.assertIn("ApplicationSecurity.startMonitoring()", app_delegate)
        self.assertIn("ApplicationSecurity.enableAntiDebugging()", app_delegate)
        self.assertNotIn("BundleVerifier", application_security)
        self.assertNotIn("verifyBundleSignature", application_security)
        self.assertNotIn("SecStaticCodeCheckValidity", application_security)
        self.assertNotIn("BundleVerifier.verifyBundleSignature", runtime_sources)
        manager_init = sparkle_manager.split("init(updaterController: SPUStandardUpdaterController) {", 1)[1].split(
            "\n    func startUpdater()", 1
        )[0]
        self.assertNotIn("updaterController.startUpdater()", manager_init)
        self.assertIn("guard sparkleConfigurationValid, !updaterStarted else { return }", sparkle_manager)
        self.assertIn("guard updaterStarted, sparkleConfigurationValid else { return false }", sparkle_manager)

    def test_ci_secret_scan_covers_introduced_commit_range_and_checked_out_tree(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn('gitleaks git --redact --log-opts="$range" .', workflow)
        self.assertIn("gitleaks dir --redact .", workflow)

    def test_publish_staged_validates_before_creating_dist(self) -> None:
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        publish_staged = release_script.split("publish_staged_release() {", 1)[1].split("\n}", 1)[0]

        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"'),
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
        )
        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
            publish_staged.index("prepare_dist"),
        )

    def test_modern_sparkle_key_seed_derives_public_key(self) -> None:
        descriptor, key_path = tempfile.mkstemp()
        os.close(descriptor)
        key_file = Path(key_path)
        self.addCleanup(key_file.unlink, missing_ok=True)
        key_file.write_text(base64.b64encode(bytes(range(32))).decode("ascii"), encoding="utf-8")

        result = subprocess.run(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(base64.b64decode(result.stdout.strip())), 32)

    def test_legacy_sparkle_key_export_is_rejected(self) -> None:
        descriptor, key_path = tempfile.mkstemp()
        os.close(descriptor)
        key_file = Path(key_path)
        self.addCleanup(key_file.unlink, missing_ok=True)
        key_file.write_text(base64.b64encode(bytes(96)).decode("ascii"), encoding="utf-8")

        result = subprocess.run(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("modern 32-byte seed", result.stderr)

    def test_sparkle_signature_verifier_rejects_modified_signature(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        key_file = temp_dir / "key"
        public_key_file = temp_dir / "public-key"
        archive = temp_dir / "archive.zip"
        key_file.write_text(base64.b64encode(bytes(range(32))).decode("ascii"), encoding="utf-8")
        archive.write_text("signed archive\n", encoding="utf-8")
        public_key = self.run_checked(
            ["xcrun", "swift", str(SCRIPT_DIR / "derive_sparkle_public_key.swift"), str(key_file)]
        ).stdout.strip()
        public_key_file.write_text(public_key, encoding="utf-8")
        signature = subprocess.run(
            [
                str(SCRIPT_DIR.parent / "Vendor" / "Sparkle" / "bin" / "sign_update"),
                "--ed-key-file",
                str(key_file),
                "-p",
                str(archive),
            ],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

        accepted = subprocess.run(
            [
                "xcrun",
                "swift",
                str(SCRIPT_DIR / "verify_sparkle_signature.swift"),
                str(public_key_file),
                signature,
                str(archive),
            ],
            text=True,
            capture_output=True,
        )
        rejected = subprocess.run(
            [
                "xcrun",
                "swift",
                str(SCRIPT_DIR / "verify_sparkle_signature.swift"),
                str(public_key_file),
                base64.b64encode(bytes(64)).decode("ascii"),
                str(archive),
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not verify", rejected.stderr)

    def test_github_tokens_are_scrubbed_before_swiftpm_commands(self) -> None:
        helper = SCRIPT_DIR / "run_without_github_tokens.sh"
        result = subprocess.run(
            [
                str(helper),
                "bash",
                "-c",
                '[[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -z "${SOURCE_GH_TOKEN:-}" ]]',
            ],
            env={
                "PATH": os.environ["PATH"],
                "GH_TOKEN": "source-token",
                "GITHUB_TOKEN": "workflow-token",
                "SOURCE_GH_TOKEN": "explicit-source-token",
            },
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve', release_script)
        self.assertEqual(package_script.count('"$RUN_WITHOUT_GITHUB_TOKENS" swift build'), 4)
        self.assertIn(
            '"$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"',
            package_script,
        )
        self.assertIn("unset GH_TOKEN GITHUB_TOKEN SOURCE_GH_TOKEN", release_script)

    def test_sparkle_vendor_manifest_rejects_extra_file_and_symlink_redirect(self) -> None:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        vendor = root / "Vendor" / "Sparkle"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        vendor.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "verify_sparkle_vendor.sh", scripts / "verify_sparkle_vendor.sh")
        scripts.joinpath("verify_sparkle_vendor.sh").chmod(0o755)
        source_vendor = SCRIPT_DIR.parent / "Vendor" / "Sparkle"
        shutil.copy2(source_vendor / "INSTALLED_MANIFEST.tsv", vendor / "INSTALLED_MANIFEST.tsv")
        shutil.copytree(source_vendor / "bin", vendor / "bin")
        shutil.copytree(
            source_vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework",
            vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework",
            symlinks=True,
        )

        accepted = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        extra = vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework" / "unexpected"
        extra.write_text("unexpected\n", encoding="utf-8")
        rejected_extra = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected_extra.returncode, 0)
        self.assertIn("extra=", rejected_extra.stderr)
        extra.unlink()

        headers = vendor / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework" / "Headers"
        headers.unlink()
        headers.symlink_to("Versions/B/PrivateHeaders")
        rejected_link = subprocess.run(
            [str(scripts / "verify_sparkle_vendor.sh")],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected_link.returncode, 0)
        self.assertIn("changed=", rejected_link.stderr)

    def test_staged_release_validator_rejects_contents_and_frameworks_symlinks(self) -> None:
        for relative in ("Contents", "Contents/Frameworks"):
            with self.subTest(relative=relative):
                approved, staged, scripts = self.make_staged_release_fixture()
                accepted = self.run_staged_validation(approved, staged, scripts)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)

                target = staged / ".build" / "release" / "RepoPrompt.app" / relative
                moved = target.with_name(f"{target.name}-real")
                target.rename(moved)
                target.symlink_to(moved.name, target_is_directory=True)
                rejected = self.run_staged_validation(approved, staged, scripts)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("must be a real directory", rejected.stderr)

    def test_staged_release_extractor_rejects_absolute_symlink(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        archive = temp_dir / "stage.zip"
        destination = temp_dir / "extract"
        member = ".build/release/RepoPrompt.app/Contents"
        info = zipfile.ZipInfo(member)
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr(info, "/tmp/repoprompt-stage-escape")

        result = subprocess.run(
            [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute target", result.stderr)

    def test_staged_release_extractor_rejects_existing_destination(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        archive = temp_dir / "stage.zip"
        destination = temp_dir / "extract"
        destination.mkdir()
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("version.env", "fixture\n")

        result = subprocess.run(
            [str(SCRIPT_DIR / "extract_staged_release.py"), str(archive), str(destination), "RepoPrompt"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination already exists", result.stderr)

    def test_release_metadata_parser_accepts_allowlisted_values(self) -> None:
        root = self.make_metadata_root()

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata "{root}"; printf "%s|%s|%s\\n" "$APP_NAME" "$MARKETING_VERSION" "$BUILD_NUMBER"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "RepoPrompt|1.0.0|1\n")

    def test_release_metadata_parser_rejects_shell_execution(self) -> None:
        root = self.make_metadata_root()
        marker = root / "executed"
        metadata = (root / "version.env").read_text(encoding="utf-8")
        (root / "version.env").write_text(
            metadata.replace("APP_NAME=RepoPrompt", f"APP_NAME=$(touch {marker})"),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; load_release_metadata "{root}"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_mcp_cli_version_sync_updates_source_and_check_detects_drift(self) -> None:
        root = self.make_metadata_root()
        source = root / "Sources" / "RepoPromptMCP" / "main.swift"
        source.parent.mkdir(parents=True)
        source.write_text('let CLI_VERSION = "9.9.9"\n', encoding="utf-8")
        env = os.environ.copy()
        env["REPOPROMPT_RELEASE_SOURCE_ROOT"] = str(root)
        helper = SCRIPT_DIR / "sync_mcp_cli_version.sh"

        rejected = subprocess.run([str(helper), "--check"], env=env, text=True, capture_output=True)
        synced = subprocess.run([str(helper)], env=env, text=True, capture_output=True)
        accepted = subprocess.run([str(helper), "--check"], env=env, text=True, capture_output=True)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Run ./Scripts/release.sh sync-cli-version", rejected.stderr)
        self.assertEqual(synced.returncode, 0, synced.stderr)
        self.assertEqual(source.read_text(encoding="utf-8"), 'let CLI_VERSION = "1.0.0"\n')
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_release_preflight_requires_synchronized_mcp_cli_version(self) -> None:
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")

        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh"', release_script)
        self.assertIn('"$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh" --check', release_script)
        self.assertIn("sync-cli-version) sync_mcp_cli_version", release_script)

    def test_remote_release_commit_helper_rejects_moved_tag(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "tag", "v1.0.0")
        self.git(work, "push", "origin", "main", "v1.0.0")

        accepted = self.run_remote_verify(work, first)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        self.commit_file(work, "second")
        self.git(work, "tag", "-f", "v1.0.0")
        self.git(work, "push", "--force", "origin", "v1.0.0")

        rejected = self.run_remote_verify(work, first)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Remote release tag moved", rejected.stderr)

    def test_release_ref_helper_requires_tag_reachable_from_main(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "tag", "v1.0.0")
        self.git(work, "push", "origin", "main", "v1.0.0")

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "v1.0.0"],
            cwd=work,
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(accepted.stdout.strip(), first)

        self.git(work, "checkout", "-b", "unmerged")
        self.commit_file(work, "unmerged")
        self.git(work, "tag", "v1.0.1")
        self.git(work, "push", "origin", "v1.0.1")
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "v1.0.1"],
            cwd=work,
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("not reachable from protected main", rejected.stderr)

    def test_release_ref_helper_rejects_noncanonical_tag(self) -> None:
        result = subprocess.run(
            [str(SCRIPT_DIR / "verify_release_ref.sh"), "release-1.0.0"],
            env={"PATH": os.environ["PATH"], "GITHUB_REF": "refs/heads/main"},
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical", result.stderr)


    def test_signed_test_build_ref_helper_requires_exact_ref_and_upstream_reachability(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "tag", "v1.0.0")
        self.git(work, "tag", "-a", "v1.0.0-annotated", "-m", "annotated")
        self.git(work, "push", "origin", "main", "v1.0.0", "v1.0.0-annotated")

        for source_ref in ("main", "refs/heads/main", "v1.0.0", "refs/tags/v1.0.0", "v1.0.0-annotated", first):
            with self.subTest(source_ref=source_ref):
                self.git(work, "checkout", source_ref)
                accepted = self.run_signed_test_ref_verify(work, source_ref)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertEqual(accepted.stdout.strip(), first)

        self.git(work, "checkout", "main")
        self.commit_file(work, "unreachable")
        unreachable = self.git(work, "rev-parse", "HEAD").stdout.strip()
        rejected = self.run_signed_test_ref_verify(work, unreachable)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("not reachable from any upstream branch or tag", rejected.stderr)

    def test_signed_test_build_ref_helper_rejects_commitish_and_mismatched_inputs(self) -> None:
        remote, work = self.make_git_remote()
        first = self.commit_file(work, "first")
        self.git(work, "push", "origin", "main")
        second = self.commit_file(work, "second")
        self.git(work, "push", "origin", "main")

        for source_ref in ("main~1", "main^", "main..HEAD", first[:12], "refs/remotes/origin/main"):
            with self.subTest(source_ref=source_ref):
                self.git(work, "checkout", first)
                result = self.run_signed_test_ref_verify(work, source_ref)
                self.assertNotEqual(result.returncode, 0)

        self.git(work, "checkout", first)
        mismatched = self.run_signed_test_ref_verify(work, "main")
        self.assertNotEqual(mismatched.returncode, 0)
        self.assertIn("checkout HEAD", mismatched.stderr)

    def test_signed_test_build_ref_helper_rejects_ambiguous_branch_tag_names(self) -> None:
        remote, work = self.make_git_remote()
        self.commit_file(work, "first")
        self.git(work, "push", "origin", "main")
        self.git(work, "checkout", "-b", "ambiguous")
        self.commit_file(work, "branch")
        self.git(work, "push", "origin", "ambiguous")
        self.git(work, "checkout", "main")
        self.git(work, "tag", "ambiguous")
        self.git(work, "push", "origin", "refs/tags/ambiguous")

        self.git(work, "checkout", "refs/heads/ambiguous")
        rejected = self.run_signed_test_ref_verify(work, "ambiguous")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("ambiguous", rejected.stderr)

    def test_signed_test_build_ref_helper_rejects_pr_and_fork_refs(self) -> None:
        remote, work = self.make_git_remote()
        self.commit_file(work, "first")
        self.git(work, "push", "origin", "main")

        for source_ref, expected in (
            ("refs/pull/123/head", "pull-request"),
            ("pull/123/head", "pull-request"),
            ("someuser:branch", "fork shorthand refs"),
        ):
            with self.subTest(source_ref=source_ref):
                result = self.run_signed_test_ref_verify(work, source_ref)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_signed_test_build_docs_describe_reachability_and_provenance(self) -> None:
        docs = (SCRIPT_DIR.parent / "docs" / "releasing.md").read_text(encoding="utf-8")

        self.assertIn("full 40-character commit SHA", docs)
        self.assertIn("unreachable", docs)
        self.assertIn("revspecs", docs)
        self.assertIn("`sign` job", docs)
        self.assertIn("signed-test-provenance.json", docs)
        self.assertIn("source commit", docs)
        self.assertIn("trusted tooling commit", docs)
        self.assertIn("workflow run URL", docs)
        self.assertIn("ZIP, DMG, checksum manifest", docs)
        self.assertIn("archive hashes", docs)

    def make_embedded_helper_layout(self) -> Path:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        macos = app / "Contents" / "MacOS"
        resources_bin = app / "Contents" / "Resources" / "bin"
        macos.mkdir(parents=True)
        resources_bin.mkdir(parents=True)
        (macos / "RepoPrompt").write_text("RepoPrompt\n", encoding="utf-8")
        helper = macos / "repoprompt-mcp"
        helper.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        helper.chmod(0o755)
        (app / "Contents" / "Resources" / "repoprompt-mcp").symlink_to("../MacOS/repoprompt-mcp")
        (resources_bin / "repoprompt-mcp").symlink_to("../../MacOS/repoprompt-mcp")
        return app

    @staticmethod
    def run_layout_validation(app: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "validate_embedded_mcp_helper_layout.sh"), str(app), "Fixture helper layout"],
            text=True,
            capture_output=True,
        )

    def make_metadata_root(self) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        (root / "version.env").write_text(
            """\
APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
""",
            encoding="utf-8",
        )
        return root

    def make_staged_release_fixture(self) -> tuple[Path, Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        approved = temp_dir / "approved"
        staged = temp_dir / "staged"
        scripts = temp_dir / "Scripts"
        app = staged / ".build" / "release" / "RepoPrompt.app"
        for directory in (
            approved / "AppBundle",
            approved / "ThirdPartyLicenses" / "fixture",
            staged / "ThirdPartyLicenses" / "fixture",
            app / "Contents" / "Frameworks" / "Sparkle.framework",
            app / "Contents" / "MacOS",
            app / "Contents" / "Resources" / "bin",
            app / "Contents" / "Resources" / "Legal" / "ThirdPartyLicenses" / "fixture",
            scripts,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        for name in (
            "load_release_metadata.sh",
            "validate_embedded_mcp_helper_layout.sh",
            "validate_packaged_legal.sh",
            "validate_staged_release.sh",
        ):
            shutil.copy2(SCRIPT_DIR / name, scripts / name)
            scripts.joinpath(name).chmod(0o755)
        metadata = """\
APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
"""
        for root in (approved, staged):
            (root / "version.env").write_text(metadata, encoding="utf-8")
            (root / "LICENSE").write_text("license\n", encoding="utf-8")
            (root / "THIRD_PARTY_NOTICES.md").write_text("notices\n", encoding="utf-8")
            (root / "ThirdPartyLicenses" / "fixture" / "LICENSE").write_text("fixture\n", encoding="utf-8")
        template = (SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_text(encoding="utf-8")
        (approved / "AppBundle" / "Info.plist.template").write_text(template, encoding="utf-8")
        for key, value in {
            "__APP_NAME__": "RepoPrompt",
            "__DISPLAY_NAME__": "RepoPrompt CE",
            "__BUNDLE_ID__": "com.pvncher.repoprompt.ce",
            "__MARKETING_VERSION__": "1.0.0",
            "__BUILD_NUMBER__": "1",
            "__DEBUG_SECURE_STORAGE_BACKEND__": "alternate-in-memory",
            "__SIGNING_MODE__": "release-candidate-adhoc",
        }.items():
            template = template.replace(key, value)
        (app / "Contents" / "Info.plist").write_text(template, encoding="utf-8")
        for name in ("RepoPrompt", "repoprompt-mcp"):
            (app / "Contents" / "MacOS" / name).write_text(name, encoding="utf-8")
        (app / "Contents" / "MacOS" / "repoprompt-mcp").chmod(0o755)
        (app / "Contents" / "Resources" / "repoprompt-mcp").symlink_to("../MacOS/repoprompt-mcp")
        (app / "Contents" / "Resources" / "bin" / "repoprompt-mcp").symlink_to("../../MacOS/repoprompt-mcp")
        legal = app / "Contents" / "Resources" / "Legal"
        shutil.copy2(staged / "LICENSE", legal / "LICENSE")
        shutil.copy2(staged / "THIRD_PARTY_NOTICES.md", legal / "THIRD_PARTY_NOTICES.md")
        shutil.copy2(
            staged / "ThirdPartyLicenses" / "fixture" / "LICENSE",
            legal / "ThirdPartyLicenses" / "fixture" / "LICENSE",
        )
        (staged / "RELEASE_COMMIT").write_text("fixture-release-commit\n", encoding="utf-8")
        return approved, staged, scripts

    @staticmethod
    def run_staged_validation(approved: Path, staged: Path, scripts: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "RELEASE_COMMIT": "fixture-release-commit",
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(staged),
            }
        )
        return subprocess.run(
            [str(scripts / "validate_staged_release.sh")],
            env=env,
            text=True,
            capture_output=True,
        )

    def make_git_remote(self) -> tuple[Path, Path]:
        parent = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, parent, True)
        remote = parent / "remote.git"
        work = parent / "work"
        self.run_checked(["git", "init", "--bare", str(remote)])
        self.run_checked(["git", "clone", str(remote), str(work)])
        self.git(work, "config", "user.email", "release-tests@example.com")
        self.git(work, "config", "user.name", "Release Tests")
        self.git(work, "checkout", "-b", "main")
        return remote, work

    def commit_file(self, work: Path, content: str) -> str:
        (work / "value.txt").write_text(content, encoding="utf-8")
        self.git(work, "add", "value.txt")
        self.git(work, "commit", "-m", content)
        return self.git(work, "rev-parse", "HEAD").stdout.strip()

    def run_signed_test_ref_verify(self, work: Path, source_ref: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "verify_signed_test_build_ref.sh"), source_ref, str(work)],
            cwd=work,
            env={"PATH": os.environ["PATH"]},
            text=True,
            capture_output=True,
        )

    def run_remote_verify(self, work: Path, expected: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "verify_remote_release_commit.sh"), "v1.0.0", expected],
            cwd=work,
            text=True,
            capture_output=True,
        )

    def git(self, work: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return self.run_checked(["git", *args], cwd=work)

    @staticmethod
    def run_checked(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
