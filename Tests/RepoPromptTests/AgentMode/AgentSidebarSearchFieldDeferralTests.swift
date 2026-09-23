@testable import RepoPromptApp
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

    private func row(tabID: UUID, title: String) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: tabID,
            tabID: tabID,
            title: title,
            lastUserMessageAt: nil,
            activityDate: Date(timeIntervalSince1970: 0),
            isPinned: false,
            sessionID: nil,
            parentSessionID: nil,
            depth: 0,
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
