# Phase 6 — Factual Prompt Projection and Accounting

**Date:** 2026-06-21
**Implementation base:** `33b32e47d55412f339a9ee6b75a02072c169c720`
**Status:** complete
**Disposition:** **GO**

## Scope

Phase 6 moves factual workspace capture, logical projection, tree/codemap/content
rendering, slice assembly, and token accounting into `RepoPromptCore`. The app
retains Git/review capture and authorization, construction-time provider choice,
selected/complete fallback, prompt envelopes, presentation, and next-launch
legacy rollback. Phase 7 runtime routing and Phase 8 standalone headless behavior
remain unchanged.

## Implemented boundary

- `PromptFactualCaptureRequest` contains frozen selection/options, an authorized
  capability-free artifact batch, and an immutable path projection.
- `PromptFactualContextCaptureService` awaits the admitted applied-ingress cut,
  captures catalog/codemap/root-lifetime identity, performs validated content
  reads, renders and accounts from one captured codemap bundle, then validates
  generation and worktree lifetime again before returning.
- Missing validated worktrees, stale generations, malformed frozen artifacts,
  cancellation, not-ready providers, and closed sessions return typed failures.
  Core never discovers Git authority or invokes an app Git provider.
- `RepoPromptCoreSessionHandle` and `LegacyWorkspaceSessionBackend` validate the
  exact Phase 5 admission before and after capture. MCP propagates its TaskLocal
  admission; UI callers admit once at provider entry.
- `CorePromptFactualContextProvider` or `LegacyPromptFactualContextProvider` is
  constructed in the already-selected Phase 5 branch and bound once through a
  fail-closed deferred provider. The inactive adapter is not constructed.
- `PromptContextPreAssemblyService` owns app artifact authorization, frozen DTO
  validation, selected-provider delegation, and once-only Git fallback.
  `PromptPackagingService` performs envelopes only.
- Clipboard, chat, headless-plan, MCP workspace/selection export, Agent export,
  Context Builder, and persistent token recount all use the construction-selected
  factual provider. Capture failure aborts output and preserves the pasteboard or
  last valid token display.

## Privacy and dependency invariants

- Core prompt sources contain no `VCSService`, `GitDiffSnapshotStore`, app Git
  capability, automatic-review request, provider closure, SwiftUI, or AppKit.
- Factual result/presentation values contain logical display paths, safe artifact
  aliases, rendered bytes, IDs, generations, and counts only. No physical path is
  present in factual result models or diagnostics.
- A bound-path projection miss is typed invalid input; renderers never fall back
  to the physical worktree path. Missing-worktree diagnostics expose only the
  failure category.
- The selected-diff physical path list is an internal package-scoped app fallback
  handoff. It is never returned by presentation, MCP DTO, diagnostics, or token
  output.
- Authorized artifact aliases reject absolute, tilde, backslash, control-character,
  empty-component, `.` and `..` forms before Core rendering.

## Review corrections

The sole completed manually curated Oracle review used review chat
`untitled-chat-235D5B` over deep Git snapshot `2026-06-21/2232` (71 changed
files). It found three P1 parity/privacy defects, all corrected before the final
ladder:

1. readable MAP artifacts now participate in entry summaries instead of being
   suppressed from MAP-only context;
2. MAP artifacts render before ordinary selected files, preserving the prior
   artifact-first ordering;
3. artifact aliases use one central safe-relative validator and reject control
   characters as well as path-escape forms.

The review also noted that an explicit request root scope is superseded by a
frozen projection. This is intentional: the projection is the already-validated
exact admitted scope and prevents later scope widening.

## Test ownership and deterministic stabilization

- `PromptContextAccountingServiceTests` moved physically from root to
  `RepoPromptCoreTests`: ten methods and eleven scenarios are preserved.
- `PromptFactualContextCaptureServiceTests` cover missing-worktree fail-closed,
  logicalization/privacy, generation discard, authorized map/patch ordering and
  accounting, and hostile alias rejection.
- Root suites retain authorization/fallback/envelope/presentation ownership and
  construction-provider assertions.
- The former full-root `AsyncLimiterTests` stall was branch-related test harness
  nondeterminism, not a limiter deadlock. `LimiterSnapshotSignal` delivered actor
  state through unordered unstructured tasks, so an older snapshot could regress
  the one-shot signal permanently. The fixture now records synchronously under
  `NSLock`; the exact stalled test passed twice before the authoritative root run.
- Other full-order fixtures were made deterministic without changing product
  policy: prompt fixtures use bounded stale-generation retries, published Git
  selection waits for both canonical artifacts, and the window-close fixture
  repeatedly establishes its two-subscriber precondition while provider
  notifications settle.
