# Headless Core Architecture Lock

Status: Item 0 architecture record, 2026-06-04. This document reserves a future boundary and inventories later moves. It does **not** create a core target, add a headless executable, move runtime ownership, or change app-proxy behavior.

## Locked target graph

The migration uses a library-first host architecture. The macOS app will embed the reusable core in-process, while a separately packaged headless executable will instantiate the same core without requiring `RepoPrompt.app` to be installed or running.

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

Item 0 reserves these future source roots. They intentionally do not exist yet and are not added to `Package.swift` in this item:

| Reserved target or product | Reserved source root | Responsibility |
| --- | --- | --- |
| `RepoPromptCore` library | `Sources/RepoPromptCore` | UI-independent host/session API, workspace state, transport-neutral MCP runtime, tool providers, neutral policies, and platform contracts |
| `RepoPromptCoreMacOS` library | `Sources/RepoPromptCoreMacOS` | FSEvents, POSIX/Darwin process and socket implementations, Keychain, code-signing inspection, peer verification, and macOS adapters |
| `RepoPromptSyntaxCBridge` target | `Sources/RepoPromptSyntaxCBridge` | Narrow Tree-sitter declarations required by core syntax parsing without the app target's bridging header |
| `repoprompt-headless` executable | `Sources/RepoPromptHeadless` | Independent direct-stdio host composition, secure configuration commands, and doctor flow |

Existing owners remain unchanged during Item 0:

| Existing target | Current responsibility retained during Item 0 |
| --- | --- |
| `RepoPrompt` | SwiftUI/AppKit shell plus today's monolithic app runtime |
| `RepoPromptMCP` / `repoprompt-mcp` | Existing app-bundled socket proxy, interactive client, and exec client |
| `RepoPromptShared` | Narrow app/CLI MCP control-message and POSIX descriptor support seams |

Keep `platforms: [.macOS(.v14)]` during this migration. The first milestone is a standalone Swift-toolchain core boundary, not a Linux or Windows product claim.

## Locked ownership rules

`RepoPromptCore` must not import `AppKit`, `SwiftUI`, `Sparkle`, `KeyboardShortcuts`, `CoreServices`, `Security`, or `Darwin`. It must not reference app-owned runtime types such as `WindowState`, `WindowStatesManager`, `NSApplication`, or `NSWorkspace`. Avoid `OSLog` in core unless a neutral logging facade is introduced.

The core runtime abstraction is a window-independent multi-session host. App windows and MCP contexts project onto core sessions; windows do not own reusable runtime state. The public compatibility schema continues to use `window_id` during the migration. Existing app routing also has a hidden strong per-call `_windowID` override; these two spellings are related compatibility surfaces but are not interchangeable in every code path.

The current app-bundled proxy remains separate from the future direct-stdio host. Do not turn `repoprompt-mcp` into the standalone host and do not make the migration depend on a shared-daemon IPC protocol.

## App-proxy compatibility guarantees

Later items may centralize or move implementations only if these behaviors remain intact:

| Contract | Locked current behavior |
| --- | --- |
| App bootstrap endpoint | `/tmp/repoprompt-ce-mcp-{uid}/repoprompt-ce-6.sock` |
| Socket namespace version | `6` |
| Bootstrap protocol version | `2` |
| Request encoding | newline-delimited JSON with `type`, `sessionToken`, `clientPid`, optional `clientName`, and `protocolVersion` |
| Response encoding | newline-delimited JSON with `type`, optional `reason`, and optional `errorCode` |
| Bootstrap error-code raw values | `approval_denied`, `protocol_version_mismatch`, `server_not_ready`, `server_unavailable`, `connection_limit_reached`, `capacity_exceeded`, `session_blocked`, and `client_cooldown` |
| App bundle helper | regular executable at `Contents/MacOS/repoprompt-mcp` |
| Compatibility helper links | `Contents/Resources/repoprompt-mcp -> ../MacOS/repoprompt-mcp` and `Contents/Resources/bin/repoprompt-mcp -> ../../MacOS/repoprompt-mcp` |
| App packaging | embed and sign the app proxy helper only; never embed the independently packaged standalone host |
| CLI admission | spoofable `RepoPrompt CLI` names bypass the generic allow-list only after trusted peer PID lookup and canonical bundled-executable path equality |
| Persisted MCP allow-list | entries matching the trimmed, case-sensitive `RepoPrompt CLI` prefix are removed and cannot be persisted |

