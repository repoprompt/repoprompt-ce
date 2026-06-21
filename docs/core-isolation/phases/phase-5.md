# Phase 5 — Atomic Workspace Authority Cutover

**Date:** 2026-06-21
**Implementation base:** `e76b39f1bf55be23c4976f839edf885473086704`
**Status:** complete
**Disposition:** **GO**

## Scope

Phase 5 selects exactly one writable workspace-session backend for a window and
moves canonical workspace state, selection revisions, root readiness, switching,
and persistence behind that backend. Phase 4 engine behavior and Foundation JSON
bytes remain the compatibility baseline. Phase 6 prompt projection, Phase 7
request draining/weak registries, Phase 8 standalone headless work, and Phase 9
compatibility removal are excluded.

The default is `core`. `coreIsolation.workspaceBackend=legacy` is an immutable
next-launch rollback choice retained through Phase 8; there is no live backend
switch or writable shadow backend.

## Blocker closure record

| Former NO-GO blocker | Implemented closure |
| --- | --- |
| Optimistic manager projection | `workspaces`/active ID are private-set observation projections. Selected mutations submit typed intents; receipt sequence waits for the one-way observation bridge before dependent work. Active-workspace listeners fire only after the complete authoritative projection. |
| Manager-owned root switching/readiness | `RepoPromptCoreSession` owns initial hydration, target unload/load, refresh, active-root replacement, active reload, cancellation boundaries, recovery, and shutdown. `WorkspaceSessionLifecycleOwner` owns the real Phase 4 store root lifetime; readiness follows load, watcher demand, and applied ingress. |
| Split selection replacement | Selection returns typed committed/unchanged/stale/not-ready outcomes. Deterministic transforms rebase from the latest snapshot at most three times under session, activation, host, and workspace/tab identity fences. Atomic `selectionAndPatch` prevents a whole-tab patch from replacing canonical selection. |
| MCP token/mapping retarget | `MCPAdmittedContextBinding` keeps window, logical workspace/tab, session ID, and exact activation token inseparable. Logical admission precedes sticky mapping; TaskLocal propagation reaches workspace/tab/selection commands; mismatch fails without reacquisition or retarget. Session switches preserve activation while advancing state/readiness generations. |
| Raw lifecycle capability | The session alone receives `WorkspaceSessionLifecycleOwner`; app consumers receive a fail-closed immutable `WorkspaceSessionQueryCapability` with no load, unload, writer, persistence, or admission surface. |
| Split writer/generation ownership | `WorkspaceSessionPersistenceCoordinator` is the selected writer/reconciler. Controller snapshots own state, dirty/saved, readiness, and selection generations. Manager writer/generation code is hard-gated to DEBUG/no-session compatibility fixtures and is unreachable from selected composition. |
| Incomplete rollback parity | `LegacyWorkspaceSessionBackend` implements the complete common command matrix, deterministic stash IDs and stashed patches, save/flush/reload/index behavior, selection CAS, switch/refresh/root lifecycle and recovery, receipt identity, result caching, and shutdown. Core/legacy parity tests cover commands plus successful persistence/reload bytes. |

## Construction and activation

`RepoPromptAppCoreContainer` resolves the backend once. The inactive backend
factory is lazy and never evaluated. Core selection constructs one host/session,
lifecycle owner, persistence coordinator, revision authority, and command ingress;
legacy selection constructs only the rollback backend resources. Shadow comparison
accepts immutable snapshots only.

Activation order is:

1. resolve the immutable backend and storage policy;
2. construct one lifecycle owner and selected runtime;
3. decode current workspace/index bytes once;
4. hydrate the active workspace roots using current filesystem settings;
5. establish watcher demand and await applied catalog ingress;
6. publish the first root-ready authoritative snapshot;
7. apply it through `WorkspaceSessionObservationBridge`;
8. acknowledge that exact snapshot sequence;
9. mint one session activation and admit commands/MCP;
10. continue monotonic observation, resynchronizing sequence gaps from the current immutable snapshot.

The deferred ingress never queues pre-activation commands. Shutdown revokes
admission, finishes observations/waiters, cancels or drains accepted work, unloads
the active lifecycle generation, closes the lifecycle owner, and releases the
host ownership lease exactly once.

## Authority inventory

