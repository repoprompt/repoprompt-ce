# Authoritative session catalog and point operations

**Status: implementation plan; maintainer review proceeds alongside separately validated commits.** Source audit: D branch `wt/overseer-scope-d-discovery`, HEAD `6533522c1ca59295ae1986339c9829aef5e75c42` (C baseline), 2026-10-13. Implement in order: (1) catalog/write paths/reconciliation, (2) discovery cutover and crawl removal, (3) target-bounded mutations, (4) withdrawal/completeness, (5) CodeMap idle investigation/repair. A/B/C remain untouched. Keep the real 42k-directory storage root permanently; cleanup and faster crawling are not solutions.

## Invariants

1. One durable catalog answers **which sessions exist and where**, for history candidates, administration inventory/census, agent discovery, sidebar, and organizer lookup. Queries never enumerate the workspace storage root, rebuild an index, or wait for reconciliation.
2. An explicit-target mutation does work proportional to its targets and necessary ancestry/incident effects, never unrelated sessions, tabs, workspaces, or directories. No membership census, inventory snapshot, sidebar rebuild, or history scan for a point mutation.
3. Catalog/indexes locate records, not authority. Exact caller routing, current ownership/incarnation, live scope generations, capability, ancestry, run-state restrictions, confirmation binding, and commit-time checks remain mandatory.
4. Completeness is explicit and scoped. Unknown is not empty, absent, idle, orphaned, or permission. Output pagination is not discovery truncation.

## Existing entry points to replace

Paths in the following reference key are relative to `Sources/RepoPrompt/` unless otherwise indicated; line numbers refer to the audited HEAD.

| Key | File and relevant lines |
|---|---|
| H | `Features/AgentMode/History/HistoryMCPToolService.swift`: list 127–139; search 495–510; time 751–769; get-session location/global-refresh fallback 267–307 |
| S | `Features/AgentMode/History/HistorySessionScanner.swift`: inventory/cache 771–885; root enumeration 975–991; metadata filtering 1026–1096; cold session lookup enumerates directories 1104–1250 |
| I | `Features/AgentMode/Services/AgentSessionOrganizingSupport.swift`: exact-target ancestry lookup 333–374; workspace/global history scan 375–405; global links and snapshot construction 413–424; loaded projections 515–621 |
| C | `Features/AgentMode/Services/AgentSessionAdministrationService.swift`: explicit targets enter `withSynchronousCensus` 190–197; membership/state/usage projection 210–231 |
| P | `Features/AgentMode/Runtime/Delegation/DelegationMembershipProjector.swift`: census construction 145–159, 244–267; full loaded-session/liveness collection 355–372 |
| F | `Features/AgentMode/Services/AgentSessionAdministrationFrontDoor.swift`: explicit unproven targets use inventory 437–451; filter derivation uses snapshot and census 510–541 |
| O | `Features/AgentMode/Services/AgentSessionOrganizer.swift`: rename/pin/group 236–311; archive 313–337; unarchive reload 355–396; carrier lookup builds sidebar/tab/stash projections 427–447; tab field mutation scans/reloads workspace 508–527 |
| R | `Features/AgentMode/Services/AgentSessionReleaseOperationHandler.swift`: whole-app oversight inventory **per target** 127–169 |
| B | `Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift`: `oversightInventory` collects all observers/candidates/intents 1218–1230 |
| X | `Features/AgentMode/Services/SessionAdminRestructureHandler.swift`: link 184–230; reparent ancestry/other-scope/depth checks 303–342; adopt subtree/usage 345–405; placement commit checks 459–532 |
| Q | `Features/AgentMode/Services/AgentSessionInventoryOperationHandler.swift`: reads snapshot 36–76; inventory/get/tree 84–177 |
| D | `Features/AgentMode/Runtime/AgentSessionDataService.swift`: save + index write 577–595; whole-index upsert 789–808; filename scan/rebuild 865–1025; read-triggered backfill/reconciliation 1103–1119, 1174–1200; list metadata 1586–1640 |
| M | `Infrastructure/MCP/Agent/AgentManageMCPToolService.swift`: listing combines disk metadata, window index, and loaded sessions then child-filters 361–478 |

