# Source Layout Ownership Map

Current as of 2026-05-30 after the source-layout refactor, Context Builder discovery cleanup, provider extraction, post-native-tree cleanup guardrail pass, provider-neutral workflow prompt catalog cleanup, and upstream Tree-sitter grammar migration. This document is contributor-facing: use it to decide where new source, tests, fixtures, diagnostics, shared protocol code, and guardrail checks belong.

## Current source tree shape

```text
Sources/
  RepoPrompt/
    Support/                     # Obj-C bridging header / bridging-header-sensitive support path used by Package.swift
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
  RepoPromptShared/
    MCP/                         # shared app/CLI MCP control protocol definitions
  RepoPromptMCP/                 # MCP CLI implementation
  RepoPromptC/                   # C support target
  CSwiftPCRE2/                   # C PCRE2 target
  TreeSitterScannerSupport/      # narrow exact-snapshot JavaScript/Python scanner ABI fallback
Tests/
  RepoPromptTests/               # XCTest tests, support, and fixtures
```

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
- Keep bridging-header-sensitive support under `Sources/RepoPrompt/Support` unless `Package.swift` is updated in the same change.
- New cross-cutting service/platform code goes under `Sources/RepoPrompt/Infrastructure/<Area>`.
- Provider-neutral workflow prompt catalog metadata and renderers go under `Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/`; do not add new workflow prompts under provider-specific command names or bundled `AppResources/Services/AI/Prompts` mirrors.
- New reusable SwiftUI components, text/markdown helpers, and UI services should prefer a narrow feature owner first; otherwise use `Sources/RepoPrompt/Infrastructure/UI/<Area>`.
- New generic extensions/helpers should prefer a narrow feature or infrastructure owner first; otherwise use `Sources/RepoPrompt/Infrastructure/Utilities`.
- New app-visible diagnostic surfaces go under `Sources/RepoPrompt/Features/Diagnostics` and must have a documented purpose and entry point.
- New app/CLI protocol definitions shared by both executables go under `Sources/RepoPromptShared`.
- MCP filesystem/product/build-flavor identity and external-client event wire DTOs are single-sourced under `Sources/RepoPromptShared/MCP`; app/helper targets may keep only local compile-flavor selection and app-only presentation behavior.
- New app-local MCP/socket/routing helpers go under `Sources/RepoPrompt/Infrastructure/MCP`, not `Sources/RepoPrompt/Shared`.
- New CLI-only implementation code goes under `Sources/RepoPromptMCP`.
- New test doubles, fixtures, parser inputs, sample projects, benchmark-only fixture data, and XCTest-only helpers go under `Tests/RepoPromptTests`, not the app target.
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
- `Infrastructure/Security/EphemeralSecureKeyValueStore.swift` remains with security storage code, not Diagnostics, because it is a required debug-app secure-storage backend rather than a fixture or visible diagnostic harness. It is `#if DEBUG`, in-memory only, and preserves existing debug behavior for ad-hoc/ephemeral secure storage.

### Tree-sitter scanner linker compatibility target

- `Sources/TreeSitterScannerSupport` is an internal C linker compatibility target, not a restored local grammar target. It contains byte-for-byte exact-snapshot copies of the upstream JavaScript and Python `scanner.c` implementations plus their required `tree_sitter` helper headers. It does not contain parser copies, grammar definitions, queries, or CE-authored scanner code.
- Clean coordinated SwiftPM root graphs compile the exact-pinned upstream JavaScript and Python parser objects but omit their scanner objects, leaving unresolved external-scanner ABI symbols. `TreeSitterScannerSupport` supplies only those missing symbols while CE continues linking the upstream package products.
- The tracked checksum manifest at [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) protects the copied snapshots from drift. Do not expand this target, restore the seven retired local grammar directories, or replace the target with transient `.build/checkouts` mutation. Remove the target, guardrails, checksums, and this exception together only after validated upstream revisions or SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

No top-level `Sources/RepoPrompt/Notifications` exception remains; app-wide notification-name extensions now live under `Sources/RepoPrompt/App/Notifications`.

## Generated IDE artifacts

The generated Xcode workspace lives under `.build/xcode` and is not part of the
source layout or a second target graph. `Package.swift` continues to own source,
target, dependency, and test-resource membership. Edit the generator and
workflow wrapper under `Scripts`, then regenerate; never edit or track generated
workspace files. See [`xcode-workspace.md`](xcode-workspace.md).

## Guardrails

Run the source-layout guardrails before or after source-layout-sensitive changes:

```bash
make guardrails
# or
./Scripts/source_layout_guardrails.sh
```

The guardrail script verifies:

- old top-level layer buckets are absent or contain no files;
- no `Tests`, `TestSupport`, or `Fixtures` directories exist under `Sources/RepoPrompt`;
- `MCPControlMessages.swift` and `MCPFilesystemIdentity.swift` exist only under `Sources/RepoPromptShared/MCP`, and the `MCPExternalClientEvent` wire DTO is declared only there;
- parser fixtures/sample inputs do not live under app syntax parsing source;
- the narrow `TreeSitterScannerSupport` compatibility target has exactly its approved JavaScript/Python scanner snapshots and helper headers, matches curated checksums, remains wired in `Package.swift`, preserves the seven migrated grammar pins/products in `Package.swift` and `Package.resolved`, and keeps the seven retired local grammar directories absent;
- Agent/MCP runtime code does not depend on `WorkspaceFilesViewModel`, `FileViewModel`, or `FolderViewModel`;
- removed native-tree/search artifact paths are not tracked again;
- removed native-tree/search/eager-loading symbols such as `AgentFileTreeBottomPanelView`, `FileTreeViewWrapper`, `FileTreeViewController`, `NativeFileTree`, `SearchFileTreeViewModel`, `RootDescendantMaterialization`, `legacyMaterializedRootKeys`, `legacyMaterializeDescendantsRecursively`, and `legacyEager` are not referenced from app source;
- removed Prompt UI cleanup artifacts (`PresetBottomBar.swift`, `SelectedFileView.swift`, `SelectedFilesPanelViewModel.swift`) and unique stale symbols (`PresetBottomBar`, `SelectedFilesContentView`, `SelectedFilesPanelViewModel`, `PresetTwoPanePopover_Copy`, `CopyPresetPreviewView`, `PresetTwoPanePopover_Chat`) are not referenced from app source;
- `App/WindowState.swift` does not reintroduce scoped `searchViewModel` wiring;
- `WorkspaceFilesViewModel.swift` does not reintroduce the removed `loadContentsRecursively` eager-loading seam.

## Historical resolved items

- `MCPControlMessages.swift`, `MCPFilesystemIdentity.swift`, and the `MCPExternalClientEvent` wire DTO now have one source of truth in `Sources/RepoPromptShared/MCP`; the app and CLI targets depend on `RepoPromptShared`.
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
