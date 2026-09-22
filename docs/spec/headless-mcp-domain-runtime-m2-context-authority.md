# Headless MCP domain runtime — M2 workspace/context authority

Date: 2026-07-26
Stack base: `feature/headless-runtime-m1-foundation` / PR #640
Frozen baseline: [`headless-mcp-domain-runtime-m0-contracts.md`](headless-mcp-domain-runtime-m0-contracts.md)

## Ownership boundary

`RepoPromptDomainRuntime` is the canonical mutable owner of workspace documents, compose-tab context metadata, revisions, connection bindings, window-generation routing, and run-launch reservations. `DomainWorkspaceStore`, `DomainContextStore`, and `DomainRoutingCoordinator` expose immutable snapshots and revisioned commands. The app owns only a `@MainActor` projection bridge and active-window presentation resolution.

Production `WorkspaceManagerViewModel` construction receives a `DomainWorkspaceAuthorityClient`. Its workspace/index writers are disabled and its save entry points issue revisioned runtime commands. A nil client is an explicit isolated legacy-test owner. M3 read providers may temporarily consume the app's connection/tab projection cache, but M2 binding transitions are published to `DomainRoutingCoordinator`; new routing and launch decisions use coordinator snapshots and tokens.

## Persistence and migration

The runtime reads existing `Workspaces/workspacesIndex.json` and `workspace.json` bytes without rewriting them at startup. Raw workspace bytes remain the compatibility format. Runtime-owned sidecars live below:

```text
DomainRuntime/v1/<profile>-<digest>/
  workspace-catalog.json
  working-journals/<workspace-id>.json
  revisions/<workspace-id>.json
  deletion-tombstones/<workspace-id>.json
  locks/
  settings/runtime-policy.json
  rollback/migration-*/
```

The first runtime-owned mutation, not startup, performs migration. It atomically writes a canonical sidecar catalog, exact rollback copies of the legacy index/workspace documents, a digest manifest, and copies of runtime-owned legacy defaults. Legacy files/defaults are not deleted. Workspace creation and deletion are explicit revisioned runtime commands: creation commits an intent journal and document before catalog publication; deletion publishes a catalog tombstone before best-effort artifact pruning, so a stale legacy index cannot resurrect it. Explicit save publishes a pending-save journal before atomically replacing `workspace.json`, then finalizes the clean journal/revision sidecars; restart resolves a matching pending digest as committed and otherwise retains dirty rollback state. There is no startup normalization or bulk rewrite.

Each workspace and context carries independent `workingRevision`, `savedRevision`, and optional `dirtyRevision`. Commands carry operation IDs plus optional catalog/workspace/context CAS expectations. Applied and unchanged operation results are durably deduplicated across restart and indexed across the whole profile; exact create retries also finish a crash-recovered catalog publication. Operation-ID reuse with different input fails closed.

N writers coordinate through bounded, cancellable nonblocking `flock` acquisition, durable catalog/workspace/context revision CAS, atomic temp-file/fsync/rename commits, catalog reconciliation, and periodic external reload. Blocking file and lock work runs on a dedicated utility queue rather than the authority actor. External polling probes the catalog revision before doing full catalog recovery and checks each known document digest without publishing when nothing changed. Clean external changes become a new saved/working revision. A dirty workspace enters explicit external-conflict state with app-callable refresh plus accept-external/keep-working resolution. Corrupt or future documents/journals/catalogs retain the last decodable saved document and make the affected authority read-only rather than silently resetting data.

## Snapshot, routing, and presentation contracts

Workspace subscriptions bootstrap before returning their atomic initial snapshot and then publish monotonic events. Consumers detect sequence gaps and refresh the full snapshot. M3 adds an awaited transient read-registration overlay on this authority: unsaved, ephemeral, and test workspace documents are immediately routable but absent from the durable catalog, failed canonical commands retain the overlay, and any later applied/deduplicated canonical create or replace supersedes it even when the canonical bytes differ. The app bridge refuses a pre-bootstrap projection, decodes changed documents through the app's canonical normalization/migration path, retains the previous complete snapshot on decode failure, and applies immutable models on `MainActor`. Working-state capture is coalesced, explicit save supersedes a queued capture, and save preserves stale-state retry, repo-path merge, decode-cache invalidation, and baseline semantics. Active-window choice remains a local presentation resolver rather than `NSWindow` or an active view model becoming domain truth.

Connection and window registrations are generation-fenced. Window incarnations are assigned monotonically by the runtime, connections (including immutable run-scoped bindings) are generation-fenced and explicitly unregistered, windows are unregistered before server teardown, and all routing state is cleared on runtime shutdown. Run-scoped bindings are immutable. `DomainRunLaunchToken` material is 256-bit random, host stores only its digest, and redemption is single-use, expiring, runtime-generation/principal/provider/PID checked, and revokes pending routing state on shutdown. Policy contents are not embedded in the token; provider/process handoff remains M3+.

`EditFlow.DomainRuntime.*` metrics carry runtime ID/generation, operation ID, workspace/context revisions, catalog revision, disposition, and byte count across runtime/backend/catalog/commit/projection phases. Bounded live validation exercised the projection/routing seam with diagnostics enabled, but this milestone does not claim a latency delta because the authorized relaunch was not a controlled performance benchmark.

## Parity and scope ledger

| M0 surface | M2 result | Later milestone boundary |
|---|---|---|
| workspace identity, roots, saved workspace JSON | runtime canonical document/catalog, explicit create/delete, deletion tombstones, authoritative file URLs across rename, and rollback-preserving lazy migration | protected root/storage-relocation policy in M4 |
| compose-tab selection, prompt, preset/bindings metadata | canonical context snapshots and independent revisions | consumed by shared read-provider handles in M3 |
| connection/window/run routing maps | generation-fenced coordinator; app maps are presentation caches | read-provider consumption completed in M3; direct host/backend remains M6 |
| child launch capability | production single-use token authority | provider/process token handoff in M3+ |
| app UI state | MainActor snapshot projection only | presentation cleanup in M7 |
| tool admission/approval | unchanged | protected mutation policy in M4 |
| AI/Agent providers | unchanged | M5 |

Out of scope for M2 itself: read provider migration, protected mutation policy, AI/Agent provider migration, direct standalone host/backend, child listener/credential handoff, and UI/cache cleanup. M3 subsequently completes the read-provider consumption boundary without changing the other exclusions.

## Gate evidence

Owner suite: `DomainWorkspaceContextAuthorityTests` covers bootstrap-gated subscription, no-startup-write migration, explicit create/delete and stale-index tombstones, pending-save crash recovery followed by edit/save, working/saved/dirty recovery, exact save, durable unchanged/applied dedup and collision handling, workspace and durable catalog CAS, context-CAS fail-closed behavior, cancellable off-actor lock contention, clean/dirty external reload, future-journal degraded mode, monotonic window reincarnation, explicit connection teardown, and one-use launch tokens. `WorkspaceSavePreparationTests` covers first-projection preservation, canonical bridge normalization, runtime stale-save retry/baseline behavior, domain-owned reload identity, and app-reachable conflict resolution. Product builds protect the presentation bridge and single-writer seam. Focused owner-suite validation protects the executable contracts, with broader root-suite coverage supplied by CI.
