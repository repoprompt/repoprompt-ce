//
//  InteractiveMCPClientSession.swift
//  repoprompt-mcp
//
//  Manages the MCP client connection for interactive CLI mode.
//  Handles bootstrap handshake, tool caching, and tool calls.
//

import Foundation
import Logging
import MCP
import RepoPromptShared

// MARK: - Progress Notification (CLI-side)

/// MCP notification wrapper for progress updates.
/// Uses RepoPromptProgressParams from shared MCPControlMessages.
struct CLIProgressNotification: MCP.Notification {
    typealias Parameters = RepoPromptProgressParams
    static let name: String = "repoprompt/control/progress"
}

private struct BindContextWorkspace: Decodable {
    let id: UUID
    let name: String
}

private struct BindContextTab: Decodable {
    let contextID: UUID
    let name: String

    private enum CodingKeys: String, CodingKey {
        case contextID = "context_id"
        case name
    }
}

private struct BindContextWindow: Decodable {
    let windowID: Int
    let workspace: BindContextWorkspace?
    let tabs: [BindContextTab]

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case workspace
        case tabs
    }
}

struct BindContextBinding: Decodable {
    let bindingKind: String
    let windowID: Int?
    let contextID: UUID?
    let workspaceName: String?

    private enum CodingKeys: String, CodingKey {
        case bindingKind = "binding_kind"
        case windowID = "window_id"
        case contextID = "context_id"
        case workspaceName = "workspace_name"
    }
}

private struct BindContextResponse: Decodable {
    let windows: [BindContextWindow]?
    let binding: BindContextBinding
}

enum ToolCallTimeoutPolicy: Equatable {
    case `default`
    case seconds(TimeInterval)
    case none
}

private final class MCPInitializationSettlementState: @unchecked Sendable {
    enum Outcome {
        case pending
        case completed
        case timedOut
        case callerCancelled
    }

    private let lock = NSLock()
    private var outcome: Outcome = .pending

    func claim(_ candidate: Outcome) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = outcome else { return false }
        outcome = candidate
        return true
    }

    func finish() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if case .pending = outcome {
            outcome = .completed
        }
        return outcome
    }
}

private final class CancellationDeliveryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let delivered {
            lock.unlock()
            continuation.resume(returning: delivered)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(delivered: Bool) {
        lock.lock()
        guard self.delivered == nil else {
            lock.unlock()
            return
        }
        self.delivered = delivered
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: delivered)
    }
}

private final class ToolCatalogSharedTaskState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []

    func install(
        waiterID: UUID,
        continuation: CheckedContinuation<Value, Error>
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if cancelledWaiterIDs.remove(waiterID) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters[waiterID] = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiters = Array(waiters.values)
        self.waiters.removeAll()
        cancelledWaiterIDs.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func cancel(waiterID: UUID) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let continuation = waiters.removeValue(forKey: waiterID)
        if continuation == nil {
            cancelledWaiterIDs.insert(waiterID)
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private final class ToolCatalogSharedTask<Value: Sendable>: @unchecked Sendable {
    private let state: ToolCatalogSharedTaskState<Value>
    private let task: Task<Value, Error>

    init(operation: @escaping @Sendable () async throws -> Value) {
        let state = ToolCatalogSharedTaskState<Value>()
        self.state = state
        task = Task {
            do {
                let value = try await operation()
                state.resolve(.success(value))
                return value
            } catch {
                state.resolve(.failure(error))
                throw error
            }
        }
    }

    func value() async throws -> Value {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            state.cancel(waiterID: waiterID)
        }
    }

    func cancel() {
        task.cancel()
    }
}

private final class ToolCallSettlementState: @unchecked Sendable {
    enum Outcome {
        case pending
        case completed
        case timedOut
        case callerCancelled
    }

    private let lock = NSLock()
    private struct CancellationDelivery {
        let task: Task<Void, Never>
        let completion: CancellationDeliveryCompletion
    }

    private var outcome: Outcome = .pending
    private var responseResult: Result<CallTool.Result, Error>?
    private var outcomeContinuation: CheckedContinuation<Outcome, Never>?
    private var cancellationDelivery: CancellationDelivery?

    func claim(
        _ candidate: Outcome,
        deliverCancellation: @escaping @Sendable () async -> Void
    ) -> Bool {
        lock.lock()
        guard case .pending = outcome else {
            lock.unlock()
            return false
        }
        outcome = candidate
        let completion = CancellationDeliveryCompletion()
        let task = Task.detached {
            await deliverCancellation()
            completion.resolve(delivered: true)
        }
        cancellationDelivery = CancellationDelivery(task: task, completion: completion)
        let continuation = outcomeContinuation
        outcomeContinuation = nil
        lock.unlock()
        continuation?.resume(returning: candidate)
        return true
    }

    func complete(with result: Result<CallTool.Result, Error>) {
        lock.lock()
        guard case .pending = outcome else {
            lock.unlock()
            return
        }
        outcome = .completed
        responseResult = result
        let continuation = outcomeContinuation
        outcomeContinuation = nil
        lock.unlock()
        continuation?.resume(returning: .completed)
    }

    func waitForOutcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard case .pending = outcome else {
                let outcome = outcome
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            outcomeContinuation = continuation
            lock.unlock()
        }
    }

    func completedResult() -> Result<CallTool.Result, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return responseResult
    }

    func waitForCancellationDelivery(
        timeoutNanoseconds: UInt64,
        timeoutSleep: @escaping @Sendable (UInt64) async throws -> Void
    ) async -> Bool {
        guard let cancellationDelivery = cancellationDeliverySnapshot() else { return true }
        let timeoutTask = Task {
            do {
                try await timeoutSleep(timeoutNanoseconds)
                cancellationDelivery.completion.resolve(delivered: false)
            } catch {}
        }
        let delivered = await withCheckedContinuation { continuation in
            cancellationDelivery.completion.install(continuation)
        }
        timeoutTask.cancel()
        await timeoutTask.value
        if !delivered {
            cancellationDelivery.task.cancel()
        }
        return delivered
    }

    private func cancellationDeliverySnapshot() -> CancellationDelivery? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationDelivery
    }
}

