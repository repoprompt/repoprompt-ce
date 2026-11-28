import Foundation
import RepoPromptCodexProvider
import RepoPromptRemoteProtocol

/// Resolves and dispatches chat operations within the immutable workspace scope of a voice call.
@MainActor
struct RemoteWorkspaceVoiceChatTools {
    let workspace: RemoteWorkspaceVoiceAccess
    let leaseIsValid: () -> Bool
    var didDispatch: (UUID) -> Void = { _ in }

    private func requireAccess() throws {
        try Task.checkCancellation()
        guard leaseIsValid(), workspace.isAuthorized() else { throw RemoteWorkspaceVoiceError.unavailable }
    }

    func execute(_ tool: String, arguments: [String: CodexJSONValue]) async throws -> String {
        try requireAccess()
        func string(_ key: String) -> String? {
            guard case let .string(value) = arguments[key] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        switch tool {
        case "list_chats":
            let historyCursor: RemoteHistoryCursor? = try decodeCursor(string("before"))
            return try await listChats(query: string("query"), before: historyCursor)

        case "list_files", "read_file":
            let operation: RemoteWorkspaceVoiceFileOperation = tool == "list_files" ? .list : .read
            let output = try await workspace.browse(operation, string("path"))
            try requireAccess()
            return output

        case "list_settings":
            return try await listSettings(agentID: string("agent_id"), query: string("query"))

        case "set_tool":
            guard let settingID = string("setting_id"), case let .bool(enabled) = arguments["enabled"] else {
                throw RemoteWorkspaceVoiceError.invalidToolArguments
            }
            return try await setTool(settingID: settingID, enabled: enabled)

        case "start_chat":
            let response = try await dispatch(.init(
                operation: .startRun, workspaceID: workspace.workspaceID.uuidString, message: requiredMessage(string("message")),
                agentID: string("agent_id"), modelID: string("model_id"), reasoningEffort: string("effort")
            ))
            return try commandResult(response)

        case "read_chat", "send_to_chat", "configure_chat":
            let chat = try await resolveChat(string("chat_id"))
            let chatID = chat.id
            try requireAccess()
            if tool == "read_chat" {
                let before: RemoteTranscriptCursor? = try decodeCursor(string("before"))
                let page = try await workspace.transcript(chatID, before)
                try requireAccess()
                let messages: [[String: String]] = page.items.compactMap {
                    guard let text = $0.text, !text.isEmpty else { return nil }
                    return ["role": $0.role, "text": String(text.prefix(1200))]
                }
                return try json([
                    "title": chat.sessionName,
                    "run_state": chat.runState.rawValue,
                    "messages": messages,
                    "older": encodeCursor(page.olderCursor) as Any? ?? NSNull()
                ])
            }
            let operation: RemoteCommandOperation = tool == "send_to_chat" ? .followUp : .configureSession
            let message = operation == .followUp ? try requiredMessage(string("message")) : nil
            let response = try await dispatch(.init(
                operation: operation, workspaceID: workspace.workspaceID.uuidString, sessionID: chatID, message: message,
                agentID: string("agent_id"), modelID: string("model_id"), reasoningEffort: string("effort")
            ))
            return try commandResult(response, chat: chat)

        default:
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
    }

    private func requiredMessage(_ text: String?) throws -> String {
        guard let text, text.utf8.count <= 12000 else {
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
        return text
    }

    private func dispatch(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        try requireAccess()
        let response = try await workspace.dispatch(request, leaseIsValid)
        try requireAccess()
        guard response.accepted,
              response.workspaceID.flatMap(UUID.init(uuidString:)) == workspace.workspaceID,
              request.sessionID == nil || response.sessionID == request.sessionID
        else { throw RemoteWorkspaceVoiceError.unavailable }
        if [.startRun, .followUp].contains(request.operation), let id = response.sessionID {
            didDispatch(id)
        }
        return response
    }

    private func commandResult(_ response: RemoteCommandResponse, chat: RemoteHistoryEntry? = nil) throws -> String {
        guard let sessionID = response.sessionID else { throw RemoteWorkspaceVoiceError.unavailable }
        var result: [String: Any] = ["accepted": true, "chat_id": sessionID.uuidString]
        result["title"] = chat?.sessionName
        result["run_state"] = (response.runState ?? chat?.runState)?.rawValue
        if let selection = response.resolvedSelection {
            result["agent_id"] = selection.agentID
            result["model_id"] = selection.modelID
            result["effort"] = selection.reasoningEffort
        }
        return try json(result)
    }

    private func listSettings(agentID: String?, query: String?) async throws -> String {
        let catalog = try await workspace.catalog()
        try requireAccess()
        func matches(_ fields: String...) -> Bool {
            guard let query else { return true }
            return fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let agents = catalog.agents.filter { $0.isAvailable && (agentID == nil || $0.id == agentID) }
        let models: [[String: Any]] = agents.flatMap { agent in
            (agent.modelDescriptors ?? []).filter { $0.isAvailable && matches($0.id, $0.displayName) }
                .prefix(16).map { model in
                    [
                        "agent_id": agent.id, "model_id": model.id, "name": model.displayName,
                        "efforts": model.reasoningEfforts.map { ["id": $0.id, "name": $0.displayName] }
                    ]
                }
        }
        let tools = catalog.metadata?.toolCatalog
        let hasDangerPermission = workspace.canConfigureTools()
        let canChangeTools = hasDangerPermission && tools?.isMutable == true
        let toolSettings: [[String: Any]] = tools?.settings.filter { matches($0.id, $0.displayName) }.prefix(40).map { setting in
            [
                "id": setting.id,
                "name": setting.displayName,
                "enabled": setting.isEnabled,
                "changeable": canChangeTools && setting.isMutable
            ]
        } ?? []
        return try json([
            "agents": agents.map { ["id": $0.id, "name": $0.displayName] },
            "models": Array(models.prefix(40)),
            "tools": toolSettings,
            "tool_scope": "mac",
            "danger_permission": hasDangerPermission
        ])
    }

    private func setTool(settingID: String, enabled: Bool) async throws -> String {
        guard workspace.canConfigureTools() else {
            throw RemoteAgentControlServiceError.commandRejected("Changing Mac-wide tools requires Danger permission on the Mac.")
        }
        let catalog = try await workspace.catalog()
        try requireAccess()
        guard let tools = catalog.metadata?.toolCatalog,
              let setting = tools.settings.first(where: { $0.id == settingID })
        else {
            throw RemoteAgentControlServiceError.commandRejected("That tool is unavailable. Check the Mac's current tool list.")
        }
        let response = try await dispatch(.init(
            operation: .configureTools, workspaceID: workspace.workspaceID.uuidString,
            toolMutation: .init(settingID: setting.id, enabled: enabled, expectedRevision: tools.revision)
        ))
        guard let updated = response.resolvedToolCatalog?.settings.first(where: { $0.id == setting.id }),
              updated.isEnabled == enabled
        else { throw RemoteWorkspaceVoiceError.unavailable }
        return try json(["accepted": true, "tool": updated.displayName, "enabled": updated.isEnabled, "scope": "mac"])
    }

    private func listChats(query: String?, before: RemoteHistoryCursor?) async throws -> String {
        let query = query.map { String($0.prefix(200)) }
        let page = try await workspace.history(.init(query: query, limit: 20, workspaceID: workspace.workspaceID, before: before))
        try requireAccess()
        guard page.workspaceID == workspace.workspaceID else { throw RemoteWorkspaceVoiceError.unavailable }
        let liveByID = Dictionary(scopedLiveSessions().map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        let chats = page.entries.filter { UUID(uuidString: $0.workspaceID) == workspace.workspaceID }
            .map { chatSummary($0, live: liveByID[$0.id]) }
        let active = liveByID.values.filter {
            $0.pendingInteraction != nil || [.opening, .working, .waitingForInput, .blocked].contains($0.runState)
        }
        let activeChats = before == nil && (query?.isEmpty ?? true)
            ? active.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }.prefix(20).map { live in
                chatSummary(Self.historyEntry(for: live), live: live)
            }
            : []
        return try json([
            "workspace": workspace.name,
            "chats": chats,
            "active_chats": activeChats,
            "active_count": active.count,
            "older": encodeCursor(page.olderCursor) as Any? ?? NSNull()
        ])
    }

    private func resolveChat(_ reference: String?) async throws -> RemoteHistoryEntry {
        if reference == "most_recent" {
            let page = try await workspace.history(.init(limit: 1, workspaceID: workspace.workspaceID))
            try requireAccess()
            guard page.workspaceID == workspace.workspaceID,
                  let chat = page.entries.first(where: { UUID(uuidString: $0.workspaceID) == workspace.workspaceID })
            else { throw RemoteWorkspaceVoiceError.unknownChat }
            return chat
        }
        guard let reference, let id = UUID(uuidString: reference) else {
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
        if let live = scopedLiveSessions().first(where: { $0.sessionID == id }) {
            return Self.historyEntry(for: live)
        }
        let history = try await workspace.history(.init(query: id.uuidString, workspaceID: workspace.workspaceID))
        guard history.workspaceID == workspace.workspaceID else { throw RemoteWorkspaceVoiceError.unavailable }
        guard let chat = history.entries.first(where: { $0.id == id && UUID(uuidString: $0.workspaceID) == workspace.workspaceID })
        else { throw RemoteWorkspaceVoiceError.unknownChat }
        return chat
    }

    private func scopedLiveSessions() -> [RemoteSessionSummary] {
        workspace.liveSessions().filter { $0.isLive && UUID(uuidString: $0.workspaceID) == workspace.workspaceID }
    }

    static func historyEntry(for live: RemoteSessionSummary) -> RemoteHistoryEntry {
        .init(
            id: live.sessionID, workspaceID: live.workspaceID, sessionName: live.sessionName ?? "Untitled chat",
            lastActivityAt: live.lastUpdatedAt, runState: live.runState
        )
    }

    private func chatSummary(_ entry: RemoteHistoryEntry, live: RemoteSessionSummary?) -> [String: String] {
        var result = [
            "chat_id": entry.id.uuidString,
            "title": entry.sessionName,
            "run_state": (live?.runState ?? entry.runState).rawValue
        ]
        if let activity = live?.latestMeaningfulActivity { result["activity"] = String(activity.prefix(400)) }
        if let pending = live?.pendingInteraction { result["needs_input"] = pending.kind.rawValue }
        return result
    }

    private func json(_ object: [String: Any]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func encodeCursor(_ cursor: (some Encodable)?) throws -> String? {
        try cursor.map { try JSONEncoder().encode($0).base64EncodedString() }
    }

    private func decodeCursor<T: Decodable>(_ token: String?) throws -> T? {
        guard let token else { return nil }
        guard token.utf8.count <= 512, let data = Data(base64Encoded: token) else {
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func activity(for tool: String) -> RemoteWorkspaceVoiceActivity? {
        switch tool {
        case "list_chats": .findingChats
        case "read_chat": .readingChat
        case "list_files", "read_file": .checkingFiles
        case "start_chat": .startingChat
        case "send_to_chat": .sendingMessage
        case "list_settings": .checkingSettings
        case "configure_chat", "set_tool": .changingSettings
        default: nil
        }
    }

    static func isMutation(_ tool: String) -> Bool {
        ["start_chat", "send_to_chat", "configure_chat", "set_tool"].contains(tool)
    }

    static var definitions: [[String: Any]] {
        func tool(
            _ name: String, _ description: String, fields: [String: String], required: [String] = [],
            booleanFields: [String: String] = [:]
        ) -> [String: Any] {
            let properties = fields.mapValues { ["type": "string", "description": $0] }
                .merging(booleanFields.mapValues { ["type": "boolean", "description": $0] }) { _, boolean in boolean }
            let schema: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ]
            return ["type": "function", "name": name, "description": description, "inputSchema": schema]
        }
        let chatReference = "A chat ID from a tool result. Use most_recent when the caller asks for the most recent chat in this workspace."
        let selection = [
            "agent_id": "Optional provider ID from list_settings. Omit to keep the chat's provider or use Codex for a new chat.",
            "model_id": "Optional exact model ID from list_settings.",
            "effort": "Optional exact reasoning effort ID supported by the selected model."
        ]
        let sending = selection.merging(["chat_id": chatReference, "message": "The caller's instruction."]) { _, field in field }
        let starting = selection.merging(["message": "The caller's first instruction for the chat."]) { _, field in field }
        let configuring = selection.merging(["chat_id": chatReference]) { _, field in field }
        return [
            tool("list_chats", "Find running and saved chats in this workspace. Omit query for a recent activity briefing.", fields: [
                "query": "A phrase from the chat title. Try a shorter phrase if there are no matches.",
                "before": "The opaque older cursor from the previous result, for the same query."
            ]),
            tool("read_chat", "Read a chat's recent transcript, whether or not it is active.", fields: [
                "chat_id": chatReference,
                "before": "The opaque older cursor from the previous read of this chat."
            ], required: ["chat_id"]),
            tool("list_files", "List the immediate contents of a folder in this workspace.", fields: [
                "path": "An exact workspace-relative folder path. Omit to see the workspace root."
            ]),
            tool("read_file", "Read a bounded excerpt of a text file in this workspace.", fields: [
                "path": "An exact workspace-relative file path."
            ], required: ["path"]),
            tool("list_settings", "Look up available providers, models, reasoning levels, and Mac-wide Codex tool settings.", fields: [
                "agent_id": "Optional provider ID to narrow the model list.",
                "query": "Optional phrase from a model or tool name. Shorten it if there are no matches."
            ]),
            tool("start_chat", "Start a normal chat in this workspace for the caller's task.", fields: starting, required: ["message"]),
            tool("send_to_chat", "Deliver the caller's instruction to an existing chat. Optional settings are applied before sending.", fields: sending, required: ["chat_id", "message"]),
            tool("configure_chat", "Change the model or reasoning level of an idle chat at the caller's request.", fields: configuring, required: ["chat_id"]),
            tool("set_tool", "Change a Codex tool for the whole Mac when explicitly requested and authorized.", fields: [
                "setting_id": "Exact tool setting ID from list_settings."
            ], required: ["setting_id", "enabled"], booleanFields: ["enabled": "True enables the tool, false disables it."])
        ]
    }
}
