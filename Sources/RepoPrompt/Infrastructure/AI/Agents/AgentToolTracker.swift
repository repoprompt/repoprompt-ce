import Foundation
import MCP

/// Observes MCP tool usage for a single agent session and emits uniform events.
/// Tool observers are registered by runID (not connectionID) to survive connection handovers.
actor AgentToolTracker {
    private var trackedRunID: UUID?
    private var hasUnregistered = false

    /// Registers a tool-call observer for a discovery run (by runID).
    /// Observer registration happens BEFORE waiting for connection, ensuring it's ready
    /// when tools are called, even during connection handovers.
    func start(
        runID: UUID,
        clientNameHint: String?,
        connectionTimeoutSeconds: TimeInterval = 10.0,
        fallbackTimeoutSeconds: TimeInterval = 5.0,
        keepObserversOnTimeout: Bool = true,
        onTool: @escaping @Sendable (String) -> Void
    ) async {
        let manager = ServerNetworkManager.shared

        // Register observer FIRST, keyed by runID (survives connection handovers)
        await manager.registerToolCallObserver(for: runID, observer: onTool)
        trackedRunID = runID
        hasUnregistered = false

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

// SEARCH-HELPER: AgentToolTrackingController, TrackerLifecycle, TrackerBinding, ToolTracking
/// Shared lifecycle shim for MCP tool tracking across all provider runtimes.
///
/// Owns a single `AgentToolTracker` + `Task` + `runID` triple so provider owners
/// (Claude, Codex, ACP) don't need to duplicate this state. Each provider owner
/// keeps one instance per tab (via `[UUID: AgentToolTrackingController]` dictionary).
///
/// Starting tracking for the same `runID` is a no-op. Starting for a different `runID`
/// cancels the prior task and re-registers. Callbacks are suppressed if the `trackedRunID`
/// has changed by delivery time (stale-delivery protection).
///
/// Related:
/// - AgentToolTracker (actor): /RepoPrompt/Services/AI/Agents/AgentToolTracker.swift
/// - ClaudeAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Claude/ClaudeAgentModeCoordinator.swift
/// - CodexAgentModeCoordinator: /RepoPrompt/Services/AgentMode/Codex/CodexAgentModeCoordinator.swift
/// - ACPIntegratedAgentModeRunner: /RepoPrompt/Services/AgentMode/Runners/ACPIntegratedAgentModeRunner.swift
final class AgentToolTrackingController {
    private let tracker = AgentToolTracker()
    private var trackingTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var registrationRunID: UUID?
    private var trackingGeneration: UInt64 = 0
    private(set) var trackedRunID: UUID?

    // MARK: - Callback-Based API (used by Claude, Codex, ACP)

    /// Start tracking MCP tool events for a run, delivering callbacks on the main actor.
    ///
    /// - If `runID` matches the current tracked run, this is a no-op.
    /// - If a different run is tracked, the prior task is cancelled and the tracker re-registered.
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
        previousRegistrationTask?.cancel()
        trackingTask?.cancel()
        trackingTask = nil
        registrationTask = nil
        registrationRunID = nil
        trackedRunID = runID

        let registrationTask = Task { [tracker, previousRegistrationTask, previousRunID] in
            if let previousRegistrationTask {
                await previousRegistrationTask.value
            }
            guard !Task.isCancelled else { return }
            await tracker.stop(ifTracking: previousRunID)
            guard !Task.isCancelled else { return }
            await tracker.registerEnhancedObserver(
                runID: runID,
                onCalled: { [weak self] invocationID, toolName, args in
                    #if DEBUG
                        let scheduledAt = DispatchTime.now().uptimeNanoseconds
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                            EditFlowPerf.Dimensions(toolName: toolName, observerType: "event_call", runID: runID.uuidString)
                        )
                    #endif
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
                },
                onCompleted: { [weak self] invocationID, toolName, args, resultJSON, isError in
                    #if DEBUG
                        let scheduledAt = DispatchTime.now().uptimeNanoseconds
                        EditFlowPerf.lifecycleEvent(
                            EditFlowPerf.Lifecycle.MCPToolCall.mainActorScheduled,
                            EditFlowPerf.Dimensions(toolName: toolName, observerType: "event_completion", runID: runID.uuidString)
                        )
                    #endif
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
        let registrationToCancel = registrationTask
        let trackingToCancel = trackingTask
        trackedRunID = nil
        registrationToCancel?.cancel()
        trackingToCancel?.cancel()

        if let registrationToCancel {
            await registrationToCancel.value
        }
        if let trackingToCancel {
            await trackingToCancel.value
        }

        guard trackingGeneration == stopGeneration, trackedRunID == nil else { return }
        if registrationTask != nil {
            registrationTask = nil
            registrationRunID = nil
        }
        if trackingTask != nil {
            trackingTask = nil
        }
        await tracker.stop(ifTracking: stoppedRunID)
    }

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
