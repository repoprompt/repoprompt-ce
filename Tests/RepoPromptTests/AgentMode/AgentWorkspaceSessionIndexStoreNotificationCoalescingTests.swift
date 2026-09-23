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

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    private final class Delegate: AgentWorkspaceSessionIndexStoreDelegate {
        struct Notification {
            let reason: SessionIndexStateChangeReason
            let indexCount: Int
            let sortDateCount: Int
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

        func makeSidebarRestoreFrozenOrder(for _: WorkspaceModel) -> [UUID: Int] {
            [:]
        }

        func sessionIndexStore(
            _ store: AgentWorkspaceSessionIndexStore,
            didChangeStateWithReason reason: SessionIndexStateChangeReason
        ) {
            notifications.append(Notification(
                reason: reason,
                indexCount: store.ownerValidatedSessionIndex.count,
                sortDateCount: store.ownerValidatedSessionListSortDates.count
            ))
        }
    }
}
