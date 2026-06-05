import Foundation

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

    let workspaceRepository: WorkspaceRepository
    let workspaceAccessPolicy: any WorkspaceAccessPolicy
    let appSessionAdapters: RepoPromptAppSessionAdapterRegistry
    let platformDependencies: RepoPromptCorePlatformDependencies
    let mcpService: MCPService
    let coreHost: RepoPromptCoreHost

    private init(
        networkManager: ServerNetworkManager,
        appSessionAdapters: RepoPromptAppSessionAdapterRegistry
    ) {
        let workspaceRepository = WorkspaceRepository()
        let workspaceAccessPolicy = UnrestrictedWorkspaceAccessPolicy()
        self.workspaceRepository = workspaceRepository
        self.workspaceAccessPolicy = workspaceAccessPolicy
        self.appSessionAdapters = appSessionAdapters
        let platformDependencies = MacOSRepoPromptCorePlatformDependencies.embeddedApp()
        self.platformDependencies = platformDependencies
        mcpService = MCPService(networkManager: networkManager)
        coreHost = RepoPromptCoreHost(
            workspaceRepository: workspaceRepository,
            workspaceAccessPolicy: workspaceAccessPolicy,
            runtimeSessionRegistry: networkManager.runtimeSessionRegistry,
            platformDependencies: platformDependencies
        )
    }

    func shutdownForAppTermination() {
        coreHost.shutdownForAppTermination()
        appSessionAdapters.removeAll()
    }
}
