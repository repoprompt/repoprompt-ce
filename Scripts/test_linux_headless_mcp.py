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
            "--mount",
            f"type=bind,src={workspace},dst=/workspace",
            "--mount",
            f"type=bind,src={profile},dst=/data",
            target,
            "--backend",
            "headless",
        ]
    raise ValueError(f"unsupported mode: {mode}")


def request(
    process: subprocess.Popen[str],
    identifier: int,
    method: str,
    params: dict[str, Any],
) -> dict[str, Any]:
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
    ready, _, _ = select.select([process.stdout], [], [], 30)
    if not ready:
        raise TimeoutError(f"timed out waiting for {method}")
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"headless process closed during {method}: {stderr}")
    reply = json.loads(line)
    if reply.get("id") != identifier or "error" in reply:
        raise AssertionError(f"invalid {method} response: {reply}")
    return reply["result"]


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
        if mode == "docker":
            for directory in (workspace, profile, workspace / "Sources"):
                directory.chmod(0o777)
        environment = os.environ.copy()
        environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = str(profile)
        environment["REPOPROMPT_MCP_WORKING_DIRS"] = str(workspace)
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
                        "path": str(fixture),
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
