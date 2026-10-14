import AppKit
import Combine
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import SwiftUI
import XCTest

/// Covers the sidebar projection's two invalidation/laziness contracts:
///
/// 1. Normalized search fields are materialized only when a search query is
///    active, and are memoized by their source inputs.
/// 2. Presentation-only sidebar state (thread collapse, attention badges)
///    re-projects rows without rebuilding them.
///
/// Both protect against a main-thread rebuild storm during workspace restore,
/// where every sidebar invalidation previously re-normalized every row.
@MainActor
final class AgentSidebarSearchFieldDeferralTests: XCTestCase {
    // MARK: - Materialization is deferred and folding behavior is pinned

    func testSourceCaptureKeepsRawTextAndMaterializationFoldsCaseAndDiacritics() throws {
        let source = AgentModeSidebarSessionBuilder.searchFieldSource(
            title: "Café RÉSUMÉ",
            entry: entry(agentModelRaw: "GPT-5.2", parentSessionID: id(7)),
            runState: nil,
            isMCPControlled: false,
            worktree: nil,
            mergeAttention: nil,
            sessionID: id(1),
            tabID: id(2)
        )

        // Capturing a source must not normalize: normalization is the expensive
        // step this change defers out of ordinary rebuilds.
        XCTAssertEqual(source.title, "Café RÉSUMÉ")

        let fields = AgentModeSidebarSessionBuilder.searchFields(source: source)
        let title = try XCTUnwrap(fields.fields.first { $0.kind == .title })
        XCTAssertEqual(title.text, "Café RÉSUMÉ")
        XCTAssertEqual(title.normalizedText, "cafe resume")

        let model = try XCTUnwrap(fields.fields.first { $0.kind == .model })
        XCTAssertEqual(model.normalizedText, "gpt-5.2")

        // Entry-derived secondary and identifier fields survive the indirection.
        XCTAssertTrue(fields.fields.contains { $0.kind == .secondary && $0.normalizedText == "sub-agent" })
        XCTAssertTrue(fields.fields.contains { $0.kind == .identifier && $0.normalizedText == id(2).uuidString.lowercased() })
    }

    func testMaterializedFieldsMatchTheEagerBuilderForTheSameInputs() {
        let indexEntry = entry(agentModelRaw: "sonnet", parentSessionID: nil)
        let eager = AgentModeSidebarSessionBuilder.searchFields(
            title: "Rebuild Storm",
            entry: indexEntry,
            runState: .running,
            isMCPControlled: true,
            worktree: nil,
            mergeAttention: nil,
            sessionID: id(1),
            tabID: id(2)
        )
        let deferred = AgentModeSidebarSessionBuilder.searchFields(
            source: AgentModeSidebarSessionBuilder.searchFieldSource(
                title: "Rebuild Storm",
                entry: indexEntry,
                runState: .running,
                isMCPControlled: true,
                worktree: nil,
                mergeAttention: nil,
                sessionID: id(1),
                tabID: id(2)
            )
        )

        XCTAssertEqual(eager, deferred)
        XCTAssertFalse(deferred.fields.isEmpty)
    }

    func testSearchMatchingStillFindsFoldedQueryAgainstDeferredFields() {
        let row = row(tabID: id(2), title: "Café RÉSUMÉ")
        let query = AgentSessionSearchQuery.parse("cafe")

        XCTAssertTrue(AgentSessionSearchMatcher.matches(query: query, fields: row.makeSearchFields()))
        XCTAssertFalse(
            AgentSessionSearchMatcher.matches(
                query: AgentSessionSearchQuery.parse("zzzznomatch"),
                fields: row.makeSearchFields()
            )
        )
    }

    // MARK: - Memoization

    func testSearchFieldMemoReusesUnchangedRowsAndPrunesToCurrentRowSet() {
        let viewModel = makeViewModel()
        let rows = (1 ... 3).map { row(tabID: id($0), title: "Session \($0)") }

        let first = viewModel.sidebarSearchFields(for: rows)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)

        // The result is positionally aligned with the input rows, which is what
        // makes the caller's lookup total and keeps every materialization counted.
        XCTAssertEqual(first.count, rows.count)
        XCTAssertEqual(
            first.map { $0.fields.first?.normalizedText },
            rows.map { $0.makeSearchFields().fields.first?.normalizedText }
        )

