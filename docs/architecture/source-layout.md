# Source Layout Ownership Map

Current as of 2026-06-05 after the bounded core/platform split and the frozen packaging (`2b35091`), app/MCP (`042a500`), and headless (`487cd71`) sibling baselines. This document is contributor-facing: use it to decide where new source, tests, fixtures, diagnostics, shared protocol code, and guardrail checks belong.

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
      CodeMap/                   # code-map extraction feature code and FileAPI model
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
      FileSystem/                # filesystem seams/services
      MCP/                       # app-side MCP infrastructure, app-local MCP helpers, and MCP view model adapters
      Networking/                # HTTP and decoding substrate
      Persistence/               # shared persistence helpers such as preset file storage
      Process/                   # process/CLI launch substrate
      Regex/                     # reusable regex adapters/toolkit
      Security/                  # keychain, signing, and secure storage
      SyntaxParsing/             # syntax parsing and tree-sitter query infrastructure
      UI/                        # reusable UI components, text/markdown/tooltip/mention substrate, UI services
      Utilities/                 # narrow generic utilities/extensions
      VCS/                       # git/VCS substrate
      WorkspaceContext/          # context store, indexing, path lookup, slices, search, token accounting
    ThirdParty/                  # vendored SwiftPCRE2 wrapper
  RepoPromptCore/               # enforced UI-independent contracts, workspace policy helpers, and narrow MCP transport values
  RepoPromptCoreMacOS/          # enforced macOS FSEvents, POSIX process, Keychain/signing, and peer-verification adapters
  RepoPromptSyntaxCBridge/      # narrow Tree-sitter declaration/linkage shim; owns grammar/scanner dependencies
  RepoPromptShared/
    MCP/                         # shared app/CLI MCP bootstrap/control contracts; POSIX descriptor support is still present pending convergence
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

[`headless-core.md`](headless-core.md) locks the library-first split. Item 5 now creates and enforces the reusable contract/adapters substrate:

```text
Sources/
  RepoPromptCore/                # UI-independent contracts, workspace policy helpers, and narrow MCP transport values
  RepoPromptCoreMacOS/           # Apple/Darwin adapter implementations
  RepoPromptSyntaxCBridge/       # narrow Tree-sitter declaration shim
  RepoPromptHeadless/            # landed independent direct-stdio runtime; not yet a shared-Core consumer
```

`RepoPromptCore`, `RepoPromptCoreMacOS`, and `RepoPromptSyntaxCBridge` are currently SwiftPM library products/targets; removing their public products is a later convergence phase. `RepoPromptHeadless` is an executable target with a separate v1 workspace/tool stack. `Scripts/core_boundary_guardrails.sh` now fails on forbidden imports, embedded-app policy references, missing roots, and accidental standalone packaging references. The app-wide Objective-C bridging-header flags are removed; the syntax shim owns grammar and scanner-support linkage.

The bounded split intentionally leaves the embedded session host and its workspace-context runtime closure under `Sources/RepoPrompt` for now. Moving `RepoPromptCoreHost` requires the deferred filesystem publication conversion from Combine to bounded async streams, neutral diagnostics instead of `os`/`UserDefaults`, explicit state-directory injection for code-map/partition caches, and app-model decoupling in `WorkspaceRepository` and `WorkspaceSessionController`. Do not bypass those blockers by moving app policy into `RepoPromptCore`.

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
- Put new reusable platform contracts and workspace policy helpers in `Sources/RepoPromptCore`; keep embedded-app policy and mixed runtime closures app-owned until they satisfy the enforced core guardrail.
- Put Apple/Darwin adapter implementations in `Sources/RepoPromptCoreMacOS`; core must never import that module.
- New cross-cutting service/platform code goes under `Sources/RepoPrompt/Infrastructure/<Area>`.
- Provider-neutral workflow prompt catalog metadata and renderers go under `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/`; do not add new workflow prompts under provider-specific command names or bundled `AppResources/Services/AI/Prompts` mirrors.
- New reusable SwiftUI components, text/markdown helpers, and UI services should prefer a narrow feature owner first; otherwise use `Sources/RepoPrompt/Infrastructure/UI/<Area>`.
- New generic extensions/helpers should prefer a narrow feature or infrastructure owner first; otherwise use `Sources/RepoPrompt/Infrastructure/Utilities`.
- New app-visible diagnostic surfaces go under `Sources/RepoPrompt/Features/Diagnostics` and must have a documented purpose and entry point.
- New app/CLI protocol definitions shared by both executables go under `Sources/RepoPromptShared`.
- New app-local MCP/socket/routing helpers go under `Sources/RepoPrompt/Infrastructure/MCP`, not `Sources/RepoPrompt/Shared`.
- New app-proxy CLI-only implementation code goes under `Sources/RepoPromptMCP`.
- New standalone direct-stdio/profile adapter code goes under `Sources/RepoPromptHeadless`; do not add a second implementation of canonical workspace/search/codemap/selection/prompt behavior while convergence is in progress.
- New test doubles, parser inputs, sample projects, benchmark-only fixture data, and XCTest-only helpers go under the matching test target. Cross-target convergence fixtures belong under `Tests/SharedRuntimeConvergenceFixtures`, never under production sources.
- Intentionally promoted durable characterization records belong under `docs/characterization`. Each tracked record must remain individually named in the source-layout guardrail allowlist; this directory is not a general home for agent working notes. The current promoted record is `docs/characterization/shared-runtime-phase0-2026-06-05.md`.
- Do not create directories named `Tests`, `TestSupport`, or `Fixtures` under `Sources/RepoPrompt`.
- Do not put parser fixtures or sample parser inputs under `Sources/RepoPrompt/Infrastructure/SyntaxParsing`; keep only production parser/query code there.
- Keep `App/WindowState.swift` in `App` until there is a separate composition-root refactor; physical moves must preserve initialization order.

