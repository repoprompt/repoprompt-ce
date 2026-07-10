#!/usr/bin/env bash
set -euo pipefail
[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD="$(ROOT_DIR="$ROOT_DIR" python3 - "$@" <<'PY'
from __future__ import annotations

import json
import os
import sys

print(json.dumps({
    "kind": "debug_app_build_then_launch",
    "repoRoot": os.environ["ROOT_DIR"],
    "args": {"appArgs": sys.argv[1:]},
}))
PY
)"

exec python3 -u "$ROOT_DIR/Scripts/conductor.py" __operation_runner "$PAYLOAD"
