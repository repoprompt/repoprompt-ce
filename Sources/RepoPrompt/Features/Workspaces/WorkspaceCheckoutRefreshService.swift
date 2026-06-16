import Foundation

enum WorkspaceCheckoutSearchIndexRefreshBehavior: Equatable {
    case noLoadedRoot
    case rebuiltSharedVisibleWorkspace
    case skippedSharedVisibleWorkspaceForSessionWorktree
}

struct WorkspaceCheckoutRefreshResult: Equatable {
    let requestedRootPath: String
    let refreshedRootIDs: [UUID]
    let refreshedRootPaths: [String]
    let removedStaleCodemapFileIDs: [UUID]
    /// Generation from rebuilding the shared visible search index. Nil is expected for
    /// session-worktree-only refreshes; scoped session search reads the fresh store catalog directly.
    let searchIndexedGeneration: UInt64?
    let searchIndexRefreshBehavior: WorkspaceCheckoutSearchIndexRefreshBehavior
    let pathLookupGeneration: UInt64?

    var didRefreshLoadedRoot: Bool {
        !refreshedRootIDs.isEmpty
    }
}

/// Coordinates workspace catalog/search/path/codemap freshness after an in-app checkout mutation.
///
/// This intentionally lives in the workspace layer. Git status code mutates Git and refreshes branch
/// summaries; Agent Mode only asks for this seam after a successful in-app checkout switch.
struct WorkspaceCheckoutRefreshService {
    let store: WorkspaceFileContextStore
    let searchService: WorkspaceSearchService

    func refreshAfterCheckoutMutation(rootPath rawRootPath: String) async -> WorkspaceCheckoutRefreshResult {
        let standardizedRootPath = StandardizedPath.absolute(rawRootPath)
        let loadedRoots = await store.rootRecords(forRootFolderPaths: [standardizedRootPath], includeSystemRoots: true)
        guard !loadedRoots.isEmpty else {
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: standardizedRootPath,
                fallbackScope: .visibleWorkspace
            )
            return WorkspaceCheckoutRefreshResult(
                requestedRootPath: standardizedRootPath,
                refreshedRootIDs: [],
                refreshedRootPaths: [],
                removedStaleCodemapFileIDs: [],
                searchIndexedGeneration: nil,
                searchIndexRefreshBehavior: .noLoadedRoot,
                pathLookupGeneration: nil
            )
        }

        let rootScope = await narrowRootScope(for: loadedRoots)
        let loadedRootIDs = loadedRoots.map(\.id)
        _ = await store.awaitAppliedIngress(rootScope: rootScope)
        for rootID in loadedRootIDs {
            await store.reconcileLoadedRootCatalogWithDisk(rootID: rootID)
        }
        await store.cancelCodemapScansForCheckoutMutation(rootIDs: loadedRootIDs)
        let removedStaleCodemapFileIDs = await store.invalidateCodemapSnapshotsForCheckoutMutation(rootIDs: loadedRootIDs)

        async let warmedGeneration = store.warmPathLookupIndexes(rootScope: rootScope)
        async let indexedResult = rebuildSharedVisibleSearchIndexIfNeeded(affectedRoots: loadedRoots)
        requestCodemapRescansInBackground(rootIDs: loadedRootIDs)

        let searchIndexResult = await indexedResult
        let pathLookupGeneration = await warmedGeneration
        return WorkspaceCheckoutRefreshResult(
            requestedRootPath: standardizedRootPath,
            refreshedRootIDs: loadedRoots.map(\.id),
            refreshedRootPaths: loadedRoots.map(\.standardizedFullPath),
            removedStaleCodemapFileIDs: removedStaleCodemapFileIDs,
            searchIndexedGeneration: searchIndexResult.generation,
            searchIndexRefreshBehavior: searchIndexResult.behavior,
            pathLookupGeneration: pathLookupGeneration
        )
    }

    private func rebuildSharedVisibleSearchIndexIfNeeded(
        affectedRoots: [WorkspaceRootRecord]
    ) async -> (generation: UInt64?, behavior: WorkspaceCheckoutSearchIndexRefreshBehavior) {
        guard affectedRoots.contains(where: { $0.kind == .primaryWorkspace }) else {
            return (nil, .skippedSharedVisibleWorkspaceForSessionWorktree)
        }
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        let generation = await searchService.rebuildIndex(from: snapshot)
        return (generation, .rebuiltSharedVisibleWorkspace)
    }

    private func requestCodemapRescansInBackground(rootIDs: [UUID]) {
        let store = store
        Task.detached(priority: .utility) {
            for rootID in rootIDs {
                try? await store.requestCodemapScans(inRoot: rootID)
            }
        }
    }

    private func narrowRootScope(for targetRoots: [WorkspaceRootRecord]) async -> WorkspaceLookupRootScope {
        let allRoots = await store.roots()
        let targetRootIDs = Set(targetRoots.map(\.id))
        let targetPrimaryRootPaths = Set(
            allRoots.compactMap { root -> String? in
                guard root.kind == .primaryWorkspace, targetRootIDs.contains(root.id) else { return nil }
                return root.standardizedFullPath
            }
        )
        let targetSessionWorktreePaths = Set(
            targetRoots.compactMap { root -> String? in
                guard root.kind == .sessionWorktree else { return nil }
                return root.standardizedFullPath
            }
        )
        return .sessionBoundWorkspace(
            canonicalRootPaths: targetPrimaryRootPaths,
            physicalRootPaths: targetSessionWorktreePaths
        )
    }
}
