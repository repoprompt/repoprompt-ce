import Foundation
import RepoPromptFoundation
import RepoPromptInstrumentation
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Bounded seed lookup and graph reply construction for both catalog routes.
@MainActor
enum MCPCodeStructureRead {
    static let maximumSeedCount = 8192

    static func resolveSelectedFiles(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext,
        maximumSeedCount: Int,
        recordVisited: (Int) -> Void = { _ in }
    ) async throws -> [WorkspaceFileRecord] {
        precondition(maximumSeedCount > 0)
        try Task.checkCancellation()
        let selectedPaths = StoredSelectionPathNormalization.standardizedPaths(
            selection.selectedPaths.map { lookupContext.translateInputPath($0) }
        )
        let slicePaths = StoredSelectionPathNormalization.standardizedPaths(
            selection.slices.keys.map { lookupContext.translateInputPath($0) }
        ).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let resolution = await store.resolveSelectedCodeStructureFiles(
            atPaths: selectedPaths + slicePaths,
            rootScope: lookupContext.rootScope,
            maximumUniqueFileCount: maximumSeedCount
        )
        try Task.checkCancellation()
        recordVisited(resolution.visitedUniqueFileCount)
        return resolution.files
    }

    static func resolveFiles(
        paths: [String],
        store: WorkspaceFileContextStore,
        lookupRootScope: WorkspaceLookupRootScope,
        maximumSeedCount: Int,
        recordVisited: (Int) -> Void = { _ in }
    ) async throws -> [WorkspaceFileRecord] {
        precondition(maximumSeedCount > 0)
        try Task.checkCancellation()
        let directFiles = await store.lookupFiles(
            atPaths: paths,
            profile: .mcpRead,
            rootScope: lookupRootScope
        )
        try Task.checkCancellation()
        let matchedFileInputs = Set(directFiles.keys)
        var resolved: [WorkspaceFileRecord] = []
        var seenStandardizedFullPaths = Set<String>()

        for path in paths {
            try Task.checkCancellation()
            guard let file = directFiles[path],
                  seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
            else { continue }
            resolved.append(file)
            recordVisited(1)
            if resolved.count > maximumSeedCount { return resolved }
        }

        let dirCandidates = paths.filter { !matchedFileInputs.contains($0) }
        for raw in dirCandidates {
            try Task.checkCancellation()
            let folderResolution = await store.expandFolderInputToFiles(
                raw,
                rootScope: lookupRootScope,
                profile: .mcpSelection,
                excludingStandardizedFullPaths: seenStandardizedFullPaths,
                maximumUniqueFileCount: maximumSeedCount - resolved.count
            )
            try Task.checkCancellation()
            guard folderResolution.handled else { continue }
            recordVisited(folderResolution.visitedUniqueFileCount)
            for file in folderResolution.files
                where seenStandardizedFullPaths.insert(file.standardizedFullPath).inserted
            {
                resolved.append(file)
            }
            if folderResolution.didExceedLimit { return resolved }
        }

        return resolved
    }

    static func buildReply(
        fromRecords files: [WorkspaceFileRecord],
        request: WorkspaceCodemapStructureRequest,
        includePathNotFoundIssue: Bool,
        requestedPaths: [String],
        lookupContext: WorkspaceLookupContext,
        store: WorkspaceFileContextStore,
        codeMapsDisabled: Bool,
        presentationWillStart: () -> Void = {}
    ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
        try Task.checkCancellation()
        let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(
            from: lookupContext.bindingProjection
        )
        if codeMapsDisabled {
            return Self.codeStructureUnavailableReply(
                issue: .init(
                    code: "codemaps_disabled",
                    phase: "graph_snapshot",
                    path: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: nil,
                    limit: nil,
                    message: "Codemap generation is disabled."
                ),
                size: request.size,
                worktreeScope: worktreeScope
            )
        }

        let boundLogicalNames = Dictionary(
            (lookupContext.bindingProjection?.boundRootsForMetadata ?? []).map {
                ($0.physicalRoot.id, $0.logicalRoot.name)
            },
            uniquingKeysWith: { current, _ in current }
        )
        let result = try await WorkspaceCodemapStructureQueryExecutor(store: store)
            .execute(
                files: files,
                request: request,
                includePathNotFoundIssue: includePathNotFoundIssue,
                rootScope: lookupContext.rootScope,
                boundLogicalNames: boundLogicalNames,
                presentationWillStart: presentationWillStart,
                phaseDidChange: { phase in
                    await MCPToolExecutionHandlerPhaseContext.report(phase.mcpToolExecutionHandlerPhase)
                }
            )
        switch result {
        case .scopeUnavailable:
            return Self.codeStructureUnavailableReply(
                issue: .init(
                    code: "git_root_unavailable", phase: "seed_resolution", path: nil,
                    retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil,
                    message: "The session-bound worktree root is unavailable."
                ),
                size: request.size, worktreeScope: worktreeScope
            )
        case .noRequestedFiles:
            return Self.codeStructureUnavailableReply(
                issue: .init(
                    code: "path_not_found", phase: "seed_resolution", path: requestedPaths.first,
                    retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil,
                    message: "No requested path resolved to a file."
                ),
                size: request.size, worktreeScope: worktreeScope
            )
        case let .completed(aggregate, presentation, revalidation):
            return Self.codeStructureReplyDTO(
                aggregate: aggregate, presentation: presentation, revalidation: revalidation,
                includesSignatures: request.includesSignatures, budget: request.budget,
                size: request.size, worktreeScope: worktreeScope
            )
        }
    }

