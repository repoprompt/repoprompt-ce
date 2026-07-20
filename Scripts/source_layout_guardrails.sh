#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

print_matches() {
  local label="$1"
  shift
  local output
  output="$($@ 2>/dev/null || true)"
  if [[ -n "$output" ]]; then
    fail "$label"
    printf '%s\n' "$output" >&2
  fi
}

# 0. Required layout roots/files should exist before negative scans run.
required_dirs=(
  "Sources/RepoPromptExecutable"
  "Sources/RepoPrompt/Features"
  "Sources/RepoPrompt/Infrastructure"
  "Sources/RepoPrompt/Infrastructure/SyntaxParsing"
  "Sources/RepoPromptShared/MCP"
  "Sources/RepoPromptWorkspaceCore"
  "Tests/RepoPromptTests"
  "Tests/RepoPromptWorkspaceCoreTests"
)
for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    fail "required source layout directory missing: $dir"
  fi
done

repo_prompt_entry="Sources/RepoPromptExecutable/RepoPromptExecutable.swift"
if [[ ! -f "$repo_prompt_entry" ]]; then
  fail "required thin RepoPrompt executable entry missing: $repo_prompt_entry"
fi
unexpected_repo_prompt_executable_files=""
if [[ -d "Sources/RepoPromptExecutable" ]]; then
  unexpected_repo_prompt_executable_files="$(find Sources/RepoPromptExecutable -type f ! -path "$repo_prompt_entry" -print)"
fi
if [[ -n "$unexpected_repo_prompt_executable_files" ]]; then
  fail "thin RepoPrompt executable target contains implementation files"
  printf '%s\n' "$unexpected_repo_prompt_executable_files" >&2
fi
repo_prompt_app_main_declarations="$(grep -R -n -E '^[[:space:]]*@main([[:space:]]|$)' Sources/RepoPrompt --include='*.swift' || true)"
if [[ -n "$repo_prompt_app_main_declarations" ]]; then
  fail "RepoPromptApp implementation target must not declare @main"
  printf '%s\n' "$repo_prompt_app_main_declarations" >&2
fi
repo_prompt_entry_main_count="$(grep -c -E '^[[:space:]]*@main([[:space:]]|$)' "$repo_prompt_entry" || true)"
if [[ "$repo_prompt_entry_main_count" -ne 1 ]]; then
  fail "thin RepoPrompt executable entry must declare exactly one @main"
fi

shared_mcp_required_files=(
  "Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  "Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift"
  "Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift"
)
for file in "${shared_mcp_required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required shared MCP file missing: $file"
  fi
done

# Tree-sitter uses exact upstream package products plus a narrow scanner linker shim.
if [[ -e "src/scanner.c" ]]; then
  fail "retired root src/scanner.c manifest-probe sentinel exists"
fi
tree_sitter_scanner_support_files=(
  "Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h"
  "Sources/TreeSitterScannerSupport/include/tree_sitter/array.h"
  "Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h"
  "Sources/TreeSitterScannerSupport/src/javascript/scanner.c"
  "Sources/TreeSitterScannerSupport/src/python/scanner.c"
  "ThirdPartyLicenses/tree-sitter/scanner-support.sha256"
)
for file in "${tree_sitter_scanner_support_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required TreeSitterScannerSupport compatibility file missing: $file"
  elif ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 &&
       [[ "$(git status --porcelain --untracked-files=all -- "$file")" != "?? $file" ]]; then
    fail "TreeSitterScannerSupport compatibility file must be tracked or pending addition: $file"
  fi
done
if [[ -d "Sources/TreeSitterScannerSupport" ]]; then
  unexpected_tree_sitter_scanner_support_files="$(find Sources/TreeSitterScannerSupport -type f \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h' \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/array.h' \
    ! -path 'Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h' \
    ! -path 'Sources/TreeSitterScannerSupport/src/javascript/scanner.c' \
    ! -path 'Sources/TreeSitterScannerSupport/src/python/scanner.c' \
    -print)"
  if [[ -n "$unexpected_tree_sitter_scanner_support_files" ]]; then
    fail "unexpected file found under narrow TreeSitterScannerSupport compatibility target"
    printf '%s\n' "$unexpected_tree_sitter_scanner_support_files" >&2
  fi
