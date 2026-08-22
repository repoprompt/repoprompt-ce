@_spi(TestSupport) @testable import RepoPromptApp
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

    func testSelectionGesturesMatchFinderSemantics() {
        let store = AgentSessionSidebarUIStore()
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let second = AgentSidebarSelectionIdentity.active(tabID: id(2))
        let archived = AgentSidebarSelectionIdentity.archived(stashedTabID: id(30), tabID: id(3))
        let order = [first, second, archived]

        XCTAssertEqual(store.handleSelectionGesture(.primary, identity: first, renderedOrder: order, workspaceID: id(99)), .activate)
        XCTAssertEqual(store.handleSelectionGesture(.toggle, identity: first, renderedOrder: order, workspaceID: id(99)), .selectionChanged)
        XCTAssertEqual(store.selectionState.selectedIdentities, [first])
        XCTAssertEqual(store.handleSelectionGesture(.range, identity: archived, renderedOrder: order, workspaceID: id(99)), .selectionChanged)
        XCTAssertEqual(store.selectionState.selectedIdentities, Set(order))

        XCTAssertEqual(store.handleSelectionGesture(.primary, identity: second, renderedOrder: order, workspaceID: id(99)), .selectionChanged)
        XCTAssertEqual(store.selectionState.selectedIdentities, [second])
    }

    func testShiftWithMissingAnchorStartsSingletonSelection() {
        let store = AgentSessionSidebarUIStore()
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let second = AgentSidebarSelectionIdentity.active(tabID: id(2))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first, second], workspaceID: id(99))

        XCTAssertEqual(store.handleSelectionGesture(.range, identity: second, renderedOrder: [second], workspaceID: id(99)), .selectionChanged)
        XCTAssertEqual(store.selectionState.selectedIdentities, [second])
        XCTAssertEqual(store.selectionState.anchor, second)
    }

    func testSelectAllAndReconcileUseRenderedRowsOnly() {
        let store = AgentSessionSidebarUIStore()
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let second = AgentSidebarSelectionIdentity.active(tabID: id(2))
        store.selectAll(renderedOrder: [first, second], workspaceID: id(99))
        XCTAssertEqual(store.selectionState.selectedIdentities, [first, second])

        store.reconcileSelection(renderedOrder: [second], workspaceID: id(99))
        XCTAssertEqual(store.selectionState.selectedIdentities, [second])
        XCTAssertNil(store.selectionState.anchor)
    }

    func testBulkActionFreezesSelectionAndRejectsReentry() throws {
        let store = AgentSessionSidebarUIStore()
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: id(99))
        let token = store.beginBulkAction(kind: .delete, targetCount: 1, workspaceID: id(99))
        XCTAssertNotNil(token)
        XCTAssertNil(store.beginBulkAction(kind: .delete, targetCount: 1, workspaceID: id(99)))
        XCTAssertEqual(store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: id(99)), .ignored)

        store.reconcileSelection(renderedOrder: [], workspaceID: id(99))
        XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
        try store.finishBulkAction(token: XCTUnwrap(token), workspaceID: id(99), notice: nil)
        XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
    }

    func testDirectBulkActionRetainsWorkspaceOwnerWithoutSelection() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            targetCount: 1,
            workspaceID: workspaceID
        ))

        store.reconcileSelection(renderedOrder: [], workspaceID: workspaceID)

        XCTAssertEqual(store.selectionState.workspaceID, workspaceID)
        XCTAssertTrue(store.isCurrentBulkAction(token: token, workspaceID: workspaceID))
    }

    func testWorkspaceMismatchReconciliationInvalidatesBulkAction() throws {
        let store = AgentSessionSidebarUIStore()
        let firstWorkspaceID = id(98)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            targetCount: 1,
            workspaceID: firstWorkspaceID
        ))

        store.reconcileSelection(renderedOrder: [], workspaceID: id(99))
        store.finishBulkAction(
            token: token,
            workspaceID: firstWorkspaceID,
            notice: .init(severity: .error, title: "Stale", message: "Stale")
        )

        XCTAssertNil(store.selectionState.inFlightAction)
        XCTAssertNil(store.selectionState.notice)
        XCTAssertNil(store.selectionState.workspaceID)
    }

    func testStaleBulkCompletionCannotMutateNewWorkspaceState() throws {
        let store = AgentSessionSidebarUIStore()
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: id(99))
        let token = try XCTUnwrap(store.beginBulkAction(kind: .stash, targetCount: 1, workspaceID: id(99)))
        store.invalidateSelectionForWorkspaceChange()
        store.finishBulkAction(token: token, workspaceID: id(99), notice: .init(severity: .error, title: "Old", message: "Old"))
        XCTAssertEqual(store.selectionState, AgentSidebarSelectionState(revision: store.selectionState.revision))
    }

    func testModifierMappingGivesShiftPrecedence() {
        XCTAssertEqual(AgentSidebarSelectionGesture(modifiers: []), .primary)
        XCTAssertEqual(AgentSidebarSelectionGesture(modifiers: [.command]), .toggle)
        XCTAssertEqual(AgentSidebarSelectionGesture(modifiers: [.command, .shift]), .range)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
