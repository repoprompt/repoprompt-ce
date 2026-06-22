# Behavior, Hazard, Test, and Performance Contract

**Frozen base:** `8e42951159c9f1d6973a4538a309908baacdb371`
**Characterization date:** 2026-06-21

Current behavior wins over historical snapshots. Oracles below protect observable
behavior, not source shape. Future-only mechanisms are not represented by
placeholder tests: their exact future oracle is frozen and assigned to the owning
phase.

## Authoritative test census

| Census | Count | Sorted exact-ID SHA-256 | Evidence |
| --- | ---: | --- | --- |
| Root before Phase 0 test addition | 1,866 | `d9e2dd3882ecd2e2f0ac8245fc9e733d06f9f58635a5c2aff3c59bef1a74207d` | `make dev-test-list`, ticket `3892b8d4-527b-4a2d-8616-f7954ff0206c` |
| Provider | 7 | `af8669b714868d718314b12d53a2e4d3980e040a2cd4ede26d28d17d03368948` | `make dev-provider-test-list`, ticket `c19e1250-4d9d-4a77-8d76-9131f6bd2f9a` |
| Root after Phase 0 test addition | 1,867 | `d1217f6703a581562fb47a986bb2c0a8f4ee67b20ff40a41d395856d8c77d9e2` | ticket `5fb563a0-1917-4433-aeec-4c85bf31885c`; exit 0 |

The pre-change curated ledger had 1,873 rows: 1,866 root and 7 provider
methods, with 2,396 root and 16 provider scenarios (2,412 total), SHA-256
`578c987ad16318697f4727b816db7201ebccf507ed9b3a4aa657642fd12faf25`.
Phase 0 adds one root method with three scenarios; it renames, consolidates, and
removes no IDs. The final ledger has 1,874 rows (1,867 root, 7 provider) and
2,415 scenarios (2,399 root, 16 provider), SHA-256
`79f8f4240ac313f7ae23c0363e0eaeb99ead7d0287a6ea53fb04ab1d5db12404`.

The complete sorted authoritative lists are preserved by the daemon logs and the
hashes above. Exact boundary-moving IDs are also recorded in
`migration-ledger.tsv`; source text was not used as an executable census.

## Existing app/proxy package identity

The reconstructed standalone product must not alter these current identities:

- app bundle/executable/display: `RepoPrompt.app` / `RepoPrompt` /
  `RepoPrompt CE`;
- release bundle identifier: `com.pvncher.repoprompt.ce`; debug identifier:
  `com.pvncher.repoprompt.ce.debug`;
- embedded helper: `RepoPrompt.app/Contents/MacOS/repoprompt-mcp`;
- filesystem protocol version: 7;
- bootstrap sockets: debug `repoprompt-ce-D-7.sock`, release
  `repoprompt-ce-7.sock`;
- external-event directories: `MCPEvents-CE-D-7` / `MCPEvents-CE-7`;
- kill-signal directories: `MCPKillSignals-CE-D-7` /
  `MCPKillSignals-CE-7`;
- Application Support directory: `RepoPrompt CE`;
- stable wrapper configs: `discovery_debug.json` / `discovery.json`;
- network configs: `mcp-config_debug.json` / `mcp-config.json`;
- routing state: `mcp-routing_debug.json` / `mcp-routing.json`;
- user-space helpers: `repoprompt_ce_cli_debug` / `repoprompt_ce_cli`;
- PATH commands: `rpce-cli-debug` / `rpce-cli`;
- Claude wrappers: `claude-rpce-debug` / `claude-rpce`.

The exact current executable oracle is
`root/RepoPromptTests.MCPFilesystemIdentityTests/testCEFilesystemIdentityPreservesVersionedFlavorAndStableConfigurationNames`;
packaged helper layout and provenance also passed in the Phase 0 `dev-run`, smoke,
and `dev-build` evidence.

## Twelve P0 hazards

### P0-01 — dual authority

