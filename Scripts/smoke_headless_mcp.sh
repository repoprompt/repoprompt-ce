#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
BINARY_NAME="repoprompt-headless"
CONF="debug"
PACKAGE_FIRST=1
BINARY="${REPOPROMPT_HEADLESS_BINARY:-}"
SMOKE_ROOT=""

fail() { echo "ERROR: $*" >&2; exit 1; }
echo_cmd() { printf '+ '; printf '%q ' "$@"; printf '\n'; }
run() { echo_cmd "$@"; "$@"; }

usage() {
	cat <<EOF
Usage: $0 [--configuration debug|release] [--binary PATH] [--skip-package]

Runs a standalone RepoPrompt Headless MCP smoke test without launching RepoPrompt.app.
The smoke uses a temp state directory and temp allowed root, then validates:
initialize, tools/list, read_file, file_search, export permission rejection, and shutdown.

Options:
  --configuration debug|release   Product configuration to package/resolve (default: debug)
  --binary PATH                   Use an explicit repoprompt-headless binary
  --skip-package                  Do not run Scripts/package_headless.sh first
EOF
}

while (( $# > 0 )); do
	case "$1" in
		--configuration)
			shift
			[[ $# -gt 0 ]] || fail "--configuration requires debug or release"
			case "$1" in
				debug|release) CONF="$1" ;;
				*) fail "--configuration must be debug or release, got '$1'" ;;
			esac
			;;
		--binary)
			shift
			[[ $# -gt 0 ]] || fail "--binary requires a path"
			BINARY="$1"
			PACKAGE_FIRST=0
			;;
		--skip-package) PACKAGE_FIRST=0 ;;
		--help|-h) usage; exit 0 ;;
		*) fail "Unknown option: $1" ;;
	esac
	shift
done

config_label() {
	case "$1" in
		debug) printf 'Debug' ;;
		release) printf 'Release' ;;
		*) fail "Unknown configuration '$1'" ;;
	esac
}

cleanup() {
	if [[ -n "$SMOKE_ROOT" ]]; then
		rm -rf "$SMOKE_ROOT"
	fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

if [[ -z "$BINARY" ]]; then
	if (( PACKAGE_FIRST )); then
		run "$ROOT_DIR/Scripts/package_headless.sh" "$CONF"
		BINARY="$HEADLESS_TOOLS_ROOT/$(config_label "$CONF")/$BINARY_NAME"
	else
		echo_cmd "$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path
		BUILD_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build -c "$CONF" --show-bin-path)"
		BINARY="$BUILD_DIR/$BINARY_NAME"
	fi
fi

[[ -x "$BINARY" ]] || fail "Headless binary is not executable: $BINARY"

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-headless-smoke.XXXXXX")"
STATE_DIR="$SMOKE_ROOT/state"
FIXTURE_DIR="$SMOKE_ROOT/fixture-root"
OUTSIDE_EXPORT="$SMOKE_ROOT/outside-workspace-context.md"
SYMLINK_EXPORT_TARGET="$SMOKE_ROOT/outside-export-target"
mkdir -p "$STATE_DIR" "$STATE_DIR/Exports" "$FIXTURE_DIR/Sources" "$SYMLINK_EXPORT_TARGET"
ln -s "$SYMLINK_EXPORT_TARGET" "$STATE_DIR/Exports/escape-link"
cat > "$FIXTURE_DIR/README.md" <<'EOF'
# Headless Smoke Fixture

This fixture contains headless-smoke-token for content search.
EOF
cat > "$FIXTURE_DIR/Sources/Sample.swift" <<'EOF'
struct HeadlessSmokeSample {
    let marker = "headless-smoke-token"
}
EOF

run "$BINARY" --state-dir "$STATE_DIR" config roots add "$FIXTURE_DIR" --name Fixture
run "$BINARY" --state-dir "$STATE_DIR" doctor
run "$BINARY" --state-dir "$STATE_DIR" config permissions list

REPOPROMPT_HEADLESS_SMOKE_BINARY="$BINARY" \
REPOPROMPT_HEADLESS_SMOKE_STATE_DIR="$STATE_DIR" \
REPOPROMPT_HEADLESS_SMOKE_OUTSIDE_EXPORT="$OUTSIDE_EXPORT" \
python3 - <<'PY'
import json
import os
import subprocess
import sys

binary = os.environ["REPOPROMPT_HEADLESS_SMOKE_BINARY"]
state_dir = os.environ["REPOPROMPT_HEADLESS_SMOKE_STATE_DIR"]
outside_export = os.environ["REPOPROMPT_HEADLESS_SMOKE_OUTSIDE_EXPORT"]

requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "headless-smoke", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 1, "limit": 5}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 3, "limit": 1}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "file_search", "arguments": {"pattern": "headless-smoke-token", "mode": "content", "path": "Fixture", "max_results": 5, "regex": False}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "workspace_context", "arguments": {"op": "export", "include": ["prompt", "selection", "tokens"], "path": outside_export}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "workspace_context", "arguments": {"op": "export", "include": ["prompt", "selection", "tokens"], "path": "escape-link/escaped.md"}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "apply_edits", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": {}},
]
stdin = "\n".join(json.dumps(request, separators=(",", ":")) for request in requests) + "\n"
completed = subprocess.run(
    [binary, "--state-dir", state_dir, "serve"],
    input=stdin,
    text=True,
    capture_output=True,
    timeout=30,
)
if completed.returncode != 0:
    sys.stderr.write(completed.stderr)
    raise SystemExit(f"headless serve exited with {completed.returncode}")

responses = []
for line in completed.stdout.splitlines():
    if line.strip():
        responses.append(json.loads(line))
by_id = {response.get("id"): response for response in responses}
expected_ids = {1, 2, 3, 4, 5, 6, 7, 8, 99}
missing = expected_ids - set(by_id)
if missing:
    raise SystemExit(f"missing JSON-RPC response id(s): {sorted(missing)}\nstdout={completed.stdout}\nstderr={completed.stderr}")

init = by_id[1]["result"]
if init.get("serverInfo", {}).get("name") != "RepoPrompt Headless":
    raise SystemExit(f"unexpected serverInfo: {init.get('serverInfo')}")
if init.get("headless", {}).get("configuredRootCount") != 1:
    raise SystemExit(f"expected one configured root, got {init.get('headless')}")

tools = [tool.get("name") for tool in by_id[2]["result"].get("tools", [])]
required_tools = {"bind_context", "manage_workspaces", "manage_selection", "workspace_context", "get_file_tree", "get_code_structure", "read_file", "file_search", "prompt"}
missing_tools = required_tools - set(tools)
if missing_tools:
    raise SystemExit(f"tools/list missing safe tools: {sorted(missing_tools)}")
for forbidden in ("apply_edits", "git", "agent_run", "app_settings"):
    if forbidden in tools:
        raise SystemExit(f"forbidden tool exposed by headless safe profile: {forbidden}")

read_result = by_id[3]["result"]
if read_result.get("isError") is not False:
    raise SystemExit(f"read_file unexpectedly failed: {read_result}")
if "headless-smoke-token" not in read_result.get("structuredContent", {}).get("content", ""):
    raise SystemExit("read_file did not return fixture token")

single_line_result = by_id[4]["result"]
if single_line_result.get("isError") is not False:
    raise SystemExit(f"single-line read_file unexpectedly failed: {single_line_result}")
single_line_structured = single_line_result.get("structuredContent", {})
expected_line = "This fixture contains headless-smoke-token for content search."
if single_line_structured.get("content") != expected_line:
    raise SystemExit(f"single-line read_file returned unexpected content: {single_line_structured}")
if single_line_structured.get("first_line") != 3 or single_line_structured.get("last_line") != 3:
    raise SystemExit(f"single-line read_file reported wrong bounds: {single_line_structured}")

search_result = by_id[5]["result"]
if search_result.get("isError") is not False:
    raise SystemExit(f"file_search unexpectedly failed: {search_result}")
if search_result.get("structuredContent", {}).get("total_matches", 0) < 1:
    raise SystemExit(f"file_search did not report a match: {search_result}")

export_result = by_id[6]["result"]
if export_result.get("isError") is not True:
    raise SystemExit(f"workspace_context export outside state should be rejected: {export_result}")
export_text = "\n".join(item.get("text", "") for item in export_result.get("content", []))
if "export_outside_state_directory is false" not in export_text:
    raise SystemExit(f"workspace_context rejection did not mention export permission: {export_text}")

symlink_export_result = by_id[7]["result"]
if symlink_export_result.get("isError") is not True:
    raise SystemExit(f"workspace_context export through Exports symlink should be rejected: {symlink_export_result}")
symlink_export_text = "\n".join(item.get("text", "") for item in symlink_export_result.get("content", []))
if "export_outside_state_directory is false" not in symlink_export_text and "escapes the headless Exports directory" not in symlink_export_text:
    raise SystemExit(f"symlink export rejection did not mention containment policy: {symlink_export_text}")

policy_result = by_id[8]["result"]
if policy_result.get("isError") is not True:
    raise SystemExit(f"gated apply_edits call should be rejected: {policy_result}")
policy_text = "\n".join(item.get("text", "") for item in policy_result.get("content", []))
if "not available in RepoPrompt Headless v1" not in policy_text:
    raise SystemExit(f"gated tool rejection message drifted: {policy_text}")

if by_id[99].get("result", "not-null") is not None:
    raise SystemExit(f"shutdown result should be null: {by_id[99]}")

print("Headless MCP smoke passed")
PY

printf 'Headless smoke binary: %s\n' "$BINARY"
printf 'Headless smoke state: %s\n' "$STATE_DIR"
printf 'Headless smoke fixture: %s\n' "$FIXTURE_DIR"