Replace H/S discovery with catalog queries; remove both the TTL inventory and cold-ID/global-refresh fallback as discovery authorities. Split transcript reading into a catalog-addressed reader. Replace I/F/Q snapshots with catalog range/point/adjacency reads, keeping scoped redaction. Replace M's three independently assembled sources with catalog metadata plus the targeted live-state projection. Sidebar restore currently reaches D through `AgentSessionDataService+Restore.swift:30–56`; stream catalog rows instead of rebuilding missing disk indexes inline. O's location lookups become indexed IDs, not constructed sidebar rows.

**Important distinction:** loaded explicit rename does not always call history or inventory today. C/P census and O carrier/full-tab work are sufficient to violate the point-operation requirement; F adds history/inventory for unproven targets or filters, R adds global links for release/retire. Do not claim every expensive path runs on every call.

## Catalog shape and persistence

Propose a single versioned SQLite catalog under the CE Application Support root (`SessionCatalog/catalog.sqlite`), using the platform library via a narrow wrapper, not a new ORM. Persistence substrate belongs in `Sources/RepoPromptPersistence`; typed catalog contracts/index logic in `RepoPromptDomainRuntime`; app composition/write adapters in their existing owners. This adds a system-library seam: the current inspected persistence/runtime targets have no SQLite implementation.

- `workspaces`: stable UUID, name/normalized search keys, registered storage authority/location, revision, deletion/consolidation state, metadata and session coverage state. Workspace identity/lifecycle comes from the existing workspace authority, not a directory-name guess. Persist catalog registration and workspace-owner changes together via the mutation protocol below.
- `sessions`: global UUID, workspace UUID, tab/archive carrier identity, title, archive/pin/group/order, provider/model, activity/duration/turn/tool/file-touch metadata, spawn/creator/organizational placement, worktree summaries, revision, durable payload locator/signature, deletion tombstone, field-level enrichment state. Reuse the semantic fields of `AgentSessionMetadataRecord`, not another reduced inventory record. Metadata-only rename must not decode/rewrite a full transcript.
- Indexed workspace/activity/provider/state/pin/group/parent keys; child adjacency and text postings for supported name/path/query predicates. Sorting and filter candidate selection use covering indexes/postings, not a full table/dictionary filter per request. Arbitrary predicate combinations must be checked with query-plan/visited-row witnesses; unsupported predicates cannot silently fall back to a root or full-population scan.
- Durable mutation/outbox records and reconciliation/classification checkpoints. Store the catalog epoch/schema, monotonic commit generation, per-workspace coverage generation, pending/failure reasons, and committed tombstones. One session has one canonical location; moves cannot temporarily count both projections.
- MainActor owns a **write-through, generation-stamped projection** plus a targeted session → live carriers registry. The latter tracks every incarnation, duplicates, window lifetime, binding generation, and run-state transitions. It is derived live state, not a second durable existence catalog or a cached permission.

Reads return rows, `catalog_generation`, `catalog_complete` (for the requested scope), `metadata_complete`, reconciliation state, and a continuation when output is paginated. During migration/failure an empty known set returns `incomplete_catalog`/unknown total with a prominent warning, never “0 sessions”/“no_matching_sessions”. A count of known rows, if supplied, is explicitly a lower bound. A completely reconciled workspace can answer confidently while global migration is still incomplete. Unscoped metadata history has no workspace/session discovery budget; explicit page limits affect output only. Transcript-content budgets remain separate and cannot invalidate the complete candidate count.

