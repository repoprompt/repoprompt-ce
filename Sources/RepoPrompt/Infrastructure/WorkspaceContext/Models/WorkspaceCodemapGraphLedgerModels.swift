import Foundation
import RepoPromptCodeMapCore

enum WorkspaceCodemapGraphTerminalArtifactReason: Hashable {
    case oversize
    case decodeFailed
    case parseFailed
}

enum WorkspaceCodemapGraphTerminalExclusionReason: Hashable {
    case securityExcluded
    case nonRegular
    case gitlink
    case repositoryBoundary
}

enum WorkspaceCodemapGraphSlotState: Hashable {
    case pending
    case contributed(CodeMapSelectionGraphContribution)
    case empty(CodeMapSelectionGraphContribution)
    case terminalArtifact(WorkspaceCodemapGraphTerminalArtifactReason)
    case terminalExcluded(WorkspaceCodemapGraphTerminalExclusionReason)
}

enum WorkspaceCodemapGraphSlotSource: Hashable {
    case cleanManifest
    case live
    case graphIndex
}

struct WorkspaceCodemapGraphSlotDiagnostics: Hashable {
    let contributionDigest: CodeMapSHA256Digest?
    let source: WorkspaceCodemapGraphSlotSource?
}

enum WorkspaceCodemapGraphSlotValidationError: Error, Hashable {
    case rootMismatch
    case pipelineMismatch
    case contributedWithoutNames
    case emptyWithNames
    case contributionDigestMismatch
}

struct WorkspaceCodemapGraphSlot: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let pipelineIdentity: CodeMapPipelineIdentity
    let state: WorkspaceCodemapGraphSlotState
    let diagnostics: WorkspaceCodemapGraphSlotDiagnostics?

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        identity: WorkspaceCodemapArtifactBindingIdentity,
        requestGeneration: UInt64,
        pathGeneration: UInt64,
        pipelineIdentity: CodeMapPipelineIdentity,
        state: WorkspaceCodemapGraphSlotState,
        diagnostics: WorkspaceCodemapGraphSlotDiagnostics?
    ) {
        self.rootEpoch = rootEpoch
        self.identity = identity
        self.requestGeneration = requestGeneration
        self.pathGeneration = pathGeneration
        self.pipelineIdentity = pipelineIdentity
        self.state = state
        self.diagnostics = diagnostics
    }

    static func validated(
        rootEpoch: WorkspaceCodemapRootEpoch,
        identity: WorkspaceCodemapArtifactBindingIdentity,
        requestGeneration: UInt64,
        pathGeneration: UInt64,
        pipelineIdentity: CodeMapPipelineIdentity,
        state: WorkspaceCodemapGraphSlotState,
        diagnostics: WorkspaceCodemapGraphSlotDiagnostics? = nil
    ) -> Result<Self, WorkspaceCodemapGraphSlotValidationError> {
        guard identity.rootID == rootEpoch.rootID,
              identity.rootLifetimeID == rootEpoch.rootLifetimeID
        else { return .failure(.rootMismatch) }

        let contribution: CodeMapSelectionGraphContribution?
        switch state {
        case .pending, .terminalArtifact, .terminalExcluded:
            contribution = nil
        case let .contributed(value):
            guard !value.sortedUniqueDefinitions.isEmpty || !value.sortedUniqueReferences.isEmpty else {
                return .failure(.contributedWithoutNames)
            }
            contribution = value
        case let .empty(value):
            guard value.sortedUniqueDefinitions.isEmpty, value.sortedUniqueReferences.isEmpty else {
                return .failure(.emptyWithNames)
            }
            contribution = value
        }

        if let contribution {
            guard contribution.artifactKey.pipelineIdentity == pipelineIdentity else {
                return .failure(.pipelineMismatch)
            }
            if let diagnosticDigest = diagnostics?.contributionDigest,
               diagnosticDigest != contribution.contributionDigest
            {
                return .failure(.contributionDigestMismatch)
            }
        }

        return .success(Self(
            rootEpoch: rootEpoch,
            identity: identity,
            requestGeneration: requestGeneration,
            pathGeneration: pathGeneration,
            pipelineIdentity: pipelineIdentity,
            state: state,
            diagnostics: diagnostics
        ))
    }

    var fileID: UUID {
        identity.fileID
    }

    var standardizedRelativePath: String {
        identity.standardizedRelativePath
    }
}

enum WorkspaceCodemapGraphCatalogEnumerationState: Hashable {
    case notStarted
    case partial
    case complete
}

enum WorkspaceCodemapGraphCatalogCoverageValidationError: Error, Hashable {
    case rootMismatch
    case missingCatalogWatermark
    case unexpectedCatalogWatermark
    case nonzeroNotStartedCount
    case accountingOverflow
    case classifiedCountMismatch(expected: UInt64, actual: UInt64)
    case supportedCountMismatch(expected: UInt64, actual: UInt64)
    case completeWithPendingSupportedSlots(UInt64)
}

