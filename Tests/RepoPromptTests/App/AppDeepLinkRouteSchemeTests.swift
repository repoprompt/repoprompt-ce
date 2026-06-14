@testable import RepoPrompt
import XCTest

final class AppDeepLinkRouteSchemeTests: XCTestCase {
    func testCanonicalSchemeOpenURLRoutesAsLegacyURL() throws {
        let url = try XCTUnwrap(URL(string: "repoprompt-ce://open//tmp/x"))
        guard case let .route(.legacyURL(routedURL)) = AppDeepLinkRoute.parse(url: url) else {
            return XCTFail("Expected canonical scheme open URL to route as a legacy URL")
        }
        XCTAssertEqual(routedURL, url)
    }

    func testLegacySchemeOpenURLStillRoutesAsLegacyURL() throws {
        let url = try XCTUnwrap(URL(string: "repoprompt://open//tmp/x"))
        guard case let .route(.legacyURL(routedURL)) = AppDeepLinkRoute.parse(url: url) else {
            return XCTFail("Expected legacy scheme open URL to keep routing as a legacy URL")
        }
        XCTAssertEqual(routedURL, url)
    }

    func testCanonicalSchemeAgentSessionRoutes() throws {
        let route = try AgentSessionDeepLinkRoute(
            windowID: 4,
            workspaceID: XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444")),
            tabID: XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555")),
            sessionID: XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        )
        let url = try XCTUnwrap(URL(
            string:
            "repoprompt-ce://agent/session?workspace_id=\(route.workspaceID.uuidString)&tab_id=\(route.tabID.uuidString)&session_id=\(route.sessionID!.uuidString)&window_id=\(route.windowID!)"
        ))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: url), .route(.agentSession(route)))
    }

    func testCanonicalSchemeAgentSessionWithInvalidPayloadIsInvalidScopedRoute() throws {
        let url = try XCTUnwrap(URL(
            string:
            "repoprompt-ce://agent/session?tab_id=\(UUID().uuidString)"
        ))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: url), .invalidScopedRoute)
    }

    func testForeignSchemeIsUnsupported() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: url), .unsupported)
    }

    func testAgentSessionBuilderEmitsCanonicalSchemeAndRoundTrips() throws {
        let route = try AgentSessionDeepLinkRoute(
            windowID: 9,
            workspaceID: XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777")),
            tabID: XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888")),
            sessionID: XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        )

        XCTAssertEqual(route.url.scheme, AppDeepLinkScheme.canonical)
        XCTAssertEqual(AppDeepLinkScheme.canonical, "repoprompt-ce")

        let roundTripped = try XCTUnwrap(URL(string: route.url.absoluteString))
        XCTAssertEqual(AppDeepLinkRoute.parse(url: roundTripped), .route(.agentSession(route)))
    }

    func testSchemeMatchingIsCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "REPOPROMPT-CE://open//tmp/x"))
        guard case .route(.legacyURL) = AppDeepLinkRoute.parse(url: url) else {
            return XCTFail("Expected uppercased canonical scheme to be accepted")
        }
    }
}
