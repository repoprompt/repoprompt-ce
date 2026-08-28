#!/usr/bin/env bash
set -euo pipefail

# Build or validate the one-time installer enclosure used to replace the legacy
# bundle/team identity. Policy owns every public identity and package setting;
# secrets provide signing material only.

MODE="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${REPOPROMPT_APPLE_IDENTITY_POLICY:-$SCRIPT_DIR/apple_identity_policy.json}"
TMP_DIR=""

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_file() { [[ -f "$1" && ! -L "$1" ]] || fail "Missing regular non-symlink file: $1"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[[ "${REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG:-}" == "1" ]] ||
    fail "identity transition package construction requires explicit Tip rollout enablement"
require_file "$POLICY"
require_command python3

# Closed, shell-safe projection of the reviewed policy. The package builder has
# no identity literals and cannot be redirected by workflow variables.
eval "$(python3 - "$POLICY" <<'PYTHON'
import json
import re
import shlex
import sys
from pathlib import Path

policy = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if policy.get("schemaVersion") != 1:
    raise SystemExit("ERROR: apple identity policy schema version mismatch")
successor = policy.get("identities", {}).get("successor")
sparkle = policy.get("sparkle")
package = policy.get("identityTransitionPackage")
if not isinstance(successor, dict) or not isinstance(sparkle, dict) or not isinstance(package, dict):
    raise SystemExit("ERROR: apple identity policy is missing transition settings")
package_keys = {
    "identifier", "installLocation", "appBundleName", "bundleIsRelocatable",
    "bundleHasStrictIdentifier", "bundleIsVersionChecked", "bundleOverwriteAction",
    "hasScripts", "applicationBundleCount",
}
if set(package) != package_keys:
    raise SystemExit("ERROR: apple identity policy transition package schema mismatch")
required = {
    "SUCCESSOR_BUNDLE_IDENTIFIER": successor.get("bundleIdentifier"),
    "SUCCESSOR_TEAM_IDENTIFIER": successor.get("teamIdentifier"),
    "SUCCESSOR_APP_REQUIREMENT": successor.get("developerIDRequirement"),
    "SUCCESSOR_INSTALLER_IDENTITY": successor.get("developerIDInstallerIdentityName"),
    "TRANSITION_PKG_IDENTIFIER": package.get("identifier"),
    "TRANSITION_INSTALL_LOCATION": package.get("installLocation"),
    "DISTRIBUTION_APP_BUNDLE_NAME": package.get("appBundleName"),
    "EXPECTED_FEED_URL": sparkle.get("stableFeedURL"),
}
if not all(isinstance(value, str) and value for value in required.values()):
    raise SystemExit("ERROR: apple identity policy has incomplete transition strings")
expected = {
    "bundleIsRelocatable": False,
    "bundleHasStrictIdentifier": False,
    "bundleIsVersionChecked": True,
    "bundleOverwriteAction": "upgrade",
    "hasScripts": False,
    "applicationBundleCount": 1,
}
for key, value in expected.items():
    if package.get(key) != value:
        raise SystemExit(f"ERROR: unsupported transition package policy: {key}")
if package["installLocation"] != "/Applications":
    raise SystemExit("ERROR: transition package must install into /Applications")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", package["identifier"]):
    raise SystemExit("ERROR: transition package identifier must be reverse-DNS")
for key, value in required.items():
    print(f"{key}={shlex.quote(value)}")
PYTHON
)"

validate_successor_app() {
    local app="$1" label="$2"
    [[ -d "$app" && ! -L "$app" ]] || fail "$label app bundle does not exist as a real directory: $app"
    require_file "$app/Contents/Info.plist"
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign --verify --strict --verbose=2 -R="$SUCCESSOR_APP_REQUIREMENT" "$app"

    local signature_details identifier team_identifier bundle_identifier feed_url public_key
    signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
    identifier="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "Identifier" { print $2; exit }')"
    team_identifier="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' ||
        fail "$label app is not signed with Developer ID Application"
    [[ "$identifier" == "$SUCCESSOR_BUNDLE_IDENTIFIER" ]] ||
        fail "$label app identifier mismatch: expected $SUCCESSOR_BUNDLE_IDENTIFIER, got ${identifier:-<missing>}"
    [[ "$team_identifier" == "$SUCCESSOR_TEAM_IDENTIFIER" ]] ||
        fail "$label app team mismatch: expected $SUCCESSOR_TEAM_IDENTIFIER, got ${team_identifier:-<missing>}"

    bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"
    feed_url="$(plutil -extract SUFeedURL raw "$app/Contents/Info.plist")"
    public_key="$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist")"
    [[ "$bundle_identifier" == "$SUCCESSOR_BUNDLE_IDENTIFIER" ]] ||
        fail "$label CFBundleIdentifier mismatch"
    [[ "$feed_url" == "$EXPECTED_FEED_URL" ]] ||
        fail "$label must retain the Stable feed URL"
    [[ -n "$public_key" ]] || fail "$label is missing SUPublicEDKey"
}

