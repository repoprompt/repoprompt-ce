import Foundation
import MCP

@MainActor
struct AgentExploreMCPToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias HeartbeatOperation = AgentRunMCPToolService.HeartbeatOperation
    typealias StartRun = AgentRunMCPToolService.StartRun

    let toolName: String
    let captureRequestMetadata: () async -> RequestMetadata
    let requireTargetWindow: () throws -> WindowState
    let resolveSpawnSourceTabID: (_ metadata: RequestMetadata) async -> UUID?
    let resolveSpawnParentSessionID: (_ metadata: RequestMetadata, _ targetWindow: WindowState) async -> UUID?
    let bindCurrentRequestToTab: (_ tabID: UUID, _ metadata: RequestMetadata) async throws -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping HeartbeatOperation) async throws -> Value
    var beginAgentRunWait: (_ metadata: RequestMetadata, _ sessionIDs: Set<UUID>, _ timeoutSeconds: TimeInterval?) async -> UUID? = { _, _, _ in nil }
    var endAgentRunWait: (_ token: UUID, _ completion: AgentRunWaitScopeCompletion) async -> Void = { _, _ in }
    let startRun: StartRun
    var vcsService: VCSService = .shared
    var gitTargetResolver: GitRepoTargetResolver = .init()

    private var startWorktreeCoordinator: AgentMCPStartWorktreeCoordinator {
        AgentMCPStartWorktreeCoordinator(
            operationName: "agent_explore.start",
            vcsService: vcsService,
            gitTargetResolver: gitTargetResolver
        )
    }

    static func resolvedStartTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        try AgentRunMCPToolService.resolvedStartTimeoutSeconds(value)
    }

    func execute(args: [String: Value]) async throws -> Value {
        guard let op = AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased() else {
            throw MCPError.invalidParams("agent_explore op is required. Use start, poll, wait, or cancel.")
        }
        switch op {
        case "start":
            return try await executeStart(args: args)
        case "poll":
            return try await executeControl(args: args, op: op)
        case "wait":
            return try await executeControl(args: args, op: op)
        case "cancel":
            return try await executeControl(args: args, op: op)
        default:
            throw MCPError.invalidParams("Unsupported agent_explore op '\(op)'. Use start, poll, wait, or cancel.")
        }
    }

    private func executeStart(args: [String: Value]) async throws -> Value {
        try validateAllowedKeys(args, op: "start", allowed: Self.startKeys)
        let startMessages = try parseStartMessages(args)
        let messages = startMessages.messages
        let worktreeStartRequest = try startWorktreeCoordinator.parseRequest(args: args)
        try validateBatchWorktreeRequest(worktreeStartRequest, messageCount: messages.count)
        let detach = AgentMCPToolHelpers.parseBool(args["detach"]) ?? false
        let timeoutSeconds = try Self.resolvedStartTimeoutSeconds(args["timeout"])

        let metadata = await captureRequestMetadata()
        let context = try await resolveStartContext(metadata: metadata)
        let started = try await startExploreRuns(
            messages: messages,
            context: context,
            worktreeRequest: worktreeStartRequest
        )

        guard startMessages.isBatch, started.count > 1 else {
            let run = started[0]
            if detach || run.outcome.snapshot.status != .running || timeoutSeconds <= 0 {
                return decoratedStartValue(snapshot: run.outcome.snapshot, delivery: run.outcome.delivery)
            }
            return try await agentRunControlService.execute(args: [
                "op": .string("wait"),
                "session_id": .string(run.outcome.snapshot.sessionID.uuidString),
                "timeout": .double(timeoutSeconds)
            ])
        }

        let sessionIDs = started.map(\.outcome.snapshot.sessionID)
        if !detach, timeoutSeconds > 0 {
            return try await agentRunControlService.execute(args: [
                "op": .string("wait"),
                "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
                "timeout": .double(timeoutSeconds)
            ])
        }

        return await batchStartValue(
            sessionIDs: sessionIDs,
            result: detach ? "detached" : "poll",
            agentModeVM: context.agentModeVM
        )
    }

    private func executeControl(args: [String: Value], op: String) async throws -> Value {
        let allowed: Set<String> = switch op {
        case "poll": Self.pollKeys
        case "wait": Self.waitKeys
        case "cancel": Self.cancelKeys
        default: ["op"]
        }
        try validateAllowedKeys(args, op: op, allowed: allowed)

        let metadata = await captureRequestMetadata()
        let targetWindow = try requireTargetWindow()
        let agentModeVM = targetWindow.agentModeViewModel
        let caller = try await resolveExploreCaller(metadata: metadata, agentModeVM: agentModeVM)
        let sessionIDs = try await resolveReferencedSessionIDs(args: args, op: op, targetWindow: targetWindow, agentModeVM: agentModeVM)
        try validateExploreChildSessions(sessionIDs: sessionIDs, callerSessionID: caller.sourceSessionID, agentModeVM: agentModeVM)

        return try await agentRunControlService.execute(args: args)
    }

    private var agentRunControlService: AgentRunMCPToolService {
        AgentRunMCPToolService(
            toolName: toolName,
            captureRequestMetadata: captureRequestMetadata,
            requireTargetWindow: requireTargetWindow,
            resolveRequestedTabID: { _ in nil },
            resolveSpawnSourceTabID: resolveSpawnSourceTabID,
            resolveSpawnParentSessionID: resolveSpawnParentSessionID,
            bindCurrentRequestToTab: bindCurrentRequestToTab,
            withHeartbeat: withHeartbeat,
            beginAgentRunWait: beginAgentRunWait,
            endAgentRunWait: endAgentRunWait,
            startRun: startRun
        )
    }

    private enum StartMessages {
        case single(String)
        case batch([String])

        var messages: [String] {
            switch self {
            case let .single(message):
                [message]
            case let .batch(messages):
                messages
            }
        }

        var isBatch: Bool {
            if case .batch = self { return true }
            return false
        }
    }

    private struct ExploreStartContext {
        let metadata: RequestMetadata
        let targetWindow: WindowState
        let agentModeVM: AgentModeViewModel
        let callerSourceTabID: UUID
        let callerSessionID: UUID
        let parentSessionID: UUID
        let selection: AgentMCPSelectionResolver.ResolvedSelection
    }

    private struct StartedExploreRun {
        let index: Int
        let target: AgentModeViewModel.MCPSessionTarget
        let requestedMessage: String
        let outcome: AgentExternalMCPRunStarter.StartOutcome
    }

    private func parseStartMessages(_ args: [String: Value]) throws -> StartMessages {
        let rawMessage = AgentMCPToolHelpers.normalizedString(args["message"])
        let rawMessages = args["messages"]
        if rawMessage != nil, rawMessages != nil {
            throw MCPError.invalidParams("agent_explore start requires either message or messages, not both.")
        }
        if let rawMessage {
            return .single(rawMessage)
        }
        guard let rawMessages else {
            throw MCPError.invalidParams("message or messages is required for agent_explore start.")
        }
        guard let values = rawMessages.arrayValue, !values.isEmpty else {
            throw MCPError.invalidParams("messages must be a non-empty array of strings.")
        }
        var messages: [String] = []
        messages.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard let message = AgentMCPToolHelpers.normalizedString(value) else {
                throw MCPError.invalidParams("messages[\(index)] must be a non-empty string.")
            }
            messages.append(message)
        }
        return .batch(messages)
    }

    private func resolveStartContext(metadata: RequestMetadata) async throws -> ExploreStartContext {
        let targetWindow = try requireTargetWindow()
        guard let workspace = targetWindow.workspaceManager.activeWorkspace else {
            throw MCPError.invalidParams("No active workspace available for agent_explore.start.")
        }
        guard workspace.isSystemWorkspace == false else {
            throw MCPError.invalidParams("Cannot start an agent run from the default system workspace. Open or select a project workspace and try again.")
        }

        let agentModeVM = targetWindow.agentModeViewModel
        let caller = try await resolveExploreCaller(metadata: metadata, agentModeVM: agentModeVM)
        try agentModeVM.mcpValidateAgentRunSpawnAllowed(sourceTabID: caller.sourceTabID, isExploreOnly: true)

        let selection = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: .explore,
            availability: targetWindow.apiSettingsViewModel.agentModeAvailabilityContext
        )
        return ExploreStartContext(
            metadata: metadata,
            targetWindow: targetWindow,
            agentModeVM: agentModeVM,
            callerSourceTabID: caller.sourceTabID,
            callerSessionID: caller.sourceSessionID,
            parentSessionID: caller.sourceSessionID,
            selection: selection
        )
    }

    private func createFreshExploreTargets(
        count: Int,
        context: ExploreStartContext,
        inheritWorktreeBindings: Bool
    ) async throws -> [AgentModeViewModel.MCPSessionTarget] {
        var targets: [AgentModeViewModel.MCPSessionTarget] = []
        targets.reserveCapacity(count)
        do {
            for _ in 0 ..< count {
                let target = try await context.agentModeVM.mcpResolveOrCreateSessionTarget(
                    tabID: nil,
                    sessionID: nil,
                    createIfNeeded: true,
                    sessionName: nil,
                    parentSessionID: context.parentSessionID,
                    inheritWorktreeBindings: inheritWorktreeBindings
                )
                targets.append(target)
            }
            return targets
        } catch {
            await discardTargets(targets, agentModeVM: context.agentModeVM)
            throw error
        }
    }

    private func startExploreRuns(
        messages: [String],
        context: ExploreStartContext,
        worktreeRequest: AgentMCPStartWorktreeCoordinator.Request
    ) async throws -> [StartedExploreRun] {
        let targets = try await createFreshExploreTargets(
            count: messages.count,
            context: context,
            inheritWorktreeBindings: worktreeRequest.inheritParentWorktreeBindings
        )
        var started: [StartedExploreRun] = []
        started.reserveCapacity(messages.count)
        for (index, target) in targets.enumerated() {
            let message = messages[index]
            do {
                try await startWorktreeCoordinator.prepare(
                    request: worktreeRequest,
                    target: target,
                    targetWindow: context.targetWindow
                )
                let outcome: AgentExternalMCPRunStarter.StartOutcome
                do {
                    outcome = try await startExploreRun(target: target, message: message, context: context)
                } catch {
                    throw startWorktreeCoordinator.providerStartError(
                        error,
                        targetSessionID: target.sessionID,
                        agentModeVM: context.agentModeVM
                    )
                }
                started.append(StartedExploreRun(index: index, target: target, requestedMessage: message, outcome: outcome))
            } catch {
                await context.agentModeVM.mcpDiscardSessionTarget(target)
                let remainingTargets = Array(targets.dropFirst(index + 1))
                await discardTargets(remainingTargets, agentModeVM: context.agentModeVM)
                if error is CancellationError { throw error }
                guard !started.isEmpty else { throw error }
                let startedIDs = started.map(\.outcome.snapshot.sessionID.uuidString).joined(separator: ", ")
                throw MCPError.internalError(
                    "agent_explore.start failed after starting \(started.count) of \(messages.count) explore sessions. Already-started session_ids: \(startedIDs). Failed index: \(index). Error: \(error)"
                )
            }
        }
        return started
    }

    private func startExploreRun(
        target: AgentModeViewModel.MCPSessionTarget,
        message: String,
        context: ExploreStartContext
    ) async throws -> AgentExternalMCPRunStarter.StartOutcome {
        try await startRun(
            target,
            message,
            context.metadata,
            bindCurrentRequestToTab,
            context.agentModeVM,
            context.selection.agentRaw,
            context.selection.modelRaw,
            nil,
            .explore,
            nil
        )
    }

    private func validateBatchWorktreeRequest(
        _ request: AgentMCPStartWorktreeCoordinator.Request,
        messageCount: Int
    ) throws {
        guard messageCount > 1, request.mode == .create else { return }
        if request.path != nil {
            throw MCPError.invalidParams(
                "agent_explore.start with multiple messages cannot use an explicit worktree_path. Omit worktree_path so each child receives a distinct app-managed worktree."
            )
        }
        if request.branch != nil {
            throw MCPError.invalidParams(
                "agent_explore.start with multiple messages cannot use an explicit worktree_branch. Omit worktree_branch so each child receives a distinct branch."
            )
        }
    }

    private func discardTargets(
        _ targets: [AgentModeViewModel.MCPSessionTarget],
        agentModeVM: AgentModeViewModel
    ) async {
        for target in targets {
            await agentModeVM.mcpDiscardSessionTarget(target)
        }
    }

    private func resolveExploreCaller(
        metadata: RequestMetadata,
        agentModeVM: AgentModeViewModel
    ) async throws -> (sourceTabID: UUID, sourceSessionID: UUID) {
        guard let sourceTabID = await resolveSpawnSourceTabID(metadata),
              let sourceSession = agentModeVM.session(for: sourceTabID, createIfNeeded: false),
              let controlContext = sourceSession.mcpControlContext
        else {
            throw MCPError.invalidParams("agent_explore is only available from MCP-started Agent Mode sessions with a non-explore role.")
        }
        guard let taskLabelKind = controlContext.taskLabelKind else {
            throw MCPError.invalidParams("agent_explore is only available from MCP-started Agent Mode sessions with a non-explore role.")
        }
        guard taskLabelKind != .explore else {
            throw MCPError.invalidParams("Explore agents cannot start additional explore agents.")
        }
        return (sourceTabID, controlContext.sessionID)
    }

    private func resolveReferencedSessionIDs(
        args: [String: Value],
        op: String,
        targetWindow: WindowState,
        agentModeVM: AgentModeViewModel
    ) async throws -> [UUID] {
        if op == "cancel" {
            guard let raw = AgentMCPToolHelpers.normalizedString(args["session_id"]) else {
                throw MCPError.invalidParams("session_id is required for agent_explore cancel.")
            }
            return try await [resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)]
        }

        if AgentMCPToolHelpers.normalizedString(args["session_id"]) != nil, args["session_ids"] != nil {
            throw MCPError.invalidParams("Specify either session_id or session_ids, not both.")
        }
        if let raw = AgentMCPToolHelpers.normalizedString(args["session_id"]) {
            return try await [resolveControlSessionID(reference: raw, targetWindow: targetWindow, agentModeVM: agentModeVM)]
        }
        guard let sessionIDsValue = args["session_ids"] else {
            throw MCPError.invalidParams("session_id or session_ids is required for agent_explore \(op).")
        }
        guard let values = sessionIDsValue.arrayValue, !values.isEmpty else {
            throw MCPError.invalidParams("session_ids must be a non-empty array of session IDs.")
        }
        var resolved: [UUID] = []
        var seen: Set<UUID> = []
        for value in values {
            guard let reference = AgentMCPToolHelpers.normalizedString(value) else {
                throw MCPError.invalidParams("session_ids must contain only non-empty strings.")
            }
            let sessionID = try await resolveControlSessionID(reference: reference, targetWindow: targetWindow, agentModeVM: agentModeVM)
            if seen.insert(sessionID).inserted {
                resolved.append(sessionID)
            }
        }
        guard !resolved.isEmpty else {
            throw MCPError.invalidParams("session_ids did not resolve to any sessions.")
        }
        return resolved
    }

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

    private func validateExploreChildSessions(
        sessionIDs: [UUID],
        callerSessionID: UUID,
        agentModeVM: AgentModeViewModel
    ) throws {
        for sessionID in sessionIDs {
            guard let liveSession = try agentModeVM.authoritativeLiveSession(for: sessionID) else {
                throw MCPError.invalidParams("Session '\(sessionID.uuidString)' is not a live explore child of the current agent session.")
            }
            guard liveSession.parentSessionID == callerSessionID,
                  liveSession.mcpControlContext?.taskLabelKind == .explore
            else {
                throw MCPError.invalidParams("Session '\(sessionID.uuidString)' is not an explore child of the current agent session.")
            }
        }
    }

    private func decoratedStartValue(
        snapshot: AgentRunMCPSnapshot,
        delivery: AgentModeViewModel.MCPInstructionDispatch
    ) -> Value {
        var object = snapshot.asObject()
        if !snapshot.status.isTerminal, delivery != .startedRun {
            object["_meta"] = .object(["delivery": .string(delivery.rawValue)])
        }
        return .object(object)
    }

    private func batchStartValue(
        sessionIDs: [UUID],
        result: String,
        agentModeVM: AgentModeViewModel
    ) async -> Value {
        let snapshots = await refreshedSnapshots(sessionIDs: sessionIDs, agentModeVM: agentModeVM)
        let runningIDs = snapshots.filter { $0.status == .running }.map(\.sessionID)
        let terminalIDs = snapshots.filter(\.status.isTerminal).map(\.sessionID)
        let interestingIDs = snapshots.filter { $0.interaction != nil || $0.status.isTerminal }.map(\.sessionID)
        return .object([
            "start": .object([
                "mode": .string("many"),
                "result": .string(result),
                "started_count": .int(sessionIDs.count),
                "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
                "running_session_ids": .array(runningIDs.map { .string($0.uuidString) }),
                "terminal_session_ids": .array(terminalIDs.map { .string($0.uuidString) }),
                "interesting_session_ids": .array(interestingIDs.map { .string($0.uuidString) })
            ]),
            "session_ids": .array(sessionIDs.map { .string($0.uuidString) }),
            "snapshots": .array(snapshots.map { .object($0.asObject()) })
        ])
    }

    private func refreshedSnapshots(
        sessionIDs: [UUID],
        agentModeVM: AgentModeViewModel
    ) async -> [AgentRunMCPSnapshot] {
        var snapshots: [AgentRunMCPSnapshot] = []
        snapshots.reserveCapacity(sessionIDs.count)
        for sessionID in sessionIDs {
            if let registration = agentModeVM.mcpRegistration(sessionID: sessionID),
               let liveSnapshot = agentModeVM.mcpSnapshot(registration: registration)
            {
                snapshots.append(liveSnapshot)
            } else if let registration = agentModeVM.mcpRegistration(sessionID: sessionID),
                      let storedSnapshot = await AgentRunSessionStore.snapshot(for: registration)
            {
                snapshots.append(storedSnapshot)
            } else {
                snapshots.append(.expired(sessionID: sessionID))
            }
        }
        return snapshots
    }

    private func validateAllowedKeys(_ args: [String: Value], op: String, allowed: Set<String>) throws {
        for key in args.keys.sorted() where !allowed.contains(key) {
            throw MCPError.invalidParams(
                "agent_explore \(op) does not support '\(key)'. Supported fields: \(allowed.sorted().joined(separator: ", "))."
            )
        }
    }

    private static let startKeys = Set(["op", "message", "messages", "detach", "timeout"])
        .union(AgentMCPStartWorktreeCoordinator.Request.argumentKeys)
    private static let pollKeys: Set<String> = ["op", "session_id", "session_ids"]
    private static let waitKeys: Set<String> = ["op", "session_id", "session_ids", "timeout"]
    private static let cancelKeys: Set<String> = ["op", "session_id"]
}
