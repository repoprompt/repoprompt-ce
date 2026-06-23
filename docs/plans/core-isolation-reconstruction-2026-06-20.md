# Core Isolation Reconstruction: Execution Plan

**Date:** 2026-06-20
**Source investigation:** `docs/investigations/core-isolation-reconstruction-2026-06-20.md`
**Execution boundary:** Phases 0–8; Phase 9 cleanup and headless/Core convergence are deferred.

## Goal

Reconstruct Core isolation on top of current `dev` behavior without replaying obsolete snapshots. Land dedicated neutral, macOS, POSIX, syntax-bridge, and standalone-headless targets; move workspace/session authority atomically; preserve app-proxy compatibility; and ship an independently packaged direct-stdio headless v1.

## Locked scope

- **Current behavior wins.** Commits `f86746c8` and `444c599c` are architectural references, not cherry-pick candidates. Current validated-root, generation, watcher, search, selection, prompt/review, MCP, and generated-Xcode behavior prevails where histories differ (`docs/investigations/core-isolation-reconstruction-2026-06-20.md:12-47,208-234`).
- **Dedicated roots.** Add `Sources/RepoPromptCore`, `Sources/RepoPromptCoreMacOS`, `Sources/RepoPromptPOSIXSupport`, `Sources/RepoPromptSyntaxCBridge`, and `Sources/RepoPromptHeadless`, plus matching test roots.
- **One writable authority.** Select `legacy` or `core` once, before session construction. Shadow comparison may consume immutable snapshots but may not hydrate watchers, persist, allocate revisions, or accept commands.
- **Policy stays in the app.** App paths, UserDefaults, approvals, mutation policy, Git/review authorization, visible lifecycle, and diagnostics presentation remain in `RepoPrompt`.
- **Transport identities stay separate.** `repoprompt-mcp` remains the app bootstrap-socket proxy. `repoprompt-headless` is a separate direct-stdio product, package, state root, secret namespace, and smoke lane.
- **Headless v1 is a fenced parallel runtime.** It may reuse neutral Core values and CoreMacOS/POSIX adapters, but it does not instantiate `WorkspaceSessionController`, `RepoPromptCoreSession`, or the app's file-context engine. Its duplicate mutable root/state/tool runtime is inventoried explicitly; adoption of the shared Core session graph is Phase 9+.
- **Plan-only change now.** Execution creates the prescribed `docs/core-isolation/` record; this planning pass creates no other artifact.
- **No opportunistic scope.** Persisted workspace schemas, cross-platform support, app policy/UI extraction, unrelated MCP provider/catalog work, and compatibility cleanup are out of scope.

## Current seams that constrain the plan

- `Package.swift:45-116` defines a monolithic app target, the app-proxy target, and one app-linked root test target; the app bridging header exposes POSIX, Tree-sitter, RepoPromptC, and PCRE2 declarations target-wide (`Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h:9-67`).
- Package assumptions are repeated in source-layout guards, Xcode generation, conductor product/test commands, the test optimizer, packaging, and CI (`Scripts/source_layout_guardrails.sh:24-152,196-243`; `Scripts/generate_xcode_workspace.py:60-153,379-644`; `Scripts/conductor.py:1058-1124,3463-3470,3687-3740`).
- Compose-tab `StoredSelection` is currently canonical; revision-fenced mutation, UI mirroring, and peer propagation meet in `WorkspaceSelectionCoordinator` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Selection/WorkspaceSelectionCoordinator.swift:42-65,311-495,597-775`).
- Workspace arrays, switching, readiness, persistence metadata, and disk-write reconciliation remain in `WorkspaceManagerViewModel` (`Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:242-309,2858-3164,3339-3373,4196-4551,6968-7158`).
- `WorkspaceFileContextStore` owns root lifetimes, accepted ingress, watchers, catalogs/generations, indexes, search, and fail-closed validated worktree scopes (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:1666-1860,2311-2580,2719-2761`).
- Prompt policy and review authority precede factual workspace projection; Core must receive frozen authorized inputs, never a capability to rediscover Git authority (`Sources/RepoPrompt/Features/Prompt/Services/PromptContextPreAssemblyService.swift:109-225`).
- `repoprompt-mcp` is explicitly an app proxy with bootstrap/retry/bridge-ledger behavior and fixed bundle/install identities (`Sources/RepoPromptMCP/main.swift:1647-2003,2429-2457`; `Scripts/package_app.sh:212-245`).
- Test listing and ledger reconciliation currently recognize only root/provider inventories (`docs/testing.md:34-97`; `Scripts/test_suite_optimizer.py:224-269,660-714,860-891`).

