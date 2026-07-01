@testable import RepoPrompt
import XCTest

@MainActor
final class AgentSessionSidebarUIStoreTests: XCTestCase {
    func testDefaultCollapseSeedingIsOneShotAndPreservesUserIntent() {
        let store = AgentSessionSidebarUIStore()
        let root = AgentSidebarThreadKey.session(id(1))
        let nested = AgentSidebarThreadKey.session(id(2))
        let later = AgentSidebarThreadKey.session(id(3))

        store.seedDefaultCollapsedThreads(eligibleKeys: [root, nested])
        XCTAssertEqual(store.snapshot.collapsedThreadKeys, [root, nested])
        XCTAssertEqual(store.snapshot.defaultCollapsedThreadKeysHandled, [root, nested])

        store.setThreadCollapsed(false, for: nested)
        XCTAssertEqual(store.snapshot.collapsedThreadKeys, [root])
        XCTAssertTrue(store.snapshot.defaultCollapsedThreadKeysHandled.contains(nested))

        store.seedDefaultCollapsedThreads(eligibleKeys: [root, nested])
        XCTAssertEqual(store.snapshot.collapsedThreadKeys, [root])

        store.expandAllSidebarThreads(eligibleKeys: [root, nested])
        XCTAssertTrue(store.snapshot.collapsedThreadKeys.isEmpty)
        XCTAssertEqual(store.snapshot.defaultCollapsedThreadKeysHandled, [root, nested])

        store.seedDefaultCollapsedThreads(eligibleKeys: [root, nested])
        XCTAssertTrue(store.snapshot.collapsedThreadKeys.isEmpty)

        store.seedDefaultCollapsedThreads(eligibleKeys: [root, nested, later])
        XCTAssertEqual(store.snapshot.collapsedThreadKeys, [later])
        XCTAssertEqual(store.snapshot.defaultCollapsedThreadKeysHandled, [root, nested, later])
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
