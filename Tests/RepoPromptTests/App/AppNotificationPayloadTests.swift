import Foundation
@testable import RepoPromptApp
import XCTest

final class AppNotificationPayloadTests: XCTestCase {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let interactionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private var route: AgentSessionDeepLinkRoute {
        AgentSessionDeepLinkRoute(
            windowID: 3,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            interactionID: interactionID
        )
    }

    func testInteractionPayloadRoundTripsThroughUserInfo() throws {
        let payload = AppNotificationPayload(
            kind: .interaction,
            route: route,
            interaction: .init(id: interactionID, kind: .approval, fingerprint: "abc123", choiceCount: 2),
            postedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let parsed = try XCTUnwrap(AppNotificationPayload.parse(payload.userInfo))

        XCTAssertEqual(parsed, payload)
        XCTAssertTrue(parsed.isFromCurrentLaunch)
    }

    func testPayloadKeepsRouteV1KeysSoOlderParsersStillRoute() {
        let payload = AppNotificationPayload(kind: .turnComplete, route: route.withInteractionID(nil))
        let userInfo = payload.userInfo

        XCTAssertEqual(userInfo[AppDeepLinkRouteUserInfoKey.routeVersion] as? Int, 1)
        XCTAssertEqual(AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo), route.withInteractionID(nil))
    }

    func testRouteV1OnlyUserInfoIsNotAV2PayloadButStillParsesAsRoute() {
        let legacy = AgentSessionDeepLinkRoute(workspaceID: workspaceID, tabID: tabID).notificationUserInfo

        XCTAssertNil(AppNotificationPayload.parse(legacy))
        XCTAssertEqual(
            AgentSessionDeepLinkRoute.parse(notificationUserInfo: legacy),
            AgentSessionDeepLinkRoute(workspaceID: workspaceID, tabID: tabID)
        )
    }

    func testBridgedNSStringKeysAndNSNumberValuesAreTolerated() throws {
        let payload = AppNotificationPayload(
            kind: .interaction,
            route: route,
            interaction: .init(id: interactionID, kind: .askUser, fingerprint: "fp", choiceCount: 3)
        )
        var bridged: [AnyHashable: Any] = [:]
        for (key, value) in payload.userInfo {
            let bridgedKey = try NSString(string: XCTUnwrap(key.base as? String))
            if let int = value as? Int {
                bridged[bridgedKey] = NSNumber(value: int)
            } else if let string = value as? String {
                bridged[bridgedKey] = NSString(string: string)
            } else {
                bridged[bridgedKey] = value
            }
        }

        let parsed = try XCTUnwrap(AppNotificationPayload.parse(bridged))
        XCTAssertEqual(parsed.interaction?.choiceCount, 3)
        XCTAssertEqual(parsed.route, route)
    }

    func testFutureVersionKeepsRouteButDropsInteractionReference() throws {
        var userInfo = AppNotificationPayload(
            kind: .interaction,
            route: route,
            interaction: .init(id: interactionID, kind: .approval, fingerprint: "fp")
        ).userInfo
        userInfo[AppNotificationPayload.Key.payloadVersion] = AppNotificationPayload.currentVersion + 1

        let parsed = try XCTUnwrap(AppNotificationPayload.parse(userInfo))
        XCTAssertEqual(parsed.route, route)
        XCTAssertNil(parsed.interaction, "Interaction references are only trusted at the understood version")
    }

    func testMalformedPayloadFieldsAreRejected() {
        var userInfo = AppNotificationPayload(kind: .interaction, route: route).userInfo
        userInfo[AppNotificationPayload.Key.launchID] = "not-a-uuid"
        XCTAssertNil(AppNotificationPayload.parse(userInfo))

        var unknownKind = AppNotificationPayload(kind: .interaction, route: route).userInfo
        unknownKind[AppNotificationPayload.Key.kind] = "surprise"
        XCTAssertNil(AppNotificationPayload.parse(unknownKind))
    }

    func testPayloadFromAnotherLaunchIsNotCurrent() {
        let payload = AppNotificationPayload(kind: .interaction, route: route, launchID: UUID())
        XCTAssertFalse(payload.isFromCurrentLaunch)
    }

