# Shared Runtime Phase 0 Characterization

**Branch:** `core_split`
**Freeze HEAD:** `487cd71d892dbc3104689cc42fdb39f6c038e8fb`
**Scope:** characterization only; no production ownership moves or Phase 1 target changes

## Frozen sibling baselines

| Lane | Commit |
| --- | --- |
| Packaging | `2b350916d52809dd036331a746d888132019ce75` |
| App/MCP | `042a500b03b39d04237ec5544811696cf6b2f2f9` |
| Headless | `487cd71d892dbc3104689cc42fdb39f6c038e8fb` |

The commits are consecutive in branch history in the order packaging → app/MCP → headless.

## Characterization artifacts

- `Tests/SharedRuntimeConvergenceFixtures/Phase0/manifest.json`: baselines, exact nine-tool overlap, allowed product differences, blockers, and invariant gate owners.
- `App/app-characterization.json`: app descriptors in current published order plus normalized argument and representative structured/text formatter-boundary snapshots. Real provider behavior remains pinned by the focused existing tool suites listed below.
- `Headless/headless-characterization.json`: direct JSON-RPC initialize, descriptors, argument-coercion observations, and tool-call response snapshots.
- `differential-ledger.json`: per-tool classification of descriptor, argument, and structured/text response differences; no current safe-tool divergence is mislabeled as an allowed product difference.
- `App/WorkspaceV1/**`: current app workspace index/directory/document fixture.
- `Headless/ProfileV1/**`: current headless configuration and workspace-document fixture.
- `Scripts/test_shared_runtime_phase0_characterization.py`: ancestry, coverage, allowed-difference, and package-separation validation.

## Normalization rules

- JSON object keys are sorted; array order is preserved.
- Temporary repository/state paths are replaced by `$ROOT` and `$STATE`.
- Fixed UUIDs and timestamps are used in persistence fixtures.
- App and headless fields are not renamed or removed merely to create equality.
- Descriptor/parser/DTO/text/error differences are recorded as blockers, not allowed product differences.

## Current differential result

Only these categories are allowed to remain different after convergence:

1. initialize and product/profile metadata;
2. profile/state-root paths;
3. capability omissions;
4. standalone initialization/configuration instructions.

The frozen v1 implementations currently differ more broadly: descriptor descriptions/schemas/annotations, wrapper normalization versus per-field coercion, DTO/envelope shapes, text/error formatting, workspace schemas/layouts, and implementation ownership. Those are Phase 1-or-later blockers. Phase 0 preserves and exposes them.

## Pinned invariant suites

- Routing: `TabContextRoutingTests`, `BindContextRoutingRecoveryTests`, `MCPResolvedToolDispatchSourceGuardTests`.
- Watcher freshness: `FileSystemAcceptedIngressBarrierTests`, `WorkspaceFileContextStoreTests`.
- Bootstrap/socket ownership and ordering: `MCPBootstrapContractCharacterizationTests`, `MCPSocketDescriptorHardeningTests`.
- Process descriptors/SIGPIPE/spawn behavior: `ProcessLauncherDescriptorInheritanceTests`.
- Packaging separation: release-tooling static tests, embedded-helper layout/version checks, and direct-stdio headless smoke.

## Validation evidence

All commands ran on `core_split` without launching `RepoPrompt.app`.

