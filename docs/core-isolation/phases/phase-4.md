# Phase 4 — Workspace/File-Context Engine Extraction

**Date:** 2026-06-21
**Implementation base:** `9224bb74396f70e6a8402168761b256488668eb6`
**Status:** implementation and every non-visible gate complete
**Disposition:** **NO-GO** — the visible packaged app-proxy smoke was not run because the required immediate launch approval was requested but not received. Phase 5 has not begun.

## Scope and ownership

Phase 4 moved the current implementation, rather than reconstructing an older
snapshot, into `RepoPromptCore` in dependency order:

- `Sources/RepoPromptCore/FileSystem`: catalog-facing filesystem runtime,
  accepted watcher ingress, crawling/ignore behavior, content scheduling,
  mutation reconciliation, and bounded caches;
- `Sources/RepoPromptCore/WorkspaceContext`: `WorkspaceFileContextStore`,
  root/catalog generations, immutable leases, ingress barriers, lookup,
  indexes/shards, store-backed search, read/search caches, slices, and
  root/session-worktree lifetime helpers;
- `Sources/RepoPromptCore/CodeMap` and `SyntaxParsing`: neutral codemap,
  scanner/query, cache, and syntax collaborators;
- neutral leaf dependencies under `Utilities`, `Platform`, and Core models.

The engine consumes the Phase 3 watcher, directory, content, mutation, runtime
path, and diagnostics contracts. Concrete FSEvents and macOS filesystem
implementations remain in `RepoPromptCoreMacOS`. Core has zero imports of
AppKit, SwiftUI, Combine, Darwin, CoreServices, Security, OSLog/`os`, and owns no
UserDefaults or NotificationCenter policy.

`WindowStateComposition` still constructs one `WorkspaceFileContextStore` per
window. `WorkspaceManagerViewModel` remains the sole writable workspace
authority. There is no second store, watcher graph, revision allocator,
persistence writer, or command ingress. No `WorkspaceSessionController`,
`RepoPromptCoreSession`, or Core host declaration exists. Phase 5 is explicitly
out of scope.

## Preserved contracts

The moved implementation retains the existing root and root-lifetime IDs,
callback-accepted and store-applied ingress watermarks, close-before-watcher
teardown, exact-lifetime successor fencing, immutable catalog-generation
leases, root-local indexes/shards/overlays, search admission and bounded FIFO
backpressure, bounded caches/coalesced flights, deterministic merge/ranking,
cancellation cleanup, typed unavailable validated scopes with no fallback,
slice persistence/rebase fences, codemap snapshot freezing, late-callback
rejection, and bounded watcher drain/teardown diagnostics.

The neutral `OrderedEventStream` uses active observer records, serialized sends,
idempotent cancellation, and close-before-cancel at every store detach path.
Its callback remains a synchronous non-`@Sendable` API, like the replaced
Combine sink: the broadcaster is the checked serialization boundary. Making the
caller closure `@Sendable` changed the package ABI and imposed an inaccurate
caller requirement; the final focused and full suites validate the lock-backed
form.

## App-retained policy and compatibility

App-selected runtime/cache paths, UserDefaults, visible diagnostics, Git/review
authorization, file-mutation authorization, workspace switching, selection
mirroring, prompt orchestration, and AppKit/SwiftUI projection remain app-owned.
Compatibility aliases and `Sources/RepoPrompt/App/CoreAdapters` are narrow
forwarding/composition seams with one concrete implementation owner.
Phase 2 token accounting leaves remain Core-owned; `TokenCalculationService`
and prompt/factual-output authority remain app-owned for Phase 6.

## Temporary immutable parity harness

The sole Phase 4 parity test is:

`root/RepoPromptTests.WorkspaceFileContextCoreParityTests/testImmutableLegacyFileProjectionMatchesDirectCorePathSearchSnapshot`

It compares a fixed legacy `FileViewModel` projection with direct Core
`SearchFileDescriptor` input and asserts identical alias-qualified ordered path
results. It constructs no store, watcher, persistence backend, revision
allocator, command ingress, or writer and performs no dual write. Ticket
`25356fcf-53ca-4bf6-bd1c-28d1a93b6d24`: 1/1 passed. Remove it with the legacy
app projection.

## Test migration and exact census

