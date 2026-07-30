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

    init(windowID: Int? = nil, workspaceID: UUID, tabID: UUID, sessionID: UUID? = nil) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
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
        components.queryItems = queryItems

        return components.url ?? URL(string: "\(AppDeepLinkURLScheme.canonical)://agent/session")!
    }

    static func parse(notificationUserInfo userInfo: [AnyHashable: Any]) -> AgentSessionDeepLinkRoute? {
        guard stringValue(for: AppDeepLinkRouteUserInfoKey.routeKind, in: userInfo) == AppDeepLinkRouteUserInfoValue.agentSessionKind else {
            return nil
        }
        guard intValue(for: AppDeepLinkRouteUserInfoKey.routeVersion, in: userInfo) == AppDeepLinkRouteUserInfoValue.currentRouteVersion else {
            return nil
        }
        guard let workspaceID = uuidValue(for: AppDeepLinkRouteUserInfoKey.workspaceID, in: userInfo),
              let tabID = uuidValue(for: AppDeepLinkRouteUserInfoKey.tabID, in: userInfo)
        else {
            return nil
        }

        let sessionID: UUID?
        if value(for: AppDeepLinkRouteUserInfoKey.sessionID, in: userInfo) != nil {
            guard let parsedSessionID = uuidValue(for: AppDeepLinkRouteUserInfoKey.sessionID, in: userInfo) else {
                return nil
            }
            sessionID = parsedSessionID
        } else {
            sessionID = nil
        }

        return AgentSessionDeepLinkRoute(
            windowID: intValue(for: AppDeepLinkRouteUserInfoKey.windowID, in: userInfo),
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID
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
            sessionID: sessionID
        )
    }

    private static func value(for key: String, in userInfo: [AnyHashable: Any]) -> Any? {
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

    private static func stringValue(for key: String, in userInfo: [AnyHashable: Any]) -> String? {
        guard let rawValue = value(for: key, in: userInfo) else { return nil }
        if let string = rawValue as? String {
            return string
        }
        if let string = rawValue as? NSString {
            return string as String
        }
        return nil
    }

    private static func intValue(for key: String, in userInfo: [AnyHashable: Any]) -> Int? {
        guard let rawValue = value(for: key, in: userInfo) else { return nil }
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

    private static func uuidValue(for key: String, in userInfo: [AnyHashable: Any]) -> UUID? {
        guard let string = stringValue(for: key, in: userInfo) else { return nil }
        return UUID(uuidString: string)
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
}
