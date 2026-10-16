# Build Modularization Program: Plan

Status: **Proposed**. Drafted 2026-09-28 against `origin/main` `589cecc536e7160519d81a787a4220100d733f07`.
Companion to [`swift-6-2-concurrency-migration-2026-07-18.md`](swift-6-2-concurrency-migration-2026-07-18.md); both programs share one target graph and one evidence discipline.

## Goal

Make the cost of an ordinary change proportional to the code it touches, not to the size of the product. An edit to one capability should rebuild, link, and test only that capability and its dependents; `RepoPromptApp` should shrink to a composition root; and the compiler and CI should keep it that way without relying on reviewer vigilance.

This is a multi-year program. It runs as short, reversible, measured vertical slices on `main`, never as a long-lived rewrite branch.

---

## 1. Evidence: where the time goes

All numbers were measured on 2026-09-28. Method and caveats are in Appendix A.

### 1.1 Developer loop

Source: conductor job logs from the most recent ~3,000 jobs across agent worktrees. Machine: 8 cores / 24 GB. Toolchain: Swift 6.3.3 / Xcode 26.3.

| Measure | p50 | p90 |
| --- | --- | --- |
| Wait for the machine-wide heavy slot (capacity 1), n=1,383 | < 1 s (75% admitted immediately) | **8.8 min** (295 jobs waited ≥ 1 min; 22 waited > 1 h) |
| Focused test job, nothing to compile (net of wait), n=130 | 2.2 min | 10.3 min |
| Focused test job, only tests changed (net), n=44 | 2.9 min | 9.0 min |
| Focused test job, app sources changed (net), n=46 | 4.7 min | 11.9 min |
| Debug package with app recompiled (net), n=19 | 13.2 min | 60 min |
| Focused test **execution**, n=2,801 | **0.6 s** | — |
| Full-suite execution (~3,000 tests), n=26 | 8.7 min | — |

With nothing changed, linking the single aggregate `RepoPromptCEPackageTests.xctest` bundle still takes 36–75 s per job. At the median, a 0.6-second test costs 2–5 minutes of build and link work, and the queue adds up to ~9 minutes at p90 when agents contend. Test execution is not the problem; building and linking are, with queueing as a tail amplifier.

### 1.2 CI

Source: `.github/workflows/ci.yml`, main run 36332152793.

- Four `Build and Test` shards each rebuild the app from scratch: 11.6 min of `swift build --product RepoPrompt` per shard, then about 4.8 min to build tests and run the shard. `actions/cache` restores `.build`, but the rebuild still happens. The likely causes are fresh-checkout mtimes and a cache key that only covers manifests.
- A main push takes 2–2.7 h wall clock. Most of that is macOS runner queueing on top of 12–19 min jobs.

### 1.3 Structural causes

1. **One module holds 88% of first-party Swift.** `RepoPromptApp` has 1,160 files and 648k lines. Every other first-party Swift target combined is about 82k lines: DomainRuntime 39.6k, MCP CLI 21k, CodeMapCore 13.4k, Shared 6.6k, WorkspaceCore 0.8k, RegexCore 0.6k, provider package 3k.
   - Every compile job in the module must parse declarations across all 1,160 files.
   - A change to any declaration visible to other files can invalidate dependents across the whole module and the test target that `@testable`-imports it.
   - Every product statically links all of it.
2. **One test module and one test bundle sit on top of it.**
   - `RepoPromptTests` has 370 files, 149k lines, and 3,314 XCTest methods.
   - 319 of those files `@testable import RepoPromptApp`. Another 11 `@testable import RepoPromptMCP`, so the test target depends on an *executable* target.
   - Native SwiftPM links every test target in a package into one `<Package>PackageTests.xctest` (verified, §3.6).
   - `dev-test FILTER=X` runs `swift build --build-tests` over the whole package before filtering (`Scripts/ci_app_test_runner.py`, `run_local_tests`). It then runs `swift test` without `--parallel`.
3. **No internal layering exists.** `Infrastructure`, `Features`, and `App` are folder names, not dependency boundaries.
   - In a file-level reference graph aggregated into 75 folder components, 67 components (645k of 648k lines) form **one strongly connected component**.
   - Against the candidate layering used for triage, 1,104 of 3,694 cross-layer file edges point the wrong way.
   - Those wrong-way edges target 201 files. The top 20 targets account for 58% and the top 40 for 73% (Appendix B).
4. **God files and nested domain types.**
   - File sizes: 17 files over 5,000 lines, 50 over 2,000, and 136 over 1,000. The largest:

     | File | Lines |
     | --- | --- |
     | `WorkspaceFileContextStore.swift` | 22.2k |
     | `AgentModeViewModel.swift` | 21.8k |
     | `MCPConnectionManager.swift` | 16.9k |
     | `WorkspaceManagerViewModel.swift` | 15.7k |
     | `WorkspaceFilesViewModel.swift` | 13.3k |
     | `CodexAgentModeCoordinator.swift` | 11.4k |
     | `WorkspaceCodemapBindingEngine.swift` | 10.0k |
     | `CodexNativeSessionController.swift` | 9.4k |
     | `GitService.swift` | 9.1k |

   - A file is the smallest unit the compiler recompiles, and one file cannot be spread across cores.
   - Lower layers consume domain types *nested inside view models*:
     - `AgentModeViewModel.MCPSessionTarget`, `.MCPInstructionDispatch`, `.MCPInteractionResponsePayload`, `.BashLiveExecutionState`, and others are used from 50 lower-layer files, 13 of which hold stored references to the view model itself.
     - `MCPServerViewModel.RequestMetadata` (31 uses), `.ResolvedTabContextSnapshot`, `.TabContextSnapshot`, `.ConnectionBindingSnapshot`, and `.FrozenFileToolAuthority`.
     - `AgentTabSession`'s Codex turn-identity types are used from 26 files.
