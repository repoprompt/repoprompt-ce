# Headless MCP domain runtime M7 — conservative cutover contract and correction evidence

Date: 2026-07-28

Branch: `feature/headless-runtime-m7-cutover`
Base: finalized M6 head `d3677c3e82d171affe08d35587e0bd9bd4561b0f`
Review addressed: `docs/reviews/headless-runtime-m7-cutover-prepush-review-2026-07-28.md`

## Backend contract

`repoprompt-mcp` accepts `--backend app|headless|auto`; MCP stdio continues to default to `app`. The default must not move to `auto` until explicit live and release evidence demonstrates app-available/no-app behavior, state continuity, retries, and latency.

`auto` remains an explicit preview mode. Selection is made exactly once before the first `initialize` read:

- explicit `app` and `headless` never probe;
- explicit `auto` performs one bounded, connect-only probe of the well-known app socket;
- an available app selects the existing proxy/reconnect path;
- an unavailable app selects the M6 direct runtime;
- no initialized process retries or switches backend;
- interactive and exec modes are app-only and reject explicit `headless` and `auto`;
- bare backend values and duplicate backend options fail with usage status.

The probe verifies a Unix socket node, connects with a 150 ms bound, transmits no protocol bytes, closes its descriptor, and never examines the private M6 child endpoint. All app-generated MCP configurations, including provider child configuration, explicitly pass `--backend app`.

## Canonical state and workspace semantics

Default headless mode uses the canonical RepoPrompt CE application-support root and the same workspace storage root selected by the app. It never derives user state from the process current working directory and never invents `Headless/default` storage.

A nondefault named headless profile requires `REPOPROMPT_MCP_HEADLESS_PROFILE_DIR`. Explicit working roots may bootstrap a synthetic workspace only inside that intentional isolated profile. Empty or duplicate explicit roots fail closed.

Direct workspace/read/search/tree/selection/prompt behavior is implemented by `MCPDomainCanonicalWorkspaceService` in `RepoPromptDomainRuntime`. `DirectHeadlessWorkspaceBackend` is a physical adapter that supplies snapshots, mutations, and path resolution; it no longer contains a second file-reading, search, tree, selection, or token-accounting implementation.

## App admission and catalog semantics

Public `bind_context` `window_id` and legacy working-directory window selection translate the selected presentation window to its exact active tab/workspace logical context at admission and persist that authoritative context. Hidden `_windowID` performs the same translation for one call. Both fail closed if the selected window has no active logical context. Later active-tab changes cannot redirect admitted work, and no active-tab execution fallback was restored.

Provider-built app tools retain their existing `MCPAppToolBinder` envelope and are canonicalized without a second `runTool` wrapper. Raw shared bindings receive one envelope. Duplicate, invalid, or noncanonical catalog materialization throws a typed error during authoritative registration rather than trapping. Exact scope coverage again requires `read_file` to have only its single window registration scope.

The app physical boundary is grouped into five typed capability families:

- `MCPAppPhysicalCapabilityAdapters.Execution`
- `MCPAppPhysicalCapabilityAdapters.Context`
- `MCPAppPhysicalCapabilityAdapters.Selection`
- `MCPAppPhysicalCapabilityAdapters.Files`
- `MCPAppPhysicalCapabilityAdapters.Prompt`

The retired flat closure dependency-bag contract is absent from the frozen ownership fixture and guarded against returning.

## Lifecycle and cleanup

- `MCPService.start()` is the process-owned transport start operation.
- `join(windowID:)` and `leave(windowID:)` attach/detach presentation only and cannot start, stop, or resurrect transport.
- Explicit shutdown remains stopped after a later window attachment.
- `restoredBinding`, `TabContextResolutionPolicy`, `shouldSkipGenericTabBinding`, `tabBindingTroubleshooting`, window-only binding snapshots, migrated-tool branching, active-tab compatibility switches, and bare cleanup blocks are removed.
- A missing connection ID in read-file auto-selection admission produces controlled invalid-params behavior rather than `preconditionFailure`.
- Positive active-context token-accounting/coalescing tests cover the still-live `presentationActiveContext` branch.

