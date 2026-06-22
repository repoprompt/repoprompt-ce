#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
source "$ROOT_DIR/Scripts/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"
case "$CONF" in
    debug) LABEL="Debug"; EXPECTED="$(uname -m)" ;;
    release) LABEL="Release"; EXPECTED="arm64,x86_64" ;;
    *) echo "ERROR: expected debug or release" >&2; exit 2 ;;
esac
BINARY="$HEADLESS_TOOLS_ROOT/$LABEL/repoprompt-headless"
MANIFEST="$HEADLESS_TOOLS_ROOT/$LABEL/artifact-manifest.json"
/usr/bin/codesign --verify --strict --verbose=2 "$BINARY"
python3 "$ROOT_DIR/Scripts/verify_tree_sitter_symbols.py" \
    --binary "$BINARY" --expect exact --label "Staged RepoPrompt Headless"
python3 "$ROOT_DIR/Scripts/headless_artifact_manifest.py" verify \
    --binary "$BINARY" --manifest "$MANIFEST" --source-root "$ROOT_DIR" \
    --configuration "$CONF" --version "$MARKETING_VERSION" --build "$BUILD_NUMBER" \
    --expected-architectures "$EXPECTED"