**Current behavior:** `WorkspaceManagerViewModel` is the only writable workspace
graph. One `WorkspaceSelectionCoordinator` and one `WorkspaceFileContextStore`
are composed per window; coordinator writes route through the manager.

**Current oracles:**

- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testPersistActiveSelectionWritesActiveTabAndEmitsChange`
- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testPersistActiveSelectionNoOpsWhenSelectionIsUnchanged`
- `root/RepoPromptTests.WorkspaceSelectionPersistenceTests/testDiskWriterPreservesNewerSelectionRevisionAgainstLaterStalePayload`

**Frozen future oracle (Phase 5):** the selected backend records every
command/receipt; the inactive backend is not constructed and records zero writes,
revision allocation, watchers, or persistence. No Phase 0 placeholder test is
valid because backend selection does not yet exist.

### P0-02 — fail-open worktree lookup

**Current behavior:** validated session-bound scopes verify root ID, lifetime,
kind, standardized physical path, and directory availability. Missing/replaced
roots produce typed unavailable and no widened catalog/search.

**Current oracles:**

- `root/RepoPromptTests.WorkspaceRootBindingProjectionTests/testMaterializerFailsClosedWhenPhysicalRootCannotBeLoaded`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testValidatedSessionScopeRejectsSamePathRootReplacement`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testMissingSessionWorktreeScopeThrowsTypedUnavailableErrorBeforeAdmission`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testQueuedSessionWorktreeSearchRechecksAvailabilityAfterAdmission`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testInitializingSessionWorktreeIsNarrowedOrTimesOutWithoutSearchingIncompleteCatalog`

Directory delete/recreate at one path without store reconciliation is not promoted
to a Phase 0 test: the current contract is store root/lifetime identity, while
descriptor/filesystem identity hardening belongs to the Phase 3 adapter boundary.

### P0-03 — generation loss

**Current behavior:** root lifetimes, accepted ingress, retained immutable catalog
leases, session dependency tokens, path indexes, and readiness tickets are
monotonic and revalidated across suspension.

**Current oracles:**