## Target architecture

Phase 0 freezes the exact third-party product list before Phase 1. These direct edges are the required final contract; transitional edges must be recorded in the migration ledger and removed by the owning phase.

| Target | Allowed direct dependencies / ownership |
| --- | --- |
| `RepoPromptSyntaxCBridge` | `TreeSitterScannerSupport` plus grammar products; declarations/linkage only, no duplicate upstream symbols |
| `RepoPromptCore` | `RepoPromptC`, `CSwiftPCRE2`, `SwiftTreeSitter`, `RepoPromptSyntaxCBridge`, Foundation, and neutral packages confirmed in Phase 0 |
| `RepoPromptPOSIXSupport` | System C/POSIX APIs only; narrowly prefixed descriptor/socket helpers |
| `RepoPromptCoreMacOS` | `RepoPromptCore`, `RepoPromptPOSIXSupport`, charset products used by concrete content loading, and macOS frameworks |
| `RepoPrompt` | `RepoPromptShared`, `RepoPromptCore`, `RepoPromptCoreMacOS`, remaining app/UI/provider products, and `SwiftTreeSitter` only where UI highlighting still requires it |
| `RepoPromptMCP` | Existing `RepoPromptShared`/Logging/MCP/ServiceLifecycle/SystemPackage dependencies plus `RepoPromptPOSIXSupport` only for behavior-preserving helper moves |
| `RepoPromptHeadless` | `RepoPromptShared`, neutral values from `RepoPromptCore`, `RepoPromptCoreMacOS` adapters configured with headless paths/namespaces, `RepoPromptPOSIXSupport`, and frozen host-runtime packages; no app or `RepoPromptMCP` dependency |
| Dedicated test targets | Their owning production target plus only the fixture/support modules recorded in Phase 0; root integration may import app/MCP/Core modules |

Additional rules:

- `RepoPromptCore` may not import AppKit, SwiftUI, Security, Darwin, CoreServices, OSLog, or `os`.
- Core-facing content decoding is a neutral contract; UniversalCharsetDetection/Cuchardet stay behind the CoreMacOS implementation boundary.
- After their owning moves, `RepoPrompt` no longer directly owns `RepoPromptC`, PCRE2, scanner/grammar, or charset dependencies except UI-only syntax use documented by the inventory.
- Headless secure storage uses the CoreMacOS adapter with a distinct state path, service name, and access namespace; no app Keychain namespace is accepted.
- Core targets remain package-internal unless a real external consumer appears.

### Runtime ownership after Phase 5

- `WorkspaceSessionController` actor: canonical ordered workspaces, active identity, dirty/saved generations, selection revisions, persistence transactions, and immutable monotonically generated snapshots.
- `RepoPromptCoreSession`: owns one controller, file-context store, selection/slice/search services, and exactly-once teardown.
- `RepoPromptCoreSessionHandle`: Sendable command/query/snapshot facade; no arbitrary access to mutable actors.
- `RepoPromptCoreHost`: creates and retains session identities independently of windows.
- `RepoPromptAppCoreContainer`: composition root that selects one backend and injects app paths, platform adapters, diagnostics, and policy.
- `WorkspaceSessionObservationBridge`: `@MainActor` snapshot-to-presentation adapter; observation cannot call mutation paths.

