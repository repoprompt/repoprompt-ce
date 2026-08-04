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
  "Sources/RepoPromptDomainRuntime"
  "Tests/RepoPromptTests"
  "Tests/RepoPromptWorkspaceCoreTests"
  "Tests/RepoPromptDomainRuntimeTests"
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
import re
import subprocess
from pathlib import Path

expected_packages = {
    "tree-sitter-c": ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", "b780e47fc780ddc8da13afa35a3f4ed5c157823d", "TreeSitterC"),
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

wrapper = resolved_pins.get("swift-tree-sitter", {})
wrapper_url = "https://github.com/repoprompt/swift-tree-sitter.git"
wrapper_revision = "a778ef4fb7f0d3ad00185f42ce83c688373c4361"
wrapper_manifest_pattern = re.compile(
    rf'\.package\(\s*url:\s*"{re.escape(wrapper_url)}",\s*revision:\s*"{wrapper_revision}"\s*\)'
)
if wrapper_manifest_pattern.search(manifest_text) is None:
    errors.append("Package.swift must use the unnamed URL/revision declaration for the approved RepoPrompt SwiftTreeSitter fork")
if wrapper.get("location") != wrapper_url or wrapper.get("state", {}) != {"revision": wrapper_revision}:
    errors.append("SwiftTreeSitter fork location/revision drifted")
if ("SwiftTreeSitter", "swift-tree-sitter") in repo_prompt_app_products:
    errors.append("RepoPromptApp must not directly depend on SwiftTreeSitter")
if ("SwiftTreeSitter", "swift-tree-sitter") not in repo_prompt_code_map_core_products:
    errors.append("RepoPromptCodeMapCore missing direct SwiftTreeSitter product dependency")
if "https://github.com/ChimeHQ/SwiftTreeSitter" in manifest_text or "swifttreesitter" in resolved_pins:
    errors.append("ChimeHQ SwiftTreeSitter must not coexist with the RepoPrompt fork")
if "https://github.com/ChimeHQ/Neon" in manifest_text or '.product(name: "Neon"' in manifest_text or "neon" in resolved_pins:
    errors.append("Neon package/product must remain removed")

runtime = resolved_pins.get("tree-sitter", {})
if runtime.get("location") != "https://github.com/tree-sitter/tree-sitter" or runtime.get("state", {}).get("version") != "0.25.10" or runtime.get("state", {}).get("revision") != "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406":
    errors.append("Tree-sitter runtime must resolve exactly to 0.25.10 / da6fe9beb4f7f67beb75914ca8e0d48ae48d6406")

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

# M1 headless domain runtime is an internal AppKit-free owner boundary. During the
# two-commit migration it may be staged in Swift 5 or promoted to Swift 6, but the
# runtime and owner tests must move together and retain complete checking.
domain_runtime = targets.get("RepoPromptDomainRuntime")
domain_runtime_tests = targets.get("RepoPromptDomainRuntimeTests")
if domain_runtime is None:
    errors.append("RepoPromptDomainRuntime target missing")
else:
    if domain_runtime.get("type") != "regular": errors.append("RepoPromptDomainRuntime must remain an internal regular target")
    if domain_runtime.get("path") != "Sources/RepoPromptDomainRuntime": errors.append("RepoPromptDomainRuntime target path drifted")
    runtime_by_name = [
        dependency["byName"][0]
        for dependency in domain_runtime.get("dependencies", [])
        if dependency.get("byName")
    ]
    runtime_products = {
        (dependency["product"][0], dependency["product"][1])
        for dependency in domain_runtime.get("dependencies", [])
        if "product" in dependency
    }
    if runtime_by_name != ["RepoPromptShared", "RepoPromptC", "RepoPromptCodeMapCore"] or runtime_products != {("Logging", "swift-log"), ("MCP", "swift-sdk")} or len(domain_runtime.get("dependencies", [])) != 5:
        errors.append("RepoPromptDomainRuntime dependencies must remain RepoPromptShared, RepoPromptC, RepoPromptCodeMapCore, Logging, and pinned MCP")
if domain_runtime_tests is None:
    errors.append("RepoPromptDomainRuntimeTests target missing")
else:
    owner_by_name = [dependency["byName"][0] for dependency in domain_runtime_tests.get("dependencies", []) if dependency.get("byName")]
    owner_products = {
        (dependency["product"][0], dependency["product"][1])
        for dependency in domain_runtime_tests.get("dependencies", [])
        if "product" in dependency
    }
    if domain_runtime_tests.get("type") != "test": errors.append("RepoPromptDomainRuntimeTests must remain a test target")
    if domain_runtime_tests.get("path") != "Tests/RepoPromptDomainRuntimeTests": errors.append("RepoPromptDomainRuntimeTests target path drifted")
    if owner_by_name != ["RepoPromptDomainRuntime"] or owner_products != {("MCP", "swift-sdk")} or len(domain_runtime_tests.get("dependencies", [])) != 2:
        errors.append("RepoPromptDomainRuntimeTests must depend only on RepoPromptDomainRuntime and MCP")

def swift_language_modes(target):
    return [
        setting.get("kind", {}).get("swiftLanguageMode", {}).get("_0")
        for setting in target.get("settings", [])
        if setting.get("kind", {}).get("swiftLanguageMode")
    ]

def strict_concurrency_features(target):
    return [
        setting.get("kind", {}).get("enableExperimentalFeature", {}).get("_0")
        for setting in target.get("settings", [])
        if setting.get("kind", {}).get("enableExperimentalFeature")
    ]

if domain_runtime is not None and domain_runtime_tests is not None:
    runtime_modes = swift_language_modes(domain_runtime)
    owner_modes = swift_language_modes(domain_runtime_tests)
    if runtime_modes != owner_modes:
        errors.append("RepoPromptDomainRuntime and owner tests must use the same Swift language mode")
    elif runtime_modes == ["5"]:
        if strict_concurrency_features(domain_runtime) != ["StrictConcurrency"] or strict_concurrency_features(domain_runtime_tests) != ["StrictConcurrency"]:
            errors.append("Swift 5 domain runtime and owner tests must retain complete StrictConcurrency checking")
    elif runtime_modes != ["6"]:
        errors.append("RepoPromptDomainRuntime and owner tests must be either Swift 5 + StrictConcurrency or Swift 6")
if app_by_name_dependencies.count("RepoPromptDomainRuntime") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptDomainRuntime")
repo_prompt_tests_dependencies = [dependency["byName"][0] for dependency in targets.get("RepoPromptTests", {}).get("dependencies", []) if dependency.get("byName")]
if repo_prompt_tests_dependencies.count("RepoPromptDomainRuntime") != 1:
    errors.append("RepoPromptTests must directly consume RepoPromptDomainRuntime for adapter evidence")

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

core_syntax_source = Path("Sources/RepoPromptCodeMapCore/CodeMapSyntaxEngine.swift").read_text()
required_core_imports = {
    "SwiftTreeSitter", "TreeSitterC", "TreeSitterCPP", "TreeSitterCSharp",
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

# RepoPromptDomainRuntime owns Sendable MCP catalog/runtime values, the M2
# workspace/context authorities, M3 shared reads, M4 protected mutation policy, and
# M5 long-running lifecycle wrappers. Physical app backends remain injected and the
# owner stays free of UI/provider implementations.
domain_runtime_source_dir="Sources/RepoPromptDomainRuntime"
if [[ -d "$domain_runtime_source_dir" ]]; then
  unexpected_domain_runtime_files="$(find "$domain_runtime_source_dir" -type f ! -name '*.swift' -print)"
  if [[ -n "$unexpected_domain_runtime_files" ]]; then
    fail "RepoPromptDomainRuntime contains non-Swift source files"
    printf '%s\n' "$unexpected_domain_runtime_files" >&2
  fi
  print_matches \
    "RepoPromptDomainRuntime imports an app/UI framework" \
    grep -R -n -E '^import[[:space:]]+(AppKit|SwiftUI|Combine)$' "$domain_runtime_source_dir"
  print_matches \
    "RepoPromptDomainRuntime declares MainActor ownership" \
    grep -R -n -E '@MainActor' "$domain_runtime_source_dir"
  domain_runtime_required_files=(
    "DomainPersistence.swift"
    "DomainWorkspaceModels.swift"
    "DomainWorkspaceCommand.swift"
    "DomainWorkspaceContextAuthority.swift"
    "DomainRoutingCoordinator.swift"
    "DomainRuntimeMetrics.swift"
    "DomainReadContext.swift"
    "DomainReadSideEffectCoordinator.swift"
    "MCPDomainReadToolDefinitions.swift"
    "MCPDomainReadToolProvider.swift"
    "DomainAgentSessionModels.swift"
    "DomainAgentRunSessionStore.swift"
    "DomainInteractionBroker.swift"
    "DomainCredentialEnvelope.swift"
    "DomainActivityCenter.swift"
    "MCPDomainLongRunningToolProvider.swift"
  )
  for file in "${domain_runtime_required_files[@]}"; do
    if [[ ! -f "$domain_runtime_source_dir/$file" ]]; then
      fail "RepoPromptDomainRuntime M2-M5 authority file missing: $file"
    fi
  done
  m5_contract_fixture="Scripts/Fixtures/headless_mcp_domain_runtime_m5_contract.json"
  if [[ ! -f "$m5_contract_fixture" ]]; then
    fail "M5 AI/Agent contract fixture missing: $m5_contract_fixture"
  elif ! python3 - "$m5_contract_fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
expected = {
    "oracle_utils", "ask_oracle", "oracle_send", "context_builder", "ask_user",
    "agent_explore", "agent_run", "agent_manage", "share_thoughts", "set_status",
    "wait_for_next_user_instruction",
}
assert value["schema_version"] == 2
assert value["milestone"] == "M5"
assert set(value["migrated_tools"]) == expected
assert value["session_lifecycle"]["false_transient_restoration_allowed"] is False
assert value["session_lifecycle"]["wait_admission_while_draining"] == "cancelled"
assert value["session_lifecycle"]["active_prior_owner_claim"] == "unavailable_until_prior_owner_durably_stops"
assert value["session_persistence"]["write_protocol"] == "advisory_lock_digest_cas_atomic_write"
assert value["session_persistence"]["duplicate_session_ids"] == "byte_preserved_degraded_read_only"
assert value["session_persistence"]["committed_base_advances_after_each_successful_cas"] is True
assert value["session_persistence"]["retained_record_limit"] == 512
assert value["interaction"]["default_timeout"] == "workspace questionTimeoutSeconds setting"
assert value["interaction"]["app_presentation_tombstone_limit"] == 256
assert value["interaction"]["connection_removal_late_waiter"] == "blocked_after_suspended_availability"
assert value["child_launch"]["real_private_endpoint"] == "deferred_to_M6B"
assert value["child_launch"]["codex_cached_runtime_behavior"] == "carrier_merged_only_at_final_process_spawn_boundary"
assert value["child_launch"]["end_to_end_private_connectivity_claimed"] is False
assert set(value["child_launch"]["launch_environment_consumers"]) == {"claude_native", "codex_app_server", "acp_agent"}
assert value["credentials"]["packaged_child_keychain_evidence"] == "unresolved_M0_procedure_record"
assert value["credentials"]["persisted_secret_bytes"] is False
assert value["credentials"]["actual_owned_bytes_instrumented"] is True
assert value["approval"]["routing_opt_out"] is False
assert value["authority"]["typed_policy_errors_preserved"] is True
assert value["public_contract"]["schema_behavior"] == "wrapped_binding_definition_preserved"
assert value["public_contract"]["proxy_behavior_changed"] is False
PY
  then
    fail "M5 AI/Agent contract fixture drifted or is invalid JSON"
  fi
  m3_read_tools=(
    "get_code_structure:getCodeStructure" "get_file_tree:getFileTree" "read_file:readFile" "file_search:search"
    "workspace_context:workspaceContext" "prompt:prompt" "oracle_chat_log:oracleChatLog" "git:git" "history:history"
  )
  for entry in "${m3_read_tools[@]}"; do
    tool="${entry%%:*}"
    identifier="${entry##*:}"
    if ! grep -q "MCPWindowToolName\.$identifier" "$domain_runtime_source_dir/MCPDomainReadToolDefinitions.swift"; then
      fail "M3 shared read definition missing: $tool"
    fi
  done
  if ! grep -q 'MCPDomainCanonicalToolDefinitions.definition(named:' "$domain_runtime_source_dir/MCPDomainReadToolDefinitions.swift"; then
    fail "M3 shared read definitions must delegate to the canonical 27-tool schema authority"
  fi
  print_matches \
    "RepoPromptDomainRuntime contains app/UI/provider implementation" \
    grep -R -n -E 'WindowState|ViewModel|AgentProvider|Claude[^[:space:]]*Provider|Codex[^[:space:]]*Provider|OpenCode[^[:space:]]*Provider|Cursor[^[:space:]]*Provider' "$domain_runtime_source_dir"
  print_matches \
    "RepoPromptDomainRuntime reintroduced random window incarnations" \
    grep -R -n -E 'windowGeneration.*random|UInt64\.random' "$domain_runtime_source_dir"

  m3_legacy_provider_files=(
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPOracleToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift"
    "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPHistoryToolProvider.swift"
  )
  m3_duplicate_schema_matches="$(grep -n -E 'name:[[:space:]]*(MCPWindowToolName\.(getCodeStructure|getFileTree|readFile|search|workspaceContext|prompt|oracleChatLog|git|history)|"(get_code_structure|get_file_tree|read_file|file_search|workspace_context|prompt|oracle_chat_log|git|history)")' "${m3_legacy_provider_files[@]}" || true)"
  if [[ -n "$m3_duplicate_schema_matches" ]]; then
    fail "M3 read/discovery schema reintroduced in an app provider"
    printf '%s\n' "$m3_duplicate_schema_matches" >&2
  fi

  m3_domain_provider="$domain_runtime_source_dir/MCPDomainReadToolProvider.swift"
  for requirement in 'case workspaceIndependent' 'case workspaceOptional' 'case workspaceRequired'; do
    if ! grep -q "$requirement" "$m3_domain_provider"; then
      fail "M3 per-family context requirement missing: $requirement"
    fi
  done
  if ! grep -q 'case "history", "oracle_chat_log"' "$m3_domain_provider" \
    || ! grep -q 'case "get_file_tree", "git"' "$m3_domain_provider"; then
    fail "M3 historical workspace-independent/optional family mapping changed"
  fi

  m3_app_read_routing="Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+DomainRouting.swift"
  if ! grep -q 'registerForRead' "$m3_app_read_routing"; then
    fail "M3 awaited transient read authority registration missing"
  fi
  if grep -q 'validateDomainReadContext' "$m3_app_read_routing"; then
    fail "M3 read path reintroduced repeated MainActor authority capture"
  fi
  m3_read_resolver="$(sed -n '/func resolveDomainReadContext/,/Runs before the server is stopped/p' "$m3_app_read_routing")"
  if grep -q -E 'registerWindow|publishDomainRoutingBinding' <<<"$m3_read_resolver"; then
    fail "M3 read resolution mutates shared presentation routing"
  fi
  if ! grep -q 'domainReadAppExecutionContexts\[invocation.invocationID\]' "$m3_app_read_routing" \
    || ! grep -q 'releaseDomainReadAppExecutionContext' "$m3_app_read_routing" \
    || ! grep -q 'registerFallbackDomainReadContext' "$m3_app_read_routing" \
    || ! grep -q 'domainRoutingConnectionIDs' "$m3_app_read_routing"; then
    fail "M3 invocation snapshot, fallback authority, or connection-lifecycle seam missing"
  fi
  if ! grep -q 'context.handle == nil' "$m3_domain_provider"; then
    fail "M3 required read authority no longer fails closed"
  fi
  m3_file_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPFileToolProvider.swift"
  m3_prompt_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPPromptContextToolProvider.swift"
  if ! grep -q 'readAuthority(appContext)' "$m3_file_backend" \
    || ! grep -q 'selectionRefreshedContext(appContext.resolvedTabContext)' "$m3_prompt_backend" \
    || grep -q 'resolveTabContextSnapshot' <<<"$(sed -n '/func selectionRefreshedContext/,/private func simplePromptReply/p' "$m3_prompt_backend")"; then
    fail "M3 app backend stopped consuming captured authority or repeated heavyweight routing"
  fi
  m3_git_backend="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift"
  if ! grep -q 'appContext.metadata' "$m3_git_backend" \
    || ! grep -q 'appContext.lookupContext' "$m3_git_backend" \
    || ! grep -q 'appContext?.resolvedTabContext' "$m3_git_backend" \
    || ! grep -q 'capturedWorkspaceID' "$m3_git_backend"; then
    fail "M3 git backend stopped consuming captured authority"
  fi
  if ! sed -n '/commitPrimaryGitDiffArtifactsToCurrentTab(/,/)/p' "$m3_git_backend" | grep -q 'appContext' \
    || ! sed -n '/replaceAdvertisedGitArtifactsForCurrentTab(/,/)/p' "$m3_git_backend" | grep -q 'appContext'; then
    fail "M3 git artifact side effects no longer carry captured authority"
  fi

  m3_side_effects="$domain_runtime_source_dir/DomainReadSideEffectCoordinator.swift"
  if ! grep -q 'case selection' "$m3_side_effects" || ! grep -q 'case gitArtifacts' "$m3_side_effects"; then
    fail "M3 independent selection/Git effect classes missing"
  fi
  if ! grep -q 'await previous.result' "$m3_side_effects"; then
    fail "M3 side-effect chain no longer recovers after an earlier failure"
  fi
  if ! grep -q 'expiredOperationIDs' "$m3_side_effects" \
    || ! grep -q 'receiptUnavailable' "$m3_side_effects"; then
    fail "M3 exact side-effect receipts no longer fail closed after bounded-ledger expiry"
  fi
fi

m2_presentation_bridge="Sources/RepoPrompt/Infrastructure/MCP/AppShared/DomainWorkspacePresentationBridge.swift"
if [[ ! -f "$m2_presentation_bridge" ]]; then
  fail "M2 MainActor workspace presentation bridge missing"
else
  if ! grep -q 'final class DomainWorkspacePresentationBridge' "$m2_presentation_bridge"; then
    fail "M2 workspace presentation bridge declaration missing"
  fi
  if ! grep -q 'guard subscription.snapshot.isBootstrapped' "$m2_presentation_bridge"; then
    fail "M2 workspace presentation bridge lost first-projection readiness gate"
  fi
fi

service_registry_source="Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift"
print_matches \
  "ServiceRegistry reintroduced stored service/schema/catalog authority" \
  grep -n -E 'static[[:space:]]+(var|let)[[:space:]]+(services|schemas|catalog)|\[any[[:space:]]+Service\]|\[Tool\]' "$service_registry_source"
for forwarding_source in \
  Sources/RepoPrompt/Infrastructure/MCP/MCPGlobalToolNames.swift \
  Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolNames.swift \
  Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolCapabilities.swift; do
  print_matches \
    "MCP compatibility facade contains a second literal tool authority: $forwarding_source" \
    grep -n -E '"(app_settings|bind_context|manage_selection|read_file|file_search|agent_run|history)"' "$forwarding_source"
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
  "docs/architecture/codex-app-server-schema-gate.md"
  "docs/architecture/compose.md"
  "docs/architecture/headless-mcp-runtime.md"
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
  "docs/spec/headless-mcp-domain-runtime-m0-contracts.md"
  "docs/spec/headless-mcp-domain-runtime-m0-editflowperf-baseline.json"
  "docs/spec/headless-mcp-domain-runtime-m2-context-authority.md"
  "docs/spec/headless-mcp-domain-runtime-m3-evidence.json"
  "docs/spec/headless-mcp-domain-runtime-m3-read-discovery.md"
  "docs/spec/headless-mcp-domain-runtime-m4-protected-mutations.md"
  "docs/spec/headless-mcp-domain-runtime-m5-ai-agent-interaction.md"
  "docs/spec/headless-mcp-domain-runtime-m6-host-extraction.md"
  "docs/spec/headless-mcp-domain-runtime-m7-cutover.md"
  "docs/spec/history-query-tools.md"
  "docs/spec/mcp-domain-canonical-tool-definitions.generated.json"
  "docs/worktrees.md"
  "docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md"
  "docs/investigations/test-coverage-value-audit-ledger-2026-05-29.md"
  "docs/plans/test-coverage-value-audit-2026-05-29.md"
)
existing_tracked_docs=()
while IFS= read -r path; do
  if [[ -e "$path" ]]; then
    existing_tracked_docs+=("$path")
  fi
done < <(git ls-files docs)
unexpected_tracked_docs="$(comm -23 \
  <(printf '%s\n' "${existing_tracked_docs[@]}" | sort) \
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
