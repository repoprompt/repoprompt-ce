#!/usr/bin/env python3
"""Phase 1 dependency-boundary and frozen-fixture characterization checks."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PHASE0_ARTIFACT_BASELINE = "48a335e"
PHASE0_PREFIX = "Tests/SharedRuntimeConvergenceFixtures/Phase0/"
FROZEN_FILES = [
    "docs/characterization/shared-runtime-phase0-2026-06-05.md",
    "Scripts/test_shared_runtime_phase0_characterization.py",
]


def fail(message: str) -> None:
    raise AssertionError(message)


def git_bytes(revision: str, path: str) -> bytes:
    return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT)


def by_name_dependencies(target: dict[str, object]) -> set[str]:
    names: set[str] = set()
    for dependency in target.get("dependencies", []):
        if "byName" in dependency:
            names.add(dependency["byName"][0])
    return names


def swift_imports(root: Path) -> dict[Path, list[str]]:
    result: dict[Path, list[str]] = {}
    pattern = re.compile(
        r"^\s*(?:(?:@[_A-Za-z0-9]+(?:\([^)]*\))?)\s+)*"
        r"import(?:\s+(?:typealias|struct|class|enum|protocol|let|var|func))?"
        r"\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )
    for source in sorted(root.rglob("*.swift")):
        result[source] = pattern.findall(source.read_text())
    return result


def assert_frozen_phase0_artifacts() -> None:
    fixture_paths = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", PHASE0_ARTIFACT_BASELINE, PHASE0_PREFIX],
        cwd=ROOT,
        text=True,
    ).splitlines()
    if not fixture_paths:
        fail(f"No Phase 0 fixtures found at {PHASE0_ARTIFACT_BASELINE}")

    current_fixture_paths = sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / PHASE0_PREFIX).rglob("*")
        if path.is_file()
    )
    if current_fixture_paths != fixture_paths:
        fail(
            "Frozen Phase 0 fixture path set changed relative to "
            f"{PHASE0_ARTIFACT_BASELINE}: baseline={fixture_paths}, current={current_fixture_paths}"
        )

    for relative in [*fixture_paths, *FROZEN_FILES]:
        current = (ROOT / relative).read_bytes()
        baseline = git_bytes(PHASE0_ARTIFACT_BASELINE, relative)
        if current != baseline:
            fail(
                "Frozen Phase 0 artifact changed relative to "
                f"{PHASE0_ARTIFACT_BASELINE}: {relative}"
            )


def main() -> int:
    package = json.loads(
        subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, text=True)
    )
    products = [(product["name"], product["type"]) for product in package["products"]]
    expected_names = ["RepoPrompt", "repoprompt-mcp", "repoprompt-headless"]
    if [name for name, _ in products] != expected_names:
        fail(f"Expected executable-only products {expected_names}, found {products}")
    if any("executable" not in product_type for _, product_type in products):
        fail(f"Every advertised product must be executable, found {products}")

    targets = {target["name"]: target for target in package["targets"]}
    expected_target_paths = {
        "RepoPromptShared": "Sources/RepoPromptShared",
        "RepoPromptPOSIXSupport": "Sources/RepoPromptPOSIXSupport",
        "RepoPromptCore": "Sources/RepoPromptCore",
        "RepoPromptCoreMacOS": "Sources/RepoPromptCoreMacOS",
    }
    for name, path in expected_target_paths.items():
        if targets.get(name, {}).get("path") != path:
            fail(f"Target {name} must remain at {path}")

    exact_by_name_dependencies = {
        "RepoPrompt": {
            "RepoPromptShared",
            "RepoPromptPOSIXSupport",
            "RepoPromptCore",
            "RepoPromptCoreMacOS",
            "RepoPromptSyntaxCBridge",
            "RepoPromptC",
            "CSwiftPCRE2",
            "Sparkle",
        },
        "RepoPromptMCP": {"RepoPromptShared", "RepoPromptPOSIXSupport"},
        "RepoPromptCoreMacOS": {"RepoPromptCore", "RepoPromptPOSIXSupport"},
        "RepoPromptHeadless": {"RepoPromptShared", "RepoPromptCore", "RepoPromptCoreMacOS"},
    }
    for target_name, expected in exact_by_name_dependencies.items():
        actual = by_name_dependencies(targets[target_name])
        if actual != expected:
            fail(
                f"{target_name} target dependencies differ from Phase 1: "
                f"expected={sorted(expected)}, actual={sorted(actual)}"
            )

    core_dependency_records = targets["RepoPromptCore"].get("dependencies", [])
    core_dependencies = by_name_dependencies(targets["RepoPromptCore"])
    if core_dependency_records:
        fail(f"RepoPromptCore must have no dependency records in Phase 1: {core_dependency_records}")
    if core_dependencies:
        fail(f"RepoPromptCore must have no premature target edges in Phase 1: {sorted(core_dependencies)}")

    core_macos_product_dependencies = [
        dependency for dependency in targets["RepoPromptCoreMacOS"].get("dependencies", []) if "product" in dependency
    ]
    if core_macos_product_dependencies:
        fail(f"RepoPromptCoreMacOS has unexpected product dependencies: {core_macos_product_dependencies}")

    shared_imports = swift_imports(ROOT / "Sources/RepoPromptShared")
    for source, imports in shared_imports.items():
        unexpected = [module for module in imports if module != "Foundation"]
        if unexpected:
            fail(f"RepoPromptShared must be Foundation-only: {source.relative_to(ROOT)} imports {unexpected}")

    core_imports = swift_imports(ROOT / "Sources/RepoPromptCore")
    for source, imports in core_imports.items():
        unexpected = [module for module in imports if module != "Foundation"]
        if unexpected:
            fail(f"RepoPromptCore Phase 1 contracts must be Foundation-only: {source.relative_to(ROOT)} imports {unexpected}")

    posix_files = list((ROOT / "Sources").rglob("POSIXDescriptorSupport.swift"))
    expected_posix = ROOT / "Sources/RepoPromptPOSIXSupport/Descriptors/POSIXDescriptorSupport.swift"
    if posix_files != [expected_posix]:
        fail(f"POSIXDescriptorSupport.swift must be single-sourced at {expected_posix.relative_to(ROOT)}")

    core_text = "\n".join(path.read_text() for path in sorted((ROOT / "Sources/RepoPromptCore").rglob("*.swift")))
    forbidden_core_tokens = [
        "POSIXDescriptorConfigurationError",
        "connectedFileDescriptor",
        "import Darwin",
        "import Glibc",
        "import SystemPackage",
        "import RepoPromptShared",
        "import RepoPromptPOSIXSupport",
    ]
    for token in forbidden_core_tokens:
        if token in core_text:
            fail(f"Darwin/POSIX-backed Core boundary token remains: {token}")

    boundary = (ROOT / "Sources/RepoPromptCore/MCP/Platform/MCPAppProxyTransportBoundary.swift").read_text()
    for required in [
        "MCPAppProxyAcceptedTransport",
        "MCPAppProxyAcceptedTransportLease",
        "reserveForAdmission",
        "transfer(",
        "rollback()",
    ]:
        if required not in boundary:
            fail(f"Opaque accepted-transport boundary missing {required}")

    process_contract = (ROOT / "Sources/RepoPromptCore/Platform/ProcessLaunching.swift").read_text()
    for required in ["operation: String", "label: String", "fd: Int32", "errno: Int32"]:
        if required not in process_contract:
            fail(f"Neutral process error missing field {required}")

    assert_frozen_phase0_artifacts()
    print("OK: shared runtime Phase 1 boundary characterization passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
