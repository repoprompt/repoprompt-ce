#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-promote}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"

SOURCE_GITHUB_REPOSITORY="${SOURCE_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-repoprompt/repoprompt-ce}}"
PUBLIC_UPDATE_REPOSITORY="${PUBLIC_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-updates}"
RELEASE_TAG="${RELEASE_TAG:-}"
SOURCE_GH_TOKEN="${SOURCE_GH_TOKEN:-${GH_TOKEN:-}}"
PUBLIC_UPDATE_GH_TOKEN="${PUBLIC_UPDATE_GH_TOKEN:-}"
REVIEWED_CHECKSUMS_SHA256="${REVIEWED_CHECKSUMS_SHA256:-}"
ARCHIVE_BASENAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}"
SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"
SENTRY_DEPLOY_ENVIRONMENT="${REPOPROMPT_SENTRY_DEPLOY_ENVIRONMENT:-production}"
SENTRY_API_BASE_URL="${REPOPROMPT_SENTRY_API_BASE_URL:-https://sentry.io/api/0}"
DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
UPDATE_ZIP_NAME="$ARCHIVE_BASENAME.zip"
DMG_NAME="$ARCHIVE_BASENAME.dmg"
APPCAST_NAME="appcast.xml"
CHECKSUMS_NAME="SHA256SUMS"
ARTIFACT_MANIFEST_NAME="$ARCHIVE_BASENAME-artifact-manifest.json"
PUBLIC_UPDATE_BASE_URL="https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$RELEASE_TAG"
PUBLIC_FEED_URL="https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/latest/download/$APPCAST_NAME"
SOURCE_RELEASE_BASE_URL="https://github.com/$SOURCE_GITHUB_REPOSITORY/releases/download/$RELEASE_TAG"
SIGN_UPDATE="${SIGN_UPDATE:-$TRUSTED_ROOT/Vendor/Sparkle/bin/sign_update}"
TMP_DIR=""
DMG_MOUNT_POINT=""
SOURCE_RELEASE_ASSET_SNAPSHOT=""
SOURCE_RELEASE_WAS_DRAFT=""
UPDATE_RELEASE_STATE=""
UPDATE_RELEASE_ASSET_SNAPSHOT=""
SENTRY_CURL_CONFIG=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

validate_embedded_mcp_helper_layout() {
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$@"
}

