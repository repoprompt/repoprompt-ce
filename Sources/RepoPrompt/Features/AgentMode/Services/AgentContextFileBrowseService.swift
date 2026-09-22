import Foundation
import OSLog

struct AgentContextFileBrowseRoot: Equatable, Hashable {
    let id: UUID
    let physicalPath: String
    let displayName: String
    let scopeLabel: String
}

struct AgentContextFileBrowseFolder: Equatable, Hashable {
    let id: UUID
    let rootID: UUID
    let parentFolderID: UUID?
    let name: String
    let standardizedRelativePath: String
    let standardizedFullPath: String
    let modificationDate: Date?
}

struct AgentContextFileBrowseFile: Equatable, Hashable {
    let id: UUID
    let rootID: UUID
    let rootGeneration: UInt64
    let parentFolderID: UUID?
    let name: String
    let standardizedRelativePath: String
    let standardizedFullPath: String
    let projectedDisplayPath: String
    let projectedDirectoryPath: String
    let modificationDate: Date?
    let supportsCodemap: Bool
}

enum AgentContextFileBrowseNodeID: Equatable, Hashable {
    case root(UUID)
    case folder(UUID)
    case file(UUID)
    case searchRootHeader(UUID)
    case searchDirectoryHeader(rootID: UUID, directoryPath: String)
}

enum AgentContextFileBrowseAddMode: Equatable, Hashable {
    case full
    case codemapOnly
}

enum AgentContextFileBrowseHeldMode: Equatable, Hashable {
    case full
    case slice
    case codemap
}

enum AgentContextFileBrowseContainerMembership: Equatable, Hashable {
    case none
    case mixed
    case all
}

enum AgentContextFileBrowseTokenEstimate: Equatable, Hashable {
    case notRequested
    case loading
    case known(Int)
    case unavailable
}

enum AgentContextFileBrowseRootScope: Equatable, Hashable {
    case allRoots
    case root(UUID)
}

struct AgentContextFileBrowseRootsSnapshot: Equatable {
    let catalogGeneration: UInt64
    let roots: [AgentContextFileBrowseRoot]
}

enum AgentContextFileBrowseRootsResult: Equatable {
    case available(AgentContextFileBrowseRootsSnapshot)
    case unavailable(missingPhysicalRootPaths: [String])
}

enum AgentContextFileBrowseSessionScopedResult<Value> {
    case available(Value)
    case missing(catalogGeneration: UInt64)
    case sessionRootsUnavailable
}

extension AgentContextFileBrowseSessionScopedResult: Equatable where Value: Equatable {}

struct AgentContextFileBrowseHierarchy: Equatable {
    let catalogGeneration: UInt64
    let rootGeneration: UInt64
    let folders: [AgentContextFileBrowseFolder]
    let files: [AgentContextFileBrowseFile]
    let descendantFiles: [AgentContextFileBrowseFile]
}

struct AgentContextFileBrowseSearchMatch: Equatable {
    let file: AgentContextFileBrowseFile
    let score: Int32
}

struct AgentContextFileBrowseSearchDirectoryGroup: Equatable {
    let id: AgentContextFileBrowseNodeID
    let directoryPath: String
    let matches: [AgentContextFileBrowseSearchMatch]
}

struct AgentContextFileBrowseSearchRootGroup: Equatable {
    let id: AgentContextFileBrowseNodeID
    let root: AgentContextFileBrowseRoot
    let matchCount: Int
    let rootMatches: [AgentContextFileBrowseSearchMatch]
    let directories: [AgentContextFileBrowseSearchDirectoryGroup]
}

enum AgentContextFileBrowseSearchSource: Equatable {
    case indexedVisibleWorkspace
    case storeCatalog
}

struct AgentContextFileBrowseSearchResult: Equatable {
    let catalogGeneration: UInt64
    let source: AgentContextFileBrowseSearchSource
    let groups: [AgentContextFileBrowseSearchRootGroup]

    var matches: [AgentContextFileBrowseSearchMatch] {
        groups.flatMap { $0.rootMatches + $0.directories.flatMap(\.matches) }
    }
}

