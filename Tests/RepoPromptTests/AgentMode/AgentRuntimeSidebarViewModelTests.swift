import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptSettingsCore
@testable import RepoPromptWorkspaceContext
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

    func testClaudeOpus48BaseAndEncodedSelectionsFallBackToOneMillionTokenContextWindow() {
        let store = AgentRuntimeMetricsUIStore()

        for selectedModelRaw in ["claude-opus-4-8", "claude-opus-4-8:xhigh"] {
            store.update(
                transcriptSnapshot: AgentTranscriptAnalyticsSnapshot(),
                codexUsage: nil,
                liveSelectedFileCount: nil,
                selectedAgent: .claudeCode,
                selectedModelRaw: selectedModelRaw
            )

            XCTAssertNil(store.runtimeVM.snapshot.contextWindowTokens)
            XCTAssertEqual(store.runtimeVM.snapshot.effectiveContextWindowTokens, 1_000_000, selectedModelRaw)
        }
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
        XCTAssertNil(store.runtimeVM.snapshot.effectiveContextWindowTokens, "An unknown backend window stays unknown")
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

    func testItemsUpdateWithoutSelectedAgentResolvesExactRawsOnly() {
        let viewModel = AgentRuntimeSidebarViewModel()

        // Without an agent, an exact model raw still resolves its context window.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5")
        XCTAssertEqual(viewModel.snapshot.effectiveContextWindowTokens, 1_000_000)

        // Encoded selections need the agent to disambiguate the specifier
        // grammar; without one the window stays unknown rather than guessed.
        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-fable-5:xhigh")
        XCTAssertNil(viewModel.snapshot.effectiveContextWindowTokens)

        viewModel.update(items: [], codexUsage: nil, selectedModelRaw: "claude-sonnet-5:xhigh")
        XCTAssertNil(viewModel.snapshot.effectiveContextWindowTokens)

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

    private func makeWorkspaceContextItem(fileCount: Int, timestamp: Date = Date()) throws -> AgentChatItem {
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
            tokenStats: nil,
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

/// Issue #506: an unknown Claude window must not act as a 200K ceiling, and a user-set
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is the effective denominator.
@MainActor
final class ClaudeContextWindowResolutionTests: XCTestCase {
    private func makeEstimator() -> ClaudeContextUsageEstimator {
        ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { usage, window in
            AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
        })
    }

    private func makeSession(model: String = "claude-fable-5", autoCompactWindow: Int? = nil) -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = model
        session.claudeAutoCompactWindowTokens = autoCompactWindow
        return session
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Context-window tests must not start a Codex session")
            }
        )
    }

    // MARK: - Unknown windows

    func testUnknownWindowKeepsReadingsAboveTwoHundredThousand() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model")

        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
        XCTAssertNil(session.codexContextUsage?.modelContextWindow)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 250_000)

        XCTAssertTrue(estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: 260_000, session: session))
        XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 260_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 260_000)
    }

    func testKnownWindowStillRejectsImpossibleReadings() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000, modelContextWindow: 200_000, session: session)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 250_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 150_000)
    }

    func testRestoredRowsAboveTwoHundredThousandSurviveAnUnknownWindow() {
        let rows = [AgentTokenUsagePersist(runID: nil, turnID: nil, promptTokens: 0, completionTokens: 0, contextUsedTokens: 350_000)]
        let restored = AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: nil)
        XCTAssertEqual(restored?.lastTotalTokens, 350_000)
        XCTAssertNil(restored?.modelContextWindow)

        XCTAssertNil(
            AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: 200_000)?.lastTotalTokens,
            "A known window still bounds restored rows"
        )
    }

    // MARK: - Auto-compact window

    func testAutoCompactWindowIsTheDenominatorBeforeAndAfterTheFirstResponse() {
        let estimator = makeEstimator()
        let session = makeSession(autoCompactWindow: 400_000)

        // Runtime init re-resolves through an empty usage report.
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: nil, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)

        // Claude reports the model's full 1M window at turn end.
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 120_000, modelContextWindow: 1_000_000, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 120_000)
    }

    func testAutoCompactWindowNeverRejectsReadings() {
        let estimator = makeEstimator()
        let session = makeSession(autoCompactWindow: 400_000)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 450_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 450_000)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: nil, completionTokens: nil, contextUsedTokens: 460_000, session: session))
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 460_000)
    }

    func testAutoCompactWindowAboveTheModelWindowUsesTheModelWindow() {
        let estimator = makeEstimator()
        let session = makeSession(model: "sonnet", autoCompactWindow: 1_000_000)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: nil, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 200_000)
    }

    func testRestoredUncappedWindowIsCappedOnTheNextReport() {
        let estimator = makeEstimator()
        let session = makeSession()
        session.codexContextUsage = AgentContextUsage(modelContextWindow: 1_000_000, lastTotalTokens: 90000, totalTotalTokens: 90000)
        session.claudeAutoCompactWindowTokens = 400_000
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: nil, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 90000)
    }

    func testAutoCompactWindowAppliesOnlyWhileAClaudeNativeProviderIsSelected() {
        let session = makeSession(autoCompactWindow: 400_000)
        XCTAssertEqual(session.activeClaudeAutoCompactWindowTokens, 400_000)
        session.selectedAgent = .claudeCodeGLM
        XCTAssertNil(session.activeClaudeAutoCompactWindowTokens, "The cap described the previous provider's process")
        session.claudeAutoCompactWindowTokens = 400_000
        XCTAssertEqual(session.activeClaudeAutoCompactWindowTokens, 400_000)
        session.selectedAgent = .openCode
        XCTAssertNil(session.activeClaudeAutoCompactWindowTokens)
        session.selectedAgent = .codexExec
        XCTAssertNil(session.activeClaudeAutoCompactWindowTokens)
    }

    func testCappedReportedWindowKeepsTheWindowVouch() {
        let viewModel = makeViewModel()
        let session = makeSession(autoCompactWindow: 400_000)
        XCTAssertTrue(viewModel.usageRuntime.ingestNonCodexUsageReport(
            promptTokens: nil, completionTokens: nil, contextUsedTokens: 150_000,
            modelContextWindow: 1_000_000, session: session
        ))
        XCTAssertEqual(session.contextUsageSnapshot?.window, 400_000)
        XCTAssertEqual(session.vouchedContextWindow?.tokens, 400_000, "The capped window is the provider's effective window")
        XCTAssertEqual(session.vouchedContextCount?.tokens, 150_000)
    }

    // MARK: - Presentation

    func testSidebarLeavesUnknownWindowsUnknown() {
        for (agent, model) in [
            (AgentProviderKind.claudeCode, "claude-unlisted-model"),
            (.codexExec, "gpt-unlisted-model"),
            (.openCode, "anything"),
            (.cursor, "anything"),
            (.devin, "anything")
        ] {
            let snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: agent, selectedModelRaw: model)
            XCTAssertNil(snapshot.effectiveContextWindowTokens, "\(agent) \(model)")
        }
        XCTAssertNil(AgentRuntimeSidebarViewModel.ContextSnapshot(selectedModelRaw: "claude-fable-5:xhigh").effectiveContextWindowTokens)

        XCTAssertEqual(
            AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: .claudeCode, selectedModelRaw: "claude-fable-5").effectiveContextWindowTokens,
            1_000_000,
            "Known model windows still resolve"
        )
        var reported = AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: .claudeCode, selectedModelRaw: "claude-unlisted-model")
        reported.contextWindowTokens = 400_000
        XCTAssertEqual(reported.effectiveContextWindowTokens, 400_000)
    }

    func testDrawerTokenPillShowsCountWithoutAGuessedDenominator() {
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.tokenSummaryText(usedTokens: 12300, contextWindowTokens: nil), "12.3K tokens")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.tokenSummaryText(usedTokens: 12300, contextWindowTokens: 400_000), "12.3K / 400.0K")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.budgetText(usedPercent: nil), "Context window unknown")
        XCTAssertEqual(AgentContextDrawerTokenEstimatePill.budgetText(usedPercent: 3.1), "3% of budget")
    }
}