`workspace:"current"` resolves from exact server-owned caller routing; unresolved routing fails closed, never falls back to a focused window. Agent Mode's omitted history workspace should default to current, with an explicit all-workspaces selector to retain cross-workspace history access. External/administrative defaults and permissions remain unchanged. `agent_manage list_sessions scope:"workspace"` selects the caller's workspace read-only; default child discovery remains disclosed. History already exposes cross-workspace metadata, so this grants no new mutation capability or delegation authority.

## Transactional write hooks (not best-effort indexing)

Hook the **owning write paths**, not each MCP tool separately:

| Mutation | Existing owner/hook |
|---|---|
| Create/fork/save/load-repair | `AgentSessionDataService.swift:577–615, 1315–1360`; admission creates a stable session row before first-turn discovery, then updates transcript-derived metadata with saves. UI, agent_run, agent_manage and provider paths converge here. |
| Rename, pin, group, archive/unarchive | `AgentSessionOrganizer.swift:236–396`, `AgentModeViewModel.swift:22014–22082`, `Features/Prompt/ViewModels/PromptViewModel.swift:3884–3904, 4069ff, 4821ff`. Replace full tab-array projection/reload with owner delta methods and row-level durable fields. |
| Spawn/reparent/adopt placement | `Runtime/Delegation/AgentModeViewModel+DelegationPlacement.swift:99–130`, X:459–532; update row, parent/child index, subtree aggregates and placement revision in the same commit. |
| Session move/consolidation | `AgentSessionDataService.swift:1205–1309`; source removal, destination insertion, payload locator and references are one catalog mutation, with rollback receipts. |
| Session deletion | `AgentSessionDataService.swift:1725–1889`; durable tombstone + index removals share the existing deletion/write fence so queued saves cannot resurrect the row. |
| Workspace create/rename/delete/consolidate | `Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:5221ff, 12550ff, 13602ff, 13761ff, 13849ff`; stable workspace IDs avoid rewriting all session rows just to rename a workspace. Import, restore and custom-storage relocation use these same catalog mutations. |
| Link/intent changes | B's existing Add/Stop authority and intent-store transactions publish endpoint-indexed deltas; no separate link owner. Link generations/cursors/notices/Auto-wake stay with their four existing owners. |

SQLite cannot atomically commit unrelated JSON files. Do **not** add a fire-and-forget “update catalog after save” hook. Stage/fsync changed payloads when needed, then transactionally commit the catalog row/locator plus an idempotent owner-write intent; acknowledge only a durable accepted mutation. Catalog-addressed readers see the committed payload version. Canonical JSON/index materialization is a replayable compatibility/export projection, not another discovery authority. Recovery resolves pending intents by operation ID/revision; it never infers existence from a partial directory walk.

The authority/owner commit protocol must preserve the existing no-suspension live check + mutation linearization region, including revocation during staging. Preparation/I/O occur off MainActor; final accepted operation tokens are issued only after exact target/lease/generation revalidation. Durable acceptance, owner projection and notifications carry the same revision; post-commit projection failure is reported as partial success and replayed idempotently, not retried as a fresh mutation. Failure before acceptance changes no target. This protocol needs explicit crash/revocation fault tests before implementation is considered complete; SQLite alone is not a cross-owner transaction.

A rename/pin/group delta must **not** schedule whole-workspace JSON encoding, `loadComposeTabsFromWorkspace`, global search rebuilding, or full sidebar sorting later as hidden work. Session presentation fields become catalog-owned row projections; legacy snapshots are explicit/batched checkpoints, not per-point-write work. Targeted subscribers update affected search postings/visible rows and ordered indexes. Provider thread-name sync remains a target-only effect. Successful target changes emit `(sessionID, workspaceID, changedFields, generation)` to interested carriers/subscribers only.

## Maintained ancestry and scoped authorization

