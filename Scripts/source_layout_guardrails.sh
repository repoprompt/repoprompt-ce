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

portable_import_guard() {
  local portable_sources="Packages/RepoPromptPortableRuntime/Sources"
  local portable_manifest="Packages/RepoPromptPortableRuntime/Package.swift"
  local forbidden_imports='^(import|@testable[[:space:]]+import)[[:space:]]+(AppKit|SwiftUI|Sparkle|RepoPromptServiceProtocol|RepoPromptServicePersistence|RepoPromptServiceHTTP|RepoPromptServerHost|RepoPromptServerOperations|RepoPromptMCPAdapter|RepoPromptApp|RepoPrompt|Hummingbird|HummingbirdTLS|NIOSSL|X509)([[:space:]]|$)'

  [[ -d "$portable_sources" ]] || fail "portable source root missing: $portable_sources"
  [[ -f "$portable_manifest" ]] || fail "portable manifest missing: $portable_manifest"
  [[ -f "docs/architecture/portable-runtime-semantic-owners.md" ]] || \
    fail "portable semantic-owner inventory missing"
  [[ -f "docs/architecture/portable-runtime-prototype-extraction.md" ]] || \
    fail "portable prototype extraction ledger missing"

  print_matches \
    "Desktop retains a dead test-only portable provider/model projection" \
    grep -R -n -E 'portable(TurnSettingsSnapshot|SettingsID|ModelIdentifier|PermissionID)' Sources/RepoPrompt

  [[ ! -e "$portable_sources/RepoPromptRuntimeModel/ServiceModel/CanonicalSigning.swift" ]] || \
    fail "transport signing/authentication belongs to future RepoPromptServiceProtocol"
  [[ ! -e "$portable_sources/RepoPromptRuntimeModel/ServiceModel/PortalDesktopSettingsDTOs.swift" ]] || \
    fail "portal request/projection DTOs belong to future RepoPromptServiceProtocol"
  [[ ! -e "$portable_sources/RepoPromptRuntimeModel/ServiceModel/PortalSessionDTOs.swift" ]] || \
    fail "portal session request/projection DTOs belong to future RepoPromptServiceProtocol"
  print_matches \
    "RuntimeModel retains a Crypto, transport-auth, or portal DTO dependency" \
    grep -R -n -E '^import[[:space:]]+(Crypto|CryptoKit)([[:space:]]|$)|CanonicalSigning|ServiceEventSigningKey|Portal[A-Z]|ConnectProviderRequest|ProviderAuthFlow|ProviderAuthentication(Status|State)|ProviderAuthTransaction' \
      "$portable_sources/RepoPromptRuntimeModel"

  print_matches \
    "portable source imports a prohibited UI, root, wire, persistence, HTTP, TLS, or Server module" \
    grep -R -n -E "$forbidden_imports" "$portable_sources"
  print_matches \
    "portable manifest/source resurrects the temporary Server graph" \
    grep -R -n -E 'makeServerPackage|REPOPROMPT_SERVER_ONLY|RepoPromptHeadlessLaunchBridge' Package.swift "$portable_manifest" "$portable_sources"
  [[ ! -e "Packages/RepoPromptServer" ]] || fail "PR 2 must not introduce the Server package graph"
  print_matches \
    "PR 2 contains premature proposal/application authority behavior" \
    grep -R -n -E 'InMemoryAuthorityStore|AuthorityTransitionCommand|AuthorityTransitionReceipt|func[[:space:]]+apply\(' \
      "$portable_sources/RepoPromptHeadlessRuntime" "$portable_sources/RepoPromptAuthorityAPI"
  print_matches \
    "portable source uses Bundle.module; package-owned semantics must be compiled Swift" \
    grep -R -n -E 'Bundle\.module' "$portable_sources"
  print_matches \
    "root-consumed portable product retains package-only declarations" \
    grep -R -n -E '^[[:space:]]*package[[:space:]]|@TaskLocal[[:space:]]+package[[:space:]]' \
      "$portable_sources/RepoPromptShared" \
      "$portable_sources/RepoPromptDomainRuntime" \
      "$portable_sources/RepoPromptCodeMapCore" \
      "$portable_sources/RepoPromptRegexCore"
  print_matches \
    "retired canonical workflow JSON remains in the repository" \
    find . -path '*/.build' -prune -o -name 'canonical-workflows-v62.json' -print

  local fixture_roots
  fixture_roots="$(find . -path '*/.build' -prune -o -type d -path '*/Tests/Fixtures/AgentParity/v1' -print)"
  if [[ "$fixture_roots" != "./Packages/RepoPromptPortableRuntime/Tests/Fixtures/AgentParity/v1" ]]; then
    fail "AgentParity/v1 must have exactly one portable package owner"
    printf '%s\n' "$fixture_roots" >&2
  fi
  if ! python3 - <<'PY'
import json
from pathlib import Path

root = Path("Packages/RepoPromptPortableRuntime/Tests/Fixtures/AgentParity/v1")
expected = {
    "model-normalization.json",
    "provider-matrix.json",
    "provider-turn-semantics.json",
    "transcript-presentation.json",
    "turn-compilation.json",
}
assert {path.name for path in root.glob("*.json")} == expected
for path in root.glob("*.json"):
    value = json.loads(path.read_text())
    assert value["schemaVersion"] == 2, path
    assert value["prototypeCommit"] == "45c42d65e444884d1681f4504c10d25dcb7d858a", path
    assert value["generatedFrom"].startswith("Packages/RepoPromptPortableRuntime/Sources/"), path
assert json.loads((root / "provider-turn-semantics.json").read_text())["generatedFrom"] == \
    "Packages/RepoPromptPortableRuntime/Sources/RepoPromptAgentRuntimeCore/ProviderTurnConfigurationAdapters.swift"
PY
  then
    fail "AgentParity fixtures must carry exact prototype and nested source provenance"
  fi

  local agent_model_definitions provider_kind_definitions
  agent_model_definitions="$(grep -R -l -E '^enum AgentModel:[[:space:]]+String' Sources/RepoPrompt --include='*.swift' || true)"
  provider_kind_definitions="$(grep -R -l -E '^enum AgentProviderKind:[[:space:]]+String' Sources/RepoPrompt --include='*.swift' || true)"
  if [[ "$agent_model_definitions" != "Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModel.swift" ]]; then
    fail "Desktop AgentModel raw-value owner drifted"
    printf '%s\n' "$agent_model_definitions" >&2
  fi
  if [[ "$provider_kind_definitions" != "Sources/RepoPrompt/Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift" ]]; then
    fail "Desktop AgentProviderKind raw-value owner drifted"
    printf '%s\n' "$provider_kind_definitions" >&2
  fi

  print_matches \
    "root Desktop adapter imports a prohibited headless, wire, persistence, HTTP, or TLS module" \
    grep -R -n -E '^import[[:space:]]+(RepoPromptHeadlessRuntime|RepoPromptServiceProtocol|RepoPromptServicePersistence|RepoPromptServiceHTTP|RepoPromptServerHost|RepoPromptServerOperations|RepoPromptMCPAdapter|Hummingbird|HummingbirdTLS|NIOSSL|X509)([[:space:]]|$)' \
      Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection \
      Sources/RepoPrompt/Features/AgentMode/Runtime/Providers \
      Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings

  print_matches \
    "Desktop/root imports Server wire protocol after portable extraction" \
    grep -R -n -E '^import[[:space:]]+RepoPromptServiceProtocol([[:space:]]|$)' Sources/RepoPrompt Sources/RepoPromptMCP
  print_matches \
    "Desktop/root imports portable headless authority instead of its established owners" \
    grep -R -n -E '^import[[:space:]]+RepoPromptHeadlessRuntime([[:space:]]|$)' Sources/RepoPrompt Sources/RepoPromptMCP

  local portable_workflow=".github/workflows/portable-runtime.yml"
  if [[ ! -f "$portable_workflow" ]] || \
     ! grep -q 'Packages/RepoPromptPortableRuntime/\*\*' "$portable_workflow" || \
     ! grep -q 'AgentWorkflow\.swift' "$portable_workflow" || \
     ! grep -q 'GlobalSettingsDocument\.swift' "$portable_workflow" || \
     ! grep -q 'AgentRunSessionStore\.swift' "$portable_workflow" || \
     ! grep -q 'test_contribution_preflight\.py' "$portable_workflow" || \
     ! grep -q 'validate_portable_dependency_graph\.py' "$portable_workflow" || \
     ! grep -q '^  root-compatibility:' "$portable_workflow" || \
     ! grep -q 'swift build --product RepoPrompt --disable-automatic-resolution' "$portable_workflow" || \
     ! grep -q 'swift build --product repoprompt-mcp --disable-automatic-resolution' "$portable_workflow"; then
    fail "portable CI path ownership must cover Portable and every documented Desktop mapping owner"
  fi
  if grep -q 'Packages/RepoPromptServer/\*\*' "$portable_workflow"; then
    fail "PR 2 portable CI must not claim a Server package graph that does not exist yet"
  fi
  if [[ -f "Packages/RepoPromptServer/Package.swift" ]] && \
     ! grep -qF '.package(path: "../RepoPromptPortableRuntime")' "Packages/RepoPromptServer/Package.swift"; then
    fail "RepoPromptServer must consume the sibling portable package through ../RepoPromptPortableRuntime"
  fi

  if ! python3 Scripts/validate_portable_dependency_graph.py; then
    fail "portable package exact dependency graph drifted"
  fi

  if [[ "$failures" -ne 0 ]]; then
    printf 'Portable import guard failed (%s issue%s).\n' "$failures" "$([[ "$failures" == 1 ]] && printf '' || printf 's')" >&2
    return 1
  fi
  printf 'OK: portable import guard passed.\n'
}

