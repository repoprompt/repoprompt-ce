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

struct WorkspaceSelectionMutationService {
    let store: WorkspaceFileContextStore
    let codemapsGloballyDisabled: Bool
    let codemapsGloballyDisabledMessage: String

    init(
        store: WorkspaceFileContextStore,
        codemapsGloballyDisabled: Bool = false,
        codemapsGloballyDisabledMessage: String = "Code maps are disabled for this tool."
    ) {
        self.store = store
        self.codemapsGloballyDisabled = codemapsGloballyDisabled
        self.codemapsGloballyDisabledMessage = codemapsGloballyDisabledMessage
    }

    func buildSelection(
        paths: [String],
        slices sliceInputs: [WorkspaceSelectionSliceInput] = [],
        sliceErrors: [String] = [],
        mode: String,
        existing: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceBuildSelectionResult {
        if mode == "codemap_only", codemapsGloballyDisabled {
            return WorkspaceBuildSelectionResult(
                selection: existing,
                invalidPaths: sliceErrors + [codemapsGloballyDisabledMessage],
                codemapUnavailable: []
            )
        }

        var invalid = sliceErrors
        var codemapUnavailable: [String] = []
        var selectedPaths: [String] = []
        var codemapPaths: [String] = []
        var seenSelected = Set<String>()
        var seenCodemap = Set<String>()
        var slicesByPath: [String: [LineRange]] = [:]

        if mode == "codemap_only" {
            let resolution = await resolveCodemapOnlyCandidates(paths: paths, rawPaths: paths, expandFolders: true, rootScope: rootScope)
            invalid.append(contentsOf: resolution.invalidPaths)
            codemapUnavailable.append(contentsOf: resolution.codemapUnavailable)
            for file in resolution.candidates where seenCodemap.insert(file.standardizedFullPath).inserted {
                codemapPaths.append(file.standardizedFullPath)
            }
        } else {
            let resolution = await resolveSelectionCandidates(paths: paths, rawPaths: paths, expandFolders: true, rootScope: rootScope)
            invalid.append(contentsOf: resolution.invalidPaths)
            for file in resolution.candidates where seenSelected.insert(file.standardizedFullPath).inserted {
                selectedPaths.append(file.standardizedFullPath)
            }
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

        var finalCodemapPaths = existing.autoCodemapPaths
        if !selectedPaths.isEmpty {
            let selectedSet = Set(selectedPaths)
            finalCodemapPaths.removeAll { selectedSet.contains($0) }
        }

        let autoEnabled = mode == "codemap_only" ? false : existing.codemapAutoEnabled
        let initialCodemapPaths: [String] = if mode == "codemap_only" {
            codemapPaths
        } else if autoEnabled {
            []
        } else {
            finalCodemapPaths
        }

        var selection = StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: initialCodemapPaths,
            slices: slicesByPath,
            codemapAutoEnabled: autoEnabled
        )
        if selection.codemapAutoEnabled {
            selection = await recomputeAutoCodemaps(selection, rootScope: rootScope)
        }
        return WorkspaceBuildSelectionResult(selection: selection, invalidPaths: invalid, codemapUnavailable: codemapUnavailable)
    }

    func buildManageSelectionSet(
        paths: [String],
        slices sliceInputs: [WorkspaceSelectionSliceInput] = [],
        sliceErrors: [String] = [],
        mode: String,
        existing: StoredSelection,
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

        let isSliceScopedSet = mode == "slices" || (paths.isEmpty && !sliceInputs.isEmpty)
        guard isSliceScopedSet else {
            return await buildSelection(
                paths: paths,
                slices: sliceInputs,
                sliceErrors: sliceErrors,
                mode: mode,
                existing: StoredSelection(),
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
        let baseCodemapPaths = StoredSelectionPathNormalization.standardizedPaths(base.autoCodemapPaths)
        var slices = originalSlices
        var selectedPaths = baseSelectedPaths
        var selectedSet = Set(selectedPaths)
        var codemapPaths = baseCodemapPaths

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
        let selectedStd = Set(selectedPaths)
        codemapPaths.removeAll { selectedStd.contains($0) }

        var nextSelection = StoredSelection(selectedPaths: selectedPaths, autoCodemapPaths: codemapPaths, slices: slices, codemapAutoEnabled: base.codemapAutoEnabled)
        let mutated = slices != originalSlices || selectedPaths != baseSelectedPaths || codemapPaths != baseCodemapPaths
        if mutated, nextSelection.codemapAutoEnabled {
            nextSelection = await recomputeAutoCodemaps(nextSelection, rootScope: rootScope)
        }
        return WorkspaceSliceSelectionMutationResult(selection: nextSelection, invalidPaths: invalid, resolvedMap: resolved, mutated: mutated)
    }

    func addPaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceAddSelectionResult {
        let codemapOnly = mode == "codemap_only"
        if codemapOnly, codemapsGloballyDisabled {
            return WorkspaceAddSelectionResult(selection: existing, invalidPaths: [codemapsGloballyDisabledMessage], resolvedMap: [:], mutated: false, codemapUnavailable: [])
        }
        let candidateResolutionTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.candidateResolutionTotal)
        let resolution: (files: [WorkspaceFileRecord], invalid: [String], resolvedMap: [String: String], unavailable: [String])
        if codemapOnly {
            let value = await resolveCodemapOnlyCandidates(paths: paths, rawPaths: rawPaths, expandFolders: true, rootScope: rootScope)
            resolution = (value.candidates, value.invalidPaths, value.resolvedMap, value.codemapUnavailable)
        } else {
            let value = await resolveSelectionCandidates(paths: paths, rawPaths: rawPaths, expandFolders: true, rootScope: rootScope)
            resolution = (value.candidates, value.invalidPaths, value.resolvedMap, [])
        }
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.candidateResolutionTotal, candidateResolutionTotal)

        let structuralMerge = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.structuralMerge)
        var selectedPaths = existing.selectedPaths
        var codemapPaths = existing.autoCodemapPaths
        var slices = existing.slices
        var selectedSet = Set(selectedPaths)
        var codemapSet = Set(codemapPaths)
        var mutated = false

        for file in resolution.files {
            let path = file.standardizedFullPath
            if codemapOnly {
                if selectedSet.contains(path) {
                    selectedPaths.removeAll { $0 == path }
                    selectedSet.remove(path)
                    mutated = true
                }
                if !codemapSet.contains(path) {
                    codemapPaths.append(path)
                    codemapSet.insert(path)
                    mutated = true
                }
                if removeSliceEntries(for: file, in: &slices) { mutated = true }
            } else {
                if !selectedSet.contains(path) {
                    selectedPaths.append(path)
                    selectedSet.insert(path)
                    mutated = true
                }
                if codemapSet.contains(path) {
                    codemapPaths.removeAll { $0 == path }
                    codemapSet.remove(path)
                    mutated = true
                }
            }
        }

        var selection = StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: codemapPaths,
            slices: slices,
            codemapAutoEnabled: codemapOnly ? false : existing.codemapAutoEnabled
        )
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.structuralMerge, structuralMerge)
        let autoCodemapRecomputeTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal)
        if selection.codemapAutoEnabled {
            selection = await recomputeAutoCodemaps(selection, rootScope: rootScope)
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal,
                autoCodemapRecomputeTotal,
                EditFlowPerf.Dimensions(outcome: "attempted")
            )
        } else {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.AutoSelect.autoCodemapRecomputeTotal,
                autoCodemapRecomputeTotal,
                EditFlowPerf.Dimensions(outcome: "skipped")
            )
        }
        return WorkspaceAddSelectionResult(selection: selection, invalidPaths: resolution.invalid, resolvedMap: resolution.resolvedMap, mutated: mutated, codemapUnavailable: resolution.unavailable)
    }

    func removePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceRemoveSelectionResult {
        let resolution = await resolveSelectionCandidates(paths: paths, rawPaths: rawPaths, expandFolders: true, allowEmptyFolderExpansion: true, rootScope: rootScope)
        let codemapOnly = mode == "codemap_only"
        var selectedPaths = existing.selectedPaths
        var codemapPaths = existing.autoCodemapPaths
        var slices = existing.slices
        var selectedSet = Set(selectedPaths)
        var codemapSet = Set(codemapPaths)
        var mutated = false

        for file in resolution.candidates {
            let path = file.standardizedFullPath
            if !codemapOnly, selectedSet.contains(path) {
                selectedPaths.removeAll { $0 == path }
                selectedSet.remove(path)
                mutated = true
            }
            if codemapSet.contains(path) {
                codemapPaths.removeAll { $0 == path }
                codemapSet.remove(path)
                mutated = true
            }
            if !codemapOnly, removeSliceEntries(for: file, in: &slices) { mutated = true }
        }

        let disableAuto = codemapOnly && mutated
        var selection = StoredSelection(
            selectedPaths: selectedPaths,
            autoCodemapPaths: codemapPaths,
            slices: slices,
            codemapAutoEnabled: disableAuto ? false : existing.codemapAutoEnabled
        )
        if selection.codemapAutoEnabled, !disableAuto {
            selection = await recomputeAutoCodemaps(selection, rootScope: rootScope)
        }
        return WorkspaceRemoveSelectionResult(selection: selection, invalidPaths: resolution.invalidPaths, resolvedMap: resolution.resolvedMap, mutated: mutated)
    }

    func promotePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> (selection: StoredSelection, invalidPaths: [String], mutated: Bool) {
        let resolution = await resolveSelectionCandidates(paths: paths, rawPaths: rawPaths, expandFolders: false, rootScope: rootScope)
        var selectedPaths = existing.selectedPaths
        var codemapPaths = existing.autoCodemapPaths
        var slices = existing.slices
        var selectedSet = Set(selectedPaths)
        var codemapSet = Set(codemapPaths)
        var mutated = false

        for file in resolution.candidates {
            let path = file.standardizedFullPath
            if !selectedSet.contains(path) {
                selectedPaths.append(path)
                selectedSet.insert(path)
                mutated = true
            }
            if codemapSet.contains(path) {
                codemapPaths.removeAll { $0 == path }
                codemapSet.remove(path)
                mutated = true
            }
            if removeSliceEntries(for: file, in: &slices) { mutated = true }
        }

        return (StoredSelection(selectedPaths: selectedPaths, autoCodemapPaths: codemapPaths, slices: slices, codemapAutoEnabled: false), resolution.invalidPaths, mutated)
    }

    func demotePaths(
        existing: StoredSelection,
        paths: [String],
        rawPaths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceDemoteSelectionResult {
        if codemapsGloballyDisabled {
            return WorkspaceDemoteSelectionResult(selection: existing, invalidPaths: [codemapsGloballyDisabledMessage], codemapUnavailable: [], mutated: false)
        }
        let resolution = await resolveSelectionCandidates(paths: paths, rawPaths: rawPaths, expandFolders: false, rootScope: rootScope)
        var selectedPaths = existing.selectedPaths
        var codemapPaths = existing.autoCodemapPaths
        var slices = existing.slices
        var selectedSet = Set(selectedPaths)
        var codemapSet = Set(codemapPaths)
        var unavailable: [String] = []
        var mutated = false

        for file in resolution.candidates {
            let path = file.standardizedFullPath
            guard supportsCodemap(file) else {
                await unavailable.append("codemap unavailable: \(displayPath(for: file, rootScope: rootScope))")
                continue
            }
            if selectedSet.contains(path) {
                selectedPaths.removeAll { $0 == path }
                selectedSet.remove(path)
                mutated = true
            }
            if removeSliceEntries(for: file, in: &slices) { mutated = true }
            if !codemapSet.contains(path) {
                codemapPaths.append(path)
                codemapSet.insert(path)
                mutated = true
            }
        }

        let selection = StoredSelection(selectedPaths: selectedPaths, autoCodemapPaths: codemapPaths, slices: slices, codemapAutoEnabled: false)
        return WorkspaceDemoteSelectionResult(selection: selection, invalidPaths: resolution.invalidPaths, codemapUnavailable: unavailable, mutated: mutated)
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

    func recomputeAutoCodemaps(
        _ base: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> StoredSelection {
        guard base.codemapAutoEnabled else { return base }
        guard !codemapsGloballyDisabled else {
            return StoredSelection(selectedPaths: base.selectedPaths, autoCodemapPaths: [], slices: base.slices, codemapAutoEnabled: base.codemapAutoEnabled)
        }
        let selectedFileLookup = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.selectedFileLookup)
        let resolved = await store.lookupFiles(atPaths: base.selectedPaths, rootScope: rootScope)
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.selectedFileLookup, selectedFileLookup)
        let selected = base.selectedPaths.compactMap { resolved[$0] }
        guard !selected.isEmpty else {
            return StoredSelection(selectedPaths: base.selectedPaths, autoCodemapPaths: [], slices: base.slices, codemapAutoEnabled: base.codemapAutoEnabled)
        }
        let codemapAPILoad = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad)
        let aggregate = await store.codemapFileAPIAggregate()
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.codemapAPILoad, codemapAPILoad)
        guard !aggregate.orderedFileAPIs.isEmpty else {
            return StoredSelection(selectedPaths: base.selectedPaths, autoCodemapPaths: [], slices: base.slices, codemapAutoEnabled: base.codemapAutoEnabled)
        }
        let referencedPathResolution = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.referencedPathResolution)
        let referenced = CodeMapExtractor.resolveReferencedFilePaths(
            from: selected,
            among: aggregate.orderedFileAPIs,
            firstFileAPIByStandardizedNestedPath: aggregate.firstFileAPIByStandardizedNestedPath
        )
        EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.referencedPathResolution, referencedPathResolution)
        return StoredSelection(selectedPaths: base.selectedPaths, autoCodemapPaths: referenced, slices: base.slices, codemapAutoEnabled: base.codemapAutoEnabled)
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
