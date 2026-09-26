import Foundation

enum AppDeepLinkURLScheme {
    static let canonical = "repoprompt-ce"
    static let legacy = "repoprompt"

    static func isSupported(_ scheme: String?) -> Bool {
        switch scheme?.lowercased() {
        case canonical, legacy:
            true
        default:
            false
        }
    }
}

struct AgentSessionDeepLinkRoute: Equatable {
    let windowID: Int?
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID?
    /// Optional pending interaction the route should reveal after activation. Absent routes keep
    /// the original "open the session" behavior.
    let interactionID: UUID?

    init(
        windowID: Int? = nil,
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID? = nil,
        interactionID: UUID? = nil
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
        self.interactionID = interactionID
    }

    func withInteractionID(_ interactionID: UUID?) -> AgentSessionDeepLinkRoute {
        AgentSessionDeepLinkRoute(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            interactionID: interactionID
        )
    }

    var notificationUserInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
            AppDeepLinkRouteUserInfoKey.routeVersion: AppDeepLinkRouteUserInfoValue.currentRouteVersion,
            AppDeepLinkRouteUserInfoKey.workspaceID: workspaceID.uuidString,
            AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString
        ]
        if let windowID {
            userInfo[AppDeepLinkRouteUserInfoKey.windowID] = windowID
        }
        if let sessionID {
            userInfo[AppDeepLinkRouteUserInfoKey.sessionID] = sessionID.uuidString
        }
        if let interactionID {
            userInfo[AppDeepLinkRouteUserInfoKey.interactionID] = interactionID.uuidString
        }
        return userInfo
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = AppDeepLinkURLScheme.canonical
        components.host = "agent"
        components.path = "/session"

        var queryItems = [
            URLQueryItem(name: AppDeepLinkRouteQueryItem.workspaceID, value: workspaceID.uuidString),
            URLQueryItem(name: AppDeepLinkRouteQueryItem.tabID, value: tabID.uuidString)
        ]
        if let sessionID {
            queryItems.append(URLQueryItem(name: AppDeepLinkRouteQueryItem.sessionID, value: sessionID.uuidString))
        }
        if let windowID {
            queryItems.append(URLQueryItem(name: AppDeepLinkRouteQueryItem.windowID, value: String(windowID)))
        }
        if let interactionID {
            queryItems.append(URLQueryItem(name: AppDeepLinkRouteQueryItem.interactionID, value: interactionID.uuidString))
        }
        components.queryItems = queryItems

        return components.url ?? URL(string: "\(AppDeepLinkURLScheme.canonical)://agent/session")!
    }

    static func parse(notificationUserInfo userInfo: [AnyHashable: Any]) -> AgentSessionDeepLinkRoute? {
        let reader = NotificationUserInfoReader(userInfo)
        guard reader.string(AppDeepLinkRouteUserInfoKey.routeKind) == AppDeepLinkRouteUserInfoValue.agentSessionKind else {
            return nil
        }
        guard reader.int(AppDeepLinkRouteUserInfoKey.routeVersion) == AppDeepLinkRouteUserInfoValue.currentRouteVersion else {
            return nil
        }
        guard let workspaceID = reader.uuid(AppDeepLinkRouteUserInfoKey.workspaceID),
              let tabID = reader.uuid(AppDeepLinkRouteUserInfoKey.tabID)
        else {
            return nil
        }

        let sessionID: UUID?
        if reader.contains(AppDeepLinkRouteUserInfoKey.sessionID) {
            guard let parsedSessionID = reader.uuid(AppDeepLinkRouteUserInfoKey.sessionID) else {
                return nil
            }
            sessionID = parsedSessionID
        } else {
            sessionID = nil
        }

        return AgentSessionDeepLinkRoute(
            windowID: reader.int(AppDeepLinkRouteUserInfoKey.windowID),
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            interactionID: reader.uuid(AppDeepLinkRouteUserInfoKey.interactionID)
        )
    }

    static func parse(url: URL) -> AgentSessionDeepLinkRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              AppDeepLinkURLScheme.isSupported(components.scheme),
              components.host?.lowercased() == "agent",
              components.path == "/session"
        else {
            return nil
        }

        guard let workspaceID = uuidQueryItem(AppDeepLinkRouteQueryItem.workspaceID, in: components),
              let tabID = uuidQueryItem(AppDeepLinkRouteQueryItem.tabID, in: components)
        else {
            return nil
        }

        let sessionID: UUID?
        if queryItemValue(AppDeepLinkRouteQueryItem.sessionID, in: components) != nil {
            guard let parsedSessionID = uuidQueryItem(AppDeepLinkRouteQueryItem.sessionID, in: components) else {
                return nil
            }
            sessionID = parsedSessionID
        } else {
            sessionID = nil
        }

        return AgentSessionDeepLinkRoute(
            windowID: intQueryItem(AppDeepLinkRouteQueryItem.windowID, in: components),
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            interactionID: uuidQueryItem(AppDeepLinkRouteQueryItem.interactionID, in: components)
        )
    }

    private static func queryItemValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.last(where: { $0.name == name })?.value
    }

    private static func uuidQueryItem(_ name: String, in components: URLComponents) -> UUID? {
        guard let value = queryItemValue(name, in: components) else { return nil }
        return UUID(uuidString: value)
    }

    private static func intQueryItem(_ name: String, in components: URLComponents) -> Int? {
        guard let value = queryItemValue(name, in: components) else { return nil }
        return Int(value)
    }
}

