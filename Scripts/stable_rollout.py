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
- ``feed-url``: print the policy-owned feed URL for one channel.
- ``packaging-context``: emit policy-derived bundle, team, application, and installer identity labels.
- ``signing-mode``: map one reviewed bundle/team pair to its runtime signing marker.
- ``generate``: assemble the accumulated appcast plus rollout manifest.
- ``validate``: prove a reviewed appcast/manifest pair against the declaration,
  policy, version metadata, and enclosure/app-manifest digests.
- ``validate-live-tip-progression``: prove the candidate rolls or advances the
  authenticated public Tip ladder without skipping or rewriting retained history.
- ``validate-stable-tip-floor``: keep Stable builds below the retained preparer so
  an unprepared Stable client cannot satisfy the transition hard gate.
- ``max-build``: greatest Sparkle build in an appcast (monotonicity input).
- ``sibling-values``: TSV projection of predecessor items for shell loops.

EdDSA signing/verification stays in shell (sign_update /
verify_sparkle_signature.swift); publication stays in the protected workflows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Release helpers import this module from clean trusted checkouts. Never leave
# an untracked __pycache__ behind in the control plane.
sys.dont_write_bytecode = True

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ROLLOUT_NAMESPACE = "https://repoprompt.com/xml-namespaces/rollout"
DECLARATION_SCHEMA_VERSION = 1
TIP_DECLARATION_SCHEMA_VERSION = 2
RESET_AUTHORITY_TYPE = "transition-to-replacement-preparer-v1"
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
TIP_RESET_DECLARATION_KEYS = DECLARATION_KEYS | {"resetAuthority"}
RESET_AUTHORITY_KEYS = {"type", "liveTip", "stableEpoch", "retainedPreparer"}
RESET_LIVE_TIP_KEYS = {"role", "tag", "buildNumber", "rolloutManifestSha256"}
RESET_STABLE_EPOCH_KEYS = {"marketingVersion", "buildNumber"}
RESET_RETAINED_PREPARER_KEYS = {"role", "tag", "buildNumber", "rolloutManifestSha256"}
PREDECESSOR_KEYS = {"role", "tag", "rolloutManifestSha256"}
MANIFEST_KEYS = {
    "schemaVersion",
    "channel",
    "sourceTag",
    "releaseCommit",
    "currentRole",
    "signingIdentity",
    "bundleIdentifier",
    "teamIdentifier",
    "marketingVersion",
    "buildNumber",
    "migrationPhase",
    "eligibilityProfile",
    "updateRepository",
    "appArtifactManifest",
    "appcastItems",
}
APPCAST_ITEM_KEYS = {
    "role",
    "tag",
    "url",
    "buildNumber",
    "marketingVersion",
    "minimumSystemVersion",
    "minimumUpdateVersion",
    "installationType",
    "enclosureName",
    "enclosureSize",
    "enclosureSha256",
    "edSignature",
    "rolloutManifestSha256",
    "rolloutManifestName",
}


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
    """Validate package-only policy without coupling application releases to it."""
    transition_package = policy.get("identityTransitionPackage")
    if (
        not isinstance(transition_package, dict)
        or set(transition_package) != IDENTITY_TRANSITION_PACKAGE_KEYS
    ):
        raise RolloutError(
            "apple identity policy transition package keys must be exactly "
            + ", ".join(sorted(IDENTITY_TRANSITION_PACKAGE_KEYS))
        )
    for key in ("identifier", "installLocation", "appBundleName", "bundleOverwriteAction"):
        if not isinstance(transition_package.get(key), str) or not transition_package[key]:
            raise RolloutError("apple identity policy transition package strings must be nonempty")
    if not re.fullmatch(
        r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", transition_package["identifier"]
    ):
        raise RolloutError("apple identity policy transition package identifier must be reverse-DNS")
    app_bundle_name = transition_package["appBundleName"]
    if Path(app_bundle_name).name != app_bundle_name or not app_bundle_name.endswith(".app"):
        raise RolloutError(
            "apple identity policy transition package appBundleName must be one app basename"
        )
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


