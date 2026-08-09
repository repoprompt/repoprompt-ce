#!/usr/bin/env python3
"""Exercise the shipped Linux binary through the upstream headless MCP backend."""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
from typing import Any
import uuid


EXPECTED_TOOLS = {
    "agent_manage",
    "agent_run",
    "app_settings",
    "apply_edits",
    "bind_context",
    "context_builder",
    "file_actions",
    "file_search",
    "get_code_structure",
    "get_file_tree",
    "git",
    "history",
    "manage_selection",
    "manage_workspaces",
    "manage_worktree",
    "oracle_send",
    "oracle_utils",
    "prompt",
    "read_file",
    "workspace_context",
}

PRIMARY_MODEL = "codex_cli_gpt-5.6-sol-medium"
PRIMARY_CLI_MODEL = "gpt-5.6-sol"
SECONDARY_MODEL = "codex_cli_gpt-5.6-terra-high"
SECONDARY_CLI_MODEL = "gpt-5.6-terra"
FAKE_CODEX_NAME = "fake-codex"
FAKE_LAUNCHER_NAME = "fake-headless-launcher"
FAKE_CODEX_SCRIPT = """#!/bin/sh
set -eu

model=default
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--model" ]; then
        shift
        if [ "$#" -eq 0 ]; then
            printf '%s\n' 'missing model argument' >&2
            exit 2
        fi
        model=$1
    fi
    shift
done

prompt=$(cat)
capture=${XDG_CACHE_HOME:?missing fake Codex capture directory}/fake-codex-capture.log
if [ -n "$capture" ]; then
    token_hash=$(printf '%s' "${REPOPROMPT_MCP_LAUNCH_TOKEN:-missing}" | sha256sum | cut -d ' ' -f 1)
    prompt_hash=$(printf '%s' "$prompt" | sha256sum | cut -d ' ' -f 1)
    printf '%s|%s|%s\n' "$model" "$token_hash" "$prompt_hash" >> "$capture"
fi

case "$prompt" in
    *oracle-contract-all-failed*)
        printf '%s\n' 'synthetic all-lane failure' >&2
        exit 24
        ;;
    *oracle-contract-partial*)
        if [ "$model" = "gpt-5.6-terra" ]; then
            printf '%s\n' 'synthetic secondary failure' >&2
            exit 23
        fi
        ;;
    *oracle-contract-concurrent*) sleep 1 ;;
esac

case "$prompt" in
    *oracle-contract-continued*) turn=continued ;;
    *oracle-contract-partial*) turn=partial ;;
    *oracle-contract-context-default*) turn=context-default ;;
    *oracle-contract-context*) turn=context ;;
    *oracle-contract-dual*) turn=dual ;;
    *oracle-contract-reset*) turn=reset ;;
    *oracle-contract-concurrent*) turn=concurrent ;;
    *) turn=legacy ;;
esac

printf '{"item":{"type":"agent_message","text":"%s:%s"}}\n' "$model" "$turn"
"""

FAKE_LAUNCHER_SCRIPT = """#!/bin/sh
set -eu

server=$1
shift
profile=${REPOPROMPT_MCP_HEADLESS_PROFILE:-default}
if [ "$profile" != "default" ]; then
    printf '%s\n' 'test launcher requires the default isolated profile' >&2
    exit 2
fi
profile_root=${REPOPROMPT_MCP_HEADLESS_PROFILE_DIR:?missing headless profile directory}
primary_root=${REPOPROMPT_MCP_WORKING_DIRS:?missing primary working directory}
secondary_root=$primary_root/secondary-workspace
parent_executable=$(readlink -f "/proc/$PPID/exe")
parent_identity=$(stat -Lc '%d|%i' "$parent_executable")
principal_fingerprint=$(printf '%s|%s' "$parent_executable" "$parent_identity" | sha256sum | cut -d ' ' -f 1)
profile_digest=$(printf '%s' "$profile" | sha256sum | cut -c 1-12)
settings_dir=$profile_root/DomainRuntime/v1/default-$profile_digest/settings
mkdir -p "$settings_dir"
now=$(( $(date +%s) - 978307200 ))
expires=$(( now + 3600 ))
umask 077
printf '%s\n' "{\"headlessGrants\":[{\"allowedOperations\":[\"bind_context.bind\",\"context_builder.ai_cost\",\"context_builder.external_process\",\"oracle_send.ai_cost\",\"oracle_send.external_process\"],\"canonicalRoots\":[\"$primary_root\",\"$secondary_root\"],\"expiresAt\":$expires,\"id\":\"00000000-0000-0000-0000-000000000001\",\"issuedAt\":$now,\"principalKey\":\"$principal_fingerprint\",\"revision\":1,\"workspaceIDs\":[]}],\"profileIdentifier\":\"default\",\"revision\":1,\"updatedAt\":$now,\"version\":2}" > "$settings_dir/protected-mutations.json"

exec "$server" "$@"
"""


