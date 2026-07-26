import Foundation
import RepoPromptCodeMapCore

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
    let maximumActiveGraphIndexBatchCountPerRoot: Int
    let maximumActiveGraphIndexBatchCount: Int
    let maximumGraphIndexCatalogPageEntryCount: Int
    let maximumGraphIndexCatalogPagePathByteCount: UInt64
    let maximumGraphIndexBatchCandidateCount: Int
    let graphIndexProgressPublicationMinimumIntervalMilliseconds: UInt64
    let maximumGraphIndexChangeByteCount: UInt64
    let maximumRetainedGraphIndexByteCountPerRoot: UInt64
    let maximumRetainedGraphIndexByteCount: UInt64
    let maximumStagedGraphIndexGraphByteCountPerRoot: UInt64
    let maximumStagedGraphIndexGraphByteCount: UInt64
    let maximumQueuedGraphIndexManifestMutationByteCountPerRoot: UInt64
    let maximumQueuedGraphIndexManifestMutationByteCount: UInt64
    let maximumManifestWriterDeferredItemCount: Int
    let manifestWriterDeferredRetryMilliseconds: UInt64
    let graphIndexRetryInitialMilliseconds: UInt64
    let graphIndexRetryMaximumMilliseconds: UInt64
    let graphIndexRetryJitterPercent: UInt64

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
        maximumActiveGraphIndexBatchCountPerRoot: Int = 1,
        maximumActiveGraphIndexBatchCount: Int = 2,
        maximumGraphIndexCatalogPageEntryCount: Int = 64,
        maximumGraphIndexCatalogPagePathByteCount: UInt64 = 256 * 1024,
        maximumGraphIndexBatchCandidateCount: Int = 64,
        graphIndexProgressPublicationMinimumIntervalMilliseconds: UInt64 = 100,
        maximumGraphIndexChangeByteCount: UInt64 = 8 * 1024 * 1024,
        maximumRetainedGraphIndexByteCountPerRoot: UInt64 = 32 * 1024 * 1024,
        maximumRetainedGraphIndexByteCount: UInt64 = 128 * 1024 * 1024,
        maximumStagedGraphIndexGraphByteCountPerRoot: UInt64 = 192 * 1024 * 1024,
        maximumStagedGraphIndexGraphByteCount: UInt64 = 512 * 1024 * 1024,
        maximumQueuedGraphIndexManifestMutationByteCountPerRoot: UInt64 = 8 * 1024 * 1024,
        maximumQueuedGraphIndexManifestMutationByteCount: UInt64 = 32 * 1024 * 1024,
        maximumManifestWriterDeferredItemCount: Int = 256,
        manifestWriterDeferredRetryMilliseconds: UInt64 = 100,
        graphIndexRetryInitialMilliseconds: UInt64 = 250,
        graphIndexRetryMaximumMilliseconds: UInt64 = 30000,
        graphIndexRetryJitterPercent: UInt64 = 20
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
        precondition(maximumActiveGraphIndexBatchCountPerRoot > 0)
        precondition(maximumActiveGraphIndexBatchCount > 0)
        precondition(maximumActiveGraphIndexBatchCount >= maximumActiveGraphIndexBatchCountPerRoot)
        precondition(maximumGraphIndexCatalogPageEntryCount > 0)
        precondition(maximumGraphIndexCatalogPagePathByteCount > 0)
        precondition(maximumGraphIndexBatchCandidateCount > 0)
        precondition(maximumGraphIndexBatchCandidateCount <= maximumGraphIndexCatalogPageEntryCount)
        precondition((25 ... 1000).contains(graphIndexProgressPublicationMinimumIntervalMilliseconds))
        precondition(maximumGraphIndexChangeByteCount > 0)
        precondition(maximumRetainedGraphIndexByteCountPerRoot > 0)
        precondition(maximumRetainedGraphIndexByteCount > 0)
        precondition(maximumRetainedGraphIndexByteCount >= maximumRetainedGraphIndexByteCountPerRoot)
        precondition(maximumStagedGraphIndexGraphByteCountPerRoot > 0)
        precondition(maximumStagedGraphIndexGraphByteCount > 0)
        precondition(maximumStagedGraphIndexGraphByteCount >= maximumStagedGraphIndexGraphByteCountPerRoot)
        precondition(maximumQueuedGraphIndexManifestMutationByteCountPerRoot > 0)
        precondition(maximumQueuedGraphIndexManifestMutationByteCount > 0)
        precondition(
            maximumQueuedGraphIndexManifestMutationByteCount >=
                maximumQueuedGraphIndexManifestMutationByteCountPerRoot
        )
        precondition(maximumManifestWriterDeferredItemCount > 0)
        precondition(manifestWriterDeferredRetryMilliseconds > 0)
        precondition(graphIndexRetryInitialMilliseconds > 0)
        precondition(graphIndexRetryMaximumMilliseconds >= graphIndexRetryInitialMilliseconds)
        precondition(graphIndexRetryJitterPercent <= 100)
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
        self.maximumActiveGraphIndexBatchCountPerRoot = maximumActiveGraphIndexBatchCountPerRoot
        self.maximumActiveGraphIndexBatchCount = maximumActiveGraphIndexBatchCount
        self.maximumGraphIndexCatalogPageEntryCount = maximumGraphIndexCatalogPageEntryCount
        self.maximumGraphIndexCatalogPagePathByteCount = maximumGraphIndexCatalogPagePathByteCount
        self.maximumGraphIndexBatchCandidateCount = maximumGraphIndexBatchCandidateCount
        self.graphIndexProgressPublicationMinimumIntervalMilliseconds =
            graphIndexProgressPublicationMinimumIntervalMilliseconds
        self.maximumGraphIndexChangeByteCount = maximumGraphIndexChangeByteCount
        self.maximumRetainedGraphIndexByteCountPerRoot = maximumRetainedGraphIndexByteCountPerRoot
        self.maximumRetainedGraphIndexByteCount = maximumRetainedGraphIndexByteCount
        self.maximumStagedGraphIndexGraphByteCountPerRoot = maximumStagedGraphIndexGraphByteCountPerRoot
        self.maximumStagedGraphIndexGraphByteCount = maximumStagedGraphIndexGraphByteCount
        self.maximumQueuedGraphIndexManifestMutationByteCountPerRoot =
            maximumQueuedGraphIndexManifestMutationByteCountPerRoot
        self.maximumQueuedGraphIndexManifestMutationByteCount =
            maximumQueuedGraphIndexManifestMutationByteCount
        self.maximumManifestWriterDeferredItemCount = maximumManifestWriterDeferredItemCount
        self.manifestWriterDeferredRetryMilliseconds = manifestWriterDeferredRetryMilliseconds
        self.graphIndexRetryInitialMilliseconds = graphIndexRetryInitialMilliseconds
        self.graphIndexRetryMaximumMilliseconds = graphIndexRetryMaximumMilliseconds
        self.graphIndexRetryJitterPercent = graphIndexRetryJitterPercent
    }
}

