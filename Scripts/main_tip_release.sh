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

ROLLOUT_TOOL="$CONTROL_PLANE_SCRIPTS_DIR/stable_rollout.py"
APPLE_IDENTITY_POLICY="$CONTROL_PLANE_SCRIPTS_DIR/apple_identity_policy.json"
ROLLOUT_DECLARATION="$ROOT_DIR/tip-rollout.json"
[[ -f "$ROLLOUT_TOOL" && -f "$APPLE_IDENTITY_POLICY" && -f "$ROLLOUT_DECLARATION" ]] ||
    fail "Tip identity rollout authority is incomplete"
eval "$(python3 "$ROLLOUT_TOOL" packaging-context \
    --declaration "$ROLLOUT_DECLARATION" \
    --policy "$APPLE_IDENTITY_POLICY" \
    --version-env "$ROOT_DIR/version.env")"
[[ "$ROLLOUT_CHANNEL" == "tip" ]] || fail "Tip release requires a Tip rollout declaration"
TIP_PUBLISH_INSTALLATION_TYPE="${TIP_PUBLISH_INSTALLATION_TYPE:-$ROLLOUT_INSTALLATION_TYPE}"

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
[[ "$TIP_UPDATE_REPOSITORY" == "$ROLLOUT_UPDATE_REPOSITORY" ]] ||
    fail "TIP_UPDATE_REPOSITORY must match the reviewed identity policy"
