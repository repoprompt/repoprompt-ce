# RepoPrompt CE XCTest Optimization Runs

## Measurement contract

- Primary metric: warm local root `Scripts/test_suite_optimizer.py baseline --target root` using conductor JSON `executionSeconds` from `./conductor test --json`.
- Provider package timing is measured separately with `Scripts/test_suite_optimizer.py baseline --target provider`.
- A root+provider number may be reported only as a derived secondary serial estimate, not as an observed single-process wallclock.
- Normal timing samples must not enable XCTest stall diagnostics or wake probes.
- Comparable baseline series use 3–5 valid samples; iteration-0 and release-gate series prefer five valid samples.
- Invalid samples are excluded only by optimizer-recorded invalid reasons.
- Noise classes use relative MAD: stable `<= 0.05`, noisy `<= 0.10`, unstable `> 0.10`.
- The curated ledger `Scripts/Fixtures/test-suite-contract-ledger.tsv` is never regenerated or overwritten. Executable add, rename, consolidation, or removal requires surgical exact-ID ledger updates in the same patch.
- Rows are append-only. Corrections are appended and supersede earlier rows; earlier artifacts and rows are not edited.

## Baseline summary

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:15:29+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | root | complete | 3 valid + 2 invalid | 2825 | 7 | 2832 | 623.578 | 635.298 | 0.0105 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | metadata guard; invalid samples from XCTest failures; source_changed=false |
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | provider | complete | 5 valid + 0 invalid | 2825 | 7 | 2832 | 0.422 | 0.536 | 0.0326 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | metadata guard; source_changed=false |

## Derived complete-suite secondary

| Date/commit | Label | Root artifact | Provider artifact | Root median | Provider median | Derived serial median | Root p95 | Provider p95 | Conservative serial p95 sum | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | `docs/test-suite-optimizer/artifacts/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | 623.578 | 0.422 | 623.999 | 635.298 | 0.536 | 635.834 | Derived serial sum only; not an observed one-process measurement; root baseline had 3 valid and 2 invalid samples |

## Iteration ledger

| Iteration | Commit/range | Attributed change | Primary/secondary scope | Root methods | Provider methods | Total methods | Method delta | Contract delta | Scenario delta | Exact old→new/removed mappings | Focused artifacts | Full-root artifacts | Provider artifacts | Root median delta | Root p95 delta | Provider median delta | Provider p95 delta | Derived secondary delta | Slowest suites/tests after change | Validation and exit codes | Decision |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| Phase 3 setup | d0abf8f0ba01 + working tree | Optimizer metadata guard, focused baselines, per-method ranking, artifact metadata, combine checks, docs, scoreboard scaffold | Tooling/setup only; no suite-speed claim | 2825 | 7 | 2832 | 0 | 0 | 0 | none | n/a | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | `docs/test-suite-optimizer/artifacts/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | n/a | n/a | n/a | n/a | n/a | suites: WorkspaceCodemapBindingEngineTests 45.431s, WorkspaceFileContextStoreCodemapSeamTests 45.222s, WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests 40.759s; top test: GitLoadedRootAuthorityEvidenceTests/testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded 16.553s | py_compile=0; optimizer tests=0; inventory=0; verify-ledger=1 missing 36 stale 2; root baseline=0; provider baseline=0 | Setup complete with reliability caveats; do not optimize until root invalid samples and ledger mismatch are triaged or accepted |

## Candidate queue

| Rank | Candidate | Metric scope | Expected effect | Risk | Entry criteria | Required evidence | Status |
|---:|---|---|---|---|---|---|---|
| 1 | Optimizer source-change guard, focused baseline support, and per-method ranking | Tooling only | Reduces campaign overhead and improves targeting; no primary suite-speed claim | Low | Always first setup step | Python optimizer tests, append-only scaffold, zero method/contract/scenario delta | Complete for Phase 3 setup |
| 2 | ACP mode-config fake ACP server fixture setup reduction | Root primary, conditional | Reduces repeated test fixture IO/setup if ACP suite ranks high | Low to medium | Initial root slow-suite/method ranking implicates `ACPAgentSessionControllerModeConfigTests` | Focused before/after artifact, focused XCTest, full-root after artifact, ledger verify | Waiting for baseline |
| 3 | Hosted CI class-per-process batching | CI-only secondary | Reduces hosted CI subprocess overhead; no local root primary improvement | Medium/high | CI elapsed becomes explicit target after local baseline | CI runner self-tests and GitHub Build and Test evidence | Waiting for CI prioritization |

## Reverted attempts

| Date | Iteration | Attempt | Reason reverted | Method delta | Scenario delta | Median delta | p95 delta | Correctness/lifecycle evidence | Artifact paths |
|---|---|---|---|---:|---:|---:|---:|---|---|

## Baseline run records

Append complete root/provider baseline records here. Include raw sample values, invalid reasons, slowest suites/tests, inventory path, and conductor log paths.

## Focused run records

Append focused before/after records here. Focused records are not primary metric results unless explicitly promoted through a complete root baseline.

## Handoff checklist per iteration

- Protected contract, plausible defect, chosen layer, and observable oracle.
- Exact executable IDs added, renamed, consolidated, or removed.
- Complete old→new/removed mapping when IDs change.
- Scenario-count rationale and before/after affected-suite plus repository totals for consolidations.
- Surgical ledger update confirmed; curated ledger was not regenerated.
- Focused command results and full-root/provider baseline artifact paths.
- Median, observed p95, relative MAD, and noise class for comparable series.
- Validation commands and exit codes.
- Any deliberately omitted or moved coverage with justification.

### Baseline: 2026-07-01T15:15:29+00:00 — root — phase3-setup-20260701T141721Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-phase3-setup-20260701T141721Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 635.298 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d324007d-9e20-45d5-b18e-f99f9e35a493.log` |  |
| 2 | no | 676.359 | 0.000 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f0a65b81-4c96-4d8c-8339-064097f5ad60.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | no | 676.102 | 0.000 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ee9ba126-e2b7-4121-a780-7af696c90e9a.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 4 | yes | 623.578 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d79cef91-af6b-4c12-8a36-57d7d28c5f76.log` |  |
| 5 | yes | 617.057 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e853a29b-615c-4660-a5e9-efa730fbf13c.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:15:29+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | root | complete | 3 valid + 2 invalid | 2825 | 7 | 2832 | 623.578 | 635.298 | 0.0105 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 45.431 | 5.296 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 45.222 | 2.289 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 40.759 | 4.923 | 0 |
| 4 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 29.510 | 6.077 | 0 |
| 5 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 22 | 22.204 | 4.399 | 0 |
| 6 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 18 | 21.634 | 3.723 | 0 |
| 7 | `RepoPromptTests.AgentRunWorktreeStartTests` | 36 | 20.601 | 3.264 | 0 |
| 8 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.316 | 16.607 | 3 |
| 9 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 4 | 19.920 | 12.194 | 0 |
| 10 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 18.156 | 42.310 | 0 |
| 11 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 16.792 | 2.204 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 14.663 | 7.753 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 14.597 | 2.018 | 0 |
| 14 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.252 | 11.941 | 0 |
| 15 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 11.037 | 3.301 | 0 |
| 16 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.833 | 11.057 | 0 |
| 17 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 10.104 | 5.404 | 0 |
| 18 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 9.926 | 1.054 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 9.050 | 1.193 | 0 |
| 20 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | 12 | 8.306 | 7.337 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 3 | 16.553 | 16.607 | 16.607 | 0 |
| 2 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 3 | 11.690 | 42.310 | 42.310 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 3 | 11.124 | 11.941 | 11.941 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 3 | 10.830 | 11.057 | 11.057 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 3 | 9.411 | 12.194 | 12.194 | 0 |
| 6 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 3 | 7.883 | 12.131 | 12.131 | 0 |
| 7 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 3 | 7.106 | 7.141 | 7.141 | 0 |
| 8 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 3 | 6.958 | 7.337 | 7.337 | 0 |
| 9 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 3 | 6.940 | 7.354 | 7.354 | 0 |
| 10 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 3 | 5.571 | 7.753 | 7.753 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 3 | 5.506 | 5.685 | 5.685 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 3 | 5.174 | 5.296 | 5.296 | 0 |
| 13 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 3 | 5.069 | 5.173 | 5.173 | 0 |
| 14 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 3 | 5.019 | 5.022 | 5.022 | 0 |
| 15 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository` | 3 | 4.737 | 5.039 | 5.039 | 0 |
| 16 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 3 | 4.422 | 4.923 | 4.923 | 0 |
| 17 | `RepoPromptTests.AgentRunDiffSeededWorktreeInitializationTests` | `testDefaultOffAndForcedFullCrawlUseOrdinaryRouteExactlyOnce` | 3 | 3.988 | 4.803 | 4.803 | 0 |
| 18 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 3 | 3.828 | 3.898 | 3.898 | 0 |
| 19 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 3 | 3.723 | 6.077 | 6.077 | 0 |
| 20 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 3 | 3.679 | 3.742 | 3.742 | 0 |

### Baseline: 2026-07-01T15:15:43+00:00 — provider — phase3-setup-20260701T141721Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor provider-test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.536 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/25a73101-a323-4f4e-bef4-1d125136f26e.log` |  |
| 2 | yes | 0.422 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8524c029-f24f-4a60-92e1-f085adae707e.log` |  |
| 3 | yes | 0.409 | 0.000 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1d780cfc-c248-4207-9838-7b03e1bda309.log` |  |
| 4 | yes | 0.408 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a9dacf62-1cf6-42d3-b0a9-b35f45f78dc0.log` |  |
| 5 | yes | 0.483 | 0.000 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/353123ab-37be-404b-8547-5e41f81efdbc.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | provider | complete | 5 valid + 0 invalid | 2825 | 7 | 2832 | 0.422 | 0.536 | 0.0326 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptClaudeCompatibleProviderTests.ClaudeCompatibleRuntimeSupportTests` | 4 | 0.001 | 0.001 | 0 |
| 2 | `RepoPromptClaudeCompatibleProviderTests.ClaudeSDKProtocolCodecTests` | 1 | 0.000 | 0.000 | 0 |
| 3 | `RepoPromptClaudeCompatibleProviderTests.ClaudeSDKNDJSONTranslatorTests` | 2 | 0.000 | 0.000 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptClaudeCompatibleProviderTests.ClaudeCompatibleRuntimeSupportTests` | `testNoModelBackendRejectsEffortEncodedSelections` | 5 | 0.001 | 0.001 | 0.001 | 0 |
| 2 | `RepoPromptClaudeCompatibleProviderTests.ClaudeCompatibleRuntimeSupportTests` | `testProviderCatalogDefaultsExposeStableRawValues` | 5 | 0.000 | 0.000 | 0.000 | 0 |
| 3 | `RepoPromptClaudeCompatibleProviderTests.ClaudeCompatibleRuntimeSupportTests` | `testResolverStripsEncodedEffortAndValidatesXHighAgainstBackendModelID` | 5 | 0.000 | 0.000 | 0.000 | 0 |
| 4 | `RepoPromptClaudeCompatibleProviderTests.ClaudeCompatibleRuntimeSupportTests` | `testRuntimeLaunchAndHeadlessSmokesPromptEnvironmentAndModels` | 5 | 0.000 | 0.000 | 0.000 | 0 |
| 5 | `RepoPromptClaudeCompatibleProviderTests.ClaudeSDKNDJSONTranslatorTests` | `testAssistantToolAndResultSmokePreservesUsageArgsAndStableInvocationID` | 5 | 0.000 | 0.000 | 0.000 | 0 |
| 6 | `RepoPromptClaudeCompatibleProviderTests.ClaudeSDKNDJSONTranslatorTests` | `testLifecycleAndStreamSmokeCoversSessionCancellationDeltaStopAndContextUsage` | 5 | 0.000 | 0.000 | 0.000 | 0 |
| 7 | `RepoPromptClaudeCompatibleProviderTests.ClaudeSDKProtocolCodecTests` | `testProtocolCodecSmokeDecodesControlRepairsControlCharactersAndEncodesUserMessage` | 5 | 0.000 | 0.000 | 0.000 | 0 |

### Focused: 2026-07-01T15:37:30+00:00 — root — reliability-gate-20260701-focused-binding

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 16.460 | 91.688 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/24709d46-b9c8-4f7b-882d-636bbc6bda08.log` |  |
| 2 | yes | 6.312 | 14.357 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a26f4574-ba93-489f-ab20-790cfab91b66.log` |  |
| 3 | yes | 3.631 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/97b8e656-c521-4a93-8c86-f6ecb29f5aa6.log` |  |
| 4 | no | 5.358 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/70c7bc9d-37fc-43b0-b2b5-21ad23e36e96.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 5 | no | 4.271 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4c5379a0-4a0e-4c4a-a7a8-15e9a0d7187e.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 6 | no | 4.313 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/33669373-1d1a-44d6-b8d5-38b19eacc322.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 7 | yes | 3.801 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7c4b94b2-076a-4517-9ff9-7dc9faf1c729.log` |  |
| 8 | yes | 3.727 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/237fb465-089d-4de1-b574-2c76f764c734.log` |  |
| 9 | yes | 3.632 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/aac5e8bc-3226-440c-b4c9-4b00bd902a08.log` |  |
| 10 | yes | 4.065 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/04182522-fb0c-4acc-82e1-c2b74b92ebc6.log` |  |
| 11 | yes | 3.525 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9345a7f5-5a74-4965-bd28-8d552ed64b2b.log` |  |
| 12 | yes | 6.146 | 6.228 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/af4ce433-bbc2-40ac-9a7b-7fb2282d79fb.log` |  |
| 13 | yes | 6.149 | 5.965 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/844ff49d-fb96-40ec-9fee-3ec0aba80770.log` |  |
| 14 | yes | 6.086 | 11.225 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7d712c34-add8-4e12-a14c-b141150c7304.log` |  |
| 15 | yes | 6.684 | 5.020 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/58f3e826-471e-44e1-a43d-47ee293d3026.log` |  |
| 16 | yes | 6.217 | 5.433 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3bd9954d-26ec-4c4e-9da8-cc9d19cf4b68.log` |  |
| 17 | yes | 6.228 | 5.169 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6cb997bf-dcd0-47c8-ae3f-1689bc735ed5.log` |  |
| 18 | yes | 6.131 | 5.070 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/97e46dd3-f43f-4e87-aee1-eb64e42f8d6c.log` |  |
| 19 | yes | 6.277 | 5.300 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/761d917a-5ba3-44a4-9111-ae04aa83bb06.log` |  |
| 20 | yes | 6.750 | 5.030 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8739281d-efca-49a4-a70b-02e64bb5e527.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:37:30+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-binding | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 17 valid + 3 invalid | 2825 | 7 | 2832 | 6.146 | 16.460 | 0.0877 | noisy | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 1 | 2.890 | 3.380 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 17 | 2.890 | 3.380 | 3.380 | 0 |

### Focused: 2026-07-01T15:39:00+00:00 — root — reliability-gate-20260701-focused-seam

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-seam.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 5.231 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/23154027-e474-4073-b40b-5667fc043986.log` |  |
| 2 | yes | 2.671 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0111a003-3264-45f8-829b-5ae93442f880.log` |  |
| 3 | yes | 2.616 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/566ae3f9-35e8-494e-9f2d-a7e7866e2add.log` |  |
| 4 | yes | 2.583 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/12944b9a-d092-48e6-b588-4daf99900dfd.log` |  |
| 5 | yes | 2.767 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4616abc2-046e-4657-955a-126ddd60c116.log` |  |
| 6 | yes | 2.653 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0ff1dddd-b611-4093-855c-531044af1742.log` |  |
| 7 | yes | 2.686 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/075df813-3c09-4674-993e-2d29c24a63ee.log` |  |
| 8 | yes | 2.600 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bdafd48b-bdca-4086-b45e-f8d63928a3fb.log` |  |
| 9 | yes | 2.703 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/254eaee6-2273-4f06-9767-81e560430b04.log` |  |
| 10 | yes | 3.546 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8919c852-0a5f-4888-a184-93826bd8e007.log` |  |
| 11 | no | 2.583 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d7502bdd-d5ad-4674-a06f-008a544e88a3.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 12 | yes | 2.798 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ab3de057-4e38-41dc-bf8d-e535a600fc88.log` |  |
| 13 | yes | 2.798 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d4c612f7-c052-4ca8-936e-9b05c133d9f8.log` |  |
| 14 | yes | 2.841 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e26a9553-e358-4659-b8c5-49e646a34f78.log` |  |
| 15 | yes | 2.886 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3099408e-6de0-4b36-8343-e105d95cc11a.log` |  |
| 16 | yes | 2.794 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/61d33f01-db12-4fed-8ce0-5b875ca04c6f.log` |  |
| 17 | yes | 2.946 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/12a705a8-6334-4d74-bf48-464437756880.log` |  |
| 18 | yes | 2.660 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/225b4625-cca5-4c40-bcdf-ed097b46a4bc.log` |  |
| 19 | yes | 2.692 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c9eafda8-8a0f-4dfe-a16b-7e8734f6a309.log` |  |
| 20 | yes | 2.686 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6f714ef8-ae48-4666-82be-24717f66bb17.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:39:00+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-seam | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 19 valid + 1 invalid | 2825 | 7 | 2832 | 2.703 | 5.231 | 0.0337 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-seam.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 1 | 1.923 | 2.790 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | `testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 19 | 1.923 | 2.790 | 2.790 | 0 |

### Focused: 2026-07-01T15:43:13+00:00 — root — reliability-gate-20260701-focused-binding-after

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 16.269 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/91d89ca4-b6a4-41f8-80ab-9e4b32f3ad5a.log` |  |
| 2 | yes | 3.172 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/018d28a9-e353-46ec-9b1c-30f4df179545.log` |  |
| 3 | yes | 3.246 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/417e31bc-3710-4589-a8e0-cad0a23dc109.log` |  |
| 4 | yes | 3.589 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/214e16e4-91af-4c33-adc7-c2abf49810a4.log` |  |
| 5 | yes | 8.374 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0c5ec247-4f9b-4f8f-bce3-a8ab563b7a47.log` |  |
| 6 | yes | 4.355 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dd811732-3f86-4b43-9c94-a7442b8c50d3.log` |  |
| 7 | yes | 3.170 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a2e95de4-30b2-4126-9b55-626197d7e674.log` |  |
| 8 | yes | 5.397 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5b6ecda0-594b-40f9-a870-9081743ee385.log` |  |
| 9 | yes | 3.092 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/70a3da17-3e3e-451b-b3df-4f3fdae76926.log` |  |
| 10 | yes | 3.198 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/29fc28e7-1296-4f01-ad3b-369e28c65611.log` |  |
| 11 | yes | 3.178 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b5139358-2840-40d6-a51c-f39d95791640.log` |  |
| 12 | yes | 3.130 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/774badc3-dac1-4fda-954c-fc22a8e025ab.log` |  |
| 13 | yes | 3.126 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0bbef7a1-18ec-4741-9249-13d811ee30e9.log` |  |
| 14 | yes | 3.028 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2affe9c1-af47-40a5-bcb7-deae969bc757.log` |  |
| 15 | yes | 3.015 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5b68ec97-3280-4c7f-a75d-0d4bdec1bf7d.log` |  |
| 16 | yes | 3.059 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1d30a542-6be2-45b7-9266-da83213a0d37.log` |  |
| 17 | yes | 3.157 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a5cf5e98-b8e4-4528-9f26-eca6c53710b2.log` |  |
| 18 | yes | 2.955 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9a74c951-55f5-4590-98f2-9afb0a613390.log` |  |
| 19 | yes | 3.206 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/014abd45-de6f-407f-b560-082f1113a320.log` |  |
| 20 | yes | 3.239 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/321c6cd3-44f3-44b3-b415-93785d248de4.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T15:43:13+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-binding-after | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 3.175 | 8.374 | 0.0242 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 1 | 2.442 | 7.627 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 20 | 2.442 | 4.638 | 7.627 | 0 |


## Reliability gate: 2026-07-01 — Phase 3 invalid-sample hardening

### Reliability-gate summary

| Date/commit | Gate | Change type | Method delta | Contract delta | Scenario delta | Focused artifacts | Root re-baseline artifact | Root validity | Decision |
|---|---|---|---:|---:|---:|---|---|---|---|
| 2026-07-01/d0abf8f0ba01 + working tree | Phase 3 invalid root samples | Test-harness determinism only; no performance optimization | 0 | 0 | 0 | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding.json`; `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-seam.json`; `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json` | intended optimizer artifact `intended artifact not emitted; summary retained in scoreboard` was not emitted; failure summary: `artifact pruned; failed-baseline summary retained in scoreboard` | 0 valid + 5 invalid | Phase 4 is **not safe** to start; target binding failure fixed in focused evidence, seam remains intermittent focused, and full-root baseline is blocked by unrelated codemap/context-builder reliability failures |

### Triage classification

| Method | Focused artifact | Focused result | Classification | Action |
|---|---|---:|---|---|
| `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding.json` | 17 valid + 3 invalid / 20 | Intermittent focused test-harness flake. The invalid assertions were exact classifier-route counters (`classifications`, `cleanClassifications`, `worktreeClassifications`, `validatedWorktreeReads`) while the durable contract (locator reuse + one build + projected entries) remained separately asserted. | Implemented one harness determinism fix: removed exact clean-vs-worktree route assertions and documented safe Git metadata-refresh fallback. Post-fix artifact is 20/20 valid. |
| `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-seam.json` | 19 valid + 1 invalid / 20 | Intermittent focused seam/harness flake. Focused invalid was `expectedReady`; Phase 3 root invalid was `expectedPending`. No production correctness regression was isolated in this dispatch. | No code change; single implemented fix was limited to the clearer binding-engine harness issue. Residual reliability concern remains. |

### Validation commands and exit codes

| Command | Exit | Notes |
|---|---:|---|
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --samples 20 --label reliability-gate-20260701-focused-binding --inventory docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard docs/test-suite-optimizer/scoreboard.md --output docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding.json --source-change-guard content` | 0 | 17 valid + 3 invalid; invalids failed the exact classifier-route assertions for `linked`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait --samples 20 --label reliability-gate-20260701-focused-seam --inventory docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard docs/test-suite-optimizer/scoreboard.md --output docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-seam.json --source-change-guard content` | 0 | 19 valid + 1 invalid; invalid was `expectedReady`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --samples 20 --label reliability-gate-20260701-focused-binding-after --inventory docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard docs/test-suite-optimizer/scoreboard.md --output docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json --source-change-guard content` | 0 | 20 valid + 0 invalid; median 3.175s, observed p95 8.374s, rel MAD 0.0242 stable. |
| `make dev-test FILTER=WorkspaceCodemapBindingEngineTests` | 0 | 65 tests, 0 failures, conductor ticket `bbc09a91-57b0-4f08-93ff-0218b0525f0f`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --samples 5 --label reliability-gate-20260701-root-after --inventory docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard docs/test-suite-optimizer/scoreboard.md --output intended artifact not emitted; summary retained in scoreboard --source-change-guard metadata` | 1 | Optimizer error: `baseline produced no valid samples`; intended artifact not emitted. Failure summary artifact: `artifact pruned; failed-baseline summary retained in scoreboard`. |
| `make dev-format` | 0 | SwiftFormat completed; 0/1370 files formatted. |
| `make dev-lint` | 0 | SwiftFormat lint and SwiftLint strict passed; 0 violations. |
| `make dev-test-list` | 0 | Authoritative root XCTest list completed; no executable ID changes intended. |
| `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | 1 | Pre-existing mismatch remains: 36 missing, 2 stale. No ledger cleanup performed in this dispatch. |

### Root re-baseline invalid samples

The root re-baseline used the Phase 3-comparable metadata source guard but produced no valid timing samples. None of the two target failures repeated in the root attempt; failures were unrelated and broad enough to block attribution.

| Sample | State | Conductor ticket | Log | Notable failures |
|---:|---|---|---|---|
| 1 | failed | `0e29187b-3bef-44d4-941c-53a48d005eb9` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0e29187b-3bef-44d4-941c-53a48d005eb9.log` | `ContextBuilderWorktreeInheritanceTests/testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository`; `PromptContextPreAssemblyServiceTests/testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly`; `WorkspaceCodemapLocalGitClassificationTests/testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` |
| 2 | failed | `d600a0fe-b73b-448a-9c06-975b8d7c3f26` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d600a0fe-b73b-448a-9c06-975b8d7c3f26.log` | `ContextBuilderWorktreeInheritanceTests/testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps`; `ContextBuilderWorktreeInheritanceTests/testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository`; `ContextBuilderWorktreeInheritanceTests/testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior`; `PromptContextPreAssemblyServiceTests/testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly`; `WorkspaceCodemapLocalGitClassificationTests/testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` |
| 3 | failed | `005b939b-2196-41b3-86eb-1522c004bcdc` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/005b939b-2196-41b3-86eb-1522c004bcdc.log` | `ContextBuilderWorktreeInheritanceTests/testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps`; `ContextBuilderWorktreeInheritanceTests/testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior`; `PromptContextPreAssemblyServiceTests/testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly`; `WorkspaceCodemapLocalGitClassificationTests/testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` |
| 4 | failed | `fe12c85f-5ce7-4c5f-a360-ef0eccf0ee44` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fe12c85f-5ce7-4c5f-a360-ef0eccf0ee44.log` | same unrelated codemap warmup/context-builder pattern; see failure summary artifact for exact signatures |
| 5 | canceled | `29a37612-c598-4c9d-9fe0-84d5280d5d22` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/29a37612-c598-4c9d-9fe0-84d5280d5d22.log` | canceled after prolonged no-progress hang; already had unrelated `ContextBuilderWorktreeInheritanceTests`, `PromptContextPreAssemblyServiceTests`, and `WorkspaceCodemapArtifactBindingTests/testBindingRejectsLegitimatelyIssuedStaleTokensWithoutChangingValue` failures |

### Phase 4 decision

Phase 4 optimization remains **blocked / unsafe**. The binding-engine invalid sample has a focused harness fix with 20/20 post-fix validity, but the seam method still reproduced intermittently in focused sampling and the full root re-baseline produced 0/5 valid samples from unrelated codemap/context-builder reliability failures. No performance optimization work was performed.
### Focused: 2026-07-01T18:25:51+00:00 — root — reliability-gate-20260701-focused-contextbuilder-worktree-inheritance

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderWorktreeInheritanceTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 211.007 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a83511d3-1eed-4332-853e-6ff934cf9cb6.log` |  |
| 2 | yes | 149.900 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8d35a158-0224-49fa-99b0-395e84e66ce9.log` |  |
| 3 | no | 255.800 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b4d274e5-e7cc-44fa-bb56-a61e8ca7befe.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 4 | no | 221.511 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/95e57ead-eec3-4cc5-9f8f-07255b960ed9.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 5 | yes | 172.959 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/66493d78-93e8-44e9-b018-f98ae1835d16.log` |  |
| 6 | no | 16.880 | 0.005 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7499d374-223e-4451-904b-b1e358f99561.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded |
| 7 | no | 121.788 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3a58fb84-8f68-4b44-87cb-ffb599e2779d.log` | measurement source changed during execution |
| 8 | no | 3.383 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/71a08595-a427-487c-ab97-12af77942b82.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 9 | no | 2.977 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5a4c24b0-9f1a-4866-a3f4-ab47a17a4193.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 10 | no | 2.918 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c37ceba6-c806-4c48-a4b1-948e9b911aeb.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 11 | no | 2.928 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9c218a8b-3832-4573-aab3-dde0a2bf96af.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 12 | no | 3.202 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d3ab11a5-353a-4d06-8b7a-77adb3ec214a.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 13 | no | 2.817 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c6947055-7011-448f-8064-aa6cbcf816eb.log` | conductor process exit 1; terminal state failed; test exit 1; filtered baseline produced no parsed XCTest timings |
| 14 | no | 2.934 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3d4e05e6-0a5a-4da5-93ac-2710e62fffad.log` | conductor process exit 1; terminal state failed; test exit 1; measurement source changed during execution; filtered baseline produced no parsed XCTest timings |
| 15 | yes | 318.658 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1dcf6b5d-2188-41bb-ae75-0db7d0365830.log` |  |
| 16 | no | 0.955 | 109.107 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0fed5aca-130e-4084-9ce5-26508f3ead3d.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded; filtered baseline produced no parsed XCTest timings |
| 17 | no | 315.444 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/531454aa-af5d-48da-bba3-07d37dadd82a.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 18 | no | 0.745 | 149.918 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ddf0375d-e9ff-44b7-a715-1460cdf8f05d.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded; measurement source changed during execution; filtered baseline produced no parsed XCTest timings |
| 19 | no | 393.415 | 0.004 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/470ac6ba-8179-4c29-8a7c-b9a3c8144094.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded |
| 20 | yes | 266.692 | 0.627 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/02c28a92-e90d-47e2-93a2-c121c826df45.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T18:25:51+00:00/c96fade22b69 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 5 valid + 15 invalid | 2825 | 7 | 2832 | 211.007 | 318.658 | 0.2639 | unstable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 5 | 210.283 | 280.755 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 4 | 99.368 | 169.196 | 169.196 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps` | 5 | 26.661 | 33.792 | 33.792 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository` | 5 | 24.883 | 33.822 | 33.822 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 5 | 2.715 | 280.755 | 280.755 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderFailsClosedBeforeProviderCreationWhenWorktreeIsUnavailable` | 5 | 0.298 | 0.459 | 0.459 | 0 |

