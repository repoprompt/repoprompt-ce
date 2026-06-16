import Foundation

struct CodexTurnStartReceipt: Equatable {
    let provisionalSubmissionID: String
}

struct CodexTurnSteerReceipt: Equatable {
    let acceptedTurnID: String
}

struct CodexTurnInterruptReceipt: Equatable {
    let interruptedTurnID: String
}

enum CodexTurnSteerError: Error, LocalizedError, Equatable {
    case noActiveTurn(CodexAppServerClient.RequestFailure)
    case expectedTurnMismatch(
        expectedTurnID: String,
        actualTurnID: String?,
        failure: CodexAppServerClient.RequestFailure
    )
    case activeTurnNotSteerable(
        turnKind: String?,
        failure: CodexAppServerClient.RequestFailure
    )

    var errorDescription: String? {
        switch self {
        case let .noActiveTurn(failure):
            failure.message
        case let .expectedTurnMismatch(_, _, failure):
            failure.message
        case let .activeTurnNotSteerable(_, failure):
            failure.message
        }
    }
}

enum CodexTurnInterruptError: Error, LocalizedError, Equatable {
    case reconciliationFailed(expectedTurnID: String, authoritativeTurnID: String?)
    case noUniqueActiveTurn(authoritativeTurnID: String?, observedTurnIDs: [String])

    var errorDescription: String? {
        switch self {
        case let .reconciliationFailed(expectedTurnID, authoritativeTurnID):
            "Codex interrupt identity reconciliation failed: expected \(expectedTurnID), authoritative \(authoritativeTurnID ?? "nil")."
        case let .noUniqueActiveTurn(authoritativeTurnID, observedTurnIDs):
            "Codex interrupt identity reconciliation failed: authoritative \(authoritativeTurnID ?? "nil"), observed active turns \(observedTurnIDs)."
        }
    }
}

protocol CodexSessionControlling: AnyObject {
    var hasActiveThread: Bool { get }
    var events: AsyncStream<CodexNativeSessionController.Event> { get }

