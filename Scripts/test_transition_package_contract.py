#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "transition_package_contract", SCRIPT_DIR / "transition_package_contract.py"
)
assert SPEC is not None and SPEC.loader is not None
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class TransitionPackageContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.context = {
            "rollout": {"role": "transition", "installationType": "package"},
            "release": {"buildNumber": "35.15.99", "marketingVersion": "1.2.3"},
            "applicationSigning": {
                "bundleIdentifier": "com.repoprompt.ce",
                "teamIdentifier": "69N6K965SF",
                "developerIDRequirement": "anchor apple generic",
            },
            "installerSigning": {
                "required": True,
                "teamIdentifier": "69N6K965SF",
                "identityName": "Developer ID Installer: RepoPrompt LLC (69N6K965SF)",
            },
            "sparkle": {
                "selectedFeedURL": "https://example.invalid/tip/appcast.xml",
                "publicEdDSAValue": "test-public-key",
            },
            "package": {
                "identifier": "com.repoprompt.ce.transition",
                "installLocation": "/Applications",
                "appBundleName": "RepoPrompt CE.app",
                "version": "35.15.99",
                "bundleIsRelocatable": False,
                "bundleHasStrictIdentifier": False,
                "bundleIsVersionChecked": True,
                "bundleOverwriteAction": "upgrade",
                "hasScripts": False,
                "applicationBundleCount": 1,
            },
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_app(
        self,
        parent: Path,
        name: str = "RepoPrompt CE.app",
        identifier: str = "com.repoprompt.ce",
    ) -> Path:
        app = parent / name
        (app / "Contents").mkdir(parents=True)
        (app / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleVersion": "35.15.99",
                    "CFBundleShortVersionString": "1.2.3",
                    "SUFeedURL": "https://example.invalid/tip/appcast.xml",
                    "SUPublicEDKey": "test-public-key",
                }
            )
        )
        (app / "Contents" / "payload.bin").write_bytes(b"signed payload\n")
        return app

    def make_expanded(self, app_source: Path) -> Path:
        expanded = self.root / "expanded"
        component = expanded / "transition-component.pkg"
        payload = component / "Payload"
        payload.mkdir(parents=True)
        target = payload / "RepoPrompt CE.app"
        target.mkdir()
        for source in app_source.rglob("*"):
            relative = source.relative_to(app_source)
            destination = target / relative
            if source.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read_bytes())
        (component / "PackageInfo").write_text(
            '<pkg-info identifier="com.repoprompt.ce.transition" '
            'version="35.15.99" install-location="/Applications" relocatable="false">'
            '<bundle path="./RepoPrompt CE.app" id="com.repoprompt.ce" '
            'CFBundleShortVersionString="1.2.3" CFBundleVersion="35.15.99"/>'
            '<bundle-version><bundle id="com.repoprompt.ce"/></bundle-version>'
            '<upgrade-bundle><bundle id="com.repoprompt.ce"/></upgrade-bundle>'
            '<update-bundle/><atomic-update-bundle/><strict-identifier/><relocate/>'
            '</pkg-info>\n',
            encoding="utf-8",
        )
        return expanded

    def test_component_plist_is_exact_deterministic_one_application_schema(self) -> None:
        payload = self.root / "payload"
        payload.mkdir()
        self.make_app(payload)
        output = self.root / "component.plist"

        package = contract.require_transition_context(self.context)
        contract.write_component_plist(payload, output, package, self.context)
        contract.validate_component_plist(payload, output, package, self.context)

        self.assertEqual(
            plistlib.loads(output.read_bytes()),
            [
                {
                    "RootRelativeBundlePath": "RepoPrompt CE.app",
                    "BundleIsRelocatable": False,
                    "BundleHasStrictIdentifier": False,
                    "BundleIsVersionChecked": True,
                    "BundleOverwriteAction": "upgrade",
                }
            ],
        )
        self.assertEqual(output.read_bytes(), contract.canonical_component_plist_bytes(package))

    def test_payload_rejects_wrong_application_count_name_and_identifier(self) -> None:
        package = contract.require_transition_context(self.context)

        empty = self.root / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(contract.TransitionPackageContractError, "application count mismatch"):
            contract.payload_application(empty, package, self.context)

        wrong_name = self.root / "wrong-name"
        wrong_name.mkdir()
        self.make_app(wrong_name, name="Wrong.app")
        with self.assertRaisesRegex(contract.TransitionPackageContractError, "application name mismatch"):
            contract.payload_application(wrong_name, package, self.context)

        wrong_identifier = self.root / "wrong-identifier"
        wrong_identifier.mkdir()
        self.make_app(wrong_identifier, identifier="com.example.wrong")
        with self.assertRaisesRegex(contract.TransitionPackageContractError, "bundle identifier mismatch"):
            contract.payload_application(wrong_identifier, package, self.context)

        extra = self.root / "extra"
        extra.mkdir()
        self.make_app(extra)
        self.make_app(extra, name="Second.app")
        with self.assertRaisesRegex(contract.TransitionPackageContractError, "application count mismatch"):
            contract.payload_application(extra, package, self.context)

    def test_transition_contract_rejects_changed_required_flag(self) -> None:
        tampered = dict(self.context)
        tampered["package"] = dict(self.context["package"])
        tampered["package"]["bundleIsVersionChecked"] = False
        with self.assertRaisesRegex(contract.TransitionPackageContractError, "bundleIsVersionChecked mismatch"):
            contract.require_transition_context(tampered)

    def test_real_pkgbuild_package_info_fixture_matches_transition_semantics(self) -> None:
        fixture_context = json.loads(json.dumps(self.context))
        fixture_context["release"]["buildNumber"] = "35.15.21"
        fixture_context["release"]["marketingVersion"] = "1.3.0"
        fixture_context["package"]["version"] = "35.15.21"
        package = contract.require_transition_context(fixture_context)
        fixture = SCRIPT_DIR / "Fixtures" / "transition-package-PackageInfo.xml"
        package_info = contract.ET.parse(fixture).getroot()

        contract.validate_package_info(package_info, package, fixture_context)

        relocated = contract.ET.fromstring(fixture.read_text(encoding="utf-8"))
        contract.ET.SubElement(
            relocated.find("./relocate"), "bundle", id="com.repoprompt.ce"
        )
        with self.assertRaisesRegex(
            contract.TransitionPackageContractError,
            "relocate must be empty and not reference bundles",
        ):
            contract.validate_package_info(relocated, package, fixture_context)

        changed_version = contract.ET.fromstring(fixture.read_text(encoding="utf-8"))
        changed_version.find("./bundle").set("CFBundleVersion", "35.15.20")
        with self.assertRaisesRegex(
            contract.TransitionPackageContractError,
            "component bundle CFBundleVersion mismatch",
        ):
            contract.validate_package_info(changed_version, package, fixture_context)

    def test_expanded_payload_validation_detects_changed_and_missing_files(self) -> None:
        expected = self.make_app(self.root / "expected")
        expanded = self.make_expanded(expected)
        manifest = self.root / "artifact-manifest.json"
        manifest.write_text("{}\n", encoding="utf-8")
        package = contract.require_transition_context(self.context)

        with mock.patch.object(contract, "validate_app_signature"), mock.patch.object(
            contract, "validate_artifact_manifest"
        ):
            contract.validate_expanded(
                expanded, expected, manifest, None, package, self.context
            )

            packaged = expanded / "transition-component.pkg" / "Payload" / "RepoPrompt CE.app"
            (packaged / "Contents" / "payload.bin").write_bytes(b"changed\n")
            with self.assertRaisesRegex(contract.TransitionPackageContractError, "changed=.*payload.bin"):
                contract.validate_expanded(
                    expanded, expected, manifest, None, package, self.context
                )

            (packaged / "Contents" / "payload.bin").unlink()
            with self.assertRaisesRegex(contract.TransitionPackageContractError, "missing=.*payload.bin"):
                contract.validate_expanded(
                    expanded, expected, manifest, None, package, self.context
                )

    def test_builder_has_no_inference_or_ambient_metadata_and_bounds_each_phase(self) -> None:
        script = (SCRIPT_DIR / "build_identity_transition_pkg.sh").read_text(encoding="utf-8")
        self.assertNotIn("pkgbuild --analyze", script)
        self.assertNotIn("version.env", script)
        self.assertNotIn("--installer-identity", script)
        self.assertIn('exec python3 "$SUPERVISOR"', script)
        self.assertNotIn("ACTIVE_SUPERVISOR_PID", script)
        self.assertNotIn("forward_active_signal", script)
        self.assertIn('productbuild --package "$component_pkg" "$unsigned_product_pkg"', script)
        self.assertIn('productsign --sign "$TRANSITION_INSTALLER_IDENTITY"', script)
        self.assertIn("--output-format json", script)
        self.assertIn("--notarytool-json-evidence", script)
        self.assertNotIn("--emit-output-tail", script)
        for timeout in (
            "COMPONENT_PACKAGE_TIMEOUT_SECONDS=300",
            "PRODUCT_ARCHIVE_TIMEOUT_SECONDS=300",
            "PACKAGE_SIGN_TIMEOUT_SECONDS=300",
            "PACKAGE_NOTARIZATION_TIMEOUT_SECONDS=1860",
            "PACKAGE_EXPANSION_TIMEOUT_SECONDS=300",
            "PAYLOAD_COMPARISON_TIMEOUT_SECONDS=300",
        ):
            self.assertIn(timeout, script)
        for phase in (
            "transition-component-plist-generation",
            "transition-component-package-construction",
            "transition-product-archive-construction",
            "transition-package-signing",
            "transition-package-notarization",
            "transition-package-expansion",
            "transition-package-payload-comparison",
        ):
            self.assertIn(phase, script)

    def test_builder_exec_handles_term_at_launch_and_leaves_no_group_or_capture(self) -> None:
        builder = (SCRIPT_DIR / "build_identity_transition_pkg.sh").read_text(
            encoding="utf-8"
        )
        wrapper_functions = builder.split("path_size_bytes() {", 1)[1].split(
            "\nrequire_app_and_manifest() {", 1
        )[0]
        wrapper_functions = "path_size_bytes() {" + wrapper_functions
        work = self.root / "wrapper-work"
        work.mkdir()
        (work / "app").mkdir()
        (work / "payload").mkdir()
        pid_file = work / "pkgbuild-pids"
        fake_pkgbuild = self.root / "pkgbuild"
        fake_pkgbuild.write_text(
            """#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
descendant = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
])
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(f"{os.getppid()} {os.getpid()} {descendant.pid} {os.getpgrp()}\\n")
    handle.flush()
    os.fsync(handle.fileno())
os.kill(os.getppid(), signal.SIGTERM)
while True:
    time.sleep(1)
""",
            encoding="utf-8",
        )
        fake_pkgbuild.chmod(0o700)
        harness = self.root / "wrapper-harness.sh"
        harness.write_text(
            "\n".join(
                (
                    "#!/usr/bin/env bash",
                    "set -euo pipefail",
                    f"SUPERVISOR={str(SCRIPT_DIR / 'supervise_release_phase.py')!r}",
                    f"WORK_DIR={str(work)!r}",
                    "fail() { printf 'ERROR: %s\\n' \"$*\" >&2; exit 1; }",
                    "require_absent() { [[ ! -e \"$1\" && ! -L \"$1\" ]] || fail \"existing: $1\"; }",
                    wrapper_functions,
                    f"run_supervised wrapper-cancellation 30 \"$WORK_DIR/app\" \"$WORK_DIR/payload\" {str(fake_pkgbuild)!r} {str(pid_file)!r}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        harness.chmod(0o700)
        process = subprocess.Popen(
            ["bash", str(harness)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        pids: tuple[int, int, int, int] | None = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    values = pid_file.read_text(encoding="ascii").split()
                    if len(values) == 4:
                        pids = tuple(int(value) for value in values)
                        break
                except (FileNotFoundError, ValueError):
                    pass
                time.sleep(0.05)
            self.assertIsNotNone(pids, "fake pkgbuild did not publish launch-boundary IDs")
            assert pids is not None
            supervisor_pid, leader_pid, descendant_pid, process_group = pids
            self.assertEqual(supervisor_pid, process.pid, "builder did not exec supervisor")
            self.assertEqual(process_group, leader_pid)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, (stdout, stderr))
            self.assertFalse((work / "supervisor-wrapper-cancellation.capture").exists())
            events = [
                json.loads(line) for line in stderr.splitlines() if line.startswith("{")
            ]
            self.assertEqual(events[-1]["event"], "cancellation")
            self.assertEqual(events[-1]["cancellation_signal"], "SIGTERM")
            self.assertTrue(events[-1]["cleanup_succeeded"])
            self.assertTrue(events[-1]["process_group_gone"])

            group_gone = False
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.killpg(process_group, 0)
                except ProcessLookupError:
                    group_gone = True
                    break
                time.sleep(0.05)
            self.assertTrue(group_gone, f"fake pkgbuild process group {process_group} survived")
            for pid in (supervisor_pid, leader_pid, descendant_pid):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=5)
            if pids is not None:
                try:
                    os.killpg(pids[3], signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
