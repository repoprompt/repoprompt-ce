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
  "Sources/RepoPromptCore"
  "Sources/RepoPromptCoreMacOS"
  "Sources/RepoPromptPOSIXSupport/Descriptors"
  "Sources/RepoPromptHeadless"
  "Sources/RepoPromptSyntaxCBridge/include"
  "Sources/RepoPromptShared/MCP"
  "Tests/RepoPromptTests"
)
for dir in "${required_dirs[@]}"; do
  if [[ ! -d "$dir" ]]; then
    fail "required source layout directory missing: $dir"
  fi
done

if [[ ! -f "Sources/RepoPromptShared/MCP/MCPControlMessages.swift" ]]; then
  fail "required shared MCP control message file missing"
fi
if [[ ! -f "Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift" ]]; then
  fail "required shared MCP bootstrap message file missing"
fi
if [[ ! -f "Sources/RepoPromptShared/MCP/MCPBootstrapEndpoint.swift" ]]; then
  fail "required shared MCP bootstrap endpoint file missing"
fi
if [[ ! -f "Sources/RepoPromptPOSIXSupport/Descriptors/POSIXDescriptorSupport.swift" ]]; then
  fail "required package-internal POSIX descriptor support file missing"
fi

if [[ ! -f "docs/architecture/headless-core.md" ]]; then
  fail "required headless-core architecture lock document missing"
fi

syntax_bridge_files=(
  "Sources/RepoPromptSyntaxCBridge/include/RepoPromptSyntaxCBridge.h"
  "Sources/RepoPromptSyntaxCBridge/RepoPromptSyntaxCBridge.c"
)
for file in "${syntax_bridge_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required narrow syntax-bridge file missing: $file"
  fi
done
if [[ -d "Sources/RepoPromptSyntaxCBridge" ]]; then
  unexpected_syntax_bridge_files="$(find Sources/RepoPromptSyntaxCBridge -type f \
    ! -path 'Sources/RepoPromptSyntaxCBridge/include/RepoPromptSyntaxCBridge.h' \
    ! -path 'Sources/RepoPromptSyntaxCBridge/RepoPromptSyntaxCBridge.c' \
    -print)"
  if [[ -n "$unexpected_syntax_bridge_files" ]]; then
    fail "unexpected file found under narrow RepoPromptSyntaxCBridge target"
    printf '%s\n' "$unexpected_syntax_bridge_files" >&2
  fi
fi
if [[ -e "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h" ]]; then
  fail "retired app target-wide bridging header still exists"
fi
if grep -n -E -- '-import-objc-header|-disable-bridging-pch' Package.swift >/dev/null 2>&1; then
  fail "Package.swift still contains retired app target-wide bridging-header flags"
fi
if ! grep -n -E -- '\.executable\(name: "repoprompt-headless", targets: \["RepoPromptHeadless"\]\)' Package.swift >/dev/null 2>&1; then
  fail "Package.swift must declare the standalone repoprompt-headless executable product"
fi
if ! grep -n -E -- 'name: "RepoPromptHeadless"' Package.swift >/dev/null 2>&1; then
  fail "Package.swift must declare the RepoPromptHeadless executable target"
fi
if [[ -d "Sources/RepoPromptHeadless" ]]; then
  headless_swift_files=()
  while IFS= read -r file; do
    headless_swift_files+=("$file")
  done < <(find Sources/RepoPromptHeadless -type f -name '*.swift' -print | sort)
  if [[ "${#headless_swift_files[@]}" -eq 0 ]]; then
    fail "Sources/RepoPromptHeadless must contain Swift source files"
  else
    print_matches \
      "standalone headless host references app UI, app bundle policy, or app-proxy socket behavior" \
      grep -n -E '^[[:space:]]*(@[[:alnum:]_]+[[:space:]]+)*import([[:space:]]+(class|struct|enum|protocol|func|var|let|typealias))?[[:space:]]+(AppKit|SwiftUI|Cocoa|Sparkle|KeyboardShortcuts)([.]|[[:space:]]|$)|Bundle[.]main|RepoPrompt[.]app|BootstrapSocketProxy|MCPFilesystemConstants[.]bootstrapSocketURL|MCPBootstrapEndpoint[.]bootstrapSocketURL|NSApplication|MCPBackgroundModeCoordinator|UserDefaults[.]standard' \
      "${headless_swift_files[@]}"
  fi
fi