        // Identical sources must not re-normalize.
        _ = viewModel.sidebarSearchFields(for: rows)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)

        // A changed source re-materializes only that row.
        var changed = rows
        changed[1] = row(tabID: id(2), title: "Session 2 renamed")
        _ = viewModel.sidebarSearchFields(for: changed)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 4)

        // The memo is replaced by the current row set, so dropped rows are not
        // retained; re-requesting them materializes again.
        _ = viewModel.sidebarSearchFields(for: [changed[0]])
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 4)
        _ = viewModel.sidebarSearchFields(for: changed)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 6)
    }

    func testDeactivatingSearchReleasesMemoizedFields() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }

        viewModel.setSessionSidebarSearchText("session")
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 3)
        XCTAssertEqual(viewModel.sidebarSearchFieldsMemo.count, 3)

        viewModel.clearSessionSidebarSearchText()
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertTrue(viewModel.sidebarSearchFieldsMemo.isEmpty)

        viewModel.setSessionSidebarSearchText("session")
        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertEqual(
            viewModel.test_sidebarSearchFieldsMaterializationCount,
            6,
            "reactivating search should rematerialize fields released while inactive"
        )
    }

    // MARK: - Restore publication batching

    func testRestoreBatchSizePublishesPreferredRowsOnceAfterPrioritizedActiveTab() {
        XCTAssertEqual(
            AgentModeViewModel.sessionSidebarRestoreBatchSize(forPersistedTabCount: 0),
            1
        )
        XCTAssertEqual(
            AgentModeViewModel.sessionSidebarRestoreBatchSize(forPersistedTabCount: 969),
            969,
            "all already-projected preferred rows should arrive in one main-actor publication"
        )
    }

    // MARK: - Projection-level invalidation contract

    func testInactiveSearchProjectionMaterializesNoSearchFields() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 4).map { ComposeTabState(id: id($0), name: "Session \($0)") }

        _ = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)

        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)
        XCTAssertEqual(
            viewModel.test_sidebarSearchFieldsMaterializationCount,
            0,
            "an empty search box must not normalize any row"
        )
    }

    func testActiveSearchProjectionMaterializesFieldsAndStillFilters() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Café RÉSUMÉ"),
            ComposeTabState(id: id(2), name: "Unrelated")
        ]
        let store = viewModel.ui.sessionSidebar
        store.update(
            searchText: "cafe",
            visibleSessionCount: AgentModeViewModel.sessionSidebarPageSize,
            archivedVisibleSessionCount: AgentModeViewModel.sessionSidebarArchivedPageSize
        )

        let result = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(viewModel.test_sidebarSearchFieldsMaterializationCount, 2)
        XCTAssertEqual(result.filteredSessions.map(\.tabID), [id(1)])
    }

    /// Drives the real `AgentSessionSidebarUIStore` publish paths rather than a
    /// synthetic snapshot, because `buildSidebarSessions` keys its row cache on
    /// the live store's `rowContentRevision`.
    func testPresentationOnlyStoreChangesReprojectWithoutRebuildingRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)
        XCTAssertEqual(viewModel.test_sidebarListProjectionBuildCount, 1)

        store.setThreadCollapsed(true, for: .tab(id(1)))
        XCTAssertTrue(store.markRunStateAttention(tabID: id(2), state: .completed))
        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(viewModel.test_sidebarListProjectionBuildCount, 2, "projection must re-run")
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1, "rows must not rebuild")
    }

    /// `observeSidebarRunStateTransition` relies on `clearRunStateAttention`
    /// having published something: when the clear publishes, it deliberately does
    /// *not* call `syncSidebarUIState(refresh:reason:)`. Before this change the
    /// clear also bumped `rowContentRevision`, so the sidebar happened to update
    /// via a full row rebuild. Now the clear is presentation-only, so this proves
    /// the transition still reaches the sidebar through re-projection alone.
    func testRunningTransitionClearingAttentionUpdatesSidebarWithoutRebuildingRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar
        let backgroundTabID = id(2)
        let session = AgentModeViewModel.TabSession(tabID: backgroundTabID)

        // Seed the observed run state so the first real transition is not swallowed.
        session.runState = .idle
        viewModel.observeSidebarRunStateTransition(for: session)

        // A background completion raises an unseen-attention badge.
        session.runState = .completed
        viewModel.observeSidebarRunStateTransition(for: session)
        XCTAssertEqual(store.attentionRunState(for: backgroundTabID), .completed)

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        let rowBuildsAfterBaseline = viewModel.test_sidebarSessionRowsBuildCount
        let projectionBuildsAfterBaseline = viewModel.test_sidebarListProjectionBuildCount
        let revisionBeforeClear = store.snapshot.revision
        let rowContentRevisionBeforeClear = store.snapshot.rowContentRevision

        // Resuming the run supersedes the stale badge.
        session.runState = .running
        viewModel.observeSidebarRunStateTransition(for: session)

        XCTAssertNil(
            store.attentionRunState(for: backgroundTabID),
            "resuming a run must clear the stale completion badge"
        )
        XCTAssertGreaterThan(
            store.snapshot.revision,
            revisionBeforeClear,
            "the clear must publish so the sidebar re-projects"
        )
        XCTAssertEqual(
            store.snapshot.rowContentRevision,
            rowContentRevisionBeforeClear,
            "the duplicate content fingerprint must not force another row rebuild"
        )

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(
            viewModel.test_sidebarListProjectionBuildCount,
            projectionBuildsAfterBaseline + 1,
            "the cleared badge must reach the sidebar through re-projection"
        )
        XCTAssertEqual(
            viewModel.test_sidebarSessionRowsBuildCount,
            rowBuildsAfterBaseline,
            "a duplicate content fingerprint must not rebuild rows for an attention-only transition"
        )
    }

    func testBackgroundWaitingTransitionRefreshesCachedSearchFields() {
        let viewModel = makeViewModel()
        var tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let backgroundTabID = id(2)
        tabs[1].activeAgentSessionID = id(500)
        let session = AgentModeViewModel.TabSession(tabID: backgroundTabID)
        session.runState = .running
        session.hasLoadedPersistedState = true
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: id(500), on: session))
        viewModel.test_installLiveSession(session)

        // Seed both transition observation and the content fingerprint while
        // the background session is running.
        viewModel.observeSidebarRunStateTransition(for: session)
        viewModel.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: tabs)
        viewModel.setSessionSidebarSearchText("approval")

        let before = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertFalse(before.filteredSessions.contains { $0.tabID == backgroundTabID })
        let rowBuildsBeforeTransition = viewModel.test_sidebarSessionRowsBuildCount
        let rowContentRevisionBeforeTransition = viewModel.ui.sessionSidebar.snapshot.rowContentRevision

        // The tab remains active across this transition, so tabsWithActiveAgentRun
        // does not change. The transition observer must still refresh the row's
        // cached run-state search source.
        session.runState = .waitingForApproval
        viewModel.observeSidebarRunStateTransition(for: session)

        XCTAssertGreaterThan(
            viewModel.ui.sessionSidebar.snapshot.rowContentRevision,
            rowContentRevisionBeforeTransition
        )
        let after = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertTrue(after.filteredSessions.contains { $0.tabID == backgroundTabID })
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, rowBuildsBeforeTransition + 1)
    }

    /// The row builder prefers the live session's worktree bindings, and the index-summary updates
    /// return early when the session has no owner-validated index entry. The live change must
    /// still refresh rows through the content fingerprint instead of waiting for a debounced save.
    func testLiveWorktreeBindingChangeWithoutIndexEntryRefreshesRows() throws {
        let viewModel = makeViewModel()
        var tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let tabID = id(2)
        tabs[1].activeAgentSessionID = id(600)
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: id(600), on: session))
        viewModel.test_installLiveSession(session)
        XCTAssertNil(viewModel.ownerValidatedSessionIndex[id(600)], "Precondition: no index entry carries the summary")

        viewModel.syncSidebarUIState(refresh: true, reason: .metadataUpdated, sidebarTabs: tabs)
        let before = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertNil(before.filteredSessions.first { $0.tabID == tabID }?.worktree)
        let rowContentRevisionBefore = viewModel.ui.sessionSidebar.snapshot.rowContentRevision

        session.worktreeBindings = [AgentSessionWorktreeBinding(
            id: "bind_sidebar", repositoryID: "repo_sidebar", repoKey: "repo",
            logicalRootPath: "/tmp/sidebar-repo", logicalRootName: "sidebar-repo",
            worktreeID: "wt_sidebar", worktreeRootPath: "/tmp/sidebar-repo-wt", worktreeName: "sidebar-wt",
            branch: "feature/sidebar", head: "abcdef", visualLabel: "sidebar", visualColorHex: "#3366FF",
            boundAt: Date(timeIntervalSinceReferenceDate: 123), source: "test"
        )]
        viewModel.syncSidebarUIState(refresh: true, reason: .metadataUpdated, sidebarTabs: tabs)

        XCTAssertGreaterThan(
            viewModel.ui.sessionSidebar.snapshot.rowContentRevision, rowContentRevisionBefore,
            "A live worktree binding change is row content even without an index entry"
        )
        let after = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot)
        XCTAssertEqual(try XCTUnwrap(after.filteredSessions.first { $0.tabID == tabID }?.worktree).rawLabel, "sidebar")
    }

    func testForcedSidebarRefreshRebuildsRows() {
        let viewModel = makeViewModel()
        let tabs = (1 ... 3).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let store = viewModel.ui.sessionSidebar

        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(viewModel.test_sidebarSessionRowsBuildCount, 1)

        store.refresh()
        _ = projection(viewModel, tabs: tabs, snapshot: store.snapshot)

        XCTAssertEqual(
            viewModel.test_sidebarSessionRowsBuildCount,
            2,
            "a forced content refresh remains the row-content invalidation path"
        )
    }

    // MARK: - Pins, groups, and facets

    func testPinnedAndGroupSearchFacetsFilterRows() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Alpha", isPinned: true, sidebarGroup: "My lanes"),
            ComposeTabState(id: id(2), name: "Beta", sidebarGroup: "Lanes"),
            ComposeTabState(id: id(3), name: "Gamma", isPinned: true)
        ]
        let store = viewModel.ui.sessionSidebar
        func filtered(_ text: String) -> Set<UUID> {
            store.update(
                searchText: text,
                visibleSessionCount: AgentModeViewModel.sessionSidebarPageSize,
                archivedVisibleSessionCount: AgentModeViewModel.sessionSidebarArchivedPageSize
            )
            return Set(projection(viewModel, tabs: tabs, snapshot: store.snapshot).filteredSessions.map(\.tabID))
        }
        XCTAssertEqual(filtered("is:pinned"), [id(1), id(3)])
        XCTAssertEqual(filtered("group:lanes"), [id(2)])
        XCTAssertEqual(filtered("group:\"My lanes\""), [id(1)])
        XCTAssertEqual(filtered("is:pinned gamma"), [id(3)], "facets combine with free text")
        XCTAssertEqual(filtered("is:pinned group:lanes"), [])

        let query = AgentSessionSearchQuery.parse("IS:PINNED group:Lanes beta")
        XCTAssertTrue(query.requiresPinned)
        XCTAssertEqual(query.groupFacets, ["lanes"])
        XCTAssertEqual(query.tokens, ["beta"])
    }

    func testPinnedRowsAreExemptFromThePageCap() {
        let viewModel = makeViewModel()
        let pinned = (1 ... 20).map { ComposeTabState(id: id($0), name: "Pinned \($0)", isPinned: true, pinnedOrder: $0) }
        let unpinned = (21 ... 40).map { ComposeTabState(id: id($0), name: "Session \($0)") }
        let result = projection(viewModel, tabs: pinned + unpinned, snapshot: viewModel.ui.sessionSidebar.snapshot)

        let paged = result.pagedSessions
        XCTAssertEqual(paged.filter(\.isPinned).count, 20, "every pin is visible")
        XCTAssertEqual(paged.count(where: { !$0.isPinned }), AgentModeViewModel.sessionSidebarPageSize)
        XCTAssertEqual(result.effectiveVisibleSessionCount, paged.count)
    }

    func testPinnedThreadAncestorsDoNotConsumeTheOrdinaryPageBudget() {
        let viewModel = makeViewModel()
        let threadCount = AgentModeViewModel.sessionSidebarPageSize + 3
        var tabs: [ComposeTabState] = []
        var sessions: [UUID: AgentModeViewModel.TabSession] = [:]
        var bindings: [UUID: UUID] = [:]
        for thread in 0 ..< threadCount {
            for level in 0 ..< 3 {
                let tabID = id(1000 + thread * 3 + level)
                let sessionID = id(2000 + thread * 3 + level)
                tabs.append(ComposeTabState(id: tabID, name: "Thread \(thread) level \(level)", isPinned: level == 2))
                let session = AgentModeViewModel.TabSession(tabID: tabID)
                session.hasLoadedPersistedState = true
                session.parentSessionID = level == 0 ? nil : id(2000 + thread * 3 + level - 1)
                XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
                sessions[tabID] = session
                bindings[tabID] = sessionID
            }
        }
        let ordinary = (0 ..< AgentModeViewModel.sessionSidebarPageSize + 4).map {
            ComposeTabState(id: id(3000 + $0), name: "Ordinary \($0)")
        }
        tabs.append(contentsOf: ordinary)
        let rows = AgentModeSidebarSessionBuilder(
            allTabs: tabs, rowTabs: tabs, sessions: sessions, authoritativeSessionIDByTabID: bindings,
            sessionIndex: [:], sessionListSortDates: [:], restoreBaseline: nil, mcpControlledTabIDs: []
        ).build()
        XCTAssertEqual(rows.filter(\.isPinned).map(\.depth), Array(repeating: 2, count: threadCount))
        let paged = viewModel.pagedSidebarSessions(filteredSessions: rows, currentTabID: nil)
        XCTAssertEqual(paged.filter(\.isPinned).count, threadCount, "every pin-bearing thread survives the page cap")
        XCTAssertEqual(paged.count(where: { $0.depth < 2 && $0.sessionID != nil }), threadCount * 2)
        XCTAssertEqual(paged.count(where: { $0.sessionID == nil }), AgentModeViewModel.sessionSidebarPageSize)
        XCTAssertEqual(paged.count, threadCount * 3 + AgentModeViewModel.sessionSidebarPageSize)
        let pinsOnly = viewModel.pagedSidebarSessions(filteredSessions: rows, currentTabID: nil, visibleSessionCount: 0)
        XCTAssertEqual(pinsOnly.count, threadCount * 3, "even a zero ordinary budget retains pins and their ancestors")
    }

    func testOrdinarySiblingsCannotHideALaterPinnedThreadAndActiveRowsStillExpandThePage() {
        let viewModel = makeViewModel()
        let firstParent = row(tabID: id(1), title: "Parent one", sessionID: id(101))
        let firstPin = row(tabID: id(2), title: "Pin one", isPinned: true, sessionID: id(102), parentSessionID: id(101), depth: 1)
        let siblings = (0 ..< AgentModeViewModel.sessionSidebarPageSize + 3).map {
            row(tabID: id(10 + $0), title: "Ordinary sibling \($0)", parentSessionID: id(101), depth: 1)
        }
        let secondParent = row(tabID: id(3), title: "Parent two", sessionID: id(103))
        let secondPin = row(tabID: id(4), title: "Pin two", isPinned: true, sessionID: id(104), parentSessionID: id(103), depth: 1)
        let rows = [firstParent, firstPin] + siblings + [secondParent, secondPin]
        let paged = viewModel.pagedSidebarSessions(filteredSessions: rows, currentTabID: nil)
        XCTAssertEqual(paged.map(\.tabID), [id(1), id(2)] + siblings.prefix(AgentModeViewModel.sessionSidebarPageSize).map(\.tabID) + [id(3), id(4)])
        XCTAssertEqual(viewModel.effectiveSidebarVisibleSessionCount(filteredSessions: rows, currentTabID: nil), paged.count)
        let pinsOnly = viewModel.pagedSidebarSessions(filteredSessions: rows, currentTabID: nil, visibleSessionCount: 0)
        XCTAssertEqual(pinsOnly.map(\.tabID), [id(1), id(2), id(3), id(4)])
        let expanded = viewModel.pagedSidebarSessions(filteredSessions: rows, currentTabID: siblings.last?.tabID)
        XCTAssertEqual(expanded.map(\.tabID), rows.map(\.tabID), "active visibility still admits every preceding ordinary row")
        XCTAssertEqual(
            viewModel.effectiveSidebarVisibleSessionCount(filteredSessions: rows, currentTabID: siblings.last?.tabID),
            expanded.count
        )
    }

    func testSearchExpandsStoredCollapsedGroupsForRenderingSelectionAndNavigation() throws {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Matching one", sidebarGroup: "A", activeAgentSessionID: id(101)),
            ComposeTabState(id: id(2), name: "Matching two", sidebarGroup: "A", activeAgentSessionID: id(102)),
            ComposeTabState(id: id(3), name: "Other", sidebarGroup: "B", activeAgentSessionID: id(103))
        ]
        let store = viewModel.ui.sessionSidebar
        store.toggleGroupCollapsed("A")
        XCTAssertTrue(projection(viewModel, tabs: tabs, snapshot: store.snapshot).renderedSelectionOrder.allSatisfy {
            $0 != .active(tabID: id(1)) && $0 != .active(tabID: id(2))
        })
        viewModel.setSessionSidebarSearchText("matching")
        let result = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        let rendered = AgentSidebarDateSectionBuilder.renderedActiveRowsWithGroups(
            for: result.pagedSessions, collapsedGroups: store.snapshot.collapsedSidebarGroups,
            searchText: store.snapshot.searchText
        )
        XCTAssertEqual(Set(rendered.filter { !$0.hidesRow }.map(\.session.tabID)), [id(1), id(2)])
        XCTAssertTrue(rendered.allSatisfy { !$0.isGroupCollapsed })
        XCTAssertEqual(result.renderedSelectionOrder, rendered.map { .active(tabID: $0.session.tabID) })
        let first = try XCTUnwrap(rendered.first)
        let second = try XCTUnwrap(rendered.dropFirst().first)
        XCTAssertEqual(viewModel.sessionSidebarShortcutTabID(at: 0, in: tabs, currentTabID: nil), first.session.tabID)
        XCTAssertEqual(
            viewModel.adjacentSidebarSessionTabID(from: first.session.tabID, forward: true, in: tabs, currentTabID: nil),
            second.session.tabID
        )
        viewModel.toggleSidebarGroupCollapsed("A")
        XCTAssertEqual(store.snapshot.collapsedSidebarGroups, ["A"], "search and its disabled collapse action preserve the stored preference")
        viewModel.setSessionSidebarSearchText("  ")
        let cleared = projection(viewModel, tabs: tabs, snapshot: store.snapshot)
        XCTAssertEqual(cleared.renderedSelectionOrder, [.active(tabID: id(3))], "clearing search restores the stored collapse")
    }

    func testGroupSectionsRenderFirstInGroupOrderAndCollapse() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Ungrouped"),
            ComposeTabState(id: id(2), name: "In B", sidebarGroup: "B", sidebarGroupOrder: 1),
            ComposeTabState(id: id(3), name: "In A", sidebarGroup: "A", sidebarGroupOrder: 0),
            ComposeTabState(id: id(4), name: "Also A", sidebarGroup: "A", sidebarGroupOrder: 0)
        ]
        let rows = projection(viewModel, tabs: tabs, snapshot: viewModel.ui.sessionSidebar.snapshot).pagedSessions
        let rendered = AgentSidebarDateSectionBuilder.renderedActiveRowsWithGroups(for: rows, collapsedGroups: [])
        XCTAssertEqual(rendered.compactMap(\.groupName), ["A", "B"])
        XCTAssertEqual(Set(rendered.prefix(2).map(\.session.tabID)), [id(3), id(4)])
        XCTAssertEqual(rendered.last?.session.tabID, id(1), "ungrouped rows keep their date sections after groups")
        XCTAssertEqual(rendered.first?.groupRowCount, 2)

        let collapsed = AgentSidebarDateSectionBuilder.renderedActiveRowsWithGroups(for: rows, collapsedGroups: ["A"])
        let groupA = collapsed.filter { $0.headerTitle == "A" }
        XCTAssertEqual(groupA.count, 1, "a collapsed group keeps one header carrier")
        XCTAssertEqual(groupA.first?.hidesRow, true)

        let ungroupedOnly = [rows.first { $0.tabID == id(1) }].compactMap(\.self)
        XCTAssertEqual(
            AgentSidebarDateSectionBuilder.renderedActiveRowsWithGroups(for: ungroupedOnly, collapsedGroups: []).map(\.id),
            AgentSidebarDateSectionBuilder.renderedActiveRows(
                for: AgentSidebarDateSectionBuilder.activeSections(for: ungroupedOnly)
            ).map(\.id),
            "without groups the list is unchanged"
        )
    }

    func testSelectionOrderFollowsGroupedVisibleRowsAndSkipsCollapsedGroups() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Ungrouped"),
            ComposeTabState(id: id(2), name: "In A", sidebarGroup: "A", sidebarGroupOrder: 0),
            ComposeTabState(id: id(3), name: "Also A", sidebarGroup: "A", sidebarGroupOrder: 0)
        ]
        let store = viewModel.ui.sessionSidebar
        let expanded = projection(viewModel, tabs: tabs, snapshot: store.snapshot).renderedSelectionOrder
        XCTAssertEqual(Set(expanded.prefix(2)), [.active(tabID: id(2)), .active(tabID: id(3))], "group rows come first")
        XCTAssertEqual(expanded.last, .active(tabID: id(1)))

        store.toggleGroupCollapsed("A")
        let collapsed = projection(viewModel, tabs: tabs, snapshot: store.snapshot).renderedSelectionOrder
        XCTAssertEqual(collapsed, [.active(tabID: id(1))], "rows of a collapsed group are not selectable (Cmd-A)")
    }

    // MARK: - Helpers

    private func projection(
        _ viewModel: AgentModeViewModel,
        tabs: [ComposeTabState],
        snapshot: AgentSessionSidebarSnapshot
    ) -> AgentModeViewModel.SidebarListProjection {
        viewModel.sidebarListProjection(
            workspaceID: nil,
            composeTabs: tabs,
            stashedTabs: [],
            currentTabID: tabs.first?.id,
            sidebarSnapshot: snapshot,
            archivedSessionsExpanded: false,
            showComposeTabsWithoutAgentSessions: true
        )
    }

    private func row(
        tabID: UUID, title: String, isPinned: Bool = false,
        sessionID: UUID? = nil, parentSessionID: UUID? = nil, depth: Int = 0
    ) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title,
            lastUserMessageAt: nil,
            activityDate: Date(timeIntervalSince1970: 0),
            isPinned: isPinned,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            depth: depth,
            isMCPControlled: false,
            searchFieldSource: AgentModeSidebarSessionBuilder.searchFieldSource(
                title: title,
                entry: nil,
                runState: nil,
                isMCPControlled: false,
                worktree: nil,
                mergeAttention: nil,
                sessionID: nil,
                tabID: tabID
            )
        )
    }

    private func entry(agentModelRaw: String?, parentSessionID: UUID?) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: id(500),
            tabID: id(2),
            name: "Indexed",
            lastUserMessageAt: nil,
            savedAt: Date(timeIntervalSince1970: 0),
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: agentModelRaw,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: parentSessionID,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: -991,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Sidebar projection tests must not start a Codex session")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