fi
if ! tree_sitter_scanner_support_checksum_output="$(shasum -a 256 -c ThirdPartyLicenses/tree-sitter/scanner-support.sha256 2>&1)"; then
  fail "TreeSitterScannerSupport compatibility snapshots differ from curated checksums"
  printf '%s\n' "$tree_sitter_scanner_support_checksum_output" >&2
fi

if ! tree_sitter_dependency_manifest_output="$(python3 <<'PY'
import json
import subprocess
from pathlib import Path

expected_packages = {
    "tree-sitter-c": ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", "b780e47fc780ddc8da13afa35a3f4ed5c157823d", "TreeSitterC"),
    "tree-sitter-dart": ("https://github.com/UserNobody14/tree-sitter-dart", None, "be07cf7118d3dba06236a3f19541685a68209934", "TreeSitterDart"),
    "tree-sitter-go": ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0", "1547678a9da59885853f5f5cc8a99cc203fa2e2c", "TreeSitterGo"),
    "tree-sitter-java": ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5", "94703d5a6bed02b98e438d7cad1136c01a60ba2c", "TreeSitterJava"),
    "tree-sitter-javascript": ("https://github.com/tree-sitter/tree-sitter-javascript", "0.25.0", "44c892e0be055ac465d5eeddae6d3e194424e7de", "TreeSitterJavaScript"),
    "tree-sitter-python": ("https://github.com/tree-sitter/tree-sitter-python", "0.25.0", "293fdc02038ee2bf0e2e206711b69c90ac0d413f", "TreeSitterPython"),
    "tree-sitter-rust": ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2", "77a3747266f4d621d0757825e6b11edcbf991ca5", "TreeSitterRust"),
    "tree-sitter-typescript": ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2", "f975a621f4e7f532fe322e13c4f79495e0a7b2e7", "TreeSitterTypeScript"),
    "tree-sitter-ruby": ("https://github.com/tree-sitter/tree-sitter-ruby", "0.23.1", "71bd32fb7607035768799732addba884a37a6210", "TreeSitterRuby"),
    "tree-sitter-swift": ("https://github.com/alex-pinkus/tree-sitter-swift", "0.7.3-with-generated-files", "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5", "TreeSitterSwift"),
    "tree-sitter-c-sharp": ("https://github.com/tree-sitter/tree-sitter-c-sharp.git", "0.23.5", "cac6d5fb595f5811a076336682d5d595ac1c9e85", "TreeSitterCSharp"),
    "tree-sitter-cpp": ("https://github.com/tree-sitter/tree-sitter-cpp", "0.23.4", "f41e1a044c8a84ea9fa8577fdd2eab92ec96de02", "TreeSitterCPP"),
    "tree-sitter-php": ("https://github.com/tree-sitter/tree-sitter-php.git", "0.24.2", "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea", "TreeSitterPHP"),
}
errors = []
manifest_text = Path("Package.swift").read_text()
resolved = json.loads(Path("Package.resolved").read_text())
resolved_pins = {pin["identity"]: pin for pin in resolved["pins"]}
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
targets = {target["name"]: target for target in package["targets"]}
repo_prompt = targets.get("RepoPrompt", {})
repo_prompt_app = targets.get("RepoPromptApp", {})
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
repo_prompt_app_dependencies = repo_prompt_app.get("dependencies", [])
repo_prompt_app_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_app_dependencies
    if "product" in dependency
}
repo_prompt_code_map_core = targets.get("RepoPromptCodeMapCore", {})
repo_prompt_code_map_core_dependencies = repo_prompt_code_map_core.get("dependencies", [])
repo_prompt_code_map_core_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_code_map_core_dependencies
    if "product" in dependency
}