- `root/RepoPromptTests.WorkspacePerRootPathSearchIndexTests/testConcurrentOldReaderRetainsOldIndexWhileNewGenerationPublishes`
- `root/RepoPromptTests.WorkspacePerRootPathSearchIndexTests/testRootUnloadDropsOnlyItsReadyIndexWhileReplacementGenerationIsPending`
- `root/RepoPromptTests.WorkspaceSearchServiceTests/testWorkspaceSearchServiceDiscardsStaleRebuildCompletion`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testSessionCatalogDependencyTokenChangesAcrossUnloadAndReload`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testWorkspaceSearchReadinessSnapshotFenceMatchesMainActorAuthorityAcrossGenerationChange`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testQueuedBroadSearchRejectsSupersededReadinessTicketAfterAdmission`
- `root/RepoPromptTests.StoreBackedWorkspaceSearchTests/testSearchRejectsSupersededReadinessAfterAppliedIngressWait`
- `root/RepoPromptTests.WorkspaceSwitchRecoveryTests/testWorkspaceSearchReadinessWaitsForExactSwitchGenerationAndRejectsStaleTicket`

### P0-04 — selection loops and ABA

**Current behavior:** canonical selection, UI mirror, peer propagation, and tab
context use separate monotonic revisions. Same-value repair does not publish a
canonical mutation; stale/lower propagation loses; context revision distinguishes
A→B→A.

**Current oracles:**

- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testMCPMirrorRepairsAfterABATabTransitionDuringSuspension`
- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testMCPActiveSelectionNoOpReconcilesStaleMirroredUIWithoutPublishingChange`
- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testTwoSourceWindowsRejectDelayedOlderPropagationAfterNewerLocalMutation`
- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testApplyingSelectionMirrorGuardSuppressesFlushPublication`
- `root/RepoPromptTests.WorkspaceSelectionCoordinatorTests/testUIFlushDoesNotRepublishWhenSubscriberFlushesUnchangedSelection`

No extra method was added for a numeric same-value revision assertion or a
newer-peer ABA value: the existing observable no-publication and A→B→A outcomes
already discriminate the plausible regressions at the lowest faithful layer.

### P0-05 — MCP retargeting

**Current behavior:** admission/routing generations and binding generations reject
stale work rather than silently adopting replacement ownership.

**Current oracles:**

- `root/RepoPromptTests.MCPReadFileAutoSelectionCoordinatorTests/testReplacementBindingGenerationDropsOldWorkAndAcceptsNewWork`
- `root/RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateFailsClosedAcrossStaleStateAndLifecycleReplacement`
- `root/RepoPromptTests.AsyncLimiterTests/testDirectAdmissionRejectsLifecycleGenerationReplacementAfterSuspension`
- `root/RepoPromptTests.AgentRunSessionStoreRegistrationTests/testActivationReplacementExpiresOldWaiterAndRejectsOldPublication`

**Frozen future oracle (Phase 7):** one immutable admission token retains the
original runtime session through active→draining→removed; admitted work completes
there or fails and is never exchanged for the replacement session.

### P0-06 — physical-path leakage

**Current behavior:** physical paths may be used for reads, but prompt file trees,
MCP scope blocks, diffs, errors, and formatted tools expose logical labels.

**Current oracles:**

- `root/RepoPromptTests.PromptContextPreAssemblyServiceTests/testResolveUsesWorktreeContentAndLogicalizesFileTree`
- `root/RepoPromptTests.ToolOutputFormatterWorktreeTests/testWorkspaceContextOutputHidesPhysicalRootInScopeBlocks`
- `root/RepoPromptTests.AutomaticReviewGitDiffCoordinatorTests/testOneCheckoutFailureProducesExplicitPartialResultWithoutPhysicalPaths`
- `root/RepoPromptTests.ContextBuilderWorktreeInheritanceTests/testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps`

### P0-07 — review authority regression

**Current behavior:** the app creates and authorizes frozen Git artifacts. Exact
workspace/tab/repository/worktree/snapshot/consumer identity is mandatory; Core
may receive only already-authorized bytes and metadata.

**Current oracles:**

- `root/RepoPromptTests.SelectedGitDiffArtifactAuthorizationServiceTests/testFrozenReviewWorkspaceMismatchDoesNotSubstituteActiveWorkspace`
- `root/RepoPromptTests.SelectedGitDiffArtifactAuthorizationServiceTests/testRejectsMismatchedTabRepoKeyAndSnapshotIdentity`
- `root/RepoPromptTests.SelectedGitDiffArtifactAuthorizationServiceTests/testDelegatedCanonicalAuthorizationRequiresExactLaunchSelectionAndConsumer`
- `root/RepoPromptTests.SelectedGitDiffArtifactAuthorizationServiceTests/testWrongWorkspaceRootTraversalAndStaleCapabilityFailClosed`
- `root/RepoPromptTests.PromptContextPreAssemblyServiceTests/testDelegatedArtifactRequiresExactFrozenConsumerAtPreassemblyBoundary`
- `root/RepoPromptTests.MCPContextBuilderGitReviewPolicyTests/testPublishedOutcomesRequireCompleteExactFrozenCheckoutMatches`

### P0-08 — watcher after release

**Current behavior:** watcher ingress is keyed by root/lifetime; unload detaches
state before asynchronous stop, advances lifetime, and exact-lifetime cleanup
cannot remove a successor.

**Current oracles:**

- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testStalePublisherLifetimeCannotMutateCurrentRootState`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testSessionWorktreeOwnershipIsIdempotentSharedAndLastReleaseUnloads`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testSessionWorktreeOwnershipReleaseDuringRootLoadUnloadsLateRoot`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testUnloadRootDrainsTrackedPublisherIngressWithoutPostDetachMutation`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testWatcherRestartWinsRaceWithStaleStopReconciliation`
- `root/RepoPromptTests.WorkspaceFileContextStoreTests/testWorkspaceIngressCoordinatorLateForcedDrainCannotCorruptReopenedSameRootState`