require_env() {
    [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"
}

require_release_tag_matches_metadata() {
    [[ "$RELEASE_TAG" == "v$MARKETING_VERSION" ]] ||
        fail "Release tag must match release metadata: expected v$MARKETING_VERSION, got ${RELEASE_TAG:-<missing>}"
}

cleanup() {
    if [[ -n "$DMG_MOUNT_POINT" ]]; then
        hdiutil detach "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

prepare_sentry_api_access() {
    require_env REPOPROMPT_SENTRY_ORG
    require_env REPOPROMPT_SENTRY_PROJECT
    local token="${SENTRY_AUTH_TOKEN:-}"
    if [[ -z "$token" ]]; then
        local token_file="${REPOPROMPT_SENTRY_AUTH_TOKEN_FILE:-${SENTRY_AUTH_TOKEN_FILE:-}}"
        [[ -n "$token_file" ]] || fail "Missing Sentry auth token file for stable promotion"
        [[ -f "$token_file" ]] || fail "Sentry auth token file does not exist: $token_file"
        token="$(tr -d '\r\n' < "$token_file")"
    fi
    [[ -n "$token" ]] || fail "Sentry auth token is empty"
    [[ -n "$TMP_DIR" ]] || fail "Sentry API access requires verified promotion state"

    SENTRY_CURL_CONFIG="$TMP_DIR/sentry-curl.conf"
    (
        umask 077
        printf 'header = "Authorization: Bearer %s"\n' "$token" > "$SENTRY_CURL_CONFIG"
    )
    chmod 600 "$SENTRY_CURL_CONFIG"
    unset SENTRY_AUTH_TOKEN
}

sentry_deploy_endpoint() {
    local encoded_org encoded_release
    encoded_org="$(jq -rn --arg value "$REPOPROMPT_SENTRY_ORG" '$value | @uri')"
    encoded_release="$(jq -rn --arg value "$SENTRY_RELEASE_NAME" '$value | @uri')"
    printf '%s/organizations/%s/releases/%s/deploys/' \
        "${SENTRY_API_BASE_URL%/}" "$encoded_org" "$encoded_release"
}

sentry_api_request() {
    local method="$1"
    local output_file="$2"
    local body_file="${3:-}"
    local args=(
        --silent
        --show-error
        --output "$output_file"
        --write-out '%{http_code}'
        --request "$method"
        --config "$SENTRY_CURL_CONFIG"
        --header 'Accept: application/json'
    )
    if [[ -n "$body_file" ]]; then
        args+=(--header 'Content-Type: application/json' --data-binary "@$body_file")
    fi

    local status
    status="$(curl "${args[@]}" "$(sentry_deploy_endpoint)")" ||
        fail "Unable to call the Sentry deploy API"
    if [[ "$status" == "403" ]]; then
        fail "Sentry deploy API rejected the organization token (HTTP 403); verify org:ci access to $REPOPROMPT_SENTRY_ORG/$REPOPROMPT_SENTRY_PROJECT"
    fi
    [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
        fail "Sentry deploy API request failed with HTTP $status"
}

list_matching_sentry_deploys() {
    local output_file="$1"
    sentry_api_request GET "$output_file"
    jq -e '
        type == "array" and
        all(.[]; has("environment") and (.environment | type == "string") and
            has("name") and ((.name == null) or (.name | type == "string")))
    ' "$output_file" >/dev/null ||
        fail "Sentry deploy API returned malformed JSON"
    jq -r \
        --arg environment "$SENTRY_DEPLOY_ENVIRONMENT" \
        --arg name "$RELEASE_TAG" \
        '[.[] | select(.environment == $environment and .name == $name)] | length' \
        "$output_file"
}

preflight_sentry_deploy_access() {
    prepare_sentry_api_access
    local matches
    matches="$(list_matching_sentry_deploys "$TMP_DIR/sentry-deploy-preflight.json")"
    [[ "$matches" =~ ^[0-9]+$ ]] || fail "Unable to count existing Sentry deploys"
    printf 'OK: Sentry deploy access verified for %s.\n' "$SENTRY_RELEASE_NAME"
}

record_verified_sentry_deploy_if_needed() {
    local matches
    matches="$(list_matching_sentry_deploys "$TMP_DIR/sentry-deploy-record.json")"
    [[ "$matches" =~ ^[0-9]+$ ]] || fail "Unable to count existing Sentry deploys"
    if (( matches > 0 )); then
        printf 'OK: Sentry production deploy already recorded for %s.\n' "$RELEASE_TAG"
        return
    fi

    local body_file="$TMP_DIR/sentry-deploy-create.json"
    jq -n \
        --arg environment "$SENTRY_DEPLOY_ENVIRONMENT" \
        --arg name "$RELEASE_TAG" \
        --arg project "$REPOPROMPT_SENTRY_PROJECT" \
        '{environment: $environment, name: $name, projects: [$project]}' > "$body_file"
    chmod 600 "$body_file"
    sentry_api_request POST "$TMP_DIR/sentry-deploy-created.json" "$body_file"
    jq -e \
        --arg environment "$SENTRY_DEPLOY_ENVIRONMENT" \
        --arg name "$RELEASE_TAG" \
        '.environment == $environment and .name == $name' \
        "$TMP_DIR/sentry-deploy-created.json" >/dev/null ||
        fail "Sentry deploy API returned a malformed create response"
    printf 'OK: recorded Sentry production deploy for %s.\n' "$RELEASE_TAG"
}

source_gh() {
    GH_TOKEN="$SOURCE_GH_TOKEN" gh "$@"
}

update_gh() {
    GH_TOKEN="$PUBLIC_UPDATE_GH_TOKEN" gh "$@"
}

curl_anonymous() {
    env -u GH_TOKEN -u GITHUB_TOKEN curl \
        --fail \
        --location \
        --retry 8 \
        --retry-delay 3 \
        --retry-all-errors \
        "$@"
}

asset_snapshot() {
    jq -c '[.assets[] | {name, id, size, updatedAt, digest}] | sort_by(.name)'
}

assert_exact_release_assets() {
    local release_json="$1"
    local release_label="$2"
    jq -e \
        --arg zip "$UPDATE_ZIP_NAME" \
        --arg dmg "$DMG_NAME" \
        --arg appcast "$APPCAST_NAME" \
        --arg checksums "$CHECKSUMS_NAME" \
        --arg manifest "$ARTIFACT_MANIFEST_NAME" \
        '([.assets[].name] | sort) == ([$zip, $dmg, $appcast, $checksums, $manifest] | sort)' \
        <<< "$release_json" >/dev/null ||
        fail "$release_label must contain exactly: $UPDATE_ZIP_NAME, $DMG_NAME, $APPCAST_NAME, $CHECKSUMS_NAME, $ARTIFACT_MANIFEST_NAME"
}

assert_exact_update_assets() {
    local release_json="$1"
    jq -e \
        --arg zip "$UPDATE_ZIP_NAME" \
        --arg appcast "$APPCAST_NAME" \
        --arg checksums "$CHECKSUMS_NAME" \
        --arg manifest "$ARTIFACT_MANIFEST_NAME" \
        '([.assets[].name] | sort) == ([$zip, $appcast, $checksums, $manifest] | sort)' \
        <<< "$release_json" >/dev/null ||
        fail "Public updater release must contain exactly: $UPDATE_ZIP_NAME, $APPCAST_NAME, $CHECKSUMS_NAME, $ARTIFACT_MANIFEST_NAME"
}

derive_sparkle_public_key() {
    local private_key_file="$1"
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift" "$private_key_file"
}

validate_checksum_manifest() {
    (
        cd "$SOURCE_ASSETS_DIR"
        printf '%s\n' "$APPCAST_NAME" "$DMG_NAME" "$UPDATE_ZIP_NAME" "$ARTIFACT_MANIFEST_NAME" | sort > "$TMP_DIR/expected-checksum-files.txt"
        awk '{ print $2 }' "$CHECKSUMS_NAME" | sort > "$TMP_DIR/checksum-files.txt"
        diff -u "$TMP_DIR/expected-checksum-files.txt" "$TMP_DIR/checksum-files.txt" ||
            fail "$CHECKSUMS_NAME must contain exactly the reviewed ZIP, DMG, appcast, and artifact manifest"
        shasum -a 256 -c "$CHECKSUMS_NAME"
    )
}

verify_reviewed_checksums_digest() {
    require_env REVIEWED_CHECKSUMS_SHA256
    local actual_digest
    actual_digest="$(shasum -a 256 "$CHECKSUMS" | awk '{ print $1 }')"
    [[ "$actual_digest" == "$REVIEWED_CHECKSUMS_SHA256" ]] ||
        fail "Reviewed SHA256SUMS digest mismatch: expected $REVIEWED_CHECKSUMS_SHA256, got $actual_digest"
}

validate_app_bundle() {
    local app_bundle="$1"
    local artifact_manifest="$2"
    codesign --verify --deep --strict --verbose=2 "$app_bundle"

    local signature_details team_identifier
    signature_details="$(codesign -dv --verbose=4 "$app_bundle" 2>&1)"
    team_identifier="$(printf '%s\n' "$signature_details" |
        awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
    printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' ||
        fail "Update app is not signed with a Developer ID Application certificate"
    [[ "$team_identifier" == "$SIGNING_TEAM_ID" ]] ||
        fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team_identifier:-<missing>}"
    xcrun stapler validate "$app_bundle"

    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_packaged_legal.sh" "$app_bundle"
    validate_embedded_mcp_helper_layout "$app_bundle" "Reviewed ZIP MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" \
        "$app_bundle" \
        "arm64,x86_64" \
        "Reviewed ZIP app"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" verify \
        --app "$app_bundle" \
        --manifest "$artifact_manifest" \
        --expected-architectures "arm64,x86_64"
}

validate_dmg_matches_zip_app() {
    DMG_MOUNT_POINT="$TMP_DIR/dmg-mount"
    mkdir -p "$DMG_MOUNT_POINT"
    hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$DMG_MOUNT_POINT" >/dev/null

    local dmg_app="$DMG_MOUNT_POINT/$DISTRIBUTION_APP_BUNDLE_NAME"
    [[ -d "$dmg_app" ]] || fail "DMG does not contain $DISTRIBUTION_APP_BUNDLE_NAME at its root"
    diff -qr "$APP_BUNDLE" "$dmg_app" ||
        fail "DMG app contents do not match the verified update ZIP app"
    validate_embedded_mcp_helper_layout "$dmg_app" "Mounted DMG MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" \
        "$dmg_app" \
        "arm64,x86_64" \
        "Mounted DMG app"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" verify \
        --app "$dmg_app" \
        --manifest "$ARTIFACT_MANIFEST" \
        --expected-architectures "arm64,x86_64"

    hdiutil detach "$DMG_MOUNT_POINT" >/dev/null
    DMG_MOUNT_POINT=""
}

validate_appcast() {
    local appcast_values="$TMP_DIR/appcast-values.tsv"
    python3 - "$APPCAST" > "$appcast_values" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"appcast must contain exactly one item, got {len(items)}")
enclosures = items[0].findall("enclosure")
if len(enclosures) != 1:
    raise SystemExit(f"appcast item must contain exactly one enclosure, got {len(enclosures)}")
item = items[0]
enclosure = enclosures[0]
values = [
    enclosure.attrib.get("url", ""),
    enclosure.attrib.get(f"{{{sparkle}}}edSignature", ""),
    enclosure.attrib.get("length", ""),
    item.findtext(f"{{{sparkle}}}version", default=""),
    item.findtext(f"{{{sparkle}}}shortVersionString", default=""),
]
print("\t".join(values))
PYTHON

    local enclosure_url enclosure_signature enclosure_length appcast_build appcast_marketing
    IFS=$'\t' read -r enclosure_url enclosure_signature enclosure_length appcast_build appcast_marketing < "$appcast_values"
    [[ "$enclosure_url" == "$PUBLIC_UPDATE_BASE_URL/$UPDATE_ZIP_NAME" ]] ||
        fail "Appcast enclosure URL mismatch: $enclosure_url"
    [[ -n "$enclosure_signature" ]] || fail "Appcast enclosure is missing an EdDSA signature"
    [[ "$enclosure_length" == "$(stat -f %z "$UPDATE_ZIP")" ]] ||
        fail "Appcast enclosure length does not match $UPDATE_ZIP_NAME"
    [[ "$appcast_build" == "$BUILD_NUMBER" ]] ||
        fail "Appcast build mismatch: expected $BUILD_NUMBER, got $appcast_build"
    [[ "$appcast_marketing" == "$MARKETING_VERSION" ]] ||
        fail "Appcast marketing version mismatch: expected $MARKETING_VERSION, got $appcast_marketing"

    local private_key_file="$TMP_DIR/sparkle-private-key"
    local committed_public_key_file="$TMP_DIR/sparkle-public-key"
    umask 077
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$private_key_file"
    local derived_public_key committed_public_key archive_signature
    derived_public_key="$(derive_sparkle_public_key "$private_key_file")"
    committed_public_key="$(plutil -extract SUPublicEDKey raw "$APP_BUNDLE/Contents/Info.plist")"
    [[ "$derived_public_key" == "$committed_public_key" ]] ||
        fail "Protected Sparkle private key does not match the app bundle SUPublicEDKey"
    archive_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$UPDATE_ZIP" |
        tr -d '\r\n')"
    [[ "$archive_signature" == "$enclosure_signature" ]] ||
        fail "Protected Sparkle private key does not reproduce the reviewed appcast signature"
    printf '%s' "$committed_public_key" > "$committed_public_key_file"
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift" \
        "$committed_public_key_file" "$enclosure_signature" "$UPDATE_ZIP"
}

