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

SMOKE_ROOT="$(mktemp -d "${REPOPROMPT_HEADLESS_SMOKE_TMPDIR:-/tmp}/rphs.XXXXXX")"
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
: > "$FIXTURE_DIR/Empty.txt"
mkdir -p "$FIXTURE_DIR/Search" "$FIXTURE_DIR/LinkedTarget"
printf 'linked\n' > "$FIXTURE_DIR/LinkedTarget/value.txt"
ln -s "$FIXTURE_DIR/README.md" "$FIXTURE_DIR/leaf-link.md"
ln -s "$FIXTURE_DIR/LinkedTarget" "$FIXTURE_DIR/intermediate-link"
mkfifo "$FIXTURE_DIR/read-fifo"
for index in 1 2 3 4; do
	printf 'needle\n' > "$FIXTURE_DIR/Search/needle-$index.txt"
done

run "$BINARY" --state-dir "$STATE_DIR" config roots add "$FIXTURE_DIR" --name Fixture
run "$BINARY" --state-dir "$STATE_DIR" doctor
run "$BINARY" --state-dir "$STATE_DIR" config permissions list

REPOPROMPT_HEADLESS_SMOKE_BINARY="$BINARY" \
REPOPROMPT_HEADLESS_SMOKE_STATE_DIR="$STATE_DIR" \
REPOPROMPT_HEADLESS_SMOKE_OUTSIDE_EXPORT="$OUTSIDE_EXPORT" \
REPOPROMPT_HEADLESS_SMOKE_FIXTURE_DIR="$FIXTURE_DIR" \
python3 - <<'PY'
import json
import os
import socket
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

binary = os.environ["REPOPROMPT_HEADLESS_SMOKE_BINARY"]
state_dir = os.environ["REPOPROMPT_HEADLESS_SMOKE_STATE_DIR"]
outside_export = os.environ["REPOPROMPT_HEADLESS_SMOKE_OUTSIDE_EXPORT"]
fixture_dir = os.environ["REPOPROMPT_HEADLESS_SMOKE_FIXTURE_DIR"]

def encode(message):
    return json.dumps(message, separators=(",", ":")).encode()

def run_raw(payload):
    # Use files instead of bidirectional pipes because the server can respond
    # before the parent has finished supplying an oversized input frame.
    with tempfile.TemporaryFile() as stdin_file, \
            tempfile.TemporaryFile() as stdout_file, \
            tempfile.TemporaryFile() as stderr_file:
        stdin_file.write(payload)
        stdin_file.seek(0)
        completed = subprocess.run(
            [binary, "--state-dir", state_dir, "serve"],
            stdin=stdin_file,
            stdout=stdout_file,
            stderr=stderr_file,
            timeout=30,
        )
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read()
        stderr = stderr_file.read()
    completed.stdout = stdout
    completed.stderr = stderr
    if completed.returncode != 0:
        sys.stderr.write(stderr.decode(errors="replace"))
        raise SystemExit(f"headless serve exited with {completed.returncode}")
    responses = []
    for line in stdout.splitlines():
        if line.strip():
            responses.append(json.loads(line))
    return responses, completed

def run_messages(messages, suffix=b"\n"):
    payload = b"\n".join(encode(message) for message in messages) + suffix
    return run_raw(payload)[0]

def by_id(responses):
    return {response.get("id"): response for response in responses if "id" in response}

def require_rpc_error(response, label):
    if not isinstance(response, dict) or "error" not in response:
        raise SystemExit(f"{label} should be a JSON-RPC error: {response}")

def require_tool_error(response, label):
    result = response.get("result", {})
    if result.get("isError") is not True:
        raise SystemExit(f"{label} should be a tool error: {response}")

