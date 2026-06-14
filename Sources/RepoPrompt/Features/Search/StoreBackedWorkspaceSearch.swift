import Foundation

enum StoreBackedWorkspaceSearchError: LocalizedError, Equatable {
    case worktreeScopeUnavailable(missingPhysicalRootPaths: [String])

    var retryAfterMilliseconds: Int {
        1000
    }

    var suggestion: String {
        "Retry after the suggested delay. If the worktree remains unavailable, restore it or rebind the Agent session to an available worktree."
    }

    var errorDescription: String? {
        switch self {
        case let .worktreeScopeUnavailable(missingPhysicalRootPaths):
            let count = missingPhysicalRootPaths.count
            let noun = count == 1 ? "worktree root is" : "worktree roots are"
            return "The bound physical \(noun) unavailable. The visible base workspace was intentionally not searched."
        }
    }
}

/// Store-backed runtime search facade for MCP and other non-UI consumers.
///
/// This intentionally works from `WorkspaceFileContextStore` catalog snapshots rather than
/// `WorkspaceFilesViewModel` tree projections.
enum StoreBackedWorkspaceSearch {
    static func search(
        pattern: String,
        mode: SearchMode = .auto,
        isRegex: Bool = false,
        caseInsensitive: Bool = false,
        maxPaths: Int = 100,
        maxMatches: Int = 250,
        paths: [String]? = nil,
        includeExtensions: [String] = [],
        excludePatterns: [String] = [],
        contextLines: Int = 0,
        wholeWord: Bool = false,
        countOnly: Bool = false,
        fuzzySpaceMatching: Bool = true,
        allowLiteralUnescapeFallback: Bool = true,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        store: WorkspaceFileContextStore,
        workspaceManager: WorkspaceManagerViewModel?
    ) async throws -> SearchResults {
        try Task.checkCancellation()
        try await ensureRootScopeAvailable(rootScope, store: store)
        try await ensureSearchReady(store: store, workspaceManager: workspaceManager)

        let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode
        let admissionClass = broadSearchAdmissionClass(pattern: pattern, mode: mode, paths: paths)
        return try await store.withStoreBackedSearchAccess(
            searchMode: effectiveMode,
            admissionClass: admissionClass
        ) { fileSearchActor in
            if admissionClass != nil {
                try await ensureRootScopeAvailable(rootScope, store: store)
                try await ensureSearchReady(store: store, workspaceManager: workspaceManager)
            }

            let ingressFreshnessState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.ingressFreshnessWait)
            let appliedIngressSamples = await store.awaitAppliedIngress(rootScope: rootScope)
            EditFlowPerf.end(EditFlowPerf.Stage.Search.ingressFreshnessWait, ingressFreshnessState)
            try Task.checkCancellation()
            let contentFreshnessPolicy = await store.contentSearchFreshnessPolicy(
                rootScope: rootScope,
                appliedIngressSamples: appliedIngressSamples
            )
            try Task.checkCancellation()

            return try await performSearch(
                pattern: pattern,
                mode: mode,
                effectiveMode: effectiveMode,
                isRegex: isRegex,
                caseInsensitive: caseInsensitive,
                maxPaths: maxPaths,
                maxMatches: maxMatches,
                paths: paths,
                includeExtensions: includeExtensions,
                excludePatterns: excludePatterns,
                contextLines: contextLines,
                wholeWord: wholeWord,
                countOnly: countOnly,
                fuzzySpaceMatching: fuzzySpaceMatching,
                allowLiteralUnescapeFallback: allowLiteralUnescapeFallback,
                contentFreshnessPolicy: contentFreshnessPolicy,
                rootScope: rootScope,
                store: store,
                fileSearchActor: fileSearchActor
            )
        }
    }

    static func requiresBroadSearchAdmission(
        pattern: String,
        mode: SearchMode,
        paths: [String]?
    ) -> Bool {
        broadSearchAdmissionClass(pattern: pattern, mode: mode, paths: paths) != nil
    }

    static func broadSearchAdmissionClass(
        pattern: String,
        mode: SearchMode,
        paths: [String]?
    ) -> BroadSearchAdmissionClass? {
        let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode
        let hasExplicitScope = paths?.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
        guard !hasExplicitScope else { return nil }
        switch effectiveMode {
        case .content:
            return .unscopedContent
        case .both:
            return .unscopedBoth
        case .auto, .path:
            return nil
        }
    }

    private static func performSearch(
        pattern: String,
        mode: SearchMode,
        effectiveMode: SearchMode,
        isRegex: Bool,
        caseInsensitive: Bool,
        maxPaths: Int,
        maxMatches: Int,
        paths: [String]?,
        includeExtensions: [String],
        excludePatterns: [String],
        contextLines: Int,
        wholeWord: Bool,
        countOnly: Bool,
        fuzzySpaceMatching: Bool,
        allowLiteralUnescapeFallback: Bool,
        contentFreshnessPolicy: FileContentFreshnessPolicy,
        rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore,
        fileSearchActor: FileSearchActor
    ) async throws -> SearchResults {
        let entryPerfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.entrypoint,
            EditFlowPerf.Dimensions(
                searchMode: mode.rawValue,
                maxResults: max(maxPaths, maxMatches),
                isRegex: isRegex,
                countOnly: countOnly,
                caseInsensitive: caseInsensitive,
                wholeWord: wholeWord,
                contextLines: contextLines
            )
        )
        var entryPerfStatus = "ok"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.entrypoint,
                entryPerfState,
                EditFlowPerf.Dimensions(
                    status: entryPerfStatus,
                    searchMode: mode.rawValue,
                    maxResults: max(maxPaths, maxMatches),
                    isRegex: isRegex,
                    countOnly: countOnly,
                    caseInsensitive: caseInsensitive,
                    wholeWord: wholeWord,
                    contextLines: contextLines
                )
            )
        }

        let snapshot: WorkspaceSearchCatalogSnapshot
        switch await store.searchCatalogAccess(rootScope: rootScope) {
        case let .available(availableSnapshot):
            snapshot = availableSnapshot
        case let .unavailable(availability):
            entryPerfStatus = "error"
            throw searchError(for: availability)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: snapshot.roots.map { ($0.id, $0) })
        let visibleRootRefs = await store.rootRefs(scope: .visibleWorkspace)
        let visibleRootIDs = Set(visibleRootRefs.map(\.id))
        let visibleRootRecords = snapshot.roots.filter { visibleRootIDs.contains($0.id) }
        let allFiles = snapshot.files
        let scopePerfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.scopeFiltering,
            EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: allFiles.count)
        )

        let filesToSearch: [WorkspaceFileRecord]
        if let rawPaths = paths, !rawPaths.isEmpty {
            let parsed = await parseSearchScopePaths(rawPaths, caseInsensitive: caseInsensitive, rootScope: rootScope, store: store)
            if parsed.spec.clauses.isEmpty, let issue = parsed.issues.first {
                entryPerfStatus = "error"
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Search.scopeFiltering,
                    scopePerfState,
                    EditFlowPerf.Dimensions(status: "error", fileCount: allFiles.count)
                )
                throw FileManagerError.fileSystemServiceNotFoundWithContext(
                    PathResolutionIssueRenderer.message(for: issue)
                )
            }

            let snapshots = allFiles.map { file in
                let root = rootsByID[file.rootID].map { WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath) }
                let clientDisplayPath = root.map {
                    ClientPathFormatter.displayPath(root: $0, relativePath: file.standardizedRelativePath, visibleRoots: visibleRootRefs)
                } ?? file.standardizedRelativePath
                return FileSearchPathSnapshot(
                    standardizedFullPath: file.standardizedFullPath,
                    standardizedRelativePath: file.standardizedRelativePath,
                    standardizedRootPath: root?.standardizedFullPath ?? "",
                    clientDisplayPath: clientDisplayPath
                )
            }
            let filterTask = Task.detached(priority: .userInitiated) { [snapshots, spec = parsed.spec] in
                filterPathIndicesResult(snapshots: snapshots, spec: spec)
            }
            if Task.isCancelled { filterTask.cancel() }
            let filterResult = await withTaskCancellationHandler {
                await filterTask.value
            } onCancel: {
                filterTask.cancel()
            }
            if filterResult.cancelled || Task.isCancelled {
                throw CancellationError()
            }
            filesToSearch = filterResult.matchedSnapshotIndices.map { allFiles[$0] }
        } else {
            filesToSearch = allFiles
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.scopeFiltering,
            scopePerfState,
            EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: filesToSearch.count)
        )

        let effectiveContentFreshnessPolicy: FileContentFreshnessPolicy =
            (effectiveMode == .content || effectiveMode == .both)
                ? contentFreshnessPolicy
                : .cachedMetadata
        let aliasByRootPath = pathSearchAliasByRootPath(roots: visibleRootRecords)
        var wasAutoCorrected: Bool? = nil
        var results: SearchResults
        do {
            results = try await EditFlowPerf.measure(
                EditFlowPerf.Stage.Search.actorSearchCall,
                EditFlowPerf.Dimensions(
                    searchMode: mode.rawValue,
                    fileCount: filesToSearch.count,
                    maxResults: max(maxPaths, maxMatches),
                    isRegex: isRegex,
                    countOnly: countOnly,
                    caseInsensitive: caseInsensitive,
                    wholeWord: wholeWord,
                    contextLines: contextLines
                )
            ) {
                try await fileSearchActor.searchUnified(
                    pattern: pattern,
                    isRegex: isRegex,
                    wasAutoCorrected: &wasAutoCorrected,
                    options: SearchOptions(
                        mode: mode,
                        caseInsensitive: caseInsensitive,
                        wholeWord: wholeWord,
                        includeExtensions: includeExtensions,
                        excludePatterns: excludePatterns,
                        contextLines: contextLines,
                        maxResults: max(maxPaths, maxMatches),
                        countOnly: countOnly,
                        fuzzySpaceMatching: fuzzySpaceMatching,
                        allowLiteralUnescapeFallback: allowLiteralUnescapeFallback,
                        contentFreshnessPolicy: effectiveContentFreshnessPolicy
                    ),
                    in: filesToSearch,
                    rootsByID: rootsByID,
                    store: store,
                    aliasByRootPath: aliasByRootPath
                )
            }
        } catch {
            entryPerfStatus = "error"
            throw error
        }
        results.scopedFileCount = filesToSearch.count
        if wasAutoCorrected == true {
            results.warningMessage = searchAutoCorrectionWarning(isRegex: isRegex)
        }
        return results
    }

    private static func ensureRootScopeAvailable(
        _ rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore
    ) async throws {
        let availability = await store.rootScopeAvailability(rootScope)
        guard availability == .available else {
            throw searchError(for: availability)
        }
    }

    private static func searchError(
        for availability: WorkspaceLookupRootScopeAvailability
    ) -> StoreBackedWorkspaceSearchError {
        switch availability {
        case .available:
            preconditionFailure("Available root scope does not produce a search error")
        case let .sessionWorktreeUnavailable(missingPhysicalRootPaths):
            .worktreeScopeUnavailable(missingPhysicalRootPaths: missingPhysicalRootPaths)
        }
    }

    private static func ensureSearchReady(
        store: WorkspaceFileContextStore,
        workspaceManager: WorkspaceManagerViewModel?
    ) async throws {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        guard !roots.isEmpty else {
            let msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }
        guard let workspaceManager else { return }
        let state = await MainActor.run { workspaceManager.workspaceSearchReadinessState }
        switch state {
        case .ready, .degraded:
            return
        case .idle:
            return
        case .activating, .loadingCatalog, .buildingIndexes:
            throw FileManagerError.fileSystemServiceNotFoundWithContext(
                "Workspace search is still loading. Wait for workspace search readiness before using file_search to avoid partial or false-empty results."
            )
        }
    }

    private static func searchAutoCorrectionWarning(isRegex: Bool) -> String {
        if isRegex {
            return "The content-search pattern was auto-corrected before running. Results may reflect a repaired or escaped version of the requested regex rather than the exact pattern you entered."
        }
        return "The content-search pattern was auto-corrected before running. Results may reflect a de-escaped literal interpretation of the text you entered."
    }

    private struct SearchScopeParseResult {
        let spec: SearchPathFilterSpec
        let issues: [PathResolutionIssue]
    }

    private static func parseSearchScopePaths(
        _ rawPaths: [String],
        caseInsensitive: Bool,
        rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore
    ) async -> SearchScopeParseResult {
        var clauses: [SearchPathClause] = []
        var issues: [PathResolutionIssue] = []
        var seenClauses = Set<String>()
        let scopedRoots = await store.rootRefs(scope: rootScope)

        func appendClause(_ clause: SearchPathClause) {
            let key = String(describing: clause)
            if seenClauses.insert(key).inserted {
                clauses.append(clause)
            }
        }

        func appendWildcardClause(for normalized: String) {
            if normalized.hasPrefix("/"),
               let root = scopedRoots
               .filter({ normalized == $0.standardizedFullPath || normalized.hasPrefix($0.standardizedFullPath.hasSuffix("/") ? $0.standardizedFullPath : $0.standardizedFullPath + "/") })
               .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            {
                let prefix = root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/"
                let relativePattern = normalized == root.standardizedFullPath
                    ? ""
                    : StandardizedPath.relative(String(normalized.dropFirst(prefix.count)))
                appendClause(.glob(pattern: relativePattern, restrictedRootPath: root.standardizedFullPath))
                return
            }

            let parts = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let alias = String(parts[0])
                let matches = scopedRoots.filter { $0.name.caseInsensitiveCompare(alias) == .orderedSame }
                if matches.count == 1, let root = matches.first {
                    appendClause(.glob(pattern: StandardizedPath.relative(String(parts[1])), restrictedRootPath: root.standardizedFullPath))
                    return
                }
                if matches.count > 1 {
                    issues.append(.ambiguousAlias(alias: alias, matchingRoots: matches))
                    return
                }
            }

            appendClause(.glob(pattern: normalized, restrictedRootPath: nil))
        }

        for raw in rawPaths {
            let normalized = normalizeUserInputPath(raw)
            guard !normalized.isEmpty else { continue }
            let hasWildcard = normalized.contains("*") || normalized.contains("?") || normalized.contains("[")
            if hasWildcard {
                appendWildcardClause(for: normalized)
                continue
            }

            if let issue = await store.exactPathResolutionIssue(for: normalized, kind: .either, rootScope: rootScope) {
                issues.append(issue)
                continue
            }
            var lookup = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(normalized, rootScope: rootScope)
            if lookup == nil {
                lookup = await store.lookupPath(WorkspacePathLookupRequest(userPath: normalized, profile: .mcpSearchScope, rootScope: rootScope))
            }
            if let lookup {
                if let file = lookup.file {
                    let root = scopedRoots.first { $0.id == file.rootID }
                    appendClause(.exactFile(absPath: file.standardizedFullPath, relPath: file.standardizedRelativePath, restrictedRootPath: root?.standardizedFullPath))
                    continue
                }
                if let folder = lookup.folder {
                    let root = scopedRoots.first { $0.id == folder.rootID }
                    appendClause(.exactFolder(
                        absLower: folder.standardizedFullPath.lowercased(),
                        relLower: folder.standardizedRelativePath.lowercased(),
                        restrictedRootPath: root?.standardizedFullPath
                    ))
                    continue
                }
            }
            appendClause(.legacyPrefix(candidateLower: normalized.lowercased()))
        }

        return SearchScopeParseResult(
            spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: clauses),
            issues: issues
        )
    }

    private static func normalizeUserInputPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return StandardizedPath.absolute(expanded)
        }
        return StandardizedPath.relative(expanded)
    }

    private static func pathSearchAliasByRootPath(roots: [WorkspaceRootRecord]) -> [String: String]? {
        guard roots.count > 1 else { return nil }
        let nameCounts = Dictionary(grouping: roots, by: { $0.name.lowercased() })
        var aliasByRootPath: [String: String] = [:]
        for root in roots {
            guard !root.name.isEmpty,
                  nameCounts[root.name.lowercased()]?.count == 1 else { continue }
            aliasByRootPath[root.standardizedFullPath] = root.name
        }
        return aliasByRootPath.isEmpty ? nil : aliasByRootPath
    }
}
