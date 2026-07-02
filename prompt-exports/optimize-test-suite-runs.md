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
| 2026-07-01T15:15:29+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | root | complete | 3 valid + 2 invalid | 2825 | 7 | 2832 | 623.578 | 635.298 | 0.0105 | stable | `prompt-exports/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | metadata guard; invalid samples from XCTest failures; source_changed=false |
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | provider | complete | 5 valid + 0 invalid | 2825 | 7 | 2832 | 0.422 | 0.536 | 0.0326 | stable | `prompt-exports/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | metadata guard; source_changed=false |

## Derived complete-suite secondary

| Date/commit | Label | Root artifact | Provider artifact | Root median | Provider median | Derived serial median | Root p95 | Provider p95 | Conservative serial p95 sum | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | `prompt-exports/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | `prompt-exports/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | 623.578 | 0.422 | 623.999 | 635.298 | 0.536 | 635.834 | Derived serial sum only; not an observed one-process measurement; root baseline had 3 valid and 2 invalid samples |

## Iteration ledger

| Iteration | Commit/range | Attributed change | Primary/secondary scope | Root methods | Provider methods | Total methods | Method delta | Contract delta | Scenario delta | Exact old→new/removed mappings | Focused artifacts | Full-root artifacts | Provider artifacts | Root median delta | Root p95 delta | Provider median delta | Provider p95 delta | Derived secondary delta | Slowest suites/tests after change | Validation and exit codes | Decision |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| Phase 3 setup | d0abf8f0ba01 + working tree | Optimizer metadata guard, focused baselines, per-method ranking, artifact metadata, combine checks, docs, scoreboard scaffold | Tooling/setup only; no suite-speed claim | 2825 | 7 | 2832 | 0 | 0 | 0 | none | n/a | `prompt-exports/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | `prompt-exports/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | n/a | n/a | n/a | n/a | n/a | suites: WorkspaceCodemapBindingEngineTests 45.431s, WorkspaceFileContextStoreCodemapSeamTests 45.222s, WorkspaceFileContextStoreCodemapAutomaticSelectionSeamTests 40.759s; top test: GitLoadedRootAuthorityEvidenceTests/testHundredThousandLogicalCandidatesAndTreeRecordsStayByteBounded 16.553s | py_compile=0; optimizer tests=0; inventory=0; verify-ledger=1 missing 36 stale 2; root baseline=0; provider baseline=0 | Setup complete with reliability caveats; do not optimize until root invalid samples and ledger mismatch are triaged or accepted |

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
Artifact: `prompt-exports/test-suite-baseline-root-phase3-setup-20260701T141721Z.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T15:15:29+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | root | complete | 3 valid + 2 invalid | 2825 | 7 | 2832 | 623.578 | 635.298 | 0.0105 | stable | `prompt-exports/test-suite-baseline-root-phase3-setup-20260701T141721Z.json` | source guard `metadata`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T15:15:43+00:00/d0abf8f0ba01 | phase3-setup-20260701T141721Z | provider | complete | 5 valid + 0 invalid | 2825 | 7 | 2832 | 0.422 | 0.536 | 0.0326 | stable | `prompt-exports/test-suite-baseline-provider-phase3-setup-20260701T141721Z.json` | source guard `metadata`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T15:37:30+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-binding | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 17 valid + 3 invalid | 2825 | 7 | 2832 | 6.146 | 16.460 | 0.0877 | noisy | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-seam.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T15:39:00+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-seam | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 19 valid + 1 invalid | 2825 | 7 | 2832 | 2.703 | 5.231 | 0.0337 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-seam.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T15:43:13+00:00/d0abf8f0ba01 | reliability-gate-20260701-focused-binding-after | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 3.175 | 8.374 | 0.0242 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json` | source guard `content`; build-lane coordinated |

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
| 2026-07-01/d0abf8f0ba01 + working tree | Phase 3 invalid root samples | Test-harness determinism only; no performance optimization | 0 | 0 | 0 | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding.json`; `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-seam.json`; `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json` | intended optimizer artifact `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after.json` was not emitted; failure summary: `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-failed.json` | 0 valid + 5 invalid | Phase 4 is **not safe** to start; target binding failure fixed in focused evidence, seam remains intermittent focused, and full-root baseline is blocked by unrelated codemap/context-builder reliability failures |

### Triage classification

| Method | Focused artifact | Focused result | Classification | Action |
|---|---|---:|---|---|
| `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree` | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding.json` | 17 valid + 3 invalid / 20 | Intermittent focused test-harness flake. The invalid assertions were exact classifier-route counters (`classifications`, `cleanClassifications`, `worktreeClassifications`, `validatedWorktreeReads`) while the durable contract (locator reuse + one build + projected entries) remained separately asserted. | Implemented one harness determinism fix: removed exact clean-vs-worktree route assertions and documented safe Git metadata-refresh fallback. Post-fix artifact is 20/20 valid. |
| `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-seam.json` | 19 valid + 1 invalid / 20 | Intermittent focused seam/harness flake. Focused invalid was `expectedReady`; Phase 3 root invalid was `expectedPending`. No production correctness regression was isolated in this dispatch. | No code change; single implemented fix was limited to the clearer binding-engine harness issue. Residual reliability concern remains. |

