import Foundation
@testable import RepoPromptCore

actor WorkspaceSessionLifecycleHarness {
    enum HydrationAction {
        case success(catalogGeneration: UInt64? = nil)
        case staleGeneration(delta: UInt64)
        case failure(String)
        case gated(WorkspaceSessionHydrationGate)
    }

    private var actions: [HydrationAction]
    private(set) var hydrateCalls: [(workspaceID: UUID?, generation: UInt64)] = []
    private(set) var unloadGenerations: [UInt64] = []
    private(set) var closeCount = 0
    private(set) var queryCount = 0

    init(actions: [HydrationAction] = [.success()]) {
        self.actions = actions
    }

    nonisolated func owner() -> WorkspaceSessionLifecycleOwner {
        WorkspaceSessionLifecycleOwner(
            query: queryCapability(),
            hydrate: { [self] workspace, generation in
                return try await hydrate(workspace: workspace, generation: generation)
            },
            unload: { [self] generation in
                await recordUnload(generation)
            },
            close: { [self] in
                await recordClose()
            }
        )
    }

    nonisolated func queryCapability() -> WorkspaceSessionQueryCapability {
        WorkspaceSessionQueryCapability(
            roots: { [self] in
                await recordQuery()
                return []
            },
            rootScopeAvailability: { [self] _ in
                await recordQuery()
                return .available
            },
            catalogGeneration: { [self] _ in
                await recordQuery()
                return 0
            },
            catalogDiagnostics: { [self] scope in
                await recordQuery()
                return WorkspaceCatalogDiagnostics(
                    generation: 0,
                    rootScope: scope,
                    rootCount: 0,
                    folderCount: 0,
                    fileCount: 0
                )
            },
            searchCatalogAccess: { [self] _, _ in
                await recordQuery()
                return .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
            },
            lookupPath: { [self] _ in
                await recordQuery()
                return nil
            }
        )
    }

    private func hydrate(
        workspace: WorkspaceModel?,
        generation: UInt64
    ) async throws -> WorkspaceSessionLifecycleReadiness {
        hydrateCalls.append((workspace?.id, generation))
        let action = actions.isEmpty ? .success() : actions.removeFirst()
        switch action {
        case let .success(catalogGeneration):
            return WorkspaceSessionLifecycleReadiness(
                workspaceID: workspace?.id,
                generation: generation,
                catalogGeneration: catalogGeneration
            )
        case let .staleGeneration(delta):
            return WorkspaceSessionLifecycleReadiness(
                workspaceID: workspace?.id,
                generation: generation &+ delta
            )
        case let .failure(message):
            throw WorkspaceSessionFailure(message)
        case let .gated(gate):
            await gate.waitUntilReleased()
            return WorkspaceSessionLifecycleReadiness(
                workspaceID: workspace?.id,
                generation: generation
            )
        }
    }

    private func recordUnload(_ generation: UInt64) {
        unloadGenerations.append(generation)
    }

    private func recordClose() {
        closeCount += 1
    }

    private func recordQuery() {
        queryCount += 1
    }
}

actor WorkspaceSessionHydrationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

func makeSessionDependencies(
    workspaces: [WorkspaceModel],
    activeWorkspaceID: UUID?,
    lifecycle: WorkspaceSessionLifecycleHarness,
    workspaceURL: @escaping @Sendable (WorkspaceModel) -> URL? = { _ in nil },
    indexURL: @escaping @Sendable () -> URL? = { nil }
) -> RepoPromptCoreSessionDependencies {
    RepoPromptCoreSessionDependencies(
        load: {
            WorkspaceSessionHydrationInput(
                workspaces: workspaces,
                activeWorkspaceID: activeWorkspaceID
            )
        },
        lifecycleOwner: lifecycle.owner(),
        workspaceURL: workspaceURL,
        indexURL: indexURL
    )
}
