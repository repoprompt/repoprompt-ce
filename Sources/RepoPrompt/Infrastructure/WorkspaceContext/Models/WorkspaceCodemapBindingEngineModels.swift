import Foundation

struct WorkspaceCodemapBindingEnginePolicy: Equatable {
    static let `default` = WorkspaceCodemapBindingEnginePolicy()

    let maximumRootCount: Int
    let maximumActiveRequestCountPerRoot: Int
    let maximumActiveRequestCount: Int
    let maximumOwnerCountPerRoot: Int
    let maximumActiveRequestCountPerOwner: Int
    let maximumQueuedRequestCountPerRoot: Int
    let maximumQueuedRequestCountPerOwner: Int
    let maximumQueuedRequestCount: Int
    let maximumActiveTaskCountPerRoot: Int
    let maximumActiveTaskCountPerOwner: Int
    let maximumActiveTaskCount: Int
    let maximumManifestAdoptionRecordCount: Int
    let maximumRetainedManifestRecordCountPerRoot: Int
    let maximumRetainedManifestRecordCount: Int
    let maximumManifestAdoptionLeaseCountPerRoot: Int
    let maximumManifestAdoptionLeaseCount: Int
    let maximumManifestAdoptionLeaseByteCountPerRoot: UInt64
    let maximumManifestAdoptionLeaseByteCount: UInt64
    let maximumCapabilityRetryCount: Int
    let maximumValidatedWorktreeByteCount: Int64
    let maximumRetainedSourceByteCountPerRoot: UInt64
    let maximumRetainedSourceByteCountPerOwner: UInt64
    let maximumRetainedSourceByteCount: UInt64
    let maximumConcurrentMaterializationCountPerRoot: Int
    let maximumConcurrentMaterializationCountPerOwner: Int
    let maximumConcurrentMaterializationCount: Int
    let maximumConsecutiveDemandAdmissions: Int
    let maximumAutomaticSelectionMatchedCandidateByteCount: UInt64
    let maximumProjectionDemandCountPerRoot: Int
    let maximumProjectionDemandCount: Int
    let maximumProjectionDemandFileIDCount: Int
    let maximumProjectionDemandMetadataByteCountPerRoot: UInt64
    let maximumProjectionDemandMetadataByteCount: UInt64
    let projectionDemandRetryMilliseconds: UInt64
    let maximumActiveProjectionBatchCountPerRoot: Int
    let maximumActiveProjectionBatchCount: Int
    let maximumProjectionCatalogPageEntryCount: Int
    let maximumProjectionCatalogPagePathByteCount: UInt64
    let maximumProjectionBatchCandidateCount: Int
    let maximumRetainedProjectionByteCountPerSegment: UInt64
    let maximumRetainedProjectionByteCountPerRoot: UInt64
    let maximumRetainedProjectionByteCount: UInt64
    let maximumStagedProjectionGraphByteCountPerRoot: UInt64
    let maximumStagedProjectionGraphByteCount: UInt64
    let maximumQueuedProjectionManifestMutationByteCountPerRoot: UInt64
    let maximumQueuedProjectionManifestMutationByteCount: UInt64
    let projectionRetryInitialMilliseconds: UInt64
    let projectionRetryMaximumMilliseconds: UInt64
    let projectionRetryJitterPercent: UInt64