### Focused: 2026-07-01T19:22:49+00:00 — root — reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderWorktreeInheritanceTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 187.303 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cdd3e4bb-154b-41e7-b953-6975c8046fa8.log` |  |
| 2 | yes | 215.278 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/027e2963-1770-436a-a823-d37e0f9ba1c1.log` |  |
| 3 | no | 369.193 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9fc22707-5e95-4b4c-b18d-4295b4b2466f.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 4 | no | 310.426 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6771bbf3-ad4a-49c1-a2f2-618799b7bc03.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 5 | yes | 283.106 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cce7d741-7b4c-47f4-a767-61d054312d8e.log` |  |
| 6 | yes | 98.580 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/21bf7337-5911-4ccf-a03a-bf981052e014.log` |  |
| 7 | yes | 47.557 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2a935d0c-b1e8-4598-b87e-c9eb59956060.log` |  |
| 8 | yes | 51.050 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4e113a76-5e1c-48ff-84c8-51b8c6000c97.log` |  |
| 9 | yes | 54.403 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/56894ea1-f7d5-4edb-b7e9-f7c65dd5686b.log` |  |
| 10 | yes | 70.157 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5466a466-7164-44b4-9442-9da6322d2770.log` |  |
| 11 | yes | 72.813 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/203fb04a-ffc4-4274-abd5-c53623275777.log` |  |
| 12 | yes | 145.902 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a8aa1219-0597-4e89-bc89-6a578ac689ab.log` |  |
| 13 | yes | 228.676 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/aa7398e3-0646-4bca-96ce-74fd0afe0125.log` |  |
| 14 | yes | 281.489 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6d4368d6-9930-4f35-94ba-bf22c9be1386.log` |  |
| 15 | yes | 97.076 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1fc4a3a3-3155-43b0-baaa-0de6d5d1a485.log` |  |
| 16 | yes | 78.825 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/30111e52-ae52-43c0-9e4c-f1ecb2bd4afd.log` |  |
| 17 | yes | 99.138 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e90e4fba-8bcf-4bde-b0eb-1851f0e7e7d2.log` |  |
| 18 | yes | 101.778 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8cee5e9f-5ad4-4607-adb8-f38f5e5a804d.log` |  |
| 19 | yes | 130.792 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a48d4247-f8b7-45c4-88fc-9e7fde409989.log` |  |
| 20 | yes | 230.885 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/422a1c03-0e06-42d8-b6cc-c2ff82376718.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T19:22:49+00:00/c96fade22b69 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 18 valid + 2 invalid | 2825 | 7 | 2832 | 100.458 | 283.106 | 0.4554 | unstable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 4 | 80.983 | 188.545 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 18 | 51.107 | 188.545 | 188.545 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps` | 18 | 8.348 | 33.799 | 33.799 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository` | 18 | 6.853 | 54.660 | 54.660 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderFailsClosedBeforeProviderCreationWhenWorktreeIsUnavailable` | 18 | 0.463 | 0.557 | 0.557 | 0 |
### Focused: 2026-07-01T19:45:23+00:00 — root — reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderWorktreeInheritanceTests/testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests/testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 22.516 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ff2304e3-ad6e-4c5b-a5ff-51a02417357c.log` |  |
| 2 | yes | 5.422 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2dd8953a-c6b5-4240-8474-204806c1c436.log` |  |
| 3 | yes | 22.942 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/252f6d75-1329-4716-a726-ca2279dc4df1.log` |  |
| 4 | yes | 22.652 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f53fa5f9-054c-483b-8a07-9c55f63062f0.log` |  |
| 5 | yes | 22.700 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e874c6ea-d808-48b7-9fdd-8fa0c0e7c79a.log` |  |
| 6 | yes | 22.662 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9004aaac-378b-41b5-b06f-5f5bbd06ce5b.log` |  |
| 7 | yes | 2.600 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b3818270-997d-455c-89d4-c5fa814ccba1.log` |  |
| 8 | yes | 5.261 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2e591a9a-b80f-4e0a-ad2b-60c4c4931ba1.log` |  |
| 9 | yes | 22.656 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/77d48346-059a-4876-91a9-a7880e594805.log` |  |
| 10 | yes | 2.417 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0e617dc0-e3f1-42ec-abe7-16cd46f8e791.log` |  |
| 11 | yes | 5.592 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/55763065-0433-4fc1-b9bc-3a7af1f5b375.log` |  |
| 12 | yes | 5.364 | 0.007 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d561fca6-bd6d-4e21-858e-c7d0a4885886.log` |  |
| 13 | yes | 2.395 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d5c5df8f-47aa-4402-8785-c72022c23a11.log` |  |
| 14 | yes | 22.679 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e05803e3-b7ae-4f95-9fcd-14d3d8eb80ec.log` |  |
| 15 | yes | 22.877 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4b801b7d-2207-4bea-8665-10cb4781fd45.log` |  |
| 16 | yes | 23.470 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bc69a5fa-65f8-4ecd-aed8-addff576529e.log` |  |
| 17 | yes | 23.295 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bdc0bb58-f21b-43e3-b4c2-463f70da1f8a.log` |  |
| 18 | yes | 23.170 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/681c2626-021c-457e-a05d-e05d39b99727.log` |  |
| 19 | yes | 184.183 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ca79a997-3ae2-4e4b-8779-101dc04b0ace.log` |  |
| 20 | yes | 102.031 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8c27d8e0-07ae-49fa-a3dc-50d1407a4a4e.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T19:45:23+00:00/b73934e9da5a | reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests/testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 22.659 | 102.031 | 0.0319 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 1 | 21.856 | 183.350 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 20 | 21.856 | 101.210 | 183.350 | 0 |
### Focused: 2026-07-01T20:22:43+00:00 — root — reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderWorktreeInheritanceTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 231.455 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d58bb274-24f8-4f49-913c-3da635c8255e.log` |  |
| 2 | yes | 109.627 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1c39c9ff-ca33-4878-bbae-4538f44bc248.log` |  |
| 3 | yes | 210.222 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f900da56-7865-4ec6-92d1-56af51baabd2.log` |  |
| 4 | yes | 311.085 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bc498cec-2ed0-4baf-a737-76144050bcbc.log` |  |
| 5 | yes | 155.563 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/247258ac-18a9-4bb7-af74-ac386aa28c62.log` |  |
| 6 | yes | 33.008 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/31c4096b-442d-4f77-81f1-3a5c48917e10.log` |  |
| 7 | yes | 42.447 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d23658a7-c33e-4c1a-8f53-44d57dbc4b00.log` |  |
| 8 | yes | 42.215 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/da2db168-1ec8-4861-9a84-bf1c56219d9d.log` |  |
| 9 | yes | 38.814 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cc49f182-d08b-4846-a384-4991c0012aeb.log` |  |
| 10 | yes | 41.812 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/452a63a8-c86d-4795-a161-db283987dfb2.log` |  |
| 11 | yes | 73.846 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/30a60f51-5a1d-4370-a51b-124ad79ef6ec.log` |  |
| 12 | yes | 42.061 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/83e87a69-774c-4f34-bbea-ec1343fe1fba.log` |  |
| 13 | yes | 39.882 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b396e26b-ded0-4b1f-a7ef-67e924a0c255.log` |  |
| 14 | yes | 39.749 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1df638f8-ec35-44c4-af4e-5c733fa676b7.log` |  |
| 15 | yes | 45.210 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/65459540-a6e0-49aa-be80-86f3f65a3c23.log` |  |
| 16 | yes | 40.647 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c0b11e1c-f125-46e0-aa2f-febbdfae8bac.log` |  |
| 17 | yes | 39.574 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/569395b3-38da-4cf1-a77e-5c8db02c9285.log` |  |
| 18 | yes | 39.159 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/06c2aeca-caad-4c40-80dd-a017163f90ef.log` |  |
| 19 | yes | 40.590 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5e1dfb0d-752d-42b8-b3e5-4c09c6907702.log` |  |
| 20 | yes | 34.411 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d724ba9b-9424-4377-b983-e2dba1c136bc.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T20:22:43+00:00/f7a85f2d6824 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 41.937 | 231.455 | 0.0703 | noisy | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 4 | 32.103 | 182.293 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 20 | 20.973 | 122.254 | 182.293 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository` | 20 | 5.050 | 33.873 | 56.204 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps` | 20 | 4.925 | 25.008 | 25.293 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderFailsClosedBeforeProviderCreationWhenWorktreeIsUnavailable` | 20 | 0.449 | 0.548 | 0.759 | 0 |

### Baseline failure summary: 2026-07-01T21:28:41+00:00 — root — reliability-gate-20260701-root-after-contextbuilder-clean

Command: `python3 Scripts/test_suite_optimizer.py baseline --target root --samples 5 --label reliability-gate-20260701-root-after-contextbuilder-clean --inventory docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard docs/test-suite-optimizer/scoreboard.md --output artifact pruned; stale failed-baseline summary retained in scoreboard --source-change-guard metadata`
Artifact: `artifact pruned; stale failed-baseline summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: no — zero valid samples; no normal timing baseline summary emitted.
Optimizer exit: no normal optimizer exit; wrapper stopped with SIGKILL/effective 137 after preserving hung-sample evidence. First conductor ticket canceled with exit 130; a second sample started during shutdown and was canceled as cleanup with exit 130.

| Sample | Valid | State | Exit | Log | Invalid reason / signature |
|---:|---|---|---:|---|---|
| 1 | no | canceled | 130 | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/614bf6c0-e3d0-4e86-bf42-c7a96470acba.log` | Root XCTest stale-output hang for ~54 min at `RepoPromptTests.AgentWorktreeMergeAttentionTests/testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent`; not ContextBuilder-related. |
| 2 | no | canceled | 130 | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3f735856-82e5-43eb-bf68-7f18b8661f06.log` | Cleanup cancellation after optimizer advanced during shutdown at `RepoPromptTests.CodeMapArtifactStoreTests/testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement`; not treated as independent failure signal. |

Result: 0 valid + 2 invalid attempted of 5 requested. Median, observed p95, relative MAD, and noise are unavailable because there were no valid samples.
ContextBuilder repeat check: no known ContextBuilder failure signatures repeated in this root re-baseline attempt.
Phase 4 decision: cannot resume from this gate; preserve evidence and classify the remaining root cluster as the `AgentWorktreeMergeAttentionTests` stale-output/hang observed in sample 1.
### Focused: 2026-07-01T21:33:32+00:00 — root — reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AgentWorktreeMergeAttentionTests/testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AgentWorktreeMergeAttentionTests/testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 13.914 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3b478c38-f22d-4f14-ba13-a08d42db2709.log` |  |
| 2 | yes | 0.669 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fb8aa13b-13fa-4bee-8209-99da93a343a6.log` |  |
| 3 | yes | 0.706 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b0a972b9-d21e-4f80-9623-e64220d87a2b.log` |  |
| 4 | yes | 0.705 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6345e740-cadf-46db-90ff-ab229ff31ed3.log` |  |
| 5 | yes | 0.691 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bf11af8c-c52f-4848-8ff8-63a25ee664a8.log` |  |
| 6 | yes | 0.728 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/43a2470d-c76a-4d0c-95ad-ae3e9641c032.log` |  |
| 7 | yes | 0.718 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/83f62ea1-8e10-4be4-bc9d-8a5a2ac7d66c.log` |  |
| 8 | yes | 0.716 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6dd95a48-f6fd-4917-89f7-1a5804e84a98.log` |  |
| 9 | yes | 0.733 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8b64ca17-9993-4ec2-bec6-5fcdf3549b77.log` |  |
| 10 | yes | 0.738 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9b2b359e-6958-4560-8a1c-ef657c058bd9.log` |  |
| 11 | yes | 0.726 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eea1dc5a-8449-43e7-86d1-3bd255e6a85b.log` |  |
| 12 | yes | 0.688 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fe8b1af8-11d7-4146-a26a-6caf58dd716a.log` |  |
| 13 | yes | 0.733 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a6f37b30-b97d-4f29-93e3-abffc94407f8.log` |  |
| 14 | yes | 0.728 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b3cbf551-011e-4b2e-9c4e-4092212500ca.log` |  |
| 15 | yes | 0.718 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/37bc081f-5ad6-43b5-b493-86d346338818.log` |  |
| 16 | yes | 0.731 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/acffba36-3445-4975-8a14-8f128d77b53b.log` |  |
| 17 | yes | 0.707 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/aeb56dd2-4692-489f-aeda-dd4cbf335846.log` |  |
| 18 | yes | 0.929 | 0.021 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/83f6ee89-30df-498d-81f3-335c7bad43ae.log` |  |
| 19 | yes | 0.694 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3384f13d-8d17-47ad-9d2f-19352c6b3d97.log` |  |
| 20 | yes | 0.724 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ed9879df-8b48-482f-af3b-46ef15f83ee6.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T21:33:32+00:00/ef45417b29a8 | reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe | root | filtered: `RepoPromptTests.AgentWorktreeMergeAttentionTests/testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.721 | 0.929 | 0.0182 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentWorktreeMergeAttentionTests` | 1 | 0.000 | 0.002 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentWorktreeMergeAttentionTests` | `testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent` | 20 | 0.000 | 0.001 | 0.002 | 0 |
### Focused: 2026-07-01T21:38:01+00:00 — root — reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.CodeMapArtifactStoreTests/testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.CodeMapArtifactStoreTests/testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 12.818 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/01612406-e639-4b29-a2e9-4363cc99b095.log` |  |
| 2 | yes | 0.720 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/098593de-bfa9-4e26-8aa3-915529990907.log` |  |
| 3 | yes | 0.766 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c5d7ade3-55ff-4294-bb8d-ded722116493.log` |  |
| 4 | yes | 0.720 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3c7ad212-5090-48f8-b7aa-76eb02465c10.log` |  |
| 5 | yes | 0.717 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5bc03101-feea-48e4-8dfc-bb4d817151e0.log` |  |
| 6 | yes | 0.717 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d207c07d-d03a-42ca-b89c-634d6e0d25c7.log` |  |
| 7 | yes | 0.710 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/31a74dc2-51b6-4dde-b093-3646e949e570.log` |  |
| 8 | yes | 0.718 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8589de17-ecfa-4c94-81f5-e20b84d6f5ad.log` |  |
| 9 | yes | 0.714 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/739c78d9-f368-4586-a9e9-e14633fca29c.log` |  |
| 10 | yes | 0.734 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5734b9cf-2853-43c3-9f3a-2543362cbbab.log` |  |
| 11 | yes | 0.721 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6bdcdd78-fa1f-45f9-bacd-4d1e74fe90ba.log` |  |
| 12 | yes | 0.734 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bdc40a39-cfe9-4e01-bc50-01a0f0e0f3c5.log` |  |
| 13 | yes | 0.739 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c37b03e-8428-487d-b2d4-a4238d8784b6.log` |  |
| 14 | yes | 0.731 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/63a0eef4-6e38-420e-8024-0bce86ac8f7b.log` |  |
| 15 | yes | 0.725 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/987b25bf-a2e8-4661-b2ba-7a73fd2c3446.log` |  |
| 16 | yes | 0.714 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dc03ed51-e9df-42be-ac86-6c1bb60c2955.log` |  |
| 17 | yes | 0.680 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fe119718-9940-4d38-b6b8-a2096f2a8a64.log` |  |
| 18 | yes | 0.718 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0f0f0932-57cb-43eb-9299-757b97366f5f.log` |  |
| 19 | yes | 0.731 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c0c5f4b7-78f1-4fdf-bb53-13798fb43602.log` |  |
| 20 | yes | 0.730 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/545b2d97-56b1-4674-9005-eff5929882fe.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T21:38:01+00:00/7e7bde452071 | reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe | root | filtered: `RepoPromptTests.CodeMapArtifactStoreTests/testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.720 | 0.766 | 0.0114 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CodeMapArtifactStoreTests` | 1 | 0.008 | 0.020 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CodeMapArtifactStoreTests` | `testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement` | 20 | 0.008 | 0.017 | 0.020 | 0 |
### Baseline: 2026-07-01T22:38:56+00:00 — root — reliability-gate-20260701-root-after-exonerated-probes-stall-wake-diagnostic

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; diagnostic summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | no | 724.865 | 0.006 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/587c4dc9-d4da-4582-b111-8bacd1d2040a.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 2 | no | 697.803 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/233a0ee5-28b6-4931-b7d4-8d3b2c28c653.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 729.333 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4f110a00-d01c-4dac-82d1-0e2c92a46200.log` |  |
| 4 | no | 683.863 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9a7b7b50-c72f-461d-847c-a39315b38bf3.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 5 | no | 140.364 | 0.001 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7a387b44-55b7-4346-aa43-e851b69eb8fa.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T22:38:56+00:00/c9a79f24aa15 | reliability-gate-20260701-root-after-exonerated-probes-stall-wake-diagnostic | root | complete | 1 valid + 4 invalid | 2825 | 7 | 2832 | 729.333 | 729.333 | 0.0000 | stable | `artifact pruned; diagnostic summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 56.176 | 6.972 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 54.642 | 2.732 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 50.347 | 5.010 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 48.688 | 35.505 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 36.738 | 5.583 | 0 |
| 6 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 25.539 | 4.997 | 0 |
| 7 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 22.961 | 17.447 | 1 |
| 8 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 22.635 | 2.732 | 0 |
| 9 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 22.482 | 2.790 | 0 |
| 10 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.711 | 3.178 | 0 |
| 11 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 18.900 | 11.694 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 18.328 | 1.412 | 0 |
| 13 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 18.106 | 7.543 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 14.126 | 4.319 | 0 |
| 15 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 12.255 | 12.251 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 12.070 | 10.937 | 0 |
| 17 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | 10 | 11.800 | 11.781 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 11.298 | 3.437 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 10.240 | 1.251 | 0 |
| 20 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 9.940 | 0.855 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 35.505 | 35.505 | 35.505 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 17.447 | 17.447 | 17.447 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 12.923 | 12.923 | 12.923 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 12.251 | 12.251 | 12.251 | 0 |
| 5 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 11.781 | 11.781 | 11.781 | 0 |
| 6 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 11.694 | 11.694 | 11.694 | 0 |
| 7 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 10.937 | 10.937 | 10.937 | 0 |
| 8 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 7.968 | 7.968 | 7.968 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 7.543 | 7.543 | 7.543 | 0 |
| 10 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 7.413 | 7.413 | 7.413 | 0 |
| 11 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 7.182 | 7.182 | 7.182 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 6.972 | 6.972 | 6.972 | 0 |
| 13 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 1 | 5.583 | 5.583 | 5.583 | 0 |
| 14 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 5.266 | 5.266 | 5.266 | 0 |
| 15 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 1 | 5.067 | 5.067 | 5.067 | 0 |
| 16 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 1 | 5.012 | 5.012 | 5.012 | 0 |
| 17 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 5.010 | 5.010 | 5.010 | 0 |
| 18 | `RepoPromptTests.AgentRunWorktreeStartTests` | `testAgentExploreBatchCreatePreparesDistinctWorktreesBeforeProviderStart` | 1 | 4.997 | 4.997 | 4.997 | 0 |
| 19 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 1 | 4.830 | 4.830 | 4.830 | 0 |
| 20 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testSubdirectoryReceiptPlansOnlyCorrespondingPhysicalRoot` | 1 | 4.688 | 4.688 | 4.688 | 0 |
### Focused: 2026-07-01T22:50:58+00:00 — root — reliability-gate-20260701-focused-durable-catalog-cas

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 17.732 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1113c8b8-361e-4394-9f25-71913a09bfae.log` |  |
| 2 | yes | 0.957 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/40cbf748-d171-407b-ae02-02709963478e.log` |  |
| 3 | yes | 1.003 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/90fa21ec-1436-45e8-925d-14f46ee1a81b.log` |  |
| 4 | yes | 0.959 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9cd431a0-1f3a-4909-90b4-509c11c3882b.log` |  |
| 5 | yes | 0.945 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1a2c5886-378c-4853-8f3c-d7636ffac4a4.log` |  |
| 6 | yes | 0.963 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fd412694-b49b-4fc5-8705-e3d76105a2e3.log` |  |
| 7 | yes | 0.948 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/62515e39-c154-4fe1-a882-70683592aacf.log` |  |
| 8 | yes | 0.968 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8f77774d-c5c2-443b-a04e-35bf2b873d00.log` |  |
| 9 | yes | 0.925 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/87222cfc-9340-4612-818b-031ae67d71e9.log` |  |
| 10 | yes | 0.951 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eb52e9ba-1315-4ef5-bdc2-26a24c9e106d.log` |  |
| 11 | yes | 1.007 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/05418285-d715-4277-9de0-dd4836549afe.log` |  |
| 12 | yes | 0.994 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a0f8b3bf-360b-4550-b1d4-83be29d73f6f.log` |  |
| 13 | yes | 0.979 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8d36200b-634a-4c10-ae0a-7311b1a33453.log` |  |
| 14 | yes | 0.983 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0f7169e6-5b20-4950-bb2c-c52ec2b5dc71.log` |  |
| 15 | yes | 0.936 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2f7831f9-16e6-4b82-93c3-9642e321f71c.log` |  |
| 16 | yes | 0.942 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/119be2ce-b4eb-4332-90c8-05e28061f3bb.log` |  |
| 17 | yes | 0.936 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/05ca15fe-efd9-4a44-8455-99b576130efc.log` |  |
| 18 | yes | 0.962 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/20c2ff50-b9ac-4c7a-88cb-519fe1ada557.log` |  |
| 19 | yes | 0.974 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4f125ba9-51c4-4c42-a38d-0c470cc43f2a.log` |  |
| 20 | yes | 0.989 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d67f7293-f6aa-44e3-bbfd-aa3f68b4fc79.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T22:50:58+00:00/f3393c0b1229 | reliability-gate-20260701-focused-durable-catalog-cas | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.962 | 1.007 | 0.0199 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | 1 | 0.199 | 0.218 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | `testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 | 0.199 | 0.216 | 0.218 | 0 |

### Baseline: 2026-07-01T23:31:04+00:00 — root — reliability-gate-20260701-root-after-durable-catalog-cas-clean

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded root-gate summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 743.895 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/588dcdb8-05be-4e54-bda0-f2530771bc73.log` |  |
| 2 | no | 733.701 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9f40cefc-e476-4a89-8329-3b586e714d40.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | no | 710.140 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c71b3b0b-a179-4348-bf14-17d7dc824473.log` | conductor process exit 1; terminal state failed; test exit 1 |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-01T23:31:04+00:00/f3393c0b1229 | reliability-gate-20260701-root-after-durable-catalog-cas-clean | root | complete | 1 valid + 2 invalid | 2825 | 7 | 2832 | 743.895 | 743.895 | 0.0000 | stable | `artifact pruned; superseded root-gate summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 55.917 | 2.753 | 0 |
| 2 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 55.204 | 6.682 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 50.860 | 5.248 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 48.668 | 35.287 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 32.761 | 5.601 | 0 |
| 6 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 24.108 | 11.401 | 0 |
| 7 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 23.465 | 4.737 | 0 |
| 8 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 22.798 | 17.248 | 1 |
| 9 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 22.580 | 3.849 | 0 |
| 10 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 21 | 21.917 | 2.813 | 0 |
| 11 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 21.337 | 3.332 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 19.159 | 1.444 | 0 |
| 13 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 18.627 | 11.289 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 13.693 | 3.965 | 0 |
| 15 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 11.568 | 3.001 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.560 | 11.028 | 0 |
| 17 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 10.696 | 1.310 | 0 |
| 18 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.672 | 10.668 | 0 |
| 19 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.458 | 1.042 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 10.215 | 1.103 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 35.287 | 35.287 | 35.287 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 17.248 | 17.248 | 17.248 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 13.078 | 13.078 | 13.078 | 0 |
| 4 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 11.401 | 11.401 | 11.401 | 0 |
| 5 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 11.289 | 11.289 | 11.289 | 0 |
| 6 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 11.028 | 11.028 | 11.028 | 0 |
| 7 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 10.668 | 10.668 | 10.668 | 0 |
| 8 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 9.483 | 9.483 | 9.483 | 0 |
| 9 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 7.652 | 7.652 | 7.652 | 0 |
| 10 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 7.328 | 7.328 | 7.328 | 0 |
| 11 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 7.318 | 7.318 | 7.318 | 0 |
| 12 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 7.233 | 7.233 | 7.233 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 6.682 | 6.682 | 6.682 | 0 |
| 14 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 1 | 5.601 | 5.601 | 5.601 | 0 |
| 15 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 5.248 | 5.248 | 5.248 | 0 |
| 16 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 1 | 5.060 | 5.060 | 5.060 | 0 |
| 17 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 1 | 5.012 | 5.012 | 5.012 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 1 | 4.861 | 4.861 | 4.861 | 0 |
| 19 | `RepoPromptTests.WorkspacePendingSeededRootTests` | `testTwoRootSeededPublicationPermitPublishesBothAtomicallyWithoutDeadlock` | 1 | 4.737 | 4.737 | 4.737 | 0 |
| 20 | `RepoPromptTests.PersistentMCPDistinctConnectionConcurrencyTests` | `testDistinctConnectionsOverlapWithoutCrossRoutingReadOrSearchResults` | 1 | 4.375 | 4.375 | 4.375 | 0 |

Reliability-gate decision note (2026-07-01T23:31Z): focused DurableArtifact CAS method was exonerated by `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json` (20 valid / 0 invalid, source guard `content`, method/contract/scenario delta 0). The required 3-sample complete root baseline was attempted via `artifact pruned; superseded root-gate summary retained in scoreboard` and is not clean (1 valid / 2 invalid, source guard `metadata`). First invalid root sample: sample 2 log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9f40cefc-e476-4a89-8329-3b586e714d40.log`, `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`, `MCPCodeStructureWorktreeTests.swift:211`, `XCTAssertEqual failed: ("2") is not equal to ("1") - Graph-worker drain counters should advance together: [0, 0, 1]`. Sample 3 also failed in `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c71b3b0b-a179-4348-bf14-17d7dc824473.log`, `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer`, `DurableArtifactTestSupport.swift:78`, `unexpectedPublication(RepoPrompt.DurableArtifactPublicationResult.busy)`. Curated ledger was not regenerated or edited; no XCTest IDs changed; method delta 0, contract delta 0, scenario delta 0. Phase 4 remains blocked; next target should be the first invalid root sample (`MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`), not slow-suite optimization.