B's `Sources/RepoPromptDomainRuntime/SessionLinks/DomainAgentSessionAncestryIndex.swift:5–71` is **immutable**, computes Euler positions/cycles from all parents, and has O(1) distance queries (`:74–86`). P:145–159 rebuilds it per census. It cannot simply become the mutable authority-side index: changing one edge can invalidate subtree Euler labels.

Reuse its graph/cycle semantics and test coverage, but replace query-time construction with maintained ID → effective-parent and parent → children indexes. Target proof walks only that ancestry (existing 256-node bound); maintain subtree size/height/liveness/worktree-refcount summaries incrementally along affected ancestor chains, plus scope-root/grantee indexes for foreign-scope protection. Do not eagerly cache all ancestor paths or rewrite every descendant on a reparent. B's immutable index can remain a background verification/rebuild artifact, never a point-call fallback. Missing, conflicting or cyclic placement is unresolved for authorization.

Point pipeline: catalog ID lookup → target-only routing/liveness → ancestry proof for each scope in the caller's chain → live authority lease → owner mutation → targeted delta. After every suspension, revalidate that target's exact owner/incarnation/placement revision, live scope chain/generation and operation arguments; commit check and live owner change remain indivisible. Unknown/duplicate live carriers never become idle. Capability/grantee checks precede metadata disclosure. Scope revocation/expiry, confirmation/idempotency/undo, non-upgrade of links and Add compensation remain with existing authorities.

Filter operations use catalog postings to find matches, then authorize/revalidate those matches individually. Absence predicates (orphan/has_links:false) require complete relevant membership/edge coverage; unknown cannot widen a mutation. No global census even for an empty result. Live link adjacency comes from the link owner indexed by endpoint, durable intent adjacency from its store; keep endpoint redaction and dormant-intent behavior. Structural operations preserve cycle, foreign-scope, whole-subtree guardrail and adoption-card rules using affected ancestry/aggregate indexes, not all sessions or all scopes.

## Per-operation cost contract

Let N = catalog sessions, T = app tabs, W = known workspaces, D = storage directories, k = explicit targets, m = output/matching sessions, d = bounded ancestry/scope depth, e = affected incident links, s = descendants actually rendered/adopted. Current costs below are reachable work, not measured asymptotic benchmarks. Common **C/P** = O(loaded sessions + live binding/tab projection) census. **F/I/S** = optional target/filtered snapshot/history path, up to O(D + scanned metadata + T + links), budget-truncated. Indexed lookup has O(log N) overhead; “O(k)” means record visits independent of N/T/W/D, with d bounded, not a claim that B-tree comparisons or unavoidable returned edges are free.

| Operation | Current path/cost (citations above) | Target work |
|---|---|---|
| rename | C/P + O:236–246,427–447; `PromptViewModel.swift:3884–3904` full-tab reload, optional F/I/S | O(k·d) record visits, k row/posting changes, zero census/inventory/sidebar rebuild |
| set_pin | C/P + O:248–271,427–447; pin owner `PromptViewModel.swift:4821ff` | O(k·d); target rank insertion via ordered index, no all-pin renumbering |
| set_group | C/P + O:273–311,508–527 scans/reloads tab arrays | O(k·d); target group/order postings only |
| archive | C/P + O:313–337 performs stash per target; location scan and owner tab-removal projection | O(k·d), exact carrier removal/run-state fence; no unrelated tabs/descendant cascade |
| unarchive | C/P + O:355–396 scans stash/tab arrays and reloads compose tabs | O(k·d), exact stash/carrier restore and notification |
| retire | C/P + R:127–169 O(k·whole-app link inventory) + archive path | O(k·d + e), incident links only through Stop owner, each counterpart revalidated; cards preserved |
| link | C/P + X:184–230 Add checks; optional F for unresolved targets | O(k·d), exact observer/target carriers and pair lookup; no observer/link census |
| reparent | C/P + X:303–342,459–532; projector ancestry/subtree and foreign-scope reads | O(k·d) bounded affected-chain visits plus ordered aggregate updates; no global Euler rebuild or unrelated descendant relabeling |
| inventory | Q:36–99 + I/F/S; snapshot/redaction/filter/sort scans population and global edges | O(log N + m + returned edges), indexed scope/filter range, complete candidate count; pagination distinct from catalog readiness |
| get | C/P + Q:43–51,103–129; exact path can avoid global history but I still reads global links | O(log N + d + requested children/edges); base record O(1) record visits, optional adjacency output paged |
| tree | Q:133–177 builds child map from snapshot population | O(log N + s + returned edges), maintained adjacency traversal; depth/output caps explicit |
| history list | H:127–231 + S inventory/filter/sort; O(D + scanned records), 5k workspace limit | O(log N + m), indexed metadata selection/count; no scan budget or transcript hydration to list sessions |