def validate_reset_authority_shape(declaration: dict) -> None:
    authority = declaration.get("resetAuthority")
    if authority is None:
        return
    if declaration["channel"] != "tip":
        raise RolloutError("resetAuthority is only supported for the Tip channel")
    if declaration["currentRole"] != "preparer":
        raise RolloutError("resetAuthority requires the preparer rollout role")
    if declaration["expectedMigrationPhase"] != "legacy-preparer":
        raise RolloutError("resetAuthority requires the legacy-preparer migration phase")
    if declaration["expectedSigningIdentity"] != "legacy":
        raise RolloutError("resetAuthority requires the legacy signing identity")
    if declaration["predecessors"] != []:
        raise RolloutError("resetAuthority requires no declared predecessors")
    if not isinstance(authority, dict) or set(authority) != RESET_AUTHORITY_KEYS:
        raise RolloutError(
            "resetAuthority keys must be exactly "
            + ", ".join(sorted(RESET_AUTHORITY_KEYS))
        )
    if authority["type"] != RESET_AUTHORITY_TYPE:
        raise RolloutError(f"resetAuthority type must be {RESET_AUTHORITY_TYPE}")

    entries = (
        ("liveTip", authority["liveTip"], RESET_LIVE_TIP_KEYS, "transition"),
        ("retainedPreparer", authority["retainedPreparer"], RESET_RETAINED_PREPARER_KEYS, "preparer"),
    )
    for label, entry, expected_keys, expected_role in entries:
        if not isinstance(entry, dict) or set(entry) != expected_keys:
            raise RolloutError(
                f"resetAuthority {label} keys must be exactly "
                + ", ".join(sorted(expected_keys))
            )
        if entry["role"] != expected_role:
            raise RolloutError(
                f"resetAuthority {label} role must be {expected_role}"
            )
        if not isinstance(entry["tag"], str) or not re.fullmatch(
            r"tip-[0-9a-f]{12}", entry["tag"]
        ):
            raise RolloutError(f"resetAuthority {label} tag must be tip-<12 lowercase hex>")
        if not isinstance(entry["buildNumber"], str):
            raise RolloutError(f"resetAuthority {label} buildNumber must be a string")
        parse_build(entry["buildNumber"], f"resetAuthority {label} build number")
        if not isinstance(entry["rolloutManifestSha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", entry["rolloutManifestSha256"]
        ):
            raise RolloutError(
                f"resetAuthority {label} rolloutManifestSha256 must be lowercase hex sha256"
            )

    stable_epoch = authority["stableEpoch"]
    if not isinstance(stable_epoch, dict) or set(stable_epoch) != RESET_STABLE_EPOCH_KEYS:
        raise RolloutError(
            "resetAuthority stableEpoch keys must be exactly "
            + ", ".join(sorted(RESET_STABLE_EPOCH_KEYS))
        )
    if not isinstance(stable_epoch["marketingVersion"], str) or not stable_epoch["marketingVersion"]:
        raise RolloutError("resetAuthority stableEpoch marketingVersion must be nonempty")
    if not isinstance(stable_epoch["buildNumber"], str):
        raise RolloutError("resetAuthority stableEpoch buildNumber must be a string")
    parse_build(stable_epoch["buildNumber"], "resetAuthority Stable epoch build number")


def load_declaration(path: Path) -> dict:
    declaration = load_json(path, "rollout declaration")
    schema_version = declaration.get("schemaVersion")
    if schema_version == DECLARATION_SCHEMA_VERSION:
        expected_keys = DECLARATION_KEYS
    elif schema_version == TIP_DECLARATION_SCHEMA_VERSION:
        expected_keys = TIP_RESET_DECLARATION_KEYS
    else:
        raise RolloutError("rollout declaration schema version mismatch")
    if set(declaration) != expected_keys:
        raise RolloutError(
            "rollout declaration keys must be exactly "
            + ", ".join(sorted(expected_keys))
        )
    if schema_version == TIP_DECLARATION_SCHEMA_VERSION and declaration.get("channel") != "tip":
        raise RolloutError("rollout declaration schema version 2 is only supported for Tip")
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
    if schema_version == TIP_DECLARATION_SCHEMA_VERSION:
        validate_reset_authority_shape(declaration)
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
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
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
    """Accept only the authenticated public P manifest's historical null-floor shape."""
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
            # Older supported Sparkle clients still read the historical projection.
            # It is generated from the hard floor; it is never an independent authority.
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


def build_manifest(args: argparse.Namespace) -> tuple[dict, str]:
    policy = load_policy(Path(args.policy))
    declaration = load_declaration(Path(args.declaration))
    version = load_version_env(Path(args.version_env))
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


def run_generate(args: argparse.Namespace) -> None:
    if not args.enclosure_signature.strip():
        raise RolloutError("generate requires --enclosure-signature")
    manifest, appcast = build_manifest(args)
    Path(args.manifest_output).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    Path(args.appcast_output).write_text(appcast, encoding="utf-8")
    print(
        f"OK: generated {manifest['channel']} rollout manifest and appcast with {len(manifest['appcastItems'])} "
        f"item(s) for the {manifest['currentRole']} role."
    )


def run_validate(args: argparse.Namespace) -> None:
    if not args.enclosure_signature:
        # The reviewed manifest carries the published signature; shell callers
        # separately prove it with the protected private key.
        actual_items = load_manifest(Path(args.manifest))["appcastItems"]
        args.enclosure_signature = str(actual_items[0].get("edSignature", ""))
    expected_manifest, expected_appcast = build_manifest(args)
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


def validate_tip_manifest_pair(
    policy: dict,
    manifest_path: Path,
    appcast_path: Path,
    label: str,
) -> dict:
    manifest = normalize_manifest_floor_authority(load_manifest(manifest_path))
    if set(manifest) != MANIFEST_KEYS:
        raise RolloutError(
            f"{label} rollout manifest keys must be exactly "
            + ", ".join(sorted(MANIFEST_KEYS))
        )
    if manifest.get("channel") != "tip":
        raise RolloutError(f"{label} rollout manifest must describe the Tip channel")
    if manifest.get("updateRepository") != update_repository(policy, "tip"):
        raise RolloutError(f"{label} Tip update repository differs from policy")

    role = manifest.get("currentRole")
    if role not in ROLES:
        raise RolloutError(f"{label} rollout manifest has unknown role {role!r}")
    identity_name = ROLE_IDENTITY[role]
    identity = policy["identities"][identity_name]
    if manifest.get("signingIdentity") != identity_name:
        raise RolloutError(f"{label} rollout role and signing identity disagree")
    if manifest.get("bundleIdentifier") != identity["bundleIdentifier"]:
        raise RolloutError(f"{label} rollout bundle identifier differs from policy")
    if manifest.get("teamIdentifier") != identity["teamIdentifier"]:
        raise RolloutError(f"{label} rollout Team ID differs from policy")
    if manifest.get("migrationPhase") != ROLE_MIGRATION_PHASE[role]:
        raise RolloutError(f"{label} rollout role and migration phase disagree")
    if not isinstance(manifest.get("eligibilityProfile"), str) or not manifest["eligibilityProfile"]:
        raise RolloutError(f"{label} rollout eligibility profile must be nonempty")
    if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("releaseCommit", ""))):
        raise RolloutError(f"{label} rollout release commit must be a full lowercase Git SHA")

    app_artifact_manifest = manifest.get("appArtifactManifest")
    if not isinstance(app_artifact_manifest, dict) or set(app_artifact_manifest) != {"name", "sha256"}:
        raise RolloutError(f"{label} rollout app artifact manifest binding is malformed")
    if not isinstance(app_artifact_manifest["name"], str) or not app_artifact_manifest["name"]:
        raise RolloutError(f"{label} rollout app artifact manifest name is missing")
    if not re.fullmatch(r"[0-9a-f]{64}", str(app_artifact_manifest["sha256"])):
        raise RolloutError(f"{label} rollout app artifact manifest digest is malformed")

    items = manifest["appcastItems"]
    for position, item in enumerate(items, start=1):
        if set(item) != APPCAST_ITEM_KEYS:
            raise RolloutError(
                f"{label} appcast item {position} keys must be exactly "
                + ", ".join(sorted(APPCAST_ITEM_KEYS))
            )
        validate_item_shape(item, position, policy, "RepoPrompt", "tip")
        if position == 1:
            if item["rolloutManifestName"] is not None or item["rolloutManifestSha256"] is not None:
                raise RolloutError(f"{label} newest appcast item must not refer to itself")
        else:
            if item["rolloutManifestName"] != "identity-rollout.json":
                raise RolloutError(f"{label} retained item {position} has the wrong manifest name")
            if not re.fullmatch(r"[0-9a-f]{64}", str(item["rolloutManifestSha256"])):
                raise RolloutError(f"{label} retained item {position} has a malformed manifest digest")
    validate_item_ladder(items)

    newest = items[0]
    for manifest_key, item_key in (
        ("sourceTag", "tag"),
        ("currentRole", "role"),
        ("marketingVersion", "marketingVersion"),
        ("buildNumber", "buildNumber"),
    ):
        if manifest.get(manifest_key) != newest.get(item_key):
            raise RolloutError(
                f"{label} rollout manifest {manifest_key} differs from its newest appcast item"
            )

    try:
        appcast = appcast_path.read_text(encoding="utf-8")
    except OSError as error:
        raise RolloutError(f"unreadable {label} Tip appcast at {appcast_path}: {error}") from error
    if render_appcast(manifest) != appcast:
        raise RolloutError(f"{label} Tip appcast does not match its rollout manifest")
    return manifest


