# Shared Runtime Phase 1 Boundary Characterization

Date: 2026-06-05
Starting checkpoint: `48a335e0f65655b6ffe39018ea7e899c02108a5a` (`Freeze shared runtime parity baseline`)

## Scope

Phase 1 establishes dependency and contract boundaries only. It does not switch the app or headless production runtime to shared Core implementations.

## Landed boundaries

- `RepoPromptShared` contains only Foundation bootstrap/control wire contracts.
- `RepoPromptPOSIXSupport` owns the existing descriptor close-on-exec and socket shutdown helpers without changing their implementation or callers' error text.
- `RepoPromptCore` no longer depends on Shared or the native C/PCRE/syntax targets; the app retains those dependencies because it still has the real importers.
- Core process descriptor failures carry neutral operation, label, descriptor number, and errno fields.
- Core contains generic workspace codec, repository, layout, diagnostics, and legacy-migration contracts. No concrete app/headless workspace model or codec moved.
- Core contains immutable tool capability policy, final session tool-name/group vocabulary, and neutral session identifiers. Current app tool catalogs remain unchanged; app-local typealiases preserve existing session call sites.
- The app-proxy admission boundary carries an opaque accepted-transport lease. The app-owned implementation preserves listener ownership, admission reservation, accepted-response-first transfer, synchronous lifecycle-ledger publication, deferred startup, rollback, close-once, and full-stop draining.
- SwiftPM exposes only the three executable products. Core, CoreMacOS, POSIXSupport, and SyntaxBridge remain package-internal implementation targets.

## Frozen behavior evidence

`Scripts/test_shared_runtime_phase1_boundaries.py` byte-compares every `Tests/SharedRuntimeConvergenceFixtures/Phase0/**` file, the Phase 0 characterization, and its script against checkpoint `48a335e`. Phase 0 fixtures and expectations are not rewritten.

## Deferred constraints for Phase 2

- Do not move or replace `WorkspaceModel`, the app repository/controller, workspace-context store, search, selection, slices, token accounting, codemap, syntax, or prompt implementations before their injected roots/watchers/diagnostics and publication barriers are ready.
- Do not implement `EmbeddedWorkspaceCodecV1`, `HeadlessWorkspaceCodecV1`, `CanonicalWorkspaceCodecV2`, canonical v2 writes, or legacy migration execution as part of the boundary work.
- Do not switch app/headless tool catalogs, descriptors, normalization, DTOs, formatting, routing, or capability composition to the new vocabulary yet.
- Keep `RepoPromptCorePlatformDependencies` and the static process facade until the later call-site injection phase; only its watcher factory is currently consumed by the app-owned session host.
- Keep app-proxy listener/Unix transport mechanics app-owned until the dedicated CoreMacOS move. The Core contract must remain opaque and direct stdio must remain separate.
- Temporary app aliases for Core session identifiers may be removed only when the host/session implementation moves to Core.

## Validation

All validation completed without launching the app:

- Phase 0 artifact script: `python3 Scripts/test_shared_runtime_phase0_characterization.py`
- Phase 1 boundary script: `python3 Scripts/test_shared_runtime_phase1_boundaries.py`
- Coordinated guardrails: ticket `729cf16a-99b2-4fcd-ae56-191490513ecb`
- Coordinated builds:
  - `RepoPrompt`: ticket `8658d922-4a71-408d-b449-a81adbf83772`
  - `repoprompt-mcp`: ticket `2bdf45a6-17a7-4406-b213-164bf1c2b0cf`
  - `repoprompt-headless`: ticket `7e610304-e3c6-4c24-8196-ad2db8340fb6`
- Focused tests:
  - Core Phase 1 contracts: `b439de4f-6bca-4e22-9595-b93993aaaf0c`
  - POSIX descriptor support: `2132ea51-b3ed-41f7-bf09-30cdb51a2b8f`
  - opaque accepted-transport lease, including reentrant publication rollback: `667cc5c9-18c1-4cbd-b158-ab3d5ffb18bd`
  - socket descriptor/rollback lifecycle: `c8d92dd2-cb20-407d-b217-33b2e5864890`
  - process descriptor inheritance/SIGPIPE: `3545e945-933d-4a63-b196-67eda5629f90`
  - bootstrap wire contract: `3088e122-9740-4add-b10b-cb77fe29c50f`
  - app Phase 0 no-rewrite characterization: `ce529cb8-abed-49ea-aa93-a5f8026d8a11`
  - headless Phase 0 no-rewrite characterization: `5621ed2e-011b-45d4-85e6-e77c252e8769`
- Coordinated lint: ticket `634f885d-e05e-4cc2-a5e4-b30f043ed63a` (0 violations)
- Coordinated headless direct-stdio smoke: ticket `c59ea1dd-9a83-46d6-a1ba-ffc4033e039e`

The required final Context Builder review ran in chat `phase-1-review-708F5C`. Its publication reentrancy and guardrail findings were resolved before the final validation tickets above.