Retiring a high-degree target must touch its incident edges; returning a subtree must touch returned descendants; adopt must enumerate its approved descendants. These are required **affected result** costs, not permission to census unrelated sessions. If existing max-depth/distinct-worktree invariants cannot be maintained by incremental aggregates, implementation must stop for a revised structural-index design, not sneak in a whole-app fallback.

## Reconciliation, migration and failure states

A low-priority, resumable background worker alone may enumerate disk. Seed registered workspaces from existing workspace authority/catalog snapshots; prioritize open workspaces, then known inactive ones. Import valid legacy session indexes once, header-reconcile stale/missing ones in bounded batches, and enrich transcript metadata separately. Never open repository roots or start CodeMap indexing for discovered workspace directories.

Persist job generation, phase, resumable work queue/cursor, classified directory identity/signature, processed counts, remaining-known work, errors and per-workspace readiness. Invalid/junk/non-workspace entries are classified once without deleting anything; valid orphan workspaces are distinguished from junk and imported only after identity/storage validation. Resumption must not replay all processed directories as ordinary startup work. Watcher events enqueue specific changed paths; watch loss marks coverage degraded and schedules one explicit incremental recovery, never periodic full-root polling. No idle O(D) stat/signature sweep. Reconciliation generation is separate from catalog commit generation; compare-and-swap imports against observed row revisions/tombstones so stale rebuilds cannot overwrite newer writes or resurrect deletes.

Short batch transactions yield to foreground reads/writes; WAL snapshots isolate queries from reconciliation. Pending migration never causes a query to await completion. Publish progress and failure/readiness in tool replies and app diagnostics. Unknown future schema/corruption is a visible degraded state, not silent reset or empty success; keep the old files intact and support an explicit background rebuild. Legacy per-workspace indexes become migration/compatibility artifacts only, with no query-time fallback. Cut over all consumers together before claiming a single catalog authority.

## Idle CPU: evidence and separate boundary

The supplied `/tmp/rp72314-samples/hot-082820.txt`, `hot-082910.txt`, `hot-083000.txt`, `hot-083051.txt` repeatedly contain `runGraphIndex`/`makeCandidate`. The latter three contain **no HistorySessionScanner/scanWorkspaces frames**. Samples report physical footprint 1.9–2.1 GB (peak 2.2 GB); this is not the same metric as the reported RSS. Samples alone do not identify the indexed workspace or prove repeated-job churn.

Read-only live CE `codemap_graph_status` captures (`/tmp/pr-d-graph-window-{1,2,4}.txt` and window-1-second) identify the active primary root of the **open upstream repository**, `D6B1315D-C752-41D8-9FC3-62BBCC579CDA`: the same job `791744E6-234D-451F-A3BA-64622A42AAB3` advanced from 18,816 to 30,016 of 39,958 candidates. REA's 2,479-candidate job and testwtbugs' 2-candidate job are complete; shared accounting reports three jobs and one active batch. This supports a progressing full graph-index pass on an open source root, not 42k workspace-directory indexing. The visible-root diagnostic is not an exhaustive proof that no other root can ever be indexed.

