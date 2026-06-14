import Foundation
import MCP

@MainActor
struct MCPOracleToolService {
    typealias RequestMetadata = MCPServerViewModel.RequestMetadata
    typealias ResolvedTabContextSnapshot = MCPServerViewModel.ResolvedTabContextSnapshot
    typealias TabScopedContext = MCPServerViewModel.TabScopedContext
    typealias ChatSendOperation = @Sendable () async throws -> [String: Value]
    typealias SendChat = @MainActor @Sendable (
        _ args: [String: Value],
        _ promptVM: PromptViewModel,
        _ tabContext: OracleViewModel.OracleSendTabContext?
    ) async throws -> [String: Value]
    typealias ExportOracleResponse = @MainActor @Sendable (OracleExportRequest) async throws -> OracleExportFile

    let askOracleToolName: String
    let oracleSendToolName: String
    let oracleChatLogToolName: String
    let promptVM: PromptViewModel
    let oracleVM: OracleViewModel
    let captureRequestMetadata: () async -> RequestMetadata
    let resolveTabContextSnapshot: (RequestMetadata) throws -> ResolvedTabContextSnapshot
    let requireCurrentTabContext: (String) async throws -> TabScopedContext
    let rebindChatSessionIfNeeded: (_ metadata: RequestMetadata, _ chatIDString: String) throws -> Void
    let resolveTabIDForAgentMode: (_ args: [String: Value], _ connectionID: UUID?) async throws -> UUID
    let requireTargetWindow: () throws -> WindowState
    let rawExplicitTabID: (_ args: [String: Value]) -> String?
    let sendStageProgress: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String) async -> Void
    let withHeartbeat: (_ connectionID: UUID?, _ tool: String, _ stage: String, _ message: String, _ operation: @escaping ChatSendOperation) async throws -> [String: Value]
    let sendChat: SendChat
    let exportOracleResponse: ExportOracleResponse

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

    func executeOracleChatLog(args: [String: Value]) async throws -> Value {
        guard let connectionID = ServerNetworkManager.currentConnectionID else {
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
        let tabContext: TabScopedContext?
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

    func executeAskOracle(args: [String: Value]) async throws -> Value {
        let allowedArgs: Set = ["message", "mode", "chat_id", "new_chat", "export_response"]
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "ask_oracle only accepts: message, mode, chat_id, new_chat, export_response. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        try validateCommonOracleArgs(args)

        guard let connectionID = ServerNetworkManager.currentConnectionID else {
            throw MCPError.invalidParams("ask_oracle requires an active MCP connection")
        }

        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let exportResponse = try parseExportResponseFlag(args)
        let newChat = args["new_chat"]?.boolValue ?? false
        let chatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChatID = (chatID?.isEmpty == false) ? chatID : nil
        let targetWindow = try requireTargetWindow()

        let tabID = try await resolveTabIDForAgentMode(args, connectionID)
        let requestContext = try? await requireCurrentTabContext(askOracleToolName)
        let virtualContext = (requestContext?.tabID == tabID) ? requestContext : nil
        if let normalizedChatID {
            guard let session = oracleVM.resolveSession(id: normalizedChatID) else {
                throw MCPError.invalidParams("Chat with ID '\(normalizedChatID)' not found")
            }
            guard let sessionTabID = session.composeTabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' is not bound to a compose tab. Use a chat_id from the current tab."
                )
            }
            guard sessionTabID == tabID else {
                throw MCPError.invalidParams(
                    "Chat with ID '\(normalizedChatID)' belongs to a different tab. ask_oracle can only continue chats from the current tab."
                )
            }
        }

        let owner = await resolveAgentOracleOwner(tabID: tabID, targetWindow: targetWindow, tabContext: virtualContext)
        let tabContext: OracleViewModel.OracleSendTabContext
        if let virtualContext, virtualContext.tabID == tabID {
            tabContext = try await oracleSendTabContext(from: virtualContext, owner: owner)
        } else {
            guard let tabSnapshot = targetWindow.workspaceManager.composeTabSnapshot(for: tabID) else {
                throw MCPError.internalError("Unable to resolve compose tab context for ask_oracle")
            }
            let lookupContext = try await oraclePackagingLookupContext(owner: owner)
            tabContext = OracleViewModel.OracleSendTabContext(
                tabID: tabID,
                promptText: tabSnapshot.promptText,
                selection: tabSnapshot.selection,
                lookupContext: lookupContext,
                agentModeSessionID: owner.agentSessionID,
                agentModeRunID: owner.runID
            )
        }

        let exportDestination: OracleExportDestination? = if exportResponse {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: targetWindow.workspaceManager.activeWorkspace,
                windowID: targetWindow.windowID,
                tabID: tabID,
                lookupContext: tabContext.lookupContext ?? .visibleWorkspace
            )
        } else {
            nil
        }

        var chatArgs: [String: Value] = [
            "message": .string(message),
            "mode": .string(modeRaw),
            "new_chat": .bool(newChat)
        ]
        if let normalizedChatID {
            chatArgs["chat_id"] = .string(normalizedChatID)
        }

        await sendStageProgress(connectionID, askOracleToolName, "starting", "Starting Oracle...")

        let capturedChatArgs = chatArgs
        var result = try await withHeartbeat(
            connectionID,
            askOracleToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            try await sendChat(capturedChatArgs, promptVM, tabContext)
        }

        if exportResponse {
            let export = try await exportOracleResponse(OracleExportRequest(
                sourceTool: askOracleToolName,
                mode: modeRaw,
                message: message,
                chatID: result["chat_id"]?.stringValue ?? normalizedChatID,
                response: result["response"]?.stringValue,
                destination: exportDestination
            ))
            result["oracle_export_path"] = .string(export.path)
            result["oracle_export_instruction"] = .string(export.instruction)
        }

        await sendStageProgress(connectionID, askOracleToolName, "complete", "Oracle complete")
        return .object(result)
    }

    // MARK: - oracle_send

    func executeOracleSend(args: [String: Value]) async throws -> Value {
        let allowedArgs: Set = ["message", "mode", "chat_id", "new_chat", "model", "export_response"]
        let unsupported = args.keys
            .filter { !$0.hasPrefix("_") && !allowedArgs.contains($0) }
            .sorted()
        if !unsupported.isEmpty {
            throw MCPError.invalidParams(
                "oracle_send only accepts: message, mode, chat_id, new_chat, model, export_response. Unsupported args: \(unsupported.joined(separator: ", "))"
            )
        }

        try validateCommonOracleArgs(args)
        let message = (args["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let modeRaw = args["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chat"
        let exportResponse = try parseExportResponseFlag(args)

        let connectionID = ServerNetworkManager.currentConnectionID
        let runPurpose: MCPRunPurpose = if let connectionID {
            await ServerNetworkManager.shared.runPurpose(for: connectionID)
        } else {
            .unknown
        }
        let targetWindow: WindowState? = if exportResponse || runPurpose == .agentModeRun {
            try requireTargetWindow()
        } else {
            nil
        }
        let metadata = await captureRequestMetadata()
        let resolvedContext = try resolveTabContextSnapshot(metadata)
        var tabContext: OracleViewModel.OracleSendTabContext? = nil

        if !resolvedContext.usesActiveTabCompatibility {
            if let chatIDString = args["chat_id"]?.stringValue,
               !chatIDString.isEmpty
            {
                try rebindChatSessionIfNeeded(metadata, chatIDString)
            }

            let context = try await requireCurrentTabContext(oracleSendToolName)
            if runPurpose == .agentModeRun, let targetWindow {
                let owner = await resolveAgentOracleOwner(tabID: context.tabID, targetWindow: targetWindow, tabContext: context)
                tabContext = try await oracleSendTabContext(from: context, owner: owner)
            } else {
                tabContext = try await oracleSendTabContext(from: context)
            }
        }

        let exportDestination: OracleExportDestination? = if exportResponse, let targetWindow {
            try MCPServerViewModel.makeOracleExportDestination(
                workspace: targetWindow.workspaceManager.activeWorkspace,
                windowID: targetWindow.windowID,
                tabID: tabContext?.tabID,
                lookupContext: tabContext?.lookupContext ?? .visibleWorkspace
            )
        } else {
            nil
        }

        await sendStageProgress(connectionID, oracleSendToolName, "starting", "Starting Oracle...")

        var chatArgs = args
        chatArgs.removeValue(forKey: "export_response")

        let capturedTabContext = tabContext
        let capturedChatArgs = chatArgs
        var result = try await withHeartbeat(
            connectionID,
            oracleSendToolName,
            "waiting",
            "Waiting for Oracle response..."
        ) {
            try await sendChat(capturedChatArgs, promptVM, capturedTabContext)
        }

        if exportResponse {
            let normalizedChatID = args["chat_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let export = try await exportOracleResponse(OracleExportRequest(
                sourceTool: oracleSendToolName,
                mode: modeRaw,
                message: message,
                chatID: result["chat_id"]?.stringValue ?? ((normalizedChatID?.isEmpty == false) ? normalizedChatID : nil),
                response: result["response"]?.stringValue,
                destination: exportDestination
            ))
            result["oracle_export_path"] = .string(export.path)
            result["oracle_export_instruction"] = .string(export.instruction)
        }

        await sendStageProgress(connectionID, oracleSendToolName, "complete", "Oracle complete")
        return .object(result)
    }

    // MARK: - Shared helpers

    private func parseExportResponseFlag(_ args: [String: Value]) throws -> Bool {
        guard let value = args["export_response"] else { return false }
        guard let boolValue = value.boolValue else {
            throw MCPError.invalidParams("export_response must be a boolean")
        }
        return boolValue
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

        if let chatIDRaw = args["chat_id"]?.stringValue,
           chatIDRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw MCPError.invalidParams("chat_id cannot be empty when provided")
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
        let (showModelPresets, temporarilyDisabled) = await MainActor.run {
            let store = GlobalSettingsStore.shared
            return (store.mcpShowModelPresets(), store.mcpTemporarilyDisablePresets())
        }

        var models: [ToolResultDTOs.ModelInfo] = []

        if showModelPresets {
            let presets = temporarilyDisabled ? [] : await ModelPresetsManager.shared.allPresets()
            if !presets.isEmpty {
                for preset in presets {
                    let supportedModes: ToolResultDTOs.SupportedModesInfo = {
                        if let modes = preset.supportedModes {
                            return ToolResultDTOs.SupportedModesInfo(
                                chat: modes.chat,
                                plan: modes.plan,
                                review: modes.review
                            )
                        }
                        return ToolResultDTOs.SupportedModesInfo(chat: true, plan: true, review: true)
                    }()
                    models.append(ToolResultDTOs.ModelInfo(
                        id: preset.id.uuidString,
                        name: preset.name,
                        description: preset.description,
                        supportedModes: supportedModes
                    ))
                }
            } else {
                try models.append(defaultCurrentChatModelInfo())
            }
        } else {
            try models.append(defaultCurrentChatModelInfo())
        }

        func bracketedModes(_ supportedModes: ToolResultDTOs.SupportedModesInfo?) -> String {
            let modes = supportedModes ?? ToolResultDTOs.SupportedModesInfo(chat: true, plan: true, review: true)
            var items: [String] = []
            if modes.chat { items.append("Chat") }
            if modes.plan { items.append("Plan") }
            if modes.review { items.append("Review") }
            return "[\(items.joined(separator: ", "))]"
        }

        var lines = ["Available models:"]
        for model in models {
            let modesText = bracketedModes(model.supportedModes)
            let descText = (model.description?.isEmpty == false) ? " — \(model.description!)" : ""
            lines.append("- \(model.id): \(model.name) — modes: \(modesText)\(descText)")
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
        tabContext: TabScopedContext?
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

    private func oraclePackagingLookupContext(for context: TabScopedContext) async throws -> WorkspaceLookupContext {
        if let frozenLookupContext = context.frozenLookupContext {
            return frozenLookupContext
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
        from context: TabScopedContext,
        owner: AgentOracleOwner = AgentOracleOwner(
            agentSessionID: nil,
            runID: nil,
            worktreeBindingState: .notApplicable
        )
    ) async throws -> OracleViewModel.OracleSendTabContext {
        let lookupContext = try await oraclePackagingLookupContext(for: context)
        return OracleViewModel.OracleSendTabContext(
            tabID: context.tabID,
            promptText: context.promptText,
            selection: context.selection,
            lookupContext: lookupContext,
            agentModeSessionID: owner.agentSessionID,
            agentModeRunID: owner.runID
        )
    }
}
