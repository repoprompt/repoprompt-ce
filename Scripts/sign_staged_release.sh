#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
METADATA_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-$ROOT_DIR}"
CODEX_MANIFEST="$METADATA_ROOT/Vendor/Codex/manifest.json"
source "$SCRIPT_DIR/load_release_metadata.sh"
load_release_metadata "$METADATA_ROOT"

APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
TRUSTED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPLE_IDENTITY_POLICY="$SCRIPT_DIR/apple_identity_policy.json"
ROLLOUT_TOOL="$SCRIPT_DIR/stable_rollout.py"
ENTITLEMENTS_TEMPLATE="$TRUSTED_ROOT/AppBundle/RepoPrompt.entitlements.template"
CODEX_V8_ENTITLEMENTS="$TRUSTED_ROOT/AppBundle/CodexV8JIT.entitlements"
TRUSTED_SPARKLE_FRAMEWORK="$TRUSTED_ROOT/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
STAGED_SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
CODEX_BUNDLE="$APP_BUNDLE/Contents/Resources/BundledRuntimes/Codex"
ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
IDENTITY_MIGRATION_ANCHOR_DESTINATION="$APP_BUNDLE/Contents/Resources/IdentityMigration/RepoPromptIdentityAnchor"
IDENTITY_MIGRATION_TARGET_IDENTIFIER="com.repoprompt.ce"
IDENTITY_MIGRATION_TARGET_TEAM_ID="69N6K965SF"
IDENTITY_MIGRATION_TARGET_REQUIREMENT='anchor apple generic and identifier "com.repoprompt.ce" and certificate leaf[subject.OU] = "69N6K965SF" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'

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
python3 "$SCRIPT_DIR/codex_runtime_artifact.py" \
    --manifest "$CODEX_MANIFEST" verify-bundle \
    --arch all \
    --bundle "$CODEX_BUNDLE"

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
plutil -lint "$CODEX_V8_ENTITLEMENTS"
plutil -replace RepoPromptDebugSecureStorageBackend -string keychain "$APP_BUNDLE/Contents/Info.plist"
signing_mode_marker="$(python3 "$ROLLOUT_TOOL" signing-mode \
    --policy "$APPLE_IDENTITY_POLICY" \
    --bundle-id "$BUNDLE_ID" \
    --team-id "$SIGNING_TEAM_ID")" ||
    fail "Release bundle/team pair is not a reviewed Apple identity"
plutil -replace RepoPromptSigningMode -string "$signing_mode_marker" "$APP_BUNDLE/Contents/Info.plist"

identity_migration_phase="$(
    plutil -extract RepoPromptIdentityMigrationPhase raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null ||
        printf 'disabled\n'
)"
expected_identity_migration_phase="${REPOPROMPT_IDENTITY_MIGRATION_PHASE:-disabled}"
[[ "$identity_migration_phase" == "$expected_identity_migration_phase" ]] ||
    fail "Staged identity migration phase mismatch: expected $expected_identity_migration_phase, got $identity_migration_phase"
case "$identity_migration_phase" in
disabled)
    ;;
legacy-preparer)
    [[ "$BUNDLE_ID" == "com.pvncher.repoprompt.ce" ]] ||
        fail "Legacy identity preparer must retain bundle identifier com.pvncher.repoprompt.ce"
    [[ "$SIGNING_TEAM_ID" == "648A27MST5" ]] ||
        fail "Legacy identity preparer must retain signing Team ID 648A27MST5"
    identity_migration_anchor="${REPOPROMPT_IDENTITY_MIGRATION_ANCHOR:-}"
    [[ -n "$identity_migration_anchor" ]] ||
        fail "Legacy identity preparer signing requires REPOPROMPT_IDENTITY_MIGRATION_ANCHOR"
    [[ -f "$identity_migration_anchor" && ! -L "$identity_migration_anchor" ]] ||
        fail "Identity migration anchor must be a regular, non-symlink file"
    codesign --verify --strict --verbose=2 \
        -R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$identity_migration_anchor"
    anchor_signature_details="$(codesign -dv --verbose=4 "$identity_migration_anchor" 2>&1)"
    anchor_identifier="$(printf '%s\n' "$anchor_signature_details" | awk -F= '/^Identifier=/{print $2; exit}')"
    anchor_team="$(printf '%s\n' "$anchor_signature_details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    [[ "$anchor_identifier" == "$IDENTITY_MIGRATION_TARGET_IDENTIFIER" ]] ||
        fail "Identity migration anchor identifier mismatch: expected $IDENTITY_MIGRATION_TARGET_IDENTIFIER, got ${anchor_identifier:-<missing>}"
    [[ "$anchor_team" == "$IDENTITY_MIGRATION_TARGET_TEAM_ID" ]] ||
        fail "Identity migration anchor team mismatch: expected $IDENTITY_MIGRATION_TARGET_TEAM_ID, got ${anchor_team:-<missing>}"
    mkdir -p "$(dirname "$IDENTITY_MIGRATION_ANCHOR_DESTINATION")"
    ditto "$identity_migration_anchor" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"
    chmod 755 "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"
    [[ -f "$IDENTITY_MIGRATION_ANCHOR_DESTINATION" && ! -L "$IDENTITY_MIGRATION_ANCHOR_DESTINATION" ]] ||
        fail "Embedded identity migration anchor must be a regular, non-symlink file"
    codesign --verify --strict --verbose=2 \
        -R="$IDENTITY_MIGRATION_TARGET_REQUIREMENT" "$IDENTITY_MIGRATION_ANCHOR_DESTINATION"
    ;;
*)
    fail "Unsupported RepoPromptIdentityMigrationPhase: $identity_migration_phase"
    ;;
esac

# Telemetry is gated on DSN presence: only the official Developer ID publish job receives the
# protected SENTRY_DSN secret, and only here is it baked into the signed bundle. The value is never
# echoed or written to the artifact manifest.
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
# Manifest-driven Codex signing: each Mach-O gets exactly the release entitlement
# profile pinned in Vendor/Codex/manifest.json. The trusted V8 JIT allowlist is a
# repository-owned plist; vendor entitlement metadata is never preserved blindly.
codex_signing_plan="$(python3 "$SCRIPT_DIR/codex_runtime_artifact.py" \
    --manifest "$CODEX_MANIFEST" list-bundle-signing-plan --arch all)"
while IFS=$'\t' read -r relative_path entitlement_profile; do
    [[ -n "$relative_path" ]] || continue
    case "$entitlement_profile" in
    v8-jit)
        sign_path "$CODEX_BUNDLE/$relative_path" --entitlements "$CODEX_V8_ENTITLEMENTS"
        ;;
    none)
        sign_path "$CODEX_BUNDLE/$relative_path"
        ;;
    *)
        fail "Unsupported Codex release entitlement profile for $relative_path: ${entitlement_profile:-<missing>}"
        ;;
    esac
done <<< "$codex_signing_plan"
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
sign_path "$APP_BUNDLE" --entitlements "$app_entitlements"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
python3 "$SCRIPT_DIR/codex_runtime_artifact.py" \
    --manifest "$CODEX_MANIFEST" verify-bundle \
    --arch all \
    --bundle "$CODEX_BUNDLE" \
    --signed-team-identifier "$SIGNING_TEAM_ID"
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