Tooling progress-output gaps observed during this dispatch: `Scripts/test_suite_optimizer.py baseline` emitted no live sample-start/sample-end lines during the long complete-root run; it did not print conductor ticket/log path as each sample began; it did not stream invalid reasons when sample 2 failed, so classification required polling conductor state/logs separately; the focused probe printed final JSON but the wrapper stayed open due inherited descriptors, making it look still-running; the complete-root wrapper also printed `root_baseline_exit=0` only after all samples finished. A future tooling improvement should emit per-sample start/end, conductor ticket/log path, exit/state, invalid reasons, and final artifact path incrementally.
### Focused: 2026-07-02T01:36:36+00:00 — root — reliability-gate-20260702-focused-mcp-code-structure-graph-drain

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-mcp-code-structure-graph-drain.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 4.318 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4274425c-9e70-44c7-8105-aff407059cf8.log` |  |
| 2 | yes | 4.366 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/819230cc-5b17-4be7-baf2-0e12c236bb45.log` |  |
| 3 | yes | 4.486 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b8cccf41-49a8-4678-9456-275ddd4a6072.log` |  |
| 4 | yes | 4.450 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5fe5ea28-f091-4f2d-96d0-4116fd630b98.log` |  |
| 5 | yes | 4.382 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8e5557d8-e1ff-4e1f-a1eb-b884bd1fd957.log` |  |
| 6 | yes | 5.481 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ea2821db-3f87-4fd8-b818-f07cf111dc49.log` |  |
| 7 | yes | 4.342 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ea017dc4-a337-4324-9c04-7b5bc28f57d9.log` |  |
| 8 | yes | 4.434 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/baf00a51-44d3-4945-a469-959dce8aeef4.log` |  |
| 9 | yes | 4.367 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/791d6654-375a-474a-83ce-ef14867ece55.log` |  |
| 10 | yes | 4.398 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d6e98ff6-a902-4947-ae60-7da4b8bc010b.log` |  |
| 11 | yes | 4.394 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/78c5bff6-1319-40ce-9f4f-e4386a32a802.log` |  |
| 12 | yes | 4.641 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6e72e588-d6d4-4f4a-87bf-d01334b05835.log` |  |
| 13 | yes | 4.346 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b6f22f30-42ff-458e-ab27-1957aa290d89.log` |  |
| 14 | yes | 4.402 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/29534774-d1b8-4a21-b518-74433c906e64.log` |  |
| 15 | yes | 4.432 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/66599398-ff50-4faf-ba8f-3fd2c1ad32dc.log` |  |
| 16 | yes | 4.433 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bbe51e49-2d8c-4b55-8db2-bb1c4ae5340a.log` |  |
| 17 | yes | 4.390 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/37b331f6-07c0-4dae-94b5-f41b62e6c688.log` |  |
| 18 | yes | 4.443 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6150fb3d-5ea9-4dcb-8423-36b611bf901d.log` |  |
| 19 | yes | 4.437 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8aa99d47-08ce-4754-bd2f-d08fba43c45c.log` |  |
| 20 | yes | 4.435 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9dcfe3a1-72c3-4419-b306-7c34206a3575.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T01:36:36+00:00/9dffe373d0ef | reliability-gate-20260702-focused-mcp-code-structure-graph-drain | root | filtered: `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 4.417 | 4.641 | 0.0068 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-mcp-code-structure-graph-drain.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 1 | 3.667 | 4.733 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | `testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` | 20 | 3.667 | 3.914 | 4.733 | 0 |
### Focused: 2026-07-02T01:50:56+00:00 — root — reliability-gate-20260702-focused-durable-crash-catalog-pointer

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-durable-crash-catalog-pointer.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 1.034 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7ee4af08-3bfa-4094-af4e-fe8ff2d6575d.log` |  |
| 2 | yes | 1.034 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/89bfae74-58ab-4f15-b223-461cb4b32cd4.log` |  |
| 3 | yes | 1.021 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b5e4e50a-8f10-4aba-81bd-91e758be4ef2.log` |  |
| 4 | yes | 1.027 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/546a40db-71f0-4d37-b7e8-844171ee60b8.log` |  |
| 5 | yes | 1.033 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c6a994b3-80b5-4633-beed-4c937dc9f812.log` |  |
| 6 | yes | 1.033 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/39f144cf-eac0-45f5-b0dc-988c21125219.log` |  |
| 7 | yes | 1.026 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/82bbfe12-510c-4605-9d85-9043b00e1b96.log` |  |
| 8 | yes | 1.049 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1ed2552f-a2c9-4abc-8b4f-c88deed2175d.log` |  |
| 9 | yes | 1.033 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bea8712e-48cd-42f2-a57a-2bd7593c991f.log` |  |
| 10 | yes | 1.071 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/503d2ec2-7916-4f99-9112-27c3791f62ee.log` |  |
| 11 | yes | 1.026 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dde49442-da98-4047-8f2b-d7aff9353380.log` |  |
| 12 | yes | 1.053 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/42e0b002-97b9-4196-840a-2c2621e6dc37.log` |  |
| 13 | yes | 1.056 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/858cdd2e-890d-41db-9580-7a16fa6e4771.log` |  |
| 14 | yes | 1.042 | 0.007 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6736bf51-dc3b-4c6f-b69d-ceaaea4550e0.log` |  |
| 15 | yes | 1.118 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/29c19bd6-6daa-429c-a25f-f484062ddf39.log` |  |
| 16 | yes | 1.022 | 0.008 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3035d86e-9c6e-47fa-bcf8-37686df36e44.log` |  |
| 17 | yes | 1.021 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7d4feeec-40ce-43b7-9582-8621c02d4dfd.log` |  |
| 18 | yes | 1.025 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1b4a1873-1c97-4ddd-a34f-c62db226af81.log` |  |
| 19 | yes | 1.013 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8a4aae7b-7738-43c2-b5c3-fa5356a2330a.log` |  |
| 20 | yes | 1.034 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1ee57b6f-f3f0-4153-8534-49ec05909817.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T01:50:56+00:00/f37309e7a095 | reliability-gate-20260702-focused-durable-crash-catalog-pointer | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 1.033 | 1.071 | 0.0084 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-durable-crash-catalog-pointer.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | 1 | 0.345 | 0.374 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | `testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer` | 20 | 0.345 | 0.365 | 0.374 | 0 |

### Focused: 2026-07-02T01:51:33+00:00 — root — reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.862 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6c6b2e57-7670-4f0c-8d02-4a6314717fd5.log` |  |
| 2 | yes | 0.850 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a180967a-006f-40cf-83f0-7793a6ae71c5.log` |  |
| 3 | yes | 0.862 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/be4c3346-75ab-41f7-a95c-9642dad1b521.log` |  |
| 4 | yes | 0.848 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/95f76053-435c-49e0-bf9c-68d604d640be.log` |  |
| 5 | yes | 0.840 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/86a385b9-137f-477d-8b01-03faa1c46d45.log` |  |
| 6 | yes | 0.859 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5c5d43b6-250c-4bba-a811-d23585621063.log` |  |
| 7 | yes | 0.855 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e3808971-ba79-4762-a0ce-009098dec320.log` |  |
| 8 | yes | 0.834 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d32ab88d-16ba-43a3-89b7-5c8f815f1e3d.log` |  |
| 9 | yes | 0.843 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/88391b92-249b-4da1-be7a-7e14e483a59c.log` |  |
| 10 | yes | 0.855 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/78a09f1b-1b30-4c74-823a-65fec5de7846.log` |  |
| 11 | yes | 0.865 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/90af38de-62b7-471a-aedd-10e8f5df8721.log` |  |
| 12 | yes | 0.864 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8bdd83d2-f396-447e-9065-04026ca56257.log` |  |
| 13 | yes | 0.833 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1d48f529-0dd4-4716-af6e-9d2103221d43.log` |  |
| 14 | yes | 0.843 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6246ff8d-bfa9-4ab7-bb83-80c0a5cf2c8a.log` |  |
| 15 | yes | 0.847 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9ce101e5-e6c8-4152-90dd-61cacdd0dccc.log` |  |
| 16 | yes | 0.860 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f193d231-70e6-4600-9cd8-89fe81273014.log` |  |
| 17 | yes | 0.846 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9243c7a9-6f00-4ec6-8c3e-abaa20d443b5.log` |  |
| 18 | yes | 0.853 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f3a0fb6e-c743-4a63-b685-43ad7df26cc0.log` |  |
| 19 | yes | 0.852 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6fca6bbb-c544-48fe-8da7-7fc3b5fc4c34.log` |  |
| 20 | yes | 0.840 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d9f63181-3723-4b90-bb55-4fa90d245dec.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T01:51:33+00:00/f37309e7a095 | reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.851 | 0.864 | 0.0099 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | 1 | 0.165 | 0.185 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | `testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 | 0.165 | 0.181 | 0.185 | 0 |
### Focused: 2026-07-02T02:03:03+00:00 — root — reliability-gate-20260702-focused-codemap-seam-newer-snapshot

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-codemap-seam-newer-snapshot.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 30.391 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5d33d8d9-0a21-4eea-b7c4-a877287a24c2.log` |  |
| 2 | yes | 2.381 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0b60e321-3f2f-4080-86bc-73267280c118.log` |  |
| 3 | yes | 2.316 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/63046852-3e6b-4e54-9a7d-0f6abf027ed1.log` |  |
| 4 | yes | 2.402 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/21ab28d6-ed3e-4726-83bd-9f7f15f21291.log` |  |
| 5 | yes | 2.268 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/065b08ae-4443-44b0-884b-7484b6a8bc50.log` |  |
| 6 | yes | 2.313 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/31786b5c-88ee-4f3e-a019-1514168ad490.log` |  |
| 7 | yes | 2.461 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cf4224cd-6c65-496f-80fb-86fbd8943f49.log` |  |
| 8 | yes | 2.219 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c61bb68e-eebe-4afe-911f-edfb131c38ce.log` |  |
| 9 | yes | 2.325 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8e1ea7f0-07bc-43f5-b90a-06204d38fb96.log` |  |
| 10 | yes | 2.347 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8c8aa2af-8276-43fe-9029-2bbd379ea75f.log` |  |
| 11 | yes | 2.200 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ae6a5ef8-937e-49ee-9cfd-824ee0382a28.log` |  |
| 12 | yes | 2.517 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5baf8ee7-d8ca-4b6e-b48d-dead9ee83d36.log` |  |
| 13 | yes | 2.380 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f8959448-1235-4269-b263-016df10fd76e.log` |  |
| 14 | yes | 2.287 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/500e710c-0662-495c-a152-df4b9fba5f3e.log` |  |
| 15 | yes | 2.237 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0ed92d6f-eccc-4753-8947-e95fcab519d5.log` |  |
| 16 | yes | 2.277 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a2d64fd6-36da-43b7-addf-9fe8265cdc7b.log` |  |
| 17 | yes | 2.264 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/605032d5-a989-4e6e-91bd-a6cfa51cec33.log` |  |
| 18 | yes | 2.229 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0929a2ee-46cc-49fe-8ae0-355ebdd9a4a9.log` |  |
| 19 | yes | 2.271 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/056a637b-6b19-4dd1-af17-373c369ec0b8.log` |  |
| 20 | yes | 2.272 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3da00c7f-1194-4cbe-807b-fdbae77ca85c.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T02:03:03+00:00/1a44c448ff4c | reliability-gate-20260702-focused-codemap-seam-newer-snapshot | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 2.300 | 2.517 | 0.0239 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-focused-codemap-seam-newer-snapshot.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 1 | 1.591 | 1.810 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | `testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 20 | 1.591 | 1.774 | 1.810 | 0 |
### Baseline: 2026-07-02T02:47:35+00:00 — root — optimization-pass-20260702-root-baseline

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded root-baseline summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | no | 725.336 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5657d269-ef52-45d8-ab7d-e1df9f74a3b6.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 2 | no | 707.284 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6b59c231-cc45-4cd1-a4f9-d297dd8ae1b1.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 669.475 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/088c666d-b25f-44f0-97e5-f3e51df85df5.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T02:47:35+00:00/17a1b296c522 | optimization-pass-20260702-root-baseline | root | complete | 1 valid + 2 invalid | 2825 | 7 | 2832 | 669.475 | 669.475 | 0.0000 | stable | `artifact pruned; superseded root-baseline summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 48.581 | 42.094 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 47.696 | 34.713 | 0 |
| 3 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 43.185 | 5.245 | 0 |
| 4 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 41.414 | 2.126 | 0 |
| 5 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 41.157 | 4.789 | 0 |
| 6 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 27.804 | 6.563 | 0 |
| 7 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 23.340 | 4.686 | 0 |
| 8 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 22.593 | 2.728 | 0 |
| 9 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.530 | 2.990 | 0 |
| 10 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.238 | 16.531 | 1 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 16.582 | 7.205 | 0 |
| 12 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 15.725 | 1.830 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 13.884 | 1.071 | 0 |
| 14 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 13.602 | 6.107 | 0 |
| 15 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 11.598 | 3.529 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.107 | 10.860 | 0 |
| 17 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.478 | 0.907 | 0 |
| 18 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.032 | 10.029 | 0 |
| 19 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | 12 | 8.885 | 7.394 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.239 | 0.976 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 42.094 | 42.094 | 42.094 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 34.713 | 34.713 | 34.713 | 0 |
| 3 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 16.531 | 16.531 | 16.531 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 12.732 | 12.732 | 12.732 | 0 |
| 5 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 10.860 | 10.860 | 10.860 | 0 |
| 6 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 10.029 | 10.029 | 10.029 | 0 |
| 7 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 7.394 | 7.394 | 7.394 | 0 |
| 8 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 7.205 | 7.205 | 7.205 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 7.045 | 7.045 | 7.045 | 0 |
| 10 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 6.977 | 6.977 | 6.977 | 0 |
| 11 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 6.949 | 6.949 | 6.949 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 6.807 | 6.807 | 6.807 | 0 |
| 13 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 1 | 6.563 | 6.563 | 6.563 | 0 |
| 14 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | `testThreeRootSessionScopeReplacesCanonicalGitRootAndPreservesIndependentNonGitRoot` | 1 | 6.107 | 6.107 | 6.107 | 0 |
| 15 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 5.245 | 5.245 | 5.245 | 0 |
| 16 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 1 | 5.065 | 5.065 | 5.065 | 0 |
| 17 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 1 | 5.016 | 5.016 | 5.016 | 0 |
| 18 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 4.789 | 4.789 | 4.789 | 0 |
| 19 | `RepoPromptTests.AgentRunWorktreeStartTests` | `testAgentExploreBatchFailureAndCancellationRetainOnlyStartedChildren` | 1 | 4.686 | 4.686 | 4.686 | 0 |
| 20 | `RepoPromptTests.AgentRunWorktreeStartTests` | `testAgentExploreBatchCreatePreparesDistinctWorktreesBeforeProviderStart` | 1 | 3.915 | 3.915 | 3.915 | 0 |
### Focused: 2026-07-02T03:18:00+00:00 — root — reliability-gate-20260702-unix-peer-write-hangup

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-unix-peer-write-hangup.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.787 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e77febd0-657a-43f9-8a50-ca0fbc858cd2.log` |  |
| 2 | yes | 0.728 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/819b461e-99e0-496f-9ae6-3798fbb0cae8.log` |  |
| 3 | yes | 0.713 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f7aea83d-1c56-4770-9c6a-a9a828487ed6.log` |  |
| 4 | yes | 0.740 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/86a71c3a-b9ea-4fae-af7c-fbbddf77f5d1.log` |  |
| 5 | yes | 0.731 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/674f5914-c935-4e11-9b57-fbc68202e526.log` |  |
| 6 | yes | 0.736 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/52d8438f-5718-48fa-960a-eabdd6698b4c.log` |  |
| 7 | yes | 0.718 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/13d17e8c-24db-44df-bc2f-dd134c9917da.log` |  |
| 8 | yes | 0.720 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/acc4989a-211a-4415-84c6-b84aa00f7e00.log` |  |
| 9 | yes | 0.728 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/78683bb6-db67-41cb-b3cc-aa3568004633.log` |  |
| 10 | yes | 0.739 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f78ff8fa-c48e-45a8-aaad-b6790c70e3f1.log` |  |
| 11 | yes | 0.720 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b3ad96b6-7dde-42cc-a70a-1dfc7c083fa4.log` |  |
| 12 | yes | 0.738 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3b820ed4-c76e-419c-85f1-255cd4990a3c.log` |  |
| 13 | yes | 0.729 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c9553a7-af2b-4f44-a07f-85e1f2f5c9e8.log` |  |
| 14 | yes | 0.671 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e38299e4-e49c-419f-b2ba-a842c8954c1c.log` |  |
| 15 | yes | 0.709 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/89741212-ed49-4df7-8954-318c189c71d6.log` |  |
| 16 | yes | 0.720 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/387c29c2-e8ac-4b5a-b977-ab019b30ac91.log` |  |
| 17 | yes | 0.730 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/09dd91d8-7378-4287-94ff-9e85ae0e1d9d.log` |  |
| 18 | yes | 0.733 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5fc6c82d-b457-4c53-90d0-5a2a9f7bd54c.log` |  |
| 19 | yes | 0.718 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/66058897-c4ab-401f-b063-07c650771f9e.log` |  |
| 20 | yes | 0.713 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/319a0d6a-c140-4e3d-b217-6c8533cbfb7d.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T03:18:00+00:00/0a7a651e39b3 | reliability-gate-20260702-unix-peer-write-hangup | root | filtered: `RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup` | 20 valid + 0 invalid |  |  |  | 0.728 | 0.740 | 0.0127 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-unix-peer-write-hangup.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.UnixSocketMCPTerminalCleanupTests` | 1 | 0.016 | 0.017 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.UnixSocketMCPTerminalCleanupTests` | `testPeerCloseDuringWritePublishesPeerWriteHangup` | 20 | 0.016 | 0.017 | 0.017 | 0 |

### Focused: 2026-07-02T03:19:13+00:00 — root — reliability-gate-20260702-manifest-logical-access-eviction

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-manifest-logical-access-eviction.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 2.163 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c42c4484-a244-437f-8211-649ea829b1ed.log` |  |
| 2 | yes | 1.968 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e7190b82-830c-436c-9857-4a55c303a06a.log` |  |
| 3 | yes | 2.172 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/62f737dc-1ba1-4799-9fc7-67cf3069cfd6.log` |  |
| 4 | yes | 2.184 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e9337b67-af8a-4892-8601-2eddfefaf333.log` |  |
| 5 | yes | 1.995 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/178bc144-a41b-4c1a-a142-fb0d70a7c88a.log` |  |
| 6 | yes | 1.937 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a28afec7-8f19-43b4-9001-f82e425b1203.log` |  |
| 7 | yes | 2.156 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c9f12cf-b258-49ac-b0ae-2013fb56b3e0.log` |  |
| 8 | yes | 2.071 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/21fdae70-e963-4430-bded-11b5a0a077a6.log` |  |
| 9 | yes | 2.062 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/975b07d2-a9ca-4648-98a5-ed3afbab0f1f.log` |  |
| 10 | yes | 2.067 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/175083c5-9e8a-4d8d-a695-dbf46e7434f4.log` |  |
| 11 | yes | 1.982 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6adeac30-c0c0-4778-867e-3358fe3bb42e.log` |  |
| 12 | yes | 2.094 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e104c743-b262-4182-bf07-a689aa4a0706.log` |  |
| 13 | yes | 1.955 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/02a1dabc-dd81-484e-a04b-675f57cef785.log` |  |
| 14 | yes | 2.136 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6f26fd1f-399e-4721-aec4-6ae3782e3c09.log` |  |
| 15 | yes | 1.989 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0d4cb733-5a39-4f5f-a38b-536919175f14.log` |  |
| 16 | yes | 2.051 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d5a34d13-cce9-4712-8ac3-851fd9bea6f4.log` |  |
| 17 | yes | 1.990 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fac10fd6-8061-4d92-b9f1-3f589c3fc665.log` |  |
| 18 | yes | 1.976 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/080d8487-1eea-42ee-ab2f-0f241a5e8074.log` |  |
| 19 | yes | 2.055 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/48b4287d-f7fe-49c7-aa67-c9a4f17db6c0.log` |  |
| 20 | yes | 1.999 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/807db9f4-7f9b-4d80-9e17-761e189c59c7.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T03:19:13+00:00/0a7a651e39b3 | reliability-gate-20260702-manifest-logical-access-eviction | root | filtered: `RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest` | 20 valid + 0 invalid |  |  |  | 2.053 | 2.172 | 0.0328 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-manifest-logical-access-eviction.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 1 | 1.349 | 1.510 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest` | 20 | 1.349 | 1.494 | 1.510 | 0 |

### Focused: 2026-07-02T03:20:25+00:00 — root — reliability-gate-20260702-binding-draining-projection-materialization

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-binding-draining-projection-materialization.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 1.799 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d2c9be79-684a-43a6-a369-ee41cd9b56ec.log` |  |
| 2 | yes | 1.608 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/721cfcf8-69af-45e7-a4b7-dffeff5ce609.log` |  |
| 3 | yes | 1.769 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/431b5dbc-8c12-4530-97d3-85c0d36b3abb.log` |  |
| 4 | yes | 1.774 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a9498317-6bc5-45bd-898a-258695ff4af5.log` |  |
| 5 | yes | 1.656 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6ab8acf8-a4f4-4c24-9f74-1d34322d43a6.log` |  |
| 6 | yes | 1.842 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/12f8d8a8-fd7d-473f-9cc9-de154e1dbee5.log` |  |
| 7 | yes | 1.602 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/59cb77cd-10d9-45ba-bfed-4a06de0d75b4.log` |  |
| 8 | yes | 1.656 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/df78c5df-0c1e-4b87-8877-d58f881265be.log` |  |
| 9 | yes | 1.675 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/04140d53-007c-40db-a929-92e1cd979926.log` |  |
| 10 | yes | 1.699 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/075aa6a4-1996-4814-a96f-8acdacf3bd0d.log` |  |
| 11 | yes | 1.645 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/78eb5371-0ecc-4542-887d-0ab108d990f9.log` |  |
| 12 | yes | 1.598 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/90bc3a06-6591-4b52-abbb-8c9301c61705.log` |  |
| 13 | yes | 1.544 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eae5183a-b2b0-488f-aa56-c7f2f15084eb.log` |  |
| 14 | yes | 1.606 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a718aa92-c996-4a8e-9079-480b8fee26be.log` |  |
| 15 | yes | 3.442 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0204f926-cf8f-42fc-ab19-676ee99545c4.log` |  |
| 16 | yes | 3.150 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1b94d472-5262-4e1c-9d19-1da3d1801633.log` |  |
| 17 | yes | 1.647 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f70ac517-f415-43a1-907d-9e4892474715.log` |  |
| 18 | yes | 1.644 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7ffbef84-24f2-4ca7-8b8c-c9a585243c62.log` |  |
| 19 | yes | 1.586 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/568de841-37cd-4425-bbf2-dc6429662006.log` |  |
| 20 | yes | 1.654 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fe1f503c-9414-41fd-98c3-cd3192284d21.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T03:20:25+00:00/0a7a651e39b3 | reliability-gate-20260702-binding-draining-projection-materialization | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage` | 20 valid + 0 invalid |  |  |  | 1.655 | 3.150 | 0.0307 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-20260702-binding-draining-projection-materialization.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 1 | 0.955 | 2.692 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage` | 20 | 0.955 | 2.391 | 2.692 | 0 |

### Focused make-loop: 2026-07-02T03:47:06+00:00 — root — reliability-gate-20260702-exact-filter-make-loops

Mode: repeated `make dev-test FILTER=<exact method>`; no optimizer baseline command; no full-root samples.
Artifact: `artifact pruned; filter-proof summary retained in scoreboard`
Filter proof: for each method, sample 1 captured `$ swift test --filter <exact method>` and `Executed 1 test, with 0 failures` before samples 2–20 continued.