struct WorkspaceCodemapGraphCatalogCoverage: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken?
    let enumerationState: WorkspaceCodemapGraphCatalogEnumerationState
    let supportedCount: UInt64
    let classifiedCount: UInt64
    let pendingCount: UInt64
    let contributedCount: UInt64
    let emptyCount: UInt64
    let terminalArtifactCount: UInt64
    let terminalExcludedCount: UInt64

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken?,
        enumerationState: WorkspaceCodemapGraphCatalogEnumerationState,
        supportedCount: UInt64,
        classifiedCount: UInt64,
        pendingCount: UInt64,
        contributedCount: UInt64,
        emptyCount: UInt64,
        terminalArtifactCount: UInt64,
        terminalExcludedCount: UInt64
    ) {
        self.rootEpoch = rootEpoch
        self.catalogWatermark = catalogWatermark
        self.enumerationState = enumerationState
        self.supportedCount = supportedCount
        self.classifiedCount = classifiedCount
        self.pendingCount = pendingCount
        self.contributedCount = contributedCount
        self.emptyCount = emptyCount
        self.terminalArtifactCount = terminalArtifactCount
        self.terminalExcludedCount = terminalExcludedCount
    }

    static func validated(
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken?,
        enumerationState: WorkspaceCodemapGraphCatalogEnumerationState,
        supportedCount: UInt64,
        classifiedCount: UInt64,
        pendingCount: UInt64,
        contributedCount: UInt64,
        emptyCount: UInt64,
        terminalArtifactCount: UInt64,
        terminalExcludedCount: UInt64
    ) -> Result<Self, WorkspaceCodemapGraphCatalogCoverageValidationError> {
        if let catalogWatermark {
            guard catalogWatermark.rootEpoch == rootEpoch else { return .failure(.rootMismatch) }
        }
        switch enumerationState {
        case .notStarted:
            guard catalogWatermark == nil else { return .failure(.unexpectedCatalogWatermark) }
            guard supportedCount == 0,
                  classifiedCount == 0,
                  pendingCount == 0,
                  contributedCount == 0,
                  emptyCount == 0,
                  terminalArtifactCount == 0,
                  terminalExcludedCount == 0
            else { return .failure(.nonzeroNotStartedCount) }
        case .partial, .complete:
            guard catalogWatermark != nil else { return .failure(.missingCatalogWatermark) }
        }

        guard let terminalCount = workspaceCodemapGraphAdding(
            terminalArtifactCount,
            terminalExcludedCount
        ), let contributedAndEmptyCount = workspaceCodemapGraphAdding(contributedCount, emptyCount),
        let expectedClassifiedCount = workspaceCodemapGraphAdding(contributedAndEmptyCount, terminalCount),
        let expectedSupportedCount = workspaceCodemapGraphAdding(expectedClassifiedCount, pendingCount)
        else { return .failure(.accountingOverflow) }
        guard classifiedCount == expectedClassifiedCount else {
            return .failure(.classifiedCountMismatch(
                expected: expectedClassifiedCount,
                actual: classifiedCount
            ))
        }
        guard supportedCount == expectedSupportedCount else {
            return .failure(.supportedCountMismatch(
                expected: expectedSupportedCount,
                actual: supportedCount
            ))
        }
        if enumerationState == .complete, pendingCount != 0 {
            return .failure(.completeWithPendingSupportedSlots(pendingCount))
        }

        return .success(Self(
            rootEpoch: rootEpoch,
            catalogWatermark: catalogWatermark,
            enumerationState: enumerationState,
            supportedCount: supportedCount,
            classifiedCount: classifiedCount,
            pendingCount: pendingCount,
            contributedCount: contributedCount,
            emptyCount: emptyCount,
            terminalArtifactCount: terminalArtifactCount,
            terminalExcludedCount: terminalExcludedCount
        ))
    }

    var terminalCount: UInt64 {
        terminalArtifactCount + terminalExcludedCount
    }

    var isComplete: Bool {
        enumerationState == .complete && pendingCount == 0
    }
}

enum WorkspaceCodemapGraphRemovalReason: Hashable {
    case replaced
    case deleted
    case renamed
    case securityExcluded

    var requiresSafetyFence: Bool {
        switch self {
        case .replaced: false
        case .deleted, .renamed, .securityExcluded: true
        }
    }
}

struct WorkspaceCodemapGraphRemoval: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let standardizedRelativePath: String
    let reason: WorkspaceCodemapGraphRemovalReason

    init?(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        standardizedRelativePath: String,
        reason: WorkspaceCodemapGraphRemovalReason
    ) {
        let standardizedPath = StandardizedPath.relative(standardizedRelativePath)
        guard !standardizedPath.isEmpty,
              standardizedPath == standardizedRelativePath,
              standardizedPath != "..",
              !standardizedPath.hasPrefix("../")
        else { return nil }
        self.rootEpoch = rootEpoch
        self.fileID = fileID
        self.standardizedRelativePath = standardizedPath
        self.reason = reason
    }
}

enum WorkspaceCodemapGraphCheckpointValidationError: Error, Hashable {
    case invalidSchemaVersion
    case invalidPolicyVersion
    case coverageRootMismatch
    case slotRootMismatch(UUID)
    case duplicateFileID(UUID)
    case duplicateRelativePath(String)
    case contributionSchemaMismatch(UUID)
    case contributionPolicyMismatch(UUID)
    case coverageCountMismatch
}

