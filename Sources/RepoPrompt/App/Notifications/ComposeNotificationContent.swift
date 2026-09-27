import Foundation

/// Links an Oracle chat to the Agent Mode session that created it through MCP (`ask_oracle`,
/// `context_builder`). Such chats are usually named with the "Untitled Chat" placeholder, so their
/// completion notifications are labelled with the owning agent session instead.
struct ChatNotificationAgentLink: Equatable {
    /// Compose tab that hosts both the agent session and its Oracle chats.
    let tabID: UUID?
    /// Agent session incarnation that owns the chat, when recorded.
    let sessionID: UUID?

    init(tabID: UUID?, sessionID: UUID?) {
        self.tabID = tabID
        self.sessionID = sessionID
    }

    /// `nil` for ordinary (user-driven) chats that no Agent Mode session owns.
    init?(chatSession: ChatSession) {
        guard chatSession.agentModeSessionID != nil || chatSession.agentModeRunID != nil else { return nil }
        self.init(tabID: chatSession.composeTabID, sessionID: chatSession.agentModeSessionID)
    }

    /// Returns `state` only while it still describes the linked agent session. A tab that has since
    /// moved on to a different session must not lend its name or route to this chat.
    func matchingState(_ state: AgentAttentionState?) -> AgentAttentionState? {
        guard let state, state.tabID == tabID else { return nil }
        if let sessionID {
            return state.sessionID == sessionID ? state : nil
        }
        return state
    }
}

/// Pure title/subtitle/body selection for Chat and Context Builder completion notifications.
struct ComposeNotificationContent: Equatable {
    static let chatCompleteTitle = "Chat Complete"
    static let oracleReplyTitle = "Oracle reply ready"
    static let genericChatBody = "Your AI response is ready"
    static let contextBuilderCompleteTitle = "Context Builder Complete"
    static let genericContextBuilderBody = "Your context is ready"

    let title: String
    let subtitle: String?
    let body: String

    /// - Parameters:
    ///   - chatName: The chat's current name; placeholder names ("Untitled Chat", "New Chat") are
    ///     never shown.
    ///   - isAgentLinked: The chat was created by an Agent Mode session.
    ///   - agentSessionName: Display name of the owning agent session, when it is live. Like other
    ///     agent notifications, it is shown regardless of `showDetails`.
    ///   - showDetails: Whether the chat name may be used as the body.
    static func chatComplete(
        chatName: String?,
        isAgentLinked: Bool,
        agentSessionName: String?,
        showDetails: Bool
    ) -> ComposeNotificationContent {
        let body = (showDetails ? ChatSession.displayableName(chatName) : nil) ?? genericChatBody
        guard isAgentLinked else {
            return ComposeNotificationContent(title: chatCompleteTitle, subtitle: nil, body: body)
        }
        let sessionName = ChatSession.displayableName(agentSessionName)
        return ComposeNotificationContent(title: oracleReplyTitle, subtitle: sessionName, body: body)
    }

    static func contextBuilderComplete(tabName: String?, showDetails: Bool) -> ComposeNotificationContent {
        let body = (showDetails ? ChatSession.displayableName(tabName) : nil) ?? genericContextBuilderBody
        return ComposeNotificationContent(title: contextBuilderCompleteTitle, subtitle: nil, body: body)
    }
}
