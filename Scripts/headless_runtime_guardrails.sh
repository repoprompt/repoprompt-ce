#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

runtime_sources="Sources/RepoPromptDomainRuntime"
direct_sources=("Sources/RepoPromptMCP" "Sources/RepoPromptMCPCore")
direct_core="Sources/RepoPromptMCPCore"

if grep -R -n -E '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must remain independent of AppKit and SwiftUI" >&2
  exit 1
fi

for forbidden in \
  MCPFoundationStandaloneBackend \
  MCPDomainCanonicalToolManifest \
  RECORD_MCP_WINDOW_TOOL_CATALOG \
  MCPServerViewModel; do
  if grep -R -n --include='*.swift' --include='*.json' "$forbidden" "$runtime_sources" "${direct_sources[@]}"; then
    echo "error: forbidden duplicate or app-owned headless authority: $forbidden" >&2
    exit 1
  fi
done

# The retired MCP ServiceRegistry is a whole symbol, not a substring of unrelated registries.
if grep -R -n -w --include='*.swift' ServiceRegistry Sources; then
  echo "error: retired M7 migration authority remains in production sources: ServiceRegistry" >&2
  exit 1
fi

for retired in \
  MCPWindowToolRuntime \
  MCPWindowToolDependencies \
  MCPWindowToolContext \
  MCPWindowToolCatalogService \
  MCPWindowToolGroup \
  MCPAppToolDependencies \
  sharedBindingRuntime \
  appAdapterTools \
  activeTabCompatibility \
  PresentationActiveContextFallback \
  usesPresentationActiveContext \
  allowLegacyImplicitRouting \
  shouldUseGenericTabBindingCompatibility \
  TabScopedContext \
  DomainProtectedMutationStage \
  migratedToolNames; do
  if grep -R -n --include='*.swift' "$retired" Sources; then
    echo "error: retired M7 migration authority remains in production sources: $retired" >&2
    exit 1
  fi
done

if grep -R -n --include='*.swift' -E '@MainActor|^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Combine)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must have zero domain-owned MainActor or UI dependencies" >&2
  exit 1
fi

canonical_file="$runtime_sources/MCPDomainCanonicalToolDefinitions.swift"
if [[ ! -f "$canonical_file" ]]; then
  echo "error: missing canonical Swift tool definitions" >&2
  exit 1
fi

if find "$runtime_sources" "${direct_sources[@]}" -type f \( -iname '*tool*manifest*.json' -o -iname '*schema*manifest*.json' \) -print -quit | grep -q .; then
  echo "error: headless canonical schemas must not be copied into a resource manifest" >&2
  exit 1
fi

if ! grep -q 'MCPStdioServerTransport' "$direct_core/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must use its terminal-aware bounded stdio transport" >&2
  exit 1
fi

if grep -E -q '(^|[^[:alnum:]_])StdioTransport\(' "$direct_core/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must not install the SDK stdio dispatcher" >&2
  exit 1
fi

canonical_workspace_service="$runtime_sources/MCPDomainCanonicalWorkspaceService.swift"
direct_workspace_adapter="$direct_core/DirectHeadlessWorkspaceBackends.swift"
if [[ ! -f "$canonical_workspace_service" ]] \
  || ! grep -q 'MCPDomainCanonicalWorkspaceService' "$direct_workspace_adapter"; then
  echo "error: direct workspace tools must adapt the canonical domain workspace service" >&2
  exit 1
fi

if grep -E -n 'String\(contentsOf|FileManager\.default\.enumerator|NSRegularExpression' "$direct_workspace_adapter"; then
  echo "error: direct workspace adapter must not duplicate canonical read/search/tree implementations" >&2
  exit 1
fi

capability_adapters="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAppPhysicalCapabilityAdapters.swift"
for family in Execution Context Selection Files Prompt; do
  if ! grep -q "struct $family" "$capability_adapters"; then
    echo "error: missing typed app physical capability family: $family" >&2
    exit 1
  fi
done

if grep -q '@dynamicMemberLookup' "$capability_adapters"; then
  echo "error: physical capability families must not expose dynamic-member forwarding" >&2
  exit 1
fi

if grep -R -n --include='MCP*ToolProvider.swift' \
  -E 'dependencies:[[:space:]]+MCPAppPhysicalCapabilityAdapters([[:space:],?)]|$)' \
  Sources/RepoPrompt/Infrastructure/MCP/WindowTools; then
  echo "error: providers must receive only explicit physical capability families" >&2
  exit 1
fi

if grep -E -q 'stored_(dependency|family)_(count|families)' Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json; then
  echo "error: the retired flat closure dependency bag contract must not return" >&2
  exit 1
fi

if ! grep -q 'MCPDomainReadToolProvider' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone composition must reuse the canonical read provider" >&2
  exit 1
fi

if ! grep -q 'protectedMutationProvider.protectedBinding' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift" \
  || ! grep -q 'longRunningToolProvider.wrapping' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone bindings must install both security decorators" >&2
  exit 1
fi

# App admission adapts client facts only; canonical classifications, lane selection and
# capacity construction must not acquire another manager-owned projection layer.
app_admission_policy="Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolAdmissionPolicy.swift"
connection_manager="Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift"
for admission_source in "$app_admission_policy" "$connection_manager"; do
  if [[ ! -f "$admission_source" ]]; then
    echo "error: missing app admission guard input: $admission_source" >&2
    exit 1
  fi
done
if grep -n -E 'static (let classifications|func classification\()|var connectionLane:|static let [[:alnum:]]+Limit[[:space:]]*=' "$app_admission_policy" \
  || grep -n -E 'func (admissionClass\(forCanonicalToolName|callLane\(forCanonicalToolName|([[:alnum:]]*Limiter|limiter)Limit\(for)|static let [[:alnum:]]+CallLaneLimit[[:space:]]*=' "$connection_manager"; then
  echo "error: retired app admission projection; use the domain catalog and connection limiter defaults" >&2
  exit 1
fi

server_sources="Sources/RepoPromptMCPServer"
if [[ ! -d "$server_sources" || ! -d Tests/RepoPromptMCPServerTests ]]; then
  echo "error: missing M7 server module or app-free tests" >&2
  exit 1
fi
if grep -R -n --include='*.swift' -E '(@MainActor|import[[:space:]]+(AppKit|SwiftUI|Combine|RepoPromptApp)([[:space:]]|$)|UserDefaults[.]standard|Bundle[.]main|ServerNetworkManager|MCPServerViewModel|WindowState)' "$server_sources" Tests/RepoPromptMCPServerTests; then
  echo "error: server transport/execution module must not acquire app authority" >&2
  exit 1
fi
if grep -n -E '(MCPToolExecutionWatchdog[.]run|domainHost[.]invoke|func dispatchResolvedProvider|private struct PromptExportExecutionEnvelope)' "$connection_manager"; then
  echo "error: retired manager-owned execution orchestration has returned" >&2
  exit 1
fi
for retired_transport in UnixSocketMCPTransport BootstrapSocketServer BootstrapSocketConnectionManager MCPRequestTimelineRegistry; do
  if [[ -e "Sources/RepoPrompt/Infrastructure/MCP/$retired_transport.swift" ]]; then
    echo "error: server implementation returned to app: $retired_transport" >&2
    exit 1
  fi
done

echo "Headless runtime guardrails passed."