initialize = lambda request_id: {
    "jsonrpc": "2.0", "id": request_id, "method": "initialize",
    "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "headless-smoke", "version": "1"}},
}
initialized = {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
exit_notification = {"jsonrpc": "2.0", "method": "exit"}

# Lifecycle and request/notification contracts.
lifecycle = [
    {"jsonrpc": "2.0", "id": 201, "method": "tools/list", "params": {}},
    initialize(202),
    {"jsonrpc": "2.0", "id": 203, "method": "tools/list", "params": {}},
    initialized,
    initialize(204),
    {"jsonrpc": "2.0", "id": 205, "method": "notifications/initialized", "params": {}},
    {"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "prompt", "arguments": {"op": "set", "text": "notification-must-not-run"}}},
    {"jsonrpc": "2.0", "id": 208, "method": "tools/call", "params": {"name": "prompt", "arguments": {"op": "get"}}},
    {"jsonrpc": "2.0", "id": 206, "method": "shutdown", "params": {}},
    {"jsonrpc": "2.0", "id": 207, "method": "ping", "params": {}},
    exit_notification,
]
lifecycle_responses = by_id(run_messages(lifecycle))
for request_id in (201, 203, 204, 205, 207):
    require_rpc_error(lifecycle_responses.get(request_id), f"lifecycle request {request_id}")
if lifecycle_responses.get(202, {}).get("result", {}).get("serverInfo", {}).get("name") != "RepoPrompt Headless":
    raise SystemExit(f"initialize failed: {lifecycle_responses.get(202)}")
if lifecycle_responses.get(208, {}).get("result", {}).get("structuredContent", {}).get("prompt") != "":
    raise SystemExit("request-only tools/call notification was executed")
if lifecycle_responses.get(206, {}).get("result", "not-null") is not None:
    raise SystemExit(f"shutdown result should be null: {lifecycle_responses.get(206)}")

# Unterminated frames are never dispatched; whitespace residual EOF is ignored.
unterminated = [initialize(301), initialized]
unterminated_payload = b"\n".join(encode(message) for message in unterminated) + b"\n" + encode({
    "jsonrpc": "2.0", "id": 302, "method": "tools/call",
    "params": {"name": "prompt", "arguments": {"op": "set", "text": "unterminated-must-not-run"}},
})
unterminated_responses, _ = run_raw(unterminated_payload)
if any(response.get("id") == 302 for response in unterminated_responses):
    raise SystemExit("unterminated EOF frame was dispatched")
if not any(response.get("id") is None and response.get("error", {}).get("code") == -32700 for response in unterminated_responses):
    raise SystemExit(f"unterminated non-whitespace EOF did not report a parse error: {unterminated_responses}")

whitespace_responses, _ = run_raw(encode(initialize(311)) + b"\n" + encode(initialized) + b"\n   \t\r")
if any("error" in response for response in whitespace_responses):
    raise SystemExit(f"whitespace-only EOF residual should be ignored: {whitespace_responses}")
garbage_responses, _ = run_raw(encode(initialize(312)) + b"\n" + encode(initialized) + b"\nnot-json")
if not any(response.get("id") is None and response.get("error", {}).get("code") == -32700 for response in garbage_responses):
    raise SystemExit(f"garbage EOF residual did not report a parse error: {garbage_responses}")

# A single oversized frame is rejected, while following frames still work.
oversized = encode({"jsonrpc": "2.0", "method": "unknown/oversized", "params": {"data": "x" * (1024 * 1024 + 128)}})
oversized_payload = b"\n".join([
    encode(initialize(321)), encode(initialized), oversized,
    encode({"jsonrpc": "2.0", "id": 322, "method": "ping"}),
    encode({"jsonrpc": "2.0", "id": 323, "method": "shutdown"}), encode(exit_notification), b"",
])
oversized_responses, _ = run_raw(oversized_payload)
if not any(response.get("id") is None and response.get("error", {}).get("code") == -32700 for response in oversized_responses):
    raise SystemExit("oversized frame was not rejected")
if by_id(oversized_responses).get(322, {}).get("result") != {}:
    raise SystemExit(f"transport did not recover after oversized frame: {oversized_responses}")

# Two individually valid large frames may arrive together even when their aggregate exceeds the limit.
large_notice = lambda marker: {"jsonrpc": "2.0", "method": "unknown/large", "params": {"marker": marker, "data": "y" * 600000}}
aggregate_responses = run_messages([
    initialize(331), initialized, large_notice(1), large_notice(2),
    {"jsonrpc": "2.0", "id": 332, "method": "ping"},
    {"jsonrpc": "2.0", "id": 333, "method": "shutdown"}, exit_notification,
])
if any(response.get("error", {}).get("code") == -32700 for response in aggregate_responses):
    raise SystemExit("aggregate buffer size was incorrectly treated as a frame limit")
if by_id(aggregate_responses).get(332, {}).get("result") != {}:
    raise SystemExit("valid frame after aggregate large notifications was lost")

socket_path = os.path.join(fixture_dir, "read-socket")
unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
unix_socket.bind(socket_path)
unix_socket.listen(1)

requests = [
    initialize(1), initialized,
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 1, "limit": 5}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 3, "limit": 1}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 2, "limit": 0}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 50}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/Empty.txt", "start_line": 50}}},
    {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": 0}}},
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/README.md", "start_line": -1, "limit": 1}}},
    {"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/leaf-link.md"}}},
    {"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/intermediate-link/value.txt"}}},
    {"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/read-fifo"}}},
    {"jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": {"name": "read_file", "arguments": {"path": "Fixture/read-socket"}}},
    {"jsonrpc": "2.0", "id": 14, "method": "tools/call", "params": {"name": "file_search", "arguments": {"pattern": "needle", "mode": "both", "path": "Fixture/Search", "max_results": 2, "regex": False}}},
    {"jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": {"name": "file_search", "arguments": {"pattern": "needle", "mode": "both", "path": "Fixture/Search", "max_results": 2, "count_only": True, "regex": False}}},
    {"jsonrpc": "2.0", "id": 16, "method": "tools/call", "params": {"name": "workspace_context", "arguments": {"op": "export", "include": ["prompt", "selection", "tokens"], "path": outside_export}}},
    {"jsonrpc": "2.0", "id": 17, "method": "tools/call", "params": {"name": "workspace_context", "arguments": {"op": "export", "include": ["prompt", "selection", "tokens"], "path": "escape-link/escaped.md"}}},
    {"jsonrpc": "2.0", "id": 18, "method": "tools/call", "params": {"name": "apply_edits", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 19, "method": "tools/call", "params": {"name": "manage_selection", "arguments": {"op": "add", "slices": []}}},
    {"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {"name": "manage_selection", "arguments": {"op": "add", "mode": "slices", "paths": ["Fixture/Sources/Sample.swift"]}}},
    {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "manage_selection", "arguments": {"op": "set", "slices": [{"path": "Fixture/Sources/Sample.swift", "ranges": [{"start_line": 1, "end_line": 5, "description": "smoke"}]}]}}},
    {"jsonrpc": "2.0", "id": 22, "method": "tools/call", "params": {"name": "manage_selection", "arguments": {"op": "remove", "slices": [{"path": "Fixture/Sources/Sample.swift", "ranges": [{"start_line": 3, "end_line": 3}]}]}}},
    {"jsonrpc": "2.0", "id": 23, "method": "tools/call", "params": {"name": "manage_selection", "arguments": {"op": "get"}}},
    {"jsonrpc": "2.0", "id": 99, "method": "shutdown", "params": {}},
    exit_notification,
]
responses = run_messages(requests)
unix_socket.close()
by_id_map = by_id(responses)
expected_ids = set(range(1, 24)) | {99}
missing = expected_ids - set(by_id_map)
if missing:
    raise SystemExit(f"missing JSON-RPC response id(s): {sorted(missing)}\nresponses={responses}")

