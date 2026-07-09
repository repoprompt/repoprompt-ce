@testable import RepoPromptApp
import XCTest

final class AgentNavigationHUDSnapshotBuilderTests: XCTestCase {
    func testCurrentWindowItemsPreserveHierarchyStatusAndRollUpSubagents() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let root = UUID()
        let child = UUID()
        let grandchild = UUID()
        let other = UUID()
        let rows = [
            row(tabID: root, depth: 0, title: "Root"),
            row(tabID: child, depth: 1, title: "Child"),
            row(tabID: grandchild, depth: 2, title: "Grandchild"),
            row(tabID: other, depth: 0, title: "Other")
        ]
        let attentionTime = Date(timeIntervalSince1970: 500)

        let items = AgentNavigationHUDSnapshotBuilder.currentWindowItems(
            rows: rows,
            currentTabID: child,
            windowID: 3,
            workspaceID: workspaceID,
            workspaceTitle: "Workspace",
            windowTitle: "Window",
            runStateByTabID: [child: .running],
            attentionRunStateByTabID: [grandchild: .completed, other: .failed],
            attentionMarkedAtByTabID: [other: attentionTime]
        )

        XCTAssertEqual(items.map(\.tabID), [root, child, grandchild, other])
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(items.map(\.displayDepth), [0, 1, 2, 0])
        XCTAssertFalse(items[0].isActiveTab)
        XCTAssertTrue(items[1].isActiveTab)
        XCTAssertEqual(items[1].statusLabel, "Running")
        XCTAssertEqual(items[0].subagentCount, 2)
        XCTAssertEqual(items[0].subagentAttentionCount, 1)
        XCTAssertEqual(items[2].subagentCount, 0)
        XCTAssertEqual(items[3].attentionMarkedAt, attentionTime)
        XCTAssertEqual(items[3].statusLabel, "Failed")
        XCTAssertTrue(AgentSessionSearchMatcher.matches(
            query: AgentSessionSearchQuery.parse("workspace opus"),
            fields: items[0].searchFields
        ))
        XCTAssertTrue(AgentSessionSearchMatcher.matches(
            query: AgentSessionSearchQuery.parse("failed"),
            fields: items[3].searchFields
        ))
    }

    func testAllAgentsSortingCapAndSearchCorpusAreDeterministic() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let now = Date(timeIntervalSince1970: 10000)
        let stale = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Stale",
            activityDate: now.addingTimeInterval(-25 * 60 * 60),
            runState: .idle
        )
        let recent = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Recent",
            activityDate: now.addingTimeInterval(-60),
            runState: .idle
        )
        let activeOlder = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Active older",
            activityDate: now.addingTimeInterval(-90),
            runState: .waitingForApproval
        )
        let attentionNewest = item(
            tabID: UUID(),
            workspaceID: workspaceID,
            title: "Attention newest",
            activityDate: now.addingTimeInterval(-3 * 60 * 60),
            runState: .idle,
            attentionState: .failed,
            attentionMarkedAt: now
        )
        let filler = (0 ..< 60).map { index in
            item(
                tabID: UUID(),
                workspaceID: workspaceID,
                title: "Searchable older session \(index)",
                activityDate: now.addingTimeInterval(TimeInterval(-120 - index)),
                runState: .idle
            )
        }
        let allItems = [stale, recent, activeOlder, attentionNewest] + filler

        let sorted = AgentNavigationHUDSnapshotBuilder.allAgentsSorted(allItems, now: now)
        let capped = AgentNavigationHUDSnapshotBuilder.allAgentsSortedAndCapped(allItems, now: now)

        XCTAssertGreaterThan(sorted.count, AgentNavigationHUDSnapshotBuilder.allAgentsCap)
        XCTAssertTrue(sorted.contains { $0.title == "Searchable older session 59" })
        XCTAssertEqual(capped.count, AgentNavigationHUDSnapshotBuilder.allAgentsCap)
        XCTAssertEqual(capped.first?.title, "Attention newest")
        XCTAssertTrue(capped.contains { $0.title == "Recent" })
        XCTAssertTrue(capped.contains { $0.title == "Active older" })
        XCTAssertFalse(capped.contains { $0.title == "Stale" })
    }

    func testSearchTokensSplitWhitespaceAndPreserveQuotedPhrases() {
        XCTAssertEqual(AgentSessionSearchQuery.tokenize("sidebar running"), ["sidebar", "running"])
        XCTAssertEqual(AgentSessionSearchQuery.tokenize("workspace \"review branch\""), ["workspace", "review branch"])
        XCTAssertEqual(AgentSessionSearchQuery.tokenize("  \"unterminated phrase  "), ["unterminated phrase"])
    }

    func testSharedSearchMatcherMatchesMetadataAndQuotedPhrases() {
        let fields = AgentSessionSearchFields(
            title: "PR cleanup: diagnostics minimization",
            primary: ["Claude Opus", "Window One"],
            status: ["Waiting for approval"],
            worktree: ["wt/agent-search-command-k"],
            path: ["https://github.com/repoprompt/repoprompt-ce/pull/123"],
            identifier: ["ABCDEF-1234"]
        )

        XCTAssertTrue(AgentSessionSearchMatcher.matches(
            query: AgentSessionSearchQuery.parse("approval \"Claude Opus\""),
            fields: fields
        ))
        XCTAssertTrue(AgentSessionSearchMatcher.matches(
            query: AgentSessionSearchQuery.parse("pull/123"),
            fields: fields
        ))
        XCTAssertFalse(AgentSessionSearchMatcher.matches(
            query: AgentSessionSearchQuery.parse("approval unrelated"),
            fields: fields
        ))
    }

    func testSharedSearchMatcherRanksTitleAbovePathContains() throws {
        let query = AgentSessionSearchQuery.parse("cleanup")
        let titleScore = try XCTUnwrap(AgentSessionSearchMatcher.score(
            query: query,
            fields: AgentSessionSearchFields(title: "Cleanup diagnostics", path: ["/tmp/other"])
        ))
        let pathScore = try XCTUnwrap(AgentSessionSearchMatcher.score(
            query: query,
            fields: AgentSessionSearchFields(title: "Other", path: ["/tmp/cleanup-diagnostics"])
        ))

        XCTAssertGreaterThan(titleScore, pathScore)
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
            threadActivityDate: nil,
            searchFields: AgentSessionSearchFields(
                title: title,
                primary: ["Claude", "Opus"],
                worktree: ["wt/search"],
                secondary: [depth > 0 ? "sub-agent" : nil],
                identifier: [tabID.uuidString]
            )
        )
    }

    private func item(
        tabID: UUID,
        workspaceID: UUID,
        title: String,
        activityDate: Date,
        runState: AgentSessionRunState?,
        attentionState: AgentSessionRunState? = nil,
        attentionMarkedAt: Date? = nil
    ) -> AgentNavigationHUDItem {
        AgentNavigationHUDItem(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: tabID,
            title: title,
            workspaceTitle: "Workspace",
            windowTitle: "Window",
            parentSessionID: nil,
            depth: 0,
            subagentCount: 0,
            subagentAttentionCount: 0,
            isActiveTab: false,
            runState: runState,
            attentionState: attentionState,
            attentionMarkedAt: attentionMarkedAt,
            activityDate: activityDate,
            worktree: nil,
            worktreeLabel: nil,
            mergeAttention: nil,
            mergeLabel: nil,
            isMCPControlled: false,
            isArchived: false,
            searchFields: AgentSessionSearchFields(
                title: title,
                primary: ["Workspace", "Window"],
                status: [runState.map { String(describing: $0) }],
                secondary: [attentionState.map { String(describing: $0) }],
                identifier: [tabID.uuidString, workspaceID.uuidString]
            )
        )
    }
}