    func ensureEventsStreamReady()
    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String
    ) async throws -> CodexNativeSessionController.SessionRef
    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef
    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexNativeSessionController.SessionRef
    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot
    func setThreadName(_ name: String, threadID: String?) async throws
    func startUserTurn(
        text: String,
        images: [AgentImageAttachment],
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexTurnStartReceipt
    func steerUserTurn(
        text: String,
        images: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt
    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID: String,
        acceptedDispatchTurnID: String
    ) async -> Bool
    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt
    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt
    func compactThread() async throws
    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal?
    func setThreadGoalObjective(_ objective: String) async throws -> CodexNativeSessionController.ThreadGoal
    func setThreadGoalStatus(_ status: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal
    func clearThreadGoal() async throws -> Bool
    func cancelCurrentTurn() async
    func shutdown() async
    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async
}

final class CodexNativeSessionController {
    private static func logCodexDebug(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard UserDefaults.standard.bool(forKey: "enableCodexDebugLogging") else { return }
            print(message())
        #endif
    }

    private static let maxRunningAggregatedOutputCharacters = 24000
    private static let computerUseMCPServerName = "computer-use"
    private static let runningOutputTruncationMarker = "\n...(output truncated)...\n"
    private static let rawEventLogFilePathKey = "codexRawEventLogFilePath"
    private static let lastRawEventLogFilePathKey = "codexLastRawEventLogFilePath"
    private static let rawEventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    struct CommandExecutionRunningUpdate {
        let invocationID: UUID?
        let processID: String?
        let appendedOutput: String?
        let sealsAssistantBoundary: Bool

        init(
            invocationID: UUID?,
            processID: String?,
            appendedOutput: String?,
            sealsAssistantBoundary: Bool = false
        ) {
            self.invocationID = invocationID
            self.processID = processID
            self.appendedOutput = appendedOutput
            self.sealsAssistantBoundary = sealsAssistantBoundary
        }
    }

    struct ReasoningDeltaPayload: Equatable {
        enum Kind: Equatable {
            case summary
            case text
        }

        let text: String
        let kind: Kind
        let itemID: String?
        let groupID: String?
        let index: Int?
    }

    private struct FileChangeStreamState {
        let itemID: String
        let invocationID: UUID?
        var argsJSON: String?
        var latestResultJSON: String?
        var accumulatedOutput: String
        var status: String
    }

    private enum CommandExecutionEventFamily {
        case raw
        case normalized
    }

    private struct CommandExecutionMirrorState {
        let family: CommandExecutionEventFamily
        var lastSeenAt: Date
    }

    enum TurnStatus {
        case completed
        case interrupted
        case failed
    }

    struct ChatgptAuthTokensRefreshRequest: Equatable {
        enum Reason: Equatable {
            case unauthorized
        }

        let requestID: CodexAppServerRequestID
        let reason: Reason
        let previousAccountID: String?
    }

    struct ChatgptAuthTokensRefreshResponse: Equatable {
        let accessToken: String
        let chatgptAccountID: String
        let chatgptPlanType: String?

        var payload: [String: Any] {
            var result: [String: Any] = [
                "accessToken": accessToken,
                "chatgptAccountId": chatgptAccountID
            ]
            if let chatgptPlanType {
                result["chatgptPlanType"] = chatgptPlanType
            }
            return result
        }
    }

    struct ServerRequestIssue: Equatable {
        enum Kind: String, Equatable {
            case authTokensRefreshInvalidParams = "auth-tokens-refresh-invalid-params"
            case authTokensRefreshUnavailable = "auth-tokens-refresh-unavailable"
            case authTokensRefreshFailed = "auth-tokens-refresh-failed"
            case requestUserInputInvalidParams = "request-user-input-invalid-params"
            case mcpElicitationInvalidParams = "mcp-elicitation-invalid-params"
            case mcpElicitationUnsupported = "mcp-elicitation-unsupported"
            case permissionsRequestUnsupported = "permissions-request-unsupported"
            case dynamicToolCallUnsupported = "dynamic-tool-call-unsupported"
            case unsupportedMethod = "unsupported-method"
        }

        let requestID: CodexAppServerRequestID
        let method: String
        let kind: Kind
        let message: String
    }

    struct LivenessActivity: Equatable {
        enum Kind: String, Equatable {
            case threadStatusChanged = "thread-status-changed"
            case turnPlanUpdated = "turn-plan-updated"
            case turnDiffUpdated = "turn-diff-updated"
            case itemPlanDelta = "item-plan-delta"
            case mcpToolProgress = "mcp-tool-progress"
            case commandOrProcessOutput = "command-or-process-output"
            case processExited = "process-exited"
            case hookLifecycle = "hook-lifecycle"
            case warning
            case deprecationNotice = "deprecation-notice"
            case serverRequestResolved = "server-request-resolved"
            case unknownScoped = "unknown-scoped"
        }

        let kind: Kind
        let method: String
        let threadID: String?
        let turnID: String?
        let itemID: String?
        let activeFlags: [String]
        let message: String?
    }

    struct ErrorNotification: Equatable {
        let message: String
        let willRetry: Bool?
        let threadID: String?
        let turnID: String?
        let itemID: String?

        init(
            message: String,
            willRetry: Bool?,
            threadID: String?,
            turnID: String?,
            itemID: String? = nil
        ) {
            self.message = message
            self.willRetry = willRetry
            self.threadID = threadID
            self.turnID = turnID
            self.itemID = itemID
        }
    }

    typealias ChatgptAuthTokensRefreshHandler = @Sendable (ChatgptAuthTokensRefreshRequest) async throws -> ChatgptAuthTokensRefreshResponse

    enum Event {
        case assistantDelta(String)
        case reasoningDelta(ReasoningDeltaPayload)
        case tokenUsage(AgentContextUsage)
        case turnStarted(turnID: String?)
        case turnCompleted(turnID: String?, status: TurnStatus)
        case contextCompacted(turnID: String?)
        case approvalRequest(AgentApprovalRequest)
        case permissionsRequest(AgentPermissionsRequest)
        case requestUserInput(AgentRequestUserInputRequest)
        case mcpElicitationRequest(AgentMCPElicitationRequest)
        case serverRequestIssue(ServerRequestIssue)
        case toolCall(name: String, invocationID: UUID?, argsJSON: String?)
        case toolResult(name: String, invocationID: UUID?, argsJSON: String?, resultJSON: String, isError: Bool?)
        case commandExecutionRunning(CommandExecutionRunningUpdate)
        case livenessActivity(LivenessActivity)
        case errorNotification(ErrorNotification)
        case error(String)
        case system(String)
    }

    struct SessionRef: Equatable {
        var conversationID: String
        var rolloutPath: String?
        var model: String?
        var reasoningEffort: String?
    }

    enum ThreadGoalStatus: String, Equatable {
        case active
        case paused
        case budgetLimited
        case complete
    }

    struct ThreadGoal: Equatable {
        let threadID: String
        let objective: String
        let status: ThreadGoalStatus
        let tokenBudget: Int64?
        let tokensUsed: Int64
        let timeUsedSeconds: Int64
        let createdAt: Int64
        let updatedAt: Int64
    }

    struct ThreadSnapshot: Equatable {
        enum RuntimeStatus: Equatable {
            case notLoaded
            case idle
            case systemError
            case active(activeFlags: [String])

            var isActive: Bool {
                if case .active = self {
                    return true
                }
                return false
            }
        }

        let conversationID: String
        let rolloutPath: String?
        let model: String?
        let reasoningEffort: String?
        let runtimeStatus: RuntimeStatus
        let currentTurnID: String?
        let activeTurnIDs: [String]
        let latestTurnStatus: TurnStatus?

        var sessionRef: SessionRef {
            SessionRef(
                conversationID: conversationID,
                rolloutPath: rolloutPath,
                model: model,
                reasoningEffort: reasoningEffort
            )
        }

        var activeFlags: [String] {
            if case let .active(activeFlags) = runtimeStatus {
                return activeFlags
            }
            return []
        }

        var hasActiveTurn: Bool {
            runtimeStatus.isActive || !activeTurnIDs.isEmpty
        }
    }

    struct Options {
        /// Timeout for setup/control-plane requests (initialize, thread/start, thread/resume).
        /// A finite timeout prevents indefinite hangs when the app-server becomes wedged.
        /// Does NOT apply to turn/start, which can block for extended model reasoning.
        var requestTimeout: TimeInterval?
        var configOverridesProvider: () async -> [String: Any]
        var approvalPolicyProvider: () -> CodexAgentToolPreferences.ApprovalPolicy
        var sandboxModeProvider: () -> CodexAgentToolPreferences.SandboxMode
        var approvalReviewerProvider: () -> CodexAgentToolPreferences.ApprovalReviewer = { CodexAgentToolPreferences.approvalReviewer() }
        var authTokensRefreshHandler: ChatgptAuthTokensRefreshHandler?
        var goalSupportEnabledProvider: @MainActor () -> Bool = { false }
        var computerUseEnabledProvider: @MainActor () -> Bool = { false }

        static func agentModeDefault(
            forceExperimentalSteering: Bool,
            approvalPolicyProvider: @escaping () -> CodexAgentToolPreferences.ApprovalPolicy = { CodexAgentToolPreferences.approvalPolicy() },
            sandboxModeProvider: @escaping () -> CodexAgentToolPreferences.SandboxMode = { CodexAgentToolPreferences.sandboxMode() },
            approvalReviewerProvider: @escaping () -> CodexAgentToolPreferences.ApprovalReviewer = { CodexAgentToolPreferences.approvalReviewer() },
            shellToolEnabled: Bool? = nil,
            suppressThirdPartyMCPServers: Bool = false,
            goalSupportEnabledProvider: @escaping @MainActor () -> Bool = { CodexGoalSupport.isEnabled },
            computerUseEnabledProvider: @escaping @MainActor () -> Bool = { false }
        ) -> Options {
            Options(
                requestTimeout: 120,
                configOverridesProvider: {
                    let featurePolicy = await MainActor.run {
                        (
                            goalSupportEnabled: goalSupportEnabledProvider(),
                            computerUseEnabled: computerUseEnabledProvider()
                        )
                    }
                    return CodexNativeSessionController.defaultAppServerConfigOverrides(
                        forceExperimentalSteering: forceExperimentalSteering,
                        approvalPolicy: approvalPolicyProvider(),
                        sandboxMode: sandboxModeProvider(),
                        approvalReviewer: approvalReviewerProvider(),
                        shellToolEnabled: shellToolEnabled,
                        suppressThirdPartyMCPServers: suppressThirdPartyMCPServers,
                        goalSupportEnabled: featurePolicy.goalSupportEnabled,
                        computerUseEnabled: featurePolicy.computerUseEnabled
                    )
                },
                approvalPolicyProvider: approvalPolicyProvider,
                sandboxModeProvider: sandboxModeProvider,
                approvalReviewerProvider: approvalReviewerProvider,
                authTokensRefreshHandler: nil,
                goalSupportEnabledProvider: goalSupportEnabledProvider,
                computerUseEnabledProvider: computerUseEnabledProvider
            )
        }
    }

    enum ClientShutdownBehavior {
        case none
        case stopOnShutdown
    }

    private enum LifecycleState {
        case fresh
        case binding
        case active
        case shuttingDown
        case terminated
    }

    private enum BufferedInbound {
        case notification(CodexAppServerClient.Notification)
        case serverRequest(CodexAppServerClient.ServerRequest)
    }

    private enum InboundStreamKind {
        case notifications
        case serverRequests
    }

    private struct LifecycleAuthorityReconciliationLineage: Equatable {
        let expectedCurrentTurnID: String
        let acceptedDispatchTurnID: String
    }

    private enum LifecycleAuthorityObservationKind: Equatable {
        case started
        case completed
    }

    private struct LifecycleAuthorityObservation: Equatable {
        let lineage: LifecycleAuthorityReconciliationLineage
        let kind: LifecycleAuthorityObservationKind
    }

    private let client: CodexAppServerClient
    private let runID: UUID
    private let tabID: UUID
    private let windowID: Int
    private let workspacePath: String?
    private let options: Options
    private let clientShutdownBehavior: ClientShutdownBehavior
    private let expectedMCPClientName: String?
    private let requestExecutor: (@Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any])?
    private let rawEventFileLoggingEnabled: Bool
    private var rawEventLogFileURL: URL?
    private var rawEventLogFileThreadID: String?
    private var hasWrittenRawEventLogHeader = false

    private var threadID: String?
    private var threadPath: String?
    private var routingCurrentTurnID: String?
    private var authoritativeLifecycleTurnID: String?
    private var activeTurnIDs: Set<String> = []
    private var activeTurnOrder: [String] = []
    private var activeTurnIDsWithObservedActivity: Set<String> = []
    private var pendingLifecycleAuthorityReconciliation: LifecycleAuthorityReconciliationLineage?
    private var lifecycleAuthorityObservations: [LifecycleAuthorityObservation] = []
    private var assistantDeltaSeenTurnIDs: Set<String> = []
    private var fileChangeStateByItemID: [String: FileChangeStreamState] = [:]
    /// Item IDs whose fileChange lifecycle has reached terminal (completed) state.
    /// Used to suppress late output deltas that arrive after completion.
    private var terminalFileChangeItemIDs: Set<String> = []
    private var commandExecutionMirrorStateByItemID: [String: CommandExecutionMirrorState] = [:]
    private var appServerRequestValueStyle: CodexAgentToolPreferences.AppServerRequestValueStyle = .configStyle

    var hasActiveThread: Bool {
        threadID?.isEmpty == false
    }

    private var notificationTask: Task<Void, Never>?
    private var serverRequestTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private let eventsContinuationLock = NSLock()
    private let eventHandlingMutex = AsyncMutex()
    private let eventsStream: AsyncStream<Event>
    /// Protected by `eventsContinuationLock`.
    private var lifecycleState: LifecycleState = .fresh
    /// One-shot flag preventing double-emission of transport-closed events when both
    /// notification and serverRequest streams end. Protected by `eventsContinuationLock`.
    /// Never reset — this controller is single-use (coordinator creates a fresh instance on reconnect).
    private var didHandleTransportEnd = false
    private var emittedToolEventDedupKeys: Set<String> = []
    private var isBindingSession = false
    private var bufferedInbound: [BufferedInbound] = []
    private let maxBufferedInbound = 128

    var events: AsyncStream<Event> {
        eventsStream
    }

    func ensureEventsStreamReady() {
        guard currentEventsContinuation() == nil else { return }
        _ = events
    }

    private static func alternateAppServerRequestValueStyle(
        for style: CodexAgentToolPreferences.AppServerRequestValueStyle
    ) -> CodexAgentToolPreferences.AppServerRequestValueStyle {
        switch style {
        case .configStyle:
            .camelCase
        case .camelCase:
            .configStyle
        }
    }

    private static func shouldRetryWithAlternateAppServerRequestValueStyle(_ error: Error) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        guard normalized.contains("unknown variant") else { return false }
        let markers = [
            "onrequest",
            "on-request",
            "onfailure",
            "on-failure",
            "unlesstrusted",
            "untrusted",
            "readonly",
            "read-only",
            "workspacewrite",
            "workspace-write",
            "dangerfullaccess",
            "danger-full-access"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private static func isMemoryModeCompatibilityFailure(_ error: Error) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        let methodMarkers = [
            "thread/memorymode/set",
            "thread memory mode",
            "memory mode"
        ]
        let mentionsMemoryMode = methodMarkers.contains { normalized.contains($0) }

        if normalized.contains("unknown variant") || normalized.contains("unknown method") {
            return mentionsMemoryMode
        }
        if normalized.contains("method not found") || normalized.contains("no such method") {
            return mentionsMemoryMode || normalized.contains("-32601")
        }
        if normalized.contains("experimental"),
           normalized.contains("unavailable") || normalized.contains("disabled") || normalized.contains("not enabled")
        {
            return mentionsMemoryMode
        }
        return false
    }

    private func requestWithCompatibleAppServerRequestValueStyle(
        method: String,
        timeout: TimeInterval?,
        paramsBuilder: (CodexAgentToolPreferences.AppServerRequestValueStyle) async -> [String: Any]
    ) async throws -> [String: Any] {
        let attemptedStyle = appServerRequestValueStyle
        do {
            return try await performRequest(
                method: method,
                params: paramsBuilder(attemptedStyle),
                timeout: timeout
            )
        } catch {
            guard Self.shouldRetryWithAlternateAppServerRequestValueStyle(error) else {
                throw error
            }
            let fallbackStyle = Self.alternateAppServerRequestValueStyle(for: attemptedStyle)
            Self.logCodexDebug(
                "[CodexNativeController] retrying \(method) with alternate request value style=\(String(describing: fallbackStyle)) after error=\(error.localizedDescription)"
            )
            let result = try await performRequest(
                method: method,
                params: paramsBuilder(fallbackStyle),
                timeout: timeout
            )
            appServerRequestValueStyle = fallbackStyle
            return result
        }
    }

    private func performRequest(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> [String: Any] {
        if let requestExecutor {
            return try await requestExecutor(method, params, timeout)
        }
        return try await client.request(method: method, params: params, timeout: timeout)
    }

    init(
        client: CodexAppServerClient,
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        workspacePath: String?,
        forceExperimentalSteering: Bool = false,
        options: Options? = nil,
        clientShutdownBehavior: ClientShutdownBehavior = .none,
        expectedMCPClientName: String? = nil,
        requestExecutor: (@Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any])? = nil
    ) {
        self.client = client
        self.runID = runID
        self.tabID = tabID
        self.windowID = windowID
        self.workspacePath = workspacePath
        self.options = options ?? Self.Options.agentModeDefault(forceExperimentalSteering: forceExperimentalSteering)
        self.clientShutdownBehavior = clientShutdownBehavior
        self.expectedMCPClientName = expectedMCPClientName
        self.requestExecutor = requestExecutor
        rawEventFileLoggingEnabled = Self.isRawEventFileLoggingEnabled()
        rawEventLogFileURL = nil
        rawEventLogFileThreadID = nil
        var continuationRef: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event> { continuation in
            continuationRef = continuation
        }
        eventsStream = stream
        eventsContinuation = continuationRef
    }

    deinit {
        notificationTask?.cancel()
        serverRequestTask?.cancel()
        finishEventsStreamIfNeeded()
        if clientShutdownBehavior == .stopOnShutdown || expectedMCPClientName != nil {
            let ownedClient = client
            let shouldStopClient = clientShutdownBehavior == .stopOnShutdown
            let shouldClearExpectedPID = expectedMCPClientName != nil
            Task {
                if shouldClearExpectedPID {
                    await ownedClient.clearExpectedAgentPIDRegistration()
                }
                if shouldStopClient {
                    await ownedClient.stop()
                }
            }
        }
    }

    private func withEventsStateLock<T>(_ body: () -> T) -> T {
        eventsContinuationLock.lock()
        defer { eventsContinuationLock.unlock() }
        return body()
    }

    private func withEventsContinuation<T>(
        _ body: (inout AsyncStream<Event>.Continuation?) -> T
    ) -> T {
        withEventsStateLock {
            body(&eventsContinuation)
        }
    }

    private func currentEventsContinuation() -> AsyncStream<Event>.Continuation? {
        withEventsContinuation { $0 }
    }

    private func finishEventsStreamIfNeeded() {
        let continuation = withEventsContinuation { continuation in
            let activeContinuation = continuation
            continuation = nil
            return activeContinuation
        }
        continuation?.finish()
    }

    private func prepareForStartOrResume() throws {
        var lifecycleError: CodexSessionControllerError?
        withEventsStateLock {
            switch lifecycleState {
            case .fresh:
                lifecycleState = .binding
            case .binding:
                lifecycleError = .invalidLifecycleState("already starting")
            case .active:
                lifecycleError = .invalidLifecycleState("already active")
            case .shuttingDown:
                lifecycleError = .invalidLifecycleState("shutting down")
            case .terminated:
                lifecycleError = .invalidLifecycleState("terminated")
            }
        }
        if let lifecycleError {
            throw lifecycleError
        }
    }

    private func markStartOrResumeSucceeded() throws {
        var lifecycleError: CodexSessionControllerError?
        withEventsStateLock {
            switch lifecycleState {
            case .binding:
                lifecycleState = .active
            case .fresh:
                lifecycleError = .invalidLifecycleState("not binding")
            case .active:
                lifecycleError = .invalidLifecycleState("already active")
            case .shuttingDown:
                lifecycleError = .invalidLifecycleState("shutting down")
            case .terminated:
                lifecycleError = .invalidLifecycleState("terminated")
            }
        }
        if let lifecycleError {
            throw lifecycleError
        }
    }

    private func markStartOrResumeFailed() {
        withEventsStateLock {
            if lifecycleState == .binding {
                lifecycleState = .fresh
            }
        }
    }

    private func ensureBindingCanComplete() throws {
        var lifecycleError: CodexSessionControllerError?
        withEventsStateLock {
            switch lifecycleState {
            case .binding:
                break
            case .fresh:
                lifecycleError = .invalidLifecycleState("not binding")
            case .active:
                lifecycleError = .invalidLifecycleState("already active")
            case .shuttingDown:
                lifecycleError = .invalidLifecycleState("shutting down")
            case .terminated:
                lifecycleError = .invalidLifecycleState("terminated")
            }
        }
        if let lifecycleError {
            throw lifecycleError
        }
    }

    private static func isRawEventFileLoggingEnabled() -> Bool {
        false
    }

    private static func normalizedThreadIdentifier(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "unknown-thread" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let normalized = String(scalars)
        return normalized.isEmpty ? "unknown-thread" : normalized
    }

    private static func makeRawEventLogFileURL(
        workspacePath: String?,
        threadID: String
    ) -> URL? {
        let defaults = UserDefaults.standard
        let overridePath = defaults.string(forKey: rawEventLogFilePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDirectory: URL = {
            if let overridePath, !overridePath.isEmpty {
                let expanded = NSString(string: overridePath).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            if let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspacePath.isEmpty
            {
                return URL(fileURLWithPath: workspacePath, isDirectory: true)
                    .appendingPathComponent(".codexlogs", isDirectory: true)
            }
            return MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent(".codexlogs", isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = "codex-thread-\(threadID)-\(timestamp).jsonl"
        return baseDirectory.appendingPathComponent(fileName)
    }

    private func ensureRawEventLogFileReadyIfNeeded() {
        guard rawEventFileLoggingEnabled else { return }
        let threadIdentifier = Self.normalizedThreadIdentifier(threadID)
        if rawEventLogFileURL != nil, rawEventLogFileThreadID == threadIdentifier {
            return
        }
        guard let fileURL = Self.makeRawEventLogFileURL(
            workspacePath: workspacePath,
            threadID: threadIdentifier
        ) else {
            return
        }
        rawEventLogFileURL = fileURL
        rawEventLogFileThreadID = threadIdentifier
        hasWrittenRawEventLogHeader = false
        UserDefaults.standard.set(fileURL.path, forKey: Self.lastRawEventLogFilePathKey)
        Self.logCodexDebug("[CodexNativeController] raw-event-log path=\(fileURL.path)")
    }

    private func appendRawEventLogRecord(_ record: [String: Any]) {
        guard rawEventFileLoggingEnabled else { return }
        ensureRawEventLogFileReadyIfNeeded()
        guard let rawEventLogFileURL else { return }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        if !FileManager.default.fileExists(atPath: rawEventLogFileURL.path) {
            _ = FileManager.default.createFile(atPath: rawEventLogFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: rawEventLogFileURL) else { return }
        do {
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private func writeRawEventLogRecord(
        kind: String,
        method: String? = nil,
        payload: Any? = nil
    ) {
        guard rawEventFileLoggingEnabled else { return }
        ensureRawEventLogFileReadyIfNeeded()
        guard rawEventLogFileURL != nil else { return }
        if !hasWrittenRawEventLogHeader {
            hasWrittenRawEventLogHeader = true
            appendRawEventLogRecord([
                "kind": "session.header",
                "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
                "runID": runID.uuidString,
                "tabID": tabID.uuidString,
                "threadID": threadID ?? "",
                "workspacePath": workspacePath ?? ""
            ])
        }
        var record: [String: Any] = [
            "kind": kind,
            "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
            "runID": runID.uuidString,
            "tabID": tabID.uuidString,
            "threadID": threadID ?? "",
            "turnID": routingCurrentTurnID ?? ""
        ]
        if let method {
            record["method"] = method
        }
        if let payload {
            if JSONSerialization.isValidJSONObject(payload) {
                record["payload"] = payload
            } else {
                record["payloadDescription"] = String(describing: payload)
            }
        }
        appendRawEventLogRecord(record)
    }

    func startOrResume(existing: SessionRef?, baseInstructions: String) async throws -> SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing: SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: nil
        )
    }

    func startOrResume(
        existing: SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> SessionRef {
        try prepareForStartOrResume()
        do {
            ensureEventsStreamReady()
            try await eventHandlingMutex.withLock {
                beginBindingSession()
            }
            let _ = MCPIntegrationHelper.ensureCodexServerForDiscovery()
            if let expectedMCPClientName {
                await client.setExpectedAgentPIDRegistration(
                    .init(clientName: expectedMCPClientName, runID: runID)
                )
            }
            await client.updateWorkingDirectory(workspacePath)
            let featurePolicy = await currentFeaturePolicy()
            await client.updateProcessFeaturePolicy(featurePolicy)
            try await client.startIfNeeded()
            await ensureInboundStreamsStarted()

            let configOverrides = await options.configOverridesProvider()
            let pathValue = existing?.rolloutPath
            let existingID = existing?.conversationID ?? ""
            let result: [String: Any]

            if existing != nil, !existingID.isEmpty || pathValue != nil {
                var params: [String: Any] = [:]
                if !existingID.isEmpty {
                    params["threadId"] = existingID
                }
                if let pathValue {
                    params["path"] = pathValue
                }
                if let model {
                    params["model"] = model
                }
                if let reasoningEffort {
                    params["effort"] = reasoningEffort
                }
                params["serviceTier"] = serviceTier ?? NSNull()
                if let workspacePath {
                    params["cwd"] = workspacePath
                }
                if !configOverrides.isEmpty {
                    params["config"] = configOverrides
                }
                // baseInstructions is intentionally omitted on thread/resume: the app-server
                // preserves original instructions across resume (confirmed by Codex protocol
                // tests: resume_switches_models_preserves_base_instructions). Resending them
                // wastes ~5-6k tokens on every reconnect for no benefit.
                result = try await requestWithCompatibleAppServerRequestValueStyle(
                    method: "thread/resume",
                    timeout: options.requestTimeout
                ) { requestValueStyle in
                    var requestParams = params
                    requestParams["approvalPolicy"] = options.approvalPolicyProvider().appServerRequestValue(style: requestValueStyle)
                    requestParams["sandbox"] = options.sandboxModeProvider().appServerRequestValue(style: requestValueStyle)
                    requestParams["approvalsReviewer"] = options.approvalReviewerProvider().appServerRequestValue
                    return requestParams
                }
            } else {
                var params: [String: Any] = [:]
                if let model {
                    params["model"] = model
                }
                if let reasoningEffort {
                    params["effort"] = reasoningEffort
                }
                params["serviceTier"] = serviceTier ?? NSNull()
                if let workspacePath {
                    params["cwd"] = workspacePath
                }
                if !configOverrides.isEmpty {
                    params["config"] = configOverrides
                }
                if !baseInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    params["baseInstructions"] = baseInstructions
                }
                result = try await requestWithCompatibleAppServerRequestValueStyle(
                    method: "thread/start",
                    timeout: options.requestTimeout
                ) { requestValueStyle in
                    var requestParams = params
                    requestParams["approvalPolicy"] = options.approvalPolicyProvider().appServerRequestValue(style: requestValueStyle)
                    requestParams["sandbox"] = options.sandboxModeProvider().appServerRequestValue(style: requestValueStyle)
                    requestParams["approvalsReviewer"] = options.approvalReviewerProvider().appServerRequestValue
                    return requestParams
                }
            }

            let pendingSessionRef = Self.parseThreadSnapshot(from: result, fallbackEffort: reasoningEffort).sessionRef
            try await disableThreadMemoryMode(threadID: pendingSessionRef.conversationID)

            let sessionRef = try await eventHandlingMutex.withLock {
                try ensureBindingCanComplete()
                let sessionRef = applyThreadResponse(result, fallbackEffort: reasoningEffort)
                await finishBindingAndDrainBufferedInbound()
                return sessionRef
            }
            try markStartOrResumeSucceeded()
            return sessionRef
        } catch {
            try? await eventHandlingMutex.withLock {
                cancelBindingSession()
            }
            markStartOrResumeFailed()
            if expectedMCPClientName != nil {
                await client.clearExpectedAgentPIDRegistration()
            }
            throw error
        }
    }

    private func disableThreadMemoryMode(threadID rawThreadID: String) async throws {
        let threadID = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty else { throw CodexAppServerClient.ClientError.invalidResponse }
        do {
            _ = try await client.request(
                method: "thread/memoryMode/set",
                params: [
                    "threadId": threadID,
                    "mode": "disabled"
                ],
                timeout: options.requestTimeout
            )
        } catch {
            guard Self.isMemoryModeCompatibilityFailure(error) else {
                throw error
            }
            Self.logCodexDebug(
                "[CodexNativeController] ignoring unsupported optional thread/memoryMode/set response: \(error.localizedDescription)"
            )
        }
    }

    func readThreadSnapshot(
        includeTurns: Bool,
        timeout: TimeInterval?
    ) async throws -> ThreadSnapshot {
        guard let threadID,
              !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        let result = try await performRequest(
            method: "thread/read",
            params: [
                "threadId": threadID,
                "includeTurns": includeTurns
            ],
            timeout: timeout
        )
        return Self.parseThreadSnapshot(from: result, fallbackEffort: nil)
    }

    func setThreadName(_ name: String, threadID explicitThreadID: String?) async throws {
        let validatedName = AgentSession.validatedName(name)
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        let resolvedThreadID = try resolvedThreadID(explicitThreadID)
        _ = try await client.request(
            method: "thread/name/set",
            params: [
                "threadId": resolvedThreadID,
                "name": validatedName
            ],
            timeout: options.requestTimeout
        )
    }

    func getThreadGoal() async throws -> ThreadGoal? {
        await updateClientProcessFeaturePolicy()
        try await client.startIfNeeded()
        let result = try await client.request(
            method: "thread/goal/get",
            params: [
                "threadId": resolvedThreadID(nil)
            ],
            timeout: options.requestTimeout
        )
        guard let rawGoal = result["goal"] else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        if rawGoal is NSNull {
            return nil
        }
        return try Self.parseThreadGoal(from: rawGoal)
    }

    func setThreadGoalObjective(_ objective: String) async throws -> ThreadGoal {
        await updateClientProcessFeaturePolicy()
        try await client.startIfNeeded()
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedObjective.isEmpty else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        let result = try await client.request(
            method: "thread/goal/set",
            params: [
                "threadId": resolvedThreadID(nil),
                "objective": trimmedObjective,
                "status": ThreadGoalStatus.active.rawValue
            ],
            timeout: options.requestTimeout
        )
        return try Self.parseThreadGoalResponse(from: result)
    }

    func setThreadGoalStatus(_ status: ThreadGoalStatus) async throws -> ThreadGoal {
        await updateClientProcessFeaturePolicy()
        try await client.startIfNeeded()
        let result = try await client.request(
            method: "thread/goal/set",
            params: [
                "threadId": resolvedThreadID(nil),
                "status": status.rawValue
            ],
            timeout: options.requestTimeout
        )
        return try Self.parseThreadGoalResponse(from: result)
    }

    func clearThreadGoal() async throws -> Bool {
        await updateClientProcessFeaturePolicy()
        try await client.startIfNeeded()
        let result = try await client.request(
            method: "thread/goal/clear",
            params: [
                "threadId": resolvedThreadID(nil)
            ],
            timeout: options.requestTimeout
        )
        guard let cleared = result["cleared"] as? Bool else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return cleared
    }

    private func resolvedThreadID(_ explicitThreadID: String?) throws -> String {
        let trimmedExplicitThreadID = explicitThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedActiveThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedThreadID = (trimmedExplicitThreadID?.isEmpty == false ? trimmedExplicitThreadID : nil)
            ?? (trimmedActiveThreadID?.isEmpty == false ? trimmedActiveThreadID : nil)
        guard let resolvedThreadID else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return resolvedThreadID
    }

    func startUserTurn(
        text: String,
        images: [AgentImageAttachment],
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?
    ) async throws -> CodexTurnStartReceipt {
        guard let threadID else { throw CodexAppServerClient.ClientError.invalidResponse }
        let input = try Self.turnInput(text: text, images: images)

        var params: [String: Any] = [
            "threadId": threadID,
            "input": input
        ]
        if let model {
            params["model"] = model
        }
        if let reasoningEffort {
            params["effort"] = reasoningEffort
        }
        params["serviceTier"] = serviceTier ?? NSNull()
        if let workspacePath {
            params["cwd"] = workspacePath
        }
        #if DEBUG
            print("[CodexNativeSessionController] turn/start request model=\(String(describing: params["model"] ?? "default")) effort=\(String(describing: params["effort"] ?? "default")) serviceTier=\(String(describing: params["serviceTier"] ?? "missing")) threadID=\(threadID)")
        #endif
        let sandboxMode = options.sandboxModeProvider()
        // turn/start can block for extended model reasoning — no timeout.
        let result = try await requestWithCompatibleAppServerRequestValueStyle(
            method: "turn/start",
            timeout: nil
        ) { requestValueStyle in
            var requestParams = params
            requestParams["approvalPolicy"] = options.approvalPolicyProvider().appServerRequestValue(style: requestValueStyle)
            requestParams["approvalsReviewer"] = options.approvalReviewerProvider().appServerRequestValue
            requestParams["sandboxPolicy"] = Self.appServerTurnSandboxPolicyPayload(
                mode: sandboxMode,
                workspacePath: workspacePath
            )
            // app-server v2 turn/start does not accept a config override bag.
            // Thread-level config changes take effect on thread/start or thread/resume.
            return requestParams
        }
        guard let turn = result["turn"] as? [String: Any],
              let submissionID = Self.nonEmptyString(turn["id"] as? String)
        else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return CodexTurnStartReceipt(provisionalSubmissionID: submissionID)
    }

    func steerUserTurn(
        text: String,
        images: [AgentImageAttachment],
        expectedTurnID: String
    ) async throws -> CodexTurnSteerReceipt {
        guard let threadID else { throw CodexAppServerClient.ClientError.invalidResponse }
        guard let expectedTurnID = Self.nonEmptyString(expectedTurnID) else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        let input = try Self.turnInput(text: text, images: images)
        do {
            let result = try await performRequest(
                method: "turn/steer",
                params: [
                    "threadId": threadID,
                    "input": input,
                    "expectedTurnId": expectedTurnID
                ],
                timeout: options.requestTimeout
            )
            guard let acceptedTurnID = Self.nonEmptyString(
                (result["turnId"] as? String)
                    ?? ((result["turn"] as? [String: Any])?["id"] as? String)
            ) else {
                throw CodexAppServerClient.ClientError.invalidResponse
            }
            // An accepted steer with a different turn ID still delivered the input;
            // callers reconcile identity from the receipt instead of retrying.
            return CodexTurnSteerReceipt(acceptedTurnID: acceptedTurnID)
        } catch let error as CodexAppServerClient.ClientError {
            throw Self.mapSteerRequestError(error, expectedTurnID: expectedTurnID)
        }
    }

    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID: String,
        acceptedDispatchTurnID: String
    ) async -> Bool {
        guard let expectedCurrentTurnID = Self.nonEmptyString(expectedCurrentTurnID),
              let acceptedDispatchTurnID = Self.nonEmptyString(acceptedDispatchTurnID),
              expectedCurrentTurnID != acceptedDispatchTurnID
        else {
            return false
        }
        do {
            return try await eventHandlingMutex.withLock {
                if authoritativeLifecycleTurnID == acceptedDispatchTurnID {
                    return true
                }
                guard authoritativeLifecycleTurnID == expectedCurrentTurnID else {
                    return false
                }
                let lineage = LifecycleAuthorityReconciliationLineage(
                    expectedCurrentTurnID: expectedCurrentTurnID,
                    acceptedDispatchTurnID: acceptedDispatchTurnID
                )
                pendingLifecycleAuthorityReconciliation = lineage
                if let observation = lifecycleAuthorityObservations.last(where: {
                    $0.lineage == lineage
                }) {
                    applyLifecycleAuthorityReconciliation(observation)
                }
                return true
            }
        } catch {
            return false
        }
    }

    func interruptUserTurn(expectedTurnID: String) async throws -> CodexTurnInterruptReceipt {
        guard let threadID else { throw CodexAppServerClient.ClientError.invalidResponse }
        guard let expectedTurnID = Self.nonEmptyString(expectedTurnID) else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        guard authoritativeLifecycleTurnID == expectedTurnID else {
            throw CodexTurnInterruptError.reconciliationFailed(
                expectedTurnID: expectedTurnID,
                authoritativeTurnID: authoritativeLifecycleTurnID
            )
        }
        do {
            _ = try await performRequest(
                method: "turn/interrupt",
                params: [
                    "threadId": threadID,
                    "turnId": expectedTurnID
                ],
                timeout: options.requestTimeout
            )
            return CodexTurnInterruptReceipt(interruptedTurnID: expectedTurnID)
        } catch let error as CodexAppServerClient.ClientError {
            throw Self.mapSteerRequestError(error, expectedTurnID: expectedTurnID)
        }
    }

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        if let authoritativeLifecycleTurnID {
            return try await interruptUserTurn(expectedTurnID: authoritativeLifecycleTurnID)
        }
        let snapshot = try await readThreadSnapshot(
            includeTurns: true,
            timeout: min(options.requestTimeout ?? 5, 5)
        )
        let observedTurnIDs = Array(
            Set(snapshot.activeTurnIDs + [snapshot.currentTurnID].compactMap(\.self))
        ).sorted()
        guard observedTurnIDs.count == 1,
              let reconciledTurnID = observedTurnIDs.first
        else {
            throw CodexTurnInterruptError.noUniqueActiveTurn(
                authoritativeTurnID: authoritativeLifecycleTurnID,
                observedTurnIDs: observedTurnIDs
            )
        }
        _ = try await performRequest(
            method: "turn/interrupt",
            params: [
                "threadId": snapshot.conversationID,
                "turnId": reconciledTurnID
            ],
            timeout: options.requestTimeout
        )
        return CodexTurnInterruptReceipt(interruptedTurnID: reconciledTurnID)
    }

    func compactThread() async throws {
        let threadID = try resolvedThreadID(nil)
        _ = try await client.request(
            method: "thread/compact/start",
            params: [
                "threadId": threadID
            ],
            timeout: options.requestTimeout
        )
    }

    func cancelCurrentTurn() async {
        do {
            _ = try await reconcileAndInterruptCurrentTurn()
        } catch {
            await emit(.error("Codex native interrupt failed: \(error.localizedDescription)"))
        }
    }

    enum InterruptActiveTurnRefreshResult: Equatable {
        case refreshed(String?)
        case failed
    }

    static func resolvedInterruptTurnID(
        cachedTurnID: String?,
        refreshResult: InterruptActiveTurnRefreshResult
    ) -> String? {
        let candidateTurnID: String? = switch refreshResult {
        case let .refreshed(refreshedTurnID):
            refreshedTurnID
        case .failed:
            cachedTurnID
        }
        guard let turnID = candidateTurnID?.trimmingCharacters(in: .whitespacesAndNewlines), !turnID.isEmpty else {
            return nil
        }
        return turnID
    }

    private func refreshActiveTurnForInterruptIfPossible() async -> InterruptActiveTurnRefreshResult {
        guard threadID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failed
        }
        let timeout = min(options.requestTimeout ?? 5, 5)
        do {
            let snapshot = try await readThreadSnapshot(includeTurns: true, timeout: timeout)
            reconcileActiveTurnRoutingState(from: snapshot)
            return .refreshed(snapshot.currentTurnID)
        } catch {
            Self.logCodexDebug("[CodexNativeController] interrupt active-turn refresh failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private func reconcileActiveTurnRoutingState(from snapshot: ThreadSnapshot) {
        threadID = snapshot.conversationID
        threadPath = snapshot.rolloutPath
        routingCurrentTurnID = snapshot.currentTurnID
        activeTurnIDs = Set(snapshot.activeTurnIDs)
        activeTurnOrder = snapshot.activeTurnIDs
        activeTurnIDsWithObservedActivity = Set(snapshot.activeTurnIDs)
    }

    static func activeTurnMismatchActualTurnID(fromErrorDescription description: String) -> String? {
        let expectedMarker = "expected active turn id `"
        let foundMarker = "` but found `"
        guard let expectedRange = description.range(of: expectedMarker) else { return nil }
        let searchStart = expectedRange.upperBound
        guard let foundRange = description[searchStart...].range(of: foundMarker) else { return nil }
        let actualStart = foundRange.upperBound
        guard let actualEnd = description[actualStart...].firstIndex(of: "`") else { return nil }
        let actual = description[actualStart ..< actualEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return actual.isEmpty ? nil : actual
    }

    private static func turnInput(
        text: String,
        images: [AgentImageAttachment]
    ) throws -> [[String: Any]] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var input: [[String: Any]] = []
        for image in images {
            switch image.source {
            case let .localFile(path):
                guard let path = nonEmptyString(path) else { continue }
                input.append([
                    "type": "localImage",
                    "path": path
                ])
            case let .url(rawURL):
                guard let rawURL = nonEmptyString(rawURL) else { continue }
                input.append([
                    "type": "image",
                    "url": rawURL
                ])
            }
        }
        if !trimmedText.isEmpty {
            input.append([
                "type": "text",
                "text": trimmedText,
                "textElements": []
            ])
        }
        guard !input.isEmpty else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return input
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func mapSteerRequestError(
        _ error: CodexAppServerClient.ClientError,
        expectedTurnID: String
    ) -> Error {
        guard case let .requestFailed(failure) = error else { return error }
        if let turnKind = structuredNonSteerableTurnKind(from: failure.data) {
            return CodexTurnSteerError.activeTurnNotSteerable(
                turnKind: turnKind,
                failure: failure
            )
        }
        if structuredNoActiveTurn(from: failure.data) {
            return CodexTurnSteerError.noActiveTurn(failure)
        }
        if let actualTurnID = structuredActualTurnID(from: failure.data) {
            return CodexTurnSteerError.expectedTurnMismatch(
                expectedTurnID: expectedTurnID,
                actualTurnID: actualTurnID,
                failure: failure
            )
        }

        let normalizedMessage = failure.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedMessage == "no active turn to steer" {
            return CodexTurnSteerError.noActiveTurn(failure)
        }
        if normalizedMessage == "cannot steer a review turn" {
            return CodexTurnSteerError.activeTurnNotSteerable(
                turnKind: "review",
                failure: failure
            )
        }
        if normalizedMessage == "cannot steer a compact turn" {
            return CodexTurnSteerError.activeTurnNotSteerable(
                turnKind: "compact",
                failure: failure
            )
        }
        if let actualTurnID = activeTurnMismatchActualTurnID(fromErrorDescription: failure.message) {
            return CodexTurnSteerError.expectedTurnMismatch(
                expectedTurnID: expectedTurnID,
                actualTurnID: actualTurnID,
                failure: failure
            )
        }
        return error
    }

    private static func structuredNonSteerableTurnKind(from data: CodexJSONValue?) -> String? {
        guard case let .object(root) = data else { return nil }
        if case let .string(kind) = root["turnKind"] {
            return nonEmptyString(kind)
        }
        if case let .object(info) = root["codexErrorInfo"],
           case let .object(nonSteerable) = info["activeTurnNotSteerable"],
           case let .string(kind) = nonSteerable["turnKind"]
        {
            return nonEmptyString(kind)
        }
        if case let .object(nonSteerable) = root["activeTurnNotSteerable"],
           case let .string(kind) = nonSteerable["turnKind"]
        {
            return nonEmptyString(kind)
        }
        return nil
    }

    private static func structuredNoActiveTurn(from data: CodexJSONValue?) -> Bool {
        guard case let .object(root) = data else { return false }
        if root["noActiveTurn"] != nil {
            return true
        }
        if case let .string(type) = root["type"] {
            return type == "noActiveTurn"
        }
        if case let .string(code) = root["code"] {
            return code == "noActiveTurn"
        }
        return false
    }

    private static func structuredActualTurnID(from data: CodexJSONValue?) -> String? {
        guard case let .object(root) = data else { return nil }
        for key in ["actualTurnId", "actualTurnID", "activeTurnId", "activeTurnID"] {
            if case let .string(value) = root[key],
               let value = nonEmptyString(value)
            {
                return value
            }
        }
        if case let .object(mismatch) = root["expectedTurnMismatch"] {
            for key in ["actualTurnId", "actualTurnID", "activeTurnId", "activeTurnID"] {
                if case let .string(value) = mismatch[key],
                   let value = nonEmptyString(value)
                {
                    return value
                }
            }
        }
        return nil
    }

    func shutdown() async {
        withEventsStateLock {
            if lifecycleState != .terminated {
                lifecycleState = .shuttingDown
            }
        }
        notificationTask?.cancel()
        notificationTask = nil
        serverRequestTask?.cancel()
        serverRequestTask = nil
        fileChangeStateByItemID.removeAll(keepingCapacity: false)
        terminalFileChangeItemIDs.removeAll(keepingCapacity: false)
        commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: false)
        finishEventsStreamIfNeeded()
        if expectedMCPClientName != nil {
            await client.clearExpectedAgentPIDRegistration()
        }
        if clientShutdownBehavior == .stopOnShutdown {
            await client.stop()
        }
    }

    private func restoreThreadSnapshot(_ snapshot: ThreadSnapshot) {
        threadID = snapshot.conversationID
        threadPath = snapshot.rolloutPath
        routingCurrentTurnID = snapshot.currentTurnID
        activeTurnIDs = Set(snapshot.activeTurnIDs)
        activeTurnOrder = snapshot.activeTurnIDs
        activeTurnIDsWithObservedActivity = Set(snapshot.activeTurnIDs)
        assistantDeltaSeenTurnIDs.removeAll(keepingCapacity: true)
        fileChangeStateByItemID.removeAll(keepingCapacity: true)
        terminalFileChangeItemIDs.removeAll(keepingCapacity: true)
        commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
    }

    private func applyThreadResponse(_ result: [String: Any], fallbackEffort: String?) -> SessionRef {
        let snapshot = Self.parseThreadSnapshot(from: result, fallbackEffort: fallbackEffort)
        restoreThreadSnapshot(snapshot)
        #if DEBUG
            ensureRawEventLogFileReadyIfNeeded()
        #endif
        #if DEBUG
            writeRawEventLogRecord(kind: "session.threadReady", payload: [
                "conversationID": snapshot.conversationID,
                "rolloutPath": snapshot.rolloutPath ?? NSNull(),
                "activeTurnIDs": snapshot.activeTurnIDs,
                "currentTurnID": snapshot.currentTurnID ?? NSNull()
            ] as [String: Any])
        #endif
        return snapshot.sessionRef
    }

    private static func parseThreadSnapshot(
        from result: [String: Any],
        fallbackEffort: String?
    ) -> ThreadSnapshot {
        let thread = result["thread"] as? [String: Any] ?? [:]
        let conversationID = firstString(in: thread, keys: ["id", "threadId", "thread_id", "threadID"]) ?? ""
        let rolloutPath = firstString(in: thread, keys: ["path"])
        let model = result["model"] as? String
        let reasoningEffort = result["reasoningEffort"] as? String ?? fallbackEffort
        let runtimeStatus = parseThreadRuntimeStatus(from: thread["status"])
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var activeTurnIDs: [String] = []
        var latestTurnStatus: TurnStatus?
        for turn in turns {
            let statusRaw = firstString(in: turn, keys: ["status"])
            if isThreadSnapshotTurnActive(statusRaw) {
                if let turnID = firstString(in: turn, keys: ["id", "turnId", "turn_id", "turnID"]),
                   !activeTurnIDs.contains(turnID)
                {
                    activeTurnIDs.append(turnID)
                }
            }
            if let parsedStatus = parseTerminalTurnStatus(from: statusRaw) {
                latestTurnStatus = parsedStatus
            }
        }
        return ThreadSnapshot(
            conversationID: conversationID,
            rolloutPath: rolloutPath,
            model: model,
            reasoningEffort: reasoningEffort,
            runtimeStatus: runtimeStatus,
            currentTurnID: activeTurnIDs.last,
            activeTurnIDs: activeTurnIDs,
            latestTurnStatus: latestTurnStatus
        )
    }

    private func updateClientProcessFeaturePolicy() async {
        await client.updateProcessFeaturePolicy(currentFeaturePolicy())
    }

    private func currentFeaturePolicy() async -> CodexOverrides.FeaturePolicy {
        await MainActor.run {
            .resolved(
                goalsEnabled: options.goalSupportEnabledProvider(),
                computerUseEnabled: options.computerUseEnabledProvider()
            )
        }
    }

    private static func parseThreadGoalResponse(from result: [String: Any]) throws -> ThreadGoal {
        guard let rawGoal = result["goal"] else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return try parseThreadGoal(from: rawGoal)
    }

    private static func parseThreadGoal(from raw: Any?) throws -> ThreadGoal {
        guard let goal = raw as? [String: Any] else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        let threadID = stringScalarValue(from: goal["threadId"])
            ?? stringScalarValue(from: goal["thread_id"])
            ?? stringScalarValue(from: goal["threadID"])
            ?? stringScalarValue(from: goal["id"])
        let objective = stringScalarValue(from: goal["objective"])
        guard let threadID, let objective else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        return try ThreadGoal(
            threadID: threadID,
            objective: objective,
            status: parseThreadGoalStatus(goal["status"]),
            tokenBudget: int64Value(goal["tokenBudget"]) ?? int64Value(goal["token_budget"]),
            tokensUsed: int64Value(goal["tokensUsed"]) ?? int64Value(goal["tokens_used"]) ?? 0,
            timeUsedSeconds: int64Value(goal["timeUsedSeconds"]) ?? int64Value(goal["time_used_seconds"]) ?? 0,
            createdAt: int64Value(goal["createdAt"]) ?? int64Value(goal["created_at"]) ?? 0,
            updatedAt: int64Value(goal["updatedAt"]) ?? int64Value(goal["updated_at"]) ?? 0
        )
    }

    private static func parseThreadGoalStatus(_ raw: Any?) throws -> ThreadGoalStatus {
        guard let normalized = stringScalarValue(from: raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        else {
            throw CodexAppServerClient.ClientError.invalidResponse
        }
        switch normalized {
        case "active":
            return .active
        case "paused":
            return .paused
        case "budgetlimited":
            return .budgetLimited
        case "complete", "completed":
            return .complete
        default:
            throw CodexAppServerClient.ClientError.invalidResponse
        }
    }

    private static func parseThreadRuntimeStatus(from raw: Any?) -> ThreadSnapshot.RuntimeStatus {
        if let rawStatus = raw as? [String: Any] {
            let type = firstString(in: rawStatus, keys: ["type"])?.lowercased()
            switch type {
            case "active":
                let activeFlags = (rawStatus["activeFlags"] as? [Any] ?? [])
                    .compactMap { stringScalarValue(from: $0) }
                return .active(activeFlags: activeFlags)
            case "idle":
                return .idle
            case "systemerror", "system_error":
                return .systemError
            case "notloaded", "not_loaded":
                return .notLoaded
            default:
                break
            }
        }

        let normalized = stringScalarValue(from: raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "active":
            return .active(activeFlags: [])
        case "idle":
            return .idle
        case "systemerror", "system_error":
            return .systemError
        case "notloaded", "not_loaded":
            return .notLoaded
        default:
            return .notLoaded
        }
    }

    private static func isThreadSnapshotTurnActive(_ rawStatus: String?) -> Bool {
        guard let normalized = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }
        return normalized == "inprogress" || normalized == "in_progress"
    }

    private static func parseTerminalTurnStatus(from rawStatus: String?) -> TurnStatus? {
        guard let normalized = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }
        switch normalized {
        case "completed":
            return .completed
        case "interrupted":
            return .interrupted
        case "failed":
            return .failed
        default:
            return nil
        }
    }

    private func ensureInboundStreamsStarted() async {
        await startNotificationStreamIfNeeded()
        await startServerRequestStreamIfNeeded()
    }

    private func shouldInstallInboundStreamTask() -> Bool {
        withEventsStateLock {
            switch lifecycleState {
            case .binding, .active:
                true
            case .fresh, .shuttingDown, .terminated:
                false
            }
        }
    }

    private func startNotificationStreamIfNeeded() async {
        guard notificationTask == nil else { return }
        let stream = await client.subscribeNotifications()
        guard shouldInstallInboundStreamTask() else { return }
        notificationTask = Task { [weak self] in
            for await notification in stream {
                guard let self else { return }
                do {
                    try await eventHandlingMutex.withLock {
                        await self.handleOrBufferNotification(notification)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
            guard let self else { return }
            await handleInboundStreamDidExit(kind: .notifications, source: "notifications")
        }
    }

    private func startServerRequestStreamIfNeeded() async {
        guard serverRequestTask == nil else { return }
        let stream = await client.subscribeServerRequests()
        guard shouldInstallInboundStreamTask() else { return }
        serverRequestTask = Task { [weak self] in
            for await request in stream {
                guard let self else { return }
                do {
                    try await eventHandlingMutex.withLock {
                        await self.handleOrBufferServerRequest(request)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
            guard let self else { return }
            await handleInboundStreamDidExit(kind: .serverRequests, source: "serverRequests")
        }
    }

    private func beginBindingSession() {
        isBindingSession = true
        bufferedInbound.removeAll(keepingCapacity: true)
        commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
    }

    private func cancelBindingSession() {
        isBindingSession = false
        bufferedInbound.removeAll(keepingCapacity: false)
        commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
    }

    private func finishBindingAndDrainBufferedInbound() async {
        let pending = bufferedInbound
        bufferedInbound.removeAll(keepingCapacity: false)
        isBindingSession = false
        for inbound in pending {
            switch inbound {
            case let .notification(notification):
                await handleNotification(notification)
            case let .serverRequest(request):
                await handleServerRequest(request)
            }
        }
    }

    private func handleOrBufferNotification(_ notification: CodexAppServerClient.Notification) async {
        if isBindingSession {
            appendBufferedInbound(.notification(notification))
            return
        }
        await handleNotification(notification)
    }

    private func handleOrBufferServerRequest(_ request: CodexAppServerClient.ServerRequest) async {
        if isBindingSession {
            appendBufferedInbound(.serverRequest(request))
            return
        }
        await handleServerRequest(request)
    }

    private func appendBufferedInbound(_ inbound: BufferedInbound) {
        if bufferedInbound.count >= maxBufferedInbound {
            bufferedInbound.removeFirst()
            Self.logCodexDebug("[CodexNativeController] dropping oldest pre-bind inbound event due to buffer cap")
        }
        bufferedInbound.append(inbound)
    }

    private func handleInboundStreamDidExit(kind: InboundStreamKind, source: String) async {
        switch kind {
        case .notifications:
            notificationTask = nil
        case .serverRequests:
            serverRequestTask = nil
        }
        do {
            try await eventHandlingMutex.withLock {
                await handleTransportStreamEnded(source: source)
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    /// Called when a transport subscription stream (notifications or serverRequests) ends.
    ///
    /// Emits a transport-closed error event and finishes the `events` stream so the
    /// downstream coordinator's `for await` loop can exit and handle terminal failure.
    /// Skipped during intentional `shutdown()`, and guaranteed to fire at most once
    /// via `didHandleTransportEnd`.
    ///
    /// Related:
    /// - CodexAppServerClient.terminateTransport (finishes subscriber continuations)
    /// - CodexAgentModeCoordinator.ensureCodexNativeSession (consumes events stream)
    /// - ClaudeNativeProcessSessionController.handleStdoutEOF (reference termination)
    private func handleTransportStreamEnded(source: String) async {
        let shouldHandle = withEventsStateLock { () -> Bool in
            if lifecycleState == .shuttingDown {
                return false
            }
            guard lifecycleState != .terminated else { return false }
            guard !didHandleTransportEnd else { return false }
            didHandleTransportEnd = true
            lifecycleState = .terminated
            return true
        }
        guard shouldHandle else { return }

        Self.logCodexDebug("[CodexNativeController] transport stream ended source=\(source), emitting error + finishing events")
        // The error message must contain "transport closed" for coordinator reconnect logic.
        await emit(.error("Codex transport closed unexpectedly."))
        finishEventsStreamIfNeeded()
    }

    private func registerActiveTurn(_ turnID: String, makeCurrent: Bool = true) {
        let trimmed = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeTurnIDs.insert(trimmed)
        activeTurnOrder.removeAll(where: { $0 == trimmed })
        activeTurnOrder.append(trimmed)
        if makeCurrent {
            routingCurrentTurnID = trimmed
        }
    }

    /// Lightweight pre-registration: ensures the turn ID is known to the routing filter
    /// without mutating `activeTurnOrder` or `routingCurrentTurnID`. This prevents cascade drops
    /// when a lifecycle event (`turn/started`) was missed upstream.
    ///
    /// Related:
    /// - shouldDropNotificationForRouting (uses activeTurnIDs for drop decisions)
    /// - Investigation Gap 4: routing drop cascade prevention
    private func observeTurnIDForRouting(_ turnID: String) {
        let trimmed = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Only insert into activeTurnIDs — don't touch activeTurnOrder or routingCurrentTurnID
        // to minimize side effects from pre-registration.
        activeTurnIDs.insert(trimmed)
    }

    private func unregisterActiveTurn(_ turnID: String) {
        let trimmed = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeTurnIDs.remove(trimmed)
        activeTurnOrder.removeAll(where: { $0 == trimmed })
        activeTurnIDsWithObservedActivity.remove(trimmed)
        assistantDeltaSeenTurnIDs.remove(trimmed)
        if routingCurrentTurnID == trimmed {
            routingCurrentTurnID = activeTurnOrder.last(where: { activeTurnIDsWithObservedActivity.contains($0) })
        }
    }

    private func markTurnActivity(_ turnID: String, makeCurrent: Bool) {
        registerActiveTurn(turnID, makeCurrent: makeCurrent)
        activeTurnIDsWithObservedActivity.insert(turnID)
    }

    private func recordLifecycleAuthorityObservation(
        turnID: String,
        kind: LifecycleAuthorityObservationKind
    ) {
        guard let authoritativeLifecycleTurnID,
              authoritativeLifecycleTurnID != turnID
        else {
            return
        }
        let lineage = LifecycleAuthorityReconciliationLineage(
            expectedCurrentTurnID: authoritativeLifecycleTurnID,
            acceptedDispatchTurnID: turnID
        )
        let observation = LifecycleAuthorityObservation(lineage: lineage, kind: kind)
        lifecycleAuthorityObservations.removeAll(where: { $0 == observation })
        lifecycleAuthorityObservations.append(observation)
        if lifecycleAuthorityObservations.count > 8 {
            lifecycleAuthorityObservations.removeFirst(lifecycleAuthorityObservations.count - 8)
        }
        if pendingLifecycleAuthorityReconciliation == lineage {
            applyLifecycleAuthorityReconciliation(observation)
        }
    }

    private func applyLifecycleAuthorityReconciliation(
        _ observation: LifecycleAuthorityObservation
    ) {
        let lineage = observation.lineage
        guard pendingLifecycleAuthorityReconciliation == lineage,
              authoritativeLifecycleTurnID == lineage.expectedCurrentTurnID
        else {
            return
        }
        switch observation.kind {
        case .started:
            let expectedWasRoutingCurrent = routingCurrentTurnID == lineage.expectedCurrentTurnID
            unregisterActiveTurn(lineage.expectedCurrentTurnID)
            registerActiveTurn(
                lineage.acceptedDispatchTurnID,
                makeCurrent: expectedWasRoutingCurrent
            )
            authoritativeLifecycleTurnID = lineage.acceptedDispatchTurnID
        case .completed:
            unregisterActiveTurn(lineage.expectedCurrentTurnID)
            unregisterActiveTurn(lineage.acceptedDispatchTurnID)
            authoritativeLifecycleTurnID = nil
        }
        pendingLifecycleAuthorityReconciliation = nil
        lifecycleAuthorityObservations.removeAll(where: { $0.lineage == lineage })
    }

    private func handleNotification(_ notification: CodexAppServerClient.Notification) async {
        guard let threadID else { return }
        let params = decodeParams(notification.params)
        #if DEBUG
            writeRawEventLogRecord(kind: "notification.received", method: notification.method, payload: params)
        #endif

        // Pre-register observed turn IDs before the routing drop decision to prevent
        // cascade drops when a lifecycle event (turn/started) was missed due to decode
        // failures. Only pre-register for turn/item-scoped methods when the thread matches.
        if Self.isTurnOrItemScopedNotificationMethod(notification.method) {
            let notifiedThreadID = Self.notificationThreadID(from: params)
            let threadMatches = notifiedThreadID == nil || notifiedThreadID == threadID
            if notifiedThreadID == nil {
                Self.logCodexDebug(
                    "[CodexNativeController] turn/item notification missing thread identifier method=\(notification.method)"
                )
            }
            if threadMatches, let observedTurnID = Self.notificationTurnID(from: params) {
                observeTurnIDForRouting(observedTurnID)
            }
        }

        if Self.shouldDropNotificationForRouting(
            method: notification.method,
            params: params,
            activeThreadID: threadID,
            currentTurnID: routingCurrentTurnID,
            activeTurnIDs: activeTurnIDs
        ) {
            #if DEBUG
                writeRawEventLogRecord(kind: "notification.dropped", method: notification.method, payload: params)
            #endif
            return
        }
        let notifiedTurnID = Self.notificationTurnID(from: params)
        if let notifiedTurnID,
           Self.shouldPromoteCurrentTurn(
               method: notification.method,
               notifiedTurnID: notifiedTurnID,
               currentTurnID: routingCurrentTurnID
           )
        {
            markTurnActivity(notifiedTurnID, makeCurrent: true)
        }
        switch notification.method {
        case "turn/started", "codex/event/turn_started":
            emittedToolEventDedupKeys.removeAll(keepingCapacity: true)
            let turnID: String?
            if let turn = params["turn"] as? [String: Any] {
                turnID = (turn["id"] as? String) ?? (turn["turn_id"] as? String)
                if let turnID {
                    registerActiveTurn(turnID, makeCurrent: false)
                    if authoritativeLifecycleTurnID == nil || authoritativeLifecycleTurnID == turnID {
                        authoritativeLifecycleTurnID = turnID
                    } else {
                        recordLifecycleAuthorityObservation(turnID: turnID, kind: .started)
                    }
                }
            } else {
                turnID = notifiedTurnID
                if let notifiedTurnID {
                    registerActiveTurn(notifiedTurnID, makeCurrent: false)
                    if authoritativeLifecycleTurnID == nil || authoritativeLifecycleTurnID == notifiedTurnID {
                        authoritativeLifecycleTurnID = notifiedTurnID
                    } else {
                        recordLifecycleAuthorityObservation(turnID: notifiedTurnID, kind: .started)
                    }
                }
            }
            await emit(.turnStarted(turnID: turnID))
        case "turn/completed", "codex/event/turn_completed":
            emittedToolEventDedupKeys.removeAll(keepingCapacity: true)
            let statusRaw = (params["turn"] as? [String: Any])?["status"] as? String
            let parsedTurnID =
                ((params["turn"] as? [String: Any])?["id"] as? String)
                    ?? ((params["turn"] as? [String: Any])?["turn_id"] as? String)
                    ?? notifiedTurnID
            let turnID = parsedTurnID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasActive = turnID.map { activeTurnIDs.contains($0) } ?? false
            let trackingWasUncertain = activeTurnIDs.isEmpty || routingCurrentTurnID == nil
            let matchesCurrentTurn = turnID != nil && turnID == routingCurrentTurnID
            let nilCompletionHasSingleActiveTurn = turnID == nil
                && activeTurnIDs.count <= 1
                && authoritativeLifecycleTurnID != nil
            if let turnID {
                recordLifecycleAuthorityObservation(turnID: turnID, kind: .completed)
                unregisterActiveTurn(turnID)
                if authoritativeLifecycleTurnID == turnID {
                    authoritativeLifecycleTurnID = nil
                }
            } else if nilCompletionHasSingleActiveTurn,
                      let authoritativeLifecycleTurnID
            {
                unregisterActiveTurn(authoritativeLifecycleTurnID)
                self.authoritativeLifecycleTurnID = nil
            } else if authoritativeLifecycleTurnID == nil,
                      let routingCurrentTurnID
            {
                unregisterActiveTurn(routingCurrentTurnID)
            }
            if wasActive || matchesCurrentTurn || trackingWasUncertain || nilCompletionHasSingleActiveTurn {
                await emit(.turnCompleted(turnID: turnID, status: mapTurnStatus(statusRaw ?? "completed")))
            } else {
                Self.logCodexDebug(
                    "[CodexNativeController] ignoring turnCompleted for non-active turnID=\(turnID ?? "nil") currentTurnID=\(routingCurrentTurnID ?? "nil") activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ","))"
                )
            }
        case "codex/event/task_complete":
            // The app-server currently mirrors task completion through canonical
            // `turn/completed` notifications as well. Treat `task_complete` as a
            // non-authoritative lifecycle hint here so one backend turn yields one
            // local completion event and we do not stale-finalize follow-up turns.
            break
        case "thread/compacted":
            await emit(.contextCompacted(turnID: notifiedTurnID))
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                if let turnID = Self.notificationTurnID(from: params) {
                    assistantDeltaSeenTurnIDs.insert(turnID)
                }
                await emit(.assistantDelta(delta))
            }
        case "codex/event/agent_message":
            if let message = Self.assistantMessageText(from: params), !message.isEmpty {
                if let turnID = Self.notificationTurnID(from: params) {
                    if assistantDeltaSeenTurnIDs.contains(turnID) {
                        break
                    }
                    assistantDeltaSeenTurnIDs.insert(turnID)
                }
                await emit(.assistantDelta(message))
            }
        case "item/reasoning/summaryTextDelta":
            if let delta = params["delta"] as? String {
                let itemID = (params["itemId"] as? String) ?? (params["item_id"] as? String)
                let summaryIndex = intValue(params["summaryIndex"]) ?? intValue(params["summary_index"])
                let groupID = makeReasoningGroupID(kind: "summary", itemID: itemID, index: summaryIndex)
                await emit(.reasoningDelta(.init(
                    text: delta,
                    kind: .summary,
                    itemID: itemID,
                    groupID: groupID,
                    index: summaryIndex
                )))
            }
        case "item/reasoning/textDelta":
            if let delta = params["delta"] as? String {
                let itemID = (params["itemId"] as? String) ?? (params["item_id"] as? String)
                let contentIndex = intValue(params["contentIndex"]) ?? intValue(params["content_index"])
                let groupID = makeReasoningGroupID(kind: "text", itemID: itemID, index: contentIndex)
                await emit(.reasoningDelta(.init(
                    text: delta,
                    kind: .text,
                    itemID: itemID,
                    groupID: groupID,
                    index: contentIndex
                )))
            }
        case let method where Self.isItemLifecycleNotificationMethod(method):
            if let toolEvent = parseToolLifecycleEvent(method: method, params: params) {
                switch toolEvent {
                case let .call(name, invocationID, argsJSON, dedupKey):
                    let emitted = markToolEventEmitted(key: "call:\(dedupKey)")
                    Self.logCodexDebug("[CodexNativeController] toolCall method=\(method) tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil") emitted=\(emitted) args=\(Self.debugPreview(argsJSON))")
                    guard emitted else { break }
                    await emit(.toolCall(name: name, invocationID: invocationID, argsJSON: argsJSON))
                case let .result(name, invocationID, argsJSON, resultJSON, isError, dedupKey):
                    let emitted = markToolEventEmitted(key: "result:\(dedupKey)")
                    Self.logCodexDebug("[CodexNativeController] toolResult method=\(method) tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil") emitted=\(emitted) isError=\(isError.map(String.init(describing:)) ?? "nil") result=\(Self.debugPreview(resultJSON))")
                    guard emitted else { break }
                    await emit(.toolResult(
                        name: name,
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        resultJSON: resultJSON,
                        isError: isError
                    ))
                    if Self.normalizedExternalToolName(name) != "bash",
                       let runningUpdate = Self.commandExecutionRunningUpdate(
                           fromToolName: name,
                           argsJSON: argsJSON,
                           resultJSON: resultJSON,
                           isError: isError
                       )
                    {
                        Self.logCodexDebug("[CodexNativeController] derivedRunningUpdate source=toolResult tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil") processID=\(runningUpdate.processID ?? "nil") outputChars=\(runningUpdate.appendedOutput?.count ?? 0)")
                        await emit(.commandExecutionRunning(runningUpdate))
                    }
                }
            }
        case "item/fileChange/outputDelta",
             "item/file_change/output_delta",
             "codex/event/item_fileChange_outputDelta",
             "codex/event/item_file_change_output_delta":
            if let patchUpdate = parseFileChangeOutputDeltaEvent(params: params),
               case let .result(name, invocationID, argsJSON, resultJSON, isError, dedupKey) = patchUpdate
            {
                let emitted = markToolEventEmitted(key: "result:\(dedupKey)")
                Self.logCodexDebug("[CodexNativeController] fileChangeOutputDelta invocationID=\(invocationID?.uuidString ?? "nil") emitted=\(emitted) result=\(Self.debugPreview(resultJSON))")
                guard emitted else { break }
                await emit(.toolResult(
                    name: name,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON,
                    isError: isError
                ))
            }
        case "codex/event/exec_command_begin":
            if let beginEvent = parseExecCommandBeginEvent(params: params) {
                guard shouldAcceptCommandExecutionEvent(
                    itemID: beginEvent.dedupKey,
                    family: .raw
                ) else {
                    break
                }
                let emitted = markToolEventEmitted(key: "call:\(beginEvent.dedupKey)")
                Self.logCodexDebug("[CodexNativeController] execCommandBegin callID=\(beginEvent.dedupKey) invocationID=\(beginEvent.invocationID?.uuidString ?? "nil") processID=\(beginEvent.processID ?? "nil") emitted=\(emitted)")
                if emitted {
                    await emit(.toolCall(name: "bash", invocationID: beginEvent.invocationID, argsJSON: beginEvent.argsJSON))
                }
                if beginEvent.invocationID != nil || beginEvent.processID != nil {
                    await emit(.commandExecutionRunning(.init(
                        invocationID: beginEvent.invocationID,
                        processID: beginEvent.processID,
                        appendedOutput: nil
                    )))
                }
            }
        case "codex/event/exec_command_output_delta":
            let itemID = commandExecutionItemID(from: params)
            guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .raw) else {
                break
            }
            if let update = parseExecCommandOutputDeltaUpdate(params: params) {
                Self.logCodexDebug("[CodexNativeController] runningUpdate method=\(notification.method) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
                await emit(.commandExecutionRunning(update))
            }
        case "codex/event/exec_command_end":
            if let completion = parseExecCommandEndEvent(params: params) {
                guard shouldAcceptCommandExecutionEvent(
                    itemID: completion.dedupKey,
                    family: .raw
                ) else {
                    break
                }
                let emitted = markToolEventEmitted(key: "result:\(completion.dedupKey)")
                Self.logCodexDebug("[CodexNativeController] execCommandEnd callID=\(completion.dedupKey) invocationID=\(completion.invocationID?.uuidString ?? "nil") processID=\(completion.processID ?? "nil") emitted=\(emitted)")
                guard emitted else { break }
                await emit(.toolResult(
                    name: "bash",
                    invocationID: completion.invocationID,
                    argsJSON: completion.argsJSON,
                    resultJSON: completion.resultJSON,
                    isError: completion.isError
                ))
            }
        case "item/commandExecution/outputDelta",
             "item/command_execution/output_delta",
             "codex/event/item_commandExecution_outputDelta",
             "codex/event/item_command_execution_output_delta":
            let itemID = commandExecutionItemID(from: params)
            guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .normalized) else {
                break
            }
            if let update = parseCommandExecutionRunningUpdateFromNotification(
                params: params,
                outputKeys: ["delta"]
            ) {
                Self.logCodexDebug("[CodexNativeController] runningUpdate method=\(notification.method) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
                await emit(.commandExecutionRunning(update))
            }
        case "item/commandExecution/terminalInteraction",
             "item/command_execution/terminal_interaction",
             "codex/event/item_commandExecution_terminalInteraction",
             "codex/event/item_command_execution_terminal_interaction":
            let itemID = commandExecutionItemID(from: params)
            guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .normalized) else {
                break
            }
            if let update = parseCommandExecutionRunningUpdateFromNotification(
                params: params,
                outputKeys: []
            ) {
                Self.logCodexDebug("[CodexNativeController] runningUpdate method=\(notification.method) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
                await emit(.commandExecutionRunning(update))
            }
        case "codex/event/terminal_interaction":
            let itemID = commandExecutionItemID(from: params)
            guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .raw) else {
                break
            }
            if let update = parseCommandExecutionRunningUpdateFromNotification(
                params: params,
                outputKeys: ["output", "delta", "text", "message", "content", "stdout", "stderr"]
            ) {
                Self.logCodexDebug("[CodexNativeController] runningUpdate method=\(notification.method) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
                await emit(.commandExecutionRunning(update))
            }
        case "codex/event/mcp_tool_call_begin", "codex/event/mcp_tool_call_end":
            if let toolEvent = parseRawMCPToolLifecycleEvent(method: notification.method, params: params) {
                switch toolEvent {
                case let .call(name, invocationID, argsJSON, dedupKey):
                    let emitted = markToolEventEmitted(key: "call:\(dedupKey)")
                    guard emitted else { break }
                    await emit(.toolCall(name: name, invocationID: invocationID, argsJSON: argsJSON))
                case let .result(name, invocationID, argsJSON, resultJSON, isError, dedupKey):
                    let emitted = markToolEventEmitted(key: "result:\(dedupKey)")
                    guard emitted else { break }
                    await emit(.toolResult(
                        name: name,
                        invocationID: invocationID,
                        argsJSON: argsJSON,
                        resultJSON: resultJSON,
                        isError: isError
                    ))
                    if Self.normalizedExternalToolName(name) != "bash",
                       let runningUpdate = Self.commandExecutionRunningUpdate(
                           fromToolName: name,
                           argsJSON: argsJSON,
                           resultJSON: resultJSON,
                           isError: isError
                       )
                    {
                        await emit(.commandExecutionRunning(runningUpdate))
                    }
                }
            }
        case "thread/tokenUsage/updated",
             "thread/token_usage/updated",
             "codex/event/thread_tokenUsage_updated",
             "codex/event/thread_token_usage_updated":
            if let usage = parseTokenUsage(from: params) {
                await emit(.tokenUsage(usage))
            }
        case "error":
            if let errorNotification = Self.parseErrorNotification(from: params) {
                await emit(.errorNotification(errorNotification))
            }
        default:
            if let activity = Self.parseLivenessActivity(method: notification.method, params: params) {
                await emit(.livenessActivity(activity))
            }
        }
    }

    private static func parseErrorNotification(from params: [String: Any]) -> ErrorNotification? {
        let errorObject = firstJSONObject(in: params, keys: ["error"]) ?? params
        let detailsObject = firstJSONObject(in: errorObject, keys: ["details", "detail"])
            ?? firstJSONObject(in: params, keys: ["details"])
        guard let message = firstString(
            in: errorObject,
            keys: ["message", "errorMessage", "error_message", "detail", "description"]
        ) ?? detailsObject.flatMap({
            firstString(in: $0, keys: ["message", "errorMessage", "error_message", "detail", "description"])
        }) ?? firstString(
            in: params,
            keys: ["message", "errorMessage", "error_message", "detail", "description"]
        ) else {
            return nil
        }
        let willRetry = boolScalarValue(from: errorObject["willRetry"])
            ?? boolScalarValue(from: errorObject["will_retry"])
            ?? detailsObject.flatMap { boolScalarValue(from: $0["willRetry"]) }
            ?? detailsObject.flatMap { boolScalarValue(from: $0["will_retry"]) }
            ?? boolScalarValue(from: params["willRetry"])
            ?? boolScalarValue(from: params["will_retry"])
        let threadID = notificationThreadID(from: params)
            ?? firstString(in: errorObject, keys: ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"])
            ?? detailsObject.flatMap {
                firstString(in: $0, keys: ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"])
            }
        let turnID = notificationTurnID(from: params)
            ?? firstString(in: errorObject, keys: ["turnId", "turn_id", "turnID"])
            ?? detailsObject.flatMap { firstString(in: $0, keys: ["turnId", "turn_id", "turnID"]) }
        let itemID = notificationItemID(from: params)
            ?? firstString(in: errorObject, keys: ["itemId", "item_id", "itemID", "callId", "call_id"])
            ?? detailsObject.flatMap { firstString(in: $0, keys: ["itemId", "item_id", "itemID", "callId", "call_id"]) }
        return ErrorNotification(
            message: message,
            willRetry: willRetry,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
    }

    private static func parseLivenessActivity(method: String, params: [String: Any]) -> LivenessActivity? {
        guard let kind = livenessActivityKind(for: method, params: params) else { return nil }
        return LivenessActivity(
            kind: kind,
            method: method,
            threadID: notificationThreadID(from: params),
            turnID: notificationTurnID(from: params),
            itemID: notificationItemID(from: params),
            activeFlags: notificationActiveFlags(from: params),
            message: firstString(
                in: params,
                keys: ["message", "warning", "text", "reason", "description", "detail"]
            )
        )
    }

    private static func livenessActivityKind(for method: String, params: [String: Any]) -> LivenessActivity.Kind? {
        switch method {
        case "thread/status/changed":
            return .threadStatusChanged
        case "turn/plan/updated":
            return .turnPlanUpdated
        case "turn/diff/updated":
            return .turnDiffUpdated
        case "item/plan/delta":
            return .itemPlanDelta
        case "item/mcpToolCall/progress", "item/mcp_tool_call/progress":
            return .mcpToolProgress
        case "command/exec/outputDelta", "command/exec/output_delta", "process/outputDelta", "process/output_delta":
            return .commandOrProcessOutput
        case "process/exited":
            return .processExited
        case "hook/started", "hook/completed":
            return .hookLifecycle
        case "warning":
            return .warning
        case "deprecationNotice", "deprecation_notice":
            return .deprecationNotice
        case "serverRequest/resolved", "server_request/resolved":
            return .serverRequestResolved
        default:
            guard isTurnOrItemScopedNotificationMethod(method),
                  notificationThreadID(from: params) != nil
                  || notificationTurnID(from: params) != nil
                  || notificationItemID(from: params) != nil
            else {
                return nil
            }
            return .unknownScoped
        }
    }

    private static func notificationActiveFlags(from params: [String: Any]) -> [String] {
        for candidate in notificationEnvelopeDictionaries(from: params) {
            if let status = candidate["status"] {
                let parsed = parseThreadRuntimeStatus(from: status)
                if case let .active(activeFlags) = parsed, !activeFlags.isEmpty {
                    return activeFlags
                }
            }
            if let thread = candidate["thread"] as? [String: Any], let status = thread["status"] {
                let parsed = parseThreadRuntimeStatus(from: status)
                if case let .active(activeFlags) = parsed, !activeFlags.isEmpty {
                    return activeFlags
                }
            }
            let flags = ((candidate["activeFlags"] ?? candidate["active_flags"]) as? [Any] ?? [])
                .compactMap { stringScalarValue(from: $0) }
            if !flags.isEmpty {
                return flags
            }
        }
        return []
    }

    private static func notificationEnvelopeDictionaries(from params: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = [params]
        let envelopeKeys = ["payload", "event", "request", "error", "msg"]
        for key in envelopeKeys {
            if let object = params[key] as? [String: Any] {
                result.append(object)
                for nestedKey in envelopeKeys where nestedKey != key {
                    if let nested = object[nestedKey] as? [String: Any] {
                        result.append(nested)
                    }
                }
            }
        }
        return result
    }

    private static func shouldPromoteCurrentTurn(
        method: String,
        notifiedTurnID: String,
        currentTurnID: String?
    ) -> Bool {
        guard isTurnActivityNotificationMethod(method) else {
            return false
        }
        return currentTurnID != notifiedTurnID
    }

    private static func isTurnActivityNotificationMethod(_ method: String) -> Bool {
        if isTurnLifecycleNotificationMethod(method) {
            return false
        }
        if method == "codex/event/task_started" {
            return true
        }
        if method == "codex/event/task_complete" {
            return false
        }
        if method.hasPrefix("item/") || method.hasPrefix("codex/event/item_") {
            return true
        }
        if method.hasPrefix("codex/event/agent_message")
            || method.hasPrefix("codex/event/reasoning_")
            || method.hasPrefix("codex/event/agent_reasoning")
        {
            return true
        }
        let lowerMethod = method.lowercased()
        if lowerMethod.contains("exec_command") {
            return true
        }
        return false
    }

    private static func shouldDropNotificationForRouting(
        method: String,
        params: [String: Any],
        activeThreadID: String,
        currentTurnID: String?,
        activeTurnIDs: Set<String>
    ) -> Bool {
        let isTurnOrItemScoped = isTurnOrItemScopedNotificationMethod(method)
        let isTurnLifecycleMethod = isTurnLifecycleNotificationMethod(method)
        let isStreamingItemRelated = isStreamingItemRelatedNotification(method: method, params: params)
        let hasStrongStreamingCorrelation = isStreamingItemRelated
            && hasStrongStreamingItemCorrelation(method: method, params: params)
        let notifiedThreadID = notificationThreadID(from: params)
        if let notifiedThreadID, notifiedThreadID != activeThreadID {
            logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=thread-mismatch activeThreadID=\(activeThreadID) notifiedThreadID=\(notifiedThreadID)")
            return true
        }
        if isTurnOrItemScoped, isTurnLifecycleMethod {
            return false
        }

        let notifiedTurnID = notificationTurnID(from: params)
        if isTurnOrItemScoped,
           !isTurnLifecycleMethod,
           let notifiedTurnID
        {
            if !activeTurnIDs.isEmpty {
                if !activeTurnIDs.contains(notifiedTurnID) {
                    if hasStrongStreamingCorrelation {
                        logCodexDebug("[CodexNativeController] allowNotification method=\(method) reason=turn-not-active-streaming-item activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)")
                    } else if isStreamingItemRelated {
                        logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=turn-not-active-streaming-item-weak-correlation activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)")
                        return true
                    } else {
                        logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=turn-not-active activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)")
                        return true
                    }
                }
            } else if let currentTurnID,
                      notifiedTurnID != currentTurnID
            {
                if hasStrongStreamingCorrelation {
                    logCodexDebug("[CodexNativeController] allowNotification method=\(method) reason=turn-mismatch-streaming-item activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)")
                } else if isStreamingItemRelated {
                    logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=turn-mismatch-streaming-item-weak-correlation activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)")
                    return true
                } else {
                    logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=turn-mismatch activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)")
                    return true
                }
            }
        }

        if notifiedThreadID == nil,
           notifiedTurnID == nil,
           activeTurnIDs.isEmpty,
           currentTurnID == nil,
           isTurnOrItemScoped
        {
            if hasStrongStreamingCorrelation {
                logCodexDebug("[CodexNativeController] allowNotification method=\(method) reason=unscoped-streaming-item-without-active-turn activeThreadID=\(activeThreadID)")
            } else if isStreamingItemRelated {
                logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=unscoped-streaming-item-weak-correlation activeThreadID=\(activeThreadID)")
                return true
            } else {
                logCodexDebug("[CodexNativeController] dropNotification method=\(method) reason=unscoped-without-active-turn activeThreadID=\(activeThreadID)")
                return true
            }
        }

        return false
    }

    private static func isTurnOrItemScopedNotificationMethod(_ method: String) -> Bool {
        method == "turn/started"
            || method == "turn/completed"
            || method == "codex/event/task_started"
            || method == "codex/event/task_complete"
            || method.hasPrefix("item/")
            || method.hasPrefix("codex/event/item_")
            || method.hasPrefix("codex/event/turn_")
    }

    private static func isTurnLifecycleNotificationMethod(_ method: String) -> Bool {
        method == "turn/started"
            || method == "turn/completed"
            || method == "codex/event/turn_started"
            || method == "codex/event/turn_completed"
            || method == "codex/event/task_started"
            || method == "codex/event/task_complete"
    }

    private static func notificationThreadID(from params: [String: Any]) -> String? {
        if let threadID = firstString(
            in: params,
            keys: ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"]
        ) {
            return threadID
        }
        if let threadID = stringScalarValue(from: params["thread"]) {
            return threadID
        }
        if let turn = params["turn"] as? [String: Any],
           let threadID = firstString(
               in: turn,
               keys: ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"]
           )
        {
            return threadID
        }
        if let thread = params["thread"] as? [String: Any],
           let threadID = firstString(
               in: thread,
               keys: ["id", "threadId", "thread_id", "threadID", "conversationId", "conversation_id"]
           )
        {
            return threadID
        }
        return nil
    }

    private static func notificationTurnID(from params: [String: Any]) -> String? {
        if let turnID = firstString(in: params, keys: ["turnId", "turn_id", "turnID"]) {
            return turnID
        }
        if let turnID = stringScalarValue(from: params["turn"]) {
            return turnID
        }
        if let turn = params["turn"] as? [String: Any],
           let turnID = firstString(in: turn, keys: ["id", "turnId", "turn_id", "turnID"])
        {
            return turnID
        }
        guard let message = params["msg"] as? [String: Any],
              let messageType = (message["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              messageType == "agent_message" || messageType == "task_complete" || messageType == "task_started"
        else {
            return nil
        }
        if let rawID = params["id"],
           let topLevelID = stringScalarValue(from: rawID)
        {
            return topLevelID
        }
        return firstString(in: params, keys: ["id"])
    }

    private static func notificationItemID(from params: [String: Any]) -> String? {
        let itemIDKeys = ["id", "itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
        if let item = params["item"] as? [String: Any],
           let itemID = firstString(in: item, keys: itemIDKeys)
        {
            return itemID
        }
        if let request = params["request"] as? [String: Any] {
            if let item = request["item"] as? [String: Any],
               let itemID = firstString(in: item, keys: itemIDKeys)
            {
                return itemID
            }
            if let itemID = firstString(
                in: request,
                keys: ["itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
            ) {
                return itemID
            }
        }
        if let itemID = firstString(
            in: params,
            keys: ["itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
        ) {
            return itemID
        }
        if let itemID = stringScalarValue(from: params["item"]) {
            return itemID
        }
        return stringScalarValue(from: params["id"])
    }

    private static func assistantMessageText(from params: [String: Any]) -> String? {
        if let msg = params["msg"] as? [String: Any],
           let message = msg["message"] as? String
        {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : message
        }
        if let message = params["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : message
        }
        return nil
    }

    private static func isStreamingItemRelatedNotification(
        method: String,
        params: [String: Any]
    ) -> Bool {
        let lowerMethod = method.lowercased()
        if lowerMethod.contains("commandexecution")
            || lowerMethod.contains("command_execution")
            || lowerMethod.contains("exec_command")
            || lowerMethod.contains("filechange")
            || lowerMethod.contains("file_change")
        {
            return true
        }
        for candidate in toolItemCandidates(fromParams: params) {
            if candidateLooksLikeCommandExecution(candidate) || candidateLooksLikeFileChange(candidate) {
                return true
            }
        }
        return false
    }

    private static func hasStrongStreamingItemCorrelation(
        method: String,
        params: [String: Any]
    ) -> Bool {
        let lowerMethod = method.lowercased()
        let methodIndicatesStreamingItem =
            lowerMethod.contains("commandexecution")
                || lowerMethod.contains("command_execution")
                || lowerMethod.contains("exec_command")
                || lowerMethod.contains("filechange")
                || lowerMethod.contains("file_change")
        for candidate in toolItemCandidates(fromParams: params) {
            let candidateIsStreamingItem = methodIndicatesStreamingItem
                || candidateLooksLikeCommandExecution(candidate)
                || candidateLooksLikeFileChange(candidate)
            guard candidateIsStreamingItem else { continue }
            if hasCommandCorrelationID(in: candidate, allowGenericID: true) {
                return true
            }
        }
        return false
    }

    private static func hasCommandCorrelationID(
        in candidate: [String: Any],
        allowGenericID: Bool
    ) -> Bool {
        if firstString(
            in: candidate,
            keys: [
                "callId", "call_id", "itemId", "item_id", "invocationId", "invocation_id",
                "toolCallId", "tool_call_id"
            ]
        ) != nil {
            return true
        }
        if allowGenericID,
           let genericID = firstString(in: candidate, keys: ["id"]),
           !genericID.isEmpty
        {
            return true
        }
        return false
    }

    private static func candidateLooksLikeCommandExecution(_ candidate: [String: Any]) -> Bool {
        let typeRaw = firstString(in: candidate, keys: ["type", "itemType", "item_type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if typeRaw.contains("commandexecution") || typeRaw.contains("command_execution") {
            return true
        }

        let toolName = firstString(
            in: candidate,
            keys: ["name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name"]
        )
        if normalizedExternalToolName(toolName) == "bash" {
            return true
        }
        return false
    }

    private static func candidateLooksLikeFileChange(_ candidate: [String: Any]) -> Bool {
        let typeRaw = firstString(in: candidate, keys: ["type", "itemType", "item_type"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return typeRaw.contains("filechange") || typeRaw.contains("file_change")
    }

    #if DEBUG
        func test_installThreadState(
            threadID: String,
            authoritativeTurnID: String? = nil,
            routingTurnID: String? = nil
        ) {
            self.threadID = threadID
            authoritativeLifecycleTurnID = authoritativeTurnID
            routingCurrentTurnID = routingTurnID
            activeTurnIDs = Set([authoritativeTurnID, routingTurnID].compactMap(\.self))
            activeTurnOrder = [authoritativeTurnID, routingTurnID].compactMap(\.self)
            pendingLifecycleAuthorityReconciliation = nil
            lifecycleAuthorityObservations.removeAll()
        }

        func test_handleNotification(
            method: String,
            params: [String: CodexJSONValue]
        ) async {
            try? await eventHandlingMutex.withLock {
                await handleNotification(.init(method: method, params: params))
            }
        }

        var test_authoritativeLifecycleTurnID: String? {
            authoritativeLifecycleTurnID
        }

        var test_routingCurrentTurnID: String? {
            routingCurrentTurnID
        }

        static func test_shouldDropNotificationForRouting(
            method: String,
            params: [String: Any],
            activeThreadID: String,
            currentTurnID: String?,
            activeTurnIDs: Set<String> = []
        ) -> Bool {
            shouldDropNotificationForRouting(
                method: method,
                params: params,
                activeThreadID: activeThreadID,
                currentTurnID: currentTurnID,
                activeTurnIDs: activeTurnIDs
            )
        }

        static func test_isItemLifecycleNotificationMethod(_ method: String) -> Bool {
            isItemLifecycleNotificationMethod(method)
        }

        static func test_shouldPromoteCurrentTurn(
            method: String,
            notifiedTurnID: String,
            currentTurnID: String?
        ) -> Bool {
            shouldPromoteCurrentTurn(
                method: method,
                notifiedTurnID: notifiedTurnID,
                currentTurnID: currentTurnID
            )
        }

        static func test_parseTokenUsage(from params: [String: Any]) -> AgentContextUsage? {
            parseTokenUsagePayload(from: params)
        }

        static func test_parseErrorNotification(from params: [String: Any]) -> ErrorNotification? {
            parseErrorNotification(from: params)
        }

        static func test_parseLivenessActivity(
            method: String,
            params: [String: Any]
        ) -> LivenessActivity? {
            parseLivenessActivity(method: method, params: params)
        }

        static func test_parseThreadSnapshot(
            _ result: [String: Any],
            fallbackEffort: String?
        ) -> ThreadSnapshot {
            parseThreadSnapshot(from: result, fallbackEffort: fallbackEffort)
        }

        static func test_toolItemCandidatesCount(from params: [String: Any]) -> Int {
            toolItemCandidates(fromParams: params).count
        }

        static func test_withCommandExecutionCompletedStatus(raw: String?) -> String {
            withCommandExecutionCompletedStatus(raw: raw)
        }

        static func test_commandExecutionEndIsError(exitCode: Int?, status: String?) -> Bool? {
            commandExecutionEndIsError(exitCode: exitCode, status: status)
        }

        static var test_maxRunningAggregatedOutputCharacters: Int {
            maxRunningAggregatedOutputCharacters
        }

        static func test_parseExecCommandEndEventResultJSON(params: [String: Any]) -> String? {
            let controller = CodexNativeSessionController(
                client: CodexAppServerClient(),
                runID: UUID(),
                tabID: UUID(),
                windowID: 1,
                workspacePath: nil
            )
            return controller.parseExecCommandEndEvent(params: params)?.resultJSON
        }

        struct TestToolLifecycleEvent: Equatable {
            let kind: String
            let name: String
            let invocationID: UUID?
            let argsJSON: String?
            let resultJSON: String?
            let isError: Bool?
        }

        func test_parseToolLifecycleEvent(method: String, params: [String: Any]) -> TestToolLifecycleEvent? {
            guard let event = parseToolLifecycleEvent(method: method, params: params) else { return nil }
            switch event {
            case let .call(name, invocationID, argsJSON, _):
                return TestToolLifecycleEvent(
                    kind: "call",
                    name: name,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: nil,
                    isError: nil
                )
            case let .result(name, invocationID, argsJSON, resultJSON, isError, _):
                return TestToolLifecycleEvent(
                    kind: "result",
                    name: name,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON,
                    isError: isError
                )
            }
        }

        func test_parseFileChangeOutputDeltaEvent(params: [String: Any]) -> TestToolLifecycleEvent? {
            guard let event = parseFileChangeOutputDeltaEvent(params: params) else { return nil }
            switch event {
            case .call:
                return nil
            case let .result(name, invocationID, argsJSON, resultJSON, isError, _):
                return TestToolLifecycleEvent(
                    kind: "result",
                    name: name,
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    resultJSON: resultJSON,
                    isError: isError
                )
            }
        }

        func test_beginBindingSession() async throws {
            try prepareForStartOrResume()
            ensureEventsStreamReady()
            try? await eventHandlingMutex.withLock {
                self.beginBindingSession()
            }
        }

        func test_bufferNotificationDuringBinding(_ notification: CodexAppServerClient.Notification) async {
            try? await eventHandlingMutex.withLock {
                await handleOrBufferNotification(notification)
            }
        }

        func test_bufferServerRequestDuringBinding(_ request: CodexAppServerClient.ServerRequest) async {
            try? await eventHandlingMutex.withLock {
                await handleOrBufferServerRequest(request)
            }
        }

        func test_finishBinding(result: [String: Any], fallbackEffort: String?) async -> SessionRef {
            guard let sessionRef = try? await eventHandlingMutex.withLock({
                try ensureBindingCanComplete()
                let sessionRef = applyThreadResponse(result, fallbackEffort: fallbackEffort)
                await finishBindingAndDrainBufferedInbound()
                return sessionRef
            }) else {
                fatalError("Failed to finish Codex test binding")
            }
            try? markStartOrResumeSucceeded()
            return sessionRef
        }

        func test_simulateTransportStreamEnded(source: String) async {
            try? await eventHandlingMutex.withLock {
                await handleTransportStreamEnded(source: source)
            }
        }
    #endif

    private enum ServerRequestRouting {
        case approval
        case requestUserInput
        case authTokensRefresh
        case mcpElicitation
        case permissions
        case dynamicToolUnsupported
        case unknownUnsupported
    }

    private func handleServerRequest(_ request: CodexAppServerClient.ServerRequest) async {
        let method = request.method
        let params = decodeParams(request.params)
        #if DEBUG
            writeRawEventLogRecord(kind: "serverRequest.received", method: method, payload: params)
        #endif

        switch Self.classifyServerRequestMethod(method) {
        case .approval:
            if let approval = buildApprovalRequest(id: request.id, method: method, params: params) {
                await emit(.approvalRequest(approval))
                return
            }
            do {
                try await client.respondToServerRequestError(
                    id: request.id,
                    code: -32602,
                    message: "Unsupported approval request payload for method: \(method)"
                )
            } catch {
                await emit(.error("Codex approval request response failed: \(error.localizedDescription)"))
                return
            }
            await emit(.error("Codex approval request could not be parsed (\(method))."))
        case .requestUserInput:
            guard let userInputRequest = Self.parseRequestUserInputRequest(
                requestID: request.id,
                method: method,
                params: params,
                activeThreadID: threadID,
                currentTurnID: routingCurrentTurnID
            ) else {
                await emitServerRequestIssue(
                    requestID: request.id,
                    method: method,
                    kind: .requestUserInputInvalidParams,
                    code: -32602,
                    message: "Invalid item/tool/requestUserInput params."
                )
                return
            }
            await emit(.requestUserInput(userInputRequest))
        case .authTokensRefresh:
            await handleChatgptAuthTokensRefreshServerRequest(request.id, method: method, params: params)
        case .mcpElicitation:
            if Self.isRepoPromptMCPElicitationRequest(params: params) {
                await respondToServerRequest(
                    id: request.id,
                    result: [
                        "action": "accept",
                        "content": [String: Any](),
                        "_meta": [String: Any]()
                    ]
                )
                return
            }
            if let autoAcceptResult = await computerUseMCPElicitationAutoAcceptResult(params: params) {
                await respondToServerRequest(id: request.id, result: autoAcceptResult)
                return
            }
            guard let elicitationRequest = Self.parseMCPElicitationRequest(
                requestID: request.id,
                method: method,
                params: params,
                activeThreadID: threadID,
                currentTurnID: routingCurrentTurnID
            ) else {
                await emitServerRequestIssue(
                    requestID: request.id,
                    method: method,
                    kind: .mcpElicitationInvalidParams,
                    code: -32602,
                    message: "Invalid mcpServer/elicitation/request params."
                )
                return
            }
            await emit(.mcpElicitationRequest(elicitationRequest))
        case .permissions:
            if let approvalResult = Self.repoPromptPermissionsAutoApprovalResult(params: params) {
                await respondToServerRequest(id: request.id, result: approvalResult)
                return
            }
            guard let permissionsRequest = Self.parsePermissionsRequest(
                requestID: request.id,
                method: method,
                params: params,
                activeThreadID: threadID,
                currentTurnID: routingCurrentTurnID
            ) else {
                await emitServerRequestIssue(
                    requestID: request.id,
                    method: method,
                    kind: .permissionsRequestUnsupported,
                    code: -32602,
                    message: "Invalid item/permissions/requestApproval params."
                )
                return
            }
            await emit(.permissionsRequest(permissionsRequest))
        case .dynamicToolUnsupported:
            await emitServerRequestIssue(
                requestID: request.id,
                method: method,
                kind: .dynamicToolCallUnsupported,
                code: -32001,
                message: "Codex requested item/tool/call, but RepoPrompt does not implement dynamic client-side tool execution."
            )
        case .unknownUnsupported:
            let message = "Unsupported Codex server request method: \(method)"
            await emitServerRequestIssue(
                requestID: request.id,
                method: method,
                kind: .unsupportedMethod,
                code: -32601,
                message: message
            )
        }
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) async {
        #if DEBUG
            writeRawEventLogRecord(
                kind: "serverRequest.respond",
                payload: [
                    "requestID": id.displayValue,
                    "result": result
                ]
            )
        #endif
        do {
            try await client.respondToServerRequest(id: id, result: result)
        } catch {
            await emit(.error("Codex server request response failed: \(error.localizedDescription)"))
        }
    }

    private func buildApprovalRequest(
        id: CodexAppServerRequestID,
        method: String,
        params: [String: Any]
    ) -> AgentApprovalRequest? {
        Self.parseApprovalRequest(
            requestID: id,
            method: method,
            params: params,
            activeThreadID: threadID,
            currentTurnID: routingCurrentTurnID
        )
    }

    private func handleChatgptAuthTokensRefreshServerRequest(
        _ requestID: CodexAppServerRequestID,
        method: String,
        params: [String: Any]
    ) async {
        guard let refreshRequest = Self.parseChatgptAuthTokensRefreshRequest(requestID: requestID, params: params) else {
            await emitServerRequestIssue(
                requestID: requestID,
                method: method,
                kind: .authTokensRefreshInvalidParams,
                code: -32602,
                message: "Invalid account/chatgptAuthTokens/refresh params."
            )
            return
        }
        guard let handler = options.authTokensRefreshHandler else {
            await emitServerRequestIssue(
                requestID: requestID,
                method: method,
                kind: .authTokensRefreshUnavailable,
                code: -32001,
                message: "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt is not managing external Codex ChatGPT auth tokens. Reconnect Codex authentication and retry."
            )
            return
        }
        let response: ChatgptAuthTokensRefreshResponse
        do {
            response = try await handler(refreshRequest)
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(detail)"
            let message = "Codex requested account/chatgptAuthTokens/refresh, but RepoPrompt failed to provide refreshed ChatGPT tokens.\(suffix)"
            await emitServerRequestIssue(
                requestID: requestID,
                method: method,
                kind: .authTokensRefreshFailed,
                code: -32002,
                message: message
            )
            return
        }
        do {
            try await client.respondToServerRequest(id: requestID, result: response.payload)
        } catch {
            await emit(.error("Codex server request response failed: \(error.localizedDescription)"))
        }
    }

    private static func isRepoPromptMCPElicitationRequest(params: [String: Any]) -> Bool {
        MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: nil,
            requestPayload: params
        ) != nil
    }

    private func computerUseMCPElicitationAutoAcceptResult(params: [String: Any]) async -> [String: Any]? {
        let computerUseEnabled = await MainActor.run { options.computerUseEnabledProvider() }
        guard computerUseEnabled,
              options.approvalPolicyProvider() == .never,
              options.sandboxModeProvider() == .dangerFullAccess,
              Self.isComputerUseMCPElicitationRequest(params: params)
        else {
            return nil
        }
        return [
            "action": "accept",
            "content": [String: Any](),
            "_meta": [
                "repoPromptAutoAccepted": true,
                "reason": "explicit_computer_use_full_access"
            ]
        ]
    }

    private static func isComputerUseMCPElicitationRequest(params: [String: Any]) -> Bool {
        let serverCandidates = [
            "server",
            "serverName",
            "server_name",
            "mcpServer",
            "mcp_server",
            "mcpServerName",
            "mcp_server_name"
        ]
        guard let serverName = firstString(in: params, keys: serverCandidates)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !serverName.isEmpty
        else {
            return false
        }
        return serverName == computerUseMCPServerName
    }

    static func parseMCPElicitationRequest(
        requestID: CodexAppServerRequestID,
        method: String,
        params: [String: Any],
        activeThreadID: String?,
        currentTurnID: String?
    ) -> AgentMCPElicitationRequest? {
        guard let rawParamsJSON = encodeJSONObjectString(params) else {
            return nil
        }
        let threadID = notificationThreadID(from: params)
            ?? firstString(in: params, keys: ["threadId", "thread_id", "thread", "conversationId", "conversation_id"])
            ?? activeThreadID
            ?? "thread:\(requestID.displayValue)"
        let turnID = notificationTurnID(from: params)
            ?? firstString(in: params, keys: ["turnId", "turn_id", "turn"])
            ?? currentTurnID
            ?? "turn:\(requestID.displayValue)"
        let itemID = notificationItemID(from: params)
            ?? firstString(in: params, keys: ["itemId", "item_id", "item", "callId", "call_id", "invocationId", "invocation_id"])
            ?? "item:\(requestID.displayValue)"
        let serverName = firstString(
            in: params,
            keys: ["server", "serverName", "server_name", "mcpServer", "mcp_server", "mcpServerName", "mcp_server_name"]
        )
        let toolName = firstString(
            in: params,
            keys: ["tool", "toolName", "tool_name", "name"]
        )
        let title = firstString(in: params, keys: ["title"])
            ?? "MCP Elicitation Requested"
        let prompt = firstString(in: params, keys: ["prompt", "reason", "description"])
        let message = firstString(in: params, keys: ["message"])
        let schemaJSON = firstJSONString(
            in: params,
            keys: ["schema", "contentSchema", "content_schema", "requestedSchema", "requested_schema"]
        )
        let defaultContentJSON = firstJSONString(
            in: params,
            keys: ["defaultContent", "default_content", "content"]
        )
        let requestSeed = "mcp-elicitation|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        var details: [AgentApprovalDetail] = []
        func appendDetail(_ label: String, _ value: String?, isCode: Bool = false) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            details.append(.init(
                id: AgentApprovalDetail.stableID(
                    requestSeed: requestSeed,
                    index: details.count,
                    label: label,
                    value: value,
                    isCode: isCode
                ),
                label: label,
                value: value,
                isCode: isCode
            ))
        }
        appendDetail("Server", serverName)
        appendDetail("Tool", toolName)
        appendDetail("Prompt", prompt ?? message)
        appendDetail("Schema", schemaJSON, isCode: true)
        appendDetail("Default Content", defaultContentJSON, isCode: true)
        appendDetail("Raw Request", rawParamsJSON, isCode: true)
        return AgentMCPElicitationRequest(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            serverName: serverName,
            toolName: toolName,
            title: title,
            prompt: prompt,
            message: message,
            schemaJSON: schemaJSON,
            defaultContentJSON: defaultContentJSON,
            rawParamsJSON: rawParamsJSON,
            details: details
        )
    }

    private static func repoPromptPermissionsAutoApprovalResult(params: [String: Any]) -> [String: Any]? {
        guard MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: nil,
            requestPayload: params
        ) != nil else {
            return nil
        }

        let request = params["request"] as? [String: Any]
        let rawOptions = (params["options"] as? [[String: Any]])
            ?? (request?["options"] as? [[String: Any]])
        let options = rawOptions ?? []

        for preferredKind in ["allow_once", "allow_always"] {
            for option in options {
                guard let kind = stringScalarValue(from: option["kind"])?.lowercased(),
                      kind == preferredKind,
                      let optionID = stringScalarValue(from: option["optionId"])
                else {
                    continue
                }
                return [
                    "outcome": [
                        "outcome": "selected",
                        "optionId": optionID
                    ]
                ]
            }
        }

        if let fallbackOptionID = options.compactMap({ stringScalarValue(from: $0["optionId"]) }).first {
            return [
                "outcome": [
                    "outcome": "selected",
                    "optionId": fallbackOptionID
                ]
            ]
        }

        return [
            "action": "accept",
            "content": [String: Any](),
            "_meta": [String: Any]()
        ]
    }

    private func emitServerRequestIssue(
        requestID: CodexAppServerRequestID,
        method: String,
        kind: ServerRequestIssue.Kind,
        code: Int,
        message: String
    ) async {
        do {
            try await client.respondToServerRequestError(
                id: requestID,
                code: code,
                message: message
            )
        } catch {
            await emit(.error("Codex server request response failed: \(error.localizedDescription)"))
            return
        }
        await emit(.serverRequestIssue(.init(requestID: requestID, method: method, kind: kind, message: message)))
    }

    private static func classifyServerRequestMethod(_ method: String) -> ServerRequestRouting {
        switch method {
        case "item/tool/requestUserInput":
            .requestUserInput
        case "account/chatgptAuthTokens/refresh":
            .authTokensRefresh
        case "mcpServer/elicitation/request":
            .mcpElicitation
        case "item/permissions/requestApproval":
            .permissions
        case "item/tool/call":
            .dynamicToolUnsupported
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "applyPatchApproval",
             "execCommandApproval":
            .approval
        default:
            method.lowercased().contains("requestapproval") ? .approval : .unknownUnsupported
        }
    }

    static func parseChatgptAuthTokensRefreshRequest(
        requestID: CodexAppServerRequestID,
        params: [String: Any]
    ) -> ChatgptAuthTokensRefreshRequest? {
        guard let reasonRaw = firstString(in: params, keys: ["reason"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            reasonRaw == "unauthorized"
        else {
            return nil
        }
        return ChatgptAuthTokensRefreshRequest(
            requestID: requestID,
            reason: .unauthorized,
            previousAccountID: firstString(in: params, keys: ["previousAccountId", "previous_account_id"])
        )
    }

    static func parseRequestUserInputRequest(
        requestID: CodexAppServerRequestID,
        method: String,
        params: [String: Any],
        activeThreadID: String?,
        currentTurnID: String?
    ) -> AgentRequestUserInputRequest? {
        let explicitThreadID = notificationThreadID(from: params)
            ?? firstString(in: params, keys: ["thread"])
        if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
            return nil
        }
        guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
            return nil
        }
        guard let turnID = notificationTurnID(from: params) ?? currentTurnID,
              !turnID.isEmpty,
              let itemID = notificationItemID(from: params),
              !itemID.isEmpty,
              let rawQuestions = params["questions"] as? [Any],
              !rawQuestions.isEmpty
        else {
            return nil
        }

        var parsedQuestions: [AgentRequestUserInputQuestion] = []
        var seenQuestionIDs = Set<String>()
        for rawQuestion in rawQuestions {
            guard let question = rawQuestion as? [String: Any] else {
                return nil
            }
            guard let questionID = firstString(in: question, keys: ["id"]),
                  !questionID.isEmpty,
                  let header = firstString(in: question, keys: ["header"]),
                  !header.isEmpty,
                  let questionText = firstString(in: question, keys: ["question"]),
                  !questionText.isEmpty,
                  !seenQuestionIDs.contains(questionID)
            else {
                return nil
            }
            seenQuestionIDs.insert(questionID)

            let rawOptions = question["options"] as? [Any] ?? []
            var options: [AgentRequestUserInputOption] = []
            for rawOption in rawOptions {
                guard let option = rawOption as? [String: Any],
                      let label = firstString(in: option, keys: ["label"]),
                      !label.isEmpty,
                      let description = firstString(in: option, keys: ["description"]),
                      !description.isEmpty
                else {
                    return nil
                }
                options.append(.init(label: label, description: description))
            }

            parsedQuestions.append(
                .init(
                    id: questionID,
                    header: header,
                    question: questionText,
                    isOther: boolScalarValue(from: question["isOther"]) ?? boolScalarValue(from: question["is_other"]) ?? false,
                    isSecret: boolScalarValue(from: question["isSecret"]) ?? boolScalarValue(from: question["is_secret"]) ?? false,
                    options: options
                )
            )
        }

        return AgentRequestUserInputRequest(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            questions: parsedQuestions
        )
    }

    static func parsePermissionsRequest(
        requestID: CodexAppServerRequestID,
        method: String,
        params: [String: Any],
        activeThreadID: String?,
        currentTurnID: String?
    ) -> AgentPermissionsRequest? {
        let explicitThreadID = notificationThreadID(from: params)
            ?? firstString(in: params, keys: ["thread"])
        if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
            return nil
        }
        guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
            return nil
        }
        guard let turnID = notificationTurnID(from: params) ?? currentTurnID,
              !turnID.isEmpty,
              let itemID = notificationItemID(from: params),
              !itemID.isEmpty,
              let cwd = firstString(in: params, keys: ["cwd"]),
              !cwd.isEmpty,
              let permissionsObject = firstJSONObject(in: params, keys: ["permissions"]),
              !permissionsObject.isEmpty,
              let permissionsJSON = encodeJSONObjectString(permissionsObject)
        else {
            return nil
        }

        let reason = firstString(in: params, keys: ["reason"])
        let permissionsID = AgentPermissionsRequest.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        let detailSeed = permissionsID.uuidString
        var details: [AgentApprovalDetail] = []
        var detailIndex = 0
        func appendDetail(label: String, value: String, isCode: Bool = false) {
            details.append(
                AgentApprovalDetail(
                    id: AgentApprovalDetail.stableID(
                        requestSeed: detailSeed,
                        index: detailIndex,
                        label: label,
                        value: value,
                        isCode: isCode
                    ),
                    label: label,
                    value: value,
                    isCode: isCode
                )
            )
            detailIndex += 1
        }
        appendDetail(label: "Approval Type", value: "permissions")
        appendDetail(label: "Working Directory", value: cwd, isCode: true)
        if let reason, !reason.isEmpty {
            appendDetail(label: "Reason", value: reason)
        }
        appendDetail(label: "Requested Permissions", value: permissionsJSON, isCode: true)

        return AgentPermissionsRequest(
            id: permissionsID,
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            cwd: cwd,
            reason: reason,
            permissionsJSON: permissionsJSON,
            details: details
        )
    }

    static func parseApprovalRequest(
        requestID: CodexAppServerRequestID,
        method: String,
        params: [String: Any],
        activeThreadID: String?,
        currentTurnID: String?
    ) -> AgentApprovalRequest? {
        let explicitThreadID = notificationThreadID(from: params)
            ?? firstString(in: params, keys: ["thread"])
        if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
            return nil
        }
        guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
            return nil
        }

        let explicitTurnID = notificationTurnID(from: params)
        let turnID =
            explicitTurnID
                ?? currentTurnID
                ?? "turn:\(requestID.displayValue)"
        let itemID =
            notificationItemID(from: params)
                ?? "item:\(requestID.displayValue)"
        let stableTurnID = explicitTurnID ?? "turn:\(requestID.displayValue)"

        let reason = firstString(in: params, keys: ["reason", "message", "prompt", "description"])
        let command = firstString(
            in: params,
            keys: ["command", "cmd", "rawCommand", "raw_command", "shellCommand", "shell_command"]
        )
            ?? firstString(
                in: params,
                keys: ["argv", "args", "exec", "script"]
            )
        let cwd = firstString(
            in: params,
            keys: ["cwd", "workingDirectory", "working_directory", "workdir", "directory"]
        )
        let grantRoot = firstString(in: params, keys: ["grantRoot", "grant_root"])
        let proposedExecpolicyAmendmentJSON = firstJSONString(
            in: params,
            keys: ["proposedExecpolicyAmendment", "proposed_execpolicy_amendment", "execpolicyAmendment", "execpolicy_amendment"]
        )
        let commandActionsJSON = firstJSONString(
            in: params,
            keys: ["commandActions", "command_actions", "actions"]
        )

        let methodNormalized = normalizeApprovalKey(method)
        let kind: AgentApprovalKind = {
            if methodNormalized.contains("filechange") || methodNormalized.contains("file_change") {
                return .fileChange
            }
            if methodNormalized.contains("commandexecution") || methodNormalized.contains("command") {
                return .commandExecution
            }
            if command?.isEmpty == false {
                return .commandExecution
            }
            return .fileChange
        }()

        let approvalID = AgentApprovalRequest.stableID(
            requestID: .codex(requestID),
            method: method,
            kind: kind,
            threadID: threadID,
            turnID: stableTurnID,
            itemID: itemID
        )
        let detailSeed = approvalID.uuidString
        var details: [AgentApprovalDetail] = []
        var detailIndex = 0
        func appendDetail(label: String, value: String, isCode: Bool = false) {
            details.append(
                AgentApprovalDetail(
                    id: AgentApprovalDetail.stableID(
                        requestSeed: detailSeed,
                        index: detailIndex,
                        label: label,
                        value: value,
                        isCode: isCode
                    ),
                    label: label,
                    value: value,
                    isCode: isCode
                )
            )
            detailIndex += 1
        }
        if let reason, !reason.isEmpty {
            appendDetail(label: "Reason", value: reason)
        }
        if let command, !command.isEmpty {
            appendDetail(label: "Command", value: command, isCode: true)
        }
        if let cwd, !cwd.isEmpty {
            appendDetail(label: "Working Directory", value: cwd, isCode: true)
        }
        if let grantRoot, !grantRoot.isEmpty {
            appendDetail(label: "Grant Root", value: grantRoot, isCode: true)
        }
        if let commandActionsJSON, !commandActionsJSON.isEmpty {
            appendDetail(label: "Command Actions", value: commandActionsJSON, isCode: true)
        }
        if let proposedExecpolicyAmendmentJSON, !proposedExecpolicyAmendmentJSON.isEmpty {
            appendDetail(label: "Execpolicy Amendment", value: proposedExecpolicyAmendmentJSON, isCode: true)
        }
        if details.isEmpty {
            appendDetail(label: "Method", value: method, isCode: true)
        }

        return AgentApprovalRequest(
            id: approvalID,
            requestID: .codex(requestID),
            method: method,
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: reason,
            command: command,
            cwd: cwd,
            grantRoot: grantRoot,
            proposedExecpolicyAmendmentJSON: proposedExecpolicyAmendmentJSON,
            details: details
        )
    }

    private static func firstString(in value: Any, keys: [String]) -> String? {
        let normalized = Set(keys.map { normalizeApprovalKey($0) })
        return firstString(in: value, normalizedKeys: normalized)
    }

    private static func firstString(in value: Any, normalizedKeys: Set<String>) -> String? {
        switch value {
        case let array as [Any]:
            for element in array {
                if let match = firstString(in: element, normalizedKeys: normalizedKeys) {
                    return match
                }
            }
            return nil
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                if normalizedKeys.contains(normalizeApprovalKey(key)),
                   let match = stringScalarValue(from: child)
                {
                    return match
                }
            }
            for child in dictionary.values {
                guard (child as? [String: Any]) != nil || (child as? [Any]) != nil else { continue }
                if let match = firstString(in: child, normalizedKeys: normalizedKeys) {
                    return match
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func stringScalarValue(from value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [String], !array.isEmpty {
            let joined = array.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func boolScalarValue(from value: Any?) -> Bool? {
        guard let value else {
            return nil
        }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func firstJSONObject(in value: Any, keys: [String]) -> [String: Any]? {
        let normalized = Set(keys.map { normalizeApprovalKey($0) })
        return firstJSONObject(in: value, normalizedKeys: normalized)
    }

    private static func firstJSONObject(in value: Any, normalizedKeys: Set<String>) -> [String: Any]? {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                guard normalizedKeys.contains(normalizeApprovalKey(key)) else { continue }
                if let object = child as? [String: Any], JSONSerialization.isValidJSONObject(object) {
                    return object
                }
            }
            for child in dictionary.values {
                if let nested = firstJSONObject(in: child, normalizedKeys: normalizedKeys) {
                    return nested
                }
            }
            return nil
        case let array as [Any]:
            for element in array {
                if let nested = firstJSONObject(in: element, normalizedKeys: normalizedKeys) {
                    return nested
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func firstJSONString(in value: Any, keys: [String]) -> String? {
        let normalized = Set(keys.map { normalizeApprovalKey($0) })
        return firstJSONString(in: value, normalizedKeys: normalized)
    }

    private static func firstJSONString(in value: Any, normalizedKeys: Set<String>) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                guard normalizedKeys.contains(normalizeApprovalKey(key)) else { continue }
                if let string = child as? String, !string.isEmpty {
                    return string
                }
                if let json = encodeJSONObjectString(child) {
                    return json
                }
            }
            for child in dictionary.values {
                if let nested = firstJSONString(in: child, normalizedKeys: normalizedKeys) {
                    return nested
                }
            }
            return nil
        case let array as [Any]:
            for element in array {
                if let nested = firstJSONString(in: element, normalizedKeys: normalizedKeys) {
                    return nested
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func encodeJSONObjectString(_ value: Any) -> String? {
        JSONDictionaryHelpers.prettyJSONString(from: value, sortedKeys: false)
    }

    private static func normalizeApprovalKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func parseTokenUsage(from params: [String: Any]) -> AgentContextUsage? {
        Self.parseTokenUsagePayload(from: params)
    }

    private static func parseTokenUsagePayload(from params: [String: Any]) -> AgentContextUsage? {
        let tokenUsage = tokenUsageObject(from: params)
        guard let tokenUsage else { return nil }

        let last = usageBreakdown(
            in: tokenUsage,
            keys: ["last", "lastTokenUsage", "last_token_usage"]
        )
        let total = usageBreakdown(
            in: tokenUsage,
            keys: ["total", "totalTokenUsage", "total_token_usage"]
        )
        let lastTotal = usageTotalTokens(from: last)
        let totalTotal = usageTotalTokens(from: total)
        let contextWindow =
            intValue(tokenUsage["modelContextWindow"])
                ?? intValue(tokenUsage["model_context_window"])
                ?? intValue(tokenUsage["contextWindow"])
                ?? intValue(tokenUsage["context_window"])

        guard contextWindow != nil || lastTotal != nil || totalTotal != nil else {
            return nil
        }
        return AgentContextUsage(
            modelContextWindow: contextWindow,
            lastTotalTokens: lastTotal,
            totalTotalTokens: totalTotal
        )
    }

    private static func tokenUsageObject(from params: [String: Any]) -> [String: Any]? {
        if let tokenUsage = params["tokenUsage"] as? [String: Any] {
            return tokenUsage
        }
        if let tokenUsage = params["token_usage"] as? [String: Any] {
            return tokenUsage
        }
        let hasTokenUsageShape =
            params["last"] != nil
                || params["total"] != nil
                || params["lastTokenUsage"] != nil
                || params["last_token_usage"] != nil
                || params["totalTokenUsage"] != nil
                || params["total_token_usage"] != nil
                || params["modelContextWindow"] != nil
                || params["model_context_window"] != nil
        return hasTokenUsageShape ? params : nil
    }

    private static func usageBreakdown(
        in tokenUsage: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let value = tokenUsage[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private static func usageTotalTokens(from usage: [String: Any]?) -> Int? {
        guard let usage else { return nil }

        if let explicit =
            intValue(usage["totalTokens"])
                ?? intValue(usage["total_tokens"])
                ?? intValue(usage["tokenCount"])
                ?? intValue(usage["token_count"])
        {
            return explicit
        }

        let input = intValue(usage["inputTokens"]) ?? intValue(usage["input_tokens"])
        let cachedInput = intValue(usage["cachedInputTokens"]) ?? intValue(usage["cached_input_tokens"])
        let output = intValue(usage["outputTokens"]) ?? intValue(usage["output_tokens"])
        let reasoningOutput =
            intValue(usage["reasoningOutputTokens"])
                ?? intValue(usage["reasoning_output_tokens"])

        if input == nil, cachedInput == nil, output == nil, reasoningOutput == nil {
            return nil
        }
        return (input ?? 0) + (cachedInput ?? 0) + (output ?? 0) + (reasoningOutput ?? 0)
    }

    private func decodeParams(_ params: [String: CodexJSONValue]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in params {
            output[key] = value.toAny()
        }
        return output
    }

    private func makeReasoningGroupID(kind: String, itemID: String?, index: Int?) -> String? {
        guard let itemID else { return nil }
        if let index {
            return "\(kind):\(itemID):\(index)"
        }
        return "\(kind):\(itemID)"
    }

    private func intValue(_ value: Any?) -> Int? {
        Self.intValue(value)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as Int64:
            return Int(number)
        case let number as UInt:
            return Int(number)
        case let number as UInt64:
            return Int(number)
        case let number as Double:
            return intValueFromFloatingPoint(number)
        case let number as Float:
            return intValueFromFloatingPoint(Double(number))
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let asInt = Int(trimmed) {
                return asInt
            }
            if let asDouble = Double(trimmed) {
                return intValueFromFloatingPoint(asDouble)
            }
            return nil
        default:
            return nil
        }
    }

    private static func intValueFromFloatingPoint(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        guard value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int:
            return Int64(number)
        case let number as Int64:
            return number
        case let number as UInt:
            guard number <= UInt(Int64.max) else { return nil }
            return Int64(number)
        case let number as UInt64:
            guard number <= UInt64(Int64.max) else { return nil }
            return Int64(number)
        case let number as Double:
            return int64ValueFromFloatingPoint(number)
        case let number as Float:
            return int64ValueFromFloatingPoint(Double(number))
        case let number as NSNumber:
            return number.int64Value
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let asInt64 = Int64(trimmed) {
                return asInt64
            }
            if let asDouble = Double(trimmed) {
                return int64ValueFromFloatingPoint(asDouble)
            }
            return nil
        default:
            return nil
        }
    }

    private static func int64ValueFromFloatingPoint(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        guard value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
        return Int64(value)
    }

    private func mapTurnStatus(_ raw: String) -> TurnStatus {
        switch raw.lowercased() {
        case "completed":
            .completed
        case "interrupted":
            .interrupted
        case "failed":
            .failed
        default:
            .completed
        }
    }

    private func emit(_ event: Event) async {
        Self.logCodexDebug("[CodexNativeController] emit \(Self.debugEventSummary(event))")
        #if DEBUG
            writeRawEventLogRecord(
                kind: "event.emit",
                payload: ["summary": Self.debugEventSummary(event)]
            )
        #endif
        currentEventsContinuation()?.yield(event)
    }

    private static func debugPreview(_ value: String?, maxLength: Int = 180) -> String {
        guard let value else { return "nil" }
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= maxLength {
            return normalized
        }
        let prefix = normalized.prefix(maxLength)
        return "\(prefix)…[\(normalized.count) chars]"
    }

    private static func debugEventSummary(_ event: Event) -> String {
        switch event {
        case let .assistantDelta(delta):
            "assistantDelta chars=\(delta.count)"
        case let .reasoningDelta(payload):
            "reasoningDelta kind=\(payload.kind) chars=\(payload.text.count) itemID=\(payload.itemID ?? "nil") groupID=\(payload.groupID ?? "nil")"
        case let .toolCall(name, invocationID, _):
            "toolCall tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil")"
        case let .toolResult(name, invocationID, _, resultJSON, isError):
            "toolResult tool=\(name) invocationID=\(invocationID?.uuidString ?? "nil") isError=\(isError.map(String.init(describing:)) ?? "nil") resultChars=\(resultJSON.count)"
        case let .commandExecutionRunning(update):
            "commandExecutionRunning invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)"
        case let .approvalRequest(request):
            "approvalRequest kind=\(request.kind)"
        case .permissionsRequest:
            "permissionsRequest"
        case let .requestUserInput(request):
            "requestUserInput questions=\(request.questions.count)"
        case let .mcpElicitationRequest(request):
            "mcpElicitationRequest server=\(request.serverName ?? "nil")"
        case let .serverRequestIssue(issue):
            "serverRequestIssue kind=\(issue.kind.rawValue) method=\(issue.method)"
        case let .turnStarted(turnID):
            "turnStarted turnID=\(turnID ?? "nil")"
        case let .turnCompleted(turnID, status):
            "turnCompleted turnID=\(turnID ?? "nil") status=\(status)"
        case let .contextCompacted(turnID):
            "contextCompacted turnID=\(turnID ?? "nil")"
        case let .tokenUsage(usage):
            "tokenUsage modelContextWindow=\(usage.modelContextWindow.map(String.init(describing:)) ?? "nil") lastTotalTokens=\(usage.lastTotalTokens.map(String.init(describing:)) ?? "nil") totalTotalTokens=\(usage.totalTotalTokens.map(String.init(describing:)) ?? "nil")"
        case let .livenessActivity(activity):
            "livenessActivity kind=\(activity.kind.rawValue) method=\(activity.method) threadID=\(activity.threadID ?? "nil") turnID=\(activity.turnID ?? "nil") itemID=\(activity.itemID ?? "nil")"
        case let .errorNotification(notification):
            "errorNotification willRetry=\(notification.willRetry.map(String.init(describing:)) ?? "nil") message=\(debugPreview(notification.message))"
        case let .error(message):
            "error \(debugPreview(message))"
        case let .system(message):
            "system \(debugPreview(message))"
        }
    }

    private enum ToolLifecycleEvent {
        case call(name: String, invocationID: UUID?, argsJSON: String?, dedupKey: String)
        case result(name: String, invocationID: UUID?, argsJSON: String?, resultJSON: String, isError: Bool?, dedupKey: String)
    }

    private struct ExecCommandBeginEvent {
        let invocationID: UUID?
        let argsJSON: String?
        let processID: String?
        let dedupKey: String
    }

    private struct ExecCommandEndEvent {
        let invocationID: UUID?
        let argsJSON: String?
        let resultJSON: String
        let isError: Bool?
        let processID: String?
        let dedupKey: String
    }

    struct CommandExecutionRunningItemIndex {
        var indexByInvocationID: [UUID: Int] = [:]
        var indexByProcessID: [String: Int] = [:]
        var lastBashIndex: Int?

        init(items: [AgentChatItem]) {
            rebuild(from: items)
        }

        mutating func rebuild(from items: [AgentChatItem]) {
            indexByInvocationID.removeAll(keepingCapacity: true)
            indexByProcessID.removeAll(keepingCapacity: true)
            lastBashIndex = nil
            for index in items.indices {
                let item = items[index]
                guard CodexNativeSessionController.normalizedExternalToolName(item.toolName) == "bash" else { continue }
                if let invocationID = item.toolInvocationID {
                    indexByInvocationID[invocationID] = index
                }
                if let processID = CodexNativeSessionController.commandExecutionProcessID(from: item.toolResultJSON) {
                    indexByProcessID[processID] = index
                }
                lastBashIndex = index
            }
        }

        mutating func applyMutation(
            oldItem: AgentChatItem,
            newItem: AgentChatItem,
            at index: Int
        ) {
            if let oldInvocationID = oldItem.toolInvocationID, indexByInvocationID[oldInvocationID] == index {
                indexByInvocationID.removeValue(forKey: oldInvocationID)
            }
            if let oldProcessID = CodexNativeSessionController.commandExecutionProcessID(from: oldItem.toolResultJSON),
               indexByProcessID[oldProcessID] == index
            {
                indexByProcessID.removeValue(forKey: oldProcessID)
            }

            guard CodexNativeSessionController.normalizedExternalToolName(newItem.toolName) == "bash" else {
                if lastBashIndex == index {
                    lastBashIndex = nil
                }
                return
            }
            if let invocationID = newItem.toolInvocationID {
                indexByInvocationID[invocationID] = index
            }
            if let processID = CodexNativeSessionController.commandExecutionProcessID(from: newItem.toolResultJSON) {
                indexByProcessID[processID] = index
            }
            if let lastBashIndex {
                if index > lastBashIndex {
                    self.lastBashIndex = index
                }
            } else {
                lastBashIndex = index
            }
        }
    }

    private struct PersistedCommandSignals {
        var runningProcessIDs: Set<String> = []
        var runningCallIDs: Set<String> = []
        var terminalProcessIDs: Set<String> = []
        var terminalCallIDs: Set<String> = []
        var outputByProcessID: [String: String] = [:]
        var outputByCallID: [String: String] = [:]
    }

    static func commandExecutionRunningUpdate(
        fromToolName toolName: String,
        argsJSON: String?,
        resultJSON: String?,
        isError: Bool?
    ) -> CommandExecutionRunningUpdate? {
        let normalizedToolName = normalizedExternalToolName(toolName)
        if normalizedToolName == "write_stdin" {
            guard let sessionID = writeStdinSessionID(from: argsJSON) else { return nil }
            guard writeStdinResultIndicatesRunning(resultJSON: resultJSON, isError: isError) else { return nil }
            return CommandExecutionRunningUpdate(
                invocationID: nil,
                processID: "session:\(sessionID)",
                appendedOutput: nil,
                sealsAssistantBoundary: writeStdinIsPoll(argsJSON: argsJSON)
            )
        }

        guard normalizedToolName == "bash" else { return nil }
        if commandExecutionResultIndicatesRunning(raw: resultJSON) {
            let processID = commandExecutionProcessID(from: resultJSON)
            let appendedOutput = commandExecutionOutputText(from: resultJSON)
            if processID != nil || appendedOutput?.isEmpty == false {
                return CommandExecutionRunningUpdate(
                    invocationID: nil,
                    processID: processID,
                    appendedOutput: appendedOutput
                )
            }
        }

        guard let resultJSON, let parsed = parseExecCommandRunningOutput(raw: resultJSON) else { return nil }
        return CommandExecutionRunningUpdate(
            invocationID: nil,
            processID: parsed.processID,
            appendedOutput: parsed.output
        )
    }

    static func applyCommandExecutionRunningUpdate(
        _ update: CommandExecutionRunningUpdate,
        to items: inout [AgentChatItem]
    ) -> Bool {
        var index: CommandExecutionRunningItemIndex? = nil
        return applyCommandExecutionRunningUpdate(update, to: &items, index: &index)
    }

    static func applyCommandExecutionRunningUpdates(
        _ updates: [CommandExecutionRunningUpdate],
        to items: inout [AgentChatItem]
    ) -> Int {
        guard !updates.isEmpty else { return 0 }
        var index: CommandExecutionRunningItemIndex? = nil
        var appliedCount = 0
        for update in updates {
            if applyCommandExecutionRunningUpdate(update, to: &items, index: &index) {
                appliedCount &+= 1
            }
        }
        return appliedCount
    }

    static func applyCommandExecutionRunningUpdate(
        _ update: CommandExecutionRunningUpdate,
        to items: inout [AgentChatItem],
        index: inout CommandExecutionRunningItemIndex?
    ) -> Bool {
        if index == nil {
            index = CommandExecutionRunningItemIndex(items: items)
        }
        let target = commandExecutionRunningTarget(update: update, items: items, index: &index)

        guard let target else {
            logCodexDebug("[CodexNativeController] runningUpdateMiss invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0) bashCount=\(items.count(where: { normalizedExternalToolName($0.toolName) == "bash" }))")
            return false
        }
        let targetIndex = target.index
        let oldItem = items[targetIndex]
        var item = oldItem
        var didChange = false

        if item.toolIsError != true,
           commandExecutionResultIndicatesTerminal(raw: item.toolResultJSON)
        {
            logCodexDebug("[CodexNativeController] runningUpdateIgnored reason=terminal targetIndex=\(targetIndex) match=\(target.reason) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil")")
            return false
        }

        if item.kind == .toolCall {
            item.kind = .toolResult
            didChange = true
        }
        if item.toolIsError != false {
            item.toolIsError = false
            didChange = true
        }

        if shouldPatchCommandExecutionRunningPayload(
            raw: item.toolResultJSON,
            processID: update.processID,
            appendOutput: update.appendedOutput
        ) {
            let patched = withCommandExecutionRunningStatus(
                raw: item.toolResultJSON,
                processID: update.processID,
                appendOutput: update.appendedOutput
            )
            if patched != item.toolResultJSON {
                item.toolResultJSON = patched
                didChange = true
            }
        }

        guard didChange else { return false }
        items[targetIndex] = item
        index?.applyMutation(oldItem: oldItem, newItem: item, at: targetIndex)
        logCodexDebug("[CodexNativeController] runningUpdateApplied match=\(target.reason) targetIndex=\(targetIndex) invocationID=\(update.invocationID?.uuidString ?? "nil") processID=\(update.processID ?? "nil") outputChars=\(update.appendedOutput?.count ?? 0)")
        return true
    }

    static func matchingBashToolResultIndex(
        in items: [AgentChatItem],
        toolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        resultJSON: String
    ) -> Int? {
        guard normalizedExternalToolName(toolName) == "bash" else { return nil }

        var metadataCacheByItemID: [UUID: BashToolResultParser.Metadata] = [:]
        func metadata(_ item: AgentChatItem) -> BashToolResultParser.Metadata {
            if let cached = metadataCacheByItemID[item.id] {
                return cached
            }
            let parsed = BashToolResultParser.parseMetadata(raw: item.toolResultJSON)
            metadataCacheByItemID[item.id] = parsed
            return parsed
        }

        var parseCacheByItemID: [UUID: BashToolResultParser.ParsedResult] = [:]
        func parsed(_ item: AgentChatItem) -> BashToolResultParser.ParsedResult {
            if let cached = parseCacheByItemID[item.id] {
                return cached
            }
            let parsed = BashToolResultParser.parse(raw: item.toolResultJSON, argsJSON: item.toolArgsJSON)
            parseCacheByItemID[item.id] = parsed
            return parsed
        }

        func isRunningBash(_ item: AgentChatItem) -> Bool {
            guard item.kind == .toolResult else { return false }
            guard normalizedExternalToolName(item.toolName) == "bash" else { return false }
            return metadata(item).isRunning
        }

        if let invocationID,
           let index = items.lastIndex(where: {
               $0.toolInvocationID == invocationID && isRunningBash($0)
           })
        {
            return index
        }

        let incomingMetadata = BashToolResultParser.parseMetadata(raw: resultJSON)
        let incomingProcessID = incomingMetadata.processID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingArgs = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        var incomingParsedResult: BashToolResultParser.ParsedResult?
        func incomingCommand() -> String? {
            if incomingParsedResult == nil {
                incomingParsedResult = BashToolResultParser.parse(raw: resultJSON, argsJSON: argsJSON)
            }
            let command = incomingParsedResult?.command?.trimmingCharacters(in: .whitespacesAndNewlines)
            return command?.isEmpty == false ? command : nil
        }

        if let incomingProcessID, !incomingProcessID.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingProcessID = metadata(item).processID?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingProcessID == incomingProcessID
           })
        {
            return index
        }

        if let incomingArgs, !incomingArgs.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingArgs = item.toolArgsJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingArgs == incomingArgs
           })
        {
            return index
        }

        if let incomingCommand = incomingCommand(), !incomingCommand.isEmpty,
           let index = items.lastIndex(where: { item in
               guard isRunningBash(item) else { return false }
               let existingCommand = parsed(item).command?.trimmingCharacters(in: .whitespacesAndNewlines)
               return existingCommand == incomingCommand
           })
        {
            return index
        }

        let runningBashIndexes = items.indices.filter { isRunningBash(items[$0]) }
        if runningBashIndexes.count == 1 {
            return runningBashIndexes[0]
        }
        return nil
    }

    private static func commandExecutionRunningTarget(
        update: CommandExecutionRunningUpdate,
        items: [AgentChatItem],
        index: inout CommandExecutionRunningItemIndex?
    ) -> (index: Int, reason: String)? {
        if let invocationID = update.invocationID,
           let byInvocation = index?.indexByInvocationID[invocationID],
           isBashItem(at: byInvocation, in: items)
        {
            return (byInvocation, "invocation-index")
        }
        if let processID = update.processID,
           let byProcess = index?.indexByProcessID[processID],
           isBashItem(at: byProcess, in: items)
        {
            return (byProcess, "process-index")
        }
        let fallbackRequiresCorrelation = update.invocationID != nil || (update.processID?.isEmpty == false)
        if let uniqueFallback = uniqueFallbackEligibleBashIndex(
            in: items,
            requireCorrelationForErroredItem: fallbackRequiresCorrelation
        ) {
            return (uniqueFallback, "single-bash-index")
        }

        let scannedTarget: (index: Int, reason: String)? = {
            if let invocationID = update.invocationID,
               let byInvocation = items.lastIndex(where: {
                   $0.toolInvocationID == invocationID && normalizedExternalToolName($0.toolName) == "bash"
               })
            {
                return (byInvocation, "invocation-scan")
            }
            if let processID = update.processID,
               let byProcess = items.lastIndex(where: { item in
                   normalizedExternalToolName(item.toolName) == "bash"
                       && commandExecutionProcessID(from: item.toolResultJSON) == processID
               })
            {
                return (byProcess, "process-scan")
            }
            if let uniqueFallback = uniqueFallbackEligibleBashIndex(
                in: items,
                requireCorrelationForErroredItem: fallbackRequiresCorrelation
            ) {
                return (uniqueFallback, "single-bash-scan")
            }
            return nil
        }()
        if scannedTarget != nil {
            index = CommandExecutionRunningItemIndex(items: items)
        }
        return scannedTarget
    }

    private static func isBashItem(at index: Int, in items: [AgentChatItem]) -> Bool {
        guard items.indices.contains(index) else { return false }
        return normalizedExternalToolName(items[index].toolName) == "bash"
    }

    private static func isFallbackEligibleBashItem(
        at index: Int,
        in items: [AgentChatItem],
        requireCorrelationForErroredItem: Bool
    ) -> Bool {
        guard isBashItem(at: index, in: items) else { return false }
        let item = items[index]
        if item.toolIsError == true {
            return requireCorrelationForErroredItem
        }
        return !commandExecutionResultIndicatesTerminal(raw: item.toolResultJSON)
    }

    private static func uniqueFallbackEligibleBashIndex(
        in items: [AgentChatItem],
        requireCorrelationForErroredItem: Bool
    ) -> Int? {
        var resolvedIndex: Int?
        for index in items.indices where isFallbackEligibleBashItem(
            at: index,
            in: items,
            requireCorrelationForErroredItem: requireCorrelationForErroredItem
        ) {
            if resolvedIndex != nil {
                return nil
            }
            resolvedIndex = index
        }
        return resolvedIndex
    }

    static func reconcilePersistedCommandExecutionStatuses(
        in items: inout [AgentChatItem],
        rolloutPath: String
    ) -> Bool {
        let trimmedPath = rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        let candidateIndices = items.indices.filter { index in
            let item = items[index]
            guard item.kind == .toolResult else { return false }
            guard normalizedExternalToolName(item.toolName) == "bash" else { return false }
            let processID = commandExecutionProcessID(from: item.toolResultJSON)
            let callID = commandExecutionCallID(from: item.toolResultJSON)
            guard processID != nil || callID != nil else {
                return false
            }
            let processIDLooksSessionScoped = processID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("session:") == true
            guard item.toolIsError == true || processIDLooksSessionScoped else {
                return false
            }
            if item.toolIsError == true {
                return true
            }
            return !commandExecutionResultIndicatesRunning(raw: item.toolResultJSON)
        }
        guard !candidateIndices.isEmpty else { return false }

        let signals = loadPersistedCommandSignals(fromRolloutPath: trimmedPath)
        guard !signals.runningProcessIDs.isEmpty
            || !signals.runningCallIDs.isEmpty
        else { return false }

        var didChange = false
        for index in candidateIndices {
            var item = items[index]
            let processID = commandExecutionProcessID(from: item.toolResultJSON)
            let processSignalKeys = canonicalCommandProcessIDs(for: processID)
            let callID = commandExecutionCallID(from: item.toolResultJSON)
            let recoveredOutput =
                (callID.flatMap { signals.outputByCallID[$0] })
                    ?? processSignalKeys.lazy.compactMap { signals.outputByProcessID[$0] }.first
            let hasTerminalSignal =
                processSignalKeys.contains(where: { signals.terminalProcessIDs.contains($0) })
                    || (callID.map { signals.terminalCallIDs.contains($0) } ?? false)
            guard !hasTerminalSignal else { continue }

            let shouldPatch =
                processSignalKeys.contains(where: { signals.runningProcessIDs.contains($0) })
                    || (callID.map { signals.runningCallIDs.contains($0) } ?? false)
            guard shouldPatch else { continue }

            if item.toolIsError != false {
                item.toolIsError = false
                didChange = true
            }
            let patched = withCommandExecutionRunningStatus(
                raw: item.toolResultJSON,
                processID: processID,
                appendOutput: recoveredOutput
            )
            if patched != item.toolResultJSON {
                item.toolResultJSON = patched
                didChange = true
            }
            items[index] = item
        }
        return didChange
    }

    private static func isItemLifecycleNotificationMethod(_ method: String) -> Bool {
        let lowerMethod = method.lowercased()
        return isItemLifecycleStartedMethod(lowerMethod) || isItemLifecycleCompletedMethod(lowerMethod)
    }

    private static func isItemLifecycleStartedMethod(_ lowerMethod: String) -> Bool {
        guard lowerMethod.contains("item/") || lowerMethod.contains("item_") else { return false }
        return lowerMethod.hasSuffix("/started") || lowerMethod.hasSuffix("_started")
    }

    private static func isItemLifecycleCompletedMethod(_ lowerMethod: String) -> Bool {
        guard !isRawResponseItemCompletedMethod(lowerMethod) else { return false }
        guard lowerMethod.contains("item/") || lowerMethod.contains("item_") else { return false }
        return lowerMethod.hasSuffix("/completed") || lowerMethod.hasSuffix("_completed")
    }

    private static func isRawResponseItemCompletedMethod(_ lowerMethod: String) -> Bool {
        lowerMethod == "rawresponseitem/completed"
    }

    private static let minimalCompletedCommandExecutionResultJSON = #"{"type":"commandExecution","status":"completed"}"#

    private static func withCommandExecutionCompletedStatus(raw: String?) -> String {
        withCommandExecutionTerminalCompletionStatus(raw: raw, status: "completed")
    }

    private static func withCommandExecutionTerminalCompletionStatus(raw: String?, status: String) -> String {
        let normalizedStatus = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallbackStatus = normalizedStatus.isEmpty ? "completed" : normalizedStatus
        guard var object = jsonObject(from: raw) else {
            return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
        }
        if object.isEmpty {
            return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
        }
        if dictString(object, key: "type")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            object["type"] = "commandExecution"
        }
        object["status"] = fallbackStatus
        if object["processId"] == nil, let legacy = object["process_id"] {
            object["processId"] = legacy
        }
        object.removeValue(forKey: "process_id")

        let resolvedExitCode =
            dictInt(object, key: "exitCode")
                ?? dictInt(object, key: "exit_code")
                ?? dictInt(object, key: "code")
        if let resolvedExitCode, resolvedExitCode >= 0 {
            object["exitCode"] = resolvedExitCode
        } else {
            object.removeValue(forKey: "exitCode")
        }
        object.removeValue(forKey: "exit_code")
        object.removeValue(forKey: "code")

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
        }
        return json
    }

    private static func shouldSynthesizeTerminalCommandCompletionPayload(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        guard let object = jsonObject(from: raw) else {
            return false
        }
        return object.isEmpty
    }

    private func parseToolLifecycleEvent(method: String, params: [String: Any]) -> ToolLifecycleEvent? {
        let lowerMethod = method.lowercased()
        let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
        let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
        guard isStarted || isCompleted else { return nil }

        if let fileChangeEvent = parseFileChangeLifecycleEvent(method: method, params: params) {
            return fileChangeEvent
        }
        if hasNormalizedCommandExecutionCandidate(in: params) {
            return parseNormalizedCommandExecutionLifecycleEvent(method: method, params: params)
        }

        for candidate in toolItemCandidates(from: params) {
            guard isLikelyToolItem(candidate) else { continue }
            guard let toolName = normalizedToolName(from: candidate) else { continue }
            let typeRaw = normalizedTypeString(from: candidate)
            guard !Self.usesRawCanonicalLiveEventFamily(typeRaw: typeRaw) else { continue }
            let itemID = stringValue(from: candidate, keys: [
                "id", "itemId", "item_id", "callId", "call_id", "invocationId", "invocation_id", "toolCallId", "tool_call_id"
            ])
            let invocationID = invocationID(from: itemID)
            let argsJSON = toolArgsJSON(from: candidate, toolName: toolName)

            if isStarted {
                let dedupKey = toolDedupKey(
                    itemID: itemID,
                    toolName: toolName,
                    argsJSON: argsJSON,
                    resultJSON: nil
                )
                return .call(name: toolName, invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
            }

            let resultJSON = toolResultJSON(from: candidate, toolName: toolName)
            let isError = toolIsError(from: candidate)
            let isCommandLike = toolName == "bash"
                || typeRaw.contains("command")
                || typeRaw.contains("exec")
                || typeRaw.contains("shell")
            let completedResultJSON: String = {
                if isCommandLike {
                    let commandResultJSON = jsonString(from: candidate) ?? (resultJSON ?? "")
                    if isCompleted,
                       Self.shouldSynthesizeTerminalCommandCompletionPayload(commandResultJSON)
                    {
                        return Self.minimalCompletedCommandExecutionResultJSON
                    }
                    if isCompleted,
                       let object = Self.jsonObject(from: commandResultJSON),
                       let statusWord = Self.commandExecutionStatusWord(from: object),
                       Self.commandExecutionTerminalStatusWords.contains(statusWord)
                    {
                        return Self.withCommandExecutionTerminalCompletionStatus(
                            raw: commandResultJSON,
                            status: statusWord
                        )
                    }
                    if isCompleted,
                       !Self.commandExecutionResultIndicatesTerminal(raw: commandResultJSON)
                    {
                        return Self.withCommandExecutionCompletedStatus(raw: commandResultJSON)
                    }
                    return commandResultJSON
                }
                if let resultJSON, !resultJSON.isEmpty {
                    return resultJSON
                }
                if typeRaw.contains("result") || typeRaw.contains("output") || (isError == true) {
                    return jsonString(from: candidate) ?? ""
                }
                return jsonString(from: candidate) ?? "{}"
            }()
            let normalizedResultJSON = isCommandLike
                ? Self.sanitizedCommandExecutionResultJSON(completedResultJSON)
                : completedResultJSON
            let dedupKey = toolDedupKey(
                itemID: itemID,
                toolName: toolName,
                argsJSON: argsJSON,
                resultJSON: normalizedResultJSON
            )
            return .result(
                name: toolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: normalizedResultJSON,
                isError: isError,
                dedupKey: dedupKey
            )
        }
        return nil
    }

    private func hasNormalizedCommandExecutionCandidate(in params: [String: Any]) -> Bool {
        toolItemCandidates(from: params).contains { candidate in
            let typeRaw = normalizedTypeString(from: candidate)
            return typeRaw.contains("commandexecution") || typeRaw.contains("command_execution")
        }
    }

    private func parseNormalizedCommandExecutionLifecycleEvent(
        method: String,
        params: [String: Any]
    ) -> ToolLifecycleEvent? {
        let lowerMethod = method.lowercased()
        let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
        let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
        guard isStarted || isCompleted else { return nil }

        for candidate in toolItemCandidates(from: params) {
            let typeRaw = normalizedTypeString(from: candidate)
            guard typeRaw.contains("commandexecution") || typeRaw.contains("command_execution") else {
                continue
            }
            let itemID = stringValue(from: candidate, keys: [
                "id", "itemId", "item_id", "callId", "call_id", "invocationId", "invocation_id"
            ])
            guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .normalized) else {
                return nil
            }
            let invocationID = invocationID(from: itemID)
            let argsJSON = normalizedCommandExecutionArgsJSON(from: candidate)
            let baseDedupKey = itemID ?? toolDedupKey(
                itemID: nil,
                toolName: "bash",
                argsJSON: argsJSON,
                resultJSON: nil
            )

            if isStarted {
                return .call(
                    name: "bash",
                    invocationID: invocationID,
                    argsJSON: argsJSON,
                    dedupKey: baseDedupKey
                )
            }

            let resultJSON = normalizedCommandExecutionResultJSON(from: candidate)
            let object = Self.jsonObject(from: resultJSON) ?? [:]
            let exitCode = Self.commandExecutionExitCode(from: object)
            let status = Self.commandExecutionStatusWord(from: object)
            let isError = Self.commandExecutionEndIsError(exitCode: exitCode, status: status)
            let dedupKey = itemID ?? toolDedupKey(
                itemID: nil,
                toolName: "bash",
                argsJSON: argsJSON,
                resultJSON: resultJSON
            )
            return .result(
                name: "bash",
                invocationID: invocationID,
                argsJSON: argsJSON,
                resultJSON: resultJSON,
                isError: isError,
                dedupKey: dedupKey
            )
        }
        return nil
    }

    private func normalizedCommandExecutionArgsJSON(from candidate: [String: Any]) -> String? {
        var args: [String: Any] = [:]
        if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
            args["command"] = command
        }
        if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
            args["cwd"] = cwd
        }
        if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]), !processID.isEmpty {
            args["processId"] = processID
        }
        let commandActions = candidate["commandActions"] ?? candidate["command_actions"]
        if let commandActions, JSONSerialization.isValidJSONObject(["commandActions": commandActions]) {
            args["commandActions"] = commandActions
        }
        return args.isEmpty ? nil : jsonString(from: args)
    }

    private func normalizedCommandExecutionResultJSON(from candidate: [String: Any]) -> String {
        let rawStatus = stringValue(from: candidate, keys: ["status"])
        let exitCode = intValue(candidate["exitCode"]) ?? intValue(candidate["exit_code"]) ?? intValue(candidate["code"])
        let status: String = {
            if let mapped = Self.normalizedCommandExecutionStatusWord(rawStatus) {
                return mapped
            }
            if let exitCode {
                return exitCode == 0 ? "completed" : "failed"
            }
            return "completed"
        }()

        var payload: [String: Any] = [
            "type": "commandExecution",
            "status": status
        ]
        if let itemID = stringValue(from: candidate, keys: ["id", "itemId", "item_id"]), !itemID.isEmpty {
            payload["id"] = itemID
        }
        if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
            payload["command"] = command
        }
        if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
            payload["cwd"] = cwd
        }
        if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]), !processID.isEmpty {
            payload["processId"] = processID
        }
        if let source = stringValue(from: candidate, keys: ["source"]), !source.isEmpty {
            payload["source"] = source
        }
        if let exitCode, exitCode >= 0 {
            payload["exitCode"] = exitCode
        }
        if let durationMs = intValue(candidate["durationMs"]) ?? intValue(candidate["duration_ms"]), durationMs >= 0 {
            payload["durationMs"] = durationMs
        }
        if let output = stringValue(from: candidate, keys: Self.commandExecutionOutputKeys),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["aggregatedOutput"] = Self.sanitizeCommandOutput(output)
        }
        let commandActions = candidate["commandActions"] ?? candidate["command_actions"]
        if let commandActions, JSONSerialization.isValidJSONObject(["commandActions": commandActions]) {
            payload["commandActions"] = commandActions
        }
        return CommandExecutionPayloadHelper.encodeJSONObject(payload)
            ?? Self.minimalCompletedCommandExecutionResultJSON
    }

    private static func normalizedCommandExecutionStatusWord(_ rawStatus: String?) -> String? {
        guard let rawStatus = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawStatus.isEmpty
        else {
            return nil
        }
        let normalized = rawStatus.lowercased()
        switch normalized {
        case "inprogress", "in_progress", "in-progress", "running", "pending":
            return "running"
        case "declined":
            return "failed"
        default:
            return normalized
        }
    }

    private func parseFileChangeLifecycleEvent(method: String, params: [String: Any]) -> ToolLifecycleEvent? {
        let lowerMethod = method.lowercased()
        let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
        let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
        guard isStarted || isCompleted else { return nil }
        guard let candidate = toolItemCandidates(from: params).first(where: { Self.candidateLooksLikeFileChange($0) }) else {
            return nil
        }
        let itemID = stringValue(from: candidate, keys: ["id", "itemId", "item_id"])
        guard let itemID, !itemID.isEmpty else { return nil }
        let invocationID = invocationID(from: itemID)
        let existingState = fileChangeStateByItemID[itemID]
        let argsJSON = applyPatchArgsJSON(from: candidate) ?? existingState?.argsJSON
        let statusInfo = Self.normalizedApplyPatchStatus(
            from: stringValue(from: candidate, keys: ["status"]),
            isCompletedLifecycle: isCompleted
        )
        let resultJSON = applyPatchResultJSON(
            from: candidate,
            accumulatedOutput: existingState?.accumulatedOutput
        )

        if isStarted {
            // A restarted itemID clears any prior terminal marker so deltas are accepted again.
            terminalFileChangeItemIDs.remove(itemID)
            fileChangeStateByItemID[itemID] = FileChangeStreamState(
                itemID: itemID,
                invocationID: invocationID,
                argsJSON: argsJSON,
                latestResultJSON: resultJSON,
                accumulatedOutput: existingState?.accumulatedOutput ?? "",
                status: statusInfo.status
            )
            let dedupKey = toolDedupKey(
                itemID: itemID,
                toolName: "apply_patch",
                argsJSON: argsJSON,
                resultJSON: nil
            )
            return .call(name: "apply_patch", invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
        }

        fileChangeStateByItemID.removeValue(forKey: itemID)
        // Mark this itemID as terminal so late output deltas are suppressed.
        terminalFileChangeItemIDs.insert(itemID)
        let dedupKey = toolDedupKey(
            itemID: itemID,
            toolName: "apply_patch",
            argsJSON: argsJSON,
            resultJSON: resultJSON
        )
        return .result(
            name: "apply_patch",
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            isError: statusInfo.isError,
            dedupKey: dedupKey
        )
    }

    private func parseFileChangeOutputDeltaEvent(params: [String: Any]) -> ToolLifecycleEvent? {
        let message = (params["msg"] as? [String: Any]) ?? params
        guard let itemID = stringValue(from: message, keys: ["itemId", "item_id", "id"]),
              !itemID.isEmpty
        else {
            return nil
        }
        // Suppress late output deltas for items that have already reached terminal state.
        guard !terminalFileChangeItemIDs.contains(itemID) else {
            return nil
        }
        let invocationID = invocationID(from: itemID)
        let rawOutput = rawStringValue(from: message, keys: ["delta", "output", "text", "message", "content"])
        let sanitizedOutput: String? = rawOutput.map { output in
            let sanitized = Self.sanitizeCommandOutput(output)
            if sanitized.isEmpty,
               !output.isEmpty,
               output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return output
            }
            return sanitized
        }

        var state = fileChangeStateByItemID[itemID] ?? FileChangeStreamState(
            itemID: itemID,
            invocationID: invocationID,
            argsJSON: nil,
            latestResultJSON: nil,
            accumulatedOutput: "",
            status: "running"
        )
        if let sanitizedOutput {
            state.accumulatedOutput = Self.cappedRunningOutput(state.accumulatedOutput + sanitizedOutput)
        }
        state.status = "running"
        let resultJSON = applyPatchRunningResultJSON(
            from: state.latestResultJSON,
            accumulatedOutput: state.accumulatedOutput,
            status: state.status
        )
        state.latestResultJSON = resultJSON
        fileChangeStateByItemID[itemID] = state
        let dedupKey = toolDedupKey(
            itemID: itemID,
            toolName: "apply_patch",
            argsJSON: state.argsJSON,
            resultJSON: resultJSON
        )
        return .result(
            name: "apply_patch",
            invocationID: state.invocationID,
            argsJSON: state.argsJSON,
            resultJSON: resultJSON,
            isError: false,
            dedupKey: dedupKey
        )
    }

    private func applyPatchArgsJSON(from candidate: [String: Any]) -> String? {
        let changePayloads = applyPatchChangePayloads(from: candidate)
        var seenPaths: Set<String> = []
        let paths = changePayloads.compactMap { payload -> String? in
            guard let path = payload["path"] as? String, !path.isEmpty else { return nil }
            guard seenPaths.insert(path).inserted else { return nil }
            return path
        }
        guard !paths.isEmpty || !changePayloads.isEmpty else { return nil }
        var payload: [String: Any] = [
            "change_count": max(changePayloads.count, paths.count)
        ]
        if let first = paths.first {
            payload["path"] = first
        }
        if paths.count > 1 {
            payload["paths"] = paths
        }
        return jsonString(from: payload)
    }

    private func applyPatchResultJSON(from candidate: [String: Any], accumulatedOutput: String?) -> String {
        let changePayloads = applyPatchChangePayloads(from: candidate)
        let statusInfo = Self.normalizedApplyPatchStatus(
            from: stringValue(from: candidate, keys: ["status"])
        )
        var payload: [String: Any] = [
            "status": statusInfo.status,
            "changes": changePayloads,
            "change_count": changePayloads.count,
            "summary_only": false
        ]
        if let accumulatedOutput, !accumulatedOutput.isEmpty {
            payload["output"] = accumulatedOutput
        }
        return jsonString(from: payload) ?? "{\"status\":\"\(statusInfo.status)\",\"changes\":[],\"change_count\":0}"
    }

    private func applyPatchRunningResultJSON(
        from raw: String?,
        accumulatedOutput: String,
        status: String
    ) -> String {
        var object = Self.jsonObject(from: raw) ?? [:]
        object["status"] = status
        object["summary_only"] = false
        if object["changes"] == nil {
            object["changes"] = []
        }
        if object["change_count"] == nil {
            let changes = object["changes"] as? [Any] ?? []
            object["change_count"] = changes.count
        }
        if !accumulatedOutput.isEmpty {
            object["output"] = accumulatedOutput
        }
        return jsonString(from: object) ?? "{\"status\":\"running\",\"changes\":[],\"change_count\":0}"
    }

    private func applyPatchChangePayloads(from candidate: [String: Any]) -> [[String: Any]] {
        let rawChanges = candidate["changes"] as? [Any] ?? []
        return rawChanges.compactMap { rawChange in
            guard let change = rawChange as? [String: Any],
                  let path = stringValue(from: change, keys: ["path"]),
                  let diff = rawStringValue(from: change, keys: ["diff"])
            else {
                return nil
            }
            let kindInfo = Self.normalizedApplyPatchKindAndMovePath(from: change["kind"])
            var payload: [String: Any] = [
                "path": path,
                "kind": kindInfo.kind,
                "diff": diff
            ]
            if let movePath = kindInfo.movePath, !movePath.isEmpty {
                payload["move_path"] = movePath
            }
            return payload
        }
    }

    private static func normalizedApplyPatchKindAndMovePath(from raw: Any?) -> (kind: String, movePath: String?) {
        if let raw = raw as? String {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), nil)
        }
        if let object = raw as? [String: Any] {
            let kind = dictString(object, key: "type")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "update"
            let movePath = dictString(object, key: "movePath") ?? dictString(object, key: "move_path")
            return (kind, movePath)
        }
        return ("update", nil)
    }

    private static func normalizedApplyPatchStatus(
        from rawStatus: String?,
        isCompletedLifecycle: Bool = false
    ) -> (status: String, isError: Bool?) {
        let normalized = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "inprogress", "in_progress", "running", "pending":
            return isCompletedLifecycle ? ("success", false) : ("running", false)
        case "completed", "success", "succeeded", "ok":
            return ("success", false)
        case "declined", "rejected":
            return ("declined", true)
        case "cancelled", "canceled", "interrupted", "stopped", "terminated":
            return ("cancelled", true)
        case "failed", "failure", "error":
            return ("failed", true)
        default:
            if isCompletedLifecycle, normalized.isEmpty {
                return ("success", false)
            }
            return (normalized.isEmpty ? "running" : normalized, nil)
        }
    }

    // MARK: - apply_patch Running / Terminal Classification

    private static let applyPatchRunningStatusWords: Set<String> = [
        "running", "pending", "in_progress", "inprogress"
    ]

    private static let applyPatchTerminalStatusWords: Set<String> = [
        "success", "completed", "succeeded", "ok",
        "declined", "rejected",
        "cancelled", "canceled", "interrupted", "stopped", "terminated",
        "failed", "failure", "error"
    ]

    /// Extracts the `status` field from an apply_patch result JSON string.
    static func applyPatchStatusWord(from raw: String?) -> String? {
        guard let object = jsonObject(from: raw) else { return nil }
        guard let status = (object["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !status.isEmpty
        else {
            return nil
        }
        return status
    }

    /// Returns `true` when the apply_patch result JSON indicates a running/in-progress state.
    static func applyPatchResultIndicatesRunning(raw: String?) -> Bool {
        guard let status = applyPatchStatusWord(from: raw) else { return false }
        return applyPatchRunningStatusWords.contains(status)
    }

    /// Returns `true` when the apply_patch result JSON indicates a terminal (completed/failed) state.
    static func applyPatchResultIndicatesTerminal(raw: String?) -> Bool {
        guard let status = applyPatchStatusWord(from: raw) else { return false }
        return applyPatchTerminalStatusWords.contains(status)
    }

    private func parseRawMCPToolLifecycleEvent(
        method: String,
        params: [String: Any]
    ) -> ToolLifecycleEvent? {
        let lowerMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowerMethod == "codex/event/mcp_tool_call_begin" || lowerMethod == "codex/event/mcp_tool_call_end" else {
            return nil
        }
        let message = (params["msg"] as? [String: Any]) ?? params
        guard let callID = stringValue(from: message, keys: ["call_id", "callId", "id"]), !callID.isEmpty else {
            return nil
        }
        let invocation = message["invocation"] as? [String: Any] ?? [:]
        var candidate = invocation
        candidate["id"] = callID
        candidate["type"] = "mcpToolCall"
        if let tool = stringValue(from: invocation, keys: ["tool"]), !tool.isEmpty {
            candidate["name"] = tool
        }
        if let server = stringValue(from: invocation, keys: ["server"]), !server.isEmpty {
            candidate["serverName"] = server
        }
        guard let toolName = normalizedToolName(from: candidate) else { return nil }
        let invocationID = invocationID(from: callID)
        let argsJSON = toolArgsJSON(from: candidate)
        if lowerMethod.hasSuffix("_begin") {
            let dedupKey = toolDedupKey(
                itemID: callID,
                toolName: toolName,
                argsJSON: argsJSON,
                resultJSON: nil
            )
            return .call(name: toolName, invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
        }
        let resultJSON = jsonString(from: message["result"] ?? [:])
            ?? "{}"
        let isError = Self.mcpToolResultIsError(message["result"])
        let dedupKey = toolDedupKey(
            itemID: callID,
            toolName: toolName,
            argsJSON: argsJSON,
            resultJSON: resultJSON
        )
        return .result(
            name: toolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            isError: isError,
            dedupKey: dedupKey
        )
    }

    private func parseExecCommandBeginEvent(params: [String: Any]) -> ExecCommandBeginEvent? {
        let message = (params["msg"] as? [String: Any]) ?? params
        guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
              !callID.isEmpty
        else {
            return nil
        }
        return ExecCommandBeginEvent(
            invocationID: invocationID(from: callID),
            argsJSON: execCommandArgsJSON(from: message),
            processID: stringValue(from: message, keys: ["process_id", "processId"]),
            dedupKey: callID
        )
    }

    private func parseExecCommandOutputDeltaUpdate(params: [String: Any]) -> CommandExecutionRunningUpdate? {
        let message = (params["msg"] as? [String: Any]) ?? params
        guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
              !callID.isEmpty
        else {
            return nil
        }
        let chunk = stringValue(from: message, keys: ["chunk"])
        let output = decodeExecCommandOutputChunk(chunk)
            ?? stringValue(from: message, keys: ["delta", "output", "text", "message", "content"])
        let sanitizedOutput = output.map(Self.sanitizeCommandOutput)
        let trimmedOutput = sanitizedOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandExecutionRunningUpdate(
            invocationID: invocationID(from: callID),
            processID: stringValue(from: message, keys: ["process_id", "processId"]),
            appendedOutput: (trimmedOutput?.isEmpty == false) ? sanitizedOutput : nil
        )
    }

    private func parseExecCommandEndEvent(params: [String: Any]) -> ExecCommandEndEvent? {
        let message = (params["msg"] as? [String: Any]) ?? params
        guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
              !callID.isEmpty
        else {
            return nil
        }

        let processID = stringValue(from: message, keys: ["process_id", "processId"])
        let exitCode = intValue(message["exit_code"]) ?? intValue(message["exitCode"]) ?? intValue(message["code"])
        let explicitStatus = stringValue(from: message, keys: ["status"])?.lowercased()
        let status: String = {
            if let explicitStatus, !explicitStatus.isEmpty {
                return explicitStatus
            }
            if let exitCode {
                return exitCode == 0 ? "completed" : "failed"
            }
            return "finished"
        }()

        var payload: [String: Any] = [
            "type": "commandExecution",
            "status": status,
            "id": callID
        ]
        if let processID, !processID.isEmpty {
            payload["processId"] = processID
        }
        if let exitCode, exitCode >= 0 {
            payload["exitCode"] = exitCode
        }
        let durationMs: Int? = {
            if let duration = message["duration"] as? [String: Any] {
                let secs = intValue(duration["secs"]) ?? 0
                let nanos = intValue(duration["nanos"]) ?? 0
                let computed = max(0, secs) * 1000 + max(0, nanos) / 1_000_000
                return computed > 0 ? computed : nil
            }
            if let explicit = intValue(message["duration_ms"]) ?? intValue(message["durationMs"]),
               explicit > 0
            {
                return explicit
            }
            return nil
        }()
        if let durationMs {
            payload["durationMs"] = durationMs
        }
        if let output = stringValue(from: message, keys: [
            "aggregated_output", "aggregatedOutput",
            "formatted_output", "formattedOutput",
            "output", "stdout", "stderr",
            "text", "message"
        ]),
            !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            payload["aggregatedOutput"] = Self.sanitizeCommandOutput(output)
        }

        let resultJSON = jsonString(from: payload) ?? Self.minimalCompletedCommandExecutionResultJSON
        let isError = Self.commandExecutionEndIsError(exitCode: exitCode, status: status)

        let argsJSON = execCommandArgsJSON(from: message)
        return ExecCommandEndEvent(
            invocationID: invocationID(from: callID),
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            isError: isError,
            processID: processID,
            dedupKey: callID
        )
    }

    private static func commandExecutionEndIsError(exitCode: Int?, status: String?) -> Bool? {
        let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedStatus {
        case "failed", "error", "cancelled", "canceled":
            return true
        case "ok", "success", "succeeded", "complete", "completed":
            return false
        default:
            break
        }
        if let exitCode {
            return exitCode != 0
        }
        return nil
    }

    private func execCommandArgsJSON(from message: [String: Any]) -> String? {
        var args: [String: Any] = [:]
        if let command = message["command"] as? [Any] {
            let argv = command
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !argv.isEmpty {
                args["argv"] = argv
            }
        }
        if args["argv"] == nil,
           let command = stringValue(from: message, keys: ["command", "cmd"]),
           !command.isEmpty
        {
            args["command"] = command
        }
        if let cwd = stringValue(from: message, keys: ["cwd"]), !cwd.isEmpty {
            args["cwd"] = cwd
        }
        if let processID = stringValue(from: message, keys: ["process_id", "processId"]), !processID.isEmpty {
            args["processId"] = processID
        }
        if args.isEmpty,
           let invocation = message["invocation"] as? [String: Any]
        {
            if let arguments = invocation["arguments"] {
                return jsonString(from: arguments)
            }
            if let command = invocation["command"] as? [Any] {
                let argv = command
                    .compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !argv.isEmpty {
                    args["argv"] = argv
                }
            }
            if let command = stringValue(from: invocation, keys: ["command", "cmd"]), !command.isEmpty {
                args["command"] = command
            }
            if let cwd = stringValue(from: invocation, keys: ["cwd"]), !cwd.isEmpty {
                args["cwd"] = cwd
            }
        }
        guard !args.isEmpty else { return nil }
        return jsonString(from: args)
    }

    private func decodeExecCommandOutputChunk(_ chunk: String?) -> String? {
        guard let chunk, !chunk.isEmpty else { return nil }
        guard let data = Data(base64Encoded: chunk),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty
        else {
            return chunk
        }
        return decoded
    }

    private func parseCommandExecutionRunningUpdateFromNotification(
        params: [String: Any],
        outputKeys: [String]
    ) -> CommandExecutionRunningUpdate? {
        let candidates = toolItemCandidates(from: params)
        var resolvedInvocationID: UUID?
        var resolvedProcessID: String?
        var resolvedOutput: String?
        var sealsAssistantBoundary = false

        for candidate in candidates {
            if resolvedInvocationID == nil {
                let itemID = stringValue(from: candidate, keys: [
                    "itemId", "item_id", "callId", "call_id", "id", "invocationId", "invocation_id"
                ])
                resolvedInvocationID = invocationID(from: itemID)
            }
            if resolvedProcessID == nil {
                resolvedProcessID = stringValue(from: candidate, keys: [
                    "processId", "process_id"
                ])
            }
            if resolvedOutput == nil {
                for key in outputKeys {
                    if let output = stringValue(from: candidate, keys: [key]) {
                        let sanitized = Self.sanitizeCommandOutput(output)
                        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            resolvedOutput = sanitized
                            break
                        }
                    }
                }
            }
            if let stdin = rawStringValue(from: candidate, keys: ["stdin"]), stdin.isEmpty {
                sealsAssistantBoundary = true
            }
        }

        guard resolvedInvocationID != nil || (resolvedProcessID?.isEmpty == false) else {
            return nil
        }
        return CommandExecutionRunningUpdate(
            invocationID: resolvedInvocationID,
            processID: resolvedProcessID,
            appendedOutput: resolvedOutput,
            sealsAssistantBoundary: sealsAssistantBoundary
        )
    }

    private static func normalizedExternalToolName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
        if suffix == "local_shell" || suffix == "shell" || suffix == "unified_exec" || suffix == "exec_command" || suffix == "run_shell_command" {
            return "bash"
        }
        if suffix == "filechange" || suffix == "file_change" {
            return "apply_patch"
        }
        return suffix
    }

    private static func writeStdinSessionID(from argsJSON: String?) -> String? {
        guard let object = jsonObject(from: argsJSON) else { return nil }
        for key in ["session_id", "sessionId", "sessionID"] {
            if let string = dictString(object, key: key), !string.isEmpty {
                return string
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func writeStdinIsPoll(argsJSON: String?) -> Bool {
        guard let object = jsonObject(from: argsJSON) else { return false }
        if let chars = dictString(object, key: "chars") {
            return chars.isEmpty
        }
        return false
    }

    private static func writeStdinResultIndicatesRunning(
        resultJSON: String?,
        isError: Bool?
    ) -> Bool {
        guard isError != true else { return false }
        guard let object = writeStdinResultObject(from: resultJSON) else { return false }
        if commandExecutionExitCode(from: object) != nil {
            return false
        }
        if let error = dictString(object, key: "error")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty
        {
            return false
        }
        if let status = dictString(object, key: "status")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            if commandExecutionRunningStatusWords.contains(status) {
                return true
            }
            if commandExecutionTerminalStatusWords.contains(status) {
                return false
            }
        }
        return false
    }

    private static func writeStdinResultObject(from raw: String?) -> [String: Any]? {
        guard let object = jsonObject(from: raw) else { return nil }
        if object["Ok"] != nil || object["Err"] != nil {
            if let extracted = textFromMCPToolResult(object),
               let extractedObject = jsonObject(from: extracted)
            {
                return extractedObject
            }
        }
        return object
    }

    private static func commandExecutionProcessID(from raw: String?) -> String? {
        guard let object = jsonObject(from: raw) else { return nil }
        for key in ["processId", "process_id"] {
            if let value = dictString(object, key: key), !value.isEmpty {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func canonicalCommandProcessIDs(for rawProcessID: String?) -> [String] {
        guard let rawProcessID = rawProcessID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProcessID.isEmpty
        else {
            return []
        }
        let lowercased = rawProcessID.lowercased()
        if lowercased.hasPrefix("session:") {
            let bare = String(rawProcessID.dropFirst("session:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if bare.isEmpty {
                return [rawProcessID]
            }
            if bare == rawProcessID {
                return [rawProcessID]
            }
            return [rawProcessID, bare]
        }
        return [rawProcessID, "session:\(rawProcessID)"]
    }

    private static func commandExecutionCallID(from raw: String?) -> String? {
        guard let object = jsonObject(from: raw) else { return nil }
        for key in ["id", "callId", "call_id"] {
            if let value = dictString(object, key: key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private enum CommandExecutionPayloadHelper {
        static func object(from raw: String?) -> [String: Any] {
            CodexNativeSessionController.jsonObject(from: raw) ?? [:]
        }

        static func seedAggregatedOutputIfNeeded(object: inout [String: Any], raw: String?) {
            guard object.isEmpty,
                  let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            let sanitizedRaw = CodexNativeSessionController.sanitizeCommandOutput(raw)
            guard !sanitizedRaw.isEmpty else { return }
            object["aggregatedOutput"] = sanitizedRaw
        }

        static func markRunning(object: inout [String: Any], processID: String?) {
            object["type"] = (CodexNativeSessionController.dictString(object, key: "type")?.isEmpty == false)
                ? object["type"]
                : "commandExecution"
            object["status"] = "running"
            object.removeValue(forKey: "exitCode")
            object.removeValue(forKey: "exit_code")
            object.removeValue(forKey: "code")

            let existingProcessID =
                CodexNativeSessionController.dictString(object, key: "processId")
                    ?? CodexNativeSessionController.dictString(object, key: "process_id")
            if let processID, !processID.isEmpty {
                object["processId"] = processID
            } else if let existingProcessID, !existingProcessID.isEmpty {
                object["processId"] = existingProcessID
            }
            object.removeValue(forKey: "process_id")
        }

        static func mergeAggregatedOutput(object: inout [String: Any], appendOutput: String?) {
            var aggregatedOutput =
                CodexNativeSessionController.dictString(object, key: "aggregatedOutput")
                    ?? CodexNativeSessionController.dictString(object, key: "aggregated_output")
                    ?? outputText(from: object)
                    ?? ""
            // Avoid re-sanitizing the full accumulated transcript on every delta append.
            // Sanitize existing output only when it still contains control/escape markers.
            if !aggregatedOutput.isEmpty, containsControlOrEscapeMarkers(aggregatedOutput) {
                aggregatedOutput = CodexNativeSessionController.sanitizeCommandOutput(aggregatedOutput)
            }
            if let appendOutput, !appendOutput.isEmpty {
                let sanitizedAppend = CodexNativeSessionController.sanitizeCommandOutput(appendOutput)
                if !sanitizedAppend.isEmpty {
                    aggregatedOutput += sanitizedAppend
                }
            }
            if !aggregatedOutput.isEmpty {
                object["aggregatedOutput"] = CodexNativeSessionController.cappedRunningOutput(aggregatedOutput)
            }
            object.removeValue(forKey: "aggregated_output")
        }

        static func outputText(from object: [String: Any]) -> String? {
            for key in CodexNativeSessionController.commandExecutionOutputKeys {
                if let value = CodexNativeSessionController.dictString(object, key: key) {
                    let sanitized = CodexNativeSessionController.sanitizeCommandOutput(value)
                    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return sanitized
                    }
                }
            }
            return nil
        }

        static func sanitizeOutputFields(in object: inout [String: Any]) -> Bool {
            var didChange = false
            for key in CodexNativeSessionController.commandExecutionOutputKeys {
                guard let value = CodexNativeSessionController.dictString(object, key: key) else { continue }
                let sanitized = CodexNativeSessionController.sanitizeCommandOutput(value)
                guard sanitized != value else { continue }
                object[key] = sanitized
                didChange = true
            }
            return didChange
        }

        static func encodeJSONObject(_ object: [String: Any]) -> String? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: []),
                  let json = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return json
        }

        private static func containsControlOrEscapeMarkers(_ text: String) -> Bool {
            text.contains("\u{001B}")
                || text.contains("\u{009B}")
                || text.contains("\u{0008}")
                || text.contains("\r")
        }
    }

    private static func withCommandExecutionRunningStatus(
        raw: String?,
        processID: String?,
        appendOutput: String?
    ) -> String {
        var object = CommandExecutionPayloadHelper.object(from: raw)
        CommandExecutionPayloadHelper.seedAggregatedOutputIfNeeded(object: &object, raw: raw)
        CommandExecutionPayloadHelper.markRunning(object: &object, processID: processID)
        CommandExecutionPayloadHelper.mergeAggregatedOutput(object: &object, appendOutput: appendOutput)
        return CommandExecutionPayloadHelper.encodeJSONObject(object)
            ?? (raw ?? "{\"type\":\"commandExecution\",\"status\":\"running\"}")
    }

    private static func cappedRunningOutput(_ raw: String) -> String {
        guard raw.count > maxRunningAggregatedOutputCharacters else { return raw }
        let suffix = String(raw.suffix(maxRunningAggregatedOutputCharacters))
        if suffix.hasPrefix(runningOutputTruncationMarker) {
            return suffix
        }
        return runningOutputTruncationMarker + suffix
    }

    private static func loadPersistedCommandSignals(fromRolloutPath path: String) -> PersistedCommandSignals {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8), !contents.isEmpty else {
            return PersistedCommandSignals()
        }

        var toolNameByCallID: [String: String] = [:]
        var writeStdinSessionIDByCallID: [String: String] = [:]
        var processIDByCallID: [String: String] = [:]
        var signals = PersistedCommandSignals()

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                continue
            }

            if let type = root["type"] as? String,
               type == "response_item",
               let payload = root["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String
            {
                switch payloadType {
                case "function_call":
                    guard let callID = dictString(payload, key: "call_id"), !callID.isEmpty else { continue }
                    let normalizedName = normalizedExternalToolName(dictString(payload, key: "name"))
                    if let normalizedName {
                        toolNameByCallID[callID] = normalizedName
                    }
                    if normalizedName == "write_stdin",
                       let argsJSON = dictString(payload, key: "arguments"),
                       let sessionID = writeStdinSessionID(from: argsJSON)
                    {
                        writeStdinSessionIDByCallID[callID] = sessionID
                    }

                case "function_call_output":
                    guard let callID = dictString(payload, key: "call_id"), !callID.isEmpty else { continue }
                    guard let output = dictString(payload, key: "output"), !output.isEmpty else { continue }
                    guard let normalizedName = toolNameByCallID[callID] else { continue }

                    if normalizedName == "bash" {
                        if commandExecutionResultIndicatesRunning(raw: output) {
                            signals.runningCallIDs.insert(callID)
                            signals.terminalCallIDs.remove(callID)
                            if let processID = commandExecutionProcessID(from: output) {
                                processIDByCallID[callID] = processID
                                for key in canonicalCommandProcessIDs(for: processID) {
                                    signals.runningProcessIDs.insert(key)
                                    signals.terminalProcessIDs.remove(key)
                                }
                            }
                            if let outputText = commandExecutionOutputText(from: output),
                               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                appendPersistedCommandOutput(
                                    outputText,
                                    callID: callID,
                                    processID: processIDByCallID[callID],
                                    signals: &signals
                                )
                            }
                        } else if let parsed = parseExecCommandRunningOutput(raw: output) {
                            processIDByCallID[callID] = parsed.processID
                            signals.runningCallIDs.insert(callID)
                            signals.terminalCallIDs.remove(callID)
                            for key in canonicalCommandProcessIDs(for: parsed.processID) {
                                signals.runningProcessIDs.insert(key)
                                signals.terminalProcessIDs.remove(key)
                            }
                            if let normalizedOutput = parsed.output {
                                appendPersistedCommandOutput(
                                    normalizedOutput,
                                    callID: callID,
                                    processID: parsed.processID,
                                    signals: &signals
                                )
                            }
                        } else if commandExecutionResultIndicatesTerminal(raw: output) {
                            signals.runningCallIDs.remove(callID)
                            signals.terminalCallIDs.insert(callID)
                            let processID = commandExecutionProcessID(from: output) ?? processIDByCallID[callID]
                            if let processID {
                                processIDByCallID[callID] = processID
                                for key in canonicalCommandProcessIDs(for: processID) {
                                    signals.runningProcessIDs.remove(key)
                                    signals.terminalProcessIDs.insert(key)
                                }
                            }
                            if let outputText = commandExecutionOutputText(from: output),
                               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            {
                                appendPersistedCommandOutput(
                                    outputText,
                                    callID: callID,
                                    processID: processID,
                                    signals: &signals
                                )
                            }
                        }
                        continue
                    }

                    if normalizedName == "write_stdin",
                       let expectedSessionID = writeStdinSessionIDByCallID[callID],
                       writeStdinResultIndicatesRunning(resultJSON: output, isError: nil)
                    {
                        for key in canonicalCommandProcessIDs(for: expectedSessionID) {
                            signals.runningProcessIDs.insert(key)
                        }
                    }

                default:
                    break
                }
                continue
            }

            guard let method = dictString(root, key: "method"), !method.isEmpty else { continue }
            let payload = root["payload"] as? [String: Any] ?? [:]
            let message = (payload["msg"] as? [String: Any]) ?? payload

            switch method {
            case "codex/event/exec_command_begin":
                guard let callID = dictString(message, key: "call_id"), !callID.isEmpty else { continue }
                toolNameByCallID[callID] = "bash"
                signals.runningCallIDs.insert(callID)
                signals.terminalCallIDs.remove(callID)
                if let processID = dictString(message, key: "process_id"), !processID.isEmpty {
                    processIDByCallID[callID] = processID
                    for key in canonicalCommandProcessIDs(for: processID) {
                        signals.runningProcessIDs.insert(key)
                        signals.terminalProcessIDs.remove(key)
                    }
                }

            case "codex/event/exec_command_output_delta",
                 "item/commandExecution/outputDelta",
                 "codex/event/item_commandExecution_outputDelta":
                let callID =
                    dictString(message, key: "call_id")
                        ?? dictString(message, key: "itemId")
                        ?? dictString(message, key: "item_id")
                        ?? dictString(payload, key: "itemId")
                        ?? dictString(payload, key: "item_id")
                let processID =
                    dictString(message, key: "process_id")
                        ?? dictString(message, key: "processId")
                        ?? (callID.flatMap { processIDByCallID[$0] })
                if let callID, !callID.isEmpty {
                    signals.runningCallIDs.insert(callID)
                    signals.terminalCallIDs.remove(callID)
                    toolNameByCallID[callID] = toolNameByCallID[callID] ?? "bash"
                }
                if let processID, !processID.isEmpty {
                    if let callID, !callID.isEmpty {
                        processIDByCallID[callID] = processID
                    }
                    for key in canonicalCommandProcessIDs(for: processID) {
                        signals.runningProcessIDs.insert(key)
                        signals.terminalProcessIDs.remove(key)
                    }
                }
                let decodedChunk =
                    decodePersistedExecOutputChunk(dictString(message, key: "chunk"))
                        ?? dictString(message, key: "delta")
                        ?? dictString(message, key: "output")
                        ?? dictString(payload, key: "delta")
                if let decodedChunk,
                   !decodedChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    appendPersistedCommandOutput(
                        decodedChunk,
                        callID: callID,
                        processID: processID,
                        signals: &signals
                    )
                }

            case "codex/event/exec_command_end":
                guard let callID = dictString(message, key: "call_id"), !callID.isEmpty else { continue }
                signals.runningCallIDs.remove(callID)
                signals.terminalCallIDs.insert(callID)
                let processID =
                    dictString(message, key: "process_id")
                        ?? dictString(message, key: "processId")
                        ?? processIDByCallID[callID]
                if let processID, !processID.isEmpty {
                    processIDByCallID[callID] = processID
                    for key in canonicalCommandProcessIDs(for: processID) {
                        signals.runningProcessIDs.remove(key)
                        signals.terminalProcessIDs.insert(key)
                    }
                }
                let endOutput =
                    dictString(message, key: "aggregated_output")
                        ?? dictString(message, key: "formatted_output")
                        ?? dictString(message, key: "stdout")
                        ?? dictString(message, key: "output")
                if let endOutput,
                   !endOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    appendPersistedCommandOutput(
                        endOutput,
                        callID: callID,
                        processID: processID,
                        signals: &signals
                    )
                }

            case "item/started", "item/completed":
                guard let item = payload["item"] as? [String: Any] else { continue }
                let typeRaw = dictString(item, key: "type")?.lowercased() ?? ""
                guard typeRaw.contains("commandexecution") else { continue }

                let callID = dictString(item, key: "id")
                let statusWord = dictString(item, key: "status")?.lowercased()
                let processID =
                    dictString(item, key: "processId")
                        ?? dictString(item, key: "process_id")
                        ?? (callID.flatMap { processIDByCallID[$0] })
                if let callID, !callID.isEmpty {
                    toolNameByCallID[callID] = "bash"
                    let hasTerminalLifecycle = method == "item/completed"
                        || (statusWord.map { commandExecutionTerminalStatusWords.contains($0) } ?? false)
                    if hasTerminalLifecycle {
                        signals.runningCallIDs.remove(callID)
                        signals.terminalCallIDs.insert(callID)
                    } else if statusWord.map({
                        commandExecutionRunningStatusWords.contains($0) || $0 == "inprogress"
                    }) == true {
                        signals.runningCallIDs.insert(callID)
                        signals.terminalCallIDs.remove(callID)
                    }
                }
                if let processID, !processID.isEmpty {
                    if let callID, !callID.isEmpty {
                        processIDByCallID[callID] = processID
                    }
                    let hasTerminalLifecycle = method == "item/completed"
                        || (statusWord.map { commandExecutionTerminalStatusWords.contains($0) } ?? false)
                    if hasTerminalLifecycle {
                        for key in canonicalCommandProcessIDs(for: processID) {
                            signals.runningProcessIDs.remove(key)
                            signals.terminalProcessIDs.insert(key)
                        }
                    } else if statusWord.map({
                        commandExecutionRunningStatusWords.contains($0) || $0 == "inprogress"
                    }) == true {
                        for key in canonicalCommandProcessIDs(for: processID) {
                            signals.runningProcessIDs.insert(key)
                            signals.terminalProcessIDs.remove(key)
                        }
                    }
                }
                if let output =
                    dictString(item, key: "aggregatedOutput")
                        ?? dictString(item, key: "aggregated_output"),
                        !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    appendPersistedCommandOutput(
                        output,
                        callID: callID,
                        processID: processID,
                        signals: &signals
                    )
                }

            case "codex/event/mcp_tool_call_begin":
                guard let callID = dictString(message, key: "call_id"), !callID.isEmpty else { continue }
                let invocation = message["invocation"] as? [String: Any] ?? [:]
                let normalizedName = normalizedExternalToolName(dictString(invocation, key: "tool"))
                if let normalizedName {
                    toolNameByCallID[callID] = normalizedName
                }
                if normalizedName == "write_stdin" {
                    if let arguments = invocation["arguments"] as? [String: Any],
                       let argsJSON = CommandExecutionPayloadHelper.encodeJSONObject(arguments),
                       let sessionID = writeStdinSessionID(from: argsJSON)
                    {
                        writeStdinSessionIDByCallID[callID] = sessionID
                    } else if let arguments = dictString(invocation, key: "arguments"),
                              let sessionID = writeStdinSessionID(from: arguments)
                    {
                        writeStdinSessionIDByCallID[callID] = sessionID
                    }
                }

            case "codex/event/mcp_tool_call_end":
                guard let callID = dictString(message, key: "call_id"), !callID.isEmpty else { continue }
                let invocation = message["invocation"] as? [String: Any] ?? [:]
                let normalizedName =
                    normalizedExternalToolName(dictString(invocation, key: "tool"))
                        ?? toolNameByCallID[callID]
                guard let normalizedName else { continue }
                toolNameByCallID[callID] = normalizedName
                let outputText = textFromMCPToolResult(message["result"])

                if normalizedName == "bash", let outputText, !outputText.isEmpty {
                    if commandExecutionResultIndicatesRunning(raw: outputText) {
                        signals.runningCallIDs.insert(callID)
                        signals.terminalCallIDs.remove(callID)
                        if let processID = commandExecutionProcessID(from: outputText) {
                            processIDByCallID[callID] = processID
                            for key in canonicalCommandProcessIDs(for: processID) {
                                signals.runningProcessIDs.insert(key)
                                signals.terminalProcessIDs.remove(key)
                            }
                        }
                        if let formattedOutput = commandExecutionOutputText(from: outputText),
                           !formattedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            appendPersistedCommandOutput(
                                formattedOutput,
                                callID: callID,
                                processID: processIDByCallID[callID],
                                signals: &signals
                            )
                        }
                    } else if let parsed = parseExecCommandRunningOutput(raw: outputText) {
                        processIDByCallID[callID] = parsed.processID
                        signals.runningCallIDs.insert(callID)
                        signals.terminalCallIDs.remove(callID)
                        for key in canonicalCommandProcessIDs(for: parsed.processID) {
                            signals.runningProcessIDs.insert(key)
                            signals.terminalProcessIDs.remove(key)
                        }
                        if let parsedOutput = parsed.output {
                            appendPersistedCommandOutput(
                                parsedOutput,
                                callID: callID,
                                processID: parsed.processID,
                                signals: &signals
                            )
                        }
                    } else if commandExecutionResultIndicatesTerminal(raw: outputText) {
                        signals.runningCallIDs.remove(callID)
                        signals.terminalCallIDs.insert(callID)
                        let processID = commandExecutionProcessID(from: outputText) ?? processIDByCallID[callID]
                        if let processID {
                            processIDByCallID[callID] = processID
                            for key in canonicalCommandProcessIDs(for: processID) {
                                signals.runningProcessIDs.remove(key)
                                signals.terminalProcessIDs.insert(key)
                            }
                        }
                        if let formattedOutput = commandExecutionOutputText(from: outputText),
                           !formattedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            appendPersistedCommandOutput(
                                formattedOutput,
                                callID: callID,
                                processID: processID,
                                signals: &signals
                            )
                        }
                    }
                    continue
                }

                if normalizedName == "write_stdin",
                   let expectedSessionID = writeStdinSessionIDByCallID[callID],
                   let outputText,
                   writeStdinResultIndicatesRunning(resultJSON: outputText, isError: nil)
                {
                    for key in canonicalCommandProcessIDs(for: expectedSessionID) {
                        signals.runningProcessIDs.insert(key)
                    }
                    if let parsed = parseExecCommandRunningOutput(raw: outputText),
                       let parsedOutput = parsed.output
                    {
                        appendPersistedCommandOutput(
                            parsedOutput,
                            callID: callID,
                            processID: expectedSessionID,
                            signals: &signals
                        )
                    }
                }

            default:
                continue
            }
        }
        return signals
    }

    private static func appendPersistedCommandOutput(
        _ rawOutput: String,
        callID: String?,
        processID: String?,
        signals: inout PersistedCommandSignals
    ) {
        let sanitized = sanitizeCommandOutput(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        if let callID, !callID.isEmpty {
            signals.outputByCallID[callID] = mergePersistedCommandOutput(
                existing: signals.outputByCallID[callID],
                appended: sanitized
            )
        }
        for key in canonicalCommandProcessIDs(for: processID) {
            signals.outputByProcessID[key] = mergePersistedCommandOutput(
                existing: signals.outputByProcessID[key],
                appended: sanitized
            )
        }
    }

    private static func mergePersistedCommandOutput(existing: String?, appended: String) -> String {
        let existingTrimmed = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingTrimmed.isEmpty {
            return cappedRunningOutput(appended)
        }
        if existingTrimmed.hasSuffix(appended) {
            return cappedRunningOutput(existingTrimmed)
        }
        let needsSeparator = !existingTrimmed.hasSuffix("\n") && !appended.hasPrefix("\n")
        let merged = existingTrimmed + (needsSeparator ? "\n" : "") + appended
        return cappedRunningOutput(merged)
    }

    private static func decodePersistedExecOutputChunk(_ chunk: String?) -> String? {
        guard let chunk, !chunk.isEmpty else { return nil }
        guard let data = Data(base64Encoded: chunk),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty
        else {
            return chunk
        }
        return decoded
    }

    private static func mcpToolResultIsError(_ value: Any?) -> Bool? {
        guard let result = value as? [String: Any] else { return nil }
        if result["Err"] != nil {
            return true
        }
        if let ok = result["Ok"] as? [String: Any], let isError = ok["isError"] as? Bool {
            return isError
        }
        return nil
    }

    private static func textFromMCPToolResult(_ value: Any?) -> String? {
        guard let result = value as? [String: Any],
              let ok = result["Ok"] as? [String: Any]
        else {
            return nil
        }
        if let content = ok["content"] as? [[String: Any]] {
            let text = content
                .compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let text = ok["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func parseExecCommandRunningOutput(raw: String) -> (processID: String, output: String?)? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let processRange = normalized.range(of: #"Process running with session ID\s+([0-9]+)"#, options: .regularExpression) else {
            return nil
        }
        let processLine = String(normalized[processRange])
        let processID = processLine.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard !processID.isEmpty else { return nil }

        var outputText: String?
        if let outputHeaderRange = normalized.range(of: "Output:\n") {
            let tail = String(normalized[outputHeaderRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                let sanitizedTail = sanitizeCommandOutput(tail)
                if !sanitizedTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    outputText = sanitizedTail
                }
            }
        }
        return (processID, outputText)
    }

    private static func commandExecutionOutputText(from raw: String?) -> String? {
        guard let object = jsonObject(from: raw) else { return nil }
        return CommandExecutionPayloadHelper.outputText(from: object)
    }

    static func mergeCommandExecutionCompletionPayload(
        existing: String?,
        incoming: String,
        argsJSON: String?
    ) -> String {
        guard var incomingObject = jsonObject(from: incoming) else { return incoming }
        guard commandExecutionObjectIsCommandLike(incomingObject) else { return incoming }

        let incomingCommand = dictString(incomingObject, key: "command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingProcessID = commandExecutionProcessID(from: incoming)
        let incomingOutput = CommandExecutionPayloadHelper.outputText(from: incomingObject)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if (incomingCommand?.isEmpty != false) || incomingProcessID == nil || (incomingOutput?.isEmpty != false) {
            let existingObject = jsonObject(from: existing)

            if incomingCommand?.isEmpty != false,
               let existingCommand = dictString(existingObject ?? [:], key: "command")?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !existingCommand.isEmpty
            {
                incomingObject["command"] = existingCommand
            } else if incomingCommand?.isEmpty != false,
                      let argsObject = jsonObject(from: argsJSON),
                      let argsCommand = commandFromCommandPayload(argsObject),
                      !argsCommand.isEmpty
            {
                incomingObject["command"] = argsCommand
            }

            if incomingProcessID == nil,
               let existingProcessID = commandExecutionProcessID(from: existing),
               !existingProcessID.isEmpty
            {
                incomingObject["processId"] = existingProcessID
                incomingObject.removeValue(forKey: "process_id")
            }

            if incomingOutput?.isEmpty != false,
               let existingOutput = CommandExecutionPayloadHelper.outputText(from: existingObject ?? [:])?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !existingOutput.isEmpty
            {
                incomingObject["aggregatedOutput"] = cappedRunningOutput(sanitizeCommandOutput(existingOutput))
                incomingObject.removeValue(forKey: "aggregated_output")
            }
        }

        return CommandExecutionPayloadHelper.encodeJSONObject(incomingObject) ?? incoming
    }

    private static func commandFromCommandPayload(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            for key in ["command", "cmd", "input", "text", "value", "argv", "args"] {
                if let command = commandFromCommandPayload(object[key]), !command.isEmpty {
                    return command
                }
            }
            if let invocationCommand = commandFromCommandPayload(object["invocation"]), !invocationCommand.isEmpty {
                return invocationCommand
            }
            if let argumentsCommand = commandFromCommandPayload(object["arguments"]), !argumentsCommand.isEmpty {
                return argumentsCommand
            }
            return nil
        }

        if let array = value as? [Any] {
            let parts = array.compactMap { element -> String? in
                if let string = element as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if let number = element as? NSNumber {
                    let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
            for nested in array {
                if let command = commandFromCommandPayload(nested), !command.isEmpty {
                    return command
                }
            }
            return nil
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\""),
               let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data, options: []),
               let nestedCommand = commandFromCommandPayload(nested),
               !nestedCommand.isEmpty
            {
                return nestedCommand
            }
            if trimmed.count >= 2,
               let first = trimmed.first,
               let last = trimmed.last,
               first == last,
               first == "\"" || first == "'"
            {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { return inner }
            }
            return trimmed
        }

        if let number = value as? NSNumber {
            let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func sanitizedCommandExecutionResultJSON(_ raw: String) -> String {
        guard var object = jsonObject(from: raw) else {
            return sanitizeCommandOutput(raw)
        }
        guard CommandExecutionPayloadHelper.sanitizeOutputFields(in: &object),
              let json = CommandExecutionPayloadHelper.encodeJSONObject(object)
        else {
            return raw
        }
        return json
    }

    private static func sanitizeCommandOutput(_ raw: String) -> String {
        CommandExecutionOutputSanitizer.sanitize(raw)
    }

    private static let commandExecutionOutputKeys: [String] = [
        "formattedOutput",
        "formatted_output",
        "aggregatedOutput",
        "aggregated_output",
        "output",
        "stdout",
        "stderr",
        "combinedOutput",
        "combined_output",
        "recentOutput",
        "recent_output",
        "text",
        "message",
        "content",
        "result",
        "log",
        "logs"
    ]

    private static let commandExecutionRunningStatusWords: Set<String> = [
        "running", "in_progress", "inprogress", "in-progress", "pending"
    ]
    private static let commandExecutionTerminalStatusWords: Set<String> = [
        "completed", "complete", "success", "succeeded", "ok", "failed", "failure", "error",
        "cancelled", "canceled", "terminated", "stopped", "done", "exited", "finished",
        "timeout", "timed_out", "killed"
    ]

    private static func commandExecutionResultIndicatesRunning(raw: String?) -> Bool {
        guard let object = jsonObject(from: raw) else { return false }
        guard commandExecutionObjectIsCommandLike(object) else { return false }

        let exitCode = commandExecutionExitCode(from: object)
        let processID = commandExecutionProcessID(from: raw)

        if let statusWord = commandExecutionStatusWord(from: object),
           commandExecutionRunningStatusWords.contains(statusWord)
        {
            return true
        }

        if let exitCode {
            if exitCode >= 0 {
                return false
            }
            if processID != nil {
                return true
            }
        }

        return false
    }

    private static func shouldPatchCommandExecutionRunningPayload(
        raw: String?,
        processID: String?,
        appendOutput: String?
    ) -> Bool {
        if appendOutput?.isEmpty == false {
            return true
        }
        guard let object = jsonObject(from: raw) else {
            return true
        }
        guard commandExecutionObjectIsCommandLike(object) else {
            return true
        }
        if object["process_id"] != nil
            || object["aggregated_output"] != nil
            || object["exit_code"] != nil
            || object["code"] != nil
        {
            return true
        }
        if commandExecutionExitCode(from: object) != nil {
            return true
        }
        let existingProcessID =
            dictString(object, key: "processId")
                ?? dictString(object, key: "process_id")
        if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !processID.isEmpty,
           processID != existingProcessID
        {
            return true
        }
        guard let statusWord = commandExecutionStatusWord(from: object) else {
            return true
        }
        return !commandExecutionRunningStatusWords.contains(statusWord)
    }

    private static func commandExecutionResultIndicatesTerminal(raw: String?) -> Bool {
        guard let object = jsonObject(from: raw) else { return false }
        let exitCode = commandExecutionExitCode(from: object)
        let processID = commandExecutionProcessID(from: raw)

        if let exitCode {
            if exitCode >= 0 {
                return true
            }
            // Some wrappers report status=failed + exitCode<0 while the underlying
            // process is still running. Keep those non-terminal when we have a PID.
            return processID == nil
        }

        if let statusWord = commandExecutionStatusWord(from: object) {
            if commandExecutionRunningStatusWords.contains(statusWord) {
                return false
            }
            if commandExecutionTerminalStatusWords.contains(statusWord) {
                return true
            }
        }
        if dictBool(object, key: "success") == true || dictBool(object, key: "ok") == true {
            return true
        }
        if let errorText = dictString(object, key: "error")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorText.isEmpty
        {
            return true
        }
        return false
    }

    private static func commandExecutionObjectIsCommandLike(_ object: [String: Any]) -> Bool {
        let type = dictString(object, key: "type")?.lowercased() ?? ""
        return type.contains("command")
    }

    private static func commandExecutionExitCode(from object: [String: Any]) -> Int? {
        dictInt(object, key: "exitCode")
            ?? dictInt(object, key: "exit_code")
            ?? dictInt(object, key: "code")
    }

    private static func commandExecutionStatusWord(from object: [String: Any]) -> String? {
        dictString(object, key: "status")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func jsonObject(from raw: String?) -> [String: Any]? {
        JSONDictionaryHelpers.object(from: raw)
    }

    private static func dictString(_ object: [String: Any], key: String) -> String? {
        JSONDictionaryHelpers.string(object, key: key)
    }

    private static func dictBool(_ object: [String: Any], key: String) -> Bool? {
        JSONDictionaryHelpers.bool(object, key: key)
    }

    private static func dictInt(_ object: [String: Any], key: String) -> Int? {
        JSONDictionaryHelpers.int(object, key: key)
    }

    private func invocationID(from rawItemID: String?) -> UUID? {
        guard let raw = rawItemID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let parsed = UUID(uuidString: raw) {
            return parsed
        }

        // Codex sometimes emits non-UUID tool item IDs (for example "call_...").
        // Build a deterministic UUID so started/completed lifecycle events can still pair.
        var hashA: UInt64 = 0xCBF2_9CE4_8422_2325
        var hashB: UInt64 = 0x9E37_79B9_7F4A_7C15
        for (index, byte) in raw.utf8.enumerated() {
            hashA ^= UInt64(byte)
            hashA &*= 0x100_0000_01B3
            hashB ^= UInt64(byte) &+ UInt64(index & 0xFF)
            hashB &*= 0x100_0000_01B3
            hashB = (hashB << 13) | (hashB >> 51)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        bytes.append(contentsOf: withUnsafeBytes(of: hashA.bigEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: hashB.bigEndian) { Array($0) })
        guard bytes.count == 16 else { return nil }

        // RFC 4122 variant + version 5-like marker for synthetic deterministic UUIDs.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func toolItemCandidates(from params: [String: Any]) -> [[String: Any]] {
        Self.toolItemCandidates(fromParams: params)
    }

    private static func toolItemCandidates(fromParams params: [String: Any]) -> [[String: Any]] {
        var candidates: [[String: Any]] = []
        if let item = params["item"] as? [String: Any] {
            candidates.append(item)
        }
        if let msg = params["msg"] as? [String: Any] {
            if let item = msg["item"] as? [String: Any] {
                candidates.append(item)
            }
            candidates.append(msg)
        }
        if let payload = params["payload"] as? [String: Any] {
            if let item = payload["item"] as? [String: Any] {
                candidates.append(item)
            }
            candidates.append(payload)
        }
        if let event = params["event"] as? [String: Any] {
            if let item = event["item"] as? [String: Any] {
                candidates.append(item)
            }
            candidates.append(event)
        }
        candidates.append(params)
        return candidates
    }

    private func normalizedTypeString(from candidate: [String: Any]) -> String {
        let raw = stringValue(from: candidate, keys: ["type", "itemType", "item_type"]) ?? ""
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func usesRawCanonicalLiveEventFamily(typeRaw: String) -> Bool {
        typeRaw.contains("mcptoolcall")
            || typeRaw.contains("mcp_tool_call")
    }

    private func isLikelyToolItem(_ candidate: [String: Any]) -> Bool {
        let typeRaw = normalizedTypeString(from: candidate)
        let typeHints = ["tool", "function", "shell", "search", "exec", "command", "mcp"]
        if typeHints.contains(where: { typeRaw.contains($0) }) {
            return true
        }
        if let _ = stringValue(from: candidate, keys: ["name", "toolName", "tool_name", "functionName", "function_name"]) {
            return true
        }
        return false
    }

    private func isRepoPromptToolCandidate(_ candidate: [String: Any], toolName: String) -> Bool {
        let repoPromptServer = MCPIntegrationHelper.repoPromptMCPServerName.lowercased()
        let mcpPrefix = "mcp__\(repoPromptServer)__"
        if MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(toolName) {
            return true
        }

        let identifyingKeys = [
            "name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name",
            "server", "serverName", "server_name", "mcpServer", "mcp_server", "mcpServerName", "mcp_server_name",
            "toolNamespace", "tool_namespace", "provider", "namespace", "origin"
        ]
        for key in identifyingKeys {
            guard let value = candidate[key] as? String else { continue }
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.isEmpty { continue }
            if lowered.hasPrefix(mcpPrefix) {
                return true
            }
            if key == "server" || key == "serverName" || key == "server_name"
                || key == "mcpServer" || key == "mcp_server" || key == "mcpServerName" || key == "mcp_server_name"
                || key == "toolNamespace" || key == "tool_namespace" || key == "provider" || key == "namespace" || key == "origin"
            {
                if MCPIntegrationHelper.isRepoPromptServerIdentifier(lowered) {
                    return true
                }
            }
        }
        return false
    }

    private func normalizedToolName(from candidate: [String: Any]) -> String? {
        let explicitName = stringValue(from: candidate, keys: [
            "name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name"
        ])
        let typeRaw = normalizedTypeString(from: candidate)
        let raw = (explicitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let lowered = raw.lowercased()

        if lowered == "local_shell"
            || lowered == "shell"
            || lowered == "unified_exec"
            || lowered == "exec_command"
            || lowered == "run_shell_command"
        {
            return "bash"
        }
        if let webCanonical = AgentWebToolCanonicalNames.canonicalToolCardName(lowered) {
            return webCanonical
        }
        if !raw.isEmpty {
            if isRepoPromptToolCandidate(candidate, toolName: raw) {
                let normalized = MCPIntegrationHelper.normalizedRepoPromptToolName(raw)
                return "mcp__\(MCPIntegrationHelper.repoPromptMCPServerName)__\(normalized)"
            }
            return raw
        }

        if typeRaw.contains("shell") || typeRaw.contains("exec") || typeRaw.contains("command") {
            return "bash"
        }
        if typeRaw.contains("filechange") || typeRaw.contains("file_change") {
            return "apply_patch"
        }
        if typeRaw.contains("search") {
            return "search"
        }
        return nil
    }

    private func toolArgsJSON(from candidate: [String: Any], toolName: String? = nil) -> String? {
        for key in ["arguments", "args", "input", "parameters", "params"] {
            if let value = candidate[key], let json = jsonString(from: value), !json.isEmpty {
                return json
            }
        }
        if toolName == "search", var payload = compactWebActionScalars(from: candidate) {
            if payload["query"] == nil, let query = searchQueryValue(from: candidate) {
                payload["query"] = query
            }
            return jsonString(from: payload)
        }
        if toolName == "search", let query = searchQueryValue(from: candidate) {
            return jsonString(from: ["query": query])
        }
        if toolName == "web_read", let payload = compactWebActionScalars(from: candidate) {
            return jsonString(from: payload)
        }
        if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
            var payload: [String: Any] = ["command": command]
            if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]),
               !processID.isEmpty
            {
                payload["processId"] = processID
            }
            if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
                payload["cwd"] = cwd
            }
            return jsonString(from: payload)
        }
        if let query = stringValue(from: candidate, keys: ["query", "q", "searchQuery", "search_query"]), !query.isEmpty {
            return jsonString(from: ["query": query])
        }
        return nil
    }

    private func toolResultJSON(from candidate: [String: Any], toolName: String? = nil) -> String? {
        if toolName == "search", let searchJSON = webSearchToolResultJSON(from: candidate) {
            return searchJSON
        }
        if toolName == "web_read", let readJSON = webReadToolResultJSON(from: candidate) {
            return readJSON
        }
        for key in AgentWebToolPayloadKeys.resultWrapperKeys {
            if let value = candidate[key], let json = jsonString(from: value), !json.isEmpty {
                return json
            }
        }
        if let text = stringValue(from: candidate, keys: ["text", "message"]), !text.isEmpty {
            return text
        }
        if let error = candidate["error"], let json = jsonString(from: error), !json.isEmpty {
            return json
        }
        return nil
    }

    private func webReadToolResultJSON(from candidate: [String: Any]) -> String? {
        var object: [String: Any] = [:]
        copyWebActionScalars(from: candidate, into: &object)
        copyWebReadResultFieldsIncludingWrappers(from: candidate, into: &object)
        let hasResultWrapper = AgentWebToolPayloadKeys.resultWrapperKeys.contains { candidate[$0] != nil }
        return object.isEmpty && !hasResultWrapper ? nil : jsonString(from: object)
    }

    private func webSearchToolResultJSON(from candidate: [String: Any]) -> String? {
        var object: [String: Any] = [:]
        copySearchMetadata(from: candidate, into: &object)
        if isSearchWebReadOrFindPayload(object) {
            copyWebReadResultFieldsIncludingWrappers(from: candidate, into: &object)
            return jsonString(from: object)
        }

        for key in AgentWebToolPayloadKeys.resultWrapperKeys {
            guard let value = candidate[key] else { continue }
            if let array = value as? [Any] {
                if !array.isEmpty { object[searchArrayKey(forWrapper: key)] = array }
                copySearchPayloadFields(from: candidate, into: &object)
                normalizeSearchContentArrays(in: &object)
                return jsonString(from: object)
            }
            if let wrapped = value as? [String: Any] {
                var merged = wrapped
                copySearchMetadata(from: candidate, into: &merged)
                copySearchPayloadFields(from: candidate, into: &merged)
                normalizeSearchContentArrays(in: &merged)
                return jsonString(from: merged)
            }
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                object[searchTextKey(forWrapper: key)] = text
                copySearchPayloadFields(from: candidate, into: &object)
                return jsonString(from: object)
            }
            if let json = jsonString(from: value), !json.isEmpty {
                object[searchTextKey(forWrapper: key)] = json
                copySearchPayloadFields(from: candidate, into: &object)
                return jsonString(from: object)
            }
        }

        copySearchPayloadFields(from: candidate, into: &object)
        normalizeSearchContentArrays(in: &object)
        return object.isEmpty ? nil : jsonString(from: object)
    }

    private func copySearchMetadata(from candidate: [String: Any], into object: inout [String: Any]) {
        copyWebActionScalars(from: candidate, into: &object)
        for key in ["status", "isError", "is_error"] {
            if object[key] == nil, let value = candidate[key] {
                object[key] = value
            }
        }
        for key in AgentWebToolPayloadKeys.queryKeys {
            guard object[key] == nil,
                  let value = candidate[key] as? String,
                  let query = compactWebQueryText(value)
            else { continue }
            object[key] = query
        }
        if object["query"] == nil,
           let query = searchQueryValue(from: candidate)
        {
            object["query"] = query
        }
        if object["error"] == nil, let error = candidate["error"] {
            object["error"] = error
        }
    }

    private func copyWebReadResultFields(from candidate: [String: Any], into object: inout [String: Any]) {
        for key in AgentWebToolPayloadKeys.readResultMetadataKeys {
            guard object[key] == nil,
                  let value = candidate[key],
                  let compactValue = compactWebReadResultValue(value)
            else { continue }
            object[key] = compactValue
        }
        if object["error"] == nil,
           let error = candidate["error"],
           let compactError = compactWebReadErrorValue(error)
        {
            object["error"] = compactError
        }
        if object["errorMessage"] == nil,
           let errorMessage = candidate["errorMessage"] ?? candidate["error_message"],
           let compactErrorMessage = compactWebReadResultValue(errorMessage)
        {
            object["errorMessage"] = compactErrorMessage
        }
        if object["match_count"] == nil, object["matchCount"] == nil,
           let matches = candidate["matches"] as? [Any], !matches.isEmpty
        {
            object["match_count"] = matches.count
        }
    }

    private func copyWebReadResultFieldsIncludingWrappers(
        from candidate: [String: Any],
        into object: inout [String: Any]
    ) {
        copyWebReadResultFields(from: candidate, into: &object)
        for key in AgentWebToolPayloadKeys.resultWrapperKeys {
            guard let wrapped = candidate[key] as? [String: Any] else { continue }
            copyWebActionScalars(from: wrapped, into: &object)
            copyWebReadResultFields(from: wrapped, into: &object)
            copyWebReadFailureMessage(from: wrapped, into: &object)
        }
        copyWebReadFailureMessage(from: candidate, into: &object)
    }

    private func copyWebReadFailureMessage(from candidate: [String: Any], into object: inout [String: Any]) {
        guard webReadResultIndicatesFailure(candidate), object["errorMessage"] == nil else { return }
        for key in ["errorMessage", "error_message", "result", "output", "response", "message", "text"] {
            guard let value = candidate[key],
                  !(value is [String: Any]),
                  let compactErrorMessage = compactWebReadResultValue(value)
            else { continue }
            object["errorMessage"] = compactErrorMessage
            return
        }
    }

    private func webReadResultIndicatesFailure(_ candidate: [String: Any]) -> Bool {
        if boolValue(from: candidate, keys: ["isError", "is_error"]) == true { return true }
        if let status = stringValue(from: candidate, keys: ["status"])?.lowercased(),
           ["error", "failed", "failure"].contains(status)
        {
            return true
        }
        return hasNonEmptyErrorSignal(in: candidate)
    }

    private func compactWebReadResultValue(_ value: Any) -> Any? {
        if let text = value as? String { return compactWebText(text) }
        if value is NSNumber { return value }
        return nil
    }

    private func compactWebReadErrorValue(_ value: Any) -> Any? {
        if let compact = compactWebReadResultValue(value) { return compact }
        guard let error = value as? [String: Any] else { return nil }
        var compactError: [String: Any] = [:]
        for key in ["message", "type", "code", "param", "status"] {
            guard let value = error[key], let compact = compactWebReadResultValue(value) else { continue }
            compactError[key] = compact
        }
        return compactError.isEmpty ? nil : compactError
    }

    private func isSearchWebReadOrFindPayload(_ object: [String: Any]) -> Bool {
        let rawAction = stringValue(from: object, keys: AgentWebToolPayloadKeys.operationKeys)
        let action = AgentWebToolCanonicalNames.canonicalWebActionType(rawAction) ?? rawAction?.lowercased()
        if ["open", "open_page", "read", "fetch", "find", "find_in_page"].contains(action ?? "") { return true }
        let hasTarget = stringValue(from: object, keys: AgentWebToolPayloadKeys.urlTargetKeys + AgentWebToolPayloadKeys.refTargetKeys) != nil
        let hasFind = stringValue(from: object, keys: AgentWebToolPayloadKeys.findKeys) != nil
        return hasTarget && hasFind
    }

    private func compactWebActionScalars(from candidate: [String: Any]) -> [String: Any]? {
        var object: [String: Any] = [:]
        copyWebActionScalars(from: candidate, into: &object)
        return object.isEmpty ? nil : object
    }

    private func copyWebActionScalars(from candidate: [String: Any], into object: inout [String: Any]) {
        for key in AgentWebToolPayloadKeys.compactScalarKeys {
            guard object[key] == nil, let value = candidate[key], isCompactWebActionScalar(value) else { continue }
            object[key] = value
        }

        var containers = [candidate]
        for key in AgentWebToolPayloadKeys.wrapperKeys {
            if let nested = candidate[key] as? [String: Any] {
                containers.append(nested)
            }
        }
        for container in containers {
            guard let action = container["action"] as? [String: Any],
                  let actionType = stringValue(from: action, keys: AgentWebToolPayloadKeys.actionTypeKeys),
                  let canonicalActionType = AgentWebToolCanonicalNames.canonicalWebActionType(actionType)
            else { continue }
            if object["action"] == nil {
                object["action"] = canonicalActionType
            }
            for key in AgentWebToolPayloadKeys.compactScalarKeys {
                guard key != "action",
                      object[key] == nil,
                      let value = action[key],
                      isCompactWebActionScalar(value)
                else { continue }
                object[key] = value
            }
            copyCompactWebSearchQueries(from: action, into: &object)
        }
    }

    private func copyCompactWebSearchQueries(from candidate: [String: Any], into object: inout [String: Any]) {
        guard object["queries"] == nil else { return }
        for key in AgentWebToolPayloadKeys.queryListKeys {
            guard let queries = candidate[key] as? [String] else { continue }
            let compactQueries = queries.prefix(10).compactMap(compactWebText)
            if !compactQueries.isEmpty {
                object["queries"] = compactQueries
                return
            }
        }
    }

    private func isCompactWebActionScalar(_ value: Any) -> Bool {
        if let text = value as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 500
        }
        if value is NSNumber { return true }
        return false
    }

    private func searchQueryValue(from candidate: [String: Any]) -> String? {
        if let query = stringValue(from: candidate, keys: AgentWebToolPayloadKeys.queryKeys),
           let compactQuery = compactWebQueryText(query)
        {
            return compactQuery
        }
        for key in AgentWebToolPayloadKeys.queryListKeys {
            guard let queries = candidate[key] as? [String] else { continue }
            let compactQueries = queries.compactMap(compactWebQueryText)
            guard let first = compactQueries.first else { continue }
            return compactWebQueryText(compactQueries.count > 1 ? "\(first) ..." : first)
        }
        for key in ["action", "search", "request", "parameters", "params"] {
            guard let nested = candidate[key] as? [String: Any] else { continue }
            if let query = searchQueryValue(from: nested) {
                return query
            }
        }
        return nil
    }

    private func compactWebQueryText(_ raw: String) -> String? {
        compactWebText(raw)
    }

    private func compactWebText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= 500 ? trimmed : String(trimmed.prefix(499)) + "…"
    }

    private func copySearchPayloadFields(from candidate: [String: Any], into object: inout [String: Any]) {
        copyWebActionScalars(from: candidate, into: &object)
        for key in ["results", "items", "web_results", "webResults", "search_results", "searchResults", "sources", "citations", "result_count", "resultCount", "total_results", "totalResults", "count", "source_count", "sourceCount", "total_sources", "totalSources", "citation_count", "citationCount", "total_citations", "totalCitations", "summary", "answer", "snippet", "text", "message", "error", "errors", "error_message", "errorMessage"] {
            guard object[key] == nil, let value = candidate[key] else { continue }
            object[key] = value
        }
    }

    private func normalizeSearchContentArrays(in object: inout [String: Any]) {
        if object["results"] == nil, let content = object["content"] as? [Any], !content.isEmpty {
            object["results"] = content
            object.removeValue(forKey: "content")
        }
        if object["results"] == nil, let result = object["result"] as? [Any], !result.isEmpty {
            object["results"] = result
            object.removeValue(forKey: "result")
        }
    }

    private func searchArrayKey(forWrapper key: String) -> String {
        switch key {
        case "content", "result", "output", "response":
            "results"
        default:
            "results"
        }
    }

    private func searchTextKey(forWrapper key: String) -> String {
        switch key {
        case "response":
            "answer"
        case "output", "content", "result":
            "text"
        default:
            "text"
        }
    }

    private func toolIsError(from candidate: [String: Any]) -> Bool? {
        let typeRaw = normalizedTypeString(from: candidate)
        let debugToolName = normalizedToolName(from: candidate) ?? "unknown"
        let debugStatus = stringValue(from: candidate, keys: ["status"])?.lowercased() ?? "nil"
        let exitCode =
            intValue(candidate["exitCode"])
                ?? intValue(candidate["exit_code"])
                ?? intValue(candidate["code"])

        // Command wrappers can report -1 even when output is usable. Treat this as unknown.
        if let exitCode, exitCode < 0, typeRaw.contains("command") {
            Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=nil reason=negative-exit-code-command-wrapper exitCode=\(exitCode) status=\(debugStatus)")
            return nil
        }
        if let exitCode {
            if exitCode == 0 {
                Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=false reason=exitCode-zero status=\(debugStatus)")
                return false
            }
            if exitCode > 0 {
                Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=true reason=positive-exit-code exitCode=\(exitCode) status=\(debugStatus)")
                return true
            }
        }

        if let isError = boolValue(from: candidate, keys: ["isError", "is_error"]) {
            Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=\(isError) reason=explicit-isError status=\(debugStatus)")
            return isError
        }
        if let status = stringValue(from: candidate, keys: ["status"])?.lowercased() {
            if status == "error" || status == "failed" || status == "failure" {
                Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=true reason=status-failed status=\(status)")
                return true
            }
            if status == "ok" || status == "success" || status == "completed" {
                Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=false reason=status-success status=\(status)")
                return false
            }
        }
        if hasNonEmptyErrorSignal(in: candidate) {
            Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=true reason=error-payload status=\(debugStatus)")
            return true
        }
        if typeRaw.contains("command") || debugToolName == "bash" || debugToolName == "exec_command" {
            Self.logCodexDebug("[CodexNativeController] toolIsError tool=\(debugToolName) decision=nil reason=insufficient-signals status=\(debugStatus)")
        }
        return nil
    }

    private func hasNonEmptyErrorSignal(in candidate: [String: Any]) -> Bool {
        for key in ["error", "errors", "error_message", "errorMessage"] {
            guard let value = candidate[key] else { continue }
            if hasNonEmptyErrorValue(value) { return true }
        }
        return false
    }

    private func hasNonEmptyErrorValue(_ value: Any) -> Bool {
        if let text = value as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return array.contains { hasNonEmptyErrorValue($0) }
        }
        if let object = value as? [String: Any] {
            if object.isEmpty { return false }
            for key in ["message", "detail", "description", "code", "error", "error_message", "errorMessage"] {
                guard let nested = object[key] else { continue }
                if hasNonEmptyErrorValue(nested) { return true }
            }
            return object.values.contains { value in
                if value is [String: Any] || value is [Any] {
                    return hasNonEmptyErrorValue(value)
                }
                return false
            }
        }
        return false
    }

    private func stringValue(from candidate: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = candidate[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func rawStringValue(from candidate: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = candidate[key] as? String {
                return value
            }
        }
        return nil
    }

    private func boolValue(from candidate: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = candidate[key] as? Bool {
                return value
            }
        }
        return nil
    }

    private func jsonString(from value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return nil
    }

    private func toolDedupKey(
        itemID: String?,
        toolName: String,
        argsJSON: String?,
        resultJSON: String?
    ) -> String {
        if let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines), !itemID.isEmpty {
            return itemID
        }
        let argsPart = argsJSON ?? ""
        let resultPart = resultJSON ?? ""
        return "\(toolName)|\(argsPart)|\(resultPart)"
    }

    private func markToolEventEmitted(key: String) -> Bool {
        if emittedToolEventDedupKeys.contains(key) {
            return false
        }
        emittedToolEventDedupKeys.insert(key)
        return true
    }

    private static let commandExecutionMirrorStateTTL: TimeInterval = 30 * 60
    private static let maxCommandExecutionMirrorEntries = 512

    private func shouldAcceptCommandExecutionEvent(
        itemID: String?,
        family: CommandExecutionEventFamily,
        now: Date = Date()
    ) -> Bool {
        guard let trimmedItemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedItemID.isEmpty
        else {
            return true
        }
        pruneCommandExecutionMirrorState(now: now)
        if let existing = commandExecutionMirrorStateByItemID[trimmedItemID] {
            guard existing.family == family else {
                return false
            }
        }
        commandExecutionMirrorStateByItemID[trimmedItemID] = .init(
            family: family,
            lastSeenAt: now
        )
        return true
    }

    private func pruneCommandExecutionMirrorState(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.commandExecutionMirrorStateTTL)
        commandExecutionMirrorStateByItemID = commandExecutionMirrorStateByItemID.filter {
            $0.value.lastSeenAt >= cutoff
        }
        let overflow = commandExecutionMirrorStateByItemID.count - Self.maxCommandExecutionMirrorEntries
        guard overflow > 0 else { return }
        let oldestKeys = commandExecutionMirrorStateByItemID
            .sorted { lhs, rhs in
                lhs.value.lastSeenAt < rhs.value.lastSeenAt
            }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys {
            commandExecutionMirrorStateByItemID.removeValue(forKey: key)
        }
    }

    private func commandExecutionItemID(from params: [String: Any]) -> String? {
        for candidate in toolItemCandidates(from: params) {
            if let itemID = stringValue(from: candidate, keys: [
                "itemId", "item_id", "callId", "call_id", "id", "invocationId", "invocation_id"
            ]), !itemID.isEmpty {
                return itemID
            }
        }
        return nil
    }

    static func appServerTurnSandboxPolicyPayload(
        mode: CodexAgentToolPreferences.SandboxMode,
        workspacePath: String?
    ) -> [String: Any] {
        switch mode {
        case .readOnly:
            return ["type": "readOnly"]
        case .dangerFullAccess:
            return ["type": "dangerFullAccess"]
        case .workspaceWrite:
            var payload: [String: Any] = [
                "type": "workspaceWrite",
                "networkAccess": true
            ]
            if let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspacePath.isEmpty
            {
                payload["writableRoots"] = [workspacePath]
            }
            return payload
        }
    }

    static func defaultAppServerConfigOverrides(
        forceExperimentalSteering: Bool,
        approvalPolicy: CodexAgentToolPreferences.ApprovalPolicy? = nil,
        sandboxMode: CodexAgentToolPreferences.SandboxMode? = nil,
        approvalReviewer: CodexAgentToolPreferences.ApprovalReviewer? = nil,
        shellToolEnabled: Bool? = nil,
        suppressThirdPartyMCPServers: Bool = false,
        goalSupportEnabled: Bool = false,
        computerUseEnabled: Bool = false
    ) -> [String: Any] {
        let serverEntries = MCPIntegrationHelper.codexMCPServerEntries()
        let preferences = CodexAgentToolPreferences.snapshot(for: serverEntries)
        let toolPolicy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
            shellToolEnabled: shellToolEnabled ?? preferences.bashToolEnabled,
            webSearchRequestEnabled: preferences.searchToolEnabled,
            viewImageToolEnabled: true,
            // Best-effort only; native FileChange events are still the authoritative patch signal.
            includeApplyPatchTool: false,
            parallelToolCallsEnabled: false,
            multiAgentEnabled: false,
            experimentalSteeringEnabled: forceExperimentalSteering ? true : nil
        )
        var overrides = CodexOverrides.appServerConfigMap(
            toolPolicy: toolPolicy,
            featurePolicy: .resolved(goalsEnabled: goalSupportEnabled, computerUseEnabled: computerUseEnabled)
        )
        let mcpOverrides = appServerMCPServerOverrides(
            serverEntries: serverEntries,
            enabledMCPServerNames: preferences.enabledMCPServerNames,
            suppressThirdPartyMCPServers: suppressThirdPartyMCPServers,
            computerUseEnabled: computerUseEnabled
        )
        for (key, value) in mcpOverrides {
            overrides[key] = value
        }
        let effectiveApprovalPolicy = approvalPolicy ?? preferences.approvalPolicy
        let effectiveSandboxMode = sandboxMode ?? preferences.sandboxMode
        let effectiveApprovalReviewer = approvalReviewer ?? preferences.approvalReviewer
        overrides["approval_policy"] = effectiveApprovalPolicy.appServerConfigOverrideValue
        overrides["sandbox_mode"] = effectiveSandboxMode.appServerConfigOverrideValue
        overrides["approvals_reviewer"] = effectiveApprovalReviewer.appServerConfigOverrideValue
        return overrides
    }

    static func appServerMCPServerOverrides(
        serverEntries: [MCPIntegrationHelper.CodexServerEntry],
        enabledMCPServerNames: Set<String>,
        suppressThirdPartyMCPServers: Bool,
        computerUseEnabled: Bool
    ) -> [String: Any] {
        var effectiveEnabledNames = suppressThirdPartyMCPServers
            ? Set([MCPIntegrationHelper.repoPromptMCPServerName])
            : enabledMCPServerNames
        if computerUseEnabled,
           serverEntries.contains(where: {
               $0.normalizedName.caseInsensitiveCompare(Self.computerUseMCPServerName) == .orderedSame
           })
        {
            effectiveEnabledNames.insert(Self.computerUseMCPServerName)
        }
        return CodexOverrides.appServerMCPServerMap(
            entries: serverEntries,
            policy: .enableSelected(
                enabledNormalizedNames: effectiveEnabledNames,
                repoPromptNormalizedName: MCPIntegrationHelper.repoPromptMCPServerName,
                exceptBroken: []
            )
        )
    }
}