struct WorkspaceCodemapManifestWriterRetryWaiter {
    let sleep: @Sendable (Duration) async throws -> Void

    static let production = Self { duration in
        try await Task.sleep(for: duration)
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
    let readGraphIndexCatalogPage: @Sendable (
        WorkspaceCodemapGraphIndexCatalogPageRequest
    ) async -> WorkspaceCodemapGraphIndexCatalogPageDisposition
    let revalidateGraphIndexCatalogToken: @Sendable (
        WorkspaceCodemapRootEpoch,
        WorkspaceCodemapGraphIndexCatalogToken
    ) async -> WorkspaceCodemapGraphIndexCatalogTokenDisposition
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
            readGraphIndexCatalogPage: { _ in .unavailable(.catalogUnavailable) },
            revalidateGraphIndexCatalogToken: { _, _ in .unavailable(.catalogUnavailable) },
            publishMarkerReadiness: { _ in false }
        )
    }

    init(
        _ resolveManifestBinding: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            String
        ) async -> WorkspaceCodemapManifestBindingCandidate?,
        readGraphIndexCatalogPage: @escaping @Sendable (
            WorkspaceCodemapGraphIndexCatalogPageRequest
        ) async -> WorkspaceCodemapGraphIndexCatalogPageDisposition,
        revalidateGraphIndexCatalogToken: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            WorkspaceCodemapGraphIndexCatalogToken
        ) async -> WorkspaceCodemapGraphIndexCatalogTokenDisposition,
        publishMarkerReadiness: @escaping @Sendable (
            WorkspaceCodemapMarkerReadinessUpdate
        ) async -> Bool = { _ in false }
    ) {
        self.resolveManifestBinding = resolveManifestBinding
        self.readGraphIndexCatalogPage = readGraphIndexCatalogPage
        self.revalidateGraphIndexCatalogToken = revalidateGraphIndexCatalogToken
        self.publishMarkerReadiness = publishMarkerReadiness
    }

    static let unavailable = WorkspaceCodemapBindingCatalogClient { _, _ in nil }
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
    case graphIndexCAS
    case locatorCAS
}

