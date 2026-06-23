import Foundation

private struct WorkspacePromptCaptureCheckpoint: @unchecked Sendable {
    let generation: UInt64
    let codemaps: WorkspaceCodemapSnapshotBundle
    let codemapFingerprint: Int
    let worktreeLifetime: WorkspaceSessionRootLifetimeSnapshot?
}

private extension WorkspaceFileContextStore {
    func beginPromptFactualCapture(
        rootScope: WorkspaceLookupRootScope,
        expectedPhysicalRoots: [WorkspaceRootRef]
    ) -> WorkspacePromptCaptureCheckpoint? {
        guard rootScopeAvailability(rootScope) == .available else { return nil }
        let lifetime: WorkspaceSessionRootLifetimeSnapshot?
        switch rootScope {
        case .sessionBoundWorkspace, .validatedSessionBoundWorkspace:
            if expectedPhysicalRoots.isEmpty {
                // An admitted session can be canonical-only. Catalog generation and the
                // exact requested canonical scope still fence this capture; a worktree
                // lifetime is required only when the frozen projection names one.
                lifetime = nil
            } else {
                guard let captured = sessionBoundRootScopeValidationSnapshot(
                    rootScope,
                    expectedPhysicalRoots: expectedPhysicalRoots
                ) else { return nil }
                lifetime = captured
            }
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData:
            lifetime = nil
        }
        let codemaps = codemapSnapshotBundle(rootScope: rootScope)
        return WorkspacePromptCaptureCheckpoint(
            generation: catalogGeneration(rootScope: rootScope),
            codemaps: codemaps,
            codemapFingerprint: codemaps.promptFingerprint,
            worktreeLifetime: lifetime
        )
    }

    func validatePromptFactualCapture(
        _ checkpoint: WorkspacePromptCaptureCheckpoint,
        rootScope: WorkspaceLookupRootScope
    ) async -> Bool {
        guard rootScopeAvailability(rootScope) == .available,
              catalogGeneration(rootScope: rootScope) == checkpoint.generation,
              codemapSnapshotBundle(rootScope: rootScope).promptFingerprint == checkpoint.codemapFingerprint
        else { return false }
        return await checkpoint.worktreeLifetime?.isCurrent() ?? true
    }
}

private extension WorkspaceCodemapSnapshotBundle {
    var promptFingerprint: Int {
        var hasher = Hasher()
        for snapshot in orderedSnapshots {
            hasher.combine(snapshot.fileID)
            hasher.combine(snapshot.rootID)
            hasher.combine(snapshot.relativePath)
            hasher.combine(snapshot.modificationDate.timeIntervalSinceReferenceDate.bitPattern)
            hasher.combine(snapshot.fileAPI != nil)
        }
        return hasher.finalize()
    }
}

