#!/usr/bin/env python3
"""Phase 2 Slice 1 workspace-authority and frozen-headless boundary checks."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINE = "7e686cf"
HEADLESS_ROOTS = ("Sources/RepoPromptHeadless", "Tests/RepoPromptHeadlessTests")
PHASE0_ROOT = "Tests/SharedRuntimeConvergenceFixtures/Phase0"

CORE_FILES = [
    "Sources/RepoPromptCore/WorkspaceContext/Slices/LineRange.swift",
    "Sources/RepoPromptCore/Workspaces/CodeMapUsage.swift",
    "Sources/RepoPromptCore/Workspaces/CopyCustomizations.swift",
    "Sources/RepoPromptCore/Workspaces/EmbeddedWorkspaceCodecV1.swift",
    "Sources/RepoPromptCore/Workspaces/FileTreeOption.swift",
    "Sources/RepoPromptCore/Workspaces/FilesTab.swift",
    "Sources/RepoPromptCore/Workspaces/GitInclusion.swift",
    "Sources/RepoPromptCore/Workspaces/WorkspaceModel.swift",
    "Sources/RepoPromptCore/Workspaces/WorkspacePersistenceWriter.swift",
    "Sources/RepoPromptCore/Workspaces/WorkspaceRepository.swift",
    "Sources/RepoPromptCore/Workspaces/WorkspaceSaveMetadata.swift",
    "Sources/RepoPromptCore/Workspaces/WorkspaceSessionController.swift",
]

APP_ADAPTER_FILES = [
    "Sources/RepoPrompt/App/CoreAdapters/EmbeddedWorkspaceRepositoryDiagnosticsAdapter.swift",
    "Sources/RepoPrompt/App/CoreAdapters/EmbeddedWorkspaceRepositoryFactory.swift",
    "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionObservationBridge.swift",
    "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionSelectionForwarder.swift",
]

REMOVED_FILES = [
    "Sources/RepoPrompt/Features/Workspaces/Core/WorkspaceRepository.swift",
    "Sources/RepoPrompt/Features/Workspaces/Core/WorkspaceSessionController.swift",
    "Sources/RepoPrompt/Features/Prompt/Models/Copy/CopyCustomizations.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/LineRange.swift",
]


def fail(message: str) -> None:
    raise AssertionError(message)


def git_paths(revision: str, root: str) -> list[str]:
    return subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", revision, root], cwd=ROOT, text=True
    ).splitlines()


def git_bytes(revision: str, path: str) -> bytes:
    return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT)


def assert_tree_unchanged(root: str) -> None:
    baseline_paths = git_paths(BASELINE, root)
    current_root = ROOT / root
    current_paths = sorted(
        path.relative_to(ROOT).as_posix() for path in current_root.rglob("*") if path.is_file()
    )
    if current_paths != baseline_paths:
        fail(
            f"Frozen tree path set changed relative to {BASELINE}: {root}: "
            f"baseline={baseline_paths}, current={current_paths}"
        )
    for relative in baseline_paths:
        if (ROOT / relative).read_bytes() != git_bytes(BASELINE, relative):
            fail(f"Frozen file changed relative to {BASELINE}: {relative}")


def swift_sources(root: Path) -> list[Path]:
    return sorted(root.rglob("*.swift"))


def constructor_files(token: str) -> list[str]:
    matches: list[str] = []
    for source in swift_sources(ROOT / "Sources"):
        if token in source.read_text():
            matches.append(source.relative_to(ROOT).as_posix())
    return matches


def main() -> int:
    for relative in [*CORE_FILES, *APP_ADAPTER_FILES]:
        if not (ROOT / relative).is_file():
            fail(f"Required Slice 1 file missing: {relative}")
    for relative in REMOVED_FILES:
        if (ROOT / relative).exists():
            fail(f"Retired pre-Slice 1 owner still exists: {relative}")

    core_workspace_text = "\n".join((ROOT / path).read_text() for path in CORE_FILES)
    forbidden_core_tokens = [
        "import AppKit",
        "import SwiftUI",
        "import Combine",
        "import Cocoa",
        "import OSLog",
        "import os",
        "import Darwin",
        "import Glibc",
        "UserDefaults",
        "Application Support",
        "Bundle.main",
        "Notification.Name",
        "WorkspaceManagerViewModel",
    ]
    for token in forbidden_core_tokens:
        if token in core_workspace_text:
            fail(f"Core workspace authority contains app/platform token: {token}")

    all_core_text = "\n".join(path.read_text() for path in swift_sources(ROOT / "Sources/RepoPromptCore"))
    if "CanonicalWorkspaceCodecV2(" in all_core_text:
        fail("Canonical v2 codec is selected or constructed during Slice 1")

    expected_constructors = {
        "WorkspacePersistenceWriter(": [
            "Sources/RepoPrompt/App/CoreAdapters/EmbeddedWorkspaceRepositoryFactory.swift"
        ],
        "WorkspaceRepository(": [
            "Sources/RepoPrompt/App/CoreAdapters/EmbeddedWorkspaceRepositoryFactory.swift"
        ],
        "WorkspaceSessionController(": [
            "Sources/RepoPrompt/Infrastructure/Core/RepoPromptCoreHost.swift"
        ],
    }
    for token, expected in expected_constructors.items():
        actual = constructor_files(token)
        if actual != expected:
            fail(f"Production constructor ownership changed for {token}: expected={expected}, actual={actual}")

    manager_path = ROOT / "Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift"
    manager = manager_path.read_text()
    forbidden_manager_patterns = [
        r"@Published\s+(?:private\(set\)\s+)?var\s+workspaces\b",
        r"@Published\s+(?:private\(set\)\s+)?var\s+activeWorkspaceID\b",
        r"\bvar\s+workspaces\s*:\s*\[WorkspaceModel\]\s*=",
        r"\bvar\s+activeWorkspaceID\s*:\s*UUID\?\s*=",
        r"WorkspaceDiskWriter",
        r"func\s+saveWorkspaceToFile\s*\(",
        r"func\s+saveWorkspaceIndex\s*\(",
        r"writeNormalizationIfUnchanged",
        r"normalizationWriteback",
        r"normalizationRequiresSave",
    ]
    for pattern in forbidden_manager_patterns:
        if re.search(pattern, manager):
            fail(f"WorkspaceManagerViewModel regained forbidden authority/read-write behavior: {pattern}")
    required_manager_patterns = [
        r"var\s+workspaces\s*:\s*\[WorkspaceModel\]\s*\{\s*sessionController\.workspaces\s*\}",
        r"var\s+activeWorkspaceID\s*:\s*UUID\?\s*\{\s*sessionController\.activeWorkspaceID\s*\}",
        r"func\s+workspaceTransaction\s*\(",
        r"func\s+mutateWorkspace\s*\(",
        r"func\s+mutateComposeTab\s*\(",
    ]
    for pattern in required_manager_patterns:
        if not re.search(pattern, manager, re.DOTALL):
            fail(f"WorkspaceManagerViewModel missing controller projection/operation: {pattern}")

    direct_mutation = re.compile(
        r"workspaceManager\.workspaces(?:\[[^\]]+\])?(?:\.[A-Za-z_][A-Za-z0-9_]*)?\s*="
        r"|workspaceManager\.workspaces\.(?:append|insert|remove|removeAll|swapAt)\s*\("
    )
    for source in swift_sources(ROOT / "Sources/RepoPrompt"):
        if direct_mutation.search(source.read_text()):
            fail(f"Direct app workspace mutation bypasses the controller: {source.relative_to(ROOT)}")

    forwarder = (ROOT / APP_ADAPTER_FILES[-1]).read_text()
    if "Temporary Slice 1 bridge" not in forwarder or "Slice 2 deletes" not in forwarder:
        fail("Temporary selection forwarder must carry its explicit Slice 2 deletion marker")

    phase0_baseline = git_paths(BASELINE, PHASE0_ROOT)
    if not phase0_baseline:
        fail(f"No Phase 0 fixtures found at {BASELINE}")
    assert_tree_unchanged(PHASE0_ROOT)
    for root in HEADLESS_ROOTS:
        assert_tree_unchanged(root)

    print("OK: shared runtime Phase 2 Slice 1 workspace-authority boundaries passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
