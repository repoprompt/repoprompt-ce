#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-stage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$SCRIPT_DIR}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
APPROVED_SOURCE_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-$ROOT_DIR}"
CODEX_MANIFEST="$APPROVED_SOURCE_ROOT/Vendor/Codex/manifest.json"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
source "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"
load_release_metadata "$ROOT_DIR"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TIP_COMMIT="${TIP_COMMIT:-$(git rev-parse HEAD)}"
TIP_SHORT_SHA="${TIP_SHORT_SHA:-${TIP_COMMIT:0:12}}"
if [[ -z "${TIP_BUILD_NUMBER:-}" ]]; then
    TIP_BUILD_SEQUENCE="${TIP_BUILD_SEQUENCE:-$(git rev-list --count "$TIP_COMMIT")}"
    TIP_BUILD_SEQUENCE="${TIP_BUILD_SEQUENCE//[[:space:]]/}"
    [[ "$TIP_BUILD_SEQUENCE" =~ ^[0-9]+$ ]] || fail "TIP_BUILD_SEQUENCE must be numeric"
    (( TIP_BUILD_SEQUENCE <= 9999 )) || fail "TIP_BUILD_SEQUENCE must not exceed 9999"
    TIP_BUILD_NUMBER="$BUILD_NUMBER.$((TIP_BUILD_SEQUENCE / 100)).$((TIP_BUILD_SEQUENCE % 100))"
