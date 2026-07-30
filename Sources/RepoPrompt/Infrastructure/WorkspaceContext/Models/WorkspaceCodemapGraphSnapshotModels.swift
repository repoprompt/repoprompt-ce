import Foundation

enum WorkspaceCodemapGraphUnresolvedReason: Hashable {
    case notIndexedYet
    case missing
    case tooCommon
}

struct WorkspaceCodemapGraphSnapshotReceipt: Hashable {
    let snapshotID: UUID
    let graphRevision: UInt64
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let safetyCounter: UInt64
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init?(
        snapshotID: UUID,
        graphRevision: UInt64,
        rootEpoch: WorkspaceCodemapRootEpoch,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken,
        appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        safetyCounter: UInt64,
        schemaVersion: UInt32,
        policyVersion: UInt32
    ) {
        guard catalogWatermark.rootEpoch == rootEpoch,
              schemaVersion > 0,
              policyVersion > 0
        else { return nil }
        self.snapshotID = snapshotID
        self.graphRevision = graphRevision
        self.rootEpoch = rootEpoch
        self.repositoryAuthority = repositoryAuthority
        self.catalogWatermark = catalogWatermark
        self.appliedGeneration = appliedGeneration
        self.safetyCounter = safetyCounter
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }
}

enum WorkspaceCodemapGraphSnapshotFreshness: Hashable {
    case current
    case updatesPending(observedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration)
}

enum WorkspaceCodemapGraphFenceReason: Hashable {
    case deleted
    case renamed
    case securityExcluded
}

enum WorkspaceCodemapGraphFenceRejection: Hashable {
    case rootEpochMismatch
    case repositoryAuthorityMismatch
    case emptyFileIDs
}

enum WorkspaceCodemapGraphFenceDisposition: Hashable {
    case fenced(safetyCounter: UInt64)
    case rejected(WorkspaceCodemapGraphFenceRejection)
    case revoked(WorkspaceCodemapGraphRevocationReason)
}

enum WorkspaceCodemapGraphReceiptInvalidReason: Hashable {
    case rootEpochMismatch
    case repositoryAuthorityMismatch
    case schemaMismatch
    case policyMismatch
    case fencedFileOverlap
}

enum WorkspaceCodemapGraphReceiptDisposition: Hashable {
    case valid(WorkspaceCodemapGraphSnapshotFreshness)
    case invalid(WorkspaceCodemapGraphReceiptInvalidReason)
    case revoked(WorkspaceCodemapGraphRevocationReason)
}