def command_for(mode: str, target: str, workspace: Path, profile: Path) -> list[str]:
    if mode == "binary":
        return [str(workspace / FAKE_LAUNCHER_NAME), target, "--backend", "headless"]
    if mode == "docker":
        return [
            "docker",
            "run",
            "--rm",
            "-i",
            "--network=none",
            "--mount",
            f"type=bind,src={workspace},dst=/workspace",
            "--mount",
            f"type=bind,src={profile},dst=/data",
            "--env",
            f"REPOPROMPT_CODEX_COMMAND=/workspace/{FAKE_CODEX_NAME}",
            "--env",
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR=/data",
            "--env",
            "REPOPROMPT_MCP_WORKING_DIRS=/workspace",
            "--env",
            "XDG_CACHE_HOME=/workspace",
            "--entrypoint",
            "/usr/bin/tini",
            target,
            "--",
            f"/workspace/{FAKE_LAUNCHER_NAME}",
            "/usr/local/bin/repoprompt-mcp",
            "--backend",
            "headless",
        ]
    raise ValueError(f"unknown mode: {mode}")


def restore_docker_mount_ownership(target: str, workspace: Path, profile: Path) -> None:
    """Return disposable bind mounts to the host runner after a non-root session."""
    owner = f"{os.getuid()}:{os.getgid()}"
    completed = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--network=none",
            "--user",
            "0:0",
            "--mount",
            f"type=bind,src={workspace},dst=/workspace",
            "--mount",
            f"type=bind,src={profile},dst=/data",
            "--entrypoint",
            "/bin/chown",
            target,
            "-R",
            owner,
            "/workspace",
            "/data",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"failed to restore Docker fixture ownership: {completed.stderr.strip()}")


def request(process: subprocess.Popen[str], identifier: int, method: str, params: dict[str, Any]) -> dict[str, Any]:
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], 30)
    if not ready:
        raise TimeoutError(f"timed out waiting for headless reply to {method}")
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"headless process closed before reply to {method}: {stderr}")
    reply = json.loads(line)
    if reply.get("id") != identifier:
        raise AssertionError(f"unexpected response id for {method}: {reply}")
    if "error" in reply:
        raise AssertionError(f"protocol error for {method}: {reply}")
    return reply


def concurrent_tool_calls(
    process: subprocess.Popen[str],
    calls: list[tuple[int, str, dict[str, Any]]],
) -> dict[int, dict[str, Any]]:
    assert process.stdin is not None
    assert process.stdout is not None
    for identifier, name, arguments in calls:
        process.stdin.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": identifier,
                    "method": "tools/call",
                    "params": {"name": name, "arguments": arguments},
                }
            )
            + "\n"
        )
    process.stdin.flush()

    replies: dict[int, dict[str, Any]] = {}
    deadline = 35
    while len(replies) < len(calls):
        ready, _, _ = select.select([process.stdout], [], [], deadline)
        if not ready:
            raise TimeoutError("timed out waiting for concurrent headless tool replies")
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise RuntimeError(f"headless process closed during concurrent calls: {stderr}")
        reply = json.loads(line)
        identifier = reply.get("id")
        if not isinstance(identifier, int) or "error" in reply:
            raise AssertionError(f"invalid concurrent protocol reply: {reply}")
        replies[identifier] = reply["result"]
    return replies