enum AppDeepLinkRoute: Equatable {
    case agentSession(AgentSessionDeepLinkRoute)
    case legacyURL(URL)

    static func parse(url: URL) -> AppDeepLinkURLParseResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              AppDeepLinkURLScheme.isSupported(components.scheme)
        else {
            return .unsupported
        }

        if components.host?.lowercased() == "agent" {
            guard components.path == "/session",
                  let route = AgentSessionDeepLinkRoute.parse(url: url)
            else {
                return .invalidScopedRoute
            }
            return .route(.agentSession(route))
        }

        return .route(.legacyURL(url))
    }

    static func parse(notificationUserInfo userInfo: [AnyHashable: Any]) -> AppDeepLinkRoute? {
        guard let route = AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo) else {
            return nil
        }
        return .agentSession(route)
    }
}

/// Tolerant reader for `UNNotificationContent.userInfo`, which round-trips through property-list
/// bridging: keys may arrive as `String` or `NSString`, and numbers as `Int`, `NSNumber`, or strings.
struct NotificationUserInfoReader {
    private let userInfo: [AnyHashable: Any]

    init(_ userInfo: [AnyHashable: Any]) {
        self.userInfo = userInfo
    }

    func contains(_ key: String) -> Bool {
        value(key) != nil
    }

    func value(_ key: String) -> Any? {
        userInfo.first { entry in
            if let stringKey = entry.key.base as? String {
                return stringKey == key
            }
            if let stringKey = entry.key.base as? NSString {
                return stringKey as String == key
            }
            return false
        }?.value
    }

    func string(_ key: String) -> String? {
        guard let rawValue = value(key) else { return nil }
        if let string = rawValue as? String {
            return string
        }
        if let string = rawValue as? NSString {
            return string as String
        }
        return nil
    }

    func int(_ key: String) -> Int? {
        guard let rawValue = value(key) else { return nil }
        if let int = rawValue as? Int {
            return int
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        if let string = rawValue as? String {
            return Int(string)
        }
        return nil
    }

    func double(_ key: String) -> Double? {
        guard let rawValue = value(key) else { return nil }
        if let double = rawValue as? Double {
            return double
        }
        if let number = rawValue as? NSNumber {
            return number.doubleValue
        }
        if let string = rawValue as? String {
            return Double(string)
        }
        return nil
    }

    func uuid(_ key: String) -> UUID? {
        guard let string = string(key) else { return nil }
        return UUID(uuidString: string)
    }
}

enum AppDeepLinkURLParseResult: Equatable {
    case route(AppDeepLinkRoute)
    case invalidScopedRoute
    case unsupported
}

enum AgentRouteSessionActivationResult: Equatable {
    case ready
    case sessionNotFound
    case sessionWorkspaceMismatch
    case sessionTabMismatch
    case blockedByActiveDifferentSession
}

enum AgentSessionRouteResult: Equatable {
    case routed
    case workspaceUnavailable
    case workspaceSwitchBlocked(String?)
    case tabUnavailable
    case sessionUnavailable
    case sessionMismatch
    case blockedByActiveDifferentSession
}

enum AppDeepLinkRouteUserInfoKey {
    static let routeKind = "rp_route_kind"
    static let routeVersion = "rp_route_version"
    static let windowID = "window_id"
    static let workspaceID = "workspace_id"
    static let tabID = "tab_id"
    static let sessionID = "session_id"
    static let interactionID = "interaction_id"
}

enum AppDeepLinkRouteUserInfoValue {
    static let agentSessionKind = "agent_session"
    static let currentRouteVersion = 1
}

enum AppDeepLinkRouteQueryItem {
    static let windowID = "window_id"
    static let workspaceID = "workspace_id"
    static let tabID = "tab_id"
    static let sessionID = "session_id"
    static let interactionID = "interaction_id"
}