    init(
        maximumRootCount: Int = 64,
        maximumActiveRequestCountPerRoot: Int = 1024,
        maximumActiveRequestCount: Int = 4096,
        maximumOwnerCountPerRoot: Int = 256,
        maximumActiveRequestCountPerOwner: Int = 64,
        maximumQueuedRequestCountPerRoot: Int = 1024,
        maximumQueuedRequestCountPerOwner: Int = 64,
        maximumQueuedRequestCount: Int = 4096,
        maximumActiveTaskCountPerRoot: Int = 1024,
        maximumActiveTaskCountPerOwner: Int = 64,
        maximumActiveTaskCount: Int = 4096,
        maximumManifestAdoptionRecordCount: Int = 8192,
        maximumRetainedManifestRecordCountPerRoot: Int = 8192,
        maximumRetainedManifestRecordCount: Int = 32768,
        maximumManifestAdoptionLeaseCountPerRoot: Int = 4096,
        maximumManifestAdoptionLeaseCount: Int = 16384,
        maximumManifestAdoptionLeaseByteCountPerRoot: UInt64 = 256 * 1024 * 1024,
        maximumManifestAdoptionLeaseByteCount: UInt64 = 1024 * 1024 * 1024,
        maximumCapabilityRetryCount: Int = 1,
        maximumValidatedWorktreeByteCount: Int64 = 8 * 1024 * 1024,
        maximumRetainedSourceByteCountPerRoot: UInt64 = 128 * 1024 * 1024,
        maximumRetainedSourceByteCountPerOwner: UInt64 = 32 * 1024 * 1024,
        maximumRetainedSourceByteCount: UInt64 = 512 * 1024 * 1024,
        maximumConcurrentMaterializationCountPerRoot: Int = 16,
        maximumConcurrentMaterializationCountPerOwner: Int = 4,
        maximumConcurrentMaterializationCount: Int = 64,
        maximumConsecutiveDemandAdmissions: Int = 8,
        maximumAutomaticSelectionMatchedCandidateByteCount: UInt64 = 8 * 1024 * 1024,
        maximumProjectionDemandCountPerRoot: Int = 64,
        maximumProjectionDemandCount: Int = 256,
        maximumProjectionDemandFileIDCount: Int = 1024,
        maximumProjectionDemandMetadataByteCountPerRoot: UInt64 = 512 * 1024,
        maximumProjectionDemandMetadataByteCount: UInt64 = 4 * 1024 * 1024,
        projectionDemandRetryMilliseconds: UInt64 = 100,
        maximumActiveProjectionBatchCountPerRoot: Int = 1,
        maximumActiveProjectionBatchCount: Int = 2,
        maximumProjectionCatalogPageEntryCount: Int = 64,
        maximumProjectionCatalogPagePathByteCount: UInt64 = 256 * 1024,
        maximumProjectionBatchCandidateCount: Int = 64,
        maximumRetainedProjectionByteCountPerSegment: UInt64 = 8 * 1024 * 1024,
        maximumRetainedProjectionByteCountPerRoot: UInt64 = 32 * 1024 * 1024,
        maximumRetainedProjectionByteCount: UInt64 = 128 * 1024 * 1024,
        maximumStagedProjectionGraphByteCountPerRoot: UInt64 = 192 * 1024 * 1024,
        maximumStagedProjectionGraphByteCount: UInt64 = 512 * 1024 * 1024,
        maximumQueuedProjectionManifestMutationByteCountPerRoot: UInt64 = 8 * 1024 * 1024,
        maximumQueuedProjectionManifestMutationByteCount: UInt64 = 32 * 1024 * 1024,
        projectionRetryInitialMilliseconds: UInt64 = 250,
        projectionRetryMaximumMilliseconds: UInt64 = 30000,
        projectionRetryJitterPercent: UInt64 = 20
    ) {
        precondition(maximumRootCount > 0)
        precondition(maximumActiveRequestCountPerRoot > 0)
        precondition(maximumActiveRequestCount > 0)
        precondition(maximumOwnerCountPerRoot > 0)
        precondition(maximumActiveRequestCountPerOwner > 0)
        precondition(maximumQueuedRequestCountPerRoot > 0)
        precondition(maximumQueuedRequestCountPerOwner > 0)
        precondition(maximumQueuedRequestCount > 0)
        precondition(maximumActiveTaskCountPerRoot > 0)
        precondition(maximumActiveTaskCountPerOwner > 0)
        precondition(maximumActiveTaskCount > 0)
        precondition(maximumManifestAdoptionRecordCount > 0)
        precondition(maximumRetainedManifestRecordCountPerRoot > 0)
        precondition(maximumRetainedManifestRecordCount > 0)
        precondition(maximumManifestAdoptionLeaseCountPerRoot > 0)
        precondition(maximumManifestAdoptionLeaseCount > 0)
        precondition(maximumManifestAdoptionLeaseByteCountPerRoot > 0)
        precondition(maximumManifestAdoptionLeaseByteCount > 0)
        precondition(maximumCapabilityRetryCount >= 0 && maximumCapabilityRetryCount <= 1)
        precondition(maximumValidatedWorktreeByteCount > 0)
        precondition(maximumRetainedSourceByteCountPerRoot > 0)
        precondition(maximumRetainedSourceByteCountPerOwner > 0)
        precondition(maximumRetainedSourceByteCount > 0)
        precondition(maximumConcurrentMaterializationCountPerRoot > 0)
        precondition(maximumConcurrentMaterializationCountPerOwner > 0)
        precondition(maximumConcurrentMaterializationCount > 0)
        precondition(maximumConsecutiveDemandAdmissions > 0)
        precondition(maximumAutomaticSelectionMatchedCandidateByteCount > 0)
        precondition(maximumProjectionDemandCountPerRoot > 0)
        precondition(maximumProjectionDemandCount >= maximumProjectionDemandCountPerRoot)
        precondition(maximumProjectionDemandFileIDCount > 0)
        precondition(maximumProjectionDemandMetadataByteCountPerRoot > 0)
        precondition(
            maximumProjectionDemandMetadataByteCount >= maximumProjectionDemandMetadataByteCountPerRoot
        )
        precondition(maximumActiveProjectionBatchCountPerRoot > 0)
        precondition(maximumActiveProjectionBatchCount > 0)
        precondition(maximumActiveProjectionBatchCount >= maximumActiveProjectionBatchCountPerRoot)
        precondition(maximumProjectionCatalogPageEntryCount > 0)
        precondition(maximumProjectionCatalogPagePathByteCount > 0)
        precondition(maximumProjectionBatchCandidateCount > 0)
        precondition(maximumProjectionBatchCandidateCount <= maximumProjectionCatalogPageEntryCount)
        precondition(maximumRetainedProjectionByteCountPerSegment > 0)
        precondition(maximumRetainedProjectionByteCountPerRoot > 0)
        precondition(maximumRetainedProjectionByteCount > 0)
        precondition(maximumRetainedProjectionByteCount >= maximumRetainedProjectionByteCountPerRoot)
        precondition(maximumStagedProjectionGraphByteCountPerRoot > 0)
        precondition(maximumStagedProjectionGraphByteCount > 0)
        precondition(maximumStagedProjectionGraphByteCount >= maximumStagedProjectionGraphByteCountPerRoot)
        precondition(maximumQueuedProjectionManifestMutationByteCountPerRoot > 0)
        precondition(maximumQueuedProjectionManifestMutationByteCount > 0)
        precondition(
            maximumQueuedProjectionManifestMutationByteCount >=
                maximumQueuedProjectionManifestMutationByteCountPerRoot
        )
        precondition(projectionRetryInitialMilliseconds > 0)
        precondition(projectionRetryMaximumMilliseconds >= projectionRetryInitialMilliseconds)
        precondition(projectionRetryJitterPercent <= 100)
        self.maximumRootCount = maximumRootCount
        self.maximumActiveRequestCountPerRoot = maximumActiveRequestCountPerRoot
        self.maximumActiveRequestCount = maximumActiveRequestCount
        self.maximumOwnerCountPerRoot = maximumOwnerCountPerRoot
        self.maximumActiveRequestCountPerOwner = maximumActiveRequestCountPerOwner
        self.maximumQueuedRequestCountPerRoot = maximumQueuedRequestCountPerRoot
        self.maximumQueuedRequestCountPerOwner = maximumQueuedRequestCountPerOwner
        self.maximumQueuedRequestCount = maximumQueuedRequestCount
        self.maximumActiveTaskCountPerRoot = maximumActiveTaskCountPerRoot
        self.maximumActiveTaskCountPerOwner = maximumActiveTaskCountPerOwner
        self.maximumActiveTaskCount = maximumActiveTaskCount
        self.maximumManifestAdoptionRecordCount = maximumManifestAdoptionRecordCount
        self.maximumRetainedManifestRecordCountPerRoot = maximumRetainedManifestRecordCountPerRoot
        self.maximumRetainedManifestRecordCount = maximumRetainedManifestRecordCount
        self.maximumManifestAdoptionLeaseCountPerRoot = maximumManifestAdoptionLeaseCountPerRoot
        self.maximumManifestAdoptionLeaseCount = maximumManifestAdoptionLeaseCount
        self.maximumManifestAdoptionLeaseByteCountPerRoot = maximumManifestAdoptionLeaseByteCountPerRoot
        self.maximumManifestAdoptionLeaseByteCount = maximumManifestAdoptionLeaseByteCount
        self.maximumCapabilityRetryCount = maximumCapabilityRetryCount
        self.maximumValidatedWorktreeByteCount = maximumValidatedWorktreeByteCount
        self.maximumRetainedSourceByteCountPerRoot = maximumRetainedSourceByteCountPerRoot
        self.maximumRetainedSourceByteCountPerOwner = maximumRetainedSourceByteCountPerOwner
        self.maximumRetainedSourceByteCount = maximumRetainedSourceByteCount
        self.maximumConcurrentMaterializationCountPerRoot = maximumConcurrentMaterializationCountPerRoot
        self.maximumConcurrentMaterializationCountPerOwner = maximumConcurrentMaterializationCountPerOwner
        self.maximumConcurrentMaterializationCount = maximumConcurrentMaterializationCount
        self.maximumConsecutiveDemandAdmissions = maximumConsecutiveDemandAdmissions
        self.maximumAutomaticSelectionMatchedCandidateByteCount =
            maximumAutomaticSelectionMatchedCandidateByteCount
        self.maximumProjectionDemandCountPerRoot = maximumProjectionDemandCountPerRoot
        self.maximumProjectionDemandCount = maximumProjectionDemandCount
        self.maximumProjectionDemandFileIDCount = maximumProjectionDemandFileIDCount
        self.maximumProjectionDemandMetadataByteCountPerRoot = maximumProjectionDemandMetadataByteCountPerRoot
        self.maximumProjectionDemandMetadataByteCount = maximumProjectionDemandMetadataByteCount
        self.projectionDemandRetryMilliseconds = min(1000, max(25, projectionDemandRetryMilliseconds))
        self.maximumActiveProjectionBatchCountPerRoot = maximumActiveProjectionBatchCountPerRoot
        self.maximumActiveProjectionBatchCount = maximumActiveProjectionBatchCount
        self.maximumProjectionCatalogPageEntryCount = maximumProjectionCatalogPageEntryCount
        self.maximumProjectionCatalogPagePathByteCount = maximumProjectionCatalogPagePathByteCount
        self.maximumProjectionBatchCandidateCount = maximumProjectionBatchCandidateCount
        self.maximumRetainedProjectionByteCountPerSegment = maximumRetainedProjectionByteCountPerSegment
        self.maximumRetainedProjectionByteCountPerRoot = maximumRetainedProjectionByteCountPerRoot
        self.maximumRetainedProjectionByteCount = maximumRetainedProjectionByteCount
        self.maximumStagedProjectionGraphByteCountPerRoot = maximumStagedProjectionGraphByteCountPerRoot
        self.maximumStagedProjectionGraphByteCount = maximumStagedProjectionGraphByteCount
        self.maximumQueuedProjectionManifestMutationByteCountPerRoot =
            maximumQueuedProjectionManifestMutationByteCountPerRoot
        self.maximumQueuedProjectionManifestMutationByteCount =
            maximumQueuedProjectionManifestMutationByteCount
        self.projectionRetryInitialMilliseconds = projectionRetryInitialMilliseconds
        self.projectionRetryMaximumMilliseconds = projectionRetryMaximumMilliseconds
        self.projectionRetryJitterPercent = projectionRetryJitterPercent
    }
}

