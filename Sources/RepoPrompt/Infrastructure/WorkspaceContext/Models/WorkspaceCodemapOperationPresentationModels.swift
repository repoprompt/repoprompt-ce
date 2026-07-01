import Foundation

enum WorkspaceCodemapOperationPresentationIntent: Equatable {
    case none
    case exact(fileIDs: [UUID], completeRootSet: Bool)
    case automatic(sourceFileIDs: [UUID])
}

struct WorkspaceCodemapOperationPresentationPlan {
    let intent: WorkspaceCodemapOperationPresentationIntent
    let preflightIssues: [WorkspaceCodemapOperationIssue]
}

struct WorkspaceCodemapOperationPresentationCandidate: Equatable, Hashable {
    let fileID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
}

enum WorkspaceCodemapOperationCandidateIssue: Equatable {
    case fileNotCataloged(UUID)
    case fileOutsideRootScope(UUID)
    case logicalPathUnavailable(UUID)
    case incompleteRootSet(missingFileIDs: [UUID])
}

struct WorkspaceCodemapOperationCompleteRootCatalogReceipt: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let supportedFileIDs: [UUID]
}

struct WorkspaceCodemapOperationCandidateCollection: Equatable {
    let candidates: [WorkspaceCodemapOperationPresentationCandidate]
    let issues: [WorkspaceCodemapOperationCandidateIssue]
    let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
}

struct WorkspaceCodemapOperationRenderedEntry: Equatable {
    let bundleID: WorkspaceCodemapFrozenPresentationBundleID
    let fileID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let artifactKey: CodeMapArtifactKey
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
    let text: String
    let tokenCount: Int
}

enum WorkspaceCodemapOperationIssue: Equatable {
    case coordinationUnavailable
    case cancelled
    case candidate(WorkspaceCodemapOperationCandidateIssue)
    case pending(fileID: UUID, ticket: WorkspaceCodemapArtifactDemandTicket)
    case unavailable(fileID: UUID, reason: WorkspaceCodemapArtifactDemandUnavailableReason)
    case automatic(WorkspaceCodemapAutomaticSelectionAggregateCoverage)
    case freezeUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationFreezeUnavailableReason
    )
    case renderUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationRenderUnavailableReason
    )
    case publicationStale(WorkspaceCodemapOperationPublicationStaleReason)
}

enum WorkspaceCodemapOperationPresentationCoverage: Equatable {
    case complete
    case partial([WorkspaceCodemapOperationIssue])
    case pending([WorkspaceCodemapOperationIssue])
    case unavailable([WorkspaceCodemapOperationIssue])
}

struct WorkspaceCodemapOperationPresentationBundleReceipt: Equatable {
    let bundleID: WorkspaceCodemapFrozenPresentationBundleID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let entries: [WorkspaceCodemapFrozenPresentationEntry]
}

struct WorkspaceCodemapOperationPresentationPublicationReceipt: Equatable {
    let requestID: UUID
    let rootScope: WorkspaceLookupRootScope
    let logicalRootDisplayNamesByRootID: [UUID: String]
    let completeRootSet: Bool
    let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
    let candidates: [WorkspaceCodemapOperationPresentationCandidate]
    let demandTickets: [WorkspaceCodemapArtifactDemandTicket]
    let bundles: [WorkspaceCodemapOperationPresentationBundleReceipt]
    let automaticReceipt: WorkspaceCodemapAutomaticSelectionPublicationReceipt?
}

enum WorkspaceCodemapOperationPublicationStaleReason: Equatable {
    case rootScope
    case rootEpoch(WorkspaceCodemapRootEpoch)
    case catalog(fileID: UUID)
    case demand(WorkspaceCodemapArtifactDemandTicket)
    case bundle(
        rootEpoch: WorkspaceCodemapRootEpoch,
        bundleID: WorkspaceCodemapFrozenPresentationBundleID
    )
    case automatic(WorkspaceCodemapAutomaticSelectionStaleReason)
}

enum WorkspaceCodemapOperationPublicationDisposition: Equatable {
    case current
    case stale(WorkspaceCodemapOperationPublicationStaleReason)
}

struct WorkspaceCodemapOperationPresentation: Equatable {
    let id: UUID
    let renderedEntriesByFileID: [UUID: WorkspaceCodemapOperationRenderedEntry]
    let orderedEntries: [WorkspaceCodemapOperationRenderedEntry]
    let coverage: WorkspaceCodemapOperationPresentationCoverage
    let issues: [WorkspaceCodemapOperationIssue]
    let publicationReceipt: WorkspaceCodemapOperationPresentationPublicationReceipt?

    init(
        id: UUID = UUID(),
        orderedEntries: [WorkspaceCodemapOperationRenderedEntry],
        coverage: WorkspaceCodemapOperationPresentationCoverage,
        issues: [WorkspaceCodemapOperationIssue],
        publicationReceipt: WorkspaceCodemapOperationPresentationPublicationReceipt?
    ) {
        self.id = id
        self.orderedEntries = orderedEntries
        renderedEntriesByFileID = Dictionary(uniqueKeysWithValues: orderedEntries.map { ($0.fileID, $0) })
        self.coverage = coverage
        self.issues = issues
        self.publicationReceipt = publicationReceipt
    }

    static var empty: WorkspaceCodemapOperationPresentation {
        WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
    }
}
