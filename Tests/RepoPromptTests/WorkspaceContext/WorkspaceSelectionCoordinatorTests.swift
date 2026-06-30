import Combine
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceSelectionCoordinatorTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testActiveSelectionSnapshotReturnsActiveTabSelectionAndFlushesPendingUIWhenRequested() {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"], codemapAutoEnabled: true)
        let pending = StoredSelection(
            selectedPaths: ["/tmp/pending.swift"],

            slices: ["/tmp/pending.swift": [LineRange(start: 1, end: 3)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = pending
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let unflushed = coordinator.activeSelectionSnapshot(flushPendingUI: false)
        XCTAssertEqual(unflushed.tabID, harness.tabID)
        XCTAssertEqual(unflushed.selection, initial)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 0)

        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let flushed = coordinator.activeSelectionSnapshot(flushPendingUI: true)
        XCTAssertEqual(flushed.tabID, harness.tabID)
        XCTAssertEqual(flushed.selection, pending)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: pending, source: .uiFlush))
    }

    func testPersistActiveSelectionWritesActiveTabAndEmitsChange() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let next = StoredSelection(
            selectedPaths: ["/tmp/next.swift"],

            slices: ["/tmp/next.swift": [LineRange(start: 4, end: 8)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
        let persisted = await coordinator.persistActiveSelection(next, source: .runtimeMutation, mirrorToUI: true)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, next)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .runtimeMutation))
        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
    }

    func testMCPActiveSelectionMirrorsAreAwaitedSerializedAndSkipSupersededRevision() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let first = StoredSelection(selectedPaths: ["/tmp/first.swift"])
        let superseded = StoredSelection(selectedPaths: ["/tmp/superseded.swift"])
        let latest = StoredSelection(selectedPaths: ["/tmp/latest.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        let firstMirrorGate = SelectionMirrorGate()
        harness.manager.firstMirrorGate = firstMirrorGate
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let firstTask = Task { @MainActor in
            await coordinator.persistActiveSelection(first, source: .mcpTabContext)
        }
        let firstMirrorStarted = await firstMirrorGate.waitUntilStarted()
        XCTAssertTrue(firstMirrorStarted)
        guard firstMirrorStarted else { return }

        let supersededTask = Task { @MainActor in
            await coordinator.persistActiveSelection(superseded, source: .mcpTabContext)
        }
        await waitForSelection(superseded, in: harness)
        let latestTask = Task { @MainActor in
            await coordinator.persistActiveSelection(latest, source: .mcpTabContext)
        }
        await waitForSelection(latest, in: harness)

        XCTAssertEqual(harness.manager.mirrorStartedSelections, [first])
        XCTAssertTrue(harness.manager.mirrorCompletedSelections.isEmpty)
        XCTAssertEqual(changes, [
            .init(tabID: harness.tabID, selection: first, source: .mcpTabContext),
            .init(tabID: harness.tabID, selection: superseded, source: .mcpTabContext),
            .init(tabID: harness.tabID, selection: latest, source: .mcpTabContext)
        ])

        await firstMirrorGate.release()
        _ = await firstTask.value
        _ = await supersededTask.value
        _ = await latestTask.value

        XCTAssertEqual(harness.manager.mirrorStartedSelections, [first, latest])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [first, latest])
        XCTAssertEqual(harness.manager.mirroredSelection, latest)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, latest)
    }

    func testMCPMirrorRequestCompletesWhileChurnRepairsCoalesceToLatest() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let requested = StoredSelection(selectedPaths: ["/tmp/requested.swift"])
        let secondSelection = StoredSelection(selectedPaths: ["/tmp/second.swift"])
        let latestSelection = StoredSelection(selectedPaths: ["/tmp/latest.swift"])
        let secondTabID = UUID()
        let latestTabID = UUID()
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.appendTab(ComposeTabState(id: secondTabID, name: "Second", selection: secondSelection))
        harness.manager.appendTab(ComposeTabState(id: latestTabID, name: "Latest", selection: latestSelection))
        let firstGate = SelectionMirrorGate()
        let repairGate = SelectionMirrorGate()
        harness.manager.mirrorGatesByAttempt = [1: firstGate, 2: repairGate]
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        let requestCompletion = SelectionMirrorCompletion(expectedCount: 1)

        let mirrorTask = Task { @MainActor in
            await coordinator.persistActiveSelection(requested, source: .mcpTabContext)
            await requestCompletion.markCompleted()
        }
        let firstAttemptStarted = await firstGate.waitUntilStarted()
        XCTAssertTrue(firstAttemptStarted)

        harness.manager.setActiveTab(secondTabID)
        await firstGate.release()
        let repairAttemptStarted = await repairGate.waitUntilStarted()
        XCTAssertTrue(repairAttemptStarted)
        let requestCompleted = await requestCompletion.waitUntilComplete()
        XCTAssertTrue(requestCompleted)

        harness.manager.setActiveTab(latestTabID)
        await repairGate.release()
        let repairedLatest = await waitForMirrorAttempts(3, in: harness)
        XCTAssertTrue(repairedLatest)
        _ = await mirrorTask.value

        XCTAssertEqual(harness.manager.mirrorStartedSelections, [requested, secondSelection, latestSelection])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [requested, secondSelection, latestSelection])
        XCTAssertEqual(harness.manager.mirroredSelection, latestSelection)
        XCTAssertEqual(harness.manager.activeWorkspace?.activeComposeTabID, latestTabID)
    }

    func testMCPMirrorRepairsAfterABATabTransitionDuringSuspension() async {
        let requested = StoredSelection(selectedPaths: ["/tmp/requested.swift"])
        let alternate = StoredSelection(selectedPaths: ["/tmp/alternate.swift"])
        let alternateTabID = UUID()
        let harness = CoordinatorHarness(initialSelection: requested)
        harness.manager.appendTab(ComposeTabState(id: alternateTabID, name: "Alternate", selection: alternate))
        let gate = SelectionMirrorGate()
        harness.manager.mirrorGatesByAttempt = [1: gate]
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let mirrorTask = Task { @MainActor in
            await coordinator.persistActiveSelection(requested, source: .mcpTabContext)
        }
        let firstAttemptStarted = await gate.waitUntilStarted()
        XCTAssertTrue(firstAttemptStarted)

        harness.manager.setActiveTab(alternateTabID)
        harness.manager.setActiveTab(harness.tabID)
        await gate.release()
        _ = await mirrorTask.value
        let repairedABA = await waitForMirrorAttempts(2, in: harness)
        XCTAssertTrue(repairedABA)

        XCTAssertEqual(harness.manager.mirrorStartedSelections, [requested, requested])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [requested, requested])
        XCTAssertEqual(harness.manager.mirroredSelection, requested)
        XCTAssertEqual(harness.manager.activeWorkspace?.activeComposeTabID, harness.tabID)
    }

    func testMCPActiveSelectionNoOpReconcilesStaleMirroredUIWithoutPublishingChange() async {
        let canonical = StoredSelection(selectedPaths: ["/tmp/canonical.swift"])
        let staleUI = StoredSelection(selectedPaths: ["/tmp/stale-ui.swift"])
        let harness = CoordinatorHarness(initialSelection: canonical)
        harness.manager.mirroredSelection = staleUI
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        _ = await coordinator.persistActiveSelection(canonical, source: .mcpTabContext)

        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 0)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(harness.manager.mirrorStartedSelections, [canonical])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [canonical])
        XCTAssertEqual(harness.manager.mirroredSelection, canonical)
    }

    func testCancelledMCPMirrorRequestDoesNotCancelBlockedPredecessorOrLatestSuccessor() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let first = StoredSelection(selectedPaths: ["/tmp/first.swift"])
        let latest = StoredSelection(selectedPaths: ["/tmp/latest.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        let gate = SelectionMirrorGate()
        harness.manager.firstMirrorGate = gate
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        let completion = SelectionMirrorCompletion(expectedCount: 2)

        let firstTask = Task { @MainActor in
            await coordinator.persistActiveSelection(first, source: .mcpTabContext)
            await completion.markCompleted()
        }
        let mirrorStarted = await gate.waitUntilStarted()
        XCTAssertTrue(mirrorStarted)
        guard mirrorStarted else { return }

        firstTask.cancel()
        let latestTask = Task { @MainActor in
            await coordinator.persistActiveSelection(latest, source: .mcpTabContext)
            await completion.markCompleted()
        }
        await waitForSelection(latest, in: harness)
        XCTAssertEqual(harness.manager.mirrorStartedSelections, [first])

        await gate.release()
        let completed = await completion.waitUntilComplete()
        XCTAssertTrue(completed)
        guard completed else {
            latestTask.cancel()
            return
        }
        _ = await firstTask.value
        _ = await latestTask.value

        XCTAssertEqual(harness.manager.mirrorStartedSelections, [first, latest])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [first, latest])
        XCTAssertEqual(harness.manager.mirroredSelection, latest)
    }

    private func waitForSelection(_ selection: StoredSelection, in harness: CoordinatorHarness) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline,
              harness.manager.composeTab(with: harness.tabID)?.selection != selection
        {
            await Task.yield()
        }
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, selection)
    }

    private func waitForMirrorAttempts(_ count: Int, in harness: CoordinatorHarness) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while harness.manager.mirrorCompletedSelections.count < count,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return harness.manager.mirrorCompletedSelections.count == count
    }

    func testMCPActiveSelectionFencesStaleUISnapshotBeforeMirrorBegins() async {
        let initial = StoredSelection()
        let canonical = StoredSelection(selectedPaths: ["/tmp/canonical.swift"], codemapAutoEnabled: false)
        let staleUI = StoredSelection()
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = staleUI
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        harness.manager.activeUISnapshotResolver = { selection, tabID in
            coordinator.selectionForActiveUISnapshot(selection, tabID: tabID)
        }
        harness.manager.presentationHandler = {
            _ = coordinator.activeSelectionSnapshot(flushPendingUI: true)
        }

        _ = await coordinator.persistActiveSelection(canonical, source: .mcpTabContext)

        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 1)
        XCTAssertEqual(harness.manager.composeTab(for: harness.identity)?.selection, canonical)
        XCTAssertEqual(harness.manager.mirrorStartedSelections, [canonical])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [canonical])
        XCTAssertEqual(harness.manager.mirroredSelection, canonical)

        // The fence is not ownership by value: a genuinely newer UI revision must still win.
        let newerUI = StoredSelection(selectedPaths: ["/tmp/newer-ui.swift"])
        harness.manager.presentationHandler = nil
        harness.manager.pendingUISelection = newerUI
        harness.manager.advanceLiveUISelectionRevision()
        XCTAssertEqual(
            coordinator.activeSelectionSnapshot(flushPendingUI: true).selection,
            newerUI
        )
    }

    func testMCPActiveSelectionCanDeferMirrorToReadFileAutoSelectionLane() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let next = StoredSelection(selectedPaths: ["/tmp/next.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        _ = await coordinator.persistActiveSelection(
            next,
            source: .mcpTabContext,
            mirrorToUI: false
        )

        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, next)
        XCTAssertTrue(harness.manager.mirrorStartedSelections.isEmpty)
        XCTAssertTrue(harness.manager.mirrorCompletedSelections.isEmpty)
        XCTAssertEqual(changes, [
            .init(tabID: harness.tabID, selection: next, source: .mcpTabContext)
        ])
    }

    func testDeferredMCPSelectionFencesQueuedUISnapshotUntilNewUIRevision() async {
        let initial = StoredSelection()
        let canonical = StoredSelection(selectedPaths: ["/tmp/worktree-only.swift"], codemapAutoEnabled: false)
        let staleUI = StoredSelection()
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.advanceLiveUISelectionRevision()
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        _ = await coordinator.persistActiveSelection(
            canonical,
            source: .mcpTabContext,
            mirrorToUI: false
        )

        XCTAssertEqual(harness.manager.presentedSelection, canonical)
        XCTAssertEqual(coordinator.selectionForActiveUISnapshot(staleUI, tabID: harness.tabID), canonical)

        // Programmatic tab restore may mutate the UI owner; refreshing the fence keeps its
        // delayed publisher from looking like a manual edit.
        harness.manager.advanceLiveUISelectionRevision()
        coordinator.refreshDeferredUISelectionFence(forTabID: harness.tabID)
        XCTAssertEqual(coordinator.selectionForActiveUISnapshot(staleUI, tabID: harness.tabID), canonical)

        // A later UI mutation wins even if its value returns to the pre-MCP baseline (ABA).
        harness.manager.advanceLiveUISelectionRevision()
        XCTAssertEqual(coordinator.selectionForActiveUISnapshot(staleUI, tabID: harness.tabID), staleUI)
    }

    func testDeferredMCPMirrorRefreshesFenceBeforeQueuedCatalogSnapshotPublishes() async {
        let first = StoredSelection(
            selectedPaths: ["/tmp/Full.swift"],

            codemapAutoEnabled: true
        )
        let latest = StoredSelection(
            selectedPaths: ["/tmp/Full.swift", "/tmp/Sliced.swift"],

            slices: ["/tmp/Sliced.swift": [LineRange(start: 4, end: 7)]],
            codemapAutoEnabled: true
        )
        let completeCatalog = StoredSelection(
            selectedPaths: ["/tmp/Full.swift", "/tmp/Sliced.swift"],

            codemapAutoEnabled: true
        )
        let harness = CoordinatorHarness(initialSelection: StoredSelection())
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        harness.manager.activeUISnapshotResolver = { selection, tabID in
            coordinator.selectionForActiveUISnapshot(selection, tabID: tabID)
        }
        harness.manager.advanceLiveUISelectionRevisionDuringMirror = true

        for expected in [first, latest] {
            _ = await coordinator.persistActiveSelection(
                expected,
                source: .mcpTabContext,
                mirrorToUI: false
            )
            harness.manager.pendingUISelection = completeCatalog

            await coordinator.mirrorSelectionToActiveUI(expected, forTabID: harness.tabID)

            // Model the already-enqueued selected-files debounce. This is not a read-file
            // drain or manage_selection get; it is the ordinary UI publication that runs
            // after the programmatic mirror has advanced the live selection revision.
            harness.manager.publishActiveComposeTabSnapshot(
                commitToMemory: true,
                touchModified: false
            )

            XCTAssertEqual(harness.manager.composeTab(for: harness.identity)?.selection, expected)
        }

        XCTAssertEqual(harness.manager.mirroredSelection, latest)
        XCTAssertEqual(harness.manager.publishedSelections, [first, latest])
        XCTAssertFalse(harness.manager.publishedSelections.contains(completeCatalog))
    }

    func testTwoSourceWindowsRejectDelayedOlderPropagationAfterNewerLocalMutation() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let older = StoredSelection(selectedPaths: ["/tmp/older.swift"])
        let newer = StoredSelection(selectedPaths: ["/tmp/newer.swift"])
        let workspaceID = UUID()
        let tabID = UUID()
        let revisionLedger = FakeMCPSelectionRevisionLedger()
        let firstWindow = CoordinatorHarness(
            initialSelection: initial,
            workspaceID: workspaceID,
            tabID: tabID,
            propagationRevisionLedger: revisionLedger
        )
        let secondWindow = CoordinatorHarness(
            initialSelection: initial,
            workspaceID: workspaceID,
            tabID: tabID,
            propagationRevisionLedger: revisionLedger
        )
        let firstCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: firstWindow.manager,
            store: firstWindow.store
        )
        let secondCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: secondWindow.manager,
            store: secondWindow.store
        )
        let olderPropagationGate = SelectionMirrorGate()

        firstWindow.manager.propagationHandler = { propagation in
            if propagation.selection == older {
                await olderPropagationGate.markStartedAndWaitForRelease()
            }
            _ = await secondCoordinator.persistSelection(
                propagation.selection,
                for: secondWindow.identity,
                source: .mcpPeerContext,
                mirrorToUIIfActive: false,
                peerSourceRevision: propagation.sourceRevision,
                peerMutationFence: MCPSelectionPeerMutationFence(
                    hostID: secondWindow.manager.mcpSelectionPropagationHostID
                )
            )
        }
        secondWindow.manager.propagationHandler = { propagation in
            _ = await firstCoordinator.persistSelection(
                propagation.selection,
                for: firstWindow.identity,
                source: .mcpPeerContext,
                mirrorToUIIfActive: false,
                peerSourceRevision: propagation.sourceRevision,
                peerMutationFence: MCPSelectionPeerMutationFence(
                    hostID: firstWindow.manager.mcpSelectionPropagationHostID
                )
            )
        }

        let olderTask = Task { @MainActor in
            await firstCoordinator.persistActiveSelection(
                older,
                source: .mcpTabContext,
                mirrorToUI: false
            )
        }
        let olderPropagationStarted = await olderPropagationGate.waitUntilStarted()
        XCTAssertTrue(olderPropagationStarted)
        guard olderPropagationStarted else { return }

        _ = await secondCoordinator.persistActiveSelection(
            newer,
            source: .mcpTabContext,
            mirrorToUI: false
        )
        XCTAssertEqual(firstWindow.manager.composeTab(for: firstWindow.identity)?.selection, newer)
        XCTAssertEqual(secondWindow.manager.composeTab(for: secondWindow.identity)?.selection, newer)

        await olderPropagationGate.release()
        _ = await olderTask.value

        XCTAssertEqual(firstWindow.manager.composeTab(for: firstWindow.identity)?.selection, newer)
        XCTAssertEqual(secondWindow.manager.composeTab(for: secondWindow.identity)?.selection, newer)
        XCTAssertEqual(firstWindow.manager.registeredSourceRevisions, [1])
        XCTAssertEqual(firstWindow.manager.acceptedPeerSourceRevisions, [2])
        XCTAssertEqual(secondWindow.manager.registeredSourceRevisions, [2])
        XCTAssertEqual(secondWindow.manager.rejectedPeerSourceRevisions, [1])
        XCTAssertEqual(firstWindow.manager.propagatedSelections, [older])
        XCTAssertEqual(secondWindow.manager.propagatedSelections, [newer])
    }

    func testPeerPropagationQueuedMirrorDoesNotApplyAfterPeerCloses() async {
        let peerCanonical = StoredSelection(selectedPaths: ["/tmp/peer-canonical.swift"])
        let propagated = StoredSelection(selectedPaths: ["/tmp/propagated.swift"])
        let workspaceID = UUID()
        let tabID = UUID()
        let revisionLedger = FakeMCPSelectionRevisionLedger()
        let source = CoordinatorHarness(
            initialSelection: StoredSelection(selectedPaths: ["/tmp/source.swift"]),
            workspaceID: workspaceID,
            tabID: tabID,
            propagationRevisionLedger: revisionLedger
        )
        let peer = CoordinatorHarness(
            initialSelection: peerCanonical,
            workspaceID: workspaceID,
            tabID: tabID,
            propagationRevisionLedger: revisionLedger
        )
        let sourceCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: source.manager,
            store: source.store
        )
        let peerCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: peer.manager,
            store: peer.store
        )
        let predecessorGate = SelectionMirrorGate()
        peer.manager.mirroredSelection = peerCanonical
        peer.manager.firstMirrorGate = predecessorGate
        source.manager.propagationPeerHostIDs = [peer.manager.mcpSelectionPropagationHostID]
        source.manager.propagationHandler = { propagation in
            _ = await peerCoordinator.persistSelection(
                propagation.selection,
                for: peer.identity,
                source: .mcpPeerContext,
                mirrorToUIIfActive: true,
                peerSourceRevision: propagation.sourceRevision,
                peerMutationFence: MCPSelectionPeerMutationFence(
                    hostID: peer.manager.mcpSelectionPropagationHostID
                )
            )
        }

        let predecessorTask = Task { @MainActor in
            await peerCoordinator.persistActiveSelection(peerCanonical, source: .mcpTabContext)
        }
        let predecessorStarted = await predecessorGate.waitUntilStarted()
        XCTAssertTrue(predecessorStarted)
        guard predecessorStarted else { return }

        let propagationTask = Task { @MainActor in
            await sourceCoordinator.persistActiveSelection(propagated, source: .mcpTabContext)
        }
        await waitForSelection(propagated, in: peer)
        XCTAssertEqual(peer.manager.acceptedPeerSourceRevisions, [2])
        XCTAssertEqual(peer.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(peer.manager.mirrorStartedSelections, [peerCanonical])

        peer.manager.mcpSelectionPropagationHostIsLive = false
        let storedUpdateCountAtClose = peer.manager.updateStoredOnlyCallCount
        await predecessorGate.release()
        _ = await predecessorTask.value
        _ = await propagationTask.value

        XCTAssertEqual(peer.manager.composeTab(for: peer.identity)?.selection, propagated)
        XCTAssertEqual(peer.manager.updateStoredOnlyCallCount, storedUpdateCountAtClose)
        XCTAssertEqual(peer.manager.mirrorStartedSelections, [peerCanonical])
        XCTAssertEqual(peer.manager.mirrorCompletedSelections, [peerCanonical])
        XCTAssertEqual(peer.manager.mirroredSelection, peerCanonical)
    }

    func testPersistActiveSelectionNoOpsWhenSelectionIsUnchanged() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = await coordinator.persistActiveSelection(initial, source: .runtimeMutation, mirrorToUI: true)

        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, initial)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 0)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
    }

    func testPersistVirtualSelectionStoresImmediatelyAndEmitsVirtualChange() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let next = StoredSelection(
            selectedPaths: ["/tmp/virtual.swift"],
            slices: ["/tmp/virtual.swift": [LineRange(start: 2, end: 5)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = await coordinator.persistVirtualSelection(next, for: harness.identity)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, next)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .virtual))
    }

    func testPersistVirtualSelectionNoOpsWhenSelectionIsUnchanged() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = await coordinator.persistVirtualSelection(initial, for: harness.identity)

        XCTAssertEqual(persisted, initial)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, initial)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 0)
        XCTAssertTrue(changes.isEmpty)
    }

    func testPersistSelectionRoutesInactiveTabAndEmitsMCPSource() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/active.swift"])
        let inactiveTabID = UUID()
        let inactiveInitial = StoredSelection(selectedPaths: ["/tmp/inactive-old.swift"])
        let next = StoredSelection(
            selectedPaths: ["/tmp/inactive-new.swift"],

            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.appendTab(ComposeTabState(id: inactiveTabID, name: "Agent", selection: inactiveInitial))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = await coordinator.persistSelection(
            next,
            for: WorkspaceSelectionIdentity(workspaceID: harness.workspaceID, tabID: inactiveTabID),
            source: .mcpTabContext
        )

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.manager.composeTab(with: inactiveTabID)?.selection, next)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, initial)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(harness.manager.presentedSelection, next)
        XCTAssertEqual(changes.last, .init(tabID: inactiveTabID, selection: next, source: .mcpTabContext))
    }

    func testMCPSelectionClearRestoresAutoModeAndNextFullAddPreservesAutoFlag() async {
        let initial = StoredSelection(
            manualCodemapPaths: ["/tmp/Manual.swift"],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let cleared = await coordinator.persistActiveSelection(
            StoredSelection(),
            source: .mcpTabContext
        )

        XCTAssertEqual(cleared, StoredSelection())
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, StoredSelection())
        XCTAssertEqual(harness.manager.mirrorStartedSelections, [StoredSelection()])
        XCTAssertEqual(harness.manager.mirrorCompletedSelections, [StoredSelection()])
        XCTAssertEqual(harness.manager.mirroredSelection, StoredSelection())

        let current = harness.manager.composeTab(with: harness.tabID)?.selection
        let nextFullAdd = StoredSelection(
            selectedPaths: ["/tmp/Full.swift"],
            codemapAutoEnabled: current?.codemapAutoEnabled ?? false
        )
        let persistedFullAdd = await coordinator.persistActiveSelection(
            nextFullAdd,
            source: .mcpTabContext
        )

        XCTAssertEqual(persistedFullAdd.selectedPaths, ["/tmp/Full.swift"])
        XCTAssertTrue(persistedFullAdd.codemapAutoEnabled)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, persistedFullAdd)
    }

    func testAtomicArtifactTransformMergesIntoLatestCanonicalSelection() async throws {
        let sourcePath = "/tmp/source.swift"
        let concurrentPath = "/tmp/concurrent.swift"
        let mapPath = "/tmp/workspace/_git_data/repos/repo/snapshot/MAP.txt"
        let patchPath = "/tmp/workspace/_git_data/repos/repo/snapshot/diff/all.patch"
        let initial = StoredSelection(
            selectedPaths: [sourcePath],

            slices: [sourcePath: [LineRange(start: 2, end: 6)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let concurrent = StoredSelection(
            selectedPaths: [sourcePath, concurrentPath],

            slices: initial.slices,
            codemapAutoEnabled: initial.codemapAutoEnabled
        )
        _ = await coordinator.persistSelection(
            concurrent,
            for: harness.identity,
            source: .runtimeMutation,
            mirrorToUIIfActive: false
        )

        let candidates = [
            GitDiffPublishedArtifact(
                kind: .map,
                absolutePath: mapPath,
                gitDataRelativePath: "repos/repo/snapshot/MAP.txt",
                clientAlias: "_git_data/repos/repo/snapshot/MAP.txt",
                selectionDisposition: .primaryAutoSelect
            ),
            GitDiffPublishedArtifact(
                kind: .allPatch,
                absolutePath: patchPath,
                gitDataRelativePath: "repos/repo/snapshot/diff/all.patch",
                clientAlias: "_git_data/repos/repo/snapshot/diff/all.patch",
                selectionDisposition: .primaryAutoSelect
            )
        ]
        let transactionValue = await coordinator.transformSelection(
            for: harness.identity,
            source: .mcpTabContext,
            mirrorToUIIfActive: false
        ) { latest in
            WorkspaceGitDiffArtifactSelectionService()
                .mergePrimaryArtifacts(existing: latest, candidates: candidates)
                .selection
        }
        let transaction = try XCTUnwrap(transactionValue)

        XCTAssertEqual(transaction.before, concurrent)
        XCTAssertEqual(transaction.after.selectedPaths, [sourcePath, concurrentPath, mapPath, patchPath])
        XCTAssertEqual(transaction.after.slices, initial.slices)
        XCTAssertFalse(transaction.after.codemapAutoEnabled)
        XCTAssertEqual(harness.manager.composeTab(for: harness.identity)?.selection, transaction.after)
    }

    func testSelectionSnapshotForInactiveTabDoesNotFlushActiveUI() {
        let initial = StoredSelection(selectedPaths: ["/tmp/active.swift"])
        let inactiveTabID = UUID()
        let inactiveSelection = StoredSelection(selectedPaths: ["/tmp/agent.swift"], codemapAutoEnabled: false)
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = StoredSelection(selectedPaths: ["/tmp/pending-active.swift"])
        harness.manager.appendTab(ComposeTabState(id: inactiveTabID, name: "Agent", selection: inactiveSelection))
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let snapshot = coordinator.selectionSnapshot(for: inactiveTabID, flushPendingUIIfActive: true)

        XCTAssertEqual(snapshot, .init(tabID: inactiveTabID, selection: inactiveSelection, isVirtual: true))
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 0)
    }

    func testApplyingSelectionMirrorGuardSuppressesFlushPublication() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let pending = StoredSelection(selectedPaths: ["/tmp/pending.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = pending
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        await coordinator.withApplyingSelectionMirror {
            XCTAssertTrue(coordinator.isApplyingSelectionMirror)
            let snapshot = coordinator.activeSelectionSnapshot(flushPendingUI: true)
            XCTAssertEqual(snapshot.selection, initial)
            XCTAssertEqual(harness.manager.publishSnapshotCallCount, 0)
        }

        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
        let flushed = coordinator.activeSelectionSnapshot(flushPendingUI: true)
        XCTAssertEqual(flushed.selection, pending)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 1)
    }

    func testUIFlushDoesNotRepublishWhenSubscriberFlushesUnchangedSelection() {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let pending = StoredSelection(selectedPaths: ["/tmp/pending.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = pending
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []

        coordinator.changes
            .sink { change in
                changes.append(change)
                _ = coordinator.activeSelectionSnapshot(flushPendingUI: true)
            }
            .store(in: &cancellables)

        let flushed = coordinator.activeSelectionSnapshot(flushPendingUI: true)

        XCTAssertEqual(flushed.selection, pending)
        XCTAssertEqual(changes, [.init(tabID: harness.tabID, selection: pending, source: .uiFlush)])
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 2)
    }

    func testSaveSnapshotPrefersMatchingCanonicalSelectionOverStaleUISnapshot() {
        let activeTabID = UUID()
        let liveUI = StoredSelection(
            selectedPaths: ["/tmp/stale.swift"],
            slices: ["/tmp/stale.swift": [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: true
        )
        let canonical = StoredSelection(selectedPaths: ["/tmp/fixture.swift"], codemapAutoEnabled: false)

        let stored = StoredSelection(selectedPaths: ["/tmp/stored.swift"])

        let decision = WorkspaceManagerViewModel.selectionForSaveSnapshot(
            liveUISelection: liveUI,
            storedSelection: stored,
            canonicalSelection: canonical,
            canonicalTabID: activeTabID,
            activeTabID: activeTabID
        )

        XCTAssertEqual(decision.selection, canonical)
        XCTAssertEqual(decision.owner, .canonicalCoordinator)
    }

    func testSaveSnapshotFallsBackToStoredSelectionWhenCanonicalIsUnusable() {
        let liveUI = StoredSelection(selectedPaths: ["/tmp/live.swift"])
        let stored = StoredSelection(selectedPaths: ["/tmp/stored.swift"], codemapAutoEnabled: false)
        let canonical = StoredSelection(selectedPaths: ["/tmp/other.swift"], codemapAutoEnabled: false)
        let activeTabID = UUID()
        let scenarios: [(name: String, canonicalSelection: StoredSelection?, canonicalTabID: UUID?)] = [
            ("canonical tab does not match", canonical, UUID()),
            ("canonical selection is missing", nil, nil)
        ]

        for scenario in scenarios {
            let decision = WorkspaceManagerViewModel.selectionForSaveSnapshot(
                liveUISelection: liveUI,
                storedSelection: stored,
                canonicalSelection: scenario.canonicalSelection,
                canonicalTabID: scenario.canonicalTabID,
                activeTabID: activeTabID
            )

            XCTAssertEqual(decision.selection, stored, scenario.name)
            XCTAssertEqual(decision.owner, .storedComposeTab, scenario.name)
        }
    }
}

@MainActor
private final class CoordinatorHarness {
    let store = WorkspaceFileContextStore()
    let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore())
    let tabID: UUID
    let manager: FakeWorkspaceSelectionManager

    var workspaceID: UUID {
        manager.activeWorkspace!.id
    }

    var identity: WorkspaceSelectionIdentity {
        WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
    }

    init(
        initialSelection: StoredSelection,
        workspaceID: UUID = UUID(),
        tabID: UUID = UUID(),
        propagationRevisionLedger: FakeMCPSelectionRevisionLedger? = nil
    ) {
        self.tabID = tabID
        let tab = ComposeTabState(id: tabID, name: "Test", selection: initialSelection)
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: "Test Workspace",
            repoPaths: [],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
        manager = FakeWorkspaceSelectionManager(
            workspace: workspace,
            fileManager: fileManager,
            propagationRevisionLedger: propagationRevisionLedger ?? FakeMCPSelectionRevisionLedger()
        )
    }
}

@MainActor
private final class FakeMCPSelectionRevisionLedger {
    private var nextRevision: UInt64 = 1

    func allocate() -> UInt64 {
        defer { nextRevision &+= 1 }
        return nextRevision
    }
}

private actor SelectionMirrorGate {
    private var started = false
    private var released = false

    func markStartedAndWaitForRelease(timeout: Duration = .seconds(5)) async {
        started = true
        let deadline = ContinuousClock.now + timeout
        while !released, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !started, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return started
    }

    func release() {
        released = true
    }
}

private actor SelectionMirrorCompletion {
    private let expectedCount: Int
    private var completedCount = 0

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func markCompleted() {
        completedCount += 1
    }

    func waitUntilComplete(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while completedCount < expectedCount, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completedCount == expectedCount
    }
}

@MainActor
private final class FakeWorkspaceSelectionManager: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    private(set) var selectionMirrorContextRevision: UInt64 = 0
    private(set) var liveUISelectionRevision: UInt64 = 0
    let fileManager: WorkspaceFilesViewModel
    var pendingUISelection: StoredSelection?
    var activeUISnapshotResolver: ((StoredSelection, UUID) -> StoredSelection)?
    var presentationHandler: (() -> Void)?
    var advanceLiveUISelectionRevisionDuringMirror = false
    private(set) var publishedSelections: [StoredSelection] = []
    private(set) var publishSnapshotCallCount = 0
    private(set) var updateStoredOnlyCallCount = 0
    var firstMirrorGate: SelectionMirrorGate?
    var mirrorGatesByAttempt: [Int: SelectionMirrorGate] = [:]
    private(set) var mirrorStartedSelections: [StoredSelection] = []
    private(set) var mirrorCompletedSelections: [StoredSelection] = []
    var mirroredSelection: StoredSelection?
    private(set) var presentedSelection: StoredSelection?
    let mcpSelectionPropagationHostID = UUID()
    var mcpSelectionPropagationHostIsLive = true
    var propagationPeerHostIDs: Set<UUID> = []
    var propagationHandler: ((MCPSelectionPeerPropagation) async -> Void)?
    private let propagationRevisionLedger: FakeMCPSelectionRevisionLedger
    private var latestMCPSelectionRevisionByIdentity: [WorkspaceSelectionIdentity: UInt64] = [:]
    private(set) var registeredSourceRevisions: [UInt64] = []
    private(set) var acceptedPeerSourceRevisions: [UInt64] = []
    private(set) var rejectedPeerSourceRevisions: [UInt64] = []
    private(set) var propagatedSelections: [StoredSelection] = []

    init(
        workspace: WorkspaceModel,
        fileManager: WorkspaceFilesViewModel,
        propagationRevisionLedger: FakeMCPSelectionRevisionLedger
    ) {
        activeWorkspace = workspace
        self.fileManager = fileManager
        self.propagationRevisionLedger = propagationRevisionLedger
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first(where: { $0.id == id })
    }

    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState? {
        guard activeWorkspace?.id == identity.workspaceID else { return nil }
        return activeWorkspace?.composeTabs.first(where: { $0.id == identity.tabID })
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {
        publishSnapshotCallCount += 1
        guard commitToMemory,
              let pendingUISelection,
              var workspace = activeWorkspace,
              let activeID = workspace.activeComposeTabID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == activeID })
        else { return }
        let publishedSelection = activeUISnapshotResolver?(pendingUISelection, activeID) ?? pendingUISelection
        workspace.composeTabs[index].selection = publishedSelection
        publishedSelections.append(publishedSelection)
        if touchModified {
            workspace.composeTabs[index].lastModified = Date()
        }
        activeWorkspace = workspace
    }

    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async {
        guard activeWorkspace?.id == workspaceID,
              activeWorkspace?.activeComposeTabID == tabID
        else { return }
        mirrorStartedSelections.append(selection)
        let attempt = mirrorStartedSelections.count
        if let gate = mirrorGatesByAttempt[attempt] {
            await gate.markStartedAndWaitForRelease()
        } else if attempt == 1, let firstMirrorGate {
            await firstMirrorGate.markStartedAndWaitForRelease()
        }
        mirroredSelection = selection
        mirrorCompletedSelections.append(selection)
        if advanceLiveUISelectionRevisionDuringMirror {
            liveUISelectionRevision &+= 1
        }
    }

    func appendTab(_ tab: ComposeTabState) {
        guard var workspace = activeWorkspace else { return }
        workspace.composeTabs.append(tab)
        activeWorkspace = workspace
    }

    func setActiveTab(_ tabID: UUID) {
        guard var workspace = activeWorkspace,
              workspace.activeComposeTabID != tabID,
              workspace.composeTabs.contains(where: { $0.id == tabID })
        else { return }
        workspace.activeComposeTabID = tabID
        activeWorkspace = workspace
        selectionMirrorContextRevision &+= 1
    }

    func updateComposeTabSelectionPresentation(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity
    ) {
        guard activeWorkspace?.id == identity.workspaceID else { return }
        presentedSelection = selection
        presentationHandler?()
    }

    func registerMCPSelectionSourceMutation(
        for identity: WorkspaceSelectionIdentity
    ) -> MCPSelectionPropagationRegistration {
        let revision = propagationRevisionLedger.allocate()
        latestMCPSelectionRevisionByIdentity[identity] = revision
        registeredSourceRevisions.append(revision)
        return MCPSelectionPropagationRegistration(
            sourceRevision: revision,
            peerHostIDs: propagationPeerHostIDs
        )
    }

    func acceptMCPPeerSelectionRevision(
        _ revision: UInt64,
        for identity: WorkspaceSelectionIdentity
    ) -> Bool {
        guard revision > latestMCPSelectionRevisionByIdentity[identity, default: 0] else {
            rejectedPeerSourceRevisions.append(revision)
            return false
        }
        latestMCPSelectionRevisionByIdentity[identity] = revision
        acceptedPeerSourceRevisions.append(revision)
        return true
    }

    func canCommitMCPSelectionPeerMutation(_ fence: MCPSelectionPeerMutationFence) -> Bool {
        mcpSelectionPropagationHostIsLive && fence.hostID == mcpSelectionPropagationHostID
    }

    func propagateMCPSelectionToPeerHosts(_ propagation: MCPSelectionPeerPropagation) async {
        propagatedSelections.append(propagation.selection)
        await propagationHandler?(propagation)
    }

    func advanceLiveUISelectionRevision() {
        liveUISelectionRevision &+= 1
    }

    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool {
        updateStoredOnlyCallCount += 1
        guard var workspace = activeWorkspace,
              workspace.id == workspaceID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
        return true
    }
}
