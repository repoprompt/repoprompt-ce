#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-preflight}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
ARCHIVE_BASENAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
APPCAST="$DIST_DIR/appcast.xml"
CHECKSUMS="$DIST_DIR/SHA256SUMS"
BUILD_ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"
SENTRY_RELEASE_NAME="$BUNDLE_ID@$MARKETING_VERSION+$BUILD_NUMBER"
SENTRY_API_BASE_URL="${REPOPROMPT_SENTRY_API_BASE_URL:-https://sentry.io/api/0}"
SENTRY_CURL_CONFIG=""
FINAL_ARTIFACT_MANIFEST="$DIST_DIR/$ARCHIVE_BASENAME-artifact-manifest.json"
STAGE_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-stage.zip"
STAGE_ARCHIVE_CHECKSUM="$STAGE_ARCHIVE.sha256"
RELEASE_TAG="${RELEASE_TAG:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-repoprompt/repoprompt-ce}"
PUBLIC_UPDATE_REPOSITORY="${PUBLIC_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-updates}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$RELEASE_TAG/}"
EXPECTED_FEED_URL="https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml"
SPARKLE_FRAMEWORK_INFO="$ROOT_DIR/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist"
TMP_DIR=""
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"

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

require_env() {
    [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"
}

sentry_linking_enabled() {
    [[ "${REPOPROMPT_ENABLE_SENTRY:-}" == "1" ]]
}

require_release_tag_matches_metadata() {
    [[ "$RELEASE_TAG" == "v$MARKETING_VERSION" ]] ||
        fail "Release tag must match release metadata: expected v$MARKETING_VERSION, got ${RELEASE_TAG:-<missing>}"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

prepare_dist() {
    [[ "$DIST_DIR" != "/" ]] || fail "DIST_DIR must not be /"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
}

run_preflight() {
    require_command plutil
    require_command shasum
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/swiftpm_notice_guardrails.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_packaged_legal.sh"
    require_file "$ROOT_DIR/AppBundle/Info.plist.template"
    require_file "$ROOT_DIR/AppBundle/RepoPrompt.entitlements.template"
    require_file "$ROOT_DIR/AppBundle/RepoPrompt.local-self-signed.entitlements.template"
    require_file "$ROOT_DIR/Vendor/Sparkle/LICENSE"
    require_file "$ROOT_DIR/Vendor/Sparkle/PROVENANCE.md"
    require_file "$ROOT_DIR/Vendor/Sparkle/SHA256SUMS"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/build_swiftpm_release_products.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/compare_swiftpm_release_resources.py"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/smoke_packaged_mcp_roundtrip.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_packaged_mcp_socket_owner.py"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_required_swiftpm_resource_bundles.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/patches/keyboardshortcuts-2.3.0-resource-lookup.patch"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/extract_staged_release.py"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    require_file "$RUN_WITHOUT_GITHUB_TOKENS"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh"
    require_file "$TRUSTED_ROOT/Vendor/Sparkle/INSTALLED_MANIFEST.tsv"
    require_file "$TRUSTED_ROOT/Vendor/Sparkle/bin/generate_appcast"
    require_file "$SPARKLE_FRAMEWORK_INFO"

    local sparkle_version feed_url
    sparkle_version="$(plutil -extract CFBundleShortVersionString raw "$SPARKLE_FRAMEWORK_INFO")"
    feed_url="$(plutil -extract SUFeedURL raw "$ROOT_DIR/AppBundle/Info.plist.template")"
    [[ "$sparkle_version" == "2.9.2" ]] || fail "Expected vendored Sparkle 2.9.2, got $sparkle_version"
    [[ "$feed_url" == "$EXPECTED_FEED_URL" ]] || fail "Expected CE Sparkle feed $EXPECTED_FEED_URL, got $feed_url"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/swiftpm_notice_guardrails.sh"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh" --check

    printf 'OK: release preflight passed for %s %s (%s) with Sparkle %s.\n' \
        "$DISPLAY_NAME" "$MARKETING_VERSION" "$BUILD_NUMBER" "$sparkle_version"
}

sync_mcp_cli_version() {
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh"
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

write_final_artifact_manifest() {
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" write \
        --app "$APP_BUNDLE" \
        --output "$FINAL_ARTIFACT_MANIFEST" \
        --expected-architectures "arm64,x86_64"
}

require_staged_sentry_symbols_when_enabled() {
    if sentry_linking_enabled && [[ ! -d "$SENTRY_SYMBOLS_DIR" ]]; then
        fail "Sentry-enabled release staging did not produce debug symbols at $SENTRY_SYMBOLS_DIR"
    fi
}

require_sentry_publish_configuration() {
    sentry_linking_enabled || return 0
    [[ -n "${SENTRY_AUTH_TOKEN:-}" || -n "${REPOPROMPT_SENTRY_AUTH_TOKEN_FILE:-${SENTRY_AUTH_TOKEN_FILE:-}}" ]] || fail "Official Sentry-enabled release publishing requires SENTRY_AUTH_TOKEN or REPOPROMPT_SENTRY_AUTH_TOKEN_FILE for Sentry release metadata and debug symbol upload."
    require_env REPOPROMPT_SENTRY_ORG
    require_env REPOPROMPT_SENTRY_PROJECT
    require_command curl
    require_command jq
    require_command sentry-cli
}

prepare_sentry_api_access() {
    sentry_linking_enabled || return 0
    [[ -n "$SENTRY_CURL_CONFIG" && -f "$SENTRY_CURL_CONFIG" ]] && return 0
    [[ -n "$TMP_DIR" ]] || fail "Sentry API access requires an initialized release workspace"
    local token="${SENTRY_AUTH_TOKEN:-}"
    if [[ -z "$token" ]]; then
        local configured_token_file="${REPOPROMPT_SENTRY_AUTH_TOKEN_FILE:-${SENTRY_AUTH_TOKEN_FILE:-}}"
        [[ -n "$configured_token_file" ]] || fail "Missing Sentry auth token file"
        [[ -f "$configured_token_file" ]] || fail "Sentry auth token file does not exist: $configured_token_file"
        token="$(tr -d '\r\n' < "$configured_token_file")"
    fi
    [[ -n "$token" ]] || fail "Sentry auth token file was empty"

    SENTRY_CURL_CONFIG="$TMP_DIR/sentry-curl.conf"
    local normalized_token_file="$TMP_DIR/sentry-auth-token"
    (
        umask 077
        printf '%s' "$token" > "$normalized_token_file"
        printf 'header = "Authorization: Bearer %s"\n' "$token" > "$SENTRY_CURL_CONFIG"
    )
    chmod 600 "$normalized_token_file" "$SENTRY_CURL_CONFIG"
    REPOPROMPT_SENTRY_AUTH_TOKEN_FILE="$normalized_token_file"
    export REPOPROMPT_SENTRY_AUTH_TOKEN_FILE
    unset SENTRY_AUTH_TOKEN
}

sentry_releases_endpoint() {
    local encoded_org
    encoded_org="$(jq -rn --arg value "$REPOPROMPT_SENTRY_ORG" '$value | @uri')"
    printf '%s/organizations/%s/releases/' "${SENTRY_API_BASE_URL%/}" "$encoded_org"
}

sentry_release_endpoint() {
    local encoded_release
    encoded_release="$(jq -rn --arg value "$SENTRY_RELEASE_NAME" '$value | @uri')"
    printf '%s%s/' "$(sentry_releases_endpoint)" "$encoded_release"
}

sentry_release_preflight_endpoint() {
    local encoded_project
    encoded_project="$(jq -rn --arg value "$REPOPROMPT_SENTRY_PROJECT" '$value | @uri')"
    printf '%s?project=%s&per_page=1' "$(sentry_releases_endpoint)" "$encoded_project"
}

sentry_api_request() {
    local method="$1"
    local endpoint="$2"
    local output_file="$3"
    local body_file="${4:-}"
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
    status="$(curl "${args[@]}" "$endpoint")" ||
        fail "Unable to call the Sentry release API"
    [[ "$status" =~ ^[0-9]{3}$ ]] || fail "Sentry release API returned an invalid HTTP status"
    printf '%s' "$status"
}

fail_sentry_release_api_status() {
    local action="$1"
    local status="$2"
    case "$status" in
        401)
            fail "Sentry release API rejected the organization token (HTTP 401); verify that SENTRY_AUTH_TOKEN is current"
            ;;
        403)
            fail "Sentry release API rejected the organization token (HTTP 403); verify org:ci access to $REPOPROMPT_SENTRY_ORG/$REPOPROMPT_SENTRY_PROJECT"
            ;;
        *)
            fail "Sentry release API could not $action (HTTP $status)"
            ;;
    esac
}

