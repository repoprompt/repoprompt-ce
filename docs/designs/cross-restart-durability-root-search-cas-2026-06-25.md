# Cross-Restart Durability for Content-Addressed Codemaps and Worktree Root/Search

**Date:** 2026-06-25
**Status:** must-ship design; implementation follows active C2 and serving integration boundaries

## Context and scope

The landed architecture already separates immutable Git/content identity from live filesystem authority:

- codemap artifacts are keyed by exact source bytes plus the full pipeline identity (`CodeMapArtifactKey.swift:280-360`);
- Git-blob locators are repository-scoped, path-free associations (`GitBlobCodeMapLocatorModels.swift:87-174`);
- root-neutral inventory/search snapshots cover tree, prefix, ignore/attribute/sparse policy, catalog policy, and search ABI (`WorkspaceRootSeedModels.swift:155-197,272-441`);
- exact namespace manifests include files, directories, empty directories, raw path bytes, type/mode, root device/inode, policy, ordered records, counts, digest, and exact EOF (`WorkspaceRootNamespaceManifest.swift:17-109,178-338,345-493`);
- creation receipts and pending authority fences deliberately bind a live watcher/Git handoff (`GitWorktreeInitializationModels.swift:91-145,198-318`);
- seeded publication starts a hidden watcher at a journal cut, replays accepted callbacks, and transfers ownership only after activation/finalization proofs (`FileSystemService+SeededInitialization.swift:4-96,98-154,210-347`).

The missing guarantee is downtime: a checksum proves that an artifact was internally valid when written, not that its worktree was unchanged while RepoPrompt was stopped. Restart is therefore **fresh authority acquisition with durable cache revalidation**, never continuation of a previous initialization. A second identity issue is equally important: current root/search authority uses a randomized process-local repository salt (`GitService.swift:12-18,4232-4241`), so neither `WorkspaceRootSeedCompatibilityKey.repositoryNamespace` nor `WorkspaceRootReusableSnapshotIdentity` is a stable disk lookup key. Durable archives require a separate installation-stable key and must be rebound into a newly computed process-local snapshot identity after fresh authority capture.

This track does not edit or depend on the active C2 working files (`GitService.swift`, `GitTargetEvidence*`, streaming parsers/tests). It also does not change ordinary non-Git loading or make codemaps available for non-Git roots.

## Findings: durability classification

| Artifact | Persist? | Cross-restart authority |
|---|---|---|
| `CodeMapArtifactContainer` | **Yes; already durable** | Authoritative only for its exact `CodeMapArtifactKey` after verified read. It does not prove any current path binding. |
| Git-blob locator record | **Yes; already durable** | Reusable after codec, locator identity, and CAS verification. Fresh Git evidence must prove the current path still resolves to that blob. |
| Existing `CodeMapRootManifestSnapshot` | **Candidate only** | Its worktree/root namespace is useful, but its live authority/binding generations cannot authorize a new process. Rebind clean records under newly captured authority; never directly adopt the old live snapshot. |
| Root-neutral committed-tree inventory | **Yes; new durable archive** | Keyed by a new installation-stable durable repository namespace plus object format, tree OID, root prefix, schemas and policies. After exact fresh matching, rebuild the current process-local compatibility/snapshot identities; never compare the archived process-local namespace verbatim. |
| Relative search base | **Yes; canonical input only** | Persist sorted relative path bytes and stable ordinals. Rebuild the current in-memory `PathSearchIndex`; its present runtime representation is not a durable ABI (`WorkspaceRootSeedModels.swift:253-270`; `PathSearchIndex.swift:261-850`). |
| Exact namespace manifest | **Yes; candidate only** | Persist an authenticated content object for equality/reuse selection. Always produce a new exact manifest under a fresh watcher after restart. The fresh manifest is authoritative. |
| Immutable tree-to-tree Git delta | **Eligible after C2, not v1 must-ship** | May later persist only after stripping attempt/cut/generation state and keying by both tree OIDs, prefix, object format, policy/command ABI, and environment. |
| Index/status evidence, raw Git spool | **No restore authority** | Recollect on every restart. Old private files are abandoned-workspace garbage or diagnostics only. |
| FSEvents IDs/cuts, accepted watermarks | **No** | Journal IDs and service watermarks are different domains; neither is serialized as a restart credential (`FileSystemService+SeededInitialization.swift:4-10`). |
| Creation receipt/materialization hint | **No** | Session-, uptime-, binding-, path-, and watcher-bound; receipt lifetime is 60 seconds (`GitWorktreeInitializationModels.swift:198-318`; `WorkspaceRootSeedModels.swift:455-535`). |
| Authority lease/fence/metadata token | **No** | Bound to live actor generations and metadata observation (`GitWorkspaceStateAuthority.swift:136-176,292-368`). |
| Target seed plan/evidence handle, replay/activation/publication proof | **No** | Private transaction state for one watcher generation and publication attempt. |
| Root/session ownership and root lifetime IDs | **No** | Recreated per process/session; agents receive claims, never durable authority. |

