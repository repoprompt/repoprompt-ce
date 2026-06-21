import Foundation
import RepoPromptCore

struct WorkspaceSessionRootLoadConfiguration {
    let respectGitignore: Bool
    let respectRepoIgnore: Bool
    let respectCursorignore: Bool
    let skipSymlinks: Bool
    let enableHierarchicalIgnores: Bool

    static let standard = WorkspaceSessionRootLoadConfiguration(
        respectGitignore: true,
        respectRepoIgnore: true,
        respectCursorignore: true,
        skipSymlinks: true,
        enableHierarchicalIgnores: true
    )
}

/// Selected-session ownership adapter for the Phase 4 workspace engine.
///
/// The mutable store is captured only by this lifecycle owner and immutable query closures.
/// Session callers receive `WorkspaceSessionQueryCapability`, never the store itself.
private actor WorkspaceSessionStoreLifecycleStorage {
    private let store: WorkspaceFileContextStore
    private let configuration: @Sendable () async -> WorkspaceSessionRootLoadConfiguration
    private var rootIDsByGeneration: [UInt64: [UUID]] = [:]
    private var isClosed = false

    init(
        store: WorkspaceFileContextStore,
        configuration: @escaping @Sendable () async -> WorkspaceSessionRootLoadConfiguration
    ) {
        self.store = store
        self.configuration = configuration
    }

    func hydrate(
        workspace: WorkspaceModel?,
        generation: UInt64
    ) async throws -> WorkspaceSessionLifecycleReadiness {
        guard !isClosed else { throw WorkspaceSessionFailure("workspace store lifecycle is closed") }
        let paths = workspace.map(WorkspaceManagerViewModel.loadableRepoPaths(for:)) ?? []
        let configuration = await configuration()
        var loaded: [WorkspaceRootRecord] = []
        do {
            for path in paths {
                try Task.checkCancellation()
                let root = try await store.loadRoot(
                    path: path,
                    kind: .primaryWorkspace,
                    respectGitignore: configuration.respectGitignore,
                    respectRepoIgnore: configuration.respectRepoIgnore,
                    respectCursorignore: configuration.respectCursorignore,
                    skipSymlinks: configuration.skipSymlinks,
                    enableHierarchicalIgnores: configuration.enableHierarchicalIgnores,
                    cancelUnderlyingLoadOnCallerCancellation: true
                )
                loaded.append(root)
                try await store.startWatchingRoot(id: root.id)
            }
            try Task.checkCancellation()
            _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            let catalogGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
            rootIDsByGeneration[generation] = loaded.map(\.id)
            return WorkspaceSessionLifecycleReadiness(
                workspaceID: workspace?.id,
                generation: generation,
                catalogGeneration: catalogGeneration
            )
        } catch {
            await store.unloadRoots(ids: loaded.map(\.id))
            throw error
        }
    }

    func unload(generation: UInt64) async {
        let rootIDs = rootIDsByGeneration.removeValue(forKey: generation) ?? []
        await store.unloadRoots(ids: rootIDs)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let rootIDs = rootIDsByGeneration.values.flatMap(\.self)
        rootIDsByGeneration.removeAll()
        await store.unloadRoots(ids: Array(Set(rootIDs)))
    }
}

enum WorkspaceSessionStoreLifecycleFactory {
    static func make(
        store: WorkspaceFileContextStore,
        configuration: @escaping @Sendable () async -> WorkspaceSessionRootLoadConfiguration = {
            .standard
        }
    ) -> WorkspaceSessionLifecycleOwner {
        let storage = WorkspaceSessionStoreLifecycleStorage(
            store: store,
            configuration: configuration
        )
        let query = WorkspaceSessionQueryCapability(
            roots: { await store.roots() },
            rootScopeAvailability: { scope in await store.rootScopeAvailability(scope) },
            catalogGeneration: { scope in await store.catalogGeneration(rootScope: scope) },
            catalogDiagnostics: { scope in await store.catalogDiagnostics(rootScope: scope) },
            searchCatalogAccess: { scope, requirement in
                await store.searchCatalogAccess(rootScope: scope, requirement: requirement)
            },
            lookupPath: { request in await store.lookupPath(request) }
        )
        return WorkspaceSessionLifecycleOwner(
            query: query,
            hydrate: { workspace, generation in
                try await storage.hydrate(workspace: workspace, generation: generation)
            },
            unload: { generation in await storage.unload(generation: generation) },
            close: { await storage.close() }
        )
    }
}