# Item 5 physically moved these files into narrow package owners. Fail if a legacy
# app-target copy or a duplicate compatibility copy reappears anywhere under Sources.
assert_single_source_file() {
  local filename="$1"
  local expected_path="$2"
  local matches=()
  while IFS= read -r file; do
    matches+=("$file")
  done < <(find Sources -name "$filename" -type f -print | sort)
  if [[ "${#matches[@]}" -ne 1 || "${matches[0]:-}" != "$expected_path" ]]; then
    fail "$filename must exist only at $expected_path"
    printf '%s\n' "${matches[@]}" >&2
  fi
}

assert_single_source_file "FileSystemWatching.swift" "Sources/RepoPromptCore/Platform/FileSystemWatching.swift"
assert_single_source_file "ProcessLaunching.swift" "Sources/RepoPromptCore/Platform/ProcessLaunching.swift"
assert_single_source_file "POSIXDescriptorSupport.swift" "Sources/RepoPromptPOSIXSupport/Descriptors/POSIXDescriptorSupport.swift"
assert_single_source_file "RepoPromptCorePlatformDependencies.swift" "Sources/RepoPromptCore/Platform/RepoPromptCorePlatformDependencies.swift"
assert_single_source_file "SecureKeyValueStorageBackend.swift" "Sources/RepoPromptCore/Platform/SecureKeyValueStorageBackend.swift"
assert_single_source_file "BundledHelperPeerVerifying.swift" "Sources/RepoPromptCore/MCP/Platform/BundledHelperPeerVerifying.swift"
assert_single_source_file "MCPAppProxyTransportBoundary.swift" "Sources/RepoPromptCore/MCP/Platform/MCPAppProxyTransportBoundary.swift"
assert_single_source_file "ProcessAncestryInspecting.swift" "Sources/RepoPromptCore/MCP/Platform/ProcessAncestryInspecting.swift"
assert_single_source_file "WorkspaceAccessPolicy.swift" "Sources/RepoPromptCore/Workspaces/WorkspaceAccessPolicy.swift"
assert_single_source_file "WorkspaceRootActions.swift" "Sources/RepoPromptCore/Workspaces/WorkspaceRootActions.swift"
assert_single_source_file "EphemeralSecureKeyValueStore.swift" "Sources/RepoPromptCore/Security/EphemeralSecureKeyValueStore.swift"
assert_single_source_file "SecureKeyService.swift" "Sources/RepoPromptCore/Security/SecureKeyService.swift"
assert_single_source_file "MacOSFSEventsWatcher.swift" "Sources/RepoPromptCoreMacOS/FileSystem/MacOSFSEventsWatcher.swift"
assert_single_source_file "POSIXProcessLauncher.swift" "Sources/RepoPromptCoreMacOS/Process/POSIXProcessLauncher.swift"
assert_single_source_file "FDWriteSupport.swift" "Sources/RepoPromptCoreMacOS/Process/FDWriteSupport.swift"
assert_single_source_file "KeychainService.swift" "Sources/RepoPromptCoreMacOS/Security/KeychainService.swift"
assert_single_source_file "RuntimeCodeSigningDetector.swift" "Sources/RepoPromptCoreMacOS/Security/RuntimeCodeSigningDetector.swift"
assert_single_source_file "MacOSBundledHelperPeerVerifier.swift" "Sources/RepoPromptCoreMacOS/MCP/PeerVerification/MacOSBundledHelperPeerVerifier.swift"
assert_single_source_file "MacOSProcessAncestryInspector.swift" "Sources/RepoPromptCoreMacOS/MCP/PeerVerification/MacOSProcessAncestryInspector.swift"

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

if ! syntax_bridge_header_output="$(python3 <<'PY'
import re
from pathlib import Path

expected = [
    "tree_sitter_javascript",
    "tree_sitter_python",
    "tree_sitter_c_sharp",
    "tree_sitter_swift",
    "tree_sitter_c",
    "tree_sitter_cpp",
    "tree_sitter_rust",
    "tree_sitter_go",
    "tree_sitter_java",
    "tree_sitter_dart",
    "tree_sitter_php",
    "tree_sitter_ruby",
    "tree_sitter_typescript",
    "tree_sitter_tsx",
]
text = Path("Sources/RepoPromptSyntaxCBridge/include/RepoPromptSyntaxCBridge.h").read_text()
pattern = re.compile(r"^const TSLanguage \* (tree_sitter_[a-z_]+)\(void\);$", re.MULTILINE)
declarations = pattern.findall(text)
unexpected_semicolon_lines = [
    line for line in text.splitlines()
    if line.strip().endswith(";")
    and line.strip() != "typedef struct TSLanguage TSLanguage;"
    and pattern.fullmatch(line) is None
]
if declarations != expected or unexpected_semicolon_lines:
    raise SystemExit(
        "RepoPromptSyntaxCBridge header must contain exactly the curated fourteen declarations"
        f"\nfound declarations: {declarations}"
        f"\nunexpected declaration lines: {unexpected_semicolon_lines}"
    )