/// Follow-up to #1594 (issue #506): the auto-compact cap sizes the displayed window only. The model's
/// own capacity is kept separately, bounds every reading, and the window is recomputed from it on
/// each runtime init without touching usage provenance.
@MainActor
final class ClaudeContextWindowCapLifecycleTests: XCTestCase {
    private func makeEstimator() -> ClaudeContextUsageEstimator {
        ClaudeContextUsageEstimator(tokenEstimator: { _ in 0 }, contextUsageBuilder: { usage, window in
            AgentSessionUsageRuntime.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
        })
    }

    /// An unlisted model, so only a provider report knows its real 1M capacity.
    private func makeSession(model: String = "claude-unlisted-model", cap: Int?) -> AgentTabSession {
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = model
        session.claudeAutoCompactWindowTokens = cap
        return session
    }

    /// One completed turn under the cap: Claude reports the model's full window at turn end.
    private func completeCappedTurn(_ estimator: ClaudeContextUsageEstimator, _ session: AgentTabSession, used: Int = 120_000) {
        _ = estimator.ingestUsageSignal(promptTokens: used, completionTokens: 10, contextUsedTokens: used, modelContextWindow: nil, session: session)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: used, completionTokens: 10, contextUsedTokens: nil, session: session))
    }

    private func runtimeInit(cap: Int?) -> NativeAgentRuntimeEvent {
        .runtimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: cap))
    }

    // MARK: - Cap changes recompute from the model's capacity

    func testRaisingTheCapRecomputesFromTheModelCapacity() {
        let estimator = makeEstimator()
        let session = makeSession(cap: 400_000)
        completeCappedTurn(estimator, session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.contextWindowCapacity?.tokens, 1_000_000)

        session.claudeAutoCompactWindowTokens = 600_000
        XCTAssertTrue(estimator.reconcileContextWindow(session: session))
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 600_000)
    }

    func testRemovingTheCapRestoresTheModelWindowAndItsCeiling() {
        let estimator = makeEstimator()
        let session = makeSession(cap: 400_000)
        completeCappedTurn(estimator, session)

        session.claudeAutoCompactWindowTokens = nil
        estimator.reconcileContextWindow(session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 1_000_000)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 500_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 500_000, "A valid reading above the old cap is kept")
    }

    // MARK: - The model's capacity, never the cap, bounds readings

    func testACapKeepsTheModelCapacityAsTheCeiling() {
        let estimator = makeEstimator()
        let session = makeSession(cap: 400_000)
        completeCappedTurn(estimator, session)

        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 450_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 450_000, "The cap is a compaction threshold, not a ceiling")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 450_000, "An impossible windowless reading is rejected")
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 450_000, completionTokens: 10, contextUsedTokens: 1_300_000, session: session))
        XCTAssertEqual(session.providerTokenUsageByTurn.last?.contextUsedTokens, 450_000, "An impossible finalized reading is not persisted")
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
    }

    func testRejectedOccupancyDoesNotFallBackToThePromptCount() {
        let estimator = makeEstimator()
        let session = makeSession(cap: 400_000)
        completeCappedTurn(estimator, session)

        // Realistic events carry both counts; an impossible occupancy discredits the billed prompt.
        _ = estimator.ingestUsageSignal(promptTokens: 1_250_000, completionTokens: 10, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 120_000)
        _ = estimator.ingestUsageSignal(promptTokens: 1_250_000, completionTokens: 10, contextUsedTokens: nil, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 120_000, "A prompt count above the capacity is rejected too")
        _ = estimator.ingestUsageSignal(promptTokens: 450_000, completionTokens: 10, contextUsedTokens: 430_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 430_000)
    }

    func testCapacitySurvivesCompactionAndRebuild() {
        let estimator = makeEstimator()
        let session = makeSession(cap: 400_000)
        completeCappedTurn(estimator, session, used: 390_000)

        estimator.ingestSystemSignal("Context compacted", session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
        XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)

        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_100_000, modelContextWindow: nil, session: session)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens, "The capacity still bounds readings after compaction")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 60000, modelContextWindow: nil, session: session)
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 60000, completionTokens: 10, contextUsedTokens: nil, session: session))
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 60000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000, "The rebuild keeps the effective window")
        XCTAssertEqual(estimator.verifiedCapacity(reported: nil, session: session), 1_000_000)
    }

    // MARK: - Identity

    func testCapacityIsScopedToTheProviderAndModel() {
        let estimator = makeEstimator()
        let session = makeSession(cap: nil)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        XCTAssertEqual(estimator.verifiedCapacity(reported: nil, session: session), 1_000_000)

        session.selectedModelRaw = "claude-other-unlisted-model"
        XCTAssertNil(estimator.verifiedCapacity(reported: nil, session: session), "Another model's capacity is not this model's")
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_500_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 1_500_000, "An unknown capacity bounds nothing")

        session.selectedModelRaw = "claude-unlisted-model"
        XCTAssertEqual(estimator.verifiedCapacity(reported: nil, session: session), 1_000_000)

        session.claudeAutoCompactWindowTokens = 400_000
        session.selectedAgent = .claudeCodeGLM
        XCTAssertNil(session.claudeAutoCompactWindowTokens, "The cap described the previous provider's process")
        XCTAssertNil(session.identityValidContextWindowCapacity, "Another provider's capacity is not this provider's")
    }

    private func sidebarWindow(_ session: AgentTabSession) -> Int? {
        var snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: session.selectedAgent, selectedModelRaw: session.selectedModelRaw)
        snapshot.contextWindowTokens = session.codexContextUsage?.modelContextWindow
        return snapshot.effectiveContextWindowTokens
    }

    func testModelAndProviderSwitchesRecomputeTheWindowBeforeAnyUsageEvent() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-fable-5", cap: 400_000)
        completeCappedTurn(estimator, session, used: 150_000)
        XCTAssertEqual(sidebarWindow(session), 400_000)

        // A 1M model capped at 400K switches to a 200K model: 150K is 75% of it, not 38% of 400K.
        session.selectedModelRaw = "sonnet"
        XCTAssertEqual(sidebarWindow(session), 200_000)
        XCTAssertEqual(session.contextUsageSnapshot?.window, 200_000)

        session.selectedModelRaw = "claude-fable-5"
        XCTAssertEqual(sidebarWindow(session), 400_000, "The model's stored capacity applies again")

        session.selectedAgent = .kimiCode
        XCTAssertEqual(
            session.codexContextUsage?.modelContextWindow,
            ClaudeCompatibleModelCatalogAdapter.contextWindowTokens(forRequestedModelRaw: session.selectedModelRaw, agentKind: .kimiCode),
            "Neither Claude's capacity nor its process's cap sizes Kimi's window"
        )
    }

    func testFinalizationRejectsStreamedOccupancyAboveANewlyReportedCapacity() {
        let estimator = makeEstimator()
        let session = makeSession(cap: nil)
        // Turn 1 streams 1.2M while the capacity is still unknown.
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        // The result then establishes a 1M capacity without its own occupancy.
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens, "The carried reading exceeds the new capacity")
        XCTAssertTrue(estimator.finalizeTurn(promptTokens: 1000, completionTokens: 10, contextUsedTokens: nil, session: session))
        XCTAssertNil(session.providerTokenUsageByTurn.last?.contextUsedTokens, "The streamed reading is not persisted")
        XCTAssertNil(session.codexContextUsage?.lastTotalTokens)
        XCTAssertNil(session.codexContextUsage?.totalTotalTokens)
    }

    func testAnEffortOnlySwitchKeepsTheCapacity() {
        let estimator = makeEstimator()
        let session = makeSession(model: "claude-unlisted-model:high", cap: nil)
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: nil, modelContextWindow: 1_000_000, session: session)
        session.selectedModelRaw = "claude-unlisted-model:xhigh"
        XCTAssertEqual(session.identityValidContextWindowCapacity, 1_000_000)
        session.selectedModelRaw = "claude-unlisted-model"
        XCTAssertEqual(session.identityValidContextWindowCapacity, 1_000_000)
        session.selectedModelRaw = "claude-other-unlisted-model:high"
        XCTAssertNil(session.identityValidContextWindowCapacity)
    }

    func testANonPositiveStoredCapacityIsNotACapacity() {
        let session = makeSession(cap: nil)
        session.contextWindowCapacity = AgentContextWindowCapacity(
            tokens: 0,
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: AgentContextWindowCapacity.modelKey(forRaw: session.selectedModelRaw)
        )
        XCTAssertNil(session.identityValidContextWindowCapacity)
    }

    /// Records saved before capacities were stored have none: their window and ceiling stay unknown
    /// until the next turn reports the model window, and that turn's readings are not bounded.
    func testPreCapacityRecordsLoseTheirWindowAndCeilingForOneTurn() {
        let estimator = makeEstimator()
        let session = makeSession(cap: nil)
        session.codexContextUsage = AgentContextUsage(modelContextWindow: 1_000_000, lastTotalTokens: 90000, totalTotalTokens: 90000)
        estimator.reconcileContextWindow(session: session)
        XCTAssertNil(session.codexContextUsage?.modelContextWindow)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 1_200_000, "No ceiling until the model window is reported")
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 95000, modelContextWindow: 1_000_000, session: session)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 1_000_000)
        XCTAssertEqual(session.contextWindowCapacity?.tokens, 1_000_000)
        _ = estimator.ingestUsageSignal(promptTokens: nil, completionTokens: nil, contextUsedTokens: 1_200_000, modelContextWindow: nil, session: session)
        XCTAssertEqual(session.codexContextUsage?.lastTotalTokens, 95000, "The reported window bounds later readings")
    }

    func testCapacityRoundTripsAndLegacyRecordsDecodeWithoutIt() throws {
        let capacity = AgentContextWindowCapacity(tokens: 1_000_000, agentRaw: "claudeCode", modelRaw: "claude-fable-5")
        let session = AgentSession(id: UUID(), name: "Capacity", items: [], codexContextWindow: 400_000, contextWindowCapacity: capacity)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.contextWindowCapacity, capacity)
        XCTAssertEqual(decoded.codexContextWindow, 400_000, "The stored window stays the effective window")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "contextWindowCapacity")
        let legacyDecoded = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyDecoded.contextWindowCapacity)
        XCTAssertEqual(legacyDecoded.codexContextWindow, 400_000)
    }

    /// One malformed capacity must not fail a session file: the retirement scan maps every header
    /// with a throwing decode, so a throw there would fail the whole scan.
    func testSessionHeaderLoadTreatsAMalformedCapacityAsAbsent() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCapacityHeader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capacity = AgentContextWindowCapacity(tokens: 1_000_000, agentRaw: "claudeCode", modelRaw: "claude-fable-5")
        let session = AgentSession(id: UUID(), name: "Capacity header", contextWindowCapacity: capacity)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])

        func loadStub(named name: String) async throws -> AgentSession {
            let fileURL = folder.appendingPathComponent("AgentSession-\(name).json")
            try JSONSerialization.data(withJSONObject: payload).write(to: fileURL)
            return try await AgentSessionDataService.shared.loadAgentSessionStub(from: fileURL)
        }

        let wellFormed = try await loadStub(named: "well-formed")
        XCTAssertEqual(wellFormed.contextWindowCapacity, capacity)

        for malformed: Any in ["bogus", 12, ["tokens": "many"]] {
            payload["contextWindowCapacity"] = malformed
            let stub = try await loadStub(named: "malformed")
            XCTAssertEqual(stub.id, session.id, "The session survives")
            XCTAssertNil(stub.contextWindowCapacity)
        }
    }

    // MARK: - Runtime init

    func testEveryRuntimeInitReappliesTheCapAfterClearChat() async throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .claudeCode)
        session.selectedModelRaw = "claude-fable-5"
        harness.host.test_installLiveSession(session)
        let runner = try ClaudeIntegratedAgentModeRunner(claudeCoordinator: harness.host.claudeCoordinator, hooks: XCTUnwrap(harness.hooks), terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        func consumeInit(cap: Int?) async {
            let runID = UUID()
            session.installRunID(runID)
            session.runState = .running
            let owner = session.beginRunAttempt(source: "auto-compact-window-init-test")
            _ = await runner.testConsumeTurnStatus([runtimeInit(cap: cap)], session: session, runID: runID, owner: owner)
        }

        // A fresh synthetic stream per init stands in for each new process: the controller dedupes
        // repeated init statuses per process, and Clear Chat replaces the process.
        await consumeInit(cap: 400_000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)

        harness.host.clearChat(tabID: session.tabID)
        XCTAssertNil(session.claudeAutoCompactWindowTokens, "Clear Chat tears down the process the cap described")
        XCTAssertNil(session.codexContextUsage)

        // The next process reports the same cap; it must still apply.
        await consumeInit(cap: 400_000)
        XCTAssertEqual(session.claudeAutoCompactWindowTokens, 400_000)
        XCTAssertEqual(session.codexContextUsage?.modelContextWindow, 400_000)
    }

    func testRepeatedRuntimeInitsKeepUsageProvenanceAndCreateNoVouch() {
        let viewModel = AgentModeViewModel(
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Context-window tests must not start a Codex session") }
        )
        let session = makeSession(cap: nil)
        let estimator = viewModel.usageRuntime.claudeContextUsageEstimator
        _ = estimator.ingestTurnFinalizationSignal(contextUsedTokens: 90000, modelContextWindow: 1_000_000, session: session)
        estimator.ingestSystemSignal("Context compacted", session: session)
        let before = session.contextUsageSnapshot
        XCTAssertEqual(before?.source, .compactionSignal)
        XCTAssertNil(session.vouchedContextWindow)

        for _ in 0 ..< 2 {
            viewModel.claudeCoordinator.observeRuntimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: 400_000), session: session)
            XCTAssertEqual(session.contextUsageSnapshot?.window, 400_000)
            XCTAssertEqual(session.contextUsageSnapshot?.source, before?.source)
            XCTAssertEqual(session.contextUsageSnapshot?.confidence, before?.confidence)
            XCTAssertEqual(session.contextUsageSnapshot?.compactedAt, before?.compactedAt)
            XCTAssertEqual(session.codexContextUsage?.awaitingPostCompactionUsage, true)
            XCTAssertNil(session.codexContextUsage?.lastTotalTokens)
            XCTAssertNil(session.vouchedContextWindow, "A recomputed window is not a provider report")
        }
        XCTAssertFalse(viewModel.claudeCoordinator.observeRuntimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: 400_000), session: session), "An unchanged cap changes nothing")
    }
}