def expected_retained_history(live: dict, live_digest: str, candidate_role: str) -> list[dict]:
    live_role = live["currentRole"]
    live_items = live["appcastItems"]
    if live_role == candidate_role:
        allowed_chain = next(chain for chain in ALLOWED_ROLE_CHAINS if chain[0] == live_role)
        retained_roles = tuple(item["role"] for item in live_items[1:])
        if retained_roles != allowed_chain[1:]:
            expected = ", ".join(allowed_chain[1:]) or "no"
            raise RolloutError(
                f"live {live_role} must retain exactly {expected} predecessors"
            )
        return live_items[1:]
    if live_role == "preparer" and candidate_role == "transition":
        newest = dict(live_items[0])
        newest["rolloutManifestName"] = "identity-rollout.json"
        newest["rolloutManifestSha256"] = live_digest
        return [newest]
    if live_role == "transition" and candidate_role == "successor":
        if [item["role"] for item in live_items[1:]] != ["preparer"]:
            raise RolloutError("live transition must retain exactly the preparer predecessor")
        newest = dict(live_items[0])
        newest["rolloutManifestName"] = "identity-rollout.json"
        newest["rolloutManifestSha256"] = live_digest
        return [newest, *live_items[1:]]
    raise RolloutError(
        "candidate Tip rollout role would regress or skip the live rollout state: "
        f"live={live_role} candidate={candidate_role}"
    )


