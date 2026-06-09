import Foundation
import RepoPromptCore

struct WorkspacePromptProjectionAdapter {
    enum Error: Swift.Error, Equatable {
        case missingSelectionProjection
        case missingTokenProjection
        case projectionProvenanceMismatch
        case missingTokenFacts(OccurrenceIdentity)
        case unusedTokenFacts([OccurrenceIdentity])
    }

    struct OccurrenceIdentity: Equatable, Hashable {
        enum Mode: Equatable, Hashable {
            case full
            case slice
            case codemap
        }

        let fileID: UUID
        let standardizedPath: String
        let mode: Mode
        let ranges: [LineRange]
    }

    struct Entry: Equatable {
        let file: WorkspaceFileRecord
        let metadata: WorkspaceSelectionProjection.PathMetadata
        let mode: WorkspaceSelectionProjection.RenderMode
        let ranges: [LineRange]?
        let codemapOrigin: WorkspaceSelectionProjection.CodemapOrigin?
    }

    struct Projection: Equatable {
        let provenance: WorkspaceFileContextCapture.Provenance
        let entries: [Entry]
    }

    struct TokenAwareProjection: Equatable {
        let provenance: WorkspaceFileContextCapture.Provenance
        let selection: WorkspaceSelectionProjection
        let tokens: WorkspaceContextProjection.TokenViews
    }

    typealias CaptureOperation = @Sendable (
        _ selection: StoredSelection,
        _ fileTreeRequest: WorkspaceFileTreeSnapshotRequest,
        _ profile: PathLocateProfile,
        _ coverage: WorkspaceFileContextCaptureCoverage
    ) async throws -> WorkspaceFileContextCapture

    typealias TokenEvaluationOperation = @Sendable ([PromptFileEntrySnapshot]) async -> PromptEntriesEvaluation

    private struct SnapshotMatchKey: Hashable {
        let fileID: UUID
        let isCodemapRequested: Bool
        let ranges: [LineRange]
    }

    private struct TokenFactMatchKey: Hashable {
        let identity: OccurrenceIdentity
        let modificationDate: Date?
    }

    private struct MatchedTokenEntry {
        let identity: OccurrenceIdentity
        let modificationDate: Date?
        let snapshot: PromptFileEntrySnapshot
    }

    private struct OccurrenceTokenFact {
        let identity: OccurrenceIdentity
        let modificationDate: Date?
        let displayTokens: Int
        let fullTokens: Int
    }

    private let capture: CaptureOperation
    private let evaluatePromptEntries: TokenEvaluationOperation

    init(store: WorkspaceFileContextStore) {
        let tokenCalculationService = TokenCalculationService()
        capture = { selection, fileTreeRequest, profile, coverage in
            try await store.captureWorkspaceFileContext(
                selection: selection,
                fileTreeRequest: fileTreeRequest,
                profile: profile,
                coverage: coverage
            )
        }
        evaluatePromptEntries = { snapshots in
            await tokenCalculationService.evaluatePromptEntries(snapshots)
        }
    }

    init(capture: @escaping CaptureOperation) {
        let tokenCalculationService = TokenCalculationService()
        self.capture = capture
        evaluatePromptEntries = { snapshots in
            await tokenCalculationService.evaluatePromptEntries(snapshots)
        }
    }

    init(
        capture: @escaping CaptureOperation,
        evaluatePromptEntries: @escaping TokenEvaluationOperation
    ) {
        self.capture = capture
        self.evaluatePromptEntries = evaluatePromptEntries
    }

    func project(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) async throws -> Projection {
        let capture = try await captureWorkspaceContext(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay
        )
        return try await project(
            capture: capture,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay
        )
    }

    private func project(
        capture: WorkspaceFileContextCapture,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) async throws -> Projection {
        let projection = try await projectContext(
            capture: capture,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            sections: [.selection],
            materializer: { request in
                try await Self.materializeSelectionProjection(request)
            }
        )
        guard let selectionProjection = projection.selection else {
            throw Error.missingSelectionProjection
        }

        return Projection(
            provenance: selectionProjection.provenance,
            entries: selectionProjection.value.files.compactMap { file in
                guard file.mode != .hidden else { return nil }
                return Entry(
                    file: file.file,
                    metadata: file.metadata,
                    mode: file.mode,
                    ranges: file.ranges,
                    codemapOrigin: file.codemapOrigin
                )
            }
        )
    }