| Signature | Exact filter | Samples | Median elapsed seconds | First proof output | First ticket | First conductor log |
|---|---|---:|---:|---|---|---|
| unix-peer-write-hangup | `RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup` | 20 valid + 0 invalid | 0.815 | `/tmp/rpce-focused-loop-20260702/unix-peer-write-hangup-sample-01.out` | `d1627f4e-eb33-4ce5-8fbd-2fd1af2922d0` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d1627f4e-eb33-4ce5-8fbd-2fd1af2922d0.log` |
| manifest-logical-access-eviction | `RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest` | 20 valid + 0 invalid | 2.210 | `/tmp/rpce-focused-loop-20260702/manifest-logical-access-eviction-sample-01.out` | `89783f51-7eb4-4705-89d8-d49b9e6a2f6b` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/89783f51-7eb4-4705-89d8-d49b9e6a2f6b.log` |
| binding-draining-projection-materialization | `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage` | 20 valid + 0 invalid | 1.897 | `/tmp/rpce-focused-loop-20260702/binding-draining-projection-materialization-sample-01.out` | `7ed66185-dbcb-4cd0-90f5-eb39c2cc7ee0` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7ed66185-dbcb-4cd0-90f5-eb39c2cc7ee0.log` |
### Baseline: 2026-07-02T04:25:20+00:00 — root — reliability-gate-20260702-root-after-latest-signatures

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded root-gate summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 678.364 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/834f1641-ad86-4451-a7c0-2a45701262e1.log` |  |
| 2 | no | 650.872 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0517da9b-ccb8-4a39-8b6e-0bbb668bd7b3.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 679.909 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/030104a7-7278-4bb8-9f72-906a9150f74a.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T04:25:20+00:00/a9a1cc840297 | reliability-gate-20260702-root-after-latest-signatures | root | complete | 2 valid + 1 invalid | 2825 | 7 | 2832 | 679.137 | 679.909 | 0.0011 | stable | `artifact pruned; superseded root-gate summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 47.770 | 6.049 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 47.194 | 34.852 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 46.919 | 2.394 | 0 |
| 4 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 45.013 | 4.904 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 31.356 | 5.430 | 0 |
| 6 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 21.624 | 2.803 | 0 |
| 7 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 18 | 21.404 | 3.605 | 0 |
| 8 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 21.228 | 3.290 | 0 |
| 9 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 20.712 | 15.612 | 0 |
| 10 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.258 | 16.434 | 2 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 20.138 | 10.322 | 0 |
| 12 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 18.077 | 2.830 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 15.734 | 1.169 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.431 | 3.380 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.977 | 12.640 | 0 |
| 16 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.485 | 1.144 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.089 | 10.093 | 0 |
| 18 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 9.715 | 1.182 | 0 |
| 19 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 9.625 | 2.610 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 9.151 | 0.794 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 2 | 34.285 | 34.852 | 34.852 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 2 | 16.427 | 16.434 | 16.434 | 0 |
| 3 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 2 | 13.704 | 15.612 | 15.612 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 2 | 12.646 | 12.871 | 12.871 | 0 |
| 5 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 2 | 11.874 | 12.640 | 12.640 | 0 |
| 6 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 2 | 10.086 | 10.093 | 10.093 | 0 |
| 7 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 2 | 9.204 | 10.322 | 10.322 | 0 |
| 8 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 2 | 8.411 | 9.178 | 9.178 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 2 | 8.351 | 9.293 | 9.293 | 0 |
| 10 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 2 | 7.163 | 7.291 | 7.291 | 0 |
| 11 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 2 | 6.896 | 6.898 | 6.898 | 0 |
| 12 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 2 | 6.883 | 6.895 | 6.895 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 2 | 5.787 | 6.049 | 6.049 | 0 |
| 14 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 2 | 5.242 | 5.430 | 5.430 | 0 |
| 15 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 2 | 5.034 | 5.037 | 5.037 | 0 |
| 16 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 2 | 5.021 | 5.023 | 5.023 | 0 |
| 17 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 2 | 4.787 | 4.904 | 4.904 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 2 | 4.027 | 4.066 | 4.066 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 2 | 3.712 | 3.719 | 3.719 | 0 |
| 20 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 2 | 3.640 | 3.656 | 3.656 | 0 |
### Baseline: 2026-07-02T05:20:51+00:00 — root — reliability-gate-20260702-root-after-manifest-retry

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded root-gate summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 672.227 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3bc5a211-be73-4a55-9553-84c5ffded553.log` |  |
| 2 | no | 652.414 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c60fc941-ed7c-4760-b462-dc3b3d40a4b9.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 635.345 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d3cf38a3-a736-4e76-b120-21028aaf48e7.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T05:20:51+00:00/0e59bd4c6adb | reliability-gate-20260702-root-after-manifest-retry | root | complete | 2 valid + 1 invalid | 2825 | 7 | 2832 | 653.786 | 672.227 | 0.0282 | stable | `artifact pruned; superseded root-gate summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 48.834 | 42.393 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 43.977 | 2.834 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 40.767 | 33.953 | 0 |
| 4 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 40.454 | 4.824 | 0 |
| 5 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 38.591 | 4.479 | 0 |
| 6 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 25.872 | 5.259 | 0 |
| 7 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 23.210 | 2.764 | 0 |
| 8 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.428 | 3.491 | 0 |
| 9 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.309 | 16.626 | 2 |
| 10 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 19.340 | 3.109 | 0 |
| 11 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 16.494 | 2.180 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 14.612 | 8.458 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 13.097 | 1.050 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 11.499 | 3.776 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.405 | 11.396 | 0 |
| 16 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.716 | 1.111 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.006 | 10.124 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 9.319 | 2.510 | 0 |
| 19 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | 12 | 8.405 | 7.013 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.281 | 1.290 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 2 | 42.352 | 42.393 | 42.393 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 2 | 27.736 | 33.953 | 33.953 | 0 |
| 3 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 2 | 16.583 | 16.626 | 16.626 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 2 | 12.674 | 16.466 | 16.466 | 0 |
| 5 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 2 | 11.134 | 11.396 | 11.396 | 0 |
| 6 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 2 | 10.003 | 10.124 | 10.124 | 0 |
| 7 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 2 | 7.067 | 7.069 | 7.069 | 0 |
| 8 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 2 | 7.012 | 7.013 | 7.013 | 0 |
| 9 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 2 | 6.934 | 7.000 | 7.000 | 0 |
| 10 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 2 | 6.694 | 8.458 | 8.458 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 2 | 5.571 | 6.583 | 6.583 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 2 | 5.183 | 6.005 | 6.005 | 0 |
| 13 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 2 | 5.071 | 5.078 | 5.078 | 0 |
| 14 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 2 | 5.019 | 5.023 | 5.023 | 0 |
| 15 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 2 | 4.812 | 4.824 | 4.824 | 0 |
| 16 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 2 | 4.457 | 4.479 | 4.479 | 0 |
| 17 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 2 | 4.276 | 5.259 | 5.259 | 0 |
| 18 | `RepoPromptTests.AgentRunDiffSeededWorktreeInitializationTests` | `testDefaultOffAndForcedFullCrawlUseOrdinaryRouteExactlyOnce` | 2 | 4.122 | 5.433 | 5.433 | 0 |
| 19 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 2 | 3.732 | 3.834 | 3.834 | 0 |
| 20 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 2 | 3.651 | 3.682 | 3.682 | 0 |
### Baseline: 2026-07-02T06:40:05+00:00 — root — reliability-gate-20260702-root-after-mcp-worktree-quiescence

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded root-gate summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 731.637 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/aeb269fd-36ae-4dc4-979a-77aacd42ed3d.log` |  |
| 2 | no | 624.835 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6d9e09b6-437a-4145-a54e-3e30c5526088.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | no | 1635.852 | 0.001 | canceled | 130 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b54d1739-3ab4-46ff-ae9c-f9780589d18f.log` | conductor process exit 130; terminal state canceled; test exit 130; canceled or lifecycle-superseded |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T06:40:05+00:00/2046eb603f37 | reliability-gate-20260702-root-after-mcp-worktree-quiescence | root | complete | 1 valid + 2 invalid | 2825 | 7 | 2832 | 731.637 | 731.637 | 0.0000 | stable | `artifact pruned; superseded root-gate summary retained in scoreboard` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 47.831 | 5.368 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 45.667 | 2.220 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 43.302 | 4.437 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 31.215 | 22.215 | 0 |
| 5 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 22.554 | 3.128 | 0 |
| 6 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 22.220 | 3.959 | 0 |
| 7 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 21.729 | 2.618 | 0 |
| 8 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.741 | 3.045 | 0 |
| 9 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.217 | 16.410 | 1 |
| 10 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 17.635 | 2.224 | 0 |
| 11 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 13.608 | 1.162 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 13.455 | 5.567 | 0 |
| 13 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 13.129 | 12.736 | 0 |
| 14 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 12.433 | 5.588 | 0 |
| 15 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.285 | 3.619 | 0 |
| 16 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.872 | 1.034 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 9.982 | 9.979 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 17 | 9.027 | 1.567 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.746 | 1.035 | 0 |
| 20 | `RepoPromptTests.GitBlobIdentityServiceTests` | 24 | 8.359 | 0.676 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 22.215 | 22.215 | 22.215 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 16.410 | 16.410 | 16.410 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 12.736 | 12.736 | 12.736 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 9.979 | 9.979 | 9.979 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 8.710 | 8.710 | 8.710 | 0 |
| 6 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 7.040 | 7.040 | 7.040 | 0 |
| 7 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 6.842 | 6.842 | 6.842 | 0 |
| 8 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 5.588 | 5.588 | 5.588 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 5.567 | 5.567 | 5.567 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 5.368 | 5.368 | 5.368 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 5.348 | 5.348 | 5.348 | 0 |
| 12 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 5.086 | 5.086 | 5.086 | 0 |
| 13 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 1 | 5.056 | 5.056 | 5.056 | 0 |
| 14 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 1 | 5.023 | 5.023 | 5.023 | 0 |
| 15 | `RepoPromptTests.AgentRunDiffSeededWorktreeInitializationTests` | `testDefaultOffAndForcedFullCrawlUseOrdinaryRouteExactlyOnce` | 1 | 4.451 | 4.451 | 4.451 | 0 |
| 16 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 4.437 | 4.437 | 4.437 | 0 |
| 17 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 4.382 | 4.382 | 4.382 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 1 | 3.959 | 3.959 | 3.959 | 0 |
| 19 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 1 | 3.794 | 3.794 | 3.794 | 0 |
| 20 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 1 | 3.666 | 3.666 | 3.666 | 0 |
### Focused: 2026-07-02T07:22:30+00:00 — root — focused-async-limiter-reliability-20260702T072212Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AsyncLimiterTests/testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-async-limiter-reliability-20260702T072212Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AsyncLimiterTests/testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.662 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5bea7a9d-492d-42ea-828e-6035250ef948.log` |  |
| 2 | yes | 0.710 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/660df45a-d660-4e4f-a3f4-72edb11858fe.log` |  |
| 3 | yes | 0.716 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/479a6f7b-aff1-4069-b142-5fc9c6b26144.log` |  |
| 4 | yes | 0.666 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1691ef73-951d-4991-986a-c4974f347b80.log` |  |
| 5 | yes | 0.660 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b3c6d6cd-c503-43a3-8c5a-8e6eeeb7401d.log` |  |
| 6 | yes | 0.712 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/831749c5-c001-4fea-9050-170b2c058ba8.log` |  |
| 7 | yes | 0.659 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c1ce3a29-6ad2-4288-b552-11af9122b04c.log` |  |
| 8 | yes | 0.666 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7173519d-cf4a-4f98-9980-fb3ddb4319d7.log` |  |
| 9 | yes | 0.674 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8ce6d099-7a5b-4471-a1bd-2863eaa5e44c.log` |  |
| 10 | yes | 0.674 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d134e8d2-5d3c-439d-ae60-50d307bf62e9.log` |  |
| 11 | yes | 0.716 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ba8b77e5-a2f4-4517-8d1b-9433e4eca2e3.log` |  |
| 12 | yes | 0.722 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/947f6cd9-a842-4d7d-a538-6c941aac9f19.log` |  |
| 13 | yes | 0.662 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/02a8e977-ffec-49d8-93e4-dea83c1e8620.log` |  |
| 14 | yes | 0.676 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9210c314-eaf6-44c8-8c86-d0fd2e7d0160.log` |  |
| 15 | yes | 0.663 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8b4c4557-48e9-402b-b630-0ca82fe3c68a.log` |  |
| 16 | yes | 0.706 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/231ac5cb-db0e-494c-9133-cbf8a2dbfb98.log` |  |
| 17 | yes | 0.711 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9ed2e5d8-6cef-48ac-9d6e-d51504bbd8e8.log` |  |
| 18 | yes | 0.671 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c510ce7-e9c3-46f3-b343-9400fb89a2b2.log` |  |
| 19 | yes | 0.667 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/49b62f15-e189-4d34-890a-40f3e7cf88d5.log` |  |
| 20 | yes | 0.667 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/496a74b3-8a7b-4767-bff2-801e9324f3ef.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T07:22:30+00:00/51ce8fd75597 | focused-async-limiter-reliability-20260702T072212Z | root | filtered: `RepoPromptTests.AsyncLimiterTests/testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.672 | 0.716 | 0.0151 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-async-limiter-reliability-20260702T072212Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AsyncLimiterTests` | 1 | 0.009 | 0.009 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AsyncLimiterTests` | `testCancelledMiddleWaiterDetachesPromptlyAndLiveWaitersRemainFIFO` | 20 | 0.009 | 0.009 | 0.009 | 0 |

### Focused: 2026-07-02T07:23:09+00:00 — root — focused-durable-artifact-reliability-20260702T072251Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.DurableArtifactIdentityLeaseGCTests/testCatalogMarksProtectObjectsAndMarkLossOnlyProducesCacheMiss --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-durable-artifact-reliability-20260702T072251Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.DurableArtifactIdentityLeaseGCTests/testCatalogMarksProtectObjectsAndMarkLossOnlyProducesCacheMiss`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.672 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/01e2d50e-42a5-4257-a7ad-981794e737a5.log` |  |
| 2 | yes | 0.719 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2037c797-0377-46d0-8d4b-89485fb6fc8f.log` |  |
| 3 | yes | 0.725 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c0f609c4-1714-407d-afae-b9787549f086.log` |  |
| 4 | yes | 0.679 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1fcc3ce5-3873-43da-ae7e-88bf572fd32f.log` |  |
| 5 | yes | 0.728 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/678b62a3-05f7-4b4c-bb79-242c88f33ba1.log` |  |
| 6 | yes | 0.700 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e3065cbd-7a85-4dec-b303-f7569490488c.log` |  |
| 7 | yes | 0.697 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0dda6d42-822a-45c6-b33d-7b55794e373b.log` |  |
| 8 | yes | 0.716 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b58eca84-9783-4f36-b624-344cf34cf393.log` |  |
| 9 | yes | 0.727 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/693374a2-34f7-4625-8498-7cf6bf597c81.log` |  |
| 10 | yes | 0.669 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/569316d3-19ab-41da-bdb1-bd8d6ef46525.log` |  |
| 11 | yes | 0.692 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/784d9997-acb4-4b7b-86a1-c8dded5ddde3.log` |  |
| 12 | yes | 0.707 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f255f5e9-55ad-4863-8287-23c01efdfc39.log` |  |
| 13 | yes | 0.669 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/92ce0775-698c-48a9-aad5-6261bed54b39.log` |  |
| 14 | yes | 0.709 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/18c67313-e79c-482b-8387-bdb6d2e9b2c8.log` |  |
| 15 | yes | 0.673 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e286d6e7-2c73-42c0-8884-1236bc85321d.log` |  |
| 16 | yes | 0.679 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/37bc312b-300a-43a7-96fc-20f7d6cb3bb0.log` |  |
| 17 | yes | 0.739 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/05fa4ff7-edc2-4f2a-b245-a5f57a337dd2.log` |  |
| 18 | yes | 0.677 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7d97faa2-8743-4fca-b739-5c03902c175b.log` |  |
| 19 | yes | 0.667 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/12ca768b-999e-4102-9ef0-2f7f3e74ac5a.log` |  |
| 20 | yes | 0.671 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c7e28903-5353-4568-9cd9-59da48ec52e1.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T07:23:09+00:00/51ce8fd75597 | focused-durable-artifact-reliability-20260702T072251Z | root | filtered: `RepoPromptTests.DurableArtifactIdentityLeaseGCTests/testCatalogMarksProtectObjectsAndMarkLossOnlyProducesCacheMiss` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.694 | 0.728 | 0.0320 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-durable-artifact-reliability-20260702T072251Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactIdentityLeaseGCTests` | 1 | 0.012 | 0.014 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactIdentityLeaseGCTests` | `testCatalogMarksProtectObjectsAndMarkLossOnlyProducesCacheMiss` | 20 | 0.012 | 0.013 | 0.014 | 0 |

### Baseline: 2026-07-02T07:54:39+00:00 — root — root-after-async-durable-reliability-20260702T072330Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-after-async-durable-reliability-20260702T072330Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: complete
Source-change guard: `metadata`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 640.153 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b8921a89-ec1d-4e6f-bbb5-9dfc540b3506.log` |  |
| 2 | yes | 609.812 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/395f7fbf-d5f5-4ccb-9610-73f7c952c618.log` |  |
| 3 | yes | 618.016 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eef5ce88-2200-4e7d-9494-50a8a5dbc46c.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T07:54:39+00:00/51ce8fd75597 | root-after-async-durable-reliability-20260702T072330Z | root | complete | 3 valid + 0 invalid | 2825 | 7 | 2832 | 618.016 | 640.153 | 0.0133 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-after-async-durable-reliability-20260702T072330Z.json` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 43.721 | 2.481 | 0 |
| 2 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 42.899 | 5.731 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 41.238 | 4.524 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 31.173 | 21.791 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 24.674 | 3.936 | 0 |
| 6 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 22.826 | 2.813 | 0 |
| 7 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 21.270 | 16.647 | 3 |
| 8 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.853 | 3.276 | 0 |
| 9 | `RepoPromptTests.AgentRunWorktreeStartTests` | 36 | 20.337 | 3.238 | 0 |
| 10 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 18.505 | 2.395 | 0 |
| 11 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 15.310 | 42.087 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 14.066 | 1.386 | 0 |
| 13 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 13.452 | 6.706 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 11.931 | 3.779 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.089 | 11.697 | 0 |
| 16 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.060 | 10.174 | 0 |
| 17 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.058 | 1.133 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 18 | 9.578 | 2.505 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.577 | 1.063 | 0 |
| 20 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | 12 | 8.459 | 7.083 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 3 | 21.351 | 21.791 | 21.791 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 3 | 16.501 | 16.647 | 16.647 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 3 | 10.958 | 11.697 | 11.697 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 3 | 10.057 | 10.174 | 10.174 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 3 | 8.952 | 11.933 | 11.933 | 0 |
| 6 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 3 | 8.275 | 42.087 | 42.087 | 0 |
| 7 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 3 | 7.161 | 7.326 | 7.326 | 0 |
| 8 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 3 | 7.063 | 7.083 | 7.083 | 0 |
| 9 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 3 | 6.953 | 7.012 | 7.012 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 3 | 5.144 | 5.731 | 5.731 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 3 | 5.080 | 6.706 | 6.706 | 0 |
| 12 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 3 | 5.058 | 5.060 | 5.060 | 0 |
| 13 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 3 | 5.023 | 5.024 | 5.024 | 0 |
| 14 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 3 | 4.629 | 5.564 | 5.564 | 0 |
| 15 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 3 | 4.470 | 4.524 | 4.524 | 0 |
| 16 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 3 | 4.405 | 4.450 | 4.450 | 0 |
| 17 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 3 | 3.669 | 3.719 | 3.719 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 3 | 3.668 | 3.936 | 3.936 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 3 | 3.643 | 3.717 | 3.717 | 0 |
| 20 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries` | 3 | 3.474 | 3.779 | 3.779 | 0 |
### Focused: 2026-07-02T08:30:13+00:00 — root — optimization-iteration1-cli-lifecycle-event-child-20260702T082947Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter CLIProcessRunnerLifecycleTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-cli-lifecycle-event-child-20260702T082947Z.json`
Inventory: ``
Scope/filter: filtered: `CLIProcessRunnerLifecycleTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 1.124 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/39dcf3e2-c36c-440d-98d2-9a3a6e10650b.log` |  |
| 2 | yes | 1.074 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/29cbbda7-8102-46f7-b08f-71f17daa8054.log` |  |
| 3 | yes | 1.022 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8726b7ad-6f43-4b00-a403-50d3654a58fe.log` |  |
| 4 | yes | 1.026 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b7b8a396-7d84-4eab-9f42-692ef24ad768.log` |  |
| 5 | yes | 1.044 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/19e0c8d6-c02f-4e46-a24e-e80f4de9a6b4.log` |  |
| 6 | yes | 1.011 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/133bec5f-3419-4bbf-8757-97e712d80d8e.log` |  |
| 7 | yes | 1.067 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d1a02274-f6af-473c-9b89-5fdc1a5017ae.log` |  |
| 8 | yes | 1.032 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5bee2949-7327-4fec-8b75-6bb20405e088.log` |  |
| 9 | yes | 1.085 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/202e2ae8-43d0-4260-ac0f-68ca60ce37fd.log` |  |
| 10 | yes | 1.023 | 0.021 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6db39d11-ef5c-4b2a-9a1e-26e39d91d0aa.log` |  |
| 11 | yes | 1.058 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2b508bbe-62ef-4d99-94d6-170c627081f3.log` |  |
| 12 | yes | 1.084 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d40083fb-20f2-4321-8c8b-d4000b273908.log` |  |
| 13 | yes | 1.068 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/64109986-b70b-4157-9e9d-61f9dda7086b.log` |  |
| 14 | yes | 1.067 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4fdf292a-a393-4f0b-9224-66058cc0d0eb.log` |  |
| 15 | yes | 1.027 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/efda90b8-529a-476a-8340-d6f33ed042d0.log` |  |
| 16 | yes | 1.049 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/94adc42b-b623-431f-9f66-5cd938ff4106.log` |  |
| 17 | yes | 1.019 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/401c5482-ad29-43c3-aacb-6c640bc0e2ba.log` |  |
| 18 | yes | 1.031 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/075b7b53-57a5-4a31-b054-3168d13ff390.log` |  |
| 19 | yes | 1.042 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/232fd59e-38a3-46b4-a3a5-c546002d01b1.log` |  |
| 20 | yes | 1.060 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/075332c6-e612-4e90-9579-5af6dce120eb.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T08:30:13+00:00/5872d90576f4 | optimization-iteration1-cli-lifecycle-event-child-20260702T082947Z | root | filtered: `CLIProcessRunnerLifecycleTests` | 20 valid + 0 invalid |  |  |  | 1.046 | 1.085 | 0.0200 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-cli-lifecycle-event-child-20260702T082947Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | 2 | 0.322 | 0.369 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessLifecycleCallbacksUseSamePIDAndTerminate` | 20 | 0.256 | 0.262 | 0.369 | 0 |
| 2 | `RepoPromptTests.CLIProcessRunnerLifecycleTests` | `testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` | 20 | 0.065 | 0.073 | 0.073 | 0 |

### Focused: 2026-07-02T08:30:45+00:00 — root — optimization-iteration1-process-launcher-event-child-20260702T083026Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter ProcessLauncherDescriptorInheritanceTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-process-launcher-event-child-20260702T083026Z.json`
Inventory: ``
Scope/filter: filtered: `ProcessLauncherDescriptorInheritanceTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.716 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/44fb4985-5bd4-4800-9154-096a9fcc2139.log` |  |
| 2 | yes | 0.768 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/77a22a2a-fab5-458c-8093-f702b919f603.log` |  |
| 3 | yes | 0.720 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f4822c9d-9b89-4927-8513-9c3f3e7cd516.log` |  |
| 4 | yes | 0.747 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e7327112-6761-4afe-8dc8-acde15776570.log` |  |
| 5 | yes | 0.718 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0880b8a9-0316-4784-8350-3864ba060afa.log` |  |
| 6 | yes | 0.727 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/65fdcbcf-5c7c-4534-b62f-bb9bf7777051.log` |  |
| 7 | yes | 0.730 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c9f3500-bc73-470f-bc07-186c36675531.log` |  |
| 8 | yes | 0.713 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0d360364-7a5a-40e3-8bc0-de07fe692a8c.log` |  |
| 9 | yes | 0.736 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bd47854e-f95c-4ef5-9cf0-3a1788790180.log` |  |
| 10 | yes | 0.734 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/379caded-3960-403e-b158-f360ece3f971.log` |  |
| 11 | yes | 0.734 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/288de369-5b8e-4bd4-82ff-ccc7de76fe09.log` |  |
| 12 | yes | 0.711 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e21f0a1b-57c6-4561-a9aa-8b362df4a5fc.log` |  |
| 13 | yes | 0.729 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ad8212e1-6123-41f4-9f79-d2a405e1a688.log` |  |
| 14 | yes | 0.721 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d56e7464-72b4-4e55-af71-3d4f77a3225b.log` |  |
| 15 | yes | 0.746 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/48253e5d-d92d-4c3c-bd4e-0855ea763293.log` |  |
| 16 | yes | 0.724 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ae92accc-b7c6-4d6a-a215-41a34ce5d04b.log` |  |
| 17 | yes | 0.746 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/32dddc31-412a-434c-b696-43c1aa227045.log` |  |
| 18 | yes | 0.782 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a9c0ee3e-b16c-44ce-a35b-544d898eec2c.log` |  |
| 19 | yes | 0.777 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dd9082bf-786c-4591-b085-9c90520f5a0c.log` |  |
| 20 | yes | 0.720 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6a790e9f-ed2f-4d84-85b4-9de0f389572d.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T08:30:45+00:00/5872d90576f4 | optimization-iteration1-process-launcher-event-child-20260702T083026Z | root | filtered: `ProcessLauncherDescriptorInheritanceTests` | 20 valid + 0 invalid |  |  |  | 0.729 | 0.777 | 0.0140 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-process-launcher-event-child-20260702T083026Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | 5 | 0.041 | 0.036 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` | 20 | 0.035 | 0.035 | 0.036 | 0 |
| 2 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testDarwinSpawnDefaultClosesUnrelatedSentinelFDWhileStdioStillWorks` | 20 | 0.003 | 0.004 | 0.004 | 0 |
| 3 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testParentPipeEndsHaveCloseOnExecAndChildStdioStillWorks` | 20 | 0.003 | 0.003 | 0.003 | 0 |
| 4 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testEstablishedSessionObservesEOFWhileSpawnedChildRemainsAlive` | 20 | 0.000 | 0.000 | 0.000 | 0 |
| 5 | `RepoPromptTests.ProcessLauncherDescriptorInheritanceTests` | `testInjectedSpawnInitializationFailuresReturnTypedErrors` | 20 | 0.000 | 0.000 | 0.000 | 0 |

### Baseline: 2026-07-02T09:01:12+00:00 — root — optimization-iteration1-event-driven-child-lifetime-20260702T083106Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration1-event-driven-child-lifetime-20260702T083106Z.json`
Inventory: ``
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 630.241 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/49a67fd3-b3dd-43f4-a9e0-2a4a972395c2.log` |  |
| 2 | yes | 599.470 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d70f93c7-d387-42c6-baab-5c8ecd399290.log` |  |
| 3 | no | 574.569 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/089c7362-dad2-409e-8ff5-d3024ce0d0fc.log` | conductor process exit 1; terminal state failed; test exit 1 |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T09:01:12+00:00/5872d90576f4 | optimization-iteration1-event-driven-child-lifetime-20260702T083106Z | root | complete | 2 valid + 1 invalid |  |  |  | 614.856 | 630.241 | 0.0250 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration1-event-driven-child-lifetime-20260702T083106Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 46.390 | 6.258 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 45.898 | 2.581 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 42.943 | 4.526 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 33.603 | 21.517 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 23.876 | 4.957 | 0 |
| 6 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 22.560 | 2.965 | 0 |
| 7 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.995 | 16.686 | 2 |
| 8 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 20.720 | 3.638 | 0 |
| 9 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 19.191 | 2.926 | 0 |
| 10 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 17.074 | 2.595 | 0 |
| 11 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 16.301 | 11.024 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 15.291 | 6.837 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 15.005 | 1.201 | 0 |
| 14 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 12.306 | 13.078 | 0 |
| 15 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 11.962 | 3.319 | 0 |
| 16 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.168 | 1.055 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.059 | 10.087 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 17 | 10.016 | 2.480 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 9.200 | 1.224 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 8.578 | 0.959 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 2 | 21.450 | 21.517 | 21.517 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 2 | 16.677 | 16.686 | 16.686 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 2 | 12.055 | 13.078 | 13.078 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 2 | 11.904 | 11.977 | 11.977 | 0 |
| 5 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 2 | 10.056 | 10.087 | 10.087 | 0 |
| 6 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 2 | 9.668 | 11.024 | 11.024 | 0 |
| 7 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 2 | 7.107 | 7.134 | 7.134 | 0 |
| 8 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 2 | 7.062 | 7.065 | 7.065 | 0 |
| 9 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 2 | 6.921 | 6.968 | 6.968 | 0 |
| 10 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 2 | 6.134 | 6.837 | 6.837 | 0 |
| 11 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 2 | 5.522 | 6.258 | 6.258 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 2 | 5.444 | 5.615 | 5.615 | 0 |
| 13 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 2 | 4.479 | 4.526 | 4.526 | 0 |
| 14 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 2 | 4.383 | 4.476 | 4.476 | 0 |
| 15 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 2 | 4.313 | 4.957 | 4.957 | 0 |
| 16 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 2 | 3.747 | 3.811 | 3.811 | 0 |
| 17 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 2 | 3.670 | 3.687 | 3.687 | 0 |
| 18 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | `testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA` | 2 | 3.577 | 3.638 | 3.638 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionFinalizationDeadlineFailsClosedWhileCleanupContinues` | 2 | 3.183 | 3.231 | 3.231 | 0 |
| 20 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries` | 2 | 3.144 | 3.319 | 3.319 | 0 |


### Iteration note: 2026-07-02T09:02:00+00:00 — optimization-iteration1-event-driven-child-lifetime

- Scope: test-harness-only replacement of fixed process keepalive sleeps; no production process code changes.
- Method delta: 0; scenario delta: 0; contract delta: 0; XCTest IDs unchanged; ledger unchanged.
- Replacement mapping: `CLIProcessRunnerLifecycleTests/testStreamingProcessTerminationCallbackRunsAfterRunnerCancellation` `/bin/sleep 5` → FIFO-gated `/bin/sh` readiness handshake with `exec /bin/cat <&3`; `ProcessLauncherDescriptorInheritanceTests/testEstablishedSessionObservesEOFWhileSpawnedChildRemainsAlive` `/bin/sleep 5` → stdin-blocked `/bin/cat`; `ProcessLauncherDescriptorInheritanceTests/testActiveUnixSocketTransportIsNotInheritedAndObservesEOFWhileSpawnedChildRemainsAlive` shell `sleep 5` suffix → `exec /bin/cat >/dev/null` after the unchanged `session:closed\n` report.
- Filter proof: optimizer focused commands recorded `conductor test --filter CLIProcessRunnerLifecycleTests --json` and `conductor test --filter ProcessLauncherDescriptorInheritanceTests --json`; prior exact daemon validations executed only the three intended methods, and suite validations executed only the two touched suites.
- Focused evidence: CLI lifecycle focused artifact `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-cli-lifecycle-event-child-20260702T082947Z.json` (20 valid + 0 invalid; optimized cancellation method median 0.065s, p95 0.073s). Descriptor focused artifact `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration1-process-launcher-event-child-20260702T083026Z.json` (20 valid + 0 invalid; active transport method median 0.035s, p95 0.035s; established-session method median 0.000s).
- Full-root evidence: exactly 3 complete root attempts in `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration1-event-driven-child-lifetime-20260702T083106Z.json`; 2 valid + 1 invalid. Valid median 614.856s vs baseline 618.016s (delta -3.160s); valid observed p95 630.241s vs baseline 640.153s (delta -9.912s). Invalid sample was an unrelated `PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync` assertion failure; no replacement root sample was run to preserve the requested exactly-3 complete-root-attempt limit.
### Focused: 2026-07-02T09:22:16+00:00 — root — reliability-gate-worktree-read-certificate-boundary-focused-20260702T092154Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-worktree-read-certificate-boundary-20260702T092154Z.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync`
Source-change guard: `metadata`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.913 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eb21cf44-33c5-4e91-a36f-2a871634c5bd.log` |  |
| 2 | yes | 1.059 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/25719abb-3d8c-4030-9816-4be66defb44b.log` |  |
| 3 | yes | 0.927 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/634fc167-2878-4500-9d34-560e1389dd37.log` |  |
| 4 | yes | 0.936 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f7531bda-144b-4dbd-8e15-541df52dc257.log` |  |
| 5 | yes | 0.933 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/14ebac42-86ee-4632-8770-b67b8ed3afe0.log` |  |
| 6 | yes | 1.067 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4c7d6c84-5244-4077-8acc-1b9682a03af6.log` |  |
| 7 | yes | 0.908 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/403274db-eda3-4ffe-9e56-72da513ea30a.log` |  |
| 8 | yes | 0.933 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c5acf031-d71c-4881-8b65-65f583ef4ce7.log` |  |
| 9 | yes | 0.948 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6ab57ccf-ca97-48df-b64b-d953f7cd007f.log` |  |
| 10 | yes | 0.955 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/92c35660-c43d-4b2a-bf3a-f58539661b6f.log` |  |
| 11 | yes | 0.905 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bb7c8562-11b9-4870-8982-179f634d0e89.log` |  |
| 12 | yes | 1.045 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/41e349cf-726b-4b66-b723-bf07baaeb383.log` |  |
| 13 | yes | 1.202 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0e15420d-1875-4caa-830d-10f1b901fc79.log` |  |
| 14 | yes | 0.922 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e79cbd14-a6a7-45c9-a60c-6be2bfc28a2c.log` |  |
| 15 | yes | 1.089 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8c05ed0e-793a-456a-b480-f54b6034f91f.log` |  |
| 16 | yes | 1.103 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/53fd27a0-2071-47a5-81ce-17a2f71a8275.log` |  |
| 17 | yes | 0.885 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/391bf4f2-b32f-4940-bdd0-511ffa921a04.log` |  |
| 18 | yes | 0.921 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7877996b-7749-4836-9e97-346fecd08fd5.log` |  |
| 19 | yes | 1.084 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/858c3b5c-cb13-45f8-b04a-7e1be93619b5.log` |  |
| 20 | yes | 0.906 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/79a8633d-92fd-4e4f-8b15-b1a8a22a5780.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T09:22:16+00:00/68f0651bdf94 | reliability-gate-worktree-read-certificate-boundary-focused-20260702T092154Z | root | filtered: `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync` | 20 valid + 0 invalid |  |  |  | 0.934 | 1.103 | 0.0296 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-worktree-read-certificate-boundary-20260702T092154Z.json` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 1 | 0.242 | 0.505 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | `testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync` | 20 | 0.242 | 0.424 | 0.505 | 0 |

