#!/usr/bin/env python3
"""Single rollout authority for the Apple identity transition.

Owns reviewed channel declarations, generated immutable rollout manifests, and
the accumulated Stable or Tip appcast. Version/build/bundle/team values are never
duplicated in the declaration; they are derived from `version.env` and
`Scripts/apple_identity_policy.json` and cross-checked here.

Commands:
- ``workflow-guard``: protected workflows call this to reject transition or
  successor roles, sibling predecessors, and the successor identity.
- ``current-role``: print the declared role for shell callers.
- ``packaging-context``: emit one phase-bound application, migration-anchor, and Installer context.
- ``signing-mode``: map one reviewed bundle/team pair to its runtime signing marker.
- ``generate``: assemble the accumulated appcast plus rollout manifest.
- ``validate``: prove a reviewed appcast/manifest pair against the declaration,
  policy, version metadata, and enclosure/app-manifest digests.
- ``max-build``: greatest Sparkle build in an appcast (monotonicity input).
- ``sibling-values``: TSV projection of predecessor items for shell loops.

EdDSA signing/verification stays in shell (sign_update /
verify_sparkle_signature.swift); publication stays in the protected workflows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Never write in-tree bytecode: an untracked __pycache__ would fail the
# strict trusted-root clean-checkout verification.
sys.dont_write_bytecode = True

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ROLLOUT_NAMESPACE = "https://repoprompt.com/xml-namespaces/rollout"
DECLARATION_SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 1
POLICY_SCHEMA_VERSION = 1

IDENTITY_TRANSITION_PACKAGE_KEYS = {
    "identifier",
    "installLocation",
    "appBundleName",
    "bundleIsRelocatable",
    "bundleHasStrictIdentifier",
    "bundleIsVersionChecked",
    "bundleOverwriteAction",
    "hasScripts",
    "applicationBundleCount",
}

ROLES = ("legacy", "preparer", "transition", "successor")
CHANNELS = ("stable", "tip")
WORKFLOW_ALLOWED_ROLES = ("legacy", "preparer")
ROLE_IDENTITY = {
    "legacy": "legacy",
    "preparer": "legacy",
    "transition": "successor",
    "successor": "successor",
}
ROLE_MIGRATION_PHASE = {
    "legacy": "disabled",
    "preparer": "legacy-preparer",
    "transition": "disabled",
    "successor": "disabled",
}
ROLE_INSTALLATION_TYPE = {
    "legacy": "application",
    "preparer": "application",
    "transition": "package",
    "successor": "application",
}
ROLE_ENCLOSURE_SUFFIX = {
    "legacy": ".zip",
    "preparer": ".zip",
    "transition": ".pkg",
    "successor": ".zip",
}
SIGNING_MODE_BY_IDENTITY = {
    "legacy": "developer-id",
    "successor": "successor-developer-id",
}
# Newest-first role chains permitted in an accumulated appcast.
ALLOWED_ROLE_CHAINS = (
    ("legacy",),
    ("preparer",),
    ("transition", "preparer"),
    ("successor", "transition", "preparer"),
)

DECLARATION_KEYS = {
    "schemaVersion",
    "channel",
    "currentRole",
    "eligibilityProfile",
    "expectedMigrationPhase",
    "expectedSigningIdentity",
    "predecessors",
}
PREDECESSOR_KEYS = {"role", "tag", "rolloutManifestSha256"}


class RolloutError(Exception):
    pass


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_build(raw: str, label: str) -> tuple[int, ...]:
    parts = str(raw).split(".")
    if not (1 <= len(parts) <= 3) or not all(part.isdigit() and part != "" for part in parts):
        raise RolloutError(f"malformed {label}: {raw!r}")
    numbers = tuple(int(part) for part in parts)
    return numbers + (0,) * (3 - len(numbers))


def load_json(path: Path, label: str) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RolloutError(f"unreadable {label} at {path}: {error}") from error
    if not isinstance(data, dict):
        raise RolloutError(f"{label} must be a JSON object")
    return data


def load_policy(path: Path) -> dict:
    policy = load_json(path, "apple identity policy")
    if policy.get("schemaVersion") != POLICY_SCHEMA_VERSION:
        raise RolloutError("apple identity policy schema version mismatch")
    for identity in ("legacy", "successor"):
        entry = policy.get("identities", {}).get(identity)
        if not isinstance(entry, dict) or not all(
            isinstance(entry.get(key), str) and entry.get(key)
            for key in (
                "bundleIdentifier",
                "teamIdentifier",
                "developerIDRequirement",
                "developerIDApplicationIdentityName",
            )
        ):
            raise RolloutError(f"apple identity policy is missing the {identity} identity")
    sparkle = policy.get("sparkle")
    if not isinstance(sparkle, dict) or not all(
        isinstance(sparkle.get(key), str) and sparkle.get(key)
        for key in (
            "stableFeedURL",
            "tipFeedURL",
            "sparklePublicEdDSAValue",
            "updateRepository",
            "tipUpdateRepository",
            "minimumSystemVersion",
        )
    ):
        raise RolloutError("apple identity policy is missing sparkle invariants")
    return policy


def validate_identity_transition_package(policy: dict) -> dict:
    """Validate the migration-only package policy without coupling Stable callers to it."""
    transition_package = policy.get("identityTransitionPackage")
    if not isinstance(transition_package, dict) or set(transition_package) != IDENTITY_TRANSITION_PACKAGE_KEYS:
        raise RolloutError(
            "apple identity policy transition package keys must be exactly "
            + ", ".join(sorted(IDENTITY_TRANSITION_PACKAGE_KEYS))
        )
    if not all(
        isinstance(transition_package.get(key), str) and transition_package[key]
        for key in ("identifier", "installLocation", "appBundleName", "bundleOverwriteAction")
    ):
        raise RolloutError("apple identity policy transition package strings must be nonempty")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", transition_package["identifier"]):
        raise RolloutError("apple identity policy transition package identifier must be reverse-DNS")
    if Path(transition_package["appBundleName"]).name != transition_package["appBundleName"] or not transition_package[
        "appBundleName"
    ].endswith(".app"):
        raise RolloutError("apple identity policy transition package appBundleName must be one app basename")
    expected_semantics = {
        "installLocation": "/Applications",
        "bundleIsRelocatable": False,
        "bundleHasStrictIdentifier": False,
        "bundleIsVersionChecked": True,
        "bundleOverwriteAction": "upgrade",
        "hasScripts": False,
        "applicationBundleCount": 1,
    }
    if any(transition_package[key] != value for key, value in expected_semantics.items()):
        raise RolloutError(
            "apple identity policy transition package must describe exactly one "
            "non-relocatable, version-checked, script-free /Applications app upgrade"
        )
    return transition_package


def load_declaration(path: Path) -> dict:
    declaration = load_json(path, "rollout declaration")
    if set(declaration) != DECLARATION_KEYS:
        raise RolloutError(
            "rollout declaration keys must be exactly "
            + ", ".join(sorted(DECLARATION_KEYS))
        )
    if declaration["schemaVersion"] != DECLARATION_SCHEMA_VERSION:
        raise RolloutError("rollout declaration schema version mismatch")
    if declaration["channel"] not in CHANNELS:
        raise RolloutError(f"rollout declaration channel must be one of {', '.join(CHANNELS)}")
    role = declaration["currentRole"]
    if role not in ROLES:
        raise RolloutError(f"unknown rollout role: {role!r}")
    if not isinstance(declaration["eligibilityProfile"], str) or not declaration["eligibilityProfile"]:
        raise RolloutError("rollout declaration eligibilityProfile must be a nonempty string")
    if declaration["expectedMigrationPhase"] != ROLE_MIGRATION_PHASE[role]:
        raise RolloutError(
            f"declared migration phase must be {ROLE_MIGRATION_PHASE[role]} for the {role} role"
        )
    if declaration["expectedSigningIdentity"] != ROLE_IDENTITY[role]:
        raise RolloutError(
            f"declared signing identity must be {ROLE_IDENTITY[role]} for the {role} role"
        )
    predecessors = declaration["predecessors"]
    if not isinstance(predecessors, list):
        raise RolloutError("rollout declaration predecessors must be a list")
    for position, entry in enumerate(predecessors, start=1):
        if not isinstance(entry, dict) or set(entry) != PREDECESSOR_KEYS:
            raise RolloutError(
                f"predecessor {position} keys must be exactly " + ", ".join(sorted(PREDECESSOR_KEYS))
            )
        if entry["role"] not in ROLES:
            raise RolloutError(f"predecessor {position} has unknown role {entry['role']!r}")
        if not isinstance(entry["tag"], str) or not entry["tag"]:
            raise RolloutError(f"predecessor {position} tag must be a nonempty string")
        if declaration["channel"] == "stable" and not entry["tag"].startswith("v"):
            raise RolloutError(f"predecessor {position} Stable tag must look like v<marketing-version>")
        if declaration["channel"] == "tip" and not entry["tag"].startswith("tip-"):
            raise RolloutError(f"predecessor {position} Tip tag must start with tip-")
        digest = entry["rolloutManifestSha256"]
        if not isinstance(digest, str) or len(digest) != 64 or not all(c in "0123456789abcdef" for c in digest):
            raise RolloutError(f"predecessor {position} rolloutManifestSha256 must be lowercase hex sha256")
    chain = (role, *[entry["role"] for entry in predecessors])
    if chain not in ALLOWED_ROLE_CHAINS:
        raise RolloutError(
            "declared role chain "
            + " -> ".join(chain)
            + " is not an allowed newest-first rollout chain"
        )
    return declaration


def load_version_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    for key in ("APP_NAME", "MARKETING_VERSION", "BUILD_NUMBER", "BUNDLE_ID", "SIGNING_TEAM_ID"):
        if not values.get(key):
            raise RolloutError(f"version.env is missing {key}")
    return values


def identity_name_for_bundle_and_team(policy: dict, bundle_id: str, team_id: str) -> str:
    matches = [
        identity_name
        for identity_name, identity in policy["identities"].items()
        if identity["bundleIdentifier"] == bundle_id and identity["teamIdentifier"] == team_id
    ]
    if len(matches) != 1:
        raise RolloutError(
            "bundle/team pair does not match exactly one reviewed Apple identity: "
            f"{bundle_id} / {team_id}"
        )
    return matches[0]


def expected_enclosure_name(
    app_name: str,
    marketing: str,
    build: str,
    role: str,
    enclosure_basename: str | None = None,
) -> str:
    basename = enclosure_basename or f"{app_name}-{marketing}-{build}"
    return f"{basename}{ROLE_ENCLOSURE_SUFFIX[role]}"


def rollout_manifest_name(app_name: str, marketing: str, build: str, channel: str) -> str:
    if channel == "tip":
        return "identity-rollout.json"
    return f"{app_name}-{marketing}-{build}-stable-rollout.json"


def update_repository(policy: dict, channel: str) -> str:
    key = "tipUpdateRepository" if channel == "tip" else "updateRepository"
    return policy["sparkle"][key]


def enclosure_url(update_repository: str, tag: str, name: str) -> str:
    return f"https://github.com/{update_repository}/releases/download/{tag}/{name}"


def validate_item_shape(
    item: dict,
    position: int,
    policy: dict,
    app_name: str,
    channel: str,
) -> None:
    minimum_system = policy["sparkle"]["minimumSystemVersion"]
    role = item.get("role")
    if role not in ROLES:
        raise RolloutError(f"appcast item {position} has unknown role {role!r}")
    build = str(item.get("buildNumber", ""))
    marketing = str(item.get("marketingVersion", ""))
    parse_build(build, f"item {position} build number")
    tag = item.get("tag", "")
    if channel == "stable" and tag != f"v{marketing}":
        raise RolloutError(f"appcast item {position} Stable tag must be v{marketing}, got {tag!r}")
    if channel == "tip" and not str(tag).startswith("tip-"):
        raise RolloutError(f"appcast item {position} Tip tag must start with tip-, got {tag!r}")
    if item.get("minimumSystemVersion") != minimum_system:
        raise RolloutError(
            f"appcast item {position} minimumSystemVersion must be exactly {minimum_system}"
        )
    if item.get("installationType") != ROLE_INSTALLATION_TYPE[role]:
        raise RolloutError(
            f"appcast item {position} installation type must be "
            f"{ROLE_INSTALLATION_TYPE[role]} for the {role} role"
        )
    enclosure_name = item.get("enclosureName")
    if channel == "stable":
        expected_name = expected_enclosure_name(app_name, marketing, build, role)
        if enclosure_name != expected_name:
            raise RolloutError(
                f"appcast item {position} enclosure name must be {expected_name}, got {enclosure_name!r}"
            )
    elif not isinstance(enclosure_name, str) or not enclosure_name.endswith(ROLE_ENCLOSURE_SUFFIX[role]):
        raise RolloutError(f"appcast item {position} enclosure name has the wrong role suffix")
    if item.get("url") != enclosure_url(update_repository(policy, channel), tag, enclosure_name):
        raise RolloutError(f"appcast item {position} enclosure URL mismatch: {item.get('url')!r}")
    size = item.get("enclosureSize")
    if not isinstance(size, int) or size <= 0:
        raise RolloutError(f"appcast item {position} enclosure size must be a positive integer")
    digest = item.get("enclosureSha256", "")
    if not isinstance(digest, str) or len(digest) != 64:
        raise RolloutError(f"appcast item {position} enclosure sha256 is malformed")
    if not item.get("edSignature"):
        raise RolloutError(f"appcast item {position} is missing an EdDSA signature")


def validate_item_ladder(items: list[dict]) -> None:
    chain = tuple(item["role"] for item in items)
    if chain not in ALLOWED_ROLE_CHAINS:
        raise RolloutError(
            "appcast role chain " + " -> ".join(chain) + " is not an allowed newest-first rollout chain"
        )
    builds = [parse_build(str(item["buildNumber"]), "item build") for item in items]
    for newer, older in zip(builds, builds[1:]):
        if not newer > older:
            raise RolloutError("appcast builds must be unique and strictly ordered newest-first")
    for position, item in enumerate(items):
        expected = str(items[position + 1]["buildNumber"]) if position + 1 < len(items) else None
        if "minimumUpdateVersion" not in item:
            raise RolloutError(
                f"appcast item {position + 1} is missing the minimumUpdateVersion authority"
            )
        if "minimumAutoupdateVersion" in item:
            raise RolloutError(
                f"appcast item {position + 1} must not carry an independent "
                "minimumAutoupdateVersion authority"
            )
        actual = item["minimumUpdateVersion"]
        if actual != expected:
            raise RolloutError(
                f"appcast item {position + 1} minimumUpdateVersion must be "
                f"{expected!r} (the immediately older build), got {actual!r}"
            )


def normalize_published_preparer_floor(
    item: dict, position: int, allow_published_tip_preparer: bool
) -> dict:
    """Normalize only the already-published Tip P null-floor representation.

    Public preparer P was generated before ``minimumUpdateVersion`` became the
    manifest authority. Its digest-bound manifest carries
    ``minimumAutoupdateVersion: null``. Accept that exact ungated legacy form
    after its bytes have been authenticated, but never accept a gated item or
    retain the compatibility projection as a second manifest authority.
    """
    normalized = dict(item)
    if "minimumUpdateVersion" in normalized:
        return normalized
    if (
        allow_published_tip_preparer
        and normalized.get("role") == "preparer"
        and "minimumAutoupdateVersion" in normalized
        and normalized["minimumAutoupdateVersion"] is None
    ):
        del normalized["minimumAutoupdateVersion"]
        normalized["minimumUpdateVersion"] = None
        return normalized
    raise RolloutError(
        f"appcast item {position} is missing the minimumUpdateVersion authority"
    )


def normalize_manifest_floor_authority(manifest: dict) -> dict:
    normalized = dict(manifest)
    items = manifest.get("appcastItems")
    if not isinstance(items, list) or not items:
        raise RolloutError("rollout manifest must contain appcast items")
    allow_published_tip_preparer = (
        manifest.get("channel") == "tip"
        and manifest.get("currentRole") == "preparer"
        and len(items) == 1
    )
    normalized_items = []
    for position, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            raise RolloutError(f"appcast item {position} must be an object")
        normalized_items.append(
            normalize_published_preparer_floor(
                item, position, allow_published_tip_preparer
            )
        )
    normalized["appcastItems"] = normalized_items
    return normalized


def xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def render_appcast(manifest: dict) -> str:
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" '
        f'xmlns:sparkle="{SPARKLE_NAMESPACE}" '
        f'xmlns:repoprompt="{ROLLOUT_NAMESPACE}">',
        "  <channel>",
        f"    <title>RepoPrompt CE {manifest['channel'].title()}</title>",
    ]
    for item in manifest["appcastItems"]:
        lines.append("    <item>")
        title = (
            f"Tip build {item['buildNumber']}"
            if manifest["channel"] == "tip"
            else f"Version {item['marketingVersion']}"
        )
        lines.append(f"      <title>{xml_escape(str(title))}</title>")
        lines.append(
            f"      <repoprompt:rolloutRole>{xml_escape(item['role'])}</repoprompt:rolloutRole>"
        )
        lines.append(f"      <sparkle:version>{xml_escape(str(item['buildNumber']))}</sparkle:version>")
        lines.append(
            "      <sparkle:shortVersionString>"
            f"{xml_escape(str(item['marketingVersion']))}</sparkle:shortVersionString>"
        )
        lines.append(
            "      <sparkle:minimumSystemVersion>"
            f"{xml_escape(item['minimumSystemVersion'])}</sparkle:minimumSystemVersion>"
        )
        if item["minimumUpdateVersion"] is not None:
            floor = xml_escape(str(item["minimumUpdateVersion"]))
            lines.append(
                "      <sparkle:minimumUpdateVersion>"
                f"{floor}</sparkle:minimumUpdateVersion>"
            )
            lines.append(
                "      <sparkle:minimumAutoupdateVersion>"
                f"{floor}</sparkle:minimumAutoupdateVersion>"
            )
        enclosure = (
            f'      <enclosure url="{xml_escape(item["url"])}" '
            f'length="{item["enclosureSize"]}" '
            'type="application/octet-stream" '
            f'sparkle:edSignature="{xml_escape(item["edSignature"])}"'
        )
        if item["installationType"] == "package":
            enclosure += ' sparkle:installationType="package"'
        enclosure += "/>"
        lines.append(enclosure)
        lines.append("    </item>")
    lines.append("  </channel>")
    lines.append("</rss>")
    return "\n".join(lines) + "\n"


def load_manifest(path: Path) -> dict:
    manifest = load_json(path, "rollout manifest")
    if manifest.get("schemaVersion") != MANIFEST_SCHEMA_VERSION:
        raise RolloutError("rollout manifest schema version mismatch")
    if not isinstance(manifest.get("appcastItems"), list) or not manifest["appcastItems"]:
        raise RolloutError("rollout manifest must contain appcast items")
    return manifest


def load_predecessor_manifests(
    declaration: dict, manifest_paths: list[str], policy: dict, app_name: str
) -> list[dict]:
    predecessors = declaration["predecessors"]
    if len(manifest_paths) != len(predecessors):
        raise RolloutError(
            f"expected {len(predecessors)} predecessor manifest file(s), got {len(manifest_paths)}"
        )
    loaded: list[dict] = []
    for position, (entry, manifest_path) in enumerate(zip(predecessors, manifest_paths), start=1):
        path = Path(manifest_path)
        digest = sha256_file(path)
        if digest != entry["rolloutManifestSha256"]:
            raise RolloutError(
                f"predecessor {position} rollout manifest digest mismatch for tag {entry['tag']}: "
                f"expected {entry['rolloutManifestSha256']}, got {digest}"
            )
        manifest = normalize_manifest_floor_authority(load_manifest(path))
        if manifest.get("channel") != declaration["channel"]:
            raise RolloutError(
                f"predecessor {position} channel mismatch: declaration says {declaration['channel']}, "
                f"manifest says {manifest.get('channel')}"
            )
        if manifest.get("currentRole") != entry["role"]:
            raise RolloutError(
                f"predecessor {position} manifest role mismatch: declaration says {entry['role']}, "
                f"manifest says {manifest.get('currentRole')}"
            )
        if manifest.get("sourceTag") != entry["tag"]:
            raise RolloutError(
                f"predecessor {position} manifest tag mismatch: declaration says {entry['tag']}, "
                f"manifest says {manifest.get('sourceTag')}"
            )
        current_item = manifest["appcastItems"][0]
        validate_item_shape(current_item, position, policy, app_name, declaration["channel"])
        loaded.append(manifest)
    return loaded


def build_manifest_from_inputs(
    args: argparse.Namespace,
    policy: dict,
    declaration: dict,
    version: dict[str, str],
) -> tuple[dict, str]:
    role = declaration["currentRole"]
    channel = declaration["channel"]

    allowed_roles = tuple(args.allowed_roles.split(",")) if args.allowed_roles else ROLES
    if role not in allowed_roles:
        raise RolloutError(
            f"the {role} rollout role is not allowed here (allowed: {', '.join(allowed_roles)})"
        )

    identity = policy["identities"][ROLE_IDENTITY[role]]
    if version["BUNDLE_ID"] != identity["bundleIdentifier"]:
        raise RolloutError(f"version.env BUNDLE_ID does not match the {ROLE_IDENTITY[role]} identity policy")
    if version["SIGNING_TEAM_ID"] != identity["teamIdentifier"]:
        raise RolloutError(f"version.env SIGNING_TEAM_ID does not match the {ROLE_IDENTITY[role]} identity policy")

    marketing = version["MARKETING_VERSION"]
    build = version["BUILD_NUMBER"]
    app_name = version["APP_NAME"]
    if channel == "stable" and args.release_tag != f"v{marketing}":
        raise RolloutError(f"Stable release tag must be v{marketing}, got {args.release_tag}")
    if channel == "tip" and not args.release_tag.startswith("tip-"):
        raise RolloutError(f"Tip release tag must start with tip-, got {args.release_tag}")
    if args.migration_phase != ROLE_MIGRATION_PHASE[role]:
        raise RolloutError(
            f"migration phase must be {ROLE_MIGRATION_PHASE[role]} for the {role} role, "
            f"got {args.migration_phase}"
        )

    enclosure = Path(args.enclosure)
    expected_name = expected_enclosure_name(
        app_name, marketing, build, role, args.enclosure_basename
    )
    if enclosure.name != expected_name:
        raise RolloutError(f"enclosure must be named {expected_name}, got {enclosure.name}")
    if not args.enclosure_signature.strip():
        raise RolloutError("enclosure EdDSA signature must be nonempty")
    app_artifact_manifest = Path(args.app_artifact_manifest)

    predecessor_manifests = load_predecessor_manifests(
        declaration, args.predecessor_manifest, policy, app_name
    )

    tag = args.release_tag
    current_item = {
        "role": role,
        "tag": tag,
        "url": enclosure_url(update_repository(policy, channel), tag, expected_name),
        "buildNumber": build,
        "marketingVersion": marketing,
        "minimumSystemVersion": policy["sparkle"]["minimumSystemVersion"],
        "minimumUpdateVersion": (
            str(predecessor_manifests[0]["appcastItems"][0]["buildNumber"])
            if predecessor_manifests
            else None
        ),
        "installationType": ROLE_INSTALLATION_TYPE[role],
        "enclosureName": expected_name,
        "enclosureSize": enclosure.stat().st_size,
        "enclosureSha256": sha256_file(enclosure),
        "edSignature": args.enclosure_signature.strip(),
        "rolloutManifestSha256": None,
        "rolloutManifestName": None,
    }
    items = [current_item]
    for entry, manifest in zip(declaration["predecessors"], predecessor_manifests):
        predecessor_item = dict(manifest["appcastItems"][0])
        predecessor_item["rolloutManifestSha256"] = entry["rolloutManifestSha256"]
        predecessor_item["rolloutManifestName"] = rollout_manifest_name(
            app_name,
            str(predecessor_item["marketingVersion"]),
            str(predecessor_item["buildNumber"]),
            channel,
        )
        items.append(predecessor_item)

    for position, item in enumerate(items, start=1):
        validate_item_shape(item, position, policy, app_name, channel)
    validate_item_ladder(items)

    manifest = {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "channel": channel,
        "sourceTag": tag,
        "releaseCommit": args.release_commit,
        "currentRole": role,
        "signingIdentity": ROLE_IDENTITY[role],
        "bundleIdentifier": identity["bundleIdentifier"],
        "teamIdentifier": identity["teamIdentifier"],
        "marketingVersion": marketing,
        "buildNumber": build,
        "migrationPhase": args.migration_phase,
        "eligibilityProfile": declaration["eligibilityProfile"],
        "updateRepository": update_repository(policy, channel),
        "appArtifactManifest": {
            "name": app_artifact_manifest.name,
            "sha256": sha256_file(app_artifact_manifest),
        },
        "appcastItems": items,
    }
    return manifest, render_appcast(manifest)


def build_manifest(args: argparse.Namespace) -> tuple[dict, str]:
    policy = load_policy(Path(args.policy))
    declaration = load_declaration(Path(args.declaration))
    version = load_version_env(Path(args.version_env))
    return build_manifest_from_inputs(args, policy, declaration, version)


def load_verified_tip_context(boundary: str) -> dict:
    script_dir = Path(__file__).resolve().parent
    if str(script_dir) not in sys.path:
        sys.path.insert(0, str(script_dir))
    import tip_release_context as context_tool

    try:
        context, digest, elapsed_ms = context_tool.verify_context_from_environment(
            boundary, str(script_dir.parent)
        )
    except context_tool.TipReleaseContextError as error:
        raise RolloutError(str(error)) from error
    # Consume the verifier's in-memory verified snapshot directly so later
    # filesystem changes cannot swap in an unverified context.
    print(
        context_tool.verification_line(context, digest, boundary, elapsed_ms),
        file=sys.stderr,
    )
    return context


def context_manifest_inputs(
    args: argparse.Namespace, context: dict
) -> tuple[argparse.Namespace, dict, dict, dict[str, str]]:
    rollout = context["rollout"]
    release = context["release"]
    application = context["applicationSigning"]
    sparkle = context["sparkle"]
    publication = context["publication"]
    role = rollout["role"]
    identity_name = rollout["signingIdentity"]
    if ROLE_IDENTITY[role] != identity_name:
        raise RolloutError("Tip context role and signing identity disagree")
    if rollout["runtimeSecureStorageMigrationPhase"] != ROLE_MIGRATION_PHASE[role]:
        raise RolloutError("Tip context role and runtime migration phase disagree")
    if rollout["installationType"] != ROLE_INSTALLATION_TYPE[role]:
        raise RolloutError("Tip context role and installation type disagree")
    if publication["repository"] != sparkle["updateRepository"]:
        raise RolloutError("Tip context publication and Sparkle repositories disagree")
    if publication["tag"] != release["tag"]:
        raise RolloutError("Tip context publication and release tags disagree")

    args.release_tag = release["tag"]
    args.release_commit = release["commit"]
    args.migration_phase = rollout["runtimeSecureStorageMigrationPhase"]
    args.allowed_roles = ",".join(ROLES)
    args.enclosure_basename = release["archiveBasename"]
    policy = {
        "identities": {
            identity_name: {
                "bundleIdentifier": application["bundleIdentifier"],
                "teamIdentifier": application["teamIdentifier"],
            }
        },
        "sparkle": {
            "minimumSystemVersion": sparkle["minimumSystemVersion"],
            "tipUpdateRepository": sparkle["updateRepository"],
        },
    }
    declaration = {
        "channel": rollout["channel"],
        "currentRole": role,
        "eligibilityProfile": rollout["eligibilityProfile"],
        "predecessors": rollout["predecessors"],
    }
    version = {
        "APP_NAME": release["appName"],
        "DISPLAY_NAME": release["displayName"],
        "MARKETING_VERSION": release["marketingVersion"],
        "BUILD_NUMBER": release["buildNumber"],
        "BUNDLE_ID": application["bundleIdentifier"],
        "SIGNING_TEAM_ID": application["teamIdentifier"],
    }
    return args, policy, declaration, version


def build_manifest_from_context(
    args: argparse.Namespace, context: dict
) -> tuple[dict, str]:
    args, policy, declaration, version = context_manifest_inputs(args, context)
    manifest, appcast = build_manifest_from_inputs(args, policy, declaration, version)
    validate_stable_build_below_retained_tip_preparer(context, manifest)
    return manifest, appcast


def validate_stable_build_below_retained_tip_preparer(
    context: dict, manifest: dict
) -> None:
    """Keep Stable builds below P so they cannot satisfy Tip's T hard gate."""
    role = context["rollout"]["role"]
    if role not in {"transition", "successor"}:
        return
    preparers = [
        item for item in manifest["appcastItems"] if item.get("role") == "preparer"
    ]
    if len(preparers) != 1:
        raise RolloutError(
            f"the {role} Tip rollout must retain exactly one preparer item"
        )
    stable_build = str(context["release"]["stableMaximumBuild"])
    preparer_build = str(preparers[0]["buildNumber"])
    if not parse_build(stable_build, "Stable maximum build") < parse_build(
        preparer_build, "retained Tip preparer build"
    ):
        raise RolloutError(
            "Stable maximum build must remain below the retained Tip preparer build: "
            f"Stable={stable_build} preparer={preparer_build}"
        )


