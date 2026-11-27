import Foundation
import RepoPromptCodexProvider
import RepoPromptRemoteProtocol

/// Resolves and dispatches chat operations within the immutable workspace scope of a voice call.
@MainActor
struct RemoteWorkspaceVoiceChatTools {
    let workspace: RemoteWorkspaceVoiceAccess
    let leaseIsValid: () -> Bool

    private func requireAccess() throws {
        try Task.checkCancellation()
        guard leaseIsValid(), workspace.isAuthorized() else { throw RemoteWorkspaceVoiceError.unavailable }
    }

    func execute(_ tool: String, arguments: [String: CodexJSONValue]) async throws -> String {
        try requireAccess()
        func string(_ key: String) -> String? {
            guard case let .string(value) = arguments[key] else { return nil }
            return value
        }

        switch tool {
        case "list_chats":
            let historyCursor: RemoteHistoryCursor? = try decodeCursor(string("before"))
            return try await listChats(query: string("query"), before: historyCursor)

        case "start_chat":
            let response = try await dispatch(to: nil, message: string("message"))
            guard let sessionID = response.sessionID else { throw RemoteWorkspaceVoiceError.unavailable }
            return try json([
                "accepted": true,
                "chat_id": sessionID.uuidString,
                "run_state": response.runState?.rawValue as Any? ?? NSNull()
            ])

        case "read_chat", "send_to_chat":
            guard let reference = string("chat_id"), let chatID = UUID(uuidString: reference) else {
                throw RemoteWorkspaceVoiceError.invalidToolArguments
            }
            guard let chat = try await findChat(chatID) else { throw RemoteWorkspaceVoiceError.unknownChat }
            try requireAccess()
            if tool == "read_chat" {
                let before: RemoteTranscriptCursor? = try decodeCursor(string("before"))
                let page = try await workspace.transcript(chatID, before)
                try requireAccess()
                let messages: [[String: String]] = page.items.compactMap {
                    guard let text = $0.text, !text.isEmpty else { return nil }
                    return ["role": $0.role, "text": String(text.prefix(1_200))]
                }
                return try json([
                    "title": chat.sessionName,
                    "run_state": chat.runState.rawValue,
                    "messages": messages,
                    "older": try encodeCursor(page.olderCursor) as Any? ?? NSNull()
                ])
            }
            let response = try await dispatch(to: chatID, message: string("message"))
            return try json([
                "accepted": true,
                "title": chat.sessionName,
                "run_state": response.runState?.rawValue ?? chat.runState.rawValue
            ])

        default:
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
    }

    private func dispatch(to chatID: UUID?, message: String?) async throws -> RemoteCommandResponse {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.utf8.count <= 12_000 else {
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
        let response = try await workspace.dispatch(chatID, text, leaseIsValid)
        try requireAccess()
        guard response.accepted,
              response.workspaceID.flatMap(UUID.init(uuidString:)) == workspace.workspaceID,
              chatID == nil || response.sessionID == chatID
        else { throw RemoteWorkspaceVoiceError.unavailable }
        return response
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
            "older": try encodeCursor(page.olderCursor) as Any? ?? NSNull()
        ])
    }

    private func findChat(_ id: UUID) async throws -> RemoteHistoryEntry? {
        if let live = scopedLiveSessions().first(where: { $0.sessionID == id }) {
            return Self.historyEntry(for: live)
        }
        let history = try await workspace.history(.init(query: id.uuidString, workspaceID: workspace.workspaceID))
        guard history.workspaceID == workspace.workspaceID else { throw RemoteWorkspaceVoiceError.unavailable }
        return history.entries.first { $0.id == id && UUID(uuidString: $0.workspaceID) == workspace.workspaceID }
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

    private func encodeCursor<T: Encodable>(_ cursor: T?) throws -> String? {
        try cursor.map { try JSONEncoder().encode($0).base64EncodedString() }
    }

    private func decodeCursor<T: Decodable>(_ token: String?) throws -> T? {
        guard let token else { return nil }
        guard token.utf8.count <= 512, let data = Data(base64Encoded: token) else {
            throw RemoteWorkspaceVoiceError.invalidToolArguments
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, fields: [String: String], required: [String] = []) -> [String: Any] {
            let schema: [String: Any] = [
                "type": "object",
                "properties": fields.mapValues { ["type": "string", "description": $0] },
                "required": required,
                "additionalProperties": false
            ]
            return ["type": "function", "name": name, "description": description, "inputSchema": schema]
        }
        return [
            tool("list_chats", "Find running and saved chats in this workspace. Omit query for a recent activity briefing.", fields: [
                "query": "A phrase from the chat title. Try a shorter phrase if there are no matches.",
                "before": "The opaque older cursor from the previous result, for the same query."
            ]),
            tool("read_chat", "Read a chat's recent transcript, whether or not it is active.", fields: [
                "chat_id": "ID returned by list_chats or start_chat.",
                "before": "The opaque older cursor from the previous read of this chat."
            ], required: ["chat_id"]),
            tool("start_chat", "Start a new Codex chat in this workspace only when explicitly asked.", fields: [
                "message": "The caller's first instruction for this new chat."
            ], required: ["message"]),
            tool("send_to_chat", "Deliver the caller's explicit instruction to an existing chat. A running chat is steered. A saved chat is resumed.", fields: [
                "chat_id": "ID returned by list_chats or start_chat.",
                "message": "The caller's instruction for this chat."
            ], required: ["chat_id", "message"])
        ]
    }
}
