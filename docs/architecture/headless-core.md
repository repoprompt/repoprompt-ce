# Headless Core Architecture Lock

Status: Phase 2 Slice 3 ownership is integrated and undergoing convergence hardening as of 2026-06-08. Shared remains platform-neutral with one narrow CryptoKit hashing exception; Core owns canonical app workspace/session authority plus the neutral filesystem, catalog, path, search, selection, slices, token-accounting, codemap, syntax, factual prompt rendering/assembly, and workspace projection closure. CoreMacOS owns directory listing and FSEvents watching. The app constructs and consumes the Core runtime through app-only observation, UI, prompt, and policy adapters; it must not retain parallel canonical state. Phase 0 characterization artifacts remain frozen at their original historical baseline, while the complete headless source/test trees are separately locked at the reviewed post-remediation state-security baseline. Headless still owns its parallel v1 runtime. Full shared-runtime convergence remains incomplete until Phase 3 explicitly adopts Core from headless and converges the deferred MCP/provider surface.

## Locked target graph

The target graph below is the convergence destination. Today the app constructs the mature shared workspace/file-context runtime from Core and CoreMacOS through app-owned adapters, while the separately packaged headless executable uses its own reviewed-baseline-locked v1 runtime without requiring `RepoPrompt.app` to be installed or running.

```text
                           RepoPromptShared
                 protocol DTOs · framing · socket contract
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
              RepoPromptCore             RepoPromptCoreMacOS
       sessions · workspaces · MCP      FSEvents · POSIX · Keychain
       dispatch · neutral policies      code signing · peer PID lookup
                    │                           │
        ┌───────────┴──────────┐       ┌────────┴─────────┐
        │                      │       │                  │
   RepoPrompt.app       repoprompt-headless        repoprompt-mcp
  AppKit/SwiftUI shell     direct stdio MCP       existing app proxy
```

The current package graph contains bounded contract/adapter roots plus the standalone executable and its separate package/install/smoke boundary:

| Reserved target or product | Reserved source root | Responsibility |
| --- | --- | --- |
| `RepoPromptCore` internal target | `Sources/RepoPromptCore` | Canonical persisted workspace/session authority plus neutral filesystem/catalog/path/search/selection/slices/token/codemap/syntax runtime and platform contracts |
| `RepoPromptCoreMacOS` internal target | `Sources/RepoPromptCoreMacOS` | Workspace directory listing, FSEvents, POSIX process/descriptor-write, Keychain, code-signing inspection, peer verification, and macOS adapters |
| `RepoPromptPOSIXSupport` internal target | `Sources/RepoPromptPOSIXSupport` | Shared close-on-exec and socket-shutdown helpers used by current POSIX importers |
| `RepoPromptSyntaxCBridge` target | `Sources/RepoPromptSyntaxCBridge` | Narrow Tree-sitter declarations and grammar/scanner linkage without an app target-wide bridging header |
| `repoprompt-headless` executable | `Sources/RepoPromptHeadless` | Independent direct-stdio JSON-RPC host with fail-closed config/state/root policy, permission defaults, terminal doctor/config commands, the read-oriented safe MCP profile, and separate package/install/smoke lane |

Existing app/proxy owners remain compatible through Phase 2 Slice 3:

| Existing target | Current responsibility retained during Item 0 |
| --- | --- |
| `RepoPrompt` | SwiftUI/AppKit shell, sole constructor/consumer of the Slice 2 runtime, and owner of composition, observation, mutation, diagnostics, readiness, UI conversion, MCP, and prompt projection/policy adapters |
| `RepoPromptMCP` / `repoprompt-mcp` | Existing app-bundled socket proxy, interactive client, and exec client |
| `RepoPromptShared` | Platform-neutral app/CLI MCP wire contracts; only `MCP/JSONRPCBridgeLedger.swift` may import `CryptoKit` for deterministic SHA-256 frame correlation |

Keep `platforms: [.macOS(.v14)]` during this migration. The first milestone is a standalone Swift-toolchain core boundary, not a Linux or Windows product claim.

## Phase 2 Slice 3 runtime lock

- `RepoPromptCore.WorkspaceSessionController` remains the sole mutable workspace/session authority; `WorkspacePersistenceWriter` and `EmbeddedWorkspaceCodecV1` preserve explicit-write-only app-v1 persistence and keep canonical-v2 writes inactive.
- Core owns the canonical neutral filesystem/catalog/path/search/selection/slices/token/codemap/syntax closure, including accepted-ingress/watermark/unload barriers and bounded search admission/backpressure.
- `RepoPromptCoreMacOS` owns workspace directory listing and FSEvents watching behind injected Core contracts. Core has no default macOS watcher construction or Application Support discovery.
- `RepoPromptEmbeddedWorkspaceRuntimeFactory` is the sole production factory. The app supplies CoreMacOS listing/watching plus app mutation, diagnostics, readiness, observation, cache-root, and view-model adapters.
- The temporary Slice 1 `WorkspaceSessionSelectionForwarder` and obsolete app runtime source paths are deleted; app behavior is adapted rather than duplicated.
- Core owns deterministic factual rendering/assembly plus workspace selection, token, code-structure, and context projections. The app retains entry conversion, artifact classification, live token-fact materialization, display/codemap mapping, Git fallback, prompt/chat/clipboard policy, Context Builder/MCP envelopes, MCP provider/catalog/DTO/formatter/dispatch ownership, and app-proxy transport through explicit adapters such as `WorkspacePromptProjectionAdapter`.
- Phase 0 fixtures plus the original characterization document/script remain byte-for-byte frozen at `48a335e`; they continue to describe the historical characterization event rather than current source provenance.
- The complete `Sources/RepoPromptHeadless/**` and `Tests/RepoPromptHeadlessTests/**` trees are independently locked by `Scripts/Fixtures/shared-runtime-headless-reviewed.sha256` after review of the standalone state-directory, state-file, and lock-file security remediation. Headless does not construct the new runtime.
- The active `Scripts/test_shared_runtime_phase2_boundaries.py` check enforces authority, no-read-rewrite, runtime ownership, sole construction, importer-backed dependencies, canonical single-source owners, app-adapter delegation, the immutable Phase 0 artifacts, the complete reviewed headless manifest, and the neutral prompt/projection boundary. `Scripts/test_shared_runtime_phase2_slice1_boundaries.py` remains a historical Slice 1 authority/Phase 0 checkpoint and is not a current headless-baseline owner.

