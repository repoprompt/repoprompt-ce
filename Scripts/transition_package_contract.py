#!/usr/bin/env python3
"""Deterministic, context-bound contract for the one-time transition package."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import shlex
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

# Never write in-tree bytecode: an untracked __pycache__ would fail the
# strict trusted-root clean-checkout verification.
sys.dont_write_bytecode = True

import tip_release_context  # noqa: E402


class TransitionPackageContractError(ValueError):
    pass


EXPECTED_APP_BUNDLE_NAME = "RepoPrompt CE.app"
EXPECTED_INSTALL_LOCATION = "/Applications"
EXPECTED_PACKAGE_FLAGS = {
    "bundleIsRelocatable": False,
    "bundleHasStrictIdentifier": False,
    "bundleIsVersionChecked": True,
    "bundleOverwriteAction": "upgrade",
    "hasScripts": False,
    "applicationBundleCount": 1,
}
def fail(message: str) -> None:
    raise TransitionPackageContractError(message)


def verified_context(boundary: str) -> dict[str, Any]:
    trusted_root = Path(__file__).resolve().parent.parent
    try:
        context, digest, elapsed_ms = tip_release_context.verify_context_from_environment(
            boundary, str(trusted_root)
        )
    except tip_release_context.TipReleaseContextError as error:
        fail(f"Tip context verification failed: {error}")
    print(
        tip_release_context.verification_line(context, digest, boundary, elapsed_ms),
        file=sys.stderr,
    )
    require_transition_context(context)
    return context


def require_transition_context(context: dict[str, Any]) -> dict[str, Any]:
    rollout = context["rollout"]
    package = context["package"]
    application = context["applicationSigning"]
    installer = context["installerSigning"]
    if rollout["role"] != "transition" or rollout["installationType"] != "package":
        fail(
            "transition package phases require role=transition and "
            f"installationType=package, got role={rollout['role']} "
            f"installationType={rollout['installationType']}"
        )
    if not isinstance(package, dict):
        fail("transition package context is missing package metadata")
    if package["appBundleName"] != EXPECTED_APP_BUNDLE_NAME:
        fail(
            "transition package application name mismatch: "
            f"expected {EXPECTED_APP_BUNDLE_NAME}, got {package['appBundleName']}"
        )
    if package["installLocation"] != EXPECTED_INSTALL_LOCATION:
        fail(
            "transition package install location mismatch: "
            f"expected {EXPECTED_INSTALL_LOCATION}, got {package['installLocation']}"
        )
    for key, expected in EXPECTED_PACKAGE_FLAGS.items():
        actual = package.get(key)
        if actual != expected or type(actual) is not type(expected):
            fail(
                f"transition package {key} mismatch: expected {expected!r}, got {actual!r}"
            )
    if installer.get("required") is not True:
        fail("transition package requires a distinct Installer signing identity")
    if installer.get("teamIdentifier") != application["teamIdentifier"]:
        fail("transition package Application and Installer Team IDs must match")
    if not package.get("identifier"):
        fail("transition package identifier must not be empty")
    return package


def component_plist_value(package: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "RootRelativeBundlePath": package["appBundleName"],
            "BundleIsRelocatable": package["bundleIsRelocatable"],
            "BundleHasStrictIdentifier": package["bundleHasStrictIdentifier"],
            "BundleIsVersionChecked": package["bundleIsVersionChecked"],
            "BundleOverwriteAction": package["bundleOverwriteAction"],
        }
    ]


def canonical_component_plist_bytes(package: dict[str, Any]) -> bytes:
    return plistlib.dumps(
        component_plist_value(package), fmt=plistlib.FMT_XML, sort_keys=True
    )


def read_app_info(app: Path, label: str) -> dict[str, Any]:
    if app.is_symlink() or not app.is_dir():
        fail(f"{label} must be a non-symlink application directory: {app}")
    info_path = app / "Contents" / "Info.plist"
    try:
        value = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"unable to read {label} Info.plist at {info_path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} Info.plist must contain a dictionary")
    return value


def validate_app_metadata(
    app: Path, package: dict[str, Any], context: dict[str, Any], label: str
) -> None:
    info = read_app_info(app, label)
    expected_identifier = context["applicationSigning"]["bundleIdentifier"]
    actual_identifier = info.get("CFBundleIdentifier")
    if actual_identifier != expected_identifier:
        fail(
            f"{label} bundle identifier mismatch: expected {expected_identifier}, "
            f"got {actual_identifier or '<missing>'}"
        )
    actual_version = info.get("CFBundleVersion")
    if actual_version != package["version"]:
        fail(
            f"{label} build mismatch: expected {package['version']}, "
            f"got {actual_version or '<missing>'}"
        )
    expected_marketing_version = context["release"]["marketingVersion"]
    actual_marketing_version = info.get("CFBundleShortVersionString")
    if actual_marketing_version != expected_marketing_version:
        fail(
            f"{label} marketing version mismatch: expected {expected_marketing_version}, "
            f"got {actual_marketing_version or '<missing>'}"
        )
    expected_feed = context["sparkle"]["selectedFeedURL"]
    actual_feed = info.get("SUFeedURL")
    if actual_feed != expected_feed:
        fail(
            f"{label} Sparkle feed mismatch: expected {expected_feed}, "
            f"got {actual_feed or '<missing>'}"
        )
    expected_public_key = context["sparkle"]["publicEdDSAValue"]
    if info.get("SUPublicEDKey") != expected_public_key:
        fail(f"{label} Sparkle public key does not match the verified context")


def payload_application(
    payload_root: Path, package: dict[str, Any], context: dict[str, Any]
) -> Path:
    if payload_root.is_symlink() or not payload_root.is_dir():
        fail(f"transition payload root must be a non-symlink directory: {payload_root}")
    entries = sorted(payload_root.iterdir(), key=lambda path: path.name)
    application_entries = [path for path in entries if path.name.endswith(".app")]
    if len(application_entries) != package["applicationBundleCount"]:
        fail(
            "transition payload application count mismatch: "
            f"expected {package['applicationBundleCount']}, got {len(application_entries)}"
        )
    if len(entries) != 1:
        fail(
            "transition payload must contain exactly one top-level application bundle; "
            f"found {[entry.name for entry in entries]}"
        )
    app = entries[0]
    if app.name != package["appBundleName"]:
        fail(
            "transition payload application name mismatch: "
            f"expected {package['appBundleName']}, got {app.name}"
        )
    validate_app_metadata(app, package, context, "transition payload application")
    return app


def write_component_plist(
    payload_root: Path,
    output: Path,
    package: dict[str, Any],
    context: dict[str, Any],
) -> None:
    payload_application(payload_root, package, context)
    if output.exists() or output.is_symlink():
        fail(f"refusing to overwrite existing transition component plist: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp-{os.getpid()}")
    temporary.write_bytes(canonical_component_plist_bytes(package))
    os.replace(temporary, output)


def validate_component_plist(
    payload_root: Path,
    component_plist: Path,
    package: dict[str, Any],
    context: dict[str, Any],
) -> None:
    payload_application(payload_root, package, context)
    expected = canonical_component_plist_bytes(package)
    try:
        actual = component_plist.read_bytes()
    except OSError as error:
        fail(f"unable to read transition component plist {component_plist}: {error}")
    if actual != expected:
        fail(
            "transition component plist is not the exact canonical one-application schema"
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def byte_tree(root: Path, label: str) -> dict[str, tuple[Any, ...]]:
    if root.is_symlink() or not root.is_dir():
        fail(f"{label} must be a non-symlink directory: {root}")
    result: dict[str, tuple[Any, ...]] = {".": ("directory",)}
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[relative] = ("symlink", os.readlink(path))
        elif path.is_dir():
            result[relative] = ("directory",)
        elif path.is_file():
            result[relative] = ("file", path.stat().st_size, sha256(path))
        else:
            fail(f"{label} contains unsupported filesystem entry: {path}")
    return result


def compare_byte_trees(expected_app: Path, packaged_app: Path) -> None:
    expected = byte_tree(expected_app, "signed input application")
    actual = byte_tree(packaged_app, "packaged application")
    if expected == actual:
        return
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(
        path for path in set(expected) & set(actual) if expected[path] != actual[path]
    )
    fail(
        "transition package payload byte-tree mismatch: "
        f"missing={missing or 'none'} extra={extra or 'none'} "
        f"changed={changed or 'none'}"
    )


def require_single_package_info_section(
    package_info: ET.Element, name: str
) -> ET.Element:
    sections = package_info.findall(f"./{name}")
    if len(sections) != 1:
        fail(
            f"expanded PackageInfo must contain exactly one {name} section; "
            f"found {len(sections)}"
        )
    return sections[0]


def validate_package_info(
    package_info: ET.Element, package: dict[str, Any], context: dict[str, Any]
) -> None:
    if package_info.tag != "pkg-info":
        fail(f"expanded PackageInfo root must be pkg-info, got {package_info.tag}")
    expected_attributes = {
        "identifier": package["identifier"],
        "version": package["version"],
        "install-location": package["installLocation"],
        "relocatable": "false",
    }
    for key, expected in expected_attributes.items():
        actual = package_info.attrib.get(key)
        if actual != expected:
            fail(
                f"expanded PackageInfo {key} mismatch: expected {expected}, "
                f"got {actual or '<missing>'}"
            )

    application = context["applicationSigning"]
    release = context["release"]
    expected_bundle = {
        "path": f"./{package['appBundleName']}",
        "id": application["bundleIdentifier"],
        "CFBundleShortVersionString": release["marketingVersion"],
        "CFBundleVersion": release["buildNumber"],
    }
    component_bundles = package_info.findall("./bundle")
    if len(component_bundles) != 1:
        fail(
            "expanded PackageInfo must contain exactly one component bundle; "
            f"found {len(component_bundles)}"
        )
    for key, expected in expected_bundle.items():
        actual = component_bundles[0].attrib.get(key)
        if actual != expected:
            fail(
                f"expanded PackageInfo component bundle {key} mismatch: "
                f"expected {expected}, got {actual or '<missing>'}"
            )

    for section_name in ("bundle-version", "upgrade-bundle"):
        section = require_single_package_info_section(package_info, section_name)
        references = section.findall("./bundle")
        if len(references) != 1 or len(section) != 1:
            fail(
                f"expanded PackageInfo {section_name} must reference exactly one "
                f"bundle; found {len(references)}"
            )
        reference = references[0]
        actual_identifier = reference.attrib.get("id")
        if actual_identifier != application["bundleIdentifier"]:
            fail(
                f"expanded PackageInfo {section_name} bundle id mismatch: expected "
                f"{application['bundleIdentifier']}, got {actual_identifier or '<missing>'}"
            )
        for key in ("path", "CFBundleShortVersionString", "CFBundleVersion"):
            actual = reference.attrib.get(key)
            if actual is not None and actual != expected_bundle[key]:
                fail(
                    f"expanded PackageInfo {section_name} bundle {key} mismatch: "
                    f"expected {expected_bundle[key]}, got {actual}"
                )

    for section_name in (
        "update-bundle",
        "atomic-update-bundle",
        "strict-identifier",
        "relocate",
    ):
        section = require_single_package_info_section(package_info, section_name)
        references = section.findall("./bundle")
        if references or len(section) != 0:
            fail(
                f"expanded PackageInfo {section_name} must be empty and not reference bundles; "
                f"found {len(references)}"
            )
def expanded_payload_application(
    expanded_root: Path, package: dict[str, Any], context: dict[str, Any]
) -> tuple[Path, Path]:
    if expanded_root.is_symlink() or not expanded_root.is_dir():
        fail(f"expanded transition package must be a non-symlink directory: {expanded_root}")
    package_infos = [path for path in expanded_root.rglob("PackageInfo") if path.is_file()]
    if len(package_infos) != 1:
        fail(
            "expanded transition package must contain exactly one PackageInfo; "
            f"found {len(package_infos)}"
        )
    try:
        package_info = ET.parse(package_infos[0]).getroot()
    except (OSError, ET.ParseError) as error:
        fail(f"unable to parse expanded PackageInfo: {error}")
    validate_package_info(package_info, package, context)
    if package_info.findall(".//scripts") or any(
        path.name == "Scripts" for path in package_infos[0].parent.iterdir()
    ):
        fail("expanded transition package must not contain installer scripts")

    payload_roots = [path for path in expanded_root.rglob("Payload") if path.is_dir()]
    candidates: list[tuple[Path, Path]] = []
    for payload_root in payload_roots:
        direct_apps = [path for path in payload_root.iterdir() if path.name.endswith(".app")]
        if direct_apps:
            if len(direct_apps) != package["applicationBundleCount"]:
                fail(
                    "expanded transition payload application count mismatch: "
                    f"expected {package['applicationBundleCount']}, got {len(direct_apps)}"
                )
            if len(list(payload_root.iterdir())) != 1:
                fail("expanded transition payload must contain only the application bundle")
            candidates.append((payload_root, direct_apps[0]))
    if len(candidates) != 1:
        fail(
            "expanded transition package must contain exactly one application payload; "
            f"found {len(candidates)}"
        )
    payload_root, app = candidates[0]
    if app.name != package["appBundleName"]:
        fail(
            "expanded transition payload application name mismatch: "
            f"expected {package['appBundleName']}, got {app.name}"
        )
    validate_app_metadata(app, package, context, "expanded transition payload application")
    return payload_root, app


def load_artifact_manifest_module() -> Any:
    path = Path(__file__).resolve().with_name("write_app_artifact_manifest.py")
    spec = importlib.util.spec_from_file_location("transition_artifact_manifest", path)
    if spec is None or spec.loader is None:
        fail(f"unable to load artifact manifest validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_artifact_manifest(app: Path, manifest_path: Path) -> None:
    module = load_artifact_manifest_module()
    actual = module.collect_manifest(app, ["arm64", "x86_64"])
    try:
        recorded = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"unable to read application artifact manifest {manifest_path}: {error}")
    if module.canonical_bytes(recorded) != module.canonical_bytes(actual):
        fail(f"artifact manifest does not match packaged application: {manifest_path}")


def run_checked(command: list[str], label: str) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    output = "\n".join(part for part in (result.stdout, result.stderr) if part)
    if result.returncode != 0:
        fail(f"{label} failed with exit {result.returncode}: {output.strip()}")
    return output


def validate_app_signature(app: Path, context: dict[str, Any], label: str) -> None:
    application = context["applicationSigning"]
    run_checked(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)],
        f"{label} code-signature validation",
    )
    run_checked(
        [
            "codesign",
            "--verify",
            "--strict",
            "--verbose=2",
            f"-R={application['developerIDRequirement']}",
            str(app),
        ],
        f"{label} designated-requirement validation",
    )
    details = run_checked(
        ["codesign", "-dv", "--verbose=4", str(app)],
        f"{label} signing-details inspection",
    )
    identifier = next(
        (line.partition("=")[2] for line in details.splitlines() if line.startswith("Identifier=")),
        "",
    )
    team = next(
        (line.partition("=")[2] for line in details.splitlines() if line.startswith("TeamIdentifier=")),
        "",
    )
    if "Authority=Developer ID Application:" not in details:
        fail(f"{label} is not signed with a Developer ID Application certificate")
    if identifier != application["bundleIdentifier"]:
        fail(
            f"{label} signed identifier mismatch: expected {application['bundleIdentifier']}, "
            f"got {identifier or '<missing>'}"
        )
    if team != application["teamIdentifier"]:
        fail(
            f"{label} signed Team ID mismatch: expected {application['teamIdentifier']}, "
            f"got {team or '<missing>'}"
        )


def validate_package_signature(package_path: Path, context: dict[str, Any]) -> None:
    output = run_checked(
        ["pkgutil", "--check-signature", str(package_path)],
        "transition package signature validation",
    )
    installer = context["installerSigning"]
    if "Developer ID Installer:" not in output:
        fail("transition package is not signed with a Developer ID Installer certificate")
    if f"({installer['teamIdentifier']})" not in output:
        fail(
            "transition package Installer Team ID mismatch: "
            f"expected {installer['teamIdentifier']}"
        )
    run_checked(
        ["xcrun", "stapler", "validate", str(package_path)],
        "transition package staple validation",
    )


def validate_expanded(
    expanded_root: Path,
    expected_app: Path | None,
    artifact_manifest: Path,
    output_app_path: Path | None,
    package: dict[str, Any],
    context: dict[str, Any],
) -> Path:
    _payload_root, packaged_app = expanded_payload_application(
        expanded_root, package, context
    )
    validate_app_signature(packaged_app, context, "transition package payload")
    validate_artifact_manifest(packaged_app, artifact_manifest)
    if expected_app is not None:
        compare_byte_trees(expected_app, packaged_app)
    if output_app_path is not None:
        output_app_path.parent.mkdir(parents=True, exist_ok=True)
        output_app_path.write_text(f"{packaged_app}\n", encoding="utf-8")
    return packaged_app


def emit_context_shell(context: dict[str, Any]) -> None:
    package = require_transition_context(context)
    application = context["applicationSigning"]
    installer = context["installerSigning"]
    values = {
        "TRANSITION_PACKAGE_IDENTIFIER": package["identifier"],
        "TRANSITION_INSTALL_LOCATION": package["installLocation"],
        "TRANSITION_PACKAGE_VERSION": package["version"],
        "TRANSITION_APP_BUNDLE_NAME": package["appBundleName"],
        "TRANSITION_APP_BUNDLE_ID": application["bundleIdentifier"],
        "TRANSITION_APP_TEAM_ID": application["teamIdentifier"],
        "TRANSITION_APP_REQUIREMENT": application["developerIDRequirement"],
        "TRANSITION_INSTALLER_TEAM_ID": installer["teamIdentifier"],
        "TRANSITION_INSTALLER_IDENTITY": installer["identityName"],
    }
    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    context_shell = commands.add_parser("context-shell")
    context_shell.add_argument("--boundary", required=True)

    write = commands.add_parser("write-component-plist")
    write.add_argument("--boundary", required=True)
    write.add_argument("--payload-root", required=True, type=Path)
    write.add_argument("--output", required=True, type=Path)

    verify = commands.add_parser("verify-component-plist")
    verify.add_argument("--boundary", required=True)
    verify.add_argument("--payload-root", required=True, type=Path)
    verify.add_argument("--component-plist", required=True, type=Path)

    package_signature = commands.add_parser("validate-package-signature")
    package_signature.add_argument("--boundary", required=True)
    package_signature.add_argument("--package", required=True, type=Path)

    expanded = commands.add_parser("validate-expanded")
    expanded.add_argument("--boundary", required=True)
    expanded.add_argument("--expanded-root", required=True, type=Path)
    expanded.add_argument("--expected-app", type=Path)
    expanded.add_argument("--artifact-manifest", required=True, type=Path)
    expanded.add_argument("--output-app-path", type=Path)

    full = commands.add_parser("validate-package")
    full.add_argument("--boundary", required=True)
    full.add_argument("--package", required=True, type=Path)
    full.add_argument("--work-dir", required=True, type=Path)
    full.add_argument("--artifact-manifest", required=True, type=Path)
    full.add_argument("--expanded-payload-dir", type=Path)
    return parser


def run_validate_package(args: argparse.Namespace, context: dict[str, Any]) -> None:
    package = require_transition_context(context)
    validate_package_signature(args.package, context)
    expanded = args.work_dir / "expanded-package"
    if expanded.exists():
        fail(f"transition validation expansion destination already exists: {expanded}")
    run_checked(
        ["pkgutil", "--expand-full", str(args.package), str(expanded)],
        "transition package expansion",
    )
    packaged_app = validate_expanded(
        expanded,
        None,
        args.artifact_manifest,
        None,
        package,
        context,
    )
    if args.expanded_payload_dir is not None:
        args.expanded_payload_dir.mkdir(parents=True, exist_ok=True)
        destination = args.expanded_payload_dir / package["appBundleName"]
        if destination.exists():
            fail(f"transition payload export destination already exists: {destination}")
        run_checked(
            ["ditto", str(packaged_app), str(destination)],
            "transition payload export",
        )


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        context = verified_context(f"{args.boundary}-{args.command}")
        package = require_transition_context(context)
        if args.command == "context-shell":
            emit_context_shell(context)
        elif args.command == "write-component-plist":
            write_component_plist(args.payload_root, args.output, package, context)
            validate_component_plist(args.payload_root, args.output, package, context)
            print(f"OK: wrote canonical transition component plist: {args.output}")
        elif args.command == "verify-component-plist":
            validate_component_plist(
                args.payload_root, args.component_plist, package, context
            )
            print(f"OK: canonical transition component plist verified: {args.component_plist}")
        elif args.command == "validate-package-signature":
            validate_package_signature(args.package, context)
            print(f"OK: transition package signature verified: {args.package}")
        elif args.command == "validate-expanded":
            validate_expanded(
                args.expanded_root,
                args.expected_app,
                args.artifact_manifest,
                args.output_app_path,
                package,
                context,
            )
            print(f"OK: transition package expanded payload verified: {args.expanded_root}")
        elif args.command == "validate-package":
            run_validate_package(args, context)
            print(f"OK: transition package validated: {args.package}")
        else:
            raise AssertionError(args.command)
    except (TransitionPackageContractError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
