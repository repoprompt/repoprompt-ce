#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-stage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$SCRIPT_DIR}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
APPROVED_SOURCE_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-}"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
source "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ROLLOUT_TOOL="$CONTROL_PLANE_SCRIPTS_DIR/stable_rollout.py"
PUBLICATION_TOOL="$CONTROL_PLANE_SCRIPTS_DIR/tip_release_publication.py"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
SIGN_UPDATE="$TRUSTED_ROOT/Vendor/Sparkle/bin/sign_update"
TMP_DIR=""

initialize_tip_release_context() {
    local boundary="main-tip-${1:-unknown}"
    load_verified_tip_release_context \
        "$CONTROL_PLANE_SCRIPTS_DIR" \
        "$APPROVED_SOURCE_ROOT" \
        "$boundary" || fail "Unable to load the verified Tip release context"
    [[ "$ROLLOUT_CHANNEL" == "tip" ]] || fail "Tip release requires a verified Tip context"
    [[ "$TIP_PUBLICATION_TARGET" == "main" ]] ||
        fail "Tip publication target must remain main"
    [[ "$TIP_PUBLICATION_DRAFT" == "false" ]] ||
        fail "Tip publication context must not be a draft"
    [[ "$TIP_PUBLICATION_PRERELEASE" == "false" ]] ||
        fail "Tip publication context must not be a prerelease"

    ROLLOUT_DECLARATION="$APPROVED_SOURCE_ROOT/tip-rollout.json"
    DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
    APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
    DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
    UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
    DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
    TRANSITION_PKG="$DIST_DIR/$ARCHIVE_BASENAME.pkg"
    TRANSITION_PACKAGE_WORK_DIR="${REPOPROMPT_TRANSITION_PACKAGE_WORK_DIR:-$ROOT_DIR/.build/release/$ARCHIVE_BASENAME-transition-work}"
    if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
        ENCLOSURE="$TRANSITION_PKG"
    else
        ENCLOSURE="$UPDATE_ZIP"
    fi
    APPCAST="$DIST_DIR/appcast.xml"
    CHECKSUMS="$DIST_DIR/SHA256SUMS"
    BUILD_ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
    SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"
    FINAL_ARTIFACT_MANIFEST="$DIST_DIR/$ARCHIVE_BASENAME-artifact-manifest.json"
    FINAL_METADATA="$DIST_DIR/$ARCHIVE_BASENAME-metadata.json"
    ROLLOUT_MANIFEST="$DIST_DIR/identity-rollout.json"
    STAGE_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-stage.zip"
    STAGE_ARCHIVE_CHECKSUM="$STAGE_ARCHIVE.sha256"
}

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
    local signed_team_identifier="${4:-}"
    [[ -n "$APPROVED_SOURCE_ROOT" ]] ||
        fail "$label requires an approved source root for Codex manifest validation"
    local approved_codex_manifest="$APPROVED_SOURCE_ROOT/Vendor/Codex/manifest.json"
    require_file "$approved_codex_manifest"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$app_bundle" "$label MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$app_bundle" "arm64,x86_64" "$label architectures"
    local codex_verification_args=(
        --manifest "$approved_codex_manifest" verify-bundle
        --arch all
        --bundle "$app_bundle/Contents/Resources/BundledRuntimes/Codex"
    )
    if [[ -n "$signed_team_identifier" ]]; then
        codex_verification_args+=(--signed-team-identifier "$signed_team_identifier")
    fi
    python3 "$CONTROL_PLANE_SCRIPTS_DIR/codex_runtime_artifact.py" "${codex_verification_args[@]}"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" verify \
        --app "$app_bundle" \
        --manifest "$manifest" \
        --expected-architectures "arm64,x86_64"
}

