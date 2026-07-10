#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-stage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$SCRIPT_DIR}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
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
FINAL_ARTIFACT_MANIFEST="$DIST_DIR/$ARCHIVE_BASENAME-artifact-manifest.json"
FINAL_METADATA="$DIST_DIR/$ARCHIVE_BASENAME-metadata.json"
STAGE_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-stage.zip"
STAGE_ARCHIVE_CHECKSUM="$STAGE_ARCHIVE.sha256"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
TMP_DIR=""

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
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
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    "$CONTROL_PLANE_SCRIPTS_DIR/release.sh" preflight
    validate_packaged_legal "$APP_BUNDLE"
    validate_public_app "$APP_BUNDLE" "$BUILD_ARTIFACT_MANIFEST" "Tip staging"

    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/tip-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
    cp "$BUILD_ARTIFACT_MANIFEST" "$stage_root/.build/release/$APP_NAME-artifact-manifest.json"
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

sign_tip() {
    require_command ditto
    require_command hdiutil
    require_command shasum
    require_command xcrun
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env SPARKLE_PRIVATE_KEY
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env RELEASE_COMMIT
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    [[ "$RELEASE_COMMIT" == "$TIP_COMMIT" ]] || fail "RELEASE_COMMIT must match TIP_COMMIT"
    [[ -d "$APP_BUNDLE" ]] || fail "Missing staged tip app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
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
    write_tip_metadata
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final tip Developer ID app"

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

case "$MODE" in
    stage) stage_tip ;;
    sign) sign_tip ;;
    publish-tip) publish_tip ;;
    *) fail "Usage: $0 stage|sign|publish-tip" ;;
esac
