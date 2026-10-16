import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
private final class RecordingRouter: AppNotificationRouting {
    private(set) var openedRoutes: [AgentSessionDeepLinkRoute?] = []

    func openNotificationRoute(_ route: AgentSessionDeepLinkRoute?) async {
        openedRoutes.append(route)
    }
}

@MainActor
private final class RecordingDispatcher: AgentNotificationActionDispatching {
    var outcome: AgentNotificationActionOutcome = .applied
    private(set) var requests: [AgentNotificationActionRequest] = []

    func dispatch(
        _ request: AgentNotificationActionRequest,
        route: AgentSessionDeepLinkRoute,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome {
        requests.append(request)
        return outcome
    }
}

@MainActor
final class AppNotificationResponseHandlerTests: XCTestCase {
    private var router: RecordingRouter!
    private var dispatcher: RecordingDispatcher!
    private var feedback: [String] = []
    private var handler: AppNotificationResponseHandler!

    private let route = AgentSessionDeepLinkRoute(
        windowID: 2,
        workspaceID: UUID(),
        tabID: UUID(),
        sessionID: UUID(),
        interactionID: UUID()
    )

    override func setUp() async throws {
        router = RecordingRouter()
        dispatcher = RecordingDispatcher()
        feedback = []
        handler = AppNotificationResponseHandler(
            router: router,
            dispatcher: dispatcher,
            preferences: FakeNotificationPreferencesProvider(),
            postFeedback: { [unowned self] _, body, _ in feedback.append(body) }
        )
    }

    private func response(
        _ actionIdentifier: String,
        payload: AppNotificationPayload?,
        text: String? = nil
    ) -> AppNotificationResponse {
        AppNotificationResponse(
            requestIdentifier: "id",
            actionIdentifier: actionIdentifier,
            userText: text,
            payload: payload,
            route: payload?.route
        )
    }

    private func interactionPayload(launchID: UUID = AppNotificationLaunchIdentity.current) -> AppNotificationPayload {
        AppNotificationPayload(
            kind: .interaction,
            route: route,
            launchID: launchID,
            interaction: .init(id: route.interactionID!, kind: .approval, fingerprint: "fp")
        )
    }

    func testDefaultClickOpensTheExactRouteIncludingInteraction() async {
        let result = await handler.handle(response(AppNotificationActionID.defaultAction, payload: interactionPayload()))

        XCTAssertEqual(result, .opened(route))
        XCTAssertEqual(router.openedRoutes, [route])
        XCTAssertTrue(dispatcher.requests.isEmpty)
    }

    func testRouteV1OnlyNotificationStillOpens() async {
        let legacyRoute = AgentSessionDeepLinkRoute(workspaceID: UUID(), tabID: UUID())
        let result = await handler.handle(AppNotificationResponse(
            requestIdentifier: "legacy",
            actionIdentifier: AppNotificationActionID.defaultAction,
            payload: nil,
            route: legacyRoute
        ))
        XCTAssertEqual(result, .opened(legacyRoute))
    }

    func testBackgroundActionIsDispatchedWithInteractionReference() async throws {
        let payload = interactionPayload()
        let result = await handler.handle(response(AppNotificationActionID.approve, payload: payload))

        XCTAssertEqual(result, .resolved(.applied))
        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.action, .approve)
        XCTAssertEqual(request.tabID, route.tabID)
        XCTAssertEqual(request.sessionID, route.sessionID)
        XCTAssertEqual(request.interaction, payload.interaction)
        XCTAssertTrue(router.openedRoutes.isEmpty, "Background actions never activate the app")
        XCTAssertTrue(feedback.isEmpty)
    }

    func testActionFromPreviousLaunchIsStaleAndNeverDispatched() async {
        let result = await handler.handle(response(AppNotificationActionID.approve, payload: interactionPayload(launchID: UUID())))

        XCTAssertEqual(result, .resolved(.stale))
        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertEqual(feedback.count, 1)
    }

    func testStaleOutcomePostsFeedback() async {
        dispatcher.outcome = .stale
        _ = await handler.handle(response(AppNotificationActionID.decline, payload: interactionPayload()))
        XCTAssertEqual(feedback.first?.contains("no longer pending"), true)
    }

    func testReplyTextIsForwarded() async {
        _ = await handler.handle(response(AppNotificationActionID.reply, payload: interactionPayload(), text: "go"))
        XCTAssertEqual(dispatcher.requests.first?.userText, "go")
    }

    func testActionWithoutUnderstoodPayloadOpensInstead() async {
        let result = await handler.handle(response(AppNotificationActionID.approve, payload: nil))
        XCTAssertEqual(result, .opened(nil))
        XCTAssertTrue(dispatcher.requests.isEmpty)
    }

    func testDismissIsIgnoredAndReviewOpens() async {
        let dismissed = await handler.handle(response(AppNotificationActionID.dismissAction, payload: interactionPayload()))
        XCTAssertEqual(dismissed, .ignored)

        let reviewed = await handler.handle(response(AppNotificationActionID.review, payload: interactionPayload()))
        XCTAssertEqual(reviewed, .opened(route))
    }

    func testNotificationRouteQueuesURLWhenNoWindowIsLive() async throws {
        let manager = WindowStatesManager.shared
        let originalWindows = manager.allWindows
        let originalPendingURLs = manager.pendingURLs
        manager.allWindows = []
        manager.pendingURLs = []
        defer {
            manager.allWindows = originalWindows
            manager.pendingURLs = originalPendingURLs
        }

        await AppDeepLinkRouter(windowStatesManager: manager).route(notificationRoute: route)

        XCTAssertEqual(manager.pendingURLs, [route.url])
        XCTAssertEqual(try AgentSessionDeepLinkRoute.parse(url: XCTUnwrap(manager.pendingURLs.first)), route)
    }

    func testMCPAskUserActivationPolicyIsOptIn() {
        var preferences = NotificationPreferences.defaults
        XCTAssertFalse(MCPAskUserToolProvider.prefersNotificationOverActivation(isAppActive: false, preferences: preferences))

        preferences.mcpAskUserNotifyInsteadOfActivate = true
        XCTAssertTrue(MCPAskUserToolProvider.prefersNotificationOverActivation(isAppActive: false, preferences: preferences))
        XCTAssertFalse(MCPAskUserToolProvider.prefersNotificationOverActivation(isAppActive: true, preferences: preferences))

        preferences.agentInteractions = false
        XCTAssertFalse(MCPAskUserToolProvider.prefersNotificationOverActivation(isAppActive: false, preferences: preferences))
    }
}