if [[ "${1:-}" == "portable-imports" ]]; then
  portable_import_guard
  exit 0
elif [[ "$#" -gt 0 ]]; then
  printf 'usage: %s [portable-imports]\n' "$0" >&2
  exit 64
fi

portable_import_guard

# 0. Required layout roots/files should exist before negative scans run.
required_dirs=(
  "Sources/RepoPromptExecutable"
  "Sources/RepoPrompt/Features"
  "Sources/RepoPrompt/Infrastructure"
  "Sources/RepoPrompt/Infrastructure/SyntaxParsing"
  "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP"
  "Sources/RepoPromptWorkspaceCore"
  "Packages/RepoPromptPortableRuntime/Sources/RepoPromptDomainRuntime"
  "Tests/RepoPromptTests"
  "Tests/RepoPromptWorkspaceCoreTests"
  "Packages/RepoPromptPortableRuntime/Tests/RepoPromptDomainRuntimeTests"
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
  "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift"
  "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift"
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
  "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h"
  "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/array.h"
  "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h"
  "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/src/javascript/scanner.c"
  "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/src/python/scanner.c"
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
if [[ -d "Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport" ]]; then
  unexpected_tree_sitter_scanner_support_files="$(find Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport -type f \
    ! -path 'Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h' \
    ! -path 'Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/array.h' \
    ! -path 'Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h' \
    ! -path 'Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/src/javascript/scanner.c' \
    ! -path 'Packages/RepoPromptPortableRuntime/Sources/TreeSitterScannerSupport/src/python/scanner.c' \
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

if ! portable_manifest_output="$(python3 <<'PY'
import json
import re
import subprocess
from pathlib import Path

portable_root = Path("Packages/RepoPromptPortableRuntime")
portable_manifest = (portable_root / "Package.swift").read_text()
portable_resolved = json.loads((portable_root / "Package.resolved").read_text())
portable_pins = {pin["identity"]: pin for pin in portable_resolved["pins"]}
portable = json.loads(subprocess.check_output(
    ["swift", "package", "--disable-sandbox", "--package-path", str(portable_root), "dump-package"],
    text=True,
))
root = json.loads(subprocess.check_output(["swift", "package", "--disable-sandbox", "dump-package"], text=True))
portable_targets = {target["name"]: target for target in portable["targets"]}
root_targets = {target["name"]: target for target in root["targets"]}
errors = []

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

moved_targets = {
    "RepoPromptRuntimeModel", "RepoPromptAuthorityAPI", "RepoPromptShared",
    "RepoPromptAgentRuntimeCore", "RepoPromptWorkspaceRuntimeCore",
    "RepoPromptDomainRuntime", "RepoPromptHeadlessRuntime", "RepoPromptCodeMapCore",
    "RepoPromptRegexCore", "RepoPromptC", "CSwiftPCRE2",
    "TreeSitterScannerSupport", "RepoPromptLinuxSupport",
}
missing = sorted(moved_targets - portable_targets.keys())
if missing:
    errors.append(f"Portable manifest missing targets: {', '.join(missing)}")
unexpected_root = sorted(moved_targets & root_targets.keys())
if unexpected_root:
    errors.append(f"Root manifest still owns portable targets: {', '.join(unexpected_root)}")

root_manifest = Path("Package.swift").read_text()
if '.package(path: "Packages/RepoPromptPortableRuntime")' not in root_manifest:
    errors.append("Root manifest missing local RepoPromptPortableRuntime dependency")
for forbidden in ("makeServerPackage", "REPOPROMPT_SERVER_ONLY"):
    if forbidden in root_manifest or forbidden in portable_manifest:
        errors.append(f"Forbidden temporary Server graph marker present: {forbidden}")

repo_prompt = root_targets.get("RepoPrompt", {})
repo_prompt_app = root_targets.get("RepoPromptApp", {})
if repo_prompt.get("type") != "executable" or repo_prompt.get("path") != "Sources/RepoPromptExecutable":
    errors.append("RepoPrompt target must remain the thin executable entry")
repo_prompt_dependencies = repo_prompt.get("dependencies", [])
if [d["byName"][0] for d in repo_prompt_dependencies if d.get("byName")] != ["RepoPromptApp"] or len(repo_prompt_dependencies) != 1:
    errors.append("RepoPrompt executable must depend only on RepoPromptApp")
if repo_prompt_app.get("type") != "regular" or repo_prompt_app.get("path") != "Sources/RepoPrompt":
    errors.append("RepoPromptApp target ownership drifted")
app_dependencies = repo_prompt_app.get("dependencies", [])
app_by_name = [d["byName"][0] for d in app_dependencies if d.get("byName")]
app_products = {(d["product"][0], d["product"][1]) for d in app_dependencies if "product" in d}
if app_by_name.count("RepoPromptWorkspaceCore") != 1:
    errors.append("RepoPromptApp must depend exactly once on RepoPromptWorkspaceCore")
for product in ("RepoPromptRuntimeModel", "RepoPromptAgentRuntimeCore", "RepoPromptShared", "RepoPromptDomainRuntime", "RepoPromptCodeMapCore", "RepoPromptRegexCore", "RepoPromptC"):
    if (product, "RepoPromptPortableRuntime") not in app_products:
        errors.append(f"RepoPromptApp missing portable product dependency: {product}")

workspace_core = root_targets.get("RepoPromptWorkspaceCore")
if workspace_core is None or workspace_core.get("path") != "Sources/RepoPromptWorkspaceCore" or workspace_core.get("dependencies", []):
    errors.append("RepoPromptWorkspaceCore root target contract drifted")
workspace_tests = root_targets.get("RepoPromptWorkspaceCoreTests")
if workspace_tests is None or workspace_tests.get("path") != "Tests/RepoPromptWorkspaceCoreTests":
    errors.append("RepoPromptWorkspaceCoreTests root target contract drifted")

allowed_edges = {
    "RepoPromptRuntimeModel": set(),
    "RepoPromptAuthorityAPI": {"RepoPromptRuntimeModel"},
    "RepoPromptShared": {"Crypto"},
    "RepoPromptAgentRuntimeCore": {"RepoPromptRuntimeModel"},
    "RepoPromptWorkspaceRuntimeCore": {"RepoPromptRuntimeModel", "RepoPromptShared"},
    "RepoPromptDomainRuntime": {"RepoPromptShared", "RepoPromptRuntimeModel", "RepoPromptC", "RepoPromptCodeMapCore", "Crypto", "Logging", "MCP"},
    "RepoPromptHeadlessRuntime": {"RepoPromptRuntimeModel", "RepoPromptAuthorityAPI", "RepoPromptShared", "RepoPromptAgentRuntimeCore", "RepoPromptWorkspaceRuntimeCore", "RepoPromptDomainRuntime"},
    "RepoPromptLinuxSupport": set(),
    "RepoPromptRegexCore": {"CSwiftPCRE2"},
    "RepoPromptC": set(),
    "CSwiftPCRE2": set(),
    "TreeSitterScannerSupport": set(),
}
for target_name, expected in allowed_edges.items():
    target = portable_targets.get(target_name, {})
    actual = set()
    for dependency in target.get("dependencies", []):
        if dependency.get("byName"):
            actual.add(dependency["byName"][0])
        elif dependency.get("product"):
            actual.add(dependency["product"][0])
    if actual != expected:
        errors.append(f"{target_name} dependency drift: expected {sorted(expected)}, got {sorted(actual)}")

code_map = portable_targets.get("RepoPromptCodeMapCore", {})
code_map_dependencies = code_map.get("dependencies", [])
code_map_products = {(d["product"][0], d["product"][1]) for d in code_map_dependencies if "product" in d}
code_map_by_name = [d["byName"][0] for d in code_map_dependencies if d.get("byName")]
if code_map_by_name.count("TreeSitterScannerSupport") != 1 or code_map_by_name.count("RepoPromptRegexCore") != 1:
    errors.append("RepoPromptCodeMapCore low-level target edges drifted")
for identity, (url, version, revision, product) in expected_packages.items():
    if f'.package(url: "{url}", exact: "{version}")' not in portable_manifest:
        errors.append(f"Portable manifest missing exact pin: {identity} {version}")
    pin = portable_pins.get(identity)
    state = pin.get("state", {}) if pin else {}
    if not pin or pin.get("location") != url or state.get("revision") != revision or state.get("version") != version:
        errors.append(f"Portable Package.resolved pin drift: {identity}")
    if (product, identity) not in code_map_products:
        errors.append(f"RepoPromptCodeMapCore missing grammar product: {product} ({identity})")

wrapper_url = "https://github.com/repoprompt/swift-tree-sitter.git"
wrapper_revision = "a778ef4fb7f0d3ad00185f42ce83c688373c4361"
if re.search(rf'\.package\(\s*url:\s*"{re.escape(wrapper_url)}",\s*revision:\s*"{wrapper_revision}"\s*\)', portable_manifest) is None:
    errors.append("Portable manifest must pin the approved RepoPrompt SwiftTreeSitter fork")
wrapper = portable_pins.get("swift-tree-sitter", {})
if wrapper.get("location") != wrapper_url or wrapper.get("state", {}) != {"revision": wrapper_revision}:
    errors.append("Portable SwiftTreeSitter pin drifted")
if ("SwiftTreeSitter", "swift-tree-sitter") not in code_map_products:
    errors.append("RepoPromptCodeMapCore missing SwiftTreeSitter product")

runtime = portable_pins.get("tree-sitter", {})
if runtime.get("location") != "https://github.com/tree-sitter/tree-sitter" or runtime.get("state", {}).get("version") != "0.25.10" or runtime.get("state", {}).get("revision") != "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406":
    errors.append("Portable Tree-sitter runtime pin drifted")

support = portable_targets.get("TreeSitterScannerSupport", {})
if sorted(support.get("sources", [])) != ["src/javascript/scanner.c", "src/python/scanner.c"]:
    errors.append("Portable TreeSitterScannerSupport contract drifted")

code_map_tests = portable_targets.get("RepoPromptCodeMapCoreTests", {})
if code_map_tests.get("type") != "test":
    errors.append("Portable RepoPromptCodeMapCoreTests target drifted")
domain_tests = portable_targets.get("RepoPromptDomainRuntimeTests", {})
if domain_tests.get("type") != "test":
    errors.append("Portable RepoPromptDomainRuntimeTests target drifted")

core_syntax = (portable_root / "Sources/RepoPromptCodeMapCore/CodeMapSyntaxEngine.swift").read_text()
required_imports = {
    "SwiftTreeSitter", "TreeSitterC", "TreeSitterCPP", "TreeSitterCSharp",
    "TreeSitterGo", "TreeSitterJava", "TreeSitterJavaScript", "TreeSitterPHP",
    "TreeSitterPython", "TreeSitterRuby", "TreeSitterRust", "TreeSitterSwift",
    "TreeSitterTSX", "TreeSitterTypeScript",
}
for module in sorted(required_imports):
    if f"import {module}\n" not in core_syntax:
        errors.append(f"CodeMapSyntaxEngine missing direct import: {module}")

if errors:
    raise SystemExit("\n".join(errors))
PY
)"; then
  fail "Portable package dependency, product, or scanner-support contract drifted"
  printf '%s\n' "$portable_manifest_output" >&2
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
domain_runtime_source_dir="Packages/RepoPromptPortableRuntime/Sources/RepoPromptDomainRuntime"
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
assert value["interaction"]["default_timeout"] == "Context Builder captured or Agent Mode live global questionTimeoutSeconds setting"
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
done < <(find Sources Packages/RepoPromptPortableRuntime/Sources -name MCPControlMessages.swift -type f -print | sort)
if [[ "${#mcp_control_files[@]}" -ne 1 || "${mcp_control_files[0]:-}" != "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPControlMessages.swift" ]]; then
  fail "MCPControlMessages.swift must exist only at Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPControlMessages.swift"
  printf '%s\n' "${mcp_control_files[@]}" >&2
