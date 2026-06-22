#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
BINARY_NAME="repoprompt-headless"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

tmp_binary=""
cleanup() { [[ -z "$tmp_binary" ]] || rm -f "$tmp_binary"; }
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
run() { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }

usage() {
	cat <<EOF
Usage: $0 [debug|release]

Builds, signs, stages, and records provenance for standalone RepoPrompt Headless.
It never packages or launches RepoPrompt.app and never touches repoprompt-mcp.
EOF
}

case "$CONF" in
	debug) CONFIG_LABEL="Debug" ;;
	release) CONFIG_LABEL="Release" ;;
	--help|-h) usage; exit 0 ;;
	*) fail "Unknown configuration '$CONF'. Expected debug or release." ;;
esac

cd "$ROOT_DIR"
source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"
: "${MARKETING_VERSION:?missing MARKETING_VERSION}"
: "${BUILD_NUMBER:?missing BUILD_NUMBER}"

python3 - "$ROOT_DIR/Sources/RepoPromptHeadless/HeadlessVersion.swift" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for field, expected in (("marketingVersion", sys.argv[2]), ("buildNumber", sys.argv[3])):
	match = re.search(rf'static let {field} = "([^"]+)"', text)
	if not match or match.group(1) != expected:
		raise SystemExit(f"HeadlessVersion.{field} must be generated from version.env ({expected})")
PY

TARGET_DIR="$HEADLESS_TOOLS_ROOT/$CONFIG_LABEL"
TARGET_BINARY="$TARGET_DIR/$BINARY_NAME"
MANIFEST="$TARGET_DIR/artifact-manifest.json"
run mkdir -p "$HEADLESS_TOOLS_ROOT" "$TARGET_DIR"
run chmod 700 "$HEADLESS_TOOLS_ROOT" "$TARGET_DIR"

if [[ "$CONF" == "release" ]]; then
	BUILT_BINARY="$ROOT_DIR/.build/headless-release/$BINARY_NAME"
	run "$CONTROL_PLANE_SCRIPTS_DIR/build_headless_release_product.sh" "$BUILT_BINARY"
	EXPECTED_ARCHITECTURES="arm64,x86_64"
else
	run "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c debug --product "$BINARY_NAME"
	BUILD_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c debug --show-bin-path)"
	BUILT_BINARY="$BUILD_DIR/$BINARY_NAME"
	EXPECTED_ARCHITECTURES="$(/usr/bin/lipo -archs "$BUILT_BINARY" | tr ' ' ',')"
fi
[[ -x "$BUILT_BINARY" ]] || fail "Missing built executable: $BUILT_BINARY"

tmp_binary="$(mktemp "$TARGET_DIR/.${BINARY_NAME}.tmp.XXXXXX")"
run cp "$BUILT_BINARY" "$tmp_binary"
run chmod 700 "$tmp_binary"
run /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$tmp_binary"
run /usr/bin/codesign --verify --strict --verbose=2 "$tmp_binary"
run "$tmp_binary" --version
run mv -f "$tmp_binary" "$TARGET_BINARY"
tmp_binary=""

run python3 "$CONTROL_PLANE_SCRIPTS_DIR/headless_artifact_manifest.py" write \
	--binary "$TARGET_BINARY" \
	--output "$MANIFEST" \
	--source-root "$ROOT_DIR" \
	--configuration "$CONF" \
	--version "$MARKETING_VERSION" \
	--build "$BUILD_NUMBER" \
	--expected-architectures "$EXPECTED_ARCHITECTURES"
run python3 "$CONTROL_PLANE_SCRIPTS_DIR/headless_artifact_manifest.py" verify \
	--binary "$TARGET_BINARY" \
	--manifest "$MANIFEST" \
	--source-root "$ROOT_DIR" \
	--configuration "$CONF" \
	--version "$MARKETING_VERSION" \
	--build "$BUILD_NUMBER" \
	--expected-architectures "$EXPECTED_ARCHITECTURES"
run chmod 600 "$MANIFEST"
printf 'Created standalone headless artifact: %s\nManifest: %s\n' "$TARGET_BINARY" "$MANIFEST"