State flow:

```text
UI/MCP intent
→ app policy and target validation
→ Core command with expected generation/revision
→ canonical mutation + persistence receipt
→ immutable snapshot
→ MainActor observation bridge
→ presentation/mirror update only
```

## Execution documentation packet

Phase 0 creates this compact execution record; do not create it during planning:

```text
docs/core-isolation/
├── README.md
├── decisions/
│   └── ADR-NNN-*.md
├── contracts/
│   ├── behavior-and-performance.md
│   ├── persistence-schema.md
│   └── headless-v1.md
├── migration-ledger.tsv
├── phases/
│   └── phase-N.md
└── deferred-work.md
```

| Artifact | Owner and mutation policy | Gate use |
| --- | --- | --- |
| `README.md` | Overall lead; mutable index/status | Names the active phase and links closed phases |
| `decisions/ADR-*` | Author + reviewer; immutable after acceptance, supersede rather than rewrite | Required for deviations or contract gaps |
| `contracts/*` | Subsystem + test owners; mutable until the owning prerequisite closes, then append-only corrections | Freezes behavior, persistence, headless, and performance oracles |
| `migration-ledger.tsv` | Engineers making moves; append-only after its Phase 0 schema freezes | One row owns each boundary declaration, dependency/call-site class, source/test ID move, and temporary alias |
| `phases/phase-N.md` | Phase lead + independent gate reviewer; mutable work/risk/evidence sections, append-only close disposition | Records exact commands/artifacts and explicit go/no-go in one place |
| `deferred-work.md` | Overall lead; append-only | Keeps Phase 9 cleanup/convergence visible and out of Phases 0–8 |

Inventory only boundary-crossing declarations and tests needed for the next phase; append newly discovered rows with provenance. The packet is an execution index, not a second issue tracker.

## Approach and work items

Phases are sequential gates. Work inside a phase may be batched only when the batch preserves single ownership and can be validated independently. Close each gate with its assigned test-matrix rows and the common validation ladder; do not duplicate evidence outside the phase record.

### Phase 0 — Characterize current behavior and freeze inventories

**Objective:** establish exact current contracts and destinations without production behavior changes.

1. Create the execution documentation packet and record current/historical revisions.
2. Populate the migration ledger for Phase 1–2 boundary declarations, direct dependency/product edges, affected call-site classes, live tests, persisted fields, bridged C declarations, and package identities. Later phases append newly discovered boundary rows with provenance rather than attempting an exhaustive repository census up front.
3. Freeze byte and semantic persistence fixtures: filenames/locations, field names, defaults, ordering, normalization, dates, dirty/saved generations, selection revisions, and stale-write reconciliation.
4. Run authoritative test lists; capture exact current IDs and scenario counts. Do not infer IDs from source.
5. Freeze the exact target-to-target and third-party product graph plus reviewed headless v1 CLI, NDJSON, tool, error, state, root, secret, permission, and shutdown contracts; current behavior wins where it overlaps.
6. Characterize all twelve P0 hazards using the test matrix below.
7. Record 3–5 comparable normal performance samples for catalog activation, search readiness, selection/prompt work, and packaged smoke. Diagnostics are evidence, not arbitrary XCTest thresholds.
8. Add characterization tests only where a plausible defect and discriminating oracle are missing.

**Gate:** every Phase 1–2 boundary row has an owner/destination; the twelve labeled P0 hazards have oracles; persistence/headless contracts and the exact package graph are frozen; the graph is acyclic.

**Rollback:** remove characterization-only additions; no production state changes.

### Phase 1 — Land package, harness, and guardrail scaffolding atomically

**Depends on:** Phase 0 inventories and target graph.

