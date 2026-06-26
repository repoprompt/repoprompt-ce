#if DEBUG
    import Foundation
    import MCP
    import SwiftUI

    struct AgentChatStressTelemetrySnapshot: Codable, Equatable {
        var sampleIndex: Int
        var timestamp: Date
        var tabID: UUID?
        var isPinnedToLiveBottom: Bool
        var userDetachedAutoFollow: Bool
        var canScrollTowardHistory: Bool
        var canScrollTowardLiveBottom: Bool
        var isNearBottom: Bool
        var distanceToBottom: CGFloat
        var topVisibleBlockID: String?
        var topVisibleAnchorDescription: String?
        var lastScrollIntentReason: String?
        var lastSettledBottomReason: String?
        var pendingPinnedBottomSourceDescription: String?
        var hasPendingPinnedBottomFlush: Bool
        var deferredPinnedCorrectionSourceDescription: String?
        var millisecondsSinceLastBottomSettle: Double?
        var scrollIntentCount: Int
        var detachCount: Int
        var repinCount: Int
        var unexpectedPinnedDriftCount: Int
        var maxUnexpectedPinnedDrift: CGFloat
        var unexpectedJumpCount: Int
        var maxUnexpectedJumpMagnitude: CGFloat
        var unexpectedHistoricalExposureCount: Int
        var maxUnexpectedHistoricalExposureBlocksBelowTop: Int
        var lastUnexpectedHistoricalExposureBlockID: String?
        var lastUnexpectedHistoricalExposureKind: String?
        var activeStreamingAssistantCharacterCount: Int
        var activeStreamingAssistantLineCount: Int
        var isLargeStreamingAssistantActive: Bool
        var largeStreamingPinnedJumpCount: Int
        var maxLargeStreamingPinnedJumpMagnitude: CGFloat
        var largeStreamingHistoricalExposureCount: Int
        var maxLargeStreamingHistoricalExposureBlocksBelowTop: Int
        var lastLargeStreamingHistoricalExposureBlockID: String?
        var lastLargeStreamingHistoricalExposureKind: String?
        var detachedJumpCount: Int
        var maxDetachedJumpMagnitude: CGFloat
        var detachedAnchorChangeCount: Int
        var detachedSnapToTopCount: Int
        var storedDetachedTargetDescription: String?
        var storedDetachedAnchorDescription: String?
        var storedDetachedViewportMinY: CGFloat?
        var liveDetachedTargetDescription: String?
        var liveDetachedViewportMinY: CGFloat?
        var detachedAcceptedDriftCount: Int
        var detachedRestoreIntentCount: Int
        var lastDetachedRebaseAction: String?
        var smoothSendScrollCount: Int
        var smoothSendStartCount: Int
        var smoothSendCompletionCount: Int
        var smoothSendFinishedWithoutAnimationCount: Int
        var smoothSendInterruptedCount: Int
        var smoothSendCorrectiveScrollCount: Int
        var lastSmoothSendSettleDurationMS: Double?
        var maxSmoothSendSettleDurationMS: Double?
        var detachedAuthorityAnchorDescription: String?
        var viewportFrameUpdateCount: Int
        var viewportCandidateUpdateCount: Int
        var projectionBuildCount: Int
        var projectionPublishCount: Int
        var lastProjectionBuildDurationMS: Double?
        var maxProjectionBuildDurationMS: Double?
        var lastColdLoadProjectionBuildDurationMS: Double?
        var refreshRequestCount: Int
        var refreshCoalescedCount: Int
        var refreshImmediateCount: Int
        var lastRefreshTotalDurationMS: Double?
        var maxRefreshTotalDurationMS: Double?
        var lastImportDurationMS: Double?
        var maxImportDurationMS: Double?
        var incrementalImportAttemptCount: Int
        var incrementalImportSuccessCount: Int
        var incrementalImportFallbackCount: Int
        var frontierReuseAttemptCount: Int
        var frontierReuseSuccessCount: Int
        var frontierReuseFallbackCount: Int
        var lastIncrementalImportDurationMS: Double?
        var maxIncrementalImportDurationMS: Double?
        var lastPayloadCaptureDurationMS: Double?
        var maxPayloadCaptureDurationMS: Double?
        var lastSanitizeDurationMS: Double?
        var maxSanitizeDurationMS: Double?
        var sanitizeReuseAttemptCount: Int
        var sanitizeReuseSuccessCount: Int
        var sanitizeReuseFallbackCount: Int
        var projectionReuseAttemptCount: Int
        var projectionReuseSuccessCount: Int
        var projectionReuseFallbackCount: Int
        var lastSourceItemCount: Int?
        var lastPayloadCaptureScannedItemCount: Int?
        var lastSanitizedActivityCount: Int?
        var lastSanitizeReusedTurnCount: Int?
        var lastProjectionReusedTurnCount: Int?
        var retainedRawPayloadEntryCount: Int
        var retainedRawPayloadTotalBytes: Int
        var coldRestoreStartCount: Int
        var coldRestoreScrollCount: Int
        var coldRestoreCorrectiveScrollCount: Int
        var coldRestoreCompletionCount: Int
        var lastColdRestoreSettleDurationMS: Double?
        var maxColdRestoreSettleDurationMS: Double?
        var manualScrollGestureCount: Int
        var manualScrollEffectCount: Int
        var manualScrollTowardHistoryGestureCount: Int
        var manualScrollTowardHistoryEffectCount: Int
        var manualScrollTowardLiveBottomGestureCount: Int
        var manualScrollTowardLiveBottomEffectCount: Int
        var manualScrollUnknownDirectionCount: Int
        var lastManualScrollDirection: String?
        var lastManualScrollOutcome: String?
        var scrollToBottomTapCount: Int
        var scrollToBottomSuccessCount: Int
        var scrollToBottomNoEffectCount: Int
        var lastScrollToBottomOutcome: String?
        var expandedApplyEditsCardCount: Int
        var expandedApplyEditsDiffPreviewCardCount: Int
        var expandedApplyEditsMarkdownFallbackCardCount: Int
        var expandedApplyPatchCardCount: Int
        var expandedApplyPatchDiffPreviewCardCount: Int
        var expandedApplyPatchMarkdownFallbackCardCount: Int
        var liveBashCardCount: Int
        var expandedLiveBashCardCount: Int
        var completedBashCardCount: Int
        var expandedCompletedBashCardCount: Int
        var latestExpandedHighSignalToolDescription: String?
        var latestExpandedHighSignalRenderMode: String?
        var supportsGeometryMetrics: Bool

        static let empty = AgentChatStressTelemetrySnapshot(
            sampleIndex: 0,
            timestamp: .distantPast,
            tabID: nil,
            isPinnedToLiveBottom: true,
            userDetachedAutoFollow: false,
            canScrollTowardHistory: false,
            canScrollTowardLiveBottom: false,
            isNearBottom: true,
            distanceToBottom: 0,
            topVisibleBlockID: nil,
            topVisibleAnchorDescription: nil,
            lastScrollIntentReason: nil,
            lastSettledBottomReason: nil,
            pendingPinnedBottomSourceDescription: nil,
            hasPendingPinnedBottomFlush: false,
            deferredPinnedCorrectionSourceDescription: nil,
            millisecondsSinceLastBottomSettle: nil,
            scrollIntentCount: 0,
            detachCount: 0,
            repinCount: 0,
            unexpectedPinnedDriftCount: 0,
            maxUnexpectedPinnedDrift: 0,
            unexpectedJumpCount: 0,
            maxUnexpectedJumpMagnitude: 0,
            unexpectedHistoricalExposureCount: 0,
            maxUnexpectedHistoricalExposureBlocksBelowTop: 0,
            lastUnexpectedHistoricalExposureBlockID: nil,
            lastUnexpectedHistoricalExposureKind: nil,
            activeStreamingAssistantCharacterCount: 0,
            activeStreamingAssistantLineCount: 0,
            isLargeStreamingAssistantActive: false,
            largeStreamingPinnedJumpCount: 0,
            maxLargeStreamingPinnedJumpMagnitude: 0,
            largeStreamingHistoricalExposureCount: 0,
            maxLargeStreamingHistoricalExposureBlocksBelowTop: 0,
            lastLargeStreamingHistoricalExposureBlockID: nil,
            lastLargeStreamingHistoricalExposureKind: nil,
            detachedJumpCount: 0,
            maxDetachedJumpMagnitude: 0,
            detachedAnchorChangeCount: 0,
            detachedSnapToTopCount: 0,
            storedDetachedTargetDescription: nil,
            storedDetachedAnchorDescription: nil,
            storedDetachedViewportMinY: nil,
            liveDetachedTargetDescription: nil,
            liveDetachedViewportMinY: nil,
            detachedAcceptedDriftCount: 0,
            detachedRestoreIntentCount: 0,
            lastDetachedRebaseAction: nil,
            smoothSendScrollCount: 0,
            smoothSendStartCount: 0,
            smoothSendCompletionCount: 0,
            smoothSendFinishedWithoutAnimationCount: 0,
            smoothSendInterruptedCount: 0,
            smoothSendCorrectiveScrollCount: 0,
            lastSmoothSendSettleDurationMS: nil,
            maxSmoothSendSettleDurationMS: nil,
            detachedAuthorityAnchorDescription: nil,
            viewportFrameUpdateCount: 0,
            viewportCandidateUpdateCount: 0,
            projectionBuildCount: 0,
            projectionPublishCount: 0,
            lastProjectionBuildDurationMS: nil,
            maxProjectionBuildDurationMS: nil,
            lastColdLoadProjectionBuildDurationMS: nil,
            refreshRequestCount: 0,
            refreshCoalescedCount: 0,
            refreshImmediateCount: 0,
            lastRefreshTotalDurationMS: nil,
            maxRefreshTotalDurationMS: nil,
            lastImportDurationMS: nil,
            maxImportDurationMS: nil,
            incrementalImportAttemptCount: 0,
            incrementalImportSuccessCount: 0,
            incrementalImportFallbackCount: 0,
            frontierReuseAttemptCount: 0,
            frontierReuseSuccessCount: 0,
            frontierReuseFallbackCount: 0,
            lastIncrementalImportDurationMS: nil,
            maxIncrementalImportDurationMS: nil,
            lastPayloadCaptureDurationMS: nil,
            maxPayloadCaptureDurationMS: nil,
            lastSanitizeDurationMS: nil,
            maxSanitizeDurationMS: nil,
            sanitizeReuseAttemptCount: 0,
            sanitizeReuseSuccessCount: 0,
            sanitizeReuseFallbackCount: 0,
            projectionReuseAttemptCount: 0,
            projectionReuseSuccessCount: 0,
            projectionReuseFallbackCount: 0,
            lastSourceItemCount: nil,
            lastPayloadCaptureScannedItemCount: nil,
            lastSanitizedActivityCount: nil,
            lastSanitizeReusedTurnCount: nil,
            lastProjectionReusedTurnCount: nil,
            retainedRawPayloadEntryCount: 0,
            retainedRawPayloadTotalBytes: 0,
            coldRestoreStartCount: 0,
            coldRestoreScrollCount: 0,
            coldRestoreCorrectiveScrollCount: 0,
            coldRestoreCompletionCount: 0,
            lastColdRestoreSettleDurationMS: nil,
            maxColdRestoreSettleDurationMS: nil,
            manualScrollGestureCount: 0,
            manualScrollEffectCount: 0,
            manualScrollTowardHistoryGestureCount: 0,
            manualScrollTowardHistoryEffectCount: 0,
            manualScrollTowardLiveBottomGestureCount: 0,
            manualScrollTowardLiveBottomEffectCount: 0,
            manualScrollUnknownDirectionCount: 0,
            lastManualScrollDirection: nil,
            lastManualScrollOutcome: nil,
            scrollToBottomTapCount: 0,
            scrollToBottomSuccessCount: 0,
            scrollToBottomNoEffectCount: 0,
            lastScrollToBottomOutcome: nil,
            expandedApplyEditsCardCount: 0,
            expandedApplyEditsDiffPreviewCardCount: 0,
            expandedApplyEditsMarkdownFallbackCardCount: 0,
            expandedApplyPatchCardCount: 0,
            expandedApplyPatchDiffPreviewCardCount: 0,
            expandedApplyPatchMarkdownFallbackCardCount: 0,
            liveBashCardCount: 0,
            expandedLiveBashCardCount: 0,
            completedBashCardCount: 0,
            expandedCompletedBashCardCount: 0,
            latestExpandedHighSignalToolDescription: nil,
            latestExpandedHighSignalRenderMode: nil,
            supportsGeometryMetrics: false
        )
    }

    struct AgentChatStressGroupingSnapshot: Codable, Equatable {
        var sampleIndex: Int
        var visibleBlockKindCounts: [String: Int]
        var workingBlockKindCounts: [String: Int]
        var archivedBlockKindCounts: [String: Int]
        var visibleStandaloneToolNameCounts: [String: Int]
        var latestVisibleStandaloneToolNames: [String]
        var latestClusterTitle: String?
        var latestGroupedHistoryTitle: String?
        var latestToolGroupLabels: [String]

        static let empty = AgentChatStressGroupingSnapshot(
            sampleIndex: 0,
            visibleBlockKindCounts: [:],
            workingBlockKindCounts: [:],
            archivedBlockKindCounts: [:],
            visibleStandaloneToolNameCounts: [:],
            latestVisibleStandaloneToolNames: [],
            latestClusterTitle: nil,
            latestGroupedHistoryTitle: nil,
            latestToolGroupLabels: []
        )
    }

    @MainActor
    final class AgentChatStressHarness: ObservableObject {
        static let forceDetachRequestedNotification = Notification.Name("AgentChatStressHarness.forceDetachRequested")
        enum Status: Equatable {
            case idle
            case bootstrapping
            case running
            case paused
            case failed(String)

            var label: String {
                switch self {
                case .idle:
                    "Idle"
                case .bootstrapping:
                    "Bootstrapping"
                case .running:
                    "Running"
                case .paused:
                    "Paused"
                case let .failed(message):
                    "Failed: \(message)"
                }
            }
        }

        enum MockTranscriptRole {
            case user
            case assistant
            case assistantInline
            case thinking
            case system
        }

        private enum ScenarioToolStep {
            case repoPromptTool(
                toolName: String,
                args: [String: Value],
                resultJSON: String,
                isError: Bool
            )
            case liveBash(
                command: String,
                processID: String,
                initialResultJSON: String,
                outputChunks: [String],
                finalResultJSON: String,
                isError: Bool
            )

            static func toolCall(
                _ toolName: String,
                argsJSON: String,
                resultJSON: String,
                isError: Bool = false
            ) -> Self {
                .repoPromptTool(
                    toolName: toolName,
                    args: Value.objectFromJSONString(argsJSON) ?? ["raw": .string(argsJSON)],
                    resultJSON: resultJSON,
                    isError: isError
                )
            }

            static func repoPromptTool(
                _ toolName: String,
                args: [String: Value],
                resultJSON: String,
                isError: Bool = false
            ) -> Self {
                .repoPromptTool(
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError
                )
            }
        }

        private struct ScenarioBatch {
            let title: String
            let includeUserTurn: Bool
            let userText: String?
            let preamble: [(MockTranscriptRole, String)]
            let toolSteps: [ScenarioToolStep]
            let intermittentMessages: [(MockTranscriptRole, String)]
            let assistantText: String
        }

        private struct StreamingOverlapLiveBash {
            let command: String
            let processID: String
            let initialResultJSON: String
            let outputChunks: [String]
            let finalResultJSON: String
        }

        private static let finalAssistantOverlapBashAssistantChunkStride = 4
        private static let finalAssistantOverlapBashChunkCount = 120

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()

        private static let persistedCodexReplayBashFixtureName = "codexlogs-live-bash-test-1-mirrored-deltas.jsonl"
        private static let persistedCodexReplayBashFixtureThreadID = "019c81fc-a7bd-7ce1-abe1-cfc05f6bb895"

        let configuration: AgentChatStressLaunchConfiguration
        unowned let agentModeViewModel: AgentModeViewModel
        unowned let promptManager: PromptViewModel
        unowned let workspaceManager: WorkspaceManagerViewModel
        let windowID: Int

        @Published private(set) var status: Status = .idle
        @Published private(set) var telemetry: AgentChatStressTelemetrySnapshot = .empty
        @Published private(set) var grouping: AgentChatStressGroupingSnapshot = .empty
        @Published private(set) var recentEvents: [String] = []

        private var targetTabID: UUID?
        private var persistedReplaySessionID: UUID?
        private var scenarioTask: Task<Void, Never>?
        private var scenarioCursor = 0
        private var autoStarted = false
        private var hasLoggedComposeTabWait = false
        private var hasLoggedWorkspaceWait = false

        private var usesUrgentMutationRefresh: Bool {
            configuration.mutationRefreshPolicy == .urgentPerMutation
        }

        init(
            configuration: AgentChatStressLaunchConfiguration,
            agentModeViewModel: AgentModeViewModel,
            promptManager: PromptViewModel,
            workspaceManager: WorkspaceManagerViewModel,
            windowID: Int
        ) {
            self.configuration = configuration
            self.agentModeViewModel = agentModeViewModel
            self.promptManager = promptManager
            self.workspaceManager = workspaceManager
            self.windowID = windowID
        }

        var statusText: String {
            status.label
        }

        var telemetryJSONString: String {
            encode(telemetry) ?? "{}"
        }

        var groupingJSONString: String {
            encode(grouping) ?? "{}"
        }

        var recentEventsText: String {
            recentEvents.joined(separator: "\n")
        }

        func bootstrapIfNeeded(currentTabID: UUID?) {
            guard configuration.autoStart else { return }
            guard status != .bootstrapping, status != .running else { return }
            if let requiredWorkspaceName = configuration.workspaceName,
               workspaceManager.activeWorkspace?.name != requiredWorkspaceName
            {
                if !hasLoggedWorkspaceWait {
                    hasLoggedWorkspaceWait = true
                    note("Waiting for workspace \(requiredWorkspaceName) before auto-start")
                }
                return
            }
            hasLoggedWorkspaceWait = false
            guard let currentTabID = currentTabID ?? promptManager.activeComposeTabID else {
                if !hasLoggedComposeTabWait {
                    hasLoggedComposeTabWait = true
                    note("Waiting for compose tab before auto-start")
                }
                return
            }
            hasLoggedComposeTabWait = false
            autoStarted = true
            start(currentTabID: currentTabID)
        }

        func start(currentTabID: UUID?) {
            scenarioTask?.cancel()
            scenarioCursor = 0
            persistedReplaySessionID = nil
            hasLoggedComposeTabWait = false
            hasLoggedWorkspaceWait = false
            status = .bootstrapping
            note("Starting stress harness")
            scenarioTask = Task { [weak self] in
                guard let self else { return }
                if configuration.scenario == .persistedCodexReplayChurn {
                    await bootstrapPersistedCodexReplayScenario(preferredTabID: currentTabID)
                    return
                }
                if configuration.scenario == .persistedAgentSessionFixture {
                    await bootstrapPersistedAgentSessionFixtureScenario(preferredTabID: currentTabID)
                    return
                }
                let tabID = await resolveTargetTabID(preferred: currentTabID)
                guard !Task.isCancelled else { return }
                guard let tabID else {
                    status = .failed("No compose tab available")
                    note("Unable to acquire a compose tab")
                    return
                }
                targetTabID = tabID
                await agentModeViewModel.testResetStressTranscript(tabID: tabID)
                await agentModeViewModel.testPrepareStressSession(tabID: tabID)
                await seedWarmup(on: tabID)
                beginLoop(on: tabID)
            }
        }

        func pause() {
            scenarioTask?.cancel()
            scenarioTask = nil
            if case .failed = status {
                return
            }
            status = .paused
            note("Paused stress harness")
        }

        func resume(currentTabID: UUID?) {
            guard status == .paused || status == .idle else { return }
            if configuration.scenario == .persistedAgentSessionFixture {
                note("Persisted agent session fixture scenario remains idle")
                status = .paused
                return
            }
            guard let tabID = currentTabID ?? targetTabID else {
                start(currentTabID: currentTabID)
                return
            }
            targetTabID = tabID
            note("Resuming stress harness")
            beginLoop(on: tabID)
        }

        func reset(currentTabID: UUID?) {
            scenarioTask?.cancel()
            scenarioTask = nil
            scenarioCursor = 0
            persistedReplaySessionID = nil
            hasLoggedComposeTabWait = false
            hasLoggedWorkspaceWait = false
            telemetry = .empty
            grouping = .empty
            recentEvents = []
            status = .idle
            note("Reset stress harness")
            Task { [weak self] in
                guard let self else { return }
                if let tabID = await resolveTargetTabID(preferred: currentTabID ?? targetTabID) {
                    targetTabID = tabID
                    await agentModeViewModel.testResetStressTranscript(tabID: tabID)
                }
                if configuration.autoStart {
                    start(currentTabID: currentTabID)
                }
            }
        }

        func recordScrollSnapshot(_ snapshot: AgentChatStressTelemetrySnapshot) {
            telemetry = snapshot
        }

        func recordGroupingSnapshot(_ snapshot: AgentChatStressGroupingSnapshot) {
            grouping = snapshot
        }

        func note(_ message: String) {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            recentEvents.append("[\(timestamp)] \(message)")
            if recentEvents.count > configuration.maxVisibleEventLogEntries {
                recentEvents.removeFirst(recentEvents.count - configuration.maxVisibleEventLogEntries)
            }
        }

        func requestForceDetach() {
            note("Force detach requested from stress panel")
            NotificationCenter.default.post(name: Self.forceDetachRequestedNotification, object: self)
        }

        private func resolveTargetTabID(preferred: UUID?) async -> UUID? {
            if let preferred {
                _ = await promptManager.ensureActiveComposeTab(preferred)
                return preferred
            }
            if let current = promptManager.activeComposeTabID {
                return current
            }
            let tab = await promptManager.ensureActiveComposeTab(nil, creationStrategy: .blank, name: "Stress Harness")
            return tab?.id
        }

        private func seedWarmup(on tabID: UUID) async {
            guard configuration.warmupTurnCount > 0 else { return }
            for _ in 0 ..< configuration.warmupTurnCount {
                await appendNextBatch(on: tabID, isWarmup: true)
            }
        }

        private func beginLoop(on tabID: UUID) {
            scenarioTask?.cancel()
            status = .running
            note("Loop active on tab \(String(tabID.uuidString.prefix(8)))")
            scenarioTask = Task { [weak self] in
                await self?.runScenarioLoop(on: tabID)
            }
        }

        private func runScenarioLoop(on tabID: UUID) async {
            while !Task.isCancelled {
                await appendNextBatch(on: tabID, isWarmup: false)
                do {
                    try await Task.sleep(nanoseconds: UInt64(configuration.insertionInterval * 1_000_000_000))
                } catch {
                    break
                }
            }
            if case .running = status {
                status = .paused
            }
        }

        private func appendNextBatch(on tabID: UUID, isWarmup: Bool) async {
            if configuration.scenario == .persistedCodexReplayChurn {
                await appendPersistedCodexReplayChurn(on: tabID, isWarmup: isWarmup)
                return
            }
            if configuration.scenario == .assistantMarkdownChurn {
                await appendAssistantMarkdownChurn(on: tabID, isWarmup: isWarmup)
                return
            }
            if configuration.scenario == .assistantMarkdownMegaChurn {
                await appendAssistantMarkdownMegaChurn(on: tabID, isWarmup: isWarmup)
                return
            }
            let batch = scenarioBatches[scenarioCursor % scenarioBatches.count]
            scenarioCursor += 1
            note("Appending batch: \(batch.title)")
            if configuration.scenario == .richToolChurn {
                agentModeViewModel.testSetStressRunState(
                    tabID: tabID,
                    state: .running,
                    statusText: "Rich stress turn running",
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
            }
            if batch.includeUserTurn, let userText = batch.userText {
                agentModeViewModel.testAppendMockTranscriptMessage(
                    tabID: tabID,
                    role: .user,
                    text: userText,
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
            }
            for (role, text) in batch.preamble {
                agentModeViewModel.testAppendMockTranscriptMessage(
                    tabID: tabID,
                    role: role.toViewModelRole,
                    text: text,
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
            }
            for repeatIndex in 0 ..< configuration.toolStepRepeatCount {
                for (stepIndex, step) in batch.toolSteps.enumerated() {
                    await execute(step: step, on: tabID, isWarmup: isWarmup)
                    guard configuration.toolStepRepeatCount > 1,
                          !batch.intermittentMessages.isEmpty,
                          (stepIndex + 1).isMultiple(of: 2) else { continue }
                    let messageIndex = ((repeatIndex * batch.toolSteps.count) + stepIndex) % batch.intermittentMessages.count
                    let message = batch.intermittentMessages[messageIndex]
                    let progressText = configuration.toolStepRepeatCount > 2
                        ? "[pass \(repeatIndex + 1)] \(message.1)"
                        : message.1
                    agentModeViewModel.testAppendMockTranscriptMessage(
                        tabID: tabID,
                        role: message.0.toViewModelRole,
                        text: progressText,
                        urgentUIRefresh: usesUrgentMutationRefresh
                    )
                }
            }
            agentModeViewModel.testAppendMockTranscriptMessage(
                tabID: tabID,
                role: .assistant,
                text: batch.assistantText,
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            if configuration.scenario == .richToolChurn {
                agentModeViewModel.testSetStressRunState(
                    tabID: tabID,
                    state: .completed,
                    statusText: "Rich stress turn complete",
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
            } else {
                agentModeViewModel.testSetStressRunState(
                    tabID: tabID,
                    state: .running,
                    statusText: "Stress harness running",
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
            }
        }

        private var scenarioBatches: [ScenarioBatch] {
            switch configuration.scenario {
            case .mixedToolLoop:
                mixedScenarioBatches
            case .richToolChurn, .persistedCodexReplayChurn, .persistedAgentSessionFixture:
                richScenarioBatches
            case .assistantMarkdownChurn, .assistantMarkdownMegaChurn:
                richScenarioBatches
            }
        }

        private func execute(step: ScenarioToolStep, on tabID: UUID, isWarmup: Bool) async {
            switch step {
            case let .repoPromptTool(toolName, args, resultJSON, isError):
                if configuration.scenario == .richToolChurn {
                    switch toolName {
                    case "apply_edits":
                        note("payload=applyEditsRich")
                    case "apply_patch":
                        note("payload=applyPatchRich")
                    default:
                        break
                    }
                }
                let invocationID = UUID()
                agentModeViewModel.testSimulateCodexRepoPromptToolCall(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args
                )
                agentModeViewModel.testSimulateCodexRepoPromptToolResult(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError
                )
                if configuration.scenario == .richToolChurn {
                    switch toolName {
                    case "apply_edits":
                        note("payload=applyEditsRichApplied")
                    case "apply_patch":
                        note("payload=applyPatchRichApplied")
                    default:
                        break
                    }
                }
            case let .liveBash(command, processID, initialResultJSON, outputChunks, finalResultJSON, isError):
                let invocationID = UUID()
                let args: [String: Value] = ["cmd": .string(command)]
                note("payload=bashLiveBurst pid=\(processID) chunks=\(outputChunks.count)")
                agentModeViewModel.testSimulateCodexRepoPromptToolCall(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: "bash",
                    args: args
                )
                agentModeViewModel.testSimulateCodexRepoPromptToolResult(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: "bash",
                    args: args,
                    resultJSON: initialResultJSON,
                    isError: false
                )
                let chunkDelayNanos = richBashChunkDelayNanos(isWarmup: isWarmup)
                for (chunkIndex, chunk) in outputChunks.enumerated() {
                    await agentModeViewModel.testSimulateCodexBashRunningUpdate(
                        tabID: tabID,
                        invocationID: invocationID,
                        processID: processID,
                        appendedOutput: chunk,
                        sealsAssistantBoundary: chunkIndex == 0
                    )
                    if chunkIndex == 0 {
                        note("payload=bashLiveBurstLive pid=\(processID)")
                    }
                    guard chunkDelayNanos > 0 else { continue }
                    try? await Task.sleep(nanoseconds: chunkDelayNanos)
                }
                if chunkDelayNanos > 0 {
                    try? await Task.sleep(nanoseconds: chunkDelayNanos)
                }
                agentModeViewModel.testSimulateCodexRepoPromptToolResult(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: "bash",
                    args: args,
                    resultJSON: finalResultJSON,
                    isError: isError
                )
                note("payload=bashLiveBurstCompleted pid=\(processID)")
            }
        }

        private func richBashChunkDelayNanos(isWarmup: Bool) -> UInt64 {
            let seconds: TimeInterval = if isWarmup {
                0.015
            } else {
                max(0.11, min(0.14, configuration.insertionInterval * 1.35))
            }
            return UInt64(seconds * 1_000_000_000)
        }

        private func bootstrapPersistedCodexReplayScenario(preferredTabID: UUID?) async {
            do {
                guard let playbackTab = await promptManager.createBackgroundComposeTab(
                    strategy: .blank,
                    name: "Stress Persisted Replay"
                ) else {
                    status = .failed("No playback tab available")
                    note("Persisted replay setup failed: unable to create playback tab")
                    return
                }
                let playbackTabID = playbackTab.id
                targetTabID = playbackTabID
                note("persistedCodexReplayPlaybackTabCreated tab=\(String(playbackTabID.uuidString.prefix(8)))")

                let session = makePersistedCodexReplaySession(for: playbackTabID)
                let stagedSession = try await agentModeViewModel.testStagePersistedStressSession(
                    tabID: playbackTabID,
                    agentSession: session
                )
                persistedReplaySessionID = stagedSession.id
                note(
                    "persistedCodexReplayFixturePrepared session=\(String(stagedSession.id.uuidString.prefix(8))) tab=\(String(playbackTabID.uuidString.prefix(8))) items=\(stagedSession.items.count) visibleRows=\(stagedSession.effectiveItemCount)"
                )

                if let preferredTabID, preferredTabID != playbackTabID,
                   preferredTabID == promptManager.activeComposeTabID
                {
                    note("persistedCodexReplayPreservedSourceTab tab=\(String(preferredTabID.uuidString.prefix(8)))")
                }

                await promptManager.switchComposeTab(playbackTabID)
                note("persistedCodexReplaySwitchToPlaybackTab tab=\(String(playbackTabID.uuidString.prefix(8)))")

                guard await waitForPersistedCodexReplayRestore(tabID: playbackTabID) else {
                    status = .failed("Persisted replay restore timed out")
                    note("Persisted replay restore timed out for tab \(String(playbackTabID.uuidString.prefix(8)))")
                    return
                }

                note(
                    "persistedCodexReplayRestoreReady session=\(String(stagedSession.id.uuidString.prefix(8))) tab=\(String(playbackTabID.uuidString.prefix(8)))"
                )
                beginLoop(on: playbackTabID)
            } catch {
                status = .failed("Persisted replay setup failed")
                note("Persisted replay setup failed: \(error.localizedDescription)")
            }
        }

        private func waitForPersistedCodexReplayRestore(tabID: UUID) async -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard !Task.isCancelled else { return false }
                let isActivePlaybackTab = promptManager.activeComposeTabID == tabID && agentModeViewModel.currentTabID == tabID
                let hasHydratedBindings = agentModeViewModel.activeSessionBindingsAreHydrated
                let hasTranscriptContent = !agentModeViewModel.transcriptItems.isEmpty
                let sessionMatches = agentModeViewModel.activeSession?.activeAgentSessionID == persistedReplaySessionID
                let settledTelemetry = telemetry.tabID == tabID
                    && telemetry.coldRestoreStartCount > 0
                    && telemetry.coldRestoreCompletionCount > 0
                    && telemetry.isPinnedToLiveBottom
                    && !telemetry.userDetachedAutoFollow
                    && telemetry.distanceToBottom <= 40
                if isActivePlaybackTab, hasHydratedBindings, hasTranscriptContent, sessionMatches, settledTelemetry {
                    return true
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        private func bootstrapPersistedAgentSessionFixtureScenario(preferredTabID: UUID?) async {
            do {
                guard let fixtureName = configuration.agentSessionFixtureName else {
                    status = .failed("No persisted agent session fixture configured")
                    note("Persisted agent session fixture setup failed: missing fixture name")
                    return
                }
                guard let playbackTab = await promptManager.createBackgroundComposeTab(
                    strategy: .blank,
                    name: "Stress Agent Session Fixture"
                ) else {
                    status = .failed("No playback tab available")
                    note("Persisted agent session fixture setup failed: unable to create playback tab")
                    return
                }
                let playbackTabID = playbackTab.id
                targetTabID = playbackTabID
                note(
                    "persistedAgentSessionFixtureLoading fixture=\(fixtureName) tab=\(String(playbackTabID.uuidString.prefix(8)))"
                )

                let stagedSession = try await agentModeViewModel.testStagePersistedStressSession(
                    tabID: playbackTabID,
                    fixtureNamed: fixtureName,
                    workspaceRootPaths: configuration.workspaceRootPaths
                )
                persistedReplaySessionID = stagedSession.id
                note(
                    "persistedAgentSessionFixturePrepared session=\(String(stagedSession.id.uuidString.prefix(8))) fixture=\(fixtureName) tab=\(String(playbackTabID.uuidString.prefix(8))) items=\(stagedSession.items.count) visibleRows=\(stagedSession.effectiveItemCount)"
                )

                if let preferredTabID, preferredTabID != playbackTabID,
                   preferredTabID == promptManager.activeComposeTabID
                {
                    note("persistedAgentSessionFixturePreservedSourceTab tab=\(String(preferredTabID.uuidString.prefix(8)))")
                }

                await promptManager.switchComposeTab(playbackTabID)
                note("persistedAgentSessionFixtureSwitchToPlaybackTab tab=\(String(playbackTabID.uuidString.prefix(8)))")

                guard await waitForPersistedAgentSessionFixtureRestore(
                    tabID: playbackTabID,
                    sessionID: stagedSession.id
                ) else {
                    status = .failed("Persisted agent session fixture restore timed out")
                    note("Persisted agent session fixture restore timed out for tab \(String(playbackTabID.uuidString.prefix(8)))")
                    return
                }

                note(
                    "persistedAgentSessionFixtureRestoreReady session=\(String(stagedSession.id.uuidString.prefix(8))) fixture=\(fixtureName) tab=\(String(playbackTabID.uuidString.prefix(8)))"
                )
                status = .paused
            } catch {
                status = .failed("Persisted agent session fixture setup failed")
                note("Persisted agent session fixture setup failed: \(error.localizedDescription)")
            }
        }

        private func waitForPersistedAgentSessionFixtureRestore(
            tabID: UUID,
            sessionID: UUID
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                guard !Task.isCancelled else { return false }
                let isActivePlaybackTab = promptManager.activeComposeTabID == tabID && agentModeViewModel.currentTabID == tabID
                let hasHydratedBindings = agentModeViewModel.activeSessionBindingsAreHydrated
                let hasTranscriptContent = !agentModeViewModel.transcriptItems.isEmpty
                let sessionMatches = agentModeViewModel.activeSession?.activeAgentSessionID == sessionID
                let settledTelemetry = telemetry.tabID == tabID
                    && (telemetry.coldRestoreStartCount ?? 0) > 0
                    && (telemetry.coldRestoreCompletionCount ?? 0) > 0
                    && (telemetry.projectionBuildCount ?? 0) > 0
                    && (telemetry.projectionPublishCount ?? 0) > 0
                    && telemetry.isPinnedToLiveBottom
                    && !telemetry.userDetachedAutoFollow
                    && telemetry.distanceToBottom <= 40
                if isActivePlaybackTab, hasHydratedBindings, hasTranscriptContent, sessionMatches, settledTelemetry {
                    return true
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        private func makePersistedCodexReplaySession(for tabID: UUID) -> AgentSession {
            let sessionID = UUID()
            let conversationID = "stress-codex-thread-\(String(sessionID.uuidString.prefix(8)).lowercased())"
            let modelRaw = AgentModelCatalog.defaultModelRaw(for: .codexExec)
            let reasoningEffort = "medium"
            var items: [AgentChatItem] = []
            var nextSequenceIndex = 0
            let restoredTurnCount = max(8, configuration.warmupTurnCount * 3)
            for turnIndex in 0 ..< restoredTurnCount {
                appendPersistedReplayHistoricalTurn(
                    turnIndex: turnIndex,
                    to: &items,
                    nextSequenceIndex: &nextSequenceIndex
                )
            }
            let transcript = AgentTranscriptIO.buildTranscript(
                from: items,
                terminalState: .completed,
                nextSequenceIndex: nextSequenceIndex,
                policy: .liveSession(hidePendingQuestionToolCall: false)
            )
            let lastUserMessageAt = items.reversed().first(where: { $0.kind == .user })?.timestamp
            return AgentSession(
                id: sessionID,
                workspaceID: nil,
                composeTabID: tabID,
                name: "Stress Persisted Codex Replay",
                savedAt: Date().addingTimeInterval(-300),
                items: items.map { AgentChatItemPersist(from: $0) },
                transcript: transcript,
                itemCount: AgentTranscriptProjectionBuilder.projectedVisibleRowCount(for: transcript),
                lastUserMessageAt: lastUserMessageAt,
                agentKind: AgentProviderKind.codexExec.rawValue,
                agentModel: modelRaw,
                agentReasoningEffort: reasoningEffort,
                lastRunState: AgentSessionRunState.completed.rawValue,
                providerSessionID: "stress-provider-\(String(sessionID.uuidString.prefix(8)).lowercased())",
                autoEditEnabled: true,
                providerTokenUsageByTurn: [],
                codexConversationID: conversationID,
                codexRolloutPath: nil,
                codexModel: modelRaw,
                codexReasoningEffort: reasoningEffort,
                codexContextWindow: 200_000,
                codexLastTotalTokens: 78000,
                codexTotalTotalTokens: 188_000,
                codexMcpSessionKey: "stress-mcp-\(String(sessionID.uuidString.prefix(8)).lowercased())"
            )
        }

        private func appendPersistedReplayHistoricalTurn(
            turnIndex: Int,
            to items: inout [AgentChatItem],
            nextSequenceIndex: inout Int
        ) {
            let batch = richScenarioBatches[turnIndex % richScenarioBatches.count]
            let userText = batch.includeUserTurn
                ? (batch.userText ?? "Continue the Codex investigation and preserve the heavy tool transcript shape.")
                : "Continue turn \(turnIndex + 1) of the restored Codex investigation and summarize the concrete evidence."
            items.append(.user("[restored turn \(turnIndex + 1)] \(userText)", sequenceIndex: nextSequenceIndex))
            nextSequenceIndex += 1
            for (role, text) in batch.preamble {
                items.append(makePersistedReplayMessage(role: role, text: text, sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
            }
            for repeatIndex in 0 ..< configuration.toolStepRepeatCount {
                for (stepIndex, step) in batch.toolSteps.enumerated() {
                    appendPersistedReplayToolStep(step, repeatIndex: repeatIndex, stepIndex: stepIndex, to: &items, nextSequenceIndex: &nextSequenceIndex)
                    guard configuration.toolStepRepeatCount > 1,
                          !batch.intermittentMessages.isEmpty,
                          (stepIndex + 1).isMultiple(of: 2) else { continue }
                    let messageIndex = ((repeatIndex * batch.toolSteps.count) + stepIndex) % batch.intermittentMessages.count
                    let message = batch.intermittentMessages[messageIndex]
                    items.append(makePersistedReplayMessage(role: message.0, text: message.1, sequenceIndex: nextSequenceIndex))
                    nextSequenceIndex += 1
                }
            }
            items.append(
                .assistant(
                    persistedReplayHistoricalAssistantSummary(turnIndex: turnIndex, batch: batch),
                    sequenceIndex: nextSequenceIndex
                )
            )
            nextSequenceIndex += 1
        }

        private func makePersistedReplayMessage(
            role: MockTranscriptRole,
            text: String,
            sequenceIndex: Int
        ) -> AgentChatItem {
            switch role {
            case .user:
                .user(text, sequenceIndex: sequenceIndex)
            case .assistant:
                .assistant(text, sequenceIndex: sequenceIndex)
            case .assistantInline:
                .assistantInline(text, sequenceIndex: sequenceIndex)
            case .thinking:
                .thinking(text, sequenceIndex: sequenceIndex)
            case .system:
                .system(text, sequenceIndex: sequenceIndex)
            }
        }

        private func appendPersistedReplayToolStep(
            _ step: ScenarioToolStep,
            repeatIndex: Int,
            stepIndex: Int,
            to items: inout [AgentChatItem],
            nextSequenceIndex: inout Int
        ) {
            switch step {
            case let .repoPromptTool(toolName, _, resultJSON, isError):
                let invocationID = UUID()
                items.append(.toolCall(name: toolName, invocationID: invocationID, argsJSON: nil, sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
                items.append(.toolResult(name: toolName, invocationID: invocationID, resultJSON: resultJSON, isError: isError, sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
            case let .liveBash(command, _, _, _, finalResultJSON, isError):
                let invocationID = UUID()
                let escapedCommand = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                items.append(.toolCall(name: "bash", invocationID: invocationID, argsJSON: "{\"cmd\":\"\(escapedCommand)\"}", sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
                items.append(.toolResult(name: "bash", invocationID: invocationID, resultJSON: finalResultJSON, isError: isError, sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
                items.append(.assistantInline("Captured terminal burst \(repeatIndex + 1).\(stepIndex + 1) and retained the completed bash card in restored history.", sequenceIndex: nextSequenceIndex))
                nextSequenceIndex += 1
            }
        }

        private func persistedReplayHistoricalAssistantSummary(turnIndex: Int, batch: ScenarioBatch) -> String {
            """
            ## Restored Codex turn \(turnIndex + 1): \(batch.title)

            This restored turn is intentionally dense. It keeps the transcript in the same heavy shape users report in production: long assistant prose, expanded tool cards, and enough prior activity that the scroll container has to manage archived and working history together.

            ### Evidence captured
            - The turn contains concrete tool activity with patch- and bash-like payloads.
            - The assistant concludes with a structured markdown summary instead of a short one-line completion.
            - The content is realistic enough to exercise the same rich markdown path used by streamed provider output.

            1. Preserve the rendered transcript shape after restore.
            2. Keep the latest heavy cards in the recent history stack.
            3. Make the next streamed turn large enough to stress pinned-bottom maintenance.

            ```swift
            struct RestoredReplayTurn\(turnIndex + 1) {
            	let title: String
            	let restoredToolPayloads: Int
            	let keepsRichMarkdownVisible: Bool
            }

            let restoredTurn = RestoredReplayTurn\(turnIndex + 1)(
            	title: "\(batch.title)",
            	restoredToolPayloads: \(max(1, batch.toolSteps.count * max(1, configuration.toolStepRepeatCount))),
            	keepsRichMarkdownVisible: true
            )
            ```

            Conclusion: the restored baseline is intentionally large and realistic so the next live replay turn can expose mid-stream pinned jumps without relying on a tiny synthetic thread.
            """
        }

        private func appendPersistedCodexReplayChurn(on tabID: UUID, isWarmup: Bool) async {
            let batchNumber = scenarioCursor + 1
            scenarioCursor += 1
            let turnID = "persisted-replay-turn-\(batchNumber)"
            let userPrompt = persistedReplayTurnPrompt(batchNumber: batchNumber)
            let editStep = richApplyEditsStep(
                path: "RepoPrompt/Views/Common/Markdown/MarkdownTextView.swift",
                note: "Coalesced streaming markdown updates while preserving the final attributed render.",
                hunkSeed: 300 + batchNumber
            )
            let patchStep = richApplyPatchStep(
                paths: [
                    "RepoPrompt/Views/AgentMode/AgentModeView.swift",
                    "RepoPromptUITests/RepoPromptUITests.swift",
                    "docs/investigations/agent-transcript-detached-stability-2026-03-11.md"
                ],
                seed: 500 + batchNumber
            )
            let liveBashStep = richLiveBashStep(
                command: "xcodetester test --only-testing RepoPromptUITests/RepoPromptUITests/testAgentChatStressHarnessPersistedCodexReplayDoesNotExposeHistoricalContentWhilePinned",
                processID: "41\(String(format: "%03d", batchNumber))",
                label: "persisted-codex-replay-\(batchNumber)",
                chunkCount: 5
            )

            note("Appending batch: persisted-codex-replay-\(batchNumber)")
            agentModeViewModel.testSetStressRunState(
                tabID: tabID,
                state: .running,
                statusText: "Persisted Codex replay running #\(batchNumber)",
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            agentModeViewModel.testAppendMockTranscriptMessage(
                tabID: tabID,
                role: .user,
                text: userPrompt,
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            note("persistedCodexReplayStreamStart#\(batchNumber)")
            await agentModeViewModel.testReplayCodexNativeEvent(tabID: tabID, event: .turnStarted(turnID: turnID))

            for (chunkIndex, chunk) in persistedReplayAssistantIntroChunks(batchNumber: batchNumber).enumerated() {
                await agentModeViewModel.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta(chunk))
                let delay = persistedCodexReplayDelayNanos(stepIndex: chunkIndex, isWarmup: isWarmup)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            await replayPersistedCodexToolStep(editStep, on: tabID, stepOffset: 0, isWarmup: isWarmup)
            await replayPersistedCodexToolStep(patchStep, on: tabID, stepOffset: 1, isWarmup: isWarmup)
            await replayPersistedCodexToolStep(liveBashStep, on: tabID, stepOffset: 2, isWarmup: isWarmup)

            var cumulativeStreamingSummary = persistedReplayAssistantIntroChunks(batchNumber: batchNumber).joined()
            var didEmitLargeWindowStart = false
            for (chunkIndex, chunk) in persistedReplayAssistantSummaryChunks(batchNumber: batchNumber).enumerated() {
                cumulativeStreamingSummary.append(chunk)
                await agentModeViewModel.testReplayCodexNativeEvent(tabID: tabID, event: .assistantDelta(chunk))
                if !didEmitLargeWindowStart,
                   Self.isLargeStreamingMarkdown(text: cumulativeStreamingSummary)
                {
                    didEmitLargeWindowStart = true
                    note(
                        "persistedCodexReplayLargeWindowStart#\(batchNumber) chars=\(cumulativeStreamingSummary.count) lines=\(Self.lineCount(in: cumulativeStreamingSummary))"
                    )
                }
                let delay = persistedCodexReplayDelayNanos(stepIndex: chunkIndex + 8, isWarmup: isWarmup)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }

            await agentModeViewModel.testReplayCodexNativeEvent(
                tabID: tabID,
                event: .turnCompleted(turnID: turnID, status: .completed)
            )
            if didEmitLargeWindowStart {
                note(
                    "persistedCodexReplayLargeWindowEnd#\(batchNumber) chars=\(cumulativeStreamingSummary.count) lines=\(Self.lineCount(in: cumulativeStreamingSummary))"
                )
            }
            note("persistedCodexReplayStreamFinalized#\(batchNumber)")
            agentModeViewModel.testSetStressRunState(
                tabID: tabID,
                state: .completed,
                statusText: "Persisted Codex replay complete #\(batchNumber)",
                urgentUIRefresh: usesUrgentMutationRefresh
            )
        }

        private func replayPersistedCodexToolStep(
            _ step: ScenarioToolStep,
            on tabID: UUID,
            stepOffset: Int,
            isWarmup: Bool
        ) async {
            switch step {
            case let .repoPromptTool(toolName, args, resultJSON, isError):
                let invocationID = UUID()
                agentModeViewModel.testSimulateCodexRepoPromptToolCall(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args
                )
                try? await Task.sleep(nanoseconds: persistedCodexReplayDelayNanos(stepIndex: stepOffset + 3, isWarmup: isWarmup))
                agentModeViewModel.testSimulateCodexRepoPromptToolResult(
                    tabID: tabID,
                    invocationID: invocationID,
                    toolName: toolName,
                    args: args,
                    resultJSON: resultJSON,
                    isError: isError
                )
            case let .liveBash(command, processID, initialResultJSON, outputChunks, finalResultJSON, isError):
                if await replayPersistedCodexFixtureBashIfAvailable(
                    on: tabID,
                    stepOffset: stepOffset,
                    isWarmup: isWarmup,
                    fallbackCommand: command,
                    fallbackProcessID: processID,
                    isError: isError
                ) {
                    await agentModeViewModel.testReplayCodexNativeEvent(
                        tabID: tabID,
                        event: .assistantDelta("\n\nThe live bash stream stayed attached to the same Codex turn and continued emitting output deltas without dropping the final markdown summary.\n\n")
                    )
                    return
                }
                let invocationID = UUID()
                let escapedCommand = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let argsJSON = "{\"cmd\":\"\(escapedCommand)\"}"
                await agentModeViewModel.testReplayCodexNativeEvent(
                    tabID: tabID,
                    event: .toolCall(name: "bash", invocationID: invocationID, argsJSON: argsJSON)
                )
                await agentModeViewModel.testReplayCodexNativeEvent(
                    tabID: tabID,
                    event: .toolResult(
                        name: "bash",
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        resultJSON: initialResultJSON,
                        isError: false
                    )
                )
                for (chunkIndex, outputChunk) in outputChunks.enumerated() {
                    await agentModeViewModel.testReplayCodexNativeEvent(
                        tabID: tabID,
                        event: .commandExecutionRunning(
                            .init(
                                invocationID: invocationID,
                                processID: processID,
                                appendedOutput: outputChunk,
                                sealsAssistantBoundary: chunkIndex == 0
                            )
                        )
                    )
                    let delay = persistedCodexReplayDelayNanos(stepIndex: stepOffset + 4 + chunkIndex, isWarmup: isWarmup)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
                await agentModeViewModel.testReplayCodexNativeEvent(
                    tabID: tabID,
                    event: .toolResult(
                        name: "bash",
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        resultJSON: finalResultJSON,
                        isError: isError
                    )
                )
                await agentModeViewModel.testReplayCodexNativeEvent(
                    tabID: tabID,
                    event: .assistantDelta("\n\nThe live bash stream stayed attached to the same Codex turn and continued emitting output deltas without dropping the final markdown summary.\n\n")
                )
            }
        }

        private func replayPersistedCodexFixtureBashIfAvailable(
            on tabID: UUID,
            stepOffset: Int,
            isWarmup: Bool,
            fallbackCommand: String,
            fallbackProcessID: String,
            isError: Bool
        ) async -> Bool {
            do {
                guard let replay = try await loadPersistedCodexFixtureBashReplay(
                    named: Self.persistedCodexReplayBashFixtureName,
                    threadID: Self.persistedCodexReplayBashFixtureThreadID,
                    fallbackCommand: fallbackCommand,
                    fallbackProcessID: fallbackProcessID,
                    isError: isError
                ) else {
                    return false
                }
                note("payload=codexFixtureBashLive fixture=\(Self.persistedCodexReplayBashFixtureName)")
                for (eventIndex, event) in replay.events.enumerated() {
                    await agentModeViewModel.testReplayCodexNativeEvent(tabID: tabID, event: event)
                    let delay = persistedCodexReplayDelayNanos(stepIndex: stepOffset + 4 + eventIndex, isWarmup: isWarmup)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
                await agentModeViewModel.testReplayCodexNativeEvent(
                    tabID: tabID,
                    event: .toolResult(
                        name: "bash",
                        invocationID: replay.invocationID,
                        argsJSON: replay.argsJSON,
                        resultJSON: replay.finalResultJSON,
                        isError: isError
                    )
                )
                note("payload=codexFixtureBashCompleted fixture=\(Self.persistedCodexReplayBashFixtureName)")
                return true
            } catch {
                note("persistedCodexReplayFixtureFallback fixture=\(Self.persistedCodexReplayBashFixtureName) reason=\(error.localizedDescription)")
                return false
            }
        }

        private func loadPersistedCodexFixtureBashReplay(
            named fixtureName: String,
            threadID: String,
            fallbackCommand: String,
            fallbackProcessID: String,
            isError: Bool
        ) async throws -> PersistedCodexFixtureBashReplay? {
            let events = try await collectPersistedCodexFixtureEvents(named: fixtureName, threadID: threadID)
            guard !events.isEmpty else { return nil }
            guard let toolCall = events.first(where: {
                if case let .toolCall(name, _, _) = $0 {
                    return name == "bash"
                }
                return false
            }) else {
                return nil
            }
            guard case let .toolCall(_, invocationID, argsJSON) = toolCall else {
                return nil
            }
            let runningUpdates = events.compactMap { event -> CodexNativeSessionController.CommandExecutionRunningUpdate? in
                guard case let .commandExecutionRunning(update) = event else { return nil }
                return update
            }
            let processID = runningUpdates.compactMap(\.processID).last ?? fallbackProcessID
            let command = bashCommand(fromArgsJSON: argsJSON) ?? fallbackCommand
            let output = runningUpdates.compactMap(\.appendedOutput).joined()
            let finalResultJSON = BashToolResultParser.resultJSON(
                statusWord: isError ? "failed" : "completed",
                command: command,
                processID: processID,
                output: output.isEmpty ? nil : output,
                exitCode: isError ? 1 : 0,
                summaryOnly: false
            )
            let replayableEvents = events.filter { event in
                switch event {
                case .toolCall, .commandExecutionRunning:
                    true
                case .toolResult, .turnStarted, .turnCompleted, .assistantDelta, .canonicalAssistantDelta, .assistantCompleted, .reasoningDelta, .reasoningCompleted, .tokenUsage, .contextCompacted, .approvalRequest, .permissionsRequest, .requestUserInput, .mcpElicitationRequest, .serverRequestIssue, .livenessActivity, .errorNotification, .error, .system:
                    false
                }
            }
            return PersistedCodexFixtureBashReplay(
                events: replayableEvents,
                invocationID: invocationID,
                argsJSON: argsJSON,
                finalResultJSON: finalResultJSON
            )
        }

        private func collectPersistedCodexFixtureEvents(
            named fixtureName: String,
            threadID: String
        ) async throws -> [CodexNativeSessionController.Event] {
            guard let fixtureURL = persistedCodexSessionFixtureURL(named: fixtureName) else {
                return []
            }
            let controller = CodexNativeSessionController(
                client: CodexAppServerClient(),
                runID: UUID(),
                tabID: UUID(),
                windowID: windowID,
                workspacePath: configuration.workspaceRootPaths.first
            )
            let recorder = PersistedCodexFixtureEventRecorder()
            let eventTask = Task {
                for await event in controller.events {
                    await recorder.record(event)
                }
            }
            defer { eventTask.cancel() }

            try await controller.test_beginBindingSession()
            let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = object["method"] as? String,
                      let payload = object["payload"] as? [String: Any]
                else {
                    continue
                }
                await controller.test_bufferNotificationDuringBinding(
                    .init(method: method, params: codexJSONDictionary(from: payload))
                )
            }
            _ = await controller.test_finishBinding(
                result: ["thread": ["id": threadID, "turns": []]],
                fallbackEffort: nil
            )
            _ = await waitForPersistedCodexFixtureEventsToSettle(recorder)
            return await recorder.snapshot()
        }

        private func waitForPersistedCodexFixtureEventsToSettle(
            _ recorder: PersistedCodexFixtureEventRecorder,
            timeout: TimeInterval = 1.0,
            quietPeriod: TimeInterval = 0.12
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            var lastCount = -1
            var stableSince = Date()
            while Date() < deadline {
                let currentCount = await recorder.count
                if currentCount != lastCount {
                    lastCount = currentCount
                    stableSince = Date()
                } else if currentCount > 0,
                          Date().timeIntervalSince(stableSince) >= quietPeriod
                {
                    return true
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return await recorder.count > 0
        }

        private func persistedCodexSessionFixtureURL(named fixtureName: String) -> URL? {
            let rootPath = configuration.workspaceRootPaths.first
            guard let rootPath, !rootPath.isEmpty else { return nil }
            return URL(fileURLWithPath: rootPath, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("RepoPromptTests", isDirectory: true)
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("CodexSessions", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: false)
        }

        private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
            var output: [String: CodexJSONValue] = [:]
            for (key, rawValue) in value {
                if let converted = CodexJSONValue.from(rawValue) {
                    output[key] = converted
                }
            }
            return output
        }

        private func bashCommand(fromArgsJSON raw: String?) -> String? {
            guard let raw,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object["cmd"] as? String
        }

        private func persistedReplayTurnPrompt(batchNumber: Int) -> String {
            "Reload the large Codex investigation thread from disk, keep the transcript pinned while the next reply streams, and verify that long final summaries plus tool churn do not reveal historical content mid-stream. (batch \(batchNumber))"
        }

        private func persistedReplayAssistantIntroChunks(batchNumber: Int) -> [String] {
            [
                "## Post-restore replay turn \(batchNumber)\n\n",
                "The thread was reloaded from disk before this response started, so the transcript already contains a large archived history with realistic tool cards and long prior summaries.\n\n",
                "### Replay goals\n- preserve pinned bottom while the next Codex-like reply streams\n- keep markdown rich during streaming\n- catch any one-frame exposure of old content if the transcript jumps\n\n",
                "I’m going to keep the same turn open while tool calls, live bash output, and a long final summary all arrive with irregular spacing.\n\n"
            ]
        }

        private func persistedReplayAssistantSummaryChunks(batchNumber: Int) -> [String] {
            (1 ... 28).map { sectionIndex in
                var chunk = "## Replay summary section \(batchNumber).\(sectionIndex)\n\n"
                chunk += "This section mimics a real Codex final turn summary after a tool-heavy investigation. It is intentionally verbose and irregular in size so the streaming cadence does not look like a uniform synthetic append loop. The transcript is already large because the session was restored from disk before this turn began.\n\n"
                chunk += "- Observation \(sectionIndex).1: historical rows must stay hidden while the live assistant tail grows.\n"
                chunk += "- Observation \(sectionIndex).2: streaming markdown should remain rich even while full-message relayout is coalesced.\n"
                chunk += "- Observation \(sectionIndex).3: tool-card churn plus a large concluding summary is the closest shape to the production failure.\n\n"
                chunk += "1. Reuse the persisted restore path so the thread starts large.\n"
                chunk += "2. Feed the live turn through Codex-style coordinator events with irregular gaps.\n"
                chunk += "3. Keep the final render high fidelity for headings, lists, inline code, and fenced blocks.\n\n"
                if sectionIndex.isMultiple(of: 4) {
                    chunk += "```swift\nstruct PersistedReplaySection\(batchNumber)_\(sectionIndex) {\n\tlet restoredHistoryRows: Int\n\tlet streamedDeltaCount: Int\n\tlet keepsPinnedBottomStable: Bool\n}\n\nlet replaySection = PersistedReplaySection\(batchNumber)_\(sectionIndex)(\n\trestoredHistoryRows: \(max(120, configuration.warmupTurnCount * 40 + sectionIndex * 6)),\n\tstreamedDeltaCount: \(sectionIndex * 7),\n\tkeepsPinnedBottomStable: true\n)\n```\n\n"
                }
                chunk += "The key requirement is that the user never sees older user messages or archived transcript groups flash into view while this large summary is still streaming. If a jump happens, the telemetry should latch it even if the bad frame is extremely brief.\n\n"
                return chunk
            }
        }

        private func persistedCodexReplayDelayNanos(stepIndex: Int, isWarmup: Bool) -> UInt64 {
            let pattern: [TimeInterval] = isWarmup
                ? [0.012, 0.018, 0.024, 0.016]
                : [0.028, 0.075, 0.041, 0.108, 0.052, 0.031, 0.126, 0.047, 0.089]
            let seconds = pattern[stepIndex % pattern.count]
            return UInt64(seconds * 1_000_000_000)
        }

        private static let largeStreamingAssistantCharacterThreshold = 12000
        private static let largeStreamingAssistantLineThreshold = 220

        private func appendAssistantMarkdownChurn(on tabID: UUID, isWarmup: Bool) async {
            await appendStreamingAssistantMarkdown(
                on: tabID,
                isWarmup: isWarmup,
                batchLabel: "assistant-markdown-churn",
                statusLabel: "Assistant markdown stream",
                prompt: assistantMarkdownPrompt,
                chunks: assistantMarkdownChunks,
                emitsLargeWindowMarkers: false,
                usesMegaCadence: false
            )
        }

        private func appendAssistantMarkdownMegaChurn(on tabID: UUID, isWarmup: Bool) async {
            await appendStreamingAssistantMarkdown(
                on: tabID,
                isWarmup: isWarmup,
                batchLabel: "assistant-markdown-mega-churn",
                statusLabel: "Assistant markdown mega stream",
                prompt: assistantMarkdownMegaPrompt,
                chunks: assistantMarkdownMegaChunks,
                emitsLargeWindowMarkers: true,
                usesMegaCadence: true
            )
        }

        private func appendStreamingAssistantMarkdown(
            on tabID: UUID,
            isWarmup: Bool,
            batchLabel: String,
            statusLabel: String,
            prompt: String,
            chunks: [String],
            emitsLargeWindowMarkers: Bool,
            usesMegaCadence: Bool
        ) async {
            let batchNumber = scenarioCursor + 1
            scenarioCursor += 1
            note("Appending batch: \(batchLabel)-\(batchNumber)")
            agentModeViewModel.testSetStressRunState(
                tabID: tabID,
                state: .running,
                statusText: "\(statusLabel) running #\(batchNumber)",
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            agentModeViewModel.testAppendMockTranscriptMessage(
                tabID: tabID,
                role: .user,
                text: prompt,
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            note("assistantMarkdownStreamStart#\(batchNumber)")
            var cumulativeText = ""
            var didEmitLargeWindowStart = false
            for chunk in chunks {
                cumulativeText.append(chunk)
                if emitsLargeWindowMarkers,
                   !didEmitLargeWindowStart,
                   Self.isLargeStreamingMarkdown(text: cumulativeText)
                {
                    didEmitLargeWindowStart = true
                    note(
                        "assistantMarkdownLargeWindowStart#\(batchNumber) chars=\(cumulativeText.count) lines=\(Self.lineCount(in: cumulativeText))"
                    )
                }
                agentModeViewModel.testAppendStreamingAssistantDelta(
                    tabID: tabID,
                    delta: chunk,
                    urgentUIRefresh: usesUrgentMutationRefresh
                )
                let delay = assistantMarkdownChunkDelayNanos(isWarmup: isWarmup, usesMegaCadence: usesMegaCadence)
                guard delay > 0 else { continue }
                try? await Task.sleep(nanoseconds: delay)
            }
            agentModeViewModel.testFinalizeStreamingAssistant(
                tabID: tabID,
                urgentUIRefresh: usesUrgentMutationRefresh
            )
            if emitsLargeWindowMarkers, didEmitLargeWindowStart {
                note(
                    "assistantMarkdownLargeWindowEnd#\(batchNumber) chars=\(cumulativeText.count) lines=\(Self.lineCount(in: cumulativeText))"
                )
            }
            note("assistantMarkdownStreamFinalized#\(batchNumber)")
            agentModeViewModel.testSetStressRunState(
                tabID: tabID,
                state: .completed,
                statusText: "\(statusLabel) complete #\(batchNumber)",
                urgentUIRefresh: usesUrgentMutationRefresh
            )
        }

        private func assistantMarkdownChunkDelayNanos(isWarmup: Bool, usesMegaCadence: Bool) -> UInt64 {
            let seconds: TimeInterval = if isWarmup {
                usesMegaCadence ? 0.018 : 0.02
            } else if usesMegaCadence {
                max(0.05, min(0.07, configuration.insertionInterval * 0.78))
            } else {
                max(0.06, min(0.09, configuration.insertionInterval * 0.85))
            }
            return UInt64(seconds * 1_000_000_000)
        }

        private static func lineCount(in text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            return text.reduce(into: 1) { count, character in
                if character == "\n" {
                    count += 1
                }
            }
        }

        private static func isLargeStreamingMarkdown(text: String) -> Bool {
            text.count >= largeStreamingAssistantCharacterThreshold || lineCount(in: text) >= largeStreamingAssistantLineThreshold
        }

        private var assistantMarkdownPrompt: String {
            "Investigate why the transcript flickers and snaps back to bottom while a long markdown answer is still streaming, then outline a narrow mitigation."
        }

        private var assistantMarkdownMegaPrompt: String {
            "Trace catastrophic pinned jumps during a huge streamed markdown answer, preserve rich markdown while streaming, and propose a mitigation that reduces relayout pressure without degrading the final render."
        }

        private var assistantMarkdownChunks: [String] {
            [
                "# Transcript churn investigation\n\n",
                "We are tracing the `MarkdownTextView` update path while the assistant is still streaming. The goal is to keep **rich markdown** visible without forcing a full attributed replacement on every delta.\n\n",
                "## Observed behaviors\n- repeated height invalidation\n- scroll thumb flicker\n- jump upward before the view snaps back to bottom\n\n",
                "### Current hypothesis\nThe expensive path is triggered by `setAttributedString(...)` after each streamed append, which means AppKit keeps re-laying out the same row while the transcript is pinned.\n\n",
                "```swift\nstruct StreamingMarkdownPlan {\n\tlet cadence: MarkdownRenderCadence\n\tlet minPublishIntervalMS: Int\n\tlet quietWindowMS: Int\n}\n\n",
                "let plan = StreamingMarkdownPlan(\n\tcadence: .streamingCoalesced,\n\tminPublishIntervalMS: 200,\n\tquietWindowMS: 120\n)\n```\n\n",
                "1. Keep the existing attributed renderer on screen\n2. Coalesce append-only recompiles while the message is still streaming\n3. Force one immediate final compile after the stream completes\n\n",
                "For links we still want the final markdown behavior to preserve [workspace state](repoprompt://workspace/switch?name=RepoPrompt) and ordinary URLs like [OpenAI](https://openai.com/).\n\n",
                "Additional notes:\n- no table markup in this scenario\n- code fences remain part of the stream\n- the content is intentionally long enough to stress layout and bottom pin maintenance\n\n",
                "### Expected result\nThe user should still see headings, lists, inline code like `setAttributedString`, and fenced code blocks while the renderer updates at a bounded cadence instead of every chunk.\n"
            ]
        }

        private var assistantMarkdownMegaChunks: [String] {
            (1 ... 36).map { sectionIndex in
                var chunk = "## Large streaming section \(sectionIndex)\n\n"
                chunk += "This section keeps the assistant response in a high-pressure markdown streaming window. It intentionally mixes prose, nested lists, and fenced code so the renderer has to maintain a rich attributed view while the transcript remains pinned to live bottom. The goal is to surface any catastrophic jump that briefly reveals historical content.\n\n"
                chunk += "- Observation \(sectionIndex).1: the markdown body keeps growing with append-only deltas.\n"
                chunk += "- Observation \(sectionIndex).2: pinned maintenance should not over-correct during transient layout instability.\n"
                chunk += "  - detail: the viewport must stay near the live tail even while the rendered height changes rapidly.\n"
                chunk += "  - detail: telemetry should latch any unexpected exposure of older transcript rows.\n\n"
                chunk += "1. Keep headings and lists rendered as markdown while streaming.\n"
                chunk += "2. Bound attributed recompiles so the same giant message is not fully rebuilt every tiny delta.\n"
                chunk += "3. Preserve final fidelity for links like [OpenAI](https://openai.com/) and workspace links like [RepoPrompt](repoprompt://workspace/switch?name=RepoPrompt).\n\n"
                if sectionIndex.isMultiple(of: 3) {
                    chunk += "```swift\nstruct LargeStreamingRenderSection\(sectionIndex) {\n\tlet appendedLines: Int\n\tlet appendedCharacters: Int\n\tlet shouldThrottle: Bool\n}\n\nlet section\(sectionIndex) = LargeStreamingRenderSection\(sectionIndex)(\n\tappendedLines: \(sectionIndex * 9),\n\tappendedCharacters: \(sectionIndex * 540),\n\tshouldThrottle: true\n)\n```\n\n"
                }
                chunk += "The renderer should prefer a stable frozen prefix and a smaller live tail once the message becomes extreme. That keeps the visible experience rich while reducing the number of whole-message attributed swaps that can destabilize the scroll view.\n\n"
                return chunk
            }
        }

        private var mixedScenarioBatches: [ScenarioBatch] {
            [
                ScenarioBatch(
                    title: "navigation",
                    includeUserTurn: true,
                    userText: "Inspect the workspace tree and spot large transcript rendering hotspots.",
                    preamble: [(.thinking, "Scanning the active transcript view and routing path."), (.assistantInline, "Checking the agent transcript container before touching scroll state.")],
                    toolSteps: [
                        .toolCall("get_file_tree", argsJSON: "{\"type\":\"files\",\"mode\":\"auto\"}", resultJSON: "{\"summary\":\"Rendered file tree with 18 visible nodes\"}"),
                        .toolCall("file_search", argsJSON: "{\"pattern\":\"scrollTo|autoScroll|activityCluster\"}", resultJSON: "{\"matches\":12,\"files\":[\"AgentModeView.swift\",\"ToolCardRouter.swift\"]}"),
                        .toolCall("read_file", argsJSON: "{\"path\":\"RepoPrompt/Views/AgentMode/AgentModeView.swift\",\"start_line\":760,\"limit\":120}", resultJSON: "{\"summary\":\"Loaded transcript scroll section\"}")
                    ],
                    intermittentMessages: [
                        (.assistantInline, "Progress: the tree is loaded, now tracing the scroll ownership path."),
                        (.thinking, "Progress: narrowing the hot path before reading more layout state."),
                        (.assistantInline, "Progress: enough navigation context is in place for the next viewport decision.")
                    ],
                    assistantText: "The transcript container is reusing the real grouping pipeline, so this batch should collapse into a navigation-heavy cluster."
                ),
                ScenarioBatch(
                    title: "execution",
                    includeUserTurn: false,
                    userText: nil,
                    preamble: [(.system, "Running command-heavy verification against the synthetic transcript."), (.thinking, "Watching for scroll jumps while command output lands.")],
                    toolSteps: [
                        .toolCall("bash", argsJSON: "{\"cmd\":\"xcodetester build\"}", resultJSON: "{\"status\":\"completed\",\"exit_code\":0,\"stdout\":\"Build Succeeded\"}"),
                        .toolCall("manage_selection", argsJSON: "{\"op\":\"get\",\"view\":\"summary\"}", resultJSON: "{\"summary\":\"12 selected files\"}"),
                        .toolCall("workspace_context", argsJSON: "{\"include\":[\"selection\",\"tokens\"]}", resultJSON: "{\"tokens\":42120}")
                    ],
                    intermittentMessages: [
                        (.assistantInline, "Progress: the build output is in, checking whether selection pressure stayed bounded."),
                        (.thinking, "Progress: token usage is moving, but I still need to confirm the scroll surface stays smooth."),
                        (.assistantInline, "Progress: command-heavy verification is complete, keeping the newest rows in view.")
                    ],
                    assistantText: "Command output stayed compact, which helps stress the cluster summary chips without flooding the viewport."
                ),
                ScenarioBatch(
                    title: "editing",
                    includeUserTurn: false,
                    userText: nil,
                    preamble: [(.assistantInline, "Applying a few mock edits to exercise grouped tool categories.")],
                    toolSteps: [
                        .toolCall("apply_patch", argsJSON: "{\"path\":\"RepoPrompt/RepoPrompt/Views/AgentMode/AgentModeView.swift\",\"change_count\":3}", resultJSON: "{\"kind\":\"edit_summary\",\"summary\":\"Updated transcript telemetry overlay\",\"change_count\":3}"),
                        compactApplyEditsStep(
                            path: "RepoPrompt/RepoPromptUITests/RepoPromptUITests.swift",
                            note: "Patched UI test helpers.",
                            hunkSeed: 31
                        ),
                        .toolCall("ask_oracle", argsJSON: "{\"mode\":\"review\",\"message\":\"Check the scroll telemetry hooks.\"}", resultJSON: "{\"summary\":\"Review complete with one minor note\"}")
                    ],
                    intermittentMessages: [
                        (.assistantInline, "Progress: the first edit landed cleanly; validating the next patch in the same turn."),
                        (.thinking, "Progress: holding the grouped edit summary steady while tool results continue to land."),
                        (.assistantInline, "Progress: review notes are in, carrying them forward without breaking auto-follow.")
                    ],
                    assistantText: "The edit-focused burst should surface an Edit cluster and push the transcript enough to probe repin behavior."
                ),
                ScenarioBatch(
                    title: "mixed-warning",
                    includeUserTurn: true,
                    userText: "Summarize the latest scroll anomalies and keep following new output.",
                    preamble: [(.thinking, "Cross-checking grouped history telemetry before adding more rows.")],
                    toolSteps: [
                        .toolCall("get_code_structure", argsJSON: "{\"paths\":[\"RepoPrompt/RepoPrompt/Views/AgentMode\"]}", resultJSON: "{\"files\":8}"),
                        .toolCall("file_search", argsJSON: "{\"pattern\":\"unexpectedJumpCount\"}", resultJSON: "{\"matches\":1}", isError: true),
                        .toolCall("prompt", argsJSON: "{\"op\":\"append\",\"text\":\"Investigate scroll jitter\"}", resultJSON: "{\"status\":\"ok\"}")
                    ],
                    intermittentMessages: [
                        (.thinking, "Progress: the grouped warning surfaced, now checking whether detached focus stays coherent."),
                        (.assistantInline, "Progress: the warning path is isolated; continuing without dropping live-bottom context."),
                        (.assistantInline, "Progress: anomaly summary captured, moving on to the next update batch.")
                    ],
                    assistantText: "I found a warning-sized anomaly marker and kept auto-follow enabled so the newest rows remain visible."
                )
            ]
        }

        private var richScenarioBatches: [ScenarioBatch] {
            [
                ScenarioBatch(
                    title: "rich-edit-bash-a",
                    includeUserTurn: true,
                    userText: "Investigate the intermittent macOS transcript scroll corruption and show the concrete heavy UI states.",
                    preamble: [
                        (.thinking, "Rebuilding the full transcript surface with expanded edits and terminal output."),
                        (.assistantInline, "Laying down real-looking diff and bash cards before probing detached responsiveness.")
                    ],
                    toolSteps: [
                        richApplyEditsStep(
                            path: "RepoPrompt/Views/AgentMode/AgentModeView.swift",
                            note: "Refined detached telemetry probes and viewport recovery sequencing.",
                            hunkSeed: 1
                        ),
                        richApplyPatchStep(
                            paths: [
                                "RepoPrompt/Views/AgentMode/AgentModeView.swift",
                                "RepoPromptUITests/RepoPromptUITests.swift",
                                "docs/investigations/agent-transcript-detached-stability-2026-03-11.md"
                            ],
                            seed: 11
                        ),
                        richLiveBashStep(
                            command: "xcodetester test --only-testing RepoPromptUITests/RepoPromptUITests/testAgentChatStressHarnessRichToolChurnManualScrollRemainsResponsiveWhenDetached",
                            processID: "24017",
                            label: "rich-manual-scroll",
                            chunkCount: 6
                        )
                    ],
                    intermittentMessages: [
                        (.assistantInline, "Progress: the newest edit diff is expanded; watching for the previous one to collapse cleanly."),
                        (.thinking, "Progress: terminal output is still growing in place, which is the shape most likely to desync the native scroll container."),
                        (.assistantInline, "Progress: rich tool churn is active; detached responsiveness can be probed against the real card morphology now.")
                    ],
                    assistantText: "The transcript now contains a large edit diff, a multi-file patch, and a live bash burst in the same turn."
                ),
                ScenarioBatch(
                    title: "rich-edit-bash-b",
                    includeUserTurn: false,
                    userText: nil,
                    preamble: [
                        (.system, "Continuing the rich churn sequence with another completed turn."),
                        (.assistantInline, "Keeping the latest bash card expanded while the next edit block replaces it as the newest change.")
                    ],
                    toolSteps: [
                        richApplyEditsStep(
                            path: "RepoPrompt/Services/AgentMode/Debug/AgentChatStressHarness.swift",
                            note: "Upgraded the stress harness to emit live bash updates and dense diff payloads.",
                            hunkSeed: 2
                        ),
                        richApplyPatchStep(
                            paths: [
                                "RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift",
                                "RepoPrompt/ViewModels/AgentModeViewModel.swift"
                            ],
                            seed: 21
                        ),
                        richLiveBashStep(
                            command: "xcodetester build && xcodetester test --only-testing RepoPromptTests/AgentTranscriptServicesTests/testRichHarnessBashRunningPayloadParsesAsRunning",
                            processID: "24018",
                            label: "rich-scroll-to-bottom",
                            chunkCount: 5
                        )
                    ],
                    intermittentMessages: [
                        (.thinking, "Progress: latest completed bash output is expanded, then the next rich edit takes over as the newest heavy card."),
                        (.assistantInline, "Progress: detaching after this point should now exercise the same height churn users see in practice."),
                        (.assistantInline, "Progress: rich churn batch complete; scroll-to-bottom recovery is ready to be tested.")
                    ],
                    assistantText: "A second rich turn completed, keeping the transcript in a high-churn expanded-card state."
                )
            ]
        }

        private func compactApplyEditsStep(path: String, note: String, hunkSeed: Int) -> ScenarioToolStep {
            applyEditsStep(
                path: path,
                note: note,
                hunkSeed: hunkSeed,
                hunkCount: 1,
                linesPerHunk: 8,
                editsRequested: 1,
                editsApplied: 1,
                addedLines: 4,
                deletedLines: 4,
                totalLinesChanged: 8,
                totalChunks: 1
            )
        }

        private func richApplyEditsStep(path: String, note: String, hunkSeed: Int) -> ScenarioToolStep {
            applyEditsStep(
                path: path,
                note: note,
                hunkSeed: hunkSeed,
                hunkCount: 4,
                linesPerHunk: 18,
                editsRequested: 4,
                editsApplied: 4,
                addedLines: 36,
                deletedLines: 36,
                totalLinesChanged: 72,
                totalChunks: 4
            )
        }

        private func applyEditsStep(
            path: String,
            note: String,
            hunkSeed: Int,
            hunkCount: Int,
            linesPerHunk: Int,
            editsRequested: Int,
            editsApplied: Int,
            addedLines: Int,
            deletedLines: Int,
            totalLinesChanged: Int,
            totalChunks: Int
        ) -> ScenarioToolStep {
            let diff = makeUnifiedDiff(path: path, seed: hunkSeed, hunkCount: hunkCount, linesPerHunk: linesPerHunk)
            let dto = ToolResultDTOs.EditSummary(
                status: "success",
                editsRequested: editsRequested,
                editsApplied: editsApplied,
                addedLines: addedLines,
                deletedLines: deletedLines,
                totalLinesChanged: totalLinesChanged,
                totalChunks: totalChunks,
                results: nil,
                unifiedDiff: nil,
                cardUnifiedDiff: diff,
                note: note,
                fileCreated: nil,
                fileOverwritten: nil,
                reviewStatus: nil,
                rejectionReason: nil,
                requiresUserApproval: false
            )
            return .repoPromptTool(
                "apply_edits",
                args: ["path": .string(path)],
                resultJSON: encode(dto) ?? #"{"status":"success","edits_requested":1,"edits_applied":1}"#,
                isError: false
            )
        }

        private func richApplyPatchStep(paths: [String], seed: Int) -> ScenarioToolStep {
            let changes = paths.enumerated().map { index, path in
                ToolResultDTOs.ApplyPatchSummary.Change(
                    path: path,
                    kind: "update",
                    movePath: nil,
                    diff: makeUnifiedDiff(path: path, seed: seed + index, hunkCount: 2, linesPerHunk: 16)
                )
            }
            let dto = ToolResultDTOs.ApplyPatchSummary(
                status: "completed",
                changes: changes,
                output: "Applied \(changes.count) transcript-focused patch segments.",
                changeCount: changes.count,
                summaryOnly: false
            )
            var args: [String: Value] = ["change_count": .int(changes.count)]
            if let firstPath = paths.first {
                args["path"] = .string(firstPath)
            }
            return .repoPromptTool(
                "apply_patch",
                args: args,
                resultJSON: encode(dto) ?? #"{"status":"completed","change_count":1,"changes":[]}"#,
                isError: false
            )
        }

        private func richLiveBashStep(
            command: String,
            processID: String,
            label: String,
            chunkCount: Int
        ) -> ScenarioToolStep {
            let outputChunks = makeTerminalOutputChunks(label: label, chunkCount: chunkCount, linesPerChunk: 14)
            let combinedOutput = outputChunks.joined()
            let initialResultJSON = BashToolResultParser.resultJSON(
                statusWord: "running",
                command: command,
                processID: processID,
                output: "Booting \(label) command stream…\n",
                exitCode: nil,
                summaryOnly: false
            )
            let finalResultJSON = BashToolResultParser.resultJSON(
                statusWord: "completed",
                command: command,
                processID: processID,
                output: "Booting \(label) command stream…\n" + combinedOutput + "Test Suite '\(label)' passed.\n",
                exitCode: 0,
                summaryOnly: false
            )
            return .liveBash(
                command: command,
                processID: processID,
                initialResultJSON: initialResultJSON,
                outputChunks: outputChunks,
                finalResultJSON: finalResultJSON,
                isError: false
            )
        }

        private func makeUnifiedDiff(path: String, seed: Int, hunkCount: Int, linesPerHunk: Int) -> String {
            var lines: [String] = [
                "diff --git a/\(path) b/\(path)",
                "index \(String(format: "%07d", seed))..\(String(format: "%07d", seed + 1)) 100644",
                "--- a/\(path)",
                "+++ b/\(path)"
            ]
            for hunkIndex in 0 ..< hunkCount {
                let startLine = 40 + (hunkIndex * (linesPerHunk + 5))
                lines.append("@@ -\(startLine),\(linesPerHunk) +\(startLine),\(linesPerHunk + 6) @@")
                lines.append(" context let viewportRevision = \(seed + hunkIndex)")
                for lineIndex in 0 ..< linesPerHunk {
                    lines.append("-old scroll state \(seed)-\(hunkIndex)-\(lineIndex)")
                    lines.append("+new scroll state \(seed)-\(hunkIndex)-\(lineIndex) with detached anchor compensation and visibility sampling")
                }
                lines.append(" context let detachedBaseline = \(seed + hunkIndex + linesPerHunk)")
            }
            return lines.joined(separator: "\n")
        }

        private func makeTerminalOutputChunks(label: String, chunkCount: Int, linesPerChunk: Int) -> [String] {
            (0 ..< chunkCount).map { chunkIndex in
                let header = "[\(label)] phase \(chunkIndex + 1)/\(chunkCount)"
                let body = (0 ..< linesPerChunk).map { lineIndex in
                    "CompileSwift normal arm64 \(header) output line \(lineIndex + 1) — rendering expanded transcript card geometry"
                }
                return ([header] + body + [""]).joined(separator: "\n")
            }
        }

        private func encode(_ value: some Encodable) -> String? {
            guard let data = try? Self.encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private struct PersistedCodexFixtureBashReplay {
        let events: [CodexNativeSessionController.Event]
        let invocationID: UUID?
        let argsJSON: String?
        let finalResultJSON: String
    }

    private actor PersistedCodexFixtureEventRecorder {
        private var events: [CodexNativeSessionController.Event] = []

        func record(_ event: CodexNativeSessionController.Event) {
            events.append(event)
        }

        var count: Int {
            events.count
        }

        func snapshot() -> [CodexNativeSessionController.Event] {
            events
        }
    }

    private extension AgentChatStressHarness.MockTranscriptRole {
        var toViewModelRole: AgentModeViewModel.MockTranscriptRole {
            switch self {
            case .user:
                .user
            case .assistant:
                .assistant
            case .assistantInline:
                .assistantInline
            case .thinking:
                .thinking
            case .system:
                .system
            }
        }
    }
#endif
