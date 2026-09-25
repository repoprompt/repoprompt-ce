import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSessionPinOrderTests: XCTestCase {
    func testExplicitPinnedOrderPrecedesLegacyActivityOrder() {
        let now = Date(timeIntervalSince1970: 1000)
        let legacyNew = tab("Legacy new", modified: now, pinned: true)
        let legacyOld = tab("Legacy old", modified: now.addingTimeInterval(-100), pinned: true)
        let manualSecond = tab("Manual second", modified: now.addingTimeInterval(-200), pinned: true, order: 1)
        let manualFirst = tab("Manual first", modified: now.addingTimeInterval(-300), pinned: true, order: 0)
        let unpinned = tab("Unpinned", modified: now.addingTimeInterval(100), pinned: false)
        let tabs = [legacyNew, legacyOld, manualSecond, manualFirst, unpinned]
        let rows = AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            rowTabs: tabs,
            sessions: [:],
            authoritativeSessionIDByTabID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.activeAgentSessionID!) }),
            sessionIndex: [:],
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: []
        ).build()

        XCTAssertEqual(rows.map(\.title), [
            "Manual first", "Manual second", "Legacy new", "Legacy old", "Unpinned"
        ])
    }

    func testPinOrderRoundTripsAndLegacyTabDecodesWithoutOrder() throws {
        let original = tab("Pinned", modified: Date(timeIntervalSince1970: 100), pinned: true, order: 3)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ComposeTabState.self, from: encoded).pinnedOrder, 3)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "pinnedOrder")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(ComposeTabState.self, from: legacyData).pinnedOrder)

        legacy["pinnedOrder"] = "future-format"
        let malformedData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(ComposeTabState.self, from: malformedData).pinnedOrder)
    }

    private func tab(
        _ name: String,
        modified: Date,
        pinned: Bool,
        order: Int? = nil
    ) -> ComposeTabState {
        ComposeTabState(
            name: name,
            lastModified: modified,
            isPinned: pinned,
            pinnedOrder: order,
            activeAgentSessionID: UUID()
        )
    }
}