enum WorkspaceCodemapPublishedArtifactLookupMissReason: String, Error, Equatable {
    case rootUnavailable
    case currentnessMismatch
    case unsupportedFileType
    case graphIndexMissing
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
    case manifestWaiterInstalled
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
    case graphIndexRunScheduled
    case graphIndexRunStarted
    case graphIndexFirstChange
    case graphIndexChangePublished
    case graphIndexCoverageComplete
    case graphIndexCoverageCancelled
    case graphIndexCoverageSuperseded
    case graphIndexEnvelopeHit
    case graphIndexEnvelopeStale
    case graphIndexEnvelopeInvalid
    case graphIndexTerminalRecordHit
    case graphIndexLocatorMiss
    case graphIndexLocatorCorrupt
    case graphIndexCASMiss
    case graphIndexArtifactBuildJoined
    case graphIndexArtifactBuildStarted
    case graphIndexArtifactBuildCompleted
    case graphIndexCatalogPage
    case graphIndexCatalogCandidates
    case graphIndexCatalogPathBytes
    case graphIndexBatchQueued
    case graphIndexBatchStarted
    case graphIndexBatchCompleted
    case graphIndexBatchCancelled
    case graphIndexRetry
    case graphIndexRootOvertake
    case graphIndexExplicitOvertake
    case graphIndexBudget
}

/// Hook payloads deliberately contain no physical or logical path.
struct WorkspaceCodemapBindingEngineHookEvent {
    let kind: WorkspaceCodemapBindingEngineHookKind
    let rootEpoch: WorkspaceCodemapRootEpoch?
    let artifactStorageDigest: String?
    let numericValue: UInt64
    let graphIndexPhase: WorkspaceCodemapGraphIndexPhase?
    let retryAfterMilliseconds: UInt64?
    let publishedArtifactLookupSource: WorkspaceCodemapPublishedArtifactLookupSource?
    let publishedArtifactLookupMissReason: WorkspaceCodemapPublishedArtifactLookupMissReason?
    let invalidationReason: WorkspaceCodemapLiveOverlayInvalidationReason?

    init(
        kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch?,
        artifactStorageDigest: String?,
        numericValue: UInt64,
        graphIndexPhase: WorkspaceCodemapGraphIndexPhase? = nil,
        retryAfterMilliseconds: UInt64? = nil,
        publishedArtifactLookupSource: WorkspaceCodemapPublishedArtifactLookupSource? = nil,
        publishedArtifactLookupMissReason: WorkspaceCodemapPublishedArtifactLookupMissReason? = nil,
        invalidationReason: WorkspaceCodemapLiveOverlayInvalidationReason? = nil
    ) {
        self.kind = kind
        self.rootEpoch = rootEpoch
        self.artifactStorageDigest = artifactStorageDigest
        self.numericValue = numericValue
        self.graphIndexPhase = graphIndexPhase
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.publishedArtifactLookupSource = publishedArtifactLookupSource
        self.publishedArtifactLookupMissReason = publishedArtifactLookupMissReason
        self.invalidationReason = invalidationReason
    }
}