## Locked ownership rules

`RepoPromptCore` must not import `AppKit`, `SwiftUI`, `Sparkle`, `KeyboardShortcuts`, `CoreServices`, `Security`, `Darwin`, `OSLog`, or `os`. It must not own Apple signposts or reference app-owned runtime types such as `WindowState`, `WindowStatesManager`, `NSApplication`, or `NSWorkspace`. Platform-neutral counters and elapsed-duration metrics remain allowed.

The core runtime abstraction is a window-independent multi-session host. App windows and MCP contexts project onto core sessions; windows do not own reusable runtime state. The public compatibility schema continues to use `window_id` during the migration. Existing app routing also has a hidden strong per-call `_windowID` override; these two spellings are related compatibility surfaces but are not interchangeable in every code path.

The current app-bundled proxy remains separate from the future direct-stdio host. Do not turn `repoprompt-mcp` into the standalone host and do not make the migration depend on a shared-daemon IPC protocol.

## App-proxy compatibility guarantees

Later items may centralize or move implementations only if these behaviors remain intact:

| Contract | Locked current behavior |
| --- | --- |
| App bootstrap endpoints | Debug: `/tmp/repoprompt-ce-mcp-{uid}/repoprompt-ce-D-7.sock`; release: `/tmp/repoprompt-ce-mcp-{uid}/repoprompt-ce-7.sock` |
| Socket namespace version | `7`, with build flavor encoded in the socket name |
| Bootstrap protocol version | `2` |
| Request encoding | newline-delimited JSON with `type`, `sessionToken`, `clientPid`, optional `clientName`, and `protocolVersion` |
| Response encoding | newline-delimited JSON with `type`, optional `reason`, and optional `errorCode` |
| Bootstrap error-code raw values | `approval_denied`, `protocol_version_mismatch`, `server_not_ready`, `server_unavailable`, `connection_limit_reached`, `capacity_exceeded`, `session_blocked`, and `client_cooldown` |
| App bundle helper | regular executable at `Contents/MacOS/repoprompt-mcp` |
| Compatibility helper links | `Contents/Resources/repoprompt-mcp -> ../MacOS/repoprompt-mcp` and `Contents/Resources/bin/repoprompt-mcp -> ../../MacOS/repoprompt-mcp` |
| App packaging | embed and sign the app proxy helper only; never embed the independently packaged standalone host |
| CLI admission | spoofable `RepoPrompt CLI` names bypass the generic allow-list only after trusted peer PID lookup and canonical bundled-executable path equality |
| Persisted MCP allow-list | entries matching the trimmed, case-sensitive `RepoPrompt CLI` prefix are removed and cannot be persisted |

The app and CLI now consume the bootstrap DTOs and flavor-aware filesystem identity centralized in `RepoPromptShared`. Keep those shared contracts single-sourced and platform-neutral while later runtime ownership moves: `MCPFilesystemIdentity` derives the v7 debug/release endpoints from an explicit user ID, and the app and `RepoPromptMCP` adapters resolve `getuid()` locally.

## Command surfaces and managed paths

Slice 5C keeps the app proxy and standalone host as separate command families:

| Command | Backing executable | Transport/state | Validation purpose |
| --- | --- | --- | --- |
| `rpce-cli` / `rpce-cli-debug` | app-bundled `RepoPrompt.app/Contents/MacOS/repoprompt-mcp` | Connects to the running app bootstrap socket and uses app windows, workspaces, approvals, and app secure-storage policy | App-proxy MCP behavior and live app integration |
| `rpce-headless` / `rpce-headless-debug` | independently staged `HeadlessTools/{Release,Debug}/repoprompt-headless` | Direct stdio JSON-RPC; uses `~/Library/Application Support/RepoPrompt CE/Headless/` plus a separate secure-storage namespace; never launches or connects to `RepoPrompt.app` | Standalone safe read-oriented MCP behavior |

Managed standalone links are intentionally outside the app bundle:

```text
/usr/local/bin/rpce-headless-debug
  -> ~/Library/Application Support/RepoPrompt CE/repoprompt_headless_debug
  -> ~/Library/Application Support/RepoPrompt CE/HeadlessTools/Debug/repoprompt-headless

/usr/local/bin/rpce-headless
  -> ~/Library/Application Support/RepoPrompt CE/repoprompt_headless
  -> ~/Library/Application Support/RepoPrompt CE/HeadlessTools/Release/repoprompt-headless
```

`Scripts/package_app.sh` remains the app-bundle owner and must not mention standalone command names. `Scripts/package_headless.sh`, `Scripts/install_headless_cli.sh`, and `Scripts/smoke_headless_mcp.sh` own standalone packaging, managed links, and direct-stdio smoke validation.

