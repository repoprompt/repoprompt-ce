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
    private var retainedTargetTickets = Set<WorkspaceCodemapArtifactDemandTicket>()

    func record(_ ownedResult: WorkspaceCodemapArtifactDemandOwnedResult) {
        switch ownedResult.ownership {
        case let .created(ticket), let .joined(ticket):
            retainedTargetTickets.insert(ticket)
        case .notAcquired:
            break
        }
    }

    func drainRetainedTickets() -> [WorkspaceCodemapArtifactDemandTicket] {
        defer { retainedTargetTickets.removeAll() }
        return Array(retainedTargetTickets)
    }
}

struct WorkspaceSelectionMutationService {
    let store: WorkspaceFileContextStore
    let codemapsGloballyDisabled: Bool
    let codemapsGloballyDisabledMessage: String
    let automaticSelectionPolicy: WorkspaceCodemapAutomaticSelectionRequestPolicy
    let automaticSelectionWaiter: WorkspaceCodemapAutomaticSelectionWaiter

    init(
        store: WorkspaceFileContextStore,
        codemapsGloballyDisabled: Bool = false,
        codemapsGloballyDisabledMessage: String = "Code maps are disabled for this tool.",
        automaticSelectionPolicy: WorkspaceCodemapAutomaticSelectionRequestPolicy = .default,
        automaticSelectionWaiter: WorkspaceCodemapAutomaticSelectionWaiter = .production
    ) {
        self.store = store
        self.codemapsGloballyDisabled = codemapsGloballyDisabled
        self.codemapsGloballyDisabledMessage = codemapsGloballyDisabledMessage
        self.automaticSelectionPolicy = automaticSelectionPolicy
        self.automaticSelectionWaiter = automaticSelectionWaiter
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
        let identities = await store.codemapAutomaticSelectionSourceIdentities(
            forFileIDs: sourceFileIDs,
            rootScope: rootScope
        )
        guard !identities.isEmpty else {
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([.emptySources])
            )
        }
        let sourceLimit = await store.automaticCodemapSelectionSourceLimit()
        guard identities.count <= sourceLimit else {
            let issue = WorkspaceCodemapAutomaticSelectionIssue.budget(.sourceLimit(
                attempted: identities.count,
                limit: sourceLimit
            ))
            return WorkspaceCodemapAutomaticSelectionResult(
                roots: [],
                aggregateCoverage: .unavailable([issue])
            )
        }