Unsound shortcuts are explicitly forbidden: reopening an old FSEvents cut; trusting a checksummed namespace, index, or status artifact without covering downtime; publishing a persisted seed plan under a new fence; treating a locator as proof of a current path; or accepting an old root manifest by fuzzy generation comparison.

## Durable schema and identity

### Store layout

Add an owner-only, build-flavor-separated root under Application Support:

```text
WorkspaceDurableArtifacts-<build-flavor>/
  v1/
    objects/<family>/<first-2-hex>/<sha256>
    locks/<family>/<first-2-hex>/<sha256>.lock
    catalogs/<family>.catalog
    quarantine/
```

Every immutable object uses:

```text
magic | schema | family | canonical identity
sorted length-framed records
footer(record counts, payload bytes, SHA-256(header + record frames))
exact EOF
```

Aggregate record count is `UInt64` accounting, never a correctness limit. Per-frame/path bounds, disk reserve, open-descriptor fan-in, and memory buffers are security/resource controls. Quota refusal means “do not persist”; it never changes live root correctness.

### Artifact families

1. **`root-inventory-v1`**
   - Durable identity: `WorkspaceDurableRepositoryNamespace` (installation-private persisted salt + resolved common-directory identity), object format, tree OID, root prefix, inventory schema, complete Git/catalog policy identities, and search ABI. Do not store the process-random `WorkspaceRootSeedCompatibilityKey.repositoryNamespace` as the lookup authority.
   - Records: raw relative-path bytes, ordinal/parent ordinal, mode, Git kind/object ID, committed-tree provenance, catalog projection.
   - On read, match every stable field to freshly captured authority, then construct a new `WorkspaceRootSeedCompatibilityKey` and recompute the current-process `WorkspaceRootReusableSnapshotIdentity` with `workspace-root-reusable-snapshot-v3`. The outer archive object has its own framing digest.

2. **`root-search-base-v1`**
   - Identity: root-inventory digest plus exact search ABI.
   - Records: searchable relative-path bytes and stable inventory ordinal.
   - No serialized `PathSearchIndex`; rebuilding it isolates future matcher implementation changes behind the existing ABI fields (`GitWorktreeInitializationModels.swift:25-36`).

3. **`worktree-namespace-v1`**
   - Identity: resolved physical root path bytes, device/inode, Git worktree identity, loaded-root prefix, exact catalog policy, namespace schema.
   - Records retain current `WorkspaceRootNamespaceRecord` byte/type/mode semantics.
   - The object digest is a comparison key, not freshness authority.

4. **`codemap-root-candidate-v2`**
   - Identity: repository namespace, object format, stable Git worktree identity, loaded-root prefix, tree OID, binding/layout/index/config/ignore/attribute/sparse semantic digests, pipeline/schema/policy versions.
   - Records: repository-relative path bytes, Git mode, locator identity, artifact key/outcome, and contribution envelope.
   - Exclude process-local `authorityGeneration`, source binding generation, live overlay state, leases, and adoption IDs. Restore constructs newly verified live records under new authority.

Storage filenames are path-free SHA-256 values. Physical path bytes remain inside 0600 objects solely to reject alias/replacement mismatches. Codemap objects retain the existing installation-salted `GitBlobRepositoryNamespace`. Root/search archives use their own `WorkspaceDurableRepositoryNamespace`, derived from a persisted private salt owned by the durable-artifact store plus the freshly resolved common-directory identity; it is deliberately distinct from the current process-random workspace-authority namespace. Worktree-local objects additionally require a freshly resolved real path, device/inode, Git directory identity, and worktree ID. Standardized-path equality alone is insufficient.

## Restore protocol: fresh watcher and Git proof

One restore flight exists per **physical root**. Its join key is resolved root path/device/inode, common-dir and worktree-gitdir identity, root prefix, repository namespace, catalog policy, and search ABI. Session ID, correlation ID, and waiter deadline are not part of the key.