if repo_prompt.get("type") != "executable":
    errors.append("RepoPrompt target must remain executable")
if repo_prompt.get("path") != "Sources/RepoPromptExecutable":
    errors.append("RepoPrompt target must remain the thin Sources/RepoPromptExecutable entry target")
repo_prompt_by_name_dependencies = [dependency["byName"][0] for dependency in repo_prompt_dependencies if dependency.get("byName")]
if len(repo_prompt_dependencies) != 1 or repo_prompt_by_name_dependencies != ["RepoPromptApp"]:
    errors.append("RepoPrompt executable target must depend only on RepoPromptApp")
if repo_prompt_app.get("type") != "regular":
    errors.append("RepoPromptApp target must remain an internal library target")
if repo_prompt_app.get("path") != "Sources/RepoPrompt":
    errors.append("RepoPromptApp target must retain the Sources/RepoPrompt implementation path")

workspace_core = targets.get("RepoPromptWorkspaceCore")
if workspace_core is None:
    errors.append("RepoPromptWorkspaceCore target missing")
else:
    if workspace_core.get("type") != "regular": errors.append("RepoPromptWorkspaceCore must remain an internal regular target")
    if workspace_core.get("path") != "Sources/RepoPromptWorkspaceCore": errors.append("RepoPromptWorkspaceCore target path drifted")
    if workspace_core.get("dependencies", []): errors.append("RepoPromptWorkspaceCore must not declare target or package dependencies")
    if workspace_core.get("settings", []): errors.append("RepoPromptWorkspaceCore must not declare compiler settings")

workspace_core_tests = targets.get("RepoPromptWorkspaceCoreTests")
if workspace_core_tests is None:
    errors.append("RepoPromptWorkspaceCoreTests target missing")
else:
    test_dependencies = [dependency["byName"][0] for dependency in workspace_core_tests.get("dependencies", []) if dependency.get("byName")]
    if workspace_core_tests.get("type") != "test": errors.append("RepoPromptWorkspaceCoreTests must remain a test target")
    if workspace_core_tests.get("path") != "Tests/RepoPromptWorkspaceCoreTests": errors.append("RepoPromptWorkspaceCoreTests target path drifted")
    if test_dependencies != ["RepoPromptWorkspaceCore"] or len(workspace_core_tests.get("dependencies", [])) != 1:
        errors.append("RepoPromptWorkspaceCoreTests must depend only on RepoPromptWorkspaceCore")

app_by_name_dependencies = [dependency["byName"][0] for dependency in repo_prompt_app_dependencies if dependency.get("byName")]
if app_by_name_dependencies.count("RepoPromptWorkspaceCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptWorkspaceCore")
for forbidden_consumer in ("RepoPrompt", "RepoPromptMCP", "RepoPromptShared", "RepoPromptTests"):
    dependencies = [dependency["byName"][0] for dependency in targets.get(forbidden_consumer, {}).get("dependencies", []) if dependency.get("byName")]
    if "RepoPromptWorkspaceCore" in dependencies: errors.append(f"{forbidden_consumer} must not directly depend on RepoPromptWorkspaceCore")
for product in package.get("products", []):
    if "RepoPromptWorkspaceCore" in product.get("targets", []): errors.append("RepoPromptWorkspaceCore must not be exposed as a package product")

for identity, (url, version, revision, product) in expected_packages.items():
    requirement = f'exact: "{version}"' if version is not None else f'revision: "{revision}"'
    manifest_pin = f'.package(url: "{url}", {requirement})'
    if manifest_pin not in manifest_text:
        errors.append(f"Package.swift missing exact pin: {identity} {version or revision}")
    pin = resolved_pins.get(identity)
    state = pin.get("state", {}) if pin is not None else {}
    if pin is None:
        errors.append(f"Package.resolved missing pin: {identity}")
    elif pin.get("location") != url or state.get("revision") != revision or state.get("version") != version:
        errors.append(f"Package.resolved pin drift: {identity}")
    if (product, identity) not in repo_prompt_code_map_core_products:
        errors.append(f"RepoPromptCodeMapCore missing upstream grammar product dependency: {product} ({identity})")

