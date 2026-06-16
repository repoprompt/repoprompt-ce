import Foundation
import MCP

/// Observes MCP tool usage for a single agent session and emits uniform events.
/// Tool observers are registered by runID (not connectionID) to survive connection handovers.
actor AgentToolTracker {
    private var trackedRunID: UUID?
    private var hasUnregistered = false

    /// Registers an enhanced tool event observer that receives args on call and result on completion.
    func registerEnhancedObserver(
        runID: UUID,
        onCalled: @escaping @Sendable (UUID, String, [String: Value]?) async -> Void,
        onCompleted: @escaping @Sendable (UUID, String, [String: Value]?, String, Bool) async -> Void
    ) async {
        let manager = ServerNetworkManager.shared

        // Register enhanced observer with args and results before waiting for
        // any MCP connection. Callers can await this method when they need the
        // observer installed before a provider readiness boundary returns.
        let observer = ServerNetworkManager.ToolEventObserver(
            onCalled: onCalled,
            onCompleted: onCompleted
        )
        await manager.registerToolEventObserver(for: runID, observer: observer)
        trackedRunID = runID
        hasUnregistered = false
    }

    /// Wait for a matching MCP connection after an observer has already been registered.
    func waitForConnectionAfterRegistration(
        runID: UUID,
        clientNameHint: String?,
        connectionTimeoutSeconds: TimeInterval = 10.0,
        fallbackTimeoutSeconds: TimeInterval = 5.0,
        keepObserversOnTimeout: Bool = true
    ) async {
        let manager = ServerNetworkManager.shared
        guard trackedRunID == runID, !hasUnregistered else { return }

        // Wait for connection (with cancellation checks)
        guard !Task.isCancelled else {
            await unregisterObserverOnce(for: runID, manager: manager)
            return
        }

        var resolvedID: UUID?
        if let hint = clientNameHint {
            resolvedID = await manager.waitForNewConnection(clientName: hint, timeout: connectionTimeoutSeconds)
        }
        if !Task.isCancelled, resolvedID == nil {
            resolvedID = await manager.waitForNewConnection(clientName: nil, timeout: fallbackTimeoutSeconds)
        }

        if Task.isCancelled {
            await unregisterObserverOnce(for: runID, manager: manager)
        } else if resolvedID == nil, !keepObserversOnTimeout {
            await unregisterObserverOnce(for: runID, manager: manager)
        }
    }

    /// Registers an enhanced tool event observer that receives args on call and result on completion.
    func startEnhanced(
        runID: UUID,
        clientNameHint: String?,
        connectionTimeoutSeconds: TimeInterval = 10.0,
        fallbackTimeoutSeconds: TimeInterval = 5.0,
        keepObserversOnTimeout: Bool = true,
        onCalled: @escaping @Sendable (UUID, String, [String: Value]?) async -> Void,
        onCompleted: @escaping @Sendable (UUID, String, [String: Value]?, String, Bool) async -> Void
    ) async {
        await registerEnhancedObserver(
            runID: runID,
            onCalled: onCalled,
            onCompleted: onCompleted
        )
        await waitForConnectionAfterRegistration(
            runID: runID,
            clientNameHint: clientNameHint,
            connectionTimeoutSeconds: connectionTimeoutSeconds,
            fallbackTimeoutSeconds: fallbackTimeoutSeconds,
            keepObserversOnTimeout: keepObserversOnTimeout
        )
    }

    /// Unregister exactly once to avoid double-cleanup races
    private func unregisterObserverOnce(for runID: UUID, manager: ServerNetworkManager) async {
        guard !hasUnregistered, trackedRunID == runID else { return }
        hasUnregistered = true
        trackedRunID = nil
        await manager.unregisterToolObservers(for: runID)
    }

    /// Detaches the observer if one was registered.
    func stop() async {
        guard !hasUnregistered, let runID = trackedRunID else { return }
        await unregisterObserverOnce(for: runID, manager: ServerNetworkManager.shared)
    }

    /// Detaches the observer only if the tracker still owns the expected run.
    func stop(ifTracking runID: UUID?) async {
        guard let runID else { return }
        await unregisterObserverOnce(for: runID, manager: ServerNetworkManager.shared)
    }
}

