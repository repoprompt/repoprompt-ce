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
            restoreBaseline: nil,
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

/// W1 characterized the pre-change frozen-map policy through these fixtures and real consumers: the
/// owner install jumped to raw persisted-array order (stage rows 2,3,4,1 → 1,2,3,4), batches relabelled
/// headings under the frozen order (stages 3, 4a, 6), index completion released before selected
/// hydration (1,3,4,2) and the final projection moved again (1,2,3,4); one uncovered bound row disabled
/// freezing entirely. The expectations below are the deliberately updated baseline contract (§5.4).
@MainActor
final class AgentSidebarRestoreCharacterizationTests: XCTestCase {
    private typealias Row = AgentModeViewModel.SidebarSession

    // D = 2026-09-29 12:00:00 UTC. All dates below are minutes relative to D.
    private let day = Date(timeIntervalSince1970: 1_790_683_200)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    private var owner: AgentModeViewModel.SessionIndexOwner {
        AgentModeViewModel.SessionIndexOwner(workspaceID: id(900), activationEpoch: 1)
    }

    func testSevenRestoreStagesKeepBaselinePositionsAndHeadingsUntilRelease() {
        let tabs = baseTabs()
        let baseline = makeBaseline(tabs)
        let selected = entry(2, interaction: -7200)
        let parent = entry(1, interaction: 0)
        // T3 remains index-less throughout this base scenario.
        let full = [parent, selected]
        let stableGroups = "2:today:2;3:yesterday:3;4:previous:4;1:previous:1"
        let stableSections = "2:today:2;3:yesterday:3;4:previous:4,1"
        // Before owner installation the owner-validated inputs are empty (unchanged settled policy).
        assertProjection(
            "1 pre-owner",
            build(tabs),
            rows: "2/102/-/0/0/-/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: stableGroups,
            sections: stableSections
        )
        // The metadata-only baseline reproduces the pre-owner order: no raw-array jump at install.
        assertProjection(
            "2 installed owner empty index",
            build(tabs, baseline: baseline),
            rows: "2/102/-/0/0/-/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: stableGroups,
            sections: stableSections
        )
        // Non-positional metadata keeps arriving; placement and headings do not move.
        assertProjection(
            "3 prioritized selected T2",
            build(tabs, entries: [selected], baseline: baseline),
            rows: "2/102/-/0/-7200/-7200/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: stableGroups,
            sections: stableSections
        )
        assertProjection(
            "4a first full batch parent",
            build(tabs, entries: [selected, parent], baseline: baseline),
            rows: "2/102/-/0/-7200/-7200/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/0/0/-",
            groups: stableGroups,
            sections: stableSections
        )
        assertProjection(
            "4b subsequent full batch duplicate metadata",
            build(tabs, entries: full, baseline: baseline),
            rows: "2/102/-/0/-7200/-7200/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/0/0/-",
            groups: stableGroups,
            sections: stableSections
        )
        let live = hydratedSelectedSession()
        assertProjection(
            "6 selected hydration before index complete",
            build(tabs, entries: [selected], sessions: [id(2): live], baseline: baseline),
            rows: "2/102/-/0/-1440/-1440/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: stableGroups,
            sections: stableSections
        )
        // One release: both completion orders consume the same final authoritative inputs.
        assertProjection(
            "7 final newer selected transcript",
            build(tabs, entries: full, sessions: [id(2): live]),
            rows: "1/101/-/0/0/0/-;2/102/-/0/-1440/-1440/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-",
            groups: "1:today:1;2:yesterday:2;3:yesterday:3;4:previous:4",
            sections: "1:today:1;2:yesterday:2,3;4:previous:4"
        )
    }