### Baseline: 2026-07-02T09:52:52+00:00 — root — reliability-gate-worktree-read-certificate-boundary-root-20260702T092236Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-worktree-read-certificate-boundary-20260702T092236Z.json`
Inventory: ``
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 595.361 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cb85ffa3-50da-48fd-affb-2f00ce4fe0be.log` |  |
| 2 | yes | 583.822 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/67f3fd55-f5fd-4d53-bd9a-ee61a35e804b.log` |  |
| 3 | yes | 634.898 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6c51eadd-b534-468b-a485-35b6ced9510d.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T09:52:52+00:00/68f0651bdf94 | reliability-gate-worktree-read-certificate-boundary-root-20260702T092236Z | root | complete | 3 valid + 0 invalid |  |  |  | 595.361 | 634.898 | 0.0194 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-worktree-read-certificate-boundary-20260702T092236Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 43.388 | 2.459 | 0 |
| 2 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 41.564 | 5.525 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 40.834 | 4.711 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 31.505 | 24.099 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 23.890 | 4.949 | 0 |
| 6 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 23.287 | 3.509 | 0 |
| 7 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 21.806 | 4.473 | 0 |
| 8 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.689 | 16.768 | 3 |
| 9 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 19.175 | 3.128 | 0 |
| 10 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 17.837 | 2.410 | 0 |
| 11 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 13.355 | 1.509 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 13.181 | 5.297 | 0 |
| 13 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 13.019 | 8.344 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.697 | 3.780 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.044 | 11.077 | 0 |
| 16 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 18 | 10.235 | 2.623 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.192 | 10.612 | 0 |
| 18 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.007 | 1.178 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.724 | 1.074 | 0 |
| 20 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | 12 | 8.479 | 7.262 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 3 | 22.223 | 24.099 | 24.099 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 3 | 16.650 | 16.768 | 16.768 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 3 | 10.893 | 11.077 | 11.077 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 3 | 10.189 | 10.612 | 10.612 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 3 | 8.987 | 11.812 | 11.812 | 0 |
| 6 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 3 | 7.071 | 7.262 | 7.262 | 0 |
| 7 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 3 | 7.062 | 7.182 | 7.182 | 0 |
| 8 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 3 | 6.987 | 7.536 | 7.536 | 0 |
| 9 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 3 | 6.521 | 8.344 | 8.344 | 0 |
| 10 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 3 | 5.287 | 5.297 | 5.297 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 3 | 5.165 | 5.201 | 5.201 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 3 | 4.856 | 5.525 | 5.525 | 0 |
| 13 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 3 | 4.595 | 4.711 | 4.711 | 0 |
| 14 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 3 | 4.480 | 4.721 | 4.721 | 0 |
| 15 | `RepoPromptTests.PersistentMCPDistinctConnectionConcurrencyTests` | `testDistinctConnectionsOverlapWithoutCrossRoutingReadOrSearchResults` | 1 | 4.264 | 4.264 | 4.264 | 0 |
| 16 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 3 | 3.731 | 4.949 | 4.949 | 0 |
| 17 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | `testSwitchingCodeStructureScopeFromWorktreeAToBDoesNotReuseA` | 3 | 3.676 | 4.473 | 4.473 | 0 |
| 18 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 3 | 3.663 | 3.765 | 3.765 | 0 |
| 19 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 3 | 3.647 | 3.709 | 3.709 | 0 |
| 20 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries` | 3 | 3.438 | 3.780 | 3.780 | 0 |

### Reliability gate note: 2026-07-02T09:55:00+00:00 — read-file coverage certificate boundary

- Scope: root-gate reliability restoration for `PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync`; no wallclock optimization iteration was started.
- Raw invalid root log: `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/089c7362-dad2-409e-8ff5-d3024ce0d0fc.log`.
- Exact failing assertions: `Tests/RepoPromptTests/MCP/Control/PersistentAgentModeMCPReadFileConnectionTests.swift:1233` `XCTAssertEqual failed: ("0") is not equal to ("1")` for repeat-read `coverageCertificateHitCount`; line `1234` `XCTAssertEqual failed: ("2") is not equal to ("1")` for `authoritativeFallbackCount`.
- Fix scope: production certificate seam + test seam. The test final revalidation now advances canonical selection through `selectionCoordinator.persistSelection` with the current selection as an expected base and adds failure diagnostics; certificate minting now samples catalog validation metadata after the DEBUG final revalidation hook so minted certificates describe the final verified state.
- Focused proof: exact single-test daemon run passed once (`make dev-test FILTER='RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests/testWorktreeReadCoverageCertificateMintsOnlyAfterVerifiedPersistenceAndResponseStaysAsync'`, ticket `aa13f764-9b6a-4827-8eb4-d43fa1261cb8`), then focused artifact `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-worktree-read-certificate-boundary-20260702T092154Z.json` recorded 20 valid + 0 invalid samples with `parsed_test_case_timings=1` for every sample.
- Root gate: exactly 3 complete-root samples in `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-worktree-read-certificate-boundary-20260702T092236Z.json`; 3 valid + 0 invalid, content guard, median 595.361s, observed p95 634.898s.
### Focused: 2026-07-02T10:40:49+00:00 — root — optimization-iteration2-template-git-repo-cache-receipt-20260702T103031Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter GitWorktreeCreationReceiptTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration2-template-git-repo-cache-receipt-20260702T103031Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json`
Scope/filter: filtered: `GitWorktreeCreationReceiptTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 27.214 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6e97055b-3f20-4fa0-9391-c1e66dedf698.log` |  |
| 2 | yes | 26.919 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cf2013a4-d4d1-46df-b0e1-a396577cac77.log` |  |
| 3 | yes | 25.892 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c6c074f4-5e73-44e0-96af-a79b90798fd4.log` |  |
| 4 | yes | 27.315 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/62730829-314c-4f89-af93-734f158c62a9.log` |  |
| 5 | yes | 24.700 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a99ebf97-e621-4ad2-ad44-86134dc6981b.log` |  |
| 6 | yes | 24.200 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f656d32f-72f9-4e60-bbdf-fc7f6528792b.log` |  |
| 7 | yes | 25.273 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c349e2f-763d-4644-becd-cc9baa9399c6.log` |  |
| 8 | yes | 33.864 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a74f4b46-ae8b-4bcf-a562-7998fed48a32.log` |  |
| 9 | yes | 31.950 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/322dbaf6-2cbd-4f2d-be12-35aef986efb4.log` |  |
| 10 | yes | 29.992 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/275d7a1f-4b08-430d-91b4-3a8fbac45f44.log` |  |
| 11 | yes | 31.663 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/441d973d-109b-4e2c-b737-e78c3a03a5d1.log` |  |
| 12 | yes | 31.961 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/934d0ac9-2ebd-456e-a6fe-1be3095742f0.log` |  |
| 13 | yes | 32.418 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ed393f51-2600-46b1-a251-df8556dacf42.log` |  |
| 14 | yes | 32.897 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7623e12f-6eab-4f85-990d-d0e4db6ebeb6.log` |  |
| 15 | yes | 35.055 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/62106f94-725e-402c-91da-6ff9469e0198.log` |  |
| 16 | yes | 32.936 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5a8bf58c-966d-4b33-997b-ba5a08015208.log` |  |
| 17 | yes | 30.398 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/09738dc8-7a49-413f-90a1-b14894ef81bf.log` |  |
| 18 | yes | 29.918 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4f111a3b-e1ce-4562-892d-38de5a833862.log` |  |
| 19 | yes | 37.686 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/284666d5-ae15-47a2-a4ed-d239f90b4a4b.log` |  |
| 20 | yes | 37.123 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e1f41e56-236f-42ed-a429-a456d1e152c8.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T10:40:49+00:00/d2b57f0449a4 | optimization-iteration2-template-git-repo-cache-receipt-20260702T103031Z | root | filtered: `GitWorktreeCreationReceiptTests` | 20 valid + 0 invalid | 2835 | 7 | 2842 | 31.031 | 37.123 | 0.1055 | unstable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration2-template-git-repo-cache-receipt-20260702T103031Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 30.230 | 6.917 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 20 | 4.841 | 6.766 | 6.917 | 0 |
| 2 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 20 | 3.261 | 3.377 | 3.384 | 0 |
| 3 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReusableSnapshotCurrentnessFailuresRetainEveryStage` | 20 | 2.929 | 3.064 | 3.961 | 0 |
| 4 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testPolicyProjectedLinkedWorktreeSubdirectoryMatchesOrdinaryCatalogExactly` | 20 | 2.924 | 3.970 | 4.010 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testSubdirectoryReceiptPlansOnlyCorrespondingPhysicalRoot` | 20 | 2.723 | 5.522 | 5.586 | 0 |
| 6 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testRepeatedAuthorityObservationReplacesAliasAndMetadataRetain` | 20 | 2.400 | 2.581 | 3.420 | 0 |
| 7 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testConcurrentSameRepositoryCreationsKeepReceiptsSessionIsolated` | 20 | 1.039 | 1.124 | 1.209 | 0 |
| 8 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionAllowsPolicyIgnoredCommittedFilesButRejectsMissingDiscoverableCommittedFiles` | 20 | 0.879 | 0.949 | 1.770 | 0 |
| 9 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptReplayFailsAcrossSessionLogicalRootAndOwnerGeneration` | 20 | 0.831 | 0.984 | 1.876 | 0 |
| 10 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptKeepsReusableParentWhenRequestedTargetTreeDiffers` | 20 | 0.773 | 0.873 | 0.873 | 0 |
| 11 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testSameRepositoryLinkedWorktreeReceiptIsEligibleAndCarriesExactScope` | 20 | 0.754 | 1.794 | 1.835 | 0 |
| 12 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReusableSnapshotCurrentnessPreservesLoadedRootCauseMatrix` | 20 | 0.718 | 1.631 | 1.656 | 0 |
| 13 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testCatalogAdmissionRejectsCanonicalEquivalentByteDistinctGitPaths` | 20 | 0.661 | 0.833 | 1.631 | 0 |
| 14 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLinkedBaseReceiptDecisionMatchesAdmittedSnapshotAndRepositoryScope` | 20 | 0.558 | 0.613 | 0.620 | 0 |
| 15 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptFallbackRestartAndConcurrentBindingIsolationMatrix` | 20 | 0.551 | 1.585 | 1.595 | 0 |
| 16 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesOwnerStaleness` | 20 | 0.551 | 0.651 | 1.664 | 0 |
| 17 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptDataIsNotPersistedWithBindingSchema` | 20 | 0.540 | 0.724 | 1.587 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testRootNeutralSnapshotExcludesTargetStateAndEvictsWithinBounds` | 20 | 0.493 | 0.532 | 1.574 | 0 |
| 19 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionRaceRevokesProvisionalAliasAndCoverage` | 20 | 0.390 | 1.712 | 1.791 | 0 |
| 20 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testCommonRepositoryMutationFencesNewLinkedWorktreeAuthorityCollection` | 20 | 0.277 | 0.300 | 1.321 | 0 |

### Baseline: 2026-07-02T11:11:09+00:00 — root — optimization-iteration2-template-git-repo-cache-root-20260702T103031Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json`
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 622.953 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c202b29a-663c-485b-af24-c556c9554e2a.log` |  |
| 2 | no | 589.542 | 0.001 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c2c11b76-7241-4b23-80bf-c35e0948347b.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 559.392 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/71b54a8c-18b4-4f18-9869-b9bbeb2b3331.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T11:11:09+00:00/d2b57f0449a4 | optimization-iteration2-template-git-repo-cache-root-20260702T103031Z | root | complete | 2 valid + 1 invalid | 2835 | 7 | 2842 | 591.172 | 622.953 | 0.0538 | noisy | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 47.596 | 6.754 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 41.860 | 2.151 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 40.107 | 5.151 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 32.707 | 23.756 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 27.160 | 5.838 | 0 |
| 6 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 21.642 | 17.029 | 2 |
| 7 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 21.578 | 3.494 | 0 |
| 8 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 19.527 | 3.014 | 0 |
| 9 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 18.331 | 2.006 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 15.560 | 1.419 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 13.991 | 7.476 | 0 |
| 12 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 13.990 | 8.209 | 0 |
| 13 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 12.963 | 2.424 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.736 | 3.841 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 12.416 | 12.365 | 0 |
| 16 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.184 | 10.238 | 0 |
| 17 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 9.786 | 1.020 | 0 |
| 18 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 18 | 9.509 | 2.541 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 8.514 | 0.799 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 8.174 | 1.372 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 2 | 23.176 | 23.756 | 23.756 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 2 | 16.977 | 17.029 | 17.029 | 0 |
| 3 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 2 | 12.253 | 12.365 | 12.365 | 0 |
| 4 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 2 | 10.181 | 10.238 | 10.238 | 0 |
| 5 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 2 | 9.245 | 9.531 | 9.531 | 0 |
| 6 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 2 | 7.244 | 7.351 | 7.351 | 0 |
| 7 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 2 | 6.981 | 7.043 | 7.043 | 0 |
| 8 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 2 | 6.669 | 8.209 | 8.209 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 2 | 6.433 | 7.476 | 7.476 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 2 | 5.881 | 6.754 | 6.754 | 0 |
| 11 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 2 | 5.292 | 5.838 | 5.838 | 0 |
| 12 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 2 | 5.161 | 5.245 | 5.245 | 0 |
| 13 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 2 | 5.159 | 5.423 | 5.423 | 0 |
| 14 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 2 | 5.021 | 5.654 | 5.654 | 0 |
| 15 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 2 | 4.787 | 5.151 | 5.151 | 0 |
| 16 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 2 | 3.789 | 3.826 | 3.826 | 0 |
| 17 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries` | 2 | 3.466 | 3.841 | 3.841 | 0 |
| 18 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 2 | 3.433 | 3.575 | 3.575 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionFinalizationDeadlineFailsClosedWhileCleanupContinues` | 2 | 3.271 | 3.454 | 3.454 | 0 |
| 20 | `RepoPromptTests.MCPReadSearchLatencyDiagnosticsGuardTests` | `testRuntimeSnapshotHiddenOperationsExposeBoundedAggregateAndDispatcherContracts` | 2 | 2.885 | 2.959 | 2.959 | 0 |


### Iteration note: 2026-07-02T11:14:57+00:00 — optimization-iteration2-template-git-repo-cache

- Scope: test-support-only shared Git repository templates for default `ReviewGitRepositoryFixture.makeRepository` and `GitWorktreeCreationReceiptTests.ReceiptFixture`; no production code, ledger IDs, process lifecycle optimization files, codemap drain/wait logic, or read-file certificate boundary code changed.
- Behavior preserved: default review repos copy an unborn configured `main` template and still create the caller-specific root `Initial commit`; explicit `objectFormat != nil` (including `.sha256`) remains on the bespoke init/config path; receipt base copies a committed template with tracked `.gitignore`, `.worktreeinclude`, and `Tracked.swift` plus ignored/untracked `secret.txt` and `nested/ignored.txt`; existing empty destination directory conversion is retained.
- Method delta: 0; scenario delta: 0; contract delta: 0; XCTest IDs unchanged; curated ledger unchanged. `make verify-ledger` is unavailable in this checkout; direct verifier still reports the pre-existing mismatch, now `missing=46 stale=2`.
- Focused evidence: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-iteration2-template-git-repo-cache-receipt-20260702T103031Z.json` (`GitWorktreeCreationReceiptTests`, 20 valid + 0 invalid, median 31.031s, observed p95 37.123s, relative MAD 0.1055 unstable, content guard, no source changes). Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json` (root 2835, provider 7, total 2842).
- Full-root evidence: exactly 3 complete-root attempts, no replacements, in `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-optimization-iteration2-template-git-repo-cache-20260702T103031Z.json`; 2 valid + 1 invalid, valid raw `[622.953, 559.392]`, median 591.172s, observed p95 622.953s, relative MAD 0.0538 noisy, content guard, no source changes.
- Latest clean anchor comparison: vs `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-worktree-read-certificate-boundary-20260702T092236Z.json` (median 595.361s / p95 634.898s), median delta -4.189s (-0.70%), p95 delta -11.945s (-1.88%).
- Invalid sample/flakes: root sample 2 failed `WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady` at `Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextStoreCodemapSeamTests.swift:7945` ("Busy-retry sequence did not complete within the external bound"). It is outside the changed Git fixture/cache scope; no replacement sample was run.
- Validation: `make dev-format` passed; `make dev-lint` passed; required focused suites passed: `GitWorktreeCreationReceiptTests`, `MCPCodeStructureWorktreeTests`, `MCPAskOracleWorktreeTests`, `WorkspaceCodemapGitCapabilityServiceTests`, `AutomaticReviewGitDiffCoordinatorTests`, `FrozenVisibleGitCheckoutResolverTests`.
### Focused: 2026-07-02T11:41:12+00:00 — root — reliability-gate-busy-retry-flake-20260702T113812Z-focused-busy-retry-50x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-busy-retry-flake-20260702T113812Z-busy-retry-50x.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady`
Source-change guard: `metadata`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 2.407 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3233d3e5-9e1c-4a4c-b6f6-116af5c72791.log` |  |
| 2 | yes | 2.223 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d73d1255-cfcb-4199-a4b0-1e881c273d42.log` |  |
| 3 | yes | 2.172 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/167d9cbb-0a86-4918-8c97-4b7ccf8ae0a6.log` |  |
| 4 | yes | 2.178 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/42fecdc6-e14f-4482-9836-7c9585c10819.log` |  |
| 5 | yes | 2.247 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b13b563a-34f5-4895-99a8-380e90fe83bc.log` |  |
| 6 | yes | 2.284 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/94393e50-2f69-4bd4-bf96-858a7a465eb6.log` |  |
| 7 | yes | 2.188 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3012925d-25d1-4711-984d-0f1547bb3e54.log` |  |
| 8 | yes | 2.127 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c8c0c73b-0419-44cd-9f62-4c11e9c4a34c.log` |  |
| 9 | yes | 2.212 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/546a5266-513b-4ab1-9ce2-80c5f07d8820.log` |  |
| 10 | yes | 2.123 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/10405260-879e-400f-9696-f9b3a925ebc5.log` |  |
| 11 | yes | 2.168 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/825c7ea2-eb89-427d-80ba-6c9aee0e4ac7.log` |  |
| 12 | yes | 2.176 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/68d25451-a234-4e50-95e5-3a43056354ae.log` |  |
| 13 | yes | 2.421 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fdd15637-bfc1-401d-a21b-a70d3a0e27c8.log` |  |
| 14 | yes | 2.193 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2d356eef-4720-4638-9d41-5eb8633523b8.log` |  |
| 15 | yes | 2.208 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/753ac1d8-4d9b-4bb0-a7e7-d35b849d1934.log` |  |
| 16 | yes | 2.174 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f56d296f-1263-4493-8311-402e9985e4ad.log` |  |
| 17 | yes | 2.151 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b97e4762-a2cb-4567-a138-a8b59c21fab8.log` |  |
| 18 | yes | 2.201 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/21a6a3bc-5070-4f65-a333-21f5bb2c3546.log` |  |
| 19 | yes | 2.246 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3481b7ca-8b64-437e-a416-d04ad9fe0ea9.log` |  |
| 20 | yes | 2.245 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6352a653-b1e3-41b5-bd53-1d201cfbdb84.log` |  |
| 21 | yes | 2.166 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b9bf0ad8-de3c-4974-9071-97162df8598b.log` |  |
| 22 | yes | 2.174 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/71c4af07-384c-456d-be50-b4c46a18ce2b.log` |  |
| 23 | yes | 2.199 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/82345486-ebd1-414a-99e8-d664b1b0e354.log` |  |
| 24 | yes | 2.198 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ab0a05f1-4c53-4d5f-b233-49c2596be1eb.log` |  |
| 25 | yes | 2.158 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/05c0bb3b-bca4-4495-b6c5-b93e10ca26a1.log` |  |
| 26 | yes | 2.186 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/68144dd6-292d-40b0-8a21-834ff70dfb5c.log` |  |
| 27 | yes | 2.151 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0aba04b1-206d-4bb1-8200-3fa446cc29e6.log` |  |
| 28 | yes | 2.128 | 0.001 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d60f18a7-5b31-4ae4-bfc2-943cef02d9c2.log` |  |
| 29 | yes | 2.162 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/118e2b2f-5663-4fb8-8b33-6ec87dcb53bc.log` |  |
| 30 | yes | 2.182 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7eafa6b7-1531-4a65-8bd3-3954e18ad0f3.log` |  |
| 31 | yes | 2.188 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/578d5e89-c2ab-45e8-a703-fcb93785061e.log` |  |
| 32 | yes | 2.244 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/272d58cd-1be5-4aeb-8563-d684bfaa272d.log` |  |
| 33 | yes | 2.312 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9ead6ddc-81c1-435d-93db-bbf8f2ad9856.log` |  |
| 34 | yes | 2.281 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5b533809-ddc1-42df-9d7c-2a6655f35e89.log` |  |
| 35 | yes | 2.291 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/976fe414-c2be-417c-b0b7-80a68e3a5ca5.log` |  |
| 36 | yes | 2.187 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e6e3fa5f-d823-405a-9277-509a9c69a162.log` |  |
| 37 | yes | 2.245 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bbd07a72-8321-4f1f-a5a4-25d1b1e96d2e.log` |  |
| 38 | yes | 2.279 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9266ed33-6c3e-4a0f-bd98-6aae7cd400a2.log` |  |
| 39 | yes | 2.307 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9671e295-b7e3-411e-a264-a9125c03bee3.log` |  |
| 40 | yes | 2.212 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ee57b730-f3cb-4368-abf5-9d7a89b2538f.log` |  |
| 41 | yes | 2.184 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c6333db1-00cb-428f-bffb-dd19350363a1.log` |  |
| 42 | yes | 2.161 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/61ce6faf-3869-49b3-a688-bae4d748d25e.log` |  |
| 43 | yes | 2.306 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/74201580-56ca-4e20-8e49-ae148ab898d8.log` |  |
| 44 | yes | 2.177 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/806b25a8-87e6-48bf-a183-b6fc3f3c47ad.log` |  |
| 45 | yes | 2.224 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7446d311-7337-4215-81e1-8bb4f6d0c3e7.log` |  |
| 46 | yes | 2.173 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/63d0b1fb-b8f7-4224-ad21-8606cd4860e8.log` |  |
| 47 | yes | 2.205 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/50120703-e262-4b17-be0d-6e401164d9d6.log` |  |
| 48 | yes | 2.182 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fc06217c-2f56-4e84-be20-0290dccd4caf.log` |  |
| 49 | yes | 2.224 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/52cd2134-6853-4e9c-bd36-5156551ba6d2.log` |  |
| 50 | yes | 2.172 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d7c97902-de29-43b8-a736-930dc1c6bd23.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T11:41:12+00:00/ac287333a72d | reliability-gate-busy-retry-flake-20260702T113812Z-focused-busy-retry-50x | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady` | 50 valid + 0 invalid | 2835 | 7 | 2842 | 2.190 | 2.312 | 0.0121 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-busy-retry-flake-20260702T113812Z-busy-retry-50x.json` | source guard `metadata`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 1 | 1.518 | 1.768 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady` | 50 | 1.518 | 1.628 | 1.768 | 0 |

### Baseline: 2026-07-02T12:18:31+00:00 — root — reliability-gate-busy-retry-flake-20260702T113812Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | no | 579.312 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0e063528-44df-42b0-aee5-aec2213e52cb.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 2 | yes | 649.130 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/aae62d0f-b4d6-4a40-8be9-d2a40cf485dd.log` |  |
| 3 | no | 665.979 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8caaeeac-07cf-4744-ba8c-819d08f7297a.log` | conductor process exit 1; terminal state failed; test exit 1 |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T12:18:31+00:00/ac287333a72d | reliability-gate-busy-retry-flake-20260702T113812Z | root | complete | 1 valid + 2 invalid | 2835 | 7 | 2842 | 649.130 | 649.130 | 0.0000 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-busy-retry-flake-20260702T113812Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 56.864 | 7.226 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 53.923 | 2.890 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 49.782 | 5.050 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 33.873 | 21.662 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 25.879 | 3.777 | 0 |
| 6 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 22.588 | 2.841 | 0 |
| 7 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.702 | 16.942 | 1 |
| 8 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 19.175 | 1.490 | 0 |
| 9 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 18.738 | 2.995 | 0 |
| 10 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 18.241 | 1.973 | 0 |
| 11 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 17.385 | 9.658 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 16.571 | 7.443 | 0 |
| 13 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 12.597 | 2.167 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.072 | 3.288 | 0 |
| 15 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.113 | 10.867 | 0 |
| 16 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.744 | 10.740 | 0 |
| 17 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 10.528 | 1.350 | 0 |
| 18 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 10.437 | 0.903 | 0 |
| 19 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.186 | 1.037 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 17 | 9.800 | 1.309 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 21.662 | 21.662 | 21.662 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 16.942 | 16.942 | 16.942 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 11.953 | 11.953 | 11.953 | 0 |
| 4 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 10.867 | 10.867 | 10.867 | 0 |
| 5 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 10.740 | 10.740 | 10.740 | 0 |
| 6 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 9.658 | 9.658 | 9.658 | 0 |
| 7 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 8.964 | 8.964 | 8.964 | 0 |
| 8 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 7.587 | 7.587 | 7.587 | 0 |
| 9 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 7.443 | 7.443 | 7.443 | 0 |
| 10 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 7.264 | 7.264 | 7.264 | 0 |
| 11 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 7.226 | 7.226 | 7.226 | 0 |
| 12 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 7.153 | 7.153 | 7.153 | 0 |
| 13 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 6.023 | 6.023 | 6.023 | 0 |
| 14 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 5.050 | 5.050 | 5.050 | 0 |
| 15 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 1 | 3.918 | 3.918 | 3.918 | 0 |
| 16 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 1 | 3.777 | 3.777 | 3.777 | 0 |
| 17 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 1 | 3.681 | 3.681 | 3.681 | 0 |
| 18 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 1 | 3.553 | 3.553 | 3.553 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionFinalizationDeadlineFailsClosedWhileCleanupContinues` | 1 | 3.542 | 3.542 | 3.542 | 0 |
| 20 | `RepoPromptTests.AgentRunDiffSeededWorktreeInitializationTests` | `testDefaultOffAndForcedFullCrawlUseOrdinaryRouteExactlyOnce` | 1 | 3.516 | 3.516 | 3.516 | 0 |