fi
TIP_BUILD_NUMBER="${TIP_BUILD_NUMBER//[[:space:]]/}"
TIP_TAG="${TIP_TAG:-tip-$TIP_SHORT_SHA}"
TIP_UPDATE_REPOSITORY="${TIP_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-tip-updates}"
TIP_DOWNLOAD_URL_PREFIX="${TIP_DOWNLOAD_URL_PREFIX:-https://github.com/$TIP_UPDATE_REPOSITORY/releases/download/$TIP_TAG/}"
TIP_GH_TOKEN="${TIP_GH_TOKEN:-${GH_TOKEN:-}}"

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
ARCHIVE_BASENAME="$APP_NAME-tip-$TIP_SHORT_SHA-$TIP_BUILD_NUMBER"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
APPCAST="$DIST_DIR/appcast.xml"
CHECKSUMS="$DIST_DIR/SHA256SUMS"
BUILD_ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"
FINAL_ARTIFACT_MANIFEST="$DIST_DIR/$ARCHIVE_BASENAME-artifact-manifest.json"
FINAL_METADATA="$DIST_DIR/$ARCHIVE_BASENAME-metadata.json"
STAGE_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-stage.zip"
STAGE_ARCHIVE_CHECKSUM="$STAGE_ARCHIVE.sha256"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
SIGN_UPDATE="$TRUSTED_ROOT/Vendor/Sparkle/bin/sign_update"
TMP_DIR=""

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
require_file() { [[ -f "$1" ]] || fail "Missing required file: $1"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT

prepare_dist() {
    [[ "$DIST_DIR" != "/" ]] || fail "DIST_DIR must not be /"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
}

write_tip_version_env() {
    local output="$1"
    cat > "$output" <<VERSION_ENV
APP_NAME=$APP_NAME
DISPLAY_NAME="$DISPLAY_NAME"
MARKETING_VERSION=$MARKETING_VERSION
BUILD_NUMBER=$TIP_BUILD_NUMBER
BUNDLE_ID=$BUNDLE_ID
SIGNING_TEAM_ID=$SIGNING_TEAM_ID
VERSION_ENV
}

validate_public_app() {
    local app_bundle="$1"
    local manifest="$2"
    local label="$3"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$app_bundle" "$label MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$app_bundle" "arm64,x86_64" "$label architectures"
    python3 "$CONTROL_PLANE_SCRIPTS_DIR/codex_runtime_artifact.py" \
        --manifest "$CODEX_MANIFEST" verify-bundle \
        --arch all \
        --bundle "$app_bundle/Contents/Resources/BundledRuntimes/Codex"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" verify \
        --app "$app_bundle" \
        --manifest "$manifest" \
        --expected-architectures "arm64,x86_64"
}

validate_distribution_zip() {
    local archive="$1"
    local manifest="$2"
    local label="$3"
    local extract_dir="$TMP_DIR/${label//[^A-Za-z0-9]/-}-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    ditto -x -k "$archive" "$extract_dir"
    local extracted_app="$extract_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    [[ -d "$extracted_app" ]] || fail "$label ZIP must contain $DISTRIBUTION_APP_BUNDLE_NAME at its root"
    validate_public_app "$extracted_app" "$manifest" "$label extracted app"
}

resolve_without_lockfile_drift() {
    require_command cmp
    require_command swift

    local before_lockfile
    before_lockfile="$(mktemp)"
    cp "$ROOT_DIR/Package.resolved" "$before_lockfile"
    "$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve
    cmp "$before_lockfile" "$ROOT_DIR/Package.resolved" ||
        fail "swift package resolve changed Package.resolved; commit the intentional lockfile update before packaging"
    rm -f "$before_lockfile"
}

validate_packaged_legal() {
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_packaged_legal.sh" "$1"
}

write_tip_metadata() {
    cat > "$FINAL_METADATA" <<JSON
{"commit":"$TIP_COMMIT","short_sha":"$TIP_SHORT_SHA","tag":"$TIP_TAG","marketing_version":"$MARKETING_VERSION","build_number":"$TIP_BUILD_NUMBER"}
JSON
}

require_tip_sentry_configuration() {
    release_sentry_linking_enabled ||
        fail "Official Tip signing requires REPOPROMPT_ENABLE_SENTRY=1"
    require_env SENTRY_DSN
    require_env REPOPROMPT_SENTRY_AUTH_TOKEN_FILE
    require_file "$REPOPROMPT_SENTRY_AUTH_TOKEN_FILE"
    [[ -s "$REPOPROMPT_SENTRY_AUTH_TOKEN_FILE" ]] || fail "Tip Sentry auth token file must not be empty"
    require_env REPOPROMPT_SENTRY_ORG
    require_env REPOPROMPT_SENTRY_PROJECT
    require_command sentry-cli
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh"
}

assert_tip_manifest_telemetry_enabled() {
    python3 - "$FINAL_ARTIFACT_MANIFEST" <<'PYTHON'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("bundle", {}).get("telemetry_enabled") is not True:
    raise SystemExit("ERROR: final Tip artifact manifest must record telemetry_enabled=true")
PYTHON
}

stage_tip() {
    require_command ditto
    require_command git
    require_command shasum
    [[ "$TIP_BUILD_NUMBER" =~ ^[0-9]{1,4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] ||
        fail "TIP_BUILD_NUMBER must be a three-component numeric build version"
    resolve_without_lockfile_drift
    "$CONTROL_PLANE_SCRIPTS_DIR/release.sh" preflight
    prepare_dist
    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        MARKETING_VERSION="$MARKETING_VERSION" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_ENABLE_SENTRY=1 \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    "$CONTROL_PLANE_SCRIPTS_DIR/release.sh" preflight
    validate_packaged_legal "$APP_BUNDLE"
    validate_public_app "$APP_BUNDLE" "$BUILD_ARTIFACT_MANIFEST" "Tip staging"
    REPOPROMPT_ENABLE_SENTRY=1 require_release_sentry_symbols_when_enabled \
        "$SENTRY_SYMBOLS_DIR" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"

    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/tip-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
    cp "$BUILD_ARTIFACT_MANIFEST" "$stage_root/.build/release/$APP_NAME-artifact-manifest.json"
    REPOPROMPT_ENABLE_SENTRY=1 stage_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$stage_root/.build/sentry-symbols/release" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    write_tip_version_env "$stage_root/version.env"
    cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$stage_root/"
    cp -R "$ROOT_DIR/ThirdPartyLicenses" "$stage_root/"
    printf '%s\n' "$TIP_COMMIT" > "$stage_root/RELEASE_COMMIT"
    write_tip_metadata
    ditto -c -k --norsrc "$stage_root" "$STAGE_ARCHIVE"
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$STAGE_ARCHIVE")" > "$(basename "$STAGE_ARCHIVE_CHECKSUM")")
    printf 'OK: staged tip build %s (%s) for %s.\n' "$TIP_TAG" "$TIP_BUILD_NUMBER" "$TIP_COMMIT"
}

submit_notarization() {
    xcrun notarytool submit "$1" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait \
        --timeout "${NOTARYTOOL_TIMEOUT:-30m}"
}

derive_sparkle_public_key() {
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift" "$1"
}

label_generated_tip_appcast() {
    python3 - "$APPCAST" "$MARKETING_VERSION" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
tree = ET.parse(sys.argv[1])
root = tree.getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"tip appcast must contain exactly one item, got {len(items)}")

item = items[0]
display_version = f"Tip build v{sys.argv[2]}"

titles = item.findall("title")
if len(titles) > 1:
    raise SystemExit(f"tip appcast item must contain at most one title, got {len(titles)}")
title = titles[0] if titles else ET.SubElement(item, "title")
title.text = display_version

short_versions = item.findall(f"{{{sparkle}}}shortVersionString")
if len(short_versions) > 1:
    raise SystemExit(
        f"tip appcast item must contain at most one sparkle:shortVersionString, got {len(short_versions)}"
    )
short_version = (
    short_versions[0]
    if short_versions
    else ET.SubElement(item, f"{{{sparkle}}}shortVersionString")
)
short_version.text = display_version

tree.write(sys.argv[1], encoding="utf-8", xml_declaration=True)
PYTHON
}

validate_generated_tip_appcast() {
    local appcast_values="$TMP_DIR/tip-appcast-values.tsv"
    python3 - "$APPCAST" > "$appcast_values" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"tip appcast must contain exactly one item, got {len(items)}")
enclosures = items[0].findall("enclosure")
if len(enclosures) != 1:
    raise SystemExit(f"tip appcast item must contain exactly one enclosure, got {len(enclosures)}")
item = items[0]
enclosure = enclosures[0]
titles = item.findall("title")
versions = item.findall(f"{{{sparkle}}}version")
short_versions = item.findall(f"{{{sparkle}}}shortVersionString")
if len(titles) != 1:
    raise SystemExit(f"tip appcast item must contain exactly one title, got {len(titles)}")
if len(versions) != 1:
    raise SystemExit(
        f"tip appcast item must contain exactly one sparkle:version, got {len(versions)}"
    )
if len(short_versions) != 1:
    raise SystemExit(
        "tip appcast item must contain exactly one "
        f"sparkle:shortVersionString, got {len(short_versions)}"
    )
values = [
    titles[0].text or "",
    enclosure.attrib.get("url", ""),
    enclosure.attrib.get(f"{{{sparkle}}}edSignature", ""),
    enclosure.attrib.get("length", ""),
    versions[0].text or "",
    short_versions[0].text or "",
]
print("\x1f".join(values))
PYTHON

    local appcast_title enclosure_url enclosure_signature enclosure_length appcast_build appcast_marketing
    IFS=$'\x1f' read -r appcast_title enclosure_url enclosure_signature enclosure_length appcast_build appcast_marketing < "$appcast_values"
    [[ "$appcast_title" == "Tip build v$MARKETING_VERSION" ]] ||
        fail "Tip appcast title mismatch: expected Tip build v$MARKETING_VERSION, got $appcast_title"
    [[ "$enclosure_url" == "$TIP_DOWNLOAD_URL_PREFIX$(basename "$UPDATE_ZIP")" ]] ||
        fail "Tip appcast enclosure URL mismatch: $enclosure_url"
    [[ -n "$enclosure_signature" ]] || fail "Tip appcast enclosure is missing an EdDSA signature"
    [[ "$enclosure_length" == "$(stat -f %z "$UPDATE_ZIP")" ]] ||
        fail "Tip appcast enclosure length does not match $(basename "$UPDATE_ZIP")"
    [[ "$appcast_build" == "$TIP_BUILD_NUMBER" ]] ||
        fail "Tip appcast build mismatch: expected $TIP_BUILD_NUMBER, got $appcast_build"
    [[ "$appcast_marketing" == "Tip build v$MARKETING_VERSION" ]] ||
        fail "Tip appcast display version mismatch: expected Tip build v$MARKETING_VERSION, got $appcast_marketing"

    local private_key_file="$TMP_DIR/tip-sparkle-private-key"
    local public_key_file="$TMP_DIR/tip-sparkle-public-key"
    umask 077
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$private_key_file"

    local derived_public_key committed_public_key reproduced_signature
    derived_public_key="$(derive_sparkle_public_key "$private_key_file")"
    committed_public_key="$(plutil -extract SUPublicEDKey raw "$APP_BUNDLE/Contents/Info.plist")"
    [[ "$derived_public_key" == "$committed_public_key" ]] ||
        fail "Tip Sparkle private key does not match the app bundle SUPublicEDKey"
    reproduced_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$UPDATE_ZIP" |
        tr -d '\r\n')"
    [[ "$reproduced_signature" == "$enclosure_signature" ]] ||
        fail "Tip Sparkle private key does not reproduce the generated appcast signature"

    printf '%s' "$committed_public_key" > "$public_key_file"
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift" \
        "$public_key_file" "$enclosure_signature" "$UPDATE_ZIP"
}