1. Add all five production targets and only one new executable product: `repoprompt-headless`. Reserve five matching test roots/prefixes, but declare each SwiftPM test target and conductor list lane only when its first meaningful contract test moves; never add placeholder XCTest methods.
2. Update `Package.swift`, source-layout rules, Swift style roots, generated Xcode manifest/schemes, conductor product/test/list commands, Make wrappers, CI, and architecture/testing docs as one control-plane change.
3. Add ledger vocabulary for `root/`, `provider/`, `core/`, `core-macos/`, `posix/`, `syntax-c-bridge/`, and `headless/`. Reconciliation must accept a reserved prefix with no live target/rows; once a target exists, its list operation becomes mandatory.
4. Update `test_suite_optimizer.py` source discovery, list collection, target choices, counts, and exact ledger reconciliation in the same landing; preserve existing root/provider IDs for unmoved tests.
5. Add compiler/guardrail enforcement for dependency direction, forbidden Core imports, canonical declaration ownership, controlled documentation, narrow C bridges, and app/headless packaging separation.
6. Reserve a repository-specific C-symbol prefix by ADR before introducing wrappers.
7. Keep the existing three Xcode convenience workflows; add a headless workflow only if it delegates to conductor rather than creating another build graph.

**Gate:** all production targets compile; every declared test lane is authoritative; reserved empty prefixes and live IDs reconcile across all seven prefixes; Xcode output is deterministic; negative guards reject reverse dependencies and forbidden imports.

**Rollback:** additive target/control-plane removal returns to the old graph; runtime ownership is unchanged.

### Phase 2 — Extract neutral leaves with one concrete owner

**Depends on:** Phase 1 enforcement.

1. Move Foundation-only workspace/root, readiness/catalog, path/scope, selection/slice, prompt/codemap, and neutral utility values in dependency-leaf batches.
2. Preserve names, cases, equality, defaults, ordering, errors, and `Codable` bytes—especially validated session-bound scopes and typed unavailability.
3. Raise access only where cross-module compilation requires it; split app/platform presentation extensions from neutral semantics.
4. Replace each moved concrete declaration with a temporary app typealias or narrow forwarding adapter. Never keep two implementations.
5. Move the lowest-faithful deterministic tests with each batch; update authoritative IDs, `migration-ledger.tsv`, curated ledger rows, notes, and scenario counts atomically.
6. Verify old bytes → new types and new bytes → legacy rollback backend.

**Gate:** one concrete owner per moved declaration; persistence and behavior remain identical; no unclassified compatibility alias.

**Rollback:** typealiases preserve call sites; legacy decoding remains valid.

### Phase 3 — Introduce platform seams and partition C bridges

**Depends on:** neutral types from Phase 2.

1. Derive narrow injected contracts from current call sites for watchers, directory/content access, mutation backends, process/descriptors, secure storage, diagnostics, and supplied runtime/cache paths.
2. Move FSEvents/CoreServices/filesystem/Keychain/signing implementations and resource lifetimes to `RepoPromptCoreMacOS`.
3. Replace platform/Combine callback ingress at the Core boundary with ordered neutral events while preserving accepted-ingress watermark semantics.
4. Move descriptor/socket helpers to `RepoPromptPOSIXSupport`; uniquely prefix every CE-defined C symbol.
5. Move Tree-sitter declarations/linkage to `RepoPromptSyntaxCBridge`; preserve scanner snapshots/checksums and never reimplement upstream symbols.
6. Remove moved declarations from the app bridging header only after every caller imports the new module.
7. Keep app path selection, UserDefaults, approvals, and diagnostics presentation in the app.
8. Provide deterministic seams for cancellation, late callbacks, descriptor closure, and platform failures.

**Gate:** neutral Core imports no platform modules; the bridging header no longer owns moved POSIX/syntax declarations; symbol inspection finds no duplicate implementation.

**Rollback:** app composes the same behaviors through adapters; no scope-broadening fallback is allowed.

### Phase 4 — Move the current workspace/file-context engine intact

**Depends on:** Phase 3 runtime dependencies.