def call_tool(
    process: subprocess.Popen[str],
    identifier: int,
    name: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    return request(
        process,
        identifier,
        "tools/call",
        {"name": name, "arguments": arguments},
    )["result"]


def tool_object(result: dict[str, Any], *, operation: str) -> dict[str, Any]:
    if result.get("isError", False):
        raise AssertionError(f"{operation} returned a tool error: {result}")
    for item in result.get("content", []):
        if item.get("type") != "text" or not isinstance(item.get("text"), str):
            continue
        try:
            value = json.loads(item["text"])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise AssertionError(f"{operation} did not return one JSON object: {result}")


def set_secondary_model(
    process: subprocess.Popen[str],
    identifier: int,
    model: str | None,
    *,
    expected_value: str | None = None,
) -> None:
    result = call_tool(
        process,
        identifier,
        "app_settings",
        {"op": "set", "key": "models.secondary_oracle_model", "value": model},
    )
    payload = tool_object(result, operation="set secondary Oracle model")
    expected = (
        None
        if model is None or not model.strip()
        else (expected_value if expected_value is not None else model)
    )
    if payload.get("key") != "models.secondary_oracle_model" or payload.get("value") != expected:
        raise AssertionError(f"secondary Oracle setting did not round-trip: {payload}")


def set_planning_model(process: subprocess.Popen[str], identifier: int, model: str) -> None:
    result = call_tool(
        process,
        identifier,
        "app_settings",
        {"op": "set", "key": "models.planning_model", "value": model},
    )
    payload = tool_object(result, operation="set planning model")
    if payload.get("key") != "models.planning_model" or payload.get("value") != model:
        raise AssertionError(f"planning model setting did not round-trip: {payload}")


def assert_legacy_oracle_result(payload: dict[str, Any], *, expected_response: str) -> str:
    expected_keys = {"chat_id", "response", "backend"}
    if set(payload) != expected_keys:
        raise AssertionError(f"disabled dual Oracle changed the legacy result shape: {payload}")
    if payload["backend"] != "headless" or payload["response"] != expected_response:
        raise AssertionError(f"unexpected legacy Oracle response: {payload}")
    if not isinstance(payload["chat_id"], str) or not payload["chat_id"]:
        raise AssertionError(f"legacy Oracle response omitted chat_id: {payload}")
    return payload["chat_id"]


def assert_dual_oracle_result(
    payload: dict[str, Any],
    *,
    expected_status: str,
    expected_primary_response: str,
    expected_secondary_response: str | None,
    expected_secondary_model: str,
    expected_history_diverged: bool | None = None,
    expected_mode: str = "chat",
) -> tuple[str, str, str]:
    required_keys = {
        "chat_id",
        "context_id",
        "mode",
        "response",
        "status",
        "oracle_pair_id",
        "primary_chat_id",
        "secondary_chat_id",
        "oracle_history_diverged",
        "oracle_results",
    }
    missing = required_keys - set(payload)
    if missing:
        raise AssertionError(f"dual Oracle result omitted PR9 keys {sorted(missing)}: {payload}")
    if "backend" in payload or payload["status"] != expected_status:
        raise AssertionError(f"unexpected dual Oracle status: {payload}")
    if payload["mode"] != expected_mode or not isinstance(payload["oracle_history_diverged"], bool):
        raise AssertionError(f"dual Oracle metadata drifted: {payload}")
    if expected_history_diverged is not None and payload["oracle_history_diverged"] != expected_history_diverged:
        raise AssertionError(f"dual Oracle history divergence drifted: {payload}")
    if payload["chat_id"] != payload["primary_chat_id"] or payload["response"] != expected_primary_response:
        raise AssertionError(f"dual Oracle did not project the primary lane: {payload}")
    if payload["primary_chat_id"] == payload["secondary_chat_id"]:
        raise AssertionError(f"dual Oracle lanes shared a chat ID: {payload}")
    identities = (payload["oracle_pair_id"], payload["primary_chat_id"], payload["secondary_chat_id"])
    if not all(isinstance(identity, str) and identity for identity in identities) or len(set(identities)) != 3:
        raise AssertionError(f"dual Oracle identities were empty or aliased: {payload}")

    lanes = payload["oracle_results"]
    if not isinstance(lanes, dict) or set(lanes) != {"primary", "secondary"}:
        raise AssertionError(f"dual Oracle result did not contain exactly two lanes: {payload}")
    primary = lanes["primary"]
    secondary = lanes["secondary"]
    if primary.get("oracle_lane") != "primary" or secondary.get("oracle_lane") != "secondary":
        raise AssertionError(f"dual Oracle lane labels drifted: {payload}")
    if primary.get("chat_id") != payload["primary_chat_id"] or secondary.get("chat_id") != payload["secondary_chat_id"]:
        raise AssertionError(f"dual Oracle lane IDs disagreed with the pair envelope: {payload}")
    if primary.get("oracle_pair_id") != payload["oracle_pair_id"] or secondary.get("oracle_pair_id") != payload["oracle_pair_id"]:
        raise AssertionError(f"dual Oracle pair identity was not stable across lanes: {payload}")
    if primary.get("model_raw_id") != PRIMARY_MODEL or secondary.get("model_raw_id") != expected_secondary_model:
        raise AssertionError(f"dual Oracle did not preserve distinct lane models: {payload}")
    if primary.get("status") != "completed" or primary.get("response") != expected_primary_response:
        raise AssertionError(f"unexpected primary Oracle response: {payload}")
    if expected_secondary_response is None:
        if (
            secondary.get("status") != "failed"
            or secondary.get("error_code") != "execution_failed"
            or not secondary.get("error")
        ):
            raise AssertionError(f"secondary Oracle failure was not preserved: {payload}")
    elif secondary.get("status") != "completed" or secondary.get("response") != expected_secondary_response:
        raise AssertionError(f"unexpected secondary Oracle response: {payload}")

    return payload["oracle_pair_id"], payload["primary_chat_id"], payload["secondary_chat_id"]


def decode_pair_failure(result: dict[str, Any]) -> dict[str, Any]:
    marker = "[[RPCE_ORACLE_PAIR_FAILURE_V1:"
    serialized = json.dumps(result, sort_keys=True)
    start = serialized.find(marker)
    if start < 0:
        raise AssertionError(f"all-lane failure omitted the structured pair envelope: {result}")
    payload_start = start + len(marker)
    payload_end = serialized.find("]]", payload_start)
    if payload_end < 0:
        raise AssertionError(f"all-lane failure envelope was truncated: {result}")
    encoded = serialized[payload_start:payload_end]
    try:
        decoded = base64.b64decode(encoded, validate=True)
        payload = json.loads(decoded)
    except (ValueError, json.JSONDecodeError) as error:
        raise AssertionError(f"all-lane failure envelope was invalid: {error}") from error
    if not isinstance(payload, dict):
        raise AssertionError(f"all-lane failure payload was not an object: {payload}")
    return payload


def assert_failed_pair_payload(payload: dict[str, Any]) -> None:
    if payload.get("status") != "failed" or payload.get("chat_id") != payload.get("primary_chat_id"):
        raise AssertionError(f"all-lane failure lost its pair projection: {payload}")
    identities = [payload.get("oracle_pair_id"), payload.get("primary_chat_id"), payload.get("secondary_chat_id")]
    if not all(isinstance(value, str) and value for value in identities) or len(set(identities)) != 3:
        raise AssertionError(f"all-lane failure identities were empty or aliased: {payload}")
    lanes = payload.get("oracle_results")
    if not isinstance(lanes, dict) or set(lanes) != {"primary", "secondary"}:
        raise AssertionError(f"all-lane failure omitted either lane: {payload}")
    for lane_name, expected_model in (("primary", PRIMARY_MODEL), ("secondary", SECONDARY_MODEL)):
        lane = lanes[lane_name]
        if (
            lane.get("status") != "failed"
            or lane.get("error_code") != "execution_failed"
            or lane.get("oracle_lane") != lane_name
            or lane.get("model_raw_id") != expected_model
            or lane.get("oracle_pair_id") != payload["oracle_pair_id"]
        ):
            raise AssertionError(f"all-lane failure corrupted {lane_name} metadata: {payload}")


def write_workspace_document(
    directory: Path,
    *,
    workspace_id: str,
    context_id: str,
    name: str,
    repo_path: str,
) -> None:
    document = {
        "id": workspace_id,
        "schemaVersion": 1,
        "name": name,
        "repoPaths": [repo_path],
        "isSystemWorkspace": False,
        "isHiddenInMenus": False,
        "activeComposeTabID": context_id,
        "composeTabs": [
            {
                "id": context_id,
                "name": "Headless",
                "prompt": "",
                "selectedPaths": [],
            }
        ],
    }
    workspace_directory = directory / f"Workspace-{name.replace('/', '_').strip()}-{workspace_id}"
    workspace_directory.mkdir()
    (workspace_directory / "workspace.json").write_text(
        json.dumps(document, sort_keys=True),
        encoding="utf-8",
    )


def write_workspace_index(directory: Path, workspaces: list[tuple[str, str]]) -> None:
    index = [
        {
            "id": workspace_id,
            "name": name,
            "customStoragePath": None,
            "isSystemWorkspace": False,
            "isHiddenInMenus": False,
        }
        for workspace_id, name in workspaces
    ]
    (directory / "workspacesIndex.json").write_text(
        json.dumps(index, sort_keys=True),
        encoding="utf-8",
    )


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in {"binary", "docker"}:
        print(f"usage: {sys.argv[0]} binary <path> | docker <image>", file=sys.stderr)
        return 2
    mode, target = sys.argv[1:]

    with tempfile.TemporaryDirectory(prefix="rpce-linux-workspace-") as workspace_raw, tempfile.TemporaryDirectory(
        prefix="rpce-linux-profile-"
    ) as profile_raw:
        workspace = Path(workspace_raw).resolve()
        profile = Path(profile_raw).resolve()
        secondary_workspace = workspace / "secondary-workspace"
        secondary_workspace.mkdir()
        primary_workspace_id = str(uuid.uuid4()).upper()
        primary_context_id = str(uuid.uuid4()).upper()
        secondary_workspace_id = str(uuid.uuid4()).upper()
        secondary_context_id = str(uuid.uuid4()).upper()
        workspace_documents = profile / "Workspaces"
        workspace_documents.mkdir()
        primary_repo_path = "/workspace" if mode == "docker" else str(workspace)
        secondary_repo_path = (
            "/workspace/secondary-workspace" if mode == "docker" else str(secondary_workspace)
        )
        write_workspace_document(
            workspace_documents,
            workspace_id=primary_workspace_id,
            context_id=primary_context_id,
            name="Primary Headless Workspace",
            repo_path=primary_repo_path,
        )
        write_workspace_document(
            workspace_documents,
            workspace_id=secondary_workspace_id,
            context_id=secondary_context_id,
            name="Secondary Headless Workspace",
            repo_path=secondary_repo_path,
        )
        write_workspace_index(
            workspace_documents,
            [
                (primary_workspace_id, "Primary Headless Workspace"),
                (secondary_workspace_id, "Secondary Headless Workspace"),
            ],
        )
        fixture = workspace / "sample.swift"
        fixture.write_text("struct LinuxHeadlessFixture {}\n", encoding="utf-8")
        fake_codex = workspace / FAKE_CODEX_NAME
        fake_codex.write_text(FAKE_CODEX_SCRIPT, encoding="utf-8")
        fake_codex.chmod(0o755)
        fake_launcher = workspace / FAKE_LAUNCHER_NAME
        fake_launcher.write_text(FAKE_LAUNCHER_SCRIPT, encoding="utf-8")
        fake_launcher.chmod(0o755)
        fake_capture = workspace / "fake-codex-capture.log"
        fake_capture.touch()
        fake_capture.chmod(0o666)
        if mode == "docker":
            # The final image intentionally runs as uid/gid 65532. These are
            # disposable bind roots, so grant that principal access without
            # changing the image's production user contract.
            workspace.chmod(0o755)
            profile.chmod(0o777)
            workspace_documents.chmod(0o777)

        environment = os.environ.copy()
        environment["REPOPROMPT_MCP_HEADLESS_PROFILE"] = "default"
        environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = str(profile)
        environment["REPOPROMPT_MCP_WORKING_DIRS"] = str(workspace)
        environment["REPOPROMPT_CODEX_COMMAND"] = str(fake_codex)
        environment["XDG_CACHE_HOME"] = str(workspace)
        environment.pop("REPOPROMPT_MCP_PRIVATE_ENDPOINT", None)
        environment.pop("REPOPROMPT_MCP_LAUNCH_TOKEN", None)
        process = subprocess.Popen(
            command_for(mode, target, workspace, profile),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            bufsize=1,
        )
        try:
            request(
                process,
                1,
                "initialize",
                {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "linux-headless-contract", "version": "1"},
                },
            )
            listed = request(process, 2, "tools/list", {})
            tools = listed["result"]["tools"]
            names = {tool["name"] for tool in tools}
            if names != EXPECTED_TOOLS:
                raise AssertionError(
                    f"canonical tool surface drifted: missing={sorted(EXPECTED_TOOLS - names)} extra={sorted(names - EXPECTED_TOOLS)}"
                )

            bind_schema = next(tool["inputSchema"] for tool in tools if tool["name"] == "bind_context")
            if "window_id" in json.dumps(bind_schema, sort_keys=True):
                raise AssertionError("Linux headless bind_context exposed app window authority")

            fixture_path = "/workspace/sample.swift" if mode == "docker" else str(fixture)
            read_reply = call_tool(
                process,
                3,
                "read_file",
                {"path": fixture_path, "start_line": 1, "limit": 1},
            )
            if read_reply.get("isError", False) or "LinuxHeadlessFixture" not in json.dumps(read_reply):
                raise AssertionError(f"read_file did not use canonical headless workspace authority: {read_reply}")

            denied_path = "/workspace/denied.txt" if mode == "docker" else str(workspace / "denied.txt")
            denied = call_tool(
                process,
                4,
                "file_actions",
                {"action": "create", "path": denied_path, "content": "denied"},
            )
            if not denied.get("isError", False) or (workspace / "denied.txt").exists():
                raise AssertionError(f"protected mutation did not fail closed: {denied}")

            set_secondary_model(process, 5, None)
            set_secondary_model(process, 51, "   ")
            invalid_secondary = call_tool(
                process,
                52,
                "app_settings",
                {
                    "op": "set",
                    "key": "models.secondary_oracle_model",
                    "value": "not-a-real-oracle-model",
                },
            )
            if not invalid_secondary.get("isError", False):
                raise AssertionError(f"unknown Secondary Oracle model was accepted: {invalid_secondary}")
            set_planning_model(process, 53, PRIMARY_MODEL)
            legacy = tool_object(
                call_tool(
                    process,
                    6,
                    "oracle_send",
                    {
                        "message": "oracle-contract-legacy",
                        "new_chat": True,
                    },
                ),
                operation="legacy oracle_send",
            )
            legacy_chat_id = assert_legacy_oracle_result(
                legacy,
                expected_response=f"{PRIMARY_CLI_MODEL}:legacy",
            )

            set_secondary_model(process, 7, SECONDARY_MODEL)
            context_default = tool_object(
                call_tool(
                    process,
                    93,
                    "context_builder",
                    {
                        "instructions": "oracle-contract-context-default",
                    },
                ),
                operation="default context_builder",
            )
            assert_legacy_oracle_result(
                context_default,
                expected_response=f"{PRIMARY_CLI_MODEL}:context-default",
            )

            invalid_response_type = call_tool(
                process,
                94,
                "context_builder",
                {
                    "instructions": "oracle-contract-invalid-response-type",
                    "response_type": "invalid",
                },
            )
            if not invalid_response_type.get("isError", False):
                raise AssertionError(f"invalid context_builder response_type was accepted: {invalid_response_type}")

            context = tool_object(
                call_tool(
                    process,
                    92,
                    "context_builder",
                    {
                        "instructions": "oracle-contract-context",
                        "response_type": "plan",
                    },
                ),
                operation="dual context_builder",
            )
            if context.get("status") != "completed" or not isinstance(context.get("plan"), dict):
                raise AssertionError(f"context_builder did not nest the pair under plan: {context}")
            _, context_primary_id, _ = assert_dual_oracle_result(
                context["plan"],
                expected_status="completed",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:context",
                expected_secondary_response=f"{SECONDARY_CLI_MODEL}:context",
                expected_secondary_model=SECONDARY_MODEL,
                expected_history_diverged=False,
                expected_mode="plan",
            )
            if any(key in context for key in ("chat_id", "response", "backend")):
                raise AssertionError(f"context_builder duplicated the nested Oracle projection: {context}")
            if context_primary_id not in context.get("follow_up_hint", ""):
                raise AssertionError(f"context_builder follow-up did not use the primary lane: {context}")

            dual = tool_object(
                call_tool(
                    process,
                    8,
                    "oracle_send",
                    {
                        "chat_id": legacy_chat_id,
                        "message": "oracle-contract-dual",
                        "model": PRIMARY_MODEL,
                    },
                ),
                operation="dual oracle_send",
            )
            pair_id, primary_chat_id, secondary_chat_id = assert_dual_oracle_result(
                dual,
                expected_status="completed",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:dual",
                expected_secondary_response=f"{SECONDARY_CLI_MODEL}:dual",
                expected_secondary_model=SECONDARY_MODEL,
                expected_history_diverged=True,
            )
            if primary_chat_id != legacy_chat_id:
                raise AssertionError(
                    f"enabling Secondary Oracle replaced the existing primary history: {dual}"
                )

            continued = tool_object(
                call_tool(
                    process,
                    9,
                    "oracle_send",
                    {
                        # Either pair member must resolve the same paired route.
                        "chat_id": secondary_chat_id,
                        "message": "oracle-contract-continued",
                        "model": PRIMARY_MODEL,
                    },
                ),
                operation="continued dual oracle_send",
            )
            continued_ids = assert_dual_oracle_result(
                continued,
                expected_status="completed",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:continued",
                expected_secondary_response=f"{SECONDARY_CLI_MODEL}:continued",
                expected_secondary_model=SECONDARY_MODEL,
            )
            if continued_ids != (pair_id, primary_chat_id, secondary_chat_id):
                raise AssertionError(
                    f"dual Oracle continuation changed pair identity: before={(pair_id, primary_chat_id, secondary_chat_id)} after={continued_ids}"
                )

            implicit_continuation = tool_object(
                call_tool(
                    process,
                    99,
                    "oracle_send",
                    {
                        "message": "oracle-contract-continued-no-id",
                        "model": PRIMARY_MODEL,
                    },
                ),
                operation="implicit continued dual oracle_send",
            )
            implicit_ids = assert_dual_oracle_result(
                implicit_continuation,
                expected_status="completed",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:continued",
                expected_secondary_response=f"{SECONDARY_CLI_MODEL}:continued",
                expected_secondary_model=SECONDARY_MODEL,
            )
            if implicit_ids != (pair_id, primary_chat_id, secondary_chat_id):
                raise AssertionError(
                    f"chat-id-free continuation did not resume the latest scoped pair: {implicit_ids}"
                )

            tool_object(
                call_tool(
                    process,
                    95,
                    "bind_context",
                    {"op": "bind", "context_id": secondary_context_id},
                ),
                operation="bind secondary context",
            )
            cross_context = call_tool(
                process,
                96,
                "oracle_send",
                {
                    "chat_id": primary_chat_id,
                    "message": "oracle-contract-cross-context",
                },
            )
            if not cross_context.get("isError", False):
                raise AssertionError(f"Oracle history crossed a bound context: {cross_context}")
            secondary_sessions = tool_object(
                call_tool(process, 97, "oracle_utils", {"op": "sessions"}),
                operation="secondary-context Oracle sessions",
            )
            if any(
                session.get("oracle_pair_id") == pair_id
                for session in secondary_sessions.get("sessions", [])
            ):
                raise AssertionError(f"Oracle sessions leaked across contexts: {secondary_sessions}")
            tool_object(
                call_tool(
                    process,
                    98,
                    "bind_context",
                    {"op": "bind", "context_id": primary_context_id},
                ),
                operation="rebind primary context",
            )

            sessions = tool_object(
                call_tool(process, 90, "oracle_utils", {"op": "sessions"}),
                operation="paired oracle_utils sessions",
            )
            pair_sessions = [
                session
                for session in sessions.get("sessions", [])
                if session.get("oracle_pair_id") == pair_id
            ]
            if {
                (session.get("chat_id"), session.get("oracle_lane"))
                for session in pair_sessions
            } != {(primary_chat_id, "primary"), (secondary_chat_id, "secondary")}:
                raise AssertionError(f"oracle_utils did not expose both pair members: {sessions}")

            concurrent = concurrent_tool_calls(
                process,
                [
                    (
                        100,
                        "oracle_send",
                        {"message": "oracle-contract-concurrent", "new_chat": True},
                    ),
                    (
                        101,
                        "oracle_send",
                        {"message": "oracle-contract-concurrent", "new_chat": True},
                    ),
                ],
            )
            successful_concurrent = [result for result in concurrent.values() if not result.get("isError", False)]
            rejected_concurrent = [result for result in concurrent.values() if result.get("isError", False)]
            if len(successful_concurrent) != 1 or len(rejected_concurrent) != 1:
                raise AssertionError(f"overlapping sends did not serialize on the Oracle route: {concurrent}")
            concurrent_payload = tool_object(successful_concurrent[0], operation="concurrent dual oracle_send")
            assert_dual_oracle_result(
                concurrent_payload,
                expected_status="completed",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:concurrent",
                expected_secondary_response=f"{SECONDARY_CLI_MODEL}:concurrent",
                expected_secondary_model=SECONDARY_MODEL,
                expected_history_diverged=False,
            )
            concurrent_prompt_hash = hashlib.sha256(b"oracle-contract-concurrent").hexdigest()
            captured_concurrent = [
                line.split("|")
                for line in fake_capture.read_text(encoding="utf-8").splitlines()
                if line.endswith(f"|{concurrent_prompt_hash}")
            ]
            if len(captured_concurrent) != 2:
                raise AssertionError(f"concurrent route launched an unexpected number of lanes: {captured_concurrent}")
            if {entry[0] for entry in captured_concurrent} != {PRIMARY_CLI_MODEL, SECONDARY_CLI_MODEL}:
                raise AssertionError(f"concurrent route did not launch both model lanes: {captured_concurrent}")
            if len({entry[1] for entry in captured_concurrent}) != 2:
                raise AssertionError(f"dual Oracle lanes reused one private launch carrier: {captured_concurrent}")
            missing_token_hash = hashlib.sha256(b"missing").hexdigest()
            if missing_token_hash in {entry[1] for entry in captured_concurrent}:
                raise AssertionError(f"dual Oracle launched a lane without a private carrier: {captured_concurrent}")

            partial = tool_object(
                call_tool(
                    process,
                    11,
                    "oracle_send",
                    {
                        "message": "oracle-contract-partial",
                        "model": PRIMARY_MODEL,
                        "new_chat": True,
                    },
                ),
                operation="partial-failure dual oracle_send",
            )
            assert_dual_oracle_result(
                partial,
                expected_status="partial_failure",
                expected_primary_response=f"{PRIMARY_CLI_MODEL}:partial",
                expected_secondary_response=None,
                expected_secondary_model=SECONDARY_MODEL,
            )

            failed = call_tool(
                process,
                91,
                "oracle_send",
                {
                    "message": "oracle-contract-all-failed",
                    "model": PRIMARY_MODEL,
                    "new_chat": True,
                },
            )
            if not failed.get("isError", False):
                raise AssertionError(f"all-lane failure returned success: {failed}")
            assert_failed_pair_payload(decode_pair_failure(failed))

            set_secondary_model(process, 12, None)
            disabled_pair_continuation = call_tool(
                process,
                13,
                "oracle_send",
                {
                    "chat_id": primary_chat_id,
                    "message": "oracle-contract-disabled-pair",
                    "model": PRIMARY_MODEL,
                },
            )
            if not disabled_pair_continuation.get("isError", False):
                raise AssertionError(
                    f"disabled Secondary Oracle continued an existing pair: {disabled_pair_continuation}"
                )

            reset = tool_object(
                call_tool(
                    process,
                    14,
                    "oracle_send",
                    {
                        "message": "oracle-contract-reset",
                        "model": PRIMARY_MODEL,
                        "new_chat": True,
                    },
                ),
                operation="reset legacy oracle_send",
            )
            assert_legacy_oracle_result(reset, expected_response=f"{PRIMARY_CLI_MODEL}:reset")

            assert process.stdin is not None
            process.stdin.close()
            process.wait(timeout=15)
            stderr = process.stderr.read() if process.stderr is not None else ""
            if process.returncode != 0:
                raise AssertionError(f"EOF drain exited {process.returncode}: {stderr}")
            if stderr:
                raise AssertionError(f"successful headless session wrote stderr: {stderr}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if mode == "docker":
                restore_docker_mount_ownership(target, workspace, profile)

    print(f"linux headless MCP contract passed ({mode})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