package enum PromptFactualContextCaptureService {
    package static func capture(
        request: PromptFactualCaptureRequest,
        store: WorkspaceFileContextStore
    ) async -> PromptFactualCaptureOutcome {
        if Task.isCancelled { return .cancelled }
        guard validate(request) else { return .unavailable(.invalidFrozenInput) }

        let effectiveScope = request.projection?.rootScope ?? request.rootScope
        if request.ingressPolicy == .awaitPending {
            _ = await store.awaitAppliedIngress(rootScope: effectiveScope)
        }
        if Task.isCancelled { return .cancelled }
        guard let checkpoint = await store.beginPromptFactualCapture(
            rootScope: effectiveScope,
            expectedPhysicalRoots: request.projection?.expectedPhysicalRoots ?? []
        ) else {
            return .unavailable(isWorktreeScope(effectiveScope) ? .missingWorktree : .notReady)
        }

        let physicalSelection = request.projection?.physicalizeSelection(request.selection) ?? request.selection
        let ordinarySelection = excluding(
            request.authorizedArtifactBatch.consumedSelectionPaths,
            from: physicalSelection
        )
        let accounting = PromptContextAccountingService()
        let resolution = await accounting.resolveEntries(
            selection: ordinarySelection,
            store: store,
            rootScope: effectiveScope,
            profile: request.entryResolutionProfile,
            codeMapUsage: request.codeMapUsage,
            codemapSnapshotBundle: checkpoint.codemaps
        )
        if Task.isCancelled { return .cancelled }
        if let projection = request.projection,
           resolution.entries.contains(where: {
               projection.logicalDisplayPath(
                   forPhysicalPath: $0.file.standardizedFullPath,
                   display: request.filePathDisplay
               ) == nil
           })
        {
            return .unavailable(.invalidFrozenInput)
        }

        let treeSnapshot: FileTreeSelectionSnapshot? = if request.rendersFileTree {
            await store.makeFileTreeSelectionSnapshot(
                selection: ordinarySelection,
                request: WorkspaceFileTreeSnapshotRequest(
                    mode: request.fileTreeMode,
                    filePathDisplay: request.filePathDisplay,
                    onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
                    includeLegend: request.includeFileTreeLegend,
                    showCodeMapMarkers: request.showCodeMapMarkers,
                    rootScope: effectiveScope
                ),
                codemapSnapshotBundle: checkpoint.codemaps,
                profile: request.entryResolutionProfile
            )
        } else {
            nil
        }
        let logicalTreeSnapshot = treeSnapshot.map {
            request.projection?.logicalizeFileTreeSnapshot($0) ?? $0
        }
        let fileTreeContent = logicalTreeSnapshot.map(CodeMapSnapshotRenderer.generateFileTree(using:))
            .flatMap { $0.isEmpty ? nil : $0 }

        let rendered = PromptFactualRenderingService.render(
            entries: resolution.entries,
            codemaps: checkpoint.codemaps,
            fileTreeContent: fileTreeContent,
            artifacts: request.authorizedArtifactBatch.payloads,
            filePathDisplay: request.filePathDisplay,
            projection: request.projection
        )

        let snapshots = await accounting.makePromptFileEntrySnapshots(
            from: resolution.entries,
            codemapSnapshotBundle: checkpoint.codemaps,
            filePathDisplay: request.filePathDisplay,
            displayPathResolver: { entry in
                request.projection?.logicalDisplayPath(
                    forPhysicalPath: entry.file.standardizedFullPath,
                    display: request.filePathDisplay
                )
            }
        )
        let ordinaryTokenResult = await TokenCalculationService().calculatePromptStats(
            snapshot: TokenCalculationSnapshot(
                promptText: request.promptText,
                selectedInstructionsText: request.selectedInstructionsText,
                duplicateUserInstructionsAtTop: request.duplicateUserInstructionsAtTop,
                promptEntries: snapshots,
                fileTree: fileTreeContent.map(TokenCalculationFileTreeInput.rendered) ?? .none
            )
        )
        let mapArtifacts = request.authorizedArtifactBatch.payloads.filter {
            $0.kind == .map && $0.readability == .readable
        }
        let mapTokens = mapArtifacts.reduce(0) {
            $0 + TokenCalculationService.estimateTokens(for: $1.content)
        }
        var fileTokenInfo = ordinaryTokenResult.fileTokenInfo
        for artifact in mapArtifacts {
            fileTokenInfo[artifact.artifactID] = TokenInfo(
                count: TokenCalculationService.estimateTokens(for: artifact.content),
                totalTokens: ordinaryTokenResult.totalTokenCountFilesOnly + mapTokens
            )
        }
        let tokenResult = TokenCalculationResult(
            totalTokenCount: ordinaryTokenResult.totalTokenCount + mapTokens,
            totalTokenCountFilesOnly: ordinaryTokenResult.totalTokenCountFilesOnly + mapTokens,
            fileTokenInfo: fileTokenInfo,
            folderTokenInfo: ordinaryTokenResult.folderTokenInfo,
            tokenCountString: String(
                format: "%.2fk",
                Double(ordinaryTokenResult.totalTokenCount + mapTokens) / 1000.0
            ),
            tokenCountFilesOnlyString: String(
                format: "%.2fk",
                Double(ordinaryTokenResult.totalTokenCountFilesOnly + mapTokens) / 1000.0
            ),
            charCount: ordinaryTokenResult.charCount + mapArtifacts.reduce(0) { $0 + $1.content.count },
            fileTreeContent: ordinaryTokenResult.fileTreeContent,
            fileTreeTokenCount: ordinaryTokenResult.fileTreeTokenCount,
            fileTreeTokenCountRaw: ordinaryTokenResult.fileTreeTokenCountRaw,
            codeMapContent: ordinaryTokenResult.codeMapContent,
            codeMapFileCount: ordinaryTokenResult.codeMapFileCount,
            codeMapTokenCount: ordinaryTokenResult.codeMapTokenCount
        )
        let selectedDiff = await resolveSelectedDiffPaths(
            selection: ordinarySelection,
            logicalSelection: request.selection,
            store: store,
            rootScope: effectiveScope,
            folderPolicy: request.selectedDiffFolderPolicy,
            profile: request.selectedDiffLookupProfile
        )
        if Task.isCancelled { return .cancelled }

        guard await store.validatePromptFactualCapture(checkpoint, rootScope: effectiveScope) else {
            return .unavailable(.staleGeneration)
        }

        let logicalize: (String) -> String = { path in
            request.projection?.logicalizePath(path, display: .full) ?? path
        }
        return .ready(
            PromptFactualContextSnapshot(
                catalogGeneration: checkpoint.generation,
                fileTreeRootCount: logicalTreeSnapshot?.roots.count ?? 0,
                rendered: rendered,
                tokenResult: tokenResult,
                entries: PromptFactualRenderingService.entrySummaries(
                    entries: resolution.entries,
                    artifacts: request.authorizedArtifactBatch.payloads,
                    display: request.filePathDisplay,
                    projection: request.projection
                ),
                missingLogicalPaths: resolution.missingPaths.map(logicalize),
                invalidLogicalPaths: resolution.invalidPaths.map(logicalize),
                selectedDiffPathResolution: selectedDiff,
                artifactDispositions: request.authorizedArtifactBatch.dispositions
            )
        )
    }

    private static func validate(_ request: PromptFactualCaptureRequest) -> Bool {
        let batch = request.authorizedArtifactBatch
        guard batch.payloads.allSatisfy({ payload in
            let readableStateIsValid = switch (payload.kind, payload.readability) {
            case (.map, .readable): true
            case (.map, .empty): false
            case (.patch, .readable): !payload.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case (.patch, .empty): payload.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return PromptAuthorizedArtifactAliasValidation.isSafe(payload.displayAlias)
                && !payload.provenance.repoKey.isEmpty
                && !payload.provenance.repositoryID.isEmpty
                && !payload.provenance.worktreeID.isEmpty
                && readableStateIsValid
        }), batch.dispositions.allSatisfy({ PromptAuthorizedArtifactAliasValidation.isSafe($0.displayAlias) }),
        batch.consumedSelectionPaths.allSatisfy({ !$0.contains("\0") })
        else { return false }

        let payloadIDs = Set(batch.payloads.map(\.artifactID))
        guard payloadIDs.count == batch.payloads.count else { return false }
        let authorizedIDs = batch.dispositions.compactMap { disposition -> UUID? in
            guard case .authorized = disposition.status,
                  let artifactID = disposition.artifactID,
                  disposition.provenance != nil
            else { return nil }
            return artifactID
        }
        return Set(authorizedIDs) == payloadIDs && authorizedIDs.count == batch.payloads.count
    }

    private static func excluding(_ consumed: Set<String>, from selection: StoredSelection) -> StoredSelection {
        guard !consumed.isEmpty else { return selection }
        let normalized = Set(consumed.compactMap(StoredSelectionPathNormalization.standardizedPath))
        func retained(_ path: String) -> Bool {
            !consumed.contains(path)
                && StoredSelectionPathNormalization.standardizedPath(path).map { !normalized.contains($0) } != false
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.filter(retained),
            autoCodemapPaths: selection.autoCodemapPaths.filter(retained),
            slices: selection.slices.filter { retained($0.key) },
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private static func isWorktreeScope(_ scope: WorkspaceLookupRootScope) -> Bool {
        switch scope {
        case .sessionBoundWorkspace, .validatedSessionBoundWorkspace: true
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded, .allLoadedExcludingGitData: false
        }
    }

    private static func selectedDiffCandidates(_ selection: StoredSelection) -> [String] {
        var values = StoredSelectionPathNormalization.standardizedPaths(selection.selectedPaths)
        var seen = Set(values)
        for (path, ranges) in StoredSelectionPathNormalization.standardizedSlices(selection.slices)
            where !ranges.isEmpty && seen.insert(path).inserted
        {
            values.append(path)
        }
        return values
    }

    private static func resolveSelectedDiffPaths(
        selection: StoredSelection,
        logicalSelection: StoredSelection,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        folderPolicy: PromptSelectedDiffFolderPolicy,
        profile: PathLocateProfile
    ) async -> PromptSelectedDiffPathResolution {
        let candidates = selectedDiffCandidates(selection)
        let logicalCandidates = selectedDiffCandidates(logicalSelection)
        guard !candidates.isEmpty else {
            return PromptSelectedDiffPathResolution(paths: [], unresolvedLogicalCandidates: [])
        }
        let resolved = await store.lookupFiles(atPaths: candidates, profile: profile, rootScope: rootScope)
        var paths: [String] = []
        var unresolved: [String] = []
        var seen = Set<String>()

        for (index, candidate) in candidates.enumerated() {
            if let file = resolved[candidate] {
                let path = file.standardizedFullPath
                if seen.insert(path).inserted { paths.append(path) }
                continue
            }
            if folderPolicy == .expandFolders {
                let expansion = await store.expandFolderInputToFiles(
                    candidate,
                    rootScope: rootScope,
                    profile: profile
                )
                if expansion.handled {
                    for file in expansion.files {
                        let path = file.standardizedFullPath
                        if seen.insert(path).inserted { paths.append(path) }
                    }
                    continue
                }
            }
            unresolved.append(index < logicalCandidates.count ? logicalCandidates[index] : candidate)
        }
        return PromptSelectedDiffPathResolution(paths: paths, unresolvedLogicalCandidates: unresolved)
    }
}
