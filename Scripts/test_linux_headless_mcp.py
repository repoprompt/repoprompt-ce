#!/usr/bin/env python3
# Smoke-test the Linux headless MCP binary or final container.

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
from typing import Any


REQUIRED_CORE_TOOLS = {
    "bind_context",
    "manage_workspaces",
    "manage_selection",
    "file_actions",
    "get_code_structure",
    "get_file_tree",
    "read_file",
    "file_search",
    "workspace_context",
    "prompt",
    "apply_edits",
    "git",
    "manage_worktree",
}


def command(mode: str, target: str, workspace: Path, profile: Path) -> list[str]:
    if mode == "binary":
        return [target, "--backend", "headless"]
    if mode == "docker":
        return [
            "docker",
            "run",
            "--rm",
            "-i",
            "--network=none",
            "--user",
            f"{os.getuid()}:{os.getgid()}",
            "--mount",
            f"type=bind,src={workspace},dst=/workspace",
            "--mount",
            f"type=bind,src={profile},dst=/data",
            target,
            "--backend",
            "headless",
        ]
    raise ValueError(f"unsupported mode: {mode}")


def request_with_notifications(
    process: subprocess.Popen[str],
    identifier: int,
    method: str,
    params: dict[str, Any],
    timeout: float = 30,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": identifier,
                "method": method,
                "params": params,
            }
        )
        + "\n"
    )
    process.stdin.flush()
    return receive_response(process, identifier, method, timeout)


def receive_response(
    process: subprocess.Popen[str],
    identifier: int,
    method: str,
    timeout: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    notifications: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], deadline - time.monotonic())
        if not ready:
            break
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise RuntimeError(f"headless process closed during {method}: {stderr}")
        reply = json.loads(line)
        if reply.get("id") != identifier:
            notifications.append(reply)
            continue
        if "error" in reply:
            raise AssertionError(f"invalid {method} response: {reply}")
        return reply["result"], notifications
    raise TimeoutError(f"timed out waiting for {method}; notifications={notifications}")


def request(
    process: subprocess.Popen[str],
    identifier: int,
    method: str,
    params: dict[str, Any],
) -> dict[str, Any]:
    result, _ = request_with_notifications(process, identifier, method, params)
    return result


def install_progress_smoke_fixture(workspace: Path) -> Path:
    provider = workspace / "fake-codex-progress"
    provider.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
if grep -q 'CANCEL_PROCESS_TREE' <<<"$payload"; then
    sleep 30 &
    echo $! > "$(dirname "$0")/cancel-descendant.pid"
    wait
    exit 0