struct WorkspaceCodemapBindingRootRegistration: Equatable {
    let capabilityRequest: WorkspaceCodemapGitCapabilityRequest
    let catalogGeneration: UInt64
    let ingressGeneration: UInt64

    init(
        rootID: UUID,
        rootLifetimeID: UUID,
        loadedRootURL: URL,
        catalogGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        capabilityRequest = WorkspaceCodemapGitCapabilityRequest(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            loadedRootURL: loadedRootURL
        )
        self.catalogGeneration = catalogGeneration
        self.ingressGeneration = ingressGeneration
    }
}

struct WorkspaceCodemapManifestBindingCandidate {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
}

struct WorkspaceCodemapBindingCatalogClient: @unchecked Sendable {
    let resolveManifestBinding: @Sendable (
        WorkspaceCodemapRootEpoch,
        String
    ) async -> WorkspaceCodemapManifestBindingCandidate?
    let readProjectionCatalogPage: @Sendable (
        WorkspaceCodemapProjectionCatalogPageRequest
    ) async -> WorkspaceCodemapProjectionCatalogPageDisposition
    let revalidateProjectionCatalogToken: @Sendable (
        WorkspaceCodemapRootEpoch,
        WorkspaceCodemapProjectionCatalogToken
    ) async -> WorkspaceCodemapProjectionCatalogTokenDisposition
    let publishProjection: @Sendable (
        WorkspaceCodemapProjectionSnapshot
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition
    let publishMarkerReadiness: @Sendable (
        WorkspaceCodemapMarkerReadinessUpdate
    ) async -> Bool

    init(
        _ resolveManifestBinding: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            String
        ) async -> WorkspaceCodemapManifestBindingCandidate?
    ) {
        self.init(
            resolveManifestBinding,
            readProjectionCatalogPage: { _ in .unavailable(.catalogUnavailable) },
            revalidateProjectionCatalogToken: { _, _ in .unavailable(.catalogUnavailable) },
            publishProjection: { _ in .superseded },
            publishMarkerReadiness: { _ in false }
        )
    }

