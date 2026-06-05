import Foundation
import RepoPromptCore

@MainActor
final class EmbeddedWorkspaceRepositoryRootProvider: WorkspaceRepositoryRootProviding {
    func repositoryRoot() async -> URL {
        if let path = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return WorkspaceStoragePaths.defaultRoot
    }
}

@MainActor
enum EmbeddedWorkspaceRepositoryFactory {
    struct Graph {
        let writer: WorkspacePersistenceWriter
        let repository: WorkspaceRepository
    }

    static func make() -> Graph {
        let codec = EmbeddedWorkspaceCodecV1()
        let diagnostics = EmbeddedWorkspaceRepositoryDiagnosticsAdapter()
        let writer = WorkspacePersistenceWriter(codec: codec, diagnostics: diagnostics)
        let repository = WorkspaceRepository(
            rootProvider: EmbeddedWorkspaceRepositoryRootProvider(),
            codec: codec,
            writer: writer,
            diagnostics: diagnostics,
            migrationService: NoopWorkspaceLegacyMigrationService()
        )
        return Graph(writer: writer, repository: repository)
    }
}
