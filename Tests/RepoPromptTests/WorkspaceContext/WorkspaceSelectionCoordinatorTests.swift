import Combine
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceSelectionCoordinatorTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testActiveSelectionSnapshotReadsCanonicalActiveTab() {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"], codemapAutoEnabled: true)
        let harness = CoordinatorHarness(initialSelection: initial)

        let snapshot = harness.coordinator.activeSelectionSnapshot(flushPendingUI: false)

        XCTAssertEqual(snapshot.tabID, harness.tabID)
        XCTAssertEqual(snapshot.selection, initial)
        XCTAssertFalse(snapshot.isVirtual)
    }

    func testPersistActiveSelectionWritesCanonicalTabAndPublishesWhileMirrorGuardIsActive() async {
        let harness = CoordinatorHarness(initialSelection: StoredSelection(selectedPaths: ["/tmp/initial.swift"]))
        let next = StoredSelection(
            selectedPaths: ["/tmp/next.swift"],
            autoCodemapPaths: ["/tmp/next_dependency.swift"],
            slices: ["/tmp/next.swift": [LineRange(start: 4, end: 8)]],
            codemapAutoEnabled: false
        )
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        var mirrorGuardWasActive = false
        harness.coordinator.changes
            .sink { change in
                changes.append(change)
                mirrorGuardWasActive = harness.coordinator.isApplyingSelectionMirror
            }
            .store(in: &cancellables)

        let persisted = await harness.coordinator.persistActiveSelection(next, source: .runtimeMutation, mirrorToUI: true)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.session.workspaceSessionController.workspace(id: harness.workspaceID)?.composeTabs.first?.selection, next)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .runtimeMutation))
        XCTAssertTrue(mirrorGuardWasActive)
        XCTAssertFalse(harness.coordinator.isApplyingSelectionMirror)
    }

    func testPersistVirtualSelectionPublishesVirtualChange() {
        let harness = CoordinatorHarness(initialSelection: StoredSelection())
        let next = StoredSelection(
            selectedPaths: ["/tmp/virtual.swift"],
            slices: ["/tmp/virtual.swift": [LineRange(start: 2, end: 5)]],
            codemapAutoEnabled: false
        )
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        harness.coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = harness.coordinator.persistVirtualSelection(next, for: harness.tabID)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.session.workspaceSessionController.workspace(id: harness.workspaceID)?.composeTabs.first?.selection, next)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .virtual))
    }

    func testPersistSelectionUsesRequestedSourceForActiveTab() async {
        let harness = CoordinatorHarness(initialSelection: StoredSelection())
        let next = StoredSelection(selectedPaths: ["/tmp/mcp.swift"])
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        harness.coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = await harness.coordinator.persistSelection(next, for: harness.tabID, source: .mcpTabContext)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .mcpTabContext))
    }

    func testDirectCoreSessionMutationPublishesMirrorChangeThroughCombineBridge() {
        let harness = CoordinatorHarness(initialSelection: StoredSelection())
        let next = StoredSelection(selectedPaths: ["/tmp/direct.swift"])
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        harness.coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        harness.session.workspaceSessionController.mutateComposeTab(
            workspaceID: harness.workspaceID,
            tabID: harness.tabID
        ) { $0.selection = next }

        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .mirror))
    }

    func testApplyingSelectionMirrorGuardSuppressesFlushAttempt() async {
        let harness = CoordinatorHarness(initialSelection: StoredSelection(selectedPaths: ["/tmp/initial.swift"]))

        await harness.coordinator.withApplyingSelectionMirror {
            XCTAssertTrue(harness.coordinator.isApplyingSelectionMirror)
            let snapshot = harness.coordinator.activeSelectionSnapshot(flushPendingUI: true)
            XCTAssertEqual(snapshot.selection.selectedPaths, ["/tmp/initial.swift"])
        }

        XCTAssertFalse(harness.coordinator.isApplyingSelectionMirror)
    }

    func testSaveSnapshotPrefersMatchingCanonicalSelectionOverStaleUISnapshot() {
        let activeTabID = UUID()
        let liveUI = StoredSelection(selectedPaths: ["/tmp/stale.swift"])
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

        for scenario in [(canonical as StoredSelection?, UUID() as UUID?), (nil, nil)] {
            let decision = WorkspaceManagerViewModel.selectionForSaveSnapshot(
                liveUISelection: liveUI,
                storedSelection: stored,
                canonicalSelection: scenario.0,
                canonicalTabID: scenario.1,
                activeTabID: activeTabID
            )
            XCTAssertEqual(decision.selection, stored)
            XCTAssertEqual(decision.owner, .storedComposeTab)
        }
    }
}

@MainActor
private final class CoordinatorHarness {
    let session: RepoPromptCoreSession
    let coordinator: WorkspaceSelectionCoordinator
    let workspaceID: UUID
    let tabID: UUID

    init(initialSelection: StoredSelection) {
        let graph = EmbeddedWorkspaceRepositoryFactory.make()
        let runtime = RepoPromptEmbeddedWorkspaceRuntimeFactory().makeRuntime()
        session = RepoPromptCoreSession(
            routingSessionID: MCPRoutingSessionID(rawValue: 99001),
            workspaceRepository: graph.repository,
            workspacePersistenceWriter: graph.writer,
            workspaceAccessPolicy: UnrestrictedWorkspaceAccessPolicy(),
            runtime: runtime
        )
        let tab = ComposeTabState(name: "Test", selection: initialSelection)
        let workspace = WorkspaceModel(
            name: "Test Workspace",
            repoPaths: [],
            composeTabs: [tab],
            activeComposeTabID: tab.id
        )
        coordinator = WorkspaceSelectionCoordinator(
            controller: session.workspaceSelectionController,
            store: session.workspaceFileContextStore
        )
        workspaceID = workspace.id
        tabID = tab.id
        session.workspaceSessionController.replaceAll([workspace], activeWorkspaceID: workspace.id)
    }
}