verify_source_release() {
    require_env RELEASE_TAG
    require_env RELEASE_COMMIT
    require_env SOURCE_GH_TOKEN
    require_env SPARKLE_PRIVATE_KEY
    require_release_tag_matches_metadata
    for command in codesign curl diff ditto gh hdiutil jq plutil python3 shasum stat xcrun; do
        require_command "$command"
    done
    require_file "$SIGN_UPDATE"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_packaged_legal.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py"
    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh"

    TMP_DIR="$(mktemp -d)"
    SOURCE_ASSETS_DIR="$TMP_DIR/source-assets"
    EXTRACT_DIR="$TMP_DIR/extract"
    mkdir -p "$SOURCE_ASSETS_DIR" "$EXTRACT_DIR"

    local source_release_json
    source_release_json="$(source_gh release view "$RELEASE_TAG" \
        --repo "$SOURCE_GITHUB_REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets,body)"
    [[ "$(jq -r .tagName <<< "$source_release_json")" == "$RELEASE_TAG" ]] ||
        fail "Reviewed source release tag mismatch"
    [[ "$(jq -r .isPrerelease <<< "$source_release_json")" == "false" ]] ||
        fail "Source release must not be a prerelease"
    grep -Fq "Release-Commit: \`$RELEASE_COMMIT\`" <<< "$(jq -r .body <<< "$source_release_json")" ||
        fail "Source release is missing its approved release-commit attestation"
    SOURCE_RELEASE_WAS_DRAFT="$(jq -r .isDraft <<< "$source_release_json")"
    [[ "$SOURCE_RELEASE_WAS_DRAFT" == "true" || "$SOURCE_RELEASE_WAS_DRAFT" == "false" ]] ||
        fail "Unable to determine source release draft state"
    assert_exact_release_assets "$source_release_json" "Reviewed source release"
    SOURCE_RELEASE_ASSET_SNAPSHOT="$(asset_snapshot <<< "$source_release_json")"

    source_gh release download "$RELEASE_TAG" \
        --repo "$SOURCE_GITHUB_REPOSITORY" \
        --dir "$SOURCE_ASSETS_DIR" \
        --pattern "$CHECKSUMS_NAME"
    CHECKSUMS="$SOURCE_ASSETS_DIR/$CHECKSUMS_NAME"
    verify_reviewed_checksums_digest
    source_gh release download "$RELEASE_TAG" \
        --repo "$SOURCE_GITHUB_REPOSITORY" \
        --dir "$SOURCE_ASSETS_DIR" \
        --pattern "$UPDATE_ZIP_NAME" \
        --pattern "$DMG_NAME" \
        --pattern "$APPCAST_NAME" \
        --pattern "$ARTIFACT_MANIFEST_NAME"
    recheck_source_assets

    UPDATE_ZIP="$SOURCE_ASSETS_DIR/$UPDATE_ZIP_NAME"
    DMG="$SOURCE_ASSETS_DIR/$DMG_NAME"
    APPCAST="$SOURCE_ASSETS_DIR/$APPCAST_NAME"
    ARTIFACT_MANIFEST="$SOURCE_ASSETS_DIR/$ARTIFACT_MANIFEST_NAME"
    validate_checksum_manifest

    ditto -x -k "$UPDATE_ZIP" "$EXTRACT_DIR"
    [[ -d "$EXTRACT_DIR/$DISTRIBUTION_APP_BUNDLE_NAME" ]] ||
        fail "Update ZIP must contain $DISTRIBUTION_APP_BUNDLE_NAME at its root"
    APP_BUNDLE="$EXTRACT_DIR/$DISTRIBUTION_APP_BUNDLE_NAME"
    validate_app_bundle "$APP_BUNDLE" "$ARTIFACT_MANIFEST"
    xcrun stapler validate "$DMG"
    validate_dmg_matches_zip_app

    local info_plist="$APP_BUNDLE/Contents/Info.plist"
    local bundle_identifier marketing_version build_number feed_url
    bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
    marketing_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist")"
    build_number="$(plutil -extract CFBundleVersion raw "$info_plist")"
    feed_url="$(plutil -extract SUFeedURL raw "$info_plist")"
    [[ "$bundle_identifier" == "$BUNDLE_ID" ]] ||
        fail "Bundle identifier mismatch: expected $BUNDLE_ID, got $bundle_identifier"
    [[ "$marketing_version" == "$MARKETING_VERSION" ]] ||
        fail "Marketing version mismatch: expected $MARKETING_VERSION, got $marketing_version"
    [[ "$build_number" == "$BUILD_NUMBER" ]] ||
        fail "Build number mismatch: expected $BUILD_NUMBER, got $build_number"
    [[ "$feed_url" == "$PUBLIC_FEED_URL" ]] ||
        fail "Sparkle feed mismatch: expected $PUBLIC_FEED_URL, got $feed_url"
    validate_appcast

    printf 'OK: reviewed source release assets verified for %s.\n' "$RELEASE_TAG"
}

