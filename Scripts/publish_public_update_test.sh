#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source "$ROOT_DIR/version.env"
set +a

PUBLIC_UPDATE_REPOSITORY="${PUBLIC_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-updates}"
PUBLIC_UPDATE_TAG="${PUBLIC_UPDATE_TAG:-v${MARKETING_VERSION}-private-smoke.${BUILD_NUMBER}}"
PUBLIC_UPDATE_BASE_URL="https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$PUBLIC_UPDATE_TAG"
PUBLIC_FEED_URL="$PUBLIC_UPDATE_BASE_URL/appcast.xml"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-repoprompt-ce}"
UPDATE_ZIP="${1:-$ROOT_DIR/dist/${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}.zip}"
ARTIFACT_MANIFEST="${UPDATE_ZIP%.zip}-artifact-manifest.json"
GENERATE_APPCAST="$ROOT_DIR/Vendor/Sparkle/bin/generate_appcast"
TMP_DIR=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ "${CONFIRM_PUBLIC_UPDATE_TEST:-}" == "1" ]] ||
    fail "Set CONFIRM_PUBLIC_UPDATE_TEST=1 to acknowledge that this publishes a signed test update publicly."
[[ -f "$UPDATE_ZIP" ]] || fail "Missing update ZIP: $UPDATE_ZIP"
[[ -f "$ARTIFACT_MANIFEST" ]] || fail "Missing update artifact manifest: $ARTIFACT_MANIFEST"
[[ -x "$GENERATE_APPCAST" ]] || fail "Missing Sparkle generate_appcast tool: $GENERATE_APPCAST"
[[ -x "$ROOT_DIR/Scripts/validate_embedded_mcp_helper_layout.sh" ]] ||
    fail "Missing embedded MCP helper layout validator"

for command in codesign curl ditto gh plutil shasum xcrun; do
    require_command "$command"
done

visibility="$(gh repo view "$PUBLIC_UPDATE_REPOSITORY" --json visibility --jq .visibility)"
[[ "$visibility" == "PUBLIC" ]] || fail "Update repository must be public: $PUBLIC_UPDATE_REPOSITORY"

if gh release view "$PUBLIC_UPDATE_TAG" --repo "$PUBLIC_UPDATE_REPOSITORY" >/dev/null 2>&1; then
    fail "Public update tag already exists and will not be overwritten: $PUBLIC_UPDATE_TAG"
fi

TMP_DIR="$(mktemp -d)"
EXTRACT_DIR="$TMP_DIR/extract"
APPCAST_DIR="$TMP_DIR/appcast"
APPCAST="$TMP_DIR/appcast.xml"
CHECKSUMS="$TMP_DIR/SHA256SUMS"
mkdir -p "$EXTRACT_DIR" "$APPCAST_DIR"

ditto -x -k "$UPDATE_ZIP" "$EXTRACT_DIR"
APP_BUNDLE="$EXTRACT_DIR/$DISPLAY_NAME.app"
[[ -d "$APP_BUNDLE" ]] || fail "Update ZIP does not contain $DISPLAY_NAME.app at its root"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
signature_details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
team_identifier="$(printf '%s\n' "$signature_details" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:' ||
    fail "Update app is not signed with a Developer ID Application certificate."
[[ "$team_identifier" == "$SIGNING_TEAM_ID" ]] ||
    fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team_identifier:-<missing>}"
xcrun stapler validate "$APP_BUNDLE"
"$ROOT_DIR/Scripts/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Public updater ZIP MCP helper layout"
"$ROOT_DIR/Scripts/validate_app_architectures.sh" "$APP_BUNDLE" "arm64,x86_64" "Public updater ZIP app"
"$ROOT_DIR/Scripts/write_app_artifact_manifest.py" verify \
    --app "$APP_BUNDLE" \
    --manifest "$ARTIFACT_MANIFEST" \
    --expected-architectures "arm64,x86_64"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist")"
marketing_version="$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")"
[[ "$bundle_identifier" == "$BUNDLE_ID" ]] ||
    fail "Bundle identifier mismatch: expected $BUNDLE_ID, got $bundle_identifier"
[[ "$marketing_version" == "$MARKETING_VERSION" ]] ||
    fail "Marketing version mismatch: expected $MARKETING_VERSION, got $marketing_version"
[[ "$build_number" == "$BUILD_NUMBER" ]] ||
    fail "Build number mismatch: expected $BUILD_NUMBER, got $build_number"

cp "$UPDATE_ZIP" "$APPCAST_DIR/"
"$GENERATE_APPCAST" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "$PUBLIC_UPDATE_BASE_URL/" \
    -o "$APPCAST" \
    "$APPCAST_DIR"

(
    cd "$(dirname "$UPDATE_ZIP")"
    shasum -a 256 "$(basename "$UPDATE_ZIP")"
    cd "$TMP_DIR"
    shasum -a 256 "$(basename "$APPCAST")"
    cd "$(dirname "$ARTIFACT_MANIFEST")"
    shasum -a 256 "$(basename "$ARTIFACT_MANIFEST")"
) > "$CHECKSUMS"

gh release create "$PUBLIC_UPDATE_TAG" \
    "$UPDATE_ZIP" \
    "$APPCAST" \
    "$CHECKSUMS" \
    "$ARTIFACT_MANIFEST" \
    --repo "$PUBLIC_UPDATE_REPOSITORY" \
    --target main \
    --latest=false \
    --title "RepoPrompt CE $MARKETING_VERSION private-repo updater smoke" \
    --notes "Public updater smoke artifact for RepoPrompt CE $MARKETING_VERSION ($BUILD_NUMBER). Source remains private during release validation."

curl --fail --location --retry 8 --retry-delay 3 --retry-all-errors \
    "$PUBLIC_FEED_URL" \
    --output "$TMP_DIR/published-appcast.xml"
grep -q "$PUBLIC_UPDATE_BASE_URL/" "$TMP_DIR/published-appcast.xml" ||
    fail "Published appcast does not point at the expected public update URL."

printf 'Published public RepoPrompt CE updater smoke release: %s\n' "$PUBLIC_UPDATE_TAG"
printf 'Isolated smoke feed URL: %s\n' "$PUBLIC_FEED_URL"