private struct RegisteredToolCall {
    let context: RequestContext<CallTool.Result>

    var requestID: ID {
        context.requestID
    }
}

private struct ToolListRefreshFlight {
    let id: UUID
    let catalogEpoch: UInt64
    let invalidationGeneration: UInt64
    let request: ToolCatalogSharedTask<(tools: [MCP.Tool], nextCursor: String?)>
}

/// Manages an interactive MCP client session with the RepoPrompt app.
actor InteractiveMCPClientSession {
    typealias TimeoutSleep = @Sendable (UInt64) async throws -> Void
    #if DEBUG
        typealias CancellationDeliveryOverride = @Sendable (MCP.Client, ID, String) async -> Void
    #endif

    static let cancellationDeliveryDrainTimeoutNanoseconds: UInt64 = 2_000_000_000

    private let sessionToken: String
    private let clientName: String
    private let logger: Logger
    private let timeoutSleep: TimeoutSleep
    private let cancellationDeliveryDrainSleep: TimeoutSleep
    private let cancellationDeliveryDrainTimeoutNanoseconds: UInt64

    private var client: MCP.Client?
    private var transport: (any Transport)?
    private var requestSendBarrier: MCPRequestSendBarrier?
    private var pendingToolCallResponseTasks: [UUID: Task<Void, Never>] = [:]
    private var cachedTools: [MCP.Tool] = []
    private var toolListFetched = false
    private var toolCatalogEpoch: UInt64 = 0
    private var toolListInvalidationGeneration: UInt64 = 0
    private var toolListRefreshFlight: ToolListRefreshFlight?
    private var defaultToolCallTimeout: ToolCallTimeoutPolicy = .default
    private(set) var toolsDirty = false
    private(set) var toolsChangeNoticePending = false

    #if DEBUG
        private let requestSendWillStart: (@Sendable () async -> Void)?
        private let toolListRefreshWillAwait: (@Sendable () async -> Void)?
        private let cancellationDeliveryOverride: CancellationDeliveryOverride?
    #endif

    /// Server info from initialization
    private(set) var serverName: String?
    private(set) var serverVersion: String?

    /// Current window selection (if any)
    private(set) var selectedWindowID: Int?

    /// Canonical context binding injected on tool calls when set.
    private(set) var selectedContextID: String?

    /// If true, request raw JSON tool output (server skips markdown formatting).
    private var rawJSONEnabled: Bool = false

    /// If true, emit progress notifications to stderr (for exec mode).
    private var progressEnabled: Bool = false

    init(sessionToken: String, clientName: String, logger: Logger? = nil) {
        self.sessionToken = sessionToken
        self.clientName = clientName
        self.logger = logger ?? Logger(label: "mcp.interactive.session") { _ in
            SwiftLogNoOpLogHandler()
        }
        timeoutSleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        cancellationDeliveryDrainSleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        cancellationDeliveryDrainTimeoutNanoseconds = Self.cancellationDeliveryDrainTimeoutNanoseconds
        #if DEBUG
            requestSendWillStart = nil
            toolListRefreshWillAwait = nil
            cancellationDeliveryOverride = nil
        #endif
    }

    #if DEBUG
        init(
            connectedClientForTesting client: MCP.Client,
            requestSendBarrier: MCPRequestSendBarrier,
            requestSendWillStart: (@Sendable () async -> Void)? = nil,
            toolListRefreshWillAwait: (@Sendable () async -> Void)? = nil,
            cancellationDeliveryOverride: CancellationDeliveryOverride? = nil,
            timeoutSleep: @escaping TimeoutSleep = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            cancellationDeliveryDrainTimeoutNanoseconds: UInt64 = InteractiveMCPClientSession.cancellationDeliveryDrainTimeoutNanoseconds,
            cancellationDeliveryDrainSleep: @escaping TimeoutSleep = { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        ) {
            sessionToken = "test-session"
            clientName = "test-client"
            logger = Logger(label: "mcp.interactive.session.tests") { _ in
                SwiftLogNoOpLogHandler()
            }
            self.timeoutSleep = timeoutSleep
            self.cancellationDeliveryDrainSleep = cancellationDeliveryDrainSleep
            self.cancellationDeliveryDrainTimeoutNanoseconds = cancellationDeliveryDrainTimeoutNanoseconds
            self.client = client
            self.requestSendBarrier = requestSendBarrier
            self.requestSendWillStart = requestSendWillStart
            self.toolListRefreshWillAwait = toolListRefreshWillAwait
            self.cancellationDeliveryOverride = cancellationDeliveryOverride
        }
    #endif

    // MARK: - Connection

    /// Connects to the RepoPrompt app via bootstrap socket and initializes MCP.
    func connect(fetchInitialTools: Bool = true) async throws {
        logger.debug("InteractiveMCPClientSession connecting...")
        resetToolCatalogForConnectionBoundary()

        // Perform bootstrap handshake and get connected FD
        let connectedFD = try await performBootstrapHandshake()
        logger.debug("Bootstrap handshake complete, FD=\(connectedFD)")

        // Create transport with the connected FD and observe completed request writes.
        let socketTransport: BootstrapSocketMCPTransport
        do {
            socketTransport = try BootstrapSocketMCPTransport(connectedFD: connectedFD, logger: logger)
        } catch let error as POSIXDescriptorConfigurationError {
            throw InteractiveSessionError.descriptorConfigurationFailed(errno: error.errnoValue)
        }
        let requestSendBarrier = MCPRequestSendBarrier()
        let transport = OrderedMCPTransport(
            underlying: socketTransport,
            requestSendBarrier: requestSendBarrier,
            logger: logger
        )

        // Create MCP client
        let client = MCP.Client(
            name: clientName,
            version: "1.0"
        )
        self.transport = transport
        self.requestSendBarrier = requestSendBarrier
        self.client = client
        logger.debug("Created MCP client '\(clientName)'")

        do {
            // Register for tool list changed notifications
            await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                await self?.markToolsDirty()
            }

            // Register for progress notifications (emit to stderr only when enabled)
            await client.onNotification(CLIProgressNotification.self) { [weak self] message in
                guard await self?.progressEnabled == true else { return }
                let params = message.params
                fputs("[progress] \(params.tool): \(params.message)\n", stderr)
            }

            logger.debug("Calling MCP client.connect(transport)...")
            // Connect and initialize. Avoid returning Initialize.Result through a
            // throwing task group: Swift 6.2 release builds can abort in
            // swift_task_dealloc when that timeout race tears down a child task.
            let initResult = try await Self.awaitInitialization(
                timeoutNanoseconds: 10_000_000_000,
                timeoutSleep: timeoutSleep
            ) {
                try await client.connect(transport: transport)
            }
            logger.debug("MCP client connected successfully")

            // Store server info
            serverName = initResult.serverInfo.name
            serverVersion = initResult.serverInfo.version

            logger.debug("Connected to \(serverName ?? "unknown") v\(serverVersion ?? "?")")

            // Initial tool fetch. Exec mode can skip this and call known tools directly,
            // avoiding startup-time UI catalog work for single-shot commands.
            if fetchInitialTools {
                try await refreshTools()
            }
        } catch {
            await client.disconnect()
            await transport.disconnect()
            self.client = nil
            self.transport = nil
            self.requestSendBarrier = nil
            resetToolCatalogForConnectionBoundary()
            serverName = nil
            serverVersion = nil
            throw error
        }
    }

    private static func awaitInitialization(
        timeoutNanoseconds: UInt64,
        timeoutSleep: @escaping TimeoutSleep,
        operation: @escaping @Sendable () async throws -> Initialize.Result
    ) async throws -> Initialize.Result {
        let settlement = MCPInitializationSettlementState()
        let connectionTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            do {
                try await timeoutSleep(timeoutNanoseconds)
            } catch {
                return
            }
            if settlement.claim(.timedOut) {
                connectionTask.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            let connectionResult: Result<Initialize.Result, Error>
            do {
                connectionResult = try await .success(connectionTask.value)
            } catch {
                connectionResult = .failure(error)
            }

            let outcome = settlement.finish()
            timeoutTask.cancel()
            await timeoutTask.value

            switch outcome {
            case .completed:
                return try connectionResult.get()
            case .timedOut:
                throw InteractiveSessionError.bootstrapResponseTimeout
            case .callerCancelled:
                throw CancellationError()
            case .pending:
                preconditionFailure("Connection task completion must settle initialization state")
            }
        } onCancel: {
            if settlement.claim(.callerCancelled) {
                connectionTask.cancel()
            }
            timeoutTask.cancel()
        }
    }

    #if DEBUG
        static func debugAwaitInitialization(
            timeoutNanoseconds: UInt64,
            timeoutSleep: @escaping TimeoutSleep,
            operation: @escaping @Sendable () async throws -> Initialize.Result
        ) async throws -> Initialize.Result {
            try await awaitInitialization(
                timeoutNanoseconds: timeoutNanoseconds,
                timeoutSleep: timeoutSleep,
                operation: operation
            )
        }
    #endif

    /// Disconnects from the MCP server.
    func disconnect() async {
        await client?.disconnect()
        await transport?.disconnect()
        let responseTasks = Array(pendingToolCallResponseTasks.values)
        pendingToolCallResponseTasks.removeAll()
        for task in responseTasks {
            task.cancel()
            await task.value
        }
        client = nil
        transport = nil
        requestSendBarrier = nil
        resetToolCatalogForConnectionBoundary()
        logger.debug("Disconnected from MCP server")
    }

    private func resetToolCatalogForConnectionBoundary() {
        toolCatalogEpoch &+= 1
        toolListRefreshFlight?.request.cancel()
        toolListRefreshFlight = nil
        cachedTools = []
        toolListFetched = false
        toolsDirty = false
        toolsChangeNoticePending = false
    }

    // MARK: - Tools

    /// Refreshes the tool list from the server. Concurrent callers coalesce onto one
    /// connection-scoped request so every caller observes the same successful catalog.
    @discardableResult
    func refreshTools() async throws -> [MCP.Tool] {
        while true {
            guard let client else {
                throw InteractiveSessionError.notConnected
            }

            let flight: ToolListRefreshFlight
            if let current = toolListRefreshFlight,
               current.catalogEpoch == toolCatalogEpoch
            {
                flight = current
            } else {
                let created = ToolListRefreshFlight(
                    id: UUID(),
                    catalogEpoch: toolCatalogEpoch,
                    invalidationGeneration: toolListInvalidationGeneration,
                    request: ToolCatalogSharedTask {
                        try await client.listTools()
                    }
                )
                toolListRefreshFlight = created
                flight = created
            }

            #if DEBUG
                if let toolListRefreshWillAwait {
                    await toolListRefreshWillAwait()
                }
            #endif

            do {
                let result = try await flight.request.value()
                guard flight.catalogEpoch == toolCatalogEpoch else {
                    clearToolListRefreshFlight(matching: flight.id)
                    if toolListFetched, !toolsDirty {
                        return cachedTools
                    }
                    logger.debug("Retrying tool list refresh after connection epoch changed")
                    continue
                }
                guard flight.invalidationGeneration == toolListInvalidationGeneration else {
                    clearToolListRefreshFlight(matching: flight.id)
                    logger.debug("Retrying tool list refresh after concurrent invalidation")
                    continue
                }

                clearToolListRefreshFlight(matching: flight.id)
                cachedTools = result.tools
                toolListFetched = true
                toolsDirty = false
                toolsChangeNoticePending = false

                logger.debug("Refreshed tools: \(cachedTools.count) available")
                return cachedTools
            } catch {
                if error is CancellationError, Task.isCancelled {
                    throw error
                }
                clearToolListRefreshFlight(matching: flight.id)
                if flight.catalogEpoch != toolCatalogEpoch {
                    if toolListFetched, !toolsDirty {
                        return cachedTools
                    }
                    logger.debug("Retrying failed tool list refresh on the current connection epoch")
                    continue
                }
                throw error
            }
        }
    }

    private func clearToolListRefreshFlight(matching id: UUID) {
        guard toolListRefreshFlight?.id == id else { return }
        toolListRefreshFlight = nil
    }

    /// Returns the cached tool list.
    func tools() -> [MCP.Tool] {
        cachedTools
    }

    /// Returns the cached tool catalog unless it has never been fetched or the server marked it dirty.
    @discardableResult
    func cachedToolsOrRefresh() async throws -> [MCP.Tool] {
        guard toolListFetched, !toolsDirty else {
            return try await refreshTools()
        }
        return cachedTools
    }

    /// Returns a specific tool by name.
    func tool(named name: String) -> MCP.Tool? {
        cachedTools.first { $0.name == name }
    }

    /// Marks the tool list as potentially stale.
    private func markToolsDirty() {
        toolListInvalidationGeneration &+= 1
        toolsDirty = true
        toolsChangeNoticePending = true
        logger.debug("Tool list marked dirty (server sent notification)")
    }

    /// Clears only the one-shot user notice after acknowledgement; the catalog stays dirty until refreshed.
    func acknowledgeToolsChanged() {
        toolsChangeNoticePending = false
    }

    // MARK: - Raw JSON Mode

    /// Enables/disables raw JSON output mode for tool calls.
    func setRawJSONEnabled(_ enabled: Bool) {
        rawJSONEnabled = enabled
    }

    /// Enables/disables progress notifications to stderr (for exec mode).
    func setProgressEnabled(_ enabled: Bool) {
        progressEnabled = enabled
    }

    /// Sets the default timeout for tool calls. Use `.none` to disable the CLI-side timeout.
    func setDefaultToolCallTimeout(_ policy: ToolCallTimeoutPolicy) {
        defaultToolCallTimeout = policy
    }

    // MARK: - Tool Calls

    /// Calls a tool with the given arguments.
    func callTool(
        name: String,
        arguments: [String: Value]?,
        timeout: ToolCallTimeoutPolicy = .default
    ) async throws -> CallTool.Result {
        guard let client, let requestSendBarrier else {
            throw InteractiveSessionError.notConnected
        }

        // Inject hidden parameters if we have window selection
        var args = arguments ?? [:]
        let suppressWindowInjection = shouldSuppressWindowInjection(toolName: name, args: args)
        let suppressContextInjection = shouldSuppressContextInjection(toolName: name)
        if let windowID = selectedWindowID, !suppressWindowInjection {
            args["_windowID"] = .int(windowID)
        }
        if let selectedContextID, args["context_id"] == nil, !suppressContextInjection {
            args["context_id"] = .string(selectedContextID)
        }

        // Request raw JSON output from server formatter (skip markdown)
        if rawJSONEnabled, args["_rawJSON"] == nil {
            args["_rawJSON"] = .bool(true)
        }

        logger.debug("Calling tool: \(name)")
        let registeredCall = try await registerAndSendToolCall(
            client: client,
            requestSendBarrier: requestSendBarrier,
            name: name,
            arguments: args.isEmpty ? nil : args
        )
        let effectiveTimeout = resolvedTimeout(
            timeout,
            toolName: name,
            arguments: args
        )
        let result = try await awaitToolCallResult(
            registeredCall,
            client: client,
            toolName: name,
            timeoutSeconds: effectiveTimeout
        )

        if result.isError != true, shouldClearWindowSelectionAfterCall(toolName: name, args: args) {
            selectedWindowID = nil
            logger.debug("Cleared window selection after open-in-new-window switch")
        }

        return result
    }

    private func registerAndSendToolCall(
        client: MCP.Client,
        requestSendBarrier: MCPRequestSendBarrier,
        name: String,
        arguments: [String: Value]?
    ) async throws -> RegisteredToolCall {
        #if DEBUG
            if let requestSendWillStart {
                await requestSendWillStart()
            }
        #endif
        try Task.checkCancellation()
        let request = CallTool.request(.init(name: name, arguments: arguments))
        await requestSendBarrier.register(requestID: request.id)
        do {
            let context = try await client.send(request)
            try await requestSendBarrier.waitUntilSent(requestID: request.id)
            return RegisteredToolCall(context: context)
        } catch {
            await requestSendBarrier.cancel(requestID: request.id)
            throw error
        }
    }

    private func awaitToolCallResult(
        _ registeredCall: RegisteredToolCall,
        client: MCP.Client,
        toolName: String,
        timeoutSeconds: TimeInterval?
    ) async throws -> CallTool.Result {
        let settlement = ToolCallSettlementState()
        let responseTaskID = UUID()
        let responseTask = Task.detached { [weak self] in
            let result: Result<CallTool.Result, Error>
            do {
                result = try await .success(registeredCall.context.value)
            } catch {
                result = .failure(error)
            }
            settlement.complete(with: result)
            await self?.removeToolCallResponseTask(responseTaskID)
        }
        pendingToolCallResponseTasks[responseTaskID] = responseTask

        let timeoutTask = timeoutSeconds.map { seconds in
            Task { [timeoutSleep] in
                do {
                    try await timeoutSleep(Self.nanoseconds(forTimeoutSeconds: seconds))
                } catch {
                    return
                }
                _ = settlement.claim(.timedOut) { [weak self] in
                    await self?.deliverCancellation(
                        client: client,
                        requestID: registeredCall.requestID,
                        reason: "CLI tool call timed out after \(seconds) seconds"
                    )
                }
            }
        }
        defer { timeoutTask?.cancel() }

        let outcome = await withTaskCancellationHandler {
            await settlement.waitForOutcome()
        } onCancel: {
            _ = settlement.claim(.callerCancelled) { [weak self] in
                await self?.deliverCancellation(
                    client: client,
                    requestID: registeredCall.requestID,
                    reason: "CLI caller cancelled tool request"
                )
            }
        }
        await waitForCancellationDeliveryIfNeeded(
            settlement: settlement,
            outcome: outcome,
            requestID: registeredCall.requestID,
            toolName: toolName
        )

        switch outcome {
        case .completed:
            guard let result = settlement.completedResult() else {
                throw InteractiveSessionError.cancelled
            }
            return try result.get()
        case .timedOut:
            throw InteractiveSessionError.toolCallTimeout(
                toolName: toolName,
                seconds: timeoutSeconds ?? 0
            )
        case .callerCancelled:
            throw CancellationError()
        case .pending:
            preconditionFailure("Tool-call outcome waiter resumed before settlement")
        }
    }

    private func removeToolCallResponseTask(_ id: UUID) {
        pendingToolCallResponseTasks.removeValue(forKey: id)
    }

    private func deliverCancellation(
        client: MCP.Client,
        requestID: ID,
        reason: String
    ) async {
        #if DEBUG
            if let cancellationDeliveryOverride {
                await cancellationDeliveryOverride(client, requestID, reason)
                return
            }
        #endif
        try? await client.cancelRequest(requestID, reason: reason)
    }

    private func waitForCancellationDeliveryIfNeeded(
        settlement: ToolCallSettlementState,
        outcome: ToolCallSettlementState.Outcome,
        requestID: ID,
        toolName: String
    ) async {
        switch outcome {
        case .timedOut, .callerCancelled:
            break
        case .pending, .completed:
            return
        }
        let delivered = await settlement.waitForCancellationDelivery(
            timeoutNanoseconds: cancellationDeliveryDrainTimeoutNanoseconds,
            timeoutSleep: cancellationDeliveryDrainSleep
        )
        if !delivered {
            logger.warning("Timed out draining cancellation for tool \(toolName), request \(String(describing: requestID))")
        }
    }

    private static func nanoseconds(forTimeoutSeconds seconds: TimeInterval) -> UInt64 {
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        let clampedSeconds = min(seconds, maxSeconds)
        return UInt64((clampedSeconds * 1_000_000_000).rounded(.up))
    }

    private func resolvedTimeout(
        _ policy: ToolCallTimeoutPolicy,
        toolName: String,
        arguments: [String: Value]
    ) -> TimeInterval? {
        let effectivePolicy: ToolCallTimeoutPolicy = switch policy {
        case .default:
            defaultToolCallTimeout
        case .seconds, .none:
            policy
        }
        switch effectivePolicy {
        case .default:
            if MCPTimeoutPolicy.cliDefaultUnboundedToolNames.contains(toolName) {
                return nil
            }
            if let semanticWaitSeconds = Self.explicitSemanticWaitSeconds(
                toolName: toolName,
                arguments: arguments
            ) {
                guard semanticWaitSeconds > 0 else { return nil }
                return max(
                    MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds,
                    semanticWaitSeconds + MCPTimeoutPolicy.cliSemanticWaitResponseMarginSeconds
                )
            }
            return MCPTimeoutPolicy.cliDefaultToolCallTimeoutSeconds
        case let .seconds(seconds):
            return seconds.isFinite && seconds > 0 ? seconds : nil
        case .none:
            return nil
        }
    }

    private static func explicitSemanticWaitSeconds(
        toolName: String,
        arguments: [String: Value]
    ) -> TimeInterval? {
        let timeoutKey: String
        switch toolName {
        case "agent_run", "agent_explore":
            let operation = arguments["op"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch operation {
            case "start", "wait":
                timeoutKey = "timeout"
            case "steer" where toolName == "agent_run":
                guard arguments["wait"]?.boolValue != false else { return nil }
                timeoutKey = "timeout_seconds"
            default:
                return nil
            }
        case "ask_user", "wait_for_next_user_instruction":
            timeoutKey = "timeout_seconds"
        default:
            return nil
        }

        guard let value = arguments[timeoutKey] else { return nil }
        let seconds: TimeInterval? = switch value {
        case let .int(value):
            TimeInterval(value)
        case let .double(value):
            value
        case let .string(value):
            Double(value)
        default:
            nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    #if DEBUG
        func test_resolvedToolCallTimeout(
            _ policy: ToolCallTimeoutPolicy = .default,
            toolName: String,
            arguments: [String: Value] = [:]
        ) -> TimeInterval? {
            resolvedTimeout(policy, toolName: toolName, arguments: arguments)
        }

        func test_markToolsDirty() {
            markToolsDirty()
        }

        func test_replaceConnectedClient(
            _ client: MCP.Client,
            requestSendBarrier: MCPRequestSendBarrier
        ) {
            self.client = client
            transport = nil
            self.requestSendBarrier = requestSendBarrier
            resetToolCatalogForConnectionBoundary()
        }
    #endif

    private func shouldSuppressWindowInjection(toolName: String, args: [String: Value]) -> Bool {
        guard toolName != "bind_context" else { return true }
        guard toolName != "app_settings" else { return true }
        guard toolName == "manage_workspaces" else { return false }
        let action = args["action"]?.stringValue?.lowercased()
        guard action == "switch" || action == "create" else { return false }
        return args["open_in_new_window"]?.boolValue ?? false
    }

    private func shouldSuppressContextInjection(toolName: String) -> Bool {
        toolName == "bind_context" || toolName == "app_settings"
    }

    private func shouldClearWindowSelectionAfterCall(toolName: String, args: [String: Value]) -> Bool {
        guard toolName == "manage_workspaces" else { return false }
        return shouldSuppressWindowInjection(toolName: toolName, args: args)
    }

    func setSelectedContextID(_ contextID: String?) {
        selectedContextID = contextID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setSelectedWindowID(_ windowID: Int?) {
        selectedWindowID = windowID
    }

    // MARK: - Window Management

    /// Checks if a tool is available in the cached tools list.
    private func hasTool(named name: String) -> Bool {
        cachedTools.contains { $0.name == name }
    }

    /// Returns true when multiple windows are currently open.
    func isMultiWindowModeAvailable() async -> Bool {
        guard !toolListFetched || hasTool(named: "bind_context") else { return false }
        guard let state = try? await fetchBindContextState() else { return false }
        return (state.windows?.count ?? 0) > 1
    }

    /// Checks if a result indicates "tool not found" for a specific tool.
    private func isToolNotFoundResult(_ result: CallTool.Result, toolName: String) -> Bool {
        guard result.isError == true else { return false }
        let needle = "Tool not found: \(toolName)"
        return result.content.contains { block in
            if case let .text(t, _, _) = block { return t.contains(needle) }
            return false
        }
    }

    /// Returns a friendly message explaining single-window mode.
    private func singleWindowInfoMessage() -> String {
        """
        RepoPrompt is currently in single-window mode.

        The 'windows' and 'use' commands are only available when multiple
        RepoPrompt windows are open. With a single window, commands run
        directly without needing window selection.

        To use multi-window mode:
        1. Open another RepoPrompt window (⌘N or File > New Window)
        2. Run 'refresh' to update available tools
        3. Then 'windows' will show the available windows
        """
    }

    /// Lists available windows.
    func listWindows() async throws -> CallTool.Result {
        if toolListFetched, !hasTool(named: "bind_context") {
            return CallTool.Result(
                content: [.text(singleWindowInfoMessage())],
                isError: false
            )
        }

        let result = try await callTool(name: "bind_context", arguments: [
            "op": .string("list")
        ], timeout: .seconds(20))
        if isToolNotFoundResult(result, toolName: "bind_context") {
            return CallTool.Result(
                content: [.text(singleWindowInfoMessage())],
                isError: false
            )
        }
        return result
    }

    /// Selects a window for subsequent tool calls.
    func selectWindow(windowID: Int) async throws -> CallTool.Result {
        if toolListFetched, !hasTool(named: "bind_context") {
            return CallTool.Result(
                content: [.text(singleWindowInfoMessage())],
                isError: false
            )
        }

        let result = try await callTool(name: "bind_context", arguments: [
            "op": .string("bind"),
            "window_id": .int(windowID)
        ], timeout: .seconds(20))

        if isToolNotFoundResult(result, toolName: "bind_context") {
            selectedWindowID = windowID
            selectedContextID = nil
            return CallTool.Result(
                content: [.text("Selected window \(windowID) locally; subsequent tool calls will include _windowID=\(windowID).")],
                isError: false
            )
        }

        // If successful, remember the selection
        if result.isError != true {
            selectedWindowID = windowID
            selectedContextID = nil
            logger.debug("Selected window \(windowID)")
        }

        return result
    }

    func clearWindowSelection() async throws -> CallTool.Result {
        selectedWindowID = nil
        selectedContextID = nil
        // Return a synthetic success result — unbind was removed server-side
        // because the routing system always re-establishes affinity on the next call.
        return CallTool.Result(content: [.text("Local window/context selection cleared.")], isError: false)
    }

    func bindContextID(_ contextID: String, windowID: Int? = nil) async throws -> CallTool.Result {
        var args: [String: Value] = [
            "op": .string("bind"),
            "context_id": .string(contextID)
        ]
        if let windowID {
            args["window_id"] = .int(windowID)
        }
        let result = try await callTool(name: "bind_context", arguments: args, timeout: .seconds(20))
        if result.isError != true {
            selectedContextID = contextID
            if let response = try? decodeBindContextResponse(from: result) {
                selectedWindowID = response.binding.windowID ?? selectedWindowID ?? windowID
            } else if let windowID {
                selectedWindowID = windowID
            }
        }
        return result
    }

    func bindWorkingDirs(_ dirs: [String], windowID: Int? = nil) async throws -> CallTool.Result {
        var args: [String: Value] = [
            "op": .string("bind"),
            "working_dirs": .array(dirs.map { .string($0) })
        ]
        if let windowID {
            args["window_id"] = .int(windowID)
        }
        let result = try await callTool(name: "bind_context", arguments: args, timeout: .seconds(20))
        if result.isError != true, let response = try? decodeBindContextResponse(from: result) {
            selectedWindowID = response.binding.windowID ?? selectedWindowID ?? windowID
            selectedContextID = response.binding.contextID?.uuidString
        }
        return result
    }

    func bindTab(selector: String, windowID: Int? = nil) async throws -> CallTool.Result {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InteractiveSessionError.handshakeFailed(reason: "Empty context selector")
        }

        if let contextID = UUID(uuidString: trimmed) {
            return try await bindContextID(contextID.uuidString, windowID: windowID)
        }

        let preferredWindowID = windowID ?? selectedWindowID
        let state = try await fetchBindContextState(windowID: preferredWindowID)
        var matches: [(windowID: Int, tab: BindContextTab)] = []
        let lowerTrimmed = trimmed.lowercased()

        for window in state.windows ?? [] {
            for tab in window.tabs where tab.name == trimmed {
                matches.append((window.windowID, tab))
            }
        }
        if matches.isEmpty {
            for window in state.windows ?? [] {
                for tab in window.tabs where tab.name.lowercased() == lowerTrimmed {
                    matches.append((window.windowID, tab))
                }
            }
        }
        if matches.isEmpty {
            for window in state.windows ?? [] {
                for tab in window.tabs where tab.name.lowercased().hasPrefix(lowerTrimmed) {
                    matches.append((window.windowID, tab))
                }
            }
        }

        guard !matches.isEmpty else {
            throw InteractiveSessionError.handshakeFailed(reason: "Unknown compose tab '\(trimmed)'. Use 'windows' to discover context_id values.")
        }
        guard matches.count == 1, let match = matches.first else {
            let details = matches.map { "\($0.tab.name)@w\($0.windowID)" }.sorted().joined(separator: ", ")
            throw InteractiveSessionError.handshakeFailed(reason: "Ambiguous compose tab '\(trimmed)': \(details). Re-run with -w or use a context_id.")
        }

        return try await bindContextID(match.tab.contextID.uuidString, windowID: match.windowID)
    }

    func bindingStatus() async throws -> BindContextBinding {
        try await fetchBindContextState().binding
    }

    func syncBindingFromServer() async {
        guard let binding = try? await bindingStatus() else { return }
        selectedWindowID = binding.windowID
        selectedContextID = binding.contextID?.uuidString
    }

    private func fetchBindContextState(windowID: Int? = nil) async throws -> BindContextResponse {
        var args: [String: Value] = [
            "op": .string("list"),
            "_rawJSON": .bool(true)
        ]
        if let windowID {
            args["window_id"] = .int(windowID)
        }
        let result = try await callTool(name: "bind_context", arguments: args, timeout: .seconds(20))
        return try decodeBindContextResponse(from: result)
    }

    private func decodeBindContextResponse(from result: CallTool.Result) throws -> BindContextResponse {
        guard let text = result.content.compactMap({
            if case let .text(text, _, _) = $0 { return text }
            return nil
        }).first else {
            throw InteractiveSessionError.handshakeFailed(reason: "bind_context returned no text payload")
        }
        let data = Data(text.utf8)
        return try JSONDecoder().decode(BindContextResponse.self, from: data)
    }

    // MARK: - Bootstrap Handshake

    /// Performs the bootstrap socket handshake and returns the connected FD.
    private func performBootstrapHandshake() async throws -> Int32 {
        let socketURL = MCPFilesystemConstants.bootstrapSocketURL()

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw InteractiveSessionError.socketCreationFailed(errno: errno)
        }
        var shouldCloseFD = true
        defer {
            if shouldCloseFD {
                POSIXDescriptorSupport.shutdownSocketReadWrite(fd)
                Darwin.close(fd)
            }
        }

        do {
            try POSIXDescriptorSupport.setCloseOnExec(fd)
        } catch let error as POSIXDescriptorConfigurationError {
            throw InteractiveSessionError.descriptorConfigurationFailed(errno: error.errnoValue)
        }

        // Disable SIGPIPE
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Set up socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw InteractiveSessionError.pathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        // Connect
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        if connectResult < 0 {
            let err = errno
            if err == ECONNREFUSED || err == ENOENT {
                throw InteractiveSessionError.appNotRunning
            }
            throw InteractiveSessionError.connectFailed(errno: err)
        }

        logger.debug("Connected to bootstrap socket")

        // Send handshake request
        try sendHandshakeRequest(fd: fd)

        // Read handshake response
        let response = try await readHandshakeResponse(
            fd: fd,
            timeout: MCPBootstrapTiming.initialResponseTimeout
        )

        switch response.type {
        case "accepted":
            logger.debug("Bootstrap handshake accepted")
            shouldCloseFD = false
            return fd

        case "rejected":
            if response.errorCode == MCPBootstrapErrorCode.approvalDenied.rawValue {
                throw InteractiveSessionError.approvalDenied
            }
            throw InteractiveSessionError.handshakeFailed(reason: response.reason ?? "Rejected by server")

        default:
            throw InteractiveSessionError.handshakeFailed(reason: "Unknown response: \(response.type)")
        }
    }

    private func sendHandshakeRequest(fd: Int32) throws {
        let request = MCPBootstrapRequest(
            sessionToken: sessionToken,
            clientPid: Int(getpid()),
            clientName: clientName,
            protocolVersion: MCPBootstrapProtocol.currentVersion
        )

        guard let jsonData = try? JSONEncoder().encode(request) else {
            throw InteractiveSessionError.handshakeFailed(reason: "Failed to encode request")
        }

        var payload = jsonData
        payload.append(UInt8(ascii: "\n"))

        do {
            try NonBlockingFDWriter.writeAll(
                payload,
                to: fd,
                stallTimeout: MCPBootstrapTiming.initialRequestWriteTimeout
            )
        } catch let error as NonBlockingFDWriteError {
            switch error {
            case .cancelled:
                throw InteractiveSessionError.cancelled
            case let .fcntlFailed(errno):
                throw InteractiveSessionError.descriptorConfigurationFailed(errno: errno)
            case let .pollFailed(errno):
                throw InteractiveSessionError.pollFailed(errno: errno)
            case .localTimeout:
                throw InteractiveSessionError.writeFailed(errno: ETIMEDOUT)
            case .brokenPipe:
                throw InteractiveSessionError.writeFailed(errno: EPIPE)
            case let .writeFailed(errno, _, _):
                throw InteractiveSessionError.writeFailed(errno: errno)
            }
        }
    }

    private func readHandshakeResponse(
        fd: Int32,
        timeout: TimeInterval
    ) async throws -> MCPBootstrapResponse {
        var buffer = Data()
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuffer.deallocate() }

        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if Task.isCancelled {
                throw InteractiveSessionError.cancelled
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            let pollResult = poll(&pfd, 1, min(100, max(1, remaining)))

            if pollResult < 0 {
                if errno == EINTR { continue }
                throw InteractiveSessionError.pollFailed(errno: errno)
            }

            if pollResult == 0 { continue }

            if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                throw InteractiveSessionError.connectionReset
            }

            let bytesRead = Darwin.read(fd, readBuffer, 4096)
            if bytesRead <= 0 {
                if bytesRead < 0, errno == EAGAIN || errno == EINTR { continue }
                throw InteractiveSessionError.serverClosed
            }

            buffer.append(readBuffer, count: bytesRead)

            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let jsonData = buffer[..<newlineIndex]
                guard let response = try? JSONDecoder().decode(MCPBootstrapResponse.self, from: Data(jsonData)) else {
                    throw InteractiveSessionError.handshakeFailed(reason: "Invalid response JSON")
                }
                return response
            }
        }

        throw InteractiveSessionError.bootstrapResponseTimeout
    }
}

