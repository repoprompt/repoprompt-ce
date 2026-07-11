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

# Exact-snapshot Tree-sitter scanner support must remain narrow and reproducible.
# Remove this block together with the support target only after validated upstream
# JavaScript/Python revisions compile their scanner objects in a clean root graph.
if [[ -e "src/scanner.c" ]]; then
  fail "retired root src/scanner.c manifest-probe sentinel exists; use the tracked TreeSitterScannerSupport target instead"
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

if [[ -f "ThirdPartyLicenses/tree-sitter/scanner-support.sha256" ]]; then
  if ! tree_sitter_scanner_support_checksum_output="$(shasum -a 256 -c ThirdPartyLicenses/tree-sitter/scanner-support.sha256 2>&1)"; then
    fail "TreeSitterScannerSupport compatibility snapshots differ from curated checksums"
    printf '%s\n' "$tree_sitter_scanner_support_checksum_output" >&2
  fi
fi

if ! tree_sitter_scanner_support_manifest_output="$(python3 <<'PY'
import json
import subprocess
from pathlib import Path

expected_packages = {
    "tree-sitter-c": ("https://github.com/tree-sitter/tree-sitter-c", "3efee11f784605d44623d7dadd6cd12a0f73ea92", "TreeSitterC"),
    "tree-sitter-dart": ("https://github.com/UserNobody14/tree-sitter-dart", "80e23c07b64494f7e21090bb3450223ef0b192f4", "TreeSitterDart"),
    "tree-sitter-go": ("https://github.com/tree-sitter/tree-sitter-go", "c350fa54d38af725c40d061a602ee3205ef1e072", "TreeSitterGo"),
    "tree-sitter-java": ("https://github.com/tree-sitter/tree-sitter-java", "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11", "TreeSitterJava"),
    "tree-sitter-javascript": ("https://github.com/tree-sitter/tree-sitter-javascript", "39798e26b6d4dbcee8e522b8db83f8b2df33a5ea", "TreeSitterJavaScript"),
    "tree-sitter-python": ("https://github.com/tree-sitter/tree-sitter-python", "c5fca1a186e8e528115196178c28eefa8d86b0b0", "TreeSitterPython"),
    "tree-sitter-rust": ("https://github.com/tree-sitter/tree-sitter-rust", "2eaf126458a4d6a69401089b6ba78c5e5d6c1ced", "TreeSitterRust"),
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

if repo_prompt.get("type") != "executable":
    errors.append("RepoPrompt target must remain executable")
if repo_prompt.get("path") != "Sources/RepoPromptExecutable":
    errors.append("RepoPrompt target must remain the thin Sources/RepoPromptExecutable entry target")
repo_prompt_by_name_dependencies = [
    dependency["byName"][0]
    for dependency in repo_prompt_dependencies
    if dependency.get("byName")
]
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
    if workspace_core.get("type") != "regular":
        errors.append("RepoPromptWorkspaceCore must remain an internal regular target")
    if workspace_core.get("path") != "Sources/RepoPromptWorkspaceCore":
        errors.append("RepoPromptWorkspaceCore target path drifted")
    if workspace_core.get("dependencies", []):
        errors.append("RepoPromptWorkspaceCore must not declare target or package dependencies")
    if workspace_core.get("settings", []):
        errors.append("RepoPromptWorkspaceCore must not declare compiler settings")

workspace_core_tests = targets.get("RepoPromptWorkspaceCoreTests")
if workspace_core_tests is None:
    errors.append("RepoPromptWorkspaceCoreTests target missing")
else:
    test_dependencies = [
        dependency["byName"][0]
        for dependency in workspace_core_tests.get("dependencies", [])
        if dependency.get("byName")
    ]
    if workspace_core_tests.get("type") != "test":
        errors.append("RepoPromptWorkspaceCoreTests must remain a test target")
    if workspace_core_tests.get("path") != "Tests/RepoPromptWorkspaceCoreTests":
        errors.append("RepoPromptWorkspaceCoreTests target path drifted")
    if test_dependencies != ["RepoPromptWorkspaceCore"] or len(workspace_core_tests.get("dependencies", [])) != 1:
        errors.append("RepoPromptWorkspaceCoreTests must depend only on RepoPromptWorkspaceCore")

app_by_name_dependencies = [
    dependency["byName"][0]
    for dependency in repo_prompt_app_dependencies
    if dependency.get("byName")
]
if app_by_name_dependencies.count("RepoPromptWorkspaceCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptWorkspaceCore")

for forbidden_consumer in ("RepoPrompt", "RepoPromptMCP", "RepoPromptShared", "RepoPromptTests"):
    dependencies = [
        dependency["byName"][0]
        for dependency in targets.get(forbidden_consumer, {}).get("dependencies", [])
        if dependency.get("byName")
    ]
    if "RepoPromptWorkspaceCore" in dependencies:
        errors.append(f"{forbidden_consumer} must not directly depend on RepoPromptWorkspaceCore")

for product in package.get("products", []):
    if "RepoPromptWorkspaceCore" in product.get("targets", []):
        errors.append("RepoPromptWorkspaceCore must not be exposed as a package product")

for identity, (url, revision, product) in expected_packages.items():
    manifest_pin = f'.package(url: "{url}", revision: "{revision}")'
    if manifest_pin not in manifest_text:
        errors.append(f"Package.swift missing exact pin: {identity} {revision}")
    pin = resolved_pins.get(identity)
    if pin is None:
        errors.append(f"Package.resolved missing pin: {identity}")
    elif pin.get("location") != url or pin.get("state", {}).get("revision") != revision:
        errors.append(f"Package.resolved pin drift: {identity}")
    if (product, identity) not in repo_prompt_app_products:
        errors.append(f"RepoPromptApp missing upstream grammar product dependency: {product} ({identity})")

support = targets.get("TreeSitterScannerSupport")
if support is None:
    errors.append("TreeSitterScannerSupport target missing")
else:
    if support.get("path") != "Sources/TreeSitterScannerSupport":
        errors.append("TreeSitterScannerSupport target path drifted")
    expected_sources = ["src/javascript/scanner.c", "src/python/scanner.c"]
    if sorted(support.get("sources", [])) != expected_sources:
        errors.append("TreeSitterScannerSupport sources must remain exactly JavaScript/Python scanner.c")
if not any(dependency.get("byName", [None])[0] == "TreeSitterScannerSupport" for dependency in repo_prompt_app_dependencies):
    errors.append("RepoPromptApp must directly depend on TreeSitterScannerSupport")

if errors:
    raise SystemExit("\n".join(errors))
PY
)"; then
  fail "TreeSitter grammar pin/product or scanner-support manifest contract drifted"
  printf '%s\n' "$tree_sitter_scanner_support_manifest_output" >&2
fi

retired_tree_sitter_grammar_dirs=(
  "Sources/RepoPromptTreeSitterCGrammar"
  "Sources/RepoPromptTreeSitterDartGrammar"
  "Sources/RepoPromptTreeSitterGoGrammar"
  "Sources/RepoPromptTreeSitterJavaGrammar"
  "Sources/RepoPromptTreeSitterJavaScriptGrammar"
  "Sources/RepoPromptTreeSitterPythonGrammar"
  "Sources/RepoPromptTreeSitterRustGrammar"
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
