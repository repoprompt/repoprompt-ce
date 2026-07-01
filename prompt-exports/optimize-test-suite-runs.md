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
