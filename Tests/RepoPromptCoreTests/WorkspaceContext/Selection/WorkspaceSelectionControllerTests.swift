import Foundation
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceSelectionControllerTests: XCTestCase {
    func testPersistActiveSelectionUsesSessionAuthorityAndAllocatesRevision() throws {
        let session = makeSessionController()
        let workspace = makeSlice1Workspace(selection: StoredSelection(selectedPaths: ["/tmp/root/Before.swift"]))
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        session.replaceAll([workspace], activeWorkspaceID: workspace.id)
        let controller = makeSelectionController(session: session)
        var changes: [WorkspaceSelectionController.Change] = []
        let token = controller.observe { changes.append($0) }
        let next = StoredSelection(selectedPaths: ["/tmp/root/After.swift"], codemapAutoEnabled: false)

        controller.persistActiveSelection(next)

        XCTAssertEqual(session.workspace(id: workspace.id)?.composeTabs.first?.selection, next)
        XCTAssertGreaterThan(session.selectionRevision(workspaceID: workspace.id, tabID: tabID), 0)
        XCTAssertEqual(changes, [.init(tabID: tabID, selection: next, source: .runtimeMutation)])
        token.cancel()
    }

    func testDirectSessionSelectionMutationPublishesMirrorChange() throws {
        let session = makeSessionController()
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        session.replaceAll([workspace], activeWorkspaceID: workspace.id)
        let controller = makeSelectionController(session: session)
        var changes: [WorkspaceSelectionController.Change] = []
        let token = controller.observe { changes.append($0) }
        let next = StoredSelection(selectedPaths: ["/tmp/root/Direct.swift"])

        session.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) { $0.selection = next }

        XCTAssertEqual(changes, [.init(tabID: tabID, selection: next, source: .mirror)])
        token.cancel()
    }

    func testExternalUICommitPublishesUIFlushAndAllocatesRevision() throws {
        let session = makeSessionController()
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        session.replaceAll([workspace], activeWorkspaceID: workspace.id)
        let controller = makeSelectionController(session: session)
        var changes: [WorkspaceSelectionController.Change] = []
        let token = controller.observe { changes.append($0) }
        let pending = try XCTUnwrap(controller.beginExternallyCommittedSelection(source: .uiFlush))
        let next = StoredSelection(selectedPaths: ["/tmp/root/UI.swift"])

        session.mutateComposeTab(
            workspaceID: workspace.id,
            tabID: tabID,
            options: .hydration
        ) { $0.selection = next }
        controller.finishExternallyCommittedSelection(target: pending.target, previous: pending.previous)

        XCTAssertEqual(changes, [.init(tabID: tabID, selection: next, source: .uiFlush)])
        XCTAssertGreaterThan(session.selectionRevision(workspaceID: workspace.id, tabID: tabID), 0)
        token.cancel()
    }

    func testActiveSelectionIsScopedByWorkspaceWhenTabIDsCollide() throws {
        let sharedTabID = UUID()
        let firstTab = ComposeTabState(id: sharedTabID, name: "First", selection: StoredSelection(selectedPaths: ["/tmp/first.swift"]))
        let secondTab = ComposeTabState(id: sharedTabID, name: "Second", selection: StoredSelection(selectedPaths: ["/tmp/second.swift"]))
        let first = WorkspaceModel(name: "First", repoPaths: ["/tmp/first"], composeTabs: [firstTab], activeComposeTabID: sharedTabID)
        let second = WorkspaceModel(name: "Second", repoPaths: ["/tmp/second"], composeTabs: [secondTab], activeComposeTabID: sharedTabID)
        let session = makeSessionController()
        session.replaceAll([first, second], activeWorkspaceID: second.id)
        let controller = makeSelectionController(session: session)

        let snapshot = controller.activeSelectionSnapshot()

        XCTAssertEqual(snapshot.tabID, sharedTabID)
        XCTAssertEqual(snapshot.selection, secondTab.selection)
        XCTAssertEqual(controller.target(forTabID: sharedTabID), .init(workspaceID: second.id, tabID: sharedTabID))
    }

    func testAmbiguousInactiveVirtualTabIDIsRejected() {
        let duplicateID = UUID()
        let firstActive = ComposeTabState(name: "First Active")
        let secondActive = ComposeTabState(name: "Second Active")
        let first = WorkspaceModel(
            name: "First",
            repoPaths: ["/tmp/first"],
            composeTabs: [firstActive, ComposeTabState(id: duplicateID, name: "Duplicate")],
            activeComposeTabID: firstActive.id
        )
        let second = WorkspaceModel(
            name: "Second",
            repoPaths: ["/tmp/second"],
            composeTabs: [secondActive, ComposeTabState(id: duplicateID, name: "Duplicate")],
            activeComposeTabID: secondActive.id
        )
        let session = makeSessionController()
        session.replaceAll([first, second], activeWorkspaceID: second.id)
        let controller = makeSelectionController(session: session)
        let attempted = StoredSelection(selectedPaths: ["/tmp/ambiguous.swift"])

        XCTAssertNil(controller.target(forTabID: duplicateID))
        controller.persistVirtualSelection(attempted, for: duplicateID)
        XCTAssertNotEqual(session.workspace(id: first.id)?.composeTabs.last?.selection, attempted)
        XCTAssertNotEqual(session.workspace(id: second.id)?.composeTabs.last?.selection, attempted)
    }

    func testObserverCanCancelDuringPublication() throws {
        let session = makeSessionController()
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        session.replaceAll([workspace], activeWorkspaceID: workspace.id)
        let controller = makeSelectionController(session: session)
        var calls = 0
        var token: WorkspaceSelectionObservationToken?
        token = controller.observe { _ in
            calls += 1
            token?.cancel()
        }

        session.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) {
            $0.selection = StoredSelection(selectedPaths: ["/tmp/one.swift"])
        }
        session.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) {
            $0.selection = StoredSelection(selectedPaths: ["/tmp/two.swift"])
        }

        XCTAssertEqual(calls, 1)
    }

    private func makeSelectionController(session: WorkspaceSessionController) -> WorkspaceSelectionController {
        WorkspaceSelectionController(
            sessionController: session,
            mutationService: WorkspaceSelectionMutationService(store: WorkspaceFileContextStore())
        )
    }

    private func makeSessionController() -> WorkspaceSessionController {
        let graph = Slice1TestWorkspaceGraph(root: FileManager.default.temporaryDirectory)
        return WorkspaceSessionController(
            repository: graph.repository,
            persistenceWriter: graph.writer,
            accessPolicy: UnrestrictedWorkspaceAccessPolicy()
        )
    }
}
