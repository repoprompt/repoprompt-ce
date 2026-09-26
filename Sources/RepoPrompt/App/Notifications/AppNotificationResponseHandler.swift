import AppKit
import Foundation
import UserNotifications

/// `Sendable` extraction of a `UNNotificationResponse`, built on the delegate's thread before any
/// actor hop (`UNNotificationResponse` and `userInfo` are not `Sendable`).
struct AppNotificationResponse: Equatable {
    let requestIdentifier: String
    let actionIdentifier: String
    let userText: String?
    let payload: AppNotificationPayload?
    /// Route parsed from route-v1 keys; present even for notifications without a v2 payload.
    let route: AgentSessionDeepLinkRoute?

    init(
        requestIdentifier: String,
        actionIdentifier: String,
        userText: String? = nil,
        payload: AppNotificationPayload?,
        route: AgentSessionDeepLinkRoute?
    ) {
        self.requestIdentifier = requestIdentifier
        self.actionIdentifier = actionIdentifier
        self.userText = userText
        self.payload = payload
        self.route = route
    }

    init(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        self.init(
            requestIdentifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            payload: AppNotificationPayload.parse(userInfo),
            route: AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo)
        )
    }
}

enum AppNotificationResponseResult: Equatable {
    case ignored
    case opened(AgentSessionDeepLinkRoute?)
    case resolved(AgentNotificationActionOutcome)
}

/// Opens a notification's route (click, "Review…", or any action that cannot be applied).
@MainActor
protocol AppNotificationRouting: AnyObject {
    func openNotificationRoute(_ route: AgentSessionDeepLinkRoute?) async
}

/// Applies a background action in the window that owns the session.
@MainActor
protocol AgentNotificationActionDispatching: AnyObject {
    func dispatch(
        _ request: AgentNotificationActionRequest,
        route: AgentSessionDeepLinkRoute,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome
}

@MainActor
final class AppNotificationResponseHandler {
    typealias FeedbackPoster = @MainActor (_ title: String, _ body: String, _ route: AgentSessionDeepLinkRoute?) -> Void

    private let router: AppNotificationRouting
    private let dispatcher: AgentNotificationActionDispatching
    private let preferences: NotificationPreferencesProviding
    private let postFeedback: FeedbackPoster

    init(
        router: AppNotificationRouting,
        dispatcher: AgentNotificationActionDispatching,
        preferences: NotificationPreferencesProviding,
        postFeedback: @escaping FeedbackPoster
    ) {
        self.router = router
        self.dispatcher = dispatcher
        self.preferences = preferences
        self.postFeedback = postFeedback
    }

    @discardableResult
    func handle(_ response: AppNotificationResponse) async -> AppNotificationResponseResult {
        let identity = AgentNotificationActionIdentity(actionIdentifier: response.actionIdentifier)
        if identity == .dismiss {
            return .ignored
        }
        let route = response.payload?.route ?? response.route
        if identity.opensApp {
            await router.openNotificationRoute(route)
            return .opened(route)
        }

        guard let payload = response.payload,
              let actionRoute = payload.route,
              payload.kind == .interaction || payload.kind == .turnComplete
        else {
            // A background action on a notification this build cannot interpret: open instead of guessing.
            await router.openNotificationRoute(route)
            return .opened(route)
        }
        guard payload.isFromCurrentLaunch else {
            // Posted by a previous launch: nothing it refers to can still be pending.
            report(.stale, actionTitle: Self.actionTitle(identity), route: actionRoute)
            return .resolved(.stale)
        }

        let request = AgentNotificationActionRequest(
            notificationKind: payload.kind,
            tabID: actionRoute.tabID,
            sessionID: actionRoute.sessionID,
            interaction: payload.interaction,
            action: identity,
            userText: response.userText,
            turnMarker: payload.turnMarker
        )
        let outcome = dispatcher.dispatch(
            request,
            route: actionRoute,
            preferences: preferences.currentNotificationPreferences
        )
        report(outcome, actionTitle: Self.actionTitle(identity), route: actionRoute)
        return .resolved(outcome)
    }

    private func report(_ outcome: AgentNotificationActionOutcome, actionTitle: String, route: AgentSessionDeepLinkRoute) {
        let body: String
        switch outcome {
        case .applied:
            return
        case .stale, .windowUnavailable:
            body = "Couldn't apply “\(actionTitle)” — the request is no longer pending."
        case .ineligible:
            body = "“\(actionTitle)” isn't available from a notification for this request. Review it in RepoPrompt."
        case .invalidInput:
            body = AgentNotificationActionResolver.emptyReplyMessage
        }
        postFeedback("RepoPrompt", body, route.withInteractionID(nil))
    }

    private static func actionTitle(_ identity: AgentNotificationActionIdentity) -> String {
        switch identity {
        case .approve: "Approve"
        case .decline: "Decline"
        case let .choice(index): "Option \(index + 1)"
        case .reply: "Reply"
        case .skip: "Skip"
        case .review, .open, .defaultClick, .dismiss, .unknown: "Open"
        }
    }
}

// MARK: - Live adapters

/// Routes notification clicks through `AppDeepLinkRouter`, queueing the route for cold launch or
/// background mode when no window is live yet.
@MainActor
final class LiveAppNotificationRouter: AppNotificationRouting {
    func openNotificationRoute(_ route: AgentSessionDeepLinkRoute?) async {
        await AppDeepLinkRouter.shared.route(notificationRoute: route)
    }
}

/// Finds the window whose active workspace owns the session. Never switches workspaces: a live
/// pending interaction always lives in some window's active workspace.
@MainActor
final class LiveAgentNotificationActionDispatcher: AgentNotificationActionDispatching {
    func dispatch(
        _ request: AgentNotificationActionRequest,
        route: AgentSessionDeepLinkRoute,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome {
        let candidates = WindowStatesManager.shared.allWindows.filter { window in
            !window.isClosing
                && window.workspaceManager.activeWorkspace?.id == route.workspaceID
                && window.agentModeViewModel.sessions[route.tabID] != nil
        }
        let window = candidates.first { $0.windowID == route.windowID } ?? candidates.first
        guard let window else { return .windowUnavailable }
        return window.agentModeViewModel.resolveNotificationAction(request, preferences: preferences)
    }
}

@MainActor
final class LiveAgentSessionVisibility: AgentSessionVisibilityProviding {
    var isAppActive: Bool {
        NSApp?.isActive == true
    }

    func isAgentSessionVisible(windowID: Int, tabID: UUID, sessionID: UUID?) -> Bool {
        guard isAppActive else { return false }
        let windows = WindowStatesManager.shared.allWindows
        let window = windows.first { $0.windowID == windowID }
            ?? windows.first { $0.agentModeViewModel.sessions[tabID] != nil && $0.isCurrentlyFocused }
        return window?.isAgentSessionVisible(tabID: tabID, sessionID: sessionID) ?? false
    }
}
