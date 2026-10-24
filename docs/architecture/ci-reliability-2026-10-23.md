# CI history audit — RepoPrompt CE, 2026-10-23

## Scope and confidence

This audit inventories **every retained workflow whose latest conclusion was failure before 2026-10-01** and deeply inspects the **2026-10-01 through 2026-10-22 workflow-creation window**, including all attempts of failed/cancelled workflows and successful workflows that were rerun. October 23 spot checks, including PR #1463, are discussed separately below and are not added to these totals.

All date boundaries here are UTC API `created_at`; some attempts of these runs executed on October 23. Latest conclusions can change while work is ongoing. These are observed snapshots, not an immutable failure-rate study.

| Coverage | Count |
| --- | ---: |
| Failed latest-conclusion runs retained before October 1 | 1,233 |
| Failed latest-conclusion October 1–22 runs | 283 |
| Cancelled latest-conclusion October 1–22 runs | 126 |
| Successful October 1–22 runs inventoried | 1,354 |
| Successful runs with multiple attempts | 54 |
| Runs whose complete available job-attempt history was retrieved | 463 |
| Jobs retrieved across those run histories | 2,826 |
| Failed jobs after excluding aggregate prerequisite gates | 427 |
| Failed-job logs successfully retrieved | 416 |
| Log retrieval gaps | 11 |
| Distinct failed XCTest method identities observed | 204 |
| Failed test jobs followed by a successful job of the same name on the same workflow run/head | 53, across 45 runs |

Of the 54 successful rerun workflows, 51 contain a prior nonaggregate job failure; three contain no such failure and should not be called rescued failures. **77 of the 126 cancelled workflows contain failed jobs**, usually matrix fail-fast/earlier attempts. Counting all cancellations as benign supersession would hide useful evidence.

The 11 unavailable logs were nine Sentry job transport-closed responses, one inaccessible/deleted static-build blob, and one rescued root-shard log whose retrieval also failed. Job/step metadata is still available. Before October 1, this audit inventories all failures but does **not** claim to have read 1,233 old logs.

### Older failure census

Retained failed runs span May 31 through September 30:

| Month | Failed latest-conclusion workflows |
| --- | ---: |
| May 2026 | 36 |
| June 2026 | 202 |
| July 2026 | 450 |
| August 2026 | 338 |
| September 2026 | 207 |

Older workflows: CI 945, Publish Tip 189, Release Candidate 35, Xcode Workspace Validation 16, Promote Release 11, Publish Release 10, assorted one-off workflows 27. Older total conclusions also include 322 cancelled and 2,500 successful runs. Separate workflow queries returned zero `timed_out` conclusions before October and during October 1–22; individual command/job timeouts still appear inside failed workflows. These are workflow counts, not flaky-test counts or comparable monthly rates.

## Findings that matter to the repair

### 1. The apparent green history contains repeated unchanged-head failures

A green latest conclusion erases the failure from an ordinary `status=failure` query. This was material: 60 failed nonaggregate jobs were hidden behind 54 eventually green workflow runs.

Examples:

| Contract | Failed job | Later successful same-run job | Interpretation |
| --- | --- | --- | --- |
| New-window catalog baseline; failures move between methods | [117220473454](https://github.com/repoprompt/repoprompt-ce/actions/runs/38971275011/job/117220473454), then [117227911302](https://github.com/repoprompt/repoprompt-ce/actions/runs/38971275011/job/117227911302) | [117230458461](https://github.com/repoprompt/repoprompt-ce/actions/runs/38971275011/job/117230458461), attempt 3 | Strong nondeterminism evidence; first untouched-window timeout, then lifecycle-claims timeout on the same head |
| Distinct-workspace admission persistence | [117187672034](https://github.com/repoprompt/repoprompt-ce/actions/runs/38960314885/job/117187672034) | [117192387601](https://github.com/repoprompt/repoprompt-ce/actions/runs/38960314885/job/117192387601), attempt 2 | `local_save_retry_exhausted` without source changes |
| Transcript restoration | [119316903390](https://github.com/repoprompt/repoprompt-ce/actions/runs/39622721315/job/119316903390) | [119337541684](https://github.com/repoprompt/repoprompt-ce/actions/runs/39622721315/job/119337541684), attempt 3 | Unexpected `CancellationError()` in GitViewModel while restoring |
| Transcript outgoing snapshot | [119195514736](https://github.com/repoprompt/repoprompt-ce/actions/runs/39588387268/job/119195514736) | [119266294376](https://github.com/repoprompt/repoprompt-ce/actions/runs/39588387268/job/119266294376) | Fixture asserts outgoing rows before asynchronous projection |
| Jev readiness UI projection | [120161844446](https://github.com/repoprompt/repoprompt-ce/actions/runs/39873810960/job/120161844446) | [120389700009](https://github.com/repoprompt/repoprompt-ce/actions/runs/39873810960/job/120389700009) | Bootstrap return does not imply readiness stream delivered |
| Queued oversight message delivery | [119830223202](https://github.com/repoprompt/repoprompt-ce/actions/runs/39776358070/job/119830223202) | [119837157251](https://github.com/repoprompt/repoprompt-ce/actions/runs/39776358070/job/119837157251) | Test observes send-attempt counter before durable delivery receipt |
| Content-read cancellation (historical) | [113724369440](https://github.com/repoprompt/repoprompt-ce/actions/runs/37899038348/job/113724369440) | [113725869283](https://github.com/repoprompt/repoprompt-ce/actions/runs/37899038348/job/113725869283) | Yield-count polling; later fixed by #1302 |

A successful retry establishes nondeterminism at that tested SHA/environment boundary. It does not establish whether the defect is exclusively in a test, exclusively in product code, or both. Product race fixes must be proven separately.

### 2. The observed clusters require both lifecycle analysis and tested-tree attribution

The top suite counts below count each failed job once per suite; a job can contain several failed methods. They include failures later rescued by reruns.

| Suite | Failed jobs | Current disposition |
| --- | ---: | --- |
| NewWindowInitialSelectionTests | 44 | Ongoing catalog/projection/lifecycle cluster. #1463 repairs one lost catalog handoff but does not prove all paths fixed. |
| ContentReadCancellationTests | 29 | Historical yield-budget cluster; no later occurrence found in this window after #1302 merged October 10. |
| AgentTranscriptRestorationLifecycleTests | 14 | Ongoing unexpected cancellation and fixture lifetime/cleanup issues. |
| AgentSessionLinkCodexPromptAdapterTests | 13 | Historical fake-controller lifetime defect, fixed by #1168 on October 1. October 6 failures executed an older synthetic merge tree without the fix, not current main. |
| ACPPermissionScopeTests | 10 | Concentrated October 4 stale synthetic-provider-launch fixtures, not evidence of ten distinct flaky algorithms. |
| AgentSessionLaneFirstSaveTests | 9 | Concentrated October 10 authority/bootstrap regression wave; distinguish intentional contract failures from flakes. |
| AgentRunMCPToolServiceSteerResumeTests | 6 | Mixed real lifecycle behavior and timing; latest failures October 21. |
| ContextBuilderMultiRootDiscoveryTests | 6 | Shared XCTest PID/bootstrap ambiguity addressed by #1390. |
| ProviderTransportActivityTests | 6 | October 9 cancellation race; five attempts on one run remained failed. |
| ConcurrentSameWorkspaceAgentRunAdmissionTests | 5 | Four distinct-workspace failures, plus other methods; residual persistence failure remains open. |
| AgentTranscriptPaneSnapshotPublicationTests | 5 | Outgoing snapshot precondition races asynchronous publication; #1438 is already merged on the audited base. |
| WorkspaceSeededPublicationAuthorityRegressionTests | 5 | Helper prerequisites fail before the intended second-commit deadlock check: live FSEvents receipt rejection on October 5/9/22 and a bounded Git discovery timeout on October 7; October 1 inner detail is truncated. #1185's exact-batch replay repair does not remove the broader live-witness dependency. |
| AgentTaskRouterRuntimeTests | 4 | Production bootstrap vs readiness stream; #1463-derived observer wait addresses the identified race. |

Specific frequent methods: new-window system-identity selection 17 jobs; content-read final materialization cancellation 17; new-window production lifecycle claims 12; transcript same-tab rebinding 8.

The new-window catalog timeout appears in many unrelated PRs and multiple method names. This pattern matches a shared observer/publication defect rather than each PR independently breaking workspace choice. Still, #1445 is diagnostics only; its existence must not be presented as a completed fix.

The Codex adapter cluster illustrates why a later failure date is insufficient to
declare a fix ineffective. [#1168](https://github.com/repoprompt/repoprompt-ce/pull/1168)
replaces a reused, already-finished fake controller with a fresh controller for
each reconnect, retaining shared dispatch history and exact replay assertions.
The October 6 [failed run](https://github.com/repoprompt/repoprompt-ce/actions/runs/37488629788)
still checked out `f2b15692710605d10ed0c432b9b6dbe03da8e9c0`, whose
[factory returns the old shared controller](https://github.com/repoprompt/repoprompt-ce/blob/f2b15692710605d10ed0c432b9b6dbe03da8e9c0/Tests/RepoPromptTests/AgentMode/SessionLinks/AgentSessionLinkPromptAdapterTests.swift#L333).
[Its history diverges before #1168](https://github.com/repoprompt/repoprompt-ce/compare/c35921b87ff3724510c03af9ac1b602fc4202b97...f2b15692710605d10ed0c432b9b6dbe03da8e9c0).
Always check the tested synthetic merge tree and commit ancestry; rerunning an old
workflow does not incorporate fixes merged since that workflow was created.

The seeded-publication cluster has a different result. The
[October 22 failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/39778810574/job/119835254022)
rejects the creation receipt during the **second preparation**, before the ready
marker and before the lock regression's second pending commit. The witness has
`eventIDRegressed=true`; stream startup, flush/barriers and stable-root checks
succeed, and drop/wrap/root-change flags are false. The complete ordered callback
batches were not retained, so their exact cause cannot be established. The
[executed tree already contains #1185's exact consecutive batch-replay exception](https://github.com/repoprompt/repoprompt-ce/blob/c2c6a1e88ea658665b80be0477dd372448f69479/Sources/RepoPrompt/Infrastructure/VCS/WorkspaceRootCreationReceiptCoordinator.swift#L380).
This is a residual live-receipt prerequisite failure, not observed recurrence of
the second-commit deadlock. `sourceA exists=false` in the caught error reflects
fixture cleanup running before diagnostic construction, not proof that the
repositories disappeared during creation. Socket, decode and simulated disk-full
errors elsewhere in those shard logs belong to other tests.

### 3. Concurrent admission is a known residual product/fixture boundary, not a proven deflake

The existing test `testAgentAdmissionsForDistinctDurableWorkspacesOverlap` predates this October wave. It was introduced in August. First failures in this audit occur October 15:

- [38691108051 / 116285577256](https://github.com/repoprompt/repoprompt-ce/actions/runs/38691108051/job/116285577256), the #1384 development branch: first admission never reaches the test save gate; all six same-workspace starts also reject persistence.
- [38758219790 / 116520912155](https://github.com/repoprompt/repoprompt-ce/actions/runs/38758219790/job/116520912155): both distinct-workspace providers fail to overlap after gates are entered.
- [38960314885 / 117187672034](https://github.com/repoprompt/repoprompt-ce/actions/runs/38960314885/job/117187672034): same-head retry passes; original rejection categorizes `local_save_retry_exhausted`.
- [39843906826 / 120064146118](https://github.com/repoprompt/repoprompt-ce/actions/runs/39843906826/job/120064146118): the same typed rejection remains on October 22.

Relevant source history:

1. [#1384](https://github.com/repoprompt/repoprompt-ce/pull/1384), merged October 15 at 09:33 UTC, moved workspace decode/encode/hash preparation off MainActor. The new suspension exposes mutations arriving while a save capture is outstanding. It also changed the fixture to await an accepted full-document catalog baseline rather than synthetically append a workspace locally.
2. [#1376](https://github.com/repoprompt/repoprompt-ce/pull/1376), merged October 16, adds the explicit test for unchanged codemap republishing and deduplicates unchanged auto/manual codemap lists before their dirty-state subscribers. Its commit history explicitly records that intermittent concurrent-workspace persistence rejection remained unresolved.
3. The fixture starts admission tasks after workspace switching and compose-tab hydration. Workspace switching can publish selected-file and Git-mode updates whose subscribers queue dirty-state updates on the main queue, while document preparation now suspends. The compose-tab loader itself does not publish those values. Deferred subscribers are a plausible remaining writer source, not established causation.
4. Before this repair, only the single-workspace and peer fixtures installed `setWorkspaceSaveConflictHandlerForTesting`. The distinct-runtime fixture now prints the same value-only conflict diagnostics. Earlier failures cannot identify the exact late state-version writer. Gather that evidence rather than increase retry counts or bypass stale-capture validation.
5. Production `retryStaleDomainAuthoritySave` protects full-document lineage, roots, revision, digest, and own-save fences. It permits one additional attempt and deliberately fails when a second current-state conflict occurs. Weakening these fences to green a flaky test risks real stale persistence.

The October 16 intentionally failing codemap regression logs two unchanged-model conflicts (state 2→4→5, writers `markWorkspaceDirty()` then `markWorkspaceDirtyIfActiveTabSnapshotChanged()`) before exhaustion. That is useful historical proof of one fixed cause, but it does not identify the writer for the current distinct-workspace failure.

[Issue #1453](https://github.com/repoprompt/repoprompt-ce/issues/1453) tracks this
exact unresolved distinct-workspace failure. Both save gates entered and opened;
that alone does not establish which request or writer invalidated the capture.

### 4. Infrastructure failures and misleading diagnostics are separate problems

- Actual package resolution failed in three October jobs. [38109729628 / 114382608573](https://github.com/repoprompt/repoprompt-ce/actions/runs/38109729628/job/114382608573) times out after 300 seconds and then raises `PermissionError: Operation not permitted` during process cleanup. [38333827286 / 115089392617](https://github.com/repoprompt/repoprompt-ce/actions/runs/38333827286/job/115089392617) and [37145827837 / 111269440973](https://github.com/repoprompt/repoprompt-ce/actions/runs/37145827837/job/111269440973) exhaust the three bounded resolution attempts.
- Resolver unit tests print intentional `::error::Dependency resolution/download failed...` fixtures directly into workflow output even when the test step succeeds. Example [120116877094](https://github.com/repoprompt/repoprompt-ce/actions/runs/39862630076/job/120116877094) contains those annotations at 22:15, then actually fails the compiler index ratchet at 22:31. Parse job/step conclusions, not every string containing `error`.
- [39440319701 / 120328423401](https://github.com/repoprompt/repoprompt-ce/actions/runs/39440319701/job/120328423401), a third attempt on October 23 of a run created October 20, cannot download `root-build-39440319701`. The subsequent mandatory artifact upload also fails because tests never started. Rerunning old shards without their retained build is inherently insufficient.
- [38246038195 / 114800023279](https://github.com/repoprompt/repoprompt-ce/actions/runs/38246038195/job/114800023279) fails installing gitleaks with HTTP 504; two other jobs fail SwiftFormat download due DNS/connection timeouts. Do not call these XCTest regressions.
- Checkout [36989713264 / 110806971327](https://github.com/repoprompt/repoprompt-ce/actions/runs/36989713264/job/110806971327) records early EOF, connection timeout, and DNS resolution failures before tests; missing-results upload is a secondary symptom.
- Eleven October 18–20 release smoke failed jobs/attempts (six candidate, five signed Tip) predominantly exit 124. These are packaged runtime/readiness failures and separate from PR root-shard flakiness. #1425/1437 release-smoke history should be assessed against current source before declaring them resolved.

### 5. Real contract failures must stay blocking

The audit finds 34 repository-guardrail failures, 29 compiler-index ratchet failures, 15 original plus two rescued build-step failures, and 13 Swift-lint failures in the initial unsuccessful set. These are not blanket evidence that the gates are trash.

Examples include inaccessible `fileprivate` API from a test, missing `try`, missing module imports, changed tool-catalog snapshots, changed schema versions, and explicit coupling-budget increases. One SettingsCore byte fixture on October 21 differs at equal byte length because schema version changed; source now pins version 13. That is a stale contract fixture, not nondeterministic JSON ordering.

Root-shard failure should not wipe healthy build caches. Conversely an unchanged-head compiler failure that passes after re-running must be examined for cache/infrastructure causes, not automatically used to relax type or import gates.

## Why earlier “fixes” did not eliminate the problem

| Change | Actual purpose and limit |
| --- | --- |
| [#705](https://github.com/repoprompt/repoprompt-ce/pull/705), August 2 | Removing a ledger changed discovery/shard order and exposed missing authority setup, a real mutation commit-order gap, and scheduling-dependent codemap tests. Fixed those contracts and aggregated failures, not a universal CI immunity layer. |
| [#899](https://github.com/repoprompt/repoprompt-ce/pull/899), August 29 | Removed bespoke retries/watchdogs and method-level resuscitation, gave suites fresh HOME/TMP/XDG, and separated deterministic PR contracts from integration tests using source-derived timing/host coupling evidence. |
| [#908](https://github.com/repoprompt/repoprompt-ce/pull/908), August 30 | Deleted many integration/timing-dependent tests and support scripts, removed the previous day's test-lane policy, and restored one root lane. The actual merge removes roughly 269,000 lines and leaves a reported 953-test suite. It also restores fail-first-suite behavior and accidentally deletes Sentry privacy tests without deleting their main workflow selector. |
| [#1088](https://github.com/repoprompt/repoprompt-ce/pull/1088), September 28 | Removes unique conductor ticket/environment churn from SwiftPM and directly invokes XCTest after build/discovery. Fixes massive fixed overhead, not app lifecycle races. |
| [#1152](https://github.com/repoprompt/repoprompt-ce/pull/1152), October 1 | Adds exact expected/executed identities, target inventory, cross-shard receipts, bounded dependency retries, warm-VM owning-module parity, and a fail-closed final Style gate. The reviewed root listing is already 4,039 methods; evidence infrastructure improved, while new asynchronous integration tests accumulated. |
| [#1168](https://github.com/repoprompt/repoprompt-ce/pull/1168), October 1 | Gives each fake Codex reconnect a fresh controller and open stream. Fixes the historical auth-recovery replay cluster; later failures on old synthetic merge trees did not contain this repair. |
| [#1177](https://github.com/repoprompt/repoprompt-ce/pull/1177), October 2 | Restores orphaned Sentry privacy coverage exposed by zero-test rejection and turns verified superseded Tip commits into ineligible outcomes. Does not change the actual test-failure semantics. |
| [#1185](https://github.com/repoprompt/repoprompt-ce/pull/1185), October 5 | Accepts only exact replay of the immediately preceding event batch. Keeps real regressions and discontinuities fail-closed, and explicitly does not claim to eliminate every live seeded-publication prerequisite failure. |
| [#1302](https://github.com/repoprompt/repoprompt-ce/pull/1302), October 10 | Replaces 10,000-yield polling with a bounded ContinuousClock wait. 29 ContentReadCancellation failed-job occurrences before this fix; none observed after it in this window. Evidence-backed targeted improvement. |
| [#1390](https://github.com/repoprompt/repoprompt-ce/pull/1390), October 16 | Clears synthetic bootstrap PID affinity after parent routes become authoritative; corrects weekly-vs-five-hour quota fixtures. Stops those specific stale-fixture clusters. It explicitly leaves the catalog checkpoint timeout unresolved. |
| [#1441](https://github.com/repoprompt/repoprompt-ce/pull/1441), open | Preserves a seeded build after successful compilation when tests fail, preventing unconditional cold retry/cache wiping. Still unmerged when inspected; do not claim it already protects main. |
| [#1463](https://github.com/repoprompt/repoprompt-ce/pull/1463), open | Repairs specific readiness-stream and final-catalog-handoff races. It does not cover all historical lifecycle cleanup, queued delivery receipt, process-fixture, or admission persistence failure paths. |

The recurring pattern is a shared production actor/stream lifecycle boundary combined with fixtures that assume an earlier event means a later event has finished. Repeated wholesale test deletion, longer timeouts, or green reruns do not supply that missing ownership proof.

## Repair principles and remaining boundaries

1. Keep every real assertion, zero-test guard, and source/compiled-artifact provenance gate.
2. Await the exact observed outcome each test asserts: applied catalog checkpoint, delivered readiness projection, completed pending-send receipt, settled persistence/teardown, child-exit acknowledgement.
3. Use bounded deadlines only as failure limits, not as the mechanism that orders work.
4. Run remaining isolated suites once after one fails so one run yields a complete diagnostic inventory. Publish no success receipt after any failure.
5. Preserve successful compiled caches on test failures; avoid compiling again merely to roll different scheduling dice.
6. Clean up timed-out dependency subprocess sessions completely before retrying, with ownership verification and fail-closed cleanup failures.
7. Retain build artifacts long enough for permitted reruns and distinguish no-test-start infrastructure failures from absent execution proof.
8. Coalesce superseded main CI work where policy permits; never cancel unrelated PRs or weaken their checks.
9. Mark concurrent-admission and any unproven cancellation origin as remaining diagnosis, not completed fixes. Instrument the exact writer/owner and reproduce the bad interleaving before changing production semantics.

## October 23 checks and changes in this repair

The implementation starts from main `4591aeca31baea3bc96650175b225f4fcb886f79`.
Neither #1463 nor #1446 was merged when the repair began. Their relevant changes
are incorporated here with attribution; their reported earlier local validation
is not evidence for this combined head.

| Boundary | Evidence | Repair and limit |
| --- | --- | --- |
| Readiness publication | [#1463](https://github.com/repoprompt/repoprompt-ce/pull/1463); the unchanged-head Jev failure above | Bootstrap snapshots qualify admission; the ordered stream owns subsequent readiness publication. A ready admission snapshot exits without repeatedly rescheduling bootstrap while the stream is held. Tests gate both orderings and wait for the actual projected readiness. |
| Final catalog preparation | [#1463](https://github.com/repoprompt/repoprompt-ce/pull/1463); [main failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/39925416951/job/120339244748) | A covering manager reconciliation can hand metadata back after the final decode suspension. Exact qualified descendants and a valid full-document baseline are required. Tests preserve newer failures and reject a revoked baseline; no third decode or larger retry budget. |
| Queued oversight delivery | [same-head failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/39776358070/job/119830223202) | Await the completed delivery result, rather than the host's send-entry counter, before asserting removal of the queued message. Exact send count and delivery assertions remain. |
| Scope-decision fixture ownership | `testScopeDecisionWaitsForActiveTurnAndResumesWithoutConsumingDraft`, recurring October 16–21 | Explicitly retain the fixture's local `DelegationScopeRuntime` until the delivery assertions finish. Its scheduled tasks and observer hold weak references, so its last direct use at `approve()` does not own it across later awaits. This is a source-supported fixture lifetime repair, not proof of the historical failure's sole cause. |
| Unchanged Git-mode publication | Workspace switching can reassign the current `gitDiffInclusionMode`; its dirty subscriber previously treated every publication as a mutation | Deduplicate identical modes before scheduling the dirty callback. Add admission regressions that inject unchanged mode publications at every save-preparation boundary, plus a real mode change that must still invalidate the first capture and require a fresh one. This repairs a concrete no-op invalidation path; historical #1453 logs do not prove it was their remaining writer. |
| Approval subscriptions | [extra diagnostic snapshot](https://github.com/repoprompt/repoprompt-ce/actions/runs/39845950864/job/120073930009) | Diagnostics legitimately republish the full MCP snapshot. The test injects such a publication, collapses only adjacent identical approval identities, and still asserts the exact approval-generation/client transition sequence and stale-click behavior. |
| Snooze cancellation fixture | [#1446](https://github.com/repoprompt/repoprompt-ce/pull/1446) | Replace yield-count assumptions with exact clock-deadline observation. Join the cancelled predecessor after proving it resumed; assert it cannot rearm or expire its replacement. Retire the test clock's tasks during cleanup. |
| Restoration fixture lifetime | [#1445](https://github.com/repoprompt/repoprompt-ce/pull/1445), diagnostic-only | Track the existing workspace-listener flush tasks. Fixture cleanup joins flushes, in-flight saves, and cancelled debounce tasks, including successors scheduled during a flush, before deleting storage or resetting shared services. A gated real-listener regression covers normal and throwing fixture bodies. This addresses demonstrated late writes; the original unexpected CancellationError's provenance remains unproven. |
| Grok cancellation fixture | [#1463 shard 4](https://github.com/repoprompt/repoprompt-ce/actions/runs/39927333232/job/120338302666) | Open the FIFO and install the trap before publishing readiness, then use the shell's builtin read, avoiding a post-ready shell fork/wait window. Keep the physical-finalization, final-write, session-removal, and neighbor-preservation assertions. This is a newly observed failure, absent from the 416 retrieved historical logs. Linux fixture exercise is not proof of Darwin behavior. |
| Resolver child ownership | [Sentry dependency failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/39935261810/job/120376186447), [second run](https://github.com/repoprompt/repoprompt-ce/actions/runs/39929803435/job/120341260088) | A timed-out SwiftPM launcher can leave Git children in different process groups. Cleanup now inventories and stops every live group within that attempt's private session, including after nonzero launcher exit, before retrying. Signal grace begins after the first signals, so a slow inventory cannot consume the grace before cleanup can confirm exit. A real subprocess regression reproduced a surviving child with the old cleanup; the new test also protects an unrelated session. The observed later Git working-directory errors are consistent with overlap, not definitive proof of every download failure's cause. |
| Expired executable on rerun | [missing root build](https://github.com/repoprompt/repoprompt-ce/actions/runs/39440319701/job/120328423401) | Root build artifacts now last seven days, matching execution receipts, instead of one day. Expired runs still require rebuilding; download errors are not test failures. |
| Incomplete failure inventory | Existing runner returned after the first failed isolated suite | Attempt every assigned suite once. Preserve failure exit status, refuse a success receipt after any failure, and verify exact identities/counts as before. Later suites become visible in the first failed run. |
| Misleading gate annotations and wasted work | Intentional resolver self-test error strings; opaque aggregate Style failure; queued main commits | Capture expected self-test output, show prerequisite outcomes in the final Style summary, and cancel superseded main CI/Sentry work per ref. Release workflow policy and mandatory gates stay intact. |

The [#1463 shard 3 run](https://github.com/repoprompt/repoprompt-ce/actions/runs/39927333232/job/120338302885)
completed successfully on October 23. It passed both recently failing new-window
methods and the new final-handoff regressions. Its shard 4 failed the Grok fixture
listed above. That provides one positive native run of the original catalog
patch, not proof that every related failure is eliminated or that this combined
repair has passed.

Real failures remain blocking. For example, [this index-ratchet failure](https://github.com/repoprompt/repoprompt-ce/actions/runs/39862630076/job/120116877094)
reports `index_wrong_way_file_edges 1363 > 1360`; it must be fixed by its owning
change, not by raising the budget in a CI repair. Recent formatting failures also
identify actual drift. No test is removed or quarantined here, no assertion is
retried until green, and no architecture or coverage threshold is relaxed.

### Validation and follow-up

The editing environment is Linux, so it cannot compile or run the macOS AppKit
root package. The PR must record current-head hosted macOS results separately
from Linux tooling checks and prior PR authors' results. The required hosted run
must compile the combined changes, run all four root shards, and complete the
final coverage union and Style gate.

The focused regression boundaries are the CI runner/receipt and resolver
self-tests, the two router ordering tests, final catalog handoff tests, the
restoration real-listener teardown test, approval transition test, snooze
cancellation/deadline tests, queued oversight delivery, and Grok physical
cancellation cleanup. Keep the exact command results and any unavailable
platform validation in the PR description.

Do not close the concurrent-admission persistence diagnosis or unexpected
restoration cancellation diagnosis merely because one run is green. The
additional conflict diagnostics are intended to identify the remaining writer.

The seeded-publication helper remains a concrete fixture follow-up. Its lock
regression from [#1003](https://github.com/repoprompt/repoprompt-ce/pull/1003)
must still execute both real pending seeded-root commits, with the first root's
current authority fence and all-loaded cache already installed. The existing
`WorkspaceRootCreationWitnessFSEventsBackend` can supply controlled witness
delivery, but `GitService` does not expose its coordinator as an initializer
dependency yet. That narrow dependency injection would avoid rewriting a rejected
receipt. Its backend must preserve a valid real journal cut, because the Store
uses the receipt's ending event ID to start actual watcher replay. Validate that
the original lock mutant still fails and current code completes on macOS before
calling the fixture deterministic; retain live receipt regression/drop/wrap/replay
and fallback coverage. This does not diagnose the separate source-admission Git
timeout. No receipt validation or helper assertion is weakened in this PR.

[PR #1441](https://github.com/repoprompt/repoprompt-ce/pull/1441) separately repairs
conductor's local seeded-cache invalidation/cold-test retry behavior; that change
is not included here. Release smoke timeouts and provider-specific historical
clusters also remain separate unless their current failure is reproduced and
traced to an exact cause.
