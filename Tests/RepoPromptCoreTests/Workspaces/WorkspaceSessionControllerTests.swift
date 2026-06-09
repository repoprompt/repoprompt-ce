import Foundation
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceSessionControllerTests: XCTestCase {
    func testReplaceAllPublishesImmutableSnapshotsInGenerationOrder() {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let first = makeSlice1Workspace(name: "First")
        let second = makeSlice1Workspace(name: "Second")
        var snapshots: [WorkspaceSessionSnapshot] = []
        let token = controller.observe { snapshots.append($0) }

        controller.replaceAll([first, second], activeWorkspaceID: second.id)
        controller.setActiveWorkspaceID(first.id)

        XCTAssertEqual(snapshots.map(\.generation), [0, 1, 2])
        XCTAssertEqual(snapshots[1].workspaces.map(\.id), [first.id, second.id])
        XCTAssertEqual(snapshots[1].activeWorkspaceID, second.id)
        XCTAssertEqual(snapshots[2].activeWorkspaceID, first.id)
        token.cancel()
    }

    func testWorkspaceActiveAndComposeTabMutationsUseSingleAuthority() throws {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let first = makeSlice1Workspace(name: "First")
        let second = makeSlice1Workspace(name: "Second")
        controller.replaceAll([first, second], activeWorkspaceID: first.id)
        let firstTabID = try XCTUnwrap(first.activeComposeTabID)

        controller.mutateWorkspace(id: first.id) { workspace in
            workspace.name = "Renamed"
            workspace.repoPaths = ["/tmp/A", "/tmp/B"]
        }
        controller.mutateActiveWorkspace { workspace in
            workspace.isHiddenInMenus = true
        }
        controller.mutateComposeTab(workspaceID: first.id, tabID: firstTabID) { tab in
            tab.name = "Focused"
            tab.promptText = "updated prompt"
        }

        let updated = try XCTUnwrap(controller.workspace(id: first.id))
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertEqual(updated.repoPaths, ["/tmp/A", "/tmp/B"])
        XCTAssertTrue(updated.isHiddenInMenus)
        XCTAssertEqual(updated.composeTabs[0].name, "Focused")
        XCTAssertEqual(updated.composeTabs[0].promptText, "updated prompt")
        XCTAssertEqual(controller.workspaces.map(\.id), [first.id, second.id])
    }

    func testTransactionAtomicallyCreatesReordersDeletesAndSelectsFallback() {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let first = makeSlice1Workspace(name: "First")
        let second = makeSlice1Workspace(name: "Second")
        let third = makeSlice1Workspace(name: "Third")
        controller.replaceAll([first, second], activeWorkspaceID: first.id)
        let generationBefore = controller.snapshot.generation

        controller.transaction { transaction in
            transaction.workspaces.append(third)
            transaction.workspaces.swapAt(0, 2)
            transaction.workspaces.removeAll { $0.id == second.id }
            transaction.activeWorkspaceID = third.id
        }

        XCTAssertEqual(controller.snapshot.generation, generationBefore + 1)
        XCTAssertEqual(controller.workspaces.map(\.id), [third.id, first.id])
        XCTAssertEqual(controller.activeWorkspaceID, third.id)
        XCTAssertNil(controller.workspace(id: second.id))
    }

    func testDirtyGenerationAndRepositoryBaselineAdvanceOnlyForCurrentSave() throws {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let workspace = makeSlice1Workspace(repoPaths: ["/tmp/A"])
        controller.replaceAll([workspace], activeWorkspaceID: workspace.id)

        XCTAssertFalse(controller.isDirty(workspaceID: workspace.id))
        XCTAssertFalse(controller.hasLocalRepoPathEdit(workspaceID: workspace.id))

        controller.mutateWorkspace(id: workspace.id) { $0.repoPaths = ["/tmp/B"] }
        let firstGeneration = controller.stateGeneration(workspaceID: workspace.id)
        let firstSave = try XCTUnwrap(controller.workspace(id: workspace.id))
        XCTAssertTrue(controller.isDirty(workspaceID: workspace.id))
        XCTAssertTrue(controller.hasLocalRepoPathEdit(workspaceID: workspace.id))

        controller.mutateWorkspace(id: workspace.id) { $0.name = "Newer local state" }
        controller.recordSaveCompletion(
            workspaceID: workspace.id,
            capturedGeneration: firstGeneration,
            persistedWorkspace: firstSave
        )
        XCTAssertTrue(controller.isDirty(workspaceID: workspace.id))
        XCTAssertEqual(controller.repositoryBaseline(workspaceID: workspace.id), ["/tmp/A"])

        let currentGeneration = controller.stateGeneration(workspaceID: workspace.id)
        let current = try XCTUnwrap(controller.workspace(id: workspace.id))
        controller.recordSaveCompletion(
            workspaceID: workspace.id,
            capturedGeneration: currentGeneration,
            persistedWorkspace: current
        )
        XCTAssertFalse(controller.isDirty(workspaceID: workspace.id))
    }

    func testProcessSharedWriterAllocatesSelectionRevisionsAcrossControllers() throws {
        let graph = makeGraph()
        let firstController = makeController(graph: graph)
        let secondController = makeController(graph: graph)
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        firstController.replaceAll([workspace], activeWorkspaceID: workspace.id)
        secondController.replaceAll([workspace], activeWorkspaceID: workspace.id)
        let initial = max(
            firstController.selectionRevision(workspaceID: workspace.id, tabID: tabID),
            secondController.selectionRevision(workspaceID: workspace.id, tabID: tabID)
        )
        XCTAssertEqual(initial, 0)

        firstController.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) {
            $0.selection = StoredSelection(selectedPaths: ["/tmp/root/A.swift"])
        }
        let firstRevision = firstController.selectionRevision(workspaceID: workspace.id, tabID: tabID)
        secondController.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) {
            $0.selection = StoredSelection(selectedPaths: ["/tmp/root/B.swift"])
        }
        let secondRevision = secondController.selectionRevision(workspaceID: workspace.id, tabID: tabID)

        XCTAssertGreaterThan(firstRevision, initial)
        XCTAssertGreaterThan(secondRevision, firstRevision)
    }

    func testStaleControllerHydrationCannotOutrankAuthoritativeSelectionMutation() async throws {
        let root = try makeSlice1TemporaryDirectory(named: #function) { url in
            self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        let graph = Slice1TestWorkspaceGraph(root: root)
        let firstController = makeController(graph: graph)
        let staleController = makeController(graph: graph)
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        let url = root.appendingPathComponent("workspace.json")
        firstController.replaceAll([workspace], activeWorkspaceID: workspace.id)

        firstController.mutateComposeTab(workspaceID: workspace.id, tabID: tabID) {
            $0.selection = StoredSelection(selectedPaths: ["/tmp/root/Authoritative.swift"])
        }
        let authoritative = try XCTUnwrap(firstController.workspace(id: workspace.id))
        let authoritativeMetadata = firstController.saveMetadata(for: authoritative, source: "authoritative", owner: .none)
        let authoritativeReceipt = try await graph.writer.enqueueWorkspace(
            authoritative,
            url: url,
            metadata: authoritativeMetadata
        )
        let authoritativeCompletion = await graph.writer.flush(authoritativeReceipt)
        XCTAssertTrue(authoritativeCompletion.succeeded)

        staleController.replaceAll([workspace], activeWorkspaceID: workspace.id)
        XCTAssertEqual(staleController.selectionRevision(workspaceID: workspace.id, tabID: tabID), 0)
        staleController.mutateWorkspace(id: workspace.id) { $0.name = "Newer unrelated edit" }
        let stale = try XCTUnwrap(staleController.workspace(id: workspace.id))
        let staleMetadata = staleController.saveMetadata(for: stale, source: "stale", owner: .none)
        XCTAssertEqual(staleMetadata.activeSelectionRevision, 0)
        let staleReceipt = try await graph.writer.enqueueWorkspace(stale, url: url, metadata: staleMetadata)
        let staleCompletion = await graph.writer.flush(staleReceipt)
        XCTAssertTrue(staleCompletion.succeeded)

        let persisted = try EmbeddedWorkspaceCodecV1().decode(Data(contentsOf: url)).document
        XCTAssertEqual(persisted.name, "Newer unrelated edit")
        XCTAssertEqual(
            persisted.composeTabs[0].selection.selectedPaths,
            ["/tmp/root/Authoritative.swift"]
        )
    }

    func testHydrationMutationDoesNotAllocateSelectionRevision() throws {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let workspace = makeSlice1Workspace()
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        controller.replaceAll([workspace], activeWorkspaceID: workspace.id)

        controller.mutateComposeTab(
            workspaceID: workspace.id,
            tabID: tabID,
            options: .hydration
        ) { $0.selection = StoredSelection(selectedPaths: ["/tmp/root/stale.swift"]) }

        XCTAssertEqual(controller.selectionRevision(workspaceID: workspace.id, tabID: tabID), 0)
    }

    func testObserverCanCancelDuringPublication() {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let workspace = makeSlice1Workspace()
        var calls = 0
        var token: WorkspaceSessionObservationToken?
        token = controller.observe { _ in
            calls += 1
            if calls > 1 { token?.cancel() }
        }

        controller.replaceAll([workspace], activeWorkspaceID: workspace.id)
        controller.mutateWorkspace(id: workspace.id) { $0.name = "After cancellation" }

        XCTAssertEqual(calls, 2)
    }

    func testBindingCandidatesUseActiveWorkspaceAndAccessPolicy() throws {
        let graph = makeGraph()
        let controller = makeController(graph: graph)
        let workspace = makeSlice1Workspace(name: "Bound", repoPaths: ["/tmp/root"])
        let tabID = try XCTUnwrap(workspace.activeComposeTabID)
        controller.replaceAll([workspace], activeWorkspaceID: workspace.id)

        let byContext = try XCTUnwrap(controller.bindingCandidate(forContextID: tabID))
        let byWorkingDirectory = controller.bindingCandidates(matchingWorkingDirs: ["/tmp/root/Sources"])

        XCTAssertEqual(byContext.workspaceID, workspace.id)
        XCTAssertEqual(byContext.repoPaths, ["/tmp/root"])
        XCTAssertEqual(byWorkingDirectory.map(\.tabID), [tabID])
    }

    private func makeGraph() -> Slice1TestWorkspaceGraph {
        Slice1TestWorkspaceGraph(root: FileManager.default.temporaryDirectory)
    }

    private func makeController(graph: Slice1TestWorkspaceGraph) -> WorkspaceSessionController {
        WorkspaceSessionController(
            repository: graph.repository,
            persistenceWriter: graph.writer,
            accessPolicy: UnrestrictedWorkspaceAccessPolicy()
        )
    }
}
