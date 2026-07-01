import Foundation

struct WorkspaceSelectionSliceInput: Equatable {
    let path: String
    let ranges: [LineRange]
}

struct WorkspaceBuildSelectionResult: Equatable {
    let selection: StoredSelection
    let invalidPaths: [String]
    let codemapUnavailable: [String]
}

struct WorkspaceAddSelectionResult: Equatable {
    let selection: StoredSelection
    let invalidPaths: [String]
    let resolvedMap: [String: String]
    let mutated: Bool
    let codemapUnavailable: [String]
}

struct WorkspaceRemoveSelectionResult: Equatable {
    let selection: StoredSelection
    let invalidPaths: [String]
    let resolvedMap: [String: String]
    let mutated: Bool
}

struct WorkspaceDemoteSelectionResult: Equatable {
    let selection: StoredSelection
    let invalidPaths: [String]
    let codemapUnavailable: [String]
    let mutated: Bool
}

struct WorkspaceSliceSelectionMutationResult: Equatable {
    let selection: StoredSelection
    let invalidPaths: [String]
    let resolvedMap: [String: String]
    let mutated: Bool
}

enum WorkspacePreResolvedFullFileMutationMode {
    case add
    case remove
}

struct WorkspaceCodemapAutomaticSelectionRequestPolicy: Equatable {
    static let `default` = Self()

    let maximumReadinessRounds: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let maximumTotalWait: Duration
    let maximumCandidateDemandCount: Int

    init(
        maximumReadinessRounds: Int = 6,
        initialBackoffMilliseconds: Int = 50,
        maximumBackoffMilliseconds: Int = 400,
        maximumTotalWait: Duration = .seconds(2),
        maximumCandidateDemandCount: Int = 1024
    ) {
        precondition(maximumReadinessRounds > 0)
        precondition(initialBackoffMilliseconds > 0)
        precondition(maximumBackoffMilliseconds >= initialBackoffMilliseconds)
        precondition(maximumCandidateDemandCount > 0)
        self.maximumReadinessRounds = maximumReadinessRounds
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.maximumTotalWait = maximumTotalWait
        self.maximumCandidateDemandCount = maximumCandidateDemandCount
    }
}

struct WorkspaceCodemapAutomaticSelectionWaiter {
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = Self { duration in
        try await Task.sleep(for: duration)
    }
}

private actor WorkspaceCodemapAutomaticSelectionDemandOwnership {
    private var retainedTickets = Set<WorkspaceCodemapArtifactDemandTicket>()
    private var retainedProjectionTickets = Set<WorkspaceCodemapProjectionDemandTicket>()

    func record(_ ownedResult: WorkspaceCodemapArtifactDemandOwnedResult) {
        switch ownedResult.ownership {
        case let .created(ticket), let .joined(ticket):
            retainedTickets.insert(ticket)
        case .notAcquired:
            break
        }
    }

    func recordCreatedResult(_ result: WorkspaceCodemapArtifactDemandResult) {
        switch result {
        case let .pending(ticket):
            retainedTickets.insert(ticket)
        case let .ready(ready):
            retainedTickets.insert(ready.ticket)
        case .unavailable:
            break
        }
    }

    func owns(_ ticket: WorkspaceCodemapArtifactDemandTicket) -> Bool {
        retainedTickets.contains(ticket)
    }

    func tickets() -> [WorkspaceCodemapArtifactDemandTicket] {
        Array(retainedTickets)
    }

    func record(_ ticket: WorkspaceCodemapProjectionDemandTicket) {
        retainedProjectionTickets.insert(ticket)
    }

    func drainRetainedProjectionTickets() -> [WorkspaceCodemapProjectionDemandTicket] {
        defer { retainedProjectionTickets.removeAll() }
        return Array(retainedProjectionTickets)
    }

    func drainRetainedTickets() -> [WorkspaceCodemapArtifactDemandTicket] {
        defer { retainedTickets.removeAll() }
        return Array(retainedTickets)
    }

    func transferSourceTickets(
        matching sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
    ) -> (sources: [WorkspaceCodemapArtifactDemandTicket], remainder: [WorkspaceCodemapArtifactDemandTicket])? {
        var available = retainedTickets
        var transferred: [WorkspaceCodemapArtifactDemandTicket] = []
        transferred.reserveCapacity(sourceTickets.count)
        for source in sourceTickets {
            let matches = available.filter { candidate in
                candidate.requestID == source.requestID &&
                    candidate.rootEpoch == source.rootEpoch &&
                    candidate.fileID == source.fileID &&
                    candidate.requestGeneration == source.requestGeneration &&
                    candidate.catalogGeneration == source.catalogGeneration &&
                    candidate.pathGeneration == source.pathGeneration &&
                    candidate.ingressGeneration == source.ingressGeneration
            }.sorted { $0.retainID.uuidString < $1.retainID.uuidString }
            guard let match = matches.first else { return nil }
            available.remove(match)
            transferred.append(match)
        }
        retainedTickets.removeAll()
        return (transferred, Array(available))
    }
}

private struct WorkspaceCodemapAutomaticSelectionProvisionalCandidateDemandBatch {
    let readyCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
    let pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason]
    let partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason]
}

struct WorkspaceSelectionMutationService {
    let store: WorkspaceFileContextStore
    let codemapsGloballyDisabled: Bool
    let codemapsGloballyDisabledMessage: String
    let automaticSelectionPolicy: WorkspaceCodemapAutomaticSelectionRequestPolicy
    let automaticSelectionWaiter: WorkspaceCodemapAutomaticSelectionWaiter
    let automaticSelectionSourceDemandHook: @Sendable (
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        WorkspaceCodemapArtifactDemandResult
    ) async throws -> Void

    init(
        store: WorkspaceFileContextStore,
        codemapsGloballyDisabled: Bool = false,
        codemapsGloballyDisabledMessage: String = "Code maps are disabled for this tool.",
        automaticSelectionPolicy: WorkspaceCodemapAutomaticSelectionRequestPolicy = .default,
        automaticSelectionWaiter: WorkspaceCodemapAutomaticSelectionWaiter = .production,
        automaticSelectionSourceDemandHook: @escaping @Sendable (
            WorkspaceCodemapAutomaticSelectionSourceIdentity,
            WorkspaceCodemapArtifactDemandResult
        ) async throws -> Void = { _, _ in }
    ) {
        self.store = store
        self.codemapsGloballyDisabled = codemapsGloballyDisabled
        self.codemapsGloballyDisabledMessage = codemapsGloballyDisabledMessage
        self.automaticSelectionPolicy = automaticSelectionPolicy
        self.automaticSelectionWaiter = automaticSelectionWaiter
        self.automaticSelectionSourceDemandHook = automaticSelectionSourceDemandHook
    }

    func buildSelection(
        paths: [String],
        slices sliceInputs: [WorkspaceSelectionSliceInput] = [],
        sliceErrors: [String] = [],
        mode: String,
        existing: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceBuildSelectionResult {
        if mode == "codemap_only" {
            let resolution = await resolveCodemapOnlyCandidates(
                paths: paths,
                rawPaths: paths,
                expandFolders: true,
                rootScope: rootScope
            )
            return WorkspaceBuildSelectionResult(
                selection: StoredSelection(
                    manualCodemapPaths: resolution.candidates.map(\.standardizedFullPath),
                    codemapAutoEnabled: false
                ),
                invalidPaths: sliceErrors + resolution.invalidPaths,
                codemapUnavailable: resolution.codemapUnavailable
            )
        }

        var invalid = sliceErrors
        let codemapUnavailable: [String] = []
        var selectedPaths: [String] = []
        var seenSelected = Set<String>()
        var slicesByPath: [String: [LineRange]] = [:]

        let resolution = await resolveSelectionCandidates(
            paths: paths,
            rawPaths: paths,
            expandFolders: true,
            rootScope: rootScope
        )
        invalid.append(contentsOf: resolution.invalidPaths)
        for file in resolution.candidates where seenSelected.insert(file.standardizedFullPath).inserted {
            selectedPaths.append(file.standardizedFullPath)
        }

        let slicePaths = sliceInputs.map(\.path)
        let resolvedSlices = await store.lookupFiles(atPaths: slicePaths, rootScope: rootScope)
        for entry in sliceInputs {
            let trimmed = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let file = resolvedSlices[trimmed] else {
                invalid.append(trimmed)
                continue
            }
            let fullPath = file.standardizedFullPath
            if seenSelected.insert(fullPath).inserted {
                selectedPaths.append(fullPath)
            }
            if !entry.ranges.isEmpty {
                slicesByPath[fullPath, default: []].append(contentsOf: entry.ranges)
            }
        }
        slicesByPath = normalizeSlices(slicesByPath)

        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            slices: slicesByPath,
            codemapAutoEnabled: existing.codemapAutoEnabled
        )
        return WorkspaceBuildSelectionResult(selection: selection, invalidPaths: invalid, codemapUnavailable: codemapUnavailable)
    }

