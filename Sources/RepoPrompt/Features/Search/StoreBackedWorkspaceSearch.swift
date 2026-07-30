import Foundation
import RepoPromptShared

enum StoreBackedWorkspaceSearchError: LocalizedError, Equatable {
    case worktreeScopeUnavailable(missingPhysicalRootPaths: [String])
    case workspaceFreshnessTimedOut
    case workspaceReadinessUnavailable
    case workspaceReadinessTimedOut
    case workspaceReadinessSuperseded

    var retryAfterMilliseconds: Int {
        1000
    }

    var suggestion: String {
        switch self {
        case .worktreeScopeUnavailable:
            "Retry after the suggested delay. If the worktree remains unavailable, restore it or rebind the Agent session to an available worktree."
        case .workspaceFreshnessTimedOut:
            "Retry after workspace file updates finish applying."
        case .workspaceReadinessUnavailable:
            "Wait for a workspace activation to establish search readiness, then retry."
        case .workspaceReadinessTimedOut:
            "Retry after workspace catalog and index hydration completes."
        case .workspaceReadinessSuperseded:
            "Retry the search against the newly active workspace."
        }
    }

    var errorDescription: String? {
        switch self {
        case let .worktreeScopeUnavailable(missingPhysicalRootPaths):
            let count = missingPhysicalRootPaths.count
            let noun = count == 1 ? "worktree root is" : "worktree roots are"
            return "The bound physical \(noun) unavailable. The visible base workspace was intentionally not searched."
        case .workspaceFreshnessTimedOut:
            return "Workspace freshness timed out before file_search could begin. Retry the search after workspace updates finish applying."
        case .workspaceReadinessUnavailable:
            return "Workspace search readiness is unavailable because no workspace activation is currently established."
        case .workspaceReadinessTimedOut:
            return "Workspace search readiness timed out before file_search could begin."
        case .workspaceReadinessSuperseded:
            return "Workspace search was superseded by a workspace activation or hydration generation change."
        }
    }
}

/// Store-backed runtime search facade for MCP and other non-UI consumers.
///
/// This intentionally works from `WorkspaceFileContextStore` catalog snapshots rather than
/// `WorkspaceFilesViewModel` tree projections.
enum StoreBackedWorkspaceSearch {
    #if DEBUG
        @TaskLocal static var readinessWaitTimeoutOverrideForTesting: Duration?
        @TaskLocal static var freshnessWaitTimeoutOverrideForTesting: Duration?
        @TaskLocal static var freshnessWaitOperationOverrideForTesting: (@Sendable ([WorkspaceRootRef], WorkspaceFileContextStore) async -> [WorkspaceIngressBarrierSample])?
    #endif

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
        try await FileSystemService.withContentReadForegroundActivity(kind: .storeBackedSearch) {
            #if DEBUG
                let diagnosticCollector = WorkspaceFileSearchDebugContext.collector
                let diagnosticSearchStart = WorkspaceFileSearchDebugTiming.now()
                defer {
                    if Task.isCancelled {
                        diagnosticCollector?.finish(status: .cancelled)
                    }
                }
            #endif
            try Task.checkCancellation()
            try await ensureRootScopeAvailable(rootScope, store: store)
            let readinessTicket = try await acquireSearchReadiness(
                store: store,
                workspaceManager: workspaceManager
            )
            try await ensureRootScopeAvailable(
                rootScope,
                store: store,
                readinessTicket: readinessTicket,
                workspaceManager: workspaceManager
            )
            try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)

            let effectiveMode = mode == .auto ? FileSearchActor.inferredAutoMode(pattern) : mode
            let admissionClass = broadSearchAdmissionClass(pattern: pattern, mode: mode, paths: paths)
            return try await store.withStoreBackedSearchAccess(
                searchMode: effectiveMode,
                admissionClass: admissionClass
            ) { fileSearchActor in
                if admissionClass != nil {
                    try await ensureRootScopeAvailable(
                        rootScope,
                        store: store,
                        readinessTicket: readinessTicket,
                        workspaceManager: workspaceManager
                    )
                }
                try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)