extension CodexNativeSessionController: CodexSessionControlling {}

enum CommandExecutionOutputSanitizer {
    private static let escapeChar = "\u{001B}"
    private static let csiRegex = try! NSRegularExpression(
        pattern: #"(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]"#,
        options: []
    )
    private static let oscRegex = try! NSRegularExpression(
        pattern: #"\x1B\][\s\S]*?(?:\x07|\x1B\\)"#,
        options: []
    )
    private static let dcsRegex = try! NSRegularExpression(
        pattern: #"\x1B[P^_X][\s\S]*?\x1B\\"#,
        options: []
    )
    private static let singleEscapeRegex = try! NSRegularExpression(
        pattern: #"\x1B[@-Z\\-_]"#,
        options: []
    )

    static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        guard requiresSanitization(raw) else { return raw }
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = stripEscapeSequences(text)
        text = applyBackspaces(text)
        text = applyCarriageReturnOverwrite(text)
        text = stripUnwantedControlScalars(text)
        return text
    }

    private static func stripEscapeSequences(_ input: String) -> String {
        guard input.contains(escapeChar) || input.contains("\u{009B}") else { return input }
        let fullRange = NSRange(input.startIndex ..< input.endIndex, in: input)
        var output = csiRegex.stringByReplacingMatches(in: input, options: [], range: fullRange, withTemplate: "")
        let rangeAfterCSI = NSRange(output.startIndex ..< output.endIndex, in: output)
        output = oscRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterCSI, withTemplate: "")
        let rangeAfterOSC = NSRange(output.startIndex ..< output.endIndex, in: output)
        output = dcsRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterOSC, withTemplate: "")
        let rangeAfterDCS = NSRange(output.startIndex ..< output.endIndex, in: output)
        output = singleEscapeRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterDCS, withTemplate: "")
        return output
    }

    private static func requiresSanitization(_ input: String) -> Bool {
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x1B, 0x9B, 0x08, 0x0D:
                return true
            case 0x00 ... 0x1F where scalar.value != 0x09 && scalar.value != 0x0A:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func applyBackspaces(_ input: String) -> String {
        guard input.contains("\u{0008}") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            if scalar.value == 0x08 {
                if !output.isEmpty {
                    output.removeLast()
                }
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    private static func applyCarriageReturnOverwrite(_ input: String) -> String {
        guard input.contains("\r") else { return input }
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let rewritten = lines.map { line -> String in
            guard let segment = line.split(separator: "\r", omittingEmptySubsequences: false).last else { return "" }
            return String(segment)
        }
        return rewritten.joined(separator: "\n")
    }

    private static func stripUnwantedControlScalars(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                output.unicodeScalars.append(scalar)
            case 0x20 ... 0x10FFFF:
                output.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        return output
    }
}

enum CodexSessionControllerError: LocalizedError {
    case imageAttachmentsUnsupported
    case emptyUserTurn
    case invalidLifecycleState(String)

    var errorDescription: String? {
        switch self {
        case .imageAttachmentsUnsupported:
            "This Codex session controller does not support image attachments."
        case .emptyUserTurn:
            "Cannot send an empty user turn."
        case let .invalidLifecycleState(description):
            "This Codex session controller cannot be started because it is \(description). Create a new controller instance."
        }
    }
}

extension CodexSessionControlling {
    func prepareLifecycleAuthorityReconciliationAfterAcceptedMismatch(
        expectedCurrentTurnID _: String,
        acceptedDispatchTurnID _: String
    ) async -> Bool {
        true
    }

    func readThreadSnapshot(
        includeTurns _: Bool,
        timeout _: TimeInterval?
    ) async throws -> CodexNativeSessionController.ThreadSnapshot {
        assertionFailure("\(type(of: self)) must implement readThreadSnapshot(includeTurns:timeout:)")
        throw CodexAppServerClient.ClientError.invalidResponse
    }

    func setThreadName(_: String, threadID _: String?) async throws {}

    func reconcileAndInterruptCurrentTurn() async throws -> CodexTurnInterruptReceipt {
        await cancelCurrentTurn()
        return CodexTurnInterruptReceipt(interruptedTurnID: "<legacy-cancel>")
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(existing: existing, baseInstructions: baseInstructions)
    }

    func startOrResume(
        existing: CodexNativeSessionController.SessionRef?,
        baseInstructions: String,
        model: String?,
        reasoningEffort: String?,
        serviceTier _: String?
    ) async throws -> CodexNativeSessionController.SessionRef {
        try await startOrResume(
            existing: existing,
            baseInstructions: baseInstructions,
            model: model,
            reasoningEffort: reasoningEffort
        )
    }

    func compactThread() async throws {
        assertionFailure("\(type(of: self)) must implement compactThread()")
        throw CodexAppServerClient.ClientError.invalidResponse
    }

    func getThreadGoal() async throws -> CodexNativeSessionController.ThreadGoal? {
        assertionFailure("\(type(of: self)) must implement getThreadGoal()")
        throw CodexAppServerClient.ClientError.invalidResponse
    }

    func setThreadGoalObjective(_: String) async throws -> CodexNativeSessionController.ThreadGoal {
        assertionFailure("\(type(of: self)) must implement setThreadGoalObjective(_:)")
        throw CodexAppServerClient.ClientError.invalidResponse
    }

    func setThreadGoalStatus(_: CodexNativeSessionController.ThreadGoalStatus) async throws -> CodexNativeSessionController.ThreadGoal {
        assertionFailure("\(type(of: self)) must implement setThreadGoalStatus(_:)")
        throw CodexAppServerClient.ClientError.invalidResponse
    }

    func clearThreadGoal() async throws -> Bool {
        assertionFailure("\(type(of: self)) must implement clearThreadGoal()")
        throw CodexAppServerClient.ClientError.invalidResponse
    }
}