| Gate | Evidence |
| --- | --- |
| Phase 0 manifest/baselines/package separation | `python3 Scripts/test_shared_runtime_phase0_characterization.py` — passed |
| Release/package static self-tests | `python3 Scripts/test_release_tooling.py` — 37 tests passed |
| New app/headless snapshots and v1 no-rewrite fixtures | `make dev-test FILTER=SharedRuntimePhase0` — 4 tests passed |
| App catalog | `make dev-test FILTER=ToolCatalogSnapshotTests` — 3 tests passed after adding a bounded wait for socket publication |
| Routing | `TabContextRoutingTests` 17 passed; `BindContextRoutingRecoveryTests` 7 passed; `MCPResolvedToolDispatchSourceGuardTests` 3 passed |
| Bootstrap/socket/process | `MCPBootstrapContractCharacterizationTests` 7 passed; `MCPSocketDescriptorHardeningTests` 21 passed; `ProcessLauncherDescriptorInheritanceTests` 6 passed |
| Watcher/file context | `FileSystemAcceptedIngressBarrierTests` 8 passed; `WorkspaceFileContextStoreTests` 102 passed |
| Headless runtime/store | `HeadlessMCPServerLifecycleTests` 7 passed; `HeadlessSelectionToolsTests` 5 passed; `HeadlessWorkspaceStoreTests` 3 passed |
| Codemap/workspace/runtime | `CodeMapGoldenTests` 4 passed; `WorkspaceSelectionPersistenceTests` 4 passed; `RepoPromptCoreHostLifecycleTests` 3 passed; `MCPRuntimeSessionRegistryTests` 2 passed |
| Target builds | coordinated Swift builds passed for `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless` |
| Guardrails | `make dev-guardrails` — passed |
| Standalone smoke | `make dev-headless-smoke` — passed over direct stdio |
| App packaging/helper smoke | `make dev-build` — packaged and signed the debug app; embedded `repoprompt-mcp --version` and helper-layout checks passed; app was not launched |
| Style | `make dev-format` and `make dev-lint` — passed; 0 SwiftFormat or SwiftLint violations |

A true live app-proxy `make dev-smoke` was intentionally not run because the user prohibited visible app launch and the command requires an already-running app. The bootstrap contract, routing, socket ownership/rollback suites, non-launching debug package, embedded-helper layout/version smoke, and direct-stdio headless smoke are the Phase 0 substitutes.

The first `ToolCatalogSnapshotTests` attempts exposed an existing publication race: the test inspected the isolated socket path before listener publication completed. Phase 0 adds a test-only bounded wait for the socket file; production behavior is unchanged, and the suite then passed.

## Exact changed files

- `docs/designs/shared-runtime-convergence-2026-06-05.md`
- `docs/plans/headless-core-isolation-2026-06-03.md`
- `docs/architecture/headless-core.md`
- `docs/architecture/source-layout.md`
- `docs/characterization/shared-runtime-phase0-2026-06-05.md`
- `Scripts/test_shared_runtime_phase0_characterization.py`
- `Tests/RepoPromptTests/MCP/ToolCatalogSnapshotTests.swift`
- `Tests/RepoPromptTests/MCP/SharedRuntimePhase0CharacterizationTests.swift`
- `Tests/RepoPromptHeadlessTests/Helpers/RepoRoot.swift`
- `Tests/RepoPromptHeadlessTests/SharedRuntimePhase0HeadlessCharacterizationTests.swift`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/manifest.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/differential-ledger.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/App/app-characterization.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/App/WorkspaceV1/workspacesIndex.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/App/WorkspaceV1/Workspace-Phase 0 App V1-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/workspace.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless/headless-characterization.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless/ProfileV1/config.json`
- `Tests/SharedRuntimeConvergenceFixtures/Phase0/Headless/ProfileV1/Workspaces/22222222-2222-2222-2222-222222222222.json`

No production Swift source, `Package.swift`, packaging script, or runtime ownership changed.

## Phase 1 blockers

1. Nine safe-tool descriptors and providers are independently owned.
2. App normalization and headless coercion differ.
3. Structured DTOs, formatted text, and errors differ.
4. Headless retains duplicate workspace/search/codemap/selection/prompt implementations.
5. No canonical workspace codec/repository or v1 migration exists.
6. Mature host/session/runtime ownership remains app-local.
7. Workspace file-context publication still retains the deferred Combine seam.
8. `RepoPromptShared` still contains POSIX descriptor support.
9. Core implementation targets remain public library products.
10. App-proxy socket mechanics and production process injection remain incomplete CoreMacOS work.