    static func codeStructureReplyDTO(
        aggregate: WorkspaceCodemapStructureAggregateResult,
        presentation: WorkspaceCodemapOperationPresentation?,
        revalidation: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult],
        includesSignatures: Bool,
        budget: WorkspaceCodemapGraphQueryBudget,
        size: WorkspaceCodemapGraphOutputSize,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO?
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        typealias DTO = ToolResultDTOs.CodeStructureReplyDTO
        let orderedRoots = aggregate.roots.sorted(by: {
            if $0.rootDisplayName != $1.rootDisplayName {
                return $0.rootDisplayName.utf8.lexicographicallyPrecedes($1.rootDisplayName.utf8)
            }
            return $0.rootEpoch.rootID.uuidString < $1.rootEpoch.rootID.uuidString
        })
        let pathByFileID = Dictionary(uniqueKeysWithValues: orderedRoots.flatMap { root in
            root.nodes.map { ($0.fileID, $0.path) }
        })
        var globalIssues = aggregate.issues.map(codeStructureIssueDTO)
        let signatureIssueCoverage: CodeStructureSignatureIssueCoverage
        if let presentation {
            globalIssues.append(contentsOf: presentation.issues.map {
                codeStructureSignatureIssueDTO($0, pathByFileID: pathByFileID)
            })
            signatureIssueCoverage = codeStructureSignatureIssueCoverage(presentation.issues)
        } else {
            signatureIssueCoverage = CodeStructureSignatureIssueCoverage()
        }

