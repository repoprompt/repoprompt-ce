# Shared Runtime Phase 2 Slice 2 Characterization

Date: 2026-06-05
Starting checkpoint: `8750dc4` (`Update transport lease source guard`)
Ownership checkpoint: `de21a1e` (`Move file context runtime into RepoPromptCore`)
Scope: Slice 2 only; no Slice 3 prompt/rendering/MCP ownership and no headless adoption

## Delivered ownership

- `RepoPromptCore` owns the complete neutral filesystem/catalog/path/search/selection/slices/token-accounting/codemap/syntax closure on top of the Slice 1 workspace/session authority.
- `RepoPromptCoreMacOS` owns workspace directory listing and FSEvents watching behind injected Core contracts.
- Native Core dependencies exist only for real moved importers: RepoPrompt C search/path helpers, PCRE2, the syntax bridge, SwiftTreeSitter, UniversalCharsetDetection, and Cuchardet.
- `RepoPromptEmbeddedWorkspaceRuntimeFactory` is the sole production factory. `RepoPromptCoreHost` receives the constructed dependency bundle rather than selecting platform defaults.
- The temporary Slice 1 selection forwarder and obsolete app runtime source paths are deleted.

## App adaptation

The app retains only product policy and adaptation:

- CoreMacOS directory-listing and watcher construction;
- file mutation authorization/backend behavior;
- diagnostics, latency attribution, readiness, and partition-event adaptation;
- Combine publication and app observation;
- Application Support/cache-root selection;
- `FileViewModel`/`FolderViewModel`, root-binding, and search-result conversion;
- prompt/rendering and MCP provider/catalog/DTO/formatter/dispatch ownership reserved for Slice 3 or Phase 3.

## Preserved behavioral barriers

- FSEvents callbacks retain accepted-sequence/watermark freshness and generation-scoped start/stop ownership.
- Root unload detaches catalog/search state before awaited watcher teardown and drains accepted publisher ingress without permitting post-detach mutation.
- A stale stop reconciliation cannot tear down a newly restarted watcher or its replacement ingress generation.
- Store-backed search retains bounded admission and content-fetch backpressure, catalog snapshot invalidation, path alias/wildcard behavior, and telemetry adaptation.
- Selection persistence, slice rebase behavior, token accounting, codemap extraction/goldens, and app acceptance state remain unchanged.

Validation exposed two teardown-order regressions after the physical ownership move. The validation tranche fixes them by detaching root/search state before awaited watcher shutdown and by making detached watcher cleanup generation-aware. The diagnostics source guard now locks the new Core ordering and owner paths.

## Frozen and deferred boundaries

- Every byte under `Sources/RepoPromptHeadless/**` and `Tests/RepoPromptHeadlessTests/**` remains identical to `7e686cf`; headless does not construct the Slice 1/2 runtime.
- Every Phase 0 fixture byte remains frozen. App-v1 decode/load stays side-effect free and canonical-v2 writes remain inactive.
- Prompt assembly/rendering, workspace-context projection, MCP safe-tool providers/catalog/descriptors/normalization/DTOs/formatting/dispatch, app-proxy transport, and standalone adoption did not move.
- App mutation policy, diagnostics/telemetry, readiness, UI state, Application Support/UserDefaults policy, and visible-app lifecycle remain app-owned.

## Focused validation evidence

- Guardrails before validation hardening: `831d9be0-c54e-4a57-b1f3-19c06b421b0e`.
- `WorkspaceSelectionControllerTests`: 6 passed (`22a13b07-8e5b-4320-9720-ae2c6dfa14e1`).
- `WorkspaceFileContextStoreTests`: all test groups passed through bounded filters. The monolithic class filter repeatedly stopped progressing after 56 passing tests, so the same class was completed by deterministic method-prefix groups; no test was omitted. Key regression reruns include immediate search-snapshot detach (`8572788b-8892-4205-8f3f-c886ae800357`), unload ingress drain (`b6c66884-a072-4806-8808-18295d341bec`), and stop ingress drain (`171329bd-7ce9-436a-90c5-1e2e3d4e876e`).
- `WorkspaceSearchServiceTests`: 12 passed (`5960160e-fc34-45da-9cbc-95e2811929d1`).
- `StoreBackedWorkspaceSearchTests`: 33 passed (`ed78ec43-61bd-46a5-8b77-d69796071f63`).
- `SelectionSlicePersistenceAndRebaseTests`: 3 passed (`5a85ac44-e8f0-4c08-9b26-dd0cd378172d`).
- `TokenCalculationServiceTests`: 4 passed (`ca05cdd4-1022-4683-8593-50f14b64e265`).
- `CodeMapGoldenTests`: 4 passed (`3c5c2e7b-e392-4136-8578-9c1e64ac76cf`).
- `FileViewModelAcceptedCodeMapTests`: 2 passed (`4f95fba3-18f0-4afd-8a63-467919d88809`).
- `MCPReadSearchLatencyDiagnosticsGuardTests`: 50 passed (`c7307237-a3d1-418a-a52f-73cc173ec1db`).
- `FileSystemAcceptedIngressBarrierTests`, `MacOSFSEventsWatcherTests`, and the watcher restart/stop/unload race regressions passed in the coordinated validation sequence.

