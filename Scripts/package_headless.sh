#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
BINARY_NAME="repoprompt-headless"

tmp_binary=""
cleanup() {
	if [[ -n "$tmp_binary" ]]; then
		rm -f "$tmp_binary"
	fi
}
trap cleanup EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }
echo_cmd() { printf '+ '; printf '%q ' "$@"; printf '\n'; }
run() { echo_cmd "$@"; "$@"; }

usage() {
	cat <<EOF
Usage: $0 [debug|release]

Builds and stages the standalone RepoPrompt CE headless MCP host outside the app bundle.

Managed artifacts:
  $HEADLESS_TOOLS_ROOT/Debug/$BINARY_NAME
  $HEADLESS_TOOLS_ROOT/Release/$BINARY_NAME

Environment overrides:
  REPOPROMPT_HEADLESS_TOOLS_ROOT   Root for staged headless tools
  REPOPROMPT_RELEASE_SOURCE_ROOT   Source checkout root
EOF
}

case "$CONF" in
	debug) CONFIG_LABEL="Debug" ;;
	release) CONFIG_LABEL="Release" ;;
	--help|-h) usage; exit 0 ;;
	*) fail "Unknown configuration '$CONF'. Expected debug or release." ;;
esac

cd "$ROOT_DIR"

TARGET_DIR="$HEADLESS_TOOLS_ROOT/$CONFIG_LABEL"
TARGET_BINARY="$TARGET_DIR/$BINARY_NAME"

printf 'RepoPrompt Headless package (%s)\n' "$CONF"
printf 'Source root: %s\n' "$ROOT_DIR"
printf 'Target binary: %s\n' "$TARGET_BINARY"

run "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --product "$BINARY_NAME"

echo_cmd "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path
BUILD_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path)"
BUILT_BINARY="$BUILD_DIR/$BINARY_NAME"
[[ -x "$BUILT_BINARY" ]] || fail "Missing built executable: $BUILT_BINARY"

run mkdir -p "$TARGET_DIR"
tmp_binary="$TARGET_DIR/.${BINARY_NAME}.tmp.$$"
run cp "$BUILT_BINARY" "$tmp_binary"
run chmod +x "$tmp_binary"
run "$tmp_binary" --version
run mv -f "$tmp_binary" "$TARGET_BINARY"
tmp_binary=""

printf 'Created: %s\n' "$TARGET_BINARY"