def write_generated_outputs(args: argparse.Namespace, manifest: dict, appcast: str) -> None:
    Path(args.manifest_output).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    Path(args.appcast_output).write_text(appcast, encoding="utf-8")
    print(
        f"OK: generated {manifest['channel']} rollout manifest and appcast with "
        f"{len(manifest['appcastItems'])} item(s) for the {manifest['currentRole']} role."
    )


def run_generate(args: argparse.Namespace) -> None:
    if not args.enclosure_signature.strip():
        raise RolloutError("generate requires --enclosure-signature")
    manifest, appcast = build_manifest(args)
    write_generated_outputs(args, manifest, appcast)


def run_generate_from_context(args: argparse.Namespace) -> None:
    if not args.enclosure_signature.strip():
        raise RolloutError("generate-from-context requires --enclosure-signature")
    context = load_verified_tip_context("stable-rollout-generate")
    manifest, appcast = build_manifest_from_context(args, context)
    write_generated_outputs(args, manifest, appcast)


def validate_generated_outputs(
    args: argparse.Namespace, expected_manifest: dict, expected_appcast: str
) -> None:
    actual_manifest_text = Path(args.manifest).read_text(encoding="utf-8")
    expected_manifest_text = json.dumps(expected_manifest, indent=2, sort_keys=True) + "\n"
    if actual_manifest_text != expected_manifest_text:
        actual = load_manifest(Path(args.manifest))
        for key, expected_value in expected_manifest.items():
            if actual.get(key) != expected_value:
                raise RolloutError(
                    f"rollout manifest field {key} mismatch: "
                    f"expected {json.dumps(expected_value, sort_keys=True)}, "
                    f"got {json.dumps(actual.get(key), sort_keys=True)}"
                )
        raise RolloutError("rollout manifest does not match its regenerated projection")
    actual_appcast = Path(args.appcast).read_text(encoding="utf-8")
    if actual_appcast != expected_appcast:
        raise RolloutError("accumulated appcast does not match the generated rollout manifest")
    print(
        f"OK: {expected_manifest['channel']} rollout manifest and appcast validated with "
        f"{len(expected_manifest['appcastItems'])} item(s)."
    )