recheck_source_assets() {
    local current_json current_snapshot
    current_json="$(source_gh release view "$RELEASE_TAG" \
        --repo "$SOURCE_GITHUB_REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets,body)"
    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
    grep -Fq "Release-Commit: \`$RELEASE_COMMIT\`" <<< "$(jq -r .body <<< "$current_json")" ||
        fail "Source release lost its approved release-commit attestation"
    assert_exact_release_assets "$current_json" "Reviewed source release"
    current_snapshot="$(asset_snapshot <<< "$current_json")"
    [[ "$current_snapshot" == "$SOURCE_RELEASE_ASSET_SNAPSHOT" ]] ||
        fail "Source release assets changed after verification; rerun promotion from a fresh review"
}

verify_strictly_newer_build() {
    local latest_json_file="$TMP_DIR/latest-release.json"
    local latest_status latest_json latest_tag latest_appcast latest_build
    if ! latest_status="$(env -u GH_TOKEN -u GITHUB_TOKEN curl \
        --location \
        --silent \
        --show-error \
        --header "Authorization: Bearer $PUBLIC_UPDATE_GH_TOKEN" \
        --header "Accept: application/vnd.github+json" \
        --output "$latest_json_file" \
        --write-out '%{http_code}' \
        "https://api.github.com/repos/$PUBLIC_UPDATE_REPOSITORY/releases/latest")"; then
        fail "Unable to query the current stable updater release"
    fi
    if [[ "$latest_status" == "404" ]]; then
        return
    fi
    [[ "$latest_status" == "200" ]] ||
        fail "Unable to query the current stable updater release: HTTP $latest_status"
    latest_json="$(cat "$latest_json_file")"
    latest_tag="$(jq -r .tag_name <<< "$latest_json")"
    if [[ "$latest_tag" == "$RELEASE_TAG" ]]; then
        return 0
    fi

    latest_appcast="$TMP_DIR/latest-appcast.xml"
    curl_anonymous \
        "https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$latest_tag/$APPCAST_NAME" \
        --output "$latest_appcast"
    latest_build="$(python3 - "$latest_appcast" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
items = ET.parse(sys.argv[1]).getroot().findall("./channel/item")
if len(items) != 1:
    raise SystemExit("latest stable appcast must contain exactly one item")
print(items[0].findtext(f"{{{sparkle}}}version", default=""))
PYTHON
)"
    [[ "$BUILD_NUMBER" =~ ^[0-9]+$ && "$latest_build" =~ ^[0-9]+$ ]] ||
        fail "Stable build numbers must be numeric: current=$BUILD_NUMBER latest=$latest_build"
    (( BUILD_NUMBER > latest_build )) ||
        fail "Stable promotion requires BUILD_NUMBER > $latest_build, got $BUILD_NUMBER"
}

