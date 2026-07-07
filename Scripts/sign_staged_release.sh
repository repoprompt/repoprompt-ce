#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
METADATA_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-$ROOT_DIR}"
source "$SCRIPT_DIR/load_release_metadata.sh"
load_release_metadata "$METADATA_ROOT"

APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
TRUSTED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS_TEMPLATE="$TRUSTED_ROOT/AppBundle/RepoPrompt.entitlements.template"
TRUSTED_SPARKLE_FRAMEWORK="$TRUSTED_ROOT/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
STAGED_SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "${SIGN_IDENTITY:-}" ]] || fail "Missing required environment variable: SIGN_IDENTITY"
[[ -f "${REPOPROMPT_PROVISIONING_PROFILE:-}" ]] ||
    fail "Missing RepoPrompt CE Developer ID provisioning profile"
[[ -d "$APP_BUNDLE" ]] || fail "Missing staged app bundle: $APP_BUNDLE"
REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
    "$SCRIPT_DIR/validate_staged_release.sh"
REPOPROMPT_RELEASE_SOURCE_ROOT="$TRUSTED_ROOT" \
    "$SCRIPT_DIR/verify_sparkle_vendor.sh"

rm -rf "$STAGED_SPARKLE_FRAMEWORK"
mkdir -p "$(dirname "$STAGED_SPARKLE_FRAMEWORK")"
ditto "$TRUSTED_SPARKLE_FRAMEWORK" "$STAGED_SPARKLE_FRAMEWORK"
REPOPROMPT_RELEASE_SOURCE_ROOT="$TRUSTED_ROOT" \
    "$SCRIPT_DIR/verify_sparkle_vendor.sh" "$STAGED_SPARKLE_FRAMEWORK"
"$SCRIPT_DIR/validate_app_architectures.sh" \
    "$APP_BUNDLE" \
    "arm64,x86_64" \
    "Trusted Sparkle replacement pre-sign app"

profile_plist="$(mktemp)"
app_entitlements="$(mktemp)"
signed_entitlements="$(mktemp)"
canonical_app_entitlements="$(mktemp)"
canonical_signed_entitlements="$(mktemp)"
cleanup() {
    rm -f "$profile_plist" "$app_entitlements" "$signed_entitlements" \
        "$canonical_app_entitlements" "$canonical_signed_entitlements"
}
trap cleanup EXIT

security cms -D -i "$REPOPROMPT_PROVISIONING_PROFILE" -o "$profile_plist"
profile_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null || true)"
[[ "$profile_app_identifier" == "$SIGNING_TEAM_ID.$BUNDLE_ID" ]] ||
    fail "Provisioning profile app identifier mismatch: expected $SIGNING_TEAM_ID.$BUNDLE_ID, got ${profile_app_identifier:-<missing>}"
cp "$REPOPROMPT_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
python3 - "$ENTITLEMENTS_TEMPLATE" "$app_entitlements" "$BUNDLE_ID" "$SIGNING_TEAM_ID" <<'PYTHON'
import sys
from pathlib import Path

template, output, bundle_id, team_id = sys.argv[1:]
text = Path(template).read_text(encoding="utf-8")
text = text.replace("__BUNDLE_ID__", bundle_id).replace("__SIGNING_TEAM_ID__", team_id)
Path(output).write_text(text, encoding="utf-8")
PYTHON
plutil -lint "$app_entitlements"
plutil -replace RepoPromptDebugSecureStorageBackend -string keychain "$APP_BUNDLE/Contents/Info.plist"
plutil -replace RepoPromptSigningMode -string developer-id "$APP_BUNDLE/Contents/Info.plist"

# Official telemetry is gated on the protected DSN. Keep unsigned staging and
# local release-candidate artifacts inert, and never echo or manifest the value.
if [[ -n "${SENTRY_DSN:-}" ]]; then
    plutil -replace RepoPromptSentryDSN -string "$SENTRY_DSN" "$APP_BUNDLE/Contents/Info.plist"
fi

sign_path() {
    local path="$1"
    shift
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$@" "$path"
}

sign_sparkle_framework() {
    local framework="$1"
    sign_path "$framework/Versions/B/XPCServices/Installer.xpc"
    sign_path "$framework/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
    sign_path "$framework/Versions/B/Autoupdate"
    sign_path "$framework/Versions/B/Updater.app"
    sign_path "$framework"
}

sign_sparkle_framework "$STAGED_SPARKLE_FRAMEWORK"
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
sign_path "$APP_BUNDLE" --entitlements "$app_entitlements"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
"$SCRIPT_DIR/validate_app_architectures.sh" \
    "$APP_BUNDLE" \
    "arm64,x86_64" \
    "Developer ID staged app post-sign"
"$SCRIPT_DIR/write_app_artifact_manifest.py" write \
    --app "$APP_BUNDLE" \
    --output "$ARTIFACT_MANIFEST" \
    --expected-architectures "arm64,x86_64"
codesign -d --entitlements :- "$APP_BUNDLE" > "$signed_entitlements"
plutil -convert xml1 -o "$canonical_app_entitlements" "$app_entitlements"
plutil -convert xml1 -o "$canonical_signed_entitlements" "$signed_entitlements"
cmp "$canonical_app_entitlements" "$canonical_signed_entitlements" ||
    fail "Signed app entitlements do not match trusted release policy"
"$SCRIPT_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Developer ID staged app MCP helper layout"

signature_details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
identifier="$(printf '%s\n' "$signature_details" | awk -F= '/^Identifier=/{print $2; exit}')"
team="$(printf '%s\n' "$signature_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
[[ "$identifier" == "$BUNDLE_ID" ]] ||
    fail "Signed app identifier mismatch: expected $BUNDLE_ID, got ${identifier:-<missing>}"
[[ "$team" == "$SIGNING_TEAM_ID" ]] ||
    fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team:-<missing>}"

printf 'OK: staged app signed for Developer ID distribution.\n'