dart = resolved_pins.get("tree-sitter-dart", {})
if dart.get("state", {}) != {"revision": "be07cf7118d3dba06236a3f19541685a68209934"}:
    errors.append("Dart must remain the canonical exact revision exception because it has no releases")

wrapper = resolved_pins.get("swifttreesitter", {})
if '.package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.10.0")' not in manifest_text:
    errors.append("Package.swift must pin SwiftTreeSitter exactly to 0.10.0")
if wrapper.get("state", {}).get("version") != "0.10.0" or wrapper.get("state", {}).get("revision") != "f97df585296977d8fcaf644cbde567151d1367b8":
    errors.append("SwiftTreeSitter resolved version/revision drifted")
if ("SwiftTreeSitter", "SwiftTreeSitter") not in repo_prompt_app_products:
    errors.append("RepoPromptApp missing direct SwiftTreeSitter product dependency for highlighting")
if ("SwiftTreeSitter", "SwiftTreeSitter") not in repo_prompt_code_map_core_products:
    errors.append("RepoPromptCodeMapCore missing direct SwiftTreeSitter product dependency")

runtime = resolved_pins.get("tree-sitter", {})
if runtime.get("location") != "https://github.com/tree-sitter/tree-sitter" or runtime.get("state", {}).get("version") != "0.25.10" or runtime.get("state", {}).get("revision") != "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406":
    errors.append("Tree-sitter runtime must resolve exactly to 0.25.10 / da6fe9beb4f7f67beb75914ca8e0d48ae48d6406")

neon = resolved_pins.get("neon", {})
if '.package(url: "https://github.com/ChimeHQ/Neon.git", revision: "07a325403534f4759c814aff0a58ac69144a524c")' not in manifest_text:
    errors.append("Package.swift must retain the unreleased SwiftTreeSitter-0.10-compatible Neon revision; released Neon is older/incompatible")
if neon.get("state", {}) != {"revision": "07a325403534f4759c814aff0a58ac69144a524c"}:
    errors.append("Neon must remain an exact revision exception without a version or branch")

support = targets.get("TreeSitterScannerSupport")
if support is None:
    errors.append("TreeSitterScannerSupport target missing")
else:
    if support.get("path") != "Sources/TreeSitterScannerSupport":
        errors.append("TreeSitterScannerSupport target path drifted")
    if sorted(support.get("sources", [])) != ["src/javascript/scanner.c", "src/python/scanner.c"]:
        errors.append("TreeSitterScannerSupport sources must remain exactly JavaScript/Python scanner.c")
core_by_name_dependencies = [
    dependency["byName"][0]
    for dependency in repo_prompt_code_map_core_dependencies
    if dependency.get("byName")
]
if core_by_name_dependencies.count("TreeSitterScannerSupport") != 1:
    errors.append("RepoPromptCodeMapCore must directly depend exactly once on TreeSitterScannerSupport")
if app_by_name_dependencies.count("TreeSitterScannerSupport") != 0:
    errors.append("RepoPromptApp must not directly depend on TreeSitterScannerSupport")
if app_by_name_dependencies.count("RepoPromptCodeMapCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptCodeMapCore")

code_map_core_tests = targets.get("RepoPromptCodeMapCoreTests", {})
core_test_dependencies = [
    dependency["byName"][0]
    for dependency in code_map_core_tests.get("dependencies", [])
    if dependency.get("byName")
]
if code_map_core_tests.get("path") != "Tests/RepoPromptCodeMapCoreTests":
    errors.append("RepoPromptCodeMapCoreTests target path drifted")
if core_test_dependencies != ["RepoPromptCodeMapCore"]:
    errors.append("RepoPromptCodeMapCoreTests must depend only on RepoPromptCodeMapCore")