verify_existing_update_release() {
    local update_release_json="$1"
    local existing_assets_dir="$TMP_DIR/existing-update-assets"
    assert_exact_update_assets "$update_release_json"
    mkdir -p "$existing_assets_dir"
    update_gh release download "$RELEASE_TAG" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --dir "$existing_assets_dir" \
        --pattern "$UPDATE_ZIP_NAME" \
        --pattern "$APPCAST_NAME" \
        --pattern "$CHECKSUMS_NAME" \
        --pattern "$ARTIFACT_MANIFEST_NAME"
    cmp "$UPDATE_ZIP" "$existing_assets_dir/$UPDATE_ZIP_NAME"
    cmp "$APPCAST" "$existing_assets_dir/$APPCAST_NAME"
    cmp "$CHECKSUMS" "$existing_assets_dir/$CHECKSUMS_NAME"
    cmp "$ARTIFACT_MANIFEST" "$existing_assets_dir/$ARTIFACT_MANIFEST_NAME"
}

prepare_update_release() {
    local update_release_json
    if update_release_json="$(update_gh release view "$RELEASE_TAG" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets 2>/dev/null)"; then
        [[ "$(jq -r .tagName <<< "$update_release_json")" == "$RELEASE_TAG" ]] ||
            fail "Public updater release tag mismatch"
        [[ "$(jq -r .isPrerelease <<< "$update_release_json")" == "false" ]] ||
            fail "Public updater release must not be a prerelease"
        verify_existing_update_release "$update_release_json"
        UPDATE_RELEASE_ASSET_SNAPSHOT="$(asset_snapshot <<< "$update_release_json")"
        if [[ "$(jq -r .isDraft <<< "$update_release_json")" == "true" ]]; then
            UPDATE_RELEASE_STATE="draft"
        else
            UPDATE_RELEASE_STATE="published"
        fi
        return
    fi

    update_gh release create "$RELEASE_TAG" \
        "$UPDATE_ZIP" \
        "$APPCAST" \
        "$CHECKSUMS" \
        "$ARTIFACT_MANIFEST" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --target main \
        --draft \
        --latest=false \
        --title "$DISPLAY_NAME $MARKETING_VERSION" \
        --notes "Stable Sparkle update assets for $DISPLAY_NAME $MARKETING_VERSION ($BUILD_NUMBER)."
    UPDATE_RELEASE_STATE="draft"
    update_release_json="$(update_gh release view "$RELEASE_TAG" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets)"
    assert_exact_update_assets "$update_release_json"
    UPDATE_RELEASE_ASSET_SNAPSHOT="$(asset_snapshot <<< "$update_release_json")"
}

