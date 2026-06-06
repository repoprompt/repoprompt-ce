#!/usr/bin/env python3
"""Phase 2 runtime, prompt-assembly, and frozen-headless boundary checks."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASELINE = "7e686cf"
FROZEN_TREES = (
    "Sources/RepoPromptHeadless",
    "Tests/RepoPromptHeadlessTests",
    "Tests/SharedRuntimeConvergenceFixtures/Phase0",
)
FROZEN_FILES = (
    "docs/characterization/shared-runtime-phase0-2026-06-05.md",
    "Scripts/test_shared_runtime_phase0_characterization.py",
)

REQUIRED_RUNTIME_PATHS = (
    "Sources/RepoPromptCore/FileSystem/FileSystemService.swift",
    "Sources/RepoPromptCore/Regex/PCRE2Regex.swift",
    "Sources/RepoPromptCore/SyntaxParsing/SyntaxManager.swift",
    "Sources/RepoPromptCore/CodeMap/CodeMapGenerator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceRuntimeDependencies.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileContextStore.swift",
    "Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Search/WorkspaceSearchService.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Selection/WorkspaceSelectionController.swift",
    "Sources/RepoPromptCore/WorkspaceContext/Slices/SelectionSliceCoordinator.swift",
    "Sources/RepoPromptCore/WorkspaceContext/TokenAccounting/TokenCalculationService.swift",
    "Sources/RepoPromptCoreMacOS/FileSystem/MacOSWorkspaceDirectoryListingBackend.swift",
    "Sources/RepoPrompt/App/RepoPromptEmbeddedWorkspaceRuntimeFactory.swift",
)

RETIRED_RUNTIME_PATHS = (
    "Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift",
    "Sources/RepoPrompt/Infrastructure/Regex/PCRE2Regex.swift",
    "Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift",
    "Sources/RepoPrompt/Features/CodeMap/CodeMapGenerator.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceSearchService.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionController.swift",
    "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SelectionSliceCoordinator.swift",
    "Sources/RepoPrompt/App/CoreAdapters/WorkspaceSessionSelectionForwarder.swift",
)

REQUIRED_PROMPT_ASSEMBLY_PATHS = (
    "Sources/RepoPromptCore/Prompt/PromptAssemblyBuilder.swift",
    "Sources/RepoPromptCore/Prompt/PromptRenderPolicy.swift",
    "Sources/RepoPromptCore/Prompt/PromptSection.swift",
    "Sources/RepoPrompt/Features/Prompt/Models/PromptSection+DisplayName.swift",
)

RETIRED_PROMPT_ASSEMBLY_PATHS = (
    "Sources/RepoPrompt/Features/Prompt/Models/PromptAssemblyBuilder.swift",
)

CORE_IMPORTERS = {
    "RepoPromptC": {
        "FileSystem/GitignoreCompiler.swift",
        "Utilities/StringFNV.swift",
        "Utilities/StringLineEndingUtilities.swift",
        "WorkspaceContext/Search/PathSearchIndex.swift",
        "WorkspaceContext/Search/RepoSearchBatchScorer.swift",
        "WorkspaceContext/Search/SearchMatch.swift",
        "WorkspaceContext/Search/SearchPathFiltering.swift",
    },
    "CSwiftPCRE2": {
        "Regex/PCRE2Error.swift",
        "Regex/PCRE2JIT.swift",
        "Regex/PCRE2Options.swift",
        "Regex/PCRE2Regex.swift",
    },
    "RepoPromptSyntaxCBridge": {"SyntaxParsing/SyntaxManager.swift"},
    "SwiftTreeSitter": {
        "CodeMap/CodeMapCaptureIndex.swift",
        "CodeMap/CodeMapGenerator.swift",
        "CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift",
        "CodeMap/LanguageStrategies/TypeScriptCodeMapStrategy.swift",
        "SyntaxParsing/SyntaxManager.swift",
    },
    "UniversalCharsetDetection": {"FileSystem/FileSystemService+ContentLoading.swift"},
    "Cuchardet": {"FileSystem/FileSystemService+ContentLoading.swift"},
    "os": {"CodeMap/CodeMapGenerator.swift"},
}


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
    if not baseline_paths:
        fail(f"No frozen files found at {BASELINE}: {root}")
    current_paths = sorted(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / root).rglob("*")
        if path.is_file()
    )
    if current_paths != baseline_paths:
        fail(
            f"Frozen tree path set changed relative to {BASELINE}: {root}: "
            f"baseline={baseline_paths}, current={current_paths}"
        )
    for relative in baseline_paths:
        if (ROOT / relative).read_bytes() != git_bytes(BASELINE, relative):
            fail(f"Frozen file changed relative to {BASELINE}: {relative}")


def swift_imports(source: Path) -> list[str]:
    pattern = re.compile(
        r"^\s*(?:(?:@[_A-Za-z0-9]+(?:\([^)]*\))?)\s+)*"
        r"import(?:\s+(?:typealias|struct|class|enum|protocol|let|var|func))?"
        r"\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )
    return pattern.findall(source.read_text())


def dependency_names(target: dict[str, object], kind: str) -> set[str]:
    return {
        dependency[kind][0]
        for dependency in target.get("dependencies", [])
        if kind in dependency
    }


def importer_paths(module: str) -> set[str]:
    core_root = ROOT / "Sources/RepoPromptCore"
    return {
        source.relative_to(core_root).as_posix()
        for source in core_root.rglob("*.swift")
        if module in swift_imports(source)
    }


def token_files(token: str, root: Path) -> list[str]:
    return sorted(
        source.relative_to(ROOT).as_posix()
        for source in root.rglob("*.swift")
        if token in source.read_text()
    )


def main() -> int:
    package = json.loads(
        subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, text=True)
    )
    products = [(product["name"], product["type"]) for product in package["products"]]
    expected_products = ["RepoPrompt", "repoprompt-mcp", "repoprompt-headless"]
    if [name for name, _ in products] != expected_products:
        fail(f"Expected executable-only products {expected_products}, found {products}")
    if any("executable" not in product_type for _, product_type in products):
        fail(f"Every advertised product must remain executable: {products}")

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

    core_target = targets["RepoPromptCore"]
    expected_by_name = {"RepoPromptC", "CSwiftPCRE2", "RepoPromptSyntaxCBridge"}
    expected_products = {"SwiftTreeSitter", "UniversalCharsetDetection", "Cuchardet"}
    actual_by_name = dependency_names(core_target, "byName")
    actual_products = dependency_names(core_target, "product")
    if actual_by_name != expected_by_name:
        fail(
            "RepoPromptCore by-name dependencies must match importer-backed native edges: "
            f"expected={sorted(expected_by_name)}, actual={sorted(actual_by_name)}"
        )
    if actual_products != expected_products:
        fail(
            "RepoPromptCore product dependencies must match importer-backed native edges: "
            f"expected={sorted(expected_products)}, actual={sorted(actual_products)}"
        )
    if len(core_target.get("dependencies", [])) != len(expected_by_name) + len(expected_products):
        fail(f"RepoPromptCore has an unsupported dependency record: {core_target.get('dependencies', [])}")

    for module, expected in CORE_IMPORTERS.items():
        actual = importer_paths(module)
        if actual != expected:
            fail(
                f"RepoPromptCore {module} importer ownership drift: "
                f"expected={sorted(expected)}, actual={sorted(actual)}"
            )

    direct_grammar_products = sorted(
        product
        for product in actual_products
        if product.startswith("TreeSitter") and product != "SwiftTreeSitter"
    )
    if direct_grammar_products:
        fail(f"RepoPromptCore must not depend directly on grammar products: {direct_grammar_products}")

    for relative in REQUIRED_RUNTIME_PATHS:
        if not (ROOT / relative).is_file():
            fail(f"Required Phase 2 Slice 2 runtime owner missing: {relative}")
    for relative in RETIRED_RUNTIME_PATHS:
        if (ROOT / relative).exists():
            fail(f"Retired app runtime owner still exists: {relative}")
    for relative in REQUIRED_PROMPT_ASSEMBLY_PATHS:
        if not (ROOT / relative).is_file():
            fail(f"Required Slice 3 prompt assembly owner missing: {relative}")
    for relative in RETIRED_PROMPT_ASSEMBLY_PATHS:
        if (ROOT / relative).exists():
            fail(f"Retired app prompt assembly owner still exists: {relative}")

    core_root = ROOT / "Sources/RepoPromptCore"
    forbidden_imports = {
        "AppKit",
        "SwiftUI",
        "Combine",
        "Cocoa",
        "Sparkle",
        "KeyboardShortcuts",
        "CoreServices",
        "Security",
        "Darwin",
        "Glibc",
        "SystemPackage",
        "OSLog",
        "RepoPromptShared",
        "RepoPromptPOSIXSupport",
        "RepoPromptCoreMacOS",
    }
    for source in sorted(core_root.rglob("*.swift")):
        leaked = sorted(set(swift_imports(source)) & forbidden_imports)
        if leaked:
            fail(f"Core app/platform import leakage: {source.relative_to(ROOT)} imports {leaked}")

    core_text = "\n".join(source.read_text() for source in sorted(core_root.rglob("*.swift")))
    forbidden_tokens = (
        "UserDefaults.standard",
        "Bundle.main",
        "Notification.Name",
        "applicationSupportDirectory",
        "WindowState",
        "WindowStatesManager",
        "NSApplication",
        "NSWorkspace",
    )
    for token in forbidden_tokens:
        if token in core_text:
            fail(f"Core app/platform ownership token remains: {token}")

    all_sources_text = "\n".join(
        source.read_text() for source in sorted((ROOT / "Sources").rglob("*.swift"))
    )
    for token in ("WorkspaceSessionSelectionForwarder", "WorkspaceSelectionHost"):
        if token in all_sources_text:
            fail(f"Obsolete Slice 1 runtime bridge remains: {token}")

    factory_path = "Sources/RepoPrompt/App/RepoPromptEmbeddedWorkspaceRuntimeFactory.swift"
    constructor_owners = {
        "WorkspaceRuntimeDependencies(": [factory_path],
        "WorkspaceFileContextStore(runtimeDependencies:": [factory_path],
        "WorkspaceSearchService()": [factory_path],
        "SelectionSliceCoordinator(store:": [factory_path],
    }
    for token, expected in constructor_owners.items():
        actual = token_files(token, ROOT / "Sources")
        if actual != expected:
            fail(f"Core runtime construction ownership changed for {token}: expected={expected}, actual={actual}")

    headless_text = "\n".join(
        source.read_text()
        for root in (ROOT / "Sources/RepoPromptHeadless", ROOT / "Tests/RepoPromptHeadlessTests")
        for source in sorted(root.rglob("*.swift"))
    )
    for token in (
        "RepoPromptEmbeddedWorkspaceRuntimeFactory",
        "WorkspaceRuntimeDependencies(",
        "WorkspaceFileContextStore(",
        "WorkspaceSelectionController(",
        "WorkspaceSearchService(",
    ):
        if token in headless_text:
            fail(f"Frozen headless surface constructs the Phase 2 runtime: {token}")

    for root in FROZEN_TREES:
        assert_tree_unchanged(root)
    for relative in FROZEN_FILES:
        if (ROOT / relative).read_bytes() != git_bytes(BASELINE, relative):
            fail(f"Frozen Phase 0 characterization changed relative to {BASELINE}: {relative}")

    print("OK: shared runtime Phase 2 boundaries passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