1. **Discover candidates securely.** Validate current-version roots, files, catalogs, and locks. Quarantine corrupt current-schema objects; ignore old schemas without decoding.
2. **Start a new hidden watcher.** Capture the current journal position, create the stream, synchronously flush it, cross its callback-queue barrier, pause ordinary draining, and retain the new watcher generation plus accepted watermark. No persisted cut is accepted by this API.
3. **Capture fresh Git authority.** Re-resolve `.git`/`commondir`, worktree identity, object format, HEAD/tree, index, sparse/config/ignore/attribute digests; retain a new metadata observation and pending authority fence. Independently derive the installation-stable durable repository namespace from the resolved common directory; never substitute it for the live process-local authority namespace.
4. **Cover downtime exactly.** While the watcher is live, stream a new exact namespace manifest using ordinary crawler semantics. Recollect index and status under the new fence. Git is an explicit-boundary proof, not a polling freshness loop.
5. **Admit immutable candidates.** Locate root inventory/search input by the durable namespace and require exact fresh equality of every remaining semantic field. Rehydrate records into a new process-local compatibility key/snapshot identity before they enter `GitWorkspaceStateAuthority`. A namespace candidate may be byte-compared to the new manifest, but the new manifest remains the source of truth. Rebind codemap root records only where fresh Git and namespace facts prove the same clean blob/mode/path and the locator/CAS pair verifies.
6. **Build private topology/search.** Reuse the immutable base, apply fresh target evidence and fresh namespace, and rebuild the matcher from canonical search input. Public root/tree/search/read state remains single-tier and private until exact folder topology—including empty directories—is complete.
7. **Close the live interval.** Flush/barrier again; capture a final accepted watermark; replay every accepted payload through that cut. Reject gaps, collapsed rescan sentinels, drops, wrap/regression, unsafe flags, root replacement, generation mismatch, or unpublished service work.
8. **Revalidate and publish once.** Require the Git fence, metadata watermark, root identity, watcher generation, replay watermark/service sequence, catalog generation, and ownership claim to remain current. Publish root/catalog/search/watcher ownership through the existing atomic store transaction.
9. **Refresh durable candidates after success.** Durable writes are post-publication cache work. Their failure cannot roll back a correct live root.

Compatible inherited agents join this flight and receive small claims. One cancelled/deadline-expired waiter detaches; the producer continues while another waiter remains. Last-waiter cancellation tears down private watcher/evidence. Eight agents must produce one watcher, namespace scan, Git evidence set, topology build, and matcher per physical worktree—not eight copies. Separate app processes may share immutable disk objects but must acquire independent watchers, Git fences, and live roots.

## Atomic publication, leases, GC, and schema deletion

### Publication and crash safety

For each immutable object: create an `O_EXCL|O_NOFOLLOW` 0600 temporary on the destination filesystem; stream and digest; `fsync` it; validate header/records/footer/EOF through that same descriptor; publish with no-replace rename under the digest; byte-verify an existing destination before coalescing; then `fsync` the containing directory. Mutable catalogs/pointers publish last by temp-file replace and directory sync.

Crash before rename leaves untrusted temporary garbage. Crash after object rename leaves a complete discoverable-or-orphan object; a missing catalog update is repaired by bounded reconciliation. Same digest with different canonical bytes is an integrity collision: quarantine both candidates and disable that cache family for the process.

### Leases and GC

- Readers retain the validated object descriptor and a stable per-object lock file under `LOCK_SH`.
- Publication, quarantine, and GC require `LOCK_EX`; GC uses nonblocking acquisition and skips busy objects.
- Kernel lock release on process death is the only crash recovery for leases; never persist PID/refcount authority.
- Mutable namespace catalogs use their own lock and compare-and-swap predecessor digest.
- GC is quota/age-driven mark-and-sweep: catalogs mark root/search/namespace candidates; codemap-root candidates mark locators; verified locators mark CAS objects. Sweep candidates move to quarantine, directory-sync, observe a grace period, then delete only under an exclusive lease and unchanged descriptor/path identity.
- `.tmp`, `.work`, and raw-spool cleanup validates owner, 0600/0700 mode, regular type, link count one, device, and unchanged inode before removal.

The security/publication model should generalize, not import, the proven patterns in `CodeMapArtifactFileStore.swift:109-180,298-418,612-747`, `CodeMapRootManifestStore.swift:650-760,1132-1209`, and `SpillBackedSortedArtifactStore.swift:220-355,395-550`.

### No-compatibility migration

New code reads only `v1` (and codemap candidate `v2`). It never imports or rewrites an older root/search/namespace archive. Under the maintenance lock, rename each obsolete version directory to a private deletion name, sync the parent, and delete descriptor-relatively. Unsafe deletion leaves an ignored quarantine directory. These are regenerable caches, not user data. Existing codemap CAS/locator schemas remain only if their canonical identity bytes are unchanged; the old live-authority root manifest is not a restart format.