    init(
        _ resolveManifestBinding: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            String
        ) async -> WorkspaceCodemapManifestBindingCandidate?,
        readProjectionCatalogPage: @escaping @Sendable (
            WorkspaceCodemapProjectionCatalogPageRequest
        ) async -> WorkspaceCodemapProjectionCatalogPageDisposition,
        revalidateProjectionCatalogToken: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            WorkspaceCodemapProjectionCatalogToken
        ) async -> WorkspaceCodemapProjectionCatalogTokenDisposition,
        publishProjection: @escaping @Sendable (
            WorkspaceCodemapProjectionSnapshot
        ) async -> WorkspaceCodemapProjectionSnapshotDisposition = { _ in .superseded },
        publishMarkerReadiness: @escaping @Sendable (
            WorkspaceCodemapMarkerReadinessUpdate
        ) async -> Bool = { _ in false }
    ) {
        self.resolveManifestBinding = resolveManifestBinding
        self.readProjectionCatalogPage = readProjectionCatalogPage
        self.revalidateProjectionCatalogToken = revalidateProjectionCatalogToken
        self.publishProjection = publishProjection
        self.publishMarkerReadiness = publishMarkerReadiness
    }

    static let unavailable = WorkspaceCodemapBindingCatalogClient { _, _ in nil }
}

struct WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let language: LanguageType
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64

    var rootEpoch: WorkspaceCodemapRootEpoch {
        WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        )
    }
}

struct WorkspaceCodemapBindingAutomaticSelectionPlanRequest: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let sourceTickets: [WorkspaceCodemapArtifactDemandTicket]
    let candidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
    let maximumMatchedCandidateCount: Int
}

struct WorkspaceCodemapBindingAutomaticSelectionPlan: Hashable {
    let necessaryCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate]
    let indexedCandidateCount: Int
    let coverageProof: WorkspaceCodemapProjectionCoverageProof
}

