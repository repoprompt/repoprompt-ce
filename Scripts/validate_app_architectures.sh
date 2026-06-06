#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
EXPECTED="${2:-arm64,x86_64}"
LABEL="${3:-App architecture validation}"
LIPO="${LIPO:-lipo}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "usage: $0 <app-bundle> [arm64,x86_64|matching] [label]"
[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle: $APP_BUNDLE"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"

normalize_list() {
    tr ', ' '\n\n' <<< "$1" | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

architectures() {
    "$LIPO" -archs "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

require_regular_executable() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" && -x "$path" ]] ||
        fail "expected non-symlink executable Mach-O: $path"
}

require_arches() {
    local path="$1"
    local expected="$2"
    require_regular_executable "$path"
    local actual
    actual="$(architectures "$path")" || fail "could not read Mach-O architectures: $path"
    [[ "$actual" == "$expected" ]] ||
        fail "$LABEL rejected $path: expected architectures $expected, got ${actual:-<none>}"
}

MAIN="$APP_BUNDLE/Contents/MacOS/RepoPrompt"
HELPER="$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
require_regular_executable "$MAIN"
require_regular_executable "$HELPER"
MAIN_ARCHES="$(architectures "$MAIN")" || fail "could not read main executable architectures"
HELPER_ARCHES="$(architectures "$HELPER")" || fail "could not read MCP helper architectures"
[[ -n "$MAIN_ARCHES" && "$MAIN_ARCHES" == "$HELPER_ARCHES" ]] ||
    fail "$LABEL requires matching app/helper architectures: app=${MAIN_ARCHES:-<none>} helper=${HELPER_ARCHES:-<none>}"

if [[ "$EXPECTED" == "matching" ]]; then
    printf 'OK: %s passed with matching app/helper architectures: %s\n' "$LABEL" "$MAIN_ARCHES"
    exit 0
fi

EXPECTED="$(normalize_list "$EXPECTED")"
[[ "$EXPECTED" == "arm64,x86_64" ]] || fail "public architecture policy must be exactly arm64,x86_64, got $EXPECTED"

MACHO_PATHS=(
    "$MAIN"
    "$HELPER"
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
)
for path in "${MACHO_PATHS[@]}"; do
    require_arches "$path" "$EXPECTED"
done

printf 'OK: %s passed universal architecture policy: %s\n' "$LABEL" "$EXPECTED"