### Current routing priority

Preserve the current `tools/call` routing order while runtime ownership changes later:

1. Logical `context_id` / legacy `_tabID` pre-resolution where applicable.
2. Hidden `_windowID` strong per-call override.
3. Existing connection-to-window mapping.
4. Same-client reusable-window mapping for a replacement or new connection.
5. Same-process live-run affinity.
6. Persisted token-backed affinity.
7. Single-window fallback to the first MCP-enabled window under the existing effective multi-window policy.
8. Multi-window guidance failure when selection remains unresolved.
9. Run-scoped tab rebind fallback, then legacy tab-binding compatibility, before invocation.

`MCPBindingResolver` uses the matching logical-context subset of that order: requested window, existing mapping, same-client reuse, live-run affinity, persisted affinity, only-hosting-window fallback, then ambiguity failure.

## Standalone security defaults and Slice 5C status

Slices 5A-5C implement these locked constraints for the first standalone profile:

- `repoprompt-headless` serves direct MCP over stdin/stdout and must not connect to or bind the app-proxy socket.
- Standalone operation must not launch `RepoPrompt.app`, require `Bundle.main`, reuse app workspace persistence implicitly, or reuse app secrets implicitly.
- The default standalone profile root is separate:

  ```text
  ~/Library/Application Support/RepoPrompt CE/Headless/
    config.json
    Workspaces/
    Exports/
  ```

- Standalone secure storage uses a separate namespace and noninteractive reads while serving. Secret writes require explicit terminal commands.
- Root access fails closed: resolve symlinks, use URL-component containment, reject workspace operations outside configured roots, and start unbound when no roots are configured.
- Standalone state directories are owner-only (`0700`), persisted state and lock files are owner-only (`0600`), and descriptor-relative `O_NOFOLLOW`/`O_CLOEXEC` access keeps reads, atomic replacements, and locks anchored to the validated state root while rejecting unsafe file types, owners, links, and path replacement races.
- Mutation and automation permissions default to `false`:

  | Permission | Default |
  | --- | --- |
  | `write_files` | `false` |
  | `vcs_write` | `false` |
  | `launch_agents` | `false` |
  | `export_outside_state_directory` | `false` |

- The first standalone safe profile is read-oriented and exposes only `bind_context`, constrained `manage_workspaces`, `manage_selection`, `workspace_context`, `get_file_tree`, `get_code_structure`, `read_file`, `file_search`, and `prompt`.
- Mutation, VCS-write, broader export, oracle, Context Builder, Agent Mode, app settings, and app lifecycle capabilities remain omitted or operation-gated in standalone v1.
- Slice 5C packaging validates this profile with `Scripts/smoke_headless_mcp.sh` over direct stdio: initialize, `tools/list`, `read_file`, `file_search`, export permission rejection, gated-tool rejection, and shutdown.

## Phase 0 regenerated move inventory

This current-owner inventory supersedes the historical Item 0 path table below for implementation planning. It records the frozen `487cd71` checkout without moving any file in Phase 0.

| Current owner/path family | Future destination/disposition | Phase 0 evidence |
| --- | --- | --- |
| `Sources/RepoPrompt/Infrastructure/Core/RepoPromptCoreHost.swift`; neutral MCP service/tool/runtime registries under `Infrastructure/MCP` | `RepoPromptCore/Runtime`; rename window-scoped reusable abstractions to session-scoped | `RepoPromptCoreHostLifecycleTests`, `MCPRuntimeRegistryTests`, dispatch-source guards |
| `Features/Workspaces/WorkspaceModel.swift`, `Features/Workspaces/Core/WorkspaceRepository.swift`, neutral workspace session/controller state and Codable dependencies | `RepoPromptCore/Workspaces`; app ObservableObject/AppStorage/folder-picker adapters remain in `RepoPrompt` | app-v1 Phase 0 fixture plus repository/no-rewrite characterization |
| Neutral `Infrastructure/WorkspaceContext/**` indexing, path, search, selection, slices, token accounting, and store behavior | `RepoPromptCore/WorkspaceContext`; watcher factory and diagnostics injected, macOS mechanics remain in CoreMacOS | `WorkspaceFileContextStoreTests`, path/search/selection suites, accepted-ingress barrier tests |
| Neutral `Features/CodeMap/**`, `Infrastructure/SyntaxParsing/**`, and required PCRE/C/parser wrappers | `RepoPromptCore/CodeMap` and `RepoPromptCore/SyntaxParsing`; File/Folder view-model and AppKit presentation adapters remain app-owned | CodeMap goldens and parser/scanner compatibility tests |
| Neutral prompt assembly, workspace-context rendering, resolved tree, selection reply, and token accounting behavior | `RepoPromptCore` prompt/context ownership; `PromptFileEntry` view-model adapter remains app-owned | Phase 0 formatter snapshots and existing prompt/context tests |
| `MCPWindowToolCatalogService`, context/runtime/group/names/helpers, and safe file/selection/prompt providers | Core session MCP catalog/providers/dispatch after capability-facet split | independent nine-tool app descriptor/normalization/formatter snapshot |
| apply edits, file mutation, VCS/worktree, Oracle, Context Builder, ask-user, Agent Mode, settings, lifecycle, approval, wake/power | remain in `RepoPrompt` | capability omission ledger; no Phase 0 move |
| `Sources/RepoPromptPOSIXSupport/Descriptors/POSIXDescriptorSupport.swift` | stay in internal POSIX support | moved in Phase 1; descriptor/process characterization remains frozen |
| app `MacOSBootstrapSocketServer`, accepted-FD manager, Unix transport and socket mechanics | `RepoPromptCoreMacOS/MCP/AppProxy`; app admission/approval/limits/diagnostics/routing remain app-owned | bootstrap contract and socket ownership/order tests |
| `RepoPromptCorePlatformDependencies.swift` and static process facade | delete after watcher/process/storage/transport injection reaches real owners | process inheritance/SIGPIPE/failure tests |
| headless workspace models/store, resolver/catalog/search/codemap, registry and nine local tool implementations | replace with Core implementations, migrate v1 storage, then delete | headless-v1 fixture, descriptor/call snapshots, direct-stdio smoke |
| headless CLI, configuration/state paths/root policy/file lock, JSON-RPC adapter, stdio transport/writer/output | remain in `RepoPromptHeadless` | lifecycle tests and direct-stdio smoke |
| Core/CoreMacOS/SyntaxBridge implementation targets | package-internal targets only | public library products removed in Phase 1 |