validate_sentry_release_response() {
    local response_file="$1"
    local label="$2"
    jq -e \
        --arg version "$SENTRY_RELEASE_NAME" \
        --arg project "$REPOPROMPT_SENTRY_PROJECT" \
        '.version == $version and
            (.projects | type == "array") and
            any(.projects[]?; .slug == $project)' \
        "$response_file" >/dev/null ||
        fail "Sentry release API returned malformed or mismatched JSON for $label"
}

preflight_sentry_release_access() {
    sentry_linking_enabled || return 0
    prepare_sentry_api_access
    local response_file="$TMP_DIR/sentry-release-preflight.json"
    local status
    status="$(sentry_api_request GET "$(sentry_release_preflight_endpoint)" "$response_file")"
    [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
        fail_sentry_release_api_status "verify release access" "$status"
    jq -e 'type == "array" and all(.[]; .version | type == "string")' "$response_file" >/dev/null ||
        fail "Sentry release API returned malformed JSON during access preflight"
    printf 'OK: Sentry org:ci release access verified for %s/%s.\n' \
        "$REPOPROMPT_SENTRY_ORG" "$REPOPROMPT_SENTRY_PROJECT"
}

prepare_sentry_release() {
    sentry_linking_enabled || return 0
    prepare_sentry_api_access
    local source_repository="${SOURCE_GITHUB_REPOSITORY:-$GITHUB_REPOSITORY}"
    [[ -n "$source_repository" ]] || fail "Missing SOURCE_GITHUB_REPOSITORY for Sentry commit association"
    printf 'Preparing Sentry release %s for %s/%s.\n' "$SENTRY_RELEASE_NAME" "$REPOPROMPT_SENTRY_ORG" "$REPOPROMPT_SENTRY_PROJECT"
    local release_response="$TMP_DIR/sentry-release.json"
    local status
    status="$(sentry_api_request GET "$(sentry_release_endpoint)" "$release_response")"
    if [[ "$status" == "404" ]]; then
        local create_body="$TMP_DIR/sentry-release-create.json"
        jq -n \
            --arg version "$SENTRY_RELEASE_NAME" \
            --arg project "$REPOPROMPT_SENTRY_PROJECT" \
            --arg repository "$source_repository" \
            --arg commit "$RELEASE_COMMIT" \
            '{version: $version, projects: [$project], refs: [{repository: $repository, commit: $commit}]}' \
            > "$create_body"
        chmod 600 "$create_body"
        status="$(sentry_api_request POST "$(sentry_releases_endpoint)" "$release_response" "$create_body")"
        [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
            fail_sentry_release_api_status "create release $SENTRY_RELEASE_NAME" "$status"
    elif [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        fail_sentry_release_api_status "look up release $SENTRY_RELEASE_NAME" "$status"
    fi
    validate_sentry_release_response "$release_response" "release preparation"

    local refs_body="$TMP_DIR/sentry-release-refs.json"
    jq -n \
        --arg repository "$source_repository" \
        --arg commit "$RELEASE_COMMIT" \
        '{refs: [{repository: $repository, commit: $commit}]}' > "$refs_body"
    chmod 600 "$refs_body"
    status="$(sentry_api_request PUT "$(sentry_release_endpoint)" "$release_response" "$refs_body")"
    [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
        fail_sentry_release_api_status "associate release commits" "$status"
    validate_sentry_release_response "$release_response" "commit association"
}

finalize_sentry_release() {
    sentry_linking_enabled || return 0
    prepare_sentry_api_access
    local release_response="$TMP_DIR/sentry-release-finalize.json"
    local status
    status="$(sentry_api_request GET "$(sentry_release_endpoint)" "$release_response")"
    [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
        fail_sentry_release_api_status "look up release $SENTRY_RELEASE_NAME before finalization" "$status"
    validate_sentry_release_response "$release_response" "release finalization"
    if jq -e '.dateReleased | type == "string"' "$release_response" >/dev/null; then
        printf 'OK: Sentry release %s is already finalized.\n' "$SENTRY_RELEASE_NAME"
        return
    fi
    jq -e '.dateReleased == null' "$release_response" >/dev/null ||
        fail "Sentry release API returned malformed finalization state"

    local finalize_body="$TMP_DIR/sentry-release-finalize-body.json"
    jq -n --arg date_released "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{dateReleased: $date_released}' > "$finalize_body"
    chmod 600 "$finalize_body"
    status="$(sentry_api_request PUT "$(sentry_release_endpoint)" "$release_response" "$finalize_body")"
    [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
        fail_sentry_release_api_status "finalize release $SENTRY_RELEASE_NAME" "$status"
    validate_sentry_release_response "$release_response" "release finalization"
    jq -e '.dateReleased | type == "string"' "$release_response" >/dev/null ||
        fail "Sentry release API did not confirm finalization"
}

upload_required_sentry_symbols() {
    require_sentry_publish_configuration
    "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" "$SENTRY_SYMBOLS_DIR"
}

package_release_candidate() {
    resolve_without_lockfile_drift
    run_preflight
    require_command ditto
    prepare_dist

    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        REPOPROMPT_ENABLE_SENTRY=1 \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    run_preflight
    validate_packaged_legal "$APP_BUNDLE"
    validate_public_app "$APP_BUNDLE" "$BUILD_ARTIFACT_MANIFEST" "Release candidate"
    write_final_artifact_manifest
    TMP_DIR="$(mktemp -d)"
    ditto "$APP_BUNDLE" "$TMP_DIR/$DISTRIBUTION_APP_BUNDLE_NAME"
    ditto -c -k --norsrc --keepParent "$TMP_DIR/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
    validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Release candidate archive"
    (
        cd "$DIST_DIR"
        shasum -a 256 \
            "$(basename "$UPDATE_ZIP")" \
            "$(basename "$FINAL_ARTIFACT_MANIFEST")" \
            > "$(basename "$CHECKSUMS")"
    )

    printf 'Created ad-hoc release-candidate artifact: %s\n' "$UPDATE_ZIP"
    printf 'This artifact is for packaging validation only. It is not notarized or distributable.\n'
}

verify_publish_inputs() {
    require_env RELEASE_TAG
    require_env RELEASE_COMMIT
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env SPARKLE_PRIVATE_KEY
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env GH_TOKEN
    require_release_tag_matches_metadata
    require_file "$REPOPROMPT_PROVISIONING_PROFILE"
    require_file "$NOTARYTOOL_PRIVATE_KEY"
    require_sentry_publish_configuration

    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
}

submit_notarization() {
    xcrun notarytool submit "$1" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait \
        --timeout "${NOTARYTOOL_TIMEOUT:-30m}"
}

stage_publish_release() {
    require_env RELEASE_TAG
    require_env RELEASE_COMMIT
    require_command ditto
    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
    require_release_tag_matches_metadata
    unset GH_TOKEN GITHUB_TOKEN SOURCE_GH_TOKEN
    resolve_without_lockfile_drift
    run_preflight
    prepare_dist
    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        REPOPROMPT_ENABLE_SENTRY=1 \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    run_preflight
    validate_packaged_legal "$APP_BUNDLE"
    validate_public_app "$APP_BUNDLE" "$BUILD_ARTIFACT_MANIFEST" "Release staging"
    require_staged_sentry_symbols_when_enabled
    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/release-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
    cp "$BUILD_ARTIFACT_MANIFEST" "$stage_root/.build/release/$APP_NAME-artifact-manifest.json"
    if [[ -d "$SENTRY_SYMBOLS_DIR" ]]; then
        mkdir -p "$stage_root/.build/sentry-symbols"
        ditto "$SENTRY_SYMBOLS_DIR" "$stage_root/.build/sentry-symbols/release"
    fi
    cp "$ROOT_DIR/version.env" "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$stage_root/"
    cp -R "$ROOT_DIR/ThirdPartyLicenses" "$stage_root/"
    printf '%s\n' "$RELEASE_COMMIT" > "$stage_root/RELEASE_COMMIT"
    ditto -c -k --norsrc "$stage_root" "$STAGE_ARCHIVE"
    (
        cd "$DIST_DIR"
        shasum -a 256 "$(basename "$STAGE_ARCHIVE")" > "$(basename "$STAGE_ARCHIVE_CHECKSUM")"
    )
    printf 'OK: secret-free release source staged for %s.\n' "$RELEASE_TAG"
    printf 'Created staged release artifact: %s\n' "$STAGE_ARCHIVE"
}

publish_staged_release() {
    require_command ditto
    require_command gh
    require_command hdiutil
    require_command xcrun
    verify_publish_inputs
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    TMP_DIR="$(mktemp -d)"
    preflight_sentry_release_access

    [[ -d "$APP_BUNDLE" ]] || fail "Missing secret-free staged app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    prepare_dist
    validate_packaged_legal "$APP_BUNDLE"

    local notary_zip="$TMP_DIR/$ARCHIVE_BASENAME-notarization.zip"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$notary_zip"
    submit_notarization "$notary_zip"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    write_final_artifact_manifest
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final Developer ID app"
    prepare_sentry_release
    upload_required_sentry_symbols

    local distribution_dir="$TMP_DIR/distribution"
    mkdir -p "$distribution_dir"
    ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    ditto -c -k --norsrc --keepParent "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
    validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Final distribution"

    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$distribution_dir" -ov -format UDZO "$DMG"
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    local appcast_dir="$TMP_DIR/appcast"
    mkdir -p "$appcast_dir"
    cp "$UPDATE_ZIP" "$appcast_dir/"
    printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$TRUSTED_ROOT/Vendor/Sparkle/bin/generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
            -o "$APPCAST" \
            "$appcast_dir"

    (
        cd "$DIST_DIR"
        shasum -a 256 \
            "$(basename "$UPDATE_ZIP")" \
            "$(basename "$DMG")" \
            "$(basename "$APPCAST")" \
            "$(basename "$FINAL_ARTIFACT_MANIFEST")" \
            > "$(basename "$CHECKSUMS")"
    )

    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
    local release_args=(
        "$RELEASE_TAG"
        "$UPDATE_ZIP"
        "$DMG"
        "$APPCAST"
        "$CHECKSUMS"
        "$FINAL_ARTIFACT_MANIFEST"
        --verify-tag
        --title "$DISPLAY_NAME $MARKETING_VERSION"
        --generate-notes
        --notes "Release-Commit: \`$RELEASE_COMMIT\`"
        --repo "$GITHUB_REPOSITORY"
        --draft
        --target "$RELEASE_COMMIT"
    )
    local existing_release_state=""
    if existing_release_state="$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null)"; then
        fail "GitHub release $RELEASE_TAG already exists (isDraft=$existing_release_state). Refusing to repeat Sentry finalization; inspect the existing draft and Sentry release before manual recovery."
    fi
    gh release create "${release_args[@]}"
    printf 'Created draft GitHub release assets for %s.\n' "$RELEASE_TAG"

    # Finalization marks release metadata, commits, and uploaded debug symbols ready.
    # Stable promotion records production availability only after public verification.
    finalize_sentry_release
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        sync-cli-version) sync_mcp_cli_version ;;
        preflight) run_preflight ;;
        artifact) package_release_candidate ;;
        stage-publish) stage_publish_release ;;
        publish-staged) publish_staged_release ;;
        *) fail "Usage: $0 sync-cli-version|preflight|artifact|stage-publish|publish-staged" ;;
    esac
fi
