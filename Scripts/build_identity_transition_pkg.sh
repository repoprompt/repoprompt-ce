#!/usr/bin/env bash
set -euo pipefail

# Deterministic, bounded builder/validator for the one-time transition package.
# Each material command is exec'd through the process-group-owning supervisor.

MODE="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="$SCRIPT_DIR/transition_package_contract.py"
SUPERVISOR="$SCRIPT_DIR/supervise_release_phase.py"

readonly PAYLOAD_COPY_TIMEOUT_SECONDS=300
readonly COMPONENT_PLIST_TIMEOUT_SECONDS=60
readonly COMPONENT_PACKAGE_TIMEOUT_SECONDS=300
readonly PRODUCT_ARCHIVE_TIMEOUT_SECONDS=300
readonly PACKAGE_SIGN_TIMEOUT_SECONDS=300
readonly PACKAGE_NOTARIZATION_TIMEOUT_SECONDS=1860
readonly PACKAGE_STAPLE_TIMEOUT_SECONDS=300
readonly PACKAGE_VALIDATION_TIMEOUT_SECONDS=300
readonly PACKAGE_EXPANSION_TIMEOUT_SECONDS=300
readonly PAYLOAD_COMPARISON_TIMEOUT_SECONDS=300

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_file() { [[ -f "$1" && ! -L "$1" ]] || fail "Missing regular non-symlink file: $1"; }
require_directory() { [[ -d "$1" && ! -L "$1" ]] || fail "Missing non-symlink directory: $1"; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
require_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "Refusing to overwrite existing transition path: $1"; }

[[ "${REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG:-}" == "1" ]] ||
    fail "identity transition package construction requires explicit Tip rollout enablement"
require_env REPOPROMPT_APPROVED_SOURCE_ROOT
require_file "$CONTRACT"
require_file "$SUPERVISOR"
require_command python3

source "$SCRIPT_DIR/load_release_metadata.sh"
load_verified_tip_release_context \
    "$SCRIPT_DIR" "$REPOPROMPT_APPROVED_SOURCE_ROOT" \
    "transition-package-${MODE:-unknown}" ||
    fail "Unable to load the verified transition package context"
[[ "$ROLLOUT_ROLE" == "transition" ]] ||
    fail "transition package command requires rollout role=transition, got $ROLLOUT_ROLE"
[[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]] ||
    fail "transition package command requires installation type=package, got $ROLLOUT_INSTALLATION_TYPE"

context_assignments="$(
    python3 "$CONTRACT" context-shell --boundary "transition-package-${MODE:-unknown}"
)" || fail "Unable to resolve transition package values from the verified context"
eval "$context_assignments"
[[ "$TRANSITION_APP_BUNDLE_ID" == "$BUNDLE_ID" ]] ||
    fail "Transition package context bundle ID mismatch: expected $BUNDLE_ID, got $TRANSITION_APP_BUNDLE_ID"
[[ "$TRANSITION_APP_TEAM_ID" == "$SIGNING_TEAM_ID" ]] ||
    fail "Transition package context Application Team ID mismatch: expected $SIGNING_TEAM_ID, got $TRANSITION_APP_TEAM_ID"
[[ "$TRANSITION_APP_REQUIREMENT" == "$EXPECTED_APP_REQUIREMENT" ]] ||
    fail "Transition package context Application requirement mismatch"
[[ "$TRANSITION_INSTALLER_TEAM_ID" == "$EXPECTED_INSTALLER_TEAM_ID" ]] ||
    fail "Transition package context Installer Team ID mismatch: expected $EXPECTED_INSTALLER_TEAM_ID, got $TRANSITION_INSTALLER_TEAM_ID"
[[ "$TRANSITION_INSTALLER_IDENTITY" == "$EXPECTED_INSTALLER_IDENTITY" ]] ||
    fail "Transition package context Installer identity mismatch"

APP=""
ARTIFACT_MANIFEST=""
EXPANDED_PAYLOAD_DIR=""
OUTPUT=""
PACKAGE=""
WORK_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --artifact-manifest) ARTIFACT_MANIFEST="$2"; shift 2 ;;
        --expanded-payload-dir) EXPANDED_PAYLOAD_DIR="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        *) fail "Unknown $MODE argument: $1" ;;
    esac
done

