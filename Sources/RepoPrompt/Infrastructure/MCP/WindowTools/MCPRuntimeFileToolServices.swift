import Foundation
import MCP
import RepoPromptCore

enum MCPRuntimeFileToolServiceError: LocalizedError, Equatable {
    case workspaceReadinessUnavailable
    case worktreeScopeUnavailable(missingPhysicalRootPaths: [String])
    case pathNotFound(String)
    case pathIsNotFile(String)
    case contentUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .workspaceReadinessUnavailable:
            "The admitted workspace runtime is not ready for file queries. Retry after workspace activation completes."
        case let .worktreeScopeUnavailable(missingPhysicalRootPaths):
            "The admitted worktree scope is unavailable: \(missingPhysicalRootPaths.joined(separator: ", "))."
        case let .pathNotFound(path):
            "No file or folder was found for '\(path)' in the admitted workspace runtime."
        case let .pathIsNotFile(path):
            "'\(path)' is not a file in the admitted workspace runtime."
        case let .contentUnavailable(path):
            "Content for '\(path)' became unavailable in the admitted workspace runtime."
        }
    }

    var retryableSearchError: StoreBackedWorkspaceSearchError? {
        switch self {
        case .workspaceReadinessUnavailable:
            .workspaceReadinessUnavailable
        case let .worktreeScopeUnavailable(missingPhysicalRootPaths):
            .worktreeScopeUnavailable(missingPhysicalRootPaths: missingPhysicalRootPaths)
        case .pathNotFound, .pathIsNotFile, .contentUnavailable:
            nil
        }
    }
}

struct MCPRuntimeReadFileResult {
    let reply: ToolResultDTOs.ReadFileReply
    let resolvedPhysicalPath: String
}

struct MCPRuntimeFileSearchRequest {
    let pattern: String
    let mode: SearchMode
    let isRegex: Bool
    let maxResults: Int
    let pathLimiters: [String]?
    let includeExtensions: [String]
    let excludePatterns: [String]
    let contextLines: Int
    let wholeWord: Bool
    let countOnly: Bool
    let fuzzySpaceMatching: Bool
}

struct MCPRuntimeFileSearchResult {
    let results: SearchResults
    let rootRefs: [WorkspaceRootRef]
}

enum MCPRuntimeFileToolServices {
    static func executeRuntimeOrLegacy<Result>(
        runtimeRequest: MCPRuntimeRequestContext?,
        toolName: String,
        runtimeOperation: (MCPRuntimeFileToolContext) async throws -> Result,
        legacyOperation: () async throws -> Result
    ) async throws -> Result {
        try await executeRuntimeOrLegacy(
            runtimeContext: runtimeRequest?.fileToolContext,
            runtimeWasAdmitted: runtimeRequest != nil,
            toolName: toolName,
            runtimeOperation: runtimeOperation,
            legacyOperation: legacyOperation
        )
    }

    static func executeRuntimeOrLegacy<Result>(
        runtimeContext: MCPRuntimeFileToolContext?,
        runtimeWasAdmitted: Bool,
        toolName: String,
        runtimeOperation: (MCPRuntimeFileToolContext) async throws -> Result,
        legacyOperation: () async throws -> Result
    ) async throws -> Result {
        guard runtimeWasAdmitted else {
            return try await legacyOperation()
        }
        guard let runtimeContext else {
            throw MCPError.internalError("The admitted runtime file context is unavailable for \(toolName).")
        }
        return try await runtimeOperation(runtimeContext)
    }

    private static func unavailableError(
        _ availability: WorkspaceLookupRootScopeAvailability
    ) -> MCPRuntimeFileToolServiceError {
        switch availability {
        case .available:
            .workspaceReadinessUnavailable
        case let .sessionWorktreeUnavailable(missingPhysicalRootPaths):
            missingPhysicalRootPaths.isEmpty
                ? .workspaceReadinessUnavailable
                : .worktreeScopeUnavailable(missingPhysicalRootPaths: missingPhysicalRootPaths)
        }
    }

    private static func requireRootScopeAvailable(
        context: MCPRuntimeFileToolContext
    ) async throws {
        let availability = await context.query.rootScopeAvailability(context.lookupContext.rootScope)
        guard availability == .available else {
            throw unavailableError(availability)
        }
    }

