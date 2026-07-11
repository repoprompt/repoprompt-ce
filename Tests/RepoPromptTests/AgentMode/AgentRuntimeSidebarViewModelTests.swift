import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentRuntimeSidebarViewModelTests: XCTestCase {
    func testStaleLiveZeroDoesNotMaskNewerManageSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)

        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)
    }

    func testUnavailableSelectionCountDoesNotReusePreviousContextCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertNil(store.runtimeVM.snapshot.selectionFileCount)
    }

    func testNewerManageSelectionWinsOverOlderWorkspaceContextSelectionCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let olderWorkspaceContext = try makeWorkspaceContextItem(
            fileCount: 0,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let newerManageSelection = try makeManageSelectionItem(
            fileCount: 8,
            timestamp: Date(timeIntervalSince1970: 200)
        )

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(
                latestWorkspaceContextItem: olderWorkspaceContext,
                latestManageSelectionItem: newerManageSelection
            ),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 8)
        XCTAssertEqual(store.runtimeVM.snapshot.selectionTokens, 80)
    }

    func testFreshLiveZeroRemainsAuthoritativeAfterToolDerivedCount() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        let snapshot = AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem)
        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 3)

        store.update(
            transcriptSnapshot: snapshot,
            codexUsage: nil,
            liveSelectedFileCount: 0,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 0)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testLiveSelectionCountMismatchSuppressesStaleToolSelectionTokens() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 3)
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: 2,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 2)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testLiveSlicedSelectionSuppressesSameCountToolSelectionTokens() throws {
        let store = AgentRuntimeMetricsUIStore()
        let manageSelectionItem = try makeManageSelectionItem(fileCount: 1)
        let liveSummary = AgentContextExportResolver.selectionSummary(
            for: StoredSelection(
                selectedPaths: ["Sources/File0.swift"],
                slices: ["Sources/File0.swift": [LineRange(start: 4, end: 8)]],
                codemapAutoEnabled: false
            )
        )
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(latestManageSelectionItem: manageSelectionItem),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            liveSelectionSummary: liveSummary,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.selectionFileCount, 1)
        XCTAssertEqual(store.runtimeVM.snapshot.selectionSummary, liveSummary)
        XCTAssertNil(store.runtimeVM.snapshot.selectionTokens)
    }

    func testClaudeFableSelectionFallsBackToOneMillionTokenContextWindow() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )

        XCTAssertNil(store.runtimeVM.snapshot.contextWindowTokens)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)
    }

    func testEncodedClaudeEffortSelectionResolvesContextWindowFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "opus[1m]:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:max"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "sonnet:high"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testGLMSlotSelectionsUseBackendContextWindowFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "sonnet"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "sonnet:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "opus:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "haiku"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testCustomSlotMappingUsesBackendContextWindowFallback() {
        let restore = installTemporaryCustomSlotMapping()
        defer { restore() }

        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .customClaudeCompatible,
            selectedModelRaw: "sonnet:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .customClaudeCompatible,
            selectedModelRaw: "haiku"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .kimiCode,
            selectedModelRaw: "kimi-code:xhigh"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testProviderReportedContextWindowWinsOverModelFallback() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 250_000,
                lastTotalTokens: 1000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.contextWindowTokens, 250_000)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 250_000)
    }

    func testConfiguredWindowBelowCanonicalUsesConfiguredDenominatorAndExposesCanonical() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 1_000_000,
                configuredContextWindow: 400_000,
                lastTotalTokens: 100_000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.contextWindowTokens, 1_000_000)
        XCTAssertEqual(store.runtimeVM.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(store.runtimeVM.snapshot.canonicalContextWindowTokens, 1_000_000)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 400_000)
    }

    func testConfiguredWindowAboveCanonicalCapsAtCanonicalDenominator() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 200_000,
                configuredContextWindow: 400_000,
                lastTotalTokens: 100_000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "sonnet"
        )

        XCTAssertEqual(store.runtimeVM.snapshot.contextWindowTokens, 200_000)
        XCTAssertEqual(store.runtimeVM.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(store.runtimeVM.snapshot.canonicalContextWindowTokens, 200_000)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testConfiguredOnlyUsesRawConfiguredDenominatorWhenCanonicalIsNil() {
        let viewModel = AgentRuntimeSidebarViewModel()
        viewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: nil,
                configuredContextWindow: 350_000,
                lastTotalTokens: 100_000,
                totalTotalTokens: nil
            )
        )

        XCTAssertNil(viewModel.snapshot.contextWindowTokens)
        XCTAssertNil(viewModel.snapshot.canonicalContextWindowTokens)
        XCTAssertEqual(viewModel.snapshot.configuredContextWindowTokens, 350_000)
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 350_000)
    }

    func testBothUpdateOverloadsPropagateConfiguredWindowIntoEffectiveDenominator() {
        let usage = AgentContextUsage(
            modelContextWindow: 1_000_000,
            configuredContextWindow: 400_000,
            lastTotalTokens: 100_000,
            totalTotalTokens: nil
        )

        let snapshotViewModel = AgentRuntimeSidebarViewModel()
        snapshotViewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: usage,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )
        XCTAssertEqual(snapshotViewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(snapshotViewModel.snapshot.effectiveContextWindowTokens, 400_000)

        let itemsViewModel = AgentRuntimeSidebarViewModel()
        itemsViewModel.update(
            items: [],
            codexUsage: usage,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )
        XCTAssertEqual(itemsViewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(itemsViewModel.snapshot.effectiveContextWindowTokens, 400_000)
    }

    func testNilConfiguredWindowPreservesExistingCanonicalAndFallbackBehavior() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 250_000,
                lastTotalTokens: 1000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )
        XCTAssertNil(store.runtimeVM.snapshot.configuredContextWindowTokens)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 250_000)

        let fallbackViewModel = AgentRuntimeSidebarViewModel()
        fallbackViewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil
        )
        XCTAssertEqual(fallbackViewModel.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testSessionConfiguredWindowAppliesWhenUsageNilAcrossUpdateOverloads() {
        let snapshotViewModel = AgentRuntimeSidebarViewModel()
        snapshotViewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(snapshotViewModel.snapshot.usageSource, .unavailable)
        XCTAssertEqual(snapshotViewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(snapshotViewModel.snapshot.effectiveContextWindowTokens, 400_000)

        let itemsViewModel = AgentRuntimeSidebarViewModel()
        itemsViewModel.update(
            items: [],
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(itemsViewModel.snapshot.usageSource, .unavailable)
        XCTAssertEqual(itemsViewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(itemsViewModel.snapshot.effectiveContextWindowTokens, 400_000)
    }

    func testUsageConfiguredWindowPrecedesSessionValueAndNilUsageFieldFallsBack() {
        let usageConfiguredViewModel = AgentRuntimeSidebarViewModel()
        usageConfiguredViewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 1_000_000,
                configuredContextWindow: 300_000,
                lastTotalTokens: 10000,
                totalTotalTokens: nil
            ),
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(usageConfiguredViewModel.snapshot.configuredContextWindowTokens, 300_000)
        XCTAssertEqual(usageConfiguredViewModel.snapshot.effectiveContextWindowTokens, 300_000)

        let nilUsageConfiguredViewModel = AgentRuntimeSidebarViewModel()
        let rebuiltUsage = AgentContextUsage(
            modelContextWindow: 1_000_000,
            configuredContextWindow: nil,
            lastTotalTokens: 10000,
            totalTotalTokens: nil
        )
        nilUsageConfiguredViewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: rebuiltUsage,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(nilUsageConfiguredViewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(nilUsageConfiguredViewModel.snapshot.effectiveContextWindowTokens, 400_000)
        XCTAssertNil(rebuiltUsage.configuredContextWindow)
    }

    func testToolDerivedBranchReceivesSessionConfiguredWindow() throws {
        let workspaceContextItem = try makeWorkspaceContextItem(fileCount: 2, tokenStatsTotal: 25000)
        let viewModel = AgentRuntimeSidebarViewModel()
        viewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(latestWorkspaceContextItem: workspaceContextItem),
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )

        XCTAssertEqual(viewModel.snapshot.usageSource, .toolDerived)
        XCTAssertEqual(viewModel.snapshot.usedTokens, 25000)
        XCTAssertEqual(viewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 400_000)
    }

    func testSessionConfiguredWindowDoesNotPublishChurnButNilToValuePublishesOnce() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )
        let firstRevision = store.revision

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5"
        )
        XCTAssertEqual(store.revision, firstRevision)

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(store.revision, firstRevision + 1)
        let configuredRevision = store.revision

        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )
        XCTAssertEqual(store.revision, configuredRevision)
    }

    func testCodexWithoutSessionConfiguredWindowPreservesCanonicalBehavior() {
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.1-codex"
        )

        XCTAssertNil(store.runtimeVM.snapshot.configuredContextWindowTokens)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testSessionValueShadowsProvisionalSidebarFallbackOnlyUnderMatchingKey() throws {
        let viewModel = AgentRuntimeSidebarViewModel()
        viewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            selectedAgent: .claudeCodeGLM,
            selectedModelRaw: "sonnet",
            sessionConfiguredContextWindow: 1_000_000
        )

        XCTAssertEqual(viewModel.snapshot.configuredContextWindowTokens, 1_000_000)
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-key-shadow")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)
        let currentKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        vm.test_storeCachedProvisionalClaudeConfiguredContextWindow(400_000, for: currentKey)

        session.claudeConfiguredContextWindow = 1_000_000
        session.claudeConfiguredContextWindowKey = currentKey
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 1_000_000)

        session.claudeConfiguredContextWindowKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCodeGLM,
            modelRaw: session.selectedModelRaw,
            workspacePath: currentKey.workspacePath
        )
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 400_000)

        session.claudeConfiguredContextWindowKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: session.selectedAgent,
            modelRaw: "claude-sonnet-5",
            workspacePath: currentKey.workspacePath
        )
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 400_000)

        session.claudeConfiguredContextWindowKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: session.selectedAgent,
            modelRaw: session.selectedModelRaw,
            workspacePath: "/tmp/repoprompt-sidebar-other-workspace"
        )
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 400_000)
    }

    func testClaudeConfiguredWindowKeyGatePreventsFamilyTransitionStaleShadow() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-family-transition")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)

        session.selectedAgent = .claudeCodeGLM
        session.selectedModelRaw = "sonnet"
        let glmKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        vm.test_storeCachedProvisionalClaudeConfiguredContextWindow(1_000_000, for: glmKey)
        session.claudeConfiguredContextWindow = 400_000
        session.claudeConfiguredContextWindowKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: .claudeCode,
            modelRaw: "claude-fable-5",
            workspacePath: glmKey.workspacePath
        )
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 1_000_000)

        session.selectedAgent = .customClaudeCompatible
        session.selectedModelRaw = "no-settings-model"
        let customKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        session.claudeConfiguredContextWindow = 1_000_000
        session.claudeConfiguredContextWindowKey = glmKey
        XCTAssertNil(vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: customKey))
        XCTAssertNil(vm.test_sidebarConfiguredContextWindow(for: session))

        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        let workspaceKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        vm.test_storeCachedProvisionalClaudeConfiguredContextWindow(350_000, for: workspaceKey)
        session.claudeConfiguredContextWindow = 400_000
        session.claudeConfiguredContextWindowKey = ClaudeProvisionalContextWindowResolver.Key(
            agentKind: session.selectedAgent,
            modelRaw: session.selectedModelRaw,
            workspacePath: "/tmp/repoprompt-sidebar-old-workspace"
        )
        XCTAssertEqual(vm.test_sidebarConfiguredContextWindow(for: session), 350_000)
    }

    func testSpawnResolvedWindowWritesLaunchKeyWithoutPoisoningCurrentKey() throws {
        let state = try makeDivergedClaudeLaunchKeyState()

        XCTAssertEqual(state.session.claudeConfiguredContextWindowKey, state.launchKey)
        XCTAssertEqual(state.session.claudeConfiguredContextWindow, 400_000)
        XCTAssertEqual(
            state.vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: state.launchKey),
            400_000
        )
        XCTAssertFalse(state.vm.provisionalClaudeContextWindowResolver.hasCachedValue(for: state.currentKey))
        XCTAssertNil(state.vm.test_sidebarConfiguredContextWindow(for: state.session))
    }

    func testSpawnResolvedWindowServesStoredValueAfterRevertingToLaunchKey() throws {
        let state = try makeDivergedClaudeLaunchKeyState()

        state.session.selectedModelRaw = "claude-fable-5"

        XCTAssertEqual(try XCTUnwrap(state.vm.test_provisionalClaudeContextWindowKey(for: state.session)), state.launchKey)
        XCTAssertEqual(state.vm.test_sidebarConfiguredContextWindow(for: state.session), 400_000)
    }

    func testSpawnResolvedWindowMatchedKeyNudgesWithoutSnapshotChurn() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-launch-key-matched")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)
        let launchKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        let initialSyncCount = vm.test_syncRuntimeMetricsCallCount

        vm.syncSpawnResolvedClaudeConfiguredContextWindow(400_000, launchKey: launchKey, for: session)

        XCTAssertEqual(session.claudeConfiguredContextWindowKey, launchKey)
        XCTAssertEqual(session.claudeConfiguredContextWindow, 400_000)
        XCTAssertEqual(
            vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: launchKey),
            400_000
        )
        XCTAssertEqual(vm.test_syncRuntimeMetricsCallCount, initialSyncCount + 1)
        let revisionAfterFirstSync = vm.ui.runtimeMetrics.revision
        let syncCountAfterFirstSync = vm.test_syncRuntimeMetricsCallCount

        vm.syncSpawnResolvedClaudeConfiguredContextWindow(400_000, launchKey: launchKey, for: session)

        XCTAssertEqual(vm.test_syncRuntimeMetricsCallCount, syncCountAfterFirstSync + 1)
        XCTAssertEqual(vm.ui.runtimeMetrics.revision, revisionAfterFirstSync)
    }

    func testProvisionalCompletionStoresCacheWithoutSyncForInactiveKey() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-completion-inactive")
        let sessionA = AgentModeViewModel.TabSession(tabID: UUID())
        sessionA.selectedAgent = .claudeCode
        sessionA.selectedModelRaw = "claude-fable-5"
        let sessionB = AgentModeViewModel.TabSession(tabID: UUID())
        sessionB.selectedAgent = .claudeCodeGLM
        sessionB.selectedModelRaw = "sonnet"
        vm.test_installLiveSession(sessionA)
        vm.test_installLiveSession(sessionB)
        vm.test_setCurrentTabIDOverride(sessionB.tabID)
        let keyA = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: sessionA))
        let initialSyncCount = vm.test_syncRuntimeMetricsCallCount

        vm.test_completeProvisionalClaudeContextWindowResolution(400_000, for: keyA)

        XCTAssertEqual(vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: keyA), 400_000)
        XCTAssertEqual(vm.test_syncRuntimeMetricsCallCount, initialSyncCount)
    }

    func testProvisionalCompletionSyncsAfterInflightSwitchBackToMatchingKey() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-completion-switchback")
        let sessionA = AgentModeViewModel.TabSession(tabID: UUID())
        sessionA.selectedAgent = .claudeCode
        sessionA.selectedModelRaw = "claude-fable-5"
        let sessionB = AgentModeViewModel.TabSession(tabID: UUID())
        sessionB.selectedAgent = .claudeCodeGLM
        sessionB.selectedModelRaw = "sonnet"
        vm.test_installLiveSession(sessionA)
        vm.test_installLiveSession(sessionB)
        let keyA = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: sessionA))

        vm.test_setCurrentTabIDOverride(sessionA.tabID)
        vm.test_markProvisionalClaudeContextWindowInFlight(for: keyA)
        vm.test_setCurrentTabIDOverride(sessionB.tabID)
        vm.test_setCurrentTabIDOverride(sessionA.tabID)
        let initialSyncCount = vm.test_syncRuntimeMetricsCallCount

        vm.test_completeProvisionalClaudeContextWindowResolution(400_000, for: keyA)

        XCTAssertEqual(vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: keyA), 400_000)
        XCTAssertEqual(vm.test_syncRuntimeMetricsCallCount, initialSyncCount + 1)
    }

    func testLateProvisionalCompletionPreservesSpawnValueClearsInFlightAndNudgesWithoutRevisionChurn() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-completion-spawn-wins")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)
        let key = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))

        vm.test_markProvisionalClaudeContextWindowInFlight(for: key)
        vm.syncSpawnResolvedClaudeConfiguredContextWindow(400_000, launchKey: key, for: session)
        let syncCountBeforeCompletion = vm.test_syncRuntimeMetricsCallCount
        let revisionBeforeCompletion = vm.ui.runtimeMetrics.revision

        vm.test_completeProvisionalClaudeContextWindowResolution(1_000_000, for: key)

        XCTAssertEqual(vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: key), 400_000)
        XCTAssertFalse(vm.test_isProvisionalClaudeContextWindowInFlight(for: key))
        XCTAssertEqual(vm.test_syncRuntimeMetricsCallCount, syncCountBeforeCompletion + 1)
        XCTAssertEqual(vm.ui.runtimeMetrics.revision, revisionBeforeCompletion)
    }

    func testLateProvisionalCompletionPreservesSpawnNil() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-completion-spawn-nil-wins")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .customClaudeCompatible
        session.selectedModelRaw = "custom-slot"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)
        let key = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))

        vm.test_markProvisionalClaudeContextWindowInFlight(for: key)
        vm.syncSpawnResolvedClaudeConfiguredContextWindow(nil, launchKey: key, for: session)
        vm.test_completeProvisionalClaudeContextWindowResolution(1_000_000, for: key)

        XCTAssertTrue(vm.provisionalClaudeContextWindowResolver.hasCachedValue(for: key))
        XCTAssertNil(vm.provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: key))
        XCTAssertFalse(vm.test_isProvisionalClaudeContextWindowInFlight(for: key))
    }

    func testRestoredUsageNilConfiguredUsesEagerParameterWithoutMutatingUsage() throws {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-stale-cache")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(UUID())
        let key = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        vm.test_storeCachedProvisionalClaudeConfiguredContextWindow(400_000, for: key)
        XCTAssertEqual(vm.test_cachedProvisionalClaudeConfiguredContextWindow(for: session), 400_000)

        let restoredUsage = AgentContextUsage(
            modelContextWindow: 1_000_000,
            configuredContextWindow: nil,
            lastTotalTokens: 75000,
            totalTotalTokens: nil
        )
        let viewModel = AgentRuntimeSidebarViewModel()
        viewModel.update(
            snapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: restoredUsage,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5",
            sessionConfiguredContextWindow: 400_000
        )

        XCTAssertNil(restoredUsage.configuredContextWindow)
        XCTAssertEqual(viewModel.snapshot.configuredContextWindowTokens, 400_000)
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 400_000)
    }

    func testItemsUpdateWithoutSelectedAgentResolvesExactRawsOnly() {
        let viewModel = AgentRuntimeSidebarViewModel()

        // Without an agent, an exact model raw still resolves its context window.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        // Encoded selections need the agent to disambiguate the specifier
        // grammar; without one they pin to the conservative default.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5:xhigh")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 200_000)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5:xhigh")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 200_000)

        // Supplying the agent unlocks encoded-raw resolution on the items path.
        viewModel.update(
            items: [],
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-fable-5:xhigh"
        )
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        viewModel.update(
            items: [],
            codexUsage: nil,
            selectedAgent: .claudeCode,
            selectedModelRaw: "claude-sonnet-5:xhigh"
        )
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)
    }

    // MARK: - Known-vs-fallback context window display gating

    func testDisplayContextWindowTokensTruthTableGatesFactWhileEffectiveMathUnchanged() {
        typealias Snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot

        // (a) configured & canonical both nil -> display nil while effective stays 200K (math unchanged).
        let bothNil = Snapshot(contextWindowTokens: nil, configuredContextWindowTokens: nil)
        XCTAssertNil(bothNil.displayContextWindowTokens)
        XCTAssertEqual(bothNil.effectiveContextWindowTokens, 200_000)

        // (b) configured only.
        let configuredOnly = Snapshot(contextWindowTokens: nil, configuredContextWindowTokens: 400_000)
        XCTAssertEqual(configuredOnly.displayContextWindowTokens, 400_000)

        // (c) canonical only.
        let canonicalOnly = Snapshot(contextWindowTokens: 1_000_000, configuredContextWindowTokens: nil)
        XCTAssertEqual(canonicalOnly.displayContextWindowTokens, 1_000_000)

        // (d) configured + canonical -> min.
        let both = Snapshot(contextWindowTokens: 1_000_000, configuredContextWindowTokens: 400_000)
        XCTAssertEqual(both.displayContextWindowTokens, 400_000)
        XCTAssertEqual(both.effectiveContextWindowTokens, 400_000)

        // (e) KNOWN canonical 200K (Sonnet): non-nil display despite equalling the fallback value.
        let knownSonnet = Snapshot(contextWindowTokens: 200_000, configuredContextWindowTokens: nil)
        XCTAssertEqual(knownSonnet.displayContextWindowTokens, 200_000)
        // KNOWN-200K vs fallback-200K distinction: identical effective, different display.
        XCTAssertEqual(knownSonnet.effectiveContextWindowTokens, bothNil.effectiveContextWindowTokens)
        XCTAssertNotNil(knownSonnet.displayContextWindowTokens)
        XCTAssertNil(bothNil.displayContextWindowTokens)
    }

    func testCodexGPTPreUsageYieldsNilDisplayThenProviderWindowShows() {
        // (a) .codexExec GPT raw, no usage but restored transcript estimate: adapter +
        // AgentModel.resolvedModel return nil windows, so canonical is nil and no fabricated 200K
        // is surfaced (display nil), while the effective fallback remains available internally.
        let store = AgentRuntimeMetricsUIStore()
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(estimatedTranscriptTokens: 50000),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.5"
        )
        XCTAssertNil(store.runtimeVM.snapshot.canonicalContextWindowTokens)
        XCTAssertNil(store.runtimeVM.snapshot.configuredContextWindowTokens)
        XCTAssertNil(store.runtimeVM.snapshot.displayContextWindowTokens)
        XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
        XCTAssertEqual(store.runtimeVM.snapshot.estimatedTranscriptTokens, 50000)

        // (b) after the first usage event carries the provider-reported ~258.4K window.
        store.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: AgentContextUsage(
                modelContextWindow: 258_400,
                lastTotalTokens: 1000,
                totalTotalTokens: nil
            ),
            liveSelectedFileCount: nil,
            selectedAgent: .codexExec,
            selectedModelRaw: "gpt-5.5"
        )
        XCTAssertEqual(store.runtimeVM.snapshot.canonicalContextWindowTokens, 258_400)
        XCTAssertEqual(store.runtimeVM.snapshot.displayContextWindowTokens, 258_400)

        // (c) companion .customClaudeCompatible unknown raw with no settings -> both nil -> display nil.
        let customStore = AgentRuntimeMetricsUIStore()
        customStore.update(
            transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
            codexUsage: nil,
            liveSelectedFileCount: nil,
            selectedAgent: .customClaudeCompatible,
            selectedModelRaw: "totally-unknown-model"
        )
        XCTAssertNil(customStore.runtimeVM.snapshot.canonicalContextWindowTokens)
        XCTAssertNil(customStore.runtimeVM.snapshot.displayContextWindowTokens)
        XCTAssertEqual(customStore.runtimeVM.snapshot.effectiveContextWindowTokens, 200_000)
    }

    func testEffectiveFallbackRetainedForInternalMathWhileDisplayNilWhenWindowUnknown() {
        typealias Snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot

        // Boundary case: restored-session estimate present, window unknown (both nil). The effective
        // fallback (200K) remains available for internal math while display stays nil, so views can
        // suppress the visible ratio denominator/percentage.
        let estimateSnapshot = Snapshot(
            estimatedTranscriptTokens: 50000,
            contextWindowTokens: nil,
            configuredContextWindowTokens: nil,
            usageSource: .unavailable
        )
        XCTAssertNil(estimateSnapshot.displayContextWindowTokens)
        XCTAssertEqual(estimateSnapshot.effectiveContextWindowTokens, 200_000)

        // .toolDerived tokenStatsTotal present, window unknown: same internal-math/display boundary.
        let toolDerived = Snapshot(
            usedTokens: 25000,
            contextWindowTokens: nil,
            configuredContextWindowTokens: nil,
            usageSource: .toolDerived
        )
        XCTAssertNil(toolDerived.displayContextWindowTokens)
        XCTAssertEqual(toolDerived.effectiveContextWindowTokens, 200_000)
    }

    private func makeDivergedClaudeLaunchKeyState() throws -> (
        vm: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        launchKey: ClaudeProvisionalContextWindowResolver.Key,
        currentKey: ClaudeProvisionalContextWindowResolver.Key
    ) {
        let vm = makeViewModel(testWorkspacePath: "/tmp/repoprompt-sidebar-launch-key-race")
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-fable-5"
        vm.test_installLiveSession(session)
        vm.test_setCurrentTabIDOverride(session.tabID)
        let launchKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))

        session.selectedModelRaw = "claude-sonnet-5"
        let currentKey = try XCTUnwrap(vm.test_provisionalClaudeContextWindowKey(for: session))
        XCTAssertNotEqual(launchKey, currentKey)
        XCTAssertFalse(vm.provisionalClaudeContextWindowResolver.hasCachedValue(for: currentKey))

        vm.syncSpawnResolvedClaudeConfiguredContextWindow(400_000, launchKey: launchKey, for: session)

        return (vm, session, launchKey, currentKey)
    }

    private func installTemporaryCustomSlotMapping() -> () -> Void {
        let defaults = UserDefaults.standard
        let store = ClaudeCodeCompatibleBackendStore.shared
        let configsKey = ClaudeCodeCompatibleBackendStore.configsDefaultsKey
        let configuredKey = store.configuredDefaultsKey(for: .custom)
        let previousConfigs = defaults.data(forKey: configsKey)
        let previousConfigured = defaults.object(forKey: configuredKey)

        store.saveConfig(ClaudeCodeCompatibleBackendConfig(
            id: .custom,
            isEnabled: true,
            displayName: "CC Custom GLM",
            baseURL: "https://example.test/anthropic",
            auth: .anthropicAPIKey,
            modelBehavior: .claudeSlotMapping(.init(
                haiku: "custom-fast",
                sonnet: "glm-5.2[1m]",
                opus: "glm-5.2"
            ))
        ))
        _ = store.setConfigured(true, for: .custom)

        return {
            if let previousConfigs {
                defaults.set(previousConfigs, forKey: configsKey)
            } else {
                defaults.removeObject(forKey: configsKey)
            }
            if let previousConfigured {
                defaults.set(previousConfigured, forKey: configuredKey)
            } else {
                defaults.removeObject(forKey: configuredKey)
            }
        }
    }

    private func makeViewModel(testWorkspacePath: String? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: testWorkspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in RuntimeSidebarFakeCodexController() }
        )
    }

    private func makeManageSelectionItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let reply = ToolResultDTOs.SelectionReply(
            files: files,
            totalTokens: fileCount * 10,
            status: "Selection • add • \(fileCount) files"
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "manage_selection",
            toolResultJSON: json
        )
    }

    private func makeWorkspaceContextItem(
        fileCount: Int,
        timestamp: Date = Date(),
        tokenStatsTotal: Int? = nil
    ) throws -> AgentChatItem {
        let files = makeSelectedFiles(fileCount: fileCount)
        let selection = ToolResultDTOs.SelectedFilesReply(
            files: files,
            totalTokens: fileCount * 10,
            fileSlices: nil,
            summary: nil
        )
        let reply = ToolResultDTOs.PromptContextDTO(
            prompt: "",
            selection: selection,
            fileBlocks: nil,
            codeStructure: nil,
            fileTree: nil,
            tokenStats: tokenStatsTotal.map { ToolResultDTOs.TokenStats(total: $0, files: fileCount * 10) },
            userTokenStats: nil,
            tokenStatsNote: nil,
            copyPreset: nil,
            copyPresets: nil
        )
        let data = try JSONEncoder().encode(reply)
        let json = String(decoding: data, as: UTF8.self)
        return AgentChatItem(
            timestamp: timestamp,
            kind: .toolResult,
            text: json,
            toolName: "workspace_context",
            toolResultJSON: json
        )
    }

    private func makeSelectedFiles(fileCount: Int) -> [ToolResultDTOs.SelectedFileInfo] {
        (0 ..< fileCount).map { index in
            ToolResultDTOs.SelectedFileInfo(
                path: "Sources/File\(index).swift",
                tokens: 10,
                renderMode: "full",
                ranges: nil,
                isAuto: false,
                codemapOrigin: nil,
                copyPreset: nil
            )
        }
    }
}

private final class RuntimeSidebarFakeCodexController: CodexSessionControllerTurnDispatchTestDefaults {
    var hasActiveThread: Bool {
        false
    }

    var events: AsyncStream<CodexNativeSessionController.Event> {
        AsyncStream { continuation in continuation.finish() }
    }

    func ensureEventsStreamReady() {}

    func startOrResume(
        existing _: CodexNativeSessionController.SessionRef?,
        baseInstructions _: String
    ) async throws -> CodexNativeSessionController.SessionRef {
        CodexNativeSessionController.SessionRef(
            conversationID: "runtime-sidebar-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil
        )
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        CodexNativeSessionController.ThreadSnapshot(
            conversationID: "runtime-sidebar-test",
            rolloutPath: nil,
            model: nil,
            reasoningEffort: nil,
            runtimeStatus: .idle,
            currentTurnID: nil,
            activeTurnIDs: [],
            latestTurnStatus: nil
        )
    }

    func setThreadName(_: String, threadID _: String?) async throws {}
    func compactThread() async throws {}
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        nil
    }

    func cancelCurrentTurn() async {}
    func shutdown() async {}
    func respondToServerRequest(id _: CodexAppServerRequestID, result _: [String: Any]) async {}
}