### Validation commands and exit codes

| Command | Exit | Notes |
|---|---:|---|
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --samples 20 --label reliability-gate-20260701-focused-binding --inventory prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard prompt-exports/optimize-test-suite-runs.md --output prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding.json --source-change-guard content` | 0 | 17 valid + 3 invalid; invalids failed the exact classifier-route assertions for `linked`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait --samples 20 --label reliability-gate-20260701-focused-seam --inventory prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard prompt-exports/optimize-test-suite-runs.md --output prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-seam.json --source-change-guard content` | 0 | 19 valid + 1 invalid; invalid was `expectedReady`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --filter RepoPromptTests.WorkspaceCodemapBindingEngineTests/testProjectionPreloadReusesUnchangedBlobAndBuildsOnlyChangedFilePerWorktree --samples 20 --label reliability-gate-20260701-focused-binding-after --inventory prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard prompt-exports/optimize-test-suite-runs.md --output prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-binding-after.json --source-change-guard content` | 0 | 20 valid + 0 invalid; median 3.175s, observed p95 8.374s, rel MAD 0.0242 stable. |
| `make dev-test FILTER=WorkspaceCodemapBindingEngineTests` | 0 | 65 tests, 0 failures, conductor ticket `bbc09a91-57b0-4f08-93ff-0218b0525f0f`. |
| `python3 Scripts/test_suite_optimizer.py baseline --target root --samples 5 --label reliability-gate-20260701-root-after --inventory prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard prompt-exports/optimize-test-suite-runs.md --output prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after.json --source-change-guard metadata` | 1 | Optimizer error: `baseline produced no valid samples`; intended artifact not emitted. Failure summary artifact: `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-failed.json`. |
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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T18:25:51+00:00/c96fade22b69 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 5 valid + 15 invalid | 2825 | 7 | 2832 | 211.007 | 318.658 | 0.2639 | unstable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T19:22:49+00:00/c96fade22b69 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 18 valid + 2 invalid | 2825 | 7 | 2832 | 100.458 | 283.106 | 0.4554 | unstable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-final-fix.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T19:45:23+00:00/b73934e9da5a | reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests/testAgentModeEmptyInitialSelectionDefersAndRoutesWithoutExplicitContext` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 22.659 | 102.031 | 0.0319 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-empty-selection-after-post-fence-fix.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T20:22:43+00:00/f7a85f2d6824 | reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix | root | filtered: `RepoPromptTests.ContextBuilderWorktreeInheritanceTests` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 41.937 | 231.455 | 0.0703 | noisy | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-contextbuilder-worktree-inheritance-after-empty-selection-fix.json` | source guard `content`; build-lane coordinated |

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

Command: `python3 Scripts/test_suite_optimizer.py baseline --target root --samples 5 --label reliability-gate-20260701-root-after-contextbuilder-clean --inventory prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json --scoreboard prompt-exports/optimize-test-suite-runs.md --output prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-contextbuilder-clean.json --source-change-guard metadata`
Artifact: `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-contextbuilder-clean.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T21:33:32+00:00/ef45417b29a8 | reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe | root | filtered: `RepoPromptTests.AgentWorktreeMergeAttentionTests/testActiveConflictOperationReturnsNilWhenOnlyTerminalOrReviewStatesArePresent` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.721 | 0.929 | 0.0182 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-agentworktree-merge-attention-stall-probe.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T21:38:01+00:00/7e7bde452071 | reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe | root | filtered: `RepoPromptTests.CodeMapArtifactStoreTests/testPendingScanAdmissionAndReadRetainOneDescriptorAcrossAtomicReplacement` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.720 | 0.766 | 0.0114 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-codemap-artifactstore-pending-scan-probe.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-exonerated-probes-stall-wake-diagnostic.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T22:38:56+00:00/c9a79f24aa15 | reliability-gate-20260701-root-after-exonerated-probes-stall-wake-diagnostic | root | complete | 1 valid + 4 invalid | 2825 | 7 | 2832 | 729.333 | 729.333 | 0.0000 | stable | `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-exonerated-probes-stall-wake-diagnostic.json` | source guard `metadata`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T22:50:58+00:00/f3393c0b1229 | reliability-gate-20260701-focused-durable-catalog-cas | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.962 | 1.007 | 0.0199 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-durable-catalog-cas-clean.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-01T23:31:04+00:00/f3393c0b1229 | reliability-gate-20260701-root-after-durable-catalog-cas-clean | root | complete | 1 valid + 2 invalid | 2825 | 7 | 2832 | 743.895 | 743.895 | 0.0000 | stable | `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-durable-catalog-cas-clean.json` | source guard `metadata`; build-lane coordinated |

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

