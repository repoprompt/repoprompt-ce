@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentWorkspaceSessionIndexStoreNotificationCoalescingTests: XCTestCase {
    func testCombinedIndexAndSortDateReplacementNotifiesOnceAfterBothValuesSettle() {
        let workspaceID = id(1)
        let tabID = id(2)
        let sessionID = id(3)
        let delegate = Delegate(workspaceID: workspaceID)
        let store = AgentWorkspaceSessionIndexStore()
        store.delegate = delegate
        let owner = AgentWorkspaceSessionIndexStore.SessionIndexOwner(
            workspaceID: workspaceID,
            activationEpoch: 1
        )
        store.test_installOwnerState(owner: owner, latestOwner: owner)

        let entry = AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Large workspace row",
            lastUserMessageAt: Date(timeIntervalSince1970: 200),
            savedAt: Date(timeIntervalSince1970: 100),
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )

        store.setSessionIndexAndRebuildSortDates([sessionID: entry])

        XCTAssertEqual(delegate.notifications.count, 1)
        XCTAssertEqual(delegate.notifications.first?.indexCount, 1)
        XCTAssertEqual(delegate.notifications.first?.sortDateCount, 1)
        guard case .sessionIndex? = delegate.notifications.first?.reason else {
            return XCTFail("the combined replacement should publish one session-index change")
        }
    }

    // MARK: - Restoration baseline join (§5.2/§5.5/§5.6)

    func testInstallCapturesMetadataOnlyBaselineAndPendingJoinWithOneNotification() {
        let fixture = makeInstalledStore()
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.sessionIndex])
        let baseline = fixture.store.ownerValidatedSidebarRestoreBaseline
        XCTAssertNotNil(baseline)
        // Persisted recency (T2 newest, then T3, then T1), not raw array order.
        XCTAssertEqual(baseline?.entries[id(12)]?.ordinal, 0)
        XCTAssertEqual(baseline?.entries[id(13)]?.ordinal, 1)
        XCTAssertEqual(baseline?.entries[id(11)]?.ordinal, 2)
        XCTAssertEqual(baseline?.entries[id(11)]?.bucket, .previous)
        XCTAssertEqual(fixture.store.ownerValidatedSidebarRestoreJoin?.index, .pending(generation: nil))
        XCTAssertEqual(fixture.store.ownerValidatedSidebarRestoreJoin?.selected, .discovering)
        XCTAssertEqual(fixture.store.ownerValidatedSidebarRestoreJoin?.initialTabID, id(12))
        XCTAssertEqual(fixture.store.ownerValidatedSidebarRestoreJoin?.initialBindingID, id(112))
    }

    func testFirstSideNeverReleasesAndBothCompletionOrdersReleaseOnce() {
        for indexFirst in [true, false] {
            let fixture = makeInstalledStore()
            let store = fixture.store
            let owner = fixture.owner
            fixture.delegate.notifications.removeAll()
            store.beginSidebarRestoreIndex(generation: 7, owner: owner)
            let final = [id(112): entry(id(112), tabID: id(12))]
            if indexFirst {
                XCTAssertTrue(store.recordSidebarRestoreIndexTerminal(generation: 7, owner: owner, outcome: .success, entries: final, ready: true))
            } else {
                store.recordSidebarRestoreSelected(.settled(.restoration(.payloadApplied)), owner: owner)
            }
            XCTAssertTrue(fixture.delegate.notifications.isEmpty, "first side must not release (indexFirst=\(indexFirst))")
            XCTAssertNotNil(store.ownerValidatedSidebarRestoreBaseline)
            XCTAssertFalse(store.ownerValidatedSessionListCacheReady, "readiness waits for the join")
            XCTAssertTrue(store.ownerValidatedSessionIndex.isEmpty, "terminal metadata is staged, not published")
            if indexFirst {
                store.recordSidebarRestoreSelected(.settled(.restoration(.payloadApplied)), owner: owner)
            } else {
                XCTAssertTrue(store.recordSidebarRestoreIndexTerminal(generation: 7, owner: owner, outcome: .success, entries: final, ready: true))
            }
            XCTAssertEqual(fixture.delegate.notifications.count, 1)
            let release = fixture.delegate.notifications.first
            XCTAssertEqual(release?.reason, .restoreProjection)
            XCTAssertEqual(release?.indexCount, 1, "final index installed before the notification")
            XCTAssertEqual(release?.sortDateCount, 1, "derived sort dates installed before the notification")
            XCTAssertEqual(release?.ready, true)
            XCTAssertEqual(release?.baselineReleased, true)
            XCTAssertNil(store.sidebarRestoreJoin)
        }
    }

    func testStaleTokenReplacementAndDuplicateSettlementsNeitherNotifyNorRelease() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        let owner = fixture.owner
        fixture.delegate.notifications.removeAll()
        store.beginSidebarRestoreIndex(generation: 1, owner: owner)
        // Same-owner replacement refresh transfers the pending side without release.
        store.beginSidebarRestoreIndex(generation: 2, owner: owner)
        store.recordSidebarRestoreIndexTerminal(generation: 1, owner: owner, outcome: .success, entries: [:], ready: true)
        store.recordSidebarRestoreSelected(.settled(.restoration(.fresh)), owner: owner)
        store.recordSidebarRestoreSelected(.settled(.selectionChanged), owner: owner)
        XCTAssertTrue(fixture.delegate.notifications.isEmpty)
        XCTAssertEqual(store.ownerValidatedSidebarRestoreJoin?.index, .pending(generation: 2))
        XCTAssertEqual(store.ownerValidatedSidebarRestoreJoin?.selected, .settled(.restoration(.fresh)), "settled side never re-arms")
        store.recordSidebarRestoreIndexTerminal(generation: 2, owner: owner, outcome: .success, entries: [:], ready: true)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
        store.recordSidebarRestoreSelected(.settled(.restoration(.missing)), owner: owner)
        XCTAssertFalse(store.recordSidebarRestoreIndexTerminal(generation: 2, owner: owner, outcome: .success, entries: [:], ready: true))
        XCTAssertEqual(fixture.delegate.notifications.count, 1, "duplicate/stale callbacks after release do not notify")
    }

    func testFailureReleasesRefreshBaselineEntriesWithLatestLocalOverlayAndReadyFalse() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        let owner = fixture.owner
        store.beginSidebarRestoreIndex(generation: 3, owner: owner)
        let local = entry(id(113), tabID: id(13))
        store.applyLocalUpsert(local)
        store.applyLocalRemoval(sessionID: id(111))
        fixture.delegate.notifications.removeAll()
        let rollback = [id(111): entry(id(111), tabID: id(11)), id(112): entry(id(112), tabID: id(12))]
        store.recordSidebarRestoreIndexTerminal(generation: 3, owner: owner, outcome: .failed, entries: rollback, ready: false)
        store.recordSidebarRestoreSelected(.settled(.restoration(.loadFailed)), owner: owner)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
        XCTAssertEqual(Set(store.ownerValidatedSessionIndex.keys), [id(112), id(113)], "local overlay wins over staged entries")
        XCTAssertFalse(store.ownerValidatedSessionListCacheReady, "failure is terminal with ready false")
        XCTAssertNil(store.ownerValidatedSidebarRestoreBaseline)
        XCTAssertNil(store.sidebarAutoArchiveOwner(workspaceID: fixture.workspace.id), "auto-archive never observes unready metadata")
    }

    func testDeferredInactiveIndexKeepsBaselineUntilSameOwnerReactivatesAndCompletes() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        let owner = fixture.owner
        fixture.delegate.notifications.removeAll()
        store.beginSidebarRestoreIndex(generation: 1, owner: owner)
        store.deferSidebarRestoreIndex(.agentModeInactive, owner: owner)
        store.recordSidebarRestoreSelected(.settled(.notPresented), owner: owner)
        XCTAssertEqual(store.ownerValidatedSidebarRestoreJoin?.index, .deferred(.agentModeInactive))
        XCTAssertNotNil(store.ownerValidatedSidebarRestoreBaseline)
        XCTAssertTrue(fixture.delegate.notifications.isEmpty)
        store.beginSidebarRestoreIndex(generation: 2, owner: owner)
        XCTAssertEqual(store.ownerValidatedSidebarRestoreJoin?.index, .pending(generation: 2))
        store.recordSidebarRestoreIndexTerminal(generation: 2, owner: owner, outcome: .success, entries: [:], ready: true)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
        XCTAssertTrue(store.ownerValidatedSessionListCacheReady)
        XCTAssertTrue(store.sidebarAutoArchiveOwner(workspaceID: fixture.workspace.id) == owner)
    }

    func testDeactivationAfterStagedTerminalDefersInsteadOfReleasing() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        let owner = fixture.owner
        fixture.delegate.notifications.removeAll()
        store.beginSidebarRestoreIndex(generation: 1, owner: owner)
        store.recordSidebarRestoreIndexTerminal(generation: 1, owner: owner, outcome: .success, entries: [:], ready: true)
        store.deferSidebarRestoreIndex(.agentModeInactive, owner: owner)
        store.recordSidebarRestoreSelected(.settled(.notPresented), owner: owner)
        XCTAssertTrue(fixture.delegate.notifications.isEmpty, "deactivation is never a release")
        XCTAssertNotNil(store.ownerValidatedSidebarRestoreBaseline)
        XCTAssertFalse(store.ownerValidatedSessionListCacheReady)
        store.beginSidebarRestoreIndex(generation: 2, owner: owner)
        store.recordSidebarRestoreIndexTerminal(generation: 2, owner: owner, outcome: .success, entries: [:], ready: true)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
    }

    func testDeferredSystemLaunchAbandonedAsSkipReleasesWithEmptyReadyBase() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        store.beginSidebarRestoreIndex(generation: 1, owner: fixture.owner)
        store.deferSidebarRestoreIndex(.initialSystemDeferral, owner: fixture.owner)
        store.recordSidebarRestoreSelected(.settled(.restoration(.unbound)), owner: fixture.owner)
        XCTAssertNotNil(store.ownerValidatedSidebarRestoreBaseline, "deferral is not a terminal skip")
        fixture.delegate.notifications.removeAll()
        store.recordSidebarRestoreIndexTerminal(generation: nil, owner: fixture.owner, outcome: .skipped, entries: [:], ready: true)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
        XCTAssertTrue(store.ownerValidatedSessionListCacheReady)
    }

    func testOwnerSupersessionDiscardsOldJoinAndOldOwnerCannotPublishIntoSuccessor() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        let oldOwner = fixture.owner
        let oldRevision = store.sidebarRestoreBaseline?.revision
        store.beginSidebarRestoreIndex(generation: 1, owner: oldOwner)
        let newOwner = store.receiveWorkspaceSwitchNotification(fixture.workspace)
        store.installOwner(newOwner, workspace: fixture.workspace, now: day, calendar: calendar)
        XCTAssertEqual(store.sidebarRestoreBaseline?.owner, newOwner)
        XCTAssertGreaterThan(store.sidebarRestoreBaseline?.revision ?? 0, oldRevision ?? .max)
        fixture.delegate.notifications.removeAll()
        XCTAssertFalse(store.recordSidebarRestoreIndexTerminal(generation: 1, owner: oldOwner, outcome: .success, entries: [:], ready: true))
        store.recordSidebarRestoreSelected(.settled(.restoration(.fresh)), owner: oldOwner)
        XCTAssertEqual(store.sidebarRestoreJoin?.index, .pending(generation: nil))
        XCTAssertEqual(store.sidebarRestoreJoin?.selected, .discovering)
        XCTAssertTrue(fixture.delegate.notifications.isEmpty)
    }

    func testCoverageAdmissionAdvancesRevisionSilentlyAndAbandonNotifiesOnce() {
        let fixture = makeInstalledStore()
        let store = fixture.store
        fixture.delegate.notifications.removeAll()
        let before = store.sidebarRestoreBaseline?.revision ?? 0
        let newChat = ComposeTabState(id: id(14), name: "New", lastModified: day, activeAgentSessionID: id(114))
        XCTAssertTrue(store.admitSidebarRestoreCoverage(fixture.workspace.composeTabs + [newChat]))
        XCTAssertFalse(store.admitSidebarRestoreCoverage([newChat]), "membership checks never rebuild the baseline")
        XCTAssertEqual(store.sidebarRestoreBaseline?.entries[id(14)]?.ordinal, 3)
        XCTAssertGreaterThan(store.sidebarRestoreBaseline?.revision ?? 0, before)
        XCTAssertTrue(fixture.delegate.notifications.isEmpty)
        store.abandonSidebarRestore(owner: fixture.owner)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection], "baseline-only removal notifies")
        store.abandonSidebarRestore(owner: nil)
        XCTAssertEqual(fixture.delegate.notifications.count, 1)
    }

    func testNoSelectionSettlesSelectedSideAtInstall() {
        let fixture = makeInstalledStore(hasSelection: false)
        XCTAssertEqual(fixture.store.ownerValidatedSidebarRestoreJoin?.selected, .settled(.restoration(.noSelection)))
        fixture.delegate.notifications.removeAll()
        fixture.store.beginSidebarRestoreIndex(generation: 1, owner: fixture.owner)
        fixture.store.recordSidebarRestoreIndexTerminal(generation: 1, owner: fixture.owner, outcome: .success, entries: [:], ready: true)
        XCTAssertEqual(fixture.delegate.notifications.map(\.reason), [.restoreProjection])
    }

    private struct InstalledStore {
        let store: AgentWorkspaceSessionIndexStore
        let delegate: Delegate
        let owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner
        let workspace: WorkspaceModel
    }

    // D = 2026-09-29 12:00:00 UTC.
    private let day = Date(timeIntervalSince1970: 1_790_683_200)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func makeInstalledStore(hasSelection: Bool = true) -> InstalledStore {
        var workspace = WorkspaceModel(
            id: id(1),
            dateModified: day,
            name: "Restore",
            repoPaths: [],
            lastUsed: day,
            composeTabs: [
                ComposeTabState(id: id(11), name: "T1", lastModified: day.addingTimeInterval(-3 * 86400), activeAgentSessionID: id(111)),
                ComposeTabState(id: id(12), name: "T2", lastModified: day, activeAgentSessionID: id(112)),
                ComposeTabState(id: id(13), name: "T3", lastModified: day.addingTimeInterval(-86400), activeAgentSessionID: id(113))
            ]
        )
        workspace.activeComposeTabID = hasSelection ? id(12) : nil
        let delegate = Delegate(workspaceID: workspace.id)
        let store = AgentWorkspaceSessionIndexStore()
        store.delegate = delegate
        let owner = store.receiveWorkspaceSwitchNotification(workspace)
        store.installOwner(owner, workspace: workspace, now: day, calendar: calendar)
        return InstalledStore(store: store, delegate: delegate, owner: owner, workspace: workspace)
    }

    private func entry(_ sessionID: UUID, tabID: UUID) -> AgentSessionIndexEntry {
        AgentSessionIndexEntry(
            id: sessionID,
            tabID: tabID,
            name: "Entry",
            lastUserMessageAt: day,
            savedAt: day,
            lastRunStateRaw: nil,
            itemCount: 1,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            autoEditEnabled: false,
            parentSessionID: nil,
            hasUnknownConversationContent: false,
            isMCPOriginated: false,
            worktreeBindingSummaries: [],
            activeWorktreeMergeSummaries: []
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    private final class Delegate: AgentWorkspaceSessionIndexStoreDelegate {
        struct Notification {
            let reason: SessionIndexStateChangeReason
            let indexCount: Int
            let sortDateCount: Int
            let ready: Bool
            let baselineReleased: Bool
        }

        let workspaceID: UUID
        var notifications: [Notification] = []

        init(workspaceID: UUID) {
            self.workspaceID = workspaceID
        }

        var activeWorkspaceIDForSessionIndexOwnership: UUID? {
            workspaceID
        }

        var activeWorkspaceIDForWorkspaceUnloadValidation: UUID? {
            workspaceID
        }

        var enforcesActiveWorkspaceIDForSessionIndexOwnership: Bool {
            true
        }

        func makeSidebarRestoreBaseline(
            for workspace: WorkspaceModel,
            owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner,
            now: Date,
            calendar: Calendar
        ) -> AgentSidebarRestoreBaseline {
            AgentModeSidebarSessionBuilder.makeRestoreBaseline(
                for: workspace.composeTabs,
                owner: owner,
                now: now,
                calendar: calendar
            )
        }

        func sessionIndexStore(
            _ store: AgentWorkspaceSessionIndexStore,
            didChangeStateWithReason reason: SessionIndexStateChangeReason
        ) {
            notifications.append(Notification(
                reason: reason,
                indexCount: store.ownerValidatedSessionIndex.count,
                sortDateCount: store.ownerValidatedSessionListSortDates.count,
                ready: store.ownerValidatedSessionListCacheReady,
                baselineReleased: store.sidebarRestoreBaseline == nil
            ))
        }
    }
}
