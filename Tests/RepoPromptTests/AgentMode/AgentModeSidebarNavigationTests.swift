@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSidebarNavigationTests: XCTestCase {
    func testParentCyclingUsesRootRowsAndMapsChildToNearestRoot() {
        let rootA = UUID()
        let childA = UUID()
        let rootB = UUID()
        let childB = UUID()
        let rootC = UUID()
        let rows = [
            row(tabID: rootA, depth: 0, title: "A"),
            row(tabID: childA, depth: 1, title: "A child"),
            row(tabID: rootB, depth: 0, title: "B"),
            row(tabID: childB, depth: 1, title: "B child"),
            row(tabID: rootC, depth: 0, title: "C")
        ]

        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: childA, forward: true, rows: rows),
            rootB
        )
        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: childB, forward: false, rows: rows),
            rootA
        )
    }

    func testParentCyclingWrapsAndFallsBackWithoutActiveTab() {
        let rootA = UUID()
        let rootB = UUID()
        let rows = [
            row(tabID: rootA, depth: 0, title: "A"),
            row(tabID: rootB, depth: 0, title: "B")
        ]

        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: rootB, forward: true, rows: rows),
            rootA
        )
        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: rootA, forward: false, rows: rows),
            rootB
        )
        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: nil, forward: true, rows: rows),
            rootA
        )
        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: nil, forward: false, rows: rows),
            rootB
        )
    }

    func testParentCyclingSkipsRedundantSwitchWhenOnlyRootIsAlreadyActive() {
        let root = UUID()
        let child = UUID()
        let rows = [
            row(tabID: root, depth: 0, title: "Root"),
            row(tabID: child, depth: 1, title: "Child")
        ]

        XCTAssertNil(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: root, forward: true, rows: rows)
        )
        XCTAssertEqual(
            AgentModeViewModel.adjacentParentSidebarSessionTabID(from: child, forward: true, rows: rows),
            root
        )
    }

    private func row(tabID: UUID, depth: Int, title: String) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title,
            lastUserMessageAt: nil,
            activityDate: Date(timeIntervalSince1970: 100),
            isPinned: false,
            sessionID: tabID,
            parentSessionID: nil,
            depth: depth,
            isMCPControlled: false,
            worktree: nil,
            worktreeMergeAttention: nil,
            threadKey: nil,
            hasThreadChildren: false,
            isThreadCollapsed: false,
            hiddenThreadDescendantCount: 0,
            hiddenThreadDescendantAttentionCount: 0,
            threadActivityDate: nil
        )
    }
}
