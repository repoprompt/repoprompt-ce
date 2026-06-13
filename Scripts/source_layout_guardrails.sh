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
  "Sources/RepoPrompt/Features"
  "Sources/RepoPrompt/Infrastructure"
  "Sources/RepoPrompt/Infrastructure/SyntaxParsing"
  "Sources/RepoPromptShared/MCP"
  "Tests/RepoPromptTests"
)
for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    fail "required source layout directory missing: $dir"
  fi
done

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
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
repo_prompt_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_dependencies
    if "product" in dependency
}

for identity, (url, revision, product) in expected_packages.items():
    manifest_pin = f'.package(url: "{url}", revision: "{revision}")'
    if manifest_pin not in manifest_text:
        errors.append(f"Package.swift missing exact pin: {identity} {revision}")
    pin = resolved_pins.get(identity)
    if pin is None:
        errors.append(f"Package.resolved missing pin: {identity}")
    elif pin.get("location") != url or pin.get("state", {}).get("revision") != revision:
        errors.append(f"Package.resolved pin drift: {identity}")
    if (product, identity) not in repo_prompt_products:
        errors.append(f"RepoPrompt missing upstream grammar product dependency: {product} ({identity})")

support = targets.get("TreeSitterScannerSupport")
if support is None:
    errors.append("TreeSitterScannerSupport target missing")
else:
    if support.get("path") != "Sources/TreeSitterScannerSupport":
        errors.append("TreeSitterScannerSupport target path drifted")
    expected_sources = ["src/javascript/scanner.c", "src/python/scanner.c"]
    if sorted(support.get("sources", [])) != expected_sources:
        errors.append("TreeSitterScannerSupport sources must remain exactly JavaScript/Python scanner.c")
if not any(dependency.get("byName", [None])[0] == "TreeSitterScannerSupport" for dependency in repo_prompt_dependencies):
    errors.append("RepoPrompt must directly depend on TreeSitterScannerSupport")

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
  "docs/architecture/source-layout.md"
  "docs/open-source-readiness.md"
  "docs/releasing.md"
  "docs/worktrees.md"
  "docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md"
  "docs/investigations/test-coverage-value-audit-ledger-2026-05-29.md"
  "docs/plans/test-coverage-value-audit-2026-05-29.md"
)
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