/// Protects the rendered row lifetime needed to retain an in-flight press.
/// This deliberately does not assert AppKit mouse delivery: the CI XCTest
/// process can render rows without delivering even a stationary control tap.
@MainActor
final class AgentSidebarRunningTapTests: XCTestCase {
    func testRenderedRowIdentitySurvivesAStationaryUpdate() throws {
        let rows = Self.sessions(now: Self.now)
        var updated = rows
        updated[3] = Self.session(
            index: 1, activity: rows[3].activityDate, title: "Updated while pressed"
        )

        // The control updates content, not just the same value twice, and both
        // renderers must retain it when no ancestry or ordering changes.
        try Self.assertRowLifetime(before: rows, after: updated, pressedID: rows[3].tabID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: rows[3].tabID,
            style: .firstRowSectionIdentity
        )
    }

    func testRenderedRowIdentitySurvivesOtherRunningSessionsResorting() throws {
        let rows = Self.sessions(now: Self.now)
        let pressedID = rows[3].tabID
        let promotedID = try XCTUnwrap(rows.last?.tabID)
        let updated = Self.sessions(now: Self.now, promotedTabID: promotedID)
        XCTAssertNotEqual(promotedID, pressedID)
        XCTAssertEqual(updated.first?.tabID, promotedID)
        XCTAssertNotEqual(rows.map(\.tabID), updated.map(\.tabID))

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressedID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressedID,
            style: .firstRowSectionIdentity, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesThePressedRowMoving() throws {
        let rows = Self.sessions(now: Self.now)
        let pressedID = rows[3].tabID
        let updated = Self.sessions(now: Self.now, promotedTabID: pressedID)
        XCTAssertNotEqual(rows.first?.tabID, pressedID)
        XCTAssertEqual(updated.first?.tabID, pressedID)

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressedID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressedID,
            style: .firstRowSectionIdentity, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesASectionOrdinalChange() throws {
        let yesterday = Self.now.addingTimeInterval(-86400)
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let today = Self.session(index: 1, activity: Self.now)
        let pressed = Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        let rows = [pinned, today, pressed]
        let updated = [
            Self.session(index: 0, activity: Self.now.addingTimeInterval(5), isPinned: true),
            today,
            pressed
        ]
        let before = Self.sections(rows)
        let after = Self.sections(updated)
        XCTAssertEqual(before.map(\.bucket), [.yesterday, .today, .yesterday])
        XCTAssertEqual(after.map(\.bucket), [.today, .yesterday])
        XCTAssertNotEqual(before.last?.id, after.last?.id)
        XCTAssertEqual(before.last?.groups.first?.id, after.last?.groups.first?.id)

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressed.tabID)
        // Even bucket/ordinal section IDs are not safe ancestors of the row.
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressed.tabID,
            style: .sectionAndGroupAncestry, survives: false
        )
    }