#if DEBUG
    /// Records saved by #1594 builds hold the capped 400K effective window and no capacity. Restoring
    /// one must not turn that cap into a validation ceiling or a permanent denominator.
    @MainActor
    final class ClaudeContextWindowCapacityRestoreTests: XCTestCase {
        func testLegacyCappedRecordAndCapacityRecordRestore() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCapacityRestore-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            let window = WindowState()
            WindowStatesManager.shared.registerWindowState(window)
            defer {
                for session in window.agentModeViewModel.sessions.values {
                    session.saveDebounceTask?.cancel()
                }
                WindowStatesManager.shared.unregisterWindowState(window)
                GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            }
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(name: "Capacity restore", repoPaths: [root.path], ephemeral: true)
            await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "capacityRestoreTests")
            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
            let tabID = try XCTUnwrap(activeWorkspace.activeComposeTabID)
            let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == activeWorkspace.id })
            window.workspaceManager.workspaces[index].customStoragePath = root.appendingPathComponent("sessions", isDirectory: true)
            let request = AgentChatItem.user("Capacity restore")
            let transcript = AgentTranscript(turns: [AgentTranscriptTurn(
                request: AgentTranscriptRequestAnchor(from: request),
                terminalState: .completed,
                startedAt: request.timestamp,
                completedAt: request.timestamp
            )], nextSequenceIndex: 1)
            // Restore resolves this session to `opus` (a 200K catalog window), so the numbers follow it.
            let model = "opus"
            let viewModel = window.agentModeViewModel
            func save(_ rows: [AgentTokenUsagePersist], capacity: AgentContextWindowCapacity?) async throws -> UUID {
                let id = UUID()
                let persisted = AgentSession(
                    id: id, workspaceID: activeWorkspace.id, composeTabID: tabID, name: "Capped Claude",
                    transcript: transcript, agentKind: AgentProviderKind.claudeCode.rawValue,
                    agentModel: model, lastRunState: "completed", providerTokenUsageByTurn: rows,
                    codexContextWindow: 150_000, contextWindowCapacity: capacity
                )
                _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: window.workspaceManager.workspaces[index])
                return id
            }
            func sidebarWindow(_ session: AgentTabSession) -> Int? {
                var snapshot = AgentRuntimeSidebarViewModel.ContextSnapshot(selectedAgent: session.selectedAgent, selectedModelRaw: session.selectedModelRaw)
                snapshot.contextWindowTokens = session.codexContextUsage?.modelContextWindow
                return snapshot.effectiveContextWindowTokens
            }

            // Legacy: a 180K reading taken under a 150K cap on a 200K model.
            let legacyID = try await save([AgentTokenUsagePersist(promptTokens: 180_000, completionTokens: 10, contextUsedTokens: 180_000)], capacity: nil)
            let initial = viewModel.session(for: tabID)
            _ = try XCTUnwrap(viewModel.test_installPersistentSessionBinding(sessionID: legacyID, on: initial, updateWorkspaceMetadata: true))
            initial.hasLoadedPersistedState = false
            let legacy = await viewModel.ensureSessionReady(tabID: tabID)
            XCTAssertEqual(legacy.selectedModelRaw, model)
            XCTAssertNil(legacy.contextWindowCapacity)
            XCTAssertEqual(legacy.codexContextUsage?.lastTotalTokens, 180_000, "The legacy cap is not a ceiling")
            XCTAssertEqual(legacy.codexContextUsage?.modelContextWindow, 150_000, "It stays as historical display data")
            viewModel.claudeCoordinator.observeRuntimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: nil), session: legacy)
            XCTAssertNil(legacy.codexContextUsage?.modelContextWindow, "An uncapped process does not keep the legacy cap")
            XCTAssertEqual(sidebarWindow(legacy), 200_000, "The sidebar falls back to the model's catalog window")

            // Current: the stored capacity bounds restored rows, and each init re-derives the window.
            let capacity = AgentContextWindowCapacity(tokens: 200_000, agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: AgentContextWindowCapacity.modelKey(forRaw: model))
            let currentID = try await save([
                AgentTokenUsagePersist(promptTokens: 190_000, completionTokens: 10, contextUsedTokens: 190_000),
                AgentTokenUsagePersist(promptTokens: 250_000, completionTokens: 10, contextUsedTokens: 250_000)
            ], capacity: capacity)
            let routed = await viewModel.activateRoutedAgentSession(tabID: tabID, sessionID: currentID, workspace: window.workspaceManager.workspaces[index])
            XCTAssertEqual(routed, .ready)
            let current = try XCTUnwrap(viewModel.sessions[tabID])
            XCTAssertEqual(current.contextWindowCapacity, capacity)
            XCTAssertEqual(current.selectedModelRaw, model)
            XCTAssertEqual(current.codexContextUsage?.lastTotalTokens, 190_000, "An impossible restored row is rejected")
            viewModel.claudeCoordinator.observeRuntimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: 160_000), session: current)
            XCTAssertEqual(current.codexContextUsage?.modelContextWindow, 160_000)
            viewModel.claudeCoordinator.observeRuntimeInit(.init(sessionID: nil, tools: [], mcpServerStatuses: [:], initializeResponse: nil, autoCompactWindowTokens: nil), session: current)
            XCTAssertEqual(current.codexContextUsage?.modelContextWindow, 200_000)
        }
    }
#endif
