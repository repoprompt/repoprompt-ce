import Foundation
import RepoPromptCodeMapCore

package enum WorkspaceCodemapOperationPresentationIntent: Equatable {
    case none
    case exact(fileIDs: [UUID], completeRootSet: Bool)
    case automatic(sourceFileIDs: [UUID])
}

package struct WorkspaceCodemapOperationPresentationPlan {
    package let intent: WorkspaceCodemapOperationPresentationIntent
    package let preflightIssues: [WorkspaceCodemapOperationIssue]
}

struct WorkspaceCodemapOperationPresentationCandidate: Equatable, Hashable {
    package let fileID: UUID
    package let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    package let logicalPath: WorkspaceCodemapLogicalPresentationPath
}

package enum WorkspaceCodemapOperationCandidateIssue: Equatable {
    case fileNotCataloged(UUID)
    case fileOutsideRootScope(UUID)
    case logicalPathUnavailable(UUID)
    case incompleteRootSet(missingFileIDs: [UUID])
}

struct WorkspaceCodemapOperationCompleteRootCatalogReceipt: Equatable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let supportedFileIDs: [UUID]
}

struct WorkspaceCodemapOperationCandidateCollection: Equatable {
    let candidates: [WorkspaceCodemapOperationPresentationCandidate]
    package let issues: [WorkspaceCodemapOperationCandidateIssue]
    let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
}

package struct WorkspaceCodemapOperationRenderedEntry: Equatable {
    let bundleID: WorkspaceCodemapFrozenPresentationBundleID
    package let fileID: UUID
    package let rootEpoch: WorkspaceCodemapRootEpoch
    let artifactKey: CodeMapArtifactKey
    package let logicalPath: WorkspaceCodemapLogicalPresentationPath
    package let text: String
    package let tokenCount: Int
}

package enum WorkspaceCodemapOperationIssue: Equatable {
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

package enum WorkspaceCodemapOperationPresentationCoverage: Equatable {
    case complete
    case partial([WorkspaceCodemapOperationIssue])
    case pending([WorkspaceCodemapOperationIssue])
    case unavailable([WorkspaceCodemapOperationIssue])
}

struct WorkspaceCodemapOperationPresentationBundleReceipt: Equatable {
    let bundleID: WorkspaceCodemapFrozenPresentationBundleID
    package let rootEpoch: WorkspaceCodemapRootEpoch
    let entries: [WorkspaceCodemapFrozenPresentationEntry]
}

package struct WorkspaceCodemapOperationPresentationPublicationReceipt: Equatable {
    let requestID: UUID
    package let rootScope: WorkspaceLookupRootScope
    let logicalRootDisplayNamesByRootID: [UUID: String]
    let completeRootSet: Bool
    let completeRootCatalogs: [WorkspaceCodemapOperationCompleteRootCatalogReceipt]
    let candidates: [WorkspaceCodemapOperationPresentationCandidate]
    let demandTickets: [WorkspaceCodemapArtifactDemandTicket]
    let bundles: [WorkspaceCodemapOperationPresentationBundleReceipt]
    let automaticReceipt: WorkspaceCodemapAutomaticSelectionReceipt?
}

package enum WorkspaceCodemapOperationPublicationStaleReason: Equatable {
    case rootScope
    case rootEpoch(WorkspaceCodemapRootEpoch)
    case catalog(fileID: UUID)
    case demand(WorkspaceCodemapArtifactDemandTicket)
    case bundle(
        rootEpoch: WorkspaceCodemapRootEpoch,
        bundleID: WorkspaceCodemapFrozenPresentationBundleID
    )
    case automatic([WorkspaceCodemapAutomaticSelectionIssue])
}

enum WorkspaceCodemapOperationPublicationDisposition: Equatable {
    case current
    case stale(WorkspaceCodemapOperationPublicationStaleReason)
}

package struct WorkspaceCodemapOperationPresentation: Equatable {
    package let id: UUID
    package let renderedEntriesByFileID: [UUID: WorkspaceCodemapOperationRenderedEntry]
    package let orderedEntries: [WorkspaceCodemapOperationRenderedEntry]
    package let coverage: WorkspaceCodemapOperationPresentationCoverage
    package let issues: [WorkspaceCodemapOperationIssue]
    let publicationReceipt: WorkspaceCodemapOperationPresentationPublicationReceipt?

    package init(
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

    package static var empty: WorkspaceCodemapOperationPresentation {
        WorkspaceCodemapOperationPresentation(
            orderedEntries: [],
            coverage: .complete,
            issues: [],
            publicationReceipt: nil
        )
    }
}
