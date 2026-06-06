import Foundation
import MCP

struct OracleExportFile: Equatable {
    let path: String
    let instruction: String
}

struct OracleExportDestination: Equatable {
    let workspaceID: UUID
    let windowID: Int
    let tabID: UUID?
    let primaryRootPath: String
}

struct OracleExportRequest {
    let sourceTool: String
    let mode: String
    let message: String
    let chatID: String?
    let response: String?
    let destination: OracleExportDestination?

    init(
        sourceTool: String,
        mode: String,
        message: String,
        chatID: String?,
        response: String?,
        destination: OracleExportDestination? = nil
    ) {
        self.sourceTool = sourceTool
        self.mode = mode
        self.message = message
        self.chatID = chatID
        self.response = response
        self.destination = destination
    }
}

enum AgentOracleExport {
    static func instruction(path: String) -> String {
        let pathLiteral = jsonStringLiteral(path)
        return """
        Read the Oracle export with `read_file` using `{"path": \(pathLiteral)}`. Use this exact absolute `path` value verbatim without shortening or rewriting it, and use the file as planning context for this task.
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\(value)\""
        }
        return literal
    }

    static func oracleMarkdown(request: OracleExportRequest, exportedAt _: Date = Date()) -> String {
        let title = switch request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plan":
            "# Oracle Plan"
        case "review":
            "# Oracle Review"
        default:
            "# Oracle Response"
        }
        let response: String = if let responseText = request.response,
                                  !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            responseText
        } else {
            "_No response text was returned._"
        }
        return "\(title)\n\n\(response)"
    }
}

struct AgentRunWaitScopeCompletion: Equatable {
    enum Reason: String, Equatable {
        case snapshotReady = "snapshot_ready"
        case timedOut = "timed_out"
        case expired
        case cancelled
        case error
    }

    let reason: Reason
    let result: String?
    let winnerSessionID: UUID?
    let pendingSessionIDs: Set<UUID>
    let errorDescription: String?
}

private enum MultiWaitDisposition {
    case actionable(AgentRunMCPSnapshot)
    case nonActionableWake(AgentRunMCPSnapshot, AgentRunSessionStore.WakeReason)
    case timedOut
    case expired
    case cancelled
}

private struct WaitAnyResult {
    let sessionID: UUID
    let disposition: MultiWaitDisposition
}

private struct CancelledSingleWaitResolution {
    let rawValue: Value
    let completion: AgentRunWaitScopeCompletion
}

private final class WaitScopeCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCompletion: AgentRunWaitScopeCompletion?

    func set(_ completion: AgentRunWaitScopeCompletion) {
        lock.lock()
        storedCompletion = completion
        lock.unlock()
    }

    func get() -> AgentRunWaitScopeCompletion? {
        lock.lock()
        let completion = storedCompletion
        lock.unlock()
        return completion
    }
}

private let agentRunSteeringWakeNote = "Steering interrupted this wait; the agent run has not completed. After responding to the user, call agent_run.wait for this session again to resume waiting."
private let waitAnyLiveReconcileIntervalSeconds: TimeInterval = 2.0

@MainActor
struct AgentRunMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias HeartbeatOperation = @Sendable () async throws -> Value
    typealias StartRun = @MainActor (
        _ target: AgentModeViewModel.MCPSessionTarget,
        _ message: String,
        _ metadata: RequestMetadata,
        _ bindCurrentRequestToTab: @escaping AgentExternalMCPRunStarter.BindCurrentRequestToTab,
        _ agentModeVM: AgentModeViewModel,
        _ agentRaw: String?,
        _ modelRaw: String?,
        _ reasoningEffortRaw: String?,
        _ taskLabelKind: AgentModelCatalog.TaskLabelKind?,
        _ workflow: AgentWorkflowDefinition?
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome

    static let defaultWaitTimeoutSeconds: TimeInterval = 300
    static let defaultStartTaskLabelKind: AgentModelCatalog.TaskLabelKind = .pair

    static func defaultTaskLabelForStart(
        resolvedTabID: UUID?,
        workflow _: AgentWorkflowDefinition? = nil
    ) -> AgentModelCatalog.TaskLabelKind? {
        // `agent_run.start` creates a new session by default; when callers omit
        // `model_id`, resolve through the global Pair role default. Workflows do
        // not override that default. If a caller explicitly targets an existing
        // tab, leave that tab's current selection alone.
        resolvedTabID == nil ? defaultStartTaskLabelKind : nil
    }

    let toolName: String
    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveRequestedTabID: (_ args: [String: Value]) throws -> UUID?
    let resolveSpawnSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
    var validateSpawnRouting: (_ metadata: RequestMetadata, _ sourceTabID: UUID?) async throws -> Void = { _, _ in }
    let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
    var resolveSpawnParentSessionIDFromSourceTabID: ((_ sourceTabID: UUID, _ targetWindow: WindowState) async -> UUID?)?
    let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping HeartbeatOperation) async throws -> Value
    var beginAgentRunWait: (_ metadata: RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil }
    var endAgentRunWait: (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in }
    let startRun: StartRun
    var currentSnapshotProvider: (@Sendable (_ sessionID: UUID, _ agentModeVM: AgentModeViewModel) async -> AgentRunMCPSnapshot?)?
    var vcsService: VCSService = .shared
    var gitTargetResolver: GitRepoTargetResolver = .init()

    func execute(args: [String: Value]) async throws -> Value {
        let op = normalizedString(args["op"])?.lowercased() ?? "wait"
        if op != "start", containsStartWorktreeArguments(args) {
            throw MCPError.invalidParams("agent_run worktree arguments are only supported with op=start.")
        }
        switch op {
        case "start":
            return try await executeStart(args: args)
        case "poll":
            return try await executeWait(args: args, forcePoll: true)
        case "wait":
            return try await executeWait(args: args)
        case "cancel":
            return try await executeCancel(args: args)
        case "steer":
            return try await executeSteer(args: args)
        case "respond":
            return try await executeRespond(args: args)
        default:
            throw MCPError.invalidParams("Unsupported agent_run op '\(op)'. Use start, poll, wait, cancel, steer, or respond.")
        }
    }

    private func executeStart(args: [String: Value]) async throws -> Value {
        let message = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let worktreeStartRequest = try parseStartWorktreeRequest(args: args)
        // start always creates a new session — reject explicit session_id
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("agent_run.start always creates a new session. Use agent_run op=steer with session_id to continue an existing session.")
        }
        let detach = parseBool(args["detach"]) ?? false
        let timeoutSeconds = try parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds

        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_run.start.")
        }
        guard workspace.isSystemWorkspace == false else {
            throw MCPError.invalidParams("Cannot start an agent run from the default system workspace. Open or select a project workspace and try again.")
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let sourceTabID = await resolveSpawnSourceTabID(metadata)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartResolvedSource", tabID: sourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "clientName": metadata.clientName ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "sourceTabID": sourceTabID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "workflowID": workflow?.id ?? "nil",
                "workflowName": workflow?.displayName ?? "nil"
            ])
        #endif
        try await validateSpawnRouting(metadata, sourceTabID)
        try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: sourceTabID)
        let spawnParentSessionID: UUID? = if let sourceTabID,
                                             let resolveSpawnParentSessionIDFromSourceTabID
        {
            await resolveSpawnParentSessionIDFromSourceTabID(sourceTabID, targetWindow)
        } else {
            await resolveSpawnParentSessionID(metadata, targetWindow)
        }
        let resolvedTabID = try resolveRequestedTabID(args)
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartParentResolved", tabID: sourceTabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "windowID": metadata.windowID.map(String.init) ?? "nil",
                "sourceTabID": sourceTabID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "requestedTabID": resolvedTabID?.uuidString ?? "nil"
            ])
        #endif
        // A non-nil spawn source is only returned for a routed Agent Mode invocation.
        // Never degrade such a nested start into an orphan when its validated
        // parent Agent session has disappeared or cannot be recovered.
        if sourceTabID != nil, spawnParentSessionID == nil {
            throw MCPError.invalidParams("agent_run.start was routed from an Agent Mode run, but RepoPrompt could not resolve its parent Agent session. Refusing to create an unparented run; reconnect the agent MCP client or retry after the source session is active.")
        }

        // Compute the default task label before target creation. Omitted `model_id`
        // for agent_run.start resolves through the global Pair role default.
        let defaultTaskLabel = Self.defaultTaskLabelForStart(resolvedTabID: resolvedTabID, workflow: workflow)

        // Validate model selection before creating a target. Role labels resolve through global role defaults.
        let selection = try AgentMCPSelectionResolver.resolve(
            modelID: normalizedString(args["model_id"]),
            defaultTaskLabel: defaultTaskLabel,
            availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        )

        let sessionName = normalizedString(args["session_name"])
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: resolvedTabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: sessionName,
            parentSessionID: spawnParentSessionID,
            inheritWorktreeBindings: worktreeStartRequest.inheritParentWorktreeBindings
        )
        do {
            try await prepareWorktreeBindingIfNeeded(
                request: worktreeStartRequest,
                target: target,
                targetWindow: targetWindow,
                metadata: metadata
            )
        } catch {
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw error
        }
        #if DEBUG
            AgentModePerfDiagnostics.event("mcp.routing.agentRunStartTargetResolved", tabID: target.tabID, fields: [
                "connectionID": metadata.connectionID?.uuidString ?? "nil",
                "targetSessionID": target.sessionID?.uuidString ?? "nil",
                "parentSessionID": spawnParentSessionID?.uuidString ?? "nil",
                "inheritWorktreeBindings": String(worktreeStartRequest.inheritParentWorktreeBindings),
                "taskLabel": selection.taskLabelKind?.rawValue ?? "nil",
                "agent": selection.agentRaw ?? "nil",
                "model": selection.modelRaw ?? "nil",
                "targetOrigin": String(describing: target.origin)
            ])
        #endif
        let outcome: AgentExternalMCPRunStarter.StartOutcome
        do {
            outcome = try await startRun(
                target,
                message,
                metadata,
                bindCurrentRequestToTab,
                agentModeVM,
                selection.agentRaw,
                selection.modelRaw,
                nil,
                selection.taskLabelKind,
                workflow
            )
        } catch {
            let decoratedError = worktreeAwareProviderStartError(
                error,
                targetSessionID: target.sessionID,
                agentModeVM: agentModeVM
            )
            await agentModeVM.mcpDiscardSessionTarget(target)
            throw decoratedError
        }
        if detach || outcome.snapshot.status != .running || timeoutSeconds <= 0 {
            return decoratedRunValue(snapshot: outcome.snapshot, workflow: workflow, delivery: outcome.delivery)
        }
        return try await waitForInterestingState(
            sessionID: outcome.snapshot.sessionID,
            agentModeVM: agentModeVM,
            metadata: metadata,
            timeoutSeconds: timeoutSeconds,
            stage: "starting",
            message: "Waiting for the started run to finish or request input...",
            workflow: workflow,
            initialDelivery: outcome.delivery
        )
    }

    private func executeWait(args: [String: Value], forcePoll: Bool = false) async throws -> Value {
        if args["session_ids"] != nil {
            if forcePoll {
                return try await executePollMany(args: args)
            }
            return try await executeWaitAny(args: args)
        }

        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let timeoutSeconds = try forcePoll ? 0 : (parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds)
        let metadata = await captureRequestMetadata()
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if initialSnapshot.status != .running || timeoutSeconds <= 0 {
            return decoratedRunValue(snapshot: initialSnapshot)
        }
        return try await waitForInterestingState(
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            metadata: metadata,
            timeoutSeconds: timeoutSeconds,
            stage: "waiting",
            message: "Waiting for the agent run to finish or request input...",
            liveSnapshot: initialSnapshot
        )
    }

    private func executeWaitAny(args: [String: Value]) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)

        // Single-element waits should preserve the existing single-session response shape.
        if sessionIDs.count == 1 {
            var singleArgs = args
            singleArgs.removeValue(forKey: "session_ids")
            singleArgs["session_id"] = .string(sessionIDs[0].uuidString)
            return try await executeWait(args: singleArgs)
        }

        let timeoutSeconds = try parseTimeoutSeconds(args["timeout"]) ?? Self.defaultWaitTimeoutSeconds
        let metadata = await captureRequestMetadata()
        let initialSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        for snapshot in initialSnapshots where snapshot.status == .running {
            await reconcileStoreForBlockingWait(
                sessionID: snapshot.sessionID,
                currentSnapshot: snapshot,
                agentModeVM: agentModeVM
            )
        }
        print("[AgentRunSteeringWake] agent_run wait-any begin sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) timeout=\(timeoutSeconds) initial=\(statusSummary(initialSnapshots))")

        if let ready = initialSnapshots.first(where: { isInterestingSnapshot($0) }) {
            return decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: ready.status == .expired ? "expired" : "snapshot_ready",
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            )
        }

        if timeoutSeconds <= 0 {
            return decoratedMultiWaitValue(
                snapshot: initialSnapshots[0],
                sessionIDs: sessionIDs,
                result: "timed_out",
                snapshots: initialSnapshots,
                pendingSessionIDs: pendingSessionIDs(from: initialSnapshots)
            )
        }

        let waitScopeToken = await beginAgentRunWait(metadata, Set(sessionIDs), timeoutSeconds)
        do {
            let value = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                "waiting",
                "Waiting for the first agent run to finish or request input..."
            ) {
                try await waitForAnyInterestingState(
                    sessionIDs: sessionIDs,
                    agentModeVM: agentModeVM,
                    timeoutSeconds: timeoutSeconds,
                    initialSnapshots: initialSnapshots
                )
            }
            let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
            print("[AgentRunSteeringWake] agent_run wait-any result sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) reason=\(completion.reason.rawValue) winner=\(completion.winnerSessionID?.uuidString ?? "none") pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            return value
        } catch is CancellationError {
            if let value = await waitAnyCancellationInterruptValueIfResumable(
                sessionIDs: sessionIDs,
                agentModeVM: agentModeVM,
                fallbackSnapshots: initialSnapshots
            ) {
                let completion = waitScopeCompletion(from: value, fallbackSessionIDs: sessionIDs)
                print("[AgentRunSteeringWake] agent_run wait-any converted cancellation to interrupt sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) pending=\(completion.pendingSessionIDs.map(\.uuidString).sorted().joined(separator: ","))")
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, completion)
                }
                return value
            }
            let completion = AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: nil)
            print("[AgentRunSteeringWake] agent_run wait-any cancelled sessions=\(sessionIDs.map(\.uuidString).joined(separator: ","))")
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw CancellationError()
        } catch {
            let completion = AgentRunWaitScopeCompletion(reason: .error, result: "error", winnerSessionID: nil, pendingSessionIDs: Set(sessionIDs), errorDescription: String(describing: error))
            print("[AgentRunSteeringWake] agent_run wait-any error sessions=\(sessionIDs.map(\.uuidString).joined(separator: ",")) error=\(error)")
            if let waitScopeToken {
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
    }

    private func executePollMany(args: [String: Value]) async throws -> Value {
        let references = try parseSessionIDArray(args)
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionIDs = try await resolveControlSessionIDs(references, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        return decoratedMultiPollValue(sessionIDs: sessionIDs, snapshots: snapshots)
    }

    private func executeCancel(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let initialSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        if initialSnapshot.status == .expired {
            throw MCPError.invalidParams("This session control handle is no longer active.")
        }
        if initialSnapshot.status.isTerminal {
            throw MCPError.invalidParams("The run is not currently active (status: \(initialSnapshot.status.rawValue)) and cannot be cancelled.")
        }
        guard let session = agentModeVM.mcpControlledSession(sessionID: sessionID), session.runState.isActive else {
            throw MCPError.invalidParams("The run is not currently active and cannot be cancelled.")
        }
        let metadata = await captureRequestMetadata()
        let cancelResult = try await withHeartbeat(
            metadata.connectionID,
            toolName,
            "cancelling",
            "Cancelling the agent run..."
        ) {
            await agentModeVM.cancelAgentRun(tabID: session.tabID, completion: .terminalPublished)
            await Task.yield()
            return await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM).toValue()
        }
        if let parsed = cancelResult.objectValue.flatMap(snapshot(from:)) {
            return decoratedRunValue(snapshot: parsed)
        }
        return cancelResult
    }

    private func executeSteer(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let text = try resolveMessage(args["message"], name: "message")
        let workflow = try resolveWorkflow(args: args)
        let delivery: AgentModeViewModel.MCPInstructionDispatch
        let snapshot: AgentRunMCPSnapshot
        if let controlledSession = agentModeVM.mcpControlledSession(sessionID: sessionID),
           controlledSession.runState.isActive
        {
            // Clear stale snapshot before dispatching so that a previous turn's terminal
            // snapshot doesn't cause waitUntilInteresting to return immediately.
            guard await agentModeVM.rotateMCPWaitRegistrationForNewTurn(sessionID: sessionID) != nil else {
                throw MCPError.invalidParams("This session control handle is no longer active.")
            }
            delivery = try await agentModeVM.mcpDispatchInstruction(
                sessionID: sessionID,
                text: text,
                allowStartingRun: true,
                workflow: workflow
            )
            await Task.yield()
            snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        } else {
            // Mark follow-up pending so mcpSnapshot(for:) returns .running during the
            // async gap before the new run actually starts.  Also clear the store so
            // the previous turn's terminal snapshot doesn't block new snapshots.
            guard await agentModeVM.rotateMCPWaitRegistrationForNewTurn(sessionID: sessionID) != nil else {
                throw MCPError.invalidParams("This session control handle is no longer active.")
            }
            agentModeVM.setMCPFollowUpRunPending(sessionID: sessionID, true)
            let metadata = await captureRequestMetadata()
            // Carry forward the existing task label kind so `prepareCodexController()`
            // doesn't see a mismatch and invalidate the controller mid-follow-up.
            let existingSession = agentModeVM.mcpControlledSession(sessionID: sessionID)
            let existingTaskLabelKind = existingSession?.mcpControlContext?.taskLabelKind
            // Carry forward reasoning effort so `normalizeCodexSelectionForSession`
            // doesn't reset the effort that was set during the initial start call.
            let existingReasoningEffort = existingSession?.selectedReasoningEffortRaw
            let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: false,
                sessionName: nil
            )
            let outcome = try await startRun(
                target,
                text,
                metadata,
                bindCurrentRequestToTab,
                agentModeVM,
                nil,
                nil,
                existingReasoningEffort,
                existingTaskLabelKind,
                workflow
            )
            delivery = outcome.delivery
            snapshot = outcome.snapshot
        }
        await Task.yield()

        // Steer-and-wait: optionally block until the agent reaches an interesting state
        let shouldWait: Bool = {
            if let explicit = parseBool(args["wait"]) { return explicit }
            if args["timeout_seconds"] != nil { return true }
            return false
        }()
        let rawSteerTimeoutSeconds = args["timeout_seconds"]
        let ignoredTimeoutWarning: String?
        let steerTimeoutSeconds: TimeInterval?
        if shouldWait == false, rawSteerTimeoutSeconds != nil {
            ignoredTimeoutWarning = "Ignoring timeout_seconds because wait=false; the steering instruction was accepted without waiting."
            steerTimeoutSeconds = nil
        } else {
            ignoredTimeoutWarning = nil
            steerTimeoutSeconds = try parseTimeoutSeconds(rawSteerTimeoutSeconds)
        }
        let shouldBlockForSteeredOutput = delivery.isActiveRunDispatch
            ? snapshot.interaction == nil
            : (!snapshot.status.isTerminal && snapshot.interaction == nil)
        if shouldWait, shouldBlockForSteeredOutput {
            let metadata = await captureRequestMetadata()
            let timeout = steerTimeoutSeconds ?? Self.defaultWaitTimeoutSeconds
            if timeout > 0 {
                if delivery.isActiveRunDispatch, snapshot.status.isTerminal {
                    // Active steering can briefly observe a stale terminal snapshot from the
                    // previous/startup turn immediately after local dispatch. Reset the store
                    // so the steer waiter blocks for the provider's steering result instead
                    // of returning old output as if it came from the new instruction.
                    guard await agentModeVM.rotateMCPWaitRegistrationForNewTurn(sessionID: sessionID) != nil else {
                        throw MCPError.invalidParams("This session control handle is no longer active.")
                    }
                }
                return try await waitForInterestingState(
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    metadata: metadata,
                    timeoutSeconds: timeout,
                    stage: "steering",
                    message: "Waiting for the steered run to finish or request input...",
                    workflow: workflow,
                    initialDelivery: delivery,
                    liveSnapshot: snapshot.status == .running ? snapshot : nil
                )
            }
        }
        return decoratedRunValue(
            snapshot: snapshot,
            workflow: workflow,
            delivery: delivery,
            warning: ignoredTimeoutWarning
        )
    }

    private func executeRespond(args: [String: Value]) async throws -> Value {
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let sessionID = try await resolveControlSessionID(args, targetWindow: targetWindow, agentModeVM: agentModeVM)
        let interactionID = try requireUUID(args["interaction_id"], name: "interaction_id")
        let workflow = try resolveWorkflow(args: args)
        let payload = try parseResponsePayload(args: args)
        let dispatch = try await agentModeVM.mcpResolvePendingInteraction(
            sessionID: sessionID,
            interactionID: interactionID,
            payload: payload,
            workflow: workflow
        )
        await Task.yield()
        return await decoratedRunValue(
            snapshot: currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM),
            workflow: workflow,
            delivery: dispatch
        )
    }

    private func waitForInterestingState(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        metadata: RequestMetadata,
        timeoutSeconds: TimeInterval,
        stage: String,
        message: String,
        workflow: AgentWorkflowDefinition? = nil,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        liveSnapshot: AgentRunMCPSnapshot? = nil
    ) async throws -> Value {
        guard var registration = agentModeVM.mcpRegistration(sessionID: sessionID) else {
            throw MCPError.invalidParams("This session control handle is no longer active.")
        }
        // Defensive reconciliation: if live state says running but the store
        // still holds a stale terminal/interesting snapshot from a previous run,
        // reset the store epoch so waitUntilInteresting blocks on the new run
        // instead of returning immediately with stale state.
        if let liveSnapshot, liveSnapshot.status == .running {
            registration = await reconcileStoreForBlockingWait(
                registration: registration,
                currentSnapshot: liveSnapshot,
                agentModeVM: agentModeVM
            ) ?? registration
        }
        print("[AgentRunSteeringWake] agent_run wait entering sessionID=\(sessionID) stage=\(stage) timeout=\(timeoutSeconds)")
        let waitScopeToken = await beginAgentRunWait(metadata, [sessionID], timeoutSeconds)
        let completionBox = WaitScopeCompletionBox()
        let snapshot: Value
        do {
            snapshot = try await withHeartbeat(
                metadata.connectionID,
                toolName,
                stage,
                message
            ) {
                let disposition = await AgentRunSessionStore.waitUntilInteresting(
                    registration: registration,
                    timeoutSeconds: timeoutSeconds
                )
                switch disposition {
                case let .snapshotReady(triggeringSnapshot):
                    print("[AgentRunSteeringWake] agent_run wait returning snapshotReady sessionID=\(sessionID) status=\(triggeringSnapshot.status.rawValue)")
                    completionBox.set(AgentRunWaitScopeCompletion(reason: triggeringSnapshot.status == .expired ? .expired : .snapshotReady, result: triggeringSnapshot.status == .expired ? "expired" : "snapshot_ready", winnerSessionID: triggeringSnapshot.status == .expired ? nil : sessionID, pendingSessionIDs: triggeringSnapshot.status == .expired ? [sessionID] : [], errorDescription: nil))
                    return triggeringSnapshot.toValue()
                case let .noteworthySnapshot(triggeringSnapshot, reason):
                    print("[AgentRunSteeringWake] agent_run wait returning noteworthy sessionID=\(sessionID) reason=\(reason.rawValue) status=\(triggeringSnapshot.status.rawValue)")
                    let completion = reason == .steeringRequested
                        ? AgentRunWaitScopeCompletion(reason: .cancelled, result: "interrupted_by_steering", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil)
                        : AgentRunWaitScopeCompletion(reason: .snapshotReady, result: reason.rawValue, winnerSessionID: sessionID, pendingSessionIDs: [], errorDescription: nil)
                    completionBox.set(completion)
                    var object = triggeringSnapshot.asObject()
                    object["_meta"] = .object(["wake_reason": .string(reason.rawValue)])
                    return .object(object)
                case .timedOut:
                    print("[AgentRunSteeringWake] agent_run wait returning timedOut sessionID=\(sessionID)")
                    completionBox.set(AgentRunWaitScopeCompletion(reason: .timedOut, result: "timed_out", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
                    return await currentSnapshot(
                        sessionID: sessionID,
                        registration: agentModeVM.mcpRegistration(sessionID: sessionID) ?? registration,
                        agentModeVM: agentModeVM
                    ).toValue()
                case .expired:
                    print("[AgentRunSteeringWake] agent_run wait returning expired sessionID=\(sessionID)")
                    completionBox.set(AgentRunWaitScopeCompletion(reason: .expired, result: "expired", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
                    return AgentRunMCPSnapshot.expired(sessionID: sessionID).toValue()
                case .cancelled:
                    print("[AgentRunSteeringWake] agent_run wait observed cancelled waiter sessionID=\(sessionID)")
                    if let resolution = await cancelledSingleWaitResolution(sessionID: sessionID, agentModeVM: agentModeVM) {
                        completionBox.set(resolution.completion)
                        return resolution.rawValue
                    }
                    completionBox.set(AgentRunWaitScopeCompletion(reason: .cancelled, result: "cancelled", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: nil))
                    throw CancellationError()
                }
            }
        } catch {
            if error is CancellationError,
               let resolution = await cancelledSingleWaitResolution(sessionID: sessionID, agentModeVM: agentModeVM)
            {
                if let waitScopeToken {
                    await endAgentRunWait(waitScopeToken, resolution.completion)
                }
                return await finalDecoratedSingleWaitValue(
                    from: resolution.rawValue,
                    sessionID: sessionID,
                    agentModeVM: agentModeVM,
                    workflow: workflow,
                    initialDelivery: initialDelivery
                )
            }
            if let waitScopeToken {
                let completion = AgentRunWaitScopeCompletion(reason: error is CancellationError ? .cancelled : .error, result: error is CancellationError ? "cancelled" : "error", winnerSessionID: nil, pendingSessionIDs: [sessionID], errorDescription: String(describing: error))
                await endAgentRunWait(waitScopeToken, completion)
            }
            throw error
        }
        if let waitScopeToken {
            let completion = completionBox.get() ?? singleWaitScopeCompletion(from: snapshot, sessionID: sessionID)
            await endAgentRunWait(waitScopeToken, completion)
        }
        return await finalDecoratedSingleWaitValue(
            from: snapshot,
            sessionID: sessionID,
            agentModeVM: agentModeVM,
            workflow: workflow,
            initialDelivery: initialDelivery
        )
    }

    private func cancelledSingleWaitResolution(
        sessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) async -> CancelledSingleWaitResolution? {
        let snapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        guard snapshot.status != .expired else { return nil }

        if snapshot.status == .running, snapshot.interaction == nil {
            var object = snapshot.asObject()
            object["_meta"] = .object(["wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue)])
            return CancelledSingleWaitResolution(
                rawValue: .object(object),
                completion: AgentRunWaitScopeCompletion(
                    reason: .cancelled,
                    result: "interrupted_by_steering",
                    winnerSessionID: nil,
                    pendingSessionIDs: [sessionID],
                    errorDescription: nil
                )
            )
        }

        return CancelledSingleWaitResolution(
            rawValue: snapshot.toValue(),
            completion: singleWaitScopeCompletion(from: snapshot.toValue(), sessionID: sessionID)
        )
    }

    private func finalDecoratedSingleWaitValue(
        from rawValue: Value,
        sessionID: UUID,
        agentModeVM: AgentModeViewModel,
        workflow: AgentWorkflowDefinition?,
        initialDelivery: AgentModeViewModel.MCPInstructionDispatch?
    ) async -> Value {
        let resolvedSnapshot: AgentRunMCPSnapshot
        let wakeReason = rawValue.objectValue.flatMap(wakeReason(from:))
        if let parsedSnapshot = rawValue.objectValue.flatMap(snapshot(from:)) {
            resolvedSnapshot = parsedSnapshot
        } else {
            resolvedSnapshot = await currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM)
        }
        return decoratedRunValue(snapshot: resolvedSnapshot, workflow: workflow, delivery: initialDelivery, wakeReason: wakeReason)
    }

    private func waitAnyCancellationInterruptValueIfResumable(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        fallbackSnapshots: [AgentRunMCPSnapshot]
    ) async -> Value? {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        let snapshots = freshSnapshots.isEmpty ? fallbackSnapshots : freshSnapshots
        guard !snapshots.isEmpty else { return nil }

        if let ready = snapshots.first(where: { isInterestingSnapshot($0) && $0.status != .expired }) {
            return decoratedMultiWaitValue(
                snapshot: ready,
                sessionIDs: sessionIDs,
                result: "snapshot_ready",
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
            )
        }

        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        guard runningIDs.isEmpty == false else { return nil }
        let pendingIDs = snapshots.filter { !isInterestingSnapshot($0) && $0.status != .expired }.map(\.sessionID)
        return Self.decoratedMultiWaitInterruptValue(
            sessionIDs: sessionIDs,
            snapshots: snapshots,
            pendingSessionIDs: pendingIDs.isEmpty ? runningIDs : pendingIDs
        )
    }

    private func waitAnySteeringInterruptValue(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        triggeringSnapshot: AgentRunMCPSnapshot,
        latestSnapshots: [AgentRunMCPSnapshot]
    ) async -> Value {
        let freshSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        var snapshots = freshSnapshots.isEmpty ? latestSnapshots : freshSnapshots
        if snapshots.isEmpty {
            snapshots = [triggeringSnapshot]
        } else if snapshots.contains(where: { $0.sessionID == triggeringSnapshot.sessionID }) == false {
            snapshots.append(triggeringSnapshot)
        }
        let pendingIDs = pendingSessionIDs(from: snapshots)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        return Self.decoratedMultiWaitInterruptValue(
            sessionIDs: sessionIDs,
            snapshots: snapshots,
            pendingSessionIDs: pendingIDs.isEmpty && !runningIDs.isEmpty ? runningIDs : pendingIDs
        )
    }

    private nonisolated static func decoratedMultiWaitInterruptValue(
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot],
        pendingSessionIDs: [UUID]
    ) -> Value {
        let representative = sessionIDs.compactMap { sessionID in
            snapshots.first { $0.sessionID == sessionID && $0.status == .running }
        }.first ?? snapshots.first ?? AgentRunMCPSnapshot.expired(sessionID: sessionIDs[0])
        var object = representative.asObject()
        object.removeValue(forKey: "assistant_text")
        object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
        object["_meta"] = .object([
            "wake_reason": .string(AgentRunSessionStore.WakeReason.steeringRequested.rawValue),
            "note": .string(agentRunSteeringWakeNote)
        ])
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string("interrupted_by_steering"),
            "winner_session_id": .null,
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(pendingSessionIDs.map { .string($0.uuidString) }),
            "instruction": .string(agentRunSteeringWakeNote)
        ])
        object["snapshots"] = .array(snapshots.map { snapshot in
            var snapshotObject = snapshot.asObject()
            if !snapshot.status.isTerminal {
                snapshotObject.removeValue(forKey: "assistant_text")
            }
            return .object(snapshotObject)
        })
        return .object(object)
    }

    private nonisolated func waitForAnyInterestingState(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel,
        timeoutSeconds: TimeInterval,
        initialSnapshots: [AgentRunMCPSnapshot]
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        var latestSnapshots = initialSnapshots

        while true {
            if Task.isCancelled {
                if let value = await waitAnyCancellationInterruptValueIfResumable(
                    sessionIDs: sessionIDs,
                    agentModeVM: agentModeVM,
                    fallbackSnapshots: latestSnapshots
                ) {
                    return value
                }
                throw CancellationError()
            }
            let liveSnapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
            latestSnapshots = liveSnapshots
            if let ready = liveSnapshots.first(where: { isInterestingSnapshot($0) }) {
                return decoratedMultiWaitValue(
                    snapshot: ready,
                    sessionIDs: sessionIDs,
                    result: ready.status == .expired ? "expired" : "snapshot_ready",
                    pendingSessionIDs: pendingSessionIDs(from: liveSnapshots).filter { $0 != ready.sessionID }
                )
            }
            for snapshot in liveSnapshots where snapshot.status == .running {
                await reconcileStoreForBlockingWait(
                    sessionID: snapshot.sessionID,
                    currentSnapshot: snapshot,
                    agentModeVM: agentModeVM
                )
            }

            let remaining = Self.timeInterval(from: clock.now.duration(to: deadline))
            guard remaining > 0 else {
                print("[AgentRunSteeringWake] agent_run wait-any top-level timeout statuses=\(statusSummary(latestSnapshots))")
                return decoratedMultiWaitValue(
                    snapshot: latestSnapshots.first ?? initialSnapshots[0],
                    sessionIDs: sessionIDs,
                    result: "timed_out",
                    snapshots: latestSnapshots,
                    pendingSessionIDs: pendingSessionIDs(from: latestSnapshots)
                )
            }

            let sliceTimeout = min(remaining, waitAnyLiveReconcileIntervalSeconds)
            let registrations = await MainActor.run {
                sessionIDs.compactMap { agentModeVM.mcpRegistration(sessionID: $0) }
            }
            let result = await waitUntilFirstActionable(
                registrations: registrations,
                fallbackSessionID: sessionIDs[0],
                timeoutSeconds: sliceTimeout
            )
            switch result.disposition {
            case let .actionable(snapshot):
                let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
                return decoratedMultiWaitValue(
                    snapshot: snapshot,
                    sessionIDs: sessionIDs,
                    result: snapshot.status == .expired ? "expired" : "snapshot_ready",
                    pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != snapshot.sessionID }
                )
            case let .nonActionableWake(snapshot, reason):
                if reason == .steeringRequested {
                    print("[AgentRunSteeringWake] agent_run wait-any interrupted by steering wake sessionID=\(snapshot.sessionID) status=\(snapshot.status.rawValue)")
                    return await waitAnySteeringInterruptValue(
                        sessionIDs: sessionIDs,
                        agentModeVM: agentModeVM,
                        triggeringSnapshot: snapshot,
                        latestSnapshots: latestSnapshots
                    )
                }
                print("[AgentRunSteeringWake] agent_run wait-any ignored non-actionable wake sessionID=\(snapshot.sessionID) reason=\(reason.rawValue) status=\(snapshot.status.rawValue)")
                continue
            case .timedOut:
                continue
            case .expired:
                let snapshots = await collectCurrentSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
                if let ready = snapshots.first(where: { isInterestingSnapshot($0) }) {
                    return decoratedMultiWaitValue(
                        snapshot: ready,
                        sessionIDs: sessionIDs,
                        result: ready.status == .expired ? "expired" : "snapshot_ready",
                        pendingSessionIDs: pendingSessionIDs(from: snapshots).filter { $0 != ready.sessionID }
                    )
                }
                return decoratedMultiWaitValue(
                    snapshot: AgentRunMCPSnapshot.expired(sessionID: result.sessionID),
                    sessionIDs: sessionIDs,
                    result: "expired",
                    pendingSessionIDs: pendingSessionIDs(from: snapshots)
                )
            case .cancelled:
                print("[AgentRunSteeringWake] agent_run wait-any observed cancelled child waiter sessionID=\(result.sessionID)")
                if let value = await waitAnyCancellationInterruptValueIfResumable(
                    sessionIDs: sessionIDs,
                    agentModeVM: agentModeVM,
                    fallbackSnapshots: latestSnapshots
                ) {
                    return value
                }
                throw CancellationError()
            }
        }
    }

    private nonisolated func waitUntilFirstActionable(
        registrations: [AgentRunSessionStore.Registration],
        fallbackSessionID: UUID,
        timeoutSeconds: TimeInterval
    ) async -> WaitAnyResult {
        await withTaskGroup(of: WaitAnyResult.self) { group in
            for registration in registrations {
                group.addTask {
                    await Self.waitUntilActionable(registration: registration, timeoutSeconds: timeoutSeconds)
                }
            }
            guard let result = await group.next() else {
                return WaitAnyResult(sessionID: fallbackSessionID, disposition: .expired)
            }
            if isTimedOutDisposition(result.disposition) {
                while let nextResult = await group.next() {
                    guard isTimedOutDisposition(nextResult.disposition) else {
                        group.cancelAll()
                        return nextResult
                    }
                }
                return result
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func waitUntilActionable(
        registration: AgentRunSessionStore.Registration,
        timeoutSeconds: TimeInterval
    ) async -> WaitAnyResult {
        let sessionID = registration.sessionID
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while true {
            if Task.isCancelled {
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
            let remaining = timeInterval(from: clock.now.duration(to: deadline))
            guard remaining > 0 else {
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            }
            let disposition = await AgentRunSessionStore.waitUntilInteresting(
                registration: registration,
                timeoutSeconds: remaining
            )
            switch disposition {
            case let .snapshotReady(snapshot):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
            case let .noteworthySnapshot(snapshot, reason):
                if snapshot.isActionableForMCPWait {
                    return WaitAnyResult(sessionID: sessionID, disposition: .actionable(snapshot))
                }
                return WaitAnyResult(sessionID: sessionID, disposition: .nonActionableWake(snapshot, reason))
            case .timedOut:
                return WaitAnyResult(sessionID: sessionID, disposition: .timedOut)
            case .expired:
                return WaitAnyResult(sessionID: sessionID, disposition: .expired)
            case .cancelled:
                return WaitAnyResult(sessionID: sessionID, disposition: .cancelled)
            }
        }
    }

    #if DEBUG
        static func test_decoratedMultiWaitInterruptValue(
            sessionIDs: [UUID],
            snapshots: [AgentRunMCPSnapshot],
            pendingSessionIDs: [UUID]
        ) -> Value {
            decoratedMultiWaitInterruptValue(
                sessionIDs: sessionIDs,
                snapshots: snapshots,
                pendingSessionIDs: pendingSessionIDs
            )
        }

        static func test_waitUntilActionableDisposition(
            sessionID: UUID,
            timeoutSeconds: TimeInterval
        ) async -> (disposition: String, wakeReason: String?, sessionID: UUID, snapshotStatus: String?) {
            guard let registration = await AgentRunSessionStore.currentRegistration(for: sessionID) else {
                return ("expired", nil, sessionID, nil)
            }
            let result = await waitUntilActionable(registration: registration, timeoutSeconds: timeoutSeconds)
            switch result.disposition {
            case let .actionable(snapshot):
                return ("actionable", nil, result.sessionID, snapshot.status.rawValue)
            case let .nonActionableWake(snapshot, reason):
                return ("non_actionable_wake", reason.rawValue, result.sessionID, snapshot.status.rawValue)
            case .timedOut:
                return ("timed_out", nil, result.sessionID, nil)
            case .expired:
                return ("expired", nil, result.sessionID, nil)
            case .cancelled:
                return ("cancelled", nil, result.sessionID, nil)
            }
        }
    #endif

    private nonisolated static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private nonisolated func isTimedOutDisposition(_ disposition: MultiWaitDisposition) -> Bool {
        if case .timedOut = disposition { return true }
        return false
    }

    private nonisolated func statusSummary(_ snapshots: [AgentRunMCPSnapshot]) -> String {
        snapshots
            .map { "\($0.sessionID.uuidString.prefix(8)):\($0.status.rawValue)" }
            .joined(separator: ",")
    }

    private nonisolated func waitScopeCompletion(from value: Value, fallbackSessionIDs: [UUID]) -> AgentRunWaitScopeCompletion {
        let object = value.objectValue
        let wait = object?["wait"]?.objectValue
        let result = wait?["result"]?.stringValue
        let winnerSessionID = wait?["winner_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let pendingSessionIDs = Set(wait?["pending_session_ids"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? fallbackSessionIDs)
        let reason: AgentRunWaitScopeCompletion.Reason = switch result {
        case "timed_out": .timedOut
        case "expired": .expired
        case "cancelled", "interrupted_by_steering": .cancelled
        case "error": .error
        default: .snapshotReady
        }
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: result,
            winnerSessionID: winnerSessionID,
            pendingSessionIDs: pendingSessionIDs,
            errorDescription: nil
        )
    }

    private nonisolated func singleWaitScopeCompletion(from value: Value, sessionID: UUID) -> AgentRunWaitScopeCompletion {
        let status = value.objectValue?["status"]?.stringValue.flatMap(AgentRunMCPSnapshot.Status.init(rawValue:))
        let reason: AgentRunWaitScopeCompletion.Reason = status == .expired ? .expired : .snapshotReady
        return AgentRunWaitScopeCompletion(
            reason: reason,
            result: reason.rawValue,
            winnerSessionID: status == .expired ? nil : sessionID,
            pendingSessionIDs: [],
            errorDescription: nil
        )
    }

    private func decoratedRunValue(
        snapshot: AgentRunMCPSnapshot,
        workflow: AgentWorkflowDefinition? = nil,
        delivery: AgentModeViewModel.MCPInstructionDispatch? = nil,
        wakeReason: AgentRunSessionStore.WakeReason? = nil,
        warning: String? = nil
    ) -> Value {
        var object = snapshot.asObject()
        if let warning = warning?.trimmingCharacters(in: .whitespacesAndNewlines), !warning.isEmpty {
            object["warning"] = .string(warning)
        }
        if let workflow {
            object["workflow_id"] = .string(workflow.id)
            object["workflow_name"] = .string(workflow.displayName)
        }
        if let meta = metadataObject(for: snapshot, delivery: delivery, wakeReason: wakeReason) {
            object["_meta"] = .object(meta)
        }
        // After a steer dispatch into an active run, the assistant_text is from the
        // *previous* turn and would confuse the caller into thinking the steer produced
        // no new output.  Strip it so the caller sees a clean "instruction accepted" response.
        if !snapshot.status.isTerminal,
           delivery?.isActiveRunDispatch == true || wakeReason?.suppressesAssistantPreview == true
        {
            object.removeValue(forKey: "assistant_text")
        }
        if wakeReason == .steeringRequested {
            object["status_text"] = .string("Wait interrupted by a new steering instruction; the agent run is still running.")
            object["wait"] = .object([
                "result": .string("interrupted_by_steering"),
                "instruction": .string(agentRunSteeringWakeNote)
            ])
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiWaitValue(
        snapshot: AgentRunMCPSnapshot,
        sessionIDs: [UUID],
        result: String,
        snapshots: [AgentRunMCPSnapshot]? = nil,
        pendingSessionIDs: [UUID]? = nil
    ) -> Value {
        var object = snapshot.asObject()
        object["wait"] = .object([
            "mode": .string("any"),
            "result": .string(result),
            "winner_session_id": result == "timed_out"
                ? .null : .string(snapshot.sessionID.uuidString),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "waited_count": .int(sessionIDs.count),
            "pending_session_ids": .array(
                (pendingSessionIDs ?? sessionIDs.filter { $0 != snapshot.sessionID }).map { .string($0.uuidString) }
            ),
            "instruction": .null
        ])
        if let snapshots {
            object["snapshots"] = .array(snapshots.map { .object($0.asObject()) })
        }
        return .object(object)
    }

    private nonisolated func decoratedMultiPollValue(
        sessionIDs: [UUID],
        snapshots: [AgentRunMCPSnapshot]
    ) -> Value {
        let interestingIDs = snapshots.filter { isInterestingSnapshot($0) }.map(\.sessionID)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        let terminalIDs = snapshots.filter(\.status.isTerminal).map(\.sessionID)
        return .object([
            "poll": .object([
                "mode": .string("many"),
                "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
                "polled_count": .int(sessionIDs.count),
                "interesting_session_ids": .array(interestingIDs.map { .string($0.uuidString) }),
                "running_session_ids": .array(runningIDs.map { .string($0.uuidString) }),
                "terminal_session_ids": .array(terminalIDs.map { .string($0.uuidString) })
            ]),
            "snapshots": .array(snapshots.map { .object($0.asObject()) })
        ])
    }

    private func metadataObject(
        for snapshot: AgentRunMCPSnapshot,
        delivery: AgentModeViewModel.MCPInstructionDispatch?,
        wakeReason: AgentRunSessionStore.WakeReason?
    ) -> [String: Value]? {
        guard !snapshot.status.isTerminal else { return nil }
        var metadata: [String: Value] = [:]
        if let delivery {
            switch delivery {
            case .queuedFollowUp, .queuedClaudeInterrupt, .queuedACPInterrupt, .deliveredIntoWaitingContinuation, .dispatchedCodexTurn:
                metadata["delivery"] = .string(delivery.rawValue)
            case .startedRun:
                break
            }
        }
        if let wakeReason {
            metadata["wake_reason"] = .string(wakeReason.rawValue)
            if wakeReason == .steeringRequested {
                metadata["note"] = .string(agentRunSteeringWakeNote)
            }
        }
        return metadata.isEmpty ? nil : metadata
    }

    private func wakeReason(from object: [String: Value]) -> AgentRunSessionStore.WakeReason? {
        guard let raw = object["_meta"]?.objectValue?["wake_reason"]?.stringValue else { return nil }
        return AgentRunSessionStore.WakeReason(rawValue: raw)
    }

    private func snapshot(from object: [String: Value]) -> AgentRunMCPSnapshot? {
        guard let sessionIDRaw = object["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: sessionIDRaw),
              let statusRaw = object["status"]?.stringValue,
              let status = AgentRunMCPSnapshot.Status(rawValue: statusRaw)
        else {
            return nil
        }
        let session = object["session"]?.objectValue
        let agent = object["agent"]?.objectValue
        let interaction = object["interaction"]?.objectValue.flatMap(interaction(from:))
        let updatedAt = object["updated_at"]?.stringValue.flatMap(Self.timestampFormatter.date(from:)) ?? Date()
        let tabID = (session?["context_id"] ?? session?["tab_id"])?.stringValue.flatMap(UUID.init(uuidString:))
        let parentSessionID = session?["parent_session_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let failureReason = object["failure_reason"]?.stringValue.flatMap(AgentRunMCPSnapshot.FailureReason.init(rawValue:))
        let worktreeBindings = worktreeBindings(from: object)
        let activeWorktreeMerges = activeWorktreeMerges(from: object)
        return AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: tabID,
            sessionName: session?["name"]?.stringValue,
            agentRaw: agent?["id"]?.stringValue,
            agentDisplayName: agent?["name"]?.stringValue,
            modelRaw: agent?["model"]?.stringValue,
            reasoningEffortRaw: agent?["reasoning_effort"]?.stringValue,
            status: status,
            statusText: object["status_text"]?.stringValue,
            latestAssistantPreview: object["assistant_text"]?.stringValue,
            interaction: interaction,
            transcriptItemCount: object["transcript_item_count"]?.intValue ?? 0,
            updatedAt: updatedAt,
            parentSessionID: parentSessionID,
            failureReason: failureReason,
            worktreeBindings: worktreeBindings,
            activeWorktreeMerges: activeWorktreeMerges
        )
    }

    private func activeWorktreeMerges(from object: [String: Value]) -> [AgentSessionWorktreeMergeSummary] {
        guard let values = object["active_worktree_merges"]?.arrayValue else { return [] }
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let statusRaw = object["status"]?.stringValue,
                  let status = AgentSessionWorktreeMergeOperation.Status(rawValue: statusRaw),
                  let repositoryID = object["repository_id"]?.stringValue,
                  let repoKey = object["repo_key"]?.stringValue,
                  let sourceWorktreeID = object["source_worktree_id"]?.stringValue,
                  let sourceLabel = object["source_label"]?.stringValue,
                  let sourcePath = object["source_path"]?.stringValue,
                  let targetWorktreeID = object["target_worktree_id"]?.stringValue,
                  let targetLabel = object["target_label"]?.stringValue,
                  let targetPath = object["target_path"]?.stringValue,
                  let updatedAtRaw = object["updated_at"]?.stringValue,
                  let updatedAt = Self.timestampFormatter.date(from: updatedAtRaw)
            else { return nil }
            return AgentSessionWorktreeMergeSummary(
                id: id,
                status: status,
                sourceWorktreeID: sourceWorktreeID,
                sourceLabel: sourceLabel,
                sourceBranch: object["source_branch"]?.stringValue,
                sourcePath: sourcePath,
                targetWorktreeID: targetWorktreeID,
                targetLabel: targetLabel,
                targetBranch: object["target_branch"]?.stringValue,
                targetPath: targetPath,
                repositoryID: repositoryID,
                repoKey: repoKey,
                conflictFileCount: object["conflict_file_count"]?.intValue ?? 0,
                updatedAt: updatedAt
            )
        }
    }

    private func worktreeBindings(from object: [String: Value]) -> [AgentRunMCPSnapshot.WorktreeBinding] {
        if let values = object["worktree_bindings"]?.arrayValue {
            return values.compactMap { value in
                guard let object = value.objectValue else { return nil }
                return worktreeBinding(from: object)
            }
        }
        if let object = object["worktree"]?.objectValue,
           let binding = worktreeBinding(from: object)
        {
            return [binding]
        }
        return []
    }

    private func worktreeBinding(from object: [String: Value]) -> AgentRunMCPSnapshot.WorktreeBinding? {
        guard let id = object["id"]?.stringValue,
              let repositoryID = object["repository_id"]?.stringValue,
              let repoKey = object["repo_key"]?.stringValue,
              let logicalRootPath = object["logical_root_path"]?.stringValue,
              let worktreeID = object["worktree_id"]?.stringValue,
              let worktreeRootPath = object["worktree_root_path"]?.stringValue,
              let boundAtRaw = object["bound_at"]?.stringValue,
              let boundAt = Self.timestampFormatter.date(from: boundAtRaw),
              let source = object["source"]?.stringValue
        else {
            return nil
        }
        return AgentRunMCPSnapshot.WorktreeBinding(
            id: id,
            repositoryID: repositoryID,
            repoKey: repoKey,
            logicalRootPath: logicalRootPath,
            logicalRootName: object["logical_root_name"]?.stringValue,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            worktreeName: object["worktree_name"]?.stringValue,
            branch: object["branch"]?.stringValue,
            head: object["head"]?.stringValue,
            visualLabel: object["visual_label"]?.stringValue,
            visualColorHex: object["visual_color_hex"]?.stringValue,
            boundAt: boundAt,
            source: source,
            unavailable: object["unavailable"]?.boolValue ?? false
        )
    }

    private func interaction(from object: [String: Value]) -> AgentRunMCPSnapshot.Interaction? {
        guard let idRaw = object["id"]?.stringValue,
              let id = UUID(uuidString: idRaw),
              let kindRaw = object["kind"]?.stringValue,
              let kind = AgentRunMCPSnapshot.Interaction.Kind(rawValue: kindRaw),
              let responseTypeRaw = object["response_type"]?.stringValue,
              let responseType = AgentRunMCPSnapshot.Interaction.ResponseType(rawValue: responseTypeRaw)
        else {
            return nil
        }
        let options = object["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
            guard let optionObject = option.objectValue,
                  let label = optionObject["label"]?.stringValue else { return nil }
            return .init(label: label, description: optionObject["description"]?.stringValue)
        } ?? []
        let fields = object["fields"]?.arrayValue?.compactMap { field -> AgentRunMCPSnapshot.Interaction.Field? in
            guard let fieldObject = field.objectValue,
                  let id = fieldObject["id"]?.stringValue,
                  let prompt = fieldObject["prompt"]?.stringValue else { return nil }
            let fieldOptions = fieldObject["options"]?.arrayValue?.compactMap { option -> AgentRunMCPSnapshot.Interaction.Option? in
                guard let optionObject = option.objectValue,
                      let label = optionObject["label"]?.stringValue else { return nil }
                return .init(label: label, description: optionObject["description"]?.stringValue)
            } ?? []
            return .init(
                id: id,
                header: fieldObject["header"]?.stringValue,
                prompt: prompt,
                isSecret: fieldObject["is_secret"]?.boolValue == true,
                allowsOther: fieldObject["allows_other"]?.boolValue == true,
                options: fieldOptions
            )
        } ?? []
        let details = object["details"]?.arrayValue?.compactMap { detail -> AgentRunMCPSnapshot.Interaction.Detail? in
            guard let detailObject = detail.objectValue,
                  let label = detailObject["label"]?.stringValue,
                  let value = detailObject["value"]?.stringValue else { return nil }
            return .init(label: label, value: value, isCode: detailObject["is_code"]?.boolValue == true)
        } ?? []
        return .init(
            id: id,
            kind: kind,
            responseType: responseType,
            title: object["title"]?.stringValue,
            prompt: object["prompt"]?.stringValue,
            context: object["context"]?.stringValue,
            allowsMultiple: object["allows_multiple"]?.boolValue,
            options: options,
            fields: fields,
            details: details
        )
    }

    /// Reconciles the store with the live snapshot before a blocking wait.
    /// If the store still holds a stale "interesting" snapshot (terminal or with
    /// interaction) from a previous run but the live session has already restarted
    /// to `.running`, resets the store epoch so `waitUntilInteresting` blocks
    /// on the new run instead of returning immediately.
    private func reconcileStoreForBlockingWait(
        sessionID: UUID,
        currentSnapshot: AgentRunMCPSnapshot,
        agentModeVM: AgentModeViewModel
    ) async {
        guard let registration = agentModeVM.mcpRegistration(sessionID: sessionID) else { return }
        _ = await reconcileStoreForBlockingWait(
            registration: registration,
            currentSnapshot: currentSnapshot,
            agentModeVM: agentModeVM
        )
    }

    private func reconcileStoreForBlockingWait(
        registration: AgentRunSessionStore.Registration,
        currentSnapshot: AgentRunMCPSnapshot,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunSessionStore.Registration? {
        guard currentSnapshot.status == .running else { return registration }
        guard let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) else { return registration }
        let isStaleInteresting = storedSnapshot.isActionableForMCPWait
        guard isStaleInteresting else { return registration }
        guard let replacement = await agentModeVM.rotateMCPWaitRegistrationForNewTurn(
            sessionID: registration.sessionID
        ) else {
            return nil
        }
        await AgentRunSessionStore.signalSnapshot(currentSnapshot, registration: replacement)
        return replacement
    }

    private func collectCurrentSnapshots(sessionIDs: [UUID], agentModeVM: AgentModeViewModel) async -> [AgentRunMCPSnapshot] {
        var snapshots: [AgentRunMCPSnapshot] = []
        snapshots.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            await snapshots.append(currentSnapshot(sessionID: sessionID, agentModeVM: agentModeVM))
        }
        return snapshots
    }

    private nonisolated func isInterestingSnapshot(_ snapshot: AgentRunMCPSnapshot) -> Bool {
        snapshot.isActionableForMCPWait
    }

    private nonisolated func pendingSessionIDs(from snapshots: [AgentRunMCPSnapshot]) -> [UUID] {
        snapshots.filter { !isInterestingSnapshot($0) }.map(\.sessionID)
    }

    private func currentSnapshot(
        sessionID: UUID,
        registration suppliedRegistration: AgentRunSessionStore.Registration? = nil,
        agentModeVM: AgentModeViewModel
    ) async -> AgentRunMCPSnapshot {
        if let providedSnapshot = await currentSnapshotProvider?(sessionID, agentModeVM) {
            return providedSnapshot
        }
        guard let registration = suppliedRegistration ?? agentModeVM.mcpRegistration(sessionID: sessionID) else {
            return .expired(sessionID: sessionID)
        }
        if let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration) {
            return liveSnapshot
        }
        if let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration) {
            return storedSnapshot
        }
        return .expired(sessionID: sessionID)
    }

    private func resolveSessionID(reference: String?, workspace: WorkspaceModel, agentModeVM: AgentModeViewModel) async throws -> UUID? {
        guard let reference else { return nil }
        guard let sessionID = try await agentModeVM.mcpResolveSessionID(reference: reference, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found in the active workspace.")
        }
        return sessionID
    }

    private struct StartWorktreeRequest {
        enum Mode: Equatable {
            case none
            case existing(selector: String)
            case create
        }

        let mode: Mode
        let repoRoot: String?
        let branch: String?
        let baseRef: String?
        let path: URL?
        let label: String?
        let color: String?
        let allowExternalPath: Bool
        let inheritParentWorktreeBindings: Bool

        var hasExplicitWorktreeArgs: Bool {
            switch mode {
            case .none:
                false
            case .existing, .create:
                true
            }
        }
    }

    private struct StartWorktreeRepositoryContext {
        let repo: GitRepoDescriptor
        let allRepos: [GitRepoDescriptor]
        let visibleRoots: [WorkspaceRootRef]
        let logicalRoot: WorkspaceRootRef
    }

    private func containsStartWorktreeArguments(_ args: [String: Value]) -> Bool {
        [
            "worktree",
            "worktree_id",
            "worktree_create",
            "worktree_repo_root",
            "worktree_branch",
            "worktree_base_ref",
            "worktree_path",
            "worktree_label",
            "worktree_color",
            "allow_external_worktree_path",
            "inherit_worktree"
        ].contains { args[$0] != nil }
    }

    private func parseStartWorktreeRequest(args: [String: Value]) throws -> StartWorktreeRequest {
        let worktree = normalizedString(args["worktree"])
        let worktreeID = normalizedString(args["worktree_id"])
        let create = parseBool(args["worktree_create"]) ?? false
        if worktree != nil, worktreeID != nil {
            throw MCPError.invalidParams("worktree and worktree_id are mutually exclusive for agent_run.start.")
        }
        if create, worktree != nil || worktreeID != nil {
            throw MCPError.invalidParams("worktree_create is mutually exclusive with worktree and worktree_id for agent_run.start.")
        }
        let repoRoot = normalizedString(args["worktree_repo_root"])
        let branch = normalizedString(args["worktree_branch"])
        let baseRef = normalizedString(args["worktree_base_ref"])
        let label = normalizedString(args["worktree_label"])
        let color = normalizedString(args["worktree_color"])
        let allowExternalPath = parseBool(args["allow_external_worktree_path"]) ?? false
        let inheritParentWorktreeBindings = try parseOptionalStartBool(
            args["inherit_worktree"],
            name: "inherit_worktree"
        ) ?? true
        if let color, !GlobalSettingsStore.isValidWorktreeColorHex(color) {
            throw MCPError.invalidParams("worktree_color must be a valid #RRGGBB value.")
        }
        let path = try explicitStartWorktreePath(from: args["worktree_path"])
        let selector: String? = if let worktreeID {
            "@id:\(worktreeID)"
        } else {
            worktree
        }
        let mode: StartWorktreeRequest.Mode = if create {
            .create
        } else if let selector {
            .existing(selector: selector)
        } else {
            .none
        }
        if !create, path != nil {
            throw MCPError.invalidParams("worktree_path is only valid with worktree_create=true for agent_run.start.")
        }
        if !create, branch != nil || baseRef != nil {
            throw MCPError.invalidParams("worktree_branch and worktree_base_ref are only valid with worktree_create=true for agent_run.start.")
        }
        if !create, allowExternalPath {
            throw MCPError.invalidParams("allow_external_worktree_path is only valid with worktree_create=true for agent_run.start.")
        }
        if case .none = mode,
           repoRoot != nil || label != nil || color != nil
        {
            throw MCPError.invalidParams("worktree_repo_root, worktree_label, and worktree_color require worktree, worktree_id, or worktree_create=true for agent_run.start.")
        }
        return StartWorktreeRequest(
            mode: mode,
            repoRoot: repoRoot,
            branch: branch,
            baseRef: baseRef,
            path: path,
            label: label,
            color: color,
            allowExternalPath: allowExternalPath,
            inheritParentWorktreeBindings: inheritParentWorktreeBindings
        )
    }

    private func parseOptionalStartBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        default:
            if let parsed = parseBool(value) {
                return parsed
            }
            throw MCPError.invalidParams("\(name) must be a boolean.")
        }
    }

    private func prepareWorktreeBindingIfNeeded(
        request: StartWorktreeRequest,
        target: AgentModeViewModel.MCPSessionTarget,
        targetWindow: WindowState,
        metadata _: RequestMetadata
    ) async throws {
        guard let targetSessionID = target.sessionID else {
            throw MCPError.internalError("agent_run.start target did not resolve a session ID for worktree binding.")
        }
        let agentModeVM = targetWindow.agentModeViewModel
        if request.hasExplicitWorktreeArgs {
            do {
                let context = try await resolveStartWorktreeRepositoryContext(
                    request: request,
                    targetWindow: targetWindow
                )
                try validateStartWorktreeRuntimeRoot(context.logicalRoot, targetWindow: targetWindow)
                let worktree: GitWorktreeDescriptor
                switch request.mode {
                case .none:
                    throw MCPError.internalError("agent_run.start worktree preparation reached an unexpected empty worktree mode.")
                case let .existing(selector):
                    do {
                        worktree = try await gitTargetResolver.resolveWorktree(
                            selector: selector,
                            repo: context.repo,
                            allRepos: context.allRepos
                        )
                    } catch let error as GitRepoTargetResolverError {
                        throw MCPError.invalidParams(error.message)
                    }
                case .create:
                    worktree = try await createStartWorktree(request: request, context: context, sessionID: targetSessionID)
                }
                let identity = try persistStartVisualIdentity(for: worktree, request: request)
                let binding = makeStartWorktreeBinding(
                    worktree: worktree,
                    logicalRoot: context.logicalRoot,
                    visualIdentity: identity,
                    replacing: agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID).first {
                        standardizedPath($0.logicalRootPath) == standardizedPath(context.logicalRoot.standardizedFullPath)
                    }
                )
                _ = try agentModeVM.applyWorktreeBinding(binding, toSessionID: targetSessionID)
            } catch {
                throw worktreePreparationError(error)
            }
        }

        let bindings = agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID, tabID: target.tabID)
        if !bindings.isEmpty {
            try await materializeStartWorktreeRoots(
                bindings: bindings,
                sessionID: targetSessionID,
                targetWindow: targetWindow
            )
        }
    }

    private func materializeStartWorktreeRoots(
        bindings: [AgentSessionWorktreeBinding],
        sessionID: UUID,
        targetWindow: WindowState
    ) async throws {
        let projection = await targetWindow.mcpServer.materializeWorkspaceBindingProjection(
            sessionID: sessionID,
            bindings: bindings
        )
        guard let projection, !projection.isEmpty else {
            throw MCPError.invalidParams("Failed to materialize the bound worktree root for agent_run.start.")
        }
        let loadedRoots = await targetWindow.promptManager.workspaceFileContextStore.rootRefs(scope: projection.lookupRootScope)
        let loadedPaths = Set(loadedRoots.map { standardizedPath($0.standardizedFullPath) })
        let missing = projection.physicalRootRefs.filter { !loadedPaths.contains(standardizedPath($0.standardizedFullPath)) }
        guard missing.isEmpty else {
            let paths = missing.map(\.standardizedFullPath).joined(separator: ", ")
            throw MCPError.invalidParams("Failed to load bound worktree root(s) for agent_run.start: \(paths)")
        }
    }

    private func resolveStartWorktreeRepositoryContext(
        request: StartWorktreeRequest,
        targetWindow: WindowState
    ) async throws -> StartWorktreeRepositoryContext {
        let store = targetWindow.promptManager.workspaceFileContextStore
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        var repos: [GitRepoDescriptor] = []
        var seen = Set<String>()
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
                if seen.insert(descriptor.rootPath.lowercased()).inserted {
                    repos.append(descriptor)
                }
            }
        }
        guard let defaultRepo = repos.first else {
            throw MCPError.invalidParams("No Git repository found in loaded roots for agent_run.start worktree binding.")
        }
        let repo: GitRepoDescriptor
        var explicitLogicalRoot: WorkspaceRootRef?
        if let rawRepoRoot = request.repoRoot {
            if !rawRepoRoot.hasPrefix("@") {
                explicitLogicalRoot = explicitLogicalRootRef(for: rawRepoRoot, visibleRoots: visibleRoots)
            }
            do {
                repo = try await gitTargetResolver.resolveRepoRootToken(
                    rawRepoRoot,
                    allRepos: repos,
                    visibleRoots: visibleRoots,
                    defaultRepo: defaultRepo
                )
            } catch let error as GitRepoTargetResolverError {
                throw MCPError.invalidParams(error.message)
            }
        } else {
            repo = defaultRepo
        }
        let logicalRoot = try await logicalRoot(for: repo, explicitLogicalRoot: explicitLogicalRoot, visibleRoots: visibleRoots)
        return StartWorktreeRepositoryContext(repo: repo, allRepos: repos, visibleRoots: visibleRoots, logicalRoot: logicalRoot)
    }

    private func validateStartWorktreeRuntimeRoot(_ logicalRoot: WorkspaceRootRef, targetWindow: WindowState) throws {
        guard let primaryRoot = targetWindow.workspaceManager.activeWorkspace?.repoPaths.first else {
            return
        }
        let primary = standardizedPath((primaryRoot as NSString).expandingTildeInPath)
        guard standardizedPath(logicalRoot.standardizedFullPath) == primary else {
            throw MCPError.invalidParams(
                "agent_run.start worktree binding currently supports the primary workspace root only. Requested root '\(logicalRoot.name)' at \(logicalRoot.standardizedFullPath), but the provider runtime cwd resolves from primary root \(primary)."
            )
        }
    }

    private func createStartWorktree(
        request: StartWorktreeRequest,
        context: StartWorktreeRepositoryContext,
        sessionID: UUID
    ) async throws -> GitWorktreeDescriptor {
        let existingWorktrees = try await vcsService.listGitWorktrees(at: context.repo.rootURL)
        let mainRootPath = existingWorktrees.first(where: \.isMain)?.path ?? context.repo.rootPath
        let plan = try GitWorktreeDefaultPathPlanner.plan(
            GitWorktreeDefaultPathPlanner.Request(
                mainWorktreeRoot: URL(fileURLWithPath: mainRootPath),
                existingWorktreeRoots: existingWorktrees.map { URL(fileURLWithPath: $0.path) },
                explicitPath: request.path,
                branch: request.branch,
                baseRef: request.baseRef,
                detach: false,
                force: false,
                allowExternalPath: request.allowExternalPath,
                purpose: .agentStart(sessionID: sessionID.uuidString)
            )
        )
        return try await vcsService.createGitWorktree(request: plan.createRequest, at: context.repo.rootURL)
    }

    private func persistStartVisualIdentity(
        for worktree: GitWorktreeDescriptor,
        request: StartWorktreeRequest
    ) throws -> WorktreeVisualIdentity {
        let label = request.label ?? fallbackLabel(for: worktree)
        do {
            return try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                repositoryID: worktree.repository.repositoryID,
                worktreeID: worktree.worktreeID,
                label: label,
                colorHex: request.color
            )
        } catch let error as GlobalSettingsStore.WorktreeVisualIdentityError {
            throw MCPError.invalidParams("Invalid worktree visual identity: \(error)")
        }
    }

    private func makeStartWorktreeBinding(
        worktree: GitWorktreeDescriptor,
        logicalRoot: WorkspaceRootRef,
        visualIdentity: WorktreeVisualIdentity,
        replacing previous: AgentSessionWorktreeBinding?
    ) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: previous?.id ?? UUID().uuidString,
            repositoryID: worktree.repository.repositoryID,
            repoKey: worktree.repository.repoKey,
            logicalRootPath: logicalRoot.standardizedFullPath,
            logicalRootName: logicalRoot.name,
            worktreeID: worktree.worktreeID,
            worktreeRootPath: worktree.path,
            worktreeName: worktree.name,
            branch: worktree.branch,
            head: worktree.head,
            visualLabel: visualIdentity.label,
            visualColorHex: visualIdentity.colorHex,
            boundAt: previous?.worktreeID == worktree.worktreeID ? previous?.boundAt ?? Date() : Date(),
            source: "agent_run.start"
        )
    }

    private func worktreePreparationError(_ error: Error) -> Error {
        if error is MCPError { return error }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return MCPError.invalidParams("agent_run.start worktree preparation failed: \(message)")
    }

    private func worktreeAwareProviderStartError(
        _ error: Error,
        targetSessionID: UUID?,
        agentModeVM: AgentModeViewModel
    ) -> Error {
        guard let targetSessionID else { return error }
        let bindings = agentModeVM.worktreeBindings(forAgentSessionID: targetSessionID)
        guard let binding = bindings.first else { return error }
        let label = binding.visualLabel ?? binding.worktreeName ?? binding.branch ?? binding.worktreeID
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return MCPError.invalidParams(
            "Agent provider start failed after binding worktree '\(label)' at \(binding.worktreeRootPath). The worktree was not removed; use manage_worktree list to inspect or recover it. Error: \(message)"
        )
    }

    private func logicalRoot(
        for repo: GitRepoDescriptor,
        explicitLogicalRoot: WorkspaceRootRef?,
        visibleRoots: [WorkspaceRootRef]
    ) async throws -> WorkspaceRootRef {
        if let explicitLogicalRoot {
            return explicitLogicalRoot
        }
        for root in visibleRoots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)),
               GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path) == GitRepoRootAuthorization.canonicalPath(repo.rootPath)
            {
                return root
            }
        }
        if let exact = visibleRoots.first(where: { standardizedPath($0.standardizedFullPath) == standardizedPath(repo.rootPath) }) {
            return exact
        }
        if let first = visibleRoots.first {
            return first
        }
        throw MCPError.invalidParams("No visible workspace root is available for agent_run.start worktree binding.")
    }

    private func explicitLogicalRootRef(for rawRepoRoot: String, visibleRoots: [WorkspaceRootRef]) -> WorkspaceRootRef? {
        let canonical = standardizedPath((rawRepoRoot as NSString).expandingTildeInPath)
        let lowered = rawRepoRoot.lowercased()
        return visibleRoots.first { root in
            root.name.lowercased() == lowered
                || standardizedPath(root.standardizedFullPath) == canonical
                || standardizedPath(root.fullPath) == canonical
        }
    }

    private func explicitStartWorktreePath(from value: Value?) throws -> URL? {
        guard let raw = normalizedString(value) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            throw MCPError.invalidParams("worktree_path must be absolute or use ~/ for agent_run.start.")
        }
        return URL(fileURLWithPath: standardized)
    }

    private func fallbackLabel(for worktree: GitWorktreeDescriptor) -> String? {
        if let name = worktree.name, !name.isEmpty { return name }
        if let branch = worktree.branch, !branch.isEmpty { return branch }
        return worktree.isMain ? "main" : nil
    }

    private func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func resolveWorkflow(args: [String: Value]) throws -> AgentWorkflowDefinition? {
        let workflowID = normalizedString(args["workflow_id"])
        let workflowName = normalizedString(args["workflow_name"])
        if workflowID != nil, workflowName != nil {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        }
        guard let reference = workflowID ?? workflowName else {
            return nil
        }
        guard let workflow = AgentWorkflowStore.shared.resolveWorkflowReference(reference) else {
            throw MCPError.invalidParams("Workflow '\(reference)' was not found.")
        }
        return workflow
    }

    private func resolveMessage(_ value: Value?, name: String) throws -> String {
        let message = normalizedString(value) ?? ""
        guard !message.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return message
    }

    private struct ParsedAnswers {
        let flat: [String: [String]]
        let structured: [String: AgentAskUserAnswer]
        let hasStructuredObjects: Bool
    }

    private func parseResponsePayload(args: [String: Value]) throws -> AgentModeViewModel.MCPInteractionResponsePayload {
        let parsedAnswers: ParsedAnswers = if let rawAnswers = args["answers"] {
            try parseAnswers(rawAnswers)
        } else {
            ParsedAnswers(flat: [:], structured: [:], hasStructuredObjects: false)
        }

        let responseRaw = normalizedString(args["response"])
        let explicitSkip: Bool
        if let skipValue = args["skip"] {
            guard let skipBool = skipValue.boolValue else {
                throw MCPError.invalidParams("skip must be a boolean.")
            }
            explicitSkip = skipBool
        } else {
            explicitSkip = false
        }
        let responseIsSkipSentinel = responseRaw?.lowercased() == "skip"
        let isSkip = explicitSkip || responseIsSkipSentinel
        if isSkip, !parsedAnswers.flat.isEmpty || !parsedAnswers.structured.isEmpty {
            throw MCPError.invalidParams("skip cannot be combined with answers.")
        }
        if explicitSkip, responseRaw != nil, !responseIsSkipSentinel {
            throw MCPError.invalidParams("skip cannot be combined with response.")
        }
        let decisionRaw = responseRaw

        let content = try parseAgentJSONObject(args["content"], name: "content")
        let meta = try parseAgentJSONObject(args["meta"] ?? args["_meta"], name: "meta")

        return AgentModeViewModel.MCPInteractionResponsePayload(
            text: responseRaw,
            skip: isSkip,
            explicitSkip: explicitSkip,
            decisionRaw: isSkip ? nil : decisionRaw,
            amendment: normalizedString(args["amendment"]),
            answersByQuestionID: parsedAnswers.flat,
            askUserAnswersByQuestionID: parsedAnswers.structured,
            hasStructuredAnswerObjects: parsedAnswers.hasStructuredObjects,
            elicitationActionRaw: isSkip ? nil : responseRaw,
            elicitationContent: content,
            elicitationMeta: meta
        )
    }

    private func parseAgentJSONObject(_ value: Value?, name: String) throws -> [String: AgentJSONValue] {
        guard let value else { return [:] }
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("\(name) must be an object.")
        }
        return try object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
            partialResult[entry.key] = try agentJSONValue(from: entry.value)
        }
    }

    private func agentJSONValue(from value: Value) throws -> AgentJSONValue {
        switch value {
        case .null:
            return .null
        case let .bool(boolValue):
            return .bool(boolValue)
        case let .int(intValue):
            return .int(intValue)
        case let .double(doubleValue):
            return .double(doubleValue)
        case let .string(stringValue):
            return .string(stringValue)
        case let .array(values):
            return try .array(values.map { try agentJSONValue(from: $0) })
        case let .object(object):
            return try .object(object.reduce(into: [String: AgentJSONValue]()) { partialResult, entry in
                partialResult[entry.key] = try agentJSONValue(from: entry.value)
            })
        default:
            throw MCPError.invalidParams("Unsupported JSON value in MCP response payload.")
        }
    }

    private func parseAnswers(_ value: Value) throws -> ParsedAnswers {
        guard let object = value.objectValue else {
            throw MCPError.invalidParams("answers must be an object keyed by question ID.")
        }
        var flat = [String: [String]]()
        var structured = [String: AgentAskUserAnswer]()
        var hasStructuredObjects = false
        for entry in object {
            let questionID = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionID.isEmpty else {
                throw MCPError.invalidParams("answers cannot contain an empty question ID.")
            }

            if entry.value.objectValue != nil {
                hasStructuredObjects = true
            }
            let parsed = try parseAnswerValue(entry.value, questionID: questionID)
            flat[questionID] = parsed.answers
            structured[questionID] = parsed
        }
        return ParsedAnswers(flat: flat, structured: structured, hasStructuredObjects: hasStructuredObjects)
    }

    private func parseAnswerValue(_ value: Value, questionID: String) throws -> AgentAskUserAnswer {
        if let answer = value.stringValue {
            return AgentAskUserAnswer(
                answers: [answer],
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        if let answerArray = value.arrayValue {
            let answers = try parseAnswerStringArray(answerArray, name: "answers['\(questionID)']")
            return AgentAskUserAnswer(
                answers: answers,
                selectedOptions: [],
                customResponse: nil,
                skipped: false
            )
        }
        guard let answerObject = value.objectValue else {
            throw MCPError.invalidParams("answers['\(questionID)'] must be a string, array of strings, or object.")
        }

        let skipped = answerObject["skipped"]?.boolValue == true || answerObject["skip"]?.boolValue == true
        let selectedOptions = try parseOptionalAnswerStrings(
            answerObject["selected_options"] ?? answerObject["selectedOptions"],
            name: "answers['\(questionID)'].selected_options"
        ) ?? []
        let customResponse = normalizedString(answerObject["custom_response"] ?? answerObject["customResponse"])
        let explicitAnswers = try parseOptionalAnswerStrings(
            answerObject["answers"],
            name: "answers['\(questionID)'].answers"
        )

        let answers: [String] = if let explicitAnswers {
            explicitAnswers
        } else {
            selectedOptions + (customResponse.map { [$0] } ?? [])
        }

        if skipped {
            let hasAnswerContent = !answers.isEmpty || !selectedOptions.isEmpty || customResponse != nil
            guard !hasAnswerContent else {
                throw MCPError.invalidParams("answers['\(questionID)'] cannot be skipped and answered at the same time.")
            }
            return AgentAskUserAnswer(answers: [], selectedOptions: [], customResponse: nil, skipped: true)
        }

        return AgentAskUserAnswer(
            answers: answers,
            selectedOptions: selectedOptions,
            customResponse: customResponse,
            skipped: false
        )
    }

    private func parseOptionalAnswerStrings(_ value: Value?, name: String) throws -> [String]? {
        guard let value else { return nil }
        if let answer = value.stringValue {
            return [answer]
        }
        guard let answerArray = value.arrayValue else {
            throw MCPError.invalidParams("\(name) must be a string or array of strings.")
        }
        return try parseAnswerStringArray(answerArray, name: name)
    }

    private func parseAnswerStringArray(_ values: [Value], name: String) throws -> [String] {
        try values.map { element -> String in
            guard let text = element.stringValue else {
                throw MCPError.invalidParams("\(name) must contain only strings.")
            }
            return text
        }
    }

    /// Resolves session_id for control operations (poll/wait/cancel/steer/respond).
    /// Accepts both full UUIDs and short IDs for a uniform caller experience.
    private func resolveControlSessionID(
        reference raw: String,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available to resolve session_id '\(raw)'.")
        }
        guard let resolved = try await agentModeVM.mcpResolveSessionID(reference: raw, workspace: workspace) else {
            throw MCPError.invalidParams("Session '\(raw)' was not found. Provide a full UUID or a valid short ID.")
        }
        return resolved
    }

    private func resolveControlSessionID(
        _ args: [String: Value],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> UUID {
        guard let raw = normalizedString(args["session_id"]) else {
            throw MCPError.invalidParams("session_id is required for agent_run control operations.")
        }
        return try await resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)
    }

    private func parseSessionIDArray(_ args: [String: Value]) throws -> [String] {
        if normalizedString(args["session_id"]) != nil {
            throw MCPError.invalidParams("Specify either session_id or session_ids, not both.")
        }
        guard let raw = args["session_ids"] else {
            throw MCPError.invalidParams("session_ids is required for multi-session wait.")
        }
        guard let values = raw.arrayValue, !values.isEmpty else {
            throw MCPError.invalidParams("session_ids must be a non-empty array of session IDs.")
        }
        return try values.map { value -> String in
            guard let reference = normalizedString(value) else {
                throw MCPError.invalidParams("session_ids must contain only non-empty strings.")
            }
            return reference
        }
    }

    private func resolveControlSessionIDs(
        _ references: [String],
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> [UUID] {
        var resolved: [UUID] = []
        var seen: Set<UUID> = []
        for reference in references {
            let sessionID = try await resolveControlSessionID(
                reference: reference,
                targetWindow: targetWindow,
                agentModeVM: agentModeVM
            )
            if seen.insert(sessionID).inserted {
                resolved.append(sessionID)
            }
        }
        guard !resolved.isEmpty else {
            throw MCPError.invalidParams("session_ids did not resolve to any sessions.")
        }
        return resolved
    }

    private func requireUUID(_ value: Value?, name: String) throws -> UUID {
        guard let raw = normalizedString(value), let uuid = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("\(name) must be a UUID string.")
        }
        return uuid
    }

    private func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
        guard let normalized = normalizedString(value), !normalized.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return normalized
    }

    private func normalizedString(_ value: Value?) -> String? {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseBool(_ value: Value?) -> Bool? {
        switch value {
        case let .bool(boolValue):
            boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                true
            case "false", "0", "no":
                false
            default:
                nil
            }
        case let .int(intValue):
            intValue != 0
        case let .double(doubleValue):
            doubleValue != 0
        case .null, .array(_), .object:
            nil
        default:
            nil
        }
    }

    private func parseTimeoutSeconds(_ value: Value?) throws -> TimeInterval? {
        guard let value else { return nil }
        switch value {
        case let .int(intValue):
            let seconds = TimeInterval(intValue)
            guard seconds >= 0 else {
                throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
            }
            return seconds
        case let .double(doubleValue):
            guard doubleValue.isFinite, doubleValue >= 0 else {
                throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
            }
            return doubleValue
        case let .string(stringValue):
            guard let parsed = Double(stringValue), parsed.isFinite, parsed >= 0 else {
                throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
            }
            return parsed
        case .null:
            return nil
        case .bool(_), .array(_), .object:
            throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
        default:
            throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension AgentRunSessionStore.WakeReason {
    var suppressesAssistantPreview: Bool {
        switch self {
        case .instructionDelivered, .steeringRequested:
            true
        }
    }
}
