import AppKit
import Combine
import SwiftUI

// AgentLogEntry and AgentLogEntryType are defined in Models/Agent/AgentLogModels.swift

enum AgentRunState: Equatable {
    case idle
    case running(UUID)
    case completed
    case cancelled
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    static func == (lhs: AgentRunState, rhs: AgentRunState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.completed, .completed), (.cancelled, .cancelled):
            true
        case let (.running(a), .running(b)):
            a == b
        case let (.failed(a), .failed(b)):
            a == b
        default:
            false
        }
    }
}

struct AgentRun: Identifiable {
    let id = UUID()
    let timestamp: Date
    let log: [AgentLogEntry]
    let state: AgentRunState
}

// DiscoveryQuestion and UserQuestionResponse are defined in Models/Agent/UserInteractionModels.swift

/// Selected follow-up type for discovery auto-generate
enum ContextBuilderFollowUpType: String, CaseIterable, Codable {
    case plan
    case review
    case question

    /// Convert to HeadlessMode for generation
    var headlessMode: HeadlessMode {
        switch self {
        case .plan: .plan
        case .review: .review
        case .question: .chat
        }
    }

    /// Response type string for discovery prompt
    var responseTypeString: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .plan: "Plan"
        case .review: "Review"
        case .question: "Question"
        }
    }

    var icon: String {
        switch self {
        case .plan: "doc.text"
        case .review: "magnifyingglass"
        case .question: "questionmark.circle"
        }
    }

    var description: String {
        switch self {
        case .plan: "Generate an implementation plan"
        case .review: "Review code changes"
        case .question: "Answer a question about the codebase"
        }
    }

    /// Label for the Generate button ("Answer" instead of "Question")
    var buttonLabel: String {
        switch self {
        case .plan: "Plan"
        case .review: "Review"
        case .question: "Answer"
        }
    }
}