The app and CLI currently compile mirrored bootstrap DTO and endpoint implementations. Item 1 may centralize only verified-equivalent wire contracts into `RepoPromptShared`; Item 0 pins their present behavior first.

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

## Standalone security defaults reserved for later work

These are locked future constraints, not implemented Item 0 behavior:

- `repoprompt-headless` serves direct MCP over stdin/stdout and must not connect to or bind the app-proxy socket.
- Standalone operation must not launch `RepoPrompt.app`, require `Bundle.main`, reuse app workspace persistence implicitly, or reuse app secrets implicitly.
- The default standalone profile root is separate:

  ```text
  ~/Library/Application Support/RepoPrompt CE/Headless/
    config.json
    Workspaces/
  ```

- Standalone secure storage uses a separate namespace and noninteractive reads while serving. Secret writes require explicit terminal commands.
- Root access fails closed: resolve symlinks, use URL-component containment, reject workspace operations outside configured roots, and start unbound when no roots are configured.
- Mutation and automation permissions default to `false`:

  | Permission | Default |
  | --- | --- |
  | `write_files` | `false` |
  | `vcs_write` | `false` |
  | `launch_agents` | `false` |
  | `export_outside_state_directory` | `false` |

- The first standalone safe profile is read-oriented. Mutation, VCS-write, broader export, oracle, Context Builder, and Agent Mode capabilities remain operation-gated.

## Concurrency lock for later implementation

| Component | Required isolation |
| --- | --- |
| `RepoPromptCoreHost`, `RepoPromptCoreSession`, `WorkspaceSessionController`, `MCPRuntimeSessionRegistry`, `MCPServiceRegistry` | `@MainActor` |
| `WorkspaceFileContextStore`, `WorkspaceSearchService`, `MCPConnectionRuntime`, `MCPToolDispatchEngine` | actor |
| macOS FSEvents callbacks | dedicated dispatch queue bridged into async streams consumed by actors |
| app UI adapters | `@MainActor` |
| standalone stdio read/write pumps | independent tasks; serialize stdout protocol writes and send diagnostics only to stderr |

## Move inventory

This is a future ownership inventory only. `move`, `split`, `stay`, and `audit` describe later work; Item 0 does not perform the disposition.

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
| `Sources/RepoPrompt/Infrastructure/MCP/AppShared/MCPFilesystemConstants.swift` and `Sources/RepoPromptMCP/Shared/MCPFilesystemConstants.swift` | `RepoPromptShared` + local adapters | split in Item 1 | Centralize neutral endpoint derivation only; keep `getuid()`, logging, directory creation, and app event-directory policy local |
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
| Syntax declarations | syntax-only residual in `RepoPrompt-Bridging-Header.h` | deferred narrow syntax bridge target | Existing grammar entry points and scanner fallback remain unchanged. |

## Closed Item 4 portability ledger

