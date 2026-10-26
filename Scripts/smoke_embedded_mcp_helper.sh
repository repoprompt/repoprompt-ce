#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
SMOKE_LABEL="${2:-Embedded MCP helper}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle> [label]"
[[ -d "$APP_BUNDLE" ]] || fail "Missing app bundle: $APP_BUNDLE"

MCP_HELPER="$(python3 - "$APP_BUNDLE" <<'PYTHON'
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve(strict=True)
helper = (app / "Contents" / "MacOS" / "repoprompt-mcp").resolve(strict=True)
if not helper.is_relative_to(app):
    raise SystemExit(f"ERROR: canonical MCP helper escapes app bundle: {helper}")
mode = helper.lstat().st_mode
if not stat.S_ISREG(mode) or not mode & 0o111:
    raise SystemExit(f"ERROR: canonical MCP helper is not an executable regular file: {helper}")
print(helper)
PYTHON
)"
[[ -n "$MCP_HELPER" ]] || fail "Could not resolve contained executable MCP helper"

status=0
"$MCP_HELPER" --version || status=$?
(( status == 0 )) ||
    fail "$SMOKE_LABEL failed --version smoke (exit $status): $MCP_HELPER"

printf 'OK: %s passed --version smoke.\n' "$SMOKE_LABEL"
