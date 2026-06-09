# Source Layout Ownership Map

Current as of 2026-06-08 after the Phase 2 Slice 3 ownership checkpoint. `RepoPromptCore` owns the canonical app-v1 workspace/session authority plus the neutral filesystem, catalog, path, search, selection, slices, token-accounting, codemap, syntax, factual prompt rendering/assembly, and workspace projection closure. `RepoPromptCoreMacOS` owns macOS directory listing and FSEvents watching. The app remains the only production constructor/consumer through app-owned composition, mutation, diagnostics, readiness, observation, UI, prompt, and policy adapters. The complete headless source/test trees are independently locked by the reviewed hardened manifest and do not construct this runtime.

## Current source tree shape

```text
Sources/
  RepoPrompt/
    App/                         # lifecycle, launch/configuration, commands, composition wiring, app notifications, root app views/view models
      Notifications/
      Sparkle/
      ViewModels/
      Views/
    Features/
      AgentMode/                 # Agent Mode UI, models, view models, onboarding, recommendations, and shared agent runtime ownership
        Runtime/Providers/       # provider/runtime enum and provider factory shared by Context Builder, Agent Mode, MCP, and recommendations
      Chat/                      # chat/oracle models, services, diff state, view models, and views
      CodeMap/                   # app codemap extraction/view-model adapters; neutral generation/models live in RepoPromptCore
      ContextBuilder/            # Context Builder product UI/runtime, view models, settings, prompts, budget defaults, and response-type mapping
      Diagnostics/               # app-integrated benchmark/debug/stress/diagnostic surfaces
      Prompt/                    # prompt UI, copy/prompt models, packaging, accounting, compact selected-files components, and view models
      Search/                    # product search adapters/models backed by WorkspaceContext search; no retired SearchFileTreeViewModel layer
      Settings/                  # settings models, view models, and views
      WorkspaceFiles/            # workspace root shell, selection, and file-list projection view models; no native tree visualization
      Workspaces/                # workspace manager UI and view models
    Infrastructure/
      AI/                        # AI provider/model/prompt/query substrate
        Prompts/Workflows/       # provider-neutral RepoPrompt workflow prompt catalog and renderers
      Concurrency/               # cross-cutting async primitives
      Diffing/                   # diff parsing/application/generation substrate
      FileSystem/                # app-only filesystem policy/adapters; neutral services live in RepoPromptCore and macOS listing/watching in RepoPromptCoreMacOS
      MCP/                       # app-side MCP infrastructure, app-local MCP helpers, and MCP view model adapters
      Networking/                # HTTP and decoding substrate
      Persistence/               # shared persistence helpers such as preset file storage
      Process/                   # process/CLI launch substrate
      Regex/                     # reusable regex adapters/toolkit
      Security/                  # keychain, signing, and secure storage
      SyntaxParsing/             # app-only syntax consumers/adapters; neutral parser/query ownership lives in RepoPromptCore
      UI/                        # reusable UI components, text/markdown/tooltip/mention substrate, UI services
      Utilities/                 # narrow generic utilities/extensions
      VCS/                       # git/VCS substrate
      WorkspaceContext/          # app observation, diagnostics, mutation, readiness, and view-model adapters over RepoPromptCore
    ThirdParty/                  # vendored SwiftPCRE2 wrapper
  RepoPromptCore/               # canonical workspace/session authority plus neutral filesystem, catalog, path, search, selection, slices, token, codemap, and syntax runtime
  RepoPromptCoreMacOS/          # macOS directory listing/FSEvents plus POSIX process, Keychain/signing, and peer-verification adapters
  RepoPromptPOSIXSupport/       # package-internal shared descriptor/socket helpers for MCP and CoreMacOS
  RepoPromptSyntaxCBridge/      # narrow Tree-sitter declaration/linkage shim; owns grammar/scanner dependencies
  RepoPromptShared/
    MCP/                         # platform-neutral app/CLI MCP wire contracts; one documented CryptoKit hashing exception
  RepoPromptHeadless/            # independent direct-stdio host, v1 profile/configuration, workspace runtime, and safe tool implementations
  RepoPromptMCP/                 # app-proxy MCP CLI implementation
  RepoPromptC/                   # C support target
  CSwiftPCRE2/                   # C PCRE2 target
  TreeSitterScannerSupport/      # narrow exact-snapshot JavaScript/Python scanner ABI fallback
Tests/
  RepoPromptTests/               # app/runtime XCTest tests, support, and fixtures
  RepoPromptHeadlessTests/       # standalone configuration, runtime, JSON-RPC, stdio-adapter, and safe-profile tests
  SharedRuntimeConvergenceFixtures/ # cross-target Phase 0 frozen fixtures and manifests
```

