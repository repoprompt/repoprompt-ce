import Foundation

struct AgentOracleOpenContext {
    let windowID: Int
    let workspaceID: UUID?
    let tabID: UUID?
    let chatID: String?

    init(windowID: Int, workspaceID: UUID?, tabID: UUID?, chatID: String? = nil) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.chatID = chatID
    }
}

struct AgentOracleLatestPopoverRoute: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID

    init?(
        openContext: AgentOracleOpenContext?,
        tabID: UUID? = nil
    ) {
        guard let openContext,
              let workspaceID = openContext.workspaceID,
              let tabID = tabID ?? openContext.tabID
        else { return nil }
        windowID = openContext.windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
    }

    init?(notificationUserInfo userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              userInfo[Key.chatID] == nil,
              userInfo[Key.route] as? String == Key.latestRoute,
              let windowID = userInfo[Key.windowID] as? Int,
              let workspaceID = Self.uuid(from: userInfo[Key.workspaceID]),
              let tabID = Self.uuid(from: userInfo[Key.tabID])
        else { return nil }
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
    }

    var notificationUserInfo: [AnyHashable: Any] {
        [
            Key.windowID: windowID,
            Key.workspaceID: workspaceID,
            Key.tabID: tabID,
            Key.route: Key.latestRoute
        ]
    }

    private enum Key {
        static let windowID = "windowID"
        static let workspaceID = "workspaceID"
        static let tabID = "tabID"
        static let chatID = "chatID"
        static let route = "route"
        static let latestRoute = "latest"
    }

    private static func uuid(from value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        if let value = value as? String { return UUID(uuidString: value) }
        return nil
    }
}

enum AgentOraclePopoverPresentation: String, Equatable {
    case standard
    case generatedAnswerReadOnly = "generated_answer_read_only"
}

struct AgentOraclePopoverRoute: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let chatID: String
    let presentation: AgentOraclePopoverPresentation

    init?(
        openContext: AgentOracleOpenContext?,
        chatID: String?,
        tabID: UUID? = nil,
        presentation: AgentOraclePopoverPresentation = .standard
    ) {
        guard let openContext,
              let workspaceID = openContext.workspaceID,
              let tabID = tabID ?? openContext.tabID,
              let chatID = Self.nonEmptyChatID(chatID)
        else { return nil }
        windowID = openContext.windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.chatID = chatID
        self.presentation = presentation
    }

    init?(notificationUserInfo userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let windowID = userInfo[Key.windowID] as? Int,
              let workspaceID = Self.uuid(from: userInfo[Key.workspaceID]),
              let tabID = Self.uuid(from: userInfo[Key.tabID]),
              let chatID = Self.chatID(from: userInfo[Key.chatID]),
              let presentation = Self.presentation(from: userInfo)
        else { return nil }
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.chatID = chatID
        self.presentation = presentation
    }

    var notificationUserInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            Key.windowID: windowID,
            Key.workspaceID: workspaceID,
            Key.tabID: tabID,
            Key.chatID: chatID
        ]
        if presentation != .standard {
            userInfo[Key.presentation] = presentation.rawValue
        }
        return userInfo
    }

    private enum Key {
        static let windowID = "windowID"
        static let workspaceID = "workspaceID"
        static let tabID = "tabID"
        static let chatID = "chatID"
        static let presentation = "presentation"
    }

    private static func presentation(from userInfo: [AnyHashable: Any]) -> AgentOraclePopoverPresentation? {
        guard let value = userInfo[Key.presentation] else { return .standard }
        guard let rawValue = value as? String else { return nil }
        return AgentOraclePopoverPresentation(rawValue: rawValue)
    }

    private static func uuid(from value: Any?) -> UUID? {
        if let value = value as? UUID { return value }
        if let value = value as? String { return UUID(uuidString: value) }
        return nil
    }

    private static func chatID(from value: Any?) -> String? {
        if let value = value as? UUID { return value.uuidString }
        return nonEmptyChatID(value as? String)
    }

    private static func nonEmptyChatID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum ContextBuilderFollowUpBranch: String {
    case plan
    case review

    static func select(responseType: String?) -> Self? {
        let normalized = responseType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "review": return .review
        case "plan", "question": return .plan
        default: return nil
        }
    }
}