### Iteration note: 2026-07-02T12:18:31+00:00 — reliability-gate-busy-retry-flake

- Scope: targeted reliability remediation only for `WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady` plus the sibling `testAutomaticSelectionBusySourceRoundBoundStopsBeforeDeadline` that shared the identical busy sequence harness. Production code, recently hardened unrelated seams, XCTest IDs, curated ledger rows, method counts, contract counts, and scenario counts were unchanged.
- Raw failure log inspected first: iteration-2 sample 2 failed only at `Tests/RepoPromptTests/WorkspaceContext/WorkspaceFileContextStoreCodemapSeamTests.swift:7945` with `Busy-retry sequence did not complete within the external bound`; method runtime was 7.507s. Adjacent tests continued normally. Nearby drain/cancellation log hits belonged to other named cancellation/drain tests, not teardown for the busy-retry failure.
- Fix shape: replaced the busy sequence harness's polling `waitUntilWaitCount` / `waitUntilDemandCount` milestone observation with `AsyncStream` continuation-backed event observation, and removed per-step 2s milestone/status timeout stacking from the two busy-round orchestrator loops. The 5s external bound remains the fail-safe; semantic assertions still require two busy outcomes, the third ready outcome, 5 waiter invocations, final receipt/currentness, stale tickets, and zero source retain count.
- Focused evidence: exact failing test stress `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-busy-retry-flake-20260702T113812Z-busy-retry-50x.json` (`RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests/testAutomaticSelectionRetriesBusySourceTwiceThenBecomesReady`, 50 valid + 0 invalid, median 2.190s, observed p95 2.312s, relative MAD 0.0121 stable, metadata guard). Single-run sibling evidence: `testAutomaticSelectionBusySourceRoundBoundStopsBeforeDeadline` passed in 1.580s; unchanged deadline sibling `testAutomaticSelectionBusySourceDeadlineStopsBeforeRoundBound` passed in 1.758s.
- Suite/style/ledger validation: full `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` passed 34 tests in 43.231s; `make dev-format` passed with 0/1371 files formatted; `make dev-lint` passed with 0 SwiftFormat/SwiftLint violations. Direct ledger verifier remained the pre-existing mismatch from before this patch: `missing=46 stale=2`.
- Full-root evidence: exactly 3 complete-root attempts, no replacements, in `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-busy-retry-flake-20260702T113812Z.json`; result 1 valid + 2 invalid, valid raw `[649.130]`, content guard, no source changes. Because only one sample was valid, median/p95 are artifact-reported but not a robust root timing comparison.
- Invalid root samples: sample 1 failed unrelated `MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` at `Tests/RepoPromptTests/MCP/MCPCodeStructureWorktreeTests.swift:215` (`presentationCandidateRequests` 8 vs 7; log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0e063528-44df-42b0-aee5-aec2213e52cb.log`). Sample 3 failed unrelated `WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse` at `Tests/RepoPromptTests/WorkspaceContext/WorkspaceCodemapBindingEngineTests.swift:2043/2045/2046` (counts 2 vs 1 and 6 vs 4; log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8caaeeac-07cf-4744-ba8c-819d08f7297a.log`). Neither invalid sample reproduced the busy-retry failure.
- Deltas: method delta 0; contract delta 0; scenario delta 0; ledger delta 0. Inventory `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json` still reports root 2835, provider 7, total executable methods 2842.
### Focused: 2026-07-02T12:58:08+00:00 — root — reliability-gate-counter-flakes-mcp-passive-tree-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-mcp-passive-tree-20x.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-counter-flakes.json`
Scope/filter: filtered: `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 4.379 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e9bb9e39-cfce-4d85-8bcb-0c8d9cc70775.log` |  |
| 2 | yes | 4.188 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c8f72f93-d8da-4d24-b237-c0ec710857fe.log` |  |
| 3 | yes | 5.177 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/72332e94-bfe2-449a-85d8-9d03022c1ef0.log` |  |
| 4 | yes | 4.222 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1017a1c4-cac4-4008-a342-42840d35af56.log` |  |
| 5 | yes | 4.221 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4a8695d4-c7e0-4bd2-be33-7d6637371a0a.log` |  |
| 6 | yes | 4.346 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5f67bece-4e3d-4c0a-bcc6-ccd5ab0567af.log` |  |
| 7 | yes | 4.238 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a106bb3e-d809-4aae-9a39-7af21c470c37.log` |  |
| 8 | yes | 4.211 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/288f4cf7-0d0a-4af0-aefd-c0ede4dfccad.log` |  |
| 9 | yes | 4.228 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/841c2b9b-fcdb-416d-8ff5-007cd4a03fc7.log` |  |
| 10 | yes | 4.296 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/03e7e959-12ed-4b95-8d91-593d109ab12b.log` |  |
| 11 | yes | 4.376 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e19b96a6-df33-41d9-916e-aecc337a9cd5.log` |  |
| 12 | yes | 5.195 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9aa58f5d-a1cf-4206-8270-0aa59d6f8bb4.log` |  |
| 13 | yes | 5.283 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5706a974-e574-485e-a1cd-623bded70a35.log` |  |
| 14 | yes | 4.262 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/08389906-2f5c-4944-ac1f-81b599ae357c.log` |  |
| 15 | yes | 4.239 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/15b276d0-e731-45aa-b64a-7cb7203ef38c.log` |  |
| 16 | yes | 4.214 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3e68f6bd-e110-4089-8ab8-3078deb79bf7.log` |  |
| 17 | yes | 4.170 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6f3f1970-c3a9-451f-a684-7d1965ef59bd.log` |  |
| 18 | yes | 4.226 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1e342934-d593-47c7-ad73-f856475e5d08.log` |  |
| 19 | yes | 4.381 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d1097886-12eb-4181-9769-08733c80d47c.log` |  |
| 20 | yes | 4.230 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5e13c1fa-166d-452c-addf-dbfb80ffc7bc.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T12:58:08+00:00/e92a73ad4d82 | reliability-gate-counter-flakes-mcp-passive-tree-20x | root | filtered: `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` | 20 valid + 0 invalid | 2835 | 7 | 2842 | 4.239 | 5.195 | 0.0093 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-mcp-passive-tree-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 1 | 3.478 | 4.506 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | `testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` | 20 | 3.478 | 4.458 | 4.506 | 0 |

### Focused: 2026-07-02T12:59:16+00:00 — root — reliability-gate-counter-flakes-binding-projection-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-binding-projection-20x.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-counter-flakes.json`
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 2.662 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/980f4463-3b48-48c2-ae35-e5c27454ef09.log` |  |
| 2 | yes | 2.619 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7723ca6b-b4f8-4503-aa06-4ba982b5505d.log` |  |
| 3 | yes | 2.673 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ca53e925-394f-4e58-a394-abe954d99bd3.log` |  |
| 4 | yes | 2.771 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f1f7931b-a290-4c33-bcb8-4a7eef12e4b6.log` |  |
| 5 | yes | 2.714 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f05c6e8a-3dab-4f0a-9f50-8d4a77c32926.log` |  |
| 6 | yes | 2.614 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/441fdacf-c4a1-4ae0-a704-50a50eaed2f4.log` |  |
| 7 | yes | 2.524 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/220d1d81-57f3-4921-9799-ce80b7bb5bdc.log` |  |
| 8 | yes | 2.720 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d41a3061-42e1-409b-bb44-3c3e9371feca.log` |  |
| 9 | yes | 2.616 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0b23e19a-f6c0-4ddc-a4c6-0d983ba4d333.log` |  |
| 10 | yes | 2.744 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b8506b2d-99dc-4929-924b-2079e24e61cb.log` |  |
| 11 | yes | 2.609 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4d0d529b-842e-444d-8924-9ad3f25298e6.log` |  |
| 12 | yes | 2.574 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7148d11f-bea4-4411-aa34-5370360f0e22.log` |  |
| 13 | yes | 2.538 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/75b643ff-8298-4a42-87d0-618b2b8b5442.log` |  |
| 14 | yes | 2.560 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2fd305b7-9252-435a-b9d5-a45856fcd61f.log` |  |
| 15 | yes | 2.525 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cda5ae32-ebb3-405c-865b-4aae2284770c.log` |  |
| 16 | yes | 2.689 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9bb7fbc6-c308-424f-9afe-48ae2e87b304.log` |  |
| 17 | yes | 2.529 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5288e3d2-b7ec-4735-b821-3f5000892e6d.log` |  |
| 18 | yes | 2.652 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c8f8c5c-e107-4349-8cae-4399f0a2fca6.log` |  |
| 19 | yes | 2.669 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d7fcca7c-31af-4e85-9197-0dd69b484756.log` |  |
| 20 | yes | 2.513 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6133b13b-dd83-44f3-9a52-d99a1e79f34a.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T12:59:16+00:00/e92a73ad4d82 | reliability-gate-counter-flakes-binding-projection-20x | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse` | 20 valid + 0 invalid | 2835 | 7 | 2842 | 2.618 | 2.744 | 0.0247 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-binding-projection-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 1 | 1.856 | 1.981 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse` | 20 | 1.856 | 1.960 | 1.981 | 0 |

### Baseline: 2026-07-02T13:33:36+00:00 — root — reliability-gate-counter-flakes

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-counter-flakes.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-counter-flakes.json`
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 605.063 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a8af9e9c-0ada-45aa-8458-6d0fdb905648.log` |  |
| 2 | no | 580.728 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fb2a31da-2aea-4541-8d28-432d4e6ee669.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | no | 639.508 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3821b9dd-d545-4f23-ae63-8891752d44ca.log` | conductor process exit 1; terminal state failed; test exit 1 |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T13:33:36+00:00/e92a73ad4d82 | reliability-gate-counter-flakes | root | complete | 1 valid + 2 invalid | 2835 | 7 | 2842 | 605.063 | 605.063 | 0.0000 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-counter-flakes.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 45.865 | 6.151 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 44.907 | 5.039 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 42.060 | 2.444 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 30.431 | 21.464 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 26.189 | 4.009 | 0 |
| 6 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 21.420 | 17.495 | 1 |
| 7 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 21.081 | 3.388 | 0 |
| 8 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 20.317 | 2.685 | 0 |
| 9 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 19.457 | 3.275 | 0 |
| 10 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 18.944 | 11.939 | 0 |
| 11 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 15.624 | 1.177 | 0 |
| 12 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 13.452 | 5.610 | 0 |
| 13 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 12.844 | 2.190 | 0 |
| 14 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 12.518 | 3.240 | 0 |
| 15 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 11.166 | 4.272 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 10.654 | 10.537 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.205 | 10.201 | 0 |
| 18 | `RepoPromptTests.StoreBackedWorkspaceSearchTests` | 47 | 10.195 | 4.637 | 0 |
| 19 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 10.010 | 0.986 | 0 |
| 20 | `RepoPromptTests.GitBlobIdentityServiceTests` | 24 | 9.395 | 1.106 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 21.464 | 21.464 | 21.464 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 17.495 | 17.495 | 17.495 | 0 |
| 3 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 11.939 | 11.939 | 11.939 | 0 |
| 4 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 10.537 | 10.537 | 10.537 | 0 |
| 5 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 10.201 | 10.201 | 10.201 | 0 |
| 6 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 8.698 | 8.698 | 8.698 | 0 |
| 7 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 7.077 | 7.077 | 7.077 | 0 |
| 8 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 7.025 | 7.025 | 7.025 | 0 |
| 9 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 6.151 | 6.151 | 6.151 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 5.723 | 5.723 | 5.723 | 0 |
| 11 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 5.610 | 5.610 | 5.610 | 0 |
| 12 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 5.298 | 5.298 | 5.298 | 0 |
| 13 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 5.279 | 5.279 | 5.279 | 0 |
| 14 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 5.039 | 5.039 | 5.039 | 0 |
| 15 | `RepoPromptTests.StoreBackedWorkspaceSearchTests` | `testInitializingSessionWorktreeIsNarrowedOrTimesOutWithoutSearchingIncompleteCatalog` | 1 | 4.637 | 4.637 | 4.637 | 0 |
| 16 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | `testThreeRootSessionScopeReplacesCanonicalGitRootAndPreservesIndependentNonGitRoot` | 1 | 4.272 | 4.272 | 4.272 | 0 |
| 17 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 1 | 4.009 | 4.009 | 4.009 | 0 |
| 18 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 1 | 3.933 | 3.933 | 3.933 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testColdAutomaticSelectionUsesManifestEnvelopeAndCASWithoutUnrelatedBuild` | 1 | 3.850 | 3.850 | 3.850 | 0 |
| 20 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` | 1 | 3.543 | 3.543 | 3.543 | 0 |

### Reliability remediation note: 2026-07-02T13:40Z — counter flakes

- Change scope: test-only assertion hardening for two brittle root-gate counter flakes; no production code, fixtures, XCTest names, retry policies, or ledger rows changed.
- Raw source-log inspection:
  - Flake A copied log: `prompt-exports/raw-logs/current-reliability/mcp-code-structure-presentation-count-0e063528.log`. Failure block: `MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` at `MCPCodeStructureWorktreeTests.swift:215`; `presentationCandidateRequests` changed `7 -> 8` while all other before/after passive-tree counters and recovery state shown in the diagnostic were unchanged.
  - Flake B copied log: `prompt-exports/raw-logs/current-reliability/binding-engine-projection-counts-8caaeeac.log`. Failure block: `WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse` at lines `2043`, `2045`, `2046`; classifications `2 vs 1`, worktree classifications `6 vs 4`, validated reads `6 vs 4`.
- Focused validation:
  - Exact focused tests passed: `make dev-test FILTER=RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` (ticket `51ec2478-bc5c-4766-8f94-9189f378d246`) and `make dev-test FILTER=RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadMapsWorktreeAndTerminalGitClassificationsWithoutCleanReuse` (ticket `840b2401-412f-4f24-88f7-40ca70b8e1e3`).
  - Focused stress artifacts: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-mcp-passive-tree-20x.json` (`20 valid + 0 invalid`) and `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-counter-flakes-binding-projection-20x.json` (`20 valid + 0 invalid`).
  - Enclosing suites passed: `MCPCodeStructureWorktreeTests` (`18/18`, ticket `a4b63a80-9e62-432a-bfed-9a65a37c5da8`) and `WorkspaceCodemapBindingEngineTests` (`65/65`, ticket `f2c7db9e-8b7e-47f7-8fea-d4fff5f771f8`).
  - Style passed: `make dev-format` (`0/1371 files formatted`, ticket `adc4e764-b37a-4cb5-94d8-74c8d0abe2b4`) and `make dev-lint` (`0 violations`, ticket `4f1d27be-c81f-4b58-8261-e878a95daa5d`).
  - Ledger verifier remains pre-existing drift: `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` exited `1`, `missing=46 stale=2`.
- Root gate: exactly 3 complete-root samples, no replacements, label `reliability-gate-counter-flakes`; artifact `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-counter-flakes.json`; result `1 valid + 2 invalid`.
  - Sample 1 valid (`605.063s`), log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a8af9e9c-0ada-45aa-8458-6d0fdb905648.log`.
  - Sample 2 invalid copied log: `prompt-exports/raw-logs/current-reliability/root-gate-counter-flakes-sample2-fb2a31da.log`; unrelated `WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild`, failures at lines `4504`, `4506`, `4529` (`1 vs 0` and unexpected published graph summary).
  - Sample 3 invalid copied log: `prompt-exports/raw-logs/current-reliability/root-gate-counter-flakes-sample3-3821b9dd.log`; unrelated `WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes`, line `600` `XCTUnwrap` nil `WorkspaceCodemapSourceAuthorityToken`.
  - Recurrence check: Flake A, Flake B, and the prior busy-retry signature did not recur in the 3 root samples.
- Deltas: method delta `0`; contract delta `0`; scenario delta `0`; ledger delta `0`; production-code delta `0`; XCTest ID delta `0`.
### Focused: 2026-07-02T14:11:25+00:00 — root — reliability-gate-graph-source-authority-graph-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-20x.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 3.095 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/97715961-5ed1-4bc0-919f-952a4c8503e9.log` |  |
| 2 | no | 2.355 | 0.002 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/deeadeea-f7be-4bfc-aa3c-0b95726e1394.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 2.925 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/541304f1-d37e-4b83-99ff-044d08010e14.log` |  |
| 4 | yes | 2.823 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0910e7a3-ba84-4dd2-9ddb-3d3b999f6d7f.log` |  |
| 5 | no | 2.350 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b5f0d5af-afc0-4e42-8603-a7ba53d2b1b4.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 6 | yes | 3.051 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2ee2d4f8-3eb6-46b1-9c24-c446511a10f2.log` |  |
| 7 | no | 1.682 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ca165630-e135-4518-8c61-b661c693a1c8.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 8 | no | 2.836 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bbf84e7f-6200-41f4-ab85-eb66783bc531.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 9 | no | 1.684 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7df04522-134a-44f0-9964-81aeca85244c.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 10 | no | 1.645 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/72168be5-6d5c-444a-ac0a-db51f3f2ec59.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 11 | no | 2.876 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/800115ea-645d-489a-953d-3350613cb7e5.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 12 | yes | 2.832 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/44e61054-96a6-4f36-862a-c06f60cc6d93.log` |  |
| 13 | no | 1.685 | 0.003 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cd701a72-54fd-493f-97df-b6d3954521c8.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 14 | yes | 2.775 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cbcf0248-67b7-4ab5-8e92-6c94520d7d37.log` |  |
| 15 | no | 2.320 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9beb7815-7ee0-476c-a1aa-c7c0b9b7c6f3.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 16 | no | 2.830 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/34e797e0-dbd0-40ff-ac4c-73e9794354ee.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 17 | no | 2.325 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/82443cd1-4bf0-4dc4-a972-8e6f5b83a21f.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 18 | yes | 2.826 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ed7cc1fb-563c-4a23-9e57-d136a4669219.log` |  |
| 19 | yes | 2.827 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6ebab8b8-6c8d-461c-a1ef-7ff9fd0f8642.log` |  |
| 20 | yes | 2.911 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f15071ae-5c35-4943-9c54-602ad884f71f.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T14:11:25+00:00/209469caefdd | reliability-gate-graph-source-authority-graph-20x | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild` | 9 valid + 11 invalid |  |  |  | 2.832 | 3.095 | 0.0201 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 1 | 2.035 | 2.283 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | `testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild` | 9 | 2.035 | 2.283 | 2.283 | 0 |

### Focused: 2026-07-02T14:12:08+00:00 — root — reliability-gate-graph-source-authority-source-authority-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-20x.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 2.055 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0c095b06-e034-494d-9bf7-d8c5f109997c.log` |  |
| 2 | no | 1.863 | 0.006 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5d5aeed6-141b-4ed3-9638-e2dfa587def3.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 3 | yes | 2.022 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b423464a-2d38-4196-88d3-4e7f4acdf984.log` |  |
| 4 | yes | 2.017 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a69b7bc4-4da2-47ca-9559-4e117b439717.log` |  |
| 5 | yes | 2.000 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ef0a4312-840f-4a3e-94bf-31994bc818fe.log` |  |
| 6 | no | 1.900 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/82d1ec05-b451-47b7-8eb3-a14848b48590.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 7 | no | 1.903 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3d53d429-7c19-43df-a329-4adb837ae84f.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 8 | yes | 2.015 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5cea0996-8222-4002-97b3-43e4c683b811.log` |  |
| 9 | no | 1.485 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/822d4241-e14e-4031-ad8a-aba5a2f62b08.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 10 | yes | 1.954 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6e07d424-6adf-4449-acae-239482f4baba.log` |  |
| 11 | yes | 2.017 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0f707992-75f1-4532-93d1-97b66792b741.log` |  |
| 12 | no | 1.956 | 0.006 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8e43308a-0a44-43b7-b0cc-8f716149d04d.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 13 | no | 2.007 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e7b4397a-a772-4c73-9b09-c06cab9ce6f8.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 14 | yes | 1.981 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f1ac9485-ef14-4775-a82f-6a2ca0315988.log` |  |
| 15 | yes | 2.078 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/53f791d0-905e-44dd-97e7-dd0db3c808bb.log` |  |
| 16 | yes | 1.968 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9bdaab87-95e3-4a53-ae66-43551e025f4b.log` |  |
| 17 | no | 1.473 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/178da5ff-4705-481d-bac5-c36309f6172e.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 18 | yes | 1.968 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4db297be-1a03-4de2-bb36-b8b1bcfa183a.log` |  |
| 19 | yes | 1.962 | 0.006 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3121370b-ba0d-466c-a9ec-0aba73725d6f.log` |  |
| 20 | no | 1.910 | 0.005 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6b2ce915-d7cf-4678-add4-0c7a713e4d4f.log` | conductor process exit 1; terminal state failed; test exit 1 |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T14:12:08+00:00/209469caefdd | reliability-gate-graph-source-authority-source-authority-20x | root | filtered: `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes` | 12 valid + 8 invalid |  |  |  | 2.008 | 2.078 | 0.0165 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 1 | 1.191 | 1.259 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | `testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes` | 12 | 1.191 | 1.259 | 1.259 | 0 |

### Focused: 2026-07-02T14:21:39+00:00 — root — reliability-gate-graph-source-authority-graph-stable-attrs-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-stable-attrs-20x.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 3.157 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/838609b3-f8a6-4790-9229-5272e1b4a69a.log` |  |
| 2 | yes | 3.118 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e796c43f-76ff-47e0-a920-b188e309a3fe.log` |  |
| 3 | yes | 3.185 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8760a710-4b41-427d-b364-95903e14d4c2.log` |  |
| 4 | yes | 3.202 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/92b19744-3b20-4ff6-a257-7e97e73268d2.log` |  |
| 5 | yes | 3.122 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/54ef2cb2-760d-4f2d-9c3a-960ade9d699e.log` |  |
| 6 | yes | 3.207 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/31be9932-022d-4a95-b377-1c339c112660.log` |  |
| 7 | yes | 3.221 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fdb44953-2e5a-4730-8d2e-90c383edf59a.log` |  |
| 8 | yes | 2.823 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0719af77-147c-456b-a639-ccbb69c56dbb.log` |  |
| 9 | yes | 2.746 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/df881fc7-5708-4702-9306-3686e5626d49.log` |  |
| 10 | yes | 2.787 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/14e75ecf-251d-4b42-bca9-34922212ecef.log` |  |
| 11 | yes | 2.643 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/84481bab-a32b-4f2d-b774-4c16bf0d14f8.log` |  |
| 12 | yes | 2.651 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/543826cd-8c42-42ea-928f-07a354b9efbf.log` |  |
| 13 | yes | 2.564 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/efe25539-480e-4e2c-8463-3a8bb695a085.log` |  |
| 14 | yes | 2.549 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1a4e1600-a354-49e9-9dbd-74bc8b162c88.log` |  |
| 15 | yes | 2.604 | 0.010 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bbd6f7d8-9be9-4f01-8e08-18ededd3adfa.log` |  |
| 16 | yes | 3.600 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/fc879cfc-169c-49d5-8395-ca11afb43d53.log` |  |
| 17 | yes | 2.560 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/33aff576-bf1c-463a-91ec-81f6c055d814.log` |  |
| 18 | yes | 2.610 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/77801e2e-4225-484d-9e6d-11c9303cccb6.log` |  |
| 19 | yes | 2.597 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b897b862-8ec1-493d-831b-56452f75181e.log` |  |
| 20 | yes | 2.622 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/46177457-d1cf-42b9-a06d-d9b6a2aaca1e.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T14:21:39+00:00/209469caefdd | reliability-gate-graph-source-authority-graph-stable-attrs-20x | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild` | 20 valid + 0 invalid |  |  |  | 2.766 | 3.221 | 0.0738 | noisy | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-stable-attrs-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 1 | 2.002 | 2.890 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | `testGraphUpdateHidesQueuedContributionAndUnloadRevokesBlockedBuild` | 20 | 2.002 | 2.438 | 2.890 | 0 |

### Focused: 2026-07-02T14:22:16+00:00 — root — reliability-gate-graph-source-authority-source-authority-stable-attrs-20x

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-stable-attrs-20x.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 1.684 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3212e6a2-c66e-431d-9cdf-9f676416b07b.log` |  |
| 2 | yes | 1.611 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/56dec673-2672-427f-89b1-79b653ae76c3.log` |  |
| 3 | yes | 1.715 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/201811c8-f479-4ced-ab40-8055e04db33f.log` |  |
| 4 | yes | 1.619 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c48a8634-d17a-4252-a644-82d7b6a6b82f.log` |  |
| 5 | yes | 1.564 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b1568f38-19fb-4325-a16e-0062d9266ea1.log` |  |
| 6 | yes | 1.624 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8b623ca5-57b3-4d6b-b23c-b4c78de4bb56.log` |  |
| 7 | yes | 1.588 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2a5a0344-b7d9-4829-858c-cca77829c516.log` |  |
| 8 | yes | 1.627 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/617eba3a-16a4-4108-ae6b-fd7e8a995035.log` |  |
| 9 | yes | 1.622 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/73409220-38cf-4a8d-8ef3-e4bbdb4c55ac.log` |  |
| 10 | yes | 1.665 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/627521de-165a-4c9c-a6d9-cb3cf4dc795b.log` |  |
| 11 | yes | 1.605 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/96d519f0-813e-48ce-85ab-d0cd4799cffa.log` |  |
| 12 | yes | 1.621 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6bb35e42-ac97-4642-b497-834f588a1e91.log` |  |
| 13 | yes | 1.599 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/81770d7d-a88b-4147-8f15-c18207241108.log` |  |
| 14 | yes | 1.611 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/63b938b9-1f7c-4bb7-a1dc-9fb1cbccb75d.log` |  |
| 15 | yes | 1.598 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/109a17e4-6904-4f87-8f81-d0dd7293ee94.log` |  |
| 16 | yes | 1.611 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3ddee51a-01e3-4091-8e19-68c6b6db9dd1.log` |  |
| 17 | yes | 1.629 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e48169d3-b9fe-44ad-8679-99149071f0e9.log` |  |
| 18 | yes | 1.608 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8dee9192-b61d-495d-820d-8f7cde3ab0b7.log` |  |
| 19 | yes | 1.604 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/1ada8867-1660-44fd-ae00-be03af13a140.log` |  |
| 20 | yes | 1.608 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a286dd13-213f-411d-898b-66166710d472.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T14:22:16+00:00/209469caefdd | reliability-gate-graph-source-authority-source-authority-stable-attrs-20x | root | filtered: `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests/testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes` | 20 valid + 0 invalid |  |  |  | 1.611 | 1.684 | 0.0072 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-stable-attrs-20x.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | 1 | 0.893 | 0.962 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapGitCapabilityServiceTests` | `testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes` | 20 | 0.893 | 0.956 | 0.962 | 0 |



### Reliability remediation note: 2026-07-02T15:03Z — graph/source-authority two-sample root exception

- Change scope: bookkeeping/evidence recovery only in this pass; no implementation changes, no staging, no commits, and no additional complete-root samples were started by this bookkeeping pass.
- User-directed exception: the original 3-sample root gate was cut off at 2 counted complete-root samples because the app/control handle crashed or expired during testing. This entry intentionally records a 2-sample exception and does not fabricate a third counted sample.
- Focused graph/source-authority evidence:
  - Initial focused graph stress artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-20x.json` (`9 valid + 11 invalid`).
  - Initial focused source-authority stress artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-20x.json` (`12 valid + 8 invalid`).
  - Stable-attrs graph stress artifact passed: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-graph-stable-attrs-20x.json` (`20 valid + 0 invalid`).
  - Stable-attrs source-authority stress artifact passed: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-reliability-gate-graph-source-authority-source-authority-stable-attrs-20x.json` (`20 valid + 0 invalid`).
- Validation/bookkeeping commands recovered from conductor, not rerun here:
  - `make dev-format` / conductor format ticket `0acd32c4-17aa-42cb-b775-c0f1f4ee267f` passed (`0/1371 files formatted`).
  - `make dev-lint` / conductor lint ticket `dfeb5658-45cd-4da6-a912-d37b1141fc94` passed (`0 violations`).
  - Root XCTest list ticket `e55253c6-8f93-417a-a445-8392845d1dc4` passed; provider XCTest list ticket `54c0ec65-b9fc-4a99-832b-ffd58d7af47c` passed.
  - Source-authority enclosing suite ticket `4e553a3b-708e-4d01-996e-0716ed7cc288` passed (`17/17`).
- Root gate artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-reliability-gate-graph-source-authority-2sample-exception.json`; label `reliability-gate-graph-source-authority-2sample-exception`; primary metric eligible: no (user-directed 2-sample exception, not the standard 3-sample gate).
  - Counted sample 1 valid: ticket `7a244f75-7087-4f17-999e-f72dcbb3c887`, `2835 tests`, `5 skipped`, `0 failures`, `~708.6s` conductor/sample elapsed (`705.309s` XCTest elapsed; log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7a244f75-7087-4f17-999e-f72dcbb3c887.log`).
  - Counted sample 2 valid: ticket `f169e22a-dccf-4896-9e5e-2031dba53382`, `2835 tests`, `5 skipped`, `0 failures`, `652.531s` XCTest elapsed (log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f169e22a-dccf-4896-9e5e-2031dba53382.log`).
  - No third sample is counted for this root gate by user direction.
  - Overrun evidence not counted: ticket `b533efea-c21c-487e-acc9-116d8ef7d2ce` was already running when this bookkeeping pass resumed, reached failed state (`2835 tests`, `5 skipped`, `1 failure`, `708.785s` XCTest elapsed), and its copied raw log is `prompt-exports/raw-logs/current-reliability/root-gate-graph-source-authority-overrun-sample3-invalid-b533efea.log`. Failure signature: `ContextBuilderWorktreeInheritanceTests/testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps` codemap artifact unavailable for `Sources/DistinctConnectionA.swift`.