The historical table remains below only as an audit record. Where it conflicts with this inventory or the convergence design, this section controls.

## Concurrency lock for later implementation

| Component | Required isolation |
| --- | --- |
| `RepoPromptCoreHost`, `RepoPromptCoreSession`, `WorkspaceSessionController`, `MCPRuntimeSessionRegistry`, `MCPServiceRegistry` | `@MainActor` |
| `WorkspaceFileContextStore`, `WorkspaceSearchService`, `MCPConnectionRuntime`, `MCPToolDispatchEngine` | actor |
| macOS FSEvents callbacks | dedicated dispatch queue bridged into async streams consumed by actors |
| app UI adapters | `@MainActor` |
| standalone stdio read/write pumps | independent tasks; serialize stdout protocol writes and send diagnostics only to stderr |

## Historical Item 0 move inventory

This inventory records the ownership plan captured before the bounded Item 5 split. It is retained for archaeology and does not override the regenerated Phase 0 inventory above. Its `Current path` column is historical unless a later section explicitly says a seam remains app-owned; the landed Item 5 roots and explicit deferrals below are authoritative.

### Workspace ownership

| Current path | Reserved owner | Disposition | Notes |
| --- | --- | --- | --- |
| `Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift` | `RepoPromptCore` | move | Workspace serialization, compose tabs, stored selections, and preset DTOs; classify `OSLog` during Item 4 |
| `Sources/RepoPrompt/Features/Workspaces/WorkspaceRootActions.swift` | `RepoPromptCore` | move | Root reorder and normalization helpers |
| `Sources/RepoPrompt/Features/Workspaces/WorkspaceSwitchSessionRegistry.swift` | `RepoPromptCore` | move | Active-session provider protocol, snapshots, and cancellation registry |
| `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceSaveDiagnostics.swift` | `RepoPromptCore` | move | Save and selection revision metadata; logging remains an Item 4 audit |
| `Sources/RepoPrompt/Features/Workspaces/WorkspaceSwitchSessionProviders.swift` | app shell/adapter | stay | Bridges workspace switching to oracle, Context Builder, and Agent Mode view models |
| `Sources/RepoPrompt/Features/Workspaces/WorkspaceSwitchingModels.swift` | `RepoPromptCore` + app shell/adapter | split | Foundation models are reusable; SwiftUI modifier and `@ObservedObject` bridge remain shell-only |
| `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift` | `RepoPromptCore` + app shell/adapter | split | Separate repository/controller behavior from `ObservableObject`, `@Published`, `@AppStorage`, overlays, folder picker, UI view-model, and window coupling |
| `Sources/RepoPrompt/Features/Workspaces/Views/` | app shell/adapter | stay | SwiftUI workspace presentation |

Routing-critical helpers currently nested in `WorkspaceManagerViewModel.swift` must be classified together during the split: `normalizedRepoPathsForComparison`, `repoPathsEquivalent`, `normalizedExactWorkspaceDirectorySet`, `loadableRepoPaths`, `exactWorkspaceMatches`, `supersetWorkspaceMatches`, `bindingCandidates`, `hasAnyWorkspaceMatch`, workspace path builders, file load/save helpers, `WorkspaceFileDecodeCache`, `WorkspaceDiskWriter`, compose-tab snapshot resolution, stored-selection rebasing, selection application, and save-metadata generation.

### MCP view-model and routing ownership