## Security and corruption policy

- Require 0700 owner directories; 0600 owner regular files; link count one; expected device; safe components; `O_NOFOLLOW`; descriptor-relative traversal; and stable descriptor/path identity before and after reads.
- Join and sort on raw path bytes. Reject byte-distinct/canonical-equivalent collisions before converting to `String`-keyed runtime structures.
- Artifacts need integrity and isolation, not encryption. They stay local under Application Support and are never exported or logged with paths/source bytes/tokens.
- Validate all “generation” fields used durably as canonical semantic digests. Process counters, uptime, timestamps, stat-only fingerprints, and watcher watermarks cannot authorize reuse.
- A corrupt candidate is never partially consumed into visible state. Derived artifacts stay unpublished until every source reader reaches authenticated EOF.

## Exact fallbacks

| Condition | Result |
|---|---|
| Candidate absent, evicted, schema/ABI mismatch, or fresh namespace differs | Cache miss; continue from fresh watcher/Git/namespace evidence. Rebuild only the missing derived state. |
| Candidate checksum/footer/identity failure | Quarantine; continue as cache miss. |
| CAS corruption | Quarantine; rebuild that codemap on demand. |
| Locator failure/staleness | Ignore locator; classify fresh blob and use/build CAS. |
| Codemap-root authority mismatch | Do not adopt the manifest; optionally reuse independently verified locator/CAS entries. |
| Durable cache ENOSPC/quota/lock contention | Skip durable read/write; live loading may continue. |
| Fresh watcher cannot start/flush/barrier, or reports gap/drop/wrap/regression/root change/unsafe flags | Abort durable seeded route; use the unified authoritative full loader. |
| Fresh Git authority invalidates once without semantic change | Discard private mutable evidence and perform the existing one-shot recapture/rebuild. |
| Changed authority or second invalidation | Unified full loader. |
| Exact namespace acquisition/root-policy fence fails | Unified full loader; persistent permission/I/O failure becomes the ordinary root-load error. |
| Root/gitdir inode or physical identity changed | Reject all worktree-local candidates; restart the flight for the new root or full-load. |
| Search archive corrupt but inventory valid | Rebuild search input/matcher from inventory; root topology may still proceed privately. |
| Old-schema deletion fails | Disable/ignore that schema family; never read it. |
| Non-Git root | Existing full filesystem root/search path; zero Git/codemap work. |

No repository/file/directory count triggers a correctness fallback. Buffer, descriptor, disk, and concurrency limits apply backpressure, spill, or admission; resource exhaustion may select the ordinary full loader but never truncate evidence.

## Implementation slices independent of C2

These slices own new files only and can run alongside serving integration. Agree on the small `DurableArtifactStore` protocol first; slices 2 and 3 then proceed in parallel.

### Slice 1 — generic durable object/lease/GC substrate

**Ownership**

- `Sources/RepoPrompt/Infrastructure/Persistence/DurableArtifacts/DurableArtifactStore.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/DurableArtifacts/DurableArtifactLease.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/DurableArtifacts/DurableArtifactInstallationIdentity.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/DurableArtifacts/DurableArtifactSecureIO.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/DurableArtifacts/DurableArtifactGarbageCollector.swift`
- `Tests/RepoPromptTests/Persistence/DurableArtifacts/*`

**Done when:** atomic no-replace publication and collision detection; same-descriptor validation; shared/exclusive cross-process leases; secure load-or-create installation salt and deterministic durable repository namespace; crash-point recovery; quarantine/GC; direct old-version deletion; no domain models and no count correctness caps.

### Slice 2 — root inventory/search/namespace archives

**Ownership**

- `Sources/RepoPrompt/Infrastructure/Persistence/WorkspaceRootArtifacts/WorkspaceRootInventoryArchive.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/WorkspaceRootArtifacts/WorkspaceRootSearchBaseArchive.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/WorkspaceRootArtifacts/WorkspaceRootNamespaceArchive.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/WorkspaceRootArtifacts/WorkspaceRootArtifactStore.swift`
- `Tests/RepoPromptTests/Persistence/WorkspaceRootArtifacts/*`

**Done when:** deterministic streaming codecs round-trip current immutable models; root/search digest recomputation is exact; namespace is typed only as a candidate; 100k routine and opt-in 1M artifacts use bounded memory; corruption and old schemas fail before publication/consumption.

### Slice 3 — codemap restart candidate archive

**Ownership**

