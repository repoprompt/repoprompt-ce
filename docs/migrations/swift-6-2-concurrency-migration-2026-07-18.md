# Swift 6.2 Concurrency Migration: Plan

## Goal

Living implementation evidence is recorded in [`swift-6-2-concurrency/migration-ledger.md`](swift-6-2-concurrency/migration-ledger.md).

Move RepoPrompt CE’s root and provider packages from Swift 5 language mode to Swift 6.2 concurrency safety through target-scoped, behavior-preserving phases. First isolate the deterministic CodeMap parsing/extraction pipeline into an internal headless target so it can be validated and migrated without pulling CAS, Git authority, workspace seeding, or app presentation across the boundary.

## Background

- Both manifests use Swift tools 6.2 but remain in Swift 5 language mode and enable no concurrency-specific settings (`Package.swift:1,81-89,112-169`; `Packages/RepoPromptAgentProviders/Package.swift:1-25`).
- The root target graph has three useful leaf boundaries—`RepoPromptWorkspaceCore`, `RepoPromptShared`, and the separate `RepoPromptClaudeCompatibleProvider` package—followed by `RepoPromptMCP`, the large `RepoPromptApp`, and the one-file `RepoPrompt` entry shell (`Package.swift:121-169`; `docs/architecture/source-layout.md:49-62`).
- The CodeMap parsing nucleus is path-free: source snapshots and artifact vocabulary feed `CodeMapSyntaxArtifactBuilder`, `SyntaxManager`/queries, and `CodeMapGenerator` plus its language helpers (`Sources/RepoPrompt/Features/CodeMap/CodeMapSyntaxArtifactBuilder.swift:1-30`; `Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift:20-71,813-909`; `Sources/RepoPrompt/Features/CodeMap/CodeMapGenerator.swift:294-429`).
- A whole-feature move would be too deep. `CodeMapExtractor` is SwiftUI/app presentation (`Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift:1-60`); artifact runtime composes concrete CAS, manifest, workspace-binding, and Git services (`Sources/RepoPrompt/Features/CodeMap/CodeMapArtifactRuntime.swift:9-75,100-132`); diff-seeded workspace startup is a separate authority (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:3272-3285,3800-3806`).
- The extraction must preserve the content-addressed CodeMap and diff-seeded startup contracts established by merge `957eb582` and subsequent bounded-reconciliation, ordering, retry, and atomic-publication work. It must not restore retired eager/native-tree paths (`docs/architecture/source-layout.md:65-81,161-178`).
- Migration work must protect cancellation, lifetime, ordering, exactly-once continuation completion, actor reentrancy, lock-backed sendability, C/Objective-C crossings, and bounded indexing/persistence work. Representative seams are documented in `.agents/skills/rpce-swift-6-concurrency-migration/references/repository-concurrency-profile.md:31-57`.
- User decisions for this plan: extract CodeMap first; prioritize parsing/extraction, expanding toward domain core only where CAS/filesystem and Git-diff seeding remain outside through one-way adapters; adopt Swift 6.2 execution/isolation features per target; keep a committed living inventory and escape-hatch ledger while raw logs remain in conductor storage.
- Primary SwiftPM documentation exposes target-level `.swiftLanguageMode(.v6)` in PackageDescription 6.0+, while the newly added local migration guidance currently describes the final mode switch as package-wide. Work Item 1 resolves the discrepancy against the active compiler; the execution path branches explicitly if mixed target modes are unavailable.

## Approach

Use a **compatibility-preserving target extraction followed by target-ordered migration**. Architectural movement and concurrency remediation are separate gates: first make CodeMap independently buildable without changing output or runtime ownership, then stage diagnostics and language semantics one target at a time.

### CodeMap boundary

Create an internal, non-product target, `RepoPromptCodeMapCore`, under `Sources/RepoPromptCodeMapCore`. It owns only the deterministic, synchronous parsing/extraction nucleus:

- path-free source/decode result and artifact/outcome vocabulary;
- pipeline identity, grammar/query registry, parse limits, and CodeMap-specific Tree-sitter execution;
- `CodeMapSyntaxArtifactBuilder`, `CodeMapGenerator`, capture indexing, extraction memoization, signature/type helpers, and language strategies;
- canonical artifact rendering that must remain byte-for-byte compatible.

The current source model must split at provenance: raw digest/decode values can cross the module, while validated worktree/Git provenance remains in `RepoPromptApp` (`CodeMapSourceSnapshot.swift:4-66,80-145`). App adapters continue to own the shared `workspaceAutomaticV1` decoder, source validation, build permits, cancellation checks, and token accounting; the core receives immutable decoded input and returns deterministic output. Likewise, per-call performance values may cross the boundary, but environment flags and aggregation remain app-owned (`CodeMapPerfStats.swift:460-549`).

Create one supporting internal target, `RepoPromptRegexCore`, because CodeMap extraction directly uses `CodeMapPCRE2Pattern`, which currently depends on the app target’s shared PCRE2 implementation and runtime policy (`CodeMapPCRE2Regex.swift:41-66`; `Infrastructure/Regex/PCRE2RegexAdapter.swift:3-20`; `ThirdParty/SwiftPCRE2/PCRE2Regex.swift:1`). Move the reusable SwiftPCRE2 wrapper and the existing `REPOPROMPT_PCRE2_JIT` resolver into that target so app search and CodeMap share one construction authority; search-specific repair, error, and match-limit policy stays in `RepoPromptApp`. Both `RepoPromptApp` and `RepoPromptCodeMapCore` depend on `RepoPromptRegexCore`. Do not duplicate the wrapper or turn this into a general regex redesign.

Keep these areas outside `RepoPromptCodeMapCore`:

- `CodeMapExtractor` and all file-tree/path/import presentation;
- `CodeMapArtifactRuntime`, coordinator scheduling, CAS/container/catalog/locator/manifest stores, handles, and leases;
- workspace binding, `GitService`, repository authority, filesystem roots, watcher replay, and diff-seeded startup;
- MCP/UI integration, token-counting actors, environment-driven diagnostics, and app lifecycle.

`CodeMapArtifactBuilderClient` remains app-owned as the `@unchecked Sendable` closure adapter around a typed, synchronous core API; its synchronization invariant is recorded in the ledger and removal of the escape hatch is evaluated during strict checking (`CodeMapArtifactBuildCoordinator.swift:326-359`). It retains build permits and cancellation checks around the core call. The extraction phase stops here. Moving persistence or workspace integration later requires a separate proposal proving that concrete CAS/filesystem scheduling, Git authority, and seeded-inventory types remain outside through one-way adapters.

### Compatibility and evidence gates

No persistence migration or intended user-visible change is part of this campaign. Every extraction and concurrency tranche must preserve:

- canonical artifact bytes, pipeline/version/query identity, `Codable` discriminators, negative outcomes, ordering, and existing golden output;
- CAS readability, coalesced flights, bounded admission/reconciliation, retry liveness, cancellation, and exactly-once completion;
- workspace/Git authority, atomic diff-seeded publication, projection freshness, and established app/MCP protocol behavior.

Implementation creates one committed living record at `docs/migrations/swift-6-2-concurrency/migration-ledger.md`. It contains the target/settings inventory, diagnostic families and counts, escape-hatch table, phase decisions, blockers, and conductor evidence. Raw logs remain in conductor storage. Each source/settings batch updates its affected rows and adds a concise phase-exit entry; escape hatches are marked removed or superseded rather than erased.

### Migration policy

Use actual compiler output and official SwiftPM APIs as authority. Target-local complete checking in Swift 5 mode, target-local Swift 6 language mode, default actor isolation, caller-actor execution, isolated-conformance inference, and explicit `@concurrent` are separate decision gates. A diagnostics-clean target may advance through multiple gates in one change only when the evidence and rollback point for each setting remain explicit; targets with repairs use one coherent diagnostic family per batch.

The dependency order is:

1. `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptWorkspaceCore`, `RepoPromptShared`, and the provider package;
2. `RepoPromptMCP`;
3. `RepoPromptApp` infrastructure and task-heavy feature runtimes;
4. `RepoPromptApp` UI/composition, root tests, and the thin `RepoPrompt` executable;
5. target-local Swift 6 language-mode adoption in the same leaf-to-root order;
6. per-target Swift 6.2 execution/isolation decisions.

The mixed `RepoPromptApp` target should continue to use explicit `@MainActor` declarations; target-wide default MainActor isolation is appropriate only for a target proven to be wholly UI/entry owned. No phase may launch or relaunch the visible app without separate approval.

## Work Items

### 1. Correct the migration authority and establish the baseline

- **Outcome:** Reconcile the local skill’s package-wide-only claim with SwiftPM’s target-level `.swiftLanguageMode` API. Prove the exact behavior with the active toolchain using a disposable two-target fixture or equivalent compiler-invocation evidence, then update the skill references before any production settings change.
- **Record:** Xcode/Swift/SDK versions, manifest revisions, actual target graph, current settings, baseline tickets/logs, pre-existing failures, and reversible complete-checking diagnostic counts by target. Remove the stale `RepoPromptMCPServerCore` target assumption unless it is added to a manifest. The count probe sizes later batches but does not change the user-selected CodeMap-first prerequisite.
- **Exit gate:** The accepted manifest syntax is compiler-verified; mixed target modes are either confirmed or rejected with evidence; the migration ledger exists; baseline failures are classified.
- **Validation:** `make doctor`; `make dev-swift-build PRODUCT=RepoPrompt`; `make dev-swift-build PRODUCT=repoprompt-mcp`; `make dev-test`; `make dev-provider-test`; skill quick validation; `make guardrails`.

### 2. Close the CodeMap dependency boundary

- **Outcome:** Produce a source-move manifest for `RepoPromptCodeMapCore` and `RepoPromptRegexCore`, then close only the dependencies that would otherwise create target cycles.
- **Required seams:** Split core source/decode values from app-owned provenance; separate CodeMap parsing/query execution from app highlighting; separate canonical artifact rendering from app token accounting; keep shared decoding and performance aggregation app-owned; keep `CodeMapArtifactBuilderClient` app-side around a typed core API; move the single PCRE2 wrapper and JIT resolver into `RepoPromptRegexCore`.
- **Test ownership:** `RepoPromptCodeMapCoreTests` becomes the sole resource owner for CodeMap parsing fixtures/goldens and the pure golden runner. Surviving app integration tests use programmatic inputs or move the relevant assertion to the core test target; do not add a resource-sharing support target.
- **Stop conditions:** Any proposed core source imports SwiftUI/AppKit, concrete filesystem/CAS/Git/workspace/MCP types, app identity, or a mutable parser cache without a proved synchronization owner.
- **Validation:** Identify the decoder, regex, syntax, generator, and golden suites through `make dev-test-list`; record the same-host corpus protocol and baseline; set the extraction acceptance band at this item’s exit before files move; run `make dev-swift-build PRODUCT=RepoPrompt`.

### 3. Extract and validate the headless CodeMap target

- **Outcome:** Add the two internal targets and `RepoPromptCodeMapCoreTests`; move the parsing/extraction nucleus, pure golden runner, and its fixtures/resources. Make `RepoPromptApp` depend on both cores and `RepoPromptCodeMapCore` depend on `RepoPromptRegexCore`. Update `Package.swift` and `docs/architecture/source-layout.md`.
- **Integration:** `RepoPromptApp` constructs validated, decoded core input and invokes the synchronous builder through its existing client; the app retains provenance, permits, cancellation, persistence, workspace binding, presentation, and app integration tests.
- **Exit gate:** No parallel decoder/query/regex authority; artifacts, negative outcomes, goldens, ordering, coalescing/cancellation, and existing CAS reads are unchanged; corpus timing remains inside the Work Item 2 acceptance band or the regression is resolved before merge.
- **Validation:** New core tests; affected existing `CodeMapGoldenTests`, artifact builder/coordinator/container/store tests, and workspace binding tests; `make dev-swift-build PRODUCT=RepoPrompt`; phase-boundary `make dev-test` and `make guardrails`.

### 4. Enable complete checking for leaf, core, shared, and provider targets

- **Outcome:** While retaining Swift 5 language mode, enable complete strict-concurrency checking independently for `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptWorkspaceCore`, `RepoPromptShared`, their tests, and `RepoPromptClaudeCompatibleProvider`.
- **Method:** Batch by one target and one diagnostic family. Use `$rpce-swift-concurrency-fix` for bounded repairs; preserve synchronous CodeMap extraction, lock-backed PCRE2/cache invariants, deterministic value semantics, and provider callback ownership.
- **Exit gate:** Zero in-scope diagnostics for each advanced target; focused tests pass; imported dependency limitations are separated from first-party defects; all escape hatches have owners and audit/removal conditions.
- **Validation:** Owner-focused core/workspace tests, both product builds when shared APIs move, and `make dev-provider-test FILTER=<AffectedSuite>` plus the provider phase gate.

### 5. Migrate the MCP executable boundary under complete checking

- **Outcome:** Enable complete checking for `RepoPromptMCP` and affected root tests while it remains in Swift 5 mode.
- **Invariants:** Long-lived task ownership, cancellation, exactly-once continuation completion, bounded progress/backpressure, transport ordering, routing authority, process lifetime, and shutdown remain observable and deterministic.
- **Exit gate:** No leaked tasks, lost cancellation, reordered progress, unbounded buffering, or undocumented unsafe sendability.
- **Validation:** `make dev-swift-build PRODUCT=repoprompt-mcp`; focused `AgentRunSessionStore`, wait/drain, bootstrap/socket, parser/process, and transport suites. Use only non-disruptive `make dev-smoke` against an already-running approved app when runtime behavior changed.

### 6. Remediate `RepoPromptApp` infrastructure and feature runtimes

- **Outcome:** Resolve diagnostics in coherent, separately reviewable tranches while `RepoPromptApp` stays in Swift 5 mode: concurrency primitives; filesystem/process/networking; persistence/CAS; workspace/indexing; MCP infrastructure; Agent Mode; then remaining feature runtimes.
- **Invariants:** Actor reentrancy is reviewed at every suspension; blocking I/O stays off Swift executors; immutable snapshots cross to MainActor; continuation/cancellation paths complete exactly once; CAS, Git fencing, seeded replay, bounded work, retry liveness, and projection freshness retain one authority.
- **Exit gate:** Remaining app diagnostics are limited to inventoried UI/composition/test boundaries. Unknown ownership blocks the tranche rather than being hidden with annotations or a new actor.
- **Validation:** `make dev-swift-build PRODUCT=RepoPrompt` and the smallest owning suite after each batch, including CodeMap store/coordinator, `WorkspaceFileContextStoreTests`, search/indexing, process, MCP, and Agent Mode lifecycle suites where affected.

### 7. Finish complete checking for UI, composition, tests, and entry shell

- **Outcome:** Repair SwiftUI/AppKit/Objective-C callback, notification, view-model publication, test, and `@main` diagnostics; then enable complete checking for `RepoPromptApp`, `RepoPromptTests`, and the thin `RepoPrompt` target.
- **Policy:** Prefer static `@MainActor` contracts over `MainActor.assumeIsolated`; preserve app state and delegate behavior; keep `Sources/RepoPromptExecutable` a one-file delegation shell.
- **Exit gate:** Every root Swift target is clean under complete checking in Swift 5 mode; public/package API and sendability changes are reviewed.
- **Validation:** Focused actor-publication, delegate, notification, and app tests; both product builds; `make dev-test`; `make dev-provider-test`; `make dev-lint`; `make guardrails`.

### 8. Adopt Swift 6 language mode at the verified boundary

- **Outcome:** Apply Swift 6 language mode without bundling any Swift 6.2 execution/isolation feature. Migrate owner tests with their production target.
- **Preferred order if mixed modes are supported:** `RepoPromptRegexCore` → `RepoPromptCodeMapCore` → `RepoPromptWorkspaceCore` → `RepoPromptShared` → provider product/tests → `RepoPromptMCP` → `RepoPromptApp`/root tests → `RepoPrompt`.
- **Fallback if Work Item 1 rejects mixed target modes:** Keep target-level complete checking as the staging mechanism, then flip each package only after all of its targets pass the package gate; migrate the provider package independently from the root.
- **Exit gate:** No unresolved Swift 6 diagnostic or behavior failure. Redundant Swift-5 checking flags are removed only at the boundary that advanced; package defaults move to v6 only after the package acceptance gate.
- **Validation:** Smallest owner build/test per target or package, both products for shared boundaries, then full root/provider suites and guardrails at each package gate.

### 9. Evaluate Swift 6.2 execution and isolation features per target

- **Outcome:** After Swift 6 mode is stable, evaluate four independent settings/contracts per target: SE-0466 default actor isolation; `NonisolatedNonsendingByDefault`; explicit or inferred isolated conformances; and `@concurrent`. Adoption is evidence-led, and explicit non-adoption is a valid result.
- **Order within each target:** Decide default isolation first; enable caller-actor semantics and audit nonisolated async work; review isolated conformances; then profile whether any work needs explicit `@concurrent`. Keep headless/core/shared/provider/MCP targets non-default-isolated unless evidence proves otherwise; keep mixed `RepoPromptApp` explicit.
- **Exit gate:** No inferred isolation changes an external conformance or forces background infrastructure onto MainActor; no blocking/CPU work is stranded on a caller actor; every isolated conformance is usable from its required domains; every `@concurrent` addition has safe crossings, cancellation ownership, and profiling evidence. Zero feature adoptions or zero `@concurrent` additions is acceptable.
- **Validation and closure:** Use the smallest affected async, cancellation, conformance, delegate, serialization, and performance suites plus the owning product build for each adopted setting. Finish with `make dev-format`, `make dev-lint`, both product builds, `make dev-test`, `make dev-provider-test`, `make guardrails`, and `make dev-build`. Close every ledger row as fixed, explicitly deferred with an owner, or blocked with evidence; do not launch the visible app.

## Maintainer-Guidance Check

- **User impact and invariant:** No intended behavior change; CodeMap output and concurrency behavior remain deterministic, bounded, cancellable, and compatible.
- **Root-cause confidence:** Target and architecture seams are confirmed; diagnostic counts remain unknown until Work Item 1.
- **Authorities:** Manifests and compiler output; the CodeMap pipeline/artifact identity; app-owned CAS/coordinator; `WorkspaceFileContextStore`; official Swift evolution and SwiftPM documentation.
- **State/scale risks:** Artifact drift, duplicate authorities, cancellation or ordering regressions, actor reentrancy, stale workspace projection, Tree-sitter/PCRE2 synchronization, unbounded work, and caller-actor latency.
- **Recommended scope:** Extract parsing/extraction and its minimal regex dependency now; defer broader CodeMap domain-core extraction.
- **Validation boundary:** Focused owner tests first, conductor product/package gates at phase boundaries, no visible app launch.

## Open Questions

- **Toolchain gate (Work Item 1):** Does the active SwiftPM/compiler accept mixed target-level Swift language modes in these packages? If yes, Work Item 8 advances leaf-to-root; if no, complete checking remains target-local and each package flips only at its acceptance gate. This requires evidence, not another user decision.

The CodeMap scope is settled: stop at parsing/extraction unless a later proposal proves a broader layer can move without importing app UI, concrete workspace/Git authority, diff-seeded inventory, or shared filesystem scheduling.

## References

- `.agents/skills/rpce-swift-6-concurrency-migration/SKILL.md`
- `.agents/skills/rpce-swift-6-concurrency-migration/references/{migration-inventory,validation-matrix,official-swift-6-2}.md`
- `docs/architecture/source-layout.md`
- `docs/architecture/provider-plugins.md`
- [SwiftPM target-level Swift language mode](https://docs.swift.org/swiftpm/documentation/packagedescription/swiftsetting/swiftlanguagemode(_:_:))
- [SE-0461: caller-actor execution for nonisolated async functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0466: control default actor isolation inference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [SE-0470: global-actor isolated conformances](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes?changes=latest_minor)
