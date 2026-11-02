import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptFoundation
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
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(usage, modelContextWindow: window)
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

    // MARK: - Environment parsing

    func testAutoCompactWindowParsesOnlyPositiveIntegers() {
        let key = ClaudeAutoCompactWindow.environmentKey
        XCTAssertEqual(key, "CLAUDE_CODE_AUTO_COMPACT_WINDOW")
        XCTAssertEqual(ClaudeAutoCompactWindow.tokens(in: [key: "400000"]), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.tokens(in: [key: " 400000\n"]), 400_000)
        for invalid in ["", "0", "-1", "400k", "4e5"] {
            XCTAssertNil(ClaudeAutoCompactWindow.tokens(in: [key: invalid]), invalid)
        }
        XCTAssertNil(ClaudeAutoCompactWindow.tokens(in: [:]))
    }

    func testEffectiveWindowIsTheSmallerKnownWindow() {
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 1_000_000, autoCompactWindow: 400_000), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 200_000, autoCompactWindow: 400_000), 200_000, "Claude Code caps the setting at the model window")
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: nil, autoCompactWindow: 400_000), 400_000)
        XCTAssertEqual(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: 1_000_000, autoCompactWindow: nil), 1_000_000)
        XCTAssertNil(ClaudeAutoCompactWindow.effectiveWindow(modelWindow: nil, autoCompactWindow: nil))

        XCTAssertNil(ClaudeAutoCompactWindow.cappedReportedWindow(nil, autoCompactWindow: 400_000), "No report invents no window")
        XCTAssertEqual(ClaudeAutoCompactWindow.cappedReportedWindow(0, autoCompactWindow: 400_000), 0, "A withdrawal signal passes through")
        XCTAssertEqual(ClaudeAutoCompactWindow.cappedReportedWindow(1_000_000, autoCompactWindow: 400_000), 400_000)
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
        let restored = AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: nil)
        XCTAssertEqual(restored?.lastTotalTokens, 350_000)
        XCTAssertNil(restored?.modelContextWindow)

        XCTAssertNil(
            AgentModeViewModel.contextUsageFromClaudeProviderTokens(rows, modelContextWindow: 200_000)?.lastTotalTokens,
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
        XCTAssertEqual(session.activeClaudeAutoCompactWindowTokens, 400_000)
        session.selectedAgent = .openCode
        XCTAssertNil(session.activeClaudeAutoCompactWindowTokens)
        session.selectedAgent = .codexExec
        XCTAssertNil(session.activeClaudeAutoCompactWindowTokens)
    }

    func testCappedReportedWindowKeepsTheWindowVouch() {
        let viewModel = makeViewModel()
        let session = makeSession(autoCompactWindow: 400_000)
        XCTAssertTrue(viewModel.ingestNonCodexUsageReport(
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