## Physical headless-core roots

[`headless-core.md`](headless-core.md) locks the library-first split. Phase 2 Slice 3 now enforces the reusable runtime, prompt/projection, and adapter substrate:

```text
Sources/
  RepoPromptCore/                # canonical workspace/session and neutral file/context/search/selection/codemap/syntax runtime
  RepoPromptCoreMacOS/           # Apple/Darwin directory listing, watcher, process, security, and peer adapters
  RepoPromptPOSIXSupport/        # shared POSIX descriptor/socket implementation support
  RepoPromptSyntaxCBridge/       # narrow Tree-sitter declaration shim
  RepoPromptHeadless/            # landed independent direct-stdio runtime; not yet a shared-Core consumer
```

SwiftPM advertises only the `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless` executable products. `RepoPromptCore`, `RepoPromptCoreMacOS`, `RepoPromptPOSIXSupport`, and `RepoPromptSyntaxCBridge` are package-internal targets. `RepoPromptHeadless` still has a separate v1 workspace/tool stack. Guardrails enforce Core ownership of the current runtime/prompt/projection closure, app-only construction, immutable Phase 0 artifacts, the complete reviewed hardened headless manifest, importer-backed native dependencies, and executable-only products.

Phase 2 Slice 2 moves the complete neutral filesystem/catalog/path/search/selection/slices/token/codemap/syntax closure to Core and deletes the temporary Slice 1 selection forwarder. `RepoPromptEmbeddedWorkspaceRuntimeFactory` is the sole production factory. The Slice 3 checkpoint adds neutral factual prompt rendering/assembly plus workspace selection, token, code-structure, and context projections in Core. App adapters retain Combine publication, UI/view-model conversion, app mutation policy, diagnostics and readiness integration, storage-root discovery, cache-root policy, artifact classification, display-path and codemap mapping, live token-fact materialization, Git fallback, prompt/chat/clipboard policy, and Context Builder/MCP envelopes. MCP provider/catalog/DTO/formatter/dispatch ownership, standalone-headless adoption, and canonical-v2 persistence remain deferred.

The legacy top-level layer buckets under `Sources/RepoPrompt` have been pruned and must not be recreated:

- `Models`
- `Notifications`
- `Services`
- `Shared`
- `Utils`
- `ViewModels`
- `Views`
- `Features/SynthaxParsing`
- `Features/Benchmark`

## Post-native-tree terminology

The old native file-tree visualization is no longer a live product surface. Do not add back `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, or `SearchFileTreeViewModel` source paths/symbols.

“File tree” remains valid when it refers to compatibility or textual context contracts, including the MCP `get_file_tree` tool, tool result cards, API/persisted symbols such as `FileTreeOption`, historical plans, and prompt/context output such as `<file_map>` / project structure maps. Contributor-facing UI and docs should prefer “project structure map” when describing generated textual context so it is not confused with the removed native UI.

The old IDE-era Prompt selected-files panel is also removed. Do not add back `PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, or the Prompt-owned copy/chat preset picker helpers. The live compact selected-files UI remains `SelectedFilesGrid` plus `FilePreviewPopover`, and the Settings chat preset picker lives under `Features/Settings`.

## Placement rules for new files