write_component_plist() {
    local output="$1"
    python3 - "$output" "$DISTRIBUTION_APP_BUNDLE_NAME" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

output, bundle_name = sys.argv[1:]
value = [{
    "RootRelativeBundlePath": bundle_name,
    "BundleIsRelocatable": False,
    "BundleHasStrictIdentifier": False,
    "BundleIsVersionChecked": True,
    "BundleOverwriteAction": "upgrade",
}]
Path(output).write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False))
PYTHON
    plutil -lint "$output"
}

validate_component_plist() {
    local path="$1"
    python3 - "$path" "$DISTRIBUTION_APP_BUNDLE_NAME" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

value = plistlib.loads(Path(sys.argv[1]).read_bytes())
expected = [{
    "RootRelativeBundlePath": sys.argv[2],
    "BundleIsRelocatable": False,
    "BundleHasStrictIdentifier": False,
    "BundleIsVersionChecked": True,
    "BundleOverwriteAction": "upgrade",
}]
if value != expected:
    raise SystemExit("ERROR: transition component plist differs from the deterministic contract")
PYTHON
}

validate_package_info() {
    local package_info="$1" expected_version="$2"
    python3 - "$package_info" "$TRANSITION_PKG_IDENTIFIER" "$TRANSITION_INSTALL_LOCATION" \
        "$DISTRIBUTION_APP_BUNDLE_NAME" "$SUCCESSOR_BUNDLE_IDENTIFIER" "$expected_version" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

path, package_id, install_location, bundle_name, bundle_id, expected_version = sys.argv[1:]
root = ET.parse(Path(path)).getroot()
if root.tag != "pkg-info":
    raise SystemExit("ERROR: transition PackageInfo root must be pkg-info")
if root.get("identifier") != package_id:
    raise SystemExit("ERROR: transition package identifier mismatch")
if root.get("install-location") != install_location:
    raise SystemExit("ERROR: transition package install location mismatch")
if root.get("version") != expected_version:
    raise SystemExit("ERROR: transition package version mismatch")
if root.get("relocatable") != "false":
    raise SystemExit("ERROR: transition package must be non-relocatable")
if root.get("postinstall-action") not in {None, "none"}:
    raise SystemExit("ERROR: transition package must not request a postinstall action")
if root.findall("scripts") or root.findall("./scripts/*"):
    raise SystemExit("ERROR: transition package must be script-free")

bundles = root.findall("bundle")
if len(bundles) != 1:
    raise SystemExit("ERROR: transition PackageInfo must contain exactly one top-level bundle")
bundle = bundles[0]
if bundle.get("id") != bundle_id:
    raise SystemExit("ERROR: transition payload bundle identifier mismatch")
path_value = bundle.get("path", "")
if path_value not in {bundle_name, f"./{bundle_name}"}:
    raise SystemExit("ERROR: transition payload bundle path mismatch")

# pkgbuild emits an empty <relocate/> even for a non-relocatable component.
# Empty is safe; any child rule or true-ish attribute is not.
for relocate in root.findall("relocate"):
    if list(relocate) or any(value.lower() not in {"", "false", "0"} for value in relocate.attrib.values()):
        raise SystemExit("ERROR: transition package contains active relocation rules")
PYTHON
}