1. Move `WorkspaceFileContextStore` and its catalog, lookup, search, slice, codemap, token, and neutral syntax collaborators in dependency order.
2. Inject Phase 3 dependencies; do not reconstruct watcher or filesystem semantics.
3. Preserve root lifetime IDs, ingress barriers/watermarks, root detachment before teardown, immutable generation leases, indexes/shards, admission/backpressure, bounded caches, deterministic ordering, cancellation, and typed unavailable scopes.
4. Keep the existing per-window app construction path temporarily; Phase 5 changes authority.
5. Move deterministic store/search tests to Core, platform lifetime tests to CoreMacOS, and retain only true app-composition tests under root.
6. Build a temporary old/new snapshot parity harness; it may compare immutable outputs but cannot dual-write.

**Gate:** root availability, catalogs, generations, indexes, search, watcher teardown, slices, codemap freezing, and cancellation match current behavior; material performance regressions block rather than redefine baselines.

**Rollback:** app still constructs the extracted engine through the legacy workspace authority.

### Phase 5 — Cut workspace authority over atomically

**Depends on:** extracted engine and frozen persistence contracts.

This landing must include backend selection, Core hydration, first-snapshot observation, command routing, app-write disablement, Core receipts, and one-writer assertions together.

1. Implement `WorkspaceSessionController`, session/handle/host, app container, and observation bridge from current load/switch/readiness/persistence semantics.
2. Keep Application Support and workspace-directory policy app-owned; pass resolved URLs into Core.
3. Select one backend at composition and expose one command-ingress protocol/handle to UI and MCP callers. The inactive backend is not constructed or registered.
4. Hydrate Core exactly once and publish the first immutable snapshot before activating command or MCP admission. Pre-activation requests fail with a typed not-ready result; they are neither queued nor retargeted.
5. Move legacy writable methods behind the legacy backend implementation. Common app view models receive only the selected command handle plus private projection setters; they contain no per-mutation `if core` fallback.
6. Convert `WorkspaceSelectionCoordinator` to expected-revision commands through that handle while retaining MainActor UI/MCP mirror fencing; remove direct compose-tab access from the common Core-mode surface.
7. Move disk-write reconciliation and dirty/saved generations behind the selected backend without changing encoding.
8. Preserve switch teardown/load/readiness ordering and exact commit/cancellation boundaries.
9. Enforce exclusivity with access control, constructor shape, dependency guards, and runtime assertions: only the selected backend can own writers/watchers/revisions, and snapshot application cannot reach command ingress.
10. Permit read-only shadow snapshots only. Keep the encapsulated legacy backend and construction switch through Phase 8 for next-launch rollback; do not retain legacy mutators on shared presentation types.

**Semantics:** stale commands return latest generation/revision; callers may recompute deterministic transforms, never blindly retry stale replacement values. Cancellation before admission changes nothing; a committed command is not rolled back, and persistence proceeds to the receipt's durability boundary.

**Gate:** common UI/MCP code has one mechanically exclusive command ingress; pre-activation work fails closed; no reachable Core-mode path can access legacy mutators or directly change app arrays, compose-tab selection, revisions, or persistence.

**Rollback:** select `legacy` before next-launch construction; never switch a live session.

### Phase 6 — Route factual prompt work through Core

**Depends on:** canonical Core snapshots and validated lookup contexts.

1. Split preassembly into app policy/frozen review capture, app authorization, Core factual capture/projection, app diff-provider invocation, and Core deterministic rendering/accounting.
2. Keep `FrozenPromptGitReviewContext` and `SelectedGitDiffArtifactAuthorizationService` app-owned.
3. Supply Core only frozen authorized artifact content/provenance/display aliases and validated workspace inputs—never live Git view models, workspace Git roots, or discovery capabilities.
4. Let Core resolve ordinary selected content, logicalize paths, place codemaps, construct factual file maps/entries, and calculate tokens.
5. Keep automatic/complete diff provider choice, fallback, compare intent, presets, envelope, clipboard/chat, and user instructions in the app.
6. Preserve rejection dispositions, bounded fallback, missing-worktree unavailability, empty-vs-unreadable artifacts, and physical-path redaction.
7. Move only purely factual tests to Core; retain authorization/orchestration tests under root.