5. **Ambient global authority.**
   - 102 `static shared` singletons with 1,231 `.shared` uses. The largest: `FontScaleManager` (130), `ServerNetworkManager` (119, including ambient `currentConnectionID` and `currentToolDispatchAuthorization`), `WindowStatesManager` (115), `GlobalSettingsStore` (115), `AgentSessionLinkRuntimeBridge` (46), `WorkspaceDiskWriter` (40), `AgentACPModelRegistry` (33), and `AppDomainRuntimeComposition` (30).
   - Also: 234 `UserDefaults.standard` uses, 354 `FileManager.default` uses, and 107 `NotificationCenter.default.post` calls.
   - These make a type impossible to move without dragging its callers' world along. They are also why hosted CI must run every suite in its own process with a sandboxed `HOME`.
6. **Tests exercise god objects.**
   - 98 test files (82k lines, 55% of test code) reference `WindowState`, `AgentModeViewModel`, `WorkspaceManagerViewModel`, `WorkspaceFilesViewModel`, `PromptViewModel`, or `MCPServerViewModel`.
   - 112 files (22k lines) touch one capability family and can move with it.
   - 118 files (35k lines) mix families.
   - 71 sleeps in 24 files and 187 expectation timeouts make the suite's runtime timing-dependent.
7. **Infrastructure amplifies the monolith.** A single machine-wide heavy slot serializes every agent's builds. Most jobs are admitted immediately, but under contention each monolithic job holds it for minutes to an hour (p90 wait 8.8 min, 22 waits over an hour). CI repeats the full build four times per run.

**Strengths to build on:**
- The extracted cores (`RepoPromptDomainRuntime`, `RepoPromptCodeMapCore`, `RepoPromptRegexCore`, `RepoPromptWorkspaceCore`, `RepoPromptShared`), each with an owner test target.
- The Claude-compatible provider package and its two-bridge rule.
- `Scripts/source_layout_guardrails.sh`.
- The per-target Swift 6 migration ledger.
- Conductor's lanes, tickets, fair heavy admission, and `.build` seed store.

---

## 2. Goals, measures, and non-goals

### 2.1 Outcome goals

Measured on the developer machine, net of queue wait unless stated.

| Measure | Baseline p50 / p90 | Milestone M1 (after W1) | Program target |
| --- | --- | --- | --- |
| Edit in an extracted module → its owning tests pass | 2.9–4.7 / 9–12 min | −30% | ≤ 60 s / ≤ 3 min |
| Focused test job with nothing changed | 2.2 / 10.3 min | ≤ 60 s | ≤ 15 s |
| Feature edit → debug app packaged | 13.2 / 60 min | −30% | ≤ 2 / ≤ 5 min |
| Heavy-slot wait (reported separately, never folded in) | < 1 s / 8.8 min | p90 ≤ 5 min | p90 ≤ 1 min |
| CI PR critical path, excluding runner queueing | 12–19 min per shard, plus 4× redundant builds | build once | ≤ 15 min |
| `RepoPromptApp` share of first-party Swift | 88% | ≤ 70% | ≤ 10% (composition and app shell) |

**Guard rails.** Each slice is measured against these, and none may regress by more than 10%: clean release build time, app launch time, peak memory, and Repo Bench results. No move may change any of the following:
- a persisted format or raw value;
- an MCP tool name, schema, or fingerprint;
- CodeMap artifact bytes;
- notification names.

Success is not declared for the focused loop while it still links the aggregate test bundle.

### 2.2 Architecture fitness goals (compiler and CI enforced)

- **Zero cycles** between first-party targets (SwiftPM enforces this).
- **Zero undeclared imports:** CI builds with `--explicit-target-dependency-import-check error`.
- **Zero edges outside the allowed-dependency matrix** (§6.1), even when acyclic.
- **Zero duplicate authorities:** one MCP catalog and registry (`RepoPromptDomainRuntime`), one settings document, one schema per tool.
- **Ratchets** (never increase; lowered by the slices that improve them):
  - wrong-way edges inside `RepoPromptApp`;
  - mutable ambient-authority uses outside the composition root;
  - files over 2,000 lines;
  - files using `@testable import RepoPromptApp`;
  - SwiftUI/AppKit imports in logic targets;
  - sleeps and wall-clock timeouts in tests;
  - `-warn-long-function-bodies` hits;
  - `public` declarations added only to satisfy tests.

### 2.3 Non-goals

- Bundling behavior, persistence-format, or UI changes into structural moves.
- Wholesale XCTest → Swift Testing conversion. New hermetic tests may use Swift Testing; bulk conversion has no latency case.
- Replacing SwiftPM with Bazel, Buck2, or Tuist (§10).
- Maximizing module count. A module exists only if it buys compile isolation, test isolation, or a real ownership boundary.

---

## 3. Target architecture

### 3.1 Normative principles

1. **Dependencies form a DAG the compiler enforces.** Every first-party target declares exactly what it imports. CI rejects undeclared imports, and a checked allowlist (§6.1) rejects forbidden edges even when they are acyclic.
2. **Depend toward stability.** Contracts and pure values sit low; volatile orchestration and presentation sit high. No module depends on something less stable than itself.
3. **`RepoPromptApp` is the composition root.**
   - Only the app target constructs concrete services, owns process and window lifecycle, and binds implementations to contracts. The MCP CLI's composition shell does the same for the CLI.
   - Nothing depends on `RepoPromptApp`.
   - `RepoPromptExecutable` stays a one-file entry shell.
4. **No mutable ambient authority below the composition root.**
   - Services receive collaborators through initializers.
   - Views receive them through typed SwiftUI environment values.
   - Per-request context (connection identity, authorization snapshot, request ID) travels as an explicit immutable value. A `TaskLocal` may carry it only inside one structured task tree, never as a silent fallback. Detached tasks, queues, and callbacks receive an explicit snapshot. Missing or mismatched authorization fails closed.
   - Stateless immutable shared constants are fine; the target is mutable authority, not the word `shared`.
