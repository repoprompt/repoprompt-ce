#!/usr/bin/env python3
"""Regression tests for trusted release-control helpers."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from unittest import mock
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


class ReleaseToolingTests(unittest.TestCase):
    def test_debug_provenance_uses_json_validation_and_rejects_truncated_output(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        validator = SCRIPT_DIR / "validate_json.py"
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        provenance = temp_dir / "RepoPromptDebugProvenance.json"

        self.assertIn(
            'run python3 "$CONTROL_PLANE_SCRIPTS_DIR/validate_json.py" \\\n        "$APP_BUNDLE/Contents/Resources/RepoPromptDebugProvenance.json"',
            package_script,
        )
        self.assertNotIn(
            'plutil -lint "$APP_BUNDLE/Contents/Resources/RepoPromptDebugProvenance.json"',
            package_script,
        )

        provenance.write_text('{"version": 1}\n', encoding="utf-8")
        valid = subprocess.run(
            [sys.executable, str(validator), str(provenance)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(valid.stdout.strip(), f"Valid JSON: {provenance}")

        provenance.write_text('{"version":', encoding="utf-8")
        truncated = subprocess.run(
            [sys.executable, str(validator), str(provenance)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(truncated.returncode, 1)
        self.assertIn(f"error: invalid JSON file {provenance}:", truncated.stderr)

    def test_runtime_signing_policy_matches_release_metadata_and_entitlement_templates(self) -> None:
        root = SCRIPT_DIR.parent
        metadata = {}
        for line in (root / "version.env").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                metadata[key] = value.strip('"')

        package_manifest = (root / "Package.swift").read_text(encoding="utf-8")
        policy = (
            root / "Sources" / "RepoPrompt" / "Infrastructure" / "Security" / "RuntimeCodeSigningPolicy.swift"
        ).read_text(encoding="utf-8")
        entitlements = (root / "AppBundle" / "RepoPrompt.entitlements.template").read_text(encoding="utf-8")
        info_plist = plistlib.loads((root / "AppBundle" / "Info.plist.template").read_bytes())

        self.assertIn('environment["REPOPROMPT_ENABLE_SENTRY"] == "1"', package_manifest)
        self.assertIn('repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertNotIn("let sentryEnabled = true", package_manifest)

        self.assertIn(
            f'static let developerIDBundleIdentifier = "{metadata["BUNDLE_ID"]}"',
            policy,
        )
        self.assertIn(
            f'static let appleDevelopmentDebugBundleIdentifier = "{metadata["BUNDLE_ID"]}.debug"',
            policy,
        )
        self.assertIn(
            f'static let signingTeamIdentifier = "{metadata["SIGNING_TEAM_ID"]}"',
            policy,
        )
        self.assertIn("1.2.840.113635.100.6.1.13", policy)
        self.assertIn("1.2.840.113635.100.6.1.12", policy)
        self.assertIn("__SIGNING_TEAM_ID__.__BUNDLE_ID__", entitlements)
        self.assertIn("<string>__SIGNING_TEAM_ID__</string>", entitlements)
        self.assertEqual(info_plist["CFBundleIdentifier"], "__BUNDLE_ID__")
        self.assertIn("RepoPromptSigningMode", info_plist)
        self.assertIn("RepoPromptDebugSecureStorageBackend", info_plist)
        self.assertIn("RepoPromptLocalSigningCertificateSHA256", info_plist)
        self.assertIn("RepoPromptLocalSecureStorageGeneration", info_plist)
        self.assertEqual(info_plist["RepoPromptIdentityMigrationPhase"], "__IDENTITY_MIGRATION_PHASE__")
        self.assertEqual(
            info_plist["RepoPromptIdentityMigrationAnchorRelativePath"],
            "IdentityMigration/RepoPromptIdentityAnchor",
        )
        self.assertIn("RepoPromptSentryDSN", info_plist)
        self.assertEqual(info_plist["RepoPromptSentryDSN"], "")
        self.assertIn(
            'static let localSelfSignedCertificateName = "RepoPrompt CE Local Self-Signed Code Signing"',
            policy,
        )

    def test_info_plist_registers_canonical_ce_url_scheme_only(self) -> None:
        info_plist = plistlib.loads((SCRIPT_DIR.parent / "AppBundle" / "Info.plist.template").read_bytes())
        url_types = info_plist.get("CFBundleURLTypes", [])
        registered_schemes = [
            scheme
            for url_type in url_types
            for scheme in url_type.get("CFBundleURLSchemes", [])
        ]

        self.assertEqual(registered_schemes, ["repoprompt-ce"])

    def test_local_self_signed_outer_codesign_uses_equals_requirement_argv(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        sign_path_body = package_script.split("sign_path(){", 1)[1].split("\n}\nsign_sparkle_framework(){", 1)[0]
        app_signing_body = package_script.split("APP_SIGN_ARGS=()", 1)[1].split(
            'run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"',
            1,
        )[0]
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        capture = temp_dir / "codesign-argv.bin"
        fake_codesign = temp_dir / "codesign"
        fake_codesign.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\0' \"$@\" > \"$CODESIGN_CAPTURE\"\n",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        probe = temp_dir / "codesign-argv-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
run() {{ "$@"; }}
sign_path() {{{sign_path_body}
}}
IS_RELEASE=1
USE_ADHOC_SIGNING=0
USE_LOCAL_SELF_SIGNED_RELEASE=1
SIGN_IDENTITY='RepoPrompt CE Local Self-Signed Code Signing'
APP_BUNDLE='/tmp/RepoPrompt.app'
APP_ENTITLEMENTS='/tmp/RepoPrompt.entitlements'
LOCAL_SELF_SIGNED_REQUIREMENT='identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"{'1' * 40}"'
APP_SIGN_ARGS=(){app_signing_body}
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)
        env = os.environ.copy()
        env.update(
            {
                "CODESIGN_CAPTURE": str(capture),
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
            }
        )

        result = subprocess.run([str(probe)], env=env, text=True, capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            capture.read_bytes().rstrip(b"\0").decode().split("\0"),
            [
                "--force",
                "--sign",
                "RepoPrompt CE Local Self-Signed Code Signing",
                "--timestamp=none",
                "--options",
                "runtime",
                "--entitlements",
                "/tmp/RepoPrompt.entitlements",
                "--requirements",
                '=designated => identifier "com.pvncher.repoprompt.ce" and certificate leaf = H"' + "1" * 40 + '"',
                "/tmp/RepoPrompt.app",
            ],
        )

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

    def test_staged_signing_resigns_every_codex_mach_o_before_mcp_and_outer_app(self) -> None:
        source = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")

        self.assertIn('CODEX_MANIFEST="$METADATA_ROOT/Vendor/Codex/manifest.json"', source)
        self.assertIn('python3 "$SCRIPT_DIR/codex_runtime_artifact.py"', source)
        self.assertEqual(source.count('--manifest "$CODEX_MANIFEST" verify-bundle'), 2)
        self.assertEqual(source.count("list-bundle-signing-plan --arch all"), 1)
        self.assertNotIn("list-bundle-mach-o-paths", source)
        self.assertEqual(source.count('--signed-team-identifier "$SIGNING_TEAM_ID"'), 1)
        self.assertNotIn('$TRUSTED_ROOT/Vendor/Codex/manifest.json', source)
        self.assertIn('CODEX_V8_ENTITLEMENTS="$TRUSTED_ROOT/AppBundle/CodexV8JIT.entitlements"', source)
        self.assertIn('plutil -lint "$CODEX_V8_ENTITLEMENTS"', source)
        for line in source.splitlines():
            if 'sign_path "$CODEX_BUNDLE' in line:
                self.assertNotIn("--preserve-metadata", line)

        sparkle_sign = source.index('sign_sparkle_framework "$STAGED_SPARKLE_FRAMEWORK"')
        enumerate_codex = source.index("list-bundle-signing-plan --arch all")
        codex_sign = source.index('sign_path "$CODEX_BUNDLE/$relative_path" --entitlements "$CODEX_V8_ENTITLEMENTS"')
        codex_sign_unprofiled = source.index('sign_path "$CODEX_BUNDLE/$relative_path"\n', codex_sign + 1)
        mcp_sign = source.index('sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"')
        app_sign = source.index('sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"')
        outer_sign = source.index('sign_path "$APP_BUNDLE" --entitlements "$app_entitlements"')
        self.assertLess(sparkle_sign, enumerate_codex)
        self.assertLess(enumerate_codex, codex_sign)
        self.assertLess(codex_sign, codex_sign_unprofiled)
        self.assertLess(codex_sign_unprofiled, mcp_sign)
        self.assertLess(mcp_sign, app_sign)
        self.assertLess(app_sign, outer_sign)
        self.assertNotIn('sign_path "$CODEX_BUNDLE"', source)

    def test_legacy_preparer_requires_verified_future_identity_anchor(self) -> None:
        package_source = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        source = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")

        self.assertTrue((SCRIPT_DIR / "identity_migration_anchor.c").is_file())
        self.assertIn("validate_stable_release_context", package_source)
        self.assertIn("legacy-preparer packaging requires a resolved Stable or Tip release context", package_source)
        self.assertIn('[[ "$PACKAGED_IDENTITY_MIGRATION_PHASE" == "$IDENTITY_MIGRATION_PHASE" ]]', package_source)
        self.assertIn('plutil -extract RepoPromptIdentityMigrationPhase raw', source)
        self.assertIn("printf 'disabled\\n'", source)
        self.assertIn('[[ "$identity_migration_phase" == "$expected_identity_migration_phase" ]]', source)
        self.assertIn('REPOPROMPT_IDENTITY_MIGRATION_ANCHOR', source)
        self.assertIn('IDENTITY_MIGRATION_TARGET_REQUIREMENT="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT"', source)
        self.assertIn('-R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$identity_migration_anchor"', source)
        self.assertIn('-R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"', source)
        self.assertIn('validate_resolved_migration_anchor_identity "$anchor_identifier" "$anchor_team"', source)
        self.assertNotIn('codesign --force --sign "$SIGN_IDENTITY"', source.split(
            'ditto "$identity_migration_anchor" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"',
            1,
        )[0].split("legacy-preparer)", 1)[1])
        self.assertLess(
            source.index('ditto "$identity_migration_anchor" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"'),
            source.index('sign_path "$APP_BUNDLE" --entitlements "$app_entitlements"'),
        )

    def test_release_workflows_gate_stable_preparer_and_require_explicit_nonlegacy_tip_dispatch(self) -> None:
        workflows = SCRIPT_DIR.parent / ".github" / "workflows"
        release_workflow = (workflows / "release.yml").read_text(encoding="utf-8")
        tip_workflow = (workflows / "main-tip.yml").read_text(encoding="utf-8")

        self.assertIn("identity_migration_phase:", release_workflow)
        self.assertIn("default: disabled", release_workflow)
        self.assertIn("- legacy-preparer", release_workflow)
        self.assertEqual(release_workflow.count("SUCCESSOR_DEVELOPER_ID_APPLICATION_P12_BASE64"), 1)
        self.assertEqual(release_workflow.count("SUCCESSOR_DEVELOPER_ID_APPLICATION_P12_PASSWORD"), 1)
        self.assertNotIn("SUCCESSOR_SIGN_IDENTITY: ${{ vars.SUCCESSOR_SIGN_IDENTITY }}", release_workflow)
        self.assertNotIn("vars.SIGN_IDENTITY", release_workflow)
        self.assertNotIn("EXPECTED_SUCCESSOR_SIGN_IDENTITY", release_workflow)
        self.assertNotIn("SUCCESSOR_DEVELOPER_ID_INSTALLER", release_workflow)
        self.assertNotIn("SUCCESSOR_NOTARYTOOL", release_workflow)
        self.assertIn('--identifier "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"', release_workflow)
        self.assertIn('grep -Fx "Identifier=$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"', release_workflow)
        self.assertIn('grep -Fx "TeamIdentifier=$EXPECTED_MIGRATION_ANCHOR_TEAM_ID"', release_workflow)
        self.assertIn('-R="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" "$anchor"', release_workflow)
        self.assertIn('printf \'REPOPROMPT_IDENTITY_MIGRATION_ANCHOR=%s\\n\' "$anchor" >> "$GITHUB_ENV"', release_workflow)

        release_stage = release_workflow.split("\n  stage:", 1)[1].split("\n  publish:", 1)[0]
        release_publish = release_workflow.split("\n  publish:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        release_anchor = release_publish.split("      - name: Prepare successor identity migration anchor", 1)[1].split(
            "      - name: Prepare provisioning profile and notarization key", 1
        )[0]
        self.assertNotIn("SUCCESSOR_", release_stage)
        self.assertIn("if: inputs.identity_migration_phase == 'legacy-preparer'", release_anchor)
        self.assertIn('anchor_source="trusted-control-plane/Scripts/identity_migration_anchor.c"', release_anchor)
        self.assertIn(
            'xcrun clang -arch arm64 -arch x86_64 -Os -Wl,-dead_strip -o "$anchor" "$anchor_source"',
            release_anchor,
        )
        self.assertNotIn('release-source/.build/release/RepoPrompt.app/Contents/MacOS/RepoPrompt', release_anchor)
        self.assertNotIn(
            "REPOPROMPT_IDENTITY_MIGRATION_PHASE: ${{ inputs.identity_migration_phase }}",
            release_workflow,
        )
        self.assertEqual(release_workflow.count("stable_rollout.py packaging-context"), 2)
        self.assertEqual(release_workflow.count('--github-env "$GITHUB_ENV"'), 2)
        self.assertEqual(release_workflow.count('--expected-migration-phase "$REQUESTED_IDENTITY_MIGRATION_PHASE"'), 2)
        self.assertLess(
            release_publish.index("Prepare successor identity migration anchor"),
            release_publish.index("Sign, notarize, and create draft release"),
        )
        self.assertIn('rm -f "$RUNNER_TEMP/repoprompt-release-successor.p12"', release_publish)
        self.assertIn('rm -f "$RUNNER_TEMP/repoprompt-successor-identity-anchor"', release_publish)

        self.assertNotIn("identity_migration_phase:", tip_workflow)
        self.assertIn("confirm_identity_rollout_role:", tip_workflow)
        self.assertIn('if [[ "$ROLLOUT_ROLE" != "legacy" ]]', tip_workflow)
        self.assertIn('if [[ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]]', tip_workflow)
        self.assertIn('[[ "$CONFIRMED_ROLLOUT_ROLE" != "$ROLLOUT_ROLE" ]]', tip_workflow)
        self.assertIn("Prepare successor identity migration anchor", tip_workflow)
        self.assertIn("if: needs.setup.outputs.rollout-role == 'preparer'", tip_workflow)
        self.assertNotIn("needs.setup.outputs.migration-phase", tip_workflow)
        self.assertNotIn("needs.setup.outputs.rollout-identity", tip_workflow)
        self.assertIn("REPOPROMPT_IDENTITY_MIGRATION_PHASE", (SCRIPT_DIR / "tip_release_context.py").read_text())

        credential_preflight = tip_workflow.split(
            "      - name: Validate role-selected Tip credentials", 1
        )[1].split("\n\n  stage:", 1)[0]
        preflight_run = credential_preflight.split("        run: |\n", 1)[1]
        self.assertIn('PREFLIGHT_KEYCHAIN_PATH="$RUNNER_TEMP/repoprompt-tip-preflight.keychain-db"', preflight_run)
        self.assertIn("trap cleanup_preflight_credentials EXIT", preflight_run)
        self.assertIn('rm -f "$CERTIFICATE_PATH"', preflight_run)
        self.assertIn('security delete-keychain "$PREFLIGHT_KEYCHAIN_PATH" || true', preflight_run)
        self.assertIn('rm -f "$PREFLIGHT_KEYCHAIN_PATH"', preflight_run)
        self.assertLess(
            preflight_run.index('security delete-keychain "$PREFLIGHT_KEYCHAIN_PATH" || true'),
            preflight_run.index('rm -f "$PREFLIGHT_KEYCHAIN_PATH"'),
        )
        self.assertLess(
            preflight_run.index("trap cleanup_preflight_credentials EXIT"),
            preflight_run.index("base64 --decode"),
        )
        self.assertNotIn(">/dev/null 2>&1 || fail", preflight_run)
        for noun_fragment in (
            "application certificate",
            "successor application certificate",
            "successor installer certificate",
            "application signing identity",
            "successor application signing identity",
            "successor installer identity",
        ):
            self.assertNotIn(f'|| fail "{noun_fragment}"', preflight_run)
        self.assertIn(
            'security import "$CERTIFICATE_PATH" -k "$PREFLIGHT_KEYCHAIN_PATH" -P "$CERTIFICATE_P12_PASSWORD"',
            preflight_run,
        )
        self.assertIn(
            'security import "$SUCCESSOR_CERTIFICATE_PATH" -k "$PREFLIGHT_KEYCHAIN_PATH" -P "$SUCCESSOR_CERTIFICATE_P12_PASSWORD"',
            preflight_run,
        )
        self.assertIn(
            'security import "$INSTALLER_CERTIFICATE_PATH" -k "$PREFLIGHT_KEYCHAIN_PATH" -P "$SUCCESSOR_INSTALLER_P12_PASSWORD"',
            preflight_run,
        )
        self.assertIn('security set-key-partition-list -S apple-tool:,apple:,codesign:', preflight_run)
        self.assertIn('security set-key-partition-list -S apple-tool:,apple:,codesign:,productbuild:', preflight_run)
        self.assertIn('security find-identity -v -p codesigning "$PREFLIGHT_KEYCHAIN_PATH"', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_SIGN_IDENTITY\\""', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY\\""', preflight_run)
        self.assertIn('security find-identity -v -p basic "$PREFLIGHT_KEYCHAIN_PATH"', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_INSTALLER_IDENTITY\\""', preflight_run)
        self.assertNotIn("security list-keychains", preflight_run)
        self.assertNotIn("security default-keychain", preflight_run)
        self.assertNotIn("GITHUB_ENV", preflight_run)
        self.assertNotIn("GITHUB_OUTPUT", preflight_run)

    def test_codex_v8_entitlement_allowlist_matches_pinned_manifest_policy(self) -> None:
        v8_profile = {
            "com.apple.security.cs.allow-jit": True,
            "com.apple.security.cs.allow-unsigned-executable-memory": True,
        }
        plist = plistlib.loads((SCRIPT_DIR.parent / "AppBundle" / "CodexV8JIT.entitlements").read_bytes())
        self.assertEqual(plist, v8_profile)

        manifest = json.loads(
            (SCRIPT_DIR.parent / "Vendor" / "Codex" / "manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(
            manifest["releaseSigningEntitlements"],
            {
                "bin/codex": v8_profile,
                "bin/codex-code-mode-host": v8_profile,
                "codex-path/rg": {},
                "codex-resources/zsh/bin/zsh": {},
            },
        )
        for policy in manifest["signedExecutables"]:
            self.assertEqual(policy["entitlements"], v8_profile, policy["path"])

        for release_script_name in (
            "release.sh",
            "main_tip_release.sh",
            "promote_release.sh",
            "publish_public_update_test.sh",
        ):
            release_source = (SCRIPT_DIR / release_script_name).read_text(encoding="utf-8")
            self.assertIn("--signed-team-identifier", release_source, release_script_name)

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
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_required_swiftpm_resource_bundles.sh"', release_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh"', release_script)
        self.assertIn(
            'require_file "$CONTROL_PLANE_SCRIPTS_DIR/patches/keyboardshortcuts-2.3.0-resource-lookup.patch"',
            release_script,
        )
        self.assertIn('DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"', release_script)
        self.assertIn('ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"', release_script)
        self.assertIn('DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"', promote_script)
        self.assertIn('APP_BUNDLE="$EXTRACT_DIR/$DISPLAY_NAME.app"', public_update_script)

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

    def test_embedded_helper_smoke_rejects_canonical_path_escape(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        helper = app / "Contents" / "MacOS" / "repoprompt-mcp"
        helper.parent.mkdir(parents=True)
        outside = temp_dir / "outside-helper"
        outside.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        outside.chmod(0o755)
        helper.symlink_to(outside)

        result = subprocess.run(
            [str(SCRIPT_DIR / "smoke_embedded_mcp_helper.sh"), str(app), "Escaping helper"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("escapes app bundle", result.stderr)

    def test_universal_builder_uses_isolated_architecture_scratch_paths_and_unsigned_merge(self) -> None:
        source = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")

        self.assertIn('SCRATCH_ROOT="${REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT:', source)
        self.assertIn('CLEAN_PUBLIC_SWIFTPM_BUILDS="${REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS:-1}"', source)
        self.assertIn('for arch in arm64 x86_64; do', source)
        self.assertIn('REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch"', source)
        self.assertIn('patch_keyboard_shortcuts_resource_lookup.sh', source)
        self.assertIn('--scratch-path "$scratch"', source)
        self.assertIn('--arch "$arch"', source)
        self.assertIn('--product RepoPrompt', source)
        self.assertIn('--product repoprompt-mcp', source)
        self.assertIn('compare_swiftpm_release_resources.py', source)
        architecture_loop = source.split('for arch in arm64 x86_64; do', 1)[1]
        self.assertLess(source.index('run rm -rf "$SCRATCH_ROOT"'), source.index('for arch in arm64 x86_64; do'))
        self.assertLess(architecture_loop.index('"$KEYBOARD_SHORTCUTS_PATCH_HELPER"'), architecture_loop.index("swift build"))
        self.assertEqual(source.count('"$LIPO" -create'), 2)
        self.assertNotIn("codesign", source)

    def test_universal_builder_cleans_stale_resources_by_default_and_patches_each_fresh_scratch(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "source"
        root.mkdir()
        scratch = temp_dir / "scratch"
        output = temp_dir / "products" / "release"
        scratch.mkdir(parents=True)
        (scratch / ".repoprompt-public-swiftpm-scratch").write_text("fixture\n", encoding="utf-8")
        for arch in ("arm64", "x86_64"):
            stale = scratch / arch / "release" / "Stale.bundle"
            stale.mkdir(parents=True)
            (stale / "stale.txt").write_text("stale\n", encoding="utf-8")

        tools = temp_dir / "tools"
        tools.mkdir()
        patch_log = temp_dir / "patch.log"
        wrapper = tools / "without-tokens"
        wrapper.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "swift" && "$2" == "build" ]]
shift 2
scratch=""
arch=""
show=0
while (( $# )); do
    case "$1" in
        --scratch-path) scratch="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --show-bin-path) show=1; shift ;;
        *) shift ;;
    esac
done
bin="$scratch/release"
mkdir -p "$bin/Current.bundle"
printf '%s\\n' "$arch" > "$bin/RepoPrompt"
printf '%s\\n' "$arch" > "$bin/repoprompt-mcp"
printf 'current\\n' > "$bin/Current.bundle/value.txt"
if (( show )); then printf '%s\\n' "$bin"; fi
""",
            encoding="utf-8",
        )
        patch = tools / "patch-keyboard-shortcuts"
        patch.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$REPOPROMPT_SWIFTPM_SCRATCH_PATH\" >> \"$PATCH_LOG\"\n",
            encoding="utf-8",
        )
        comparator = tools / "compare-resources"
        comparator.write_text("#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n", encoding="utf-8")
        lipo = tools / "lipo"
        lipo.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-archs" ]]; then
    cat "$2"
    exit 0
fi
output=""
while (( $# )); do
    if [[ "$1" == "-output" ]]; then output="$2"; shift 2; else shift; fi
done
printf 'arm64 x86_64\\n' > "$output"
""",
            encoding="utf-8",
        )
        ditto = tools / "ditto"
        ditto.write_text("#!/usr/bin/env bash\nset -euo pipefail\ncp -R \"$1\" \"$2\"\n", encoding="utf-8")
        for tool in (wrapper, patch, comparator, lipo, ditto):
            tool.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{tools}:{env['PATH']}",
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(scratch),
                "REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS": str(wrapper),
                "REPOPROMPT_KEYBOARD_SHORTCUTS_PATCH_HELPER": str(patch),
                "REPOPROMPT_SWIFTPM_RESOURCE_COMPARATOR": str(comparator),
                "PATCH_LOG": str(patch_log),
                "LIPO": str(lipo),
            }
        )
        result = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(output)],
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / "Stale.bundle").exists())
        self.assertTrue((output / "Current.bundle" / "value.txt").is_file())
        self.assertEqual(
            patch_log.read_text(encoding="utf-8").splitlines(),
            [str(scratch / "arm64"), str(scratch / "x86_64")],
        )

        repository_marker = root / "must-survive.txt"
        repository_marker.write_text("keep\n", encoding="utf-8")
        unsafe_root_env = env | {"REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(root)}
        unsafe_root = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(temp_dir / "unsafe-root-output")],
            env=unsafe_root_env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(unsafe_root.returncode, 0)
        self.assertIn("repository root", unsafe_root.stderr)
        self.assertTrue(repository_marker.is_file())

        unmarked = temp_dir / "unmarked-scratch"
        unmarked.mkdir()
        unmarked_marker = unmarked / "must-survive.txt"
        unmarked_marker.write_text("keep\n", encoding="utf-8")
        unmarked_env = env | {"REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT": str(unmarked)}
        unsafe_unmarked = subprocess.run(
            [str(SCRIPT_DIR / "build_swiftpm_release_products.sh"), str(temp_dir / "unsafe-unmarked-output")],
            env=unmarked_env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(unsafe_unmarked.returncode, 0)
        self.assertIn("unmarked public SwiftPM scratch path", unsafe_unmarked.stderr)
        self.assertTrue(unmarked_marker.is_file())

    def test_swiftpm_resource_comparator_accepts_equivalence_and_rejects_drift(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        arm = temp_dir / "arm"
        intel = temp_dir / "intel"
        for root in (arm, intel):
            (root / "Fixture.bundle" / "nested").mkdir(parents=True)
            (root / "Fixture.bundle" / "nested" / "value.txt").write_text("same\n", encoding="utf-8")
            (root / "Fixture.bundle" / "link").symlink_to("nested/value.txt")
            (root / "Sparkle.framework").mkdir()
            (root / "Sparkle.framework" / "Info.plist").write_text("same\n", encoding="utf-8")

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "compare_swiftpm_release_resources.py"), str(arm), str(intel)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        (intel / "Fixture.bundle" / "nested" / "value.txt").write_text("different\n", encoding="utf-8")
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "compare_swiftpm_release_resources.py"), str(arm), str(intel)],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("resource differs", rejected.stderr)

    def test_architecture_validator_accepts_universal_and_rejects_helper_mismatch(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        env = os.environ.copy()
        env["LIPO"] = str(fake_lipo)

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "validate_app_architectures.sh"), str(app), "arm64,x86_64", "Fixture"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        env["FAKE_THIN_HELPER"] = "1"
        rejected = subprocess.run(
            [str(SCRIPT_DIR / "validate_app_architectures.sh"), str(app), "arm64,x86_64", "Fixture"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("matching app/helper architectures", rejected.stderr)

    def test_artifact_manifest_is_deterministic_external_and_detects_binary_drift(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        info = {
            "CFBundleExecutable": "RepoPrompt",
            "CFBundleIdentifier": "com.pvncher.repoprompt.ce",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "RepoPromptSigningMode": "release-candidate-adhoc",
        }
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        fake_codesign = app.parent / "codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *--extract-certificates*)
    [[ "${FAKE_CERTIFICATE_AVAILABLE:-0}" == "1" ]] || exit 1
    for argument in "$@"; do
      case "$argument" in
        --extract-certificates=*) printf 'fixture certificate\n' > "${argument#*=}0" ;;
      esac
    done
    ;;
  *--entitlements*)
    [[ "${FAKE_MISSING_ENTITLEMENTS:-0}" != "1" ]] || exit 1
    cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>fixture</key><true/></dict></plist>
PLIST
    ;;
  *-r-*)
    [[ "${FAKE_MISSING_REQUIREMENT:-0}" != "1" ]] || exit 0
    printf 'designated => identifier "fixture"\n' >&2
    ;;
  *)
    if [[ "${FAKE_CERTIFICATE_BACKED:-0}" == "1" ]]; then
      printf 'Identifier=fixture\nTeamIdentifier=TEAMID\nAuthority=Developer ID Application: Fixture\n' >&2
    else
      printf 'Identifier=fixture\nTeamIdentifier=not set\n' >&2
    fi
    ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = app.parent / "artifact-manifest.json"
        env = os.environ.copy()
        env.update({"LIPO": str(fake_lipo), "CODESIGN": str(fake_codesign)})
        writer = SCRIPT_DIR / "write_app_artifact_manifest.py"

        written = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(written.returncode, 0, written.stderr)
        content = manifest.read_text(encoding="utf-8")
        self.assertNotIn(str(app.parent), content)
        self.assertNotIn("generated_at", content)
        manifest_content = json.loads(content)
        self.assertIsNone(manifest_content["bundle_signing"]["leaf_certificate_sha256"])
        for executable in manifest_content["executables"]:
            self.assertIsNone(executable["signing"]["leaf_certificate_sha256"])
        # The RC fixture has no DSN, so telemetry is disabled.
        self.assertFalse(manifest_content["bundle"]["telemetry_enabled"])

        # With a DSN present, the manifest records telemetry_enabled=True but never the DSN value.
        dsn_value = "https://examplepublickey@o9999.ingest.sentry.io/424242"
        info_with_dsn = dict(info)
        info_with_dsn["RepoPromptSentryDSN"] = dsn_value
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info_with_dsn))
        dsn_manifest = app.parent / "telemetry-manifest.json"
        dsn_written = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(dsn_manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(dsn_written.returncode, 0, dsn_written.stderr)
        dsn_manifest_text = dsn_manifest.read_text(encoding="utf-8")
        self.assertNotIn(dsn_value, dsn_manifest_text)
        self.assertNotIn("examplepublickey", dsn_manifest_text)
        self.assertTrue(json.loads(dsn_manifest_text)["bundle"]["telemetry_enabled"])
        # Restore the no-DSN RC Info.plist so the remainder of the test is unaffected.
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

        accepted = subprocess.run(
            [
                str(writer),
                "verify",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        env["FAKE_MISSING_REQUIREMENT"] = "1"
        missing_requirement = subprocess.run(
            [str(writer), "write", "--app", str(app), "--output", str(app.parent / "missing-requirement.json")],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(missing_requirement.returncode, 0, missing_requirement.stderr)
        missing_requirement_manifest = json.loads(
            (app.parent / "missing-requirement.json").read_text(encoding="utf-8")
        )
        self.assertIsNone(missing_requirement_manifest["bundle_signing"]["designated_requirement"])
        for executable in missing_requirement_manifest["executables"]:
            self.assertIsNone(executable["signing"]["designated_requirement"])

        env["FAKE_CERTIFICATE_BACKED"] = "1"
        certificate_backed_missing_requirement = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "certificate-backed-missing-requirement.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(certificate_backed_missing_requirement.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose a designated requirement",
            certificate_backed_missing_requirement.stderr,
        )
        env.pop("FAKE_MISSING_REQUIREMENT")
        certificate_backed_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "certificate-backed-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(certificate_backed_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            certificate_backed_missing_certificate.stderr,
        )
        env.pop("FAKE_CERTIFICATE_BACKED")

        info["RepoPromptSigningMode"] = "developer-id"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        env["FAKE_MISSING_REQUIREMENT"] = "1"
        developer_id_missing_requirement = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "developer-id-missing-requirement.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(developer_id_missing_requirement.returncode, 0)
        self.assertIn(
            "signed path did not expose a designated requirement",
            developer_id_missing_requirement.stderr,
        )
        env.pop("FAKE_MISSING_REQUIREMENT")
        developer_id_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "developer-id-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(developer_id_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            developer_id_missing_certificate.stderr,
        )

        info["RepoPromptSigningMode"] = "local-self-signed"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        local_self_signed_missing_certificate = subprocess.run(
            [
                str(writer),
                "write",
                "--app",
                str(app),
                "--output",
                str(app.parent / "local-self-signed-missing-certificate.json"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(local_self_signed_missing_certificate.returncode, 0)
        self.assertIn(
            "certificate-backed signed path did not expose an extractable leaf certificate",
            local_self_signed_missing_certificate.stderr,
        )

        info["RepoPromptSigningMode"] = "developer-id"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        env["FAKE_CERTIFICATE_AVAILABLE"] = "1"
        env["FAKE_MISSING_ENTITLEMENTS"] = "1"
        missing_entitlements = subprocess.run(
            [str(writer), "write", "--app", str(app), "--output", str(app.parent / "missing-entitlements.json")],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing_entitlements.returncode, 0)
        self.assertIn("did not expose parseable signed entitlements", missing_entitlements.stderr)
        env.pop("FAKE_MISSING_ENTITLEMENTS")
        env.pop("FAKE_CERTIFICATE_AVAILABLE")
        info["RepoPromptSigningMode"] = "release-candidate-adhoc"
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

        with (app / "Contents" / "MacOS" / "repoprompt-mcp").open("a", encoding="utf-8") as handle:
            handle.write("drift\n")
        rejected = subprocess.run(
            [
                str(writer),
                "verify",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match app bundle", rejected.stderr)

    def test_artifact_manifest_records_certificate_from_equals_form_extraction(self) -> None:
        app, fake_lipo = self.make_universal_architecture_fixture()
        info = {
            "CFBundleExecutable": "RepoPrompt",
            "CFBundleIdentifier": "com.pvncher.repoprompt.ce",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "RepoPromptSigningMode": "developer-id",
        }
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
        certificate = b"fixture leaf certificate\n"
        fake_codesign = app.parent / "codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$1" >> "$CODESIGN_CAPTURE"
for argument in "${@:2}"; do printf '\t%s' "$argument" >> "$CODESIGN_CAPTURE"; done
printf '\n' >> "$CODESIGN_CAPTURE"
certificate_prefix=""
for argument in "$@"; do
  case "$argument" in
    --extract-certificates=*) certificate_prefix="${argument#*=}" ;;
    --extract-certificates)
      printf 'certificate prefix must use the equals form\n' >&2
      exit 64
      ;;
  esac
done
if [[ -n "$certificate_prefix" ]]; then
  [[ "${FAKE_MISSING_CERTIFICATE_FOR:-}" != "${@: -1}" ]] || exit 1
  printf 'fixture leaf certificate\n' > "${certificate_prefix}0"
  exit 0
fi
case "$*" in
  *--entitlements*)
    printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n'
    ;;
  *-r-*)
    printf 'designated => identifier "fixture"\n' >&2
    ;;
  *)
    printf 'Identifier=fixture\nTeamIdentifier=TEAMID\nAuthority=Developer ID Application: Fixture\n' >&2
    ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = app.parent / "certificate-manifest.json"
        codesign_capture = app.parent / "codesign-argv.txt"
        env = os.environ.copy()
        env.update(
            {
                "LIPO": str(fake_lipo),
                "CODESIGN": str(fake_codesign),
                "CODESIGN_CAPTURE": str(codesign_capture),
            }
        )

        result = subprocess.run(
            [
                str(SCRIPT_DIR / "write_app_artifact_manifest.py"),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        content = json.loads(manifest.read_text(encoding="utf-8"))
        expected_fingerprint = hashlib.sha256(certificate).hexdigest()
        self.assertEqual(content["bundle_signing"]["leaf_certificate_sha256"], expected_fingerprint)
        for executable in content["executables"]:
            self.assertEqual(executable["signing"]["leaf_certificate_sha256"], expected_fingerprint)
        extraction_calls = [
            line.split("\t")
            for line in codesign_capture.read_text(encoding="utf-8").splitlines()
            if any(argument.startswith("--extract-certificates=") for argument in line.split("\t"))
        ]
        self.assertEqual(len(extraction_calls), 3)
        for arguments in extraction_calls:
            self.assertEqual(arguments[:2], ["-d", next(item for item in arguments if item.startswith("--extract-certificates="))])
            self.assertNotIn("--extract-certificates", arguments)

        covered_paths = [app / "Contents" / "MacOS" / "RepoPrompt", app / "Contents" / "MacOS" / "repoprompt-mcp", app]
        for index, covered_path in enumerate(covered_paths):
            with self.subTest(covered_path=covered_path):
                failure_env = env | {"FAKE_MISSING_CERTIFICATE_FOR": str(covered_path)}
                rejected = subprocess.run(
                    [
                        str(SCRIPT_DIR / "write_app_artifact_manifest.py"),
                        "write",
                        "--app",
                        str(app),
                        "--output",
                        str(app.parent / f"missing-certificate-{index}.json"),
                        "--expected-architectures",
                        "arm64,x86_64",
                    ],
                    env=failure_env,
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    f"certificate-backed signed path did not expose an extractable leaf certificate: {covered_path}",
                    rejected.stderr,
                )

    def test_packaging_path_identity_skips_nested_compatibility_link(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        architecture_release = temp_dir / ".build" / "arm64-apple-macosx" / "release"
        architecture_release.mkdir(parents=True)
        compatibility_release = temp_dir / ".build" / "release"
        compatibility_release.symlink_to(Path("arm64-apple-macosx") / "release")
        app_bundle = architecture_release / "RepoPrompt.app"
        compatibility_app_bundle = compatibility_release / "RepoPrompt.app"

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        function_body = package_script.split("paths_same(){", 1)[1].split("\n}\nfinish(){", 1)[0]
        probe = temp_dir / "path-identity-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
paths_same(){{{function_body}
}}
if [[ "$(paths_same "$1" "$2")" != "1" ]]; then
  ln -sfn "$1" "$2"
fi
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)

        result = subprocess.run(
            [str(probe), str(app_bundle), str(compatibility_app_bundle)],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(compatibility_app_bundle.is_symlink())
        self.assertFalse((app_bundle / "RepoPrompt.app").exists())

    def test_packaging_path_identity_keeps_case_distinct_missing_paths_separate(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)

        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        function_body = package_script.split("paths_same(){", 1)[1].split("\n}\nfinish(){", 1)[0]
        probe = temp_dir / "path-identity-case-probe.sh"
        probe.write_text(
            f"""#!/usr/bin/env bash
set -euo pipefail
paths_same(){{{function_body}
}}
paths_same "$1" "$2"
""",
            encoding="utf-8",
        )
        probe.chmod(0o755)

        result = subprocess.run(
            [str(probe), str(temp_dir / "RepoPrompt.app"), str(temp_dir / "repoprompt.app")],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0")

    def test_packaging_removes_stale_public_manifest_before_non_public_preflight(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        cleanup_before_metadata = """remove_stale_artifact_manifests
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"""
        manifest_write_block = package_script.split(
            'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Post-sign packaged app"',
            1,
        )[1].split(
            'run "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"',
            1,
        )[0]

        self.assertIn('manifests=("$ROOT_DIR"/.build/release/*-artifact-manifest.json)', package_script)
        self.assertIn(cleanup_before_metadata, package_script)
        self.assertIn("if (( PUBLIC_UNIVERSAL_RELEASE )); then", manifest_write_block)
        self.assertIn('write_app_artifact_manifest.py" write', manifest_write_block)
        self.assertIn('--output "$ARTIFACT_MANIFEST"', manifest_write_block)

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "repo"
        scripts = root / "Scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SCRIPT_DIR / "load_release_metadata.sh", scripts / "load_release_metadata.sh")
        doctor = scripts / "doctor.sh"
        doctor.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8")
        doctor.chmod(0o755)
        metadata = root / "version.env"
        artifact_manifest = root / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        artifact_manifest.parent.mkdir(parents=True)
        env = os.environ.copy()
        env.update(
            {
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
            }
        )

        metadata.write_text("invalid metadata\n", encoding="utf-8")
        artifact_manifest.write_text("stale\n", encoding="utf-8")
        metadata_failure = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(metadata_failure.returncode, 0)
        self.assertFalse(artifact_manifest.exists())

        metadata.write_text(
            """APP_NAME=RepoPrompt
DISPLAY_NAME="RepoPrompt CE"
MARKETING_VERSION=1.0.0
BUILD_NUMBER=1
BUNDLE_ID=com.pvncher.repoprompt.ce
SIGNING_TEAM_ID=648A27MST5
""",
            encoding="utf-8",
        )
        artifact_manifest.write_text("stale\n", encoding="utf-8")
        preflight_failure = subprocess.run(
            [str(SCRIPT_DIR / "package_app.sh"), "debug"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(preflight_failure.returncode, 42, preflight_failure.stderr)
        self.assertFalse(artifact_manifest.exists())

    def test_packaged_roundtrip_source_uses_exact_pid_and_isolated_cleanup_without_global_kill(self) -> None:
        source = (SCRIPT_DIR / "smoke_packaged_mcp_roundtrip.sh").read_text(encoding="utf-8")

        self.assertIn('env -i', source)
        self.assertIn('CFFIXED_USER_HOME="$ISOLATED_HOME"', source)
        self.assertIn('"$MCP_HELPER"', source)
        self.assertIn('[helper, "-e", "windows"]', source)
        self.assertIn('HELPER_REQUEST_TIMEOUT="${REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT:-30}"', source)
        self.assertIn('timeout=int(helper_timeout)', source)
        self.assertIn('"MCP_SOCKET_DEBUG": "1"', source)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_DIAGNOSTICS_DIR', source)
        self.assertIn('sample "$APP_PID" 5 1', source)
        cleanup = source.split("cleanup() {", 1)[1].split("\n}", 1)[0]
        self.assertLess(cleanup.index("set +e"), cleanup.index("sample "))
        self.assertLess(cleanup.index("set +e"), cleanup.index('kill -TERM "$APP_PID"'))
        self.assertIn('helper-socket-debug.log', source)
        self.assertIn('except subprocess.TimeoutExpired as error:', source)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT must be a positive integer', source)
        self.assertIn('log_phase() {', source)
        self.assertIn('windows-attempt-${attempt}.out', source)
        self.assertIn('windows-attempt-${attempt}.err', source)
        self.assertIn('CLI windows attempt ${attempt}', source)
        self.assertIn('APP_PID=$!', source)
        self.assertIn('launched-process.json', source)
        self.assertIn('mkdir -p "$ISOLATED_HOME/Library/Keychains" "$ISOLATED_HOME/Library/Preferences"', source)
        self.assertIn('SMOKE_KEYCHAIN_PATH="$ISOLATED_HOME/Library/Keychains/repoprompt-packaged-smoke.keychain-db"', source)
        self.assertIn('isolated_security create-keychain -p "$SMOKE_KEYCHAIN_PASSWORD" "$SMOKE_KEYCHAIN_PATH"', source)
        self.assertIn('isolated_security unlock-keychain -p "$SMOKE_KEYCHAIN_PASSWORD" "$SMOKE_KEYCHAIN_PATH"', source)
        self.assertIn('isolated_security list-keychains -d user -s "$SMOKE_KEYCHAIN_PATH"', source)
        self.assertIn('isolated_security default-keychain -d user -s "$SMOKE_KEYCHAIN_PATH"', source)
        self.assertIn('isolated_security delete-keychain "$SMOKE_KEYCHAIN_PATH"', cleanup)
        self.assertLess(source.index('isolated_security create-keychain'), source.index('APP_PID=$!'))
        self.assertLess(source.index('isolated_security default-keychain'), source.index('APP_PID=$!'))
        self.assertIn('verify_packaged_mcp_socket_owner.py', source)
        self.assertIn('"$SOCKET_OWNER_HELPER" selftest', source)
        self.assertIn('preflight "$MCP_SOCKET_DIR"', source)
        self.assertIn('find-owner "$MCP_SOCKET_DIR" "$APP_PID" "$APP_EXECUTABLE"', source)
        self.assertIn('verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE"', source)
        self.assertLess(source.index('"$SOCKET_OWNER_HELPER" selftest'), source.index('preflight "$MCP_SOCKET_DIR"'))
        self.assertLess(source.index('preflight "$MCP_SOCKET_DIR"'), source.index('APP_PID=$!'))
        roundtrip_loop = source.split('while (( $(date +%s) <= deadline )); do', 1)[1]
        self.assertLess(
            roundtrip_loop.index('verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE"'),
            roundtrip_loop.index("run_windows_request"),
        )
        self.assertIn('kill -TERM "$APP_PID"', source)
        self.assertIn('kill -KILL "$APP_PID"', source)
        self.assertIn('rm -rf "$TEMP_ROOT"', source)
        self.assertNotIn("pkill", source)
        self.assertNotIn("open -n", source)

    @unittest.skipUnless(sys.platform == "darwin", "macOS libproc socket descriptor inspection")
    def test_packaged_socket_owner_find_treats_startup_snapshot_transition_as_retryable(self) -> None:
        helper_path = SCRIPT_DIR / "verify_packaged_mcp_socket_owner.py"
        spec = importlib.util.spec_from_file_location("verify_packaged_mcp_socket_owner_test", helper_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)

        missing_snapshot = (None, {})
        created_snapshot = ((101, 202), {})
        with (
            mock.patch.object(helper, "validate_expected_process") as validate_process,
            mock.patch.object(helper, "capture_socket_snapshot", side_effect=[missing_snapshot, created_snapshot]),
            mock.patch.object(helper, "live_release_claims", return_value={}),
        ):
            result = helper.find_owner(Path("/tmp/repoprompt-ce-mcp-test"), 123, Path("/tmp/RepoPrompt"))

        self.assertIsNone(result)
        self.assertEqual(validate_process.call_count, 2)

    @unittest.skipUnless(sys.platform == "darwin", "macOS libproc socket descriptor inspection")
    def test_packaged_socket_owner_helper_rejects_live_preflight_and_accepts_exact_owner(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        socket_directory = temp_dir / "repoprompt-ce-mcp"
        socket_directory.mkdir(mode=0o700)
        socket_path = socket_directory / "repoprompt-ce-7.sock"
        listener, accepted_connections = self.start_unix_listener(socket_path)
        expected_executable = self.socket_owner_process_path(listener.pid)
        wrong_pid = os.getpid()
        wrong_executable = self.socket_owner_process_path(wrong_pid)

        selftest = self.run_socket_owner_helper("selftest")
        preflight = self.run_socket_owner_helper("preflight", socket_directory)
        found = self.run_socket_owner_helper("find-owner", socket_directory, listener.pid, expected_executable)
        verified = self.run_socket_owner_helper("verify-owner", socket_path, listener.pid, expected_executable)
        wrong_owner = self.run_socket_owner_helper("verify-owner", socket_path, wrong_pid, wrong_executable)

        self.assertEqual(selftest.returncode, 0, selftest.stderr)
        self.assertNotEqual(preflight.returncode, 0)
        self.assertIn("pre-existing live release socket", preflight.stderr)
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(Path(found.stdout.strip()), socket_path)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertNotEqual(wrong_owner.returncode, 0)
        self.assertIn(str(listener.pid), wrong_owner.stderr)
        self.assertIn(f"not exclusively launched pid {wrong_pid}", wrong_owner.stderr)
        self.assertFalse(accepted_connections.exists(), "ownership inspection must not connect to the release socket")

    @unittest.skipUnless(sys.platform == "darwin", "macOS libproc socket descriptor inspection")
    def test_packaged_socket_owner_helper_allows_stale_and_rejects_wrong_or_replaced_owner(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        socket_directory = temp_dir / "repoprompt-ce-mcp"
        socket_directory.mkdir(mode=0o700)
        socket_path = socket_directory / "repoprompt-ce-7.sock"
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(os.fspath(socket_path))
        stale.close()
        accepted_stale = self.run_socket_owner_helper("preflight", socket_directory)
        self.assertEqual(accepted_stale.returncode, 0, accepted_stale.stderr)

        socket_path.unlink()
        first, first_accepted_connections = self.start_unix_listener(socket_path)
        first_executable = self.socket_owner_process_path(first.pid)

        socket_path.unlink()
        stale_replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale_replacement.bind(os.fspath(socket_path))
        stale_replacement.close()
        replaced_by_stale = self.run_socket_owner_helper("verify-owner", socket_path, first.pid, first_executable)
        self.assertNotEqual(replaced_by_stale.returncode, 0)
        self.assertIn("identity does not match", replaced_by_stale.stderr)
        self.assertFalse(first_accepted_connections.exists(), "stale-replacement inspection must not connect")

        socket_path.unlink()
        bound_replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        bound_replacement.bind(os.fspath(socket_path))
        try:
            replaced_by_bound = self.run_socket_owner_helper("verify-owner", socket_path, first.pid, first_executable)
        finally:
            bound_replacement.close()
        self.assertNotEqual(replaced_by_bound.returncode, 0)
        self.assertIn("identity does not match", replaced_by_bound.stderr)
        self.assertFalse(first_accepted_connections.exists(), "bound-replacement inspection must not connect")

        socket_path.unlink()
        second, second_accepted_connections = self.start_unix_listener(
            socket_path,
            claim_ownership_lock=False,
        )
        second_executable = self.socket_owner_process_path(second.pid)

        replaced = self.run_socket_owner_helper("verify-owner", socket_path, first.pid, first_executable)
        ambiguous_current = self.run_socket_owner_helper("verify-owner", socket_path, second.pid, second_executable)

        self.assertNotEqual(replaced.returncode, 0)
        self.assertIn("not exclusively launched pid", replaced.stderr)
        self.assertIn(str(first.pid), replaced.stderr)
        self.assertIn(str(second.pid), replaced.stderr)
        self.assertNotEqual(ambiguous_current.returncode, 0)
        self.assertIn("not exclusively launched pid", ambiguous_current.stderr)
        self.assertFalse(first_accepted_connections.exists(), "replaced-owner inspection must not connect")
        self.assertFalse(second_accepted_connections.exists(), "current-owner inspection must not connect")

        first.terminate()
        first.wait(timeout=5)
        unlocked_current = self.run_socket_owner_helper("verify-owner", socket_path, second.pid, second_executable)
        self.assertNotEqual(unlocked_current.returncode, 0)
        self.assertIn("ownership lock is not held", unlocked_current.stderr)
        self.assertFalse(second_accepted_connections.exists(), "unlocked-owner verification must not connect")

        socket_path.unlink()
        socket_path.write_text("not a socket\n", encoding="utf-8")
        nonsocket = self.run_socket_owner_helper("preflight", socket_directory)
        self.assertNotEqual(nonsocket.returncode, 0)
        self.assertIn("not a UNIX socket", nonsocket.stderr)

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
        self.assertIn("checksum_manifests=(signed-release/*SHA256SUMS)", signed_smoke)
        self.assertIn("artifact_manifests=(signed-release/*-artifact-manifest.json)", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum manifest", signed_smoke)
        self.assertIn("Expected exactly one signed ZIP checksum entry", signed_smoke)
        self.assertIn("shasum -a 256 -c", signed_smoke)
        self.assertLess(signed_smoke.index("shasum -a 256 -c"), signed_smoke.index("ditto -x -k"))
        self.assertIn("validate_embedded_mcp_helper_layout.sh", signed_smoke)
        self.assertIn("validate_app_architectures.sh", signed_smoke)
        self.assertIn("write_app_artifact_manifest.py verify", signed_smoke)
        self.assertIn("smoke_packaged_mcp_roundtrip.sh", signed_smoke)
        self.assertIn('"extracted/RepoPrompt CE.app"', signed_smoke)
        self.assertIn("env -i", signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', signed_smoke)
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", signed_smoke)
        self.assertIn('HOME="$HOME"', signed_smoke)
        self.assertIn('TMPDIR="$RUNNER_TEMP"', signed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"', signed_smoke)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            signed_smoke,
        )

        reviewed_smoke = promote_workflow.split("\n  smoke-reviewed-helper:", 1)[1].split("\n  promote:", 1)[0]
        self.assertNotIn("environment: release", reviewed_smoke)
        self.assertIn("contents: write", reviewed_smoke)
        self.assertIn("GH_TOKEN: ${{ github.token }}", reviewed_smoke)
        self.assertIn("reviewed_checksums_sha256", reviewed_smoke)
        self.assertIn("validate_embedded_mcp_helper_layout.sh", reviewed_smoke)
        self.assertIn("validate_app_architectures.sh", reviewed_smoke)
        self.assertIn("write_app_artifact_manifest.py verify", reviewed_smoke)
        self.assertIn("smoke_packaged_mcp_roundtrip.sh", reviewed_smoke)
        self.assertIn('"extracted/RepoPrompt CE.app"', reviewed_smoke)
        self.assertIn("env -i", reviewed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', reviewed_smoke)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', reviewed_smoke)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"',
            reviewed_smoke,
        )
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            reviewed_smoke,
        )
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

    def test_official_release_stage_and_publish_require_sentry_linking(self) -> None:
        env = os.environ.copy()
        env["REPOPROMPT_ENABLE_SENTRY"] = "0"
        for mode, phase in (("stage-publish", "staging"), ("publish-staged", "publishing")):
            with self.subTest(mode=mode):
                result = subprocess.run(
                    [str(SCRIPT_DIR / "release.sh"), mode],
                    env=env,
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    f"Official release {phase} requires REPOPROMPT_ENABLE_SENTRY=1",
                    result.stderr,
                )

    def test_shared_release_sentry_symbol_policy_requires_copies_and_uploads(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        policy = SCRIPT_DIR / "release_sentry_symbols.sh"
        uploader = SCRIPT_DIR / "upload_sentry_debug_symbols.sh"
        symbols = temp_dir / "symbols"
        dwarf = symbols / "RepoPrompt.dSYM" / "Contents" / "Resources" / "DWARF" / "RepoPrompt"
        dwarf.parent.mkdir(parents=True)
        dwarf.write_text("fixture-debug-symbols", encoding="utf-8")
        helper_dwarf = symbols / "repoprompt-mcp.dSYM" / "Contents" / "Resources" / "DWARF" / "repoprompt-mcp"
        helper_dwarf.parent.mkdir(parents=True)
        helper_dwarf.write_text("fixture-helper-debug-symbols", encoding="utf-8")
        staged_symbols = temp_dir / "stage" / ".build" / "sentry-symbols" / "release"
        token = "shared-policy-secret-output-marker"
        token_file = temp_dir / "sentry-token"
        token_file.write_text(token, encoding="utf-8")
        token_file.chmod(0o600)
        argv_capture = temp_dir / "sentry-argv.txt"
        token_capture = temp_dir / "sentry-token-capture.txt"
        fake_cli = temp_dir / "sentry-cli"
        fake_cli.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$ARGV_CAPTURE"
printf '%s' "${SENTRY_AUTH_TOKEN:-}" > "$TOKEN_CAPTURE"
""",
            encoding="utf-8",
        )
        fake_cli.chmod(0o755)

        env = os.environ.copy()
        env.pop("SENTRY_AUTH_TOKEN", None)
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "REPOPROMPT_ENABLE_SENTRY": "1",
                "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE": str(token_file),
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "ARGV_CAPTURE": str(argv_capture),
                "TOKEN_CAPTURE": str(token_capture),
            }
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; stage_release_sentry_symbols "$2" "$3" "$5" "$6" "$7" "$8"; '
                'upload_release_sentry_symbols "$2" "$4" "$5" "$6" "$7" "$8"',
                "release-sentry-symbol-policy-test",
                str(policy),
                str(symbols),
                str(staged_symbols),
                str(uploader),
                "RepoPrompt.dSYM",
                "RepoPrompt",
                "repoprompt-mcp.dSYM",
                "repoprompt-mcp",
            ],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (staged_symbols / "RepoPrompt.dSYM" / "Contents" / "Resources" / "DWARF" / "RepoPrompt").read_text(
                encoding="utf-8"
            ),
            "fixture-debug-symbols",
        )
        self.assertEqual(
            (
                staged_symbols
                / "repoprompt-mcp.dSYM"
                / "Contents"
                / "Resources"
                / "DWARF"
                / "repoprompt-mcp"
            ).read_text(encoding="utf-8"),
            "fixture-helper-debug-symbols",
        )
        self.assertEqual(token_capture.read_text(encoding="utf-8"), token)
        self.assertEqual(
            argv_capture.read_text(encoding="utf-8").splitlines(),
            [
                "debug-files",
                "upload",
                "--org",
                "fixture-org",
                "--project",
                "fixture-project",
                str(symbols),
            ],
        )
        self.assertNotIn(token, result.stdout + result.stderr)

        app_bundle = temp_dir / "RepoPrompt.app"
        app_macos = app_bundle / "Contents" / "MacOS"
        app_macos.mkdir(parents=True)
        (app_macos / "RepoPrompt").write_text("fixture-app-executable", encoding="utf-8")
        (app_macos / "repoprompt-mcp").write_text("fixture-helper-executable", encoding="utf-8")
        fake_dwarfdump = temp_dir / "dwarfdump"
        fake_dwarfdump.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--uuid" ]]
path="$2"
[[ -s "$path" ]] || exit 9
if [[ "${UUID_MODE:-match}" == "malformed" ]]; then
    printf 'unexpected uuid output\\n'
    exit 0
fi
if [[ "$path" == *repoprompt-mcp* ]]; then
    first_uuid="33333333-3333-3333-3333-333333333333"
    second_uuid="44444444-4444-4444-4444-444444444444"
    if [[ "${UUID_MODE:-match}" == "mismatch" && "$path" == *.dSYM/* ]]; then
        first_uuid="55555555-5555-5555-5555-555555555555"
    fi
else
    first_uuid="11111111-1111-1111-1111-111111111111"
    second_uuid="22222222-2222-2222-2222-222222222222"
fi
printf 'UUID: %s (arm64) %s\\n' "$first_uuid" "$path"
printf 'UUID: %s (x86_64) %s\\n' "$second_uuid" "$path"
""",
            encoding="utf-8",
        )
        fake_dwarfdump.chmod(0o755)
        uuid_env = env | {"REPOPROMPT_DWARFDUMP_BIN": str(fake_dwarfdump)}
        uuid_command = (
            'source "$1"; verify_release_sentry_symbol_uuids_before_signing '
            '"$2" "$3" "$4" "$5" "$6" "$7"'
        )
        uuid_args = [
            "bash",
            "-c",
            uuid_command,
            "release-sentry-symbol-uuid-test",
            str(policy),
            str(symbols),
            str(app_bundle),
            "RepoPrompt.dSYM",
            "RepoPrompt",
            "repoprompt-mcp.dSYM",
            "repoprompt-mcp",
        ]

        uuid_result = subprocess.run(uuid_args, env=uuid_env, text=True, capture_output=True)
        self.assertEqual(uuid_result.returncode, 0, uuid_result.stderr)
        self.assertNotIn(token, uuid_result.stdout + uuid_result.stderr)

        empty_symbols = temp_dir / "empty-symbols"
        shutil.copytree(symbols, empty_symbols)
        (
            empty_symbols
            / "repoprompt-mcp.dSYM"
            / "Contents"
            / "Resources"
            / "DWARF"
            / "repoprompt-mcp"
        ).write_bytes(b"")
        empty_args = list(uuid_args)
        empty_args[5] = str(empty_symbols)
        empty_result = subprocess.run(empty_args, env=uuid_env, text=True, capture_output=True)
        self.assertNotEqual(empty_result.returncode, 0)
        self.assertIn("Unable to read Mach-O UUIDs", empty_result.stderr)
        self.assertNotIn(token, empty_result.stdout + empty_result.stderr)

        mismatch_result = subprocess.run(
            uuid_args,
            env=uuid_env | {"UUID_MODE": "mismatch"},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(mismatch_result.returncode, 0)
        self.assertIn("UUIDs do not match staged executable", mismatch_result.stderr)
        self.assertNotIn(token, mismatch_result.stdout + mismatch_result.stderr)

        malformed_result = subprocess.run(
            uuid_args,
            env=uuid_env | {"UUID_MODE": "malformed"},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(malformed_result.returncode, 0)
        self.assertIn("Malformed Mach-O UUID output", malformed_result.stderr)
        self.assertNotIn(token, malformed_result.stdout + malformed_result.stderr)

        nested_symlink = symbols / "RepoPrompt.dSYM" / "Contents" / "linked-debug-file"
        nested_symlink.symlink_to(dwarf)
        symlink_result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; require_release_sentry_symbols_when_enabled "$2" "$3" "$4" "$5" "$6"',
                "release-sentry-symbol-policy-symlink-test",
                str(policy),
                str(symbols),
                "RepoPrompt.dSYM",
                "RepoPrompt",
                "repoprompt-mcp.dSYM",
                "repoprompt-mcp",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(symlink_result.returncode, 0)
        self.assertIn("must not contain symlinks", symlink_result.stderr)
        self.assertNotIn(token, symlink_result.stdout + symlink_result.stderr)
        nested_symlink.unlink()

        missing = temp_dir / "missing-symbols"
        missing_result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; require_release_sentry_symbols_when_enabled "$2" "$3" "$4" "$5" "$6"',
                "release-sentry-symbol-policy-missing-test",
                str(policy),
                str(missing),
                "RepoPrompt.dSYM",
                "RepoPrompt",
                "repoprompt-mcp.dSYM",
                "repoprompt-mcp",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing_result.returncode, 0)
        self.assertIn("did not produce a real debug-symbol directory", missing_result.stderr)
        self.assertNotIn(token, missing_result.stdout + missing_result.stderr)

        partial_symbols = temp_dir / "partial-symbols"
        (partial_symbols / "RepoPrompt.dSYM").mkdir(parents=True)
        partial_result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; require_release_sentry_symbols_when_enabled "$2" "$3" "$4" "$5" "$6"',
                "release-sentry-symbol-policy-partial-test",
                str(policy),
                str(partial_symbols),
                "RepoPrompt.dSYM",
                "RepoPrompt",
                "repoprompt-mcp.dSYM",
                "repoprompt-mcp",
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(partial_result.returncode, 0)
        self.assertIn("missing required dSYM payload", partial_result.stderr)
        self.assertNotIn(token, partial_result.stdout + partial_result.stderr)

        disabled_destination = temp_dir / "disabled-stage"
        disabled_env = env | {"REPOPROMPT_ENABLE_SENTRY": "0"}
        disabled_result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; stage_release_sentry_symbols "$2" "$3" "$5" "$6" "$7" "$8"; '
                'upload_release_sentry_symbols "$2" "$4" "$5" "$6" "$7" "$8"',
                "release-sentry-symbol-policy-disabled-test",
                str(policy),
                str(missing),
                str(disabled_destination),
                str(temp_dir / "missing-uploader"),
                "RepoPrompt.dSYM",
                "RepoPrompt",
                "repoprompt-mcp.dSYM",
                "repoprompt-mcp",
            ],
            env=disabled_env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(disabled_result.returncode, 0, disabled_result.stderr)
        self.assertFalse(disabled_destination.exists())
        self.assertNotIn(token, disabled_result.stdout + disabled_result.stderr)

    def test_sentry_symbol_upload_helper_uses_token_file_without_logging_secret(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        symbols = temp_dir / "symbols"
        symbols.mkdir()
        (symbols / "RepoPrompt.dSYM").mkdir()
        ambient_token = "sntrys_wrong_ambient_secret_token"
        token = "sntrys_fixture_secret_token"
        token_file = temp_dir / "sentry-token"
        token_file.write_text(token + "\n", encoding="utf-8")
        argv_capture = temp_dir / "argv.txt"
        token_capture = temp_dir / "token.txt"
        fake_cli = temp_dir / "sentry-cli"
        fake_cli.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ARGV_CAPTURE"
printf '%s' "${SENTRY_AUTH_TOKEN:-}" > "$TOKEN_CAPTURE"
""",
            encoding="utf-8",
        )
        fake_cli.chmod(0o755)
        env = os.environ.copy()
        env["SENTRY_AUTH_TOKEN"] = ambient_token
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE": str(token_file),
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "ARGV_CAPTURE": str(argv_capture),
                "TOKEN_CAPTURE": str(token_capture),
            }
        )

        result = subprocess.run(
            [str(SCRIPT_DIR / "upload_sentry_debug_symbols.sh"), str(symbols)],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(token, result.stdout)
        self.assertNotIn(token, result.stderr)
        argv = argv_capture.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            argv,
            [
                "debug-files",
                "upload",
                "--org",
                "fixture-org",
                "--project",
                "fixture-project",
                str(symbols),
            ],
        )
        self.assertNotIn("--include-sources", argv)
        self.assertNotIn(token, "\n".join(argv))
        self.assertEqual(token_capture.read_text(encoding="utf-8"), token)

        empty_token_file = temp_dir / "empty-sentry-token"
        empty_token_file.write_text(" \t\r\n", encoding="utf-8")
        argv_capture.unlink()
        token_capture.unlink()
        for token_file_variable in (
            "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE",
            "SENTRY_AUTH_TOKEN_FILE",
        ):
            with self.subTest(token_file_variable=token_file_variable):
                explicit_empty_env = env.copy()
                explicit_empty_env.pop("REPOPROMPT_SENTRY_AUTH_TOKEN_FILE", None)
                explicit_empty_env.pop("SENTRY_AUTH_TOKEN_FILE", None)
                explicit_empty_env[token_file_variable] = str(empty_token_file)
                empty_result = subprocess.run(
                    [str(SCRIPT_DIR / "upload_sentry_debug_symbols.sh"), str(symbols)],
                    env=explicit_empty_env,
                    text=True,
                    capture_output=True,
                )

                self.assertNotEqual(empty_result.returncode, 0)
                self.assertEqual(empty_result.stdout, "")
                self.assertEqual(
                    empty_result.stderr,
                    "ERROR: Explicit Sentry auth token file contains no token.\n",
                )
                self.assertFalse(argv_capture.exists())
                self.assertFalse(token_capture.exists())

    def run_sentry_prepare_fixture(
        self,
        lookup_mode: str,
        attempts: int = 1,
        action: str = "full",
        env_overrides: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[dict[str, object]]]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        call_log = temp_dir / "sentry-api-calls.jsonl"
        counter_file = temp_dir / "sentry-api-counters.json"
        release_state = temp_dir / "sentry-release.json"
        api_tmp = temp_dir / "api-tmp"
        api_tmp.mkdir()
        fake_curl = temp_dir / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env python3
import json
import os
import stat
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

args = sys.argv[1:]

def option(name):
    return args[args.index(name) + 1]

if option("--connect-timeout") != os.environ.get("EXPECTED_CONNECT_TIMEOUT", "10"):
    raise SystemExit(88)
if option("--max-time") != os.environ.get("EXPECTED_REQUEST_TIMEOUT", "60"):
    raise SystemExit(89)
if "--retry" in args or "--retry-all-errors" in args:
    raise SystemExit(87)

config = Path(option("--config"))
if stat.S_IMODE(config.stat().st_mode) != 0o600:
    raise SystemExit(90)
if config.read_text(encoding="utf-8") != 'header = "Authorization: Bearer fixture-token"\\n':
    raise SystemExit(91)
token_file = Path(os.environ["REPOPROMPT_SENTRY_AUTH_TOKEN_FILE"])
if stat.S_IMODE(token_file.stat().st_mode) != 0o600:
    raise SystemExit(92)
if token_file.read_text(encoding="utf-8") != "fixture-token":
    raise SystemExit(93)
if "SENTRY_AUTH_TOKEN" in os.environ:
    raise SystemExit(94)

scenario = os.environ["SENTRY_LOOKUP_MODE"]
if scenario == "transport":
    raise SystemExit(7)

method = option("--request")
output = Path(option("--output"))
url = args[-1]
body = None
if "--data-binary" in args:
    body_arg = option("--data-binary")
    if not body_arg.startswith("@"):
        raise SystemExit(95)
    body = json.loads(Path(body_arg[1:]).read_text(encoding="utf-8"))

with Path(os.environ["SENTRY_CALL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "method": method,
        "url": url,
        "body": body,
        "connect_timeout": option("--connect-timeout"),
        "max_time": option("--max-time"),
    }) + "\\n")

state_path = Path(os.environ["SENTRY_RELEASE_STATE"])
counter_path = Path(os.environ["SENTRY_COUNTER_FILE"])
parsed = urlparse(url)
is_preflight = parsed.query != ""
is_collection = parsed.path.endswith("/releases/")
version = unquote(parsed.path.rstrip("/").split("/")[-1])

def bump(key):
    counters = json.loads(counter_path.read_text(encoding="utf-8")) if counter_path.exists() else {}
    counters[key] = counters.get(key, 0) + 1
    counter_path.write_text(json.dumps(counters), encoding="utf-8")
    return counters[key]

def release_payload():
    state = json.loads(state_path.read_text(encoding="utf-8"))
    return {
        "version": state["version"],
        "projects": [{"slug": "fixture-project"}],
        "dateReleased": state.get("dateReleased"),
    }

if is_preflight:
    if scenario == "unauthorized":
        status, response = 401, {"detail": "SECRET_BODY_MARKER"}
    elif scenario == "denied":
        status, response = 403, {"detail": "SECRET_BODY_MARKER"}
    elif scenario == "malformed":
        status, response = 200, {}
    else:
        status, response = 200, []
elif method == "GET" and not is_collection:
    if scenario in {"existing-finalized", "existing-unfinalized"} and not state_path.exists():
        date_released = "2026-01-01T00:00:00Z" if scenario == "existing-finalized" else None
        state_path.write_text(json.dumps({"version": version, "dateReleased": date_released}), encoding="utf-8")
    if scenario == "unknown-create" and counter_path.exists() and json.loads(counter_path.read_text(encoding="utf-8")).get("create", 0) > 0:
        raise SystemExit(28)
    if scenario == "http-create-unknown" and counter_path.exists() and json.loads(counter_path.read_text(encoding="utf-8")).get("create", 0) > 0:
        status, response = 503, {"detail": "ambiguous create observation"}
    elif state_path.exists():
        status, response = 200, release_payload()
    else:
        status, response = 404, {"detail": "SECRET_BODY_MARKER"}
elif method == "POST" and is_collection:
    create_attempt = bump("create")
    if scenario == "ambiguous-create-lost" and create_attempt == 1:
        raise SystemExit(28)
    if scenario == "unknown-create":
        raise SystemExit(28)
    if scenario in {"http-create-lost", "http-create-unknown"} and create_attempt == 1:
        status, response = 503, {"detail": "ambiguous create"}
    else:
        state_path.write_text(
            json.dumps({"version": body["version"], "dateReleased": None}),
            encoding="utf-8",
        )
        if scenario == "ambiguous-create-landed" and create_attempt == 1:
            raise SystemExit(28)
        if scenario == "http-create-landed" and create_attempt == 1:
            status, response = 503, {"detail": "ambiguous create"}
        else:
            status, response = 201, release_payload()
elif method == "PUT" and not is_collection and state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8"))
    if "dateReleased" in body:
        finalize_attempt = bump("finalize")
        if scenario == "ambiguous-finalize-lost" and finalize_attempt == 1:
            raise SystemExit(28)
        if scenario == "http-finalize-lost" and finalize_attempt == 1:
            status, response = 503, {"detail": "ambiguous finalize"}
        else:
            state["dateReleased"] = body["dateReleased"]
            state_path.write_text(json.dumps(state), encoding="utf-8")
            if scenario == "ambiguous-finalize-landed" and finalize_attempt == 1:
                raise SystemExit(28)
            if scenario == "http-finalize-landed" and finalize_attempt == 1:
                status, response = 503, {"detail": "ambiguous finalize"}
    elif "refs" in body:
        refs_attempt = bump("refs")
        if scenario == "ambiguous-refs" and refs_attempt == 1:
            raise SystemExit(28)
        if scenario == "http-refs" and refs_attempt == 1:
            status, response = 503, {"detail": "ambiguous refs"}
    if "status" not in locals() or status != 503:
        status, response = 200, release_payload()
else:
    status, response = 500, {"detail": "unexpected fixture request", "version": version}

output.write_text(json.dumps(response), encoding="utf-8")
sys.stdout.write(str(status))
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "REPOPROMPT_ENABLE_SENTRY": "1",
                "SENTRY_AUTH_TOKEN": "fixture-token",
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "REPOPROMPT_SENTRY_API_BASE_URL": "https://sentry.example/api/0",
                "SOURCE_GITHUB_REPOSITORY": "fixture/repository",
                "RELEASE_COMMIT": "0123456789abcdef",
                "SENTRY_LOOKUP_MODE": lookup_mode,
                "SENTRY_CALL_LOG": str(call_log),
                "SENTRY_COUNTER_FILE": str(counter_file),
                "SENTRY_RELEASE_STATE": str(release_state),
                "FIXTURE_TMP_DIR": str(api_tmp),
                "ATTEMPTS": str(attempts),
                "EXPECTED_CONNECT_TIMEOUT": "10",
                "EXPECTED_REQUEST_TIMEOUT": "60",
            }
        )
        if env_overrides:
            env.update(env_overrides)
        if action in {"recover", "recover-disabled"}:
            metadata = dict(
                line.split("=", 1)
                for line in (SCRIPT_DIR.parent / "version.env").read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#")
            )
            env["RELEASE_TAG"] = f'v{metadata["MARKETING_VERSION"].strip(chr(34))}'
            if action == "recover-disabled":
                env.pop("REPOPROMPT_ENABLE_SENTRY", None)
            shell_action = "recover_sentry_finalization"
        else:
            shell_action = (
                "preflight_sentry_release_access; "
                "for ((attempt = 0; attempt < ATTEMPTS; attempt++)); do prepare_sentry_release; done; "
                "finalize_sentry_release; finalize_sentry_release"
            )
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; TMP_DIR="$FIXTURE_TMP_DIR"; ' + shell_action,
                "sentry-release-test",
                str(SCRIPT_DIR / "release.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        calls = (
            [json.loads(line) for line in call_log.read_text(encoding="utf-8").splitlines()]
            if call_log.exists()
            else []
        )
        return result, calls

    def test_sentry_release_prepare_creates_only_for_not_found_and_is_retry_safe(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("not-found-once", attempts=2)

        self.assertEqual(result.returncode, 0, result.stderr)
        collection_posts = [call for call in calls if call["method"] == "POST"]
        refs_updates = [
            call
            for call in calls
            if call["method"] == "PUT" and "refs" in (call["body"] or {})
        ]
        finalizations = [
            call
            for call in calls
            if call["method"] == "PUT" and "dateReleased" in (call["body"] or {})
        ]
        self.assertEqual(len(collection_posts), 1)
        self.assertEqual(len(refs_updates), 2)
        self.assertEqual(len(finalizations), 1)
        self.assertEqual(
            collection_posts[0]["body"]["refs"],
            [{"repository": "fixture/repository", "commit": "0123456789abcdef"}],
        )
        self.assertTrue(all("%40" in call["url"] and "%2B" in call["url"] for call in refs_updates))
        self.assertIn("already finalized", result.stdout)
        self.assertNotIn("fixture-token", result.stdout + result.stderr + json.dumps(calls))
        self.assertNotIn("SECRET_BODY_MARKER", result.stdout + result.stderr)

    def test_sentry_release_prepare_does_not_create_after_lookup_failure(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("denied")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["method"], "GET")
        self.assertFalse(any(call["method"] in {"POST", "PUT"} for call in calls))
        self.assertIn("org:ci access", result.stderr)
        self.assertNotIn("fixture-token", result.stdout + result.stderr)
        self.assertNotIn("SECRET_BODY_MARKER", result.stdout + result.stderr)

    def test_sentry_release_requests_are_bounded_without_curl_mutation_retries(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("not-found-once")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(len(calls), 0)
        self.assertTrue(all(call["connect_timeout"] == "10" for call in calls))
        self.assertTrue(all(call["max_time"] == "60" for call in calls))

    def test_sentry_release_recovers_ambiguous_create_outcomes_by_observation(self) -> None:
        for scenario, expected_posts in (
            ("ambiguous-create-landed", 1),
            ("ambiguous-create-lost", 2),
            ("http-create-landed", 1),
            ("http-create-lost", 2),
        ):
            with self.subTest(scenario=scenario):
                result, calls = self.run_sentry_prepare_fixture(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len([call for call in calls if call["method"] == "POST"]), expected_posts)
                first_post = next(index for index, call in enumerate(calls) if call["method"] == "POST")
                self.assertEqual(calls[first_post + 1]["method"], "GET")

    def test_sentry_release_recovers_ambiguous_finalize_outcomes_by_observation(self) -> None:
        for scenario, expected_finalizations in (
            ("ambiguous-finalize-landed", 1),
            ("ambiguous-finalize-lost", 2),
            ("http-finalize-landed", 1),
            ("http-finalize-lost", 2),
        ):
            with self.subTest(scenario=scenario):
                result, calls = self.run_sentry_prepare_fixture(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                finalizations = [
                    call
                    for call in calls
                    if call["method"] == "PUT" and "dateReleased" in (call["body"] or {})
                ]
                self.assertEqual(len(finalizations), expected_finalizations)
                first_finalize = calls.index(finalizations[0])
                self.assertEqual(calls[first_finalize + 1]["method"], "GET")

    def test_sentry_release_retries_identical_idempotent_refs_after_transport_failure(self) -> None:
        for scenario in ("ambiguous-refs", "http-refs"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_sentry_prepare_fixture(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                refs_updates = [
                    call
                    for call in calls
                    if call["method"] == "PUT" and "refs" in (call["body"] or {})
                ]
                self.assertEqual(len(refs_updates), 2)
                self.assertEqual(refs_updates[0]["body"], refs_updates[1]["body"])
                first_refs = calls.index(refs_updates[0])
                self.assertEqual(calls[first_refs + 1]["method"], "GET")

    def test_sentry_release_fails_loudly_when_ambiguous_create_cannot_be_reconciled(self) -> None:
        for scenario in ("unknown-create", "http-create-unknown"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_sentry_prepare_fixture(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len([call for call in calls if call["method"] == "POST"]), 1)
                first_post = next(index for index, call in enumerate(calls) if call["method"] == "POST")
                self.assertEqual(calls[first_post + 1]["method"], "GET")
                self.assertIn("Unable to reconcile Sentry release state", result.stderr)
                self.assertNotIn("fixture-token", result.stdout + result.stderr)

    def test_finalize_sentry_recovery_mode_accepts_an_existing_finalized_release(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("existing-finalized", action="recover")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call["method"] in {"POST", "PUT"} for call in calls))
        self.assertIn("already finalized", result.stdout)

    def test_finalize_sentry_recovery_mode_finalizes_an_existing_unfinalized_release(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("existing-unfinalized", action="recover")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call["method"] == "POST" for call in calls))
        finalizations = [
            call
            for call in calls
            if call["method"] == "PUT" and "dateReleased" in (call["body"] or {})
        ]
        self.assertEqual(len(finalizations), 1)

    def test_finalize_sentry_recovery_mode_requires_sentry_to_be_enabled(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("existing-unfinalized", action="recover-disabled")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("finalize-sentry requires REPOPROMPT_ENABLE_SENTRY=1", result.stderr)

    def test_sentry_timeout_configuration_rejects_unbounded_values_before_network(self) -> None:
        result, calls = self.run_sentry_prepare_fixture(
            "not-found-once",
            env_overrides={"REPOPROMPT_SENTRY_REQUEST_TIMEOUT_SECONDS": "301"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("must not exceed 300 seconds", result.stderr)

    def run_sentry_deploy_fixture(self, scenario: str) -> tuple[subprocess.CompletedProcess[str], list[dict[str, object]]]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        call_log = temp_dir / "calls.jsonl"
        counter = temp_dir / "counter"
        state = temp_dir / "state"
        fake_curl = temp_dir / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env python3
import json
import os
import stat
import sys
from pathlib import Path

args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1]

if option("--connect-timeout") != "10" or option("--max-time") != "60":
    raise SystemExit(90)
if "--retry" in args or "--retry-all-errors" in args:
    raise SystemExit(91)
config = Path(option("--config"))
if stat.S_IMODE(config.stat().st_mode) != 0o600:
    raise SystemExit(93)
if config.read_text(encoding="utf-8") != 'header = "Authorization: Bearer fixture-token"\\n':
    raise SystemExit(94)
if "SENTRY_AUTH_TOKEN" in os.environ:
    raise SystemExit(95)
method = option("--request")
output = Path(option("--output"))
body = None
if "--data-binary" in args:
    body = json.loads(Path(option("--data-binary")[1:]).read_text(encoding="utf-8"))
with Path(os.environ["CALL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({"method": method, "body": body}) + "\\n")

state = Path(os.environ["DEPLOY_STATE"])
counter = Path(os.environ["DEPLOY_COUNTER"])
if method == "GET":
    if os.environ["SCENARIO"] == "http-unknown" and counter.exists():
        response = {"detail": "ambiguous deploy observation"}
        status = 503
    else:
        response = ([{"environment": "production", "name": "vfixture"}] if state.exists() else [])
        status = 200
elif method == "POST":
    attempt = int(counter.read_text(encoding="utf-8")) + 1 if counter.exists() else 1
    counter.write_text(str(attempt), encoding="utf-8")
    scenario = os.environ["SCENARIO"]
    if scenario == "lost" and attempt == 1:
        raise SystemExit(28)
    if scenario in {"http-lost", "http-unknown"} and attempt == 1:
        response = {"detail": "ambiguous deploy create"}
        status = 503
    else:
        state.write_text("landed", encoding="utf-8")
        if scenario == "landed" and attempt == 1:
            raise SystemExit(28)
        if scenario == "http-landed" and attempt == 1:
            response = {"detail": "ambiguous deploy create"}
            status = 503
        else:
            response = {"environment": "production", "name": "vfixture"}
            status = 201
else:
    raise SystemExit(92)
output.write_text(json.dumps(response), encoding="utf-8")
sys.stdout.write(str(status))
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        api_tmp = temp_dir / "api"
        api_tmp.mkdir()
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "SENTRY_AUTH_TOKEN": "fixture-token",
                "REPOPROMPT_SENTRY_ORG": "fixture-org",
                "REPOPROMPT_SENTRY_PROJECT": "fixture-project",
                "REPOPROMPT_SENTRY_DEPLOY_ENVIRONMENT": "production",
                "RELEASE_TAG": "vfixture",
                "FIXTURE_TMP_DIR": str(api_tmp),
                "CALL_LOG": str(call_log),
                "DEPLOY_STATE": str(state),
                "DEPLOY_COUNTER": str(counter),
                "SCENARIO": scenario,
            }
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; TMP_DIR="$FIXTURE_TMP_DIR"; preflight_sentry_deploy_access; record_verified_sentry_deploy_if_needed',
                "sentry-deploy-test",
                str(SCRIPT_DIR / "promote_release.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        calls = [json.loads(line) for line in call_log.read_text(encoding="utf-8").splitlines()]
        return result, calls

    def test_sentry_deploy_recovers_ambiguous_create_outcomes_without_curl_retry(self) -> None:
        for scenario, expected_posts in (
            ("landed", 1),
            ("lost", 2),
            ("http-landed", 1),
            ("http-lost", 2),
        ):
            with self.subTest(scenario=scenario):
                result, calls = self.run_sentry_deploy_fixture(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len([call for call in calls if call["method"] == "POST"]), expected_posts)
                first_post = next(index for index, call in enumerate(calls) if call["method"] == "POST")
                self.assertEqual(calls[first_post + 1]["method"], "GET")
                self.assertNotIn("fixture-token", result.stdout + result.stderr + json.dumps(calls))

    def test_sentry_deploy_fails_closed_when_http_ambiguity_cannot_be_reconciled(self) -> None:
        result, calls = self.run_sentry_deploy_fixture("http-unknown")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([call for call in calls if call["method"] == "POST"]), 1)
        first_post = next(index for index, call in enumerate(calls) if call["method"] == "POST")
        self.assertEqual(calls[first_post + 1]["method"], "GET")
        self.assertIn("Unable to reconcile Sentry deploy state", result.stderr)
        self.assertNotIn("fixture-token", result.stdout + result.stderr + json.dumps(calls))

    def test_promotion_anonymous_downloads_cap_each_attempt_to_remaining_budget(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        args_file = temp_dir / "args.jsonl"
        counter_file = temp_dir / "counter"
        fake_curl = temp_dir / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

with Path(os.environ["ARGS_FILE"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\\n")
counter = Path(os.environ["CURL_COUNTER"])
attempt = int(counter.read_text(encoding="utf-8")) + 1 if counter.exists() else 1
counter.write_text(str(attempt), encoding="utf-8")
print("https://failed.example/artifact" if attempt == 1 else "https://success.example/artifact", end="")
if attempt == 1:
    print("transient diagnostic", file=sys.stderr)
raise SystemExit(28 if attempt == 1 else 0)
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)
        fake_date = temp_dir / "date"
        fake_date.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path

values = Path(os.environ["DATE_VALUES"])
remaining = values.read_text(encoding="utf-8").splitlines()
print(remaining.pop(0))
values.write_text("\\n".join(remaining), encoding="utf-8")
""",
            encoding="utf-8",
        )
        fake_date.chmod(0o755)
        fake_sleep = temp_dir / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_sleep.chmod(0o755)
        date_values = temp_dir / "date-values"
        date_values.write_text("100\n100\n590\n595\n", encoding="utf-8")
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{temp_dir}:{env.get('PATH', '')}",
                "ARGS_FILE": str(args_file),
                "CURL_COUNTER": str(counter_file),
                "DATE_VALUES": str(date_values),
            }
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; curl_anonymous --write-out "%{url_effective}" https://example.invalid/artifact',
                "download-test",
                str(SCRIPT_DIR / "promote_release.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "https://success.example/artifact")
        self.assertNotIn("https://failed.example/artifact", result.stdout)
        self.assertIn("transient diagnostic", result.stderr)
        calls = [json.loads(line) for line in args_file.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(
            [args[args.index("--connect-timeout") + 1] for args in calls],
            ["10", "10"],
        )
        self.assertEqual([args[args.index("--max-time") + 1] for args in calls], ["120", "105"])
        self.assertTrue(all("--retry" not in args and "--retry-max-time" not in args for args in calls))

    def test_sentry_release_preflight_distinguishes_invalid_token_without_mutation(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("unauthorized")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertFalse(any(call["method"] in {"POST", "PUT"} for call in calls))
        self.assertIn("HTTP 401", result.stderr)
        self.assertIn("SENTRY_AUTH_TOKEN is current", result.stderr)
        self.assertNotIn("fixture-token", result.stdout + result.stderr)
        self.assertNotIn("SECRET_BODY_MARKER", result.stdout + result.stderr)

    def test_sentry_release_preflight_rejects_malformed_json_before_mutation(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("malformed")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertFalse(any(call["method"] in {"POST", "PUT"} for call in calls))
        self.assertIn("malformed JSON during access preflight", result.stderr)

    def test_sentry_release_preflight_reports_transport_deadline_failure_clearly(self) -> None:
        result, calls = self.run_sentry_prepare_fixture("transport")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("configured network deadline", result.stderr)
        self.assertNotIn("HTTP transport:", result.stderr)

    def test_sentry_symbol_flow_is_explicit_secret_safe_and_release_only_by_default(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        universal_builder = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        symbol_policy = (SCRIPT_DIR / "release_sentry_symbols.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        release_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        promote_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "release-promote.yml").read_text(encoding="utf-8")
        conductor = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")

        self.assertIn('SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/$CONF"', package_script)
        self.assertNotIn("REPOPROMPT_SENTRY_SYMBOLS_DIR", package_script)
        self.assertIn("SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)", package_script)
        self.assertIn('run xcrun dsymutil "$BUILD_DIR/$exe" -o "$SENTRY_SYMBOLS_DIR/$exe.dSYM"', package_script)
        self.assertIn('if truthy "${REPOPROMPT_UPLOAD_SENTRY_SYMBOLS:-}"; then', package_script)
        self.assertIn("REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires REPOPROMPT_ENABLE_SENTRY=1", package_script)
        self.assertIn("REPOPROMPT_UPLOAD_SENTRY_SYMBOLS requires SENTRY_AUTH_TOKEN or REPOPROMPT_SENTRY_AUTH_TOKEN_FILE", package_script)
        self.assertIn("SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)", universal_builder)

        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh"', release_script)
        self.assertIn('require_file "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"', release_script)
        self.assertIn('source "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"', release_script)
        self.assertIn("Official release staging requires REPOPROMPT_ENABLE_SENTRY=1", release_script)
        self.assertIn("Official release publishing requires REPOPROMPT_ENABLE_SENTRY=1", release_script)
        self.assertIn('SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"', release_script)
        self.assertIn("stage_release_sentry_symbols", release_script)
        self.assertIn("upload_release_sentry_symbols", release_script)
        self.assertIn('upload_required_sentry_symbols', release_script)
        self.assertIn("require_release_sentry_symbols_when_enabled()", symbol_policy)
        self.assertIn("stage_release_sentry_symbols()", symbol_policy)
        self.assertIn("verify_release_sentry_symbol_uuids_before_signing()", symbol_policy)
        self.assertIn("REPOPROMPT_DWARFDUMP_BIN", symbol_policy)
        self.assertIn("upload_release_sentry_symbols()", symbol_policy)
        self.assertNotIn("SENTRY_AUTH_TOKEN", symbol_policy)
        self.assertIn('SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"', release_script)
        self.assertIn('require_sentry_publish_configuration() {', release_script)
        self.assertIn('require_command sentry-cli', release_script)
        self.assertIn('preflight_sentry_release_access', release_script)
        self.assertIn('prepare_sentry_release', release_script)
        self.assertIn('sentry_api_request POST', release_script)
        self.assertIn('sentry_api_request PUT', release_script)
        self.assertIn("'{refs: [{repository: $repository, commit: $commit}]}'", release_script)
        self.assertIn('finalize_sentry_release', release_script)
        self.assertIn('finalize-sentry) recover_sentry_finalization', release_script)
        self.assertIn('Refusing to repeat publish-staged', release_script)
        self.assertIn("'{dateReleased: $date_released}'", release_script)
        self.assertNotIn('sentry-cli --org', release_script)
        self.assertNotIn('record_sentry_production_deploy', release_script)
        self.assertNotIn('releases deploys "$SENTRY_RELEASE_NAME" new', release_script)
        self.assertIn('token="$(tr -d', release_script)
        self.assertIn('REPOPROMPT_SENTRY_AUTH_TOKEN_FILE="$normalized_token_file"', release_script)
        self.assertIn('unset SENTRY_AUTH_TOKEN', release_script)

        self.assertIn('preflight_sentry_deploy_access', promote_script)
        self.assertIn('record_verified_sentry_deploy_if_needed', promote_script)
        self.assertIn("'$value | @uri'", promote_script)
        self.assertIn('sentry_api_request POST', promote_script)
        self.assertNotIn('sentry-cli', promote_script)
        sentry_request = promote_script.split("sentry_api_request() {", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("--retry", sentry_request)

        publish_staged = release_script.split("publish_staged_release() {", 1)[1].split("\n}\n\ncase", 1)[0]
        self.assertLess(
            publish_staged.index("preflight_sentry_release_access"),
            publish_staged.index("sign_staged_release.sh"),
        )
        self.assertLess(
            publish_staged.index("validate_staged_release.sh"),
            publish_staged.index("verify_release_sentry_symbol_uuids_before_signing"),
        )
        self.assertLess(
            publish_staged.index("verify_release_sentry_symbol_uuids_before_signing"),
            publish_staged.index("sign_staged_release.sh"),
        )
        self.assertLess(publish_staged.index("prepare_sentry_release"), publish_staged.index("upload_required_sentry_symbols"))
        self.assertLess(publish_staged.index("upload_required_sentry_symbols"), publish_staged.index("gh release view"))
        self.assertLess(publish_staged.index("gh release view"), publish_staged.index("gh release create"))
        self.assertLess(publish_staged.index("gh release create"), publish_staged.index("finalize_sentry_release"))

        promote_case = promote_script.split('    promote)\n', 1)[1].split('        ;;', 1)[0]
        self.assertLess(promote_case.index("preflight_sentry_deploy_access"), promote_case.index("publish_reviewed_release"))
        self.assertLess(promote_case.index("publish_reviewed_release"), promote_case.index("verify_anonymous_publish"))
        self.assertLess(promote_case.index("verify_anonymous_publish"), promote_case.index("record_verified_sentry_deploy_if_needed"))

        stage_job = release_workflow.split("\n  stage:", 1)[1].split("\n  publish:", 1)[0]
        publish_job = release_workflow.split("\n  publish:", 1)[1].split("\n  smoke-signed-helper:", 1)[0]
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', stage_job)
        self.assertNotIn("SENTRY_AUTH_TOKEN", stage_job)
        self.assertIn("Install Sentry CLI when symbol upload is configured", publish_job)
        self.assertIn("brew install getsentry/tools/sentry-cli", publish_job)
        self.assertIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", publish_job)
        self.assertLess(
            publish_job.index("Install Sentry CLI when symbol upload is configured"),
            publish_job.index("Sign, notarize, and create draft release"),
        )
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', publish_job)
        self.assertIn("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}", publish_job)
        self.assertIn("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}", publish_job)

        promote_job = promote_workflow.split("\n  promote:", 1)[1]
        self.assertIn("Prepare Sentry promotion token file", promote_job)
        self.assertIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", promote_job)
        self.assertIn("chmod 600", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}", promote_job)
        self.assertIn("REPOPROMPT_SENTRY_DEPLOY_ENVIRONMENT: production", promote_job)
        self.assertIn("Remove Sentry promotion token file", promote_job)
        self.assertNotIn("sentry-cli", promote_job)

        self.assertIn('"REPOPROMPT_ENABLE_SENTRY"', conductor)
        self.assertIn('"REPOPROMPT_UPLOAD_SENTRY_SYMBOLS"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_AUTH_TOKEN_FILE"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_ORG"', conductor)
        self.assertIn('"REPOPROMPT_SENTRY_PROJECT"', conductor)
        self.assertNotIn('"SENTRY_AUTH_TOKEN"', conductor)

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

    def test_staged_release_validator_accepts_keyboard_shortcuts_resources_layout(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK: staged release payload matches approved source", result.stdout)

    def test_tip_staged_release_carries_exact_rollout_authority(self) -> None:
        tip_release = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('cp "$ROLLOUT_DECLARATION" "$stage_root/tip-rollout.json"', tip_release)
        self.assertIn('cp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$stage_root/tip-release-context.json"', tip_release)
        self.assertIn('cp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE"', tip_release)
        self.assertIn("load_verified_tip_release_context", tip_release)
        self.assertIn("tip_release_context.py verify", tip_workflow)
        self.assertIn(
            "uses: ./trusted-control-plane/.github/actions/verify-tip-context",
            tip_workflow,
        )

        approved, staged, scripts = self.make_staged_release_fixture(tip_context=True)
        accepted = self.run_staged_validation(
            approved,
            staged,
            scripts,
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        staged_context = staged / "tip-release-context.json"
        staged_digest = staged / "tip-release-context.json.sha256"
        context_bytes = staged_context.read_bytes()
        digest_bytes = staged_digest.read_bytes()

        staged_context.unlink()
        missing_context = self.run_staged_validation(
            approved,
            staged,
            scripts,
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(missing_context.returncode, 0)
        self.assertIn("Missing regular staged Tip release context", missing_context.stderr)
        staged_context.write_bytes(context_bytes)

        changed_context = json.loads(context_bytes)
        changed_context["release"]["tag"] = "tip-coordinated-tamper"
        changed_bytes = (json.dumps(changed_context, indent=2, sort_keys=True) + "\n").encode()
        staged_context.write_bytes(changed_bytes)
        staged_digest.write_text(hashlib.sha256(changed_bytes).hexdigest() + "\n", encoding="ascii")
        coordinated_tamper = self.run_staged_validation(
            approved,
            staged,
            scripts,
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(coordinated_tamper.returncode, 0)
        self.assertIn("Staged Tip release context differs from the setup context", coordinated_tamper.stderr)
        staged_context.write_bytes(context_bytes)
        staged_digest.write_bytes(digest_bytes)

        version_path = staged / "version.env"
        version_bytes = version_path.read_bytes()
        version_path.write_text(
            version_path.read_text(encoding="utf-8").replace("BUILD_NUMBER=35.15.21", "BUILD_NUMBER=35.15.22"),
            encoding="utf-8",
        )
        version_drift = self.run_staged_validation(
            approved,
            staged,
            scripts,
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(version_drift.returncode, 0)
        self.assertIn("staged version.env does not match the verified Tip release context", version_drift.stderr)
        version_path.write_bytes(version_bytes)

        (staged / "tip-rollout.json").write_text("{}\n", encoding="utf-8")
        changed = self.run_staged_validation(
            approved,
            staged,
            scripts,
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("Staged Tip rollout declaration does not match approved source", changed.stderr)

    def test_staged_release_validator_rejects_requested_preparer_for_historical_template(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        template_path = approved / "AppBundle" / "Info.plist.template"
        historical_template = "\n".join(
            line
            for line in template_path.read_text(encoding="utf-8").splitlines()
            if "RepoPromptIdentityMigration" not in line
        )
        template_path.write_text(historical_template + "\n", encoding="utf-8")
        info_path = staged / ".build" / "release" / "RepoPrompt.app" / "Contents" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.pop("RepoPromptIdentityMigrationPhase")
        info.pop("RepoPromptIdentityMigrationAnchorRelativePath")
        info_path.write_bytes(plistlib.dumps(info))

        result = self.run_staged_validation(
            approved,
            staged,
            scripts,
            identity_migration_phase="legacy-preparer",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "staged identity migration phase mismatch: expected legacy-preparer, got disabled",
            result.stderr,
        )

    def test_public_app_validation_uses_approved_manifest_from_extracted_stage_layout(self) -> None:
        for script_name in ("release.sh", "main_tip_release.sh"):
            with self.subTest(script=script_name):
                approved, staged, scripts = self.make_staged_release_fixture()
                self.assertFalse((staged / "Vendor").exists())

                result, capture = self.run_public_app_validation(
                    approved,
                    staged,
                    scripts,
                    script_name,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                calls = capture.read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(calls), 1)
                self.assertIn(str(approved / "Vendor" / "Codex" / "manifest.json"), calls[0])
                self.assertNotIn(str(staged / "Vendor"), calls[0])

    def test_staged_release_validator_rejects_missing_approved_codex_manifest(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        (approved / "Vendor" / "Codex" / "manifest.json").unlink()

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing approved Codex manifest", result.stderr)

    def test_staged_release_validator_rejects_missing_embedded_codex_package_target(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        bundle = staged / ".build" / "release" / "RepoPrompt.app" / "Contents" / "Resources" / "BundledRuntimes" / "Codex"
        shutil.rmtree(bundle / "x86_64-apple-darwin")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing embedded Codex package targets", result.stderr)

    def test_staged_release_validator_rejects_keyboard_shortcuts_app_root_bundle(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        self.write_keyboard_shortcuts_bundle(app / "KeyboardShortcuts_KeyboardShortcuts.bundle")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected app bundle root entries", result.stderr)
        self.assertIn("KeyboardShortcuts_KeyboardShortcuts.bundle", result.stderr)

    def test_staged_release_validator_rejects_missing_keyboard_shortcuts_resources_bundle(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        shutil.rmtree(app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required SwiftPM resource bundle directory", result.stderr)
        self.assertIn("KeyboardShortcuts_KeyboardShortcuts.bundle", result.stderr)

    def test_resource_bundle_normalizer_rewrites_flat_keyboard_shortcuts_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "RepoPrompt.app"
            bundle = app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle"
            (bundle / "en.lproj").mkdir(parents=True)
            (bundle / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
            (bundle / "en.lproj" / "Localizable.strings").write_text('"record_shortcut" = "Record Shortcut";\n', encoding="utf-8")

            result = subprocess.run(
                [str(SCRIPT_DIR / "normalize_swiftpm_resource_bundles.sh"), str(app)],
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((bundle / "Contents" / "Info.plist").is_file())
            self.assertTrue((bundle / "Contents" / "Resources" / "en.lproj" / "Localizable.strings").is_file())
            self.assertFalse((bundle / "Info.plist").exists())
            self.assertFalse((bundle / "en.lproj").exists())

    def test_staged_release_validator_rejects_missing_keyboard_shortcuts_patch_marker(self) -> None:
        approved, staged, scripts = self.make_staged_release_fixture()
        app = staged / ".build" / "release" / "RepoPrompt.app"
        (app / "Contents" / "MacOS" / "RepoPrompt").write_text("unpatched fixture\n", encoding="utf-8")

        result = self.run_staged_validation(approved, staged, scripts)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing KeyboardShortcuts resource lookup patch marker", result.stderr)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", result.stderr)

    def test_keyboard_shortcuts_patch_helper_applies_and_is_idempotent(self) -> None:
        root, utilities = self.make_keyboard_shortcuts_patch_fixture()

        applied = self.run_keyboard_shortcuts_patch(root)
        applied_text = utilities.read_text(encoding="utf-8")
        skipped = self.run_keyboard_shortcuts_patch(root)

        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertIn("Applied KeyboardShortcuts resource lookup patch", applied.stdout)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", applied_text)
        self.assertIn("Bundle.main.resourceURL?.appendingPathComponent(bundleName)", applied_text)
        self.assertEqual(skipped.returncode, 0, skipped.stderr)
        self.assertIn("already applied", skipped.stdout)

    def test_keyboard_shortcuts_patch_helper_checks_pin_before_idempotent_skip(self) -> None:
        root, _ = self.make_keyboard_shortcuts_patch_fixture()
        applied = self.run_keyboard_shortcuts_patch(root)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.write_package_resolved(root, "2.3.0", revision="changed-revision")

        rejected = self.run_keyboard_shortcuts_patch(root)

        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("KeyboardShortcuts dependency version or revision changed", rejected.stderr)
        self.assertIn("changed-revision", rejected.stderr)
        self.assertNotIn("already applied", rejected.stdout)

    def test_keyboard_shortcuts_patch_helper_rejects_source_drift(self) -> None:
        root, _ = self.make_keyboard_shortcuts_patch_fixture(source='extension String {\n\tvar localized: String { self }\n}\n')

        result = self.run_keyboard_shortcuts_patch(root)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch no longer applies cleanly", result.stderr)

    def test_package_app_invokes_keyboard_shortcuts_patch_and_shared_swiftpm_bundle_validator(self) -> None:
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        universal_builder = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")
        patch_helper = (SCRIPT_DIR / "patch_keyboard_shortcuts_resource_lookup.sh").read_text(encoding="utf-8")
        staged_validator = (SCRIPT_DIR / "validate_staged_release.sh").read_text(encoding="utf-8")
        shared_validator = (SCRIPT_DIR / "validate_required_swiftpm_resource_bundles.sh").read_text(encoding="utf-8")

        dependency_patch = package_script.index("patch_keyboard_shortcuts_resource_lookup.sh")
        first_build = package_script.index('phase "Building $APP_NAME ($CONF, host-native)"')
        universal_dependency_patch = universal_builder.index("patch_keyboard_shortcuts_resource_lookup.sh")
        universal_first_build = universal_builder.index("swift build")
        broad_resources_copy = package_script.index('for bundle in "$BUILD_DIR"/*.bundle; do run cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"; done')
        resources_validation = package_script.index("validate_required_swiftpm_resource_bundles.sh")
        outer_app_sign = package_script.index('sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"')

        self.assertIn("validate_required_swiftpm_resource_bundles.sh", staged_validator)
        self.assertIn('required_bundles = ["KeyboardShortcuts_KeyboardShortcuts.bundle"]', shared_validator)
        self.assertIn("RepoPromptKeyboardShortcutsResourceLookupV1", shared_validator)
        self.assertNotIn("RepoPromptKeyboardShortcutsResourceLookupV1", package_script)
        self.assertIn('REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch"', universal_builder)
        self.assertIn('--scratch-path "$SWIFTPM_SCRATCH_PATH"', patch_helper)
        self.assertLess(dependency_patch, first_build)
        self.assertLess(universal_dependency_patch, universal_first_build)
        self.assertLess(broad_resources_copy, resources_validation)
        self.assertLess(resources_validation, outer_app_sign)

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
        self.assertIn("switch Self.startDecision(", sparkle_manager)
        self.assertIn("guard sparkleConfigurationValid, !updaterStarted else { return .ignore }", sparkle_manager)
        self.assertIn(
            "guard updaterStarted, sparkleConfigurationValid, userInitiatedObserverState.activeRequest == nil else {",
            sparkle_manager,
        )

    def test_ci_secret_scan_covers_introduced_commit_range_and_checked_out_tree(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn('gitleaks git --redact --log-opts="$range" .', workflow)
        self.assertIn("gitleaks dir --redact .", workflow)

    def _make_format_tools_test_environment(
        self,
        system_swiftformat_version: str,
    ) -> tuple[Path, dict[str, str], Path]:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        tools = root / "tools"
        tools.mkdir()
        managed = root / "managed"
        temp = root / "tmp"
        temp.mkdir()
        mismatched_invocations = root / "mismatched-swiftformat-invocations"

        fake_swiftformat = tools / "swiftformat"
        fake_swiftformat.write_text(
            f"""#!/usr/bin/env python3
import sys
from pathlib import Path

if sys.argv[1:] == ["--version"]:
    print({system_swiftformat_version!r})
    raise SystemExit(0)

Path({str(mismatched_invocations)!r}).write_text(" ".join(sys.argv[1:]), encoding="utf-8")
raise SystemExit(99)
""",
            encoding="utf-8",
        )
        fake_swiftformat.chmod(0o755)

        fake_swiftlint = tools / "swiftlint"
        fake_swiftlint.write_text(
            "#!/bin/sh\nif [ \"$1\" = version ] || [ \"$1\" = --version ]; then echo 0.65.0; fi\nexit 0\n",
            encoding="utf-8",
        )
        fake_swiftlint.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{tools}:/usr/bin:/bin",
                "REPOPROMPT_FORMAT_TOOLS_DIR": str(managed),
                "TMPDIR": str(temp),
            }
        )
        return root, env, mismatched_invocations

    def _install_fake_swiftformat_download_tools(
        self,
        root: Path,
        archive: Path,
        checksum: str,
    ) -> None:
        tools = root / "tools"
        fake_curl = tools / "curl"
        fake_curl.write_text(
            """#!/usr/bin/env python3
import os
import json
import shutil
import sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["FAKE_SWIFTFORMAT_CURL_ARGS"], "w", encoding="utf-8") as handle:
    json.dump(args, handle)
if "FAKE_SWIFTFORMAT_CURL_LOG" in os.environ:
    with open(os.environ["FAKE_SWIFTFORMAT_CURL_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\\n")
counter_path = os.environ.get("FAKE_SWIFTFORMAT_CURL_COUNTER")
if counter_path:
    counter = Path(counter_path)
    attempt = int(counter.read_text(encoding="utf-8")) + 1 if counter.exists() else 1
    counter.write_text(str(attempt), encoding="utf-8")
    if attempt <= int(os.environ.get("FAKE_SWIFTFORMAT_FAIL_ATTEMPTS", "0")):
        raise SystemExit(28)
output = args[args.index("--output") + 1]
shutil.copyfile(os.environ["FAKE_SWIFTFORMAT_ARCHIVE"], output)
""",
            encoding="utf-8",
        )
        fake_curl.chmod(0o755)

        fake_shasum = tools / "shasum"
        fake_shasum.write_text(
            f"#!/bin/sh\nprintf '%s  %s\\n' {checksum!r} \"$3\"\n",
            encoding="utf-8",
        )
        fake_shasum.chmod(0o755)
        archive.parent.mkdir(parents=True, exist_ok=True)

    def test_format_tool_resolver_accepts_only_authoritative_system_swiftformat(self) -> None:
        installer = SCRIPT_DIR / "install_format_tools.sh"

        exact_root, exact_env, _ = self._make_format_tools_test_environment("0.61.1")
        exact = subprocess.run(
            [str(installer), "resolve-swiftformat"],
            env=exact_env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(exact.returncode, 0, exact.stderr)
        self.assertEqual(Path(exact.stdout.strip()), exact_root / "tools" / "swiftformat")

        _, mismatch_env, mismatch_invocations = self._make_format_tools_test_environment("0.62.1")
        mismatch = subprocess.run(
            [str(installer), "resolve-swiftformat"],
            env=mismatch_env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("incompatible (0.62.1", mismatch.stderr)
        self.assertIn("SwiftFormat 0.61.1 is required", mismatch.stderr)
        self.assertFalse(mismatch_invocations.exists())

    def test_format_tool_install_verifies_and_resolves_managed_swiftformat(self) -> None:
        installer = SCRIPT_DIR / "install_format_tools.sh"
        root, env, mismatched_invocations = self._make_format_tools_test_environment("0.62.1")
        archive = root / "fixtures" / "swiftformat.zip"
        managed_swiftformat = root / "managed" / "swiftformat" / "0.61.1" / "swiftformat"
        pinned_checksum = "b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"

        archive.parent.mkdir(parents=True)
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr(
                "swiftformat",
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 0.61.1; exit 0; fi\nexit 0\n",
            )
        self._install_fake_swiftformat_download_tools(root, archive, pinned_checksum)
        env["FAKE_SWIFTFORMAT_ARCHIVE"] = str(archive)
        env["FAKE_SWIFTFORMAT_CURL_ARGS"] = str(root / "curl-args.json")

        installed = subprocess.run(
            [str(installer), "install"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertIn(f"Installed SwiftFormat 0.61.1 at {managed_swiftformat}", installed.stdout)
        self.assertTrue(os.access(managed_swiftformat, os.X_OK))
        self.assertFalse(mismatched_invocations.exists())
        curl_args = json.loads((root / "curl-args.json").read_text(encoding="utf-8"))
        self.assertEqual(curl_args[curl_args.index("--connect-timeout") + 1], "10")
        self.assertEqual(curl_args[curl_args.index("--max-time") + 1], "120")
        self.assertNotIn("--retry", curl_args)
        self.assertNotIn("--retry-max-time", curl_args)

        resolved = subprocess.run(
            [str(installer), "resolve-swiftformat"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertEqual(Path(resolved.stdout.strip()), managed_swiftformat)

    def test_format_tool_install_rejects_bad_swiftformat_checksum(self) -> None:
        installer = SCRIPT_DIR / "install_format_tools.sh"
        root, env, mismatched_invocations = self._make_format_tools_test_environment("0.62.1")
        archive = root / "fixtures" / "swiftformat.zip"
        managed_swiftformat = root / "managed" / "swiftformat" / "0.61.1" / "swiftformat"

        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"not-the-official-swiftformat-archive")
        self._install_fake_swiftformat_download_tools(root, archive, "0" * 64)
        env["FAKE_SWIFTFORMAT_ARCHIVE"] = str(archive)
        env["FAKE_SWIFTFORMAT_CURL_ARGS"] = str(root / "curl-args.json")

        result = subprocess.run(
            [str(installer), "install"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SwiftFormat archive checksum mismatch", result.stderr)
        self.assertFalse(managed_swiftformat.exists())
        self.assertFalse(mismatched_invocations.exists())

    def test_format_tool_install_rejects_unbounded_download_timeout_before_curl(self) -> None:
        installer = SCRIPT_DIR / "install_format_tools.sh"
        root, env, _ = self._make_format_tools_test_environment("0.62.1")
        archive = root / "fixtures" / "swiftformat.zip"
        self._install_fake_swiftformat_download_tools(root, archive, "0" * 64)
        curl_args = root / "curl-args.json"
        env.update(
            {
                "FAKE_SWIFTFORMAT_ARCHIVE": str(archive),
                "FAKE_SWIFTFORMAT_CURL_ARGS": str(curl_args),
                "REPOPROMPT_FORMAT_DOWNLOAD_TOTAL_TIMEOUT_SECONDS": "601",
            }
        )

        result = subprocess.run(
            [str(installer), "install"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not exceed 600 seconds", result.stderr)
        self.assertFalse(curl_args.exists())

    def test_format_tool_download_caps_each_attempt_to_remaining_budget(self) -> None:
        installer = SCRIPT_DIR / "install_format_tools.sh"
        root, env, _ = self._make_format_tools_test_environment("0.62.1")
        archive = root / "fixtures" / "swiftformat.zip"
        pinned_checksum = "b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
        archive.parent.mkdir(parents=True)
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr(
                "swiftformat",
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 0.61.1; exit 0; fi\nexit 0\n",
            )
        self._install_fake_swiftformat_download_tools(root, archive, pinned_checksum)
        date_values = root / "date-values"
        date_values.write_text("100\n100\n395\n", encoding="utf-8")
        fake_date = root / "tools" / "date"
        fake_date.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path

values = Path(os.environ["FAKE_SWIFTFORMAT_DATE_VALUES"])
remaining = values.read_text(encoding="utf-8").splitlines()
print(remaining.pop(0))
values.write_text("\\n".join(remaining), encoding="utf-8")
""",
            encoding="utf-8",
        )
        fake_date.chmod(0o755)
        curl_log = root / "curl-log.jsonl"
        env.update(
            {
                "FAKE_SWIFTFORMAT_ARCHIVE": str(archive),
                "FAKE_SWIFTFORMAT_CURL_ARGS": str(root / "curl-args.json"),
                "FAKE_SWIFTFORMAT_CURL_LOG": str(curl_log),
                "FAKE_SWIFTFORMAT_CURL_COUNTER": str(root / "curl-counter"),
                "FAKE_SWIFTFORMAT_FAIL_ATTEMPTS": "1",
                "FAKE_SWIFTFORMAT_DATE_VALUES": str(date_values),
            }
        )

        result = subprocess.run(
            [str(installer), "install"],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in curl_log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(
            [args[args.index("--connect-timeout") + 1] for args in calls],
            ["10", "5"],
        )
        self.assertEqual([args[args.index("--max-time") + 1] for args in calls], ["120", "5"])
        self.assertTrue(all("--retry" not in args and "--retry-max-time" not in args for args in calls))

    def test_swift_style_never_formats_with_mismatched_path_swiftformat(self) -> None:
        style_script = SCRIPT_DIR / "swift_style.sh"
        _, env, mismatched_invocations = self._make_format_tools_test_environment("0.62.1")

        result = subprocess.run(
            [str(style_script), "format-check"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SwiftFormat 0.61.1 is required", result.stderr)
        self.assertIn("make install-format-tools", result.stderr)
        self.assertFalse(mismatched_invocations.exists())

    def test_swift_style_lint_uses_config_discovery_without_script_input_overhead(self) -> None:
        root = SCRIPT_DIR.parent
        style_script = (SCRIPT_DIR / "swift_style.sh").read_text(encoding="utf-8")
        swiftlint_config = (root / ".swiftlint.yml").read_text(encoding="utf-8")
        lint_body = style_script.split("run_swiftlint(){", 1)[1].split("\n}", 1)[0]
        workflow = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        style_job = workflow.split("\n  style:", 1)[1].split("\n  build-and-test:", 1)[0]

        installer_step = "./Scripts/install_format_tools.sh install"
        lint_step = "run: make lint"
        self.assertIn(installer_step, style_job)
        self.assertIn(lint_step, style_job)
        self.assertLess(style_job.index(installer_step), style_job.index(lint_step))
        self.assertIn('local args=(lint --strict --config "$ROOT_DIR/.swiftlint.yml" --quiet --force-exclude)', lint_body)
        self.assertNotIn("SCRIPT_INPUT_FILE", lint_body)
        self.assertNotIn("--use-script-input-files", lint_body)

        style_paths_body = style_script.split("STYLE_PATHS=(", 1)[1].split("\n)", 1)[0]
        style_paths = [
            line.strip().strip('"')
            for line in style_paths_body.splitlines()
            if line.strip().startswith('"')
        ]
        for style_path in style_paths:
            self.assertIn(f"  - {style_path}", swiftlint_config)

        for excluded_path in (
            ".build",
            ".swiftpm",
            "build",
            "Carthage",
            "DerivedData",
            "Generated",
            "Pods",
            "Vendor",
            "Packages/RepoPromptAgentProviders/.build",
            "Sources/CSwiftPCRE2",
            "Sources/RepoPromptC",
            "Sources/RepoPrompt/ThirdParty/SwiftPCRE2",
            "Sources/RepoPromptShared/Workflows/WorkflowPromptSharedFragments.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Build.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+DeepPlan.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Investigate.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Optimize.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+OracleExport.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Orchestrate.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Refactor.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Reminder.swift",
            "Sources/RepoPromptShared/Workflows/WorkflowPrompt+Review.swift",
        ):
            self.assertIn(f"  - {excluded_path}", swiftlint_config)

    def test_publish_staged_validates_before_creating_dist(self) -> None:
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        publish_staged = release_script.split("publish_staged_release() {", 1)[1].split("\n}", 1)[0]

        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"'),
            publish_staged.index("verify_release_sentry_symbol_uuids_before_signing"),
        )
        self.assertLess(
            publish_staged.index("verify_release_sentry_symbol_uuids_before_signing"),
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
        )
        self.assertLess(
            publish_staged.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"'),
            publish_staged.index("prepare_dist"),
        )

    def test_ci_workflow_cancels_only_superseded_pull_request_runs(self) -> None:
        ci_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        concurrency_block = ci_workflow.split("concurrency:", 1)[1].split("\npermissions:", 1)[0]
        normalized_concurrency = " ".join(concurrency_block.split())

        self.assertIn(
            "group: ci-${{ github.event.pull_request.number || github.run_id }}",
            normalized_concurrency,
        )
        self.assertIn(
            "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
            normalized_concurrency,
        )
        self.assertNotIn("cancel-in-progress: true", concurrency_block)

    def test_main_tip_workflow_keeps_tip_separate_and_uses_hardened_smoke(self) -> None:
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        publication_script = (SCRIPT_DIR / "tip_release_publication.py").read_text(encoding="utf-8")
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")

        self.assertIn("name: Publish Tip", tip_workflow)
        concurrency_block = tip_workflow.split("concurrency:", 1)[1].split("\npermissions:", 1)[0]
        normalized_concurrency = " ".join(concurrency_block.split())
        self.assertIn(
            "group: >- ${{ (github.event_name == 'workflow_dispatch' && 'main-tip-dispatch-channel') || "
            "(github.event.workflow_run.conclusion == 'success' && 'main-tip-channel') || "
            "format('main-tip-skipped-{0}', github.run_id) }}",
            normalized_concurrency,
        )
        self.assertIn("queue: max", normalized_concurrency)
        self.assertNotIn("cancel-in-progress:", concurrency_block)

        publish_header = tip_workflow.split("\n  publish:", 1)[1].split("\n    needs:", 1)[0]
        self.assertIn(
            "concurrency:\n      group: main-tip-publish\n      queue: max",
            publish_header,
        )
        self.assertIn("should-publish", tip_workflow)
        self.assertIn("stable-appcast-input.xml", tip_workflow)
        self.assertEqual(tip_workflow.count("tip_release_context.py resolve"), 1)
        self.assertNotIn("stable_rollout.py packaging-context", tip_workflow)
        self.assertIn("environment: tip-release", tip_workflow)
        self.assertIn("TIP_UPDATE_REPOSITORY_TOKEN", tip_workflow)
        self.assertIn("repoprompt-ce-tip-updates", tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT: "60"', tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_DIAGNOSTICS_DIR: ${{ runner.temp }}/tip-smoke-diagnostics', tip_workflow)
        self.assertIn("Upload Tip smoke diagnostics", tip_workflow)
        self.assertIn("RepoPrompt-CE-tip-smoke-diagnostics", tip_workflow)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_TIMEOUT"', tip_workflow)
        self.assertIn(
            'REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT="$REPOPROMPT_PACKAGED_SMOKE_HELPER_TIMEOUT"',
            tip_workflow,
        )
        self.assertIn("Check out approved tip source as data", tip_workflow)
        self.assertIn("extract_staged_release.py", tip_workflow)
        self.assertIn("REPOPROMPT_APPROVED_SOURCE_ROOT: ${{ github.workspace }}/approved-source", tip_workflow)
        verify_action = (
            SCRIPT_DIR.parent / ".github" / "actions" / "verify-tip-context" / "action.yml"
        ).read_text(encoding="utf-8")
        self.assertIn('echo "REPOPROMPT_TIP_RELEASE_CONTEXT=$GITHUB_WORKSPACE/tip-release-context/tip-release-context.json"', verify_action)
        self.assertIn('echo "REPOPROMPT_EXPECTED_CONTEXT_SHA256=$EXPECTED_CONTEXT_SHA256"', verify_action)
        self.assertIn("path: tip-source/dist/", tip_workflow)
        self.assertEqual(tip_workflow.count("main_tip_release.sh validate-assets"), 2)
        self.assertNotIn("shasum -a 256 tip-source/dist/SHA256SUMS", tip_workflow)
        self.assertIn(
            'REPOPROMPT_TIP_ASSET_GITHUB_OUTPUT="$GITHUB_OUTPUT"', tip_workflow
        )
        self.assertIn("path: signed-tip", tip_workflow)
        self.assertIn("DIST_DIR: ${{ github.workspace }}/signed-tip", tip_workflow)
        self.assertIn("path: tip-assets", tip_workflow)
        self.assertIn("DIST_DIR: ${{ github.workspace }}/tip-assets", tip_workflow)
        self.assertNotIn("TIP_PUBLISH_INSTALLATION_TYPE", tip_workflow)
        downstream_workflow = tip_workflow.split("\n  automatic-tip-dormant:", 1)[1]
        self.assertNotIn("TIP_UPDATE_REPOSITORY:", downstream_workflow)
        self.assertNotIn("stable-release-channel", tip_workflow)
        self.assertNotIn("PUBLIC_UPDATE_REPOSITORY_TOKEN", tip_workflow)

        stage_job = tip_workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]
        sign_job = tip_workflow.split("\n  sign:", 1)[1].split("\n  smoke-no-secrets:", 1)[0]
        sign_step = sign_job.split("      - name: Sign staged Tip application", 1)[1].split(
            "      - name: Notarize and validate Tip application", 1
        )[0]
        notarize_step = sign_job.split("      - name: Notarize and validate Tip application", 1)[1].split(
            "      - name: Prepare transition package payload", 1
        )[0]
        package_steps = sign_job.split("      - name: Prepare transition package payload", 1)[1].split(
            "      - name: Construct and notarize normal Tip enclosure", 1
        )[0]
        finalize_step = sign_job.split("      - name: Finalize signed Tip release assets", 1)[1].split(
            "      - name: Remove ephemeral keychain", 1
        )[0]
        cleanup_step = sign_job.split("      - name: Remove ephemeral keychain", 1)[1].split(
            "      - name: Upload signed tip assets", 1
        )[0]
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', stage_job)
        for protected_name in (
            "SENTRY_DSN",
            "SENTRY_AUTH_TOKEN",
            "REPOPROMPT_SENTRY_ORG",
            "REPOPROMPT_SENTRY_PROJECT",
            "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE",
        ):
            self.assertNotIn(protected_name, stage_job)
        self.assertIn("Install Sentry CLI for Tip symbol upload", sign_job)
        self.assertIn("Prepare Tip Sentry auth token file", sign_job)
        self.assertIn("chmod 600", sign_job)
        self.assertIn('mkdir -p "$RUNNER_TEMP/repoprompt-tip-secrets"', sign_job)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', sign_step)
        self.assertIn("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}", sign_step)
        self.assertIn("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}", sign_step)
        self.assertIn("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}", sign_step)
        self.assertIn("REPOPROMPT_SENTRY_AUTH_TOKEN_FILE: ${{ runner.temp }}/repoprompt-tip-secrets/sentry-auth-token", sign_step)
        self.assertNotIn("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}", sign_step)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', notarize_step)
        self.assertIn("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}", notarize_step)
        self.assertIn("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}", finalize_step)
        for phase_name in (
            "Generate deterministic transition component plist",
            "Construct transition component package",
            "Construct transition product archive",
            "Sign transition package",
            "Notarize transition package",
            "Expand transition package",
            "Compare transition package payload",
        ):
            self.assertIn(phase_name, package_steps)
        self.assertIn("needs.setup.outputs.installation-type == 'package'", package_steps)
        self.assertIn("run: exec ./trusted-control-plane/Scripts/main_tip_release.sh", package_steps)
        self.assertIn("-T /usr/bin/productsign", sign_job)
        self.assertIn("productbuild:,productsign:", sign_job)
        self.assertIn("if: always()", cleanup_step)
        self.assertIn('rm -rf "$RUNNER_TEMP/repoprompt-tip-secrets"', cleanup_step)
        self.assertEqual(tip_workflow.count("SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}"), 1)
        self.assertEqual(tip_workflow.count("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}"), 2)
        self.assertEqual(tip_workflow.count("REPOPROMPT_SENTRY_ORG: ${{ vars.SENTRY_ORG }}"), 2)
        self.assertEqual(tip_workflow.count("REPOPROMPT_SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}"), 2)
        self.assertEqual(
            tip_workflow.count(
                "REPOPROMPT_SENTRY_AUTH_TOKEN_FILE: ${{ runner.temp }}/repoprompt-tip-secrets/sentry-auth-token"
            ),
            2,
        )
        self.assertLess(
            sign_job.index("Install Sentry CLI for Tip symbol upload"),
            sign_job.index("Sign staged Tip application"),
        )
        self.assertLess(
            sign_job.index("Prepare Tip Sentry auth token file"),
            sign_job.index("Sign staged Tip application"),
        )
        self.assertLess(
            sign_job.index("Sign staged Tip application"),
            sign_job.index("Notarize and validate Tip application"),
        )
        self.assertLess(
            sign_job.index("Notarize and validate Tip application"),
            sign_job.index("Generate deterministic transition component plist"),
        )
        self.assertLess(
            sign_job.index("Compare transition package payload"),
            sign_job.index("Finalize signed Tip release assets"),
        )
        self.assertLess(
            sign_job.index("Finalize signed Tip release assets"),
            sign_job.index("Upload signed tip assets for smoke and publish"),
        )

        self.assertIn("load_verified_tip_release_context", tip_script)
        self.assertNotIn('git rev-list --count "$TIP_COMMIT"', tip_script)
        self.assertNotIn('TIP_TAG="${TIP_TAG:-tip-$TIP_SHORT_SHA}"', tip_script)
        self.assertNotIn("TIP_UPDATE_REPOSITORY=", tip_script)
        self.assertNotIn('${TIP_GH_TOKEN:-${GH_TOKEN:-}}', tip_script)
        self.assertNotIn("gh release create", tip_script)
        self.assertIn('exec python3 "$PUBLICATION_TOOL" publish', tip_script)
        self.assertIn('REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER"', tip_script)
        self.assertEqual(tip_script.count('REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER"'), 1)
        self.assertIn("stage|sign-application|notarize-application|prepare-transition-payload", tip_script)
        self.assertIn("compare-transition-payload|build-application-enclosure|finalize-assets", tip_script)
        self.assertIn('source "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"', tip_script)
        self.assertIn("stage_release_sentry_symbols", tip_script)
        self.assertIn("require_tip_sentry_configuration", tip_script)
        self.assertIn("require_release_sentry_symbols_when_enabled", tip_script)
        self.assertIn("upload_release_sentry_symbols", tip_script)
        self.assertIn("final Tip artifact manifest must record telemetry_enabled=true", tip_script)
        stage_tip = tip_script.split("stage_tip() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("REPOPROMPT_ENABLE_SENTRY=1", stage_tip)
        self.assertNotIn("SENTRY_DSN", stage_tip)
        self.assertNotIn("SENTRY_AUTH_TOKEN", stage_tip)

        sign_tip = tip_script.split("sign_tip_application() {", 1)[1].split("\n}", 1)[0]
        notarize_tip = tip_script.split("notarize_tip_application() {", 1)[1].split("\n}", 1)[0]
        application_enclosure = tip_script.split("build_tip_application_enclosure() {", 1)[1].split("\n}", 1)[0]
        finalize_assets = tip_script.split("finalize_tip_release_assets() {", 1)[1].split("\n}", 1)[0]
        require_sentry = sign_tip.index("require_tip_sentry_configuration")
        verify_symbols = sign_tip.index("verify_release_sentry_symbol_uuids_before_signing")
        sign_staged = sign_tip.index('"$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"')
        assert_telemetry = notarize_tip.index("assert_tip_manifest_telemetry_enabled")
        upload_symbols = notarize_tip.index("upload_release_sentry_symbols")
        create_distribution = application_enclosure.index('local distribution_dir="$TMP_DIR/distribution"')
        self.assertLess(require_sentry, verify_symbols)
        self.assertLess(verify_symbols, sign_staged)
        self.assertLess(assert_telemetry, upload_symbols)
        self.assertGreaterEqual(create_distribution, 0)
        generate_appcast = finalize_assets.index("generate_tip_rollout_appcast")
        write_checksums = finalize_assets.index('shasum -a 256', generate_appcast)
        self.assertLess(generate_appcast, write_checksums)
        self.assertIn('python3 "$ROLLOUT_TOOL" generate-from-context', tip_script)
        self.assertIn('python3 "$ROLLOUT_TOOL" validate-from-context', tip_script)
        self.assertNotIn('--allowed-roles legacy,preparer,transition,successor', tip_script)
        self.assertIn('--manifest-output "$ROLLOUT_MANIFEST"', tip_script)
        self.assertIn('fail "Tip Sparkle private key does not match the app bundle SUPublicEDKey"', tip_script)
        self.assertIn('fail "Tip Sparkle private key does not reproduce the generated appcast signature"', tip_script)
        self.assertIn('"$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"', tip_script)
        self.assertIn("validate_live_tip_publication_state", publication_script)
        self.assertIn("supervisor.run_supervised", publication_script)
        self.assertIn('"draft": True', publication_script)
        self.assertIn("upload_missing_assets", publication_script)
        self.assertIn('"draft": False', publication_script)
        self.assertIn("anonymous_post_publish_audit", publication_script)
        self.assertNotIn("--clobber", publication_script)
        self.assertNotIn("time.sleep", publication_script)
        self.assertIn('validate-local-assets', tip_script)
        self.assertNotIn('shasum -a 256 -c SHA256SUMS', tip_script)
        self.assertNotIn('done < <(python3 "$ROLLOUT_TOOL" predecessor-values-from-context)', tip_script)

        capture_override = package_script.index(
            'RELEASE_BUILD_NUMBER_OVERRIDE="${REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE:-}"'
        )
        capture_team_override = package_script.index('SIGNING_TEAM_ID_OVERRIDE="${SIGNING_TEAM_ID:-}"')
        load_metadata = package_script.index('load_release_metadata "$ROOT_DIR"')
        apply_override = package_script.index('BUILD_NUMBER="$RELEASE_BUILD_NUMBER_OVERRIDE"')
        apply_team_override = package_script.index(
            'SIGNING_TEAM_ID="${SIGNING_TEAM_ID_OVERRIDE:-$BASE_SIGNING_TEAM_ID}"'
        )
        self.assertLess(capture_override, load_metadata)
        self.assertLess(capture_team_override, load_metadata)
        self.assertLess(load_metadata, apply_override)
        self.assertLess(load_metadata, apply_team_override)
        self.assertIn(
            'fail "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE must be a valid numeric build version"',
            package_script,
        )

    def test_tip_publish_asset_inventory_is_exact(self) -> None:
        approved, _, scripts = self.make_staged_release_fixture(tip_context=True)
        context_environment = json.loads(
            (approved.parent / "tip-context-environment.json").read_text(encoding="utf-8")
        )
        context = json.loads(Path(context_environment["context"]).read_text(encoding="utf-8"))
        expected = context["publication"]["assets"]
        self.assertEqual(context["rollout"]["installationType"], "package")
        self.assertIn("tip-release-context.json", expected)
        self.assertIn("tip-release-context.json.sha256", expected)
        self.assertTrue(any(name.endswith(".pkg") for name in expected))

        dist = approved.parent / "publish-assets"
        dist.mkdir()
        for name in expected:
            if name == "SHA256SUMS":
                continue
            if name == "tip-release-context.json":
                shutil.copy2(context_environment["context"], dist / name)
            elif name == "tip-release-context.json.sha256":
                shutil.copy2(context_environment["digest"], dist / name)
            else:
                (dist / name).write_text(f"{name}\n", encoding="utf-8")

        def write_checksums(names: list[str] | None = None) -> str:
            checksum_names = names or [name for name in expected if name != "SHA256SUMS"]
            checksums = "".join(
                f"{hashlib.sha256((dist / name).read_bytes()).hexdigest()}  {name}\n"
                for name in checksum_names
            )
            (dist / "SHA256SUMS").write_text(checksums, encoding="utf-8")
            return hashlib.sha256(checksums.encode()).hexdigest()

        trusted_checksums_digest = write_checksums()
        env = os.environ.copy()
        env.pop("GH_TOKEN", None)
        env.update(
            {
                "REPOPROMPT_TIP_RELEASE_CONTEXT": context_environment["context"],
                "REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE": context_environment["digest"],
                "REPOPROMPT_TIP_STABLE_APPCAST": context_environment["stable_appcast"],
                "REPOPROMPT_EXPECTED_CONTEXT_SHA256": context_environment["expected_digest"],
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT": context_environment["approved_commit"],
                "REPOPROMPT_EXPECTED_TOOLING_COMMIT": context_environment["tooling_commit"],
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(approved),
                "DIST_DIR": str(dist),
                "REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256": trusted_checksums_digest,
            }
        )

        def validate(custom_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                [str(scripts / "main_tip_release.sh"), "validate-assets"],
                cwd=approved,
                env=custom_env or env,
                text=True,
                capture_output=True,
                timeout=5,
            )

        accepted = validate()
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn(f"contains exactly {len(expected)} files", accepted.stdout)
        github_output = approved.parent / "github-output"
        github_output.write_text("", encoding="utf-8")
        output_env = env.copy()
        output_env["REPOPROMPT_TIP_ASSET_GITHUB_OUTPUT"] = str(github_output)
        accepted_output = validate(output_env)
        self.assertEqual(accepted_output.returncode, 0, accepted_output.stderr)
        self.assertEqual(
            github_output.read_text(encoding="utf-8"),
            f"sha256sums-sha256={trusted_checksums_digest}\n",
        )

        conflicting_env = env.copy()
        conflicting_env["TIP_TAG"] = "tip-conflicting-ambient"
        conflicting = validate(conflicting_env)
        self.assertNotEqual(conflicting.returncode, 0)
        self.assertIn("Ambient TIP_TAG conflicts with the verified Tip release context", conflicting.stderr)

        legacy_aliases = {
            "TIP_UPDATE_REPOSITORY": context["sparkle"]["updateRepository"],
            "TIP_PUBLISH_INSTALLATION_TYPE": context["rollout"]["installationType"],
            "RELEASE_COMMIT": context["release"]["commit"],
            "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE": context["release"]["buildNumber"],
            "BUILD_NUMBER": context["release"]["buildNumber"],
            "GH_TOKEN": "synthetic-legacy-alias",
        }
        for alias, value in legacy_aliases.items():
            with self.subTest(legacy_alias=alias):
                alias_env = env.copy()
                alias_env[alias] = value
                rejected_alias = validate(alias_env)
                self.assertNotEqual(rejected_alias.returncode, 0)
                self.assertIn(
                    f"Ambient legacy Tip authority alias is prohibited: {alias}",
                    rejected_alias.stderr,
                )

        missing_context_env = env.copy()
        missing_context_env.pop("REPOPROMPT_TIP_RELEASE_CONTEXT")
        missing_context = validate(missing_context_env)
        self.assertNotEqual(missing_context.returncode, 0)
        self.assertIn(
            "Missing required environment variable: REPOPROMPT_TIP_RELEASE_CONTEXT",
            missing_context.stderr,
        )

        (dist / "appcast.xml").unlink()
        missing = validate()
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("missing=['appcast.xml']", missing.stderr)

        (dist / "appcast.xml").write_text("appcast.xml\n", encoding="utf-8")
        (dist / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
        extra = validate()
        self.assertNotEqual(extra.returncode, 0)
        self.assertIn("extra=['unexpected.txt']", extra.stderr)
        (dist / "unexpected.txt").unlink()

        context_asset = dist / "tip-release-context.json"
        context_asset.unlink()
        context_asset.symlink_to(context_environment["context"])
        symlink = validate()
        self.assertNotEqual(symlink.returncode, 0)
        self.assertIn("regular non-symlink file", symlink.stderr)

        context_asset.unlink()
        shutil.copy2(context_environment["context"], context_asset)
        changed_asset = dist / "appcast.xml"
        changed_asset.write_text("changed appcast bytes\n", encoding="utf-8")
        changed = validate()
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("local Tip asset digest mismatch", changed.stderr)

        coordinated_env = env.copy()
        write_checksums()
        coordinated = validate(coordinated_env)
        self.assertNotEqual(coordinated.returncode, 0)
        self.assertIn("differs from the trusted sign-job digest", coordinated.stderr)

        missing_checksum_env = env.copy()
        missing_checksum_env["REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256"] = write_checksums(
            [name for name in expected if name not in {"SHA256SUMS", "appcast.xml"}]
        )
        missing_checksum = validate(missing_checksum_env)
        self.assertNotEqual(missing_checksum.returncode, 0)
        self.assertIn("SHA256SUMS entry set mismatch", missing_checksum.stderr)

        write_checksums()
        root_symlink = approved.parent / "publish-assets-link"
        root_symlink.symlink_to(dist, target_is_directory=True)
        root_symlink_env = env.copy()
        root_symlink_env["DIST_DIR"] = str(root_symlink)
        rejected_root = validate(root_symlink_env)
        self.assertNotEqual(rejected_root.returncode, 0)
        self.assertIn("real non-symlink directory", rejected_root.stderr)

        appcast = dist / "appcast.xml"
        appcast.unlink()
        appcast.mkdir()
        rejected_directory = validate()
        self.assertNotEqual(rejected_directory.returncode, 0)
        self.assertIn("regular non-symlink file", rejected_directory.stderr)
        appcast.rmdir()
        os.mkfifo(appcast)
        started = time.monotonic()
        rejected_fifo = validate()
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertNotEqual(rejected_fifo.returncode, 0)
        self.assertIn("regular non-symlink file", rejected_fifo.stderr)
        appcast.unlink()
        appcast.write_text("appcast.xml\n", encoding="utf-8")
        write_checksums()

        setup_symlink = approved.parent / "setup-context-link.json"
        setup_symlink.symlink_to(context_environment["context"])
        setup_symlink_env = env.copy()
        setup_symlink_env["REPOPROMPT_TIP_RELEASE_CONTEXT"] = str(setup_symlink)
        rejected_setup_symlink = validate(setup_symlink_env)
        self.assertNotEqual(rejected_setup_symlink.returncode, 0)
        self.assertIn("setup context must be a regular non-symlink file", rejected_setup_symlink.stderr)

        setup_fifo = approved.parent / "setup-context.fifo"
        os.mkfifo(setup_fifo)
        setup_fifo_env = env.copy()
        setup_fifo_env["REPOPROMPT_TIP_RELEASE_CONTEXT"] = str(setup_fifo)
        started = time.monotonic()
        rejected_setup_fifo = validate(setup_fifo_env)
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertNotEqual(rejected_setup_fifo.returncode, 0)
        self.assertIn("setup context must be a regular non-symlink file", rejected_setup_fifo.stderr)

    def test_main_tip_setup_lookup_is_anonymous_until_serialized_publish(self) -> None:
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        setup_job = tip_workflow.split("\n  setup:", 1)[1].split("\n  credential-preflight:", 1)[0]
        after_setup = tip_workflow.split("\n  stage:", 1)[1]
        before_publish, publish_job = tip_workflow.split("\n  publish:", 1)

        self.assertIn("permissions:\n  contents: read", tip_workflow)
        self.assertNotIn("lookup_public_tip_release.sh", setup_job)
        self.assertNotIn("lookup-public", setup_job)
        self.assertNotIn("TIP_GH_TOKEN", setup_job)
        self.assertNotIn("${{ github.token }}", tip_workflow)
        self.assertNotIn("${{ github.token }}", after_setup)
        self.assertNotIn("environment: tip-release", setup_job)
        self.assertNotIn("Authorization:", setup_job)
        self.assertNotIn("api.github.com", setup_job)
        self.assertNotIn("TIP_UPDATE_REPOSITORY_TOKEN", before_publish)
        self.assertIn("TIP_GH_TOKEN: ${{ secrets.TIP_UPDATE_REPOSITORY_TOKEN }}", publish_job)
        self.assertEqual(tip_workflow.count("TIP_UPDATE_REPOSITORY_TOKEN"), 1)

    def test_tip_fetches_use_single_attempt_total_wall_clock_bounds(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        setup_resolution = workflow.split(
            "      - name: Resolve, verify, and summarize immutable Tip context", 1
        )[1].split("      - name: Upload immutable Tip release context", 1)[0]
        predecessor_fetch = tip_script.split("generate_tip_rollout_appcast() {", 1)[1].split(
            "sign_tip_application() {", 1
        )[0]
        live_publication = tip_script.split("publish_tip() {", 1)[1].split(
            'if [[ "${BASH_SOURCE[0]}" == "$0" ]]', 1
        )[0]

        for label, source, expected_curls in (
            ("Stable setup", setup_resolution, 1),
            ("predecessor", predecessor_fetch, 1),
            ("live publication", live_publication, 0),
        ):
            with self.subTest(fetch_boundary=label):
                self.assertEqual(source.count("curl --fail"), expected_curls)
                self.assertEqual(source.count("--connect-timeout 10"), expected_curls)
                self.assertEqual(source.count("--max-time 30"), expected_curls)
                self.assertNotIn("--retry", source)
                self.assertNotIn("retry-after", source.casefold())
        publication = (SCRIPT_DIR / "tip_release_publication.py").read_text(encoding="utf-8")
        self.assertIn("supervisor.run_supervised", publication)
        self.assertIn("DEFAULT_COMMAND_TIMEOUT_SECONDS", publication)
        self.assertIn("DEFAULT_ASSET_TIMEOUT_SECONDS", publication)
        self.assertNotIn("time.sleep", publication)
        self.assertNotIn("--retry", publication)

    def test_tip_no_release_diagnostic_contract_is_truthful_and_read_only(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        setup_job = workflow.split("\n  setup:", 1)[1].split("\n  automatic-tip-dormant:", 1)[0]
        resolve_step = setup_job.split(
            "      - name: Resolve, verify, and summarize immutable Tip context", 1
        )[1]
        diagnostic_job = workflow.split("\n  automatic-tip-dormant:", 1)[1].split(
            "\n  credential-preflight:", 1
        )[0]

        self.assertIn("skip-reason: ${{ steps.tip.outputs.skip-reason }}", setup_job)
        for marker in (
            'skip_reason=""',
            'skip_reason="role-requires-manual-review"',
            'echo "skip-reason=$skip_reason"',
        ):
            self.assertIn(marker, resolve_step)
        self.assertIn(
            "    if: >-\n"
            "      github.event_name == 'workflow_run' &&\n"
            "      needs.setup.outputs.should-publish != 'true' &&\n"
            "      needs.setup.outputs.skip-reason == 'role-requires-manual-review'",
            diagnostic_job,
        )
        self.assertIn("name: Automatic Tip Publication Dormant (Review Required)", diagnostic_job)
        self.assertIn("runs-on: ubuntu-latest", diagnostic_job)
        self.assertIn("    permissions:\n      contents: read", diagnostic_job)
        for marker in (
            "GITHUB_STEP_SUMMARY",
            "expected-role: ${{ needs.setup.outputs.rollout-role }}",
            'echo "- Rollout role: $ROLLOUT_ROLE"',
            'echo "- Commit: $TIP_COMMIT"',
            'echo "- Tag: $TIP_TAG"',
            "Nothing was built, signed, or published.",
            "Manual workflow capability, exact-role confirmation, and environment approval",
            "Follow the go/no-go procedure in docs/releasing.md",
            "obtain explicit authorization before any release dispatch",
            "::error::",
            "exit 1",
        ):
            self.assertIn(marker, diagnostic_job)
        self.assertIn("boundary: automatic-dormant", diagnostic_job)
        self.assertIn(
            "uses: ./trusted-control-plane/.github/actions/verify-tip-context",
            diagnostic_job,
        )
        self.assertLess(
            diagnostic_job.index("Verify immutable Tip release context"),
            diagnostic_job.index("Report suppressed automatic publication"),
        )

    def test_setup_has_no_existence_only_release_lookup(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        publication = (SCRIPT_DIR / "tip_release_publication.py").read_text(encoding="utf-8")

        self.assertFalse((SCRIPT_DIR / "lookup_public_tip_release.sh").exists())
        self.assertNotIn("lookup_public_tip_release.sh", workflow)
        self.assertNotIn("lookup-public", publication)
        self.assertNotIn("existing-public-unaudited", publication)

    def test_tip_release_provenance_is_exact_before_credentials_and_runs_are_not_cancelled(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        stable_workflow = (
            SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_provenance_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        commit = "a" * 40
        publication.validate_release_provenance(commit, commit, commit, commit)
        for label, values in (
            ("workflow-definition", ("b" * 40, commit, commit, commit)),
            ("tooling", (commit, "b" * 40, commit, commit)),
            ("selected-source", (commit, commit, "b" * 40, commit)),
            ("protected-main", (commit, commit, commit, "b" * 40)),
        ):
            with self.subTest(skew=label), self.assertRaisesRegex(
                publication.PublicationError, "provenance skew"
            ):
                publication.validate_release_provenance(*values)

        provenance_args = mock.Mock(
            workflow_definition_commit=commit,
            tooling_commit=commit,
            selected_source_commit=commit,
            repository="repoprompt/repoprompt-ce",
            trusted_tooling_root=str(SCRIPT_DIR.parent),
            command_timeout_seconds=30.0,
        )
        with mock.patch.object(publication, "PublicationRunner"), mock.patch.object(
            publication, "fetch_live_main", return_value=commit
        ) as protected_fetch:
            self.assertEqual(publication.run_validate_provenance(provenance_args), 0)
        protected_fetch.assert_called_once()
        with mock.patch.object(publication, "PublicationRunner"), mock.patch.object(
            publication, "fetch_live_main", return_value="b" * 40
        ), self.assertRaisesRegex(publication.PublicationError, "provenance skew"):
            publication.run_validate_provenance(provenance_args)

        dispatch_input = workflow.split("      commit:", 1)[1].split(
            "      confirm_identity_rollout_role:", 1
        )[0]
        self.assertIn("required: true", dispatch_input)
        setup = workflow.split("\n  setup:", 1)[1].split("\n  automatic-tip-dormant:", 1)[0]
        self.assertIn("ref: ${{ github.workflow_sha }}", setup)
        self.assertIn("WORKFLOW_DEFINITION_COMMIT: ${{ github.workflow_sha }}", setup)
        self.assertIn("MANUAL_COMMIT: ${{ inputs.commit }}", setup)
        self.assertIn("WORKFLOW_RUN_COMMIT: ${{ github.event.workflow_run.head_sha }}", setup)
        self.assertIn("tip_release_publication.py validate-provenance", setup)
        self.assertLess(
            setup.index("tip_release_publication.py validate-provenance"),
            setup.index("Check out approved tip source as data"),
        )
        global_concurrency = workflow.split("concurrency:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("queue: max", global_concurrency)
        self.assertNotIn("cancel-in-progress:", global_concurrency)
        stable_concurrency = stable_workflow.split("concurrency:", 1)[1].split(
            "\npermissions:", 1
        )[0]
        self.assertIn("group: release-draft-creation", stable_concurrency)
        self.assertIn("queue: max", stable_concurrency)
        self.assertNotIn("cancel-in-progress:", stable_concurrency)
        self.assertNotIn("git -C trusted-control-plane fetch", setup)
        publication_source = (SCRIPT_DIR / "tip_release_publication.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("fresh protected source main verification", publication_source)
        self.assertIn("supervisor.run_supervised", publication_source)

        release_selftest = (SCRIPT_DIR.parent / "Makefile").read_text(encoding="utf-8").split(
            "release-selftest:\n", 1
        )[1].split("\n\n", 1)[0]
        self.assertIn("python3 Scripts/test_release_phase_supervisor.py", release_selftest)
        self.assertIn("python3 Scripts/test_transition_package_contract.py", release_selftest)

        for job, next_job, minutes in (
            ("setup", "automatic-tip-dormant", 20),
            ("automatic-tip-dormant", "credential-preflight", 10),
            ("credential-preflight", "stage", 30),
            ("stage", "sign", 90),
            ("sign", "smoke-no-secrets", 120),
            ("smoke-no-secrets", "publish", 30),
        ):
            body = workflow.split(f"\n  {job}:", 1)[1].split(f"\n  {next_job}:", 1)[0]
            self.assertIn(f"timeout-minutes: {minutes}", body)
        publish_body = workflow.split("\n  publish:", 1)[1]
        self.assertIn("timeout-minutes: 120", publish_body)

        sign_job = workflow.split("\n  sign:", 1)[1].split("\n  smoke-no-secrets:", 1)[0]
        sign_job_environment = sign_job.split("    env:", 1)[1].split("    steps:", 1)[0]
        self.assertNotIn("${{ runner.temp }}", sign_job_environment)
        self.assertIn("Initialize transition package work directory", sign_job)
        self.assertIn(
            "printf 'REPOPROMPT_TRANSITION_PACKAGE_WORK_DIR=%s\\n' \"$transition_work_dir\" >> \"$GITHUB_ENV\"",
            sign_job,
        )
        self.assertIn('transition_work_dir="${REPOPROMPT_TRANSITION_PACKAGE_WORK_DIR:-}"', sign_job)
        self.assertIn('expected_transition_work_dir="$RUNNER_TEMP/repoprompt-transition-package-work"', sign_job)
        self.assertIn('[[ "$transition_work_dir" != "$expected_transition_work_dir" ]]', sign_job)
        self.assertIn('rm -rf -- "$transition_work_dir"', sign_job)

    def test_tip_publication_draft_resume_and_public_audit_are_byte_exact(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_asset_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        dist = root / "dist"
        downloads = root / "downloads"
        dist.mkdir()
        downloads.mkdir()
        names = [
            "RepoPrompt-tip-fixture.pkg",
            "appcast.xml",
            "identity-rollout.json",
            "tip-release-context.json",
            "tip-release-context.json.sha256",
            "SHA256SUMS",
        ]
        context = {
            "release": {
                "displayName": "RepoPrompt CE",
                "shortSha": "a" * 12,
                "commit": "a" * 40,
                "buildNumber": "35.15.21",
                "tag": "tip-" + "a" * 12,
            },
            "rollout": {"role": "transition"},
            "publication": {"target": "main", "assets": names},
        }
        setup_context = root / "setup-context.json"
        setup_digest = root / "setup-context.json.sha256"
        setup_context.write_text(json.dumps(context, sort_keys=True) + "\n", encoding="utf-8")
        setup_digest.write_text(hashlib.sha256(setup_context.read_bytes()).hexdigest() + "\n", encoding="ascii")
        for name in names:
            if name == "SHA256SUMS":
                continue
            source = setup_context if name == "tip-release-context.json" else setup_digest if name == "tip-release-context.json.sha256" else None
            if source is not None:
                shutil.copy2(source, dist / name)
            else:
                (dist / name).write_text(f"fixture bytes for {name}\n", encoding="utf-8")
        checksum_names = [name for name in names if name != "SHA256SUMS"]
        (dist / "SHA256SUMS").write_text(
            "".join(
                f"{hashlib.sha256((dist / name).read_bytes()).hexdigest()}  {name}\n"
                for name in checksum_names
            ),
            encoding="utf-8",
        )
        checksums_digest = hashlib.sha256((dist / "SHA256SUMS").read_bytes()).hexdigest()
        expectations, returned_checksums_digest = publication.build_local_asset_expectations(
            context, dist, setup_context, setup_digest, checksums_digest
        )
        self.assertEqual(returned_checksums_digest, checksums_digest)

        def remote(name: str) -> dict:
            expectation = expectations[name]
            return {
                "name": name,
                "state": "uploaded",
                "size": expectation.size,
                "url": f"https://api.github.com/repos/example/updates/releases/assets/{len(name)}",
                "browser_download_url": (
                    f"https://github.com/example/updates/releases/download/{context['release']['tag']}/{name}"
                ),
            }

        def release(*, draft: bool, asset_names: list[str], title: str | None = None) -> dict:
            return {
                "id": 42,
                "tag_name": context["release"]["tag"],
                "target_commitish": "main",
                "name": title or publication.expected_release_title(context),
                "body": publication.expected_release_notes(context),
                "draft": draft,
                "prerelease": False,
                "assets": [remote(name) for name in asset_names],
            }

        first = names[0]
        draft_plan = publication.validate_release_metadata(
            context, release(draft=True, asset_names=[first]), expectations
        )
        self.assertEqual(draft_plan.state, "draft")
        self.assertEqual(set(draft_plan.missing_assets), set(names) - {first})

        class AuthenticatedLookupRunner:
            def lookup_authenticated_release(
                self, phase: str, repository: str, tag: str
            ) -> dict:
                self.call = (phase, repository, tag)
                return release(draft=True, asset_names=[first])

            def fetch_json(self, *args, **kwargs):
                raise AssertionError("authenticated lookup must list releases so drafts are visible")

        lookup_runner = AuthenticatedLookupRunner()
        looked_up = publication.fetch_release(
            lookup_runner,
            "example/updates",
            context["release"]["tag"],
            authenticated=True,
            allow_not_found=False,
            phase="resume exact draft",
        )
        self.assertTrue(looked_up["draft"])
        self.assertEqual(
            lookup_runner.call,
            ("resume exact draft", "example/updates", context["release"]["tag"]),
        )

        with self.assertRaisesRegex(publication.PublicationError, "metadata mismatch"):
            publication.validate_release_metadata(
                context,
                release(draft=True, asset_names=[], title="mismatching draft"),
                expectations,
            )

        public_plan = publication.validate_release_metadata(
            context, release(draft=False, asset_names=names), expectations
        )
        self.assertEqual({asset.name for asset in public_plan.remote_assets}, set(names))
        with self.assertRaisesRegex(publication.PublicationError, "public GitHub release asset inventory"):
            publication.validate_release_metadata(
                context, release(draft=False, asset_names=names[:-1]), expectations
            )

    def test_tip_publication_run_publish_resumes_every_ambiguous_mutation_and_audits_public_bytes(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_state_machine_test",
            SCRIPT_DIR / "tip_release_publication.py",
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        dist = root / "dist"
        dist.mkdir()
        names = (
            "RepoPrompt-tip-aaaaaaaaaaaa-35.15.21.pkg",
            "RepoPrompt-tip-aaaaaaaaaaaa-35.15.21-artifact-manifest.json",
            "RepoPrompt-tip-aaaaaaaaaaaa-35.15.21-metadata.json",
            "appcast.xml",
            "identity-rollout.json",
            "tip-release-context.json",
            "tip-release-context.json.sha256",
            "SHA256SUMS",
        )
        expectations: dict[str, object] = {}
        for name in names:
            value = b"{}\n" if name == "identity-rollout.json" else f"bytes:{name}\n".encode()
            path = dist / name
            path.write_bytes(value)
            expectations[name] = publication.AssetExpectation(
                name=name,
                path=path,
                size=len(value),
                sha256=hashlib.sha256(value).hexdigest(),
            )
        candidate_manifest_bytes = (dist / "identity-rollout.json").read_bytes()
        candidate_appcast_bytes = (dist / "appcast.xml").read_bytes()
        context = {
            "release": {
                "displayName": "RepoPrompt CE",
                "shortSha": "a" * 12,
                "commit": "a" * 40,
                "buildNumber": "35.15.21",
                "tag": "tip-" + "a" * 12,
            },
            "rollout": {"role": "transition", "installationType": "package"},
            "publication": {
                "repository": "example/updates",
                "target": "main",
                "assets": list(names),
            },
        }
        args = mock.Mock(
            dist_dir=str(dist),
            context=str(root / "setup-context.json"),
            digest=str(root / "setup-context.json.sha256"),
            stable_appcast=str(root / "stable.xml"),
            approved_source_root=str(root),
            trusted_tooling_root=str(root),
            expected_context_sha256="b" * 64,
            expected_approved_source_commit=context["release"]["commit"],
            expected_tooling_commit=context["release"]["commit"],
            expected_sha256sums_sha256="c" * 64,
            token_env="TIP_GH_TOKEN",
            command_timeout_seconds=5.0,
            asset_timeout_seconds=5.0,
        )

        def remote_asset(name: str, *, state: str = "uploaded") -> dict:
            expectation = expectations[name]
            return {
                "name": name,
                "state": state,
                "size": expectation.size,
                "url": f"https://api.github.com/repos/example/updates/releases/assets/{len(name)}",
                "browser_download_url": (
                    "https://github.com/example/updates/releases/download/"
                    f"{context['release']['tag']}/{name}"
                ),
            }

        def release(*, draft: bool, assets: list[dict]) -> dict:
            return {
                "id": 42,
                "tag_name": context["release"]["tag"],
                "target_commitish": "main",
                "name": publication.expected_release_title(context),
                "body": publication.expected_release_notes(context),
                "draft": draft,
                "prerelease": False,
                "assets": assets,
            }

        class StatefulRunner:
            def __init__(self) -> None:
                self.release: dict | None = None
                self.mutations: list[tuple[str, str | None]] = []
                self.downloads: list[tuple[str, str, bool]] = []
                self.live_rollout_phases: list[str] = []
                self.retained_audit_phases: list[str] = []
                self.ambiguous_once: str | None = None
                self.ambiguous_consumed = False
                self.latest_mismatch = False

            def lookup_authenticated_release(self, _phase, _repository, _tag):
                return json.loads(json.dumps(self.release)) if self.release is not None else None

            def fetch_json(self, _phase, url, *, authenticated, allow_not_found=False):
                self.assert_anonymous(authenticated)
                if url.endswith("/commits/main"):
                    return {"sha": context["release"]["commit"]}
                if "/releases/tags/" in url and self.release is not None and not self.release["draft"]:
                    return json.loads(json.dumps(self.release))
                if allow_not_found:
                    return None
                raise publication.PublicationError("published Tip release is not anonymously reachable")

            @staticmethod
            def assert_anonymous(authenticated: bool) -> None:
                if authenticated:
                    raise AssertionError("public lookup unexpectedly requested authentication")

            def download(self, phase, _url, _destination, expectation, *, authenticated, api_asset=False):
                self.downloads.append((phase, expectation.name, authenticated))

            def gh(self, _phase, arguments, *, payload_path, payload_size):
                del payload_path, payload_size
                if arguments[:3] == ["api", "--method", "POST"]:
                    self.mutations.append(("create", None))
                    self.release = release(draft=True, assets=[])
                    self._maybe_ambiguous("create")
                    return
                if arguments[:2] == ["release", "upload"]:
                    name = Path(arguments[3]).name
                    self.mutations.append(("upload", name))
                    assert self.release is not None
                    self.release["assets"].append(remote_asset(name))
                    self._maybe_ambiguous("upload")
                    return
                if arguments[:3] == ["api", "--method", "PATCH"]:
                    self.mutations.append(("publish", None))
                    assert self.release is not None
                    self.release["draft"] = False
                    self._maybe_ambiguous("publish")
                    return
                raise AssertionError(f"unexpected mutation arguments: {arguments!r}")

            def _maybe_ambiguous(self, operation: str) -> None:
                if self.ambiguous_once == operation and not self.ambiguous_consumed:
                    self.ambiguous_consumed = True
                    raise publication.PublicationError(
                        f"simulated ambiguous {operation} result after remote success"
                    )

        def invoke(runner: StatefulRunner) -> int:
            def live_rollout(_runner, _repository, _directory, phase_prefix):
                runner.live_rollout_phases.append(phase_prefix)
                if phase_prefix == "pre-publication latest" and (
                    runner.release is None or runner.release["draft"]
                ):
                    predecessor = b"predecessor\n"
                    return {}, predecessor.decode(), predecessor, predecessor
                manifest_bytes = (
                    b"mismatching latest\n"
                    if runner.latest_mismatch and phase_prefix == "anonymous latest"
                    else candidate_manifest_bytes
                )
                return (
                    {},
                    candidate_appcast_bytes.decode(),
                    manifest_bytes,
                    candidate_appcast_bytes,
                )

            def audit_retained(
                _runner, _context, _manifest, _appcast, _directory, *, phase_prefix
            ):
                runner.retained_audit_phases.append(phase_prefix)

            with mock.patch.dict(os.environ, {"TIP_GH_TOKEN": "fixture-token"}, clear=False), mock.patch.object(
                publication, "preflight_local_inputs", return_value=dist
            ), mock.patch.object(publication, "verify_context", return_value=context), mock.patch.object(
                publication,
                "build_local_asset_expectations",
                return_value=(expectations, args.expected_sha256sums_sha256),
            ), mock.patch.object(publication, "validate_local_candidate"), mock.patch.object(
                publication, "PublicationRunner", return_value=runner
            ), mock.patch.object(publication, "fetch_live_rollout", side_effect=live_rollout), mock.patch.object(
                publication.rollout, "validate_live_tip_publication_state"
            ), mock.patch.object(publication, "validate_candidate_manifest"), mock.patch.object(
                publication, "audit_retained_enclosures", side_effect=audit_retained
            ):
                return publication.run_publish(args)

        normal = StatefulRunner()
        self.assertEqual(invoke(normal), 0)
        self.assertEqual(normal.mutations[0], ("create", None))
        self.assertEqual(normal.mutations[-1], ("publish", None))
        self.assertEqual(
            [name for operation, name in normal.mutations if operation == "upload"],
            list(sorted(names)),
        )
        anonymously_audited = {
            name for phase, name, authenticated in normal.downloads if not authenticated
        }
        self.assertEqual(anonymously_audited, set(names))
        self.assertEqual(
            normal.live_rollout_phases,
            [
                "pre-publication latest",
                "final pre-publication latest",
                "anonymous latest",
            ],
        )
        self.assertEqual(
            normal.retained_audit_phases,
            ["pre-publication", "final pre-publication", "anonymous post-publication"],
        )

        existing = StatefulRunner()
        existing.release = release(draft=False, assets=[remote_asset(name) for name in names])
        self.assertEqual(invoke(existing), 0)
        self.assertEqual(existing.mutations, [])
        self.assertEqual(
            {name for _phase, name, authenticated in existing.downloads if authenticated},
            set(names),
        )
        self.assertEqual(
            {name for _phase, name, authenticated in existing.downloads if not authenticated},
            set(names),
        )

        for ambiguous_operation in ("create", "upload", "publish"):
            with self.subTest(ambiguous_operation=ambiguous_operation):
                interrupted = StatefulRunner()
                interrupted.ambiguous_once = ambiguous_operation
                with self.assertRaisesRegex(publication.PublicationError, "ambiguous"):
                    invoke(interrupted)
                self.assertEqual(invoke(interrupted), 0)
                self.assertEqual(
                    sum(operation == "create" for operation, _name in interrupted.mutations), 1
                )
                self.assertEqual(
                    sum(operation == "publish" for operation, _name in interrupted.mutations), 1
                )
                uploaded_names = [
                    name for operation, name in interrupted.mutations if operation == "upload"
                ]
                self.assertEqual(uploaded_names, list(sorted(names)))

        starter = StatefulRunner()
        starter.release = release(
            draft=True, assets=[remote_asset(names[0], state="starter")]
        )
        with self.assertRaisesRegex(publication.PublicationError, "starter asset automatically"):
            invoke(starter)
        self.assertEqual(starter.mutations, [])

        mismatching_draft = StatefulRunner()
        mismatching_draft.release = release(draft=True, assets=[])
        mismatching_draft.release["name"] = "unrelated draft"
        with self.assertRaisesRegex(publication.PublicationError, "metadata mismatch"):
            invoke(mismatching_draft)
        self.assertEqual(mismatching_draft.mutations, [])

        latest_mismatch = StatefulRunner()
        latest_mismatch.latest_mismatch = True
        with self.assertRaisesRegex(publication.PublicationError, "anonymous latest rollout manifest"):
            invoke(latest_mismatch)
        mutation_snapshot = list(latest_mismatch.mutations)
        with self.assertRaisesRegex(publication.PublicationError, "anonymous latest rollout manifest"):
            invoke(latest_mismatch)
        self.assertEqual(latest_mismatch.mutations, mutation_snapshot)

    def test_tip_publication_run_publish_rejects_live_advance_before_patch(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_final_live_race_test",
            SCRIPT_DIR / "tip_release_publication.py",
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        dist = root / "dist"
        dist.mkdir()
        candidate = dist / "candidate.pkg"
        candidate.write_bytes(b"candidate\n")
        expectation = publication.AssetExpectation(
            name=candidate.name,
            path=candidate,
            size=candidate.stat().st_size,
            sha256=hashlib.sha256(candidate.read_bytes()).hexdigest(),
        )
        expectations = {candidate.name: expectation}
        commit = "a" * 40
        context = {
            "release": {
                "commit": commit,
                "tag": "tip-" + "a" * 12,
                "shortSha": "a" * 12,
                "buildNumber": "35.15.21",
            },
            "rollout": {"role": "transition"},
            "publication": {"repository": "example/updates"},
        }
        args = mock.Mock(
            dist_dir=str(dist),
            context=str(root / "context.json"),
            digest=str(root / "context.json.sha256"),
            stable_appcast=str(root / "stable.xml"),
            approved_source_root=str(root),
            trusted_tooling_root=str(root),
            expected_context_sha256="b" * 64,
            expected_sha256sums_sha256="c" * 64,
            token_env="TIP_GH_TOKEN",
            command_timeout_seconds=5.0,
            asset_timeout_seconds=5.0,
        )
        complete_draft = publication.ReleasePlan(
            release_id=42,
            state="draft",
            remote_assets=(),
            missing_assets=(),
        )
        initial_bytes = b"initial-live-state\n"
        advanced_bytes = b"advanced-live-state\n"
        validation_digests: list[str] = []

        def validate_live(_context, _manifest, _appcast, digest, _candidate_commit):
            validation_digests.append(digest)
            if len(validation_digests) == 2:
                raise publication.rollout.RolloutError("live rollout advanced")

        with mock.patch.dict(os.environ, {"TIP_GH_TOKEN": "fixture-token"}, clear=False), mock.patch.object(
            publication, "preflight_local_inputs", return_value=dist
        ), mock.patch.object(publication, "verify_context", return_value=context), mock.patch.object(
            publication,
            "build_local_asset_expectations",
            return_value=(expectations, args.expected_sha256sums_sha256),
        ), mock.patch.object(publication, "validate_local_candidate"), mock.patch.object(
            publication, "PublicationRunner", return_value=object()
        ), mock.patch.object(publication, "fetch_live_main", return_value=commit) as main_fetch, mock.patch.object(
            publication, "fetch_release", return_value={"id": 42}
        ), mock.patch.object(
            publication, "validate_release_metadata", return_value=complete_draft
        ), mock.patch.object(
            publication,
            "fetch_live_rollout",
            side_effect=[
                ({}, "initial appcast", initial_bytes, b"initial appcast"),
                ({}, "advanced appcast", advanced_bytes, b"advanced appcast"),
            ],
        ) as live_fetch, mock.patch.object(
            publication.rollout,
            "validate_live_tip_publication_state",
            side_effect=validate_live,
        ), mock.patch.object(publication, "audit_retained_enclosures") as retained_audit, mock.patch.object(
            publication, "audit_remote_release_assets"
        ), mock.patch.object(publication, "create_draft") as create, mock.patch.object(
            publication, "publish_draft"
        ) as publish:
            with self.assertRaisesRegex(
                publication.PublicationError,
                "live Tip predecessor state is unsafe: live rollout advanced",
            ):
                publication.run_publish(args)

        self.assertEqual(main_fetch.call_count, 2)
        self.assertEqual(live_fetch.call_count, 2)
        self.assertEqual(
            validation_digests,
            [hashlib.sha256(initial_bytes).hexdigest(), hashlib.sha256(advanced_bytes).hexdigest()],
        )
        retained_audit.assert_called_once()
        create.assert_not_called()
        publish.assert_not_called()

    def test_tip_publication_retained_enclosure_audit_rejects_missing_changed_or_wrong_url(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_retained_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        enclosure_bytes = b"retained preparer enclosure\n"
        repository = "example/updates"
        name = "RepoPrompt-tip-aaaaaaaaaaaa-35.15.18.zip"
        item = {
            "role": "preparer",
            "tag": "tip-aaaaaaaaaaaa",
            "url": f"https://github.com/{repository}/releases/download/tip-aaaaaaaaaaaa/{name}",
            "buildNumber": "35.15.18",
            "marketingVersion": "1.3.0",
            "minimumSystemVersion": "13.0",
            "minimumUpdateVersion": None,
            "installationType": "application",
            "enclosureName": name,
            "enclosureSize": len(enclosure_bytes),
            "enclosureSha256": hashlib.sha256(enclosure_bytes).hexdigest(),
            "edSignature": "fixture-signature",
            "rolloutManifestSha256": None,
            "rolloutManifestName": None,
        }
        manifest = {
            "channel": "tip",
            "updateRepository": repository,
            "currentRole": "preparer",
            "appcastItems": [item],
        }
        context = {
            "sparkle": {"minimumSystemVersion": "13.0", "updateRepository": repository},
            "release": {"appName": "RepoPrompt"},
        }
        appcast = publication.rollout.render_appcast(manifest)
        retained = publication.retained_enclosure_expectations(context, manifest, appcast)
        self.assertEqual(len(retained), 1)
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        downloaded = root / name
        publication._stream_worker_response(
            io.BytesIO(enclosure_bytes),
            downloaded,
            maximum_bytes=retained[0].size,
            expected_size=retained[0].size,
            expected_sha256=retained[0].sha256,
        )
        self.assertEqual(downloaded.read_bytes(), enclosure_bytes)
        changed_output = root / "changed.zip"
        with self.assertRaisesRegex(publication.PublicationError, "size mismatch|SHA-256 mismatch"):
            publication._stream_worker_response(
                io.BytesIO(b"changed\n"),
                changed_output,
                maximum_bytes=retained[0].size,
                expected_size=retained[0].size,
                expected_sha256=retained[0].sha256,
            )
        self.assertFalse(changed_output.exists())

        class MissingRunner:
            def download(self, *_args, **_kwargs) -> None:
                raise publication.PublicationError("HTTP GET failed with status 404")

        with self.assertRaisesRegex(publication.PublicationError, "status 404"):
            publication.audit_retained_enclosures(
                MissingRunner(), context, manifest, appcast, root / "missing", phase_prefix="test"
            )
        wrong = json.loads(json.dumps(manifest))
        wrong["appcastItems"][0]["url"] = wrong["appcastItems"][0]["url"].replace(name, "other.zip")
        with self.assertRaisesRegex(publication.rollout.RolloutError, "URL mismatch"):
            publication.retained_enclosure_expectations(context, wrong, appcast)

    def test_tip_candidate_manifest_binds_artifact_manifest_and_newest_enclosure_bytes(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_candidate_binding_test",
            SCRIPT_DIR / "tip_release_publication.py",
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        context = {
            "release": {
                "tag": "tip-aaaaaaaaaaaa",
                "commit": "a" * 40,
                "marketingVersion": "1.3.0",
                "buildNumber": "35.15.21",
            },
            "rollout": {
                "role": "transition",
                "signingIdentity": "successor",
                "runtimeSecureStorageMigrationPhase": "disabled",
                "eligibilityProfile": "tip-rollout-v1",
                "installationType": "package",
                "predecessors": [],
            },
            "applicationSigning": {
                "bundleIdentifier": "com.repoprompt.ce",
                "teamIdentifier": "69N6K965SF",
            },
        }
        enclosure = publication.AssetExpectation(
            "RepoPrompt-tip-aaaaaaaaaaaa-35.15.21.pkg",
            Path("/fixture/enclosure.pkg"),
            123,
            "1" * 64,
        )
        artifact = publication.AssetExpectation(
            "RepoPrompt-tip-aaaaaaaaaaaa-35.15.21-artifact-manifest.json",
            Path("/fixture/artifact.json"),
            45,
            "2" * 64,
        )
        expectations = {enclosure.name: enclosure, artifact.name: artifact}
        normalized = {
            "sourceTag": context["release"]["tag"],
            "releaseCommit": context["release"]["commit"],
            "currentRole": "transition",
            "signingIdentity": "successor",
            "bundleIdentifier": "com.repoprompt.ce",
            "teamIdentifier": "69N6K965SF",
            "marketingVersion": "1.3.0",
            "buildNumber": "35.15.21",
            "migrationPhase": "disabled",
            "eligibilityProfile": "tip-rollout-v1",
            "appArtifactManifest": {"name": artifact.name, "sha256": artifact.sha256},
            "appcastItems": [
                {
                    "tag": context["release"]["tag"],
                    "role": "transition",
                    "enclosureName": enclosure.name,
                    "enclosureSize": enclosure.size,
                    "enclosureSha256": enclosure.sha256,
                }
            ],
        }
        with mock.patch.object(
            publication.rollout, "validate_tip_manifest_appcast", return_value=normalized
        ):
            publication.validate_candidate_manifest(context, {}, "fixture", expectations)
            for field, changed, message in (
                ("appArtifactManifest", {"name": artifact.name, "sha256": "3" * 64}, "appArtifactManifest"),
                ("enclosureName", "other.pkg", "newest enclosure"),
                ("enclosureSize", 124, "newest enclosure"),
                ("enclosureSha256", "4" * 64, "newest enclosure"),
            ):
                with self.subTest(field=field):
                    mutated = json.loads(json.dumps(normalized))
                    if field == "appArtifactManifest":
                        mutated[field] = changed
                    else:
                        mutated["appcastItems"][0][field] = changed
                    with mock.patch.object(
                        publication.rollout,
                        "validate_tip_manifest_appcast",
                        return_value=mutated,
                    ), self.assertRaisesRegex(publication.PublicationError, message):
                        publication.validate_candidate_manifest(
                            context, {}, "fixture", expectations
                        )

    def test_tip_publication_supervisor_timeout_reaps_complete_process_group(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_timeout_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        for value in ("nan", "inf", "-inf", "3600.1"):
            with self.subTest(rejected_timeout=value), self.assertRaises(
                publication.argparse.ArgumentTypeError
            ):
                publication.positive_float(value)
        self.assertEqual(publication.positive_float("3600"), 3600.0)
        with self.assertRaisesRegex(publication.PublicationError, "must be finite"):
            publication.PublicationRunner(
                work_dir=SCRIPT_DIR,
                dist_dir=SCRIPT_DIR,
                total_asset_bytes=0,
                token_env="TIP_GH_TOKEN",
                command_timeout=float("inf"),
                asset_timeout=1.0,
            )
        self.assertFalse((SCRIPT_DIR / "supervise_transition_package_phase.py").exists())
        self.assertTrue((SCRIPT_DIR / "supervise_release_phase.py").is_file())

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        pid_file = root / "descendant.pid"
        worker = root / "hang.py"
        worker.write_text(
            "import os, signal, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "    while True: time.sleep(1)\n"
            f"open({str(pid_file)!r}, 'w').write(str(child))\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "while True: time.sleep(1)\n",
            encoding="utf-8",
        )
        runner = publication.PublicationRunner(
            work_dir=root,
            dist_dir=root,
            total_asset_bytes=0,
            token_env="TIP_GH_TOKEN",
            command_timeout=0.25,
            asset_timeout=0.25,
        )
        with self.assertRaisesRegex(publication.PublicationError, "exit status 124"):
            runner.run_material("publication timeout cleanup", [sys.executable, str(worker)])
        descendant = int(pid_file.read_text(encoding="ascii"))
        with self.assertRaises(ProcessLookupError):
            os.kill(descendant, 0)

    def test_tip_publication_http_worker_streams_and_removes_invalid_partial_files(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_stream_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        class ChunkedResponse:
            def __init__(self, value: bytes) -> None:
                self.value = value
                self.offset = 0
                self.read_sizes: list[int] = []

            def read(self, size: int) -> bytes:
                self.read_sizes.append(size)
                result = self.value[self.offset : self.offset + size]
                self.offset += len(result)
                return result

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        body = (b"a" * (1024 * 1024)) + (b"b" * 97)
        response = ChunkedResponse(body)
        output = root / "asset.bin"
        publication._stream_worker_response(
            response,
            output,
            maximum_bytes=len(body),
            expected_size=len(body),
            expected_sha256=hashlib.sha256(body).hexdigest(),
        )
        self.assertEqual(output.read_bytes(), body)
        self.assertGreater(len(response.read_sizes), 2)
        self.assertLessEqual(max(response.read_sizes), 1024 * 1024)

        oversized = root / "oversized.bin"
        with self.assertRaisesRegex(publication.PublicationError, "exceeded maximum"):
            publication._stream_worker_response(
                ChunkedResponse(b"changed"),
                oversized,
                maximum_bytes=3,
                expected_size=None,
                expected_sha256=None,
            )
        self.assertFalse(oversized.exists())

        changed = root / "changed.bin"
        with self.assertRaisesRegex(publication.PublicationError, "SHA-256 mismatch"):
            publication._stream_worker_response(
                ChunkedResponse(b"changed"),
                changed,
                maximum_bytes=7,
                expected_size=7,
                expected_sha256="0" * 64,
            )
        self.assertFalse(changed.exists())

    def test_tip_publication_authenticated_lookup_paginates_to_find_draft(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "tip_release_publication_lookup_test", SCRIPT_DIR / "tip_release_publication.py"
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        publication = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = publication
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(publication)

        tag = "tip-" + ("a" * 12)
        first_page = [{"tag_name": f"other-{position}"} for position in range(100)]
        expected = {"tag_name": tag, "draft": True, "id": 42}
        pages = iter([first_page, [expected]])

        class Response:
            status = 200

            def __init__(self, url: str, value: object) -> None:
                self.url = url
                self.value = json.dumps(value).encode("utf-8")

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback) -> None:
                return None

            def geturl(self) -> str:
                return self.url

            def read(self, size: int) -> bytes:
                return self.value[:size]

        def urlopen(request, timeout: int):
            self.assertEqual(timeout, 30)
            return Response(request.full_url, next(pages))

        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        output = root / "lookup.json"
        args = mock.Mock(
            repository="example/updates",
            tag=tag,
            output=str(output),
            maximum_pages=3,
            token_env="TIP_GH_TOKEN",
        )
        with mock.patch.dict(os.environ, {"TIP_GH_TOKEN": "fixture-secret"}), mock.patch.object(
            publication.GITHUB_URL_OPENER, "open", side_effect=urlopen
        ):
            publication.run_worker_release_lookup(args)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"release": expected})

        request = publication.urllib.request.Request(
            "https://api.github.com/repos/example/updates/releases/assets/42",
            headers={"Authorization": "Bearer fixture-secret"},
        )
        redirected = publication.GitHubRedirectHandler().redirect_request(
            request,
            None,
            302,
            "Found",
            {},
            "https://release-assets.githubusercontent.com/github-production-release-asset/file",
        )
        self.assertIsNotNone(redirected)
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaisesRegex(publication.PublicationError, "unreviewed host"):
            publication.GitHubRedirectHandler().redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "https://example.invalid/file",
            )

    def test_tip_appcast_generation_uses_shared_rollout_authority_and_crypto_verifier(self) -> None:
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        generator = tip_script.split("generate_tip_rollout_appcast() {", 1)[1].split("\n}", 1)[0]

        self.assertIn('python3 "$ROLLOUT_TOOL" predecessor-values-from-context', generator)
        self.assertIn('python3 "$ROLLOUT_TOOL" generate-from-context', generator)
        self.assertIn('python3 "$ROLLOUT_TOOL" validate-from-context', generator)
        self.assertNotIn('--declaration "$ROLLOUT_DECLARATION"', generator)
        self.assertNotIn('--policy "$APPLE_IDENTITY_POLICY"', generator)
        self.assertIn('local rollout_context_args=(--enclosure "$ENCLOSURE")', generator)
        self.assertIn('--appcast-output "$APPCAST"', generator)
        self.assertIn('--manifest-output "$ROLLOUT_MANIFEST"', generator)
        self.assertIn('"$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE"', generator)
        self.assertIn('verify_sparkle_signature.swift', generator)
        self.assertNotIn("validate_generated_tip_appcast", tip_script)
        self.assertNotIn("label_generated_tip_appcast", tip_script)
        self.assertNotIn("generate_appcast", generator)

    def test_tip_appcast_generation_supports_zero_predecessors_on_macos_bash(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        root = temp_dir / "source"
        scripts = root / "Scripts"
        sign_update = root / "Vendor" / "Sparkle" / "bin" / "sign_update"
        dist = root / "dist"
        scripts.mkdir(parents=True)
        sign_update.parent.mkdir(parents=True)
        dist.mkdir()

        shutil.copy2(SCRIPT_DIR / "main_tip_release.sh", scripts / "main_tip_release.sh")
        (scripts / "load_release_metadata.sh").write_text(
            """\
load_verified_tip_release_context() {
    APP_NAME=RepoPrompt
    DISPLAY_NAME="RepoPrompt CE"
    MARKETING_VERSION=1.3.0
    TIP_BUILD_NUMBER=35.15.17
    TIP_COMMIT=0123456789abcdef0123456789abcdef01234567
    TIP_SHORT_SHA=0123456789ab
    TIP_TAG=tip-0123456789ab
    ARCHIVE_BASENAME=RepoPrompt-tip-0123456789ab-35.15.17
    ROLLOUT_CHANNEL=tip
    ROLLOUT_ROLE=preparer
    ROLLOUT_IDENTITY=legacy
    ROLLOUT_INSTALLATION_TYPE=application
    ROLLOUT_UPDATE_REPOSITORY=repoprompt/repoprompt-ce-tip-updates
    REPOPROMPT_IDENTITY_MIGRATION_PHASE=legacy-preparer
    TIP_PUBLICATION_TARGET=main
    TIP_PUBLICATION_DRAFT=false
    TIP_PUBLICATION_PRERELEASE=false
    BUNDLE_ID=com.pvncher.repoprompt.ce
    SIGNING_TEAM_ID=648A27MST5
}
""",
            encoding="utf-8",
        )
        (scripts / "release_sentry_symbols.sh").write_text("\n", encoding="utf-8")
        rollout_capture = temp_dir / "rollout-arguments.json"
        (scripts / "stable_rollout.py").write_text(
            """\
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

command = sys.argv[1]
if command == "predecessor-values-from-context":
    pass
elif command == "generate-from-context":
    arguments = sys.argv[2:]
    Path(os.environ["FAKE_ROLLOUT_CAPTURE"]).write_text(json.dumps(arguments), encoding="utf-8")
    for flag, content in (("--appcast-output", "<rss/>\\n"), ("--manifest-output", "{}\\n")):
        output = Path(arguments[arguments.index(flag) + 1])
        output.write_text(content, encoding="utf-8")
elif command == "validate-from-context":
    pass
else:
    raise SystemExit(f"unexpected command: {command}")
""",
            encoding="utf-8",
        )
        (scripts / "apple_identity_policy.json").write_text("{}\n", encoding="utf-8")
        (root / "tip-rollout.json").write_text('{"predecessors": []}\n', encoding="utf-8")
        (root / "version.env").write_text("BUILD_NUMBER=35\n", encoding="utf-8")
        sign_update.write_text("#!/usr/bin/env bash\nprintf 'fixture-signature\\n'\n", encoding="utf-8")
        sign_update.chmod(0o755)
        enclosure = dist / "RepoPrompt-tip-0123456789ab-35.15.17.zip"
        enclosure.write_text("fixture enclosure\n", encoding="utf-8")
        (dist / "RepoPrompt-tip-0123456789ab-35.15.17-artifact-manifest.json").write_text(
            "{}\n",
            encoding="utf-8",
        )

        env = os.environ.copy()
        env.update(
            {
                "FAKE_ROLLOUT_CAPTURE": str(rollout_capture),
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(root),
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(root),
                "SPARKLE_PRIVATE_KEY": "fixture-private-key",
                "DIST_DIR": str(dist),
            }
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; initialize_tip_release_context unit-test; TMP_DIR="$(mktemp -d)"; '
                "derive_sparkle_public_key() { printf 'fixture-public-key\\n'; }; "
                "plutil() { printf 'fixture-public-key\\n'; }; "
                "xcrun() { return 0; }; "
                "generate_tip_rollout_appcast",
                "bash",
                str(scripts / "main_tip_release.sh"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((dist / "appcast.xml").is_file())
        self.assertTrue((dist / "identity-rollout.json").is_file())
        rollout_arguments = json.loads(rollout_capture.read_text(encoding="utf-8"))
        self.assertNotIn("--declaration", rollout_arguments)
        self.assertNotIn("--policy", rollout_arguments)
        self.assertNotIn("--predecessor-manifest", rollout_arguments)

    def test_release_sentry_runtime_wiring_uses_protected_dsn_and_stable_resolution(self) -> None:
        root = SCRIPT_DIR.parent
        package_manifest = (root / "Package.swift").read_text(encoding="utf-8")
        package_resolved = json.loads((root / "Package.resolved").read_text(encoding="utf-8"))
        notice_inventory = (root / "ThirdPartyLicenses" / "swiftpm" / "inventory.tsv").read_text(encoding="utf-8")
        release_workflow = (root / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        ci_workflow = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        release_candidate_workflow = (root / ".github" / "workflows" / "release-candidate.yml").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        staged_signing_script = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        bootstrap_source = (
            root
            / "Sources"
            / "RepoPrompt"
            / "Infrastructure"
            / "Telemetry"
            / "SentryTelemetryBootstrap.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('.package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.17.1")', package_manifest)
        self.assertIn('let sentryDependency = Target.Dependency.product(name: "Sentry", package: "sentry-cocoa")', package_manifest)
        self.assertIn('repoPromptAppDependencies.append(sentryDependency)', package_manifest)
        self.assertIn('repoPromptAppSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertIn('repoPromptTestDependencies.append(sentryDependency)', package_manifest)
        self.assertIn('repoPromptTestSwiftSettings.append(.define("REPOPROMPT_SENTRY_ENABLED"))', package_manifest)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', release_workflow)
        self.assertIn('name: Sentry-enabled Build', ci_workflow)
        self.assertIn('REPOPROMPT_ENABLE_SENTRY: "1"', ci_workflow)
        self.assertIn('swift build --product RepoPrompt', ci_workflow)
        self.assertIn('swift test --filter SentryTelemetryPrivacyTests', ci_workflow)
        self.assertIn('smoke_packaged_mcp_roundtrip.sh', release_candidate_workflow)
        self.assertIn('".build/release/RepoPrompt.app"', release_candidate_workflow)
        self.assertIn("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}", release_workflow)
        self.assertIn("REPOPROMPT_ENABLE_SENTRY=1", release_script)
        self.assertIn('if [[ -n "${SENTRY_DSN:-}" ]]; then', staged_signing_script)
        self.assertIn('plutil -replace RepoPromptSentryDSN -string "$SENTRY_DSN"', staged_signing_script)
        self.assertIn('Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN")', bootstrap_source)
        self.assertIn('REPOPROMPT_TELEMETRY_DISABLED', bootstrap_source)
        self.assertIn('GlobalSettingsStore.shared.telemetryEnabled()', bootstrap_source)
        self.assertIn('options.beforeSend', bootstrap_source)
        self.assertIn('options.enableCaptureFailedRequests = false', bootstrap_source)
        self.assertIn('options.enableAutoSessionTracking = false', bootstrap_source)
        self.assertIn('event.request = nil', bootstrap_source)
        self.assertIn('event.user = nil', bootstrap_source)
        self.assertIn('event.serverName = nil', bootstrap_source)
        self.assertIn('deviceIdentifierKeys', bootstrap_source)
        self.assertIn('geoPayloadKeys', bootstrap_source)
        self.assertIn('event.dist = nil', bootstrap_source)
        self.assertIn('scrub(stacktrace: event.stacktrace)', bootstrap_source)
        self.assertIn('event.debugMeta?.forEach', bootstrap_source)
        self.assertIn('options.tracesSampleRate = performanceTracingEnabled ? 0.05 : 0', bootstrap_source)
        self.assertIn('#if DEBUG\n                if let value = ProcessInfo.processInfo.environment["REPOPROMPT_SENTRY_DSN"]', bootstrap_source)
        self.assertIn('Official Sentry-enabled release publishing requires SENTRY_AUTH_TOKEN', release_script)
        self.assertIn('SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"', release_script)
        self.assertIn('prepare_sentry_release', release_script)
        self.assertIn('finalize_sentry_release', release_script)
        self.assertNotIn('record_sentry_production_deploy', release_script)
        self.assertIn('record_verified_sentry_deploy_if_needed', promote_script)

        pins = {pin["identity"]: pin for pin in package_resolved["pins"]}
        self.assertEqual(pins["sentry-cocoa"]["state"]["version"], "9.17.1")
        self.assertIn("sentry-cocoa\t9.17.1\thttps://github.com/getsentry/sentry-cocoa", notice_inventory)

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

    def test_secret_free_swiftpm_commands_scrub_tokens(self) -> None:
        helper = SCRIPT_DIR / "run_without_github_tokens.sh"
        result = subprocess.run(
            [
                str(helper),
                # Re-enter the wrapper to verify nesting remains harmless.
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
        universal_builder = (SCRIPT_DIR / "build_swiftpm_release_products.sh").read_text(encoding="utf-8")
        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        workflows_dir = SCRIPT_DIR.parent / ".github" / "workflows"
        release_workflow = (workflows_dir / "release.yml").read_text(encoding="utf-8")
        tip_workflow = (workflows_dir / "main-tip.yml").read_text(encoding="utf-8")

        release_stage_job = release_workflow.split("\n  stage:", 1)[1].split("\n  publish:", 1)[0]
        tip_stage_job = tip_workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]
        release_stage_function = release_script.split("stage_publish_release() {", 1)[1].split("\n}", 1)[0]
        tip_stage_function = tip_script.split("stage_tip() {", 1)[1].split("\n}", 1)[0]
        release_resolver = release_script.split("resolve_without_lockfile_drift() {", 1)[1].split("\n}", 1)[0]
        tip_resolver = tip_script.split("resolve_without_lockfile_drift() {", 1)[1].split("\n}", 1)[0]

        self.assertIn("run: ./trusted-control-plane/Scripts/release.sh stage-publish", release_stage_job)
        self.assertIn("run: ./trusted-control-plane/Scripts/main_tip_release.sh stage", tip_stage_job)
        self.assertIn("resolve_without_lockfile_drift", release_stage_function)
        self.assertIn("resolve_without_lockfile_drift", tip_stage_function)
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve', release_resolver)
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve', tip_resolver)
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY', release_stage_function)
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY', tip_stage_function)
        self.assertIn(
            'REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS"',
            package_script,
        )
        self.assertIn('"$RUN_WITHOUT_GITHUB_TOKENS" swift build', universal_builder)
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

    def test_release_metadata_parser_accepts_three_component_tip_build(self) -> None:
        root = self.make_metadata_root()
        metadata_path = root / "version.env"
        metadata_path.write_text(
            metadata_path.read_text(encoding="utf-8").replace("BUILD_NUMBER=1", "BUILD_NUMBER=28.7.95"),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata "{root}"; printf "%s\n" "$BUILD_NUMBER"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "28.7.95\n")

    def test_release_metadata_tip_projection_helper_and_call_sites_are_removed(self) -> None:
        consumers = (
            SCRIPT_DIR / "load_release_metadata.sh",
            SCRIPT_DIR / "main_tip_release.sh",
            SCRIPT_DIR / "validate_staged_release.sh",
            SCRIPT_DIR / "sign_staged_release.sh",
        )
        for path in consumers:
            with self.subTest(path=path.name):
                source = path.read_text(encoding="utf-8")
                self.assertNotIn("load_release_metadata_with_identity_projection", source)
        tip_release = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        self.assertNotIn("stable_rollout.py packaging-context", tip_release)
        self.assertNotIn("load_release_metadata ", tip_release)

    def test_release_metadata_loader_preserves_stable_identity_without_tip_contract(self) -> None:
        root = self.make_metadata_root()

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata "{root}"; '
                'printf "%s|%s\\n" "$BUNDLE_ID" "$SIGNING_TEAM_ID"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "com.pvncher.repoprompt.ce|648A27MST5\n")

    def test_staged_signer_verifies_context_before_profile_validation(self) -> None:
        source = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")

        verification = source.index("load_verified_tip_release_context")
        profile_validation = source.index("profile_app_identifier=")
        self.assertLess(verification, profile_validation)
        self.assertIn("signing-mode-from-context", source)
        self.assertNotIn("load_release_metadata_with_identity_projection", source)
        self.assertIn('"${REPOPROMPT_TIP_ARCHIVE_CONTRACT:-}"', source)

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

    def make_universal_architecture_fixture(self) -> tuple[Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        app = temp_dir / "RepoPrompt.app"
        paths = [
            app / "Contents" / "MacOS" / "RepoPrompt",
            app / "Contents" / "MacOS" / "repoprompt-mcp",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Sparkle",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Autoupdate",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "Updater.app"
            / "Contents"
            / "MacOS"
            / "Updater",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "XPCServices"
            / "Installer.xpc"
            / "Contents"
            / "MacOS"
            / "Installer",
            app
            / "Contents"
            / "Frameworks"
            / "Sparkle.framework"
            / "Versions"
            / "B"
            / "XPCServices"
            / "Downloader.xpc"
            / "Contents"
            / "MacOS"
            / "Downloader",
        ]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"#!/usr/bin/env bash\n# {path.name}\n", encoding="utf-8")
            path.chmod(0o755)
        fake_lipo = temp_dir / "lipo"
        fake_lipo.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
if [[ "${FAKE_THIN_HELPER:-0}" == "1" && "$path" == *repoprompt-mcp ]]; then
    printf 'arm64\n'
else
    printf 'arm64 x86_64\n'
fi
""",
            encoding="utf-8",
        )
        fake_lipo.chmod(0o755)
        return app, fake_lipo

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

    def start_unix_listener(
        self,
        socket_path: Path,
        *,
        claim_ownership_lock: bool = True,
    ) -> tuple[subprocess.Popen[str], Path]:
        ready = socket_path.with_suffix(".ready")
        accepted_connections = socket_path.with_name(f"{socket_path.name}.{time.monotonic_ns()}.accepted")
        ready.unlink(missing_ok=True)
        accepted_connections.unlink(missing_ok=True)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import fcntl, os, socket, sys\n"
                "lock_descriptor = None\n"
                "if sys.argv[4] == '1':\n"
                "    lock_descriptor = os.open(sys.argv[1] + '.lock', os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)\n"
                "    os.fchmod(lock_descriptor, 0o600)\n"
                "    fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                "listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
                "listener.bind(sys.argv[1])\n"
                "if lock_descriptor is not None:\n"
                "    metadata = os.lstat(sys.argv[1])\n"
                "    record = f'repoprompt-ce-socket-identity-v1 {metadata.st_dev} {metadata.st_ino}\\n'.encode()\n"
                "    os.ftruncate(lock_descriptor, 0)\n"
                "    assert os.write(lock_descriptor, record) == len(record)\n"
                "    os.fsync(lock_descriptor)\n"
                "listener.listen(8)\n"
                "open(sys.argv[2], 'w', encoding='utf-8').close()\n"
                "while True:\n"
                "    client, _ = listener.accept()\n"
                "    with open(sys.argv[3], 'a', encoding='utf-8') as accepted:\n"
                "        accepted.write('accepted\\n')\n"
                "        accepted.flush()\n"
                "    with client:\n"
                "        while client.recv(4096):\n"
                "            pass\n",
                os.fspath(socket_path),
                os.fspath(ready),
                os.fspath(accepted_connections),
                "1" if claim_ownership_lock else "0",
            ],
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

        def stop() -> None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if process.stderr is not None:
                process.stderr.close()

        self.addCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not ready.exists():
            if process.poll() is not None:
                self.fail(f"UNIX listener exited early: {process.stderr.read() if process.stderr else ''}")
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "UNIX listener did not become ready")
        return process, accepted_connections

    def socket_owner_process_path(self, pid: int) -> Path:
        result = self.run_socket_owner_helper("process-path", pid)
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(result.stdout.strip())

    @staticmethod
    def run_socket_owner_helper(*arguments: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "verify_packaged_mcp_socket_owner.py"), *(str(argument) for argument in arguments)],
            text=True,
            capture_output=True,
            timeout=10,
        )

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

    def make_keyboard_shortcuts_patch_fixture(self, source: str | None = None) -> tuple[Path, Path]:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        utilities = root / ".build" / "checkouts" / "KeyboardShortcuts" / "Sources" / "KeyboardShortcuts" / "Utilities.swift"
        utilities.parent.mkdir(parents=True)
        utilities.write_text(source if source is not None else self.keyboard_shortcuts_upstream_utilities(), encoding="utf-8")
        self.write_package_resolved(root, "2.3.0")
        return root, utilities

    @staticmethod
    def keyboard_shortcuts_upstream_utilities() -> str:
        return """\
import SwiftUI

#if os(macOS)
import Carbon.HIToolbox


extension String {
\t/**
\tMakes the string localizable.
\t*/
\tvar localized: String {
\t\tNSLocalizedString(self, bundle: .module, comment: self)
\t}
}


extension Data {
\tvar toString: String? { String(data: self, encoding: .utf8) }
}
"""

    @staticmethod
    def write_package_resolved(
        root: Path,
        version: str,
        revision: str = "045cf174010beb335fa1d2567d18c057b8787165",
    ) -> None:
        (root / "Package.resolved").write_text(
            json.dumps(
                {"pins": [{"identity": "keyboardshortcuts", "state": {"revision": revision, "version": version}}]},
                indent=2,
            ),
            encoding="utf-8",
        )

    @staticmethod
    def run_keyboard_shortcuts_patch(root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT_DIR / "patch_keyboard_shortcuts_resource_lookup.sh"), str(root)],
            text=True,
            capture_output=True,
        )

    def make_staged_release_fixture(
        self, *, tip_context: bool = False
    ) -> tuple[Path, Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        approved = temp_dir / "approved"
        staged = temp_dir / "staged"
        trusted = temp_dir / "trusted"
        scripts = (trusted if tip_context else temp_dir) / "Scripts"
        app = staged / ".build" / "release" / "RepoPrompt.app"
        for directory in (
            approved / "AppBundle",
            approved / "Vendor" / "Codex",
            approved / "ThirdPartyLicenses" / "fixture",
            staged / "ThirdPartyLicenses" / "fixture",
            app / "Contents" / "Frameworks" / "Sparkle.framework",
            app / "Contents" / "MacOS",
            app / "Contents" / "Resources" / "bin",
            app / "Contents" / "Resources" / "Legal" / "ThirdPartyLicenses" / "fixture",
            app / "Contents" / "Resources" / "BundledRuntimes" / "Codex" / "aarch64-apple-darwin",
            app / "Contents" / "Resources" / "BundledRuntimes" / "Codex" / "x86_64-apple-darwin",
            scripts,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        for name in (
            "apple_identity_policy.json",
            "load_release_metadata.sh",
            "stable_rollout.py",
            "validate_embedded_mcp_helper_layout.sh",
            "validate_app_architectures.sh",
            "write_app_artifact_manifest.py",
            "validate_packaged_legal.sh",
            "validate_required_swiftpm_resource_bundles.sh",
            "validate_staged_release.sh",
            "release_sentry_symbols.sh",
            "release.sh",
            "main_tip_release.sh",
            "supervise_release_phase.py",
            "tip_release_context.py",
            "tip_release_publication.py",
        ):
            shutil.copy2(SCRIPT_DIR / name, scripts / name)
            scripts.joinpath(name).chmod(0o755)
        (scripts / "codex_runtime_artifact.py").write_text(
            "#!/usr/bin/env python3\nimport os\nimport sys\nfrom pathlib import Path\n\nexpected_manifest = Path(os.environ[\"FAKE_CODEX_MANIFEST\"])\nexpected_bundle = Path(os.environ[\"FAKE_CODEX_BUNDLE\"])\nexpected = [\n    \"--manifest\",\n    str(expected_manifest),\n    \"verify-bundle\",\n    \"--arch\",\n    \"all\",\n    \"--bundle\",\n    str(expected_bundle),\n]\nif sys.argv[1:] != expected:\n    print(f\"ERROR: unexpected Codex verifier arguments: {sys.argv[1:]!r}\", file=sys.stderr)\n    raise SystemExit(64)\nif not expected_manifest.is_file():\n    print(f\"ERROR: missing approved Codex manifest: {expected_manifest}\", file=sys.stderr)\n    raise SystemExit(65)\nexpected_targets = {\"aarch64-apple-darwin\", \"x86_64-apple-darwin\"}\nif not expected_bundle.is_dir() or {path.name for path in expected_bundle.iterdir()} != expected_targets:\n    print(f\"ERROR: missing embedded Codex package targets: {expected_bundle}\", file=sys.stderr)\n    raise SystemExit(66)\ncapture = os.environ.get(\"FAKE_CODEX_CAPTURE\")\nif capture:\n    with Path(capture).open(\"a\", encoding=\"utf-8\") as handle:\n        handle.write(\" \".join(sys.argv[1:]) + \"\\n\")\nprint(\"OK: fixture Codex bundle contract.\")\n",
            encoding="utf-8",
        )
        (approved / "Vendor" / "Codex" / "manifest.json").write_text("{}\n", encoding="utf-8")
        shutil.copy2(SCRIPT_DIR.parent / "tip-rollout.json", approved / "tip-rollout.json")
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
            "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
            "__LOCAL_SECURE_STORAGE_GENERATION__": "",
            "__IDENTITY_MIGRATION_PHASE__": "disabled",
        }.items():
            template = template.replace(key, value)
        (app / "Contents" / "Info.plist").write_text(template, encoding="utf-8")
        for name in ("RepoPrompt", "repoprompt-mcp"):
            executable = app / "Contents" / "MacOS" / name
            content = "RepoPromptKeyboardShortcutsResourceLookupV1\n" if name == "RepoPrompt" else name
            executable.write_text(content, encoding="utf-8")
            executable.chmod(0o755)
        sparkle_executables = [
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Sparkle",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Autoupdate",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "Updater.app" / "Contents" / "MacOS" / "Updater",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "XPCServices" / "Installer.xpc" / "Contents" / "MacOS" / "Installer",
            app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / "XPCServices" / "Downloader.xpc" / "Contents" / "MacOS" / "Downloader",
        ]
        for executable in sparkle_executables:
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text(executable.name, encoding="utf-8")
            executable.chmod(0o755)
        (app / "Contents" / "Resources" / "repoprompt-mcp").symlink_to("../MacOS/repoprompt-mcp")
        (app / "Contents" / "Resources" / "bin" / "repoprompt-mcp").symlink_to("../../MacOS/repoprompt-mcp")
        self.write_keyboard_shortcuts_bundle(app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle")
        legal = app / "Contents" / "Resources" / "Legal"
        shutil.copy2(staged / "LICENSE", legal / "LICENSE")
        shutil.copy2(staged / "THIRD_PARTY_NOTICES.md", legal / "THIRD_PARTY_NOTICES.md")
        shutil.copy2(
            staged / "ThirdPartyLicenses" / "fixture" / "LICENSE",
            legal / "ThirdPartyLicenses" / "fixture" / "LICENSE",
        )
        (staged / "RELEASE_COMMIT").write_text("fixture-release-commit\n", encoding="utf-8")
        fake_lipo = scripts / "fake-lipo"
        fake_lipo.write_text("#!/usr/bin/env bash\nprintf 'arm64 x86_64\\n'\n", encoding="utf-8")
        fake_lipo.chmod(0o755)
        fake_codesign = scripts / "fake-codesign"
        fake_codesign.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *--extract-certificates*) exit 1 ;;
  *--entitlements*) printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\\n' ;;
  *-r-*) printf 'designated => identifier "fixture"\\n' >&2 ;;
  *) printf 'Identifier=fixture\\nTeamIdentifier=not set\\n' >&2 ;;
esac
""",
            encoding="utf-8",
        )
        fake_codesign.chmod(0o755)
        manifest = staged / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        manifest_env = os.environ.copy()
        manifest_env.update({"LIPO": str(fake_lipo), "CODESIGN": str(fake_codesign)})
        subprocess.run(
            [
                str(scripts / "write_app_artifact_manifest.py"),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=manifest_env,
            check=True,
            text=True,
            capture_output=True,
        )
        if tip_context:
            def git(root: Path, *arguments: str) -> str:
                result = subprocess.run(
                    ["git", "-C", str(root), *arguments],
                    text=True,
                    capture_output=True,
                    check=True,
                )
                return result.stdout.strip()

            for root, message in (
                (trusted, "trusted Tip tooling fixture"),
                (approved, "approved Tip source fixture"),
            ):
                git(root, "init", "-q", "--initial-branch=main")
                git(root, "config", "user.email", "tip-staged-tests@example.invalid")
                git(root, "config", "user.name", "Tip Staged Tests")
                git(root, "add", ".")
                git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)

            approved_commit = git(approved, "rev-parse", "HEAD")
            tooling_commit = git(trusted, "rev-parse", "HEAD")
            stable_appcast = temp_dir / "stable-appcast-input.xml"
            shutil.copy2(
                SCRIPT_DIR / "Fixtures" / "tip-release-context" / "v1" / "stable-appcast.xml",
                stable_appcast,
            )
            context_dir = temp_dir / "canonical-tip-context"
            context_dir.mkdir()
            context_path = context_dir / "tip-release-context.json"
            digest_path = context_dir / "tip-release-context.json.sha256"
            resolved = subprocess.run(
                [
                    sys.executable,
                    str(scripts / "tip_release_context.py"),
                    "resolve",
                    "--trusted-tooling-root",
                    str(trusted),
                    "--approved-source-root",
                    str(approved),
                    "--stable-appcast",
                    str(stable_appcast),
                    "--approved-source-commit",
                    approved_commit,
                    "--trusted-tooling-commit",
                    tooling_commit,
                    "--source-build-sequence",
                    "1521",
                    "--expected-tip-update-repository",
                    "repoprompt/repoprompt-ce-tip-updates",
                    "--output",
                    str(context_path),
                    "--digest-output",
                    str(digest_path),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(resolved.returncode, 0, resolved.stderr)
            context = json.loads(context_path.read_text(encoding="utf-8"))
            release = context["release"]
            application = context["applicationSigning"]
            rollout = context["rollout"]
            (staged / "version.env").write_text(
                "\n".join(
                    (
                        f"APP_NAME={release['appName']}",
                        f'DISPLAY_NAME="{release["displayName"]}"',
                        f"MARKETING_VERSION={release['marketingVersion']}",
                        f"BUILD_NUMBER={release['buildNumber']}",
                        f"BUNDLE_ID={application['bundleIdentifier']}",
                        f"SIGNING_TEAM_ID={application['teamIdentifier']}",
                        "",
                    )
                ),
                encoding="utf-8",
            )
            shutil.copy2(approved / "tip-rollout.json", staged / "tip-rollout.json")
            shutil.copy2(context_path, staged / "tip-release-context.json")
            shutil.copy2(digest_path, staged / "tip-release-context.json.sha256")
            (staged / "RELEASE_COMMIT").write_text(approved_commit + "\n", encoding="utf-8")

            rendered_template = (approved / "AppBundle" / "Info.plist.template").read_text(
                encoding="utf-8"
            )
            for key, value in {
                "__APP_NAME__": release["appName"],
                "__DISPLAY_NAME__": release["displayName"],
                "__BUNDLE_ID__": application["bundleIdentifier"],
                "__MARKETING_VERSION__": release["marketingVersion"],
                "__BUILD_NUMBER__": release["buildNumber"],
                "__DEBUG_SECURE_STORAGE_BACKEND__": "alternate-in-memory",
                "__SIGNING_MODE__": "release-candidate-adhoc",
                "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
                "__LOCAL_SECURE_STORAGE_GENERATION__": "",
                "__IDENTITY_MIGRATION_PHASE__": rollout[
                    "runtimeSecureStorageMigrationPhase"
                ],
            }.items():
                rendered_template = rendered_template.replace(key, str(value))
            info_path = app / "Contents" / "Info.plist"
            info_path.write_text(rendered_template, encoding="utf-8")
            subprocess.run(
                [
                    str(scripts / "write_app_artifact_manifest.py"),
                    "write",
                    "--app",
                    str(app),
                    "--output",
                    str(manifest),
                    "--expected-architectures",
                    "arm64,x86_64",
                ],
                env=manifest_env,
                check=True,
                text=True,
                capture_output=True,
            )
            (temp_dir / "tip-context-environment.json").write_text(
                json.dumps(
                    {
                        "context": str(context_path),
                        "digest": str(digest_path),
                        "stable_appcast": str(stable_appcast),
                        "expected_digest": digest_path.read_text(encoding="ascii").strip(),
                        "approved_commit": approved_commit,
                        "tooling_commit": tooling_commit,
                    }
                ),
                encoding="utf-8",
            )

        return approved, staged, scripts

    @staticmethod
    def write_keyboard_shortcuts_bundle(bundle: Path) -> None:
        resources = bundle / "Contents" / "Resources"
        (resources / "en.lproj").mkdir(parents=True, exist_ok=True)
        (bundle / "Contents" / "Info.plist").write_text("<plist/>\n", encoding="utf-8")
        (resources / "en.lproj" / "Localizable.strings").write_text('"record_shortcut" = "Record Shortcut";\n', encoding="utf-8")

    @staticmethod
    def codex_fixture_environment(approved: Path, staged: Path) -> dict[str, str]:
        app = staged / ".build" / "release" / "RepoPrompt.app"
        return {
            "FAKE_CODEX_MANIFEST": str(approved / "Vendor" / "Codex" / "manifest.json"),
            "FAKE_CODEX_BUNDLE": str(
                app / "Contents" / "Resources" / "BundledRuntimes" / "Codex"
            ),
        }

    @classmethod
    def project_staged_release_identity(
        cls,
        staged: Path,
        scripts: Path,
        bundle_id: str,
        signing_team_id: str,
    ) -> None:
        version_path = staged / "version.env"
        version = version_path.read_text(encoding="utf-8")
        version = re.sub(r"(?m)^BUNDLE_ID=.*$", f"BUNDLE_ID={bundle_id}", version)
        version = re.sub(r"(?m)^SIGNING_TEAM_ID=.*$", f"SIGNING_TEAM_ID={signing_team_id}", version)
        version_path.write_text(version, encoding="utf-8")

        app = staged / ".build" / "release" / "RepoPrompt.app"
        info_path = app / "Contents" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = bundle_id
        info_path.write_bytes(plistlib.dumps(info))

        manifest = staged / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        manifest_env = os.environ.copy()
        manifest_env.update(
            {"LIPO": str(scripts / "fake-lipo"), "CODESIGN": str(scripts / "fake-codesign")}
        )
        subprocess.run(
            [
                str(scripts / "write_app_artifact_manifest.py"),
                "write",
                "--app",
                str(app),
                "--output",
                str(manifest),
                "--expected-architectures",
                "arm64,x86_64",
            ],
            env=manifest_env,
            check=True,
            text=True,
            capture_output=True,
        )

    @classmethod
    def run_staged_validation(
        cls,
        approved: Path,
        staged: Path,
        scripts: Path,
        identity_migration_phase: str | None = None,
        release_build_number_override: str | None = None,
        tip_archive_contract: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "RELEASE_COMMIT": "fixture-release-commit",
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(staged),
                "LIPO": str(scripts / "fake-lipo"),
                "CODESIGN": str(scripts / "fake-codesign"),
                **cls.codex_fixture_environment(approved, staged),
            }
        )
        if identity_migration_phase is not None:
            env["REPOPROMPT_IDENTITY_MIGRATION_PHASE"] = identity_migration_phase
        if release_build_number_override is not None:
            env["REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE"] = release_build_number_override
        if tip_archive_contract is not None:
            env["REPOPROMPT_TIP_ARCHIVE_CONTRACT"] = tip_archive_contract
            if tip_archive_contract == "tip-rollout-v1":
                env.pop("RELEASE_COMMIT", None)
                env.pop("REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE", None)
                env.pop("BUILD_NUMBER", None)
                env.pop("GH_TOKEN", None)
                context_environment_path = approved.parent / "tip-context-environment.json"
                if context_environment_path.is_file():
                    context_environment = json.loads(
                        context_environment_path.read_text(encoding="utf-8")
                    )
                    env.update(
                        {
                            "REPOPROMPT_TIP_RELEASE_CONTEXT": context_environment["context"],
                            "REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE": context_environment[
                                "digest"
                            ],
                            "REPOPROMPT_TIP_STABLE_APPCAST": context_environment[
                                "stable_appcast"
                            ],
                            "REPOPROMPT_EXPECTED_CONTEXT_SHA256": context_environment[
                                "expected_digest"
                            ],
                            "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT": context_environment[
                                "approved_commit"
                            ],
                            "REPOPROMPT_EXPECTED_TOOLING_COMMIT": context_environment[
                                "tooling_commit"
                            ],
                        }
                    )
        return subprocess.run(
            [str(scripts / "validate_staged_release.sh")],
            env=env,
            text=True,
            capture_output=True,
        )

    @classmethod
    def run_public_app_validation(
        cls,
        approved: Path,
        staged: Path,
        scripts: Path,
        script_name: str,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        app = staged / ".build" / "release" / "RepoPrompt.app"
        artifact_manifest = staged / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
        capture = staged.parent / f"{script_name}-codex-calls.txt"
        env = os.environ.copy()
        env.update(
            {
                "RELEASE_COMMIT": "fixture-release-commit",
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(staged),
                "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(scripts),
                "TIP_COMMIT": "fixture-release-commit",
                "TIP_BUILD_NUMBER": "1.1",
                "LIPO": str(scripts / "fake-lipo"),
                "CODESIGN": str(scripts / "fake-codesign"),
                "FAKE_CODEX_CAPTURE": str(capture),
                **cls.codex_fixture_environment(approved, staged),
            }
        )
        tip_declaration = staged / "tip-rollout.json"
        if script_name == "main_tip_release.sh":
            shutil.copy2(SCRIPT_DIR.parent / "tip-rollout.json", tip_declaration)
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; TMP_DIR="$(mktemp -d)"; validate_public_app "$2" "$3" "Extracted stage fixture"',
                "bash",
                str(scripts / script_name),
                str(app),
                str(artifact_manifest),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        tip_declaration.unlink(missing_ok=True)
        return result, capture

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


class TipReleaseContextTests(unittest.TestCase):
    """Immutable setup-digest and committed-input Tip context coverage."""

    TOOL = SCRIPT_DIR / "tip_release_context.py"
    ROLLOUT_TOOL = SCRIPT_DIR / "stable_rollout.py"
    FIXTURE = SCRIPT_DIR / "Fixtures" / "tip-release-context" / "v1"
    SYNTHETIC_REPOSITORY = "example/repoprompt-ce-tip-updates"

    def run_context(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            [sys.executable, str(self.TOOL), *args],
            env=env,
            text=True,
            capture_output=True,
        )

    @staticmethod
    def git(work: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(work), *args],
            text=True,
            capture_output=True,
            check=True,
        )

    def commit_fixture_root(self, root: Path, message: str) -> str:
        self.git(root, "init", "-q", "--initial-branch=main")
        self.git(root, "config", "user.email", "tip-context-tests@example.invalid")
        self.git(root, "config", "user.name", "Tip Context Tests")
        self.git(root, "add", ".")
        self.git(root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", message)
        return self.git(root, "rev-parse", "HEAD").stdout.strip()

    def make_authority_fixture(
        self,
        *,
        application_identity_name: str | None = None,
        declaration_mutator=None,
        policy_mutator=None,
    ) -> dict[str, object]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        trusted_root = temp_dir / "trusted"
        approved_root = temp_dir / "approved"
        (trusted_root / "Scripts").mkdir(parents=True)
        approved_root.mkdir()

        policy = json.loads(
            (self.FIXTURE / "apple_identity_policy.json").read_text(encoding="utf-8")
        )
        if application_identity_name is not None:
            policy["identities"]["successor"][
                "developerIDApplicationIdentityName"
            ] = application_identity_name
        if policy_mutator is not None:
            policy_mutator(policy)
        (trusted_root / "Scripts" / "apple_identity_policy.json").write_text(
            json.dumps(policy, indent=2) + "\n", encoding="utf-8"
        )
        shutil.copy2(self.ROLLOUT_TOOL, trusted_root / "Scripts" / "stable_rollout.py")
        shutil.copy2(self.TOOL, trusted_root / "Scripts" / "tip_release_context.py")
        (trusted_root / "authority-marker.txt").write_text("trusted\n", encoding="utf-8")

        declaration = json.loads(
            (self.FIXTURE / "tip-rollout.json").read_text(encoding="utf-8")
        )
        if declaration_mutator is not None:
            declaration_mutator(declaration)
        (approved_root / "tip-rollout.json").write_text(
            json.dumps(declaration, indent=2) + "\n", encoding="utf-8"
        )
        shutil.copy2(self.FIXTURE / "version.env", approved_root / "version.env")
        (approved_root / "authority-marker.txt").write_text("approved\n", encoding="utf-8")

        stable_appcast = temp_dir / "stable-appcast.xml"
        shutil.copy2(self.FIXTURE / "stable-appcast.xml", stable_appcast)
        tooling_commit = self.commit_fixture_root(trusted_root, "trusted tooling fixture")
        approved_commit = self.commit_fixture_root(approved_root, "approved source fixture")
        return {
            "temp": temp_dir,
            "trusted": trusted_root,
            "approved": approved_root,
            "stable_appcast": stable_appcast,
            "tooling_commit": tooling_commit,
            "approved_commit": approved_commit,
        }

    def resolve(
        self,
        fixture: dict[str, object],
        output: Path,
        digest: Path,
        *,
        source_build_sequence: str = "1521",
        expected_repository: str | None = None,
        stable_appcast: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return self.run_context(
            "resolve",
            "--trusted-tooling-root", str(fixture["trusted"]),
            "--approved-source-root", str(fixture["approved"]),
            "--stable-appcast", str(stable_appcast or fixture["stable_appcast"]),
            "--approved-source-commit", str(fixture["approved_commit"]),
            "--trusted-tooling-commit", str(fixture["tooling_commit"]),
            "--source-build-sequence", source_build_sequence,
            "--expected-tip-update-repository",
            expected_repository or self.SYNTHETIC_REPOSITORY,
            "--output", str(output),
            "--digest-output", str(digest),
        )

    def make_context_fixture(
        self,
        *,
        source_build_sequence: str = "1521",
        **authority_options,
    ) -> dict[str, object]:
        fixture = self.make_authority_fixture(**authority_options)
        fixture["context"] = Path(fixture["temp"]) / "tip-release-context.json"
        fixture["digest"] = Path(fixture["temp"]) / "tip-release-context.json.sha256"
        result = self.resolve(
            fixture,
            Path(fixture["context"]),
            Path(fixture["digest"]),
            source_build_sequence=source_build_sequence,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        fixture["expected_digest"] = Path(fixture["digest"]).read_text(
            encoding="ascii"
        ).strip()
        return fixture

    def verification_arguments(
        self,
        fixture: dict[str, object],
        *,
        boundary: str = "unit-test",
        expected_digest: str | None = None,
        include_roots: bool = True,
    ) -> list[str]:
        arguments = [
            "--context", str(fixture["context"]),
            "--digest", str(fixture["digest"]),
            "--stable-appcast", str(fixture["stable_appcast"]),
            "--expected-context-sha256",
            expected_digest or str(fixture["expected_digest"]),
            "--expected-approved-source-commit", str(fixture["approved_commit"]),
            "--expected-tooling-commit", str(fixture["tooling_commit"]),
            "--boundary", boundary,
        ]
        if include_roots:
            arguments += [
                "--approved-source-root", str(fixture["approved"]),
                "--trusted-tooling-root", str(fixture["trusted"]),
            ]
        return arguments

    @staticmethod
    def context_environment(fixture: dict[str, object]) -> dict[str, str]:
        return {
            "REPOPROMPT_TIP_RELEASE_CONTEXT": str(fixture["context"]),
            "REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE": str(fixture["digest"]),
            "REPOPROMPT_TIP_STABLE_APPCAST": str(fixture["stable_appcast"]),
            "REPOPROMPT_EXPECTED_CONTEXT_SHA256": str(fixture["expected_digest"]),
            "REPOPROMPT_APPROVED_SOURCE_ROOT": str(fixture["approved"]),
            "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT": str(fixture["approved_commit"]),
            "REPOPROMPT_EXPECTED_TOOLING_COMMIT": str(fixture["tooling_commit"]),
        }

    @staticmethod
    def write_context(context_path: Path, digest_path: Path, value: dict) -> str:
        raw = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        digest = hashlib.sha256(raw).hexdigest()
        context_path.write_bytes(raw)
        digest_path.write_text(digest + "\n", encoding="ascii")
        return digest

    def test_resolve_is_deterministic_path_independent_and_uses_pure_max_build(self) -> None:
        fixture = self.make_context_fixture()
        context_path = Path(fixture["context"])
        digest_path = Path(fixture["digest"])
        first_bytes = context_path.read_bytes()
        self.assertEqual(fixture["expected_digest"], hashlib.sha256(first_bytes).hexdigest())

        relocated = Path(fixture["temp"]) / "relocated"
        trusted_clone = relocated / "trusted"
        approved_clone = relocated / "approved"
        relocated.mkdir()
        for source, destination in (
            (fixture["trusted"], trusted_clone),
            (fixture["approved"], approved_clone),
        ):
            subprocess.run(
                ["git", "clone", "-q", str(source), str(destination)],
                check=True,
                capture_output=True,
                text=True,
            )
        relocated_fixture = dict(fixture)
        relocated_fixture["trusted"] = trusted_clone
        relocated_fixture["approved"] = approved_clone
        second_context = relocated / "context.json"
        second_digest = relocated / "context.sha256"
        rerun = self.resolve(relocated_fixture, second_context, second_digest)
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertEqual(second_context.read_bytes(), first_bytes)
        self.assertEqual(second_digest.read_bytes(), digest_path.read_bytes())

        context = json.loads(context_path.read_text(encoding="utf-8"))
        self.assertEqual(context["release"]["buildNumber"], "35.15.21")
        self.assertEqual(context["archiveContract"], "tip-rollout-v1")
        self.assertTrue(context["package"]["bundleIsVersionChecked"])
        self.assertFalse(context["package"]["bundleIsRelocatable"])
        self.assertFalse(context["package"]["bundleHasStrictIdentifier"])
        self.assertFalse(context["package"]["hasScripts"])
        self.assertEqual(context["package"]["applicationBundleCount"], 1)
        self.assertIn("tipReleaseContextTool", context["provenance"]["inputSha256"])
        self.assertEqual(len(context["publication"]["assets"]), 8)

        spec = importlib.util.spec_from_file_location(
            "stable_rollout_context_test",
            self.ROLLOUT_TOOL,
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        rollout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rollout)
        self.assertEqual(
            rollout.max_build_from_appcast(self.FIXTURE / "stable-appcast.xml"),
            "35",
        )
        cli = subprocess.run(
            [
                sys.executable,
                str(self.ROLLOUT_TOOL),
                "max-build",
                "--appcast", str(self.FIXTURE / "stable-appcast.xml"),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(cli.stdout.strip(), "35")

    def test_role_contract_is_exact_for_every_tip_rollout_role(self) -> None:
        expected = {
            "legacy": ("legacy", "disabled", "application", False, False),
            "preparer": ("legacy", "legacy-preparer", "application", True, False),
            "transition": ("successor", "disabled", "package", False, True),
            "successor": ("successor", "disabled", "application", False, False),
        }

        def predecessors(role: str) -> list[dict]:
            if role == "transition":
                return [
                    {
                        "role": "preparer",
                        "tag": "tip-preparer0001",
                        "rolloutManifestSha256": "1" * 64,
                    }
                ]
            if role == "successor":
                return [
                    {
                        "role": "transition",
                        "tag": "tip-transition001",
                        "rolloutManifestSha256": "2" * 64,
                    },
                    {
                        "role": "preparer",
                        "tag": "tip-preparer0001",
                        "rolloutManifestSha256": "1" * 64,
                    },
                ]
            return []

        fixtures = {}
        for role, contract in expected.items():
            signing_identity, migration_phase, installation_type, anchor_required, installer_required = contract

            def mutate(declaration: dict, *, selected_role: str = role) -> None:
                selected = expected[selected_role]
                declaration.update(
                    {
                        "currentRole": selected_role,
                        "expectedSigningIdentity": selected[0],
                        "expectedMigrationPhase": selected[1],
                        "predecessors": predecessors(selected_role),
                    }
                )

            fixture = self.make_context_fixture(declaration_mutator=mutate)
            fixtures[role] = fixture
            context = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
            with self.subTest(role=role):
                self.assertEqual(context["rollout"]["signingIdentity"], signing_identity)
                self.assertEqual(
                    context["rollout"]["runtimeSecureStorageMigrationPhase"], migration_phase
                )
                self.assertEqual(context["rollout"]["installationType"], installation_type)
                self.assertEqual(context["migrationAnchorSigning"]["required"], anchor_required)
                self.assertEqual(context["installerSigning"]["required"], installer_required)
                self.assertEqual(context["package"] is not None, role == "transition")
                assets = context["publication"]["assets"]
                self.assertEqual(any(name.endswith(".pkg") for name in assets), role == "transition")
                self.assertEqual(any(name.endswith(".zip") for name in assets), role != "transition")
                self.assertEqual(any(name.endswith(".dmg") for name in assets), role != "transition")
                verified = self.run_context(
                    "verify", *self.verification_arguments(fixture, include_roots=False)
                )
                self.assertEqual(verified.returncode, 0, verified.stderr)

        transition_fixture = fixtures["transition"]
        tampered = json.loads(
            Path(transition_fixture["context"]).read_text(encoding="utf-8")
        )
        tampered["rollout"]["installationType"] = "application"
        tampered["package"] = None
        tampered["installerSigning"] = {
            "required": False,
            "teamIdentifier": None,
            "identityName": None,
        }
        archive = tampered["release"]["archiveBasename"]
        tampered["publication"]["assets"] = [
            "appcast.xml",
            "SHA256SUMS",
            f"{archive}-artifact-manifest.json",
            f"{archive}-metadata.json",
            "identity-rollout.json",
            f"{archive}.zip",
            f"{archive}.dmg",
            "tip-release-context.json",
            "tip-release-context.json.sha256",
        ]
        coordinated_digest = self.write_context(
            Path(transition_fixture["context"]),
            Path(transition_fixture["digest"]),
            tampered,
        )
        rejected = self.run_context(
            "verify",
            *self.verification_arguments(
                transition_fixture,
                expected_digest=coordinated_digest,
                include_roots=False,
            ),
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("transition role requires package installation", rejected.stderr)

    def test_transition_only_policy_is_not_required_by_successor_context(self) -> None:
        def successor(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "successor",
                    "expectedSigningIdentity": "successor",
                    "expectedMigrationPhase": "disabled",
                    "predecessors": [
                        {
                            "role": "transition",
                            "tag": "tip-transition001",
                            "rolloutManifestSha256": "2" * 64,
                        },
                        {
                            "role": "preparer",
                            "tag": "tip-preparer0001",
                            "rolloutManifestSha256": "1" * 64,
                        },
                    ],
                }
            )

        def without_transition_material(policy: dict) -> None:
            policy.pop("identityTransitionPackage")
            policy["identities"]["successor"].pop(
                "developerIDInstallerIdentityName"
            )

        successor_fixture = self.make_context_fixture(
            declaration_mutator=successor,
            policy_mutator=without_transition_material,
        )
        context = json.loads(
            Path(successor_fixture["context"]).read_text(encoding="utf-8")
        )
        self.assertEqual(context["rollout"]["role"], "successor")
        self.assertIsNone(context["package"])
        self.assertFalse(context["installerSigning"]["required"])

        for label, policy_mutator, expected_error in (
            (
                "package metadata",
                lambda policy: policy.pop("identityTransitionPackage"),
                "transition package keys must be exactly",
            ),
            (
                "Installer label",
                lambda policy: policy["identities"]["successor"].pop(
                    "developerIDInstallerIdentityName"
                ),
                "transition Tip role requires a reviewed Developer ID Installer identity",
            ),
        ):
            with self.subTest(missing=label):
                fixture = self.make_authority_fixture(policy_mutator=policy_mutator)
                output = Path(fixture["temp"]) / "context.json"
                digest = Path(fixture["temp"]) / "context.sha256"
                result = self.resolve(fixture, output, digest)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)

    def test_verify_requires_setup_digest_and_does_not_reload_authority_inputs(self) -> None:
        fixture = self.make_context_fixture()
        arguments = self.verification_arguments(
            fixture,
            boundary="credential-preflight",
            include_roots=False,
        )
        verified = self.run_context("verify", *arguments)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertIn("boundary=credential-preflight", verified.stdout)

        without_expected = list(arguments)
        index = without_expected.index("--expected-context-sha256")
        del without_expected[index : index + 2]
        rejected = self.run_context("verify", *without_expected)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("--expected-context-sha256", rejected.stderr)

        shutil.rmtree(fixture["trusted"])
        shutil.rmtree(fixture["approved"])
        still_verified = self.run_context("verify", *arguments)
        self.assertEqual(still_verified.returncode, 0, still_verified.stderr)

        stable_appcast = Path(fixture["stable_appcast"])
        stable_appcast.write_bytes(stable_appcast.read_bytes() + b"\n")
        appcast_rejected = self.run_context("verify", *arguments)
        self.assertNotEqual(appcast_rejected.returncode, 0)
        self.assertIn("carried Stable appcast digest mismatch", appcast_rejected.stderr)

    def test_verify_rejects_coordinated_context_and_sidecar_tampering(self) -> None:
        fixture = self.make_context_fixture()
        original_expected = str(fixture["expected_digest"])
        context = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
        context["applicationSigning"]["bundleIdentifier"] = "com.example.tampered"
        coordinated_digest = self.write_context(
            Path(fixture["context"]),
            Path(fixture["digest"]),
            context,
        )
        self.assertNotEqual(coordinated_digest, original_expected)

        rejected = self.run_context(
            "verify",
            *self.verification_arguments(
                fixture,
                expected_digest=original_expected,
                include_roots=False,
            ),
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("expected-setup=" + original_expected, rejected.stderr)
        self.assertIn("actual=" + coordinated_digest, rejected.stderr)
        self.assertIn("detached=" + coordinated_digest, rejected.stderr)

    def test_verify_uses_closed_schema_and_exact_shell_export_allowlist(self) -> None:
        fixture = self.make_context_fixture()
        shell = self.run_context(
            "verify",
            *self.verification_arguments(fixture),
            "--emit-shell",
        )
        self.assertEqual(shell.returncode, 0, shell.stderr)
        assignments = {}
        for line in shell.stdout.splitlines():
            token = shlex.split(line)
            self.assertEqual(len(token), 1, line)
            key, value = token[0].split("=", 1)
            assignments[key] = value
        self.assertEqual(
            tuple(assignments),
            (
                "REPOPROMPT_TIP_CONTEXT_SHA256",
                "REPOPROMPT_TIP_ARCHIVE_CONTRACT",
                "TIP_COMMIT",
                "TIP_SHORT_SHA",
                "TIP_BUILD_SEQUENCE",
                "TIP_BUILD_NUMBER",
                "TIP_TAG",
                "ARCHIVE_BASENAME",
                "APP_NAME",
                "DISPLAY_NAME",
                "MARKETING_VERSION",
                "ROLLOUT_CHANNEL",
                "ROLLOUT_ROLE",
                "ROLLOUT_IDENTITY",
                "REPOPROMPT_IDENTITY_MIGRATION_PHASE",
                "ROLLOUT_INSTALLATION_TYPE",
                "BUNDLE_ID",
                "SIGNING_TEAM_ID",
                "EXPECTED_APP_REQUIREMENT",
                "EXPECTED_SIGN_IDENTITY",
                "EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER",
                "EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID",
                "EXPECTED_MIGRATION_ANCHOR_TEAM_ID",
                "EXPECTED_MIGRATION_ANCHOR_REQUIREMENT",
                "EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY",
                "EXPECTED_INSTALLER_TEAM_ID",
                "EXPECTED_INSTALLER_IDENTITY",
                "SPARKLE_PUBLIC_EDDSA_VALUE",
                "ROLLOUT_UPDATE_REPOSITORY",
                "ROLLOUT_FEED_URL",
                "TIP_PUBLICATION_TARGET",
                "TIP_PUBLICATION_DRAFT",
                "TIP_PUBLICATION_PRERELEASE",
                "TIP_PUBLICATION_ASSETS_JSON",
            ),
        )
        self.assertEqual(assignments["REPOPROMPT_TIP_ARCHIVE_CONTRACT"], "tip-rollout-v1")
        self.assertEqual(assignments["EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"], "")
        self.assertEqual(assignments["EXPECTED_MIGRATION_ANCHOR_TEAM_ID"], "")
        self.assertEqual(assignments["EXPECTED_MIGRATION_ANCHOR_REQUIREMENT"], "")
        self.assertEqual(assignments["EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY"], "")
        self.assertEqual(assignments["TIP_PUBLICATION_TARGET"], "main")
        self.assertEqual(assignments["TIP_PUBLICATION_DRAFT"], "false")
        self.assertEqual(assignments["TIP_PUBLICATION_PRERELEASE"], "false")
        self.assertNotIn("TIP_PUBLISH_INSTALLATION_TYPE", assignments)

        original = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
        cases = []
        unknown = json.loads(json.dumps(original))
        unknown["unexpected"] = "value"
        cases.append((unknown, "keys are not closed-schema"))
        malformed = json.loads(json.dumps(original))
        malformed["release"]["sourceBuildSequence"] = "1521"
        cases.append((malformed, "source build sequence must be an integer"))
        role_identity = json.loads(json.dumps(original))
        role_identity["rollout"]["signingIdentity"] = "legacy"
        cases.append((role_identity, "transition role requires the successor signing identity"))
        role_migration = json.loads(json.dumps(original))
        role_migration["rollout"]["runtimeSecureStorageMigrationPhase"] = "legacy-preparer"
        cases.append((role_migration, "transition role requires migration phase disabled"))
        short_sha = json.loads(json.dumps(original))
        short_sha["release"]["shortSha"] = "1" * 12
        cases.append((short_sha, "first 12 characters of the release commit"))
        tag = json.loads(json.dumps(original))
        tag["release"]["tag"] = "tip-" + "1" * 12
        tag["publication"]["tag"] = tag["release"]["tag"]
        cases.append((tag, "release tag must be derived from the release commit"))
        build = json.loads(json.dumps(original))
        build["release"]["buildNumber"] = "35.15.22"
        build["package"]["version"] = "35.15.22"
        build["release"]["archiveBasename"] = build["release"]["archiveBasename"].replace(
            "35.15.21", "35.15.22"
        )
        build["publication"]["assets"] = [
            name.replace("35.15.21", "35.15.22")
            for name in build["publication"]["assets"]
        ]
        cases.append((build, "release build number must be derived"))
        package_version = json.loads(json.dumps(original))
        package_version["package"]["version"] = "35.15.22"
        cases.append((package_version, "package version must equal the release build number"))
        selected_feed = json.loads(json.dumps(original))
        selected_feed["sparkle"]["selectedFeedURL"] = selected_feed["sparkle"]["stableFeedURL"]
        cases.append((selected_feed, "selected feed must equal the reviewed Tip feed"))
        publication_assets = json.loads(json.dumps(original))
        publication_assets["publication"]["assets"] = list(
            reversed(publication_assets["publication"]["assets"])
        )
        cases.append((publication_assets, "publication assets do not match"))
        installer_team = json.loads(json.dumps(original))
        installer_team["installerSigning"]["teamIdentifier"] = "DIFFERENT1"
        cases.append((installer_team, "Installer and Application Team IDs must match"))
        secret_field = json.loads(json.dumps(original))
        secret_field["githubToken"] = "synthetic"
        cases.append((secret_field, "prohibited secret-like field"))
        for value, expected_error in cases:
            with self.subTest(expected_error):
                new_digest = self.write_context(
                    Path(fixture["context"]),
                    Path(fixture["digest"]),
                    value,
                )
                rejected = self.run_context(
                    "verify",
                    *self.verification_arguments(
                        fixture,
                        expected_digest=new_digest,
                        include_roots=False,
                    ),
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(expected_error, rejected.stderr)

    def test_verify_checks_setup_routing_and_writes_fixed_github_environment(self) -> None:
        fixture = self.make_context_fixture()
        github_env = Path(fixture["temp"]) / "github-env"
        github_env.write_text("EXISTING=value\n", encoding="utf-8")
        verified = self.run_context(
            "verify",
            *self.verification_arguments(fixture, boundary="workflow-job"),
            "--expected-role", "transition",
            "--expected-installation-type", "package",
            "--expected-tag", f"tip-{str(fixture['approved_commit'])[:12]}",
            "--expected-build-number", "35.15.21",
            "--github-env", str(github_env),
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        environment = dict(
            line.split("=", 1)
            for line in github_env.read_text(encoding="utf-8").splitlines()
        )
        self.assertEqual(environment["EXISTING"], "value")
        self.assertEqual(environment["ROLLOUT_ROLE"], "transition")
        self.assertEqual(environment["ROLLOUT_INSTALLATION_TYPE"], "package")
        self.assertEqual(environment["TIP_BUILD_NUMBER"], "35.15.21")
        self.assertEqual(environment["REPOPROMPT_TIP_CONTEXT_SHA256"], fixture["expected_digest"])

        rejected = self.run_context(
            "verify",
            *self.verification_arguments(fixture, boundary="workflow-job"),
            "--expected-role", "successor",
            "--expected-installation-type", "package",
            "--expected-tag", f"tip-{str(fixture['approved_commit'])[:12]}",
            "--expected-build-number", "35.15.21",
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("setup routing role mismatch", rejected.stderr)

    def test_resolve_requires_committed_fixed_inputs_and_clean_roots(self) -> None:
        fixture = self.make_authority_fixture()
        output = Path(fixture["temp"]) / "context.json"
        digest = Path(fixture["temp"]) / "context.sha256"
        input_paths = (
            Path(fixture["trusted"]) / "Scripts" / "apple_identity_policy.json",
            Path(fixture["trusted"]) / "Scripts" / "stable_rollout.py",
            Path(fixture["trusted"]) / "Scripts" / "tip_release_context.py",
            Path(fixture["approved"]) / "tip-rollout.json",
            Path(fixture["approved"]) / "version.env",
        )
        for file in input_paths:
            with self.subTest(file=file.name):
                original = file.read_bytes()
                file.write_bytes(original + b"\n")
                rejected = self.resolve(fixture, output, digest)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("does not match committed blob", rejected.stderr)
                file.write_bytes(original)

        for root_key, label in (
            ("trusted", "trusted tooling"),
            ("approved", "approved source"),
        ):
            with self.subTest(dirty=label):
                marker = Path(fixture[root_key]) / "authority-marker.txt"
                original = marker.read_text(encoding="utf-8")
                marker.write_text(original + "dirty\n", encoding="utf-8")
                rejected = self.resolve(fixture, output, digest)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    f"{label} Git checkout has staged, working-tree, or untracked changes",
                    rejected.stderr,
                )
                marker.write_text(original, encoding="utf-8")

        resolved = self.resolve(fixture, output, digest)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        Path(fixture["approved"], "authority-marker.txt").write_text(
            "approved\ndirty\n",
            encoding="utf-8",
        )
        base_verify = [
            "--context", str(output),
            "--digest", str(digest),
            "--expected-context-sha256", digest.read_text(encoding="ascii").strip(),
            "--expected-approved-source-commit", str(fixture["approved_commit"]),
            "--expected-tooling-commit", str(fixture["tooling_commit"]),
        ]
        no_roots = self.run_context("verify", *base_verify, "--boundary", "no-root")
        self.assertEqual(no_roots.returncode, 0, no_roots.stderr)
        with_roots = self.run_context(
            "verify",
            *base_verify,
            "--boundary", "with-root",
            "--approved-source-root", str(fixture["approved"]),
            "--trusted-tooling-root", str(fixture["trusted"]),
        )
        self.assertNotEqual(with_roots.returncode, 0)
        self.assertIn(
            "approved source Git checkout has staged, working-tree, or untracked changes",
            with_roots.stderr,
        )

    def test_verify_rejects_untracked_shadow_module_and_writes_no_bytecode(self) -> None:
        fixture = self.make_context_fixture()
        trusted = Path(fixture["trusted"])

        # Sibling-module imports inside the trusted root must not create
        # untracked in-tree bytecode that would fail the next boundary's
        # strict clean-checkout verification, even without the ambient
        # PYTHONDONTWRITEBYTECODE test default.
        bytecode_env = os.environ.copy()
        bytecode_env.pop("PYTHONDONTWRITEBYTECODE", None)
        bytecode_env.update(self.context_environment(fixture))
        adapter = subprocess.run(
            [
                sys.executable,
                str(trusted / "Scripts" / "stable_rollout.py"),
                "predecessor-values-from-context",
            ],
            env=bytecode_env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(adapter.returncode, 0, adapter.stderr)
        self.assertEqual(list(trusted.rglob("__pycache__")), [])
        clean = self.run_context("verify", *self.verification_arguments(fixture))
        self.assertEqual(clean.returncode, 0, clean.stderr)

        # An untracked shadow module must be rejected even at the expected
        # HEAD, before anything could import it from the trusted root.
        shadow = trusted / "Scripts" / "hashlib.py"
        shadow.write_text(
            "raise AssertionError('untracked shadow module executed')\n",
            encoding="utf-8",
        )
        rejected = self.run_context("verify", *self.verification_arguments(fixture))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "trusted tooling Git checkout has staged, working-tree, or untracked changes",
            rejected.stderr,
        )
        self.assertNotIn("untracked shadow module executed", rejected.stderr)
        self.assertNotIn("untracked shadow module executed", rejected.stdout)

    def test_policy_owns_transition_contract_and_application_roles_omit_it(self) -> None:
        fixture = self.make_context_fixture()
        context = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
        policy = json.loads(
            (self.FIXTURE / "apple_identity_policy.json").read_text(encoding="utf-8")
        )
        expected_package = dict(policy["identityTransitionPackage"])
        expected_package["version"] = "35.15.21"
        self.assertEqual(context["package"], expected_package)
        self.assertEqual(
            context["migrationAnchorSigning"],
            {
                "required": False,
                "bundleIdentifier": None,
                "teamIdentifier": None,
                "developerIDRequirement": None,
                "identityName": None,
            },
        )

        invalid = self.make_authority_fixture(
            policy_mutator=lambda value: value["identityTransitionPackage"].update(
                {"bundleIsVersionChecked": False}
            )
        )
        invalid_result = self.resolve(
            invalid,
            Path(invalid["temp"]) / "context.json",
            Path(invalid["temp"]) / "context.sha256",
        )
        self.assertNotEqual(invalid_result.returncode, 0)
        self.assertIn("version-checked", invalid_result.stderr)

        def successor(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "successor",
                    "expectedSigningIdentity": "successor",
                    "expectedMigrationPhase": "disabled",
                    "predecessors": [
                        {
                            "role": "transition",
                            "tag": "tip-transition0001",
                            "rolloutManifestSha256": "2" * 64,
                        },
                        {
                            "role": "preparer",
                            "tag": "tip-preparer0001",
                            "rolloutManifestSha256": "1" * 64,
                        },
                    ],
                }
            )

        successor_fixture = self.make_context_fixture(declaration_mutator=successor)
        successor_context = json.loads(
            Path(successor_fixture["context"]).read_text(encoding="utf-8")
        )
        self.assertEqual(successor_context["rollout"]["role"], "successor")
        self.assertIsNone(successor_context["package"])
        self.assertFalse(successor_context["installerSigning"]["required"])
        self.assertIsNone(successor_context["installerSigning"]["identityName"])
        self.assertEqual(len(successor_context["publication"]["assets"]), 9)
        successor_assets = successor_context["publication"]["assets"]
        self.assertTrue(any(name.endswith(".zip") for name in successor_assets))
        self.assertTrue(any(name.endswith(".dmg") for name in successor_assets))
        self.assertFalse(any(name.endswith(".pkg") for name in successor_assets))
        self.assertIn("tip-release-context.json", successor_assets)
        self.assertIn("tip-release-context.json.sha256", successor_assets)

        def preparer(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "preparer",
                    "expectedSigningIdentity": "legacy",
                    "expectedMigrationPhase": "legacy-preparer",
                    "predecessors": [],
                }
            )

        preparer_fixture = self.make_context_fixture(declaration_mutator=preparer)
        preparer_context = json.loads(
            Path(preparer_fixture["context"]).read_text(encoding="utf-8")
        )
        expected_anchor = policy["identities"]["successor"]
        self.assertEqual(
            preparer_context["migrationAnchorSigning"],
            {
                "required": True,
                "bundleIdentifier": expected_anchor["bundleIdentifier"],
                "teamIdentifier": expected_anchor["teamIdentifier"],
                "developerIDRequirement": expected_anchor["developerIDRequirement"],
                "identityName": expected_anchor["developerIDApplicationIdentityName"],
            },
        )
        preparer_shell = self.run_context(
            "verify",
            *self.verification_arguments(preparer_fixture),
            "--emit-shell",
        )
        self.assertEqual(preparer_shell.returncode, 0, preparer_shell.stderr)
        preparer_assignments = {
            token[0].split("=", 1)[0]: token[0].split("=", 1)[1]
            for line in preparer_shell.stdout.splitlines()
            if (token := shlex.split(line))
        }
        self.assertEqual(
            preparer_assignments["EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY"],
            expected_anchor["developerIDApplicationIdentityName"],
        )
        self.assertEqual(
            preparer_assignments["EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"],
            expected_anchor["bundleIdentifier"],
        )
        self.assertNotIn("EXPECTED_SUCCESSOR_SIGN_IDENTITY", preparer_assignments)

    def test_resolve_rejects_build_repository_drift_and_binds_appcast(self) -> None:
        fixture = self.make_authority_fixture()
        output = Path(fixture["temp"]) / "context.json"
        digest = Path(fixture["temp"]) / "context.sha256"
        for sequence in ("0", "10000"):
            rejected = self.resolve(
                fixture,
                output,
                digest,
                source_build_sequence=sequence,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("source build sequence must be between 1 and 9999", rejected.stderr)

        malformed_appcast = Path(fixture["temp"]) / "stable-malformed.xml"
        malformed_appcast.write_text(
            (self.FIXTURE / "stable-appcast.xml")
            .read_text(encoding="utf-8")
            .replace(
                "<sparkle:version>35</sparkle:version>",
                "<sparkle:version>35.1</sparkle:version>",
            ),
            encoding="utf-8",
        )
        malformed = self.resolve(
            fixture,
            output,
            digest,
            stable_appcast=malformed_appcast,
        )
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("incompatible with the Tip three-component encoding", malformed.stderr)

        repository = self.resolve(
            fixture,
            output,
            digest,
            expected_repository="example/unreviewed-tip-updates",
        )
        self.assertNotEqual(repository.returncode, 0)
        self.assertIn("does not match reviewed identity policy", repository.stderr)

        first = self.resolve(fixture, output, digest)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_context = json.loads(output.read_text(encoding="utf-8"))
        changed_appcast = Path(fixture["temp"]) / "stable-changed.xml"
        changed_appcast.write_bytes(Path(fixture["stable_appcast"]).read_bytes() + b"\n")
        second = self.resolve(
            fixture,
            output,
            digest,
            stable_appcast=changed_appcast,
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        second_context = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(
            first_context["release"]["buildNumber"],
            second_context["release"]["buildNumber"],
        )
        self.assertNotEqual(
            first_context["provenance"]["inputSha256"]["stableAppcast"],
            second_context["provenance"]["inputSha256"]["stableAppcast"],
        )

    def test_context_rollout_adapter_reuses_declaration_algorithm_for_zero_predecessors(self) -> None:
        def preparer(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "preparer",
                    "expectedSigningIdentity": "legacy",
                    "expectedMigrationPhase": "legacy-preparer",
                    "predecessors": [],
                }
            )

        fixture = self.make_context_fixture(declaration_mutator=preparer)
        context = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
        release = context["release"]
        application = context["applicationSigning"]
        temp_dir = Path(fixture["temp"])
        enclosure = temp_dir / f"{release['archiveBasename']}.zip"
        enclosure.write_bytes(b"synthetic preparer enclosure\n")
        app_manifest = temp_dir / "app-artifact-manifest.json"
        app_manifest.write_text("{}\n", encoding="utf-8")
        projected_version = temp_dir / "projected-version.env"
        projected_version.write_text(
            "\n".join(
                (
                    f"APP_NAME={release['appName']}",
                    f'DISPLAY_NAME="{release["displayName"]}"',
                    f"MARKETING_VERSION={release['marketingVersion']}",
                    f"BUILD_NUMBER={release['buildNumber']}",
                    f"BUNDLE_ID={application['bundleIdentifier']}",
                    f"SIGNING_TEAM_ID={application['teamIdentifier']}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        generic_appcast = temp_dir / "generic-appcast.xml"
        generic_manifest = temp_dir / "generic-manifest.json"
        context_appcast = temp_dir / "context-appcast.xml"
        context_manifest = temp_dir / "context-manifest.json"
        tool = Path(fixture["trusted"]) / "Scripts" / "stable_rollout.py"
        shared = [
            "--enclosure", str(enclosure),
            "--enclosure-signature", "synthetic-signature",
            "--app-artifact-manifest", str(app_manifest),
        ]
        generic = subprocess.run(
            [
                sys.executable,
                str(tool),
                "generate",
                "--declaration", str(Path(fixture["approved"]) / "tip-rollout.json"),
                "--policy", str(Path(fixture["trusted"]) / "Scripts" / "apple_identity_policy.json"),
                "--version-env", str(projected_version),
                "--release-tag", release["tag"],
                "--release-commit", release["commit"],
                "--migration-phase", "legacy-preparer",
                "--enclosure-basename", release["archiveBasename"],
                *shared,
                "--appcast-output", str(generic_appcast),
                "--manifest-output", str(generic_manifest),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(generic.returncode, 0, generic.stderr)

        env = os.environ.copy()
        env.update(self.context_environment(fixture))
        predecessors = subprocess.run(
            [sys.executable, str(tool), "predecessor-values-from-context"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(predecessors.returncode, 0, predecessors.stderr)
        self.assertEqual(predecessors.stdout, "")
        generated = subprocess.run(
            [
                sys.executable,
                str(tool),
                "generate-from-context",
                *shared,
                "--appcast-output", str(context_appcast),
                "--manifest-output", str(context_manifest),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.assertEqual(context_appcast.read_bytes(), generic_appcast.read_bytes())
        self.assertEqual(context_manifest.read_bytes(), generic_manifest.read_bytes())

        validated = subprocess.run(
            [
                sys.executable,
                str(tool),
                "validate-from-context",
                *shared,
                "--appcast", str(context_appcast),
                "--manifest", str(context_manifest),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(validated.returncode, 0, validated.stderr)

    def test_context_rollout_adapter_accumulates_preparer_transition_successor_ladder(self) -> None:
        def preparer(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "preparer",
                    "expectedSigningIdentity": "legacy",
                    "expectedMigrationPhase": "legacy-preparer",
                    "predecessors": [],
                }
            )

        def generate(
            fixture: dict[str, object],
            predecessors: list[Path],
        ) -> tuple[dict, Path, Path]:
            context = json.loads(Path(fixture["context"]).read_text(encoding="utf-8"))
            temp_dir = Path(fixture["temp"])
            suffix = ".pkg" if context["rollout"]["installationType"] == "package" else ".zip"
            enclosure = temp_dir / f"{context['release']['archiveBasename']}{suffix}"
            enclosure.write_bytes(f"{context['rollout']['role']} enclosure\n".encode())
            app_manifest = temp_dir / "app-artifact-manifest.json"
            app_manifest.write_text("{}\n", encoding="utf-8")
            appcast = temp_dir / "appcast.xml"
            manifest = temp_dir / "identity-rollout.json"
            tool = Path(fixture["trusted"]) / "Scripts" / "stable_rollout.py"
            arguments = [
                sys.executable,
                str(tool),
                "generate-from-context",
                "--enclosure", str(enclosure),
                "--enclosure-signature", f"{context['rollout']['role']}-signature",
                "--app-artifact-manifest", str(app_manifest),
            ]
            for predecessor in predecessors:
                arguments += ["--predecessor-manifest", str(predecessor)]
            arguments += [
                "--appcast-output", str(appcast),
                "--manifest-output", str(manifest),
            ]
            env = os.environ.copy()
            env.update(self.context_environment(fixture))
            result = subprocess.run(arguments, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return context, manifest, appcast

        preparer_fixture = self.make_context_fixture(
            declaration_mutator=preparer,
            source_build_sequence="1521",
        )
        preparer_context, preparer_manifest, _ = generate(preparer_fixture, [])
        preparer_digest = hashlib.sha256(preparer_manifest.read_bytes()).hexdigest()

        def transition(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "transition",
                    "expectedSigningIdentity": "successor",
                    "expectedMigrationPhase": "disabled",
                    "predecessors": [
                        {
                            "role": "preparer",
                            "tag": preparer_context["release"]["tag"],
                            "rolloutManifestSha256": preparer_digest,
                        }
                    ],
                }
            )

        transition_fixture = self.make_context_fixture(
            declaration_mutator=transition,
            source_build_sequence="1522",
        )
        transition_context, transition_manifest, _ = generate(
            transition_fixture,
            [preparer_manifest],
        )
        transition_digest = hashlib.sha256(transition_manifest.read_bytes()).hexdigest()

        def successor(declaration: dict) -> None:
            declaration.update(
                {
                    "currentRole": "successor",
                    "expectedSigningIdentity": "successor",
                    "expectedMigrationPhase": "disabled",
                    "predecessors": [
                        {
                            "role": "transition",
                            "tag": transition_context["release"]["tag"],
                            "rolloutManifestSha256": transition_digest,
                        },
                        {
                            "role": "preparer",
                            "tag": preparer_context["release"]["tag"],
                            "rolloutManifestSha256": preparer_digest,
                        },
                    ],
                }
            )

        successor_fixture = self.make_context_fixture(
            declaration_mutator=successor,
            source_build_sequence="1523",
        )
        successor_context, successor_manifest, successor_appcast = generate(
            successor_fixture,
            [transition_manifest, preparer_manifest],
        )
        final_manifest = json.loads(successor_manifest.read_text(encoding="utf-8"))
        items = final_manifest["appcastItems"]
        self.assertEqual([item["role"] for item in items], ["successor", "transition", "preparer"])
        self.assertEqual(
            [item["minimumUpdateVersion"] for item in items],
            [
                transition_context["release"]["buildNumber"],
                preparer_context["release"]["buildNumber"],
                None,
            ],
        )
        final_appcast = successor_appcast.read_text(encoding="utf-8")
        self.assertEqual(final_appcast.count("    <item>"), 3)
        minimum_updates = re.findall(
            r"<sparkle:minimumUpdateVersion>([0-9.]+)</sparkle:minimumUpdateVersion>",
            final_appcast,
        )
        minimum_autoupdates = re.findall(
            r"<sparkle:minimumAutoupdateVersion>([0-9.]+)</sparkle:minimumAutoupdateVersion>",
            final_appcast,
        )
        self.assertEqual(minimum_updates, minimum_autoupdates)
        self.assertEqual(
            minimum_updates,
            [
                transition_context["release"]["buildNumber"],
                preparer_context["release"]["buildNumber"],
            ],
        )
        self.assertEqual(final_manifest["sourceTag"], successor_context["release"]["tag"])

        blocked_fixture = self.make_authority_fixture(declaration_mutator=transition)
        blocked_stable_appcast = Path(blocked_fixture["stable_appcast"])
        blocked_stable_appcast.write_text(
            blocked_stable_appcast.read_text(encoding="utf-8")
            .replace("Stable Build 35", "Stable Build 36")
            .replace("<sparkle:version>35<", "<sparkle:version>36<"),
            encoding="utf-8",
        )
        blocked_fixture["context"] = Path(blocked_fixture["temp"]) / "tip-release-context.json"
        blocked_fixture["digest"] = Path(blocked_fixture["temp"]) / "tip-release-context.json.sha256"
        blocked_resolution = self.resolve(
            blocked_fixture,
            Path(blocked_fixture["context"]),
            Path(blocked_fixture["digest"]),
            source_build_sequence="1522",
        )
        self.assertEqual(blocked_resolution.returncode, 0, blocked_resolution.stderr)
        blocked_fixture["expected_digest"] = Path(blocked_fixture["digest"]).read_text(
            encoding="ascii"
        ).strip()
        blocked_context = json.loads(
            Path(blocked_fixture["context"]).read_text(encoding="utf-8")
        )
        blocked_enclosure = Path(blocked_fixture["temp"]) / (
            blocked_context["release"]["archiveBasename"] + ".pkg"
        )
        blocked_enclosure.write_text("transition enclosure\n", encoding="utf-8")
        blocked_app_manifest = Path(blocked_fixture["temp"]) / "app-artifact-manifest.json"
        blocked_app_manifest.write_text("{}\n", encoding="utf-8")
        blocked = subprocess.run(
            [
                sys.executable,
                str(Path(blocked_fixture["trusted"]) / "Scripts" / "stable_rollout.py"),
                "generate-from-context",
                "--enclosure", str(blocked_enclosure),
                "--enclosure-signature", "transition-signature",
                "--app-artifact-manifest", str(blocked_app_manifest),
                "--predecessor-manifest", str(preparer_manifest),
                "--appcast-output", str(Path(blocked_fixture["temp"]) / "blocked-appcast.xml"),
                "--manifest-output", str(Path(blocked_fixture["temp"]) / "blocked-manifest.json"),
            ],
            env={**os.environ, **self.context_environment(blocked_fixture)},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("Stable=36 preparer=35.15.21", blocked.stderr)

    def test_live_tip_publication_state_allows_only_monotonic_retained_rollout_history(self) -> None:
        spec = importlib.util.spec_from_file_location("stable_rollout_live_test", self.ROLLOUT_TOOL)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        rollout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rollout)

        repository = self.SYNTHETIC_REPOSITORY
        minimum_system = "13.0"
        live_main = "2" * 40

        def item(
            role: str,
            tag: str,
            build: str,
            minimum_update: str | None,
            manifest_digest: str | None,
        ) -> dict:
            suffix = ".pkg" if role == "transition" else ".zip"
            enclosure_name = f"RepoPrompt-tip-{tag[4:]}-{build}{suffix}"
            return {
                "role": role,
                "tag": tag,
                "url": f"https://github.com/{repository}/releases/download/{tag}/{enclosure_name}",
                "buildNumber": build,
                "marketingVersion": "1.3.0",
                "minimumSystemVersion": minimum_system,
                "minimumUpdateVersion": minimum_update,
                "installationType": "package" if role == "transition" else "application",
                "enclosureName": enclosure_name,
                "enclosureSize": 42,
                "enclosureSha256": "1" * 64,
                "edSignature": f"{role}-signature",
                "rolloutManifestSha256": manifest_digest,
                "rolloutManifestName": "identity-rollout.json" if manifest_digest else None,
            }

        def manifest(role: str, items: list[dict]) -> dict:
            newest = items[0]
            return {
                "schemaVersion": 1,
                "channel": "tip",
                "sourceTag": newest["tag"],
                "releaseCommit": "1" * 40,
                "currentRole": role,
                "signingIdentity": "legacy" if role in {"legacy", "preparer"} else "successor",
                "bundleIdentifier": "com.example.app",
                "teamIdentifier": "EXAMPLETEAM",
                "marketingVersion": newest["marketingVersion"],
                "buildNumber": newest["buildNumber"],
                "migrationPhase": "legacy-preparer" if role == "preparer" else "disabled",
                "eligibilityProfile": "tip-rollout-v1",
                "updateRepository": repository,
                "appArtifactManifest": {"name": "manifest.json", "sha256": "3" * 64},
                "appcastItems": items,
            }

        def candidate(role: str, build: str, predecessors: list[dict], commit: str = live_main) -> dict:
            return {
                "release": {"commit": commit, "buildNumber": build, "appName": "RepoPrompt"},
                "sparkle": {
                    "minimumSystemVersion": minimum_system,
                    "updateRepository": repository,
                },
                "rollout": {"role": role, "predecessors": predecessors},
            }

        preparer_digest = "a" * 64
        transition_digest = "b" * 64
        transition_retained_digest = "c" * 64
        preparer_retained_digest = "d" * 64
        p_item = item("preparer", "tip-aaaaaaaaaaaa", "35.15.18", None, None)
        p_manifest = manifest("preparer", [p_item])
        t_item = item("transition", "tip-bbbbbbbbbbbb", "35.15.21", "35.15.18", None)
        p_retained = item(
            "preparer", "tip-aaaaaaaaaaaa", "35.15.18", None, preparer_retained_digest
        )
        t_manifest = manifest("transition", [t_item, p_retained])
        n_item = item("successor", "tip-cccccccccccc", "35.15.22", "35.15.21", None)
        t_retained = item(
            "transition", "tip-bbbbbbbbbbbb", "35.15.21", "35.15.18", transition_retained_digest
        )
        n_manifest = manifest("successor", [n_item, t_retained, p_retained])

        valid_cases = (
            (
                "P-to-T",
                candidate(
                    "transition",
                    "35.15.21",
                    [{"role": "preparer", "tag": p_item["tag"], "rolloutManifestSha256": preparer_digest}],
                ),
                p_manifest,
                preparer_digest,
            ),
            (
                "T-to-N",
                candidate(
                    "successor",
                    "35.15.22",
                    [
                        {"role": "transition", "tag": t_item["tag"], "rolloutManifestSha256": transition_digest},
                        {"role": "preparer", "tag": p_retained["tag"], "rolloutManifestSha256": preparer_retained_digest},
                    ],
                ),
                t_manifest,
                transition_digest,
            ),
            (
                "N-to-new-N",
                candidate(
                    "successor",
                    "35.15.23",
                    [
                        {"role": "transition", "tag": t_retained["tag"], "rolloutManifestSha256": transition_retained_digest},
                        {"role": "preparer", "tag": p_retained["tag"], "rolloutManifestSha256": preparer_retained_digest},
                    ],
                ),
                n_manifest,
                "e" * 64,
            ),
        )
        for label, candidate_context, live_manifest, manifest_digest in valid_cases:
            with self.subTest(valid=label):
                rollout.validate_live_tip_publication_state(
                    candidate_context,
                    live_manifest,
                    rollout.render_appcast(live_manifest),
                    manifest_digest,
                    live_main,
                )

        with self.subTest(valid="published-P-null-floor-compatibility"):
            published_preparer = json.loads(json.dumps(p_manifest))
            published_item = published_preparer["appcastItems"][0]
            self.assertIsNone(published_item.pop("minimumUpdateVersion"))
            published_item["minimumAutoupdateVersion"] = None
            normalized_preparer = rollout.normalize_manifest_floor_authority(
                published_preparer
            )
            rollout.validate_live_tip_publication_state(
                valid_cases[0][1],
                published_preparer,
                rollout.render_appcast(normalized_preparer),
                preparer_digest,
                live_main,
            )

        rejected_cases = []
        stale = json.loads(json.dumps(valid_cases[0][1]))
        stale["release"]["commit"] = "4" * 40
        rejected_cases.append(("stale historical dispatch", stale, p_manifest, preparer_digest, "source commit is stale"))
        regression = candidate("preparer", "35.15.22", [])
        rejected_cases.append(("role regression", regression, t_manifest, transition_digest, "would regress or skip"))
        same_build = json.loads(json.dumps(valid_cases[0][1]))
        same_build["release"]["buildNumber"] = p_item["buildNumber"]
        rejected_cases.append(("same build", same_build, p_manifest, preparer_digest, "strictly newer"))
        wrong_history = json.loads(json.dumps(valid_cases[0][1]))
        wrong_history["rollout"]["predecessors"][0]["rolloutManifestSha256"] = "f" * 64
        rejected_cases.append(("changed pin", wrong_history, p_manifest, preparer_digest, "do not exactly match"))
        for label, candidate_context, live_manifest, manifest_digest, expected_error in rejected_cases:
            with self.subTest(rejected=label), self.assertRaisesRegex(rollout.RolloutError, expected_error):
                rollout.validate_live_tip_publication_state(
                    candidate_context,
                    live_manifest,
                    rollout.render_appcast(live_manifest),
                    manifest_digest,
                    live_main,
                )

    def test_stable_build_must_remain_below_retained_tip_preparer(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "stable_rollout_cross_channel_test", self.ROLLOUT_TOOL
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        rollout = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rollout)

        manifest = {
            "appcastItems": [
                {"role": "transition", "buildNumber": "35.15.21"},
                {"role": "preparer", "buildNumber": "35.15.18"},
            ]
        }
        context = {
            "rollout": {"role": "transition"},
            "release": {"stableMaximumBuild": "35"},
        }
        rollout.validate_stable_build_below_retained_tip_preparer(context, manifest)

        context["release"]["stableMaximumBuild"] = "36"
        with self.assertRaisesRegex(
            rollout.RolloutError,
            r"Stable=36 preparer=35\.15\.18",
        ):
            rollout.validate_stable_build_below_retained_tip_preparer(context, manifest)

    def test_main_tip_workflow_transports_one_digest_bound_context_to_every_job(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(workflow.count("tip_release_context.py resolve"), 1)
        self.assertEqual(workflow.count("stable_rollout.py feed-url"), 1)
        self.assertNotIn(
            "https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml",
            workflow,
        )
        self.assertIn("--connect-timeout 10 --max-time 30", workflow)
        self.assertNotIn("stable_rollout.py packaging-context", workflow)
        self.assertIn("context-sha256: ${{ steps.tip.outputs.context-sha256 }}", workflow)
        self.assertNotIn("rollout-identity: ${{ steps.tip.outputs", workflow)
        self.assertNotIn("migration-phase: ${{ steps.tip.outputs", workflow)
        self.assertIn("name: RepoPrompt-CE-tip-release-context", workflow)
        self.assertIn("sha256sums-sha256: ${{ steps.signed-assets.outputs.sha256sums-sha256 }}", workflow)
        self.assertEqual(
            workflow.count("REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256: ${{ needs.sign.outputs.sha256sums-sha256 }}"),
            2,
        )
        self.assertIn("path: ${{ runner.temp }}/tip-release-context/", workflow)
        for basename in (
            "tip-release-context.json",
            "tip-release-context.json.sha256",
            "stable-appcast-input.xml",
        ):
            self.assertIn(basename, workflow)

        action = (
            SCRIPT_DIR.parent / ".github" / "actions" / "verify-tip-context" / "action.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("using: composite", action)
        self.assertIn(
            "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093", action
        )
        self.assertIn("name: RepoPrompt-CE-tip-release-context", action)
        self.assertIn("path: tip-release-context", action)
        self.assertEqual(action.count("tip_release_context.py verify"), 1)
        for marker in (
            "--context tip-release-context/tip-release-context.json",
            "--digest tip-release-context/tip-release-context.json.sha256",
            "--stable-appcast tip-release-context/stable-appcast-input.xml",
            "--expected-context-sha256 \"$EXPECTED_CONTEXT_SHA256\"",
            "--expected-approved-source-commit",
            "--expected-tooling-commit",
            "--expected-role \"$SETUP_ROLLOUT_ROLE\"",
            "--expected-installation-type \"$SETUP_INSTALLATION_TYPE\"",
            "--expected-tag \"$SETUP_TAG\"",
            "--expected-build-number \"$SETUP_BUILD_NUMBER\"",
            "--boundary \"$VERIFICATION_BOUNDARY\"",
            "--approved-source-root \"$APPROVED_SOURCE_ROOT\"",
            "--trusted-tooling-root trusted-control-plane",
            '--github-env "$GITHUB_ENV"',
            'echo "REPOPROMPT_TIP_RELEASE_CONTEXT=$GITHUB_WORKSPACE/tip-release-context/tip-release-context.json"',
            'echo "REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE=$GITHUB_WORKSPACE/tip-release-context/tip-release-context.json.sha256"',
            'echo "REPOPROMPT_TIP_STABLE_APPCAST=$GITHUB_WORKSPACE/tip-release-context/stable-appcast-input.xml"',
            'echo "REPOPROMPT_APPROVED_SOURCE_ROOT=$GITHUB_WORKSPACE/$APPROVED_SOURCE_ROOT"',
            'echo "REPOPROMPT_EXPECTED_CONTEXT_SHA256=$EXPECTED_CONTEXT_SHA256"',
            'echo "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT=$EXPECTED_APPROVED_SOURCE_COMMIT"',
            'echo "REPOPROMPT_EXPECTED_TOOLING_COMMIT=$EXPECTED_TOOLING_COMMIT"',
        ):
            self.assertIn(marker, action)
        self.assertLess(
            action.index("tip_release_context.py verify"),
            action.index("REPOPROMPT_TIP_RELEASE_CONTEXT="),
        )

        jobs = {
            "automatic": workflow.split("\n  automatic-tip-dormant:", 1)[1].split(
                "\n  credential-preflight:", 1
            )[0],
            "credential": workflow.split("\n  credential-preflight:", 1)[1].split(
                "\n  stage:", 1
            )[0],
            "stage": workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0],
            "sign": workflow.split("\n  sign:", 1)[1].split("\n  smoke-no-secrets:", 1)[0],
            "smoke": workflow.split("\n  smoke-no-secrets:", 1)[1].split(
                "\n  publish:", 1
            )[0],
            "publish": workflow.split("\n  publish:", 1)[1],
        }
        owned_operation = {
            "automatic": "Report suppressed automatic publication",
            "credential": "Validate role-selected Tip credentials",
            "stage": "Stage tip artifact",
            "sign": "Download staged tip source",
            "smoke": "Download signed tip assets",
            "publish": "Download signed tip assets",
        }
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertIn("Verify immutable Tip release context", job)
                self.assertIn(
                    "uses: ./trusted-control-plane/.github/actions/verify-tip-context",
                    job,
                )
                self.assertIn(
                    "expected-context-sha256: ${{ needs.setup.outputs.context-sha256 }}",
                    job,
                )
                self.assertIn(
                    "expected-approved-source-commit: ${{ needs.setup.outputs.commit }}",
                    job,
                )
                self.assertIn(
                    "expected-tooling-commit: ${{ needs.setup.outputs.tooling-commit }}",
                    job,
                )
                self.assertIn(
                    "expected-role: ${{ needs.setup.outputs.rollout-role }}", job
                )
                self.assertIn(
                    "expected-installation-type: ${{ needs.setup.outputs.installation-type }}",
                    job,
                )
                self.assertIn("expected-tag: ${{ needs.setup.outputs.tag }}", job)
                self.assertIn(
                    "expected-build-number: ${{ needs.setup.outputs.build-number }}", job
                )
                if name == "stage":
                    self.assertIn("Check out tip source", job)
                    self.assertIn("approved-source-root: tip-source", job)
                else:
                    self.assertIn("Check out approved tip source as data", job)
                    self.assertIn("approved-source-root: approved-source", job)
                self.assertLess(
                    job.index("Check out trusted tooling"),
                    job.index("Verify immutable Tip release context"),
                )
                self.assertLess(
                    job.index("Verify immutable Tip release context"),
                    job.index(owned_operation[name]),
                )
        self.assertEqual(workflow.count("boundary: automatic-dormant"), 1)
        self.assertEqual(workflow.count("boundary: credential-preflight"), 1)
        self.assertEqual(workflow.count("boundary: stage"), 1)
        self.assertEqual(workflow.count("boundary: sign"), 1)
        self.assertEqual(workflow.count("boundary: smoke"), 1)
        self.assertEqual(workflow.count("boundary: publish"), 1)
        self.assertEqual(
            workflow.count(
                "uses: ./trusted-control-plane/.github/actions/verify-tip-context"
            ),
            len(jobs),
        )

    def test_summary_is_verified_markdown_safe_public_and_path_free(self) -> None:
        backtick = chr(96)
        fixture = self.make_context_fixture(
            application_identity_name=(
                "Developer ID Application: Synthetic "
                + backtick
                + "label"
                + backtick
                + " <unsafe>|"
            )
        )
        summary_path = Path(fixture["temp"]) / "summary.md"
        summary_path.write_text("Existing summary\n", encoding="utf-8")
        result = self.run_context(
            "summary",
            *self.verification_arguments(fixture, boundary="setup-summary"),
            "--output", str(summary_path),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = summary_path.read_text(encoding="utf-8")
        self.assertTrue(summary.startswith("Existing summary\n"))
        for heading in (
            "### Authority provenance",
            "### Application signing",
            "### Migration-anchor Application signing",
            "### Installer signing",
            "### Sparkle public signing and feeds",
            "### Transition package",
            "### Predecessor pins",
            "### Exact publication inventory",
        ):
            self.assertIn(heading, summary)
        self.assertIn("Runtime secure-storage migration phase", summary)
        self.assertIn("&lt;unsafe&gt;", summary)
        self.assertNotIn("<unsafe>", summary)
        self.assertNotIn(str(fixture["temp"]), summary)
        for prohibited in ("PRIVATE KEY", "github_pat_", "ghp_"):
            self.assertNotIn(prohibited, summary)


class IdentityTransitionReleaseToolingTests(unittest.TestCase):
    """Shared rollout-authority coverage for the Stable safety lock and
    the explicitly dispatched Tip identity dress rehearsal."""

    POLICY = SCRIPT_DIR / "apple_identity_policy.json"
    DECLARATION = SCRIPT_DIR.parent / "release-rollout.json"
    TIP_DECLARATION = SCRIPT_DIR.parent / "tip-rollout.json"
    UPDATE_REPOSITORY = "repoprompt/repoprompt-ce-updates"
    TIP_UPDATE_REPOSITORY = "repoprompt/repoprompt-ce-tip-updates"

    def rollout(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "stable_rollout.py"), *args],
            text=True,
            capture_output=True,
        )

    @staticmethod
    def shell_assignments(output: str) -> dict[str, str]:
        assignments = {}
        for line in output.splitlines():
            token = shlex.split(line)
            if len(token) != 1 or "=" not in token[0]:
                raise AssertionError(f"unexpected packaging-context output: {line!r}")
            key, value = token[0].split("=", 1)
            assignments[key] = value
        return assignments

    def test_packaging_context_projects_tip_role_without_advancing_stable_metadata(self) -> None:
        root = SCRIPT_DIR.parent
        transition_context = self.rollout(
            "packaging-context",
            "--declaration", str(self.TIP_DECLARATION),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
        )
        self.assertEqual(transition_context.returncode, 0, transition_context.stderr)
        context = self.shell_assignments(transition_context.stdout)
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        self.assertEqual(context["ROLLOUT_ROLE"], "transition")
        self.assertEqual(context["ROLLOUT_IDENTITY"], "successor")
        self.assertEqual(context["ROLLOUT_INSTALLATION_TYPE"], "package")
        self.assertEqual(context["BUNDLE_ID"], "com.repoprompt.ce")
        self.assertEqual(
            context["EXPECTED_SIGN_IDENTITY"],
            policy["identities"]["successor"]["developerIDApplicationIdentityName"],
        )
        self.assertEqual(
            context["EXPECTED_INSTALLER_IDENTITY"],
            policy["identities"]["successor"]["developerIDInstallerIdentityName"],
        )

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        stable_transition = self.make_declaration(
            temp_dir,
            "transition",
            [
                {
                    "role": "preparer",
                    "tag": "v0.1.0",
                    "rolloutManifestSha256": "0" * 64,
                }
            ],
        )
        mismatch = self.rollout(
            "packaging-context",
            "--declaration", str(stable_transition),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
        )
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("version.env identity does not match the successor Stable rollout identity", mismatch.stderr)

    def test_base_policy_queries_do_not_require_migration_only_package_policy(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        stable_feed = policy["sparkle"]["stableFeedURL"]
        policy.pop("identityTransitionPackage")
        policy_path = temp_dir / "stable-policy.json"
        policy_path.write_text(json.dumps(policy, indent=2) + "\n", encoding="utf-8")

        result = self.rollout(
            "feed-url", "--policy", str(policy_path), "--channel", "stable"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), stable_feed)

    def test_successor_packaging_context_does_not_require_transition_only_policy(self) -> None:
        temp_dir, _preparer, transition, successor = self.make_pts_ladder()
        base_policy = json.loads(self.POLICY.read_text(encoding="utf-8"))

        successor_policy = json.loads(json.dumps(base_policy))
        successor_policy.pop("identityTransitionPackage")
        successor_policy["identities"]["successor"].pop(
            "developerIDInstallerIdentityName"
        )
        successor_policy_path = temp_dir / "successor-without-transition-policy.json"
        successor_policy_path.write_text(
            json.dumps(successor_policy, indent=2) + "\n", encoding="utf-8"
        )
        result = self.rollout(
            "packaging-context",
            "--declaration", str(successor["declaration"]),
            "--policy", str(successor_policy_path),
            "--version-env", str(successor["version_env"]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.shell_assignments(result.stdout)["EXPECTED_INSTALLER_IDENTITY"], ""
        )

        for label, mutate, expected_error in (
            (
                "package metadata",
                lambda policy: policy.pop("identityTransitionPackage"),
                "transition package keys must be exactly",
            ),
            (
                "Installer label",
                lambda policy: policy["identities"]["successor"].pop(
                    "developerIDInstallerIdentityName"
                ),
                "transition rollout role requires a reviewed Developer ID Installer identity",
            ),
        ):
            with self.subTest(missing=label):
                policy = json.loads(json.dumps(base_policy))
                mutate(policy)
                policy_path = temp_dir / f"transition-without-{label.replace(' ', '-')}.json"
                policy_path.write_text(
                    json.dumps(policy, indent=2) + "\n", encoding="utf-8"
                )
                rejected = self.rollout(
                    "packaging-context",
                    "--declaration", str(transition["declaration"]),
                    "--policy", str(policy_path),
                    "--version-env", str(transition["version_env"]),
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(expected_error, rejected.stderr)

    def test_stable_packaging_context_is_phase_bound_and_exportable(self) -> None:
        root = SCRIPT_DIR.parent
        legacy = self.rollout(
            "packaging-context",
            "--declaration", str(self.DECLARATION),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
            "--expected-migration-phase", "disabled",
        )
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        legacy_context = self.shell_assignments(legacy.stdout)
        self.assertEqual(
            legacy_context["REPOPROMPT_STABLE_RELEASE_CONTEXT"], "stable-rollout-v1"
        )
        self.assertEqual(legacy_context["ROLLOUT_ROLE"], "legacy")
        self.assertEqual(legacy_context["EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"], "")
        self.assertEqual(legacy_context["EXPECTED_INSTALLER_IDENTITY"], "")

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        preparer = self.make_declaration(temp_dir, "preparer")
        preparer_result = self.rollout(
            "packaging-context",
            "--declaration", str(preparer),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
            "--expected-migration-phase", "legacy-preparer",
        )
        self.assertEqual(preparer_result.returncode, 0, preparer_result.stderr)
        preparer_context = self.shell_assignments(preparer_result.stdout)
        successor = json.loads(self.POLICY.read_text(encoding="utf-8"))["identities"]["successor"]
        self.assertEqual(
            preparer_context["EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"],
            successor["bundleIdentifier"],
        )
        self.assertEqual(
            preparer_context["EXPECTED_MIGRATION_ANCHOR_TEAM_ID"],
            successor["teamIdentifier"],
        )

        mismatched = self.rollout(
            "packaging-context",
            "--declaration", str(preparer),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
            "--expected-migration-phase", "disabled",
        )
        self.assertNotEqual(mismatched.returncode, 0)
        self.assertIn(
            "requested identity migration phase does not match the rollout declaration: "
            "expected legacy-preparer, got disabled",
            mismatched.stderr,
        )

        github_env = temp_dir / "github-env"
        github_summary = temp_dir / "summary.md"
        exported = self.rollout(
            "packaging-context",
            "--declaration", str(self.DECLARATION),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
            "--expected-migration-phase", "disabled",
            "--github-env", str(github_env),
            "--github-summary", str(github_summary),
        )
        self.assertEqual(exported.returncode, 0, exported.stderr)
        exported_context = dict(
            line.split("=", 1)
            for line in github_env.read_text(encoding="utf-8").splitlines()
        )
        self.assertEqual(exported_context, legacy_context)
        self.assertIn("Stable release identity context", github_summary.read_text(encoding="utf-8"))

    def test_stable_context_propagates_synthetic_policy_and_rejects_wrong_identity(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        policy["identities"]["legacy"].update(
            {
                "bundleIdentifier": "example.synthetic.legacy",
                "teamIdentifier": "LEGACYTEAM1",
                "developerIDRequirement": "synthetic legacy requirement",
                "developerIDApplicationIdentityName": "Synthetic Legacy Application",
            }
        )
        policy["identities"]["successor"].update(
            {
                "bundleIdentifier": "example.synthetic.successor",
                "teamIdentifier": "NEXTTEAM123",
                "developerIDRequirement": "synthetic successor requirement",
                "developerIDApplicationIdentityName": "Synthetic Successor Application",
                "developerIDInstallerIdentityName": "Synthetic Successor Installer",
            }
        )
        policy_path = temp_dir / "policy.json"
        policy_path.write_text(json.dumps(policy, indent=2) + "\n", encoding="utf-8")
        version_path = temp_dir / "version.env"
        version_path.write_text(
            "APP_NAME=RepoPrompt\n"
            "MARKETING_VERSION=1.0.0\n"
            "BUILD_NUMBER=1\n"
            "BUNDLE_ID=example.synthetic.legacy\n"
            "SIGNING_TEAM_ID=LEGACYTEAM1\n",
            encoding="utf-8",
        )
        declaration = self.make_declaration(temp_dir, "preparer")
        resolved = self.rollout(
            "packaging-context",
            "--declaration", str(declaration),
            "--policy", str(policy_path),
            "--version-env", str(version_path),
            "--expected-migration-phase", "legacy-preparer",
        )
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        context = self.shell_assignments(resolved.stdout)
        self.assertEqual(context["EXPECTED_APP_BUNDLE_ID"], "example.synthetic.legacy")
        self.assertEqual(context["EXPECTED_APP_TEAM_ID"], "LEGACYTEAM1")
        self.assertEqual(
            context["EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"],
            "example.synthetic.successor",
        )
        self.assertEqual(context["EXPECTED_MIGRATION_ANCHOR_TEAM_ID"], "NEXTTEAM123")

        helper = SCRIPT_DIR / "load_release_metadata.sh"
        base_script = (
            'set -euo pipefail\nsource "$HELPER"\neval "$RESOLVED"\n'
        )
        env = dict(os.environ, HELPER=str(helper), RESOLVED=resolved.stdout)
        accepted = subprocess.run(
            [
                "bash", "-c",
                base_script
                + 'validate_stable_release_context "$EXPECTED_APP_BUNDLE_ID" '
                '"$EXPECTED_APP_TEAM_ID" "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" '
                '"$EXPECTED_SIGN_IDENTITY"\n'
                + 'validate_resolved_migration_anchor_identity '
                '"$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID" '
                '"$EXPECTED_MIGRATION_ANCHOR_TEAM_ID"\n',
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        wrong_identity = subprocess.run(
            [
                "bash", "-c",
                base_script
                + 'validate_stable_release_context wrong.bundle '
                '"$EXPECTED_APP_TEAM_ID" "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" '
                '"$EXPECTED_SIGN_IDENTITY"\n',
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(wrong_identity.returncode, 0)
        self.assertIn("Stable application bundle identifier mismatch", wrong_identity.stderr)
        wrong_anchor = subprocess.run(
            [
                "bash", "-c",
                base_script
                + 'validate_resolved_migration_anchor_identity wrong.anchor '
                '"$EXPECTED_MIGRATION_ANCHOR_TEAM_ID"\n',
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(wrong_anchor.returncode, 0)
        self.assertIn("Identity migration anchor identifier mismatch", wrong_anchor.stderr)

    def test_stable_identity_consumers_do_not_embed_policy_identity_literals(self) -> None:
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        consumers = {
            "package_app": (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8"),
            "sign_staged": (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8"),
            "workflow": (
                SCRIPT_DIR.parent / ".github" / "workflows" / "release.yml"
            ).read_text(encoding="utf-8"),
        }
        identity_literals = set()
        for identity in policy["identities"].values():
            identity_literals.update(
                value
                for key, value in identity.items()
                if key
                in {
                    "bundleIdentifier",
                    "teamIdentifier",
                    "developerIDRequirement",
                    "developerIDApplicationIdentityName",
                    "developerIDInstallerIdentityName",
                }
            )
        for consumer_name, source in consumers.items():
            for literal in identity_literals:
                with self.subTest(consumer=consumer_name, literal=literal):
                    self.assertNotIn(literal, source)

    def test_signing_mode_is_derived_from_the_reviewed_bundle_team_pair(self) -> None:
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        for identity_name, marker in (
            ("legacy", "developer-id"),
            ("successor", "successor-developer-id"),
        ):
            with self.subTest(identity=identity_name):
                identity = policy["identities"][identity_name]
                result = self.rollout(
                    "signing-mode",
                    "--policy", str(self.POLICY),
                    "--bundle-id", identity["bundleIdentifier"],
                    "--team-id", identity["teamIdentifier"],
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), marker)

        rejected = self.rollout(
            "signing-mode",
            "--policy", str(self.POLICY),
            "--bundle-id", policy["identities"]["successor"]["bundleIdentifier"],
            "--team-id", policy["identities"]["legacy"]["teamIdentifier"],
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match exactly one reviewed Apple identity", rejected.stderr)

    def chain_predecessors(self, role: str) -> list[dict]:
        placeholder = "0" * 64
        if role == "transition":
            return [{"role": "preparer", "tag": "v0.1.0", "rolloutManifestSha256": placeholder}]
        if role == "successor":
            return [
                {"role": "transition", "tag": "v0.2.0", "rolloutManifestSha256": placeholder},
                {"role": "preparer", "tag": "v0.1.0", "rolloutManifestSha256": placeholder},
            ]
        return []

    def make_declaration(
        self,
        directory: Path,
        role: str,
        predecessors: list[dict] | None = None,
        channel: str = "stable",
        **overrides: object,
    ) -> Path:
        phase = {"legacy": "disabled", "preparer": "legacy-preparer"}.get(role, "disabled")
        identity = "successor" if role in ("transition", "successor") else "legacy"
        declaration = {
            "schemaVersion": 1,
            "channel": channel,
            "currentRole": role,
            "eligibilityProfile": f"{channel}-rollout-v1",
            "expectedMigrationPhase": phase,
            "expectedSigningIdentity": identity,
            "predecessors": predecessors or [],
        }
        declaration.update(overrides)
        path = directory / f"{channel}-rollout-{role}.json"
        path.write_text(json.dumps(declaration, indent=2) + "\n", encoding="utf-8")
        return path

    def make_release(
        self,
        directory: Path,
        role: str,
        marketing: str,
        build: str,
        predecessors: list[dict] | None = None,
        predecessor_manifests: list[Path] | None = None,
        channel: str = "stable",
        release_tag: str | None = None,
        enclosure_basename: str | None = None,
    ) -> dict:
        release_dir = directory / f"{role}-{build}"
        release_dir.mkdir(parents=True, exist_ok=True)
        version_env = release_dir / "version.env"
        successor_identity = role in ("transition", "successor")
        version_env.write_text(
            "APP_NAME=RepoPrompt\n"
            f"MARKETING_VERSION={marketing}\n"
            f"BUILD_NUMBER={build}\n"
            f"BUNDLE_ID={'com.repoprompt.ce' if successor_identity else 'com.pvncher.repoprompt.ce'}\n"
            f"SIGNING_TEAM_ID={'69N6K965SF' if successor_identity else '648A27MST5'}\n",
            encoding="utf-8",
        )
        suffix = ".pkg" if role == "transition" else ".zip"
        enclosure = release_dir / f"{enclosure_basename or f'RepoPrompt-{marketing}-{build}'}{suffix}"
        enclosure.write_text(f"enclosure {role} {build}\n", encoding="utf-8")
        app_manifest = release_dir / f"RepoPrompt-{marketing}-{build}-artifact-manifest.json"
        app_manifest.write_text('{"schema_version":1}\n', encoding="utf-8")
        declaration = self.make_declaration(
            release_dir,
            role,
            predecessors,
            channel=channel,
        )
        appcast = release_dir / "appcast.xml"
        manifest = release_dir / (
            "identity-rollout.json"
            if channel == "tip"
            else f"RepoPrompt-{marketing}-{build}-stable-rollout.json"
        )
        release_tag = release_tag or (f"tip-{build}" if channel == "tip" else f"v{marketing}")
        arguments = [
            "generate",
            "--declaration", str(declaration),
            "--policy", str(self.POLICY),
            "--version-env", str(version_env),
            "--release-tag", release_tag,
            "--release-commit", f"commit-{build}",
            "--migration-phase", "legacy-preparer" if role == "preparer" else "disabled",
            "--enclosure", str(enclosure),
            "--enclosure-signature", f"sig-{role}-{build}",
            "--app-artifact-manifest", str(app_manifest),
            "--appcast-output", str(appcast),
            "--manifest-output", str(manifest),
        ]
        if enclosure_basename:
            arguments += ["--enclosure-basename", enclosure_basename]
        for predecessor_manifest in predecessor_manifests or []:
            arguments += ["--predecessor-manifest", str(predecessor_manifest)]
        result = self.rollout(*arguments)
        return {
            "result": result,
            "dir": release_dir,
            "version_env": version_env,
            "declaration": declaration,
            "enclosure": enclosure,
            "app_manifest": app_manifest,
            "appcast": appcast,
            "manifest": manifest,
            "arguments": arguments,
        }

    def make_pts_ladder(self) -> tuple[Path, dict, dict, dict]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        preparer = self.make_release(temp_dir, "preparer", "1.2.0", "120")
        self.assertEqual(preparer["result"].returncode, 0, preparer["result"].stderr)
        transition = self.make_release(
            temp_dir,
            "transition",
            "1.5.0",
            "150",
            predecessors=[
                {
                    "role": "preparer",
                    "tag": "v1.2.0",
                    "rolloutManifestSha256": hashlib.sha256(preparer["manifest"].read_bytes()).hexdigest(),
                }
            ],
            predecessor_manifests=[preparer["manifest"]],
        )
        self.assertEqual(transition["result"].returncode, 0, transition["result"].stderr)
        successor = self.make_release(
            temp_dir,
            "successor",
            "2.0.0",
            "200",
            predecessors=[
                {
                    "role": "transition",
                    "tag": "v1.5.0",
                    "rolloutManifestSha256": hashlib.sha256(transition["manifest"].read_bytes()).hexdigest(),
                },
                {
                    "role": "preparer",
                    "tag": "v1.2.0",
                    "rolloutManifestSha256": hashlib.sha256(preparer["manifest"].read_bytes()).hexdigest(),
                },
            ],
            predecessor_manifests=[transition["manifest"], preparer["manifest"]],
        )
        self.assertEqual(successor["result"].returncode, 0, successor["result"].stderr)
        return temp_dir, preparer, transition, successor

    def validate_arguments(self, release: dict, allowed_roles: str | None = None) -> list[str]:
        arguments = list(release["arguments"])
        arguments[0] = "validate"
        generate_only = arguments.index("--appcast-output")
        arguments[generate_only : generate_only + 4] = [
            "--appcast", str(release["appcast"]),
            "--manifest", str(release["manifest"]),
        ]
        signature_index = arguments.index("--enclosure-signature")
        del arguments[signature_index : signature_index + 2]
        if allowed_roles:
            arguments += ["--allowed-roles", allowed_roles]
        return arguments

    def test_tip_workflow_preflights_role_credentials_before_secret_free_stage(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        preflight = workflow.split("\n  credential-preflight:", 1)[1].split("\n  stage:", 1)[0]
        stage = workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]

        self.assertIn("needs: setup", preflight)
        self.assertIn("environment: tip-release", preflight)
        self.assertIn(
            "uses: ./trusted-control-plane/.github/actions/verify-tip-context", preflight
        )
        self.assertNotIn("stable_rollout.py packaging-context", workflow)
        self.assertLess(
            preflight.index("Verify immutable Tip release context"),
            preflight.index("Validate role-selected Tip credentials"),
        )
        self.assertIn('case "$ROLLOUT_IDENTITY" in', preflight)
        for secret_name in (
            "SUCCESSOR_NOTARYTOOL_PRIVATE_KEY_BASE64",
            "SUCCESSOR_NOTARYTOOL_KEY_ID",
            "SUCCESSOR_NOTARYTOOL_ISSUER_ID",
        ):
            self.assertIn(f"{secret_name}: ${{{{ secrets.{secret_name} }}}}", preflight)
        for secret_name in (
            "SUCCESSOR_DEVELOPER_ID_INSTALLER_P12_BASE64",
            "SUCCESSOR_DEVELOPER_ID_INSTALLER_P12_PASSWORD",
        ):
            self.assertIn(f"secrets.{secret_name}", preflight)
        self.assertIn('decode_value "application certificate"', preflight)
        self.assertIn('decode_value "notarytool private key"', preflight)
        self.assertIn('if [[ "$ROLLOUT_ROLE" == "transition" ]]', preflight)
        self.assertIn('if [[ "$ROLLOUT_ROLE" == "preparer" ]]', preflight)
        self.assertIn("needs:\n      - setup\n      - credential-preflight", stage)
        self.assertLess(workflow.index("credential-preflight:"), workflow.index("\n  stage:"))
        self.assertLess(workflow.index("\n  stage:"), workflow.index("\n  sign:"))
        self.assertNotIn("TIP_UPDATE_REPOSITORY_TOKEN", preflight)

    def test_tip_signing_uses_policy_labels_and_role_selected_notary_credentials(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        import_step = workflow.split("      - name: Import role-selected Developer ID certificates", 1)[1].split(
            "      - name: Prepare successor identity migration anchor", 1
        )[0]
        anchor_step = workflow.split("      - name: Prepare successor identity migration anchor", 1)[1].split(
            "      - name: Prepare provisioning profile and notarization key", 1
        )[0]
        notary_step = workflow.split("      - name: Prepare provisioning profile and notarization key", 1)[1].split(
            "      - name: Install Sentry CLI", 1
        )[0]

        for stale_name in (
            "CONFIGURED_LEGACY_SIGN_IDENTITY",
            "CONFIGURED_SUCCESSOR_SIGN_IDENTITY",
            "CONFIGURED_SUCCESSOR_INSTALLER_IDENTITY",
            "SUCCESSOR_INSTALLER_IDENTITY",
            "SUCCESSOR_SIGN_IDENTITY: ${{ vars.SUCCESSOR_SIGN_IDENTITY }}",
            "SIGN_IDENTITY: ${{ vars.SIGN_IDENTITY }}",
        ):
            self.assertNotIn(stale_name, workflow)
        self.assertIn('verify_identity codesigning "$EXPECTED_SIGN_IDENTITY" application', import_step)
        self.assertIn('verify_identity basic "$EXPECTED_INSTALLER_IDENTITY" installer', import_step)
        self.assertIn('security import "$installer_certificate" -k "$KEYCHAIN_PATH"', import_step)
        self.assertIn('printf \'SIGN_IDENTITY=%s\\n\' "$EXPECTED_SIGN_IDENTITY"', import_step)
        self.assertIn(
            'grep -F "\\\"$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY\\\""',
            anchor_step,
        )
        self.assertIn(
            'codesign --force --sign "$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY"',
            anchor_step,
        )
        self.assertIn('--identifier "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"', anchor_step)
        self.assertIn('-R="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT"', anchor_step)
        for secret_name in (
            "NOTARYTOOL_PRIVATE_KEY_BASE64",
            "NOTARYTOOL_KEY_ID",
            "NOTARYTOOL_ISSUER_ID",
            "SUCCESSOR_NOTARYTOOL_PRIVATE_KEY_BASE64",
            "SUCCESSOR_NOTARYTOOL_KEY_ID",
            "SUCCESSOR_NOTARYTOOL_ISSUER_ID",
        ):
            self.assertIn(f"secrets.{secret_name}", notary_step)
        self.assertIn('case "$ROLLOUT_IDENTITY" in', notary_step)
        self.assertIn("printf 'NOTARYTOOL_KEY_ID=%s\\n'", notary_step)
        self.assertIn("printf 'NOTARYTOOL_ISSUER_ID=%s\\n'", notary_step)
        self.assertNotIn("\n          NOTARYTOOL_KEY_ID: ${{ secrets.NOTARYTOOL_KEY_ID }}", workflow)
        self.assertNotIn("\n          NOTARYTOOL_ISSUER_ID: ${{ secrets.NOTARYTOOL_ISSUER_ID }}", workflow)
        self.assertNotIn("\n          INSTALLER_IDENTITY=", workflow)

    def test_packaging_context_projects_policy_application_and_installer_labels(self) -> None:
        _temp_dir, preparer, transition, successor = self.make_pts_ladder()
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        for role, release, identity_name in (
            ("preparer", preparer, "legacy"),
            ("transition", transition, "successor"),
            ("successor", successor, "successor"),
        ):
            with self.subTest(role=role):
                result = self.rollout(
                    "packaging-context",
                    "--declaration", str(release["declaration"]),
                    "--policy", str(self.POLICY),
                    "--version-env", str(release["version_env"]),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                context = self.shell_assignments(result.stdout)
                identity = policy["identities"][identity_name]
                self.assertEqual(context["EXPECTED_SIGN_IDENTITY"], identity["developerIDApplicationIdentityName"])
                expected_installer = (
                    policy["identities"]["successor"]["developerIDInstallerIdentityName"]
                    if role == "transition"
                    else ""
                )
                self.assertEqual(context["EXPECTED_INSTALLER_IDENTITY"], expected_installer)
                self.assertEqual(context["EXPECTED_APP_BUNDLE_ID"], identity["bundleIdentifier"])
                self.assertEqual(context["EXPECTED_APP_TEAM_ID"], identity["teamIdentifier"])
                self.assertEqual(context["EXPECTED_APP_REQUIREMENT"], identity["developerIDRequirement"])
                self.assertEqual(
                    context["EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER"],
                    f"{identity['teamIdentifier']}.{identity['bundleIdentifier']}",
                )
                successor_identity = policy["identities"]["successor"]
                expected_anchor = successor_identity if role == "preparer" else None
                for key, policy_key in (
                    ("EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID", "bundleIdentifier"),
                    ("EXPECTED_MIGRATION_ANCHOR_TEAM_ID", "teamIdentifier"),
                    ("EXPECTED_MIGRATION_ANCHOR_REQUIREMENT", "developerIDRequirement"),
                    ("EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY", "developerIDApplicationIdentityName"),
                ):
                    self.assertEqual(
                        context[key], expected_anchor[policy_key] if expected_anchor else ""
                    )

    def test_policy_declaration_and_requirement_authorities_agree(self) -> None:
        policy = json.loads(self.POLICY.read_text(encoding="utf-8"))
        runtime_policy = (
            SCRIPT_DIR.parent
            / "Sources/RepoPrompt/Infrastructure/Security/RuntimeCodeSigningPolicy.swift"
        ).read_text(encoding="utf-8")
        info_template = (SCRIPT_DIR.parent / "AppBundle/Info.plist.template").read_text(encoding="utf-8")
        sign_staged = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")
        pkg_builder = (SCRIPT_DIR / "build_identity_transition_pkg.sh").read_text(encoding="utf-8")
        package_app = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        mcp_source = (SCRIPT_DIR.parent / "Sources/RepoPromptMCP/main.swift").read_text(encoding="utf-8")

        legacy = policy["identities"]["legacy"]
        successor = policy["identities"]["successor"]
        requirement_template = (
            'anchor apple generic and identifier "{bundle}" and certificate '
            'leaf[subject.OU] = "{team}" and certificate '
            "leaf[field.1.2.840.113635.100.6.1.13] exists"
        )
        for identity in (legacy, successor):
            self.assertEqual(
                identity["developerIDRequirement"],
                requirement_template.format(
                    bundle=identity["bundleIdentifier"], team=identity["teamIdentifier"]
                ),
            )
        self.assertIn(f'developerIDBundleIdentifier = "{legacy["bundleIdentifier"]}"', runtime_policy)
        self.assertIn(f'signingTeamIdentifier = "{legacy["teamIdentifier"]}"', runtime_policy)
        self.assertIn(
            f'successorDeveloperIDBundleIdentifier = "{successor["bundleIdentifier"]}"', runtime_policy
        )
        self.assertIn(f'successorSigningTeamIdentifier = "{successor["teamIdentifier"]}"', runtime_policy)
        self.assertNotIn("SUCCESSOR_APP_REQUIREMENT=", pkg_builder)
        self.assertIn('[[ "$TRANSITION_APP_REQUIREMENT" == "$EXPECTED_APP_REQUIREMENT" ]]', pkg_builder)
        self.assertIn('python3 "$CONTRACT" context-shell', pkg_builder)
        self.assertIn('signing_mode_marker="$EXPECTED_SIGNING_MODE"', sign_staged)
        self.assertIn(
            'IDENTITY_MIGRATION_TARGET_REQUIREMENT="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT"',
            sign_staged,
        )
        self.assertIn('-R="$EXPECTED_APP_REQUIREMENT" "$APP_BUNDLE"', sign_staged)
        self.assertIn('stable_rollout.py" signing-mode', package_app)
        self.assertIn(
            f'repoPromptCEReleaseBundleIdentifier = "{successor["bundleIdentifier"]}"',
            mcp_source,
        )

        sparkle = policy["sparkle"]
        self.assertIn(f"<string>{sparkle['stableFeedURL']}</string>", info_template)
        self.assertIn(f"<string>{sparkle['sparklePublicEdDSAValue']}</string>", info_template)
        self.assertIn(
            f"<key>LSMinimumSystemVersion</key><string>{sparkle['minimumSystemVersion']}</string>",
            info_template,
        )
        self.assertEqual(sparkle["updateRepository"], self.UPDATE_REPOSITORY)
        self.assertEqual(sparkle["tipUpdateRepository"], "repoprompt/repoprompt-ce-tip-updates")
        self.assertEqual(
            sparkle["tipFeedURL"],
            "https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/latest/download/appcast.xml",
        )
        self.assertEqual(
            legacy["developerIDApplicationIdentityName"],
            "Developer ID Application: Eric Provencher (648A27MST5)",
        )
        self.assertEqual(
            successor["developerIDApplicationIdentityName"],
            "Developer ID Application: Samuel Baron (69N6K965SF)",
        )
        self.assertEqual(
            successor["developerIDInstallerIdentityName"],
            "Developer ID Installer: Samuel Baron (69N6K965SF)",
        )

        declaration = json.loads(self.DECLARATION.read_text(encoding="utf-8"))
        self.assertEqual(declaration["currentRole"], "legacy")
        self.assertEqual(declaration["predecessors"], [])
        self.assertEqual(declaration["expectedMigrationPhase"], "disabled")
        self.assertEqual(declaration["expectedSigningIdentity"], "legacy")

        tip_declaration = json.loads(self.TIP_DECLARATION.read_text(encoding="utf-8"))
        self.assertEqual(tip_declaration["channel"], "tip")
        self.assertEqual(tip_declaration["currentRole"], "transition")
        self.assertEqual(tip_declaration["expectedMigrationPhase"], "disabled")
        self.assertEqual(tip_declaration["expectedSigningIdentity"], "successor")
        self.assertEqual(
            tip_declaration["predecessors"],
            [
                {
                    "role": "preparer",
                    "tag": "tip-2f94412e6ab5",
                    "rolloutManifestSha256": "3c69703fa7582105633b36e8874fe2a28e1832aabb776351e68dbf3367e122db",
                }
            ],
        )

    def test_single_legacy_release_generates_one_deterministic_application_item(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        release = self.make_release(temp_dir, "legacy", "1.0.0", "1")
        self.assertEqual(release["result"].returncode, 0, release["result"].stderr)

        appcast = release["appcast"].read_text(encoding="utf-8")
        self.assertEqual(appcast.count("<item>"), 1)
        self.assertIn("<repoprompt:rolloutRole>legacy</repoprompt:rolloutRole>", appcast)
        self.assertIn("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", appcast)
        self.assertNotIn("minimumUpdateVersion", appcast)
        self.assertNotIn("minimumAutoupdateVersion", appcast)
        self.assertNotIn("installationType", appcast)
        self.assertIn(
            f"https://github.com/{self.UPDATE_REPOSITORY}/releases/download/v1.0.0/RepoPrompt-1.0.0-1.zip",
            appcast,
        )

        first_manifest = release["manifest"].read_text(encoding="utf-8")
        rerun = self.rollout(*release["arguments"])
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertEqual(release["manifest"].read_text(encoding="utf-8"), first_manifest)
        self.assertEqual(release["appcast"].read_text(encoding="utf-8"), appcast)

        validated = self.rollout(*self.validate_arguments(release, allowed_roles="legacy,preparer"))
        self.assertEqual(validated.returncode, 0, validated.stderr)

        preparer = self.make_release(temp_dir, "preparer", "1.1.0", "2")
        self.assertEqual(preparer["result"].returncode, 0, preparer["result"].stderr)
        self.assertEqual(preparer["appcast"].read_text(encoding="utf-8").count("<item>"), 1)

    def test_synthetic_pts_fixtures_produce_deterministic_aggregate_appcast(self) -> None:
        _temp_dir, preparer, transition, successor = self.make_pts_ladder()

        appcast = successor["appcast"].read_text(encoding="utf-8")
        self.assertEqual(appcast.count("<item>"), 3)
        roles = re.findall(r"<repoprompt:rolloutRole>([a-z]+)</repoprompt:rolloutRole>", appcast)
        self.assertEqual(roles, ["successor", "transition", "preparer"])
        builds = re.findall(r"<sparkle:version>([0-9.]+)</sparkle:version>", appcast)
        self.assertEqual(builds, ["200", "150", "120"])
        hard_ladders = re.findall(
            r"<sparkle:minimumUpdateVersion>([0-9.]+)</sparkle:minimumUpdateVersion>", appcast
        )
        compatibility_ladders = re.findall(
            r"<sparkle:minimumAutoupdateVersion>([0-9.]+)</sparkle:minimumAutoupdateVersion>", appcast
        )
        self.assertEqual(hard_ladders, ["150", "120"])
        self.assertEqual(compatibility_ladders, hard_ladders)
        manifest = json.loads(successor["manifest"].read_text(encoding="utf-8"))
        for item in manifest["appcastItems"]:
            self.assertIn("minimumUpdateVersion", item)
            self.assertNotIn("minimumAutoupdateVersion", item)
        self.assertEqual(appcast.count("<sparkle:minimumSystemVersion>14.0<"), 3)
        self.assertEqual(appcast.count('sparkle:installationType="package"'), 1)
        for tag, name in (
            ("v2.0.0", "RepoPrompt-2.0.0-200.zip"),
            ("v1.5.0", "RepoPromptTransition".replace("RepoPromptTransition", "RepoPrompt-1.5.0-150.pkg")),
            ("v1.2.0", "RepoPrompt-1.2.0-120.zip"),
        ):
            self.assertIn(
                f"https://github.com/{self.UPDATE_REPOSITORY}/releases/download/{tag}/{name}", appcast
            )

        validated = self.rollout(
            *self.validate_arguments(successor, allowed_roles="successor,transition,preparer")
        )
        self.assertEqual(validated.returncode, 0, validated.stderr)

        max_build = self.rollout("max-build", "--appcast", str(successor["appcast"]))
        self.assertEqual(max_build.stdout.strip(), "200")

        siblings = self.rollout("sibling-values", "--manifest", str(successor["manifest"]))
        rows = [line.split("\t") for line in siblings.stdout.splitlines()]
        self.assertEqual([(row[1], row[2]) for row in rows], [("transition", "v1.5.0"), ("preparer", "v1.2.0")])
        self.assertEqual(rows[0][7], "RepoPrompt-1.5.0-150-stable-rollout.json")

    def test_transition_normalizes_the_authenticated_public_preparer_floor_shape(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        preparer = self.make_release(
            temp_dir,
            "preparer",
            "1.2.0",
            "120",
            channel="tip",
            release_tag="tip-public-preparer",
            enclosure_basename="RepoPrompt-tip-public-preparer-120",
        )
        self.assertEqual(preparer["result"].returncode, 0, preparer["result"].stderr)

        public_preparer = json.loads(preparer["manifest"].read_text(encoding="utf-8"))
        public_item = public_preparer["appcastItems"][0]
        self.assertIsNone(public_item.pop("minimumUpdateVersion"))
        public_item["minimumAutoupdateVersion"] = None
        preparer["manifest"].write_text(
            json.dumps(public_preparer, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        transition = self.make_release(
            temp_dir,
            "transition",
            "1.5.0",
            "150",
            predecessors=[
                {
                    "role": "preparer",
                    "tag": "tip-public-preparer",
                    "rolloutManifestSha256": hashlib.sha256(
                        preparer["manifest"].read_bytes()
                    ).hexdigest(),
                }
            ],
            predecessor_manifests=[preparer["manifest"]],
            channel="tip",
            release_tag="tip-transition",
            enclosure_basename="RepoPrompt-tip-transition-150",
        )
        self.assertEqual(transition["result"].returncode, 0, transition["result"].stderr)
        manifest = json.loads(transition["manifest"].read_text(encoding="utf-8"))
        self.assertEqual(
            [item["minimumUpdateVersion"] for item in manifest["appcastItems"]],
            ["120", None],
        )
        self.assertTrue(
            all("minimumAutoupdateVersion" not in item for item in manifest["appcastItems"])
        )

    def test_tip_pts_ladder_reuses_one_feed_and_accumulates_top_level_items(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)

        preparer = self.make_release(
            temp_dir,
            "preparer",
            "1.2.0",
            "100.1.1",
            channel="tip",
            release_tag="tip-preparer",
            enclosure_basename="RepoPrompt-tip-preparer-100.1.1",
        )
        self.assertEqual(preparer["result"].returncode, 0, preparer["result"].stderr)
        transition = self.make_release(
            temp_dir,
            "transition",
            "1.2.0",
            "100.1.2",
            predecessors=[
                {
                    "role": "preparer",
                    "tag": "tip-preparer",
                    "rolloutManifestSha256": hashlib.sha256(
                        preparer["manifest"].read_bytes()
                    ).hexdigest(),
                }
            ],
            predecessor_manifests=[preparer["manifest"]],
            channel="tip",
            release_tag="tip-transition",
            enclosure_basename="RepoPrompt-tip-transition-100.1.2",
        )
        self.assertEqual(transition["result"].returncode, 0, transition["result"].stderr)
        successor = self.make_release(
            temp_dir,
            "successor",
            "1.2.0",
            "100.1.3",
            predecessors=[
                {
                    "role": "transition",
                    "tag": "tip-transition",
                    "rolloutManifestSha256": hashlib.sha256(
                        transition["manifest"].read_bytes()
                    ).hexdigest(),
                },
                {
                    "role": "preparer",
                    "tag": "tip-preparer",
                    "rolloutManifestSha256": hashlib.sha256(
                        preparer["manifest"].read_bytes()
                    ).hexdigest(),
                },
            ],
            predecessor_manifests=[transition["manifest"], preparer["manifest"]],
            channel="tip",
            release_tag="tip-successor",
            enclosure_basename="RepoPrompt-tip-successor-100.1.3",
        )
        self.assertEqual(successor["result"].returncode, 0, successor["result"].stderr)

        appcast = successor["appcast"].read_text(encoding="utf-8")
        self.assertEqual(appcast.count("<item>"), 3)
        self.assertEqual(
            re.findall(r"<repoprompt:rolloutRole>([a-z]+)</repoprompt:rolloutRole>", appcast),
            ["successor", "transition", "preparer"],
        )
        self.assertEqual(
            re.findall(r"<sparkle:version>([0-9.]+)</sparkle:version>", appcast),
            ["100.1.3", "100.1.2", "100.1.1"],
        )
        hard_ladders = re.findall(
            r"<sparkle:minimumUpdateVersion>([0-9.]+)</sparkle:minimumUpdateVersion>",
            appcast,
        )
        compatibility_ladders = re.findall(
            r"<sparkle:minimumAutoupdateVersion>([0-9.]+)</sparkle:minimumAutoupdateVersion>",
            appcast,
        )
        self.assertEqual(hard_ladders, ["100.1.2", "100.1.1"])
        self.assertEqual(compatibility_ladders, hard_ladders)
        self.assertEqual(appcast.count('sparkle:installationType="package"'), 1)
        self.assertNotIn(self.UPDATE_REPOSITORY + "/releases", appcast)
        for tag, basename, suffix in (
            ("tip-successor", "RepoPrompt-tip-successor-100.1.3", ".zip"),
            ("tip-transition", "RepoPrompt-tip-transition-100.1.2", ".pkg"),
            ("tip-preparer", "RepoPrompt-tip-preparer-100.1.1", ".zip"),
        ):
            self.assertIn(
                f"https://github.com/{self.TIP_UPDATE_REPOSITORY}/releases/download/"
                f"{tag}/{basename}{suffix}",
                appcast,
            )

        manifest = json.loads(successor["manifest"].read_text(encoding="utf-8"))
        self.assertEqual(manifest["channel"], "tip")
        self.assertEqual(manifest["currentRole"], "successor")
        self.assertEqual(
            [entry["rolloutManifestName"] for entry in manifest["appcastItems"][1:]],
            ["identity-rollout.json", "identity-rollout.json"],
        )

    def test_rollout_tampering_and_invalid_ladders_fail_closed(self) -> None:
        temp_dir, preparer, transition, successor = self.make_pts_ladder()

        def successor_validate() -> subprocess.CompletedProcess[str]:
            return self.rollout(
                *self.validate_arguments(successor, allowed_roles="successor,transition,preparer")
            )

        with self.subTest("predecessor manifest byte flip breaks the SHA-256 binding"):
            original = preparer["manifest"].read_text(encoding="utf-8")
            preparer["manifest"].write_text(original.replace("sig-preparer-120", "sig-tampered"), encoding="utf-8")
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rollout manifest digest mismatch", result.stderr)
            preparer["manifest"].write_text(original, encoding="utf-8")

        with self.subTest("enclosure mutation breaks the digest binding"):
            successor["enclosure"].write_text("tampered enclosure\n", encoding="utf-8")
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)
            successor["enclosure"].write_text("enclosure successor 200\n", encoding="utf-8")

        with self.subTest("compatibility projection divergence is rejected"):
            appcast_text = successor["appcast"].read_text(encoding="utf-8")
            successor["appcast"].write_text(
                appcast_text.replace(
                    "<sparkle:minimumAutoupdateVersion>150<", "<sparkle:minimumAutoupdateVersion>149<", 1
                ),
                encoding="utf-8",
            )
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("accumulated appcast does not match", result.stderr)
            successor["appcast"].write_text(appcast_text, encoding="utf-8")

        with self.subTest("hard gate divergence is rejected"):
            appcast_text = successor["appcast"].read_text(encoding="utf-8")
            successor["appcast"].write_text(
                appcast_text.replace(
                    "<sparkle:minimumUpdateVersion>150<",
                    "<sparkle:minimumUpdateVersion>149<",
                    1,
                ),
                encoding="utf-8",
            )
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("accumulated appcast does not match", result.stderr)
            successor["appcast"].write_text(appcast_text, encoding="utf-8")

        with self.subTest("missing hard gate projection is rejected"):
            appcast_text = successor["appcast"].read_text(encoding="utf-8")
            successor["appcast"].write_text(
                appcast_text.replace(
                    "      <sparkle:minimumUpdateVersion>150</sparkle:minimumUpdateVersion>\n",
                    "",
                    1,
                ),
                encoding="utf-8",
            )
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("accumulated appcast does not match", result.stderr)
            successor["appcast"].write_text(appcast_text, encoding="utf-8")

        with self.subTest("manifest cannot add a second floor authority"):
            manifest_text = successor["manifest"].read_text(encoding="utf-8")
            manifest = json.loads(manifest_text)
            manifest["appcastItems"][0]["minimumAutoupdateVersion"] = "150"
            successor["manifest"].write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("appcastItems mismatch", result.stderr)
            successor["manifest"].write_text(manifest_text, encoding="utf-8")

        invalid_declarations = [
            ("unknown role", {"currentRole": "beta"}, "unknown rollout role"),
            (
                "duplicate roles",
                {
                    "predecessors": [
                        {"role": "preparer", "tag": "v1.2.0", "rolloutManifestSha256": "0" * 64},
                        {"role": "preparer", "tag": "v1.1.0", "rolloutManifestSha256": "0" * 64},
                    ],
                    "currentRole": "successor",
                    "expectedSigningIdentity": "successor",
                },
                "not an allowed newest-first rollout chain",
            ),
            (
                "legacy cannot carry siblings",
                {
                    "predecessors": [
                        {"role": "preparer", "tag": "v1.2.0", "rolloutManifestSha256": "0" * 64}
                    ]
                },
                "not an allowed newest-first rollout chain",
            ),
            ("wrong phase for role", {"expectedMigrationPhase": "legacy-preparer"}, "must be disabled"),
            ("wrong identity for role", {"expectedSigningIdentity": "successor"}, "must be legacy"),
        ]
        for label, overrides, expected_error in invalid_declarations:
            with self.subTest(label):
                declaration = self.make_declaration(temp_dir, "legacy", **overrides)
                result = self.rollout("current-role", "--declaration", str(declaration))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)

        with self.subTest("out-of-order builds are rejected"):
            older_with_higher_build = self.make_release(temp_dir, "preparer", "9.9.9", "999")
            self.assertEqual(older_with_higher_build["result"].returncode, 0)
            broken = self.make_release(
                temp_dir,
                "transition",
                "1.6.0",
                "160",
                predecessors=[
                    {
                        "role": "preparer",
                        "tag": "v9.9.9",
                        "rolloutManifestSha256": hashlib.sha256(
                            older_with_higher_build["manifest"].read_bytes()
                        ).hexdigest(),
                    }
                ],
                predecessor_manifests=[older_with_higher_build["manifest"]],
            )
            self.assertNotEqual(broken["result"].returncode, 0)
            self.assertIn("strictly ordered newest-first", broken["result"].stderr)

        with self.subTest("manifest field tampering is rejected with the exact field"):
            manifest_text = successor["manifest"].read_text(encoding="utf-8")
            successor["manifest"].write_text(
                manifest_text.replace('"installationType": "package"', '"installationType": "application"'),
                encoding="utf-8",
            )
            result = successor_validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatch", result.stderr)
            successor["manifest"].write_text(manifest_text, encoding="utf-8")

    def test_stable_surfaces_stay_locked_while_tip_requires_explicit_role_dispatch(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)

        for role in ("legacy", "preparer"):
            with self.subTest(allowed=role):
                declaration = self.make_declaration(temp_dir, role)
                result = self.rollout(
                    "workflow-guard", "--declaration", str(declaration), "--policy", str(self.POLICY)
                )
                self.assertEqual(result.returncode, 0, result.stderr)

        for role in ("transition", "successor"):
            with self.subTest(rejected=role):
                declaration = self.make_declaration(temp_dir, role, self.chain_predecessors(role))
                result = self.rollout(
                    "workflow-guard", "--declaration", str(declaration), "--policy", str(self.POLICY)
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"reject the {role} rollout role", result.stderr)

        workflows_dir = SCRIPT_DIR.parent / ".github" / "workflows"
        release_workflow = (workflows_dir / "release.yml").read_text(encoding="utf-8")
        promote_workflow = (workflows_dir / "release-promote.yml").read_text(encoding="utf-8")
        tip_workflow = (workflows_dir / "main-tip.yml").read_text(encoding="utf-8")
        self.assertEqual(release_workflow.count("stable_rollout.py workflow-guard"), 2)
        self.assertEqual(promote_workflow.count("stable_rollout.py workflow-guard"), 1)
        self.assertIn("tip_release_context.py resolve", tip_workflow)
        self.assertEqual(tip_workflow.count("tip_release_context.py resolve"), 1)
        self.assertNotIn("stable_rollout.py packaging-context", tip_workflow)
        self.assertIn("confirm_identity_rollout_role", tip_workflow)
        self.assertIn('if [[ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]]', tip_workflow)
        self.assertNotIn("release-rollout.json", tip_workflow)

        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        self.assertIn("require_dormant_rollout_declaration", release_script)
        self.assertIn("resolve_release_artifact_role", promote_script)
        for script_text in (release_script, promote_script):
            self.assertNotIn("REPOPROMPT_IDENTITY_TRANSITION_TOOLING_UNLOCK", script_text)
            self.assertNotIn("REPOPROMPT_RELEASE_ARTIFACT_ROLE", script_text)
            self.assertNotIn("REPOPROMPT_PREDECESSOR_APPCAST", script_text)

    def test_tip_dispatch_matrix_and_go_no_go_documentation_contract(self) -> None:
        root = SCRIPT_DIR.parent
        workflow = (root / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        releasing = (root / "docs" / "releasing.md").read_text(encoding="utf-8")
        architecture = (
            root / "docs" / "architecture" / "apple-identity-migration.md"
        ).read_text(encoding="utf-8")

        self.assertIn('if [[ "$ROLLOUT_ROLE" != "legacy" ]]', workflow)
        self.assertIn('if [[ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]]', workflow)
        self.assertIn('[[ "$CONFIRMED_ROLLOUT_ROLE" != "$ROLLOUT_ROLE" ]]', workflow)
        self.assertIn('skip_reason="role-requires-manual-review"', workflow)
        self.assertIn("Manual workflow capability, exact-role confirmation, and environment approval", workflow)
        self.assertNotIn("dispatch the Publish Tip workflow manually", workflow)

        for row in (
            "| legacy | Permitted after exact-main setup validation |",
            "| P / `preparer` | Suppressed before credentials or builds |",
            "| T / `transition` | Suppressed before credentials or builds |",
            "| N / `successor` | Suppressed before credentials or builds |",
        ):
            self.assertIn(row, releasing)
        for document in (releasing, architecture):
            self.assertIn("P and T remain manual", document)
            self.assertIn("blockers A and B", document)
            self.assertIn("first T and first N", document)
            self.assertIn("ordinary subsequent N", document)
        self.assertIn("they are not release authorization", releasing)
        self.assertIn("those gates do not authorize a release", architecture)

        # Behavioral: a transition declaration in the tagged source fails
        # promotion before any release lookup or mutation.
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        fixture_root = temp_dir / "transition-source"
        fixture_root.mkdir()
        shutil.copy2(SCRIPT_DIR.parent / "version.env", fixture_root / "version.env")
        transition_declaration = self.make_declaration(
            fixture_root, "transition", self.chain_predecessors("transition")
        )
        shutil.move(str(transition_declaration), fixture_root / "release-rollout.json")
        env = dict(os.environ)
        env["REPOPROMPT_RELEASE_SOURCE_ROOT"] = str(fixture_root)
        env["REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR"] = str(SCRIPT_DIR)
        result = subprocess.run(
            ["bash", str(SCRIPT_DIR / "promote_release.sh"), "verify"],
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dormant until successor rollout enablement", result.stderr)

        for script_name in ("release.sh", "promote_release.sh", "build_identity_transition_pkg.sh", "main_tip_release.sh"):
            with self.subTest(syntax=script_name):
                syntax = subprocess.run(
                    ["bash", "-n", str(SCRIPT_DIR / script_name)], text=True, capture_output=True
                )
                self.assertEqual(syntax.returncode, 0, syntax.stderr)

        # Tip reuses its existing workflow, repository, feed, and appcast name;
        # role changes add accumulated top-level items rather than a sibling feed.
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        tip_workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("generate_tip_rollout_appcast", tip_script)
        self.assertIn("identity-rollout.json", tip_script)
        self.assertIn("$ROLLOUT_UPDATE_REPOSITORY", tip_script)
        self.assertNotIn("repoprompt-ce-tip-updates", tip_script)
        self.assertIn("repoprompt-ce-tip-updates", tip_workflow)
        self.assertNotIn("tip-transition-appcast.xml", tip_script)
        self.assertNotIn("tip-successor-appcast.xml", tip_script)

    def test_transition_pkg_builder_requires_explicit_tip_enablement(self) -> None:
        script = (SCRIPT_DIR / "build_identity_transition_pkg.sh").read_text(encoding="utf-8")
        for marker in (
            'CONTRACT="$SCRIPT_DIR/transition_package_contract.py"',
            'SUPERVISOR="$SCRIPT_DIR/supervise_release_phase.py"',
            'exec python3 "$SUPERVISOR"',
            '--notarytool-json-evidence',
            'productbuild --package "$component_pkg" "$unsigned_product_pkg"',
            'productsign --sign "$TRANSITION_INSTALLER_IDENTITY"',
            'pkgutil --expand-full "$OUTPUT" "$expanded_pkg"',
            "transition-package-payload-comparison",
        ):
            self.assertIn(marker, script)
        self.assertNotIn("pkgbuild --analyze", script)
        self.assertNotIn("version.env", script)
        self.assertNotIn("ACTIVE_SUPERVISOR_PID", script)
        self.assertNotIn("forward_active_signal", script)
        self.assertNotIn("plutil -replace 0.", script)
        self.assertNotIn("skip-notarization", script)
        self.assertNotIn("allow-unstapled", script)

        env = dict(os.environ)
        refused = subprocess.run(
            ["bash", str(SCRIPT_DIR / "build_identity_transition_pkg.sh"), "validate", "--package", "/nonexistent.pkg"],
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("explicit Tip rollout enablement", refused.stderr)

        env["REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG"] = "1"
        enabled = subprocess.run(
            ["bash", str(SCRIPT_DIR / "build_identity_transition_pkg.sh"), "validate", "--package", "/nonexistent.pkg"],
            text=True,
            capture_output=True,
            env=env,
        )
        self.assertNotEqual(enabled.returncode, 0)
        self.assertNotIn("explicit Tip rollout enablement", enabled.stderr)
        self.assertIn("Missing required environment variable: REPOPROMPT_APPROVED_SOURCE_ROOT", enabled.stderr)


if __name__ == "__main__":
    unittest.main()