    func testRenderedRowIdentitySurvivesRootToThreadChildRegrouping() throws {
        let parent = Self.session(index: 0, activity: Self.now)
        let pressed = Self.session(index: 1, activity: Self.now.addingTimeInterval(-30))
        let rows = [parent, pressed]
        let updated = [
            Self.session(index: 0, activity: Self.now, hasThreadChildren: true),
            Self.session(
                index: 1, activity: pressed.activityDate,
                parentSessionID: parent.tabID, depth: 1
            )
        ]
        let before = Self.sections(rows)
        let after = Self.sections(updated)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.first?.groups.map(\.id), [parent.tabID, pressed.tabID])
        XCTAssertEqual(after.first?.groups.map(\.id), [parent.tabID])
        XCTAssertEqual(after.first?.groups.first?.rows.map(\.tabID), [parent.tabID, pressed.tabID])

        try Self.assertRowLifetime(before: rows, after: updated, pressedID: pressed.tabID)
        try Self.assertRowLifetime(
            before: rows, after: updated, pressedID: pressed.tabID,
            style: .sectionAndGroupAncestry, survives: false
        )
    }

    func testDateSectionIdentitySurvivesARunningResort() throws {
        let now = Self.now
        let rows = Self.sessions(now: now)
        let before = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: Self.calendar)
        let promotedID = try XCTUnwrap(rows.last?.tabID)
        let after = AgentSidebarDateSectionBuilder.activeSections(
            for: Self.sessions(now: now, promotedTabID: promotedID),
            now: now,
            calendar: Self.calendar
        )

        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.bucket), [.today])
        XCTAssertNotEqual(before.first?.groups.first?.id, after.first?.groups.first?.id)
    }

    func testSplitRunsOfTheSameDayKeepDistinctSectionIdentities() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let rows = [
            Self.session(index: 0, activity: yesterday, isPinned: true),
            Self.session(index: 1, activity: now),
            Self.session(index: 2, activity: yesterday.addingTimeInterval(-60))
        ]
        let sections = AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: Self.calendar)

        XCTAssertEqual(sections.map(\.bucket), [.yesterday, .today, .yesterday])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    func testArchivedSectionIdentitySurvivesReorderingWithinADay() throws {
        let now = Self.now
        let first = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000001")),
            tab: ComposeTabState(),
            stashedAt: now
        )
        let second = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000002")),
            tab: ComposeTabState(),
            stashedAt: now.addingTimeInterval(-30)
        )
        let info = AgentModeViewModel.SidebarSessionDateInfo(lastEngagementAt: now, activityDate: now)
        let forward = AgentSidebarDateSectionBuilder.archivedSections(
            for: [first, second],
            now: now,
            calendar: Self.calendar,
            dateInfo: { _ in info }
        )
        let reversed = AgentSidebarDateSectionBuilder.archivedSections(
            for: [second, first],
            now: now,
            calendar: Self.calendar,
            dateInfo: { _ in info }
        )

        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
        XCTAssertEqual(forward.map(\.bucket), [.today])
    }

    func testRenderedRowsKeepSectionHeadersThreadOrderAndDepth() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let previous = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -3, to: now))
        let pinned = Self.session(index: 0, activity: yesterday, isPinned: true)
        let parent = Self.session(index: 1, activity: now, hasThreadChildren: true)
        let child = Self.session(
            index: 2,
            activity: now.addingTimeInterval(-20),
            parentSessionID: parent.tabID,
            depth: 1
        )
        let older = Self.session(index: 3, activity: previous)
        let rendered = AgentSidebarDateSectionBuilder.renderedActiveRows(
            for: AgentSidebarDateSectionBuilder.activeSections(
                for: [pinned, parent, child, older],
                now: now,
                calendar: Self.calendar
            )
        )

        XCTAssertEqual(
            rendered.map(\.session.tabID),
            [pinned.tabID, parent.tabID, child.tabID, older.tabID]
        )
        XCTAssertEqual(rendered.map(\.showsHeader), [true, true, false, true])
        XCTAssertEqual(rendered.map(\.isFirstHeader), [true, false, false, false])
        XCTAssertEqual(rendered.map(\.headerTitle), ["Yesterday", "Today", "Today", "Previous"])
        XCTAssertEqual(rendered.map(\.session.depth), [0, 0, 1, 0])
        XCTAssertEqual(rendered.map(\.session.isPinned), [true, false, false, false])
    }

    func testArchivedRenderedRowsKeepOneHeaderPerDay() throws {
        let now = Self.now
        let yesterday = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: -1, to: now))
        let today = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000011")),
            tab: ComposeTabState(),
            stashedAt: now
        )
        let older = try StashedTab(
            id: XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000012")),
            tab: ComposeTabState(),
            stashedAt: yesterday
        )
        let rendered = AgentSidebarDateSectionBuilder.renderedArchivedRows(
            for: AgentSidebarDateSectionBuilder.archivedSections(
                for: [today, older],
                now: now,
                calendar: Self.calendar,
                dateInfo: { tab in
                    AgentModeViewModel.SidebarSessionDateInfo(
                        lastEngagementAt: tab.stashedAt,
                        activityDate: tab.stashedAt
                    )
                }
            )
        )

        XCTAssertEqual(rendered.map(\.row.id), [today.id, older.id])
        XCTAssertEqual(rendered.map(\.showsHeader), [true, true])
        XCTAssertEqual(rendered.map(\.isFirstHeader), [true, false])
        XCTAssertEqual(rendered.map(\.headerTitle), ["Today", "Yesterday"])
    }

    func testFlatRowListMatchesSectionListFrames() {
        let sectionFrames = Self.measureFrames(.sectionForEach)
        let flatFrames = Self.measureFrames(.flatRows)

        XCTAssertEqual(Set(sectionFrames.keys), Set(["H-Yesterday", "H-Today", "H-Previous", "R0", "R1", "R2", "R3"]))
        XCTAssertEqual(sectionFrames.keys.sorted(), flatFrames.keys.sorted())
        for name in sectionFrames.keys.sorted() {
            XCTAssertEqual(
                flatFrames[name]?.minY ?? -1,
                sectionFrames[name]?.minY ?? -2,
                accuracy: 0.5,
                "\(name) vertical position"
            )
            XCTAssertEqual(
                flatFrames[name]?.height ?? -1,
                sectionFrames[name]?.height ?? -2,
                accuracy: 0.5,
                "\(name) height"
            )
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_780_660_800)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func sections(
        _ rows: [AgentModeViewModel.SidebarSession]
    ) -> [AgentSidebarActiveDateSection] {
        AgentSidebarDateSectionBuilder.activeSections(for: rows, now: now, calendar: calendar)
    }

    private static func assertRowLifetime(
        before: [AgentModeViewModel.SidebarSession],
        after: [AgentModeViewModel.SidebarSession],
        pressedID: UUID,
        style: SidebarIdentityList.Style = .current,
        survives: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = NSHostingView(rootView: SidebarIdentityList(sections: sections(before), style: style))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
        host.layoutSubtreeIfNeeded()
        let initialRows = identityRows(in: host)
        XCTAssertEqual(Set(initialRows.compactMap { $0.session?.tabID }), Set(before.map(\.tabID)), file: file, line: line)
        XCTAssertEqual(initialRows.count, before.count, file: file, line: line)
        let pressedRow = try XCTUnwrap(initialRows.first { $0.session?.tabID == pressedID }, file: file, line: line)
        // A row-local marker, not a synthetic gesture/activation implementation.
        // Keeping a strong reference also prevents address reuse from hiding replacement.
        pressedRow.pressedTabID = pressedID

        host.rootView = SidebarIdentityList(sections: sections(after), style: style)
        host.layoutSubtreeIfNeeded()
        let updatedRows = identityRows(in: host)
        XCTAssertNil(host.window, "Identity checks must not require a window", file: file, line: line)
        XCTAssertEqual(Set(updatedRows.compactMap { $0.session?.tabID }), Set(after.map(\.tabID)), file: file, line: line)
        XCTAssertEqual(updatedRows.count, after.count, file: file, line: line)
        let updatedRow = try XCTUnwrap(updatedRows.first { $0.session?.tabID == pressedID }, file: file, line: line)
        XCTAssertEqual(updatedRow.session, after.first { $0.tabID == pressedID }, "The retained row must receive updated content", file: file, line: line)
        XCTAssertEqual(pressedRow === updatedRow, survives, "\(style) effective row identity", file: file, line: line)
        XCTAssertEqual(updatedRow.pressedTabID, survives ? pressedID : nil, "\(style) row-local press state", file: file, line: line)
    }

    private static func identityRows(in view: NSView) -> [SidebarIdentityRowView] {
        (view as? SidebarIdentityRowView).map { [$0] } ?? view.subviews.flatMap { identityRows(in: $0) }
    }

    private static func measureFrames(
        _ style: SidebarLayoutProbe.Style
    ) -> [String: CGRect] {
        let sink = SidebarLayoutFrameSink()
        let host = NSHostingView(rootView: SidebarLayoutProbe(style: style, sink: sink))
        host.frame = CGRect(x: 0, y: 0, width: 280, height: 420)
        host.layoutSubtreeIfNeeded()
        return sink.frames
    }

    private static func sessions(
        now: Date,
        promotedTabID: UUID? = nil
    ) -> [AgentModeViewModel.SidebarSession] {
        let rows = (0 ..< 5).map { index in
            let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
            var activity = now.addingTimeInterval(-Double(40 - index * 10))
            if promotedTabID == tabID {
                activity = now.addingTimeInterval(5)
            }
            return Self.session(index: index, activity: activity)
        }
        return rows.sorted { $0.activityDate > $1.activityDate }
    }

    private static func session(
        index: Int,
        activity: Date,
        isPinned: Bool = false,
        parentSessionID: UUID? = nil,
        depth: Int = 0,
        hasThreadChildren: Bool = false,
        title: String? = nil
    ) -> AgentModeViewModel.SidebarSession {
        let tabID = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(index)")!
        return AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title ?? "Running \(index)",
            lastUserMessageAt: nil,
            activityDate: activity,
            isPinned: isPinned,
            sessionID: tabID,
            parentSessionID: parentSessionID,
            depth: depth,
            isMCPControlled: false,
            hasThreadChildren: hasThreadChildren
        )
    }
}