@MainActor
final class ContextBuilderAgentViewModel: ObservableObject {
    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            if AgentRuntimeProviderService.enableDebugLogging {
                print("[DiscoverAgent] \(message())")
            }
        #endif
    }

    @MainActor
    final class TabSession: ObservableObject {
        private static let maxLogEntries = 5

        let tabID: UUID
        @Published var agentLog: [AgentLogEntry]
        /// Total tool calls for the current run (tracked separately since agentLog is limited)
        @Published var toolCallCount: Int = 0

        private static let assistantOutputDedupeKey = "assistant-output"
        private static let assistantOutputPreviewLimit = 160

        private var logEntryIDByDedupeKey: [String: UUID] = [:]
        private var lastAssistantOutputContentMessageID: String?

        /// Inserts or updates a log entry at the front (newest-first) and trims to keep only the last `maxLogEntries`.
        /// When `dedupeKey` is supplied, subsequent entries with the same key update the existing visible row
        /// without incrementing the tool-call count.
        @discardableResult
        func appendLogEntry(_ entry: AgentLogEntry, dedupeKey: String? = nil) -> Bool {
            if let dedupeKey {
                if let existingID = logEntryIDByDedupeKey[dedupeKey],
                   let index = agentLog.firstIndex(where: { $0.id == existingID })
                {
                    let existingEntry = agentLog[index]
                    guard existingEntry.type != entry.type || existingEntry.message != entry.message else {
                        return false
                    }
                    agentLog[index] = AgentLogEntry(
                        id: existingEntry.id,
                        timestamp: entry.timestamp,
                        type: entry.type,
                        message: entry.message
                    )
                    return true
                }

                logEntryIDByDedupeKey[dedupeKey] = entry.id
            }

            if entry.type == .tool {
                toolCallCount += 1
            }
            agentLog.insert(entry, at: 0)
            trimLogEntriesIfNeeded()
            return true
        }

        /// Appends a streaming assistant delta to the full output buffer while maintaining a single compact preview row.
        /// When a provider supplies a stable message ID, changed IDs are treated as whole-message boundaries
        /// and separated in the backing output so adjacent full-message chunks do not get glued together.
        @discardableResult
        func appendAssistantOutputDelta(_ delta: String, messageID: String? = nil) -> Bool {
            guard !delta.isEmpty else { return false }

            let normalizedMessageID = messageID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentMessageID = normalizedMessageID?.isEmpty == false ? normalizedMessageID : nil
            let previousOutput = lastAgentOutput ?? ""
            let separator = Self.assistantOutputBoundarySeparator(
                previous: previousOutput,
                next: delta,
                previousMessageID: lastAssistantOutputContentMessageID,
                nextMessageID: contentMessageID
            )

            lastAgentOutput = previousOutput + separator + delta
            lastAssistantOutputContentMessageID = contentMessageID
            return updateAssistantOutputPreview()
        }

        /// Replaces the accumulated assistant output with an authoritative final message while preserving one preview row.
        @discardableResult
        func replaceAssistantOutput(_ output: String) -> Bool {
            lastAgentOutput = output
            lastAssistantOutputContentMessageID = nil
            if output.isEmpty {
                return removeLogEntry(dedupeKey: Self.assistantOutputDedupeKey)
            }
            return updateAssistantOutputPreview()
        }

        /// Clears the log and resets run-scoped log state for a new run.
        func resetLog() {
            agentLog = []
            toolCallCount = 0
            logEntryIDByDedupeKey = [:]
            lastAgentOutput = nil
            lastAssistantOutputContentMessageID = nil
            usedAgentOutputAsPrompt = false
        }

        private func trimLogEntriesIfNeeded() {
            guard agentLog.count > Self.maxLogEntries else { return }
            agentLog.removeLast(agentLog.count - Self.maxLogEntries)
            pruneDedupeKeysForVisibleLog()
        }

        private func pruneDedupeKeysForVisibleLog() {
            let visibleIDs = Set(agentLog.map(\.id))
            logEntryIDByDedupeKey = logEntryIDByDedupeKey.filter { visibleIDs.contains($0.value) }
        }

        private func removeLogEntry(dedupeKey: String) -> Bool {
            guard let existingID = logEntryIDByDedupeKey.removeValue(forKey: dedupeKey),
                  let index = agentLog.firstIndex(where: { $0.id == existingID })
            else {
                return false
            }
            agentLog.remove(at: index)
            return true
        }

        private static func assistantOutputBoundarySeparator(
            previous: String,
            next: String,
            previousMessageID: String?,
            nextMessageID: String?
        ) -> String {
            guard !previous.isEmpty, !next.isEmpty,
                  let previousMessageID, !previousMessageID.isEmpty,
                  let nextMessageID, !nextMessageID.isEmpty,
                  previousMessageID != nextMessageID
            else {
                return ""
            }

            let newlineCount = trailingNewlineCount(in: previous) + leadingNewlineCount(in: next)
            guard newlineCount < 2 else { return "" }
            return String(repeating: "\n", count: 2 - newlineCount)
        }

        private static func trailingNewlineCount(in text: String) -> Int {
            var count = 0
            for character in text.reversed() {
                guard character.isNewline else { break }
                count += 1
            }
            return count
        }

        private static func leadingNewlineCount(in text: String) -> Int {
            var count = 0
            for character in text {
                guard character.isNewline else { break }
                count += 1
            }
            return count
        }

        private func updateAssistantOutputPreview() -> Bool {
            guard let preview = Self.compactAssistantOutputPreview(from: lastAgentOutput) else {
                return false
            }

            return appendLogEntry(
                AgentLogEntry(timestamp: Date(), type: .assistant, message: preview),
                dedupeKey: Self.assistantOutputDedupeKey
            )
        }

        private static func compactAssistantOutputPreview(from output: String?) -> String? {
            guard let output else { return nil }
            let compacted = output
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compacted.isEmpty else { return nil }

            if compacted.count <= assistantOutputPreviewLimit {
                return compacted
            }

            let suffixCount = max(assistantOutputPreviewLimit - 1, 1)
            return "…" + String(compacted.suffix(suffixCount))
        }

        @Published var agentRunState: AgentRunState
        @Published var isAgentBusy: Bool
        @Published var isCancelling: Bool
        /// Latches user cancel intent for the active discover run.
        /// Used to suppress automatic follow-up generation even if the run exits as completed.
        var didUserCancelActiveContextBuilderRun: Bool = false
        @Published var runHistory: [AgentRun]
        /// Agent/model selection moved to workspace-scoped settings (not tab-specific)
        @Published var contextBuilderInstructions: String
        /// Selected context builder prompt IDs for this tab
        @Published var selectedContextBuilderPromptIDs: Set<UUID> = []
        /// Chat session ID from plan generation (wiped on new discovery run)
        @Published var generatedPlanChatID: String?

        // Per-tab plan UI state
        @Published var isBackgroundPlanGenerating: Bool
        @Published var backgroundPlanError: String?
        @Published var backgroundPlanResponseText: String?
        @Published var backgroundPlanReasoningText: String?
        var backgroundPlanResponsePreviewText: String?
        var backgroundPlanReasoningPreviewText: String?

        /// When true, MCP is controlling this tab's run and UI auto-generate should be suppressed
        var isMCPControlledRun: Bool = false

        /// MCP response_type requested (plan/question/review/clarify) - only set during MCP runs
        var mcpResponseType: String?

        /// Model name that will be used for MCP plan generation (resolved at run start)
        var mcpPlanModel: String?

        /// Per-run MCP token budget override for this tab (non-persistent)
        var tokenBudgetOverrideForRun: Int?

        /// True if agent output was copied to prompt area (set during completion)
        var usedAgentOutputAsPrompt: Bool = false

        /// Last extracted agent output (set during completion for MCP snapshot)
        var lastAgentOutput: String?

        // MARK: - Run-Start Captured State (prevents tab bleed)

        /// Prompt text captured when discovery run started
        var runStartPromptText: String?
        /// File selection captured when discovery run started
        var runStartSelection: StoredSelection?
        /// Selected context builder prompt IDs captured when run started
        var runStartContextBuilderPromptIDs: Set<UUID>?
        /// Agent/model used for the most recent run (kept for log display + cleanup)
        var lastRunAgentKind: AgentProviderKind?
        var lastRunModelRaw: String?

        // MARK: - Clarifying Questions State

        /// Pending structured ask_user interaction from the agent awaiting user response
        @Published var pendingAskUser: AgentAskUserPendingState?
        /// Continuation to resume after user responds (internal, not published)
        var askUserContinuation: CheckedContinuation<AgentAskUserResponse, Error>?
        /// Task for question timeout handling
        var askUserTimeoutTask: Task<Void, Never>?
        /// Generation token for timeout reset/cancellation races
        var pendingAskUserTimeoutGeneration: UInt64 = 0

        let runLifecycleGate = TaskSemaphore(1)
        private(set) var runLifecycleTracker = AgentRunLifecycleTracker()
        var activeRunOwnership: AgentRunOwnership? {
            runLifecycleTracker.activeOwnership
        }

        var activeRunAttemptID: UUID? {
            activeRunOwnership?.attemptID
        }

        var activeRunLiveness: AgentRunLivenessSnapshot? {
            runLifecycleTracker.liveness
        }

        var agentTask: Task<Void, Never>?
        var activeAgentProvider: HeadlessAgentProvider?
        var boundClientID: String?

        // MARK: - Background Plan Generation (per-tab tracking)

        /// Task handle for this tab's background plan generation
        var backgroundPlanTask: Task<Void, Never>?

        /// Live Oracle chat session used by MCP follow-up streaming.
        var followUpOracleSessionID: UUID?

        /// Per-tab auto-generate plan setting (loaded from tab config)
        var autoGeneratePlan: Bool = false

        /// Per-tab selected follow-up type for auto-generate (plan/review/question)
        var selectedFollowUpType: ContextBuilderFollowUpType = .plan

        @discardableResult
        func beginRunAttempt(source: String) -> AgentRunOwnership {
            let ownership = runLifecycleTracker.begin(tabID: tabID, persistentSessionID: nil)
            #if DEBUG
                AgentModePerfDiagnostics.increment("contextBuilder.run.lifecycle.attempt.started")
                AgentModePerfDiagnostics.increment("contextBuilder.run.lifecycle.attempt.started.source.\(source)")
            #endif
            return ownership
        }

        @discardableResult
        func recordRunProgress(
            ownership: AgentRunOwnership,
            kind: AgentRunLivenessSignalKind,
            stage: AgentRunLifecycleStage,
            retryIntent: AgentRunRetryIntent = .none,
            timestampUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
        ) -> AgentRunProgressAcceptance {
            let result = runLifecycleTracker.record(
                ownership: ownership,
                kind: kind,
                stage: stage,
                retryIntent: retryIntent,
                timestampUptimeNanoseconds: timestampUptimeNanoseconds
            )
            #if DEBUG
                if case let .rejected(reason) = result {
                    AgentModePerfDiagnostics.increment("contextBuilder.run.lifecycle.progress.rejected.\(reason.rawValue)", tabID: tabID)
                }
            #endif
            return result
        }

        @discardableResult
        func endRunAttempt(ifCurrent ownership: AgentRunOwnership, source: String) -> Bool {
            guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
            recordRunAttemptEnded(source: source)
            return true
        }

        @discardableResult
        func endCurrentRunAttempt(source: String) -> Bool {
            guard let ownership = activeRunOwnership else { return false }
            guard runLifecycleTracker.end(ifCurrent: ownership) else { return false }
            recordRunAttemptEnded(source: source)
            return true
        }

        private func recordRunAttemptEnded(source: String) {
            #if DEBUG
                AgentModePerfDiagnostics.increment("contextBuilder.run.lifecycle.attempt.ended")
                AgentModePerfDiagnostics.increment("contextBuilder.run.lifecycle.attempt.ended.source.\(source)")
            #endif
        }

        init(tabID: UUID) {
            self.tabID = tabID
            agentLog = []
            agentRunState = .idle
            isAgentBusy = false
            isCancelling = false
            didUserCancelActiveContextBuilderRun = false
            runHistory = []
            contextBuilderInstructions = ""
            generatedPlanChatID = nil
            isBackgroundPlanGenerating = false
            backgroundPlanError = nil
            backgroundPlanResponseText = nil
            backgroundPlanReasoningText = nil
            backgroundPlanResponsePreviewText = nil
            backgroundPlanReasoningPreviewText = nil
            isMCPControlledRun = false
            followUpOracleSessionID = nil
            pendingAskUser = nil
            askUserContinuation = nil
            askUserTimeoutTask = nil
            pendingAskUserTimeoutGeneration = 0
            autoGeneratePlan = false
            selectedFollowUpType = .plan
        }
    }

    // MARK: - MCP Programmatic Run Support

    /// Snapshot of a completed discover run for MCP clients
    struct ContextBuilderRunSnapshot {
        let runID: UUID
        let tabID: UUID
        let finalState: ComposeTabState?
        let runState: AgentRunState
        /// Combined assistant output text from the agent run
        let agentOutput: String?
        /// True if agent output was copied to the prompt area (prompt was empty)
        let usedAgentOutputAsPrompt: Bool
    }

    /// Track MCP runs waiting for completion
    private var mcpRunContinuations: [UUID: CheckedContinuation<ContextBuilderRunSnapshot, Error>] = [:]

    /// Track MCP run IDs to tab IDs for cancellation lookup
    private var mcpRunTabByRunID: [UUID: UUID] = [:]

    // MARK: - Published session-scoped proxies

    @Published var agentLog: [AgentLogEntry] = []
    @Published var agentRunState: AgentRunState = .idle
    @Published private(set) var isAgentBusy: Bool = false
    @Published private(set) var isCancelling: Bool = false
    @Published var runHistory: [AgentRun] = []
    @Published private(set) var toolCallCount: Int = 0
    @Published private(set) var runAgentKind: AgentProviderKind?
    @Published private(set) var runModelRaw: String?
    @Published private(set) var codexDynamicModels: [CodexAppServerClient.RemoteModel] = []
    @Published private(set) var acpDynamicModelRevision: Int = 0
    @Published private(set) var availableAgents: [AgentProviderKind] = AgentModelCatalog.selectableAgents(availability: .none)
    @Published var selectedAgent: AgentProviderKind = .claudeCode {
        didSet {
            guard selectedAgent != oldValue else { return }
            guard !isRestoringState else { return }
            if !isModelRawValidForSelectedAgent(selectedModelRaw) {
                isRestoringState = true
                selectedModelRaw = defaultModelRaw(for: selectedAgent)
                selectedModel = AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel
                isRestoringState = false
            }
            updateDynamicModelPolling()
            persistAgentModelGlobally()
            if let session = activeSession {
                persistSessionConfig(session)
            }
        }
    }

    @Published var selectedModelRaw: String = AgentModel.defaultModel.rawValue {
        didSet {
            guard selectedModelRaw != oldValue else { return }
            guard !isRestoringState else { return }
            if !isModelRawValidForSelectedAgent(selectedModelRaw) {
                isRestoringState = true
                selectedModelRaw = defaultModelRaw(for: selectedAgent)
                selectedModel = AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel
                isRestoringState = false
                return
            }
            let resolvedKnownModel = AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel
            if selectedModel != resolvedKnownModel {
                isRestoringState = true
                selectedModel = resolvedKnownModel
                isRestoringState = false
            }
            persistAgentModelGlobally()
            if let session = activeSession {
                persistSessionConfig(session)
            }
        }
    }

    @Published var selectedModel: AgentModel = .defaultModel {
        didSet {
            guard selectedModel != oldValue else { return }
            guard !isRestoringState else { return }
            if !isModelRawValidForSelectedAgent(selectedModel.rawValue), selectedAgent != .codexExec {
                isRestoringState = true
                selectedModelRaw = defaultModelRaw(for: selectedAgent)
                selectedModel = AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel
                isRestoringState = false
                return
            }
            let raw = selectedModel.rawValue
            if selectedModelRaw != raw {
                isRestoringState = true
                selectedModelRaw = raw
                isRestoringState = false
            } else {
                persistAgentModelGlobally()
                if let session = activeSession {
                    persistSessionConfig(session)
                }
            }
        }
    }

    @Published var contextBuilderInstructions: String = "" {
        didSet {
            guard contextBuilderInstructions != oldValue else { return }
            guard !isRestoringState, let session = activeSession else { return }
            session.contextBuilderInstructions = contextBuilderInstructions
            persistSessionConfig(session)
        }
    }

    /// Selected context builder prompt IDs for the current tab
    @Published var selectedContextBuilderPromptIDs: Set<UUID> = [] {
        didSet {
            guard selectedContextBuilderPromptIDs != oldValue else { return }
            guard !isRestoringState, let session = activeSession else { return }
            session.selectedContextBuilderPromptIDs = selectedContextBuilderPromptIDs
            persistSessionConfig(session)
        }
    }

    @Published var tokenBudget: Int = ContextBuilderDefaults.discoveryTokenBudget {
        didSet {
            guard tokenBudget != oldValue else { return }
            guard !isRestoringState else { return }
            persistTokenBudgetToWorkspace()
            if let session = activeSession {
                persistSessionConfig(session)
            }
        }
    }

    @Published var enhancementMode: PromptEnhancementMode = ContextBuilderDefaults.enhancementMode {
        didSet {
            guard enhancementMode != oldValue else { return }
            guard !isRestoringState else { return }
            persistEnhancementModeToWorkspace()
            if let session = activeSession {
                persistSessionConfig(session)
            }
        }
    }

    @Published var autoGeneratePlan: Bool = ContextBuilderDefaults.autoGeneratePlan {
        didSet {
            guard autoGeneratePlan != oldValue else { return }
            guard !isRestoringState else { return }
            // Persist to tab/session
            if let session = activeSession {
                session.autoGeneratePlan = autoGeneratePlan
                persistSessionConfig(session)
            }
            // Also persist as workspace default so new tabs inherit this setting
            persistAutoGeneratePlanToWorkspace()
        }
    }

    /// Selected follow-up type for auto-generate (plan/review/question) - per-tab setting
    @Published var selectedFollowUpType: ContextBuilderFollowUpType = .plan {
        didSet {
            guard selectedFollowUpType != oldValue else { return }
            guard !isRestoringState else { return }
            // Persist to tab/session
            if let session = activeSession {
                session.selectedFollowUpType = selectedFollowUpType
                persistSessionConfig(session)
            }
        }
    }

    @Published var allowClarifyingQuestions: Bool = ContextBuilderDefaults.allowClarifyingQuestions {
        didSet {
            guard allowClarifyingQuestions != oldValue else { return }
            guard !isRestoringState else { return }
            persistAllowClarifyingQuestionsToWorkspace()
            // When turning off main toggle, also turn off MCP toggle to avoid inconsistent state
            if !allowClarifyingQuestions, allowClarifyingQuestionsForMCP {
                allowClarifyingQuestionsForMCP = false
            }
        }
    }

    /// Allow clarifying questions when discovery is triggered via MCP (defaults false)
    @Published var allowClarifyingQuestionsForMCP: Bool = ContextBuilderDefaults.allowClarifyingQuestionsForMCP {
        didSet {
            guard allowClarifyingQuestionsForMCP != oldValue else { return }
            guard !isRestoringState else { return }
            persistAllowClarifyingQuestionsForMCPToWorkspace()
        }
    }

    /// Timeout (in seconds) for clarifying question responses (workspace-scoped)
    @Published var questionTimeoutSeconds: TimeInterval = ContextBuilderDefaults.questionTimeoutSeconds {
        didSet {
            guard questionTimeoutSeconds != oldValue else { return }
            guard !isRestoringState else { return }
            persistQuestionTimeoutToWorkspace()
        }
    }

    /// Token budget for plan generation (workspace-scoped)
    @Published var planTokenBudget: Int = ContextBuilderDefaults.planTokenBudget {
        didSet {
            guard planTokenBudget != oldValue else { return }
            guard !isRestoringState else { return }
            persistPlanTokenBudgetToWorkspace()
        }
    }

    @Published private(set) var sessions: [UUID: TabSession] = [:]

    /// Current tab ID - derived from promptManager (single source of truth)
    var currentTabID: UUID? {
        promptManager.activeComposeTabID
    }

    /// Track last processed tab to detect changes
    private var lastProcessedTabID: UUID?
    /// Chat session ID from plan generation (synced from active TabSession)
    @Published private(set) var generatedPlanChatID: String?

    // MARK: - Background Plan Generation State

    /// Note: backgroundPlanTask is tracked per-tab in TabSession to allow concurrent plan generation across different tabs.
    /// The single global oracleViewModel is used for all tabs.
    /// True when a plan is being generated in the background (headless mode) - synced from active TabSession
    @Published private(set) var isBackgroundPlanGenerating: Bool = false
    /// Error message if background plan generation failed - synced from active TabSession
    @Published private(set) var backgroundPlanError: String?
    /// Preview-safe projection of the plan response, trimmed to avoid large SwiftUI renders
    @Published private(set) var backgroundPlanResponsePreviewText: String?
    /// Preview-safe projection of the reasoning text, trimmed to avoid large SwiftUI renders
    @Published private(set) var backgroundPlanReasoningPreviewText: String?

    // MARK: - MCP Control State

    /// When true, MCP is controlling the current run and UI auto-generate should be suppressed
    @Published private(set) var isMCPControlledRun: Bool = false
    /// MCP response_type requested (plan/question/review/clarify) - synced from active TabSession
    @Published private(set) var mcpResponseType: String?
    /// Model name that will be used for MCP plan generation - synced from active TabSession
    @Published private(set) var mcpPlanModel: String?

    // MARK: - Clarifying Questions State

    /// Pending structured ask_user interaction from the agent awaiting user response (synced from active TabSession)
    @Published private(set) var pendingAskUser: AgentAskUserPendingState?

    /// Set of tab IDs that currently have an active discovery run (UI or MCP-initiated)
    @Published private(set) var tabsWithActiveContextBuilderRun: Set<UUID> = []

    private static let backgroundPlanUIRefreshDelayNanos: UInt64 = 200_000_000
    private var pendingBackgroundPlanRefreshTabIDs: Set<UUID> = []
    private var backgroundPlanUIRefreshTask: Task<Void, Never>?

    /// Set of tab IDs that currently have an active plan generation running
    var tabsWithActivePlanGeneration: Set<UUID> {
        Set(sessions.filter(\.value.isBackgroundPlanGenerating).map(\.key))
    }

    // MARK: - Computed properties

    private var activeSession: TabSession? {
        guard let id = currentTabID else { return nil }
        return sessions[id]
    }

    private static let planPreviewCharacterLimit = 64000
    private static let planPreviewLineLimit = 1200

    private static func makePlanPreview(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        var preview = text
        var truncated = false

        if preview.count > planPreviewCharacterLimit {
            preview = String(preview.suffix(planPreviewCharacterLimit))
            truncated = true
        }

        let lines = preview.split(whereSeparator: \.isNewline)
        if lines.count > planPreviewLineLimit {
            preview = lines.suffix(planPreviewLineLimit).joined(separator: "\n")
            truncated = true
        }

        if truncated {
            preview = "[Truncated]\n" + preview.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return preview
    }

    private func applyPlanPreview(to session: TabSession) {
        session.backgroundPlanResponsePreviewText = Self.makePlanPreview(from: session.backgroundPlanResponseText)
        session.backgroundPlanReasoningPreviewText = Self.makePlanPreview(from: session.backgroundPlanReasoningText)
    }

    private func applyBackgroundPlanBindings(from session: TabSession) {
        isBackgroundPlanGenerating = session.isBackgroundPlanGenerating
        backgroundPlanError = session.backgroundPlanError
        backgroundPlanResponsePreviewText = session.backgroundPlanResponsePreviewText
        backgroundPlanReasoningPreviewText = session.backgroundPlanReasoningPreviewText
    }

    private func requestBackgroundPlanUIRefresh(
        for tabID: UUID,
        urgent: Bool = false
    ) {
        pendingBackgroundPlanRefreshTabIDs.insert(tabID)
        if urgent {
            flushPendingBackgroundPlanUIRefresh(cancelScheduled: true)
            return
        }
        guard backgroundPlanUIRefreshTask == nil else { return }
        backgroundPlanUIRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.backgroundPlanUIRefreshDelayNanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushPendingBackgroundPlanUIRefresh()
            }
        }
    }

    private func flushPendingBackgroundPlanUIRefresh(cancelScheduled: Bool = false) {
        if cancelScheduled {
            backgroundPlanUIRefreshTask?.cancel()
        }
        backgroundPlanUIRefreshTask = nil
        guard !pendingBackgroundPlanRefreshTabIDs.isEmpty else { return }
        let tabIDs = pendingBackgroundPlanRefreshTabIDs
        pendingBackgroundPlanRefreshTabIDs.removeAll()
        guard let currentTabID else { return }
        guard tabIDs.contains(currentTabID), let session = sessions[currentTabID] else { return }
        applyBackgroundPlanBindings(from: session)
    }

    private func clearPendingBackgroundPlanUIRefresh(for tabID: UUID) {
        pendingBackgroundPlanRefreshTabIDs.remove(tabID)
        guard pendingBackgroundPlanRefreshTabIDs.isEmpty else { return }
        backgroundPlanUIRefreshTask?.cancel()
        backgroundPlanUIRefreshTask = nil
    }

    var selectedModelDisplayName: String {
        AgentModelCatalog.displayName(
            for: selectedModelRaw,
            agentKind: selectedAgent,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    var runModelDisplayName: String {
        let rawModel = runModelRaw ?? selectedModelRaw
        let agent = runAgentKind ?? selectedAgent
        return AgentModelCatalog.displayName(
            for: rawModel,
            agentKind: agent,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    func modelOptions(for agentKind: AgentProviderKind) -> [AgentModelOption] {
        AgentModelCatalog.options(for: agentKind, availability: agentAvailabilityContext, codexDynamicModels: codexDynamicModels)
    }

    func selectModel(rawModel: String) {
        selectedModelRaw = rawModel
        AgentModelCatalog.updateLastUsedEffortIfEncoded(
            agentKind: selectedAgent,
            rawModel: selectedModelRaw
        )
    }

    // MARK: - Dependencies

    private let promptManager: PromptViewModel
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private let mcpServer: MCPServerViewModel
    /// Chat VM used for headless plan generation from discovery.
    /// Weak to avoid accidental strong cycles with the view layer.
    private weak var oracleViewModel: OracleViewModel?
    private let maxHistoryCount = 5
    private var isRestoringState = false
    private let settingsManager = GlobalSettingsStore.shared
    private var cancellables = Set<AnyCancellable>()

    private var currentWorkspaceID: UUID? {
        workspaceManager?.activeWorkspaceID
    }

    private var currentWorkspacePath: String? {
        workspaceManager?.activeWorkspace?.repoPaths.first
    }

    /// Track which agents are running (for cleanup)
    private var activeAgentRuns: Set<UUID> = []

    /// Token for tab-close listener (to remove on deinit if needed)
    private var tabCloseListenerToken: UUID?
    private var codexModelsSubscriptionTask: Task<Void, Never>?
    private var openCodeModelsSubscriptionTask: Task<Void, Never>?
    private var cursorModelsSubscriptionTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init(
        promptManager: PromptViewModel,
        workspaceManager: WorkspaceManagerViewModel,
        mcpServer: MCPServerViewModel,
        oracleViewModel: OracleViewModel
    ) {
        self.promptManager = promptManager
        self.workspaceManager = workspaceManager
        self.mcpServer = mcpServer
        self.oracleViewModel = oracleViewModel
        refreshAvailableAgents()

        handleWorkspaceSwitch(workspaceManager.activeWorkspace)

        workspaceManager.addWorkspaceDidSwitchListener(label: "discover") { [weak self] workspace in
            guard let self else { return }
            Task { @MainActor in
                self.handleWorkspaceSwitch(workspace)
            }
        }

        workspaceManager.addBeforeSaveListener { [weak self] _ in
            guard let self else { return }
            persistCurrentSession()
        }

        // Reload agent/model when recommendations are applied
        NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                // If notification includes a workspaceID, only sync if it matches this VM's workspace
                if let targetWorkspaceID = notification.userInfo?["workspaceID"] as? UUID {
                    guard targetWorkspaceID == currentWorkspaceID else { return }
                    // Note: ContextBuilderAgentViewModel uses GlobalSettingsStore directly (no overlay),
                    // so no need to discard - just re-apply from workspace
                }
                applyGlobalAgentModel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .claudeCodeGLMAvailabilityChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleClaudeCodeGLMAvailabilityChanged()
            }
            .store(in: &cancellables)

        if let apiSettingsViewModel = promptManager.apiSettingsViewModel {
            Publishers.MergeMany(
                apiSettingsViewModel.$isClaudeCodeConnected.dropFirst().map { _ in () },
                apiSettingsViewModel.$isCodexConnected.dropFirst().map { _ in () },
                apiSettingsViewModel.$isOpenCodeConnected.dropFirst().map { _ in () },
                apiSettingsViewModel.$isCursorConnected.dropFirst().map { _ in () }
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAgentProviderAvailabilityChanged()
            }
            .store(in: &cancellables)
        }

        // Observe tab changes from promptManager (single source of truth)
        promptManager.$activeComposeTabID
            .removeDuplicates()
            .sink { [weak self] tabID in
                self?.onTabChanged(tabID)
            }
            .store(in: &cancellables)

        // Register for tab-close events to cancel running tasks before tabs are removed
        tabCloseListenerToken = promptManager.addComposeTabsWillCloseListener { [weak self] tabIDs in
            guard let self else { return }
            await handleComposeTabsWillClose(tabIDs)
        }
        updateDynamicModelPolling(startCursorPolling: false)
    }

    /// Note: Real cleanup happens in handleWorkspaceSwitch(nil) when window closes.
    /// Deinit is just a safety net - continuations are Sendable and can be resumed from any thread.
    /// Background plan tasks are now tracked per-session and cleaned up in handleWorkspaceSwitch.
    nonisolated deinit {
        // These are Sendable and safe to access/resume from any thread
        for (_, continuation) in mcpRunContinuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private var agentAvailabilityContext: AgentModelCatalog.AvailabilityContext {
        promptManager.apiSettingsViewModel?.agentModeAvailabilityContext ?? .current
    }

    private func defaultModelRaw(for agent: AgentProviderKind) -> String {
        AgentModelCatalog.defaultModelRaw(for: agent, availability: agentAvailabilityContext, codexDynamicModels: codexDynamicModels)
    }

    private func normalizedSelection(agentRaw: String?, modelRaw: String?) -> AgentModelCatalog.NormalizedAgentSelection {
        AgentModelCatalog.normalizeSelection(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    private func refreshAvailableAgents() {
        availableAgents = AgentModelCatalog.selectableAgents(availability: agentAvailabilityContext)
    }

    private func isModelRawValidForSelectedAgent(_ rawModel: String) -> Bool {
        AgentModelCatalog.isValid(
            rawModel: rawModel,
            for: selectedAgent,
            availability: agentAvailabilityContext,
            codexDynamicModels: codexDynamicModels
        )
    }

    private func handleClaudeCodeGLMAvailabilityChanged() {
        handleAgentProviderAvailabilityChanged()
    }

    private func handleAgentProviderAvailabilityChanged() {
        refreshAvailableAgents()
        let normalized = normalizedSelection(agentRaw: selectedAgent.rawValue, modelRaw: selectedModelRaw)
        guard normalized.agent != selectedAgent || normalized.modelRaw.caseInsensitiveCompare(selectedModelRaw) != .orderedSame else {
            return
        }
        isRestoringState = true
        selectedAgent = normalized.agent
        selectedModelRaw = normalized.modelRaw
        selectedModel = AgentModel.resolvedModel(forRaw: normalized.modelRaw, agentKind: normalized.agent) ?? .defaultModel
        isRestoringState = false
        updateDynamicModelPolling()
    }

    private func updateDynamicModelPolling(startCursorPolling: Bool = true) {
        updateCodexModelPolling()
        updateOpenCodeModelPolling()
        updateCursorModelPolling(startPolling: startCursorPolling)
    }

    private func updateCodexModelPolling() {
        if selectedAgent == .codexExec {
            startCodexModelsSubscriptionIfNeeded()
        } else {
            stopCodexModelsSubscription()
        }
    }

    private func startCodexModelsSubscriptionIfNeeded() {
        guard codexModelsSubscriptionTask == nil else { return }
        codexModelsSubscriptionTask = Task { [weak self] in
            guard let self else { return }
            let stream = await CodexModelPollingService.shared.subscribe()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.codexDynamicModels = snapshot.models
                }
            }
        }
    }

    private func stopCodexModelsSubscription() {
        codexModelsSubscriptionTask?.cancel()
        codexModelsSubscriptionTask = nil
    }

    private func updateOpenCodeModelPolling() {
        if selectedAgent == .openCode {
            startOpenCodeModelsSubscriptionIfNeeded()
        } else {
            stopOpenCodeModelsSubscription()
        }
    }

    private func startOpenCodeModelsSubscriptionIfNeeded() {
        guard openCodeModelsSubscriptionTask == nil else { return }
        let workspacePath = currentWorkspacePath
        openCodeModelsSubscriptionTask = Task { [weak self, workspacePath] in
            let stream = await OpenCodeACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    acpDynamicModelRevision &+= 1
                    syncSelectedACPModelFromRegistryIfNeeded(for: .openCode)
                }
            }
        }
    }

    private func stopOpenCodeModelsSubscription() {
        openCodeModelsSubscriptionTask?.cancel()
        openCodeModelsSubscriptionTask = nil
    }

    private func updateCursorModelPolling(startPolling: Bool = true) {
        guard selectedAgent == .cursor else {
            stopCursorModelsSubscription()
            return
        }
        guard startPolling,
              AgentModelCatalog.isAgentAvailable(.cursor, availability: agentAvailabilityContext)
        else {
            return
        }
        startCursorModelsSubscriptionIfNeeded()
    }

    private func startCursorModelsSubscriptionIfNeeded() {
        guard cursorModelsSubscriptionTask == nil else { return }
        let workspacePath = currentWorkspacePath
        cursorModelsSubscriptionTask = Task { [weak self, workspacePath] in
            let stream = await CursorACPModelPollingService.shared.subscribe(workspacePath: workspacePath)
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    acpDynamicModelRevision &+= 1
                    syncSelectedACPModelFromRegistryIfNeeded(for: .cursor)
                }
            }
        }
    }

    private func stopCursorModelsSubscription() {
        cursorModelsSubscriptionTask?.cancel()
        cursorModelsSubscriptionTask = nil
    }

    private func syncSelectedACPModelFromRegistryIfNeeded(for agent: AgentProviderKind) {
        guard selectedAgent == agent,
              let providerID = agent.acpProviderID,
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID),
              let preferredModelRaw = snapshot.preferredModelRaw
        else {
            return
        }

        let trimmedSelection = selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIsDefault = trimmedSelection.isEmpty
            || trimmedSelection.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let selectedOption = snapshot.option(matching: selectedModelRaw)
        let selectedIsPlaceholder = selectedIsDefault || selectedOption?.isPlaceholderDefault == true
        guard selectedIsPlaceholder else { return }
        guard selectedModelRaw.caseInsensitiveCompare(preferredModelRaw) != .orderedSame else { return }

        isRestoringState = true
        selectedModelRaw = preferredModelRaw
        selectedModel = AgentModel.resolvedModel(forRaw: preferredModelRaw, agentKind: agent) ?? .defaultModel
        isRestoringState = false
        persistAgentModelGlobally()
        if let session = activeSession {
            persistSessionConfig(session)
        }
    }

    // MARK: - Tab management

    /// Called when the active tab changes (observed from promptManager)
    private func onTabChanged(_ id: UUID?) {
        guard lastProcessedTabID != id else { return }
        lastProcessedTabID = id
        guard let id else {
            clearBindings()
            applyGlobalAgentModel()
            applyWorkspaceDiscoverySettings(from: workspaceManager?.activeWorkspace)
            return
        }
        let session = session(for: id)
        loadConfigForSession(session)
        applySessionToBindings(session)
    }

    /// Force-refresh bindings for the active tab even if the tab ID has not changed.
    @MainActor
    func refreshActiveSessionBindings() {
        guard let tabID = currentTabID else {
            clearBindings()
            applyGlobalAgentModel()
            applyWorkspaceDiscoverySettings(from: workspaceManager?.activeWorkspace)
            return
        }
        // Reset guard to allow re-emit when view appears after being hidden.
        lastProcessedTabID = nil
        onTabChanged(tabID)
    }

    private func session(for tabID: UUID) -> TabSession {
        if let existing = sessions[tabID] {
            return existing
        }
        let newSession = TabSession(tabID: tabID)
        sessions[tabID] = newSession
        return newSession
    }

    private func loadConfigForSession(_ session: TabSession) {
        guard let manager = workspaceManager,
              let tabState = manager.composeTab(with: session.tabID) else { return }

        isRestoringState = true

        // Load tab-specific instructions
        session.contextBuilderInstructions = tabState.contextBuilder.instructions

        // Load tab-specific context builder prompt IDs
        session.selectedContextBuilderPromptIDs = Set(tabState.contextBuilder.selectedContextBuilderPromptIDs)

        // Agent/model selection: always from GLOBAL settings (not workspace, not tab)
        // This ensures consistent behavior across all workspaces and tabs
        let (globalAgentRaw, globalModelRaw) = settingsManager.globalContextBuilderAgentSelection()
        let normalizedAgentSelection = normalizedSelection(agentRaw: globalAgentRaw, modelRaw: globalModelRaw)

        // Load workspace-scoped settings (tokenBudget, enhancementMode, etc.)
        let workspaceSettings = settingsManager.chatSettings(for: manager.activeWorkspace?.id ?? currentWorkspaceID ?? UUID())

        // Token budget: workspace setting
        tokenBudget = workspaceSettings.discoveryTokenBudget ?? ContextBuilderDefaults.discoveryTokenBudget

        // Enhancement mode: workspace setting
        if let modeString = workspaceSettings.discoveryEnhancementMode,
           let mode = PromptEnhancementMode(rawValue: modeString)
        {
            enhancementMode = mode
        } else {
            enhancementMode = .fullRewrite
        }

        // Auto-generate plan: tab setting, falling back to workspace default
        let workspaceAutoGenerate = workspaceSettings.discoveryAutoGeneratePlan ?? ContextBuilderDefaults.autoGeneratePlan
        let tabAutoGenerate = tabState.contextBuilder.autoGeneratePlan ?? workspaceAutoGenerate
        session.autoGeneratePlan = tabAutoGenerate
        autoGeneratePlan = tabAutoGenerate

        // Selected follow-up type: tab setting, defaults to .plan
        let tabFollowUpType: ContextBuilderFollowUpType = if let rawType = tabState.contextBuilder.followUpTypeRaw,
                                                             let parsedType = ContextBuilderFollowUpType(rawValue: rawType)
        {
            parsedType
        } else {
            .plan
        }
        session.selectedFollowUpType = tabFollowUpType
        selectedFollowUpType = tabFollowUpType

        // Allow clarifying questions: workspace setting only (not tab-specific), defaults to true for UI
        allowClarifyingQuestions = workspaceSettings.discoveryAllowClarifyingQuestions ?? true
        // Allow clarifying questions for MCP: workspace setting only, defaults to false
        allowClarifyingQuestionsForMCP = workspaceSettings.discoveryAllowClarifyingQuestionsForMCP ?? false
        // Question timeout: workspace setting only
        questionTimeoutSeconds = workspaceSettings.discoveryQuestionTimeoutSeconds ?? ContextBuilderDefaults.questionTimeoutSeconds
        // Plan token budget: workspace setting only, defaults to 120k
        planTokenBudget = workspaceSettings.discoveryPlanTokenBudget ?? 120_000

        // Apply agent/model from global settings
        selectedAgent = normalizedAgentSelection.agent
        selectedModelRaw = normalizedAgentSelection.modelRaw
        selectedModel = AgentModel.resolvedModel(forRaw: selectedModelRaw, agentKind: selectedAgent) ?? .defaultModel

        isRestoringState = false
        updateDynamicModelPolling(startCursorPolling: false)
    }

    private func applySessionToBindings(_ session: TabSession) {
        isRestoringState = true
        agentLog = session.agentLog
        toolCallCount = session.toolCallCount
        agentRunState = session.agentRunState
        isAgentBusy = session.isAgentBusy
        isCancelling = session.isCancelling
        runHistory = session.runHistory
        runAgentKind = session.lastRunAgentKind
        runModelRaw = session.lastRunModelRaw
        generatedPlanChatID = session.generatedPlanChatID
        applyBackgroundPlanBindings(from: session)
        // Per-tab MCP control flag
        isMCPControlledRun = session.isMCPControlledRun
        mcpResponseType = session.mcpResponseType
        mcpPlanModel = session.mcpPlanModel
        // Per-tab clarifying questions state
        pendingAskUser = session.pendingAskUser
        // Per-tab auto-generate plan setting
        autoGeneratePlan = session.autoGeneratePlan
        // Per-tab selected follow-up type
        selectedFollowUpType = session.selectedFollowUpType
        // Agent/model/tokenBudget/enhancementMode are workspace-scoped, not tab-scoped
        contextBuilderInstructions = session.contextBuilderInstructions
        selectedContextBuilderPromptIDs = session.selectedContextBuilderPromptIDs
        isRestoringState = false
        updateDynamicModelPolling(startCursorPolling: false)
    }

    private func clearBindings() {
        isRestoringState = true
        agentLog = []
        toolCallCount = 0
        agentRunState = .idle
        isAgentBusy = false
        isCancelling = false
        runHistory = []
        runAgentKind = nil
        runModelRaw = nil
        generatedPlanChatID = nil
        // Per-tab plan UI state
        isBackgroundPlanGenerating = false
        backgroundPlanError = nil
        backgroundPlanResponsePreviewText = nil
        backgroundPlanReasoningPreviewText = nil
        // Per-tab MCP control flag
        isMCPControlledRun = false
        mcpResponseType = nil
        // Per-tab clarifying questions state
        pendingAskUser = nil
        let normalized = normalizedSelection(agentRaw: nil, modelRaw: nil)
        selectedAgent = normalized.agent
        selectedModelRaw = normalized.modelRaw
        selectedModel = AgentModel.resolvedModel(forRaw: normalized.modelRaw, agentKind: normalized.agent) ?? .defaultModel
        contextBuilderInstructions = ""
        selectedContextBuilderPromptIDs = []
        tokenBudget = ContextBuilderDefaults.discoveryTokenBudget
        enhancementMode = ContextBuilderDefaults.enhancementMode
        autoGeneratePlan = ContextBuilderDefaults.autoGeneratePlan
        selectedFollowUpType = .plan
        allowClarifyingQuestions = ContextBuilderDefaults.allowClarifyingQuestions
        allowClarifyingQuestionsForMCP = ContextBuilderDefaults.allowClarifyingQuestionsForMCP
        questionTimeoutSeconds = ContextBuilderDefaults.questionTimeoutSeconds
        planTokenBudget = ContextBuilderDefaults.planTokenBudget
        isRestoringState = false
        updateDynamicModelPolling(startCursorPolling: false)
    }

    private func updateRuntimeBindings(from session: TabSession) {
        guard session.tabID == currentTabID else { return }
        isRestoringState = true
        agentLog = session.agentLog
        toolCallCount = session.toolCallCount
        agentRunState = session.agentRunState
        isAgentBusy = session.isAgentBusy
        isCancelling = session.isCancelling
        runHistory = session.runHistory
        runAgentKind = session.lastRunAgentKind
        runModelRaw = session.lastRunModelRaw
        generatedPlanChatID = session.generatedPlanChatID
        applyBackgroundPlanBindings(from: session)
        // Per-tab MCP control flag
        isMCPControlledRun = session.isMCPControlledRun
        mcpResponseType = session.mcpResponseType
        mcpPlanModel = session.mcpPlanModel
        // Per-tab clarifying questions state
        pendingAskUser = session.pendingAskUser
        // Per-tab selected follow-up type
        selectedFollowUpType = session.selectedFollowUpType
        isRestoringState = false
        updateDynamicModelPolling()
    }

    /// Lightweight binding update for streaming hot path - only updates agentLog and toolCallCount.
    /// Use this instead of updateRuntimeBindings during streaming to avoid excessive SwiftUI updates.
    /// Note: pendingAskUser and other state changes have their own explicit updateRuntimeBindings calls.
    private func updateAgentLogBinding(from session: TabSession) {
        guard session.tabID == currentTabID else { return }
        agentLog = session.agentLog
        toolCallCount = session.toolCallCount
    }

    // MARK: - Workspace coordination

    private func handleWorkspaceSwitch(_ workspace: WorkspaceModel?) {
        stopCodexModelsSubscription()
        stopOpenCodeModelsSubscription()
        stopCursorModelsSubscription()

        // Fail any pending MCP continuations before clearing sessions
        for (runID, continuation) in mcpRunContinuations {
            continuation.resume(throwing: CancellationError())
            mcpRunTabByRunID.removeValue(forKey: runID)
        }
        mcpRunContinuations.removeAll()

        for session in sessions.values {
            // Cancel any pending clarifying questions
            cancelPendingQuestion(for: session)
            session.agentTask?.cancel()
            // Cancel any background plan generation for this session
            session.backgroundPlanTask?.cancel()
            session.backgroundPlanTask = nil
            if let oracleVM = oracleViewModel {
                if let followUpSessionID = session.followUpOracleSessionID {
                    Task { @MainActor in
                        await oracleVM.cancelStreaming(in: followUpSessionID)
                    }
                }
            }
            session.followUpOracleSessionID = nil
            if let provider = session.activeAgentProvider {
                Task { await provider.dispose() }
            }
        }
        sessions.removeAll()
        lastProcessedTabID = nil
        clearBindings()
        tabsWithActiveContextBuilderRun.removeAll()

        guard let workspace else { return }
        // Apply workspace defaults after clearing bindings (will be overridden by tab-specific settings when tab loads)
        applyGlobalAgentModel()
        applyWorkspaceDiscoverySettings(from: workspace)
        // Manually trigger tab reload since $activeComposeTabID uses .removeDuplicates()
        // and won't emit if the tab ID hasn't changed. Since we just set lastProcessedTabID = nil,
        // onTabChanged will reload the current tab's state.
        onTabChanged(promptManager.activeComposeTabID)
    }

    // MARK: - Tab Close Cleanup

    /// Called before compose tabs are closed. Cancels all running tasks for those tabs.
    @MainActor
    private func handleComposeTabsWillClose(_ tabIDs: Set<UUID>) async {
        for tabID in tabIDs {
            guard let session = sessions[tabID] else { continue }

            debugLog("handleComposeTabsWillClose: cleaning up tab \(tabID)")

            // 1. Cancel any pending clarifying question
            cancelPendingQuestion(for: session)

            // 2. Cancel background plan generation for this tab
            if session.isBackgroundPlanGenerating {
                debugLog("handleComposeTabsWillClose: cancelling background plan for tab \(tabID)")
                session.backgroundPlanTask?.cancel()
                session.backgroundPlanTask = nil
                session.isBackgroundPlanGenerating = false
                if let followUpSessionID = session.followUpOracleSessionID {
                    await oracleViewModel?.cancelStreaming(in: followUpSessionID)
                }
                session.followUpOracleSessionID = nil
            }

            // 3. Cancel agent run if running
            if session.agentRunState.isRunning || session.agentTask != nil {
                debugLog("handleComposeTabsWillClose: cancelling agent run for tab \(tabID)")
                let agentKind = effectiveRunAgentKind(for: session)
                await cancelRun(for: session, agent: agentKind)
            }

            // 4. Fail any MCP continuations waiting on this tab
            for (runID, mappedTabID) in mcpRunTabByRunID where mappedTabID == tabID {
                debugLog("handleComposeTabsWillClose: failing MCP continuation for runID \(runID)")
                if let continuation = mcpRunContinuations.removeValue(forKey: runID) {
                    continuation.resume(throwing: CancellationError())
                }
                mcpRunTabByRunID.removeValue(forKey: runID)
            }

            // 5. Remove session and tracking state
            sessions.removeValue(forKey: tabID)
            tabsWithActiveContextBuilderRun.remove(tabID)

            // 6. If this was the current tab, bindings will be updated by the tab-change observer
        }
    }

    /// Load agent/model defaults from workspace settings.
    /// Used during workspace switch to initialize defaults before tab-specific settings are loaded.
    /// Apply global Context Builder agent/model selection.
    /// Used during workspace switch to initialize agent/model from global settings.
    private func applyGlobalAgentModel() {
        // Agent/model are now GLOBAL (not workspace-scoped)
        let (globalAgentRaw, globalModelRaw) = settingsManager.globalContextBuilderAgentSelection()
        let normalized = normalizedSelection(agentRaw: globalAgentRaw, modelRaw: globalModelRaw)

        isRestoringState = true
        selectedAgent = normalized.agent
        selectedModelRaw = normalized.modelRaw
        selectedModel = AgentModel.resolvedModel(forRaw: normalized.modelRaw, agentKind: normalized.agent) ?? .defaultModel
        isRestoringState = false
        refreshAvailableAgents()
        updateDynamicModelPolling(startCursorPolling: false)
    }

    /// Load workspace-scoped discovery defaults (token budget, enhancement mode, clarifying questions, plan budget).
    /// Used during workspace switch to initialize defaults before tab-specific settings are loaded.
    private func applyWorkspaceDiscoverySettings(from workspace: WorkspaceModel?) {
        guard let id = workspace?.id ?? currentWorkspaceID else { return }
        let settings = settingsManager.chatSettings(for: id)

        isRestoringState = true
        tokenBudget = settings.discoveryTokenBudget ?? ContextBuilderDefaults.discoveryTokenBudget
        // Restore enhancement mode from raw value, with migration from old Bool setting
        if let modeString = settings.discoveryEnhancementMode,
           let mode = PromptEnhancementMode(rawValue: modeString)
        {
            enhancementMode = mode
        } else {
            enhancementMode = ContextBuilderDefaults.enhancementMode
        }
        allowClarifyingQuestions = settings.discoveryAllowClarifyingQuestions ?? ContextBuilderDefaults.allowClarifyingQuestions
        allowClarifyingQuestionsForMCP = settings.discoveryAllowClarifyingQuestionsForMCP ?? ContextBuilderDefaults.allowClarifyingQuestionsForMCP
        questionTimeoutSeconds = settings.discoveryQuestionTimeoutSeconds ?? ContextBuilderDefaults.questionTimeoutSeconds
        planTokenBudget = settings.discoveryPlanTokenBudget ?? ContextBuilderDefaults.planTokenBudget
        autoGeneratePlan = settings.discoveryAutoGeneratePlan ?? ContextBuilderDefaults.autoGeneratePlan
        isRestoringState = false
    }

    /// Update GLOBAL agent/model selection.
    /// Agent/model are now global (shared across all workspaces), not workspace-scoped.
    private func persistAgentModelGlobally() {
        guard !isRestoringState else { return }

        // Update global settings (single source of truth)
        settingsManager.setGlobalContextBuilderAgentSelection(
            agentRaw: selectedAgent.rawValue,
            modelRaw: selectedModelRaw,
            markUserDefined: true
        )

        // Notify recommendation system that inputs have changed
        // This triggers wizard recompute without affecting PromptVM overlays
        NotificationCenter.default.post(
            name: .recommendationsShouldRefresh,
            object: nil,
            userInfo: ["reason": "discoverAgentChanged"]
        )
    }

    @MainActor
    func resolvedMCPContextBuilderBudget(for workspaceID: UUID, wantsResponse: Bool) -> Int {
        let settings = settingsManager.chatSettings(for: workspaceID)
        return ContextBuilderBudgetResolver.resolveBudget(
            wantsResponse: wantsResponse,
            discoveryTokenBudget: settings.discoveryTokenBudget,
            planTokenBudget: settings.discoveryPlanTokenBudget
        )
    }

    /// Update workspace defaults for token budget (used as default when creating new tabs).
    /// Note: Settings are saved to both the current tab and workspace defaults.
    private func persistTokenBudgetToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryTokenBudget = tokenBudget
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace defaults for enhancement mode (used as default when creating new tabs).
    /// Note: Settings are saved to both the current tab and workspace defaults.
    private func persistEnhancementModeToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryEnhancementMode = enhancementMode.rawValue
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace setting for allowing clarifying questions during discovery.
    private func persistAllowClarifyingQuestionsToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryAllowClarifyingQuestions = allowClarifyingQuestions
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace setting for allowing clarifying questions during MCP-triggered discovery.
    private func persistAllowClarifyingQuestionsForMCPToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryAllowClarifyingQuestionsForMCP = allowClarifyingQuestionsForMCP
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace setting for question timeout.
    private func persistQuestionTimeoutToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryQuestionTimeoutSeconds = questionTimeoutSeconds
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace setting for plan token budget.
    private func persistPlanTokenBudgetToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryPlanTokenBudget = planTokenBudget
        settingsManager.updateChatSettings(settings, commit: true)
    }

    /// Update workspace default for auto-generate plan setting.
    /// This ensures new tabs inherit the user's preference instead of falling back to a potentially stale default.
    private func persistAutoGeneratePlanToWorkspace() {
        guard !isRestoringState, let wsID = currentWorkspaceID else { return }
        var settings = settingsManager.chatSettings(for: wsID)
        settings.discoveryAutoGeneratePlan = autoGeneratePlan
        settingsManager.updateChatSettings(settings, commit: true)
    }

    // MARK: - Persistence

    private func persistSessionConfig(_ session: TabSession, markWorkspaceDirty: Bool = true) {
        guard !isRestoringState,
              let manager = workspaceManager,
              var tab = manager.composeTab(with: session.tabID) else { return }

        // Persist tab-specific settings only (not agent/model which are workspace-scoped)
        // Agent/model and token settings are intentionally not persisted per tab.
        tab.contextBuilder = ContextBuilderTabConfig(
            instructions: session.contextBuilderInstructions,
            autoGeneratePlan: session.autoGeneratePlan,
            followUpTypeRaw: session.selectedFollowUpType.rawValue,
            selectedContextBuilderPromptIDs: Array(session.selectedContextBuilderPromptIDs)
        )
        manager.updateComposeTab(tab, markDirty: markWorkspaceDirty)
    }

    private func persistCurrentSession() {
        guard let session = activeSession else { return }
        persistSessionConfig(session, markWorkspaceDirty: false)
    }

    // MARK: - Run lifecycle

    /// MCP-specific entry point to run Context Builder and await completion.
    /// Returns a snapshot of the final tab state after the run completes.
    /// Note: Sets `isMCPControlledRun = true` to suppress UI auto-generate.
    /// Caller (executeContextBuilder) is responsible for clearing the flag after follow-up generation.
    /// Note: All overrides are ephemeral - original UI settings are restored after the run.
    @MainActor
    func runContextBuilderForMCP(
        tabID: UUID,
        instructionsOverride: String? = nil,
        tokenBudgetOverride: Int? = nil,
        persistTokenBudget: Bool = true,
        enhancementModeOverride: PromptEnhancementMode? = nil,
        agentOverride: AgentProviderKind? = nil,
        modelOverrideRaw: String? = nil,
        responseType: String? = nil,
        planModelName: String? = nil
    ) async throws -> ContextBuilderRunSnapshot {
        // 1. Ensure session exists for this tab (MCP may run against a background tab)
        let session = session(for: tabID)
        if lastProcessedTabID != tabID {
            lastProcessedTabID = tabID
            loadConfigForSession(session)
            applySessionToBindings(session)
        }

        // Mark this tab as MCP-controlled to suppress UI auto-generate
        session.isMCPControlledRun = true
        session.mcpResponseType = responseType
        session.mcpPlanModel = planModelName
        updateRuntimeBindings(from: session)

        // 2. Capture current UI state for restoration after MCP run
        // MCP overrides are ephemeral and should not persist to user settings
        let savedInstructions = contextBuilderInstructions
        let savedAgent = selectedAgent
        let savedModelRaw = selectedModelRaw
        let savedEnhancementMode = enhancementMode
        let savedTokenBudget = tokenBudget
        let savedSessionInstructions = session.contextBuilderInstructions
        let previousBudgetOverride = session.tokenBudgetOverrideForRun

        // 3. Apply overrides with isRestoringState to suppress persistence
        isRestoringState = true
        if let override = instructionsOverride {
            session.contextBuilderInstructions = override
            contextBuilderInstructions = override
        }
        if let budget = tokenBudgetOverride {
            if persistTokenBudget {
                tokenBudget = budget
            } else {
                session.tokenBudgetOverrideForRun = budget
            }
        }
        if let mode = enhancementModeOverride {
            enhancementMode = mode
        }
        if let agent = agentOverride {
            selectedAgent = agent
        }
        if let modelOverrideRaw {
            let normalizedModelRaw = modelOverrideRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedModelRaw.isEmpty,
               AgentModelCatalog.isValid(
                   rawModel: normalizedModelRaw,
                   for: selectedAgent,
                   availability: agentAvailabilityContext,
                   codexDynamicModels: codexDynamicModels
               )
            {
                selectedModelRaw = normalizedModelRaw
                selectedModel = AgentModel.resolvedModel(forRaw: normalizedModelRaw, agentKind: selectedAgent) ?? .defaultModel
            }
        }
        isRestoringState = false

        // Persist MCP instructions to tab state so they survive tab switches and UI refreshes.
        // For new MCP-created tabs, this ensures the instructions field shows the provided value.
        if instructionsOverride != nil {
            persistSessionConfig(session, markWorkspaceDirty: false)
        }

        // Use AsyncScope to ensure UI state is restored after MCP run completes
        return try await AsyncScope.withCleanup {} cleanup: { [weak self] in
            guard let self else { return }
            // Restore original UI state - MCP overrides are ephemeral
            // EXCEPT for instructions when an override was provided - those are persisted
            // to the tab state and should remain visible in the UI
            isRestoringState = true
            if instructionsOverride == nil {
                contextBuilderInstructions = savedInstructions
            }
            selectedAgent = savedAgent
            selectedModelRaw = savedModelRaw
            selectedModel = AgentModel.resolvedModel(forRaw: savedModelRaw, agentKind: savedAgent) ?? .defaultModel
            enhancementMode = savedEnhancementMode
            tokenBudget = savedTokenBudget
            if let session = sessions[tabID] {
                session.tokenBudgetOverrideForRun = previousBudgetOverride
                if instructionsOverride == nil {
                    session.contextBuilderInstructions = savedSessionInstructions
                }
                updateRuntimeBindings(from: session)
            }
            isRestoringState = false
        } operation: { [weak self] in
            guard let self else {
                throw NSError(domain: "DiscoverAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "ViewModel deallocated"])
            }

            // 4. Check if already running
            guard !session.agentRunState.isRunning, !session.isAgentBusy else {
                throw NSError(domain: "DiscoverAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Context Builder is already running for this tab"])
            }

            // 5. Check workspace
            guard workspaceManager?.activeWorkspace?.isSystemWorkspace == false else {
                throw NSError(domain: "DiscoverAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "No workspace open"])
            }

            // 5b. Capture run-start state to prevent tab bleed during MCP run.
            // Note: instructionsOverride only affects session.contextBuilderInstructions (already set above),
            // NOT the tab's main prompt content. This preserves existing MCP semantics where
            // <current_prompt_content> = tab's prompt, <discover_instructions> = override instructions.
            captureRunStartState(for: session)

            // 6. Start the run
            session.agentTask?.cancel()
            session.resetLog()
            let runAgent = selectedAgent
            let runModelRaw = selectedModelRaw
            session.lastRunAgentKind = runAgent
            session.lastRunModelRaw = runModelRaw
            session.appendLogEntry(
                AgentLogEntry(
                    timestamp: Date(),
                    type: .system,
                    message: "Starting \(runAgent.displayName) agent (MCP-initiated)..."
                )
            )

            let runID = UUID()
            let ownership = session.beginRunAttempt(source: "contextBuilder.mcp")
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
            tabsWithActiveContextBuilderRun.insert(tabID)
            mcpRunTabByRunID[runID] = tabID
            session.agentRunState = .running(runID)
            session.isCancelling = false
            session.didUserCancelActiveContextBuilderRun = false
            session.isAgentBusy = true
            updateRuntimeBindings(from: session)

            debugLog("Starting MCP run with ID: \(runID)")

            let agentKind = runAgent
            let modelRaw = runModelRaw
            session.agentTask = Task { @MainActor [weak self] in
                guard let self else { return }

                await session.runLifecycleGate.withPermit {
                    await AsyncScope.withCleanup({}, cleanup: { [runID] in
                        await self.restoreToolRestrictions(agent: agentKind, runID: runID)
                    }) {
                        await self.performContextBuilderAgentRun(
                            session: session,
                            runID: runID,
                            connectionID: runID,
                            agentKind: agentKind,
                            modelRaw: modelRaw,
                            ownership: ownership
                        )
                    }
                }

                session.endRunAttempt(ifCurrent: ownership, source: "contextBuilder.mcp.cleanup")
                session.agentTask = nil
                session.isAgentBusy = false
                session.isCancelling = false
                clearRunStartState(for: session)
                tabsWithActiveContextBuilderRun.remove(tabID)
                updateRuntimeBindings(from: session)
            }

            // 7. Wait for completion via continuation. If the wrapping MCP tool task
            // is cancelled (for example by a tool-card cancel button), propagate that
            // cancellation into the unstructured discovery run and resume this waiter.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.mcpRunContinuations[runID] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    await self?.cancelMCPContextBuilderRun(runID: runID)
                }
            }
        }
    }

    /// If the main prompt area is empty but we have agent output,
    /// copy the agent output to the prompt area so the user can see it.
    /// Sets `session.usedAgentOutputAsPrompt` and returns the extracted agent output.
    @discardableResult
    private func copyAgentOutputToPromptIfEmpty(session: TabSession) -> String? {
        // Prefer the full accumulated assistant output. The visible assistant row is only a compact preview.
        let accumulatedOutput = session.lastAgentOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? session.lastAgentOutput
            : nil
        let logPreviewFallback = session.agentLog
            .first { $0.type == .assistant }?
            .message
        let agentOutput = accumulatedOutput ?? logPreviewFallback

        debugLog("copyAgentOutputToPromptIfEmpty: logCount=\(session.agentLog.count), agentOutput length=\(agentOutput?.count ?? 0)")

        // Store on session for MCP snapshot
        session.lastAgentOutput = agentOutput

        // Reset flag at start
        session.usedAgentOutputAsPrompt = false

        guard let manager = workspaceManager else {
            debugLog("copyAgentOutputToPromptIfEmpty: workspaceManager is nil")
            return agentOutput
        }

        guard var tab = manager.composeTab(with: session.tabID) else {
            debugLog("copyAgentOutputToPromptIfEmpty: tab not found for \(session.tabID)")
            return agentOutput
        }

        let promptEmpty = tab.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        debugLog("copyAgentOutputToPromptIfEmpty: promptText length=\(tab.promptText.count), empty=\(promptEmpty)")

        guard promptEmpty else {
            debugLog("copyAgentOutputToPromptIfEmpty: prompt not empty, skipping")
            return agentOutput
        }

        guard let output = agentOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("copyAgentOutputToPromptIfEmpty: no agent output to copy")
            return agentOutput
        }

        debugLog("copyAgentOutputToPromptIfEmpty: copying agent output to prompt (\(output.count) chars)")
        tab.promptText = output
        // Clear any override since we're putting content directly in the prompt
        tab.contextOverrides.useOverridePrompt = false
        tab.contextOverrides.overridePromptText = ""
        manager.updateComposeTab(tab, markDirty: true)
        session.usedAgentOutputAsPrompt = true

        return agentOutput
    }

    /// Notify any waiting MCP continuation that a run has completed
    private func notifyMCPIfWaiting(runID: UUID, session: TabSession) {
        // Clean up runID → tabID mapping
        mcpRunTabByRunID.removeValue(forKey: runID)

        guard let continuation = mcpRunContinuations.removeValue(forKey: runID) else { return }

        let finalState = snapshotForTab(session.tabID)

        let snapshot = ContextBuilderRunSnapshot(
            runID: runID,
            tabID: session.tabID,
            finalState: finalState,
            runState: session.agentRunState,
            agentOutput: session.lastAgentOutput,
            usedAgentOutputAsPrompt: session.usedAgentOutputAsPrompt
        )
        continuation.resume(returning: snapshot)
    }

    func runContextBuilderAgent() {
        guard let tabID = currentTabID else { return }
        let session = session(for: tabID)

        guard !session.agentRunState.isRunning, !session.isAgentBusy else {
            debugLog("Run ignored (busy or already running)")
            return
        }

        guard workspaceManager?.activeWorkspace?.isSystemWorkspace == false else {
            debugLog("Run blocked: no workspace or system workspace active")
            let entry = AgentLogEntry(
                timestamp: Date(),
                type: .system,
                message: "Open a workspace before running Context Builder."
            )
            session.appendLogEntry(entry)
            session.agentRunState = .failed("No workspace open")
            updateRuntimeBindings(from: session)
            return
        }

        session.agentTask?.cancel()
        session.resetLog()
        // Wipe any previous plan state for this tab only (not other tabs)
        session.generatedPlanChatID = nil
        session.backgroundPlanError = nil
        session.backgroundPlanResponseText = nil
        session.backgroundPlanReasoningText = nil
        applyPlanPreview(to: session)
        clearBackgroundPlanState(forTabID: tabID) // Cancel any in-progress background plan for THIS tab

        // Capture tab state at run start to prevent bleed on tab switch
        captureRunStartState(for: session)

        let runAgent = selectedAgent
        let runModelRaw = selectedModelRaw
        session.lastRunAgentKind = runAgent
        session.lastRunModelRaw = runModelRaw

        session.appendLogEntry(
            AgentLogEntry(
                timestamp: Date(),
                type: .system,
                message: "Starting \(runAgent.displayName) agent..."
            )
        )

        let runID = UUID()
        let ownership = session.beginRunAttempt(source: "contextBuilder.ui")
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        tabsWithActiveContextBuilderRun.insert(tabID)
        session.agentRunState = .running(runID)
        session.isCancelling = false
        session.didUserCancelActiveContextBuilderRun = false
        session.isAgentBusy = true
        updateRuntimeBindings(from: session)

        debugLog("Starting run with ID: \(runID)")

        let agentKind = runAgent
        let modelRaw = runModelRaw
        session.agentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await session.runLifecycleGate.withPermit {
                await AsyncScope.withCleanup({}, cleanup: { [runID] in
                    await self.restoreToolRestrictions(agent: agentKind, runID: runID)
                }) {
                    await self.performContextBuilderAgentRun(
                        session: session,
                        runID: runID,
                        connectionID: runID,
                        agentKind: agentKind,
                        modelRaw: modelRaw,
                        ownership: ownership
                    )
                }
            }

            session.endRunAttempt(ifCurrent: ownership, source: "contextBuilder.ui.cleanup")
            session.agentTask = nil
            session.isAgentBusy = false
            session.isCancelling = false
            clearRunStartState(for: session)
            tabsWithActiveContextBuilderRun.remove(tabID)
            updateRuntimeBindings(from: session)
        }
    }

    /// Note:
    /// Discovery runs manage their client connection policy cleanup (restoreToolRestrictions) in runContextBuilderAgent,
    /// not inside performContextBuilderAgentRun. This separation ensures the tab‑context commit/clear sequence at end‑of‑run
    /// is ordered correctly before policies are removed.
    private func performContextBuilderAgentRun(
        session: TabSession,
        runID: UUID,
        connectionID: UUID,
        agentKind: AgentProviderKind,
        modelRaw: String,
        ownership: AgentRunOwnership
    ) async {
        await AsyncScope.withCleanup({}, cleanup: { [weak self] in
            await self?.clearTabContextForAgent(agent: agentKind, runID: runID)
        }) { [weak self] in
            guard let self else { return }

            debugLog("Starting MCP server for window")
            await mcpServer.startServer()

            guard mcpServer.windowToolsEnabled else {
                debugLog("MCP server failed to start")
                session.appendLogEntry(
                    AgentLogEntry(
                        timestamp: Date(),
                        type: .error,
                        message: "Failed to start MCP server. Check Local Network permission in System Settings."
                    )
                )
                session.agentRunState = .failed("MCP server not running")
                saveRunToHistory(for: session)
                notifyMCPIfWaiting(runID: runID, session: session)
                updateRuntimeBindings(from: session)
                return
            }

            debugLog("Acquiring headless run lease (gate + policy)...")

            let additionalTools = additionalToolsForContextBuilderAgent(tabID: session.tabID)
            let windowID = await MainActor.run { self.mcpServer.windowID }

            let spec = AgentRunSpec(
                type: .discover,
                runID: runID,
                agentKind: agentKind,
                modelString: nil,
                windowID: windowID,
                restrictedTools: DiscoverMCPToolPolicy.restrictedTools,
                connectionTTL: 15
            )

            let lease: MCPBootstrapLease
            do {
                lease = try await AgentRunCoordinator.shared.prepareAndInstallPolicy(
                    spec,
                    tabID: session.tabID,
                    additionalTools: additionalTools,
                    reason: "discover-run",
                    gateID: runID
                )
            } catch is CancellationError {
                debugLog("Task cancelled before lease acquisition completed")
                session.appendLogEntry(
                    AgentLogEntry(timestamp: Date(), type: .system, message: "Cancelled by user")
                )
                session.agentRunState = .cancelled
                saveRunToHistory(for: session)
                notifyMCPIfWaiting(runID: runID, session: session)
                updateRuntimeBindings(from: session)
                return
            } catch {
                debugLog("Failed to acquire lease: \(error.localizedDescription)")
                session.appendLogEntry(
                    AgentLogEntry(timestamp: Date(), type: .error, message: "Failed to prepare MCP connection policy: \(error.localizedDescription)")
                )
                session.agentRunState = .failed(error.localizedDescription)
                saveRunToHistory(for: session)
                notifyMCPIfWaiting(runID: runID, session: session)
                updateRuntimeBindings(from: session)
                return
            }

            debugLog("Lease acquired; spawning agent")

            // Track this run for cleanup
            activeAgentRuns.insert(runID)

            debugLog("Creating agent provider")

            let modelString = modelRaw == AgentModel.defaultModel.rawValue ? nil : modelRaw
            let provider = AgentRuntimeProviderService.shared.makeProvider(
                for: agentKind,
                modelString: modelString,
                workspacePath: currentWorkspacePath
            )
            session.activeAgentProvider = provider

            // Note: Tab context is now installed automatically by the routing layer when the policy is applied

            // Ensure provider disposal happens in cleanup; gate release is centralized via AgentRunCoordinator
            await AsyncScope.withCleanup({}, cleanup: {
                self.debugLog("Disposing provider")
                await provider.dispose()
                session.activeAgentProvider = nil
            }) {
                @MainActor func handleStreamError(_ error: Error) async {
                    self.debugLog("Caught error: \(error)")
                    self.debugLog("Error type: \(String(describing: type(of: error)))")
                    if error is CancellationError {
                        self.debugLog("Error is CancellationError")
                        session.appendLogEntry(
                            AgentLogEntry(timestamp: Date(), type: .system, message: "Cancelled by user")
                        )
                        session.agentRunState = .cancelled
                    } else {
                        let verboseErrorMessage = self.extractVerboseErrorMessage(from: error)
                        self.debugLog("Error is not CancellationError: \(verboseErrorMessage)")
                        session.appendLogEntry(
                            AgentLogEntry(timestamp: Date(), type: .error, message: verboseErrorMessage)
                        )
                        session.agentRunState = .failed(verboseErrorMessage)
                    }
                }

                do {
                    self.debugLog("Building agent message")
                    let message = await self.buildAgentMessage(for: session, runID: runID)
                    self.debugLog("System prompt length: \(message.systemPrompt.count)")
                    self.debugLog("User message length: \(message.userMessage.count)")
                    self.debugLog("Starting stream with runID: \(runID)")

                    let stream = try await provider.streamAgentMessage(message, runID: runID)
                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)

                    // Centralized "release on routing" – releases the gate once mapping is established or on timeout
                    // Returns true if MCP routing succeeded, false on timeout/failure/cancellation
                    let routed = await lease.releaseWhenRouted(timeoutMs: 10000)
                    self.debugLog("Routing result for run \(runID): routed=\(routed)")

                    let connectionMessage = if routed {
                        // Only mention "via MCP" if this run was triggered by MCP context_builder
                        if session.isMCPControlledRun {
                            "\(agentKind.displayName) connected via MCP, analyzing workspace..."
                        } else {
                            "\(agentKind.displayName) connected, analyzing workspace..."
                        }
                    } else {
                        // Routing timed out or failed - agent may have limited workspace access
                        "\(agentKind.displayName) started, but MCP connection not confirmed. Tools may be unavailable."
                    }

                    session.appendLogEntry(
                        AgentLogEntry(
                            timestamp: Date(),
                            type: routed ? .system : .error,
                            message: connectionMessage
                        )
                    )
                    self.updateRuntimeBindings(from: session)

                    do {
                        for try await result in stream {
                            if Task.isCancelled {
                                self.debugLog("Task cancelled during streaming")
                                break
                            }
                            session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
                            self.debugLog("Received stream result type: \(result.type)")
                            if result.type == "content" {
                                if session.appendAssistantOutputDelta(result.text ?? "", messageID: result.contentMessageID) {
                                    // Streaming hot path: only update agentLog binding to avoid excessive SwiftUI updates
                                    self.updateAgentLogBinding(from: session)
                                }
                                continue
                            }

                            if result.type == "final_content" {
                                if let finalContent = result.text,
                                   session.replaceAssistantOutput(finalContent)
                                {
                                    // Streaming hot path: only update agentLog binding to avoid excessive SwiftUI updates
                                    self.updateAgentLogBinding(from: session)
                                }
                                continue
                            }

                            if let mapping = self.mapStreamResultToLogEntry(result) {
                                if session.appendLogEntry(mapping.entry, dedupeKey: mapping.dedupeKey) {
                                    // Streaming hot path: only update agentLog binding to avoid excessive SwiftUI updates
                                    self.updateAgentLogBinding(from: session)
                                }
                            }
                        }

                        if Task.isCancelled {
                            self.debugLog("Completed with cancellation")
                            session.appendLogEntry(
                                AgentLogEntry(timestamp: Date(), type: .system, message: "Cancelled by user")
                            )
                            session.agentRunState = .cancelled
                        } else {
                            self.debugLog("Completed successfully")
                            // Commit tab context BEFORE setting .completed state
                            // This ensures prompt/selection are available when auto-generate triggers
                            await self.commitTabContextForAgent(agent: agentKind, runID: runID)

                            // If the main prompt area is empty, copy agent output there
                            self.copyAgentOutputToPromptIfEmpty(session: session)

                            session.appendLogEntry(
                                AgentLogEntry(
                                    timestamp: Date(),
                                    type: .system,
                                    message: "✓ Context Builder complete! Selection and prompt updated."
                                )
                            )
                            session.agentRunState = .completed

                            // Trigger auto-plan for this specific tab, if enabled
                            // (skipped if we used agent output as prompt since that's already a response)
                            if !session.usedAgentOutputAsPrompt {
                                self.maybeAutoGeneratePlan(for: session)
                            }
                        }
                    } catch {
                        await handleStreamError(error)
                    }
                } catch {
                    // Ensure the gate is released even if streaming fails to begin
                    await lease.failAndCleanup()
                    await handleStreamError(error)
                }

                self.saveRunToHistory(for: session)
                self.notifyMCPIfWaiting(runID: runID, session: session)
                self.updateRuntimeBindings(from: session)
            }
        }
    }

    func cancelAgentRun() async {
        guard let session = activeSession else { return }
        let agentKind = effectiveRunAgentKind(for: session)
        await cancelRun(for: session, agent: agentKind)
    }

    /// Cancel all active discovery runs and background plan generation (used before workspace switches).
    @MainActor
    func cancelAllActiveRuns() async {
        let activeTabs = tabsWithActiveContextBuilderRun.union(tabsWithActivePlanGeneration)
        guard !activeTabs.isEmpty else { return }

        for tabID in activeTabs {
            guard let session = sessions[tabID] else { continue }

            cancelPendingQuestion(for: session)

            if session.isBackgroundPlanGenerating {
                session.backgroundPlanTask?.cancel()
                session.backgroundPlanTask = nil
                session.isBackgroundPlanGenerating = false
                if let followUpSessionID = session.followUpOracleSessionID {
                    await oracleViewModel?.cancelStreaming(in: followUpSessionID)
                }
                session.followUpOracleSessionID = nil
                updateRuntimeBindings(from: session)
            }

            if session.agentRunState.isRunning || session.agentTask != nil {
                let agentKind = effectiveRunAgentKind(for: session)
                await cancelRun(for: session, agent: agentKind)
            }

            for (runID, mappedTabID) in mcpRunTabByRunID where mappedTabID == tabID {
                if let continuation = mcpRunContinuations.removeValue(forKey: runID) {
                    continuation.resume(throwing: CancellationError())
                }
                mcpRunTabByRunID.removeValue(forKey: runID)
            }
        }
    }

    private func effectiveRunAgentKind(for session: TabSession) -> AgentProviderKind {
        session.lastRunAgentKind ?? selectedAgent
    }

    /// Cancel a MCP-triggered discovery run by runID.
    /// This allows MCP clients to cancel runs independently of the active UI tab.
    @MainActor
    func cancelMCPContextBuilderRun(runID: UUID) async {
        guard let tabID = mcpRunTabByRunID[runID],
              let session = sessions[tabID]
        else {
            debugLog("cancelMCPContextBuilderRun: no session for runID \(runID)")
            return
        }

        debugLog("cancelMCPContextBuilderRun: cancelling runID=\(runID) tabID=\(tabID)")

        // Also fail the MCP continuation with cancellation error
        if let continuation = mcpRunContinuations.removeValue(forKey: runID) {
            continuation.resume(throwing: CancellationError())
        }
        mcpRunTabByRunID.removeValue(forKey: runID)

        let agentKind = effectiveRunAgentKind(for: session)
        await cancelRun(for: session, agent: agentKind)
    }

    /// Cancel a MCP-triggered discovery run by tab ID.
    @MainActor
    func cancelMCPContextBuilderRun(forTabID tabID: UUID) async {
        guard let session = sessions[tabID] else {
            debugLog("cancelMCPContextBuilderRun: no session for tabID \(tabID)")
            return
        }

        debugLog("cancelMCPContextBuilderRun: cancelling tabID=\(tabID)")

        // Find and fail any MCP continuation for this tab
        for (runID, mappedTabID) in mcpRunTabByRunID where mappedTabID == tabID {
            if let continuation = mcpRunContinuations.removeValue(forKey: runID) {
                continuation.resume(throwing: CancellationError())
            }
            mcpRunTabByRunID.removeValue(forKey: runID)
        }

        let agentKind = effectiveRunAgentKind(for: session)
        await cancelRun(for: session, agent: agentKind)
    }

    /// Core cancellation logic that works on an arbitrary TabSession.
    /// Used by both UI cancel (activeSession) and MCP cancel (by runID/tabID).
    @MainActor
    private func cancelRun(for session: TabSession, agent: AgentProviderKind) async {
        if !session.isCancelling {
            session.isCancelling = true
        }
        session.didUserCancelActiveContextBuilderRun = true
        updateRuntimeBindings(from: session)

        debugLog("Cancel requested for tab \(session.tabID)")

        // Cancel any pending question first
        cancelPendingQuestion(for: session)

        let taskSnapshot = session.agentTask
        let provider = session.activeAgentProvider
        session.activeAgentProvider = nil

        debugLog("Cancelling agent task")
        taskSnapshot?.cancel()

        debugLog("Disposing provider to kill CLI process")
        await provider?.dispose()

        if session.agentRunState.isRunning || taskSnapshot != nil {
            session.isAgentBusy = true
            updateRuntimeBindings(from: session)
        }

        if case let .running(runID) = session.agentRunState {
            await restoreToolRestrictions(agent: agent, runID: runID)
        }

        if let task = taskSnapshot {
            debugLog("Waiting for task cleanup to complete")
            await task.value
            debugLog("Run task finished")
        }

        session.endCurrentRunAttempt(source: "contextBuilder.cancel")
        session.agentTask = nil
        session.agentRunState = .cancelled
        session.isAgentBusy = false
        session.isCancelling = false
        clearRunStartState(for: session)
        tabsWithActiveContextBuilderRun.remove(session.tabID)
        updateRuntimeBindings(from: session)
    }

    @discardableResult
    func beginCancellation(forTabID tabID: UUID? = nil) -> Bool {
        let session: TabSession? = if let tabID {
            sessions[tabID]
        } else {
            activeSession
        }
        guard let session else { return false }
        if session.isCancelling { return false }
        session.isCancelling = true
        session.didUserCancelActiveContextBuilderRun = true
        updateRuntimeBindings(from: session)
        return true
    }

    // MARK: - MCP tool restrictions

    private func additionalToolsForContextBuilderAgent(tabID: UUID) -> Set<String>? {
        let sessionIsMCP = sessions[tabID]?.isMCPControlledRun ?? false
        let shouldAllowQuestions = sessionIsMCP
            ? allowClarifyingQuestionsForMCP
            : allowClarifyingQuestions
        return shouldAllowQuestions ? DiscoverMCPToolPolicy.grantedTools : nil
    }

    private func restoreToolRestrictions(agent: AgentProviderKind, runID: UUID) async {
        debugLog("Clearing leftover client restriction policy (if any) for runID=\(runID)")
        guard let clientName = agent.mcpClientNameHint else {
            debugLog("No client hint available; nothing to clear")
            return
        }
        let windowID = await MainActor.run { self.mcpServer.windowID }
        await ServerNetworkManager.shared.clearClientConnectionPolicy(
            for: clientName,
            windowID: windowID,
            runID: runID
        )
        debugLog("Cleared client restriction policy for \(clientName) runID=\(runID)")
    }

    // MARK: - Tab-scoped MCP integration

    private func snapshotAndWorkspace(for tabID: UUID) -> (ComposeTabState, UUID?)? {
        guard let manager = workspaceManager else { return nil }
        let base = manager.composeTab(with: tabID)
        let name = base?.name ?? "Tab"
        let snapshot = manager.collectComposeTabSnapshot(name: name, base: base)
        let workspaceID = manager.workspaces.first(where: { workspace in
            workspace.composeTabs.contains(where: { $0.id == tabID })
        })?.id
        return (snapshot, workspaceID)
    }

    // REMOVED: installTabContextForAgent functions
    // Tab context is now installed automatically by the routing layer via connection policy

    // REMOVED: waitForConnectionID - use MCPBootstrapLease.releaseWhenRouted instead

    // REMOVED: resolveConnectionID - routing layer handles this now

    /// Finds connection IDs for a runID that belong to the specified agent type.
    /// This filters out host MCP connections (e.g., Claude Desktop) that may share
    /// the same runID, ensuring we only terminate the spawned agent connection.
    @MainActor
    private func agentConnectionIDs(for runID: UUID, agent: AgentProviderKind) async -> [UUID] {
        guard let agentClientName = agent.mcpClientNameHint else { return [] }

        // Get all connection candidates for this run
        let candidateIDs = mcpServer.connectionIDs(forRunID: runID)
        guard !candidateIDs.isEmpty else { return [] }

        // Filter by client name via ServerNetworkManager
        var matches: [UUID] = []
        for cid in candidateIDs {
            let clientName = await ServerNetworkManager.shared.clientIdentifier(forConnection: cid)
            if clientName == agentClientName {
                matches.append(cid)
            }
        }
        debugLog("agentConnectionIDs: runID=\(runID) agent=\(agentClientName) candidates=\(candidateIDs.count) matches=\(matches.count)")
        return matches
    }

    private func commitTabContextForAgent(agent: AgentProviderKind, runID: UUID) async {
        guard activeAgentRuns.remove(runID) != nil else {
            debugLog("commitTabContextForAgent: runID=\(runID) not tracked, skipping")
            return
        }
        debugLog("commitTabContextForAgent: runID=\(runID)")

        let windowID = mcpServer.windowID
        let agentClientName = agent.mcpClientNameHint

        // Find only agent-owned connections for this run (excludes host MCP connections)
        let agentConnections = await agentConnectionIDs(for: runID, agent: agent)

        if agentConnections.isEmpty {
            debugLog("commitTabContextForAgent: no agent connection found for runID=\(runID); skipping termination")
        } else {
            for cid in agentConnections {
                debugLog("commitTabContextForAgent: terminating agent connection \(cid) runID=\(runID)")
                await ServerNetworkManager.shared.terminateConnection(
                    cid,
                    reason: .runCompleted,
                    message: "context builder run completed successfully"
                )

                // Commit & clear tab context for this connection
                await mcpServer.commitAndClearTabContext(connectionID: cid, expectedRunID: runID)
                mcpServer.removeTabContext(
                    forConnectionID: cid,
                    clientName: agentClientName,
                    windowID: nil,
                    runID: runID
                )
            }
        }

        // Run-level cleanup: ensure runID mappings & pending contexts are dropped
        if let clientName = agentClientName {
            mcpServer.removeTabContext(
                forConnectionID: nil,
                clientName: clientName,
                windowID: windowID,
                runID: runID
            )
        }
    }

    private func clearTabContextForAgent(agent: AgentProviderKind, runID: UUID) async {
        guard activeAgentRuns.remove(runID) != nil else {
            debugLog("clearTabContextForAgent: runID=\(runID) not tracked, skipping")
            return
        }
        debugLog("clearTabContextForAgent: runID=\(runID)")

        let windowID = mcpServer.windowID
        let agentClientName = agent.mcpClientNameHint

        // Find only agent-owned connections for this run (excludes host MCP connections)
        let agentConnections = await agentConnectionIDs(for: runID, agent: agent)

        for cid in agentConnections {
            debugLog("clearTabContextForAgent: terminating agent connection \(cid) runID=\(runID)")
            await ServerNetworkManager.shared.terminateConnection(
                cid,
                reason: .runCancelled,
                message: "context builder run cancelled/errored"
            )

            mcpServer.removeTabContext(
                forConnectionID: cid,
                clientName: agentClientName,
                windowID: nil,
                runID: runID
            )
        }

        // Run-level cleanup: ensure runID mappings & pending contexts are dropped
        if let clientName = agentClientName {
            mcpServer.removeTabContext(
                forConnectionID: nil,
                clientName: clientName,
                windowID: windowID,
                runID: runID
            )
        }
    }

    // MARK: - History

    private func saveRunToHistory(for session: TabSession) {
        let run = AgentRun(timestamp: Date(), log: session.agentLog, state: session.agentRunState)
        session.runHistory.insert(run, at: 0)
        if session.runHistory.count > maxHistoryCount {
            session.runHistory.removeLast(session.runHistory.count - maxHistoryCount)
        }
    }

    // MARK: - Agent message assembly

    private func buildAgentMessage(for session: TabSession, runID: UUID) async -> AgentMessage {
        // Determine token budget:
        // - MCP runs: prefer any explicit per-run override, otherwise derive budget from response_type
        // - UI runs with auto-generate enabled: use planTokenBudget (larger budget for plan/review/question context)
        // - UI runs without auto-generate: use regular tokenBudget
        // Note: MCP budget selection is independent of UI's autoGeneratePlan setting to avoid cross-feature coupling
        let effectiveBudget: Int
        if session.isMCPControlledRun {
            let wantsResponse = session.mcpResponseType.flatMap { raw in
                ContextBuilderResponseType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }?.wantsResponse ?? false
            let resolvedMCPBudget = ContextBuilderBudgetResolver.resolveBudget(
                wantsResponse: wantsResponse,
                discoveryTokenBudget: tokenBudget,
                planTokenBudget: planTokenBudget
            )
            effectiveBudget = session.tokenBudgetOverrideForRun ?? resolvedMCPBudget
        } else if session.autoGeneratePlan {
            // UI path with auto-generate: use larger plan budget
            effectiveBudget = planTokenBudget
        } else {
            // UI path without auto-generate: use regular budget
            effectiveBudget = tokenBudget
        }
        let adjustedBudget = max(0, effectiveBudget - 1500)

        // Use MCP-specific setting for MCP-controlled runs, UI setting for UI-triggered runs
        let clarifyingEnabledForRun = session.isMCPControlledRun
            ? allowClarifyingQuestionsForMCP
            : allowClarifyingQuestions

        // Determine response type for discovery prompt:
        // - MCP runs: use mcpResponseType (set by MCP handler)
        // - UI runs with auto-generate: use selectedFollowUpType's response string (so review mode gets git guidance)
        // - UI runs without auto-generate: nil (clarify mode)
        let responseType: String? = if session.isMCPControlledRun {
            session.mcpResponseType
        } else if session.autoGeneratePlan {
            session.selectedFollowUpType.responseTypeString
        } else {
            nil
        }

        debugLog("buildAgentMessage: isMCPControlledRun=\(session.isMCPControlledRun), autoGeneratePlan=\(session.autoGeneratePlan), selectedFollowUpType=\(session.selectedFollowUpType), responseType=\(responseType ?? "nil"), effectiveBudget=\(effectiveBudget)")

        let systemPrompt = SystemPromptService.discoverPrompt(tokenBudget: adjustedBudget, agentKind: selectedAgent, enhancementMode: enhancementMode, allowClarifyingQuestions: clarifyingEnabledForRun, responseType: responseType, instructions: session.contextBuilderInstructions, questionTimeoutSeconds: questionTimeoutSeconds)
        debugLog("System prompt includes ask_user: \(systemPrompt.contains("ask_user"))")
        let userMessage = await buildAgentUserMessage(for: session, adjustedBudget: adjustedBudget)
        return AgentMessage(systemPrompt: systemPrompt, userMessage: userMessage)
    }

    private func buildAgentUserMessage(for session: TabSession, adjustedBudget: Int) async -> String {
        // Context builder prompt IDs captured at run start from viewmodel (always set by captureRunStartState)
        let contextBuilderPromptIDs = session.runStartContextBuilderPromptIDs ?? []

        // PRIORITY 1: Use run-start captured state (prevents tab bleed)
        if let promptText = session.runStartPromptText,
           let selection = session.runStartSelection
        {
            let fileTree = await buildFileTree(from: selection)
            debugLog("Using run-start captured state for tab=\(session.tabID)")
            return makeUserMessage(
                fileTree: fileTree,
                userPrompt: promptText,
                discoverInstructions: session.contextBuilderInstructions,
                adjustedBudget: adjustedBudget,
                contextBuilderPromptIDs: contextBuilderPromptIDs
            )
        }

        // PRIORITY 2: Workspace snapshot (fallback, may be slightly stale)
        if let snapshot = snapshotForTab(session.tabID) {
            let fileTree = await buildFileTree(from: snapshot.selection)
            debugLog("Using workspace snapshot for tab=\(session.tabID)")
            return makeUserMessage(
                fileTree: fileTree,
                userPrompt: snapshot.promptText,
                discoverInstructions: session.contextBuilderInstructions,
                adjustedBudget: adjustedBudget,
                contextBuilderPromptIDs: contextBuilderPromptIDs
            )
        }

        // PRIORITY 3: Live UI state ONLY if still on correct tab
        // If the tab is no longer active and we have no captured state, something went wrong.
        guard session.tabID == currentTabID else {
            debugLog("ERROR: Tab context unavailable - tab switched before state was captured")
            return makeUserMessage(
                fileTree: "",
                userPrompt: "[Error: Tab context was not available. Please try running Context Builder again.]",
                discoverInstructions: session.contextBuilderInstructions,
                adjustedBudget: adjustedBudget,
                contextBuilderPromptIDs: contextBuilderPromptIDs
            )
        }

        debugLog("Using live UI state (tab still active) for tab=\(session.tabID)")
        workspaceManager?.publishActiveComposeTabSnapshot(commitToMemory: true)
        let liveSelection = snapshotForTab(session.tabID)?.selection ?? StoredSelection()
        let fileTree = await buildFileTree(from: liveSelection)
        return makeUserMessage(
            fileTree: fileTree,
            userPrompt: promptManager.promptText,
            discoverInstructions: session.contextBuilderInstructions,
            adjustedBudget: adjustedBudget,
            contextBuilderPromptIDs: contextBuilderPromptIDs
        )
    }

    private func makeUserMessage(
        fileTree: String,
        userPrompt: String,
        discoverInstructions: String,
        adjustedBudget: Int,
        contextBuilderPromptIDs: Set<UUID> = []
    ) -> String {
        var message = ""

        if !fileTree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += """
            <file_map>
            \(fileTree)
            </file_map>

            """
        }

        // Always include current prompt content if not empty - the system prompt controls what the agent does with it
        // (augment mode: preserve verbatim, preserve mode: don't touch, fullRewrite mode: rewrite completely)
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += """
            <current_prompt_content>
            \(userPrompt)
            </current_prompt_content>

            """
        }

        // Include context builder custom prompts (meta prompts) before user instructions
        if let metaPromptText = ContextBuilderPromptStorage.shared.promptText(for: contextBuilderPromptIDs) {
            message += """
            \(metaPromptText)

            """
            print(metaPromptText)
        }

        if !discoverInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += """
            <discover_instructions>
            \(discoverInstructions)
            </discover_instructions>

            """
        }

        message += """
        <metadata>
        <token_budget>\(adjustedBudget)</token_budget>
        <token_budget_guidance>
        Make a best effort to ensure the complete prompt (including all selected files and context) fits within the prescribed token budget of \(adjustedBudget) tokens.

        Context Optimization Strategy:
        - For MCP modes (like the current context_builder mode), selected files are automatically compressed to show only their codemaps (API signatures) instead of full content, dramatically reducing token usage
        - Codemaps provide type definitions, function signatures, and structure without full implementation details
        - Additional codemaps may be automatically included for types referenced by selected files (in 'auto' mode)
        - Use the MCP tools to check current token counts and adjust selection as needed to stay within budget

        Prioritize including files most relevant to the user's task while staying within the token budget.
        For additional files that may not fit, but are important, mention them in the prompt, with a short description for what they contain that may be relevant to the task.
        </token_budget_guidance>
        <output_format>
        The final prompt should be written with clear formatting, isolating important concepts in xml tags, and making use of clean markdown where possible.
        Do not add any outer wrapping for the complete prompt, as it will already be wrapped in <user_instructions>.
        </output_format>
        </metadata>
        """

        return message
    }

    private func buildFileTree(from selection: StoredSelection) async -> String {
        let snapshot = await promptManager.workspaceFileContextStore.makeFileTreeSelectionSnapshot(
            selection: selection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .auto,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                showCodeMapMarkers: true,
                rootScope: .allLoaded
            ),
            profile: .uiAssisted
        )
        debugLog("Generating file tree for \(snapshot.roots.count) roots")
        debugLog("Selected files count: \(snapshot.selectedFileIDs.count)")
        let tree = CodeMapExtractor.generateFileTree(using: snapshot)
        debugLog("File tree length: \(tree.count) characters")
        return tree
    }

    private func snapshotForTab(_ tabID: UUID) -> ComposeTabState? {
        workspaceManager?.composeTab(with: tabID)
    }

    /// Captures the tab's prompt and selection state at discovery run start.
    /// This prevents tab bleed when user switches tabs during a run.
    private func captureRunStartState(for session: TabSession) {
        // Capture context builder prompt IDs from the viewmodel (current UI state)
        session.runStartContextBuilderPromptIDs = selectedContextBuilderPromptIDs

        // First try: workspace snapshot (most reliable source)
        if session.tabID == currentTabID {
            workspaceManager?.publishActiveComposeTabSnapshot(commitToMemory: true)
        }
        if let snapshot = workspaceManager?.composeTab(with: session.tabID) {
            session.runStartPromptText = snapshot.promptText
            session.runStartSelection = snapshot.selection
            debugLog("Captured run-start state from workspace snapshot for tab=\(session.tabID)")
            return
        }

        // Fallback: Only use live UI if this is still the active tab
        // (safe because we haven't yielded yet, so no tab switch could have occurred)
        guard session.tabID == currentTabID else {
            debugLog("WARNING: No snapshot and tab not active; run may have stale context")
            session.runStartPromptText = ""
            session.runStartSelection = StoredSelection()
            return
        }

        // Capture from live UI prompt text with an empty selection if no compose snapshot exists.
        session.runStartPromptText = promptManager.promptText
        session.runStartSelection = StoredSelection()
        debugLog("Captured run-start prompt from live UI for tab=\(session.tabID); compose selection snapshot unavailable")
    }

    /// Clears the captured run-start state after a run completes or is cancelled.
    private func clearRunStartState(for session: TabSession) {
        session.runStartPromptText = nil
        session.runStartSelection = nil
        session.runStartContextBuilderPromptIDs = nil
    }

    // MARK: - Error handling

    private func extractVerboseErrorMessage(from error: Error) -> String {
        var errorMessage: String = if let providerError = error as? AIProviderError {
            switch providerError {
            case let .invalidConfiguration(detail):
                detail
            case let .apiError(source):
                if let nsError = source as NSError? {
                    nsError.localizedDescription
                } else {
                    "Agent CLI encountered an error"
                }
            case let .invalidResponse(detail):
                detail
            default:
                "Unexpected error: \(error)"
            }
        } else {
            error.localizedDescription
        }

        let lowerMessage = errorMessage.lowercased()
        // Don't add generic guidance if the error already contains specific guidance
        // (e.g., 404 errors already explain about settings/account access)
        let hasSpecificGuidance = lowerMessage.contains("login") ||
            lowerMessage.contains("authenticate") ||
            lowerMessage.contains("404") ||
            lowerMessage.contains("not found") ||
            lowerMessage.contains("settings")
        if !hasSpecificGuidance {
            let guidance = "\n\nEnsure you are logged into the agent CLI and have not hit rate limits."
            return errorMessage + guidance
        }

        return errorMessage
    }

    /// Formats tool arguments JSON into a compact, readable summary for display.
    /// Shows key parameters like paths, patterns, queries in a concise format.
    private func formatToolArgsSummary(_ argsJSON: String?) -> String? {
        guard let json = argsJSON,
              let data = json.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var parts: [String] = []

        // Handle line ranges for read_file (show as "file.swift:10-50")
        if let path = args["path"] as? String {
            var pathPart = (path as NSString).lastPathComponent
            if let startLine = args["start_line"] as? Int {
                if let limit = args["limit"] as? Int {
                    pathPart += ":\(startLine)-\(startLine + limit - 1)"
                } else {
                    pathPart += ":\(startLine)"
                }
            }
            parts.append(pathPart)
        }

        // Handle new_path for file moves
        if let newPath = args["new_path"] as? String {
            parts.append("→ " + (newPath as NSString).lastPathComponent)
        }

        // Primary operation/action keys
        let opKeys = ["op", "action", "mode", "response_type", "type", "scope"]
        for key in opKeys {
            if let value = args[key] as? String, !value.isEmpty {
                parts.append(value)
                break // Only show one operation type
            }
        }

        // Content/target keys (if no path already added)
        if !args.keys.contains("path") {
            let contentKeys = ["pattern", "paths", "query", "compare", "command", "workspace", "chat_name", "chat_id"]
            for key in contentKeys {
                if let value = args[key] {
                    let formatted = formatArgValue(value)
                    if !formatted.isEmpty {
                        parts.append(formatted)
                        break // Only show one content value
                    }
                }
            }
        }

        // Special case: show "rewrite" indicator for full file rewrites
        if args["rewrite"] != nil {
            parts.append("rewrite")
        }

        // Special case: show search preview for apply_edits
        if let search = args["search"] as? String, !search.isEmpty {
            let preview = search.count > 25 ? String(search.prefix(22)) + "..." : search
            let singleLine = preview.replacingOccurrences(of: "\n", with: "↵")
            parts.append("\"\(singleLine)\"")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Formats a single argument value for display.
    private func formatArgValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            // Truncate long strings and show just the filename for paths
            if str.contains("/") {
                return (str as NSString).lastPathComponent
            }
            return str.count > 40 ? String(str.prefix(37)) + "..." : str
        case let arr as [Any]:
            if let first = arr.first {
                let formatted = formatArgValue(first)
                return arr.count > 1 ? "\(formatted) +\(arr.count - 1)" : formatted
            }
            return ""
        case let num as NSNumber:
            return num.stringValue
        default:
            return ""
        }
    }

    private struct AgentLogMapping {
        let entry: AgentLogEntry
        let dedupeKey: String?
    }

    private func mapStreamResultToLogEntry(_ result: AIStreamResult) -> AgentLogMapping? {
        let entryType: AgentLogEntryType
        let message: String
        let dedupeKey: String?

        switch result.type {
        case "content", "final_content":
            return nil // Assistant output is aggregated by TabSession.
        case "event":
            let eventMessage = result.text ?? ""
            guard shouldDisplayCompactStatusMessage(eventMessage) else { return nil }
            entryType = .tool
            message = eventMessage
            dedupeKey = nil
        case "tool_call":
            entryType = .tool
            let toolName = result.toolName ?? "tool"
            if let argsSummary = formatToolArgsSummary(result.toolArgsJSON) {
                message = "\(toolName): \(argsSummary)"
            } else {
                message = toolName
            }
            dedupeKey = toolDedupeKey(for: result)
        case "tool_result":
            return nil // Skip tool results to avoid duplicate entries
        case "error":
            entryType = .error
            message = result.text ?? "Agent reported an error."
            dedupeKey = nil
        case "system":
            entryType = .system
            message = result.text ?? ""
            dedupeKey = nil
        case "status":
            let statusMessage = result.text ?? result.reasoning ?? ""
            guard shouldDisplayCompactStatusMessage(statusMessage) else { return nil }
            entryType = .system
            message = statusMessage
            dedupeKey = "status:\(normalizedLogKeyComponent(statusMessage))"
        case "message_stop":
            entryType = .system
            if let prompt = result.promptTokens, let completion = result.completionTokens {
                message = "Tokens used: \(prompt) input, \(completion) output"
            } else {
                message = "Agent completed"
            }
            dedupeKey = "message-stop"
        default:
            let fallbackMessage = result.text ?? result.reasoning ?? "Unknown event"
            guard shouldDisplayCompactStatusMessage(fallbackMessage) else { return nil }
            entryType = .system
            message = fallbackMessage
            dedupeKey = "status:\(result.type):\(normalizedLogKeyComponent(fallbackMessage))"
        }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return nil }
        return AgentLogMapping(
            entry: AgentLogEntry(timestamp: Date(), type: entryType, message: trimmedMessage),
            dedupeKey: dedupeKey
        )
    }

    private func toolDedupeKey(for result: AIStreamResult) -> String? {
        guard let invocationID = result.toolInvocationID else {
            return nil
        }
        return "tool:\(invocationID.uuidString)"
    }

    private func normalizedLogKeyComponent(_ value: String, limit: Int = 240) -> String {
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit))
    }

    private func shouldDisplayCompactStatusMessage(_ rawMessage: String) -> Bool {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 120 else { return false }
        return !looksLikePathOrCodeStatus(message)
    }

    private func looksLikePathOrCodeStatus(_ message: String) -> Bool {
        let lower = message.lowercased()
        let genericNoise = ["tool", "tools", "other", "resource", "resources", "content", "chunk"]
        if genericNoise.contains(lower) {
            return true
        }

        if lower.hasPrefix("@@") || lower.hasPrefix("diff --") || lower.hasPrefix("{") || lower.hasPrefix("[") {
            return true
        }

        if lower.hasPrefix("+") || lower.hasPrefix("-") {
            return true
        }

        let codeMarkers = ["{", "}", ";", "=>", "function ", "class ", "import ", "const ", "let ", "var "]
        if codeMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let sourceExtensions = [
            ".swift", ".ts", ".tsx", ".js", ".jsx", ".json", ".md", ".py", ".rb", ".go",
            ".rs", ".java", ".kt", ".c", ".h", ".cpp", ".hpp", ".m", ".mm", ".sh",
            ".yaml", ".yml", ".toml", ".xml", ".html", ".css"
        ]
        let tokens = message
            .split(whereSeparator: { $0.isWhitespace || ",;()[]{}<>\"'".contains($0) })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        if tokens.contains(where: { token in
            let lowerToken = token.lowercased()
            return token.contains("/") ||
                token.contains("\\") ||
                sourceExtensions.contains(where: { lowerToken.hasSuffix($0) })
        }) {
            return true
        }

        return false
    }

    // MARK: - Plan Generation from Discovery

    /// Returns the effective prompt text for a tab (considering overrides).
    /// Used by the view to send the prompt through normal chat flow.
    @MainActor
    func effectivePrompt(for tabID: UUID) -> String? {
        guard let tab = workspaceManager?.composeTab(with: tabID) else { return nil }
        let overrides = tab.contextOverrides
        let prompt = overrides.useOverridePrompt
            ? overrides.overridePromptText
            : tab.promptText
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Centralized logic to compute chat name from a tab's title.
    /// Used by both UI auto-plan and MCP plan/question flows.
    @MainActor
    func chatNameForTab(_ tabID: UUID) -> String {
        let tabName = workspaceManager?.composeTab(with: tabID)?.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = workspaceManager?.activeWorkspace?.name ?? "Workspace"
        let defaultName = "Plan – \(workspaceName)"
        return (tabName?.isEmpty == false) ? tabName! : defaultName
    }

    /// Called when a tab's discovery run completes successfully.
    /// If auto-generate is enabled and the run is not MCP-controlled,
    /// start background plan generation for that tab.
    private func maybeAutoGeneratePlan(for session: TabSession) {
        // 0. Only auto-generate for truly completed runs without user cancel intent
        guard session.agentRunState == .completed else {
            debugLog("Auto-plan skipped: run not completed for tab=\(session.tabID)")
            return
        }
        guard !session.didUserCancelActiveContextBuilderRun, !session.isCancelling else {
            debugLog("Auto-plan skipped: user cancellation detected for tab=\(session.tabID)")
            return
        }

        // 1. Respect per-tab setting (falls back to workspace default if not explicitly set)
        guard session.autoGeneratePlan else {
            debugLog("Auto-plan disabled; skipping for tab=\(session.tabID)")
            return
        }

        // 2. MCP runs manage their own plan generation
        guard !session.isMCPControlledRun else {
            debugLog("Auto-plan suppressed for MCP-controlled run tab=\(session.tabID)")
            return
        }

        // 3. Need a OracleViewModel to drive follow-up generation
        guard let oracleVM = oracleViewModel else {
            debugLog("Auto-plan: OracleViewModel not set; skipping for tab=\(session.tabID)")
            return
        }

        // 4. Only auto-generate if there's a non-empty effective prompt
        guard effectivePrompt(for: session.tabID) != nil else {
            debugLog("Auto-plan: no effective prompt; skipping for tab=\(session.tabID)")
            return
        }

        // Use the centralized chat name logic and selected follow-up type
        let chatName = chatNameForTab(session.tabID)
        let mode = session.selectedFollowUpType.headlessMode

        debugLog("Auto-plan: starting background generation for tab=\(session.tabID), mode=\(mode)")
        startBackgroundPlanGeneration(
            tabID: session.tabID,
            oracleViewModel: oracleVM,
            chatName: chatName,
            mode: mode
        )
    }

    /// Start background plan/review/question generation (headless mode).
    /// Called when auto-generate is triggered after Context Builder completes.
    /// Note: Only cancels any existing plan generation for THIS tab, not other tabs.
    /// - Parameters:
    ///   - tabID: The tab to generate for
    ///   - oracleViewModel: The OracleViewModel to use for follow-up generation
    ///   - chatName: Name for the resulting chat session
    ///   - mode: The headless mode (plan/review/chat) - determines which system prompt and generation path to use
    @MainActor
    func startBackgroundPlanGeneration(
        tabID: UUID,
        oracleViewModel: OracleViewModel,
        chatName: String = "Plan",
        mode: HeadlessMode = .plan
    ) {
        // Session must exist - caller ensures tab is valid
        let session = session(for: tabID)

        // Cancel any existing background plan task for THIS tab only
        session.backgroundPlanTask?.cancel()

        session.generatedPlanChatID = nil
        session.isBackgroundPlanGenerating = true
        session.backgroundPlanError = nil
        session.backgroundPlanResponseText = nil
        session.backgroundPlanReasoningText = nil
        clearPendingBackgroundPlanUIRefresh(for: tabID)
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)

        session.backgroundPlanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let session = sessions[tabID] else { return }

            do {
                let reply = try await generatePlanFromDiscovery(
                    tabID: tabID,
                    oracleViewModel: oracleViewModel,
                    chatName: chatName,
                    mode: mode
                )
                // generatedPlanChatID is set inside generatePlanFromDiscovery
                session.isBackgroundPlanGenerating = false
                if let response = reply.response, !response.isEmpty {
                    session.backgroundPlanResponseText = response
                }
                clearPendingBackgroundPlanUIRefresh(for: tabID)
                applyPlanPreview(to: session)
                updateRuntimeBindings(from: session)
            } catch {
                // Treat both outer Task cancellation and stream CancellationError as "user cancelled".
                if Task.isCancelled || (error is CancellationError) {
                    session.backgroundPlanResponseText = nil
                    session.backgroundPlanReasoningText = nil
                    session.backgroundPlanError = nil
                } else {
                    session.backgroundPlanError = error.asFriendlyString()
                }
                session.isBackgroundPlanGenerating = false
                clearPendingBackgroundPlanUIRefresh(for: tabID)
                applyPlanPreview(to: session)
                updateRuntimeBindings(from: session)
            }

            // Clear task reference when this run ends for any reason
            session.backgroundPlanTask = nil
        }
    }

    /// Cancel any in-progress background plan generation for a specific tab and reset to "ready to generate" state.
    /// - Parameter tabID: The tab to cancel. If nil, cancels for the current active tab.
    @MainActor
    func cancelBackgroundPlanGeneration(forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID, let session = sessions[targetTabID] else { return }

        // 1) Cancel the underlying follow-up stream in OracleViewModel
        if let oracleVM = oracleViewModel {
            if let followUpSessionID = session.followUpOracleSessionID {
                Task { @MainActor in
                    await oracleVM.cancelStreaming(in: followUpSessionID)
                }
            }
        }

        // 2) Cancel the wrapper task (so outer await stack unwinds)
        session.backgroundPlanTask?.cancel()
        session.backgroundPlanTask = nil

        // 3) Reset UI state on the tab
        session.isBackgroundPlanGenerating = false
        session.backgroundPlanError = nil
        session.backgroundPlanResponseText = nil
        session.backgroundPlanReasoningText = nil
        session.generatedPlanChatID = nil
        session.followUpOracleSessionID = nil
        clearPendingBackgroundPlanUIRefresh(for: targetTabID)
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)
    }

    /// Clear background plan state for a specific tab (e.g., when starting a new discovery run).
    /// - Parameter tabID: The tab to clear. If nil, clears for the current active tab.
    @MainActor
    func clearBackgroundPlanState(forTabID tabID: UUID? = nil) {
        cancelBackgroundPlanGeneration(forTabID: tabID)
        // generatedPlanChatID is cleared in cancelBackgroundPlanGeneration
    }

    /// Clear the MCP control flag for a specific tab.
    /// Called by executeContextBuilder after follow-up generation completes.
    @MainActor
    func clearMCPControlledRun(forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let id = targetTabID, let session = sessions[id] else {
            // Fallback: clear VM-level flag if no session found
            isMCPControlledRun = false
            mcpResponseType = nil
            mcpPlanModel = nil
            return
        }
        session.isMCPControlledRun = false
        session.mcpResponseType = nil
        session.mcpPlanModel = nil
        updateRuntimeBindings(from: session)
    }

    @MainActor
    func generatedPlanResponseText(for tabID: UUID? = nil) -> String? {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID, let session = sessions[targetTabID] else { return nil }
        return session.backgroundPlanResponseText
    }

    /// Use the generated plan text as the main prompt.
    /// Sets the prompt text in PromptViewModel and clears the plan generation state.
    @MainActor
    func useGeneratedPlanAsPrompt() {
        guard let tabID = currentTabID,
              let session = sessions[tabID],
              let planText = session.backgroundPlanResponseText,
              !planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        // Set the prompt text
        promptManager.promptText = planText

        // Clear plan state for this tab (keep generatedPlanChatID for "View in Chat" if desired)
        session.backgroundPlanResponseText = nil
        session.backgroundPlanReasoningText = nil
        session.backgroundPlanError = nil
        clearPendingBackgroundPlanUIRefresh(for: tabID)
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)
    }

    /// Returns the plan status for a specific tab, centralizing the view's switch logic.
    @MainActor
    func planStatus(for tabID: UUID?) -> ContextBuilderPlanStatus {
        guard let id = tabID, let session = sessions[id] else { return .idle }
        if session.isBackgroundPlanGenerating {
            return .generating
        }
        if let error = session.backgroundPlanError {
            return .error(error)
        }
        if let chatID = session.generatedPlanChatID {
            let preview = session.backgroundPlanResponsePreviewText ?? session.backgroundPlanResponseText
            return .ready(chatID: chatID, previewText: preview)
        }
        return .idle
    }

    /// Returns the current context-builder follow-up Oracle chat ID for a tab, when known.
    @MainActor
    func currentFollowUpOracleChatID(for tabID: UUID?) -> String? {
        if let id = tabID {
            return sessions[id]?.generatedPlanChatID
        }
        return generatedPlanChatID
    }

    // MARK: - MCP Plan/Question Generation

    private func promptMode(for mode: HeadlessMode) -> PromptViewModel.PlanActMode {
        switch mode {
        case .plan:
            .plan
        case .review:
            .review
        case .chat:
            .chat
        }
    }

    private enum FollowUpFinalizationResult {
        case finalised
        case timedOut
        case cancelled
    }

    private func waitForFollowUpFinalization(
        in oracleViewModel: OracleViewModel,
        queryID: UUID,
        sessionID: UUID,
        timeout: Duration = .seconds(4 * 60 * 60)
    ) async throws {
        let result = await withTaskGroup(of: FollowUpFinalizationResult.self) { group in
            group.addTask {
                do {
                    try await oracleViewModel.waitUntilMessageFinalised(queryID)
                    return .finalised
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    await oracleViewModel.cancelStreaming(in: sessionID)
                    return .timedOut
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
            }

            let firstResult = await group.next() ?? .cancelled
            group.cancelAll()
            return firstResult
        }

        switch result {
        case .finalised:
            return
        case .timedOut:
            throw ChatToolError.internalError("Follow-up response timed out before finalization")
        case .cancelled:
            try Task.checkCancellation()
        }
    }

    /// Unified follow-up generator that always streams in a real chat session.
    /// Used by both MCP-triggered follow-ups and UI auto-generate follow-ups.
    @MainActor
    private func runFollowUpOracleStream(
        for tabID: UUID,
        oracleViewModel: OracleViewModel,
        mode: HeadlessMode,
        prompt: String,
        selection: StoredSelection,
        chatName: String,
        model: AIModel,
        chatPresetID: UUID?,
        mcpSessionUIState: OracleViewModel.MCPSessionUIState? = nil,
        gitScopeOverride: GitInclusion? = nil,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        let session = session(for: tabID)

        // Set initial UI state
        session.generatedPlanChatID = nil
        session.isBackgroundPlanGenerating = true
        session.backgroundPlanError = nil
        session.backgroundPlanResponseText = nil
        session.backgroundPlanReasoningText = nil
        session.followUpOracleSessionID = nil
        updateRuntimeBindings(from: session)

        let modeName = mode.mcpModeName
        let promptMode = promptMode(for: mode)

        let isFocusedTab = (promptManager.activeComposeTabID == tabID)
        let activeSessionID = oracleViewModel.workspaceManager.activeChatSessionID(forTabID: tabID) ?? oracleViewModel.currentSessionID
        let isUserStreaming = oracleViewModel.isSessionStreaming(activeSessionID)
        let shouldActivate = isFocusedTab && !isUserStreaming

        var createdSessionID: UUID?
        do {
            try Task.checkCancellation()
            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }

            let aiMessage = await promptManager.buildHeadlessAIMessage(
                from: HeadlessContextSnapshot(
                    tabID: tabID,
                    promptText: prompt,
                    selection: selection
                ),
                model: model,
                mode: mode,
                gitScopeOverride: mode == .review ? gitScopeOverride : nil
            )

            try Task.checkCancellation()
            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }

            let createdSession = try await oracleViewModel.createSession(
                named: chatName,
                tabID: tabID,
                activateInUI: shouldActivate,
                setActiveForTab: true
            )
            createdSessionID = createdSession.id
            session.followUpOracleSessionID = createdSession.id
            session.generatedPlanChatID = createdSession.shortID
            updateRuntimeBindings(from: session)

            try Task.checkCancellation()
            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }

            if let mcpSessionUIState {
                oracleViewModel.setMCPSessionUIState(mcpSessionUIState, for: createdSession.id)
            } else {
                oracleViewModel.clearMCPSessionUIState(for: createdSession.id)
            }

            try Task.checkCancellation()
            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }

            await oracleViewModel.sendMessage(
                prompt,
                sessionID: createdSession.id,
                overrideModel: model,
                overrideChatPresetID: chatPresetID,
                overrideMode: promptMode,
                gitInclusionOverride: mode == .review ? gitScopeOverride : nil,
                selectionOverride: selection,
                overrideAIMessage: aiMessage,
                onProgress: { [weak self] text, reasoning in
                    guard let self,
                          let session = sessions[tabID],
                          session.isBackgroundPlanGenerating else { return }
                    session.backgroundPlanResponseText = text
                    session.backgroundPlanReasoningText = reasoning
                    applyPlanPreview(to: session)
                    requestBackgroundPlanUIRefresh(for: tabID)
                    onProgress?(text, reasoning)
                }
            )

            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }
            guard let queryId = oracleViewModel.activeQueryId(for: createdSession.id) else {
                throw ChatToolError.internalError("Failed to start follow-up stream")
            }
            try await waitForFollowUpFinalization(
                in: oracleViewModel,
                queryID: queryId,
                sessionID: createdSession.id
            )
            guard session.isBackgroundPlanGenerating else {
                throw CancellationError()
            }

            let aiMsg = oracleViewModel.getChatMessage(withId: queryId).flatMap { $0.isUser ? nil : $0 }
            let responseText = aiMsg?.content
            let reply = ChatSendReply(
                chatId: createdSession.id,
                shortId: createdSession.shortID,
                mode: modeName,
                response: responseText,
                errors: nil
            )

            session.isBackgroundPlanGenerating = false
            session.followUpOracleSessionID = nil
            session.generatedPlanChatID = reply.shortId
            if let response = reply.response, !response.isEmpty {
                session.backgroundPlanResponseText = response
            }
            clearPendingBackgroundPlanUIRefresh(for: tabID)
            applyPlanPreview(to: session)
            updateRuntimeBindings(from: session)
            workspaceManager?.setActiveChatSessionID(reply.chatId, forTabID: tabID)

            return reply
        } catch {
            if let createdSessionID {
                await oracleViewModel.cancelStreaming(in: createdSessionID)
            }

            if error is CancellationError {
                session.backgroundPlanResponseText = nil
                session.backgroundPlanReasoningText = nil
                session.generatedPlanChatID = nil
                session.backgroundPlanError = nil
            } else {
                session.backgroundPlanError = error.asFriendlyString()
            }
            session.isBackgroundPlanGenerating = false
            session.followUpOracleSessionID = nil
            clearPendingBackgroundPlanUIRefresh(for: tabID)
            applyPlanPreview(to: session)
            updateRuntimeBindings(from: session)
            throw error
        }
    }

    /// Run plan or question generation for MCP context_builder.
    /// This method encapsulates all UI state management for MCP-triggered plan/question generation,
    /// including cancellation wiring, progress updates, and cleanup.
    ///
    /// - Parameters:
    ///   - tabID: The tab to generate for
    ///   - oracleViewModel: The OracleViewModel to use for follow-up generation
    ///   - mode: `.plan`, `.chat` (question), or `.review`
    ///   - prompt: The effective prompt text (already computed by caller)
    ///   - selection: The file selection (already computed by caller)
    /// - Returns: The chat reply with chat_id for follow-up
    @MainActor
    func runMCPPlanOrQuestion(
        for tabID: UUID,
        oracleViewModel: OracleViewModel,
        mode: HeadlessMode,
        prompt: String,
        selection: StoredSelection,
        gitScopeOverride: GitInclusion? = nil
    ) async throws -> ChatSendReply {
        let modeName = mode.mcpModeName
        let modelSelection = try await oracleViewModel.resolveMCPFollowUpModel(mode: modeName)
        let mcpSessionUIState: OracleViewModel.MCPSessionUIState? = {
            guard let mcpModelInfo = modelSelection.mcpControlInfo else { return nil }
            let overrideChatPresetName = modelSelection.chatPresetID
                .flatMap { ChatPresetManager.shared.preset(with: $0)?.name }
            return OracleViewModel.MCPSessionUIState(
                modelInfo: mcpModelInfo,
                overrideModelName: modelSelection.model.displayName,
                overrideChatPresetName: overrideChatPresetName
            )
        }()

        return try await runFollowUpOracleStream(
            for: tabID,
            oracleViewModel: oracleViewModel,
            mode: mode,
            prompt: prompt,
            selection: selection,
            chatName: chatNameForTab(tabID),
            model: modelSelection.model,
            chatPresetID: modelSelection.chatPresetID,
            mcpSessionUIState: mcpSessionUIState,
            gitScopeOverride: gitScopeOverride
        )
    }

    // MARK: - MCP UI State Setters

    // These allow MCP to update UI progress without going through startBackgroundPlanGeneration

    @MainActor
    func setBackgroundPlanGenerating(_ generating: Bool, forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID else { return }
        let session = session(for: targetTabID)
        session.isBackgroundPlanGenerating = generating
        if generating {
            session.backgroundPlanError = nil
            session.backgroundPlanResponseText = nil
            session.backgroundPlanReasoningText = nil
        }
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)
    }

    @MainActor
    func setBackgroundPlanResponseText(_ text: String, forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID, let session = sessions[targetTabID] else { return }
        session.backgroundPlanResponseText = text
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)
    }

    @MainActor
    func setBackgroundPlanReasoningText(_ text: String?, forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID, let session = sessions[targetTabID] else { return }
        session.backgroundPlanReasoningText = text
        applyPlanPreview(to: session)
        updateRuntimeBindings(from: session)
    }

    @MainActor
    func setGeneratedPlanChatID(_ chatID: String, forTabID tabID: UUID? = nil) {
        let targetTabID = tabID ?? currentTabID
        guard let targetTabID, let session = sessions[targetTabID] else {
            // Fallback: update published property directly
            generatedPlanChatID = chatID
            return
        }
        session.generatedPlanChatID = chatID
        updateRuntimeBindings(from: session)
    }

    /// Generate an implementation plan using the built context.
    /// Called from UI when user clicks "Generate Plan" after Context Builder completes.
    ///
    /// - Parameters:
    ///   - tabID: The tab containing the discovery results
    ///   - oracleViewModel: The OracleViewModel to use for follow-up generation
    ///   - chatName: Optional name for the resulting chat session
    ///   - mode: The headless mode (plan/review/chat) - determines which generation path to use
    ///   - onProgress: Optional callback invoked with accumulated text and reasoning during streaming
    /// - Returns: The chat reply with chat_id for follow-up
    @MainActor
    func generatePlanFromDiscovery(
        tabID: UUID,
        oracleViewModel: OracleViewModel,
        chatName: String? = nil,
        mode: HeadlessMode = .plan,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> ChatSendReply {
        // Get the tab's current state after Context Builder completed
        guard let tab = workspaceManager?.composeTab(with: tabID) else {
            throw ContextBuilderGenerationError.missingTab
        }

        // Effective prompt: override if set, else tab's promptText
        let overrides = tab.contextOverrides
        let prompt = overrides.useOverridePrompt
            ? overrides.overridePromptText
            : tab.promptText

        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextBuilderGenerationError.emptyPrompt
        }

        let selection = tab.selection

        // Determine default chat name based on mode
        let defaultChatName = switch mode {
        case .plan: "Plan"
        case .review: "Review"
        case .chat: "Answer"
        }

        return try await runFollowUpOracleStream(
            for: tabID,
            oracleViewModel: oracleViewModel,
            mode: mode,
            prompt: prompt,
            selection: selection,
            chatName: chatName ?? defaultChatName,
            model: promptManager.preferredAIModel,
            chatPresetID: nil,
            onProgress: onProgress
        )
    }

    // MARK: - Clarifying Questions

    private var questionTimeout: TimeInterval {
        questionTimeoutSeconds
    }

    /// Ask the user a clarifying question and wait for their response.
    /// Called by the ask_user tool implementation in MCPServerViewModel.
    ///
    /// Legacy single-question adapter retained for existing in-process callers during migration.
    @MainActor
    func askUserQuestion(
        tabID: UUID,
        question: String,
        options: [String]?,
        context: String?,
        multiSelect: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> UserQuestionResponse {
        let questionID = "response"
        let interaction = AgentAskUserInteraction(
            title: "Question",
            context: context,
            timeoutSeconds: timeout ?? questionTimeout,
            questions: [
                AgentAskUserQuestion(
                    id: questionID,
                    question: question,
                    options: (options ?? []).map { AgentAskUserOption(label: $0) },
                    allowsMultiple: multiSelect,
                    allowsCustom: true
                )
            ]
        )
        let response = try await askUser(tabID: tabID, interaction: interaction)
        if response.timedOut {
            return .timeout(elapsedSeconds: response.elapsedSeconds)
        }
        if response.skipped {
            return .skipped(elapsedSeconds: response.elapsedSeconds)
        }
        let answer = response.answersByQuestionID[questionID]
        if answer?.skipped == true {
            return .skipped(elapsedSeconds: response.elapsedSeconds)
        }
        return .answered(answer?.answers.joined(separator: "\n") ?? "", elapsedSeconds: response.elapsedSeconds)
    }

    /// Ask the user one structured ask_user interaction and wait for their response.
    @MainActor
    func askUserInteraction(
        tabID: UUID,
        interaction: AgentAskUserInteraction
    ) async throws -> AgentAskUserResponse {
        try await askUser(tabID: tabID, interaction: interaction)
    }

    /// Ask the user one structured ask_user interaction and wait for their response.
    @MainActor
    func askUser(
        tabID: UUID,
        interaction: AgentAskUserInteraction
    ) async throws -> AgentAskUserResponse {
        let session = session(for: tabID)
        try interaction.validate()
        guard session.pendingAskUser == nil else {
            throw ContextBuilderGenerationError.askUserAlreadyPending
        }

        let pending = AgentAskUserPendingState(
            interaction: interaction,
            timeoutStartedAt: interaction.askedAt
        )
        session.pendingAskUser = pending

        // Auto-focus the window and switch to the correct compose tab when question is pending.
        // Await to ensure tab switch completes and UI bindings are updated before continuing.
        let didFocusAndPublish = await focusWindowForQuestion(tabID: tabID)
        guard sessions[tabID] === session,
              session.pendingAskUser?.interaction.id == interaction.id
        else {
            throw CancellationError()
        }
        if !didFocusAndPublish {
            // Fallback: ensure pendingAskUser is published even when we cannot focus/switch.
            updateRuntimeBindings(from: session)
        }

        let logQuestion = interaction.questions.count == 1
            ? interaction.questions[0].question
            : "\(interaction.questions.count) questions"
        session.appendLogEntry(
            AgentLogEntry(
                timestamp: Date(),
                type: .system,
                message: "🤔 Agent is asking: \(logQuestion)"
            )
        )
        updateAgentLogBinding(from: session)

        return try await withCheckedThrowingContinuation { continuation in
            session.askUserContinuation = continuation
            schedulePendingAskUserTimeout(
                for: session,
                interactionID: interaction.id,
                timeoutSeconds: interaction.timeoutSeconds,
                startedAt: interaction.askedAt
            )
        }
    }

    func updateAskUserDraft(tabID: UUID, interactionID: UUID, questionID: String, draft: AgentAskUserDraft) {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.contains(where: { $0.id == questionID })
        else { return }
        guard pending.draftsByQuestionID[questionID] != draft else { return }
        pending.draftsByQuestionID[questionID] = draft
        session.pendingAskUser = pending
        updateRuntimeBindings(from: session)
    }

    func updateAskUserQuestionIndex(tabID: UUID, interactionID: UUID, index: Int) {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              pending.interaction.questions.indices.contains(index)
        else { return }
        guard pending.currentQuestionIndex != index else { return }
        pending.currentQuestionIndex = index
        session.pendingAskUser = pending
        updateRuntimeBindings(from: session)
    }

    /// Reset the pending Context Builder ask_user timeout after visible card activity.
    func noteAskUserCardActivity(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID],
              let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              session.askUserContinuation != nil
        else { return }

        schedulePendingAskUserTimeout(
            for: session,
            interactionID: interactionID,
            timeoutSeconds: pending.interaction.timeoutSeconds,
            startedAt: Date()
        )
        updateRuntimeBindings(from: session)
    }

    private func schedulePendingAskUserTimeout(
        for session: TabSession,
        interactionID: UUID,
        timeoutSeconds: TimeInterval,
        startedAt: Date
    ) {
        session.askUserTimeoutTask?.cancel()
        session.pendingAskUserTimeoutGeneration &+= 1
        let generation = session.pendingAskUserTimeoutGeneration
        if var pending = session.pendingAskUser, pending.interaction.id == interactionID {
            pending.timeoutStartedAt = startedAt
            session.pendingAskUser = pending
        }
        let sleepNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)

        session.askUserTimeoutTask = Task { @MainActor [weak self, weak session] in
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }

            guard let self,
                  let session,
                  session.pendingAskUserTimeoutGeneration == generation,
                  let pending = session.pendingAskUser,
                  pending.interaction.id == interactionID,
                  let continuation = session.askUserContinuation
            else { return }

            invalidatePendingAskUserTimeout(for: session)
            session.pendingAskUser = nil
            session.askUserContinuation = nil

            let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
            let response = pending.interaction.buildTimedOutResponse(
                drafts: pending.draftsByQuestionID,
                elapsedSeconds: elapsedSeconds
            )
            logAskUserResponse(response, in: session)
            updateRuntimeBindings(from: session)
            continuation.resume(returning: response)
        }
    }

    private func invalidatePendingAskUserTimeout(for session: TabSession) {
        session.pendingAskUserTimeoutGeneration &+= 1
        session.askUserTimeoutTask?.cancel()
        session.askUserTimeoutTask = nil
        if var pending = session.pendingAskUser {
            pending.timeoutStartedAt = nil
            session.pendingAskUser = pending
        }
    }

    func submitAskUserResponse(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else { return }
        do {
            try resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: false)
        } catch {
            debugLog("submitAskUserResponse failed: \(error.localizedDescription)")
        }
    }

    func submitAskUserResponse(tabID: UUID, interactionID: UUID, draftsByQuestionID: [String: AgentAskUserDraft]) throws {
        guard let session = sessions[tabID],
              var pending = session.pendingAskUser,
              pending.interaction.id == interactionID
        else { return }
        pending.draftsByQuestionID = draftsByQuestionID
        session.pendingAskUser = pending
        try resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: false)
    }

    func skipAskUser(tabID: UUID, interactionID: UUID) {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else { return }
        try? resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: true)
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func noteQuestionCardActivity(tabID: UUID, questionID: UUID) {
        noteAskUserCardActivity(tabID: tabID, interactionID: questionID)
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func submitQuestionResponse(tabID: UUID, interactionID: UUID, response: String) {
        guard let session = sessions[tabID],
              let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              let question = pending.interaction.questions.first
        else {
            debugLog("submitQuestionResponse: no pending question for tab \(tabID)")
            return
        }
        var draft = AgentAskUserDraft(customResponse: response)
        if let matchedOption = question.optionLabels.first(where: { $0 == response }) {
            draft = AgentAskUserDraft(selectedOptionLabels: [matchedOption])
        }
        try? submitAskUserResponse(tabID: tabID, interactionID: interactionID, draftsByQuestionID: [question.id: draft])
    }

    /// Legacy single-question UI shim retained for tests and old call sites during migration.
    func skipQuestion(tabID: UUID, interactionID: UUID) {
        skipAskUser(tabID: tabID, interactionID: interactionID)
    }

    /// Get pending structured ask_user interaction for a specific tab (for UI to query).
    @MainActor
    func pendingAskUser(for tabID: UUID?) -> AgentAskUserPendingState? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.pendingAskUser
    }

    /// Legacy single-question snapshot shim retained for tests and old call sites during migration.
    @MainActor
    func pendingQuestion(for tabID: UUID?) -> DiscoveryQuestion? {
        pendingAskUser(for: tabID)?.legacyDiscoveryQuestion
    }

    /// Cancel any pending question for a session (internal helper).
    private func cancelPendingQuestion(for session: TabSession) {
        invalidatePendingAskUserTimeout(for: session)
        let continuation = session.askUserContinuation
        session.askUserContinuation = nil
        session.pendingAskUser = nil
        updateRuntimeBindings(from: session)
        continuation?.resume(throwing: CancellationError())
    }

    /// Focus the window and reveal the appropriate question surface when a clarifying question is pending.
    private func focusWindowForQuestion(tabID: UUID) async -> Bool {
        let windowID = mcpServer.windowID
        guard let windowState = WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID }) else {
            debugLog("focusWindowForQuestion: no window found for windowID=\(windowID)")
            return false
        }

        let didReveal = await windowState.revealPendingInteraction(
            tabID: tabID,
            surface: .contextualQuestion
        )
        guard didReveal else { return false }

        if let session = sessions[tabID] {
            updateRuntimeBindings(from: session)
            return true
        }

        return false
    }

    private func resolveAskUserResponse(for session: TabSession, interactionID: UUID, skipAll: Bool) throws {
        guard let pending = session.pendingAskUser,
              pending.interaction.id == interactionID,
              let continuation = session.askUserContinuation
        else { return }

        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
        let response = if skipAll {
            pending.interaction.buildSkippedResponse(elapsedSeconds: elapsedSeconds)
        } else {
            try pending.interaction.buildSubmittedResponse(
                drafts: pending.draftsByQuestionID,
                elapsedSeconds: elapsedSeconds
            )
        }

        invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        logAskUserResponse(response, in: session)
        updateRuntimeBindings(from: session)

        continuation.resume(returning: response)
    }

    private func logAskUserResponse(_ response: AgentAskUserResponse, in session: TabSession) {
        let message: String
        let type: AgentLogEntryType
        if response.timedOut {
            message = "⏱️ Question timed out after \(response.elapsedSeconds) seconds"
            type = .system
        } else if response.skipped {
            message = "⏭️ Question skipped by user"
            type = .system
        } else {
            let answered = response.answersByQuestionID
                .sorted { $0.key < $1.key }
                .flatMap(\.value.answers)
                .joined(separator: "; ")
            message = answered.isEmpty ? "💬 User submitted answers" : "💬 User response: \(answered)"
            type = .user
        }
        session.appendLogEntry(
            AgentLogEntry(
                timestamp: Date(),
                type: type,
                message: message
            )
        )
    }
}

// MARK: - Context Builder Plan Status

enum ContextBuilderPlanStatus: Equatable {
    case idle
    case generating
    case ready(chatID: String, previewText: String?)
    case error(String)

    static func == (lhs: ContextBuilderPlanStatus, rhs: ContextBuilderPlanStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.generating, .generating):
            true
        case let (.ready(a, _), .ready(b, _)):
            a == b
        case let (.error(a), .error(b)):
            a == b
        default:
            false
        }
    }
}

// MARK: - Context Builder Generation Errors

enum ContextBuilderGenerationError: LocalizedError {
    case emptyPrompt
    case missingTab
    case askUserAlreadyPending

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: "Context Builder has no prompt to generate from."
        case .missingTab: "Unable to locate the Context Builder tab."
        case .askUserAlreadyPending: "ask_user is already waiting for a response in this Context Builder session."
        }
    }
}
