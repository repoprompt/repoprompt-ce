#!/usr/bin/env python3
"""Validate Phase 0 frozen baselines, characterization coverage, and package separation."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PHASE0 = ROOT / "Tests/SharedRuntimeConvergenceFixtures/Phase0"
TOOLS = [
    "bind_context",
    "manage_workspaces",
    "manage_selection",
    "workspace_context",
    "get_file_tree",
    "get_code_structure",
    "read_file",
    "file_search",
    "prompt",
]
APP_TOOL_ORDER = [
    "bind_context",
    "manage_workspaces",
    "manage_selection",
    "get_code_structure",
    "get_file_tree",
    "read_file",
    "file_search",
    "workspace_context",
    "prompt",
]
BASELINES = {
    "packaging": "2b350916d52809dd036331a746d888132019ce75",
    "app_mcp": "042a500b03b39d04237ec5544811696cf6b2f2f9",
    "headless": "487cd71d892dbc3104689cc42fdb39f6c038e8fb",
}
ALLOWED_DIFFERENCES = {
    "initialize and product/profile metadata",
    "profile and state-root paths",
    "unsupported capability omissions",
    "standalone initialization and configuration instructions",
}


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=ROOT, text=True, stderr=subprocess.STDOUT
    ).strip()


def assert_tool_records(records, label: str) -> None:
    names = [record["tool"] for record in records]
    assert names == TOOLS, f"{label} must cover the exact ordered nine-tool overlap: {names}"


def validate_characterization(path: Path, runtime: str) -> None:
    snapshot = load_json(path)
    assert snapshot["format_version"] == 1
    assert snapshot["runtime"] == runtime
    expected_order = APP_TOOL_ORDER if runtime == "app-v1" else TOOLS
    assert snapshot["tool_order"] == expected_order
    descriptor_names = [descriptor["name"] for descriptor in snapshot["descriptors"]]
    assert descriptor_names == expected_order, f"{runtime} descriptor order drifted: {descriptor_names}"
    if runtime == "app-v1":
        assert [record["tool"] for record in snapshot["normalized_arguments"]] == TOOLS
        assert [record["tool"] for record in snapshot["responses"]] == APP_TOOL_ORDER
    else:
        assert_tool_records(snapshot["argument_coercion"], "headless argument coercion")
        initialize = snapshot["initialize"]
        assert initialize["headless"]["stateDirectory"] == "$STATE"
        assert initialize["headless"]["safeToolsEnabled"] is True
        assert_tool_records(snapshot["responses"], f"{runtime} responses")


def main() -> None:
    manifest = load_json(PHASE0 / "manifest.json")
    assert manifest["branch"] == "core_split"
    assert manifest["freeze_head"] == BASELINES["headless"]
    assert manifest["baselines"] == BASELINES
    assert manifest["overlapping_tools"] == TOOLS
    assert set(manifest["allowed_product_differences"]) == ALLOWED_DIFFERENCES
    assert manifest["phase_1_or_later_blockers"], "Phase 1 blockers must remain explicit"

    ledger = load_json(PHASE0 / "differential-ledger.json")
    assert set(ledger["allowed_product_differences"]) == ALLOWED_DIFFERENCES
    assert [entry["name"] for entry in ledger["tools"]] == TOOLS
    for entry in ledger["tools"]:
        assert entry["descriptor"] == "phase_1_blocker"
        assert entry["arguments"] == "phase_1_blocker"
        assert entry["structured_text_response"] == "phase_1_blocker"
        assert entry["allowed"] == []

    for commit in BASELINES.values():
        assert git("cat-file", "-t", commit) == "commit"
    assert git("rev-parse", f"{BASELINES['app_mcp']}^") == BASELINES["packaging"]
    assert git("rev-parse", f"{BASELINES['headless']}^") == BASELINES["app_mcp"]
    subprocess.check_call(
        ["git", "merge-base", "--is-ancestor", BASELINES["headless"], "HEAD"], cwd=ROOT
    )

    validate_characterization(PHASE0 / "App/app-characterization.json", "app-v1")
    validate_characterization(PHASE0 / "Headless/headless-characterization.json", "headless-v1")

    app_workspace = PHASE0 / (
        "App/WorkspaceV1/Workspace-Phase 0 App V1-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/workspace.json"
    )
    headless_workspace = PHASE0 / "Headless/ProfileV1/Workspaces/22222222-2222-2222-2222-222222222222.json"
    assert app_workspace.is_file()
    assert headless_workspace.is_file()
    assert load_json(app_workspace)["schemaVersion"] == 1
    assert load_json(headless_workspace)["schema_version"] == 1

    package_app = (ROOT / "Scripts/package_app.sh").read_text(encoding="utf-8")
    package_headless = (ROOT / "Scripts/package_headless.sh").read_text(encoding="utf-8")
    smoke_headless = (ROOT / "Scripts/smoke_headless_mcp.sh").read_text(encoding="utf-8")
    assert "repoprompt-mcp" in package_app
    assert "repoprompt-headless" not in package_app
    assert "rpce-headless" not in package_app
    assert "repoprompt-headless" in package_headless
    assert "repoprompt-mcp" not in package_headless
    assert "RepoPrompt.app" not in package_headless
    assert " serve" in smoke_headless or "serve\n" in smoke_headless
    assert "without launching RepoPrompt.app" in smoke_headless
    assert "package_app.sh" not in smoke_headless
    assert "open -a" not in smoke_headless

    print("shared runtime Phase 0 characterization: ok")


if __name__ == "__main__":
    main()
