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
        let target = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))

        XCTAssertEqual(store.selectionState.inFlightAction, AgentSidebarBulkActionOperation(
            token: token,
            workspaceID: workspaceID,
            kind: .delete,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row
        ))
        XCTAssertTrue(store.selectionState.isMutationInFlight)
        XCTAssertFalse(store.selectionState.showsSelectionPresentation)
        XCTAssertEqual(
            store.selectionState.commandRowProgressOperation(for: target, workspaceID: workspaceID),
            store.selectionState.inFlightAction
        )
        XCTAssertNil(store.selectionState.commandRowProgressOperation(
            for: .active(tabID: id(2)),
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.commandRowProgressOperation(for: target, workspaceID: id(98)))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [target],
            workspaceID: workspaceID
        ))
        XCTAssertEqual(
            store.selectionState.commandFallbackProgressOperation(
                existingIdentities: [target],
                renderedIdentities: [],
                workspaceID: workspaceID
            ),
            store.selectionState.inFlightAction
        )
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [.active(tabID: id(2))],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [],
            workspaceID: id(98)
        ))
        XCTAssertNil(store.selectionState.archivedHeaderCommandProgressOperation)

        store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil)

        XCTAssertFalse(store.selectionState.isMutationInFlight)
        XCTAssertFalse(store.selectionState.showsSelectionPresentation)
        XCTAssertNil(store.selectionState.commandRowProgressOperation(for: target, workspaceID: workspaceID))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
    }

    func testCommandRowProgressRetirementIsMonotonicAndPreventsSameIdentityReattachment() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let target = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .stash,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))

        let initialRevision = store.selectionState.revision
        store.retireCommandRowProgress(token: token, forRemovedTabIDs: [id(2)], workspaceID: workspaceID)
        store.retireCommandRowProgress(token: token, forRemovedTabIDs: [id(1)], workspaceID: id(98))
        XCTAssertEqual(store.selectionState.revision, initialRevision)

        store.retireCommandRowProgress(token: token, forRemovedTabIDs: [id(1)], workspaceID: workspaceID)

        let retiredOperation = try XCTUnwrap(store.selectionState.inFlightAction)
        XCTAssertTrue(retiredOperation.commandRowProgressRetired)
        XCTAssertEqual(store.selectionState.revision, initialRevision + 1)
        XCTAssertNil(store.selectionState.commandRowProgressOperation(for: target, workspaceID: workspaceID))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [target],
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))

        store.retireCommandRowProgress(token: token, forRemovedTabIDs: [id(1)], workspaceID: workspaceID)
        XCTAssertEqual(store.selectionState.revision, initialRevision + 1)

        store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil)
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [target],
            workspaceID: workspaceID
        ))
    }

    func testStaleCommandRowRetirementCannotMutateNewOperationGeneration() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let target = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let tokenA = try XCTUnwrap(store.beginBulkAction(
            kind: .stash,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))

        store.invalidateSelectionForWorkspaceChange()

        let tokenB = try XCTUnwrap(store.beginBulkAction(
            kind: .stash,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))
        XCTAssertNotEqual(tokenA, tokenB)
        let revision = store.selectionState.revision

        store.retireCommandRowProgress(token: tokenA, forRemovedTabIDs: [target.tabID], workspaceID: workspaceID)
        store.finishBulkAction(token: tokenA, workspaceID: workspaceID, notice: nil)

        let currentOperation = try XCTUnwrap(store.selectionState.inFlightAction)
        XCTAssertEqual(currentOperation.token, tokenB)
        XCTAssertFalse(currentOperation.commandRowProgressRetired)
        XCTAssertEqual(store.selectionState.revision, revision)
        XCTAssertEqual(
            store.selectionState.commandRowProgressOperation(for: target, workspaceID: workspaceID),
            currentOperation
        )

        store.retireCommandRowProgress(token: tokenB, forRemovedTabIDs: [target.tabID], workspaceID: workspaceID)
        let retiredOperation = try XCTUnwrap(store.selectionState.inFlightAction)
        XCTAssertEqual(retiredOperation.token, tokenB)
        XCTAssertTrue(retiredOperation.commandRowProgressRetired)
        XCTAssertEqual(store.selectionState.revision, revision + 1)

        store.finishBulkAction(token: tokenB, workspaceID: workspaceID, notice: nil)
        XCTAssertNil(store.selectionState.inFlightAction)
    }

    func testArchivedRowUsesFallbackOnlyWhenItsRowIsAbsent() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let target = AgentSidebarSelectionIdentity.archived(stashedTabID: id(10), tabID: id(1))
        _ = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))

        XCTAssertNotNil(store.selectionState.commandRowProgressOperation(for: target, workspaceID: workspaceID))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [target],
            workspaceID: workspaceID
        ))
        XCTAssertNotNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [target],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [.archived(stashedTabID: id(11), tabID: target.tabID)],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
    }

    func testSelectionOriginSurvivesEmptyReconciliationUntilFinish() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let first = AgentSidebarSelectionIdentity.active(tabID: id(1))
        _ = store.handleSelectionGesture(.toggle, identity: first, renderedOrder: [first], workspaceID: workspaceID)
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .stash,
            origin: .selection,
            presentationTargets: [first],
            commandProgressPlacement: nil,
            workspaceID: workspaceID
        ))

        XCTAssertTrue(store.selectionState.isMutationInFlight)
        XCTAssertTrue(store.selectionState.showsSelectionPresentation)
        XCTAssertNil(store.selectionState.commandRowProgressOperation(for: first, workspaceID: workspaceID))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [first],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.archivedHeaderCommandProgressOperation)

        store.reconcileSelection(renderedOrder: [], workspaceID: workspaceID)

        XCTAssertTrue(store.selectionState.selectedIdentities.isEmpty)
        XCTAssertTrue(store.selectionState.showsSelectionPresentation)
        XCTAssertEqual(store.selectionState.inFlightAction, .init(
            token: token,
            workspaceID: workspaceID,
            kind: .stash,
            origin: .selection,
            presentationTargets: [first],
            commandProgressPlacement: nil
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
                presentationTargets: [first],
                commandProgressPlacement: origin == .command ? .row : nil,
                workspaceID: workspaceID
            ))
            let frozenState = store.selectionState

            XCTAssertNil(store.beginBulkAction(
                kind: .stash,
                origin: origin,
                presentationTargets: [first],
                commandProgressPlacement: origin == .command ? .row : nil,
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
        let target = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [target],
            commandProgressPlacement: .row,
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
                presentationTargets: [first],
                commandProgressPlacement: origin == .command ? .row : nil,
                workspaceID: workspaceID
            ))

            store.invalidateSelectionForWorkspaceChange()
            store.finishBulkAction(
                token: token,
                workspaceID: workspaceID,
                notice: .init(severity: .error, title: "Stale", message: "Stale")
            )

            XCTAssertNil(store.selectionState.inFlightAction)
            XCTAssertNil(store.selectionState.commandRowProgressOperation(for: first, workspaceID: workspaceID))
            XCTAssertNil(store.selectionState.archivedHeaderCommandProgressOperation)
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
                presentationTargets: [first],
                commandProgressPlacement: origin == .command ? .row : nil,
                workspaceID: originalWorkspaceID
            ))

            store.reconcileSelection(renderedOrder: [], workspaceID: nextWorkspaceID)
            store.finishBulkAction(
                token: token,
                workspaceID: originalWorkspaceID,
                notice: .init(severity: .error, title: "Stale", message: "Stale")
            )

            XCTAssertNil(store.selectionState.inFlightAction)
            XCTAssertNil(store.selectionState.commandRowProgressOperation(for: first, workspaceID: originalWorkspaceID))
            XCTAssertNil(store.selectionState.archivedHeaderCommandProgressOperation)
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
            presentationTargets: [first],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))
        XCTAssertEqual(store.selectionState, selectedState)

        store.clearSelection()
        XCTAssertNotNil(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [first],
            commandProgressPlacement: .row,
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
            presentationTargets: [first],
            commandProgressPlacement: nil,
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
            presentationTargets: [first],
            commandProgressPlacement: nil,
            workspaceID: otherWorkspaceID
        ))
        XCTAssertEqual(store.selectionState, selectedState)
        XCTAssertNotNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            presentationTargets: [first],
            commandProgressPlacement: nil,
            workspaceID: selectionWorkspaceID
        ))
    }

    func testArchivedHeaderCommandFreezesTargetsWithoutRowProgress() throws {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let first = AgentSidebarSelectionIdentity.archived(stashedTabID: id(10), tabID: id(1))
        let second = AgentSidebarSelectionIdentity.archived(stashedTabID: id(20), tabID: id(2))

        let token = try XCTUnwrap(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [first, second],
            commandProgressPlacement: .archivedHeader,
            workspaceID: workspaceID
        ))

        let operation = try XCTUnwrap(store.selectionState.archivedHeaderCommandProgressOperation)
        XCTAssertEqual(operation.token, token)
        XCTAssertEqual(operation.targetCount, 2)
        XCTAssertEqual(operation.presentationTargets, [first, second])
        XCTAssertNil(store.selectionState.commandRowProgressOperation(for: first, workspaceID: workspaceID))
        XCTAssertNil(store.selectionState.commandFallbackProgressOperation(
            existingIdentities: [first, second],
            renderedIdentities: [],
            workspaceID: workspaceID
        ))

        let revision = store.selectionState.revision
        store.retireCommandRowProgress(token: token, forRemovedTabIDs: [first.tabID], workspaceID: workspaceID)
        XCTAssertEqual(store.selectionState.revision, revision)
        XCTAssertEqual(store.selectionState.archivedHeaderCommandProgressOperation, operation)
    }

    func testBulkActionRejectsInvalidOriginAndProgressPlacementCombinations() {
        let store = AgentSessionSidebarUIStore()
        let workspaceID = id(99)
        let active = AgentSidebarSelectionIdentity.active(tabID: id(1))
        let otherActive = AgentSidebarSelectionIdentity.active(tabID: id(2))

        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [active, otherActive],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .command,
            presentationTargets: [active],
            commandProgressPlacement: .archivedHeader,
            workspaceID: workspaceID
        ))

        _ = store.handleSelectionGesture(.toggle, identity: active, renderedOrder: [active], workspaceID: workspaceID)
        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            presentationTargets: [active],
            commandProgressPlacement: .row,
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.beginBulkAction(
            kind: .delete,
            origin: .selection,
            presentationTargets: [otherActive],
            commandProgressPlacement: nil,
            workspaceID: workspaceID
        ))
        XCTAssertNil(store.selectionState.inFlightAction)
    }

    func testBulkMutationTargetsMapOnlyTheRequestedAction() {
        let workspaceID = id(99)
        let activeDelete = id(1)
        let stashed = id(10)
        let archivedTab = id(2)
        let stash = id(3)
        let pin = id(4)
        let unpin = id(5)
        let targets = AgentModeViewModel.SidebarBulkMutationTargets(
            workspaceID: workspaceID,
            activeDeleteTabIDs: [activeDelete],
            archivedDeleteTargets: [.init(stashedTabID: stashed, tabID: archivedTab)],
            stashTabIDs: [stash],
            pinTabIDs: [pin],
            unpinTabIDs: [unpin]
        )

        XCTAssertEqual(targets.presentationTargets(for: .delete), [
            .active(tabID: activeDelete),
            .archived(stashedTabID: stashed, tabID: archivedTab)
        ])
        XCTAssertEqual(targets.presentationTargets(for: .stash), [.active(tabID: stash)])
        XCTAssertEqual(targets.presentationTargets(for: .pin), [.active(tabID: pin)])
        XCTAssertEqual(targets.presentationTargets(for: .unpin), [.active(tabID: unpin)])
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
