import Foundation

@MainActor
final class AgentFileTagSuggestionService {
    private struct FileCandidate {
        let displayName: String
        let disambiguationLabel: String?
        let commitDisplayText: String
        let matchName: String
        let tokenRelativePath: String
        let scoreRelativePath: String
        let nameLower: String
        let scorePathLower: String
        let standardizedFullPath: String
        let expandedSubtitle: String?
    }

    private nonisolated static let excludedPathComponent = "_git_data"
    private nonisolated static let fuzzyThreshold: Double = 0.85
    private nonisolated static let indexCandidateMultiplier = 8
    private nonisolated static let minimumIndexCandidateLimit = 64

    private let store: WorkspaceFileContextStore?
    private let searchService: WorkspaceSearchService?
    private weak var selectionCoordinator: WorkspaceSelectionCoordinator?
    private let lookupContextProvider: (() async -> WorkspaceLookupContext)?
    private let maxResults: Int
    private let showsFileSubtitles: Bool

    private var cachedCandidates: [FileCandidate] = []
    private var cachedLookupContext: WorkspaceLookupContext = .visibleWorkspace
    private var cachedGenerationSignature: UInt64?

    init(
        store: WorkspaceFileContextStore?,
        searchService: WorkspaceSearchService?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        lookupContextProvider: (() async -> WorkspaceLookupContext)? = nil,
        maxResults: Int = 5,
        showsFileSubtitles: Bool = false
    ) {
        self.store = store
        self.searchService = searchService
        self.selectionCoordinator = selectionCoordinator
        self.lookupContextProvider = lookupContextProvider
        self.maxResults = maxResults
        self.showsFileSubtitles = showsFileSubtitles
    }

    func suggestions(for rawQuery: String) async -> [MentionSuggestion] {
        guard let store else { return [] }

        let lookupContext = await currentLookupContext()
        if cachedLookupContext != lookupContext {
            cachedCandidates.removeAll()
            cachedGenerationSignature = nil
            cachedLookupContext = lookupContext
        }
        let query = RepoSearchQueryFactory.make(rawQuery, supportsWildcards: false)
        if query.isEmpty {
            let selected = await selectedSuggestionsForEmptyQuery(store: store, lookupContext: lookupContext)
            if !selected.isEmpty {
                return Array(selected.prefix(maxResults))
            }
            let currentGeneration = await store.catalogGeneration(rootScope: lookupContext.rootScope)
            if !cachedCandidates.isEmpty,
               cachedGenerationSignature == currentGeneration
            {
                return Array(cachedCandidates.prefix(maxResults)).map { makeSuggestion(from: $0) }
            }
            cachedCandidates.removeAll()
            cachedGenerationSignature = nil
            return []
        }

        let candidateLimit = max(maxResults * Self.indexCandidateMultiplier, Self.minimumIndexCandidateLimit)
        let catalogResults = await catalogResults(for: query.raw, limit: candidateLimit, store: store, lookupContext: lookupContext)
        let candidates = await makeCandidates(from: catalogResults, store: store, lookupContext: lookupContext)
        guard !candidates.isEmpty else { return [] }
        cachedCandidates = candidates
        cachedGenerationSignature = await store.catalogGeneration(rootScope: lookupContext.rootScope)
        return scoredSuggestions(from: candidates, query: query)
    }

