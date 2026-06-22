#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
OUTPUT="${1:-$ROOT_DIR/.build/headless-release/repoprompt-headless}"
PRODUCT="repoprompt-headless"
ARCHITECTURES=(arm64 x86_64)

fail() { echo "ERROR: $*" >&2; exit 1; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OUTPUT")"
inputs=()
for arch in "${ARCHITECTURES[@]}"; do
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --product "$PRODUCT"
    bin_dir="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c release --arch "$arch" --show-bin-path)"
    binary="$bin_dir/$PRODUCT"
    [[ -x "$binary" ]] || fail "missing $arch release binary: $binary"
    observed="$(/usr/bin/lipo -archs "$binary")"
    [[ " $observed " == *" $arch "* ]] || fail "$binary does not contain $arch"
    inputs+=("$binary")
done

temporary="$(mktemp "$(dirname "$OUTPUT")/.repoprompt-headless.universal.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
run /usr/bin/lipo -create "${inputs[@]}" -output "$temporary"
run chmod 700 "$temporary"
[[ "$(/usr/bin/lipo -archs "$temporary")" == *arm64* && "$(/usr/bin/lipo -archs "$temporary")" == *x86_64* ]] ||
    fail "universal headless binary is missing an architecture"
run mv -f "$temporary" "$OUTPUT"
trap - EXIT
printf 'Created universal headless product: %s\n' "$OUTPUT"
