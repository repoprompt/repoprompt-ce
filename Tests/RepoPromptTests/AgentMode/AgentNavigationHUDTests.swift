import Foundation
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentNavigationHUDTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rows(count: Int) -> [AgentModeViewModel.SidebarSession] {
        (0 ..< count).map { index in
            let tabID = UUID()
            let sessionID = UUID()
            let title = "Session \(index) café implementation"
            return AgentModeViewModel.SidebarSession(
                id: tabID, tabID: tabID, title: title, lastUserMessageAt: now,
                activityDate: now, isPinned: false, sessionID: sessionID,
                parentSessionID: nil, depth: 0, isMCPControlled: true,
                searchFieldSource: AgentSessionSearchFieldSource(
                    title: title, runState: .completed, isMCPControlled: true,
                    sessionID: sessionID, tabID: tabID, entryID: sessionID,
                    lastRunStateRaw: "completed", agentKindRaw: "claudeCode",
                    agentModelRaw: "model", agentReasoningEffortRaw: "high", autoEditEnabled: true
                )
            )
        }
    }

    func testSnapshotBuild519Rows() throws {
        guard ProcessInfo.processInfo.environment["RPCE_RUN_PERF_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set RPCE_RUN_PERF_BENCHMARKS=1 to run the opt-in snapshot benchmark")
        }
        let rows = rows(count: 519)
        let workspaceID = UUID()
        var samples: [Double] = []
        var searchSamples: [Double] = []
        for _ in 0 ..< 7 {
            let start = ContinuousClock.now
            let items = AgentNavigationHUDSnapshotBuilder.currentWindowItems(
                rows: rows, currentTabID: rows.first?.tabID, windowID: 1,
                workspaceID: workspaceID, workspaceTitle: "Workspace", windowTitle: "Window"
            )
            let elapsed = start.duration(to: .now)
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            let searchStart = ContinuousClock.now
            let fields = items.map(\.searchFields)
            let searchElapsed = searchStart.duration(to: .now)
            searchSamples.append(Double(searchElapsed.components.seconds) * 1000 + Double(searchElapsed.components.attoseconds) / 1e15)
            XCTAssertEqual(items.count, rows.count)
            XCTAssertEqual(fields.count, rows.count)
            XCTAssertTrue(AgentSessionSearchMatcher.matches(query: .parse("cafe"), fields: items[0].searchFields))
        }
        print("HUD_BENCHMARK_519 raw_snapshot_ms=\(samples) query_only_fields_ms=\(searchSamples)")
    }

    private func item(
        title: String, depth: Int = 0, overseeing: Int = 0, overseen: Bool = false,
        archived: Bool = false, tabID: UUID = UUID(), windowID: Int = 1,
        attention: AgentSessionRunState? = nil, subagentAttentionCount: Int = 0
    ) -> AgentNavigationHUDItem {
        AgentNavigationHUDItem(
            windowID: windowID, workspaceID: UUID(), tabID: tabID, sessionID: tabID,
            title: title, workspaceTitle: "Workspace", windowTitle: "Window",
            parentSessionID: nil, depth: depth, subagentCount: 0, subagentAttentionCount: subagentAttentionCount,
            overseenSessionCount: archived ? 0 : overseeing, isOverseen: !archived && overseen,
            isActiveTab: false, runState: .idle, attentionState: attention, attentionMarkedAt: nil,
            activityDate: now, worktree: nil, worktreeLabel: nil, mergeAttention: nil,
            mergeLabel: nil, isMCPControlled: false, isArchived: archived,
            searchFieldSource: AgentSessionSearchFieldSource(title: title),
            archivedSearchFields: archived ? AgentSessionSearchFields(title: title, status: ["archived"]) : nil
        )
    }

    private func loadedVM(_ items: [AgentNavigationHUDItem], mode: AgentNavigationHUDMode = .currentWindow) async -> AgentNavigationHUDViewModel {
        let vm = AgentNavigationHUDViewModel()
        vm.present(mode: mode) { mode, _ in
            AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: items)
        }
        await vm.test_waitForSnapshot()
        return vm
    }

    func testRoleFiltersFlattenEveryDepthAndSearchOnlyWithinRole() async {
        let items = [
            item(title: "Root", overseeing: 3),
            item(title: "Nested controller", depth: 4, overseeing: 1),
            item(title: "Leaf", depth: 8, overseen: true),
            item(title: "Both", depth: 3, overseeing: 2, overseen: true),
            item(title: "Archive", archived: true)
        ]
        let vm = await loadedVM(items)
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Root"])
        XCTAssertTrue(vm.showsRoleFilter)
        vm.setRoleFilter(.overseers)
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Root", "Nested controller", "Both"])
        vm.toggleSubagents()
        XCTAssertFalse(vm.showSubagents, "the sub-agent toggle is ignored during a role filter")
        vm.query = "overseeing"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Root", "Nested controller", "Both"])
        vm.query = "root"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Root"])
        vm.setRoleFilter(.overseen)
        XCTAssertTrue(vm.filteredItems.isEmpty, "search narrows the role, not the whole snapshot")
        vm.query = ""
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Leaf", "Both"])
        XCTAssertEqual(vm.totalItemCount, 2)
        XCTAssertEqual(vm.roleItemCount, 2)
        vm.query = "overseen"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Leaf", "Both"])
        vm.query = "archived"
        XCTAssertTrue(vm.filteredItems.isEmpty)
        vm.setRoleFilter(.all)
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Archive"])
    }

    func testAllAgentsCapIsAppliedAfterRoleFilterAndSearchRemainsUncapped() async {
        let items = [item(title: "Unrelated")] + (0 ..< 70).map {
            item(title: "Session \($0)", depth: 5, overseeing: 1)
        } + [item(title: "Archived Session", archived: true)]
        let vm = await loadedVM(items, mode: .allAgents)
        vm.setRoleFilter(.overseers)
        XCTAssertEqual(vm.filteredItems.count, AgentNavigationHUDSnapshotBuilder.allAgentsCap)
        XCTAssertEqual(vm.filteredItems.map(\.id), Array(items.dropFirst().prefix(50)).map(\.id))
        XCTAssertTrue(vm.isShowingLimitedResults)
        vm.query = "session"
        XCTAssertEqual(vm.filteredItems.count, 70)
        XCTAssertFalse(vm.isShowingLimitedResults)
        XCTAssertTrue(vm.filteredItems.allSatisfy { !$0.isArchived && $0.overseenSessionCount == 1 })
    }

    func testRoleCycleWrapsInBothDirectionsAndSurvivesDismissal() async {
        let vm = await loadedVM([item(title: "Plain")])
        XCTAssertFalse(vm.showsRoleFilter)
        vm.cycleRoleFilter()
        XCTAssertEqual(vm.roleFilter, .overseers)
        XCTAssertTrue(vm.showsRoleFilter, "a selected empty filter must always remain recoverable")
        XCTAssertEqual(vm.emptyTitle, "No overseer sessions in this window")
        vm.cycleRoleFilter()
        XCTAssertEqual(vm.roleFilter, .overseen)
        vm.cycleRoleFilter()
        XCTAssertEqual(vm.roleFilter, .all)
        vm.cycleRoleFilter(backward: true)
        XCTAssertEqual(vm.roleFilter, .overseen)
        vm.dismiss()
        XCTAssertEqual(vm.roleFilter, .overseen)
        vm.present(mode: .allAgents) { mode, _ in
            AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [])
        }
        await vm.test_waitForSnapshot()
        XCTAssertEqual(vm.roleFilter, .overseen)
        XCTAssertEqual(vm.emptyTitle, "No active or recent overseen sessions across windows")
        vm.setRoleFilter(.all)
        XCTAssertFalse(vm.showsRoleFilter)
    }

    func testEmptyQueryAndRoleFilteringNormalizeNothingAndSearchMemoIsReused() async {
        let vm = await loadedVM([item(title: "Café", overseeing: 1), item(title: "Hidden", depth: 9, overseen: true)])
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 0)
        vm.setRoleFilter(.overseers)
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 0)
        vm.query = "cafe"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Café"])
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 1, "excluded sub-agent rows must not be normalized")
        vm.query = "caf"
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 1)
        vm.setRoleFilter(.all)
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 2)
        vm.query = "hidden"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Hidden"])
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 2)
    }

    func testShellIsPresentedBeforeSnapshotWorkAndDismissCancelsPendingLoad() async {
        let vm = AgentNavigationHUDViewModel()
        var loads = 0
        let loader: AgentNavigationHUDViewModel.SnapshotLoader = { mode, _ in
            loads += 1
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [])
        }
        vm.present(mode: .currentWindow, loadSnapshot: loader)
        XCTAssertTrue(vm.isPresented)
        XCTAssertTrue(vm.isLoadingSnapshot)
        XCTAssertEqual(loads, 0)
        vm.dismiss()
        await vm.test_waitForSnapshot()
        XCTAssertFalse(vm.isPresented)
        XCTAssertFalse(vm.isLoadingSnapshot)
        vm.present(mode: .currentWindow, loadSnapshot: loader)
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 1, "the cancelled opening must not rebuild or republish")
        XCTAssertTrue(vm.isPresented)
        XCTAssertFalse(vm.isLoadingSnapshot)
    }

    func testRapidScopeChangeOnlyLoadsLatestScope() async {
        let vm = AgentNavigationHUDViewModel()
        var modes: [AgentNavigationHUDMode] = []
        let loader: AgentNavigationHUDViewModel.SnapshotLoader = { mode, _ in
            modes.append(mode)
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [])
        }
        vm.present(mode: .currentWindow, loadSnapshot: loader)
        vm.present(mode: .allAgents, loadSnapshot: loader)
        await vm.test_waitForSnapshot()
        XCTAssertEqual(modes, [.allAgents])
        XCTAssertEqual(vm.snapshot.mode, .allAgents)
        vm.present(mode: .allAgents, loadSnapshot: loader)
        XCTAssertFalse(vm.isPresented, "a distinct command retains deliberate toggle semantics")
    }

    func testArchivedSearchRowsLoadOnlyForUnfilteredAllAgentsSearch() async {
        let live = item(title: "Live", overseeing: 1)
        let archive = item(title: "Archived", archived: true)
        let vm = AgentNavigationHUDViewModel()
        var includeArchivedCalls: [Bool] = []
        vm.present(mode: .allAgents) { mode, includeArchived in
            includeArchivedCalls.append(includeArchived)
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: includeArchived ? [live, archive] : [live])
        }
        await vm.test_waitForSnapshot()
        XCTAssertEqual(includeArchivedCalls, [false])
        vm.query = "\"\""
        XCTAssertFalse(vm.queryIsEmpty, "Esc must clear entered quotes rather than dismiss")
        XCTAssertFalse(vm.hasSearchTerms)
        XCTAssertFalse(vm.clearQueryOrDismiss())
        XCTAssertTrue(vm.isPresented)
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(includeArchivedCalls, [false], "an empty parsed query must not materialize archives")
        vm.setRoleFilter(.overseers)
        vm.query = "archived"
        XCTAssertTrue(vm.filteredItems.isEmpty)
        XCTAssertEqual(includeArchivedCalls, [false])
        vm.setRoleFilter(.all)
        await vm.test_waitForSnapshot()
        XCTAssertEqual(includeArchivedCalls, [false, true])
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Archived"])
        vm.setRoleFilter(.overseen)
        XCTAssertTrue(vm.filteredItems.isEmpty)
    }

    func testRefreshCoalescesAndInvalidatesChangedSearchSources() async {
        let tabID = UUID()
        var current = item(title: "Original", overseeing: 1, tabID: tabID)
        let vm = AgentNavigationHUDViewModel()
        var loads = 0
        vm.present(mode: .currentWindow) { mode, _ in
            loads += 1
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [current])
        }
        await vm.test_waitForSnapshot()
        vm.query = "original"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Original"])
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 1)
        current = item(title: "Replacement", overseen: true, tabID: tabID)
        vm.refresh()
        vm.refresh()
        vm.refresh()
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(vm.filteredItems.isEmpty)
        XCTAssertEqual(vm.test_searchFieldsMaterializationCount, 2)
        vm.query = "replacement"
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Replacement"])
        vm.query = ""
        vm.setRoleFilter(.overseers)
        XCTAssertTrue(vm.filteredItems.isEmpty, "retired roles must not survive a refresh")
        vm.setRoleFilter(.overseen)
        XCTAssertEqual(vm.filteredItems.map(\.title), ["Replacement"])
        vm.dismiss()
        vm.refresh()
        XCTAssertEqual(loads, 2, "dismissed HUDs do not refresh")
    }

    func testEarlyHighlightedAndIndexedPicksReplayAfterFirstLoad() async {
        let items = [item(title: "First"), item(title: "Second"), item(title: "Third")]
        for index in [nil, 2] as [Int?] {
            let vm = AgentNavigationHUDViewModel()
            var picked: [String] = []
            vm.present(mode: .currentWindow) { mode, _ in
                AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: items)
            }
            let pick: AgentNavigationHUDViewModel.SelectionAction = { picked.append($0.title) }
            if let index {
                await vm.selectItem(atDisplayIndex: index, using: pick)
            } else {
                await vm.selectHighlighted(using: pick)
            }
            XCTAssertTrue(picked.isEmpty)
            await vm.test_waitForSnapshot()
            XCTAssertEqual(picked, [index == nil ? "First" : "Third"])
            await vm.test_waitForSnapshot()
            XCTAssertEqual(picked.count, 1, "a pending intent is consumed once")
        }
    }

    func testPendingPickIsLastWinsAndOutOfBoundsDoesNotFallbackToHighlight() async {
        let vm = AgentNavigationHUDViewModel()
        var picked: [String] = []
        let items = [item(title: "First"), item(title: "Second")]
        let loader: AgentNavigationHUDViewModel.SnapshotLoader = { mode, _ in
            AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: items)
        }
        vm.present(mode: .currentWindow, loadSnapshot: loader)
        await vm.selectHighlighted { picked.append($0.title) }
        await vm.selectItem(atDisplayIndex: 1) { picked.append($0.title) }
        await vm.test_waitForSnapshot()
        XCTAssertEqual(picked, ["Second"])
        vm.dismiss()
        vm.present(mode: .currentWindow, loadSnapshot: loader)
        await vm.selectItem(atDisplayIndex: 8) { picked.append($0.title) }
        await vm.test_waitForSnapshot()
        XCTAssertEqual(picked, ["Second"])
    }

    func testPendingPicksAreClearedByQueryDismissScopeAndRoleChanges() async {
        let items = [item(title: "First", overseeing: 1)]
        let loader: AgentNavigationHUDViewModel.SnapshotLoader = { mode, _ in
            AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: items)
        }
        for change in 0 ..< 4 {
            let vm = AgentNavigationHUDViewModel()
            var picked = false
            vm.present(mode: .currentWindow, loadSnapshot: loader)
            await vm.selectHighlighted { _ in picked = true }
            switch change {
            case 0: vm.query = "first"
            case 1:
                vm.dismiss()
                vm.present(mode: .currentWindow, loadSnapshot: loader)
            case 2: vm.present(mode: .allAgents, loadSnapshot: loader)
            default: vm.setRoleFilter(.overseers)
            }
            await vm.test_waitForSnapshot()
            XCTAssertFalse(picked, "a pick must not leak into a changed corpus or presentation")
            XCTAssertFalse(vm.isLoadingSnapshot, "cancelled older tasks must not affect the newer load")
        }
    }

    func testCancelledLoadClearsLoadingStateAndAllowsAnotherLoad() async {
        let vm = AgentNavigationHUDViewModel()
        var loads = 0
        vm.present(mode: .currentWindow) { mode, _ in
            loads += 1
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [])
        }
        vm.test_cancelSnapshotTask()
        await vm.test_waitForSnapshot()
        XCTAssertFalse(vm.isLoadingSnapshot)
        XCTAssertEqual(loads, 0)
        vm.refresh()
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 1, "early returns must release the task slot")
    }

    func testRefreshKeepsResultsAndRecoverableEmptyStatesWithoutLoadingFlash() async {
        let vm = await loadedVM([item(title: "Plain")])
        let previous = vm.filteredItems
        vm.refresh()
        XCTAssertFalse(vm.isLoadingSnapshot)
        XCTAssertEqual(vm.filteredItems, previous)
        await vm.test_waitForSnapshot()
        vm.query = "missing"
        vm.refresh()
        XCTAssertFalse(vm.isLoadingSnapshot)
        XCTAssertTrue(vm.filteredItems.isEmpty)
        await vm.test_waitForSnapshot()
        vm.query = ""
        vm.setRoleFilter(.overseen)
        vm.refresh()
        XCTAssertFalse(vm.isLoadingSnapshot, "Show all stays available during an empty-filter refresh")
        XCTAssertTrue(vm.showsRoleFilter)
        XCTAssertEqual(vm.emptyTitle, "No overseen sessions in this window")
        await vm.test_waitForSnapshot()
    }

    func testRoleOnlyInvalidationIgnoresChurnOtherWindowsAndArchives() async {
        let tabID = UUID()
        let remoteTabID = UUID()
        let archivedTabID = UUID()
        var items = [
            item(title: "Controller", overseeing: 2, tabID: tabID),
            item(title: "Remote", depth: 4, overseen: true, tabID: remoteTabID, windowID: 2),
            item(title: "Archived", archived: true, tabID: archivedTabID)
        ]
        let vm = AgentNavigationHUDViewModel()
        var loads = 0
        vm.present(mode: .allAgents) { mode, _ in
            loads += 1
            return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: items)
        }
        await vm.test_waitForSnapshot()
        for _ in 0 ..< 10 {
            vm.refreshIfOversightRolesChanged(windowID: 1, roles: [tabID: (2, false), archivedTabID: (9, true)])
            vm.refreshIfOversightRolesChanged(windowID: 2, roles: [remoteTabID: (0, true)])
            vm.refreshIfOversightRolesChanged(windowID: 3, roles: [tabID: (0, false)])
        }
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 1)
        items[1] = item(title: "Remote", depth: 4, overseeing: 1, tabID: remoteTabID, windowID: 2)
        vm.refreshIfOversightRolesChanged(windowID: 2, roles: [remoteTabID: (1, false)])
        vm.refreshIfOversightRolesChanged(windowID: 2, roles: [remoteTabID: (1, false)])
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 2, "real role changes still coalesce into one load")
        vm.refreshIfOversightRolesChanged(windowID: 2, roles: [remoteTabID: (1, false)])
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 2)
        items[1] = item(title: "Remote", depth: 4, tabID: remoteTabID, windowID: 2)
        vm.refreshIfOversightRolesChanged(windowID: 2, roles: [:])
        await vm.test_waitForSnapshot()
        XCTAssertEqual(loads, 3, "role loss or an unresolvable endpoint must refresh too")
    }

    func testHeaderCountsUseVisibleDepthCappedCorpusAndCountParentAttentionOnce() async {
        let vm = await loadedVM([
            item(title: "Attention root", overseeing: 1, attention: .waitingForUser, subagentAttentionCount: 3),
            item(title: "Hidden attention root", overseeing: 1, subagentAttentionCount: 2),
            item(title: "Plain"),
            item(title: "Child", depth: 1, overseen: true, attention: .waitingForUser),
            item(title: "Deep", depth: 3, overseen: true, attention: .waitingForUser),
            item(title: "Archive", archived: true, attention: .waitingForUser)
        ])
        XCTAssertEqual(vm.totalItemCount, 3)
        XCTAssertEqual(vm.needsAttentionCount, 2, "row plus several hidden alerts count one parent")
        vm.query = "child"
        XCTAssertEqual(vm.totalItemCount, 3, "search does not rewrite scope totals")
        vm.query = ""
        vm.toggleSubagents()
        XCTAssertEqual(vm.totalItemCount, 4)
        XCTAssertEqual(vm.needsAttentionCount, 3)
        vm.setRoleFilter(.overseen)
        XCTAssertEqual(vm.totalItemCount, 2, "role totals flatten all depths and exclude archives")
        XCTAssertEqual(vm.needsAttentionCount, 2)
        vm.setRoleFilter(.overseers)
        XCTAssertEqual(vm.totalItemCount, 2)
        XCTAssertEqual(vm.needsAttentionCount, 2)
    }

    func testRoleFilterKeysHandleBackTabAndLockStateWithoutInterceptingOtherShortcuts() {
        XCTAssertEqual(AgentNavigationHUDView.roleFilterCyclesBackward(key: .tab, modifiers: []), false)
        XCTAssertEqual(AgentNavigationHUDView.roleFilterCyclesBackward(key: .tab, modifiers: .shift), true)
        XCTAssertEqual(AgentNavigationHUDView.roleFilterCyclesBackward(key: .tab, modifiers: .capsLock), false)
        XCTAssertEqual(AgentNavigationHUDView.roleFilterCyclesBackward(key: .tab, modifiers: [.shift, .capsLock]), true)
        XCTAssertEqual(AgentNavigationHUDView.roleFilterCyclesBackward(key: KeyEquivalent("\u{19}"), modifiers: []), true)
        let otherKeys: [KeyEquivalent] = [.upArrow, .downArrow, .return, .escape, "1"]
        for key in otherKeys {
            XCTAssertNil(AgentNavigationHUDView.roleFilterCyclesBackward(key: key, modifiers: []))
        }
        XCTAssertNil(AgentNavigationHUDView.roleFilterCyclesBackward(key: .tab, modifiers: .command))
    }

    func testEventDedupeIgnoresReceiptDelayButAllowsRapidDistinctCommands() {
        var dedupe = AgentNavigationHUDCommandDeduplicator()
        XCTAssertFalse(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: 42))
        // Identical captured time stays duplicate regardless of time spent building the HUD.
        XCTAssertTrue(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: 42))
        XCTAssertFalse(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: 41), "a reordered distinct delivery is not a duplicate")
        XCTAssertFalse(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: 42.01))
        XCTAssertTrue(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: 42))
        XCTAssertFalse(dedupe.isDuplicate(mode: .allAgents, eventTimestamp: 42.01))
        XCTAssertFalse(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: nil))
        XCTAssertFalse(dedupe.isDuplicate(mode: .currentWindow, eventTimestamp: nil))
    }
}