    func projectTokens(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy?,
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot],
        tokenProjectionInput: WorkspaceTokenProjectionInput
    ) async throws -> TokenAwareProjection {
        let tokenFacts = try await makeOccurrenceTokenFacts(
            resolvedEntries: resolvedEntries,
            promptFileEntrySnapshots: promptFileEntrySnapshots
        )
        let capture = try await captureWorkspaceContext(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            alternatePolicy: alternatePolicy
        )
        return try await projectTokens(
            capture: capture,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            alternatePolicy: alternatePolicy,
            tokenFacts: tokenFacts,
            tokenProjectionInput: tokenProjectionInput
        )
    }

    func captureWorkspaceContext(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy? = nil,
        fileTreeRequest: WorkspaceFileTreeSnapshotRequest? = nil
    ) async throws -> WorkspaceFileContextCapture {
        let codemapCoverage: WorkspaceFileContextCaptureCoverage.CodemapCoverage = if codeMapUsage == .complete
            || alternatePolicy?.codeMapUsage == .complete
        {
            .allAvailable
        } else {
            .referenced
        }
        return try await capture(
            selection,
            fileTreeRequest ?? WorkspaceFileTreeSnapshotRequest(
                mode: .none,
                filePathDisplay: filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: false,
                rootScope: .allLoaded
            ),
            .uiAssisted,
            .projection(codemapCoverage: codemapCoverage)
        )
    }

    func projectTokens(
        capture: WorkspaceFileContextCapture,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy?,
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot],
        tokenProjectionInput: WorkspaceTokenProjectionInput
    ) async throws -> TokenAwareProjection {
        let tokenFacts = try await makeOccurrenceTokenFacts(
            resolvedEntries: resolvedEntries,
            promptFileEntrySnapshots: promptFileEntrySnapshots
        )
        return try await projectTokens(
            capture: capture,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            alternatePolicy: alternatePolicy,
            tokenFacts: tokenFacts,
            tokenProjectionInput: tokenProjectionInput
        )
    }

    private func projectTokens(
        capture: WorkspaceFileContextCapture,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy?,
        tokenFacts: [OccurrenceTokenFact],
        tokenProjectionInput: WorkspaceTokenProjectionInput
    ) async throws -> TokenAwareProjection {
        let projection = try await projectContext(
            capture: capture,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            sections: [.selection, .tokens],
            alternatePolicy: alternatePolicy,
            tokenProjectionInput: tokenProjectionInput,
            materializer: { request in
                try Self.materializeTokenProjection(request, tokenFacts: tokenFacts)
            }
        )
        guard let selectionProjection = projection.selection else {
            throw Error.missingSelectionProjection
        }
        guard let tokenProjection = projection.tokens else {
            throw Error.missingTokenProjection
        }
        guard selectionProjection.provenance == tokenProjection.provenance else {
            throw Error.projectionProvenanceMismatch
        }

        return TokenAwareProjection(
            provenance: selectionProjection.provenance,
            selection: selectionProjection.value,
            tokens: tokenProjection.value
        )
    }

    @MainActor
    func mapToLivePromptEntries(
        _ projection: Projection,
        resolveFile: (WorkspaceFileRecord) -> FileViewModel?
    ) -> [PromptFileEntry] {
        projection.entries.compactMap { entry in
            guard let file = resolveFile(entry.file),
                  file.id == entry.file.id,
                  file.standardizedFullPath == entry.file.standardizedFullPath
            else { return nil }

            return PromptFileEntry(
                file: file,
                isCodemap: entry.mode == .codemap,
                ranges: entry.mode == .slice ? entry.ranges : nil
            )
        }
    }

    private func projectContext(
        capture: WorkspaceFileContextCapture,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        sections: WorkspaceContextProjectionRequest.Sections,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy? = nil,
        tokenProjectionInput: WorkspaceTokenProjectionInput = .emptyVirtual,
        materializer: @escaping WorkspaceContextProjectionService.Materializer
    ) async throws -> WorkspaceContextProjection {
        let service = WorkspaceContextProjectionService(
            capture: {
                capture
            },
            materializer: materializer
        )
        return try await service.project(.init(
            sections: sections,
            filePathDisplay: filePathDisplay,
            codeMapUsage: codeMapUsage,
            alternatePolicy: alternatePolicy,
            tokenProjectionInput: tokenProjectionInput
        ))
    }

    private func makeOccurrenceTokenFacts(
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot]
    ) async throws -> [OccurrenceTokenFact] {
        var snapshotIndicesByKey: [SnapshotMatchKey: [Int]] = [:]
        snapshotIndicesByKey.reserveCapacity(promptFileEntrySnapshots.count)
        for (index, snapshot) in promptFileEntrySnapshots.enumerated() {
            let key = SnapshotMatchKey(
                fileID: snapshot.fileID,
                isCodemapRequested: snapshot.isCodemapRequested,
                ranges: snapshot.ranges ?? []
            )
            snapshotIndicesByKey[key, default: []].append(index)
        }

        var snapshotCursorsByKey: [SnapshotMatchKey: Int] = [:]
        var matchedEntries: [MatchedTokenEntry] = []
        matchedEntries.reserveCapacity(resolvedEntries.count)
        var firstMissing: (index: Int, identity: OccurrenceIdentity)?

        for (index, entry) in resolvedEntries.enumerated() {
            let identity = Self.occurrenceIdentity(for: entry)
            let key = SnapshotMatchKey(
                fileID: entry.file.id,
                isCodemapRequested: entry.isCodemap,
                ranges: identity.ranges
            )
            let cursor = snapshotCursorsByKey[key, default: 0]
            guard let indices = snapshotIndicesByKey[key], cursor < indices.count else {
                firstMissing = (index, identity)
                break
            }
            snapshotCursorsByKey[key] = cursor + 1
            matchedEntries.append(MatchedTokenEntry(
                identity: identity,
                modificationDate: entry.file.modificationDate,
                snapshot: promptFileEntrySnapshots[indices[cursor]]
            ))
        }

        var batchIndices: [[Int]] = []
        var nextBatchByFileID: [UUID: Int] = [:]
        for index in matchedEntries.indices {
            let fileID = matchedEntries[index].snapshot.fileID
            let batchIndex = nextBatchByFileID[fileID, default: 0]
            nextBatchByFileID[fileID] = batchIndex + 1
            while batchIndices.count <= batchIndex {
                batchIndices.append([])
            }
            batchIndices[batchIndex].append(index)
        }

        var results: [PromptEntriesEvaluation.EntryResult?] = Array(
            repeating: nil,
            count: matchedEntries.count
        )
        for indices in batchIndices {
            let evaluation = await evaluatePromptEntries(indices.map { matchedEntries[$0].snapshot })
            for index in indices {
                let fileID = matchedEntries[index].snapshot.fileID
                results[index] = evaluation.entryResultsByFileID[fileID]
            }
        }

        var facts: [OccurrenceTokenFact] = []
        facts.reserveCapacity(matchedEntries.count)
        for index in resolvedEntries.indices {
            if let firstMissing, firstMissing.index == index {
                throw Error.missingTokenFacts(firstMissing.identity)
            }
            guard index < matchedEntries.count else { break }
            let matched = matchedEntries[index]
            guard let result = results[index],
                  result.renderMode == Self.evaluationMode(for: matched.identity.mode)
            else {
                throw Error.missingTokenFacts(matched.identity)
            }
            facts.append(OccurrenceTokenFact(
                identity: matched.identity,
                modificationDate: matched.modificationDate,
                displayTokens: result.displayTokens,
                fullTokens: result.fullTokens
            ))
        }
        return facts
    }

    private static func materializeTokenProjection(
        _ request: WorkspaceContextProjectionMaterializationRequest,
        tokenFacts: [OccurrenceTokenFact]
    ) throws -> WorkspaceContextProjectionMaterialization {
        var factIndicesByKey: [TokenFactMatchKey: [Int]] = [:]
        factIndicesByKey.reserveCapacity(tokenFacts.count)
        for (index, fact) in tokenFacts.enumerated() {
            let key = TokenFactMatchKey(
                identity: fact.identity,
                modificationDate: fact.modificationDate
            )
            factIndicesByKey[key, default: []].append(index)
        }

        var factCursorsByKey: [TokenFactMatchKey: Int] = [:]
        var consumedFacts = Array(repeating: false, count: tokenFacts.count)
        var occurrences: [WorkspaceContextProjectionMaterialization.Occurrence] = []
        occurrences.reserveCapacity(request.occurrences.count)

        for occurrence in request.occurrences {
            let identity = occurrenceIdentity(for: occurrence)
            let key = TokenFactMatchKey(
                identity: identity,
                modificationDate: occurrence.file.modificationDate
            )
            let cursor = factCursorsByKey[key, default: 0]
            guard let indices = factIndicesByKey[key], cursor < indices.count else {
                throw Error.missingTokenFacts(identity)
            }
            factCursorsByKey[key] = cursor + 1
            let factIndex = indices[cursor]
            consumedFacts[factIndex] = true
            let fact = tokenFacts[factIndex]
            occurrences.append(.init(
                id: occurrence.id,
                content: nil,
                tokenFacts: .init(
                    displayTokens: fact.displayTokens,
                    fullTokens: fact.fullTokens
                )
            ))
        }

        let unusedIdentities = tokenFacts.indices.compactMap { index in
            consumedFacts[index] ? nil : tokenFacts[index].identity
        }
        guard unusedIdentities.isEmpty else {
            throw Error.unusedTokenFacts(unusedIdentities)
        }
        return WorkspaceContextProjectionMaterialization(
            provenance: request.provenance,
            occurrences: occurrences
        )
    }

    private static func occurrenceIdentity(
        for entry: ResolvedPromptFileEntry
    ) -> OccurrenceIdentity {
        let mode: OccurrenceIdentity.Mode = switch entry.mode {
        case .fullFile:
            .full
        case .sliced:
            .slice
        case .codemap:
            .codemap
        }
        return OccurrenceIdentity(
            fileID: entry.file.id,
            standardizedPath: entry.file.standardizedFullPath,
            mode: mode,
            ranges: entry.lineRanges ?? []
        )
    }

    private static func occurrenceIdentity(
        for occurrence: WorkspaceContextProjectionMaterializationRequest.Occurrence
    ) -> OccurrenceIdentity {
        let mode: OccurrenceIdentity.Mode = switch occurrence.mode {
        case .full:
            .full
        case .slice:
            .slice
        case .codemap:
            .codemap
        }
        return OccurrenceIdentity(
            fileID: occurrence.file.id,
            standardizedPath: occurrence.file.standardizedFullPath,
            mode: mode,
            ranges: occurrence.ranges
        )
    }

    private static func evaluationMode(
        for mode: OccurrenceIdentity.Mode
    ) -> PromptEntriesEvaluation.RenderMode {
        switch mode {
        case .full: .full
        case .slice: .slice
        case .codemap: .codemap
        }
    }

    private static func materializeSelectionProjection(
        _ request: WorkspaceContextProjectionMaterializationRequest
    ) async throws -> WorkspaceContextProjectionMaterialization {
        WorkspaceContextProjectionMaterialization(
            provenance: request.provenance,
            occurrences: request.occurrences.map { occurrence in
                let displayTokens = occurrence.mode == .codemap
                    ? occurrence.codemap?.tokens ?? 0
                    : 0
                return .init(
                    id: occurrence.id,
                    content: nil,
                    tokenFacts: .init(
                        displayTokens: displayTokens,
                        fullTokens: 0
                    )
                )
            }
        )
    }
}