validate_distribution_zip() {
    local archive="$1"
    local manifest="$2"
    local label="$3"
    local signed_team_identifier="${4:-}"
    local extract_dir="$TMP_DIR/${label//[^A-Za-z0-9]/-}-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    ditto -x -k "$archive" "$extract_dir"
    local extracted_app="$extract_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    [[ -d "$extracted_app" ]] || fail "$label ZIP must contain $DISTRIBUTION_APP_BUNDLE_NAME at its root"
    validate_public_app "$extracted_app" "$manifest" "$label extracted app" "$signed_team_identifier"
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
{"commit":"$TIP_COMMIT","short_sha":"$TIP_SHORT_SHA","tag":"$TIP_TAG","marketing_version":"$MARKETING_VERSION","build_number":"$TIP_BUILD_NUMBER","rollout_role":"$ROLLOUT_ROLE","signing_identity":"$ROLLOUT_IDENTITY","migration_phase":"$REPOPROMPT_IDENTITY_MIGRATION_PHASE"}
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
    local phase_started=$SECONDS
    require_command ditto
    require_command curl
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
        BUNDLE_ID="$BUNDLE_ID" \
        SIGNING_TEAM_ID="$SIGNING_TEAM_ID" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
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
    cp "$ROLLOUT_DECLARATION" "$stage_root/tip-rollout.json"
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$stage_root/tip-release-context.json"
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" \
        "$stage_root/tip-release-context.json.sha256"
    write_tip_version_env "$stage_root/version.env"
    cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$stage_root/"
    cp -R "$ROOT_DIR/ThirdPartyLicenses" "$stage_root/"
    printf '%s\n' "$TIP_COMMIT" > "$stage_root/RELEASE_COMMIT"
    write_tip_metadata
    ditto -c -k --norsrc "$stage_root" "$STAGE_ARCHIVE"
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$STAGE_ARCHIVE")" > "$(basename "$STAGE_ARCHIVE_CHECKSUM")")
    printf 'OK: staged tip build %s (%s) for %s context=%s elapsed-seconds=%s.\n' \
        "$TIP_TAG" "$TIP_BUILD_NUMBER" "$TIP_COMMIT" \
        "$REPOPROMPT_TIP_CONTEXT_SHA256" "$((SECONDS - phase_started))"
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

generate_tip_rollout_appcast() {
    local predecessor_dir="$TMP_DIR/predecessors"
    mkdir -p "$predecessor_dir"
    # macOS Bash 3.2 aborts on empty-array expansion under set -u. Keep the
    # shared argument vector non-empty even for a zero-predecessor preparer.
    local rollout_context_args=(--enclosure "$ENCLOSURE")
    local position=0 role tag digest path actual_digest predecessor_values
    predecessor_values="$(python3 "$ROLLOUT_TOOL" predecessor-values-from-context)" ||
        fail "Unable to read verified Tip predecessor values"
    while IFS=$'\t' read -r role tag digest; do
        [[ -n "$role" ]] || continue
        position=$((position + 1))
        path="$predecessor_dir/$position-identity-rollout.json"
        curl --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 30 \
            "https://github.com/$ROLLOUT_UPDATE_REPOSITORY/releases/download/$tag/identity-rollout.json" \
            --output "$path"
        actual_digest="$(shasum -a 256 "$path" | awk '{print $1}')"
        [[ "$actual_digest" == "$digest" ]] ||
            fail "Tip predecessor $role manifest digest mismatch for $tag"
        rollout_context_args+=(--predecessor-manifest "$path")
    done <<< "$predecessor_values"

    local enclosure_signature
    enclosure_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE" |
        tr -d '\r\n')"
    [[ -n "$enclosure_signature" ]] || fail "Unable to sign Tip rollout enclosure"

    python3 "$ROLLOUT_TOOL" generate-from-context \
        "${rollout_context_args[@]}" \
        --enclosure-signature "$enclosure_signature" \
        --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --appcast-output "$APPCAST" \
        --manifest-output "$ROLLOUT_MANIFEST"
    python3 "$ROLLOUT_TOOL" validate-from-context \
        "${rollout_context_args[@]}" \
        --enclosure-signature "$enclosure_signature" \
        --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --appcast "$APPCAST" \
        --manifest "$ROLLOUT_MANIFEST"

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
        "$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE" |
        tr -d '\r\n')"
    [[ "$reproduced_signature" == "$enclosure_signature" ]] ||
        fail "Tip Sparkle private key does not reproduce the generated appcast signature"

    printf '%s' "$committed_public_key" > "$public_key_file"
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift" \
        "$public_key_file" "$enclosure_signature" "$ENCLOSURE"
}

sign_tip_application() {
    local phase_started=$SECONDS
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_tip_sentry_configuration
    [[ "$SIGN_IDENTITY" == "$EXPECTED_SIGN_IDENTITY" ]] ||
        fail "SIGN_IDENTITY does not match the reviewed $ROLLOUT_IDENTITY identity"
    [[ -d "$APP_BUNDLE" ]] || fail "Missing staged tip app bundle: $APP_BUNDLE"
    printf 'PHASE START [%s]: application signing role=%s bundle=%s team=%s tag=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROLLOUT_ROLE" "$BUNDLE_ID" "$SIGNING_TEAM_ID" "$TIP_TAG"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    verify_release_sentry_symbol_uuids_before_signing \
        "$SENTRY_SYMBOLS_DIR" \
        "$APP_BUNDLE" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    printf 'PHASE COMPLETE [%s]: application signing elapsed-seconds=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((SECONDS - phase_started))"
}