def run_validate(args: argparse.Namespace) -> None:
    if not args.enclosure_signature:
        actual_items = load_manifest(Path(args.manifest))["appcastItems"]
        args.enclosure_signature = str(actual_items[0].get("edSignature", ""))
    expected_manifest, expected_appcast = build_manifest(args)
    validate_generated_outputs(args, expected_manifest, expected_appcast)


def run_validate_from_context(args: argparse.Namespace) -> None:
    if not args.enclosure_signature:
        actual_items = load_manifest(Path(args.manifest))["appcastItems"]
        args.enclosure_signature = str(actual_items[0].get("edSignature", ""))
    context = load_verified_tip_context("stable-rollout-validate")
    expected_manifest, expected_appcast = build_manifest_from_context(args, context)
    validate_generated_outputs(args, expected_manifest, expected_appcast)


def validate_tip_manifest_appcast(
    context: dict, manifest: dict, appcast: str
) -> dict:
    """Validate one Tip manifest/appcast pair against the immutable context.

    This is the shared structural trust boundary for both predecessor-state
    admission and post-publication byte audits. It intentionally does not
    decide whether the manifest is the predecessor or the candidate; callers
    layer that state-machine decision on top of the same parsed representation.
    """
    if manifest.get("channel") != "tip":
        raise RolloutError("live rollout manifest must describe the Tip channel")
    if manifest.get("updateRepository") != context["sparkle"]["updateRepository"]:
        raise RolloutError("live Tip update repository differs from the candidate context")
    normalized = normalize_manifest_floor_authority(manifest)
    items = normalized.get("appcastItems")
    if not isinstance(items, list) or not items:
        raise RolloutError("live Tip rollout manifest must contain appcast items")
    live_policy = {
        "sparkle": {
            "minimumSystemVersion": context["sparkle"]["minimumSystemVersion"],
            "tipUpdateRepository": context["sparkle"]["updateRepository"],
        }
    }
    for position, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            raise RolloutError(f"live appcast item {position} must be an object")
        validate_item_shape(
            item, position, live_policy, context["release"]["appName"], "tip"
        )
    validate_item_ladder(items)
    try:
        expected_appcast = render_appcast(normalized)
    except (KeyError, TypeError) as error:
        raise RolloutError(f"live Tip rollout manifest cannot render its appcast: {error}") from error
    if expected_appcast != appcast:
        raise RolloutError("live Tip appcast does not match its rollout manifest")
    return normalized