recheck_update_assets() {
    local current_json current_snapshot
    current_json="$(update_gh release view "$RELEASE_TAG" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --json tagName,isDraft,isPrerelease,assets)"
    assert_exact_update_assets "$current_json"
    current_snapshot="$(asset_snapshot <<< "$current_json")"
    [[ "$current_snapshot" == "$UPDATE_RELEASE_ASSET_SNAPSHOT" ]] ||
        fail "Public updater release assets changed after verification; rerun promotion from a fresh review"
}

publish_reviewed_release() {
    require_env PUBLIC_UPDATE_GH_TOKEN
    [[ "$(source_gh repo view "$SOURCE_GITHUB_REPOSITORY" --json visibility --jq .visibility)" == "PUBLIC" ]] ||
        fail "Stable promotion requires a public source repository: $SOURCE_GITHUB_REPOSITORY"
    [[ "$(update_gh repo view "$PUBLIC_UPDATE_REPOSITORY" --json visibility --jq .visibility)" == "PUBLIC" ]] ||
        fail "Update repository must be public: $PUBLIC_UPDATE_REPOSITORY"

    verify_strictly_newer_build
    verify_reviewed_checksums_digest
    recheck_source_assets
    prepare_update_release
    recheck_source_assets
    recheck_update_assets
    verify_reviewed_checksums_digest

    update_gh release edit "$RELEASE_TAG" \
        --repo "$PUBLIC_UPDATE_REPOSITORY" \
        --draft=false \
        --latest
    recheck_source_assets
    source_gh release edit "$RELEASE_TAG" \
        --repo "$SOURCE_GITHUB_REPOSITORY" \
        --draft=false \
        --latest
}

