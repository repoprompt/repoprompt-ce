#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SWIFT_JOBS="${SWIFT_JOBS:-4}"
swift build --configuration release --jobs "$SWIFT_JOBS" --product repoprompt-mcp
BINARY="$(swift build --configuration release --show-bin-path)/repoprompt-mcp"

"$BINARY" --version
python3 Scripts/test_linux_headless_mcp.py binary "$BINARY"