## Exception policy

Exceptions must be explicit, narrow, and documented here before they become precedent.

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

For the source-layout check alone, run `./Scripts/source_layout_guardrails.sh`. For the enforced core-boundary scan alone, run `bash ./Scripts/core_boundary_guardrails.sh`.

The source-layout guardrail verifies:

- old top-level layer buckets are absent or contain no files;
- no `Tests`, `TestSupport`, or `Fixtures` directories exist under `Sources/RepoPrompt`;
- `MCPControlMessages.swift` exists only at `Sources/RepoPromptShared/MCP/MCPControlMessages.swift`;
- parser fixtures/sample inputs do not live under app syntax parsing source;
- tracked contributor-facing documentation remains within the explicit file allowlist, including individually promoted durable characterization records;
- each Item 5 moved contract/adapter file is single-sourced only under its narrow `RepoPromptCore` or `RepoPromptCoreMacOS` owner, so app-local compatibility copies cannot return;
- the narrow `RepoPromptSyntaxCBridge` target contains exactly its declaration header and anchor C file, exposes exactly the curated fourteen Tree-sitter declarations, owns the exact grammar/scanner linkage set, and replaces the retired app-wide bridging header;
- the narrow `TreeSitterScannerSupport` compatibility target has exactly its approved JavaScript/Python scanner snapshots and helper headers, matches curated checksums, remains wired only through `RepoPromptSyntaxCBridge`, preserves the pinned grammar products in `Package.swift` and `Package.resolved`, keeps grammar products off the app target, requires the temporary core native-linkage umbrella, and keeps the retired local grammar directories absent;
- Agent/MCP runtime code does not depend on `WorkspaceFilesViewModel`, `FileViewModel`, or `FolderViewModel`;
- removed native-tree/search artifact paths are not tracked again;
- removed native-tree/search/eager-loading symbols such as `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, `SearchFileTreeViewModel`, `RootDescendantMaterialization`, `legacyMaterializedRootKeys`, `legacyMaterializeDescendantsRecursively`, and `legacyEager` are not referenced from app source;
- removed Prompt UI cleanup artifacts (`PresetBottomBar.swift`, `SelectedFileView.swift`, `SelectedFilesPanelViewModel.swift`) and unique stale symbols (`PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, `PresetTwoPanePopover_Copy`, `CopyPresetPreviewView`, `PresetTwoPanePopover_Chat`) are not referenced from app source;
- `App/WindowState.swift` does not reintroduce scoped `searchViewModel` wiring;
- `WorkspaceFilesViewModel.swift` does not reintroduce the removed `loadContentsRecursively` eager-loading seam.

The enforced core-boundary guardrail rejects:

- missing `Sources/RepoPromptCore`, `Sources/RepoPromptCoreMacOS`, or `Sources/RepoPromptSyntaxCBridge` roots;
- forbidden Apple UI/platform imports under `Sources/RepoPromptCore`;
- app-owned runtime and embedded-app policy references under `Sources/RepoPromptCore`;
- any accidental app-packaging reference to standalone `repoprompt-headless` / `rpce-headless` command names.

Shared MCP single-sourcing, syntax-shim ownership, and scanner compatibility remain enforced by the source-layout guardrail.

## Historical resolved items

- `MCPControlMessages.swift` now has one source of truth in `Sources/RepoPromptShared/MCP/MCPControlMessages.swift`; the app and CLI targets depend on `RepoPromptShared`.
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