Phase 3 adds an adapter-level late-OS-callback and exactly-once stop oracle after
the CoreMacOS ownership seam exists; no future adapter is mocked in Phase 0.

### P0-09 — dependency cycles

**Phase 0 oracle:** ADR-001 supplies an explicit topological order. Current
`Package.swift` has no new graph, and `make guardrails` plus both product builds
protect the present graph.

**Frozen future oracle (Phase 1):** reverse target edges and forbidden Core imports
must fail package/source guard validation. This is a structural/compiler guard,
not an XCTest.

### P0-10 — C-symbol collision

**Phase 0 oracle:** the bridging inventory identifies every POSIX, Tree-sitter,
RepoPromptC, and PCRE2 declaration; current app/MCP products link successfully.
ADR-001 reserves `rpce_` for new CE-defined C symbols and keeps upstream
`tree_sitter_*` single-owned.

**Frozen future oracle (Phases 1/3):** all products link and `nm`/ownership guards
find exactly one implementation per upstream or `rpce_*` symbol. No symbol-only
XCTest is added.

### P0-11 — headless privilege bleed

**Phase 0 oracle:** [headless-v1.md](headless-v1.md) freezes reviewed behavior from
`21b5603f`/`487cd71d`, including isolated state/secret identities, explicit
fail-closed roots, owner-only files, direct stdio, and the denied capability
matrix.

**Frozen future oracle (Phase 8):** isolated-HOME subprocess tests prove the
standalone process cannot observe app roots, state, secrets, sockets, or denied
capabilities. The current branch has no headless target, so a Phase 0 executable
placeholder would be false coverage.

### P0-12 — performance regression

**Current deterministic oracles:** bounded caches/leases, broad-search admission,
generation freshness, deterministic capped ordering, cancellation cleanup, and
the opt-in search-index benchmark's counter vectors.

**Diagnostic oracle:** the normal samples below are baselines, not arbitrary
XCTest thresholds. Material regressions block later phases and require
investigation rather than redefining the baseline.

## Performance evidence

Environment for search/catalog: Apple M4 Pro, 14 logical cores, 48 GiB,
macOS 26.5 (25F71), DEBUG SwiftPM, coordinated daemon.

### Catalog activation and search readiness

Command:
`make dev-test FILTER=RepoPromptTests.WorkspaceFileSearchIndexTimeToReadyBenchmarkTests/testLargeRepositoryTimeToReadyBenchmark`
with the supported `/tmp/RepoPromptCE-file-search-index-opt-in` marker.

Ticket `b31d6170-7fac-47fb-a659-a5dfb612f718`; five measured samples after one
excluded warmup; correctness passed and counter vectors matched.

| Scenario | Measured total ms | Median | p95 | Stability |
| --- | --- | ---: | ---: | ---: |
| cold worktree first scoped search | 1377.804, 1356.310, 1349.150, 1354.043, 1333.122 | 1354.043 | 1377.804 | 1.8% |
| incremental one-file ready search | 245.359, 242.725, 235.877, 236.143, 223.824 | 236.143 | 245.359 | 3.9% |

Cold ready-search phases were 386.999, 379.344, 382.745, 382.488, and
377.689 ms. Cold first-catalog phases were 238.420, 233.365, 237.020,
237.025, and 233.328 ms. Every cold sample crawled/built authoritatively once
with zero fallback; every incremental sample advanced/applied/patched once with
zero crawl, authoritative rebuild, or fallback.

The initially submitted environment-only opt-in ticket
`f2eb024a-26e1-4288-a16a-6873ed076915` skipped and is invalid timing evidence;
it is retained only to explain the supported-marker rerun.

### Selection/prompt work

Five coordinated normal samples of:

`RepoPromptTests.PromptCanonicalCodemapPackagingTests/testFrozenHeadlessPackagingPreservesSlicesAndWorktreeProjectionWithCanonicalCodemap`