struct AgentContextFileBrowseRevalidationResult: Equatable {
    let catalogGeneration: UInt64
    let files: [AgentContextFileBrowseFile]
    let rejectedCount: Int
}

actor AgentContextFileBrowseService {
    typealias IndexedSearch = @Sendable (String, Int) async -> WorkspaceSearchQueryResult

    private struct RootTreeIndex {
        let root: WorkspaceRootRecord
        let generation: UInt64
        let rootFolderID: UUID
        let foldersByID: [UUID: WorkspaceFolderRecord]
        let directFoldersByParentID: [UUID: [WorkspaceFolderRecord]]
        let directFilesByParentID: [UUID: [WorkspaceFileRecord]]
        let orderedFiles: [WorkspaceFileRecord]
        var descendantsByFolderID: [UUID: [WorkspaceFileRecord]] = [:]
    }

    private struct SearchIndexKey: Hashable {
        let rootScope: WorkspaceLookupRootScope
        let catalogGeneration: UInt64
        let projectionIdentity: String
        let selectedRootID: UUID?
    }

    private struct StoreSearchIndex {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex
    }

    private struct RevalidatedRecord {
        let record: WorkspaceFileRecord
        let rootGeneration: UInt64
    }

    private struct RankedRecord {
        let record: WorkspaceFileRecord
        let file: AgentContextFileBrowseFile
        let score: Int32
    }

    private static let excludedPathComponent = "_git_data"
    private static let fuzzyThreshold = 0.85
    private static let indexCandidateMultiplier = 8
    private static let minimumIndexCandidateLimit = 64
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ContextFileBrowse")

    private let store: WorkspaceFileContextStore
    private let indexedSearch: IndexedSearch?
    private var treeIndexesByRootID: [UUID: RootTreeIndex] = [:]
    private var searchIndexesByKey: [SearchIndexKey: StoreSearchIndex] = [:]

    init(store: WorkspaceFileContextStore, searchService: WorkspaceSearchService?) {
        self.store = store
        if let searchService {
            indexedSearch = { @Sendable query, limit in
                await searchService.search(query, limit: limit)
            }
        } else {
            indexedSearch = nil
        }
    }

    init(store: WorkspaceFileContextStore, indexedSearch: IndexedSearch? = nil) {
        self.store = store
        self.indexedSearch = indexedSearch
    }

    func pruneCaches(
        retainingRootIDs: Set<UUID>,
        lookupContext: WorkspaceLookupContext
    ) {
        treeIndexesByRootID = treeIndexesByRootID.filter { retainingRootIDs.contains($0.key) }
        let projectionIdentity = Self.projectionIdentity(lookupContext.bindingProjection)
        searchIndexesByKey = searchIndexesByKey.filter { key, _ in
            key.rootScope == lookupContext.rootScope
                && key.projectionIdentity == projectionIdentity
                && key.selectedRootID.map(retainingRootIDs.contains) != false
        }
    }

    func roots(lookupContext: WorkspaceLookupContext) async -> AgentContextFileBrowseRootsResult {
        guard lookupContext.bindingProjection?.isFullyMaterialized != false else {
            return .unavailable(missingPhysicalRootPaths: [])
        }
        let validation = await store.readFileAutoSelectionCatalogValidationSnapshot(
            rootScope: lookupContext.rootScope
        )
        guard case .available = validation.rootScopeAvailability else {
            if case let .sessionWorktreeUnavailable(missingPhysicalRootPaths) = validation.rootScopeAvailability {
                Self.logger.notice("Context file browse roots unavailable for the current session scope")
                return .unavailable(missingPhysicalRootPaths: missingPhysicalRootPaths)
            }
            preconditionFailure("Workspace root-scope availability gained an unhandled case")
        }

        let physicalRoots = await store.rootRefs(scope: lookupContext.rootScope)
            .filter { !Self.isGitDataRoot($0) }
        let displayRoots = projectedDisplayRoots(from: physicalRoots, lookupContext: lookupContext)
        return .available(AgentContextFileBrowseRootsSnapshot(
            catalogGeneration: validation.rootScopeCatalogGeneration,
            roots: displayRoots
        ))
    }

    func hierarchy(
        rootID: UUID,
        folderID: UUID?,
        lookupContext: WorkspaceLookupContext
    ) async throws -> AgentContextFileBrowseSessionScopedResult<AgentContextFileBrowseHierarchy> {
        try Task.checkCancellation()
        guard case let .available(physicalRoots) = await allowedPhysicalRoots(lookupContext: lookupContext) else {
            return .sessionRootsUnavailable
        }
        guard var index = await currentTreeIndex(rootID: rootID, allowedRoots: physicalRoots) else {
            guard case let .available(catalogGeneration) = await currentCatalogGeneration(lookupContext: lookupContext) else {
                return .sessionRootsUnavailable
            }
            return .missing(catalogGeneration: catalogGeneration)
        }
        let parentID = folderID ?? index.rootFolderID
        let descendantRecords: [WorkspaceFileRecord]
        if let folderID {
            guard index.foldersByID[folderID] != nil else {
                guard case let .available(catalogGeneration) = await currentCatalogGeneration(lookupContext: lookupContext) else {
                    return .sessionRootsUnavailable
                }
                return .missing(catalogGeneration: catalogGeneration)
            }
            if let cached = index.descendantsByFolderID[folderID] {
                descendantRecords = cached
            } else {
                descendantRecords = Self.resolveDescendants(folderID: folderID, index: index)
                index.descendantsByFolderID[folderID] = descendantRecords
                treeIndexesByRootID[rootID] = index
            }
        } else {
            descendantRecords = index.orderedFiles
        }
        let makeBrowseFile = { record in
            self.makeFile(
                record: record,
                rootGeneration: index.generation,
                physicalRoots: physicalRoots,
                lookupContext: lookupContext
            )
        }
        let folders = (index.directFoldersByParentID[parentID] ?? []).map(Self.makeFolder)
        let files = (index.directFilesByParentID[parentID] ?? []).compactMap(makeBrowseFile)
        let descendantFiles = descendantRecords.compactMap(makeBrowseFile)
        try Task.checkCancellation()
        guard case let .available(catalogGeneration) = await currentCatalogGeneration(lookupContext: lookupContext) else {
            return .sessionRootsUnavailable
        }
        return .available(AgentContextFileBrowseHierarchy(
            catalogGeneration: catalogGeneration,
            rootGeneration: index.generation,
            folders: folders,
            files: files,
            descendantFiles: descendantFiles
        ))
    }

    func search(
        query rawQuery: String,
        scope: AgentContextFileBrowseRootScope,
        lookupContext: WorkspaceLookupContext,
        limit: Int = 300
    ) async throws -> AgentContextFileBrowseSessionScopedResult<AgentContextFileBrowseSearchResult> {
        guard lookupContext.bindingProjection?.isFullyMaterialized != false else {
            return .sessionRootsUnavailable
        }
        let query = RepoSearchQueryFactory.make(rawQuery, supportsWildcards: false)
        let boundedLimit = max(0, limit)
        guard !query.isEmpty, boundedLimit > 0 else {
            let validation = await store.readFileAutoSelectionCatalogValidationSnapshot(rootScope: lookupContext.rootScope)
            guard case .available = validation.rootScopeAvailability else {
                return .sessionRootsUnavailable
            }
            return .available(AgentContextFileBrowseSearchResult(
                catalogGeneration: validation.rootScopeCatalogGeneration,
                source: .storeCatalog,
                groups: []
            ))
        }
        try Task.checkCancellation()

        let rootsResult = await roots(lookupContext: lookupContext)
        guard case let .available(rootSnapshot) = rootsResult else {
            return .sessionRootsUnavailable
        }
        let allowedRoots = rootsForScope(scope, in: rootSnapshot.roots)
        let allowedRootIDs = Set(allowedRoots.map(\.id))
        guard !allowedRootIDs.isEmpty else {
            return .available(AgentContextFileBrowseSearchResult(
                catalogGeneration: rootSnapshot.catalogGeneration,
                source: .storeCatalog,
                groups: []
            ))
        }

        let candidateLimit = max(boundedLimit * Self.indexCandidateMultiplier, Self.minimumIndexCandidateLimit)
        let candidates: [WorkspaceSearchCatalogEntry]
        let source: AgentContextFileBrowseSearchSource
        if indexedSearchIsAdmissible(scope: scope, lookupContext: lookupContext), let indexedSearch {
            let result = await indexedSearch(query.raw, candidateLimit)
            if result.isIndexReady, !result.isStale {
                candidates = Array(result.results.lazy.filter {
                    allowedRootIDs.contains($0.rootID) && !Self.isGitDataPath($0.standardizedRelativePath)
                }.prefix(candidateLimit))
                source = .indexedVisibleWorkspace
            } else {
                Self.logger.debug("Visible workspace search index unavailable or stale; using store catalog")
                candidates = try await storeBackedCandidates(
                    query: query.raw,
                    scope: scope,
                    lookupContext: lookupContext,
                    allowedRootIDs: allowedRootIDs,
                    limit: candidateLimit
                )
                source = .storeCatalog
            }
        } else {
            candidates = try await storeBackedCandidates(
                query: query.raw,
                scope: scope,
                lookupContext: lookupContext,
                allowedRootIDs: allowedRootIDs,
                limit: candidateLimit
            )
            source = .storeCatalog
        }

        try Task.checkCancellation()
        let records = await revalidatedRecords(for: candidates, allowedRootIDs: allowedRootIDs)
        try Task.checkCancellation()
        let physicalRoots = allowedRoots.map(Self.makePhysicalRootRef)
        var ranked = score(
            records: records,
            query: query,
            physicalRoots: physicalRoots,
            lookupContext: lookupContext
        )
        if ranked.count > boundedLimit {
            ranked.removeSubrange(boundedLimit...)
        }
        guard case let .available(catalogGeneration) = await currentCatalogGeneration(lookupContext: lookupContext) else {
            return .sessionRootsUnavailable
        }
        return .available(AgentContextFileBrowseSearchResult(
            catalogGeneration: catalogGeneration,
            source: source,
            groups: group(ranked: ranked, roots: allowedRoots)
        ))
    }

    func revalidate(
        files: [AgentContextFileBrowseFile],
        lookupContext: WorkspaceLookupContext
    ) async throws -> AgentContextFileBrowseSessionScopedResult<AgentContextFileBrowseRevalidationResult> {
        try Task.checkCancellation()
        guard case let .available(roots) = await allowedPhysicalRoots(lookupContext: lookupContext) else {
            return .sessionRootsUnavailable
        }
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let requestedByRoot = Dictionary(grouping: files.filter { rootsByID[$0.rootID] != nil }, by: \.rootID)
        var validByID: [UUID: RevalidatedRecord] = [:]
        validByID.reserveCapacity(files.count)

        for (rootID, candidates) in requestedByRoot {
            try Task.checkCancellation()
            guard let lookup = await store.appliedIndexRecordLookup(
                rootID: rootID,
                fileIDs: candidates.map(\.id),
                folderIDs: []
            ), lookup.root.standardizedFullPath == rootsByID[rootID]?.standardizedFullPath else {
                continue
            }
            for candidate in candidates {
                guard let record = lookup.filesByID[candidate.id],
                      record.standardizedFullPath == candidate.standardizedFullPath
                else { continue }
                validByID[candidate.id] = RevalidatedRecord(record: record, rootGeneration: lookup.generation)
            }
        }

        try Task.checkCancellation()
        var seenIDs = Set<UUID>()
        let validFiles = files.compactMap { candidate -> AgentContextFileBrowseFile? in
            guard seenIDs.insert(candidate.id).inserted,
                  let revalidated = validByID[candidate.id]
            else { return nil }
            return makeFile(
                record: revalidated.record,
                rootGeneration: revalidated.rootGeneration,
                physicalRoots: roots,
                lookupContext: lookupContext
            )
        }
        guard case let .available(catalogGeneration) = await currentCatalogGeneration(lookupContext: lookupContext) else {
            return .sessionRootsUnavailable
        }
        return .available(AgentContextFileBrowseRevalidationResult(
            catalogGeneration: catalogGeneration,
            files: validFiles,
            rejectedCount: files.count - validFiles.count
        ))
    }

    private func currentTreeIndex(
        rootID: UUID,
        allowedRoots: [WorkspaceRootRef]
    ) async -> RootTreeIndex? {
        guard let allowedRoot = allowedRoots.first(where: { $0.id == rootID }) else {
            treeIndexesByRootID.removeValue(forKey: rootID)
            return nil
        }

        if let cached = treeIndexesByRootID[rootID],
           let current = await store.appliedIndexRecordLookup(rootID: rootID, fileIDs: [], folderIDs: []),
           current.root.standardizedFullPath == allowedRoot.standardizedFullPath,
           current.generation == cached.generation,
           current.root.standardizedFullPath == cached.root.standardizedFullPath
        {
            return cached
        }

        guard let snapshot = await store.appliedIndexRootSnapshot(rootID: rootID),
              snapshot.root.standardizedFullPath == allowedRoot.standardizedFullPath,
              let rootFolder = snapshot.folders.first(where: { $0.standardizedRelativePath.isEmpty })
        else {
            treeIndexesByRootID.removeValue(forKey: rootID)
            return nil
        }
        let index = Self.makeTreeIndex(snapshot: snapshot, rootFolderID: rootFolder.id)
        treeIndexesByRootID[rootID] = index
        return index
    }

    private static func makeTreeIndex(
        snapshot: WorkspaceAppliedIndexRootSnapshot,
        rootFolderID: UUID
    ) -> RootTreeIndex {
        let folders = snapshot.folders.filter {
            $0.id == rootFolderID || !isGitDataPath($0.standardizedRelativePath)
        }
        let files = snapshot.files.filter { !isGitDataPath($0.standardizedRelativePath) }
        let foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let directFolders = Dictionary(grouping: folders.filter { $0.id != rootFolderID }) { folder in
            precondition(folder.parentFolderID != nil, "Indexed non-root folder must have a parent")
            return folder.parentFolderID!
        }.mapValues(sortFolders)
        let directFiles = Dictionary(grouping: files) { file in
            precondition(file.parentFolderID != nil, "Indexed file must have a parent folder")
            return file.parentFolderID!
        }.mapValues(sortFiles)
        return RootTreeIndex(
            root: snapshot.root,
            generation: snapshot.generation,
            rootFolderID: rootFolderID,
            foldersByID: foldersByID,
            directFoldersByParentID: directFolders,
            directFilesByParentID: directFiles,
            orderedFiles: sortFiles(files)
        )
    }

    private static func resolveDescendants(folderID: UUID, index: RootTreeIndex) -> [WorkspaceFileRecord] {
        var stack = [folderID]
        var seenFolders = Set<UUID>()
        var seenFiles = Set<UUID>()
        var files: [WorkspaceFileRecord] = []
        while let current = stack.popLast() {
            guard seenFolders.insert(current).inserted else { continue }
            for file in index.directFilesByParentID[current] ?? [] where seenFiles.insert(file.id).inserted {
                files.append(file)
            }
            let children = index.directFoldersByParentID[current] ?? []
            stack.append(contentsOf: children.reversed().map(\.id))
        }
        return sortFiles(files)
    }

    private func storeBackedCandidates(
        query: String,
        scope: AgentContextFileBrowseRootScope,
        lookupContext: WorkspaceLookupContext,
        allowedRootIDs: Set<UUID>,
        limit: Int
    ) async throws -> [WorkspaceSearchCatalogEntry] {
        let access = await store.searchCatalogAccess(
            rootScope: lookupContext.rootScope,
            requirement: .recordsOnly
        )
        guard case let .available(snapshot) = access else { return [] }
        try Task.checkCancellation()
        let selectedRootID: UUID? = if case let .root(rootID) = scope { rootID } else { nil }
        let key = SearchIndexKey(
            rootScope: lookupContext.rootScope,
            catalogGeneration: snapshot.generation,
            projectionIdentity: Self.projectionIdentity(lookupContext.bindingProjection),
            selectedRootID: selectedRootID
        )
        let cached: StoreSearchIndex
        if let existing = searchIndexesByKey[key] {
            cached = existing
        } else {
            let entries = snapshot.entries.filter {
                allowedRootIDs.contains($0.rootID) && !Self.isGitDataPath($0.standardizedRelativePath)
            }
            let haystacks = entries.map { searchHaystack(for: $0, lookupContext: lookupContext) }
            try Task.checkCancellation()
            let built = await StoreSearchIndex(entries: entries, index: PathSearchIndex.build(paths: haystacks))
            try Task.checkCancellation()
            searchIndexesByKey = searchIndexesByKey.filter {
                $0.key.rootScope != key.rootScope || $0.key.catalogGeneration == key.catalogGeneration
            }
            searchIndexesByKey[key] = built
            cached = built
        }
        let hits = await cached.index.search(query, limit: limit)
        try Task.checkCancellation()
        var seen = Set<UUID>()
        return hits.compactMap { hit in
            guard cached.entries.indices.contains(hit.index) else { return nil }
            let entry = cached.entries[hit.index]
            return seen.insert(entry.id).inserted ? entry : nil
        }
    }

    private func revalidatedRecords(
        for entries: [WorkspaceSearchCatalogEntry],
        allowedRootIDs: Set<UUID>
    ) async -> [RevalidatedRecord] {
        let requested = entries.filter { allowedRootIDs.contains($0.rootID) }
        let entriesByRoot = Dictionary(grouping: requested, by: \.rootID)
        var validByID: [UUID: RevalidatedRecord] = [:]
        for (rootID, rootEntries) in entriesByRoot {
            guard let lookup = await store.appliedIndexRecordLookup(
                rootID: rootID,
                fileIDs: rootEntries.map(\.id),
                folderIDs: []
            ) else { continue }
            for entry in rootEntries {
                guard let record = lookup.filesByID[entry.id],
                      record.standardizedFullPath == entry.standardizedFullPath,
                      !Self.isGitDataPath(record.standardizedRelativePath)
                else { continue }
                validByID[entry.id] = RevalidatedRecord(record: record, rootGeneration: lookup.generation)
            }
        }
        var seen = Set<UUID>()
        return requested.compactMap { entry in
            guard seen.insert(entry.id).inserted else { return nil }
            return validByID[entry.id]
        }
    }

    private func score(
        records: [RevalidatedRecord],
        query: RepoSearchQuery,
        physicalRoots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) -> [RankedRecord] {
        let projected = records.compactMap { revalidated -> (RevalidatedRecord, AgentContextFileBrowseFile)? in
            guard let file = makeFile(
                record: revalidated.record,
                rootGeneration: revalidated.rootGeneration,
                physicalRoots: physicalRoots,
                lookupContext: lookupContext
            ) else { return nil }
            return (revalidated, file)
        }
        let candidates = projected.map {
            RepoSearchBatchScorer.Candidate(
                name: $0.1.name,
                path: $0.1.projectedDisplayPath,
                nameLower: $0.1.name.lowercased(),
                pathLower: $0.1.projectedDisplayPath.lowercased()
            )
        }
        let scores = RepoSearchBatchScorer.scores(
            for: candidates,
            query: query,
            fuzzyThreshold: Self.fuzzyThreshold
        )
        var ranked: [RankedRecord] = []
        for index in projected.indices where scores[index] > 0 {
            ranked.append(RankedRecord(
                record: projected[index].0.record,
                file: projected[index].1,
                score: scores[index]
            ))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.file.projectedDisplayPath.count != rhs.file.projectedDisplayPath.count {
                return lhs.file.projectedDisplayPath.count < rhs.file.projectedDisplayPath.count
            }
            let lhsLower = lhs.file.projectedDisplayPath.lowercased()
            let rhsLower = rhs.file.projectedDisplayPath.lowercased()
            if lhsLower != rhsLower { return lhsLower < rhsLower }
            return lhs.record.standardizedFullPath < rhs.record.standardizedFullPath
        }
        return ranked
    }

    private func group(
        ranked: [RankedRecord],
        roots: [AgentContextFileBrowseRoot]
    ) -> [AgentContextFileBrowseSearchRootGroup] {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        var orderedRootIDs: [UUID] = []
        var matchesByRootID: [UUID: [AgentContextFileBrowseSearchMatch]] = [:]
        for item in ranked where rootsByID[item.file.rootID] != nil {
            if matchesByRootID[item.file.rootID] == nil { orderedRootIDs.append(item.file.rootID) }
            matchesByRootID[item.file.rootID, default: []].append(
                AgentContextFileBrowseSearchMatch(file: item.file, score: item.score)
            )
        }

        return orderedRootIDs.compactMap { rootID in
            guard let root = rootsByID[rootID], let matches = matchesByRootID[rootID] else { return nil }
            var rootMatches: [AgentContextFileBrowseSearchMatch] = []
            var orderedDirectories: [String] = []
            var directoryMatches: [String: [AgentContextFileBrowseSearchMatch]] = [:]
            for match in matches {
                if match.file.projectedDirectoryPath.isEmpty {
                    rootMatches.append(match)
                } else {
                    if directoryMatches[match.file.projectedDirectoryPath] == nil {
                        orderedDirectories.append(match.file.projectedDirectoryPath)
                    }
                    directoryMatches[match.file.projectedDirectoryPath, default: []].append(match)
                }
            }
            let directories = orderedDirectories.map { directory in
                AgentContextFileBrowseSearchDirectoryGroup(
                    id: .searchDirectoryHeader(rootID: rootID, directoryPath: directory),
                    directoryPath: directory,
                    matches: directoryMatches[directory] ?? []
                )
            }
            return AgentContextFileBrowseSearchRootGroup(
                id: .searchRootHeader(rootID),
                root: root,
                matchCount: matches.count,
                rootMatches: rootMatches,
                directories: directories
            )
        }
    }

    private func makeFile(
        record: WorkspaceFileRecord,
        rootGeneration: UInt64,
        physicalRoots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) -> AgentContextFileBrowseFile? {
        let projectedPath: String
        if let projected = lookupContext.bindingProjection?.projectedLogicalPathComponents(
            forPhysicalPath: record.standardizedFullPath
        ) {
            projectedPath = ClientPathFormatter.nonAbsoluteDisplayPath(
                root: projected.root,
                relativePath: projected.relativePath,
                visibleRoots: lookupContext.bindingProjection?.visibleLogicalRootRefs ?? physicalRoots
            )
        } else {
            guard let root = physicalRoots.first(where: { $0.id == record.rootID }) else { return nil }
            projectedPath = ClientPathFormatter.nonAbsoluteDisplayPath(
                root: root,
                relativePath: record.standardizedRelativePath,
                visibleRoots: physicalRoots
            )
        }
        let directory = Self.parentDirectory(of: record.standardizedRelativePath)
        return AgentContextFileBrowseFile(
            id: record.id,
            rootID: record.rootID,
            rootGeneration: rootGeneration,
            parentFolderID: record.parentFolderID,
            name: record.name,
            standardizedRelativePath: record.standardizedRelativePath,
            standardizedFullPath: record.standardizedFullPath,
            projectedDisplayPath: projectedPath,
            projectedDirectoryPath: directory,
            modificationDate: record.modificationDate,
            supportsCodemap: WorkspaceSelectionMutationService.supportsCodemap(record)
        )
    }

    private func projectedDisplayRoots(
        from physicalRoots: [WorkspaceRootRef],
        lookupContext: WorkspaceLookupContext
    ) -> [AgentContextFileBrowseRoot] {
        let projectedRoots = physicalRoots.map { physicalRoot -> WorkspaceRootRef in
            lookupContext.bindingProjection?.projectedLogicalPathComponents(
                forPhysicalPath: physicalRoot.standardizedFullPath
            )?.root ?? physicalRoot
        }
        return zip(physicalRoots, projectedRoots).map { physicalRoot, projectedRoot in
            AgentContextFileBrowseRoot(
                id: physicalRoot.id,
                physicalPath: physicalRoot.standardizedFullPath,
                displayName: projectedRoot.name,
                scopeLabel: ClientPathFormatter.nonAbsoluteRootAlias(
                    root: projectedRoot,
                    visibleRoots: projectedRoots
                )
            )
        }
    }

    private func currentCatalogGeneration(
        lookupContext: WorkspaceLookupContext
    ) async -> AgentContextFileBrowseSessionScopedResult<UInt64> {
        guard lookupContext.bindingProjection?.isFullyMaterialized != false else {
            return .sessionRootsUnavailable
        }
        let validation = await store.readFileAutoSelectionCatalogValidationSnapshot(
            rootScope: lookupContext.rootScope
        )
        guard case .available = validation.rootScopeAvailability else {
            return .sessionRootsUnavailable
        }
        return .available(validation.rootScopeCatalogGeneration)
    }

    private func allowedPhysicalRoots(
        lookupContext: WorkspaceLookupContext
    ) async -> AgentContextFileBrowseSessionScopedResult<[WorkspaceRootRef]> {
        guard lookupContext.bindingProjection?.isFullyMaterialized != false else {
            return .sessionRootsUnavailable
        }
        let validation = await store.readFileAutoSelectionCatalogValidationSnapshot(
            rootScope: lookupContext.rootScope
        )
        guard case .available = validation.rootScopeAvailability else {
            Self.logger.notice("Context file browse roots unavailable for the current session scope")
            return .sessionRootsUnavailable
        }
        let roots = await store.rootRefs(scope: lookupContext.rootScope).filter { !Self.isGitDataRoot($0) }
        return .available(roots)
    }

    private func rootsForScope(
        _ scope: AgentContextFileBrowseRootScope,
        in roots: [AgentContextFileBrowseRoot]
    ) -> [AgentContextFileBrowseRoot] {
        switch scope {
        case .allRoots:
            roots
        case let .root(rootID):
            roots.filter { $0.id == rootID }
        }
    }

    private func indexedSearchIsAdmissible(
        scope: AgentContextFileBrowseRootScope,
        lookupContext: WorkspaceLookupContext
    ) -> Bool {
        scope == .allRoots
            && lookupContext.rootScope == .visibleWorkspace
            && lookupContext.bindingProjection == nil
    }

    private func searchHaystack(
        for entry: WorkspaceSearchCatalogEntry,
        lookupContext: WorkspaceLookupContext
    ) -> String {
        let logicalPath = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.standardizedFullPath,
            display: .relative
        )
        return [
            logicalPath,
            entry.displayPath,
            entry.name,
            entry.standardizedRelativePath,
            entry.standardizedFullPath
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func makeFolder(_ record: WorkspaceFolderRecord) -> AgentContextFileBrowseFolder {
        AgentContextFileBrowseFolder(
            id: record.id,
            rootID: record.rootID,
            parentFolderID: record.parentFolderID,
            name: record.name,
            standardizedRelativePath: record.standardizedRelativePath,
            standardizedFullPath: record.standardizedFullPath,
            modificationDate: record.modificationDate
        )
    }

    private static func sortFolders(_ folders: [WorkspaceFolderRecord]) -> [WorkspaceFolderRecord] {
        folders.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.standardizedRelativePath < $1.standardizedRelativePath
        }
    }

    private static func sortFiles(_ files: [WorkspaceFileRecord]) -> [WorkspaceFileRecord] {
        files.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.standardizedRelativePath < $1.standardizedRelativePath
        }
    }

    private static func isGitDataRoot(_ root: WorkspaceRootRef) -> Bool {
        root.name.caseInsensitiveCompare(excludedPathComponent) == .orderedSame
            || URL(fileURLWithPath: root.standardizedFullPath).lastPathComponent
            .caseInsensitiveCompare(excludedPathComponent) == .orderedSame
    }

    private static func isGitDataPath(_ path: String) -> Bool {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains {
            String($0).caseInsensitiveCompare(excludedPathComponent) == .orderedSame
        }
    }

    private static func makePhysicalRootRef(_ root: AgentContextFileBrowseRoot) -> WorkspaceRootRef {
        WorkspaceRootRef(
            id: root.id,
            name: URL(fileURLWithPath: root.physicalPath).lastPathComponent,
            fullPath: root.physicalPath
        )
    }

    private static func parentDirectory(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    private static func projectionIdentity(_ projection: WorkspaceRootBindingProjection?) -> String {
        guard let projection else { return "unprojected" }
        let roots = projection.boundRootsForMetadata.map {
            "\($0.logicalRoot.id.uuidString):\($0.logicalRoot.standardizedFullPath)->\($0.physicalRoot.id.uuidString):\($0.physicalRoot.standardizedFullPath)"
        }
        return ([projection.sessionID.uuidString] + roots).joined(separator: "|")
    }
}