    private func catalogResults(
        for query: String,
        limit: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [WorkspaceSearchCatalogEntry] {
        if lookupContext.bindingProjection == nil, let searchService {
            let result = await searchService.search(query, limit: limit)
            if result.isIndexReady, !result.isStale {
                let visibleRootIDs = await Set(store.rootRefs(scope: lookupContext.rootScope).map(\.id))
                let scopedResults = result.results.filter { visibleRootIDs.contains($0.rootID) }
                return Array(scopedResults.prefix(limit))
            }
        }
        return await storeBackedCatalogResults(for: query, limit: limit, store: store, lookupContext: lookupContext)
    }

    private func storeBackedCatalogResults(
        for query: String,
        limit: Int,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [WorkspaceSearchCatalogEntry] {
        let snapshot = await store.searchCatalogSnapshot(rootScope: lookupContext.rootScope)
        let entries = snapshot.entries
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(entries.prefix(boundedLimit)) }

        let indexedPaths = entries.map { searchHaystack(for: $0, lookupContext: lookupContext) }
        let index = await PathSearchIndex.build(paths: indexedPaths)
        let hits = await index.search(trimmed, limit: boundedLimit)
        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(hits.count)
        for hit in hits where entries.indices.contains(hit.index) {
            let entry = entries[hit.index]
            guard seenIDs.insert(entry.id).inserted else { continue }
            results.append(entry)
        }
        return results
    }

    private func searchHaystack(for entry: WorkspaceSearchCatalogEntry, lookupContext: WorkspaceLookupContext) -> String {
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

    private func makeCandidates(
        from entries: [WorkspaceSearchCatalogEntry],
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [FileCandidate] {
        let filtered = entries.filter {
            !Self.shouldExcludeFromSuggestions(relativePath: $0.standardizedRelativePath)
        }
        guard !filtered.isEmpty else { return [] }
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        let hasMultipleRoots = roots.count > 1
        let countByFileName = Dictionary(grouping: filtered, by: { $0.name.lowercased() })
            .mapValues(\.count)
        let rootNamesByFileName = Dictionary(grouping: filtered, by: { $0.name.lowercased() })
            .mapValues { Set($0.map { $0.rootName.lowercased() }) }

        var candidates = filtered.map { entry in
            let tokenRelativePath = tokenPath(for: entry, hasMultipleRoots: hasMultipleRoots, lookupContext: lookupContext)
            let scoreRelativePath = tokenRelativePath
            let fileNameKey = entry.name.lowercased()
            let isDuplicateName = (countByFileName[fileNameKey] ?? 0) > 1
            let spansMultipleRoots = (rootNamesByFileName[fileNameKey]?.count ?? 0) > 1
            let rootLabel = entry.rootName.trimmingCharacters(in: .whitespacesAndNewlines)
            let disambiguationLabel: String? = if isDuplicateName {
                if spansMultipleRoots, !rootLabel.isEmpty {
                    rootLabel
                } else if let parentLabel = Self.parentDirectoryLabel(for: scoreRelativePath), !parentLabel.isEmpty {
                    parentLabel
                } else if !rootLabel.isEmpty {
                    rootLabel
                } else {
                    nil
                }
            } else {
                nil
            }

            return FileCandidate(
                displayName: entry.name,
                disambiguationLabel: disambiguationLabel,
                commitDisplayText: Self.commitDisplayText(
                    fileName: entry.name,
                    tokenRelativePath: tokenRelativePath,
                    isDuplicateName: isDuplicateName
                ),
                matchName: entry.name,
                tokenRelativePath: tokenRelativePath,
                scoreRelativePath: scoreRelativePath,
                nameLower: entry.name.lowercased(),
                scorePathLower: scoreRelativePath.lowercased(),
                standardizedFullPath: entry.standardizedFullPath,
                expandedSubtitle: Self.expandedSubtitleLabel(
                    for: tokenRelativePath,
                    fallbackRootLabel: rootLabel
                )
            )
        }
        candidates.sort { lhs, rhs in
            if lhs.scorePathLower != rhs.scorePathLower {
                return lhs.scorePathLower < rhs.scorePathLower
            }
            return lhs.tokenRelativePath < rhs.tokenRelativePath
        }
        return candidates
    }

    private func currentLookupContext() async -> WorkspaceLookupContext {
        if let lookupContextProvider {
            return await lookupContextProvider()
        }
        return .visibleWorkspace
    }

    private func tokenPath(
        for entry: WorkspaceSearchCatalogEntry,
        hasMultipleRoots: Bool,
        lookupContext: WorkspaceLookupContext
    ) -> String {
        if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: entry.standardizedFullPath,
            display: .relative
        ) {
            return projected
        }
        return hasMultipleRoots ? entry.displayPath : entry.standardizedRelativePath
    }

    private func tokenPath(
        for file: WorkspaceFileRecord,
        roots: [WorkspaceRootRef],
        hasMultipleRoots: Bool,
        lookupContext: WorkspaceLookupContext
    ) -> String {
        if let projected = lookupContext.bindingProjection?.projectedLogicalDisplayPath(
            forPhysicalPath: file.standardizedFullPath,
            display: .relative
        ) {
            return projected
        }
        if hasMultipleRoots, let root = roots.first(where: { $0.id == file.rootID }) {
            return ClientPathFormatter.displayPath(
                root: root,
                relativePath: file.standardizedRelativePath,
                visibleRoots: roots
            )
        }
        return file.standardizedRelativePath
    }

    private func scoredSuggestions(from candidates: [FileCandidate], query: RepoSearchQuery) -> [MentionSuggestion] {
        let scoringCandidates = candidates.map {
            RepoSearchBatchScorer.Candidate(
                name: $0.matchName,
                path: $0.scoreRelativePath,
                nameLower: $0.nameLower,
                pathLower: $0.scorePathLower
            )
        }
        let rawScores = RepoSearchBatchScorer.scores(
            for: scoringCandidates,
            query: query,
            fuzzyThreshold: Self.fuzzyThreshold
        )

        var scored: [(candidate: FileCandidate, score: Int32)] = []
        scored.reserveCapacity(candidates.count)
        for (index, score) in rawScores.enumerated() where score > 0 {
            guard candidates.indices.contains(index) else { continue }
            scored.append((candidates[index], score))
        }

        guard !scored.isEmpty else { return [] }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.candidate.scoreRelativePath.count != rhs.candidate.scoreRelativePath.count {
                return lhs.candidate.scoreRelativePath.count < rhs.candidate.scoreRelativePath.count
            }
            return lhs.candidate.scorePathLower < rhs.candidate.scorePathLower
        }

        return scored
            .prefix(maxResults)
            .map { makeSuggestion(from: $0.candidate) }
    }

    /// Build the suggestion list for a bare `@` from the active stored selection.
    /// This path does not refresh all workspace candidates or materialize UI VMs.
    private func selectedSuggestionsForEmptyQuery(
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext
    ) async -> [MentionSuggestion] {
        guard let selectionCoordinator else { return [] }
        let selection = lookupContext.physicalizeSelection(
            selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true).selection
        )
        guard !selection.selectedPaths.isEmpty else { return [] }
        let visibleRoots = await store.rootRefs(scope: lookupContext.rootScope)
        let hasMultipleRoots = visibleRoots.count > 1
        let candidateByPath = makeCandidateByTokenPath()
        var seenIdentities = Set<String>()
        var suggestions: [MentionSuggestion] = []
        suggestions.reserveCapacity(min(maxResults, selection.selectedPaths.count))

        for path in selection.selectedPaths {
            guard let lookup = await store.lookupPath(WorkspacePathLookupRequest(userPath: path, profile: .mcpSelection, rootScope: lookupContext.rootScope)),
                  let file = lookup.file else { continue }
            guard !Self.shouldExcludeFromSuggestions(relativePath: file.standardizedRelativePath) else { continue }
            guard seenIdentities.insert(file.standardizedFullPath).inserted else { continue }
            let tokenRelativePath = tokenPath(
                for: file,
                roots: visibleRoots,
                hasMultipleRoots: hasMultipleRoots,
                lookupContext: lookupContext
            )
            if let candidate = candidateByPath[tokenRelativePath] {
                suggestions.append(makeSuggestion(from: candidate))
            } else {
                let rootLabel = visibleRoots
                    .first(where: { $0.id == file.rootID })?
                    .name
                suggestions.append(MentionSuggestion(
                    displayName: file.name,
                    relativePath: tokenRelativePath,
                    kind: .file,
                    subtitle: expandedSubtitleLabel(for: tokenRelativePath, fallbackRootLabel: rootLabel),
                    commitDisplayText: file.name
                ))
            }
            if suggestions.count >= maxResults { break }
        }
        return suggestions
    }