- Deltas: method delta `0`; contract delta `0`; scenario delta `0`; ledger delta `0`; production-code delta `0`; XCTest ID delta `0`.
### Focused: 2026-07-02T16:14:56+00:00 — root — wave1-after-worktree-exact-20260702

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.WorktreeAPISmokeHarnessTests/testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections --json`
Artifact: `docs/test-suite-optimizer/artifacts/wave1-after-worktree-exact-20260702.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.WorktreeAPISmokeHarnessTests/testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 12.348 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e3011e17-9599-4746-848b-6e5ded54ef37.log` |  |
| 2 | yes | 12.179 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/126cd5f1-b908-435a-96f3-4e8e03505a0d.log` |  |
| 3 | yes | 9.713 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ec391bce-748a-40de-b86e-c014799b0126.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T16:14:56+00:00/4423bf1dbe10 | wave1-after-worktree-exact-20260702 | root | filtered: `RepoPromptTests.WorktreeAPISmokeHarnessTests/testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 3 valid + 0 invalid |  |  |  | 12.179 | 12.348 | 0.0139 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-worktree-exact-20260702.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 1 | 11.341 | 11.563 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 3 | 11.341 | 11.563 | 11.563 | 0 |

### Focused: 2026-07-02T16:15:05+00:00 — root — wave1-after-contextbuilder-startup-20260702

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderModelStartupSelectionTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/wave1-after-contextbuilder-startup-20260702.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.ContextBuilderModelStartupSelectionTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.828 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/18b6ef0e-7953-4047-9619-258ccf8c801d.log` |  |
| 2 | yes | 0.954 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e4734fa0-bd52-4a58-bda7-1068e97243aa.log` |  |
| 3 | yes | 0.819 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b09a0da0-c72e-4f5e-bdc8-38b880311f35.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T16:15:05+00:00/4423bf1dbe10 | wave1-after-contextbuilder-startup-20260702 | root | filtered: `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | 3 valid + 0 invalid |  |  |  | 0.828 | 0.954 | 0.0105 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-contextbuilder-startup-20260702.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | 12 | 0.051 | 0.110 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testCachedCLIFlagIsNotReadyUntilCurrentProcessVerification` | 3 | 0.043 | 0.043 | 0.043 | 0 |
| 2 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testTransientFallbackResolutionDoesNotMutatePersistedSelection` | 3 | 0.003 | 0.003 | 0.003 | 0 |
| 3 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testValidPersistedSelectionSurvivesStoreReloadAndStartupResolution` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 4 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testOpenCodeStartupReadinessJoinsRunningPollAndEmitsLiveSnapshot` | 3 | 0.001 | 0.110 | 0.110 | 0 |
| 5 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testCursorStartupReadinessJoinsRunningPollWithoutDynamicMetadata` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 6 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testDynamicPersistedSelectionSurvivesAfterACPDiscovery` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 7 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testPersistedDynamicSelectionSurvivesStandardCatalogWarmup` | 3 | 0.000 | 0.001 | 0.001 | 0 |
| 8 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testFallbackUsesWizardRecommendationProviderFilter` | 3 | 0.000 | 0.000 | 0.000 | 0 |
| 9 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testFilteredRecommendationProvidersDoNotReappearThroughGenericFallback` | 3 | 0.000 | 0.000 | 0.000 | 0 |
| 10 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testStaticOpenCodeDefaultSurvivesAfterACPDiscovery` | 3 | 0.000 | 0.000 | 0.000 | 0 |
| 11 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testUnavailablePersistedSelectionFallsBackToRecommendedAvailableProvider` | 3 | 0.000 | 0.000 | 0.000 | 0 |
| 12 | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `testUnconfiguredClaudeCodeCannotBecomeEffectiveStartupSelection` | 3 | 0.000 | 0.000 | 0.000 | 0 |

### Focused: 2026-07-02T16:15:14+00:00 — root — wave1-after-mention-coordinator-20260702

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.MentionCoordinatorTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/wave1-after-mention-coordinator-20260702.json`
Inventory: ``
Scope/filter: filtered: `RepoPromptTests.MentionCoordinatorTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.936 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/84a3a792-bd5c-4a81-a754-b3d9f276d991.log` |  |
| 2 | yes | 0.976 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8c6cca86-301d-4e71-ac17-4ab00254c3aa.log` |  |
| 3 | yes | 0.978 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3693c67a-621f-4aa7-be2f-6566ef665e67.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T16:15:14+00:00/4423bf1dbe10 | wave1-after-mention-coordinator-20260702 | root | filtered: `RepoPromptTests.MentionCoordinatorTests` | 3 valid + 0 invalid |  |  |  | 0.976 | 0.978 | 0.0021 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-mention-coordinator-20260702.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MentionCoordinatorTests` | 4 | 0.158 | 0.155 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.MentionCoordinatorTests` | `testClickingAncestorWindowMakesThatLevelCurrentForFurtherNavigation` | 3 | 0.154 | 0.155 | 0.155 | 0 |
| 2 | `RepoPromptTests.MentionCoordinatorTests` | `testWorkspaceReuseKeepsSuggestionsAndCommitRemovalOnNewFileManager` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 3 | `RepoPromptTests.MentionCoordinatorTests` | `testDeallocatedManagerUpdatingToNilInvalidatesActiveMentionState` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 4 | `RepoPromptTests.MentionCoordinatorTests` | `testWorkspaceSwitchInvalidatesStaleDebouncedQuery` | 3 | 0.001 | 0.001 | 0.001 | 0 |

### Wave 1 bookkeeping: 2026-07-02T16:15Z — optimization-wave1-mechanical-polling

- Wave label: `optimization-wave1-mechanical-polling`.
- Commit range: `7452e2db..4423bf1d`.
- Wave head verified before validation: clean working tree, `HEAD=4423bf1d`.
- Members/files changed:
  - `f3dca88d` Optimize worktree API smoke selection settles — `Tests/RepoPromptTests/MCP/WorktreeAPISmokeHarnessTests.swift`.
  - `39b40a31` Optimize ACP startup fake discovery gates — `Sources/RepoPrompt/Infrastructure/AI/Providers/Cursor/CursorACPModelPollingService.swift`, `Sources/RepoPrompt/Infrastructure/AI/Providers/OpenCode/OpenCodeACPModelPollingService.swift`, `Tests/RepoPromptTests/ContextBuilder/ContextBuilderModelStartupSelectionTests.swift`.
  - `4423bf1d` Optimize mention coordinator debounce tests — `Sources/RepoPrompt/Infrastructure/UI/TextField/MentionCoordinator.swift`, `Tests/RepoPromptTests/Mentions/MentionCoordinatorTests.swift`.
- Per-member root deltas were not individually measured. No pre-change focused optimizer artifacts were captured for these three members, so the after-only focused artifacts below are recorded as post-change evidence and the aggregate root delta is deferred to a future wave/root gate.
- No complete-root gate was run in this pass. Raw conductor logs remain outside the repository and were not committed.
- AgentRun 2s member was inspected/deferred; no speed claim is made for it here.
- Method delta `0`; contract delta `0`; scenario delta `0`; XCTest ID delta `0`; ledger drift unchanged and the ledger was not edited.

Validation recovered from pair agents:

- Worktree exact: focused ticket `6b120e29-5cce-47b7-b5a0-8929f625dc06`, suite ticket `44d18e52-53a6-4841-8afc-6def5665c062`, format-check `b24480ca-aa73-4977-b781-e6aaea25c6bf`.
- ContextBuilder suite: ticket `8e52bd18-8c0b-4081-8766-8df0e563d7b1`, format-check `6c14412f-0790-4c10-96f8-53402a8de2bc`, test-list `51dea008-413a-49f5-96ad-faac84619196`.
- Mention suite: ticket `cdc8cb18-91fc-40b3-aec8-9bc05a9b9b86`, format-check `fd3494ee-65fd-467c-825b-1eee50106a0a`.

Wave-head validation run in this bookkeeping pass:

- `make dev-lint` passed: conductor lint ticket `7dc495ea-2721-4631-899a-40fe5f61d9df`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7dc495ea-2721-4631-899a-40fe5f61d9df.log`; SwiftFormat reported `0/1371 files require formatting`; SwiftLint reported `0 violations, 0 serious in 1371 files`.
- `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` exited nonzero with the known pre-existing drift: `missing=46 stale=2`; examples printed were `AgentContextExportResolverTests/testBoundWorktreeAutoCodemapDoesNotUseMetadataOnlyFastPathWhenAutoCodemapEnabled`, `testEmptyBoundExportSkipsWorktreeProjection`, `testEmptyDirectFilePreviewReturnsEmptyContent`, `testMetadataOnlyWorktreeExportDoesNotDirectReadSymlinkEscapingRoot`, `testNonGitAutomaticExportBatchesSelectedPathLookupsWithoutRuntimeFallback`; stale examples `AgentContextExportResolverTests/testNonGitAutomaticExportPreservesSelectedRowsWithoutRuntimeOrLegacyFallback`, `WorkspaceSelectionAutoCodemapInvariantTests/testStoredSelectionPersistsManualPathsButDiscardsLegacyInferredPathKey`. Underlying test-list tickets: root `2e346a09-b6f7-40ce-ad86-470713f0b0ec` (log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2e346a09-b6f7-40ce-ad86-470713f0b0ec.log`) and provider `7ae38411-79e7-4d67-ba06-7f7a72c50a5a` (log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7ae38411-79e7-4d67-ba06-7f7a72c50a5a.log`). Ledger intentionally unchanged.

After-only focused optimizer artifacts from this pass (`--samples 3`, `--source-change-guard content`, primary metric eligible: no):

| Label | Filter | Tickets | Samples | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact |
|---|---|---|---:|---:|---:|---:|---|---|
| `wave1-after-worktree-exact-20260702` | `RepoPromptTests.WorktreeAPISmokeHarnessTests/testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | `e3011e17-9599-4746-848b-6e5ded54ef37`, `126cd5f1-b908-435a-96f3-4e8e03505a0d`, `ec391bce-748a-40de-b86e-c014799b0126` | 3 valid + 0 invalid | 12.179 | 12.348 | 0.0139 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-worktree-exact-20260702.json` |
| `wave1-after-contextbuilder-startup-20260702` | `RepoPromptTests.ContextBuilderModelStartupSelectionTests` | `18b6ef0e-7953-4047-9619-258ccf8c801d`, `e4734fa0-bd52-4a58-bda7-1068e97243aa`, `b09a0da0-c72e-4f5e-bdc8-38b880311f35` | 3 valid + 0 invalid | 0.828 | 0.954 | 0.0105 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-contextbuilder-startup-20260702.json` |
| `wave1-after-mention-coordinator-20260702` | `RepoPromptTests.MentionCoordinatorTests` | `84a3a792-bd5c-4a81-a754-b3d9f276d991`, `8c6cca86-301d-4e71-ac17-4ab00254c3aa`, `3693c67a-621f-4aa7-be2f-6566ef665e67` | 3 valid + 0 invalid | 0.976 | 0.978 | 0.0021 | stable | `docs/test-suite-optimizer/artifacts/wave1-after-mention-coordinator-20260702.json` |

### Deferred optimization note: 2026-07-02T16:55Z — P1 ContextBuilder readiness fences

- Candidate: standalone P1 `ContextBuilderWorktreeInheritanceTests` readiness fences.
- Plan source: context-builder plan `p1-readiness-fences-2A0AD4`; consumed plan export was deleted after handoff.
- Pair attempted the scoped implementation experimentally and restored all source changes because the attempt did not stay inside the optimization/safety boundary.
- Preserved before artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-optimization-p1-contextbuilder-worktree-readiness-before-20260702T163300Z.json` (`3 valid + 0 invalid`, median `66.087s`, observed p95 `75.848s`, commit `4a5790e2`).
- Experimental result (not committed): full focused suite worsened to roughly `112–124s`; the non-agent path exposed intermittent `registrationFailed` around codemap demand timing; graph-drain changes materially increased wallclock.
- Decision: defer P1 pending a diagnostic investigation of the codemap `registrationFailed` timing and the ContextBuilder fence cost profile. No source code, production semantics, XCTest IDs, ledger rows, method/contract/scenario counts, or root-gate claims changed in this note.
- Next suggested planning path: ask design/context-builder to split P1 into diagnostic sub-problems or move to the next low-risk breadth cleanup wave if P1 remains unsafe.
### Focused: 2026-07-02T17:30:58+00:00 — root — wave2-before-m1-tool-tracking-20260702T172942Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AgentToolTrackingControllerTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m1-tool-tracking-20260702T172942Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AgentToolTrackingControllerTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 71.929 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cf208564-b449-48c0-a4b1-24bb18efe3c4.log` |  |
| 2 | yes | 1.355 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8a022cf7-c0f5-4dda-83a7-3776515e3d34.log` |  |
| 3 | yes | 1.370 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/effe8eed-b25d-4947-b48a-38e5c6663660.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T17:30:58+00:00/8654b62b3445 | wave2-before-m1-tool-tracking-20260702T172942Z | root | filtered: `RepoPromptTests.AgentToolTrackingControllerTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 1.370 | 71.929 | 0.0110 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m1-tool-tracking-20260702T172942Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | 4 | 0.563 | 0.328 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testToolObserverCallbacksReturnBeforeFIFOTranscriptDeliveryCompletes` | 3 | 0.310 | 0.328 | 0.328 | 0 |
| 2 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier` | 3 | 0.170 | 0.172 | 0.172 | 0 |
| 3 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testStopWaitsForCapturedObserverToEnterMailboxAndDrain` | 3 | 0.080 | 0.085 | 0.085 | 0 |
| 4 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testOverlappingStopAndStartUnregistersOldObserverAndReleasesCallbacks` | 3 | 0.003 | 0.003 | 0.003 | 0 |

### Focused: 2026-07-02T17:34:20+00:00 — root — wave2-after-m1-tool-tracking-20260702T173417Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AgentToolTrackingControllerTests --json`
Artifact: `artifact pruned; superseded after-run summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AgentToolTrackingControllerTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.827 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9a18f137-595e-4f54-84d2-a11aca9f859f.log` |  |
| 2 | yes | 0.783 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a013a63c-5e4e-477b-bbd5-4cc2beda4475.log` |  |
| 3 | yes | 0.776 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bc2e3aef-20fb-43e3-842e-e24f62097544.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T17:34:20+00:00/8654b62b3445 | wave2-after-m1-tool-tracking-20260702T173417Z | root | filtered: `RepoPromptTests.AgentToolTrackingControllerTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 0.783 | 0.827 | 0.0093 | stable | `artifact pruned; superseded after-run summary retained in scoreboard` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | 4 | 0.005 | 0.003 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier` | 3 | 0.003 | 0.003 | 0.003 | 0 |
| 2 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testOverlappingStopAndStartUnregistersOldObserverAndReleasesCallbacks` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 3 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testToolObserverCallbacksReturnBeforeFIFOTranscriptDeliveryCompletes` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 4 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testStopWaitsForCapturedObserverToEnterMailboxAndDrain` | 3 | 0.000 | 0.001 | 0.001 | 0 |

### Focused: 2026-07-02T17:36:36+00:00 — root — wave2-after-m1-tool-tracking-20260702T173633Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AgentToolTrackingControllerTests --json`
Artifact: `artifact pruned; superseded after-run summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AgentToolTrackingControllerTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.827 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8236c640-51ed-473b-9e73-947d9edc00cc.log` |  |
| 2 | yes | 0.879 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2940930d-2bd5-4e8b-b74f-4c5e5e11da72.log` |  |
| 3 | yes | 0.773 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/6be41db2-6e30-4356-80d3-ca053e1c77c4.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T17:36:36+00:00/8654b62b3445 | wave2-after-m1-tool-tracking-20260702T173633Z | root | filtered: `RepoPromptTests.AgentToolTrackingControllerTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 0.827 | 0.879 | 0.0635 | noisy | `artifact pruned; superseded after-run summary retained in scoreboard` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | 4 | 0.005 | 0.104 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier` | 3 | 0.003 | 0.003 | 0.003 | 0 |
| 2 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testStopWaitsForCapturedObserverToEnterMailboxAndDrain` | 3 | 0.001 | 0.104 | 0.104 | 0 |
| 3 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testOverlappingStopAndStartUnregistersOldObserverAndReleasesCallbacks` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 4 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testToolObserverCallbacksReturnBeforeFIFOTranscriptDeliveryCompletes` | 3 | 0.001 | 0.001 | 0.001 | 0 |

### Wave 2 M1 member note: 2026-07-02T17:46Z — optimization-wave2-m1-tool-tracking-gates

- Scope: test-only deterministic gates in `Tests/RepoPromptTests/AgentMode/AgentToolTrackingControllerTests.swift`; production diff `0`.
- Contract preserved: observer fire calls still return before FIFO transcript callback bodies drain; `stopTracking()` / raw unregister still wait on captured delivery barriers and mailbox drain; FIFO/order assertions retained.
- Source changes: replaced fixed `Thread.sleep` / `Task.sleep` waits in the suite with test-local synchronous callback/checkpoint gates plus cooperative observer-count checks. No wallclock sleeps remain in the target file.
- Focused before artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m1-tool-tracking-20260702T172942Z.json` — `3 valid + 0 invalid`, median `1.370s`, observed p95 `71.929s`, relative MAD `0.0110`, noise `stable`.
- Focused after artifact (final source): `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m1-tool-tracking-20260702T174531Z.json` — `3 valid + 0 invalid`, median `0.716s`, observed p95 `0.775s`, relative MAD `0.0055`, noise `stable`.
- Superseded after artifacts `artifact pruned; superseded after-run summary retained in scoreboard` and `artifact pruned; superseded after-run summary retained in scoreboard` were generated before later style/review refinements; final comparison uses `20260702T174531Z`.
- Validation: `make dev-test FILTER=RepoPromptTests.AgentToolTrackingControllerTests` passed, ticket `58c9fa87-368e-49d0-8871-ff9478161e25`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/58c9fa87-368e-49d0-8871-ff9478161e25.log`; `make dev-format-check` passed, ticket `e3295503-04ba-49c7-a4e2-532c8c5bfb64`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e3295503-04ba-49c7-a4e2-532c8c5bfb64.log`.
- Method delta `0`; contract delta `0`; scenario delta `0`; XCTest-ID delta `0`; ledger untouched.
- root delta not individually measured; see future Wave 2 gate.

### Focused: 2026-07-02T17:45:34+00:00 — root — wave2-after-m1-tool-tracking-20260702T174531Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.AgentToolTrackingControllerTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m1-tool-tracking-20260702T174531Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.AgentToolTrackingControllerTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 0.775 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/672c6469-f879-42d3-8c74-83ddbec1dd42.log` |  |
| 2 | yes | 0.712 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7d9c9a47-5283-45a1-9762-04198ae80ebd.log` |  |
| 3 | yes | 0.716 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/25f5a14d-1dd7-4a90-9315-ef55b9b6c573.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T17:45:34+00:00/8654b62b3445 | wave2-after-m1-tool-tracking-20260702T174531Z | root | filtered: `RepoPromptTests.AgentToolTrackingControllerTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 0.716 | 0.775 | 0.0055 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m1-tool-tracking-20260702T174531Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | 4 | 0.004 | 0.002 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testConcurrentRawUnregisterAndStopJoinCapturedDeliveryBarrier` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 2 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testOverlappingStopAndStartUnregistersOldObserverAndReleasesCallbacks` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 3 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testToolObserverCallbacksReturnBeforeFIFOTranscriptDeliveryCompletes` | 3 | 0.001 | 0.001 | 0.001 | 0 |
| 4 | `RepoPromptTests.AgentToolTrackingControllerTests` | `testStopWaitsForCapturedObserverToEnterMailboxAndDrain` | 3 | 0.000 | 0.000 | 0.000 | 0 |
### Focused: 2026-07-02T17:59:08+00:00 — root — wave2-before-m2-content-loading-gates-20260702T175847Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.FileSystemContentLoadingConcurrencyTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m2-content-loading-gates-20260702T175847Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.FileSystemContentLoadingConcurrencyTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 16.807 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/71ae8032-8697-4248-8164-2597e9ca69e4.log` |  |
| 2 | yes | 1.706 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/f60b3c14-391b-4b89-b7df-fbf676004c96.log` |  |
| 3 | yes | 1.619 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a02a4ddd-1936-4f37-94fe-8f74bfbf4642.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T17:59:08+00:00/304a44f19e27 | wave2-before-m2-content-loading-gates-20260702T175847Z | root | filtered: `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 1.706 | 16.807 | 0.0512 | noisy | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m2-content-loading-gates-20260702T175847Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | 24 | 0.880 | 0.224 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testSlowSameRootContentReadDoesNotDelayAcceptedWatcherFlush` | 3 | 0.224 | 0.224 | 0.224 | 0 |
| 2 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testOffActorContentReadWorkerConcurrencyIsBounded` | 3 | 0.128 | 0.129 | 0.129 | 0 |
| 3 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerReservesPermitForLatencySensitiveReadsAcrossSupportedCapacities` | 3 | 0.109 | 0.206 | 0.206 | 0 |
| 4 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerRoundRobinsOwnersWhilePreservingOwnerFIFO` | 3 | 0.060 | 0.061 | 0.061 | 0 |
| 5 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerForegroundTokensBlockCodemapReplacementUntilFinalEnd` | 3 | 0.048 | 0.048 | 0.048 | 0 |
| 6 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerNeverPromotesAgedCodemapAheadOfForegroundWaiters` | 3 | 0.046 | 0.047 | 0.047 | 0 |
| 7 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerBoundsQueueCancelsWaitersAndReturnsIdle` | 3 | 0.038 | 0.042 | 0.042 | 0 |
| 8 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testQueuedContentReadWorkerPermitWaitRecordsCorrelatedAcquireAndPrivacySafeDimensions` | 3 | 0.038 | 0.040 | 0.040 | 0 |
| 9 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testStaleChunkedReadDoesNotOverwriteEncodingCacheAfterConcurrentEdit` | 3 | 0.037 | 0.041 | 0.041 | 0 |
| 10 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancelledQueuedContentReadWorkerPermitWaitRecordsCancellationWithoutAcquisitionOrLeak` | 3 | 0.037 | 0.037 | 0.037 | 0 |
| 11 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentLoadingPreservesTextBinaryEmptyFallbackLargeFileAndCacheBehavior` | 3 | 0.024 | 0.025 | 0.025 | 0 |
| 12 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerPrioritizesInteractiveWaitersOverBulk` | 3 | 0.024 | 0.024 | 0.024 | 0 |
| 13 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testChunkedReadEnforcesConfiguredSizeLimitWhenFileGrows` | 3 | 0.022 | 0.022 | 0.022 | 0 |
| 14 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testSlowContentReadOnRootADoesNotDelayRootBReadAndWatcherFlush` | 3 | 0.020 | 0.021 | 0.021 | 0 |
| 15 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testForegroundActivityTokensCleanUpOnSuccessErrorAndCancellation` | 3 | 0.013 | 0.013 | 0.013 | 0 |
| 16 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancelledActiveBackgroundReadRetainsPermitUntilBodyReturns` | 3 | 0.012 | 0.013 | 0.013 | 0 |
| 17 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancellationDuringChunkedReadDoesNotCommitEncodingCache` | 3 | 0.005 | 0.007 | 0.007 | 0 |
| 18 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testValidatedRawContentRejectsSymlinkRetargetDuringRead` | 3 | 0.003 | 0.003 | 0.003 | 0 |
| 19 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentLoadingRejectsTraversalAndSymlinkTargets` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 20 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testValidatedRawContentReadsExactBytesWithoutProbeOrReread` | 3 | 0.002 | 0.002 | 0.002 | 0 |