syntax_source = Path("Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift").read_text()
core_syntax_source = Path("Sources/RepoPromptCodeMapCore/CodeMapSyntaxEngine.swift").read_text()
if "import SwiftTreeSitter\n" not in syntax_source:
    errors.append("SyntaxManager must retain direct SwiftTreeSitter import for highlighting")
required_core_imports = {
    "SwiftTreeSitter", "TreeSitterC", "TreeSitterCPP", "TreeSitterCSharp", "TreeSitterDart",
    "TreeSitterGo", "TreeSitterJava", "TreeSitterJavaScript", "TreeSitterPHP", "TreeSitterPython",
    "TreeSitterRuby", "TreeSitterRust", "TreeSitterSwift", "TreeSitterTSX", "TreeSitterTypeScript",
}
for module in sorted(required_core_imports):
    if f"import {module}\n" not in core_syntax_source:
        errors.append(f"CodeMapSyntaxEngine missing direct grammar/wrapper module import: {module}")
bridging_header = Path("Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h").read_text()
if "tree_sitter_" in bridging_header or "TSLanguage" in bridging_header:
    errors.append("bridging header must not redeclare Tree-sitter grammar APIs")

if errors:
    raise SystemExit("\n".join(errors))
PY
)"; then
  fail "Tree-sitter dependency, product, or scanner-support contract drifted"
  printf '%s\n' "$tree_sitter_dependency_manifest_output" >&2
fi

retired_tree_sitter_grammar_dirs=(
  "Sources/RepoPromptTreeSitterCGrammar"
  "Sources/RepoPromptTreeSitterCSharpGrammar"
  "Sources/RepoPromptTreeSitterCPPGrammar"
  "Sources/RepoPromptTreeSitterDartGrammar"
  "Sources/RepoPromptTreeSitterGoGrammar"
  "Sources/RepoPromptTreeSitterJavaGrammar"
  "Sources/RepoPromptTreeSitterJavaScriptGrammar"
  "Sources/RepoPromptTreeSitterPHPGrammar"
  "Sources/RepoPromptTreeSitterPythonGrammar"
  "Sources/RepoPromptTreeSitterRubyGrammar"
  "Sources/RepoPromptTreeSitterRustGrammar"
  "Sources/RepoPromptTreeSitterSwiftGrammar"
  "Sources/RepoPromptTreeSitterTypeScriptGrammar"
)
for dir in "${retired_tree_sitter_grammar_dirs[@]}"; do
  if [[ -e "$dir" ]]; then
    fail "retired local Tree-sitter grammar directory exists: $dir"
  fi
done

# RepoPromptWorkspaceCore is a Foundation-only path-policy boundary.
workspace_core_source_dir="Sources/RepoPromptWorkspaceCore"
if [[ -d "$workspace_core_source_dir" ]]; then
  unexpected_workspace_core_files="$(find "$workspace_core_source_dir" -type f ! -name '*.swift' -print)"
  if [[ -n "$unexpected_workspace_core_files" ]]; then
    fail "RepoPromptWorkspaceCore contains non-Swift source files"
    printf '%s\n' "$unexpected_workspace_core_files" >&2
  fi

  if ! workspace_core_imports="$(xcrun swiftc -frontend -emit-imported-modules "$workspace_core_source_dir"/*.swift 2>&1 | sort -u)"; then
    fail "Swift compiler could not inspect RepoPromptWorkspaceCore imports"
    printf '%s\n' "$workspace_core_imports" >&2
  elif [[ "$workspace_core_imports" != "Foundation" ]]; then
    fail "RepoPromptWorkspaceCore compiler import allowlist is Foundation only"
    printf '%s\n' "$workspace_core_imports" >&2
  fi
fi

# 1. Old top-level layer buckets should not receive files again.
old_buckets=(
  "Sources/RepoPrompt/ViewModels"
  "Sources/RepoPrompt/Views"
  "Sources/RepoPrompt/Services"
  "Sources/RepoPrompt/Models"
  "Sources/RepoPrompt/Notifications"
  "Sources/RepoPrompt/Utils"
  "Sources/RepoPrompt/Shared"
  "Sources/RepoPrompt/Features/SynthaxParsing"
  "Sources/RepoPrompt/Features/Benchmark"
)
for bucket in "${old_buckets[@]}"; do
  if [[ -d "$bucket" ]]; then
    matches="$(find "$bucket" -type f -print)"
    if [[ -n "$matches" ]]; then
      fail "legacy bucket contains files: $bucket"
      printf '%s\n' "$matches" >&2
    fi
  fi
