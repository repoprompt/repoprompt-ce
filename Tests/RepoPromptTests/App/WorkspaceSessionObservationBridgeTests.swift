import Combine
import Foundation
@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

@MainActor
final class WorkspaceSessionObservationBridgeTests: XCTestCase {
    func testBridgePublishesOrderedReadOnlyControllerSnapshots() {
        let graph = makeGraph()
        let controller = WorkspaceSessionController(
            repository: graph.repository,
            persistenceWriter: graph.writer,
            accessPolicy: UnrestrictedWorkspaceAccessPolicy()
        )
        let bridge = WorkspaceSessionObservationBridge(controller: controller)
        var generations: [UInt64] = []
        let cancellable = bridge.$snapshot.dropFirst().sink { generations.append($0.generation) }
        let first = WorkspaceModel(name: "First", repoPaths: ["/tmp/first"])
        let second = WorkspaceModel(name: "Second", repoPaths: ["/tmp/second"])

        controller.replaceAll([first, second], activeWorkspaceID: second.id)
        controller.mutateWorkspace(id: second.id) { $0.name = "Renamed" }
        controller.setActiveWorkspaceID(first.id)

        XCTAssertEqual(generations, [1, 2, 3])
        XCTAssertEqual(bridge.workspaces.map(\.name), ["First", "Renamed"])
        XCTAssertEqual(bridge.activeWorkspaceID, first.id)
        withExtendedLifetime(cancellable) {}
    }

    private func makeGraph() -> (writer: WorkspacePersistenceWriter, repository: WorkspaceRepository) {
        let codec = EmbeddedWorkspaceCodecV1()
        let writer = WorkspacePersistenceWriter(codec: codec)
        let repository = WorkspaceRepository(
            rootProvider: ObservationBridgeRootProvider(root: FileManager.default.temporaryDirectory),
            codec: codec,
            writer: writer,
            migrationService: NoopWorkspaceLegacyMigrationService()
        )
        return (writer, repository)
    }
}

private struct ObservationBridgeRootProvider: WorkspaceRepositoryRootProviding {
    let root: URL

    func repositoryRoot() async -> URL {
        root
    }
}