- `Sources/RepoPrompt/Infrastructure/Persistence/CodeMapArtifacts/CodeMapRootRestartArchiveModels.swift`
- `Sources/RepoPrompt/Infrastructure/Persistence/CodeMapArtifacts/CodeMapRootRestartArchiveStore.swift`
- `Tests/RepoPromptTests/CodeMap/CodeMapRootRestartArchiveTests.swift`

**Done when:** v2 deterministically excludes live generations/leases and can only return typed, non-serving candidate records; corruption/old schema fails closed; untracked/live-overlay state is not encodable. This parallel slice does **not** perform rebinding or consume C2 evidence.

**Explicitly not owned by these slices:** `GitService.swift`, `GitTargetEvidence*`, `GitStatusPorcelainV2Parser.swift`, `WorkspaceRootSeedPlanner.swift`, `WorkspaceFileContextStore.swift`, `PathSearchIndex.swift`, or their active C2 tests.

After C2 and serving integration settle, one serial integration change may connect the new stores through `WorkspaceRootReusableSnapshotCoordinator.swift`, new `WorkspaceRootRestartRestoreCoordinator.swift` and `CodeMapRestartCandidateRebinder.swift` files, `FileSystemService+SeededInitialization.swift`, and the existing private publication transaction. That change owns the adapter from C2's sealed fresh Git evidence into a small restart-evidence DTO; no parallel slice imports or fabricates that proof. It must not add a second publication path.

## Test and benchmark matrix

| Lane | Required cases |
|---|---|
| Restart correctness | No-change warm restore; downtime add/delete/rename; deep empty-directory add/delete; ignored/untracked/symlink/special changes; namespace unchanged but index/content changed; branch/ref/index/config/ignore/attribute/sparse changes; same path/new inode; mutation during scan and final barrier. Compare exact files, folders, empty folders, search ordering, reads, codemap graph, and watcher behavior with forced-full. |
| Git/worktree | Staged/unstaged/untracked/ignored, rename/copy/delete, conflict, assume-unchanged, sparse, submodule/nested repository; main plus two linked worktrees; moved/replaced/pruned gitdir; symlink aliases; repository common-dir replacement. |
| Forbidden authority | Inject persisted old cut, receipt, fence, status/index evidence, seed plan, replay proof, and process generation; prove none can authorize reuse. |
| Crash/atomicity | Terminate after temp write, file sync, rename, directory sync, and catalog swap. Restart yields old complete object, new complete object, or miss—never partial state. |
| Security/corruption | Symlink/hardlink/owner/mode/link-count/device/parent replacement; truncation/in-place mutation/trailing bytes/count overflow/digest collision; reader-vs-GC and two-process publication races; old schema ignored/deleted without decode. |
| Leases/GC | Shared reader blocks sweep; crashed reader releases kernel lock; busy objects skip; mark loss causes cache miss only; quarantine grace; abandoned work/raw spool cleanup; quota and minimum-disk behavior. |
| Concurrency | 1/2/4/8/16 same-root sessions produce one restore flight per process; eight distinct worktrees remain admission-bounded; two app processes share immutable objects but have separate watcher/Git proof. Cancellation/deadline/last-claim teardown leak nothing. |
| Scale | Routine 100k and opt-in 1M files; 2,048+ spill runs; path-heavy all-changed and empty-directory-heavy fixtures; bounded 16–64 MB configurable working set; no root-sized per-agent `Set<String>`/path copies. |
| Performance | Cold full baseline; warm process/no restart; cold app restart with durable CAS only; + root inventory; + search base; + namespace equality; 1/2/4/8 agents; main/linked worktree; freshly relaunched and aged app. Record p50/p95 root-ready, first search/read/codemap, CPU, peak RSS, bytes read/written, Git commands, stats, watcher events, fallback, and cleanup. |

Shipping retains the enterprise gates from the work log: exact parity and no stale publication; no cardinality correctness cliff; projected/restart p95 at least 40% faster than forced full on the representative large fixture; unrelated foreground p95 regression at most 5%; peak-memory regression at most 10%; zero leaked locks, artifacts, watchers, flights, or authority observations; and exact fallback telemetry. Durable restore remains disabled until those gates pass in the shipping build.

## Recommendation

Ship durability as a cache layer around the existing proof protocol, not as persisted proof. Land the generic durable substrate first, implement root/search/namespace and codemap candidate archives in parallel, then perform one serial restore integration after C2. The restore fast path is valid only when a new watcher covers the entire validation interval, fresh Git authority proves tracked state, a newly enumerated namespace covers downtime and empty-directory topology, and the existing atomic publication fence succeeds.