    func buildManageSelectionSet(
        paths: [String],
        slices sliceInputs: [WorkspaceSelectionSliceInput] = [],
        sliceErrors: [String] = [],
        mode: String,
        existing: StoredSelection,
        hasFullFileArtifactInputs: Bool = false,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceBuildSelectionResult {
        if mode == "codemap_only", !sliceInputs.isEmpty {
            return WorkspaceBuildSelectionResult(
                selection: existing,
                invalidPaths: sliceErrors + ["mode 'codemap_only' cannot be used with slices"],
                codemapUnavailable: []
            )
        }

        if mode == "slices" {
            let validSliceInputs = sliceInputs.filter { !SliceRangeMath.normalize($0.ranges).isEmpty }
            let pathsWithRanges = Set(validSliceInputs.map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) })
            var pathsMissingRanges: [String] = []
            var seenMissing = Set<String>()
            for path in paths.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !path.isEmpty && !pathsWithRanges.contains(path) {
                if seenMissing.insert(path).inserted { pathsMissingRanges.append(path) }
            }
            for entry in sliceInputs where SliceRangeMath.normalize(entry.ranges).isEmpty {
                let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, seenMissing.insert(path).inserted { pathsMissingRanges.append(path) }
            }
            if !pathsMissingRanges.isEmpty {
                return WorkspaceBuildSelectionResult(
                    selection: existing,
                    invalidPaths: sliceErrors + ["mode 'slices' requires line ranges for paths: \(pathsMissingRanges.joined(separator: ", ")). Use #L ranges, the slices array, or op='add' mode='full' for whole files."],
                    codemapUnavailable: []
                )
            }
            if validSliceInputs.isEmpty {
                let invalid = sliceErrors.isEmpty
                    ? ["mode 'slices' requires a non-empty slices array or #L line ranges on paths."]
                    : sliceErrors
                return WorkspaceBuildSelectionResult(
                    selection: existing,
                    invalidPaths: invalid,
                    codemapUnavailable: []
                )
            }
        }

        let isSliceScopedSet = mode == "slices" || (!hasFullFileArtifactInputs && paths.isEmpty && !sliceInputs.isEmpty)
        guard isSliceScopedSet else {
            let replacementSeed = StoredSelection(
                codemapAutoEnabled: existing.codemapAutoEnabled
            )
            return await buildSelection(
                paths: paths,
                slices: sliceInputs,
                sliceErrors: sliceErrors,
                mode: mode,
                existing: replacementSeed,
                rootScope: rootScope
            )
        }