5. **View models are leaves.**
   - Only views and the composition root reference a view model.
   - Domain, runtime, MCP, and provider types never nest inside one.
   - State that runtime code reads or mutates lives in a runtime-owned store that the view model observes.
6. **Logic and presentation are separate targets.**
   - Logic targets import neither SwiftUI nor AppKit. Combine and Observation are allowed where needed.
   - UI targets depend on logic, never the reverse.
   - This keeps most tests headless, and it makes UI-only targets eligible for default MainActor isolation.
7. **Add contracts only where they pay.** A protocol is introduced when it:
   - breaks a real cycle;
   - lets a consumer substitute an implementation (test double, headless vs. app); or
   - states an independently testable contract.

   It uses the consumer's stable vocabulary, stays narrow, and carries `Sendable` request and result values. With one implementation and no cycle, use a concrete type. Indexing, search, and parsing stay free of per-item existentials. There are no god protocols mirroring a god object.
8. **Every module owns its tests.**
   - Tests live in `<Module>Tests` and import the module they test.
   - Collaborators come from the module's `TestSupport` fakes.
   - `@testable import RepoPromptApp` is reserved for composition and integration tests.
9. **Structural moves and semantic changes never share a commit.** Moves are mechanical, scripted, and replayable; semantics change in separately reviewed commits.
10. **Every slice is measured.** A slice lands with before/after timings. A slice that does not pay back is reverted or redesigned.

### 3.2 Capability graph

This replaces a single linear layer stack. Families are peers unless an edge is listed. Arrows mean "may depend on".

