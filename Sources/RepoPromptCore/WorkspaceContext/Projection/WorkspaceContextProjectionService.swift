import Foundation

package enum WorkspaceContextProjectionError: Error, Equatable {
    case captureProvenanceMismatch
    case duplicateRootID(UUID)
    case rootAssociationMismatch(recordID: UUID, rootID: UUID)
    case recordAssociationMismatch(UUID)
    case duplicateCodemapFileID(UUID)
    case codemapAssociationMismatch(UUID)
    case materializationProvenanceMismatch
    case duplicateOccurrenceID(WorkspaceContextProjectionMaterializationRequest.OccurrenceID)
    case missingOccurrenceIDs([WorkspaceContextProjectionMaterializationRequest.OccurrenceID])
    case unexpectedOccurrenceIDs([WorkspaceContextProjectionMaterializationRequest.OccurrenceID])
    case missingTokenFacts(WorkspaceContextProjectionMaterializationRequest.OccurrenceID)
    case invalidTokenFacts(WorkspaceContextProjectionMaterializationRequest.OccurrenceID)
}

package struct WorkspaceContextProjectionService {
    package typealias CaptureOperation = @Sendable () async throws -> WorkspaceFileContextCapture
    package typealias Materializer = @Sendable (
        WorkspaceContextProjectionMaterializationRequest
    ) async throws -> WorkspaceContextProjectionMaterialization

    private struct OccurrenceKey: Hashable {
        enum Mode: Hashable {
            case full
            case slice
            case codemap
        }

        let fileID: UUID
        let mode: Mode
        let ranges: [LineRange]
    }

    private let captureOperation: CaptureOperation
    private let materializer: Materializer
    #if DEBUG
        private let willReturnForTesting: (@Sendable () -> Void)?
    #endif

    package init(
        capture: @escaping CaptureOperation,
        materializer: @escaping Materializer
    ) {
        captureOperation = capture
        self.materializer = materializer
        #if DEBUG
            willReturnForTesting = nil
        #endif
    }

    #if DEBUG
        package init(
            capture: @escaping CaptureOperation,
            materializer: @escaping Materializer,
            willReturnForTesting: @escaping @Sendable () -> Void
        ) {
            captureOperation = capture
            self.materializer = materializer
            self.willReturnForTesting = willReturnForTesting
        }
    #endif

    package func project(
        _ request: WorkspaceContextProjectionRequest
    ) async throws -> WorkspaceContextProjection {
        try Task.checkCancellation()
        let capture = try await captureOperation()
        try Task.checkCancellation()

        let plan = try Self.makePlan(capture: capture, request: request)
        let preparedOccurrences = plan.occurrences
        let completeAlternateOccurrences = plan.completeAlternateOccurrences
        let occurrences = preparedOccurrences.map(\.value)

        let needsContent = request.sections.contains(.files)
        let needsTokenFacts = request.sections.contains(.selection) || request.sections.contains(.tokens)
        let needsMaterialization = needsContent || needsTokenFacts
        let materializedByID: [WorkspaceContextProjectionMaterializationRequest.OccurrenceID: WorkspaceContextProjectionMaterialization.Occurrence]
        if needsMaterialization {
            try Task.checkCancellation()
            let materialization = try await materializer(.init(
                provenance: capture.provenance,
                occurrences: occurrences,
                requiresContent: needsContent,
                requiresTokenFacts: needsTokenFacts
            ))
            try Task.checkCancellation()
            materializedByID = try Self.validateMaterialization(
                materialization,
                expectedProvenance: capture.provenance,
                expected: occurrences,
                requiresTokenFacts: needsTokenFacts
            )
        } else {
            materializedByID = [:]
        }

        let selectionProjection: WorkspaceSelectionProjection?
        if request.sections.contains(.selection) || request.sections.contains(.tokens) {
            try Task.checkCancellation()
            selectionProjection = try WorkspaceSelectionProjectionService.project(.init(
                entries: occurrences.map { occurrence in
                    guard let tokenFacts = materializedByID[occurrence.id]?.tokenFacts else {
                        throw WorkspaceContextProjectionError.missingTokenFacts(occurrence.id)
                    }
                    return WorkspaceSelectionProjectionRequest.Entry(
                        file: occurrence.file,
                        metadata: occurrence.metadata,
                        mode: occurrence.mode,
                        ranges: occurrence.ranges,
                        tokens: .init(
                            displayTokens: tokenFacts.displayTokens,
                            fullTokens: tokenFacts.fullTokens,
                            codemapTokens: occurrence.codemap?.tokens ?? 0
                        ),
                        codemapAvailable: occurrence.codemap != nil,
                        codemapContent: occurrence.codemap?.content
                    )
                },
                completeAlternateEntries: completeAlternateOccurrences.compactMap { prepared in
                    let occurrence = prepared.value
                    guard let codemap = occurrence.codemap else { return nil }
                    return WorkspaceSelectionProjectionRequest.Entry(
                        file: occurrence.file,
                        metadata: occurrence.metadata,
                        mode: .codemap,
                        tokens: .init(
                            displayTokens: codemap.tokens,
                            fullTokens: 0,
                            codemapTokens: codemap.tokens
                        ),
                        codemapAvailable: true,
                        codemapContent: codemap.content
                    )
                },
                codeMapUsage: request.codeMapUsage,
                codemapAutoEnabled: capture.storedSelection.codemapAutoEnabled,
                missingPaths: plan.missingPaths,
                invalidPaths: plan.invalidPaths,
                alternatePolicy: request.alternatePolicy
            ))
            try Task.checkCancellation()
        } else {
            selectionProjection = nil
        }

        let promptSection: WorkspaceContextProjection.Section<String>?
        if request.sections.contains(.prompt) {
            try Task.checkCancellation()
            promptSection = .init(provenance: capture.provenance, value: request.promptText)
            try Task.checkCancellation()
        } else {
            promptSection = nil
        }

        let selectionSection: WorkspaceContextProjection.Section<WorkspaceSelectionProjection>?
        if request.sections.contains(.selection), let selectionProjection {
            try Task.checkCancellation()
            selectionSection = .init(provenance: capture.provenance, value: selectionProjection)
            try Task.checkCancellation()
        } else {
            selectionSection = nil
        }

        let fileBlocksSection: WorkspaceContextProjection.Section<[String]>?
        if request.sections.contains(.files) {
            try Task.checkCancellation()
            let values = occurrences.map { occurrence in
                PromptRenderingFileValue(
                    displayPath: occurrence.metadata.displayPath,
                    fileName: occurrence.file.name,
                    content: occurrence.mode == .codemap ? nil : materializedByID[occurrence.id]?.content,
                    ranges: occurrence.mode == .slice ? occurrence.ranges : nil,
                    codemapText: occurrence.mode == .codemap ? occurrence.codemap?.content : nil
                )
            }
            let blocks = PromptRenderingService.renderFileBlocks(values).map(\.text)
            fileBlocksSection = .init(provenance: capture.provenance, value: blocks)
            try Task.checkCancellation()
        } else {
            fileBlocksSection = nil
        }

        let codeStructureSection: WorkspaceContextProjection.Section<CodeStructureProjection>?
        if request.sections.contains(.codeStructure) {
            try Task.checkCancellation()
            let projection = CodeStructureProjectionService.project(.init(
                entries: preparedOccurrences.map {
                    CodeStructureProjectionRequest.Entry(
                        physicalPath: $0.value.file.standardizedFullPath,
                        displayPath: $0.value.metadata.displayPath,
                        fileAPI: $0.fileAPI
                    )
                },
                budget: request.codeStructureBudget,
                includeUnmappedPaths: request.includeUnmappedCodeStructurePaths
            ))
            codeStructureSection = .init(provenance: capture.provenance, value: projection)
            try Task.checkCancellation()
        } else {
            codeStructureSection = nil
        }

        let fileTreeSection: WorkspaceContextProjection.Section<WorkspaceContextProjection.FileTree>?
        if request.sections.contains(.fileTree) {
            try Task.checkCancellation()
            let content = FileTreeSnapshotRenderer.generateFileTree(using: capture.fileTree)
            fileTreeSection = .init(
                provenance: capture.provenance,
                value: .init(
                    rootCount: capture.fileTree.roots.count,
                    usesLegend: capture.fileTree.includeLegend,
                    content: content
                )
            )
            try Task.checkCancellation()
        } else {
            fileTreeSection = nil
        }

        let tokensSection: WorkspaceContextProjection.Section<WorkspaceContextProjection.TokenViews>?
        if request.sections.contains(.tokens), let selectionProjection {
            try Task.checkCancellation()
            let views: TokenProjectionService.WorkspaceViews = switch request.tokenProjectionInput {
            case let .componentEstimate(source, nonFile):
                TokenProjectionService.workspaceComponentEstimates(
                    from: selectionProjection,
                    source: source,
                    nonFile: nonFile
                )
            case let .activeLive(input):
                TokenProjectionService.activeLiveWorkspaceEstimates(
                    from: selectionProjection,
                    input: input
                )
            }
            tokensSection = .init(
                provenance: capture.provenance,
                value: .init(
                    normalized: views.normalized,
                    userConfigured: views.userConfigured
                )
            )
            try Task.checkCancellation()
        } else {
            tokensSection = nil
        }

        let projection = WorkspaceContextProjection(
            prompt: promptSection,
            selection: selectionSection,
            fileBlocks: fileBlocksSection,
            codeStructure: codeStructureSection,
            fileTree: fileTreeSection,
            tokens: tokensSection
        )
        #if DEBUG
            willReturnForTesting?()
        #endif
        try Task.checkCancellation()
        return projection
    }

    package static func makePlan(
        capture: WorkspaceFileContextCapture,
        request: WorkspaceContextProjectionRequest
    ) throws -> WorkspaceContextProjectionPlan {
        let validated = try validateCapture(capture)
        let preparedOccurrences = makeOccurrences(
            capture: capture,
            rootsByID: validated.rootsByID,
            filesByID: validated.filesByID,
            codemapsByFileID: validated.codemapsByFileID,
            request: request
        )
        let completeAlternateOccurrences = makeCompleteAlternateOccurrences(
            capture: capture,
            rootsByID: validated.rootsByID,
            filesByID: validated.filesByID,
            codemapsByFileID: validated.codemapsByFileID,
            normalized: preparedOccurrences,
            request: request
        )
        let missingPaths = Array(Set(
            validated.selectedMissingPaths
                + validated.sliceMissingPaths
                + (request.codeMapUsage == .auto ? validated.autoCodemapMissingPaths : [])
        )).sorted()
        let invalidPaths = Array(Set(
            validated.selectedInvalidPaths
                + validated.sliceInvalidPaths
                + (request.codeMapUsage == .auto ? validated.autoCodemapInvalidPaths : [])
        )).sorted()
        return WorkspaceContextProjectionPlan(
            provenance: capture.provenance,
            occurrences: preparedOccurrences,
            completeAlternateOccurrences: completeAlternateOccurrences,
            missingPaths: missingPaths,
            invalidPaths: invalidPaths
        )
    }

    private struct ValidatedCapture {
        let rootsByID: [UUID: WorkspaceRootRecord]
        let filesByID: [UUID: WorkspaceFileRecord]
        let codemapsByFileID: [UUID: WorkspaceCodemapSnapshot]
        let selectedMissingPaths: [String]
        let selectedInvalidPaths: [String]
        let autoCodemapMissingPaths: [String]
        let autoCodemapInvalidPaths: [String]
        let sliceMissingPaths: [String]
        let sliceInvalidPaths: [String]
    }

    private static func validateCapture(
        _ capture: WorkspaceFileContextCapture
    ) throws -> ValidatedCapture {
        guard capture.provenance.catalogGeneration == capture.catalog.generation,
              capture.provenance.rootScope == capture.catalog.rootScope,
              capture.catalog.diagnostics.generation == capture.catalog.generation,
              capture.catalog.diagnostics.rootScope == capture.catalog.rootScope
        else {
            throw WorkspaceContextProjectionError.captureProvenanceMismatch
        }

        var rootsByID: [UUID: WorkspaceRootRecord] = [:]
        for root in capture.catalog.roots {
            guard rootsByID.updateValue(root, forKey: root.id) == nil else {
                throw WorkspaceContextProjectionError.duplicateRootID(root.id)
            }
        }

        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        for file in capture.materializedFiles {
            guard rootsByID[file.rootID] != nil else {
                throw WorkspaceContextProjectionError.rootAssociationMismatch(
                    recordID: file.id,
                    rootID: file.rootID
                )
            }
            guard filesByID.updateValue(file, forKey: file.id) == nil else {
                throw WorkspaceContextProjectionError.recordAssociationMismatch(file.id)
            }
        }
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        for folder in capture.materializedFolders {
            guard rootsByID[folder.rootID] != nil else {
                throw WorkspaceContextProjectionError.rootAssociationMismatch(
                    recordID: folder.id,
                    rootID: folder.rootID
                )
            }
            guard foldersByID.updateValue(folder, forKey: folder.id) == nil else {
                throw WorkspaceContextProjectionError.recordAssociationMismatch(folder.id)
            }
        }
        for file in capture.catalog.files {
            guard rootsByID[file.rootID] != nil else {
                throw WorkspaceContextProjectionError.rootAssociationMismatch(
                    recordID: file.id,
                    rootID: file.rootID
                )
            }
        }

        var codemapsByFileID: [UUID: WorkspaceCodemapSnapshot] = [:]
        for codemap in capture.codemapSnapshots {
            guard codemapsByFileID.updateValue(codemap, forKey: codemap.fileID) == nil else {
                throw WorkspaceContextProjectionError.duplicateCodemapFileID(codemap.fileID)
            }
            guard let file = filesByID[codemap.fileID],
                  let root = rootsByID[codemap.rootID],
                  file.rootID == codemap.rootID,
                  StandardizedPath.absolute(codemap.rootPath) == root.standardizedFullPath,
                  StandardizedPath.relative(codemap.relativePath) == file.standardizedRelativePath,
                  StandardizedPath.absolute(codemap.fullPath) == file.standardizedFullPath,
                  codemap.fileAPI.map({ StandardizedPath.absolute($0.filePath) == file.standardizedFullPath }) ?? true
            else {
                throw WorkspaceContextProjectionError.codemapAssociationMismatch(codemap.fileID)
            }
        }

        var selectedMissingPaths: [String] = []
        var selectedInvalidPaths: [String] = []
        try validateSelectionPaths(
            capture.selectedPaths,
            foldersByID: foldersByID,
            filesByID: filesByID,
            missingPaths: &selectedMissingPaths,
            invalidPaths: &selectedInvalidPaths
        )

        var autoCodemapMissingPaths: [String] = []
        var autoCodemapInvalidPaths: [String] = []
        try validateSelectionPaths(
            capture.autoCodemapPaths,
            foldersByID: foldersByID,
            filesByID: filesByID,
            missingPaths: &autoCodemapMissingPaths,
            invalidPaths: &autoCodemapInvalidPaths
        )

        var sliceMissingPaths: [String] = []
        var sliceInvalidPaths: [String] = []
        for slice in capture.slices {
            if let file = slice.file {
                try validateCapturedFile(file, filesByID: filesByID)
            } else {
                appendPath(
                    slice.path,
                    issue: slice.issue ?? .unresolved(input: slice.path),
                    missingPaths: &sliceMissingPaths,
                    invalidPaths: &sliceInvalidPaths
                )
            }
        }

        try validateTree(
            capture.fileTree.roots,
            rootsByID: rootsByID,
            foldersByID: foldersByID,
            filesByID: filesByID
        )

        return ValidatedCapture(
            rootsByID: rootsByID,
            filesByID: filesByID,
            codemapsByFileID: codemapsByFileID,
            selectedMissingPaths: Array(Set(selectedMissingPaths)).sorted(),
            selectedInvalidPaths: Array(Set(selectedInvalidPaths)).sorted(),
            autoCodemapMissingPaths: Array(Set(autoCodemapMissingPaths)).sorted(),
            autoCodemapInvalidPaths: Array(Set(autoCodemapInvalidPaths)).sorted(),
            sliceMissingPaths: Array(Set(sliceMissingPaths)).sorted(),
            sliceInvalidPaths: Array(Set(sliceInvalidPaths)).sorted()
        )
    }

    private static func validateSelectionPaths(
        _ paths: [WorkspaceFileContextCapture.SelectionPath],
        foldersByID: [UUID: WorkspaceFolderRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        missingPaths: inout [String],
        invalidPaths: inout [String]
    ) throws {
        for path in paths {
            switch path.resolution {
            case let .file(file):
                try validateCapturedFile(file, filesByID: filesByID)
            case let .folder(folder, descendantFiles):
                guard foldersByID[folder.id] == folder else {
                    throw WorkspaceContextProjectionError.recordAssociationMismatch(folder.id)
                }
                for file in descendantFiles {
                    try validateCapturedFile(file, filesByID: filesByID)
                }
            case let .unresolved(issue):
                appendPath(
                    path.input,
                    issue: issue,
                    missingPaths: &missingPaths,
                    invalidPaths: &invalidPaths
                )
            }
        }
    }

    private static func validateCapturedFile(
        _ file: WorkspaceFileRecord,
        filesByID: [UUID: WorkspaceFileRecord]
    ) throws {
        guard filesByID[file.id] == file else {
            throw WorkspaceContextProjectionError.recordAssociationMismatch(file.id)
        }
    }

    private static func appendPath(
        _ path: String,
        issue: PathResolutionIssue,
        missingPaths: inout [String],
        invalidPaths: inout [String]
    ) {
        if case .unresolved = issue {
            missingPaths.append(path)
        } else {
            invalidPaths.append(path)
        }
    }

    private static func validateTree(
        _ folders: [FileTreeFolderSnapshot],
        rootsByID: [UUID: WorkspaceRootRecord],
        foldersByID: [UUID: WorkspaceFolderRecord],
        filesByID: [UUID: WorkspaceFileRecord]
    ) throws {
        for folder in folders {
            guard let capturedFolder = foldersByID[folder.id],
                  let root = rootsByID[capturedFolder.rootID],
                  folder.standardizedFullPath == capturedFolder.standardizedFullPath,
                  folder.standardizedRootPath == root.standardizedFullPath
            else {
                throw WorkspaceContextProjectionError.recordAssociationMismatch(folder.id)
            }
            for child in folder.children {
                switch child {
                case let .folder(childFolder):
                    try validateTree(
                        [childFolder],
                        rootsByID: rootsByID,
                        foldersByID: foldersByID,
                        filesByID: filesByID
                    )
                case let .file(file):
                    guard filesByID[file.id] != nil else {
                        throw WorkspaceContextProjectionError.recordAssociationMismatch(file.id)
                    }
                }
            }
        }
    }

    private static func makeOccurrences(
        capture: WorkspaceFileContextCapture,
        rootsByID: [UUID: WorkspaceRootRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        codemapsByFileID: [UUID: WorkspaceCodemapSnapshot],
        request: WorkspaceContextProjectionRequest
    ) -> [WorkspaceContextProjectionPlan.Occurrence] {
        let multipleRoots = capture.catalog.roots.count > 1

        var prepared: [WorkspaceContextProjectionPlan.Occurrence] = []
        var seenKeys = Set<OccurrenceKey>()
        var selectedFileIDs = Set<UUID>()

        func append(_ file: WorkspaceFileRecord, ranges: [LineRange], forceCodemap: Bool) {
            selectedFileIDs.insert(file.id)
            let codemapSnapshot = codemapsByFileID[file.id]
            let fileAPI = codemapSnapshot?.fileAPI
            let mode: WorkspaceSelectionProjection.BaseMode = if forceCodemap, fileAPI != nil {
                .codemap
            } else if !ranges.isEmpty {
                .slice
            } else {
                .full
            }
            let keyMode: OccurrenceKey.Mode = switch mode {
            case .full: .full
            case .slice: .slice
            case .codemap: .codemap
            }
            let effectiveRanges = mode == .slice ? ranges : []
            let key = OccurrenceKey(fileID: file.id, mode: keyMode, ranges: effectiveRanges)
            guard seenKeys.insert(key).inserted, let root = rootsByID[file.rootID] else { return }

            let displayPath: String = switch request.filePathDisplay {
            case .full:
                file.fullPath
            case .relative:
                multipleRoots && !root.name.isEmpty
                    ? root.name + "/" + file.standardizedRelativePath
                    : file.standardizedRelativePath
            }
            let metadata = WorkspaceSelectionProjection.PathMetadata(
                displayPath: displayPath,
                rootPath: root.fullPath,
                pathWithinRoot: file.standardizedRelativePath
            )
            let codemap: WorkspaceContextProjectionMaterializationRequest.Codemap? = fileAPI.map {
                .init(
                    content: $0.getFullAPIDescription(displayPath: displayPath),
                    tokens: $0.apiTokenCount
                )
            }
            let occurrence = WorkspaceContextProjectionMaterializationRequest.Occurrence(
                id: .init(rawValue: prepared.count),
                file: file,
                metadata: metadata,
                mode: mode,
                ranges: effectiveRanges,
                codemap: codemap
            )
            prepared.append(.init(value: occurrence, fileAPI: fileAPI))
        }

        let selectedForceCodemap = request.codeMapUsage == .selected
        for path in capture.selectedPaths {
            switch path.resolution {
            case let .file(file):
                append(
                    file,
                    ranges: sliceRanges(
                        for: path.input,
                        file: file,
                        slices: capture.storedSelection.slices
                    ) ?? [],
                    forceCodemap: selectedForceCodemap
                )
            case let .folder(_, descendantFiles):
                for file in descendantFiles {
                    append(file, ranges: [], forceCodemap: selectedForceCodemap)
                }
            case .unresolved:
                break
            }
        }

        for slice in capture.slices {
            guard let file = slice.file, !selectedFileIDs.contains(file.id) else { continue }
            append(file, ranges: slice.ranges, forceCodemap: false)
        }

        switch request.codeMapUsage {
        case .none, .selected:
            break
        case .auto:
            for path in capture.autoCodemapPaths {
                switch path.resolution {
                case let .file(file):
                    guard !selectedFileIDs.contains(file.id), codemapsByFileID[file.id]?.fileAPI != nil else { continue }
                    append(file, ranges: [], forceCodemap: true)
                case let .folder(_, descendantFiles):
                    for file in descendantFiles where !selectedFileIDs.contains(file.id) && codemapsByFileID[file.id]?.fileAPI != nil {
                        append(file, ranges: [], forceCodemap: true)
                    }
                case .unresolved:
                    break
                }
            }
        case .complete:
            for codemap in capture.codemapSnapshots where codemap.fileAPI != nil && !selectedFileIDs.contains(codemap.fileID) {
                guard let file = filesByID[codemap.fileID] else { continue }
                append(file, ranges: [], forceCodemap: true)
            }
        }

        return prepared
    }

    private static func makeCompleteAlternateOccurrences(
        capture: WorkspaceFileContextCapture,
        rootsByID: [UUID: WorkspaceRootRecord],
        filesByID: [UUID: WorkspaceFileRecord],
        codemapsByFileID: [UUID: WorkspaceCodemapSnapshot],
        normalized: [WorkspaceContextProjectionPlan.Occurrence],
        request: WorkspaceContextProjectionRequest
    ) -> [WorkspaceContextProjectionPlan.Occurrence] {
        guard request.alternatePolicy?.codeMapUsage == .complete,
              request.codeMapUsage != .complete,
              request.sections.contains(.selection) || request.sections.contains(.tokens)
        else { return [] }

        let normalizedFileIDs = Set(normalized.map(\.value.file.id))
        let complete = makeOccurrences(
            capture: capture,
            rootsByID: rootsByID,
            filesByID: filesByID,
            codemapsByFileID: codemapsByFileID,
            request: .init(
                sections: request.sections,
                filePathDisplay: request.filePathDisplay,
                codeMapUsage: .complete
            )
        )
        return complete.filter {
            $0.value.mode == .codemap && !normalizedFileIDs.contains($0.value.file.id)
        }
    }

    private static func sliceRanges(
        for input: String,
        file: WorkspaceFileRecord,
        slices: [String: [LineRange]]
    ) -> [LineRange]? {
        let candidateKeys = [
            input,
            StandardizedPath.absolute(input),
            file.relativePath,
            file.standardizedRelativePath,
            file.fullPath,
            file.standardizedFullPath
        ]
        for key in candidateKeys {
            if let ranges = slices[key] { return ranges }
        }
        return nil
    }

    private static func validateMaterialization(
        _ materialization: WorkspaceContextProjectionMaterialization,
        expectedProvenance: WorkspaceFileContextCapture.Provenance,
        expected: [WorkspaceContextProjectionMaterializationRequest.Occurrence],
        requiresTokenFacts: Bool
    ) throws -> [WorkspaceContextProjectionMaterializationRequest.OccurrenceID: WorkspaceContextProjectionMaterialization.Occurrence] {
        guard materialization.provenance == expectedProvenance else {
            throw WorkspaceContextProjectionError.materializationProvenanceMismatch
        }

        let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.id, $0) })
        var materializedByID: [WorkspaceContextProjectionMaterializationRequest.OccurrenceID: WorkspaceContextProjectionMaterialization.Occurrence] = [:]
        var unexpectedIDs: [WorkspaceContextProjectionMaterializationRequest.OccurrenceID] = []

        for occurrence in materialization.occurrences {
            guard materializedByID.updateValue(occurrence, forKey: occurrence.id) == nil else {
                throw WorkspaceContextProjectionError.duplicateOccurrenceID(occurrence.id)
            }
            guard let expectedOccurrence = expectedByID[occurrence.id] else {
                unexpectedIDs.append(occurrence.id)
                continue
            }
            if requiresTokenFacts {
                guard let tokenFacts = occurrence.tokenFacts else {
                    throw WorkspaceContextProjectionError.missingTokenFacts(occurrence.id)
                }
                guard tokenFacts.displayTokens >= 0, tokenFacts.fullTokens >= 0 else {
                    throw WorkspaceContextProjectionError.invalidTokenFacts(occurrence.id)
                }
                switch expectedOccurrence.mode {
                case .full:
                    guard tokenFacts.displayTokens == tokenFacts.fullTokens else {
                        throw WorkspaceContextProjectionError.invalidTokenFacts(occurrence.id)
                    }
                case .slice:
                    break
                case .codemap:
                    guard tokenFacts.displayTokens == expectedOccurrence.codemap?.tokens else {
                        throw WorkspaceContextProjectionError.invalidTokenFacts(occurrence.id)
                    }
                }
            }
        }

        if !unexpectedIDs.isEmpty {
            throw WorkspaceContextProjectionError.unexpectedOccurrenceIDs(unexpectedIDs.sorted())
        }
        let missingIDs = expectedByID.keys.filter { materializedByID[$0] == nil }.sorted()
        if !missingIDs.isEmpty {
            throw WorkspaceContextProjectionError.missingOccurrenceIDs(missingIDs)
        }
        return materializedByID
    }
}