sign_tip() {
    require_command ditto
    require_command hdiutil
    require_command plutil
    require_command python3
    require_command shasum
    require_command stat
    require_command xcrun
    require_file "$SIGN_UPDATE"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env SPARKLE_PRIVATE_KEY
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env RELEASE_COMMIT
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_tip_sentry_configuration
    [[ "$RELEASE_COMMIT" == "$TIP_COMMIT" ]] || fail "RELEASE_COMMIT must match TIP_COMMIT"
    [[ -d "$APP_BUNDLE" ]] || fail "Missing staged tip app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    verify_release_sentry_symbol_uuids_before_signing \
        "$SENTRY_SYMBOLS_DIR" \
        "$APP_BUNDLE" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    prepare_dist
    TMP_DIR="$(mktemp -d)"
    local notary_zip="$TMP_DIR/$ARCHIVE_BASENAME-notarization.zip"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$notary_zip"
    submit_notarization "$notary_zip"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" write \
        --app "$APP_BUNDLE" \
        --output "$FINAL_ARTIFACT_MANIFEST" \
        --expected-architectures "arm64,x86_64"
    assert_tip_manifest_telemetry_enabled
    write_tip_metadata
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final tip Developer ID app"
    upload_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"

    local distribution_dir="$TMP_DIR/distribution"
    mkdir -p "$distribution_dir"
    ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    ditto -c -k --norsrc --keepParent "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
    validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Final tip distribution"
    hdiutil create -volname "$DISPLAY_NAME Tip" -srcfolder "$distribution_dir" -ov -format UDZO "$DMG"
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    local appcast_dir="$TMP_DIR/appcast"
    mkdir -p "$appcast_dir"
    cp "$UPDATE_ZIP" "$appcast_dir/"
    printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$TRUSTED_ROOT/Vendor/Sparkle/bin/generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "$TIP_DOWNLOAD_URL_PREFIX" \
            -o "$APPCAST" \
            "$appcast_dir"
    label_generated_tip_appcast
    validate_generated_tip_appcast
    (cd "$DIST_DIR" && shasum -a 256 \
        "$(basename "$UPDATE_ZIP")" \
        "$(basename "$DMG")" \
        "$(basename "$APPCAST")" \
        "$(basename "$FINAL_ARTIFACT_MANIFEST")" \
        "$(basename "$FINAL_METADATA")" \
        > "$(basename "$CHECKSUMS")")
    printf 'OK: signed and notarized tip artifact %s.\n' "$TIP_TAG"
}

