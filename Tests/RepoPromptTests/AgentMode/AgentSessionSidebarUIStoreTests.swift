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

    /// `rowContentRevision` is the only content term of `SidebarSessionRowsCacheKey`,
    /// so bumping it discards every built sidebar row. Thread collapse and attention
    /// badges are applied downstream of row construction, so they must advance
    /// `revision` (re-projection) without advancing `rowContentRevision` (rebuild).
    func testPresentationOnlyChangesAdvanceRevisionWithoutInvalidatingRowContent() {
        let store = AgentSessionSidebarUIStore()
        let thread = AgentSidebarThreadKey.session(id(1))
        let tabID = id(2)

        XCTAssertEqual(store.snapshot.rowContentRevision, 0)

        store.setThreadCollapsed(true, for: thread)
        store.clearCollapsedThreads()
        store.seedDefaultCollapsedThreads(eligibleKeys: [AgentSidebarThreadKey.session(id(3))])
        store.expandAllSidebarThreads(eligibleKeys: [thread])
        XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .completed))
        XCTAssertTrue(store.clearRunStateAttention(tabID: tabID))
        XCTAssertTrue(store.markRunStateAttention(tabID: tabID, state: .failed))
        XCTAssertTrue(store.clearRunStateAttention(for: [tabID]))

        XCTAssertEqual(
            store.snapshot.rowContentRevision,
            0,
            "presentation-only sidebar state must not force a row rebuild"
        )
        XCTAssertGreaterThan(
            store.snapshot.revision,
            0,
            "presentation-only sidebar state must still re-project"
        )
    }

    /// `update(searchText:...)` and `refresh()` are the two remaining publish paths.
    /// Search/pagination stays presentation-only; `refresh()` is the single
    /// row-content invalidation path, used only after its caller's content
    /// fingerprint has already proven sidebar-visible content changed.
    func testSearchAndPaginationStayPresentationOnlyWhileRefreshInvalidatesRowContent() {
        let store = AgentSessionSidebarUIStore()

        store.update(searchText: "query", visibleSessionCount: 25, archivedVisibleSessionCount: 10)
        XCTAssertEqual(store.snapshot.searchText, "query")
        XCTAssertEqual(store.snapshot.rowContentRevision, 0)

        let revisionBeforeRefresh = store.snapshot.revision
        store.refresh()
        XCTAssertEqual(store.snapshot.rowContentRevision, 1)
        XCTAssertEqual(store.snapshot.revision, revisionBeforeRefresh + 1)

        // `refresh()` is a forced publish, so repeated calls keep invalidating.
        store.refresh()
        XCTAssertEqual(store.snapshot.rowContentRevision, 2)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}