build_transition_pkg() {
    local app="" output="" installer_identity=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app="$2"; shift 2 ;;
            --output) output="$2"; shift 2 ;;
            --installer-identity) installer_identity="$2"; shift 2 ;;
            *) fail "Unknown build argument: $1" ;;
        esac
    done
    [[ -n "$app" && -n "$output" && -n "$installer_identity" ]] ||
        fail "Usage: $0 build --app <successor.app> --output <transition.pkg> --installer-identity <identity>"
    [[ "$installer_identity" == "$SUCCESSOR_INSTALLER_IDENTITY" ]] ||
        fail "Transition Installer identity must match the reviewed policy"
    [[ ! -e "$output" && ! -L "$output" ]] || fail "Refusing to overwrite transition package: $output"
    for command in codesign diff ditto pkgbuild pkgutil plutil productbuild productsign xcrun; do
        require_command "$command"
    done
    validate_successor_app "$app" "Transition payload input"
    [[ -n "${NOTARYTOOL_PRIVATE_KEY:-}" && -n "${NOTARYTOOL_KEY_ID:-}" && -n "${NOTARYTOOL_ISSUER_ID:-}" ]] ||
        fail "Transition package notarization credentials are incomplete"
    require_file "$NOTARYTOOL_PRIVATE_KEY"

    TMP_DIR="$(mktemp -d)"
    local payload_root="$TMP_DIR/payload-root"
    local component_plist="$TMP_DIR/component.plist"
    local component_pkg="$TMP_DIR/transition-component.pkg"
    local unsigned_product="$TMP_DIR/transition-unsigned.pkg"
    local signed_product="$TMP_DIR/transition-signed.pkg"
    mkdir -p "$payload_root"
    ditto "$app" "$payload_root/$DISTRIBUTION_APP_BUNDLE_NAME"
    write_component_plist "$component_plist"
    validate_component_plist "$component_plist"

    local payload_build
    payload_build="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
    [[ "$payload_build" =~ ^[0-9]{1,4}(\.[0-9]{1,2}){0,2}$ ]] ||
        fail "Transition payload has an invalid CFBundleVersion: $payload_build"

    pkgbuild \
        --root "$payload_root" \
        --component-plist "$component_plist" \
        --identifier "$TRANSITION_PKG_IDENTIFIER" \
        --version "$payload_build" \
        --install-location "$TRANSITION_INSTALL_LOCATION" \
        "$component_pkg"
    productbuild --package "$component_pkg" "$unsigned_product"
    productsign --sign "$installer_identity" "$unsigned_product" "$signed_product"

    xcrun notarytool submit "$signed_product" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait --timeout "${NOTARYTOOL_TIMEOUT:-30m}"
    xcrun stapler staple "$signed_product"
    validate_transition_pkg "$signed_product" --expected-app "$app"
    [[ -d "$(dirname "$output")" && ! -L "$(dirname "$output")" ]] ||
        fail "Transition package output parent must be a real directory"
    mv "$signed_product" "$output"
    printf 'OK: created identity-transition package: %s\n' "$output"
}

validate_transition_pkg() {
    local pkg="$1"; shift
    local expanded_payload_dir="" expected_app=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expanded-payload-dir) expanded_payload_dir="$2"; shift 2 ;;
            --expected-app) expected_app="$2"; shift 2 ;;
            *) fail "Unknown validate argument: $1" ;;
        esac
    done
    for command in codesign ditto pkgutil plutil xcrun; do require_command "$command"; done
    require_file "$pkg"

    local signature_details
    signature_details="$(pkgutil --check-signature "$pkg")"
    printf '%s\n' "$signature_details" | grep -F "$SUCCESSOR_INSTALLER_IDENTITY" >/dev/null ||
        fail "Transition package Installer identity mismatch"
    printf '%s\n' "$signature_details" | grep -F "($SUCCESSOR_TEAM_IDENTIFIER)" >/dev/null ||
        fail "Transition package Installer Team ID mismatch"
    xcrun stapler validate "$pkg"

    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"
    local expand_dir="$TMP_DIR/transition-expand"
    rm -rf "$expand_dir"
    pkgutil --expand-full "$pkg" "$expand_dir"

    local package_info payload_app payload_build
    local package_info_list="$TMP_DIR/package-info-list"
    local payload_app_list="$TMP_DIR/payload-app-list"
    find "$expand_dir" -name PackageInfo -type f -print > "$package_info_list"
    [[ "$(awk 'END { print NR + 0 }' "$package_info_list")" == "1" ]] ||
        fail "Transition package must contain exactly one PackageInfo"
    IFS= read -r package_info < "$package_info_list"
    find "$expand_dir" -type d -name "$DISTRIBUTION_APP_BUNDLE_NAME" -print > "$payload_app_list"
    [[ "$(awk 'END { print NR + 0 }' "$payload_app_list")" == "1" ]] ||
        fail "Transition package must contain exactly one $DISTRIBUTION_APP_BUNDLE_NAME"
    IFS= read -r payload_app < "$payload_app_list"
    validate_successor_app "$payload_app" "Transition payload"
    payload_build="$(plutil -extract CFBundleVersion raw "$payload_app/Contents/Info.plist")"
    validate_package_info "$package_info" "$payload_build"

    if [[ -n "$expected_app" ]]; then
        diff -qr "$expected_app" "$payload_app" >/dev/null ||
            fail "Transition package payload does not byte-match the signed input app"
    fi
    if [[ -n "$expanded_payload_dir" ]]; then
        [[ ! -e "$expanded_payload_dir/$DISTRIBUTION_APP_BUNDLE_NAME" ]] ||
            fail "Refusing to overwrite expanded transition payload"
        mkdir -p "$expanded_payload_dir"
        ditto "$payload_app" "$expanded_payload_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    fi
    printf 'OK: transition package validated: %s\n' "$pkg"
}

case "$MODE" in
    build) build_transition_pkg "$@" ;;
    validate)
        [[ $# -ge 1 ]] || fail "Usage: $0 validate <transition.pkg> [--expected-app <app>] [--expanded-payload-dir <dir>]"
        pkg_path="$1"; shift
        validate_transition_pkg "$pkg_path" "$@"
        ;;
    *) fail "Usage: $0 build|validate ..." ;;
esac