notarize_tip_application() {
    local phase_started=$SECONDS
    require_command ditto
    require_command python3
    require_command xcrun
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_tip_sentry_configuration
    [[ -d "$APP_BUNDLE" ]] || fail "Missing signed Tip app bundle: $APP_BUNDLE"
    printf 'PHASE START [%s]: application notarization role=%s bundle=%s team=%s tag=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROLLOUT_ROLE" "$BUNDLE_ID" "$SIGNING_TEAM_ID" "$TIP_TAG"
    prepare_dist
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$DIST_DIR/tip-release-context.json"
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" \
        "$DIST_DIR/tip-release-context.json.sha256"
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
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final tip Developer ID app" "$SIGNING_TEAM_ID"
    upload_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    printf 'PHASE COMPLETE [%s]: application notarization elapsed-seconds=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((SECONDS - phase_started))"
}

run_transition_package_phase() {
    local phase="$1"
    [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" && "$ROLLOUT_ROLE" == "transition" ]] ||
        fail "Transition package phase $phase requires role=transition installation-type=package"
    require_env EXPECTED_INSTALLER_IDENTITY
    require_file "$FINAL_ARTIFACT_MANIFEST"
    exec env REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_identity_transition_pkg.sh" "$phase" \
        --app "$APP_BUNDLE" \
        --artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --work-dir "$TRANSITION_PACKAGE_WORK_DIR" \
        --output "$TRANSITION_PKG"
}

build_tip_application_enclosure() {
    local phase_started=$SECONDS
    [[ "$ROLLOUT_INSTALLATION_TYPE" == "application" ]] ||
        fail "Normal Tip enclosure construction requires installation-type=application"
    require_command ditto
    require_command hdiutil
    require_command xcrun
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_file "$FINAL_ARTIFACT_MANIFEST"
    TMP_DIR="$(mktemp -d)"
    printf 'PHASE START [%s]: application ZIP/DMG construction role=%s tag=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROLLOUT_ROLE" "$TIP_TAG"
    local distribution_dir="$TMP_DIR/distribution"
    mkdir -p "$distribution_dir"
    ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    ditto -c -k --norsrc --keepParent "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
    validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Final tip distribution" "$SIGNING_TEAM_ID"
    hdiutil create -volname "$DISPLAY_NAME Tip" -srcfolder "$distribution_dir" -ov -format UDZO "$DMG"
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    printf 'PHASE COMPLETE [%s]: application ZIP/DMG construction elapsed-seconds=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((SECONDS - phase_started))"
}

finalize_tip_release_assets() {
    local phase_started=$SECONDS
    require_command curl
    require_command plutil
    require_command python3
    require_command shasum
    require_command stat
    require_command xcrun
    require_env SPARKLE_PRIVATE_KEY
    require_file "$SIGN_UPDATE"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"
    require_file "$FINAL_ARTIFACT_MANIFEST"
    require_file "$FINAL_METADATA"
    TMP_DIR="$(mktemp -d)"
    local checksum_assets=()
    printf 'PHASE START [%s]: release enclosure finalization role=%s installation-type=%s tag=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROLLOUT_ROLE" "$ROLLOUT_INSTALLATION_TYPE" "$TIP_TAG"

    if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
        require_file "$TRANSITION_PKG"
        checksum_assets+=("$(basename "$TRANSITION_PKG")")
    else
        require_file "$UPDATE_ZIP"
        require_file "$DMG"
        checksum_assets+=("$(basename "$UPDATE_ZIP")" "$(basename "$DMG")")
    fi

    generate_tip_rollout_appcast
    checksum_assets+=(
        "$(basename "$APPCAST")"
        "$(basename "$FINAL_ARTIFACT_MANIFEST")"
        "$(basename "$FINAL_METADATA")"
        "$(basename "$ROLLOUT_MANIFEST")"
        tip-release-context.json
        tip-release-context.json.sha256
    )
    (cd "$DIST_DIR" && shasum -a 256 "${checksum_assets[@]}" > "$(basename "$CHECKSUMS")")
    printf 'PHASE COMPLETE [%s]: release enclosure finalization elapsed-seconds=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((SECONDS - phase_started))"
    printf 'OK: signed, notarized, and finalized Tip %s artifact %s.\n' "$ROLLOUT_ROLE" "$TIP_TAG"
}

validate_tip_publish_assets() {
    require_command python3
    require_file "$PUBLICATION_TOOL"
    require_env REPOPROMPT_TIP_RELEASE_CONTEXT
    require_env REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE
    require_env REPOPROMPT_TIP_STABLE_APPCAST
    require_env REPOPROMPT_EXPECTED_CONTEXT_SHA256
    require_env REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT
    require_env REPOPROMPT_EXPECTED_TOOLING_COMMIT
    [[ -n "$APPROVED_SOURCE_ROOT" ]] || fail "Missing required environment variable: REPOPROMPT_APPROVED_SOURCE_ROOT"
    DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
    local args=(
        validate-local-assets
        --context "$REPOPROMPT_TIP_RELEASE_CONTEXT"
        --digest "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE"
        --stable-appcast "$REPOPROMPT_TIP_STABLE_APPCAST"
        --expected-context-sha256 "$REPOPROMPT_EXPECTED_CONTEXT_SHA256"
        --expected-approved-source-commit "$REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT"
        --expected-tooling-commit "$REPOPROMPT_EXPECTED_TOOLING_COMMIT"
        --approved-source-root "$APPROVED_SOURCE_ROOT"
        --trusted-tooling-root "$TRUSTED_ROOT"
        --dist-dir "$DIST_DIR"
    )
    if [[ -n "${REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256:-}" ]]; then
        args+=(--expected-sha256sums-sha256 "$REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256")
    fi
    if [[ -n "${REPOPROMPT_TIP_ASSET_GITHUB_OUTPUT:-}" ]]; then
        args+=(--github-output "$REPOPROMPT_TIP_ASSET_GITHUB_OUTPUT")
    fi
    exec python3 "$PUBLICATION_TOOL" "${args[@]}"
}

publish_tip() {
    require_command python3
    require_env TIP_GH_TOKEN
    require_env REPOPROMPT_EXPECTED_CONTEXT_SHA256
    require_env REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT
    require_env REPOPROMPT_EXPECTED_TOOLING_COMMIT
    require_env REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256
    require_file "$PUBLICATION_TOOL"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/supervise_release_phase.py"
    DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
    exec python3 "$PUBLICATION_TOOL" publish \
        --context "$REPOPROMPT_TIP_RELEASE_CONTEXT" \
        --digest "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" \
        --stable-appcast "$REPOPROMPT_TIP_STABLE_APPCAST" \
        --expected-context-sha256 "$REPOPROMPT_EXPECTED_CONTEXT_SHA256" \
        --expected-approved-source-commit "$REPOPROMPT_EXPECTED_APPROVED_SOURCE_COMMIT" \
        --expected-tooling-commit "$REPOPROMPT_EXPECTED_TOOLING_COMMIT" \
        --approved-source-root "$APPROVED_SOURCE_ROOT" \
        --trusted-tooling-root "$TRUSTED_ROOT" \
        --dist-dir "$DIST_DIR" \
        --expected-sha256sums-sha256 "$REPOPROMPT_EXPECTED_TIP_SHA256SUMS_SHA256" \
        --token-env TIP_GH_TOKEN \
        --command-timeout-seconds "${TIP_PUBLICATION_COMMAND_TIMEOUT_SECONDS:-300}" \
        --asset-timeout-seconds "${TIP_PUBLICATION_ASSET_TIMEOUT_SECONDS:-900}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        validate-assets) validate_tip_publish_assets ;;
        publish-tip) publish_tip ;;
        *) initialize_tip_release_context "$MODE" ;;
    esac
    case "$MODE" in
        stage) stage_tip ;;
        sign-application) sign_tip_application ;;
        notarize-application) notarize_tip_application ;;
        prepare-transition-payload) run_transition_package_phase prepare-payload ;;
        write-transition-component-plist) run_transition_package_phase write-component-plist ;;
        build-transition-component) run_transition_package_phase build-component ;;
        build-transition-product) run_transition_package_phase build-product ;;
        sign-transition-package) run_transition_package_phase sign-package ;;
        notarize-transition-package) run_transition_package_phase notarize-package ;;
        staple-transition-package) run_transition_package_phase staple-package ;;
        validate-transition-package) run_transition_package_phase validate-package ;;
        expand-transition-package) run_transition_package_phase expand-package ;;
        compare-transition-payload) run_transition_package_phase compare-payload ;;
        build-application-enclosure) build_tip_application_enclosure ;;
        finalize-assets) finalize_tip_release_assets ;;
        validate-assets|publish-tip) ;;
        *) fail "Usage: $0 stage|sign-application|notarize-application|prepare-transition-payload|write-transition-component-plist|build-transition-component|build-transition-product|sign-transition-package|notarize-transition-package|staple-transition-package|validate-transition-package|expand-transition-package|compare-transition-payload|build-application-enclosure|finalize-assets|validate-assets|publish-tip" ;;
    esac
fi