- New product-flow code goes under `Sources/RepoPrompt/Features/<FeatureName>`.
- New app lifecycle, launch/configuration, command, root view/view-model, notification-name, and composition-root wiring goes under `Sources/RepoPrompt/App`.
- Keep Tree-sitter C declarations in the narrow `Sources/RepoPromptSyntaxCBridge` shim. Do not restore target-wide app bridging-header flags.
- Put canonical neutral workspace values, codecs, repository/persistence behavior, session authority, filesystem/catalog/path/search/selection/slices/token/codemap/syntax behavior, factual prompt rendering from already-classified neutral values, reusable platform contracts, and workspace policy helpers in `Sources/RepoPromptCore`. Keep app storage-root discovery, Combine observation, diagnostics/tracing adapters, mutation policy, readiness integration, UI behavior, file/workspace/codemap projection, prompt/chat/clipboard policy, Git artifact fallback, and MCP product ownership app-owned.
- Put Apple/Darwin adapter implementations in `Sources/RepoPromptCoreMacOS`; core must never import that module.
- Put descriptor/socket helpers shared by the app proxy, proxy CLI, and CoreMacOS in `Sources/RepoPromptPOSIXSupport`; never place them in `RepoPromptShared` or expose them from Core contracts.
- New cross-cutting service/platform code goes under `Sources/RepoPrompt/Infrastructure/<Area>`.
- Provider-neutral workflow prompt catalog metadata and renderers go under `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/`; do not add new workflow prompts under provider-specific command names or bundled `AppResources/Services/AI/Prompts` mirrors.
- New reusable SwiftUI components, text/markdown helpers, and UI services should prefer a narrow feature owner first; otherwise use `Sources/RepoPrompt/Infrastructure/UI/<Area>`.
- New generic extensions/helpers should prefer a narrow feature or infrastructure owner first; otherwise use `Sources/RepoPrompt/Infrastructure/Utilities`.
- New app-visible diagnostic surfaces go under `Sources/RepoPrompt/Features/Diagnostics` and must have a documented purpose and entry point.
- New app/CLI protocol definitions shared by both executables go under `Sources/RepoPromptShared`.
- MCP filesystem/product/build-flavor identity and external-client event wire DTOs are single-sourced under `Sources/RepoPromptShared/MCP`; app/helper targets keep local compile-flavor selection and resolve process-local platform values such as `getuid()` before calling the shared API.
- New app-local MCP/socket/routing helpers go under `Sources/RepoPrompt/Infrastructure/MCP`, not `Sources/RepoPrompt/Shared`.
- New app-proxy CLI-only implementation code goes under `Sources/RepoPromptMCP`.
- New standalone direct-stdio/profile adapter code goes under `Sources/RepoPromptHeadless`; do not add a second implementation of canonical workspace/search/codemap/selection/prompt behavior while convergence is in progress.
- New test doubles, parser inputs, sample projects, benchmark-only fixture data, and XCTest-only helpers go under the matching test target. Cross-target convergence fixtures belong under `Tests/SharedRuntimeConvergenceFixtures`, never under production sources.
- Intentionally promoted durable characterization records belong under `docs/characterization`. This directory is not a general home for agent working notes. Current records are the frozen Phase 0 baseline, `shared-runtime-phase1-2026-06-05.md`, `shared-runtime-phase2-slice1-2026-06-05.md`, `shared-runtime-phase2-slice2-2026-06-05.md`, and the narrow Slice 3 factual-rendering checkpoint record.
- Do not create directories named `Tests`, `TestSupport`, or `Fixtures` under `Sources/RepoPrompt`.
- Do not put parser fixtures or sample parser inputs under `Sources/RepoPrompt/Infrastructure/SyntaxParsing`; keep only production parser/query code there.
- Keep `App/WindowState.swift` in `App` until there is a separate composition-root refactor; physical moves must preserve initialization order.

## Exception policy

Exceptions must be explicit, narrow, and documented here before they become precedent.

### RepoPromptShared CryptoKit exception

- `Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift` may import `CryptoKit` solely for deterministic SHA-256 frame correlation. No other `RepoPromptShared` source may import `CryptoKit`, and Darwin/POSIX imports remain forbidden throughout the target.

### App-visible diagnostics retained in the app target

These files are intentionally compiled as app-integrated diagnostics and live under `Sources/RepoPrompt/Features/Diagnostics`:

- `Features/Diagnostics/Benchmark`: the Settings-visible Repo Bench surface, including benchmark core, settings UI/view model, run store, reporting, and local rankings. If Repo Bench needs a headless/CI runner, create a separate executable-target plan rather than hiding target churn in this layout cleanup.
- `Features/Diagnostics/AgentMode`: debug-only Agent Mode performance instrumentation and text-derivation diagnostics.
- `Features/Diagnostics/AgentMode/Stress`: debug-only Agent chat stress launch configuration, harness, overlay panel, and stress support extensions on `AgentModeViewModel`, launched with `-RP_AGENT_CHAT_STRESS` and `RP_AGENT_STRESS_*` environment variables.
- `Features/Diagnostics/MCP`: hidden DEBUG MCP diagnostics, transport diagnostics, Sparkle diagnostics, and memory sampling exposed through `__repoprompt_debug_diagnostics` / legacy debug transport tools.
- `Features/Diagnostics/Prompt`: DEBUG prompt/token recount event forwarding, selection signatures, and selected-path watchdog state surfaced through restore performance diagnostics.
- `Features/Diagnostics/CodeMap`: DEBUG CodeMap initial-root-load timing wrappers surfaced through restore performance diagnostics.
- `Features/Diagnostics/App`: app-wide font-scale metrics, workspace/window restore performance logging, and DEBUG root-load trace correlation (`WorkspaceRootLoadDiagnostics`) surfaced through restore/workspace loading diagnostics.