init = by_id_map[1]["result"]
if init.get("serverInfo", {}).get("name") != "RepoPrompt Headless":
    raise SystemExit(f"unexpected serverInfo: {init.get('serverInfo')}")
if init.get("headless", {}).get("configuredRootCount") != 1:
    raise SystemExit(f"expected one configured root, got {init.get('headless')}")

tools = [tool.get("name") for tool in by_id_map[2]["result"].get("tools", [])]
required_tools = {"bind_context", "manage_workspaces", "manage_selection", "workspace_context", "get_file_tree", "get_code_structure", "read_file", "file_search", "prompt"}
if set(tools) != required_tools:
    raise SystemExit(f"safe tool catalog drifted: {tools}")

read_result = by_id_map[3]["result"]
if read_result.get("isError") is not False:
    raise SystemExit(f"read_file unexpectedly failed: {read_result}")
if "headless-smoke-token" not in read_result.get("structuredContent", {}).get("content", ""):
    raise SystemExit("read_file did not return fixture token")

single_line_result = by_id_map[4]["result"]
if single_line_result.get("isError") is not False:
    raise SystemExit(f"single-line read_file unexpectedly failed: {single_line_result}")
single_line_structured = single_line_result.get("structuredContent", {})
expected_line = "This fixture contains headless-smoke-token for content search."
if single_line_structured.get("content") != expected_line + "\n":
    raise SystemExit(f"single-line read_file returned unexpected content: {single_line_structured}")