enum WorkspaceCodemapBindingAutomaticSelectionPlanDisposition: Hashable {
    case ready(WorkspaceCodemapBindingAutomaticSelectionPlan)
    case provisional(
        necessaryCandidates: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate],
        indexedCandidateCount: Int,
        progress: WorkspaceCodemapProjectionProgress,
        remainingCount: UInt64?,
        retry: WorkspaceCodemapProjectionRetry?
    )
    case incomplete(
        progress: WorkspaceCodemapProjectionProgress,
        remainingCount: UInt64?,
        retry: WorkspaceCodemapProjectionRetry?
    )
    case busy(
        progress: WorkspaceCodemapProjectionProgress,
        retryAfterMilliseconds: UInt64?
    )
    case stale
    case unavailable(WorkspaceCodemapSelectionGraphUnavailableReason)
    case budget(
        dimension: WorkspaceCodemapProjectionBudgetDimension,
        attempted: UInt64,
        limit: UInt64
    )
}

struct WorkspaceCodemapValidatedSourceReaderClient: @unchecked Sendable {
    let read: @Sendable (
        WorkspaceCodemapArtifactBindingIdentity,
        GitBlobLStatFingerprint,
        Int64,
        UUID
    ) async throws -> ValidatedRawFileContentSnapshot
}

struct WorkspaceCodemapBindingDemand: Equatable {
    let owner: WorkspaceCodemapLiveDemandOwner
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
    let priority: CodeMapArtifactBuildPriority
    let language: LanguageType
}

enum WorkspaceCodemapBindingRegistrationResult {
    case registered(adoptedReadyCount: Int)
    case exactDuplicate
    case unavailable(WorkspaceCodemapGitCapabilityState)
    case busy
    case failed
}

enum WorkspaceCodemapBindingDemandRejection: Equatable {
    case rootNotRegistered
    case capabilityUnavailable
    case rootEpochMismatch
    case rootPathMismatch
    case invalidIdentity
    case catalogGenerationMismatch
    case requestGenerationInvalid
    case stalePathGeneration
    case staleIngressGeneration
    case languageMismatch
    case classificationMismatch
    case sourceAuthorityUnavailable
    case overlayRejected
    case staleCompletion
}

enum WorkspaceCodemapBindingDemandUnavailableReason: Equatable {
    case unsupportedFileType
    case missing
    case securityExcluded
    case nonRegular
    case oversized
    case transient
    case terminalArtifact(WorkspaceCodemapLiveArtifactOutcome)
}

enum WorkspaceCodemapBindingDemandResult {
    case ready(WorkspaceCodemapLiveReadySnapshot)
    case alreadyReady(WorkspaceCodemapLiveReadySnapshot)
    case unavailable(WorkspaceCodemapBindingDemandUnavailableReason)
    case busy(retryAfterMilliseconds: Int?)
    case rejected(WorkspaceCodemapBindingDemandRejection)
    case cancelled
}

enum WorkspaceCodemapPublishedArtifactLookupSource: String, Equatable {
    case projectionCAS
    case locatorCAS
}

enum WorkspaceCodemapPublishedArtifactLookupMissReason: String, Error, Equatable {
    case rootUnavailable
    case currentnessMismatch
    case unsupportedFileType
    case projectionMissing
    case artifactMissing
}

struct WorkspaceCodemapPublishedArtifactLookupRequest {
    let ownerID: UUID
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
    let language: LanguageType
}

struct WorkspaceCodemapPublishedArtifactLookupHit {
    let handle: CodeMapArtifactHandle
    let source: WorkspaceCodemapPublishedArtifactLookupSource
}

enum WorkspaceCodemapPublishedArtifactLookupResult {
    case hit(WorkspaceCodemapPublishedArtifactLookupHit)
    case miss(WorkspaceCodemapPublishedArtifactLookupMissReason)
    case cancelled
}

enum WorkspaceCodemapBindingManifestState: Equatable {
    case unavailable
    case miss
    case clean(generation: UInt64)
    case dirtyRetryRequired
}

struct WorkspaceCodemapBindingInvalidationResult: Equatable {
    let revokedOverlayCount: Int
    let cancelledRequestCount: Int
    let manifestWriteFailed: Bool
}