publish_tip() {
    require_command gh
    require_env TIP_GH_TOKEN
    case "$TIP_UPDATE_REPOSITORY" in
        repoprompt/repoprompt-ce|repoprompt/repoprompt-ce-updates)
            fail "TIP_UPDATE_REPOSITORY must not target the source or stable update repository"
            ;;
    esac
    for path in "$UPDATE_ZIP" "$DMG" "$APPCAST" "$CHECKSUMS" "$FINAL_ARTIFACT_MANIFEST" "$FINAL_METADATA"; do
        [[ -f "$path" ]] || fail "Missing tip publish asset: $path"
    done
    GH_TOKEN="$TIP_GH_TOKEN" gh release create "$TIP_TAG" \
        "$UPDATE_ZIP" \
        "$DMG" \
        "$APPCAST" \
        "$CHECKSUMS" \
        "$FINAL_ARTIFACT_MANIFEST" \
        "$FINAL_METADATA" \
        --repo "$TIP_UPDATE_REPOSITORY" \
        --target main \
        --latest \
        --title "$DISPLAY_NAME Tip $TIP_SHORT_SHA" \
        --notes "Tip build from main commit \`$TIP_COMMIT\` with build number \`$TIP_BUILD_NUMBER\`."
    printf 'OK: published tip update release %s to %s.\n' "$TIP_TAG" "$TIP_UPDATE_REPOSITORY"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        stage) stage_tip ;;
        sign) sign_tip ;;
        publish-tip) publish_tip ;;
        *) fail "Usage: $0 stage|sign|publish-tip" ;;
    esac
fi