fi
printf '%s\\n' '{"type":"thread.started","thread_id":"smoke"}'
printf '%s\\n' '{"type":"turn.started"}'
printf '%s\\n' '{"type":"item.started","item":{"type":"command_execution","command":"redacted"}}'
head -c 9000000 /dev/zero | tr '\\0' x
printf '\\n'
printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"redacted"}}'
printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"PROGRESS_FINAL_OK"}}'
printf '%s\\n' '{"type":"turn.completed"}'
""",
        encoding="utf-8",
    )
    provider.chmod(0o755)
    return provider


def tool_value(result: dict[str, Any]) -> Any:
    if result.get("isError", False):
        raise AssertionError(f"tool returned an error: {result}")
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                return json.loads(item["text"])
            except (KeyError, TypeError, json.JSONDecodeError):
                continue
    raise AssertionError(f"tool omitted a JSON result: {result}")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} binary|docker TARGET")
    mode, target = sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix="rp-linux-workspace-") as workspace_raw, tempfile.TemporaryDirectory(
        prefix="rp-linux-profile-"
    ) as profile_raw:
        workspace = Path(workspace_raw)
        profile = Path(profile_raw)
        (workspace / "Sources").mkdir()
        fixture = workspace / "Sources" / "Sample.swift"
        fixture.write_text(
            "struct LinuxHeadlessFixture { let value: Int }\n",
            encoding="utf-8",
        )
        read_path = (
            Path("/workspace") / fixture.relative_to(workspace)
            if mode == "docker"
            else fixture
        )
        environment = os.environ.copy()
        environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = str(profile)
        environment["REPOPROMPT_MCP_WORKING_DIRS"] = str(workspace)
        if mode == "binary":
            environment["REPOPROMPT_CODEX_COMMAND"] = str(
                install_progress_smoke_fixture(workspace)
            )
            environment["REPOPROMPT_MCP_HEADLESS_GRANT_OPERATIONS"] = (
                "agent_run.ai_cost,agent_run.external_process,"
                "context_builder.ai_cost,context_builder.external_process"
            )
            version_environment = environment.copy()
            version_environment["REPOPROMPT_MCP_CHILD_ENDPOINT"] = "/tmp/nonexistent-rpce-child.sock"
            version_environment["REPOPROMPT_MCP_CHILD_LAUNCH_TOKEN"] = "not-a-token"
            version = subprocess.run(
                [target, "--version"],
                env=version_environment,
                text=True,
                capture_output=True,
                check=True,
                timeout=10,
            )
            if not version.stdout.startswith("repoprompt-mcp "):
                raise AssertionError(f"private carrier hijacked --version: {version}")
        process = subprocess.Popen(
            command(mode, target, workspace, profile),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        try:
            initialized = request(
                process,
                1,
                "initialize",
                {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {
                        "name": "linux-headless-smoke",
                        "version": "1",
                    },
                },
            )
            if initialized.get("serverInfo", {}).get("name") != "RepoPrompt CE":
                raise AssertionError(f"unexpected server identity: {initialized}")

            listed = request(process, 2, "tools/list", {})
            names = {tool["name"] for tool in listed["tools"]}
            missing = REQUIRED_CORE_TOOLS - names
            if missing:
                raise AssertionError(f"missing core tools: {sorted(missing)}")
            file_actions = next(tool for tool in listed["tools"] if tool["name"] == "file_actions")
            if "Linux limitation" not in file_actions.get("description", ""):
                raise AssertionError("file_actions does not advertise the Linux delete limitation")

            tree = request(
                process,
                3,
                "tools/call",
                {
                    "name": "get_file_tree",
                    "arguments": {"type": "files"},
                },
            )
            tree_payload = tool_value(tree)
            if "Sample.swift" not in json.dumps(tree_payload):
                raise AssertionError(f"fixture missing from file tree: {tree_payload}")

            read_result = request(
                process,
                4,
                "tools/call",
                {
                    "name": "read_file",
                    "arguments": {
                        "path": str(read_path),
                        "start_line": 1,
                        "limit": 5,
                    },
                },
            )
            if "LinuxHeadlessFixture" not in json.dumps(tool_value(read_result)):
                raise AssertionError(f"read_file omitted fixture: {read_result}")

            search_result = request(
                process,
                5,
                "tools/call",
                {
                    "name": "file_search",
                    "arguments": {
                        "pattern": "LinuxHeadlessFixture",
                        "path": str(fixture.relative_to(workspace)),
                        "regex": False,
                    },
                },
            )
            if "LinuxHeadlessFixture" not in json.dumps(tool_value(search_result)):
                raise AssertionError(f"file_search omitted fixture: {search_result}")

            deletion_target = workspace / "Sources" / "DeleteMe.swift"
            deletion_target.write_text("struct DeleteMe {}\n", encoding="utf-8")
            delete_result = request(
                process,
                6,
                "tools/call",
                {
                    "name": "file_actions",
                    "arguments": {
                        "action": "delete",
                        "path": (
                            f"/workspace/{deletion_target.relative_to(workspace)}"
                            if mode == "docker"
                            else str(deletion_target)
                        ),
                    },
                },
            )
            if not delete_result.get("isError", False):
                raise AssertionError(f"file_actions delete unexpectedly succeeded: {delete_result}")
            if not deletion_target.exists():
                raise AssertionError("file_actions delete removed the smoke-test target")

            if mode == "binary":
                for request_id, key, value in [
                    (7, "context_builder.context_token_budget", 100_000),
                    (8, "context_builder.analysis_token_budget", 150_000),
                ]:
                    setting_result = request(
                        process,
                        request_id,
                        "tools/call",
                        {
                            "name": "app_settings",
                            "arguments": {"op": "set", "key": key, "value": value},
                        },
                    )
                    if tool_value(setting_result).get("value") != value:
                        raise AssertionError(f"budget setting did not persist: {setting_result}")

                context_result, notifications = request_with_notifications(
                    process,
                    9,
                    "tools/call",
                    {
                        "name": "context_builder",
                        "arguments": {
                            "instructions": "Reply with the fake provider result.",
                            "response_type": "review",
                        },
                        "_meta": {"progressToken": "linux-progress-smoke"},
                    },
                    timeout=45,
                )
                context_payload = tool_value(context_result)
                if context_payload.get("response") != "PROGRESS_FINAL_OK":
                    raise AssertionError(f"large provider stream lost final response: {context_payload}")
                if (
                    context_payload.get("context_token_budget") != 100_000
                    or context_payload.get("analysis_token_budget") != 150_000
                ):
                    raise AssertionError(f"context builder ignored configured budgets: {context_payload}")
                progress_messages = [
                    item.get("params", {}).get("message", "")
                    for item in notifications
                    if item.get("method") == "notifications/progress"
                ]
                required_progress = [
                    "Context Builder started",
                    "Provider session started",
                    "Workspace inspection started",
                    "Context Builder completed",
                ]
                missing_progress = [
                    expected
                    for expected in required_progress
                    if not any(expected in message for message in progress_messages)
                ]
                if missing_progress:
                    raise AssertionError(
                        f"missing progress milestones {missing_progress}: {progress_messages}"
                    )

                started_agent = tool_value(request(
                    process,
                    10,
                    "tools/call",
                    {
                        "name": "agent_run",
                        "arguments": {
                            "op": "start",
                            "message": "CANCEL_PROCESS_TREE",
                            "detach": True,
                        },
                    },
                ))
                session_id = started_agent.get("session_id")
                if not session_id:
                    raise AssertionError(f"agent_run omitted session_id: {started_agent}")
                descendant_pid_file = workspace / "cancel-descendant.pid"
                deadline = time.monotonic() + 10
                while not descendant_pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not descendant_pid_file.exists():
                    raise AssertionError("cancellation provider did not launch descendant")
                descendant_pid = int(descendant_pid_file.read_text().strip())
                tool_value(request(
                    process,
                    11,
                    "tools/call",
                    {
                        "name": "agent_run",
                        "arguments": {"op": "cancel", "session_id": session_id},
                    },
                ))
                deadline = time.monotonic() + 5
                while Path(f"/proc/{descendant_pid}").exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if Path(f"/proc/{descendant_pid}").exists():
                    raise AssertionError(f"provider descendant {descendant_pid} survived cancellation")
                post_cancel_result = request(
                    process,
                    12,
                    "tools/call",
                    {"name": "git", "arguments": {"op": "status"}},
                )
                if tool_value(post_cancel_result).get("op") != "status":
                    raise AssertionError(f"server did not settle after cancellation: {post_cancel_result}")

            process.stdin.close()
            process.wait(timeout=15)
            if process.returncode != 0:
                stderr = process.stderr.read() if process.stderr is not None else ""
                raise AssertionError(f"headless process exited {process.returncode}: {stderr}")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