def validate_explicit_tip_reset(
    declaration: dict,
    candidate: dict,
    live: dict,
    live_manifest_path: Path,
    stable_epoch: dict[str, str],
) -> None:
    authority = declaration.get("resetAuthority")
    if authority is None:
        raise RolloutError(
            "transition -> preparer requires an explicit checked-in resetAuthority"
        )
    for declaration_key, manifest_key in (
        ("currentRole", "currentRole"),
        ("expectedSigningIdentity", "signingIdentity"),
        ("expectedMigrationPhase", "migrationPhase"),
        ("eligibilityProfile", "eligibilityProfile"),
    ):
        if declaration[declaration_key] != candidate[manifest_key]:
            raise RolloutError(
                "reset candidate does not match its checked-in rollout declaration: "
                f"{declaration_key}={declaration[declaration_key]!r} "
                f"manifest={candidate[manifest_key]!r}"
            )
    if candidate["currentRole"] != "preparer" or len(candidate["appcastItems"]) != 1:
        raise RolloutError(
            "reset candidate must be a single-item replacement preparer rollout"
        )

    live_tip = authority["liveTip"]
    live_manifest_digest = sha256_file(live_manifest_path)
    if live_manifest_digest != live_tip["rolloutManifestSha256"]:
        raise RolloutError(
            "reset authorization live Tip manifest digest mismatch: "
            f"expected {live_tip['rolloutManifestSha256']} got {live_manifest_digest}"
        )
    for authority_key, live_key in (("role", "currentRole"), ("tag", "sourceTag"), ("buildNumber", "buildNumber")):
        if live_tip[authority_key] != live[live_key]:
            raise RolloutError(
                "reset authorization live Tip "
                f"{authority_key} mismatch: expected {live_tip[authority_key]!r} "
                f"got {live[live_key]!r}"
            )

    if [item["role"] for item in live["appcastItems"]] != ["transition", "preparer"]:
        raise RolloutError(
            "reset authorization requires the live transition to retain exactly one preparer"
        )
    retained = live["appcastItems"][1]
    authorized_preparer = authority["retainedPreparer"]
    for key in ("role", "tag", "buildNumber", "rolloutManifestSha256"):
        if authorized_preparer[key] != retained[key]:
            raise RolloutError(
                "reset authorization retained preparer "
                f"{key} mismatch: expected {authorized_preparer[key]!r} got {retained[key]!r}"
            )

    authorized_epoch = authority["stableEpoch"]
    for key in ("marketingVersion", "buildNumber"):
        if authorized_epoch[key] != stable_epoch[key]:
            raise RolloutError(
                "reset authorization Stable epoch "
                f"{key} mismatch: expected {authorized_epoch[key]!r} got {stable_epoch[key]!r}"
            )

    stable_build = parse_build(stable_epoch["buildNumber"], "Stable maximum build")
    retained_build = parse_build(
        authorized_preparer["buildNumber"], "authorized retained preparer build"
    )
    if stable_build < retained_build:
        raise RolloutError(
            "reset authorization is only valid after the retained preparer falls below "
            f"the Stable epoch: Stable={stable_epoch['buildNumber']} "
            f"preparer={authorized_preparer['buildNumber']}"
        )
    if candidate["marketingVersion"] != authorized_epoch["marketingVersion"]:
        raise RolloutError(
            "replacement preparer marketingVersion must match the authorized Stable epoch: "
            f"candidate={candidate['marketingVersion']} "
            f"Stable={authorized_epoch['marketingVersion']}"
        )

    candidate_build = parse_build(candidate["buildNumber"], "candidate Tip build")
    live_build = parse_build(live["buildNumber"], "live Tip build")
    if not candidate_build > live_build or not candidate_build > stable_build:
        raise RolloutError(
            "replacement preparer build must be newer than both live Tip and Stable: "
            f"candidate={candidate['buildNumber']} live Tip={live['buildNumber']} "
            f"Stable={stable_epoch['buildNumber']}"
        )
    print(
        "OK: explicit Tip reset authorized for live transition "
        f"{live_tip['tag']} ({live_tip['buildNumber']}), replacing retained preparer "
        f"{authorized_preparer['tag']} ({authorized_preparer['buildNumber']}) "
        f"for Stable {authorized_epoch['marketingVersion']} ({authorized_epoch['buildNumber']}) "
        f"with replacement preparer {candidate['buildNumber']}."
    )


