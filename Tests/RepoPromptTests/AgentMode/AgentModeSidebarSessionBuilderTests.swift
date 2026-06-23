@testable import RepoPrompt
import XCTest

@MainActor
final class AgentModeSidebarSessionBuilderTests: XCTestCase {
    func testRestoredOnlyOrdersSiblingsByNewestActivityAndPreservesHierarchy() {
        let parentTabID = id(1)
        let olderChildTabID = id(2)
        let newerChildTabID = id(3)
        let grandchildTabID = id(4)
        let parentSessionID = id(101)
        let olderChildSessionID = id(102)
        let newerChildSessionID = id(103)
        let grandchildSessionID = id(104)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(olderChildTabID, sessionID: olderChildSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID),
            tab(grandchildTabID, sessionID: grandchildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                olderChildSessionID,
                tabID: olderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(40)
            ),
            entry(
                grandchildSessionID,
                tabID: grandchildTabID,
                parentSessionID: newerChildSessionID,
                lastUserMessageAt: date(30)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, newerChildTabID, grandchildTabID, olderChildTabID])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1])
    }

    func testSiblingOrderIsHydrationInvariant() {
        let parentTabID = id(10)
        let olderChildTabID = id(11)
        let newerChildTabID = id(12)
        let parentSessionID = id(110)
        let olderChildSessionID = id(111)
        let newerChildSessionID = id(112)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(olderChildTabID, sessionID: olderChildSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID)
        ]
        let entries = [
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                olderChildSessionID,
                tabID: olderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(30)
            )
        ]
        let index = sessionIndex(entries)
        let expectedOrder = [parentTabID, newerChildTabID, olderChildTabID]
        let restoredRows = build(tabs: tabs, sessionIndex: index)
        let partiallyHydratedRows = build(
            tabs: tabs,
            sessions: [
                newerChildTabID: liveSession(
                    tabID: newerChildTabID,
                    sessionID: newerChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(30)
                )
            ],
            sessionIndex: index
        )
        let fullyHydratedRows = build(
            tabs: tabs,
            sessions: [
                parentTabID: liveSession(
                    tabID: parentTabID,
                    sessionID: parentSessionID,
                    lastUserMessageAt: date(10)
                ),
                olderChildTabID: liveSession(
                    tabID: olderChildTabID,
                    sessionID: olderChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(20)
                ),
                newerChildTabID: liveSession(
                    tabID: newerChildTabID,
                    sessionID: newerChildSessionID,
                    parentSessionID: parentSessionID,
                    lastUserMessageAt: date(30)
                )
            ],
            sessionIndex: index
        )

        XCTAssertEqual(restoredRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(partiallyHydratedRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(fullyHydratedRows.map(\.tabID), expectedOrder)
        XCTAssertEqual(restoredRows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(partiallyHydratedRows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(fullyHydratedRows.map(\.depth), [0, 1, 1])
    }

    func testLiveContinuationWinsOverStalePersistedDates() throws {
        let parentTabID = id(20)
        let continuedChildTabID = id(21)
        let otherChildTabID = id(22)
        let parentSessionID = id(120)
        let continuedChildSessionID = id(121)
        let otherChildSessionID = id(122)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(continuedChildTabID, sessionID: continuedChildSessionID),
            tab(otherChildTabID, sessionID: otherChildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                continuedChildSessionID,
                tabID: continuedChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(100),
                savedAt: date(1000)
            ),
            entry(
                otherChildSessionID,
                tabID: otherChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(200)
            )
        ])
        let continuedSession = liveSession(
            tabID: continuedChildTabID,
            sessionID: continuedChildSessionID,
            parentSessionID: parentSessionID,
            lastUserMessageAt: date(300)
        )

        let rows = build(
            tabs: tabs,
            sessions: [continuedChildTabID: continuedSession],
            sessionIndex: index
        )

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, continuedChildTabID, otherChildTabID])
        let continuedRow = try XCTUnwrap(rows.first(where: { $0.tabID == continuedChildTabID }))
        XCTAssertEqual(continuedRow.lastUserMessageAt, date(300))
        XCTAssertEqual(continuedRow.activityDate, date(300))
    }

    func testUnhydratedPersistedRowUsesIndexSavedAtInsteadOfTabLastModified() throws {
        let staleTabID = id(23)
        let newerTabID = id(24)
        let staleSessionID = id(123)
        let newerSessionID = id(124)
        let tabs = [
            tab(staleTabID, sessionID: staleSessionID, lastModified: date(1000)),
            tab(newerTabID, sessionID: newerSessionID, lastModified: date(1))
        ]
        let index = sessionIndex([
            entry(
                staleSessionID,
                tabID: staleTabID,
                lastUserMessageAt: nil,
                savedAt: date(100)
            ),
            entry(
                newerSessionID,
                tabID: newerTabID,
                lastUserMessageAt: nil,
                savedAt: date(200)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [newerTabID, staleTabID])
        XCTAssertEqual(try row(for: staleTabID, in: rows).activityDate, date(100))
    }

    func testSiblingOrderFollowsActivityDates() throws {
        let parentTabID = id(30)
        let newerChildTabID = id(31)
        let activeOlderChildTabID = id(32)
        let parentSessionID = id(130)
        let newerChildSessionID = id(131)
        let activeOlderChildSessionID = id(132)
        let tabs = [
            tab(parentTabID, sessionID: parentSessionID),
            tab(newerChildTabID, sessionID: newerChildSessionID),
            tab(activeOlderChildTabID, sessionID: activeOlderChildSessionID)
        ]
        let index = sessionIndex([
            entry(parentSessionID, tabID: parentTabID, lastUserMessageAt: date(10)),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(300)
            ),
            entry(
                activeOlderChildSessionID,
                tabID: activeOlderChildTabID,
                parentSessionID: parentSessionID,
                lastUserMessageAt: date(100)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [parentTabID, newerChildTabID, activeOlderChildTabID])
        XCTAssertEqual(
            try XCTUnwrap(rows.first(where: { $0.tabID == activeOlderChildTabID })).activityDate,
            date(100)
        )
        XCTAssertEqual(
            try XCTUnwrap(rows.first(where: { $0.tabID == newerChildTabID })).activityDate,
            date(300)
        )
    }

    func testPinnedChildPrecedesNewerUnpinnedSibling() {
        let rootTabID = id(33)
        let pinnedChildTabID = id(34)
        let newerChildTabID = id(35)
        let rootSessionID = id(133)
        let pinnedChildSessionID = id(134)
        let newerChildSessionID = id(135)
        let tabs = [
            tab(rootTabID, sessionID: rootSessionID),
            tab(pinnedChildTabID, sessionID: pinnedChildSessionID, isPinned: true),
            tab(newerChildTabID, sessionID: newerChildSessionID)
        ]
        let index = sessionIndex([
            entry(rootSessionID, tabID: rootTabID, lastUserMessageAt: date(1)),
            entry(
                pinnedChildSessionID,
                tabID: pinnedChildTabID,
                parentSessionID: rootSessionID,
                lastUserMessageAt: date(10)
            ),
            entry(
                newerChildSessionID,
                tabID: newerChildTabID,
                parentSessionID: rootSessionID,
                lastUserMessageAt: date(100)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.map(\.tabID), [rootTabID, pinnedChildTabID, newerChildTabID])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }

    func testPinnedDescendantElevatesContainingRootSubtree() {
        let pinnedSubtreeRootTabID = id(36)
        let branchTabID = id(37)
        let pinnedGrandchildTabID = id(38)
        let newerRootTabID = id(39)
        let pinnedSubtreeRootSessionID = id(136)
        let branchSessionID = id(137)
        let pinnedGrandchildSessionID = id(138)
        let newerRootSessionID = id(139)
        let tabs = [
            tab(pinnedSubtreeRootTabID, sessionID: pinnedSubtreeRootSessionID),
            tab(branchTabID, sessionID: branchSessionID),
            tab(pinnedGrandchildTabID, sessionID: pinnedGrandchildSessionID, isPinned: true),
            tab(newerRootTabID, sessionID: newerRootSessionID)
        ]
        let index = sessionIndex([
            entry(
                pinnedSubtreeRootSessionID,
                tabID: pinnedSubtreeRootTabID,
                lastUserMessageAt: date(1)
            ),
            entry(
                branchSessionID,
                tabID: branchTabID,
                parentSessionID: pinnedSubtreeRootSessionID,
                lastUserMessageAt: date(5)
            ),
            entry(
                pinnedGrandchildSessionID,
                tabID: pinnedGrandchildTabID,
                parentSessionID: branchSessionID,
                lastUserMessageAt: date(10)
            ),
            entry(newerRootSessionID, tabID: newerRootTabID, lastUserMessageAt: date(100))
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(
            rows.map(\.tabID),
            [pinnedSubtreeRootTabID, branchTabID, pinnedGrandchildTabID, newerRootTabID]
        )
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0])
    }

    func testPinnedRootsAndRootSubtreeRecencyRemainStable() {
        let pinnedOlderSubtreeRootTabID = id(40)
        let pinnedOlderSubtreeChildTabID = id(41)
        let pinnedNewerSubtreeRootTabID = id(42)
        let pinnedNewerSubtreeChildTabID = id(43)
        let freshRootTabID = id(44)
        let freshChildTabID = id(45)
        let mediumRootTabID = id(46)
        let pinnedOlderSubtreeRootSessionID = id(140)
        let pinnedOlderSubtreeChildSessionID = id(141)
        let pinnedNewerSubtreeRootSessionID = id(142)
        let pinnedNewerSubtreeChildSessionID = id(143)
        let freshRootSessionID = id(144)
        let freshChildSessionID = id(145)
        let mediumRootSessionID = id(146)
        let tabs = [
            tab(pinnedOlderSubtreeRootTabID, sessionID: pinnedOlderSubtreeRootSessionID, isPinned: true),
            tab(pinnedOlderSubtreeChildTabID, sessionID: pinnedOlderSubtreeChildSessionID),
            tab(pinnedNewerSubtreeRootTabID, sessionID: pinnedNewerSubtreeRootSessionID, isPinned: true),
            tab(pinnedNewerSubtreeChildTabID, sessionID: pinnedNewerSubtreeChildSessionID),
            tab(freshRootTabID, sessionID: freshRootSessionID),
            tab(freshChildTabID, sessionID: freshChildSessionID),
            tab(mediumRootTabID, sessionID: mediumRootSessionID)
        ]
        let index = sessionIndex([
            entry(
                pinnedOlderSubtreeRootSessionID,
                tabID: pinnedOlderSubtreeRootTabID,
                lastUserMessageAt: date(250)
            ),
            entry(
                pinnedOlderSubtreeChildSessionID,
                tabID: pinnedOlderSubtreeChildTabID,
                parentSessionID: pinnedOlderSubtreeRootSessionID,
                lastUserMessageAt: date(20)
            ),
            entry(
                pinnedNewerSubtreeRootSessionID,
                tabID: pinnedNewerSubtreeRootTabID,
                lastUserMessageAt: date(10)
            ),
            entry(
                pinnedNewerSubtreeChildSessionID,
                tabID: pinnedNewerSubtreeChildTabID,
                parentSessionID: pinnedNewerSubtreeRootSessionID,
                lastUserMessageAt: date(280)
            ),
            entry(freshRootSessionID, tabID: freshRootTabID, lastUserMessageAt: date(5)),
            entry(
                freshChildSessionID,
                tabID: freshChildTabID,
                parentSessionID: freshRootSessionID,
                lastUserMessageAt: date(300)
            ),
            entry(mediumRootSessionID, tabID: mediumRootTabID, lastUserMessageAt: date(200))
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(
            rows.map(\.tabID),
            [
                pinnedNewerSubtreeRootTabID,
                pinnedNewerSubtreeChildTabID,
                pinnedOlderSubtreeRootTabID,
                pinnedOlderSubtreeChildTabID,
                freshRootTabID,
                freshChildTabID,
                mediumRootTabID
            ]
        )
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1, 0, 1, 0])
    }

    func testCyclesAndMissingParentsDegradeToRootWithoutBreakingValidHierarchy() throws {
        let validRootTabID = id(50)
        let validChildTabID = id(51)
        let cycleATabID = id(52)
        let cycleBTabID = id(53)
        let missingParentTabID = id(54)
        let validRootSessionID = id(150)
        let validChildSessionID = id(151)
        let cycleASessionID = id(152)
        let cycleBSessionID = id(153)
        let missingParentSessionID = id(154)
        let tabs = [
            tab(validRootTabID, sessionID: validRootSessionID),
            tab(validChildTabID, sessionID: validChildSessionID),
            tab(cycleATabID, sessionID: cycleASessionID),
            tab(cycleBTabID, sessionID: cycleBSessionID),
            tab(missingParentTabID, sessionID: missingParentSessionID)
        ]
        let index = sessionIndex([
            entry(validRootSessionID, tabID: validRootTabID, lastUserMessageAt: date(10)),
            entry(
                validChildSessionID,
                tabID: validChildTabID,
                parentSessionID: validRootSessionID,
                lastUserMessageAt: date(200)
            ),
            entry(
                cycleASessionID,
                tabID: cycleATabID,
                parentSessionID: cycleBSessionID,
                lastUserMessageAt: date(500)
            ),
            entry(
                cycleBSessionID,
                tabID: cycleBTabID,
                parentSessionID: cycleASessionID,
                lastUserMessageAt: date(400)
            ),
            entry(
                missingParentSessionID,
                tabID: missingParentTabID,
                parentSessionID: id(999),
                lastUserMessageAt: date(300)
            )
        ])

        let rows = build(tabs: tabs, sessionIndex: index)

        XCTAssertEqual(rows.count, tabs.count)
        XCTAssertEqual(try row(for: cycleATabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: cycleBTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: missingParentTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: validRootTabID, in: rows).depth, 0)
        XCTAssertEqual(try row(for: validChildTabID, in: rows).depth, 1)
        XCTAssertLessThan(
            try XCTUnwrap(rows.firstIndex(where: { $0.tabID == validRootTabID })),
            try XCTUnwrap(rows.firstIndex(where: { $0.tabID == validChildTabID }))
        )
    }

    private func build(
        tabs: [ComposeTabState],
        sessions: [UUID: AgentModeViewModel.TabSession] = [:],
        sessionIndex: [UUID: AgentSessionIndexEntry]
    ) -> [AgentModeViewModel.SidebarSession] {
        AgentModeSidebarSessionBuilder(
            allTabs: tabs,
            linkedTabs: tabs,
            sessions: sessions,
            authoritativeSessionIDByTabID: Dictionary(
                uniqueKeysWithValues: tabs.compactMap { tab in
                    tab.activeAgentSessionID.map { (tab.id, $0) }
                }
            ),
            sessionIndex: sessionIndex,
            sessionListSortDates: [:],
            sessionListCacheReady: true,
            sidebarRestoreFrozenOrderByTabID: [:],
            mcpControlledTabIDs: []
        ).build()
    }

    private func liveSession(
        tabID: UUID,
        sessionID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date
    ) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.testInstallPersistentSessionBinding(sessionID: sessionID)
        session.parentSessionID = parentSessionID
        session.hasLoadedPersistedState = true
        session.lastUserMessageAt = lastUserMessageAt
        session.lastActivityAt = lastUserMessageAt
        return session
    }

    private func tab(
        _ tabID: UUID,
        sessionID: UUID,
        isPinned: Bool = false,
        lastModified: Date? = nil
    ) -> ComposeTabState {
        ComposeTabState(
            id: tabID,
            name: "Tab \(tabID.uuidString.suffix(4))",
            lastModified: lastModified ?? date(1),
            isPinned: isPinned,
            activeAgentSessionID: sessionID
        )
    }

    private func entry(
        _ sessionID: UUID,
        tabID: UUID,
        parentSessionID: UUID? = nil,
        lastUserMessageAt: Date?,
        savedAt: Date? = nil
    ) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Session \(sessionID.uuidString.suffix(4))",
            lastUserMessageAt: lastUserMessageAt,
            savedAt: savedAt ?? lastUserMessageAt ?? date(1),
            lastRunStateRaw: nil,
            itemCount: lastUserMessageAt == nil ? 0 : 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func sessionIndex(_ entries: [AgentSessionIndexEntry]) -> [UUID: AgentSessionIndexEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private func row(
        for tabID: UUID,
        in rows: [AgentModeViewModel.SidebarSession]
    ) throws -> AgentModeViewModel.SidebarSession {
        try XCTUnwrap(rows.first(where: { $0.tabID == tabID }))
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
