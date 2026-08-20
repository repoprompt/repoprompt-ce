#!/usr/bin/env python3
"""Validate the PR-2 portable package DAG and root-consumer contract."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PORTABLE_ROOT = ROOT / "Packages" / "RepoPromptPortableRuntime"


def dump_package(path: Path) -> dict[str, object]:
    return json.loads(
        subprocess.check_output(
            ["swift", "package", "--disable-sandbox", "--package-path", str(path), "dump-package"],
            cwd=ROOT,
            text=True,
        )
    )


def dependency_names(target: dict[str, object]) -> set[str]:
    names: set[str] = set()
    for dependency in target.get("dependencies", []):
        if "byName" in dependency:
            names.add(dependency["byName"][0])
        elif "product" in dependency:
            names.add(dependency["product"][0])
    return names


def product_dependencies(target: dict[str, object]) -> set[tuple[str, str]]:
    return {
        (dependency["product"][0], dependency["product"][1])
        for dependency in target.get("dependencies", [])
        if "product" in dependency
    }


def main() -> int:
    portable = dump_package(PORTABLE_ROOT)
    root = dump_package(ROOT)
    portable_targets = {target["name"]: target for target in portable["targets"]}
    root_targets = {target["name"]: target for target in root["targets"]}
    errors: list[str] = []

    exact_edges = {
        "RepoPromptRuntimeModel": set(),
        "RepoPromptAuthorityAPI": {"RepoPromptRuntimeModel"},
        "RepoPromptShared": {"Crypto"},
        "RepoPromptAgentRuntimeCore": {"RepoPromptRuntimeModel"},
        "RepoPromptWorkspaceRuntimeCore": {"RepoPromptRuntimeModel", "RepoPromptShared"},
        "RepoPromptDomainRuntime": {
            "RepoPromptShared", "RepoPromptRuntimeModel", "RepoPromptC",
            "RepoPromptCodeMapCore", "Crypto", "Logging", "MCP",
        },
        "RepoPromptHeadlessRuntime": {
            "RepoPromptRuntimeModel", "RepoPromptAuthorityAPI", "RepoPromptShared",
            "RepoPromptAgentRuntimeCore", "RepoPromptWorkspaceRuntimeCore",
            "RepoPromptDomainRuntime",
        },
        "RepoPromptLinuxSupport": set(),
        "RepoPromptRegexCore": {"CSwiftPCRE2"},
        "RepoPromptC": set(),
        "CSwiftPCRE2": set(),
        "TreeSitterScannerSupport": set(),
    }
    moved_targets = set(exact_edges) | {"RepoPromptCodeMapCore"}

    missing = sorted(moved_targets - portable_targets.keys())
    if missing:
        errors.append(f"Portable manifest missing targets: {', '.join(missing)}")
    unexpected_root = sorted(moved_targets & root_targets.keys())
    if unexpected_root:
        errors.append(f"Root manifest still owns portable targets: {', '.join(unexpected_root)}")

    for target_name, expected in exact_edges.items():
        actual = dependency_names(portable_targets.get(target_name, {}))
        if actual != expected:
            errors.append(
                f"{target_name} dependency drift: expected {sorted(expected)}, got {sorted(actual)}"
            )

    root_manifest = (ROOT / "Package.swift").read_text()
    portable_manifest = (PORTABLE_ROOT / "Package.swift").read_text()
    if '.package(path: "Packages/RepoPromptPortableRuntime")' not in root_manifest:
        errors.append("Root manifest missing local RepoPromptPortableRuntime dependency")
    for forbidden in ("makeServerPackage", "REPOPROMPT_SERVER_ONLY"):
        if forbidden in root_manifest or forbidden in portable_manifest:
            errors.append(f"Forbidden temporary Server graph marker present: {forbidden}")

    app = root_targets.get("RepoPromptApp", {})
    required_products = {
        "RepoPromptRuntimeModel", "RepoPromptAgentRuntimeCore", "RepoPromptShared",
        "RepoPromptDomainRuntime", "RepoPromptCodeMapCore", "RepoPromptRegexCore",
        "RepoPromptC",
    }
    actual_products = {
        name for name, package in product_dependencies(app)
        if package == "RepoPromptPortableRuntime"
    }
    missing_products = sorted(required_products - actual_products)
    if missing_products:
        errors.append(
            "RepoPromptApp missing portable product dependencies: "
            + ", ".join(missing_products)
        )

    executable = root_targets.get("RepoPrompt", {})
    if dependency_names(executable) != {"RepoPromptApp"}:
        errors.append("RepoPrompt executable must depend only on RepoPromptApp")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("OK: portable package dependency graph passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
