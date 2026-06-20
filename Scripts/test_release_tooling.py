#!/usr/bin/env python3
"""Regression tests for trusted release-control helpers."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


class ReleaseToolingTests(unittest.TestCase):
    def test_runtime_signing_policy_matches_release_metadata_and_entitlement_templates(self) -> None:
        root = SCRIPT_DIR.parent
        metadata = {}
        for line in (root / "version.env").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                metadata[key] = value.strip('"')

        policy = (
            root / "Sources" / "RepoPrompt" / "Infrastructure" / "Security" / "RuntimeCodeSigningPolicy.swift"
        ).read_text(encoding="utf-8")
        entitlements = (root / "AppBundle" / "RepoPrompt.entitlements.template").read_text(encoding="utf-8")
        info_plist = plistlib.loads((root / "AppBundle" / "Info.plist.template").read_bytes())

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
        self.assertIn(
            'static let localSelfSignedCertificateName = "RepoPrompt CE Local Self-Signed Code Signing"',
            policy,
        )

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
        self.assertIn('APP_PID=$!', source)
        self.assertIn('launched-process.json', source)
        self.assertIn('verify_packaged_mcp_socket_owner.py', source)
        self.assertIn('preflight "$MCP_SOCKET_DIR"', source)
        self.assertIn('find-owner "$MCP_SOCKET_DIR" "$APP_PID" "$APP_EXECUTABLE"', source)
        self.assertIn('verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE"', source)
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

    @unittest.skipUnless(sys.platform == "darwin", "macOS UNIX peer PID semantics")
    def test_packaged_socket_owner_helper_rejects_live_preflight_and_accepts_exact_owner(self) -> None:
        temp_dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp_dir, True)
        socket_directory = temp_dir / "repoprompt-ce-mcp"
        socket_directory.mkdir(mode=0o700)
        socket_path = socket_directory / "repoprompt-ce-7.sock"
        listener = self.start_unix_listener(socket_path)
        expected_executable = self.socket_owner_process_path(listener.pid)

        preflight = self.run_socket_owner_helper("preflight", socket_directory)
        found = self.run_socket_owner_helper("find-owner", socket_directory, listener.pid, expected_executable)
        verified = self.run_socket_owner_helper("verify-owner", socket_path, listener.pid, expected_executable)

        self.assertNotEqual(preflight.returncode, 0)
        self.assertIn("pre-existing live release socket", preflight.stderr)
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(Path(found.stdout.strip()), socket_path)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "macOS UNIX peer PID semantics")
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
        first = self.start_unix_listener(socket_path)
        first_executable = self.socket_owner_process_path(first.pid)
        socket_path.unlink()
        second = self.start_unix_listener(socket_path)
        second_executable = self.socket_owner_process_path(second.pid)

        replaced = self.run_socket_owner_helper("verify-owner", socket_path, first.pid, first_executable)
        current = self.run_socket_owner_helper("verify-owner", socket_path, second.pid, second_executable)

        self.assertNotEqual(replaced.returncode, 0)
        self.assertIn(f"belongs to pid {second.pid}", replaced.stderr)
        self.assertEqual(current.returncode, 0, current.stderr)

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
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", signed_smoke)
        self.assertIn('HOME="$HOME"', signed_smoke)
        self.assertIn('TMPDIR="$RUNNER_TEMP"', signed_smoke)

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

    def start_unix_listener(self, socket_path: Path) -> subprocess.Popen[str]:
        ready = socket_path.with_suffix(".ready")
        ready.unlink(missing_ok=True)
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import socket, sys\n"
                "listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
                "listener.bind(sys.argv[1])\n"
                "listener.listen(8)\n"
                "open(sys.argv[2], 'w', encoding='utf-8').close()\n"
                "while True:\n"
                "    client, _ = listener.accept()\n"
                "    with client:\n"
                "        while client.recv(4096):\n"
                "            pass\n",
                os.fspath(socket_path),
                os.fspath(ready),
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
        return process

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
            "validate_app_architectures.sh",
            "write_app_artifact_manifest.py",
            "validate_packaged_legal.sh",
            "validate_required_swiftpm_resource_bundles.sh",
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
            "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
            "__LOCAL_SECURE_STORAGE_GENERATION__": "",
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
    def run_staged_validation(approved: Path, staged: Path, scripts: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "RELEASE_COMMIT": "fixture-release-commit",
                "REPOPROMPT_APPROVED_SOURCE_ROOT": str(approved),
                "REPOPROMPT_RELEASE_SOURCE_ROOT": str(staged),
                "LIPO": str(scripts / "fake-lipo"),
                "CODESIGN": str(scripts / "fake-codesign"),
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