**Gate:** current rendered output/accounting matches; Core APIs cannot discover Git authority; no physical worktree path leaks into output or diagnostics.

**Rollback:** app orchestration can return to legacy factual services at next construction without schema changes.

### Phase 7 — Split MCP runtime identity from weak UI adapters

**Depends on:** stable Core session identities.

1. Add an actor-owned runtime registry with `created → active → draining → removed` states, strong session handles, admitted-request counts, and immutable session/generation admission tokens.
2. Add a `@MainActor` weak app-adapter registry mapping compatibility window IDs to runtime sessions.
3. Register runtime identity before UI publication; activate only after the first authoritative workspace snapshot.
4. Resolve logical contexts against runtime snapshots while preserving current `MCPBindingResolver` external priority and error compatibility.
5. Bind each request to one admission token at start and require it downstream; never exchange it for a replacement session.
6. UI-required tools fail explicitly if their weak adapter disappears; runtime-capable admitted work may finish against its original draining session.
7. Transition the old runtime to draining before replacement activation; reject new work and never retarget admitted work.
8. Preserve `repoprompt-mcp` bootstrap socket, proxy entry, correlation ledger, retry/kill-signal/watchdog, bundle, and socket-owner behavior.

**Gate:** admitted work either completes against its original session or fails; external app-proxy routing/identity remains compatible; no headless code enters proxy routing.

**Rollback:** disable the new runtime registry only at construction; do not remap draining live work.

### Phase 8 — Ship independently packaged standalone headless v1

**Depends on:** Phase 0 frozen contract, Phase 1 graph/guards, Phase 2 neutral values, Phase 3 CoreMacOS/POSIX adapters, and Phase 7 proxy-identity proof. It does not depend on the Phase 4–5 mutable Core engine.

1. Add `repoprompt-headless` under `Sources/RepoPromptHeadless` with direct NDJSON stdin/stdout; send logs only to stderr/private artifacts. Its headless-owned root registry, state store, tool registry, and lifecycle are the explicitly tolerated duplicate mutable boundary.
2. Reuse neutral values plus CoreMacOS/POSIX adapters, but do not instantiate or wrap `WorkspaceSessionController`, `RepoPromptCoreSession`, or `WorkspaceFileContextStore`. Use a distinct versioned state root and configure the secure-storage adapter with a headless-only service/namespace; verify owner-only directories/files at creation and use.
3. Require explicit roots; validate containment, symlinks, and availability fail-closed.
4. Instantiate only the frozen read-oriented allowlist; mutation, VCS write, automation, agent launch, and external export are absent or default-denied.
5. Preserve exact framing, limits, errors, EOF, cancellation, state encoding, permission checks, and shutdown behavior from `contracts/headless-v1.md`. Contract gaps require an ADR.
6. Add independent build/package, install/status/uninstall, provenance/architecture, and direct-stdio roundtrip scripts.
7. Keep headless out of `package_app.sh` and the app bundle; keep existing app-proxy smoke app-proxy-only.
8. Extend conductor/build-all with separate headless operations/lanes.
9. Add malformed input, framing, EOF, cancellation, permission, root escape, denied-tool, isolated HOME/state/secret, and shutdown fixtures.
10. Record each duplicated mutable component and its intended Phase 9 Core replacement in `deferred-work.md`; do not claim shared-session convergence.

**Gate:** standalone and app-proxy identities pass independent lanes; headless cannot observe app roots, state, secrets, sockets, or denied capabilities.

**Rollback:** remove only the standalone artifact/install; preserve app/proxy behavior and leave private state according to the frozen uninstall contract.

## Test matrix

Use the lowest layer that faithfully reproduces each risk. Exact IDs come from implementation-time list commands; suite names are discovery anchors, not substitutes for authoritative IDs.