| Current path | Reserved owner | Disposition | Notes |
| --- | --- | --- | --- |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` | `RepoPromptCore` + app shell/adapter | split | Extract tool/session runtime; retain observable dashboard, approval overlay, external events, and AppKit activation in the app adapter |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+CopyPresets.swift` | `RepoPromptCore` | move | Preset parsing and DTO projection |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionCore.swift` | `RepoPromptCore` | move | Selection assembly, token helpers, path projection, and code-structure assembly |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionEngine.swift` | `RepoPromptCore` | move | Selection mutation logic |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionParsing.swift` | `RepoPromptCore` | move | Argument and line-range parsing |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+SelectionReply.swift` | `RepoPromptCore` | move | Selection replies and virtual prompt evaluation |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift` | `RepoPromptCore` + app shell/adapter | split | Session/tab affinity, run mappings, snapshots, and compatibility fallback; retain `WindowState` hooks in app adapters |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+TokenStats.swift` | `RepoPromptCore` | move | Token-stat DTO assembly |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel+WorkspaceContext.swift` | `RepoPromptCore` | move | Workspace-context and token-breakdown assembly |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPReadFileAutoSelectionCoordinator.swift` | `RepoPromptCore` | move | Runtime-neutral selection queue after session naming cleanup |
| `Sources/RepoPrompt/Infrastructure/MCP/ViewModels/HeadlessMode+MCP.swift` | `RepoPromptCore` | move | Neutral mode description helper |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPBindingResolver.swift` | `RepoPromptCore` | move | Logical context routing priority |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPToolArgsNormalizer.swift` | `RepoPromptCore` | move | Hidden selector normalization and compatibility fields |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift` | `RepoPromptCore` + `RepoPromptCoreMacOS` | split | Separate connection/routing policy and dispatch from listener lifecycle, transferred-FD ledger, socket health, and parent-PID inspection |
| `Sources/RepoPrompt/Infrastructure/MCP/ServerController.swift` | `RepoPromptCore` + `RepoPromptCoreMacOS` + app shell/adapter | split | Separate neutral coordination, macOS helper verification, and app approval/wake/power policy |
| `Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift` | `RepoPromptCore` + app shell/adapter | split/rename | Future `MCPContextRoutingService`; inject session lifecycle rather than app globals |
| `Sources/RepoPrompt/Infrastructure/MCP/ServiceRegistry.swift`, `Service.swift`, `WindowScopedService.swift` | `RepoPromptCore` | move/rename | Replace static and window-scoped concepts with instance-owned session registries |

### Window-tool providers

All current files under `Sources/RepoPrompt/Infrastructure/MCP/WindowTools/` are inventoried. Existing `Window` naming is compatibility-era naming; later items rename core concepts to session-scoped types.

| Current path | Reserved owner | Disposition |
| --- | --- | --- |
| `MCPFileToolProvider.swift` | `RepoPromptCore` | move |
| `MCPSelectionToolProvider.swift` | `RepoPromptCore` | move |
| `MCPPromptContextToolProvider.swift` | `RepoPromptCore` | move |
| `MCPGitToolProvider.swift` | `RepoPromptCore` | move |
| `MCPWorktreeToolProvider.swift` | `RepoPromptCore` | move |
| `MCPWorktreeToolProvider+Merge.swift` | `RepoPromptCore` | move |
| `MCPApplyEditsToolProvider.swift` | `RepoPromptCore` | move |
| `MCPContextBuilderToolProvider.swift` | `RepoPromptCore` | move |
| `MCPOracleToolProvider.swift` | `RepoPromptCore` | move |
| `MCPAskUserToolProvider.swift` | `RepoPromptCore` | move |
| `MCPAgentControlToolProvider.swift` | `RepoPromptCore` | move |
| `MCPAgentSessionControlToolProvider.swift` | `RepoPromptCore` | move |
| `MCPWindowToolCatalogService.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowToolContext.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowToolGroup.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowToolNames.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowToolRuntime.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowWorkspaceToolHelpers.swift` | `RepoPromptCore` | move/rename |
| `MCPWindowToolDependencies.swift` | `RepoPromptCore` + app shell/adapter | split into capability-specific ports |

Mutation, VCS-write, oracle, Context Builder, ask-user, and agent providers remain capability-gated. Inventorying them as reusable implementations does not expose them in the first standalone safe profile.

### App-proxy socket and shared-contract inventory

| Current path | Reserved owner | Disposition | Notes |
| --- | --- | --- | --- |
| `Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketServer.swift` | `RepoPromptCoreMacOS` | move | Darwin listener, bind/listen/accept, peer PID lookup, handshake I/O, and ownership transfer |
| `Sources/RepoPrompt/Infrastructure/MCP/BootstrapSocketConnectionManager.swift` | `RepoPromptCoreMacOS` | move | Accepted-FD app-proxy adapter; keep bundle metadata and app keepalive policy adapter-owned |
| `Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift` | `RepoPromptCoreMacOS` | move | Unix-socket lifecycle and read/write pumps |
| `Sources/RepoPrompt/Infrastructure/MCP/AppShared/NewlineDelimitedSocketReader.swift` | `RepoPromptCoreMacOS` | audit/move | App transport loop; share only verified-equivalent framing logic |
| `Sources/RepoPromptMCP/Shared/NewlineDelimitedSocketReader.swift` | `RepoPromptMCP` | audit/stay | Proxy transport loop; currently near-duplicate but not byte-identical to app copy |
| `Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPBootstrapMessages.swift` and `Sources/RepoPromptMCP/Shared/MCPBootstrapMessages.swift` | `RepoPromptShared` | centralize in Item 1 | Preserve DTO fields, protocol version `2`, timing, and raw error codes |
| `Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPFilesystemConstants.swift` and `Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift` | `RepoPromptShared` + local adapters | split in Item 1 | Centralize flavor-aware filesystem identity and endpoint derivation in `MCPFilesystemIdentity`; keep `getuid()`, logging, directory creation, and app event-directory policy local |
| `Sources/RepoPromptShared/MCP/MCPControlMessages.swift` | `RepoPromptShared` | stay | Already correctly single-sourced |
| `Sources/RepoPromptShared/MCP/POSIXDescriptorSupport.swift` | `RepoPromptShared` | stay | Already shared descriptor hardening |
| `Sources/RepoPromptMCP/main.swift`, `Interactive/InteractiveMCPClientSession.swift`, `Transports/BootstrapSocketMCPTransport.swift` | `RepoPromptMCP` | stay | Existing app proxy/client roles remain bundled and independently maintained |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPExternalClientEvent.swift`, `MCPExternalEventsMonitor.swift` | app shell/adapter | stay | App-facing diagnostics from CLI event files |

### Platform adapter inventory