    /// Duplicate-tolerant lookup for cached candidates. Keep the first
    /// candidate seen for a given token path so we still pick up any
    /// precomputed disambiguation / display text when we do have a hit.
    private func makeCandidateByTokenPath() -> [String: FileCandidate] {
        Dictionary(
            cachedCandidates.map { ($0.tokenRelativePath, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func makeSuggestion(from candidate: FileCandidate) -> MentionSuggestion {
        MentionSuggestion(
            displayName: candidate.displayName,
            relativePath: candidate.tokenRelativePath,
            kind: .file,
            subtitle: showsFileSubtitles ? candidate.expandedSubtitle : candidate.disambiguationLabel,
            commitDisplayText: candidate.commitDisplayText
        )
    }

    private func expandedSubtitleLabel(for tokenRelativePath: String, fallbackRootLabel: String?) -> String? {
        guard showsFileSubtitles else { return nil }
        return Self.expandedSubtitleLabel(for: tokenRelativePath, fallbackRootLabel: fallbackRootLabel)
    }

    nonisolated static func commitDisplayText(
        fileName: String,
        tokenRelativePath: String,
        isDuplicateName: Bool
    ) -> String {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDuplicateName, !trimmedFileName.isEmpty {
            return trimmedFileName
        }
        return tokenRelativePath
    }

    private nonisolated static func shouldExcludeFromSuggestions(relativePath: String) -> Bool {
        relativePath
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .contains { String($0).lowercased() == excludedPathComponent }
    }

    private nonisolated static func parentDirectoryLabel(for relativePath: String) -> String? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        let parentComponents = components.dropLast()
        guard !parentComponents.isEmpty else { return nil }
        return parentComponents.joined(separator: "/")
    }

    private nonisolated static func expandedSubtitleLabel(
        for tokenRelativePath: String,
        fallbackRootLabel: String?
    ) -> String? {
        if let parentLabel = parentDirectoryLabel(for: tokenRelativePath), !parentLabel.isEmpty {
            return parentLabel
        }
        let rootLabel = fallbackRootLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rootLabel.isEmpty ? nil : rootLabel
    }

    #if DEBUG

        // MARK: - Testing support

        func seedCandidateCacheForTesting(tokenPaths: [String]) {
            cachedCandidates = tokenPaths.map { tokenPath in
                let basename = (tokenPath as NSString).lastPathComponent
                return FileCandidate(
                    displayName: basename,
                    disambiguationLabel: nil,
                    commitDisplayText: tokenPath,
                    matchName: basename,
                    tokenRelativePath: tokenPath,
                    scoreRelativePath: tokenPath,
                    nameLower: basename.lowercased(),
                    scorePathLower: tokenPath.lowercased(),
                    standardizedFullPath: tokenPath,
                    expandedSubtitle: Self.expandedSubtitleLabel(
                        for: tokenPath,
                        fallbackRootLabel: nil
                    )
                )
            }
        }

        var cachedCandidateCountForTesting: Int {
            cachedCandidates.count
        }

        var pathSearchIndexIsBuiltForTesting: Bool {
            false
        }
    #endif
}