        let sliceResult = await mutateSlices(
            base: existing,
            entries: sliceInputs,
            mode: .setPaths,
            rootScope: rootScope
        )
        return WorkspaceBuildSelectionResult(
            selection: sliceResult.selection,
            invalidPaths: sliceErrors + sliceResult.invalidPaths,
            codemapUnavailable: []
        )
    }

    /// Applies already-authorized exact identities without path lookup, folder expansion, or
    /// codemap discovery. Git artifact policy remains owned by the MCP boundary.
    func mutatePreResolvedFullFilePaths(
        base: StoredSelection,
        absolutePaths: [String],
        mode: WorkspacePreResolvedFullFileMutationMode
    ) -> StoredSelection {
        var selected = StoredSelectionPathNormalization.standardizedPaths(base.selectedPaths)
        var slices = StoredSelectionPathNormalization.standardizedSlices(base.slices)
        var selectedSet = Set(selected)

        let identities = absolutePaths.compactMap(StoredSelectionPathNormalization.standardizedPath)
        for identity in identities {
            switch mode {
            case .add:
                if selectedSet.insert(identity).inserted {
                    selected.append(identity)
                }
                slices.removeValue(forKey: identity)
            case .remove:
                selected.removeAll { $0 == identity }
                selectedSet.remove(identity)
                slices.removeValue(forKey: identity)
            }
        }

        return StoredSelection(
            selectedPaths: selected,
            manualCodemapPaths: base.manualCodemapPaths.filter { !selectedSet.contains($0) },
            slices: slices,
            codemapAutoEnabled: base.codemapAutoEnabled
        )
    }

    func mutateSlices(
        base: StoredSelection,
        entries: [WorkspaceSelectionSliceInput],
        mode: SliceMutationMode,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceSliceSelectionMutationResult {
        let trimmedInputs = entries.map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }
        var invalid: [String] = []
        var lookupInputs: [String] = []
        lookupInputs.reserveCapacity(trimmedInputs.count)
        for input in trimmedInputs where !input.isEmpty {
            if let issue = await store.exactPathResolutionIssue(for: input, kind: .file, rootScope: rootScope) {
                invalid.append(PathResolutionIssueRenderer.message(for: issue))
            } else {
                lookupInputs.append(input)
            }
        }
        let lookup = await store.lookupFiles(atPaths: lookupInputs, rootScope: rootScope)
        let roots = await store.rootRefs(scope: rootScope)
        func displayPath(for file: WorkspaceFileRecord) -> String {
            guard let root = roots.first(where: { $0.id == file.rootID }) else { return file.standardizedFullPath }
            return ClientPathFormatter.displayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: roots)
        }

        var resolved: [String: String] = [:]
        let originalSlices = StoredSelectionPathNormalization.standardizedSlices(base.slices)
        let baseSelectedPaths = StoredSelectionPathNormalization.standardizedPaths(base.selectedPaths)
        var slices = originalSlices
        var selectedPaths = baseSelectedPaths
        var selectedSet = Set(selectedPaths)

        func resolveEntry(_ entry: WorkspaceSelectionSliceInput, at index: Int) -> WorkspaceFileRecord? {
            let input = trimmedInputs[index]
            guard !input.isEmpty else { return nil }
            guard !invalid.contains(where: { $0 == input || $0.contains(input) }) else { return nil }
            guard let file = lookup[input] else {
                invalid.append(entry.path)
                return nil
            }
            resolved[entry.path] = displayPath(for: file)
            return file
        }

        switch mode {
        case .set:
            slices.removeAll()
            var aggregated: [String: [LineRange]] = [:]
            for (index, entry) in entries.enumerated() {
                guard let file = resolveEntry(entry, at: index) else { continue }
                aggregated[file.standardizedFullPath, default: []].append(contentsOf: entry.ranges)
            }
            for (full, ranges) in aggregated {
                let normalized = SliceRangeMath.normalize(ranges)
                if normalized.isEmpty { slices.removeValue(forKey: full) } else { slices[full] = normalized }
            }
        case .setPaths:
            var aggregated: [String: [LineRange]] = [:]
            for (index, entry) in entries.enumerated() {
                guard let file = resolveEntry(entry, at: index) else { continue }
                aggregated[file.standardizedFullPath, default: []].append(contentsOf: entry.ranges)
            }
            for (full, ranges) in aggregated {
                let normalized = SliceRangeMath.normalize(ranges)
                if normalized.isEmpty { slices.removeValue(forKey: full) } else { slices[full] = normalized }
            }
        case .add:
            for (index, entry) in entries.enumerated() {
                guard let file = resolveEntry(entry, at: index) else { continue }
                let normalized = SliceRangeMath.normalize(entry.ranges)
                guard !normalized.isEmpty else { continue }
                let next = SliceRangeMath.coalesce(slices[file.standardizedFullPath] ?? [], normalized)
                if next.isEmpty { slices.removeValue(forKey: file.standardizedFullPath) } else { slices[file.standardizedFullPath] = next }
            }
        case .remove:
            for (index, entry) in entries.enumerated() {
                guard let file = resolveEntry(entry, at: index) else { continue }
                let full = file.standardizedFullPath
                let baseRanges = slices[full] ?? []
                if baseRanges.isEmpty && entry.ranges.isEmpty {
                    slices.removeValue(forKey: full)
                    continue
                }
                let removal = SliceRangeMath.normalize(entry.ranges)
                guard !baseRanges.isEmpty else { continue }
                let next = removal.isEmpty ? [] : SliceRangeMath.subtract(baseRanges, removing: removal)
                if next.isEmpty { slices.removeValue(forKey: full) } else { slices[full] = next }
            }
        }

        for (full, ranges) in slices where !ranges.isEmpty {
            if selectedSet.insert(full).inserted { selectedPaths.append(full) }
        }
        let nextSelection = StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: base.manualCodemapPaths.filter { !selectedSet.contains($0) },
            slices: slices,
            codemapAutoEnabled: base.codemapAutoEnabled
        )
        let mutated = nextSelection != base
        return WorkspaceSliceSelectionMutationResult(
            selection: nextSelection,
            invalidPaths: invalid,
            resolvedMap: resolved,
            mutated: mutated
        )
    }

    func addPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceAddSelectionResult {
        if mode == "codemap_only" {
            let resolution = await resolveCodemapOnlyCandidates(
                paths: paths,
                rawPaths: rawPaths,
                expandFolders: true,
                rootScope: rootScope
            )
            guard !resolution.candidates.isEmpty else {
                return WorkspaceAddSelectionResult(
                    selection: existing,
                    invalidPaths: resolution.invalidPaths,
                    resolvedMap: resolution.resolvedMap,
                    mutated: false,
                    codemapUnavailable: resolution.codemapUnavailable
                )
            }
            var selectedPaths = StoredSelectionPathNormalization.standardizedPaths(existing.selectedPaths)
            var slices = StoredSelectionPathNormalization.standardizedSlices(existing.slices)
            var manualPaths = StoredSelectionPathNormalization.standardizedPaths(existing.manualCodemapPaths)
            var manualSet = Set(manualPaths)
            for file in resolution.candidates {
                let path = file.standardizedFullPath
                selectedPaths.removeAll { $0 == path }
                slices.removeValue(forKey: path)
                if manualSet.insert(path).inserted { manualPaths.append(path) }
            }
            let selection = StoredSelection(
                selectedPaths: selectedPaths,
                manualCodemapPaths: manualPaths,
                slices: slices,
                codemapAutoEnabled: false
            )
            return WorkspaceAddSelectionResult(
                selection: selection,
                invalidPaths: resolution.invalidPaths,
                resolvedMap: resolution.resolvedMap,
                mutated: selection != existing,
                codemapUnavailable: resolution.codemapUnavailable
            )
        }
        let candidateResolutionTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.candidateResolutionTotal)
        let resolution = await resolveSelectionCandidates(
            paths: paths,
            rawPaths: rawPaths,
            expandFolders: true,
            rootScope: rootScope
        )
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.candidateResolutionTotal, candidateResolutionTotal)

        let structuralMerge = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.structuralMerge)
        var selectedPaths = existing.selectedPaths
        let slices = existing.slices
        var selectedSet = Set(selectedPaths)
        for file in resolution.candidates where selectedSet.insert(file.standardizedFullPath).inserted {
            selectedPaths.append(file.standardizedFullPath)
        }
        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: existing.manualCodemapPaths.filter { !selectedSet.contains($0) },
            slices: slices,
            codemapAutoEnabled: existing.codemapAutoEnabled
        )
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.structuralMerge, structuralMerge)
        return WorkspaceAddSelectionResult(
            selection: selection,
            invalidPaths: resolution.invalidPaths,
            resolvedMap: resolution.resolvedMap,
            mutated: selection != existing,
            codemapUnavailable: []
        )
    }

    func removePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceRemoveSelectionResult {
        if mode == "codemap_only" {
            let resolution = await resolveSelectionCandidates(
                paths: paths,
                rawPaths: rawPaths,
                expandFolders: true,
                allowEmptyFolderExpansion: true,
                rootScope: rootScope
            )
            let removedPaths = Set(resolution.candidates.map(\.standardizedFullPath))
            let selection = StoredSelection(
                selectedPaths: existing.selectedPaths,
                manualCodemapPaths: existing.manualCodemapPaths.filter { !removedPaths.contains($0) },
                slices: existing.slices,
                codemapAutoEnabled: existing.codemapAutoEnabled
            )
            return WorkspaceRemoveSelectionResult(
                selection: selection,
                invalidPaths: resolution.invalidPaths,
                resolvedMap: resolution.resolvedMap,
                mutated: selection != existing
            )
        }
        let resolution = await resolveSelectionCandidates(
            paths: paths,
            rawPaths: rawPaths,
            expandFolders: true,
            allowEmptyFolderExpansion: true,
            rootScope: rootScope
        )
        var selectedPaths = existing.selectedPaths
        var slices = existing.slices
        for file in resolution.candidates {
            selectedPaths.removeAll { $0 == file.standardizedFullPath }
            _ = removeSliceEntries(for: file, in: &slices)
        }
        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: existing.manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: existing.codemapAutoEnabled
        )
        return WorkspaceRemoveSelectionResult(
            selection: selection,
            invalidPaths: resolution.invalidPaths,
            resolvedMap: resolution.resolvedMap,
            mutated: selection != existing
        )
    }

    func promotePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (selection: StoredSelection, invalidPaths: [String], mutated: Bool) {
        let resolution = await resolveSelectionCandidates(paths: paths, rawPaths: rawPaths, expandFolders: false, rootScope: rootScope)
        var selectedPaths = existing.selectedPaths
        var manualCodemapPaths = existing.manualCodemapPaths
        var slices = existing.slices
        var selectedSet = Set(selectedPaths)
        var mutated = false

        for file in resolution.candidates {
            let path = file.standardizedFullPath
            if !selectedSet.contains(path) {
                selectedPaths.append(path)
                selectedSet.insert(path)
                mutated = true
            }
            manualCodemapPaths.removeAll { $0 == path }
            if removeSliceEntries(for: file, in: &slices) { mutated = true }
        }

        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: existing.codemapAutoEnabled
        )
        return (selection, resolution.invalidPaths, selection != existing || mutated)
    }

    func demotePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceDemoteSelectionResult {
        let resolution = await resolveCodemapOnlyCandidates(
            paths: paths,
            rawPaths: rawPaths,
            expandFolders: false,
            rootScope: rootScope
        )
        guard !resolution.candidates.isEmpty else {
            return WorkspaceDemoteSelectionResult(
                selection: existing,
                invalidPaths: resolution.invalidPaths,
                codemapUnavailable: resolution.codemapUnavailable,
                mutated: false
            )
        }
        var selectedPaths = existing.selectedPaths
        var slices = existing.slices
        var manualCodemapPaths = existing.manualCodemapPaths
        var manualSet = Set(manualCodemapPaths)
        for file in resolution.candidates {
            let path = file.standardizedFullPath
            selectedPaths.removeAll { $0 == path }
            _ = removeSliceEntries(for: file, in: &slices)
            if manualSet.insert(path).inserted { manualCodemapPaths.append(path) }
        }
        let selection = StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: false
        )
        return WorkspaceDemoteSelectionResult(
            selection: selection,
            invalidPaths: resolution.invalidPaths,
            codemapUnavailable: resolution.codemapUnavailable,
            mutated: selection != existing
        )
    }

    func resolveSelectionCandidates(
        paths: [String],
        rawPaths: [String],
        expandFolders: Bool,
        allowEmptyFolderExpansion: Bool = false,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceResolvedCandidates {
        let rawLookup = rawLookup(rawPaths)
        let ordered = orderedInputs(paths)
        var invalid: [String] = []
        var preflight: [String] = []
        for key in ordered {
            if let issue = await store.exactPathResolutionIssue(for: key, kind: expandFolders ? .either : .file, rootScope: rootScope) {
                invalid.append(PathResolutionIssueRenderer.message(for: issue))
            } else {
                preflight.append(key)
            }
        }

        let resolved = await store.lookupFiles(atPaths: preflight, rootScope: rootScope)
        var resolvedMap: [String: String] = [:]
        var candidates: [WorkspaceFileRecord] = []
        var seen = Set<String>()
        for key in preflight {
            let raw = rawLookup[key] ?? key
            if let file = resolved[key] {
                if seen.insert(file.standardizedFullPath).inserted { candidates.append(file) }
                if resolvedMap[raw] == nil { resolvedMap[raw] = await displayPath(for: file, rootScope: rootScope) }
                continue
            }
            if expandFolders {
                let folder = await store.expandFolderInputToFiles(key, rootScope: rootScope)
                if folder.handled {
                    if folder.files.isEmpty {
                        if allowEmptyFolderExpansion {
                            resolvedMap[raw] = resolvedMap[raw] ?? (folder.displayPath ?? key)
                        } else if let issue = folder.issue {
                            invalid.append(PathResolutionIssueRenderer.message(for: issue))
                        } else {
                            invalid.append(raw)
                        }
                    } else {
                        for file in folder.files where seen.insert(file.standardizedFullPath).inserted {
                            candidates.append(file)
                        }
                        resolvedMap[raw] = resolvedMap[raw] ?? (folder.displayPath ?? key)
                    }
                    continue
                }
                if let issue = folder.issue {
                    invalid.append(PathResolutionIssueRenderer.message(for: issue))
                    continue
                }
            }
            invalid.append(raw)
        }
        return WorkspaceResolvedCandidates(candidates: candidates, resolvedMap: resolvedMap, invalidPaths: invalid)
    }

    func resolveCodemapOnlyCandidates(
        paths: [String],
        rawPaths: [String],
        expandFolders: Bool,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceCodemapOnlyCandidates {
        let rawLookup = rawLookup(rawPaths)
        let ordered = orderedInputs(paths)
        var invalid: [String] = []
        var preflight: [String] = []
        for key in ordered {
            if let issue = await store.exactPathResolutionIssue(for: key, kind: expandFolders ? .either : .file, rootScope: rootScope) {
                invalid.append(PathResolutionIssueRenderer.message(for: issue))
            } else {
                preflight.append(key)
            }
        }

        let resolved = await store.lookupFiles(atPaths: preflight, rootScope: rootScope)
        var unavailable: [String] = []
        var resolvedMap: [String: String] = [:]
        var candidates: [WorkspaceFileRecord] = []
        var seen = Set<String>()
        for key in preflight {
            let raw = rawLookup[key] ?? key
            if let file = resolved[key] {
                if supportsCodemap(file) {
                    if seen.insert(file.standardizedFullPath).inserted { candidates.append(file) }
                } else {
                    await unavailable.append("codemap unavailable: \(displayPath(for: file, rootScope: rootScope))")
                }
                if resolvedMap[raw] == nil {
                    resolvedMap[raw] = await displayPath(for: file, rootScope: rootScope)
                }
                continue
            }
            if expandFolders {
                let folder = await store.expandFolderInputToFiles(key, rootScope: rootScope)
                if folder.handled {
                    if folder.files.isEmpty {
                        if let issue = folder.issue { invalid.append(PathResolutionIssueRenderer.message(for: issue)) } else { invalid.append(raw) }
                    } else {
                        var supported = 0
                        var unsupported = 0
                        for file in folder.files {
                            if supportsCodemap(file) {
                                if seen.insert(file.standardizedFullPath).inserted { candidates.append(file) }
                                supported += 1
                            } else {
                                unsupported += 1
                            }
                        }
                        if unsupported > 0, supported == 0 {
                            unavailable.append("codemap unavailable: \(raw) (no supported files)")
                        } else if unsupported > 0 {
                            unavailable.append("codemap unavailable: \(unsupported) file(s) in \(raw) skipped (unsupported)")
                        }
                        resolvedMap[raw] = resolvedMap[raw] ?? (folder.displayPath ?? key)
                    }
                    continue
                }
                if let issue = folder.issue {
                    invalid.append(PathResolutionIssueRenderer.message(for: issue))
                    continue
                }
            }
            invalid.append(raw)
        }
        return WorkspaceCodemapOnlyCandidates(candidates: candidates, resolvedMap: resolvedMap, invalidPaths: invalid, codemapUnavailable: unavailable)
    }

    /// Resolves graph-inferred codemap targets without folding them into `StoredSelection`.
    /// Source lookup and root-scope validation happen before exact root-qualified identities
    /// cross into the graph query.
    func resolveAutomaticCodemapSelection(
        for selection: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult? {
        guard selection.codemapAutoEnabled, !codemapsGloballyDisabled else { return nil }

        let selectedPaths = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        var inScopePaths: [String] = []
        inScopePaths.reserveCapacity(selectedPaths.count)
        for path in selectedPaths {
            guard await store.exactPathResolutionIssue(
                for: path,
                kind: .file,
                rootScope: rootScope
            ) == nil else { continue }
            inScopePaths.append(path)
        }
        guard !inScopePaths.isEmpty else {
            return WorkspaceCodemapAutomaticSelectionResult(roots: [])
        }
        let lookup = await store.lookupFiles(atPaths: inScopePaths, rootScope: rootScope)
        return try await resolveAutomaticCodemapSelection(
            sourceFileIDs: inScopePaths.compactMap { lookup[$0]?.id },
            rootScope: rootScope
        )
    }

    func resolveAutomaticCodemapSelection(
        sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        let ownership = WorkspaceCodemapAutomaticSelectionDemandOwnership()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: automaticSelectionPolicy.maximumTotalWait)
        do {
            let result = try await resolveAutomaticCodemapSelectionRetainingOwnership(
                sourceFileIDs: sourceFileIDs,
                rootScope: rootScope,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
            let projectionTickets = await ownership.drainRetainedProjectionTickets()
            var projectionCleanupCompletedBeforeDeadline = automaticSelectionDeadlineIsCurrent(
                clock: clock,
                deadline: deadline
            )
            for ticket in projectionTickets {
                _ = await store.releaseCodemapProjectionDemand(ticket, deadline: deadline)
                if !automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) {
                    projectionCleanupCompletedBeforeDeadline = false
                }
            }
            guard projectionCleanupCompletedBeforeDeadline else {
                let artifactTickets = await ownership.drainRetainedTickets()
                return await failClosedAutomaticSelection(
                    permits: [result.publicationReceipt?.publicationPermit].compactMap(\.self),
                    tickets: artifactTickets,
                    deadline: deadline
                )
            }
            return await finalizeAutomaticSelectionOwnership(
                result,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
        } catch {
            for ticket in await ownership.drainRetainedProjectionTickets() {
                _ = await store.releaseCodemapProjectionDemand(ticket, deadline: deadline)
            }
            for ticket in await ownership.drainRetainedTickets() {
                _ = await store.cancelCodemapArtifactDemand(ticket, deadline: deadline)
            }
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func finalizeAutomaticSelectionOwnership(
        _ result: WorkspaceCodemapAutomaticSelectionResult,
        ownership: WorkspaceCodemapAutomaticSelectionDemandOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> WorkspaceCodemapAutomaticSelectionResult {
        guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) else {
            let tickets = await ownership.drainRetainedTickets()
            return await failClosedAutomaticSelection(
                permits: [result.publicationReceipt?.publicationPermit].compactMap(\.self),
                tickets: tickets,
                deadline: deadline
            )
        }
        guard let receipt = result.publicationReceipt else {
            let tickets = await ownership.drainRetainedTickets()
            guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) else {
                return await failClosedAutomaticSelection(tickets: tickets, deadline: deadline)
            }
            for ticket in tickets {
                _ = await store.cancelCodemapArtifactDemand(ticket, deadline: deadline)
                guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) else {
                    return await failClosedAutomaticSelection(tickets: tickets, deadline: deadline)
                }
            }
            return result
        }
        let transfer = await ownership.transferSourceTickets(matching: receipt.sourceTickets)
        guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) else {
            let tickets: [WorkspaceCodemapArtifactDemandTicket] = if let transfer {
                transfer.sources + transfer.remainder
            } else {
                await ownership.drainRetainedTickets()
            }
            return await failClosedAutomaticSelection(
                permits: [receipt.publicationPermit],
                tickets: tickets,
                deadline: deadline
            )
        }
        guard let transfer,
              transfer.sources.count == receipt.sourceTickets.count
        else {
            let tickets = await ownership.drainRetainedTickets()
            return await failClosedAutomaticSelection(
                permits: [receipt.publicationPermit],
                tickets: tickets,
                deadline: deadline
            )
        }
        let partitionedRemainder = partitionAutomaticSelectionRemainder(
            transfer.remainder,
            for: receipt
        )
        for ticket in partitionedRemainder.cancellable {
            _ = await store.cancelCodemapArtifactDemand(ticket, deadline: deadline)
            guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline) else {
                return await failClosedAutomaticSelection(
                    permits: [receipt.publicationPermit],
                    tickets: transfer.sources + partitionedRemainder.retained + partitionedRemainder.cancellable,
                    deadline: deadline
                )
            }
        }
        if receipt.publicationBasis == .projectionCoverage {
            for rootEpoch in Set(partitionedRemainder.cancellable.map(\.rootEpoch)) {
                let publicationCurrent = await store.waitForCodemapGraphPublication(
                    rootEpoch: rootEpoch,
                    deadline: deadline
                )
                guard publicationCurrent,
                      automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline)
                else {
                    return await failClosedAutomaticSelection(
                        permits: [receipt.publicationPermit],
                        tickets: transfer.sources + partitionedRemainder.retained,
                        deadline: deadline
                    )
                }
            }
        }
        let refreshedResult = await store.refreshAutomaticCodemapSelectionResultForCurrentProjection(
            result,
            sourceTickets: transfer.sources,
            rootScope: receipt.rootScope,
            deadline: deadline
        )
        guard automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline),
              let refreshedResult,
              let refreshedReceipt = refreshedResult.publicationReceipt
        else {
            return await failClosedAutomaticSelection(
                permits: [receipt.publicationPermit, refreshedResult?.publicationReceipt?.publicationPermit]
                    .compactMap(\.self),
                tickets: transfer.sources + partitionedRemainder.retained,
                deadline: deadline
            )
        }
        let leasedTickets = transfer.sources + partitionedRemainder.retained
        let store = store
        let lease = WorkspaceCodemapAutomaticSelectionPublicationLease {
            for ticket in leasedTickets {
                _ = await store.releaseReadyCodemapArtifactDemandRetain(ticket)
            }
        }
        let leasedReceipt = WorkspaceCodemapAutomaticSelectionPublicationReceipt(
            requestID: refreshedReceipt.requestID,
            rootScope: refreshedReceipt.rootScope,
            rootScopeEpochs: refreshedReceipt.rootScopeEpochs,
            sourceTickets: transfer.sources,
            graphKeys: refreshedReceipt.graphKeys,
            coverageProofs: refreshedReceipt.coverageProofs,
            targets: refreshedReceipt.targets,
            publicationBasis: refreshedReceipt.publicationBasis,
            publicationPermit: refreshedReceipt.publicationPermit,
            publicationLease: lease
        )
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: refreshedResult.roots,
            aggregateCoverage: refreshedResult.aggregateCoverage,
            publicationReceipt: leasedReceipt
        )
    }

    private func partitionAutomaticSelectionRemainder(
        _ tickets: [WorkspaceCodemapArtifactDemandTicket],
        for receipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt
    ) -> (retained: [WorkspaceCodemapArtifactDemandTicket], cancellable: [WorkspaceCodemapArtifactDemandTicket]) {
        guard case let .provisionalCandidates(candidates) = receipt.publicationBasis else {
            return (retained: [], cancellable: tickets)
        }
        var candidatesBySlot: [
            WorkspaceCodemapRootScopedFileSlot: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate
        ] = [:]
        for candidate in candidates {
            let slot = WorkspaceCodemapRootScopedFileSlot(candidate: candidate)
            guard candidatesBySlot[slot] == nil else {
                return (retained: [], cancellable: tickets)
            }
            candidatesBySlot[slot] = candidate
        }
        var targetsBySlot: [
            WorkspaceCodemapRootScopedFileSlot: WorkspaceCodemapAutomaticSelectionTarget
        ] = [:]
        for target in receipt.targets {
            let slot = WorkspaceCodemapRootScopedFileSlot(target: target)
            guard targetsBySlot[slot] == nil else {
                return (retained: [], cancellable: tickets)
            }
            targetsBySlot[slot] = target
        }

        var retained: [WorkspaceCodemapArtifactDemandTicket] = []
        var cancellable: [WorkspaceCodemapArtifactDemandTicket] = []
        for ticket in tickets {
            let slot = WorkspaceCodemapRootScopedFileSlot(ticket: ticket)
            if let target = targetsBySlot[slot],
               let candidate = candidatesBySlot[slot],
               ticket.requestGeneration == target.requestGeneration,
               ticket.catalogGeneration == target.catalogGeneration,
               ticket.requestGeneration == candidate.requestGeneration,
               ticket.catalogGeneration == candidate.catalogGeneration,
               ticket.pathGeneration == candidate.pathGeneration,
               ticket.ingressGeneration == candidate.ingressGeneration
            {
                retained.append(ticket)
            } else {
                cancellable.append(ticket)
            }
        }
        return (retained: retained, cancellable: cancellable)
    }

    private func automaticSelectionDeadlineIsCurrent(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) -> Bool {
        !Task.isCancelled && clock.now < deadline
    }

    private func failClosedAutomaticSelection(
        permits: [WorkspaceCodemapAutomaticSelectionPublicationPermit] = [],
        tickets: [WorkspaceCodemapArtifactDemandTicket],
        deadline: ContinuousClock.Instant
    ) async -> WorkspaceCodemapAutomaticSelectionResult {
        for permit in permits {
            permit.revoke()
        }
        for ticket in tickets {
            _ = await store.cancelCodemapArtifactDemand(ticket, deadline: deadline)
        }
        return WorkspaceCodemapAutomaticSelectionResult(
            roots: [],
            aggregateCoverage: .stale(.publicationReceipt)
        )
    }

    private func resolveAutomaticCodemapSelectionRetainingOwnership(
        sourceFileIDs: [UUID],
        rootScope: WorkspaceLookupRootScope,
        ownership: WorkspaceCodemapAutomaticSelectionDemandOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapAutomaticSelectionResult {
        try Task.checkCancellation()
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceFileIDs,
            rootScope: rootScope
        )
        try Task.checkCancellation()
        guard !identities.isEmpty else {
            return WorkspaceCodemapAutomaticSelectionResult(roots: [])
        }
        let sourceDemandLimit = await store.automaticCodemapSelectionSourceDemandLimit()
        try Task.checkCancellation()
        guard identities.count <= sourceDemandLimit else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .budget(.sourceLimit(
                    attempted: identities.count,
                    limit: sourceDemandLimit
                ))
            )
        }

        var sourceResults: [WorkspaceCodemapAutomaticSelectionSourceIdentity: WorkspaceCodemapArtifactDemandResult] = [:]
        var sourceTickets: [WorkspaceCodemapAutomaticSelectionSourceIdentity: WorkspaceCodemapArtifactDemandTicket] = [:]
        do {
            for source in identities {
                try Task.checkCancellation()
                let ownedResult = await store.requestCodemapArtifactWithOwnership(
                    forFileID: source.fileID,
                    priority: .demand
                )
                await ownership.record(ownedResult)
                let result = ownedResult.result
                sourceResults[source] = result
                sourceTickets[source] = ticket(from: result)
                try await automaticSelectionSourceDemandHook(source, result)
                try Task.checkCancellation()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
        var sourceAttempts: [WorkspaceCodemapAutomaticSelectionSourceIdentity: Int] = [:]
        for round in 0 ..< automaticSelectionPolicy.maximumReadinessRounds {
            try Task.checkCancellation()
            var busySources: [(WorkspaceCodemapAutomaticSelectionSourceIdentity, WorkspaceCodemapArtifactDemandTicket?, Int?)] = []
            var hasPending = false
            for source in identities {
                guard let current = sourceResults[source] else { continue }
                let refreshed: WorkspaceCodemapArtifactDemandResult = switch current {
                case let .pending(ticket): await store.codemapArtifactDemandStatus(ticket)
                case .ready, .unavailable: current
                }
                sourceResults[source] = refreshed
                switch refreshed {
                case .pending:
                    hasPending = true
                case let .unavailable(.busy(retryAfterMilliseconds)):
                    hasPending = true
                    busySources.append((source, sourceTickets[source], retryAfterMilliseconds))
                case .ready, .unavailable:
                    break
                }
            }
            if !hasPending || round + 1 == automaticSelectionPolicy.maximumReadinessRounds || clock.now >= deadline {
                break
            }
            guard try await waitForAutomaticSelectionRound(
                round: round,
                retryAfterMilliseconds: busySources.compactMap(\.2),
                clock: clock,
                deadline: deadline
            ) else { break }
            for (source, existingTicket, _) in busySources {
                sourceAttempts[source, default: 0] += 1
                let result: WorkspaceCodemapArtifactDemandResult
                if let existingTicket {
                    if await ownership.owns(existingTicket) {
                        result = await store.retryBusyCodemapArtifactDemand(
                            existingTicket,
                            priority: .demand
                        )
                        await ownership.recordCreatedResult(result)
                    } else {
                        result = sourceResults[source] ?? .unavailable(.busy(retryAfterMilliseconds: nil))
                    }
                } else {
                    let ownedResult = await store.requestCodemapArtifactWithOwnership(
                        forFileID: source.fileID,
                        priority: .demand
                    )
                    await ownership.record(ownedResult)
                    result = ownedResult.result
                }
                sourceResults[source] = result
                sourceTickets[source] = ticket(from: result)
            }
        }

        var readySources: [WorkspaceCodemapAutomaticSelectionSourceIdentity] = []
        var sourcePartialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        var sourcePendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for source in identities {
            guard let result = sourceResults[source] else { continue }
            switch result {
            case .ready:
                readySources.append(source)
            case let .pending(ticket):
                sourcePendingReasons.append(.sourceDemand(source, ticket))
                sourcePartialReasons.append(.sourceDemandTimedOut(source))
            case .unavailable(.busy):
                sourcePendingReasons.append(.sourceBusy(
                    source,
                    attempts: sourceAttempts[source, default: 0]
                ))
                sourcePartialReasons.append(.sourceDemandTimedOut(source))
            case let .unavailable(reason):
                sourcePartialReasons.append(.source(.unavailable(source, reason)))
            }
        }
        guard !readySources.isEmpty else {
            let coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage = sourcePendingReasons.isEmpty
                ? .unavailable(.noReadySources)
                : .pending(sourcePendingReasons)
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: coverage
            )
        }
        let allSourceRootEpochs = Set(identities.map(\.rootEpoch))
        let readySourceRootEpochs = Set(readySources.map(\.rootEpoch))
        guard readySourceRootEpochs == allSourceRootEpochs else {
            let coverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage =
                sourcePendingReasons.isEmpty
                    ? .unavailable(.noReadySources)
                    : .pending(sourcePendingReasons)
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: coverage
            )
        }

        let retainedSourceTickets = await ownership.tickets()
        let readySourceIDs = Set(readySources.map(\.fileID))
        let sourceTicketsByRoot = Dictionary(
            grouping: retainedSourceTickets.filter { readySourceIDs.contains($0.fileID) },
            by: \.rootEpoch
        )
        let projectionDeadline = projectionDeadlineUptimeNanoseconds(clock: clock, deadline: deadline)
        for rootEpoch in sourceTicketsByRoot.keys.sorted(by: workspaceCodemapRootEpochPrecedes) {
            let acquisition = await store.acquireCodemapProjectionDemand(
                sourceTickets: sourceTicketsByRoot[rootEpoch] ?? [],
                deadlineUptimeNanoseconds: projectionDeadline
            )
            if case let .acquired(ticket, _) = acquisition {
                await ownership.record(ticket)
            }
        }
        var candidatePlanDisposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition =
            .pending([])
        var provisionallyDemandedFileIDs = Set<UUID>()
        for round in 0 ..< automaticSelectionPolicy.maximumReadinessRounds {
            try Task.checkCancellation()
            candidatePlanDisposition = await store.planAutomaticCodemapSelectionCandidates(
                sources: readySources,
                rootScope: rootScope,
                maximumCandidateDemandCount: automaticSelectionPolicy.maximumCandidateDemandCount
            )
            if case let .provisional(provisional) = candidatePlanDisposition {
                for candidate in provisional.candidates
                    where !provisionallyDemandedFileIDs.contains(candidate.identity.fileID)
                {
                    guard let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                        candidate: candidate,
                        rootScope: rootScope,
                        rootScopeEpochs: provisional.rootScopeEpochs
                    ) else { continue }
                    await ownership.record(owned)
                    switch owned.result {
                    case .ready, .pending:
                        provisionallyDemandedFileIDs.insert(candidate.identity.fileID)
                    case .unavailable(.busy):
                        break
                    case .unavailable:
                        provisionallyDemandedFileIDs.insert(candidate.identity.fileID)
                    }
                }
            }
            guard automaticSelectionCandidatePlanDispositionShouldRetryForReadiness(candidatePlanDisposition),
                  round + 1 < automaticSelectionPolicy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            guard try await waitForAutomaticSelectionRound(
                round: round,
                retryAfterMilliseconds: [],
                clock: clock,
                deadline: deadline
            ) else { break }
        }
        candidatePlanDisposition = try await refreshCandidatePlanAfterGraphPublicationDrain(
            candidatePlanDisposition,
            readySources: readySources,
            rootScope: rootScope,
            clock: clock,
            deadline: deadline
        )
        let candidatePlan: WorkspaceCodemapAutomaticSelectionCandidatePlan
        switch candidatePlanDisposition {
        case let .ready(plan):
            candidatePlan = plan
        case let .provisional(plan):
            let provisionalDemand = try await settleProvisionalAutomaticCandidates(
                plan: plan,
                rootScope: rootScope,
                ownership: ownership,
                clock: clock,
                deadline: deadline
            )
            return await store.provisionalAutomaticCodemapSelectionResult(
                sources: readySources,
                plan: plan,
                readyCandidates: provisionalDemand.readyCandidates,
                pendingReasons: sourcePendingReasons + provisionalDemand.pendingReasons,
                partialReasons: sourcePartialReasons + provisionalDemand.partialReasons,
                rootScope: rootScope
            )
        case let .incomplete(reasons):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .incomplete(reasons)
            )
        case let .pending(reasons):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .pending(reasons)
            )
        case let .busy(reason):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .busy(reason)
            )
        case let .unavailable(reason):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable(reason)
            )
        case let .stale(reason):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .stale(reason)
            )
        case let .budget(reason):
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .budget(reason)
            )
        }

        var candidateResults: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var candidateTickets: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        for candidate in candidatePlan.candidates {
            let fileID = candidate.identity.fileID
            guard let ownedResult = await store.requestAutomaticCodemapArtifactWithOwnership(
                candidate: candidate,
                rootScope: rootScope,
                rootScopeEpochs: candidatePlan.rootScopeEpochs,
                coverageProofs: candidatePlan.coverageProofs
            ) else {
                let rootEpoch = WorkspaceCodemapRootEpoch(
                    rootID: candidate.identity.rootID,
                    rootLifetimeID: candidate.identity.rootLifetimeID
                )
                return WorkspaceCodemapAutomaticSelectionResult(
                    roots: [],
                    aggregateCoverage: .stale(.coverageProof(rootEpoch))
                )
            }
            await ownership.record(ownedResult)
            let result = ownedResult.result
            candidateResults[fileID] = result
            candidateTickets[fileID] = ticket(from: result)
        }
        var candidateAttempts: [UUID: Int] = [:]
        for round in 0 ..< automaticSelectionPolicy.maximumReadinessRounds {
            try Task.checkCancellation()
            var busyCandidates: [(UUID, WorkspaceCodemapArtifactDemandTicket?, Int?)] = []
            var hasPending = false
            for candidate in candidatePlan.candidates {
                let fileID = candidate.identity.fileID
                guard let current = candidateResults[fileID] else { continue }
                let refreshed: WorkspaceCodemapArtifactDemandResult = switch current {
                case let .pending(ticket): await store.codemapArtifactDemandStatus(ticket)
                case .ready, .unavailable: current
                }
                candidateResults[fileID] = refreshed
                switch refreshed {
                case .pending:
                    hasPending = true
                case let .unavailable(.busy(retryAfterMilliseconds)):
                    hasPending = true
                    busyCandidates.append((fileID, candidateTickets[fileID], retryAfterMilliseconds))
                case .ready, .unavailable:
                    break
                }
            }
            if !hasPending || round + 1 == automaticSelectionPolicy.maximumReadinessRounds || clock.now >= deadline {
                break
            }
            guard try await waitForAutomaticSelectionRound(
                round: round,
                retryAfterMilliseconds: busyCandidates.compactMap(\.2),
                clock: clock,
                deadline: deadline
            ) else { break }
            for (fileID, existingTicket, _) in busyCandidates {
                candidateAttempts[fileID, default: 0] += 1
                let result: WorkspaceCodemapArtifactDemandResult
                guard let candidate = candidatePlan.candidates.first(where: {
                    $0.identity.fileID == fileID
                }) else {
                    return WorkspaceCodemapAutomaticSelectionResult(
                        roots: [],
                        aggregateCoverage: .stale(.publicationReceipt)
                    )
                }
                if let existingTicket {
                    if await ownership.owns(existingTicket) {
                        guard let ownedResult = await store.retryBusyAutomaticCodemapArtifactDemand(
                            existingTicket,
                            candidate: candidate,
                            rootScope: rootScope,
                            rootScopeEpochs: candidatePlan.rootScopeEpochs,
                            coverageProofs: candidatePlan.coverageProofs
                        ) else {
                            let rootEpoch = WorkspaceCodemapRootEpoch(
                                rootID: candidate.identity.rootID,
                                rootLifetimeID: candidate.identity.rootLifetimeID
                            )
                            return WorkspaceCodemapAutomaticSelectionResult(
                                roots: [],
                                aggregateCoverage: .stale(.coverageProof(rootEpoch))
                            )
                        }
                        await ownership.record(ownedResult)
                        result = ownedResult.result
                    } else {
                        result = candidateResults[fileID] ?? .unavailable(.busy(retryAfterMilliseconds: nil))
                    }
                } else {
                    guard let ownedResult = await store.requestAutomaticCodemapArtifactWithOwnership(
                        candidate: candidate,
                        rootScope: rootScope,
                        rootScopeEpochs: candidatePlan.rootScopeEpochs,
                        coverageProofs: candidatePlan.coverageProofs
                    ) else {
                        let rootEpoch = WorkspaceCodemapRootEpoch(
                            rootID: candidate.identity.rootID,
                            rootLifetimeID: candidate.identity.rootLifetimeID
                        )
                        return WorkspaceCodemapAutomaticSelectionResult(
                            roots: [],
                            aggregateCoverage: .stale(.coverageProof(rootEpoch))
                        )
                    }
                    await ownership.record(ownedResult)
                    result = ownedResult.result
                }
                candidateResults[fileID] = result
                candidateTickets[fileID] = ticket(from: result)
            }
        }

        var candidatePendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in candidatePlan.candidates {
            let fileID = candidate.identity.fileID
            guard let result = candidateResults[fileID] else { continue }
            switch result {
            case .ready:
                break
            case let .pending(ticket):
                candidatePendingReasons.append(.candidateDemand(
                    rootEpoch: ticket.rootEpoch,
                    fileID: fileID,
                    ticket: ticket
                ))
            case .unavailable(.busy):
                candidatePendingReasons.append(.candidateBusy(
                    rootEpoch: WorkspaceCodemapRootEpoch(
                        rootID: candidate.identity.rootID,
                        rootLifetimeID: candidate.identity.rootLifetimeID
                    ),
                    fileID: fileID,
                    attempts: candidateAttempts[fileID, default: 0]
                ))
            case let .unavailable(reason):
                return WorkspaceCodemapAutomaticSelectionResult(
                    roots: [],
                    aggregateCoverage: .unavailable(.candidate(
                        rootEpoch: WorkspaceCodemapRootEpoch(
                            rootID: candidate.identity.rootID,
                            rootLifetimeID: candidate.identity.rootLifetimeID
                        ),
                        fileID: fileID,
                        reason: reason
                    ))
                )
            }
        }
        if !candidatePendingReasons.isEmpty {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .pending(candidatePendingReasons)
            )
        }

        let candidateRootEpochs = Set(candidatePlan.candidates.map {
            WorkspaceCodemapRootEpoch(
                rootID: $0.identity.rootID,
                rootLifetimeID: $0.identity.rootLifetimeID
            )
        })
        let finalGraphDrainRootEpochs = Set(readySources.map(\.rootEpoch)).union(candidateRootEpochs)
        guard try await drainAutomaticSelectionGraphPublications(
            rootEpochs: finalGraphDrainRootEpochs,
            clock: clock,
            deadline: deadline
        ) else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .pending(
                    finalGraphDrainRootEpochs
                        .sorted(by: workspaceCodemapRootEpochPrecedes)
                        .map { .graphRebuild(rootEpoch: $0) }
                )
            )
        }

        var result = try await store.resolveAutomaticCodemapSelection(
            sources: readySources,
            rootScope: rootScope
        )
        for round in 1 ..< automaticSelectionPolicy.maximumReadinessRounds {
            guard automaticSelectionAggregateCoverageShouldRetryForReadiness(result.aggregateCoverage),
                  clock.now < deadline
            else { break }
            guard try await waitForAutomaticSelectionRound(
                round: round,
                retryAfterMilliseconds: [],
                clock: clock,
                deadline: deadline
            ) else { break }
            if automaticSelectionAggregateCoverageIsTransientGraphReadiness(result.aggregateCoverage) {
                let rootEpochs = Set(readySources.map(\.rootEpoch)).union(candidateRootEpochs)
                guard try await drainAutomaticSelectionGraphPublications(
                    rootEpochs: rootEpochs,
                    clock: clock,
                    deadline: deadline
                ) else { break }
            }
            result = try await store.resolveAutomaticCodemapSelection(
                sources: readySources,
                rootScope: rootScope
            )
        }
        switch result.aggregateCoverage {
        case let .complete(proofs):
            guard !sourcePartialReasons.isEmpty else { return result }
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .partial(proofs: proofs, reasons: sourcePartialReasons)
            )
        case .provisional:
            return result
        case .partial, .incomplete, .pending, .unavailable, .stale, .busy, .budget:
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: result.aggregateCoverage
            )
        }
    }

    private func refreshCandidatePlanAfterGraphPublicationDrain(
        _ disposition: WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition,
        readySources: [WorkspaceCodemapAutomaticSelectionSourceIdentity],
        rootScope: WorkspaceLookupRootScope,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapAutomaticSelectionCandidatePlanDisposition {
        guard automaticSelectionCandidatePlanDispositionIsTransientGraphReadiness(disposition),
              automaticSelectionDeadlineIsCurrent(clock: clock, deadline: deadline)
        else { return disposition }

        let rootEpochs = Set(readySources.map(\.rootEpoch))
        guard try await drainAutomaticSelectionGraphPublications(
            rootEpochs: rootEpochs,
            clock: clock,
            deadline: deadline
        ) else { return disposition }
        return await store.planAutomaticCodemapSelectionCandidates(
            sources: readySources,
            rootScope: rootScope,
            maximumCandidateDemandCount: automaticSelectionPolicy.maximumCandidateDemandCount
        )
    }

    private func drainAutomaticSelectionGraphPublications(
        rootEpochs: Set<WorkspaceCodemapRootEpoch>,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        guard !rootEpochs.isEmpty else { return true }
        for rootEpoch in rootEpochs.sorted(by: workspaceCodemapRootEpochPrecedes) {
            try Task.checkCancellation()
            guard clock.now < deadline else { return false }
            let publicationCurrent = await store.waitForCodemapGraphPublication(
                rootEpoch: rootEpoch,
                deadline: deadline
            )
            try Task.checkCancellation()
            guard publicationCurrent, clock.now < deadline else { return false }
        }
        try Task.checkCancellation()
        return clock.now < deadline
    }

    private func settleProvisionalAutomaticCandidates(
        plan: WorkspaceCodemapAutomaticSelectionProvisionalCandidatePlan,
        rootScope: WorkspaceLookupRootScope,
        ownership: WorkspaceCodemapAutomaticSelectionDemandOwnership,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> WorkspaceCodemapAutomaticSelectionProvisionalCandidateDemandBatch {
        var candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var seen = Set<UUID>()
        for candidate in plan.candidates.sorted(by: automaticSelectionCandidatePrecedes)
            where seen.insert(candidate.identity.fileID).inserted
        {
            candidates.append(candidate)
        }

        var results: [UUID: WorkspaceCodemapArtifactDemandResult] = [:]
        var ticketsByFileID: [UUID: WorkspaceCodemapArtifactDemandTicket] = [:]
        var attemptsByFileID: [UUID: Int] = [:]
        var partialReasons: [WorkspaceCodemapAutomaticSelectionPartialReason] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                candidate: candidate,
                rootScope: rootScope,
                rootScopeEpochs: plan.rootScopeEpochs
            ) else {
                // Ownership acquisition only reports nil here; staleCurrentness is the conservative provisional catch-all.
                partialReasons.append(.candidateUnavailable(
                    rootEpoch: candidate.rootEpoch,
                    fileID: candidate.identity.fileID,
                    reason: .staleCurrentness
                ))
                continue
            }
            await ownership.record(owned)
            results[candidate.identity.fileID] = owned.result
            ticketsByFileID[candidate.identity.fileID] = ticket(from: owned.result)
        }

        for round in 0 ..< automaticSelectionPolicy.maximumReadinessRounds {
            try Task.checkCancellation()
            var busyCandidates: [(WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate, WorkspaceCodemapArtifactDemandTicket?, Int?)] = []
            var hasPending = false
            for candidate in candidates {
                let fileID = candidate.identity.fileID
                guard let current = results[fileID] else { continue }
                let refreshed: WorkspaceCodemapArtifactDemandResult = switch current {
                case let .pending(ticket): await store.codemapArtifactDemandStatus(ticket)
                case .ready, .unavailable: current
                }
                results[fileID] = refreshed
                switch refreshed {
                case .pending:
                    hasPending = true
                case let .unavailable(.busy(retryAfterMilliseconds)):
                    hasPending = true
                    busyCandidates.append((candidate, ticketsByFileID[fileID], retryAfterMilliseconds))
                case .ready, .unavailable:
                    break
                }
            }
            guard hasPending,
                  round + 1 < automaticSelectionPolicy.maximumReadinessRounds,
                  clock.now < deadline
            else { break }
            guard try await waitForAutomaticSelectionRound(
                round: round,
                retryAfterMilliseconds: busyCandidates.compactMap(\.2),
                clock: clock,
                deadline: deadline
            ) else { break }
            for (candidate, existingTicket, _) in busyCandidates {
                let fileID = candidate.identity.fileID
                attemptsByFileID[fileID, default: 0] += 1
                let result: WorkspaceCodemapArtifactDemandResult
                if let existingTicket, await ownership.owns(existingTicket) {
                    result = await store.retryBusyCodemapArtifactDemand(
                        existingTicket,
                        priority: .background
                    )
                    await ownership.recordCreatedResult(result)
                } else if let owned = await store.requestProvisionalAutomaticCodemapArtifactWithOwnership(
                    candidate: candidate,
                    rootScope: rootScope,
                    rootScopeEpochs: plan.rootScopeEpochs
                ) {
                    await ownership.record(owned)
                    result = owned.result
                } else {
                    // Ownership reacquisition only reports nil here; staleCurrentness is the conservative catch-all.
                    result = .unavailable(.staleCurrentness)
                }
                results[fileID] = result
                ticketsByFileID[fileID] = ticket(from: result)
            }
        }

        var readyCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var pendingReasons: [WorkspaceCodemapAutomaticSelectionPendingReason] = []
        for candidate in candidates {
            let fileID = candidate.identity.fileID
            guard let result = results[fileID] else { continue }
            let rootEpoch = candidate.rootEpoch
            switch result {
            case .ready:
                readyCandidates.append(candidate)
            case let .pending(ticket):
                pendingReasons.append(.candidateDemand(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    ticket: ticket
                ))
            case .unavailable(.busy):
                pendingReasons.append(.candidateBusy(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    attempts: attemptsByFileID[fileID, default: 0]
                ))
            case let .unavailable(reason):
                partialReasons.append(.candidateUnavailable(
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    reason: reason
                ))
            }
        }
        pendingReasons.sort(by: automaticSelectionPendingReasonPrecedes)
        partialReasons.sort(by: automaticSelectionPartialReasonPrecedes)
        return WorkspaceCodemapAutomaticSelectionProvisionalCandidateDemandBatch(
            readyCandidates: readyCandidates,
            pendingReasons: pendingReasons,
            partialReasons: partialReasons
        )
    }

    private func ticket(
        from result: WorkspaceCodemapArtifactDemandResult
    ) -> WorkspaceCodemapArtifactDemandTicket? {
        switch result {
        case let .pending(ticket): ticket
        case let .ready(ready): ready.ticket
        case .unavailable: nil
        }
    }

    private func waitForAutomaticSelectionRound(
        round: Int,
        retryAfterMilliseconds: [Int],
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        try Task.checkCancellation()
        let exponential = automaticSelectionPolicy.initialBackoffMilliseconds << min(round, 3)
        let suggested = retryAfterMilliseconds.max() ?? exponential
        let milliseconds = min(
            automaticSelectionPolicy.maximumBackoffMilliseconds,
            max(automaticSelectionPolicy.initialBackoffMilliseconds, suggested)
        )
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        try await automaticSelectionWaiter.sleep(min(.milliseconds(milliseconds), remaining))
        try Task.checkCancellation()
        return clock.now < deadline
    }

    private func projectionDeadlineUptimeNanoseconds(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) -> UInt64 {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return DispatchTime.now().uptimeNanoseconds }
        let components = remaining.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return DispatchTime.now().uptimeNanoseconds
        }
        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        let (secondNanoseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (combinedNanoseconds, combinedOverflow) = secondNanoseconds.addingReportingOverflow(
            attoseconds / 1_000_000_000
        )
        let remainingNanoseconds = secondsOverflow || combinedOverflow ? UInt64.max : combinedNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        let (value, overflow) = now.addingReportingOverflow(remainingNanoseconds)
        return overflow ? UInt64.max : value
    }

    private func orderedInputs(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }

    private func rawLookup(_ rawPaths: [String]) -> [String: String] {
        var lookup: [String: String] = [:]
        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, lookup[trimmed] == nil else { continue }
            lookup[trimmed] = raw
        }
        return lookup
    }

    private func normalizeSlices(_ slices: [String: [LineRange]]) -> [String: [LineRange]] {
        var normalized: [String: [LineRange]] = [:]
        for (path, ranges) in slices {
            let value = SliceRangeMath.normalize(ranges)
            if !value.isEmpty { normalized[path] = value }
        }
        return normalized
    }

    private func removeSliceEntries(for file: WorkspaceFileRecord, in slices: inout [String: [LineRange]]) -> Bool {
        var mutated = false
        let variants = [file.standardizedFullPath, file.fullPath, file.relativePath]
        for key in variants where slices.removeValue(forKey: key) != nil {
            mutated = true
        }
        let matchingKeys = slices.keys.filter { StoredSelectionPathNormalization.standardizedPath($0) == file.standardizedFullPath }
        for key in matchingKeys {
            slices.removeValue(forKey: key)
            mutated = true
        }
        return mutated
    }

    private func supportsCodemap(_ file: WorkspaceFileRecord) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return SyntaxManager.supportsCodeMap(fileExtension: ext)
    }

    private func displayPath(for file: WorkspaceFileRecord, rootScope: WorkspaceLookupRootScope) async -> String {
        let roots = await store.rootRefs(scope: rootScope)
        guard let root = roots.first(where: { $0.id == file.rootID }) else { return file.standardizedFullPath }
        return ClientPathFormatter.displayPath(root: root, relativePath: file.standardizedRelativePath, visibleRoots: roots)
    }
}