PY
)"; then
  fail "RepoPromptSyntaxCBridge declaration shim drifted"
  printf '%s\n' "$syntax_bridge_header_output" >&2
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
    "tree-sitter-typescript": ("https://github.com/tree-sitter/tree-sitter-typescript", "75b3874edb2dc714fb1fd77a32013d0f8699989f", "TreeSitterTypeScript"),
    "tree-sitter-ruby": ("https://github.com/tree-sitter/tree-sitter-ruby", "7a010836b74351855148818d5cb8170dc4df8e6a", "TreeSitterRuby"),
    "tree-sitter-swift": ("https://github.com/alex-pinkus/tree-sitter-swift", "9253825dd2570430b53fa128cbb40cb62498e75d", "TreeSitterSwift"),
    "tree-sitter-c-sharp": ("https://github.com/tree-sitter/tree-sitter-c-sharp.git", "b27b091bfdc5f16d0ef76421ea5609c82a57dff0", "TreeSitterCSharp"),
    "tree-sitter-cpp": ("https://github.com/tree-sitter/tree-sitter-cpp", "e5cea0ec884c5c3d2d1e41a741a66ce13da4d945", "TreeSitterCPP"),
    "tree-sitter-php": ("https://github.com/provencher/tree-sitter-php", "0a99deca13c4af1fb9adcb03c958bfc9f4c740a9", "TreeSitterPHP"),
}
errors = []
manifest_text = Path("Package.swift").read_text()
resolved = json.loads(Path("Package.resolved").read_text())
resolved_pins = {pin["identity"]: pin for pin in resolved["pins"]}
package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
targets = {target["name"]: target for target in package["targets"]}
repo_prompt = targets.get("RepoPrompt", {})
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
repo_prompt_mcp = targets.get("RepoPromptMCP", {})
repo_prompt_mcp_dependencies = repo_prompt_mcp.get("dependencies", [])
core = targets.get("RepoPromptCore", {})
core_dependencies = core.get("dependencies", [])
macos = targets.get("RepoPromptCoreMacOS", {})
macos_dependencies = macos.get("dependencies", [])
syntax_bridge = targets.get("RepoPromptSyntaxCBridge", {})
syntax_bridge_dependencies = syntax_bridge.get("dependencies", [])
syntax_bridge_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in syntax_bridge_dependencies
    if "product" in dependency
}
repo_prompt_products = {
    (dependency["product"][0], dependency["product"][1])
    for dependency in repo_prompt_dependencies
    if "product" in dependency
}
expected_syntax_bridge_products = {
    (product, identity)
    for identity, (_, _, product) in expected_packages.items()
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
    if (product, identity) not in syntax_bridge_products:
        errors.append(f"RepoPromptSyntaxCBridge missing upstream grammar product dependency: {product} ({identity})")

if syntax_bridge_products != expected_syntax_bridge_products:
    errors.append("RepoPromptSyntaxCBridge grammar product dependencies must remain exactly the curated set")
unexpected_repo_prompt_grammar_products = sorted(repo_prompt_products & expected_syntax_bridge_products)
if unexpected_repo_prompt_grammar_products:
    errors.append(f"RepoPrompt must not directly depend on Tree-sitter grammar products: {unexpected_repo_prompt_grammar_products}")

support = targets.get("TreeSitterScannerSupport")
if support is None:
    errors.append("TreeSitterScannerSupport target missing")
else:
    if support.get("path") != "Sources/TreeSitterScannerSupport":
        errors.append("TreeSitterScannerSupport target path drifted")
    expected_sources = ["src/javascript/scanner.c", "src/python/scanner.c"]
    if sorted(support.get("sources", [])) != expected_sources:
        errors.append("TreeSitterScannerSupport sources must remain exactly JavaScript/Python scanner.c")
def has_by_name(dependencies, name):
    return any(dependency.get("byName", [None])[0] == name for dependency in dependencies)

if syntax_bridge.get("path") != "Sources/RepoPromptSyntaxCBridge":
    errors.append("RepoPromptSyntaxCBridge target path drifted")
syntax_bridge_by_name_dependencies = sorted(
    dependency["byName"][0]
    for dependency in syntax_bridge_dependencies
    if "byName" in dependency
)
if syntax_bridge_by_name_dependencies != ["TreeSitterScannerSupport"]:
    errors.append("RepoPromptSyntaxCBridge must directly depend only on TreeSitterScannerSupport plus the curated grammar products")
if has_by_name(repo_prompt_dependencies, "TreeSitterScannerSupport"):
    errors.append("RepoPrompt must not directly depend on TreeSitterScannerSupport")
unexpected_core_native_dependencies = sorted(
    dependency["byName"][0]
    for dependency in core_dependencies
    if "byName" in dependency
    and dependency["byName"][0] in {"RepoPromptShared", "RepoPromptPOSIXSupport", "RepoPromptC", "CSwiftPCRE2", "RepoPromptSyntaxCBridge"}
)
if unexpected_core_native_dependencies:
    errors.append(f"RepoPromptCore has premature dependency edges: {unexpected_core_native_dependencies}")
if not has_by_name(repo_prompt_dependencies, "RepoPromptCore") or not has_by_name(repo_prompt_dependencies, "RepoPromptCoreMacOS"):
    errors.append("RepoPrompt must directly depend on RepoPromptCore and RepoPromptCoreMacOS")
if not has_by_name(repo_prompt_dependencies, "RepoPromptSyntaxCBridge"):
    errors.append("RepoPrompt must directly depend on RepoPromptSyntaxCBridge while SyntaxManager remains app-owned")
if not has_by_name(repo_prompt_dependencies, "RepoPromptC") or not has_by_name(repo_prompt_dependencies, "CSwiftPCRE2"):
    errors.append("RepoPrompt must retain direct native dependencies while current app sources import them")
if not has_by_name(repo_prompt_dependencies, "RepoPromptPOSIXSupport"):
    errors.append("RepoPrompt must directly depend on RepoPromptPOSIXSupport while app socket sources import it")
if not has_by_name(repo_prompt_mcp_dependencies, "RepoPromptPOSIXSupport"):
    errors.append("RepoPromptMCP must directly depend on RepoPromptPOSIXSupport")
if not has_by_name(macos_dependencies, "RepoPromptCore"):
    errors.append("RepoPromptCoreMacOS must directly depend on RepoPromptCore")
if not has_by_name(macos_dependencies, "RepoPromptPOSIXSupport"):
    errors.append("RepoPromptCoreMacOS must directly depend on RepoPromptPOSIXSupport")
if has_by_name(macos_dependencies, "RepoPromptShared"):
    errors.append("RepoPromptCoreMacOS must not depend on RepoPromptShared")

product_names = [product["name"] for product in package["products"]]
if product_names != ["RepoPrompt", "repoprompt-mcp", "repoprompt-headless"]:
    errors.append(f"SwiftPM products must expose exactly the three executables, found: {product_names}")

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

# 3b. MCPBootstrapMessages.swift has exactly one source of truth.
mcp_bootstrap_message_files=()
while IFS= read -r file; do
  mcp_bootstrap_message_files+=("$file")
done < <(find Sources -name MCPBootstrapMessages.swift -type f -print | sort)
if [[ "${#mcp_bootstrap_message_files[@]}" -ne 1 || "${mcp_bootstrap_message_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift" ]]; then
  fail "MCPBootstrapMessages.swift must exist only at Sources/RepoPromptShared/MCP/MCPBootstrapMessages.swift"
  printf '%s\n' "${mcp_bootstrap_message_files[@]}" >&2
fi

# 3c. MCPBootstrapEndpoint.swift has exactly one source of truth.
mcp_bootstrap_endpoint_files=()
while IFS= read -r file; do
  mcp_bootstrap_endpoint_files+=("$file")
done < <(find Sources -name MCPBootstrapEndpoint.swift -type f -print | sort)
if [[ "${#mcp_bootstrap_endpoint_files[@]}" -ne 1 || "${mcp_bootstrap_endpoint_files[0]:-}" != "Sources/RepoPromptShared/MCP/MCPBootstrapEndpoint.swift" ]]; then
  fail "MCPBootstrapEndpoint.swift must exist only at Sources/RepoPromptShared/MCP/MCPBootstrapEndpoint.swift"
  printf '%s\n' "${mcp_bootstrap_endpoint_files[@]}" >&2
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
  "docs/architecture/headless-core.md"
  "docs/architecture/provider-plugins.md"
  "docs/architecture/source-layout.md"
  "docs/characterization/shared-runtime-phase0-2026-06-05.md"
  "docs/characterization/shared-runtime-phase1-2026-06-05.md"
  "docs/characterization/shared-runtime-phase2-slice1-2026-06-05.md"
  "docs/open-source-readiness.md"
  "docs/releasing.md"
  "docs/worktrees.md"
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