    private static func availableCatalog(
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsOnly,
        context: MCPRuntimeFileToolContext
    ) async throws -> WorkspaceSearchCatalogSnapshot {
        try await requireRootScopeAvailable(context: context)
        await context.query.awaitAppliedIngress(rootScope: context.lookupContext.rootScope)
        try Task.checkCancellation()
        let access = await context.query.searchCatalogAccess(
            rootScope: context.lookupContext.rootScope,
            requirement: requirement
        )
        let snapshot: WorkspaceSearchCatalogSnapshot
        switch access {
        case let .available(available):
            snapshot = available
        case let .unavailable(availability):
            throw unavailableError(availability)
        }
        try await requireRootScopeAvailable(context: context)
        return snapshot
    }

    static func resolveCodeStructureFiles(
        paths: [String],
        context: MCPRuntimeFileToolContext
    ) async throws -> [WorkspaceFileRecord] {
        let catalog = try await availableCatalog(context: context)
        var result: [WorkspaceFileRecord] = []
        var seen = Set<String>()
        for path in paths {
            try Task.checkCancellation()
            if let issue = await context.query.exactPathResolutionIssue(
                for: path,
                kind: .either,
                rootScope: context.lookupContext.rootScope
            ) {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }
            guard let lookup = await context.query.lookupPath(WorkspacePathLookupRequest(
                userPath: path,
                profile: .mcpRead,
                rootScope: context.lookupContext.rootScope
            )) else {
                try await requireRootScopeAvailable(context: context)
                throw MCPRuntimeFileToolServiceError.pathNotFound(path)
            }
            if let file = lookup.file, seen.insert(file.standardizedFullPath).inserted {
                result.append(file)
                continue
            }
            guard let folder = lookup.folder else {
                try await requireRootScopeAvailable(context: context)
                throw MCPRuntimeFileToolServiceError.pathNotFound(path)
            }
            let prefix = folder.standardizedRelativePath.isEmpty
                ? ""
                : folder.standardizedRelativePath + "/"
            for file in catalog.files where file.rootID == folder.rootID
                && (prefix.isEmpty || file.standardizedRelativePath.hasPrefix(prefix))
                && seen.insert(file.standardizedFullPath).inserted
            {
                result.append(file)
            }
        }
        try await requireRootScopeAvailable(context: context)
        return result
    }

    static func buildCodeStructureDTO(
        files: [WorkspaceFileRecord],
        maxResults: Int,
        includeUnmappedPaths: Bool,
        context: MCPRuntimeFileToolContext
    ) async throws -> ToolResultDTOs.SelectedCodeStructureDTO {
        try await requireRootScopeAvailable(context: context)
        let roots = await context.query.rootRefs(scope: context.lookupContext.rootScope)
        let rootIDs = Set(roots.map(\.id))
        let codemaps = await context.query.codemapSnapshotBundle(rootScope: context.lookupContext.rootScope)
        try await requireRootScopeAvailable(context: context)
        var entries: [(key: String, display: String, api: FileAPI?)] = []
        var seen = Set<String>()
        for file in files where rootIDs.contains(file.rootID) && seen.insert(file.standardizedFullPath).inserted {
            let display = context.lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: file.standardizedFullPath,
                display: .relative
            ) ?? roots.first(where: { $0.id == file.rootID }).map {
                ClientPathFormatter.displayPath(root: $0, relativePath: file.standardizedRelativePath, visibleRoots: roots)
            } ?? file.relativePath
            entries.append((file.standardizedFullPath, display, codemaps.snapshot(for: file)?.fileAPI))
        }
        entries.sort { $0.display == $1.display ? $0.key < $1.key : $0.display < $1.display }