def run_validate_live_tip_progression(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    candidate_manifest_path = Path(args.candidate_manifest)
    candidate_appcast_path = Path(args.candidate_appcast)
    candidate = validate_tip_manifest_pair(
        policy, candidate_manifest_path, candidate_appcast_path, "candidate"
    )

    if bool(args.live_manifest) != bool(args.live_appcast):
        raise RolloutError("--live-manifest and --live-appcast must be supplied together")
    if bool(args.declaration) != bool(args.stable_appcast):
        raise RolloutError("--declaration and --stable-appcast must be supplied together")
    if not args.live_manifest:
        if candidate["currentRole"] not in {"legacy", "preparer"} or len(candidate["appcastItems"]) != 1:
            raise RolloutError(
                "the first public Tip rollout must be a single-item legacy or preparer release"
            )
        print(
            "OK: no public Tip rollout exists; candidate may establish "
            f"the {candidate['currentRole']} baseline."
        )
        return

    live_manifest_path = Path(args.live_manifest)
    live_appcast_path = Path(args.live_appcast)
    live = validate_tip_manifest_pair(policy, live_manifest_path, live_appcast_path, "live")
    live_digest = sha256_file(live_manifest_path)
    candidate_digest = sha256_file(candidate_manifest_path)

    if candidate["sourceTag"] == live["sourceTag"]:
        if candidate_digest != live_digest or candidate_appcast_path.read_bytes() != live_appcast_path.read_bytes():
            raise RolloutError(
                "the public Tip release uses the candidate tag with different manifest or appcast bytes"
            )
        print(f"OK: public Tip rollout already matches candidate {candidate['sourceTag']} exactly.")
        return

    candidate_build = parse_build(candidate["buildNumber"], "candidate Tip build")
    live_build = parse_build(live["buildNumber"], "live Tip build")
    if not candidate_build > live_build:
        raise RolloutError(
            "candidate Tip build must be strictly newer than live Tip: "
            f"candidate={candidate['buildNumber']} live={live['buildNumber']}"
        )

    if live["currentRole"] == "transition" and candidate["currentRole"] == "preparer":
        if args.declaration:
            declaration = load_declaration(Path(args.declaration))
            stable_epoch = stable_epoch_from_appcast(Path(args.stable_appcast))
            validate_explicit_tip_reset(
                declaration, candidate, live, live_manifest_path, stable_epoch
            )
            return

    expected = expected_retained_history(live, live_digest, candidate["currentRole"])
    actual = candidate["appcastItems"][1:]
    if actual != expected:
        raise RolloutError(
            "candidate Tip retained items do not exactly match the authenticated live history"
        )
    print(
        "OK: candidate Tip rollout safely advances "
        f"{live['currentRole']} -> {candidate['currentRole']} with exact retained history."
    )


def run_feed_url(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    key = "tipFeedURL" if args.channel == "tip" else "stableFeedURL"
    print(policy["sparkle"][key])


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


def stable_epoch_from_appcast(path: Path) -> dict[str, str]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise RolloutError(f"unparseable appcast XML at {path}: {error}") from error
    items = root.findall("./channel/item")
    if not items:
        raise RolloutError("appcast must contain at least one item")

    builds: list[tuple[tuple[int, ...], str, str]] = []
    for position, item in enumerate(items, start=1):
        versions = item.findall(f"{{{SPARKLE_NAMESPACE}}}version")
        if len(versions) != 1 or not (versions[0].text or "").strip():
            raise RolloutError(f"appcast item {position} must contain exactly one sparkle:version")
        marketing_versions = item.findall(
            f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
        )
        if len(marketing_versions) != 1 or not (marketing_versions[0].text or "").strip():
            raise RolloutError(
                f"appcast item {position} must contain exactly one sparkle:shortVersionString"
            )
        raw_build = (versions[0].text or "").strip()
        marketing_version = (marketing_versions[0].text or "").strip()
        builds.append(
            (parse_build(raw_build, f"item {position} build"), raw_build, marketing_version)
        )

    maximum_build = max(build[0] for build in builds)
    maximums = [build for build in builds if build[0] == maximum_build]
    if len(maximums) != 1:
        raise RolloutError("Stable appcast maximum build must be unique")
    _, raw_build, marketing_version = maximums[0]
    return {"marketingVersion": marketing_version, "buildNumber": raw_build}


def max_build_from_appcast(path: Path) -> str:
    return stable_epoch_from_appcast(path)["buildNumber"]


def run_max_build(args: argparse.Namespace) -> None:
    print(max_build_from_appcast(Path(args.appcast)))


def run_validate_stable_tip_floor(args: argparse.Namespace) -> None:
    policy = load_policy(Path(args.policy))
    manifest = validate_tip_manifest_pair(
        policy,
        Path(args.tip_manifest),
        Path(args.tip_appcast),
        "Tip floor",
    )
    role = manifest["currentRole"]
    if role in {"legacy", "preparer"}:
        print(f"OK: the {role} Tip role does not require a retained preparer floor.")
        return

    preparers = [item for item in manifest["appcastItems"] if item["role"] == "preparer"]
    if len(preparers) != 1:
        raise RolloutError(f"the {role} Tip rollout must retain exactly one preparer item")
    stable_build = max_build_from_appcast(Path(args.stable_appcast))
    preparer_build = str(preparers[0]["buildNumber"])
    if not parse_build(stable_build, "Stable maximum build") < parse_build(
        preparer_build, "retained Tip preparer build"
    ):
        raise RolloutError(
            "Stable maximum build must remain below the retained Tip preparer build: "
            f"Stable={stable_build} preparer={preparer_build}"
        )
    print(
        "OK: Stable maximum build remains below the retained Tip preparer: "
        f"Stable={stable_build} preparer={preparer_build}."
    )


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

    live_progression = subparsers.add_parser("validate-live-tip-progression")
    live_progression.add_argument("--policy", required=True)
    live_progression.add_argument("--candidate-manifest", required=True)
    live_progression.add_argument("--candidate-appcast", required=True)
    live_progression.add_argument("--live-manifest")
    live_progression.add_argument("--live-appcast")
    live_progression.add_argument("--declaration")
    live_progression.add_argument("--stable-appcast")
    live_progression.set_defaults(func=run_validate_live_tip_progression)

    stable_floor = subparsers.add_parser("validate-stable-tip-floor")
    stable_floor.add_argument("--policy", required=True)
    stable_floor.add_argument("--stable-appcast", required=True)
    stable_floor.add_argument("--tip-manifest", required=True)
    stable_floor.add_argument("--tip-appcast", required=True)
    stable_floor.set_defaults(func=run_validate_stable_tip_floor)

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