/// Sidebar filter tabs: All is the unchanged sidebar; the others narrow it.
@MainActor
final class AgentSidebarTabFilterTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func row(
        _ number: Int,
        parent: Int? = nil,
        depth: Int = 0,
        pinned: Bool = false,
        runState: AgentSessionRunState = .idle,
        laneCreator: Int? = nil
    ) -> AgentModeViewModel.SidebarSession {
        AgentModeViewModel.SidebarSession(
            id: id(number), tabID: id(number), title: "Session \(number)", lastUserMessageAt: base,
            activityDate: base, isPinned: pinned, sessionID: id(100 + number),
            parentSessionID: parent.map { id(100 + $0) }, createdByOverseerSessionID: laneCreator.map { id(100 + $0) },
            depth: depth, isMCPControlled: false,
            searchFieldSource: AgentSessionSearchFieldSource(title: "Session \(number)", runState: runState)
        )
    }

    func testAllTabReturnsRowsUnchanged() {
        let rows = [row(1), row(2, parent: 1, depth: 1), row(3, pinned: true)]
        let filtered = AgentModeViewModel.sidebarRows(rows, in: .all, attentionTabIDs: [], overseerSessionIDs: [])
        XCTAssertEqual(filtered.map(\.id), rows.map(\.id))
    }

    func testPinnedTabKeepsPinnedRowsWithTheirParents() {
        let rows = [row(1), row(2, parent: 1, depth: 1, pinned: true), row(3), row(4, pinned: true)]
        let filtered = AgentModeViewModel.sidebarRows(rows, in: .pinned, attentionTabIDs: [], overseerSessionIDs: [])
        XCTAssertEqual(filtered.map(\.id), [id(1), id(2), id(4)])
    }

    func testActiveTabKeepsRunningWaitingAndUnseenAttention() {
        let rows = [
            row(1, runState: .running), row(2, runState: .waitingForApproval), row(3, runState: .completed),
            row(4), row(5, parent: 4, depth: 1, runState: .waitingForUser)
        ]
        let filtered = AgentModeViewModel.sidebarRows(rows, in: .active, attentionTabIDs: [id(3)], overseerSessionIDs: [])
        // 3 is completed but carries unseen attention; idle 4 stays as the parent of waiting 5.
        XCTAssertEqual(filtered.map(\.id), [id(1), id(2), id(3), id(4), id(5)])
        XCTAssertTrue(AgentModeViewModel.sidebarRows([row(6)], in: .active, attentionTabIDs: [], overseerSessionIDs: []).isEmpty)
    }

    func testOverseersTabKeepsSessionsOverseeingOthers() {
        let rows = [row(1), row(2, laneCreator: 1), row(3), row(4)]
        let filtered = AgentModeViewModel.sidebarRows(rows, in: .overseers, attentionTabIDs: [], overseerSessionIDs: [id(101), id(103)])
        XCTAssertEqual(filtered.map(\.id), [id(1), id(3)])
    }

    func testSelectingATabPublishesWithoutRebuildingRows() {
        let store = AgentSessionSidebarUIStore()
        let before = store.snapshot
        store.setSidebarTab(.active)
        XCTAssertEqual(store.snapshot.sidebarTab, .active)
        XCTAssertEqual(store.snapshot.rowContentRevision, before.rowContentRevision)
        XCTAssertGreaterThan(store.snapshot.revision, before.revision)
    }

    func testFilteredTabShowsMatchesInsideCollapsedThreadsAndAllTabKeepsCollapse() {
        let viewModel = makeViewModel()
        let tabs = [
            ComposeTabState(id: id(1), name: "Parent", lastModified: base, activeAgentSessionID: id(101)),
            ComposeTabState(id: id(2), name: "Pinned child", lastModified: base, isPinned: true, activeAgentSessionID: id(102))
        ]
        for (offset, tab) in tabs.enumerated() {
            let session = AgentModeViewModel.TabSession(tabID: tab.id)
            session.hasLoadedPersistedState = true
            session.lastActivityAt = base.addingTimeInterval(TimeInterval(-offset * 60))
            if offset == 1 { session.parentSessionID = id(101) }
            XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: tab.activeAgentSessionID, on: session))
            viewModel.test_installLiveSession(session)
        }
        viewModel.ui.sessionSidebar.refresh()
        viewModel.ui.sessionSidebar.setThreadCollapsed(true, for: .key(sessionID: id(101), tabID: id(1)))
        XCTAssertEqual(projection(viewModel, tabs: tabs).filteredSessions.map(\.tabID), [id(1)], "All keeps the collapse")

        viewModel.setSidebarTab(.pinned)
        XCTAssertEqual(projection(viewModel, tabs: tabs).filteredSessions.map(\.tabID), [id(1), id(2)])
        viewModel.setSidebarTab(.all)
        XCTAssertEqual(projection(viewModel, tabs: tabs).filteredSessions.map(\.tabID), [id(1)])
    }

    func testActiveTabFollowsLiveRunStateWithoutARowRebuild() {
        let viewModel = makeViewModel()
        let tab = ComposeTabState(id: id(1), name: "Worker", lastModified: base, activeAgentSessionID: id(101))
        let session = AgentModeViewModel.TabSession(tabID: tab.id)
        session.hasLoadedPersistedState = true
        XCTAssertNotNil(viewModel.test_installPersistentSessionBinding(sessionID: tab.activeAgentSessionID, on: session))
        viewModel.test_installLiveSession(session)
        viewModel.ui.sessionSidebar.refresh()
        viewModel.setSidebarTab(.active)
        XCTAssertTrue(projection(viewModel, tabs: [tab]).filteredSessions.isEmpty)

        session.runState = .running
        XCTAssertEqual(projection(viewModel, tabs: [tab]).filteredSessions.map(\.tabID), [id(1)])
        session.runState = .completed
        XCTAssertTrue(projection(viewModel, tabs: [tab]).filteredSessions.isEmpty)
    }

    private func projection(
        _ viewModel: AgentModeViewModel,
        tabs: [ComposeTabState]
    ) -> AgentModeViewModel.SidebarListProjection {
        viewModel.sidebarListProjection(
            workspaceID: nil,
            composeTabs: tabs,
            stashedTabs: [],
            currentTabID: nil,
            sidebarSnapshot: viewModel.ui.sessionSidebar.snapshot,
            archivedSessionsExpanded: false,
            showComposeTabsWithoutAgentSessions: true
        )
    }

    private func makeViewModel() -> AgentModeViewModel {
        AgentModeViewModel(
            testWindowID: -1408,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Sidebar tab tests must not start a Codex session")
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
    }
}