def validate_live_tip_publication_state(
    context: dict,
    live_manifest: dict,
    live_appcast: str,
    live_manifest_sha256: str,
    live_main_commit: str,
) -> None:
    """Fail closed unless a candidate advances the authenticated live Tip ladder."""
    if not re.fullmatch(r"[0-9a-f]{40}", live_main_commit):
        raise RolloutError("live source main commit must be a full lowercase Git SHA")
    if context["release"]["commit"] != live_main_commit:
        raise RolloutError(
            "candidate Tip source commit is stale: "
            f"candidate={context['release']['commit']} live-main={live_main_commit}"
        )
    if not re.fullmatch(r"[0-9a-f]{64}", live_manifest_sha256):
        raise RolloutError("live Tip rollout manifest digest must be a lowercase SHA-256")
    live_manifest = validate_tip_manifest_appcast(context, live_manifest, live_appcast)
    items = live_manifest["appcastItems"]

    live_role = live_manifest.get("currentRole")
    live_item = items[0]
    if live_role != live_item.get("role"):
        raise RolloutError("live rollout manifest role differs from its newest appcast item")
    if live_role not in ROLES:
        raise RolloutError(f"live rollout manifest has unknown role {live_role!r}")
    if live_manifest.get("signingIdentity") != ROLE_IDENTITY[live_role]:
        raise RolloutError("live rollout manifest role and signing identity disagree")
    for manifest_key, item_key in (
        ("sourceTag", "tag"),
        ("buildNumber", "buildNumber"),
        ("marketingVersion", "marketingVersion"),
    ):
        if live_manifest.get(manifest_key) != live_item.get(item_key):
            raise RolloutError(
                f"live rollout manifest {manifest_key} differs from its newest appcast item"
            )
    if not re.fullmatch(r"[0-9a-f]{40}", str(live_manifest.get("releaseCommit", ""))):
        raise RolloutError("live rollout manifest release commit is malformed")
    if live_item.get("rolloutManifestName") is not None or live_item.get(
        "rolloutManifestSha256"
    ) is not None:
        raise RolloutError("live newest appcast item must not refer to itself as a predecessor")

    candidate_build = parse_build(context["release"]["buildNumber"], "candidate Tip build")
    live_build = parse_build(str(live_item["buildNumber"]), "live Tip build")
    if not candidate_build > live_build:
        raise RolloutError(
            "candidate Tip build must be strictly newer than live Tip: "
            f"candidate={context['release']['buildNumber']} live={live_item['buildNumber']}"
        )

    candidate_role = context["rollout"]["role"]
    if live_role == "preparer" and candidate_role == "transition":
        expected_predecessors = [
            {
                "role": "preparer",
                "tag": live_manifest["sourceTag"],
                "rolloutManifestSha256": live_manifest_sha256,
            }
        ]
    elif live_role == "transition" and candidate_role == "successor":
        expected_predecessors = [
            {
                "role": "transition",
                "tag": live_manifest["sourceTag"],
                "rolloutManifestSha256": live_manifest_sha256,
            }
        ]
        retained_items = items[1:]
        if [item.get("role") for item in retained_items] != ["preparer"]:
            raise RolloutError("live transition must retain exactly the preparer predecessor")
        expected_predecessors.extend(
            {
                "role": item["role"],
                "tag": item["tag"],
                "rolloutManifestSha256": item.get("rolloutManifestSha256"),
            }
            for item in retained_items
        )
    elif live_role == "successor" and candidate_role == "successor":
        retained_items = items[1:]
        if [item.get("role") for item in retained_items] != ["transition", "preparer"]:
            raise RolloutError(
                "live successor must retain exactly the transition and preparer predecessors"
            )
        expected_predecessors = [
            {
                "role": item["role"],
                "tag": item["tag"],
                "rolloutManifestSha256": item.get("rolloutManifestSha256"),
            }
            for item in retained_items
        ]
    else:
        raise RolloutError(
            "candidate Tip rollout role would regress or skip the live rollout state: "
            f"live={live_role} candidate={candidate_role}"
        )

    for position, predecessor in enumerate(expected_predecessors, start=1):
        digest = predecessor["rolloutManifestSha256"]
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RolloutError(
                f"live retained predecessor {position} has a malformed rollout manifest digest"
            )
    if context["rollout"]["predecessors"] != expected_predecessors:
        raise RolloutError(
            "candidate Tip predecessor pins do not exactly match the authenticated live history"
        )


