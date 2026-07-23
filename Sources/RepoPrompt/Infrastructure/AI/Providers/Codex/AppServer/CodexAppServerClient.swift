import Darwin
import Darwin.POSIX.fcntl
import Foundation

enum CodexJSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    func toAny() -> Any {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value
        case let .bool(value):
            value
        case let .object(value):
            value.mapValues { $0.toAny() }
        case let .array(value):
            value.map { $0.toAny() }
        case .null:
            NSNull()
        }
    }

    static func from(_ value: Any) -> CodexJSONValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let dict as [String: Any]:
            var output: [String: CodexJSONValue] = [:]
            for (key, value) in dict {
                if let converted = CodexJSONValue.from(value) {
                    output[key] = converted
                }
            }
            return .object(output)
        case let array as [Any]:
            let converted = array.compactMap { CodexJSONValue.from($0) }
            return .array(converted)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

enum CodexAppServerRequestID: Hashable {
    case int(Int)
    case string(String)

    init?(raw: Any) {
        if let value = raw as? Int {
            self = .int(value)
            return
        }
        if let value = raw as? NSNumber {
            self = .int(value.intValue)
            return
        }
        if let value = raw as? String {
            self = .string(value)
            return
        }
        return nil
    }

    var jsonValue: Any {
        switch self {
        case let .int(value): value
        case let .string(value): value
        }
    }

    var displayValue: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}