        var renderedFiles: [DTO.FileDTO] = []
        var renderedFileIDs = Set<UUID>()
        var sizeOmittedFileIDs = Set<UUID>()
        var renderedTokenCount = 0
        let separatorTokens = TokenCalculationService.estimateTokens(for: "\n\n")
        var signatureBudgetReached = false
        if includesSignatures, let presentation {
            let orderedSignatureNodes: [WorkspaceCodemapStructureNodeResult] = orderedRoots.flatMap { root -> [WorkspaceCodemapStructureNodeResult] in
                if case .invalid? = revalidation[root.rootEpoch] { return [] }
                return root.nodes
            }.sorted { lhs, rhs in
                if lhs.isSeed != rhs.isSeed { return lhs.isSeed }
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                if lhs.path != rhs.path { return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) }
                return lhs.fileID.uuidString < rhs.fileID.uuidString
            }
            for node in orderedSignatureNodes {
                guard let rendered = presentation.renderedEntriesByFileID[node.fileID] else { continue }
                let separator = renderedFiles.isEmpty ? 0 : separatorTokens
                let attempted = renderedTokenCount + separator + rendered.tokenCount
                guard attempted <= budget.renderTokenCount else {
                    signatureBudgetReached = true
                    sizeOmittedFileIDs.insert(node.fileID)
                    continue
                }
                renderedTokenCount = attempted
                renderedFileIDs.insert(node.fileID)
                renderedFiles.append(DTO.FileDTO(
                    path: node.path,
                    role: node.isSeed ? "seed" : "related",
                    depth: node.depth,
                    reachedBy: node.reachedBy.map(codeStructureDirectionName).sorted(),
                    content: rendered.text,
                    tokens: rendered.tokenCount
                ))
            }
        }
        if signatureBudgetReached {
            globalIssues.append(DTO.IssueDTO(
                code: "signature_size_limit",
                phase: "render",
                path: nil,
                retryable: false,
                retryAfterMilliseconds: nil,
                attempted: nil,
                limit: nil,
                message: "Some signatures were omitted to fit the requested output size."
            ))
        }

        var rootDTOs: [DTO.RootDTO] = []
        for root in orderedRoots {
            let graphRevalidation = revalidation[root.rootEpoch]
            let graphInvalid = if case .invalid? = graphRevalidation { true } else { false }
            let revalidationUpdatesPending: Bool = if case let .valid(updatesPending)? = graphRevalidation {
                updatesPending
            } else {
                false
            }
            let coverage = root.coverage
            var rootIssues = root.issues.map { issue in
                let mapped = codeStructureIssueDTO(issue)
                guard root.executionStop == nil, root.status != .unavailable, !graphInvalid,
                      issue.code == "seed_not_indexed", coverage?.isComplete != true
                else { return mapped }
                return DTO.IssueDTO(
                    code: mapped.code,
                    phase: mapped.phase,
                    path: mapped.path,
                    retryable: true,
                    retryAfterMilliseconds: 100,
                    attempted: mapped.attempted,
                    limit: mapped.limit,
                    message: mapped.message
                )
            }
            if case let .invalid(code, message)? = graphRevalidation {
                rootIssues.append(DTO.IssueDTO(
                    code: code,
                    phase: "graph_revalidation",
                    path: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: nil,
                    limit: nil,
                    message: message
                ))
            }
            let signatureIssueCoversRoot = signatureIssueCoverage.coversAll ||
                signatureIssueCoverage.rootEpochs.contains(root.rootEpoch)
            let missingSignature = includesSignatures && !graphInvalid && !signatureIssueCoversRoot && root.nodes.contains {
                !renderedFileIDs.contains($0.fileID) &&
                    !sizeOmittedFileIDs.contains($0.fileID) &&
                    !signatureIssueCoverage.fileIDs.contains($0.fileID)
            }
            if missingSignature {
                rootIssues.append(DTO.IssueDTO(
                    code: "signature_unavailable",
                    phase: "render",
                    path: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: nil,
                    limit: nil,
                    message: "One or more signatures could not be rendered; graph data remains usable."
                ))
            }
            let status: DTO.Status = if graphInvalid {
                .unavailable
            } else if root.status != .ok || revalidationUpdatesPending || missingSignature {
                root.hasUsefulData ? .partial : codeStructureStatusDTO(root.status)
            } else {
                .ok
            }
            let indexStopReason: String? = if let stop = root.executionStop {
                stop.reason.rawValue
            } else if case let .invalid(code, _)? = graphRevalidation {
                code
            } else if root.status == .unavailable {
                rootIssues.first?.code ?? "graph_unavailable"
            } else {
                nil
            }
            rootDTOs.append(DTO.RootDTO(
                root: root.rootDisplayName,
                status: status,
                index: DTO.IndexDTO(
                    state: root.executionStop != nil || root.status == .unavailable || graphInvalid
                        ? .stopped : coverage?.isComplete == true ? .complete : .indexing,
                    indexed: coverage?.classifiedCount ?? 0,
                    total: coverage?.supportedCount ?? 0,
                    reason: indexStopReason,
                    attempted: root.executionStop?.budget.map { Int(clamping: $0.attempted) },
                    limit: root.executionStop?.budget.map { Int(clamping: $0.limit) }
                ),
                updatesPending: indexStopReason == nil && (root.updatesPending || revalidationUpdatesPending) ? true : nil,
                seeds: root.seeds.map {
                    DTO.SeedDTO(path: $0.path, state: codeStructureSeedStateDTO($0.state))
                },
                nodes: graphInvalid ? [] : root.nodes.map {
                    DTO.NodeDTO(
                        path: $0.path,
                        depth: $0.depth,
                        seed: $0.isSeed ? true : nil,
                        reachedBy: $0.reachedBy.map(codeStructureDirectionName).sorted()
                    )
                },
                edges: graphInvalid ? [] : root.edges.map {
                    DTO.EdgeDTO(
                        from: $0.fromPath,
                        to: $0.toPath,
                        symbols: $0.symbols,
                        ambiguous: $0.ambiguous ? true : nil
                    )
                },
                unresolved: graphInvalid ? [] : root.unresolved.map {
                    DTO.UnresolvedDTO(
                        from: $0.fromPath,
                        name: $0.name,
                        reason: codeStructureUnresolvedReasonDTO($0.reason)
                    )
                },
                truncated: graphInvalid ? nil : root.truncation.map {
                    DTO.TruncatedDTO(reason: "size", droppedNodes: $0.droppedNodeCount)
                },
                issues: rootIssues
            ))
        }

        let usableNodeCount = rootDTOs.reduce(0) { $0 + $1.nodes.count }
        let usableEdgeCount = rootDTOs.reduce(0) { $0 + $1.edges.count }
        let allIssues = globalIssues + rootDTOs.flatMap(\.issues)
        let hasUsefulData = usableNodeCount > 0 || usableEdgeCount > 0
        let status: DTO.Status = if hasUsefulData {
            globalIssues.isEmpty && rootDTOs.allSatisfy { $0.status == .ok } ? .ok : .partial
        } else if rootDTOs.contains(where: { $0.status == .pending }) {
            .pending
        } else {
            .unavailable
        }
        let retryableIssues = allIssues.filter(\.retryable)
        return DTO(
            status: status,
            size: size,
            roots: rootDTOs,
            files: renderedFiles,
            summary: DTO.SummaryDTO(
                seeds: rootDTOs.reduce(0) { $0 + $1.seeds.count },
                nodes: usableNodeCount,
                edges: usableEdgeCount,
                files: renderedFiles.count,
                tokens: renderedTokenCount
            ),
            issues: globalIssues,
            retry: retryableIssues.isEmpty ? nil : DTO.RetryDTO(
                retryable: true,
                retryAfterMilliseconds: retryableIssues.compactMap(\.retryAfterMilliseconds).max() ?? 100
            ),
            worktreeScope: worktreeScope
        )
    }

    private static func codeStructureUnavailableReply(
        issue: ToolResultDTOs.CodeStructureReplyDTO.IssueDTO,
        size: WorkspaceCodemapGraphOutputSize,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO?
    ) -> ToolResultDTOs.CodeStructureReplyDTO {
        ToolResultDTOs.CodeStructureReplyDTO(
            status: .unavailable,
            size: size,
            roots: [],
            files: [],
            summary: .init(seeds: 0, nodes: 0, edges: 0, files: 0, tokens: 0),
            issues: [issue],
            retry: issue.retryable
                ? .init(retryable: true, retryAfterMilliseconds: issue.retryAfterMilliseconds ?? 100)
                : nil,
            worktreeScope: worktreeScope
        )
    }

    private static func codeStructureIssueDTO(
        _ issue: WorkspaceCodemapStructureIssueRecord
    ) -> ToolResultDTOs.CodeStructureReplyDTO.IssueDTO {
        let isSizeIssue = ["graph_size_limit", "signature_size_limit"].contains(issue.code)
        return .init(
            code: issue.code,
            phase: issue.phase,
            path: issue.path,
            retryable: issue.retryable,
            retryAfterMilliseconds: issue.retryAfterMilliseconds,
            attempted: isSizeIssue ? nil : issue.attempted,
            limit: isSizeIssue ? nil : issue.limit,
            message: issue.message
        )
    }

    private struct CodeStructureSignatureIssueCoverage {
        var fileIDs = Set<UUID>()
        var rootEpochs = Set<WorkspaceCodemapRootEpoch>()
        var coversAll = false
    }

    private static func codeStructureSignatureIssueCoverage(
        _ issues: [WorkspaceCodemapOperationIssue]
    ) -> CodeStructureSignatureIssueCoverage {
        var coverage = CodeStructureSignatureIssueCoverage()
        for issue in issues {
            switch issue {
            case .coordinationUnavailable, .cancelled, .automatic:
                coverage.coversAll = true
            case let .candidate(candidate):
                switch candidate {
                case let .fileNotCataloged(fileID),
                     let .fileOutsideRootScope(fileID),
                     let .logicalPathUnavailable(fileID):
                    coverage.fileIDs.insert(fileID)
                case let .incompleteRootSet(missingFileIDs):
                    coverage.fileIDs.formUnion(missingFileIDs)
                }
            case let .pending(fileID, _), let .unavailable(fileID, _):
                coverage.fileIDs.insert(fileID)
            case let .freezeUnavailable(rootEpoch, _), let .renderUnavailable(rootEpoch, _):
                coverage.rootEpochs.insert(rootEpoch)
            case let .publicationStale(reason):
                switch reason {
                case .rootScope, .automatic:
                    coverage.coversAll = true
                case let .rootEpoch(rootEpoch), let .bundle(rootEpoch, _):
                    coverage.rootEpochs.insert(rootEpoch)
                case let .catalog(fileID):
                    coverage.fileIDs.insert(fileID)
                case let .demand(ticket):
                    coverage.fileIDs.insert(ticket.fileID)
                }
            }
        }
        return coverage
    }

    private static func codeStructureSignatureIssueDTO(
        _ issue: WorkspaceCodemapOperationIssue,
        pathByFileID: [UUID: String]
    ) -> ToolResultDTOs.CodeStructureReplyDTO.IssueDTO {
        typealias DTO = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO
        switch issue {
        case .coordinationUnavailable:
            return DTO(code: "signature_unavailable", phase: "render_demand", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Signature coordination is temporarily unavailable.")
        case .cancelled:
            return DTO(code: "signature_unavailable", phase: "render_demand", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Signature rendering was cancelled.")
        case let .candidate(candidate):
            let fileID: UUID? = switch candidate {
            case let .fileNotCataloged(fileID), let .fileOutsideRootScope(fileID), let .logicalPathUnavailable(fileID): fileID
            case .incompleteRootSet: nil
            }
            return DTO(code: "signature_unavailable", phase: "render_demand", path: fileID.flatMap { pathByFileID[$0] }, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "A current signature candidate is unavailable.")
        case let .pending(fileID, _):
            return DTO(code: "signature_pending", phase: "render_demand", path: pathByFileID[fileID], retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Signature generation is still pending.")
        case let .unavailable(fileID, reason):
            let retryable = switch reason {
            case .busy, .rootTransient, .staleCurrentness: true
            default: false
            }
            return DTO(code: "signature_unavailable", phase: "render_demand", path: pathByFileID[fileID], retryable: retryable, retryAfterMilliseconds: retryable ? 100 : nil, attempted: nil, limit: nil, message: "A signature artifact is unavailable; graph data remains usable.")
        case .automatic:
            return DTO(code: "signature_unavailable", phase: "render_demand", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Signature selection is unavailable.")
        case .freezeUnavailable:
            return DTO(code: "signature_freeze_failed", phase: "freeze", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Signatures could not be frozen; graph data remains usable.")
        case .renderUnavailable:
            return DTO(code: "signature_render_failed", phase: "render", path: nil, retryable: false, retryAfterMilliseconds: nil, attempted: nil, limit: nil, message: "Signatures could not be rendered; graph data remains usable.")
        case .publicationStale:
            return DTO(code: "signature_publication_stale", phase: "render", path: nil, retryable: true, retryAfterMilliseconds: 100, attempted: nil, limit: nil, message: "Signature rendering became stale; graph data remains usable.")
        }
    }

    private static func codeStructureStatusDTO(
        _ status: WorkspaceCodemapStructureStatus
    ) -> ToolResultDTOs.CodeStructureReplyDTO.Status {
        switch status {
        case .ok: .ok
        case .partial: .partial
        case .pending: .pending
        case .unavailable: .unavailable
        }
    }

    private static func codeStructureSeedStateDTO(
        _ state: WorkspaceCodemapStructureSeedState
    ) -> ToolResultDTOs.CodeStructureReplyDTO.SeedState {
        switch state {
        case .covered: .covered
        case .pending: .pending
        case .notIndexed: .notIndexed
        case .excluded: .excluded
        }
    }

    private static func codeStructureUnresolvedReasonDTO(
        _ reason: WorkspaceCodemapGraphUnresolvedReason
    ) -> ToolResultDTOs.CodeStructureReplyDTO.UnresolvedReason {
        switch reason {
        case .notIndexedYet: .notIndexedYet
        case .missing: .missing
        case .tooCommon: .tooCommon
        }
    }

    private static func codeStructureDirectionName(
        _ direction: WorkspaceCodemapStructureTraversalReachDirection
    ) -> String {
        switch direction {
        case .referencedDefinitions: "uses"
        case .referrers: "used_by"
        }
    }

    // Reads a file with optional slicing. Supports 1-based indices and a negative sentinel
    // for bottom-origin reads (start_line = -N reads the last N lines).
    // Returns both the content slice and metadata about the shown range.
}

private extension WorkspaceCodemapStructureExecutionPhase {
    var mcpToolExecutionHandlerPhase: MCPToolExecutionHandlerPhase {
        switch self {
        case .seedResolution: .getCodeStructureSeedResolution
        case .graphSnapshot: .getCodeStructureGraphSnapshot
        case .graphTraversal: .getCodeStructureGraphTraversal
        case .graphRevalidation: .getCodeStructureGraphRevalidation
        case .renderDemand: .getCodeStructureRenderDemand
        case .freeze: .getCodeStructureFreeze
        case .render: .getCodeStructureRender
        case .assembly: .getCodeStructureAssembly
        }
    }
}
