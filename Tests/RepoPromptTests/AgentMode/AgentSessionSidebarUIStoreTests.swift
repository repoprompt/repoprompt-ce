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

    func testCommandOriginWithoutSelectionUsesCommandProgressPolicy() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            targetCount: 1,
            workspaceID: workspaceID
        ))

        XCTAssertEqual(store.selectionState.inFlightAction, AgentSidebarBulkActionOperation(
            token: token,
            workspaceID: workspaceID,
            kind: .delete,
            origin: .command,
            targetCount: 1
        ))
        XCTAssertTrue(store.selectionState.isMutationInFlight)
        XCTAssertFalse(store.selectionState.showsSelectionPresentation)
        XCTAssertEqual(store.selectionState.commandProgressOperation, store.selectionState.inFlightAction)

        store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil)

        XCTAssertFalse(store.selectionState.isMutationInFlight)
        XCTAssertFalse(store.selectionState.showsSelectionPresentation)
        XCTAssertNil(store.selectionState.commandProgressOperation)
    }

    func testSelectionOriginSurvivesEmptyReconciliationUntilFinish() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: workspaceID)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .stash,
            origin: .selection,
            targetCount: 1,
            workspaceID: workspaceID
        ))

        XCTAssertTrue(store.selectionState.isMutationInFlight)
        XCTAssertTrue(store.selectionState.showsSelectionPresentation)
        XCTAssertNil(store.selectionState.commandProgressOperation)

        store.reconcileSelection(renderedOrder: [], workspaceID: workspaceID)

        XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
        XCTAssertTrue(store.selectionState.showsSelectionPresentation)
        XCTAssertEqual(store.selectionState.inFlightAction, .init(
            token: token,
            workspaceID: workspaceID,
            kind: .stash,
            origin: .selection,
            targetCount: 1
        ))

        store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil)

        XCTAssertFalse(store.selectionState.isMutationInFlight)
        XCTAssertFalse(store.selectionState.showsSelectionPresentation)
    }

    func testBulkActionLocksSelectionMutationsAndRejectsReentryForBothOrigins() throws {
        for origin in [AgentSidebarBulkActionOrigin.selection, .command] {
            let store = AgentSessionSidebarUIStore()
            let workspaceID = id(99)
            let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
            let second = AgentSidebarSelectionIdentity.active(tabID: id(2))
            if origin == .selection {
                _ = store.handleSelectionGesture(
                    .toggle,
                    identity: first,
                    renderedOrder: [first, second],
                    workspaceID: workspaceID
                )
            }
            let token = try XCTUnwrap(store.beginBulkAction(
                kind: .delete,
                origin: origin,
                targetCount: 1,
                workspaceID: workspaceID
            ))
            let frozenState = store.selectionState

            XCTAssertNil(store.beginBulkAction(
                kind: .stash,
                origin: origin,
                targetCount: 1,
                workspaceID: workspaceID
            ))
            XCTAssertEqual(store.handleSelectionGesture(
                .toggle,
                identity: second,
                renderedOrder: [first, second],
                workspaceID: workspaceID
            ), .ignored)
            store.selectAll(renderedOrder: [first, second], workspaceID: workspaceID)
            store.clearSelection()

            XCTAssertEqual(store.selectionState, frozenState)
            store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil)
        }
    }

    func testDirectBulkActionRetainsWorkspaceOwnerWithoutSelection() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            targetCount: 1,
            workspaceID: workspaceID
        ))

        store.reconcileSelection(renderedOrder: [], workspaceID: workspaceID)

        XCTAssertEqual(store.selectionState.workspaceID, workspaceID)
        XCTAssertTrue(store.isCurrentBulkAction(token: token, workspaceID: workspaceID))
    }

    func testWorkspaceInvalidationClearsBothOriginsAndRejectsStaleFinish() throws {
        for origin in [AgentSidebarBulkActionOrigin.selection, .command] {
            let store = AgentSessionSidebarUIStore()
            let workspaceID = id(99)
            let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
            if origin == .selection {
                _ = store.handleSelectionGesture(
                    .toggle,
                    identity: first,
                    renderedOrder: [first],
                    workspaceID: workspaceID
                )
            }
            let token = try XCTUnwrap(store.beginBulkAction(
                kind: .delete,
                origin: origin,
                targetCount: 1,
                workspaceID: workspaceID
            ))

            store.invalidateSelectionForWorkspaceChange()
            store.finishBulkAction(
                token: token,
                workspaceID: workspaceID,
                notice: .init(severity: .error, title: "Stale", message: "Stale")
            )

            XCTAssertNil(store.selectionState.inFlightAction)
            XCTAssertNil(store.selectionState.commandProgressOperation)
            XCTAssertFalse(store.selectionState.isMutationInFlight)
            XCTAssertFalse(store.selectionState.showsSelectionPresentation)
            XCTAssertNil(store.selectionState.notice)
            XCTAssertNil(store.selectionState.workspaceID)
            XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
        }
    }

    func testWorkspaceMismatchReconciliationClearsBothOriginsAndRejectsStaleFinish() throws {
        for origin in [AgentSidebarBulkActionOrigin.selection, .command] {
            let store = AgentSessionSidebarUIStore()
            let originalWorkspaceID = id(98)
            let nextWorkspaceID = id(99)
            let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
            if origin == .selection {
                _ = store.handleSelectionGesture(
                    .toggle,
                    identity: first,
                    renderedOrder: [first],
                    workspaceID: originalWorkspaceID
                )
            }
            let token = try XCTUnwrap(store.beginBulkAction(
                kind: .delete,
                origin: origin,
                targetCount: 1,
                workspaceID: originalWorkspaceID
            ))

            store.reconcileSelection(renderedOrder: [], workspaceID: nextWorkspaceID)
            store.finishBulkAction(
                token: token,
                workspaceID: originalWorkspaceID,
                notice: .init(severity: .error, title: "Stale", message: "Stale")
            )

            XCTAssertNil(store.selectionState.inFlightAction)
            XCTAssertNil(store.selectionState.commandProgressOperation)
            XCTAssertFalse(store.selectionState.isMutationInFlight)
            XCTAssertFalse(store.selectionState.showsSelectionPresentation)
            XCTAssertNil(store.selectionState.notice)
            XCTAssertNil(store.selectionState.workspaceID)
            XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
        }
    }

    func testCommandBulkActionRequiresEmptySelection() {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: workspaceID)
        let selectedState = store.selectionState

        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            targetCount: 1,
            workspaceID: workspaceID
        ))
        XCTAssertEqual(store.selectionState, selectedState)

        store.clearSelection()
        XCTAssertNotNil(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            targetCount: 1,
            workspaceID: workspaceID
        ))
    }

    func testSelectionBulkActionRequiresNonemptySelectionOwnedByWorkspace() {
        let store = AgentSessionSidebarUIStore()
        let selectionWorkspaceID = id(98)
        let otherWorkspaceID = id(99)
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))

        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            targetCount: 1,
            workspaceID: selectionWorkspaceID
        ))

        _ = store.handleSelectionGesture(
            .toggle,
            identity: first,
            renderedOrder: [first],
            workspaceID: selectionWorkspaceID
        )
        let selectedState = store.selectionState

        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            targetCount: 1,
            workspaceID: otherWorkspaceID
        ))
        XCTAssertEqual(store.selectionState, selectedState)
        XCTAssertNotNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            targetCount: 1,
            workspaceID: selectionWorkspaceID
        ))
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
