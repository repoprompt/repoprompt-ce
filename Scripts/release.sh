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
ARCHIVE_BASENAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
APPCAST="$DIST_DIR/appcast.xml"
CHECKSUMS="$DIST_DIR/SHA256SUMS"
SIGNED_TEST_PROVENANCE="$DIST_DIR/$ARCHIVE_BASENAME-signed-test-provenance.json"
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
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/sync_mcp_cli_version.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/extract_staged_release.py"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    require_file "$RUN_WITHOUT_GITHUB_TOKENS"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_signed_test_build_ref.sh"
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

package_release_candidate() {
    resolve_without_lockfile_drift
    run_preflight
    require_command ditto
    prepare_dist

    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    run_preflight
    validate_packaged_legal "$APP_BUNDLE"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"
    (
        cd "$DIST_DIR"
        shasum -a 256 "$(basename "$UPDATE_ZIP")" > "$(basename "$CHECKSUMS")"
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
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    run_preflight
    validate_packaged_legal "$APP_BUNDLE"
    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/release-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
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

stage_signed_test_build() {
    require_env RELEASE_COMMIT
    require_command ditto
    unset GH_TOKEN GITHUB_TOKEN SOURCE_GH_TOKEN
    resolve_without_lockfile_drift
    run_preflight
    prepare_dist
    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    run_preflight
    validate_packaged_legal "$APP_BUNDLE"
    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/signed-test-build-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
    cp "$ROOT_DIR/version.env" "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$stage_root/"
    cp -R "$ROOT_DIR/ThirdPartyLicenses" "$stage_root/"
    printf '%s\n' "$RELEASE_COMMIT" > "$stage_root/RELEASE_COMMIT"
    ditto -c -k --norsrc "$stage_root" "$STAGE_ARCHIVE"
    (
        cd "$DIST_DIR"
        shasum -a 256 "$(basename "$STAGE_ARCHIVE")" > "$(basename "$STAGE_ARCHIVE_CHECKSUM")"
    )
    printf 'OK: secret-free signed test build source staged for %s.\n' "$RELEASE_COMMIT"
    printf 'Created staged signed test build artifact: %s\n' "$STAGE_ARCHIVE"
}

verify_signed_test_build_inputs() {
    require_command python3
    require_env RELEASE_COMMIT
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_env SIGNED_TEST_SOURCE_REF
    require_env SIGNED_TEST_REACHABLE_REFS
    require_env SIGNED_TEST_TOOLING_COMMIT
    require_env SIGNED_TEST_WORKFLOW_RUN_URL
    require_env SIGNED_TEST_STAGED_ARCHIVE_NAME
    require_env SIGNED_TEST_STAGED_ARCHIVE_SHA256
    require_file "$REPOPROMPT_PROVISIONING_PROFILE"
    require_file "$NOTARYTOOL_PRIVATE_KEY"
}

sha256_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

write_signed_test_build_provenance() {
    local zip_name dmg_name checksums_name
    zip_name="$(basename "$UPDATE_ZIP")"
    dmg_name="$(basename "$DMG")"
    checksums_name="$(basename "$CHECKSUMS")"

    SIGNED_TEST_PROVENANCE_PATH="$SIGNED_TEST_PROVENANCE" \
    SIGNED_TEST_ZIP_NAME="$zip_name" \
    SIGNED_TEST_ZIP_SHA256="$(sha256_file "$UPDATE_ZIP")" \
    SIGNED_TEST_DMG_NAME="$dmg_name" \
    SIGNED_TEST_DMG_SHA256="$(sha256_file "$DMG")" \
    SIGNED_TEST_CHECKSUMS_NAME="$checksums_name" \
    SIGNED_TEST_CHECKSUMS_SHA256="$(sha256_file "$CHECKSUMS")" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

reachable_refs = [ref for ref in os.environ["SIGNED_TEST_REACHABLE_REFS"].split(",") if ref]
provenance = {
    "schema_version": 1,
    "artifact": "RepoPrompt CE signed test build",
    "requested_ref": os.environ["SIGNED_TEST_SOURCE_REF"],
    "resolved_source_commit": os.environ["RELEASE_COMMIT"],
    "trusted_tooling_commit": os.environ["SIGNED_TEST_TOOLING_COMMIT"],
    "workflow_run_url": os.environ["SIGNED_TEST_WORKFLOW_RUN_URL"],
    "signing_mode": "developer-id-signed-test-build",
    "source_reachable_refs": reachable_refs,
    "hash_algorithm": "SHA-256",
    "artifacts": {
        "zip": {
            "file": os.environ["SIGNED_TEST_ZIP_NAME"],
            "sha256": os.environ["SIGNED_TEST_ZIP_SHA256"],
        },
        "dmg": {
            "file": os.environ["SIGNED_TEST_DMG_NAME"],
            "sha256": os.environ["SIGNED_TEST_DMG_SHA256"],
        },
        "checksums": {
            "file": os.environ["SIGNED_TEST_CHECKSUMS_NAME"],
            "sha256": os.environ["SIGNED_TEST_CHECKSUMS_SHA256"],
        },
        "staged_source_archive": {
            "file": os.environ["SIGNED_TEST_STAGED_ARCHIVE_NAME"],
            "sha256": os.environ["SIGNED_TEST_STAGED_ARCHIVE_SHA256"],
        },
    },
}
Path(os.environ["SIGNED_TEST_PROVENANCE_PATH"]).write_text(
    json.dumps(provenance, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

publish_staged_release() {
    require_command ditto
    require_command gh
    require_command hdiutil
    require_command xcrun
    verify_publish_inputs
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    TMP_DIR="$(mktemp -d)"

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

    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"

    local dmg_staging="$TMP_DIR/dmg"
    mkdir -p "$dmg_staging"
    ditto "$APP_BUNDLE" "$dmg_staging/$APP_NAME.app"
    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$dmg_staging" -ov -format UDZO "$DMG"
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
            > "$(basename "$CHECKSUMS")"
    )

    "$CONTROL_PLANE_SCRIPTS_DIR/verify_remote_release_commit.sh" "$RELEASE_TAG" "$RELEASE_COMMIT"
    local release_args=(
        "$RELEASE_TAG"
        "$UPDATE_ZIP"
        "$DMG"
        "$APPCAST"
        "$CHECKSUMS"
        --verify-tag
        --title "$DISPLAY_NAME $MARKETING_VERSION"
        --generate-notes
        --notes "Release-Commit: \`$RELEASE_COMMIT\`"
        --repo "$GITHUB_REPOSITORY"
        --draft
        --target "$RELEASE_COMMIT"
    )
    gh release create "${release_args[@]}"
    printf 'Created draft GitHub release assets for %s.\n' "$RELEASE_TAG"
}

publish_signed_test_build() {
    require_command ditto
    require_command hdiutil
    require_command xcrun
    verify_signed_test_build_inputs
    TMP_DIR="$(mktemp -d)"

    [[ -d "$APP_BUNDLE" ]] || fail "Missing secret-free staged app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    prepare_dist
    validate_packaged_legal "$APP_BUNDLE"

    local notary_zip="$TMP_DIR/$ARCHIVE_BASENAME-signed-test-notarization.zip"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$notary_zip"
    submit_notarization "$notary_zip"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"

    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$UPDATE_ZIP"

    local dmg_staging="$TMP_DIR/dmg"
    mkdir -p "$dmg_staging"
    ditto "$APP_BUNDLE" "$dmg_staging/$APP_NAME.app"
    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$dmg_staging" -ov -format UDZO "$DMG"
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"

    (
        cd "$DIST_DIR"
        shasum -a 256 \
            "$(basename "$UPDATE_ZIP")" \
            "$(basename "$DMG")" \
            > "$(basename "$CHECKSUMS")"
    )
    write_signed_test_build_provenance

    printf 'Created signed test build ZIP: %s\n' "$UPDATE_ZIP"
    printf 'Created signed test build DMG: %s\n' "$DMG"
    printf 'Created signed test build provenance: %s\n' "$SIGNED_TEST_PROVENANCE"
    printf 'This artifact is signed and notarized for testing only. It is not a GitHub Release or stable update.\n'
}

case "$MODE" in
    sync-cli-version) sync_mcp_cli_version ;;
    preflight) run_preflight ;;
    artifact) package_release_candidate ;;
    stage-publish) stage_publish_release ;;
    publish-staged) publish_staged_release ;;
    stage-test-build) stage_signed_test_build ;;
    publish-test-build) publish_signed_test_build ;;
    *) fail "Usage: $0 sync-cli-version|preflight|artifact|stage-publish|publish-staged|stage-test-build|publish-test-build" ;;
esac