done

# 2. Test-only directories must stay out of the app source target.
print_matches \
  "Tests/TestSupport/Fixtures directory found under Sources/RepoPrompt" \
  find Sources/RepoPrompt -type d \( -name Tests -o -name TestSupport -o -name Fixtures \) -print

# 3. MCPControlMessages.swift has exactly one source of truth.
mcp_control_files=()
while IFS= read -r file; do
  mcp_control_files+=("$file")
done < <(find Sources -name MCPControlMessages.swift -type f -print | sort)
if [[ "${#mcp_control_files[@]}" -ne 1 || "${mcp_control_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPControlMessages.swift" ]]; then
  fail "MCPControlMessages.swift must exist only at Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  printf '%s\n' "${mcp_control_files[@]}" >&2
fi

# 3a. MCP filesystem and event wire identity also have one shared source of truth.
mcp_identity_files=()
while IFS= read -r file; do
  mcp_identity_files+=("$file")
done < <(find Sources -name MCPFilesystemIdentity.swift -type f -print | sort)
if [[ "${#mcp_identity_files[@]}" -ne 1 || "${mcp_identity_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift" ]]; then
  fail "MCPFilesystemIdentity.swift must exist only under RepoPromptShared"
  printf '%s\n' "${mcp_identity_files[@]}" >&2
fi

mcp_event_declarations="$(grep -R -l -E '^(public )?struct MCPExternalClientEvent' Sources --include='*.swift' | sort || true)"
if [[ "$mcp_event_declarations" != "Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift" ]]; then
  fail "MCPExternalClientEvent wire DTO must be declared only under RepoPromptShared"
  printf '%s\n' "$mcp_event_declarations" >&2
fi

# 4. Parser fixtures and sample parser inputs must not live in app source.
print_matches \
  "parser fixture/test directory found under app syntax parsing source" \
  find Sources/RepoPrompt/Infrastructure/SyntaxParsing -type d \( -iname '*fixture*' -o -iname '*test*' \) -print
print_matches \
  "parser fixture-like sample input found under app syntax parsing source" \
  find Sources/RepoPrompt/Infrastructure/SyntaxParsing -type f \( \
    -iname '*fixture*' -o -iname '*test*' -o \
    -name '*.dart' -o -name '*.go' -o -name '*.java' -o -name '*.js' -o -name '*.jsx' -o \
    -name '*.py' -o -name '*.rb' -o -name '*.rs' -o -name '*.ts' -o -name '*.tsx' -o \
    -name '*.php' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
  \) -print

# 5. Agent/MCP runtime paths must stay off WorkspaceFiles UI view-model dependencies.
# UI views may still depend on WorkspaceFilesViewModel/FileViewModel/FolderViewModel until
# the later UI-adapter simplification items, but runtime code must use WorkspaceContext values.
print_matches \
  "Agent/MCP runtime source references WorkspaceFilesViewModel/FileViewModel/FolderViewModel" \
  grep -R -n -E 'WorkspaceFilesViewModel|FileViewModel|FolderViewModel' \
    Sources/RepoPrompt/Features/AgentMode/ViewModels \
    Sources/RepoPrompt/Features/ContextBuilder/ViewModels \
    Sources/RepoPrompt/Infrastructure/MCP

# 6. Removed native tree visualization, IDE-mode tree search, and eager root materialization
# seams must not return. Keep unique deleted symbols global, but scope generic names to
# their former owners.
removed_artifact_paths=(
  "Sources/RepoPrompt/Features/AgentMode/Views/AgentFileTreeBottomPanelView.swift"
  "Sources/RepoPrompt/Features/WorkspaceFiles/Views/FileTree/NativeFileTree"
  "Sources/RepoPrompt/Features/Search/ViewModels/SearchFileTreeViewModel.swift"
)
for path in "${removed_artifact_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed native-tree/search artifact path exists: $path"
  fi