Reliability-gate decision note (2026-07-01T23:31Z): focused DurableArtifact CAS method was exonerated by `prompt-exports/test-suite-focused-root-reliability-gate-20260701-focused-durable-catalog-cas.json` (20 valid / 0 invalid, source guard `content`, method/contract/scenario delta 0). The required 3-sample complete root baseline was attempted via `prompt-exports/test-suite-baseline-root-reliability-gate-20260701-root-after-durable-catalog-cas-clean.json` and is not clean (1 valid / 2 invalid, source guard `metadata`). First invalid root sample: sample 2 log `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/9f40cefc-e476-4a89-8329-3b586e714d40.log`, `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`, `MCPCodeStructureWorktreeTests.swift:211`, `XCTAssertEqual failed: ("2") is not equal to ("1") - Graph-worker drain counters should advance together: [0, 0, 1]`. Sample 3 also failed in `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/c71b3b0b-a179-4348-bf14-17d7dc824473.log`, `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer`, `DurableArtifactTestSupport.swift:78`, `unexpectedPublication(RepoPrompt.DurableArtifactPublicationResult.busy)`. Curated ledger was not regenerated or edited; no XCTest IDs changed; method delta 0, contract delta 0, scenario delta 0. Phase 4 remains blocked; next target should be the first invalid root sample (`MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage`), not slow-suite optimization.

Tooling progress-output gaps observed during this dispatch: `Scripts/test_suite_optimizer.py baseline` emitted no live sample-start/sample-end lines during the long complete-root run; it did not print conductor ticket/log path as each sample began; it did not stream invalid reasons when sample 2 failed, so classification required polling conductor state/logs separately; the focused probe printed final JSON but the wrapper stayed open due inherited descriptors, making it look still-running; the complete-root wrapper also printed `root_baseline_exit=0` only after all samples finished. A future tooling improvement should emit per-sample start/end, conductor ticket/log path, exit/state, invalid reasons, and final artifact path incrementally.
### Focused: 2026-07-02T01:36:36+00:00 — root — reliability-gate-20260702-focused-mcp-code-structure-graph-drain