/// Accepts transcript-facing tool events synchronously and delivers them in FIFO order.
///
/// MCP observer callbacks enqueue here before their first suspension, so tool dispatch and
/// completion response paths never wait for main-actor transcript/UI work. Each controller
/// owns one mailbox, which preserves call-before-completion ordering for that tab while
/// retaining at most one drain task.
final class AgentToolEventDeliveryMailbox: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private let lock = NSLock()
    private var queuedOperations: [Operation] = []
    private var queuedOperationHead = 0
    private var nextDrainToken: UInt64 = 0
    private var activeDrainToken: UInt64?
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ operation: @escaping Operation) {
        lock.lock()
        queuedOperations.append(operation)
        scheduleDrainIfNeeded()
        lock.unlock()
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard activeDrainToken != nil || queuedOperationHead < queuedOperations.count else {
                lock.unlock()
                continuation.resume()
                return
            }
            idleContinuations.append(continuation)
            lock.unlock()
        }
    }

    #if DEBUG
        func queuedOperationCountForTesting() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return queuedOperations.count - queuedOperationHead
        }
    #endif

    private func scheduleDrainIfNeeded() {
        guard activeDrainToken == nil, queuedOperationHead < queuedOperations.count else { return }
        nextDrainToken &+= 1
        let token = nextDrainToken
        activeDrainToken = token
        Task { [weak self] in
            await self?.drain(token: token)
        }
    }

    private func takeNextOperation(token: UInt64) -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        guard activeDrainToken == token, queuedOperationHead < queuedOperations.count else {
            return nil
        }
        let operation = queuedOperations[queuedOperationHead]
        queuedOperationHead += 1
        if queuedOperationHead == queuedOperations.count {
            queuedOperations.removeAll(keepingCapacity: true)
            queuedOperationHead = 0
        } else if queuedOperationHead >= 64, queuedOperationHead * 2 >= queuedOperations.count {
            queuedOperations.removeFirst(queuedOperationHead)
            queuedOperationHead = 0
        }
        return operation
    }

    private func drain(token: UInt64) async {
        while let operation = takeNextOperation(token: token) {
            await operation()
        }
        drainDidFinish(token: token)
    }

    private func drainDidFinish(token: UInt64) {
        lock.lock()
        guard activeDrainToken == token else {
            lock.unlock()
            return
        }
        activeDrainToken = nil
        scheduleDrainIfNeeded()
        guard activeDrainToken == nil, queuedOperationHead == queuedOperations.count else {
            lock.unlock()
            return
        }
        let continuations = idleContinuations
        idleContinuations.removeAll(keepingCapacity: true)
        lock.unlock()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

// SEARCH-HELPER: AgentToolTrackingController, TrackerLifecycle, TrackerBinding, ToolTracking
/// Shared lifecycle shim for MCP tool tracking across all provider runtimes.
///
/// Owns a single `AgentToolTracker` + `Task` + `runID` triple so provider owners
/// (Claude, Codex, ACP) don't need to duplicate this state. Each provider owner
/// keeps one instance per tab (via `[UUID: AgentToolTrackingController]` dictionary).
///
/// Starting tracking for the same `runID` is a no-op. Starting for a different `runID`
/// serializes teardown of the prior registration before re-registering. Callbacks are suppressed if the `trackedRunID`
/// has changed by delivery time (stale-delivery protection).
///
/// Related:
/// - AgentToolTracker (actor): /RepoPrompt/Services/AI/Agents/AgentToolTracker.swift
/// - ClaudeAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Claude/ClaudeAgentModeCoordinator.swift
/// - CodexAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift
/// - ACPIntegratedAgentModeRunner: /RepoPrompt/Services/AgentMode/Runners/ACPIntegratedAgentModeRunner.swift
final class AgentToolTrackingController {
    private let tracker = AgentToolTracker()
    private let eventDeliveryMailbox = AgentToolEventDeliveryMailbox()
    private var trackingTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var registrationRunID: UUID?
    private var trackingGeneration: UInt64 = 0
    private(set) var trackedRunID: UUID?

    // MARK: - Callback-Based API (used by Claude, Codex, ACP)

    /// Start tracking MCP tool events for a run, delivering callbacks on the main actor.
    ///
    /// - If `runID` matches the current tracked run, this is a no-op.
    /// - If a different run is tracked, prior teardown is serialized before registration.
    /// - Stale callbacks (where `trackedRunID` has changed) are silently dropped.
    @MainActor func startTracking(
        runID: UUID,
        clientNameHint: String?,
        onCalled: @escaping @MainActor (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?) -> Void,
        onCompleted: @escaping @MainActor (_ invocationID: UUID, _ toolName: String, _ args: [String: Value]?, _ resultJSON: String, _ isError: Bool) -> Void
    ) async {
        if trackedRunID == runID {
            if registrationRunID == runID, let registrationTask {
                await registrationTask.value
            }
            return
        }

        trackingGeneration &+= 1
        let generation = trackingGeneration
        let previousRegistrationTask = registrationTask
        let previousRunID = registrationRunID ?? trackedRunID
        trackingTask?.cancel()
        trackingTask = nil
        registrationRunID = runID
        trackedRunID = runID

        let registrationTask = Task { [weak self, tracker, eventDeliveryMailbox, previousRegistrationTask, previousRunID] in
            if let previousRegistrationTask {
                await previousRegistrationTask.value
            }
            await tracker.stop(ifTracking: previousRunID)
            await eventDeliveryMailbox.waitUntilIdle()
            let shouldRegister = await MainActor.run { [weak self] in
                guard let self else { return false }
                return trackedRunID == runID && trackingGeneration == generation
            }
            guard shouldRegister else { return }
            await tracker.registerEnhancedObserver(
                runID: runID,
                onCalled: { [weak self, eventDeliveryMailbox] invocationID, toolName, args in
                    #if DEBUG
                        let scheduledAt = DispatchTime.now().uptimeNanoseconds
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                            EditFlowPerf.Dimensions(toolName: toolName, observerType: "event_call", runID: runID.uuidString)
                        )
                    #endif
                    MCPToolObserverAttributionContext.record(
                        correlationPath: "deferred_transcript_fifo",
                        scannedItemCount: 0
                    )
                    eventDeliveryMailbox.enqueue { [weak self] in
                        #if DEBUG
                            let bodyDurationMicroseconds = await MainActor.run { [weak self] in
                                let enteredAt = DispatchTime.now().uptimeNanoseconds
                                EditFlowPerf.lifecycleEvent(
                                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                                    EditFlowPerf.Dimensions(
                                        toolName: toolName,
                                        observerType: "event_call",
                                        queueDelayMicroseconds: Int((enteredAt - scheduledAt) / 1000),
                                        runID: runID.uuidString
                                    )
                                )
                                guard let self, shouldDeliverCallback(for: runID) else { return 0 }
                                onCalled(invocationID, toolName, args)
                                return Int((DispatchTime.now().uptimeNanoseconds - enteredAt) / 1000)
                            }
                            EditFlowPerf.lifecycleEvent(
                                EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                                EditFlowPerf.Dimensions(
                                    toolName: toolName,
                                    observerType: "event_call",
                                    durationMicroseconds: bodyDurationMicroseconds,
                                    runID: runID.uuidString
                                )
                            )
                        #else
                            await MainActor.run { [weak self] in
                                guard let self, shouldDeliverCallback(for: runID) else { return }
                                onCalled(invocationID, toolName, args)
                            }
                        #endif
                    }
                },
                onCompleted: { [weak self, eventDeliveryMailbox] invocationID, toolName, args, resultJSON, isError in
                    #if DEBUG
                        let scheduledAt = DispatchTime.now().uptimeNanoseconds
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                            EditFlowPerf.Dimensions(toolName: toolName, observerType: "event_completion", runID: runID.uuidString)
                        )
                    #endif
                    MCPToolObserverAttributionContext.record(
                        correlationPath: "deferred_transcript_fifo",
                        scannedItemCount: 0
                    )
                    eventDeliveryMailbox.enqueue { [weak self] in
                        #if DEBUG
                            let bodyDurationMicroseconds = await MainActor.run { [weak self] in
                                let enteredAt = DispatchTime.now().uptimeNanoseconds
                                EditFlowPerf.lifecycleEvent(
                                    EditFlowPerf.Lifecycle.MCPToolCall.mainActorEntered,
                                    EditFlowPerf.Dimensions(
                                        toolName: toolName,
                                        observerType: "event_completion",
                                        queueDelayMicroseconds: Int((enteredAt - scheduledAt) / 1000),
                                        runID: runID.uuidString
                                    )
                                )
                                guard let self, shouldDeliverCallback(for: runID) else { return 0 }
                                onCompleted(invocationID, toolName, args, resultJSON, isError)
                                return Int((DispatchTime.now().uptimeNanoseconds - enteredAt) / 1000)
                            }
                            EditFlowPerf.lifecycleEvent(
                                EditFlowPerf.Lifecycle.MCPToolCall.mainActorExited,
                                EditFlowPerf.Dimensions(
                                    toolName: toolName,
                                    observerType: "event_completion",
                                    durationMicroseconds: bodyDurationMicroseconds,
                                    resultBytes: resultJSON.utf8.count,
                                    runID: runID.uuidString
                                )
                            )
                        #else
                            await MainActor.run { [weak self] in
                                guard let self, shouldDeliverCallback(for: runID) else { return }
                                onCompleted(invocationID, toolName, args, resultJSON, isError)
                            }
                        #endif
                    }
                }
            )
        }
        self.registrationTask = registrationTask
        registrationRunID = runID

        await registrationTask.value
        guard trackedRunID == runID, trackingGeneration == generation else { return }
        if registrationRunID == runID {
            self.registrationTask = nil
            registrationRunID = nil
        }
        trackingTask = Task { [weak self] in
            guard let self else { return }
            await tracker.waitForConnectionAfterRegistration(
                runID: runID,
                clientNameHint: clientNameHint
            )
        }
    }

    @MainActor private func shouldDeliverCallback(for runID: UUID) -> Bool {
        // `ServerNetworkManager` fires observer callbacks synchronously, but the
        // controller hops them to the main actor for UI mutation. A fast tool can
        // complete and the run can stop tracking before that hop executes. Deliver
        // already-fired callbacks when no newer run has taken ownership; still drop
        // callbacks after this controller starts tracking a different run.
        trackedRunID == runID || trackedRunID == nil
    }

    // MARK: - Continuation-Based API (used by headless providers)

    /// Start tracking and yield tool events into an `AsyncThrowingStream` continuation.
    /// This is the original API retained for headless provider compatibility.
    func startTracking(
        runID: UUID,
        clientNameHint: String,
        continuation: AsyncThrowingStream<AIStreamResult, any Swift.Error>.Continuation
    ) {
        trackingTask?.cancel()
        trackingTask = Task {
            await tracker.startEnhanced(
                runID: runID,
                clientNameHint: clientNameHint,
                onCalled: { invocationID, toolName, args in
                    let argsJSON = Self.encodeArgsToJSON(args)
                    let event = AIStreamResult(
                        type: "tool_call",
                        text: nil,
                        toolName: toolName,
                        toolArgs: argsJSON,
                        toolInvocationID: invocationID,
                        toolArgsJSON: argsJSON
                    )
                    continuation.yield(event)
                },
                onCompleted: { invocationID, toolName, args, resultJSON, isError in
                    let argsJSON = Self.encodeArgsToJSON(args)
                    let event = AIStreamResult(
                        type: "tool_result",
                        text: nil,
                        toolName: toolName,
                        toolArgs: argsJSON,
                        toolOutput: resultJSON,
                        toolInvocationID: invocationID,
                        toolResultJSON: resultJSON,
                        toolArgsJSON: argsJSON,
                        toolIsError: isError
                    )
                    continuation.yield(event)
                }
            )
        }
    }

    // MARK: - Lifecycle

    @MainActor func stopTracking() async {
        trackingGeneration &+= 1
        let stopGeneration = trackingGeneration
        let stoppedRunID = registrationRunID ?? trackedRunID
        let previousRegistrationTask = registrationTask
        let trackingToCancel = trackingTask
        trackedRunID = nil
        registrationRunID = nil
        trackingToCancel?.cancel()
        trackingTask = nil

        let stopTask = Task { [tracker, eventDeliveryMailbox, previousRegistrationTask, trackingToCancel, stoppedRunID] in
            if let previousRegistrationTask {
                await previousRegistrationTask.value
            }
            if let trackingToCancel {
                await trackingToCancel.value
            }
            await tracker.stop(ifTracking: stoppedRunID)
            await eventDeliveryMailbox.waitUntilIdle()
        }
        registrationTask = stopTask
        await stopTask.value

        guard trackingGeneration == stopGeneration, trackedRunID == nil else { return }
        registrationTask = nil
    }

    #if DEBUG
        func waitForPendingEventDeliveriesForTesting() async {
            await eventDeliveryMailbox.waitUntilIdle()
        }
    #endif

    // MARK: - Helpers

    /// Encode tool arguments to JSON string for display.
    static func encodeArgsToJSON(_ args: [String: Value]?) -> String? {
        guard let args, !args.isEmpty else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(args)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