actor CodexAppServerClient {
    struct RequestFailure: Equatable {
        let method: String
        let code: Int?
        let message: String
        let data: CodexJSONValue?

        var userFacingMessage: String {
            guard ["initialize", "thread/resume"].contains(method),
                  code == -32601 || code == -32602
            else {
                return message
            }
            return "\(message) The active Codex runtime rejected RepoPrompt's required \(method) request shape. Reinstall or update RepoPrompt CE; if REPOPROMPT_CODEX_EXECUTABLE is set, update or remove that explicit override."
        }
    }

    struct RemoteReasoningEffort: Hashable {
        let reasoningEffort: String
        let description: String
    }

    struct RemoteModel: Hashable {
        let id: String
        let model: String
        let displayName: String
        let description: String
        let isDefault: Bool
        let supportedReasoningEfforts: [RemoteReasoningEffort]
        let defaultReasoningEffort: String?
    }

    struct ServerRequest {
        let id: CodexAppServerRequestID
        let method: String
        let params: [String: CodexJSONValue]
    }

    struct Config {
        let commandName: String
        let additionalPathHints: [String]
        let enableDebugLogging: Bool
        let requestTimeout: TimeInterval?
        /// Launch directory for the Codex app-server process. Distinct from the thread/turn
        /// execution cwd, which the controller sends per request.
        /// When nil, falls back to temp directory via CLIProcessConfiguration default.
        private(set) var processLaunchDirectory: String?
        private(set) var processFeaturePolicy: CodexOverrides.FeaturePolicy
        /// Process-level `model_reasoning_summary` override for app-server launch.
        /// Nil preserves Codex CLI process defaults; pass a value only for an intentional process override.
        /// Agent Mode should prefer per-thread config instead of process launch config.
        private(set) var processModelReasoningSummary: CodexOverrides.ReasoningSummary?

        init(
            commandName: String = CLILaunchProfiles.codex.commandName,
            additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
            enableDebugLogging: Bool = false,
            requestTimeout: TimeInterval? = nil,
            processLaunchDirectory: String? = nil,
            processFeaturePolicy: CodexOverrides.FeaturePolicy = .defaultDisabled,
            processModelReasoningSummary: CodexOverrides.ReasoningSummary? = nil
        ) {
            self.commandName = commandName
            self.additionalPathHints = additionalPathHints
            self.enableDebugLogging = enableDebugLogging
            self.requestTimeout = requestTimeout
            self.processLaunchDirectory = processLaunchDirectory
            self.processFeaturePolicy = processFeaturePolicy
            self.processModelReasoningSummary = processModelReasoningSummary
        }

        mutating func replaceProcessLaunchDirectory(_ path: String?) {
            processLaunchDirectory = path
        }

        mutating func replaceProcessLaunchPolicy(
            featurePolicy: CodexOverrides.FeaturePolicy,
            modelReasoningSummary: CodexOverrides.ReasoningSummary?
        ) {
            processFeaturePolicy = featurePolicy
            processModelReasoningSummary = modelReasoningSummary
        }
    }

    struct Notification {
        let method: String
        let params: [String: CodexJSONValue]
    }

    struct ProcessExitEvidence: Equatable {
        let executablePath: String
        let launchDirectory: String
        let pid: pid_t
        let status: ProcessExitStatus
        let stderrTail: Data
        let stderrWasTruncated: Bool
        let stderrWasSettled: Bool
    }

    enum ClientError: Error, LocalizedError {
        case processNotRunning
        case processExited(ProcessExitEvidence)
        case invalidResponse
        case jsonDecodeFailed
        case requestFailed(RequestFailure)
        case executableUnavailable(String)
        case transportWriteFailed(message: String, errno: Int32?)
        case transportReadSetupFailed(message: String, errno: Int32?)

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                "Codex app-server process is not running."
            case let .processExited(evidence):
                Self.processExitDescription(evidence)
            case .invalidResponse:
                "Codex app-server returned an invalid response."
            case .jsonDecodeFailed:
                "Failed to decode Codex app-server JSON response."
            case let .requestFailed(failure):
                failure.userFacingMessage
            case let .executableUnavailable(message):
                message
            case let .transportWriteFailed(message, _):
                message
            case let .transportReadSetupFailed(message, _):
                message
            }
        }

        private static func processExitDescription(_ evidence: ProcessExitEvidence) -> String {
            let outcome = switch evidence.status {
            case let .exited(code):
                "exited with status \(code)"
            case let .uncaughtSignal(signal):
                "terminated from signal \(signal)"
            }
            var description = "Codex app-server \(outcome) while running \(evidence.executablePath) in \(evidence.launchDirectory)."
            if !evidence.stderrTail.isEmpty {
                let stderr = String(decoding: evidence.stderrTail, as: UTF8.self)
                let suffix = evidence.stderrWasTruncated ? " (tail truncated)" : ""
                description += " stderr\(suffix): \(stderr)"
            }
            if !evidence.stderrWasSettled {
                description += " Stderr capture did not settle after bounded process-family cleanup."
            }
            return description
        }
    }

    enum TransportTerminationReason: Equatable {
        case stdinWrite(method: String?, errno: Int32?)
        case stdoutEOF
        case timeout(method: String, requestID: String)
        case explicitStop
        case livenessCheckFailed(method: String?)
        case decodeRecoveryBudgetExceeded(generation: UInt64)
        case readSourceSetupFailed(stream: String, errno: Int32?)
        case observedProcessExit(status: ProcessExitStatus)
    }

    struct ExpectedAgentPIDRegistration: Equatable {
        let clientName: String
        let runID: UUID
    }

    struct ExpectedAgentPIDRegistrar {
        let register: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
        let clear: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void

        static let serverNetworkManager = ExpectedAgentPIDRegistrar(
            register: { pid, clientName, runID in
                await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
            },
            clear: { pid, clientName, runID in
                await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            }
        )
    }

    private struct RegisteredExpectedAgentPID: Equatable {
        let pid: pid_t
        let clientName: String
        let runID: UUID
    }

    private struct PendingRequestMetadata {
        let method: String
        let transportGeneration: UInt64
    }

    private struct ExitObservation {
        let observer: ChildProcessExitObserver
        let executablePath: String
        let launchDirectory: String
        let stderrCapture: CodexProcessStderrCapture
    }

    private struct ActiveTransport {
        let generation: UInt64
        let process: SpawnedProcess
        let exitObservation: ExitObservation?
    }

    private struct PreparedRuntimeLaunchContext {
        let environment: [String: String]
        let resolution: CodexProviderHelpers.CodexExecutableResolution
    }

    private struct TerminatingTransport {
        let activeTransport: ActiveTransport?
        let expectedAgentPIDToClear: RegisteredExpectedAgentPID?
        let processFamilyCleanupWasCompleted: Bool
    }

    static func isTimeoutError(_ error: Error) -> Bool {
        if let clientError = error as? ClientError,
           case let .requestFailed(failure) = clientError
        {
            return isTimeoutErrorMessage(failure.message)
        }

        let nsError = error as NSError
        let candidates = [
            error.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ].compactMap(\.self)
        return candidates.contains(where: isTimeoutErrorMessage)
    }

    private static func isTimeoutErrorMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("request timed out after")
            || normalized.contains("timed out after")
    }

    static func requestFailure(
        method: String,
        errorObject: [String: Any]
    ) -> RequestFailure? {
        guard let message = errorObject["message"] as? String else { return nil }
        let code: Int? = if let value = errorObject["code"] as? Int {
            value
        } else if let value = errorObject["code"] as? NSNumber {
            value.intValue
        } else {
            nil
        }
        return RequestFailure(
            method: method,
            code: code,
            message: message,
            data: errorObject["data"].flatMap(CodexJSONValue.from)
        )
    }

    private static func shouldPoisonTransportOnTimeout(method: String) -> Bool {
        switch method {
        case "thread/start", "thread/resume":
            true
        default:
            false
        }
    }

    private var config = Config()
    private var activeTransport: ActiveTransport?
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestMetadata: [String: PendingRequestMetadata] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var nextRequestID: Int = 1
    private var notificationContinuations: [UUID: AsyncStream<Notification>.Continuation] = [:]
    private var serverRequestContinuations: [UUID: AsyncStream<ServerRequest>.Continuation] = [:]
    private var isInitialized = false
    private var stdoutFramer = LineFramer()
    private var stdoutTail = Data()
    private var didTerminateTransport = false
    private var lastTransportTerminationReason: TransportTerminationReason?
    private var lastTransportFailure: ClientError?
    private var transportTerminationTask: (generation: UInt64, task: Task<Void, Never>)?
    /// Per-transport decode-recovery attempts, used to cap CPU spent on malformed lines.
    private var decodeRecoveryAttemptsByGeneration: [UInt64: Int] = [:]
    /// Monotonic counter incremented each time a new process is started.
    /// Captured by consumer tasks and stdin-failure teardown to scope teardown
    /// to the correct transport instance — prevents a stale task from killing a
    /// newly started process.
    private var transportGeneration: UInt64 = 0
    /// Actor-confined authority for startup work. Explicit or emergency shutdown
    /// revokes every invocation that began before the shutdown request.
    private var startupAuthorityEpoch: UInt64 = 0
    private var startupTask: (id: UUID, task: Task<Void, Error>)?
    private var expectedAgentPIDRegistration: ExpectedAgentPIDRegistration?
    private var registeredExpectedAgentPID: RegisteredExpectedAgentPID?
    private var preparedRuntimeLaunchContext: PreparedRuntimeLaunchContext?
    private static let maxDecodeRecoveryAttemptsPerGeneration = 128
    private static let stderrTailLimit = 8 * 1024
    private static let exitDiagnosticSettlementWindow: TimeInterval = 0.25
    private let writeFrameHandler: @Sendable (Int32, Data) throws -> Void
    private let livenessProbe: @Sendable (SpawnedProcess) -> Bool
    private let processSpawnPreparation: @Sendable () async throws -> Void
    private let processEnvironmentBuilder: @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult
    private let provisionsRepoPromptMCPOnStart: Bool
    private let processExitObserverFactory: @Sendable (pid_t) -> ChildProcessExitObserver
    private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar
    #if DEBUG
        private var terminalObserverJoinCount = 0
    #endif

    deinit {
        emergencyTerminateTransportForDeinit()
    }

    init(
        writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { descriptor, frame in
            try FDWriteSupport.writeAll(frame, to: descriptor)
        },
        livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { process in
            CodexAppServerClient.defaultProcessAppearsAlive(process)
        },
        processSpawnPreparation: @escaping @Sendable () async throws -> Void = {},
        processEnvironmentBuilder: @escaping @Sendable (ProcessEnvironmentRequest) async -> ProcessEnvironmentResult = {
            await ProcessEnvironmentBuilder.build($0)
        },
        provisionsRepoPromptMCPOnStart: Bool = true,
        processExitObserverFactory: @escaping @Sendable (pid_t) -> ChildProcessExitObserver = {
            ChildProcessExitObserver(pid: $0)
        },
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .serverNetworkManager
    ) {
        self.writeFrameHandler = writeFrameHandler
        self.livenessProbe = livenessProbe
        self.processSpawnPreparation = processSpawnPreparation
        self.processEnvironmentBuilder = processEnvironmentBuilder
        self.provisionsRepoPromptMCPOnStart = provisionsRepoPromptMCPOnStart
        self.processExitObserverFactory = processExitObserverFactory
        self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar
    }

    func updateConfig(_ config: Config) {
        self.config = config
        preparedRuntimeLaunchContext = nil
    }

    /// Resolves the process environment and Codex runtime once for this client lifetime.
    /// Native Agent Mode calls this before MCP provisioning, then `startIfNeeded()` reuses
    /// the same captured launch context instead of consulting a second environment snapshot.
    func prepareRuntimeForLaunch() async throws -> CodexRuntimeAuthority.Runtime {
        if let runtime = preparedRuntimeLaunchContext?.resolution.runtime {
            return runtime
        }

        let environmentResult = await processEnvironmentBuilder(
            ProcessEnvironmentRequest(
                purpose: .codexAppServer,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        var environment = environmentResult.environment
        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: config.commandName,
            environment: environment,
            additionalPathHints: config.additionalPathHints,
            logger: config.enableDebugLogging ? { print("[CodexAppServer] \($0)") } : nil
        )
        guard resolution.status == .available else {
            throw ClientError.executableUnavailable(resolution.userMessage)
        }
        guard let runtime = resolution.runtime else {
            throw ClientError.executableUnavailable("RepoPrompt could not start Codex: runtime resolution completed without runtime metadata.")
        }
        do {
            try runtime.prepareState()
        } catch {
            throw ClientError.executableUnavailable(
                "RepoPrompt could not start Codex: unable to prepare its isolated state directories (\(error.localizedDescription))."
            )
        }
        environment.merge(resolution.environmentOverrides) { _, ownedValue in ownedValue }
        preparedRuntimeLaunchContext = PreparedRuntimeLaunchContext(
            environment: environment,
            resolution: resolution
        )
        return runtime
    }

    func setExpectedAgentPIDRegistration(_ registration: ExpectedAgentPIDRegistration?) async {
        expectedAgentPIDRegistration = registration
        guard registration != nil else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        guard let activeTransport else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        await registerExpectedAgentPIDIfNeeded(for: activeTransport.process.pid)
    }

    func clearExpectedAgentPIDRegistration() async {
        expectedAgentPIDRegistration = nil
        await clearRegisteredExpectedAgentPIDIfNeeded()
    }

    private func registerExpectedAgentPIDIfNeeded(for pid: pid_t) async {
        guard !didTerminateTransport,
              let registration = expectedAgentPIDRegistration
        else {
            return
        }
        let target = RegisteredExpectedAgentPID(
            pid: pid,
            clientName: registration.clientName,
            runID: registration.runID
        )
        guard registeredExpectedAgentPID != target else { return }
        await clearRegisteredExpectedAgentPIDIfNeeded()
        guard expectedAgentPIDRegistration == registration, activeTransport?.process.pid == pid else { return }
        registeredExpectedAgentPID = target
        await expectedAgentPIDRegistrar.register(target.pid, target.clientName, target.runID)
        guard expectedAgentPIDRegistration == registration, activeTransport?.process.pid == pid else {
            if registeredExpectedAgentPID == target {
                registeredExpectedAgentPID = nil
            }
            await expectedAgentPIDRegistrar.clear(target.pid, target.clientName, target.runID)
            return
        }
    }

    private func clearRegisteredExpectedAgentPIDIfNeeded() async {
        guard let registered = takeRegisteredExpectedAgentPIDForDeferredClear() else { return }
        await expectedAgentPIDRegistrar.clear(registered.pid, registered.clientName, registered.runID)
    }

    private func takeRegisteredExpectedAgentPIDForDeferredClear() -> RegisteredExpectedAgentPID? {
        let registered = registeredExpectedAgentPID
        registeredExpectedAgentPID = nil
        return registered
    }

    /// Updates the process launch directory for the next process start.
    /// Must be called before `startIfNeeded()` to take effect.
    func updateProcessLaunchDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        config.replaceProcessLaunchDirectory(normalized)
    }

    func updateProcessFeaturePolicy(_ featurePolicy: CodexOverrides.FeaturePolicy) async {
        await updateProcessLaunchPolicy(
            featurePolicy: featurePolicy,
            modelReasoningSummary: config.processModelReasoningSummary
        )
    }

    func updateProcessLaunchPolicy(
        featurePolicy: CodexOverrides.FeaturePolicy,
        modelReasoningSummary: CodexOverrides.ReasoningSummary?
    ) async {
        guard featurePolicy != config.processFeaturePolicy
            || modelReasoningSummary != config.processModelReasoningSummary
        else { return }
        config.replaceProcessLaunchPolicy(
            featurePolicy: featurePolicy,
            modelReasoningSummary: modelReasoningSummary
        )
        if activeTransport != nil {
            await terminateTransport(flushStdout: true, reason: .explicitStop)
        }
    }

    func subscribeNotifications() -> AsyncStream<Notification> {
        AsyncStream { continuation in
            let id = UUID()
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNotificationContinuation(id) }
            }
        }
    }

    func subscribeServerRequests() -> AsyncStream<ServerRequest> {
        AsyncStream { continuation in
            let id = UUID()
            serverRequestContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeServerRequestContinuation(id) }
            }
        }
    }

    func startIfNeeded() async throws {
        let authority = startupAuthorityEpoch
        if let termination = transportTerminationTask,
           termination.generation == transportGeneration
        {
            await termination.task.value
            try ensureStartupAuthority(authority)
        }
        if let existingStartupTask = startupTask?.task {
            return try await existingStartupTask.value
        }
        if let activeTransport {
            let appearsAlive = livenessProbe(activeTransport.process)
            if isInitialized, appearsAlive {
                return
            }
            if !appearsAlive {
                await settleObservationalTermination(
                    generation: activeTransport.generation,
                    flushStdout: false,
                    fallbackReason: .livenessCheckFailed(method: nil)
                )
                try ensureStartupAuthority(authority)
            }
        }
        try ensureStartupAuthority(authority)
        let startupID = UUID()
        let task = Task<Void, Error> {
            try await self.performStartupIfNeeded(startupAuthority: authority)
        }
        startupTask = (id: startupID, task: task)
        do {
            try await task.value
            if startupTask?.id == startupID {
                startupTask = nil
            }
        } catch {
            if startupTask?.id == startupID {
                startupTask = nil
            }
            throw error
        }
    }

    func stop() async {
        startupAuthorityEpoch &+= 1
        startupTask?.task.cancel()
        startupTask = nil
        if let termination = transportTerminationTask,
           termination.generation == transportGeneration
        {
            await termination.task.value
            return
        }
        await terminateTransport(flushStdout: true, reason: .explicitStop)
    }

    // MARK: - Authoritative transport termination

    /// Single, idempotent teardown path for the process transport layer.
    ///
    /// Called from `handleStdoutEOF()` (EOF detected on stdout) and `stop()` (explicit shutdown).
    /// Responsible for: flushing remaining stdout, cancelling consumer tasks, failing all
    /// pending requests, finishing all notification/serverRequest subscriber continuations,
    /// and cleaning up the process. Idempotent via `didTerminateTransport` flag.
    ///
    /// Note: `flushStdout` is best-effort; buffered channel bytes that have not yet been
    /// fed into `stdoutFramer` may still be dropped during teardown.
    ///
    /// When `expectedGeneration` is provided, the call is a no-op if the current
    /// `transportGeneration` doesn't match — this prevents a stale consumer task
    /// from tearing down a newly-started transport.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.handleStdoutEOF / shutdown (reference implementation)
    /// - FileHandleChunkChannel (FIFO chunk ordering)
    /// - CodexNativeSessionController.startNotificationStreamIfNeeded (downstream subscriber)
    private func terminateTransport(
        flushStdout: Bool,
        expectedGeneration: UInt64? = nil,
        requestFailure: ClientError = .processNotRunning,
        reason: TransportTerminationReason
    ) async {
        let task = beginTransportTermination(
            flushStdout: flushStdout,
            expectedGeneration: expectedGeneration,
            requestFailure: requestFailure,
            reason: reason
        )
        await task?.value
    }

    @discardableResult
    private func beginTransportTermination(
        flushStdout: Bool,
        expectedGeneration: UInt64? = nil,
        requestFailure: ClientError,
        reason: TransportTerminationReason
    ) -> Task<Void, Never>? {
        if let expectedGeneration, expectedGeneration != transportGeneration { return nil }
        let generation = transportGeneration
        return installTransportTermination(
            generation: generation,
            reason: reason,
            captureAfterClaim: { lastTransportFailure = requestFailure },
            operation: { client, _ in
                await client.completeTransportTermination(
                    generation: generation,
                    flushStdout: flushStdout,
                    requestFailure: requestFailure
                )
            }
        )
    }

    private func beginObservedProcessExitTermination(
        status: ProcessExitStatus,
        observer: ChildProcessExitObserver,
        generation: UInt64
    ) -> Task<Void, Never>? {
        guard let activeTransport,
              activeTransport.generation == generation,
              activeTransport.exitObservation?.observer === observer,
              activeTransport.process.pid == observer.pid
        else {
            return nil
        }
        return installTransportTermination(
            generation: generation,
            reason: .observedProcessExit(status: status),
            captureAfterClaim: { takeRegisteredExpectedAgentPIDForDeferredClear() },
            operation: { client, expectedAgentPIDToClear in
                await client.completeObservedProcessExitTermination(
                    status: status,
                    observer: observer,
                    generation: generation,
                    expectedAgentPIDToClear: expectedAgentPIDToClear
                )
            }
        )
    }

    /// Shared first-claim arbitration for every transport-termination origin:
    /// same-generation task reuse, the terminal-cause claim, post-claim state
    /// capture, and termination-task publication happen identically here so a
    /// new termination cause cannot skip or reorder any step of the protocol.
    private func installTransportTermination<ClaimContext: Sendable>(
        generation: UInt64,
        reason: TransportTerminationReason,
        captureAfterClaim: () -> ClaimContext,
        operation: @escaping @Sendable (CodexAppServerClient, ClaimContext) async -> Void
    ) -> Task<Void, Never>? {
        if let existing = transportTerminationTask,
           existing.generation == generation
        {
            return existing.task
        }
        guard claimTransportTermination(reason: reason) else { return nil }
        let claimContext = captureAfterClaim()
        let task = Task { [weak self] in
            guard let self else { return }
            await operation(self, claimContext)
        }
        transportTerminationTask = (generation: generation, task: task)
        return task
    }

    private func claimTransportTermination(reason: TransportTerminationReason) -> Bool {
        guard !didTerminateTransport else { return false }
        didTerminateTransport = true
        isInitialized = false
        lastTransportTerminationReason = reason
        return true
    }

    private func completeTransportTermination(
        generation: UInt64,
        flushStdout: Bool,
        requestFailure: ClientError
    ) async {
        guard generation == transportGeneration else { return }
        defer { retireTransportTermination(generation: generation) }
        await finishTransportTermination(
            invalidateClaimedTransport(
                flushStdout: flushStdout,
                requestFailure: requestFailure
            )
        )
    }

    private func invalidateClaimedTransport(
        flushStdout: Bool,
        requestFailure: ClientError,
        processFamilyCleanupWasCompleted: Bool = false
    ) -> TerminatingTransport {
        if flushStdout {
            var remainingLines: [Data] = []
            stdoutFramer.flush { lineData in
                remainingLines.append(lineData)
            }
            for lineData in remainingLines {
                handleJSONLine(lineData)
            }
        }

        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        activeTransport?.exitObservation?.stderrCapture.finish()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil

        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        let requests = pendingRequests
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: requestFailure)
        }

        let notifContinuations = notificationContinuations
        notificationContinuations.removeAll()
        for continuation in notifContinuations.values {
            continuation.finish()
        }

        let serverReqContinuations = serverRequestContinuations
        serverRequestContinuations.removeAll()
        for continuation in serverReqContinuations.values {
            continuation.finish()
        }

        let terminatingTransport = TerminatingTransport(
            activeTransport: activeTransport,
            expectedAgentPIDToClear: takeRegisteredExpectedAgentPIDForDeferredClear(),
            processFamilyCleanupWasCompleted: processFamilyCleanupWasCompleted
        )
        activeTransport = nil

        stdoutFramer = LineFramer()
        stdoutTail.removeAll(keepingCapacity: false)
        decodeRecoveryAttemptsByGeneration.removeValue(forKey: transportGeneration)
        return terminatingTransport
    }

    private func settleObservationalTermination(
        generation: UInt64,
        flushStdout: Bool,
        fallbackReason: TransportTerminationReason
    ) async {
        guard generation == transportGeneration else { return }
        if let existing = transportTerminationTask,
           existing.generation == generation
        {
            await existing.task.value
            return
        }
        if let activeTransport,
           activeTransport.generation == generation,
           let observer = activeTransport.exitObservation?.observer
        {
            if let outcome = await observer.wait(timeout: Self.exitDiagnosticSettlementWindow) {
                await handleObservedProcessExit(
                    outcome,
                    observer: observer,
                    generation: generation
                )
                return
            }

            // A terminal root can race the bounded diagnostic wait without
            // making a reused-PID signal safe. Join the sole observer so its
            // typed exit survives; waitid remains non-destructive.
            if ProcessTermination.childIsTerminalOrAlreadyReaped(activeTransport.process.pid) {
                #if DEBUG
                    terminalObserverJoinCount += 1
                #endif
                if let outcome = await observer.wait() {
                    await handleObservedProcessExit(
                        outcome,
                        observer: observer,
                        generation: generation
                    )
                    return
                }
            }
        }
        await terminateTransport(
            flushStdout: flushStdout,
            expectedGeneration: generation,
            reason: fallbackReason
        )
    }

    private func handleObservedProcessExit(
        _ outcome: ChildProcessExitObserver.Outcome,
        observer: ChildProcessExitObserver,
        generation: UInt64
    ) async {
        guard let activeTransport,
              activeTransport.generation == generation,
              activeTransport.exitObservation?.observer === observer,
              activeTransport.process.pid == observer.pid
        else {
            return
        }
        let task: Task<Void, Never>? = switch outcome {
        case let .exited(status):
            beginObservedProcessExitTermination(
                status: status,
                observer: observer,
                generation: generation
            )
        case .failed:
            beginTransportTermination(
                flushStdout: true,
                expectedGeneration: generation,
                requestFailure: .processNotRunning,
                reason: .livenessCheckFailed(method: nil)
            )
        }
        await task?.value
    }

    private func completeObservedProcessExitTermination(
        status: ProcessExitStatus,
        observer: ChildProcessExitObserver,
        generation: UInt64,
        expectedAgentPIDToClear: RegisteredExpectedAgentPID?
    ) async {
        defer { retireTransportTermination(generation: generation) }
        if let expectedAgentPIDToClear {
            await expectedAgentPIDRegistrar.clear(
                expectedAgentPIDToClear.pid,
                expectedAgentPIDToClear.clientName,
                expectedAgentPIDToClear.runID
            )
        }
        guard let transport = activeTransport,
              transport.generation == generation,
              let exitObservation = transport.exitObservation,
              exitObservation.observer === observer,
              transport.process.pid == observer.pid
        else {
            return
        }
        let logger: (String) -> Void = config.enableDebugLogging
            ? { print("[CodexAppServer] \($0)") }
            : { _ in }
        await ProcessTermination.terminateObservedProcessFamily(
            observer: observer,
            processGroupID: transport.process.processGroupID,
            logger: logger
        )
        let stderrWasSettled = await exitObservation.stderrCapture.waitUntilFinished(
            timeout: Self.exitDiagnosticSettlementWindow
        )
        guard let currentTransport = activeTransport,
              currentTransport.generation == generation,
              currentTransport.exitObservation?.observer === observer,
              currentTransport.process.pid == observer.pid
        else {
            return
        }

        let stderr = exitObservation.stderrCapture.snapshot()
        let evidence = ProcessExitEvidence(
            executablePath: exitObservation.executablePath,
            launchDirectory: exitObservation.launchDirectory,
            pid: observer.pid,
            status: status,
            stderrTail: stderr.bytes,
            stderrWasTruncated: stderr.wasTruncated,
            stderrWasSettled: stderrWasSettled
        )
        lastTransportFailure = .processExited(evidence)
        await finishTransportTermination(
            invalidateClaimedTransport(
                flushStdout: true,
                requestFailure: .processExited(evidence),
                processFamilyCleanupWasCompleted: true
            )
        )
    }

    private func retireTransportTermination(generation: UInt64) {
        guard transportTerminationTask?.generation == generation else { return }
        transportTerminationTask = nil
    }

    private func emergencyTerminateTransportForDeinit() {
        startupAuthorityEpoch &+= 1
        startupTask?.task.cancel()
        startupTask = nil
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        let requests = pendingRequests
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: ClientError.processNotRunning)
        }
        for continuation in notificationContinuations.values {
            continuation.finish()
        }
        notificationContinuations.removeAll()
        for continuation in serverRequestContinuations.values {
            continuation.finish()
        }
        serverRequestContinuations.removeAll()
        let expectedAgentPIDToClear = registeredExpectedAgentPID
        registeredExpectedAgentPID = nil
        if let expectedAgentPIDToClear {
            let registrar = expectedAgentPIDRegistrar
            Task.detached {
                await registrar.clear(
                    expectedAgentPIDToClear.pid,
                    expectedAgentPIDToClear.clientName,
                    expectedAgentPIDToClear.runID
                )
            }
        }
        guard let activeTransport else { return }
        self.activeTransport = nil
        activeTransport.exitObservation?.stderrCapture.finish()
        let process = activeTransport.process
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdin?.closeFile()
        Task.detached {
            if let observer = activeTransport.exitObservation?.observer {
                await ProcessTermination.terminateObservedProcessFamily(
                    observer: observer,
                    processGroupID: process.processGroupID
                )
            } else {
                _ = await ProcessTermination.terminateAndReap(
                    pid: process.pid,
                    processGroupID: process.processGroupID
                )
            }
        }
    }

    private func finishTransportTermination(_ terminatingTransport: TerminatingTransport?) async {
        guard let terminatingTransport else { return }
        if let expectedAgentPIDToClear = terminatingTransport.expectedAgentPIDToClear {
            await expectedAgentPIDRegistrar.clear(
                expectedAgentPIDToClear.pid,
                expectedAgentPIDToClear.clientName,
                expectedAgentPIDToClear.runID
            )
        }
        guard let activeTransport = terminatingTransport.activeTransport else { return }
        let process = activeTransport.process
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdin?.closeFile()
        let logger: (String) -> Void = config.enableDebugLogging
            ? { print("[CodexAppServer] \($0)") }
            : { _ in }
        if terminatingTransport.processFamilyCleanupWasCompleted {
            return
        }
        if let observer = activeTransport.exitObservation?.observer {
            await ProcessTermination.terminateObservedProcessFamily(
                observer: observer,
                processGroupID: process.processGroupID,
                logger: logger
            )
        } else {
            _ = await ProcessTermination.terminateAndReap(
                pid: process.pid,
                processGroupID: process.processGroupID,
                logger: logger
            )
        }
    }

    private static func defaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
        // Use a non-destructive child-state check so exited/zombie children do not
        // look healthy, while leaving final reap/cleanup to the normal teardown path.
        if ProcessTermination.childIsTerminalOrAlreadyReaped(process.pid) {
            return false
        }

        let pidState = Darwin.kill(process.pid, 0)
        if pidState == -1, errno == ESRCH {
            return false
        }
        guard let stdinDescriptor = process.stdinDescriptor else { return false }
        let descriptorFlags = fcntl(stdinDescriptor, F_GETFD)
        if descriptorFlags == -1, errno == EBADF {
            return false
        }
        return true
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        try await request(
            method: method,
            params: params,
            timeout: timeout,
            useDefaultTimeout: true
        )
    }

    func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?,
        useDefaultTimeout: Bool
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let activeTransport, !didTerminateTransport else {
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
        let requestID = makeRequestID()
        let generation = activeTransport.generation
        let deadline = timeout ?? (useDefaultTimeout ? config.requestTimeout : nil)
        var payload: [String: Any] = [
            "method": method,
            "id": Int(requestID) ?? requestID
        ]
        if let params {
            payload["params"] = params
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = continuation
                pendingRequestMetadata[requestID] = PendingRequestMetadata(
                    method: method,
                    transportGeneration: generation
                )
                if let deadline {
                    scheduleTimeout(for: requestID, after: deadline)
                }
                if Task.isCancelled {
                    cancelPendingRequestIfPresent(id: requestID)
                    return
                }
                do {
                    try sendJSONLine(payload, method: method)
                } catch {
                    failPendingRequestIfPresent(id: requestID, error: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingRequestIfPresent(id: requestID) }
        }
    }

    func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws {
        guard activeTransport != nil, !didTerminateTransport else {
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
        let payload: [String: Any] = [
            "id": id.jsonValue,
            "result": result
        ]
        try sendJSONLine(payload, method: nil)
    }

    func respondToServerRequestError(
        id: CodexAppServerRequestID,
        code: Int = -32601,
        message: String,
        data: [String: Any]? = nil
    ) throws {
        guard activeTransport != nil, !didTerminateTransport else {
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
        var errorObject: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let data {
            errorObject["data"] = data
        }
        let payload: [String: Any] = [
            "id": id.jsonValue,
            "error": errorObject
        ]
        try sendJSONLine(payload, method: nil)
    }

    func notify(method: String, params: [String: Any]?) throws {
        guard activeTransport != nil, !didTerminateTransport else {
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
        var payload: [String: Any] = [
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try sendJSONLine(payload, method: method)
    }

    /// Returns all models exposed by Codex app-server `model/list`, following pagination.
    func listModels(limit: Int = 100) async throws -> [RemoteModel] {
        do {
            return try await fetchModelPages(limit: limit)
        } catch let error as ClientError {
            switch error {
            case .processNotRunning, .processExited, .transportWriteFailed, .transportReadSetupFailed:
                return try await fetchModelPages(limit: limit)
            default:
                throw error
            }
        } catch {
            throw error
        }
    }

    private func fetchModelPages(limit: Int) async throws -> [RemoteModel] {
        let pageLimit = max(1, limit)
        try await startIfNeeded()

        var cursor: String?
        var seenModelIDs = Set<String>()
        var models: [RemoteModel] = []

        while true {
            var params: [String: Any] = ["limit": pageLimit]
            if let cursor {
                params["cursor"] = cursor
            }

            let result = try await request(method: "model/list", params: params)
            guard let pageItems = result["data"] as? [[String: Any]] else {
                throw ClientError.invalidResponse
            }

            for entry in pageItems {
                guard
                    let id = entry["id"] as? String,
                    !id.isEmpty
                else { continue }
                guard seenModelIDs.insert(id).inserted else { continue }

                let model = (entry["model"] as? String) ?? id
                let displayName = (entry["displayName"] as? String) ?? model
                let description = (entry["description"] as? String) ?? ""
                let isDefault = entry["isDefault"] as? Bool ?? false
                let defaultReasoningEffort = entry["defaultReasoningEffort"] as? String
                let supportedReasoningEfforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                    .compactMap { effortEntry -> RemoteReasoningEffort? in
                        guard let reasoningEffort = effortEntry["reasoningEffort"] as? String,
                              !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else {
                            return nil
                        }
                        let effortDescription = (effortEntry["description"] as? String) ?? ""
                        return RemoteReasoningEffort(reasoningEffort: reasoningEffort, description: effortDescription)
                    }
                models.append(
                    RemoteModel(
                        id: id,
                        model: model,
                        displayName: displayName,
                        description: description,
                        isDefault: isDefault,
                        supportedReasoningEfforts: supportedReasoningEfforts,
                        defaultReasoningEffort: defaultReasoningEffort
                    )
                )
            }

            let nextCursor = result["nextCursor"] as? String
            guard let nextCursor, !nextCursor.isEmpty, nextCursor != cursor else {
                break
            }
            cursor = nextCursor
        }

        return models
    }

    private func initializeIfNeeded() async throws {
        if isInitialized {
            return
        }
        let clientInfo: [String: Any] = [
            "name": "repoprompt",
            "title": "RepoPrompt",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        ]
        let capabilities: [String: Any] = [
            "experimentalApi": true
        ]
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": clientInfo,
                "capabilities": capabilities
            ]
        )
        try notify(method: "initialized", params: nil)
        isInitialized = true
    }

    private func ensureStartupAuthority(_ authority: UInt64) throws {
        guard authority == startupAuthorityEpoch else {
            throw CancellationError()
        }
    }

    private func performStartupIfNeeded(startupAuthority: UInt64) async throws {
        do {
            try ensureStartupAuthority(startupAuthority)
            if activeTransport == nil {
                try await startProcess(startupAuthority: startupAuthority)
            }
            try ensureStartupAuthority(startupAuthority)
            try await initializeIfNeeded()
        } catch is CancellationError {
            if let termination = transportTerminationTask,
               termination.generation == transportGeneration
            {
                await termination.task.value
                throw lastTransportFailure ?? ClientError.processNotRunning
            }
            throw CancellationError()
        }
    }

    private static func executableUnavailableSpawnError(
        _ error: ProcessLauncherError
    ) -> ClientError? {
        let failure = error.processLaunchFailure
        guard failure.domain == NSPOSIXErrorDomain else { return nil }
        return switch failure.code {
        case Int(ENOENT):
            .executableUnavailable(
                "RepoPrompt could not start Codex: the selected runtime could not be started. Reinstall RepoPrompt CE or configure a valid explicit override."
            )
        case Int(EACCES):
            .executableUnavailable(
                "RepoPrompt could not start Codex: permission was denied when starting the selected runtime. Reinstall RepoPrompt CE or configure a valid explicit override."
            )
        default:
            nil
        }
    }

    private func startProcess(startupAuthority: UInt64) async throws {
        let runtime = try await prepareRuntimeForLaunch()
        guard let launchContext = preparedRuntimeLaunchContext else {
            throw ClientError.executableUnavailable("RepoPrompt could not start Codex: prepared runtime launch context was unavailable.")
        }
        let environment = launchContext.environment
        let resolution = launchContext.resolution
        if provisionsRepoPromptMCPOnStart {
            let provisioning = CodexIntegrationConfiguration.ensureServerForDiscovery(runtime: runtime)
            guard provisioning.success else {
                throw ClientError.executableUnavailable(
                    provisioning.errorMessage ?? "RepoPrompt could not prepare its owned Codex configuration."
                )
            }
        }
        let processOverrides = CodexOverrides.cliConfigArgs(
            toolPolicy: .init(
                toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
                modelReasoningSummary: config.processModelReasoningSummary
            ),
            featurePolicy: config.processFeaturePolicy
        )
        let args = processOverrides + ["app-server"]
        let launchDirectory = CLIProcessConfiguration.resolvedWorkingDirectory(
            config.processLaunchDirectory
        )
        let spawned: SpawnedProcess
        do {
            try await processSpawnPreparation()
            try Task.checkCancellation()
            try ensureStartupAuthority(startupAuthority)
            spawned = try ProcessLauncher.spawn(
                command: resolution.resolvedCommand,
                arguments: args,
                environment: environment,
                workingDirectory: launchDirectory
            )
        } catch let error as ProcessLauncherError {
            guard let mappedError = Self.executableUnavailableSpawnError(error) else {
                throw error
            }
            throw mappedError
        }

        // The observer is installed before reader setup or PID registration so
        // every successful spawn immediately has one cancellation-independent reaper.
        transportGeneration &+= 1
        let generation = transportGeneration
        let exitObserver = processExitObserverFactory(spawned.pid)
        let capture = CodexProcessStderrCapture(byteLimit: Self.stderrTailLimit)

        stdoutFramer = LineFramer()
        stdoutTail.removeAll(keepingCapacity: false)
        didTerminateTransport = false
        lastTransportTerminationReason = nil
        lastTransportFailure = nil
        transportTerminationTask = nil
        decodeRecoveryAttemptsByGeneration[generation] = 0
        activeTransport = ActiveTransport(
            generation: generation,
            process: spawned,
            exitObservation: ExitObservation(
                observer: exitObserver,
                executablePath: resolution.resolvedCommand,
                launchDirectory: launchDirectory,
                stderrCapture: capture
            )
        )

        Task.detached { [weak self] in
            guard let outcome = await exitObserver.wait() else { return }
            await self?.handleObservedProcessExit(
                outcome,
                observer: exitObserver,
                generation: generation
            )
        }
        do {
            try startStdoutReader(spawned.stdout, generation: generation)
            try startStderrReader(spawned.stderr, capture: capture)
        } catch {
            let clientError = Self.transportReadSetupError(stream: "process pipe", error: error)
            let task = beginTransportTermination(
                flushStdout: false,
                requestFailure: clientError,
                reason: .readSourceSetupFailed(stream: "process pipe", errno: Self.errnoValue(from: error))
            )
            await task?.value
            throw lastTransportFailure ?? clientError
        }
        await registerExpectedAgentPIDIfNeeded(for: spawned.pid)
        guard activeTransport?.process.pid == spawned.pid,
              activeTransport?.generation == generation,
              !didTerminateTransport
        else {
            if let termination = transportTerminationTask,
               termination.generation == generation
            {
                await termination.task.value
            }
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
    }

    // SEARCH-HELPER: FIFO stdout, FileHandleChunkChannel, readabilityHandler, chunk ordering
    /// Sets up a FIFO channel + single consumer task for stdout, mirroring Claude's pattern.
    ///
    /// Using `FileHandleChunkChannel` ensures chunks are processed in the exact order
    /// delivered by the OS, avoiding the reordering that occurs when each
    /// `readabilityHandler` callback spawns an independent `Task`.
    ///
    /// Related:
    /// - FileHandleChunkChannel (FIFO ordering primitive)
    /// - ClaudeNativeProcessSessionController.startStdoutReader (reference implementation)
    private func startStdoutReader(_ handle: FileHandle, generation: UInt64) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Codex app-server stdout")
        stdoutConsumerTask?.cancel()
        stdoutConsumerTask = nil
        let channel = FileHandleChunkChannel()
        stdoutChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk, generation: generation)
            }
            // Stream ended — could be genuine EOF or cancellation/finish from teardown.
            // Only trigger teardown on genuine EOF (not cancellation), and scope to
            // this transport generation so a stale task can't kill a new process.
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await handleStdoutEOF(generation: generation)
        }
    }

    /// Sets up a FIFO channel + single consumer task for stderr.
    private func startStderrReader(_ handle: FileHandle, capture: CodexProcessStderrCapture) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Codex app-server stderr")
        stderrConsumerTask?.cancel()
        stderrConsumerTask = nil
        let channel = FileHandleChunkChannel()
        stderrChunkChannel = channel
        let enableDebugLogging = config.enableDebugLogging
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stderrConsumerTask = Task {
            defer { capture.finish() }
            for await chunk in channel.stream {
                capture.append(chunk)
                if enableDebugLogging, !chunk.isEmpty {
                    print("[CodexAppServer][stderr] \(String(decoding: chunk, as: UTF8.self))")
                }
            }
        }
    }

    private func handleStdoutChunk(_ data: Data, generation: UInt64) async {
        guard activeTransport?.generation == generation, !didTerminateTransport else { return }
        appendTail(&stdoutTail, chunk: data, limit: 128 * 1024)
        stdoutFramer.feed(data, onDiagnostic: { [self] diagnostic in
            handleStdoutFramerDiagnostic(diagnostic)
        }, onLine: { [self] lineData in
            handleJSONLine(lineData)
        })
    }

    /// Called when the stdout consumer task's channel stream ends (EOF or explicit finish).
    /// Delegates to `terminateTransport` for authoritative cleanup, scoped to the
    /// transport generation that created the consumer task.
    private func handleStdoutEOF(generation: UInt64) async {
        await settleObservationalTermination(
            generation: generation,
            flushStdout: true,
            fallbackReason: .stdoutEOF
        )
    }

    private func handleStdoutFramerDiagnostic(_ diagnostic: LineFramer.Diagnostic) {
        guard config.enableDebugLogging else { return }
        switch diagnostic {
        case let .overflow(droppedBytes, retainedBytes):
            if let (sample, truncated) = makeUTF8Sample(from: stdoutTail, limit: 180) {
                let preview = truncated ? "\(sample)…" : sample
                print("[CodexAppServer] stdout LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes, tail sample: \(preview)")
            } else {
                print("[CodexAppServer] stdout LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes")
            }
        case .nonJSONCandidateQuoteStateReset:
            print("[CodexAppServer] stdout LineFramer reset quote state for non-JSON candidate")
        }
    }

    // SEARCH-HELPER: JSON decode, recovery, concatenated, embedded tail, JSON-RPC
    /// Attempts to decode and route a single JSON-RPC line from stdout.
    ///
    /// If direct decode fails, applies recovery heuristics (concatenated-object
    /// splitting and embedded-tail recovery) adapted from Claude's decode pipeline.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.handleLine (reference decode + recovery)
    /// - ClaudeNativeProcessSessionController.recoverConcatenatedInboundMessagesIfNeeded
    /// - ClaudeNativeProcessSessionController.recoverEmbeddedInboundTailIfNeeded
    private func handleJSONLine(_ lineData: Data) {
        guard let trimmed = trimmedASCIIWhitespace(lineData) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            // Primary decode failed — attempt recovery heuristics.
            guard shouldAttemptDecodeRecovery() else {
                let generation = transportGeneration
                if config.enableDebugLogging {
                    print("[CodexAppServer] Decode recovery budget exhausted for generation \(generation); terminating poisoned transport")
                }
                Task { [generation] in
                    await self.terminateTransport(
                        flushStdout: false,
                        expectedGeneration: generation,
                        reason: .decodeRecoveryBudgetExceeded(generation: generation)
                    )
                }
                return
            }
            if recoverConcatenatedJSONLines(from: trimmed) {
                return
            }
            if recoverEmbeddedJSONTail(from: trimmed) {
                return
            }
            if recoverInvalidJSONStringControlChars(from: trimmed) {
                return
            }
            if config.enableDebugLogging {
                let preview = String(data: trimmed.prefix(500), encoding: .utf8) ?? "<non-utf8>"
                print("[CodexAppServer] Failed to decode JSON line (no recovery): \(preview)")
            }
            return
        }
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        routeDecodedJSON(json)
    }

    private func shouldAttemptDecodeRecovery() -> Bool {
        let generation = transportGeneration
        let attempts = decodeRecoveryAttemptsByGeneration[generation, default: 0]
        guard attempts < Self.maxDecodeRecoveryAttemptsPerGeneration else {
            return false
        }
        decodeRecoveryAttemptsByGeneration[generation] = attempts + 1
        if decodeRecoveryAttemptsByGeneration.count > 4 {
            let minGeneration = max(transportGeneration > 0 ? transportGeneration - 2 : 0, 0)
            decodeRecoveryAttemptsByGeneration = decodeRecoveryAttemptsByGeneration.filter { $0.key >= minGeneration }
        }
        return true
    }

    /// Routes a successfully decoded JSON-RPC object to the appropriate handler
    /// (response, error, server request, or notification broadcast).
    private func routeDecodedJSON(_ json: [String: Any]) {
        if let idValue = json["id"] {
            let idString = String(describing: idValue)
            if let result = json["result"] as? [String: Any] {
                if let continuation = pendingRequests.removeValue(forKey: idString) {
                    pendingRequestMetadata.removeValue(forKey: idString)
                    cancelTimeout(for: idString)
                    if config.enableDebugLogging {
                        print("[CodexAppServer] Response for request \(idString)")
                    }
                    continuation.resume(returning: result)
                }
                return
            }
            if let error = json["error"] as? [String: Any],
               let continuation = pendingRequests.removeValue(forKey: idString)
            {
                let metadata = pendingRequestMetadata.removeValue(forKey: idString)
                cancelTimeout(for: idString)
                guard let failure = Self.requestFailure(
                    method: metadata?.method ?? "<unknown>",
                    errorObject: error
                ) else {
                    continuation.resume(throwing: ClientError.invalidResponse)
                    return
                }
                if config.enableDebugLogging {
                    print("[CodexAppServer] Error for request \(idString): \(failure.message)")
                }
                continuation.resume(throwing: ClientError.requestFailed(failure))
                return
            }
            if let method = json["method"] as? String,
               let requestID = CodexAppServerRequestID(raw: idValue)
            {
                let params = codexJSONDictionary(from: json["params"] as? [String: Any] ?? [:])
                if config.enableDebugLogging {
                    print("[CodexAppServer] Server request: \(method) -> broadcasting to \(serverRequestContinuations.count) listeners")
                }
                broadcastServerRequest(id: requestID, method: method, params: params)
                return
            }
            if let continuation = pendingRequests.removeValue(forKey: idString) {
                pendingRequestMetadata.removeValue(forKey: idString)
                cancelTimeout(for: idString)
                continuation.resume(throwing: ClientError.invalidResponse)
            }
            return
        }
        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            if config.enableDebugLogging {
                print("[CodexAppServer] Notification: \(method) -> broadcasting to \(notificationContinuations.count) listeners")
            }
            broadcastNotification(method: method, params: codexJSONDictionary(from: params))
        }
    }

    // MARK: - Decode recovery heuristics

    /// Maximum line size for concatenated-segment recovery to avoid expensive scans.
    private static let maxConcatenatedRecoveryBytes = 2 * 1024 * 1024 // 2 MB

    /// Attempts to split a corrupted line into multiple concatenated JSON objects
    /// using brace-depth scanning, then routes each successfully decoded object.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.recoverConcatenatedInboundMessagesIfNeeded
    private func recoverConcatenatedJSONLines(from lineData: Data) -> Bool {
        guard lineData.count <= Self.maxConcatenatedRecoveryBytes else { return false }
        let segments = Self.splitConcatenatedJSONObjects(lineData)
        guard !segments.isEmpty else { return false }
        let looksCorrupted =
            segments.count > 1
                || (segments.count == 1 && segments[0].count != lineData.count)
        guard looksCorrupted else { return false }

        var recoveredCount = 0
        for segment in segments {
            guard let json = try? JSONSerialization.jsonObject(with: segment) as? [String: Any] else {
                continue
            }
            recoveredCount += 1
            routeDecodedJSON(json)
        }

        if recoveredCount > 0 {
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
            if config.enableDebugLogging {
                print("[CodexAppServer] Recovered \(recoveredCount)/\(segments.count) JSON segment(s) from corrupted line")
            }
        }
        return recoveredCount > 0
    }

    /// Maximum trailing bytes to scan for embedded-tail recovery.
    private static let maxTailRecoveryScanBytes = 256 * 1024 // 256 KB

    /// JSON-RPC marker byte sequences used to locate potential object start positions.
    private static let jsonRPCMarkers: [[UInt8]] = [
        Array("{\"method\"".utf8),
        Array("{\"id\"".utf8),
        Array("{\"result\"".utf8),
        Array("{\"error\"".utf8),
        Array("{\"jsonrpc\"".utf8)
    ]

    /// Scans the tail of a corrupted line for an embedded valid JSON-RPC object.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.recoverEmbeddedInboundTailIfNeeded
    private func recoverEmbeddedJSONTail(from lineData: Data) -> Bool {
        guard !lineData.isEmpty else { return false }

        let scanWindow: Data
        let scanOffset: Int
        if lineData.count > Self.maxTailRecoveryScanBytes {
            scanOffset = lineData.count - Self.maxTailRecoveryScanBytes
            scanWindow = lineData.suffix(Self.maxTailRecoveryScanBytes)
        } else {
            scanOffset = 0
            scanWindow = lineData
        }

        let markerOffsets = Self.jsonRPCObjectStartOffsets(in: scanWindow, markers: Self.jsonRPCMarkers)
        guard !markerOffsets.isEmpty else { return false }

        // Skip offset 0 if it's the start of the original data (already failed upstream).
        let candidateOffsets: [Int] = if markerOffsets.first == 0, scanOffset == 0 {
            Array(markerOffsets.dropFirst())
        } else {
            markerOffsets
        }
        guard !candidateOffsets.isEmpty else { return false }

        // Try candidates from the end (prefer the rightmost / latest embedded JSON).
        for offset in candidateOffsets.reversed() {
            let absoluteOffset = scanOffset + offset
            let suffixData = lineData.suffix(from: lineData.startIndex + absoluteOffset)
            guard let json = try? JSONSerialization.jsonObject(with: suffixData) as? [String: Any] else {
                continue
            }
            if config.enableDebugLogging {
                let preview = String(data: suffixData.prefix(180), encoding: .utf8) ?? "<non-utf8>"
                print("[CodexAppServer] Recovered embedded JSON tail at offset \(absoluteOffset): \(preview)")
            }
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
            routeDecodedJSON(json)
            return true
        }
        return false
    }

    private func recoverInvalidJSONStringControlChars(from lineData: Data) -> Bool {
        guard let repaired = repairJSONStringControlCharacters(lineData) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: repaired) as? [String: Any] else {
            return false
        }
        if config.enableDebugLogging {
            print("[CodexAppServer] Recovered JSON by escaping control characters inside JSON strings")
        }
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        routeDecodedJSON(json)
        return true
    }

    /// Splits concatenated JSON objects from raw data using brace-depth scanning.
    /// Reused from Claude's `splitConcatenatedJSONObjectPayloads` algorithm.
    static func splitConcatenatedJSONObjects(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        var results: [Data] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if start == nil {
                if character == "{" {
                    start = index
                    depth = 1
                    inString = false
                    escaping = false
                }
                index = text.index(after: index)
                continue
            }

            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let segmentStart = start {
                        let segmentEnd = text.index(after: index)
                        let segment = String(text[segmentStart ..< segmentEnd])
                        if let segmentData = segment.data(using: .utf8), !segmentData.isEmpty {
                            results.append(segmentData)
                        }
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }
        return results
    }

    /// Finds byte offsets of JSON-RPC marker sequences in raw Data.
    private static func jsonRPCObjectStartOffsets(in data: Data, markers: [[UInt8]]) -> [Int] {
        guard !data.isEmpty, !markers.isEmpty else { return [] }
        var offsets = Set<Int>()
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for marker in markers {
                guard data.count >= marker.count else { continue }
                let searchLimit = data.count - marker.count
                for i in 0 ... searchLimit {
                    var matches = true
                    for j in 0 ..< marker.count {
                        if baseAddress[i + j] != marker[j] {
                            matches = false
                            break
                        }
                    }
                    if matches {
                        offsets.insert(i)
                    }
                }
            }
        }
        return offsets.sorted()
    }

    private func broadcastNotification(method: String, params: [String: CodexJSONValue]) {
        for continuation in notificationContinuations.values {
            continuation.yield(Notification(method: method, params: params))
        }
    }

    private func broadcastServerRequest(id: CodexAppServerRequestID, method: String, params: [String: CodexJSONValue]) {
        let request = ServerRequest(id: id, method: method, params: params)
        for continuation in serverRequestContinuations.values {
            continuation.yield(request)
        }
    }

    private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
        var output: [String: CodexJSONValue] = [:]
        for (key, value) in value {
            if let converted = CodexJSONValue.from(value) {
                output[key] = converted
            }
        }
        return output
    }

    /// Writes a single JSON-RPC line to stdin as an atomic frame (payload + newline).
    ///
    /// Combining payload and newline into a single write prevents pipe interleaving
    /// that could theoretically occur with two separate writes.
    ///
    /// Related:
    /// - ClaudeNativeProcessSessionController.sendLine (reference atomic write pattern)
    private func sendJSONLine(_ payload: [String: Any], method: String?) throws {
        guard let activeTransport, !didTerminateTransport else {
            throw lastTransportFailure ?? ClientError.processNotRunning
        }
        let process = activeTransport.process
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        if config.enableDebugLogging {
            if let line = String(data: data, encoding: .utf8) {
                print("[CodexAppServer] -> \(line)")
            }
        }
        guard let stdinDescriptor = process.stdinDescriptor else {
            throw ClientError.processNotRunning
        }
        var frame = data
        frame.append(0x0A)
        let generation = activeTransport.generation
        do {
            try writeFrameHandler(stdinDescriptor, frame)
        } catch let error as FDWriteError {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: error.errnoValue),
                errno: error.errnoValue
            )
            beginTransportTermination(
                flushStdout: false,
                expectedGeneration: generation,
                requestFailure: failure,
                reason: .stdinWrite(method: method, errno: error.errnoValue)
            )
            throw failure
        } catch {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: nil),
                errno: nil
            )
            beginTransportTermination(
                flushStdout: false,
                expectedGeneration: generation,
                requestFailure: failure,
                reason: .stdinWrite(method: method, errno: nil)
            )
            throw failure
        }
    }

    private func transportWriteFailureMessage(method: String?, errno: Int32?) -> String {
        let operation = method ?? "transport write"
        if let errno {
            let message = String(cString: strerror(errno))
            return "Codex app-server stdin write failed during \(operation): \(message)"
        }
        return "Codex app-server stdin write failed during \(operation)."
    }

    private static func transportReadSetupError(stream: String, error: Error) -> ClientError {
        let errnoValue = errnoValue(from: error)
        if let errnoValue {
            let message = String(cString: strerror(errnoValue))
            return .transportReadSetupFailed(
                message: "Codex app-server \(stream) reader failed to start: \(message)",
                errno: errnoValue
            )
        }
        return .transportReadSetupFailed(
            message: "Codex app-server \(stream) reader failed to start: \(error.localizedDescription)",
            errno: nil
        )
    }

    private static func errnoValue(from error: Error) -> Int32? {
        if let preflightError = error as? ReadSourceFDPreflightError {
            switch preflightError {
            case .invalidFileDescriptor:
                return EBADF
            case let .descriptorCheckFailed(_, _, errnoValue):
                return errnoValue
            }
        }
        if let posixError = error as? POSIXError {
            return posixError.code.rawValue
        }
        return nil
    }

    private func scheduleTimeout(for requestID: String, after timeout: TimeInterval) {
        guard timeout > 0 else { return }
        timeoutTasks[requestID]?.cancel()
        timeoutTasks[requestID] = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutRequest(id: requestID, after: timeout)
        }
    }

    private func timeoutRequest(id: String, after timeout: TimeInterval) async {
        timeoutTasks.removeValue(forKey: id)
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            pendingRequestMetadata.removeValue(forKey: id)
            return
        }
        let metadata = pendingRequestMetadata.removeValue(forKey: id)
        if let metadata,
           Self.shouldPoisonTransportOnTimeout(method: metadata.method)
        {
            beginTransportTermination(
                flushStdout: false,
                expectedGeneration: metadata.transportGeneration,
                requestFailure: .processNotRunning,
                reason: .timeout(method: metadata.method, requestID: id)
            )
        }
        continuation.resume(throwing: ClientError.requestFailed(.init(
            method: metadata?.method ?? "<unknown>",
            code: nil,
            message: "Request timed out after \(timeout)s",
            data: nil
        )))
    }

    private func cancelTimeout(for requestID: String) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
    }

    private func cancelPendingRequestIfPresent(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pendingRequestMetadata.removeValue(forKey: id)
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func failPendingRequestIfPresent(id: String, error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pendingRequestMetadata.removeValue(forKey: id)
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func makeRequestID() -> String {
        let value = nextRequestID
        nextRequestID += 1
        return String(value)
    }

    private func removeNotificationContinuation(_ id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }

    private func removeServerRequestContinuation(_ id: UUID) {
        serverRequestContinuations.removeValue(forKey: id)
    }

    #if DEBUG
        func debugProcessID() -> pid_t? {
            activeTransport?.process.pid
        }

        func debugIsProcessRunning() -> Bool {
            activeTransport != nil && !didTerminateTransport
        }

        func debugNextRequestID() -> Int {
            nextRequestID
        }

        func debugTransportGeneration() -> UInt64 {
            transportGeneration
        }

        func debugLastTransportTerminationReason() -> TransportTerminationReason? {
            lastTransportTerminationReason
        }

        func debugProcessExitObserver() -> ChildProcessExitObserver? {
            activeTransport?.exitObservation?.observer
        }

        func debugDeliverObservedProcessExit(
            _ outcome: ChildProcessExitObserver.Outcome,
            observer: ChildProcessExitObserver,
            generation: UInt64
        ) async {
            await handleObservedProcessExit(
                outcome,
                observer: observer,
                generation: generation
            )
        }

        static func debugDefaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
            defaultProcessAppearsAlive(process)
        }

        func debugTerminalObserverJoinCount() -> Int {
            terminalObserverJoinCount
        }

        func debugDecodeRecoveryAttempts(generation: UInt64? = nil) -> Int {
            let key = generation ?? transportGeneration
            return decodeRecoveryAttemptsByGeneration[key, default: 0]
        }

        func debugIngestRawStdoutLine(_ line: Data) {
            handleJSONLine(line)
        }

        static func debugMaxDecodeRecoveryAttemptsPerGeneration() -> Int {
            maxDecodeRecoveryAttemptsPerGeneration
        }

        func debugPendingRequestCount() -> Int {
            pendingRequests.count
        }

        func debugTimeoutTaskCount() -> Int {
            timeoutTasks.count
        }

        func debugInstallTestTransport() {
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            transportGeneration &+= 1
            activeTransport = ActiveTransport(
                generation: transportGeneration,
                process: SpawnedProcess(
                    pid: pid_t.max,
                    processGroupID: nil,
                    stdin: stdinPipe.fileHandleForWriting,
                    stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
                    stdout: stdoutPipe.fileHandleForReading,
                    stderr: stderrPipe.fileHandleForReading
                ),
                exitObservation: nil
            )
            isInitialized = true
            didTerminateTransport = false
            lastTransportTerminationReason = nil
            lastTransportFailure = nil
            transportTerminationTask = nil
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        }

    #endif
}
