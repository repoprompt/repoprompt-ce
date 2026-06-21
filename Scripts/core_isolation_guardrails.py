#!/usr/bin/env python3
"""Structural guards for the staged Core-isolation target graph."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


TARGET_PATHS = {
    "RepoPromptSyntaxCBridge": "Sources/RepoPromptSyntaxCBridge",
    "RepoPromptCore": "Sources/RepoPromptCore",
    "RepoPromptPOSIXSupport": "Sources/RepoPromptPOSIXSupport",
    "RepoPromptCoreMacOS": "Sources/RepoPromptCoreMacOS",
    "RepoPromptHeadless": "Sources/RepoPromptHeadless",
}

RESERVED_TEST_PATHS = {
    "RepoPromptCoreTests": "Tests/RepoPromptCoreTests",
    "RepoPromptCoreMacOSTests": "Tests/RepoPromptCoreMacOSTests",
    "RepoPromptPOSIXSupportTests": "Tests/RepoPromptPOSIXSupportTests",
    "RepoPromptSyntaxCBridgeTests": "Tests/RepoPromptSyntaxCBridgeTests",
    "RepoPromptHeadlessTests": "Tests/RepoPromptHeadlessTests",
}

TEST_TARGET_DEPENDENCIES = {
    "RepoPromptCoreTests": {"RepoPromptCore"},
    "RepoPromptCoreMacOSTests": {"RepoPromptCoreMacOS"},
    "RepoPromptPOSIXSupportTests": {"RepoPromptPOSIXSupport"},
    "RepoPromptSyntaxCBridgeTests": {"RepoPromptSyntaxCBridge"},
    "RepoPromptHeadlessTests": {"RepoPromptHeadless"},
}

EXPECTED_DEPENDENCIES = {
    "RepoPromptSyntaxCBridge": {
        ("target", "TreeSitterScannerSupport", ""),
        ("product", "TreeSitterC", "tree-sitter-c"),
        ("product", "TreeSitterDart", "tree-sitter-dart"),
        ("product", "TreeSitterGo", "tree-sitter-go"),
        ("product", "TreeSitterJava", "tree-sitter-java"),
        ("product", "TreeSitterJavaScript", "tree-sitter-javascript"),
        ("product", "TreeSitterPython", "tree-sitter-python"),
        ("product", "TreeSitterRust", "tree-sitter-rust"),
        ("product", "TreeSitterTypeScript", "tree-sitter-typescript"),
        ("product", "TreeSitterRuby", "tree-sitter-ruby"),
        ("product", "TreeSitterSwift", "tree-sitter-swift"),
        ("product", "TreeSitterCSharp", "tree-sitter-c-sharp"),
        ("product", "TreeSitterCPP", "tree-sitter-cpp"),
        ("product", "TreeSitterPHP", "tree-sitter-php"),
    },
    "RepoPromptCore": {
        ("target", "RepoPromptC", ""),
        ("target", "CSwiftPCRE2", ""),
        ("target", "RepoPromptSyntaxCBridge", ""),
        ("product", "SwiftTreeSitter", "SwiftTreeSitter"),
    },
    "RepoPromptPOSIXSupport": set(),
    "RepoPromptCoreMacOS": {
        ("target", "RepoPromptCore", ""),
        ("target", "RepoPromptPOSIXSupport", ""),
        ("product", "UniversalCharsetDetection", "UniversalCharsetDetection"),
        ("product", "Cuchardet", "UniversalCharsetDetection"),
    },
    "RepoPromptHeadless": {
        ("target", "RepoPromptShared", ""),
        ("target", "RepoPromptCore", ""),
        ("target", "RepoPromptCoreMacOS", ""),
        ("target", "RepoPromptPOSIXSupport", ""),
        ("product", "Logging", "swift-log"),
    },
}

EXPECTED_EXISTING_LOCAL_DEPENDENCIES = {
    # Phase 3 uses explicit platform/POSIX/syntax modules. RepoPromptC remains
    # until the Phase 4 engine move because app-owned ignore/search policy still calls it.
    "RepoPrompt": {
        "RepoPromptShared",
        "RepoPromptCore",
        "RepoPromptCoreMacOS",
        "RepoPromptPOSIXSupport",
        "RepoPromptSyntaxCBridge",
        "RepoPromptC",
        "Sparkle",
    },
    "RepoPromptMCP": {"RepoPromptShared", "RepoPromptPOSIXSupport"},
}

ALLOWED_IMPORTS = {
    "RepoPromptCore": {
        "Foundation",
        "Dispatch",
        "CryptoKit",
        "RepoPromptC",
        "CSwiftPCRE2",
        "RepoPromptSyntaxCBridge",
        "SwiftTreeSitter",
    },
    "RepoPromptCoreMacOS": {
        "Foundation",
        "Dispatch",
        "CryptoKit",
        "CoreFoundation",
        "CoreServices",
        "Darwin",
        "Security",
        "RepoPromptCore",
        "RepoPromptPOSIXSupport",
        "UniversalCharsetDetection",
        "Cuchardet",
    },
    "RepoPromptPOSIXSupport": {"Foundation", "Darwin"},
    "RepoPromptSyntaxCBridge": {
        "TreeSitterScannerSupport",
        "TreeSitterC",
        "TreeSitterDart",
        "TreeSitterGo",
        "TreeSitterJava",
        "TreeSitterJavaScript",
        "TreeSitterPython",
        "TreeSitterRust",
        "TreeSitterTypeScript",
        "TreeSitterRuby",
        "TreeSitterSwift",
        "TreeSitterCSharp",
        "TreeSitterCPP",
        "TreeSitterPHP",
    },
    "RepoPromptHeadless": {
        "Foundation",
        "Dispatch",
        "RepoPromptShared",
        "RepoPromptCore",
        "RepoPromptCoreMacOS",
        "RepoPromptPOSIXSupport",
        "Logging",
    },
}

CORE_DECLARATIONS = {
    "WorkspacePreset",
    "StoredSelection",
    "ContextBuilderOverrides",
    "ContextBuilderTabConfig",
    "StashedTab",
    "ComposeTabState",
    "WorkspaceModel",
    "WorkspaceLookupRootScope",
    "WorkspaceLookupRootScopeAvailability",
    "WorkspaceRootKind",
    "WorkspaceRootRecord",
    "WorkspaceFolderRecord",
    "WorkspaceFileRecord",
    "WorkspaceSearchReadinessTicket",
    "WorkspaceSearchReadinessState",
    "WorkspaceSearchReadinessWaitError",
    "WorkspaceCatalogDiagnostics",
    "WorkspaceSearchCatalogEntry",
    "WorkspaceSearchCatalogAccessRequirement",
    "WorkspaceSearchQueryResult",
    "WorkspacePathLookupRequest",
    "WorkspacePathLocation",
    "WorkspacePathLookupResult",
    "WorkspaceResolvedCandidates",
    "WorkspaceCodemapOnlyCandidates",
    "PathMatchLocation",
    "PathMatchCacheIdentity",
    "PathLocateProfile",
    "PathLocateOptions",
    "FileCreationResolution",
    "AnyItem",
    "PathCharPolicy",
    "LineRange",
    "SliceRangeMath",
    "ResolvedWorkspaceSelection",
    "ResolvedPromptFileEntryID",
    "ResolvedPromptFileEntryRole",
    "PromptFileEntryMode",
    "ResolvedPromptFileEntry",
    "ResolvedPromptFileBlockRecord",
    "TokenCalculationSnapshot",
    "FileAPI",
    "InterfaceInfo",
    "TypeAliasInfo",
    "ClassInfo",
    "FunctionInfo",
    "ParameterInfo",
    "PropertyInfo",
    "VariableInfo",
    "EnumInfo",
    "WorkspaceCodemapSnapshot",
    "WorkspaceCodemapSnapshotBundle",
    "RenderedCodemap",
    "WorkspaceCodemapRepairResult",
    "WorkspaceCodemapUpdateEvent",
    "RepoPromptRegexRuntime",
    "RepoPromptPCRE2MatchPolicy",
    "RepoPromptPCRE2CompileResult",
    "RepoPromptPCRE2CompileRequest",
    "RepoPromptPCRE2Adapter",
    "RegexPatternFailure",
    "RegexToolkit",
    "SearchPatternErrorFormatter",
    "SearchPatternError",
    "SearchPatternTooComplexError",
    "RelativePath",
    "StandardizedPath",
    "StoredSelectionPathNormalization",
    "GitDiffPathNormalization",
    "CheckoutPathIdentity",
    "RepoSearchQuery",
    "PathSearchIndex",
    "WorkspaceRootRef",
    "RootAliasOptions",
    "RootAliasResolution",
    "PathResolutionIssue",
    "ClientPathFormatter",
}

IMPORT_RE = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n)]*\))?\s+)|"
    r"(?:(?:public|internal|package|private|fileprivate)\s+))*import\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_.]*)",
    re.MULTILINE,
)
DECL_RE = re.compile(
    r"^\s*(?:(?:public|internal|package|private|fileprivate|open|final|indirect|nonisolated)\s+)*"
    r"(?:struct|enum|class|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)\b",
    re.MULTILINE,
)
C_FUNCTION_RE = re.compile(
    r"^\s*(?!static\b)(?:(?:extern|inline|const|volatile|unsigned|signed|long|short)\s+)*"
    r"[A-Za-z_][A-Za-z0-9_]*(?:\s*\*+)?\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.MULTILINE,
)
C_EXTERN_GLOBAL_RE = re.compile(
    r"^\s*extern\s+(?:const\s+)?[A-Za-z_][A-Za-z0-9_]*(?:\s*\*+)?\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[.*?\])?\s*;",
    re.MULTILINE,
)
CDECL_RE = re.compile(r'@_cdecl\(\s*"([^"]+)"\s*\)')


def dependency_key(dependency: dict[str, Any]) -> tuple[str, str, str]:
    if "byName" in dependency:
        return ("target", dependency["byName"][0], "")
    if "product" in dependency:
        return ("product", dependency["product"][0], dependency["product"][1])
    return ("unknown", json.dumps(dependency, sort_keys=True), "")


def validate_package(package: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    targets = {target["name"]: target for target in package.get("targets", [])}

    products = {
        (product["name"], tuple(product.get("targets", [])))
        for product in package.get("products", [])
    }
    expected_products = {
        ("RepoPrompt", ("RepoPrompt",)),
        ("repoprompt-mcp", ("RepoPromptMCP",)),
        ("repoprompt-headless", ("RepoPromptHeadless",)),
    }
    if products != expected_products:
        errors.append("executable products must remain exactly RepoPrompt, repoprompt-mcp, and repoprompt-headless")

    for name, expected_path in TARGET_PATHS.items():
        target = targets.get(name)
        if target is None:
            errors.append(f"missing Phase 1 production target: {name}")
            continue
        if target.get("path") != expected_path:
            errors.append(f"{name} path must remain {expected_path}")
        expected_type = "executable" if name == "RepoPromptHeadless" else "regular"
        if target.get("type") != expected_type:
            errors.append(f"{name} must remain a {expected_type} target")
        actual = {dependency_key(item) for item in target.get("dependencies", [])}
        expected = EXPECTED_DEPENDENCIES[name]
        if actual != expected:
            errors.append(
                f"{name} direct dependencies drifted: expected {sorted(expected)}, got {sorted(actual)}"
            )

    for name, expected_path in RESERVED_TEST_PATHS.items():
        target = targets.get(name)
        if target is None:
            continue
        if target.get("path") != expected_path:
            errors.append(f"{name} path must remain {expected_path}")
        if target.get("type") != "test":
            errors.append(f"{name} must remain a test target")
        actual_targets = {
            key[1]
            for key in (dependency_key(item) for item in target.get("dependencies", []))
            if key[0] == "target"
        }
        expected_targets = TEST_TARGET_DEPENDENCIES[name]
        if actual_targets != expected_targets:
            errors.append(
                f"{name} local dependencies drifted: expected {sorted(expected_targets)}, "
                f"got {sorted(actual_targets)}"
            )

    for name, expected in EXPECTED_EXISTING_LOCAL_DEPENDENCIES.items():
        target = targets.get(name)
        if target is None:
            errors.append(f"missing existing production target: {name}")
            continue
        actual_targets = {
            key[1]
            for key in (dependency_key(item) for item in target.get("dependencies", []))
            if key[0] == "target"
        }
        if actual_targets != expected:
            errors.append(
                f"{name} local dependencies drifted: expected {sorted(expected)}, "
                f"got {sorted(actual_targets)}"
            )

    local_names = set(targets)
    graph: dict[str, set[str]] = {}
    for name, target in targets.items():
        graph[name] = {
            key[1]
            for key in (dependency_key(item) for item in target.get("dependencies", []))
            if key[0] == "target" and key[1] in local_names
        }

    visiting: list[str] = []
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visiting:
            cycle = visiting[visiting.index(name) :] + [name]
            errors.append(f"local target dependency cycle: {' -> '.join(cycle)}")
            return
        if name in visited:
            return
        visiting.append(name)
        for dependency in sorted(graph.get(name, set())):
            visit(dependency)
        visiting.pop()
        visited.add(name)

    for name in sorted(graph):
        visit(name)

    return errors


def swift_files(root: Path, relative: str) -> list[Path]:
    directory = root / relative
    return sorted(directory.rglob("*.swift")) if directory.is_dir() else []


def validate_sources(root: Path) -> list[str]:
    errors: list[str] = []
    for name, relative in RESERVED_TEST_PATHS.items():
        directory = root / relative
        if not directory.exists():
            continue
        files = swift_files(root, relative)
        if not files or not any("XCTestCase" in file.read_text(encoding="utf-8") for file in files):
            errors.append(f"test root {relative} must contain a meaningful XCTestCase before {name} is declared")
    for target, relative in TARGET_PATHS.items():
        directory = root / relative
        if not directory.is_dir():
            errors.append(f"missing Phase 1 source root: {relative}")
            continue
        files = swift_files(root, relative)
        if target == "RepoPromptSyntaxCBridge":
            bridge_sources = sorted(
                path for path in directory.rglob("*")
                if path.is_file() and path.suffix.lower() in {".c", ".h"}
            )
            if not bridge_sources:
                errors.append(f"Phase 3 syntax bridge has no C/header source: {relative}")
        elif not files:
            errors.append(f"production source root has no Swift source: {relative}")
        allowed = ALLOWED_IMPORTS[target]
        for file in files:
            text = file.read_text(encoding="utf-8")
            for imported in IMPORT_RE.findall(text):
                module = imported.split(".", 1)[0]
                if module not in allowed:
                    errors.append(f"{file.relative_to(root)} imports forbidden module {imported}")
            for symbol in CDECL_RE.findall(text):
                if not symbol.startswith("rpce_"):
                    errors.append(f"{file.relative_to(root)} exports unprefixed C symbol {symbol}")

    declaration_locations: dict[str, list[str]] = {name: [] for name in CORE_DECLARATIONS}
    sources_root = root / "Sources"
    if sources_root.is_dir():
        for file in sorted(sources_root.rglob("*.swift")):
            text = file.read_text(encoding="utf-8")
            for name in DECL_RE.findall(text):
                if name in declaration_locations:
                    declaration_locations[name].append(str(file.relative_to(root)))
    for name, locations in sorted(declaration_locations.items()):
        if len(locations) != 1:
            errors.append(f"{name} must have exactly one concrete production declaration; found {locations}")

    legacy_bridge = root / "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h"
    if legacy_bridge.exists():
        errors.append("RepoPrompt target-wide bridging header must remain removed after Phase 3")
    package_text = (root / "Package.swift").read_text(encoding="utf-8")
    if "-import-objc-header" in package_text or "-disable-bridging-pch" in package_text:
        errors.append("Package.swift must not restore RepoPrompt bridging-header flags")

    forbidden_app_imports = {
        "CoreServices", "Security", "Cuchardet", "UniversalCharsetDetection"
    }
    app_root = root / "Sources/RepoPrompt"
    for file in sorted(app_root.rglob("*.swift")):
        imported = {name.split(".", 1)[0] for name in IMPORT_RE.findall(file.read_text(encoding="utf-8"))}
        leaked = sorted(imported & forbidden_app_imports)
        if leaked:
            errors.append(
                f"{file.relative_to(root)} retains Phase 3 platform imports {leaked}"
            )

    if (root / "Sources/RepoPromptShared/MCP/POSIXDescriptorSupport.swift").exists():
        errors.append("POSIXDescriptorSupport must have one canonical owner in RepoPromptPOSIXSupport")

    expected_syntax_files = {
        "Sources/RepoPromptSyntaxCBridge/RepoPromptSyntaxCBridge.c",
        "Sources/RepoPromptSyntaxCBridge/include/RepoPromptSyntaxCBridge.h",
    }
    actual_syntax_files = {
        str(path.relative_to(root))
        for path in (root / "Sources/RepoPromptSyntaxCBridge").rglob("*")
        if path.is_file()
    }
    if actual_syntax_files != expected_syntax_files:
        errors.append(
            f"syntax bridge files drifted: expected {sorted(expected_syntax_files)}, "
            f"got {sorted(actual_syntax_files)}"
        )

    bridge_symbols: dict[str, list[str]] = {}
    bridge_files: list[Path] = []
    bridge_files.extend(
        file
        for relative in ("Sources/RepoPromptPOSIXSupport", "Sources/RepoPromptSyntaxCBridge")
        for file in sorted((root / relative).rglob("*"))
        if file.suffix.lower() in {".c", ".h", ".m", ".mm"}
    )
    for file in bridge_files:
        if not file.is_file():
            continue
        text = file.read_text(encoding="utf-8")
        relative = str(file.relative_to(root))
        for symbol in C_FUNCTION_RE.findall(text) + C_EXTERN_GLOBAL_RE.findall(text):
            if symbol.startswith("tree_sitter_"):
                bridge_symbols.setdefault(symbol, []).append(relative)
                continue
            if relative.startswith(("Sources/RepoPromptPOSIXSupport/", "Sources/RepoPromptSyntaxCBridge/")):
                if not symbol.startswith("rpce_"):
                    errors.append(f"{relative} declares unprefixed CE C symbol {symbol}")
    expected_tree_sitter_symbols = {
        "tree_sitter_javascript", "tree_sitter_python", "tree_sitter_c_sharp",
        "tree_sitter_swift", "tree_sitter_c", "tree_sitter_cpp",
        "tree_sitter_rust", "tree_sitter_go", "tree_sitter_java",
        "tree_sitter_dart", "tree_sitter_php", "tree_sitter_ruby",
        "tree_sitter_typescript", "tree_sitter_tsx",
    }
    if set(bridge_symbols) != expected_tree_sitter_symbols:
        errors.append(
            f"syntax bridge declarations drifted: expected {sorted(expected_tree_sitter_symbols)}, "
            f"got {sorted(bridge_symbols)}"
        )
    for symbol, locations in sorted(bridge_symbols.items()):
        if len(locations) != 1:
            errors.append(f"upstream symbol {symbol} must have one bridge declaration; found {locations}")

    package_script = root / "Scripts/package_app.sh"
    if package_script.is_file() and re.search(
        r"RepoPromptHeadless|repoprompt-headless|rpce-headless", package_script.read_text(encoding="utf-8")
    ):
        errors.append("Scripts/package_app.sh must remain app/proxy-only until Phase 8")
    app_bundle = root / "AppBundle"
    if app_bundle.is_dir():
        for file in sorted(path for path in app_bundle.rglob("*") if path.is_file()):
            try:
                text = file.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if re.search(r"RepoPromptHeadless|repoprompt-headless|rpce-headless", text):
                errors.append(f"{file.relative_to(root)} must not package the standalone headless product")

    return errors


def load_package(root: Path) -> dict[str, Any]:
    output = subprocess.check_output(
        ["swift", "package", "dump-package"], cwd=root, text=True, stderr=subprocess.STDOUT
    )
    return json.loads(output)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--package-json", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    package = json.loads(args.package_json.read_text()) if args.package_json else load_package(root)
    errors = validate_package(package) + validate_sources(root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("OK: Core isolation target, source, symbol, and package-separation guardrails passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