| Family | Targets (initial) | May depend on |
| --- | --- | --- |
| **F0 Pure cores and contracts** | `RepoPromptFoundation` (Utilities, Concurrency primitives, clock and sorting helpers); `RepoPromptInstrumentation` (event/metric contracts plus a no-op sink); existing `RepoPromptWorkspaceCore`, `RepoPromptRegexCore` (plus the `Infrastructure/Regex` adapters), `RepoPromptCodeMapCore`, `RepoPromptShared`; `RepoPromptDiffing` (reconciled with any overlap in `RepoPromptDomainRuntime/Diffing`); C targets | Other F0 targets (acyclic), C targets, vetted value-level third-party libraries |
| **F1 Platform adapters** | `RepoPromptProcess`, `RepoPromptFileSystem`, `RepoPromptVCS`, `RepoPromptSecureStorage`, `RepoPromptPersistence` (document storage mechanics only, not feature schemas), `RepoPromptNetworking` | F0 |
| **F2 Domain engines** | `RepoPromptDomainRuntime` (existing; the single MCP catalog, registry, and workspace/context authority); `RepoPromptWorkspaceContext` (plus `…Search` and `…CodeMap` orchestration targets as sized); `RepoPromptAIContracts` (model identity and provider-neutral runtime vocabulary, including today's `AgentModel*`); `RepoPromptAIProviders` (split per provider family where large, e.g. Codex app-server ~20k); `RepoPromptMCPServer` (transport, dispatch, admission, policy; binds to the DomainRuntime registry) | F0, F1, and the listed peer edges only: WorkspaceContext → DomainRuntime; AIProviders → AIContracts; MCPServer → DomainRuntime |
| **F3 Orchestration** | `RepoPromptAgentRuntime` plus sub-targets as sized: Transcript, SessionLinks, Codex runtime, Runners, ProviderBindings; headless agent tool bindings | F0–F2 |
| **F4 Feature logic** | `RepoPrompt<Feature>` for Prompt, Chat/Oracle, ContextBuilder, Settings, Workspaces, WorkspaceFiles, AgentModePresentation, MCPPresentation, Diagnostics | F0–F3; other features only through declared, reviewed edges |
| **F5 UI** | `RepoPromptDesignSystem` (generic rendering only); `RepoPrompt<Feature>UI` | DesignSystem: F0 only. Feature UI: its feature logic, DesignSystem, F0–F3 value types |
| **F6 Composition** | `RepoPromptApp` (composition, lifecycle, window affinity, app-bound MCP tool adapters, debug harness wiring); `RepoPromptMCPCore` (CLI implementation library) plus the thin `repoprompt-mcp` executable; `RepoPromptExecutable` | Anything below. Nothing depends on F6 |

### 3.3 Boundary rules for cross-cutting concerns

- **MCP tools.** Placement follows the capabilities a tool needs, not its name, and every tool keeps one canonical schema and one authority path through `RepoPromptDomainRuntime`.
  - Headless workspace operations live with their domain owner. Much of this is already in DomainRuntime.
  - Headless agent operations live in F3.
  - Tools that need windows, `WindowState`, or UI selection are app adapters registered by composition.
  - No second registry and no service locator.
- **Settings.** The versioned settings document, its recovery lanes, and schema stamping (see `docs/architecture/settings-persistence.md`) stay single and are owned by the persistence mechanics.
  - Each feature owns its typed settings facet: schema slice, defaults, and validation.
  - `GlobalSettingsStore.shared` is replaced by facet injection. There is no universal `SettingsStore` hub protocol.
  - The Settings UI may remain a top-level aggregator of feature-provided panes.
- **Instrumentation and diagnostics.**
  - Event shapes and sink contracts live in `RepoPromptInstrumentation` (F0) and default to no-op.
  - Engines emit through injected sinks.
  - Diagnostics engines live where their data lives. Diagnostics UI is an F5 target, and debug harness wiring stays in the composition root.
  - Low layers never import the Diagnostics feature.
- **Notifications, deep links, windows.** Runtime code emits intents: a notification request value or a deep-link route value. The app delivers them. Window registry and active-context lookups are narrow capabilities passed explicitly.
- **Design system.**
  - Generic, settings-free rendering primitives only.
  - Components that reference feature types today, such as `Infrastructure/UI/Agent` and pieces referencing `WorkspaceFilesViewModel`, move to their feature's UI target.
  - `FontPreset` values move down. The active preset and scale are supplied through the environment by composition, instead of `FontScaleManager.shared`.
- **Provider plugins.** The two-bridge rule in `provider-plugins.md` survives every move. No raw package imports outside the bridges.

### 3.4 Physical packaging

**Decision: root-package targets first; separate packages only by exception.**

- **While types are still moving, targets in the root package are the right boundary.** `package` access and target dependency declarations give real compile boundaries without committing unstable internal types to `public` API. Dependency declarations plus the import check and the allowlist enforce intent.
- **A family becomes a local package only if** it has an independent consumer or release boundary (as the provider package does), its API has stabilized, or the P0 benchmark proves a material gain that targets cannot provide. The P0 gate: at least 30% lower median edit→owning-test time excluding queue, with no more than 10% regression in clean release build or indexing time, complete CI test discovery, and no public exposure of mutable implementation types.
- **Targets alone do not fix the focused-test loop on native SwiftPM.** Native SwiftPM links one aggregate test bundle per package; §3.6 covers this. The program therefore selects a *focused-test executor* in P0 (§8, P0.3) instead of assuming that target count creates speed.

### 3.5 Contract policy (applying principle 7)

Contracts are candidates only for:
- workspace selection and projection;
- VCS and filesystem where substitution is needed;
- per-feature settings facets;
- AI provider runtime;
- MCP tool invocation context;
- agent session host;
- window registry;
- instrumentation sinks;
- notification intents.

Each needs a named consumer and a test that substitutes it. Hub types with high fan-in are first *investigated* with index-store evidence; high fan-in is not proof that a protocol is needed.

### 3.6 Test architecture

- **Ownership.** Tests move with their code, in the same slice, into `<Module>Tests`. Shared fakes and builders live in `<Module>TestSupport` library targets placed under `Tests/`, never under `Sources/RepoPrompt`. A guardrail forbids production targets from importing them.
- **Hermeticity.** Filesystem roots, key-value storage, clocks (`any Clock<Duration>`), process launching, and notification delivery are injected. Tests stop reading the real `HOME`, `UserDefaults.standard`, or wall-clock sleeps. Hermeticity is fixed in the slice that moves each test, not in a separate late phase.
- **Parallelism.** In-process parallel execution is enabled per module once its tests are hermetic. The CI per-suite-process isolation is retired only for modules proven hermetic.
- **Pyramid.** Logic targets carry the bulk of fast unit tests. App-level integration tests shrink to composition, lifecycle, and cross-feature flows.
- **Verified toolchain facts** (throwaway package, Swift 6.3.3):
  - Native SwiftPM builds one aggregate `ExpPackageTests.xctest` for all test targets.
  - `--build-system swiftbuild` (preview) builds one bundle per test target, and `swift build --build-system swiftbuild --product ATests` builds only that bundle's closure.
  - `package` access does not cross package boundaries.
  - `--explicit-target-dependency-import-check error` reports undeclared intra-package imports.

### 3.7 Concurrency per module

- Every extraction runs through the existing migration ledger: record target mode, new cross-module `Sendable`/isolation diagnostics, and escape hatches.
- Moving a declaration across a module boundary changes `Sendable` checking, isolation inference, and conformance usability, even with no new Swift 6 feature enabled. These are handled in the slice, not deferred.
- New targets start in the package default mode with complete checking where clean. Target-local Swift 6 promotion is a separate, evidenced step.
- Default MainActor isolation applies only to UI-only targets. Orchestration, providers, persistence, and MCP dispatch must never inherit it.

---

## 4. Seam catalog (initial decoupling backlog)

Derived from the graph evidence (Appendix B). P0.2 validated every entry against the index store (ledger, P0.2). Rows the index changed (S2, S4, S5, S8, S9, S11, S12, S13, and the new S17) carry index counts. Confirmed rows keep their triage counts; the ledger has their index counts. Each slice re-checks its seam with `modularization_index_graph.py readiness` before it starts.

| ID | Seam | Evidence | Resolution |
| --- | --- | --- | --- |
| S1 | Fonts in App | `FontPreset` 85 and `FontScaleManager` 77 wrong-way edges; `FontScaleManager.shared` ×130 | Preset values → DesignSystem; active scale/preset via environment; settings-backed authority stays in composition |
| S2 | Window composition leakage | `WindowState` 54 wrong-way edges, mostly through its members; `WindowStateManager` 29; `WindowStatesManager.shared` 116 refs in 35 files | Narrow window-registry and active-context capabilities passed explicitly; window-bound tools stay app adapters; `WindowState` split into per-feature assemblies late (W7) |
| S3 | Agent VM as runtime hub | 50 lower-layer files use `AgentModeViewModel.*` nested types; 13 hold stored VM references; `AgentModeViewModel+Types` fan-in 55 | Hoist neutral values to F3; runtime-owned session store observed by the VM; runtime never references the VM |
| S4 | Codex turn state in `AgentTabSession` | The 15 nested `AgentTabSession.Codex*` types are used from only 4 files. Codex-prefixed members and types of the session (156) are used from 19 files, 14 in `AgentMode/Runtime`. `AgentTabSession` 36 wrong-way edges | Move Codex turn state, not just its identity types, into a store owned by the Codex runtime target; the session holds a reference to it |
| S5 | MCP request/authority snapshots nested in `MCPServerViewModel` | `MCPServerViewModel+TabContext.swift` 25 wrong-way edges. Refs in other files: `RequestMetadata` 63 in 16 files, `TabContextSnapshot` 47/14, `ResolvedTabContextSnapshot` 34/10, `FrozenFileToolAuthority` 25/6, `DomainReadAppExecutionContext` 16/6, `ConnectionBindingSnapshot` 13/3. 10 files hold stored VM references (triage count; not index-derivable) | Immutable invocation-context values in `RepoPromptMCPServer`; VM keeps presentation only |
| S6 | Ambient dispatch context | `ServerNetworkManager.shared` ×119, including `currentConnectionID` and `currentToolDispatchAuthorization` | Explicit `ToolInvocationContext` threaded through dispatch; fail closed; idempotent against duplicate request IDs and cancellation |
| S7 | Global settings hub | `GlobalSettingsStore.shared` ×115; `GlobalSettingsManager` fan-in 73 | Storage mechanics in F1; feature-owned typed facets; one document and schema preserved |
| S8 | Workspace-files VM used below | `WorkspaceFilesViewModel` fan-in 33, 10 wrong-way edges from 8 components (UI/TextField, MCP/WindowTools, WorkspaceContext, UI/Mentions, MCP/ApplyEdits, MCP, Diffing, Search). The triage count of 76 was mostly `relativePath` name collisions | Selection/projection contracts owned by WorkspaceContext; VM consumes them |
| S9 | Misplaced values | `WorkspaceModel` 37 wrong-way edges; `MCPFilesystemConstants` 6, `ChatPreset` 3, `FileSystemItems` 2, `CopyPresetOverrides` and `ToolResultDTOs` 1 each. `SortingUtils` and `toolIcon(for:)` were dropped: the index finds no wrong-way use | Move values to the lowest owning family; invert behavior |
| S10 | Provider/model vocabulary inside Agent Mode | AI → AgentMode: 135 edges from 60 files (`ACPAgentProvider`, `AgentRuntimeProviderService`, `AgentModel`, `AgentModelCatalog`, `AgentModelParameter`, `HeadlessAgentProvider`, `AgentACPModelRegistry`) | `RepoPromptAIContracts` owns model identity and neutral runtime DTOs; raw values unchanged |
| S11 | MCP tool implementations call into features | `Infrastructure/MCP` outside `MCP/ViewModels`: → `AgentMode/Runtime` 45, → `Features/*/Models` 56, → other view models 83, → `App` 38. `MCP/WindowTools` → layers above MCP: 124 edges from 15 files | Placement by required capability (§3.3) |
| S12 | Diagnostics used by engines | `AgentModePerfDiagnostics` 39 wrong-way edges; `WorktreeStartupInstrumentation` 20 from 9 components; `WorkspaceRestorePerfLog` 13; `MCPToolExecutionDiagnostics` 8; `AgentSessionLinkCatalogDiagnostics` 3 | Instrumentation contracts in F0; implementations injected |
| S13 | App notifications used by runtime | `Notification.Name` members: `AppNotifications.swift` 39 wrong-way edges, `WorkspaceNotifications.swift` 6. Also `NotificationPreferences` 10, `AppDeepLinkRoute` 8, `NotificationService` 5, `UserNotificationCenterClient` 4, `AppNotificationPayload` 3, `AppNotificationCategories` 2 | Notification names (raw strings unchanged) and intent values in F0/F3; delivery in App |
| S14 | Bridging header | `-import-objc-header … -disable-bridging-pch` in `unsafeFlags`; only 5 Swift consumers (`ApplicationSecurity`, `SearchMatch`, `SearchPathFiltering`, `GitignoreCompiler`, `MCPConnectionManager`) | Classify each declaration. Wildmatch/gitignore → `RepoPromptC` (check `wildmatch.h` equivalence); `ptrace`/`sysctl` anti-debug → a narrow C target. Remove the app `unsafeFlags` only when proven equivalent |
| S15 | Tests depend on an executable | `RepoPromptTests` → `RepoPromptMCP`; 11 `@testable import RepoPromptMCP` files | `RepoPromptMCPCore` library plus a thin executable (the `RepoPromptExecutable` pattern), composed with DomainRuntime, not copied. Also unblocks native Xcode unit testing |
| S16 | God files | The 17 files over 5k lines (§1.3) | Split responsibilities in place, before any move, one boundary at a time. The three largest are late extraction candidates |
| S17 | Prompt and workspace-manager VMs used below | `PromptViewModel` 26 and `WorkspaceManagerViewModel` 20 wrong-way edges (triage graph: 13 and 8) | As S8: the lower family owns the contract or state; the VM consumes it. Confirm the consumers with `readiness` before the slice |

---

## 5. Build and test infrastructure (parallel track from day one)

1. **Structured timing.** Conductor records per-job phases (queue, plan, compile, emit-module, link, test execution) and peak RSS as structured data, not just logs. A scheduled measurement lane captures `-driver-time-compilation`, `-Xfrontend -debug-time-function-bodies`, and `-stats-output-dir`. Dashboards feed the ratchets.
2. **Fixed per-job overhead (done).** The per-job conductor ticket defeated SwiftPM's environment-keyed manifest cache, and `swift test` re-planned in the sandbox. Both are fixed: a no-change focused job went from 74.7 s to 2.2 s (ledger, P0.4).
3. **Focused-test executor.** Build a module index (suite → test target → module) and add `dev-test MODULE=X`. `FILTER` resolves to its owning test target, and only that closure is built, using the executor chosen in P0.3. Until then, conductor reports the whole-graph build cost honestly.
4. **Admission v2.** Replace the capacity-1 heavy slot with admission weighted by each job's *measured* peak RSS and CPU for its actual build closure. Small module jobs then run concurrently while app packaging stays exclusive, and fairness is kept.
5. **Cross-worktree reuse.** Extend the existing seed store. Evaluate content-addressed compilation caching (available with Swift Build / Xcode 26) as a cache shared across worktrees. Adopt it only with correctness evidence (clean-vs-cached binary equivalence and test parity).
6. **Link-time levers.**
   - Evaluate `-Xlinker -no_deduplicate` for debug test bundles.
   - Evaluate debug-only dynamic linkage for large leaves only under the singleton-identity rule: no module may be linked into two images.
   - Neither is adopted without measured gains and parity checks.
7. **Type-check budgets.** Run `-warn-long-function-bodies` and `-warn-long-expression-type-checking` in the measurement lane and ratchet the counts. Large SwiftUI bodies are the usual suspects.
8. **CI.**
   - Build once per run and fan out verified artifacts, or restructure shards so there is one build per runner. Artifact handoff must be proven to preserve paths, resources, and signing.
   - Fix cache effectiveness (mtime restoration or content-addressed caching), verified by rebuilt-file counts.
   - Enforce `--explicit-target-dependency-import-check error`.
   - Run affected-target selection for PRs, including reverse dependencies and manifest/resource/script changes.
   - Keep the full suite on main and nightly.
9. **Xcode workspace generator.** Emit per-module test schemes if the xcodebuild executor wins P0.3. Enable native Xcode unit testing once S15 lands.

---

## 6. Governance

1. **Module catalog.** `docs/architecture/modules.md` is the canonical list: family, owner area, allowed dependencies, language mode, isolation default, test target, and TestSupport target. A machine-readable twin (for example `Scripts/modularization/modules.json`) is validated against `Package.swift` by the guardrails. `source-layout.md` links to it and keeps its existing constraints.
2. **Guardrails.** Extend `Scripts/source_layout_guardrails.sh` with:
   - the allowed-edge matrix;
   - forbidden imports (SwiftUI/AppKit in logic targets, `RepoPromptApp` anywhere, TestSupport in production);
   - no `static shared` mutable authority in extracted targets (allowlist for immutable constants);
   - a rule that new files for a family that already has a module go in that module, not `RepoPromptApp`;
   - the existing DomainRuntime, CodeMap, scanner, and executable-shell protections.
3. **Ratchets.** `docs/migrations/build-modularization/ratchets.json` stores baselines for every §2.2 metric. CI fails on regression, and each improving slice lowers the baseline.
4. **Size budgets.** New files: 800 lines soft, 1,500 hard. Module review trigger: 40k lines. Existing files over 2,000 lines are ratcheted.
5. **Decision records.** Kept in the ledger:
   - ADR-01 root targets first and the packaging gate;
   - ADR-02 capability graph and allowed edges;
   - ADR-03 contract policy;
   - ADR-04 composition root and injection;
   - ADR-05 logic/UI split;
   - ADR-06 test ownership and hermeticity;
   - ADR-07 focused-test executor;
   - ADR-08 admission and caching;
   - ADR-09 per-module concurrency.
6. **Ledger.** `docs/migrations/build-modularization/ledger.md`, mirroring the concurrency ledger. For each slice it records the move manifest, symbol map, conductor tickets, before/after timings, compatibility checks, ratchet deltas, and any temporary alias with its owner and removal deadline.

---

## 7. Migration method: the slice protocol

A slice is one boundary, lands in 1–3 PRs, and takes days, not weeks. Each slice is sized for one primary writer (human or agent) plus read-only probes.

1. **Select** a boundary with a small closure, using the graph tool's *extraction readiness* report: references from the candidate file set to anything outside itself and already-extracted modules.
2. **Publish** the source-and-test move manifest and symbol map in the ledger.
3. **Semantic pre-work PR(s)**, behavior-preserving:
   - hoist the nested values this boundary needs;
   - invert the specific mutable authority it touches;
   - split the god-file responsibilities it requires;
   - retarget its tests to the new seam and make them hermetic.
4. **Mechanical move PR**, with no semantic edits:
   - create the target, owning test target, and TestSupport;
   - `git mv` the files;
   - apply the access-control codemod (`package` inside the root package; `public` only at a real package boundary);
   - update `Package.swift`, the module catalog, guardrails, the conductor module index, and the Xcode generator if affected.
5. **Validate:**
   - the compatibility checklist (§7.2);
   - both products where shared contracts moved;
   - owning tests and dependents' tests;
   - a non-disruptive live smoke check;
   - a release-configuration build and Repo Bench for hot-path modules.
6. **Measure** before and after (edit→owning test, app incremental build, clean build, memory), record the results, and ratchet the new boundary.
7. **Revert as a unit** if any gate fails.

### 7.1 Codemods

SwiftSyntax tools live in a separate tools package that is never linked into products. They are idempotent and versioned against source patterns, and they reject unmatched sites rather than guessing. Operations:
- hoist nested type (with an optional temporary typealias that has an owner and a deadline);
- lift access levels from compiler diagnostics;
- synthesize memberwise `public` initializers, only at package boundaries;
- insert and remove imports;
- retarget test imports.

After a conflict, replay the codemod on current `main` instead of rebasing a move.

### 7.2 Compatibility checklist (per slice)

- Persisted raw values and Codable keys; secure permission documents; workspace journals.
- **Runtime identity:** run the P0.6 slice checklist in the ledger ("P0.6 compatibility inventory"). It covers:
  - type-name-dependent strings: `String(reflecting:)` (14 files, diagnostics except two module-invariant sort keys, one pinned by a golden), `#fileID`, bridged `NSError` domains, and runtime class names (the guardrail forbids keyed archivers and `NSStringFromClass`);
  - `Bundle.main` lookups (21 files, app-only roots enforced by the guardrail) and resources (no production `resources:` or `Bundle.module`);
  - the `ModularizationCompatibilityGoldenTests` goldens.
- MCP tool names, schemas, and fingerprints (DomainRuntime catalog tests); CodeMap artifact bytes (goldens); notification names.
- Sparkle linkage, conditional Sentry linkage, signing, entitlements, `Scripts/package_app.sh`.
- Static-linkage singleton identity: no module duplicated across images.
- Release performance: cross-module generic specialization on hot paths (`@inlinable` only where measured).
- `Sendable`, isolation, and conformance diagnostics at the new boundary (ledger).

### 7.3 Working alongside high-velocity development

- No program-wide freeze.
- Each boundary-changing slice gets a short announced merge window of days. The mechanical move merges quickly, and in-flight branches re-apply through the codemod.
- Temporary aliases are allowed only for one named migration, with an owner and a removal deadline.
- No parallel logic, registries, or long-lived branches.

---

## 8. Roadmap

Waves proceed bottom-up by dependency closure. P2 and later waves interleave: decouple a boundary, then extract it, then choose the next. The infrastructure track (§5) runs alongside from P0. Progress is tracked by ratchets and measured outcomes, not dates.

### P0 — Evidence and decisions (no production code moves)

- **P0.1 Timing.** Structured conductor timing and the measurement lane (§5.1). Publish the baseline.
- **P0.2 Graph tool.** An index-store dependency tool, replacing the regex prototype in Appendix A. It reports exact symbol references file→file, SCCs, wrong-way edges, and extraction readiness. Validate the top 40 offenders and the seam catalog with it.
- **P0.3 Focused-test executor bake-off** on the real repository, for two slices: one leaf and one workspace/agent-adjacent. Candidates:
  - (a) native aggregate bundle (baseline);
  - (b) `--build-system swiftbuild` with `--product <T>Tests`;
  - (c) xcodebuild with per-module schemes;
  - (d) a local package for the slice.

  Measure cold and warm edit→test, test discovery completeness, resources, peak RSS, disk, and CI parity. This decides ADR-07 and exercises the §3.4 packaging gate.
- **P0.4 Fixed per-job overhead** (§5.2) — done; see ledger.
- **P0.5 Link and type-check levers** measured (§5.6, §5.7) — done; see ledger.
- **P0.6 Compatibility inventory** (§7.2) captured as golden tests where missing — done; see ledger.
- **P0.7 Ratchets file** with baselines, and a guardrail skeleton that fails only on regression.
- **Exit gate:** baseline recorded; ADR-01…09 decided with evidence; the graph tool agrees with the top offenders; no production behavior changed.

### P1 — Guardrails and tooling

- **P1.1** CI import check set to `error`; allowed-edge enforcement for existing targets.
- **P1.2** Codemod toolkit and module template (`make new-module NAME=… FAMILY=…`).
- **P1.3** Conductor module index, `dev-test MODULE=`, the P0.3 executor, and admission v2.
- **P1.4** CI build-once and cache fixes (independent of modules).
- **Exit gate:** a pilot module can be created, tested with the focused executor, guarded, and measured end to end.

### Waves

| Wave | Scope (seams) | Expected outcome |
| --- | --- | --- |
| **W1 Foundations and unblockers** | S14 bridging header; S15 `RepoPromptMCPCore`; Foundation utilities and Concurrency; Diffing; S12 Instrumentation contracts; Process; SecureStorage; DesignSystem primitives with S1 fonts | First focused-loop win; M1 milestone; roughly 20–30k lines out of the app |
| **W2 Platform adapters** | FileSystem; VCS (`GitService` decomposition); Persistence mechanics with S7 storage split; Networking | 23 Platform-only test files move; low layers free of feature types |
| **W3 Workspace engine** | S8; in-place decomposition of `WorkspaceFileContextStore` and `WorkspaceCodemapBindingEngine`; then WorkspaceContext, Search, and CodeMap orchestration targets | The largest hot-path engine becomes independently testable. Guard with Repo Bench and CodeMap goldens |
| **W4 AI** | S10 `RepoPromptAIContracts`; providers per family (Codex app-server as its own target); ACP; Claude two-bridge rule kept | Provider edits stop rebuilding Agent Mode |
| **W5 MCP server** | S5, S6, S11; `RepoPromptMCPServer`; tool placement; DomainRuntime remains the sole authority | Ambient dispatch context eliminated; MCP tests headless |
| **W6 Agent orchestration** | S3, S4; `AgentModeViewModel` decomposition into a runtime-owned session store; Transcript, SessionLinks (20k), Codex runtime (12k), Runners, ProviderBindings | App-level tests retarget to runtime tests; the largest share of the 82k lines of god-object tests shrinks |
| **W7 Features, UI, composition** | Logic/UI splits per feature; MCPPresentation; Diagnostics split; S2 window capabilities; per-feature assemblies; `WindowState` slimmed | `RepoPromptApp` becomes composition only (≤ 10% target) |
| **Continuous** | Hermetic tests and parallel execution per moved module; per-module Swift 6 promotion via the ledger; god-file ratchet | — |

Each wave ends when its seams are closed, its tests are owned by module test targets, and its ratchets reach target.

---

## 9. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Moves silently change runtime identity (resources, type names, catalogs, singletons) | §7.2 checklist, golden tests from P0.6, a no-duplicate-image rule, and a release smoke check per slice |
| Unstable internal types become frozen `public` API | Root targets and `package` access first; packages only past the §3.4 gate |
| Claimed gains that never reach the everyday command | Measure the real `dev-test` path; no success claim while the aggregate bundle is linked; P0.3 executor decision |
| Merge conflicts with daily multi-agent merges | Short slices, mechanical/semantic separation, codemod replay, announced merge windows |
| Protocol proliferation, existential cost, generic compile blow-up | Contract policy (principle 7); concrete hot paths; Repo Bench and type-check budgets |
| Concurrency diagnostics surge when types cross modules | Handled per slice in the ledger; default MainActor only for UI-only targets |
| Release performance regressions from lost cross-module specialization | Release build plus Repo Bench per hot-path slice; `@inlinable` only on measured paths |
| Queue remains the bottleneck | Separate infrastructure track (§5.4, §5.5), reported separately in every measurement |
| God-object decomposition changes ordering or cancellation semantics | In-place splits first with existing tests; preserve ordering, cancellation, and CAS invariants; behavior diffs reviewed separately |
| Program stalls midway, leaving two architectures | Ratchets make regressions impossible; each wave independently valuable; module catalog is the single source of truth |

---

## 10. Alternatives considered

- **Quick wins only** (filter-aware conductor builds, `--parallel`, bridging-header removal). These are correct and are included in P0/P1/W1, but the floor stays at monolith invalidation plus aggregate linking.
- **Eight local "band" packages up front.** Rejected as the default. It forces `public` API on unstable types, duplicates lower-layer builds per package, and root `swift test` would not run dependency packages' tests. Kept as a gated option per family.
- **Bazel (`rules_swift`), Buck2, or Tuist.** Strong per-target caching and testing, but they replace SwiftPM, conductor, and the Xcode generator for an open-source project, at a large permanent cost. Revisit only if SwiftPM plus Swift Build cannot meet §2 after W3.
- **Debug dynamic frameworks by default.** A link-time lever with singleton-identity risk; evaluated in §5.6 only.
- **Big-bang rewrite branch.** Rejected: it cannot survive daily multi-agent merges.

---

## 11. Open decisions and their gates

| Decision | Gate |
| --- | --- |
| Focused-test executor (native / swiftbuild / xcodebuild / package) | P0.3 measurements |
| Package extraction for any family | §3.4 criteria |
| Compilation caching across worktrees | §5.5 correctness evidence |
| Debug dynamic linkage | §5.6 measured gain plus the no-duplicate-image rule |
| Default MainActor isolation per UI target | Concurrency ledger evidence per target |
| Swift Testing as the default for new tests | P1 policy decision; no bulk conversion |

---

## Appendix A: Method and caveats

- **Timing.** Conductor job logs under `~/Library/Application Support/RepoPrompt CE/Conductor/*/jobs/`.
  - Job duration is log birth time → last write, minus the parsed "acquired fair global heavy slot … after X" wait.
  - Jobs are classified by log content: test runner present; `Compiling RepoPromptApp` or `Compiling RepoPromptTests` lines; `Executed N tests`.
  - These are approximations over mixed workloads and worktrees. P0.1 replaces them with structured records.
  - Reproduce with `python3 Scripts/conductor_job_timings.py`. An earlier ad-hoc parse misread millisecond waits (`739ms`) as minutes and overstated the median wait as 12.3 min; the tested parser supersedes it.
- **Dependency graph.** `Scripts/modularization_metrics.py` (regex-based) over comment- and string-stripped sources.
  - Declarations: top-level `class`/`struct`/`enum`/`actor`/`protocol`/`typealias` with names of at least 5 characters, plus top-level `func`/`let`/`var` names of at least 6 characters.
  - Edges only to names declared in at most two files, aggregated by folder component. Layers are a *triage ordering*, not the §3.2 target design.
  - It undercounts extension-member use and overload-resolved references and can misattribute same-named symbols. P0.2 replaces it with index-store data.
- **Test coupling.** The same declaration map, applied to `Tests/RepoPromptTests`. "App-level" means the file references `WindowState`, `WindowStatesManager`, `WindowStateManager`, `AgentModeViewModel`, `WorkspaceManagerViewModel`, `WorkspaceFilesViewModel`, `PromptViewModel`, `MCPServerViewModel`, or `AppDelegate`.
- **Toolchain experiment.** A throwaway package with targets A, B, C, test targets ATests and BTests, and a local path package L, built with native SwiftPM and `--build-system swiftbuild` on Swift 6.3.3.
- **CI.** `gh run view` job and step timings for main run 36332152793.

## Appendix B: Top wrong-way dependency targets (index store)

This table is now index-derived; it replaces the regex triage table. Source: the P0.2 graph, `python3 Scripts/modularization_index_graph.py report --top 40` at HEAD `9e912a86` (ledger, P0.2). The index graph has 1,360 wrong-way file edges into 253 files. The top 20 targets account for 53% and the top 40 for 68%. The triage figures in §1.3 (1,104 edges, 201 files, 58% and 73%) are the regex graph's, kept as the original evidence. The two graphs share components, layer ranks, and the wrong-way rule, so their counts are comparable.

| Wrong-way edges | Target file |
| --- | --- |
| 92 | `App/FontPreset.swift` |
| 77 | `App/FontScaleManager.swift` |
| 54 | `App/WindowState.swift` |
| 43 | `Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift` |
| 43 | `Features/AgentMode/ViewModels/AgentModeViewModel.swift` |
| 39 | `App/Notifications/AppNotifications.swift` |
| 39 | `Features/Diagnostics/AgentMode/AgentModePerfDiagnostics.swift` |
| 37 | `Features/Workspaces/WorkspaceModel.swift` |
| 36 | `Features/AgentMode/ViewModels/AgentTabSession.swift` |
| 35 | `Features/AgentMode/Providers/ACP/ACPAgentProvider.swift` |
| 29 | `App/WindowStateManager.swift` |
| 26 | `Features/Prompt/ViewModels/PromptViewModel.swift` |
| 26 | `Infrastructure/MCP/ViewModels/MCPServerViewModel.swift` |
| 25 | `Features/Settings/Models/GlobalSettingsManager.swift` |
| 25 | `Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift` |
| 22 | `Features/AgentMode/ViewModels/AgentModeViewModel+Types.swift` |
| 20 | `Features/Diagnostics/App/WorktreeStartupInstrumentation.swift` |
| 20 | `Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift` |
| 17 | `Features/AgentMode/Models/ModelSelection/AgentModelCatalog.swift` |
| 17 | `Infrastructure/MCP/MCPIntegrationHelper.swift` |
| 16 | `Features/AgentMode/Models/ModelSelection/AgentModel.swift` |
| 14 | `Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift` |
| 13 | `App/AppDomainRuntimeComposition.swift` |
| 13 | `Features/Diagnostics/App/WorkspaceRestorePerfLog.swift` |
| 12 | `Infrastructure/MCP/RepoPromptMCPServerConfiguration.swift` |
| 10 | `App/Notifications/NotificationPreferences.swift` |
| 10 | `Features/AgentMode/Models/UserInteractionModels.swift` |
| 10 | `Features/AgentMode/Providers/HeadlessAgentProvider.swift` |
| 10 | `Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift` |
| 10 | `Infrastructure/WorkspaceContext/Models/WorkspaceRootSeedModels.swift` |