The curated ledger contains a literal `Moved <old root ID> -> <new ID> in Phase
4` note for every physical move. This is the complete machine-readable old/new
map, not a suite-level approximation:

- 233 methods / 284 scenarios moved with zero scenario delta;
- Core: 212 methods / 263 scenarios;
- CoreMacOS: 21 methods / 21 scenarios;
- one parity method/scenario was added;
- final census: root 1622/2101 scenarios, Core 218/275, CoreMacOS 34/34,
  POSIX 3/3, provider 7/16; total 1884 methods / 2429 scenarios.

Final authoritative lists:

| Target | Ticket | Methods | Sorted-ID SHA-256 |
| --- | --- | ---: | --- |
| Core | `7f31ee84-a9d0-4b5c-ba11-95e1e26e3e40` | 218 | `ecf51bc21c776ce61b15ca4549625a2b6ce7b0250d43974b0424b306ad192871` |
| CoreMacOS | `1c60c7e5-f4f6-4c4b-b5f3-315d1d53ce5f` | 34 | `3c5b82a29fd97b1bbe249b9e0aa7dbe32c331f41925e47157a3940144d76dabe` |
| POSIX | `a0bdcd0a-3037-4ea5-a982-09e865fd2c34` | 3 | `491a411dcfedeb9ea27cd4c7e4fe32768268ddb242243adf9d94053ad34c1fa9` |
| Provider | `3fa0afe2-91bf-47e5-90e5-99b7b71a399b` | 7 | `af8669b714868d718314b12d53a2e4d3980e040a2cd4ede26d28d17d03368948` |
| Root | `6b053ff2-3c87-43d5-a81e-8146f6d6703f` | 1622 | `e1785707a22bd89b265aed0092ed4c65de6b238e13a94f3dfa770891acfe4390` |

`python3 Scripts/test_suite_optimizer.py verify-ledger --ledger
Scripts/Fixtures/test-suite-contract-ledger.tsv` reconciled all 1884 live IDs.
Its relist tickets were Core `893ee052-945c-43fc-8bd4-93dc9ce70fbe`, CoreMacOS
`f84a95a3-f8c2-4bba-9c3a-38ae17bc732c`, POSIX
`3fd522f5-dcf3-405b-8d18-6a82ec3594e5`, provider
`99195828-5b3e-4628-a295-68eb83f2781f`, and root
`3c7a0e41-32a1-40c0-b6d2-912c316476ad`. Final curated-ledger SHA-256:
`69c566a6aa2dc1bf9eb325f7675dfae15116d6f8a4382a159b20de590936693c`.

## Behavior evidence

Focused evidence after extraction and review corrections:

- store-backed engine matrix: ticket `9874c58d-d35a-483d-83e5-e3244087aa98`,
  43/43 passed;
- accepted ingress barriers after ordered-stream hardening: ticket
  `b8253533-bd2b-41bb-8b6c-7d1bbfec60af`, 10/10 passed;
- diagnostics/root compatibility: ticket
  `9cd93906-66b8-48e1-bb62-b3fca6da69f2`, 23/23 passed;
- immutable parity: ticket `25356fcf-53ca-4bf6-bd1c-28d1a93b6d24`, 1/1 passed.

Final full lanes after formatting and the review corrections:

| Lane | Ticket | Result |
| --- | --- | --- |
| Core | `4767ac17-c89f-467f-bac2-fbebfe1f24a9` | 218 passed, 0 failed |
| CoreMacOS | `14dd7230-ac8c-4a69-b3d2-ab15298c2da8` | 34 passed, 0 failed |
| POSIX | `18fd645b-57a9-4baa-8b32-4ae3f92b4a70` | 3 passed, 0 failed |
| Provider | `5ee67d30-3aac-4524-8c5c-b691169239d5` | 7 passed, 0 failed |
| Root | `fc077da5-5d2e-4381-90a6-9d91a1138979` | 1622 passed, 2 skipped, 0 failed |

## Performance evidence

### Catalog/search readiness

Ticket `1b5b4493-9019-4caa-85eb-5620f275b23c` ran
`WorkspaceFileSearchIndexTimeToReadyBenchmarkTests/testLargeRepositoryTimeToReadyBenchmark`
and passed its factual fixture/counter assertions.

