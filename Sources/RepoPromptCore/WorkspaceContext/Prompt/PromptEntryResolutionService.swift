import Foundation

/// Dormant value-based orchestration for resolving persisted workspace selections into prompt-entry
/// snapshots and token-accounting inputs. This service intentionally has no PromptViewModel or
/// TokenCountingViewModel dependencies so callers can opt in incrementally.
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

package struct PromptContextAccountingResult {
    package let tokenResult: TokenCalculationResult
    package let resolvedEntries: [ResolvedPromptFileEntry]
    package let promptFileEntrySnapshots: [PromptFileEntrySnapshot]
    package let tokenCalculationSnapshot: TokenCalculationSnapshot
    package let missingPaths: [String]
    package let invalidPaths: [String]
    package let codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle
    package let codemapSnapshotsUsed: [UUID: WorkspaceCodemapSnapshot]
}

package enum PromptContextAccountingContentPolicy {
    case loadContent
    case cachedOnly
}

private struct SelectedFileAccountingReadRequest {
    let selectedPathIndex: Int
    let selectedPath: String
    let file: WorkspaceFileRecord
}

private struct SelectedFileAccountingReadResult {
    let selectedPathIndex: Int
    let content: String?
    let errorDescription: String?
}

package actor PromptContextAccountingService {
    private static let selectedFileAccountingReadConcurrencyLimit = 4

    private let tokenCalculationService: TokenCalculationService

    package init(tokenCalculationService: TokenCalculationService = TokenCalculationService()) {
        self.tokenCalculationService = tokenCalculationService
    }

    package func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        fileTreeSnapshotRequest: WorkspaceFileTreeSnapshotRequest
    ) async -> PromptContextAccountingResult {
        let codemapSnapshotBundle = await store.codemapSnapshotBundle(rootScope: request.rootScope)
        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: request.selection,
            request: fileTreeSnapshotRequest,
            codemapSnapshotBundle: codemapSnapshotBundle,
            profile: request.pathLocateProfile
        )
        return await calculatePromptStats(
            request: request.withFileTree(.snapshot(snapshot)),
            store: store,
            codemapSnapshotBundle: codemapSnapshotBundle
        )
    }

    package func calculatePromptStats(
        request: PromptContextAccountingRequest,
        store: WorkspaceFileContextStore,
        codemapSnapshotBundle frozenCodemaps: WorkspaceCodemapSnapshotBundle? = nil,
        codemapDisplayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) async -> PromptContextAccountingResult {
        let codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle = if let frozenCodemaps {
            frozenCodemaps
        } else {
            await store.codemapSnapshotBundle(rootScope: request.rootScope)
        }
        let codemapSnapshots = codemapSnapshotBundle.snapshotsByFileID
        let resolution = await resolveEntries(
            selection: request.selection,
            store: store,
            rootScope: request.rootScope,
            profile: request.pathLocateProfile,
            codeMapUsage: request.codeMapUsage,
            codemapSnapshotBundle: codemapSnapshotBundle,
            contentPolicy: .loadContent
        )
        let snapshots = makePromptFileEntrySnapshots(
            from: resolution.entries,
            codemapSnapshotBundle: codemapSnapshotBundle,
            filePathDisplay: request.filePathDisplay,
            displayPathResolver: codemapDisplayPathResolver
        )
        let calculationSnapshot = TokenCalculationSnapshot(
            promptText: request.promptText,
            selectedInstructionsText: request.selectedInstructionsText,
            duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
            promptEntries: snapshots,
            fileTree: request.fileTree
        )
        let tokenResult = await tokenCalculationService.calculatePromptStats(snapshot: calculationSnapshot)
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
            codemapSnapshotBundle: codemapSnapshotBundle,
            codemapSnapshotsUsed: usedCodemaps
        )
    }

    package func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        profile: PathLocateProfile = .uiAssisted,
        codeMapUsage: CodeMapUsage = .auto,
        codemapSnapshotBundle frozenCodemaps: WorkspaceCodemapSnapshotBundle? = nil,
        contentPolicy: PromptContextAccountingContentPolicy = .loadContent
    ) async -> (entries: [ResolvedPromptFileEntry], missingPaths: [String], invalidPaths: [String]) {
        let codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle = if let frozenCodemaps {
            frozenCodemaps
        } else {
            await store.codemapSnapshotBundle(rootScope: rootScope)
        }
        return await resolveEntries(
            selection: selection,
            store: store,
            rootScope: rootScope,
            profile: profile,
            codeMapUsage: codeMapUsage,
            codemapSnapshotBundle: codemapSnapshotBundle,
            contentPolicy: contentPolicy
        )
    }

    private func resolveEntries(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        codeMapUsage: CodeMapUsage,
        codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle,
        contentPolicy: PromptContextAccountingContentPolicy
    ) async -> (entries: [ResolvedPromptFileEntry], missingPaths: [String], invalidPaths: [String]) {
        var entries: [ResolvedPromptFileEntry] = []
        var missingPaths: [String] = []
        var invalidPaths: [String] = []
        var seenIDs = Set<ResolvedPromptFileEntryID>()
        var selectedFileIDs = Set<UUID>()

        let selectedPathLookupRequests = selection.selectedPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let selectedPathLookupResults = await store.lookupPaths(selectedPathLookupRequests)
        guard !Task.isCancelled else {
            return (entries, missingPaths, invalidPaths)
        }
        var selectedPathResultsByIndex: [Int: WorkspacePathLookupResult] = [:]
        var selectedPathFallbackLookups = 0
        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return (entries, missingPaths, invalidPaths)
            }
            if let result = selectedPathLookupResults[path] {
                selectedPathResultsByIndex[selectedPathIndex] = result
            } else if let result = await store.lookupPath(path, profile: profile, rootScope: rootScope) {
                selectedPathResultsByIndex[selectedPathIndex] = result
                selectedPathFallbackLookups += 1
            }
        }

        var selectedFileReadRequests: [SelectedFileAccountingReadRequest] = []
        var selectedCodemapReadSkips = 0
        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return (entries, missingPaths, invalidPaths)
            }
            guard let result = selectedPathResultsByIndex[selectedPathIndex] else {
                continue
            }
            if let file = result.file {
                let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshotBundle.hasRenderableCodemap(for: file)
                if useSelectedCodemap {
                    selectedCodemapReadSkips += 1
                } else {
                    selectedFileReadRequests.append(
                        SelectedFileAccountingReadRequest(
                            selectedPathIndex: selectedPathIndex,
                            selectedPath: path,
                            file: file
                        )
                    )
                }
            }
        }

        let selectedFileReadResults = await withTaskGroup(
            of: SelectedFileAccountingReadResult.self,
            returning: [Int: SelectedFileAccountingReadResult].self
        ) { group in
            let concurrencyLimit = Self.selectedFileAccountingReadConcurrencyLimit
            var iterator = selectedFileReadRequests.makeIterator()
            var activeReads = 0
            var results: [Int: SelectedFileAccountingReadResult] = [:]

            func enqueueNextReadIfAvailable() {
                guard !Task.isCancelled,
                      activeReads < concurrencyLimit,
                      let request = iterator.next()
                else {
                    return
                }
                activeReads += 1
                group.addTask {
                    guard !Task.isCancelled else {
                        return SelectedFileAccountingReadResult(
                            selectedPathIndex: request.selectedPathIndex,
                            content: nil,
                            errorDescription: "cancelled"
                        )
                    }
                    let content: String?
                    let errorDescription: String?
                    switch contentPolicy {
                    case .loadContent:
                        do {
                            content = try await store.readValidatedContentSnapshot(
                                rootID: request.file.rootID,
                                relativePath: request.file.standardizedRelativePath,
                                workloadClass: .promptAccounting
                            ).content
                            errorDescription = nil
                        } catch {
                            content = nil
                            errorDescription = String(String(describing: error).prefix(120))
                        }
                    case .cachedOnly:
                        content = await store.cachedSearchContentSnapshot(for: request.file).content
                        errorDescription = nil
                    }
                    return SelectedFileAccountingReadResult(
                        selectedPathIndex: request.selectedPathIndex,
                        content: content,
                        errorDescription: errorDescription
                    )
                }
            }

            for _ in 0 ..< concurrencyLimit {
                enqueueNextReadIfAvailable()
            }

            while let result = await group.next() {
                activeReads -= 1
                results[result.selectedPathIndex] = result
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueueNextReadIfAvailable()
            }

            return results
        }
        guard !Task.isCancelled else {
            return (entries, missingPaths, invalidPaths)
        }

        for (selectedPathIndex, path) in selection.selectedPaths.enumerated() {
            guard !Task.isCancelled else {
                return (entries, missingPaths, invalidPaths)
            }
            guard let result = selectedPathResultsByIndex[selectedPathIndex] else {
                missingPaths.append(path)
                continue
            }

            if let file = result.file {
                selectedFileIDs.insert(file.id)
                let ranges = sliceRanges(for: path, file: file, location: result.location, in: selection.slices)
                let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshotBundle.hasRenderableCodemap(for: file)
                let content = useSelectedCodemap ? nil : selectedFileReadResults[selectedPathIndex]?.content
                let entry = ResolvedPromptFileEntry(
                    file: file,
                    isCodemap: useSelectedCodemap,
                    lineRanges: useSelectedCodemap ? nil : ranges,
                    mode: useSelectedCodemap ? .codemap : ((ranges?.isEmpty == false) ? .sliced : .fullFile),
                    loadedContent: content ?? nil,
                    rootFolderPath: result.location.rootPath
                )
                append(entry, to: &entries, seenIDs: &seenIDs)
            } else if let folder = result.folder {
                let files = await store.files(inRoot: folder.rootID)
                let prefix = folder.standardizedRelativePath
                for file in files where prefix.isEmpty || file.standardizedRelativePath == prefix || file.standardizedRelativePath.hasPrefix(prefix + "/") {
                    guard !Task.isCancelled else {
                        return (entries, missingPaths, invalidPaths)
                    }
                    selectedFileIDs.insert(file.id)
                    let useSelectedCodemap = codeMapUsage == .selected && codemapSnapshotBundle.hasRenderableCodemap(for: file)
                    let content: String?
                    if useSelectedCodemap {
                        content = nil
                    } else {
                        do {
                            content = switch contentPolicy {
                            case .loadContent:
                                try await store.readValidatedContentSnapshot(
                                    rootID: file.rootID,
                                    relativePath: file.standardizedRelativePath,
                                    workloadClass: .promptAccounting
                                ).content
                            case .cachedOnly:
                                await store.cachedSearchContentSnapshot(for: file).content
                            }
                        } catch {
                            content = nil
                        }
                    }
                    let entry = ResolvedPromptFileEntry(
                        file: file,
                        isCodemap: useSelectedCodemap,
                        mode: useSelectedCodemap ? .codemap : .fullFile,
                        loadedContent: content ?? nil,
                        rootFolderPath: result.location.rootPath
                    )
                    append(entry, to: &entries, seenIDs: &seenIDs)
                }
            } else {
                invalidPaths.append(path)
            }
        }

        for (path, ranges) in selection.slices {
            guard !Task.isCancelled else {
                return (entries, missingPaths, invalidPaths)
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
            let content: String? = switch contentPolicy {
            case .loadContent:
                try? await store.readValidatedContentSnapshot(
                    rootID: file.rootID,
                    relativePath: file.standardizedRelativePath,
                    workloadClass: .promptAccounting
                ).content
            case .cachedOnly:
                await store.cachedSearchContentSnapshot(for: file).content
            }
            let entry = ResolvedPromptFileEntry(file: file, lineRanges: ranges, mode: .sliced, loadedContent: content ?? nil, rootFolderPath: result.location.rootPath)
            append(entry, to: &entries, seenIDs: &seenIDs)
        }

        let codemapPaths: [String] = switch codeMapUsage {
        case .none, .selected:
            []
        case .auto:
            Array(selection.autoCodemapPaths)
        case .complete:
            codemapSnapshotBundle.orderedSnapshots.compactMap { snapshot in
                guard !selectedFileIDs.contains(snapshot.fileID), snapshot.fileAPI != nil else { return nil }
                return snapshot.fullPath
            }
        }

        let codemapPathLookupRequests = codemapPaths.map {
            WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope)
        }
        let codemapPathLookupResults = await store.lookupPaths(codemapPathLookupRequests)
        guard !Task.isCancelled else {
            return (entries, missingPaths, invalidPaths)
        }
        for path in codemapPaths {
            guard !Task.isCancelled else {
                return (entries, missingPaths, invalidPaths)
            }
            guard let result = codemapPathLookupResults[path] else {
                missingPaths.append(path)
                continue
            }
            guard let file = result.file else {
                invalidPaths.append(path)
                continue
            }
            guard !selectedFileIDs.contains(file.id), codemapSnapshotBundle.hasRenderableCodemap(for: file) else { continue }
            let entry = ResolvedPromptFileEntry(file: file, isCodemap: true, mode: .codemap, loadedContent: nil, rootFolderPath: result.location.rootPath)
            append(entry, to: &entries, seenIDs: &seenIDs)
        }

        let uniqueMissingPaths = Array(Set(missingPaths)).sorted()
        let uniqueInvalidPaths = Array(Set(invalidPaths)).sorted()
        return (entries, uniqueMissingPaths, uniqueInvalidPaths)
    }

    package func makePromptFileEntrySnapshots(
        from entries: [ResolvedPromptFileEntry],
        codemapSnapshotBundle: WorkspaceCodemapSnapshotBundle,
        filePathDisplay: FilePathDisplay = .relative,
        displayPathResolver: ((ResolvedPromptFileEntry) -> String?)? = nil
    ) -> [PromptFileEntrySnapshot] {
        let hasMultipleRoots = Set(entries.map(\.file.rootID)).count > 1
        return entries.map { entry in
            let codeMapContent: String?
            let availableCodeMapTokenCount: Int
            let displayPath = displayPathResolver?(entry)
                ?? Self.selectedPath(for: entry, filePathDisplay: filePathDisplay, hasMultipleRoots: hasMultipleRoots)
            if let rendered = codemapSnapshotBundle.renderedCodemap(for: entry.file, displayPath: displayPath) {
                availableCodeMapTokenCount = rendered.tokenCount
                codeMapContent = entry.isCodemap ? rendered.text : nil
            } else {
                availableCodeMapTokenCount = 0
                codeMapContent = nil
            }
            let cachedFullTokenCount = entry.loadedContent.map(TokenCalculationService.estimateTokens(for:))
            return PromptFileEntrySnapshot(
                fileID: entry.file.id,
                relativePath: entry.file.relativePath,
                isCodemapRequested: entry.isCodemap,
                ranges: entry.lineRanges,
                cachedFullTokenCount: cachedFullTokenCount,
                loadedContent: entry.loadedContent,
                codeMapContent: codeMapContent,
                availableCodeMapTokenCount: availableCodeMapTokenCount
            )
        }
    }

    private nonisolated static func selectedPath(for entry: ResolvedPromptFileEntry, filePathDisplay: FilePathDisplay, hasMultipleRoots: Bool) -> String {
        if filePathDisplay == .relative {
            if hasMultipleRoots, let rootFolderPath = entry.rootFolderPath, !rootFolderPath.isEmpty {
                let rootFolderName = (StandardizedPath.absolute(rootFolderPath) as NSString).lastPathComponent
                return rootFolderName.isEmpty ? entry.file.relativePath : "\(rootFolderName)/\(entry.file.relativePath)"
            }
            return entry.file.relativePath
        }
        return entry.file.fullPath
    }

    private nonisolated func sliceRanges(for path: String, file: WorkspaceFileRecord, location: WorkspacePathLocation, in slices: [String: [LineRange]]) -> [LineRange]? {
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

    private func append(_ entry: ResolvedPromptFileEntry, to entries: inout [ResolvedPromptFileEntry], seenIDs: inout Set<ResolvedPromptFileEntryID>) {
        guard seenIDs.insert(entry.id).inserted else { return }
        entries.append(entry)
    }
}
