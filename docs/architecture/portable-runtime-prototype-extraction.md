# Portable runtime prototype extraction ledger

PR 2 extracts the established portable semantic owners from the committed `rp-server`
prototype at **`45c42d65e444884d1681f4504c10d25dcb7d858a`**. The prototype working tree is not an input. This ledger records
every source in the three extracted owners and the deliberate dependency inversions.

## Dependency rule

`RepoPromptRuntimeModel` owns canonical store-independent semantic values and persisted
defaults and has no external dependency. `RepoPromptAuthorityAPI` owns the async durable-store
seam. Agent depends only on Model; Workspace depends on Model + Shared; Headless depends on
Model + AuthorityAPI + Shared + Agent + Workspace + Domain. Portable content-identity hashing
is owned by Shared; transport signing/authentication is deferred. No portable target imports the
prototype protocol, persistence, HTTP, TLS, app, AppKit, or SwiftUI modules.

Legacy declarations whose names contain `Wire` are retained only where they are the
established store-independent Codable snapshot/command value used by the runtime. PR 3
owns HTTP envelopes, authentication, transport mappings, and Server composition; it must
map those envelopes to these canonical values rather than duplicate their defaults.

## Agent owner

| Prototype file | PR 2 disposition |
|---|---|
| `AgentCatalogAuthority.swift` | Ported to `RepoPromptAgentRuntimeCore`. |
| `AgentComposerCatalogContracts.swift` | Ported; canonical provider/model catalog behavior retained. |
| `AgentTranscriptPresentationCore.swift` | Ported unchanged apart from Model import. |
| `CodexServiceTierAvailability.swift` | Ported. |
| `DesktopProviderModelFallbackCatalog.swift` | Ported. |
| `EffectiveTurnConfiguration.swift` | Moved to `RepoPromptRuntimeModel`, because store records and Headless share the value. |
| `LifecycleGate.swift` | Ported. |
| `ProviderContracts.swift` | Ported. |
| `ProviderTurnConfigurationAdapters.swift` | Ported with frozen semantics, including direct providers accepting no caller permission ID, always resolving `workspaceWrite`, and emitting `provider.settingsID`. Desktop integration is deferred until a real production consumer exists. |
| `RuntimePorts.swift` | Ported. |
| `SessionAuthority.swift` | Ported. |

`AgentRuntime.swift` and `AgentTurnRuntime.swift` remain small root-consumer adapters over
these established owners; they are not replacements for the extracted catalog, permission,
transcript, lifecycle, and provider semantics.

## Workspace owner

| Prototype file/resource | PR 2 disposition |
|---|---|
| `CanonicalRuntimeServices.swift` | Ported to Headless, its semantic composition owner, because it depends on Agent. |
| `DurableFilesystem.swift` | Ported. |
| `OwnedResourceReconciliationService.swift` | Ported. |
| `SelectionAuthority.swift` | Ported. |
| `WorkspaceAuthority.swift` | Ported; RepoPromptC mutation calls inverted behind descriptor-relative POSIX operations. |
| `WorkspaceServices.swift` | Ported; CodeMap construction inverted behind `WorkspaceCodeMapBuilding`. |
| `Resources/canonical-workflows-v62.json` | Deleted; `RepoPromptShared/Workflows` is the sole compiled catalog. |

The journal/path-fence identity keeps the pre-extraction `device` + `inode` fields and adds
an optional birth-time fence when the platform exposes one. This is a compatibility-preserving
security adaptation required for equivalent macOS/Linux inode-reuse behavior: legacy JSON
without the field decodes and re-encodes without it, while new identities record the additive
field. Exact legacy and additive JSON snapshots make the persisted semantics explicit.

## Headless owner

| Prototype file | PR 2 disposition |
|---|---|
| `AgentComposerAttachmentStore.swift` | Ported over the narrow `ComposerAttachmentStore` capability. |
| `AgentComposerCatalogService.swift` | Ported over Model/Agent and `ComposerCatalogStore`. |
| `AgentSubmissionCoordinator.swift` | Ported over `AgentSubmissionStore`. |
| `AgentTranscriptPresentationService.swift` | Ported over `AgentTranscriptStore`. |
| `AgentTurnIntentCompiler.swift` | Ported. |
| `EventHub.swift` | Ported. |
| `HeadlessACPSessionUpdateNormalizer.swift` | Ported. |
| `HeadlessAskUser.swift` | Ported. |
| `HeadlessRunStatusCopy.swift` | Ported. |
| `ProjectSourceProvisioningService.swift` | Ported over Workspace capabilities; the anchored local Git runner is inverted behind `ProjectSourceGitRunning` and its process-backed implementation is deferred to PR 3. |
| `ProviderSettingsService.swift` | Ported; persistence is `ProviderSettingsStore`, and concrete vault/runtime/managed-auth/direct-provider edges are protocols. |
| `RepoPromptHeadlessAuthority.swift` | Ported as the established mutable authority over `RepoPromptAuthorityStore`; no local projection reducer. |
| `ServerSettingsService.swift` | Ported over `RepoPromptAuthorityStore` and explicit project-catalog adapter. |
| `SubagentPermissionResolver.swift` | Ported. |
| `WorkflowRepository.swift` | Ported over `WorkflowRepositoryStore`. |
| `ClaudeCompatibleLaunchResolution.swift` | **Deferred to PR 3**: executable/private-helper resolution. |
| `CodexDeviceAuthRuntime.swift` | **Deferred to PR 3**: provider launch/auth composition. |
| `CodexRepoPromptMCPConfig.swift` | **Deferred to PR 3**: helper/session launch configuration. |
| `DirectProviderRuntime.swift` | **Deferred to PR 3**: concrete provider transport composition. |
| `NativeProviderRuntimes.swift` | **Deferred to PR 3**: executable runtime composition. |
| `PortableProcessSupervisionPort.swift` | **Deferred to PR 3** with process composition. |
| `ProviderCLIAdapter.swift` | Concrete launch adapter deferred; its settings behavior is preserved by `ProviderRuntimeSettingsAdapting`. |
| `ProviderConnectionRuntime.swift` | **Deferred to PR 3**: connection/process composition. |
| `ProviderCredentialHTTPValidation.swift` | **Deferred to PR 3**: HTTP validation transport. |
| `ProviderSupervisor.swift` | **Deferred to PR 3**: process lifecycle composition. |
| `ValidatedProviderEgressTransport.swift` | **Deferred to PR 3**: network transport. |

