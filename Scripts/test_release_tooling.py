#!/usr/bin/env python3
"""Regression tests for trusted release-control helpers."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
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
        signer = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")

        self.assertTrue((SCRIPT_DIR / "identity_migration_anchor.c").is_file())
        self.assertIn("validate_stable_release_context", package_source)
        self.assertIn("legacy-preparer packaging requires a resolved Stable or Tip release context", package_source)
        self.assertIn('EXPECTED_MIGRATION_ANCHOR_REQUIREMENT', signer)
        self.assertIn('validate_resolved_migration_anchor_identity', signer)
        self.assertIn('-R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$identity_migration_anchor"', signer)
        self.assertIn('-R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"', signer)
        self.assertIn('[[ "$SIGN_IDENTITY" == "$EXPECTED_SIGN_IDENTITY" ]]', signer)
        self.assertIn('-R="$EXPECTED_APP_REQUIREMENT" "$APP_BUNDLE"', signer)
        for literal in (
            'IDENTITY_MIGRATION_TARGET_IDENTIFIER="com.repoprompt.ce"',
            'IDENTITY_MIGRATION_TARGET_TEAM_ID="69N6K965SF"',
            '[[ "$BUNDLE_ID" == "com.pvncher.repoprompt.ce" ]]',
            '[[ "$SIGNING_TEAM_ID" == "648A27MST5" ]]',
        ):
            self.assertNotIn(literal, signer)
        self.assertLess(
            signer.index('ditto "$identity_migration_anchor" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"'),
            signer.index('sign_path "$APP_BUNDLE" --entitlements "$app_entitlements"'),
        )

    def test_release_workflows_gate_stable_preparer_and_keep_automatic_tip_publication(self) -> None:
        workflows = SCRIPT_DIR.parent / ".github" / "workflows"
        release_workflow = (workflows / "release.yml").read_text(encoding="utf-8")
        tip_workflow = (workflows / "main-tip.yml").read_text(encoding="utf-8")

        self.assertIn("identity_migration_phase:", release_workflow)
        self.assertIn("default: disabled", release_workflow)
        self.assertIn("- legacy-preparer", release_workflow)
        self.assertEqual(release_workflow.count("stable_rollout.py packaging-context"), 2)
        self.assertEqual(release_workflow.count('--github-env "$GITHUB_ENV"'), 2)
        self.assertIn('--expected-migration-phase "$REQUESTED_IDENTITY_MIGRATION_PHASE"', release_workflow)
        for marker in (
            'EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY',
            '--identifier "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"',
            '-R="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" "$anchor"',
            'grep -Fx "TeamIdentifier=$EXPECTED_MIGRATION_ANCHOR_TEAM_ID"',
        ):
            self.assertIn(marker, release_workflow)
        for literal in ("com.repoprompt.ce", "69N6K965SF"):
            self.assertNotIn(literal, release_workflow)

        trigger = tip_workflow.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]
        dispatch = tip_workflow.split("  workflow_dispatch:", 1)[1].split("\n\nconcurrency:", 1)[0]
        self.assertIn("  workflow_run:", trigger)
        self.assertIn("    workflows: [CI]", trigger)
        self.assertIn("    branches: [main]", trigger)
        self.assertIn("  workflow_dispatch:", trigger)
        self.assertNotIn("      commit:", dispatch)
        self.assertNotIn("    inputs:", dispatch)
        self.assertNotIn("confirm_identity_rollout_role", tip_workflow)
        self.assertIn("DISPATCH_COMMIT: ${{ github.sha }}", tip_workflow)
        self.assertIn("DISPATCH_REF: ${{ github.ref }}", tip_workflow)
        self.assertIn("WORKFLOW_RUN_COMMIT: ${{ github.event.workflow_run.head_sha }}", tip_workflow)
        self.assertIn('[[ "$DISPATCH_REF" == "refs/heads/main" ]]', tip_workflow)
        self.assertIn('[[ "$commit" == "$live_main" ]]', tip_workflow)
        self.assertIn('[[ "$tooling_commit" == "$commit" ]]', tip_workflow)
        self.assertNotIn("CONFIRMED_ROLLOUT_ROLE", tip_workflow)
        self.assertNotIn("automatic-tip-dormant", tip_workflow)
        self.assertNotIn("should-publish", tip_workflow)
        self.assertNotIn("skip-reason", tip_workflow)
        self.assertIn("if: needs.setup.outputs.rollout-role == 'preparer'", tip_workflow)
        self.assertIn("EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY", tip_workflow)
        self.assertIn('--identifier "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"', tip_workflow)
        self.assertIn('-R="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" "$anchor"', tip_workflow)
        self.assertNotIn("EXPECTED_SUCCESSOR_SIGN_IDENTITY", tip_workflow)

        credential_preflight = tip_workflow.split(
            "      - name: Validate role-selected Tip credentials", 1
        )[1].split("\n\n  stage:", 1)[0]
        preflight_run = credential_preflight.split("        run: |\n", 1)[1]
        self.assertIn('PREFLIGHT_KEYCHAIN_PATH="$RUNNER_TEMP/repoprompt-tip-preflight.keychain-db"', preflight_run)
        self.assertIn("trap cleanup_preflight_credentials EXIT", preflight_run)
        self.assertIn('security find-identity -v -p codesigning "$PREFLIGHT_KEYCHAIN_PATH"', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_SIGN_IDENTITY\\""', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY\\""', preflight_run)
        self.assertIn('grep -F "\\"$EXPECTED_INSTALLER_IDENTITY\\""', preflight_run)
        self.assertNotIn("security list-keychains", preflight_run)
        self.assertNotIn("GITHUB_ENV", preflight_run)

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
        self.assertIn("REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1", tip_release)
        self.assertIn("REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1", tip_workflow)

        approved, staged, scripts = self.make_staged_release_fixture()
        generic_override = self.run_staged_validation(
            approved,
            staged,
            scripts,
            release_build_number_override="1",
        )
        self.assertEqual(generic_override.returncode, 0, generic_override.stderr)

        missing = self.run_staged_validation(
            approved,
            staged,
            scripts,
            release_build_number_override="1",
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("missing staged file", missing.stderr)
        self.assertIn("tip-rollout.json", missing.stderr)

        shutil.copy2(approved / "tip-rollout.json", staged / "tip-rollout.json")
        legacy_identity = self.run_staged_validation(
            approved,
            staged,
            scripts,
            release_build_number_override="1",
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertNotEqual(legacy_identity.returncode, 0)
        self.assertIn("BUNDLE_ID, SIGNING_TEAM_ID", legacy_identity.stderr)

        self.project_staged_release_identity(staged, scripts, "com.repoprompt.ce", "69N6K965SF")
        accepted = self.run_staged_validation(
            approved,
            staged,
            scripts,
            release_build_number_override="1",
            tip_archive_contract="tip-rollout-v1",
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        (staged / "tip-rollout.json").write_text("{}\n", encoding="utf-8")
        changed = self.run_staged_validation(
            approved,
            staged,
            scripts,
            release_build_number_override="1",
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
        root = SCRIPT_DIR.parent
        workflow = (root / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        publisher = (SCRIPT_DIR / "publish_tip_release.sh").read_text(encoding="utf-8")

        self.assertIn("name: Publish Tip", workflow)
        concurrency = workflow.split("concurrency:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("group: main-tip-channel", concurrency)
        self.assertNotIn("main-tip-dispatch-channel", concurrency)
        self.assertNotIn("github.event", concurrency)
        self.assertIn("queue: max", concurrency)
        self.assertNotIn("cancel-in-progress:", concurrency)
        self.assertIn("concurrency:\n      group: main-tip-publish\n      queue: max", workflow)

        self.assertIn("DISPATCH_COMMIT: ${{ github.sha }}", workflow)
        self.assertIn('Tip candidate is not the current protected-main commit', workflow)
        self.assertIn("validate-stable-tip-floor", workflow)
        self.assertNotIn("lookup_public_tip_release.sh", workflow)
        self.assertNotIn("tip_release_context.py", workflow)
        self.assertNotIn("tip_release_publication.py", workflow)
        self.assertIn("environment: tip-release", workflow)
        self.assertEqual(workflow.count("TIP_UPDATE_REPOSITORY_TOKEN"), 1)
        self.assertIn('REPOPROMPT_PACKAGED_SMOKE_TIMEOUT: "240"', workflow)
        self.assertIn("Upload Tip smoke diagnostics", workflow)
        self.assertIn("build_identity_transition_pkg.sh validate", workflow)
        self.assertIn("path: tip-source/dist/", workflow)
        self.assertIn("path: signed-tip", workflow)
        stage_tip = tip_script.split("stage_tip() {", 1)[1].split("\n}", 1)[0]
        self.assertEqual(stage_tip.count("stage_release_sentry_symbols"), 1)
        self.assertIn("path: tip-assets", workflow)

        stage = workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]
        for protected_name in ("SENTRY_DSN", "SENTRY_AUTH_TOKEN", "TIP_UPDATE_REPOSITORY_TOKEN"):
            self.assertNotIn(protected_name, stage)
        sign = workflow.split("\n  sign:", 1)[1].split("\n  smoke-no-secrets:", 1)[0]
        self.assertIn("Prepare successor identity migration anchor", sign)
        self.assertIn("SUCCESSOR_DEVELOPER_ID_INSTALLER_P12_BASE64", sign)
        self.assertIn("SUCCESSOR_NOTARYTOOL_PRIVATE_KEY_BASE64", sign)
        self.assertIn("SENTRY_DSN: ${{ secrets.SENTRY_DSN }}", sign)

        self.assertIn('PUBLISH_TIP_RELEASE="$CONTROL_PLANE_SCRIPTS_DIR/publish_tip_release.sh"', tip_script)
        self.assertIn('exec "$PUBLISH_TIP_RELEASE"', tip_script)
        self.assertIn("validate_tip_publish_assets", tip_script)
        self.assertIn("SHA256SUMS entry set mismatch", tip_script)
        self.assertIn('python3 "$ROLLOUT_TOOL" generate', tip_script)
        self.assertIn('python3 "$ROLLOUT_TOOL" validate', tip_script)

        for marker in (
            "require_live_main \"publication setup\"",
            "require_live_main \"final pre-publication\"",
            "create_draft_if_missing",
            "audit_authenticated_release_assets",
            "upload_missing_assets",
            "audit_public_release",
        ):
            self.assertIn(marker, publisher)
        self.assertNotIn("--clobber", publisher)
        self.assertNotIn("gh release delete", publisher)

    def test_tip_publish_asset_inventory_is_exact(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        short_sha = "0123456789ab"
        build_number = "35.15.16"
        archive_basename = f"RepoPrompt-tip-{short_sha}-{build_number}"
        expected = {
            f"{archive_basename}.pkg",
            "appcast.xml",
            "SHA256SUMS",
            f"{archive_basename}-artifact-manifest.json",
            f"{archive_basename}-metadata.json",
            "identity-rollout.json",
        }
        for name in expected:
            if name != "SHA256SUMS":
                (temp_dir / name).write_text(f"{name}\n", encoding="utf-8")

        def write_checksums() -> None:
            names = sorted(name for name in expected if name != "SHA256SUMS")
            (temp_dir / "SHA256SUMS").write_text(
                "".join(
                    f"{hashlib.sha256((temp_dir / name).read_bytes()).hexdigest()}  {name}\n"
                    for name in names
                ),
                encoding="utf-8",
            )

        write_checksums()

        env = os.environ.copy()
        env.update(
            {
                "TIP_COMMIT": "0123456789abcdef0123456789abcdef01234567",
                "TIP_SHORT_SHA": short_sha,
                "TIP_BUILD_NUMBER": build_number,
                "TIP_PUBLISH_INSTALLATION_TYPE": "package",
                "DIST_DIR": str(temp_dir),
            }
        )

        accepted = subprocess.run(
            [str(SCRIPT_DIR / "main_tip_release.sh"), "validate-assets"],
            cwd=SCRIPT_DIR.parent,
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertIn("contains exactly 6 files", accepted.stdout)

        (temp_dir / "appcast.xml").unlink()
        missing = subprocess.run(
            [str(SCRIPT_DIR / "main_tip_release.sh"), "validate-assets"],
            cwd=SCRIPT_DIR.parent,
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("missing=['appcast.xml']", missing.stderr)

        (temp_dir / "appcast.xml").write_text("appcast\n", encoding="utf-8")
        write_checksums()
        (temp_dir / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
        extra = subprocess.run(
            [str(SCRIPT_DIR / "main_tip_release.sh"), "validate-assets"],
            cwd=SCRIPT_DIR.parent,
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(extra.returncode, 0)
        self.assertIn("extra=['unexpected.txt']", extra.stderr)

        for path in temp_dir.iterdir():
            path.unlink()
        package_expected = {
            f"{archive_basename}.pkg",
            "appcast.xml",
            "SHA256SUMS",
            f"{archive_basename}-artifact-manifest.json",
            f"{archive_basename}-metadata.json",
            "identity-rollout.json",
        }
        for name in package_expected:
            if name != "SHA256SUMS":
                (temp_dir / name).write_text(f"{name}\n", encoding="utf-8")
        write_checksums()
        package_env = env.copy()
        package_env["TIP_PUBLISH_INSTALLATION_TYPE"] = "package"
        package = subprocess.run(
            [str(SCRIPT_DIR / "main_tip_release.sh"), "validate-assets"],
            cwd=SCRIPT_DIR.parent,
            env=package_env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(package.returncode, 0, package.stderr)
        self.assertIn("contains exactly 6 files", package.stdout)

        package_env["TIP_PUBLISH_INSTALLATION_TYPE"] = "invalid"
        invalid_type = subprocess.run(
            [str(SCRIPT_DIR / "main_tip_release.sh"), "validate-assets"],
            cwd=SCRIPT_DIR.parent,
            env=package_env,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(invalid_type.returncode, 0)
        self.assertIn(
            "TIP_PUBLISH_INSTALLATION_TYPE must be application or package",
            invalid_type.stderr,
        )

    def test_main_tip_setup_uses_exact_event_sha_and_defers_remote_mutation(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        setup = workflow.split("\n  setup:", 1)[1].split("\n  credential-preflight:", 1)[0]
        before_publish, publish = workflow.split("\n  publish:", 1)

        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("DISPATCH_COMMIT: ${{ github.sha }}", setup)
        self.assertIn("WORKFLOW_RUN_COMMIT: ${{ github.event.workflow_run.head_sha }}", setup)
        self.assertIn('requested_commit="$WORKFLOW_RUN_COMMIT"', setup)
        self.assertIn("git fetch --no-tags origin main", setup)
        self.assertIn('[[ "$commit" == "$live_main" ]]', setup)
        self.assertNotIn("TIP_GH_TOKEN", setup)
        self.assertNotIn("TIP_UPDATE_REPOSITORY_TOKEN", before_publish)
        self.assertNotIn("lookup_public_tip_release", workflow)
        self.assertIn("TIP_GH_TOKEN: ${{ secrets.TIP_UPDATE_REPOSITORY_TOKEN }}", publish)

    def test_tip_workflow_automatically_publishes_without_dormant_release_route(self) -> None:
        workflow = (SCRIPT_DIR.parent / ".github" / "workflows" / "main-tip.yml").read_text(encoding="utf-8")
        trigger = workflow.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]
        credential_preflight = workflow.split("\n  credential-preflight:", 1)[1].split("\n  stage:", 1)[0]
        stage = workflow.split("\n  stage:", 1)[1].split("\n  sign:", 1)[0]

        self.assertIn("  workflow_dispatch:", trigger)
        self.assertIn("  workflow_run:", trigger)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)
        self.assertNotIn("automatic-tip-dormant:", workflow)
        self.assertNotIn("should-publish", workflow)
        self.assertNotIn("skip-reason", workflow)
        self.assertNotIn("if:", credential_preflight)
        self.assertNotIn("if:", stage)

    def test_tip_publication_helper_is_resume_safe_and_byte_exact(self) -> None:
        helper = SCRIPT_DIR / "publish_tip_release.sh"
        source = helper.read_text(encoding="utf-8")

        self.assertTrue(helper.is_file())
        syntax = subprocess.run(["bash", "-n", str(helper)], text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        for marker in (
            "lookup_release()",
            "create_draft_if_missing()",
            "audit_authenticated_release_assets()",
            "upload_missing_assets()",
            "publish_draft()",
            "audit_public_release()",
            "verify_downloaded_asset()",
            "validate_candidate_bindings()",
            "candidate Tip enclosure digest does not match its manifest binding",
            "audit_live_rollout_progression()",
            "audit_stable_tip_floor()",
            "audit_retained_enclosures()",
            "validate-live-tip-progression",
            "validate-stable-tip-floor",
            'require_live_main "publication setup"',
            'require_live_main "final pre-publication"',
            'audit_live_rollout_progression "final pre-publication"',
            "Unable to create or reconcile Tip release draft",
            "Unable to reconcile Tip asset upload",
        ):
            self.assertIn(marker, source)
        self.assertNotIn("--clobber", source)
        self.assertNotIn(
            '${TIP_GH_TOKEN:-${GH_TOKEN:-}}',
            (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8"),
        )
        self.assertNotIn("gh release delete", source)
        self.assertIn("Remote Tip asset SHA-256 mismatch", source)
        self.assertIn("Public Tip release asset inventory mismatch", source)
        self.assertIn('[[ "$TIP_SOURCE_BRANCH" == "main" ]]', source)
        self.assertIn('"target_commitish": branch', source)
        self.assertIn('digest != f"sha256:{expected_sha}"', source)

        missing = subprocess.run(
            [str(helper), "/nonexistent"],
            env={"PATH": os.environ["PATH"]},
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Missing required environment variable", missing.stderr)

    def test_tip_appcast_generation_uses_shared_rollout_authority_and_crypto_verifier(self) -> None:
        tip_script = (SCRIPT_DIR / "main_tip_release.sh").read_text(encoding="utf-8")
        rollout = (SCRIPT_DIR / "stable_rollout.py").read_text(encoding="utf-8")
        generator = tip_script.split("generate_tip_rollout_appcast() {", 1)[1].split("\n}", 1)[0]

        self.assertIn('python3 "$ROLLOUT_TOOL" predecessor-values', generator)
        self.assertIn('python3 "$ROLLOUT_TOOL" generate', generator)
        self.assertIn('python3 "$ROLLOUT_TOOL" validate', generator)
        self.assertIn('"$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE"', generator)
        self.assertIn("verify_sparkle_signature.swift", generator)
        self.assertIn('"minimumUpdateVersion"', rollout)
        self.assertIn("<sparkle:minimumUpdateVersion>", rollout)
        self.assertIn("<sparkle:minimumAutoupdateVersion>", rollout)
        self.assertIn("must not carry an independent", rollout)
        self.assertIn("normalize_published_preparer_floor", rollout)

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
load_release_metadata() {
    APP_NAME=RepoPrompt
    DISPLAY_NAME="RepoPrompt CE"
    MARKETING_VERSION=1.3.0
    BUILD_NUMBER=35
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
if command == "packaging-context":
    print("ROLLOUT_CHANNEL=tip")
    print("ROLLOUT_ROLE=preparer")
    print("ROLLOUT_IDENTITY=legacy")
    print("ROLLOUT_INSTALLATION_TYPE=application")
    print("ROLLOUT_UPDATE_REPOSITORY=repoprompt/repoprompt-ce-tip-updates")
    print("REPOPROMPT_IDENTITY_MIGRATION_PHASE=legacy-preparer")
elif command == "predecessor-values":
    pass
elif command == "generate":
    arguments = sys.argv[2:]
    Path(os.environ["FAKE_ROLLOUT_CAPTURE"]).write_text(json.dumps(arguments), encoding="utf-8")
    for flag, content in (("--appcast-output", "<rss/>\\n"), ("--manifest-output", "{}\\n")):
        output = Path(arguments[arguments.index(flag) + 1])
        output.write_text(content, encoding="utf-8")
elif command == "validate":
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
                "SPARKLE_PRIVATE_KEY": "fixture-private-key",
                "TIP_BUILD_NUMBER": "35.15.17",
                "TIP_COMMIT": "0123456789abcdef0123456789abcdef01234567",
                "TIP_SHORT_SHA": "0123456789ab",
            }
        )
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; TMP_DIR="$(mktemp -d)"; '
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
        self.assertEqual(rollout_arguments.count("--declaration"), 1)
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

    def test_release_metadata_loader_projects_reviewed_tip_identity_in_child_process(self) -> None:
        root = self.make_metadata_root()
        shutil.copy2(SCRIPT_DIR.parent / "tip-rollout.json", root / "tip-rollout.json")

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata_with_identity_projection "{root}" "{root}" "{SCRIPT_DIR}" tip-rollout-v1; '
                'printf "%s|%s|%s|%s\\n" "$BUNDLE_ID" "$SIGNING_TEAM_ID" "$ROLLOUT_ROLE" "$ROLLOUT_IDENTITY"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "com.repoprompt.ce|69N6K965SF|transition|successor\n")

    def test_release_metadata_loader_preserves_stable_identity_without_tip_contract(self) -> None:
        root = self.make_metadata_root()

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{SCRIPT_DIR / "load_release_metadata.sh"}"; '
                f'load_release_metadata_with_identity_projection "{root}" "" "{SCRIPT_DIR}" ""; '
                'printf "%s|%s\\n" "$BUNDLE_ID" "$SIGNING_TEAM_ID"',
            ],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "com.pvncher.repoprompt.ce|648A27MST5\n")

    def test_staged_signer_uses_reviewed_identity_projection_before_profile_validation(self) -> None:
        source = (SCRIPT_DIR / "sign_staged_release.sh").read_text(encoding="utf-8")

        projection = source.index("load_release_metadata_with_identity_projection")
        profile_validation = source.index("profile_app_identifier=")
        self.assertLess(projection, profile_validation)
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

    def make_staged_release_fixture(self) -> tuple[Path, Path, Path]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        approved = temp_dir / "approved"
        staged = temp_dir / "staged"
        scripts = temp_dir / "Scripts"
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
            timeout=30,
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
        successor = policy["identities"]["successor"]
        self.assertEqual(context["ROLLOUT_ROLE"], "transition")
        self.assertEqual(context["ROLLOUT_IDENTITY"], "successor")
        self.assertEqual(context["ROLLOUT_INSTALLATION_TYPE"], "package")
        self.assertEqual(context["BUNDLE_ID"], successor["bundleIdentifier"])
        self.assertEqual(context["EXPECTED_SIGN_IDENTITY"], successor["developerIDApplicationIdentityName"])
        self.assertEqual(context["EXPECTED_INSTALLER_IDENTITY"], successor["developerIDInstallerIdentityName"])
        self.assertEqual(context["REPOPROMPT_STABLE_RELEASE_CONTEXT"], "")

        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        stable_transition = self.make_declaration(
            temp_dir,
            "transition",
            [{"role": "preparer", "tag": "v0.1.0", "rolloutManifestSha256": "0" * 64}],
        )
        mismatch = self.rollout(
            "packaging-context",
            "--declaration", str(stable_transition),
            "--policy", str(self.POLICY),
            "--version-env", str(root / "version.env"),
        )
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("version.env identity does not match the successor Stable rollout identity", mismatch.stderr)

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
        release_commit = hashlib.sha1(f"commit-{build}".encode()).hexdigest()
        arguments = [
            "generate",
            "--declaration", str(declaration),
            "--policy", str(self.POLICY),
            "--version-env", str(version_env),
            "--release-tag", release_tag,
            "--release-commit", release_commit,
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

    def make_tip_release(
        self,
        directory: Path,
        role: str,
        build: str,
        retained: tuple[dict, ...] = (),
        release_tag: str | None = None,
    ) -> dict:
        predecessor_entries = []
        predecessor_manifests = []
        for release in retained:
            manifest = json.loads(release["manifest"].read_text(encoding="utf-8"))
            predecessor_entries.append(
                {
                    "role": manifest["currentRole"],
                    "tag": manifest["sourceTag"],
                    "rolloutManifestSha256": hashlib.sha256(
                        release["manifest"].read_bytes()
                    ).hexdigest(),
                }
            )
            predecessor_manifests.append(release["manifest"])
        tag = release_tag or f"tip-{role}-{build.replace('.', '-')}"
        release = self.make_release(
            directory,
            role,
            "1.2.0",
            build,
            predecessors=predecessor_entries,
            predecessor_manifests=predecessor_manifests,
            channel="tip",
            release_tag=tag,
            enclosure_basename=f"RepoPrompt-{tag}-{build}",
        )
        self.assertEqual(release["result"].returncode, 0, release["result"].stderr)
        return release

    def make_tip_pts_ladder(self) -> tuple[Path, dict, dict, dict]:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        preparer = self.make_tip_release(
            temp_dir, "preparer", "100.1.1", release_tag="tip-preparer"
        )
        transition = self.make_tip_release(
            temp_dir, "transition", "100.1.2", (preparer,), release_tag="tip-transition"
        )
        successor = self.make_tip_release(
            temp_dir,
            "successor",
            "100.1.3",
            (transition, preparer),
            release_tag="tip-successor",
        )
        return temp_dir, preparer, transition, successor

    def validate_tip_progression(
        self, candidate: dict, live: dict | None = None
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            "validate-live-tip-progression",
            "--policy", str(self.POLICY),
            "--candidate-manifest", str(candidate["manifest"]),
            "--candidate-appcast", str(candidate["appcast"]),
        ]
        if live is not None:
            arguments += [
                "--live-manifest", str(live["manifest"]),
                "--live-appcast", str(live["appcast"]),
            ]
        return self.rollout(*arguments)

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
        self.assertIn("stable_rollout.py packaging-context", preflight)
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

        self.assertIn('verify_identity codesigning "$EXPECTED_SIGN_IDENTITY" application', import_step)
        self.assertIn('verify_identity basic "$EXPECTED_INSTALLER_IDENTITY" installer', import_step)
        self.assertIn('printf \'SIGN_IDENTITY=%s\\n\' "$EXPECTED_SIGN_IDENTITY"', import_step)
        self.assertIn('grep -F "\\"$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY\\""', anchor_step)
        self.assertIn('codesign --force --sign "$EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY"', anchor_step)
        self.assertIn('--identifier "$EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID"', anchor_step)
        self.assertIn('-R="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT" "$anchor"', anchor_step)
        self.assertIn('grep -Fx "TeamIdentifier=$EXPECTED_MIGRATION_ANCHOR_TEAM_ID"', anchor_step)
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
        self.assertNotIn("EXPECTED_SUCCESSOR_SIGN_IDENTITY", workflow)

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
                self.assertEqual(context["EXPECTED_APP_BUNDLE_ID"], identity["bundleIdentifier"])
                self.assertEqual(context["EXPECTED_APP_TEAM_ID"], identity["teamIdentifier"])
                self.assertEqual(context["EXPECTED_APP_REQUIREMENT"], identity["developerIDRequirement"])
                expected_installer = (
                    identity.get("developerIDInstallerIdentityName", "") if role == "transition" else ""
                )
                self.assertEqual(context["EXPECTED_INSTALLER_IDENTITY"], expected_installer)
                expected_anchor = policy["identities"]["successor"] if role == "preparer" else None
                self.assertEqual(
                    context["EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY"],
                    expected_anchor["developerIDApplicationIdentityName"] if expected_anchor else "",
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
        self.assertIn(
            'IDENTITY_MIGRATION_TARGET_REQUIREMENT="$EXPECTED_MIGRATION_ANCHOR_REQUIREMENT"',
            sign_staged,
        )
        self.assertNotIn(successor["developerIDRequirement"], sign_staged)
        self.assertNotIn(successor["developerIDRequirement"], pkg_builder)
        self.assertIn('apple_identity_policy.json', pkg_builder)
        self.assertIn('signing_mode_marker="$EXPECTED_SIGNING_MODE"', sign_staged)
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
        self.assertTrue(all("minimumUpdateVersion" in item for item in manifest["appcastItems"]))
        self.assertTrue(all("minimumAutoupdateVersion" not in item for item in manifest["appcastItems"]))
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

    def test_tip_pts_ladder_reuses_one_feed_and_accumulates_top_level_items(self) -> None:
        temp_dir, preparer, transition, successor = self.make_tip_pts_ladder()

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
            r"<sparkle:minimumUpdateVersion>([0-9.]+)</sparkle:minimumUpdateVersion>", appcast
        )
        compatibility_ladders = re.findall(
            r"<sparkle:minimumAutoupdateVersion>([0-9.]+)</sparkle:minimumAutoupdateVersion>", appcast
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
        self.assertTrue(all("minimumUpdateVersion" in item for item in manifest["appcastItems"]))
        self.assertTrue(all("minimumAutoupdateVersion" not in item for item in manifest["appcastItems"]))

        stable_appcast = temp_dir / "stable-appcast.xml"
        stable_appcast.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>'
            '<sparkle:version>100</sparkle:version>'
            '</item></channel></rss>\n',
            encoding="utf-8",
        )
        stable_floor = self.rollout(
            "validate-stable-tip-floor",
            "--policy", str(self.POLICY),
            "--stable-appcast", str(stable_appcast),
            "--tip-manifest", str(successor["manifest"]),
            "--tip-appcast", str(successor["appcast"]),
        )
        self.assertEqual(stable_floor.returncode, 0, stable_floor.stderr)
        stable_appcast.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>'
            '<sparkle:version>101</sparkle:version>'
            '</item></channel></rss>\n',
            encoding="utf-8",
        )
        crossed_floor = self.rollout(
            "validate-stable-tip-floor",
            "--policy", str(self.POLICY),
            "--stable-appcast", str(stable_appcast),
            "--tip-manifest", str(successor["manifest"]),
            "--tip-appcast", str(successor["appcast"]),
        )
        self.assertNotEqual(crossed_floor.returncode, 0)
        self.assertIn("Stable=101 preparer=100.1.1", crossed_floor.stderr)

        first = self.validate_tip_progression(preparer)
        self.assertEqual(first.returncode, 0, first.stderr)
        p_to_t = self.validate_tip_progression(transition, preparer)
        self.assertEqual(p_to_t.returncode, 0, p_to_t.stderr)
        t_to_s = self.validate_tip_progression(successor, transition)
        self.assertEqual(t_to_s.returncode, 0, t_to_s.stderr)
        idempotent = self.validate_tip_progression(successor, successor)
        self.assertEqual(idempotent.returncode, 0, idempotent.stderr)
        skipped = self.validate_tip_progression(successor, preparer)
        self.assertNotEqual(skipped.returncode, 0)
        self.assertIn("regress or skip", skipped.stderr)

        successor_manifest_text = successor["manifest"].read_text(encoding="utf-8")
        changed = json.loads(successor_manifest_text)
        changed["appcastItems"][1]["rolloutManifestSha256"] = "f" * 64
        successor["manifest"].write_text(
            json.dumps(changed, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        changed_history = self.validate_tip_progression(successor, transition)
        self.assertNotEqual(changed_history.returncode, 0)
        self.assertIn("retained items do not exactly match", changed_history.stderr)
        successor["manifest"].write_text(successor_manifest_text, encoding="utf-8")

    def test_live_tip_progression_allows_rolling_roles_and_phase_advances(self) -> None:
        temp_dir, preparer, transition, successor = self.make_tip_pts_ladder()
        legacy = self.make_tip_release(temp_dir, "legacy", "99.1.1")
        next_legacy = self.make_tip_release(temp_dir, "legacy", "99.1.2")
        next_preparer = self.make_tip_release(temp_dir, "preparer", "100.1.4")
        next_transition = self.make_tip_release(
            temp_dir, "transition", "100.1.4", (preparer,)
        )
        next_successor = self.make_tip_release(
            temp_dir, "successor", "100.1.4", (transition, preparer)
        )

        for label, live, candidate in (
            ("legacy to legacy", legacy, next_legacy),
            ("preparer to preparer", preparer, next_preparer),
            ("preparer to transition", preparer, transition),
            ("transition to transition", transition, next_transition),
            ("transition to successor", transition, successor),
            ("successor to successor", successor, next_successor),
        ):
            with self.subTest(label):
                result = self.validate_tip_progression(candidate, live)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("with exact retained history", result.stdout)

    def test_live_tip_progression_rejects_changed_history_regression_and_phase_skip(self) -> None:
        temp_dir, preparer, transition, successor = self.make_tip_pts_ladder()
        next_preparer = self.make_tip_release(temp_dir, "preparer", "100.1.4")

        altered_root = temp_dir / "altered-history"
        altered_preparer = self.make_tip_release(
            altered_root,
            "preparer",
            "100.1.1",
            release_tag="tip-preparer",
        )
        altered_preparer["enclosure"].write_text(
            "altered authenticated preparer enclosure\n", encoding="utf-8"
        )
        regenerated = self.rollout(*altered_preparer["arguments"])
        self.assertEqual(regenerated.returncode, 0, regenerated.stderr)
        changed_transition = self.make_tip_release(
            altered_root,
            "transition",
            "100.1.5",
            (altered_preparer,),
        )

        live_preparer_item = json.loads(transition["manifest"].read_text(encoding="utf-8"))[
            "appcastItems"
        ][1]
        changed_preparer_item = json.loads(
            changed_transition["manifest"].read_text(encoding="utf-8")
        )["appcastItems"][1]
        self.assertEqual(changed_preparer_item["role"], live_preparer_item["role"])
        self.assertEqual(changed_preparer_item["tag"], live_preparer_item["tag"])
        self.assertEqual(changed_preparer_item["buildNumber"], live_preparer_item["buildNumber"])
        self.assertNotEqual(
            changed_preparer_item["enclosureSha256"], live_preparer_item["enclosureSha256"]
        )

        changed_history = self.validate_tip_progression(changed_transition, transition)
        self.assertNotEqual(changed_history.returncode, 0)
        self.assertIn("retained items do not exactly match", changed_history.stderr)

        regression = self.validate_tip_progression(next_preparer, transition)
        self.assertNotEqual(regression.returncode, 0)
        self.assertIn("regress or skip", regression.stderr)

        skipped = self.validate_tip_progression(successor, preparer)
        self.assertNotEqual(skipped.returncode, 0)
        self.assertIn("regress or skip", skipped.stderr)

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

        with self.subTest("appcast text drift from the manifest is rejected"):
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

    def test_stable_surfaces_stay_locked_while_tip_automatically_publishes_checked_in_role(self) -> None:
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
        self.assertIn("tip-rollout.json", tip_workflow)
        self.assertIn("stable_rollout.py packaging-context", tip_workflow)
        self.assertNotIn("confirm_identity_rollout_role", tip_workflow)
        self.assertNotIn("CONFIRMED_ROLLOUT_ROLE", tip_workflow)
        self.assertIn("workflow_run", tip_workflow)
        self.assertNotIn("release-rollout.json", tip_workflow)

        release_script = (SCRIPT_DIR / "release.sh").read_text(encoding="utf-8")
        promote_script = (SCRIPT_DIR / "promote_release.sh").read_text(encoding="utf-8")
        self.assertIn("require_dormant_rollout_declaration", release_script)
        self.assertIn("resolve_release_artifact_role", promote_script)
        for script_text in (release_script, promote_script):
            self.assertNotIn("REPOPROMPT_IDENTITY_TRANSITION_TOOLING_UNLOCK", script_text)
            self.assertNotIn("REPOPROMPT_RELEASE_ARTIFACT_ROLE", script_text)
            self.assertNotIn("REPOPROMPT_PREDECESSOR_APPCAST", script_text)

        # Behavioral: a transition declaration in the tagged source fails
        # promotion before any release lookup or mutation.
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
            timeout=30,
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
        self.assertIn("generate_tip_rollout_appcast", tip_script)
        self.assertIn("identity-rollout.json", tip_script)
        self.assertIn("repoprompt-ce-tip-updates", tip_script)
        self.assertNotIn("tip-transition-appcast.xml", tip_script)
        self.assertNotIn("tip-successor-appcast.xml", tip_script)

    def test_transition_pkg_builder_requires_explicit_tip_enablement(self) -> None:
        script_path = SCRIPT_DIR / "build_identity_transition_pkg.sh"
        script = script_path.read_text(encoding="utf-8")
        for marker in (
            'POLICY="${REPOPROMPT_APPLE_IDENTITY_POLICY:-$SCRIPT_DIR/apple_identity_policy.json}"',
            '"BundleIsRelocatable": False',
            '"BundleHasStrictIdentifier": False',
            '"BundleIsVersionChecked": True',
            '"BundleOverwriteAction": "upgrade"',
            'productbuild --package "$component_pkg" "$unsigned_product"',
            'productsign --sign "$installer_identity"',
            'xcrun notarytool submit "$signed_product"',
            'xcrun stapler staple "$signed_product"',
            'xcrun stapler validate "$pkg"',
            'mv "$signed_product" "$output"',
            'diff -qr "$expected_app" "$payload_app"',
            'Transition package must contain exactly one PackageInfo',
        ):
            self.assertIn(marker, script)
        self.assertNotIn("pkgbuild --analyze", script)
        self.assertNotIn('xcrun stapler staple "$output"', script)
        self.assertNotIn("local package_infos=()", script)
        self.assertNotIn("plutil -replace 0.", script)
        self.assertLess(
            script.index('xcrun notarytool submit "$signed_product"'),
            script.index('xcrun stapler staple "$signed_product"'),
        )
        self.assertLess(
            script.index('xcrun stapler staple "$signed_product"'),
            script.index('validate_transition_pkg "$signed_product"'),
        )
        self.assertLess(
            script.index('validate_transition_pkg "$signed_product"'),
            script.index('mv "$signed_product" "$output"'),
        )
        self.assertNotIn("skip-notarization", script)
        self.assertNotIn("allow-unstapled", script)
        for literal in ("com.repoprompt.ce", "69N6K965SF", "Developer ID Installer: Samuel Baron"):
            self.assertNotIn(literal, script)

        syntax = subprocess.run(["bash", "-n", str(script_path)], text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        refused = subprocess.run(
            ["bash", str(script_path), "validate", "/nonexistent.pkg"],
            text=True,
            capture_output=True,
            env=dict(os.environ),
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("explicit Tip rollout enablement", refused.stderr)


if __name__ == "__main__":
    unittest.main()