if single_line_structured.get("first_line") != 3 or single_line_structured.get("last_line") != 3:
    raise SystemExit(f"single-line read_file reported wrong bounds: {single_line_structured}")

zero_limit = by_id_map[5]["result"].get("structuredContent", {})
if zero_limit.get("content") != "" or zero_limit.get("first_line") != 2 or zero_limit.get("last_line") != 1:
    raise SystemExit(f"limit=0 parity failed: {zero_limit}")
beyond = by_id_map[6]["result"].get("structuredContent", {})
if beyond.get("content") != "" or beyond.get("message") != "Requested start_line exceeds file length.":
    raise SystemExit(f"beyond-EOF parity failed: {beyond}")
empty = by_id_map[7]["result"].get("structuredContent", {})
if (empty.get("total_lines"), empty.get("first_line"), empty.get("last_line"), empty.get("message")) != (0, 0, 0, None):
    raise SystemExit(f"empty-file parity failed: {empty}")
for request_id, label in ((8, "start_line=0"), (9, "negative start with limit"), (10, "leaf symlink"), (11, "intermediate symlink"), (12, "FIFO"), (13, "socket")):
    require_tool_error(by_id_map[request_id], label)

search = by_id_map[14]["result"].get("structuredContent", {})
if (search.get("total_path_matches"), search.get("total_content_matches"), search.get("total_matches")) != (4, 4, 8):
    raise SystemExit(f"search totals are inaccurate: {search}")
if search.get("returned_matches") != 2 or search.get("omitted") != 6:
    raise SystemExit(f"search shared-budget accounting is inaccurate: {search}")
count_only = by_id_map[15]["result"].get("structuredContent", {})
if count_only.get("count_only") is not True or count_only.get("returned_matches") != 0 or count_only.get("total_matches") != 8 or count_only.get("omitted") != 6:
    raise SystemExit(f"count_only accounting is inaccurate: {count_only}")
if count_only.get("path_matches") or count_only.get("content_matches"):
    raise SystemExit(f"count_only materialized results: {count_only}")

export_result = by_id_map[16]["result"]
if export_result.get("isError") is not True:
    raise SystemExit(f"workspace_context export outside state should be rejected: {export_result}")
export_text = "\n".join(item.get("text", "") for item in export_result.get("content", []))
if "export_outside_state_directory is false" not in export_text:
    raise SystemExit(f"workspace_context rejection did not mention export permission: {export_text}")

symlink_export_result = by_id_map[17]["result"]
if symlink_export_result.get("isError") is not True:
    raise SystemExit(f"workspace_context export through Exports symlink should be rejected: {symlink_export_result}")
