import Foundation
import RepoPromptCore

/// App-shell composition container for the staged reusable core host.
///
/// This remains inside the monolithic app target until Item 5 creates physical
/// SwiftPM boundaries. App-only listener and adapter ownership intentionally stay
/// here rather than leaking into the reusable host API.
@MainActor
final class RepoPromptAppCoreContainer {
    static let shared = RepoPromptAppCoreContainer(
        networkManager: .shared,
        appSessionAdapters: .shared
    )

    let workspacePersistenceWriter: WorkspacePersistenceWriter
    let workspaceRepository: WorkspaceRepository
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let appSessionAdapters: RepoPromptAppSessionAdapterRegistry
    let runtimeFactory: RepoPromptEmbeddedWorkspaceRuntimeFactory
    let mcpService: MCPService
    let coreHost: RepoPromptCoreHost

    private init(
        networkManager: ServerNetworkManager,
        appSessionAdapters: RepoPromptAppSessionAdapterRegistry
    ) {
        let workspaceGraph = EmbeddedWorkspaceRepositoryFactory.make()
        let workspaceRepository = workspaceGraph.repository
        let workspaceAccessPolicy = UnrestrictedWorkspaceAccessPolicy()
        workspacePersistenceWriter = workspaceGraph.writer
        self.workspaceRepository = workspaceRepository
        self.workspaceAccessPolicy = workspaceAccessPolicy
        self.appSessionAdapters = appSessionAdapters
        runtimeFactory = RepoPromptEmbeddedWorkspaceRuntimeFactory()
        mcpService = MCPService(networkManager: networkManager)
        coreHost = RepoPromptCoreHost(
            workspaceRepository: workspaceRepository,
            workspacePersistenceWriter: workspaceGraph.writer,
            workspaceAccessPolicy: workspaceAccessPolicy,
            runtimeSessionRegistry: networkManager.runtimeSessionRegistry,
            runtimeFactory: runtimeFactory
        )
    }

    func shutdownForAppTermination() {
        coreHost.shutdownForAppTermination()
        appSessionAdapters.removeAll()
    }
}