enum WorkspaceCodemapBindingEngineHookKind: String {
    case capabilityEligible
    case capabilityTerminalUnavailable
    case capabilityTransientRetry
    case classificationClean
    case classificationWorktree
    case classificationUnavailable
    case locatorFastPath
    case casFastPath
    case build
    case manifestLoadHit
    case manifestLoadMiss
    case manifestAdopted
    case manifestRevisionQueued
    case manifestWrite
    case manifestFailure
    case overlayReady
    case overlayUnavailable
    case overlayExactDuplicate
    case materialization
    case staleDrop
    case cancellation
    case busy
    case failure
    case invalidation
    case publishedArtifactLookupHit
    case publishedArtifactLookupMiss
    #if DEBUG
        case publishedArtifactPostLookupCurrentnessRejection
    #endif
    case rootUnload
    case projectionPreloadScheduled
    case projectionPreloadStarted
    case projectionFirstSegment
    case projectionSegmentPublished
    case projectionCoverageComplete
    case projectionCoverageCancelled
    case projectionCoverageSuperseded
    case projectionEnvelopeHit
    case projectionEnvelopeStale
    case projectionEnvelopeInvalid
    case projectionTerminalRecordHit
    case projectionLocatorMiss
    case projectionLocatorCorrupt
    case projectionCASMiss
    case projectionBuildJoined
    case projectionBuildStarted
    case projectionBuildCompleted
    case projectionCatalogPage
    case projectionCatalogCandidates
    case projectionCatalogPathBytes
    case projectionBatchQueued
    case projectionBatchStarted
    case projectionBatchCompleted
    case projectionBatchCancelled
    case projectionRetry
    case projectionDemandOvertake
    case projectionExplicitOvertake
    case projectionBudget
}

/// Hook payloads deliberately contain no physical or logical path.
struct WorkspaceCodemapBindingEngineHookEvent {
    let kind: WorkspaceCodemapBindingEngineHookKind
    let rootEpoch: WorkspaceCodemapRootEpoch?
    let artifactStorageDigest: String?
    let numericValue: UInt64
    let projectionPhase: WorkspaceCodemapProjectionPreloadPhase?
    let retryAfterMilliseconds: UInt64?
    let publishedArtifactLookupSource: WorkspaceCodemapPublishedArtifactLookupSource?
    let publishedArtifactLookupMissReason: WorkspaceCodemapPublishedArtifactLookupMissReason?
    let invalidationReason: WorkspaceCodemapLiveOverlayInvalidationReason?

    init(
        kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch?,
        artifactStorageDigest: String?,
        numericValue: UInt64,
        projectionPhase: WorkspaceCodemapProjectionPreloadPhase? = nil,
        retryAfterMilliseconds: UInt64? = nil,
        publishedArtifactLookupSource: WorkspaceCodemapPublishedArtifactLookupSource? = nil,
        publishedArtifactLookupMissReason: WorkspaceCodemapPublishedArtifactLookupMissReason? = nil,
        invalidationReason: WorkspaceCodemapLiveOverlayInvalidationReason? = nil
    ) {
        self.kind = kind
        self.rootEpoch = rootEpoch
        self.artifactStorageDigest = artifactStorageDigest
        self.numericValue = numericValue
        self.projectionPhase = projectionPhase
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.publishedArtifactLookupSource = publishedArtifactLookupSource
        self.publishedArtifactLookupMissReason = publishedArtifactLookupMissReason
        self.invalidationReason = invalidationReason
    }
}

struct WorkspaceCodemapBindingEngineHooks {
    let event: @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void
    let afterManifestStoreWriteBeforeCompletion: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    #if DEBUG
        /// Deterministic race seam, structurally absent from non-DEBUG products.
        let afterPublishedArtifactLookupBeforeCurrentnessValidation: @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void
    #endif

    init(
        event: @escaping @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void = { _ in },
        afterManifestStoreWriteBeforeCompletion: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in }
    ) {
        self.event = event
        self.afterManifestStoreWriteBeforeCompletion = afterManifestStoreWriteBeforeCompletion
        #if DEBUG
            afterPublishedArtifactLookupBeforeCurrentnessValidation = { _ in }
        #endif
    }

    #if DEBUG
        init(
            event: @escaping @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void = { _ in },
            afterManifestStoreWriteBeforeCompletion: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in },
            afterPublishedArtifactLookupBeforeCurrentnessValidation: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void
        ) {
            self.event = event
            self.afterManifestStoreWriteBeforeCompletion = afterManifestStoreWriteBeforeCompletion
            self.afterPublishedArtifactLookupBeforeCurrentnessValidation =
                afterPublishedArtifactLookupBeforeCurrentnessValidation
        }
    #endif

    static let none = WorkspaceCodemapBindingEngineHooks()
}