symlink_export_text = "\n".join(item.get("text", "") for item in symlink_export_result.get("content", []))
if "export_outside_state_directory is false" not in symlink_export_text and "escapes the headless Exports directory" not in symlink_export_text:
    raise SystemExit(f"symlink export rejection did not mention containment policy: {symlink_export_text}")

policy_result = by_id_map[18]["result"]
if policy_result.get("isError") is not True:
    raise SystemExit(f"gated apply_edits call should be rejected: {policy_result}")
policy_text = "\n".join(item.get("text", "") for item in policy_result.get("content", []))
if "not available in RepoPrompt Headless v1" not in policy_text:
    raise SystemExit(f"gated tool rejection message drifted: {policy_text}")

require_tool_error(by_id_map[19], "empty slices")
require_tool_error(by_id_map[20], "slice mode paths without ranges")
for request_id in (21, 22, 23):
    if by_id_map[request_id].get("result", {}).get("isError") is not False:
        raise SystemExit(f"selection request {request_id} failed: {by_id_map[request_id]}")
selection = by_id_map[23]["result"].get("structuredContent", {}).get("files", [])
sample = next((entry for entry in selection if entry.get("relative_path") == "Sources/Sample.swift"), None)
if sample is None:
    raise SystemExit(f"slice selection missing after range removal: {selection}")
expected_ranges = [(1, 2, "smoke"), (4, 5, "smoke")]
actual_ranges = [(item.get("start_line"), item.get("end_line"), item.get("description")) for item in sample.get("ranges", [])]
if actual_ranges != expected_ranges:
    raise SystemExit(f"range-level removal widened or removed the selection: {actual_ranges}")

if by_id_map[99].get("result", "not-null") is not None:
    raise SystemExit(f"shutdown result should be null: {by_id_map[99]}")

# Verify the prior unterminated notification did not mutate persisted state.
verify = by_id(run_messages([
    initialize(401), initialized,
    {"jsonrpc": "2.0", "id": 402, "method": "tools/call", "params": {"name": "prompt", "arguments": {"op": "get"}}},
    {"jsonrpc": "2.0", "id": 403, "method": "shutdown"}, exit_notification,
]))
if verify[402]["result"].get("structuredContent", {}).get("prompt") != "":
    raise SystemExit("unterminated mutation frame changed persisted prompt state")

# Separate processes must serialize workspace load-modify-save transactions.
def append_prompt(index):
    responses = by_id(run_messages([
        initialize(5000 + index * 10), initialized,
        {"jsonrpc": "2.0", "id": 5001 + index * 10, "method": "tools/call", "params": {"name": "prompt", "arguments": {"op": "append", "text": "x"}}},
        {"jsonrpc": "2.0", "id": 5002 + index * 10, "method": "shutdown"}, exit_notification,
    ]))
    result = responses[5001 + index * 10].get("result", {})
    if result.get("isError") is not False:
        raise RuntimeError(f"concurrent prompt append failed: {result}")

with ThreadPoolExecutor(max_workers=8) as executor:
    list(executor.map(append_prompt, range(16)))

locked_verify = by_id(run_messages([
    initialize(7001), initialized,
    {"jsonrpc": "2.0", "id": 7002, "method": "tools/call", "params": {"name": "prompt", "arguments": {"op": "get"}}},
    {"jsonrpc": "2.0", "id": 7003, "method": "shutdown"}, exit_notification,
]))
if locked_verify[7002]["result"].get("structuredContent", {}).get("prompt") != "x" * 16:
    raise SystemExit(f"cross-process workspace updates were lost: {locked_verify[7002]}")

print("Headless MCP smoke passed")
PY

printf 'Headless smoke binary: %s\n' "$BINARY"
printf 'Headless smoke state: %s\n' "$STATE_DIR"
printf 'Headless smoke fixture: %s\n' "$FIXTURE_DIR"