| Scenario | Phase 4 raw ms | Phase 4 median / p95 | Phase 0 median / p95 | Disposition |
| --- | --- | --- | --- | --- |
| cold worktree first scoped search | 1397.863, 1410.232, 1380.738, 1409.523, 1548.552 | 1409.523 / 1548.552 | 1354.043 / 1377.804 | median +4.1%; stable 9.9%; no material regression |
| incremental one-file ready search | 238.396, 236.633, 246.431, 232.970, 242.528 | 238.396 / 246.431 | 236.143 / 245.359 | median +1.0%; stable 3.4%; no material regression |

Counter vectors remained exact: cold performed one crawl, authoritative
publication, catalog rebuild, and shard build with zero fallback/patch;
incremental performed one applied-generation advance, patch, rebuild, and shard
build with zero crawl/authoritative/fallback.

### Prompt/codemap packaging

The fixed canonical-codemap fixture passed five times: tickets
`710616d2-bdcb-4e55-86a0-59de3e6d3859` (0.291 s),
`4fb717fa-1c35-420a-978b-a277d2cc471a` (0.300 s),
`a63cb681-1695-4764-b284-c3c4ce550cf1` (0.299 s),
`6dad7515-fe21-4cc7-8469-c9e4cfcb9a07` (0.300 s), and
`cfadaa40-d844-4771-8b48-711dbf6de108` (0.297 s). Median 0.299 s, range
0.291–0.300 s, versus Phase 0 median 0.267 s/range 0.263–0.281 s. The 32 ms
report-only increase is not a material behavior/performance regression and the
factual output fixture was exact.

### Packaged app-proxy runtime

**Not run.** A visible launch/relaunch requires explicit user approval
immediately beforehand. Approval was requested after every non-visible gate was
green; the RepoPrompt question transport was closed and no user approval was
received. No visible application was launched or stopped.

## Style, guardrails, Xcode, builds, and package

- `make dev-format`: ticket `e3a2e4f4-538e-467f-9126-5888ae2b0017`,
  completed; 23 touched Swift files formatted.
- `make dev-lint`: ticket `4ef10eee-3347-4a34-a9c2-65edd73c7dff`, 0/1253 files
  needed formatting and SwiftLint found zero violations.
- `make guardrails`, `Scripts/core_isolation_guardrails.py`, nine negative/valid
  Core-isolation unit tests, and 26 optimizer unit tests passed. The first
  guardrail attempt was invalid because it overlapped a coordinated SwiftPM lane
  and `dump-package` returned the lock message; the clean idle retry passed all
  rules.
- `make xcode-generator-test`: 23/23 passed. `make xcode-validate` regenerated
  and validated `.build/xcode/RepoPromptCE.xcworkspace` with `xcodebuild -list`.
- forbidden Core platform-import count: 0; concrete
  `WorkspaceFileContextStore` declaration count: 1, in Core; Phase 5 declaration
  count: 0.

Coordinated builds, all passed:

| Build | Ticket |
| --- | --- |
| target `RepoPromptCore` | `e2c9f8ab-a793-44a2-b06f-360af4a7b2af` |
| target `RepoPromptCoreMacOS` | `8974cfd8-d065-447c-9ad6-e4ee146963bc` |
| target `RepoPromptPOSIXSupport` | `17b5776b-1158-428e-a677-79d0cfe41636` |
| target `RepoPromptSyntaxCBridge` | `062a5d2d-28d0-4878-a5ca-901756a73621` |
| target `RepoPromptHeadless` | `ae567de9-e82c-48f9-9409-04c543fc8d1e` |
| product `RepoPrompt` | `119e3ff8-81a2-4a5d-9b6b-7221050899d7` |
| product `repoprompt-mcp` | `6c676196-0ec5-4c5f-bff9-7904a7cb71c9` |
| product `repoprompt-headless` | `0270116e-7483-42ee-b4f6-35264476b614` |
| all products | `b75676dc-cce8-4209-9312-ed6975280612` |