Source trigger: `Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:11615–11618,13409–13453,13637` schedules eligible loaded roots after inventory/search readiness; `WorkspaceCodemapBindingEngine.swift:1355–1475,2611ff` starts the utility worker. `WorkspaceCodemapSelectionGraph.swift:1352–1361,1406–1469` revisits affected referrers and resolves/sorts edges per diff. High-degree repeated graph work is a plausible cost amplifier, not yet a demonstrated bug. All three files have **zero diff** at `origin/main...HEAD` in this D checkout; current evidence does not attribute this code to the overseer stack. Historical sample source line offsets differ from this checkout.

Report this as a separate CodeMap performance boundary, not fixed by the session catalog. Before calling the overall idle criterion passed, pin app provenance and measure the same job through completion, root lifetime/job restart counts, graph edge/affected-source work, and CPU/RSS with no foreground queries. Prove unopened workspaces create no graph jobs. If jobs repeatedly restart or fail to settle, a separate bounded CodeMap repair is required. Process sampling via `ps` was sandbox-denied in this design pass; no current CPU/RSS improvement is claimed.

## Acceptance and rollout gates

- Deterministic fixture: 250 sessions, 1,500 tabs, **42k decoy directories retained**. End-to-end rename (including queued notifications/persistence work) visits one target plus its bounded chain, changes one catalog row, and performs **zero** membership census, inventory snapshot, global link census, root enumeration, sidebar rebuild, tab-array reload or whole-workspace serialization. Repeat with larger N/T/D and assert unchanged unrelated-record counts.
- Equivalent operation-count witnesses for pin/group/archive/unarchive/retire/link/reparent; high-degree/subtree tests account only for necessary effects. SQL visited-row/query-plan witnesses ensure point and selective-filter calls do not hide full table scans. Notification observers must be included in the witness.
- Crash/restart/write-failure/move rollback, concurrent rename/delete/reconcile, revocation during suspension, duplicate carriers, cycles/missing ancestry, ancestor revocation, stale approvals/idempotency/undo, orphan redaction, and custom storage/import/schema migration tests.
- Interrupted background bootstrap queries are prompt and visibly incomplete; a known complete workspace is authoritative even with unrelated migration pending. Classified junk costs zero on unchanged subsequent launches; reconciliation converges without clobbering foreground updates.
- Real 42k-root CE scenario: current/named workspace **complete listing under 100 ms**, measured end-to-end including encoding/transport, not just the database helper; unscoped metadata history never discovery-truncates. Preserve the measured old baseline: named testwtbugs 3.289 s/incomplete zero lower bound, UUID 1.678 s/40 sessions (`/tmp/pr-d-before-{named,uuid}.txt`).
- For each implementation increment: focused suites, full coordinated `make dev-test`, `make dev-lint`, guardrails, commit/push preflights and review. Fresh live scenario uses a stronger model than Haiku; record exact tool calls/results and pushed-head debug-app provenance. No claimed idle pass until the separate graph workload settles or is repaired.
- Pending `release_scope request_id` withdrawal remains a bounded runtime lifecycle fix (`Infrastructure/MCP/Agent/SessionAdminMCPToolService.swift:217–243`, `Runtime/Delegation/DelegationScopeRuntime.swift:397–466`): requester-only, cancelled requests cannot later be approved; no scan or catalog grant.

**Maintainer-guidance check:** impact/invariants are correct existence and target-bounded work; scan/census causes are source-confirmed; catalog owns discovery while existing scope/link/lifecycle authorities keep permissions. Main risks are crash consistency, legacy projections becoming competing authorities, stale placement/live state, and hidden whole-workspace subscriber work. Recommended scope is the coordinated catalog/write-path/consumer cutover above, with separate reporting of CodeMap idle cost. Proceed incrementally; escalate genuine authority or semantics decisions without blocking unrelated work.
