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

**2026-10-03 PR 4 maintainer policy decision.** The user explicitly makes the App-line reference advisory, superseding the earlier hard-ceiling and proposed +177 allowance decisions. No numeric baseline is raised: `app_target_swift_lines` remains 649,794, headroom 2,000, advisory reference 651,794. Pinned main `a877f1ea` has 651,988 App lines (+194); the pending PR 4 merge has 651,971 (+177), a PR 4 contribution of −17. Excess remains visible even when another mandatory ratchet fails. All four non-increasing metrics, dependency/security/test gates and baseline/configuration failures remain mandatory; `update` still refuses unapproved baseline increases. The earlier actual guardrail exit1 is retained as historical failure, not retrospectively passed. Policy regression checks and final commit/push preflights must execute before publication; optional current-main full-suite/package/live checks remain pending, including incomplete ticket `51d89061-0945-4554-b73b-12d601485397` (zero executed tests).

**2026-10-03 PR 4/#1148 test-import alignment.** The maintainer explicitly authorizes only `tests_testable_import_app_files` 332 → 333 for the already-merged #1148 coverage at `274fd59d12585e26d53a8457dbd5c5b5014b7441`. Its new `MCPStateSubscriptionTests.swift` necessarily imports App: all six unchanged tests exercise real `MCPService` subscriber fan-out, seed/unsubscribe/approval state and `MCPServerViewModel` lifetime/window presentation with App dependencies and DEBUG hooks. Preserve the complete upstream file and assertions; no consolidation, deletion, Shared substitute, public/SPI exposure or suppression. CI run `37109785395`, job `111165298080`, checked synthetic merge `10d61881d4feb4b8300b4001c2cfd4878d343f4d` and failed the genuine 333 > 332 ratchet before compilation; that failure remains historical, not passed. This is a one-file structural-baseline alignment, not a relaxed check: counts above 333 still fail. App baseline 649,794/headroom 2,000/advisory reference 651,794, every other baseline/list and all dependency/security/test/configuration gates remain unchanged. Exact merged-head guardrails, eight focused methods, style and later commit/push preflights remain pending validator execution.

**2026-10-01 PR 2/main reconciliation.** Merging current `origin/main` (#1134–#1136) into PR 2 put the app target at 649,172 Swift lines, 242 above the earlier 648,930 ceiling. Regenerated `ratchets.json` with `update --allow-regression` against the merged tree: the recorded app-line baseline is now 649,172 with the same fixed 2,000-line headroom. The non-increasing gate counts remain unchanged; tracked-only counts reflect the merged source. This is a baseline reconciliation for existing feature work and PR 2, not a change to the guardrail policy.

**2026-10-01 PR 2/#1137 reconciliation.** Merging `origin/main` at `773a0f2e` added three tests with an exact `@testable import RepoPromptApp` line. The new Devin catalog, Context Builder prompt, and MCP policy tests exercise app-owned types; the fourth new Devin test uses an SPI-prefixed import and is not counted by this lexical metric. Regenerated `ratchets.json` with `update --allow-regression` against the merged tree: the test-import baseline is 332 rather than 329. The app-line baseline and tracked metrics were also refreshed for the new Devin catalog. This reconciles upstream app-level test coverage without weakening the non-increasing rule for later changes.

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