struct WorkspaceCodemapBindingEngineHooks {
    let event: @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void
    let afterManifestRevisionQueuedBeforeWaiterInstall: @Sendable (
        WorkspaceCodemapRootEpoch,
        UInt64
    ) async -> Void
    let afterManifestStoreWriteBeforeCompletion: @Sendable (WorkspaceCodemapRootEpoch) async -> Void
    #if DEBUG
        /// Deterministic race seam, structurally absent from non-DEBUG products.
        let afterPublishedArtifactLookupBeforeCurrentnessValidation: @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void
    #endif

    init(
        event: @escaping @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void = { _ in },
        afterManifestRevisionQueuedBeforeWaiterInstall: @escaping @Sendable (
            WorkspaceCodemapRootEpoch,
            UInt64
        ) async -> Void = { _, _ in },
        afterManifestStoreWriteBeforeCompletion: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in }
    ) {
        self.event = event
        self.afterManifestRevisionQueuedBeforeWaiterInstall =
            afterManifestRevisionQueuedBeforeWaiterInstall
        self.afterManifestStoreWriteBeforeCompletion = afterManifestStoreWriteBeforeCompletion
        #if DEBUG
            afterPublishedArtifactLookupBeforeCurrentnessValidation = { _ in }
        #endif
    }

    #if DEBUG
        init(
            event: @escaping @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void = { _ in },
            afterManifestRevisionQueuedBeforeWaiterInstall: @escaping @Sendable (
                WorkspaceCodemapRootEpoch,
                UInt64
            ) async -> Void = { _, _ in },
            afterManifestStoreWriteBeforeCompletion: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void = { _ in },
            afterPublishedArtifactLookupBeforeCurrentnessValidation: @escaping @Sendable (
                WorkspaceCodemapRootEpoch
            ) async -> Void
        ) {
            self.event = event
            self.afterManifestRevisionQueuedBeforeWaiterInstall =
                afterManifestRevisionQueuedBeforeWaiterInstall
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
    var manifestWriteBatches: UInt64 = 0
    var manifestWriteItems: UInt64 = 0
    var manifestWriteBatchBytes: UInt64 = 0
    var manifestWriteCoalescedItems: UInt64 = 0
    var manifestWriterPeakQueuedItems: UInt64 = 0
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
    var publishedArtifactGraphIndexCASHits: UInt64 = 0
    var publishedArtifactLocatorCASHits: UInt64 = 0
    var publishedArtifactLookupMisses: UInt64 = 0
    #if DEBUG
        var publishedArtifactPostLookupCurrentnessRejections: UInt64 = 0
    #endif
    var graphIndexRunsScheduled: UInt64 = 0
    var graphIndexRunsStarted: UInt64 = 0
    var graphIndexFirstChanges: UInt64 = 0
    var graphIndexChangesPublished: UInt64 = 0
    var graphIndexChangeBytes: UInt64 = 0
    var graphIndexCoveragesCompleted: UInt64 = 0
    var graphIndexCoveragesCancelled: UInt64 = 0
    var graphIndexCoveragesSuperseded: UInt64 = 0
    var graphIndexEnvelopeHits: UInt64 = 0
    var graphIndexEnvelopeStale: UInt64 = 0
    var graphIndexEnvelopeInvalid: UInt64 = 0
    var graphIndexTerminalRecordHits: UInt64 = 0
    var graphIndexLocatorMisses: UInt64 = 0
    var graphIndexLocatorCorruptions: UInt64 = 0
    var graphIndexCASMisses: UInt64 = 0
    var graphIndexArtifactBuildsJoined: UInt64 = 0
    var graphIndexArtifactBuildsStarted: UInt64 = 0
    var graphIndexArtifactBuildsCompleted: UInt64 = 0
    var graphIndexCatalogPages: UInt64 = 0
    var graphIndexCatalogCandidates: UInt64 = 0
    var graphIndexCatalogPathBytes: UInt64 = 0
    var graphIndexBatchesQueued: UInt64 = 0
    var graphIndexBatchesStarted: UInt64 = 0
    var graphIndexBatchesCompleted: UInt64 = 0
    var graphIndexRetries: UInt64 = 0
    var graphIndexRootOvertakes: UInt64 = 0
    var graphIndexExplicitOvertakes: UInt64 = 0
    var graphIndexBudgetRejections: UInt64 = 0
    var graphIndexCancelledBatches: UInt64 = 0

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
        manifestWriteBatches = initialValue
        manifestWriteItems = initialValue
        manifestWriteBatchBytes = initialValue
        manifestWriteCoalescedItems = initialValue
        manifestWriterPeakQueuedItems = initialValue
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
        publishedArtifactGraphIndexCASHits = initialValue
        publishedArtifactLocatorCASHits = initialValue
        publishedArtifactLookupMisses = initialValue
        #if DEBUG
            publishedArtifactPostLookupCurrentnessRejections = initialValue
        #endif
        graphIndexRunsScheduled = initialValue
        graphIndexRunsStarted = initialValue
        graphIndexFirstChanges = initialValue
        graphIndexChangesPublished = initialValue
        graphIndexChangeBytes = initialValue
        graphIndexCoveragesCompleted = initialValue
        graphIndexCoveragesCancelled = initialValue
        graphIndexCoveragesSuperseded = initialValue
        graphIndexEnvelopeHits = initialValue
        graphIndexEnvelopeStale = initialValue
        graphIndexEnvelopeInvalid = initialValue
        graphIndexTerminalRecordHits = initialValue
        graphIndexLocatorMisses = initialValue
        graphIndexLocatorCorruptions = initialValue
        graphIndexCASMisses = initialValue
        graphIndexArtifactBuildsJoined = initialValue
        graphIndexArtifactBuildsStarted = initialValue
        graphIndexArtifactBuildsCompleted = initialValue
        graphIndexCatalogPages = initialValue
        graphIndexCatalogCandidates = initialValue
        graphIndexCatalogPathBytes = initialValue
        graphIndexBatchesQueued = initialValue
        graphIndexBatchesStarted = initialValue
        graphIndexBatchesCompleted = initialValue
        graphIndexRetries = initialValue
        graphIndexRootOvertakes = initialValue
        graphIndexExplicitOvertakes = initialValue
        graphIndexBudgetRejections = initialValue
        graphIndexCancelledBatches = initialValue
    }
}