/// The production list supplies identity and header ancestry; only the row
/// content is replaced with an inspectable AppKit lifetime probe.
private struct SidebarIdentityList: View {
    enum Style {
        case current
        case firstRowSectionIdentity
        case sectionAndGroupAncestry
    }

    let sections: [AgentSidebarActiveDateSection]
    let style: Style

    var body: some View {
        VStack(spacing: 2) {
            switch style {
            case .current:
                AgentSidebarKeyedRowList(
                    items: AgentSidebarDateSectionBuilder.renderedActiveRows(for: sections),
                    showsHeader: \.showsHeader,
                    headerTitle: \.headerTitle,
                    isFirstHeader: \.isFirstHeader
                ) { item in
                    SidebarIdentityRow(session: item.session)
                }
            case .firstRowSectionIdentity:
                // Before ebf21f155, a section was keyed by its first row.
                // Recreate that changing ancestor even with today's builder.
                ForEach(sections) { section in
                    legacySection(section)
                        .id(section.groups.first?.id)
                }
            case .sectionAndGroupAncestry:
                // Stable day/ordinal sections alone still replace a row when
                // its section ordinal or thread-group ancestry changes.
                ForEach(sections) { section in
                    legacySection(section)
                }
            }
        }
    }

    private func legacySection(_ section: AgentSidebarActiveDateSection) -> some View {
        ForEach(section.groups) { group in
            ForEach(group.rows) { session in
                SidebarIdentityRow(session: session)
            }
        }
    }
}

private struct SidebarIdentityRow: NSViewRepresentable {
    let session: AgentModeViewModel.SidebarSession

    func makeNSView(context _: Context) -> SidebarIdentityRowView {
        SidebarIdentityRowView()
    }

    func updateNSView(_ view: SidebarIdentityRowView, context _: Context) {
        view.session = session
    }
}

private final class SidebarIdentityRowView: NSView {
    var session: AgentModeViewModel.SidebarSession?
    var pressedTabID: UUID?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: 36)
    }
}

private struct SidebarLayoutFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

@MainActor
private final class SidebarLayoutFrameSink {
    var frames: [String: CGRect] = [:]
}

private struct SidebarLayoutProbe: View {
    enum Style {
        case sectionForEach
        case flatRows
    }

    let style: Style
    let sink: SidebarLayoutFrameSink

    var body: some View {
        stack
            .coordinateSpace(name: "probe")
            .frame(width: 280, alignment: .top)
            .onPreferenceChange(SidebarLayoutFrameKey.self) { sink.frames = $0 }
    }

    @ViewBuilder
    private var stack: some View {
        switch style {
        case .sectionForEach:
            VStack(spacing: 2) {
                ForEach(Self.sections, id: \.title) { section in
                    marker(section.title, minHeight: nil, top: section.isFirst ? 2 : 14, bottom: 4)
                    ForEach(section.rows, id: \.self) { name in
                        marker(name, minHeight: 36, top: 0, bottom: 0)
                    }
                }
            }
        case .flatRows:
            VStack(spacing: 2) {
                ForEach(Array(Self.flatItems.enumerated()), id: \.offset) { _, item in
                    if let header = item.header {
                        marker(header, minHeight: nil, top: item.isFirst ? 2 : 14, bottom: 4)
                    }
                    marker(item.row, minHeight: 36, top: 0, bottom: 0)
                }
            }
        }
    }