`make dev-build` ticket `3ce0a596-7eaa-4a14-82f4-368691af9b88` built,
signed, architecture-validated, helper-layout-validated, and ran the
non-launching embedded MCP-helper smoke. The app and embedded helper are arm64,
`codesign --verify --deep --strict` passes, the bundle contains only
`RepoPrompt` and `repoprompt-mcp`, and the arm64 `repoprompt-headless` executable
remains outside the app bundle. Final hashes: `Package.swift`
`2df851a230445e9199d4e84867de9c5211ead25f6f86fa54369168e6e92b0eca`;
`Package.resolved`
`619a752f9015f1544aa4d8438e5ebad106b8402aba4d6b7febe5bdb4b518dacc`.

## Independent review

RepoPrompt Oracle review mode was attempted but unavailable (`Transport
closed`). Independent agents `/root/dependency_map` and
`/root/dependency_map/ordered_stream_review` reviewed the stabilized diff.
Findings and corrections:

1. Core policy leakage (Combine, OS logging, UserDefaults, NotificationCenter)
   was removed behind neutral contracts/app adapters.
2. Runtime diagnostics now use enabled/priority sink selection, capture exact
   begin/end sink and opaque context, retain MCP request identity, route legacy
   counters/root-load context, and redact unload fault paths.
3. Ordered ingress now serializes sends, uses active cancellable observers, and
   closes ingress before cancellation at every detach/failure/unload path.
4. The parity and ledger claims were corrected to the sole immutable old/new
   harness and literal 233-row mapping.
5. No Phase 5 authority/construction leakage was found.

The final review correction initially produced an incremental linker mismatch
when the synchronous sink was changed to `@Sendable`; restoring its accurate
synchronous callback ABI retained the ordering/teardown hardening. Focused and
all five full suites then passed.

## Exact uncommitted inventory

The worktree remains uncommitted. The following 154 `git status --short` entries
are the exact Phase 4 inventory at close; local `.build` artifacts are ignored:

```text
 M Scripts/Fixtures/test-suite-contract-ledger.tsv
 M Scripts/source_layout_guardrails.sh
 M Sources/RepoPrompt/App/CoreCompatibilityAliases.swift
 M Sources/RepoPrompt/App/WindowStateComposition.swift
 M Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsApplyEditsRebaseLatency.swift
 M Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift
 M Sources/RepoPrompt/Features/WorkspaceFiles/Models/FileSystemItems.swift
 M Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/FileViewModel.swift
 M Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift
 M Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift
 M Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift
 M Sources/RepoPrompt/Infrastructure/MCP/MCPToolWorkCountDiagnostics.swift
 M Sources/RepoPrompt/Infrastructure/Utilities/StandardizedPath.swift
 M Sources/RepoPrompt/Infrastructure/VCS/GitDiff/GitDiffPublishedArtifacts.swift
D  Sources/RepoPrompt/Infrastructure/WorkspaceContext/Models/WorkspaceFileContextModels.swift
D  Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatchTypes.swift
 M Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathResolution/WorkspacePathPolicy.swift
D  Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift
 M Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspacePublishedGitArtifactIngress.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapCacheManager.swift -> Sources/RepoPromptCore/CodeMap/CodeMapCacheManager.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapCaptureIndex.swift -> Sources/RepoPromptCore/CodeMap/CodeMapCaptureIndex.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapExtractionMemo.swift -> Sources/RepoPromptCore/CodeMap/CodeMapExtractionMemo.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapGenerator.swift -> Sources/RepoPromptCore/CodeMap/CodeMapGenerator.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapPCRE2Regex.swift -> Sources/RepoPromptCore/CodeMap/CodeMapPCRE2Regex.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeMapPerfStats.swift -> Sources/RepoPromptCore/CodeMap/CodeMapPerfStats.swift
RM Sources/RepoPrompt/Features/CodeMap/CodeScanActor.swift -> Sources/RepoPromptCore/CodeMap/CodeScanActor.swift
RM Sources/RepoPrompt/Features/CodeMap/JSTSSignatureExtractor.swift -> Sources/RepoPromptCore/CodeMap/JSTSSignatureExtractor.swift
RM Sources/RepoPrompt/Features/CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift -> Sources/RepoPromptCore/CodeMap/LanguageStrategies/SwiftCodeMapStrategy.swift
RM Sources/RepoPrompt/Features/CodeMap/LanguageStrategies/TypeScriptCodeMapStrategy.swift -> Sources/RepoPromptCore/CodeMap/LanguageStrategies/TypeScriptCodeMapStrategy.swift
RM Sources/RepoPrompt/Features/CodeMap/LanguageTypeExtractor.swift -> Sources/RepoPromptCore/CodeMap/LanguageTypeExtractor.swift
RM Sources/RepoPrompt/Features/CodeMap/ReferencedTypesAccumulator.swift -> Sources/RepoPromptCore/CodeMap/ReferencedTypesAccumulator.swift
RM Sources/RepoPrompt/Features/CodeMap/SwiftSignatureParser.swift -> Sources/RepoPromptCore/CodeMap/SwiftSignatureParser.swift
RM Sources/RepoPrompt/Features/CodeMap/TopLevelScanner.swift -> Sources/RepoPromptCore/CodeMap/TopLevelScanner.swift
RM Sources/RepoPrompt/Features/CodeMap/TypeCleaner.swift -> Sources/RepoPromptCore/CodeMap/TypeCleaner.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileContentSnapshot.swift -> Sources/RepoPromptCore/FileSystem/FileContentSnapshot.swift
R  Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemProviding.swift -> Sources/RepoPromptCore/FileSystem/FileSystemProviding.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+ContentLoading.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+ContentLoading.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+DirectoryEnumeration.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+DirectoryEnumeration.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+DirectoryListing.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+DirectoryListing.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+FSEvents.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FileOperations.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+FileOperations.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+IgnoreRules.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+IgnoreRules.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+PathUtilities.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+PathUtilities.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+Testing.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService+Testing.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService.swift -> Sources/RepoPromptCore/FileSystem/FileSystemService.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemServiceTypes.swift -> Sources/RepoPromptCore/FileSystem/FileSystemServiceTypes.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemWatcherEarlyFilter.swift -> Sources/RepoPromptCore/FileSystem/FileSystemWatcherEarlyFilter.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemWatcherIngressMailbox.swift -> Sources/RepoPromptCore/FileSystem/FileSystemWatcherIngressMailbox.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/GitignoreCompiler.swift -> Sources/RepoPromptCore/FileSystem/GitignoreCompiler.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/HierarchicalIgnoreEvaluator.swift -> Sources/RepoPromptCore/FileSystem/HierarchicalIgnoreEvaluator.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/IgnoreCacheStore.swift -> Sources/RepoPromptCore/FileSystem/IgnoreCacheStore.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/IgnoreDebugMetricsRecorder.swift -> Sources/RepoPromptCore/FileSystem/IgnoreDebugMetricsRecorder.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/IgnoreRules.swift -> Sources/RepoPromptCore/FileSystem/IgnoreRules.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/IgnoreRulesManager.swift -> Sources/RepoPromptCore/FileSystem/IgnoreRulesManager.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/LRUCache.swift -> Sources/RepoPromptCore/FileSystem/LRUCache.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/PathComponentsCache.swift -> Sources/RepoPromptCore/FileSystem/PathComponentsCache.swift
RM Sources/RepoPrompt/Infrastructure/FileSystem/PatternPool.swift -> Sources/RepoPromptCore/FileSystem/PatternPool.swift
 M Sources/RepoPromptCore/Platform/FileContentAccess.swift
 M Sources/RepoPromptCore/Platform/RuntimeDiagnostics.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/DartQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/DartQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/GoQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/GoQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/JavaQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/JavaQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/JavaScriptQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/JavaScriptQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/PythonQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/PythonQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/RubyQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/RubyQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/RustQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/RustQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/SwiftQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/SwiftQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/cQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/cQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/cSharpQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/cSharpQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/cppQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/cppQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/phpQueries.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/phpQueries.swift
R  Sources/RepoPrompt/Infrastructure/SyntaxParsing/Queries/typeScript.swift -> Sources/RepoPromptCore/SyntaxParsing/Queries/typeScript.swift
RM Sources/RepoPrompt/Infrastructure/SyntaxParsing/QueryResourceLoader.swift -> Sources/RepoPromptCore/SyntaxParsing/QueryResourceLoader.swift
RM Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift -> Sources/RepoPromptCore/SyntaxParsing/SyntaxManager.swift
RM Sources/RepoPrompt/Infrastructure/Diffing/DiffEditCreator.swift -> Sources/RepoPromptCore/Utilities/DiffEditCreator.swift
R  Sources/RepoPrompt/Infrastructure/Concurrency/TaskSemaphore.swift -> Sources/RepoPromptCore/Utilities/TaskSemaphore.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Indexing/DeferredReplayBufferActor.swift -> Sources/RepoPromptCore/WorkspaceContext/Indexing/DeferredReplayBufferActor.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Indexing/DeltaReplayPreparationActor.swift -> Sources/RepoPromptCore/WorkspaceContext/Indexing/DeltaReplayPreparationActor.swift
 M Sources/RepoPromptCore/WorkspaceContext/Models/WorkspaceFileContextModels.swift
 M Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathMatchTypes.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatchWorker.swift -> Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathMatchWorker.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatcher.swift -> Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathMatcher.swift
 M Sources/RepoPromptCore/WorkspaceContext/PathResolution/WorkspacePathPolicy.swift
 M Sources/RepoPromptCore/WorkspaceContext/Search/PathSearchIndex.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/RepoSearchBatchScorer.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/RepoSearchBatchScorer.swift
RM Sources/RepoPrompt/Features/Search/SearchMatch.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/SearchMatch.swift
RM Sources/RepoPrompt/Features/Search/SearchPathFiltering.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/SearchPathFiltering.swift
RM Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/StoreBackedWorkspaceSearch.swift
RM Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearchLane.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/StoreBackedWorkspaceSearchLane.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceFileSearchDebugTiming.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/WorkspaceFileSearchDebugTiming.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceSearchService.swift -> Sources/RepoPromptCore/WorkspaceContext/Search/WorkspaceSearchService.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/PartitionStore.swift -> Sources/RepoPromptCore/WorkspaceContext/Slices/PartitionStore.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SelectionSliceCoordinator.swift -> Sources/RepoPromptCore/WorkspaceContext/Slices/SelectionSliceCoordinator.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceAssembly.swift -> Sources/RepoPromptCore/WorkspaceContext/Slices/SliceAssembly.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRebaseEngine.swift -> Sources/RepoPromptCore/WorkspaceContext/Slices/SliceRebaseEngine.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRebaseFence.swift -> Sources/RepoPromptCore/WorkspaceContext/Slices/SliceRebaseFence.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileContextStore.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceInteractiveReadCache.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceInteractiveReadCache.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceRootUnloadTermination.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceRootUnloadTermination.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceSearchDecodedContentCache.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceSearchDecodedContentCache.swift
RM Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceSessionWorktreeOwnership.swift -> Sources/RepoPromptCore/WorkspaceContext/WorkspaceSessionWorktreeOwnership.swift
 M Sources/RepoPromptCoreMacOS/MacOSFileContentSnapshotReader.swift
 M Tests/RepoPromptTests/MCP/MCPReadSearchLatencyDiagnosticsGuardTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/FileSystemAcceptedIngressBarrierTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/FileSystemContentLoadingConcurrencyTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/FileSystemServiceEventPathMappingTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/FileSystemServiceIgnoreRecoveryTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/FileSystemServiceRecoveryTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/IgnoreDebugMetricsRecorderTests.swift
 D Tests/RepoPromptTests/Services/FileSystem/IgnoreRulesRecoveryTests.swift
 M Tests/RepoPromptTests/WorkspaceContext/ReplayEvidenceHarnessTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/Search/SearchPathFilteringTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchConcurrencyMatrixTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchLaneTests.swift
 M Tests/RepoPromptTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/Search/WorkspacePerRootPathSearchIndexTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/Search/WorkspaceSearchServiceTests.swift
 M Tests/RepoPromptTests/WorkspaceContext/Slices/SelectionSlicePersistenceAndRebaseTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/WorkspaceCatalogShardTests.swift
 D Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextStoreExactCapabilityTests.swift
 M Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextStoreTests.swift
 M docs/core-isolation/README.md
 M docs/core-isolation/migration-ledger.tsv
?? Sources/RepoPrompt/App/CoreAdapters/
?? Sources/RepoPromptCore/FileSystem/FileSystemItems.swift
?? Sources/RepoPromptCore/Platform/OrderedEventStream.swift
?? Sources/RepoPromptCore/Utilities/StringRuntimeUtilities.swift
?? Sources/RepoPromptCore/WorkspaceContext/CoreRuntimeCompatibilityAliases.swift
?? Sources/RepoPromptCore/WorkspaceContext/Models/PublishedGitArtifactModels.swift
?? Sources/RepoPromptCore/WorkspaceContext/Models/WorkspaceRuntimeLeafModels.swift
?? Sources/RepoPromptCore/WorkspaceContext/Search/WorkspaceSearchReadinessSource.swift
?? Sources/RepoPromptCore/WorkspaceContext/Slices/StoredSelectionPathNormalization.swift
?? Sources/RepoPromptCore/WorkspaceContext/Slices/StoredSelectionSliceMutation.swift
?? Sources/RepoPromptCore/WorkspaceContext/WorkspaceEngineDiagnostics.swift
?? Sources/RepoPromptCore/WorkspaceContext/WorkspaceRuntimeDependencies.swift
?? Sources/RepoPromptCore/WorkspaceContext/WorkspaceRuntimePerf.swift
?? Tests/RepoPromptCoreMacOSTests/FileSystem/
?? Tests/RepoPromptCoreMacOSTests/Support/
?? Tests/RepoPromptCoreTests/FileSystem/
?? Tests/RepoPromptCoreTests/Support/
?? Tests/RepoPromptCoreTests/WorkspaceContext/ReplayEvidenceHarnessTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/SearchPathFilteringTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchConcurrencyMatrixTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchLaneTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/StoreBackedWorkspaceSearchTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/WorkspacePerRootPathSearchIndexTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Search/WorkspaceSearchServiceTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/Slices/
?? Tests/RepoPromptCoreTests/WorkspaceContext/WorkspaceCatalogShardTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/WorkspaceFileContextStoreExactCapabilityTests.swift
?? Tests/RepoPromptCoreTests/WorkspaceContext/WorkspaceFileContextStoreTests.swift
?? Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextCoreParityTests.swift
?? docs/core-isolation/phases/phase-4.md
```