        let ownership = WorkspaceCodemapAutomaticSelectionDemandOwnership()
        do {
            var result = try await store.resolveAutomaticCodemapSelection(
                sources: identities,
                rootScope: rootScope
            )
            guard let receipt = result.receipt, !result.targets.isEmpty else { return result }

            let initialRevalidation = await store.revalidateAutomaticCodemapSelection(
                receipt,
                rootScope: rootScope
            )
            let initiallyValid = Set(initialRevalidation.validTargets)
            var resultsByTarget: [WorkspaceCodemapAutomaticSelectionTarget: WorkspaceCodemapArtifactDemandResult] = [:]
            var ticketsByTarget: [WorkspaceCodemapAutomaticSelectionTarget: WorkspaceCodemapArtifactDemandTicket] = [:]
            let rootReceiptByEpoch = Dictionary(uniqueKeysWithValues: receipt.roots.map { ($0.rootEpoch, $0) })
            for target in result.targets where initiallyValid.contains(target) {
                try Task.checkCancellation()
                guard let rootReceipt = rootReceiptByEpoch[target.rootEpoch],
                      let owned = await store.requestAutomaticCodemapTargetWithOwnership(
                          target: target,
                          rootReceipt: rootReceipt,
                          rootScope: rootScope,
                          priority: .background
                      )
                else {
                    resultsByTarget[target] = .unavailable(.staleCurrentness)
                    continue
                }
                await ownership.record(owned)
                switch owned.ownership {
                case let .created(ticket), let .joined(ticket):
                    ticketsByTarget[target] = ticket
                case .notAcquired:
                    break
                }
                resultsByTarget[target] = owned.result
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: automaticSelectionPolicy.maximumTotalWait)
            for round in 0 ..< automaticSelectionPolicy.maximumReadinessRounds {
                try Task.checkCancellation()
                var waiting = false
                var retryAfter: [Int] = []
                for (target, current) in resultsByTarget {
                    let refreshed: WorkspaceCodemapArtifactDemandResult = switch current {
                    case let .pending(ticket):
                        await store.codemapArtifactDemandStatus(ticket)
                    case .ready, .unavailable:
                        current
                    }
                    resultsByTarget[target] = refreshed
                    switch refreshed {
                    case .pending:
                        waiting = true
                    case let .unavailable(.busy(milliseconds)):
                        waiting = true
                        if let milliseconds { retryAfter.append(milliseconds) }
                    case .ready, .unavailable:
                        break
                    }
                }
                guard waiting,
                      round + 1 < automaticSelectionPolicy.maximumReadinessRounds,
                      clock.now < deadline
                else { break }
                try await waitForAutomaticSelectionReadiness(
                    round: round,
                    suggestedMilliseconds: retryAfter,
                    clock: clock,
                    deadline: deadline
                )
                for (target, current) in resultsByTarget {
                    guard case .unavailable(.busy) = current,
                          let rootReceipt = rootReceiptByEpoch[target.rootEpoch]
                    else { continue }
                    if let priorTicket = ticketsByTarget.removeValue(forKey: target) {
                        _ = await store.cancelCodemapArtifactDemand(priorTicket)
                    }
                    if let owned = await store.requestAutomaticCodemapTargetWithOwnership(
                        target: target,
                        rootReceipt: rootReceipt,
                        rootScope: rootScope,
                        priority: .background
                    ) {
                        await ownership.record(owned)
                        switch owned.ownership {
                        case let .created(ticket), let .joined(ticket):
                            ticketsByTarget[target] = ticket
                        case .notAcquired:
                            break
                        }
                        resultsByTarget[target] = owned.result
                    }
                }
            }

            let finalRevalidation = await store.revalidateAutomaticCodemapSelection(
                receipt,
                rootScope: rootScope
            )
            let finallyValid = Set(finalRevalidation.validTargets)
            let readyTargets = Set(resultsByTarget.compactMap { target, demand -> WorkspaceCodemapAutomaticSelectionTarget? in
                guard finallyValid.contains(target), case .ready = demand else { return nil }
                return target
            })
            let invalidIssuesByRoot = Dictionary(grouping: finalRevalidation.issues) { issue -> WorkspaceCodemapRootEpoch? in
                switch issue {
                case let .rootEpochChanged(rootEpoch), let .graphNotInitialized(rootEpoch),
                     let .updatesPending(rootEpoch), let .reconciling(rootEpoch),
                     let .graphUnavailable(rootEpoch), let .graphRevoked(rootEpoch, _),
                     let .receiptInvalid(rootEpoch, _):
                    rootEpoch
                case let .targetNotCataloged(rootEpoch, _), let .targetGenerationChanged(rootEpoch, _),
                     let .targetLogicalPathUnavailable(rootEpoch, _), let .targetDemandPending(rootEpoch, _),
                     let .targetDemandUnavailable(rootEpoch, _, _):
                    rootEpoch
                case let .sourceOutsideRootScope(source), let .sourceNotCataloged(source),
                     let .sourcePending(source), let .sourceNotIndexed(source),
                     let .sourceExcluded(source), let .sourceFenced(source),
                     let .sourceGenerationChanged(source, _):
                    source.rootEpoch
                case .emptySources, .rootScopeChanged, .budget:
                    nil
                }
            }

            let roots = result.roots.map { root -> WorkspaceCodemapAutomaticSelectionRootResult in
                var issues = root.issues + (invalidIssuesByRoot[root.rootEpoch] ?? [])
                for target in root.targets {
                    guard let demand = resultsByTarget[target] else { continue }
                    switch demand {
                    case .ready:
                        break
                    case .pending:
                        issues.append(.targetDemandPending(
                            rootEpoch: target.rootEpoch,
                            fileID: target.fileID
                        ))
                    case let .unavailable(reason):
                        issues.append(.targetDemandUnavailable(
                            rootEpoch: target.rootEpoch,
                            fileID: target.fileID,
                            reason: reason
                        ))
                    }
                }
                issues = issues.reduce(into: []) { unique, issue in
                    if !unique.contains(issue) { unique.append(issue) }
                }.sorted(by: automaticSelectionIssuePrecedes)
                let targets = root.targets.filter { readyTargets.contains($0) }
                let hasPendingDemand = issues.contains { issue in
                    if case .targetDemandPending = issue { return true }
                    return false
                }
                let status: WorkspaceCodemapAutomaticSelectionStatus = if !targets.isEmpty {
                    issues.isEmpty ? .ok : .partial
                } else if hasPendingDemand || root.status == .pending {
                    .pending
                } else {
                    .unavailable
                }
                let rootReceipt = root.receipt.map {
                    WorkspaceCodemapAutomaticSelectionRootReceipt(
                        rootEpoch: $0.rootEpoch,
                        graphReceipt: $0.graphReceipt,
                        sources: $0.sources,
                        targets: $0.targets.filter { readyTargets.contains($0) }
                    )
                }
                return WorkspaceCodemapAutomaticSelectionRootResult(
                    rootEpoch: root.rootEpoch,
                    status: status,
                    targets: targets,
                    sources: root.sources,
                    issues: issues,
                    coverage: root.coverage,
                    graphTargetCount: root.graphTargetCount,
                    graphResolutionCount: root.graphResolutionCount,
                    graphReferenceFailureCount: root.graphReferenceFailureCount,
                    graphByteCount: root.graphByteCount,
                    receipt: rootReceipt
                )
            }
            let receiptRoots = roots.compactMap { root -> WorkspaceCodemapAutomaticSelectionRootReceipt? in
                guard !root.targets.isEmpty else { return nil }
                return root.receipt
            }
            let finalReceipt = receiptRoots.isEmpty ? nil : WorkspaceCodemapAutomaticSelectionReceipt(
                rootScope: receipt.rootScope,
                rootScopeEpochs: receipt.rootScopeEpochs,
                roots: receiptRoots
            )
            result = WorkspaceCodemapAutomaticSelectionResult(roots: roots, receipt: finalReceipt)
            await releaseAutomaticSelectionOwnership(ownership)
            return result
        } catch {
            await releaseAutomaticSelectionOwnership(ownership)
            throw error
        }
    }

    private func waitForAutomaticSelectionReadiness(
        round: Int,
        suggestedMilliseconds: [Int],
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws {
        let shift = min(round, 20)
        let exponential = automaticSelectionPolicy.initialBackoffMilliseconds << shift
        let bounded = min(automaticSelectionPolicy.maximumBackoffMilliseconds, exponential)
        let suggested = suggestedMilliseconds.max() ?? 0
        let milliseconds = max(bounded, suggested)
        let proposed = Duration.milliseconds(milliseconds)
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return }
        try await automaticSelectionWaiter.sleep(min(proposed, remaining))
    }

    private func releaseAutomaticSelectionOwnership(
        _ ownership: WorkspaceCodemapAutomaticSelectionDemandOwnership
    ) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        for ticket in await ownership.drainRetainedTickets() {
            _ = await store.cancelCodemapArtifactDemand(ticket, deadline: deadline)
        }
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

    private func removeSliceEntries(
        for file: WorkspaceFileRecord,
        in slices: inout [String: [LineRange]]
    ) -> Bool {
        var mutated = false
        let variants = [file.standardizedFullPath, file.fullPath, file.relativePath]
        for key in variants where slices.removeValue(forKey: key) != nil {
            mutated = true
        }
        let matchingKeys = slices.keys.filter {
            StoredSelectionPathNormalization.standardizedPath($0) == file.standardizedFullPath
        }
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

    private func displayPath(
        for file: WorkspaceFileRecord,
        rootScope: WorkspaceLookupRootScope
    ) async -> String {
        let roots = await store.rootRefs(scope: rootScope)
        guard let root = roots.first(where: { $0.id == file.rootID }) else {
            return file.standardizedFullPath
        }
        return ClientPathFormatter.displayPath(
            root: root,
            relativePath: file.standardizedRelativePath,
            visibleRoots: roots
        )
    }
}
