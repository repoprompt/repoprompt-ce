# Shared Runtime Phase 2 Slice 1 Characterization

Date: 2026-06-05
Starting checkpoint: `7e686cf4df882826ece64c994fb834e1334a10c1` (`Establish shared runtime dependency boundaries`)
Scope: Slice 1 only; no commit, headless adoption, canonical-v2 writes, or Slice 2/3 ownership

## Delivered authority

- `RepoPromptCore` now owns the canonical persisted app workspace graph: workspace, compose/stashed tab, selection, preset, context-builder, copy, file-tree, codemap, git, files-tab, and line-range values.
- `EmbeddedWorkspaceCodecV1` preserves current app-v1 coding keys, including the legacy `discover` key, and reports normalization as decode metadata without writing.
- `WorkspaceRepository` owns index-order inventory, custom storage paths, decode caching, explicit saves/deletes, injected root/layout policy, diagnostics, and the Phase 1 migration seam.
- `WorkspacePersistenceWriter` is a process-shared actor with per-URL serialization, enqueue durability, flush-through-receipt cuts, stale-date suppression, newest-selection arbitration/merge, atomic replacement, neutral completion diagnostics, and recovery when a successful replacement supersedes an earlier failed write.
- `WorkspaceSessionController` is the authoritative `@MainActor` owner of ordered workspaces, active workspace ID, index projection, immutable snapshots, mutation transactions, dirty/save generations, selection revisions, repository baselines, and binding candidates. Hydration does not mint authoritative selection revisions, and stale save completions cannot advance either dirty state or repo-path baselines.

## App adaptation

- `RepoPromptAppCoreContainer` constructs one writer/repository graph and shares it with every app session controller through the app-owned `RepoPromptCoreHost`.
- `WorkspaceManagerViewModel` has read-only controller projections and routes load, create, rename, reorder, duplicate cleanup, delete, switching, root/preset/metadata updates, compose-tab lifecycle, selection persistence, and save completion through controller mutations or bounded transactions. Its save pipeline returns and flushes the exact receipt for the exact captured generation/payload before recording completion.
- `WorkspaceSessionObservationBridge` adapts immutable Core snapshots to Combine without exposing writable canonical storage.
- `WorkspaceSessionSelectionForwarder` temporarily satisfies the existing app selection-host seam and is explicitly marked for deletion in Slice 2. `WindowState` retains both the observation bridge and forwarder for the full window lifetime.
- App storage-root discovery, UserDefaults/Application Support policy, durability tracing, duplicate-cleanup result models, UI behavior, file/context runtime, MCP adapters, and prompt behavior remain app-owned.

## Frozen and deferred boundaries

- Phase 0 fixtures and characterization remain unchanged.
- `Sources/RepoPromptHeadless/**` and `Tests/RepoPromptHeadlessTests/**` remain byte-for-byte unchanged from `7e686cf`.
- The app is the only production constructor/consumer of `WorkspacePersistenceWriter`, `WorkspaceRepository`, and `WorkspaceSessionController`.
- No `CanonicalWorkspaceCodecV2` production selection or v2 write path is present.
- No Slice 2 file/context/search/selection/codemap/syntax ownership or Slice 3 rendering/MCP/prompt ownership moved.

## Supporting files outside the primary move table

- `WorkspaceIndexEntry` was added to the existing Core repository contracts because app-v1 index inventory is required by the concrete repository/controller.
- `MCPConnectionManager+DebugDiagnosticsWorkspace.swift` was retargeted from the removed nested app writer to the process-shared Core writer so existing diagnostics continue to compile and observe the same durability boundary.
- Persistent MCP integration fixtures that directly mutated the old writable manager array were converted to the public manager transaction API; no compatibility setter was added.
- The Makefile, source-layout/headless architecture locks, Phase 2 design, and a new Slice 1 boundary script were updated to make the ownership constraints permanent.

## Test coverage

Core coverage now includes:

