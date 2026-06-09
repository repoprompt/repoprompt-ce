import Foundation

package struct PromptContextAccountingRequest {
    package let selection: StoredSelection
    package let promptText: String
    package let selectedInstructionsText: String
    package let duplicateUserInstructionsAtTop: Bool
    package let fileTree: TokenCalculationFileTreeInput
    package let codeMapUsage: CodeMapUsage
    package let filePathDisplay: FilePathDisplay
    package let rootScope: WorkspaceLookupRootScope
    package let pathLocateProfile: PathLocateProfile

    package init(
        selection: StoredSelection,
        promptText: String = "",
        selectedInstructionsText: String = "",
        duplicateUserInstructionsAtTop: Bool = false,
        fileTree: TokenCalculationFileTreeInput = .none,
        codeMapUsage: CodeMapUsage = .auto,
        filePathDisplay: FilePathDisplay = .relative,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        pathLocateProfile: PathLocateProfile = .uiAssisted
    ) {
        self.selection = selection
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.fileTree = fileTree
        self.codeMapUsage = codeMapUsage
        self.filePathDisplay = filePathDisplay
        self.rootScope = rootScope
        self.pathLocateProfile = pathLocateProfile
    }

    package func withFileTree(_ fileTree: TokenCalculationFileTreeInput) -> PromptContextAccountingRequest {
        PromptContextAccountingRequest(
            selection: selection,
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            fileTree: fileTree,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            rootScope: rootScope,
            pathLocateProfile: pathLocateProfile
        )
    }
}

package struct PromptContextAccountingResolution: Equatable {
    package let entries: [ResolvedPromptFileEntry]
    package let missingPaths: [String]
    package let invalidPaths: [String]

    package init(
        entries: [ResolvedPromptFileEntry],
        missingPaths: [String],
        invalidPaths: [String]
    ) {
        self.entries = entries
        self.missingPaths = missingPaths
        self.invalidPaths = invalidPaths
    }

    package static let empty = PromptContextAccountingResolution(
        entries: [],
        missingPaths: [],
        invalidPaths: []
    )
}

package struct PromptContextAccountingResult {
    package let tokenResult: TokenCalculationResult
    package let resolvedEntries: [ResolvedPromptFileEntry]
    package let promptFileEntrySnapshots: [PromptFileEntrySnapshot]
    package let tokenCalculationSnapshot: TokenCalculationSnapshot
    package let missingPaths: [String]
    package let invalidPaths: [String]
    package let codemapSnapshotsUsed: [UUID: WorkspaceCodemapSnapshot]
    package let captureProvenance: WorkspaceFileContextCapture.Provenance?

    package init(
        tokenResult: TokenCalculationResult,
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot],
        tokenCalculationSnapshot: TokenCalculationSnapshot,
        missingPaths: [String],
        invalidPaths: [String],
        codemapSnapshotsUsed: [UUID: WorkspaceCodemapSnapshot],
        captureProvenance: WorkspaceFileContextCapture.Provenance? = nil
    ) {
        self.tokenResult = tokenResult
        self.resolvedEntries = resolvedEntries
        self.promptFileEntrySnapshots = promptFileEntrySnapshots
        self.tokenCalculationSnapshot = tokenCalculationSnapshot
        self.missingPaths = missingPaths
        self.invalidPaths = invalidPaths
        self.codemapSnapshotsUsed = codemapSnapshotsUsed
        self.captureProvenance = captureProvenance
    }
}

package enum PromptContextAccountingError: Error, Equatable {
    case captureSelectionMismatch
    case captureRootScopeMismatch
}

private struct PromptContextEntryIntent {
    let file: WorkspaceFileRecord
    let isCodemap: Bool
    let lineRanges: [LineRange]?
    let mode: PromptFileEntryMode
    let rootFolderPath: String?

    var id: ResolvedPromptFileEntryID {
        ResolvedPromptFileEntryID(fileID: file.id, mode: mode, lineRanges: lineRanges)
    }
}