                var parsedSearchScope: SearchScopeParseResult? = if let rawPaths = paths, !rawPaths.isEmpty {
                    await parseSearchScopePaths(
                        rawPaths,
                        caseInsensitive: caseInsensitive,
                        rootScope: rootScope,
                        store: store
                    )
                } else {
                    nil
                }
                try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
                let freshnessRootRefs: [WorkspaceRootRef] = if let parsedSearchScope {
                    parsedSearchScope.freshnessRootRefs
                } else {
                    await store.rootRefs(scope: rootScope)
                }
                try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
                #if DEBUG
                    let freshnessWaitTimeout = freshnessWaitTimeoutOverrideForTesting
                        ?? MCPTimeoutPolicy.workspaceFreshnessWaitTimeout
                #else
                    let freshnessWaitTimeout = MCPTimeoutPolicy.workspaceFreshnessWaitTimeout
                #endif
                let ingressFreshnessState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.ingressFreshnessWait)
                let appliedIngressSamples: [WorkspaceIngressBarrierSample]
                do {
                    appliedIngressSamples = try await awaitAppliedIngress(
                        rootRefs: freshnessRootRefs,
                        store: store,
                        timeout: freshnessWaitTimeout
                    )
                    try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
                } catch {
                    EditFlowPerf.end(EditFlowPerf.Stage.Search.ingressFreshnessWait, ingressFreshnessState)
                    throw error
                }
                EditFlowPerf.end(EditFlowPerf.Stage.Search.ingressFreshnessWait, ingressFreshnessState)
                try Task.checkCancellation()
                let contentFreshnessPolicy = await store.contentSearchFreshnessPolicy(
                    rootRefs: freshnessRootRefs,
                    appliedIngressSamples: appliedIngressSamples
                )
                try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
                try Task.checkCancellation()
                if let parsed = parsedSearchScope {
                    // Exact paths can change kind or disappear while the freshness barrier applies
                    // pending ingress. Refresh only their root-local catalog records; wildcard,
                    // unresolved, and ambiguous clauses retain their initial conservative semantics.
                    parsedSearchScope = await refreshExactSearchScopeClauses(
                        parsed,
                        store: store
                    )
                    try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
                }
                try Task.checkCancellation()
                #if DEBUG
                    let diagnosticPreambleEnd = WorkspaceFileSearchDebugTiming.now()
                    diagnosticCollector?.recordReadinessFreshnessPreamble(
                        nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: diagnosticSearchStart,
                            through: diagnosticPreambleEnd
                        )
                    )
                #endif

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
                    freshnessQualifiedRootIDs: Set(freshnessRootRefs.map(\.id)),
                    parsedSearchScope: parsedSearchScope,
                    rootScope: rootScope,
                    store: store,
                    fileSearchActor: fileSearchActor,
                    workspaceManager: workspaceManager,
                    readinessTicket: readinessTicket
                )
            }
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
        freshnessQualifiedRootIDs: Set<UUID>,
        parsedSearchScope: SearchScopeParseResult?,
        rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore,
        fileSearchActor: FileSearchActor,
        workspaceManager: WorkspaceManagerViewModel?,
        readinessTicket: WorkspaceSearchReadinessTicket?
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

        try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
        #if DEBUG
            let diagnosticCatalogStart = WorkspaceFileSearchDebugTiming.now()
        #endif
        let catalogRequirement: WorkspaceSearchCatalogAccessRequirement = switch mode {
        case .path:
            .recordsOnly
        case .auto, .content, .both:
            .recordsAndPathIndexes
        }
        let catalogAccess = await store.searchCatalogAccess(
            rootScope: rootScope,
            requirement: catalogRequirement
        )
        #if DEBUG
            let diagnosticCatalogEnd = WorkspaceFileSearchDebugTiming.now()
            WorkspaceFileSearchDebugContext.collector?.recordFirstCatalogAccess(
                nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                    since: diagnosticCatalogStart,
                    through: diagnosticCatalogEnd
                )
            )
        #endif
        try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
        let snapshot: WorkspaceSearchCatalogSnapshot
        switch catalogAccess {
        case let .available(availableSnapshot):
            snapshot = availableSnapshot
        case let .unavailable(availability):
            entryPerfStatus = "error"
            throw searchError(for: availability)
        }

        let rootsByID = Dictionary(uniqueKeysWithValues: snapshot.roots.map { ($0.id, $0) })
        let visibleRootRefs = await store.rootRefs(scope: .visibleWorkspace)
        try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
        let visibleRootIDs = Set(visibleRootRefs.map(\.id))
        let visibleRootRecords = snapshot.roots.filter { visibleRootIDs.contains($0.id) }
        let allFiles = snapshot.files
        let scopePerfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.scopeFiltering,
            EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: allFiles.count)
        )

        let filesToSearch: [WorkspaceFileRecord]
        if let rawPaths = paths, !rawPaths.isEmpty {
            guard let parsed = parsedSearchScope else {
                preconditionFailure("Explicit search paths must be parsed before freshness")
            }
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
            try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
            filesToSearch = filterResult.matchedSnapshotIndices.map { allFiles[$0] }
        } else {
            filesToSearch = allFiles
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.scopeFiltering,
            scopePerfState,
            EditFlowPerf.Dimensions(status: (paths?.isEmpty == false) ? "explicit" : "all", fileCount: filesToSearch.count)
        )

        let allSearchedFilesAreFreshnessQualified = filesToSearch.allSatisfy {
            freshnessQualifiedRootIDs.contains($0.rootID)
        }
        let freshnessAllowsCachedMetadata = if case .cachedMetadata = contentFreshnessPolicy {
            true
        } else {
            false
        }
        let effectiveContentFreshnessPolicy: FileContentFreshnessPolicy = if effectiveMode == .content
            || effectiveMode == .both
        {
            freshnessAllowsCachedMetadata && allSearchedFilesAreFreshnessQualified
                ? .cachedMetadata
                : .validateDiskMetadata
        } else {
            .cachedMetadata
        }
        let aliasByRootPath = pathSearchAliasByRootPath(roots: visibleRootRecords)
        var wasAutoCorrected: Bool? = nil
        var results: SearchResults
        #if DEBUG
            var diagnosticActorStart: UInt64?
        #endif
        do {
            try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
            #if DEBUG
                WorkspaceFileSearchDebugContext.collector?.setRequestedPathLimit(max(0, maxPaths))
                diagnosticActorStart = WorkspaceFileSearchDebugTiming.now()
            #endif
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
            #if DEBUG
                if let diagnosticActorStart {
                    let diagnosticActorEnd = WorkspaceFileSearchDebugTiming.now()
                    WorkspaceFileSearchDebugContext.collector?.recordFileSearchActor(
                        nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: diagnosticActorStart,
                            through: diagnosticActorEnd
                        )
                    )
                }
            #endif
            try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
        } catch {
            #if DEBUG
                if let diagnosticActorStart {
                    let diagnosticActorEnd = WorkspaceFileSearchDebugTiming.now()
                    WorkspaceFileSearchDebugContext.collector?.recordFileSearchActor(
                        nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: diagnosticActorStart,
                            through: diagnosticActorEnd
                        )
                    )
                }
            #endif
            entryPerfStatus = "error"
            throw error
        }
        results.scopedFileCount = filesToSearch.count
        if wasAutoCorrected == true {
            results.warningMessage = searchAutoCorrectionWarning(isRegex: isRegex)
        }
        #if DEBUG
            WorkspaceFileSearchDebugContext.collector?.finish(status: .completed)
        #endif
        return results
    }

    private static func ensureRootScopeAvailable(
        _ rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore,
        readinessTicket: WorkspaceSearchReadinessTicket? = nil,
        workspaceManager: WorkspaceManagerViewModel? = nil
    ) async throws {
        let perfState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.rootScopeAvailabilityGate)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Search.rootScopeAvailabilityGate, perfState) }
        let availability = await store.rootScopeAvailability(rootScope)
        try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
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

    private static func acquireSearchReadiness(
        store: WorkspaceFileContextStore,
        workspaceManager: WorkspaceManagerViewModel?
    ) async throws -> WorkspaceSearchReadinessTicket? {
        let perfState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.workspaceReadinessAcquireGate)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Search.workspaceReadinessAcquireGate, perfState) }
        guard let workspaceManager else {
            try await ensureVisibleWorkspaceLoaded(
                store: store,
                readinessTicket: nil,
                workspaceManager: nil
            )
            return nil
        }
        #if DEBUG
            let timeout = readinessWaitTimeoutOverrideForTesting
                ?? MCPTimeoutPolicy.workspaceReadinessWaitTimeout
        #else
            let timeout = MCPTimeoutPolicy.workspaceReadinessWaitTimeout
        #endif
        let ticket: WorkspaceSearchReadinessTicket
        do {
            ticket = try await workspaceManager.awaitWorkspaceSearchReadiness(timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceSearchReadinessWaitError {
            throw searchError(for: error)
        }
        try await validateSearchReadiness(ticket, workspaceManager: workspaceManager)
        try await ensureVisibleWorkspaceLoaded(
            store: store,
            readinessTicket: ticket,
            workspaceManager: workspaceManager
        )
        try await validateSearchReadiness(ticket, workspaceManager: workspaceManager)
        return ticket
    }

    private static func ensureVisibleWorkspaceLoaded(
        store: WorkspaceFileContextStore,
        readinessTicket: WorkspaceSearchReadinessTicket?,
        workspaceManager: WorkspaceManagerViewModel?
    ) async throws {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        try await validateSearchReadiness(readinessTicket, workspaceManager: workspaceManager)
        guard !roots.isEmpty else {
            let msg = "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
            throw FileManagerError.fileSystemServiceNotFoundWithContext(msg)
        }
    }

    private static func validateSearchReadiness(
        _ ticket: WorkspaceSearchReadinessTicket?,
        workspaceManager: WorkspaceManagerViewModel?
    ) async throws {
        guard let ticket else { return }
        let perfState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.workspaceReadinessValidationGate)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Search.workspaceReadinessValidationGate, perfState) }
        guard let workspaceManager else {
            preconditionFailure("A workspace readiness ticket requires its issuing manager")
        }
        do {
            try workspaceManager.validateWorkspaceSearchReadinessSnapshot(ticket)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceSearchReadinessWaitError {
            throw searchError(for: error)
        }
    }

    private static func searchError(
        for error: WorkspaceSearchReadinessWaitError
    ) -> StoreBackedWorkspaceSearchError {
        switch error {
        case .unavailable:
            .workspaceReadinessUnavailable
        case .timedOut:
            .workspaceReadinessTimedOut
        case .superseded:
            .workspaceReadinessSuperseded
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
        let freshnessRootRefs: [WorkspaceRootRef]
        let exactClauses: [ExactSearchScopeClause]
    }

    private struct ExactSearchScopeClause {
        let clauseIndex: Int
        let rootID: UUID
        let relativePath: String
        var missingClauses: [SearchPathClause]
    }

    private enum PendingSearchScopeEntry {
        case wildcard(normalizedPath: String)
        case issue(PathResolutionIssue)
        case resolved(normalizedPath: String, lookup: WorkspacePathLookupResult)
        case lookup(normalizedPath: String)
    }

    private static func parseSearchScopePaths(
        _ rawPaths: [String],
        caseInsensitive: Bool,
        rootScope: WorkspaceLookupRootScope,
        store: WorkspaceFileContextStore
    ) async -> SearchScopeParseResult {
        var clauses: [SearchPathClause] = []
        var issues: [PathResolutionIssue] = []
        var exactClauses: [ExactSearchScopeClause] = []
        var clauseIndicesByKey: [String: Int] = [:]
        var exactClauseIndicesByClauseIndex: [Int: Int] = [:]
        let scopedRoots = await store.rootRefs(scope: rootScope)
        var freshnessRootPaths = Set<String>()
        var requiresFullFreshnessScope = false

        @discardableResult
        func appendClause(_ clause: SearchPathClause) -> Int {
            let key = String(describing: clause)
            if let existingIndex = clauseIndicesByKey[key] {
                return existingIndex
            }
            let clauseIndex = clauses.count
            clauseIndicesByKey[key] = clauseIndex
            clauses.append(clause)

            switch clause {
            case let .exactFile(_, _, restrictedRootPath),
                 let .exactFolder(_, _, restrictedRootPath),
                 let .glob(_, restrictedRootPath):
                if let restrictedRootPath {
                    freshnessRootPaths.insert(restrictedRootPath)
                } else {
                    requiresFullFreshnessScope = true
                }
            case let .legacyPrefix(candidateLower):
                if candidateLower.hasPrefix("/") {
                    if let root = scopedRoots
                        .filter({ StandardizedPath.isDescendant(candidateLower, of: $0.standardizedFullPath.lowercased()) })
                        .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
                    {
                        freshnessRootPaths.insert(root.standardizedFullPath)
                    }
                } else {
                    requiresFullFreshnessScope = true
                }
            }
            return clauseIndex
        }

        func appendIssue(_ issue: PathResolutionIssue) {
            issues.append(issue)
            requiresFullFreshnessScope = true
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
                    appendIssue(.ambiguousAlias(alias: alias, matchingRoots: matches))
                    return
                }
            }

            appendClause(.glob(pattern: normalized, restrictedRootPath: nil))
        }

        func appendLookup(_ lookup: WorkspacePathLookupResult, normalizedPath: String) {
            let root = scopedRoots.first { $0.id == lookup.location.rootID }
            let clause: SearchPathClause
            if let file = lookup.file {
                clause = .exactFile(
                    absPath: file.standardizedFullPath,
                    relPath: file.standardizedRelativePath,
                    restrictedRootPath: root?.standardizedFullPath
                )
            } else if let folder = lookup.folder {
                clause = .exactFolder(
                    absLower: folder.standardizedFullPath.lowercased(),
                    relLower: folder.standardizedRelativePath.lowercased(),
                    restrictedRootPath: root?.standardizedFullPath
                )
            } else {
                return
            }
            let clauseIndex = appendClause(clause)
            let missingClause = SearchPathClause.legacyPrefix(candidateLower: normalizedPath.lowercased())
            if let exactClauseIndex = exactClauseIndicesByClauseIndex[clauseIndex] {
                guard !exactClauses[exactClauseIndex].missingClauses.contains(missingClause) else { return }
                exactClauses[exactClauseIndex].missingClauses.append(missingClause)
            } else {
                exactClauseIndicesByClauseIndex[clauseIndex] = exactClauses.count
                exactClauses.append(ExactSearchScopeClause(
                    clauseIndex: clauseIndex,
                    rootID: lookup.location.rootID,
                    relativePath: lookup.location.correctedPath,
                    missingClauses: [missingClause]
                ))
            }
        }

        var pendingEntries: [PendingSearchScopeEntry] = []
        var lookupRequests: [WorkspacePathLookupRequest] = []
        for raw in rawPaths {
            let normalized = normalizeUserInputPath(raw)
            guard !normalized.isEmpty else { continue }
            let hasWildcard = normalized.contains("*") || normalized.contains("?") || normalized.contains("[")
            if hasWildcard {
                pendingEntries.append(.wildcard(normalizedPath: normalized))
                continue
            }

            if let issue = await store.exactPathResolutionIssue(for: normalized, kind: .either, rootScope: rootScope) {
                pendingEntries.append(.issue(issue))
                continue
            }
            if let lookup = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
                normalized,
                rootScope: rootScope
            ) {
                pendingEntries.append(.resolved(normalizedPath: normalized, lookup: lookup))
                continue
            }
            pendingEntries.append(.lookup(normalizedPath: normalized))
            lookupRequests.append(WorkspacePathLookupRequest(
                userPath: normalized,
                profile: .mcpSearchScope,
                rootScope: rootScope
            ))
        }

        let lookupResults = await store.lookupPaths(lookupRequests)
        for entry in pendingEntries {
            switch entry {
            case let .wildcard(normalizedPath):
                appendWildcardClause(for: normalizedPath)
            case let .issue(issue):
                appendIssue(issue)
            case let .resolved(normalizedPath, lookup):
                appendLookup(lookup, normalizedPath: normalizedPath)
            case let .lookup(normalizedPath):
                if let lookup = lookupResults[normalizedPath] {
                    appendLookup(lookup, normalizedPath: normalizedPath)
                } else {
                    appendClause(.legacyPrefix(candidateLower: normalizedPath.lowercased()))
                }
            }
        }

        let freshnessRootRefs = if requiresFullFreshnessScope || clauses.isEmpty {
            scopedRoots
        } else {
            scopedRoots.filter { freshnessRootPaths.contains($0.standardizedFullPath) }
        }
        return SearchScopeParseResult(
            spec: SearchPathFilterSpec(caseInsensitive: caseInsensitive, clauses: clauses),
            issues: issues,
            freshnessRootRefs: freshnessRootRefs,
            exactClauses: exactClauses
        )
    }

    private static func refreshExactSearchScopeClauses(
        _ parsed: SearchScopeParseResult,
        store: WorkspaceFileContextStore
    ) async -> SearchScopeParseResult {
        guard !parsed.exactClauses.isEmpty else { return parsed }
        var clauses = parsed.spec.clauses
        var disappearedExactClauses: [ExactSearchScopeClause] = []

        for exactClause in parsed.exactClauses {
            guard let lookup = await store.lookupDiscoverablePath(
                rootID: exactClause.rootID,
                relativePath: exactClause.relativePath
            ) else {
                disappearedExactClauses.append(exactClause)
                continue
            }
            let restrictedRootPath = lookup.location.rootPath
            if let file = lookup.file {
                clauses[exactClause.clauseIndex] = .exactFile(
                    absPath: file.standardizedFullPath,
                    relPath: file.standardizedRelativePath,
                    restrictedRootPath: restrictedRootPath
                )
            } else if let folder = lookup.folder {
                clauses[exactClause.clauseIndex] = .exactFolder(
                    absLower: folder.standardizedFullPath.lowercased(),
                    relLower: folder.standardizedRelativePath.lowercased(),
                    restrictedRootPath: restrictedRootPath
                )
            } else {
                disappearedExactClauses.append(exactClause)
            }
        }

        if !disappearedExactClauses.isEmpty {
            let fallbacksByClauseIndex = Dictionary(
                uniqueKeysWithValues: disappearedExactClauses.map { ($0.clauseIndex, $0.missingClauses) }
            )
            var refreshedClauses: [SearchPathClause] = []
            refreshedClauses.reserveCapacity(
                clauses.count + disappearedExactClauses.reduce(0) { $0 + max(0, $1.missingClauses.count - 1) }
            )
            var seenClauseKeys = Set<String>()
            for (clauseIndex, clause) in clauses.enumerated() {
                let candidates = fallbacksByClauseIndex[clauseIndex] ?? [clause]
                for candidate in candidates
                    where seenClauseKeys.insert(String(describing: candidate)).inserted
                {
                    refreshedClauses.append(candidate)
                }
            }
            clauses = refreshedClauses
        }

        return SearchScopeParseResult(
            spec: SearchPathFilterSpec(caseInsensitive: parsed.spec.caseInsensitive, clauses: clauses),
            issues: parsed.issues,
            freshnessRootRefs: parsed.freshnessRootRefs,
            exactClauses: []
        )
    }

    private static func awaitAppliedIngress(
        rootRefs: [WorkspaceRootRef],
        store: WorkspaceFileContextStore,
        timeout: Duration
    ) async throws -> [WorkspaceIngressBarrierSample] {
        let race = AppliedIngressWaitRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation: continuation)
                let freshnessTask = Task {
                    let samples: [WorkspaceIngressBarrierSample]
                    #if DEBUG
                        if let override = freshnessWaitOperationOverrideForTesting {
                            samples = await override(rootRefs, store)
                        } else {
                            samples = await store.awaitAppliedIngress(rootRefs: rootRefs)
                        }
                    #else
                        samples = await store.awaitAppliedIngress(rootRefs: rootRefs)
                    #endif
                    race.resolve(.success(samples))
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    race.resolve(.failure(StoreBackedWorkspaceSearchError.workspaceFreshnessTimedOut))
                }
                race.install(freshnessTask: freshnessTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }

    private final class AppliedIngressWaitRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[WorkspaceIngressBarrierSample], Error>?
        private var pendingResult: Result<[WorkspaceIngressBarrierSample], Error>?
        private var freshnessTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var isResolved = false

        func install(continuation: CheckedContinuation<[WorkspaceIngressBarrierSample], Error>) {
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func install(
            freshnessTask: Task<Void, Never>,
            timeoutTask: Task<Void, Never>
        ) {
            lock.lock()
            if isResolved {
                lock.unlock()
                freshnessTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.freshnessTask = freshnessTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func resolve(_ result: Result<[WorkspaceIngressBarrierSample], Error>) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            let continuation = continuation
            self.continuation = nil
            if continuation == nil {
                pendingResult = result
            }
            let freshnessTask = freshnessTask
            let timeoutTask = timeoutTask
            self.freshnessTask = nil
            self.timeoutTask = nil
            lock.unlock()

            freshnessTask?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }
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