| Ticket | XCTest seconds | Result |
| --- | ---: | --- |
| `6cb7c208-dbb2-47fc-8f49-1c70a459c17e` | 0.281 | passed |
| `4f08b8c1-10fe-4db7-be9d-7eb5c75335dd` | 0.267 | passed |
| `415e6340-88c2-403b-9408-97b081b1aa7b` | 0.265 | passed |
| `a25f6337-58fd-4361-a86c-35146a082426` | 0.270 | passed |
| `794987e4-771c-4f7e-81b4-53499d5f8b05` | 0.263 | passed |

Median 0.267 s; range 0.263–0.281 s. Each fixture physicalized a worktree
selection, preserved slices, resolved canonical codemap content, and rendered
factual prompt context. The report-only series has no arbitrary threshold.

### Packaged app-proxy smoke

The user explicitly approved one visible coordinated launch, five non-disruptive
smokes, and stop. `make dev-run` ticket
`f4126869-c980-417d-9d9d-d04cd53a54d6` built, signed, packaged, validated the
embedded helper, and launched PID 26963. All smoke jobs exercised windows,
workspace switch/idempotence, tree roots, worktree listing, and role discovery
with exit 0 and `measurementInvalid == false`.

| Ticket | Conductor execution seconds | Series use |
| --- | ---: | --- |
| `833c21c0-75a7-40b4-96ef-9b5ee4d1a826` | 2.194 | cold first switch/load; lifecycle evidence only |
| `cf1c0b94-e874-4f9f-81bd-ab7de0f5e413` | 0.302 | comparable warm sample |
| `3ae4c866-b576-4017-9684-af8cf3e21708` | 0.767 | comparable warm sample |
| `a5f6c1b3-1d88-435e-9ff3-71393eb6ced5` | 0.291 | comparable warm sample |
| `beec51d7-f1a1-48a5-888d-b6b9c002a3fe` | 0.302 | comparable warm sample |

The four comparable warm samples satisfy the required 3–5 series; median is
0.302 s and range is 0.291–0.767 s. Repeated workspace-switch requests returned
the harness-accepted already-active response and continued. Coordinated stop
ticket `5a7c4020-f8fc-45ed-9597-6220ba84a5ee` exited 0 and confirmed the app is
stopped.

## Phase 6 append — factual prompt parity and performance (2026-06-21)

Phase 6 preserves the characterized ordering, slices, canonical codemap rendering,
tree markers, selected-artifact precedence, map-as-context behavior, fallback
policy, and token estimator. A capture now blocks on accepted/applied ingress and
is discarded when catalog, codemap, validated worktree lifetime, session
activation, or state generation changes before completion. This intentionally
replaces the former plausible mixed-generation result with typed unavailability.

Focused correctness evidence began with Core accounting `fdd66c45` (10 tests),
Core factual capture/privacy `16f44f83` (3 tests), and root
authorization/orchestration `245fdb01` (11 tests). After the curated Oracle
corrections, Core factual capture `8abf30de` (4 tests), root preassembly
`4f0dc11a` (10 tests), and canonical packaging `a1d62bc2` (3 tests) passed.

Three comparable DEBUG SwiftPM samples of the authorized map/patch
capture/render/accounting test were:

| Ticket | XCTest seconds | Result |
| --- | ---: | --- |
| `3c1af909` | 0.006 | passed |
| `c2c3b6a0` | 0.006 | passed |
| `f2ae4eb4` | 0.007 | passed |

Median 0.006 s; range 0.006–0.007 s. This is report-only evidence with no
arbitrary threshold. The final live packaged `workspace_context` capture selected
three Phase 6 files and returned 10,199 total tokens: 10,072 selected-file tokens
plus 127 logical-tree tokens. It explicitly reported fresh accounting from the
`construction_selected_factual_provider`. Earlier Phase 0 samples remain the
fixed baseline.