// MARK: - Errors

enum InteractiveSessionError: Swift.Error, CustomStringConvertible {
    case notConnected
    case socketCreationFailed(errno: Int32)
    case descriptorConfigurationFailed(errno: Int32)
    case pathTooLong
    case connectFailed(errno: Int32)
    case appNotRunning
    case approvalDenied
    case handshakeFailed(reason: String)
    case bootstrapResponseTimeout
    case toolCallTimeout(toolName: String, seconds: TimeInterval)
    case connectionReset
    case serverClosed
    case writeFailed(errno: Int32)
    case pollFailed(errno: Int32)
    case cancelled

    var description: String {
        switch self {
        case .notConnected:
            return "Not connected to MCP server"
        case let .socketCreationFailed(errno):
            return "Failed to create socket: \(errno)"
        case let .descriptorConfigurationFailed(errno):
            return "Failed to configure socket descriptor: \(errno)"
        case .pathTooLong:
            return "Socket path too long"
        case let .connectFailed(errno):
            if errno == EPERM || errno == EACCES {
                return "Failed to connect: permission denied (errno \(errno)). If running in a sandboxed environment (e.g., Codex), disable sandbox or grant socket access."
            } else if errno == ENOENT {
                return "Failed to connect: socket not found. Is RepoPrompt running with MCP enabled?"
            } else if errno == ECONNREFUSED {
                return "Failed to connect: connection refused. RepoPrompt may need to be restarted."
            }
            return "Failed to connect: \(errno)"
        case .appNotRunning:
            return "RepoPrompt app is not running or MCP is disabled"
        case .approvalDenied:
            return "Connection approval was denied"
        case let .handshakeFailed(reason):
            return "Handshake failed: \(reason)"
        case .bootstrapResponseTimeout:
            return "Timed out waiting for RepoPrompt bootstrap response"
        case let .toolCallTimeout(toolName, seconds):
            let renderedSeconds = seconds.rounded(.down) == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
            return "Timed out waiting for tool '\(toolName)' after \(renderedSeconds)s"
        case .connectionReset:
            return "Connection reset by server"
        case .serverClosed:
            return "Server closed connection"
        case let .writeFailed(errno):
            return "Write failed: \(errno)"
        case let .pollFailed(errno):
            return "Poll failed: \(errno)"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