    private func marker(
        _ name: String,
        minHeight: CGFloat?,
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        Text(verbatim: name)
            .frame(
                maxWidth: .infinity,
                minHeight: minHeight,
                maxHeight: minHeight,
                alignment: .leading
            )
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarLayoutFrameKey.self,
                        value: [name: proxy.frame(in: .named("probe"))]
                    )
                }
            }
    }

    private static let sections: [(title: String, isFirst: Bool, rows: [String])] = [
        ("H-Yesterday", true, ["R0"]),
        ("H-Today", false, ["R1", "R2"]),
        ("H-Previous", false, ["R3"])
    ]

    private static let flatItems: [(header: String?, isFirst: Bool, row: String)] = [
        ("H-Yesterday", true, "R0"),
        ("H-Today", false, "R1"),
        (nil, false, "R2"),
        ("H-Previous", false, "R3")
    ]
}

/// #1373: a session switch, a global link-candidate notification, or an unrelated prompt publish
/// must re-render only the rows whose rendered values changed — not every pinned row.
///
/// Pinned rows are exempt from the page cap, so a workspace with hundreds of pins renders hundreds
/// of rows. These tests host the real sidebar with 500 pinned sessions and count actual
/// `AgentSessionRow` body evaluations.
@MainActor
final class AgentSidebarRowInvalidationTests: XCTestCase {
    private static let rowCount = 500

    @MainActor
    private struct Fixture {
        let state: WindowState
        let tabs: [ComposeTabState]
        let host: NSHostingView<AgentModeSessionsSidebarView>
        let window: NSWindow

        var vm: AgentModeViewModel {
            state.agentModeViewModel
        }
    }

    private var renderedTitles: [String] = []
    private var changedModelFields: Set<String> = []

    override func setUp() async throws {
        try await super.setUp()
        renderedTitles = []
        changedModelFields = []
        AgentSidebarRowRenderProbe.onSessionRowBody = { [weak self] title in
            self?.renderedTitles.append(title)
        }
        AgentSidebarRowRenderProbe.onActiveRowModelChange = { [weak self] old, new in
            self?.changedModelFields.formUnion(Self.changedFields(old, new))
        }
    }

    override func tearDown() async throws {
        AgentSidebarRowRenderProbe.onSessionRowBody = nil
        AgentSidebarRowRenderProbe.onActiveRowModelChange = nil
        try await super.tearDown()
    }

    // MARK: - Real sidebar

    func testSessionSwitchReRendersOnlyTheTwoRowsWhoseSelectionChanged() async throws {
        let fixture = try await makeFixture()
        XCTAssertGreaterThanOrEqual(
            Set(renderedTitles).count, Self.rowCount,
            "Sanity: the pin-exempt page must actually render every pinned row"
        )
        // Warm both tabs: a first visit may legitimately capture live editor state into the tab.
        // The issue's acceptance target is a warm switch between already-visited sessions.
        for tab in [fixture.tabs[1], fixture.tabs[0]] {
            await fixture.state.promptManager.switchComposeTab(tab.id)
            await render(fixture, currentTabID: tab.id)
        }
        try await settle(fixture)
        let rowBuildsBefore = fixture.vm.test_sidebarSessionRowsBuildCount
        let rowContentRevisionBefore = fixture.vm.ui.sessionSidebar.snapshot.rowContentRevision
        let fingerprintBefore = fixture.vm.makeSessionSidebarContentFingerprint()
        renderedTitles = []

        // The production chain (`.activeComposeTabChanged` → `onTabChanged` → `syncAllActiveUIState`)
        // runs the sidebar sync; the selected tab must not count as row content.
        await fixture.state.promptManager.switchComposeTab(fixture.tabs[1].id)
        XCTAssertEqual(fixture.vm.currentTabID, fixture.tabs[1].id)
        await render(fixture, currentTabID: fixture.tabs[1].id)

        XCTAssertEqual(
            Set(renderedTitles), [fixture.tabs[0].name, fixture.tabs[1].name],
            "Only the previously and newly active rows may re-render; got \(Set(renderedTitles).count) rows, changed: \(changedModelFields.sorted())"
        )
        let fingerprintDelta = fixture.vm.makeSessionSidebarContentFingerprint()
            .debugDeltaDiagnostics(from: fingerprintBefore).categories
        XCTAssertEqual(
            fixture.vm.ui.sessionSidebar.snapshot.rowContentRevision, rowContentRevisionBefore,
            "A selection change is not row content and must not force a full row rebuild; changed: \(fingerprintDelta)"
        )
        XCTAssertEqual(fixture.vm.test_sidebarSessionRowsBuildCount, rowBuildsBefore)
    }

    func testUnchangedSessionLinkNotificationsReRenderNoRows() async throws {
        let fixture = try await makeFixture()
        renderedTitles = []
        changedModelFields = []

        NotificationCenter.default.post(name: .agentSessionLinkCandidatesDidChange, object: nil)
        NotificationCenter.default.post(name: .agentSessionLinkOverseerProjectionDidChange, object: fixture.vm)
        await render(fixture, currentTabID: fixture.tabs[0].id)

        XCTAssertEqual(
            Set(renderedTitles).count, 0,
            "Notifications that change no rendered row facts must not re-render rows; changed: \(changedModelFields.sorted())"
        )
    }

    func testBackgroundRunStateChangeReRendersOnlyThatRow() async throws {
        let fixture = try await makeFixture()
        let session = fixture.vm.session(for: fixture.tabs[5].id)
        session.runState = .idle
        fixture.vm.observeSidebarRunStateTransition(for: session)
        await render(fixture, currentTabID: fixture.tabs[0].id)
        renderedTitles = []

        session.runState = .completed
        fixture.vm.observeSidebarRunStateTransition(for: session)
        await render(fixture, currentTabID: fixture.tabs[0].id)

        XCTAssertEqual(Set(renderedTitles), [fixture.tabs[5].name], "Only the transitioned row may re-render")
    }

    func testOversightLinkChangeReRendersOnlyTheLinkedRows() async throws {
        let fixture = try await makeFixture()
        renderedTitles = []
        let observerID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let targetID = try XCTUnwrap(fixture.tabs[1].activeAgentSessionID)

        let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
            observerSessionID: observerID, rawTargetSessionID: targetID.uuidString
        )
        guard case .added = outcome else { return XCTFail("Real bridge grant failed: \(outcome)") }
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        await render(fixture, currentTabID: fixture.tabs[0].id)