struct WorkspaceCodemapBindingEngineCounters: Equatable {
    var capabilityResolutions: UInt64 = 0
    var capabilityRetries: UInt64 = 0
    var classifications: UInt64 = 0
    var cleanClassifications: UInt64 = 0
    var worktreeClassifications: UInt64 = 0
    var locatorFastPaths: UInt64 = 0
    var casFastPaths: UInt64 = 0
    var builds: UInt64 = 0
    var manifestLoads: UInt64 = 0
    var manifestAdoptions: UInt64 = 0
    var demandManifestAdoptionBypasses: UInt64 = 0
    var demandManifestAdoptionWaits: UInt64 = 0
    var manifestWrites: UInt64 = 0
    var manifestFailures: UInt64 = 0
    var materializations: UInt64 = 0
    var materializedBytes: UInt64 = 0
    var validatedWorktreeReads: UInt64 = 0
    var validatedWorktreeBytes: UInt64 = 0
    var overlayReadyPublications: UInt64 = 0
    var overlayUnavailablePublications: UInt64 = 0
    var overlayExactDuplicateCompletions: UInt64 = 0
    var staleCompletionDrops: UInt64 = 0
    var cancellations: UInt64 = 0
    var busyRejections: UInt64 = 0
    var failures: UInt64 = 0
    var publishedArtifactProjectionCASHits: UInt64 = 0
    var publishedArtifactLocatorCASHits: UInt64 = 0
    var publishedArtifactLookupMisses: UInt64 = 0
    #if DEBUG
        var publishedArtifactPostLookupCurrentnessRejections: UInt64 = 0
    #endif
    var projectionPreloadsScheduled: UInt64 = 0
    var projectionPreloadsStarted: UInt64 = 0
    var projectionFirstSegments: UInt64 = 0
    var projectionSegmentsPublished: UInt64 = 0
    var projectionSegmentBytes: UInt64 = 0
    var projectionCoveragesCompleted: UInt64 = 0
    var projectionCoveragesCancelled: UInt64 = 0
    var projectionCoveragesSuperseded: UInt64 = 0
    var projectionEnvelopeHits: UInt64 = 0
    var projectionEnvelopeStale: UInt64 = 0
    var projectionEnvelopeInvalid: UInt64 = 0
    var projectionTerminalRecordHits: UInt64 = 0
    var projectionLocatorMisses: UInt64 = 0
    var projectionLocatorCorruptions: UInt64 = 0
    var projectionCASMisses: UInt64 = 0
    var projectionBuildsJoined: UInt64 = 0
    var projectionBuildsStarted: UInt64 = 0
    var projectionBuildsCompleted: UInt64 = 0
    var projectionCatalogPages: UInt64 = 0
    var projectionCatalogCandidates: UInt64 = 0
    var projectionCatalogPathBytes: UInt64 = 0
    var projectionBatchesQueued: UInt64 = 0
    var projectionBatchesStarted: UInt64 = 0
    var projectionBatchesCompleted: UInt64 = 0
    var projectionRetries: UInt64 = 0
    var projectionDemandOvertakes: UInt64 = 0
    var projectionExplicitOvertakes: UInt64 = 0
    var projectionBudgetRejections: UInt64 = 0
    var projectionCancelledBatches: UInt64 = 0
    var projectionDemandsAcquired: UInt64 = 0
    var projectionDemandsJoined: UInt64 = 0
    var projectionDemandsReleased: UInt64 = 0
    var projectionDemandsExpired: UInt64 = 0
    var projectionDemandsRevoked: UInt64 = 0
    var projectionDemandBusyRejections: UInt64 = 0

    init(initialValue: UInt64 = 0) {
        capabilityResolutions = initialValue
        capabilityRetries = initialValue
        classifications = initialValue
        cleanClassifications = initialValue
        worktreeClassifications = initialValue
        locatorFastPaths = initialValue
        casFastPaths = initialValue
        builds = initialValue
        manifestLoads = initialValue
        manifestAdoptions = initialValue
        demandManifestAdoptionBypasses = initialValue
        demandManifestAdoptionWaits = initialValue
        manifestWrites = initialValue
        manifestFailures = initialValue
        materializations = initialValue
        materializedBytes = initialValue
        validatedWorktreeReads = initialValue
        validatedWorktreeBytes = initialValue
        overlayReadyPublications = initialValue
        overlayUnavailablePublications = initialValue
        overlayExactDuplicateCompletions = initialValue
        staleCompletionDrops = initialValue
        cancellations = initialValue
        busyRejections = initialValue
        failures = initialValue
        publishedArtifactProjectionCASHits = initialValue
        publishedArtifactLocatorCASHits = initialValue
        publishedArtifactLookupMisses = initialValue
        #if DEBUG
            publishedArtifactPostLookupCurrentnessRejections = initialValue
        #endif
        projectionPreloadsScheduled = initialValue
        projectionPreloadsStarted = initialValue
        projectionFirstSegments = initialValue
        projectionSegmentsPublished = initialValue
        projectionSegmentBytes = initialValue
        projectionCoveragesCompleted = initialValue
        projectionCoveragesCancelled = initialValue
        projectionCoveragesSuperseded = initialValue
        projectionEnvelopeHits = initialValue
        projectionEnvelopeStale = initialValue
        projectionEnvelopeInvalid = initialValue
        projectionTerminalRecordHits = initialValue
        projectionLocatorMisses = initialValue
        projectionLocatorCorruptions = initialValue
        projectionCASMisses = initialValue
        projectionBuildsJoined = initialValue
        projectionBuildsStarted = initialValue
        projectionBuildsCompleted = initialValue
        projectionCatalogPages = initialValue
        projectionCatalogCandidates = initialValue
        projectionCatalogPathBytes = initialValue
        projectionBatchesQueued = initialValue
        projectionBatchesStarted = initialValue
        projectionBatchesCompleted = initialValue
        projectionRetries = initialValue
        projectionDemandOvertakes = initialValue
        projectionExplicitOvertakes = initialValue
        projectionBudgetRejections = initialValue
        projectionCancelledBatches = initialValue
        projectionDemandsAcquired = initialValue
        projectionDemandsJoined = initialValue
        projectionDemandsReleased = initialValue
        projectionDemandsExpired = initialValue
        projectionDemandsRevoked = initialValue
        projectionDemandBusyRejections = initialValue
    }
}