| Topic | Classification | Exact disposition |
| --- | --- | --- |
| Combine | mixed: shell-only plus explicitly deferred runtime seam | Keep SwiftUI `ObservableObject` / `@Published` publications shell-owned. The filesystem publisher and workspace ingress subscription remain transitional inside the monolithic target; Item 5 replaces movable runtime multi-observer channels with bounded per-subscriber async streams before placing them in `RepoPromptCore`. |
| CryptoKit | core-safe hashing, with standalone toolchain verification deferred | Current movable uses are deterministic SHA-256 hashing rather than secret persistence or UI policy. Keep them in the reusable inventory; if standalone Swift tooling rejects `CryptoKit`, Item 5 introduces a narrow digest helper backed by the package toolchain rather than an Apple adapter leak. |
| OSLog / `os` | shell-only diagnostics or injected logging facade | Keep signposts and app diagnostics outside reusable runtime ownership. Movable logging sites must consume a neutral logging port during Item 5; `RepoPromptCore` must not import `OSLog` or `os`. |
| `FoundationNetworking` | explicitly deferred capability seam | The first safe headless profile does not promote AI/network capability ownership. When networking is promoted, reusable Foundation HTTP code gains conditional `FoundationNetworking` imports where standalone Swift toolchains require them; no macOS adapter is implied. |
| Application Support defaults | adapter-owned embedded-app policy | Reusable stores receive state-directory URLs. Existing embedded-app Application Support defaults stay shell/adapter-owned; the standalone host later receives its separate `Headless/` profile URL explicitly. |
| `UserDefaults` | shell-only preferences or injected configuration | Reusable runtime code must not read `.standard`. Existing preference reads remain transitional in the monolithic target and move to shell-owned configuration snapshots or standalone JSON profile persistence as the Item 5 boundary is enforced. |

## Exact seams deferred to Item 5

- Create `RepoPromptCore`, `RepoPromptCoreMacOS`, and `RepoPromptSyntaxCBridge` targets and physical roots atomically; update `Package.swift` only then.
- Move staged neutral contracts into `RepoPromptCore`, move macOS FSEvents, POSIX launcher, Keychain/signing policy, app-proxy socket files, peer verification, and ancestry lookup into `RepoPromptCoreMacOS`, and remove transitional macOS default arguments from reusable initializers in favor of composition-root injection.
- Split remaining app-proxy connection/runtime policy so raw descriptors and Unix transport lifecycle remain adapter-owned while neutral routing/admission policy becomes reusable.
- Promote process-launcher call-site injection only when the corresponding capability owners move; Item 4 intentionally preserves the existing static compatibility facade.
- Replace movable Combine runtime channels with bounded async-stream seams, introduce a core logging port, and inject state-directory/configuration snapshots instead of carrying `UserDefaults.standard` or embedded-app Application Support defaults into core.
- Create `RepoPromptSyntaxCBridge`, move the syntax-only residual declarations out of `RepoPrompt-Bridging-Header.h`, wire grammar products narrowly, and remove the target-wide bridging-header setting.
- Run standalone Swift-toolchain compilation after the physical boundary lands and decide whether CryptoKit digest calls need a package-backed helper and where conditional `FoundationNetworking` imports belong.
- Do not create the standalone host, package/install scripts, or headless commands until Items 6–7.

## Advisory boundary guardrail

`Scripts/core_boundary_guardrails.sh` is intentionally report-only during Item 0. It scans `Sources/RepoPromptCore` only if that future root exists, reports forbidden imports and app-owned references, and reports any app-packaging reference to standalone command names. Missing `Sources/RepoPromptCore` is expected and succeeds. Findings are advisory until the physical boundary lands in Item 5.

The existing `Scripts/source_layout_guardrails.sh` remains responsible for shared `MCPControlMessages.swift` single-sourcing and the narrow `TreeSitterScannerSupport` compatibility target.

## Item 0 characterization coverage

| Compatibility surface | Characterization owner |
| --- | --- |
| Bootstrap JSON, versions, exact socket path, temporary app/CLI mirror contract | `Tests/RepoPromptTests/MCP/Control/MCPBootstrapContractCharacterizationTests.swift` |
| Logical-context priority and tools/call source-order markers | `TabContextRoutingTests.swift`, `MCPResolvedToolDispatchSourceGuardTests.swift` |
| Bundled CLI path verification and MCP allow-list sanitization | `ServerControllerAdmissionTests.swift` |
| Embedded app helper path and compatibility symlinks | `Scripts/validate_embedded_mcp_helper_layout.sh`, `Scripts/test_release_tooling.py` |
| Advisory boundary wiring | `make guardrails`, `make dev-guardrails`, and `./conductor guardrails` |

## Explicitly deferred work

Items 1–7 remain deferred. In particular, Item 0 does not centralize bootstrap contracts, replace singleton/window hot-path ownership, extract sessions, isolate Apple implementations, create SwiftPM boundaries, add a standalone host, or package/install headless artifacts.