struct WorkspaceCodemapGraphCheckpoint: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let generation: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32
    let slots: [WorkspaceCodemapGraphSlot]
    let coverage: WorkspaceCodemapGraphCatalogCoverage

    private init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        slots: [WorkspaceCodemapGraphSlot],
        coverage: WorkspaceCodemapGraphCatalogCoverage
    ) {
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.generation = generation
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.slots = slots
        self.coverage = coverage
    }

    static func validated(
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32,
        policyVersion: UInt32,
        slots: [WorkspaceCodemapGraphSlot],
        coverage: WorkspaceCodemapGraphCatalogCoverage
    ) -> Result<Self, WorkspaceCodemapGraphCheckpointValidationError> {
        guard schemaVersion > 0 else { return .failure(.invalidSchemaVersion) }
        guard policyVersion > 0 else { return .failure(.invalidPolicyVersion) }
        guard coverage.rootEpoch == rootEpoch else { return .failure(.coverageRootMismatch) }

        var fileIDs = Set<UUID>()
        var relativePaths = Set<String>()
        var pendingCount: UInt64 = 0
        var contributedCount: UInt64 = 0
        var emptyCount: UInt64 = 0
        var terminalArtifactCount: UInt64 = 0
        var terminalExcludedCount: UInt64 = 0
        for slot in slots {
            guard slot.rootEpoch == rootEpoch else { return .failure(.slotRootMismatch(slot.fileID)) }
            guard fileIDs.insert(slot.fileID).inserted else {
                return .failure(.duplicateFileID(slot.fileID))
            }
            guard relativePaths.insert(slot.standardizedRelativePath).inserted else {
                return .failure(.duplicateRelativePath(slot.standardizedRelativePath))
            }
            switch slot.state {
            case .pending:
                pendingCount += 1
            case let .contributed(contribution):
                guard contribution.schemaVersion == schemaVersion else {
                    return .failure(.contributionSchemaMismatch(slot.fileID))
                }
                guard contribution.policyVersion == policyVersion else {
                    return .failure(.contributionPolicyMismatch(slot.fileID))
                }
                contributedCount += 1
            case let .empty(contribution):
                guard contribution.schemaVersion == schemaVersion else {
                    return .failure(.contributionSchemaMismatch(slot.fileID))
                }
                guard contribution.policyVersion == policyVersion else {
                    return .failure(.contributionPolicyMismatch(slot.fileID))
                }
                emptyCount += 1
            case .terminalArtifact:
                terminalArtifactCount += 1
            case .terminalExcluded:
                terminalExcludedCount += 1
            }
        }

        guard let supportedCount = UInt64(exactly: slots.count),
              coverage.supportedCount == supportedCount,
              coverage.pendingCount == pendingCount,
              coverage.contributedCount == contributedCount,
              coverage.emptyCount == emptyCount,
              coverage.terminalArtifactCount == terminalArtifactCount,
              coverage.terminalExcludedCount == terminalExcludedCount
        else { return .failure(.coverageCountMismatch) }

        let orderedSlots = slots.sorted(by: workspaceCodemapGraphSlotPrecedes)
        return .success(Self(
            rootEpoch: rootEpoch,
            repositoryAuthority: repositoryAuthority,
            generation: generation,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion,
            slots: orderedSlots,
            coverage: coverage
        ))
    }
}

enum WorkspaceCodemapGraphRevocationReason: Hashable {
    case rootUnloaded
    case rootEpochChanged
    case repositoryAuthorityChanged
    case schemaMismatch
    case policyMismatch
    case reconciliationFailed
    case contributionGenerationExhausted
    case safetyCounterExhausted
    case fenceCapacityExceeded
    case accountingOverflow
}

enum WorkspaceCodemapGraphChangesDisposition: Hashable {
    case unchanged(generation: WorkspaceCodemapSelectionGraphContributionGeneration)
    case diff(
        changedSlots: [WorkspaceCodemapGraphSlot],
        removed: [WorkspaceCodemapGraphRemoval],
        coverage: WorkspaceCodemapGraphCatalogCoverage,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration
    )
    case resync(
        checkpoint: WorkspaceCodemapGraphCheckpoint,
        generation: WorkspaceCodemapSelectionGraphContributionGeneration
    )
    case revoked(WorkspaceCodemapGraphRevocationReason)
}

enum WorkspaceCodemapGraphCheckpointDisposition: Hashable {
    case checkpoint(WorkspaceCodemapGraphCheckpoint)
    case revoked(WorkspaceCodemapGraphRevocationReason)
}

private func workspaceCodemapGraphAdding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : result
}

private func workspaceCodemapGraphSlotPrecedes(
    _ lhs: WorkspaceCodemapGraphSlot,
    _ rhs: WorkspaceCodemapGraphSlot
) -> Bool {
    if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
        return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
            rhs.standardizedRelativePath.utf8
        )
    }
    return lhs.fileID.uuidString.utf8.lexicographicallyPrecedes(rhs.fileID.uuidString.utf8)
}