        let cap = max(0, maxResults)
        let mapped = entries.filter { $0.api != nil }
        var content: [String] = []
        var estimatedTokens = 0
        var tokenOmitted = 0
        for entry in mapped.prefix(cap) {
            guard let api = entry.api else { continue }
            let estimate = api.estimatedFullAPIDescriptionTokens(displayPath: entry.display)
            if estimatedTokens + estimate > 6000, !content.isEmpty {
                tokenOmitted += 1
                continue
            }
            content.append(api.getFullAPIDescription(displayPath: entry.display))
            estimatedTokens += estimate
        }
        let maxOmitted = max(0, mapped.count - cap)
        let unmapped = includeUnmappedPaths
            ? entries.filter { $0.api == nil }.map(\.display).sorted()
            : []
        return ToolResultDTOs.SelectedCodeStructureDTO(
            fileCount: content.count,
            content: content.joined(separator: "\n\n"),
            unmappedPaths: unmapped.isEmpty ? nil : unmapped,
            pendingPaths: nil,
            omittedCount: maxOmitted > 0 ? maxOmitted : nil,
            omittedTotal: maxOmitted + tokenOmitted > 0 ? maxOmitted + tokenOmitted : nil,
            tokenBudgetOmittedCount: tokenOmitted > 0 ? tokenOmitted : nil,
            tokenBudgetHit: tokenOmitted > 0 ? true : nil,
            worktreeScope: ToolResultDTOs.WorktreeScopeDTO.sessionBound(
                from: context.lookupContext.bindingProjection
            )
        )
    }

    static func readFile(
        path: String,
        startLine1Based: Int?,
        lineCount: Int?,
        context: MCPRuntimeFileToolContext
    ) async throws -> MCPRuntimeReadFileResult {
        let catalog = try await availableCatalog(context: context)
        let resolvedPath = context.lookupContext.translateInputPath(path)
        if let issue = await context.query.exactPathResolutionIssue(
            for: resolvedPath,
            kind: .file,
            rootScope: context.lookupContext.rootScope
        ) {
            throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
        }
        guard let lookup = await context.query.lookupPath(WorkspacePathLookupRequest(
            userPath: resolvedPath,
            profile: .mcpRead,
            rootScope: context.lookupContext.rootScope
        )) else {
            try await requireRootScopeAvailable(context: context)
            throw MCPRuntimeFileToolServiceError.pathNotFound(path)
        }
        guard let file = lookup.file else {
            try await requireRootScopeAvailable(context: context)
            throw MCPRuntimeFileToolServiceError.pathIsNotFile(path)
        }
        guard let rootRecord = catalog.roots.first(where: { $0.id == file.rootID }) else {
            throw MCPRuntimeFileToolServiceError.workspaceReadinessUnavailable
        }
        let rootRefs = catalog.roots.map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
        let root = WorkspaceRootRef(
            id: rootRecord.id,
            name: rootRecord.name,
            fullPath: rootRecord.standardizedFullPath
        )
        let contentSnapshot = try await context.query.searchContentSnapshot(
            for: file,
            freshnessPolicy: .validateDiskMetadata
        )
        guard contentSnapshot.isFresh, let content = contentSnapshot.content else {
            throw MCPRuntimeFileToolServiceError.contentUnavailable(path)
        }
        try Task.checkCancellation()

        let displayPath = context.lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: file.standardizedFullPath,
            display: context.filePathDisplay
        ) ?? {
            switch context.filePathDisplay {
            case .full:
                file.standardizedFullPath
            case .relative:
                ClientPathFormatter.displayPath(
                    root: root,
                    relativePath: file.standardizedRelativePath,
                    visibleRoots: rootRefs
                )
            }
        }()
        let preparedContent = await WorkspaceInteractiveReadProcessor.prepareOffActor(content)
        let prepared = try await MCPReadFileToolProjection.makeBaseReply(
            preparedContent: preparedContent,
            startLine1Based: startLine1Based,
            lineCount: lineCount,
            displayPath: displayPath
        )
        let reply = try await MCPReadFileToolProjection.projectReply(
            prepared.reply,
            displayPath: displayPath,
            worktreeScope: ToolResultDTOs.WorktreeScopeDTO.sessionBound(
                from: context.lookupContext.bindingProjection
            )
        )
        try await requireRootScopeAvailable(context: context)
        return MCPRuntimeReadFileResult(
            reply: reply,
            resolvedPhysicalPath: file.standardizedFullPath
        )
    }

    static func fileSearch(
        request: MCPRuntimeFileSearchRequest,
        context: MCPRuntimeFileToolContext
    ) async throws -> MCPRuntimeFileSearchResult {
        let catalog = try await availableCatalog(context: context)
        let rootRefs = catalog.roots.map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
        let rootsByID = Dictionary(uniqueKeysWithValues: catalog.roots.map { ($0.id, $0) })
        let scopedFiles = try await searchFiles(
            from: catalog.files,
            rootsByID: rootsByID,
            rootRefs: rootRefs,
            pathLimiters: request.pathLimiters,
            context: context
        )
        let descriptors = scopedFiles.compactMap { file -> SearchFileDescriptor? in
            guard let root = rootsByID[file.rootID] else { return nil }
            return SearchFileDescriptor(
                id: file.id,
                name: file.name,
                relativePath: file.relativePath,
                standardizedRelativePath: file.standardizedRelativePath,
                fullPath: file.fullPath,
                standardizedFullPath: file.standardizedFullPath,
                standardizedRootFolderPath: root.standardizedFullPath,
                fileExtension: {
                    let ext = (file.name as NSString).pathExtension
                    return ext.isEmpty ? nil : ext
                }(),
                contentSnapshot: { freshnessPolicy in
                    try await context.query.searchContentSnapshot(
                        for: file,
                        freshnessPolicy: freshnessPolicy
                    )
                }
            )
        }
        let aliasByRootPath = Dictionary(uniqueKeysWithValues: catalog.roots.map { root in
            let ref = WorkspaceRootRef(id: root.id, name: root.name, fullPath: root.standardizedFullPath)
            return (
                root.standardizedFullPath,
                ClientPathFormatter.nonAbsoluteRootAlias(root: ref, visibleRoots: rootRefs)
            )
        })

        let actor = FileSearchActor()
        var wasAutoCorrected: Bool?
        var results = try await actor.searchUnified(
            pattern: request.pattern,
            isRegex: request.isRegex,
            wasAutoCorrected: &wasAutoCorrected,
            options: SearchOptions(
                mode: request.mode,
                caseInsensitive: true,
                wholeWord: request.wholeWord,
                includeExtensions: request.includeExtensions,
                excludePatterns: request.excludePatterns,
                contextLines: request.contextLines,
                maxResults: request.maxResults,
                countOnly: request.countOnly,
                fuzzySpaceMatching: request.fuzzySpaceMatching,
                allowLiteralUnescapeFallback: true,
                contentFreshnessPolicy: .validateDiskMetadata
            ),
            in: descriptors,
            aliasByRootPath: aliasByRootPath
        )
        results.scopedFileCount = scopedFiles.count
        if wasAutoCorrected == true {
            results.warningMessage = request.isRegex
                ? "The content-search pattern was auto-corrected before running. Results may reflect a repaired or escaped version of the requested regex rather than the exact pattern you entered."
                : "The content-search pattern was auto-corrected before running. Results may reflect a de-escaped literal interpretation of the text you entered."
        }
        try await requireRootScopeAvailable(context: context)
        return MCPRuntimeFileSearchResult(results: results, rootRefs: rootRefs)
    }

    private static func searchFiles(
        from files: [WorkspaceFileRecord],
        rootsByID: [UUID: WorkspaceRootRecord],
        rootRefs: [WorkspaceRootRef],
        pathLimiters: [String]?,
        context: MCPRuntimeFileToolContext
    ) async throws -> [WorkspaceFileRecord] {
        guard let pathLimiters, !pathLimiters.isEmpty else { return files }

        var clauses: [SearchPathClause] = []
        var clauseKeys = Set<String>()
        var issues: [PathResolutionIssue] = []

        func appendClause(_ clause: SearchPathClause) {
            guard clauseKeys.insert(String(describing: clause)).inserted else { return }
            clauses.append(clause)
        }

        for rawLimiter in pathLimiters {
            try Task.checkCancellation()
            let translated = context.lookupContext.translateInputPath(rawLimiter)
            let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let normalized = expanded.hasPrefix("/")
                ? StandardizedPath.absolute(expanded)
                : StandardizedPath.relative(expanded)
            let hasWildcard = normalized.contains("*")
                || normalized.contains("?")
                || normalized.contains("[")

            if hasWildcard {
                if normalized.hasPrefix("/"),
                   let root = rootRefs
                   .filter({
                       normalized == $0.standardizedFullPath
                           || normalized.hasPrefix(
                               $0.standardizedFullPath.hasSuffix("/")
                                   ? $0.standardizedFullPath
                                   : $0.standardizedFullPath + "/"
                           )
                   })
                   .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
                {
                    let prefix = root.standardizedFullPath.hasSuffix("/")
                        ? root.standardizedFullPath
                        : root.standardizedFullPath + "/"
                    let relativePattern = normalized == root.standardizedFullPath
                        ? ""
                        : StandardizedPath.relative(String(normalized.dropFirst(prefix.count)))
                    appendClause(.glob(
                        pattern: relativePattern,
                        restrictedRootPath: root.standardizedFullPath
                    ))
                    continue
                }

                let parts = normalized.split(
                    separator: "/",
                    maxSplits: 1,
                    omittingEmptySubsequences: true
                )
                if parts.count == 2 {
                    let alias = String(parts[0])
                    let matchingRoots = rootRefs.filter {
                        $0.name.caseInsensitiveCompare(alias) == .orderedSame
                    }
                    if matchingRoots.count == 1, let root = matchingRoots.first {
                        appendClause(.glob(
                            pattern: StandardizedPath.relative(String(parts[1])),
                            restrictedRootPath: root.standardizedFullPath
                        ))
                        continue
                    }
                    if matchingRoots.count > 1 {
                        issues.append(.ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
                        continue
                    }
                }

                appendClause(.glob(pattern: normalized, restrictedRootPath: nil))
                continue
            }

            if let issue = await context.query.exactPathResolutionIssue(
                for: normalized,
                kind: .either,
                rootScope: context.lookupContext.rootScope
            ) {
                issues.append(issue)
                continue
            }

            guard let lookup = await context.query.lookupPath(WorkspacePathLookupRequest(
                userPath: normalized,
                profile: .mcpSearchScope,
                rootScope: context.lookupContext.rootScope
            )) else {
                try await requireRootScopeAvailable(context: context)
                appendClause(.legacyPrefix(candidateLower: normalized.lowercased()))
                continue
            }

            let restrictedRootPath = rootsByID[lookup.location.rootID]?.standardizedFullPath
            if let file = lookup.file {
                appendClause(.exactFile(
                    absPath: file.standardizedFullPath,
                    relPath: file.standardizedRelativePath,
                    restrictedRootPath: restrictedRootPath
                ))
            } else if let folder = lookup.folder {
                appendClause(.exactFolder(
                    absLower: folder.standardizedFullPath.lowercased(),
                    relLower: folder.standardizedRelativePath.lowercased(),
                    restrictedRootPath: restrictedRootPath
                ))
            } else {
                try await requireRootScopeAvailable(context: context)
            }
        }

        if clauses.isEmpty, let issue = issues.first {
            throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
        }

        let snapshots = files.map { file in
            let rootRef = rootsByID[file.rootID].map {
                WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
            }
            let displayPath = rootRef.map {
                ClientPathFormatter.displayPath(
                    root: $0,
                    relativePath: file.standardizedRelativePath,
                    visibleRoots: rootRefs
                )
            } ?? file.standardizedRelativePath
            return RepoPromptCore.FileSearchPathSnapshot(
                standardizedFullPath: file.standardizedFullPath,
                standardizedRelativePath: file.standardizedRelativePath,
                standardizedRootPath: rootRef?.standardizedFullPath ?? "",
                clientDisplayPath: displayPath
            )
        }
        let spec = SearchPathFilterSpec(caseInsensitive: true, clauses: clauses)
        let matchedPaths = Set(RepoPromptCore.filterPaths(snapshots: snapshots, spec: spec))
        try Task.checkCancellation()
        return files.filter { matchedPaths.contains($0.standardizedFullPath) }
    }

    static func fileTree(
        type: String,
        mode: String,
        maxDepth: Int?,
        startPath: String?,
        context: MCPRuntimeFileToolContext
    ) async throws -> ToolResultDTOs.FileTreeDTO {
        _ = try await availableCatalog(context: context)
        let snapshotMode: WorkspaceFileTreeSnapshotMode = switch mode.lowercased() {
        case "full": .full
        case "folders": .folders
        case "auto": .auto
        default: throw MCPError.invalidParams("invalid mode: \(mode)")
        }
        let snapshot = await context.query.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: snapshotMode,
                filePathDisplay: context.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: context.codeMapsEnabled,
                rootScope: context.lookupContext.rootScope,
                startPath: startPath.map(context.lookupContext.translateInputPath),
                maxDepth: maxDepth
            ),
            profile: .mcpRead
        )
        try await requireRootScopeAvailable(context: context)
        let logical = context.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(snapshot) ?? snapshot
        let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: context.lookupContext.bindingProjection)
        if type == "roots" {
            let lines = logical.roots.map(\.fullPath)
            return ToolResultDTOs.FileTreeDTO(
                rootsCount: logical.roots.count,
                usesLegend: false,
                tree: lines.isEmpty ? "No workspace loaded" : lines.joined(separator: "\n"),
                note: lines.isEmpty ? "No workspace loaded" : nil,
                wasTruncated: false,
                worktreeScope: worktreeScope
            )
        }
        let tree = await Task.detached(priority: .userInitiated) {
            CodeMapExtractor.generateFileTree(using: logical)
        }.value
        return ToolResultDTOs.FileTreeDTO(
            rootsCount: logical.roots.count,
            usesLegend: false,
            tree: tree.isEmpty ? "No workspace loaded" : tree,
            note: tree.isEmpty ? "No workspace loaded" : nil,
            wasTruncated: false,
            worktreeScope: worktreeScope
        )
    }
}
