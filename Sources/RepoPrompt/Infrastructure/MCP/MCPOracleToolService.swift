import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

@MainActor
struct MCPOracleToolService {
    typealias RequestMetadata = MCPRequestMetadata
    typealias ResolvedTabContextSnapshot = MCPResolvedTabContextSnapshot
    typealias TabContextSnapshot = MCPTabContextSnapshot
    typealias ChatSendOperation = @Sendable () async throws -> [String: Value]
    typealias SendChat = @MainActor @Sendable (
        _ args: [String: Value],
        _ promptVM: PromptViewModel,
        _ tabContext: OracleViewModel.OracleSendTabContext?
    ) async throws -> [String: Value]
    typealias ExportOracleResponse = @MainActor @Sendable (OracleExportRequest) async throws -> OracleExportFile
    typealias StabilizedVirtualContext = @MainActor @Sendable (
        _ context: TabContextSnapshot
    ) async -> TabContextSnapshot
    typealias ResolveDelegatedReviewPackaging = @MainActor @Sendable (
        _ conversationTabID: UUID,
        _ conversationWorkspaceID: UUID?,
        _ conversationAgentSessionID: UUID?,
        _ conversationAgentRunID: UUID?
    ) async throws -> OracleViewModel.OracleSendPackagingContext?

    let askOracleToolName: String
    let oracleSendToolName: String
    let oracleChatLogToolName: String
    let promptVM: PromptViewModel
    let oracleVM: OracleViewModel
    let liveRunPurpose: MCPAppPhysicalCapabilityAdapters.LiveRunPurpose
    let resolveTabContextSnapshot: (RequestMetadata) throws -> ResolvedTabContextSnapshot
    let requireCurrentTabContext: (String) async throws -> TabContextSnapshot
    let stabilizedVirtualContext: StabilizedVirtualContext
    let resolveDelegatedReviewPackaging: ResolveDelegatedReviewPackaging
    let rebindChatSessionIfNeeded: (_ metadata: RequestMetadata, _ chatIDString: String) throws -> Void
    let resolveTabIDForAgentMode: (_ args: [String: Value], _ connectionID: UUID?) async throws -> UUID
    let requireTargetWindow: () throws -> WindowState
    let rawExplicitTabID: (_ args: [String: Value]) -> String?
    let sendStageProgress: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String) async -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping ChatSendOperation) async throws -> [String: Value]
    let resolveStartExecution: @MainActor (String, String?, UUID?) throws -> ResolvedOracleExecution
    let sendChat: SendChat
    let exportOracleResponse: ExportOracleResponse
    var jobCenter: MCPLongRunningJobCenter = WindowStatesManager.shared.longRunningJobs
    var registerJobExecution: (UUID, UUID?, String, @escaping () -> Void) -> Void = { _, _, _, _ in }
    var unregisterJobExecution: (UUID) -> Void = { _ in }
    /// Ticket admission fence: the exact captured workspace/tab must still exist after awaited preparation.
    /// Tab close cancels only admitting or registered jobs, so a tab removed during preparation is caught here.
    var admissionTargetExists: @MainActor (WindowState, MCPLongRunningJobCenter.Owner) -> Bool = { window, owner in
        if let workspaceID = owner.workspaceID {
            return window.workspaceManager.composeTab(for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: owner.tabID)) != nil
        }
        return window.workspaceManager.composeTab(with: owner.tabID) != nil
    }

    func executeOracleUtils(args: [String: Value]) async throws -> Value {
        let op = (args["op"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !op.isEmpty else {
            throw MCPError.invalidParams("oracle_utils requires an 'op' parameter.")
        }
        var forwarded = args
        forwarded.removeValue(forKey: "op")

        switch op {
        case "models":
            return try await executeOracleModelsUtility()
        case "sessions":
            return try await executeLiveOracleSessions(args: forwarded)
        default:
            throw MCPError.invalidParams("Unsupported oracle_utils op '\(op)'. Use models or sessions.")
        }
    }

    func executeOracleChatLog(args: [String: Value], invocationContext: ToolInvocationContext) async throws -> Value {
        guard let connectionID = invocationContext.connectionID else {
            throw MCPError.invalidParams("oracle_chat_log requires an active MCP connection")
        }

        let allowedArgs: Set = ["chat_id", "limit", "include_user"]
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_chat_log only accepts: chat_id, limit, include_user. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        if let limitValue = args["limit"], limitValue.intValue == nil {
            throw MCPError.invalidParams("limit must be an integer")
        }
        if let includeUserValue = args["include_user"], includeUserValue.boolValue == nil {
            throw MCPError.invalidParams("include_user must be a boolean")
        }
        if let chatIDRaw = args["chat_id"]?.stringValue,
           chatIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw MCPError.invalidParams("chat_id cannot be empty when provided")
        }

        let hasExplicitTabID = rawExplicitTabID(args) != nil
        let tabID: UUID
        let tabContext: TabContextSnapshot?
        if hasExplicitTabID {
            tabID = try await resolveTabIDForAgentMode(args, connectionID)
            let requestContext = try? await requireCurrentTabContext(oracleChatLogToolName)
            tabContext = (requestContext?.tabID == tabID) ? requestContext : nil
        } else {
            let currentContext = try await requireCurrentTabContext(oracleChatLogToolName)
            tabID = currentContext.tabID
            tabContext = currentContext
        }
        let targetWindow = try requireTargetWindow()
        let owner = await resolveAgentOracleOwner(tabID: tabID, targetWindow: targetWindow, tabContext: tabContext)

        let result = try await oracleVM.tool_oracleChatLog(
            args: args,
            tabID: tabID,
            agentModeSessionID: owner.agentSessionID,
            agentModeRunID: owner.runID
        )
        return .object(result)
    }

    // MARK: - ask_oracle (agent-mode only)

    func executeAskOracle(args: [String: Value], invocationContext: ToolInvocationContext) async throws -> Value {
        let operation = try MCPLongRunningJobOperation.parse(args)
        if operation.id != nil {
            return try await jobCenter.control(operation: operation, tool: askOracleToolName) { owner in
                try await authorizeJob(owner, tool: askOracleToolName, invocationContext: invocationContext)
            }
        }
        return try await executeAskOracleWorkflow(args: MCPLongRunningJobOperation.executionArgs(args), invocationContext: invocationContext, operation: operation)
    }

    private func executeAskOracleWorkflow(args: [String: Value], invocationContext: ToolInvocationContext, operation: MCPLongRunningJobOperation) async throws -> Value {
        let allowedArgs = Set(["message", "mode", "chat_id", "new_chat", "model", "images", "export_response"]).union(Self.diagnosticKeys)
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle only accepts: message, mode, chat_id, new_chat, model, images, export_response. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        try validateCommonOracleArgs(args)
        #if DEBUG
            let diagnostics = try OracleViewModel.OracleRequestDiagnostics.parse(args)
        #endif
        let imageRequests = try Self.parseOracleImageRequests(args["images"])

        guard let connectionID = invocationContext.connectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let exportResponse = try parseExportResponseFlag(args)
        let route = try resolveConversationRoute(args: args, missingChatIDStartsNew: true)
        let (isStartRoute, continuationChatID, modelOverride): (Bool, String?, String?) = switch route {
        case let .start(primaryModelOverride): (true, nil, primaryModelOverride)
        case let .continuation(chatID): (false, chatID, nil)
        case .implicitContinuation:
            throw MCPError.internalError("ask_oracle resolved an invalid implicit continuation route")
        }
        let targetWindow = try requireTargetWindow()

        let tabID = try await resolveTabIDForAgentMode(args, connectionID)
        let requestContext = try? await requireCurrentTabContext(askOracleToolName)
        let virtualContext = (requestContext?.tabID == tabID) ? requestContext : nil
        if let continuationChatID {
            guard let session = oracleVM.resolveSession(id: continuationChatID) else {
                throw MCPError.invalidParams("Chat with ID '\(continuationChatID)' not found")
            }
            guard let sessionTabID = session.composeTabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(continuationChatID)' is not bound to a compose tab. Use a chat_id from the current tab."
                )
            }
            guard sessionTabID == tabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(continuationChatID)' belongs to a different tab. ask_oracle can only continue chats from the current tab."
                )
            }
        }

        let ticketPurpose: MCPRunPurpose? = if case .start = operation { await liveRunPurpose(connectionID) } else { nil }
        let owner = await resolveAgentOracleOwner(tabID: tabID, targetWindow: targetWindow, tabContext: virtualContext)
        if ticketPurpose == .agentModeRun,
           virtualContext?.activeAgentSessionID == nil || virtualContext?.runID == nil
        {
            throw MCPError.invalidParams("Ticket admission requires the active Agent session/run context")
        }
        var tabContext: OracleViewModel.OracleSendTabContext
        if let virtualContext, virtualContext.tabID == tabID {
            tabContext = try await oracleSendTabContext(
                from: virtualContext,
                owner: owner,
                origin: .askOracle,
                mode: modeRaw,
                imageRequests: imageRequests
            )
        } else {
            guard let tabSnapshot = targetWindow.workspaceManager.composeTabSnapshot(for: tabID) else {
                throw MCPError.internalError("Unable to resolve compose tab context for ask_oracle")
            }
            let lookupContext = try await oraclePackagingLookupContext(owner: owner)
            let transientImages = try await loadOracleImages(
                imageRequests,
                lookupContext: lookupContext,
                sessionAttachmentPaths: sessionAttachmentPaths(
                    for: imageRequests,
                    tabID: tabID,
                    owner: owner
                )
            )
            let reviewGitContext = await promptVM.freezePromptGitReviewContext(
                workspaceID: targetWindow.workspaceManager.activeWorkspace?.id,
                tabID: tabID,
                sessionID: owner.agentSessionID,
                bindings: owner.worktreeBindingState.bindings ?? [],
                base: "HEAD"
            )
            let workspaceID = targetWindow.workspaceManager.activeWorkspace?.id
            let directPackaging = OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: workspaceID.map {
                    targetWindow.workspaceManager.selectionRevisionForMCP(
                        workspaceID: $0,
                        tabID: tabID
                    )
                } ?? 0,
                sourceAgentSessionID: owner.agentSessionID,
                sourceAgentRunID: owner.runID,
                promptText: tabSnapshot.promptText,
                selection: tabSnapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext,
                provenance: .direct
            )
            let packaging = try await reviewPackaging(
                mode: modeRaw,
                conversationTabID: tabID,
                conversationWorkspaceID: workspaceID,
                owner: owner,
                direct: directPackaging
            )
            tabContext = OracleViewModel.OracleSendTabContext(
                tabID: tabID,
                workspaceID: workspaceID,
                origin: .askOracle,
                agentModeSessionID: owner.agentSessionID,
                agentModeRunID: owner.runID,
                packaging: packaging,
                transientImages: transientImages
            )
        }

        if case .blocking = operation, let invocationID = invocationContext.metadata.invocationID {
            tabContext.toolSettlement = targetWindow.agentModeViewModel.oracleToolSettlementCallbacks(tabID: tabID, sessionID: owner.agentSessionID, runID: owner.runID, invocationID: invocationID, toolName: askOracleToolName)
        }
        #if DEBUG
            tabContext.requestDiagnostics = diagnostics
        #endif
        let exportDestination: OracleExportDestination? = if exportResponse {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: ticketPurpose == nil ? targetWindow.workspaceManager.activeWorkspace : targetWindow.workspaceManager.workspaces.first(where: { $0.id == tabContext.workspaceID }),
                windowID: targetWindow.windowID,
                tabID: tabID,
                lookupContext: tabContext.packaging.lookupContext ?? .visibleWorkspace
            )
        } else {
            nil
        }

        var chatArgs: [String: Value] = [
            "message": .string(message),
            "mode": .string(modeRaw),
            "new_chat": .bool(isStartRoute)
        ]
        if let continuationChatID {
            chatArgs["chat_id"] = .string(continuationChatID)
        }
        if let modelOverride {
            chatArgs["model"] = .string(modelOverride)
        }

        let capturedChatArgs = chatArgs
        if case let .start(detach, timeout) = operation {
            if isStartRoute {
                tabContext.resolvedStartExecution = try resolveStartExecution(modeRaw, modelOverride, tabContext.workspaceID)
            }
            let jobOwner = MCPLongRunningJobCenter.Owner(windowID: targetWindow.windowID, workspaceID: tabContext.workspaceID, tabID: tabID, sessionID: ticketPurpose == .agentModeRun ? virtualContext?.activeAgentSessionID : nil, runID: ticketPurpose == .agentModeRun ? virtualContext?.runID : nil)
            let snapshot = try await jobCenter.start(tool: askOracleToolName, owner: jobOwner, admissible: {
                try requireAdmissionTarget(targetWindow, jobOwner)
            }, register: { id, cancel in
                registerJobExecution(id, jobOwner.runID, askOracleToolName, cancel)
            }, unregister: unregisterJobExecution) { progress in
                var capturedTabContext = tabContext
                capturedTabContext.jobProgress = progress
                await progress.phase("message_send", stage: "generating")
                var result = try await sendChat(capturedChatArgs, promptVM, capturedTabContext)
                if exportResponse {
                    await progress.phase("response_export", stage: "exporting")
                    result = try await exportSettledReply(
                        result, sourceTool: askOracleToolName, mode: modeRaw, message: message,
                        fallbackChatID: continuationChatID, destination: exportDestination, ticketBacked: true
                    )
                }
                return .object(result)
            }
            if detach { return snapshot.value() }
            return await jobCenter.store.wait(id: snapshot.id, timeout: timeout)?.value() ?? MCPLongRunningJobCenter.expired(id: snapshot.id)
        }

        await sendStageProgress(connectionID, askOracleToolName, "starting", "Starting Oracle...")
        var result = try await withHeartbeat(
            connectionID,
            askOracleToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            try await sendChat(capturedChatArgs, promptVM, tabContext)
        }

        if exportResponse {
            result = try await exportSettledReply(
                result, sourceTool: askOracleToolName, mode: modeRaw, message: message,
                fallbackChatID: continuationChatID, destination: exportDestination, ticketBacked: false
            )
        }

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle complete")
        return .object(result)
    }

    // MARK: - oracle_send

    private static var diagnosticKeys: Set<String> {
        #if DEBUG
            OracleViewModel.OracleRequestDiagnostics.argumentKeys
        #else
            []
        #endif
    }

    private static let oracleSendExecutionKeys: Set<String> = Set(["message", "mode", "chat_id", "new_chat", "model", "export_response"]).union(diagnosticKeys)

    func executeOracleSend(args: [String: Value], invocationContext: ToolInvocationContext) async throws -> Value {
        let operation = try MCPLongRunningJobOperation.parse(args)
        if operation.id != nil {
            return try await jobCenter.control(operation: operation, tool: oracleSendToolName) { owner in
                try await authorizeJob(owner, tool: oracleSendToolName, invocationContext: invocationContext)
            }
        }
        guard case let .start(detach, timeout) = operation else {
            return try await executeOracleSendWorkflow(args: args, invocationContext: invocationContext)
        }
        let executionArgs = MCPLongRunningJobOperation.executionArgs(args)
        guard executionArgs.keys.allSatisfy({ $0.hasPrefix("_") || Self.oracleSendExecutionKeys.contains($0) }) else { throw MCPError.invalidParams("oracle_send start accepts only message, mode, chat_id, new_chat, model, export_response") }
        try validateCommonOracleArgs(executionArgs)
        #if DEBUG
            _ = try OracleViewModel.OracleRequestDiagnostics.parse(executionArgs)
        #endif
        _ = try parseExportResponseFlag(executionArgs)
        let route = try resolveConversationRoute(args: executionArgs, missingChatIDStartsNew: false)
        let purpose = if let connection = invocationContext.connectionID { await liveRunPurpose(connection) } else { MCPRunPurpose.unknown }
        if purpose != .agentModeRun, case let .continuation(chatID) = route {
            try rebindChatSessionIfNeeded(invocationContext.metadata, chatID)
        }
        let context = try await requireCurrentTabContext(oracleSendToolName)
        let window = try requireTargetWindow()
        if purpose == .agentModeRun, context.activeAgentSessionID == nil || context.runID == nil {
            throw MCPError.invalidParams("Ticket admission requires the active Agent session/run context")
        }
        var capturedArgs = executionArgs
        var implicitSessionID: UUID?
        if case .implicitContinuation = route {
            if let candidate = oracleVM.resolveImplicitOracleContinuationCandidate(tabID: context.tabID, activateInUI: false, agentModeSessionID: purpose == .agentModeRun ? context.activeAgentSessionID : nil, agentModeRunID: purpose == .agentModeRun ? context.runID : nil) {
                implicitSessionID = candidate.id
            } else {
                capturedArgs["new_chat"] = .bool(true)
            }
        }
        let resolvedOwner = if purpose == .agentModeRun {
            await resolveAgentOracleOwner(tabID: context.tabID, targetWindow: window, tabContext: context)
        } else {
            AgentOracleOwner(agentSessionID: nil, runID: nil, worktreeBindingState: .notApplicable)
        }
        let mode = executionArgs["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        var sendContext = try await oracleSendTabContext(
            from: context,
            owner: resolvedOwner,
            origin: .oracleSend,
            mode: mode
        )
        sendContext.implicitContinuationSessionID = implicitSessionID
        if capturedArgs["new_chat"]?.boolValue == true {
            sendContext.resolvedStartExecution = try resolveStartExecution(mode, capturedArgs["model"]?.stringValue, sendContext.workspaceID)
        }
        let exportDestination: OracleExportDestination? = if try parseExportResponseFlag(executionArgs) {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: window.workspaceManager.workspaces.first(where: { $0.id == sendContext.workspaceID }),
                windowID: window.windowID,
                tabID: sendContext.tabID,
                lookupContext: sendContext.packaging.lookupContext ?? .visibleWorkspace
            )
        } else { nil }
        let prepared = PreparedOracleSend(context: sendContext, exportDestination: exportDestination)
        let owner = MCPLongRunningJobCenter.Owner(windowID: window.windowID, workspaceID: context.workspaceID, tabID: context.tabID, sessionID: purpose == .agentModeRun ? context.activeAgentSessionID : nil, runID: purpose == .agentModeRun ? context.runID : nil)
        let frozenArgs = capturedArgs
        let snapshot = try await jobCenter.start(tool: oracleSendToolName, owner: owner, admissible: {
            try requireAdmissionTarget(window, owner)
        }, register: { id, cancel in
            registerJobExecution(id, owner.runID, oracleSendToolName, cancel)
        }, unregister: unregisterJobExecution) { progress in
            await progress.phase("preparing", stage: "preparing")
            return try await executeOracleSendWorkflow(args: frozenArgs, invocationContext: invocationContext, prepared: prepared, jobProgress: progress)
        }
        if detach { return snapshot.value() }
        return await jobCenter.store.wait(id: snapshot.id, timeout: timeout)?.value() ?? MCPLongRunningJobCenter.expired(id: snapshot.id)
    }

    /// Never rebinds: a replacement tab is a different owner, so a closed target rejects the start.
    private func requireAdmissionTarget(_ window: WindowState, _ owner: MCPLongRunningJobCenter.Owner) throws {
        guard admissionTargetExists(window, owner) else {
            throw MCPError.invalidRequest("Tab context '\(owner.tabID.uuidString)' was closed before the job was admitted")
        }
    }

    private struct PreparedOracleSend {
        let context: OracleViewModel.OracleSendTabContext
        let exportDestination: OracleExportDestination?
    }

    private func authorizeJob(_ owner: MCPLongRunningJobCenter.Owner, tool: String, invocationContext: ToolInvocationContext) async throws {
        let context = try await requireCurrentTabContext(tool)
        let window = try requireTargetWindow()
        guard window.windowID == owner.windowID, context.tabID == owner.tabID, context.workspaceID == owner.workspaceID else {
            throw MCPError.invalidParams("job_id belongs to a different workspace/context; bind the context_id from its start snapshot")
        }
        let purpose = if let connection = invocationContext.connectionID { await liveRunPurpose(connection) } else { MCPRunPurpose.unknown }
        if purpose == .agentModeRun, context.activeAgentSessionID == nil || context.runID == nil {
            throw MCPError.invalidParams("Ticket controls require the active Agent session/run context")
        }
        let sessionID = purpose == .agentModeRun ? context.activeAgentSessionID : nil
        let runID = purpose == .agentModeRun ? context.runID : nil
        guard sessionID == owner.sessionID, runID == owner.runID else {
            throw MCPError.invalidParams("job_id belongs to a different Agent session/run")
        }
    }

    private func executeOracleSendWorkflow(args: [String: Value], invocationContext: ToolInvocationContext, prepared: PreparedOracleSend? = nil, jobProgress: MCPLongRunningJobProgress? = nil) async throws -> Value {
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !Self.oracleSendExecutionKeys.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_send only accepts: message, mode, chat_id, new_chat, model, export_response. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        try validateCommonOracleArgs(args)
        #if DEBUG
            let diagnostics = try OracleViewModel.OracleRequestDiagnostics.parse(args)
        #endif
        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let exportResponse = try parseExportResponseFlag(args)
        let route = try resolveConversationRoute(args: args, missingChatIDStartsNew: false)
        let continuationChatID: String? = switch route {
        case .start, .implicitContinuation: nil
        case let .continuation(chatID): chatID
        }

        let connectionID = prepared == nil ? invocationContext.connectionID : nil
        let runPurpose: MCPRunPurpose = if let connectionID {
            await liveRunPurpose(connectionID)
        } else {
            .unknown
        }
        let targetWindow: WindowState? = if prepared == nil, exportResponse || runPurpose == .agentModeRun {
            try requireTargetWindow()
        } else {
            nil
        }
        let metadata = invocationContext.metadata
        if prepared == nil { _ = try resolveTabContextSnapshot(metadata) }
        var tabContext: OracleViewModel.OracleSendTabContext

        if prepared == nil, runPurpose != .agentModeRun, let continuationChatID {
            try rebindChatSessionIfNeeded(metadata, continuationChatID)
        }

        if let prepared {
            tabContext = prepared.context
        } else {
            let context = try await requireCurrentTabContext(oracleSendToolName)
            if runPurpose == .agentModeRun, let targetWindow {
                let owner = await resolveAgentOracleOwner(tabID: context.tabID, targetWindow: targetWindow, tabContext: context)
                tabContext = try await oracleSendTabContext(
                    from: context,
                    owner: owner,
                    origin: .oracleSend,
                    mode: modeRaw
                )
            } else {
                tabContext = try await oracleSendTabContext(
                    from: context,
                    origin: .oracleSend,
                    mode: modeRaw
                )
            }
        }

        if prepared == nil, runPurpose == .agentModeRun, let targetWindow, let invocationID = metadata.invocationID {
            tabContext.toolSettlement = targetWindow.agentModeViewModel.oracleToolSettlementCallbacks(tabID: tabContext.tabID, sessionID: tabContext.agentModeSessionID, runID: tabContext.agentModeRunID, invocationID: invocationID, toolName: oracleSendToolName)
        }
        tabContext.jobProgress = jobProgress
        #if DEBUG
            tabContext.requestDiagnostics = diagnostics
        #endif
        let exportDestination: OracleExportDestination? = if let prepared {
            prepared.exportDestination
        } else if exportResponse, let targetWindow {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: targetWindow.workspaceManager.activeWorkspace,
                windowID: targetWindow.windowID,
                tabID: tabContext.tabID,
                lookupContext: tabContext.packaging.lookupContext ?? .visibleWorkspace
            )
        } else {
            nil
        }

        await sendStageProgress(connectionID, oracleSendToolName, "starting", "Starting Oracle...")

        var chatArgs = args
        chatArgs.removeValue(forKey: "export_response")
        for key in Self.diagnosticKeys {
            chatArgs.removeValue(forKey: key)
        }

        let capturedTabContext = tabContext
        let capturedChatArgs = chatArgs
        await jobProgress?.phase("message_send", stage: "generating")
        var result: [String: Value] = if prepared != nil {
            // Ticket workers must not resolve heartbeat delivery from a disconnected request.
            try await sendChat(capturedChatArgs, promptVM, capturedTabContext)
        } else {
            try await withHeartbeat(
                connectionID,
                oracleSendToolName,
                "waiting",
                "Waiting for Oracle response..."
            ) {
                try await sendChat(capturedChatArgs, promptVM, capturedTabContext)
            }
        }

        if exportResponse {
            await jobProgress?.phase("response_export", stage: "exporting")
            let requestedChatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            result = try await exportSettledReply(
                result, sourceTool: oracleSendToolName, mode: modeRaw, message: message,
                fallbackChatID: (requestedChatID?.isEmpty == false) ? requestedChatID : nil,
                destination: exportDestination, ticketBacked: prepared != nil
            )
        }

        await sendStageProgress(connectionID, oracleSendToolName, "complete", "Oracle complete")
        return .object(result)
    }

    // MARK: - Shared helpers

    /// Optional export failures must not discard an already-settled Oracle response.
    /// Blocking non-group cancellation retains its request-owned cancellation contract.
    func exportSettledOracleResponse(
        _ reply: [String: Value], request: OracleExportRequest, ticketBacked: Bool = false
    ) async throws -> [String: Value] {
        var result = reply
        if Task.isCancelled, ticketBacked || request.groupResult != nil {
            result["oracle_export_error"] = Self.exportCancellationNotice
            return result
        }
        do {
            let export = try await exportOracleResponse(request)
            result["oracle_export_path"] = .string(export.path)
            result["oracle_export_instruction"] = .string(export.instruction)
        } catch is CancellationError {
            guard ticketBacked || request.groupResult != nil else { throw CancellationError() }
            result["oracle_export_error"] = Self.exportCancellationNotice
        } catch {
            // Export may have written output before failing. Keep response truth and
            // recovery handles without exposing arbitrary exporter error details.
            result["oracle_export_error"] = Self.exportFailureNotice
        }
        return result
    }

    /// Optional-export boundary for a settled reply: assembles the export request, including
    /// group decoding. A ticket worker already holds a paid reply, so a cancelled ticket or a
    /// malformed group degrades to a safe `oracle_export_error` notice instead of failing the
    /// ticket. Blocking callers keep the strict decoder's throwing contract.
    private func exportSettledReply(
        _ reply: [String: Value],
        sourceTool: String,
        mode: String,
        message: String,
        fallbackChatID: String?,
        destination: OracleExportDestination?,
        ticketBacked: Bool
    ) async throws -> [String: Value] {
        var result = reply
        if ticketBacked, Task.isCancelled {
            result["oracle_export_error"] = Self.exportCancellationNotice
            return result
        }
        let groupResult: OracleGroupResult?
        do {
            groupResult = try Self.decodeOracleGroupResultForExport(reply)
        } catch {
            guard ticketBacked else { throw error }
            // Decoder diagnostics stay out of the notice, matching exporter failures.
            result["oracle_export_error"] = Self.exportFailureNotice
            return result
        }
        return try await exportSettledOracleResponse(reply, request: OracleExportRequest(
            sourceTool: sourceTool,
            mode: mode,
            message: message,
            chatID: reply["chat_id"]?.stringValue ?? fallbackChatID,
            response: reply["response"]?.stringValue,
            groupResult: groupResult,
            reconciliationGuidance: reply["oracle_reconciliation_guidance"]?.stringValue,
            destination: destination
        ), ticketBacked: ticketBacked)
    }

    private static let exportCancellationNotice = Value.string(
        "Oracle export cancelled; output may remain. Recover the settled result using the returned chat IDs."
    )

    private static let exportFailureNotice = Value.string(
        "Oracle export failed; output may remain. Recover the settled result using the returned chat IDs."
    )

    /// Single route boundary for every Oracle entry point, so route-contract failures always
    /// surface as `invalidParams` before admission, rebinding, packaging, or sending.
    private func resolveConversationRoute(
        args: [String: Value], missingChatIDStartsNew: Bool
    ) throws -> OracleConversationRoute {
        let chatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedModelOverride = try parseOracleModelOverride(args["model"])
        do {
            return try OracleConversationRoute.resolve(
                chatID: (chatID?.isEmpty == false) ? chatID : nil,
                newChat: args["new_chat"]?.boolValue ?? false,
                modelOverride: requestedModelOverride,
                whenMissingChatID: missingChatIDStartsNew ? .startNew : .continueCurrent
            )
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    static func decodeOracleGroupResultForExport(_ result: [String: Value]) throws -> OracleGroupResult? {
        guard result["oracle_group_id"] != nil else { return nil }
        do {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(OracleGroupResult.self, from: data)
        } catch {
            throw MCPError.internalError(
                "Oracle returned an invalid grouped result for export: \(error.localizedDescription)"
            )
        }
    }

    private func parseExportResponseFlag(_ args: [String: Value]) throws -> Bool {
        guard let value = args["export_response"] else { return false }
        guard let boolValue = value.boolValue else {
            throw MCPError.invalidParams("export_response must be a boolean")
        }
        return boolValue
    }

    static func parseOracleImageRequests(_ value: Value?) throws -> [OracleImageRequest] {
        guard let value else { return [] }
        guard case let .array(items) = value else {
            throw MCPError.invalidParams("images must be an array of objects.")
        }
        guard !items.isEmpty else { return [] }
        guard items.count <= OracleImageAttachmentLimits.production.maxCount else {
            throw MCPError.invalidParams(
                "images supports at most \(OracleImageAttachmentLimits.production.maxCount) items."
            )
        }
        return try items.enumerated().map { index, item in
            guard case let .object(object) = item else {
                throw MCPError.invalidParams("images[\(index)] must be an object.")
            }
            let unsupported = object.keys
                .filter { !["path", "title"].contains($0) }
                .sorted()
            guard unsupported.isEmpty else {
                throw MCPError.invalidParams(
                    "images[\(index)] unsupported keys: \(unsupported.joined(separator: ", "))."
                )
            }
            guard let rawPath = object["path"]?.stringValue else {
                throw MCPError.invalidParams("images[\(index)].path must be a string.")
            }
            guard !rawPath.isEmpty else {
                throw MCPError.invalidParams("images[\(index)].path must be a non-empty local file path.")
            }
            let title: String?
            if let titleValue = object["title"] {
                guard let rawTitle = titleValue.stringValue else {
                    throw MCPError.invalidParams("images[\(index)].title must be a string.")
                }
                let normalized = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized.count <= 200 else {
                    throw MCPError.invalidParams("images[\(index)].title exceeds 200 characters.")
                }
                title = normalized.isEmpty ? nil : normalized
            } else {
                title = nil
            }
            return OracleImageRequest(index: index, path: rawPath, title: title)
        }
    }

    private func parseOracleModelOverride(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        guard case let .string(raw) = value else {
            throw MCPError.invalidParams("model must be a string")
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= OracleRosterContract.maximumModelIdentifierLength
        else {
            throw MCPError.invalidParams(
                "model must be non-empty and at most \(OracleRosterContract.maximumModelIdentifierLength) characters"
            )
        }
        return normalized
    }

    private func validateCommonOracleArgs(_ args: [String: Value]) throws {
        let message = (args["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw MCPError.invalidParams("message cannot be empty")
        }

        let modeRaw = args["mode"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "chat"
        guard ["chat", "plan", "review"].contains(modeRaw) else {
            throw MCPError.invalidParams("Invalid mode: \(modeRaw). Valid modes: chat, plan, review")
        }

        if let chatIDValue = args["chat_id"] {
            guard let chatIDRaw = chatIDValue.stringValue else {
                throw MCPError.invalidParams("chat_id must be a string")
            }
            guard !chatIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("chat_id cannot be empty when provided")
            }
        }
        if let newChatValue = args["new_chat"], newChatValue.boolValue == nil {
            throw MCPError.invalidParams("new_chat must be a boolean")
        }
    }

    private func oracleModelAvailabilityGuidance(for model: AIModel) -> String {
        switch model.providerType {
        case .claudeCode:
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
                return "Configure and enable \(descriptor.groupDisplayName) in Settings."
            }
            return "Connect Claude Code in Settings."
        default:
            return "Please check that the \(model.providerType.displayName) API key is configured in Settings."
        }
    }

    private func executeOracleModelsUtility() async throws -> Value {
        let settingsStore = GlobalSettingsStore.shared
        let exposesPresets = settingsStore.mcpShowModelPresets()
            && !settingsStore.mcpTemporarilyDisablePresets()
        let presets = exposesPresets ? ModelPresetsManager.shared.allPresets() : []
        guard !presets.isEmpty else {
            let model = try defaultCurrentChatModelInfo()
            return .string(
                "Available models:\n- \(model.id): \(model.name) — modes: [Chat, Plan, Review] — \(model.description ?? "MCP Oracle Model")"
            )
        }

        let chatPresets = ChatPresetManager.shared.allPresets
        var lines = ["Available Model Presets (automatic-selection priority order):"]
        for (priority, preset) in presets.enumerated() {
            lines.append("- \(priority + 1). \(preset.name) (\(preset.id.uuidString))")
            for (laneIndex, rawModel) in preset.modelStrings.enumerated() {
                let label = OracleRosterContract.displayLabel(laneIndex: laneIndex)
                if let model = AIModel.fromModelName(rawModel) {
                    let availability = promptVM.mcpOracleIsProviderConfigured(for: model)
                        ? "available"
                        : "unavailable"
                    lines.append("  - \(label): \(model.displayName) — \(availability)")
                } else {
                    lines.append("  - \(label): \(rawModel) — unknown model")
                }
            }
            var modes: [String] = []
            if preset.supports(mode: "chat") { modes.append("Chat") }
            if preset.supports(mode: "plan") { modes.append("Plan") }
            if preset.supports(mode: "review") { modes.append("Review") }
            lines.append("  - Modes: [\(modes.joined(separator: ", "))]")

            let mappings: [String] = [("Chat", "chat"), ("Plan", "plan"), ("Review", "review")].compactMap { label, mode in
                guard let id = preset.chatPresetMappings?.presetID(for: mode) else { return nil }
                let name = chatPresets.first(where: { $0.id == id })?.name ?? "Missing (\(id.uuidString))"
                return "\(label) → \(name)"
            }
            if !mappings.isEmpty {
                lines.append("  - Chat Presets: \(mappings.joined(separator: "; "))")
            }
            if let description = preset.description, !description.isEmpty {
                lines.append("  - \(description)")
            }
        }
        return .string(lines.joined(separator: "\n"))
    }

    private func defaultCurrentChatModelInfo() throws -> ToolResultDTOs.ModelInfo {
        let resolution = promptVM.mcpOraclePlanningModelResolution()
        guard case let .configured(effectiveModel) = resolution else {
            let message = PromptViewModel.mcpOraclePlanningModelErrorMessage(
                for: resolution,
                availabilityGuidance: { model in oracleModelAvailabilityGuidance(for: model) }
            ) ?? "MCP Oracle model is not configured."
            throw MCPError.invalidParams(message)
        }
        return ToolResultDTOs.ModelInfo(
            id: "current_chat_model",
            name: effectiveModel.displayName,
            description: "MCP Oracle Model",
            supportedModes: ToolResultDTOs.SupportedModesInfo(chat: true, plan: true, review: true)
        )
    }

    private func executeLiveOracleSessions(args: [String: Value]) async throws -> Value {
        let allowedArgs: Set = ["limit", "scope", "context_id"]
        let unsupported = args.keys.filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }.sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_utils op='sessions' only accepts limit, scope, and context_id. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }
        if let limitValue = args["limit"], limitValue.intValue == nil {
            throw MCPError.invalidParams("limit must be an integer")
        }
        if let contextIDValue = args["context_id"]?.stringValue {
            let trimmed = contextIDValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw MCPError.invalidParams("context_id cannot be empty when provided")
            }
            if UUID(uuidString: trimmed) == nil {
                throw MCPError.invalidParams("context_id must be a valid UUID. Use bind_context op=list to discover context_id values.")
            }
        }
        var listArgs: [String: Value] = [:]
        if let limit = args["limit"] {
            listArgs["limit"] = limit
        }
        if let scope = args["scope"] {
            listArgs["scope"] = scope
        }
        if let contextID = args["context_id"] {
            listArgs["tab_id"] = contextID
        }
        var result = try await oracleVM.tool_chatList(args: listArgs)
        result["action"] = .string("list")
        return .object(result)
    }

    private struct AgentOracleOwner {
        let agentSessionID: UUID?
        let runID: UUID?
        let worktreeBindingState: AgentSessionWorktreeBindingState
    }

    private func resolveAgentOracleOwner(
        tabID: UUID,
        targetWindow: WindowState,
        tabContext: TabContextSnapshot?
    ) async -> AgentOracleOwner {
        let agentModeViewModel = targetWindow.agentModeViewModel
        let storedSessionID = tabContext?.activeAgentSessionID
            ?? targetWindow.workspaceManager.composeTab(with: tabID)?.activeAgentSessionID
            ?? agentModeViewModel.session(for: tabID, createIfNeeded: false)?.activeAgentSessionID
        guard let storedSessionID else {
            return AgentOracleOwner(
                agentSessionID: nil,
                runID: tabContext?.runID,
                worktreeBindingState: .notApplicable
            )
        }

        let hydratedSession = await agentModeViewModel.ensureSessionReady(tabID: tabID)
        guard hydratedSession.activeAgentSessionID == storedSessionID else {
            return AgentOracleOwner(
                agentSessionID: storedSessionID,
                runID: tabContext?.runID ?? hydratedSession.runID,
                worktreeBindingState: .unavailable
            )
        }
        return AgentOracleOwner(
            agentSessionID: storedSessionID,
            runID: tabContext?.runID ?? hydratedSession.runID,
            worktreeBindingState: agentModeViewModel.worktreeBindingState(
                forAgentSessionID: storedSessionID,
                tabID: tabID
            )
        )
    }

    private func oraclePackagingLookupContext(for context: TabContextSnapshot) async throws -> WorkspaceLookupContext {
        if let authority = context.frozenFileToolAuthority {
            let targetWindow = try requireTargetWindow()
            try await authority.validate(
                workspaceManager: targetWindow.workspaceManager,
                store: targetWindow.promptManager.workspaceFileContextStore
            )
            return authority.lookupContext
        }
        return try await requiredOracleLookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: context.activeAgentSessionID,
                worktreeBindingState: context.worktreeBindingState
            )
        )
    }

    private func oraclePackagingLookupContext(owner: AgentOracleOwner) async throws -> WorkspaceLookupContext {
        try await requiredOracleLookupContext(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: owner.agentSessionID,
                worktreeBindingState: owner.worktreeBindingState
            )
        )
    }

    private func requiredOracleLookupContext(
        source: AgentWorkspaceLookupContextSource
    ) async throws -> WorkspaceLookupContext {
        do {
            return try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: source,
                store: promptVM.workspaceFileContextStore
            )
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    private func oracleSendTabContext(
        from context: TabContextSnapshot,
        owner: AgentOracleOwner = AgentOracleOwner(
            agentSessionID: nil,
            runID: nil,
            worktreeBindingState: .notApplicable
        ),
        origin: OracleSendOrigin,
        mode: String,
        imageRequests: [OracleImageRequest] = []
    ) async throws -> OracleViewModel.OracleSendTabContext {
        let stabilizedContext = await stabilizedVirtualContext(context)
        let lookupContext = try await oraclePackagingLookupContext(for: stabilizedContext)
        let transientImages = try await loadOracleImages(
            imageRequests,
            lookupContext: lookupContext,
            sessionAttachmentPaths: sessionAttachmentPaths(
                for: imageRequests,
                tabID: stabilizedContext.tabID,
                owner: owner
            )
        )
        let reviewGitContext = await promptVM.freezePromptGitReviewContext(
            workspaceID: stabilizedContext.workspaceID,
            tabID: stabilizedContext.tabID,
            sessionID: owner.agentSessionID,
            bindings: owner.worktreeBindingState.bindings ?? stabilizedContext.worktreeBindings,
            base: "HEAD"
        )
        let directPackaging = OracleViewModel.OracleSendPackagingContext(
            sourceTabID: stabilizedContext.tabID,
            sourceWorkspaceID: stabilizedContext.workspaceID,
            sourceSelectionRevision: stabilizedContext.selectionRevision,
            sourceAgentSessionID: owner.agentSessionID,
            sourceAgentRunID: owner.runID,
            promptText: stabilizedContext.promptText,
            selection: stabilizedContext.selection,
            lookupContext: lookupContext,
            reviewGitContext: reviewGitContext,
            provenance: .direct
        )
        let packaging = try await reviewPackaging(
            mode: mode,
            conversationTabID: stabilizedContext.tabID,
            conversationWorkspaceID: stabilizedContext.workspaceID,
            owner: owner,
            direct: directPackaging
        )
        return OracleViewModel.OracleSendTabContext(
            tabID: stabilizedContext.tabID,
            workspaceID: stabilizedContext.workspaceID,
            origin: origin,
            agentModeSessionID: owner.agentSessionID,
            agentModeRunID: owner.runID,
            packaging: packaging,
            transientImages: transientImages
        )
    }

    /// Exact image files the owning Agent session attached itself; empty without an owner.
    private func sessionAttachmentPaths(
        for requests: [OracleImageRequest],
        tabID: UUID,
        owner: AgentOracleOwner
    ) -> [String] {
        guard !requests.isEmpty, let targetWindow = try? requireTargetWindow() else { return [] }
        return targetWindow.agentModeViewModel.oracleAuthorizedAttachmentPaths(
            tabID: tabID,
            agentSessionID: owner.agentSessionID
        )
    }

    private func loadOracleImages(
        _ requests: [OracleImageRequest],
        lookupContext: WorkspaceLookupContext,
        sessionAttachmentPaths: [String]
    ) async throws -> [AITransientImage] {
        guard !requests.isEmpty else { return [] }
        let storeRoots = await promptVM.workspaceFileContextStore.rootRefs(scope: lookupContext.rootScope)
        let representedPhysicalPaths = Set(storeRoots.map(\.standardizedFullPath))
        let namespace = lookupContext.exactFileNamespace(storeRoots: storeRoots)

        // Pure in-memory projection: merge every represented binding's logical aliases under
        // its physical root. Root capture itself runs off the main actor inside
        // deriveAuthorityDetached, and a root that fails to capture is isolated so it only
        // fails the image requests that actually resolve under it.
        var physicalRootOrder: [String] = []
        var logicalRootsByPhysicalPath: [String: [String]] = [:]
        for binding in namespace.rootBindings
            where representedPhysicalPaths.contains(binding.lookupRoot.standardizedFullPath)
        {
            let physicalRootPath = binding.lookupRoot.standardizedFullPath
            if logicalRootsByPhysicalPath[physicalRootPath] == nil {
                physicalRootOrder.append(physicalRootPath)
                logicalRootsByPhysicalPath[physicalRootPath] = []
            }
            for logicalRootPath in [physicalRootPath] + binding.clientRoots.map(\.standardizedFullPath)
                where !(logicalRootsByPhysicalPath[physicalRootPath] ?? []).contains(logicalRootPath)
            {
                logicalRootsByPhysicalPath[physicalRootPath]?.append(logicalRootPath)
            }
        }
        let rootSpecs = physicalRootOrder.map {
            OracleImageRootSpec(
                physicalRootPath: $0,
                logicalRootPaths: logicalRootsByPhysicalPath[$0] ?? [$0]
            )
        }
        do {
            let authority = try await OracleImageAttachmentLoader.deriveAuthorityDetached(
                rootSpecs: rootSpecs,
                sessionAttachmentPaths: sessionAttachmentPaths
            )
            return try await OracleImageAttachmentLoader.loadDetached(
                requests: requests,
                authority: authority
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    private func reviewPackaging(
        mode: String,
        conversationTabID: UUID,
        conversationWorkspaceID: UUID?,
        owner: AgentOracleOwner,
        direct: OracleViewModel.OracleSendPackagingContext
    ) async throws -> OracleViewModel.OracleSendPackagingContext {
        guard mode == "review" else { return direct }
        guard let delegated = try await resolveDelegatedReviewPackaging(
            conversationTabID,
            conversationWorkspaceID,
            owner.agentSessionID,
            owner.runID
        ) else {
            return direct
        }
        guard owner.agentSessionID != nil, owner.runID != nil else {
            throw MCPError.invalidParams(
                "Delegated Oracle review packaging requires an exact Agent Mode session and run"
            )
        }
        guard delegated.sourceWorkspaceID == conversationWorkspaceID else {
            throw MCPError.invalidParams(
                "Delegated Oracle review packaging belongs to a different workspace"
            )
        }
        guard case .delegated = delegated.provenance else {
            throw MCPError.internalError(
                "Delegated Oracle review packaging is missing delegation provenance"
            )
        }
        return delegated
    }
}
