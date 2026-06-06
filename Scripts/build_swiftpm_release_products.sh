#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_WITHOUT_GITHUB_TOKENS="${REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS:-$SCRIPT_DIR/run_without_github_tokens.sh}"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/public-release-products/release}"
DEFAULT_SCRATCH_ROOT="$ROOT_DIR/.build/public-release-swiftpm"
SCRATCH_ROOT="${REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT:-$DEFAULT_SCRATCH_ROOT}"
SCRATCH_SENTINEL_NAME=".repoprompt-public-swiftpm-scratch"
LIPO="${LIPO:-lipo}"
KEYBOARD_SHORTCUTS_PATCH_HELPER="${REPOPROMPT_KEYBOARD_SHORTCUTS_PATCH_HELPER:-$SCRIPT_DIR/patch_keyboard_shortcuts_resource_lookup.sh}"
RESOURCE_COMPARATOR="${REPOPROMPT_SWIFTPM_RESOURCE_COMPARATOR:-$SCRIPT_DIR/compare_swiftpm_release_resources.py}"
CLEAN_PUBLIC_SWIFTPM_BUILDS="${REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS:-1}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

canonical_path() {
    python3 - "$1" <<'PYTHON'
import sys
from pathlib import Path

print(Path(sys.argv[1]).resolve(strict=False))
PYTHON
}

normalized_arches() {
    "$LIPO" -archs "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

require_exact_arch() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" ]] || fail "missing SwiftPM product: $path"
    local actual
    actual="$(normalized_arches "$path")"
    [[ "$actual" == "$expected" ]] ||
        fail "unexpected architecture set for $path: expected $expected, got ${actual:-<none>}"
}

[[ -x "$RUN_WITHOUT_GITHUB_TOKENS" ]] || fail "missing token-scrubbing SwiftPM wrapper: $RUN_WITHOUT_GITHUB_TOKENS"
[[ -x "$KEYBOARD_SHORTCUTS_PATCH_HELPER" ]] || fail "missing KeyboardShortcuts resource patch helper: $KEYBOARD_SHORTCUTS_PATCH_HELPER"
[[ -x "$RESOURCE_COMPARATOR" ]] || fail "missing resource comparator: $RESOURCE_COMPARATOR"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"
command -v ditto >/dev/null 2>&1 || fail "missing ditto"

mkdir -p "$(dirname "$OUTPUT_DIR")"
ROOT_CANONICAL="$(canonical_path "$ROOT_DIR")"
SCRATCH_CANONICAL="$(canonical_path "$SCRATCH_ROOT")"
DEFAULT_SCRATCH_CANONICAL="$(canonical_path "$DEFAULT_SCRATCH_ROOT")"
[[ "$SCRATCH_CANONICAL" != "/" ]] || fail "refusing to use / as the public SwiftPM scratch root"
[[ "$SCRATCH_CANONICAL" != "$ROOT_CANONICAL" ]] || fail "refusing to use the repository root as public SwiftPM scratch"
[[ "$ROOT_CANONICAL" != "$SCRATCH_CANONICAL/"* ]] || fail "refusing to use a repository ancestor as public SwiftPM scratch: $SCRATCH_CANONICAL"
if [[ ( -e "$SCRATCH_ROOT" || -L "$SCRATCH_ROOT" ) && "$SCRATCH_CANONICAL" != "$DEFAULT_SCRATCH_CANONICAL" && ! -f "$SCRATCH_ROOT/$SCRATCH_SENTINEL_NAME" ]]; then
    fail "refusing to use unmarked public SwiftPM scratch path: $SCRATCH_ROOT"
fi
case "$CLEAN_PUBLIC_SWIFTPM_BUILDS" in
    1)
        run rm -rf "$SCRATCH_ROOT"
        ;;
    0) ;;
    *) fail "REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS must be 0 or 1" ;;
esac
run mkdir -p "$SCRATCH_ROOT"
printf 'RepoPrompt CE universal public SwiftPM scratch\n' > "$SCRATCH_ROOT/$SCRATCH_SENTINEL_NAME"

ARM64_BIN_DIR=""
X86_64_BIN_DIR=""
for arch in arm64 x86_64; do
    scratch="$SCRATCH_ROOT/$arch"
    run env \
        REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS" \
        REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch" \
        "$KEYBOARD_SHORTCUTS_PATCH_HELPER" "$ROOT_DIR"
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build \
        -c release \
        --arch "$arch" \
        --scratch-path "$scratch" \
        --product RepoPrompt
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build \
        -c release \
        --arch "$arch" \
        --scratch-path "$scratch" \
        --product repoprompt-mcp
    printf '+ %q ' "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path
    printf '\n'
    bin_dir="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)"
    if [[ "$arch" == "arm64" ]]; then
        ARM64_BIN_DIR="$bin_dir"
    else
        X86_64_BIN_DIR="$bin_dir"
    fi
    require_exact_arch "$bin_dir/RepoPrompt" "$arch"
    require_exact_arch "$bin_dir/repoprompt-mcp" "$arch"
done

run "$RESOURCE_COMPARATOR" "$ARM64_BIN_DIR" "$X86_64_BIN_DIR"

staged_output="$(mktemp -d "$(dirname "$OUTPUT_DIR")/.public-release-products.XXXXXX")"
cleanup() {
    rm -rf "$staged_output"
}
trap cleanup EXIT

run "$LIPO" -create \
    "$ARM64_BIN_DIR/RepoPrompt" \
    "$X86_64_BIN_DIR/RepoPrompt" \
    -output "$staged_output/RepoPrompt"
run "$LIPO" -create \
    "$ARM64_BIN_DIR/repoprompt-mcp" \
    "$X86_64_BIN_DIR/repoprompt-mcp" \
    -output "$staged_output/repoprompt-mcp"
run chmod +x "$staged_output/RepoPrompt" "$staged_output/repoprompt-mcp"
require_exact_arch "$staged_output/RepoPrompt" "arm64,x86_64"
require_exact_arch "$staged_output/repoprompt-mcp" "arm64,x86_64"

for resource in "$ARM64_BIN_DIR"/*.bundle "$ARM64_BIN_DIR/Sparkle.framework"; do
    [[ -e "$resource" ]] || continue
    run ditto "$resource" "$staged_output/$(basename "$resource")"
done

run rm -rf "$OUTPUT_DIR"
run mv "$staged_output" "$OUTPUT_DIR"
trap - EXIT
printf 'OK: universal SwiftPM release products created at %s\n' "$OUTPUT_DIR"