struct WorkspaceCodemapBindingEngineProjectionRootAccounting: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let phase: WorkspaceCodemapProjectionPreloadPhase
    let progress: WorkspaceCodemapProjectionProgress
    let queuedBatchCount: Int
    let activeBatchCount: Int
    let drainingBatchCount: Int
    let resources: WorkspaceCodemapProjectionResourceAccounting
    let retry: WorkspaceCodemapProjectionRetry?
    let budget: WorkspaceCodemapProjectionBudget?
    let retainedDemandCount: Int
    let retainedDemandMetadataByteCount: UInt64
}

struct WorkspaceCodemapBindingEngineAccounting: Equatable {
    let rootCount: Int
    let eligibleRootCount: Int
    let unavailableRootCount: Int
    let activeRequestCount: Int
    let queuedRequestCount: Int
    let ownerCount: Int
    let reservedSourceByteCount: UInt64
    let manifestAdoptionLeaseCount: Int
    let manifestAdoptionLeaseByteCount: UInt64
    let rootAdmissionHistoryCount: Int
    let ownerAdmissionHistoryCount: Int
    let dirtyManifestCount: Int
    let counters: WorkspaceCodemapBindingEngineCounters
    let projectionJobCount: Int
    let suspendedProjectionJobCount: Int
    let queuedProjectionBatchCount: Int
    let activeProjectionBatchCount: Int
    let drainingProjectionTaskCount: Int
    let retainedProjectionDemandCount: Int
    let retainedProjectionDemandMetadataByteCount: UInt64
    let terminalProjectionDemandStatusCount: Int
    let projectionResources: WorkspaceCodemapProjectionResourceAccounting
    let projectionRoots: [WorkspaceCodemapBindingEngineProjectionRootAccounting]

    init(
        rootCount: Int,
        eligibleRootCount: Int,
        unavailableRootCount: Int,
        activeRequestCount: Int,
        queuedRequestCount: Int,
        ownerCount: Int,
        reservedSourceByteCount: UInt64,
        manifestAdoptionLeaseCount: Int,
        manifestAdoptionLeaseByteCount: UInt64,
        rootAdmissionHistoryCount: Int,
        ownerAdmissionHistoryCount: Int,
        dirtyManifestCount: Int,
        counters: WorkspaceCodemapBindingEngineCounters,
        projectionJobCount: Int = 0,
        suspendedProjectionJobCount: Int = 0,
        queuedProjectionBatchCount: Int = 0,
        activeProjectionBatchCount: Int = 0,
        drainingProjectionTaskCount: Int = 0,
        retainedProjectionDemandCount: Int = 0,
        retainedProjectionDemandMetadataByteCount: UInt64 = 0,
        terminalProjectionDemandStatusCount: Int = 0,
        projectionResources: WorkspaceCodemapProjectionResourceAccounting = .zero,
        projectionRoots: [WorkspaceCodemapBindingEngineProjectionRootAccounting] = []
    ) {
        self.rootCount = rootCount
        self.eligibleRootCount = eligibleRootCount
        self.unavailableRootCount = unavailableRootCount
        self.activeRequestCount = activeRequestCount
        self.queuedRequestCount = queuedRequestCount
        self.ownerCount = ownerCount
        self.reservedSourceByteCount = reservedSourceByteCount
        self.manifestAdoptionLeaseCount = manifestAdoptionLeaseCount
        self.manifestAdoptionLeaseByteCount = manifestAdoptionLeaseByteCount
        self.rootAdmissionHistoryCount = rootAdmissionHistoryCount
        self.ownerAdmissionHistoryCount = ownerAdmissionHistoryCount
        self.dirtyManifestCount = dirtyManifestCount
        self.counters = counters
        self.projectionJobCount = projectionJobCount
        self.suspendedProjectionJobCount = suspendedProjectionJobCount
        self.queuedProjectionBatchCount = queuedProjectionBatchCount
        self.activeProjectionBatchCount = activeProjectionBatchCount
        self.drainingProjectionTaskCount = drainingProjectionTaskCount
        self.retainedProjectionDemandCount = retainedProjectionDemandCount
        self.retainedProjectionDemandMetadataByteCount = retainedProjectionDemandMetadataByteCount
        self.terminalProjectionDemandStatusCount = terminalProjectionDemandStatusCount
        self.projectionResources = projectionResources
        self.projectionRoots = projectionRoots
    }
}