fi

# 3a. MCP filesystem and event wire identity also have one shared source of truth.
mcp_identity_files=()
while IFS= read -r file; do
  mcp_identity_files+=("$file")
done < <(find Sources Packages/RepoPromptPortableRuntime/Sources -name MCPFilesystemIdentity.swift -type f -print | sort)
if [[ "${#mcp_identity_files[@]}" -ne 1 || "${mcp_identity_files[0]:-}" != "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift" ]]; then
  fail "MCPFilesystemIdentity.swift must exist only under RepoPromptShared"
  printf '%s\n' "${mcp_identity_files[@]}" >&2
fi

mcp_event_declarations="$(grep -R -l -E '^(public )?struct MCPExternalClientEvent' Sources Packages/RepoPromptPortableRuntime/Sources --include='*.swift' | sort || true)"
if [[ "$mcp_event_declarations" != "Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/MCP/MCPExternalClientEvent.swift" ]]; then
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

# Agent Mode terminal settlement stays free of the app's concrete session
# class (AgentTabSession) and uses provider-neutral domain terminal command
# vocabulary directly.
terminal_session_neutral_files=(
  "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalSessionBinding.swift"
  "Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift"
)
for path in "${terminal_session_neutral_files[@]}"; do
  if [[ ! -f "$path" ]]; then
      fail "required session-neutral terminal settlement source missing: $path"
    continue
  fi
  print_matches \
      "session-neutral terminal settlement source references the concrete agent session class: $path" \
    grep -n -E 'AgentModeViewModel\.TabSession|AgentTabSession' "$path"
  print_matches \
      "domain-vocabulary terminal settlement source references app-nested terminal command type: $path" \
    grep -n -E 'AgentModeViewModel\.AttachmentTurnDisposition|AgentModeRunService\.CancellationCompletion' "$path"