    func testInteractionIDRoundTripsThroughDeepLinkURL() {
        XCTAssertEqual(AppDeepLinkRoute.parse(url: route.url), .route(.agentSession(route)))
        XCTAssertEqual(AgentSessionDeepLinkRoute.parse(url: route.url)?.interactionID, interactionID)
    }

    func testStableIdentifiersReplaceRatherThanStack() {
        XCTAssertEqual(
            AppNotificationIdentifier.interaction(interactionID),
            AppNotificationIdentifier.interaction(interactionID)
        )
        XCTAssertEqual(AppNotificationIdentifier.turnComplete(tabID: tabID), "rp.agent.turn.\(tabID.uuidString)")
        XCTAssertEqual(
            AppNotificationIdentifier.sessionThread(tabID: tabID, sessionID: nil),
            "rp.agent.session.\(tabID.uuidString)"
        )
        XCTAssertEqual(
            AppNotificationIdentifier.sessionThread(tabID: tabID, sessionID: sessionID),
            "rp.agent.session.\(sessionID.uuidString)"
        )
    }
}

@MainActor
final class NotificationCategoryRegistryTests: XCTestCase {
    func testInstallRegistersStaticCategoriesOnly() async {
        let center = FakeUserNotificationCenter()
        let registry = NotificationCategoryRegistry(client: center, staticCategories: AgentNotificationAction.staticCategories)

        await registry.installStaticCategories()

        XCTAssertEqual(center.registeredCategories, AgentNotificationAction.staticCategories)
        XCTAssertTrue(registry.dynamicIdentifiers.isEmpty)
    }

    func testDynamicCategoriesAreUnionedAndPruned() async throws {
        let center = FakeUserNotificationCenter()
        let registry = NotificationCategoryRegistry(client: center, staticCategories: AgentNotificationAction.staticCategories)
        await registry.installStaticCategories()
        let interactionID = UUID()
        let category = try XCTUnwrap(AgentNotificationAction.category(
            for: [.choice(index: 0, label: "Yes"), .choice(index: 1, label: "No"), .review],
            interactionID: interactionID
        ))

        let registered = await registry.ensureRegistered(category)

        XCTAssertTrue(registered)
        XCTAssertTrue(AppNotificationCategoryID.isDynamic(category.identifier))
        XCTAssertTrue(center.registeredCategories.contains(category))
        XCTAssertTrue(center.registeredCategories.isSuperset(of: AgentNotificationAction.staticCategories))

        await registry.pruneDynamicCategories(keeping: [])
        XCTAssertFalse(center.registeredCategories.contains(category))
        XCTAssertTrue(center.registeredCategories.isSuperset(of: AgentNotificationAction.staticCategories))
    }

    func testAlreadyRegisteredStaticCategoryDoesNotRewriteTheSet() async throws {
        let center = FakeUserNotificationCenter()
        let registry = NotificationCategoryRegistry(client: center, staticCategories: AgentNotificationAction.staticCategories)
        await registry.installStaticCategories()
        let writes = center.setCategoriesCallCount
        let approve = try XCTUnwrap(AgentNotificationAction.category(for: [.approve, .decline, .review], interactionID: nil))

        let registered = await registry.ensureRegistered(approve)

        XCTAssertTrue(registered)
        XCTAssertEqual(center.setCategoriesCallCount, writes)
    }

    func testDynamicCapFailsClosed() async throws {
        let center = FakeUserNotificationCenter()
        let registry = NotificationCategoryRegistry(client: center, staticCategories: [])
        for _ in 0 ..< NotificationCategoryRegistry.maximumDynamicCategories {
            let category = try XCTUnwrap(AgentNotificationAction.category(
                for: [.choice(index: 0, label: "A")],
                interactionID: UUID()
            ))
            let registered = await registry.ensureRegistered(category)
            XCTAssertTrue(registered)
        }
        let overflow = try XCTUnwrap(AgentNotificationAction.category(
            for: [.choice(index: 0, label: "A")],
            interactionID: UUID()
        ))

        let registered = await registry.ensureRegistered(overflow)
        XCTAssertFalse(registered)
    }
}
