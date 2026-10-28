import Foundation
import RepoPromptWorkspaceCore

struct WorkspaceCodemapStructureRequest: Equatable {
    let direction: WorkspaceCodemapStructureTraversalDirection?
    let maximumDepth: Int
    let includesSignatures: Bool
    let size: WorkspaceCodemapGraphOutputSize
    let budget: WorkspaceCodemapGraphQueryBudget
}

enum WorkspaceCodemapStructureExecutionResult {
    case scopeUnavailable
    case noRequestedFiles
    case completed(
        aggregate: WorkspaceCodemapStructureAggregateResult,
        presentation: WorkspaceCodemapOperationPresentation?,
        revalidation: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]
    )
}

/// Orchestrates the existing scoped graph and presentation owners without retaining authority.
struct WorkspaceCodemapStructureQueryExecutor {
    let store: WorkspaceFileContextStore

    @MainActor
    func execute(
        files: [WorkspaceFileRecord],
        request: WorkspaceCodemapStructureRequest,
        includePathNotFoundIssue: Bool,
        rootScope: WorkspaceLookupRootScope,
        boundLogicalNames: [UUID: String],
        presentationWillStart: () -> Void,
        phaseDidChange: @escaping @Sendable (WorkspaceCodemapStructureExecutionPhase) async -> Void
    ) async throws -> WorkspaceCodemapStructureExecutionResult {
        switch await store.rootScopeAvailability(rootScope) {
        case .available: break
        case .sessionWorktreeUnavailable: return .scopeUnavailable
        }
        let roots = await store.rootRefs(scope: rootScope)
        let uniqueFiles = Self.uniqueScopedFiles(files, roots: roots)
        if uniqueFiles.isEmpty, includePathNotFoundIssue { return .noRequestedFiles }

        let logicalRootNames = await WorkspaceLogicalRootIdentity.displayNames(
            store: store, rootScope: rootScope, boundLogicalNames: boundLogicalNames
        )
        let orderedFiles = Self.orderFiles(uniqueFiles, roots: roots, logicalRootNames: logicalRootNames)
        await phaseDidChange(.graphSnapshot)
        let aggregate = try await store.queryCodemapStructureGraphs(
            seedFileIDs: orderedFiles.map(\.id),
            direction: request.direction,
            maximumDepth: request.maximumDepth,
            budget: request.budget,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootNames
        )
        try Task.checkCancellation()
        await phaseDidChange(.graphTraversal)
        await phaseDidChange(.graphRevalidation)
        let initialRevalidation = await store.revalidateCodemapStructureGraphs(aggregate)
        let renderableFileIDs = aggregate.roots.flatMap { root -> [UUID] in
            if case .invalid? = initialRevalidation[root.rootEpoch] { return [] }
            return root.nodes.map(\.fileID)
        }
        let presentation: WorkspaceCodemapOperationPresentation?
        if request.includesSignatures, !renderableFileIDs.isEmpty {
            presentationWillStart()
            presentation = try await WorkspaceCodemapPresentationCoordinator(
                store: store,
                policy: WorkspaceCodemapPresentationRequestPolicy(
                    maximumReadinessRounds: 4096,
                    initialBackoffMilliseconds: 25,
                    maximumBackoffMilliseconds: 250,
                    maximumTotalWait: .milliseconds(workspaceCodemapProductionDemandWaitMilliseconds),
                    maximumCandidateDemandCount: request.budget.maximumNodeCount
                ),
                structurePhaseDidChange: phaseDidChange
            ).structureSignaturePresentation(
                fileIDs: renderableFileIDs,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootNames
            )
        } else {
            presentation = nil
        }
        try Task.checkCancellation()
        let finalRevalidation = await store.revalidateCodemapStructureGraphs(aggregate)
        let revalidation = Self.mergeRevalidation(initial: initialRevalidation, final: finalRevalidation)
        try Task.checkCancellation()
        await phaseDidChange(.assembly)
        return .completed(aggregate: aggregate, presentation: presentation, revalidation: revalidation)
    }

    static func uniqueScopedFiles(_ files: [WorkspaceFileRecord], roots: [WorkspaceRootRef]) -> [WorkspaceFileRecord] {
        let allowedRootIDs = Set(roots.map(\.id))
        var unique: [String: WorkspaceFileRecord] = [:]
        for file in files where allowedRootIDs.contains(file.rootID) {
            if unique[file.standardizedFullPath] == nil { unique[file.standardizedFullPath] = file }
        }
        return Array(unique.values)
    }

    static func orderFiles(
        _ files: [WorkspaceFileRecord], roots: [WorkspaceRootRef], logicalRootNames: [UUID: String]
    ) -> [WorkspaceFileRecord] {
        files.sorted { lhs, rhs in
            let left = WorkspaceLogicalRootIdentity.relativePath(
                for: lhs, roots: roots, rootDisplayNamesByRootID: logicalRootNames
            ) ?? lhs.standardizedRelativePath
            let right = WorkspaceLogicalRootIdentity.relativePath(
                for: rhs, roots: roots, rootDisplayNamesByRootID: logicalRootNames
            ) ?? rhs.standardizedRelativePath
            if left != right { return left.utf8.lexicographicallyPrecedes(right.utf8) }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func mergeRevalidation(
        initial: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult],
        final: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]
    ) -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] {
        var merged = initial
        for (rootEpoch, result) in final {
            if case .invalid? = merged[rootEpoch] { continue }
            merged[rootEpoch] = result
        }
        return merged
    }
}