## Close disposition

**NO-GO.** All deterministic behavior, parity, performance, exact test/ledger,
style, structural, Xcode, target/product build, full-suite, signature,
architecture, bundle-separation, and non-launching package gates are green.
The sole blocker is the required visible packaged app-proxy smoke, which cannot
run without explicit immediate user approval. Phase 5 has not begun. After
approval, run the packaged live smoke, record its ticket/raw warm samples and
`measurementInvalid == false`, then change this disposition only if it passes.

## Approved lifecycle gate continuation — 2026-06-21

The user explicitly approved the required visible debug-app launch, packaged
app-proxy smoke, and matching-app stop. This continuation performed Phase 4
validation only; no Phase 5 source, authority, construction, or command path was
introduced.

### Coordinated launch

`make dev-run` completed successfully under ticket
`4f51fc45-a546-441c-807c-ac31d1c0e9c2`. It rebuilt, signed, packaged,
architecture-validated, helper-layout-validated, stopped any prior matching CE
debug instance, and launched
`~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`.
Conductor confirmed matching debug PID `69626`.

### Packaged app-proxy smoke

The launched packaged app was exercised with one cold lifecycle sample followed
by four comparable warm `./conductor smoke` samples. Every job exercised
`windows`, workspace switch/idempotence, `tree --type roots`, worktree listing,
and role discovery; every job exited 0 and reported
`measurementInvalid == false`.

