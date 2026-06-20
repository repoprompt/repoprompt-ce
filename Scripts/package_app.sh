#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
cd "$ROOT_DIR"

[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x

START_TIME="$(date +%s)"
PHASE_START="$START_TIME"
phase(){
    local now elapsed total
    now="$(date +%s)"
    elapsed=$((now - PHASE_START))
    total=$((now - START_TIME))
    printf '\n==> [%s] %s (previous: %ss, total: %ss)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$elapsed" "$total"
    PHASE_START="$now"
}
echo_cmd(){
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}
run(){
    echo_cmd "$@"
    "$@"
}
fail(){ echo "ERROR: $*" >&2; exit 1; }
remove_stale_artifact_manifests(){
    local manifests=()
    shopt -s nullglob
    manifests=("$ROOT_DIR"/.build/release/*-artifact-manifest.json)
    shopt -u nullglob
    if (( ${#manifests[@]} )); then
        run rm -f -- "${manifests[@]}"
    fi
}
paths_same(){
    python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

left = Path(sys.argv[1])
right = Path(sys.argv[2])
try:
    print("1" if left.samefile(right) else "0")
except OSError:
    left_resolved = left.resolve(strict=False)
    right_resolved = right.resolve(strict=False)
    print("1" if left_resolved == right_resolved else "0")
PY
}
finish(){
    local status="$1" now total
    [[ -z "${APP_ENTITLEMENTS:-}" ]] || rm -f "$APP_ENTITLEMENTS"
    now="$(date +%s)"
    total=$((now - START_TIME))
    if (( status == 0 )); then
        printf '\n==> [%s] Completed packaging in %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$total"
    else
        echo "ERROR: Packaging failed after ${total}s. Re-run with VERBOSE=1 $0 $CONF for shell tracing." >&2
    fi
    exit "$status"
}
trap 'finish $?' EXIT

BUNDLE_ID_OVERRIDE="${BUNDLE_ID:-}"
# Invalidate public-release manifests before metadata parsing, checks, or builds
# so failed non-public packaging cannot leave stale release metadata behind.
remove_stale_artifact_manifests
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"
APP_NAME="${APP_NAME:-RepoPrompt}"; DISPLAY_NAME="${DISPLAY_NAME:-RepoPrompt CE}"; BASE_BUNDLE_ID="${BUNDLE_ID:-com.pvncher.repoprompt.ce}"; MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"; BUILD_NUMBER="${BUILD_NUMBER:-1}"; SIGNING_TEAM_ID="${SIGNING_TEAM_ID:-648A27MST5}"
ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"

IS_RELEASE=0
[[ "$CONF" == "release" ]] && IS_RELEASE=1
if (( IS_RELEASE )); then
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-$BASE_BUNDLE_ID}"
else
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-${DEBUG_BUNDLE_ID:-$BASE_BUNDLE_ID.debug}}"
fi

phase "Checking build environment"
run "$CONTROL_PLANE_SCRIPTS_DIR/doctor.sh" --quiet
SIGN_IDENTITY_WAS_EXPLICIT=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY_WAS_EXPLICIT=1
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
RELEASE_ALLOW_ADHOC_SIGNING="${RELEASE_ALLOW_ADHOC_SIGNING:-0}"
LOCAL_SELF_SIGNED_RELEASE="${LOCAL_SELF_SIGNED_RELEASE:-0}"
LOCAL_SELF_SIGNED_CERTIFICATE_NAME="RepoPrompt CE Local Self-Signed Code Signing"
LOCAL_SIGNING_CERTIFICATE_SHA1="${LOCAL_SIGNING_CERTIFICATE_SHA1:-}"
LOCAL_SIGNING_CERTIFICATE_SHA256="${LOCAL_SIGNING_CERTIFICATE_SHA256:-}"
LOCAL_SIGNING_SERVICE_GENERATION="${LOCAL_SIGNING_SERVICE_GENERATION:-}"
LOCAL_SELF_SIGNED_REQUIREMENT=""
PREFER_STABLE_DEBUG_SIGNING="${PREFER_STABLE_DEBUG_SIGNING:-1}"
DEBUG_SECURE_STORAGE_BACKEND="${DEBUG_SECURE_STORAGE_BACKEND:-}"
REPOPROMPT_PROVISIONING_PROFILE="${REPOPROMPT_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS_TEMPLATE="${APP_ENTITLEMENTS_TEMPLATE:-$ROOT_DIR/AppBundle/RepoPrompt.entitlements.template}"
LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE="$ROOT_DIR/AppBundle/RepoPrompt.local-self-signed.entitlements.template"
APP_ENTITLEMENTS=""
USE_ADHOC_SIGNING=0
USE_LOCAL_SELF_SIGNED_RELEASE=0
DEBUG_STORAGE_BACKEND_MARKER="alternate-in-memory"
SIGNING_MODE_MARKER="debug-apple-development"
warn_adhoc_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a debug package."
    echo "WARNING: RepoPrompt debug runtime will use ephemeral in-memory secure storage instead of macOS Keychain for API keys and secure permission documents."
    echo "WARNING: Keychain consent prompts should be avoided, but secrets and secure permission changes saved in this run will not persist across app launches."
    echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" for real local Keychain persistence."
}
warn_release_candidate_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a release-candidate package."
    echo "WARNING: This artifact exercises release packaging only. It is not notarizable, distributable, or suitable for GitHub Releases."
}
if [[ "$LOCAL_SELF_SIGNED_RELEASE" == "1" || "$LOCAL_SELF_SIGNED_RELEASE" == "true" ]]; then
    (( IS_RELEASE )) || fail "LOCAL_SELF_SIGNED_RELEASE is only supported for release packaging."
    [[ -n "$SIGN_IDENTITY" ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires SIGN_IDENTITY pointing at the user-local self-signed code-signing identity."
    [[ "$LOCAL_SIGNING_CERTIFICATE_SHA1" =~ ^[[:xdigit:]]{40}$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires LOCAL_SIGNING_CERTIFICATE_SHA1 with the selected certificate SHA-1 fingerprint."
    [[ "$LOCAL_SIGNING_CERTIFICATE_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires LOCAL_SIGNING_CERTIFICATE_SHA256 with the selected certificate SHA-256 fingerprint."
    [[ "$LOCAL_SIGNING_SERVICE_GENERATION" =~ ^[1-9][0-9]*$ ]] || fail "LOCAL_SELF_SIGNED_RELEASE requires a positive LOCAL_SIGNING_SERVICE_GENERATION."
    LOCAL_SIGNING_CERTIFICATE_SHA1="$(tr '[:lower:]' '[:upper:]' <<< "$LOCAL_SIGNING_CERTIFICATE_SHA1")"
    LOCAL_SIGNING_CERTIFICATE_SHA256="$(tr '[:lower:]' '[:upper:]' <<< "$LOCAL_SIGNING_CERTIFICATE_SHA256")"
    LOCAL_SELF_SIGNED_REQUIREMENT="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$LOCAL_SIGNING_CERTIFICATE_SHA1\""
    USE_LOCAL_SELF_SIGNED_RELEASE=1
    echo "WARNING: Building a local-only self-signed production app."
    echo "WARNING: This app is for installation on this Mac only. It is not notarized and must not be uploaded to GitHub Releases."
fi
if [[ -z "$SIGN_IDENTITY" ]] && (( ! IS_RELEASE )) && [[ "$PREFER_STABLE_DEBUG_SIGNING" == "1" || "$PREFER_STABLE_DEBUG_SIGNING" == "true" ]]; then
    AUTO_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / { print $2; exit }')"
    if [[ -n "$AUTO_SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$AUTO_SIGN_IDENTITY"
        echo "Using auto-detected debug signing identity: $SIGN_IDENTITY"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if (( IS_RELEASE )); then
        if [[ "$RELEASE_ALLOW_ADHOC_SIGNING" != "1" && "$RELEASE_ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Release packaging requires SIGN_IDENTITY and will not produce an ad-hoc signed app by default. Set SIGN_IDENTITY to a stable Apple signing identity for team $SIGNING_TEAM_ID."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_release_candidate_signing
    else
        if [[ "$ALLOW_ADHOC_SIGNING" != "1" && "$ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Debug ad-hoc signing is disabled by default. Set ALLOW_ADHOC_SIGNING=1 to build an ad-hoc package, or set SIGN_IDENTITY for stable signing."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_adhoc_signing
    fi
else
    if (( ! IS_RELEASE )) && (( ! SIGN_IDENTITY_WAS_EXPLICIT )) && [[ -z "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
        echo "WARNING: Auto-detected debug signing will use ephemeral in-memory secure storage to avoid macOS Keychain prompts."
        echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" to opt in to persistent debug Keychain storage."
    fi
    echo "Using signing identity: $SIGN_IDENTITY"
    if ! security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" >/dev/null 2>&1; then
        echo "WARNING: SIGN_IDENTITY was not found by exact text in 'security find-identity'; codesign will still attempt to use it."
    fi
fi

if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
    SIGNING_MODE_MARKER="local-self-signed"
elif (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
    SIGNING_MODE_MARKER="developer-id"
elif (( IS_RELEASE )); then
    SIGNING_MODE_MARKER="release-candidate-adhoc"
elif [[ -n "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
    case "$DEBUG_SECURE_STORAGE_BACKEND" in
        keychain|alternate-in-memory) DEBUG_STORAGE_BACKEND_MARKER="$DEBUG_SECURE_STORAGE_BACKEND" ;;
        *) fail "DEBUG_SECURE_STORAGE_BACKEND must be 'keychain' or 'alternate-in-memory', got '$DEBUG_SECURE_STORAGE_BACKEND'." ;;
    esac
elif (( SIGN_IDENTITY_WAS_EXPLICIT )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
elif (( USE_ADHOC_SIGNING )); then
    SIGNING_MODE_MARKER="debug-adhoc"
fi
printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"
printf 'Signing mode marker: %s\n' "$SIGNING_MODE_MARKER"

SWIFT_BUILD_ARGS=(-c "$CONF")
PUBLIC_UNIVERSAL_RELEASE=0
ARCHITECTURE_POLICY="matching"
if (( IS_RELEASE )) && (( ! USE_LOCAL_SELF_SIGNED_RELEASE )); then
    PUBLIC_UNIVERSAL_RELEASE=1
    ARCHITECTURE_POLICY="arm64,x86_64"
fi

# KeyboardShortcuts' default Bundle.module lookup does not match RepoPrompt's
# packaged resource layout. Host-native builds patch the default checkout below;
# the universal builder patches each isolated architecture checkout before compiling.
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    phase "Building universal public release products in isolated SwiftPM directories"
    BUILD_DIR="$ROOT_DIR/.build/public-release-products/release"
    run env \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS" \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_swiftpm_release_products.sh" "$BUILD_DIR"
else
    phase "Patching KeyboardShortcuts resource lookup"
    run "$CONTROL_PLANE_SCRIPTS_DIR/patch_keyboard_shortcuts_resource_lookup.sh" "$ROOT_DIR"

    phase "Building $APP_NAME ($CONF, host-native)"
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_NAME"

    phase "Building repoprompt-mcp ($CONF, host-native)"
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build "${SWIFT_BUILD_ARGS[@]}" --product repoprompt-mcp

    phase "Resolving build artifact paths"
    echo_cmd "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path
    BUILD_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path)"
fi
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
elif (( IS_RELEASE )); then
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
else
    APP_BUNDLE="${REPOPROMPT_DEBUG_APP_BUNDLE:-$HOME/Library/Application Support/RepoPrompt CE/DebugApps/$APP_NAME.app}"
fi
COMPAT_APP_BUNDLE="$ROOT_DIR/.build/$CONF/$APP_NAME.app"
CLI_PATH="$BUILD_DIR/repoprompt-mcp"
printf 'BUILD_DIR=%s\nAPP_BUNDLE=%s\nCOMPAT_APP_BUNDLE=%s\nCLI_PATH=%s\nAD_HOC_SIGNING=%s\nARCHITECTURE_POLICY=%s\n' "$BUILD_DIR" "$APP_BUNDLE" "$COMPAT_APP_BUNDLE" "$CLI_PATH" "$USE_ADHOC_SIGNING" "$ARCHITECTURE_POLICY"

phase "Creating app bundle layout"
run rm -rf "$APP_BUNDLE"
if [[ "$(paths_same "$APP_BUNDLE" "$COMPAT_APP_BUNDLE")" != "1" ]]; then
    run rm -rf "$COMPAT_APP_BUNDLE"
fi
run mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/bin" "$APP_BUNDLE/Contents/Frameworks"
for exe in "$APP_NAME" repoprompt-mcp; do
    [[ -x "$BUILD_DIR/$exe" ]] || fail "Missing built executable: $BUILD_DIR/$exe"
    run cp "$BUILD_DIR/$exe" "$APP_BUNDLE/Contents/MacOS/$exe"
    run chmod +x "$APP_BUNDLE/Contents/MacOS/$exe"
done
run ln -sf ../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/repoprompt-mcp"
run ln -sf ../../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/bin/repoprompt-mcp"
run mkdir -p "$APP_BUNDLE/Contents/Resources/Legal"
run cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/Legal/"
run cp -R "$ROOT_DIR/ThirdPartyLicenses" "$APP_BUNDLE/Contents/Resources/Legal/"
[[ ! -d AppResources ]] || run rsync -a AppResources/ "$APP_BUNDLE/Contents/Resources/"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do run cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"; done
shopt -u nullglob
run "$CONTROL_PLANE_SCRIPTS_DIR/normalize_swiftpm_resource_bundles.sh" "$APP_BUNDLE"
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_required_swiftpm_resource_bundles.sh" "$APP_BUNDLE" "Packaged app SwiftPM resource bundle layout"

phase "Writing Info.plist"
run python3 - <<PY
from pathlib import Path
s=Path('AppBundle/Info.plist.template').read_text()
for k,v in {'__APP_NAME__':'$APP_NAME','__DISPLAY_NAME__':'$DISPLAY_NAME','__BUNDLE_ID__':'$BUNDLE_ID','__MARKETING_VERSION__':'$MARKETING_VERSION','__BUILD_NUMBER__':'$BUILD_NUMBER','__DEBUG_SECURE_STORAGE_BACKEND__':'$DEBUG_STORAGE_BACKEND_MARKER','__SIGNING_MODE__':'$SIGNING_MODE_MARKER','__LOCAL_SIGNING_CERTIFICATE_SHA256__':'$LOCAL_SIGNING_CERTIFICATE_SHA256','__LOCAL_SECURE_STORAGE_GENERATION__':'$LOCAL_SIGNING_SERVICE_GENERATION'}.items(): s=s.replace(k,v)
Path('$APP_BUNDLE/Contents/Info.plist').write_text(s)
PY
run plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    phase "Rendering local self-signed entitlements"
    [[ -f "$LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE" ]] || fail "Missing local self-signed entitlements template: $LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE"
    APP_ENTITLEMENTS="$(mktemp)"
    run python3 - <<PY
from pathlib import Path
s=Path('$LOCAL_SELF_SIGNED_ENTITLEMENTS_TEMPLATE').read_text()
s=s.replace('__BUNDLE_ID__', '$BUNDLE_ID')
Path('$APP_ENTITLEMENTS').write_text(s)
PY
    run plutil -lint "$APP_ENTITLEMENTS"
elif (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    phase "Embedding release provisioning profile and entitlements"
    [[ -f "$REPOPROMPT_PROVISIONING_PROFILE" ]] || fail "Signed release packaging requires REPOPROMPT_PROVISIONING_PROFILE pointing to the RepoPrompt CE Developer ID provisioning profile."
    [[ -f "$APP_ENTITLEMENTS_TEMPLATE" ]] || fail "Missing release entitlements template: $APP_ENTITLEMENTS_TEMPLATE"
    PROFILE_PLIST="$(mktemp)"
    run security cms -D -i "$REPOPROMPT_PROVISIONING_PROFILE" -o "$PROFILE_PLIST"
    PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    run rm -f "$PROFILE_PLIST"
    [[ "$PROFILE_APP_IDENTIFIER" == "$SIGNING_TEAM_ID.$BUNDLE_ID" ]] || fail "Provisioning profile app identifier mismatch: expected $SIGNING_TEAM_ID.$BUNDLE_ID, got ${PROFILE_APP_IDENTIFIER:-<missing>}."
    run cp "$REPOPROMPT_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    APP_ENTITLEMENTS="$(mktemp)"
    run python3 - <<PY
from pathlib import Path
s=Path('$APP_ENTITLEMENTS_TEMPLATE').read_text()
for k,v in {'__BUNDLE_ID__':'$BUNDLE_ID','__SIGNING_TEAM_ID__':'$SIGNING_TEAM_ID'}.items(): s=s.replace(k,v)
Path('$APP_ENTITLEMENTS').write_text(s)
PY
    run plutil -lint "$APP_ENTITLEMENTS"
fi

phase "Copying dynamic frameworks"
printf 'Framework destination: %s\n' "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
    "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_vendor.sh" "$SPARKLE_FRAMEWORK"
run cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
run install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Pre-sign packaged app"

phase "Signing app bundle"
sign_path(){
    local path="$1"
    shift || true
    local args=(--force --sign "$SIGN_IDENTITY")
    if (( USE_ADHOC_SIGNING )); then
        args+=(--timestamp=none)
    elif (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
        args+=(--timestamp=none --options runtime)
    elif (( IS_RELEASE )); then
        args+=(--timestamp --options runtime)
    else
        args+=(--timestamp=none)
    fi
    run codesign "${args[@]}" "$@" "$path"
}
sign_sparkle_framework(){
    local framework="$1"
    sign_path "$framework/Versions/B/XPCServices/Installer.xpc"
    sign_path "$framework/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
    sign_path "$framework/Versions/B/Autoupdate"
    sign_path "$framework/Versions/B/Updater.app"
    sign_path "$framework"
}
verify_signed_app_identity(){
    local details identifier team authorities designated_requirement certificate_dir certificate_prefix actual_fingerprint
    details="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
    identifier="$(awk -F= '/^Identifier=/{print $2; exit}' <<< "$details")"
    team="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<< "$details")"
    authorities="$(printf '%s\n' "$details" | awk -F= '/^Authority=/{print $2}' | paste -sd ', ' -)"
    printf 'Signed app path: %s\n' "$APP_BUNDLE"
    printf 'Signed app identifier: %s\n' "${identifier:-<missing>}"
    printf 'Signed app team: %s\n' "${team:-<missing>}"
    printf 'Signing authorities: %s\n' "${authorities:-<none/ad-hoc>}"
    printf 'Ad-hoc signing active: %s\n' "$USE_ADHOC_SIGNING"
    printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"
    [[ "$identifier" == "$BUNDLE_ID" ]] || fail "Signed app identifier mismatch: expected $BUNDLE_ID, got ${identifier:-<missing>}"
    if (( USE_ADHOC_SIGNING )); then
        [[ -z "$team" || "$team" == "not set" ]] || echo "WARNING: Expected ad-hoc signing without a team identifier, but found team '$team'."
        echo "WARNING: Ad-hoc package created explicitly; do not use this artifact for release."
    elif (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
        [[ -z "$team" || "$team" == "not set" ]] || fail "Local self-signed app unexpectedly has team identifier '$team'."
        run codesign --verify --deep --strict --verbose=2 -R="$LOCAL_SELF_SIGNED_REQUIREMENT" "$APP_BUNDLE"
        certificate_dir="$(mktemp -d)"
        certificate_prefix="$certificate_dir/leaf"
        codesign -d --extract-certificates="$certificate_prefix" "$APP_BUNDLE" >/dev/null 2>&1 || {
            rm -rf "$certificate_dir"
            fail "Could not extract the local signing certificate from the packaged app."
        }
        [[ -f "${certificate_prefix}0" ]] || {
            rm -rf "$certificate_dir"
            fail "Packaged app did not expose a leaf signing certificate."
        }
        actual_fingerprint="$(shasum -a 256 "${certificate_prefix}0" | awk '{print toupper($1)}')"
        rm -rf "$certificate_dir"
        [[ "$actual_fingerprint" == "$LOCAL_SIGNING_CERTIFICATE_SHA256" ]] || fail "Packaged app certificate fingerprint mismatch: expected $LOCAL_SIGNING_CERTIFICATE_SHA256, got ${actual_fingerprint:-<missing>}."
        designated_requirement="$(codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n 's/^designated => //p')"
        [[ -n "$designated_requirement" ]] || fail "Could not extract the packaged app designated requirement."
        grep -F -i -- "$LOCAL_SIGNING_CERTIFICATE_SHA1" <<< "$designated_requirement" >/dev/null || fail "Packaged app designated requirement is not pinned to the selected local certificate."
        printf 'Selected local certificate SHA-256: %s\n' "$LOCAL_SIGNING_CERTIFICATE_SHA256"
        printf 'Local secure-storage service generation: v%s\n' "$LOCAL_SIGNING_SERVICE_GENERATION"
        printf 'Extracted designated requirement: %s\n' "$designated_requirement"
    elif (( IS_RELEASE )); then
        [[ "$team" == "$SIGNING_TEAM_ID" ]] || fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team:-<missing>}"
    else
        [[ -n "$team" && "$team" != "not set" ]] || fail "Debug app was expected to be signed with a stable identity, but no team identifier was found."
    fi
}
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then sign_sparkle_framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; fi
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_SIGN_ARGS=()
if (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")
fi
if (( USE_LOCAL_SELF_SIGNED_RELEASE )); then
    APP_SIGN_ARGS+=(--requirements "=designated => $LOCAL_SELF_SIGNED_REQUIREMENT")
fi
if (( ${#APP_SIGN_ARGS[@]} )); then
    sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"
else
    sign_path "$APP_BUNDLE"
fi
run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_signed_app_identity
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$ARCHITECTURE_POLICY" "Post-sign packaged app"
if (( PUBLIC_UNIVERSAL_RELEASE )); then
    run "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" write \
        --app "$APP_BUNDLE" \
        --output "$ARTIFACT_MANIFEST" \
        --expected-architectures "$ARCHITECTURE_POLICY"
fi
run "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Packaged app MCP helper layout"
run "$RUN_WITHOUT_GITHUB_TOKENS" "$CONTROL_PLANE_SCRIPTS_DIR/smoke_embedded_mcp_helper.sh" "$APP_BUNDLE" "Packaged app MCP helper"
if [[ "$(paths_same "$APP_BUNDLE" "$COMPAT_APP_BUNDLE")" != "1" ]]; then
    phase "Updating compatibility app bundle link"
    run mkdir -p "$(dirname "$COMPAT_APP_BUNDLE")"
    if (( USE_ADHOC_SIGNING )); then
        if (( IS_RELEASE )); then
            warn_release_candidate_signing
        else
            warn_adhoc_signing
        fi
    fi
    run ln -sfn "$APP_BUNDLE" "$COMPAT_APP_BUNDLE"
    printf 'Compatibility link: %s -> %s\n' "$COMPAT_APP_BUNDLE" "$APP_BUNDLE"
fi
printf 'Created: %s\n' "$APP_BUNDLE"