    func testCapturedBucketsSurviveMidnightAndCalendarChangeDuringOneRestore() {
        let tabs = baseTabs()
        let rows = build(tabs, entries: [entry(1, interaction: 0)], baseline: makeBaseline(tabs))
        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: -6 * 3600)!
        for (now, calendar) in [(day.addingTimeInterval(86400), calendar), (day, shifted)] {
            let sections = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: calendar)
            XCTAssertEqual(
                sections.map { "\(label($0.groups.first?.id)):\($0.bucket)" }.joined(separator: ";"),
                "2:today;3:yesterday;4:previous"
            )
        }
    }

    func testUncoveredRowFollowsCoveredPeersWithoutDisablingStability() {
        let tabs = baseTabs()
        // T3 is missing from the baseline; previously one missing bound row disabled freezing globally.
        let baseline = makeBaseline(tabs.filter { $0.id != id(3) })
        assertProjection(
            "missing T3 coverage",
            build(tabs, entries: [entry(2, interaction: -7200), entry(3, interaction: 0)], baseline: baseline),
            rows: "2/102/-/0/-7200/-7200/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-;3/103/-/0/0/0/-",
            groups: "2:today:2;4:previous:4;1:previous:1;3:yesterday:3",
            sections: "2:today:2;4:previous:4,1;3:yesterday:3"
        )
        // Admission appends without renumbering; a reappearing row keeps its reservation.
        var admitted = baseline
        XCTAssertTrue(admitted.admit([tab(3, modified: -1440), tab(2, modified: 0)]))
        XCTAssertFalse(admitted.admit([tab(3, modified: 0)]))
        XCTAssertEqual(admitted.entries[id(3)]?.ordinal, 3)
        XCTAssertEqual(admitted.entries[id(2)]?.ordinal, baseline.entries[id(2)]?.ordinal)
    }

    func testStashedTabRetainsCoverageWhenItBecomesActive() {
        let tabs = baseTabs()
        let stashed = StashedTab(id: id(500), tab: tab(5, modified: 0), stashedAt: date(-60))
        let all = tabs + [stashed.tab]
        let baseline = makeBaseline(all)
        assertProjection(
            "stashed not active",
            build(all, visible: tabs, baseline: baseline),
            rows: "2/102/-/0/0/-/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: "2:today:2;3:yesterday:3;4:previous:4;1:previous:1",
            sections: "2:today:2;3:yesterday:3;4:previous:4,1"
        )
        assertProjection(
            "stashed becomes active",
            build(all, entries: [entry(5, interaction: -7200)], baseline: baseline),
            rows: "2/102/-/0/0/-/-;5/105/-/0/-7200/-7200/-;3/103/-/0/-1440/-/-;4/-/-/0/-2880/-/-;1/101/-/0/-4320/-/-",
            groups: "2:today:2;5:today:5;3:yesterday:3;4:previous:4;1:previous:1",
            sections: "2:today:2,5;3:yesterday:3;4:previous:4,1"
        )
    }

    func testManualAndLegacyPinsKeepPinRulesWithBaselineOrdinalWithinPeers() {
        let tabs = [
            tab(5, modified: -4320, pinned: true, order: 1),
            tab(6, modified: -7200, pinned: true, order: 0),
            tab(7, modified: -60, pinned: true),
            tab(8, modified: -1440, pinned: true),
            tab(9, modified: 0)
        ]
        let newerT8 = [entry(8, interaction: 0)]
        assertProjection(
            "settled legacy recency reorders",
            build(tabs, entries: newerT8),
            rows: "6/106/-/0/-7200/-/-;5/105/-/0/-4320/-/-;8/108/-/0/0/0/-;7/107/-/0/-60/-/-;9/109/-/0/0/-/-",
            groups: "6:previous:6;5:previous:5;8:today:8;7:today:7;9:today:9",
            sections: "6:previous:6,5;8:today:8,7,9"
        )
        let baseline = makeBaseline(tabs)
        assertProjection(
            "baseline legacy pins keep captured ordinal and bucket",
            build(tabs, entries: newerT8, baseline: baseline),
            rows: "6/106/-/0/-7200/-/-;5/105/-/0/-4320/-/-;7/107/-/0/-60/-/-;8/108/-/0/0/0/-;9/109/-/0/0/-/-",
            groups: "6:previous:6;5:previous:5;7:today:7;8:yesterday:8;9:today:9",
            sections: "6:previous:6,5;7:today:7;8:yesterday:8;9:today:9"
        )
        // An uncovered pinned row stays in its pin group, after covered legacy peers.
        let withNewPin = tabs + [tab(10, modified: 0, pinned: true)]
        XCTAssertEqual(
            build(withNewPin, baseline: baseline).map { label($0.id) },
            ["6", "5", "7", "8", "10", "9"]
        )
    }

    func testParentChildArrivalPermutationsStayFlatUntilReleaseThenThread() {
        let tabs = [tab(1, modified: -4320), tab(3, modified: -1440)]
        let parent = entry(1, interaction: -4320)
        let child = entry(3, interaction: -1440, parent: 101)
        let baseline = makeBaseline(tabs)
        for entries in [[parent], [child], [parent, child], [child, parent]] {
            let rows = build(tabs, entries: entries, baseline: baseline)
            XCTAssertEqual(rows.map { label($0.id) }, ["3", "1"])
            XCTAssertEqual(rows.map(\.depth), [0, 0], "flat restore layout retains parent metadata only")
        }
        XCTAssertEqual(build(tabs, entries: [child], baseline: baseline).first?.parentSessionID, id(101))
        for entries in [[parent, child], [child, parent]] {
            assertProjection(
                "both metadata settled",
                build(tabs, entries: entries),
                rows: "1/101/-/0/-4320/-4320/-;3/103/101/1/-1440/-1440/-",
                groups: "1:yesterday:1,3",
                sections: "1:yesterday:1,3"
            )
        }
        let malformed = [tab(5, modified: 0), tab(6, modified: -1440), tab(7, modified: -2880)]
        let entries = [entry(5, interaction: 0, parent: 999), entry(6, interaction: -1440, parent: 107), entry(7, interaction: -2880, parent: 106)]
        assertProjection(
            "missing parent and cycle settled",
            build(malformed, entries: entries),
            rows: "5/105/999/0/0/0/-;6/106/107/0/-1440/-1440/-;7/107/106/0/-2880/-2880/-",
            groups: "5:today:5;6:yesterday:6;7:previous:7",
            sections: "5:today:5;6:yesterday:6;7:previous:7"
        )
        assertProjection(
            "cycle under baseline stays flat",
            build(malformed, entries: entries, baseline: makeBaseline(malformed)),
            rows: "5/105/999/0/0/0/-;6/106/107/0/-1440/-1440/-;7/107/106/0/-2880/-2880/-",
            groups: "5:today:5;6:yesterday:6;7:previous:7",
            sections: "5:today:5;6:yesterday:6;7:previous:7"
        )
    }

    func testCollapsePreferenceUsesRealFilteredRowsAndPreservesThreadDate() {
        let viewModel = makeViewModel()
        let tabs = [tab(1, modified: -4320), tab(3, modified: -1440)]
        let entries = [entry(1, interaction: -4320), entry(3, interaction: -1440, parent: 101)]
        let workspace = WorkspaceModel(id: id(900), dateModified: day, name: "W1", repoPaths: [], lastUsed: day, composeTabs: tabs)
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        viewModel.test_installSessionIndexSnapshot(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), owner: owner, latestOwner: owner, activeWorkspace: workspace)
        let key = AgentSidebarThreadKey.session(id(101))
        viewModel.ui.sessionSidebar.setThreadCollapsed(true, for: key)
        let collapsed = viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: "")
        assertProjection(
            "collapsed filtered consumer",
            collapsed,
            rows: "1/101/-/0/-4320/-4320/-1440",
            groups: "1:yesterday:1",
            sections: "1:yesterday:1"
        )
        XCTAssertEqual(collapsed.map(\.hiddenThreadDescendantCount), [1])
        XCTAssertEqual(collapsed.map(\.isThreadCollapsed), [true])
        assertProjection(
            "selected descendant prevents collapse",
            viewModel.filteredSidebarSessions(for: tabs, currentTabID: id(3), searchText: ""),
            rows: "1/101/-/0/-4320/-4320/-1440;3/103/101/1/-1440/-1440/-1440",
            groups: "1:yesterday:1,3",
            sections: "1:yesterday:1,3"
        )
        viewModel.ui.sessionSidebar.setThreadCollapsed(false, for: key)
        assertProjection(
            "explicit expansion",
            viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: ""),
            rows: "1/101/-/0/-4320/-4320/-1440;3/103/101/1/-1440/-1440/-1440",
            groups: "1:yesterday:1,3",
            sections: "1:yesterday:1,3"
        )
    }

    func testFirstProjectionAppliesEffectiveDefaultCollapseBeforeSeedingTask() {
        let viewModel = makeViewModel()
        // T1 → T3 → T5: T3 is a nested thread parent, eligible for default collapse.
        let tabs = [tab(1, modified: -4320), tab(3, modified: -1440), tab(5, modified: -60)]
        let entries = [entry(1, interaction: -4320), entry(3, interaction: -1440, parent: 101), entry(5, interaction: -60, parent: 103)]
        let workspace = WorkspaceModel(id: id(900), dateModified: day, name: "W1", repoPaths: [], lastUsed: day, composeTabs: tabs)
        let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
        viewModel.test_installSessionIndexSnapshot(Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }), owner: owner, latestOwner: owner, activeWorkspace: workspace)
        let defaultKeys = viewModel.defaultCollapsedSidebarThreadKeys(for: tabs, searchText: "")
        XCTAssertEqual(defaultKeys, [.session(id(103))])
        let firstFrame = viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: "")
        XCTAssertEqual(firstFrame.map { label($0.id) }, ["1", "3"], "no expanded frame before the seeding task")
        XCTAssertEqual(firstFrame.map(\.isThreadCollapsed), [false, true])
        // The view's later seeding task only records the handled set; rows cannot move.
        viewModel.seedDefaultCollapsedSidebarThreads(defaultKeys)
        XCTAssertEqual(viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: ""), firstFrame)
        viewModel.ui.sessionSidebar.setThreadCollapsed(false, for: .session(id(103)))
        XCTAssertEqual(
            viewModel.filteredSidebarSessions(for: tabs, currentTabID: nil, searchText: "").map { label($0.id) },
            ["1", "3", "5"],
            "explicit expansion remains respected"
        )
    }

    /// Serializers only: no sorting, date-bucket, threading, or collapse policy.
    /// Section UUIDs encode bucket/ordinal; snapshots label the first rendered thread group instead.
    private func assertProjection(
        _ stage: String,
        _ rows: [Row],
        rows expectedRows: String,
        groups expectedGroups: String,
        sections expectedSections: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rowText = rows.map { row in
            [label(row.id), label(row.sessionID), label(row.parentSessionID), String(row.depth), minutes(row.activityDate), minutes(row.lastUserMessageAt), minutes(row.threadActivityDate)].joined(separator: "/")
        }.joined(separator: ";")
        let groups = AgentSidebarDateSectionBuilder.activeGroups(for: rows, now: day, calendar: calendar)
        let groupText = groups.map { "\(label($0.id)):\($0.bucket):\($0.rows.map { label($0.id) }.joined(separator: ","))" }.joined(separator: ";")
        let sections = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: day, calendar: calendar)
        let sectionText = sections.map { "\(label($0.groups.first?.id)):\($0.bucket):\($0.groups.flatMap(\.rows).map { label($0.id) }.joined(separator: ","))" }.joined(separator: ";")
        print("SIDEBAR_RESTORE_STAGE | \(stage) | \(rowText) | \(groupText) | \(sectionText)")
        XCTAssertEqual(rowText, expectedRows, stage, file: file, line: line)
        XCTAssertEqual(groupText, expectedGroups, stage, file: file, line: line)
        XCTAssertEqual(sectionText, expectedSections, stage, file: file, line: line)
    }

    private func build(
        _ allTabs: [ComposeTabState],
        visible: [ComposeTabState]? = nil,
        entries: [AgentSessionIndexEntry] = [],
        sessions: [UUID: AgentModeViewModel.TabSession] = [:],
        baseline: AgentSidebarRestoreBaseline? = nil
    ) -> [Row] {
        AgentModeSidebarSessionBuilder(
            allTabs: allTabs,
            rowTabs: visible ?? allTabs,
            sessions: sessions,
            authoritativeSessionIDByTabID: Dictionary(uniqueKeysWithValues: allTabs.compactMap { tab in tab.activeAgentSessionID.map { (tab.id, $0) } }),
            sessionIndex: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            sessionListSortDates: [:],
            restoreBaseline: baseline,
            mcpControlledTabIDs: []
        ).build()
    }

    /// Production capture seam: metadata-only order and buckets at D.
    private func makeBaseline(_ persistedTabs: [ComposeTabState]) -> AgentSidebarRestoreBaseline {
        AgentModeSidebarSessionBuilder.makeRestoreBaseline(for: persistedTabs, owner: owner, now: day, calendar: calendar)
    }

    private func baseTabs() -> [ComposeTabState] {
        [tab(1, modified: -4320), tab(2, modified: 0), tab(3, modified: -1440), tab(4, modified: -2880, bound: false)]
    }

    private func tab(_ number: Int, modified: Int, bound: Bool = true, pinned: Bool = false, order: Int? = nil) -> ComposeTabState {
        ComposeTabState(id: id(number), name: "T\(number)", lastModified: date(modified), isPinned: pinned, pinnedOrder: order, activeAgentSessionID: bound ? id(100 + number) : nil)
    }

    private func entry(_ number: Int, interaction: Int, parent: Int? = nil) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id(100 + number), tabID: id(number), name: "T\(number)",
            lastUserMessageAt: date(interaction), savedAt: date(interaction), lastRunStateRaw: nil,
            itemCount: 1, agentKindRaw: nil, agentModelRaw: nil, agentReasoningEffortRaw: nil,
            autoEditEnabled: false, parentSessionID: parent.map(id), hasUnknownConversationContent: false,
            isMCPOriginated: false, worktreeBindingSummaries: [], activeWorktreeMergeSummaries: []
        )
    }

    private func hydratedSelectedSession() -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: id(2))
        session.installPersistentSessionBinding(AgentPersistentSessionBindingIdentity(tabID: id(2), sessionID: id(102)))
        session.hasLoadedPersistedState = true
        session.lastActivityAt = date(-1440)
        // Deliberately leave the cached last-user date stale: the actual source
        // item interaction, not a fixture-computed sort date, must win.
        session.lastUserMessageAt = date(-7200)
        session.items = [AgentChatItem(id: id(1000), timestamp: date(-1440), kind: .user, text: "Selected restored interaction")]
        return session
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: -1112,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("W1 must not start a provider") },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }

    private func date(_ minutes: Int) -> Date {
        day.addingTimeInterval(Double(minutes) * 60)
    }

    private func minutes(_ date: Date?) -> String {
        date.map { String(Int($0.timeIntervalSince(day) / 60)) } ?? "-"
    }

    private func label(_ id: UUID?) -> String {
        id.map { String(Int($0.uuidString.suffix(12))!) } ?? "-"
    }

    private func id(_ number: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", number))")!
    }
}