struct WorkspaceCodemapBindingEngineGraphIndexRootAccounting: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let phase: WorkspaceCodemapGraphIndexPhase
    let progress: WorkspaceCodemapGraphIndexProgress
    let queuedBatchCount: Int
    let activeBatchCount: Int
    let drainingBatchCount: Int
    let resources: WorkspaceCodemapGraphIndexResourceAccounting
    let retry: WorkspaceCodemapGraphIndexRetry?
    let budget: WorkspaceCodemapGraphIndexBudget?
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
    let graphIndexJobCount: Int
    let suspendedGraphIndexJobCount: Int
    let queuedGraphIndexBatchCount: Int
    let activeGraphIndexBatchCount: Int
    let drainingGraphIndexTaskCount: Int
    let graphIndexResources: WorkspaceCodemapGraphIndexResourceAccounting
    let graphIndexRoots: [WorkspaceCodemapBindingEngineGraphIndexRootAccounting]

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
        graphIndexJobCount: Int = 0,
        suspendedGraphIndexJobCount: Int = 0,
        queuedGraphIndexBatchCount: Int = 0,
        activeGraphIndexBatchCount: Int = 0,
        drainingGraphIndexTaskCount: Int = 0,
        graphIndexResources: WorkspaceCodemapGraphIndexResourceAccounting = .zero,
        graphIndexRoots: [WorkspaceCodemapBindingEngineGraphIndexRootAccounting] = []
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
        self.graphIndexJobCount = graphIndexJobCount
        self.suspendedGraphIndexJobCount = suspendedGraphIndexJobCount
        self.queuedGraphIndexBatchCount = queuedGraphIndexBatchCount
        self.activeGraphIndexBatchCount = activeGraphIndexBatchCount
        self.drainingGraphIndexTaskCount = drainingGraphIndexTaskCount
        self.graphIndexResources = graphIndexResources
        self.graphIndexRoots = graphIndexRoots
    }
}