        XCTAssertEqual(
            Set(renderedTitles), [fixture.tabs[0].name, fixture.tabs[1].name],
            "Exactly the observer and target rows must re-render; changed: \(changedModelFields.sorted())"
        )
    }

    /// The verbatim Copy Session ID fallback revalidates the row's identity at click time, and the
    /// preparation task re-keys on its live preconditions rather than only the session ID.
    func testCopyFallbackRevalidatesAndPreparationKeyTracksPreconditions() async throws {
        let fixture = try await makeFixture()
        let actions = AgentSidebarActiveRowActions()
        actions.bind(agentModeVM: fixture.vm, promptManager: fixture.state.promptManager)
        let workspaceID = fixture.vm.workspaceManager?.activeWorkspaceID
        let tab = fixture.tabs[7]
        let sessionID = try XCTUnwrap(tab.activeAgentSessionID)

        XCTAssertTrue(actions.isCurrentRowSessionID(sessionID, tabID: tab.id, workspaceID: workspaceID))
        XCTAssertFalse(actions.isCurrentRowSessionID(UUID(), tabID: tab.id, workspaceID: workspaceID), "Stale session ID")
        XCTAssertFalse(actions.isCurrentRowSessionID(sessionID, tabID: tab.id, workspaceID: UUID()), "Other workspace")

        // A bound row with an exact endpoint needs no preparation.
        let boundRow = AgentModeViewModel.SidebarSession(
            id: tab.id, tabID: tab.id, title: tab.name, lastUserMessageAt: nil, activityDate: Date(),
            isPinned: true, sessionID: sessionID, parentSessionID: nil, depth: 0, isMCPControlled: false,
            hasThreadChildren: false
        )
        XCTAssertNil(actions.oversightFacts(for: boundRow).preparationKey)

        // A row whose live session is not yet bound to its ID carries a key that follows hydration.
        let unpreparedRow = AgentModeViewModel.SidebarSession(
            id: tab.id, tabID: tab.id, title: tab.name, lastUserMessageAt: nil, activityDate: Date(),
            isPinned: true, sessionID: UUID(), parentSessionID: nil, depth: 0, isMCPControlled: false,
            hasThreadChildren: false
        )
        let session = fixture.vm.session(for: tab.id)
        session.hasLoadedPersistedState = false
        let loadingKey = try XCTUnwrap(actions.oversightFacts(for: unpreparedRow).preparationKey)
        session.hasLoadedPersistedState = true
        let loadedKey = try XCTUnwrap(actions.oversightFacts(for: unpreparedRow).preparationKey)
        XCTAssertFalse(loadingKey.hasLoadedPersistedState)
        XCTAssertTrue(loadedKey.hasLoadedPersistedState)
        XCTAssertNotEqual(loadingKey, loadedKey, "Hydration settling must re-key the preparation task")
    }

    /// Headers are bucketed against a day anchor held in list state. A quiet midnight changes no
    /// row model, so only the calendar day-change notification can relabel "Today" as "Yesterday".
    func testCalendarDayChangeRelabelsDateHeadersWithoutOtherUpdates() async throws {
        let fixture = try await makeFixture()
        var headers: [String] = []
        AgentSidebarRowRenderProbe.onActiveRowsRendered = { rows in
            headers = rows.filter(\.showsHeader).map(\.headerTitle)
        }
        defer {
            AgentSidebarRowRenderProbe.onActiveRowsRendered = nil
            AgentSidebarDayClock.now = { Date() }
        }
        fixture.vm.ui.sessionSidebar.refresh()
        await render(fixture, currentTabID: fixture.tabs[0].id)
        XCTAssertEqual(headers.first, "Today", "Precondition: fixture rows were active today")

        let calendar = Calendar.current
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
        AgentSidebarDayClock.now = { tomorrow.addingTimeInterval(60) }
        headers = []
        // A list re-render after midnight still buckets against the held anchor, not the wall clock.
        fixture.vm.ui.sessionSidebar.refresh()
        await render(fixture, currentTabID: fixture.tabs[0].id)
        XCTAssertEqual(headers.first, "Today", "Without the day-change signal the list keeps its day anchor")
        headers = []

        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await render(fixture, currentTabID: fixture.tabs[0].id)
        XCTAssertEqual(headers.first, "Yesterday", "The day-change notification must relabel the headers")
    }

    /// The persistence presentation overlays `observerIneligibleReason` onto marked rows' summaries
    /// without posting a sidebar invalidation, and closed rows never render it. Recorded facts must
    /// not carry it, or the next unrelated notification re-renders every marked row for nothing.
    func testPersistencePresentationChangeDoesNotDriftRecordedRowFacts() async throws {
        let fixture = try await makeFixture()
        let observerID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let targetID = try XCTUnwrap(fixture.tabs[1].activeAgentSessionID)
        let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
            observerSessionID: observerID, rawTargetSessionID: targetID.uuidString
        )
        guard case .added = outcome else { return XCTFail("Real bridge grant failed: \(outcome)") }
        try await settle(fixture)
        renderedTitles = []
        changedModelFields = []

        fixture.vm.agentSessionLinkApplyPersistencePresentation(.init(availability: .blocked("Saved links are read-only.")))
        XCTAssertNotNil(
            fixture.vm.agentSidebarOversightSummary(tabID: fixture.tabs[1].id, expectedSessionID: targetID)?
                .observerIneligibleReason,
            "Precondition: the live summary now carries the persistence blocker"
        )
        NotificationCenter.default.post(name: .agentSessionLinkCandidatesDidChange, object: nil)
        await render(fixture, currentTabID: fixture.tabs[0].id)

        XCTAssertEqual(
            Set(renderedTitles).count, 0,
            "A persistence-only change must not re-render rows; changed: \(changedModelFields.sorted())"
        )
    }

    /// A freshly mounted list must resolve oversight facts on its very first render. Resolving them
    /// before the action owner is bound produced `.none`, which equality and the notification
    /// filter then kept: no role marks, creator labels, or Copy Session ID until an unrelated change.
    func testFreshlyMountedSidebarShowsOversightFactsOnFirstRender() async throws {
        let fixture = try await makeFixture()
        let observerID = try XCTUnwrap(fixture.tabs[0].activeAgentSessionID)
        let targetID = try XCTUnwrap(fixture.tabs[1].activeAgentSessionID)
        let outcome = await AgentSessionLinkRuntimeBridge.shared.addMonitorLink(
            observerSessionID: observerID, rawTargetSessionID: targetID.uuidString
        )
        guard case .added = outcome else { return XCTFail("Real bridge grant failed: \(outcome)") }
        try await settle(fixture)

        var firstModels: [UUID: AgentSidebarActiveRowModel] = [:]
        AgentSidebarRowRenderProbe.onActiveRowBody = { model in
            if firstModels[model.session.tabID] == nil { firstModels[model.session.tabID] = model }
        }
        defer { AgentSidebarRowRenderProbe.onActiveRowBody = nil }
        let freshHost = NSHostingView(rootView: sidebar(for: fixture.state, tabID: fixture.tabs[0].id))
        freshHost.frame = fixture.host.frame
        freshHost.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(firstModels[fixture.tabs[1].id], "The target row must render on first mount")
        XCTAssertTrue(target.oversight.role.hasMark, "The overseen row must show its role mark on first render")
        XCTAssertNotNil(target.oversight.targetEndpoint)
        XCTAssertEqual(firstModels.count, Self.rowCount)
        XCTAssertTrue(
            firstModels.values.allSatisfy { $0.oversight.copySessionIDTarget != nil },
            "Every bound top-level row must offer Copy Session ID on first render"
        )
    }

    func testUnrelatedPromptPublishReRendersNoRows() async throws {
        let fixture = try await makeFixture()
        renderedTitles = []

        fixture.state.promptManager.promptText = "unrelated draft text"
        fixture.state.promptManager.instructionsHeight += 10
        await render(fixture, currentTabID: fixture.tabs[0].id)

        XCTAssertEqual(renderedTitles, [], "Prompt publishes the sidebar never reads must not re-render rows")
    }

    /// Clicks are not deliverable in CI XCTest (see `AgentSidebarRunningTapTests`), so this pins the
    /// property a press depends on: the pressed row's native view survives a switch, a forced row
    /// rebuild, and a link notification landing mid-press.
    func testRowNativeViewsSurviveSidebarUpdatesDuringAPress() async throws {
        let fixture = try await makeFixture()
        let before = rowRegions(in: fixture.host)
        XCTAssertEqual(before.count, Self.rowCount)

        await fixture.state.promptManager.switchComposeTab(fixture.tabs[1].id)
        fixture.vm.ui.sessionSidebar.refresh()
        NotificationCenter.default.post(name: .agentSessionLinkCandidatesDidChange, object: nil)
        await render(fixture, currentTabID: fixture.tabs[1].id)

        let after = rowRegions(in: fixture.host)
        XCTAssertEqual(
            Set(before.map(ObjectIdentifier.init)), Set(after.map(ObjectIdentifier.init)),
            "Every row, including a pressed one, must keep its native view across sidebar updates"
        )
    }

    // MARK: - Control: the pre-fix row shape

    /// Rows whose action closures capture values are incomparable, so every parent re-render
    /// re-evaluates every row body. This is the shape the sidebar used before #1373 (its closures
    /// captured the row session and list snapshot); the probe must detect it as O(N).
    func testControlClosureCarryingRowsReRenderEveryRow() {
        let titles = (0 ..< Self.rowCount).map { "Control \($0)" }
        let host = NSHostingView(rootView: LegacyClosureRowList(titles: titles, activeIndex: 0))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        host.layoutSubtreeIfNeeded()
        renderedTitles = []

        host.rootView = LegacyClosureRowList(titles: titles, activeIndex: 1)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            Set(renderedTitles).count, Self.rowCount,
            "Closure-carrying rows re-render every row for a two-row selection change"
        )
    }

    // MARK: - Fixture

    private static func changedFields(_ old: AgentSidebarActiveRowModel, _ new: AgentSidebarActiveRowModel) -> Set<String> {
        var fields: Set<String> = []
        if old.session != new.session { fields.insert("session") }
        if old.workspaceID != new.workspaceID { fields.insert("workspaceID") }
        if old.isActive != new.isActive { fields.insert("isActive") }
        if old.runState != new.runState { fields.insert("runState") }
        if old.attentionRunState != new.attentionRunState { fields.insert("attentionRunState") }
        if old.oversight.role != new.oversight.role { fields.insert("oversight.role") }
        if old.oversight.summary != new.oversight.summary { fields.insert("oversight.summary") }
        if old.oversight.targetEndpoint != new.oversight.targetEndpoint { fields.insert("oversight.targetEndpoint") }
        if old.oversight.creatorSessionID != new.oversight.creatorSessionID { fields.insert("oversight.creator") }
        if old.oversight.copySessionIDTarget != new.oversight.copySessionIDTarget { fields.insert("oversight.copyTarget") }
        if old.isSelected != new.isSelected { fields.insert("isSelected") }
        if old.showsSelectionPresentation != new.showsSelectionPresentation { fields.insert("showsSelectionPresentation") }
        if old.isInteractionEnabled != new.isInteractionEnabled { fields.insert("isInteractionEnabled") }
        if old.commandProgressKind != new.commandProgressKind { fields.insert("commandProgressKind") }
        return fields
    }

    private func render(_ fixture: Fixture, currentTabID: UUID) async {
        // Session-link and snapshot publishers deliver on the next main-queue turn.
        for _ in 0 ..< 3 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        fixture.host.rootView = sidebar(for: fixture.state, tabID: currentTabID)
        fixture.host.layoutSubtreeIfNeeded()
        await Task.yield()
        fixture.host.layoutSubtreeIfNeeded()
    }

    private func rowRegions(in view: NSView) -> [StableMenuContextView] {
        (view as? StableMenuContextView).map { [$0] } ?? view.subviews.flatMap { rowRegions(in: $0) }
    }

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        addTeardownBlock {
            await MainActor.run {
                GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false)
            }
        }
        let state = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let vm = AgentModeViewModel(
                    testWindowID: windowID,
                    codexControllerFactory: { _, _, _, _, _, _ in
                        LifecycleNoopCodexController(recorder: LifecycleRecorder())
                    },
                    claudeControllerFactory: { _, _, _, _ in MonitorFakeNativeController() },
                    headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) },
                    acpProviderFactory: { _, _ in throw ProviderLaunchRefused.refused },
                    acpControllerFactory: { _, _ in throw ProviderLaunchRefused.refused },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                    mcpRunRoutingCleaner: { _, _, _ in },
                    mcpServerEnabler: { false },
                    testMCPServer: server,
                    testWorkspaceFileContextStore: prompt.workspaceFileContextStore
                )
                vm.promptManager = prompt
                vm.workspaceManager = manager
                return vm
            },
            contextBuilderProviderFactory: { _, _, _, _ in
                AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            }
        )
        addTeardownBlock {
            await state.tearDown()
        }
        await state.workspaceManager.awaitInitialized()
        let tabs = (0 ..< Self.rowCount).map { index in
            ComposeTabState(name: "Pinned \(index)", isPinned: true, activeAgentSessionID: UUID())
        }
        let workspace = WorkspaceModel(
            name: "Pinned sidebar workload", repoPaths: [], ephemeralFlag: true,
            composeTabs: tabs, activeComposeTabID: tabs[0].id
        )
        state.workspaceManager.workspaces = [workspace]
        let switched = await state.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "sidebarRowInvalidationTest")
        XCTAssertEqual(switched, .switched)
        state.promptManager.loadComposeTabsFromWorkspace(workspace)
        let vm = state.agentModeViewModel
        await vm.handleWorkspaceSwitch(workspace)
        vm.test_setCurrentTabIDOverride(tabs[0].id)
        _ = await vm.ensureSessionReady(tabID: tabs[0].id)
        for tab in tabs {
            let session = vm.session(for: tab.id)
            _ = vm.test_installPersistentSessionBinding(sessionID: tab.activeAgentSessionID, on: session, updateWorkspaceMetadata: true)
            session.hasLoadedPersistedState = true
            // Each pinned row is an existing restored conversation, as in the hosted menu fixture.
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.items = [AgentChatItem(kind: .user, text: "Pinned fixture message")]
        }
        WindowStatesManager.shared.registerWindowState(state)
        addTeardownBlock {
            await MainActor.run {
                WindowStatesManager.shared.unregisterWindowState(state)
            }
        }
        // Real production wiring: switches travel `.activeComposeTabChanged` → `onTabChanged` →
        // `syncAllActiveUIState`, and the current tab comes from the prompt manager, not an override.
        vm.test_setupObservers()
        vm.test_setCurrentTabIDOverride(nil)
        XCTAssertEqual(vm.currentTabID, tabs[0].id)
        vm.setAgentModeActive(true)
        await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
        vm.syncSidebarUIState(refresh: true, reason: .runState, sidebarTabs: tabs)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock {
            await MainActor.run {
                window.close()
            }
        }
        let host = NSHostingView(rootView: sidebar(for: state, tabID: tabs[0].id))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let fixture = Fixture(state: state, tabs: tabs, host: host, window: window)
        // Settle startup publications before any measurement.
        try await settle(fixture)
        return fixture
    }

    private struct SettleSignature: Equatable {
        var rows: [String]
        var sessionIndex: [UUID: AgentSessionIndexEntry]
        var restorePresentation: AgentModeViewModel.SidebarRestorePresentationKey
        var sessionListCacheReady: Bool

        var isSettled: Bool {
            !rows.contains("pending") && sessionListCacheReady && !restorePresentation.isOwnerPending
                && restorePresentation.baselineRevision == nil
        }
    }

    /// Workspace activation hydrates every bound tab in the background, and the debounced save
    /// later upserts each session's index entry. With hundreds of tabs that outlives a few run-loop
    /// turns, so measurements start only once pending saves are flushed and the endpoints, copy
    /// targets, session index and restore-presentation release are all present and unchanged.
    private func settle(_ fixture: Fixture) async throws {
        func signature() -> SettleSignature {
            SettleSignature(
                rows: fixture.tabs.map { tab in
                    guard let sessionID = tab.activeAgentSessionID,
                          let endpoint = fixture.vm.agentSidebarOversightTargetEndpoint(tabID: tab.id, expectedSessionID: sessionID),
                          let copyTarget = fixture.vm.agentSessionCopyIDTarget(tabID: tab.id, sessionID: sessionID, tabName: tab.name)
                    else { return "pending" }
                    return "\(endpoint)|\(copyTarget)"
                },
                sessionIndex: fixture.vm.ownerValidatedSessionIndex,
                restorePresentation: fixture.vm.sidebarRestorePresentationKey,
                sessionListCacheReady: fixture.vm.ownerValidatedSessionListCacheReady
            )
        }
        func flushPendingSaves() async -> Bool {
            let pending = fixture.tabs.filter { fixture.vm.sessions[$0.id]?.saveDebounceTask != nil }
            for tab in pending {
                await fixture.vm.flushSave(for: tab.id)
                fixture.vm.sessions[tab.id]?.saveDebounceTask = nil
            }
            return !pending.isEmpty
        }
        var previous: SettleSignature?
        for _ in 0 ..< 300 {
            let flushed = await flushPendingSaves()
            await AgentSessionLinkRuntimeBridge.shared.test_settleProjections()
            await render(fixture, currentTabID: fixture.vm.currentTabID ?? fixture.tabs[0].id)
            let current = signature()
            if !flushed, current == previous, current.isSettled { return }
            previous = current
        }
        let last = signature()
        XCTFail("""
        Settle state: cacheReady=\(last.sessionListCacheReady) \
        ownerPending=\(last.restorePresentation.isOwnerPending) \
        baselineRevision=\(String(describing: last.restorePresentation.baselineRevision)) \
        indexCount=\(last.sessionIndex.count)
        """)
        let probe = fixture.tabs[2]
        let probeSessionID = probe.activeAgentSessionID ?? UUID()
        let endpoint = fixture.vm.agentSidebarOversightTargetEndpoint(tabID: probe.id, expectedSessionID: probeSessionID)
        let candidate = fixture.vm.agentSessionLinkCandidate(
            tabID: probe.id, sessionID: probeSessionID, tabName: probe.name, isWindowClosing: false
        )
        let session = fixture.vm.session(for: probe.id)
        XCTFail("""
        Fixture never settled: \((previous?.rows ?? []).count { $0 == "pending" }) rows pending; \
        probe endpoint=\(endpoint != nil) candidate=\(candidate != nil) \
        failure=\(String(describing: candidate.flatMap(AgentSessionLinkEndpointEligibility.targetResolveFailure(for:)))) \
        loaded=\(session.hasLoadedPersistedState) loadTask=\(session.persistedLoadTask != nil) \
        transition=\(session.bindingTransitionInProgress) active=\(String(describing: session.activeAgentSessionID == probeSessionID))
        """)
    }

    private func sidebar(for state: WindowState, tabID: UUID) -> AgentModeSessionsSidebarView {
        AgentModeSessionsSidebarView(
            rootsStore: AgentWorkspaceRootsSidebarStore(
                rootProjections: { [] }, rootChanges: Empty<Void, Never>().eraseToAnyPublisher(),
                workspaceManager: state.workspaceManager, windowID: state.windowID
            ),
            agentModeVM: state.agentModeViewModel, sidebarUI: state.agentModeViewModel.ui.sessionSidebar,
            promptManager: state.promptManager, apiSettingsVM: state.apiSettingsViewModel,
            currentTabID: tabID, onManageWorkspaces: {}
        )
    }

    private enum ProviderLaunchRefused: Error { case refused }
}

/// The pre-#1373 row shape: `AgentSessionRow` built inline with fresh action closures.
private struct LegacyClosureRowList: View {
    let titles: [String]
    let activeIndex: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                let title = titles[index]
                let activeIndex = activeIndex
                AgentSessionRow(
                    title: titles[index],
                    isActive: index == activeIndex,
                    isPinned: true,
                    isMCPControlled: false,
                    runState: .idle,
                    threadDepth: 0,
                    onSelectionGesture: { _ in index == activeIndex ? .ignored : .activate },
                    onSelect: { _ = title },
                    onTogglePin: { _ = title },
                    onDelete: { _ = title },
                    onRename: { _ = ($0, title) },
                    sessionIDCopyAction: .systemClipboard(sessionID: nil)
                )
            }
        }
    }
}