verify_anonymous_publish() {
    local published_update_appcast="$TMP_DIR/published-update-appcast.xml"
    local published_update_zip="$TMP_DIR/published-update-$UPDATE_ZIP_NAME"
    local published_update_checksums="$TMP_DIR/published-update-$CHECKSUMS_NAME"
    local published_update_manifest="$TMP_DIR/published-update-$ARTIFACT_MANIFEST_NAME"
    local published_source_zip="$TMP_DIR/published-source-$UPDATE_ZIP_NAME"
    local published_source_dmg="$TMP_DIR/published-source-$DMG_NAME"
    local published_source_appcast="$TMP_DIR/published-source-$APPCAST_NAME"
    local published_source_checksums="$TMP_DIR/published-source-$CHECKSUMS_NAME"
    local published_source_manifest="$TMP_DIR/published-source-$ARTIFACT_MANIFEST_NAME"

    curl_anonymous "$PUBLIC_FEED_URL" --output "$published_update_appcast"
    curl_anonymous "$PUBLIC_UPDATE_BASE_URL/$UPDATE_ZIP_NAME" --output "$published_update_zip"
    curl_anonymous "$PUBLIC_UPDATE_BASE_URL/$CHECKSUMS_NAME" --output "$published_update_checksums"
    curl_anonymous "$PUBLIC_UPDATE_BASE_URL/$ARTIFACT_MANIFEST_NAME" --output "$published_update_manifest"
    curl_anonymous "$SOURCE_RELEASE_BASE_URL/$UPDATE_ZIP_NAME" --output "$published_source_zip"
    curl_anonymous "$SOURCE_RELEASE_BASE_URL/$DMG_NAME" --output "$published_source_dmg"
    curl_anonymous "$SOURCE_RELEASE_BASE_URL/$APPCAST_NAME" --output "$published_source_appcast"
    curl_anonymous "$SOURCE_RELEASE_BASE_URL/$CHECKSUMS_NAME" --output "$published_source_checksums"
    curl_anonymous "$SOURCE_RELEASE_BASE_URL/$ARTIFACT_MANIFEST_NAME" --output "$published_source_manifest"

    cmp "$APPCAST" "$published_update_appcast"
    cmp "$UPDATE_ZIP" "$published_update_zip"
    cmp "$CHECKSUMS" "$published_update_checksums"
    cmp "$ARTIFACT_MANIFEST" "$published_update_manifest"
    cmp "$UPDATE_ZIP" "$published_source_zip"
    cmp "$DMG" "$published_source_dmg"
    cmp "$APPCAST" "$published_source_appcast"
    cmp "$CHECKSUMS" "$published_source_checksums"
    cmp "$ARTIFACT_MANIFEST" "$published_source_manifest"

    local update_latest_url source_latest_url
    update_latest_url="$(curl_anonymous \
        --output /dev/null \
        --write-out '%{url_effective}' \
        "https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/latest")"
    source_latest_url="$(curl_anonymous \
        --output /dev/null \
        --write-out '%{url_effective}' \
        "https://github.com/$SOURCE_GITHUB_REPOSITORY/releases/latest")"
    [[ "$update_latest_url" == "https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/tag/$RELEASE_TAG" ]] ||
        fail "Public updater latest redirect mismatch: $update_latest_url"
    [[ "$source_latest_url" == "https://github.com/$SOURCE_GITHUB_REPOSITORY/releases/tag/$RELEASE_TAG" ]] ||
        fail "Source latest redirect mismatch: $source_latest_url"

    printf 'OK: anonymous release smoke passed for %s.\n' "$RELEASE_TAG"
}

case "$MODE" in
    verify)
        verify_source_release
        ;;
    promote)
        verify_source_release
        preflight_sentry_deploy_access
        publish_reviewed_release
        verify_anonymous_publish
        record_verified_sentry_deploy_if_needed
        ;;
    *)
        fail "Usage: $0 verify|promote"
        ;;
esac
