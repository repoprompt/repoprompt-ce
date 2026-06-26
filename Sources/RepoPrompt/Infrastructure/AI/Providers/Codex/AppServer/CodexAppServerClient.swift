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
            return "\(message) Update the installed Codex CLI and try again; it rejected RepoPrompt's required \(method) request shape."
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
        /// Working directory for the Codex app-server process.
        /// When nil, falls back to temp directory via CLIProcessConfiguration default.
        let workingDirectory: String?
        let processFeaturePolicy: CodexOverrides.FeaturePolicy

        init(
            commandName: String = CLILaunchProfiles.codex.commandName,
            additionalPathHints: [String] = CLILaunchProfiles.codex.supplementalSearchPaths,
            enableDebugLogging: Bool = false,
            requestTimeout: TimeInterval? = nil,
            workingDirectory: String? = nil,
            processFeaturePolicy: CodexOverrides.FeaturePolicy = .defaultDisabled
        ) {
            self.commandName = commandName
            self.additionalPathHints = additionalPathHints
            self.enableDebugLogging = enableDebugLogging
            self.requestTimeout = requestTimeout
            self.workingDirectory = workingDirectory
            self.processFeaturePolicy = processFeaturePolicy
        }
    }

    struct Notification {
        let method: String
        let params: [String: CodexJSONValue]
    }

    enum ClientError: Error, LocalizedError {
        case processNotRunning
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
    }

    enum TransportTerminationReason: Equatable {
        case stdinWrite(method: String?, errno: Int32?)
        case stdoutEOF
        case timeout(method: String, requestID: String)
        case explicitStop
        case livenessCheckFailed(method: String?)
        case decodeRecoveryBudgetExceeded(generation: UInt64)
        case readSourceSetupFailed(stream: String, errno: Int32?)
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

    private struct TerminatingTransport {
        let process: SpawnedProcess?
        let expectedAgentPIDToClear: RegisteredExpectedAgentPID?
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
    private var process: SpawnedProcess?
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
    /// Per-transport decode-recovery attempts, used to cap CPU spent on malformed lines.
    private var decodeRecoveryAttemptsByGeneration: [UInt64: Int] = [:]
    /// Monotonic counter incremented each time a new process is started.
    /// Captured by consumer tasks and stdin-failure teardown to scope teardown
    /// to the correct transport instance — prevents a stale task from killing a
    /// newly started process.
    private var transportGeneration: UInt64 = 0
    private var startupTask: (id: UUID, task: Task<Void, Error>)?
    private var expectedAgentPIDRegistration: ExpectedAgentPIDRegistration?
    private var registeredExpectedAgentPID: RegisteredExpectedAgentPID?
    private static let maxDecodeRecoveryAttemptsPerGeneration = 128
    private let writeFrameHandler: @Sendable (Int32, Data) throws -> Void
    private let livenessProbe: @Sendable (SpawnedProcess) -> Bool
    private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar

    init(
        writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { descriptor, frame in
            try FDWriteSupport.writeAll(frame, to: descriptor)
        },
        livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { process in
            CodexAppServerClient.defaultProcessAppearsAlive(process)
        },
        expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .serverNetworkManager
    ) {
        self.writeFrameHandler = writeFrameHandler
        self.livenessProbe = livenessProbe
        self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    func setExpectedAgentPIDRegistration(_ registration: ExpectedAgentPIDRegistration?) async {
        expectedAgentPIDRegistration = registration
        guard registration != nil else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        guard let process else {
            await clearRegisteredExpectedAgentPIDIfNeeded()
            return
        }
        await registerExpectedAgentPIDIfNeeded(for: process.pid)
    }

    func clearExpectedAgentPIDRegistration() async {
        expectedAgentPIDRegistration = nil
        await clearRegisteredExpectedAgentPIDIfNeeded()
    }

    private func registerExpectedAgentPIDIfNeeded(for pid: pid_t) async {
        guard let registration = expectedAgentPIDRegistration else { return }
        let target = RegisteredExpectedAgentPID(
            pid: pid,
            clientName: registration.clientName,
            runID: registration.runID
        )
        guard registeredExpectedAgentPID != target else { return }
        await clearRegisteredExpectedAgentPIDIfNeeded()
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else { return }
        registeredExpectedAgentPID = target
        await expectedAgentPIDRegistrar.register(target.pid, target.clientName, target.runID)
        guard expectedAgentPIDRegistration == registration, process?.pid == pid else {
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

    /// Updates the working directory for the next process start.
    /// Must be called before `startIfNeeded()` to take effect.
    func updateWorkingDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        config = Config(
            commandName: config.commandName,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            requestTimeout: config.requestTimeout,
            workingDirectory: normalized,
            processFeaturePolicy: config.processFeaturePolicy
        )
    }

    func updateProcessFeaturePolicy(_ featurePolicy: CodexOverrides.FeaturePolicy) async {
        guard featurePolicy != config.processFeaturePolicy else { return }
        config = Config(
            commandName: config.commandName,
            additionalPathHints: config.additionalPathHints,
            enableDebugLogging: config.enableDebugLogging,
            requestTimeout: config.requestTimeout,
            workingDirectory: config.workingDirectory,
            processFeaturePolicy: featurePolicy
        )
        if process != nil {
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
        if let existingStartupTask = startupTask?.task {
            return try await existingStartupTask.value
        }
        if let process {
            let appearsAlive = livenessProbe(process)
            if isInitialized, appearsAlive {
                return
            }
            if !appearsAlive {
                scheduleTransportCleanup(
                    invalidateTransport(
                        flushStdout: false,
                        requestFailure: .processNotRunning,
                        reason: .livenessCheckFailed(method: nil)
                    )
                )
            }
        }
        let startupID = UUID()
        let task = Task<Void, Error> {
            try await self.performStartupIfNeeded()
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
        startupTask?.task.cancel()
        startupTask = nil
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
        await finishTransportTermination(
            invalidateTransport(
                flushStdout: flushStdout,
                expectedGeneration: expectedGeneration,
                requestFailure: requestFailure,
                reason: reason
            )
        )
    }

    private func invalidateTransport(
        flushStdout: Bool,
        expectedGeneration: UInt64? = nil,
        requestFailure: ClientError,
        reason: TransportTerminationReason
    ) -> TerminatingTransport? {
        if let expected = expectedGeneration, expected != transportGeneration { return nil }
        guard !didTerminateTransport else { return nil }
        didTerminateTransport = true
        lastTransportTerminationReason = reason

        // 1. Flush remaining stdout lines before tearing down.
        if flushStdout {
            var remainingLines: [Data] = []
            stdoutFramer.flush { lineData in
                remainingLines.append(lineData)
            }
            for lineData in remainingLines {
                handleJSONLine(lineData)
            }
        }

        // 2. Tear down chunk channels and consumer tasks.
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()
        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil

        // 3. Cancel all timeout tasks and fail all pending requests.
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

        // 4. Finish all notification and serverRequest subscriber streams.
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

        // 5. Snapshot and nil process BEFORE the await to prevent actor re-entrancy
        // issues: other calls (startIfNeeded, request, subscribe*) that interleave
        // during ProcessTermination.terminateAndReap will see process==nil and
        // correctly fail/bail out.
        let terminatingProcess = process
        let expectedAgentPIDToClear = takeRegisteredExpectedAgentPIDForDeferredClear()
        process = nil
        isInitialized = false

        // 6. Reset framer state for potential future restart.
        stdoutFramer = LineFramer()
        stdoutTail.removeAll(keepingCapacity: false)
        decodeRecoveryAttemptsByGeneration.removeValue(forKey: transportGeneration)

        return TerminatingTransport(
            process: terminatingProcess,
            expectedAgentPIDToClear: expectedAgentPIDToClear
        )
    }

    private func scheduleTransportCleanup(_ terminatingTransport: TerminatingTransport?) {
        guard let terminatingTransport else { return }
        Task {
            await self.finishTransportTermination(terminatingTransport)
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
        guard let process = terminatingTransport.process else { return }
        process.stdout.readabilityHandler = nil
        process.stderr.readabilityHandler = nil
        process.stdin?.closeFile()
        let pid = process.pid
        _ = await ProcessTermination.terminateAndReap(
            pid: pid,
            logger: config.enableDebugLogging ? { print("[CodexAppServer] \($0)") } : { _ in }
        )
    }

    private static func defaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
        // Use a non-destructive child-state check so exited/zombie children do not
        // look healthy, while leaving final reap/cleanup to the normal teardown path.
        var info = siginfo_t()
        let waitResult = Darwin.waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if waitResult == 0, info.si_pid == process.pid {
            return false
        }
        if waitResult == -1, errno == ECHILD {
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
        try Task.checkCancellation()
        guard process != nil else { throw ClientError.processNotRunning }
        let requestID = makeRequestID()
        let generation = transportGeneration
        let deadline = timeout ?? config.requestTimeout
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
        guard process != nil else { throw ClientError.processNotRunning }
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
        guard process != nil else { throw ClientError.processNotRunning }
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
        guard process != nil else { throw ClientError.processNotRunning }
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
            case .processNotRunning, .transportWriteFailed, .transportReadSetupFailed:
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

    private func performStartupIfNeeded() async throws {
        if process == nil {
            try await startProcess()
        }
        try await initializeIfNeeded()
    }

    private func startProcess() async throws {
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .codexAppServer,
                enableDebugLogging: config.enableDebugLogging
            )
        )
        let environment = environmentResult.environment
        let resolution = CodexProviderHelpers.resolveCodexExecutable(
            commandName: config.commandName,
            environment: environment,
            additionalPathHints: config.additionalPathHints,
            logger: config.enableDebugLogging ? { print("[CodexAppServer] \($0)") } : nil
        )
        guard resolution.status == .available else {
            throw ClientError.executableUnavailable(resolution.userMessage)
        }
        let processOverrides = CodexOverrides.cliConfigArgs(
            toolPolicy: .init(toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit),
            featurePolicy: config.processFeaturePolicy
        )
        let args = processOverrides + ["app-server"]
        let spawned = try ProcessLauncher.spawn(
            command: resolution.resolvedCommand,
            arguments: args,
            environment: environment,
            workingDirectory: config.workingDirectory
        )
        stdoutFramer = LineFramer()
        stdoutTail.removeAll(keepingCapacity: false)
        didTerminateTransport = false
        transportGeneration &+= 1
        decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        process = spawned
        do {
            try startStdoutReader(spawned.stdout)
            try startStderrReader(spawned.stderr)
        } catch {
            let clientError = Self.transportReadSetupError(stream: "process pipe", error: error)
            let terminatingTransport = invalidateTransport(
                flushStdout: false,
                requestFailure: clientError,
                reason: .readSourceSetupFailed(stream: "process pipe", errno: Self.errnoValue(from: error))
            )
            await finishTransportTermination(terminatingTransport)
            throw clientError
        }
        await registerExpectedAgentPIDIfNeeded(for: spawned.pid)
        guard process?.pid == spawned.pid, !didTerminateTransport else {
            throw ClientError.processNotRunning
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
    private func startStdoutReader(_ handle: FileHandle) throws {
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
        let generation = transportGeneration
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk)
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
    private func startStderrReader(_ handle: FileHandle) throws {
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
        stderrConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard self != nil else { break }
                if enableDebugLogging,
                   let line = String(data: chunk, encoding: .utf8),
                   !line.isEmpty
                {
                    print("[CodexAppServer][stderr] \(line)")
                }
            }
        }
    }

    private func handleStdoutChunk(_ data: Data) async {
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
        await terminateTransport(
            flushStdout: true,
            expectedGeneration: generation,
            reason: .stdoutEOF
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
        guard let process else { throw ClientError.processNotRunning }
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
        let generation = transportGeneration
        do {
            try writeFrameHandler(stdinDescriptor, frame)
        } catch let error as FDWriteError {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: error.errnoValue),
                errno: error.errnoValue
            )
            scheduleTransportCleanup(
                invalidateTransport(
                    flushStdout: false,
                    expectedGeneration: generation,
                    requestFailure: failure,
                    reason: .stdinWrite(method: method, errno: error.errnoValue)
                )
            )
            throw failure
        } catch {
            let failure = ClientError.transportWriteFailed(
                message: transportWriteFailureMessage(method: method, errno: nil),
                errno: nil
            )
            scheduleTransportCleanup(
                invalidateTransport(
                    flushStdout: false,
                    expectedGeneration: generation,
                    requestFailure: failure,
                    reason: .stdinWrite(method: method, errno: nil)
                )
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
            let terminatingTransport = invalidateTransport(
                flushStdout: false,
                expectedGeneration: metadata.transportGeneration,
                requestFailure: .processNotRunning,
                reason: .timeout(method: metadata.method, requestID: id)
            )
            scheduleTransportCleanup(terminatingTransport)
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
            process?.pid
        }

        func debugIsProcessRunning() -> Bool {
            process != nil
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

        static func debugDefaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
            defaultProcessAppearsAlive(process)
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
            process = SpawnedProcess(
                pid: pid_t.max,
                stdin: stdinPipe.fileHandleForWriting,
                stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
                stdout: stdoutPipe.fileHandleForReading,
                stderr: stderrPipe.fileHandleForReading
            )
            isInitialized = true
            didTerminateTransport = false
            lastTransportTerminationReason = nil
            transportGeneration &+= 1
            decodeRecoveryAttemptsByGeneration[transportGeneration] = 0
        }

    #endif
}