| State or ingress | Selected owner/path |
| --- | --- |
| Ordered workspaces, active ID, tab/stash state | `WorkspaceSessionController` snapshot |
| Workspace create/delete/metadata/hide/ephemeral changes | `WorkspaceSessionCommandClient` → selected ingress |
| Compose create/remove/patch/activate/reorder/stash/restore/delete-stashed/patch-stashed | backend-neutral `ComposeTabCommand` |
| Root add/remove/reorder | ordered-root command → session lifecycle refresh |
| Switch/refresh/reload and recovery | `RepoPromptCoreSession` or parity legacy orchestration |
| Selection replacement | expected-revision selection command |
| Selection plus draft/context fields | atomic `selectionAndPatch` |
| Deterministic slice/artifact transforms | bounded coordinator stale rebase |
| Mirror/peer sequencing | MainActor coordinator counters only; noncanonical |
| Dirty/saved/readiness/state/selection generations | controller/session snapshot |
| Save/flush/reload/index/normalization arbitration | selected persistence coordinator |
| Root load/unload/watcher readiness | opaque session lifecycle owner |
| Root/path/search reads | immutable query capability or existing content-operation adapters |
| Manager arrays and UI listeners | observation-only presentation projection |
| MCP mapping and mutation authorization | exact admitted request binding |
| Rollback | same client surface over `LegacyWorkspaceSessionBackend` |
| Shadow | pure immutable snapshot comparison |

No production selected path falls back to manager array mutation, manager disk
reload, a second writer, or a second revision allocator. DEBUG XCTest compositions
that intentionally construct no selected backend use an explicitly XCTest-gated
typed adapter; that adapter is absent from release builds and is not a Core/legacy
runtime fallback.

## Persistence and rollback compatibility

- Workspace and index locations, keys, Foundation encoder/decoder defaults, array
  order, `discover`, and ephemeral filtering are unchanged.
- Per-URL serialization, stale payload suppression, newer-selection precedence,
  newer-disk field preservation, normalization fingerprint CAS, and flush behavior
  remain behind the selected coordinator.
- Persistence receipts identify the exact session and activation and report
  dirty/saved disposition without manager-side generation allocation.
- Next-launch legacy reads the same current bytes and executes the same common
  commands. No migration, dual write, or shadow writer exists.

## Tests and structural guards

New/expanded contracts cover:

- first-snapshot admission, session/activation receipts, duplicate command IDs,
  root readiness failure, late hydration shutdown, switch/recovery, active root
  replacement, reload, opaque queries, and host ownership;
- persistence merge precedence, index order/ephemeral exclusion, and normalization CAS;
- complete Core/legacy command and persistence/reload parity;
- receipt-first active projection and real store lifecycle/query behavior;
- typed selection outcomes, no ingress fallback, bounded stale rebase, retry limit,
  activation/identity fencing, and atomic selection/tab patching;
- exact MCP session/token binding, switching-token retention, delayed mapping,
  no retarget, inactive-tab persistence, and routing compatibility fixtures.

`Scripts/core_isolation_guardrails.py` and its negative fixtures enforce private
manager projection, no optimistic didSet feedback, selected writer/generation
exclusivity, opaque lifecycle/query capabilities, no selected selection fallback,
complete legacy dispatch, coherent MCP admitted binding, and no Phase 6/headless
construction.

## Validation evidence

