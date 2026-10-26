import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentMonitorDashboardSortPolicyTests: XCTestCase {
    private func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    private func row(
        _ name: String,
        status: AgentMonitorLinkStatus = .idle,
        provider: String? = nil,
        location: String? = nil,
        activity: TimeInterval? = nil,
        unread: Bool = false,
        targetID: UUID,
        linkID: UUID,
        generation: UInt64 = 1,
        route: AgentSessionDeepLinkRoute? = nil
    ) -> AgentMonitorPillProps.Outbound {
        AgentMonitorPillProps.Outbound(
            linkID: linkID,
            generation: generation,
            targetSessionID: targetID,
            targetEndpoint: AgentSessionLinkIdentityTestSupport.endpoint(sessionID: targetID),
            displayName: name,
            providerDisplayName: provider,
            locationLabel: location,
            status: status,
            lastActivityAt: activity.map(Date.init(timeIntervalSince1970:)),
            hasUnreadActivity: unread,
            targetRoute: route
        )
    }

    private func assertCanonicalIdentityOrder(
        _ rows: [AgentMonitorPillProps.Outbound],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows).map(\.targetSessionID),
            [id("000000000001"), id("000000000002")],
            file: file,
            line: line
        )
    }

    func testActiveRowsPrecedeInactive() {
        let linkID = id("100000000000")
        let rows = [
            row("Same", status: .idle, location: "same", targetID: id("000000000001"), linkID: linkID),
            row("Same", status: .awaitingUser, location: "same", targetID: id("000000000002"), linkID: linkID)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows).map(\.targetSessionID),
            [id("000000000002"), id("000000000001")]
        )
    }

    func testStatusSubtypesDoNotRankWithinActiveOrInactiveBuckets() {
        let linkID = id("100000000000")
        let statusPairs: [(AgentMonitorLinkStatus, AgentMonitorLinkStatus)] = [
            (AgentMonitorLinkStatus.running, .awaitingUser),
            (.awaitingUser, .running),
            (.idle, .unavailable),
            (.unavailable, .idle)
        ]
        for (lowerStatus, higherStatus) in statusPairs {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    status: higherStatus,
                    location: "same",
                    targetID: id("000000000002"),
                    linkID: linkID
                ),
                row(
                    "Same",
                    status: lowerStatus,
                    location: "same",
                    targetID: id("000000000001"),
                    linkID: linkID
                )
            ])
        }
    }

    func testKnownLocationsPrecedeMissingAndUseTrimmedPOSIXFolding() {
        let linkID = id("100000000000")
        let rows = [
            row("Same", location: nil, targetID: id("000000000005"), linkID: linkID),
            row("Same", location: "  ", targetID: id("000000000004"), linkID: linkID),
            row("Same", location: " Éclair ", targetID: id("000000000001"), linkID: linkID),
            row("Same", location: "eagle", targetID: id("000000000002"), linkID: linkID),
            row("Same", location: "ECLAIR", targetID: id("000000000003"), linkID: linkID)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows).map(\.targetSessionID),
            [id("000000000002"), id("000000000001"), id("000000000003"), id("000000000004"), id("000000000005")]
        )
    }

    func testLocationPrecedesTaskName() {
        let linkID = id("100000000000")
        let rows = [
            row("Alpha task", location: "Zulu location", targetID: id("000000000001"), linkID: linkID),
            row("Zulu task", location: "Alpha location", targetID: id("000000000002"), linkID: linkID)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows).map(\.targetSessionID),
            [id("000000000002"), id("000000000001")]
        )
    }

    func testFoldedTaskNameFollowsFoldedLocation() {
        let linkID = id("100000000000")
        let rows = [
            row("Zulu", location: "Same", targetID: id("000000000004"), linkID: linkID),
            row("éclair", location: " same ", targetID: id("000000000002"), linkID: linkID),
            row("ECLAIR", location: "SAME", targetID: id("000000000003"), linkID: linkID),
            row("Eagle", location: "same", targetID: id("000000000001"), linkID: linkID)
        ]

        XCTAssertEqual(
            AgentMonitorDashboardSortPolicy.sorted(rows).map(\.targetSessionID),
            [id("000000000001"), id("000000000002"), id("000000000003"), id("000000000004")]
        )
    }

    func testTargetThenLinkUUIDBreakLexicalTies() {
        let lowerTarget = id("000000000001")
        let higherTarget = id("000000000002")
        let lowerLink = id("100000000001")
        let higherLink = id("100000000002")
        let rows = [
            row("Same", location: "same", targetID: higherTarget, linkID: lowerLink),
            row("Same", location: "same", targetID: lowerTarget, linkID: higherLink),
            row("Same", location: "same", targetID: lowerTarget, linkID: lowerLink)
        ]

        let sorted = AgentMonitorDashboardSortPolicy.sorted(rows)
        XCTAssertEqual(sorted.map(\.targetSessionID), [lowerTarget, lowerTarget, higherTarget])
        XCTAssertEqual(sorted.map(\.linkID), [lowerLink, higherLink, lowerLink])
    }

    func testActivityDoesNotAffectOrdering() {
        let linkID = id("100000000000")
        for (lowerActivity, higherActivity) in [(1.0, 999.0), (999.0, 1.0)] {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    location: "same",
                    activity: higherActivity,
                    targetID: id("000000000002"),
                    linkID: linkID
                ),
                row(
                    "Same",
                    location: "same",
                    activity: lowerActivity,
                    targetID: id("000000000001"),
                    linkID: linkID
                )
            ])
        }
    }

    func testProviderDoesNotAffectOrdering() {
        let linkID = id("100000000000")
        for (lowerProvider, higherProvider) in [("Alpha", "Zulu"), ("Zulu", "Alpha")] {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    provider: higherProvider,
                    location: "same",
                    targetID: id("000000000002"),
                    linkID: linkID
                ),
                row(
                    "Same",
                    provider: lowerProvider,
                    location: "same",
                    targetID: id("000000000001"),
                    linkID: linkID
                )
            ])
        }
    }

    func testUnreadDoesNotAffectOrdering() {
        let linkID = id("100000000000")
        for (lowerUnread, higherUnread) in [(false, true), (true, false)] {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    location: "same",
                    unread: higherUnread,
                    targetID: id("000000000002"),
                    linkID: linkID
                ),
                row(
                    "Same",
                    location: "same",
                    unread: lowerUnread,
                    targetID: id("000000000001"),
                    linkID: linkID
                )
            ])
        }
    }

    func testRouteDoesNotAffectOrdering() {
        let linkID = id("100000000000")
        let route = AgentSessionDeepLinkRoute(
            windowID: 7,
            workspaceID: id("200000000001"),
            tabID: id("300000000001"),
            sessionID: id("000000000001")
        )
        for (lowerRoute, higherRoute) in [
            (AgentSessionDeepLinkRoute?.none, route),
            (route, nil)
        ] {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    location: "same",
                    targetID: id("000000000002"),
                    linkID: linkID,
                    route: higherRoute
                ),
                row(
                    "Same",
                    location: "same",
                    targetID: id("000000000001"),
                    linkID: linkID,
                    route: lowerRoute
                )
            ])
        }
    }

    func testGenerationDoesNotAffectOrdering() {
        let linkID = id("100000000000")
        for (lowerGeneration, higherGeneration) in [(UInt64(1), UInt64(99)), (UInt64(99), UInt64(1))] {
            assertCanonicalIdentityOrder([
                row(
                    "Same",
                    location: "same",
                    targetID: id("000000000002"),
                    linkID: linkID,
                    generation: higherGeneration
                ),
                row(
                    "Same",
                    location: "same",
                    targetID: id("000000000001"),
                    linkID: linkID,
                    generation: lowerGeneration
                )
            ])
        }
    }
}