done

# Claude runtime coordination must use its closed host capability surface rather
# than retaining or attaching the concrete AgentModeViewModel. The session type
# is the extracted top-level AgentTabSession; AgentModeViewModel.TabSession is a
# source-compatibility alias only.
claude_coordinator_source="Sources/RepoPrompt/Features/AgentMode/Runtime/Claude/ClaudeAgentModeCoordinator.swift"
if [[ ! -f "$claude_coordinator_source" ]]; then
  fail "required Claude agent-mode coordinator source missing: $claude_coordinator_source"
else
  print_matches \
    "ClaudeAgentModeCoordinator stores concrete AgentModeViewModel authority" \
    grep -n -E '(^|[[:space:]])(weak[[:space:]]+)?(var|let)[[:space:]]+[[:alnum:]_]+[[:space:]]*:[[:space:]]*AgentModeViewModel[?]?[[:space:]]*$' \
      "$claude_coordinator_source"
  print_matches \
    "ClaudeAgentModeCoordinator reintroduced attach(viewModel:)" \
    grep -n -E 'func[[:space:]]+attach\(viewModel:[[:space:]]*AgentModeViewModel[?]?\)' \
      "$claude_coordinator_source"
fi

# The Agent Mode session type is the extracted top-level AgentTabSession.
# `AgentModeViewModel.TabSession` must remain a source-compatibility typealias to
# that exact class (no parallel session authority), and Agent Mode runtime code
# must name AgentTabSession directly instead of the view-model-qualified alias.
agent_tab_session_source="Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentTabSession.swift"
if [[ ! -f "$agent_tab_session_source" ]]; then
  fail "required extracted agent session source missing: $agent_tab_session_source"
else
  if ! grep -q -F 'typealias TabSession = AgentTabSession' "$agent_tab_session_source"; then
    fail "AgentTabSession source lost the AgentModeViewModel.TabSession source-compatibility typealias"
  fi
fi
print_matches \
  "Agent Mode runtime source references the view-model-qualified session alias (use AgentTabSession)" \
  grep -R -n -F 'AgentModeViewModel.TabSession' \
    Sources/RepoPrompt/Features/AgentMode/Runtime

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
  "docs/architecture/context-composer.md"
  "docs/architecture/desktop-agent-authority.md"
    "docs/architecture/headless-mcp-runtime.md"
    "docs/architecture/portable-runtime-semantic-owners.md"
    "docs/architecture/portable-runtime-prototype-extraction.md"
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
