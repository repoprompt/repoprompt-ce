# Build Modularization: Completion Plan (minimum-complete scope)

Status: **Proposed**, revision 2 (2026-09-29), against `origin/main` `944854b7`. It replaces the first draft (`c90109d7`), which aimed for an app target at ≤ 10% of the code in 150–220 PRs over 4–7 months. That draft is kept in full as the appendix, [Later / further efficiencies](#appendix-later--further-efficiencies).

Inputs:
- [`../build-modularization-2026-09-28.md`](../build-modularization-2026-09-28.md), the program plan (architecture, seams S1–S17, slice protocol);
- [`ledger.md`](ledger.md), with the Phase 0 evidence and ADR-01…09;
- the frozen headless handoff note (`git show 7eaf24b2:docs/spec/headless-option-b-handoff.md`), read as input only.

This document does not change the architecture. It picks the smallest set of slices that meets the two goals below, sizes and orders them, and defers everything else.

Legend:
- **[M]**: measured for this plan.
- **[L]**: from the ledger.
- **[E]**: estimate.
- **G1** / **G2**: the goal a slice or criterion serves (§1.1).
- Labels on each PR:
  - **L**: logic change (behavior-preserving);
  - **A**: access-level only, meaning a separate access and `import` PR;
  - **M**: pure move, meaning `git mv` plus the access and `import` edits the move needs, byte-identical otherwise, as checked by the audit in §4.4.
- Time is in **agent-days**: one writer doing the pre-work, the move, validation, and review fixes.

---

## Execution model: ten milestone PRs (hard ceiling; supersedes slice-per-PR)

User decision, 2026-09-29. The whole remaining modularization is **at most 10 PRs**, with no exceptions and no splitting.

- **Slices are work items.** The slice IDs in §2 (T*, A*–F*, X) are now checklists *inside* milestone PRs, not PRs. Where §2's per-slice PR counts, §2.9's totals, or the per-slice rules in §4.1 conflict with this section, this section wins.
- **Scope freeze.** Anything found mid-milestone that the milestone's goal does not need goes to the **follow-up list** at the end of this section, not into a new PR.
- **One PR per milestone.** Docs, fixes, and review responses go into the milestone PR they belong to.
- **Prep and move are separate** only for WorkspaceContext (PR 4/5), the MCP server (PR 6/7), and the agent runtime (PR 9/10). Everywhere else, logic and moves share one PR, and the move audit (T0) proves the pure-move parts.
- **Each PR body states** which it delivers: a measured build/test-time gain, or a named headless seam (X8).
- **Review.** Exactly **one** Astra review per milestone PR:
  - It starts at push, alongside CI, and is pinned to the head SHA.
  - Model: `codexExec:gpt-6-astra-high` for PRs 2, 3, and 8; `codexExec:gpt-6-astra-xhigh` for PRs 4–7, 9, and 10.
  - It reports **only** correctness, behavior change, concurrency and ordering, boundary/seam, or build-system problems. No style or nits; at most the top 10 findings by severity.
  - There is one round of fixes, each finding dispositioned CONFIRMED, REFUTED, or UNRESOLVED.
  - A second review happens only if a fix changed behavior.
- **Size.** A milestone PR may be large. The move audit proves the moves, and reviewers focus on logic.

### The ten PRs

"Hard deps" must be **merged** before the PR starts.

| PR | Milestone (slices) | Delivers | Hard deps | Lane |
| --- | --- | --- | --- | --- |
| 1 | #1117 T0: move audit, access-lift, test-import helper, `new-module` template | Tooling that proves every later move | — | gate |
| 2 | Tooling + foundations: T1–T5 (catalog, import check, edge matrix, placement guardrail, ratchets, `dev-test MODULE=`, edit-locality metric, index freshness, ADR-08 admission v2, CI build-once, Sentry build conditional or main-only); A1–A5 (Foundation + notification names, instrumentation contracts, Regex, Process, SecureStorage); this plan rewrite | Build/test time (CI build-once, module tests, admission); headless Process seam | 1 | gate |
| 3 | Platform: B1 FileSystem + `IgnoreMatcher`, B2 VCS queries, B3 CodeMap persistence, B4 settings core + global-ignore facet | Headless seams X8 (e), (f), (g); module tests for FS/VCS | 2 | M |
| 4 | WorkspaceContext prep: C1 seams S8/S9/S17, C2 read-only snapshot and store carve-outs (in-app only) | Headless seam X8 (d) | 2 | P |
| 5 | WorkspaceContext move: C3 | Build/test time (WorkspaceContext tests leave the app) | 3, 4 | M |
| 6 | MCP server prep: D1 S5, D2 S6 `ToolInvocationContext`, D3 admission/settlement seam (in-app only) | Headless seams X8 (a), (b), (c) | 2 | P |
| 7 | MCP server move: D4 | Build/test time (MCP tests leave the app) | 5, 6 | M |
| 8 | AI: E1 contracts + E2 providers (incl. Diffing) | Build/test time (AI tests leave the app) | 2 | AI |
| 9 | Agent runtime prep: F1 S3 hoists, F2 S4 Codex state, F3 session store (in-app only) | Cycle break; headless session-host contract | 2, 8 | AI |
| 10 | Agent runtime move F4 + exit measurement X | Build/test time; X1–X9 measured | 7, 9 (and 3, 8 transitively) | M |

**One change from the proposed lanes: PR 9 runs in lane AI after PR 8, not in lane P.**
- **Critical path.** In lane P, PR 4 → PR 6 → PR 9 → PR 10 would be the critical path (≈ 43 agent-days after PR 2 at midpoints). Moving PR 9 behind PR 8 shortens that to ≈ 35.
- **Conflict.** PR 8 rewrites the provider references that PR 9's runtime carve-outs also touch (10 runtime files [M]). Running PR 9 second removes that conflict instead of managing it.

### Revised order after PR 2 (2026-10-01): seams for headless first

User decision: "seam, then port." The in-app seam PRs that headless depends on move ahead of the platform moves. The ten-PR ceiling is unchanged; only the numbering after PR 2 changes.

| New # | Milestone | Old # | Hard deps (merged) | Lane | Headless seam delivered |
| --- | --- | --- | --- | --- | --- |
| 3 | WorkspaceContext prep: invert WorkspaceContext → Features/VM edges (S8/S9/S17), read-only root-scoped snapshot (C1/C2) | 4 | 2 | P | X8 (d) |
| 4 | MCP server prep: S5 invocation-context values, S6 `ToolInvocationContext`, admission/settlement seam (D1–D3) | 6 | 2 (soft: 3) | P | X8 (a)(b)(c) |
| 5 | Platform: FileSystem + `IgnoreMatcher`, VCS queries, CodeMap persistence, settings core + ignore facet (B1–B4) | 3 | 2 | M | X8 (e)(f)(g) |
| 6 | WorkspaceContext move (C3) | 5 | 3, 5 | M | — (build/test time) |
| 7 | MCP server move (D4) | 7 | 4, 6 | M | — (build/test time) |
| 8 | AI: contracts + providers (E1/E2) | 8 | 2 | AI | — |
| 9 | Agent runtime prep (F1–F3) | 9 | 8 | AI | session-host contract |
| 10 | Agent runtime move + exit (F4, X) | 10 | 7, 9 | M | — |

- **DomainRuntime.** It is already its own target. Its seam is a guardrail, not a PR: no app dependency, and nothing moves out of it. That is enforced by the T1 edge matrix shipped in PR 2.
- **Why the WorkspaceContext move still waits for Platform.** Index readiness on `7d9cecd2` shows the WorkspaceContext set (101 files) has 126 outbound file references into FileSystem and VCS. Its Features/MCP-ViewModel edges, which PR 3 removes, number about 40.
- **Claims lists.** Each PR publishes its file claims before it moves or substantially edits any file. The PR-triage overseer sequences open contributor PRs against them.

### PR 4 bounded implementation contract (2026-10-02)

The approved in-app prep uses one new `Infrastructure/MCP/MCPInvocationContext.swift`
for S5 value declarations and the Sendable S6 carrier. Existing args-only canonical
bindings remain unchanged: the app ingress scopes the captured packet around the
DomainRuntime host, and window adapters capture it before their first suspension.
The existing VM retains live file-authority capture/validation and the atomic
lifetime mutation fence. Explicit `trustedLocal` compatibility is separate from
network authorization; a missing network packet is never local authorization.

D3 consumes the existing DomainRuntime admission/settlement values and moves only
the app client-policy value projection into `MCPToolAdmissionPolicy`. DomainRuntime
continues owning permits, request identities, cancellation, settlement, delivery,
and replay. No additional wire-ID deduplication or headless signature change.

The nonthrowing metadata compatibility helper is **not an authorization boundary**:
absent metadata can classify as administrative in compatibility code. Safety relies
on mandatory binder/read ingress and the preserved scoped, explicit packet through
the structured Host Task, runTool/start gate and heartbeat. Carrier-free MCPService
getters return nil, never live successor metadata. No throwing-signature expansion
into unclaimed callers or production admission weakening is included.

Local source gates are green on the v8 freeze: broad ticket
`c6cb5b47-e9e3-4aad-8f6c-42285c5a1296` executed 4,142 tests, with 4,140 passed,
0 failed and 2 skipped; DomainRuntime 268 and MCPCore 66 passed. Exact regressions
6, affected 195, repaired exact 11 and affected three-suite 78 passed. Final v8
format/lint/guardrails passed with no source drift. The prior broad-v7 failure
(4,129 passed, 11 failed, 2 skipped) remains historical evidence, not erased.

Final acceptance still requires **final-head `make dev-build`**, thorough live CE
MCP E2E (approval/denial, multiwindow, cancellation, replay), and headless
initialize/list/read-only coverage; debug packaging/runtime checks are **NOT_RUN**.
No lifecycle occurs without separate explicit approval through the overseer. The
local v8 receipt does not certify integration onto a newer main.

### Soft conflicts and churn rules

| Pair | Overlap | Rule |
| --- | --- | --- |
| 3 ↔ 4 | PR 3 adds `import`s and access lifts in WorkspaceContext files that PR 4 edits | PR 4 never edits `Infrastructure/{FileSystem,VCS,Persistence}` or the settings store. Whichever lands second replays its mechanical import edits (access-lift or import script), not a hand merge |
| 5 ↔ 6 | PR 5 relocates `Infrastructure/WorkspaceContext`, which MCP files import | PR 6 never edits files under `Infrastructure/WorkspaceContext`, `Features/Search`, or `Features/CodeMap`. PR 5 gets an announced **merge window**, and PR 6 rebases after it |
| 7 ↔ 9 | PR 7 relocates `Infrastructure/MCP` (not `WindowTools`/`ViewModels`); PR 9 edits `Features/AgentMode` | PR 9 never edits `Infrastructure/MCP`. PR 7 gets a merge window |
| 8 ↔ 9 | Both touch runtime provider references | Serialized in lane AI (PR 9 after PR 8) |
| 3, 5, 7, 10 ↔ `main` feature work | Big relocations | Each move PR announces a merge window and is rebuilt by replaying its move script on the current `main` |
| All ↔ `Package.swift`, `modules.json`, `ratchets.json` | Every PR edits them | These are append-only rows per target. Conflicts are resolved by keeping both rows and re-running the ratchet `update` |

### Lanes and timeline (3 worktrees after PR 2; weeks from today)

Estimates are milestone agent-days at about 0.8× the §2 slice sums, since a single PR per milestone saves the per-PR review and merge overhead.

```
week:      1    2    3    4    5    6    7    8    9   10
gate  [1][====== 2 ======]
M                         [==== 3 ====][= 5 =]   [7]   [==10==]
P                         [== 4 ==][====== 6 ======]
AI                        [==== 8 ====][===== 9 =====]
```

| PR | Agent-days [E] | Lane |
| --- | --- | --- |
| 1 | ≈ 0.5 (CI and merge) | gate |
| 2 | 13–21 (two engineers can share the branch; a single PR) | gate |
| 3 | 10–16 | M |
| 4 | 6–9 | P |
| 5 | 4–7 | M |
| 6 | 11–17 | P |
| 7 | 3–6 | M |
| 8 | 9–14 | AI |
| 9 | 10–16 | AI |
| 10 | 6–11 | M |

**Calendar.**
- Critical path: 1 → 2 → 4 → 6 → 7 → 10, with PR 9 finishing in parallel.
- Total: **≈ 40–65 agent-days ≈ 8–13 weeks, ≈ 10 expected**, with 3 lanes and ≈ 72–117 agent-days of total effort.
- The largest remaining risk to the calendar is PR 2, the serial gate (≈ 3–4 weeks).

**Worktrees.** Three lanes after PR 2. The ADR-08 admission scheduler in PR 2 handles heavy-slot contention. U2's condition still applies: if heavy-slot wait p90 exceeds 5 min, lane AI pauses behind lane M.

### Follow-up list (out of scope for the ten PRs)

- T6, cross-worktree cache sharing (conditional).
- Everything in the appendix, "Later / further efficiencies".
- The CI `SentryTelemetryPrivacyTests` filter matches no tests (conductor ticket `6b988fb3`, found in PR 2), so that job is not privacy-test evidence. Fix the filter or the test names.

---

## 0. Summary

- **Finish line.** Two goals:
  - **G1:** a majority of day-to-day edits run their own module's tests without building `RepoPromptApp`, and new code cannot land in the old app or add wrong-way edges;
  - **G2:** headless MCP can be finished on stable, app-free seams.
- **How each is measured (§1.3).**
  - G1: ≥ 55% of Swift file edits land in app-free modules (15% today [M]); module edit→test p50 ≤ 60 s; the CI critical path ≤ 15 min with one app build (25 min longest job and five app builds today [M]); ratchets and an edge matrix enforced in CI.
  - G2: seven named headless seams exist in app-free targets, each with contract tests.
  - App share is tracked, not targeted. It lands near **40%** (88.4% today).
- **Scope.** 29 slices, and 6 of them are tooling (plus a conditional T6):
  - tooling T0–T5;
  - foundations A1–A5;
  - platform B1–B4;
  - WorkspaceContext C1–C3;
  - MCP server D1–D4;
  - AI E1–E2;
  - agent runtime F1–F4;
  - exit X.
- **Total [E].** About **77–110 PRs** and **89–147 agent-days** (midpoint ≈ 118). With **2 worktrees** that is **9–15 weeks, ≈ 12 expected**. The critical path runs through WorkspaceContext, then the MCP server move, then the agent-runtime move. The previous draft needed 17–30 weeks.
- **Headless checkpoint.** At about **week 6–7**, WorkspaceContext (C3) and S5/S6 (D1/D2) have landed. The port-vs-rebuild decision can then be made. Porting settlement/admission waits for D3 (week 7).
- **Deferred** (appendix): the design system and fonts (S1); feature UI splits (Settings, Prompt, Chat, ContextBuilder, Workspaces, WorkspaceFiles, AgentMode UI, MCP presentation, Diagnostics); window capabilities (S2) and the composition-root slimming; the full god-file decompositions (`WorkspaceFileContextStore`, `MCPConnectionManager`, `AgentModeViewModel`, `GitService`); Presets; the SwiftSyntax codemod toolkit; the no-change focused test ≤ 15 s; the test-sleep ratchet; cross-worktree caching (conditional, T6).

---

## 1. Goals, evidence, and exit criteria

### 1.1 Goals (define "done")

- **G1: developer productivity.** Build and test inefficiencies are removed where most editing happens, and new features cannot get tangled into the old app.
- **G2: headless readiness.** Headless MCP can be finished without revisiting modularization-related architectural flaws. The seams it needs are request settlement/admission, DomainRuntime, WorkspaceContext, the MCP window tools, and VCS.

### 1.2 Evidence that sets the scope [M]

**Where edits land.** The sample is 90 days of `main` (since 2026-07-01), 677 commits that touch Swift sources, and 3,951 Swift file touches. Each row adds modules on top of the row above it.

| Code outside `RepoPromptApp` | Share of file touches | Commits touching only module code |
| --- | --- | --- |
| Today (DomainRuntime, MCP CLI/Core, Shared, CodeMapCore, RegexCore, WorkspaceCore, provider package) | 15% | 6% |
| + leaf adapters (Foundation, Regex, Process, FileSystem, VCS, Security, Persistence) | 23% | 12% |
| + WorkspaceContext (incl. Search, CodeMap orchestration) | 28% | 17% |
| + MCP server (`Infrastructure/MCP` minus `ViewModels/`, `WindowTools/`) | 38% | 22% |
| + AI (contracts and providers) | 47% | 29% |
| + agent runtime (`AgentMode/{Runtime,History,Routing,Services,Providers,Models,Recommendations}`) | **60%** | 38% |

- **What this means.**
  - The agent runtime is what takes G1 past a majority. Without it, the reach is 47%.
  - The remaining app-side hot spots are UI and view models: `AgentMode/ViewModels` 291 touches, `MCP/WindowTools` 177, `AgentMode/Views` 160, `MCP/ViewModels` 129, `Settings/Views` 103.
  - Feature commits span logic and UI, so the whole-commit share stays lower. The edit→test loop is per file edited, so file touches are the measure.
- **Probe findings [M].**
  - **Agent runtime to providers.** 10 runtime files reference concrete provider types: `CodexNativeSessionController`, `CodexAppServerClient`, `ACPAgentSessionController`, `ClaudeNativeProcessSessionController`, and others. Most of them are in `Runtime/Codex` and `ProviderConversationCleanupRegistry`. The providers (E2) therefore move before the runtime (F4).
  - **Settings store.** `GlobalSettingsStore` is declared inside the 2,780-line `Settings/Models/GlobalSettingsManager.swift`. It imports Foundation only, with no `Bundle.main`. Its app couplings are `PromptViewModel.PlanActMode` and one app notification. `GlobalSettingsDocument` (648 lines) and `GlobalSettingsFileStore` (742) have none. The consumers that matter here are 7 MCP-server files and 6 runtime files, plus 0 in WorkspaceContext. A small pre-work step plus a move replaces the facet redesign.
  - **Small folders.**
    - `Infrastructure/Diffing` has one consumer, in AI, so it folds into E2.
    - `Security` is used by runtime (1 file), AI (2), the app (3) and other UI (3). `BundleIdentityDefaultsMigration` and `RuntimeCodeSigningPolicy` read `Bundle.main`, so the target is app-only.
    - `Persistence/CodeMapArtifacts` is used by WorkspaceContext (2 files).
    - `Persistence/DurableArtifacts` has no external references.
    - `Persistence/Presets` is used only by AI (1) and UI (2), so it is deferred.
- **CI [M].**
  - Run `34618892604` on main took 36.5 min wall.
  - The longest single job was 25.3 min (root shard 1). The four test shards took 15.9–25.3 min each, and the Sentry build 23.2 min.
  - That is **five app builds per run**. Recent main runs took 26–39 min wall, including runner queueing.
- **Edit→test [L].**
  - App aggregate path: median 2.9–4.7 min, p90 9–12 min.
  - Module path (ADR-07): median 33.5–48.1 s on the two measured targets.
  - Heavy-slot wait: p90 8.8 min, with waits up to 35 min seen.

### 1.3 Exit criteria (done when all hold)

| # | Goal | Criterion | Target | Measured by |
| --- | --- | --- | --- | --- |
| X1 | G1 | **Edit locality:** share of Swift file touches, over the trailing 60 days of `main`, that land in targets whose owning test target does not build `RepoPromptApp` | **≥ 55%** (15% today; 60% projected from the §1.2 history) | `modularization_metrics.py edit-locality` (added in T2) |
| X2 | G1 | Module edit → owning tests pass, excluding queue | p50 ≤ 60 s, p90 ≤ 3 min over ≥ 20 `--module` jobs | `conductor_job_timings.py` |
| X3 | G1 | Every family moved by this plan has an owning `<Module>Tests` target. Tests for moved code live there, with no `@testable import RepoPromptApp` | Owning target for each; `tests_testable_import_app_files` ≤ 175 (325 today [M]; [E] from the test folders that move) | Module catalog, gated ratchet |
| X4 | G1 | CI critical path, excluding runner queueing | Longest job ≤ 15 min, and **one** app build per PR run (the Sentry variant is conditional or off the PR path). Fallback: ≥ 40% below the baseline measured at T5 start | `gh run view` job timings |
| X5 | G1 | Heavy-slot wait with 2 active worktrees | p90 ≤ 5 min | `conductor_job_timings.py` |
| X6 | G1 | The cycle is broken along the seams that matter | No SwiftPM target cycle. Every moved family has zero edges into `RepoPromptApp` (compiler-enforced). The index shows 0 remaining wrong-way edges through seams S3–S6, S8, S9, S12, S17. The largest app SCC is reported, not targeted | Compiler; `modularization_index_graph.py report` |
| X7 | G1 | Guardrails stop regressions | In CI: `--explicit-target-dependency-import-check error`; the allowed-edge matrix; a placement guardrail for each moved family (new files for that family go in its module); the ratchets in §1.5 gated | CI and `make guardrails` |
| X8 | G2 | Headless seams exist in app-free targets, each with a contract test in its module | (a) `ToolInvocationContext` (`Sendable`, no window references); (b) an admission-policy value plus a settlement-result type in `RepoPromptMCPServer`; (c) the file-tool authority snapshot in the server layer; (d) a read-only, root-scoped WorkspaceContext snapshot; (e) non-`@MainActor` VCS worktree and repository queries; (f) an `IgnoreMatcher`-shaped API in FileSystem; (g) a global-ignore settings facet. DomainRuntime gains no app dependency and nothing is moved out of it | Module catalog; contract tests; §3 notes |
| X9 | G1 | No regression > 10% | Release build time, launch time, peak memory, Repo Bench | At C3, D4, F4 |

### 1.4 Tracked, not goals

| Number | Today [M] | Projected at exit [E] |
| --- | --- | --- |
| App share of first-party Swift | 88.4% (652,086 / 737,191) | **≈ 40%** (≈ 350–370k lines out), before feature growth |
| Index wrong-way edges / largest file SCC | 1,364 / 640 of 1,161 | Reported at each move; no target |
| Feature edit → debug package | 13.2 / 60 min [L] | Reported at C3, D4, F4 |
| No-change focused test | 22 s on the module path [L] | Deferred (appendix, X7) |

### 1.5 Ratchets: each is gated as soon as its slice lands

| Ratchet or guardrail | Gated in | Notes |
| --- | --- | --- |
| `tests_testable_import_app_files` (non-increasing) | T1 | The regex is exact. Every test move lowers the baseline in the same PR |
| `app_files_over_2000_lines` | T1 | Exact line counts |
| `app_target_swift_lines` advisory reference | T1 (advisory since 2026-10-03) | Baseline plus unchanged headroom is reported, not gated; numeric baselines and all other gates remain unchanged (see ledger policy) |
| Import check `error` and the allowed-edge matrix | T1 | Covers the existing targets; each new target adds its row in its move PR |
| Placement guardrail ("new files for a moved family go in its module") | T1, then extended by each move PR | This is the main "no new code in the old app" lever |
| Per-target guardrails: no SwiftUI/AppKit in logic targets, no `RepoPromptApp` import, `bundle_main_allowed_roots` | Each target's move PR | P0.6 checklist |
| Index wrong-way edges and largest SCC (non-increasing); type-check budgets (≥ 1,000 ms bodies = 10, ≥ 500 ms expressions = 6) | T5 | Needs the build-producing CI job and trusted freshness (T3) |
| `app_files_over_5000_lines`, `app_static_shared_declarations` | Already gated | — |

---

## 2. Slices

> Under the ten-PR execution model, these slices are work items inside milestone PRs. The PR counts below are historical sizing only.

Sizes come from text measurements in the first draft [M]. "Days" is agent-days [E]. Each PR lands within about a day, so a slice is its PR count. Readiness is re-run at the start of every slice (program plan §7 step 1), and a slice is re-estimated if its blockers differ.

### 2.1 Tooling (runs alongside wave A; the move audit comes first)

| ID | Scope (first-draft ID) | Goal | Size | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| **T0** | `Scripts/modularization_move_audit.py` plus tests (§4.4); a diagnostics-driven **access-lift script** (parses "inaccessible due to `internal`" errors, adds `package`); a test-import retarget helper; `make new-module NAME= FAMILY=` template (P1-a) | G1 | ~500–800 script lines | tooling ×1–2 | 1–1.5 | — |
| T1 | `modules.json` and `docs/architecture/modules.md`; CI import check `error`; allowed-edge matrix; placement guardrail; gate the §1.5 T1 ratchets (P1-b) | G1 | Manifest, guardrails, CI | tooling ×1–2 | 1–2 | T0 |
| T2 | `dev-test MODULE=`; `FILTER` → owning-target resolution; `edit-locality` metric (X1) (P1-c) | G1 | conductor, metrics | tooling ×1–2 | 1–2 | T1 |
| T3 | Index freshness by content hash, not mtime (P1-d) | G1 | `modularization_index_graph.py` | tooling ×1 | 0.5 | — |
| T4 | **ADR-08 admission v2**, weighted by measured `peakRss` (module jobs ≈ 1.5 GiB, app and aggregate links 3–5 GiB [L]) (P1-f) | G1 | conductor | tooling ×2–3 | 2–3 | T2 |
| T5 | CI: one app build per run (build once, then fan out test shards); module-test jobs for extracted targets; affected-target selection; the index and type-check gates (P1-e) | G1 | `.github/workflows/ci.yml`, runner | tooling ×2–4 | 2–4 | T3 |
| *T6* | *Conditional:* ADR-08 §5.5 cross-worktree cache sharing, **only if** after T4 the cold per-worktree scratch builds still cost > 10% of agent build time, and clean-vs-cached equivalence passes | G1 | conductor | tooling ×1–2 | 1.5–3 | T4 |

T6 is not in the totals.

### 2.2 Wave A: foundations

| ID | Scope, target | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | `RepoPromptFoundation`: Concurrency, Utilities, Networking, SyntaxParsing; plus the `Notification.Name` constants used by the moved closures (a slim S13) (W1-1) | G1 | 22 files, ~1.4k lines; 3 blockers (`CustomOpenAIProvider` error enum, `LineRange`, `SliceRangeMath`) [L] | L×1 → M×1 (+M×1 names) | 2–3 | T0 |
| A2 | S12 `RepoPromptInstrumentation`: event and sink contracts and a no-op sink for `AgentModePerfDiagnostics`, `MCPToolExecutionDiagnostics`, `WorkspaceRestorePerfLog`/`WorktreeStartupInstrumentation`, `AgentSessionLinkCatalogDiagnostics`; Telemetry. Implementations stay in Diagnostics (W1-4) | G1 | ~3.9k lines; removes ~83 index wrong-way edges | L×3 (one per family) → M×1 | 3–5 | A1 |
| A3 | `Infrastructure/Regex` adapters → `RepoPromptRegexCore` (W1-2) | G1 | 3 files, 1.7k | M×1 (+L×1 if readiness finds app references) | 1–1.5 | A1 |
| A4 | `RepoPromptProcess`: `Infrastructure/Process` (+CLI) (W1-5) | G1+G2 | 24 files, 5.7k; inbound 46 files / 179 symbols; 4 non-Foundation blockers [L] | L×1 → A×1 → M×1 | 2–3 | A1 |
| A5 | `RepoPromptSecureStorage` (app-only; added to `bundle_main_allowed_roots`) (W1-6) | G1 | 14 files, 3.9k; consumers: runtime 1, AI 2, app 3, UI 3 | L×0–1 → M×1 | 1.5–2.5 | A1 |

### 2.3 Wave B: platform

| ID | Scope, target | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | `RepoPromptFileSystem`: FSEvents, `FileSystemService`, `GitignoreCompiler` behind an `IgnoreMatcher`-shaped API, disk writer; `WorkspaceDiskWriter.shared` (40 uses) to injection (W2-1) | G1+G2 | 33 files, 18.9k; tests 5 files | L×2–3 → M×1 (A×1 if > 50 files need access) | 4–6 | A4 |
| B2 | `RepoPromptVCS`: evict feature references; expose worktree and repository queries as non-`@MainActor`, app-free APIs; move. **No `GitService` decomposition** (W2-2, reduced) | G2+G1 | 54 files, 32.2k; tests 14 files | L×2–3 → M×1–2 | 4–6 | A4, B1 |
| B3 | `RepoPromptPersistence`: `CodeMapArtifacts` (+`DurableArtifacts`). **Presets deferred** (W2-3, reduced) | G1 | ~10k [E] of 15k; CodeMap artifact goldens must stay byte-identical | L×0–1 → M×1 | 1.5–3 | B1 |
| B4 | `RepoPromptSettingsCore` (app-only): split `GlobalSettingsStore` out of its 2,780-line mixed file; drop its `PromptViewModel.PlanActMode` and app-notification couplings; move store, document, and file store, **keeping `.shared` for now**; add a global-ignore facet (W2-4, reduced) | G1+G2 | ~3.4k lines [E]; 7 MCP-server and 6 runtime consumers; settings goldens and `testGlobalSettingsDocumentPersistedKeysArePinned` must hold | L×2 → M×1 → L×1 (facet) | 3–5 | A1 |

### 2.4 Wave C: WorkspaceContext

| ID | Scope | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | S9 `WorkspaceModel` values downward (37 edges); S8 `WorkspaceFilesViewModel` selection and projection contracts (10 edges); S17 `PromptViewModel` (26) and `WorkspaceManagerViewModel` (20) consumers (W3-1) | G1+G2 | ~40 consumer files [E] | L×4–5 | 4–6 | B3 |
| C2 | A **read-only, root-scoped snapshot** value type separate from the mutating selection store, plus only the `WorkspaceFileContextStore` carve-outs the move needs. **No full 22.8k-line split** (W3-2, reduced) | G2 | 22.8k-line file; 2–4 extractions | L×2–4 | 3–5 | C1 |
| C3 | Move `RepoPromptWorkspaceContext` (+`…Search`, + `…CodeMapOrchestration` if the closure warrants), including `Features/Search` and `Features/CodeMap` orchestration; the codemap binding engine moves whole (W3-4, W3-5) | G1+G2 | ~110 files, ~85k; tests 28 + part of 14 files | L×1 → A×1 → M×2–3 | 5–9 | C2 |

### 2.5 Wave D: MCP server

| ID | Scope | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | S5: hoist immutable invocation-context values out of `MCPServerViewModel`: `RequestMetadata` (63 refs / 16 files), `TabContextSnapshot` (47/14), `ResolvedTabContextSnapshot` (34/10), `FrozenFileToolAuthority` (25/6), `ConnectionBindingSnapshot` (13/3) (W5-1) | G2 | ~5.1k plus ~40 consumer files | L×3–5 | 4–7 | A2 |
| D2 | S6: an explicit `ToolInvocationContext` threaded through dispatch, replacing ambient `ServerNetworkManager.shared` state (31 files). Fails closed; idempotent against duplicate request IDs and cancellation. **High risk** (W5-2) | G2 | 31 files | L×1 (type plus dual path) → L×3–4 (by tool family) → L×1 (remove fallback) | 6–9 | D1 |
| D3 | An admission and settlement **policy seam** extracted from `MCPConnectionManager`; the authority snapshot type moves into the server layer. **No full 16.9k-line split** (W5-3, reduced) | G2 | 2–4 extractions | L×2–4 | 3–5 | D2 |
| D4 | Move `RepoPromptMCPServer` (transport, dispatch, admission, policy). `WindowTools` stay app adapters registered by composition (W5-4) | G1+G2 | ~45–60k [E]; tests `MCP` 43 files | L×1–2 (evict VM and `App` edges) → M×1–2 | 4–7 | C3, D3, B4 |

### 2.6 Wave E: AI

| ID | Scope | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| E1 | `RepoPromptAIContracts`: provider-neutral model and catalog DTOs, `AgentACPModelRegistry.shared` to injection, `AgentRuntimeProviderService` vocabulary. Raw values unchanged (W4-1) | G1 | ~5.1k; 150 index edges from 61 files | L×3 → M×1 | 4–6 | A2 |
| E2 | Provider families to their own targets: Codex app-server (`CodexNativeSessionController` 9.4k), ACP, the Claude bridge (two-bridge rule kept), the rest. `Infrastructure/Diffing` folds in (its only consumer is AI); the one Presets reference is inverted (W4-2) | G1 | ~125 files, ~56k (+1.9k Diffing); tests 16 files | L×3 → M×3–4 | 7–12 | E1, A4, A5 |

### 2.7 Wave F: agent runtime

| ID | Scope | Goal | Size [M] | Labels (PRs) | Days | Depends on |
| --- | --- | --- | --- | --- | --- | --- |
| F1 | S3: hoist neutral values out of `AgentModeViewModel+Types` (144 nested types used from 53 files) to top level. A nested `typealias` is left behind, so **consumers do not change**. Type-name identity is checked by P0.6 item 3 (W6-1, no codemod) | G1 | ~1.1k; 22 edges | L×2–3 | 2–4 | E1 |
| F2 | S4: Codex turn **state** out of `AgentTabSession` (156 Codex members used from 19 files) into a store owned by the Codex runtime (W6-2) | G1 | 19 files | L×3–4 | 4–6 | F1 |
| F3 | A runtime-owned session store; the 13 stored runtime→`AgentModeViewModel` references inverted; provider-neutral seams where the runtime needs them. **The full 21.8k-line VM decomposition is deferred** (W6-3, reduced) | G1 | 13 references [L]; 10 runtime files with concrete provider references [M] | L×4–6 | 6–10 | F2 |
| F4 | Move `RepoPromptAgentRuntime` (+ a Codex runtime sub-target; History, Routing, Services, Providers, Models, Recommendations) and retarget its tests (W6-4) | G1 | Runtime 100 files, 67.2k, plus ~13k; tests: the runtime part of `AgentMode`'s 132 files | A×1 → M×3–5 → M×1–2 (tests) | 6–11 | F3, E2, D4, B4 |

### 2.8 Exit

| ID | Scope | Goal | Labels | Days |
| --- | --- | --- | --- | --- |
| X | Measure X1–X9, flip any remaining ceilings, finalize the catalog, record in the ledger | G1+G2 | tooling ×1 | 1–2 |

### 2.9 Totals, order, and schedule [E]

| Group | PRs | Agent-days |
| --- | --- | --- |
| Tooling T0–T5 | 8–14 | 7.5–13 |
| A (foundations) | 11–14 | 9.5–15 |
| B (platform) | 11–16 | 12.5–20 |
| C (WorkspaceContext) | 10–14 | 12–20 |
| D (MCP server) | 12–19 | 17–28 |
| E (AI) | 10–11 | 11–18 |
| F (agent runtime) | 14–21 | 18–31 |
| X | 1 | 1–2 |
| **Total** | **≈ 77–110** | **≈ 89–147 (mid ≈ 118)** |

Two worktrees, one of them on the critical path. Weeks use the midpoints and 5 agent-days a week.

| Weeks | Lane A (critical path) | Lane B |
| --- | --- | --- |
| 1–2 | T0 → A1 → A4 | T1 → T2 → T4 → T3 → T5 |
| 2–4 | B1 → B3 | A2 → A3 → A5 |
| 4–6 | C1 → C2 → C3 | D1 → D2 |
| **6–7: headless checkpoint** | C3 lands | D2 lands; D3 |
| 7–8 | B4 → D4 | E1 |
| 8–12 | E2 → F4 | F1 → F2 → F3 → B2 |
| 12 | X | — |

- **Critical path:** T0 → A1 → A4 → B1 → B3 → C1 → C2 → C3 → D4 → F4. D3 and F3 must land before D4 and F4. The calendar is set by the load on both lanes: **9–15 weeks, about 12 expected.**
- **Lane rules.** Only one lane may hold a god file at a time. D1/D2 edit the MCP view model and dispatch in place, while C edits the workspace store, so they do not collide.
- **B2 (VCS) runs late** because it is off the critical path. If headless VCS work is wanted at the week 6–7 checkpoint, swap B2 ahead of E1 on lane B, at a cost of about 1 week to F.
- **Merge latency.** The next independent slice starts while a PR waits to merge. Dependent slices wait for the merge; nothing is stacked.

---

## 3. Headless plug-in notes (boundaries only; no headless code is ported or rewritten)

The frozen branch touched these areas (`git diff --stat` [M]): MCP CLI 15 files, DomainRuntime 25, VCS 10, FileSystem 8, WindowTools 6, WorkspaceContext 6.

- **Process (A4).** Keep `RepoPromptProcess` free of `Bundle.main` and `UserDefaults.standard`. The bounded read backends and the direct-headless coordinator can then link it from `RepoPromptMCPCore` unchanged.
- **FileSystem ignore (B1) and Settings (B4).** The branch unified global ignore behind a DomainRuntime ignore engine (M8K–Q, M14). `IgnoreMatcher` in FileSystem and the global-ignore facet in SettingsCore are the only two owners a port changes. Ignore logic is not moved into DomainRuntime here.
- **VCS (B2).** Headless needs nested-Git parity and worktree root overlays, including the M22 P2 "worktree opt-out ineffective" fix in `prepareSessionRootOverlay`. The non-`@MainActor`, app-free worktree and repository queries are what a CLI-side lane calls.
- **WorkspaceContext (C2/C3).** Headless read backends need a read-only, root-scoped projection with root authority and leases (M21–M22) and an app-independent code-structure query core (M15). The C2 snapshot type is that input. The code-structure entry point in `…CodeMapOrchestration` takes the snapshot, not the store. No AppKit, `Bundle.main`, or `UserDefaults.standard`.
- **DomainRuntime (all waves).** It stays the single MCP catalog, registry, and workspace/context authority. It gains no app dependency, and nothing moves out of it into app-only targets. The branch's `Ignore/`, `Search/`, and `ContextBuilder/` settlement cores can therefore land there later without reshaping. New targets depend on DomainRuntime, never the reverse.
- **Request settlement and admission (D2/D3).** The branch built proxy startup and terminal settlement, shared direct-headless admission, off-main `tools/call` routing, disconnected replay, and typed retry errors (M8A–J). D3's admission-policy value and settlement-result type are consumed by dispatch. The app supplies today's policy and a headless port supplies its own, without forking dispatch. `ToolInvocationContext` (D2) carries connection identity, the authorization snapshot, and the request ID. It is `Sendable` with no window references.
- **MCP window tools (D4).** They stay app adapters registered by composition against the one DomainRuntime tool definition. A headless implementation registers as a second backend of that definition, never as a second registry. The authority snapshot lives in `RepoPromptMCPServer`, so either backend can recheck it after `await` (M9–M11).
- **Agent session host (F3).** The M22 P2 bug "early cancel can be lost" is a design input: launch state, including pending-start cancellation, is stored before a session becomes visible. The session-store contract sits in `RepoPromptAgentRuntime`, so a headless host implements it instead of subclassing app types.

---

## 4. Rules for every slice

> Under the ten-PR execution model: "PR" in §4.1–4.2 means the milestone PR. The review rule is the single Astra review defined in the execution model, which supersedes per-slice review. The move audit (§4.4) still proves every pure-move part.

### 4.1 PR shape

1. **Its own PR, targeting `main`.** Never stacked on another PR branch; a dependent slice waits for its predecessor to merge. Branch from the current `origin/main`.
2. **Lands within about a day.** If review or CI pushes it past that, rebase by replaying the mechanical step (the move script or the access-lift script) on the current `main`, not by resolving move conflicts by hand.
3. **Logic pre-work and pure moves are separate PRs.**
   - An **L** PR is a behavior-preserving logic change with tests.
   - An **M** PR contains only:
     - `git mv`;
     - `Package.swift`;
     - the catalog, guardrail, conductor-index, and ratchet-baseline updates;
     - the access-modifier and `import` edits the move requires.
   - An **A** PR is used only when the access edits alone exceed about 50 files.
4. **Ledger entry in the same PR:**
   - the move manifest (old → new path);
   - symbol access changes;
   - conductor tickets;
   - before/after timings;
   - ratchet deltas;
   - P0.6 checklist results.
5. `preflight.sh commit` and `preflight.sh push` on every PR; `pr-ready` for manifest, Xcode-workspace, or CI changes.

### 4.2 Independent review

- Every PR is reviewed by someone who did not write it: a human, or a separate review agent with a fresh context.
- **Each finding is confirmed or refuted with evidence:**
  - *Confirmed:* fixed, with the fixing commit.
  - *Refuted:* the file:line, command output, test ticket, or index `edge` query that shows it is not a defect.
  - *Deferred:* only with an issue link and maintainer agreement.
- Nothing is closed with "looks fine".
- For **M** and **A** PRs the reviewer re-runs the move audit (§4.4) and checks its report instead of reading moved bodies.

- **Reviewer model and depth (user rule, 2026-09-29).** Every slice PR and every wave gets a critical review by a **read-only GPT-6 Astra session**:
  - `codexExec:gpt-6-astra-high` for Tooling (T0–T5) and waves A, B, and E;
  - `codexExec:gpt-6-astra-xhigh` for waves C, D, and F (god-file carve-outs, concurrency, ordering and cancellation), and for any **L** PR in any wave that touches settlement, admission, cancellation, or actor isolation.
- **End-of-wave review.** When a wave's last PR is up, one XHigh cross-PR review covers the whole wave. It checks:
  - exit criteria and seam contracts met;
  - no behavior drift across the PRs;
  - ratchets actually gated.
  The next wave does not start until its findings are dispositioned.
- **Timing.** An independent review starts as soon as a PR is pushed, in parallel with CI; neither waits for the other.
  - The reviewer is pinned to the exact head SHA and records it in its report.
  - If a push moves the head during review, the report notes it; the review does not restart.
- **Reviewers are read-only:** no GitHub writes and no edits. Reports go to `/tmp/rpce-pr-reviews/<PR>.md`, and end-of-wave reports to `/tmp/rpce-pr-reviews/wave-<X>.md`, with evidence alongside.
- **The author dispositions each finding against the code and tests:**
  - **CONFIRMED:** fixed, with a regression test.
  - **REFUTED:** with evidence.
  - **UNRESOLVED:** with what would settle it.
  Evidence-backed pushback counts as a resolution. Severity may be re-ranked with a stated reason.

### 4.3 Validation

| Check | L | A | M | Wave exit |
| --- | --- | --- | --- | --- |
| `make guardrails` (runtime identity, ratchets, placement, edge matrix) | ✓ | ✓ | ✓ | ✓ |
| Move audit (§4.4) | — | ✓ | ✓ | — |
| `make dev-swift-build PRODUCT=all` | ✓ | ✓ | ✓ | ✓ |
| Owning module tests, `dev-test MODULE=<T>Tests` | ✓ | ✓ | ✓ | ✓ |
| Dependents' focused tests | ✓ | ✓ | ✓ | — |
| Full suite, `make dev-test` (same test count, 0 failures) | If the PR touches app sources | ✓ | ✓ | ✓ |
| `ModularizationCompatibilityGoldenTests` plus the P0.6 checklist ([ledger](ledger.md), "Slice checklist") | If identity sites are touched | ✓ | ✓ | ✓ |
| `make dev-lint` | ✓ | ✓ | ✓ | ✓ |
| Index `report` recorded | — | — | ✓ | ✓ |
| `make dev-smoke` | MCP, agent, or packaging slices | — | MCP, agent, or packaging slices | ✓ |
| Release build plus Repo Bench | Hot paths (C, D) | — | Hot paths (C, D) | ✓ (X9) |

### 4.4 Byte-identical move audit (T0)

`Scripts/modularization_move_audit.py --base origin/main [--head HEAD] [--json out.json]`. Its tests run in `make conductor-selftest`. The script exits 1 on any violation.

1. **Rename report.** It runs `git diff --name-status -M100%` and lists each moved file with its similarity.
   - `R100` files pass.
   - Any `R<100` file, or `D`+`A` pair, goes to check 2.
2. **Normalized hash.** Normalize both sides, then require equal SHA-256. The normalization:
   - strips access keywords (`open`, `public`, `package`, `internal`) from declaration heads, only where they are the line's sole difference;
   - drops `import` lines, which are checked against the first-party allowlist instead;
   - leaves whitespace untouched.
3. **Line-class diff.** In every modified, non-moved Swift file, each `-U0` hunk line is either an access-modifier-only change or a first-party `import` added or removed.
4. **Allowed non-Swift files:**
   - `Package.swift`;
   - `modules.json`, `modules.md`;
   - `source_layout_guardrails.sh`;
   - `ratchets.json`;
   - the ledger;
   - the conductor module index;
   - `generate_xcode_workspace.py`.
5. **Discovery parity.** Given `--tests-before N --tests-after M` from the full-suite tickets, N must equal M.
6. **Output.** A human report plus JSON (manifest, similarity, hashes, violations) for the ledger.

---

## 5. Defaults applied, and where evidence changed them

| Default | Applied as | Change and evidence |
| --- | --- | --- |
| ADR-08 goes early | **T4 (admission v2) in weeks 1–2** | The evidence supports it. With 2 worktrees and the default heavy capacity of 1, heavy jobs serialize. Waits reached 35 min [L]. Module jobs peak at about 1.5 GiB versus 3–5 GiB for app links [L], so admitting by RSS lets module jobs run in parallel. The caching half of ADR-08 (§5.5) stays conditional (T6), because the ADR requires clean-vs-cached correctness evidence first |
| P1 tooling alongside wave 1, with the move audit first | T0 first; T1–T5 on lane B in weeks 1–2 | Unchanged |
| Swift Testing allowed in new module test targets; no conversion | Adopted | ADR-07 verified Swift Testing on the module path [L] |
| 2 parallel worktrees | Adopted | 3 is possible after T4; see decision U2 |
| Each ratchet gated as soon as its slice lands | §1.5 | Unchanged. `tests_sleep_calls` has no slice here (it needs a regex fix for fake-clock `sleep` declarations) and moves to the appendix |
| Codemod toolkit only if the remaining large moves justify it | **Not built** | The large edits in this scope are handled without a toolkit:<br>- The 179-symbol access lift (A4) and the C3/F4 access PRs use the T0 diagnostics-driven access-lift script.<br>- The 144 nested-type hoists (F1) use nested `typealias` shims, with zero consumer edits.<br>- Test retargets are `import` swaps.<br>The toolkit returns with the deferred feature splits (appendix P1-g) |
| Headless unfreezes once the WorkspaceContext and MCP server seams (S5/S6) exist | The **decision** unfreezes at the week 6–7 checkpoint (C3 + D2) | Refinement: **porting of settlement/admission (M8A–J) waits for D3**, and ports touching `MCPConnectionManager` or dispatch avoid D4's move window, using the move manifest as a path map. The branch's first milestones sit exactly in the code D3 restructures |

---

## 6. Risks (condensed; the full table is in the appendix, §4)

| Risk | Mitigation |
| --- | --- |
| **Ordering or cancellation changes** in the carve-outs of god files (C2, D2, D3, F2, F3) | A split map in the ledger before the first PR, listing responsibilities, the actor or queue each runs on, and the invariants each must keep. A characterization test per invariant before its code moves. Review focused on ordering and cancellation. Never combine a carve-out with a move |
| **S6 threading (D2)** fails open, or double-settles on duplicate request IDs or cancellation | The dual-path PR first, with fail-closed tests; migrate by tool family; remove the ambient fallback last |
| **Concurrency diagnostics at new boundaries** blow the one-day budget | Build the candidate target in a scratch path during pre-work and fix the diagnostics there (ADR-09) |
| **Merge churn on a busy `main`** (the app grew 3,995 lines in a day [M]) | Scripted, replayable moves; one target per move PR; announced merge windows for C3, D4, F4 |
| **Heavy-slot contention and approval overhead** | T4 first; module-scoped validation while iterating; one full suite per PR; pre-approved command classes per slice |
| **Estimates for the reduced god-file work** (C2, D3, F3) are wide | Each reruns `readiness` and publishes its split map before the first PR, and the estimate is re-issued then |

---

## 7. Decisions (approved 2026-09-29)

| # | Decision | Approved |
| --- | --- | --- |
| U1 | Scope vs. calendar | **(a) Keep wave F** (agent runtime). G1 targets 60% edit locality |
| U2 | Worktrees | **2 to start; 3 once T4 lands and heavy-slot wait measures ≤ 5 min p90** |
| U3 | X1 threshold and window | **≥ 55% over the trailing 60 days** |
| U4 | Sentry build in CI | **Conditional (by path or label) or `main` only, not on every PR** (in T5) |
| U5 | Plan location | **`docs/migrations/build-modularization/completion-plan.md`** |

---

## Appendix: Later / further efficiencies

This appendix is the complete first draft (`c90109d7`), kept so the deferred work stays sized and ordered for later. Only the headings (demoted two levels) and the relative links have changed. **Where it disagrees with the core plan above, the core plan wins.**

Core slices map back to first-draft IDs as follows:

| First-draft ID | Core slice |
| --- | --- |
| P1-a | T0 |
| P1-b | T1 |
| P1-c | T2 |
| P1-d | T3 |
| P1-f | T4 |
| P1-e | T5 |
| W1-1 | A1 |
| W1-4 | A2 |
| W1-2 | A3 |
| W1-5 | A4 |
| W1-6 | A5 |
| W2-1 | B1 |
| W2-2 | B2 (reduced) |
| W2-3 | B3 (reduced) |
| W2-4 | B4 (reduced) |
| W3-1 | C1 |
| W3-2 | C2 (reduced) |
| W3-4, W3-5 | C3 |
| W5-1 | D1 |
| W5-2 | D2 |
| W5-3 | D3 (reduced) |
| W5-4 | D4 |
| W4-1 | E1 |
| W4-2 | E2 |
| W1-3 | Folded into E2 |
| W6-1 | F1 |
| W6-2 | F2 |
| W6-3 | F3 (reduced) |
| W6-4 | F4 |

**Deferred**, with the "(reduced)" rows keeping their unreduced remainder:
- P1-g (codemod toolkit);
- W1-7 (fonts, S1) and W1-8 (DesignSystem);
- the `GitService` decomposition (rest of W2-2);
- Presets (rest of W2-3);
- the S7 facet rollout (rest of W2-4);
- the full `WorkspaceFileContextStore` split (rest of W3-2);
- W3-3 (codemap engine split);
- the full `MCPConnectionManager` split (rest of W5-3);
- the full `AgentModeViewModel` decomposition (rest of W6-3);
- all of W7 (feature and UI splits, S2 window capabilities, S13 intents, the composition root);
- exit criteria X1 (≤ 10% app share), X3–X5 (targets), X7, and X8 as gates;
- the `tests_sleep_calls` ratchet.

Status: **Proposed**. Drafted 2026-09-29 against `origin/main` `944854b7` (Phase 0, #1108 bridging header retired, #1109 `RepoPromptMCPCore` split).
Inputs: [`../build-modularization-2026-09-28.md`](../build-modularization-2026-09-28.md) (the program plan: §2 goals, §3 architecture, §4 seams S1–S17, §7 slice protocol, §8 waves) and [`ledger.md`](ledger.md) (P0.1–P0.6 evidence and ADRs). This document does not change the architecture. It turns the remaining waves into sized, ordered PRs with an exit line.

Priority (user decision, 2026-09-29): modularization runs first and goes through to completion. The headless port-vs-rebuild decision waits until after it. The frozen headless branch (`7eaf24b2`, archived as `origin/archive/headless-option-b-m8-m22`) is an **input** only. No headless code is ported or rewritten in this plan. Where a boundary touches an area headless depends on, a short **headless plug-in note** says how headless logic would attach later.

Legend: **[M]** = measured on `944854b7` for this plan; **[L]** = measured earlier, taken from the ledger; **[E]** = estimate. All time estimates are ranges in *agent-days*: one primary writer doing pre-work, the move, validation, and review fixes. Wall-clock merge latency comes on top.

---

### 0. Summary

**Where we are [M].** `RepoPromptApp` holds 1,161 files and 652,086 lines, **88.4%** of first-party Swift (737,191 lines). Five extracted logic modules have their own test targets: DomainRuntime, CodeMapCore, RegexCore, WorkspaceCore, and MCPCore. The index graph shows **1,364** wrong-way file edges into 255 files; the largest cycle spans **66 of 75** components and the largest file SCC **640 of 1,161** files. **325 of 402** test files (81%) `@testable import RepoPromptApp`. The module test executor (ADR-07) already cuts edit→owning-test time by 77–95% [L], but only for code that has left the app.

**Finish line.** `RepoPromptApp` holds ≤ 10% of first-party Swift and is composition only. Index wrong-way edges ≤ 70 and largest file SCC ≤ 50. At least 25 logic modules, each with an owning test target. At least 85% of test files do not `@testable import RepoPromptApp`. Module edit→owning test ≤ 60 s p50 / ≤ 3 min p90. Feature edit→debug package ≤ 2 / ≤ 5 min. CI PR critical path ≤ 15 min with one build. Ten ratchets gated in CI (§1.3).

**What remains.** 8 phases (P1 tooling, then W1-rest → W7): 7 tooling items and 36 slices, about **150–220 PRs** and **170–290 agent-days** [E]. The critical path runs Foundation → Process → FileSystem → workspace pre-work → `WorkspaceFileContextStore` split → WorkspaceContext move → MCP server (S5/S6) → agent runtime (S3/S4, `AgentModeViewModel`) → window capabilities and composition. It is about **80–135 agent-days** [E], roughly **4–7 calendar months** with 2 parallel worktrees. AI providers (W4), VCS, DesignSystem, and most W7 feature splits run off the critical path.

**Rules per PR.** Each PR targets `main` directly (never stacked), lands within about a day, gets an independent review in which every finding is confirmed or refuted with evidence, and passes a scripted move audit (`Scripts/modularization_move_audit.py`, added in the first slice). Semantic pre-work PRs and pure-move PRs are always separate.

**Top risks.** God-file splits changing ordering or cancellation (W3, W5, W6). Concurrency diagnostics at new boundaries. Merge churn on a busy `main`. Approval overhead and heavy-slot contention (35-min slot waits, 22-min full suites, 15-min SwiftFormat in fresh worktrees [L]).

**Your decisions (§5).** (1) ADR-08 admission v2 timing; (2) P1 tooling before or alongside W1; (3) Swift Testing policy; (4) app-share target: 10%, 20%, or 30%; (5) parallel worktrees: 1, 2, or 3; (6) when to gate tracked ratchets; (7) codemod toolkit before W3 or manual moves; (8) revise M1 (≤ 70% is not reachable after W1 alone); (9) confirm the headless branch stays frozen until W7 exits.

**Caveat.** 17 of 1,160 files are stale in the index; slice sizes for those files are from text measurement. Readiness for slices not sampled in P0.2 is estimated. Each slice reruns `readiness` before it starts (§7 step 1).

---

### 1. Finish line

#### 1.1 Current baseline

| Measure | Program baseline (plan §1–2) | Now (`944854b7`) | Source |
| --- | --- | --- | --- |
| `RepoPromptApp` files / lines | 1,160 / 648,091 | 1,161 / 652,086 | [M] `modularization_metrics.py report` |
| App share of first-party Swift | 88.3% | **88.4%** (652,086 / 737,191) | [M] |
| Files > 5,000 / > 2,000 lines in app | 17 / 50 | 17 / 51 | [M] |
| `static shared` declarations / `.shared` uses | 102 / 1,220 | 102 / 1,223 | [M] |
| Wrong-way file edges, index | 1,360 (`9e912a86`) | **1,364** into 255 files | [M] index graph, with the §0 caveat |
| Wrong-way file edges, regex (tracked ratchet) | 1,102 | 1,104 | [M] |
| Largest component cycle, index | 66 / 75 | **66 / 75** | [M] |
| Largest file SCC, index | 639 / 1,160 | **640 / 1,161** (19 non-trivial SCCs) | [M] |
| Logic modules with an owning test target | 4 | **5** (+ the provider package) | [M] `Package.swift` |
| Test files `@testable import RepoPromptApp` | 319 | **325 of 402** (80.8%); 359 import the app in any form | [M] |
| Test sleeps (regex, tracked) | 47 | 54 (baseline file: 48) | [M] |
| Module edit→owning test, excluding queue | 2.9–4.7 / 9–12 min (aggregate) | 33.5–48.1 s median on module targets | [L] P0.3, one sample per scenario |
| No-change focused test | 2.2 / 10.3 min | 2.2 s aggregate after P0.4; 22.1 s on the module path | [L] P0.4, P0.3 |
| Feature edit → debug package | 13.2 / 60 min | Not re-measured | [L] |
| Heavy-slot wait p90 | 8.8 min | Not re-measured; up to 35 min seen in P0.3 | [L] |
| CI PR critical path | 12–19 min per shard, 4 redundant builds | Unchanged | [L] |

Drift since the ratchet re-baseline is from `main` feature work, not from a slice: +594 app lines, +1 `@testable` file, +6 regex sleeps. From the 2026-09-28 baseline to now the app grew by 3,995 lines [M]. Every wave has to outrun that growth (R7).

#### 1.2 Exit criteria (the program is done when all hold)

| # | Criterion | Target | Measured by |
| --- | --- | --- | --- |
| X1 | App share of first-party Swift | **≤ 10%** (≈ 74k lines at today's size), composition and app shell only. Decision D4 may relax this to 20% | `modularization_metrics.py` `app_share_permille` |
| X2 | Wrong-way file edges inside `RepoPromptApp` (index) | ≤ 70 (≈ 5% of 1,364; what remains is the `App/Views` → `App` triage quirk). Zero edges from any target to `RepoPromptApp` (compiler-enforced) | `modularization_index_graph.py report` after a conductor build |
| X3 | Largest cycle (index) | ≤ 5 components and ≤ 50 files. No cycle between targets (SwiftPM) | Same |
| X4 | Logic modules with an owning `<Module>Tests` target | ≥ 25 (5 today). Plus ≥ 8 feature UI targets | `docs/architecture/modules.md` and `modules.json`, validated by guardrails |
| X5 | Test files **not** using `@testable import RepoPromptApp` | ≥ 85% (19% today). About 60 composition and integration files may keep it | `tests_testable_import_app_files` |
| X6 | Module edit → owning tests pass, excluding queue | p50 ≤ 60 s, p90 ≤ 3 min over at least 20 module jobs per wave | `conductor_job_timings.py` on `--module` jobs |
| X7 | Focused test with nothing changed | ≤ 15 s p50. Needs the Swift Build re-plan cost fixed (22 s today) or native per-target bundles | Same |
| X8 | Feature edit → debug app packaged | p50 ≤ 2 min, p90 ≤ 5 min | `conductor build` timings |
| X9 | Heavy-slot wait (reported separately) | p90 ≤ 1 min | Same |
| X10 | CI PR critical path, excluding runner queueing | ≤ 15 min, one app build per run | `gh run view` step timings |
| X11 | Guard rails (no regression > 10%) | Clean release build, launch time, peak memory, Repo Bench | Per hot-path slice and at each wave exit |
| X12 | Governance | `--explicit-target-dependency-import-check error` in CI; allowed-edge matrix enforced; module catalog authoritative | CI and `make guardrails` |

**Milestones [E].**
- **M1 (after W1).** The plan's "≤ 70% app share after W1" is not reachable. W1-rest moves about 31k lines, which gives about 84%. Proposed M1: ≤ 85% app share, ≥ 11 logic modules, and `dev-test MODULE=` in daily use (D8).
- **M2 (after W3).** App share ≈ 64% (W1 + W2 + W3 ≈ 181k lines out). This is where the old "≤ 70%" really lands.
- **M3 (after W6).** App share ≈ 25–30%. `AgentModeViewModel` split. MCP server headless.
- **Finish (after W7).** X1–X12.

#### 1.3 Ratchets that become gated

| Ratchet | Today | Becomes gated | Why then |
| --- | --- | --- | --- |
| `app_files_over_5000_lines` | Gated | — | — |
| `app_static_shared_declarations` | Gated | — | — |
| `tests_testable_import_app_files` | Tracked | **First W1 slice** | The regex is exact (anchored `@testable import RepoPromptApp`). Every test that moves lowers it |
| `app_files_over_2000_lines` | Tracked | **First W1 slice** | Line counts are exact. Stops new god files |
| `app_target_swift_lines` | Tracked | At W1 exit, as a *per-wave ceiling* rather than per PR | Feature work legitimately adds lines. Gate the "new files for a family with a module go in that module" guardrail first |
| Index wrong-way edges and largest SCC | Report only | After P1.4 (a CI job that builds, then runs `report`) | Needs a current index. Also fix freshness to compare content hashes, not mtimes (§4, R8) |
| Type-check budgets (`≥ 1,000 ms` bodies = 10, `≥ 500 ms` expressions = 6) | Report only | After P1.4 | Needs a compile. Values were stable across two runs [L] |
| `tests_sleep_calls` | Tracked | After the regex stops counting fake-clock `func sleep` declarations | Today it has false positives |
| Import check `error` and the allowed-edge matrix | Not enforced | **P1.1**, before W1-rest moves | Prevents new edges as soon as targets exist |
| No SwiftUI/AppKit in logic targets; no `RepoPromptApp` import; no TestSupport in production | Partly (TestSupport) | With each new target's move PR | Guardrail per target |

---

### 2. Remaining slices and phases (dependency order)

Sizes are text measurements of the file set [M] (with the §0 caveat). "Readiness" means P0.2 `readiness` output where it was sampled [L]; otherwise it is estimated [E] and gets re-run at slice start. PR counts separate **pre-work** (behavior-preserving semantic edits) from **move** (pure `git mv` plus mechanical access and import edits). Change types:
- **Move**: pure move;
- **Access**: access-level and import only;
- **Logic**: behavior-preserving logic change, such as a hoist, an inversion, an injection, or a split.

Each row is sized so that every PR lands in ≤ 1 day. A slice that would need longer is already split into several PRs.

#### P1 — Tooling (see decision D2 on ordering)

| ID | Scope | Depends on | Size | Change type | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| P1-a | `Scripts/modularization_move_audit.py` plus tests (§3.4) and `make new-module NAME= FAMILY=` template (target, `<Module>Tests`, catalog row, guardrail stanza) | — | ~400–700 script lines [E] | Tooling | 1–2 | 1–1.5 |
| P1-b | P1.1: `modules.json` and `docs/architecture/modules.md`; CI `--explicit-target-dependency-import-check error`; allowed-edge matrix for existing targets; gate the two exact ratchets (§1.3) | — | Manifest, guardrails, CI | Tooling | 1–2 | 1–2 |
| P1-c | P1.3a: `dev-test MODULE=` alias, and `FILTER` → owning-target resolution from the module index | P1-b | conductor, runner | Tooling | 1–2 | 1–2 |
| P1-d | Index freshness by content hash, not mtime (the stale-17 case in §0) | — | `modularization_index_graph.py` | Tooling | 1 | 0.5 |
| P1-e | P1.4: CI build once, fix cache effectiveness, affected-target selection; enables the index and type-check gates | — | `.github/workflows/ci.yml`, runner | Tooling | 2–4 | 2–4 |
| P1-f | P1.3b / ADR-08: admission v2, weighted by measured `peakRss` (module jobs ≈ 1.5 GiB, app and aggregate links 3–5 GiB [L]) | P1-c | conductor | Tooling | 2–3 | 2–3 |
| P1-g | P1.2: SwiftSyntax codemod toolkit (hoist nested type, lift access from diagnostics, retarget test imports) in a separate tools package | — | New tools package | Tooling | 2–4 | 2–4 |
| **P1 total** | | | | | **10–18** | **9.5–17** |

#### W1-rest — Foundations (S12, S1, plus the leaf adapters)

| ID | Scope, target | Depends on | Size [M] | Readiness | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- | --- |
| W1-1 | `RepoPromptFoundation`: `Infrastructure/Concurrency`, `Infrastructure/Utilities` (+Collections), `Infrastructure/Networking`, `SyntaxParsing` | P1-a | 22 files, ~1.4k lines. Tests: `Infrastructure/Concurrency` 1 file | Concurrency **ready**; inbound 18 files / 19 symbols. Utilities blocked by `CustomOpenAIProvider` error enum, `LineRange`, `SliceRangeMath`; inbound 52 files / 79 symbols [L] | Pre-work (Logic): relocate or invert the 3 blockers. Move + Access: ~70 inbound files get `package` access or an import | 2 | 1.5–2.5 |
| W1-2 | Regex adapters `Infrastructure/Regex` → `RepoPromptRegexCore` (or `RepoPromptRegex`) | W1-1 | 3 files, 1.7k | Not sampled [E: small] | Move + Access; pre-work only if readiness finds app references | 1–2 | 1–1.5 |
| W1-3 | `RepoPromptDiffing`; reconcile with `DomainRuntime/Diffing` | W1-1 | 6 files, 1.9k. Tests `Diffing` 6 files, 0.5k | Blocked by `AIMessage.FileChange`, `FileViewModel`, `WorkspaceFilesViewModel` (13 symbols); **0 in-app inbound** [L] | Pre-work (Logic): invert the 13 outbound symbols. Move: files and tests | 2 | 1.5–2.5 |
| W1-4 | S12 `RepoPromptInstrumentation`: event and sink contracts, no-op sink; `AgentModePerfDiagnostics`, `WorktreeStartupInstrumentation`, `WorkspaceRestorePerfLog`, `MCPToolExecutionDiagnostics`, `AgentSessionLinkCatalogDiagnostics` contracts; Telemetry | W1-1 | ~5 contract sources, ~2.8k; Telemetry 2 files, 1.1k. Removes ~83 index wrong-way edges | Not sampled [E] | Pre-work (Logic), one PR per diagnostics family (3): contract plus injection at call sites. Move: contracts. Implementations stay in Diagnostics until W7 | 4 | 3–5 |
| W1-5 | `RepoPromptProcess`: `Infrastructure/Process` (+CLI) | W1-1 | 24 files, 5.7k. Tests: 1 file | Blocked by `AsyncScope`, `TaskSemaphore` (W1-1), `FileSystemService` (2 files), `MCPConfigExportService`, `MCPIntegrationHelper`; inbound **46 files / 179 symbols** [L] | Pre-work (Logic): invert the 4 non-Foundation blockers. Access PR: 179 symbols to `package`. Move PR | 3 | 2–3 |
| W1-6 | `RepoPromptSecureStorage`: `Infrastructure/Security` | W1-1 | 14 files, 3.9k. Tests `Security` 8 files, 2.8k | Not sampled [E] | Pre-work if needed. Move. `RuntimeCodeSigningPolicy` reads `Bundle.main`, so the target is **app-only** (added to `bundle_main_allowed_roots`, never CLI-linked) | 2 | 1.5–3 |
| W1-7 | S1 fonts: `FontPreset` values downward; active scale and preset via SwiftUI environment; settings-backed authority stays in composition | W1-1 | 2 files, 0.7k; `FontScaleManager.shared` in **81 files** (129 refs); 169 index wrong-way edges | Not sampled | Logic: 1 PR for the environment key and composition wiring, then 3 PRs of ~25–30 call-site files each, grouped by folder | 4 | 3–5 |
| W1-8 | `RepoPromptDesignSystem`: `UI/Components`, `Tooltip`, `Markdown`, `UI/Services`, `Composer`, `UI` root files, `FontPreset` | W1-7 | ~58 files, ~11.7k. Tests `UI` 5, `Markdown` 3 | Not sampled [E: components referencing feature types must move to feature UI later] | Pre-work (Logic): evict feature-typed components (`UI/Agent`, pieces referencing `WorkspaceFilesViewModel`). Move: 1–2 PRs. `TextField` (4.4k) and `Mentions` wait for S8 (W3) | 2–3 | 2–4 |
| **W1-rest total** | | | **≈ 130 files, ≈ 31k lines out** | | | **20–22** | **15.5–26.5** |

> **Headless plug-in note: Foundation and Process (W1-1, W1-5).** The frozen branch's bounded read backends and `DirectHeadlessProviderCoordinator` use process launch and cancellation primitives. Keep `RepoPromptProcess` free of `Bundle.main` and `UserDefaults.standard` so a later port can link it from `RepoPromptMCPCore` without a semantic change (P0.6 checklist item 5).

#### W2 — Platform adapters

| ID | Scope, target | Depends on | Size [M] | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| W2-1 | `RepoPromptFileSystem`: `Infrastructure/FileSystem` (FSEvents, `FileSystemService`, `GitignoreCompiler`, disk writer) | W1-1, W1-5 | 33 files, 18.9k. Tests `Services/FileSystem` 5 files, 4.5k | Pre-work (Logic): invert feature references (readiness at start); `WorkspaceDiskWriter.shared` (40 uses) to injection, per plan §3.1. Access PR. Move | 4–6 | 4–6 |
| W2-2 | `RepoPromptVCS`: `Infrastructure/VCS`, GitDiff, Models; `GitService` (9.1k) decomposition first (S16) | W1-5, W2-1 | 54 files, 32.2k. Tests `Services/VCS` 14 files, 3.7k | Logic: `GitService` in-place split, 2–3 PRs. Pre-work 1–2. Move 1–2 (GitDiff may be its own target) | 5–7 | 6–9 |
| W2-3 | `RepoPromptPersistence`: `CodeMapArtifacts`, `DurableArtifacts`, `Presets` (storage mechanics only) | W1-1, W2-1 | 16 files, 15.0k | Pre-work: separate feature schemas from mechanics. Move. CodeMap artifact goldens must stay byte-identical | 3–4 | 3–5 |
| W2-4 | S7 settings storage: `GlobalSettingsFileStore`, `GlobalSettingsDocument`, JSON preservation, transaction lock → persistence mechanics; facet API. `GlobalSettingsStore.shared` (59 files) becomes facet injection *per feature as each feature moves* (W3–W7) | W2-3 | ~6 files, ~2.6k moved now; `GlobalSettingsManager` (3.1k) stays until W7 | Logic: facet API plus the first 2 facets (global ignore, notifications). Move: mechanics. Settings goldens and `testGlobalSettingsDocumentPersistedKeysArePinned` must hold | 3–5 | 4–7 |
| **W2 total** | | | **≈ 110 files, ≈ 68k lines out** | | **15–22** | **17–27** |

> **Headless plug-in note: FileSystem ignore (W2-1).** The branch unified global ignore into one authority, with a shared ignore compiler and layer engine under `DomainRuntime/Ignore` (M8K–Q). Move the app's `GitignoreCompiler` behind a narrow `IgnoreMatcher`-shaped API in `RepoPromptFileSystem`. A later port can then replace its internals with the DomainRuntime engine without touching callers. Do not move ignore logic into DomainRuntime in this plan.
>
> **Headless plug-in note: VCS (W2-2).** Headless needs nested-Git parity and worktree root overlays (`prepareSessionRootOverlay`; see M22 review P2, "worktree opt-out ineffective"). Expose worktree and repository queries as plain, non-`@MainActor`, app-free library APIs in `RepoPromptVCS`, so a headless lane can call them from the CLI process. Keep `Bundle.main` out.
>
> **Headless plug-in note: Settings (W2-4).** The branch changed global-ignore migration and load handling. Make "global ignore" the first S7 facet, so a later port changes one facet type and one owner.

#### W3 — Workspace engine (S8, S9, S17, S16)

| ID | Scope | Depends on | Size [M] | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| W3-1 | S9 `WorkspaceModel` values downward (37 edges); S8 `WorkspaceFilesViewModel` selection and projection contracts (10 edges from 8 components); S17 `PromptViewModel` (26) and `WorkspaceManagerViewModel` (20) consumers | W2 | `WorkspaceModel` 632 lines; VM edges touch ~40 files [E] | Logic: 1 PR per seam (4), plus 1–2 follow-ups | 4–6 | 4–7 |
| W3-2 | `WorkspaceFileContextStore` (22.8k) in-place split, one responsibility per PR (selection, projection, token accounting, codemap automatic selection, persistence journal, …) | W3-1 | 22.8k lines, 1 file → ~8–12 files | Logic, in place; no target change. Existing `WorkspaceFileContextStoreTests` run on every PR | 6–10 | 8–14 |
| W3-3 | `WorkspaceCodemapBindingEngine` (10.4k) and `WorkspaceCodemapLiveOverlay` (3.5k) split | W3-1 | 13.9k | Logic, in place | 3–5 | 4–7 |
| W3-4 | Move to `RepoPromptWorkspaceContext` (+ `…Search`, + `…CodeMapOrchestration` if the closure warrants) | W3-2, W3-3 | 92 files, ~71.4k. Tests `WorkspaceContext` 28 files, 7.8k; `Workspaces` 14, 11.9k (part) | Access: 1–2 PRs (codemod or diagnostics-driven). Move: 2–3 PRs, one per target | 3–5 | 5–8 |
| W3-5 | `Features/Search` (5.1k) and `Features/CodeMap` (8.1k) orchestration into the W3-4 targets | W3-4 | 17 files, 13.2k | Pre-work plus move. Repo Bench and CodeMap goldens | 2–4 | 3–5 |
| **W3 total** | | | **≈ 110 files, ≈ 85k lines out** | | **18–30** | **24–41** |

> **Headless plug-in note: WorkspaceContext (W3).** Headless read backends need a read-only workspace projection with root authority and leases (M21–M22), plus an app-independent code-structure query core (M15). Design the S8 selection/projection contract so that a *read-only, root-scoped snapshot* is its own value type, separate from the mutating selection store. Keep `RepoPromptWorkspaceContext` free of AppKit, `Bundle.main`, and `UserDefaults.standard`, so a later port can link it from the CLI. The code-structure query entry point in `…CodeMapOrchestration` should take that snapshot, not the store.
>
> **Headless plug-in note: DomainRuntime (all waves).** `RepoPromptDomainRuntime` stays the single MCP catalog, registry, and workspace/context authority. The branch put `Ignore/`, `Search/`, and `ContextBuilder/` settlement cores there. This plan adds no app dependency to DomainRuntime and moves nothing *out* of it into app-only targets, so those subfolders can land later without reshaping. New targets depend on DomainRuntime, never the reverse (plan §3.2 edges).

#### W4 — AI (S10), off the critical path

| ID | Scope | Depends on | Size [M] | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| W4-1 | `RepoPromptAIContracts`: `AgentModel*`, `AgentModelCatalog`, `AgentModelParameter`, `AgentACPModelRegistry` (33 `.shared` uses), `ACPAgentProvider`, `HeadlessAgentProvider`, `AgentRuntimeProviderService` vocabulary | W1-1, W1-4 | `ModelSelection` 8 files, 3.9k; `Providers` 6 files, 1.2k; 150 index edges from 61 files | Logic: hoist provider-neutral DTOs (2 PRs); `AgentACPModelRegistry.shared` injection (1). Move (1). Raw values unchanged | 4–5 | 4–6 |
| W4-2 | `RepoPromptAIProviders…`: Codex app-server as its own target (6 files, 12.7k; `CodexNativeSessionController` 9.4k), Codex shared and AppOnly; ACP (4 files, 5.2k); the other provider families; `AI/Agents`, `ModelCatalog`, `Prompts` | W4-1, W1-5 | 125 files, ~56k. Tests `AI` 16 files, 3.2k | Pre-work per family (Codex 2, ACP 1, the rest 1). Move per family (3–4). The Claude two-bridge rule is kept | 6–9 | 8–14 |
| **W4 total** | | | **≈ 140 files, ≈ 61k lines out** | | **10–14** | **12–20** |

#### W5 — MCP server (S5, S6, S11)

| ID | Scope | Depends on | Size [M] | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| W5-1 | S5: immutable invocation-context values (`RequestMetadata` 63 refs in 16 files, `TabContextSnapshot` 47/14, `ResolvedTabContextSnapshot` 34/10, `FrozenFileToolAuthority` 25/6, `ConnectionBindingSnapshot` 13/3) out of `MCPServerViewModel` (+`TabContext` 5.1k) | W3 | ~5.1k plus ~40 consumer files [E] | Logic: hoist 1 type family per PR | 3–5 | 4–7 |
| W5-2 | S6: explicit `ToolInvocationContext` threaded through dispatch, replacing ambient `ServerNetworkManager.shared` (`currentConnectionID`, `currentToolDispatchAuthorization`; 31 files). Fail closed; idempotent against duplicate request IDs and cancellation | W5-1 | 31 files | **Logic, high risk**: 1 PR for the context type and the dual path; 3–4 PRs migrating call sites by tool family; 1 PR removing the ambient fallback | 5–6 | 6–9 |
| W5-3 | `MCPConnectionManager` (16.9k) in-place split; `registerHandlers(for:connectionID:)` alone costs 3 s of type-checking [L] | W5-1 | 16.9k | Logic, in place | 5–8 | 7–12 |
| W5-4 | S11 tool placement by capability; move to `RepoPromptMCPServer` (transport, dispatch, admission, policy). `WindowTools` (29 files, 11.4k) stay app adapters | W5-2, W5-3 | MCP total 125 files, 88.8k; ~45–60k moves [E]. Tests `MCP` 43 files, ~30k | Pre-work: evict feature and VM references (83 edges to other VMs, 38 to `App`). Access. Move 2 PRs | 4–6 | 5–8 |
| **W5 total** | | | **≈ 45–60k lines out** | | **17–25** | **22–36** |

> **Headless plug-in note: request settlement and admission (W5-2, W5-4).** The branch built proxy startup and terminal settlement, shared direct-headless admission, off-main `tools/call` routing, disconnected replay, and typed retry/prerequisite errors (M8A–J). Make `RepoPromptMCPServer`'s admission and settlement a small policy seam: an admission-policy value plus a settlement result type, consumed by dispatch. The app composition then supplies today's policy, and a later headless port supplies its own without forking dispatch. `ToolInvocationContext` (S6) is the carrier headless also needs, for connection identity, the authorization snapshot, and the request ID. Keep it `Sendable`, with no reference to windows.
>
> **Headless plug-in note: MCP window tools (W5-4, W7).** Window-bound tools stay app adapters registered by composition, against the one DomainRuntime tool definition. A headless implementation of the same tool registers as a *second backend of that definition*, never as a second registry or schema. The branch rechecks file-tool authority after `await` (M9–M11). Keep the authority snapshot type in `RepoPromptMCPServer`, not in the window adapter, so either backend can recheck it.

#### W6 — Agent orchestration (S3, S4)

| ID | Scope | Depends on | Size [M] | Change type and PR split | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- | --- |
| W6-1 | S3: hoist neutral values from `AgentModeViewModel+Types` (1.1k; 144 nested types used from 53 files; 22 edges) to F3 | W4-1, W5-1 | ~53 consumer files | Logic: hoist by type family (codemod if P1-g exists) | 3–5 | 4–7 |
| W6-2 | S4: Codex turn **state** out of `AgentTabSession` (2.3k; 156 Codex members used from 19 files, 14 in `AgentMode/Runtime`) into a Codex-runtime-owned store | W6-1 | 19 files | Logic | 3–4 | 4–6 |
| W6-3 | Runtime-owned session store; `AgentModeViewModel` (21.8k) decomposition so that runtime never references the VM (13 stored references [L, triage]) | W6-1, W6-2 | 21.8k lines | Logic, in place, one responsibility per PR | 8–12 | 10–18 |
| W6-4 | Move `RepoPromptAgentRuntime` plus sub-targets: SessionLinks (30 files, 20.8k), Codex runtime (9, 12.2k), Transcript (8, 12.9k), Runners, ProviderBindings, Claude, Usage, ToolTracking, WorkspaceLifetime; plus History, Routing, Services | W6-3, W5-4 | Runtime 100 files, 67.2k; plus ~34 files, ~13k. Tests `AgentMode` 132 files, ~62k (retargeted) | Access 2 PRs. Move 1 per sub-target (4–6). Test retarget and hermeticity 2–3 | 8–11 | 8–14 |
| **W6 total** | | | **≈ 80k lines out** | | **22–32** | **26–45** |

> **Headless plug-in note: agent session host (W6-3, W6-4).** The branch's `DirectHeadlessProviderCoordinator` runs headless agent, Oracle, and grouped lanes. Its M22 P2 bug ("early cancel can be lost": the session is published before its launch task is stored) is a design input for the session-host contract: launch state, including pending-start cancellation, is stored before the session becomes visible. Put the contract in `RepoPromptAgentRuntime`. A headless host then implements the contract instead of subclassing app types.

#### W7 — Features, UI, composition (S2, S13, rest of S7 and S12)

| ID | Scope | Depends on | Size [M] | PRs | Agent-days |
| --- | --- | --- | --- | --- | --- |
| W7-1 | Settings logic/UI (Models 6.2k, VM 4.7k, Views 19.7k); finish S7 facets; `GlobalSettingsManager` (3.1k) | W2-4 | 4–6 | 5–8 |
| W7-2 | Prompt logic/UI (~14.9k; `PromptViewModel` 7.5k) | W3 | 3–5 | 4–7 |
| W7-3 | Chat/Oracle (~11.6k; `OracleViewModel` 4.4k) | W6 | 3–4 | 3–6 |
| W7-4 | ContextBuilder (~12.7k; `ContextBuilderAgentViewModel` 6.2k) | W6 | 3–4 | 3–6 |
| W7-5 | Workspaces (~21.6k; `WorkspaceManagerViewModel` 16.4k split first) | W3 | 5–8 | 7–12 |
| W7-6 | WorkspaceFiles (~17.7k; `WorkspaceFilesViewModel` 13.3k split first); `UI/TextField`, `Mentions` | W3 | 4–6 | 5–9 |
| W7-7 | AgentModePresentation and AgentMode UI (Views 97 files, 44.3k; VM/UI 8.8k); the four slow `body` getters (27.5 s of type-checking [L]) | W6 | 5–8 | 6–10 |
| W7-8 | MCPPresentation (MCP ViewModels 18.9k); Diagnostics split (~17.4k): engines to their data, UI to F5 | W5, W1-4 | 3–5 | 4–7 |
| W7-9 | S2 window capabilities (`WindowState` 2.6k, 54 edges; `WindowStatesManager.shared` 116 refs in 35 files); S13 notification names and intents (`AppNotifications` 39 edges) into F0/F3; per-feature assemblies; `WindowState` slimmed | W7-1…8 | 6–10 | 8–14 |
| **W7 total** | | | **36–56** | **45–79** |

> **Headless plug-in note: Context Builder (W7-4).** The branch's shared Context Builder route/stream settlement core (M16) and opt-in direct-headless discovery (M17–M20) live in DomainRuntime. Keep `RepoPromptContextBuilder` feature logic consuming a settlement *result* contract, not owning settlement, so the later port swaps the producer rather than the feature.

#### 2.1 Totals and critical path [E]

| Phase | PRs | Agent-days | Lines out of app |
| --- | --- | --- | --- |
| P1 tooling | 10–18 | 9.5–17 | — |
| W1-rest | 20–22 | 15.5–26.5 | ≈ 31k |
| W2 | 15–22 | 17–27 | ≈ 68k |
| W3 | 18–30 | 24–41 | ≈ 85k |
| W4 | 10–14 | 12–20 | ≈ 61k |
| W5 | 17–25 | 22–36 | ≈ 45–60k |
| W6 | 22–32 | 26–45 | ≈ 80k |
| W7 | 36–56 | 45–79 | ≈ 160–190k |
| **Total** | **≈ 148–219** | **≈ 171–292** | **≈ 530–575k → app ≈ 77–122k (≈ 10–17%)** |

The sized waves alone leave the app at about 10–17%, before new feature growth. Reaching X1's ≤ 10% needs W7-9 to reduce the composition root to the shell, app-bound tool adapters, and wiring, with nothing else. That is the reason for the M3 checkpoint in D4.

- **Critical path:** W1-1 → W1-5 → W2-1 → W3-1 → W3-2 → W3-4 → W5 (S5 → S6 → split → move) → W6 (S3 → S4 → VM decomposition → move) → W7-9. About **80–135 agent-days**.
- **Off the path,** in a second worktree: P1-e/f/g, W1-2/3/4/6/7/8, W2-2/3/4, W3-3/5, all of W4, and W7-1/2/5/6. W7-3/4/7/8 follow W5/W6.
- **Calendar [E].** With 2 parallel worktrees and merge latency of about 0.5 day per PR: **4–7 months**. With 1 worktree: 8–13 months. With 3: 3.5–6 months, but only after admission v2 (P1-f); otherwise heavy-slot waits eat the gain (R4).
- **Uncertainty.** The god-file splits (W3-2, W5-3, W6-3) carry the widest ranges, since their responsibility count is not yet mapped. Each gets a split map (a ledger entry) before its first PR, and the estimate is re-issued then.

---

### 3. Per-slice process rules

#### 3.1 PR shape

1. **One PR, targeting `main`.** Never stacked on another PR branch; a dependent slice waits for its predecessor to merge. Branch from current `origin/main`.
2. **Lands within about one working day** of opening. If review or CI pushes it past that, rebase by *replaying* the mechanical step (codemod or script) on current `main`, not by hand-resolving move conflicts.
3. **Pre-work and move PRs are separate** (plan §7, principle 9). Pre-work PRs are behavior-preserving logic changes, with tests. Move PRs contain only `git mv`, `Package.swift`, catalog, guardrail, and conductor-index updates, plus access-modifier and `import` edits.
4. **Ledger entry in the same PR:** move manifest (old → new path), symbol access changes, conductor tickets, before/after timings, ratchet deltas, compatibility checklist results.
5. Commit and push preflights (`preflight.sh commit` / `push`) on every PR. Use `pr-ready` for manifest, Xcode-workspace, or CI boundary changes.

#### 3.2 Independent review

- Every PR is reviewed by someone who did not write it (a human, or a separate review agent with a fresh context).
- **Each finding gets a disposition with evidence:**
  - *Confirmed*: fixed in the PR, with the fixing commit.
  - *Refuted*: the file:line, command output, test ticket, or index `edge` query that shows it is not a defect.
  - *Deferred*: an issue link, with the maintainer's agreement.
- No finding is closed with "looks fine". Refutations cite evidence.
- For move PRs the reviewer re-runs the move audit (§3.4) and checks its report instead of reading moved bodies.

#### 3.3 Validation matrix

| Check | Pre-work PR (Logic) | Access PR | Move PR | App-touching (any PR changing `RepoPromptApp` sources) | Wave exit |
| --- | --- | --- | --- | --- | --- |
| `make guardrails` (incl. §9 runtime identity, ratchets) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Move audit (§3.4) | — | ✓ | ✓ | — | — |
| `make dev-swift-build PRODUCT=all` (both products) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Owning module tests, `dev-test MODULE=<T>Tests` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dependents' tests (focused `FILTER` on consumers) | ✓ | ✓ | ✓ | ✓ | — |
| Full suite, `make dev-test` (test count equals before, 0 failures) | If app-touching | ✓ | ✓ | ✓ | ✓ |
| `ModularizationCompatibilityGoldenTests` plus the P0.6 checklist (6 items) | If the moved code has identity sites | ✓ | ✓ | ✓ | ✓ |
| `make dev-lint` | ✓ | ✓ | ✓ | ✓ | ✓ |
| Index `report` (wrong-way, SCC) recorded in the ledger | — | — | ✓ | — | ✓ |
| Non-disruptive live smoke, `make dev-smoke` | MCP, agent, or packaging slices | — | MCP, agent, or packaging slices | — | ✓ |
| Release build plus Repo Bench | Hot-path slices (W3, W5) | — | Hot-path slices | — | ✓ |
| Before/after timings (edit→owning test, app incremental, peak RSS) | — | — | ✓ | — | ✓ |

**P0.6 compatibility checklist** (ledger §"Slice checklist"), restated:
1. Guardrails section 9 passes. A new app-only target that holds `Bundle.main` code is added to `bundle_main_allowed_roots`; CLI-linked targets never are.
2. The goldens pass and move with their types, literals unchanged.
3. Re-run the three scan commands on the moved files. Any new sort, equality, or persistence use of `String(reflecting:)`, `String(describing:)` of a type, or `#fileID` needs a golden or an explicit key.
4. A moved error whose `NSError` domain is compared or persisted declares `CustomNSError.errorDomain`.
5. Moving `Bundle.main` or `UserDefaults.standard` readers into a CLI-linked target is a semantic PR of its own.
6. Update the inventory rows.

#### 3.4 Byte-identical move audit (reusable script, added in P1-a)

`Scripts/modularization_move_audit.py --base origin/main [--head HEAD] [--json out.json]`, with tests in `Scripts/test_modularization_move_audit.py` (run by `make conductor-selftest`). It fails a move or access PR unless every check passes.

1. **Rename report.** It runs `git diff --name-status -M100% <base>...<head>` and `git diff -M50% --stat`, then lists every moved file with git's similarity percentage. `R100` files are byte-identical by definition. Any `R<100` or `D`+`A` pair goes to check 2.
2. **Normalized content hash.** For each pair, it normalizes both sides and requires equal SHA-256. The normalization:
   - removes access-modifier keywords (`open`, `public`, `package`, `internal`) from declaration heads, only where they are the sole difference on that line;
   - drops `import` lines, compared separately against the allowlist (new first-party module imports only);
   - leaves whitespace untouched, so formatting is not hidden.
3. **Line-class diff.** For every *modified, non-moved* Swift file, each `git diff -U0` hunk line must be an access-modifier-only change or an added or removed first-party `import`.
4. **Allowed non-Swift files.** `Package.swift`, `Scripts/modularization/modules.json`, `docs/architecture/modules.md`, `source_layout_guardrails.sh`, the ledger, the conductor module index, and `Scripts/generate_xcode_workspace.py`.
5. **Discovery parity.** Given `--tests-before N --tests-after M` (from full-suite tickets), it requires N = M.
6. **Output.** A human report plus JSON (manifest, similarity, hashes, violations) pasted into the ledger. Exit 1 on any violation.

Pre-work PRs are not audited by this script. They get normal review, because they are *meant* to change code.

---

### 4. Risks and mitigations

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | **God-file decomposition changes ordering or cancellation semantics** (`WorkspaceFileContextStore`, `MCPConnectionManager`, `AgentModeViewModel`, `GitService`). Splitting a class can reorder `await` points, drop a `Task` cancellation link, or break CAS and generation checks | Split in place first, one responsibility per PR, with the existing tests on every PR. Publish a **split map** in the ledger before the first PR: responsibilities, the actor or queue each runs on, and the cancellation and ordering invariants each must keep. Add a characterization test for each invariant *before* moving the code that holds it. Each split PR is reviewed for ordering and cancellation specifically. Order splits so that pure, stateless helpers go first and stateful coordinators last. Never combine a split with a move |
| R2 | **Concurrency diagnostics at new module boundaries.** Crossing a module changes `Sendable` inference, isolation, and conformance usability (plan §3.7). A 44-diagnostic surprise can blow the one-day budget | Before the move, count new diagnostics by building the candidate target from a throwaway manifest in a `--scratch` measurement path during pre-work. Fix them in pre-work. Record the mode and escape hatches in the concurrency ledger (ADR-09). New targets use the package default mode; default `MainActor` only for UI-only targets |
| R3 | **Merge churn with high-velocity `main`.** Moves conflict with feature PRs in the same files. The app grew 3,995 lines in one day of merges [M], and the headless branch diverges further with every move | Move PRs are scripted and replayed, not rebased by hand. Announce a short merge window for each boundary-changing slice. Keep each move PR to one target so conflicts are local. The move manifest doubles as a path map for in-flight branches and the future headless port |
| R4 | **Approval overhead and heavy-slot contention** seen so far: 35-min heavy-slot waits and 22-min full suites (P0.3, S14 [L]); 930-s SwiftFormat lint in a fresh worktree; the installer-test flake in `conductor-selftest`; permission prompts per tool call; up to 5.5 GB per `.build/swiftbuild` scratch | Prefer module-scoped validation (`dev-test MODULE=`) and run the full suite once per PR, not per iteration. Land admission v2 (P1-f) before running 3 worktrees. Batch approvals: one reviewed plan per slice, with pre-approved command classes (`conductor` build and test, guardrails, audit). Seed format-tool caches across worktrees (a P0.1 follow-up). Schedule full suites off-peak. Cap parallel worktrees (D5) |
| R5 | **Runtime identity changes silently** (bundles, type names, singletons) | P0.6 checklist, guardrail section 9, goldens, no-duplicate-image rule, release smoke check at wave exit |
| R6 | **Release performance regressions** from lost cross-module specialization | Release build plus Repo Bench for W3 and W5 slices; `@inlinable` only on measured paths |
| R7 | **App share regrows** from feature work during the program | "New files for a family with a module go in that module" guardrail (P1-b); per-wave app-lines ceiling (§1.3) |
| R8 | **Stale index misleads slice sizing** (the 17-file case: a touched file with identical content keeps its old unit, so the mtime check reports it stale) | P1-d switches freshness to source content hashes, which the tool already records. Until then, cross-check sizes with text counts |
| R9 | **Headless port cost grows** as the files it touched move (the branch touched MCP CLI 15 files, DomainRuntime 25, VCS 10, FileSystem 8, WindowTools 6, WorkspaceContext 6 [M, `git diff --stat`]) | Plug-in notes at each seam; move manifests as a path map; DomainRuntime not reshaped. The port-vs-rebuild decision is explicitly deferred (D9) |
| R10 | **Program stalls mid-way** | Each wave is independently valuable; ratchets prevent regression; the catalog is the source of truth |

---

### 5. Decisions you need to make

| # | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | **ADR-08 timing** (admission v2, cross-worktree caching) | (a) Before W1-rest; (b) with W2, before a third worktree; (c) after W3 | **(b)** Admission v2 (P1-f) lands before any 3-worktree operation. Caching (§5.5) stays gated on correctness evidence, not on a date |
| D2 | **P1 tooling before or alongside W1** | (a) All of P1 first (≈ 2–3 weeks); (b) P1-a/b/c/d first (≈ 4–6 agent-days), with P1-e/f/g alongside W1–W2; (c) fully alongside | **(b)** The move audit, import check, `dev-test MODULE=`, and index freshness are needed by the first move. CI build-once and codemods are not |
| D3 | **Swift Testing policy** | (a) Allowed for new tests in extracted modules; (b) default for new tests there; (c) XCTest only | **(a)** The runner supports it on the module path [L]. No bulk conversion (plan non-goal) |
| D4 | **App-share target** | ≤ 10% (≈ 74k, composition only); ≤ 20% (feature UIs may stay); ≤ 30% (stop after W6) | **≤ 10%** as the program target, with a checkpoint at M3 (≈ 25–30%) to decide whether W7's remaining UI splits pay back |
| D5 | **Parallel worktrees** | 1, 2, or 3 | **2** until admission v2, then up to 3. Only one may be on the critical path, and no two slices may touch the same god file |
| D6 | **When to gate tracked ratchets** | Per §1.3 | Gate `tests_testable_import_app_files` and `app_files_over_2000_lines` in P1-b; the index and type-check gates after P1-e |
| D7 | **Codemod toolkit (P1-g) before W3,** or diagnostics-driven manual access lifting | — | Build it before W3-4 and W6-1, where 50+ consumer files and 100+ access changes per PR make manual edits error-prone. W1–W2 go manual |
| D8 | **Revise M1** | Keep "≤ 70% after W1" or adopt "≤ 85% after W1, ≈ 64% after W3" | Adopt the revision; ≤ 70% needs ≈ 136k lines moved |
| D9 | **Headless** | Keep `7eaf24b2` frozen until W7 exits, then decide port vs rebuild | Confirm. The plug-in notes keep a port viable. No headless work is scheduled here |
| D10 | **Merge windows** | Announce boundary-changing moves on a fixed cadence (for example, two days a week) | Yes, for W3-4, W5-4, and W6-4 |

---

### Appendix: measurement notes

- **[M] commands:** `python3 Scripts/modularization_metrics.py report --details`; `python3 Scripts/modularization_index_graph.py dump` then `report --top 40` on the index after conductor tickets `e7b25e19` (no-op, 22 s) and `7da84fad` (2 min 14 s); per-folder `find … | wc -l` over `Sources/RepoPrompt` and `Tests/RepoPromptTests`; `grep -rl` for `.shared` accessors and `@testable` imports.
- **Index caveat:** 17 of 1,160 files are stale in the index; slice sizes for those files are from text measurement. They are the #1108/#1109-touched files plus a few SessionLinks, Oracle, and VCS files. They recompiled with identical content, and their units were not rewritten.
- **Not re-run for this plan:** `readiness` for the unsampled candidate sets (W1-2, W1-4, W1-6, W1-7, W1-8, and all of W2–W7). Their blocker counts are estimates, and the first step of each slice (plan §7 step 1) produces them.
- **Top index wrong-way targets now** (edges): `FontPreset` 92, `FontScaleManager` 77, `WindowState` 54, `AgentRuntimeProviderService` 43, `AgentModeViewModel` 43, `AppNotifications` 39, `AgentModePerfDiagnostics` 39, `WorkspaceModel` 37, `AgentTabSession` 36, `ACPAgentProvider` 35. The top 20 hold 53% of edges and the top 40 hold 68%. This matches P0.2.