| Risk / phase | Observable oracle | Lowest faithful layer and anchors | Broader lane / ledger effect |
| --- | --- | --- | --- |
| **P0-01** Dual authority — 0, 5 | Selected backend records every command/receipt; inactive backend records no writes, revisions, watchers, or persistence | Core controller + root assembled integration; current selection/persistence coordinator suites | App/MCP affected tests; new/moved rows |
| **P0-02** Fail-open worktree — 0, 2, 4 | Missing/replaced physical root yields typed unavailable and zero broadened results | Core root-binding/store/search tests; preserve `WorkspaceRootBindingProjectionTests`, `WorkspaceFileContextStoreTests`, `StoreBackedWorkspaceSearchTests` | Root prompt/MCP worktree integration; move rows |
| **P0-03** Generation loss — 0, 4, 5 | Leased snapshots stay immutable; stale readiness/search generations cannot supersede current | Core store/catalog/path-index tests with controlled continuations | Root readiness integration; move rows |
| **P0-04** Selection loops/ABA — 0, 5 | Snapshot mirroring emits no new canonical revision; delayed old propagation loses; genuinely newer ABA wins | Core revision state machine + root MainActor coordinator integration | Selection/persistence suites; split rows by layer |
| **P0-05** MCP retargeting — 0, 7 | Admission token retains old session identity through replacement | Root registry race/in-process MCP tests; preserve distinct-connection and teardown coverage | Packaged proxy smoke; new root rows |
| **P0-06** Physical-path leakage — 0, 6 | Physical content is read while file maps, diffs, errors, and tools expose only logical labels | Core prompt fixture + root authorization/formatter tests | Prompt integration; move factual rows |
| **P0-07** Review authority — 0, 6 | Stale/mismatched/undelegated artifact is rejected; Core cannot enumerate Git authority | Root authorization/orchestration tests; dependency guard | Full prompt tests; authorization rows remain `root/` |
| **P0-08** Watcher-after-release — 0, 3, 4 | Old lifetime callback cannot mutate replacement root; last release unloads once | Core state tests + CoreMacOS adapter lifetime tests | App hydration diagnostics; move watcher rows |
| **P0-09** Dependency cycles — 0–4 | Reverse edge or forbidden import fails package/guardrail validation | Compiler + manifest/import guard | All builds; no XCTest row without behavior |
| **P0-10** C-symbol collision — 0, 1, 3 | All products link and symbol inspection finds one implementation per symbol | POSIX/syntax link tests + `nm` guard | App/MCP/headless builds; ledger only for behavioral tests |
| **P0-11** Headless privilege bleed — 0, 8 | Isolated process cannot see app state/secrets/roots/socket; denied tools return frozen error | Headless subprocess/security tests with isolated HOME | Packaged headless smoke; new `headless/` rows |
| **P0-12** Performance regression — 0, 4–8 | Comparable samples preserve reviewed activation/search/prompt/resource profile | Bounded deterministic invariants + runtime diagnostics | Evidence artifacts; diagnostics do not create ledger rows |
| Supporting: persistence compatibility — 0, 2, 5 | Legacy bytes decode identically; new bytes remain readable by rollback backend | Core fixture tests + root restart integration | Move rows with scenario totals |
| Supporting: stale persistence overwrite — 0, 5 | Newer selection revision survives stale payload races | Core disk-writer/controller gate | Root save integration; move rows |
| Supporting: prompt render/token drift — 0, 6 | Golden sections, codemap placement, and token totals match | Core prompt/accounting tests | Root clipboard/chat integration; move factual rows |
| Supporting: runtime/UI lifetime — 7 | Adapter loss preserves runtime identity; UI-only work fails explicitly | Root registry/weak-adapter integration | Proxy smoke; new root rows |
| Supporting: app-proxy regression — 7, 8 | Bundle paths, socket ownership, proxy mode, exit/retry semantics remain unchanged | Existing packaged shell smoke and MCP terminal tests | No shell-smoke ledger row |
| Supporting: headless wire/state security — 8 | Exact NDJSON; malformed input bounded; permissions and root escapes denied | Headless fixture/subprocess tests | Separate package/install smoke; new rows |

