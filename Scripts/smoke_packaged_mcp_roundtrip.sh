#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="${1:-}"
SMOKE_LABEL="${2:-Packaged MCP roundtrip}"
ARTIFACT_MANIFEST="${3:-}"
EXPECTED_ARCHITECTURES="${REPOPROMPT_EXPECTED_ARCHITECTURES:-arm64,x86_64}"
ROUNDTRIP_TIMEOUT="${REPOPROMPT_PACKAGED_SMOKE_TIMEOUT:-60}"
SOCKET_OWNER_HELPER="$SCRIPT_DIR/verify_packaged_mcp_socket_owner.py"
MCP_SOCKET_DIR="${REPOPROMPT_PACKAGED_SMOKE_SOCKET_DIR:-/tmp/repoprompt-ce-mcp-$(id -u)}"
APP_PID=""
APP_COMMAND=""
APP_START=""
TEMP_ROOT=""
APP_LOG=""
MCP_SOCKET_PATH=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

process_matches() {
    [[ -n "$APP_PID" ]] || return 1
    kill -0 "$APP_PID" 2>/dev/null || return 1
    local command start
    command="$(ps -p "$APP_PID" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
    start="$(ps -p "$APP_PID" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//')"
    [[ "$command" == "$APP_COMMAND" ]] || return 1
    [[ -z "$APP_START" || "$start" == "$APP_START" ]]
}

cleanup() {
    local status=$?
    if process_matches; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            process_matches || break
            sleep 0.5
        done
        if process_matches; then
            kill -KILL "$APP_PID" 2>/dev/null || true
        fi
        wait "$APP_PID" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -n "$APP_LOG" && -f "$APP_LOG" ]]; then
        printf '%s\n' "--- packaged app log tail ---" >&2
        tail -100 "$APP_LOG" >&2 || true
    fi
    [[ -z "$TEMP_ROOT" ]] || rm -rf "$TEMP_ROOT"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -n "$APP_BUNDLE" ]] || fail "usage: $0 <app-bundle> [label] [artifact-manifest]"
[[ -x "$SOCKET_OWNER_HELPER" ]] || fail "missing packaged MCP socket ownership verifier: $SOCKET_OWNER_HELPER"
"$SCRIPT_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "$SMOKE_LABEL layout"
"$SCRIPT_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "$EXPECTED_ARCHITECTURES" "$SMOKE_LABEL architectures"
if [[ -n "$ARTIFACT_MANIFEST" ]]; then
    "$SCRIPT_DIR/write_app_artifact_manifest.py" verify \
        --app "$APP_BUNDLE" \
        --manifest "$ARTIFACT_MANIFEST" \
        --expected-architectures "$EXPECTED_ARCHITECTURES"
fi

CANONICAL_PATHS="$(python3 - "$APP_BUNDLE" <<'PYTHON'
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve(strict=True)
app_executable = (app / "Contents" / "MacOS" / "RepoPrompt").resolve(strict=True)
helper = (app / "Contents" / "MacOS" / "repoprompt-mcp").resolve(strict=True)
for label, path in (("app executable", app_executable), ("MCP helper", helper)):
    if not path.is_relative_to(app):
        raise SystemExit(f"ERROR: canonical {label} escapes app bundle: {path}")
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode) or not mode & 0o111:
        raise SystemExit(f"ERROR: canonical {label} is not an executable regular file: {path}")
print(app_executable)
print(helper)
PYTHON
)"
APP_EXECUTABLE="$(printf '%s\n' "$CANONICAL_PATHS" | sed -n '1p')"
MCP_HELPER="$(printf '%s\n' "$CANONICAL_PATHS" | sed -n '2p')"
[[ -n "$APP_EXECUTABLE" && -n "$MCP_HELPER" ]] || fail "could not resolve contained packaged executables"

"$SCRIPT_DIR/smoke_embedded_mcp_helper.sh" "$APP_BUNDLE" "$SMOKE_LABEL early helper"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-packaged-smoke.XXXXXX")"
ISOLATED_HOME="$TEMP_ROOT/home"
ISOLATED_TMP="$TEMP_ROOT/tmp"
APP_LOG="$TEMP_ROOT/app.log"
mkdir -p "$ISOLATED_HOME" "$ISOLATED_TMP"
chmod 700 "$TEMP_ROOT" "$ISOLATED_HOME" "$ISOLATED_TMP"

"$SOCKET_OWNER_HELPER" preflight "$MCP_SOCKET_DIR" ||
    fail "$SMOKE_LABEL requires no pre-existing live release MCP socket in $MCP_SOCKET_DIR"

MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
APP_COMMAND="$APP_EXECUTABLE"
env -i \
    PATH="$MINIMAL_PATH" \
    HOME="$ISOLATED_HOME" \
    CFFIXED_USER_HOME="$ISOLATED_HOME" \
    TMPDIR="$ISOLATED_TMP/" \
    USER="${USER:-runner}" \
    LOGNAME="${LOGNAME:-${USER:-runner}}" \
    LANG=C \
    LC_ALL=C \
    "$APP_EXECUTABLE" >"$APP_LOG" 2>&1 &
APP_PID=$!
sleep 0.2
ACTUAL_COMMAND="$(ps -p "$APP_PID" -o command= 2>/dev/null | sed 's/^[[:space:]]*//')"
APP_START="$(ps -p "$APP_PID" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//')"
[[ -n "$ACTUAL_COMMAND" && -n "$APP_START" ]] || fail "could not record launched packaged app process identity"
[[ "$ACTUAL_COMMAND" == "$APP_EXECUTABLE" ]] ||
    fail "launched process identity mismatch: expected $APP_EXECUTABLE, got $ACTUAL_COMMAND"
APP_COMMAND="$ACTUAL_COMMAND"
printf '{"pid":%s,"command":"%s","start":"%s"}\n' \
    "$APP_PID" \
    "${APP_COMMAND//\"/\\\"}" \
    "${APP_START//\"/\\\"}" \
    > "$TEMP_ROOT/launched-process.json"

run_windows_request() {
    python3 - "$MCP_HELPER" "$ISOLATED_HOME" "$ISOLATED_TMP" <<'PYTHON'
import os
import subprocess
import sys

helper, home, temporary = sys.argv[1:]
environment = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": home,
    "CFFIXED_USER_HOME": home,
    "TMPDIR": temporary + "/",
    "USER": os.environ.get("USER", "runner"),
    "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "runner")),
    "LANG": "C",
    "LC_ALL": "C",
}
try:
    completed = subprocess.run(
        [helper, "-e", "windows"],
        env=environment,
        text=True,
        capture_output=True,
        timeout=10,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
if completed.stdout:
    print(completed.stdout, end="")
if completed.stderr:
    print(completed.stderr, end="", file=sys.stderr)
raise SystemExit(completed.returncode)
PYTHON
}

deadline=$(( $(date +%s) + ROUNDTRIP_TIMEOUT ))
last_status=75
while (( $(date +%s) <= deadline )); do
    process_matches || fail "packaged app exited before MCP bootstrap completed"
    if [[ -z "$MCP_SOCKET_PATH" ]]; then
        set +e
        MCP_SOCKET_PATH="$("$SOCKET_OWNER_HELPER" find-owner "$MCP_SOCKET_DIR" "$APP_PID" "$APP_EXECUTABLE" 2>"$TEMP_ROOT/socket-owner.err")"
        owner_status=$?
        set -e
        if (( owner_status == 75 )); then
            MCP_SOCKET_PATH=""
            sleep 1
            continue
        fi
        if (( owner_status != 0 )); then
            cat "$TEMP_ROOT/socket-owner.err" >&2 || true
            fail "$SMOKE_LABEL could not prove the launched app owns the release MCP socket"
        fi
        [[ -n "$MCP_SOCKET_PATH" ]] || fail "$SMOKE_LABEL ownership verifier returned an empty socket path"
    fi

    "$SOCKET_OWNER_HELPER" verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE" ||
        fail "$SMOKE_LABEL launched app no longer owns the release MCP socket: $MCP_SOCKET_PATH"
    set +e
    run_windows_request
    last_status=$?
    set -e
    if (( last_status == 0 )); then
        "$SOCKET_OWNER_HELPER" verify-owner "$MCP_SOCKET_PATH" "$APP_PID" "$APP_EXECUTABLE" ||
            fail "$SMOKE_LABEL release MCP socket ownership changed during the helper request"
        printf 'OK: %s completed bootstrap and windows request with exact helper %s against launched pid %s socket %s\n' \
            "$SMOKE_LABEL" "$MCP_HELPER" "$APP_PID" "$MCP_SOCKET_PATH"
        exit 0
    fi
    (( last_status == 1 || last_status == 124 )) ||
        fail "$SMOKE_LABEL helper request failed with exit $last_status: $MCP_HELPER"
    sleep 1
done

fail "$SMOKE_LABEL timed out waiting for bootstrap/windows response (last exit $last_status)"