done

print_matches \
  "removed native-tree/workspace-loading/search seam referenced in Sources" \
  grep -R -n -E 'AgentFileTreeBottomPanelView|FileTreeViewWrapper|FileTreeViewController|NativeFileTree|SearchFileTreeViewModel|RootDescendantMaterialization|legacyMaterializedRootKeys|legacyMaterializeDescendantsRecursively|legacyEager' \
    Sources/RepoPrompt
print_matches \
  "WindowState references removed searchViewModel wiring" \
  grep -n -E 'searchViewModel' Sources/RepoPrompt/App/WindowState.swift
print_matches \
  "WorkspaceFilesViewModel references removed recursive eager loading seam" \
  grep -n -E 'loadContentsRecursively' Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift

# 7. Removed IDE-era Prompt selected-files panel and Prompt-owned preset bottom bar
# artifacts must not return. The live compact selected-files surface is
# SelectedFilesGrid/FilePreviewPopover, and Settings owns its chat preset picker.
removed_prompt_cleanup_paths=(
  "Sources/RepoPrompt/Features/Prompt/Views/Components/PresetBottomBar.swift"
  "Sources/RepoPrompt/Features/Prompt/Views/Components/SelectedFileView.swift"
  "Sources/RepoPrompt/Features/Prompt/ViewModels/Selection/SelectedFilesPanelViewModel.swift"
)
for path in "${removed_prompt_cleanup_paths[@]}"; do
  if [[ -e "$path" ]]; then
    fail "removed Prompt UI cleanup artifact path exists: $path"
  fi
done

print_matches \
  "removed Prompt selected-files/preset-bottom-bar symbol referenced in Sources" \
  grep -R -n -E 'PresetBottomBar|SelectedFilesContentView|SelectedFilesPanelViewModel|PresetTwoPanePopover_Copy|CopyPresetPreviewView|PresetTwoPanePopover_Chat' \
    Sources/RepoPrompt

# 8. Agent-authored reports and working notes stay local unless explicitly
# promoted into the contributor-facing documentation set.
allowed_tracked_docs=(
  "docs/architecture/provider-plugins.md"
  "docs/architecture/settings-persistence.md"
  "docs/architecture/source-layout.md"
  "docs/architecture/xcode-workspace.md"
  "docs/designs/cross-restart-durability-root-search-cas-2026-06-25.md"
  "docs/mcp-progress.md"
  "docs/migrations/swift-6-2-concurrency-migration-2026-07-18.md"
  "docs/migrations/swift-6-2-concurrency/migration-ledger.md"
  "docs/open-source-readiness.md"
  "docs/privacy/telemetry.md"
  "docs/releasing.md"
  "docs/testing.md"
  "docs/spec/history-query-tools.md"
  "docs/worktrees.md"
  "docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md"
  "docs/investigations/test-coverage-value-audit-ledger-2026-05-29.md"
  "docs/plans/test-coverage-value-audit-2026-05-29.md"
)
while IFS= read -r path; do
  allowed_tracked_docs+=("$path")
done < <(git ls-files 'docs/test-suite-optimizer')
unexpected_tracked_docs="$(comm -23 \
  <(git ls-files docs | sort) \
  <(printf '%s\n' "${allowed_tracked_docs[@]}" | sort))"
if [[ -n "$unexpected_tracked_docs" ]]; then
  fail "unexpected tracked docs found; keep agent-authored working documents local or add durable docs to the explicit allowlist"
  printf '%s\n' "$unexpected_tracked_docs" >&2
fi

if [[ "$failures" -ne 0 ]]; then
  printf 'Source layout guardrails failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
  exit 1
fi

printf 'OK: source layout guardrails passed.\n'
