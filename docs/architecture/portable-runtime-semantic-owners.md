# Portable runtime semantic owners

This inventory is the PR 2 review surface for identity-sensitive semantics after
`RepoPromptPortableRuntime` extraction. The portable package owns values shared
between products; Desktop keeps its established UI/runtime policy and persistence
owners. PR 2 does not add speculative Desktop-to-portable projections solely to
exercise tests. A catch-all Desktop bridge is prohibited. The prototype-by-prototype
disposition is recorded in
[`portable-runtime-prototype-extraction.md`](portable-runtime-prototype-extraction.md).

| Semantic surface | Canonical portable owner | Desktop/root relationship in PR 2 |
| --- | --- | --- |
| Workflow raw IDs, command names, prompt rendering, MCP order, and install order | `Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/Workflows/**` | `Sources/RepoPrompt/Features/AgentMode/Models/AgentWorkflow.swift` and existing Chat/Prompt/Agent Mode callers adapt definitions for UI only. |
| Provider kinds, execution modes, model identifiers, provider controls, turn configuration, and permissions | `RepoPromptRuntimeModel` and `RepoPromptAgentRuntimeCore/ProviderTurnConfigurationAdapters.swift` | Desktop's existing model catalogs, provider kinds, permission settings, and launch paths remain independently authoritative until a real portable consumer is introduced. PR 2 deliberately adds no unused `portableModelIdentifier`, `portableSettingsID`, `portablePermissionID`, or `portableTurnSettingsSnapshot` API. Portable exhaustive tests and frozen fixtures validate the extracted owner directly. |
| App settings persistence and presentation | Portable typed values/defaults only when genuinely cross-product | `GlobalSettingsDocument.swift`, `GlobalSettingsManager.swift`, and existing Settings view-model adapters remain authoritative for Desktop persistence. |
| App-backed MCP session/agent projection | Portable identity/snapshot values only when genuinely shared | `AgentManageMCPToolService.swift` and `AgentRunSessionStore.swift` continue mapping live/persisted Desktop session owners; they never query a headless authority or Server store. |
| Protocol-v1 wire/auth/portal request and projection DTOs | Deferred to `Packages/RepoPromptServer/Sources/RepoPromptServiceProtocol/**` in PR 3 | No Desktop owner. `CanonicalSigning`, `ServiceEventSigningKey`, `PortalSessionDTOs`, `ConnectProviderRequest`, and provider auth-flow/browser projection DTOs are not RuntimeModel semantics. Headless keeps only non-Codable credential/auth runtime ports and semantic configuration state. Root Desktop and public MCP targets must not import `RepoPromptServiceProtocol`. |

## Executable checks

`Scripts/source_layout_guardrails.sh portable-imports` enforces the prohibited
import set, single compiled workflow catalog, single Agent Parity fixture,
Desktop definition owners, absence of dead test-only portable projections, and absence
of Server/headless authority imports from root products. The full source-layout guard
additionally parses both SwiftPM manifests and verifies the exact target dependency graph.

## Explicit deferrals

- PR 3 introduces the Server wire mappings, transport signing/authentication, portal
  request/projection DTOs, and concrete Server package consumer.
- PR 5 introduces proposal/application lifecycle transitions and durable outbox
  behavior. PR 2 contains only store-independent commands/receipts plus injected store
  seams and does not change an existing durable schema.
