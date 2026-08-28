#!/usr/bin/env python3
"""Resolve and verify the immutable, secret-free Tip release context.

Resolution is the sole compilation step. It reads committed policy, rollout,
version, and resolver tooling inputs plus the downloaded Stable appcast, then
writes canonical context bytes and a detached SHA-256. Downstream verification
uses the expected setup digest as its immutable anchor; it does not recompile
the release decision from ambient files.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType
from typing import Any

# Never write in-tree bytecode: an untracked __pycache__ would fail the
# strict trusted-root clean-checkout verification below.
sys.dont_write_bytecode = True


SCHEMA_VERSION = 1
CONTEXT_KIND = "repoprompt-tip-release-context"
ARCHIVE_CONTRACT = "tip-rollout-v1"
CONTEXT_BASENAME = "tip-release-context.json"
CONTEXT_DIGEST_BASENAME = "tip-release-context.json.sha256"
PUBLICATION_TARGET = "main"

SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
BOUNDARY_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")
CF_BUNDLE_VERSION_PATTERN = re.compile(r"[0-9]{1,4}(?:\.[0-9]{1,2}){0,2}")
STABLE_BASE_BUILD_PATTERN = re.compile(r"[1-9][0-9]{0,3}")

ROLLOUT_ROLES = {"legacy", "preparer", "transition", "successor"}
SIGNING_IDENTITIES = {"legacy", "successor"}
MIGRATION_PHASES = {"disabled", "legacy-preparer"}
INSTALLATION_TYPES = {"application", "package"}

INPUT_DIGEST_KEYS = {
    "appleIdentityPolicy",
    "stableRolloutTool",
    "tipReleaseContextTool",
    "tipRolloutDeclaration",
    "versionEnv",
    "stableAppcast",
}
TOP_LEVEL_KEYS = {
    "schemaVersion",
    "kind",
    "archiveContract",
    "provenance",
    "rollout",
    "release",
    "applicationSigning",
    "migrationAnchorSigning",
    "installerSigning",
    "sparkle",
    "package",
    "publication",
}
PROVENANCE_KEYS = {"approvedSourceCommit", "trustedToolingCommit", "inputSha256"}
ROLLOUT_KEYS = {
    "channel",
    "role",
    "signingIdentity",
    "eligibilityProfile",
    "runtimeSecureStorageMigrationPhase",
    "installationType",
    "predecessors",
}
PREDECESSOR_KEYS = {"role", "tag", "rolloutManifestSha256"}
RELEASE_KEYS = {
    "appName",
    "displayName",
    "marketingVersion",
    "stableMaximumBuild",
    "sourceBuildSequence",
    "buildNumber",
    "commit",
    "shortSha",
    "tag",
    "archiveBasename",
}
APPLICATION_SIGNING_KEYS = {
    "bundleIdentifier",
    "teamIdentifier",
    "developerIDRequirement",
    "identityName",
    "expectedProvisioningProfileApplicationIdentifier",
}
MIGRATION_ANCHOR_SIGNING_KEYS = {
    "required",
    "bundleIdentifier",
    "teamIdentifier",
    "developerIDRequirement",
    "identityName",
}
INSTALLER_SIGNING_KEYS = {"required", "teamIdentifier", "identityName"}
SPARKLE_KEYS = {
    "publicEdDSAValue",
    "stableFeedURL",
    "tipFeedURL",
    "selectedFeedURL",
    "updateRepository",
    "minimumSystemVersion",
}
PACKAGE_KEYS = {
    "identifier",
    "installLocation",
    "appBundleName",
    "version",
    "bundleIsRelocatable",
    "bundleHasStrictIdentifier",
    "bundleIsVersionChecked",
    "bundleOverwriteAction",
    "hasScripts",
    "applicationBundleCount",
}
PUBLICATION_KEYS = {"repository", "tag", "target", "draft", "prerelease", "assets"}

PROHIBITED_KEY_FRAGMENTS = (
    "apikey",
    "authorization",
    "credential",
    "githubtoken",
    "notarypassword",
    "p12",
    "password",
    "privatekey",
    "secret",
    "sentrydsn",
    "token",
)
PROHIBITED_VALUE_MARKERS = (
    # Split key-envelope literals so the staged-source scanner does not
    # classify this deny-list itself as an embedded credential.
    "-----BEGIN " + "PRIVATE KEY-----",
    "-----BEGIN " + "ENCRYPTED PRIVATE KEY-----",
    "-----BEGIN " + "OPENSSH PRIVATE KEY-----",
    "github_pat_",
    "ghp_",
)

SHELL_EXPORT_KEYS = (
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
)


class TipReleaseContextError(Exception):
    """Expected resolver or verifier failure."""


def canonical_json_bytes(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_bytes(path: Path, label: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise TipReleaseContextError(f"cannot read {label}: {error}") from error


def sha256_file(path: Path, label: str) -> str:
    return sha256_bytes(read_bytes(path, label))


def read_json_object(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = read_bytes(path, label)
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise TipReleaseContextError(f"{label} must be UTF-8") from error
    try:
        value = json.loads(decoded)
    except json.JSONDecodeError as error:
        raise TipReleaseContextError(f"malformed {label}: {error.msg} at line {error.lineno}") from error
    if not isinstance(value, dict):
        raise TipReleaseContextError(f"{label} must be a JSON object")
    return value, raw


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise TipReleaseContextError(
            f"{label} keys are not closed-schema: missing={missing or 'none'} "
            f"unknown={unknown or 'none'}"
        )


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise TipReleaseContextError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise TipReleaseContextError(f"{label} must be an array")
    return value


def require_string(value: Any, label: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        qualifier = "nonempty " if nonempty else ""
        raise TipReleaseContextError(f"{label} must be a {qualifier}string")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise TipReleaseContextError(f"{label} must not contain control characters")
    return value


def require_bool(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise TipReleaseContextError(f"{label} must be a boolean")
    return value


def require_int(value: Any, label: str) -> int:
    if type(value) is not int:
        raise TipReleaseContextError(f"{label} must be an integer")
    return value


def require_digest(value: Any, label: str) -> str:
    digest = require_string(value, label)
    if not SHA256_PATTERN.fullmatch(digest):
        raise TipReleaseContextError(f"{label} must be a lowercase SHA-256")
    return digest


def require_commit(value: Any, label: str) -> str:
    commit = require_string(value, label)
    if not COMMIT_PATTERN.fullmatch(commit):
        raise TipReleaseContextError(f"{label} must be a full lowercase 40-character Git commit")
    return commit


def require_safe_basename(value: Any, label: str) -> str:
    name = require_string(value, label)
    if name in (".", "..") or Path(name).name != name or "/" in name or "\\" in name:
        raise TipReleaseContextError(f"{label} must be a single safe basename")
    return name


def scan_for_secret_like_data(value: Any, path: str = "context") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                raise TipReleaseContextError(f"{path} contains a non-string key")
            normalized = re.sub(r"[^a-z0-9]", "", key.lower())
            if any(fragment in normalized for fragment in PROHIBITED_KEY_FRAGMENTS):
                raise TipReleaseContextError(f"{path}.{key} is a prohibited secret-like field")
            scan_for_secret_like_data(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan_for_secret_like_data(child, f"{path}[{index}]")
    elif isinstance(value, str):
        if any(marker in value for marker in PROHIBITED_VALUE_MARKERS):
            raise TipReleaseContextError(f"{path} contains prohibited secret-like material")


def load_rollout_tool(path: Path) -> ModuleType:
    try:
        spec = importlib.util.spec_from_file_location("repoprompt_tip_context_stable_rollout", path)
        if spec is None or spec.loader is None:
            raise TipReleaseContextError("cannot load stable rollout tool")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except TipReleaseContextError:
        raise
    except Exception as error:
        raise TipReleaseContextError(f"cannot load stable rollout tool: {error}") from error
    required = (
        "load_policy",
        "validate_identity_transition_package",
        "load_declaration",
        "load_version_env",
        "identity_name_for_bundle_and_team",
        "update_repository",
        "max_build_from_appcast",
        "parse_build",
        "ROLE_IDENTITY",
        "ROLE_MIGRATION_PHASE",
        "ROLE_INSTALLATION_TYPE",
    )
    missing = [name for name in required if not hasattr(module, name)]
    if missing:
        raise TipReleaseContextError(f"stable rollout tool is missing required interface: {', '.join(missing)}")
    return module


def call_rollout(function: Any, *args: Any) -> Any:
    try:
        return function(*args)
    except Exception as error:
        raise TipReleaseContextError(str(error)) from error


def run_git(root: Path, arguments: list[str], label: str, *, binary: bool = False) -> Any:
    if not root.is_dir():
        raise TipReleaseContextError(f"{label} root is not a directory")
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            text=not binary,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TipReleaseContextError(f"cannot inspect {label} Git checkout: {error}") from error
    if result.returncode != 0:
        raise TipReleaseContextError(f"cannot inspect {label} Git checkout")
    return result.stdout


def git_head(root: Path, label: str) -> str:
    return require_commit(run_git(root, ["rev-parse", "HEAD"], label).strip(), f"{label} Git HEAD")


def require_git_head(root: Path, expected_commit: str, label: str) -> None:
    actual = git_head(root, label)
    if actual != expected_commit:
        raise TipReleaseContextError(
            f"{label} Git HEAD mismatch: expected {expected_commit}, got {actual}"
        )


def require_clean_checkout(root: Path, label: str) -> None:
    # Include untracked files: an untracked shadow module (for example
    # Scripts/hashlib.py) could execute on import even at the expected HEAD.
    status = run_git(root, ["status", "--porcelain", "--untracked-files=all"], label)
    if status:
        raise TipReleaseContextError(
            f"{label} Git checkout has staged, working-tree, or untracked changes"
        )


def require_committed_file(root: Path, commit: str, relative_path: str, label: str) -> Path:
    path = root / relative_path
    actual = read_bytes(path, label)
    committed = run_git(root, ["show", f"{commit}:{relative_path}"], label, binary=True)
    if actual != committed:
        raise TipReleaseContextError(
            f"{label} does not match committed blob {commit}:{relative_path}"
        )
    return path


def stable_maximum_build(rollout: ModuleType, appcast: Path) -> str:
    build = call_rollout(rollout.max_build_from_appcast, appcast)
    if not isinstance(build, str) or not STABLE_BASE_BUILD_PATTERN.fullmatch(build):
        raise TipReleaseContextError(
            "Stable maximum build is incompatible with the Tip three-component encoding: "
            f"expected one positive 1-4 digit component, got {build!r}"
        )
    return build


def resolved_tip_build(rollout: ModuleType, stable_build: str, source_sequence: int) -> str:
    if not 1 <= source_sequence <= 9999:
        raise TipReleaseContextError("source build sequence must be between 1 and 9999")
    build = f"{stable_build}.{source_sequence // 100}.{source_sequence % 100}"
    if not CF_BUNDLE_VERSION_PATTERN.fullmatch(build):
        raise TipReleaseContextError(f"resolved Tip build is not a valid CFBundleVersion: {build!r}")
    parsed_build = call_rollout(rollout.parse_build, build, "resolved Tip build")
    parsed_stable = call_rollout(rollout.parse_build, stable_build, "Stable maximum build")
    if not parsed_build > parsed_stable:
        raise TipReleaseContextError(
            f"resolved Tip build must be greater than Stable maximum: {build} <= {stable_build}"
        )
    return build


def expected_publication_assets(archive_basename: str, installation_type: str) -> list[str]:
    shared = [
        "appcast.xml",
        "SHA256SUMS",
        f"{archive_basename}-artifact-manifest.json",
        f"{archive_basename}-metadata.json",
        "identity-rollout.json",
    ]
    if installation_type == "package":
        release_artifacts = [f"{archive_basename}.pkg"]
    elif installation_type == "application":
        release_artifacts = [f"{archive_basename}.zip", f"{archive_basename}.dmg"]
    else:
        raise TipReleaseContextError(f"unknown Tip installation type: {installation_type!r}")
    return shared + release_artifacts + [CONTEXT_BASENAME, CONTEXT_DIGEST_BASENAME]


def load_authority(
    rollout: ModuleType,
    policy_path: Path,
    declaration_path: Path,
    version_env_path: Path,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, str]]:
    policy = call_rollout(rollout.load_policy, policy_path)
    declaration = call_rollout(rollout.load_declaration, declaration_path)
    if declaration["currentRole"] == "transition":
        call_rollout(rollout.validate_identity_transition_package, policy)
    version = call_rollout(rollout.load_version_env, version_env_path)
    if declaration["channel"] != "tip":
        raise TipReleaseContextError("Tip release context requires a Tip rollout declaration")
    require_string(version.get("DISPLAY_NAME"), "version.env DISPLAY_NAME")
    call_rollout(
        rollout.identity_name_for_bundle_and_team,
        policy,
        version["BUNDLE_ID"],
        version["SIGNING_TEAM_ID"],
    )
    return policy, declaration, version


def build_context(
    *,
    rollout: ModuleType,
    policy_path: Path,
    rollout_tool_path: Path,
    context_tool_path: Path,
    declaration_path: Path,
    version_env_path: Path,
    stable_appcast_path: Path,
    approved_source_commit: str,
    trusted_tooling_commit: str,
    source_build_sequence: int,
    expected_tip_update_repository: str,
) -> dict[str, Any]:
    policy, declaration, version = load_authority(
        rollout, policy_path, declaration_path, version_env_path
    )
    selected_repository = call_rollout(rollout.update_repository, policy, "tip")
    if selected_repository != expected_tip_update_repository:
        raise TipReleaseContextError(
            "configured Tip update repository does not match reviewed identity policy: "
            f"expected {selected_repository!r}, got {expected_tip_update_repository!r}"
        )

    stable_build = stable_maximum_build(rollout, stable_appcast_path)
    build_number = resolved_tip_build(rollout, stable_build, source_build_sequence)
    role = declaration["currentRole"]
    identity_name = rollout.ROLE_IDENTITY[role]
    identity = policy["identities"][identity_name]
    migration_phase = rollout.ROLE_MIGRATION_PHASE[role]
    installation_type = rollout.ROLE_INSTALLATION_TYPE[role]
    package_required = installation_type == "package"
    short_sha = approved_source_commit[:12]
    tag = f"tip-{short_sha}"
    app_name = require_safe_basename(version["APP_NAME"], "version.env APP_NAME")
    display_name = require_string(version["DISPLAY_NAME"], "version.env DISPLAY_NAME")
    marketing_version = require_string(version["MARKETING_VERSION"], "version.env MARKETING_VERSION")
    archive_basename = f"{app_name}-tip-{short_sha}-{build_number}"
    require_safe_basename(archive_basename, "release archive basename")

    installer_identity = identity.get("developerIDInstallerIdentityName") if package_required else None
    if package_required and not installer_identity:
        raise TipReleaseContextError(
            f"the {role} Tip role requires a reviewed Developer ID Installer identity"
        )
    package = None
    if package_required:
        package = dict(policy["identityTransitionPackage"])
        package["version"] = build_number
        if f"{display_name}.app" != package["appBundleName"]:
            raise TipReleaseContextError(
                "Tip transition display name does not match the reviewed package application name"
            )

    migration_anchor_required = role == "preparer"
    successor_identity = policy["identities"]["successor"]
    migration_anchor = {
        "required": migration_anchor_required,
        "bundleIdentifier": (
            successor_identity["bundleIdentifier"] if migration_anchor_required else None
        ),
        "teamIdentifier": (
            successor_identity["teamIdentifier"] if migration_anchor_required else None
        ),
        "developerIDRequirement": (
            successor_identity["developerIDRequirement"] if migration_anchor_required else None
        ),
        "identityName": (
            successor_identity["developerIDApplicationIdentityName"]
            if migration_anchor_required
            else None
        ),
    }

    context: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": CONTEXT_KIND,
        "archiveContract": ARCHIVE_CONTRACT,
        "provenance": {
            "approvedSourceCommit": approved_source_commit,
            "trustedToolingCommit": trusted_tooling_commit,
            "inputSha256": {
                "appleIdentityPolicy": sha256_file(policy_path, "Apple identity policy"),
                "stableRolloutTool": sha256_file(rollout_tool_path, "stable rollout tool"),
                "tipReleaseContextTool": sha256_file(context_tool_path, "Tip context tool"),
                "tipRolloutDeclaration": sha256_file(
                    declaration_path, "Tip rollout declaration"
                ),
                "versionEnv": sha256_file(version_env_path, "version.env"),
                "stableAppcast": sha256_file(stable_appcast_path, "Stable appcast"),
            },
        },
        "rollout": {
            "channel": "tip",
            "role": role,
            "signingIdentity": identity_name,
            "eligibilityProfile": declaration["eligibilityProfile"],
            "runtimeSecureStorageMigrationPhase": migration_phase,
            "installationType": installation_type,
            "predecessors": [dict(entry) for entry in declaration["predecessors"]],
        },
        "release": {
            "appName": app_name,
            "displayName": display_name,
            "marketingVersion": marketing_version,
            "stableMaximumBuild": stable_build,
            "sourceBuildSequence": source_build_sequence,
            "buildNumber": build_number,
            "commit": approved_source_commit,
            "shortSha": short_sha,
            "tag": tag,
            "archiveBasename": archive_basename,
        },
        "applicationSigning": {
            "bundleIdentifier": identity["bundleIdentifier"],
            "teamIdentifier": identity["teamIdentifier"],
            "developerIDRequirement": identity["developerIDRequirement"],
            "identityName": identity["developerIDApplicationIdentityName"],
            "expectedProvisioningProfileApplicationIdentifier": (
                f"{identity['teamIdentifier']}.{identity['bundleIdentifier']}"
            ),
        },
        "migrationAnchorSigning": migration_anchor,
        "installerSigning": {
            "required": package_required,
            "teamIdentifier": identity["teamIdentifier"] if package_required else None,
            "identityName": installer_identity,
        },
        "sparkle": {
            "publicEdDSAValue": policy["sparkle"]["sparklePublicEdDSAValue"],
            "stableFeedURL": policy["sparkle"]["stableFeedURL"],
            "tipFeedURL": policy["sparkle"]["tipFeedURL"],
            "selectedFeedURL": policy["sparkle"]["tipFeedURL"],
            "updateRepository": selected_repository,
            "minimumSystemVersion": policy["sparkle"]["minimumSystemVersion"],
        },
        "package": package,
        "publication": {
            "repository": selected_repository,
            "tag": tag,
            "target": PUBLICATION_TARGET,
            "draft": False,
            "prerelease": False,
            "assets": expected_publication_assets(archive_basename, installation_type),
        },
    }
    scan_for_secret_like_data(context)
    validate_closed_schema(context)
    validate_semantic_invariants(context)
    return context


def validate_closed_schema(context: dict[str, Any]) -> None:
    require_exact_keys(context, TOP_LEVEL_KEYS, "context")
    if context["schemaVersion"] != SCHEMA_VERSION:
        raise TipReleaseContextError("Tip release context schema version mismatch")
    if context["kind"] != CONTEXT_KIND:
        raise TipReleaseContextError("Tip release context kind mismatch")
    if context["archiveContract"] != ARCHIVE_CONTRACT:
        raise TipReleaseContextError("Tip release context archive contract mismatch")

    provenance = require_object(context["provenance"], "context.provenance")
    require_exact_keys(provenance, PROVENANCE_KEYS, "context.provenance")
    approved_commit = require_commit(
        provenance["approvedSourceCommit"], "context approved source commit"
    )
    require_commit(provenance["trustedToolingCommit"], "context trusted tooling commit")
    input_digests = require_object(provenance["inputSha256"], "context.provenance.inputSha256")
    require_exact_keys(input_digests, INPUT_DIGEST_KEYS, "context.provenance.inputSha256")
    for key in sorted(INPUT_DIGEST_KEYS):
        require_digest(input_digests[key], f"context input digest {key}")

    rollout = require_object(context["rollout"], "context.rollout")
    require_exact_keys(rollout, ROLLOUT_KEYS, "context.rollout")
    if rollout["channel"] != "tip":
        raise TipReleaseContextError("context rollout channel must be tip")
    if rollout["role"] not in ROLLOUT_ROLES:
        raise TipReleaseContextError(f"unknown context rollout role: {rollout['role']!r}")
    if rollout["signingIdentity"] not in SIGNING_IDENTITIES:
        raise TipReleaseContextError("unknown context rollout signing identity")
    require_string(rollout["eligibilityProfile"], "context rollout eligibility profile")
    if rollout["runtimeSecureStorageMigrationPhase"] not in MIGRATION_PHASES:
        raise TipReleaseContextError("unknown context runtime secure-storage migration phase")
    if rollout["installationType"] not in INSTALLATION_TYPES:
        raise TipReleaseContextError("unknown context installation type")
    predecessors = require_list(rollout["predecessors"], "context rollout predecessors")
    for position, raw_entry in enumerate(predecessors, start=1):
        entry = require_object(raw_entry, f"context predecessor {position}")
        require_exact_keys(entry, PREDECESSOR_KEYS, f"context predecessor {position}")
        if entry["role"] not in ROLLOUT_ROLES:
            raise TipReleaseContextError(f"context predecessor {position} has an unknown role")
        require_string(entry["tag"], f"context predecessor {position} tag")
        require_digest(
            entry["rolloutManifestSha256"],
            f"context predecessor {position} rollout manifest digest",
        )

    release = require_object(context["release"], "context.release")
    require_exact_keys(release, RELEASE_KEYS, "context.release")
    require_safe_basename(release["appName"], "context release app name")
    require_string(release["displayName"], "context release display name")
    require_string(release["marketingVersion"], "context release marketing version")
    stable_build = require_string(release["stableMaximumBuild"], "context Stable maximum build")
    if not STABLE_BASE_BUILD_PATTERN.fullmatch(stable_build):
        raise TipReleaseContextError("context Stable maximum build is incompatible with Tip encoding")
    sequence = require_int(release["sourceBuildSequence"], "context source build sequence")
    if not 1 <= sequence <= 9999:
        raise TipReleaseContextError("context source build sequence must be between 1 and 9999")
    build = require_string(release["buildNumber"], "context release build number")
    if not CF_BUNDLE_VERSION_PATTERN.fullmatch(build):
        raise TipReleaseContextError("context release build number is not a valid CFBundleVersion")
    commit = require_commit(release["commit"], "context release commit")
    if commit != approved_commit:
        raise TipReleaseContextError("context release commit differs from approved source provenance")
    short_sha = require_string(release["shortSha"], "context release short SHA")
    if not re.fullmatch(r"[0-9a-f]{12}", short_sha):
        raise TipReleaseContextError("context release short SHA must be 12 lowercase hex characters")
    tag = require_string(release["tag"], "context release tag")
    if not re.fullmatch(r"tip-[0-9a-f]{12}", tag):
        raise TipReleaseContextError("context release tag must be tip- followed by 12 lowercase hex characters")
    require_safe_basename(release["archiveBasename"], "context release archive basename")

    application = require_object(context["applicationSigning"], "context.applicationSigning")
    require_exact_keys(application, APPLICATION_SIGNING_KEYS, "context.applicationSigning")
    for key in APPLICATION_SIGNING_KEYS:
        require_string(application[key], f"context Application signing {key}")

    migration_anchor = require_object(
        context["migrationAnchorSigning"], "context.migrationAnchorSigning"
    )
    require_exact_keys(
        migration_anchor,
        MIGRATION_ANCHOR_SIGNING_KEYS,
        "context.migrationAnchorSigning",
    )
    migration_anchor_required = require_bool(
        migration_anchor["required"], "context migration-anchor signing required"
    )
    if migration_anchor_required != (rollout["role"] == "preparer"):
        raise TipReleaseContextError(
            "context migration-anchor signing requirement must match the preparer role"
        )
    for key in (
        "bundleIdentifier",
        "teamIdentifier",
        "developerIDRequirement",
        "identityName",
    ):
        if migration_anchor_required:
            require_string(migration_anchor[key], f"context migration-anchor signing {key}")
        elif migration_anchor[key] is not None:
            raise TipReleaseContextError(
                f"context migration-anchor signing {key} must be null when not required"
            )

    installer = require_object(context["installerSigning"], "context.installerSigning")
    require_exact_keys(installer, INSTALLER_SIGNING_KEYS, "context.installerSigning")
    installer_required = require_bool(installer["required"], "context Installer signing required")
    for key in ("teamIdentifier", "identityName"):
        if installer_required:
            require_string(installer[key], f"context Installer signing {key}")
        elif installer[key] is not None:
            raise TipReleaseContextError(
                f"context Installer signing {key} must be null when not required"
            )

    sparkle = require_object(context["sparkle"], "context.sparkle")
    require_exact_keys(sparkle, SPARKLE_KEYS, "context.sparkle")
    for key in SPARKLE_KEYS:
        require_string(sparkle[key], f"context Sparkle {key}")

    package = context["package"]
    if rollout["installationType"] == "package":
        package = require_object(package, "context.package")
        require_exact_keys(package, PACKAGE_KEYS, "context.package")
        for key in ("identifier", "installLocation", "bundleOverwriteAction"):
            require_string(package[key], f"context package {key}")
        require_safe_basename(package["appBundleName"], "context package app bundle name")
        package_version = require_string(package["version"], "context package version")
        if not CF_BUNDLE_VERSION_PATTERN.fullmatch(package_version):
            raise TipReleaseContextError("context package version is not a valid CFBundleVersion")
        for key in (
            "bundleIsRelocatable",
            "bundleHasStrictIdentifier",
            "bundleIsVersionChecked",
            "hasScripts",
        ):
            require_bool(package[key], f"context package {key}")
        require_int(package["applicationBundleCount"], "context package application bundle count")
    elif package is not None:
        raise TipReleaseContextError("context package must be null for application releases")

    publication = require_object(context["publication"], "context.publication")
    require_exact_keys(publication, PUBLICATION_KEYS, "context.publication")
    require_string(publication["repository"], "context publication repository")
    require_string(publication["tag"], "context publication tag")
    require_string(publication["target"], "context publication target")
    require_bool(publication["draft"], "context publication draft")
    require_bool(publication["prerelease"], "context publication prerelease")
    assets = require_list(publication["assets"], "context publication assets")
    for position, name in enumerate(assets, start=1):
        require_safe_basename(name, f"context publication asset {position}")
    if len(set(assets)) != len(assets):
        raise TipReleaseContextError("context publication assets must be unique")


def validate_semantic_invariants(context: dict[str, Any]) -> None:
    """Validate relationships derivable from the context without ambient authority."""
    provenance = context["provenance"]
    rollout = context["rollout"]
    release = context["release"]
    application = context["applicationSigning"]
    installer = context["installerSigning"]
    sparkle = context["sparkle"]
    package = context["package"]
    publication = context["publication"]

    role = rollout["role"]
    expected_signing_identity = (
        "successor" if role in {"transition", "successor"} else "legacy"
    )
    if rollout["signingIdentity"] != expected_signing_identity:
        raise TipReleaseContextError(
            f"context {role} role requires the {expected_signing_identity} signing identity"
        )
    expected_migration_phase = (
        "legacy-preparer" if role == "preparer" else "disabled"
    )
    if rollout["runtimeSecureStorageMigrationPhase"] != expected_migration_phase:
        raise TipReleaseContextError(
            f"context {role} role requires migration phase {expected_migration_phase}"
        )
    expected_installation_type = "package" if role == "transition" else "application"
    if rollout["installationType"] != expected_installation_type:
        raise TipReleaseContextError(
            f"context {role} role requires {expected_installation_type} installation"
        )

    commit = release["commit"]
    short_sha = commit[:12]
    if release["shortSha"] != short_sha:
        raise TipReleaseContextError(
            "context release short SHA must equal the first 12 characters of the release commit"
        )
    if provenance["approvedSourceCommit"] != commit:
        raise TipReleaseContextError(
            "context approved source commit must equal the release commit"
        )
    expected_tag = f"tip-{short_sha}"
    if release["tag"] != expected_tag:
        raise TipReleaseContextError(
            f"context release tag must be derived from the release commit: expected {expected_tag}"
        )

    expected_build = (
        f"{release['stableMaximumBuild']}."
        f"{release['sourceBuildSequence'] // 100}."
        f"{release['sourceBuildSequence'] % 100}"
    )
    if release["buildNumber"] != expected_build:
        raise TipReleaseContextError(
            "context release build number must be derived from the Stable maximum and source sequence: "
            f"expected {expected_build}, got {release['buildNumber']}"
        )
    expected_archive = (
        f"{release['appName']}-tip-{short_sha}-{release['buildNumber']}"
    )
    if release["archiveBasename"] != expected_archive:
        raise TipReleaseContextError(
            f"context release archive basename mismatch: expected {expected_archive}"
        )

    expected_profile_identifier = (
        f"{application['teamIdentifier']}.{application['bundleIdentifier']}"
    )
    if application["expectedProvisioningProfileApplicationIdentifier"] != expected_profile_identifier:
        raise TipReleaseContextError(
            "context provisioning-profile application identifier must equal TeamIdentifier.BundleIdentifier"
        )

    package_required = role == "transition"
    if (package is not None) != package_required:
        raise TipReleaseContextError(
            "context package presence must match the rollout installation type"
        )
    if installer["required"] != package_required:
        raise TipReleaseContextError(
            "context Installer signing requirement must match package installation"
        )
    if package_required:
        if package["version"] != release["buildNumber"]:
            raise TipReleaseContextError(
                "context transition package version must equal the release build number"
            )
        if package["appBundleName"] != f"{release['displayName']}.app":
            raise TipReleaseContextError(
                "context transition package application name must equal the release display name"
            )
        if installer["teamIdentifier"] != application["teamIdentifier"]:
            raise TipReleaseContextError(
                "context Installer and Application Team IDs must match for package installation"
            )

    if sparkle["selectedFeedURL"] != sparkle["tipFeedURL"]:
        raise TipReleaseContextError("context selected feed must equal the reviewed Tip feed")
    if publication["repository"] != sparkle["updateRepository"]:
        raise TipReleaseContextError(
            "context publication and Sparkle update repositories must match"
        )
    if publication["tag"] != release["tag"]:
        raise TipReleaseContextError("context publication and release tags must match")
    if publication["target"] != PUBLICATION_TARGET:
        raise TipReleaseContextError(
            f"context publication target must remain {PUBLICATION_TARGET}"
        )
    if publication["draft"] or publication["prerelease"]:
        raise TipReleaseContextError(
            "context Tip publication must be neither draft nor prerelease"
        )
    expected_assets = expected_publication_assets(
        release["archiveBasename"], rollout["installationType"]
    )
    if publication["assets"] != expected_assets:
        raise TipReleaseContextError(
            "context publication assets do not match the release and installation type"
        )


def parse_detached_digest(path: Path) -> str:
    raw = read_bytes(path, "detached context digest")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as error:
        raise TipReleaseContextError("detached context digest must be ASCII") from error
    if not re.fullmatch(r"[0-9a-f]{64}\n", text):
        raise TipReleaseContextError(
            "detached context digest must contain exactly one lowercase SHA-256 and a newline"
        )
    return text[:-1]


def verify_context(args: argparse.Namespace) -> tuple[dict[str, Any], str, float]:
    started = time.monotonic()
    boundary = require_string(args.boundary, "verification boundary")
    if not BOUNDARY_PATTERN.fullmatch(boundary):
        raise TipReleaseContextError(
            "verification boundary must contain only letters, digits, dot, underscore, colon, or hyphen"
        )
    expected_digest = require_digest(args.expected_context_sha256, "expected setup context SHA-256")
    expected_approved = require_commit(
        args.expected_approved_source_commit, "expected approved source commit"
    )
    expected_tooling = require_commit(args.expected_tooling_commit, "expected trusted tooling commit")

    context, raw_context = read_json_object(Path(args.context), "Tip release context")
    scan_for_secret_like_data(context)
    actual_digest = sha256_bytes(raw_context)
    detached_digest = parse_detached_digest(Path(args.digest))
    if actual_digest != detached_digest or actual_digest != expected_digest:
        raise TipReleaseContextError(
            "Tip release context digest mismatch: "
            f"actual={actual_digest} detached={detached_digest} expected-setup={expected_digest}"
        )
    if canonical_json_bytes(context) != raw_context:
        raise TipReleaseContextError("Tip release context bytes are not canonical JSON")
    validate_closed_schema(context)
    validate_semantic_invariants(context)

    stable_appcast_value = getattr(args, "stable_appcast", None)
    if stable_appcast_value:
        stable_appcast_path = Path(stable_appcast_value)
        if stable_appcast_path.is_symlink() or not stable_appcast_path.is_file():
            raise TipReleaseContextError(
                "carried Stable appcast must be a regular non-symlink file"
            )
        actual_stable_appcast_digest = sha256_file(
            stable_appcast_path, "carried Stable appcast"
        )
        expected_stable_appcast_digest = context["provenance"]["inputSha256"][
            "stableAppcast"
        ]
        if actual_stable_appcast_digest != expected_stable_appcast_digest:
            raise TipReleaseContextError(
                "carried Stable appcast digest mismatch: "
                f"actual={actual_stable_appcast_digest} "
                f"context={expected_stable_appcast_digest}"
            )

    provenance = context["provenance"]
    if provenance["approvedSourceCommit"] != expected_approved:
        raise TipReleaseContextError(
            "approved source commit mismatch: "
            f"context={provenance['approvedSourceCommit']} expected={expected_approved}"
        )
    if provenance["trustedToolingCommit"] != expected_tooling:
        raise TipReleaseContextError(
            "trusted tooling commit mismatch: "
            f"context={provenance['trustedToolingCommit']} expected={expected_tooling}"
        )

    approved_root = args.approved_source_root
    tooling_root = args.trusted_tooling_root
    if bool(approved_root) != bool(tooling_root):
        raise TipReleaseContextError(
            "approved source and trusted tooling roots must either both be supplied or both be omitted"
        )
    if approved_root:
        approved_path = Path(approved_root)
        tooling_path = Path(tooling_root)
        require_git_head(approved_path, expected_approved, "approved source")
        require_git_head(tooling_path, expected_tooling, "trusted tooling")
        require_clean_checkout(approved_path, "approved source")
        require_clean_checkout(tooling_path, "trusted tooling")

    routing_expectations = {
        "role": (getattr(args, "expected_role", None), context["rollout"]["role"]),
        "installation type": (
            getattr(args, "expected_installation_type", None),
            context["rollout"]["installationType"],
        ),
        "tag": (getattr(args, "expected_tag", None), context["release"]["tag"]),
        "build number": (
            getattr(args, "expected_build_number", None),
            context["release"]["buildNumber"],
        ),
    }
    supplied_routing = [expected is not None for expected, _actual in routing_expectations.values()]
    if any(supplied_routing) and not all(supplied_routing):
        raise TipReleaseContextError(
            "expected role, installation type, tag, and build number must be supplied together"
        )
    for label, (expected, actual) in routing_expectations.items():
        if expected is not None and expected != actual:
            raise TipReleaseContextError(
                f"setup routing {label} mismatch: context={actual!r} expected={expected!r}"
            )

    elapsed_ms = (time.monotonic() - started) * 1000
    return context, actual_digest, elapsed_ms


REQUIRED_ENVIRONMENT_NAMES = (
    "REPOPROMPT_TIP_RELEASE_CONTEXT",
    "REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE",
    "REPOPROMPT_TIP_STABLE_APPCAST",
    "REPOPROMPT_EXPECTED_CONTEXT_SHA256",
    "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT",
    "REPOPROMPT_EXPECTED_TOOLING_COMMIT",
    "REPOPROMPT_APPROVED_SOURCE_ROOT",
)


def verify_context_from_environment(
    boundary: str, trusted_tooling_root: str
) -> tuple[dict[str, Any], str, float]:
    """Verify the context selected by the REPOPROMPT_* environment authority."""
    missing = [name for name in REQUIRED_ENVIRONMENT_NAMES if not os.environ.get(name)]
    if missing:
        raise TipReleaseContextError(
            "missing required Tip context environment: " + ", ".join(missing)
        )
    args = argparse.Namespace(
        context=os.environ["REPOPROMPT_TIP_RELEASE_CONTEXT"],
        digest=os.environ["REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE"],
        stable_appcast=os.environ["REPOPROMPT_TIP_STABLE_APPCAST"],
        expected_context_sha256=os.environ["REPOPROMPT_EXPECTED_CONTEXT_SHA256"],
        expected_approved_source_commit=os.environ[
            "REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT"
        ],
        expected_tooling_commit=os.environ["REPOPROMPT_EXPECTED_TOOLING_COMMIT"],
        boundary=boundary,
        approved_source_root=os.environ["REPOPROMPT_APPROVED_SOURCE_ROOT"],
        trusted_tooling_root=trusted_tooling_root,
        expected_role=None,
        expected_installation_type=None,
        expected_tag=None,
        expected_build_number=None,
    )
    return verify_context(args)


def verification_line(context: dict[str, Any], digest: str, boundary: str, elapsed_ms: float) -> str:
    provenance = context["provenance"]
    rollout = context["rollout"]
    release = context["release"]
    return (
        f"OK: Tip context verified boundary={boundary} digest={digest} "
        f"source={provenance['approvedSourceCommit']} tooling={provenance['trustedToolingCommit']} "
        f"role={rollout['role']} runtime-secure-storage-migration-phase="
        f"{rollout['runtimeSecureStorageMigrationPhase']} build={release['buildNumber']} "
        f"tag={release['tag']} installation-type={rollout['installationType']} "
        f"elapsed-ms={elapsed_ms:.1f}"
    )


def shell_exports(context: dict[str, Any], digest: str) -> dict[str, str]:
    rollout = context["rollout"]
    release = context["release"]
    application = context["applicationSigning"]
    migration_anchor = context["migrationAnchorSigning"]
    installer = context["installerSigning"]
    sparkle = context["sparkle"]
    publication = context["publication"]
    values = {
        "REPOPROMPT_TIP_CONTEXT_SHA256": digest,
        "REPOPROMPT_TIP_ARCHIVE_CONTRACT": context["archiveContract"],
        "TIP_COMMIT": release["commit"],
        "TIP_SHORT_SHA": release["shortSha"],
        "TIP_BUILD_SEQUENCE": str(release["sourceBuildSequence"]),
        "TIP_BUILD_NUMBER": release["buildNumber"],
        "TIP_TAG": release["tag"],
        "ARCHIVE_BASENAME": release["archiveBasename"],
        "APP_NAME": release["appName"],
        "DISPLAY_NAME": release["displayName"],
        "MARKETING_VERSION": release["marketingVersion"],
        "ROLLOUT_CHANNEL": rollout["channel"],
        "ROLLOUT_ROLE": rollout["role"],
        "ROLLOUT_IDENTITY": rollout["signingIdentity"],
        "REPOPROMPT_IDENTITY_MIGRATION_PHASE": rollout[
            "runtimeSecureStorageMigrationPhase"
        ],
        "ROLLOUT_INSTALLATION_TYPE": rollout["installationType"],
        "BUNDLE_ID": application["bundleIdentifier"],
        "SIGNING_TEAM_ID": application["teamIdentifier"],
        "EXPECTED_APP_REQUIREMENT": application["developerIDRequirement"],
        "EXPECTED_SIGN_IDENTITY": application["identityName"],
        "EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER": application[
            "expectedProvisioningProfileApplicationIdentifier"
        ],
        "EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID": migration_anchor["bundleIdentifier"] or "",
        "EXPECTED_MIGRATION_ANCHOR_TEAM_ID": migration_anchor["teamIdentifier"] or "",
        "EXPECTED_MIGRATION_ANCHOR_REQUIREMENT": (
            migration_anchor["developerIDRequirement"] or ""
        ),
        "EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY": migration_anchor["identityName"] or "",
        "EXPECTED_INSTALLER_TEAM_ID": installer["teamIdentifier"] or "",
        "EXPECTED_INSTALLER_IDENTITY": installer["identityName"] or "",
        "SPARKLE_PUBLIC_EDDSA_VALUE": sparkle["publicEdDSAValue"],
        "ROLLOUT_UPDATE_REPOSITORY": sparkle["updateRepository"],
        "ROLLOUT_FEED_URL": sparkle["selectedFeedURL"],
        "TIP_PUBLICATION_TARGET": publication["target"],
        "TIP_PUBLICATION_DRAFT": str(publication["draft"]).lower(),
        "TIP_PUBLICATION_PRERELEASE": str(publication["prerelease"]).lower(),
        "TIP_PUBLICATION_ASSETS_JSON": json.dumps(publication["assets"], separators=(",", ":")),
    }
    if tuple(values) != SHELL_EXPORT_KEYS:
        raise TipReleaseContextError("internal shell export allowlist mismatch")
    return values


def markdown_code(value: Any) -> str:
    escaped = html.escape(str(value), quote=False)
    longest = max((len(match.group(0)) for match in re.finditer(r"`+", escaped)), default=0)
    fence = "`" * (longest + 1)
    padding = " " if longest else ""
    return f"{fence}{padding}{escaped}{padding}{fence}"


def render_summary(context: dict[str, Any], digest: str, boundary: str, elapsed_ms: float) -> str:
    provenance = context["provenance"]
    digests = provenance["inputSha256"]
    rollout = context["rollout"]
    release = context["release"]
    application = context["applicationSigning"]
    migration_anchor = context["migrationAnchorSigning"]
    installer = context["installerSigning"]
    sparkle = context["sparkle"]
    package = context["package"]
    publication = context["publication"]
    lines = [
        "## Tip release context",
        "",
        f"- Verification boundary: {markdown_code(boundary)}",
        f"- Context SHA-256: {markdown_code(digest)}",
        f"- Verification elapsed milliseconds: {markdown_code(f'{elapsed_ms:.1f}')}",
        "",
        "### Authority provenance",
        "",
        f"- Approved source commit: {markdown_code(provenance['approvedSourceCommit'])}",
        f"- Trusted tooling commit: {markdown_code(provenance['trustedToolingCommit'])}",
    ]
    for key in sorted(digests):
        lines.append(f"- Input {markdown_code(key)} SHA-256: {markdown_code(digests[key])}")
    lines += [
        "",
        "### Rollout and release",
        "",
        f"- Rollout role: {markdown_code(rollout['role'])}",
        "- Runtime secure-storage migration phase: "
        f"{markdown_code(rollout['runtimeSecureStorageMigrationPhase'])}",
        f"- Eligibility profile: {markdown_code(rollout['eligibilityProfile'])}",
        f"- Installation type: {markdown_code(rollout['installationType'])}",
        f"- Marketing version: {markdown_code(release['marketingVersion'])}",
        f"- Stable maximum build: {markdown_code(release['stableMaximumBuild'])}",
        f"- Source build sequence: {markdown_code(release['sourceBuildSequence'])}",
        f"- Tip build: {markdown_code(release['buildNumber'])}",
        f"- Tag: {markdown_code(release['tag'])}",
        f"- Archive basename: {markdown_code(release['archiveBasename'])}",
        "",
        "### Application signing",
        "",
        f"- Bundle identifier: {markdown_code(application['bundleIdentifier'])}",
        f"- Team identifier: {markdown_code(application['teamIdentifier'])}",
        f"- Public identity label: {markdown_code(application['identityName'])}",
        "- Expected provisioning-profile application identifier: "
        f"{markdown_code(application['expectedProvisioningProfileApplicationIdentifier'])}",
        "",
        "### Migration-anchor Application signing",
        "",
        f"- Required: {markdown_code(str(migration_anchor['required']).lower())}",
        "- Bundle identifier: "
        f"{markdown_code(migration_anchor['bundleIdentifier'] or 'not-required')}",
        "- Team identifier: "
        f"{markdown_code(migration_anchor['teamIdentifier'] or 'not-required')}",
        "- Public identity label: "
        f"{markdown_code(migration_anchor['identityName'] or 'not-required')}",
        "",
        "### Installer signing",
        "",
        f"- Required: {markdown_code(str(installer['required']).lower())}",
        f"- Team identifier: {markdown_code(installer['teamIdentifier'] or 'not-required')}",
        f"- Public identity label: {markdown_code(installer['identityName'] or 'not-required')}",
        "",
        "### Sparkle public signing and feeds",
        "",
        f"- Public EdDSA value: {markdown_code(sparkle['publicEdDSAValue'])}",
        f"- Stable feed: {markdown_code(sparkle['stableFeedURL'])}",
        f"- Tip feed: {markdown_code(sparkle['tipFeedURL'])}",
        f"- Selected Tip feed: {markdown_code(sparkle['selectedFeedURL'])}",
        f"- Tip update repository: {markdown_code(sparkle['updateRepository'])}",
        "",
        "### Transition package",
        "",
    ]
    if package is None:
        lines.append("- Not required; transition-only package metadata is omitted.")
    else:
        lines += [
            f"- Identifier: {markdown_code(package['identifier'])}",
            f"- Install location: {markdown_code(package['installLocation'])}",
            f"- Application bundle: {markdown_code(package['appBundleName'])}",
            f"- Version: {markdown_code(package['version'])}",
            f"- Relocatable: {markdown_code(str(package['bundleIsRelocatable']).lower())}",
            "- Strict identifier: "
            f"{markdown_code(str(package['bundleHasStrictIdentifier']).lower())}",
            f"- Version checked: {markdown_code(str(package['bundleIsVersionChecked']).lower())}",
            f"- Overwrite action: {markdown_code(package['bundleOverwriteAction'])}",
            f"- Scripts present: {markdown_code(str(package['hasScripts']).lower())}",
            f"- Application bundle count: {markdown_code(package['applicationBundleCount'])}",
        ]
    lines += ["", "### Predecessor pins", ""]
    if rollout["predecessors"]:
        for position, predecessor in enumerate(rollout["predecessors"], start=1):
            lines.append(
                f"{position}. Role {markdown_code(predecessor['role'])}; "
                f"tag {markdown_code(predecessor['tag'])}; rollout manifest SHA-256 "
                f"{markdown_code(predecessor['rolloutManifestSha256'])}"
            )
    else:
        lines.append("- None")
    lines += ["", "### Exact publication inventory", ""]
    for asset in publication["assets"]:
        lines.append(f"- {markdown_code(asset)}")
    return "\n".join(lines) + "\n"


def write_atomic(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError as error:
        raise TipReleaseContextError(f"cannot write {path.name}: {error}") from error
    finally:
        temporary.unlink(missing_ok=True)


def append_github_environment(path: Path, values: dict[str, str]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            for key, value in values.items():
                if "\n" in value or "\r" in value:
                    raise TipReleaseContextError(
                        f"Tip context shell export {key} contains a line break"
                    )
                handle.write(f"{key}={value}\n")
    except OSError as error:
        raise TipReleaseContextError(f"cannot append GitHub environment file: {error}") from error


def run_resolve(args: argparse.Namespace) -> None:
    approved_commit = require_commit(args.approved_source_commit, "approved source commit")
    tooling_commit = require_commit(args.trusted_tooling_commit, "trusted tooling commit")
    approved_root = Path(args.approved_source_root)
    tooling_root = Path(args.trusted_tooling_root)
    require_git_head(approved_root, approved_commit, "approved source")
    require_git_head(tooling_root, tooling_commit, "trusted tooling")

    policy_path = require_committed_file(
        tooling_root,
        tooling_commit,
        "Scripts/apple_identity_policy.json",
        "Apple identity policy",
    )
    rollout_tool_path = require_committed_file(
        tooling_root,
        tooling_commit,
        "Scripts/stable_rollout.py",
        "stable rollout tool",
    )
    context_tool_path = require_committed_file(
        tooling_root,
        tooling_commit,
        "Scripts/tip_release_context.py",
        "Tip release context tool",
    )
    declaration_path = require_committed_file(
        approved_root,
        approved_commit,
        "tip-rollout.json",
        "Tip rollout declaration",
    )
    version_env_path = require_committed_file(
        approved_root,
        approved_commit,
        "version.env",
        "version.env",
    )
    if read_bytes(Path(__file__), "active Tip release context tool") != read_bytes(
        context_tool_path, "committed Tip release context tool"
    ):
        raise TipReleaseContextError(
            "active Tip release context tool does not match the committed trusted tooling input"
        )
    require_clean_checkout(approved_root, "approved source")
    require_clean_checkout(tooling_root, "trusted tooling")

    rollout = load_rollout_tool(rollout_tool_path)
    context = build_context(
        rollout=rollout,
        policy_path=policy_path,
        rollout_tool_path=rollout_tool_path,
        context_tool_path=context_tool_path,
        declaration_path=declaration_path,
        version_env_path=version_env_path,
        stable_appcast_path=Path(args.stable_appcast),
        approved_source_commit=approved_commit,
        trusted_tooling_commit=tooling_commit,
        source_build_sequence=args.source_build_sequence,
        expected_tip_update_repository=require_string(
            args.expected_tip_update_repository, "expected Tip update repository"
        ),
    )
    raw = canonical_json_bytes(context)
    digest = sha256_bytes(raw)
    output = Path(args.output)
    digest_output = Path(args.digest_output)
    if output.resolve() == digest_output.resolve():
        raise TipReleaseContextError("context and detached digest outputs must be different files")
    write_atomic(output, raw)
    write_atomic(digest_output, f"{digest}\n".encode("ascii"))
    print(
        f"OK: resolved canonical Tip release context digest={digest} "
        f"source={approved_commit} tooling={tooling_commit} role={context['rollout']['role']} "
        f"runtime-secure-storage-migration-phase="
        f"{context['rollout']['runtimeSecureStorageMigrationPhase']} "
        f"build={context['release']['buildNumber']} tag={context['release']['tag']}"
    )


def run_verify(args: argparse.Namespace) -> None:
    context, digest, elapsed_ms = verify_context(args)
    line = verification_line(context, digest, args.boundary, elapsed_ms)
    if args.emit_shell:
        print(line, file=sys.stderr)
        for key, value in shell_exports(context, digest).items():
            print(f"{key}={shlex.quote(value)}")
    else:
        print(line)
    if args.github_env:
        append_github_environment(Path(args.github_env), shell_exports(context, digest))


def run_summary(args: argparse.Namespace) -> None:
    context, digest, elapsed_ms = verify_context(args)
    output_value = args.output or os.environ.get("GITHUB_STEP_SUMMARY", "")
    if not output_value:
        raise TipReleaseContextError("summary requires --output or GITHUB_STEP_SUMMARY")
    output = Path(output_value)
    summary = render_summary(context, digest, args.boundary, elapsed_ms)
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(summary)
    except OSError as error:
        raise TipReleaseContextError(f"cannot write Tip context summary: {error}") from error
    print(verification_line(context, digest, args.boundary, elapsed_ms))


def add_verification_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--context", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--expected-context-sha256", required=True)
    parser.add_argument("--expected-approved-source-commit", required=True)
    parser.add_argument("--expected-tooling-commit", required=True)
    parser.add_argument("--boundary", required=True)
    parser.add_argument("--stable-appcast")
    parser.add_argument("--approved-source-root")
    parser.add_argument("--trusted-tooling-root")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    resolve = commands.add_parser("resolve", help="resolve and write one canonical Tip context")
    resolve.add_argument("--trusted-tooling-root", required=True)
    resolve.add_argument("--approved-source-root", required=True)
    resolve.add_argument("--stable-appcast", required=True)
    resolve.add_argument("--approved-source-commit", required=True)
    resolve.add_argument("--trusted-tooling-commit", required=True)
    resolve.add_argument("--source-build-sequence", required=True, type=int)
    resolve.add_argument("--expected-tip-update-repository", required=True)
    resolve.add_argument("--output", required=True)
    resolve.add_argument("--digest-output", required=True)
    resolve.set_defaults(func=run_resolve)

    verify = commands.add_parser("verify", help="verify exact context bytes against setup digest")
    add_verification_arguments(verify)
    verify.add_argument("--emit-shell", action="store_true")
    verify.add_argument("--github-env")
    verify.add_argument("--expected-role")
    verify.add_argument("--expected-installation-type")
    verify.add_argument("--expected-tag")
    verify.add_argument("--expected-build-number")
    verify.set_defaults(func=run_verify)

    summary = commands.add_parser("summary", help="verify and append a Markdown-safe public summary")
    add_verification_arguments(summary)
    summary.add_argument("--output")
    summary.set_defaults(func=run_summary)

    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except TipReleaseContextError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