- app-v1 key/round-trip/normalization warnings;
- side-effect-free repository loads and explicit-save-only persistence;
- index order, missing documents, custom storage paths, durable index completion, and concurrent merging index saves;
- every controller mutation family, generation ordering, dirty/save baselines, hydration revision neutrality, stale-controller selection arbitration, shared selection revisions, and binding candidates;
- serialized writes, flush cuts, cancellation durability, stale-date suppression, stale selection rejection, merging newer selection into newer disk state, and fail-first/succeed-second recovery.

App coverage now includes:

- immutable snapshot-to-Combine observation;
- app-only/shared process composition, retained bridge lifetimes, and no-v2 selection source assertions;
- no second writable manager authority and a gated manager save race proving stale generations cannot advance repo-path baselines;
- durability tracer attribution over neutral Core events;
- unchanged Phase 0 app/headless fixture behavior and root hydration/normalization characterization.

## Validation evidence

The complete documented Slice 1 gate passed in order:

- guardrails: `39761dc1-d28a-405d-873f-4402c2de1a47`
- repository: `c73a961b-f8cd-4811-8241-d200afa7d1e4`
- app-v1 codec: `2f41b1b2-ca6b-41bc-a581-9858bc9e4661`
- session controller: `788e593c-a355-4376-a28c-057c632d70a2`
- selection persistence: `20f86469-850a-4439-b56f-661472f31db4`
- root sync: `213e2dc3-3349-4aaf-810b-d3c88009655d`
- Phase 0 app/headless characterization: `c4b3f10f-083d-4f9d-b615-a857e2534f29`
- `RepoPrompt` build: `c96b57bc-05fc-4c77-bcdd-9b7ad996e217`
- `repoprompt-mcp` build: `151db1de-fb8b-4228-9b0e-220912522d94`
- `repoprompt-headless` build: `41aecf86-e12e-4663-ad54-718212c5e0ee`
- headless smoke: `f04bf2ac-3ea7-417f-964e-339bd7b81a0a`
- lint/format check: `1286387b-d21f-4ba2-9f3a-d79279af15c4`

Additional post-review regressions passed:

- persistence writer recovery: `c3bffcdb-6285-4b2b-a478-1f54269a242b`
- observation bridge: `dcc2233c-43f8-4705-818d-62af1f4d5434`
- app composition, lifetime, and gated save race: `06b0c47d-9cc6-435a-bb43-f802795bde09`
- app durability diagnostics: `f6f786fc-f8e5-438e-a560-d4cbde44893b`
- mutating Swift format: `716b4618-74ff-4e62-b3ef-6ad9e8b7436a`

The first blocking Context Builder review (`slice-1-review-604A48`) identified five issues, all fixed before the gate: exact receipt/generation save completion, serialized durable index merging, hydration-neutral selection revisions, retained window bridge lifetimes, and superseded writer-failure cleanup.

A broader full-suite run (`5ad83952-5a35-4c2d-b9ce-f215e1a45e96`) reproduced a pre-existing source-guard failure and later stopped making progress, so it was canceled. The isolated blocker is `8cb8ae55-c514-45fc-9332-cb6884e4b10e`: `MCPReadSearchLatencyDiagnosticsGuardTests/testExactReadAndBootstrapAttributionHooksRemainOwnedCoarseAndDirect` expects `handshakeSocket.transferOwnershipIfOpen(`, but that hook is already absent at checkpoint `7e686cf`; neither the test nor `MacOSBootstrapSocketServer.swift` is in the Slice 1 diff.

The final blocking Context Builder review (`slice-1-review-33883C`) identified additional persistence edge cases. Before the final gate, Slice 1 was updated to suppress selection revisions for hydration mutations, reserve every receipt for its exact payload, propagate direct document/index write failures before side effects, arbitrate revisions for all compose-tab selections (including inactive tabs), make observer cancellation publication-safe, route app index writes through the canonical repository, and use collision-resistant opaque per-URL diagnostics correlation. The focused post-review tickets were controller `2562df50-c471-4e61-8d9c-7a9bff1baa6a`, selection `b9490dae-cc21-4c45-a1be-df9ddb4428e9`, writer `7820c418-2ed6-4697-bb58-552fc0fcbe49`, repository `6d76db35-0fea-438c-878c-0b9c1bae7124`, and app composition `df9df5d3-1f7c-4236-b781-42e4a72b7c9e`.