### Documented wiring exceptions outside Diagnostics

- `App/AppLaunchConfiguration.swift` remains in `App` because it owns process arguments/environment interpretation for launch behavior. It still routes DEBUG-only Agent chat stress settings, but harness-specific configuration lives under `Features/Diagnostics/AgentMode/Stress`.
- `App/WindowState.swift` remains the composition root and continues to instantiate/pause the DEBUG-only `AgentChatStressHarness`. This is wiring only; harness implementation lives under Diagnostics.
- `Sources/RepoPromptCore/Security/EphemeralSecureKeyValueStore.swift` remains with reusable security storage code, not Diagnostics, because it is a required debug-app secure-storage backend rather than a fixture or visible diagnostic harness. It is `#if DEBUG`, in-memory only, and preserves existing debug behavior for ad-hoc/ephemeral secure storage.

### Tree-sitter scanner linker compatibility target

- `Sources/TreeSitterScannerSupport` is an internal C linker compatibility target consumed narrowly through `RepoPromptSyntaxCBridge`, not a restored local grammar target. It contains byte-for-byte exact-snapshot copies of the upstream JavaScript and Python `scanner.c` implementations plus their required `tree_sitter` helper headers. It does not contain parser copies, grammar definitions, queries, or CE-authored scanner code.
- Clean coordinated SwiftPM root graphs compile the exact-pinned upstream JavaScript and Python parser objects but omit their scanner objects, leaving unresolved external-scanner ABI symbols. `TreeSitterScannerSupport` supplies only those missing symbols while CE continues linking the upstream package products.
- The tracked checksum manifest at [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) protects the copied snapshots from drift. Do not expand this target, restore the seven retired local grammar directories, or replace the target with transient `.build/checkouts` mutation. Remove the target, guardrails, checksums, and this exception together only after validated upstream revisions or SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

No top-level `Sources/RepoPrompt/Notifications` exception remains; app-wide notification-name extensions now live under `Sources/RepoPrompt/App/Notifications`.

## Guardrails

Run the repository guardrails before or after source-layout-sensitive changes:

```bash
make guardrails
# coordinated entrypoint:
make dev-guardrails
```

For the source-layout check alone, run `./Scripts/source_layout_guardrails.sh`. For the enforced core-boundary scan alone, run `bash ./Scripts/core_boundary_guardrails.sh`. The active `python3 Scripts/test_shared_runtime_phase2_boundaries.py` check enforces current workspace/runtime/prompt/projection ownership, sole app construction, importer-backed dependencies, immutable Phase 0 artifacts, and the complete reviewed hardened headless manifest; `Scripts/test_shared_runtime_phase2_slice1_boundaries.py` remains a historical checkpoint. The focused manifest behavior is covered by `python3 Scripts/test_shared_runtime_headless_baseline.py`. The independently reviewable headless source/test manifest is checked or reproducibly regenerated with `python3 Scripts/shared_runtime_headless_baseline.py --check|--write`; it does not alter the Phase 0 baseline.

The source-layout guardrail verifies:

- old top-level layer buckets are absent or contain no files;
- no `Tests`, `TestSupport`, or `Fixtures` directories exist under `Sources/RepoPrompt`;
- `MCPControlMessages.swift`, `MCPFilesystemIdentity.swift`, and `MCPBootstrapMessages.swift` exist only under `Sources/RepoPromptShared/MCP`, and the `MCPExternalClientEvent` wire DTO is declared only there;
- parser fixtures/sample inputs do not live under app syntax parsing source;
- tracked contributor-facing documentation remains within the explicit file allowlist, including individually promoted durable characterization records;
- each moved contract/runtime/adapter file is single-sourced under its narrow `RepoPromptCore`, `RepoPromptCoreMacOS`, or `RepoPromptPOSIXSupport` owner;
- the narrow `RepoPromptSyntaxCBridge` target contains exactly its declaration header and anchor C file, exposes exactly the curated fourteen Tree-sitter declarations, owns the exact grammar/scanner linkage set, and replaces the retired app-wide bridging header;
- the narrow `TreeSitterScannerSupport` compatibility target has exactly its approved JavaScript/Python scanner snapshots and helper headers, matches curated checksums, remains wired only through `RepoPromptSyntaxCBridge`, preserves the pinned grammar products in `Package.swift` and `Package.resolved`, keeps grammar products off the app target, and keeps the retired local grammar directories absent;
- Agent/MCP runtime code does not depend on `WorkspaceFilesViewModel`, `FileViewModel`, or `FolderViewModel`;
- removed native-tree/search artifact paths are not tracked again;
- removed native-tree/search/eager-loading symbols such as `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, `SearchFileTreeViewModel`, `RootDescendantMaterialization`, `legacyMaterializedRootKeys`, `legacyMaterializeDescendantsRecursively`, and `legacyEager` are not referenced from app source;
- removed Prompt UI cleanup artifacts (`PresetBottomBar.swift`, `SelectedFileView.swift`, `SelectedFilesPanelViewModel.swift`) and unique stale symbols (`PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, `PresetTwoPanePopover_Copy`, `CopyPresetPreviewView`, `PresetTwoPanePopover_Chat`) are not referenced from app source;
- `App/WindowState.swift` does not reintroduce scoped `searchViewModel` wiring;
- `WorkspaceFilesViewModel.swift` does not reintroduce the removed `loadContentsRecursively` eager-loading seam.

The enforced core-boundary guardrail rejects:

- missing `Sources/RepoPromptCore`, `Sources/RepoPromptCoreMacOS`, `Sources/RepoPromptPOSIXSupport`, `Sources/RepoPromptShared`, or `Sources/RepoPromptSyntaxCBridge` roots;
- forbidden Apple UI/platform imports under `Sources/RepoPromptCore`;
- imports other than Foundation under `Sources/RepoPromptShared`, except the documented `CryptoKit` import in `MCP/JSONRPCBridgeLedger.swift`, plus all Darwin/POSIX imports and descriptor/socket ownership;
- Darwin/POSIX-backed types, raw accepted descriptors, or POSIX support imports in Core contracts;
- app-owned runtime and embedded-app policy references under `Sources/RepoPromptCore`;
- missing Slice 2 Core/CoreMacOS owners, retired app runtime paths, obsolete selection forwarding, multiple production runtime factories, speculative native dependencies, or headless runtime construction;
- premature MCP catalog/provider/DTO/formatter/dispatch ownership in Core;
- any accidental app-packaging reference to standalone `repoprompt-headless` / `rpce-headless` command names.

Shared MCP single-sourcing, syntax-shim ownership, and scanner compatibility remain enforced by the source-layout guardrail.

## Historical resolved items

- `MCPControlMessages.swift`, `MCPFilesystemIdentity.swift`, `MCPBootstrapMessages.swift`, and the `MCPExternalClientEvent` wire DTO now have one source of truth in `Sources/RepoPromptShared/MCP`; the app and CLI targets depend on `RepoPromptShared`.
- The old production dependency on a test-named filesystem seam was renamed to `FileSystemProviding`; test doubles/support live under tests.
- The dead Dart parser fixture under app source was removed rather than retained as production code.
- Workspace, Agent Mode, MCP infrastructure, workspace context/files, Prompt, Context Builder, Chat, Search, Settings, Code Map, and syntax parsing were moved toward the hybrid feature/infrastructure layout.
- Benchmark, debug, and stress harnesses were classified as app-integrated diagnostics or documented wiring exceptions.
- The old top-level layer buckets were pruned as part of Work Item 11.
- The native file-tree visualization, IDE-era search view-model layer, and eager root materialization seams were removed. Textual project structure maps and MCP `get_file_tree` output remain supported compatibility surfaces.
- The Claude-compatible Agent Mode provider family was extracted into the `RepoPromptClaudeCompatibleProvider` package product under `Packages/RepoPromptAgentProviders/`; see `docs/architecture/provider-plugins.md` for the bridge/adapter layout and rules for adding new providers.
- Workflow prompt generation now lives in the provider-neutral catalog under `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/`; the old provider-specific `ClaudeCodeCommands` surface and duplicated bundled prompt mirror under `AppResources/Services/AI/Prompts/` should not be restored.

## Contributor validation commands

Run the smallest focused validation that covers your change, then broaden as needed:

```bash
make dev-guardrails
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-test FILTER=CodexIntegrationConfigurationTests
make dev-test FILTER=WorkspaceFileContextStoreTests
make dev-test
make guardrails
make doctor
make dev-build
make dev-test
```

Use `make run` only when it is safe to stop any existing RepoPrompt instance and launch the debug app.