TIP_GH_TOKEN="${TIP_GH_TOKEN:-}"

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
ARCHIVE_BASENAME="$APP_NAME-tip-$TIP_SHORT_SHA-$TIP_BUILD_NUMBER"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
TRANSITION_PKG="$DIST_DIR/$ARCHIVE_BASENAME.pkg"
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
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
SIGN_UPDATE="$TRUSTED_ROOT/Vendor/Sparkle/bin/sign_update"
PUBLISH_TIP_RELEASE="$CONTROL_PLANE_SCRIPTS_DIR/publish_tip_release.sh"
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
    local signed_team_identifier="${4:-}"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$app_bundle" "$label MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$app_bundle" "arm64,x86_64" "$label architectures"
    local codex_verification_args=(
        --manifest "$CODEX_MANIFEST" verify-bundle
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
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
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

generate_tip_rollout_appcast() {
    local predecessor_dir="$TMP_DIR/predecessors"
    mkdir -p "$predecessor_dir"
    # macOS still ships Bash 3.2, where expanding an empty array under
    # `set -u` aborts the script. Keep this argument vector non-empty for the
    # preparer role, whose rollout intentionally has no predecessors.
    local rollout_generate_args=(--declaration "$ROLLOUT_DECLARATION")
    local position=0 role tag digest path actual_digest
    while IFS=$'\t' read -r role tag digest; do
        [[ -n "$role" ]] || continue
        position=$((position + 1))
        path="$predecessor_dir/$position-identity-rollout.json"
        curl --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 30 \
            "https://github.com/$TIP_UPDATE_REPOSITORY/releases/download/$tag/identity-rollout.json" \
            --output "$path"
        actual_digest="$(shasum -a 256 "$path" | awk '{print $1}')"
        [[ "$actual_digest" == "$digest" ]] ||
            fail "Tip predecessor $role manifest digest mismatch for $tag"
        rollout_generate_args+=(--predecessor-manifest "$path")
    done < <(python3 "$ROLLOUT_TOOL" predecessor-values --declaration "$ROLLOUT_DECLARATION")

    local enclosure_signature
    enclosure_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE" |
        tr -d '\r\n')"
    [[ -n "$enclosure_signature" ]] || fail "Unable to sign Tip rollout enclosure"

    python3 "$ROLLOUT_TOOL" generate \
        "${rollout_generate_args[@]}" \
        --policy "$APPLE_IDENTITY_POLICY" \
        --version-env "$ROOT_DIR/version.env" \
        --release-tag "$TIP_TAG" \
        --release-commit "$TIP_COMMIT" \
        --migration-phase "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        --allowed-roles legacy,preparer,transition,successor \
        --enclosure "$ENCLOSURE" \
        --enclosure-basename "$ARCHIVE_BASENAME" \
        --enclosure-signature "$enclosure_signature" \
        --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --appcast-output "$APPCAST" \
        --manifest-output "$ROLLOUT_MANIFEST"
    python3 "$ROLLOUT_TOOL" validate \
        "${rollout_generate_args[@]}" \
        --policy "$APPLE_IDENTITY_POLICY" \
        --version-env "$ROOT_DIR/version.env" \
        --release-tag "$TIP_TAG" \
        --release-commit "$TIP_COMMIT" \
        --migration-phase "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        --allowed-roles legacy,preparer,transition,successor \
        --enclosure "$ENCLOSURE" \
        --enclosure-basename "$ARCHIVE_BASENAME" \
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

sign_tip() {
    require_command curl
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
    [[ "$SIGN_IDENTITY" == "$EXPECTED_SIGN_IDENTITY" ]] ||
        fail "SIGN_IDENTITY does not match the reviewed $ROLLOUT_IDENTITY identity"
    if [[ "$ROLLOUT_ROLE" == "transition" ]]; then
        require_env EXPECTED_INSTALLER_IDENTITY
    fi
    [[ "$RELEASE_COMMIT" == "$TIP_COMMIT" ]] || fail "RELEASE_COMMIT must match TIP_COMMIT"
    [[ -d "$APP_BUNDLE" ]] || fail "Missing staged tip app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
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
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
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
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final tip Developer ID app" "$SIGNING_TEAM_ID"
    upload_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"

    local checksum_assets=()
    if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
        REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG=1 \
            "$CONTROL_PLANE_SCRIPTS_DIR/build_identity_transition_pkg.sh" build \
            --app "$APP_BUNDLE" \
            --output "$TRANSITION_PKG" \
            --installer-identity "$EXPECTED_INSTALLER_IDENTITY"
        checksum_assets+=("$(basename "$TRANSITION_PKG")")
    else
        local distribution_dir="$TMP_DIR/distribution"
        mkdir -p "$distribution_dir"
        ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
        ditto -c -k --norsrc --keepParent "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
        validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Final tip distribution" "$SIGNING_TEAM_ID"
        hdiutil create -volname "$DISPLAY_NAME Tip" -srcfolder "$distribution_dir" -ov -format UDZO "$DMG"
        submit_notarization "$DMG"
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        checksum_assets+=("$(basename "$UPDATE_ZIP")" "$(basename "$DMG")")
    fi

    generate_tip_rollout_appcast
    checksum_assets+=(
        "$(basename "$APPCAST")"
        "$(basename "$FINAL_ARTIFACT_MANIFEST")"
        "$(basename "$FINAL_METADATA")"
        "$(basename "$ROLLOUT_MANIFEST")"
    )
    (cd "$DIST_DIR" && shasum -a 256 "${checksum_assets[@]}" > "$(basename "$CHECKSUMS")")
    printf 'OK: signed and notarized Tip %s artifact %s.\n' "$ROLLOUT_ROLE" "$TIP_TAG"
}

tip_publish_assets() {
    TIP_PUBLISH_ASSETS=("$APPCAST" "$CHECKSUMS" "$FINAL_ARTIFACT_MANIFEST" "$FINAL_METADATA" "$ROLLOUT_MANIFEST")
    case "$TIP_PUBLISH_INSTALLATION_TYPE" in
        package) TIP_PUBLISH_ASSETS+=("$TRANSITION_PKG") ;;
        application) TIP_PUBLISH_ASSETS+=("$UPDATE_ZIP" "$DMG") ;;
        *) fail "TIP_PUBLISH_INSTALLATION_TYPE must be application or package" ;;
    esac
}

