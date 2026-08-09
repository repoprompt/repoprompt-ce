#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${1:-repoprompt-ce-headless:local}"
docker build --file Dockerfile.headless --tag "$IMAGE" .
docker run --rm --entrypoint /usr/local/bin/repoprompt-mcp "$IMAGE" --version
python3 Scripts/test_linux_headless_mcp.py docker "$IMAGE"