| Current path or family | Reserved owner | Disposition | Notes |
| --- | --- | --- | --- |
| `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift` and FSEvents lifecycle helpers | `RepoPromptCore` + `RepoPromptCoreMacOS` | split | Keep coalescing, ignore evaluation, and deltas neutral; move CoreServices lifecycle and flag mapping |
| `Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift` | `RepoPromptCoreMacOS` | move behind core contract | Preserve pipes, `FD_CLOEXEC`, no-SIGPIPE handling, child signal restoration, and working-directory behavior |
| `Sources/RepoPrompt/Infrastructure/Process/CLIProcessRunner.swift` | app capability adapter; promotion deferred | stay/audit | Two direct `ProcessLauncher.spawn` calls |
| `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift` | app capability adapter; promotion deferred | stay/audit | One direct `ProcessLauncher.spawn` call |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/ClaudeCode/SDK/ClaudeNativeProcessSessionController.swift` | app capability adapter; promotion deferred | stay/audit | One direct `ProcessLauncher.spawn` call |
| `Sources/RepoPrompt/Infrastructure/AI/Providers/Codex/AppServer/CodexAppServerClient.swift` | app capability adapter; promotion deferred | stay/audit | One direct `ProcessLauncher.spawn` call |
| `Sources/RepoPrompt/Infrastructure/Process/ProcessRegistry.swift` and `SpawnedProcess` consumers | app capability adapter; promotion deferred | stay/audit | Review with Item 4 process isolation |

### Secure-store inventory

| Current path | Reserved owner | Disposition | Notes |
| --- | --- | --- | --- |
| `Sources/RepoPrompt/Infrastructure/Security/SecureKeyValueStorageBackend.swift` | `RepoPromptCore` + `RepoPromptCoreMacOS` + app composition | split | Move neutral protocol core-facing; keep factory, bundle marker, code-signing policy, and debug/release backend selection adapter-owned |
| `Sources/RepoPrompt/Infrastructure/Security/KeychainService.swift` | `RepoPromptCore` + `RepoPromptCoreMacOS` | split | Keep neutral access mode/reason and error semantics; move `SecItem*` implementation behind macOS adapter |
| `Sources/RepoPrompt/Infrastructure/Security/EphemeralSecureKeyValueStore.swift` | `RepoPromptCore` | move after decoupling | Neutral in-memory backend after decoupling from concrete Keychain error type |
| `Sources/RepoPrompt/Infrastructure/Security/SecureKeyService.swift` | `RepoPromptCore` | move | Neutral secure-string facade |
| `Sources/RepoPrompt/Infrastructure/Security/KeyManager.swift` | `RepoPromptCore` | move | Neutral cached provider-key facade |
| `Sources/RepoPrompt/Infrastructure/Security/RuntimeCodeSigningDetector.swift` | `RepoPromptCoreMacOS` | move | Apple Security code-signing inspection |
| `Sources/RepoPrompt/Infrastructure/Security/SecurityObfuscation.swift` | deferred | audit | Not part of the secure-store backend seam |

Existing app consumers remain adapter-owned until later review: `App/WindowStateComposition.swift`, `Features/Settings/ViewModels/APISettingsViewModel.swift`, `Features/AgentMode/Runtime/ProviderBindings/AgentPermissionSecureStore.swift`, `Infrastructure/AI/Providers/ClaudeCode/ClaudeCodeCompatibleBackendStore.swift`, and `ClaudeCodeLaunchEnvironmentResolver.swift`.

### Bridging-header dependency inventory

Item 4 narrowed `Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h` to a syntax-only transitional residual without editing `Package.swift`. Accidental target-wide declarations are gone: Apple APIs are source-local or adapter-owned, RepoPrompt C consumers import `RepoPromptC` directly, PCRE wrappers import `CSwiftPCRE2` directly, and `PathSearchIndex` consumes the published `RepoPromptC` ABI instead of local `@_silgen_name` shadows.

| Current Swift consumer | Item 4 disposition | Item 5 reserved owner |
| --- | --- | --- |
| `Sources/RepoPrompt/App/ApplicationSecurity.swift` | imports `Darwin` locally and owns the `PT_DENY_ATTACH` fallback value | app shell |
| `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+DirectoryEnumeration.swift` | removed unused `sysctlbyname("hw.ncpu", ...)` helper | n/a |
| `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift` | consumes injected `ProcessAncestryInspecting`; `MacOSProcessAncestryInspector` owns `sysctl` / `kinfo_proc` | split core/macOS adapter |
| `Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift` | still receives `tree_sitter_*` declarations from the narrowed header | `RepoPromptCore` via `RepoPromptSyntaxCBridge` |
| `Sources/RepoPrompt/Features/Search/SearchMatch.swift`, `SearchPathFiltering.swift`, `Infrastructure/FileSystem/GitignoreCompiler.swift`, `Infrastructure/Utilities/StringExtensions.swift`, `Infrastructure/WorkspaceContext/Search/RepoSearchBatchScorer.swift`, `Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift` | import `RepoPromptC` directly; string allocation helpers use narrow `repo_strdup` / `repo_free` wrappers | `RepoPromptCore` via direct `RepoPromptC` dependency |
| `Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2Error.swift`, `PCRE2JIT.swift`, `PCRE2Options.swift`, `PCRE2Regex.swift` | import `CSwiftPCRE2` directly | `RepoPromptCore` via direct `CSwiftPCRE2` dependency |

Syntax declaration strategy: keep the remaining grammar declarations in the current target-wide header through Item 4 so scanner/linker behavior is unchanged. Item 5 creates `RepoPromptSyntaxCBridge`, wires the grammar products to that narrow target, moves the declarations there, and removes the app bridging-header setting atomically with the SwiftPM split. `TreeSitterScannerSupport` remains unchanged.

### Test ownership inventory

| Current path | Reserved disposition |
| --- | --- |
| `Tests/RepoPromptTests/MCP/` | Split app-adapter tests from future reusable core MCP tests when physical targets land |
| `Tests/RepoPromptTests/WorkspaceContext/` | Move neutral workspace-context coverage with the core library test owner |
| `Tests/RepoPromptTests/Services/FileSystem/` | Split neutral filesystem behavior from macOS watcher-adapter coverage |
| `Tests/RepoPromptTests/Security/` | Split neutral secure-store facade coverage from Keychain and runtime-policy adapter coverage |
| `Scripts/test_release_tooling.py` and embedded-helper validators | Keep app-proxy packaging characterization with release tooling |

## Item 4 staged adapter isolation

Item 4 stages neutral contracts and macOS-owned implementations inside the existing monolithic `RepoPrompt` target. No future Item 5 target roots or `Package.swift` changes land yet.

| Boundary | Neutral staged contract | macOS-owned staged implementation | Preserved behavior |
| --- | --- | --- | --- |
| Filesystem watching | `Infrastructure/Core/Platform/FileSystemWatching.swift` | `Infrastructure/FileSystem/MacOS/MacOSFSEventsWatcher.swift` | Dedicated callback queue deep-copies native payloads and maps FSEvents flags before the existing mailbox, overflow recovery, ignore evaluation, scan coalescing, and delta generation run. |
| Process launching | `Infrastructure/Core/Platform/ProcessLaunching.swift` | `Infrastructure/Process/MacOS/POSIXProcessLauncher.swift` | Existing POSIX pipe/spawn semantics remain behind a compatibility facade while the injected adapter is available to staged host composition. |
| Secure storage | `Infrastructure/Core/Platform/SecureKeyValueStorageBackend.swift` | `Infrastructure/Security/MacOS/KeychainService.swift`, `AppSecureKeyValueStorageFactory.swift`, `RuntimeCodeSigningDetector.swift` | Neutral access modes and errors are separated from embedded-app Keychain/signing selection policy. |
| App-proxy socket boundary | `Infrastructure/MCP/Platform/MCPAppProxyTransportBoundary.swift` | `Infrastructure/MCP/AppProxy/` | Accepted sockets produce a normalized peer identity with trusted-socket versus handshake-fallback provenance. Only `LOCAL_PEERPID` is authorization input; the range-checked handshake PID is diagnostic metadata and admission fails closed when trusted socket credentials are unavailable. |
| Bundled-helper verification | `Infrastructure/MCP/Platform/BundledHelperPeerVerifying.swift` | `Infrastructure/MCP/PeerVerification/MacOSBundledHelperPeerVerifier.swift` | Bundle helper URL and peer PID are explicit verifier inputs; canonical symlink-aware executable matching is preserved. |
| Process ancestry | `Infrastructure/MCP/Platform/ProcessAncestryInspecting.swift` | `Infrastructure/MCP/PeerVerification/MacOSProcessAncestryInspector.swift` | Admission policy retains its ancestor walk while `sysctl` / `kinfo_proc` lookup moves to the adapter. |
| Syntax declarations | syntax-only residual removed during Item 5 | `Sources/RepoPromptSyntaxCBridge` | Existing grammar entry points and scanner fallback remain unchanged behind the narrow declaration shim. |

## Closed Item 4 portability ledger

| Topic | Classification | Exact disposition |
| --- | --- | --- |
| Combine | mixed: shell-only plus explicitly deferred runtime seam | Keep SwiftUI `ObservableObject` / `@Published` publications shell-owned. The filesystem publisher and workspace ingress subscription remain transitional inside the monolithic target; Item 5 replaces movable runtime multi-observer channels with bounded per-subscriber async streams before placing them in `RepoPromptCore`. |
| CryptoKit | core-safe hashing, with standalone toolchain verification deferred | Current movable uses are deterministic SHA-256 hashing rather than secret persistence or UI policy. Keep them in the reusable inventory; if standalone Swift tooling rejects `CryptoKit`, Item 5 introduces a narrow digest helper backed by the package toolchain rather than an Apple adapter leak. |
| OSLog / `os` | shell-only diagnostics or injected logging facade | Keep signposts and app diagnostics outside reusable runtime ownership. Movable logging sites must consume a neutral logging port during Item 5; `RepoPromptCore` must not import `OSLog` or `os`. |
| `FoundationNetworking` | explicitly deferred capability seam | The first safe headless profile does not promote AI/network capability ownership. When networking is promoted, reusable Foundation HTTP code gains conditional `FoundationNetworking` imports where standalone Swift toolchains require them; no macOS adapter is implied. |
| Application Support defaults | adapter-owned embedded-app policy | Reusable stores receive state-directory URLs. Existing embedded-app Application Support defaults stay shell/adapter-owned; the standalone host later receives its separate `Headless/` profile URL explicitly. |
| `UserDefaults` | shell-only preferences or injected configuration | Reusable runtime code must not read `.standard`. Existing preference reads remain transitional in the monolithic target and move to shell-owned configuration snapshots or standalone JSON profile persistence as the Item 5 boundary is enforced. |

## Phase 1 dependency boundary landed

The enforceable package boundary now includes:

- Package-internal `RepoPromptCore`, `RepoPromptCoreMacOS`, `RepoPromptPOSIXSupport`, and `RepoPromptSyntaxCBridge` targets; SwiftPM exposes only executable products.
- No `RepoPromptCore` dependency on `RepoPromptShared`, POSIX support, or native C/syntax targets until a real Core source imports them. Current app importers retain their direct native dependencies.
- A declaration-only Tree-sitter C shim with all fourteen entry points used by syntax parsing. Grammar products and `TreeSitterScannerSupport` now link through that shim; the app target-wide bridging header and unsafe flags are removed.
- Platform-neutral filesystem watching, process launching, secure-storage, workspace access/root policy, codec/repository/migration, session/capability, and opaque MCP admission contracts under `Sources/RepoPromptCore`.
- macOS FSEvents, POSIX launcher/descriptor-write support, Keychain, runtime signing, bundled-helper verification, and process-ancestry adapters under `Sources/RepoPromptCoreMacOS`.
- Enforced core-boundary guardrails that fail on forbidden platform/UI imports, embedded-app policy references, missing roots, or accidental standalone packaging references.

## Explicitly deferred seams after Phase 2 Slice 3

The canonical app workspace/file-context/prompt-projection runtime move is complete, but product convergence is not. These owners remain intentionally app-local until Phase 3 or later:

- App preset/conversation/VCS/clipboard policy, live view-model conversion, token-fact materialization, and prompt projection adaptation remain app-owned around the canonical Core services.
- MCP safe-tool providers, catalog, descriptor vocabulary, argument normalization, DTOs, text formatting, capability composition, and dispatch remain app-owned; Slice 2 does not establish headless parity or move product protocol ownership.
- App-proxy `MacOSBootstrapSocketServer`, accepted-FD connection management, Unix transport, app filesystem constants, admission/approval, routing, and lifecycle policy remain app-owned. Existing `repoprompt-mcp` behavior is unchanged.
- App mutation authorization, diagnostics/telemetry, readiness, Combine publication, UI/view-model conversion, Application Support/UserDefaults policy, and visible-app lifecycle remain adapters in `Sources/RepoPrompt`.
- The static `ProcessLauncher` facade remains in `RepoPromptCoreMacOS` while deferred app capabilities call it directly; promote call-site injection only with those capability owners.
- The independent headless safe profile remains locked to the reviewed hardened source/test manifest under `Sources/RepoPromptHeadless` and `Tests/RepoPromptHeadlessTests`; future adoption must be a separately characterized Phase 3 change and must not route through the app proxy or app bundle.

## Enforced boundary guardrail

`Scripts/core_boundary_guardrails.sh` requires Core, CoreMacOS, POSIXSupport, Shared, and SyntaxBridge roots; permits `CryptoKit` only in `Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift`, rejects every other non-Foundation Shared import plus all Darwin/POSIX ownership there, rejects forbidden platform/UI/app policy imports, all `os`/`OSLog` ownership, and Apple signpost tokens in Core, and continues to reject app-packaging references to standalone command names. `Scripts/source_layout_guardrails.sh` and `Scripts/test_shared_runtime_phase2_boundaries.py` lock canonical Core owner filenames, reject restored app-side readable-file/session-binding implementations, and require the explicit observation and prompt-projection adapters. The Phase 1 boundary retains the immutable Phase 0 artifacts at `48a335e`; the active Phase 2 boundary separately verifies the product/dependency graph, sole app factory, importer-backed native edges, and every path and byte in the reviewed hardened headless source/test manifest. Findings fail `make guardrails`.

The two baseline contracts are intentionally independent and have no path-level exemptions. `python3 Scripts/shared_runtime_headless_baseline.py --check` verifies the reviewed headless manifest. After a future complete-tree headless change is explicitly reviewed, `python3 Scripts/shared_runtime_headless_baseline.py --write` reproducibly advances only that manifest before commit; it does not rewrite or recharacterize Phase 0 artifacts.

`Scripts/source_layout_guardrails.sh` remains responsible for single-sourcing `MCPControlMessages.swift`, `MCPFilesystemIdentity.swift`, and `MCPBootstrapMessages.swift` under `RepoPromptShared`, plus the narrow `TreeSitterScannerSupport` compatibility target. It requires `Sources/RepoPromptHeadless`/`RepoPromptHeadless`/`repoprompt-headless` and rejects app UI, app bundle policy, or app-proxy socket references from the standalone source root.

## Item 0 characterization coverage

| Compatibility surface | Characterization owner |
| --- | --- |
| Bootstrap JSON, versions, exact v7 debug/release socket paths, and shared app/CLI wire contract | `Tests/RepoPromptTests/MCP/Control/MCPBootstrapContractCharacterizationTests.swift` |
| Logical-context priority and tools/call source-order markers | `TabContextRoutingTests.swift`, `MCPResolvedToolDispatchSourceGuardTests.swift` |
| Bundled CLI path verification and MCP allow-list sanitization | `ServerControllerAdmissionTests.swift` |
| Embedded app helper path and compatibility symlinks | `Scripts/validate_embedded_mcp_helper_layout.sh`, `Scripts/test_release_tooling.py` |
| Enforced boundary wiring | `make guardrails`, `make dev-guardrails`, and `./conductor guardrails` |

## Remaining deferred work

Phase 3 may converge catalog/provider/DTO/formatter/dispatch behavior and explicitly adopt Core from headless. Phase 3+ must also retire the reviewed-baseline-locked parallel headless v1 implementations through separately characterized migrations. Neither step may change app-proxy routing or standalone security/profile boundaries without new characterization. Readable-root expansion (including any future authorization of `~/.codex/prompts`) requires an explicit product/security policy decision; the install location alone is not read authorization.