`ProviderSettingsPorts.swift` is the explicit inversion boundary for the deferred concrete
runtime/vault/authentication implementations. `AuthorityStoreCapabilities.swift` exposes
service-specific persistence capabilities; `AuthorityStoreOperations.swift` is only the
compatibility aggregate used by the central established authority, preserving prototype
operation/default behavior without importing SQLite or a concrete repository.

The committed prototype tree contains **26**, not 27, Headless files. The table above is the
complete `git ls-tree -r 45c42d65e444884d1681f4504c10d25dcb7d858a -- Sources/RepoPromptHeadlessRuntime`
result: 15 portable semantic files are extracted and 11 concrete launch, process, HTTP, or
network-composition files are explicitly deferred to PR 3. This corrects the audit's file-count
claim without using it to omit any plan-required owner.

## Runtime-model closure

The store-independent declaration closure formerly under
`Sources/RepoPromptServiceProtocol/*.swift` is single-sourced under
`RepoPromptRuntimeModel/ServiceModel`. The extraction preserves raw values, defaults,
Codable behavior, provider settings, permissions, state snapshots, commands, receipts,
events, and reconciliation values. `AuthorityStoreRecords.swift` contains persistence
records required by the authority port but no SQLite behavior. PR 3 retains and maps actual
HTTP/authentication envelopes at the Server boundary.

The committed prototype closure contains 30 files. PR 2 retains the 27 genuinely portable
semantic files:

`AdvancedServerSettingsDTOs.swift`, `AgentModelSettingsDTOs.swift`, `Commands.swift`,
`ComposerWireDTOs.swift`, `ContextBuilderSettingsDTOs.swift`,
`DirectAgentPermissionSettingsDTOs.swift`, `DirectProviderSettingsDTOs.swift`,
`DurabilityDTOs.swift`, `Errors.swift`, `Events.swift`, `Identifiers.swift`,
`MCPClientIdentity.swift`, `MCPDisabledToolsSettingsDTOs.swift`, `MCPModelPresetDTOs.swift`,
`ProviderConnectionDTOs.swift`, `ProviderSettingsDTOs.swift`,
`SavedPromptDTOs.swift`, `SelectionPresetDTOs.swift`, `ServerSettingsDTOs.swift`,
`Snapshots.swift`, `SubagentPermissionSettingsDTOs.swift`,
`TranscriptPresentationWireDTOs.swift`, `WireDTOs.swift`, `WorkflowPresetDTOs.swift`,
`WorkflowSettingsDTOs.swift`, `WorkspaceApprovalSettingsDTOs.swift`, and `WorkspaceDTOs.swift`.

`CanonicalSigning.swift` is excluded because canonical envelope serialization and transport
authentication belong to future `RepoPromptServiceProtocol`; `PortalDesktopSettingsDTOs.swift`
and `PortalSessionDTOs.swift` are excluded because portal request/projection ownership is also
Server protocol scope. `ConnectProviderRequest`, the provider auth-flow/browser projection
DTOs, and `ServiceEventSigningKey` are likewise deferred. Headless preserves the established
credential and managed-auth behavior through non-Codable runtime ports, while its catalog
uses only the semantic `authenticationConfigured` state required by portable admission. The
prototype's key-helper/workload-identity connect branches reject `capabilityMissing` before
reading their wire-only structured fields, so PR 2 does not invent portable replacements.
Shared owns the narrower cross-platform SHA-256 content digest used by portable runtime
identities, so RuntimeModel has no Crypto edge. Portable fixture and RuntimeModel tests cover decoding,
default, raw-value, and provider-setting compatibility; exhaustive Agent tests cover every
provider, permission, effort/settings path, resource scope, and malformed-input rejection.
No dead Desktop projection API or test-only parity bridge is retained.

## Explicit exclusions

PR 2 contains no `RepoPromptHeadlessLaunchBridge`, private-helper lookup, Server package or
Server product graph, `makeServerPackage`, or `REPOPROMPT_SERVER_ONLY`. It also contains no
`InMemoryAuthorityStore`, `RepoPromptHeadlessAuthority.apply`, committed-projection reducer,
or proposal/application invariant. Those transition-state-machine changes belong to PR 5.