### Test and ledger protocol for every batch

1. Name the protected contract, plausible defect, lowest faithful layer, fixture, and exact oracle before adding or moving a test.
2. List old/current IDs authoritatively before edits; list every affected target afterward.
3. Update `Scripts/Fixtures/test-suite-contract-ledger.tsv` surgically in the same patch. Never regenerate it.
4. Record exact old → new IDs in `migration-ledger.tsv`; delete stale rows and preserve scenario counts for physical moves unless reviewed behavior changes.
5. Run exact ledger reconciliation across all seven prefixes.
6. Use structural guards only for dependency, ownership, symbol/link, and packaging constraints that executable behavior cannot cheaply enforce.
7. Keep performance/churn evidence diagnostic unless a stable deterministic threshold exists.
8. Use packaged/live smoke only for bundle/provenance/real transport journeys, never as the sole protection for deterministic Core logic.

## Validation ladder

Run the smallest coordinated lane first, then broaden only after the phase's focused gate passes:

1. Affected target test/filter and authoritative list.
2. Ledger verification.
3. Affected product builds.
4. Source/dependency/symbol/packaging guardrails.
5. Generated Xcode tests/validation when the graph changes.
6. `make dev-lint` for Swift changes.
7. Full affected/root/provider tests.
8. Package validation without launching the visible app.
9. Existing app-proxy live smoke only for proxy/runtime/package changes.
10. Separate standalone packaged smoke only in Phase 8.

Every execution record captures exact commands and results. The implementation pass must derive the final command names from the Phase 1 conductor/Make changes rather than inventing unsupported commands in advance.

## Critical file ownership map

| Area | Primary future changes |
| --- | --- |
| Package/control plane | `Package.swift`, `Scripts/source_layout_guardrails.sh`, `Scripts/generate_xcode_workspace.py`, `Scripts/conductor.py`, `Scripts/test_suite_optimizer.py`, Make/CI, `docs/testing.md`, architecture docs, curated ledger |
| C/platform | App bridging header; new POSIX/syntax/CoreMacOS roots; existing scanner support remains checksum-controlled |
| Neutral/Core engine | Workspace context models, path policy/projection, file-context store, catalog/search/selection/slice/codemap/token services moved per Phase 0 inventory |
| App authority adapters | `WorkspaceManagerViewModel`, `WorkspaceSelectionCoordinator`, app composition files identified in Phase 0 |
| Prompt/review | App-owned frozen review + authorization; Core-owned factual projection/accounting; app orchestration in prompt services/view model |
| MCP runtime | `MCPBindingResolver`, app runtime/adapter registries, current proxy entry preserved |
| Headless | New headless source/test roots and separate package/install/smoke scripts |
| Tests | Existing workspace/prompt/MCP suites split only by faithful layer; five dedicated test roots and seven-prefix ledger |

## Deferred Phase 9+

- Remove the legacy backend and construction switch.
- Remove compatibility typealiases/forwarders and obsolete app implementations.
- Make post-stabilization ownership guards permanent.
- Converge the standalone mutable runtime onto the shared Core session graph.
- Plan any further MCP provider/catalog/DTO/formatter/dispatch extraction separately.

## Open questions

None currently block execution. A newly discovered contract gap, dependency cycle, or headless ambiguity must become an ADR and may block the owning phase gate; it must not be resolved opportunistically.

## References

- `docs/investigations/core-isolation-reconstruction-2026-06-20.md`
- `docs/architecture/source-layout.md`
- `docs/architecture/xcode-workspace.md`
- `docs/testing.md`
- `docs/plans/test-coverage-value-audit-2026-05-29.md`
- `.agents/skills/rpce-test-quality/SKILL.md`
- `Package.swift`