| Lane | Ticket / command | Result |
| --- | --- | --- |
| Core session focused | `8db34cf6-d470-4867-8369-d23ac63ded0a` | 10 pass |
| Core controller focused | `60d01c48-8a80-476e-871a-aeddcbb8dc22` | 4 pass |
| Core persistence focused | `48a83665` | 3 pass |
| Core/legacy command parity | `f5c578a7` | pass |
| Core/legacy persistence/reload parity | `07c07d7b` | pass |
| Root authority/parity/lifecycle | `6f28503c-a8d3-47a8-84f1-77fc36e2d1b7` | 7 pass |
| Selection coordinator | `bd5844db-2192-436f-8618-b103fb4a9305` | 28 pass |
| Selection persistence | `2be59110-66e2-42e4-8338-3f8db6fd8bf7` | 4 pass |
| Switch recovery | `ebefafb6-6553-4676-b4a0-b01edcbe5e9a` | 21 pass |
| MCP tab routing | `18b05eb1-a69f-4aa5-a419-3adc21108051` | 46 pass |
| MCP watchdog/dispatch regression | `396882e0-030a-44cd-a4ee-c684dfe163d3` | 17 pass |
| Persistent read/selection regression | `939489d6-9226-4a26-8878-596f3b05a81b` | 19 pass |
| Full Core root | `c679c25b-5994-427a-a9b5-d2efd8a37c7a` | pass |
| Final Swift format/lint | `52fb6b2e-2bb6-46e4-ac04-1f0e128516c5`; `025b9d98-fef7-401b-9487-a93cf57d85c9` | 0 files changed; 0 lint violations |
| Full Oracle-worktree regression class | `ffbb7fe8-f3f2-46ef-91e3-1ef5f86e0048` | 21 pass |
| Full root | `1074851e-031d-44e7-b753-f2ec9cd6b3d1` | pass |
| Core macOS / POSIX / provider | `0d0d348e-780a-49ea-9cbc-7637d0d27293`; `10b0efab-2828-4b0e-bd1d-7e65a74e7153`; `02da9adb-fe28-4d1a-ba5e-a59a48cb325c` | pass |
| All Swift products | `a13326ec-5a7b-4104-92c1-5e55cf877e43` | `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless` pass |
| Non-launching signed debug package | `b249ce77-5322-46dd-98c8-19057297c786` | pass, including architecture, signature, helper layout, and embedded-helper smoke |
| Xcode generator / validation | `make xcode-generator-test`; `make xcode-validate` | 23 pass; workspace regenerated and `xcodebuild -list` validated |
| Exact ledger reconcile | `verify-ledger` | 1,917 IDs: Core 235, CoreMacOS 34, POSIX 3, provider 7, root 1,638 |
| Guard ladder | `make guardrails`; Core-isolation 17; optimizer 26 | pass on final source |
| Manually curated Oracle review | relay session `A9A091B6-7E2E-4BDE-8090-FA46CA2C2875`; `prompt-exports/oracle-review-2026-06-21-190402-untitled-chat-9da990-ae64.md` | **GO**, no blocking findings |
| Coordinated packaged relaunch | `df1df8ca-c20c-4825-8f15-b39eac423760` | pass; matching PID `50310` |
| Packaged live cold / idempotent smoke | `dd33ec37-4ffb-4b83-9655-3b5bd2a0d65a`; `7e7cf414-3819-4c7a-bb55-93a3d6d8fc3e` | pass; second switch reported already active and completed the remaining flow |
| Coordinated stop / exact process proof | `eb145f35-0c4f-4e1d-b615-f0928f037780`; exact executable scan | pass; PID `50310` absent and zero matching processes |

## Final Oracle and live gate

The review tab was explicitly bound to worktree
`wt_eda4cdc53d376a9912a55bd89432b5d324ee84bd49ff2a2a52dd18d35665623c`
at base `e76b39f1`. Git snapshot `2026-06-21/1857` published all 53 changed
files and then replaced the 221,113-token aggregate patch with a manually
curated 125,919-token set of MAP plus exact per-file patches spanning the Core
session, app adapters, manager projection, selection, MCP binding/routing,
legacy rollback, composition, and this phase record. The historical planning
chat was unavailable after relaunch, so the sole completed Oracle review used a
fresh review chat over that unchanged selection. It returned **GO** with no
concrete blocking correctness findings, preserved Phase 4 behavior and bytes,
and admitted no Phase 6 scope.

The approved packaged lifecycle gate then ran two non-launching-rebuild-free
live smokes against PID `50310`. The first performed the workspace switch and
validated roots, worktree inventory, and role discovery. The second exercised
the already-active idempotent switch path and completed the same remaining
checks. Earlier in the same approved run, exact tab admission, session-bound
worktree routing, revisioned selection mutation, and authorized Git artifact
publication succeeded on the live app. Conductor then stopped the matching app;
an exact resolved-executable scan found no matching process and PID `50310` no
longer existed.

## Gate

**Final disposition: GO.** Every deterministic, structural, style, ledger,
build, Xcode, signed-package, curated-review, and approved live lifecycle gate
is green. No selected-path direct authority, inactive mutable backend,
pre-ready admission, projection feedback, second writer/revision/watcher owner,
selection fallback, MCP retarget, persistence-byte change, or Phase 6 work was
accepted. Changes remain uncommitted.