safe_work_dir() {
    [[ -n "$WORK_DIR" && "$WORK_DIR" == /* && "$WORK_DIR" != "/" ]] ||
        fail "$MODE requires an absolute, non-root --work-dir"
    [[ "$WORK_DIR" != "$REPOPROMPT_APPROVED_SOURCE_ROOT" ]] ||
        fail "Transition package work directory must not be the approved source root"
}

work_context="$WORK_DIR/tip-release-context.json"
work_digest="$WORK_DIR/tip-release-context.json.sha256"
payload_root="$WORK_DIR/payload-root"
component_plist="$WORK_DIR/component.plist"
component_pkg="$WORK_DIR/transition-component.pkg"
unsigned_product_pkg="$WORK_DIR/transition-unsigned.pkg"
expanded_pkg="$WORK_DIR/expanded-package"
expanded_app_path_file="$WORK_DIR/expanded-app-path"

initialize_work_dir() {
    safe_work_dir
    require_absent "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$payload_root"
    chmod 700 "$WORK_DIR"
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$work_context"
    cp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" "$work_digest"
}

verify_work_dir() {
    safe_work_dir
    require_directory "$WORK_DIR"
    require_file "$work_context"
    require_file "$work_digest"
    cmp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$work_context" >/dev/null ||
        fail "Transition package work context differs byte-for-byte from setup context"
    cmp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" "$work_digest" >/dev/null ||
        fail "Transition package work digest differs byte-for-byte from setup digest"
}

path_size_bytes() {
    local path="$1"
    python3 - "$path" <<'PYTHON'
import os
import signal
import sys
from pathlib import Path

def timeout(_signal, _frame):
    raise TimeoutError("size calculation exceeded 15 seconds")

signal.signal(signal.SIGALRM, timeout)
signal.alarm(15)
path = Path(sys.argv[1])
if not path.exists() and not path.is_symlink():
    print(0)
    raise SystemExit(0)
total = path.lstat().st_size
pending = [path] if path.is_dir() and not path.is_symlink() else []
while pending:
    directory = pending.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            stat = entry.stat(follow_symlinks=False)
            total += stat.st_size
            if entry.is_dir(follow_symlinks=False):
                pending.append(Path(entry.path))
signal.alarm(0)
print(total)
PYTHON
}

run_supervised() {
    # Every builder invocation owns exactly one material command. Replace this
    # shell directly with the supervisor so cancellation cannot land between a
    # background fork and publication of the supervisor PID.
    local phase="$1" timeout_seconds="$2" app_path="$3" payload_path="$4"
    shift 4
    local capture="$WORK_DIR/supervisor-${phase//[^A-Za-z0-9._-]/-}.capture"
    local app_size payload_size
    # macOS Bash 3.2 aborts on empty-array expansion under set -u. Keep the
    # trailing supervisor argument vector non-empty by folding the mandatory
    # command separator into it alongside the phase-specific evidence flag.
    local supervisor_tail_args=(--)
    require_absent "$capture"
    app_size="$(path_size_bytes "$app_path")"
    payload_size="$(path_size_bytes "$payload_path")"
    printf 'PHASE START [%s]: phase=%s command=%s app=%s app-size-bytes=%s payload=%s payload-size-bytes=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$(basename "$1")" \
        "$app_path" "$app_size" "$payload_path" "$payload_size"
    if [[ "$phase" == "transition-package-notarization" ]]; then
        supervisor_tail_args=(--notarytool-json-evidence --)
    fi
    exec python3 "$SUPERVISOR" \
        --phase "$phase" --timeout-seconds "$timeout_seconds" \
        --heartbeat-seconds 30 \
        --capture-file "$capture" --cwd "$WORK_DIR" \
        --app-path "$app_path" --app-size-bytes "$app_size" \
        --payload-path "$payload_path" --payload-size-bytes "$payload_size" \
        --redact-env NOTARYTOOL_PRIVATE_KEY --redact-env NOTARYTOOL_KEY_ID \
        --redact-env NOTARYTOOL_ISSUER_ID "${supervisor_tail_args[@]}" "$@"
}

require_app_and_manifest() {
    require_directory "$APP"
    require_file "$ARTIFACT_MANIFEST"
}

case "$MODE" in
    prepare-payload)
        require_app_and_manifest
        initialize_work_dir
        run_supervised "transition-payload-copy" "$PAYLOAD_COPY_TIMEOUT_SECONDS" \
            "$APP" "$payload_root" ditto "$APP" "$payload_root/$TRANSITION_APP_BUNDLE_NAME"
        ;;
    write-component-plist)
        require_app_and_manifest; verify_work_dir; require_directory "$payload_root"
        require_absent "$component_plist"
        run_supervised "transition-component-plist-generation" "$COMPONENT_PLIST_TIMEOUT_SECONDS" \
            "$APP" "$payload_root" python3 "$CONTRACT" write-component-plist \
            --boundary transition-component-plist --payload-root "$payload_root" --output "$component_plist"
        ;;
    build-component)
        require_app_and_manifest; verify_work_dir; require_directory "$payload_root"; require_file "$component_plist"
        python3 "$CONTRACT" verify-component-plist \
            --boundary transition-component-package-input \
            --payload-root "$payload_root" --component-plist "$component_plist"
        require_command pkgbuild; require_absent "$component_pkg"
        run_supervised "transition-component-package-construction" "$COMPONENT_PACKAGE_TIMEOUT_SECONDS" \
            "$APP" "$payload_root" pkgbuild --root "$payload_root" \
            --component-plist "$component_plist" --identifier "$TRANSITION_PACKAGE_IDENTIFIER" \
            --version "$TRANSITION_PACKAGE_VERSION" --install-location "$TRANSITION_INSTALL_LOCATION" \
            "$component_pkg"
        ;;
    build-product)
        require_app_and_manifest; verify_work_dir; require_file "$component_pkg"; require_command productbuild
        require_absent "$unsigned_product_pkg"
        run_supervised "transition-product-archive-construction" "$PRODUCT_ARCHIVE_TIMEOUT_SECONDS" \
            "$APP" "$component_pkg" productbuild --package "$component_pkg" "$unsigned_product_pkg"
        ;;
    sign-package)
        require_app_and_manifest; verify_work_dir; require_file "$unsigned_product_pkg"; require_command productsign
        [[ -n "$OUTPUT" ]] || fail "sign-package requires --output"
        require_absent "$OUTPUT"; mkdir -p "$(dirname "$OUTPUT")"
        run_supervised "transition-package-signing" "$PACKAGE_SIGN_TIMEOUT_SECONDS" \
            "$APP" "$unsigned_product_pkg" productsign --sign "$TRANSITION_INSTALLER_IDENTITY" \
            "$unsigned_product_pkg" "$OUTPUT"
        ;;
    notarize-package)
        require_app_and_manifest; verify_work_dir
        [[ -n "$OUTPUT" ]] || fail "notarize-package requires --output"; require_file "$OUTPUT"
        require_env NOTARYTOOL_PRIVATE_KEY; require_env NOTARYTOOL_KEY_ID; require_env NOTARYTOOL_ISSUER_ID
        require_file "$NOTARYTOOL_PRIVATE_KEY"; require_command xcrun
        run_supervised "transition-package-notarization" "$PACKAGE_NOTARIZATION_TIMEOUT_SECONDS" \
            "$APP" "$OUTPUT" xcrun notarytool submit "$OUTPUT" \
            --key "$NOTARYTOOL_PRIVATE_KEY" --key-id "$NOTARYTOOL_KEY_ID" \
            --issuer "$NOTARYTOOL_ISSUER_ID" --wait --timeout 30m --output-format json
        ;;
    staple-package)
        require_app_and_manifest; verify_work_dir
        [[ -n "$OUTPUT" ]] || fail "staple-package requires --output"; require_file "$OUTPUT"; require_command xcrun
        run_supervised "transition-package-stapling" "$PACKAGE_STAPLE_TIMEOUT_SECONDS" \
            "$APP" "$OUTPUT" xcrun stapler staple "$OUTPUT"
        ;;
    validate-package)
        require_app_and_manifest; verify_work_dir
        [[ -n "$OUTPUT" ]] || fail "validate-package requires --output"; require_file "$OUTPUT"
        run_supervised "transition-package-signature-validation" "$PACKAGE_VALIDATION_TIMEOUT_SECONDS" \
            "$APP" "$OUTPUT" python3 "$CONTRACT" validate-package-signature \
            --boundary transition-package-signature --package "$OUTPUT"
        ;;
    expand-package)
        require_app_and_manifest; verify_work_dir
        [[ -n "$OUTPUT" ]] || fail "expand-package requires --output"; require_file "$OUTPUT"; require_command pkgutil
        require_absent "$expanded_pkg"
        run_supervised "transition-package-expansion" "$PACKAGE_EXPANSION_TIMEOUT_SECONDS" \
            "$APP" "$OUTPUT" pkgutil --expand-full "$OUTPUT" "$expanded_pkg"
        ;;
    compare-payload)
        require_app_and_manifest; verify_work_dir; require_directory "$expanded_pkg"
        require_absent "$expanded_app_path_file"
        run_supervised "transition-package-payload-comparison" "$PAYLOAD_COMPARISON_TIMEOUT_SECONDS" \
            "$APP" "$expanded_pkg" python3 "$CONTRACT" validate-expanded \
            --boundary transition-package-payload --expanded-root "$expanded_pkg" \
            --expected-app "$APP" --artifact-manifest "$ARTIFACT_MANIFEST" \
            --output-app-path "$expanded_app_path_file"
        ;;
    validate)
        [[ -n "$PACKAGE" ]] || fail "validate requires --package"; require_file "$PACKAGE"; require_file "$ARTIFACT_MANIFEST"
        safe_work_dir; require_absent "$WORK_DIR"; mkdir -p "$WORK_DIR"; chmod 700 "$WORK_DIR"
        cp "$REPOPROMPT_TIP_RELEASE_CONTEXT" "$work_context"
        cp "$REPOPROMPT_TIP_RELEASE_CONTEXT_SHA256_FILE" "$work_digest"
        command=(python3 "$CONTRACT" validate-package --boundary transition-package-smoke \
            --package "$PACKAGE" --work-dir "$WORK_DIR" --artifact-manifest "$ARTIFACT_MANIFEST")
        if [[ -n "$EXPANDED_PAYLOAD_DIR" ]]; then command+=(--expanded-payload-dir "$EXPANDED_PAYLOAD_DIR"); fi
        run_supervised "transition-package-smoke-validation" "$PACKAGE_NOTARIZATION_TIMEOUT_SECONDS" \
            "$WORK_DIR/expanded-package/$TRANSITION_APP_BUNDLE_NAME" "$PACKAGE" "${command[@]}"
        ;;
    *)
        fail "Usage: $0 prepare-payload|write-component-plist|build-component|build-product|sign-package|notarize-package|staple-package|validate-package|expand-package|compare-payload|validate ..."
        ;;
esac