- The opt-in search benchmark marker was removed before the authoritative root
  run. Diagnostic benchmark execution is intentionally not part of the routine
  root gate.

## Validation evidence

| Lane | Ticket / command | Result |
| --- | --- | --- |
| Core factual capture after Oracle fixes | `8abf30de-f0d3-4c7f-91c3-7bb93cc3a7e2` | 4 pass |
| Root preassembly/orchestration | `4f0dc11a-cb4a-4242-b7e6-639def7c3833` | 10 pass |
| Canonical prompt packaging | `a1d62bc2-a2d6-41a6-8dd0-0a1b1e42eecf` | 3 pass |
| AsyncLimiter former stall exact repeats | `ff4401d9`; `5cb22125` | pass twice |
| Window-close stabilized repeats | `921458df-b94f-4eb7-8bac-a4817ecbe338`; `30c5c31c-c9a1-457a-b44b-a1eba321d552` | pass twice |
| Authoritative full root with 300 s stall detector | `b41e17e4-7f85-4792-85b3-851092f8fe16` | pass; no stall |
| Full Core | `0ed44f33-405e-4b1f-a9e2-8a79cc955ea5` | pass |
| Full CoreMacOS / POSIX / provider | `06dbee85-5087-431f-bfb2-71effdd3b12e`; `0609c7a9-7fa4-4a63-8739-0cc6a37fa00c`; `d2c73992-25bd-494a-afbb-da997b98fd5b` | pass |
| Final format / lint | `2250aad6-9110-424e-b9f4-7e964ee35ca4`; `c74b2d98-88c9-4b13-8be7-efe070094b3c` | 0 formatted; 0 violations |
| All Swift products | `9141b276-716b-4d17-a3b8-06f269b4d6bf` | app, MCP, headless pass |
| Signed non-launching debug package | `01f59e49-0b5c-4e44-b266-2494212a6118` | pass, including signature/layout/helper smoke |
| Xcode generator / validation | `make xcode-generator-test`; `make xcode-validate` | 23 pass; workspace list validated |
| Exact authoritative lists / ledger | `verify-ledger` | 1,920 IDs / 2,469 scenarios: Core 249/314, CoreMacOS 34/34, POSIX 3/3, provider 7/16, root 1,627/2,102 |
| Core-isolation negative fixtures | `python3 Scripts/test_core_isolation_guardrails.py` | 20 pass |
| Final structural guard | `bc760572-544f-4f2d-9f14-a9b0d586bce5` | pass |
| Core authority/privacy token scans and `git diff --check` | direct final audit | pass; only package-internal slice lookup references a physical location |

Three comparable Core factual capture/render/accounting samples were 0.006,
0.006, and 0.007 seconds (tickets `3c1af909`, `c2c3b6a0`, and `f2ae4eb4`),
median 0.006 seconds. The result-only path and authority scans are recorded as
structural evidence, not a performance threshold.

## Packaged live evidence

With explicit user approval, coordinated relaunch
`d2935afa-6bea-4e42-9de7-598892e4d9df` rebuilt, signed, packaged, replaced the
prior app, and launched matching PID `45446`. Generic app-proxy smoke
`2e75fe6d-c5b5-4478-891d-b0db6cc4452b` passed.

The persisted `phase6-live-review` workspace then selected three Phase 6 files.
Live `workspace_context` returned the exact selected contents and logical tree,
10,199 total tokens (10,072 selection plus 127 tree), and reported:

`Token accounting: fresh from construction_selected_factual_provider`

Coordinated stop `e40c7c79-79cd-4d89-88cd-b36038efc73d` completed. App status
`7c4875d4-7e18-4179-80f8-06b3cd157223` reported no matching debug PIDs; the
repository executable-identity helper independently returned zero exact matches
and PID `45446` was absent.

## Rollback

`coreIsolation.workspaceBackend=legacy` remains next-launch only through Phase 8.
It selects the legacy factual adapter in the same immutable construction branch.
Both providers execute the same Core factual renderer/accounting path. No
persisted bytes, live backend switch, writable shadow, or second parity query was
added.

## Gate

**Final disposition: GO.** Deterministic, full-root, platform, provider, style,
ledger, structural, privacy, product, signed-package, curated Oracle review, and
approved live lifecycle gates are green. No mixed-generation result, Core Git
authority, physical-path presentation, missing-worktree fallback, provider
reacquisition, duplicate Git fallback, inactive adapter construction, or Phase 7+
scope was accepted. Changes remain uncommitted.