## Broad validation evidence

- Refreshed guardrails: `e6b7ad16-4a59-4f57-b071-0e05c8d8550e`.
- Product builds: `RepoPrompt` `d52a3bda-9ade-4ba4-8b36-f546808227bb`; `repoprompt-mcp` `2ba8c1c8-22c5-43d4-a315-4982014a7a61`; `repoprompt-headless` `0e25442a-d046-4c8b-9a30-e8cb2dfb94ec`.
- Debug app package/helper validation: `79a4412e-1cf0-461e-8fc7-18231b8f48bd`; the app was not launched.
- Direct-stdio headless smoke: `4bed73a3-5171-4a32-a06b-bce36e6e71d6`.
- SwiftFormat normalization of the moved Slice 2 files: `3a935fec-bffc-4e35-8e79-8d6c753fda7e`; lint then passed with 0 violations: `1110d28d-d4c8-4993-8ecb-08f8f406f4ad`.
- Target-wide broad shards passed: all `RepoPromptCoreTests` (`c2a8c038-d4c5-4230-89d4-ddb1aa5f470d`), all `RepoPromptCoreMacOSTests` (`196c02ee-645b-49fa-bd11-c0ecf8e3d691`), all frozen `RepoPromptHeadlessTests` (`5928dfe5-425f-45e2-b82c-98aeb82c3862`), and all `RepoPromptPOSIXSupportTests` (`1ebbfae5-7b3e-4fe2-ac25-a3aa678d0dab`).
- App adaptation/lifecycle coverage passed: Core host lifecycle `ec0cc04d-002b-4d01-b36e-a869105c9fac`; workspace composition `6c5ff2ea-c56a-4b1e-8175-464c7206bfd1`; content loading concurrency `d6d05577-3d3a-4328-b208-5045202f4227`; selection coordinator `d0c4ffaf-d5a0-4a11-990b-afcad326a477`; workspace loading diagnostics `f9921f80-ebf3-4808-a726-1005f54cbef1`; path/search/ignore recovery `f3a60fb5-afd6-4574-bad0-80686bb3dd2a`, `41becc9c-7947-458d-9b0a-53e92aa0309a`, `2555f8cb-2cd9-484e-953d-6ccb75fb05bd`, and `b2e66f97-0bc7-4d59-b7ef-907b78669aed`.
- Provider package broad tests passed: `a67cb2fe-1617-43b8-8d82-f02bc5a6b3e2`.

The first broad run exposed two moved Core-test fixture defects rather than production failures: the neutral test runtime supplied no mutation backend and classified directory symlinks without preserving the followed-directory bit. `TestWorkspaceRuntime` now supplies a FileManager-backed mutation adapter and stable symlink metadata; the focused recovery suites pass (`be866d93-fe4f-4a68-a49c-b50ff2c11630`, `4fc27eeb-253c-4aeb-9eec-dcd37df1e8d0`). It also exposed one stale diagnostics source-owner path, now updated and locked by `f9921f80-ebf3-4808-a726-1005f54cbef1`.

A single-process unfiltered `make dev-test` was attempted three times. After the fixture failures were fixed, it stopped advancing at different app test-class transitions while the same classes passed immediately in isolation (for example `AgentPermissionSecureStoreTests`, `4aacb45f-d7ba-4b5b-a688-bd08744abc03`). Those runs were canceled only after their logs and inactive processes confirmed harness deadlock; target-wide Core/CoreMacOS/headless/POSIX shards and the Slice 2 app-adapter suites above provide the broad validation evidence.

## Final review

The blocking Context Builder review first completed discovery but exceeded the provider character limit with the broad branch package. It was rerun without cancellation using a focused 10-file merge-base artifact and completed in chat `phase-2-review-3EE516`.

The review found one P0 watcher lifecycle race: an older detached stop and a later restarted-then-stopped watcher could share the same ingress generation, allowing the older stop to reset the later lifecycle after its watcher had become nil. The first coherent fix set adds a distinct watcher lifecycle epoch, increments it for each real start attempt, captures it in `DetachedWatcherStop`, and requires it to match before destructive cleanup. A regression test proves a stale stop cannot discard accepted work from a later restarted-and-stopped lifecycle.

Post-review focused validation passed:

- accepted-ingress barrier suite, including the new lifecycle-epoch regression: `c1f7e79d-8f39-4680-8ecb-c66d6f620caa` (9 tests);
- store restart-vs-stale-stop regression: `04607acf-892b-4c3a-8fb0-c1e290e78818`;
- `RepoPrompt` build: `6e952bf5-ca3e-44c3-8fed-a820851d3ad2`;
- guardrails: `0267f9f0-aeff-4393-8a58-f45294c4cb90`;
- lint: `5e2129f9-b087-4acd-85c6-30ef7793271c` (0 violations);
- `git diff --check`: passed.

Per the tranche checkpoint rule, no second review or broader follow-on fix set was started after this P0 correction.