def run_validate_live_tip_publication(args: argparse.Namespace) -> None:
    context = load_verified_tip_context("stable-rollout-live-publication")
    manifest_path = Path(args.live_manifest)
    live_manifest = load_manifest(manifest_path)
    try:
        live_appcast = Path(args.live_appcast).read_text(encoding="utf-8")
    except OSError as error:
        raise RolloutError(f"unreadable live Tip appcast: {error}") from error
    validate_live_tip_publication_state(
        context,
        live_manifest,
        live_appcast,
        sha256_file(manifest_path),
        args.live_main_commit,
    )
    print(
        "OK: live Tip publication state permits "
        f"{context['rollout']['role']} {context['release']['tag']} "
        f"build {context['release']['buildNumber']}."
    )


def run_workflow_guard(args: argparse.Namespace) -> None:
    load_policy(Path(args.policy))
    declaration = load_declaration(Path(args.declaration))
    if declaration["channel"] != "stable":
        raise RolloutError("protected Stable workflows require a Stable rollout declaration")
    role = declaration["currentRole"]
    if role not in WORKFLOW_ALLOWED_ROLES:
        raise RolloutError(
            f"protected workflows reject the {role} rollout role until successor rollout enablement"
        )
    if declaration["predecessors"]:
        raise RolloutError(
            "protected workflows reject sibling predecessor publication until successor rollout enablement"
        )
    if declaration["expectedSigningIdentity"] != "legacy":
        raise RolloutError("protected workflows reject the successor signing identity")
    print(f"OK: rollout declaration permits the dormant-safe {role} role with no siblings.")