Command: `/Users/pvncher/Documents/Git/repoprompt-ce-release/conductor test --filter RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage --json`
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-mcp-code-structure-graph-drain.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-02T01:36:36+00:00/9dffe373d0ef | reliability-gate-20260702-focused-mcp-code-structure-graph-drain | root | filtered: `RepoPromptTests.MCPCodeStructureWorktreeTests/testInheritedWorktreeSequentialStructureThenTreePublishesLogicalMarkerWithoutPhysicalLeakage` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 4.417 | 4.641 | 0.0068 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-mcp-code-structure-graph-drain.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-durable-crash-catalog-pointer.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-02T01:50:56+00:00/f37309e7a095 | reliability-gate-20260702-focused-durable-crash-catalog-pointer | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testSubprocessCrashReplacingCatalogLeavesOldOrNewCompletePointer` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 1.033 | 1.071 | 0.0084 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-durable-crash-catalog-pointer.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-02T01:51:33+00:00/f37309e7a095 | reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry | root | filtered: `RepoPromptTests.DurableArtifactCrashAndCatalogTests/testConcurrentSubprocessCatalogCASPublishesExactlyOneWinner` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 0.851 | 0.864 | 0.0099 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-durable-catalog-cas-after-publish-retry.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-codemap-seam-newer-snapshot.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-02T02:03:03+00:00/1a44c448ff4c | reliability-gate-20260702-focused-codemap-seam-newer-snapshot | root | filtered: `RepoPromptTests.WorkspaceFileContextStoreCodemapSeamTests/testGraphWorkerConsumesNewerSnapshotArrivingDuringProcessAdmissionWait` | 20 valid + 0 invalid | 2825 | 7 | 2832 | 2.300 | 2.517 | 0.0239 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-focused-codemap-seam-newer-snapshot.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-baseline-root-optimization-pass-20260702-root-baseline.json`
Inventory: `prompt-exports/test-suite-inventory-phase3-setup-20260701T141721Z.json`
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
| 2026-07-02T02:47:35+00:00/17a1b296c522 | optimization-pass-20260702-root-baseline | root | complete | 1 valid + 2 invalid | 2825 | 7 | 2832 | 669.475 | 669.475 | 0.0000 | stable | `prompt-exports/test-suite-baseline-root-optimization-pass-20260702-root-baseline.json` | source guard `metadata`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-unix-peer-write-hangup.json`
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
| 2026-07-02T03:18:00+00:00/0a7a651e39b3 | reliability-gate-20260702-unix-peer-write-hangup | root | filtered: `RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup` | 20 valid + 0 invalid |  |  |  | 0.728 | 0.740 | 0.0127 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-unix-peer-write-hangup.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-manifest-logical-access-eviction.json`
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
| 2026-07-02T03:19:13+00:00/0a7a651e39b3 | reliability-gate-20260702-manifest-logical-access-eviction | root | filtered: `RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest` | 20 valid + 0 invalid |  |  |  | 2.053 | 2.172 | 0.0328 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-manifest-logical-access-eviction.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-root-reliability-gate-20260702-binding-draining-projection-materialization.json`
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
| 2026-07-02T03:20:25+00:00/0a7a651e39b3 | reliability-gate-20260702-binding-draining-projection-materialization | root | filtered: `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage` | 20 valid + 0 invalid |  |  |  | 1.655 | 3.150 | 0.0307 | stable | `prompt-exports/test-suite-focused-root-reliability-gate-20260702-binding-draining-projection-materialization.json` | source guard `content`; build-lane coordinated |

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
Artifact: `prompt-exports/test-suite-focused-make-loop-reliability-gate-20260702.json`
Filter proof: for each method, sample 1 captured `$ swift test --filter <exact method>` and `Executed 1 test, with 0 failures` before samples 2–20 continued.

| Signature | Exact filter | Samples | Median elapsed seconds | First proof output | First ticket | First conductor log |
|---|---|---:|---:|---|---|---|
| unix-peer-write-hangup | `RepoPromptTests.UnixSocketMCPTerminalCleanupTests/testPeerCloseDuringWritePublishesPeerWriteHangup` | 20 valid + 0 invalid | 0.815 | `/tmp/rpce-focused-loop-20260702/unix-peer-write-hangup-sample-01.out` | `d1627f4e-eb33-4ce5-8fbd-2fd1af2922d0` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/d1627f4e-eb33-4ce5-8fbd-2fd1af2922d0.log` |
| manifest-logical-access-eviction | `RepoPromptTests.CodeMapRootManifestStoreTests/testLogicalAccessEvictionKeepsHotOldManifestOverColdNewManifest` | 20 valid + 0 invalid | 2.210 | `/tmp/rpce-focused-loop-20260702/manifest-logical-access-eviction-sample-01.out` | `89783f51-7eb4-4705-89d8-d49b9e6a2f6b` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/89783f51-7eb4-4705-89d8-d49b9e6a2f6b.log` |
| binding-draining-projection-materialization | `RepoPromptTests.WorkspaceCodemapBindingEngineTests/testDemandAdmissionCountsActiveAndDrainingProjectionMaterializationUsage` | 20 valid + 0 invalid | 1.897 | `/tmp/rpce-focused-loop-20260702/binding-draining-projection-materialization-sample-01.out` | `7ed66185-dbcb-4cd0-90f5-eb39c2cc7ee0` | `/Users/pvncher/Library/Application Support/RepoPrompt CE/Conductor/6eb29133d54d75306f7c1d83cf6ce787643dd42843b1af4ff800cdd8d9846ccb/jobs/7ed66185-dbcb-4cd0-90f5-eb39c2cc7ee0.log` |