validate_tip_publish_assets() {
    require_command python3
    tip_publish_assets
    local expected_basenames=()
    local path
    for path in "${TIP_PUBLISH_ASSETS[@]}"; do
        expected_basenames+=("$(basename "$path")")
    done
    python3 - "$DIST_DIR" "${expected_basenames[@]}" <<'PYTHON'
import sys
from pathlib import Path

dist = Path(sys.argv[1])
expected = set(sys.argv[2:])
if not dist.is_dir():
    raise SystemExit(f"ERROR: Missing Tip publish directory: {dist}")
actual = {entry.name for entry in dist.iterdir()}
missing = sorted(expected - actual)
extra = sorted(actual - expected)
if missing or extra:
    raise SystemExit(
        "ERROR: Tip publish asset inventory mismatch: "
        f"missing={missing or 'none'} extra={extra or 'none'}"
    )
for name in sorted(expected):
    path = dist / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"ERROR: Tip publish asset must be a regular non-symlink file: {path}")
print(f"OK: Tip publish asset inventory contains exactly {len(expected)} files.")
PYTHON
    (cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$CHECKSUMS")")
    python3 - "$CHECKSUMS" "${expected_basenames[@]}" <<'PYTHON'
import re
import sys
from pathlib import Path

checksum_path = Path(sys.argv[1])
expected = set(sys.argv[2:]) - {checksum_path.name}
actual = set()
for line in checksum_path.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
    if not match:
        raise SystemExit(f"ERROR: malformed SHA256SUMS line: {line!r}")
    name = match.group(2)
    if name in actual:
        raise SystemExit(f"ERROR: duplicate SHA256SUMS entry: {name}")
    actual.add(name)
if actual != expected:
    raise SystemExit(
        "ERROR: SHA256SUMS entry set mismatch: "
        f"missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
    )
PYTHON
}

publish_tip() {
    require_env TIP_GH_TOKEN
    require_env TIP_SOURCE_REPOSITORY
    require_env TIP_SOURCE_BRANCH
    require_file "$PUBLISH_TIP_RELEASE"
    case "$TIP_UPDATE_REPOSITORY" in
        repoprompt/repoprompt-ce|repoprompt/repoprompt-ce-updates)
            fail "TIP_UPDATE_REPOSITORY must not target the source or stable update repository"
            ;;
    esac
    validate_tip_publish_assets
    TIP_GH_TOKEN="$TIP_GH_TOKEN" \
    TIP_UPDATE_REPOSITORY="$TIP_UPDATE_REPOSITORY" \
    TIP_SOURCE_REPOSITORY="$TIP_SOURCE_REPOSITORY" \
    TIP_SOURCE_BRANCH="$TIP_SOURCE_BRANCH" \
    TIP_COMMIT="$TIP_COMMIT" \
    TIP_TAG="$TIP_TAG" \
    TIP_BUILD_NUMBER="$TIP_BUILD_NUMBER" \
    TIP_PUBLISH_INSTALLATION_TYPE="$TIP_PUBLISH_INSTALLATION_TYPE" \
    TIP_RELEASE_TITLE="$DISPLAY_NAME Tip $ROLLOUT_ROLE $TIP_SHORT_SHA" \
    TIP_RELEASE_NOTES="Tip identity rollout role \`$ROLLOUT_ROLE\` from main commit \`$TIP_COMMIT\` with build number \`$TIP_BUILD_NUMBER\`." \
    TIP_EXPECTED_ROLLOUT_ROLE="$ROLLOUT_ROLE" \
    TIP_EXPECTED_SIGNING_IDENTITY="$ROLLOUT_IDENTITY" \
    TIP_EXPECTED_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        exec "$PUBLISH_TIP_RELEASE" "${TIP_PUBLISH_ASSETS[@]}"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        stage) stage_tip ;;
        sign) sign_tip ;;
        validate-assets) validate_tip_publish_assets ;;
        publish-tip) publish_tip ;;
        *) fail "Usage: $0 stage|sign|validate-assets|publish-tip" ;;
    esac
fi