private struct PromptContextContentReadRequest {
    let intentIndex: Int
    let file: WorkspaceFileRecord
}

private struct PromptContextContentReadResult {
    let intentIndex: Int
    let content: String?
}

package actor PromptContextAccountingService {
    package nonisolated static let selectedFileReadConcurrencyLimit = 4

    package init() {}

    package func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        fileTreeSnapshotRequest: WorkspaceFileTreeSnapshotRequest
    ) async throws -> PromptContextAccountingResult {
        try Task.checkCancellation()
        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: request.selection,
            request: fileTreeSnapshotRequest,
            profile: request.pathLocateProfile
        )
        try Task.checkCancellation()
        return try await calculatePromptStats(
            request: request.withFileTree(.snapshot(snapshot)),
            store: store
        )
    }

    package func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore
    ) async throws -> PromptContextAccountingResult {
        try Task.checkCancellation()
        let codemapSnapshots = await store.codemapSnapshotDictionary()
        try Task.checkCancellation()
        let resolution = try await resolveEntries(
            selection: request.selection,
            store: store,
            rootScope: request.rootScope,
            profile: request.pathLocateProfile,
            codeMapUsage: request.codeMapUsage,
            codemapSnapshots: codemapSnapshots
        )
        return try await calculatePromptStats(
            request: request,
            resolution: resolution,
            codemapSnapshots: codemapSnapshots,
            captureProvenance: nil
        )
    }

    package func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        capture: WorkspaceFileContextCapture
    ) async throws -> PromptContextAccountingResult {
        try Task.checkCancellation()
        guard capture.storedSelection == request.selection else {
            throw PromptContextAccountingError.captureSelectionMismatch
        }
        guard capture.provenance.rootScope == request.rootScope else {
            throw PromptContextAccountingError.captureRootScopeMismatch
        }

        let plan = try WorkspaceContextProjectionService.makePlan(
            capture: capture,
            request: .init(
                sections: [.selection],
                filePathDisplay: request.filePathDisplay,
                codeMapUsage: request.codeMapUsage
            )
        )
        try Task.checkCancellation()
        let resolution = try await resolveEntries(plan: plan, store: store)
        let codemapSnapshots = Dictionary(
            uniqueKeysWithValues: capture.codemapSnapshots.map { ($0.fileID, $0) }
        )
        return try await calculatePromptStats(
            request: request,
            resolution: resolution,
            codemapSnapshots: codemapSnapshots,
            captureProvenance: capture.provenance
        )
    }

    private func calculatePromptStats(
        request: PromptContextAccountingRequest,
        resolution: PromptContextAccountingResolution,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot],
        captureProvenance: WorkspaceFileContextCapture.Provenance?
    ) async throws -> PromptContextAccountingResult {
        let snapshots = makePromptFileEntrySnapshots(
            from: resolution.entries,
            codemapSnapshots: codemapSnapshots,
            filePathDisplay: request.filePathDisplay
        )
        let calculationSnapshot = TokenCalculationSnapshot(
            promptText: request.promptText,
            selectedInstructionsText: request.selectedInstructionsText,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            promptEntries: snapshots,
            fileTree: request.fileTree
        )
        try Task.checkCancellation()

        let tokenCalculationService = TokenCalculationService()
        let tokenResult = try await tokenCalculationService.calculatePromptStatsScoped(
            snapshot: calculationSnapshot
        )
        try Task.checkCancellation()

        let usedCodemaps = codemapSnapshots.filter { fileID, _ in
            snapshots.contains { $0.fileID == fileID && $0.isCodemapRequested && $0.codeMapContent != nil }
        }
        return PromptContextAccountingResult(
            tokenResult: tokenResult,
            resolvedEntries: resolution.entries,
            promptFileEntrySnapshots: snapshots,
            tokenCalculationSnapshot: calculationSnapshot,
            missingPaths: resolution.missingPaths,
            invalidPaths: resolution.invalidPaths,
            codemapSnapshotsUsed: usedCodemaps,
            captureProvenance: captureProvenance
        )
    }

    package func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        profile: PathLocateProfile = .uiAssisted,
        codeMapUsage: CodeMapUsage = .auto
    ) async throws -> PromptContextAccountingResolution {
        try Task.checkCancellation()
        let codemapSnapshots = await store.codemapSnapshotDictionary()
        try Task.checkCancellation()
        return try await resolveEntries(
            selection: selection,
            store: store,
            rootScope: rootScope,
            profile: profile,
            codeMapUsage: codeMapUsage,
            codemapSnapshots: codemapSnapshots
        )
    }

    package func makePromptFileEntrySnapshots(
        from entries: [ResolvedPromptFileEntry],
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot],
        filePathDisplay: FilePathDisplay = .relative
    ) -> [PromptFileEntrySnapshot] {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        return entries.map { entry in
            let codeMapContent: String?
            let availableCodeMapTokenCount: Int
            if let api = codemapSnapshots[entry.file.id]?.fileAPI {
                availableCodeMapTokenCount = api.apiTokenCount
                if entry.isCodemap {
                    let displayPath = Self.selectedPath(
                        for: entry,
                        filePathDisplay: filePathDisplay,
                        hasMultipleRoots: hasMultipleRoots
                    )
                    let description = api.getFullAPIDescription(displayPath: displayPath)
                    codeMapContent = description.isEmpty ? nil : description
                } else {
                    codeMapContent = nil
                }
            } else {
                availableCodeMapTokenCount = 0
                codeMapContent = nil
            }
            return PromptFileEntrySnapshot(
                fileID: entry.file.id,
                relativePath: entry.file.relativePath,
                isCodemapRequested: entry.isCodemap,
                ranges: entry.lineRanges,
                cachedFullTokenCount: entry.loadedContent.map(TokenCalculationService.estimateTokens(for:)),
                loadedContent: entry.loadedContent,
                codeMapContent: codeMapContent,
                availableCodeMapTokenCount: availableCodeMapTokenCount
            )
        }
    }

    private func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        codeMapUsage: CodeMapUsage,
        codemapSnapshots: [UUID: WorkspaceCodemapSnapshot]
    ) async throws -> PromptContextAccountingResolution {
        var intents: [PromptContextEntryIntent] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        func appendIntent(_ intent: PromptContextEntryIntent) {
            guard seenIDs.insert(intent.id).inserted else { return }
            intents.append(intent)
        }

        var selectedPathLookupInputs: [String] = []
        var invalidSelectedPathIndexes = Set<Int>()
        selectedPathLookupInputs.reserveCapacity(selection.selectedPaths.count)
        for (index, path) in selection.selectedPaths.enumerated() {
            try Task.checkCancellation()
            if await store.exactPathResolutionIssue(for: path, kind: .either, rootScope: rootScope) != nil {
                invalidPaths.append(path)
                invalidSelectedPathIndexes.insert(index)
            } else {
                selectedPathLookupInputs.append(path)
            }
        }

        let selectedPathLookupRequests = selectedPathLookupInputs.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedPathLookupResults = await store.lookupPaths(selectedPathLookupRequests)
        try Task.checkCancellation()

        var selectedPathResultsByIndex: [Int: WorkspacePathLookupResult] = [:]
        let rootRefs = await store.rootRefs(scope: rootScope)
        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            try Task.checkCancellation()
            guard !invalidSelectedPathIndexes.contains(selectedPathIndex) else { continue }
            if let result = selectedPathLookupResults[path] {
                selectedPathResultsByIndex[selectedPathIndex] = result
            } else if let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) {
                selectedPathResultsByIndex[selectedPathIndex] = result
            } else {
                let folderResolution = await store.resolveFolderInput(
                    path,
                    rootScope: rootScope,
                    profile: profile
                )
                if let folder = folderResolution.folder,
                   let root = rootRefs.first(where: { $0.id == folder.rootID })
                {
                    selectedPathResultsByIndex[selectedPathIndex] = WorkspacePathLookupResult(
                        input: path,
                        location: WorkspacePathLocation(
                            rootID: root.id,
                            rootPath: root.fullPath,
                            correctedPath: folder.standardizedRelativePath
                        ),
                        file: nil,
                        folder: folder
                    )
                } else if folderResolution.issue != nil {
                    invalidPaths.append(path)
                    invalidSelectedPathIndexes.insert(selectedPathIndex)
                }
            }
        }

        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            try Task.checkCancellation()
            guard !invalidSelectedPathIndexes.contains(selectedPathIndex) else { continue }
            guard let result = selectedPathResultsByIndex[selectedPathIndex] else {
                missingPaths.append(path)
                continue
            }

            if let file = result.file {
                selectedFileIDs.insert(file.id)
                let ranges = sliceRanges(for: path, file: file, location: result.location, in: selection.slices)
                let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshots[file.id]?.fileAPI != nil
                appendIntent(PromptContextEntryIntent(
                    file: file,
                    isCodemap: useSelectedCodemap,
                    lineRanges: useSelectedCodemap ? nil : ranges,
                    mode: useSelectedCodemap ? .codemap : ((ranges?.isEmpty == false) ? .sliced : .fullFile),
                    rootFolderPath: result.location.rootPath
                ))
            } else if let folder = result.folder {
                let files = await store.files(inRoot: folder.rootID)
                let prefix = folder.standardizedRelativePath
                for file in files where prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                    try Task.checkCancellation()
                    selectedFileIDs.insert(file.id)
                    let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshots[file.id]?.fileAPI != nil
                    appendIntent(PromptContextEntryIntent(
                        file: file,
                        isCodemap: useSelectedCodemap,
                        lineRanges: nil,
                        mode: useSelectedCodemap ? .codemap : .fullFile,
                        rootFolderPath: result.location.rootPath
                    ))
                }
            } else {
                invalidPaths.append(path)
            }
        }

        for (path, ranges) in selection.slices {
            try Task.checkCancellation()
            if await store.exactPathResolutionIssue(for: path, kind: .file, rootScope: rootScope) != nil {
                invalidPaths.append(path)
                continue
            }
            guard let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id) else { continue }
            selectedFileIDs.insert(file.id)
            appendIntent(PromptContextEntryIntent(
                file: file,
                isCodemap: false,
                lineRanges: ranges,
                mode: .sliced,
                rootFolderPath: result.location.rootPath
            ))
        }

        let codemapPaths: [String] = switch codeMapUsage {
        case .none, .selected:
            []
        case .auto:
            selection.autoCodemapPaths
        case .complete:
            codemapSnapshots.compactMap { fileID, snapshot in
                guard !selectedFileIDs.contains(fileID), snapshot.fileAPI != nil else { return nil }
                return snapshot.fullPath
            }
        }

        for path in codemapPaths {
            try Task.checkCancellation()
            if await store.exactPathResolutionIssue(for: path, kind: .file, rootScope: rootScope) != nil {
                invalidPaths.append(path)
                continue
            }
            guard let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id), codemapSnapshots[file.id]?.fileAPI != nil else { continue }
            appendIntent(PromptContextEntryIntent(
                file: file,
                isCodemap: true,
                lineRanges: nil,
                mode: .codemap,
                rootFolderPath: result.location.rootPath
            ))
        }

        let contentByIntentIndex = try await readContents(for: intents, store: store)
        try Task.checkCancellation()
        let entries = intents.enumerated().map { index, intent in
            ResolvedPromptFileEntry(
                file: intent.file,
                isCodemap: intent.isCodemap,
                lineRanges: intent.lineRanges,
                mode: intent.mode,
                loadedContent: contentByIntentIndex[index] ?? nil,
                rootFolderPath: intent.rootFolderPath
            )
        }
        return PromptContextAccountingResolution(
            entries: entries,
            missingPaths: Array(Set(missingPaths)).sorted(),
            invalidPaths: Array(Set(invalidPaths)).sorted()
        )
    }

    private func resolveEntries(
        plan: WorkspaceContextProjectionPlan,
        store: WorkspaceFileContextStore
    ) async throws -> PromptContextAccountingResolution {
        try Task.checkCancellation()
        let intents = plan.occurrences.map { prepared in
            let occurrence = prepared.value
            let mode: PromptFileEntryMode = switch occurrence.mode {
            case .full:
                .fullFile
            case .slice:
                .sliced
            case .codemap:
                .codemap
            }
            return PromptContextEntryIntent(
                file: occurrence.file,
                isCodemap: occurrence.mode == .codemap,
                lineRanges: occurrence.mode == .slice ? occurrence.ranges : nil,
                mode: mode,
                rootFolderPath: occurrence.metadata.rootPath
            )
        }
        let contentByIntentIndex = try await readContents(for: intents, store: store)
        try Task.checkCancellation()
        let entries = intents.enumerated().map { index, intent in
            ResolvedPromptFileEntry(
                file: intent.file,
                isCodemap: intent.isCodemap,
                lineRanges: intent.lineRanges,
                mode: intent.mode,
                loadedContent: contentByIntentIndex[index] ?? nil,
                rootFolderPath: intent.rootFolderPath
            )
        }
        return PromptContextAccountingResolution(
            entries: entries,
            missingPaths: plan.missingPaths,
            invalidPaths: plan.invalidPaths
        )
    }

    private func readContents(
        for intents: [PromptContextEntryIntent],
        store: WorkspaceFileContextStore
    ) async throws -> [Int: String?] {
        let requests = intents.enumerated().compactMap { index, intent -> PromptContextContentReadRequest? in
            guard !intent.isCodemap else { return nil }
            return PromptContextContentReadRequest(intentIndex: index, file: intent.file)
        }
        guard !requests.isEmpty else { return [:] }
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(
            of: PromptContextContentReadResult.self,
            returning: [Int: String?].self
        ) { group in
            var iterator = requests.makeIterator()
            var activeReads = 0
            var results: [Int: String?] = [:]

            func enqueueNextReadIfAvailable() {
                guard activeReads < Self.selectedFileReadConcurrencyLimit,
                      let request = iterator.next()
                else { return }
                activeReads += 1
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let content = try await store.readContent(
                            rootID: request.file.rootID,
                            relativePath: request.file.standardizedRelativePath
                        )
                        try Task.checkCancellation()
                        return PromptContextContentReadResult(
                            intentIndex: request.intentIndex,
                            content: content
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return PromptContextContentReadResult(
                            intentIndex: request.intentIndex,
                            content: nil
                        )
                    }
                }
            }

            for _ in 0 ..< Self.selectedFileReadConcurrencyLimit {
                enqueueNextReadIfAvailable()
            }
            while activeReads > 0 {
                try Task.checkCancellation()
                guard let result = try await group.next() else { break }
                activeReads -= 1
                results[result.intentIndex] = result.content
                enqueueNextReadIfAvailable()
            }
            try Task.checkCancellation()
            return results
        }
    }

    private nonisolated static func selectedPath(
        for entry: ResolvedPromptFileEntry,
        filePathDisplay: FilePathDisplay,
        hasMultipleRoots: Bool
    ) -> String {
        if filePathDisplay == .relative {
            if hasMultipleRoots, let rootFolderPath = entry.rootFolderPath, !rootFolderPath.isEmpty {
                let rootFolderName = (StandardizedPath.absolute(rootFolderPath) as NSString).lastPathComponent
                return rootFolderName.isEmpty ? entry.file.relativePath : "\(rootFolderName)/\(entry.file.relativePath)"
            }
            return entry.file.relativePath
        }
        return entry.file.fullPath
    }

    private nonisolated func sliceRanges(
        for path: String,
        file: WorkspaceFileRecord,
        location: WorkspacePathLocation,
        in slices: [String: [LineRange]]
    ) -> [LineRange]? {
        let candidateKeys = [
            path,
            StandardizedPath.absolute(path),
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath,
            location.absolutePath
        ]
        for key in candidateKeys {
            if let ranges = slices[key] { return ranges }
        }
        return nil
    }
}
