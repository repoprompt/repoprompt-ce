# Deferred Work

**Policy:** append-only after Phase 0 close. These items are intentionally outside
Phases 0–8 and must not be used to expand an earlier phase.

## Phase 9+ compatibility cleanup

1. Remove the legacy backend and construction-time selector after Core authority
   stabilizes.
2. Remove temporary app typealiases, forwarding adapters, and obsolete concrete
   implementations.
3. Convert transitional ownership/import guards into permanent source-layout and
   package guards.
4. Remove dead bridging-header declarations only after every caller imports its
   owning module.
5. Revisit access levels raised solely for extraction and lower them where
   external module use no longer requires exposure.

## Headless/Core convergence

Headless v1 intentionally duplicates mutable runtime components:

| Headless v1 component | Phase 9+ intended replacement |
| --- | --- |
| headless root registry | shared Core session/root authority |
| headless workspace/state store | `WorkspaceSessionController` persistence transactions |
| headless selection store | Core selection/revision controller |
| headless tool registry/dispatch | shared factual tool services plus product policy profile |
| headless file catalog/search path | `WorkspaceFileContextStore` and Core search |
| headless lifecycle/request registry | shared Core session handle/runtime admission |
| headless prompt state/renderer | Core factual prompt projection/accounting |

Convergence requires a separate characterized migration. Headless v1 must not
wrap or instantiate the app's current mutable engine as a shortcut.

## Phase 8 append — concrete duplicate mapping (2026-06-22)

| Phase 8 owner | Phase 9+ convergence target |
| --- | --- |
| `Configuration/HeadlessConfigurationStore.swift`, `HeadlessStateFileSecurity.swift`, `HeadlessFileLock.swift` | selected Core session persistence transaction and platform descriptor adapters |
| `Runtime/HeadlessWorkspaceStore.swift`, `HeadlessWorkspaceModels.swift`, `HeadlessHost.swift` | `WorkspaceSessionController` / `RepoPromptCoreSession` authority |
| `Configuration/HeadlessRootAccessPolicy.swift`, `Runtime/HeadlessPathResolver.swift`, `HeadlessSecureFileAccess.swift` | shared Core root capability plus CoreMacOS/POSIX descriptor services |
| `Runtime/HeadlessFileCatalog.swift`, `HeadlessSearchService.swift`, `HeadlessCodeStructureService.swift` | `WorkspaceFileContextStore` immutable catalog/search/codemap services |
| `MCP/HeadlessMCPServer.swift`, `HeadlessStdioTransport.swift`, `HeadlessToolRegistry.swift` | shared runtime admission/tool services with a product-specific policy profile |
| `MCP/Tools/HeadlessSelectionTools.swift`, `HeadlessPromptTools.swift`, `HeadlessWorkspaceTools.swift` | shared Core selection/session/prompt command ingress |

These duplicates are intentional Phase 8 product boundaries. They must not be
replaced by app/Core runtime construction during Phase 8, and this mapping does
not authorize Phase 9 work.

## Separately planned work

- Additional MCP provider/catalog/DTO/formatter/dispatch extraction.
- Cross-platform/Linux/Windows support.
- Persisted schema redesign or migration.
- Moving app path, UserDefaults, approval, Git authorization, visible lifecycle,
  or diagnostics-presentation policy into Core.
- Broader performance optimization unrelated to preserving the frozen Phase 0
  baselines.

## Phase 5 append — selected-session compatibility retirement (2026-06-21)

- Remove `LegacyWorkspaceSessionBackend` and `coreIsolation.workspaceBackend`
  only after Phase 8 rollback support expires.
- Remove deferred presentation reconciliation and legacy manager test fallbacks
  after every UI caller is natively async over command receipts.
- Phase 5 closed every production selected-path direct fallback. The only
  compatibility retained for later retirement is an explicitly DEBUG/XCTest,
  no-session fixture adapter; release composition cannot construct or call it.
- Converge headless onto the shared Core session graph only in Phase 9+.
- Phase 7, not Phase 5, owns draining request counts, replacement routing, and
  weak runtime adapter registries.

## Phase 6 append — factual compatibility retirement (2026-06-21)

- Remove `LegacyPromptFactualContextProvider` with the Phase 5 legacy backend only
  after Phase 8 rollback support expires.
- Remove app aliases/DEBUG compatibility projections for Core prompt accounting,
  token values, and legacy mixed-layer XCTest assertions in Phase 9.
- Converge remaining specialized selection/code-structure presentation adapters
  only after their external DTO contracts are characterized; do not reintroduce
  store-backed common prompt/export rendering.

## Publication remediation confirmation (2026-06-22)

- Phase 9 compatibility cleanup and headless/Core convergence remain deferred;
  publication hardening is not authorization to begin either migration.
- `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless` retain distinct app,
  compatibility-proxy, and direct-stdio identities, state, packaging, and smoke lanes.
- Continuous linked Tree-sitter verification is a publication guard only. It does
  not move grammar ownership, add bridge symbols, or broaden the target graph.
- Any future convergence must begin from a new characterized plan and preserve
  the Phase 0–8 checkpoints and this append-only deferral record.