## Focused correction evidence

- Backend selection policy: `f2ffd3f4-4176-4e82-be86-87bda55bf118` — 4 tests passed.
- Runtime root/configuration: `76a5b7b8-e19a-457d-b13b-697fcdb6a952` — 5 tests passed.
- Direct no-app/parser process: `b460deaf-8cf3-4e83-adec-3ff5c1bd133a` — 3 tests passed.
- App child backend pin: `7e8abbe4-2f9b-4bb7-820b-21945d2c70f4` — passed.
- Generated Codex integration configuration: `070321c4-5b74-4c1c-80e5-0bf50305a298` — 22 tests passed before the additional exact child-pin test above.
- Authoritative routing admission: `f3687442-e9f5-4ceb-9eb8-894c0a24ac04` — 57 tests passed.
- Restored active token-accounting tests passed (22; conductor ticket `0e3d3a65-f75e-4c21-ad4e-449e136abecc`).
- Catalog single envelope: `8ed82cf1-c043-4d18-b04c-0689ae61f1e9` — passed.
- Catalog duplicate failure: `d37a402b-fa8c-42ec-8966-ef742947882a` — passed.
- Process-owned join/shutdown semantics: `b5ee8fa5-facc-4f7a-98e1-855faaa899d0` — passed.
- Exact one-scope registration without window transport start: `ba50ff5d-7fa1-44d8-b7ab-2a624bfdcdd7` — passed.
- Standalone canonical composition: `4e2db67d-7d5d-4e45-af5e-685d2b68148b` — 2 tests passed.
- Frozen ownership/capability-family contract: `11d740c3-7edd-4d94-89d9-fd290e0724b9` — 3 tests passed.
- Provider package: `02bfec08-19c9-4fbe-b68b-c126e122f849` — passed.
- Products:
  - RepoPrompt: `0fa57b39-7668-4f9d-96df-09ae6cc7af49` — passed.
  - repoprompt-mcp: `9ed7685b-b8f3-458a-9cee-1861256f792e` — passed.
- Final format: `5c2c153c-98c7-4e9d-bd4d-81da0796e11f` — passed.
- Final lint: `4e258845-9ae2-420f-bd46-da7fa38a2df3` — passed.
- `Scripts/headless_runtime_guardrails.sh` — passed after final formatting.

## Test-ledger reconciliation

The curated ledger adds reviewed rows for parser edges, canonical state roots, app-child backend pinning, exact window-context admission, catalog single-envelope/fail-closed behavior, and restored token accounting. It renames the old headless-only mode-rejection row to the broader non-app contract and updates the lifecycle row to include post-shutdown attachment.

Authoritative list tickets:

- root: `f2bde283-9275-449e-ac68-3aad38285c7b`;
- provider: `c5fb9c47-56da-441b-92e2-2106d3c63857`.

Final exact-ID verification used fresh list tickets `bc4a0410-ffae-4315-8191-86c22fe06a16` and `68dae8ec-5d16-4926-92be-a6a984e73259` and passed with 3,768 methods.

## Remaining validation gates

- `make dev-codex-schema-check` remains locally blocked because installed Codex `0.144.1` is below the repository contract floor `0.145.0` (ticket `56f0f2d1-ba64-4c6e-ab9b-7b8070f00699`).
- A full `ToolCatalogSnapshotTests` class attempt compiled and exercised the new exact tests, but entered bootstrap retry paths while a visible app owned the socket; it was canceled rather than stopping/relaunching the app. The new catalog, lifecycle, and exact-scope methods pass independently above.
- No full root-suite rerun is claimed for this correction pass. The bounded focused owners, provider suite, exact ledger, products, lint, and guardrails pass.
- No live app proxy/no-app auto matrix, packaging, release artifact, latency comparison, or state-loss/retry evidence was produced. The task explicitly forbids app relaunch and requires the branch to remain local.

These gaps are why `app` remains the default. Moving the default to `auto` is a later release decision, not part of this M7 correction.
