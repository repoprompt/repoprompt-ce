# Build Modularization Ledger

Living record for [`../build-modularization-2026-09-28.md`](../build-modularization-2026-09-28.md). Each slice adds its manifest, evidence, timings, and ratchet deltas. Entries are marked superseded rather than erased.

## Tooling

| Tool | Purpose | Plan item |
| --- | --- | --- |
| `Scripts/modularization_metrics.py report [--details]` | Architecture metrics: app size and share, god files, singletons, triage dependency graph (wrong-way edges, largest cycle), test coupling. Build-free regex graph; feeds the ratchets | P0.2 prototype, P0.7 |
| `Scripts/modularization_index_graph.py report\|readiness\|compare\|edge\|dump` | Compiler-grade `RepoPromptApp` file graph from the debug build's index store: wrong-way edges, SCCs, extraction readiness for a candidate file set, regex comparison, the symbols behind one edge. Needs a current debug build | P0.2 |
| `Scripts/modularization_metrics.py check` / `update` | Ratchet gate (run by `make guardrails`) and baseline refresh | P0.7 |
| `./conductor job status --json` → `phaseTimings` | Structured per-job phase marks and segments; also persisted as `<ticket>.timing.json` next to the job log | P0.1 |
| `Scripts/conductor_job_timings.py` | Queue-wait, net job-duration, and per-phase percentiles; prefers `<ticket>.timing.json`, falls back to log parsing | P0.1 |
| `./conductor swift-build --product P` / `./conductor test` with `--scratch <label> [--swiftc-flag=F]... [--linker-flag=F]...` | Measurement builds with extra compiler or linker flags in `.build/measure/<label>`: never the shared `.build`, never build-cache eligible, excluded from seeds. Flags are refused without `--scratch`; `test` accepts it only on the aggregate path | P0.5 |
| `phaseTimings.peakRss` (job status and `<ticket>.timing.json`) | Optional per-job peak process-tree RSS, sampled once per second for heavy-slot jobs | P0.5 |

Self-tests: `make conductor-selftest` (includes `test_modularization_metrics.py`, `test_modularization_index_graph.py`, `test_conductor_job_timings.py`, and `test_conductor_job_phases.py`).

## T0 — move-audit tooling (2026-09-29)

Added a fail-closed Git move audit (manifest, normalized SHA-256, similarity, import/access-only and discovery checks), dry-run diagnostics-driven `package` access lift, dry-run test-import retarget helper, and `make new-module` checklist. The helpers make no Swift changes in this slice. T0's Python regressions use temporary Git repositories and run in `make conductor-selftest`. The audit's first-party import allowlist is derived from first-party source/test targets and `Package.swift` at the compared revisions; unchanged external imports remain valid.

## T1–T5 — PR 2 tooling half (2026-09-30)

Checkpoint `f80ae16a` adds the append-friendly first-party target catalog (`Scripts/modularization/modules.json`) and allowed-edge/import/placement guardrails. The T1 gates are `tests_testable_import_app_files` and `app_files_over_2000_lines` (non-increasing), plus `app_target_swift_lines` with fixed 2,000-line headroom. CI's root test build uses SwiftPM's `--explicit-target-dependency-import-check error`.

T2 routes `make dev-test MODULE=<TestTarget>` through conductor's app-free module executor. Exact, unambiguous `FILTER=<Suite>` values resolve to an owning app-free target; ambiguous/regex filters retain the aggregate path or require an explicit module. `modularization_metrics.py edit-locality` measures trailing 60-day Swift touches on `origin/main` by current module ownership. T3 compares source SHA-256 values against the conductor build attestation; missing or changed fingerprints fail the index gate instead of trusting mtimes.

T4 changes machine-wide heavy admission to FIFO weighted reservations. Per-class observed `peakRss` samples set a nearest-rank p90 reservation with headroom; unknown app/aggregate work reserves conservatively, and legacy queue records are exclusive. T5 has one CI root test-bundle build and artifact handoff to four no-build shards, affected app-free module-test jobs, main-only Sentry validation, and build-produced index/type-check ratchets. The CI artifact carries source/test hash attestations and refuses missing or changed inputs. Hosted CI and runtime speedups are **not established** by local source inspection or selftests; record those separately when a PR run exists.

Local tooling-half validation on 2026-09-30: `make conductor-selftest` passed; `make guardrails` passed after rerunning outside the restricted SwiftPM sandbox; `make xcode-validate` passed after the same sandbox accommodation. `make dev-test MODULE=RepoPromptRegexCoreTests` completed with 7 tests and 0 failures (conductor ticket `84bbe116-8b0c-4da9-b389-70de298a2de8`, exit 0; 3m 59s global-heavy wait, 2m 10s execution). The initial sandbox-denied guardrails and Xcode attempts were not source failures.

## Ratchet policy

- **Gated by build-free guardrails:** `app_files_over_5000_lines`, `app_files_over_2000_lines`, `app_static_shared_declarations`, and `tests_testable_import_app_files` are non-increasing. Missing or invalid baseline configuration remains a failure.
- **Gated by the build-producing CI job:** index wrong-way edges and largest cycle; type-check body and expression budgets. Index freshness must be proven by source hashes before comparing counts.
- **Tracked, not gated:** `app_target_swift_lines` (visible advisory above baseline plus the unchanged 2,000-line headroom), `app_shared_accessor_uses`, `app_userdefaults_standard_uses`, lexical `app_wrong_way_file_edges`, lexical `app_largest_cycle_components`, and `tests_sleep_calls`. The lexical graph can add false edges from identifier collisions; the sleep regex also counts fake-clock declarations.
- Lower a baseline with `update` in the slice that improves it. Raising one requires `update --allow-regression` plus a justification entry here.

**2026-10-11 #1286 overseer-scope test-import alignment.** The maintainer explicitly authorizes only `tests_testable_import_app_files` 331 → 332 for `Tests/RepoPromptTests/MCP/SessionAdminScopeLifecycleTests.swift`, the one App-importing test file the delegation-scope stack (#1286, with #1288/#1290 adding none) introduces. It necessarily imports App: it exercises `BatchConfirmationCoordinator`, `DelegationScopeRuntime` and `AgentSessionAdministrationCore`, which live in the App target, and it carries the regression witnesses for batch-card tab/session binding, supplied-confirmation validation below the threshold, and applying-card retention. When #1286 was first published `main` had slack; merging `main` at `b279947533a8bae418582c9a800e5f3e1a890459` (four new App-importing test files, baseline still 331) brought the merged tree to 332. No consolidation into unrelated suites, suppression or SPI exposure. `update --allow-regression` was run and its output narrowed to this single metric: the description, app-line baseline and headroom, every tracked metric and every other gated baseline are unchanged. Counts above 332 still fail.

**2026-10-03 PR 4 maintainer policy decision.** The user explicitly makes the App-line reference advisory, superseding the earlier hard-ceiling and proposed +177 allowance decisions. No numeric baseline is raised: `app_target_swift_lines` remains 649,794, headroom 2,000, advisory reference 651,794. Pinned main `a877f1ea` has 651,988 App lines (+194); the pending PR 4 merge has 651,971 (+177), a PR 4 contribution of −17. Excess remains visible even when another mandatory ratchet fails. All four non-increasing metrics, dependency/security/test gates and baseline/configuration failures remain mandatory; `update` still refuses unapproved baseline increases. The earlier actual guardrail exit1 is retained as historical failure, not retrospectively passed. Policy regression checks and final commit/push preflights must execute before publication; optional current-main full-suite/package/live checks remain pending, including incomplete ticket `51d89061-0945-4554-b73b-12d601485397` (zero executed tests).

**2026-10-03 PR 4/#1148 test-import alignment.** The maintainer explicitly authorizes only `tests_testable_import_app_files` 332 → 333 for the already-merged #1148 coverage at `274fd59d12585e26d53a8457dbd5c5b5014b7441`. Its new `MCPStateSubscriptionTests.swift` necessarily imports App: all six unchanged tests exercise real `MCPService` subscriber fan-out, seed/unsubscribe/approval state and `MCPServerViewModel` lifetime/window presentation with App dependencies and DEBUG hooks. Preserve the complete upstream file and assertions; no consolidation, deletion, Shared substitute, public/SPI exposure or suppression. CI run `37109785395`, job `111165298080`, checked synthetic merge `10d61881d4feb4b8300b4001c2cfd4878d343f4d` and failed the genuine 333 > 332 ratchet before compilation; that failure remains historical, not passed. This is a one-file structural-baseline alignment, not a relaxed check: counts above 333 still fail. App baseline 649,794/headroom 2,000/advisory reference 651,794, every other baseline/list and all dependency/security/test/configuration gates remain unchanged. Exact merged-head guardrails, eight focused methods, style and later commit/push preflights remain pending validator execution.

**2026-10-01 PR 2/main reconciliation.** Merging current `origin/main` (#1134–#1136) into PR 2 put the app target at 649,172 Swift lines, 242 above the earlier 648,930 ceiling. Regenerated `ratchets.json` with `update --allow-regression` against the merged tree: the recorded app-line baseline is now 649,172 with the same fixed 2,000-line headroom. The non-increasing gate counts remain unchanged; tracked-only counts reflect the merged source. This is a baseline reconciliation for existing feature work and PR 2, not a change to the guardrail policy.

**2026-10-01 PR 2/#1137 reconciliation.** Merging `origin/main` at `773a0f2e` added three tests with an exact `@testable import RepoPromptApp` line. The new Devin catalog, Context Builder prompt, and MCP policy tests exercise app-owned types; the fourth new Devin test uses an SPI-prefixed import and is not counted by this lexical metric. Regenerated `ratchets.json` with `update --allow-regression` against the merged tree: the test-import baseline is 332 rather than 329. The app-line baseline and tracked metrics were also refreshed for the new Devin catalog. This reconciles upstream app-level test coverage without weakening the non-increasing rule for later changes.

**2026-10-01 #1143 reconciliation.** Merging `origin/main` at `7d9cecd2` into the #1128 new-window chooser fix adds one test file with an exact `@testable import RepoPromptApp` line: `NewWindowInitialSelectionTests`. It is a composition suite. It drives `WindowState`, `DomainWorkspacePresentationBridge`, `ContentViewModel`, and `WorkspaceManagerViewModel` together against a real `MCPDomainRuntime`, so it cannot move to a module test target. The PR's projection-observer test support was folded into the existing `WorkspaceAuthorityRootTestFixture.swift` rather than adding a second file. Regenerated `ratchets.json` with `update --allow-regression` against the merged tree: the test-import baseline is 333 rather than 332. The app-line baseline was refreshed to include the fix's source (+628 lines). The non-increasing rule for later changes is unchanged.

**2026-10-08 #1143 simplification follow-up.** Applied the four static-equivalence cuts from the review of `493d6205`: remove unused route/startup test surface, consolidate the identical pending/dispatch restore payload, and remove one-shot startup replacement checks. App source falls from 650,635 to 650,611 Swift lines (24 fewer); execution/protection separation, route scheduling, startup joins, and cancellation checks remain unchanged. Regenerated measurements show 650,611 app lines and 749,091 first-party lines. The recorded baseline of 650,498 predates the 137-line restore-lifetime addition at the reviewed head; it remains unchanged because the measured total is within the existing 2,000-line allowance and this deletion-only follow-up should not raise the baseline. Non-increasing gate counts are unchanged. The projection generation counter is intentionally retained pending separate zero-sequence, same-sequence, and stop/restart equivalence validation.

## Baseline — 2026-09-28 (`589cecc5`)

Metrics: [`ratchets.json`](ratchets.json). App target: 1,160 files, 648,091 lines, 88.3% of first-party Swift; 17 files over 5k lines; 102 singleton declarations and 1,220 `.shared` uses; 1,102 wrong-way edges; largest cycle 67 of 75 components.

Conductor timings (last 3,000 jobs, net of queue):

| Category | n | p50 | p90 |
| --- | --- | --- | --- |
| Heavy-slot wait | 1,383 | < 1 s | 8.8 min |
| Focused test, nothing compiled | 131 | 2.2 min | 10.1 min |
| Focused test, tests recompiled | 44 | 3.0 min | 9.0 min |
| Focused test, app recompiled | 46 | 4.7 min | 11.1 min |
| Package, app recompiled | 19 | 13.2 min | 60.1 min |

**Correction:** the first draft of the plan reported a heavy-slot wait of p50 12.3 min, because an ad-hoc parser read `739ms` as minutes. The tested parser shows that 75% of jobs are admitted immediately, 295 waited at least a minute, and 22 waited over an hour. The plan text has been corrected.

**Historical sample qualification:** these percentiles are from the earlier prefix-limited log classifier, which could omit verbose test jobs whose XCTest footer followed 400,000 characters. They describe a potentially censored subset, not a complete test-job population. The current summarizer streams full logs and reports unclassified, missing-duration, and known-failed counts; the original historical corpus has not been independently reconstructed here.

## Ratchet re-baseline — 2026-09-29 (rebase onto `5d5a99de`)

`update --allow-regression`, because main moved between the baseline and this branch landing. No change on this branch worsens a gated metric.
- **Gated:** `tests_sleep_calls` 47 → 49. Both come from main: #1067 added a fake clock whose `func sleep(_:)` declaration the regex counts (`ContextBuilderGroupedSupervisionTests`), and #1092 added a 2 ms `Task.sleep` poll (`AgentAdmissionRecoveryTests`).
- **Tracked (refreshed, not gated):** app files 1,160 → 1,161, app lines 648,091 → 651,485, files over 2,000 lines 50 → 51, `.shared` uses 1,220 → 1,222, wrong-way edges 1,102 → 1,104, `@testable import RepoPromptApp` test files 319 → 324. Of these, this branch adds 2 app lines (the P0.6 access change) and 1 `@testable` file (the P0.6 goldens); the rest is main (`origin/main` alone measures 651,483 lines and 323 files).

## Ratchet exception — advertised model admission (2026-09-30)

`app_static_shared_declarations`: **102 → 103**, solely for
`AgentAdvertisedModelCatalog.shared`. Generated with
`python3 Scripts/modularization_metrics.py update --allow-regression --baseline /tmp/overseer-model-selection-ratchets.generated.json`;
only this justified metric is adopted in `ratchets.json`. Other baselines stay unchanged;
`app_files_over_5000_lines` remains 17. This is an explicit one-owner exception, not a
relaxation of the gate or a rename to evade its `shared` count.

The new owner is the process-memory index of exact advertised compound model IDs and their
precomputed effort decomposition, shared by `set_model` and explicit `create_lane(model_id:)`.
Ordinary catalogue producers populate it; ACP/Codex/backend configuration changes invalidate it.
Admission only performs bounded memory lookups and refuses a cold index actionably. It never
warms persistence, scans the full catalogue, discovers models, or calls a provider. Keeping this
projection separate prevents the legacy discovery/resolution paths (including Codex effort parsing
that can consult persistence) from leaking into the configuration-only transaction.

Alternatives inspected: `AgentACPModelRegistry` owns ACP provider snapshots and store warming;
`AgentCodexModelRegistry` owns Codex snapshots. Neither is a coherent owner for Claude, ACP,
Codex, and other advertised targets together. `AgentModelCatalog` is a stateless catalogue facade;
adding a differently named static cache there would preserve the new global lifetime while merely
hiding it from the ratchet. Reworking all catalogue lifetimes/injection is outside this bounded
feature and would add risk without strengthening its no-I/O contract. The index has no authority,
provider lifecycle, or persistence ownership; independently constructed instances support admission
tests. Future catalogue-service extraction should absorb this projection and remove this singleton,
not duplicate it in individual registries. No other new global owner is authorized by this exception.

## Ratchet exception — background Oracle invocations (2026-11-06)

This is an explicit one-owner exception for `OracleBackgroundInvocationRegistry.shared`.
After the M6 module extraction, `python3 Scripts/modularization_metrics.py check` measures
**88** `app_static_shared_declarations`, within main's existing ceiling of **89**.
The existing `ratchets.json` baseline is retained.

The owner is the process-memory index of background Oracle invocations used by
`ask_oracle`/`oracle_chat_log`, provider awareness, and session deletion, independent of
window and run lifetimes. No existing initializer or hook supplies the registry to
deletion after writer and attachment drains but before file removal, and after the
commit reporter returns. App-owned runtime/store ownership and canonical durable result
authority remain unchanged. This owner only tracks process-local workers, awareness,
and drain completion. The exception authorizes no other global owner.

## Catalog runtime consolidation (2026-10-29)

`AgentModelCatalogRuntime` replaces the independent advertised, ACP and Codex registry singletons with one application-owned runtime. It owns the existing memory-only admission index and lazily retains the same ACP and Codex registry implementations; provider locks, caches, persistence, warm/reset fences, and invalidation order remain unchanged. Registry-only access does not install the compatible-backend handler. The first advertised operation installs it before proceeding, without holding a runtime slot or activation lock across the registrar. Admission remains exact-ID and memory-only; producers capture generations before reading source snapshots. The existing ACP warm-to-advertised and backend-store-to-invalidation lock order is preserved, and the runtime does not acquire a registry while holding its index lock. The previous exception above is historical: the measured `app_static_shared_declarations` ratchet decreases from 89 to 87. Polling-service lifetimes and app-owned configuration/persistence are not retired by this change.

## Decisions

| ID | Decision | Status |
| --- | --- | --- |
| ADR-01 | Root-package targets first; separate packages only past the §3.4 gate | Accepted (plan) |
| ADR-02 | Capability graph and allowed edges (plan §3.2) | Accepted (2026-09-29) as written. Evidence: P0.2 index graph (1,360 wrong-way file edges, largest cycle 66 of 75 components, seam catalog and Appendix B validated) |
| ADR-03 | Contract policy (plan §3.5, principle 7) | Accepted (2026-09-29) as written. Evidence: P0.2 index `edge`/seam data, where fan-in alone overstated coupling (S8 fan-in 109 → 33 by index) |
| ADR-04 | Composition root and injection (plan §3.1 principles 3–4) | Accepted (2026-09-29) as written. Evidence: P0.2 index graph, where ambient `.shared` authorities carry the cross-layer edges (S1, S2, S6, S7: 116–129 refs each) |
| ADR-05 | Logic/UI split (plan §3.1 principle 6) | Accepted (2026-09-29) as written. Evidence: P0.5 type-check data (SwiftUI is 58 of 104 function bodies ≥ 200 ms and 74% of their time) |
| ADR-06 | Test ownership and hermeticity (plan §3.6) | Accepted (2026-09-29) as written. Evidence: P0.3 bake-off (module-owned test targets cut median edit→test by 77% and 95%; an app interface change recompiles 360 app test files) |
| ADR-07 | Focused-test executor | Accepted (2026-09-28): Swift Build per-target bundles (`conductor test --module`) for test targets whose closure excludes `RepoPromptApp`, including Swift Testing; native aggregate stays the default `FILTER` path, the path for app-dependent targets, and the CI path. Passed the gate on both P0.3 slices (77% and 95% lower median edit→test, no discovery loss) |
| ADR-08 | Admission and caching (plan §5.4–5.5) | Admission v2 accepted in T4: FIFO weighted reservations use measured per-class peak RSS with conservative app/aggregate fallback and legacy exclusivity. Cross-worktree caching remains conditional T6 and requires clean-vs-cached correctness evidence |
| ADR-09 | Per-module concurrency (plan §3.7) | Accepted (2026-09-29) as written. Evidence: the existing [Swift 6.2 concurrency migration ledger](../swift-6-2-concurrency/migration-ledger.md), which each extraction extends |

## Phase 0 progress

- [x] P0.1 timing: retroactive baseline, structured conductor phase timing, and attribution of the two open overheads (see P0.1 below)
- [x] P0.2 graph tool: regex prototype, then the index-store tool, validated against the top 40 and the seam catalog (see P0.2 below)
- [x] P0.3 focused-test executor bake-off — gate holds on both slices (`RepoPromptMCPCoreTests` 77%, `RepoPromptDomainRuntimeTests` 95%); ADR-07 accepted. Not measured, not blockers: candidates (c) and (d), CI parity of module runs (CI stays on the aggregate)
- [x] P0.4 fixed per-job overhead root cause and fix (see below)
- [x] P0.5 link and type-check levers: type-check baselines, frontend profile, link breakdown, `-no_deduplicate` rejected, per-job peak RSS added (see P0.5 below)
- [x] P0.6 compatibility inventory: type-name, bundle, and persisted-identity inventory; goldens where missing; runtime-identity guardrail; slice checklist (see P0.6 below)
- [x] P0.7 ratchets file and guardrail gate

**Phase 0 exit gate (2026-09-29): closed, with ADR-08 explicitly deferred.**
- Met: baseline recorded (Baseline, P0.1); the index graph agrees with the top offenders (P0.2); no production behavior changed. P0.6 made one access-only change.
- Decided with evidence (see Decisions): ADR-01 and ADR-07, then ADR-02, 03, 04, 05, 06, and 09, accepted as written in the plan.
- **Deferred:** ADR-08 admission and caching stays Proposed. It is gated to P1.3 (admission v2) and §5.5 (caching correctness evidence), and it does not block P1 or W1.

~~Phase 0 exit gate (2026-09-29): not yet met.~~ Superseded the same day by the maintainer decisions above.

## P0.4 — fixed per-job overhead (2026-09-28)

The "no-op relink" hypothesis was wrong. A no-change focused `dev-test` spent about 75 s (41 s "build" plus a slow `swift test`) because of two causes:

1. **Per-job environment defeats SwiftPM's caches.** SwiftPM keys its manifest cache on the full process environment, since manifests can read it (this `Package.swift` does). Conductor exported a unique `REPOPROMPT_CONDUCTOR_JOB_TICKET` to every job, so each build re-evaluated every package manifest and re-planned: 28–31 s no-op versus 0.7 s with a stable environment (reproduced directly).
2. **Test execution through SwiftPM.** `swift test --skip-build` ran in the sandboxed environment, which again missed the manifest cache (26–36 s for a 7 ms test with any single sandbox variable changed). Alternating `swift build` and `swift test` also forced the next build to re-plan (about 10–15 s).

Fixes:

- `Scripts/conductor.py`: the job ticket is exported only to conductor's own `__operation_runner`, which pops it on entry (`capture_job_ticket`); readers use `current_job_ticket()`. SwiftPM-facing commands now see a stable, allowlisted environment.
- `Scripts/ci_app_test_runner.py` local path: build with SwiftPM, list tests with the toolchain's `swiftpm-xctest-helper`, apply `--filter` with SwiftPM's regex-search semantics (whole suites collapsed), then run the bundle directly with `xctest` inside the same sandbox.
  - It falls back to `swift test --skip-build` when `--test-product` is given, when any test imports Swift Testing, when the bundle or helper is unavailable, or when the filter is not a valid Python regex.
  - Parity: the helper and `swift test list` report the same 3,599 tests, with no differences.

Measured through conductor (focused filter `RepoPromptRegexCoreTests`, 7 tests):

| Scenario | Before | After |
| --- | --- | --- |
| Nothing changed | 74.7 s | **2.2 s** (build 0.6 s) |
| One app file touched, body only (1 file compiled) | — | 41 s |
| One unused top-level `func` added to the app (interface change) | — | 246 s (6 app files and **all 370 test files** recompiled; build 168 s) |

The interface-change row is the monolith cost that per-module test targets must remove: any interface change to `RepoPromptApp` recompiles the entire `@testable` test target.

Follow-up: in the interface-change job about 78 s of execution happened outside SwiftPM (conductor build-cache handling). It is about 1.5 s on no-op jobs. Investigate under P0.1. **Explained in P0.1:** it is SwiftPM emitting the build's diagnostics after its build timer stops, not conductor cache handling.

## P0.3 focused-test executor — leaf slice (2026-09-28)

Candidates:
- **(a) native aggregate**: `conductor test --filter RepoPromptMCPCoreTests`. It builds the package test graph and runs the one `RepoPromptCEPackageTests.xctest`.
- **(b) Swift Build per target**: `conductor test --module RepoPromptMCPCoreTests` (commit `02d97447`). It runs `swift build --build-system swiftbuild --scratch-path .build/swiftbuild --product RepoPromptMCPCoreTests`, lists the bundle with `swiftpm-xctest-helper`, and runs it directly with `xctest` in the sandbox.

Method:
- The probe edits were made in `Sources/RepoPromptMCPCore/MCPReplayState.swift`:
  - **body:** `replayFrames()` rewritten to an equivalent `let` plus `return`;
  - **interface:** an unused top-level `func` appended;
  - **revert:** the file restored, which is a second interface change.
- Each scenario ran once per path, from the same warm state. All probes are reverted.
- Times come from conductor job JSON:
  - `exec` is `executionSeconds`. It starts after global heavy admission, so queue and heavy-slot waits (up to 35 min here, because other checkouts held the slot) are excluded.
  - `pre-test` is process start to the first `Test Suite … started` line.
  - `build` is the build tool's own `Build complete!` time.

| Scenario | Path | Ticket | exec | pre-test | build | What was rebuilt |
| --- | --- | --- | --- | --- | --- | --- |
| Cold (new scratch path) | b | `60a66da1` | 651.5 s | 569.4 s | 321.5 s | Dependency resolve/fetch (~227 s) plus the full closure: 57 targets, no `RepoPromptApp` |
| No-op | b | `18a5de6d` | 81.8 s | 40.1 s | 19.1 s | Nothing compiled; Swift Build re-plans (1,888 planning steps) |
| No-op (warm) | a | `107a8bca` | 76.2 s | 22.1 s | 3.3 s | Nothing |
| Body edit | b | `f10b33bf` | **41.3 s** | **22.0 s** | 12.0 s | `RepoPromptMCPCore` plus the module bundle link |
| Body edit | a | `2a706f79` | 114.5 s | 84.4 s | 66.9 s | 1 file, then relinks `repoprompt-mcp` and the aggregate bundle (app included) |
| Interface edit | b | `edd41ba4` | **61.3 s** | **34.0 s** | 24.2 s | `RepoPromptMCPCore`, `RepoPromptMCPCoreTests` |
| Interface edit | a | `5e3f5b83` | 210.5 s | 193.3 s | 116.1 s | MCPCore, the MCP executable, and **360 `RepoPromptTests` files** (two app tests `@testable import RepoPromptMCPCore`), then the aggregate link |
| Revert (interface) | b | `9d0e7019` | **48.1 s** | **26.7 s** | 18.0 s | As for the interface edit |
| Revert (interface) | a | `48397249` | 389.8 s | 356.9 s | 166.9 s | As for the interface edit |

Medians over the three edit scenarios:

| Metric | (a) aggregate | (b) module | Reduction |
| --- | --- | --- | --- |
| exec (edit → tests finished, excluding queue) | 210.5 s | 48.1 s | 77% |
| pre-test (edit → first test starts) | 193.3 s | 26.7 s | 86% |
| build tool only | 116.1 s | 18.0 s | 84% |

Findings:

- **App exclusion.** No (b) log contains `Compiling RepoPromptApp` or `Compiling RepoPromptTests`. The Swift Build target list never includes `RepoPromptApp`; the cold closure is 57 targets, mostly tree-sitter, NIO, and collections through DomainRuntime and CodeMapCore.
- **Discovery parity.**
  - `swiftpm-xctest-helper` lists 66 tests in 9 suites from `RepoPromptMCPCoreTests.xctest`.
  - That equals the 66 `func test…` declarations in `Tests/RepoPromptMCPCoreTests` and the 66 that path (a) executes for the same filter.
  - The target has no Swift Testing tests.
  - Every run in both paths passed 66/66.
- **No swiftbuild blockers** on this package with Swift 6.3.3 / Xcode 26.5 SDK. The only diagnostics were the existing `-Wshorten-64-to-32` warnings in the tree-sitter Python scanner.
- **Where the win comes from.**
  - Interface changes no longer recompile the app test target.
  - Body edits no longer relink the aggregate bundle.
  - Module runs also skip conductor's seeded `.build` cache handling. On path (a), 17–190 s per edit job ran outside SwiftPM (pre-test minus build), which is the same unexplained overhead as the P0.4 follow-up.
- **Costs of (b):**
  - A no-op costs about 18 s more before tests start, because Swift Build re-plans every invocation (19 s versus 3 s).
  - The first run in a worktree resolves and fetches dependencies again (~227 s) and builds the closure from scratch.
  - `.build/swiftbuild` is 5.4 GB for this one closure, against 4.2 GB for the whole native `.build/arm64-apple-macosx`. Disk and a cold start are the price of a second scratch path until §5.5 shares caches.
- **Noise.** Test execution for the same 66 tests ranged from 17 s to 82 s. That target's `DirectHeadlessOracleGroupTests` is timing-sensitive, and other checkouts were building concurrently. `pre-test` is the cleaner comparison; each row is one sample.

**ADR-07 recommendation (leaf slice; superseded by the decision in the next section):** adopt (b) as the focused-test executor for test targets whose closure excludes `RepoPromptApp`, behind `dev-test MODULE=` (P1.3).
- It clears the §3.4/P0.3 gate: the median edit→owning-test time, excluding queue, is 77% lower (the gate is ≥ 30%), with no discovery loss.
- Keep the native aggregate as the default `FILTER` path and in CI until:
  1. the workspace/agent-adjacent slice repeats this result;
  2. module runs support Swift Testing (the helper path lists XCTest only);
  3. peak RSS and CI parity are measured.
- Candidates (c) xcodebuild per-module schemes and (d) local package were not measured. (b) already removes the app from the loop without new packaging, so (d) needs a separate justification under §3.4.

## P0.3 focused-test executor — agent-adjacent slice, Swift Testing, and decision (2026-09-28)

### Swift Testing in `--module` runs

The invocation was derived from SwiftPM 6.3.3 on a throwaway package with XCTest and Swift Testing tests. `swiftpm-testing-helper --help` prints nothing, and `swift test --build-system swiftbuild -v` does not print the test commands, so the argument vectors and environment were captured with `ps` while `swift test` ran:

- **XCTest:** `xctest [-XCTest <selectors>] <T>.xctest` with `SWIFT_TESTING_ENABLED=0`. Without that variable `xctest` also hosts the Swift Testing tests. Our first real-repo run hit exactly this and ran them twice.
- **Swift Testing:** `swiftpm-testing-helper --test-bundle-path <T>.xctest/Contents/MacOS/<T> --build-system swiftbuild [--filter F] <same path> --testing-library swift-testing`.
  - `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` must point at the platform's Developer frameworks. Without them the helper cannot `dlopen` the bundle (`@rpath/XCTest.framework` not found).
- **Order and exit status:** both libraries always run, XCTest first. The run fails if either fails. Swift Testing's exit 69 (no tests matched) counts as success, as in `swift test`.

`Scripts/ci_app_test_runner.py` now does the same in `--module` runs whenever a file under `Tests/<Target>` imports Testing (commit `145862db`).
- **Detection:** `sources_import_swift_testing`, which the aggregate path's `package_uses_swift_testing` now also uses (over `Tests/`).
- **Filter equivalence:**
  - Swift Testing receives `--filter` verbatim, as SwiftPM forwards it, so its selection is identical by construction.
  - XCTest selection matches the helper's listing with Python `re`, whereas SwiftPM uses ICU. The runner therefore accepts only a portable subset: literals, escaped punctuation, `.`, `*`, `+`, `?`, `|`, anchors, plain groups, and simple classes.
  - Anything else fails closed: `--module` exits 2 before building, and the aggregate direct path falls back to `swift test`.
- **Other fail-closed cases (exit 2):** `Tests/<Target>` is missing; or the target imports Testing but the helper or the platform path is unavailable.
- **Unit tests:** 7 new cases in `Scripts/test_ci_app_test_runner.py` cover:
  - argument vectors and environments;
  - exit-code mapping;
  - both libraries running after an XCTest failure;
  - a Swift Testing–only selection;
  - the fail-closed paths and portable filters;
  - the shared detection.
- **End to end on this repo,** with a temporary two-test `@Suite` in `Tests/RepoPromptDomainRuntimeTests` (removed afterwards):
  - unfiltered: 258 XCTest plus 2 Swift Testing tests, each run once (`28a964b4`);
  - `--filter 'P03SwiftTestingProbe|DomainAgentRunExecutionContractsTests'`: 5 plus 2 (`75ece559`).

No first-party test target imports Testing today.

### Second slice: `RepoPromptDomainRuntimeTests`

This is the workspace/agent domain: agent-session links, worktree bindings, Oracle groups, and workspace activation.
- In `Package.swift` the test target depends only on `RepoPromptDomainRuntime` and the `MCP` product.
- `RepoPromptDomainRuntime` depends on `RepoPromptShared`, `RepoPromptWorkspaceCore`, `RepoPromptC`, `RepoPromptCodeMapCore`, `Logging`, and `MCP`.
- No path reaches `RepoPromptApp`.

Method: the same as the leaf slice, with these specifics.
- **Probe file:** `Sources/RepoPromptDomainRuntime/ArrayExtensions.swift`.
  - **body:** `chunked(into:)` computes its reserve capacity through a `let`;
  - **interface:** an unused top-level `func` appended;
  - **revert:** `git checkout`, a second interface change.
- **Order:** in each scenario (b) ran first, then (a), from the same source state. One sample per path per scenario.
- **Metrics:** `exec`, `pre-test`, and `build` are defined as before. Heavy-slot waits (up to 6 min 15 s here) are excluded.
- **What was rebuilt:**
  - for (a), from the native `Compiling`/`Linking` lines;
  - for (b), from index-store units and object/product mtimes in `.build/swiftbuild`, because Swift Build prints no per-file lines.

| Scenario | Path | Ticket | exec | pre-test | build | What was rebuilt |
| --- | --- | --- | --- | --- | --- | --- |
| Warm-up | b | `5b0dc819` | 89.0 s | 71.9 s | 52.2 s | The test target (the Swift Testing probe had just been removed) |
| Warm-up | a | `ae2e90f5` | 46.3 s | 35.3 s | 22.7 s | Nothing |
| No-op | b | `14dd4be9` | 22.1 s | 13.6 s | 6.3 s | Nothing; Swift Build re-plans |
| No-op | a | `e389e5ca` | 7.7 s | 3.7 s | 1.1 s | Nothing |
| Body edit | b | `64abd3ff` | **15.5 s** | **13.1 s** | 7.7 s | `ArrayExtensions.o`, the prelinked `RepoPromptDomainRuntime.o`, the module bundle |
| Body edit | a | `59e607e0` | 72.6 s | 64.0 s | 53.0 s | All 86 `RepoPromptDomainRuntime` files; relinks `repoprompt-mcp`, the `RepoPrompt` app executable, and the aggregate bundle |
| Interface edit | b | `c49b5a2a` | **86.1 s** | **80.8 s** | 68.6 s | 81 of 86 DomainRuntime files, all 20 test files, the bundle |
| Interface edit | a | `273905ca` | 866.6 s | 859.3 s | 530.0 s | DomainRuntime 81, MCPCore 32, MCP 1, MCPCoreTests 9, DomainRuntimeTests 2, **`RepoPromptApp` 1,142 and `RepoPromptTests` 360 files**; the same three links |
| Revert (interface) | b | `b8df4df5` | **33.5 s** | **30.5 s** | 25.4 s | As for the interface edit |
| Revert (interface) | a | `b31cf893` | 665.1 s | 662.6 s | 558.6 s | As for the interface edit |

Medians over the three edit scenarios:

| Metric | (a) aggregate | (b) module | Reduction |
| --- | --- | --- | --- |
| exec (edit → tests finished, excluding queue) | 665.1 s | 33.5 s | 95% |
| pre-test (edit → first test starts) | 662.6 s | 30.5 s | 95% |
| build tool only | 530.0 s | 25.4 s | 95% |

Findings:

- **App exclusion.** No (b) log mentions `RepoPromptApp`, and `.build/swiftbuild` contains no `RepoPromptApp` artifacts. On (a), any `RepoPromptDomainRuntime` interface change recompiles the whole app (1,142 files), because the app imports the module, plus 360 app test files.
- **Discovery parity.**
  - `swiftpm-xctest-helper` lists 258 tests in 20 suites from `RepoPromptDomainRuntimeTests.xctest`.
  - That equals the 258 `func test…()` declarations in `Tests/RepoPromptDomainRuntimeTests`.
  - Every run in both paths executed 258 with 0 failures.
- **Noise.** The (b) interface (86 s) and revert (34 s) runs rebuilt the same files; each row is one sample.
- **Unattributed gap on (a).** It spent 11–329 s between `Build complete!` and the first test. This is not conductor's cache publication, which runs after the tests. The gap is unattributed, like the leaf-slice and P0.4 follow-ups. **Explained in P0.1:** only 12–16 s falls after `Build complete!` (runner listing steps); the rest is SwiftPM's post-timer diagnostic output, which this metric counted as part of the gap.
- **Costs of (b).**
  - A no-op starts tests about 10 s later (Swift Build re-plans: 6.3 s versus 1.1 s).
  - `.build/swiftbuild` is 5.5 GB now that it covers both slices (5.4 GB after the leaf slice), next to 4.2 GB for `.build/arm64-apple-macosx`.
- **Cold start.** Not re-measured, because the scratch path was already warm from the leaf slice, which shares the DomainRuntime closure. This target's first build there (`0c42dc38`, with the Swift Testing probe) took 159 s exec and a 65.6 s build.

### Peak RSS

Method:
- **Sampler:** a local script (`.build/p03-rss/rss_sampler.py`, not committed) polled `ps -axww -o pid=,ppid=,rss=,args=` every 0.5 s while the job ran. It is read-only and sends no signals.
- **Root process:** the job's `ci_app_test_runner.py`, matched on this worktree's absolute script path plus `--local --module …` or `--local --filter …`, so jobs from other checkouts cannot match.
- **Aggregation:** each sample sums RSS over the root's descendant tree.
- **Build service:** the sampler also looked for a `SWBBuildService` outside the tree. None appeared: SwiftPM 6.3.3 runs Swift Build in-process in `swift-build`.
- **Caveats:**
  - the tree sum counts shared pages once per process, so it is an upper bound;
  - 0.5 s sampling can miss short compiler peaks, so single-process figures are lower bounds.
- **Runs sampled:** the interface-edit rows, the heaviest edit scenario.

| Run | Ticket | Samples | Peak tree RSS | Processes at peak | Largest single processes |
| --- | --- | --- | --- | --- | --- |
| (b) module, interface edit | `c49b5a2a` | 77 | 1,553 MiB | 10 | `swift-build` 313, `ld` 263, `swift-frontend` 237 MiB |
| (a) aggregate, interface edit | `273905ca` | 860 | 3,856 MiB | 15 | `dsymutil` 2,070, `ld` 1,988, `swift-frontend` 1,153, `swift-driver` 596 MiB |

(a) peaked 55 s into the app recompile, with parallel `swift-frontend` jobs. Its largest single processes are the app and aggregate link and dSYM steps, which (b) never runs.

### ADR-07 decision

Gate: at least 30% lower median edit→owning-test time excluding queue, and no discovery loss.

| Slice | Median exec, (a) → (b) | Reduction | Discovery (helper = declared = executed) |
| --- | --- | --- | --- |
| Leaf: `RepoPromptMCPCoreTests` | 210.5 s → 48.1 s | 77% | 66 = 66 = 66 |
| Agent-adjacent: `RepoPromptDomainRuntimeTests` | 665.1 s → 33.5 s | 95% | 258 = 258 = 258 |

**Accepted.**
- **Adopted executor:** Swift Build per-target bundles (`conductor test --module`), for test targets whose closure excludes `RepoPromptApp`. P1.3 surfaces it as `dev-test MODULE=`.
- **Unchanged paths:** the native aggregate stays the default `FILTER` path, the path for targets that depend on the app, and the CI path.
- **Preconditions met:**
  - Swift Testing is supported (above).
  - Release builds and packaging are untouched (still native SwiftPM), so the §3.4 clean-build clause is unaffected.
- **Not adopted:** candidates (c) xcodebuild per-module schemes and (d) a local package were not measured. (b) already takes the app out of the loop without new packaging or generated schemes, and (d) would still need its own §3.4 justification.
- **Costs accepted:**
  - a no-op about 10 s slower;
  - a second scratch path (5.5 GB) with a one-time cold resolve and build per worktree, until §5.5 shares caches.
- **Follow-ups, not blockers:**
  - CI parity for module runs (CI stays on the aggregate);
  - the unattributed post-build gap on (a) (P0.1);
  - cross-worktree cache sharing (§5.5).

## W1 slice S14 — retire the app bridging header (2026-09-28)

**Manifest:**
- Deleted `Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h` and removed the app target's `unsafeFlags` (`-import-objc-header …`, `-disable-bridging-pch`) and the now-unused `packageRoot`/`#filePath` manifest value.
- Added `Sources/RepoPromptC/include/repo_gitignore.h`. It declares the existing gitignore wrapper API; `repo_gitignore_pattern` moved out of `repo_wildmatch_wrapper.c` with an identical layout.
- Added `Sources/RepoPromptC/include/repo_process_security.h` and `src/process_security/repo_process_security.c` with `repo_deny_debugger_attachment()`, because `ptrace` is not exported to Swift by `Darwin`.
- Added explicit `import RepoPromptC` to the 7 Swift consumers: `ApplicationSecurity`, `SearchMatch`, `SearchPathFiltering`, `WorkspaceReadableFileService`, `PathSearchIndex`, `RepoSearchBatchScorer`, `GitignoreCompiler`.
  - `sysctl`/`kinfo_proc`/`P_TRACED` already come from `Darwin`.
  - No app Swift file used PCRE2 C symbols through the bridge.
- Guardrails now reject `-import-objc-header` and a recreated `Sources/RepoPrompt/Support`. The Xcode generator rejects a bridging header on any target, replacing its old "app must own the header" assertion. `AGENTS.md`, `source-layout.md`, and the concurrency profile reference are updated.

**Why:** a bridging header ties C interop to one Swift target, blocks moving any consumer into another module, and needed `unsafeFlags`. Every consumer now names its dependency explicitly, which the import check can enforce.

**Evidence:**
- The release-only `ptrace` call path (`#if !DEBUG`) and the gitignore API type-check against the generated `RepoPromptC` module map (`swiftc -typecheck`).
- `generate_xcode_workspace.py generate && validate` pass.
- `make guardrails` passes.
- Full suite through conductor (ticket `7b24e1f3`): exit 0, **3,599 tests executed**, 2 skipped, 0 failures, 0 compile errors. The build took 1,314 s because dropping the bridging header changes every app compile flag.

**Found during validation — umbrella directories leave warm caches stale.** The first full run failed: `GitignoreCompiler` could not see the new `repo_gitignore.h` symbols. The cached `RepoPromptC` precompiled module (06:31) predated the header (07:24). With a generated `umbrella` *directory*, adding a header is not a tracked module input, so warm clang module caches, including CI's restored `.build`, are not invalidated.
- Fix: an explicit umbrella header, `Sources/RepoPromptC/include/RepoPromptC.h`, listing every public header. Adding or removing a header now edits a tracked input.
- A guardrail fails if any `RepoPromptC` header is missing from the umbrella.
- Rule for all future C targets: provide an explicit umbrella header.
- Style: `conductor lint` passed (SwiftFormat 0/1594 files need formatting; SwiftLint `--strict` clean).

Follow-up (style lane): SwiftFormat `--lint` took 930 s in this fresh worktree. Investigate cache reuse across worktrees under P0.1/§5.5; it lengthens every agent's pre-handoff check.

## W1 slice S15 — `RepoPromptMCPCore` library plus a thin MCP executable (2026-09-28)

**Manifest:**
- All `Sources/RepoPromptMCP` files except `main.swift` moved to `Sources/RepoPromptMCPCore` (`git mv`).
- The declarations and globals from the old 3,759-line `main.swift` moved to `RepoPromptMCPCore/MCPCLIProcess.swift`. `main.swift` keeps only the entry script (about 180 lines).
- **Eager-initialization parity:** `main.swift` globals initialize in source order at launch; library globals are lazy. The new `bootstrapMCPCLIProcess()` is the entry's first statement and forces `log`, then `debugLogURL`, whose initializer truncates the socket debug log at startup, as before. No other moved global has an initialization side effect.
- **Access:** only what the entry script uses became `package`. That is the CLI mode and option types, exit-code and error enums, the four service types' initializers and `run()` requirements, `DirectHeadlessChildBridge.isRequested/run`, `MCPBackendSelection.resolve`, `RuntimePolicyAdministration.run`, the stdin probes, `cliDisplayCommand`, `handleRuntimeError`, and `log`. Nothing is `public`.
- **Tests:** the 9 CLI test files that did not import the app moved to the new `RepoPromptMCPCoreTests` target (dependencies: MCPCore, DomainRuntime, Shared, MCP). The 2 that also need the app (`OracleGroupBoundaryTests`, `MCPExportWatchdogContractTests`) stay in `RepoPromptTests` and `@testable import RepoPromptMCPCore`. `RepoPromptTests` no longer depends on an executable target.
- **Tooling:** `sync_mcp_cli_version.sh` now points at `MCPCLIProcess.swift`; the `let CLI_VERSION` form is unchanged and `--check` passes. Also updated: the headless guardrails (array of CLI source roots; core-owned files checked in the core), the workspace-core guardrail consumer list, style and lint paths, the preflight MCP path pattern, the conductor diagnostics target map, the Xcode generator's test-dependency topology and README text, `AGENTS.md`, `xcode-workspace.md`, and `source-layout.md`.

**Why:** CLI owner tests no longer compile or link the 648k-line app, and the root test target stops depending on an executable, which was the stated blocker for native Xcode test bundles.

**Evidence:**
- `conductor swift-build --product repoprompt-mcp` passes.
- `make guardrails` passes; the gated `tests_sleep_calls` ratchet improved from 49 to 48 as one test left the app target (47 to 46 before the rebase onto main).
- Xcode generator `generate` and `validate` pass; `make conductor-selftest` passes.
- Full suite through conductor (`s15-full-2`): exit 0, **3,599 tests executed**, 2 skipped, 0 failures. The first attempt failed because one moved test used the `RepoRoot` helper from `RepoPromptTests/Helpers`. That helper now lives in a new shared `RepoPromptTestSupport` library target under `Tests/`, the first TestSupport target per plan §3.6; a guardrail rejects any production target that depends on it.
- CLI smoke on the built binary: `--version`, `--help`, and the no-argument usage path are unchanged. With `MCP_SOCKET_DEBUG=1`, a pre-seeded socket debug log is truncated to 0 bytes at launch even for `--version`, which confirms eager-initialization parity.
- Ratchet baseline lowered: `tests_sleep_calls` 49 → 48 (47 → 46 before the rebase onto main).

## P0.1 — structured conductor timing (2026-09-28)

**What conductor records** (`Scripts/conductor.py`; additive, with no change to lanes, admission, or job behavior):
- The job payload (`job status --json`) gains `phaseTimings`. The same data is written after the job ends to `<ticket>.timing.json` next to the job log, with the operation, state, exit code, and build-cache state. It expires with its log.
- **Marks** are wall-clock epoch seconds, recorded the first time each point is reached:
  - `queued`, `laneAdmitted`
  - `buildCachePrepareStarted` / `Finished` (seed clone, and for seeded jobs the cleanup-deadline scan)
  - `heavySlotWaitStarted`, `heavySlotAcquired`
  - `processStarted`
  - `cacheColdRetryStarted`
  - `buildCompleted` (the last `Build complete! (Xs)` before the first test; X is kept as `buildReportedSeconds`)
  - `firstTestStarted` (the first XCTest `Test Suite '…' started` or Swift Testing `Test run started`)
  - `processFinished`
  - `cachePublicationStarted` / `Finished`
  - `finished`
- **Output marks are receipt times.** They are when conductor read the line from the pipe.
- **Segments** are derived from the marks and are omitted when an endpoint is missing:
  - `queueSeconds`, `buildCachePrepareSeconds`, `heavySlotWaitSeconds`, `launchSeconds`
  - `processToBuildCompleteSeconds`, `buildReportedSeconds`
  - `preBuildSeconds`: process time before `Build complete!` minus SwiftPM's reported build time
  - `buildCompleteToFirstTestSeconds`, `processToFirstTestSeconds`, `testSeconds`
  - `processSeconds` (equals `executionSeconds`)
  - `finalizeSeconds`, `cachePublicationSeconds`, `totalSeconds`
- **Consumers:**
  - `Scripts/conductor_job_timings.py` prefers the record and falls back to log parsing. It adds per-category percentiles for the prepare, pre-build, build, post-build, test, and publication segments.
  - Tests: `Scripts/test_conductor_job_phases.py` (new, in `make conductor-selftest`) and new cases in `test_conductor_job_timings.py`.
- **Not in this item:**
  - the §5.1 compiler-flag measurement lane, which goes with P0.5 type-check budgets. **P0.5** added opt-in measurement builds (`--scratch`); a scheduled lane is still open;
  - per-job peak RSS, which goes with P1.3 admission v2. **Added in P0.5** as `phaseTimings.peakRss`.

**Method.**
- **Jobs:** four `conductor test --filter RepoPromptRegexCoreTests` jobs on the aggregate path, run in sequence after a daemon restart, plus one synthetic output job. Each row is one sample.
- **Probe file:** `Sources/RepoPrompt/Infrastructure/Utilities/SequenceExtension.swift`.
  - **body:** `[T]()` became `: [T] = []`;
  - **interface:** an unused top-level `func` appended.
  - The probe is reverted. This worktree's `.build` still holds the interface build, so its next build recompiles.
- **Sampler:** a read-only script (`.build/p01-timing/sampler.py`, not committed).
  - It polled `ps` every 0.25 s for descendants of this worktree's `ci_app_test_runner.py`, plus the job-log size.
  - It records which tool runs in each gap.

| Job | Ticket | Heavy wait | Prepare | Process | Build (SwiftPM) | Pre-build | Build complete → first test | Tests | Publication | Total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| No-op, first after daemon restart | `1cbc9abf` | 0.0 s | 1.4 s | 57.1 s | 37.8 s (re-plan only) | 3.4 s | 15.7 s | 0.2 s | **134.8 s** (published) | 193.5 s |
| No-op | `7f6a9b46` | 179.3 s | 2.4 s | 18.8 s | 2.4 s | 2.3 s | 13.8 s | 0.3 s | 1.8 s (throttled) | 202.7 s |
| Body edit (1 app file, relinks) | `9673ee20` | 2,219.9 s | 2.2 s | 293.9 s | 278.2 s | 2.0 s | 13.5 s | 0.2 s | 1.4 s (throttled) | 2,517.7 s |
| Interface edit (1,059 app + 360 test files) | `c54f1c6c` | 1,793.7 s | 6.1 s | 1,017.2 s | 764.5 s | **240.9 s** | 11.7 s | 0.1 s | **243.9 s** (published) | 3,061.3 s |

Findings:

- **P0.4 follow-up (~78 s outside SwiftPM on large-change jobs): SwiftPM emits diagnostics after its build timer stops. It is not conductor cache handling.**
  - Cache prepare (1.4–6.1 s) runs before the process starts, and publication runs after it exits, so neither is inside `executionSeconds`.
  - In the interface job, the sampler shows the last `swift-frontend`, `ld`, and `dsymutil` exiting at about 766 s. That matches SwiftPM's reported 764.5 s.
  - `swift-build` then ran alone, with no children, for about 238 s. The job log grew from 2.0 MB to 6.5 MB (about 19 KB/s) before `Build complete!` arrived.
  - The build emitted 72.6k lines, including 15,484 warnings. The top offenders:
    - 4,608 deprecated MCP `text(_:metadata:)`;
    - 1,356 "no 'async' operations occur within 'await'";
    - 630 "no calls to throwing functions occur within 'try'";
    - 508 main-actor `shared` access.
  - **Conductor is not the bottleneck.** `conductor diagnostics high-output --lines 20000 --warnings 80000` (`744d7dbf`) pumped 5.3 MB and 100k lines in 1.9 s, about 150 times faster.
  - The cost scales with diagnostic volume and machine load. In the P0.3 logs, the jobs with 75k lines had gaps of 104 s and 329 s, the jobs with 15k lines had 77 s and 190 s, and the jobs with ≤ 1.3k lines had 3–19 s. The P0.4 78 s (6 app and 370 test files recompiled) fits the same pattern; that job's log was not re-sampled.
- **P0.3 follow-up (11–329 s between build and first test): only 12–16 s is post-build.**
  - The old metric was pre-test minus reported build, so it included the diagnostic output above.
  - With receipt timestamps, the time after `Build complete!` is 11.7–15.7 s in all four jobs. It is spent entirely in the runner's direct path:
    - `swift build --show-bin-path`: 0.6–3.4 s. It re-evaluates the manifest (`swift-package` and `swift-frontend` children).
    - `swiftpm-xctest-helper` listing the 415 MB aggregate bundle: 5–12 s.
    - `xctest` launch: about 0.8 s.
  - The tests themselves take about 0.2 s.
- **Cache publication is on the job's critical path, and the seed is 14.8 GB.**
  - Publication runs after the tests pass but before the job completes, and it keeps the build lane: 134.8 s and 243.9 s here.
  - It is throttled to once per hour per key, so it hits roughly the first job each hour.
  - The seed includes `.build/swiftbuild` (5.5 GiB of module-run scratch), next to 4.1 GiB for `.build/arm64-apple-macosx`.
- **Other observations:**
  - The first job after a daemon restart re-planned for 37.8 s with nothing compiled.
  - `dsymutil` takes about 64 s of the body-edit build and about 56 s (two runs) of the interface build. It is inside SwiftPM's time and is a P0.5 link lever.

Proposed fixes (not implemented in P0.1):
1. **Diagnostic volume, largest win.** Remove the warnings at the source, starting with the single MCP `text(_:metadata:)` API migration (4,608 of 15,484). Measure under P0.5 whether a lower-volume diagnostic style for local test builds shortens the drain without changing binaries.
2. **Runner listing, simple and safe.**
   - Cache the `swiftpm-xctest-helper` listing keyed on bundle path, size, and mtime. The listing is a pure function of the binary. This saves 5–12 s per job whose bundle did not relink.
   - Resolve the bin path once instead of running `swift build --show-bin-path` (0.6–3.4 s).
3. **Publication, needs a decision.**
   - Exclude `.build/swiftbuild` from the seed in `_sanitize_seed`. That is about 5.5 GiB less to clone, sanitize, and measure, but new worktrees lose a warm module scratch path.
     - **Decided (2026-09-29): excluded**, next to `.build/measure`, with a unit test (`test_seed_sanitizing_drops_module_test_scratch`). A new worktree's first module run builds its closure cold.
   - Alternatively, report the job result before publishing. That changes the deliberate hold on the build lane and needs a design.

## P0.2 — index-store dependency graph (2026-09-29)

**Tool:** `Scripts/modularization_index_graph.py`, tested by `Scripts/test_modularization_index_graph.py` (16 cases over a synthetic fake store, plus one ctypes binding case against an empty store; in `make conductor-selftest`).

**Reader choice.** Xcode 26.3's default toolchain ships `usr/lib/libIndexStore.dylib` with the stable C API, including the function-pointer `*_apply_f` variants. The tool binds 22 of those functions with `ctypes`, locating the library next to `xcrun --find swift` (override: `--library` or `REPOPROMPT_LIBINDEXSTORE`). No Swift package, pip dependency, or new build step is needed. No store-dumping CLI ships with Xcode 26.3:
- `sourcekit-lsp` answers per-symbol editor queries.
- `xcindex-test` is a diagnostic driver for Xcode's build-system index preparation that needs an Xcode project.
- Neither enumerates units and records.

**Source of truth.** `conductor swift-build --product RepoPrompt` (ticket `5ed14530`, exit 0, 768 s, about 1,060 app files recompiled after the P0.1 probe) populates `.build/arm64-apple-macosx/debug/index/store`. SwiftPM enables the index store for debug builds by default.
- The store held 6,460 units, including 2,320 `RepoPromptApp` units.
  - 1,160 point at this worktree's sources.
  - The other 1,160 point at the worktree whose `.build` conductor seeded this one from (`wt-mcp-headless-reliability-core`).
- Per file, the tool uses the newest unit whose main file lies under *this* root's `Sources/RepoPrompt`. It ignores seeded units from other checkouts and units for deleted files. A freshly seeded worktree with no build of its own therefore reports every file as unindexed rather than borrowing another checkout's graph.
- `freshness` in the output reports source files newer than their unit, and source files with no unit. After this build: 1,160 of 1,160 indexed, 0 stale.

**Method.**
- **Definitions and references.**
  - A file *defines* every USR it has a declaration or definition occurrence for.
  - It *references* every USR it has a reference occurrence for, explicit or implicit.
  - An edge A→B exists when A references a USR that B (B ≠ A) defines.
  - USRs are unique across files (0 multiply defined), so no ambiguity rule is needed.
  - Implicit references, such as a getter behind a property read, never create an edge on their own: 0 edges are implicit-only.
- **Local symbols.** The index skips locals, so shadowing cannot create false edges.
- **Triage and cost.**
  - Components, layer ranks, wrong-way rule, and Tarjan SCC are imported from `modularization_metrics.py` unchanged, so both graphs are directly comparable.
  - Extraction takes 21 s uncontended and 82 s alongside a build. `dump` writes the graph as JSON (85 MB) for repeated queries.
- **`readiness --files <paths>`** lists, for a candidate set:
  - app files outside the set that it references, with the symbols involved;
  - the non-system modules it imports;
  - the outside files and symbols that reference it, which need `package` access after a move.

  Accessors fold into their property.

**Results (HEAD `9e912a86`).**

| Measure | Regex prototype | Index store |
| --- | --- | --- |
| File edges | 6,405 | 7,673 |
| Cross-layer file edges | 3,692 | 4,484 |
| Wrong-way file edges | 1,102 | **1,360** (983 shared) |
| Wrong-way target files | 200 | 253 |
| Top 20 / top 40 targets' share | 58% / 73% | 53% / 68% |
| Largest component cycle | 67 of 75 | **66 of 75** |
| Largest file-level cycle | — | 639 of 1,160 files (19 non-trivial file SCCs) |

Components outside the largest index cycle: `Features/AgentMode` (the root folder's own files), `Infrastructure/Concurrency`, `Diffing`, `Networking`, `Regex`, `SyntaxParsing`, `Infrastructure/UI` (root files), `UI/Services`, `WorkspaceContext/PathResolution`.

**Validation diff** (`modularization_index_graph.py compare`). Of the regex's wrong-way edges, 119 (11%) are false. It misses 377 edges (28% of the index count). Every disagreement was classified.

- **Missed by the regex (377):**
  - **233 member or extension-member references.** The regex indexes top-level names only.
    - `App/Views/ContentViewNotificationHandler` → `App/Notifications/AppNotifications.swift` through `Notification.Name.showAPISettingsTab` and other static members.
    - `App/Views/ContentRootShellView` → `App/WindowState.swift` through the `promptManager` and `agentModeViewModel` properties.
  - **143 types the regex cannot see:** nested types, types indented under `#if`, or names under 5 characters.
    - `AgentSessionDataService` → `Diagnostics/App/WorkspaceRestorePerfLog.swift`: `enum WorkspaceRestorePerfLog` is indented under `#if`.
    - `AgentSessionRestoreModels` → `AgentModeViewModel+Types.swift`: `BuiltTranscriptPresentation` is nested in an extension.
  - **1 reference inside string interpolation**, which the regex strips: `ACPProviderSupport` uses `"\(RepoPromptMCPServerConfiguration.defaultServerName)"`.
- **Invented by the regex (119):**
  - **83 same-name collisions with another app declaration.**
    - 66 of the 76 regex edges into `WorkspaceFilesViewModel.swift` are `.relativePath` property uses, matched to a file-private top-level `func relativePath(from:rootPath:)` in that file.
    - `compare` and `insertionIndex` resolve elsewhere, not to the `SortingUtils` globals.
    - `fileName` resolves elsewhere, not to the `ToolCardContainer` global.
  - **4 names that resolve to another module:** `compare` in AI provider files is Foundation's.
  - **32 locals or labels with no indexed symbol:** `if let compare = …` in `AgentToolCardRenderSummary`, `let fileName = …` in `AgentTranscriptServices`.
- **Top 40 targets:** 34 of 40 agree.
  - **Entered:** `App/Notifications/AppNotifications.swift` (39, regex 0), `Diagnostics/AgentMode/AgentModePerfDiagnostics.swift` (39, 0), `MCPServerViewModel+TabContext.swift` (25, 0), `AgentModeViewModel+Types.swift` (22, 3), `Diagnostics/App/WorkspaceRestorePerfLog.swift` (13, 0), `OracleViewModel.swift` (8, 6).
  - **Left:** `SortingUtils.swift` (27 → 0) and `ToolCardContainer.swift` (18 → 0), both collisions. The other four (`AgentPermissionSecureStore`, `CodeMapSelectionGraphContribution`, `MCPFilesystemConstants`, `AgentMonitorPillModels`) sit at the 6–7-edge cutoff.
  - **Large moves:** `WorkspaceFilesViewModel` 76 → 10 (rank 3 → 29); `WindowState` 37 → 54; `AgentTabSession` 21 → 36; `PromptViewModel` 13 → 26; `WorkspaceManagerViewModel` 8 → 20; `WorkspaceModel` 26 → 37.
- **Largest cycle:** the only difference is `Infrastructure/Diffing`.
  - Its 10 inbound regex edges are the identifier `Change` resolving to other declarations.
  - The index finds no in-app reference to any Diffing file. Only `Tests/RepoPromptTests/Diffing/DiffParserRecoveryTests.swift` uses it, which a text search confirms.
- **Inherited triage quirk:** `App/Views` ranks as Views (10) and the rest of `App` as 12, so `App/Views` → `App/*` edges count as wrong-way in both graphs.

**Seam catalog (plan §4) against the index.** Counts are file edges unless stated. "refs" means reference occurrences in other files.

| Seam | Plan evidence (regex) | Index evidence | Change |
| --- | --- | --- | --- |
| S1 | `FontPreset` 85, `FontScaleManager` 77; `.shared` ×130 | 92 and 77 wrong-way; `FontScaleManager.shared` 129 refs in 80 files | Confirmed |
| S2 | `WindowState` 37, `WindowStateManager` 29; `.shared` ×115 | 54 and 29; `WindowStatesManager.shared` 116 refs in 35 files | Larger (`WindowState` members) |
| S3 | 50 lower-layer files use nested types; `+Types` fan-in 55 | `AgentModeViewModel` 43 wrong-way; `+Types` fan-in 56, 22 wrong-way; 144 nested types used from 53 files, 27 of them below the ViewModels rank | Confirmed. Stored-VM-reference counts (13) are not index-derivable |
| S4 | 26 files use nested `Codex*` identity types | The 15 nested `AgentTabSession.Codex*` types are used from **4** files. Codex-prefixed members and types of `AgentTabSession` (156) are used from 19 files, 14 in `AgentMode/Runtime`. `AgentTabSession` 36 wrong-way | **Reframed:** the seam is Codex turn *state* on the session, not a handful of identity types |
| S5 | `RequestMetadata` ×31, `ResolvedTabContextSnapshot` ×18 | `MCPServerViewModel+TabContext.swift` 25 wrong-way (regex 0). `RequestMetadata` 63 refs in 16 files; `ResolvedTabContextSnapshot` 34/10; `TabContextSnapshot` 47/14; `FrozenFileToolAuthority` 25/6; `DomainReadAppExecutionContext` 16/6; `ConnectionBindingSnapshot` 13/3 | Confirmed, larger |
| S6 | `ServerNetworkManager.shared` ×119 | 116 refs in 30 files | Confirmed |
| S7 | `GlobalSettingsStore.shared` ×115; `GlobalSettingsManager` fan-in 73 | 119 refs in 63 files; fan-in 73, 25 wrong-way | Confirmed |
| S8 | `WorkspaceFilesViewModel` fan-in 109, 76 wrong-way | Fan-in **33**, **10** wrong-way, from 8 components (UI/TextField 2, MCP/WindowTools 2; WorkspaceContext, UI/Mentions, MCP/ApplyEdits, MCP, Diffing, Search 1 each) | **Much smaller.** 66 edges were the `relativePath` collision |
| S9 | `SortingUtils` 27, `WorkspaceModel` 26, `ToolCardContainer`'s `toolIcon(for:)`, and others | `SortingUtils` **0**; `ToolCardContainer` **0** (`toolIcon(for:)` is used by 14 files, all in `AgentMode/Views`); `WorkspaceModel` 37; `MCPFilesystemConstants` 6; `ChatPreset` 3; `FileSystemItems` 2; `CopyPresetOverrides`, `ToolResultDTOs`, `FileSystemItemViewModel` 1 each | **Drop `SortingUtils` and `toolIcon(for:)`**; `WorkspaceModel` is the main item |
| S10 | AI → AgentMode 135 edges from 60 files | 150 from 61 (regex with the same predicate: 139/61). `AgentRuntimeProviderService` 43, `ACPAgentProvider` 35 | Confirmed |
| S11 | MCP → AgentRuntime 72, → models 68, → VMs 31, → App 27 | Predicate: `Infrastructure/MCP` outside `MCP/ViewModels`. → `AgentMode/Runtime` 45 (regex 36), → `Features/*/Models` 56 (47), → other ViewModels **83** (32), → `App` 38 (27). `MCP/WindowTools` → layers above MCP: 124 edges from 15 files | Confirmed. The VM share is about 2.6× the regex count. The plan's numbers used a different grouping |
| S12 | `WorktreeStartupInstrumentation` 18 edges from 5 layers | 20 wrong-way from 9 components; **plus `AgentModePerfDiagnostics` 39 and `WorkspaceRestorePerfLog` 13**, both invisible to the regex; `MCPToolExecutionDiagnostics` 8; `AgentSessionLinkCatalogDiagnostics` 3 | **Larger:** add the two perf-diagnostics enums |
| S13 | `NotificationPreferences`, `AppNotificationPayload`, `AppDeepLinkRoute`, `UserNotificationCenterClient` | **`AppNotifications.swift` 39** and `WorkspaceNotifications.swift` 6 (`Notification.Name` members); `NotificationPreferences` 10, `AppDeepLinkRoute` 8, `NotificationService` 5, `UserNotificationCenterClient` 4, `AppNotificationPayload` 3, `AppNotificationCategories` 2 | **Larger:** notification names are the biggest part |
| S14, S15 | — | Landed (W1) | — |
| S16 | God files | Line counts, not graph data | Unchanged |

Not in the catalog:
- **`PromptViewModel`** (26 wrong-way edges) and **`WorkspaceManagerViewModel`** (20) are view models used from lower layers, like S8.
- **`Infrastructure/Diffing`** has no in-app consumers.

**Readiness samples**:

Readiness is only affirmative for a complete, current source/index snapshot. Saved graphs now revalidate source bytes on load; older graph documents without source fingerprints report freshness unknown and cannot claim `ready`.

| Candidate | Files | Blockers (outbound target files) | Outbound symbols | Inbound files / symbols needing access |
| --- | --- | --- | --- | --- |
| `Infrastructure/Concurrency` | 6 | none (**ready**) | 0 | 18 / 19 |
| `Infrastructure/Diffing` | 6 | `AIMessage` (`FileChange`), `FileViewModel`, `WorkspaceFilesViewModel` | 13 | 0 / 0 |
| `Infrastructure/Utilities` | 11 | `CustomOpenAIProvider` (error enum), `LineRange`, `SliceRangeMath` | 13 | 52 / 79 |
| `Infrastructure/Process` | 24 | `AsyncScope`, `TaskSemaphore`, `FileSystemService` (2 files), `MCPConfigExportService`, `MCPIntegrationHelper` | 16 | 46 / 179 |

**Ratchet decision: keep the regex source.** Neither `app_wrong_way_file_edges` nor `app_largest_cycle_components` switches to the index.
- **The index needs a build.** It is exact only after a current debug build of the app, which took 768 s here. `make guardrails`, the commit preflight, and the CI guardrail step run without one. A stale or absent store would make the gate depend on which worktree ran it.
- **`app_largest_cycle_components` is now informational.** A dependency-free helper with a colliding parameter name can raise the lexical SCC size, so the prior claim that gating was sound was incorrect. Promote it only after scope-correct or compiler-derived edges are available in the gate.
- **`app_wrong_way_file_edges` stays tracked, not gated.** With 11% false edges and 28% missed, the regex count can move by name collisions alone, for example a new file-private global named like a common property.
- **Index baseline.** For slice reporting it is **1,360 wrong-way file edges and 66 of 75 components** (HEAD `9e912a86`). Slices that change boundaries record both counts after their conductor build.
- **When to gate on the index:** promote to an index-backed gate once CI has a build-producing job that can run `report` after building (P1.4 build-once). It is not added to `ratchets.json`, because `update` would drop keys that `collect` does not produce.

**Validation.**
- `make guardrails` passes, with modularization ratchets ok.
- `make conductor-selftest`: every suite passes except `test_local_production_installer.py`.
  - It failed 3 of 18 in the make run, then 5, 1, and 4 in three standalone reruns.
  - Each run failed a different subset, always with a 15 s `install_local_production.sh` subprocess timeout. The 15-minute load average was about 45 at the start.
  - This change does not touch the installer or its test. The failures are the known load-sensitive flake.
- `test_security_inventory.py`, the suite after it, passes standalone.

## P0.5 — link and type-check levers (2026-09-29)

**Tooling added** (`Scripts/conductor.py`, `Scripts/ci_app_test_runner.py`; default jobs unchanged):
- **Measurement builds.** `swift-build --product P` and aggregate `test` accept `--scratch <label>`, repeatable `--swiftc-flag=<flag>` (→ `-Xswiftc`), and repeatable `--linker-flag=<flag>` (→ `-Xlinker`).
  - The build runs in `.build/measure/<label>`, so a flag change never invalidates the shared `.build`.
  - Extra flags without `--scratch` are refused, on both the client and the daemon.
  - Measurement jobs are never build-cache eligible, and `_sanitize_seed` drops `.build/measure` from seeds.
  - `--product all` and `test --module` reject `--scratch`; module runs already have their own scratch path.
  - The runner forwards `--scratch-path` and `--build-arg=` to `swift build --build-tests`, bundle discovery, and the `swift test` fallback.
  - Use the `--flag=value` form, and pass lists as separate words: zsh does not word-split `$VAR`. One job here crashed SwiftPM's planner (exit 251) when eight flags arrived as one argument; it was re-run.
- **Per-job peak RSS** (the P0.1 deferral). Heavy-slot jobs run a read-only sampler thread that runs `ps -axo pid=,ppid=,rss=,comm=` once per second and sums RSS over the job's process tree.
  - `phaseTimings.peakRss` (live status and `<ticket>.timing.json`) records `treeBytes` and `treeProcesses` at the tree peak, `largestProcessBytes` and `largestProcessName`, `samples`, and `sampleIntervalSeconds`. The field is absent when nothing was sampled.
  - Cost: one `ps` per second per heavy job. Sampler errors are swallowed, and it never signals or waits on job processes.
  - Caveats, as in P0.3: the tree sum is an upper bound (shared pages counted per process); 1 s sampling misses short peaks. Under load a sample took about 1.3 s.
- **Tests:** 6 new cases in `test_ci_app_test_runner.py` (argv, forwarding, refusals, seed exclusion) and 4 in `test_conductor_job_phases.py` (ps parsing, tree sum, sampler stop, record fold).

**Method.**
- **Runs:** one scratch path, `.build/measure/p05-typecheck`, on HEAD `1c3de429` plus this change. Swift 6.3.3 / Xcode 26.3, 8 cores.
  - **Run 1:** `-warn-long-function-bodies=200`, `-warn-long-expression-type-checking=100`, `-stats-output-dir`, and `-debug-time-function-bodies`. Load average 35–111. Tickets: `46541f94` (MCP product, dependencies warm) and `569c44ed` (app).
  - **Run 2:** the two `-warn-long-*` flags only; this recompiles everything. Load average about 10. Ticket `c3a1636c`.
- **Hit parsing.** Warnings are deduplicated by file, line, column, and message.
  - **Area** is `body` (a View `body` getter or a ViewModifier `body(content:)`), another member of a file declaring a SwiftUI view, or non-view code.
  - Expression hits sit inside function hits; the two kinds are counted separately.
- **Link times** come from SwiftPM's llbuild database (`build.db`, per-command `start`/`end`). Each link command is `swiftc`, which runs `ld` and then `dsymutil`, because debug links pass `-g`. `ld` and `dsymutil` lifetimes come from a 0.5 s `ps` poll of processes whose arguments name the scratch path.
- **Heavy-slot waits are excluded** (4.5 min on run 1, 69 s on the test build). The analysis scripts were throwaways under `.build/measure/tools` and were deleted with the scratch.
- **Driver timing:** `-driver-time-compilation` prints nothing under SwiftPM's integrated driver.
- **Stats granularity:** `-stats-output-dir` gives per-*batch* records (47 compile jobs of about 25 files for the app), so per-file cost comes from `-debug-time-function-bodies`.

### Type-check budgets (`RepoPromptApp`)

| Hits | Run 1 (load 35–111) | Run 2 (load ~10) |
| --- | --- | --- |
| Function bodies ≥ 200 ms | 104 | 92 |
| Function bodies ≥ 500 ms | 24 | 21 |
| Function bodies ≥ 1,000 ms | **10** | **10** |
| Expressions ≥ 100 ms | 26 | 26 |
| Expressions ≥ 200 ms | 10 | 11 |
| Expressions ≥ 500 ms | **6** | **6** |
| Files with a hit | 70 | — |

- **Per-function times barely move with load.** 116 hits appear in both runs; their median ratio is 1.03. The counts that differ come from bodies near a threshold.
- **Other first-party targets** (run 2, unique): `RepoPromptDomainRuntime` 4, `RepoPromptCodeMapCore` 1. SwiftPM builds remote dependencies with warnings suppressed.
- **By area, function hits ≥ 200 ms** (run 1; run 2 in parentheses):
  - View `body`: 33 (31), 41.6 s;
  - other SwiftUI view-file members: 25 (24), 11.5 s;
  - non-view code: 46 (37), 18.5 s.
  - SwiftUI is 58 of 104 hits and **74% of hit time**. At ≥ 1,000 ms it is 8 of 10.
- **Expression hits ≥ 100 ms:** 9 in SwiftUI view files and 17 in non-view code, but 5 of the 6 hits ≥ 500 ms are SwiftUI.
- **By folder (all hits):** `Features/AgentMode` 48, `Features/Settings` 19, `Infrastructure/MCP` 12, `Infrastructure/WorkspaceContext` 8, `Infrastructure/UI` 7, `Features/ContextBuilder` 6.
- **All bodies** (`-debug-time-function-bodies`): 82,422 bodies in 1,145 files, 327 s in total.
  - Bodies at or above each threshold: 2,712 at 25 ms, 1,022 at 50 ms, 318 at 100 ms.
  - The 408 view `body` getters take 53.5 s (16%). The four slowest bodies alone take 27.5 s (8.4%).

Top 25 by time (run 1 ms; run 2 ms):

| # | Run 1 | Run 2 | Kind | Location | What | Area |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 8,762 | 8,741 | function | `Features/AgentMode/Views/ContextDrawer/AgentContextDrawerFilesTab.swift:207` | getter `body` | view `body` |
| 2 | 8,644 | 8,619 | expression | `Features/AgentMode/Views/ContextDrawer/AgentContextDrawerFilesTab.swift:222` | expression (in #1) | view file |
| 3 | 7,882 | 7,663 | function | `App/Views/ContentViewNotificationHandler.swift:65` | `body(content:)` | view `body` |
| 4 | 7,841 | 7,624 | expression | `App/Views/ContentViewNotificationHandler.swift:126` | expression (in #3) | view file |
| 5 | 6,250 | 6,179 | function | `Features/AgentMode/Views/Components/AgentSessionRows.swift:610` | getter `body` | view `body` |
| 6 | 4,605 | 4,688 | function | `Features/AgentMode/Views/Components/AgentSessionsSidebarView.swift:418` | getter `body` | view `body` |
| 7 | 3,168 | 3,008 | function | `Infrastructure/MCP/MCPConnectionManager.swift:12082` | `registerHandlers(for:connectionID:)` | non-view |
| 8 | 2,633 | 2,392 | function | `Infrastructure/MCP/WindowRoutingService.swift:2179` | `updateCachedTools()` | non-view |
| 9 | 1,995 | 1,956 | function | `Features/AgentMode/Views/Components/AgentSessionRows.swift:1393` | getter `body` | view `body` |
| 10 | 1,810 | 1,709 | function | `Features/AgentMode/Views/AgentModeView.swift:1916` | getter `chatTranscript` | view file |
| 11 | 1,696 | 1,652 | function | `Features/AgentMode/Views/ToolCards/AgentAskUserWizardCard.swift:182` | `optionButton(option:question:draft:)` | view file |
| 12 | 1,552 | 1,467 | expression | `Features/AgentMode/Views/AgentModeView.swift:1998` | expression | view file |
| 13 | 1,274 | 1,157 | function | `Infrastructure/UI/Agent/AgentQuestionCard.swift:142` | `optionButton(option:)` | view file |
| 14 | 1,238 | 1,181 | expression | `App/Changelog.swift:67` | expression | view file |
| 15 | 856 | 802 | function | `Features/Settings/Views/ChatPresetsSettingsView.swift:686` | getter `body` | view `body` |
| 16 | 830 | 797 | function | `Features/AgentMode/ViewModels/AgentModeViewModel.swift:4994` | `installPersistentSessionBindingUpdatingInferredWorkspace(…)` | non-view |
| 17 | 809 | 773 | expression | `Features/AgentMode/ViewModels/AgentModeViewModel.swift:5008` | expression (in #16) | non-view |
| 18 | 773 | 764 | function | `Features/Settings/Views/PermissionsSettingsView.swift:366` | getter `body` | view `body` |
| 19 | 706 | 688 | function | `Features/Settings/Views/CopyPresetsSettingsView.swift:562` | getter `body` | view `body` |
| 20 | 672 | 663 | function | `Features/ContextBuilder/Views/ContextBuilderAgentView.swift:1322` | getter `body` | view `body` |
| 21 | 634 | 635 | function | `Features/AgentMode/Views/Components/AgentSessionRows.swift:939` | getter `hiddenCountChip` | view file |
| 22 | 631 | 536 | function | `Features/AgentMode/Views/Components/AgentEmptyStateViews.swift:418` | getter `body` | view `body` |
| 23 | 629 | 635 | function | `Features/Workspaces/Views/ManageWorkspacesView.swift:211` | getter `duplicateCleanupCallout` | view file |
| 24 | 626 | 628 | expression | `Features/AgentMode/Views/Components/AgentSessionRows.swift:941` | expression (in #21) | view file |
| 25 | 549 | 567 | function | `Features/Settings/Views/APISettingsView.swift:38` | getter `body` | view `body` |

### Frontend time profile (run 1, `RepoPromptApp`)

- **App compile.** The module's llbuild command took 497 s in run 1 and 297 s in run 2. It comprises 47 batch compile jobs (20–193 s wall each), which sum to 3,155 s wall and 1,325 s user in run 1. That is 2.4× oversubscribed, so the table uses instructions.
- **Emit-module job.** It also takes 122 s wall, 93 of its 160 billion instructions in semantic analysis (81 billion declaration checking). It is on the critical path for every dependent.
- **Peak frontend memory:** 1,972 MiB for a batch job, 1,759 MiB for emit-module.

| Phase | Instructions (billions) | Share |
| --- | --- | --- |
| Type checking and semantic analysis | 1,063 | 23% |
| SILGen | 492 | 11% |
| IRGen | 371 | 8% |
| Parse and import resolution | 252 | 5% |
| SIL optimization | 127 | 3% |
| Not separately timed (LLVM code generation and object emission, module loading) | 2,352 | 51% |
| **Total (47 compile jobs)** | **4,657** | |

Where the type-checking time goes, by file (function-body time, 327 s in total):

| File | Seconds | Lines | ms per line |
| --- | --- | --- | --- |
| `Features/AgentMode/ViewModels/AgentModeViewModel.swift` | 14.4 | 21,787 | 0.66 |
| `Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift` | 10.6 | 15,710 | 0.67 |
| `Infrastructure/MCP/MCPConnectionManager.swift` | 10.6 | 16,904 | 0.63 |
| `Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift` | 10.1 | 22,231 | 0.45 |
| `Features/AgentMode/Views/Components/AgentSessionRows.swift` | 9.4 | 1,551 | 6.1 |
| `Features/AgentMode/Views/ContextDrawer/AgentContextDrawerFilesTab.swift` | 9.2 | 714 | 12.9 |
| `App/Views/ContentViewNotificationHandler.swift` | 8.0 | 191 | **41.9** |
| `Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift` | 7.4 | 13,325 | 0.56 |
| `Infrastructure/MCP/ToolOutputFormatter.swift` | 5.5 | 6,792 | 0.81 |
| `Features/AgentMode/Views/Components/AgentSessionsSidebarView.swift` | 5.4 | 1,403 | 3.8 |
| `Features/AgentMode/Views/AgentModeView.swift` | 5.1 | 6,034 | 0.85 |
| `Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift` | 4.8 | 11,396 | 0.42 |

- **Correlation with the §1.3 god files.** The nine largest files hold 20% of the lines (129.8k) and take 21% of the function-body time (69.1 s): 0.53 ms per line against the module's 0.51.
  - Their cost is size, not pathological code: they are expensive because every edit recompiles 9–22k lines in one frontend job, which the S16 splits address.
  - The pathological files are small SwiftUI files at 3.8–42 ms per line, where single `body` getters take 2–9 s. By folder, `Features/AgentMode` takes 109 s (33%), `Infrastructure/MCP` 41 s, `Infrastructure/WorkspaceContext` 26 s, and `Features/Settings` 20 s.

### Link levers

Link command durations from the 12 local checkouts' `build.db` (the latest link of each, mixed load):

| Product | p50 | Range |
| --- | --- | --- |
| `RepoPromptCEPackageTests.xctest` | 29 s | 10.5–81.3 s |
| `RepoPrompt` | 51 s | 12.8–81.4 s |
| `repoprompt-mcp` | 7.5 s | 1.8–19.1 s |

Controlled relinks (tickets `2a199eb0`, `e85a8915`, `d9a49e62`, `0a8e958a`, alternating; load 15–45):
- Only the three links re-ran; 0 files compiled.
- Each job then ran `--filter RepoPromptRegexCoreTests` from the relinked bundle: 7 tests, 0 failures.

| Job | `-no_deduplicate` | Test bundle: command / `ld` / `dsymutil` | `RepoPrompt`: command / `ld` / `dsymutil` | Job exec |
| --- | --- | --- | --- | --- |
| nd1 | yes | 21.7 / 6.1 / 13.7 s | 19.4 / 3.9 / 12.5 s | 34.9 s |
| pl2 | no | 24.7 / 4.2 / 18.1 s | 21.4 / 3.1 / 15.6 s | 40.3 s |
| nd3 | yes | 23.6 / 4.5 / 16.9 s | 20.9 / 4.5 / 14.2 s | 39.2 s |
| pl4 | no | 20.1 / 4.8 / 13.4 s | 17.7 / 3.7 / 10.8 s | 33.3 s |

- **`-no_deduplicate`: no measurable gain.** Test-bundle command mean 22.7 s with the flag vs 22.4 s without; `ld` 5.3 vs 4.5 s, within noise. The bundle still links and runs.
- **`dsymutil` is the link cost.** It is 60–75% of every debug link command: 11–18 s for the test bundle and app at this load, 8.5 s for the app at load about 10, where `ld` took 1.5 s. It peaks at 1.8–2.1 GiB for the test bundle and 1.3–1.7 GiB for the app, and was the largest single process in every sampled job but one. `ld` itself takes 3–6 s and peaks at 1.2–2.0 GiB.
- **Debug dynamic linkage:** deferred, not evaluated (§5.6 singleton-identity rule).

### Per-job peak RSS (new field)

| Job | Ticket | Exec | Peak tree RSS | Processes at peak | Largest process |
| --- | --- | --- | --- | --- | --- |
| App build, run 1 (dependencies and app) | `569c44ed` | 638 s | 4,838 MiB | 54 | `dsymutil` 1,922 MiB |
| Test build + link + filter | `9d37d757` | 171 s | 5,069 MiB | 40 | `dsymutil` 2,126 MiB |
| Relink + filter (4 jobs) | `2a199eb0`… | 33–40 s | 3,032–3,350 MiB | 6–10 | `ld` or `dsymutil` 1,854–2,043 MiB |
| App build, run 2 | `c3a1636c` | 516 s | 5,140 MiB | 63 | `dsymutil` 1,804 MiB |

These agree with P0.3's sampler: 3,856 MiB for an aggregate interface edit. For admission v2 (P1.3), compile fan-out drives the tree peak, but a single link or dSYM step alone holds about 2 GiB.

### Recommendations

1. **Type-check ratchet, proposed and not gated.**
   - Track four counts for `RepoPromptApp`:

     | Metric | Baseline |
     | --- | --- |
     | `app_long_function_bodies_1000ms` | 10 |
     | `app_long_expressions_500ms` | 6 |
     | `app_long_function_bodies_500ms` | 24 |
     | `app_long_expressions_200ms` | 11 |

   - Take the maximum of the two runs as the baseline.
   - The first two were identical in both runs and are gate-ready. The ≥ 500 ms / ≥ 200 ms pair moved by up to 3 and stays tracked.
   - The ≥ 200 ms function count (92–104) is a report-only indicator.
   - Like the index metrics, these need a compile, so they cannot run in `make guardrails`. Gate them when a build-producing CI job exists (P1.4). Until then, record them per slice with `conductor swift-build --product RepoPrompt --scratch <label> --swiftc-flag=-Xfrontend --swiftc-flag=-warn-long-function-bodies=500 --swiftc-flag=-Xfrontend --swiftc-flag=-warn-long-expression-type-checking=200`.
   - The build-produced limits now live in [`build-ratchets.json`](build-ratchets.json), not `ratchets.json` (which holds source metrics). The CI warning classifier deduplicates by normalized app source path, line, column, and warning kind, retaining the maximum observed duration; repeated compiler emissions with different timings must not consume multiple slots. Timing is report-only on pull requests and enforced on pushes to `main`; compilation, import checking, Swift Testing guard, and test artifacts remain blocking.
   - **First-party warning ratchet (#519, 2026-11-02).** The same clean CI build also counts repository-owned source warnings under `Sources/`, `Tests/`, and `Packages/` (dependency checkouts under `.build` and `Vendor/` excluded). Like the timing classifier, it counts each diagnostic once by path, line, column, and message after stripping color and OSC 8 link escapes, because the compiler re-emits a diagnostic for every frontend job that type-checks the file. The flag-induced type-check timing warnings are excluded. The ceiling is `warnings.first_party_unique` in [`build-ratchets.json`](build-ratchets.json), enforced under `TYPECHECK_RATCHET_ENFORCE=1` like the timing budget. The report lists the 10 files with the most warnings, and `typecheck-timing.json` records every unique warning. Lower the ceiling only after a verified cleanup.
     - Baseline: `./conductor ci-build-tests` (clean, ticket `b078497e`, HEAD `88a23062e`, Swift 6.4) reported **430** unique first-party warnings in 152 files, from 494 located emissions in the stored log. That compares with the 15,484 raw emissions recorded above. The 15,484 came from an uncoordinated focused-test log with batch-mode repeats and dependency output.
     - Largest remaining bucket: 104 single-argument MCP `.text(...)` calls (mostly `Infrastructure/MCP/ToolOutputFormatter.swift`) still resolve to the deprecated `text(_:metadata:)`. Only the explicit `metadata:` call sites were migrated. Next come redundant `await` (50), deprecated `SecKeychain` APIs (20), and main-actor isolation (17). Bulk cleanup is still open under #519.
2. **Cheapest type-check wins.** Split the four bodies over 4 s: `AgentContextDrawerFilesTab.body`, `SettingsNotificationHandler.body(content:)`, `AgentSessionRow.body`, and `AgentModeSessionsListView.body`. Together they cost 27.5 s of type checking per full compile and sit in batch jobs on the app's critical path. Pure view refactors: behavior-preserving, out of scope here.
3. **Do not adopt `-no_deduplicate`** for debug test bundles.
4. **Evaluate skipping dSYM generation for local debug links** (follow-up; not adopted).
   - LLDB can read DWARF from the object files through the debug map, so a local test or debug-app link may not need `dsymutil`. The driver has no switch for this; SwiftPM passes `-g` to the link.
   - Parity checks before adoption: breakpoints and backtraces in the test bundle and debug app, crash symbolication, and `package_app.sh`. Release packaging keeps its dSYM.
5. **Measurement lane.** Do not schedule `-debug-time-function-bodies` over the whole graph: run 1's log was 1.19 GB, with 2.2M lines including dependencies. The two `-warn-long-*` flags are enough for the ratchet. Per-file profiling stays on-demand.

**Not done here:**
- P0.1 proposed measuring a lower-volume diagnostic style for local test builds; it is not measured and stays open.
- SwiftPM product builds print `Build of product '…' complete!`, which the P0.1 `buildCompleted` pattern does not match. `swift-build` jobs therefore lack `buildReportedSeconds` (P1.3 follow-up).

**Validation.**
- `make guardrails` passes, with modularization ratchets ok.
- `make conductor-selftest`: every suite passes except `test_local_production_installer.py`.
  - It had 4 of 18 errors, each a 15 s `install_local_production.sh` subprocess timeout (the known load-sensitive flake; this change does not touch the installer).
  - `test_security_inventory.py`, the suite after it, passes standalone.
- Live checks:
  - measurement flags reached SwiftPM (the job log shows `swift build … --scratch-path …/.build/measure/p05-typecheck -Xswiftc …`);
  - relink-only jobs compiled nothing;
  - `phaseTimings.peakRss` appeared in live status and in `.timing.json`.
- **Cleanup.**
  - The measurement scratch `.build/measure/p05-typecheck` (9.1 GB) and the throwaway scripts were deleted.
  - Two conductor job logs stay under the daemon's retention: `569c44ed` at 1.19 GB (run 1, `-debug-time-function-bodies`) and `9d37d757` at 171 MB.

## P0.6 — compatibility inventory (2026-09-29)

**Question.** Which runtime identities can a module move change *silently*? A move changes only what the compiler or runtime derives from the owning module or target:
- the module prefix in reflected type names, in bridged `NSError` domains (`<Module>.<Type>`), in `#fileID`, and in Swift class runtime names (`_TtC13RepoPromptApp…`);
- which bundle `Bundle.module` and `Bundle(for:)` resolve;
- which process answers a `Bundle.main` or `UserDefaults.standard` lookup, once code moves into a target that `repoprompt-mcp` also links.

Literal strings (raw values, Codable keys, notification names, tool names, identifiers) cannot change in a move. They change only when someone edits them, and principle 9 keeps edits out of move commits. The inventory below therefore classifies literal identities as module-invariant, and adds goldens only where an identity is derived, or is persisted or cross-process and was not yet pinned.

Scan at `7f10a4f5` (first-party `Sources`, `Tests`, `Packages`; `Vendor` excluded):

```bash
grep -rn --include='*.swift' -E 'String\(reflecting:|String\(describing: *type\(of|\\\(type\(of:|#fileID' Sources
grep -rn --include='*.swift' -E 'NSKeyed|NSStringFromClass|NSClassFromString|_typeName\(|@objc\(' Sources Tests
grep -rn --include='*.swift' -E 'Bundle\.(main|module)|Bundle\(for:|NSImage\(named:' Sources
```

### Type-name-dependent strings

| Site | Kind | Stable? | Covered by |
| --- | --- | --- | --- |
| `automaticSelectionIssuePrecedes` (`WorkspaceCodemapAutomaticSelectionModels.swift`), used by `WorkspaceFileContextStore`, `WorkspaceSelectionMutationService`, and the result's `issues`/coverage | `String(reflecting:)` sort key over `WorkspaceCodemapAutomaticSelectionIssue`. The order is observable in automatic-selection results; it is not persisted | **Order must be stable.** It is module-invariant by construction: both sides of every comparison carry the same type prefix at the same position, so the first difference is always a case name or a payload value | **New:** `ModularizationCompatibilityGoldenTests.testAutomaticSelectionIssueOrderIsPinned`. It also pins that integer payloads sort as text (`10` before `9`), which any explicit-comparator refactor must preserve |
| `debugReflectionIssueSortKey` (`WorkspaceCodemapPresentationCoordinator.swift`) | Same pattern for presentation issues | Module-invariant by the same argument | Not separately pinned. Its comment says automatic-selection uses "explicit typed comparators"; that is inaccurate (it also uses reflection). Left unchanged |
| `String(reflecting:)` of errors or error types: 15 sites in 10 files (`AppDomainRuntimeComposition`, `AppDelegate`, `RepoPromptApp`, `AppDomainRuntimeRegistration` ×2, `OracleReviewPackagingDiagnostics`, `AgentSelectedFilesModelCoordinator`, `SearchMatch`, `MCPAppToolCatalogRegistration` ×4, `MCPServerViewModel` ×2, `ACPAgentSessionController`) | Log text, diagnostic fields, `RegistrationStatus.failed` and `windowToolRegistrationFailureDescription` UI diagnostics. `SearchMatch`'s `PatternErrorInfo.errorType` is `Codable`, but `SearchResults` is never encoded and the field is never read | Diagnostics only; may change | — |
| `String(reflecting:)` of `String` values: `AgentSessionHandoffPrompt` (title quoting), `PCRE2Error` (pattern) | Escaped string literal | No type name in the output; module-invariant | — |
| Metatype interpolation and `String(describing: type(of:))`: 10 sites in 4 files (`MCPConnectionManager+DebugSparkleDiagnostics` ×2, `SparkleUpdateManager`, `FileSystemService+FSEvents`, `CodexNativeSessionController` ×6) | Debug logs and `assertionFailure` messages | Diagnostics only | — |
| `#fileID`: 10 sites in 4 files (`GlobalSettingsManager` ×6, `WindowSettingsManager` ×2, `AgentTabSession`, `CodeMapPCRE2Regex`) | Settings-write diagnostic attribution and assertion locations; the value embeds the module name | Diagnostics only | — |
| `NSClassFromString("XCTestCase")` (`AppLaunchConfiguration`) | Objective-C class lookup | Stable: Objective-C names carry no module | **New guardrail** allows only this literal |
| `NSKeyedArchiver`/`Unarchiver`, `NSStringFromClass`, `_typeName` | — | 0 sites. The plan's "`NSKeyedArchiver` (1 file)" is not reproduced at this commit | **New guardrail** forbids them in first-party `Sources` |
| `@objc(windowDidOrderOffScreen:)` (`InterceptingWindowDelegateProxy`, plus its test double) | Explicit selector | Module-invariant | `InterceptingWindowDelegateProxyTests` (`NSSelectorFromString` literal) |
| Bridged `NSError` domains | A Swift error bridges with domain `<Module>.<Type>` | Compared only against `com.apple.osascript` (`CLIPathInstaller`). `DiffGenerationError` declares an explicit `RepoPrompt.DiffGenerationError` domain, which survived its earlier move into DomainRuntime. `WorkspaceManagerViewModel` builds `NSError`s with literal domains | New comparisons must use an explicit `CustomNSError.errorDomain` (checklist) |
| Module-qualified names in code: `RepoPromptApp.Tool` (`MCPReadMutationPathContractTests`), 20+ `typealias X = RepoPromptDomainRuntime.X` forwarding aliases, two `"RepoPromptApp.init …"` log strings | Compile-time disambiguation and log text | A move breaks the build loudly; nothing silent | — |
| Swift class runtime names in AppKit persistence | — | None. No `restorationClass`, keyed archives, `@SceneStorage`, or value-typed `WindowGroup(for:)`; `NSPrincipalClass` is `NSApplication`; the window autosave name and pasteboard types are literals. No logger category or label is derived from a type | — |
| Sentry crash and hang grouping | Symbolicated frames carry module names | Telemetry grouping will shift after moves; accepted | — |

### Bundle lookups

| Site | Resource | Effect of a move | Covered by |
| --- | --- | --- | --- |
| `Bundle.main`: 34 references in 21 files, all under `Sources/RepoPrompt` (`RepoPromptApp`) | Info.plist keys: `WindowState`, `SparkleUpdateManager` (versions, `SUPublicEDKey`), `MCPConnectionManager+DebugSparkleDiagnostics` (`SUFeedURL`, versions), `RuntimeCodeSigningPolicy` (signing-mode and debug-storage keys), `CodexAppServerClient` and `ACPAgentSessionController` (client version), `SentryTelemetryBootstrap` (`RepoPromptSentryDSN`), `BootstrapSocketConnectionManager` (name, version). Bundle identifier: Logger subsystems in `AppCommandLifetime`, `AgentSessionLifecycleAuthority`, `WorkspaceManagerViewModel`, `WorkspaceAgentAdmissionCoordinator`, `AgentSessionLinkCatalogDiagnostics`; `NotificationSettingsView`; `BundleIdentityDefaultsMigration`. Bundle and resources URL: `AppLaunchConfiguration` (XCTest detection), `UserNotificationCenterClient`, `CodexRuntimeAuthority` (bundled Codex). Auxiliary executable `repoprompt-mcp`: `ServerController`, `CLISymlinkManager`, `CLIPathInstaller` | None while the code stays in a target statically linked into the app. Moving it into a target that the CLI links (`RepoPromptShared`, `RepoPromptDomainRuntime`, `RepoPromptMCPCore`, `RepoPromptMCP`, `RepoPromptCodeMapCore`, `RepoPromptWorkspaceCore`, `RepoPromptRegexCore`) changes which process answers | **New guardrail:** `Bundle.main` and `NSImage(named:)` only under allowlisted app-only roots (today `Sources/RepoPrompt/`) |
| `NSImage(named: "RepoPromptLogoNoBg_Monochrome")` (`MCPBackgroundModeCoordinator`) | Implicit main-bundle image | No such asset is packaged, so the lookup returns `nil` and the code falls back. Pre-existing; unchanged | Same guardrail |
| `Bundle.module`, `Bundle(for:)` in production | — | 0 sites. The only SwiftPM `resources:` belong to the `RepoPromptCodeMapCoreTests` test target (Fixtures, Goldens). `package_app.sh` copies build-directory bundles, but arbitrary first-party target bundle lookup after packaging is not validated | **New guardrail** rejects both pending validation |
| `AppResources/` copied to `Contents/Resources` by `package_app.sh` | `AppIcon.icns` (through Info.plist); `Audio/notificationDing.mp3` (no code reference found) | Unaffected by Swift moves | `package_app.sh` |
| KeyboardShortcuts `Bundle.module` | Third-party resources | Unaffected; patched by `patch_keyboard_shortcuts_resource_lookup.sh` | Packaging |

### Persisted and cross-process identities

| Identity | Stable? | Covered by |
| --- | --- | --- |
| MCP tool names, descriptions, input schemas, annotations | Literal; persisted by clients | `DirectHeadlessCompositionTests.testCanonicalDefinitionsMatchReadableGeneratedReviewSnapshot` byte-compares `docs/spec/mcp-domain-canonical-tool-definitions.generated.json`; `MCPDomainStandaloneCompositionTests` pins the 28-tool name set; guardrail M3 checks |
| MCP tool and catalog fingerprints (`MCPDomainToolFingerprint`, `catalogFingerprint`) | SHA-256 over the pinned inputs above; no type names | Transitively, by the snapshot |
| CodeMap artifact bytes | Persisted | `Tests/RepoPromptCodeMapCoreTests/Goldens`, `CodeMapSyntaxArtifactTests` |
| Settings document: `currentSchemaVersion` 10, per-feature minimums, lineage | Persisted | `ModelRouterSettingsPersistenceTests`, `NotificationSettingsPersistenceTests` (literal 10), `GlobalSettingsSchemaRecoveryTests`, `GlobalSettingsOwnershipTests`, `AppSettingsMCPServiceAgentModeSettingsTests`, frozen v2/v4 codecs |
| Settings document root keys and the 11 `scalarPreferences` group keys | Persisted; synthesized Codable keys are module-invariant, but S7 splits these facets across features | **New:** `testGlobalSettingsDocumentPersistedKeysArePinned`. Field keys inside groups stay spot-checked by the settings suites |
| Darwin notification `com.repoprompt.fontScaleDidChange` (`FontScaleManager`) | Cross-process between app instances | **New:** `testFontScaleDarwinNotificationNameIsPinned`. The constant went from `private` to internal so the test can read it; the value is unchanged |
| `Notification.Name`: 61 definitions in 12 files | Literal; in-process `NotificationCenter` only | Not pinned (neither persisted nor cross-process) |
| `UNNotification` action and category identifiers, payload route keys | Literal; delivered notifications outlive a launch | `AppNotificationPayloadTests` (identifier formats, route v1 keys) |
| Secure-storage account names | Persisted in Keychain | `SecureStorageAccountCatalogTests` |
| `UserDefaults` keys: about 98 distinct literals, scattered | Literal; module-invariant | Not pinned. Three resolve against the calling process's defaults domain across the app/CLI boundary: `GlobalCustomStorageURL` (written and read by the app, also read by `DirectHeadlessRuntimeConfiguration` in MCPCore), `enableSocketDebugLog` (CLI), `enableMCPResponseDeliveryTrace` (`RepoPromptShared`, both processes). Pinning them needs a key-constant refactor; defer to S7 |

### Behavior-preserving changes

- `FontScaleManager.externalChangeNotificationRawName`: `private static let` → `static let`. Access only; no value or behavior change.
- No production refactor of the reflection sort key. It is already module-invariant, and the golden pins its order.

### Slice checklist (referenced by plan §7.2)

For every slice that moves code, before the move PR merges:

1. `make guardrails` passes, including section 9 (runtime identity): no production `resources:`, no `Bundle.module` or `Bundle(for:)`, `Bundle.main` and `NSImage(named:)` only under allowlisted app-only roots, and no runtime type-name APIs. A slice that creates an app-only target holding `Bundle.main` code adds its root to `bundle_main_allowed_roots` in the same PR. CLI-linked targets are never allowlisted.
2. `conductor test --filter ModularizationCompatibilityGoldenTests` passes, plus the owning suites in the tables above for every moved site. Each golden moves with its type, and its literals stay unchanged.
3. Rerun the scan commands on the moved files. Any new sort, equality, or persistence use of `String(reflecting:)`, `String(describing:)` of a type, or `#fileID` needs a golden or an explicit key.
4. A moved Swift error whose `NSError` domain or code is compared or persisted declares an explicit `CustomNSError.errorDomain`.
5. Moving code that reads `Bundle.main` or `UserDefaults.standard` into a CLI-linked target is a semantic change and gets its own PR.
6. Update this inventory's rows for the moved sites.

**Validation.**
- `conductor test --filter ModularizationCompatibilityGoldenTests`: 3 tests executed, 0 failures (ticket `9e3b306e`; rerun after formatting, ticket `46e70b79`).
- `make guardrails` passes, including the new section 9, with modularization ratchets ok.
  - The new checks were exercised against negative inputs: a production `resources:` block, `Bundle(for:)`, and `Bundle.module`.
  - The first draft matched `groupCarrierBundle(for:)` in `RepoPromptMCPCore`; the patterns are now anchored to an identifier boundary.
- Tracked metrics grew (not gated): `app_target_swift_lines` 648,098 → 648,100 (the constant's doc comment) and `tests_testable_import_app_files` 319 → 320 (the new golden suite, which tests app-owned types). Baselines unchanged.
- `make conductor-selftest`: every suite passes except `test_local_production_installer.py`, which hit the known load-sensitive flake (6 of 18 errors, each a 15 s installer subprocess timeout; this change does not touch the installer). `test_security_inventory.py`, the suite after it, passes standalone.
- SwiftFormat `--lint` and SwiftLint `--strict` are clean on the two changed Swift files.

## PR 2 foundations A1–A5 (2026-09-30)

### Ownership and move evidence

| Slice | Former app family | New production owner | Owning tests |
| --- | --- | --- | --- |
| A1 | `Infrastructure/Concurrency`, `Infrastructure/Utilities`, `Infrastructure/Networking`, `Infrastructure/SyntaxParsing`, selected notification names | `RepoPromptFoundation` | `RepoPromptFoundationTests` |
| A2 | diagnostic event and sink contracts; concrete recorders remain in `RepoPromptApp` | `RepoPromptInstrumentation` | `RepoPromptInstrumentationTests` |
| A3 | `Infrastructure/Regex` adapters | `RepoPromptRegexCore` | `RepoPromptRegexCoreTests` |
| A4 | `Infrastructure/Process` including `CLI/` | `RepoPromptProcess` | `RepoPromptProcessTests` |
| A5 | `Infrastructure/Security` | `RepoPromptSecureStorage` (app-only) | `RepoPromptSecureStorageTests` |

The mechanical move commit `d681cbbd` is reproducibly audited with
`python3 Scripts/modularization_move_audit.py --base 3aed2da3 --head d681cbbd`:
**PASS, 76 moves, 0 violations**. The complete old-to-new path manifest is
below. All 76 pairs are R100; the audit command verifies their normalized
SHA-256 equality. The separate
`8ca85819` checkpoint contains the necessary target access and import changes,
including test retargets, rather than hiding them in the byte-identical move.
The subsequent A2 instrumentation checkpoints are `c93500a3`, `3775cd3e`,
`864e23b4`, `abe9bad3`, and `40205042`.

### Byte-identical move manifest

R100 `Sources/RepoPrompt/Infrastructure/Process/CLI/CLIPathInstaller.swift` → `Sources/RepoPrompt/App/CLI/CLIPathInstaller.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLI/CLISymlinkManager.swift` → `Sources/RepoPrompt/App/CLI/CLISymlinkManager.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/Shortcuts.swift` → `Sources/RepoPrompt/App/Shortcuts.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/ErrorExtensions.swift` → `Sources/RepoPrompt/Infrastructure/AI/ErrorExtensions.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/AsyncMutex.swift` → `Sources/RepoPromptFoundation/Concurrency/AsyncMutex.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/AsyncScope.swift` → `Sources/RepoPromptFoundation/Concurrency/AsyncScope.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/BoundedOrderedConcurrentMap.swift` → `Sources/RepoPromptFoundation/Concurrency/BoundedOrderedConcurrentMap.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/CancellableProbe.swift` → `Sources/RepoPromptFoundation/Concurrency/CancellableProbe.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/SameThreadReentryCheckedLock.swift` → `Sources/RepoPromptFoundation/Concurrency/SameThreadReentryCheckedLock.swift`
R100 `Sources/RepoPrompt/Infrastructure/Concurrency/TaskSemaphore.swift` → `Sources/RepoPromptFoundation/Concurrency/TaskSemaphore.swift`
R100 `Sources/RepoPrompt/Infrastructure/Networking/HTTPClient.swift` → `Sources/RepoPromptFoundation/Networking/HTTPClient.swift`
R100 `Sources/RepoPrompt/Infrastructure/Networking/HTTPDecoding.swift` → `Sources/RepoPromptFoundation/Networking/HTTPDecoding.swift`
R100 `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/LineRange.swift` → `Sources/RepoPromptFoundation/Slices/LineRange.swift`
R100 `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRangeMath.swift` → `Sources/RepoPromptFoundation/Slices/SliceRangeMath.swift`
R100 `Sources/RepoPrompt/Infrastructure/SyntaxParsing/SyntaxManager.swift` → `Sources/RepoPromptFoundation/SyntaxParsing/SyntaxManager.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/CheckoutPathIdentity.swift` → `Sources/RepoPromptFoundation/Utilities/CheckoutPathIdentity.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/Collections/BoundedArray.swift` → `Sources/RepoPromptFoundation/Utilities/Collections/BoundedArray.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/Collections/PersistentHashMap.swift` → `Sources/RepoPromptFoundation/Utilities/Collections/PersistentHashMap.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/FriendlyErrorRepresentable.swift` → `Sources/RepoPromptFoundation/Utilities/FriendlyErrorRepresentable.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/JSONDictionaryHelpers.swift` → `Sources/RepoPromptFoundation/Utilities/JSONDictionaryHelpers.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/RelativePath.swift` → `Sources/RepoPromptFoundation/Utilities/RelativePath.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/SequenceExtension.swift` → `Sources/RepoPromptFoundation/Utilities/SequenceExtension.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/String+Sanitize.swift` → `Sources/RepoPromptFoundation/Utilities/String+Sanitize.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/String+Slug.swift` → `Sources/RepoPromptFoundation/Utilities/String+Slug.swift`
R100 `Sources/RepoPrompt/Infrastructure/Utilities/WorkspacePathNormalizations.swift` → `Sources/RepoPromptFoundation/Utilities/WorkspacePathNormalizations.swift`
R100 `Sources/RepoPrompt/Infrastructure/Telemetry/SentryTelemetryModel.swift` → `Sources/RepoPromptInstrumentation/SentryTelemetryModel.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLI/ManagedCLIPathPolicy.swift` → `Sources/RepoPromptProcess/CLI/ManagedCLIPathPolicy.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIEnvironmentCache.swift` → `Sources/RepoPromptProcess/CLIEnvironmentCache.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLILaunchProfile.swift` → `Sources/RepoPromptProcess/CLILaunchProfile.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLINativePathDefaults.swift` → `Sources/RepoPromptProcess/CLINativePathDefaults.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIOutputFormat.swift` → `Sources/RepoPromptProcess/CLIOutputFormat.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIProcessConfiguration+AdditionalPaths.swift` → `Sources/RepoPromptProcess/CLIProcessConfiguration+AdditionalPaths.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIProcessConfiguration.swift` → `Sources/RepoPromptProcess/CLIProcessConfiguration.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIProcessLogCollector.swift` → `Sources/RepoPromptProcess/CLIProcessLogCollector.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CLIProcessRunner.swift` → `Sources/RepoPromptProcess/CLIProcessRunner.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ChildProcessExitObserver.swift` → `Sources/RepoPromptProcess/ChildProcessExitObserver.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/CommandPathResolver.swift` → `Sources/RepoPromptProcess/CommandPathResolver.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ExecutableFileIdentity.swift` → `Sources/RepoPromptProcess/ExecutableFileIdentity.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/FDWriteSupport.swift` → `Sources/RepoPromptProcess/FDWriteSupport.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/FileHandleChunkChannel.swift` → `Sources/RepoPromptProcess/FileHandleChunkChannel.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessDebugLogging.swift` → `Sources/RepoPromptProcess/ProcessDebugLogging.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessEnvironmentBuilder.swift` → `Sources/RepoPromptProcess/ProcessEnvironmentBuilder.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessEnvironmentSanitizer.swift` → `Sources/RepoPromptProcess/ProcessEnvironmentSanitizer.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessLaunchContext.swift` → `Sources/RepoPromptProcess/ProcessLaunchContext.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift` → `Sources/RepoPromptProcess/ProcessLauncher.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessRegistry.swift` → `Sources/RepoPromptProcess/ProcessRegistry.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessStreamFraming.swift` → `Sources/RepoPromptProcess/ProcessStreamFraming.swift`
R100 `Sources/RepoPrompt/Infrastructure/Process/ProcessTermination.swift` → `Sources/RepoPromptProcess/ProcessTermination.swift`
R100 `Sources/RepoPrompt/Infrastructure/Regex/PCRE2RegexAdapter.swift` → `Sources/RepoPromptRegexCore/PCRE2RegexAdapter.swift`
R100 `Sources/RepoPrompt/Infrastructure/Regex/PCRE2SearchFastPlans.swift` → `Sources/RepoPromptRegexCore/PCRE2SearchFastPlans.swift`
R100 `Sources/RepoPrompt/Infrastructure/Regex/RegexToolkit.swift` → `Sources/RepoPromptRegexCore/RegexToolkit.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/BundleIdentityDefaultsMigration.swift` → `Sources/RepoPromptSecureStorage/BundleIdentityDefaultsMigration.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/EphemeralSecureKeyValueStore.swift` → `Sources/RepoPromptSecureStorage/EphemeralSecureKeyValueStore.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/IdentityTransitionDiagnostics.swift` → `Sources/RepoPromptSecureStorage/IdentityTransitionDiagnostics.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/KeyManager.swift` → `Sources/RepoPromptSecureStorage/KeyManager.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/KeychainService.swift` → `Sources/RepoPromptSecureStorage/KeychainService.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/LocalSigningIdentityRegistry.swift` → `Sources/RepoPromptSecureStorage/LocalSigningIdentityRegistry.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/RuntimeCodeSigningDetector.swift` → `Sources/RepoPromptSecureStorage/RuntimeCodeSigningDetector.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/RuntimeCodeSigningPolicy.swift` → `Sources/RepoPromptSecureStorage/RuntimeCodeSigningPolicy.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecureKeyService.swift` → `Sources/RepoPromptSecureStorage/SecureKeyService.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecureKeyValueStorageBackend.swift` → `Sources/RepoPromptSecureStorage/SecureKeyValueStorageBackend.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecureStorageAccountCatalog.swift` → `Sources/RepoPromptSecureStorage/SecureStorageAccountCatalog.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecureStorageIdentityMigration.swift` → `Sources/RepoPromptSecureStorage/SecureStorageIdentityMigration.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecureStorageRepairService.swift` → `Sources/RepoPromptSecureStorage/SecureStorageRepairService.swift`
R100 `Sources/RepoPrompt/Infrastructure/Security/SecurityObfuscation.swift` → `Sources/RepoPromptSecureStorage/SecurityObfuscation.swift`
R100 `Tests/RepoPromptTests/Infrastructure/Concurrency/AsyncMutexCancellationHandoffTests.swift` → `Tests/RepoPromptFoundationTests/AsyncMutexCancellationHandoffTests.swift`
R100 `Tests/RepoPromptTests/AgentMode/SessionLinks/AgentSessionLinkDiagnosticsRedactionGuardTests.swift` → `Tests/RepoPromptInstrumentationTests/AgentSessionLinkDiagnosticsRedactionGuardTests.swift`
R100 `Tests/RepoPromptTests/AI/CLIProcessRunnerCancellationTests.swift` → `Tests/RepoPromptProcessTests/CLIProcessRunnerCancellationTests.swift`
R100 `Tests/RepoPromptTests/Infrastructure/Process/ExecutableFileIdentityTests.swift` → `Tests/RepoPromptProcessTests/ExecutableFileIdentityTests.swift`
R100 `Tests/RepoPromptTests/Services/ProcessLauncherSignalDispositionTests.swift` → `Tests/RepoPromptProcessTests/ProcessLauncherSignalDispositionTests.swift`
R100 `Tests/RepoPromptTests/Security/DebugSecureStorageRuntimePolicyTests.swift` → `Tests/RepoPromptSecureStorageTests/DebugSecureStorageRuntimePolicyTests.swift`
R100 `Tests/RepoPromptTests/Security/KeychainServiceTests.swift` → `Tests/RepoPromptSecureStorageTests/KeychainServiceTests.swift`
R100 `Tests/RepoPromptTests/Security/LocalSigningIdentityRegistryTests.swift` → `Tests/RepoPromptSecureStorageTests/LocalSigningIdentityRegistryTests.swift`
R100 `Tests/RepoPromptTests/Security/SecureStorageAccountCatalogTests.swift` → `Tests/RepoPromptSecureStorageTests/SecureStorageAccountCatalogTests.swift`
R100 `Tests/RepoPromptTests/Security/SecureStorageIdentityMigrationTests.swift` → `Tests/RepoPromptSecureStorageTests/SecureStorageIdentityMigrationTests.swift`
R100 `Tests/RepoPromptTests/Security/SecureStorageRepairServiceTests.swift` → `Tests/RepoPromptSecureStorageTests/SecureStorageRepairServiceTests.swift`

### P0.6 compatibility inventory for moved sites

1. `RepoPromptSecureStorage` is explicitly app-only and is in
   `bundle_main_allowed_roots`; no CLI-linked target is allowlisted.
2. The moved-file identity scans find one `String(reflecting:)` in
   `RepoPromptRegexCore/SwiftPCRE2/PCRE2Error.swift`, applied to a **String pattern**
   for diagnostic quoting, not to a type or a persisted/sorted key. They find no
   `#fileID`, metatype description, keyed-archive, runtime class-name, or Objective-C
   selector site in the five target trees and their owning test trees.
3. Three `Bundle.main` reads remain in `RepoPromptSecureStorage`:
   `BundleIdentityDefaultsMigration` and `RuntimeCodeSigningPolicy` (two reads).
   `RepoPromptProcess` contains neither `Bundle.main` nor
   `UserDefaults.standard`; no CLI-linked process-identity semantics changed.
4. The moved Swift error types have no `NSError` domain/code comparison or
   persistence site in the new target trees or their owning tests. Secure-storage
   `decision.domain` is its own typed enum, not an `NSError` domain. No new
   `CustomNSError.errorDomain` is needed by this move.
5. `SecureStorageAccountCatalogTests` continues to pin persisted Keychain
   account names. The existing `ModularizationCompatibilityGoldenTests` pins
   the identity-sensitive values catalogued above; neither the moved literal
   values nor those goldens were edited by the pure move.

The startup phase-event seam carries only closed enums, identifiers, and flags;
its app adapter delegates to the pre-existing recorder. The module supplies a
no-op sink so an uncomposed consumer cannot start logging or change policy.

### Local validation evidence

| Check | Conductor ticket | Result |
| --- | --- | --- |
| `make dev-swift-build PRODUCT=all` | `e0145fa8` | Completed successfully; app and MCP products, 4m 9s execution |
| `./conductor test --module RepoPromptFoundationTests` | `8ae537a3` | Completed successfully; 5 tests, 0 failures |
| `./conductor test --module RepoPromptInstrumentationTests` | `eb7376c3` | Completed successfully; 4 tests, 0 failures |
| `./conductor test --module RepoPromptRegexCoreTests` | `78f23d39` | Completed successfully; 7 tests, 0 failures |
| `./conductor test --module RepoPromptProcessTests` | `fcd86898` | Completed successfully; 13 tests, 0 failures |
| `./conductor test --module RepoPromptSecureStorageTests` | `c925fd8e` | Completed successfully; 73 tests, 0 failures |
| `./conductor test --filter ModularizationCompatibilityGoldenTests` | `c066843c` | Completed successfully; 3 tests, 0 failures |
| `make dev-lint` after the app-test import repair | `4e227173` | Completed successfully; 0 files require formatting; SwiftLint strict passed |
| `make guardrails` | — | Exit 0, source layout and modularization ratchets passed (the initial sandboxed attempt failed in SwiftPM manifest sandboxing; rerun with process access passed) |

The first full-suite ticket `41e27478` failed at compilation because one app
regression test lacked `import RepoPromptInstrumentation`; commit `4662c7f1`
adds that direct import. The second full-suite ticket `eae6a0de` compiled and
ran 3,224 app tests, but one timing-sensitive `ContentReadCancellationTests`
case timed out waiting for overwrite reconciliation. Its owner source and test
body have no behavioral diff in this slice; focused class ticket `5cdd9078`
then passed all 36 cases, including the timed-out case. The final full
`make dev-test` ticket `b35e427e` **completed successfully**: 3,224 app tests,
2 skipped, 0 failures, plus the other test products; 11m 6s execution.
These timings are post-move observations only, not a before/after performance
claim.

## PR 3 WorkspaceContext prep (2026-10-01)

This in-place C1/C2 slice removes WorkspaceContext, Search, and CodeMap's outbound references to Features, view models, and MCP implementation files. S8 now uses file search projections and feature-side path adapters; S9 stores selection values in WorkspaceContext and receives neutral workspace/tab values from the workspace manager; S17 uses neutral prompt/workspace values and a search-readiness contract. Startup and debug diagnostics use injected recorders from `WindowStateComposition`, following the PR 2 instrumentation contract pattern. The read-only, root-scoped `WorkspaceContextRootSnapshot` retains catalog and lifetime leases and has a Sendable/currentness contract test. No files or package targets move in this PR.

Compiler-index readiness baseline on 101 files: 55 outbound target files, 168 outbound file edges, 1,040 symbols. The final index and validation tickets are recorded in `/tmp/rpce-pr-reviews/pr3-impl.md` for this worktree. FileSystem/VCS and other Infrastructure remain for subsequent milestones.


## #1112 restoration-presentation test ownership exception — 2026-10-02

Atila approved one increase of `tests_testable_import_app_files`, from 333 to
334, for exactly
`Tests/RepoPromptTests/AgentMode/Transcript/AgentTranscriptRestorationPresentationTests.swift`.
It owns the classifier, persisted-restoration lifecycle, and snapshot-publication
suites for one cohesive restoration-presentation contract. The nearest existing
transcript-policy tests own repaint/remount behavior; appending the new contract
there solely to satisfy the file count would harm ownership and navigation.
Existing title and sidebar suites remain in their owning test files.

This exception does not raise the app-source line baseline or its 2,000-line
headroom, change other ratchets, or authorize wider production visibility.
The approval was relayed by Atila's delegated #1112 overseer during implementation.
Guardrails must still pass on the integrated change.

2026-10-09: Atila reaffirmed the same single-file exception for `Tests/RepoPromptTests/AgentMode/Transcript/AgentTranscriptRestorationPresentationTests.swift` against main’s lowered baseline (327→328); the exception was not widened.


## PR 4 MCP server prep — bounded source handoff (2026-10-02)

Base/current fetched origin/main at start: `61ab8b285fa5a9281587ec9712404bfe7b5c528f`;
clean isolated `modularization/pr4-mcp-server-seams`, zero ahead/behind at fetch.
No fast-forward was needed. Published claims and frozen interfaces are in
`/tmp/rpce-pr-reviews/pr4-{claims,interfaces}.md` (scratch coordination artifacts).

### Split map and preserved owners

- **S5 values:** single approved `MCPInvocationContext.swift`; nested compatibility
  aliases remain in existing VM extensions. Snapshot defaults, mutable value-copy
  behavior, revision/generation values, root projection and lifetime equality are
  unchanged. Live MainActor capture/validate and synchronous atomic
  `performIfGenerationCurrent` remain in the existing main VM extension.
- **S6 app ingress:** manager captures connection/tool/invocation/window evidence;
  TaskLocal bridges only the unchanged DomainRuntime args-only binding. Binder/VM
  synchronously capture before suspension, pass the same explicit provider packet,
  and revalidate exact connection/catalog/window ownership at the existing gates.
  Oracle, control, AskUser and ContextBuilder receive context or injected app
  purpose/progress callbacks. A missing or mismatched packet throws; DEBUG uses an
  injected redacted existing adapter sink. Explicit local test compatibility never
  becomes network authorization.
- **D3 policy projection:** `MCPToolAdmissionPolicy.clientPolicySnapshot` is the
  original app mapping, consumed at the four existing dispatch/catalog sites.
  Admission-decision and settlement-result aliases refer to the existing domain
  types. No callback ordering, permit registry, cancellation, settlement lease,
  delivery fence or wire-ID/replay ownership moves.
- **DomainRuntime/MCPCore/CLI/headless:** untouched. No file moves or new targets.
  Only one approved new source file; no new test files or ratchet increases.

### Actual async boundaries

Manager resolved operation explicitly receives the packet through the existing
watchdog/provider closures, scopes its diagnostic sink and packet around host
invocation, and preserves the host's structured Task and existing security scopes.
The VM captures before runTool, carries the packet through its start-gated Task,
and reestablishes the bridge immediately around the provider. Heartbeat task-group
children explicitly retain/reestablish the captured packet. Global window tools
capture before MainActor and approval awaits; their helpers receive the packet or
captured identity values. Domain reads retain the host packet alongside (not in
place of) the separate DomainRead invocation identity. Continuation-only start,
idle, connection and file-resolution waiters carry existing exact tokens/results
and do not discover new routing authority on resume. No request-authority
DispatchQueue or detached hop was found in these integration-owned app adapters.

### Authorization qualification

The retained nonthrowing metadata helper is **not an authorization boundary**.
An absent metadata value can classify as administrative in compatibility code.
Safety depends on strict mandatory network binder/read ingress and preserving the
scoped explicit packet across the structured Host Task, runTool/start gate and
heartbeat. Carrier-free MCPService getters return nil rather than looking up a
live successor connection/client/window. Independent Sol production-caller audit
found no audited contextless production adapter entry; parent spot-checked the
complete inventory. Do not turn fixture compatibility into network authorization.

### Local v8 validation evidence (dedicated validator)

| Check | Conductor ticket / accounting | Result |
| --- | --- | --- |
| Exact network/context regressions | `b41db62d-a832-4197-9b6b-5f93c2577b36` | PASS: 6 executed, 6 passed |
| Affected source suites | `e0a24bd2-8275-47e9-95a9-ab867070e9cb` | PASS: 195 executed, 195 passed |
| Exact repaired fixture regressions, v8 | `4dd2173c-3cc0-48f7-8caa-a6a20d1992d0` | PASS: 11 executed, 11 passed |
| Three repaired suites, v8 | `776e86c5-912c-4b83-9063-8f4e2a9f1161` | PASS: 78 executed, 78 passed |
| Broad frozen-source run, v8 | `c6cb5b47-e9e3-4aad-8f6c-42285c5a1296` | PASS: 4,142 executed; 4,140 passed; 0 failed; 2 skipped |
| DomainRuntime / MCPCore in broad-v8 | Same broad ticket, per-module identities | PASS: 268 / 66 respectively |
| Final v8 formatter | `590321dc-e976-44fa-b196-3a12c56e2c64` | Completed, exit 0 |
| Final v8 lint | `d4f0eb5e-966f-4d29-850d-217e8794caf9` | Completed, exit 0 |
| Final v8 guardrails | `0c4a4894-3072-44a9-8c82-678c7ca61965` | Completed, exit 0; ratchets unchanged |

Identity counts, raw logs, original failures and freeze evidence remain under
`/tmp/rpce-pr-reviews/pr4-local-receipts/`. The v8 all-Swift/source manifest covers
1,849 files; validator and precommit checks found drift `[]`. Integration preserves
that manifest and makes documentation-only changes after the tested freeze. These
checks are validator execution evidence, not claims of integration-run tests.

The earlier broad-v7 ticket `b5b53855-287c-4f24-85c9-fe2d3c4219c9` remains a
**FAILED** historical receipt: 4,142 executed, 4,129 passed, 11 failed, 2 skipped.
The complete source/receipt audit classified all 11 as test-only direct materialized
adapter fixtures missing the mandatory carrier. Overseer approved only mechanical
matching trusted-local scopes at those same entries, retaining prerequisite drains,
physical race/collision/cancellation gates and all assertions. The exact 11 and the
broader v8 run now provide the rerun evidence; source triage alone was not a pass.
The extra CancellationError in the first file-actions method was a repeat-validation
obligation, not discarded. Its exact method passes in v8.

Mechanical fixture adaptations are enumerated in the scratch PR draft and audit:
ContextBuilderSelectionPrerequisiteTests (3 methods),
MCPSelectionPrerequisiteErrorTests (4), MCPReadMutationPathContractTests (4), existing
OracleGroupBoundary service fixture and the single ContentReadCancellationTests
constructor near original line 435. The protected final-materialization/rollback
regression near original line 850 is unchanged. Hoisted-type references in existing
authority/recovery tests are mechanical; no new test files or ratchet increases.

### Ref provenance and remaining acceptance

The tested branch remains based on `61ab8b285fa5a9281587ec9712404bfe7b5c528f`.
Immediately before local commit, an explicit fetch found current origin/main
`64b9352eec13e0252500d429f64ca9d1dd5e49fd` (four commits ahead of the tested base).
No rebase, merge, stash, history rewrite or source mutation integrates that newer
main here. Current-main integration and revalidation require separate coordination.

**NOT_RUN:** final-head `make dev-build` debug package, live CE MCP E2E (approval,
denial, multiwindow, cancellation, replay), and headless initialize/list/read-only
runtime checks. Dedicated validator owns these next gates. Live lifecycle requires
separate explicit overseer approval. Local commit authorization is not push/PR or
lifecycle authorization; no integration engineer builds/tests/formatter were run.

## PR5 — B1–B4 platform extraction (2026-10-04)

Base: `3fbf7d0d41a4fe04c1bc701327afd297ccaeaf74`, branch
`modularization/pr5-platform`. Three disjoint Sol engineers owned FileSystem,
VCS, and SettingsCore; the coordinator owned Persistence, manifests, app
composition, and integration. PR6 WorkspaceContext extraction is not included.

- **B1:** FileSystem owns watchers/FSEvents, ignore compilation and neutral
  matching contracts, content reads, seed-plan reading, and the generic injected
  disk writer. App metrics/recording, settings policy, authenticated seed-plan
  adapters, and workspace write policy remain app-owned.
- **B2:** VCS owns app-free repository/worktree queries and reusable parsers and
  values. GitService and feature-dependent receipt/presentation authority stay
  app-owned; no full GitService rewrite.
- **B3:** Persistence owns CodeMapArtifacts and DurableArtifacts plus canonical
  selection contribution values. App source-snapshot verification adapters retain
  the original raw-byte/OID/digest guards. Presets remain deferred.
- **B4:** SettingsCore owns the document, file store, neutral values and store,
  including `.shared` compatibility and immutable global-ignore settings.
  Application catalogs, notification mapping, UI normalization and bootstrap stay
  app-owned. Persisted keys and compatibility literals are unchanged.

`Sources/RepoPromptShared`, `Sources/RepoPromptDomainRuntime`,
`Sources/RepoPromptMCP`, and the frozen prototype are untouched. Reliability
transport/bootstrap/Exec-reporting repairs are not absorbed. Contributor overlaps
in GitService/receipts stay at their original app paths; moved root-manifest and
settings fixes require path reconciliation against their exact contributor heads,
not blanket deferral or unreviewed cherry-picks.

### Executed receipts

| Boundary | Conductor ticket | Actual result |
| --- | --- | --- |
| App product | `231c341a-3c12-4eff-9f80-22d8565dee0b` | PASS |
| MCP product | `f9e08926-d451-4d47-a78f-c50ceb82bb79` | PASS |
| Content reads + compatibility goldens | `9fdd0a5c-051d-499d-8316-e3e768aababa` | 40 tests, zero failures |
| Final platform owners + focused app integration | `deb667b5-66db-44cc-8c87-aa59a4bc0ec5` | 61 owning tests + 97 app tests, zero failures |
| Event-bridge fixture regressions | `30f34235-741b-414c-829e-ffd576050374` | 12 tests, zero failures |
| Broad final Swift source validation | `46a276bf-e38f-40ff-9ed0-fab61ce555a0` | 4,399 tests, four skipped, zero failures; 14 targets |
| Pinned formatter + strict lint | `a4c64972-916f-4805-b49d-896de7145a2d` | PASS; 0/1,632 files require formatting |

Guardrails passed, including 36 target rows, placement, dependency edges, licenses,
headless fences and 15 metrics tests. Nested-sandbox SwiftPM manifest evaluation
failed first; the approved unsandboxed guardrail invocation passed. This is a
validation-environment receipt, not a source defect.

Historical failed receipts are retained: focused content reads
`010cf4d8-a793-450b-905f-0480a165f5a1` and broad
`e89816c4-9ff6-454e-9933-a90beb1d0317`. The former exposed lost host TaskLocal
attribution across the existing detached read worker; a captured app-owned
attribution adapter restores the original tag without new tasks, locks or unsafe
annotations. Its final-materialization gate failure remains unattributed despite
subsequent focused and broad passes; it is not labeled inherited. The latter
exposed three app test hosts bypassing startup notification-bridge installation;
explicit fixture adapters repaired delivery without weakening any assertions.

Disk-writer injection preserves independent selection keys when incoming records
are nil; the owning contract regression exercises this behavior. Source review
confirms normalization writeback forwards the manager's injected writer, but no
committed integration regression directly injects a non-default manager writer.
That routing contract remains a coverage gap, not a claimed executed test. No
timeout widening, retry sleeps, authorization weakening or assertion removal was
used to repair failures.

The four gated metrics tighten to 16 files over 5,000 lines, 47 over 2,000,
326 app-testable imports and 89 app static shared declarations. App line count
remains advisory; its numeric baseline and headroom are unchanged. Tracked sleep
count growth (59 to 64) is disclosed, not silently baselined upward.

**NOT_RUN:** debug packaging, visible-app lifecycle, live CE MCP acceptance and
paid provider calls. No timing benchmark is claimed; conductor execution/queue
and global-wait accounting are available in the ticket logs. Exact-head hosted
checks and fresh milestone Astra review remain acceptance gates.

### Independent milestone review

Read-only Astra XHigh review of exact `2467154530eb0b31f2d196dde1f1dfcc3647cee5`
found no demonstrated B1–B4 behavior, security or authority regression. It confirmed
preserved read cancellation/permit ownership, authenticated seed-plan readers,
raw artifact provenance/OID/byte-count/digest/CAS guards, and settings startup/event
boundaries. Review report: `/tmp/pr5-astra-246715453-review.md` (local artifact,
not a hosted check or new test execution).

Its P3 evidence finding is corrected above: injected manager normalization routing
is source-reviewed, not directly covered by a committed injection regression.
Direct app raw-source-adapter mismatch coverage is also an explicit gap; owning
container corruption/hostile-file tests validate a different layer. Duplicate pure
delta coalescing in the app and FileSystem is a non-blocking future divergence risk,
not a demonstrated current algorithm mismatch. The historical final-materialization
failure remains unattributed; broad GREEN is not causal proof of its disposition.

### V194 injected write-backend contract resolution

The PR5 coordinator owns this B1 repair. Revised-head review at `838a583a2`
correctly left historical V194 (revised audit row 197) unresolved: the async
`atomicWrite` callback controlled queued writes, while eligible normalization
bypassed it and performed physical I/O. This was not cleared by eight hosted
GREEN checks. The default physical app behavior matched main, but the custom
write-backend contract was defective, not merely a mechanical-audit classification.

Concrete regression receipt `11a451db-f630-4804-be31-0baedcefd6a6` executed one
case, `testNormalizationDoesNotBypassInjectedBackendFailure`, and failed both the
refusal and unchanged-file assertions: normalization returned success and replaced
the real file despite the injected backend refusing writes. No production source
had changed before this RED execution.

The intended contract is now explicit: `WorkspaceDiskWriteBackend` requires both
`queuedAtomicWrite` (async) and `normalizationAtomicWrite` (synchronous), with no
implicit physical fallback when choosing a custom backend. It is a write backend,
not a virtual filesystem; file-stamp reads remain filesystem-owned. The default
`.physical` backend performs the same atomic writes as main. Normalization's
pending-slot check, size/mtime checks, synchronous backend call, and successful
selection recording remain one non-suspending actor operation. No `await`, task,
lock, retry, timeout inflation, or authority bypass was inserted into that critical
section. Application composition still uses the default process-owned writer.

Focused correction receipt `769a00a9-582d-4897-96b6-811a40f6c37e` executed **seven
owning contract tests, all passed**: the five new normalization regressions cover
backend refusal without physical mutation, custom backend dispatch without physical
mutation, default physical behavior, stale size/date rejection, and pending-write
rejection. The two existing selection-key and in-flight/coalescing tests retain
their original assertions. The extra DecodeWork selector matched no app tests;
this receipt is not claimed as app integration coverage. Revised-head full tests,
style, hosted checks and independent delta review are separate subsequent gates.

The other 257 strict-audit rows at `838a583a2` retain their exact-path/owner intended
adaptation dispositions; the strict tool remains FAIL, not suppressed or made GREEN.
This repair resolves a substantive injected-backend defect but does not make the
extraction a pure move. Manager-injected normalization routing and direct app
raw-source-adapter mismatch coverage remain separately disclosed gaps, not tests
supplied by these owning writer or neutral container suites. The historical
final-materialization and graph authority failures remain unattributed; subsequent
GREEN execution is not causal explanation. No typed-path claimed source or
separately owned reliability source was modified.


**2026-10-13 upstream validation reconciliation.** Unmodified upstream `39b496ab26a39002cdabe90fce8794d9c2355107` contains 333 files with the exact App-test import counted by the ratchet, against a recorded limit of 332. The Ultrafast contribution adds coverage to existing suites and introduces no new App-importing test file. Align only `tests_testable_import_app_files` to the existing 333-file tree; counts above 333 still fail, and every other baseline and policy stays unchanged. Update the stale sidebar builder and self-compact reservation test calls to the current interfaces without removing assertions. These prerequisite repairs are kept separate from the Ultrafast implementation for review.

## PR 8 (M8) — AI contracts and provider families to their own targets (2026-11-06)

Delivers completion-plan milestone 8 (wave E: E1 contracts + E2 providers). Six new
library targets in the root package, none of which depends on `RepoPromptApp`, UI
pickers, or `AgentModeViewModel`:

- **`RepoPromptAIContracts`** (~3.1k lines) — E1: provider-neutral `AIModel`
  identity and raw values, `AIProviderType`, `AgentModelOption`/effort variants,
  `AgentProviderKind` and task-label kinds (`explore` etc. stay typed, not
  positional strings), reasoning-effort values, Claude/Codex/ACP model-identity
  normalization, `CodexModelSpecifier`, `CodexServiceTierVariantCatalog`,
  `ModelCatalogSemantics`, `CodexDynamicModelMapper`, `AgentCLIToolContext`, and `AIProviderError`.
- **`RepoPromptAgentProviderContracts`** (~0.5k) — the native runtime seam:
  `NativeAgentRuntimeControlling` plus its event/status/error/session values
  (`NativeAgentRuntimeEvent`, `…RuntimeInitStatus`, `…TurnStatus`,
  `…InterruptOutcome`, `…ControllerError`, `…EventStreamHandle`).
- **Provider families (E2):** `RepoPromptClaudeProvider` (~5.1k:
  `ClaudeCodeProvider`, `ClaudeCodeAgentProvider`, `ClaudeNativeProcessSessionController`,
  turn correlation, CLI stream decoding, the package-facing half of the
  compatible-provider bridge), `RepoPromptCodexProvider` (~4.1k:
  `CodexAppServerClient`, the injected `AgentCodexModelRegistry`, Codex exec
  contracts), `RepoPromptACPProviders` (~14.1k: ACP session controller and
  headless bridge, Grok/Devin/Antigravity/Cursor/OpenCode providers, launch
  resolvers and model polling), and `RepoPromptHTTPProviders` (~4.0k: OpenAI,
  Anthropic and custom HTTP engines plus shared liveness).

Each target has an owning test target (~8.2k test lines total) that builds and
runs without the app. `RepoPromptDomainRuntime` gained only a downward
`RepoPromptAIContracts` dependency; nothing moved out of it and it still has no
app dependency. `ProviderContent` and `Diffing` remain the shared owners rather
than moving upward into a concrete provider target. This is not a claim that
DomainRuntime is unchanged: against main `21a31933e`, M8 adds the shared diffing
implementation (`ChangeApplier`, `ChangeManager`, `DiffParser`, `DiffParserFileSource`,
`FileChange`, `OptimalLineFinderUtility`) and provider-content values for approval,
context usage, JSON, run state, payload retention, Codex request/interaction identity,
normalized events, transport activity, MCP configuration and stable interaction
identity. It also adds `AgentModelCatalogRuntime` and
`AgentOracleAuthoritativeChatIDPolicy`. These include relocations and extracted
values; file additions alone do not measure new behavior.

**Retired machinery.** The registry singletons (`AgentACPModelRegistry.shared`,
`AgentCodexModelRegistry.shared`) and direct advertised-catalog access are gone;
the one application-owned `AgentModelCatalogRuntime` (2026-10-29 entry above) is
the only composition point, and registries are constructed with injected storage,
option policy, and invalidation. App-local nested controller types and capability
projections (`ClaudeNativeProcessSessionController.{TurnStatus,RuntimeInitStatus,Event,SessionRef,InterruptOutcome,ControllerError}`)
are replaced by the contract values; the Claude/Codex/ACP/HTTP providers take
app policy (model selection, prompt delivery, environment filtering, launch
hosts, approval overlays) through package initializers instead of reaching into
app state, separating construction from consumption. No second model catalog was
introduced; provider-specific persistence destinations (`CodexDynamicModelStore`,
`ACPDynamicModelStore`, backend stores) remain app-owned and behavior-identical.

**Reconciliation with main (53 commits since the integration branch's base).**
The extraction was rebuilt on current main and the following upstream semantics
were preserved inside the moved code: one-snapshot Codex catalog projection
(#1590 — the records snapshot now threads through the registry dependencies,
`AgentCodexModelPolicy`, mapper, and `AIModel` wrappers; cache keyed by records,
remote/stored inputs with identical canonical records share one entry);
provider-initiated turn tracking (#1565/#1611 — `providerTurnStarted`, provider
output ownership, event-stream generations and the `eventStreamSnapshot`
protocol requirement); the auto-compact window (#1594/#1620 —
`autoCompactWindowTokens` on the contract init status); native Claude terminal
usage normalization (#1582 — `CompletionUsageMode` is provider-owned and decided
by the injected compatible-backend/model-selection policy); the unified
`CLIProcessRunner` output-drain hook API (#1580) over the branch's split
streaming/non-streaming hooks, keeping the DispatchIO-owned bounded drain; Codex
`optOutNotificationMethods` and exact response usage (#1601). Correlation tests
moved to `RepoPromptClaudeProviderTests` were refreshed from main's updated
versions; the registry ownership tests now assert the single-snapshot contract
instead of the retired remote/stored cache split.

**Aggregate effect against merged main `3fd8a9027`.** The integration snapshot
is parent `b9500dea0` plus main `3fd8a9027` and the review remediation described
here (final publication SHA and receipts are in PR #1642): 616 files,
+23,202/−12,706; net +10,496 lines. App-target Swift lines
681,246 → 650,378 (−30,868). This is relocation out of the app target, not a
net reduction in aggregate implementation. `modules.json` carries six new target
rows and placement rules; the import-check matrix and per-target guards cover them.

**Separate lexical and compiler-index evidence.** The earlier 1,048 → 947
wrong-way-file-edge comparison is a lexical/source-layout metric, **not** a
compiler-index result. At head `b9500dea0`, CI run `42233157014`, build job
`127945262805`, recorded **1,268 measured wrong-way edges (ceiling 1,360)** and
**largest cycle 63 measured components (ceiling 66)**. This is not a before/after
comparison. This older receipt does not validate the subsequent `3fd8a9027` merge
plus review fixes; final-head results are recorded separately in PR #1642.
A stale or freshness-unproven graph is not a pass.
The 47 → 43 large-file threshold and 89 → 87 shared-declaration threshold are
separate source ratchets. No compiler-index ceiling was raised.

**Not only a move: shared process I/O.** `CLIProcessRunner` also contains a real
nonstreaming I/O rewrite: concurrent `ShellOutputCapture` output readers,
DispatchIO-owned stdin, a bounded post-exit drain, and coordinated cancellation
cleanup replace the previous blocking-file-handle path. The streaming hook API
was reconciled with #1580. At M8 head `b9500dea0`, the file was byte-identical to #1415 head
`e8a86685c` (blob `8faa24a4e74ca2e634a70781d0d6bb93c1570f61`). Shared presence
in two PRs is neither a pure-move claim nor evidence of unchanged runtime behavior.

**Validation boundaries.** Detailed command/ticket/head receipts and failure
attribution are recorded in draft PR #1642. At `b9500dea0`, hosted CI and Xcode
passed, while the complete local suite had 8,338 passes, one source-authority
failure, and 16 skips. Its focused CodeMap follow-up had 10 passes and a different
graph-completion timeout. At revision `b9500dea0`, these failures are
`WorkspaceCodemapGraphIncrementalIndexTests.testPathScopedReconcileWorkIsIndependentOfLiveLayerSize`
(line 563) and `testGraphIndexCompletionImpliesGraphCoverageWhilePullLoopIsPaused`
(the `waitForGraphCompletion` throw at line 791). They are not failures in
`CodemapAutomaticSelectionGraphNativeTests`; #1415's cited synchronization repair
does not modify these tests. Hosted root shards executed the class; Xcode validation
is not a test result. Hosted green does not clear the local failures. Their causes
remain unresolved for those historical observations. The review diagnostic run
(`4f12794b`, 242 passed / 1 failed) exposed a separate setup-ordering
problem in the completion test's setup: its root-wide admission hold can prevent
the first graph publication, yet the test waits for that publication's pull pause
before releasing the hold. The test now admits page one and gates following catalog
pages until the pause is observed, preserving the coverage assertions and deadlines.
This repairs that observed setup ordering; it does not establish the cause of the
historical completion timeout or nil token. The revised class passed all 11 tests
(ticket `f4a526a0`; completion 5.123s, token issuance 6.204s). Failure records now
retain the authority rejection reason and timed-out root state for future attribution.

**Missing milestone performance evidence.** A matched before/after focused-build
comparison has **not** been performed. Existing conductor durations span different
source/cache states and shared-host load, so they are not a valid comparison and
support no speedup claim. Acceptance remains open until an identical focused
product/target workload is measured on the pre-extraction and extracted trees with
matched toolchain, cache policy and host conditions. This repair does not substitute
unmatched timings or queue time for that experiment.

**Unperformed assembled/live validation.** No visible app launch/relaunch,
credentialed live-provider journey, or local release/packaged-provider smoke was
performed. Module/focused tests and hosted Sentry packaging do not establish those
assembled runtime behaviors. They require separate approval and matching artifact
receipts; #1404 acceptance remains pending.

## M6 / #1403 — Stage 0 implementation checkpoint (2026-10-18)

Base: `a1368cbbf16565834740a3199964adb19519a9d4`, branch
`wt/1401-milestone-1`. This is a partial implementing checkpoint, **not** M6
completion or permission to treat the #1402 readiness gate as passed.

### Existing owners and selected retirement

| Boundary | Existing owner | Preserved invariant |
| --- | --- | --- |
| App MCP ingress | `ServerNetworkManager` → `MCPDomainHost.invoke` | Captured invocation and exact route ownership remain independent of tool arguments |
| Service composition | `MCPServerViewModel` and its SessionAdmin extension | Caller endpoints come from installed run routing, not caller-supplied identity |
| Administration | Bridge-owned production administration core/front door | Single authorization engine, canonical writer selection and durable-effect receipts remain intact |
| Link/cursor authority | `DomainAgentSessionLinkAuthority` | Bare cursors select only exact authorized outbound targets; successors remain opaque |
| Transcript filtering | `AgentTranscriptIO` + `AgentTranscriptImportPolicy` | Active refresh/import path retains pending-question and hidden-tool filtering |

Retired `AgentModeViewModel.shouldDisplayInTranscript` and its sole-use
`isAskUserToolName` helper: **32 lines removed, zero successor lines**. Both were
private and had no live callers; the wrapper's diagnostic/alternate question-name
route was unreachable. The active `refreshDerivedTranscriptState` path continues
to construct the live-session import policy and consume `AgentTranscriptIO`.
No state, subscriptions, schemas, leases, consent checks, cancellation owners or
persistence fences were removed. This bounded dead-route retirement does not
claim that other manager/bridge state is redundant.

### Executable contract work

- Added `AgentSessionLinkToolServiceTests.testActivatedTwoLaneJourneyReplaysBareCursorsAndRetiresOwnedLanes`.
  It assembles the real tool services, bridge, authority and temporary intent
  store with the existing controlled endpoint host. It activates Overseer,
  creates two explore lanes without a workspace selector, acknowledges first-task
  `LANE_OK` delivery, replays returned bare wait handles and successors, retires
  both lanes and checks live/durable intent and waiter cleanup without changing
  the foreground workspace/tab. The host does not execute a provider; this is
  **not** packaged ingress or real-provider completion evidence.
- Strengthened `testCursorOnlyWaitRejectsForeignAndUnknownHandlesWithExecutableRecovery`:
  each returned list call now supplies the target for a fresh poll and two waits
  using actual returned handles. No earlier target identity or reconstructed
  target/cursor record completes the recovery.
- Reuse the existing production organizer group-order recovery/no-op tests and
  real temporary-Git unopened model/effort, bind/release and conflicting-writer
  suites; do not duplicate those effect-level assertions in the controlled host.

### Validation status

- Local Oracle diff review: no actionable findings; not the milestone's pinned
  independent review at push.
- Test ticket `1f88d989-c888-4210-b1ec-acb3a5ffaa57`: timed out at the
  one-hour job limit after 21m 31s of global wait, near the end of compilation;
  no passing test receipt. Rerun `a3b4e4bd-ec17-403d-a50d-ab69d9420165`
  (`issue1401-stage0-contract-v2`) completed successfully, exit 0: **126 tests,
  zero failures** (98 link-tool service, 19 production organizer, 4 real-Git
  worktree recovery, 5 canonical transcript). Heavy admission took 22ms;
  execution including build/post-test work took 21m 25s, and the selected tests
  themselves took 42.18s. Auxiliary module bundles executed zero matching tests
  and are not additional coverage. This is controlled-host/app-service coverage,
  not packaged-process or real-provider proof.
- Lint ticket `dd21c72b-8174-423c-a522-f32b3e9dcb0c`: failed, exit 70,
  after 31m 55s. SwiftFormat timed out in redundantPublic/wrapArguments rules
  across six files, including unchanged source/test files. This is not a pass
  or evidence that SwiftLint ran.
- Earlier test ticket `4ac2b6e2-d741-4356-9875-83f3ffe527b6`: canceled before
  global heavy admission; no tests executed.
- Pinned formatter installed via successful ticket
  `ba1b3fd0-ef64-40a4-99f6-6b9b4ef48117`. Broad format ticket
  `94841811-4ed4-4649-b2b2-12487ed0f240` was canceled; inspection showed only the
  intended source/test files changed. Scoped formatting subsequently reported a
  `wrapArguments` timeout on the giant existing AgentModeViewModel file; this is
  **not** a passing style receipt.

Still required before C3 extraction: complete assembled production-ingress
coverage and Stage 0 validation, reconcile exact source/test claims and dependency
closure, then perform audited moves and app-free module/test validation. No files
have moved, no module/ratchet limits changed, and no live app action occurred.

### Batch integration checkpoint (2026-10-25)

Integrated current main `a7c3c892ef17fe91596cdd88a16a72436e2f6c27` without
rewriting the published checkpoint history. The independent engineer review found
no demonstrated production regression and identified two test-oracle gaps, both
corrected in the existing two-lane journey:

- Record each first task's actual destination and match the two returned lane IDs,
  rather than accepting two identical messages sent to an unspecified destination.
- Join the temporary intent store's writer and open a fresh reader before and after
  retirement. Require both exact observer/target pairs to be durable first, then
  require neither pair to restore after cleanup. Empty bridge inventory alone is
  not proof that a durable store was installed or that its rows were removed.

Also applied the shared test-only admission-fixture repair from
`65c4fdea53b41e35b9edc3c1333eeb2828702d35`: join root loading and the foreground
badge callback before measuring Git-mode save invalidations. The exact retry
allowance and durable-save assertions remain enforced; no #1310 feature code was
included.

- Separate pair cleanup and a local Oracle diff review found no further actionable
  findings. These checkpoint reviews are **not** the final pinned M6 review.
- Coordinated formatter `664e3cc1-e143-4ce8-abe9-88139cf93b0c`: PASS, exit 0,
  no additional formatting changes. Coordinated strict lint
  `ea9224d6-dcac-47c2-9c2d-68aa0fdc43af`: PASS, exit 0, zero formatting drift.
- Coordinated focused tests `ad04aaff-0374-4fae-a1b1-6f0ec2e58dee`: PASS, exit 0,
  **260 tests, zero failures**: 98 link-tool service, 27 same-workspace admission,
  103 initial-window selection, 23 production-organizer journey, four real-Git
  worktree recovery and five canonical transcript tests. Auxiliary bundles ran
  zero matching tests and are not extra coverage. Execution including build and
  post-test work took 15m 14s; selected tests took 49.32s; heavy admission took 11ms.
- Coordinated app product build `7f525a87-ed6c-4169-acbf-c261616368da`: PASS,
  exit 0, 13.2s execution with 10ms heavy admission. This builds the product but
  does not package or launch it and does not establish live-ingress behavior.
- An earlier attempt executed no tests because the sandbox prevented conductor's
  required process-identity check. Its lint run passed formatting but could not
  write SwiftLint's cache. Both were retried through the same coordinated lanes
  after restarting only this worktree's idle daemon with the required permissions;
  neither failed attempt is counted as passing evidence.

This remains a **partial Stage 0 checkpoint**, not M6 readiness. Production-ingress
and remaining adversarial/effect coverage, C3 app-free extraction, move/access/index
and edit-to-test evidence, final milestone review, and broader product/release/live
validation remain outstanding. No roadmap/readiness issue is closed, no module or
ratchet limit is raised, and no visible app is launched, stopped or replaced.

### Stage 0 host/service readiness checkpoint (2026-10-28)

Normally merged pinned main `c47a23d61b2970625772e0b900252da9b3a2064f` into
existing M6 lineage `c92605d21c6fe4fb0196316e73523fc3865fe5e4`, producing
`33d00d600373f169b296467de36eaba0c242bb84`. Primary checkout untouched.

Selected existing journeys now enter the real canonical registry/domain host,
then the existing service, authorization engine, production organizer/configuration/
worktree owners or link bridge/authority. The small test-only host helper owns its
temporary runtime and verifies invocation/resource cleanup. Exact returned bare
cursors and successors, ordinary/preview group-order recovery, zero-change
satisfaction, unopened model/effort writes, real temporary-Git bind/release,
conflicting writers, committed-save versus late-authority change and pre-publication
save rejection retain effect-level assertions without foreground changes.

Preserved only the remaining +19 FrontDoor and +41 first-save-test hunks from local
`6b02b155da4f1c059c398c572563c10afaaed1ed`; other handler/scope-test progress was
already upstream. Repaired the inherited first-save oracle against current main's
structured `.admissionRejected` evidence, retaining all no-publication/save/provider
assertions. Preview recovery intentionally preserves `preview: true`; the separate
ordinary returned call proves `state_satisfied: true`, `changed_count: 0`.

- **PASS:** seven exact focused tests, zero failures; conductor
  `b7dcda37-47af-43dc-a829-f4863ecac49c`, request
  `runtime-contract-20261028-host-first-v3`, exit 0. One link-tool journey,
  two organizer journeys, three worktree/configuration journeys, one first-save
  rejection. Selected tests 117.017s; build 209.95s; job execution 487.720s;
  heavy admission 0.106s. Auxiliary zero-match bundles are not coverage.
  Tested parent is `33d00d600373f169b296467de36eaba0c242bb84`; six-Swift-file
  binary-diff SHA-256 `f58c6e243b1238d958dcdd857e9ffc5302c585aa0eb6e77621925ab20bd187d6`.
- Earlier `9adfdd8d-ff2e-4267-ae9a-bf31ac52f627` timed out at 3600s after a
  3375.75s cold build and partial execution. `a9ba2f96-b4ee-4081-beeb-a7dad5326b1f`
  failed exit 1: seven tests, two failed test methods (ten oracle assertions).
  Neither is passing evidence; v3 corrects the typed-error/preview oracles.
- Scoped pinned SwiftFormat and strict SwiftLint passed for changed files.
  Whole-tree combined lint `04fb6848-0241-402d-8416-b9dd6d0d49cb` **FAILED**
  exit 70 after 14m53s: `redundantEquatable` timed out in unchanged
  `WorkspaceCodemapLiveOverlayModels.swift`. No SwiftLint phase/pass is claimed
  for this job. Missing-tool and canceled attempts are not passes. A separate
  worktree's earlier timeout was followed by a passing format-check, so a
  deterministic source defect is not established. No formatter policy was
  weakened; repository-wide style is **NOT_PASSED**, not landing-ready.
- One local Oracle review found a setup-error host-cleanup gap, fixed by covering
  post-start temporary-directory setup with the existing asynchronous cleanup.
  This is not the final independent milestone review.

Evidence tier: **in-process host + real service/engine effects with controlled
endpoint resolution**. It does not execute transport early/pre-admission policy,
app binder or real bootstrap route-proof issuance. `LANE_OK` still acknowledges
controlled-host task delivery, not a provider response. The existing discovery
socket fixture's default admission is debug-only; a subsequent serialized-transport
journey must explicitly use production Agent admission. Packaged/live/vendor
validation is **NOT_RUN**; no app lifecycle or GitHub write occurred.

The existing 32-line dead transcript-filter retirement remains intact, with
`AgentTranscriptIO` / `AgentTranscriptImportPolicy` surviving; this phase adds no
broader VM/bridge retirement and does not certify M6/M10. No extraction or ratchet
change is included, and no readiness issue is closed.

### Stage 0 serialized admission checkpoint (2026-10-28)

The existing discovery fixture now explicitly exercises production Agent admission,
real socket frames, app tool registration and bootstrap proof for the observer.
Two controlled native controllers produce actual assistant replies through the
runtime; they are not vendor processes or packaged/live evidence. The fixture
enters the ordinary active Agent Mode lifecycle and records foreground workspace,
tab and draft before activation; it asserts those remain unchanged through the
journey. It does not establish UI-free or inactive-presentation behavior.

The journey executes returned bare cursors and successors, unknown-cursor recovery,
real scope request, exact group-order recovery with zero-change satisfaction, scope
release and lane retirement. The existing foreign/unknown cursor recovery now also
passes through the canonical domain host; malformed handles remain separate.

- **PASS:** conductor `8d7ab6be-f18c-496f-b848-00394b3d3f33`, request
  `runtime-contract-20261028-cohesive-formatted`, exit 0, **11 matched and passed**;
  selected tests 24.932s, build 79.29s, execution 3m01s, global wait 1m37s.
  This includes the serialized journey, existing discovery route fence, both cursor
  cases and the seven host/first-save contracts. Tested HEAD is
  `348bf52c2da0a88c3e3575f22c099448ed16936d` plus two-test-file binary diff
  SHA-256 `ab03d885a93aa0acb37b2db5e6941822abb52a5488a615c25f9abab21e899ddd`.
  Logs are in the conductor jobs directory under the ticket UUID.
- Earlier single journey `bf14f022-8179-4ed3-9f97-4abfb9f36065` passed exit 0,
  1 matched, before scoped formatting. Earlier failed diagnostics are not passes.
  Scoped pinned SwiftFormat exit 0, one of two files formatted; scoped strict
  SwiftLint exit 0, zero violations. Whole-tree combined style remains NOT_PASSED
  as recorded above; packaged/live/vendor tiers remain NOT_RUN.
- Focused review found missing persistent fixture cleanup and a permissive changed-
  cursor oracle. The fixture now deletes its canonical workspace and owned directory
  on success or failure, and requires changed then timeout on successor replay.
  Conductor `e527fb45-35c8-4db6-9d7c-233269593612`, request
  `runtime-contract-20261028-review-fixes-v3`, exit 0, 1 matched and passed in
  19.458s, build 56.59s, execution 2m07s, global wait 9.5s. Final two-test-file
  binary diff SHA-256 `5767dc7e25b4b64ec68228562535c3d835c2fa782f880a1672528519620771ed`.
  The earlier review-fix compile failure and owned-root rejection were corrected,
  not counted as passes. Final scoped format lint and strict SwiftLint both exit 0,
  zero drift/violations. The 11-test receipt above predates these focused changes.
- Readiness investigation found the fixture's inactive Agent Mode left the ordinary
  workspace-switch fence set, blocking the composer despite an idle public snapshot.
  Real fixture activation resolves this case without changing production behavior.
  The coupling of inactive presentation to that fence remains an unresolved M9/M10
  runtime-ownership finding; neither inactive safety nor no-foreground workspace
  admission is claimed. Temporary production diagnostics were removed.

This is a bounded partial Stage 0 checkpoint, not #1402 or M6 completion. The
32-line inherited dead-route retirement and surviving transcript owner are unchanged;
no new production responsibility, extraction, or ratchet is claimed.

### Stage 0 — request-progress authority retirement

The app-owned direct `MCPRequestProgressState` route and its context enum, alias,
forwarding overloads and direct send branch are retired. `MCPDomainHost` and its
request progress handle remain the sole standard-progress authority; the boxed
TaskLocal, same-connection inheritance, explicit override, connection separation,
lifecycle correlation and RepoPrompt CLI control fallback remain. This slice changes
`MCPConnectionManager.swift` by +9/-51 (60 combined lines), with no new state or
owner. It does not retire filesystem transport or broader runtime responsibilities.

Conductor `ff56b17c-e86e-45a9-aeb3-f467107e9446`, request
`runtime-contract-20261028-progress-final`, passed exit 0, nine matched and passed:
six connection-removal/progress tests and three TaskLocal layout guards. The three
new tests exercise manager-to-host delivery and control fallback, canonical-handle
nested inheritance/override/separation, and independently settled and terminal
handle suppression followed by successor-generation delivery. Tested parent
`b3fd63f3d8c3a946cfe2d5d47eb507410772c83f` plus two-file diff SHA-256
`34e7db92fcec135af149036be058a56ed91c98a205697a91133b9567086990c7`.
A DEBUG-only host getter now validates the complete handle and exposes the existing
actor only for its quiescence test barrier; it adds no shipping state or authority.
The tests capture each actor before finish/cancel, wait for its own worker after
negative sends, and reject a forged handle. Final conductor
`7891afb2-3c03-4e9c-8d0b-c3204bd81517`, request
`runtime-contract-20261028-progress-quiescence`, passed exit 0, **13 matched and
passed**: six progress/removal tests, three TaskLocal guards, four domain response
delivery tests. Parent `b3fd63f3d8c3a946cfe2d5d47eb507410772c83f` plus three-Swift-file
diff SHA-256 `d93a1958684425d5c080cbda0306b44ff2744bfc1cf6724819ed630881cf83f7`;
execution 9m18s, global wait 16ms. The DEBUG observation adds 10 source lines;
combined production delta is +19/-51, with no new shipping route or state.

Scoped strict SwiftLint with `--no-cache` passed; pinned SwiftFormat 0.61.1
reports nine pre-existing host-file diagnostics, independently reproduced on the
exact HEAD baseline (`/tmp/runtime-contract-20261028-host-baseline-format.log`).
The manager and test file passed pinned formatting. Whole-tree combined style remains
NOT_PASSED as above. Live, packaged and vendor provider evidence remains NOT_RUN.

The serialized acceptance fixture establishes no tool-requested workspace
selection or unrelated focus/draft change only for an already active caller workspace.
It does not establish inactive-presentation safety or UI-free execution. A minimal
missing counterexample is an authorized observer captured for workspace A while its
window has nil or unrelated workspace B active: exercise explicit and omitted
workspace selection and assert the exact captured observer/workspace route without
fallback, focus changes or fabricated success. Existing destination resolution draws
from active window workspaces, so this remains a separate windowless/foreground
gate, not a demonstrated passing case or a claim about #1408 completion.

### Stage 0 — no-selection and adversarial current-head receipt

At parent `8946c2bdf364042d1466e8dba0a5ab083e1da12f` plus test diff SHA-256
`3912ed88773a30439a4f7d47be3a685a3e264715ddbb8174d1fdfb84d9d4d206`, the
existing serialized production-admission journey asserts its caller's `WindowState`
has no attached `NSWindow` before and after tool calls. Setup explicitly routes an
active workspace; the journey does not select another workspace or tab, alter its
foreground draft, or hydrate/change the persisted unopened sentinel's session and
draft. It still exercises two returned lane IDs, controlled assistant replies,
returned bare cursors and successors, and exact group-order recovery. This is a
real socket observer/binder/bootstrap with controlled lane providers, not a
packaged/vendor/live or generally windowless runtime claim.

- `630fa54a-5a6e-436b-8576-b25a81306e0a`, request
  `runtime-contract-20261028-no-selection-sentinel`: exit 0, **1/1** matched,
  `AgentSessionLinkLiveDiscoveryTests.testActivatedTwoLaneContractUsesProductionAgentAdmissionAndReturnedCalls`,
  41.513s test, 6m40s execution.
- `821faaa1-3a10-4fa7-9803-ce436fa961b7`, request
  `runtime-contract-20261028-adversarial-final`: exit 0, **10/10** matched,
  1m58s execution. Its exact passing cases and evidence are:
  - `AgentSessionLaneFirstSaveTests.testAuthorityRevisionConflictBeforeLanePublicationLeavesNoLaneOrProvider`,
    `testFailedFirstSaveKeepsTheLaneForRecoveryWithoutLinkProof`, and
    `testRebindDuringHydrationDoesNotMarkReplacementAsCreatorOwned`: actual app
    destination/save fixtures show no prepublication allocation/provider on conflict,
    retained unproven recovery on failed first save, and no ownership for a rebound
    replacement.
  - `AgentSessionLinkToolServiceTests.testActivatedLaneBasisIsFencedAtClaimCapSaveInsertReserveSeedAndActivation`
    and `testActivatedLaneCancelledCallerStillCommitsFirstTaskOnceAndReplayJoinsReceipt`:
    controlled bridge fixture rejects changed activation at each named fence and
    preserves one committed first task across caller cancellation/replay.
  - `SessionAdminInFlightIdempotencyTests.testCancelledCreationReleasesReservationWithoutCachingAnEffect`:
    controlled worktree host proves no precommit effect and successful fresh retry.
  - `SessionAdminInventoryReadTests.testFullAccessOffAfterLinkRevalidatesConsentBeforeDelivery`:
    loaded-window bridge fixture returns partial `scope_revoked` with stable replay
    after access changes between link and dispatch.
  - `SessionAdminWorktreeRecoveryTests.testCompetingBoundWritersCannotMutateConfigurationOrCreateWorktree`,
    `testUnopenedLaneModelAndEffortUseItsWriterDespiteEarlierWorkspaceReplica`, and
    `testExistingCheckoutRecoveryReplaysThroughToolBindAndRelease`: canonical-host
    fixtures prove competing writers fail closed, unopened model/effort persistence
    leaves the replica unhydrated, and a real temporary Git checkout's returned bind
    recovery is replayed and released without deleting the checkout.
- The organizer cases were unmatched by the first selector (file name was mistaken
  for suite name) and are **not** counted in its ten. Corrected ticket
  `4977b03e-3eaf-4884-b362-19a4924008fe`, request
  `runtime-contract-20261028-organizer-final`, passed exit 0, **2/2**, 1m34s:
  `SessionAdminProductionOrganizerJourneyTests.testReorderGroupsMCPRecoveryAndApplyUseOneWriterForAgreeingReplicas`
  replays the exact zero-change and preview recovery across agreeing replicas;
  `testReorderGroupsReportsCommittedSaveWhenAuthorityOrReplicaIdentityChangesDuringSave`
  returns a partial committed-effect receipt after scope/identity changes at the
  real save suspension, without pretending the durable edit was rolled back. Both
  use canonical host fixtures, not serialized or live provider evidence.

Scoped pinned SwiftFormat 0.61.1 and strict no-cache SwiftLint both passed for the
changed test file. Whole-tree style remains NOT_PASSED as previously recorded;
full integration, packaged, real vendor and live app gates remain for integration.

### M6 — app-free WorkspaceContext extraction and integration (2026-10-29)

This is the continuation of the single M6 PR #1415, not an additional milestone.
The extraction is implemented. The exact-head validation reconciliation below
supersedes the provisional remaining-gates summary, without erasing historical
failures or certifying the broader #1402/#1408 campaign. Earlier Stage 0
NOT_PASSED entries above describe their historical heads, not the current style result.

#### Surviving owners and retirement

`RepoPromptWorkspaceContext` now owns the dependency-closed WorkspaceContext,
search and CodeMap orchestration implementation, plus required Git materialization,
identity and initialization values. Its dependencies are app-free; UI drafts,
presentation, focus, observation and application policy composition remain in
`RepoPromptApp`. Ten complete test/helper files moved to owning module targets.
The existing automatic-selection ordering golden subsequently moved unchanged
from `RepoPromptTests.ModularizationCompatibilityGoldenTests` to
`RepoPromptWorkspaceContextTests.WorkspaceCodemapGraphFoundationModelTests`.
Settings/provider and app-notification goldens remain with their existing app owners.

`WorkspaceCodemapStructureQueryExecutor` owns query orchestration, not a new store,
graph, cache or lifecycle authority. Existing root/catalog authority, graph receipts,
demand cleanup and post-await revalidation remain authoritative. App adapters retain
wire arguments, invocation authorization, DTO assembly and genuine window state.
`MCPDomainHost` remains the sole standard-progress owner: the unused manager-owned
direct progress state alias, context enum, overloads and send branch are removed.
That retirement is +19/-51 combined across manager and its existing host, including
10 DEBUG-only observation lines for deterministic tests; it is not a new shipping
owner. No VM/bridge or headless campaign completion is claimed.

#### Reproducible move and access evidence

- Original-path preparation ends at `a3cac3d8f2efd3ead5421f7033bdc0c38d955e9a`.
- Pure move: `8025ce3a48a8b1b0d9f2d94a63b8ee2b43ff0a7f`.
- Fixture/style path changes: `d9a789d4cc7dceebcb494d93ae0bd26d75812dc2`.
- Official move audit: **113 moves, zero violations** (103 production, 10 tests/helpers).
  The normalized hash manifest is [m6-workspace-move-manifest.tsv](m6-workspace-move-manifest.tsv).
  Reproduce with `python3 Scripts/modularization_move_audit.py --base a3cac3d8f2efd3ead5421f7033bdc0c38d955e9a --head 8025ce3a48a8b1b0d9f2d94a63b8ee2b43ff0a7f`.
  Its test-discovery counts are null; it is not test parity evidence.
- Preparation includes required assignment-equivalent initializers and access lifts.
  The store recorder is an immutable, initializer-only reference to the existing
  synchronous Sendable recording contract (`package nonisolated let`); mutable
  store state remains actor-isolated. No unsafe annotation or ratchet increase was
  introduced for that boundary.
- Combined contract/extraction integration: `82074771975b52f19e4e26804999fae8d192ebd7`.
  Later compiler fixes added missing direct test imports without widening production
  test hooks. `cc7828ddf22c2fda6e1d14a70330a9f26b6446a9` repairs the structural
  guard's package-qualified function locator and relocates the existing golden.
- `6779a1ab81b80a86a2ca5c9cc0d7d8052863eac5` bounds the existing real-child
  admission fixture's cleanup using prelaunch termination observation instead of
  blocking `waitUntilExit` after suspension. Production admission is unchanged.
  It is integrated by `be9073e082ceed303d3bab4ad41a3e521ca24323`.

#### P0.6 compatibility disposition

1. The 103 moved production files have no `Bundle.main`, `Bundle.module`,
   `Bundle(for:)`, `NSImage(named:)`, standard-defaults, runtime class-name or
   `#fileID` lookup sites. The target introduces no resources or dynamic library
   product. Both packaged executables passed the helper/layout and resource/legal
   validation at the head recorded below; this is not live application evidence.
2. Swift module-qualified reflected names change. The automatic-selection and
   presentation issue sorts compare the same concrete type on both sides, so their
   shared module prefix does not change ordering. The existing automatic-selection
   golden pins case/payload order, including lexical integer order, in the owning
   test target. SearchMatch's reflected regex error diagnostic still comes from
   RepoPromptRegexCore; SearchResults is not a persisted encoding. Symbolicated
   module-frame names are not a persisted identity guarantee.
3. Moved NSError bridges compare system POSIX/Cocoa domains, not Swift-generated
   domains. Existing literal notification names, Codable raw cases and persisted
   keys are unchanged. Relevant existing witnesses include CodeMap golden/artifact
   tests, settings-key goldens and app selection-persistence suites; these are
   named contracts, not a claim of exhaustive serialization coverage.
4. The former app defaults read for `enableRepoFileReplaySignposts` now goes through
   the existing FileSystemRuntimeHooks preference port, composed with the same
   defaults key in FileSystemAppIntegration. This is reviewed preparation, not a
   byte-identical move claim.
5. GitWorkspaceStateAuthority and WorkspaceRootTargetEvidenceCoordinator retain
   one declaration each in one SwiftPM target; app composition injects the existing
   shared actors. No second singleton, store, dynamic image or parallel runtime
   authority is introduced. Separate-process profile ownership remains #1408 work.
6. The manifest and this inventory supersede old app-location rows for this slice.
   Final integrated owning/compatibility results must be recorded before readiness.

#### Measured dependency change (same c47 production baseline)

These compare pristine `c47a23d61b2970625772e0b900252da9b3a2064f` with extracted
production at `1c00dabb44c638d77dd929d054b71e40962c9945`, before the later #1538
main integration. They are not timings or a claim about the entire campaign.

| Metric | Before | After |
| --- | ---: | ---: |
| App Swift files | 1,217 | 1,118 |
| App Swift lines | 665,791 | 576,073 |
| First-party Swift lines | 840,415 | 841,742 |
| App share | 79.2% | 68.4% |
| App-testable importing files | 340 | 330 |
| Compiler-index app file edges | 8,081 | 7,187 |
| Compiler-index wrong-way edges | 1,359 | 1,303 |
| Largest component cycle | 64 | 54 |
| Largest file cycle | 770 | 681 |

The compiler exporter is current (1,118/1,118 sources, no stale or unindexed
sources); it excludes 103 retained index units for deleted paths. The before
index is independently fresh. This is app-only dependency evidence, not a
whole-program cycle proof. The total implementation grew by 1,327 production
lines including preparation/composition; moving 89,718 lines out of App is not
presented as deleting that implementation. No aggregate net-reduction claim.

#### Validation receipts and remaining gates

All jobs use conductor. Queue/global-wait are not build-performance gains.

| Scope / head | Ticket | Result |
| --- | --- | --- |
| Owning module before integration | `816c3c56-173b-4d62-aa68-99f7b7110a9b` | 35 matched, 35 passed |
| Full lint, 1c00dabb | `01ccbe5a-44d2-4329-97a2-6f00eadd4f1e` | exit 0; 0/1,918 formatter drift, strict SwiftLint |
| Debug package, 1c00dabb | `845d1aa9-cc82-443d-a341-9097062f8466` | exit 0; 158s execution, 50m03s queue |
| Release preflight, 1c00dabb | `b0ac5eaf-bbf8-45d1-9e45-1aa49946625f` | exit 0 |
| Universal Release artifact, 1c00dabb | `dcbcb25f-f3a6-4e5b-8d31-f6bf6f15d877` | exit 0; 44m58s execution, 50m27s queue |
| Full suite, 1c00dabb | `17c94933-7b8c-4125-b457-0e96a2ad2e3e` | **not passed**: 4,524 unique passes, one guard failure, then 3,600s timeout in admission child fixture |
| Repaired admission class, 6779a1ab | `30068d4e-5d30-458e-afd5-6ebbf7ae8999` | 19 matched, 19 passed |

The Release artifact is local ad-hoc arm64+x86_64 packaging validation only,
not notarized or distributable. ZIP SHA-256:
`46217966d1dff7268d640cf15d55f4336e0bd52637661b0dd5889a2621d51122`;
external artifact-manifest SHA-256:
`19038f7720e3b29e31f4de4c96e0d866a836e2c22f3a34d1e3cd4c3bece62bfd`.
No visible application launch, remote merge or release publication was performed.
The admission hang's cooperative wait mechanism is supported by existing test
history, not proven by a captured full-suite stack. Its bounded fixture repair
must be checked in the full integrated run; the old timeout remains evidence.

#### Exact source-head reconciliation: `3d03fe5f` (2026-10-29)

Source head `3d03fe5f373f57313ad96c892d679e47313140fd` includes the bounded
buffered-process drain correction. A deterministic process-owner regression first
failed against close-before-drain (`55c7e798`); the repaired process owner passed
33/33 (`c9d11d3a`), and strict lint passed (`821d34c5`). The previously failing
Devin probe passed in the exact-head shard; its original failure is consistent with,
but not independently proven to have been caused by, that output race.

- CI build `8c765e24` and four isolated CI shards `2cafe661`, `012fccf5`,
  `ad0e486d`, `6dd9c626` passed. Listing/receipt coverage verifies **7,600
  identities, including 16 skips**, across 16 targets; it is not 7,600 passing
  test cases. The four prior discovery setup cases passed in these isolated suites.
  All 15 app-free module parity runs passed, **1,190 executed, zero failures**.
- The monolithic `99d9b3c2` at `5dbe9d08` timed out with four discovery setup
  failures; its cause remains unresolved. Isolated shard passes do not erase or
  diagnose it. Earlier `17c94933` and pristine graph-coverage timeout also remain
  historical red evidence. The 113/0 move audit above is not test-discovery parity.
- Provider-package tests `083669c8` passed 34 cases; app product `dfd3d604`, MCP
  product `65347061`, Xcode workspace validation and Release preflight `db0d8a17`
  passed. Exact-head Debug package `67594d42` and validation-only universal ad-hoc
  Release artifact `42a29dc1` passed. Release ZIP SHA-256
  `0dbabd6397b5c0d4423b2b20bbab9aa4308415b9b6f10aa2957fb1d88d28b6e1`,
  manifest SHA-256 `fd76702ca47f8cd946dfb46218bb4280ba95d23606b069dcdef24f78dfde07cb`.
  Packaged helper checks do not establish live MCP.
- With user-approved Debug-only restart (`3172e791`, `4605f0f3`), exact-head basic
  live MCP smoke `61b30de2` passed. Initial `21db94e1` failed with exit 73 before
  the debug listener became ready and remains a failed receipt. This basic smoke
  is not a real-vendor or standalone-headless journey. The assembled two-lane
  journey uses controlled providers and a prepared workspace/window; it is not a
  vendor-socket, inactive-presentation, or no-window proof.
- Fresh compiler-index check at this source head passed: wrong-way app file edges
  1,304/1,360 and largest component cycle 54/66 ratchet; the prior c47-to-1c00
  app-only graph comparison above remains explicitly historical, not a final-head
  whole-program proof. Independent pinned Astra review found no demonstrated
  findings (`/tmp/runtime-m6-astra-review-3d03fe5f.md`, PR comment `6488277784`).
  Hosted CI `40817649592` and Xcode `40817649498` passed for the reviewed head.
- Existing narrow workload witnesses passed: graph publication proportionality
  (`012fccf5`, 18.040s; 16,384-file fixture) and catalog bulk-add 10,000/20,000
  scaling (`ad0e486d`, 5.843s). They are not Repo Bench or a launch/runtime
  benchmark. Repo Bench was removed at `f861d16bb3a14305d1329e079ed393b317fc0508`.

Release validation-artifact execution and sampled process-tree peak RSS were
**4,957.327s / 5,867,683,840 bytes** at pristine c47 and **8,652.404s /
5,606,113,280 bytes** at 3d03 (`42a29dc1`). These are actual receipts, not matched
dependency-cache/host-load experiments. Both logs explicitly clean their Release
output scratch. The final head also incorporates current-main changes beyond
c47, so this pair does not isolate M6. Do not infer a time gain, causal regression,
or satisfaction of the 10% runtime/launch guardrail from these receipts.

#### Bounded warm-cache incremental comparison (2026-10-29)

One sample per head, using the same appended nonsemantic comment
`\n// M6 matched incremental measurement.\n` in
`WorkspaceCodemapGraphStructureModels.swift`, separately restored after each job.
Both heads warmed the selected test and app build first. Conductor receipt process
execution excludes queue time; peak RSS is sampled process-tree RSS at 1-second
intervals. All four measured jobs reported `warmLocal` and zero queue seconds. Each
requested four global-heavy slots from the existing eight-slot configuration;
the campaign did not alter admission capacity for these measurements.

| Command | Before c47 ticket; execution / peak RSS | After 3d03 ticket; execution / peak RSS |
| --- | --- | --- |
| `./conductor test --filter testGraphIndexPublicationWorkStaysProportionalToBatchSize` | `4c724416-daf1-49a4-b62c-43113674b14f`; 112.784s / 2,869,116,928 bytes | `208fbe63-ce29-4cad-af65-9e84cc59ec7a`; 60.596s / 2,444,607,488 bytes |
| `./conductor swift-build --product RepoPrompt` | `757a1e22-6096-46d6-b4bb-47024d5740dc`; 37.928s / 2,486,583,296 bytes | `88e01694-7682-4c57-b197-84c4c70207bc`; 9.500s / 1,034,797,056 bytes |

Before global-heavy waits were 0.006s for each; after waits were 0.009s and
0.008s respectively. The selected test passed exactly one case at each head:
11.613s before and 12.910s after. Before warmups were `6ba72ae6-a047-4c3e-8c9f-7ee92cd524e4`
and `8ee71011-9ff5-4569-83ac-2be7639618f7`; after warmups were
`9423e42e-7073-453e-b2bf-63ad565238d3` and `b44c4b78-0552-43bb-950c-1e86fc2bcdcf`.
The restored source SHA-256 was `32c672097bee9e983cccc47196122cf0c5e3fb8fb85520caf7466a115996f403`
before and `cdd0afe9057708c40711fe0039cb9cc82b14272d04dd2eea28e2151a484b990a`
after; the after backup and restored file matched after both jobs.

These are bounded observations, not an isolated causal speedup: the selected
suite/owning target differs across heads, intervening main changes c47→35 are
included, and only one sample was taken. The app measurement followed the test
measurement and could reuse its compiled cache; cache state is not proof of
identical compiler work. Neither this nor the unmatched Release receipts establish
the launch/runtime 10% guardrail. The monolithic discovery setup failures remain
unexplained. Repo Bench is unavailable, not a passing gate. Exact-head hosted and
packaging receipts above apply to the source head, not subsequent documentation
edits. User review and final merge are separate; M7 still waits for merged M6,
M8 is independent, and #1402/#1408 and snapshot-only Q2 semantics are not closed.

#### M6 integration repair and acceptance boundary (2026-10-31)

This follow-up starts from PR head `0c541c01877fd646ad255ec18d82afd988761f2c`
and normally integrates main `135ffde7` (#1566). The MCP admission-test merge
retains upstream's `ChildProcessExitObserver` implementation and M6's
`RepoPromptWorkspaceContext` import. The superseded `AdmissionChild` helper
must not survive beside the upstream `withAdmissionChild` overload: the newer
helper owns signaling and reaping through one observer and bounded exit wait.
Independent source review confirms that this file differs from the integrated
main file only by the WorkspaceContext import.

The existing assembled contract is now named
`AgentSessionLinkLiveDiscoveryTests.testActivatedTwoLaneContractInSelectedWorkspaceUsesProductionAdmissionAndReturnedCalls`
(formerly `testActivatedTwoLaneContractUsesProductionAgentAdmissionAndReturnedCalls`).
Its helper receives the fixture's expected workspace ID rather than deriving its
expected value from the active workspace under test. Setup, Overseer activation,
lane creation and final cleanup assert that exact selected workspace. The real
serialized ingress, controlled replies, returned bare cursors, recovery replay,
durable effects and unchanged foreground tab/draft checks remain in the journey.
Historical receipts under the old name remain historical; the rename does not
create new executed evidence.

**Historical scope gap, superseded by the Round 3 no-selection test below.**
At this checkpoint, the demonstrated journey required an already selected
workspace and did not attach an NSWindow or change selection. These are distinct
contracts. `AgentSessionLaneMCPToolService` enumerates active window workspaces;
`WindowStatesManager+AgentSessionLanes` and
`AgentModeViewModel+SessionLinkLanes` recheck that workspace before allocation
and retirement. Removing those fences is not a valid test fix. The nonvisual
saved-oversight owner prepares existing saved sessions, with a single-carrier
workspace projection that cannot persist UI placement; it is not an existing
owner for arbitrary new lanes. A bounded no-selection implementation needs
durable lane placement, discovery, authority and retirement coverage. It does
not require completion of the entire separate #1408 campaign. This follow-up
does not waive #1402's acceptance or close that issue.

The following historical performance evidence is retained. Its current
startup disposition is accepted unresolved risk, not a passing measurement;
see the final Round 3 reconciliation below:

- At `0c541c018`, the local 300-chat scale case recorded warm-refresh/menu p95
  of **67.141833/195.427625 ms**, each against **50 ms**. Its 4 restore reads,
  470 visits and 35 publications do not explain the elapsed-time failure. The
  diagnostic and hosted passes demonstrate other successful executions, not a
  cause for this failure. The test matches pinned upstream `76998e93`, which
  narrows the changed surface but does not exonerate all runtime dependencies.
- The five retained fresh-profile Debug launches compared old main `35d141ad9`
  with `0c541c018`, despite the candidate incorporating newer upstream
  `76998e93`. Window-appearance medians **2,585/2,861 ms (+10.68%)** did not meet
  the 10% acceptance budget. Different upstream changes and overlapping heavy
  work prevent attributing that observation to M6. No threshold is changed.
- The `0c541c018` experiment verified bootstrap ownership but did not execute
  its MCP helper probe. The live pass at `3d03fe5f` remains pinned to that head.

The planned follow-up protocol recorded the final candidate SHA and its
integrated upstream baseline, using the same macOS host/toolchain, configuration,
architecture, profile and secure-storage policy. The user later closed the
incomplete experiment and accepted its unresolved startup risk, as recorded
below; the remainder of this paragraph is the historical plan, not pending work.
Finish builds before measurement, establish
exclusive heavy-work admission for the measurement interval, and retain a
predeclared balanced launch sequence (two warm-ups and twenty retained samples
per head). Keep every valid slow sample; record invalid attempts and their
predeclared environmental reason instead of replacing them until the gate
passes. Report raw window-appearance/attachment samples, their p50 and
nearest-rank p95, and sampled RSS separately from exact peak memory. Compare the
unchanged 10% budget without claiming that a numerical pass diagnoses the
historical failure. Run the unchanged 30/300-chat scale case on both matched
heads with load evidence; disposition of the old failure must distinguish an
observed result from an established mechanism.

The existing `Release Candidate` workflow can validate basic live MCP on the
final branch: it packages the artifact, then
`Scripts/smoke_packaged_mcp_roundtrip.sh` proves the launched process owns its
socket and performs `windows`, `initialize` and `tools/list` through that
artifact's embedded helper before shutdown. This is basic packaged live evidence,
not a real-provider or full Overseer journey. Do not run the release-socket
smoke against a Debug bundle or substitute a build/test pass for this check.

Readiness and merge approval remain separate: unresolved acceptance or missing
final-source validation can keep the PR Draft; the user's review is the later
merge gate. The eight passing hosted checks at `0c541c018` are not validation of
this integration repair. Fresh hosted results and the final published SHA belong
in the PR readiness record.

#### M6 current-main integration (2026-11-06)

Normal merge `a6eaa002098525220f349eff1aae31a937777bcd` incorporates main
`348957d5db58e782cd851d591a906d9ef74fac71` into PR head
`5b3bf9f0d8edccc4bea41e6eb5a2780550441998`. Published history is preserved.
The separate local `wt/1401-milestone-1` checkout was inspected read-only:
its `ba3f3cb0b` head has no commits absent from the PR head (168 commits behind),
and its untracked investigation report was not modified or included.

Integration decisions:

- Retain both sides' direct imports in `ResizableTextField`, Oracle-pill routing
  tests and runtime-sidebar tests. Add the missing WorkspaceContext import to
  main's workspace-switch convergence test. Relative to incorporated main, these
  four files differ only by the extraction's direct import.
- Move main's new `WorkspaceCodemapRootPausePolicy` beside its extracted store.
  Its standardized-path keys, defaults values and pause/resume semantics are
  unchanged. Package access permits the store's package initializer defaults and
  existing app-test injection. Forward the new policy argument through **both**
  Debug and Release app composition initializers; the initial merge omitted that
  forwarding, which app-test compilation detected. This new file is additional
  integration work, not one of the historical 103 byte-audited production moves.
- Keep the PR's bounded DispatchIO-backed buffered capture, cancellable input
  writer and sole waiter/reaper ownership rather than restoring main's blocking
  buffered-reader implementation. Adopt main's shared output hooks and timeout,
  retiring the duplicated stream/nonstream hook fields and parameters. Both
  existing cancellation/drain tests and main's captured-output regression remain.
  No timeout was increased, and no cleanup/authority fence was removed.
- Preserve main's operation-count scale-test gates from #1580. Main removed the
  wall-clock assertions; this does **not** waive this PR's recorded 50 ms
  performance acceptance or diagnose the historical failure.

Validation host: macOS 26.7.2 (25G332), arm64, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). All build/test jobs used this worktree's conductor queue;
heavy admission retained the existing machine configuration. No visible app was
launched, stopped or relaunched.

| Boundary | Conductor ticket | Receipt |
| --- | --- | --- |
| App-free WorkspaceContext owning target | `8d5642e9-9a16-4a8d-9cf5-65ed5ef67551` | 34 executed, zero failures; 8m44s execution, 41ms heavy wait |
| Process owning target | `a4308ed5-a633-4204-a69b-007c4813ddd2` | 34 executed, zero failures; 44.6s execution, 7m58s queue, 12ms heavy wait |
| Guardrails | `2d9623a3-4c47-4482-8565-4fe7c87f674d` | exit 0; no ratchet limit raised by this integration |
| Both Debug products, before forwarding repair | `c7cb5067-6582-4f8f-b810-606cce4c9903` | exit 0; 11m02s execution, 1m12s queue; not packaging/live proof |
| Lint after forwarding repair | `f4aa9f01-de86-46e2-b5d5-fe875abe20d8` | exit 0; 0/1,943 files need formatting; strict SwiftLint |
| Both Debug products after forwarding repair | `e0a7ca64-69b3-4e78-b263-69fb56d04f2d` | exit 0; 26.5s execution, 48.4s queue; not packaging/live proof |
| Broader full suite | `6b0ec11d-99a7-443b-9580-e8b035fc956c` | timed out at 60 minutes, exit 124; 3,125 completed passes, 10 skips and 4 failures; incomplete |

Scoped pinned SwiftFormat ran on the eight integration-owned Swift files and
changed none. Initial lint `a42134a9` failed because pinned SwiftFormat was absent;
the repository installer supplied 0.61.1, then full lint passed (`52c7598d` and
the post-repair ticket above). Initial app-test ticket `b0de49dd` failed compilation
at the missing policy-forwarding argument. The dependent full-suite attempt
`3bc60398` was canceled, not passed. An earlier selector correction canceled
`53e97b37` during package preparation; it is not test evidence.

Post-repair focused run `211d5c13-c9e5-4271-b062-30a56799aa3f` is **NOT PASSING**:
169 passed, 2 failed, 4 explicitly skipped (175 named cases; auxiliary zero-match
bundles add no coverage). Failures are:

- `CodemapAutomaticSelectionGraphNativeTests.testFilesystemSiblingRootsRemainIsolatedAfterWatcherEdit`:
  line 1236 returned `[]` instead of `AlphaReplacedProps` after overlay publication.
  The test differs from incorporated main only by its WorkspaceContext import.
  Isolated reproduction `8483edd8-cbb4-44ba-adb1-a50b11af9834` executed that one
  test and passed in 1.043s (58.6s job). This does not diagnose or erase the failure.
- `SessionAdminWorktreeRecoveryTests.testStandaloneIdentifyingBindStillRefusesTwoOwningCheckoutsWithoutRepoRoot`:
  fixture setup timed out waiting for `foreground drafts published` at 3.0s.
  Isolated reproduction `0c9b4997-8098-42fc-91e2-3d631bc0e8fa` executed that
  one test and passed in 3.702s (47.0s job). No deadline, retry count or assertion
  was weakened; the mixed-run failure remains unexplained.

The 30/300-chat diagnostic in that same run retained twenty samples per case.
Nearest-rank refresh/menu p95 was **4.960041/2.605875 ms** at 30 chats and
**49.806/71.928959 ms** at 300 chats. Restore was 71.047375/262.1375 ms;
both cases recorded four restore reads, 470 visits and 35 publications. The
300-chat menu result still exceeds the recorded **50 ms** acceptance budget even
though main's operation-count test passed. These are candidate-only observations
from the integration suite, not an exclusive-load matched baseline experiment
or an established explanation of the historical failure. Raw samples remain in
the ticket's `OVERSIGHT_SCALE` log lines.

After the successful isolated test regenerated the source fingerprint,
`python3 Scripts/modularization_index_graph.py check` passed at **1,304/1,360**
wrong-way file edges and **54/66** cycle components. An earlier query made during
an active app-index build correctly refused unproven freshness; it was not a pass.

The bounded local Oracle resolution review found no behavioral regression; it
noted optional duplicate-test and test-hook deadline-order cleanups. Both were
left unchanged to preserve upstream coverage and existing bounded-drain semantics.
This is not the overseer's separate independent review or an approval to merge.

At this historical checkpoint, no selected-workspace fixture was relabeled as
#1402's workspace-free contract. Round 3 subsequently added the app-side
no-selection witness. The matched launch experiment was authorized, partially
executed, then closed by the user with startup risk accepted; it is not pending
further lifecycle authorization or samples. The 10% budget and old slow samples
remain unchanged; current disposition is recorded in the final reconciliation.

#### M6 Round 2 baseline investigation (2026-11-06)

Candidate source `4a53016cdb4e60ced9d235d795ee6741e8b2fb8f` was compared
with its incorporated main `348957d5db58e782cd851d591a906d9ef74fac71` in an
independent detached worktree. The baseline had its own conductor queue/build
output; machine-wide heavy admission was not bypassed or reconfigured. It was
moved from the candidate's ignored `.build` directory to ignored `build` before
any successful candidate cache publication, to avoid including the nested
checkout in conductor's recursive build-cache snapshot. No pre-existing other
worktree or dirty primary was changed.

**Full-suite result is incomplete, not green.** Ticket `6b0ec11d` reached its
unchanged 60-minute execution timeout after 3,125 named passes, 10 skips and four
failures. The two original mixed-run cases had not yet run. Failures were:
`AgentProjectionRepairIdempotenceTests.testRepeatedProjectionAtThreeWindowScaleStaysWithinBudget`
(6.186231166s versus 5s),
`AgentSessionLinkCatalogScaleTests.testWarmActualRouteCatalogAtApprovedScale`
(p95 558.0045ms versus 500ms),
`AgentSessionLinkLateQualificationTests.testAvailabilityProducerABAVetoesRetainedOffer`
and `AgentSessionLinkLiveDiscoveryTests.testW4ProvisionalDeclarationNeverAppearsInAnyPublishedSnapshot`
(both timedOut(4)). Execution last entered
`AgentTranscriptTurnCacheGroupingTests.testLargeProjectionGroupingMatchesHistoricalSlicesWithinBudget`.
These failures are recorded, not attributed solely to machine load.

**Original mixed failures:**

- Candidate diagnostic `b6fa38b1-f86e-4395-8d02-717aca756952` executed 46 cases:
  39 passed, seven CodeMap cases failed; WorktreeRecovery passed 27/27.
  The original sibling-root failure reproduced. At overlay generation 9, the
  graph was sealed but partial: one supported, zero classified, one pending,
  zero contributed, no symbols. Presentation had returned fresh text after
  0.310866708s. No native watcher callback was recorded before the assertion;
  the manually replayed invalidation completed in 0.0036605s. This contradicts
  a late native-watcher explanation for this observation. The pending graph
  publication/demand ordering was unresolved at this checkpoint (the Round 3
  held-index witness below resolves its classification); no desired-symbol polling,
  deadline increase or speculative production fix was substituted.
- Candidate exact diagnostic `a6f45827-b3f7-4189-8988-e519241dfd8c` passed the
  original worktree method but failed the sibling test earlier, while initially
  resolving artifacts, before the edit. It does not exonerate the original failure.
- Unmodified baseline mixed run `886c05f7-3ef7-4d4b-8549-1d7dd87e4e0f` executed
  173 cases: 165 passed, four skipped, four failed. All failures were the same
  `foreground drafts published` fixture timeout, in
  `testCreateDefaultBindKeepsARepositoryPathThatReadsAsASelectorLiteral`,
  `testCreateDefaultBindUsesTheElectedRootWhenTwoCheckoutsShareItsRepository`,
  `testCreateRecoverySelectorKeepsALinkedPrimaryCheckout`, and
  `testUnopenedLaneModelAndEffortUseItsWriterDespiteEarlierWorkspaceReplica`.
  The original standalone and sibling-root methods passed. Cold baseline job
  `2dc4b950` timed out compiling and executed no tests; it is not a pass.
- Baseline diagnostic `89f56efb-c8fa-48ef-91cb-875918d7bcce` executed 46 cases:
  43 passed, three failed. Worktree fixture failures occurred in
  `testBusyCreateBindRecoveryCallCarriesTheElectedRootWhenTwoCheckoutsShareItsRepository`
  and `testCreateDefaultBindCompletesForASoleRepositoryWhosePathReadsAsASelector`.
  Captured transitions show the replica draft initially present, then the target
  tab absent from its active-workspace projection within 18/50ms. The live draft
  strings and active tab IDs remained correct; switching and selection-mirror
  flags were false. Explicit snapshot publication after timeout did not restore
  the missing projected tab. Thus this is not merely a delayed 120ms debounce:
  asynchronous projection replacement invalidates the fixture's directly
  installed replica. The exact replacing producer is not yet identified.
  WorkspaceManager differs from this baseline only by its extraction import.
  The inherited fixture failure mode is proven; no production repair is claimed.
  The other failure was
  `testGlobalDisableCancelsDiscoveryAndIndexingAcrossStoresAndPreservesManualPause`.
  The original sibling-root method passed again with generation 9 fully classified;
  baseline reproduction of the original empty graph remains absent.

Diagnostic modifications only captured state and rethrew original errors;
original assertions/deadlines were retained. They were removed after the jobs.
Their logs/patches remain local, not shipped runtime machinery.

**Unchanged scale acceptance, twenty retained samples per case:**

| Source/run | 30-chat refresh/menu p95 (ms) | 300-chat refresh/menu p95 (ms) |
| --- | --- | --- |
| Candidate `211d5c13` | 4.960041 / 2.605875 | 49.806 / 71.928959 |
| Candidate full-suite `6b0ec11d` | 6.585208 / 3.963958 | 34.610916 / 57.253834 |
| Incorporated main `886c05f7` | 9.528166 / 3.190791 | 54.340833 / 117.786416 |
| Candidate after late merge `dbfaafe5` | 6.877542 / 2.462917 | 45.69475 / 147.639083 |

The benchmark source is byte-identical across these heads. Both baseline and
candidate exceed the **50ms** menu p95 limit. Each recorded four restore reads,
470 candidate visits and 35 publications. Different, heavily contended host
intervals prevent attributing the difference to this PR or claiming improvement.
All slow samples remain evidence; the acceptance limit is unchanged. The later
matched non-quiet observations and final disposition appear below.

**Workspace-free distinction:** the existing canonical two-lane tool contract
omits the `workspace` argument but installs an active workspace and uses a
controlled endpoint host. It can prove returned bare cursor replay and cleanup,
not production creation with zero active-workspace owners or provider completion.
`AgentSessionLaneMCPToolService.resolveDestination` filters window candidates by
`activeWorkspace`, returning `callerWindowHasNoWorkspace` with no eligible owner.
Allocation in `WindowStatesManager+AgentSessionLanes` and
`AgentModeViewModel+SessionLinkLanes` rechecks that authority. A positive zero-owner
proof needs an implemented durable placement/admission/discovery/retirement owner
independent of active window selection, followed by a real route contract. Removing
these guards or launching an app is not a substitute. By the user's final scope
decision, zero-owner and standalone operation are deferred to #1408; #1402's
app-side without-selecting-a-workspace contract is covered by the later
no-selection test. No ownership guard was removed.

Release Candidate run [42057513544](https://github.com/repoprompt/repoprompt-ce/actions/runs/42057513544)
passed at exact source `4a53016c`: release package, embedded MCP roundtrip, and
macOS 15 x86_64/arm64 artifact smokes. It is ancestor-head evidence after the next
merge, not final-head CI, a real-provider journey, or the matched local launch
experiment. At this checkpoint local visible-app lifecycle had not been
authorized or performed; the later approved experiment is now closed.

The late normal merge incorporates `5a3f112253508c972b0952a95ea9c56e90b909b0`
(#1632 Re-prompt, #1619 verified recovery backups, #1634 input focus). Its sole
text conflict was additive imports in `WorkspaceProjectionDecodeTests`; both
main's SettingsCore import and M6's WorkspaceContext import are retained.
Main's recovery-backup refusal/authority and session-scoped UI changes remain
intact. No threshold, guard, or ratchet is relaxed.

Post-merge focused ticket `dbfaafe5-4e46-4887-919c-327f2c1279ce` completed with
**265 passes, one explicit diagnostic skip, zero failures** (266 named cases).
Coverage includes 20 DomainRecoveryBackup cases, 10 WorkspaceDiskWriterContract,
six DirectHeadlessWorkingDirectoryBinding, the Re-prompt suites, 23 titlebar
safety, 47 first-lane-save, 23 production-organizer, four workspace-switch and
six workspace-projection cases (the opt-in measurement matrix was skipped).
The canonical two-lane bare-cursor/retirement contract passed in 0.894s; the
production first-lane full-document-adoption case passed in 6.440s. Neither is
a zero-active-workspace or real-provider proof. The original CodeMap failure
was not included in this merge-boundary filter and remains unresolved.
Post-merge lint `2ad7380c-953e-4c92-95a7-770868580938` passed: no formatting
drift in 1,946 files and strict SwiftLint. Oracle re-review could not run because
the MCP transport was closed; no visible-app restart was used to repair it.

Both Debug products passed in `94fbfe87-75a5-444e-94e9-cebe7b749b8b`
(61s execution after 39m09s queue). The fresh post-build compiler-index check
passed at **1,304/1,360 wrong-way file edges** and **54/66 cycle components**.
This is build/index evidence, not packaging or visible-app proof. Mandatory
staged-index commit and outgoing-range push preflights are publication gates;
final-head hosted status is reported on the PR, not inferred from these receipts.

#### M6 Round 3 measurement checkpoint (2026-11-06; in progress)

Source candidate is `5b1fc7aa83b8490ff7a2747f71a303feb3767c6a`; the comparable
incorporated-main baseline is now `5a3f112253508c972b0952a95ea9c56e90b909b0`,
not Round 2's older main. Both checkouts were clean before this documentation
checkpoint. The benchmark source is byte-identical. At the initial observation,
load averages were 72.56/75.75/72.01 and M8 owned heavy test ticket
`2d3b90d6-4c26-4d3c-9913-474ba3b4ce86`; no competing measurement was started.
M8 has priority and is awaited, never cancelled. Exact-head normal CI, Xcode
validation and Release Candidate `42112251102` have all completed successfully;
this does not close the unresolved acceptance gates above.

Predeclared menu protocol: ordinary arm64 Debug test builds with the same
host/toolchain and unchanged benchmark. Finish preparation on both heads first.
Run three independent invocations per head in A/B/B/A/A/B order (A=main,
B=candidate); each existing test discards its own first warm-up and retains
20 menu samples at 300 chats. Preserve all 60 retained samples per head, report
per-run and pooled nearest-rank p95 plus median/range, against unchanged 50ms.
Record system load/CPU and global heavy-holder observations before and during
measurement. Admit measurement only after no other active/queued heavy jobs
(including M8), one-minute load no greater than logical CPU count and CPU idle
at least 80% across three observations 20 seconds apart. A new competing job
marks that interval contaminated, not passing or quietly discarded. If a valid
quiet interval cannot be established, report that limitation rather than label
busy measurements quiet. No admission capacity or timeout is changed.

The overseer relayed user approval for the matched visible-debug-app launch
experiment, restricted to its needed coordinated lifecycle actions; concrete
lifecycle permission was obtained before execution. That approval is now
withdrawn and the experiment closed. The historical plan was two warm-ups per
head then 20 retained samples
per head in balanced A/B/B/A blocks, same prebuilt Debug configuration and
in-memory secure-storage policy, fresh isolated profile per sample. Retain
Startup phase window-appearance/attachment elapsed values and sampled RSS
(separately from true peak memory), compare the unchanged 10% median budget,
and keep invalid attempts with their reason. No compilation overlaps measurement.
At this checkpoint conductor forwarded HOME but not CFFIXED_USER_HOME; a local
Foundation probe confirmed HOME alone still resolved the real user home. The
subsequent caller-only forwarding commit and actual app-held lease checks below
resolved that isolation prerequisite. Final scope is #1402 app-side no-selection
coverage, with zero-owner/standalone operation deferred to #1408 by user decision.

Preparation completed: baseline ticket `94293ed0-e591-4f57-9665-34c93f9ec719`
and candidate ticket `a0a90026-e4bb-49f0-a0fb-d80d4aab6709` each executed and
passed the one intended benchmark method. These are preparation/warm-up runs,
not retained quiet measurements. Two subsequent three-observation quiet gates
failed despite empty global heavy and M8 queues: first one-minute loads
14.17/10.66/31.43 with CPU idle 24.75/61.12/11.29%; after a five-minute cooldown,
loads 15.59/11.50/9.40 with idle 59.57/45.70/62.25%. Read-only process inspection
showed desktop/browser/backup activity, not another conductor job. No process
was stopped to manufacture a quiet window. Raw gate observations are retained
locally under ignored `build/m6-round3-receipts`. These were pre-measurement
checkpoints; later retained samples are reported below.

Round 3 review follow-up: the user permits matched **non-quiet** measurements
under recorded load if bounded quiet attempts continue to fail; unrelated desktop
and backup processes are not touched. Workspace-free app-side lane creation remains
in #1415 under #1402, not deferred to #1408. Caller-only `CFFIXED_USER_HOME`
forwarding and its focused regression are approved as a separate tooling commit;
actual isolated Foundation home resolution remains a prerequisite for launches.

Verified the actual archived log for exact-head CI `42112245223`, root shard 1:
20 retained 300-chat menu samples have nearest-rank p95 **25.016875ms**, median
**16.989354ms**, with the same **4 reads / 470 visits / 35 publications**.
The benchmark, `AgentSessionLinkRuntimeBridge.swift`, and
`AgentSidebarOversightMenuModels.swift` have no diff from incorporated main
`5a3f1122`. This is passing hosted evidence against 50ms, not a claim that the
contended local runs passed or that every transitive dependency is unchanged.

The complete `Scripts/test_conductor_smoke.py` suite passes **8/8** (including the
new caller-only home regression). The unsandboxed `make conductor-selftest` run
passed all portable phases but failed its final local-production-installer suite:
`test_two_consecutive_installs_keep_fingerprint_generation_and_designated_requirement`
hit its existing 15-second fixture subprocess timeout (17 other cases passed).
The earlier sandboxed attempt additionally lacked process-inventory permission.
Neither complete selftest attempt is reported as passing; no real app lifecycle
action was performed by these mocked installer tests.

Tooling-only commit `e832aeb0d1502564c138ae7e43de650827fffd78` adds that single
forwarded key and the caller-present/caller-absent regression. Commit preflight
passed. A Foundation probe with both HOME and CFFIXED_USER_HOME set resolves the
isolated `/tmp/rpce-1415-home-probe`; HOME alone did not. This probe alone was
not packaged-app isolation evidence; subsequent pilots and valid retained
samples verified the actual app-held lease inside each isolated home.

Focused ticket `3d850405-4de1-4320-bcc2-6ad42a27c017` executed **2/2**, zero failures:
- `AgentSessionLinkLiveDiscoveryTests.testActivatedTwoLaneContractWithoutSelectingWorkspaceUsesProductionAdmissionAndReturnedCalls`
  passed in 13.463s. Ordinary app initialization supplies its System/Default
  workspace; the variant never creates/selects/switches a workspace or assigns
  activeWorkspace. It sets up an observer chat in that existing owner, then uses
  serialized production MCP admission, explicitly authorized Overseer activation,
  two `create_lane` calls with no workspace argument, controlled-provider
  `LANE_OK` replies through the real runner, actual bare cursors and successor
  replay, returned group-order recovery, and retirement. This is app-side
  no-user-workspace-selection evidence, not a zero-workspace standalone backend
  or a packaged/live-provider run. No production ownership guard changed.
- `CodemapAutomaticSelectionGraphNativeTests.testFilesystemSiblingRootsRemainIsolatedAfterWatcherEdit`
  passed in 1.708s with a causal gate. Hold only the edited root's background
  graph-index catalog read. Exact presentation still returns its fresh symbol.
  Once presentation releases its operation-owned demand, the graph generation
  barrier returns an empty, incomplete replacement snapshot. Release the index
  read and join its completion: the replacement symbol is present, with sibling
  isolation and no sibling rebuild intact. The competing transition is
  `WorkspaceCodemapPresentationCoordinator.release` →
  `cancelCodemapArtifactDemand` → `finishCancelledCodemapArtifactDemand` →
  `revokeReadyArtifact`, independent of background index completion. The old
  generation fence did not join that independent work. The subsequent main replay
  below establishes the inherited invalid-test-synchronization classification.

Two more quiet gates encountered priority M8 tickets `3143054f...` and
`62f10727...`; both were awaited. Matching Debug packages were then queued for
owned bundle paths with the same alternate-in-memory secure storage. The shared
scheduler admitted both; at load 307.73 another M8 ticket `c3f8892f...` was waiting.
Candidate package `df992bda...` was deliberately cancelled (exit 130, not a pass)
to free its slots for M8. No capacity setting was changed, no M8 job cancelled,
and none of this interval is measurement evidence.

Main replay `afaa2910-fee8-422a-a5ca-bda122198bcd` executed the same held-index
sibling-root witness against incorporated main `5a3f1122`: **1/1 passed, 1.128s**.
Only the test patch was applied; main production code was untouched, and that
patch was reversed afterward (clean baseline). This establishes an **inherited
invalid test synchronization**, not an extraction-owned production regression:
the old helper waited for an applied overlay generation, which can be the demand
revocation, not for the independent index's replacement publication. It does not
prove a particular native watcher scheduling order in the historical run.
The corrected witness also asserts the held index is not already complete and
checks the sibling build count again after index completion. No retry, timeout
increase, or production behavior change is used as the fix.

The bounded Oracle delta review found no production defect but identified test
harness hardening: abort before mutating a non-System or leftover-fixture
workspace; catch each session deletion failure separately so restoration still
runs; read back restored tabs and confirm each known fixture session is absent;
record returned lane IDs immediately for cleanup; and recheck sibling builds
post-index. These changes were applied and the final family validation below
passed 51 cases with four opt-in skips.
The serialized contract uses **production socket admission with fixture-seeded
run state**, a seeded observer/chat/model catalog and controlled provider replies.
“No workspace argument” applies to lane creation, not subsequent explicit
workspace administration. “Only returned cursors” describes the positive wait
path; the separate expired-cursor adversarial probe deliberately invents a handle.
A lost create response could leave an unrecorded lane; this fixture does not claim
to prove crash/lost-response cleanup. Restoration occurs under the serial MCP
test lease and restores content, not the original revision counter.

Baseline isolated app package `1f7f6162-eca7-4c51-ab66-4f3ad1d4089b` completed
successfully, including signing/layout/embedded-helper checks; it did not launch
an app. Candidate package `e6e1a87f...` subsequently completed. Actual packaged
home isolation was verified through the app-held `.repoprompt-ce-debug-seed.lock`
whose path derives from `AppProfileLocations.current.homeDirectory`, before
accepting each valid retained launch measurement.

Final test readback uses the existing canonical snapshot decoder and compares
saved bytes with that snapshot, restored composed/stashed tabs and active tab,
and absence of all recorded fixture sessions. An intermediate ticket
`627fed71...` failed compilation because the initial assertion used a private
cache API; it ran no tests. Corrected ticket
`124b2f9c-b491-46ff-9520-46047c9bcdd6` executed **55 cases: 51 passed, 4 opt-in
skips, zero failures** (36 LiveDiscovery cases including skips, 19 CodeMap cases).
The no-selection journey passed in **12.079s**, selected-workspace journey in
**12.007s**, and held-index sibling-root witness in **0.094s**. Final lint ticket
`698b8811-6303-4439-8844-9d9847982106` passed: **0/1946 format drift** plus strict
SwiftLint. The main replay patch was byte-identical to the final CodeMap patch
(SHA256 `c1104bb2d6de36200948b5cce6eb00d97d95e3130e8a99042a2224787bbc3ca6`).
The test-only changes are commit `37744852d7eda2494308543f67229ac3f46649a6`,
after a passing staged-index preflight. Together with tooling commit `e832aeb0d`,
these are the new code/test commits requiring review beyond published `5b1fc7aa8`.
M8 ticket `5148c134-1080-4e59-99b4-139a80024e23` finished at its one-hour timeout
(exit 124); that is not our validation pass. A final bounded quiet gate observed
no heavy holder initially, loads **6.14/5.78/5.31** and CPU idle
**41.52/61.13/36.89%**, so it failed. M8 started another suite
`71fa80d3-2069-4500-8300-82a50dbee3f8` during the third observation. The
predeclared six-run A/B/B/A/A/B menu batch waited on that suite; subsequent
**non-quiet** measurements, contamination exclusions and replacements are
reported below.
The overseer has coordinated no further M8 heavy submissions until the matched
menu and launch batch finishes. Subsequent ticket waits are bounded to at most
ten minutes per call and repeated while needed, never interpreted as passes.

The checkpoint publication pushed these validated commits and the ledger so
hosted CI and fresh-session review could proceed while M8 finished. No main
merge was needed. The candidate bundle was later prepared after menu
measurements. The approved launch experiment was partially executed and then
closed by the user; its unresolved startup risk is accepted, not passed.
Publication is not readiness, and the PR remains Draft for manual user merging
only. Under the final docs-only instruction, report any conflict rather than
merging main.

### Round 3 follow-up: exact-head CI and corroborating receipts (2026-11-06)

Published head is `bc235c22c82aba5511f09a88cc408bf133d4dc87`; it remains
Draft and mergeable. Independent follow-up review reported no new P1/P2 code
defect and accepted the scoped no-selection and CodeMap witnesses. No code has
changed since that review.

CI run `42154839579`, attempt 1, failed its Build and Static Gates job
`127687369398` during checkout, before immutable-candidate verification or any
build/static gate. The actual check-run annotation says: **"GitHub Actions has
encountered an internal error when running your job."** The separate notice
reports macOS arm64 capacity constraints. `gh run view --log-failed` returned
`log not found: 127687369398`; missing logs alone were not the classification.
Job JSON shows setup succeeded, checkout left in progress, and every later step
pending. Raw job, annotations, and log-fetch error are retained under
`build/m6-round3-receipts/ci-bc235c22c/`. This is an evidenced infrastructure
failure eligible for the integration-v3 failed-job rerun, not a source pass.
Generated Xcode Workspace, Portable Checks, Secret Scan, and Declare Integration
Candidate succeeded on this head. Required root validation was incomplete at
this checkpoint; the final readback below confirms all 11 checks passed.
After a successful clean-tree push safety preflight (raw
`ci-bc235c22c/rerun-preflight-clean.txt`), `gh run rerun 42154839579 --failed`
was accepted. On attempt 2, Build and Static Gates job `127701183715`
subsequently **passed**; four root shards were then queued. This is not yet an
overall CI pass. The ledger addition was preserved
as an exact patch, temporarily removed for that clean-tree gate, and restored
unchanged afterward; no code or commit changed. The initial sandboxed preflight
could not evaluate Swift package metadata, and a second gate correctly refused
my in-progress ledger edit; neither failure was bypassed.

The earlier smoke and Foundation statements had only transcript output, not
reviewer-accessible raw receipts. They were rerun at this exact published head:

- `python3 Scripts/test_conductor_smoke.py`: **8 tests, 0.008s, OK**, exit 0.
  Raw `build/m6-round3-receipts/conductor-smoke-bc235c22c.txt`, SHA256
  `fc23540c8545d4075fe2f0420accd022e74e5566176c3bd4c597964ff02c2e14`.
  This is a manually invoked Python suite, not a claim that hosted CI enrolls it.
- `/usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSHomeDirectory().js'`
  with both `HOME` and `CFFIXED_USER_HOME` set to a fresh owned
  `build/foundation-vqotwqyu` directory returned that exact absolute directory,
  exit 0. Raw JSON includes command, environment values, output, timestamp, and
  comparison in `build/m6-round3-receipts/foundation-home-bc235c22c.json`, SHA256
  `f024b6a2e125f8286fdf3770031b152dbc9db04a80e50f7e30627f822af6b5e5`.
  The isolated directory was removed afterward. This probe itself launched no
  app and did not prove LaunchServices forwarding. Subsequent pilots and valid
  retained launches verified the app-held seed-lock/profile path inside fresh
  isolated homes. Omitted, empty, and real-home values never count.

The full local conductor selftest remains **failed**, not superseded by these
focused passes or the later hosted CI success. Its retained unsandboxed log is
`build/m6-round3-receipts/conductor-selftest-unsandboxed.txt` (SHA256
`325be001ac4a9d52ac4e78b5961a09068213d0e93432f7f2304706d91d72ad2e`).
Its installer fixture
`LocalProductionInstallerTests.test_two_consecutive_installs_keep_fingerprint_generation_and_designated_requirement`
exceeded the existing 15-second subprocess timeout; 17 other installer cases
passed. The exact historical slow subprocess phase was not retained, so the
latency cause is **unlocalized**, not asserted to be machine load.

Source causality is narrower and established: this fixture copies only
`install_local_production.sh`, `local_signing_identity.py`, and
`resolve_full_xcode_developer_dir.sh` into a temporary fake repository, supplies
fake packaging/security/signing commands, and invokes the installer with
`subprocess.run(["bash", ...], timeout=15)` directly. It never invokes conductor
or its changed environment snapshot/prepare path. Those three files and the
fixture itself are byte-identical to incorporated main `5a3f1122535`; hashes are
retained in `build/m6-round3-receipts/installer-source-identity.json`. Therefore
this fixture timeout is not caused by the new conductor forwarding line. An
unchanged focused rerun passed **1/1 in 10.578s** on the PR and **1/1 in 7.085s**
on main; these are corroborating executions, not an explanation of the timeout
or a full-selftest pass. Their raw outputs and command manifest are retained as
`installer-focused-bc235c22c.txt`, `installer-focused-main.txt`, and
`receipt-manifest-bc235c22c.json` in the same receipts directory.

M8 `71fa80d3...` was the priority heavy job at this checkpoint. The bounded batch
waited on active M8 tickets and required an idle heavy queue before sampling.
Subsequent results and the user's closure of the incomplete launch experiment
are recorded below. These ledger-only follow-up notes do not change either
measured code head.

The first post-M8 sampling attempt at 05:56 UTC was refused **before submitting
any benchmark**: M8 was idle, but the machine-wide queue contained `d922ee5a...`
(fix-1646) and `fab2d377...` (PR1539 review). Recorded load1 was **84.77** on
8 CPUs and CPU idle **1.58%**; raw precheck is in `a1-console.txt`. No menu
observations were discarded or counted as passes. The batch now waits on all
machine-wide heavy tickets as well as M8, with waits bounded to 600 seconds;
`a1r` denotes the first actual sampling submission after this refused precheck.
The fix-1646 job later returned cancellation (130) by another actor; this lane
did not cancel it. CI attempt 2 subsequently passed root shards 1, 2, and 4;
shard 3 was still queued at that checkpoint. Subsequent exact-head readback
confirmed **CI run 42154839579 attempt 2 completed SUCCESS**: all four root
shards, Build and Static Gates, Style, Portable Checks, Secret Scan, Declare
Integration Candidate, and Sentry Build and Privacy succeeded. Raw state is
retained in `ci-bc235c22c/attempt2-progress.json`.

The sandbox denied `top` on the next precheck (`a1r-console.txt`), again before
submission. With approved observation access, load fell below 50 and baseline
run `a1s` / `df8807f1-d459-42a8-894f-7a7ce7413ff3` executed. Its 20 observations
are retained, but **excluded from the matched comparison due to competing heavy
execution**, not due to their values: fix-1646 ticket `26261ca4...` acquired slots
at 07:11:14 UTC, while this test's first-test receipt was 07:11:39 UTC. The guard
had observed an empty queue before submission. The batch paused for that ticket,
and an additional uncontended baseline invocation is required; the contaminated
run remains visible in the final report. App launches occurred only in the
subsequently authorized experiment, now closed.

#### Matched menu observations and pre-launch checkpoint

The bounded high-load gate waited until load1 fell below 50; it did not exhaust
its 30-minute allowance. Samples remain **non-quiet**, not idle-machine proof.
Both builds are Debug on the same machine/toolchain, main `5a3f1122535` versus
PR `bc235c22c`. The benchmark and direct menu path are unchanged. Each invocation
retained 20 observations after its built-in warmup, with counters **4 reads,
470 visits, 35 publications**. Full values, raw conductor tickets/status/log
paths, CPU snapshots, and 1-second heavy/load monitoring are retained under
`build/m6-round3-receipts/`; `menu-summary.json` consolidates them.

| Head / invocation | Ticket | Median ms | p95 ms | Observed test-window load1 |
| --- | --- | ---: | ---: | ---: |
| main a2 | `2a869e09-51f6-4147-987c-dda4dd2b8d1d` | 23.1043 | **58.0227** | 29.83–31.73 |
| main a3 | `b686dc76-62d8-467e-9a03-13e00d633215` | 15.8069 | 41.5140 | 17.04 |
| main a4 replacement | `20b465d6-d309-4648-ad2d-957cc62539d9` | 19.5990 | 23.8392 | 17.63 |
| PR b1 | `629b518a-f5a5-4368-91bb-d632f02850d5` | 15.1009 | 16.3803 | 20.10–21.33 |
| PR b3 | `cbc6ba13-5686-4311-8d65-9503134943f1` | 23.8636 | 28.6993 | 21.18–21.63 |
| PR b4 replacement | `366d1443-d70e-490a-9d51-f5ac9f4c3aac` | 24.8884 | 30.4739 | 12.94–13.55 |

Pooled **60 observations/head**, nearest-rank p95: main **41.513958 ms**,
PR **30.197458 ms**, both below the unchanged **50 ms** limit. Main range
**14.981666–481.325333 ms**, median **21.7637295 ms**; PR range
**14.838–31.6045 ms**, median **23.124979 ms**. The PR median is about 6.25%
higher, while its p95 is lower; non-quiet runs with materially varying load do
not isolate causation or establish median equivalence. There is no observed
p95 regression requiring a production fix. Main invocation a2 individually
fails the 50 ms p95 budget; it was retained, not retried away. Pre-run CPU idle
was only 3.70–45.28% across accepted runs.

Two invocations remain separately visible but are excluded from matched pools
because another heavy holder was observed during the recorded test window:
main a1s p95 **27.816833 ms**, PR b2 (`7b85de08...`) p95 **32.359958 ms**.
Replacements were selected for this scheduling reason, not their timing values.
Other jobs that appeared only outside the test window are recorded, not hidden.
The window is conservative `firstTestStarted..processFinished`, based on daemon
output receipt timestamps; monitoring is sampled at 1 second, not a claim of
continuous scheduler instrumentation. Accepted order after exclusions is
B/A/A/B/A/B rather than the originally planned A/B/B/A/A/B; all raw runs remain
available. No quiet-machine claim or threshold change is made.

Candidate package ticket `e6e1a87f-cdb1-4500-a4cf-add748ae2f80` completed after
the heavy queue became empty. Its provenance records commit `bc235c22c` and
`dirty: true`; dirty contents were not captured, so it is not a clean exact-tree
artifact attestation. Main's prebuilt bundle records clean `5a3f1122535`.
The actual app-held profile lease and Foundation probe matched each fresh owned
home for both pilots and all 20 valid retained launches. The experiment is now
closed and incomplete, with accepted unresolved startup risk as detailed below.

### M6 final evidence reconciliation and accepted startup risk (2026-11-06)

**Disposition: the user accepted the unresolved startup risk. It is not a
pre-merge blocker, but it is not a passing startup result. A 10% regression is
not excluded.** Reopen on a reproducible matched slowdown over the unchanged
10% budget or evidence of added startup work. The experiment is closed: the
user withdrew launch/stop approval and requested documentation only. No more
benchmarks, heavy jobs or app lifecycle actions are authorized by this task.
Required review remains open; the PR remains Draft, with manual user merging
only. The reviews were fresh **Astra sessions**, not a different model and not
a human review; fresh-session findings do not satisfy that outstanding review
requirement by themselves.

**CI verified at `bc235c22c82aba5511f09a88cc408bf133d4dc87`: all 11 checks passed.**
[CI run 42154839579](https://github.com/repoprompt/repoprompt-ce/actions/runs/42154839579)
completed successfully on attempt 2, after the evidenced GitHub internal
checkout error and policy-supported failed-job rerun documented above.
[Xcode run 42154839532](https://github.com/repoprompt/repoprompt-ce/actions/runs/42154839532)
also passed. [Release Candidate 42112251102](https://github.com/repoprompt/repoprompt-ce/actions/runs/42112251102)
passed at ancestor `5b1fc7aa83b8490ff7a2747f71a303feb3767c6a`.
`git diff 5b1fc7aa8..bc235c22c -- Sources` is empty: application source is unchanged
since that Release Candidate; conductor tooling and tests did change. This is
ancestor release evidence, not a release run on the later head. Publishing this
documentation commit creates a **new head with separate CI**; the 11 green checks
must not be relabeled as checks on that new commit.

**Actual launch receipts, not the planned sample count:**
`build/m6-round3-receipts/launch-retained-01-a.json` through
`launch-retained-20-a.json` record five balanced A/B/B/A blocks, **10 retained
launches per head**. Main is incorporated `5a3f112253508c972b0952a95ea9c56e90b909b0`;
the candidate bundle's provenance names `bc235c22c`, **dirty**, and does not
capture dirty contents. The user stopped the batch at `launch-retained-21-a` of
40 planned retained samples. Sample 21 has `valid: false`, no retained timing,
and is excluded. Its profile cleanup is not certified by the incomplete receipt;
all 20 valid retained receipts explicitly record isolated-profile removal after
coordinated stops. The launch driver is no longer running. Pilots and warmups
are separate and are not counted in the following results.

| Window-appearance elapsed | Main | PR | PR change |
| --- | ---: | ---: | ---: |
| Median | 2,320.5 ms | 2,327 ms | **+0.28%** |
| Mean | 2,230.9 ms | 2,345.7 ms | **+5.15%** |

Raw retained values (milliseconds, per-head execution order):
- Main: `2429, 2225, 1998, 2321, 2355, 1860, 2574, 2388, 1839, 2320`.
- PR: `2336, 2639, 2318, 2417, 2163, 2239, 2915, 2731, 1464, 2235`.

The same Debug configuration, signing mode and alternate-in-memory secure
storage were used, with a new isolated profile per launch. Actual app-held
seed-lock paths and Foundation probes were inside those profiles. Execution was
**non-quiet under changing load** (sampled retained-window load1 **14.19–70.63**
on 8 CPUs), not a stationary controlled experiment. Enumerating all 5^5
resamples of the five ABBA blocks and recomputing the per-head median ratio
reproduces an approximate **-4.3% to +14.4%** central block-resampling range.
This is **not a confidence interval**, and the incomplete experiment is **not an
equivalence result**. A small observed median difference cannot exclude the
unchanged 10% regression budget.

The investigation lane's review at `bc235c22c` found the same **55 linked
dependencies**, executable size **+0.38%**, no added eager initializer section,
and no concrete added startup work. Read-only inspection during this docs
reconciliation corroborated 55 dependencies per bundle, sizes
398,662,672 / 400,185,072 bytes (+0.3819%), and no eager initializer section added.
The investigation reported **no early-exit or fault difference in the 20 valid
retained samples**; that statement does not cover pilots, warmups or sample 21,
and is not a general absence-of-fault guarantee. These are bounded inspection
findings, not proof that a 10% startup regression is impossible.

Historical **+10.68%** compared different upstream baselines (`35d141ad9` versus
candidate `0c541c018` incorporating `76998e93`) under overlapping heavy work.
It remains a recorded observation, **not an established M6 regression**. Neither
that historical result nor the new partial experiment is rewritten as passed.

**Workspace-free scope, by user decision:** #1402's app-side contract is covered
by `testActivatedTwoLaneContractWithoutSelectingWorkspaceUsesProductionAdmissionAndReturnedCalls`:
ordinary initialization supplies the System/Default owner without the user
selecting a workspace. Zero-owner and standalone operation are deferred to
#1408. No established destination, placement, admission or retirement ownership
guards were removed. This does not claim completion of the broader #1408 work.

### M6 semantic integration repair after main advanced (2026-11-06)

The later docs-head CI run `42191967668` at `e5c48df82` exposed a **real compile
failure in the PR-plus-current-main build**, not infrastructure: #1636 introduced
`WorkspaceAppliedIndexFolderOrdering.swift` after the previous incorporated
baseline and its unqualified `WorkspaceFolderRecord` no longer resolved after
M6's extraction. Style failed as the integration aggregate. This does not
invalidate the 11 green checks on the earlier pinned integration state, nor does
that earlier green validate this newer base.

A normal merge incorporates nine commits from main, advancing the baseline from
`5a3f112253508c972b0952a95ea9c56e90b909b0` to
`ba7dc2b7edd5a71a48f9f038f25fe82a8abcee1a`. It applied without textual conflicts;
33 incoming files changed. The sole extra production repair is
`import RepoPromptWorkspaceContext` in the new folder-ordering helper. Its sole
production caller orders applied folder records before constructing/updating
app `FolderViewModel`s; retaining this internal app adapter avoids adding a new
package API to WorkspaceContext. The record and its fields already have package
visibility. No access, authority guard, timeout or ratchet is widened.

Incoming-boundary audit:

| Main change | Ownership/integration result |
| --- | --- |
| #1636 `f52988b19` | Folder-ordering adapter remains app-private; import repaired. View-model and test imports survived the merge. |
| #1641 `c70e13541` | Canonical locator validation cache stays in Persistence; secure open/read/hash, quota accounting and private proof ownership retained. No new WorkspaceContext dependency. |
| #1639 `2b93111c4` | Tool-result liveness scanning remains app Agent Mode transcript policy; no moved-record dependency or new workspace authority. |
| #1626 `b5aac786c` | Subtree-prefix reuse remains in FileSystem with its owning tests; not moved back into the app. |
| #1583 `4dc716e08` | Start budget/expiry and binding callbacks remain app MCP/session-admission machinery, not WorkspaceContext. Updated closure signatures and existing M6 imports retained; writable-workspace and activation-owner fences retained. Its new `StoredSelection` test reference also needed a plain WorkspaceContext import in `AgentRunMCPToolServiceSteerResumeTests`. |
| #1640 `766547af2` | Main-run-loop menu scheduling remains AppKit/UI-owned. |
| #1637 `ba7dc2b7e` | Cancellation-independent cleanup cadence remains in Process with unchanged escalation deadlines; app cleanup comment updated. |
| #1635 `ef178ba0a` | Large-transcript deadline diagnostic stays test-only. |
| #1643 `d617b63ae` | Upstream version metadata and CLI version both advance to 1.9.0/build 43. |

The bounded local Oracle integration review endorsed the import and app-private
placement. Its hypothetical Explore view-model split was checked against the
actual provider: both lookups capture the same MCP server's immutable `windowID`;
window IDs are monotonically allocated and each window's `agentModeViewModel`
is a `let`. Closing the window makes lookup fail rather than retargeting another
window. No production fix was justified by that hypothetical. This local static
review is not the outstanding independent milestone review.

Maintainer-guidance check: user impact is restoring merged-source compilation;
root cause is confirmed missing module import, with WorkspaceContext retaining
record authority and the app retaining projection/admission ownership. The repair
adds no persistence/state mutation or scale mechanism. Scope is normal main
integration plus two imports (one production, one test); validation covers both products, the changed
boundaries and style. No visible app lifecycle or new performance experiment is
performed. Startup risk acceptance and #1408 scope disposition remain unchanged;
old launch/menu and Release Candidate receipts retain their original SHAs and
are not relabeled as new-baseline validation.

The first focused test ticket `56a9fda2-cb7f-41ca-880b-ec066e42124a` failed
compilation at the upstream #1583 test's `StoredSelection` reference (line 1911);
**zero tests ran**. The second plain import fixes that same extraction-boundary
mismatch without changing test behavior. An incoming-file scan against extracted
package type names found no other missing-import reference: the remaining hits
were generic nested names (`Result`, `State`, `Candidate`, `Pending`, `Snapshot`)
or source-path strings in the TaskLocal layout guard, not moved type usages.

Merged-tree validation (raw receipts in `build/m6-main-sync-receipts/`):

- Both products: `46b24ce8-30ec-4a64-a3a4-c4eb6978750b`, `swift-build --product all`, **passed** (RepoPrompt and repoprompt-mcp). The subsequent test-only import does not alter either product.
- Focused boundaries: `bb83e7ed-8cc8-43cb-ac52-83a1609069b5`, **98 passed, four opt-in skips, zero failures**, all 12 selected suites executed. Counts: steer/resume 25; start budget 6; live discovery 32 passed + 4 skips; tool-result context 4; sanitation 15; applied-index hot path 1; removed-folder rebuild 3; stable-menu deferral 2; folder ordering 3; process cancellation 2; locator maintenance 4; subtree removal 1. A 600-second waiter timeout was not a job failure; the same ticket subsequently completed successfully.
- Final formatting: `ebc3fdf7-0954-4377-947e-b027c650f241`, **passed**, 0/1,950 files changed. Final lint: `031164bb-ce17-4665-a78c-340f1a72124b`, **passed**, 0/1,950 drift and strict SwiftLint.
- Fresh compiler-index ratchet after coordinated compilation: **passed**, wrong-way file edges **1,304/1,360**, largest cycle components **54/66**. An earlier check during the test build reported freshness unproven; it was not counted as a pass. Final receipt: `index-ratchets-final.txt`.
- These are focused integration receipts, not a new full-suite, release-artifact, live-MCP or launch result. Compilation still reports existing future Swift-6 warnings; those are not test failures.

Publication uses the mandatory commit and push preflights and a fast-forward
push to `wt/1401-milestone-1`; the PR remains Draft. Exact-head hosted CI is a
separate gate after publication, not implied by these local passes. Required
independent review remains open, including this new integration delta.

## M7 / #1405 — local admission retirement checkpoint (2026-11-07)

**Partial preparation, not M7/D4 completion.** Re-attested GitHub main and merged
#1415 before planning: `21a31933e80fd3b0e347e1517187f6c621654c47`, merge time
`2026-11-06T18:41:02Z`, M6 head `e8a86685cf64158d74462809f71fcea61c0d3072`.
The isolated branch is `runtime/20261107-m7-mcp-transport`; the dirty primary is
not an implementation or validation location. #1642/M8 is a separate lane,
not a prerequisite. Its open-PR files were checked for overlap; manifest/catalog
rows and the milestone ledger need ordinary integration reconciliation later.
The primary's MCP edits are in AgentManage, the prompt VM and the session-control
provider; none is changed here. No shared file-claim artifact was found in the
previous `/tmp/rpce-pr-reviews` claim location; that is not a claim that every
other actor is idle.

### Local file scope and retirement

Owned source paths: `MCPConnectionManager.swift`, `Policies/MCPToolAdmissionPolicy.swift`,
`WindowTools/MCPGitToolAdmissionController.swift` under app MCP;
`Features/Diagnostics/MCP/MCPToolConcurrencyEvidence.swift`; and
`RepoPromptDomainRuntime/MCPDomainConnectionCallAdmission.swift`. The new owner
suite is `Tests/RepoPromptDomainRuntimeTests/MCPDomainConnectionAdmissionPolicyTests.swift`.
The headless guard script and this ledger record the boundary. No provider-lane
source, manifest row, ratchet limit, or primary-checkout file changes.

| Retired app machinery | Surviving owner / effect |
| --- | --- |
| Manager `admissionClass` and `callLane` forwarding methods (unused), five `*CallLaneLimit` constants, six connection-ID-taking capacity methods that ignored that ID | `MCPDomainToolCatalog` classifies; the existing domain limiter constructs its six lanes from `MCPDomainToolAdmissionLimits`. Connection publication/replacement and post-await identity checks remain unchanged. |
| Policy's nine capacity mirrors, classifications dictionary alias and classification forwarder | Consumers read the domain catalog/limits directly, including Git repository admission and release diagnostics. |
| App extension mapping canonical admission class to lane | The identical mapping is owned beside `MCPDomainConnectionCallLimiters`; `exclusive` still means the historical `ordinary` lane. No lane count, capacity, scheduling, cancellation, or settlement algorithm changes. |
| Repeated six-argument default construction at five manager sites | Canonical defaults on the existing domain initializer. The DEBUG file-read override and injected idle clock remain explicit. No new factory, registry, policy engine or permit owner. |

`MCPToolAdmissionPolicy` remains the narrow app adapter for role/client facts and
operation-argument decoding. Its exact-link/activation inputs and domain policy
calls are unchanged. The watchdog, resource-admission and settlement names are
already aliases to DomainRuntime, not unextracted implementation; moving those
aliases into a new target would not retire a responsibility.

### Captured invocation / preserved gates

At the pinned base, `registerHandlers` is in `ServerNetworkManager` (the type in
`MCPConnectionManager.swift`). Its network packet becomes
`dispatchInvocationContext` only after exact connection/catalog/window evidence
is captured. `dispatchResolvedProvider` carries that packet through watchdog
execution; `resolvedOperation` scopes `MCPInvocationContextBridge` around the
single `domainHost.invoke(MCPDomainHostInvocation(...))` call. The host consumes
the resolved registration handle, principal/security context, admitted domain
context and original admission deadline. App binder/VM effect checks still own
live presentation identity. This checkpoint does not change that path, add a
second envelope, or move any check across an await.

Transport registration, lifecycle generation, policy/run revisions, cancellation,
limiter replacement during tentative idle close, export publication authority,
terminal fencing, response bytes and replay/delivery accounting are untouched.
DomainRuntime remains the owner of permits and settlement, not this adapter.

### Recorded prerequisites before D4 relocation

These are remaining M7 work, not permission to import M8 or to claim extraction:

1. **Captured values are not yet an app-free file closure.**
   `MCPInvocationContextBridge.require` defaults to the app's
   `MCPInvocationDiagnosticAdapter`; `MCPTabContextSnapshot` carries
   `AgentSessionWorktreeBindingState`, `AgentWorkspaceLookupContextIdentity`,
   `ContextBuilderReviewTargetResolution` and `WorkspaceSessionRootLifetimeSnapshot`.
   The first three are still app-owned: binding state/source/identity are in
   `Features/AgentMode/Services/AgentWorkspaceLookupContextResolver.swift`, and
   review resolution is in `Features/ContextBuilder/Services/ContextBuilderReviewTarget.swift`.
   The lifetime snapshot is already package-visible in WorkspaceContext and
   must stay with its existing clock; it is not a new app-dependency blocker.
   `AgentSessionLinkRunCatalogRouteToken` is a pure value over UUIDs, generations
   and a domain endpoint, currently beside app catalog projection. These are
   bounded declaration/adapter seams to prepare, not evidence that M8 or a full
   VM decomposition is required. Separate neutral evidence from app live
   capture/diagnostics before moving the carrier. Do not erase lifetime checks or
   replace them with an untyped closure bag.
2. **Dispatch is still interleaved with app authority and publication.**
   `registerHandlers` captures live session-link grants, policy revisions and
   presentation identities, resolves exact registration scope, handles prompt
   export admission/publication, and calls tool-card observers. A new wrapper
   around `host.invoke` alone does not remove this orchestration. Freeze a narrow
   captured-call/app-effect adapter contract with tests at those await boundaries
   before relocating it; do not move the giant handler unchanged to another app
   class or silently expand into AgentModeViewModel decomposition.
3. **Transport closure has app consumers.** `MCPServerConnection` and transport
   context values are declared alongside manager/dashboard state; bootstrap and
   Unix transport share them and app diagnostics. Resolve that dependency closure
   and its consumers before the pure move. Bootstrap/listener/reconnect/proxy and
   response-byte ownership must remain transport responsibilities.
4. **No `RepoPromptMCPServer` target or move receipt yet.** The existing
   DomainRuntime physical-admission owner can be validated app-free now; that
   does not satisfy the requested new server target, handler reduction, complete
   app/direct effect matrix, independent milestone review or performance gates.
   No pure-file-move audit is claimed for this in-place preparation.

### Validation and limits

- Initial owner-module ticket `4005b31f-799a-4e96-9214-af7fef7252d2` passed:
  **2 tests, 0 failures**, 6m27s including cold dependency/module compilation;
  test execution 0.017s. This receipt predates the literal-capacity assertions
  requested by local review; final validation is recorded separately below.
- Pinned formatter installation `ae8fc5c8-64e5-497b-9724-ff8d692cfe52` passed.
  The initial format attempt refused system SwiftFormat 0.64.4; it did not format
  or validate sources. Repository-required 0.61.1 is now locally installed.
- The new guard was exercised against temporary source fixtures: current source
  exit 0; baseline mirrors exit 1; missing policy exit 1; missing manager exit 1.
  Receipt: `build/m7-receipts/admission-guard-cases.txt`. The full headless guard
  also passed. No production file was temporarily reverted for these probes.
- One local Oracle review found no visible behavioral regression and requested
  fail-closed guard inputs and fixed-capacity pins. Both are applied. This is a
  bounded source review, not the independent full-milestone review or execution
  evidence. Its alias/catalog assumptions were checked directly against source.

- Strict lint `7366681a-55b3-46bc-8898-0d4062ab1302` passed in 10m18s:
  SwiftFormat 0.61.1 reported **0/1,954 files** requiring formatting in the
  repository-defined style scope, followed by successful strict SwiftLint.
  That formatter scope excludes the domain admission file and new owner test;
  this is not a claim that all six changed Swift files were checked by that job.
- The separate six-file scoped formatter unexpectedly reformatted unrelated
  parts of the domain admission file and removed existing `Sendable` declarations.
  Final diff inspection caught this. The file was restored to baseline plus
  only the intended mapping/default changes (**+35/-7**). Formatting the edited
  range with `redundantSendable` disabled then reported **0/1 files** changed;
  no unrelated formatting or conformance changes remain. The other five Swift
  files were unchanged by scoped formatting. Validation before this restoration
  is explicitly distinguished from the corrected-source rerun below.
- Broad guardrails `e18aeda3-bd13-4925-a023-6e2f1c7cd8e4` **failed** at the
  unchanged 300-second job timeout while SwiftPM waited for the concurrent
  integration build's `.build` lock (PID 63928). This is a failed job, not a
  passing check or just a waiter timeout. The retry waited for that build to
  settle; no timeout increase or concurrent duplicate was used.

- Pre-restoration integration `4866de62-8035-414c-8252-778d05e3526b` passed:
  **52 unique tests, 0 failures, 0 skips**. Executed suites: app role projection
  2, connection removal/progress 6, export watchdog contracts 37, serialized app
  cancellation/policy/reconnect 3, direct MCP physical read admission 2, domain
  lane/effect tests 2. Other target bundles matched zero tests and are not counted
  as coverage. Conductor execution 20m54s, heavy wait 32.9s; the 1,200-second
  waiter expired while compilation continued, then the same ticket completed.
  Counts and exact methods: `build/m7-receipts/integration-test-counts.json`.
- That pre-restoration source is retained in
  `build/m7-receipts/integration-v1-source-manifest.sha256` (manifest digest
  `2905e2766346df2fae038ddeb76b38a6600c8f0d76783a04905d9fcf6109a1c9`).
  Corrected source is base `21a31933e80fd3b0e347e1517187f6c621654c47` plus the
  seven source/test/script files in `build/m7-receipts/source-manifest.sha256`
  (manifest digest `95100e23de5c473c6f0d6d6292146faa60252975641a6e6f7a5f12b6ad392a5f`).
  Ledger-only updates do not change that source manifest.

- Pre-restoration serialized broad guardrails
  `30900f27-7400-46a9-991d-ca42863e5128` passed
  in 1m13s with the unchanged timeout, after the competing build completed.
  The earlier failed ticket remains recorded above.
- Pre-restoration compiler-index check passed: **1,304/1,360 wrong-way file edges** and
  **54/66 largest cycle components**, unchanged from the M6 integration receipt.
  Receipt: `build/m7-receipts/index-check.txt`. No ratchet baseline was raised.
- Source concentration, not a runtime-speedup claim: manager **18,620 → 18,535**
  lines; admission adapter **89 → 53**; existing domain admission owner
  **881 → 909**. Across the five changed production files the net reduction is
  **91 lines**. The class-to-lane mapping is moved ownership, not deleted behavior;
  the genuinely retired paths are enumerated above. `registerHandlers` itself
  has not been reduced by this checkpoint.

- Pre-restoration Debug products (`RepoPrompt`, `repoprompt-mcp`) built
  successfully in ticket `2a1c99a6-2dfe-42f7-88e8-e4859900ef74`, 27.4s execution.
  This is a warm build after test-bundle compilation, not a matched
  build-performance result. No packaging, installation or visible launch was
  performed.
- Corrected-source integration `7ba1e797-8e0f-4059-93a8-3d0947270e21`
  passed: **52 unique tests, 0 failures, 0 skips**, with the same six suite counts
  above and the original `Sendable` declarations preserved. Execution 22m05s,
  global heavy wait 0.279s. Exact terminal test-case results were counted, rather
  than adding nested suite totals or treating compiler-warning excerpts labeled
  by the runner as test failures. Receipt:
  `build/m7-receipts/integration-v2-test-counts.json`.
- Corrected-source Debug products passed in ticket
  `e1da05a0-fe9e-4c81-9e83-4740165937df`: `RepoPrompt` and `repoprompt-mcp`,
  21.9s warm execution after 4m57s global heavy-slot wait. No competing build was
  submitted to bypass the queue. This is not a build-performance comparison.
- Corrected-source broad guardrails passed in ticket
  `dc257505-49fc-464a-bb55-d99cb7979a31`, 1m16s, serialized after the product
  build with the unchanged timeout.
- Corrected-source fresh compiler-index check passed unchanged:
  **1,304/1,360 wrong-way file edges**, **54/66 largest cycle components**.
  Receipt: `build/m7-receipts/index-check-final.txt`; no baseline changes.

Full-suite execution,
Release packaging/performance, packaged-process/live MCP and full-milestone
independent review are **NOT_RUN**. The historical Repo Bench surface is
unavailable; no replacement benchmark or visible app action was attempted.
The new owner fixture routes all six representative canonical classifications
through real limiter permits, performs temporary-file effects, proves overflow
waits and cancellation prevents its effect, and retains cancelled running owners
until physical settlement. A separate case checks explicit fixture overrides.
These controlled effects do not substitute for the full app/direct production
journey or packaged-process validation.

Maintainer-guidance check: the invariant is one canonical class/capacity owner
with unchanged physical admission. Redundant forwarding is confirmed from
source; no user-visible bug or performance gain is claimed. State and scale risks
are cancellation/permit lifetime and accidental capacity drift; generation,
authorization, durable-effect and delivery ownership remain unchanged. Scope is
bounded in-place preparation. Full milestone extraction and acceptance remain
open; no visible app action, publishing, commit or issue mutation is authorized
by this checkpoint.

## M7 transport adapter extraction — local implementation (2026-11-07)

This section supersedes the preparation-only scope above, not its historical
validation receipts. Base remains `21a31933e80fd3b0e347e1517187f6c621654c47`
(M6/#1415), in isolated branch `runtime/20261107-m7-mcp-transport`.
No primary-checkout files, GitHub state, or visible app lifecycle were changed.

### Responsibility retirement map

| Responsibility | Owner after extraction |
| --- | --- |
| Unix/bootstrap framing, reader cancellation, connection transport and response deadlines | `RepoPromptMCPServer/Transport` |
| Captured invocation values and single boxed dispatch TaskLocals | `RepoPromptMCPServer/Context` |
| Argument preparation, export envelope, provider-entry bridge, settlement observation and execution supervision | `RepoPromptMCPServer/Execution` |
| Physical resource acquisition selection | server adapter over unchanged DomainRuntime host gates |
| Provider-return, format, completion observer and handler-result sequence | `MCPToolCompletionPublisher`; app supplies formatting and live observer routing |
| Publication revalidation and post-applied-mutation suppression | `MCPToolPublicationGate`; actual wire delivery remains the transport gate |
| Catalog, lane capacities, host invocation/registration generations, cancellation and settlement | unchanged DomainRuntime owners |
| Live window/run/policy capture, connection lifecycle, consent, tool-card ownership and notice effects | app manager and existing app adapters |
| Bundle identity and health-monitor settings | injected app `MCPServerConnectionConfiguration` |

The manager no longer owns the watchdog algorithm, export bridge/observations,
execution failure switch, or repeated completion sequences. The captured
resolution reaches the existing host without fallback/re-resolution. Its host
accessor executes at the original provider-entry point (including the DEBUG
runtime override), not during capture. Dispatch fences and the non-short-circuit
final publication checks preserve their await order. Cleanup-unresponsive retains
the physical lease through the existing abort path. Window/global observer
asymmetries remain explicit; global success does not gain a window-only throwing
publication check or invocation-context wrapper.

The app-free suite exercises socket cancellation, captured context, real-host
six-admission-class execution, stale successor-registration rejection, and
publication suppression. Its completion test calls the production sequence,
not a reimplementation of format/observe/release ordering. Existing app export
watchdog tests remain the owner of end-to-end export/settlement/physical-delivery
coverage. These are not packaged/live-app or machine-wide shared app/headless
read-budget claims. M8 is independent; #1039 is not claimed fixed.

### Move and review evidence

Local audit: `build/m7-receipts/final-audit/whole-file-move-audit.json` records
HEAD/prepared/final SHA-256 values for the eleven whole-file moves. The accompanying
`preparation-at-original-paths.patch` and `relocation-only.patch` partition access,
import and adapter changes from byte-identical relocation. This is a **derived
local patch partition**, not two committed revisions and not a claim that the
whole working diff is a pure move. Split carriers, diagnostic values and handler
components are logic preparation, reviewed separately. The commit-based
`modularization_move_audit.py` gate remains for an authorized publication lane.

One current-session Oracle implementation review found no regression in the
reviewed moved dispatch/lease/envelope/delivery logic, and identified remaining
completion-sequencing ownership plus test/access cleanup. Applied: server-owned
completion and preparation, moved publication/phase helpers, original-point DEBUG
hook lookup, stale-successor test, explicit Sendable carriers, and injected bundle/
settings configuration. This does not substitute for the roadmap's separately
authorized exact-head Astra/CI publication review. No agents were launched.

### Final local validation

All commands ran in this isolated M7 worktree through Conductor where applicable.
These are local implementation receipts, not a published milestone acceptance.

| Check | Result | Conductor ticket |
| --- | --- | --- |
| Focused app integration: export watchdog, read/mutation path contracts, connection removal/replacement, bootstrap ownership, task-local layout, bind-context authority | **199 passed**, 0 failures | `680edd9e-1841-4320-97fd-7d8efe241980` |
| Full `RepoPromptMCPServerTests` | **13 passed**, 0 failures | `f5f024d1-4fcd-4db7-b3f2-466a6538cda0` |
| Full `RepoPromptDomainRuntimeTests` | **557 passed**, 0 failures | `9997f33c-59df-40e4-a986-678f83d057bf` |
| Full `RepoPromptMCPCoreTests` | **187 passed**, 0 failures | `00a70a99-1b47-4ef4-abc7-3a8263e51bc4` |
| Final Debug `RepoPrompt` and `repoprompt-mcp` product builds | **PASS**, 2m35s execution | `0a32a129-ec3f-4f81-b8ff-797d49f56d46` |
| Full formatter check + strict SwiftLint | **PASS**, 0/1,976 files require formatting | `4985c628-f14c-408c-ac2e-5ad51eb40973` |
| Full repository guardrails | **PASS**, 35.2s execution | `68d9b742-8ddc-426a-8382-6948b8e05a1b` |

The four test runs total **956 tests**, not nested-suite or repeated-run totals.
The only source change after those runs was sorting the new server-module import
in `AgentModeViewModel.swift`; the final source matched SwiftFormat's output
byte-for-byte, with no prompt-body changes. Both products were rebuilt afterward.
Source hashes and terminal test counts are recorded in the local
`build/m7-receipts/final-source-manifest.json` and `final-test-counts.json`.

The fresh post-build compiler-index check passed with unchanged baselines:
**1,296/1,360 wrong-way file edges**, **54/66 largest cycle components**.
Receipt: `build/m7-receipts/index-check-m7-complete.txt`.
`git diff --check` passed. No ratchet baseline was raised.

Earlier formatter attempts timed out or reported the unsorted import; the full
final lint above supersedes them. One guardrail attempt timed out behind SwiftPM,
and a later overlapping attempt was canceled before the final serialized pass;
neither is counted as green. Compiler warnings about two unhandled DomainRuntime
JSON fixtures and existing SDK deprecations remain warnings, not test failures.

**NOT_RUN:** the full app test suite, Release packaging/performance, packaged-process
and live CE MCP smoke, hosted CI, exact-head Astra publication review, and the
commit-based move audit. No build-time speedup, production E2E equivalence, or
external milestone acceptance is claimed. At this validation checkpoint changes
were uncommitted; no agents, push, PR, issue mutation, merge, or visible app
launch/stop/relaunch had occurred.

### Publication preparation (2026-11-07)

The user subsequently authorized committing, pushing and opening the M7 PR.
The implementation source manifest was rechecked without drift. Current remote
main was re-attested as `f713d289c80335af6246f10c3931838182501215`; the tested
branch remains based on `21a31933e80fd3b0e347e1517187f6c621654c47`, without
rebasing or claiming validation against newer main. `make xcode-validate` passed
for the added package target, including `xcodebuild -list`; generated workspace
files remain ignored. No visible app lifecycle or sub-agent action was authorized
or performed. Full app/Release/live validation and the milestone publication
review remain outstanding as described above.

## M8 integration after M6 landed (2026-11-07)

M6 / #1415 landed first at main `21a31933e80fd3b0e347e1517187f6c621654c47`.
M8 normally merges that head after its review repairs at `c6e6ee54d`.
Both milestones' target/dependency declarations and historical ledger entries are
retained. Earlier M8 aggregate counts and compiler-index receipts describe their
named pre-M6 snapshots, not this integration. Fresh integration validation is
required; the historical CodeMap incremental-index causes, large-history timing,
blocked-writer timing and suite `29b71307` unexplained stop remain open. The detailed
historical receipts are in [PR #1642](https://github.com/repoprompt/repoprompt-ce/pull/1642):

- Large-history timing: main run `41976958973` observed 15.4414s; M8 `b9500dea0`
  hosted shard job `127970362986` passed at 10.961936667s with all 1,996 deliveries.
  This establishes neither event loss nor an M8-specific cause.
- Blocked-writer quit: the `4275e53e2` full run observed 1.083509s against a <1s
  assertion; the same-head focused case passed in 0.368s. The cause is unknown.
- Full-suite ticket `29b71307-6043-41b3-bb4e-41d25ffce98a` at `e436b6635`
  exited 1 after 2,065.44s, with 4,987 passes, 10 skips and no recorded XCTest
  assertion failure. The app test process stopped before completing its tests;
  later module tests ran. Neither a causal signal nor a crash report was found.
  The last-started test does not establish causation.

No deadline or assertion is relaxed to dispose of these observations. M6 landing does not retroactively explain those failures.

## M9 / #1406 — initial F1/F2 session-runtime preparation (2026-11-07)

Base: current main `7ede2d055469ec487e30f0bdb3508255ec11e05e`, isolated branch
`runtime/20261107-m9-session-preparation`. M8 / #1642 is merged. M7 / #1651
was rechecked open at `b711ea3fa46883b23e7dc712bb08b731b252eaa2` before edits.
Its `AgentTabSession` overlap is an import addition; this slice does not touch its
MCP transport/execution extraction, package declarations, or module manifest.
At final handoff main is unchanged and #1651 is still open at
`114cc3861cef3975a85e0c501e360d631a5fdd45`. Its current overlapping source/test
patches are only `RepoPromptMCPServer` imports in `AgentTabSession` and
`AgentSessionLinkCodexCatalogRepairTests`; retain those imports during integration.
Both lanes append ledger entries at the same tail: preserve both histories, rather
than choosing one side. No M7 code was cherry-picked or duplicated. Integration
with that advancing lane must still be validated before merging the combined tree. The dirty
primary is not used for implementation or validation.

### Split map and bounded scope

| Responsibility | Existing authority | This slice |
| --- | --- | --- |
| Durable registration, epoch, persistence health and acknowledgment | `DomainAgentRunSessionStore` | Retained unchanged; no new session registry/store |
| Transient attempt identity and terminal resource ownership | `AgentRunAttemptLifecycle` | Retained unchanged |
| Terminal publication, commit ordering and teardown | `AgentRunTerminalCommitBarrier`, driven by `AgentModeRunService` | Retained unchanged |
| Neutral interaction transport, instruction dispatch/result plan, token accumulator | Four nested types in `AgentModeViewModel+Types` | Top-level values in `Runtime/AgentRunRuntimeValues.swift`; nested aliases preserve consumers |
| Codex active/anonymous turn identity, accepted-steer reconciliation, fallback queue/in-flight/blocker/pump/retry and dispatch gate | Stored cluster in `AgentTabSession` | One `CodexTurnRuntimeState` instance retained by that session; forwarding properties contain no duplicate storage |
| Provider/controller lifecycle, cancellation, fallback queue settlement and draft restoration | Existing Codex coordinator and run service | Retained; no new resets, cancellation tasks or automatic teardown |
| Saved-target resolution and nonvisual preparation | `AgentSessionCarrierResolver`, prepared runtime registry and window composition | Not replaced in this slice; F3 remains open |

The Codex owner remains MainActor-isolated, matching its current callers. Its weak
notification bridge feeds the existing monitor observation channel on exactly the
same writes. Controller replacement still rotates the controller generation and
invalidates active identities without silently dropping queued work; the coordinator
remains responsible for retiring that queue. M8's Codex provider request-failure and
shared attachment contracts are reused, not redefined.

**Retired responsibilities:** the VM namespace no longer defines the four selected
runtime value bodies. `AgentTabSession` no longer stores the 12 turn-routing/fallback
fields or defines the 13 associated Codex types/gate implementations. Compatibility
aliases and computed forwarding are intentionally retained. No writer-selection,
prepared-window or VM-callback branch is claimed retired by this initial slice.

### Identity and persistence audit

The hoisted values and turn-state types are not Codable/NSCoding payloads. Their
stored UUIDs, controller generations, run/attempt identity, stop fences, attachment
reservations and monitoring claims are preserved field-for-field. The six MCP
instruction-dispatch raw strings and their delivery-signaling policy are pinned by
a compatibility test. Swift reflected/mangled names **do change**; aliases preserve
source/type equivalence, not the old reflected spelling. A first-party source/test/
package search found no literal consumers of the moved qualified names. Agent Mode
reflection sites were inspected: error diagnostics and the test-only
`agentSessionLinkEvidenceBytes` helper do not define a persisted type-name contract.
No persistence schema, archived class name, notification name or permission boundary
is changed. Other nested types and the remaining Codex session fields are not part
of this hoist.

### Validation and limitations

Final source validation (conductor, no visible app lifecycle):

| Check | Result | Ticket |
| --- | --- | --- |
| Focused final F1/F2 and existing runtime/link suites | **119 passed**, zero failures/skips | `5d569d44-4b40-4571-a2f5-682023995b03` |
| Final full SwiftFormat check + strict SwiftLint | **PASS**, 0/2,063 files require formatting | `2b9f8c93-2871-4f43-8e76-8aa216cc79b9` |
| Repository guardrails | **PASS** | `62b0a629-5fcd-48f5-9536-39be10c7ab70` |
| Fresh compiler-index check after successful coordinated test build | **PASS**, wrong-way file edges **1,215/1,360**, largest cycle **53/66** | `.build/modularization/m9-index-check.json` |

The seven executed suites were `AgentRunCancellationOutcomeTests` (6),
`AgentRunLifecycleContractsTests` (4), `AgentSessionLinkCodexCatalogRepairTests` (21),
`AgentSessionLinkCodexPromptAdapterTests` (41),
`AgentSessionLinkNativeAndHeadlessPromptAdapterTests` (31),
`AgentSessionLinkSteerTransactionLiveTests` (12), and
`ModularizationCompatibilityGoldenTests` (4). Module bundles matching zero tests
are not additional coverage. The final job took 3m 41s including compilation and
post-test work; XCTest execution was 39.59s. No ratchet limits changed and no
edge-count improvement against a measured base graph is claimed.

Historical first run `126ad602-e5dc-48a8-889a-ba4b29fe1747` compiled and ran **37
tests: 36 passed, one failed**. The new controller-replacement test incorrectly
expected MCP-control reset to clear steer reconciliation. The source review and
execution agreed that queue abandonment preserves it; `beginRunAttempt` clears
it. Only the test was corrected, preserving production semantics. Three original
filter terms matched no suite; the final filter uses the verified class names
above. A 1,200-second waiter timeout did not cancel or fail that cold-build job;
it later finished in 34m 22s with the stated test failure. First lint
`7ac20bbf-6d6a-471d-b377-225e5634ea8e` also passed, before the test-only revision.

The one Oracle diff review found no demonstrated production regression and caught
the incorrect test expectation. Its requested checks were added: optional in-place
writeback, silent-field observation, cancellation of both runtime-held tasks by
the real coordinator reset, and serial-gate identity across controller replacement.
A source scan found no closure-taking mutating/inout uses of the forwarded queue
that could introduce re-entrant writeback loss. A mechanical body comparison verified
all 13 moved Codex declarations against HEAD after type-name normalization.
Formatting used the repository-pinned tool on only the six edited Swift files
(no whole-repo formatting mutation); conductor installed that pinned tool under
ticket `25382459-fdb3-4b41-b016-9a596536c3bb`. An initial sandboxed conductor help
attempt could not create its state directory; approved execution then used the
ordinary coordinated daemon, not a separate build path.

These are focused in-process integration receipts, not independent-writer or
real-persistence acceptance for F3. Full app suite, packaged products, real-provider
or live CE MCP smoke, Release/performance, hosted CI and M7 integration are **NOT_RUN**.
At this validation checkpoint changes were uncommitted and unpublished.

**M9 is not complete.** F3 still needs an exact session/workspace/incarnation writer
capability over the existing lifecycle/store authorities, zero/one/conflicting-writer
outcomes, first-save/pending-start cancellation ordering, and exact saved-target loading
without a window/prompt/workspace VM. Administration, scope transactions, session-link
host consumption, deferred presentation handoff and bounded drain remain subsequent
work. Provider factories and mutable session dependencies still exist in the execution
seam. No target move belongs here; F4 stays in M10. At the implementation checkpoint,
no live app action, publish or merge was authorized or performed.

Maintainer-guidance check: the confirmed structural coupling is the scope, not a
claimed user-visible bug fix. Existing lifecycle/store/settlement authorities remain
single owners. Primary risks are lost in-place writeback, missed observer invalidation,
and changed cancellation/identity lifetime; focused integration tests cover those
boundaries. The additional owner is one small in-memory object per session, with no
polling, scans or autonomous tasks. Broader F3 behavior is deliberately not approximated
by a parallel manager or speculative persistence layer.

### Publication preparation

The user subsequently authorized creating a PR. Main was re-attested unchanged at
`7ede2d055469ec487e30f0bdb3508255ec11e05e`; this remains a standalone partial-M9
slice, not a branch stacked on M7 and not a closure of #1406. The coordinated
`swift-build --product RepoPrompt` passed under ticket
`89cc1d6b-aa75-41c6-b0d3-67810dba803b` (24.4s execution). No implementation source
changed after the 119-test/lint/guardrail receipts. Mandatory staged-index commit
and outgoing-range push safety gates apply before publication. Full-suite,
Release/performance and live-smoke limits above remain; the app was not launched
or stopped. Hosted checks must be assessed on the published head separately.

## M7 / #1651 integration after M8 landed (2026-11-07)

Merged main `7ede2d055469ec487e30f0bdb3508255ec11e05e` (M8 / #1642) into
M7 head `b711ea3fa46883b23e7dc712bb08b731b252eaa2`, without rewriting the
published branch. Ten conflicted files were resolved: package app/test dependency
lists retain both milestones, five app-test headers retain both import sets,
three relocated provider controllers retain M8's exact bytes, and both historical
ledger entries are retained. Provider targets do not gain a server dependency.
M7 server sources, server tests and canonical connection admission are unchanged.

A full app/test compile exposed one clean-merge integration gap: M8's new
`ClaudeNativeSessionAppHost` and its test still referenced the app's former
`ReadSourceFDPreflight`. Both now explicitly import its M7 server owner; the
provider remains independent. The existing invalid-descriptor host test is
included in the passing app run. No runtime algorithm or timeout was changed.
One focused Oracle conflict-resolution review found no actionable issue in the
package/catalog/import resolution; its stated full-build coverage limit was
addressed by the compile and regression run below.

| Check | Result | Ticket |
| --- | --- | --- |
| Focused app integration, routing authority, connection lifetime, export watchdog, Auto-wake/prompt pipeline, Context Builder selection, Claude host | **414 passed**, 0 failures | `8108eb5f-0e0b-4993-b087-7dbc4920636c` |
| Full server suite | **13 passed**, 0 failures | `5ed90a51-de41-40ad-9150-f302927d02b7` |
| Full ACP provider suite | **101 passed**, 0 failures | `77b99d20-264f-4e74-9b7a-416f4427900f` |
| Full Claude provider suite | **38 passed**, 0 failures | `ba1ec975-7eba-450f-b28a-283fc6f828dc` |
| Full Codex provider suite | **19 passed**, 0 failures | `c7ebdc67-aa38-49db-90a4-bcb9d8b58797` |
| Both Debug products | **PASS** | `1806e433-b003-4f0b-ac35-f0d18904d67d` |
| Full SwiftFormat + strict SwiftLint | **PASS**, 0/2,083 files require formatting | `43fdd96c-db33-4155-abd2-4adcabe3fcc5` |
| Initial combined-tree guardrails | **PASS** | `1d095f29-3b5a-445e-bae0-062b55a98007` |

Total: **585 tests**. The app waiter initially expired while the same job was
still running; the job subsequently completed with exit 0 after build-cache
publication. The first app compile failed on the missing import above, and the
first lint attempt hit formatter rule timeouts. Those failed attempts are not
counted as passes; the final runs supersede them without deadline changes.

`make xcode-validate` passed. The fresh post-build compiler-index check passed at
**1,206/1,360 wrong-way file edges** and **53/66 largest cycle components**.
Ratchet configuration matches incoming main exactly. Local receipts are under
`build/m7-receipts/m8-merge-*`; no generated workspace, logs or local audit files
are committed. Full app-suite, Release/performance, live-app smoke and the
milestone's exact-head publication review remain outside these local receipts.
No sub-agent, visible app lifecycle, force-push or primary-checkout edit occurred.

## M9 / #1652 — merge-conflict resolution after M7 (2026-11-07)

Merged main `85505637e94744162e31ae29372975de70f88ac7` into M9 head
`18132a58f5013614a71a9f19968362d383ab51b9`, without rewriting history.
The only conflict was this Markdown ledger's competing additions; both histories
are retained. A line-order check confirmed every line from both parent ledgers
survives. All six M9 Swift files remain byte-identical to the PR head except the
two incoming M7 MCP-server imports; no code was manually changed by the resolution.
Conflict-marker and whitespace checks passed. The focused merge-resolution review
found no actionable issue.

The initially submitted test/build/lint jobs were unnecessary for this Markdown-only
resolution and were canceled at the user's direction: `89f1f527`, `327435c6`, and
`5b8ab44e`. A briefly requested focused-test retry (`c1dace8e`) was also canceled
when the user confirmed this resolution is docs-only and requested pushing without
tests. None of these attempts is a passing validation receipt. Earlier implementation
receipts retain their original source provenance. Mandatory commit/push safety gates
remain applicable. No visible app lifecycle action occurred.

## M9 / #1406 — execution inputs and saved-carrier lookup prerequisites (2026-11-07)

Isolated branch `runtime/20261107-m9-session-writer` starts at #1652's exact
head `2fe16b92a73d624b9333cf1cc593c6e35836ce93`. At the opening recheck,
#1652 is open and mergeable, and main remains
`85505637e94744162e31ae29372975de70f88ac7`, already incorporated by that base.
M7 and M8 history and the preceding validation receipts are preserved, not
cherry-picked or represented as validation of this new diff. The primary is untouched.

Continuation recheck: #1652 was squash-merged as `15d858caaa4eff7d9f2d6cb211fb383f4e392a53`.
Its tree is identical to the original base. The uncommitted continuation was carried
onto new local branch `runtime/20261107-m9-session-writer-main` at that main commit,
without rewriting the original branch or duplicating #1652's commits.

### Ownership map and commit grouping

1. **Execution inputs:** runtime-owned factory/routing closure vocabulary and an
   immutable ACP request input, together with provider-configuration regression tests.
2. **Saved-carrier lookup:** a window-free exact metadata resolver, its production
   window adapter and disk/identity/revalidation regressions.
3. **Live session storage:** move the existing live-object map and reverse binding
   index into `AgentSessionRuntimeStore`, with identity, duplicate-claim, rebinding,
   retention and VM publication-order regressions. This replaces storage rather
   than adding a second registry; it does not yet transfer mutation admission.

These are prerequisite chunks, **not the independent session writer**. Source
inspection confirms that `CodexAgentModeCoordinator` still retains a concrete VM
and uses it for runtime dispatch, route proofs, persistence and presentation. The
run-service hooks and runners still accept mutable `AgentTabSession`. Replacing
that ownership requires a real host/capability inversion; a weak writer registry
beside the window census would only add a parallel authority and is not introduced.

| Responsibility | Owner after this slice | Retired responsibility |
| --- | --- | --- |
| Provider/routing factory signatures | `AgentRunExecutionContracts`, using M8 provider/model contracts | VM-owned definitions and runtime references to those five VM aliases; presentation compatibility aliases remain |
| ACP model/resume/role/pin request assembly | Immutable `AgentACPRunInput`, captured by the existing session host at each dispatch | `AgentModeRunService.makeACPRunRequest(session:)` and its mutable-session input |
| Exact saved metadata lookup and carrier cardinality | `AgentSavedSessionTargetLoader` | Window-manager implementation of the lookup loop; composition still supplies the catalog and live fences |
| Live session objects and synchronous reverse binding index | `AgentSessionRuntimeStore`, owned by existing composition | VM's stored `sessions`, claim maps and binding-index maintenance; computed compatibility access and UI notifications remain |
| Durable registration/epochs, attempts and terminal settlement | Existing domain store, run-attempt lifecycle and terminal barrier | None; no replacement authority or schema change |
| Execution hosting, writer election, payload hydration and handoff/drain | Existing VM, carrier census and prepared-window composition | None; these M9 acceptance gates remain open |

The loader point-reads one UUID per known workspace through `AgentSessionDataService`.
It constructs no window, prompt VM or workspace VM, does not hydrate payloads or
start providers, and performs no new writes. Live metadata and carrier placement
are re-read after IO; the first match is revalidated after later workspace reads.
Current authoritative live state bypasses disk as before. Conflicting persisted
identity remains fail-closed, and cancellation is distinguished from unreadable
storage. The result is request-local evidence, never permission or a writer.

No persisted/reflected class schema changes: closure aliases are source vocabulary,
and the new input/lookup values are not encoded. Existing provider factories and
VM-backed callbacks are still injected implementations, not eliminated dependencies.
No target move is included; M10 remains unchanged.

The live-object store retains exact `AgentTabSession` instances and preserves all
reverse claims, including duplicates, so existing census/admission code can still
reject conflicts. Binding callbacks update the index synchronously; replacement and
removal detach retired callbacks. The VM retains a computed compatibility property,
publishes `objectWillChange` before replacement, then runs census/sidebar/revocation/
attention notifications in their original order. No `$sessions` consumers or direct
initializer assignments were found. The store has no persistence, provider-start,
cancellation or presentation callback and is not a competing writer-election authority.
A scoped Oracle review found no production regression; its test-name finding was
applied without weakening the exact-object callback guard.

### Validation receipts

| Check | Result | Conductor ticket |
| --- | --- | --- |
| Loader, ACP input/permission and existing run-lifecycle suites | **47 passed**, zero failures | `20f30147-b72b-4681-83d4-1ee98cdb427d` |
| Full SwiftFormat check + strict SwiftLint | **PASS**, 0/2,088 files require formatting | `284bac1b-e9b8-4864-b985-25f27bf80694` |
| Repository guardrails after build released SwiftPM lock | **PASS** | `29ddd161-6d8d-4b5f-8eb2-7370bb733cf1` |
| ACP integration plus historical/stashed lookup | **29 passed, 1 failed**; provenance-inconsistent fixture diagnosed below | `511aad6b-7140-4579-92b2-2c16330011cc` |
| App product build | **PASS** | `2d0e10ad-7677-48e3-90c8-45660e80fb21` |
| Loader plus corrected historical/stashed integration | **8 passed**, zero failures; includes conflicting-provenance rejection | `da236742-700f-424a-ab06-2163e6ae1885` |
| Runtime store, identity snapshots, cancellation, lifecycle and lane-first-save suites | **63 passed**, zero failures | `eb9a00c0-ce01-4a5f-9f09-327d92a31bcd` |
| Final combined input, loader, store, ACP integration and saved-target boundaries | **77 passed**, zero failures | `7bc8169d-4ad8-431d-8704-fc894886aa81` |
| Final full SwiftFormat check + strict SwiftLint | **PASS** | `7c041bdb-e0d7-4026-b53d-8eb29d7a79e3` |
| Final app product build | **PASS** | `6621a585-dcdb-44f1-a6de-984a96b04921` |
| Fresh compiler-index ratchets after final product build | **PASS**: wrong-way file edges 1,205/1,360; largest cycle components 53/66 | `.build/modularization/m9-final-index.json` (1,091 files, 153,464 symbols; local artifact, not committed) |

The 63-test store run comprised `AgentSessionRuntimeStoreTests` (4),
`AgentContextExportRenderSnapshotTests` (2), `AgentRunCancellationOutcomeTests` (6),
`AgentRunLifecycleContractsTests` (4) and `AgentSessionLaneFirstSaveTests` (47).
Ticket `1690c12f-b1c0-4fbe-9425-8c19e3808653` was canceled after 9.9 seconds because
scoped formatting had not yet completed; it is not a receipt. Formatting completed
before the passing replacement run. The retired-callback test was subsequently
renamed to describe the observable guarantee rather than claim guard mutation coverage.

The historical/stashed integration fixture saved a stashed payload with nil parent
and organization while its index claimed non-nil provenance. Diagnostic tickets
`f0b37e13-ccfa-42e3-98ca-c60927b6de7f` and `7032e534-ace8-4229-8d54-8a4f74b946b3`
reproduced the existing fail-closed provenance check (not cancellation or duplicate
carriers). The fixture now persists matching provenance and explicitly asserts that
a conflicting parent is rejected; no production guard was weakened. Temporary
prints were removed. The 29 successful integration tests cover ACP advertised
commands, compact runner/transactions and background compaction settlement.

An earlier compiler-index check reported freshness unproven (0 stale, 0 unindexed
files), so it is **not a passing receipt**. The final product build and subsequent
fresh-index check above supersede that incomplete attempt; no ratchet baseline was
increased. Final tests and lint cover the renamed test and current production source.
Only ledger receipts changed afterward.

The 47 tests are `AgentSavedSessionTargetLoaderTests` (7),
`OpenCodeRunRequestPinPropagationTests` (3), `DevinPermissionLevelTests` (33),
and `AgentRunLifecycleContractsTests` (4). The build took 1,553.25 seconds;
selected XCTest execution took 27.025 seconds. Two filter terms used file names
rather than the actual class names and matched nothing; their integration coverage
is not included in this count. Auxiliary zero-match bundles are not coverage.
A waiter expired while the same successful ticket was publishing its cache;
it was rejoined without resubmission.

The first focused conductor ticket `7b2a9cd4-a9b7-4397-b188-ec0666eca437`
was canceled (exit 130) after source inspection identified a missing provider-contract
import, now fixed; it is not a test pass. Initial guardrails
`399e3d9f-6330-4f3a-b3db-23418f4294f6` timed out at 300 seconds waiting for the
test build's SwiftPM lock. The passing retry ran after that build, without changing
the timeout. Pinned formatter installation succeeded under ticket
`81888ee8-127b-468c-a93d-2309c70a751c` after build-cache setup removed the initial
worktree-local formatter. Only changed Swift files were formatted.

One Oracle diff review identified mixed fresh metadata/old carrier evidence; the
loader now refreshes carrier placement and checks it again before returning.
Its closing-window concern was checked against `AgentSessionCarrierResolver.capture`,
which already excludes closing windows. The proposed override of mismatched disk
identity by a newly live runtime was not adopted: identity conflicts remain failures.

**M9 remains incomplete:** independent zero/one/conflicting writer admission;
first-save acknowledgment and pending-start cancellation before visibility;
administration/scope/link command adoption; inversion of remaining VM/provider
execution dependencies; window-free payload hydration and execution hosting;
presentation attachment, deferred handoff and bounded drain. The existing window
adapter still rejects agreeing replicas; this slice does not claim that acceptance.
Full-suite, real-provider, live CE MCP, Release/performance and hosted CI are not
claimed. No publishing, merging or visible app lifecycle action is authorized.

Maintainer-guidance check: this is confirmed structural preparation, not a claim
of independent-runtime behavior. Existing authorities and persisted identity stay
intact. Primary risks are stale carrier evidence and dispatch-value drift; focused
real-disk and input-capture tests cover those boundaries. Lookup remains bounded by
the supplied workspace catalog with UUID point reads, no polling or new background
owner. The broader writer transition must not be labeled complete by these changes.

### M9 completion continuation — writer authority (in progress)

The subsequent completion request starts from `48b4707d0`. The next transition
promotes the existing runtime store to process ownership with lifetime scopes;
scopes retain objects and the store holds weak scope references. Exact writer
capabilities capture object, binding generation, workspace and restoration token.
Absent, unscoped, transitioning and conflicting claims remain distinguishable;
metadata replicas never register live objects. The carrier adapter is being moved
to consume this authority rather than independently elect a live writer.

`AgentPersistentSessionBindingIdentity` gains an in-memory optional workspace UUID
(no Codable/schema change). Production binding installation captures explicit CAS
workspace or unique carrier workspace, never a later selected-tab inference.
Unscoped bindings fail closed for writer admission. Cross-scope binding observation
is maintained centrally so the same object accidentally installed in two scopes
cannot hide a duplicate claim by rebinding.

This transition is an intermediate local checkpoint, not M9 acceptance. Initial focused
conductor ticket `116272e7-e502-4393-8e85-5fa2db6c3afa` passed **57 tests** (writer store
7, context snapshot 2, first-save 47, historical/stashed metadata 1). A subsequent
usage-accounting extraction moves estimator ownership and all accounting bodies to
`AgentSessionUsageRuntime`; run hooks retain that service, while durable-report
append results explicitly trigger the caller's exact-object save. No presentation
object is needed by the accounting service. The VM retains forwarding accessors,
not a second accounting implementation. Runtime carrier evidence now retains the
writer capability across suspension rather than only an unqualified session object.

Ticket `caac76ea-5b54-443f-a9f3-8be28f0ae488` failed compilation before tests because
Swift disallows covariant `Self` in a stored-property initializer; the initializer
now names its concrete service type. Corrected ticket
`a20f4e3d-0aec-4138-a674-844ab5189037` then failed compilation before tests because
`RuntimeOwner.matches` was not actor-isolated after gaining a writer-currency check;
`RuntimeOwner` is now explicitly MainActor-owned. Retry `m9-writer-usage-v4`, ticket
`9556badc-e12b-4ca7-b772-8ac7c81c3642`, passed **251 tests**: first-save 47, context-load
40, handoff inheritance 100, writer store 8, standalone usage 2, Claude window-cap
lifecycle 15, Claude window resolution 11, administration/worktree recovery 28.
Non-mutating conductor lint `d76251e8-e73c-4f4f-b2cf-af7ceae6a42c` passed. These are
focused transition receipts, not full M9 or final-product/index validation.

The transition review found that a rejected live writer could disappear into a
cold metadata fallback. Carrier snapshots now retain explicit writer rejection
reasons and administration refuses that fallback. A partial-window census test
checks the process-wide conflict. Same-ID explicit workspace qualification now
rotates the binding and requires hydration again; dirty, owned, creating or saving
objects cannot be silently qualified, and a fresh-creation claim must match the
CAS workspace. The suggested immediate retirement on presentation close is not
adopted: that would elect a successor before owned work and durable effects drain.
Explicit runtime retirement still belongs in the remaining host/drain cutover.

Remaining integration includes runtime command/services extraction,
first-save/cancellation admission, administration/scope/link adoption, window-free
payload hosting, presentation attachment and settlement-driven handoff/drain.
Inspection confirms the MCP agent tool services still require `WindowState`, and
Codex coordination reaches 46 distinct VM members; replacing these with a protocol
that merely forwards to the VM would not satisfy the requested outcome.

### M9 completion continuation — durable payload effect and optional presentation

The next local transition starts from `40858d5e9`. `AgentSessionPayloadWriter`
now performs the actual saver invocation for an exact runtime writer, with payload
session/workspace/tab identity, frozen storage placement, binding incarnation and
source/save revisions checked before and after suspension. The save token and
request-local effect-phase vocabulary are runtime-owned, with VM compatibility
aliases. A returned URL is explicitly not a configured-first-save or terminal
acknowledgment: those remain with their existing authorities. Rebinding, competing
writers, changed source revisions and storage moves after a real disk effect return
superseded-after-write; a thrown cancellation after the disk effect retains
write-may-have-committed evidence. Dirty state is not cleared by this service.

`AgentSessionPresentationRuntime` owns optional exact-object presentation attachment
and run-activity timestamp bookkeeping. Run hooks retain this router rather than
the VM. Attachments have generations, so a late detach cannot disconnect a newer
presenter. ACP refresh callbacks now carry the exact originating session instead
of a recyclable tab UUID. The VM attaches/detaches sinks through its existing
session-map mutation; predecessor completion cannot clear successor activity.
The existing window close path keeps its sink through its current drain, then
detaches. This does **not** yet claim that window close leaves managed execution
running: the broader provider/host teardown transition remains outstanding.

Retired responsibilities in this transition: VM-owned save-token implementation,
direct unqualified saver invocation in `saveSessionCore`, VM callback capture in
the run service's presentation hook group, and VM-owned activity timestamp mutation.
The hook documentation no longer incorrectly permits a headless host to silently
no-op persistence, binding observation or queued-user-work recovery.

Execution receipts:

- `dc8646a5-124d-40bf-81fa-47051e25758b` (`m9-payload-writer-v1`): **51 tests passed**
  (47 existing first-save, 4 payload-writer tests including real persistence).
- `c9da21f5-4829-4387-9ee4-729595b21485` (`m9-presentation-payload-v1`): failed one
  new test's immediate full-VM deallocation assumption. The corrected integration
  test awaits existing close preparation; a separate router/presenter lifetime
  test checks the intended ownership boundary without asserting unrelated VM work
  has already drained. No production timeout or retry was changed.
- `076d3ae9-536c-4ad4-874f-fe62fc921121` (`m9-presentation-payload-v2`): **117 tests
  passed**: ACP execution 11, quiet check-in 14, first-save 47, payload writer 4,
  presentation runtime 4, runtime store 8, administration/worktree recovery 29.
- `ea3d34e1-d1c5-4f45-839c-cefcbdb205de`: conductor lint passed.

The transition review prompted frozen-directory verification and preserving
terminal presentation effects until legacy close preparation finishes. The
suggested active-workspace/catalog mismatch was checked against source:
`activeWorkspace` delegates to `workspace(withID:)`, and prepared projections install
their borrowed workspace in that same catalog. There is no alternate active-only
workspace in that path. The suggested bypass/automatic retry for unscoped or
conflicting writers was not adopted: those identities cannot safely authorize a
write or a timer retry loop. Required flush fails honestly and retains dirty state;
a new real-disk VM integration test verifies zero writes during conflict and one
successful explicit retry after the competing claim is removed. Binding-transition
rejection already occurs in the preceding save-token check.

M9 is still in progress. Payload construction/save serialization, full saved-target
hydration and execution hosting, remaining provider/VM execution callbacks,
settlement-driven presentation handoff and bounded writer retirement still require
integration. The optional presentation router is not a second lifecycle authority.
Final product/index/full-suite validation and live smoke are not claimed here.

### M9 completion continuation — runtime transcript construction and hydration

Starting at `3f1bdc5e6`, the production saved-payload path now uses runtime-owned
transcript construction/application and full persisted-field application. The
builder's sanitization, cache reuse, quiet display, analytics and instrumentation
algorithms move unchanged; the VM keeps compatibility forwarding entry points.
The loader no longer calls a static VM transcript builder. A neutral transition
token preserves exact object, binding generation and source revision checks.
Full field application checks the saved session and workspace identity and returns
a binding-qualified applied-payload receipt. Existing synchronous provider repairs
finish before that receipt publishes readiness through the existing restoration
authority. An old receipt cannot grant readiness to a later binding incarnation.
Codex effort resolution is a frozen policy shared with the coordinator's normalizer,
not a second preference store. Latest indexed organizational placement still wins
over payload placement. Pending provider-switch tuples keep their existing override.

The real-disk regression constructs neither WindowState, PromptViewModel nor
WorkspaceManagerViewModel. It loads a saved payload and checks transcript, metadata,
usage capacity, indexed placement and readiness on a standalone session object;
negative cases cover stale incarnation and foreign workspace before mutation.
This is payload hydration, not yet a window-free execution host. Attachment repair,
provider command reconciliation, preference effects, and index/UI publication still
run in the caller tail; save-core and execution-host extraction remain necessary.

Intermediate receipts (continued below as validation completes):

- `84c53053-df23-4af0-912f-7285b0330c59` (`m9-transcript-runtime-v1`): failed
  compilation before tests on two new fixture initializers; corrected persisted
  item conversion and explicit viewport state.
- `d6a9aa12-ef41-4341-ae6a-a1e7f1672d1c` (`m9-transcript-runtime-v2`): **56 tests
  passed** (2 transcript-runtime, 14 quiet-display, 40 context-load).
- `5e558bb6-8057-417d-8195-fbe718e51076` (`m9-full-hydration-v1`): failed
  compilation before tests because the new Codex policy omitted contract/provider imports.
- `885781de-99b3-41b4-a4b9-753242ac1f89` (`m9-full-hydration-v2`): failed
  compilation before tests on an unqualified nested handoff-state initializer;
  corrected to infer the existing field type, without adding a VM construction.
- `725ffea8-0da3-4ec8-a044-c090569318b2` (`m9-full-hydration-v3`): failed
  compilation before tests because the nested receipt's synchronous readiness method
  lacked explicit MainActor isolation. The method now expresses the existing session
  actor boundary; no executor hop or unchecked sendability was introduced.
- `6fea7758-c6a2-4059-aab9-4b790befa2d6` (`m9-full-hydration-v4`): production
  compilation passed; test compilation failed on a new capacity fixture using an
  integer instead of `AgentContextWindowCapacity`. Corrected the typed fixture.
- `af46e86c-b5e8-41f8-9dc6-ee4225935cff`: conductor lint passed before the final
  capacity-fixture correction (that file was subsequently scoped-formatted).

The standalone workspace fence uses the exact load request's `sourceWorkspaceID`:
legacy files may omit their embedded workspace ID, but an explicit conflicting
embedded ID is refused. A real-disk legacy regression keeps the embedded field nil
and proves the scoped load is accepted without inventing persisted identity. A
mechanical comparison against `3f1bdc5e6` verified all six moved transcript-builder
method bodies match, apart from the neutral result-type name and formatting.

Review added the standalone workspace fence and separated field application from
readiness publication. The suggested lost refresh-task/cold-load side effects were
checked against source: the old mark-synchronized helper only assigns the sync
stamp, and `setItemsSilently` still cancels pending derived work. The old supplied-
presentation hydration path did no additional cold-load work. Readiness is binding-
qualified, not source-revision-qualified. The Codex normalizer's non-Codex branch
already published the agent-neutral selection bindings; no preference mutation is
introduced by the forwarding binding publication. The prior Codex selection restore
already stripped model effort suffixes before normalization, so its precedence is
preserved rather than changing it based on the review's inferred alternative.

Final focused receipt for this transition: `a2634059-9e37-4792-9b60-674e15072484`
(`m9-full-hydration-v5`) **194 tests passed**: quiet-display 14, first-save 47,
context-load 40, standalone transcript/hydration 7, Claude native effort 12, Codex
resume/wedge commit 74. Final lint `97e94d70-874e-4f75-b7ba-f49854e52dd9`
(`m9-full-hydration-lint-v2`) passed. The runtime builder move and legacy workspace receipt
are included in this passing tree. No app was launched or stopped. M9 remains
in progress: complete save-core ownership, window-free execution composition and
MCP/link/admin routing, presentation handoff and bounded retirement/drain remain
required; this receipt is not acceptance of those unfinished paths.

### M9 completion continuation — runtime save preparation and configured commit

Starting at `33487157b`, the runtime scope owns save admission/coalescing/drain
bookkeeping through `AgentSessionSaveQueue`. Deletion withdraws follow-up intent
without claiming that an admitted write has drained. Cancellation of a waiter does
not invent a durable-drain acknowledgment. The VM's three parallel queue collections
are retired; existing close, required flush and fresh-creation callers use the same
scope queue.

`AgentSessionPayloadBuilder` owns the actual payload field construction, canonical
configuration stamp, post-await configuration reread and Codex persistence fields.
`AgentSessionSaveRuntime` prepares the configured/recovery write and performs the
existing exact payload write and configured-creation acknowledgment. Preparation
pins the exact object, binding and source/save revisions; a later token cannot
relabel an older prepared payload as current. The existing session restoration
state remains the only first-save authority. A URL from storage is not an
acknowledgment. Runtime receipts carry the exact durable binding; the caller still
publishes index and terminal effects in their existing order.

The synchronous transcript refresh, incremental import, quiet-retirement,
summary-only compaction and persistence snapshot algorithms now live in
`AgentSessionTranscriptRefreshRuntime`. Save preparation uses those implementations,
not VM callbacks. Optional presentation publication follows each refresh at the
same call boundary. Existing VM APIs forward for their remaining callers; obsolete
private snapshot/compaction implementations are removed. The refresh reason and
persistable snapshot are neutral values with compatibility aliases; neither is a
persisted or Codable type. Their raw values and persisted payload fields are
unchanged.

Four standalone runtime tests cover real-disk transcript preparation and configured
first save without presentation models; held writes with configuration, name,
incarnation and request-revision changes; cancellation after a durable effect; and
coalescing/drain/deletion intent. The review compared moved transcript and payload
bodies against the old hunks. It identified an admission-order regression: the new
prepare guard could turn an unscoped writer's deferral into a failure. Writer/token
admission now precedes preparation, preserving the fail-closed deferral path and
preventing invalid preparation from marking creation ready. A VM regression checks
that an unscoped binding reaches no saver, retains dirty state and does not spin a
retry loop. The rebind fixture explicitly verifies its incarnation changed.

Receipts so far:

- `30a1dc22-3729-49d3-91af-5fbc1c6d16a4` (`m9-save-runtime-v1`): failed
  compilation before tests on one deletion path still naming the retired queue
  field; routed it through `discardFollowUp`.
- `169f0818-f380-4c0f-8ed3-ccd004e0a797` (`m9-save-runtime-v2`): **117 tests
  passed** (quiet display 14, retention 12, first-save 47, payload writer 4,
  save runtime 4, transcript runtime 7, worktree recovery 29). This predates the
  admission-order review fix. The filter also named a transcript file rather than
  its actual suite names; those suites did not run under that name.

This is not final M9 acceptance. The existing VM still composes admission/storage
currency, debounce scheduling and index publication. Runtime host composition,
window-free MCP/link/admin routing, presentation handoff, and bounded retirement
must consume these runtime services before obsolete prepared-window ownership can
be removed. No new lifecycle authority or target move is introduced here.

Final receipt for this transition: `45776ab8-2590-4a07-8c50-e41e526f2f23`
(`m9-save-runtime-v3`) **242 tests passed**: quiet display 14, retention 12,
first-save 47, payload writer 4, save runtime 4, transcript runtime 7, sidebar
restore stability 14, pane presentation 42, pane snapshot publication 4,
restoration lifecycle 64, worktree recovery 30. This includes the admission-order
fix, the unscoped-writer VM test and the actual restoration/publication suites.
Conductor lint `0d525fa2-7d2e-4d13-8388-5010030ee5c9`
(`m9-save-runtime-lint-v1`) passed on the same Swift tree. No live app action,
publishing or target move occurred. Final product/index/full-suite evidence remains
open until the remaining host/routing transition is implemented.

### M9 continuation — scope-owned persistence orchestration (2026-11-07)

`Scope.persistence` now owns debounce admission, save coalescing, the complete
save transaction, required flushes and in-flight drain through the existing
`AgentSessionSaveQueue`, payload writer and configured-creation authority. The VM's
save entrypoints are compatibility delegates. Its remaining composition supplies
catalog/carrier admission and reads, suppression and the existing provider-switch
gate; no parallel lease or lifecycle authority was added. Sidebar/index projection
is a separate optional presentation callback. Durable payload and metadata writes
still use `AgentSessionDataService`.

Run-service persistence and usage hooks retain the concrete persistence runtime.
Codex save and throttled-output call sites now use that runtime and exact session
objects instead of calling the VM by tab ID. The current UI composition installs
the dependency; this does not yet remove the coordinator's other VM dependencies.

A debounce retains its exact scope until it settles. It cannot save a different
object installed under the same tab ID. Review identified that simply rejecting a
same-object binding-generation change could lose a transition follow-up; it now
re-arms under the new incarnation and runs ordinary writer/restoration admission.
No conflict or unavailable writer is bypassed. Required flushes without a scope or
composition fail rather than acknowledging a write. A vanished UI adapter reports
owner unavailability, not persistence suppression.

Standalone tests exercise real-disk saves through run hooks without presentation,
scope retention/release, same-object requalification versus recycled tab objects,
configured first-save acknowledgment, missing composition, held writes across
storage/incarnation changes, and an existing authority's save refusal. No test
constructs a window, prompt VM or workspace VM for those runtime transactions.

Initial conductor ticket `a4941ac3-a8ed-44d4-a70d-6a4ad47dcb22`
(`m9-persistence-composition-v1`) passed **90 tests**: first-save 47, standalone
persistence 5, presentation 4, save runtime 4, worktree recovery 30. This receipt
predates Codex direct wiring and the reviewed same-object re-arm.
Final conductor ticket `b4e71595-7ceb-42cf-850c-95ff92f236ad`
(`m9-persistence-composition-v2`) passed **176 tests**: ACP execution 11,
first-save 47, standalone persistence 6, presentation 4, save runtime 4,
Codex resume/wedge commit 74, worktree recovery 30. This includes the re-arm,
released-scope and missing-composition assertions. Conductor lint
`96e2bf0c-a2e3-4f62-a5f5-6119791b9850`
(`m9-persistence-composition-lint-v1`) passed on the same Swift tree.
The review's last-user-date question was checked against the builder: the receipt
payload copies `snapshot.lastUserMessageAt`, preserving the old index input.

M9 acceptance remains open: the production catalog/carrier adapter is still
VM-composed; provider input, live transcript/attachment effects, routing and the
prepared execution host must become window-free. The obsolete prepared-window
factory and close-cancels-run path are not retired yet. These remaining gates are
part of M9, not delegated to M10. No publishing or visible app lifecycle action
occurred.

### M9 continuation — provider attachment and stream effects (2026-11-07)

`Scope.attachments` owns reservation/consumption/finalization, admitted retention
and hydration-repair tasks, and canonical attachment-path application. The run
service and Codex call this concrete owner; the VM no longer stores retention
tasks or performs those mutations. File admission and deletion still belong to
`AgentSessionDataService`. Reservations capture both the temporary directory and
retained root, rather than consulting the selected workspace when a turn ends.
Publication after IO checks the exact live object, binding/restoration incarnation
and storage location; stale disk effects remain available for a later exact
hydration repair. Admitted tasks retain their scope until completion; cancelling
a drain waiter does not claim that the move completed. Sweep protection now comes
from live runtime scopes plus admitted retention operations, not a window census.

`Scope.stream` owns accepted stream application, tool accounting, buffered text,
reasoning status and terminal transcript repair. It shares the scope's usage and
persistence services. Run/tool hooks bind those actual services, while exact-object
presentation sinks carry assistant revision/generation and derived-publication
notifications. Tool-hook refresh/save no longer targets a potentially recycled
tab ID. The existing run-attempt and terminal authorities are unchanged. The
stream owner borrows the run service/coordinator weakly to avoid a hook cycle;
the final runtime host still must own those dependencies independently of UI.

Review compared the moved algorithms against their removed bodies. It identified
missing-placement cleanup and first-binding retention cases: managed temporary
cleanup remains available without a reservation, and a previously unbound live
object qualifies its first retained-session destination at consumption. An
already bound reservation never adopts a different identity. Explicit test storage
overrides do not require a workspace presentation. A stale reasoning flush also
releases its pending slot instead of suppressing later previews. That reasoning
feature remains disabled by existing policy; no feature flag was enabled for
validation. The hydration repair admission was checked against the real caller:
`persistentBindingTransitionIsCurrent` already requires the exact object in the
scope before `applyPersistedHydration` can invoke it. Usage wrappers had no hidden
publication side effects beyond the moved save-on-appended-usage behavior.

Initial attachment conductor ticket `012bddb4-9487-43cc-9012-cf61d9e4c845`
(`m9-attachment-runtime-v1`) passed **130 tests**: image retention 29, Oracle
attachment forwarding 2, standalone attachment runtime 4, deletion 21, Codex
resume/wedge commit 74. Combined stream ticket
`ef7a800b-3948-404d-b965-84f23410cb1d` (`m9-stream-attachments-v1`) passed
**95 tests** before review fixes: ACP execution 11, ACP tool correlation 10, image
retention 29, quiet lifecycle 25, transcript retention 12, standalone attachment
4 and stream 4. The filter's `AgentAssistantPresentation` term matched no suite;
the expanded run uses actual pane presentation/publication suite names. Expanded
post-review validation and lint are recorded below once settled. The standalone fixtures construct no window, prompt VM or workspace VM.

Post-review runs `59a2ac39-dea1-4280-bb7c-fa3ff8fb0f95`
(`m9-stream-attachments-v2`) and `fbbcedce-110b-46b4-ab0d-27f42866fbeb`
(`m9-stream-attachments-v3`) each ran 255 tests with one failure in the new
explicit-storage VM fixture. Keeping the UI adapter explicitly alive did not fix
it. Diagnostic ticket `9f9a5b8c-ccdf-4b32-9a75-9cbcd8e3ee8b` isolated the failing
location witness: object, binding and restoration stayed current, but URL equality
changed after creation of a previously absent retention directory. The captured
location now explicitly represents directories before they exist, preserving the
same-path identity without weakening incarnation or moved-storage rejection. The
regression asserts absent storage before retention, normalized directory identity,
unchanged binding/location and the repaired row afterward. Lint tickets
`3a3eb149-aa56-45fc-bea1-a9c7226f4f6a` and
`1e766b04-22c4-4cc2-9d87-a5ae028ad5a9` passed on their respective pre-fix trees;
neither is claimed as final post-normalization evidence.

Final conductor ticket `24eafbdb-e608-4c20-aa36-4f6064223221`
(`m9-stream-attachments-v4`) passed **255 tests** after directory normalization:
ACP execution 11, ACP tool correlation 10, image retention 30, quiet lifecycle 25,
transcript retention 12, standalone attachment runtime 6, deletion 21, standalone
stream runtime 5, pane presentation 42, pane snapshot publication 4, Claude
compaction usage 4, Claude plugin bridge 11, Codex resume/wedge commit 74.
Final lint `8e6245da-f558-43e5-bf2c-ccde2566c96a`
(`m9-stream-attachments-lint-v3`) passed on the same Swift tree. Scoped formatting,
not a repository-wide baseline, preceded these runs. No visible app lifecycle
action was taken.

The first commit preflight rejected the additional test-file count (`340 > 339`).
The two new runtime-effect suites were consolidated, without dropping tests, into
`AgentSessionProviderEffectsRuntimeTests.swift`; no baseline was raised. Conductor
`3a532555-fe8b-4c3d-96ac-53c6b9688026` passed all **11** consolidated tests.

This is still not final M9 acceptance. Provider input, binding/MCP interaction,
queued-work and terminal/handoff services, exact domain catalog composition, the
saved execution host and bounded retirement remain in M9. The prepared-window
factory and close-cancels-run path still exist; M10's target move is untouched.

### M9 continuation — runtime MCP publication (2026-11-07)

Moved actual MCP snapshot/interaction projection, instruction/observation signalling,
terminal domain publication and Oracle delegation promotion/removal into scope-owned
`AgentSessionMCPRuntime`. Run hooks and Codex use the concrete runtime; optional
presentation binding updates no longer gate remote state publication. Session names
and parent-worktree metadata remain catalog composition inputs. The domain session
store, attempt lifecycle and terminal barrier remain the existing authorities.

Review distinguished a committed domain effect from permission to start its successor.
A terminal publication may settle after presentation removes the originating object;
its activation/registration still owns publication, but only the current scope/object/
binding may receive the successor epoch. The barrier now also checks its bound
successor capability before consuming a queued follow-up or provider successor, on
both first completion and duplicate-commit paths. A rebind or Stop cannot reinterpret
a successful domain publication as permission to start work on a new incarnation.
The committed result is retained rather than mislabeled as no effect or stale.

First conductor ticket `e3e2c0c8-5570-4bb5-ab83-cead31e008eb`
(`m9-mcp-runtime-v1`) failed compilation before tests: the new metadata adapter's
nested closure needed explicit `self`. The adapter now takes the authoritative
control-context session ID directly, also preserving the former index lookup key.
Post-review conductor ticket `74fd2273-c075-4eb8-8205-5ff8182fb538`
(`m9-mcp-runtime-v2`) passed **125 tests**: lifecycle contracts 4, MCP steer/resume
25, start budget 6, standalone attachment 6, standalone MCP runtime 5, standalone
stream 5, Codex resume/wedge commit 74. The barrier fixture exercises both queued
and provider-specific successors across a held, real domain publication followed
by a binding rotation, including duplicate commit. Another fixture verifies an
object removed from the scope still publishes its owned terminal result without
updating the replacement or sending a stale instruction wake. These fixtures
construct no window, prompt VM or workspace VM. Lint ticket
`f931d0f2-1505-4472-ae26-75dbc3867e11` passed on the same Swift tree.

This is a user-requested **draft PR checkpoint**, not full M9 or PR-ready acceptance.
All prior receipts above remain scoped to their recorded checkpoints. A full-suite
run, fresh final-head product/compiler-index qualification and live MCP smoke have
not been performed for this draft head. No visible app lifecycle action was taken.

M9 is still incomplete: terminal preparation/post-settlement continuation, provider
input and interaction cancellation, workspace-rooted execution routing, domain
catalog composition, saved runtime host adoption and bounded retirement remain.
The new runtime does not claim that detaching today's window leaves its run alive.

### M9 continuation — runtime interactions and joined cancellation (2026-11-07)

Moved the actual question/approval/instruction cancellation and interaction-state
reconciliation into `AgentSessionInteractionRuntime`. The scope now owns approval
subscriptions and their cancellation effects, using the existing approval store and
its existing route/tab namespace, not a window or a new approval authority. Codex's
observer protocol no longer requires a view-model argument, and its reconciliation
calls no longer depend on a weak view model. Worktree review cancellation retains
its operation-state mutation and persistence; sidebar/permission projection is an
optional exact-object presentation sink.

Subscriptions apply only to the original object and join unsubscribe during teardown.
Admitted approval cancellation retains the original scope through the store effect;
a cancelled drain waiter does not acknowledge that work early. The production terminal
binding joins that exact session's cancellation effects before domain publication.
The legacy window-close path also joins them before clearing approval namespaces.
The route ID is immutable in this composition; presentation attachment is not permission
to replace an existing approval namespace.

Review identified two different cancellation races. A detached old object with no
known review cannot cancel its replacement's whole namespace. Conversely, an exact
review ID from a stale UI snapshot cannot identify all work already admitted by the
stopping run. Current exact owners now cancel through a monotonic admission cutoff
in the existing approval store; detached owners may only settle a known exact ID.
Buffered pre-cutoff review snapshots cannot resurrect a finished run. Reviews admitted
after the cutoff remain untouched. The admission instant is process-local, not a
persisted identity or a wall-clock deadline.

Initial conductor `e5529124-e7e4-4cac-82a4-a021283e95c1` passed **127 tests** before
review fixes. Its misspelled MCP steer/resume filter matched no tests in that suite;
it is not an MCP integration receipt. Expanded post-review
`a14512cd-4517-42a1-b8a3-16cc19fa6ebe` ran **156 tests with one failure**: the
scope-decision fixture's delivery wait timed out. The four new runtime tests passed.
Diagnostic tickets `4a640734-126c-4134-bd7a-8bdd9109771e` and
`2bed34b0-f55c-4707-85ec-44164f0d5d5b` reproduced it: the notice was admitted and
submission returned, but the fixture changed its wait identity while delivery was
being prepared. Production `awaitNextInstruction` installs the wait ID before its
continuation; the fixture now does likewise in one actor pass. No deadline, delivery
assertion, production refusal, or retry budget was weakened; temporary tracing was
removed.

Final conductor `a20e8837-742f-4869-bea8-d7ce088cbed0`
(`m9-interaction-runtime-v3`) passed **156 tests**: MCP steer/resume 25,
standalone interaction runtime 4, worktree persistence 3, Claude approval/resume 38,
Codex resume/wedge commit 74, approval response binding 3, worktree review state 9.
Final lint `f01e97fc-843a-4196-a947-cb2da6017024`
(`m9-interaction-runtime-lint-v2`) passed on the same Swift tree. Earlier lint
`b8ebb982-195d-45c3-80fc-fecf7c6228fc` passed before the fixture correction.

This is still a runtime-composition transition, not completed M9 acceptance. Independent
writer admission/adoption, provider-input and remaining continuation composition,
window-free saved execution and routing, presentation handoff, bounded host retirement,
and final product/index/full-suite qualification remain open. No app lifecycle action
or publication was performed for this continuation.

### M9 continuation — retirement admission and acknowledged handoff (2026-11-07)

The runtime scope now marks retirement independently of a window registry entry.
New bindings are refused while the originating writer retains its exact capability
for final IO. Once the host has joined owned effects and acknowledged its final save,
writer claims are released explicitly; retaining an old presentation cannot retain
or resurrect those claims. Dirty sessions, in-flight writes, pending attachment retention
and unsettled terminal publication cannot be released. Final-save orchestration joins
retention and an already admitted write before freezing the last payload.
This is an admission/drain correction, not the completed window-free host cutover.

The prepared-owner registry no longer treats moving an owner to its retiring map
as permission to admit a successor. It owns the entire drain before link invalidation's
first await. Teardown callers join one task. Failed final saves retain the in-memory
owner and pending visit, including failures during a direct UI handoff; cleanup does
not automatically retry storage. An explicit visit can retry the final save and owns
its activation, superseding an older deferred visit. An automatic retirement instead
reads the latest queued visit after acknowledged drain. Durable deletion is a new
settlement fact which releases a previously deletion-blocked drain without hydrating
its queued visit. Shutdown still uses the existing absolute budget and cannot claim
that a timed-out write completed.

Review identified and corrected failed-handoff state placement, the pre-teardown
invalidation gap, recursive duplicate visits and deletion-settlement cleanup. Existing
lifecycle, link, deletion and persistence authorities remain unchanged; no second
host manager or durable-ack shortcut was introduced. Added a window-free scope
regression and production saved-target cases for mid-drain visits, failed retirement
and direct-handoff saves, explicit retry and in-progress deletion.

The first conductor ticket `b77d76b1-7b7c-4f01-8539-b83ec63bb8c6` passed **9
runtime-store tests** before review fixes. The prepared-owner filter used the file's
wrong XCTest class and matched no integration tests. Expanded
`dd9299e3-13cd-409d-84a0-53d13fbeae8c` passed **109 tests** (handoff inheritance 100,
runtime store 9), still without the intended saved-target integration suite. Lint
`ba227228-b011-44d1-bc6d-ce625da4cf82` passed that Swift tree.

Corrected integration ticket `e692bec1-4caa-4c15-a2bb-79921420e4b8` was cancelled
after three completed tests failed before the retirement branch: the requester never
received the target's terminal result. Diagnostic
`4e55eb68-ed4e-4057-bb68-31135f38baf9` reproduced the failure in one case. The result
notice was queued and retried while the requester was running, then retried while
terminal publication remained in progress. No retry followed settlement. The scope
decision owner observed only `objectWillChange`, but runtime terminal/composer/hydration
settlement uses the existing `monitorReadinessChangePublisher`. It now observes that
channel too, retaining the same decision queue, stop fences and delivery transaction.
A causal regression holds terminal publication, witnesses the refusal, and releases
it without a UI publication; no timeout or delivery assertion is weakened. Temporary
tracing was removed. Targeted confirmation `098d2f20-3562-4a33-b482-80c6ed0f9c43`
passed **3 tests**: both scope-decision regressions and the held final-save retirement
integration. Expanded ticket `29654cff-6ad5-49b0-a8ef-cdeb43436d7b` executed **159 tests**
with one failure: the direct-handoff failure fixture's injected saver strongly retained
its owner, so the final lifetime assertion timed out after the save/retry assertions
passed. The fixture now captures that owner weakly; production drain guards and test
timeouts are unchanged. Lint `a67b99e3-11df-4ab2-b696-30e270d998c1` passed before
that capture-only fixture correction.

Corrected ticket `4fb36955-d86b-4802-8b61-4ce139654638`
(`m9-writer-retirement-v6`) passed **159 tests**: MCP steer/resume 26, standalone
attachment runtime 6, handoff inheritance 100, runtime store 9, and prepared-owner /
managed-run inventory integration 18. Final lint
`030c1342-9105-430c-afe8-79b4221dc6f6` passed the same Swift tree. Both products
(`RepoPrompt` and `repoprompt-mcp`) passed conductor ticket
`bf41842e-f6f6-48ec-8cb4-41abe2c9fee3`. The immediately following fresh compiler-index
check passed at **1,226/1,360 wrong-way file edges** and **53/66 largest-cycle
components**, with no baseline increase (`.build/modularization-index-m9-retirement.json`).

These receipts qualify this checkpoint, not completed M9. General writer admission
with agreeing UI replicas, actual window-free run-host/input/continuation composition,
MCP/admin/scope/link runtime routing, and replacing the prepared `WindowState` factory
remain open. Full-suite qualification and live smoke are not claimed. No app lifecycle
action, publication, push or PR-state change was performed.

### M9 continuation — Codex runtime effects and partial-write receipts (2026-11-08)

The Codex coordinator now sends usage, activity, assistant-delta and refresh effects
to the existing concrete usage/presentation runtimes instead of 87 weak-VM call sites.
Usage and originating run timestamps remain live without a presenter; optional
presentation dispatch is exact-object, not a lookup of a potentially recycled tab ID.
Production attachment installs the scope services. A standalone coordinator also owns
concrete services without constructing a window or view model. The one refresh sink
carries the existing full/transcript-runtime/runtime-metrics scope, preserving narrow
publications. The in-memory refresh enum moved with a VM alias; persisted/reflected
identities are unchanged. This does not remove the remaining provider-input, route,
factory or continuation dependencies and is not a window-free run-host claim.

Full-suite ticket `b1569e4c-37d2-46c9-8ff1-c1a4cc9fcc62` at `a04d7902a` was cancelled
at 15m59s after 3,114 completed case passes and one failing case (two assertions).
It is **not** a full-suite pass. The compaction test expected a successful required-save
acknowledgment followed by `session_not_exclusive` / local cancellation. An exact writer
that loses exclusivity while its saver is suspended now correctly refuses that
acknowledgment: the existing compaction transaction returns `persistence_indeterminate`
and preserves a recovery note. Its test now commits a real payload before admitting the
competitor, proves the reservation exists on disk, drains the refused debounced save,
and verifies recovery rather than executable work on reload. No production persistence,
writer or native-dispatch guard was relaxed.

New coordinator regressions exercise actual native turn/usage events without a VM,
presenter detach during a turn, and production VM attachment followed by a reused-tab
replacement. Review also removed a redundant optional scoped-refresh callback in favor
of one explicit scoped sink. The old usage VM methods were verified to be forwarding
only. The unchanged compaction branch after a successful required-save acknowledgment
is distinct from the tested failed-acknowledgment branch; `selfCompactState` already
marks changes dirty, and this work does not redefine local cancellation as a disk receipt.

Initial focused ticket `c46ea92f-f58f-4273-88a3-704c86657173` executed 146 tests with
one failure in a new assertion: Codex's reported window belongs to
`contextUsageSnapshot.window`, not the separate non-Codex capacity field. The new
disk-backed compaction case and the other 144 cases passed. That assertion was corrected
without changing the accounting implementation.

Corrected ticket `f43ba7bf-6d37-4d9a-8a80-636c2f0698f7` (`m9-codex-effects-v2`)
passed **150 tests**: standalone/production Codex runtime effects 2, interaction runtime
4, compaction transactions 26, context load 40, presentation runtime 4, and Codex
resume/wedge commit 74. Lint ticket `7d82eeac-5909-4c65-b059-8512d1edec34` passed
the same Swift tree. Scoped formatting and independent review were performed; no
ratchet baseline changed. The earlier product/index receipt belongs to `a04d7902a`,
not this new integration. Full-suite qualification and live smoke remain unclaimed.
General independent writer admission, real run-host/input/factory/continuation
composition, window-free saved execution and presentation-preserving close remain
open. No push, PR-state mutation, merge, or app lifecycle action was performed.

### M9 continuation — self-compaction consumes the runtime writer (2026-11-08)

Retired self-compaction's same-VM/all-windows competing-writer scan. Admission and
its deferred compact/note owner fences now resolve the process-owned exact writer,
including scopes with no window or view model. Workspace, session, exact live object,
tab and binding generation must match. A retiring scope refuses new admission and
provider dispatch without revoking its originating final-save capability. A same-key
replay of an already acknowledged reservation remains a query and can report its
existing receipt during retirement; it does not admit or dispatch new work.

Failing-first ticket `089a822e-e9a6-4ce5-b6e1-6d65a7d2a792` reproduced the old
window-census defect (one test, three assertion failures): a window-free competitor
was missed, a reservation/key was spent, and required save then failed before IO;
removing the competitor could no longer admit a fresh retry with that key. The
regression now distinguishes pre-admission refusal from the separately covered
post-write indeterminate receipt. Coverage also exercises retirement before admission,
retirement during required save, and a window-free competitor or retirement after an
acknowledged receipt but before deferred provider dispatch.

Ticket `701ff66e-9197-4c6e-9938-b1bf8175c6b1` failed before tests: the deferred-owner
fence still referenced the deleted helper. Review caught the same remaining caller;
it now uses the exact runtime authority too. No duplicate window scan remains in this
self-compaction path. Ticket `f3a6ca02-c4e9-4405-b500-a156742146a5` executed 45 tests
with three retirement-fixture failures. The ordinary test VM is not a prepared workspace
projection, so its guarded prepared-window retirement adapter correctly did nothing.
The fixtures now enter retirement through their exact runtime writer's scope; no
production guard or timeout was loosened. Lint `e9ef7ea8-87bf-410b-9a0c-987fb6a90705`
passed before that fixture correction. Corrected broader validation receipts follow;
this is a consumer cutover, not completion of general first-mutation admission or the
window-free execution host.

Corrected expanded ticket `165239bf-b387-4d05-8f99-a5a6565eca74`
(`m9-compact-writer-v4`) passed **169 tests**: 168 selected app tests across native/ACP
self-compaction state, scheduler, completion, actual transactions and related link
consumers, plus one domain tool-catalog policy case. This includes all 30 compaction
transaction tests (four new admission/retirement cases), nine runtime-store cases,
four real payload-writer cases and both Codex runtime-effects cases. The regex also
selects individual compaction-related methods in other link suites; this is not a
claim that those entire suites ran. Final lint
`c360db7f-bbbe-426c-9aa2-22ca5a3c7cfa` passed the same Swift tree. No baseline increase,
push, PR change or visible-app lifecycle action occurred. General writer admission and
the actual window-free run-host/routing replacement remain open; the incomplete full
suite recorded above has not been converted into a passing receipt.

### M9 continuation — runtime-owned resume handoff preparation (2026-11-08)

Retired VM-owned ordinary handoff prepend/send-consumption and the unqualified
post-await resume-recovery assignment. `AgentSessionHandoffRuntime` now belongs to
one runtime scope. Its preparation retains that scope and captures the exact session,
persistent binding and transition generation, Stop fence, originating run/attempt,
agent and an in-memory handoff revision before workspace-context IO. Commit rejects
replacement, rebind, retirement, cancellation, a new run, or an intervening handoff,
including change-and-restore. Transcript and model changes alone do not discard a
valid frozen cutoff snapshot. Existing handoffs bypass transcript reconstruction.

The ordinary pending-handoff value and three provider-switch composition/dispatch
values are now runtime-owned with VM compatibility aliases; fields, physical-dispatch
rules and persisted session schema are unchanged. Prepend and send-outcome hooks use
the concrete runtime, not a weak VM callback. The originating runner still owns
physical dispatch and send-outcome qualification; this is not a new delivery authority.
Provider-switch confirmation remains separate from ordinary handoff consumption.

Review caught the required caller consequence: refusing stale preparation must not
silently start a contextless fresh provider. Claude and ACP now require a successful
recovery result before fallback; ACP also rechecks its exact attempt after that await.
The worktree transition caller propagates refusal as stale before provider-context
invalidation, rather than interpreting it as an absent optional handoff. An existing
handoff and a newly staged one remain distinct so worktree rollback only owns the
payload it actually staged. Production Claude recovery coverage uses the real VM
hook and checks the recovered transcript in the fake controller's provider input;
the isolated runtime cases construct no WindowState, PromptViewModel or workspace VM.

Validation iterations: `9e788ef2-967b-4f15-817f-6e31b9c9a73e` failed before tests on
invalid throwing capture-list syntax in the new cancellation fixture.
`febce8fa-a2e6-4fcd-a88f-f028c3beeef1` failed before tests on a test factory's wrong
arity. `3a4a0ad2-628d-4a85-8b40-fadc6e456a2a` failed before tests on a missing
required route-recovery argument in the strengthened integration test. These were
fixture/compiler errors, not passing execution receipts. Lint
`e5674596-f1ec-4339-97ad-62053b3dfbed` passed before the final fixture and worktree
caller corrections. Corrected execution receipts follow below.

Ticket `f1ac0726-b20a-4c5a-8116-4120e48dd1d5` executed 240 selected tests with
seven failing cases (14 assertions, including six unexpected assertion/throw reports).
All six new runtime cases passed. The strengthened Claude integration fixture reused
one controller after shutting down its event stream; it now supplies a distinct fresh
controller, like production. The durable worktree fixture also installed its session
binding before attaching a workspace and never qualified that binding afterward. It
now creates the exact carrier and exercises the production qualification CAS before
granting restored readiness; the production unscoped-writer refusal is unchanged.
Four worktree cases reported `ambiguousGitTopology` in unchanged repository-exclude
reconciliation; their cause is not attributed to the handoff change without further
evidence. These failures are being isolated rather than hidden by longer timeouts or
weaker assertions. Lint `688b2577-e8b1-43dc-a73a-8db41af6331f` passed before these
last fixture corrections.

The next focused ticket `5e2db468-c19b-4c24-8907-398340e2d0d1` ran 50 tests:
49 cases passed and the Manage-link case failed two assertions because it still
expected a nil carrier after the fixture began installing an explicit carrier.
Its CAS now asserts the already-installed exact session ID. All four prior topology
cases passed on this run; their earlier failure mechanism remains unproven.
Final ticket `ee1ee17e-aaac-4911-916c-2440ddd31b32` passed **251 tests**: ACP execution
11, ACP identity 13, provider switching 39, standalone handoff 6, periodic resume
failure 2, handoff inheritance 100, worktree admission 42, and Claude approval/resume
38. The ACP execution suite is selected by its actual class name, not the earlier
nonmatching filename-like filter. Final lint `6d5c6f8f-1e7c-4482-bf47-d46ffa447053`
passed the same Swift tree. No production identity guard or timeout was weakened.

Remaining: workspace-context capture is still supplied by the VM composition;
independent first-mutation writer admission, provider input/link/continuation
composition, actual window-free saved execution, and presentation-preserving close
are not completed by this extraction. No target move, push, PR change, merge or
visible-app lifecycle action occurred. The earlier incomplete full-suite run remains
unqualified until a new full run completes.

At committed head `941d5f61e`, conductor product build
`7786bccd-c4fb-4524-8f35-b4a1828976e8` passed for both products. A fresh compiler-index
dump/check passed with **1,223/1,360 wrong-way file edges** and **53/66 cycle
components** (1,109 files; 154,581 symbols), before the full-test cache transition.
Full-suite ticket `c3cd5637-2b97-49c7-8b77-026bd72de532` subsequently reached its
existing 3,600-second job limit: **6,837 completed cases, 19 failing cases**, with
execution interrupted during `WorkspaceOpenFolderOrchestrationTests`. This is an
incomplete, failed run, not a full-suite pass. The earlier waiter timeouts did not
cancel or resubmit the job.

One failure was traced to the delegation census fixture installing an unscoped
binding, then invoking archive's required payload save. The fixture now uses the
production runtime binding path and asserts the workspace qualification; production
writer admission remains unchanged. The other 18 failing cases were in
`SessionAdminWorktreeRecoveryTests`, with watcher `streamStartFailed` errors and
follow-on mutation/receipt assertions. A process inspection during the run counted
2,712 numeric descriptors, including 2,226 pipes, but this observation alone does
not establish the failure cause or attribute it to a baseline. The affected suites
are being rerun in a fresh test process; no timeout, guard or assertion is relaxed.
Fresh-process ticket `5b5115be-f054-41f6-a8f9-39c9c1463489` passed all **47 tests**
(delegation membership census 17, worktree recovery 30). This confirms the fixture
repair and a passing isolated worktree suite, not the cause of the full-run watcher
failures and not a substitute for complete-suite qualification. The existing
conductor `ci-shard` operation provides per-suite process isolation for final
whole-suite validation; the failed monolithic run remains recorded above.

### M9 continuation — runtime-owned queued draft recovery (2026-11-08)

`AgentSessionDraftRuntime` now owns the existing pending-tab draft storage and
fragment acknowledgement ledger, restoration composition, stale-editor stores,
snapshot acknowledgement, and lossless route-refusal withdrawal. Run-service
recovery hooks retain this concrete runtime and pass the exact originating object,
not a tab UUID resolved through a weak view model. Composer/reprompt/slash-command
updates are optional exact-object presentation callbacks; detaching presentation
cannot discard queued user work. Existing provider and terminal authorities still
own queue withdrawal and delivery; no new queue, acknowledgement counter or
persisted schema was introduced.

Review identified the important difference between replacement and absence:
compose-tab removal detaches the object **before** joining cancellation. A different
live object reusing the tab ID refuses late recovery, while an absent object still
uses the existing pending-tab storage (needed for stash). Final claim release
refuses new recovery. Tests cover both cases, presentation detach, fragment
acknowledgement, and plain-text route refusal without constructing any UI owner.
An integration test also covers an explicitly bound but unmaterialized tab: draft
reads/writes do not create a runtime, and `makeSession` consumes the pending draft
exactly once when materialized. The legacy per-tab acknowledgement semantics and
cleanup sites remain intact.

Initial ticket `9bacd207-7824-4bad-a13c-e484d5dc57b6` passed **110 tests** before
review's absent-object correction and two additional cases. Its route-refusal
filename-like filter matched no tests; the final route integration is selected by
actual XCTest class names. Final receipts follow below. This is a required service
composition transition, **not** independent writer admission or a complete
window-free execution host. Those M9 gates, presentation-preserving close and full
validation remain open; M10's target move is untouched.

Final ticket `4f570216-a139-4f99-ae3e-7c6984b3c801` passed **198 tests**: draft
restoration 11, composer submission 39, reprompt submission 40, ACP steering 27,
managed Stop 34, delegation census 17 and worktree recovery 30. Route-integration
ticket `68e11731-51db-4474-a3d5-b69a5221cd24` passed **2 tests**, exercising the real
Claude and Codex pre-dispatch refusal paths. Lint
`c38cafb9-ab28-44c6-8ef1-a76193317ee1` passed the same Swift tree. Scope-only runtime
coverage includes presentation detach, absent-versus-replaced objects, final release,
lossless user-row withdrawal and acknowledgement; existing VM integration preserves
reprompt mutation and composer presentation behavior. No visible app action, push,
PR edit or merge was performed.

The final diff check additionally fenced restoration-event delivery against a
synchronous presentation observer replacing the tab during `draftChanged`. The
runtime captures the originating object before notification and refuses to deliver
that event to its replacement; a deterministic reentrant-observer test covers it.
VM fallback publication also captures whether a runtime existed before the callback.
Final corrected ticket `01b26cec-fa0f-45d3-82ec-811e9fbc3e1c` passed **201 tests**
(the same suites above, draft restoration now 12, with both route integration cases
included). Final lint `2ccb656a-316a-44d2-8ded-9b937c83fa13` passed this Swift tree.

### M9 CI repair and main reconciliation (2026-11-08)

Merged current main `58e3e33de449e80e3b9a372d49bbf9be1d7bec53` without rewriting
history (`c1c9fd5c4`). The sole textual conflict was the persistence-owner comment
in `AgentTabSession`; runtime-store ownership and main's Oracle-background fields
were both retained. Main's Oracle cancellation/drain and transcript-rendering
changes remain intact. The user redirected work to this merge and CI repair;
clean-build ticket `8e55d34d-9949-4157-bd3b-76d3a46c7aa7` was cancelled, not passed.

The full artifact for hosted run `42373863311`, job `128407913364`, shows a
successful compilation and passing type-check counts (6/10 bodies, 3/6
expressions), followed by a **439/430 first-party warning-ratchet failure**.
Nine diagnostics were introduced by M9's never-reassigned weak local lifetime
witnesses. These, plus three equivalent witnesses in the subsequent local M9
commits, now use `weak let`. Weak ownership, deallocation assertions, cancellation
checks and runtime behavior are unchanged; no warning limit was increased.
Independent review found no issues with this bounded test correction.

The merged tree's clean enforcing build `f93f3640-40e7-4786-a3ae-00604ae952a7`
compiled successfully and removed all targeted diagnostics, but **did not pass**
the aggregate warning gate: 449/430 on local Xcode 27.0 / Swift 6.4, versus the
hosted job's Xcode 26.6 / Swift 6.3.3. A normalized diagnostic comparison shows
additional diagnostics outside these test edits, including newer capture,
SwiftUI macro and C conversion diagnostics. Type-check counts passed at 5/10
bodies and 2/6 expressions. This is not a clean-warning receipt; hosted-toolchain
confirmation remains necessary. No unrelated warning cleanup or suppression was
added to make the newer local compiler fit the older budget.

Product ticket `9eaa842b-5d1a-4f19-abe0-131f26b12374` passed both products. Its
fresh compiler-index check passed at **1,225/1,360 wrong-way file edges** and
**53/66 cycle components**. Focused ticket
`e5249b2c-f9e6-46b9-a7fd-dab38af83ef9` passed **141 tests** across the runtime
lifetime/effect suites, managed Stop, Claude approval/resume and Oracle-group
cancellation integration. Initial lint `fd296860-25ed-4285-adfb-885a378ff239`
found one merged documentation-comment formatting issue; the pinned formatter
corrected only that comment after the build/test receipts. No test rerun is
claimed for the comment-only correction. Final lint
`01fb3aeb-2426-46eb-bba6-1c139fdb7750` passed. The merge commit passed the mandatory
staged preflight; the repair commit and push use the same staged/outgoing safety
gates. Hosted CI must confirm the new published head.

M9 is still partial: independent writer admission and window-free execution/
handoff remain open, along with complete-suite and live-smoke qualification.
This repair does not claim M9 completion. No visible app lifecycle action occurred.

### M9 continuation — cancellation before control visibility (2026-11-08)

Retired the app's publish-then-install cancellation sequence and its weak-VM
shutdown callback. `DomainAgentRunSessionStore` can now atomically bind an exact
registration-qualified cancellation capability while creating or reclaiming its
record, including before a resumable claim awaits persistence. A suspended claim
rechecks ownership before accepting or rolling back; it cannot remove a successor
registration or undo shutdown. Existing registration, durable metadata, execution
orchestration and terminal-barrier authorities remain unchanged.

`AgentSessionMCPRuntime.ControlActivationCancellation` retains the originating
runtime scope and concrete run-service cancellation command independently of a
presenter. Cancellation during setup prevents control publication. Publication
also refuses a retiring scope. Installed control can still drain during binding
transition/deactivation, but cannot cancel a replacement persistent binding or
another activation/registration. Domain cleanup releases the retained scope.
Deactivation already removes its handler even when keeping the registration; the
legacy install API remains because direct/headless composition still uses it.
This is not a claim that the direct/headless startup path or full saved host has
completed the same cutover.

Regression witnesses cover cancellation at the real pre-publication activation
seam, scope lifetime without a VM/window, installed drain during retirement and
binding preparation, same-ID rebinding refusal, cancellation of a pending
activation without touching prior control, and a real persisted resumable claim
held before CAS while a successor registration replaces it. No sleeps, increased
timeouts, weakened identity checks or parallel cancellation registry were added.
Review prompted the split between setup eligibility and installed drain ownership.
Incidental formatter changes to the domain target's existing Sendable declarations
were reverted; the target's concurrency contracts are unchanged.

Initial ticket `242e0ad2-584c-4979-973a-f4f57af1678c` passed **81 tests** before
review refinements. Expanded ticket `7742ea8d-feaa-4103-bfa4-bf925b115d4c` passed
**182 tests**. Final ticket `c021386e-963a-437f-b304-150618d6d1fd` passed the same
**182 tests** after the retirement fence: MCP steer/resume 27, start budgets 6,
first save 47, runtime MCP 8, Codex resume/wedge 74 and workspace-scoped routing 20.
Lint `647dc8ad-edc6-4d24-817c-16fd4333d0c4` passed the pre-retirement-fence tree;
final lint `3d241768-2718-4a77-99c3-196ed098a8d7` passed the final Swift tree.

Independent writer admission, canonical catalog-backed saved execution, remaining
provider/input composition, runtime-addressed MCP/admin/link commands and
presentation-preserving host handoff/drain remain M9 gates. This checkpoint does
not qualify the final full suite, products/compiler index, warning ratchet or live
smoke. M10 is untouched. No push, PR edit or visible app lifecycle action occurred.

### M9 continuation — direct-host startup cancellation and drain (2026-11-08)

Retired direct/headless Agent startup's publish-then-install cancellation sequence.
The existing domain store now receives the exact activation-qualified cancellation
handler atomically with registration, before epoch preparation or running visibility.
The coordinator tracks the setup operation from its first suspension through task
attachment or rollback; shutdown joins that operation, including root preparation.
Cancellation after running publication but before task attachment prevents physical
provider launch. Installed cancellation joins the exact registration's task through
terminal publication rather than treating `task.cancel()` as settled work. Old task
completion cannot publish into a replacement registration. No second registration,
terminal, or persistence authority was introduced.

Setup failures now roll back the prepared root overlay and clean up their exact
registration, including caller cancellation after epoch admission. Existing domain
cleanup intentionally retains dormant resumable metadata; this slice neither erases
that history nor changes its retention policy. A generation-zero registration from
an already-shut-down store is cancellation, not an internal epoch error. The existing
domain shutdown deadline still determines cooperative versus interrupted settlement.
This does not replace the app's prepared-window host or finish general writer admission.

Six new deterministic regression cases cover atomic pending cancellation, domain
shutdown joining held setup, caller cancellation after admission, cancellation of an
already-visible running start before physical launch, coordinator shutdown joining
rollback, and an already-shut-down store. They use the real domain store, a held epoch
or post-publication seam, and a provider-launch file witness; no visible app is created.
Initial ticket `9752d41c-fb7f-4aac-8f33-676a451b2689` ran 40 tests with three new
assertion failures: the fixtures incorrectly expected canonical dormant metadata to
be deleted. The assertions now explicitly verify preserved dormant/resumable history,
zero live registrations/handlers, and the cancellation outcome; production cleanup
policy was not weakened. Ticket `0f30235c-162b-4499-bfc1-517ad79b7664` passed 41 tests
(the additional nonexistent `DirectHeadlessRootOverlayTests` filter matched none).
Expanded `4fa2f12f-6f15-4ddc-9d7b-dc76b4adb47d` and
`c69aa911-2e9b-4471-91fa-61e6b6078c1d` each passed 106 tests. An explicit local
coordinator capture removed the edited path's compiler capture warnings without
isolation escape hatches or formatter suppression.

Final ticket `e1c4a56a-9650-4933-bd82-304810d3b07c` passed **106 tests** after extending
setup ownership before its first suspension: startup/payload 8, direct composition 35,
context builder 6, file read 2, search 11, workspace visibility 4, Oracle groups 29,
working-directory binding 6, and execution contracts 5. Final MCP product build
`e78947f3-2f57-4e85-bce9-a51c4d277b03` and lint
`3b81b2e6-c4e4-4908-92b4-6d96ea7b596f` passed the same Swift tree, with no compiler
warnings from the two edited files. Earlier MCP product
`5c4bbf73-7426-4d7b-9e67-a88208e0cd64` and lint tickets
`08149446-6d50-4f18-bf0d-c50991ca97cc` / `92e4c523-3e45-4394-aec1-6a9a6cb0d384`
also passed their respective intermediate trees. The change received one independent
review and uses the mandatory staged contribution preflight before commit.

M9 remains incomplete: independent app writer admission, remaining provider-input
composition, canonical saved-target execution without WindowState/PromptVM/WorkspaceVM,
runtime-addressed commands, presentation-preserving handoff/drain, and final whole-PR
qualification remain open. This receipt does not qualify the full app product, a fresh
compiler index, the aggregate warning ratchet, the full test suite, or live smoke.
M10 is untouched. No push, PR edit or visible app lifecycle action occurred.

### M9 continuation — runtime-owned route mappings and saved-target CI fixture (2026-11-08)

Retired MCPServerViewModel's storage ownership of the five synchronous run/connection
projection maps. `MCPRunRouteBindings` owns their actual storage, registration,
replacement, pending-policy token capture and generation-fenced rollback. Existing
view-model accessors use `_modify` to mutate the same dictionaries without a copied
mirror or per-mutation copy-on-write cost. Context promotion, domain publication,
read-selection handover and transport replacement effects retain their existing owners
and ordering. DomainRoutingCoordinator remains the routing authority.

AgentSessionMCPRuntime now retains the concrete mapping owner, not the MCP view model,
and performs the final exact route/tab, bidirectional mapping and live-connection fence.
A composition-owned availability witness preserves refusal when the legacy server is
gone: retaining a stale map cannot by itself authorize dispatch. This witness grants
no domain authority and does not choose a session writer. The legacy server still owns
route availability; the actual independent host and canonical endpoint routing remain
unfinished. Rollback checks its token before running synchronous context cleanup, so
an obsolete token cannot clean up a successor or resurrect a displaced pending policy.

Three standalone tests construct no window or view model and cover exact mapping,
replacement/rollback generations and retained storage with owner loss. Existing real
transport-removal tests now call the runtime fence and check absent/wrong-route hosts,
then prove removal refuses physical provider dispatch while the mapping still exists.
The change received one independent review. The review's lifetime finding prompted the
availability witness; existing per-VM scope and immutable route composition were verified.

Initial `07ea97b3-04e9-454b-be30-baeb53c9adee` failed compilation before tests because
new files lacked the explicit MCPServer token import; imports were corrected.
`8515640a-436c-4f0b-a942-372600aede24` ran 102 tests with two failing cases (six
assertions): clearing the fixture's final-fence hook enabled its synthetic-route test
bypass. The corrected fixture explicitly calls the real runtime fence rather than a
simulated boolean. `5dbfad89-717a-4c50-b049-058abd9afb1b` then passed all 102 routing
cases and reproduced the separate hosted inventory failure with its exact refusal.

Published-head CI run `42400768704` at `24521f822` completed: build/static gates and
shards 1–3 passed; shard 4 failed the reduced-consent approval test. The Style job was
an aggregate prerequisite failure, not a formatter failure. Local reproduction showed
`target_not_preparable / target_missing`: that fixture created only an in-memory index
row, not the saved target required before requesting consent. It now saves the exact
target through AgentSessionDataService, explicitly disables global auto-approval for
this card-flow test, cleans up its scope, and also asserts no management link was made.
Production missing-target and capability guards are unchanged; no timeout was increased.

Final `010e53ab-0562-44f4-85ce-d8ea0bc55a43` passed **178 tests**: Codex adapters 41,
native/headless adapters 31, runtime MCP 8, Context Builder transactions 19, route
bindings 3, and the complete inventory-read suite 76. The apparent drain-test stall
was not established: the process finished before a read-only sample could attach,
and that case passed in 5.6 seconds. No job was cancelled. Lint
`49dbdc5d-ccff-4e9a-8f49-22ea5a609e2c` passed the intermediate tree; final lint
`047d27bd-365f-4301-80b5-b6d673445815` passed after the fixture corrections. Subsequent
source edits only clarify ownership comments. Scoped formatting, direct diff review
and mandatory staged contribution preflight apply to this checkpoint.

M9 still needs independent writer admission, canonical window-free saved execution,
remaining provider-input/command composition and presentation-preserving handoff/drain.
Fresh final products/index, aggregate warning enforcement, full-suite and live-smoke
qualification are not supplied by these focused receipts. The hosted fix is local and
unpublished. No push, PR edit, merge, visible app lifecycle action or M10 target move.

### M9 continuation — runtime-owned interaction commands (2026-11-08)

Retired the view model's implementation of shared question/approval response parsing,
question continuation settlement, user-input settlement and managed interaction response
policy/application. AgentSessionInteractionRuntime now owns those actual bodies; the
legacy view-model entry points forward exact objects. Managed response holds the exact
scope across authorization and rechecks object, persistent binding, transition generation,
interaction and grant before submission. Endpoint/catalog proof remains separate and is
still supplied by the legacy adapter; this is not independent host admission. Existing
ACP one-time permission authority, redaction, manual-only restrictions and approval stores
remain unchanged. Response effects join the runtime's existing effect drain.

The response payload and validated resolution are neutral, nonpersisted values with
compatibility aliases, not reflected/Codable schema changes. Concrete provider commands
are weak references: RunService owns the coordinators, whose terminal binder retains
interaction hooks. Strong references in both directions would create a cycle. A real
RunService composition/close regression retains only the interaction runtime and proves
both coordinator owners release. Other standalone tests prove scope lifetime across held
authorization, revocation, same-ID rebinding, object replacement and refusal rather than a
false submitted result when user-input commands are unavailable. These standalone tests
construct no window, PromptVM or WorkspaceVM.

Initial `70906ae6-4ac2-4fdb-a19c-20ee2cbd6566` failed compilation before tests because the
response payload was still nested in the view model; the actual neutral definition was
moved rather than adding a runtime-to-VM alias. `8ea0b39a-1910-4468-9e33-2d45adf63c59`
passed 86 tests. Supplemental `57f3f95f-0ec8-4806-97be-e7bf97a2eecf` ran 39 tests with
one failing case (seven assertions): the extraction added an unintended missing-controller
refusal to local ACP approval settlement. The previous behavior was restored, preserving
the existing tests; managed ACP still requires its actual provider route. No timeout or
assertion was weakened. Intermediate lint `e9eecacf-8017-4538-acff-c1da13b383fe` passed.

Final `76a8eb1f-0cd5-4f27-bce2-b379014a6136` passed **346 tests**: session-link runtime
bridge 234, Claude approval/resume 38, MCP steer/resume 27, ACP permission scope 10,
worktree review 9, interaction runtime 8, Codex approval choice 6, ACP approval availability
5, overseer ACP policy 4, ACP permission identity 3 and Context Builder ask-user 2.
Final lint `53a70e3d-bd63-4613-9d82-f1c6656ed8d9` passed the same Swift tree. One independent
review, scoped formatting, direct final diff review and staged contribution preflight apply.

M9 remains incomplete: independent writer admission, canonical saved-target host construction,
remaining provider-input/continuation composition, runtime-addressed routing and UI-detached
handoff/drain still require their production cutover. These receipts are not full-product,
fresh-index, aggregate-warning, full-suite or live-smoke qualification. No publication,
visible app lifecycle action or M10 target move occurred.

### M9 continuation — runtime-owned question lifetime (2026-11-08)

Retired the view model's `ask_user` creation, timeout/rearm, draft/index mutation and
caller-cancellation implementations. The existing interaction runtime now installs the
response/cancellation continuation before publishing waiting state and retains the exact
scope through settlement. Caller cancellation captures the original session object rather
than resolving a possibly recycled tab UUID. A transient per-call identity prevents delayed
cancellation from consuming a later question with a reused public interaction ID; it is not
a new run lifecycle or persistence authority. Timeout settlement keeps the existing generation
fence and releases its original caller after presentation detaches. The existing optional
presentation sink handles UI projection; the VM still performs hydration/lifecycle admission.
No persisted schema, link authority, provider lifecycle or permission decision changed.

Four standalone regression tests cover scope retention/release without presentation,
conflicting question refusal, original-caller cancellation versus a replacement object with
the same tab and interaction IDs, timeout rearm and retained draft response after detachment,
the actual zero-delay timeout task, and cancellation-before-admission/retirement refusal.
These tests construct no WindowState, PromptVM or WorkspaceVM. An independent review found
no correctness regression. Its duplicated card-activity guard was consolidated into the
runtime's result, and the cancellation-before-admission test name now states its precise
coverage; it does not claim to control an external cancellation race between synchronous
statements. No test sleeps, retry budgets or timeout limits were inflated.

Initial `bd3e9267-8ef2-4d12-85d1-594975aef798` passed **81 tests**. Final
`b27bbdab-42a1-4c9c-b06a-38ee0fb7b558` passed **353 tests**: link runtime bridge 234,
Claude approval/resume 38, MCP steer/resume 27, notification action resolver 22,
notification eligibility 16, interaction runtime 12, Context Builder ask-user 2 and
interactive lifecycle contracts 2. Final lint `2af2d0a9-1b8e-44b9-8760-3ba7413678e6`
passed the same Swift tree. Scoped formatting, final diff review and staged contribution
preflight apply; the focused results do not replace aggregate warning enforcement.

M9 remains incomplete. Independent canonical writer admission, real window-free saved-run
host construction, provider-input/continuation composition, runtime-addressed routing and
presentation-preserving handoff/drain still need their production cutover. No new final-product,
fresh-index, full-suite or live-smoke qualification is supplied by this checkpoint. No push,
PR edit, merge, visible app lifecycle action or M10 target move occurred.

### M9 continuation — runtime-owned link execution and wake scheduling (2026-11-08)

Moved the actual prompt inventory/hold maps, catalog projections, passive snapshots and claim
store, provider-input proof/handoff/receipt algorithms, auto-wake scheduling and tombstones,
and periodic scheduling into one scope-owned `AgentSessionLinkExecutionRuntime`. The VM's
compatibility accessors reference the same storage (including `_modify`), not a mirror.
The four existing link, passive-delivery, prompt-claim and wake-reservation authorities remain
separate. Run-service hooks and 66 native Codex call sites now invoke the concrete runtime.
Required canonical endpoint, run-start, provider-switch, composer and self-compaction commands
remain explicit legacy composition inputs; optional presentation handles only UI projection.
This relocation alone does not make the host window-free or grant independent writer admission.

Mechanical comparison found 89 of 92 moved method bodies identical apart from whitespace;
the other three adapt optional display/weak coordinator access and the required composer-claim
result. Review identified late legacy command-owner loss: retained runtime hooks must preserve
the old all-or-nothing weak-VM behavior, not partly consume a wake receipt. An explicit owner
availability witness now preserves ordinary-dispatch fallback while refusing wake dispatch and
leaving receipt/provenance state untouched. It is not a consent or endpoint-currency shortcut;
a future nonvisual host must supply its own command lifetime. Installation is once per scope,
not a presentation reattachment operation. No lifecycle, persisted schema or permission owner
was duplicated.

Four standalone tests cover overlapping inventory holds and highest committed revision,
claim acknowledgement/rebinding, repeated Stop tombstones and the physical dispatch fence,
route qualification across an exact-object replacement, and command-owner release without
partial receipt application. They construct no WindowState, PromptVM or WorkspaceVM. The
source-layout snooze guard now reads the new owning file, with all assertions preserved.

Execution receipts:

- `bd2891f5-ea7c-4c36-ba4a-f576790ffc70` failed compilation before tests: missing supplemental
  input parameter and performance recorder wiring; both were wired through the actual composition.
- `48715d24-5b65-4939-aebe-575cf76cda5c` ran 223 tests, one new assertion failed. The test had
  mistaken rendered unpaid content for physical dispatch permission; it now checks the actual
  dispatch fence and unchanged unpaid queue/provenance. No production guard was weakened.
- `915a3ff2-6285-4692-96c5-38b24f5a7e0a` ran 559 tests, one source-path guard failed because it
  still inspected the former owner file. Only that path was corrected.
- Final `8660e67e-91ca-4647-ae7b-15f760b74663` passed **559 tests**: runtime bridge 234,
  auto-wake 127, Codex resume/wedge 74, Codex prompt adapter 41, native/headless adapter 31,
  interactions 12, ACP runner adapter 11, headless runner adapter 10, snooze projection 8,
  auto-wake persistence 7 and new link execution runtime 4.
- Final lint `51a30a98-541f-4135-8060-0534b477ee71` passed; both products built successfully
  with `412a80ff-56dd-43c9-b58a-0a0be7c004fb`. Fresh compiler-index dump/check after that build
  passed at **1234/1360** wrong-way file edges and **53/66** cycle components (1122 files,
  156012 symbols). No ratchet baseline was raised.

One independent review, scoped formatting, final direct diff review and staged contribution
preflight apply. Full-suite, aggregate-warning and live-smoke qualification remain open.
Independent canonical writer admission, real saved execution host construction, remaining
command composition, runtime-addressed routing and presentation-preserving handoff/drain still
need their production cutover. No push, PR edit, merge, visible app lifecycle action or M10
move occurred.

### M9 continuation — runtime-owned send acceptance and turn timing (2026-11-08)

Published the six accumulated commits through `e9e1834fd` after the normal push preflight.
The requested isolated `SessionAdminInventoryReadTests` rerun, ticket
`abbe8c1f-8f93-47d0-9475-b1c66a8ffe24`, passed **76 tests**, including the reported
reduced-capability approval-card failure. Its fixture now persists the exact saved target
before requesting approval; the one-card assertion and authorization guards remain intact.
Hosted CI monitoring is delegated to the overseer; this receipt is local, not a CI-green claim.

Moved provider-switch send preparation, physical acceptance, managed-send authorization and
post-hop checks, durable row acceptance, compensating persistence and already-accepted start
retry into the existing scope-owned link execution runtime. The existing composer claim,
provider-switch record, persistence service and link authorization remain the authorities.
The VM retains only compatibility wrappers and the still-required canonical placement,
provider-input composition and start-command adapters. Shared turn anchor/footer/timer changes
now belong to `AgentSessionTurnTimingRuntime`; elapsed-time publication is optional presentation.
No invisible window or view model is needed by the concrete transaction or timing algorithms.

Accepted provider-switch persistence effects retain their exact scope/session and are joined
before terminal publication and legacy close. Retirement also refuses writer release while
an existing composer claim or send effect remains. Review caught a durable-retry regression
in the newly added scope guards: owner retirement after acceptance must return the existing
persisted receipt, not report the row undelivered. Every refusal releases the original claim;
new admissions are refused while retiring without invalidating originating final writes.

Five additional standalone cases cover real-disk acceptance before dispatch, Stop after the
write without a provider start, a thrown error after disk followed by confirmed compensation,
authorization revocation and same-ID rebinding without writes, already-durable retry after
retirement, and rollback of prior timer/footer anchors. These augment the four existing runtime
cases; no timing budgets or production authority checks were weakened.

Initial focused tickets `8f5014de-3146-44d0-9cec-b0ee96719de6` and
`86b3f27f-235a-4127-9a44-f3ab7e6a60d8` passed **81** and **84** tests respectively.
After review fixes, `244713d3-9639-45d9-b4c9-86446825086a` passed **86 tests**:
provider switch 39, live send transaction 34, link execution runtime 9 and presentation 4.
Integration ticket `ea3e330f-3014-41aa-9004-b38ddb3df8eb` passed **261 tests** (MCP
steer/resume 27 and link runtime bridge 234). Its misspelled worktree filter matched no tests;
the corrected separate `ab395398-8400-4a6a-b7b2-7eee680a0032` passed all **42** worktree
binding-admission tests. Both products passed `344ecb3d-818e-4286-b486-6a7fb57f8667`.
Lint `e6126003-810d-400c-9e9f-6c77cae714cf` found one trailing blank line in the thin VM
adapter; scoped formatting removed it, and final `b61d1571-5732-4711-88a6-ebb8d9ee6cb4`
passed. That formatting-only correction does not change the tested executable statements.
One independent review and staged contribution preflight apply; no compiler-index baseline
or diagnostic budget was raised.

Independent writer admission, canonical saved-run host construction, remaining command
composition, runtime-addressed routing and presentation-preserving handoff/drain remain open.
This transaction cutover is not M9 completion. Final full-suite, aggregate-warning and live-smoke
qualification remain open; no visible app lifecycle action or M10 target move occurred.

### M9 continuation — scope-owned instruction delivery and native link commands (2026-11-08)

Retired the link executor's VM-forwarding instruction-resume callback. The runtime now owns
continuation delivery, timeout cleanup, user-versus-lane token accounting and claim acceptance.
It retains the exact scope through the synchronous delivery/receipt boundary, refuses a replaced
object or retired/unavailable owner, and publishes optional presentation only after acceptance.
A reentrant presentation callback therefore cannot remove the legacy command owner between
physical delivery and its receipt. Refused delivery leaves the waiter to its existing cancellation
owner; no replacement run is started. Existing task-input bookkeeping ordering is unchanged.

Codex replay, bootstrap qualification, exact-object checks, provider-switch physical acquisition
and lane-batch classification now use the installed concrete link runtime rather than the VM.
Managed replay without that runtime fails closed. The readiness test seam forwards to the same
runtime storage. This does not remove the remaining settings/bootstrap/start/catalog adapters
or establish a complete window-free host.

Three additional standalone runtime tests cover single delivery and origin-separated accounting,
receipt ordering under reentrant presentation loss, recycled-tab/unavailable-owner refusal, and
managed-proof refusal without consuming the original claim or instruction waiter. The negative
proof fixture uses a real managed-metadata claim with a matching Manage inventory capability,
then withholds the required current authorization proof. It does not start an unrelated wake task.

Validation history is retained rather than treating retries as an initial pass:
- `8ccd59d5-49e3-49c2-8ae6-72055a1b1344` failed test compilation (origin associated value and
  throwing-continuation fixture types); production compiled. Both fixture errors were corrected.
- `702e21c3-14d0-4e18-b147-40b06db782f7` ran 238 tests with two failing cases/seven assertions.
  The new negative-proof fixture tested the wrong boundary; a transport tombstone alone is not
  proof refusal. The existing periodic-deletion case also observed an already-cancelled attempt.
- `a2701610-34fd-4544-9d3e-32a84c5dcbae` reran the 12 runtime tests plus the exact deletion case:
  deletion passed; the negative fixture could not obtain a managed claim.
- `86dca887-acfb-4935-ad79-3b2cddae6087` ran 166 tests with that same one fixture failure.
  Two misspelled adapter filters matched nothing. Source inspection identified the fixture's
  missing Manage inventory capability; the fail-closed production filter was not weakened.
- Final `21dadc46-1065-4fb8-b1fb-e7b0a1ef824b` passed **238 tests**: runtime 12, auto-wake 127,
  MCP steer/resume 27, Codex prompt adapter 41, native/headless prompt adapter 31. The periodic
  deletion assertion passed in this broader run as well as the isolated run; its earlier ordering
  failure remains unexplained, not classified as a baseline flake. No assertion or timeout changed.
- Both products passed `d642820c-1071-4e00-907b-2e48b2e92f5a`; lint passed
  `22219b3f-8e5d-45ce-b780-ba57353ed29b` on the same Swift tree. Scoped formatting, one independent
  review and mandatory staged contribution preflight apply. No baseline or warning budget increased.

Independent canonical writer admission, saved execution without window/view-model construction,
remaining runtime command composition, runtime-addressed control routing and presentation-preserving
handoff/drain remain required. This is not M9 completion or full-suite/CI/live-smoke qualification.

### M9 continuation — runtime-owned session construction and observation (2026-11-08)

The scope now constructs observed session objects. Actual source mutation, run-state durability,
coalesced transcript scheduling and MCP publisher subscriptions no longer live in VM callbacks.
The existing source, persistence, restoration and terminal authorities are unchanged. Presentation
receives optional exact-object events only. Overseer activation retirement still synchronously
notifies the existing discovery sink; only the pill repaint waits until the enclosing mutation settles.
Source-mutation summary types moved unchanged, with VM aliases and no persisted schema change.

Pending derived work retains its exact scope until settlement. Replaced/released objects cannot
schedule new durability or transcript work. A refused task clears only its own generation's handle,
so subsequent readmission is not wedged and a successor task is not cleared. Coalescing policy is
read live from the composition adapter, preserving test injection and prompt-owner lifetime behavior.
Run-state observation retains restoration suppression and allows the originating final save during
retirement; presentation loss does not suppress that save.

Three persistence tests exercise real disk writes without a VM, pending-scope lifetime, coalescing,
replacement/readmission, restoration suppression and writer release. A domain-store integration
case verifies real published interaction changes from the runtime's subscription, without manually
publishing or constructing a window/view model. Existing Combine will-set timing is preserved.

Validation:
- `b5b6517a-6e36-4faf-923f-e876d76a2320` failed compilation before tests: two activation callbacks
  had not moved to the link runtime. Their actual VM bodies were located and moved to observation;
  discovery authority was not replaced with a no-op or duplicated in the link owner.
- `90ab95a3-c33d-4019-92d3-89ac4f6e5487` ran **126 tests**, one new fixture assertion failed.
  Persistence intentionally retains its completed debounce handle. The fixture now discards that
  joined handle before checking that released objects cannot schedule again; the save-generation
  assertion is unchanged. No production scheduling guard or timeout was weakened.
- Final `5270e250-8596-4def-bda6-6ebe50790188` passed **126 tests**: quiet display 14, first save 47,
  MCP runtime 9, persistence runtime 9, runtime store 9, Claude approval/resume 38.
- Lint `724bb996-65e3-48d9-bc74-a44a51af057d` passed on the same Swift tree. Scoped formatting,
  one independent review and mandatory staged contribution preflight apply. No baseline increased.

This removes VM-owned session-observation execution, not the remaining composition adapters.
Independent canonical writer admission, the prepared-window replacement, provider/start composition,
runtime routing and presentation-preserving handoff/drain remain open. Products, fresh compiler
index, full suite, aggregate warning qualification and live smoke are not newly qualified here.

### M9 continuation — runtime-owned cancellation preparation and Oracle drain (2026-11-08)

Run-service cancellation preparation now retains the concrete interaction/link runtimes instead of
calling a weak VM. The existing cancellation, Oracle invocation, provider adoption and wake owners
remain authoritative. Internal cancellation fences deferred starts but does not perform explicit
Stop withdrawal. Exact-object checks prevent an old session from resolving a recycled tab's endpoint
or cancelling that replacement's provider adoption/wake work, including equal binding values.
Actual Oracle close/join bodies moved to the interaction runtime; pending joins retain the original
scope through cleanup. VM compatibility entry points remain for existing callers and do not eagerly
construct provider coordinators for an otherwise empty close.

Two window-free runtime cases cover internal versus explicit Stop, exactly-once instruction
settlement, replacement refusal, and a real held Oracle preparation. Closing admission is explicitly
not a cleanup acknowledgment; the scope stays alive until the outstanding effect drains.

The recurring periodic-deletion fixture failure is now causally explained. While committed deletion
cleanup was held, a queued Combine readiness notification legitimately reconciled periodic
eligibility and cancelled the prepared wake before the test's physical-dispatch assertion. A forced
notification reproduced `cancelled.preDispatch.eligibility_lost` through the periodic subscription.
This test now disconnects only that subscription after preparing its real wake, isolating the
transport fence it intends to test. All original state/inventory/dispatch assertions remain; no
production deletion policy, timeout or expected phase changed. Temporary probes were removed.

Validation:
- Initial `8d9eda0b-a1b8-46a2-aa71-76e06c8e012f` passed **111 tests** before the final stale-object fence.
- `4ea2888b-d849-4372-9328-9b04cd54a4b4` ran **238 tests**, with the periodic-deletion case failing.
  Exact-case `91ef7e7e-6253-4097-9988-87ef48e418e6` and whole auto-wake suite
  `14d2a37a-b4ce-4195-8453-624cb260e623` passed before controlled reproduction; those retries were
  not treated as proof of a baseline flake. Diagnostic `0003d271-2862-43f7-b306-79ae16135fc0`
  intentionally failed the unchanged assertion after forcing the readiness event, confirming the path.
- Final `6a28e279-ecd8-4e5a-b5ce-298e3886ff12` passed **240 tests**: runtime 14, auto-wake 127,
  MCP steer/resume 27, Codex prompt adapter 41 and native/headless prompt adapter 31.
- Both products passed `481d09d8-fff1-43f0-8094-89166835243f`; lint passed
  `d599176d-e655-426d-aae2-2281d479fffc` on the final Swift tree. Fresh compiler-index check passed
  **1236/1360** wrong-way file edges and **53/66** largest-cycle components (1127 files, 156174 symbols).
- Scoped formatting, one independent review and mandatory staged contribution preflight apply.
  No baseline, warning budget or test assertion was weakened.

Canonical writer admission, window-free saved-host composition, provider construction outside the
execution seam, runtime-addressed routing and presentation-preserving handoff/drain still remain.
This is not M9 completion, full-suite qualification or a fresh hosted/live-smoke receipt.

### M9 continuation — provider construction outside execution (2026-11-08)

`AgentModeRunComposition` now owns the three headless/ACP provider/controller factories. The run
service and runners no longer retain or invoke them. Execution performs its existing admission,
attachment reservation, run-attempt and lease setup, then returns an immutable construction request
with a one-shot handoff qualified by the originating attempt, binding and Stop fence. Composition
constructs the requested resource and returns its result to that same runner. ACP support remains
in execution, between provider and controller construction; stale startup refuses before support
or controller construction. Existing live-runtime reuse and provider-command paths do not construct
replacement resources.

Refusal settles through the existing terminal barrier and lease cleanup, not a second lifecycle
manager. A newer binding or attempt cannot be terminalized by an old preparation. The existing start
receipt records acceptance at actual provider-task installation, not from a successor's running
state after suspension. Repeated fulfillment, including while an async factory is held, cannot
construct twice. Pending-start cancellation remains installed before visibility by the earlier
atomic domain-registration work.

Three added execution tests cover deferred headless construction, held ACP construction with Stop,
no late support/controller side effects, repeated fulfillment, Stop-generation-only refusal, and
replacement-attempt survival without a false old-start receipt. Existing harnesses now exercise
actual product composition instead of placing factories back inside execution.

Validation:
- `f75890f1-dd44-4fff-8f87-b582d26b653d` passed **82 tests** before review corrections.
- `4dc7cef1-7329-427a-ace1-9b77473b6f4d` failed compilation before tests because the new binding
  fences used an incorrect property name. They now use `currentRestorationBindingToken`.
- Final `1ef980ca-5004-482a-ab2d-bdb8da3c91c3` passed **299 tests**: ACP execution 14, quiet
  lifecycle 25, waiting ownership 2, self-compact ACP settlement 24, ACP background settlement 4,
  ACP compact runner 8 and transaction 6, auto-wake 127, native/headless prompt adapter 31,
  Claude approval/resume 38, and Oracle cancellation 20. Corrected class filters include all three
  ACP compact suites; the earlier filename-shaped filter was not counted as coverage.
- Both products passed `c52b22b5-7c1d-4e06-a5ba-ae889c520237`; lint passed
  `4545d0e7-c1f7-4d64-82c4-a04fe4a6dad9`. Explicit strong capture in the outer ACP handoff preserves
  the installed task's weak session capture and removes the newly introduced capture warning.
- Fresh compiler-index check passed **1237/1360** wrong-way file edges and **53/66** largest-cycle
  components (1129 files, 156258 symbols), using the just-built product closure.
- Scoped formatting and one independent review completed; mandatory staged contribution preflight
  applies before commit. No assertion, timeout, warning budget or architectural ratchet was relaxed.

The execution seam still has workspace/carrier inputs and coordinator dependencies to replace.
Canonical independent writer admission, real window-free saved-host composition, runtime-addressed
routing, presentation-preserving execution/handoff/drain and final full qualification remain open.
This is not M9 completion or a fresh hosted/live-smoke receipt.

### M9 continuation — runtime-owned provider-input construction (2026-11-08)

`AgentSessionProviderInputRuntime` now owns the actual slash-skill parser, resolution and prompt
expansion, attachment rendering, tagged-file resolution/packaging, conversation history and headless
message construction. Scope composition retains the existing skill catalog and recorder; it does not
create another catalog or select a window. Workspace paths, the concrete content store and lookup
scope are explicit inputs. The existing readable-file service, worktree projection and token budget
remain authoritative. Neutral in-memory skill token values replace VM-nested implementation types;
compatibility forwarding entry points preserve existing callers without persisted schema changes.

The headless run hook retains the concrete input and link runtimes rather than calling a weak VM and
substituting an empty system prompt. History rebuilding still re-owes the supplement through the
existing claim owner. Input finishing preserves the currency check before attachment rendering and
handoff staging, and the handoff runtime still refuses a replaced object. The VM continues to supply
workspace lookup and startup composition; this is not an independent canonical host yet.

Added runtime tests construct no WindowState, PromptViewModel or WorkspaceManagerViewModel. They
exercise real worktree file content with logical-path display, duplicate packaging avoidance,
explicit-root skill discovery, native compact versus explicit skill namespace, refused publication
into a fresh catalog, non-empty headless system prompts/history, current handoff staging, refusal
before staging, history-bypass after staging and replacement-object refusal. Existing VM/provider
integration tests remain in the focused run.

Validation:
- `91af4b7b-9485-4c2a-b6c1-726d18056513` passed **164 tests** before the final review coverage.
- Final `3c8f52df-857d-449d-b55d-e9f5ee4a61c1` passed **179 tests**: composer submission 39,
  file-tag/worktree 17, provider switch 39, link execution runtime 15, native/headless adapter 31,
  and Claude approval/resume 38. Counts come from named XCTest suites, not empty wrappers.
- Both products passed `ab56ecc5-fc8c-4311-9214-3ca7292717e4`; lint passed
  `e366e05e-2df0-48cb-b1be-a351739a16ea` on the same Swift tree.
- Fresh compiler-index check passed **1240/1360** wrong-way file edges and **53/66** largest-cycle
  components (1130 files, 156323 symbols). No budget or baseline was raised.
- Scoped formatting and one independent review completed. Source verification confirmed the legacy
  scope/catalog/recorder are immutable, link execution holds its scope weakly, and skill-refresh
  forwarding had no omitted side effect. Mandatory staged contribution preflight applies before commit.

Canonical writer admission, window-free saved-host composition, remaining context/startup/terminal
commands, runtime-addressed routing and presentation-preserving execution/handoff/drain remain open.
This is not full-suite, aggregate-warning, hosted-CI or live-smoke qualification, and not M9 completion.

### M9 continuation — explicit execution workspace inputs (2026-11-08)

Removed the mutable-session workspace callback from `AgentModeRunService.Dependencies`. Run
composition supplies an immutable logical fallback root; the existing worktree resolver still checks
current bindings and filesystem/Git identity at the original execution guard point. Queued ACP input
uses the root admitted by its originating attempt, not a later selected window or a weak VM returning
nil after detachment. The native coordinators' separate workspace dependencies and canonical host
composition remain open; this value is not a canonical catalog or writer grant.

The ACP runner records the input immediately after the existing `beginRunAttempt`, before its
control/reuse/fresh-provider branches. Steering requires the existing run ID, attempt and controller
checks plus the exact session object, restoration binding and binding-transition generation. The
separate generation covers runtime-only nil-to-nil binding transitions. Missing/stale input refuses
without terminating a successor, and the existing dequeued-batch path preserves managed receipts and
local draft recovery. The record is retained input, not another lifecycle manager or liveness flag.

Coverage includes live filesystem refusal for a missing bound worktree, same-ID rebinding,
in-progress and nil-to-nil transitions, missing/previous-attempt steering with no provider write,
and the real mixed local/managed flush producing a queued-follow-up receipt while retaining the
local draft and current running owner. The existing manual live-controller fixture explicitly
installs its originating workspace input; assertions and timeouts were not weakened.

Validation:
- `4b56a9c6-e889-44cf-af34-10ed15d568a1` passed **125 tests** before review additions.
- `e2d8efde-0f54-4a97-abda-f68e597e178a` passed **126 tests**; its extra worktree filter used a
  non-matching class prefix. The correct isolated suite passed **42 tests** in
  `4514dde0-ff47-456a-9ed2-c4b6e00e2916`.
- Final `fac17795-8e6c-4326-b8c7-b6a0b9b6c2b4` passed **168 tests** on the final Swift tree:
  ACP execution 15, waiting ownership 2, ACP settle 24, background settle 4, compact runner 8,
  compact transaction 6, managed ACP steering 29, worktree admission 42, Claude approval/resume 38.
- Both products passed `38373203-8f5d-4b37-b983-b1426bee7783`; lint passed
  `875135a6-154c-4a67-a835-702b5c005115` on the same Swift tree. Earlier product/lint receipts
  `7170ef47-016b-4893-868c-ca975913b768` / `a3d7cf41-61a2-4c8d-bf4c-55c0273eb938` predate the
  final exact-object/transition fence and are not the final qualification.
- Fresh compiler index passed **1241/1360** wrong-way file edges and **53/66** largest-cycle
  components (1131 files, 156358 symbols), with no baseline increase.
- Scoped formatting and one independent review completed. Source tracing confirmed production ACP
  attempts enter through the runner; other attempt constructors are native/headless or terminal
  failure/cancellation paths. Mandatory staged contribution preflight applies before commit.

Independent canonical writer admission, window-free saved-host composition, remaining runtime
commands/routing, presentation-preserving execution and full final qualification remain open.
This is not full-suite, aggregate-warning, hosted-CI or live-smoke qualification, and not M9 completion.

### M9 continuation — MCP execution bookkeeping without presentation (2026-11-08)

Moved the actual tool-token maps, run/connection indexes, ended counts, idle continuations and
child-run wait scopes from `MCPServerViewModel` into `MCPToolExecutionRuntime`. The legacy server
forwards to that same storage; it retains contextual run resolution and the legacy single-slot UI.
Codex/Claude steering queries and cancellation, plus run-service idle waiting, retain the concrete
owner instead of weakly consulting a server presentation. Close-safety publication is optional and
weakly bound to the presenter. Registration, connection isolation, captured-timeout expiration and
exact cursor wake behavior retain their existing algorithms.

Review identified a completion-lifetime gap: retaining the tracker while leaving completion behind
weak VM cleanup could strand tracked tools. The existing once-only completion claim, instrumentation
and unregistration now live with the execution owner; only clearing the matching UI slot is optional.
The existing lock-protected cleanup claim was relocated unchanged, not replaced by a second lock or
new unchecked-Sendable escape hatch. Cancellation still unregisters steering bookkeeping immediately:
zero tracked executions is explicitly **not** proof that physical side effects have drained.

Coverage adds standalone token/connection isolation and duplicate completion, idle continuation
completion/cancellation with owner lifetime, overlapping child scopes with captured timeout expiry,
and actual server disposal followed by retained runtime completion. Existing provider steering,
Context Builder abort and physical file-read cancellation tests remain intact. Assertions/timeouts
were not weakened; a new unused weak-variable warning was corrected to an immutable weak binding.

Validation:
- `62033390-ad47-4a69-8629-f9a7f33c5048` passed **151 tests** before the review completion fix.
- Final `1636c4e7-17e8-4464-912d-5e306c063e2f` passed **188 tests**: MCP idle/runtime 6,
  MCP transport 4, Claude approval/resume 38, Codex resume/wedge 74, managed ACP steering 29,
  Context Builder abort 1 and physical content-read cancellation 36.
- Both products passed `688e2c5a-102d-4216-8f5d-dfca46ee6712`; lint passed
  `1c27cc07-0894-4de4-bfb7-889c8b571f57` on the same Swift tree.
- Fresh compiler index passed **1241/1360** wrong-way file edges and **53/66** largest-cycle
  components (1132 files, 156429 symbols), with no baseline increase.
- Scoped formatting and one independent review completed. Source tracing confirmed the server is
  assigned only during VM initialization and the tool canceller is immutable/purely forwarded;
  capturing its actual execution owner therefore does not skip a later replacement mechanism.
  Mandatory staged contribution preflight applies before commit.

Canonical writer admission, saved-target host composition, domain-backed route/catalog/context
admission and remaining startup/terminal commands still require the main M9 cutover. In particular,
legacy child-wake publication/origin callbacks and tool bootstrap still depend on window composition.
This checkpoint is not full-suite, aggregate-warning, hosted-CI or live-smoke qualification and does
not establish presentation-preserving managed execution or M9 completion.

### M9 continuation — input context assembly and recovered control epochs (2026-11-08)

Moved initial-thread eligibility, context wrapping, actual file-tree assembly and asynchronous
skill/context/attachment/handoff orchestration into `AgentSessionProviderInputRuntime`. Composition
still supplies the existing presentation lookup source, captured after skill discovery at the same
boundary as before. This preserves mutable worktree-binding timing; it is explicitly the existing
permissive presentation policy, not canonical saved-host admission. The VM retains UI snapshot and
source selection, not a second copy of the input-building algorithms.

Moved actual MCP epoch preparation into the scope-owned MCP runtime. Missing-record recovery now
installs the existing exact cancellation capability atomically with registration before recovered
control is published. The domain overload rejects foreign runtimes, other lifecycle generations and
invalid registrations; it uses the existing registration authority. Accepted original epochs are
reconciled even when scope membership changes during the actor hop, while successor effects still
require the current scope and Stop fence. New recovery control additionally requires exact current
incarnation and admission; cancellation, retirement or replacement cleans up its partial registration.
Snapshot publication uses the same injected domain store. Neutral in-memory control/transition values
replace VM-nested definitions without changing persisted schema.

Coverage exercises real worktree content and initial-context wrapping, post-skill source capture and
refusal, pending versus installed recovery cancellation, retirement, replacement, foreign/invalid
registrations, accepted epochs across Stop and accepted original epochs after scope removal. New
runtime fixtures do not construct WindowState, PromptViewModel or WorkspaceManagerViewModel. No
assertions or timeouts were weakened and no additional lifecycle owner was introduced.

Validation:
- `0af74f3f-74b1-482b-9dc4-bcb176b3683b` failed compilation before tests: missing provider-kind
  import. The corrected input-context run `4e9c74d8-096c-4b43-bc5d-685da8c5f963` passed **195 tests**.
- Epoch attempts `7d445a2b-ccac-4f10-a042-6d36d9665035` and
  `073c25bd-fb09-47a9-9871-5cb8da6d9b9f` failed compilation before tests: the handler needed
  `@escaping`, then the extracted transition value needed its neutral owner. Both were corrected.
- Final `892e9cf6-c688-4e89-9fde-82414c91becf` passed **281 tests**: composer submission 39,
  worktree file tags 18, MCP steer/resume 27, first-save admission 47, handoff inheritance 100,
  runtime MCP 12 and Claude approval/resume 38. Actual named XCTest counts were checked.
- Both products passed `76923a6c-735a-4167-b36e-e7c00fa45bf2`; lint passed
  `3f494305-0437-40c6-b05a-d11dc0b5fc27` on the final Swift tree.
- Fresh compiler index passed **1239/1360** wrong-way file edges and **53/66** largest-cycle
  components (1133 files, 156477 symbols), without a baseline increase.
- Scoped formatting and one independent review per transition completed; review findings about
  binding-capture timing and already-accepted epoch reconciliation were applied and tested.
  Mandatory staged contribution preflight applies before commit.

Canonical writer admission, window-free saved host and catalog/context composition, remaining
startup/terminal commands and exact runtime routing remain open. This is not full-suite,
aggregate-warning, hosted-CI or live-smoke qualification and does not establish M9 completion.

### M9 continuation — native execution capabilities and warning repair (2026-11-08)

Codex execution now receives the existing draft, MCP bootstrap and settings capabilities directly
from composition instead of resolving them through its weak presentation owner. The optional owner
continues to serve UI model updates, thread display naming and explicit Computer Use presentation
admission; detaching it does not grant Computer Use permission. Existing route queries retain the
same transport authority and exact route arguments. Runtime workspace and MCP catalog composition
remain legacy dependencies, so this does not establish a window-free saved host.

Draft restoration uses the existing exact-object recovery policy and cannot overwrite a replacement
session. Hook approval policy uses the session's bound workspace for both enforcement and UI;
unknown placement fails closed. Native compaction command entrypoints install the existing run
service and terminal barrier before execution, with a debug assertion for missing composition.
No new lifecycle, settings or routing authority was added.

The reported hosted warning in the MCP cancellation hook is fixed by explicitly discarding the
existing cancellation count. No warning or modularization budget was raised. A bounded comparison
of compiler warnings in touched files against the preceding validated compilation found no new
diagnostic and removed the reported unused-result warning; this is not an aggregate warning-budget
qualification.

Validation:
- Initial `9068179d-b547-4e4c-af87-c4a3143eff95` passed **149 tests**, with one existing opt-in
  vendor-signing test skipped, before review hardening.
- Final `de22f27a-edf0-41a8-990b-e43a96b015e0` passed **289 tests**, with that same opt-in test
  skipped: composer submission 39, MCP steer/resume 27, native self-compaction completion 25,
  terminal scheduling 8, Codex prompt adapter 41, compact transactions 30, runtime MCP 12,
  Computer Use workflow 24, hook review cards 4, execution adapters 4 and resume/wedge commits 75.
- Both products passed `55fadc2c-90e5-46f6-be02-22219149f787`; lint passed
  `452105ba-9bee-4495-95f8-d831b9713ff0` on the final Swift tree.
- Fresh compiler index passed **1239/1360** wrong-way file edges and **53/66** largest-cycle
  components (1133 files, 156490 symbols), without a baseline increase.
- Scoped formatting and one independent review completed. Strict-policy fail-closed behavior,
  matching presentation policy and explicit compaction ownership were applied and tested.
  Mandatory staged contribution preflight applies before commit.

Standalone coverage exercises bound settings and original-object draft recovery without a
presentation. Existing cold-compaction coverage detaches presentation before bootstrap and retains
its physical dispatch assertions. Canonical writer admission, saved-host construction, remaining
startup/terminal commands, runtime routing and close/handoff/drain integration remain open. Full
suite, final hosted CI and live smoke are not established by this checkpoint.

### M9 continuation — runtime-owned startup orchestration (2026-11-08)

`AgentSessionRunStartRuntime` now owns the actual startup sequence, exact-object lifetime,
Claude event reservation, Stop and restoration fences, existing configured-creation ordering,
lane prompt admission and final resource-composition dispatch. The VM supplies per-request
workspace, hydration, binding and provider-switch inputs; it no longer implements the sequence.
These inputs still depend on legacy presentation composition. This is not a canonical writer or
window-free saved-host cutover.

The same owner implements Claude steering enqueue for both startup and ordinary steering.
Its accepted producer retains the exact runtime scope and existing run service until settlement,
rather than disappearing with a weak presentation task. A refused generic steering request uses
existing candidate/managed-turn compensation; persistence addresses the original object, not a
recycled tab UUID. No new queue, creation authority, run registration or terminal lifecycle was
introduced. Entry refusal settles the original composer candidate, and the binding admission
result retains the original non-nil admission semantics rather than adding an unowned post-CAS
failure branch.

Two standalone tests exercise real scoped session state without constructing WindowState,
PromptViewModel or WorkspaceManagerViewModel. Held preparation proves scope retention and
refusal after Stop, replacement, same-ID rebinding, retirement or workspace change. Held input
augmentation proves that a rebound attempt cannot dispatch or acknowledge a successor. Existing
integration tests continue to exercise actual provider dispatch and first-save authority.

Validation:
- Initial `9bd87393-24ed-44d5-a9bc-cf4dad987303` failed test compilation before execution because
  the new fixture read `didStart` from the recorder rather than its outcome; the API use was fixed.
- `504f787b-6b5f-4586-a267-2a553ebb30e2` passed **373 tests**. Its misspelled composer filter
  matched none; supplemental `cdfed2c5-556b-457d-ba33-f8af09d48ee3` passed all **39** actual
  `AgentComposerSubmissionAttemptTests` cases.
- Final `1bb0101b-ca69-4495-b94a-f191052ad480` passed **412 tests** with the corrected composer
  filter and final admission parity: ACP execution 15, composer submission 39, provider switch 39,
  MCP steer/resume 27, native self-compaction 25, terminal scheduling 8, first-save 47, auto-wake
  127, compact transactions 30, scoped link execution 17 and Claude approval/resume 38.
- Final both-product build `b15d5edb-3b83-41c7-ae67-ef135b9ab1ad` and lint
  `f61da792-f571-46c8-8cc4-2213f6db8ef2` passed. Earlier product/lint receipts
  `319cf290-3242-4b9b-8622-fe921eeb1bb7` and `f3d55921-9741-463d-b96c-cf2e5a13e22e` predate
  the final admission adjustment.
- Fresh final compiler index passed **1241/1360** wrong-way file edges and **53/66** largest-cycle
  components (1134 files, 156564 symbols), with no baseline increase. Final focused compilation
  reported no compiler warnings in the four touched Swift files; aggregate warning qualification
  is still separate.
- Scoped formatting and one independent review completed. Review fixes cover entry candidate
  cleanup, refused steering receipts and original binding-commit ordering. Mandatory staged
  contribution preflight applies before commit.

Canonical workspace/admission inputs, saved-host construction, remaining terminal/follow-up
ownership, exact runtime routing and presentation-detach/drain integration remain open. Full-suite,
final hosted CI and live smoke are not established by this checkpoint.

### M9 continuation — runtime-owned follow-up producers and joined recovery (2026-11-08)

`AgentSessionRunContinuationRuntime` owns the actual ACP scheduled-start queue, ordinary
follow-up producer, typed draft recovery and Claude adoption-race reinsertion previously implemented
in the VM. Its Tasks retain the exact scope until settlement and remove themselves from the pending
set on every completion. Cancelling a drain waiter is not proof that its producers finished. Writer
claim release now refuses while these starts remain pending.

The first ACP producer owns the batch's startup composition; queued instructions preserve their
individual Stop fences and draft provenance. Production composition captures a per-request launch
that calls the concrete startup runtime, rather than a VM implementation of startup. The existing
workspace and creation inputs still depend on the legacy host and are not claimed as canonical
window-free composition. No new run, queue, acknowledgement or lifecycle authority was introduced.

Review identified a real legacy-close admission gap for idle scheduled producers. The close path
now marks its private scope retiring before the first await, stops coordinators in the original
order, then joins producers. Final originating persistence remains permitted. This is retirement
of the legacy private runtime, not the eventual presentation-only detach path. Non-ACP refusal
preserves an existing ACP pending flag, and the original Stop fence is captured before every Task
hop. Missing launch composition restores typed ACP drafts without turning managed provider text
into local user text.

Standalone tests exercise scope lifetime and a cancelled drain waiter, refusal after replacement or
same-ID rebinding, active and already-completed successor transfer, missing composition recovery,
Claude adoption reinsertion and Stop before the task starts. A real VM/ACP integration holds the
producer, starts close, releases it and proves close completes without a provider prompt. Original
Stop, managed receipt and draft assertions remain intact; no timeout or retry inflation was used.

Validation:
- Initial `6e031103-3797-4583-b583-4d2b3c3900cc` passed **114 tests** before review fixes.
  Its `AgentStopTransactionTests` filter matched none; that typo also remained in the next run
  and was corrected with the explicit supplemental suites below.
- Final `19731b9d-0525-4008-a4c0-89ed12f62f08` passed **193 tests**: MCP steer/resume 27,
  first-save 47, ACP steering 30, scoped link execution 21, Claude approval/resume 38 and worktree
  recovery 30. The new gated window-close case and all four standalone continuation cases passed.
- Supplemental `0f4dec08-1ec3-42c2-89f9-2f6fd802c2cc` passed **50 tests**: Stop transactions 34,
  route cleanup 1, Stop transcript 4, runtime store 9 and waiting ownership 2. Together the final
  unchanged Swift tree passed **243 named tests**.
- Both products passed `3acc44df-7f42-4863-8344-215154e9e706`; lint passed
  `156dddfb-84c4-4c48-96e4-57f61fe9be02`. Fresh compiler index passed **1242/1360** wrong-way
  file edges and **53/66** largest-cycle components (1135 files, 156615 symbols), without a
  baseline increase. The final compilation reported no compiler warning in the five touched Swift
  files; aggregate hosted warning qualification is separate.
- Scoped formatting and one independent review completed. Mandatory staged contribution preflight
  applies before commit.

Canonical writer admission, saved-host construction, remaining terminal self-compaction/worktree
commands, exact runtime routing and presentation-only close/handoff integration remain open. This
checkpoint does not establish final full-suite, hosted CI or live-smoke qualification.

### M9.1 scope freeze and merge-safety audit (2026-11-08, PR #1655, refs #1406)

PR #1655 is **M9.1: behaviour-preserving runtime ownership extraction**, not completion of M9.
The existing session objects, observation, streaming, derived transcript work, usage/timing,
attachment retention, draft/handoff handling, save queue/payload transaction, MCP state publication,
interaction effects, link execution, startup and follow-up producers now have named runtime owners.
The VM forwards to those owners and supplies legacy app composition and optional presentation.
No persisted schema or provider protocol changes. User-visible behaviour is unchanged, including
**today's ordinary window-close-cancels-run behaviour**; this PR does not turn close into a
presentation-only detach. Existing prepared managed-session behaviour remains intact.

Merged main `bb68ff0d29ef8582a4636fa615ec6acd374a011a` with merge commit `360705f61`.
The stopped worker's terminal-transcript materialisation stash remains untouched and excluded.

#### Audit and bounded repair

- The scope's session map and reverse binding index are the live-object storage; VM accessors
  forward to that map. Runtime observation owns source/run callbacks; the exact-object presentation
  sink forwards attached UI refresh, transcript, activity, draft and terminal notifications. The
  ordinary close path detaches that sink **after** its cancellation/drain, not before terminal UI.
- Saves use the existing creation/restoration/binding admission and exact save token, one scope save
  queue and durable payload writer. Retention completes before final prepared-host save/release.
  `finishRetiringPreparedOversightOwner` deliberately retains an unsettled writer, reports a warning
  and retries on explicit visit/shutdown. Releasing its infrastructure after failed durability would
  discard that retry capability; the review's suggested unconditional teardown was not applied.
- Prepared-owner release occurs after `invalidateWindow`, observer/census subscription removal,
  close/presentation detach and final save. It is not a second live UI writer. Ordinary close retains
  its existing lifetime/disposal policy; no new presentation-only claim-release policy was added.
- Runtime startup checks retirement and Stop before dispatch. `AgentModeRunService.prepareRun`
  reaches the ACP runner's synchronous attempt/`.running` prologue before its first provider await;
  close therefore sees and cancels that run. Moving the producer join ahead of cancellation could
  instead strand close behind provider work. Existing guarded close/start coverage remains required.
- Production live session construction uses `Scope.makeSession`; the remaining direct constructors
  are a slash-suggestion scratch object and a tracker teardown placeholder, not admitted writers.
  `AgentSavedSessionTargetLoader` is called by `WindowStatesManager+AgentSessionLinks`, not dead code.
  The early-refusal placement of the follow-up flag cleanup is unchanged from main, not a newly
  introduced second queue/owner.
- The whole reported watchdog class initially passed (43 cases), so a single green run did not
  establish absence of the reported successor-attempt failure. Source tracing found a same-run
  observer lifetime race: a cancelled predecessor connection lookup could unregister a replacement
  observer by run ID. A deterministic gated network witness failed before repair with **0 callbacks
  instead of 1** (`d2e74659-0276-4302-a07b-268672cac1d1`). Cleanup now carries the existing registration
  token through lookup and Task hops and refuses a predecessor token. Both callback and continuation
  APIs use that token; no new observer authority or queue was introduced. This mechanism also exists
  in main's unchanged tracker code; its historical CI scheduling trigger is not proven. The original
  exact-association/duplicate-dispatch assertions remain unchanged, with no timeout or retry increase.
- Explicitly discarded the runtime footer helper's result, removing a new extraction warning.
  Existing unrelated warnings are not silently presented as a warning-free repository.

One independent selected-boundary review covered scope/observation/persistence/presentation,
startup/continuation and prepared-host teardown. Its lifecycle hypotheses were checked against the
actual callers and synchronous runner admission, rather than applied speculatively. This is a source
and local-test audit, not a live UI/hosted-CI receipt; the overseer owns those checks.

#### Compatibility adapter retirement inventory

These are deliberate temporary composition/forwarding adapters, not claims that M9 is complete.
Entries group the forwarding methods for the named owner; no duplicate copy of its runtime maps
is intended to remain.

| Remaining adapter / boundary | Retirement segment |
| --- | --- |
| `AgentSessionRuntimeStore.Writer` resolution used by carrier census; legacy exact-object admission and VM binding/creation inputs | M9.2a establishes the writer admission contract; M9.2b routes callers through it |
| VM `sessions` proxy, UI side effects around replacement, `AgentTabSession` forwarding aliases, scope lifetime tied to the legacy host | M9.2b writer routing; M9.4 presentation/lifetime handoff |
| VM interaction command forwarding and `interactionRuntime` provider/approval composition | M9.2b |
| VM `AgentSessionLink*` forwarding methods / `_modify` storage access and `linkExecutionRuntime.Commands` endpoint/start/composer/self-compact inputs | M9.2b; workspace inputs completed in M9.3 |
| VM `makeRunStartEnvironment`, `makeFollowUpLaunch`, `AgentModeRunComposition` workspace/resource factories and weak host preparation callbacks | M9.2b routing; M9.3 window-free host composition |
| VM stream forwarding / lazy `_ = runService`, weak runtime service/coordinator back-pointers and Claude tool-hook installation | M9.2b explicit host-owned routing/composition |
| VM `configureCodexRuntime`, provider/UI model and Computer Use presentation attachment | M9.3 host composition; M9.4 presentation detach |
| VM `mcpRuntime` route/metadata adapter, `MCPRunRouteBindings`, `MCPToolExecutionRuntime` app/server composition | M9.2b canonical routing; M9.3 route/catalog host composition |
| `installPersistenceComposition`: workspace catalog, names, suppression, creation/save admission | M9.3 |
| VM save/token/flush forwarding methods and `AgentSessionPersistenceRuntime.Presentation` commit/UI callbacks | M9.2b writer routing; M9.4 optional presentation |
| `attachmentRuntime.configuration` location/current-root adapter and preview invalidation | M9.3 canonical storage inputs; M9.4 presentation invalidation |
| VM provider-input/workspace-source and resume-handoff composition, draft/usage/timing/transcript forwarding | M9.2b commands; M9.3 workspace/context composition |
| VM terminal preparation/self-compaction/provider-switch/worktree-relocation settlement callbacks | M9.2b command ownership; M9.4 final presentation drain (stashed terminal work is not in M9.1) |
| `synchronizeRunPresentationAttachments`, `detachRunPresentation`, UI refresh/notification projections and legacy `prepareForWindowClose` retirement | M9.4 |
| `WindowState` prepared owner, `AgentSessionCarrierResolver` weak prepared-owner registry and window census | M9.3 |
| `AgentSavedSessionTargetLoader` window-catalog caller adapter (loader itself remains the point-read implementation) | M9.3 |

Remaining plan: **M9.2a** writer admission contract; **M9.2b** routing through that writer;
**M9.3** window-free saved-target host; **M9.4** presentation detach/drain and #1406 closeout.
The later app-free target move remains M10. PR #1655 references, and does not close, #1406.

Focused wrap-up validation:
- Initial whole watchdog class: `17b16884-2d95-45ff-8d09-063750f5b381`, **43 tests**, passed.
- Deterministic pre-fix cancellation witness: `d2e74659-0276-4302-a07b-268672cac1d1`, **1 test**,
  failed at its expected successor callback count (0 rather than 1).
- Post-fix `65445f3d-9617-49f7-bb31-e58bbff2c878`: **166 tests**, zero failures: watchdog 44,
  handoff inheritance 100, persistence runtime 9, presentation runtime 4 and runtime store 9.
  The extra `AgentSessionProviderEffectsRuntimeTests` filter was a filename, not a suite, and
  selected no cases; it is not included in that count. Its actual suites are covered by the full gate.
- Scoped SwiftFormat 0.61.1: 0/3 files needed changes. Final Swift lint
  `e9d03c82-fe20-4fef-a0ca-1c52163cd718` passed (0/2142 files require formatting).

The first full local run (`f50d333a-7447-4c94-8c23-acb830ed969f`) found three
`AgentSessionRestorationAdmissionTests` failures, then was cancelled for repair; it is not a pass.
The fresh-runtime fixture retained its old VM (also captured by XCTest teardown), leaving that
runtime's retiring writer claim alive while creating the allegedly fresh runtime. The three
created-session cases therefore refused binding before reading disk. The fixture now explicitly
joins attachment/persistence work and discards the old in-memory sessions before reopening,
asserting that no writer remains. This models process disposal, not ordinary close or a second
live host. It neither writes the payload nor grants readiness, and all original payload, failed
write, restoration and provider-dispatch assertions remain intact. No production close/release
policy was changed to accommodate this restart fixture. The pre-fixture-repair product gate
`47acabf5-b5e2-4fe5-87dc-da472663eb80` passed for both products; its fresh index check passed at
**1242/1360** wrong-way file edges and **53/66** largest-cycle components.

Fresh-runtime fixture repair validation: `025bb09a-367e-417e-ba6d-cd5d33a50ec7`, **28 tests**,
zero failures (restoration admission 19, runtime store 9). No new compiler diagnostic in the
changed fixture. Scoped SwiftFormat and lint `e58f94fa-e23f-4c2b-beb6-fff6dfa2113e` passed.
A new full-suite run and both product/index gates follow this final Swift tree.

#### M9.1 published-head gate reconciliation

Published code/test head: `d92a8371f9a2d799be76a38b80ef4e145125c85a`, normal fast-forward push
on 2026-11-08 after the mandatory push safety preflight. The local brief and terminal-materialisation
stash remain excluded and preserved. PR #1655 stays draft; no live-app lifecycle action was run.

- Full local ticket `150c3fb1-4f2a-4944-8cb6-e822b2e36f75` **did not pass**: it reached its
  unchanged 3600-second job limit after 6279 completed cases, including 14 failed cases. Thirteen
  were Oracle admission failures following a shutdown suite; one was a Codex interpreter-version
  probe failure. This is not a full-suite qualification receipt.
- Separate focused `80fc7d45-b399-435f-88fe-3830b4bd0436` passed **38 tests** (Codex runtime
  authority 18, Oracle cancellation adapter 20). That focused pass does not erase the full-run
  failure or establish the transient Codex probe's historical cause.
- The shutdown/Oracle ordering witness `7910823a-752d-4407-90ac-bc4b4ae4d677` ran **31 cases**:
  shutdown 11 passed, Oracle 13/20 failed (27 assertion/error events). An isolated temporary clone
  of **main `bb68ff0d29ef8582a4636fa615ec6acd374a011a`** ran the identical filter under ticket
  `b45628d3-6b7e-42a8-99b4-49e5da9a1e17`: the same 31 cases and identical 13 failed-case names.
  The shutdown fixture permanently closes the shared Oracle registry used by the later class.
  This is a **pre-existing local cross-suite ordering issue**, not an M9.1 regression. The proposed
  isolation experiment was removed from the branch and preserved only as a local patch. No
  production shutdown-policy change, assertion relaxation or timeout increase is included.
- Per overseer direction, the **hosted per-suite-process shards are the authoritative full-suite
  gate**. Their result and the debug/live smoke are owned by the overseer; this worker did not read
  CI logs and does not claim either gate passed.
- Final `make dev-swift-build PRODUCT=all`: `7bb4c881-442c-408b-8315-56ca055b8b9b`, **passed**.
  The preceding attempt `b690da03-4069-4497-9a35-f1e3f2971d77` failed because the incremental
  compiler referenced a missing generated `Sparkle.framework`; the intact vendored framework was
  recopied to that generated location before the successful coordinated rebuild. No tracked file
  or binary dependency changed.
- Fresh compiler-index check after that build: **1242/1360** wrong-way file edges and **53/66**
  largest-cycle components, passed; no ratchet baseline change.
- Warning audit: all **11 diagnostic locations / 9 warning kinds** emitted by the final product
  build in branch-changed files have unchanged source lines and matching compiler diagnostics in
  the main comparison build. The new observation unused-result warning was repaired earlier;
  the new watchdog/fixture code emitted no new diagnostics in focused compilation. This is not a
  claim that the repository has no existing warnings; the clean hosted aggregate ratchet remains
  separate. Final Swift-tree lint: `e58f94fa-e23f-4c2b-beb6-fff6dfa2113e`, passed.

### M9.2 in progress: writer admission, placement, and Send/Stop routing

This is a partial routing milestone, not completion of M9.2 or #1406.

- `AgentSessionRuntimeStore.Writer` now carries an exact scope/incarnation/workspace/restoration
  identity; command admission is distinct from originating-writer currency. Retirement refuses new
  commands without invalidating already-claimed teardown or durable acknowledgement. Binding
  admission refuses a second live writer before it can install a partial claim.
- Delegation placement prepares a missing writer before the final synchronous scope-lease and
  membership fence. The writer owns payload mutation and the existing serialized required save;
  agreeing UI replicas receive projections, never writer claims. The cold file-rewrite fallback is
  removed. Real-persistence tests cover the first mutation across cold replicas and late authority
  loss during preparation.
- The runtime scope now retains its single `AgentModeRunService`, shared by start and cancellation.
  The stream runtime no longer depends on a weak view-model-owned execution back-pointer.
  `WindowStatesManager` routes Send/Stop and their start-stop fence through the process writer;
  route IDs remain exact endpoint fences, not window-election inputs.
- The actual managed Stop transaction and cancellation helpers moved from the view model into
  `AgentSessionLinkExecutionRuntime`. Claimed cleanup and audit effects retain their writer and
  are tracked through drain. Stop effects are deliberately not joined by terminal publication,
  which Stop itself awaits. Unsettled provisional target claims live in the existing MCP runtime.
- Send rechecks its writer around authorization and persistence. Loss of the writer during a save
  cannot acknowledge that write or compensate against the successor: the row remains, persistence
  is reported indeterminate, and provider dispatch is withheld.
- Retired here: the link `Commands.endpoint` callback, the VM managed Stop implementation and
  cancellation helper bodies, and the VM's stored execution service. Remaining Steer/Compact/model,
  MCP/admin/worktree, provider-input, self-compaction, terminal preparation and forwarding adapters
  in the inventory above are still M9.2 work. Window-free resource composition remains M9.3;
  close-preserves-run and presentation lifetime remain M9.4.

Milestone validation: `1af66724-155a-4599-b74b-61510597f814` passed **580 focused tests**;
`d1b9e6c1-9216-4f04-a909-703e918cdbf7` built both products. Fresh index check passed
**1241/1360** wrong-way file edges and **53/66** largest-cycle components. Scoped pinned
SwiftFormat lint and strict SwiftLint passed all 21 changed Swift files (the final wake fixture was
rechecked separately). Normalized diagnostics in touched files matched the nine pre-existing
warning signatures from the admission/placement builds; no new warning signature was introduced.
The scope-lifetime witness joins its exact pending persistence task before asserting deallocation;
it does not use a sleep or retry. Competing-writer wake coverage distinguishes cached authority
projections from command admission: newer inventory can be cached, but no conflicted session
mutation or provider wake is admitted. Hosted CI and live-app validation remain overseer-owned.