def run_current_role(args: argparse.Namespace) -> None:
    print(load_declaration(Path(args.declaration))["currentRole"])


def run_feed_url(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    key = "tipFeedURL" if args.channel == "tip" else "stableFeedURL"
    print(policy["sparkle"][key])


def run_packaging_context(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    declaration = load_declaration(Path(args.declaration))
    version = load_version_env(Path(args.version_env))
    role = declaration["currentRole"]
    migration_phase = ROLE_MIGRATION_PHASE[role]
    if (
        args.expected_migration_phase is not None
        and args.expected_migration_phase != migration_phase
    ):
        raise RolloutError(
            "requested identity migration phase does not match the rollout declaration: "
            f"expected {migration_phase}, got {args.expected_migration_phase}"
        )
    identity_name = ROLE_IDENTITY[role]
    identity = policy["identities"][identity_name]
    version_identity_name = identity_name_for_bundle_and_team(
        policy, version["BUNDLE_ID"], version["SIGNING_TEAM_ID"]
    )
    # Stable metadata remains pinned to the currently releasable identity. Tip
    # T/S builds intentionally project the role-selected successor identity
    # without changing the repository-wide Stable/debug defaults mid-rehearsal.
    if declaration["channel"] == "stable" and version_identity_name != identity_name:
        raise RolloutError(
            f"version.env identity does not match the {identity_name} Stable rollout identity"
        )
    package_required = ROLE_INSTALLATION_TYPE[role] == "package"
    installer_identity = identity.get("developerIDInstallerIdentityName", "")
    if package_required:
        validate_identity_transition_package(policy)
        if not installer_identity:
            raise RolloutError(
                f"the {role} rollout role requires a reviewed Developer ID Installer identity"
            )

    migration_anchor_required = role == "preparer"
    migration_anchor = policy["identities"]["successor"] if migration_anchor_required else None
    values = {
        "REPOPROMPT_STABLE_RELEASE_CONTEXT": (
            "stable-rollout-v1" if declaration["channel"] == "stable" else ""
        ),
        "ROLLOUT_CHANNEL": declaration["channel"],
        "ROLLOUT_ROLE": role,
        "ROLLOUT_IDENTITY": identity_name,
        "BUNDLE_ID": identity["bundleIdentifier"],
        "SIGNING_TEAM_ID": identity["teamIdentifier"],
        "REPOPROMPT_IDENTITY_MIGRATION_PHASE": migration_phase,
        "ROLLOUT_INSTALLATION_TYPE": ROLE_INSTALLATION_TYPE[role],
        "ROLLOUT_ENCLOSURE_SUFFIX": ROLE_ENCLOSURE_SUFFIX[role],
        "EXPECTED_APP_BUNDLE_ID": identity["bundleIdentifier"],
        "EXPECTED_APP_TEAM_ID": identity["teamIdentifier"],
        "EXPECTED_APP_REQUIREMENT": identity["developerIDRequirement"],
        "EXPECTED_PROVISIONING_PROFILE_APPLICATION_IDENTIFIER": (
            f"{identity['teamIdentifier']}.{identity['bundleIdentifier']}"
        ),
        "EXPECTED_SIGN_IDENTITY": identity["developerIDApplicationIdentityName"],
        "EXPECTED_SIGNING_MODE": SIGNING_MODE_BY_IDENTITY[identity_name],
        "EXPECTED_INSTALLER_TEAM_ID": identity["teamIdentifier"] if package_required else "",
        "EXPECTED_INSTALLER_IDENTITY": installer_identity if package_required else "",
        "EXPECTED_MIGRATION_ANCHOR_BUNDLE_ID": (
            migration_anchor["bundleIdentifier"] if migration_anchor_required else ""
        ),
        "EXPECTED_MIGRATION_ANCHOR_TEAM_ID": (
            migration_anchor["teamIdentifier"] if migration_anchor_required else ""
        ),
        "EXPECTED_MIGRATION_ANCHOR_REQUIREMENT": (
            migration_anchor["developerIDRequirement"] if migration_anchor_required else ""
        ),
        "EXPECTED_MIGRATION_ANCHOR_SIGN_IDENTITY": (
            migration_anchor["developerIDApplicationIdentityName"]
            if migration_anchor_required
            else ""
        ),
        "ROLLOUT_UPDATE_REPOSITORY": update_repository(policy, declaration["channel"]),
        "ROLLOUT_FEED_URL": policy["sparkle"][
            "tipFeedURL" if declaration["channel"] == "tip" else "stableFeedURL"
        ],
    }
    if args.github_env:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                raise RolloutError(
                    f"packaging context value for {key} cannot contain a newline"
                )
        try:
            with Path(args.github_env).open("a", encoding="utf-8") as handle:
                for key, value in values.items():
                    handle.write(f"{key}={value}\n")
        except OSError as error:
            raise RolloutError(
                f"unable to append the Stable packaging context to {args.github_env}: {error}"
            ) from error
        if args.github_summary:
            try:
                with Path(args.github_summary).open("a", encoding="utf-8") as handle:
                    handle.write("### Stable release identity context\n\n")
                    handle.write(f"- Rollout role: `{role}`\n")
                    handle.write(f"- Migration phase: `{migration_phase}`\n")
                    handle.write(f"- Application bundle identifier: `{identity['bundleIdentifier']}`\n")
                    handle.write(f"- Application Team ID: `{identity['teamIdentifier']}`\n")
                    handle.write(
                        f"- Migration anchor required: `{'yes' if migration_anchor_required else 'no'}`\n"
                    )
            except OSError as error:
                raise RolloutError(
                    f"unable to append the Stable packaging summary to {args.github_summary}: {error}"
                ) from error
        print(
            "OK: resolved Stable release identity context for "
            f"role={role} phase={migration_phase}."
        )
        return
    if args.github_summary:
        raise RolloutError("--github-summary requires --github-env")
    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")


def run_signing_mode(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    identity_name = identity_name_for_bundle_and_team(policy, args.bundle_id, args.team_id)
    print(SIGNING_MODE_BY_IDENTITY[identity_name])


def run_predecessor_values(args: argparse.Namespace) -> None:
    declaration = load_declaration(Path(args.declaration))
    for entry in declaration["predecessors"]:
        print("\t".join((entry["role"], entry["tag"], entry["rolloutManifestSha256"])))


def run_predecessor_values_from_context(_args: argparse.Namespace) -> None:
    context = load_verified_tip_context("stable-rollout-predecessors")
    for entry in context["rollout"]["predecessors"]:
        print("\t".join((entry["role"], entry["tag"], entry["rolloutManifestSha256"])))


def run_signing_mode_from_context(_args: argparse.Namespace) -> None:
    context = load_verified_tip_context("stable-rollout-signing-mode")
    print(SIGNING_MODE_BY_IDENTITY[context["rollout"]["signingIdentity"]])


def max_build_from_appcast(path: Path) -> str:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise RolloutError(f"unparseable appcast XML: {error}") from error
    items = root.findall("./channel/item")
    if not items:
        raise RolloutError("appcast must contain at least one item")
    builds: list[tuple[tuple[int, ...], str]] = []
    for position, item in enumerate(items, start=1):
        versions = item.findall(f"{{{SPARKLE_NAMESPACE}}}version")
        if len(versions) != 1 or not (versions[0].text or "").strip():
            raise RolloutError(f"appcast item {position} must contain exactly one sparkle:version")
        raw = (versions[0].text or "").strip()
        builds.append((parse_build(raw, f"item {position} build"), raw))
    return max(builds)[1]


def run_max_build(args: argparse.Namespace) -> None:
    print(max_build_from_appcast(Path(args.appcast)))


def run_sibling_values(args: argparse.Namespace) -> None:
    manifest = load_manifest(Path(args.manifest))
    for position, item in enumerate(manifest["appcastItems"][1:], start=2):
        print(
            "\t".join(
                str(value)
                for value in (
                    position,
                    item["role"],
                    item["tag"],
                    item["url"],
                    item["enclosureSize"],
                    item["enclosureSha256"],
                    item["edSignature"],
                    item["rolloutManifestName"],
                    item["rolloutManifestSha256"],
                )
            )
        )


def add_shared_generate_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--declaration", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--version-env", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--release-commit", required=True)
    parser.add_argument("--migration-phase", required=True)
    parser.add_argument("--enclosure", required=True)
    parser.add_argument("--enclosure-signature", default="")
    parser.add_argument("--app-artifact-manifest", required=True)
    parser.add_argument("--predecessor-manifest", action="append", default=[])
    parser.add_argument("--allowed-roles")
    parser.add_argument("--enclosure-basename")


def add_context_generate_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--enclosure", required=True)
    parser.add_argument("--enclosure-signature", default="")
    parser.add_argument("--app-artifact-manifest", required=True)
    parser.add_argument("--predecessor-manifest", action="append", default=[])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    guard = subparsers.add_parser("workflow-guard")
    guard.add_argument("--declaration", required=True)
    guard.add_argument("--policy", required=True)
    guard.set_defaults(func=run_workflow_guard)

    current_role = subparsers.add_parser("current-role")
    current_role.add_argument("--declaration", required=True)
    current_role.set_defaults(func=run_current_role)

    feed_url = subparsers.add_parser("feed-url")
    feed_url.add_argument("--policy", required=True)
    feed_url.add_argument("--channel", required=True, choices=CHANNELS)
    feed_url.set_defaults(func=run_feed_url)

    packaging_context = subparsers.add_parser("packaging-context")
    packaging_context.add_argument("--declaration", required=True)
    packaging_context.add_argument("--policy", required=True)
    packaging_context.add_argument("--version-env", required=True)
    packaging_context.add_argument(
        "--expected-migration-phase",
        choices=("disabled", "legacy-preparer"),
    )
    packaging_context.add_argument("--github-env")
    packaging_context.add_argument("--github-summary")
    packaging_context.set_defaults(func=run_packaging_context)

    signing_mode = subparsers.add_parser("signing-mode")
    signing_mode.add_argument("--policy", required=True)
    signing_mode.add_argument("--bundle-id", required=True)
    signing_mode.add_argument("--team-id", required=True)
    signing_mode.set_defaults(func=run_signing_mode)

    predecessor_values = subparsers.add_parser("predecessor-values")
    predecessor_values.add_argument("--declaration", required=True)
    predecessor_values.set_defaults(func=run_predecessor_values)

    predecessor_values_from_context = subparsers.add_parser(
        "predecessor-values-from-context"
    )
    predecessor_values_from_context.set_defaults(func=run_predecessor_values_from_context)

    signing_mode_from_context = subparsers.add_parser("signing-mode-from-context")
    signing_mode_from_context.set_defaults(func=run_signing_mode_from_context)

    generate = subparsers.add_parser("generate")
    add_shared_generate_arguments(generate)
    generate.add_argument("--appcast-output", required=True)
    generate.add_argument("--manifest-output", required=True)
    generate.set_defaults(func=run_generate)

    validate = subparsers.add_parser("validate")
    add_shared_generate_arguments(validate)
    validate.add_argument("--appcast", required=True)
    validate.add_argument("--manifest", required=True)
    validate.set_defaults(func=run_validate)

    generate_from_context = subparsers.add_parser("generate-from-context")
    add_context_generate_arguments(generate_from_context)
    generate_from_context.add_argument("--appcast-output", required=True)
    generate_from_context.add_argument("--manifest-output", required=True)
    generate_from_context.set_defaults(func=run_generate_from_context)

    validate_from_context = subparsers.add_parser("validate-from-context")
    add_context_generate_arguments(validate_from_context)
    validate_from_context.add_argument("--appcast", required=True)
    validate_from_context.add_argument("--manifest", required=True)
    validate_from_context.set_defaults(func=run_validate_from_context)

    validate_live = subparsers.add_parser("validate-live-tip-publication")
    validate_live.add_argument("--live-main-commit", required=True)
    validate_live.add_argument("--live-manifest", required=True)
    validate_live.add_argument("--live-appcast", required=True)
    validate_live.set_defaults(func=run_validate_live_tip_publication)

    max_build = subparsers.add_parser("max-build")
    max_build.add_argument("--appcast", required=True)
    max_build.set_defaults(func=run_max_build)

    sibling_values = subparsers.add_parser("sibling-values")
    sibling_values.add_argument("--manifest", required=True)
    sibling_values.set_defaults(func=run_sibling_values)

    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except RolloutError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