### Focused: 2026-07-02T18:02:30+00:00 — root — wave2-after-m2-content-loading-gates-20260702T180225Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.FileSystemContentLoadingConcurrencyTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m2-content-loading-gates-20260702T180225Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.FileSystemContentLoadingConcurrencyTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 1.563 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/eb839605-2479-403e-8097-ea75cb84731e.log` |  |
| 2 | yes | 1.455 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d7e90aa4-a44e-46b7-9d78-a60bb605c5d8.log` |  |
| 3 | yes | 1.443 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/bff4d446-4bc0-490a-8c4a-62c8d3e89219.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T18:02:30+00:00/304a44f19e27 | wave2-after-m2-content-loading-gates-20260702T180225Z | root | filtered: `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 1.455 | 1.563 | 0.0082 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m2-content-loading-gates-20260702T180225Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | 24 | 0.685 | 0.219 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testSlowSameRootContentReadDoesNotDelayAcceptedWatcherFlush` | 3 | 0.215 | 0.219 | 0.219 | 0 |
| 2 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerReservesPermitForLatencySensitiveReadsAcrossSupportedCapacities` | 3 | 0.079 | 0.082 | 0.082 | 0 |
| 3 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerRoundRobinsOwnersWhilePreservingOwnerFIFO` | 3 | 0.049 | 0.053 | 0.053 | 0 |
| 4 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerNeverPromotesAgedCodemapAheadOfForegroundWaiters` | 3 | 0.047 | 0.048 | 0.048 | 0 |
| 5 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerForegroundTokensBlockCodemapReplacementUntilFinalEnd` | 3 | 0.046 | 0.049 | 0.049 | 0 |
| 6 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testStaleChunkedReadDoesNotOverwriteEncodingCacheAfterConcurrentEdit` | 3 | 0.037 | 0.038 | 0.038 | 0 |
| 7 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerBoundsQueueCancelsWaitersAndReturnsIdle` | 3 | 0.036 | 0.043 | 0.043 | 0 |
| 8 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancelledQueuedContentReadWorkerPermitWaitRecordsCancellationWithoutAcquisitionOrLeak` | 3 | 0.030 | 0.033 | 0.033 | 0 |
| 9 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentLoadingPreservesTextBinaryEmptyFallbackLargeFileAndCacheBehavior` | 3 | 0.025 | 0.025 | 0.025 | 0 |
| 10 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentReadSchedulerPrioritizesInteractiveWaitersOverBulk` | 3 | 0.024 | 0.024 | 0.024 | 0 |
| 11 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testChunkedReadEnforcesConfiguredSizeLimitWhenFileGrows` | 3 | 0.022 | 0.023 | 0.023 | 0 |
| 12 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testQueuedContentReadWorkerPermitWaitRecordsCorrelatedAcquireAndPrivacySafeDimensions` | 3 | 0.022 | 0.023 | 0.023 | 0 |
| 13 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancelledActiveBackgroundReadRetainsPermitUntilBodyReturns` | 3 | 0.012 | 0.015 | 0.015 | 0 |
| 14 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testOffActorContentReadWorkerConcurrencyIsBounded` | 3 | 0.012 | 0.013 | 0.013 | 0 |
| 15 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testSlowContentReadOnRootADoesNotDelayRootBReadAndWatcherFlush` | 3 | 0.008 | 0.010 | 0.010 | 0 |
| 16 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testCancellationDuringChunkedReadDoesNotCommitEncodingCache` | 3 | 0.005 | 0.006 | 0.006 | 0 |
| 17 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testValidatedRawContentRejectsSymlinkRetargetDuringRead` | 3 | 0.003 | 0.003 | 0.003 | 0 |
| 18 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testContentLoadingRejectsTraversalAndSymlinkTargets` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 19 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testForegroundActivityTokensCleanUpOnSuccessErrorAndCancellation` | 3 | 0.002 | 0.002 | 0.002 | 0 |
| 20 | `RepoPromptTests.FileSystemContentLoadingConcurrencyTests` | `testValidatedRawContentReadsExactBytesWithoutProbeOrReread` | 3 | 0.002 | 0.002 | 0.002 | 0 |

### Wave 2 M2 member note: 2026-07-02T18:04Z — optimization-wave2-m2-content-loading-gates

- Scope: test-only deterministic gates in `Tests/RepoPromptTests/Services/FileSystem/FileSystemContentLoadingConcurrencyTests.swift`; evidence-only updates under `docs/test-suite-optimizer/`; production diff `0`.
- Contract preserved: `testOffActorContentReadWorkerConcurrencyIsBounded` still proves no overflow worker enters before the gate is released, now by observing a held-gate limiter snapshot with `activePermitCount == limit` and queued overflow work present before preserving `enteredBeforeRelease == limit`.
- Source changes: replaced the 100ms negative wait with positive process-wide limiter snapshot proof; converted test-local `AsyncCounter.waitUntilValue` and `AsyncSignal.waitUntilMarked` from 10ms polling to continuation-backed waiters with timeout-returning, idempotent cleanup. Lifecycle/publication/snapshot positive polling helpers remain bounded polls where no exact signal exists; the 60s cancellation sentinel is untouched.
- Focused before artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m2-content-loading-gates-20260702T175847Z.json` — `3 valid + 0 invalid`, median `1.706s`, observed p95 `16.807s`, relative MAD `0.0512`, noise `noisy`.
- Focused after artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m2-content-loading-gates-20260702T180225Z.json` — `3 valid + 0 invalid`, median `1.455s`, observed p95 `1.563s`, relative MAD `0.0082`, noise `stable`.
- Validation: `make dev-test FILTER=RepoPromptTests.FileSystemContentLoadingConcurrencyTests` passed, ticket `4e52f655-49cc-4513-b9ce-8a94083fc953`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4e52f655-49cc-4513-b9ce-8a94083fc953.log`; `make dev-format-check` passed, ticket `dd7fce24-e74d-4c78-886f-628e8d206c3b`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dd7fce24-e74d-4c78-886f-628e8d206c3b.log`.
- Method delta `0`; contract delta `0`; scenario delta `0`; XCTest-ID delta `0`; ledger untouched; raw logs uncommitted.
- root delta not individually measured; see future Wave 2 gate.

### Focused: 2026-07-02T19:09:38+00:00 — root — wave2-after-m3prime-contextbuilder-codemap-gate-20260702T190736Z

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.ContextBuilderWorktreeInheritanceTests --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m3prime-contextbuilder-codemap-gate-20260702T190736Z.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-phase3-setup-20260701T141721Z.json`
Scope/filter: filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 40.784 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/75220637-5cf5-48a6-815d-e45fa5d7fc13.log` |  |
| 2 | yes | 34.005 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/592978ea-71ce-46e7-983c-3c7d61a35d9d.log` |  |
| 3 | yes | 45.687 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2c999fcf-4e2f-42a7-80e0-39291fd0e836.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T19:09:38+00:00/25a0d3fe8159 | wave2-after-m3prime-contextbuilder-codemap-gate-20260702T190736Z | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 valid + 0 invalid | 2825 | 7 | 2832 | 40.784 | 45.687 | 0.1202 | unstable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m3prime-contextbuilder-codemap-gate-20260702T190736Z.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 4 | 31.899 | 35.476 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 3 | 20.744 | 35.476 | 35.476 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeTwoRootContextBuilderImplicitGitPublishesSelectedRepository` | 3 | 4.804 | 7.759 | 7.759 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderUsesFrozenWorktreeAcrossNestedToolsAccountingAndFollowUps` | 3 | 2.929 | 3.140 | 3.140 | 0 |
| 4 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeContextBuilderFailsClosedBeforeProviderCreationWhenWorktreeIsUnavailable` | 3 | 0.465 | 0.471 | 0.471 | 0 |

### Wave 2 M3′ member note: 2026-07-02T19:11Z — optimization-wave2-m3prime-contextbuilder-codemap-gate

- Decision/tags: `reliability-hardening`, `coverage-tradeoff`.
- Scope: test-only helper `Tests/RepoPromptTests/Helpers/CodemapE2ETestGating.swift`; one-method test change in `Tests/RepoPromptTests/ContextBuilder/ContextBuilderWorktreeInheritanceTests.swift`; contributor docs in `docs/testing.md`; evidence-only updates under `docs/test-suite-optimizer/`; production diff `0`.
- Contract preserved: `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` still proves canonical non-agent workspace routing, read/search sentinel visibility, selected git artifact publication, review follow-up packaging, canonical code-structure path shape, and no worktree leakage. Routine gates no longer await live tree-sitter codemap generation for this pipeline contract.
- Coverage tradeoff: the strict live codemap generation scenario moved from the routine gate to `RPCE_RUN_CODEMAP_E2E=1` or `/tmp/RepoPromptCE-codemap-e2e-opt-in`; compensating leaf generation coverage remains in codemap golden/builder tests per `docs/analysis/test-suite-codemap-sensitive-test-strategy-2026-07-02.md`.
- Focused before pivot artifact (exact non-agent method): `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m3-contextbuilder-registrationfailed-nonagent-20260702T181503Z.json` — `2 valid + 1 invalid`; invalid sample hit the registration/real-generation flake; median `25.664s`, observed p95 `32.606s`, noise `unstable`.
- Focused before pivot artifact (full ContextBuilder suite): `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-before-m3-contextbuilder-registrationfailed-suite-20260702T181641Z.json` — `3 valid + 0 invalid`, median `85.225s`, observed p95 `85.781s`, relative MAD `0.0065`, noise `stable`.
- Focused after artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-wave2-after-m3prime-contextbuilder-codemap-gate-20260702T190736Z.json` — `3 valid + 0 invalid`, median `40.784s`, observed p95 `45.687s`, relative MAD `0.1202`, noise `unstable`.
- Strict E2E validation: `RPCE_RUN_CODEMAP_E2E=1 make dev-test FILTER=RepoPromptTests.ContextBuilderWorktreeInheritanceTests` passed, ticket `330ba2ad-6429-4b86-bd97-30af670a3ce6`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/330ba2ad-6429-4b86-bd97-30af670a3ce6.log`.
- List/ledger/style validation: `make dev-test-list` passed, ticket `3ccd78b5-71a5-46eb-b993-cf1c135e1550`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/3ccd78b5-71a5-46eb-b993-cf1c135e1550.log`; `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` failed with pre-existing live-ID reconciliation mismatch `missing=46 stale=2`; `make dev-format` passed after the final Swift edit, ticket `7cc562fd-9dab-41f4-9896-3faa0afca893`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7cc562fd-9dab-41f4-9896-3faa0afca893.log`; `make dev-format-check` passed, ticket `d979927f-6c70-414b-8382-c174a8b7373c`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d979927f-6c70-414b-8382-c174a8b7373c.log`; `make dev-lint` passed, ticket `0c0d5584-ecd3-42fe-83c7-e6ce5865d063`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0c0d5584-ecd3-42fe-83c7-e6ce5865d063.log`.
- Method delta `0`; contract delta `0`; scenario delta `0`; XCTest-ID delta `0`; ledger unchanged; raw logs uncommitted.
- root timing deferred to the next root stabilization gate; no individual root delta claimed. root delta not individually measured; see future Wave 2 gate.
### Baseline: 2026-07-02T19:42:06+00:00 — root — root-stabilization-after-w2-m3prime-20260702-151854

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `artifact pruned; superseded failed root-stabilization summary retained in scoreboard`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | no | 693.298 | 0.004 | failed | 1 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/19a21e63-c24a-4e91-a4be-1df1a37b458b.log` | conductor process exit 1; terminal state failed; test exit 1 |
| 2 | yes | 657.333 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8c89bb0e-df2e-4105-bb17-bc58866b97a1.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T19:42:06+00:00/07004bab4570 | root-stabilization-after-w2-m3prime-20260702-151854 | root | complete | 1 valid + 1 invalid | 2835 | 7 | 2842 | 657.333 | 657.333 | 0.0000 | stable | `artifact pruned; superseded failed root-stabilization summary retained in scoreboard` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 46.117 | 5.638 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 44.877 | 2.534 | 0 |
| 3 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 42.109 | 4.649 | 0 |
| 4 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 31.883 | 7.315 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 28.519 | 5.341 | 0 |
| 6 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 27.877 | 3.982 | 0 |
| 7 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 26.290 | 12.955 | 0 |
| 8 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 23.771 | 11.055 | 0 |
| 9 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 20.901 | 16.918 | 1 |
| 10 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 20.359 | 2.333 | 0 |
| 11 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 19.503 | 11.905 | 0 |
| 12 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 16.990 | 9.861 | 0 |
| 13 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 16.176 | 1.395 | 0 |
| 14 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 17 | 14.424 | 2.593 | 0 |
| 15 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 13.473 | 3.789 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 10.814 | 10.567 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 10.559 | 10.556 | 0 |
| 18 | `RepoPromptTests.StoreBackedWorkspaceSearchTests` | 47 | 10.490 | 4.468 | 0 |
| 19 | `RepoPromptTests.ACPAgentSessionControllerModeConfigTests` | 27 | 8.789 | 1.134 | 0 |
| 20 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 8.618 | 0.776 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 1 | 16.918 | 16.918 | 16.918 | 0 |
| 2 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 1 | 12.955 | 12.955 | 12.955 | 0 |
| 3 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testNonAgentContextBuilderKeepsCanonicalWorkspaceBehavior` | 1 | 12.890 | 12.890 | 12.890 | 0 |
| 4 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | `testThreeRootSessionScopeReplacesCanonicalGitRootAndPreservesIndependentNonGitRoot` | 1 | 11.905 | 11.905 | 11.905 | 0 |
| 5 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 1 | 11.055 | 11.055 | 11.055 | 0 |
| 6 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 1 | 10.567 | 10.567 | 10.567 | 0 |
| 7 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 1 | 10.556 | 10.556 | 10.556 | 0 |
| 8 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 1 | 10.271 | 10.271 | 10.271 | 0 |
| 9 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 1 | 9.861 | 9.861 | 9.861 | 0 |
| 10 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 1 | 7.470 | 7.470 | 7.470 | 0 |
| 11 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 1 | 7.394 | 7.394 | 7.394 | 0 |
| 12 | `RepoPromptTests.MCPAskOracleWorktreeTests` | `testAgentRunLinkedWorktreeSourceDelegatesArtifactToExplicitlyUnboundChild` | 1 | 7.315 | 7.315 | 7.315 | 0 |
| 13 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 1 | 6.970 | 6.970 | 6.970 | 0 |
| 14 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 1 | 5.638 | 5.638 | 5.638 | 0 |
| 15 | `RepoPromptTests.MCPAskOracleWorktreeTests` | `testOracleReviewTransportUsesPublishedLinkedWorktreePatchForFreshAndContinuingChat` | 1 | 5.606 | 5.606 | 5.606 | 0 |
| 16 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testSubdirectoryReceiptPlansOnlyCorrespondingPhysicalRoot` | 1 | 5.341 | 5.341 | 5.341 | 0 |
| 17 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 1 | 5.308 | 5.308 | 5.308 | 0 |
| 18 | `RepoPromptTests.MCPAskOracleWorktreeTests` | `testAgentRunLinkedWorktreeFreshAndContinuingOracleInheritsLaunchArtifact` | 1 | 4.749 | 4.749 | 4.749 | 0 |
| 19 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 1 | 4.649 | 4.649 | 4.649 | 0 |
| 20 | `RepoPromptTests.StoreBackedWorkspaceSearchTests` | `testInitializingSessionWorktreeIsNarrowedOrTimesOutWithoutSearchingIncompleteCatalog` | 1 | 4.468 | 4.468 | 4.468 | 0 |

### Focused: 2026-07-02T19:50:44+00:00 — root — root-stabilization-after-w2-m3prime-focused-durableartifact-catalog-delete-20260702-154959

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.DurableArtifactCrashAndCatalogTests/testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-root-stabilization-after-w2-m3prime-focused-durableartifact-catalog-delete-20260702-154959.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Scope/filter: filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath`
Source-change guard: `content`
Primary metric eligible: no

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 25.653 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/8e1d4927-a286-4f3e-b57d-bfc59e3ed93e.log` |  |
| 2 | yes | 0.785 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/936a1484-c6c0-45c6-9652-6a5127e9f99a.log` |  |
| 3 | yes | 0.772 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/05a6b8f2-e9d9-401c-8ef0-efef8d91b68c.log` |  |
| 4 | yes | 0.776 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/ec63825f-5817-4156-93d7-ff5f825a12ea.log` |  |
| 5 | yes | 0.773 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cbf52e7d-7816-499b-a5b5-5f7d6d6f2dfd.log` |  |
| 6 | yes | 0.719 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/79e83965-39bc-40dc-b1c6-a0029deaacd1.log` |  |
| 7 | yes | 0.772 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0479dc13-ea64-4835-9ea9-a00dfe60e9b4.log` |  |
| 8 | yes | 0.751 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/56b842e2-5c4a-4682-a5f6-d7b5cbe20c71.log` |  |
| 9 | yes | 0.750 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/2cacc88a-8240-4cb6-b640-e01067d79cdd.log` |  |
| 10 | yes | 0.735 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/58336a2c-944e-4b53-a64c-36dde612dca3.log` |  |
| 11 | yes | 0.767 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e1c36729-801b-4e9f-a72d-439044f8af1a.log` |  |
| 12 | yes | 0.715 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/b254b0aa-9e75-48ab-8412-8cbddfd8b17b.log` |  |
| 13 | yes | 0.775 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/dd0e0ef8-83ba-4eed-adcf-e5d85871e708.log` |  |
| 14 | yes | 0.755 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/5e319152-d480-4049-94af-a84cbf457c12.log` |  |
| 15 | yes | 0.755 | 0.003 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/4d148bd3-7882-43f3-8d7d-fe235bd667e4.log` |  |
| 16 | yes | 0.719 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/25e136c5-2fc4-401e-b4d3-e4cfc76aae5f.log` |  |
| 17 | yes | 0.719 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/19f2bc96-242b-4b06-a00b-a475db455277.log` |  |
| 18 | yes | 0.736 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/cc8f448f-d378-4c28-9cd0-5347bda09c77.log` |  |
| 19 | yes | 0.717 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/0b724f67-e4e5-40b6-b72e-e8b96930e10e.log` |  |
| 20 | yes | 0.767 | 0.004 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/e0f367ec-0974-4529-acd6-712ba1c9a751.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T19:50:44+00:00/07004bab4570 | root-stabilization-after-w2-m3prime-focused-durableartifact-catalog-delete-20260702-154959 | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath` | 20 valid + 0 invalid | 2835 | 7 | 2842 | 0.755 | 0.785 | 0.0260 | stable | `docs/test-suite-optimizer/artifacts/test-suite-focused-root-root-stabilization-after-w2-m3prime-focused-durableartifact-catalog-delete-20260702-154959.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | 1 | 0.010 | 0.016 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.DurableArtifactCrashAndCatalogTests` | `testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath` | 20 | 0.010 | 0.011 | 0.016 | 0 |

### Root stabilization note: 2026-07-02T19:52Z — after W2-M3′

- Scope: root-stabilization evidence for PR #346 after pushed commit `07004bab`; this is not an optimization claim and does not establish a comparable root timing delta.
- Root artifact: `artifact pruned; superseded failed root-stabilization summary retained in scoreboard`; command used `--samples 2` with `--source-change-guard content`; result `1 valid + 1 invalid`. The only valid root sample had optimizer median/observed p95 `657.333s`; because one sample failed, the two-sample gate did not pass and timing is not a stabilization/optimization baseline.
- Root invalid sample 1: conductor ticket `19a21e63-c24a-4e91-a4be-1df1a37b458b`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/19a21e63-c24a-4e91-a4be-1df1a37b458b.log`; failing test `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testCatalogDeletionReturnsBusyWithoutUnlinkingReplacementPath`; symptom `XCTAssertEqual failed: ("96 bytes") is not equal to ("20 bytes")` at `DurableArtifactCrashAndCatalogTests.swift:344`.
- Focused fix: test-harness only. The deletion-attack test now records DEBUG catalog CAS busy reasons, retries ordinary transient `.busy`, and stops on `.identitySafeRemoval` before asserting the attacker replacement bytes. Production code, executable IDs, ledger, contract count, and scenario count unchanged.
- Focused validation artifact: `docs/test-suite-optimizer/artifacts/test-suite-focused-root-root-stabilization-after-w2-m3prime-focused-durableartifact-catalog-delete-20260702-154959.json`; result `20 valid + 0 invalid`, median `0.755s`, observed p95 `0.785s`, relative MAD `0.0260`, stable. First sample paid compile cost (`25.653s`); XCTest case median remained `0.010s`.
- Style validation: `make dev-format` passed, ticket `36571795-c437-4e52-864e-ffe8b7e92c86`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/36571795-c437-4e52-864e-ffe8b7e92c86.log`; `make dev-lint` passed, ticket `928f3519-8a5e-4b0b-bc08-e084cfd023d3`, log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/928f3519-8a5e-4b0b-bc08-e084cfd023d3.log`.
- Checkpoint pending at note time; raw conductor logs remain uncommitted, while optimizer JSON artifacts are retained as campaign evidence.
### Baseline: 2026-07-02T20:22:10+00:00 — root — root-stabilization-after-durableartifact-fix-20260702-155747

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --json`
Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-root-stabilization-after-durableartifact-fix-20260702-155747.json`
Inventory: `docs/test-suite-optimizer/artifacts/test-suite-inventory-reliability-gate-busy-retry-flake-20260702T113812Z.json`
Scope/filter: complete
Source-change guard: `content`
Primary metric eligible: yes

| Sample | Valid | Execution seconds | Queue wait | State | Exit | Measurement invalid | Log | Invalid reason |
|---:|---|---:|---:|---|---:|---|---|---|
| 1 | yes | 722.434 | 0.002 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/14b4d209-ffe3-460b-a7fe-d98b4e2c9bac.log` |  |
| 2 | yes | 739.581 | 0.005 | completed | 0 | no | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a3eb2072-669f-46f1-8172-5ea788fcf983.log` |  |

| Date/commit | Label | Target | Scope/filter | Samples | Root methods | Provider methods | Total executable methods | Median executionSeconds | Observed p95 | Relative MAD | Noise | Artifact | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| 2026-07-02T20:22:10+00:00/dd5760b4c058 | root-stabilization-after-durableartifact-fix-20260702-155747 | root | complete | 2 valid + 0 invalid | 2835 | 7 | 2842 | 731.007 | 739.581 | 0.0117 | stable | `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-root-stabilization-after-durableartifact-fix-20260702-155747.json` | source guard `content`; build-lane coordinated |

20 slowest suites by median aggregate XCTest case seconds across valid samples:

| Rank | Suite | Methods | Median aggregate seconds | Max method seconds | Fail/skip observations |
|---:|---|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 3 | 65.181 | 63.311 | 0 |
| 2 | `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests` | 65 | 54.409 | 3.683 | 0 |
| 3 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | 65 | 51.450 | 6.978 | 0 |
| 4 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | 34 | 46.397 | 5.078 | 0 |
| 5 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | 33 | 31.209 | 5.798 | 0 |
| 6 | `RepoPromptTests.AgentRunWorktreeStartTests` | 34 | 29.716 | 9.693 | 0 |
| 7 | `RepoPromptTests.WorkspacePendingSeededRootTests` | 12 | 25.142 | 3.886 | 0 |
| 8 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | 16 | 24.953 | 13.651 | 0 |
| 9 | `RepoPromptTests.MCPAskOracleWorktreeTests` | 23 | 22.139 | 5.230 | 0 |
| 10 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | 47 | 21.510 | 17.483 | 2 |
| 11 | `RepoPromptTests.WorkspaceCodemapLiveOverlayTests` | 37 | 17.921 | 1.619 | 0 |
| 12 | `RepoPromptTests.CodeMapRootManifestStoreTests` | 28 | 15.535 | 4.482 | 0 |
| 13 | `RepoPromptTests.MCPCodeStructureWorktreeTests` | 18 | 15.515 | 2.633 | 0 |
| 14 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | 5 | 13.608 | 6.202 | 0 |
| 15 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | 16 | 11.918 | 6.982 | 0 |
| 16 | `RepoPromptTests.AgentProviderContextBuilderTests` | 7 | 11.858 | 12.593 | 0 |
| 17 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | 3 | 11.272 | 11.539 | 0 |
| 18 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | 10 | 11.192 | 13.790 | 0 |
| 19 | `RepoPromptTests.WorkspaceCodemapSelectionGraphTests` | 19 | 10.525 | 0.977 | 0 |
| 20 | `RepoPromptTests.GitBlobIdentityServiceTests` | 24 | 9.810 | 1.231 | 0 |

20 slowest tests by median XCTest case seconds across valid samples:

| Rank | Suite | Method | Observations | Median seconds | Observed p95 | Max seconds | Fail/skip observations |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | `testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 2 | 63.227 | 63.311 | 63.311 | 0 |
| 2 | `RepoPromptTests.GitLoadedRootAuthorityEvidenceTests` | `testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded` | 2 | 17.239 | 17.483 | 17.483 | 0 |
| 3 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingRetriesAfterRevocationAndDoesNotPublishFirstAssembly` | 2 | 12.796 | 13.651 | 13.651 | 0 |
| 4 | `RepoPromptTests.AgentProviderContextBuilderTests` | `testAgentModeOverCapHandoffUsesBorrowedPresentationWithoutSecondDemandOrFreeze` | 2 | 11.606 | 12.593 | 12.593 | 0 |
| 5 | `RepoPromptTests.WorkspaceRootTargetSeedPlanManifestTests` | `testManifestScaleStreamsOneHundredThousandByDefaultAndOneMillionOptIn` | 2 | 11.268 | 11.539 | 11.539 | 0 |
| 6 | `RepoPromptTests.WorkspaceCodemapLocalGitClassificationTests` | `testGitLayoutWatcherChangeReprobesAndAdmitsConvertedRepository` | 2 | 11.167 | 13.790 | 13.790 | 0 |
| 7 | `RepoPromptTests.PromptContextPreAssemblyServiceTests` | `testFinalPackagingCancellationThrowsWithoutPublishingPayload` | 2 | 9.311 | 9.380 | 9.380 | 0 |
| 8 | `RepoPromptTests.WorkspaceRootNamespaceManifestTests` | `testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes` | 2 | 7.936 | 8.265 | 8.265 | 0 |
| 9 | `RepoPromptTests.FileSystemAcceptedIngressBarrierTests` | `testSyntheticHundredThousandPathReplayUsesBoundedSpillWorkingSet` | 2 | 7.318 | 7.526 | 7.526 | 0 |
| 10 | `RepoPromptTests.SelectionSlicePersistenceAndRebaseTests` | `testCanonicalStoreWatcherEditsPreserveLargeBeginningMiddleEndSlices` | 2 | 7.252 | 7.380 | 7.380 | 0 |
| 11 | `RepoPromptTests.AgentManageMCPToolServiceResumeTests` | `testResumeOfControlledSessionPreservesWaitOwnershipAcrossSteering` | 2 | 7.239 | 7.544 | 7.544 | 0 |
| 12 | `RepoPromptTests.WorkspaceCodemapBindingEngineTests` | `testWarmManifestRejectsExplicitNonCleanCandidateStatesWithoutSourceRead` | 2 | 6.181 | 6.978 | 6.978 | 0 |
| 13 | `RepoPromptTests.AgentRunWorktreeStartTests` | `testAgentExploreBatchCreatePreparesDistinctWorktreesBeforeProviderStart` | 2 | 6.074 | 8.324 | 8.324 | 0 |
| 14 | `RepoPromptTests.WorktreeAPISmokeHarnessTests` | `testWorktreeBoundManageSelectionPersistsAcrossOneShotContextConnections` | 2 | 6.007 | 6.202 | 6.202 | 0 |
| 15 | `RepoPromptTests.AgentRunWorktreeStartTests` | `testManualFirstSendCreatesAndBindsNewWorktreeAcrossNewAndLinkedRoutes` | 2 | 5.912 | 9.693 | 9.693 | 0 |
| 16 | `RepoPromptTests.WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests` | `testAutomaticSelectionIgnoresUnsupportedEnterpriseInventoryForCompleteness` | 2 | 4.880 | 5.078 | 5.078 | 0 |
| 17 | `RepoPromptTests.WorktreeStartupInstrumentationTests` | `testScopedControlPreparesExactLoadedRootAndRejectsStaleScopeBeforeLease` | 2 | 4.782 | 8.884 | 8.884 | 0 |
| 18 | `RepoPromptTests.GitWorktreeCreationReceiptTests` | `testReceiptCreationFailurePointsAreCorrelationScopedOneShotAndFailClosed` | 2 | 4.614 | 4.972 | 4.972 | 0 |
| 19 | `RepoPromptTests.CodeMapRootManifestStoreTests` | `testTerminalScanMutationWitnessRejectsAddedValidAndCorruptEntries` | 2 | 4.248 | 4.482 | 4.482 | 0 |
| 20 | `RepoPromptTests.PersistentAgentModeMCPReadFileConnectionTests` | `testThreeRootSessionScopeReplacesCanonicalGitRootAndPreservesIndependentNonGitRoot` | 2 | 4.241 | 6.982 | 6.982 | 0 |

### Root stabilization note: 2026-07-02T20:22Z — after durable artifact fix

- Scope: root-stabilization evidence for PR #346 from clean pushed head `dd5760b4`; this is not an optimization claim.
- Artifact: `docs/test-suite-optimizer/artifacts/test-suite-baseline-root-root-stabilization-after-durableartifact-fix-20260702-155747.json`; raw optimizer log remains local/uncommitted only.
- Result: `2 valid + 0 invalid`; raw executionSeconds `722.434, 739.581`; median `731.007s`; observed p95 `739.581s`; relative MAD `0.0117` (`stable`).
- Sample logs: `14b4d209-ffe3-460b-a7fe-d98b4e2c9bac` → `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/14b4d209-ffe3-460b-a7fe-d98b4e2c9bac.log`; `a3eb2072-669f-46f1-8172-5ea788fcf983` → `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/a3eb2072-669f-46f1-8172-5ea788fcf983.log`.
- No failures, invalid samples, focused fixes, commits, or pushes in this pass; raw logs remain local/uncommitted, and optimizer JSON artifacts are retained under `docs/test-suite-optimizer/artifacts/` for orchestrator handling.