| Ticket | Execution seconds | Result | Series use |
| --- | ---: | --- | --- |
| `906dd175-1679-4238-b2e1-f1392bb1940e` | 2.909 | exit 0, valid | cold first switch/load; lifecycle evidence |
| `0d85c5ad-ea77-41a0-b35a-a951091acaaf` | 0.391 | exit 0, valid | warm |
| `d26cf242-1b0a-4d66-8274-b852a3cdcdb6` | 0.979 | exit 0, valid | warm |
| `4fb4b83c-bead-43a0-aba9-895b22237c10` | 0.390 | exit 0, valid | warm |
| `b7937fad-4569-4d76-816c-186b494a2134` | 0.393 | exit 0, valid | warm |

The warm median was 0.392 s and range was 0.390–0.979 s, versus Phase 0 median
0.302 s and range 0.291–0.767 s. The report-only median delta is +0.090 s
(+29.8%). All factual transport operations passed, no sample was invalid, and
the single higher sample did not reproduce across the other three warm runs;
this sub-second diagnostic variation is not a material Phase 4 regression.
Repeated switches returned the harness-accepted already-active response and
continued through every subsequent assertion.

### Coordinated stop and stopped proof

`make dev-stop-app` ticket `149add76-a2e7-4bd1-a151-c7c6432a44f9`
completed with exit 0 and `measurementInvalid == false`; conductor reported
`RepoPrompt stop confirmed`. Follow-up `./conductor app status` ticket
`2b78d7b3-1617-446b-9f75-0a715df3a34a` also completed with exit 0 and reported:

```text
Running matching debug app PIDs: none
Bundle exists: yes
```

The matching CE debug app is stopped. No unrelated application process was
stopped.

## Final appended disposition

**GO.** This disposition supersedes the earlier NO-GO whose sole blocker was
explicit lifecycle approval. The approved coordinated launch, five valid
packaged app-proxy smokes, coordinated matching-app stop, and stopped-process
proof close that blocker. All Phase 4 behavior, parity, performance, exact
list/ledger, style, structural, Xcode, build, full-suite, package, and live
runtime gates are green. Changes remain uncommitted. Phase 5 has not begun.

## Independent Oracle curated-ledger metadata correction — 2026-06-21

A post-close independent Oracle audit found five stale metadata rows in
`Scripts/Fixtures/test-suite-contract-ledger.tsv` at current rows 1562, 1566,
1590, 1622, and 1625. Their executable IDs and Phase 4 move notes were correct,
but metadata inherited from the former root suite still named
`WorkspaceFilesViewModelRootShellFixture`, `ui_store_projection`, and
`main_actor_manager`. The migrated methods exercise only direct
`WorkspaceFileContextStore` and Core event/diagnostic APIs in
`RepoPromptCoreTests/WorkspaceContext/WorkspaceFileContextStoreTests.swift`.

The correction was deliberately metadata-only:

| Current row / method | Corrected Core contract and fixtures |
| --- | --- |
| 1562 — `testBatchRootUnloadDeduplicatesIDsPublishesEventsAndClearsLoadedRoots` | root identity, applied-index events, batch-unload ordering; temporary-root Core store fixture; direct event/root/file oracle |
| 1566 — `testCRUDAndRootUnloadPublishAppliedIndexEvents` | file mutation, applied-index events, root unload; temporary-root Core store fixture; exact ordered mutation/unload deltas |
| 1590 — `testEnsureIndexedFilesSkipsEligibleFileWhenRootUnloadsDuringEligibilitySuspension` | eligibility/root-lifetime/task ordering; temporary-root plus concurrency-gate fixtures; no stale root/file/catalog resurrection |
| 1622 — `testRootLoadIndexesFilesFoldersReadsContentAndLooksUpPaths` | root identity, catalog indexing, content reads, path lookup; temporary-root Core store fixture; exact direct store results |
| 1625 — `testRootUnloadUsesOneSelectiveInvalidationCycle` | root unload, selective invalidation, cache eviction; temporary-root Core store fixture; exact store-diagnostic invalidation record |

Only the secondary contract tags, validation class where needed, fixture IDs,
observable oracle, failure risk, resource-cost tags, and lifecycle owner changed.
The exact method IDs, target/file/suite/method/domain, primary contract IDs,
`core_swiftpm` layer, scenario counts, runtime/shared-state fields,
`current_disposition` action, replacement/delta fields, and byte-for-byte Phase 4
move notes were preserved. No test or production source changed.

Authoritative reconciliation command:

```bash
python3 Scripts/test_suite_optimizer.py verify-ledger \
  --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv
```

Result: 1,884 live IDs reconciled — Core 218, CoreMacOS 34, POSIX 3,
provider 7, root 1,622; reserved headless and syntax-bridge prefixes remain zero.
Relist tickets: Core `97b60002-65da-48df-aaf5-822a351d3610`, CoreMacOS
`c5069546-379b-42bd-bcd8-5741ffa49b12`, POSIX
`592d123a-5bb5-4056-b423-397ed73e771c`, provider
`8609d505-014d-45cd-9d8c-cf1e51d04df0`, and root
`6aa738ad-dfa6-4f4a-919d-88f94ee07a84`.

This correction does not alter the Phase 4 **GO** disposition and does not begin
Phase 5.
