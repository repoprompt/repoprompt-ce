#!/usr/bin/env bash
set -euo pipefail
quiet=0
install_debug_cli=0
check_format_tools=0
install_format_tools=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
    case "$arg" in
        --quiet) quiet=1 ;;
        --install-debug-cli) install_debug_cli=1 ;;
        --check-format-tools) check_format_tools=1 ;;
        --install-format-tools) install_format_tools=1 ;;
        --help|-h)
            cat <<'EOF'
Usage: ./Scripts/doctor.sh [--quiet] [--install-debug-cli] [--check-format-tools] [--install-format-tools]

Checks Swift/Xcode, signing, SDK, SwiftUI availability, debug CLI status, and Swift style tool status.

Options:
  --quiet                 Suppress nonessential output. Does not require SwiftFormat or SwiftLint.
  --install-debug-cli     Package and install /usr/local/bin/rpce-cli-debug.
  --check-format-tools    Fail if SwiftFormat or SwiftLint is missing.
  --install-format-tools  Install missing SwiftFormat/SwiftLint tools with Homebrew.
EOF
            exit 0
            ;;
        *) echo "ERROR: Unknown option: $arg" >&2; exit 2 ;;
    esac
done

[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x
START_TIME="$(date +%s)"
PHASE_START="$START_TIME"
log(){ (( quiet )) || printf '%s\n' "$*"; }
phase(){
    (( quiet )) && return
    local now elapsed total
    now="$(date +%s)"
    elapsed=$((now - PHASE_START))
    total=$((now - START_TIME))
    printf '\n==> [%s] %s (previous: %ss, total: %ss)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$elapsed" "$total"
    PHASE_START="$now"
}
run(){ (( quiet )) || { printf '+ '; printf '%q ' "$@"; printf '\n'; }; "$@"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
require(){ command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1. Install Xcode command line tools or ensure it is on PATH."; }
phase "Checking required tools"
for tool in swift xcrun codesign security plutil otool install_name_tool; do require "$tool"; done
if (( install_format_tools )); then
    phase "Installing Swift style tools"
    run "$ROOT_DIR/Scripts/install_format_tools.sh" install
elif (( check_format_tools )); then
    phase "Checking Swift style tools"
    run "$ROOT_DIR/Scripts/install_format_tools.sh" check
elif (( ! quiet )); then
    phase "Swift style tool status"
    "$ROOT_DIR/Scripts/install_format_tools.sh" status || true
fi
phase "Swift toolchain"
(( quiet )) || run swift --version
phase "macOS SDK"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[[ -n "$SDK_PATH" ]] || fail "No macOS SDK found via xcrun. Try xcode-select --install or select a valid Xcode with xcode-select."
log "$SDK_PATH"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR=""
if [[ "$SDK_VERSION" =~ ^([0-9]+)(\.|$) ]]; then
    SDK_MAJOR="${BASH_REMATCH[1]}"
else
    SDK_REAL_PATH="$(cd "$SDK_PATH" 2>/dev/null && pwd -P || true)"
    while IFS= read -r base; do
        if [[ "$base" =~ MacOSX([0-9]+) ]]; then
            SDK_MAJOR="${BASH_REMATCH[1]}"
            break
        fi
    done <<EOF
$(basename "$SDK_PATH")
$(basename "${SDK_REAL_PATH:-$SDK_PATH}")
EOF
fi
[[ -n "$SDK_MAJOR" ]] || fail "Unable to determine macOS SDK version from xcrun output '${SDK_VERSION:-<empty>}' or path $SDK_PATH"
if (( SDK_MAJOR < 26 )); then fail "macOS 26 SDK or newer required. Current SDK: ${SDK_VERSION:-$SDK_PATH}"; fi
phase "Signing diagnostics"
DEFAULT_KEYCHAIN="$(security default-keychain 2>/dev/null | tr -d '"' || true)"
log "Default keychain: ${DEFAULT_KEYCHAIN:-<unknown>}"
APPLE_DEVELOPMENT_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / { print $2 }' || true)"
if [[ -n "$APPLE_DEVELOPMENT_IDENTITIES" ]]; then
    log "Apple Development signing identities:"
    while IFS= read -r identity; do [[ -z "$identity" ]] || log "  - $identity"; done <<< "$APPLE_DEVELOPMENT_IDENTITIES"
else
    log "WARNING: No Apple Development signing identity found; debug packaging requires SIGN_IDENTITY or explicit ALLOW_ADHOC_SIGNING=1."
fi
log "If codesign cannot access an identity, unlock the keychain first. For CI/signing reliability, configure the key partition list with apple-tool:,apple:,codesign:."
log "Note: keychain partition-list setup helps codesign access signing keys; it does not bypass runtime Keychain item consent."
phase "Compiling SwiftUI Liquid Glass probe"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/GlassProbe.swift" <<'SWIFT'
import SwiftUI
@available(macOS 26.0, *)
private struct GlassProbe: View { var body: some View { Text("OK").glassEffect() } }
SWIFT
ARCH="$(uname -m)"
run xcrun swiftc -typecheck -parse-as-library -target "${ARCH}-apple-macos14.0" "$TMP/GlassProbe.swift"
log "OK: toolchain can compile SwiftUI Liquid Glass symbols."
if (( install_debug_cli )); then
    phase "Installing debug CLI"
    run "$ROOT_DIR/Scripts/install_debug_cli.sh" install --build
elif (( ! quiet )); then
    phase "Debug CLI status"
    "$ROOT_DIR/Scripts/install_debug_cli.sh" status || true
fi
