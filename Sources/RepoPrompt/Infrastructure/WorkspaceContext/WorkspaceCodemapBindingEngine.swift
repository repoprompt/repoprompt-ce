import Foundation
import RepoPromptCodeMapCore

/// Inert orchestration for Git-only, artifact-backed workspace codemap bindings.
///
/// One injected instance can own bounded sessions for many roots. It deliberately owns no source
/// catalog and no artifact cache: those remain with the caller and the process-wide artifact runtime.
struct WorkspaceCodemapManifestFIFO<Element> {
    private(set) var storage: [Element] = []
    private(set) var head = 0

    var count: Int {
        storage.count - head
    }

    var isEmpty: Bool {
        head == storage.count
    }

    var first: Element? {
        head < storage.count ? storage[head] : nil
    }

    mutating func append(_ item: Element) {
        storage.append(item)
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let item = storage[head]
        head += 1
        compactIfNeeded()
        return item
    }

    mutating func popBatch(
        maximumItemCount: Int,
        maximumByteCount: UInt64,
        byteCount: (Element) -> UInt64,
        canAppend: (Element, Element, Element) -> Bool
    ) -> [Element] {
        guard let first = popFirst() else { return [] }
        var items = [first]
        var bytes = byteCount(first)
        while items.count < maximumItemCount,
              let previous = items.last,
              let next = self.first
        {
            let nextBytes = byteCount(next)
            let (candidateBytes, overflow) = bytes.addingReportingOverflow(nextBytes)
            guard !overflow,
                  candidateBytes <= maximumByteCount,
                  canAppend(first, previous, next),
                  let absorbed = popFirst()
            else { break }
            items.append(absorbed)
            bytes = candidateBytes
        }
        return items
    }

    func contains(where predicate: (Element) -> Bool) -> Bool {
        storage[head...].contains(where: predicate)
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        storage = storage[head...].filter { !shouldRemove($0) }
        head = 0
    }

    mutating func prepend(contentsOf items: [Element]) {
        guard !items.isEmpty else { return }
        storage = items + Array(storage[head...])
        head = 0
    }

    mutating func drain() -> [Element] {
        let items = Array(storage[head...])
        storage.removeAll(keepingCapacity: false)
        head = 0
        return items
    }

    private mutating func compactIfNeeded() {
        guard head >= 64, head * 2 >= storage.count else { return }
        storage.removeFirst(head)
        head = 0
    }
}

actor WorkspaceCodemapBindingEngine {
    private enum GraphIndexPublicationDisposition {
        case accepted(WorkspaceCodemapGraphIndexProgress)
        case exactDuplicate(WorkspaceCodemapGraphIndexProgress)
        case stale
        case superseded
        case busy(retryAfterMilliseconds: UInt64?)
        case budget(dimension: WorkspaceCodemapGraphIndexBudgetDimension, attempted: UInt64, limit: UInt64)
        case unavailable
    }

    private static let maximumManifestWriterBatchItemCount = 64
    private static let maximumManifestWriterDeferredAttempts = 3

    private final class DemandCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var isCancelled: Bool {
            lock.withLock { storage }
        }

        func cancel() {
            lock.withLock { storage = true }
        }
    }

    private struct RegistrationAttempt {
        let id: UUID
        let registration: WorkspaceCodemapBindingRootRegistration
        var cancelled: Bool
    }

    private struct UnavailableRoot {
        let registration: WorkspaceCodemapBindingRootRegistration
        let state: WorkspaceCodemapGitCapabilityState
    }

    private struct PipelineSession {
        let id: UUID
        let language: LanguageType
        let pipelineIdentity: CodeMapPipelineIdentity
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        var previouslyObservedManifestAuthority: CodeMapRootManifestAuthority?
        var manifestRecords: [String: CodeMapRootManifestRecord]
        var automaticSelectionCandidateRecords: [String: CodeMapRootManifestRecord]
        var manifestState: WorkspaceCodemapBindingManifestState
        var manifestLoadStarted: Bool
        var manifestLoadFinished: Bool
        var manifestRevision: UInt64
        var persistedManifestRevision: UInt64
        var pendingManifestChanges: [String: PendingManifestChange]
    }

    private struct Session {
        let id: UUID
        let registration: WorkspaceCodemapBindingRootRegistration
        let capability: GitCodemapRootCapability
        let manifestWriterSession: CodeMapRootManifestWriterSessionToken
        var pipelines: [CodeMapPipelineIdentity: PipelineSession]
        var pathGenerations: [String: UInt64]
        var generation: UInt64
        var invalidationGeneration: UInt64
    }

    private struct PipelineScope: Hashable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let pipelineIdentity: CodeMapPipelineIdentity
    }

    private enum ManifestAdoptionOutcome {
        case terminal(adoptedReadyCount: Int)
        case retryable
        case superseded
    }

    private struct ManifestAdoptionAttempt {
        let operationID: UUID
        let scope: PipelineScope
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let pipelineSessionID: UUID
        let catalogGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        let manifestRevision: UInt64
    }

    private struct ManifestAdoptionOperation {
        let attempt: ManifestAdoptionAttempt
        let task: Task<ManifestAdoptionOutcome, Never>
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    private struct ActiveRequest {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let demand: WorkspaceCodemapBindingDemand
        let publicOwner: WorkspaceCodemapLiveDemandOwner
        let relativePath: String
        let sessionID: UUID
        let sessionGeneration: UInt64
        let pipelineIdentity: CodeMapPipelineIdentity
        let pipelineSessionID: UUID
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let reservedSourceBytes: UInt64
        var overlayOwner: WorkspaceCodemapLiveDemandOwner?
        var preflight: WorkspaceCodemapLiveDemandPreflightTicket?
        var ticket: WorkspaceCodemapLiveDemandTicket?
        var task: Task<Void, Never>?
        var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
        var cancelled: Bool
    }

    private struct QueuedRequest {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let demand: WorkspaceCodemapBindingDemand
        var enqueueOrdinal: UInt64
        var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
    }

    private struct OwnerKey: Hashable {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let owner: WorkspaceCodemapLiveDemandOwner
    }

    private struct ManifestAdoptionContext {
        let operationID: UUID
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let pipelineIdentity: CodeMapPipelineIdentity
        let pipelineSessionID: UUID
        let catalogGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let namespace: CodeMapRootManifestNamespace
        let authority: CodeMapRootManifestAuthority
        let manifestRevision: UInt64
        let ticket: WorkspaceCodemapLiveManifestAdoptionTicket
    }

    private struct PreparedManifestAdoption {
        let record: CodeMapRootManifestRecord
        let candidate: WorkspaceCodemapManifestBindingCandidate
        let sourceAuthority: WorkspaceCodemapSourceAuthorityToken
        let association: VerifiedGitBlobCodeMapLocatorAssociation
        let lease: CodeMapArtifactLease?
    }

    private struct PendingManifestChange {
        let revision: UInt64
        let workItemID: UUID
        let record: CodeMapRootManifestRecord?
    }

    private enum ManifestMutation {
        case upsert(CodeMapRootManifestRecord)
        case remove(repositoryRelativePath: String)

        var repositoryRelativePath: String {
            switch self {
            case let .upsert(record): record.repositoryRelativePath
            case let .remove(repositoryRelativePath): repositoryRelativePath
            }
        }

        var record: CodeMapRootManifestRecord? {
            switch self {
            case let .upsert(record): record
            case .remove: nil
            }
        }
    }

    private enum ManifestMutationAuthority: Equatable {
        case session(invalidationGeneration: UInt64)
        case graphIndex(jobID: UUID, generation: WorkspaceCodemapGraphIndexGeneration)
    }

    private enum ManifestMutationSubmissionResult {
        case persisted
        case durabilityFailure
        case retry
        case budget(WorkspaceCodemapGraphIndexBudget)
    }

    private struct ManifestWriterWorkKey: Hashable {
        let scope: PipelineScope
        let sessionID: UUID
        let pipelineSessionID: UUID
    }

    private struct ManifestMutationWorkItem {
        let id: UUID
        let workKey: ManifestWriterWorkKey
        let revision: UInt64
        let proof: ManifestMutationAuthority
        let mutations: [ManifestMutation]
        let byteCount: UInt64
    }

    private struct ManifestMutationBatch {
        let id: UUID
        let workKey: ManifestWriterWorkKey
        let proof: ManifestMutationAuthority
        let items: [ManifestMutationWorkItem]
        let highestRevision: UInt64
        let changesByPath: [String: PendingManifestChange]
        let byteCount: UInt64
        let absorbedWorkItemCount: Int
    }

    private struct ManifestWriteWaiter {
        let id: UUID
        let revision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ManifestWriterState {
        var writerID: UUID?
        var task: Task<Void, Never>?
        var retryTask: Task<Void, Never>?
        var retryID: UUID?
        var queuedWork = WorkspaceCodemapManifestFIFO<ManifestMutationWorkItem>()
        var deferredHeadBatch: ManifestMutationBatch?
        var deferredWork: [ManifestMutationWorkItem] = []
        var deferredFailureCount: UInt = 0
        var inFlightBatch: ManifestMutationBatch?
        var waitersByWorkKey: [ManifestWriterWorkKey: [ManifestWriteWaiter]] = [:]
        var waiterWorkKeyByID: [UUID: ManifestWriterWorkKey] = [:]
    }

    private struct GraphIndexAdmissionWaiter {
        let jobID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        var enqueueOrdinal: UInt64
        var rootOvertakeRecorded: Bool
        var explicitOvertakeRecorded: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Root-local warm index state and progress accounting. Graph publication is
    /// exclusively overlay-driven.
    private struct GraphIndexJob {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        var phase: WorkspaceCodemapGraphIndexPhase
        var generation: WorkspaceCodemapGraphIndexGeneration?
        var cursor: WorkspaceCodemapGraphIndexCatalogCursor?
        var lastProcessedCursor: WorkspaceCodemapGraphIndexCatalogCursor?
        var progress: WorkspaceCodemapGraphIndexProgress
        var inBatchProgress: WorkspaceCodemapGraphIndexInBatchProgress?
        var pageStartProcessedCandidateBaseline: UInt64?
        var nextGraphChangeSequence: UInt64
        var pipelineScopes: [CodeMapPipelineIdentity: WorkspaceCodemapGraphIndexPipelineScope]
        var resources: WorkspaceCodemapGraphIndexResourceAccounting
        var pendingManifestMutationCount: UInt64
        var retryAttempt: UInt64
        var retry: WorkspaceCodemapGraphIndexRetry?
        var budget: WorkspaceCodemapGraphIndexBudget?
        var checkpoint: WorkspaceCodemapGraphIndexCheckpoint?
        var task: Task<Void, Never>?
        var isQueuedForAdmission: Bool
        var isActiveBatch: Bool
    }

    private enum GraphIndexCandidateResolution {
        case entry(WorkspaceCodemapGraphIndexEntry, manifestRecord: CodeMapRootManifestRecord?)
        case transient
        case budget(WorkspaceCodemapGraphIndexBudget)
    }

    private struct IndexedGraphIndexCandidateResolution: @unchecked Sendable {
        let index: Int
        let fileID: UUID
        let resolution: GraphIndexCandidateResolution
    }

    private enum GraphIndexBatchResult {
        case checkpointed
        case complete
        case retry
        case restartGeneration
        case restartPage
        case budgetLimited
        case cancelled
        case superseded
    }

    private enum GraphIndexResourceReservationResult {
        case reserved
        case retry
        case budget(WorkspaceCodemapGraphIndexBudget)
    }

    private enum GraphIndexPublicationStalenessResult {
        case restartGeneration
        case retry
        case terminal
    }

    private struct AdoptionReservation {
        let id: UUID
        var recordCount: Int
        var leaseBytesByRelativePath: [String: UInt64]

        var leaseCount: Int {
            leaseBytesByRelativePath.count
        }

        var leaseBytes: UInt64 {
            leaseBytesByRelativePath.values.reduce(0) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(value)
                return overflow ? .max : sum
            }
        }
    }

    private struct OverlayCancellation {
        let owner: WorkspaceCodemapLiveDemandOwner?
        let ticket: WorkspaceCodemapLiveDemandTicket?
        let preflight: WorkspaceCodemapLiveDemandPreflightTicket?
    }

    private struct SynchronousCancellationBatch {
        let overlayCancellations: [OverlayCancellation]
        let cancelledRequestCount: Int
    }

    private struct ValidatedDemandContext {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let session: Session
        let pipelineIdentity: CodeMapPipelineIdentity
        let pathGeneration: UInt64
    }

    private enum DemandValidation {
        case valid(ValidatedDemandContext)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private enum RootRecord {
        case registering(RegistrationAttempt)
        case unavailable(UnavailableRoot)
        case eligible(Session)
    }

    private struct ResolvedArtifact {
        let resolution: CodeMapArtifactCoordinatorResolution
        let association: VerifiedGitBlobCodeMapLocatorAssociation?
        let materializedByteCount: UInt64
        let performedBuild: Bool
        let locatorFastPath: Bool
        let casFastPath: Bool
    }

    private struct PublishedArtifactLookupContext {
        let rootEpoch: WorkspaceCodemapRootEpoch
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let pipelineSessionID: UUID
        let pipelineIdentity: CodeMapPipelineIdentity
        let repositoryRelativePath: String
        let pathGeneration: UInt64
        let record: CodeMapRootManifestRecord
    }

    private enum CleanArtifactFastPathResult {
        case ready(ResolvedArtifact)
        case miss(CodeMapArtifactCoordinatorMiss)
    }

    private let runtime: CodeMapArtifactRuntime
    private let capabilityService: WorkspaceCodemapGitCapabilityService
    private let identityService: GitBlobIdentityService
    private let materializationService: GitBlobSourceMaterializationService
    private let sourceReader: WorkspaceCodemapValidatedSourceReaderClient
    private let catalogClient: WorkspaceCodemapBindingCatalogClient
    private let overlay: WorkspaceCodemapLiveOverlay
    private let selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory
    private let policy: WorkspaceCodemapBindingEnginePolicy
    private let hooks: WorkspaceCodemapBindingEngineHooks
    private let manifestWriterRetryWaiter: WorkspaceCodemapManifestWriterRetryWaiter
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let accessEpochSeconds: @Sendable () -> UInt64
    private var roots: [WorkspaceCodemapRootEpoch: RootRecord] = [:]
    private var activeRequests: [UUID: ActiveRequest] = [:]
    private var drainingRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var queuedRequests: [UUID: QueuedRequest] = [:]
    private var queueOrder: [UUID] = []
    private var nextQueueOrdinal: UInt64 = 1
    private var nextAdmissionOrdinal: UInt64 = 1
    private var rootLastAdmission: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var ownerLastAdmission: [OwnerKey: UInt64] = [:]
    private var consecutiveDemandAdmissions = 0
    private var manifestWriters: [CodeMapRootManifestNamespace: ManifestWriterState] = [:]
    private var pendingManifestWaiterInstalls: Set<UUID> = []
    private var cancelledManifestWaiterInstalls: Set<UUID> = []
    private var adoptionReservations: [PipelineScope: AdoptionReservation] = [:]
    private var retainedAdoptions: [PipelineScope: AdoptionReservation] = [:]
    private var manifestAdoptionOperations: [PipelineScope: ManifestAdoptionOperation] = [:]
    private var drainingManifestAdoptionTasks: [UUID: Task<ManifestAdoptionOutcome, Never>] = [:]
    private var graphIndexJobs: [WorkspaceCodemapRootEpoch: GraphIndexJob] = [:]
    private var selectionGraphsByRootEpoch: [WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraph] = [:]
    private var graphPullTasksByRootEpoch: [
        WorkspaceCodemapRootEpoch: (id: UUID, task: Task<Void, Never>)
    ] = [:]
    private var latestOverlayContributionGenerationByRootEpoch: [
        WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraphContributionGeneration
    ] = [:]
    private var graphIndexAdmissionQueue: [GraphIndexAdmissionWaiter] = []
    private var activeGraphIndexJobIDs: Set<UUID> = []
    private var drainingGraphIndexTasks: [UUID: Task<Void, Never>] = [:]
    private var drainingGraphIndexResources: [UUID: WorkspaceCodemapGraphIndexResourceAccounting] = [:]
    private var drainingGraphIndexRootEpochs: [UUID: WorkspaceCodemapRootEpoch] = [:]
    private var nextGraphIndexQueueOrdinal: UInt64 = 1
    private var graphIndexRootLastAdmission: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var registrationOperations: Set<UUID> = []
    private var replacementCancelledRegistrationAttemptIDs: Set<UUID> = []
    private var registrationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false
    private var shutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var counters = WorkspaceCodemapBindingEngineCounters()
    #if DEBUG
        private struct DebugGraphIndexAdmissionHold {
            let rootEpoch: WorkspaceCodemapRootEpoch
            let expiryTask: Task<Void, Never>
        }

        private var debugGraphIndexAdmissionHolds: [UUID: DebugGraphIndexAdmissionHold] = [:]
        private var debugGraphIndexAdmissionEnqueuedAtNanoseconds: [UUID: UInt64] = [:]
        private var debugGraphIndexQueueWaitMillisecondsByRootEpoch: [
            WorkspaceCodemapRootEpoch: [UInt64]
        ] = [:]
        private var debugGraphIndexQueueWaitSampleOrdinalByRootEpoch: [
            WorkspaceCodemapRootEpoch: UInt64
        ] = [:]
    #endif

    init(
        runtime: CodeMapArtifactRuntime,
        capabilityService: WorkspaceCodemapGitCapabilityService,
        identityService: GitBlobIdentityService = GitBlobIdentityService(),
        materializationService: GitBlobSourceMaterializationService = GitBlobSourceMaterializationService(),
        sourceReader: WorkspaceCodemapValidatedSourceReaderClient,
        catalogClient: WorkspaceCodemapBindingCatalogClient = .unavailable,
        overlay: WorkspaceCodemapLiveOverlay = WorkspaceCodemapLiveOverlay(),
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
        manifestWriterRetryWaiter: WorkspaceCodemapManifestWriterRetryWaiter = .production,
        initialQueueOrdinal: UInt64 = 1,
        initialAdmissionOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        accessEpochSeconds: @escaping @Sendable () -> UInt64 = {
            UInt64(max(0, Date().timeIntervalSince1970))
        }
    ) {
        self.runtime = runtime
        self.capabilityService = capabilityService
        self.identityService = identityService
        self.materializationService = materializationService
        self.sourceReader = sourceReader
        self.catalogClient = catalogClient
        self.overlay = overlay
        self.selectionGraphFactory = selectionGraphFactory
        self.policy = policy
        self.hooks = hooks
        self.manifestWriterRetryWaiter = manifestWriterRetryWaiter
        nextQueueOrdinal = max(1, initialQueueOrdinal)
        nextAdmissionOrdinal = max(1, initialAdmissionOrdinal)
        counters = WorkspaceCodemapBindingEngineCounters(initialValue: initialCounterValue)
        self.uptimeNanoseconds = uptimeNanoseconds
        self.accessEpochSeconds = accessEpochSeconds
    }

    func registerRoot(
        _ registration: WorkspaceCodemapBindingRootRegistration,
        selectionGraph providedSelectionGraph: WorkspaceCodemapSelectionGraph? = nil
    ) async -> WorkspaceCodemapBindingRegistrationResult {
        guard !isShuttingDown else { return .failed }
        let operationID = UUID()
        registrationOperations.insert(operationID)
        defer { finishRegistrationOperation(operationID) }

        let rootEpoch = registration.capabilityRequest.rootEpoch
        if let current = roots[rootEpoch] {
            switch current {
            case let .registering(attempt):
                return attempt.registration == registration ? .busy : .failed
            case let .unavailable(unavailable):
                let replacesRevokedAuthority = unavailable.registration.capabilityRequest ==
                    registration.capabilityRequest &&
                    registration.catalogGeneration > unavailable.registration.catalogGeneration &&
                    registration.ingressGeneration > unavailable.registration.ingressGeneration
                if case .unresolved = unavailable.state,
                   unavailable.registration == registration || replacesRevokedAuthority
                {
                    roots.removeValue(forKey: rootEpoch)
                } else {
                    return unavailable.registration == registration ? .exactDuplicate : .failed
                }
            case let .eligible(session):
                return session.registration == registration ? .exactDuplicate : .failed
            }
        }
        guard registration.catalogGeneration > 0,
              registration.ingressGeneration > 0,
              roots.count < policy.maximumRootCount
        else {
            recordBusy(rootEpoch)
            return .busy
        }

        let attempt = RegistrationAttempt(id: UUID(), registration: registration, cancelled: false)
        roots[rootEpoch] = .registering(attempt)
        incrementCounter(\.capabilityResolutions)
        var capabilityState = await capabilityService.resolve(root: registration.capabilityRequest)
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        if case .transientUnavailable = capabilityState,
           policy.maximumCapabilityRetryCount == 1
        {
            incrementCounter(\.capabilityRetries)
            emit(.capabilityTransientRetry, rootEpoch: rootEpoch)
            capabilityState = await capabilityService.reload(root: registration.capabilityRequest)
            guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
                await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
                finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
                return .failed
            }
        }
        guard case let .eligible(capability) = capabilityState else {
            guard registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
                await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
                finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
                return .failed
            }
            roots[rootEpoch] = .unavailable(UnavailableRoot(
                registration: registration,
                state: capabilityState
            ))
            switch capabilityState {
            case .terminalUnavailable:
                emit(.capabilityTerminalUnavailable, rootEpoch: rootEpoch)
            default:
                emit(.failure, rootEpoch: rootEpoch)
            }
            return .unavailable(capabilityState)
        }

        let registrationDisposition = await overlay.register(
            capability: capabilityState,
            catalogGeneration: registration.catalogGeneration
        )
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        switch registrationDisposition {
        case .registered, .exactDuplicate:
            break
        case .busy:
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordBusy(rootEpoch)
            return .busy
        case .rejected:
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordFailure(rootEpoch)
            return .failed
        }

        let manifestWriterSession: CodeMapRootManifestWriterSessionToken
        do {
            manifestWriterSession = try await runtime.manifestStore.registerManifestWriterSession()
        } catch {
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordFailure(rootEpoch)
            return .failed
        }
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            return .failed
        }
        roots[rootEpoch] = .eligible(Session(
            id: UUID(),
            registration: registration,
            capability: capability,
            manifestWriterSession: manifestWriterSession,
            pipelines: [:],
            pathGenerations: [:],
            generation: 1,
            invalidationGeneration: 1
        ))
        let graph = providedSelectionGraph ?? selectionGraphFactory.make(rootEpoch: rootEpoch)
        selectionGraphsByRootEpoch[rootEpoch] = graph
        await graph.installReconciliationExpiryHandler { [weak self] in
            await self?.graphReconciliationDidExpire(rootEpoch: rootEpoch)
        }
        let pullTaskID = UUID()
        let pullTask = Task(priority: .utility) {
            await self.runGraphPullLoop(rootEpoch: rootEpoch, graph: graph)
            self.graphPullLoopDidFinish(rootEpoch: rootEpoch, taskID: pullTaskID)
        }
        graphPullTasksByRootEpoch[rootEpoch] = (pullTaskID, pullTask)
        emit(.capabilityEligible, rootEpoch: rootEpoch)
        return .registered(adoptedReadyCount: 0)
    }

    func selectionGraph(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapSelectionGraph? {
        selectionGraphsByRootEpoch[rootEpoch]
    }

    private func runGraphPullLoop(
        rootEpoch: WorkspaceCodemapRootEpoch,
        graph: WorkspaceCodemapSelectionGraph
    ) async {
        let notifications = await overlay.graphChangeNotifications(rootEpoch: rootEpoch)
        var shouldPull = true
        var iterator = notifications.makeAsyncIterator()
        while !Task.isCancelled {
            if shouldPull {
                let accounting = await graph.incrementalAccounting()
                let changes = await overlay.graphChanges(
                    rootEpoch: rootEpoch,
                    since: accounting.appliedGeneration
                )
                switch changes {
                case let .unchanged(generation):
                    await graph.observe(generation: generation)
                    shouldPull = false
                case let .revoked(reason):
                    await graph.shutdown(reason: reason)
                    return
                case let .diff(_, _, _, generation):
                    await graph.observe(generation: generation)
                    let disposition = await graph.apply(changes)
                    switch disposition {
                    case .committed, .unchanged:
                        // Pull again immediately. The overlay answers from current state, so a
                        // wakeup arriving during a non-preemptive apply cannot be lost.
                        shouldPull = true
                    case .cancelled, .revoked:
                        return
                    case .rejected:
                        // A continuity failure gets exactly one authoritative checkpoint. A
                        // rejected checkpoint below is terminal, preventing a deterministic spin.
                        _ = await overlay.advanceGraphResyncFloor(rootEpoch: rootEpoch)
                        shouldPull = true
                    }
                case let .resync(_, generation):
                    await graph.observe(generation: generation)
                    let disposition = await graph.apply(changes)
                    switch disposition {
                    case let .committed(_, _, _, _, resync):
                        shouldPull = true
                        if resync {
                            await scheduleFollowingWatcherReconciliationIfNeeded(
                                rootEpoch: rootEpoch,
                                graph: graph
                            )
                        }
                    case .unchanged:
                        shouldPull = true
                    case .cancelled, .revoked:
                        return
                    case .rejected:
                        let accounting = await graph.incrementalAccounting()
                        if accounting.reconciling {
                            _ = await graph.recordWatcherGapReconciliationFailure()
                        } else {
                            await graph.shutdown(reason: .accountingOverflow)
                        }
                        return
                    }
                }
                if shouldPull { continue }
            }
            guard let notification = await iterator.next() else {
                if !Task.isCancelled {
                    await revokeGraphAfterOverlayTermination(
                        rootEpoch: rootEpoch,
                        graph: graph,
                        reason: .rootUnloaded
                    )
                }
                return
            }
            switch notification {
            case .changed:
                shouldPull = true
            case let .revoked(reason):
                await revokeGraphAfterOverlayTermination(
                    rootEpoch: rootEpoch,
                    graph: graph,
                    reason: reason
                )
                return
            }
        }
    }

    private func revokeGraphAfterOverlayTermination(
        rootEpoch: WorkspaceCodemapRootEpoch,
        graph: WorkspaceCodemapSelectionGraph,
        reason: WorkspaceCodemapGraphRevocationReason
    ) async {
        await graph.shutdown(reason: reason)
        if let draining = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled) {
            await draining.value
        }
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
    }

    private func scheduleFollowingWatcherReconciliationIfNeeded(
        rootEpoch: WorkspaceCodemapRootEpoch,
        graph: WorkspaceCodemapSelectionGraph
    ) async {
        let accounting = await graph.incrementalAccounting()
        guard accounting.reconciling,
              case var .eligible(session)? = roots[rootEpoch],
              session.invalidationGeneration < UInt64.max
        else { return }
        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        session.invalidationGeneration += 1
        roots[rootEpoch] = .eligible(session)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        guard await overlay.beginGraphReconciliation(rootEpoch: rootEpoch) else {
            _ = await graph.recordWatcherGapReconciliationFailure()
            return
        }
        let launch = scheduleGraphIndex(rootEpoch: rootEpoch)
        if launch != .handedOff {
            _ = await graph.recordWatcherGapReconciliationFailure()
        }
    }

    private func graphReconciliationDidExpire(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async {
        guard selectionGraphsByRootEpoch[rootEpoch] != nil else { return }
        if let draining = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled) {
            await draining.value
        }
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
    }

    private func graphPullLoopDidFinish(
        rootEpoch: WorkspaceCodemapRootEpoch,
        taskID: UUID
    ) {
        guard graphPullTasksByRootEpoch[rootEpoch]?.id == taskID else { return }
        graphPullTasksByRootEpoch.removeValue(forKey: rootEpoch)
    }

    private func shutdownGraphRoot(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapGraphRevocationReason
    ) async {
        // Revoke first so a detached candidate observes cooperative cancellation. Only then drain
        // the pull task; waiting for the pull before revocation can deadlock root replacement on a
        // large candidate build.
        if let graph = selectionGraphsByRootEpoch.removeValue(forKey: rootEpoch) {
            await graph.shutdown(reason: reason)
        }
        if let pull = graphPullTasksByRootEpoch.removeValue(forKey: rootEpoch) {
            pull.task.cancel()
            await pull.task.value
        }
    }

    #if DEBUG
        func graphPullTaskCountForTesting() -> Int {
            graphPullTasksByRootEpoch.count
        }
    #endif

    /// Hands an already-public, Git-eligible root to the graph indexer.
    ///
    /// Root readiness scheduling remains owned by `WorkspaceFileContextStore`; this method is
    /// deliberately idempotent and never performs catalog, manifest, CAS, or source work inline.
    @discardableResult
    func scheduleGraphIndex(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapGraphIndexLaunchPhase {
        guard !isShuttingDown else { return .cancelled }
        guard case let .eligible(session)? = roots[rootEpoch] else { return .superseded }
        if let existing = graphIndexJobs[rootEpoch] {
            if existing.phase == .superseded {
                return .superseded
            }
            if existing.phase == .cancelled {
                return .cancelled
            }
            return graphIndexJobIsCurrent(existing) ? .handedOff : .superseded
        }

        let jobID = UUID()
        graphIndexJobs[rootEpoch] = GraphIndexJob(
            id: jobID,
            rootEpoch: rootEpoch,
            sessionID: session.id,
            sessionGeneration: session.generation,
            invalidationGeneration: session.invalidationGeneration,
            repositoryAuthority: session.capability.repositoryAuthority,
            catalogGeneration: session.registration.catalogGeneration,
            ingressGeneration: session.registration.ingressGeneration,
            phase: .scheduled,
            generation: nil,
            cursor: nil,
            lastProcessedCursor: nil,
            progress: .notStarted,
            inBatchProgress: nil,
            pageStartProcessedCandidateBaseline: nil,
            nextGraphChangeSequence: 0,
            pipelineScopes: [:],
            resources: .zero,
            pendingManifestMutationCount: 0,
            retryAttempt: 0,
            retry: nil,
            budget: nil,
            checkpoint: nil,
            task: nil,
            isQueuedForAdmission: false,
            isActiveBatch: false
        )
        incrementCounter(\.graphIndexRunsScheduled)
        emit(.graphIndexRunScheduled, rootEpoch: rootEpoch, graphIndexPhase: .scheduled)
        let task = Task(priority: .background) {
            await self.runGraphIndex(jobID: jobID, rootEpoch: rootEpoch)
        }
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else {
            task.cancel()
            return .superseded
        }
        job.task = task
        graphIndexJobs[rootEpoch] = job
        return .handedOff
    }

    func cancelGraphIndex(rootEpoch: WorkspaceCodemapRootEpoch) {
        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
    }

    func demand(_ demand: WorkspaceCodemapBindingDemand) async -> WorkspaceCodemapBindingDemandResult {
        let requestID = UUID()
        let cancellation = DemandCancellationState()
        return await withTaskCancellationHandler {
            if Task.isCancelled || cancellation.isCancelled {
                return .cancelled
            }
            return await withCheckedContinuation { continuation in
                admitOrQueue(
                    requestID: requestID,
                    demand: demand,
                    cancellation: cancellation,
                    continuation: continuation
                )
            }
        } onCancel: {
            cancellation.cancel()
            Task {
                if await self.cancelRequest(requestID: requestID) {
                    await self.recordCancellationTelemetry(1)
                }
            }
        }
    }

    /// Resolves an already-published clean Git artifact without demand admission, manifest
    /// adoption, source classification, source-authority capture, or worktree materialization.
    /// Targeted invalidation removes the path graphIndex or changes its generation, so the
    /// durable record remains authoritative only while the captured path identity is current.
    func lookupPublishedArtifact(
        _ request: WorkspaceCodemapPublishedArtifactLookupRequest
    ) async -> WorkspaceCodemapPublishedArtifactLookupResult {
        guard !Task.isCancelled else { return .cancelled }
        let contextResult = publishedArtifactLookupContext(request)
        let context: PublishedArtifactLookupContext
        switch contextResult {
        case let .success(value):
            context = value
        case let .failure(reason):
            recordPublishedArtifactLookupMiss(request: request, reason: reason)
            return .miss(reason)
        }

        let resolution: CodeMapArtifactCoordinatorResolution
        let source: WorkspaceCodemapPublishedArtifactLookupSource
        do {
            switch try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                ownerID: request.ownerID,
                priority: .demand,
                target: .artifactKey(context.record.artifactKey)
            )) {
            case let .ready(value):
                resolution = value
                source = .graphIndexCAS
            case .miss:
                switch try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                    ownerID: request.ownerID,
                    priority: .demand,
                    target: .locator(context.record.locatorIdentity)
                )) {
                case let .ready(value):
                    guard value.handle.key == context.record.artifactKey else {
                        recordPublishedArtifactLookupMiss(request: request, reason: .currentnessMismatch)
                        return .miss(.currentnessMismatch)
                    }
                    resolution = value
                    source = .locatorCAS
                case .miss:
                    recordPublishedArtifactLookupMiss(request: request, reason: .artifactMissing)
                    return .miss(.artifactMissing)
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            recordPublishedArtifactLookupMiss(request: request, reason: .artifactMissing)
            return .miss(.artifactMissing)
        }

        guard !Task.isCancelled else { return .cancelled }
        #if DEBUG
            await hooks.afterPublishedArtifactLookupBeforeCurrentnessValidation(context.rootEpoch)
        #endif
        guard publishedArtifactLookupIsCurrent(context, request: request),
              (try? VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                  identity: context.record.locatorIdentity,
                  artifactKey: context.record.artifactKey,
                  casHandle: resolution.handle
              )) != nil,
              publishedArtifactOutcomeMatches(
                  resolution.handle.outcome,
                  manifestOutcome: context.record.outcome
              )
        else {
            #if DEBUG
                incrementCounter(\.publishedArtifactPostLookupCurrentnessRejections)
                emit(
                    .publishedArtifactPostLookupCurrentnessRejection,
                    rootEpoch: context.rootEpoch,
                    artifact: resolution.handle.key,
                    publishedArtifactLookupSource: source
                )
            #endif
            recordPublishedArtifactLookupMiss(request: request, reason: .currentnessMismatch)
            return .miss(.currentnessMismatch)
        }

        switch source {
        case .graphIndexCAS:
            incrementCounter(\.publishedArtifactGraphIndexCASHits)
        case .locatorCAS:
            incrementCounter(\.publishedArtifactLocatorCASHits)
        }
        emit(
            .publishedArtifactLookupHit,
            rootEpoch: context.rootEpoch,
            artifact: resolution.handle.key,
            publishedArtifactLookupSource: source
        )
        return .hit(WorkspaceCodemapPublishedArtifactLookupHit(
            handle: resolution.handle,
            source: source
        ))
    }

    @discardableResult
    func cancel(owner: WorkspaceCodemapLiveDemandOwner) async -> Int {
        let requestIDs = queuedRequests.values
            .filter { $0.demand.owner == owner }
            .map(\.id) + activeRequests.values.filter { $0.publicOwner == owner }.map(\.id)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        return cancellationBatch.cancelledRequestCount
    }

    @discardableResult
    private func cancelRequest(requestID: UUID) async -> Bool {
        let cancellationBatch = synchronouslyCancelRequests([requestID])
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        return cancellationBatch.cancelledRequestCount == 1
    }

    func invalidateModified(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: standardizedRelativePaths, reason: .modified)
    }

    func invalidateDeleted(
        rootEpoch: WorkspaceCodemapRootEpoch,
        standardizedRelativePaths: Set<String>
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: standardizedRelativePaths, reason: .deleted)
    }

    func invalidateRenamed(
        rootEpoch: WorkspaceCodemapRootEpoch,
        from oldPath: String,
        to newPath: String
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidatePaths(rootEpoch, paths: [oldPath, newPath], reason: .renamed)
    }

    func invalidateWatcherGap(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        guard case var .eligible(session)? = roots[rootEpoch],
              session.invalidationGeneration < UInt64.max,
              let graph = selectionGraphsByRootEpoch[rootEpoch]
        else {
            return await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .watcherGap)
        }
        let reconciliation = await graph.beginWatcherGapReconciliation()
        if case .coalesced = reconciliation {
            _ = await overlay.beginGraphReconciliation(rootEpoch: rootEpoch)
            emit(.invalidation, rootEpoch: rootEpoch, invalidationReason: .watcherGap)
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        if case .revoked = reconciliation {
            return await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .watcherGap)
        }

        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        session.invalidationGeneration += 1
        roots[rootEpoch] = .eligible(session)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)

        let requestIDs = activeRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        let queuedIDs = queuedRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs + queuedIDs)
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)

        guard await overlay.beginGraphReconciliation(rootEpoch: rootEpoch),
              scheduleGraphIndex(rootEpoch: rootEpoch) == .handedOff
        else {
            _ = await graph.recordWatcherGapReconciliationFailure()
            return await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .watcherGap)
        }
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        emit(.invalidation, rootEpoch: rootEpoch, invalidationReason: .watcherGap)
        return WorkspaceCodemapBindingInvalidationResult(
            revokedOverlayCount: 0,
            cancelledRequestCount: cancellationBatch.cancelledRequestCount,
            manifestWriteFailed: false
        )
    }

    func invalidateCheckout(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .checkoutChanged)
    }

    func invalidateCatalog(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .catalogChanged)
    }

    func invalidateRepositoryAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .authorityChanged)
    }

    func unloadRoot(rootEpoch: WorkspaceCodemapRootEpoch) async {
        if case .registering? = roots[rootEpoch] {
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.release(rootEpoch: rootEpoch)
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.rootUnload, rootEpoch: rootEpoch)
            return
        }
        let manifestWriterSession: CodeMapRootManifestWriterSessionToken? = if case let .eligible(session)? =
            roots[rootEpoch]
        {
            session.manifestWriterSession
        } else {
            nil
        }
        let requestIDs = queuedRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id) +
            activeRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        let graphIndexTasks = drainingGraphIndexTasks.compactMap { jobID, task in
            drainingGraphIndexRootEpochs[jobID] == rootEpoch ? task : nil
        }
        roots.removeValue(forKey: rootEpoch)
        detachManifestWriters(rootEpoch: rootEpoch)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
        _ = await overlay.unregister(rootEpoch: rootEpoch)
        adoptionReservations = adoptionReservations.filter { $0.key.rootEpoch != rootEpoch }
        retainedAdoptions = retainedAdoptions.filter { $0.key.rootEpoch != rootEpoch }
        pruneAdmissionHistory()
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        for task in graphIndexTasks {
            await task.value
        }
        if let manifestWriterSession {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
        }
        await capabilityService.release(rootEpoch: rootEpoch)
        emit(.rootUnload, rootEpoch: rootEpoch)
    }

    func shutdown() async {
        if shutdownComplete {
            return
        }
        if isShuttingDown {
            await waitForShutdownCompletion()
            return
        }

        isShuttingDown = true
        #if DEBUG
            for hold in debugGraphIndexAdmissionHolds.values {
                hold.expiryTask.cancel()
            }
            debugGraphIndexAdmissionHolds.removeAll()
            debugGraphIndexAdmissionEnqueuedAtNanoseconds.removeAll()
        #endif
        let rootEpochs = Array(roots.keys)
        for rootEpoch in rootEpochs {
            _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        }
        let graphIndexTasks = Array(drainingGraphIndexTasks.values)
        let manifestWriterSessions = roots.values.compactMap { record -> CodeMapRootManifestWriterSessionToken? in
            guard case let .eligible(session) = record else { return nil }
            return session.manifestWriterSession
        }
        let requestIDs = Array(queuedRequests.keys) + Array(activeRequests.keys)
        roots.removeAll()
        let writerTasks = cancelAllManifestWriters()
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        adoptionReservations.removeAll()
        retainedAdoptions.removeAll()
        let adoptionOperations = Array(manifestAdoptionOperations.values)
        manifestAdoptionOperations.removeAll()
        for operation in adoptionOperations {
            operation.task.cancel()
            drainingManifestAdoptionTasks[operation.attempt.operationID] = operation.task
            for waiter in operation.waiters.values {
                waiter.resume()
            }
        }
        let adoptionTasks = Array(drainingManifestAdoptionTasks.values)
        rootLastAdmission.removeAll()
        ownerLastAdmission.removeAll()
        consecutiveDemandAdmissions = 0
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        let requestTasks = Array(drainingRequestTasks.values)

        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        for rootEpoch in rootEpochs {
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
        }
        for task in requestTasks {
            await task.value
        }
        for task in writerTasks {
            await task.value
        }
        for task in adoptionTasks {
            _ = await task.value
        }
        for task in graphIndexTasks {
            await task.value
        }
        for writerSession in manifestWriterSessions {
            await runtime.manifestStore.endManifestWriterSession(writerSession)
        }
        for rootEpoch in rootEpochs {
            await capabilityService.release(rootEpoch: rootEpoch)
        }
        await waitForRegistrationOperationsToDrain()
        await capabilityService.drain()

        adoptionReservations.removeAll()
        retainedAdoptions.removeAll()
        drainingManifestAdoptionTasks.removeAll()
        drainingRequestTasks.removeAll()
        drainingGraphIndexTasks.removeAll()
        drainingGraphIndexResources.removeAll()
        drainingGraphIndexRootEpochs.removeAll()
        graphIndexAdmissionQueue.removeAll()
        activeGraphIndexJobIDs.removeAll()
        graphIndexRootLastAdmission.removeAll()
        pruneAdmissionHistory()
        shutdownComplete = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func snapshot(rootEpoch: WorkspaceCodemapRootEpoch) async -> WorkspaceCodemapLiveRootSnapshot? {
        await overlay.snapshot(rootEpoch: rootEpoch)
    }

    func freeze(rootEpoch: WorkspaceCodemapRootEpoch) async -> WorkspaceCodemapLiveOverlayBundle? {
        await overlay.freeze(rootEpoch: rootEpoch)
    }

    func freezeReadyArtifact(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        requestGeneration: UInt64
    ) async -> WorkspaceCodemapLiveOverlayBundle? {
        await overlay.freezeReadyArtifact(
            rootEpoch: rootEpoch,
            fileID: fileID,
            requestGeneration: requestGeneration
        )
    }

    @discardableResult
    func revokeReadyArtifact(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        requestGeneration: UInt64
    ) async -> Bool {
        await overlay.revokeReadyArtifact(
            rootEpoch: rootEpoch,
            fileID: fileID,
            requestGeneration: requestGeneration
        )
    }

    func accounting() -> WorkspaceCodemapBindingEngineAccounting {
        var eligible = 0
        var unavailable = 0
        var active = 0
        var owners = Set<WorkspaceCodemapLiveDemandOwner>()
        var dirty = 0
        for record in roots.values {
            switch record {
            case .registering:
                continue
            case .unavailable:
                unavailable += 1
            case let .eligible(session):
                eligible += 1
                dirty += session.pipelines.values.count(where: {
                    $0.manifestState == .dirtyRetryRequired
                })
            }
        }
        active = activeRequests.count
        owners.formUnion(activeRequests.values.map(\.publicOwner))
        owners.formUnion(queuedRequests.values.map(\.demand.owner))
        let reservedSourceBytes = activeRequests.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let adoptionUsage = adoptionLeaseUsage()
        let graphIndexRoots: [WorkspaceCodemapBindingEngineGraphIndexRootAccounting] = graphIndexJobs.values.sorted {
            rootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
        }.map { job -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting in
            let drainingResources = drainingGraphIndexResources.reduce(
                WorkspaceCodemapGraphIndexResourceAccounting.zero
            ) { partial, element in
                guard drainingGraphIndexRootEpochs[element.key] == job.rootEpoch else { return partial }
                switch partial.adding(element.value) {
                case let .success(value):
                    return value
                case .failure:
                    return WorkspaceCodemapGraphIndexResourceAccounting(
                        retainedPathBytes: .max,
                        retainedSourceBytes: .max,
                        retainedGraphIndexBytes: .max,
                        stagedGraphBytes: .max,
                        residentGraphBytes: .max,
                        queuedManifestMutationBytes: .max
                    )
                }
            }
            let rootResources = switch job.resources.adding(drainingResources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapGraphIndexResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedGraphIndexBytes: .max,
                    stagedGraphBytes: .max,
                    residentGraphBytes: .max,
                    queuedManifestMutationBytes: .max
                )
            }
            return WorkspaceCodemapBindingEngineGraphIndexRootAccounting(
                rootEpoch: job.rootEpoch,
                phase: job.phase,
                progress: job.progress,
                queuedBatchCount: job.isQueuedForAdmission ? 1 : 0,
                activeBatchCount: activeGraphIndexBatchCount(rootEpoch: job.rootEpoch),
                drainingBatchCount: drainingGraphIndexRootEpochs.values.count(where: {
                    $0 == job.rootEpoch
                }),
                resources: rootResources,
                retry: job.retry,
                budget: job.budget
            )
        }
        let liveGraphIndexResources = graphIndexJobs.values.reduce(
            WorkspaceCodemapGraphIndexResourceAccounting.zero
        ) { partial, job in
            switch partial.adding(job.resources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapGraphIndexResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedGraphIndexBytes: .max,
                    stagedGraphBytes: .max,
                    residentGraphBytes: .max,
                    queuedManifestMutationBytes: .max
                )
            }
        }
        let graphIndexResources = drainingGraphIndexResources.values.reduce(
            liveGraphIndexResources
        ) { partial, resources in
            switch partial.adding(resources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapGraphIndexResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedGraphIndexBytes: .max,
                    stagedGraphBytes: .max,
                    residentGraphBytes: .max,
                    queuedManifestMutationBytes: .max
                )
            }
        }
        return WorkspaceCodemapBindingEngineAccounting(
            rootCount: roots.count,
            eligibleRootCount: eligible,
            unavailableRootCount: unavailable,
            activeRequestCount: active,
            queuedRequestCount: queuedRequests.count,
            ownerCount: owners.count,
            reservedSourceByteCount: reservedSourceBytes,
            manifestAdoptionLeaseCount: adoptionUsage?.count ?? .max,
            manifestAdoptionLeaseByteCount: adoptionUsage?.bytes ?? .max,
            rootAdmissionHistoryCount: rootLastAdmission.count,
            ownerAdmissionHistoryCount: ownerLastAdmission.count,
            dirtyManifestCount: dirty,
            counters: counters,
            graphIndexJobCount: graphIndexJobs.count,
            suspendedGraphIndexJobCount: graphIndexJobs.values.count(where: {
                $0.phase == .suspendedBusy
            }),
            queuedGraphIndexBatchCount: graphIndexAdmissionQueue.count,
            activeGraphIndexBatchCount: activeGraphIndexJobIDs.count,
            drainingGraphIndexTaskCount: drainingGraphIndexTasks.count,
            graphIndexResources: graphIndexResources,
            graphIndexRoots: graphIndexRoots
        )
    }

    #if DEBUG
        func debugAcquireGraphIndexAdmissionHold(
            rootEpoch: WorkspaceCodemapRootEpoch,
            expiresAfterMilliseconds: UInt64
        ) -> (
            holdID: UUID,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        )? {
            guard !isShuttingDown, !shutdownComplete, roots[rootEpoch] != nil else { return nil }
            let holdID = UUID()
            let expiryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: expiresAfterMilliseconds * 1_000_000)
                guard !Task.isCancelled else { return }
                _ = await self?.debugReleaseGraphIndexAdmissionHold(
                    holdID,
                    rootEpoch: rootEpoch
                )
            }
            debugGraphIndexAdmissionHolds[holdID] = DebugGraphIndexAdmissionHold(
                rootEpoch: rootEpoch,
                expiryTask: expiryTask
            )
            let snapshot = debugGraphIndexAdmissionSnapshot(rootEpoch: rootEpoch)
            return (holdID, snapshot.metrics, snapshot.queueWaitMilliseconds)
        }

        func debugReleaseGraphIndexAdmissionHold(
            _ holdID: UUID,
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (
            released: Bool,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        ) {
            let owned = debugGraphIndexAdmissionHolds[holdID]
            let released = owned?.rootEpoch == rootEpoch
            if released, let hold = debugGraphIndexAdmissionHolds.removeValue(forKey: holdID) {
                hold.expiryTask.cancel()
                scheduleGraphIndexAdmissions()
            }
            let snapshot = debugGraphIndexAdmissionSnapshot(rootEpoch: rootEpoch)
            return (released, snapshot.metrics, snapshot.queueWaitMilliseconds)
        }

        func debugGraphIndexAdmissionSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        ) {
            let current = accounting()
            let queueWaitMilliseconds = debugGraphIndexQueueWaitMillisecondsByRootEpoch[
                rootEpoch
            ] ?? []
            return (
                [
                    "hold_count": UInt64(debugGraphIndexAdmissionHolds.values.count(where: {
                        $0.rootEpoch == rootEpoch
                    })),
                    "queue_wait_sample_ordinal":
                        debugGraphIndexQueueWaitSampleOrdinalByRootEpoch[rootEpoch] ?? 0,
                    "queued_graphIndex_batch_count": UInt64(current.queuedGraphIndexBatchCount),
                    "active_graphIndex_batch_count": UInt64(current.activeGraphIndexBatchCount),
                    "builds": current.counters.builds,
                    "materializations": current.counters.materializations,
                    "manifest_writes": current.counters.manifestWrites,
                    "manifest_write_batches": current.counters.manifestWriteBatches,
                    "manifest_write_items": current.counters.manifestWriteItems,
                    "manifest_write_batch_bytes": current.counters.manifestWriteBatchBytes,
                    "manifest_write_coalesced_items": current.counters.manifestWriteCoalescedItems,
                    "manifest_writer_peak_queued_items": current.counters.manifestWriterPeakQueuedItems,
                    "failures": current.counters.failures,
                    "manifest_failures": current.counters.manifestFailures,
                    "busy_rejections": current.counters.busyRejections,
                    "graphIndex_batches_started": current.counters.graphIndexBatchesStarted,
                    "graphIndex_batches_queued": current.counters.graphIndexBatchesQueued,
                    "graph_index_runs_started": current.counters.graphIndexRunsStarted,
                    "graphIndex_changes_published": current.counters.graphIndexChangesPublished,
                    "graphIndex_catalog_pages": current.counters.graphIndexCatalogPages,
                    "graphIndex_catalog_candidates": current.counters.graphIndexCatalogCandidates,
                    "graphIndex_budget_rejections": current.counters.graphIndexBudgetRejections,
                    "retained_path_bytes": current.graphIndexResources.retainedPathBytes,
                    "retained_source_bytes": current.graphIndexResources.retainedSourceBytes,
                    "retained_graphIndex_bytes": current.graphIndexResources.retainedGraphIndexBytes,
                    "staged_graph_bytes": current.graphIndexResources.stagedGraphBytes,
                    "resident_graph_bytes": current.graphIndexResources.residentGraphBytes,
                    "queued_manifest_mutation_bytes": current.graphIndexResources.queuedManifestMutationBytes,
                    "limit_retained_path_bytes":
                        policy.maximumGraphIndexCatalogPagePathByteCount *
                        UInt64(policy.maximumActiveGraphIndexBatchCount),
                    "limit_retained_source_bytes": policy.maximumRetainedSourceByteCount,
                    "limit_retained_graphIndex_bytes": policy.maximumRetainedGraphIndexByteCount,
                    "limit_staged_graph_bytes": policy.maximumStagedGraphIndexGraphByteCount,
                    "limit_resident_graph_bytes": WorkspaceCodemapSelectionGraphSizePolicy.initial.maxBytes,
                    "limit_queued_manifest_mutation_bytes":
                        policy.maximumQueuedGraphIndexManifestMutationByteCount
                ],
                queueWaitMilliseconds
            )
        }
    #endif

    // MARK: - GraphIndex build

    private func runGraphIndex(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async {
        defer { finishGraphIndexWorker(jobID: jobID, rootEpoch: rootEpoch) }
        guard updateGraphIndexPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .waitingForAdmission) else {
            return
        }
        incrementCounter(\.graphIndexRunsStarted)
        emit(.graphIndexRunStarted, rootEpoch: rootEpoch, graphIndexPhase: .waitingForAdmission)

        while !Task.isCancelled {
            guard await awaitGraphIndexAdmission(jobID: jobID, rootEpoch: rootEpoch) else { return }
            let result = await processGraphIndexBatch(jobID: jobID, rootEpoch: rootEpoch)
            releaseGraphIndexAdmission(jobID: jobID, rootEpoch: rootEpoch)
            switch result {
            case .checkpointed:
                guard updateGraphIndexPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else { return }
            case .restartGeneration:
                guard resetGraphIndexForLatestGeneration(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    recordSupersession: true
                ) else {
                    return
                }
            case .restartPage:
                guard resetGraphIndexForLatestGeneration(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    recordSupersession: false
                ), await waitForGraphIndexRetry(jobID: jobID, rootEpoch: rootEpoch),
                updateGraphIndexPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else {
                    return
                }
            case .complete, .budgetLimited, .cancelled, .superseded:
                return
            case .retry:
                guard await waitForGraphIndexRetry(jobID: jobID, rootEpoch: rootEpoch) else {
                    return
                }
                guard updateGraphIndexPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else { return }
            }
        }
    }

    private func awaitGraphIndexAdmission(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        guard let job = graphIndexJobs[rootEpoch], job.id == jobID, graphIndexJobIsCurrent(job) else {
            return false
        }
        if job.isActiveBatch {
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var current = graphIndexJobs[rootEpoch],
                      current.id == jobID,
                      graphIndexJobIsCurrent(current)
                else {
                    continuation.resume(returning: false)
                    return
                }
                if current.isQueuedForAdmission {
                    continuation.resume(returning: false)
                    return
                }
                if nextGraphIndexQueueOrdinal == .max {
                    renumberGraphIndexAdmissionQueue()
                }
                let ordinal = nextGraphIndexQueueOrdinal
                nextGraphIndexQueueOrdinal = addingChecked(nextGraphIndexQueueOrdinal, 1) ?? .max
                current.isQueuedForAdmission = true
                current.phase = .waitingForAdmission
                graphIndexJobs[rootEpoch] = current
                graphIndexAdmissionQueue.append(GraphIndexAdmissionWaiter(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    enqueueOrdinal: ordinal,
                    rootOvertakeRecorded: false,
                    explicitOvertakeRecorded: false,
                    continuation: continuation
                ))
                #if DEBUG
                    debugGraphIndexAdmissionEnqueuedAtNanoseconds[jobID] = DispatchTime.now().uptimeNanoseconds
                #endif
                incrementCounter(\.graphIndexBatchesQueued)
                emit(.graphIndexBatchQueued, rootEpoch: rootEpoch, graphIndexPhase: .waitingForAdmission)
                scheduleGraphIndexAdmissions()
            }
        } onCancel: {
            Task { await self.cancelGraphIndexAdmission(jobID: jobID) }
        }
    }

    private func scheduleGraphIndexAdmissions() {
        guard !isShuttingDown, !graphIndexAdmissionQueue.isEmpty else { return }
        let demandForeground = activeRequests.values.contains { $0.demand.priority == .demand } ||
            queuedRequests.values.contains { $0.demand.priority == .demand }
        let explicitForeground = activeRequests.values.contains { $0.demand.priority == .explicit } ||
            queuedRequests.values.contains { $0.demand.priority == .explicit }
        if demandForeground || explicitForeground {
            for index in graphIndexAdmissionQueue.indices {
                let rootEpoch = graphIndexAdmissionQueue[index].rootEpoch
                if demandForeground, !graphIndexAdmissionQueue[index].rootOvertakeRecorded {
                    graphIndexAdmissionQueue[index].rootOvertakeRecorded = true
                    incrementCounter(\.graphIndexRootOvertakes)
                    emit(.graphIndexRootOvertake, rootEpoch: rootEpoch, graphIndexPhase: .waitingForAdmission)
                }
                if explicitForeground, !graphIndexAdmissionQueue[index].explicitOvertakeRecorded {
                    graphIndexAdmissionQueue[index].explicitOvertakeRecorded = true
                    incrementCounter(\.graphIndexExplicitOvertakes)
                    emit(.graphIndexExplicitOvertake, rootEpoch: rootEpoch, graphIndexPhase: .waitingForAdmission)
                }
            }
        }

        while activeGraphIndexJobIDs.count < policy.maximumActiveGraphIndexBatchCount,
              !graphIndexAdmissionQueue.isEmpty
        {
            let eligible = graphIndexAdmissionQueue.indices.filter { index in
                let waiter = graphIndexAdmissionQueue[index]
                #if DEBUG
                    if debugGraphIndexAdmissionHolds.values.contains(where: {
                        $0.rootEpoch == waiter.rootEpoch
                    }) {
                        return false
                    }
                #endif
                guard let job = graphIndexJobs[waiter.rootEpoch],
                      job.id == waiter.jobID,
                      graphIndexJobIsCurrent(job),
                      !job.isActiveBatch,
                      activeGraphIndexBatchCount(rootEpoch: waiter.rootEpoch) <
                      policy.maximumActiveGraphIndexBatchCountPerRoot
                else { return false }
                return activeGraphIndexJobIDs.count < policy.maximumActiveGraphIndexBatchCount
            }
            guard !eligible.isEmpty else { return }
            let selectedIndex = eligible.min { lhs, rhs in
                let left = graphIndexAdmissionQueue[lhs]
                let right = graphIndexAdmissionQueue[rhs]
                let leftAdmission = graphIndexRootLastAdmission[left.rootEpoch] ?? 0
                let rightAdmission = graphIndexRootLastAdmission[right.rootEpoch] ?? 0
                if leftAdmission != rightAdmission { return leftAdmission < rightAdmission }
                if left.enqueueOrdinal != right.enqueueOrdinal {
                    return left.enqueueOrdinal < right.enqueueOrdinal
                }
                return rootEpochPrecedes(left.rootEpoch, right.rootEpoch)
            }!
            let waiter = graphIndexAdmissionQueue.remove(at: selectedIndex)
            guard var job = graphIndexJobs[waiter.rootEpoch],
                  job.id == waiter.jobID,
                  graphIndexJobIsCurrent(job)
            else {
                #if DEBUG
                    debugGraphIndexAdmissionEnqueuedAtNanoseconds.removeValue(forKey: waiter.jobID)
                #endif
                waiter.continuation.resume(returning: false)
                continue
            }
            #if DEBUG
                if let enqueued = debugGraphIndexAdmissionEnqueuedAtNanoseconds.removeValue(
                    forKey: waiter.jobID
                ) {
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- enqueued
                    var samples = debugGraphIndexQueueWaitMillisecondsByRootEpoch[
                        waiter.rootEpoch,
                        default: []
                    ]
                    samples.append(elapsed / 1_000_000)
                    if samples.count > 1024 {
                        samples.removeFirst(
                            samples.count - 1024
                        )
                    }
                    debugGraphIndexQueueWaitMillisecondsByRootEpoch[waiter.rootEpoch] = samples
                    debugGraphIndexQueueWaitSampleOrdinalByRootEpoch[waiter.rootEpoch, default: 0] &+= 1
                }
            #endif
            job.isQueuedForAdmission = false
            job.isActiveBatch = true
            job.phase = .readingCatalogPage
            job.retry = nil
            graphIndexJobs[waiter.rootEpoch] = job
            activeGraphIndexJobIDs.insert(waiter.jobID)
            ensureAdmissionOrdinalCapacity()
            graphIndexRootLastAdmission[waiter.rootEpoch] = nextAdmissionOrdinal
            nextAdmissionOrdinal = addingChecked(nextAdmissionOrdinal, 1) ?? .max
            consecutiveDemandAdmissions = 0
            incrementCounter(\.graphIndexBatchesStarted)
            emit(.graphIndexBatchStarted, rootEpoch: waiter.rootEpoch, graphIndexPhase: .readingCatalogPage)
            waiter.continuation.resume(returning: true)
        }
    }

    private func activeGraphIndexBatchCount(rootEpoch: WorkspaceCodemapRootEpoch) -> Int {
        activeGraphIndexJobIDs.count { jobID in
            if drainingGraphIndexRootEpochs[jobID] == rootEpoch {
                return true
            }
            return graphIndexJobs[rootEpoch]?.id == jobID
        }
    }

    private func releaseGraphIndexAdmission(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        activeGraphIndexJobIDs.remove(jobID)
        job.isActiveBatch = false
        graphIndexJobs[rootEpoch] = job
        incrementCounter(\.graphIndexBatchesCompleted)
        emit(.graphIndexBatchCompleted, rootEpoch: rootEpoch)
        scheduleQueuedRequests()
        scheduleGraphIndexAdmissions()
    }

    private func cancelGraphIndexAdmission(jobID: UUID) {
        let detached = graphIndexAdmissionQueue.filter { $0.jobID == jobID }
        graphIndexAdmissionQueue.removeAll { $0.jobID == jobID }
        #if DEBUG
            debugGraphIndexAdmissionEnqueuedAtNanoseconds.removeValue(forKey: jobID)
        #endif
        for waiter in detached {
            waiter.continuation.resume(returning: false)
        }
    }

    private func renumberGraphIndexAdmissionQueue() {
        var ordinal: UInt64 = 1
        for index in graphIndexAdmissionQueue.indices {
            graphIndexAdmissionQueue[index].enqueueOrdinal = ordinal
            ordinal = addingChecked(ordinal, 1) ?? .max
        }
        nextGraphIndexQueueOrdinal = ordinal
    }

    private func processGraphIndexBatch(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> GraphIndexBatchResult {
        defer { clearGraphIndexBatchResources(jobID: jobID, rootEpoch: rootEpoch) }
        guard let initial = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) else {
            return .cancelled
        }
        let request = WorkspaceCodemapGraphIndexCatalogPageRequest(
            rootEpoch: rootEpoch,
            token: initial.generation?.catalogToken,
            cursor: initial.cursor,
            maximumEntryCount: min(
                policy.maximumGraphIndexCatalogPageEntryCount,
                policy.maximumGraphIndexBatchCandidateCount
            ),
            maximumPathByteCount: policy.maximumGraphIndexCatalogPagePathByteCount
        )
        let pageDisposition = await catalogClient.readGraphIndexCatalogPage(request)
        guard !Task.isCancelled,
              let afterPageRead = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
        else { return .cancelled }
        let page: WorkspaceCodemapGraphIndexCatalogPage
        switch pageDisposition {
        case let .page(value):
            page = value
        case .stale:
            supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        case let .unavailable(reason):
            if reason == .rootNotCurrent {
                supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            }
            return .retry
        }
        guard page.token.rootEpoch == rootEpoch,
              page.token.catalogGeneration == afterPageRead.catalogGeneration,
              page.token.ingressGeneration == afterPageRead.ingressGeneration,
              request.token == nil || request.token == page.token
        else {
            supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        }
        switch reserveGraphIndexResources(
            jobID: jobID,
            rootEpoch: rootEpoch,
            retainedPathBytes: page.pathByteCount
        ) {
        case .reserved:
            break
        case .retry:
            return .retry
        case let .budget(budget):
            finishGraphIndexForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
            return .budgetLimited
        }

        if afterPageRead.generation == nil {
            guard let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch),
                  var job = graphIndexJobs[rootEpoch],
                  job.id == jobID,
                  graphIndexJobIsCurrent(job),
                  overlaySnapshot.catalogGeneration == job.catalogGeneration,
                  overlaySnapshot.repositoryAuthority == job.repositoryAuthority
            else { return .retry }
            job.generation = WorkspaceCodemapGraphIndexGeneration(
                catalogToken: page.token,
                repositoryAuthority: job.repositoryAuthority,
                contributionGeneration: overlaySnapshot.contributionGeneration
            )
            graphIndexJobs[rootEpoch] = job
        }
        guard let generation = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)?.generation,
              generation.catalogToken == page.token
        else { return .superseded }
        incrementCounter(\.graphIndexCatalogPages)
        addToCounter(\.graphIndexCatalogCandidates, UInt64(page.entries.count))
        addToCounter(\.graphIndexCatalogPathBytes, page.pathByteCount)
        emit(.graphIndexCatalogPage, rootEpoch: rootEpoch, numericValue: 1, graphIndexPhase: .readingCatalogPage)
        emit(
            .graphIndexCatalogCandidates,
            rootEpoch: rootEpoch,
            numericValue: UInt64(page.entries.count),
            graphIndexPhase: .readingCatalogPage
        )
        emit(
            .graphIndexCatalogPathBytes,
            rootEpoch: rootEpoch,
            numericValue: page.pathByteCount,
            graphIndexPhase: .readingCatalogPage
        )
        guard updateGraphIndexPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .loadingEnvelopes) else {
            return .cancelled
        }
        var pipelineByFileID: [UUID: CodeMapPipelineIdentity] = [:]
        var candidatesByPipeline: [CodeMapPipelineIdentity: [WorkspaceCodemapGraphIndexCatalogCandidate]] = [:]
        do {
            for candidate in page.entries {
                let pipelineIdentity = try ensurePipeline(
                    rootEpoch: rootEpoch,
                    language: candidate.language
                )
                pipelineByFileID[candidate.identity.fileID] = pipelineIdentity
                candidatesByPipeline[pipelineIdentity, default: []].append(candidate)
            }
        } catch {
            return .retry
        }
        guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
            return .cancelled
        }
        let pendingSlots = page.entries.compactMap { candidate -> WorkspaceCodemapGraphSlot? in
            guard let pipelineIdentity = pipelineByFileID[candidate.identity.fileID] else { return nil }
            return try? WorkspaceCodemapGraphSlot.validated(
                rootEpoch: rootEpoch,
                identity: candidate.identity,
                requestGeneration: candidate.requestGeneration,
                pathGeneration: candidate.pathGeneration,
                pipelineIdentity: pipelineIdentity,
                state: .pending,
                diagnostics: WorkspaceCodemapGraphSlotDiagnostics(
                    contributionDigest: nil,
                    source: .graphIndex
                )
            ).get()
        }
        guard pendingSlots.count == page.entries.count,
              await publishGraphIndexSlots(
                  rootEpoch: rootEpoch,
                  catalogToken: page.token,
                  slots: pendingSlots,
                  enumerationFinished: page.isEnd && page.entries.isEmpty
              )
        else { return .superseded }

        var manifestRecordsByPipeline: [CodeMapPipelineIdentity: [String: CodeMapRootManifestRecord]] = [:]
        for (pipelineIdentity, candidates) in candidatesByPipeline {
            guard let records = await loadGraphIndexManifestRecords(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                candidatePaths: Set(candidates.compactMap { candidate in
                    guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil,
                          case let .eligible(session)? = roots[rootEpoch]
                    else { return nil }
                    return repositoryPath(
                        loadedRootRelativePath: candidate.identity.standardizedRelativePath,
                        prefix: session.capability.repositoryRelativeLoadedRootPrefix
                    )
                })
            ) else { return .cancelled }
            manifestRecordsByPipeline[pipelineIdentity] = records
        }

        var resolvedByFileID: [UUID: GraphIndexCandidateResolution] = [:]
        var misses: [WorkspaceCodemapGraphIndexCatalogCandidate] = []
        for candidate in page.entries {
            guard let pipelineIdentity = pipelineByFileID[candidate.identity.fileID],
                  case let .eligible(session)? = roots[rootEpoch],
                  session.id == afterPageRead.sessionID,
                  let repositoryRelativePath = repositoryPath(
                      loadedRootRelativePath: candidate.identity.standardizedRelativePath,
                      prefix: session.capability.repositoryRelativeLoadedRootPrefix
                  )
            else { return .superseded }
            let record = manifestRecordsByPipeline[pipelineIdentity]?[repositoryRelativePath]
            if let record,
               let entry = graphIndexEntry(
                   candidate: candidate,
                   pipelineIdentity: pipelineIdentity,
                   repositoryRelativePath: repositoryRelativePath,
                   record: record
               )
            {
                retainGraphIndexAutomaticSelectionRecord(
                    rootEpoch: rootEpoch,
                    pipelineIdentity: pipelineIdentity,
                    record: record
                )
                resolvedByFileID[candidate.identity.fileID] = .entry(entry, manifestRecord: nil)
            } else {
                misses.append(candidate)
            }
        }

        if !misses.isEmpty {
            guard updateGraphIndexPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .classifyingBatch),
                  case let .eligible(session)? = roots[rootEpoch]
            else { return .cancelled }
            incrementCounter(\.classifications)
            let classifications = await identityService.classify(
                workspaceRoot: session.registration.capabilityRequest.loadedRootURL,
                relativePaths: misses.map(\.identity.standardizedRelativePath)
            )
            guard !Task.isCancelled,
                  currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil
            else { return .cancelled }
            guard classifications.failure == nil,
                  classifications.classifications.count == misses.count
            else { return .retry }
            let classificationsByPath = Dictionary(
                uniqueKeysWithValues: classifications.classifications.map { ($0.relativePath, $0) }
            )
            guard updateGraphIndexPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .resolvingArtifacts) else {
                return .cancelled
            }
            let maximumConcurrentResolutions = min(
                misses.count,
                policy.maximumConcurrentMaterializationCountPerOwner
            )
            let indexedResolutions = await withTaskGroup(
                of: IndexedGraphIndexCandidateResolution.self,
                returning: [IndexedGraphIndexCandidateResolution].self
            ) { group in
                var nextIndex = 0
                var completed: [IndexedGraphIndexCandidateResolution] = []
                completed.reserveCapacity(misses.count)

                while nextIndex < maximumConcurrentResolutions {
                    let index = nextIndex
                    let candidate = misses[index]
                    nextIndex += 1
                    group.addTask {
                        guard let pipelineIdentity = pipelineByFileID[candidate.identity.fileID],
                              let classification = classificationsByPath[
                                  candidate.identity.standardizedRelativePath
                              ]
                        else {
                            return IndexedGraphIndexCandidateResolution(
                                index: index,
                                fileID: candidate.identity.fileID,
                                resolution: .transient
                            )
                        }
                        let resolution = await self.resolveGraphIndexCandidate(
                            jobID: jobID,
                            rootEpoch: rootEpoch,
                            candidate: candidate,
                            pipelineIdentity: pipelineIdentity,
                            classification: classification
                        )
                        return IndexedGraphIndexCandidateResolution(
                            index: index,
                            fileID: candidate.identity.fileID,
                            resolution: resolution
                        )
                    }
                }

                while let result = await group.next() {
                    completed.append(result)
                    guard nextIndex < misses.count else { continue }
                    let index = nextIndex
                    let candidate = misses[index]
                    nextIndex += 1
                    group.addTask {
                        guard let pipelineIdentity = pipelineByFileID[candidate.identity.fileID],
                              let classification = classificationsByPath[
                                  candidate.identity.standardizedRelativePath
                              ]
                        else {
                            return IndexedGraphIndexCandidateResolution(
                                index: index,
                                fileID: candidate.identity.fileID,
                                resolution: .transient
                            )
                        }
                        let resolution = await self.resolveGraphIndexCandidate(
                            jobID: jobID,
                            rootEpoch: rootEpoch,
                            candidate: candidate,
                            pipelineIdentity: pipelineIdentity,
                            classification: classification
                        )
                        return IndexedGraphIndexCandidateResolution(
                            index: index,
                            fileID: candidate.identity.fileID,
                            resolution: resolution
                        )
                    }
                }
                return completed.sorted { $0.index < $1.index }
            }
            guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                return .cancelled
            }
            for result in indexedResolutions {
                switch result.resolution {
                case let .entry(entry, manifestRecord):
                    resolvedByFileID[result.fileID] = .entry(
                        entry,
                        manifestRecord: manifestRecord
                    )
                case .transient:
                    return .retry
                case let .budget(budget):
                    finishGraphIndexForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
                    return .budgetLimited
                }
            }
        }

        let orderedResolutions = page.entries.compactMap { candidate in
            resolvedByFileID[candidate.identity.fileID]
        }
        guard orderedResolutions.count == page.entries.count else { return .retry }
        let entries = orderedResolutions.compactMap { resolution -> WorkspaceCodemapGraphIndexEntry? in
            guard case let .entry(entry, _) = resolution else { return nil }
            return entry
        }
        guard entries.count == page.entries.count else { return .retry }

        if page.isEnd {
            let tokenDisposition = await catalogClient.revalidateGraphIndexCatalogToken(
                rootEpoch,
                page.token
            )
            guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                return .cancelled
            }
            switch tokenDisposition {
            case .current:
                break
            case .stale:
                supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            case .unavailable:
                return .retry
            }
        }

        let pageLastCursor = page.entries.last.map {
            WorkspaceCodemapGraphIndexCatalogCursor(
                standardizedRelativePath: $0.identity.standardizedRelativePath,
                fileID: $0.identity.fileID
            )
        } ?? currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)?.lastProcessedCursor
        let catalogCompletion: WorkspaceCodemapGraphIndexCatalogCompletion? = page.isEnd
            ? WorkspaceCodemapGraphIndexCatalogCompletion(
                token: page.token,
                finalCursor: pageLastCursor,
                supportedCandidateCount: page.supportedCandidateCountThroughPage
            )
            : nil

        let manifestRecords = orderedResolutions.compactMap { resolution -> CodeMapRootManifestRecord? in
            guard case let .entry(_, record) = resolution else { return nil }
            return record
        }
        let manifestFileIDsByRelativePath = Dictionary(uniqueKeysWithValues: orderedResolutions.compactMap {
            resolution -> (String, UUID)? in
            guard case let .entry(entry, record?) = resolution else { return nil }
            return (record.repositoryRelativePath, entry.identity.fileID)
        })
        var markerReadinessUnavailableFileIDs = Set<UUID>()
        if !manifestRecords.isEmpty {
            guard updateGraphIndexPhase(
                jobID: jobID,
                rootEpoch: rootEpoch,
                phase: .writingManifestCheckpoint
            ) else { return .cancelled }
            let grouped = Dictionary(grouping: manifestRecords, by: { $0.artifactKey.pipelineIdentity })
            for (pipelineIdentity, records) in grouped {
                let pipelineFileIDs = Set(records.compactMap {
                    manifestFileIDsByRelativePath[$0.repositoryRelativePath]
                })
                for mutations in boundedManifestMutationBatches(records.map(ManifestMutation.upsert)) {
                    let submission = await submitManifestMutations(
                        rootEpoch: rootEpoch,
                        pipelineIdentity: pipelineIdentity,
                        mutations: mutations,
                        proof: .graphIndex(jobID: jobID, generation: generation),
                        retainRecordsInMemory: true
                    )
                    guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                        return .cancelled
                    }
                    switch submission {
                    case .persisted:
                        markerReadinessUnavailableFileIDs.subtract(pipelineFileIDs)
                    case .durabilityFailure:
                        markerReadinessUnavailableFileIDs.formUnion(mutations.compactMap {
                            manifestFileIDsByRelativePath[$0.repositoryRelativePath]
                        })
                    case .retry:
                        return .retry
                    case let .budget(budget):
                        finishGraphIndexForBudget(
                            jobID: jobID,
                            rootEpoch: rootEpoch,
                            budget: budget
                        )
                        return .budgetLimited
                    }
                }
            }
        }

        let changeGroups: [GraphIndexChangeGroup]
        switch graphIndexChangeGroups(entries) {
        case let .groups(groups):
            changeGroups = groups
        case let .budget(budget):
            finishGraphIndexForBudget(
                jobID: jobID,
                rootEpoch: rootEpoch,
                budget: budget
            )
            return .budgetLimited
        }
        let retainedGraphIndexBytes = changeGroups.reduce(0) {
            addingSaturating($0, $1.byteCount)
        }
        switch reserveGraphIndexResources(
            jobID: jobID,
            rootEpoch: rootEpoch,
            retainedGraphIndexBytes: retainedGraphIndexBytes
        ) {
        case .reserved:
            break
        case .retry:
            return .retry
        case let .budget(budget):
            finishGraphIndexForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
            return .budgetLimited
        }

        var progress = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)?.progress ?? .notStarted
        if changeGroups.isEmpty {
            let delta = WorkspaceCodemapGraphIndexProgressDelta(
                counts: .zero,
                catalogPageCount: 1,
                catalogPathByteCount: page.pathByteCount,
                publishedGraphChangeCount: 0,
                publishedGraphChangeByteCount: 0
            )
            let advance = progress.advancing(
                to: .checkpointed,
                by: delta,
                catalogCompletion: catalogCompletion
            )
            guard case let .success(advanced) = advance else {
                let budget = switch advance {
                case let .failure(error): graphIndexOverflowBudget(error)
                case .success: preconditionFailure("Expected graphIndex accounting failure.")
                }
                finishGraphIndexForBudget(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    budget: budget
                )
                return .budgetLimited
            }
            progress = advanced
            updateGraphIndexProgress(jobID: jobID, rootEpoch: rootEpoch, progress: progress)
        } else {
            var publishedChangeThisPage = false
            for (index, group) in changeGroups.enumerated() {
                guard var job = graphIndexJobs[rootEpoch], job.id == jobID,
                      job.nextGraphChangeSequence < UInt64.max
                else {
                    finishGraphIndexForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: WorkspaceCodemapGraphIndexBudget(
                            dimension: .catalogEntries,
                            attempted: .max,
                            limit: .max - 1
                        )
                    )
                    return .budgetLimited
                }
                let counts = graphIndexCounts(group.entries)
                let isLast = index == changeGroups.count - 1
                let delta = WorkspaceCodemapGraphIndexProgressDelta(
                    counts: counts,
                    catalogPageCount: isLast ? 1 : 0,
                    catalogPathByteCount: isLast ? page.pathByteCount : 0,
                    publishedGraphChangeCount: 1,
                    publishedGraphChangeByteCount: group.byteCount
                )
                guard case let .success(advanced) = progress.advancing(
                    to: .publishingGraphChanges,
                    by: delta,
                    catalogCompletion: isLast ? catalogCompletion : nil
                ) else {
                    return publishedChangeThisPage ? .restartPage : .retry
                }
                switch reserveGraphIndexResources(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    stagedGraphBytes: group.byteCount
                ) {
                case .reserved:
                    break
                case .retry:
                    return publishedChangeThisPage ? .restartPage : .retry
                case let .budget(budget):
                    finishGraphIndexForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: budget
                    )
                    return .budgetLimited
                }
                let disposition = await publishGraphIndexEntries(
                    group.entries,
                    progress: advanced,
                    enumerationFinished: false,
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    markerReadinessUnavailableFileIDs: markerReadinessUnavailableFileIDs
                )
                releaseStagedGraphIndexBytes(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    byteCount: group.byteCount
                )
                guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                    return .cancelled
                }
                switch disposition {
                case let .accepted(accepted), let .exactDuplicate(accepted):
                    progress = accepted
                    publishedChangeThisPage = true
                    job = graphIndexJobs[rootEpoch]!
                    job.progress = accepted
                    job.nextGraphChangeSequence += 1
                    job.retry = nil
                    graphIndexJobs[rootEpoch] = job
                    incrementCounter(\.graphIndexChangesPublished)
                    addToCounter(\.graphIndexChangeBytes, group.byteCount)
                    if job.nextGraphChangeSequence == 1 {
                        incrementCounter(\.graphIndexFirstChanges)
                        emit(
                            .graphIndexFirstChange,
                            rootEpoch: rootEpoch,
                            numericValue: group.byteCount,
                            graphIndexPhase: .publishingGraphChanges
                        )
                    }
                    emit(
                        .graphIndexChangePublished,
                        rootEpoch: rootEpoch,
                        numericValue: group.byteCount,
                        graphIndexPhase: .publishingGraphChanges
                    )
                case .stale, .superseded:
                    switch await graphIndexPublicationStalenessResult(
                        jobID: jobID,
                        rootEpoch: rootEpoch
                    ) {
                    case .restartGeneration:
                        return .restartGeneration
                    case .retry:
                        return publishedChangeThisPage ? .restartPage : .retry
                    case .terminal:
                        supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
                        return .superseded
                    }
                case let .budget(dimension, attempted, limit):
                    finishGraphIndexForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: WorkspaceCodemapGraphIndexBudget(
                            dimension: dimension,
                            attempted: attempted,
                            limit: limit
                        )
                    )
                    return .budgetLimited
                case .unavailable:
                    return publishedChangeThisPage ? .restartPage : .retry
                case .busy:
                    return .retry
                }
            }
        }

        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return .cancelled }
        // Change progress already includes this page. For an empty page it was advanced above.
        guard job.progress.counts.supportedCandidateCount == page.supportedCandidateCountThroughPage
        else {
            supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        }
        job.cursor = page.nextCursor
        job.lastProcessedCursor = pageLastCursor
        progress = graphIndexProgress(progress, phase: .checkpointed)
        job.phase = .checkpointed
        job.progress = progress
        job.inBatchProgress = nil
        job.pageStartProcessedCandidateBaseline = nil
        job.retryAttempt = 0
        job.retry = nil
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job

        guard page.isEnd else { return .checkpointed }
        guard let completion = catalogCompletion,
              progress.catalogCompletion == completion
        else { return .retry }
        let finalDisposition = await publishGraphIndexEntries(
            [],
            progress: progress,
            enumerationFinished: true,
            jobID: jobID,
            rootEpoch: rootEpoch
        )
        guard var completedJob = graphIndexJobs[rootEpoch], completedJob.id == jobID else {
            return .cancelled
        }
        switch finalDisposition {
        case let .accepted(accepted), let .exactDuplicate(accepted):
            completedJob.phase = .complete
            completedJob.progress = accepted
            completedJob.inBatchProgress = nil
            completedJob.pageStartProcessedCandidateBaseline = nil
            completedJob.retry = nil
            completedJob.checkpoint = makeGraphIndexCheckpoint(completedJob)
            graphIndexJobs[rootEpoch] = completedJob
            incrementCounter(\.graphIndexCoveragesCompleted)
            emit(.graphIndexCoverageComplete, rootEpoch: rootEpoch, graphIndexPhase: .complete)
            return .complete
        case .stale, .superseded:
            switch await graphIndexPublicationStalenessResult(
                jobID: jobID,
                rootEpoch: rootEpoch
            ) {
            case .restartGeneration:
                return .restartGeneration
            case .retry:
                return .restartPage
            case .terminal:
                supersedeGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            }
        case let .budget(dimension, attempted, limit):
            finishGraphIndexForBudget(
                jobID: jobID,
                rootEpoch: rootEpoch,
                budget: WorkspaceCodemapGraphIndexBudget(
                    dimension: dimension,
                    attempted: attempted,
                    limit: limit
                )
            )
            return .budgetLimited
        case .unavailable:
            return .retry
        case .busy:
            return .retry
        }
    }

    private func loadGraphIndexManifestRecords(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        candidatePaths: Set<String>
    ) async -> [String: CodeMapRootManifestRecord]? {
        guard let job = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              case let .eligible(session)? = roots[rootEpoch],
              let pipeline = session.pipelines[pipelineIdentity]
        else { return nil }
        incrementCounter(\.manifestLoads)
        let load: CodeMapRootManifestLoadResult
        do {
            load = try await runtime.manifestStore.loadCurrentManifest(
                namespace: pipeline.namespace,
                currentAuthority: pipeline.authority
            )
        } catch {
            guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil else { return nil }
            incrementCounter(\.graphIndexEnvelopeInvalid)
            emit(.graphIndexEnvelopeInvalid, rootEpoch: rootEpoch, graphIndexPhase: .loadingEnvelopes)
            return [:]
        }
        guard currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch) != nil,
              job.sessionID == session.id
        else { return nil }
        switch load {
        case .miss:
            emit(.manifestLoadMiss, rootEpoch: rootEpoch)
            updateGraphIndexPipelineScope(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                manifestGeneration: nil
            )
            return [:]
        case .stale:
            incrementCounter(\.graphIndexEnvelopeStale)
            emit(.graphIndexEnvelopeStale, rootEpoch: rootEpoch, graphIndexPhase: .loadingEnvelopes)
            updateGraphIndexPipelineScope(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                manifestGeneration: nil
            )
            return [:]
        case let .hit(snapshot):
            guard snapshot.namespace == pipeline.namespace,
                  snapshot.authority == pipeline.authority
            else {
                incrementCounter(\.graphIndexEnvelopeStale)
                return [:]
            }
            emit(.manifestLoadHit, rootEpoch: rootEpoch, numericValue: UInt64(snapshot.records.count))
            updateGraphIndexPipelineScope(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                manifestGeneration: snapshot.manifestGeneration
            )
            return Dictionary(uniqueKeysWithValues: snapshot.records.compactMap { record in
                candidatePaths.contains(record.repositoryRelativePath)
                    ? (record.repositoryRelativePath, record)
                    : nil
            })
        }
    }

    private func graphIndexEntry(
        candidate: WorkspaceCodemapGraphIndexCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        repositoryRelativePath: String,
        record: CodeMapRootManifestRecord
    ) -> WorkspaceCodemapGraphIndexEntry? {
        guard record.repositoryRelativePath == repositoryRelativePath,
              record.bindingGeneration == candidate.requestGeneration,
              record.locatorIdentity.pipelineIdentity == pipelineIdentity,
              record.artifactKey.pipelineIdentity == pipelineIdentity
        else {
            incrementCounter(\.graphIndexEnvelopeStale)
            emit(.graphIndexEnvelopeStale, graphIndexPhase: .loadingEnvelopes)
            return nil
        }
        let outcome: WorkspaceCodemapGraphIndexEntryOutcome
        switch record.outcome {
        case .ready, .readyNoSymbols:
            guard let envelope = record.contributionEnvelope,
                  envelope.identity.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion,
                  envelope.identity.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion
            else {
                incrementCounter(\.graphIndexEnvelopeStale)
                emit(.graphIndexEnvelopeStale, graphIndexPhase: .loadingEnvelopes)
                return nil
            }
            let contribution = CodeMapSelectionGraphContribution(
                artifactKey: record.artifactKey,
                definitions: envelope.sortedUniqueDefinitions,
                references: envelope.sortedUniqueReferences
            )
            guard CodeMapRootManifestContributionIdentity(contribution) == envelope.identity else {
                incrementCounter(\.graphIndexEnvelopeInvalid)
                emit(.graphIndexEnvelopeInvalid, graphIndexPhase: .loadingEnvelopes)
                return nil
            }
            outcome = envelope.sortedUniqueDefinitions.isEmpty && envelope.sortedUniqueReferences.isEmpty
                ? .empty(contribution)
                : .contributed(contribution)
            incrementCounter(\.graphIndexEnvelopeHits)
            emit(.graphIndexEnvelopeHit, graphIndexPhase: .loadingEnvelopes)
        case .terminalOversize:
            outcome = .terminalArtifact(.oversize)
            incrementCounter(\.graphIndexTerminalRecordHits)
            emit(.graphIndexTerminalRecordHit, graphIndexPhase: .loadingEnvelopes)
        case .terminalDecodeFailure:
            outcome = .terminalArtifact(.decodeFailed)
            incrementCounter(\.graphIndexTerminalRecordHits)
            emit(.graphIndexTerminalRecordHit, graphIndexPhase: .loadingEnvelopes)
        case .terminalParseFailure:
            outcome = .terminalArtifact(.parseFailed)
            incrementCounter(\.graphIndexTerminalRecordHits)
            emit(.graphIndexTerminalRecordHit, graphIndexPhase: .loadingEnvelopes)
        }
        return WorkspaceCodemapGraphIndexEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: outcome
        )
    }

    private func retainGraphIndexAutomaticSelectionRecord(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        record: CodeMapRootManifestRecord
    ) {
        guard record.contributionEnvelope != nil,
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[pipelineIdentity]
        else { return }
        if pipeline.automaticSelectionCandidateRecords[record.repositoryRelativePath] == nil {
            let retainedCount = session.pipelines.values.reduce(0) {
                addingSaturating($0, $1.automaticSelectionCandidateRecords.count)
            }
            guard retainedCount < policy.maximumRetainedManifestRecordCountPerRoot else { return }
        }
        pipeline.automaticSelectionCandidateRecords[record.repositoryRelativePath] = record
        session.pipelines[pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
    }

    private func resolveGraphIndexCandidate(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        candidate: WorkspaceCodemapGraphIndexCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        classification: GitBlobIdentityClassification
    ) async -> GraphIndexCandidateResolution {
        guard let job = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              case let .eligible(session)? = roots[rootEpoch],
              session.id == job.sessionID,
              let pipeline = session.pipelines[pipelineIdentity],
              classification.relativePath == candidate.identity.standardizedRelativePath,
              let repositoryRelativePath = classification.repositoryRelativePath,
              repositoryRelativePath == repositoryPath(
                  loadedRootRelativePath: candidate.identity.standardizedRelativePath,
                  prefix: session.capability.repositoryRelativeLoadedRootPrefix
              )
        else { return .transient }

        switch classification.outcome {
        case .securityExcluded:
            return .entry(WorkspaceCodemapGraphIndexEntry(
                identity: candidate.identity,
                requestGeneration: candidate.requestGeneration,
                pathGeneration: candidate.pathGeneration,
                pipelineIdentity: pipelineIdentity,
                outcome: .terminalExcluded(.securityExcluded)
            ), manifestRecord: nil)
        case let .unsupported(reason):
            let exclusion: WorkspaceCodemapGraphTerminalExclusionReason
            switch reason {
            case .gitlink: exclusion = .gitlink
            case .nonRegularFile: exclusion = .nonRegular
            case .unsupportedGit, .invalidObjectFormat, .invalidPath, .unknownIndexMode:
                return .transient
            }
            return .entry(WorkspaceCodemapGraphIndexEntry(
                identity: candidate.identity,
                requestGeneration: candidate.requestGeneration,
                pathGeneration: candidate.pathGeneration,
                pipelineIdentity: pipelineIdentity,
                outcome: .terminalExcluded(exclusion)
            ), manifestRecord: nil)
        case .unavailable:
            return .transient
        case .oidEligible, .requiresValidatedWorktreeBytes:
            break
        }

        let sourceAuthority = await capabilityService.makeSourceAuthority(
            capability: session.capability,
            observedRootEpoch: rootEpoch,
            observedRepositoryAuthority: job.repositoryAuthority,
            candidateRepositoryRelativePath: repositoryRelativePath,
            observedPathGeneration: candidate.pathGeneration,
            currentPathGeneration: candidate.pathGeneration,
            observedIngressGeneration: job.ingressGeneration,
            currentIngressGeneration: session.registration.ingressGeneration
        )
        guard !Task.isCancelled,
              let sourceAuthority,
              graphIndexCandidateIsCurrent(
                  jobID: jobID,
                  rootEpoch: rootEpoch,
                  candidate: candidate,
                  pipelineIdentity: pipelineIdentity
              )
        else { return .transient }

        switch classification.outcome {
        case let .oidEligible(blobOID):
            incrementCounter(\.cleanClassifications)
            let locator = GitBlobCodeMapLocatorIdentity(
                repositoryNamespace: session.capability.repositoryNamespace,
                blobOID: blobOID,
                pipelineIdentity: pipelineIdentity
            )
            var sourceReservation: UInt64 = 0
            defer {
                if sourceReservation > 0 {
                    releaseGraphIndexSourceBytes(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        byteCount: sourceReservation
                    )
                }
            }
            let resolved: ResolvedArtifact
            do {
                switch try await Self.resolveCleanFastPath(
                    runtime: runtime,
                    locator: locator,
                    manifestRecord: nil,
                    ownerID: jobID,
                    priority: .background
                ) {
                case let .ready(fastPath):
                    resolved = fastPath
                case let .miss(miss):
                    recordGraphIndexFastPathMiss(miss, rootEpoch: rootEpoch)
                    let reservation = UInt64(policy.maximumValidatedWorktreeByteCount)
                    switch reserveGraphIndexResources(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        retainedSourceBytes: reservation,
                        preserveForegroundSourceAllowance: true
                    ) {
                    case .reserved:
                        break
                    case .retry:
                        return .transient
                    case let .budget(budget):
                        return .budget(budget)
                    }
                    sourceReservation = reservation
                    resolved = try await Self.materializeAndResolveClean(
                        runtime: runtime,
                        materializationService: materializationService,
                        capability: session.capability,
                        language: candidate.language,
                        locator: locator,
                        ownerID: jobID,
                        priority: .background
                    )
                }
            } catch GitBlobSourceMaterializationError.oversized {
                guard !Task.isCancelled,
                      graphIndexCandidateIsCurrent(
                          jobID: jobID,
                          rootEpoch: rootEpoch,
                          candidate: candidate,
                          pipelineIdentity: pipelineIdentity
                      )
                else { return .transient }
                return .entry(
                    terminalOversizeGraphIndexEntry(
                        candidate: candidate,
                        pipelineIdentity: pipelineIdentity
                    ),
                    manifestRecord: nil
                )
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  graphIndexCandidateIsCurrent(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity
                  ), let association = resolved.association,
                  let mode = gitMode(classification)
            else { return .transient }
            recordGraphIndexResolutionTelemetry(
                resolved,
                rootEpoch: rootEpoch,
                locatorMissAlreadyRecorded: sourceReservation > 0
            )
            guard let entry = graphIndexEntry(
                candidate: candidate,
                pipelineIdentity: pipelineIdentity,
                artifactKey: resolved.resolution.handle.key,
                outcome: resolved.resolution.handle.outcome
            ), let record = try? makeManifestRecord(
                session: session,
                pipeline: pipeline,
                repositoryRelativePath: repositoryRelativePath,
                gitMode: mode,
                association: association,
                bindingGeneration: candidate.requestGeneration
            ) else { return .transient }
            return .entry(entry, manifestRecord: record)

        case let .requiresValidatedWorktreeBytes(reason):
            incrementCounter(\.worktreeClassifications)
            let sourceReservation = UInt64(policy.maximumValidatedWorktreeByteCount)
            switch reserveGraphIndexResources(
                jobID: jobID,
                rootEpoch: rootEpoch,
                retainedSourceBytes: sourceReservation,
                preserveForegroundSourceAllowance: true
            ) {
            case .reserved:
                break
            case .retry:
                return .transient
            case let .budget(budget):
                return .budget(budget)
            }
            defer {
                releaseGraphIndexSourceBytes(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    byteCount: sourceReservation
                )
            }
            let validated: ValidatedRawFileContentSnapshot
            do {
                validated = try await sourceReader.read(
                    candidate.identity,
                    sourceAuthority.acceptedPostPathFingerprint,
                    policy.maximumValidatedWorktreeByteCount,
                    jobID
                )
            } catch FileSystemError.fileTooLarge {
                guard !Task.isCancelled,
                      graphIndexCandidateIsCurrent(
                          jobID: jobID,
                          rootEpoch: rootEpoch,
                          candidate: candidate,
                          pipelineIdentity: pipelineIdentity
                      )
                else { return .transient }
                return .entry(
                    terminalOversizeGraphIndexEntry(
                        candidate: candidate,
                        pipelineIdentity: pipelineIdentity
                    ),
                    manifestRecord: nil
                )
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  graphIndexCandidateIsCurrent(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity
                  )
            else { return .transient }
            incrementCounter(\.validatedWorktreeReads)
            addToCounter(\.validatedWorktreeBytes, UInt64(validated.data.count))
            let source = CodeMapSourceSnapshot(validatedContent: validated)
            guard let input = try? CodeMapArtifactBuildInput(source: source, language: candidate.language) else {
                return .transient
            }
            let result: CodeMapArtifactBuildCoordinatorResult
            do {
                result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                    ownerID: jobID,
                    priority: .background,
                    target: .source(input)
                ))
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  graphIndexCandidateIsCurrent(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity
                  ), case let .ready(resolution) = result,
                  let entry = graphIndexEntry(
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity,
                      artifactKey: resolution.handle.key,
                      outcome: resolution.handle.outcome
                  )
            else { return .transient }
            recordGraphIndexBuildTelemetry(resolution, rootEpoch: rootEpoch)
            _ = reason
            return .entry(entry, manifestRecord: nil)

        case .unavailable, .securityExcluded, .unsupported:
            return .transient
        }
    }

    private func graphIndexEntry(
        candidate: WorkspaceCodemapGraphIndexCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        artifactKey: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome
    ) -> WorkspaceCodemapGraphIndexEntry? {
        let graphIndexOutcome: WorkspaceCodemapGraphIndexEntryOutcome = switch outcome {
        case let .ready(artifact):
            {
                let contribution = CodeMapSelectionGraphContribution(
                    artifactKey: artifactKey,
                    artifact: artifact
                )
                return contribution.sortedUniqueDefinitions.isEmpty &&
                    contribution.sortedUniqueReferences.isEmpty
                    ? .empty(contribution)
                    : .contributed(contribution)
            }()
        case .readyNoSymbols:
            .empty(CodeMapSelectionGraphContribution(
                artifactKey: artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            ))
        case .oversize:
            .terminalArtifact(.oversize)
        case .decodeFailed:
            .terminalArtifact(.decodeFailed)
        case .parseFailed:
            .terminalArtifact(.parseFailed)
        }
        return WorkspaceCodemapGraphIndexEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: graphIndexOutcome
        )
    }

    private func terminalOversizeGraphIndexEntry(
        candidate: WorkspaceCodemapGraphIndexCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity
    ) -> WorkspaceCodemapGraphIndexEntry {
        WorkspaceCodemapGraphIndexEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: .terminalArtifact(.oversize)
        )
    }

    private func recordGraphIndexFastPathMiss(
        _ miss: CodeMapArtifactCoordinatorMiss,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        switch miss {
        case .locatorNotFound:
            incrementCounter(\.graphIndexLocatorMisses)
            emit(.graphIndexLocatorMiss, rootEpoch: rootEpoch)
        case .corruptLocator:
            incrementCounter(\.graphIndexLocatorCorruptions)
            emit(.graphIndexLocatorCorrupt, rootEpoch: rootEpoch)
        case .locatorHitWithMissingArtifact:
            incrementCounter(\.graphIndexLocatorMisses)
            incrementCounter(\.graphIndexCASMisses)
            emit(.graphIndexLocatorMiss, rootEpoch: rootEpoch)
            emit(.graphIndexCASMiss, rootEpoch: rootEpoch)
        case .artifactKeyNotFound:
            incrementCounter(\.graphIndexCASMisses)
            emit(.graphIndexCASMiss, rootEpoch: rootEpoch)
        }
    }

    private func recordGraphIndexResolutionTelemetry(
        _ resolved: ResolvedArtifact,
        rootEpoch: WorkspaceCodemapRootEpoch,
        locatorMissAlreadyRecorded: Bool = false
    ) {
        if !locatorMissAlreadyRecorded {
            switch resolved.resolution.locatorLookup {
            case .miss, .hitButArtifactMissing:
                incrementCounter(\.graphIndexLocatorMisses)
                emit(.graphIndexLocatorMiss, rootEpoch: rootEpoch)
            case .corrupt:
                incrementCounter(\.graphIndexLocatorCorruptions)
                emit(.graphIndexLocatorCorrupt, rootEpoch: rootEpoch)
            case .hit, .stale, .notRequested:
                break
            }
            if resolved.resolution.locatorLookup == .hitButArtifactMissing {
                incrementCounter(\.graphIndexCASMisses)
                emit(.graphIndexCASMiss, rootEpoch: rootEpoch)
            }
        }
        if resolved.materializedByteCount > 0 {
            incrementCounter(\.materializations)
            addToCounter(\.materializedBytes, resolved.materializedByteCount)
            emit(
                .materialization,
                rootEpoch: rootEpoch,
                numericValue: resolved.materializedByteCount
            )
        }
        recordGraphIndexBuildTelemetry(resolved.resolution, rootEpoch: rootEpoch)
    }

    private func recordGraphIndexBuildTelemetry(
        _ resolution: CodeMapArtifactCoordinatorResolution,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        switch resolution.buildProvenance {
        case .notNeeded:
            break
        case .joinedSharedBuild:
            incrementCounter(\.graphIndexArtifactBuildsJoined)
            incrementCounter(\.graphIndexArtifactBuildsCompleted)
            emit(.graphIndexArtifactBuildJoined, rootEpoch: rootEpoch)
            emit(.graphIndexArtifactBuildCompleted, rootEpoch: rootEpoch)
        case .performed:
            incrementCounter(\.graphIndexArtifactBuildsStarted)
            incrementCounter(\.graphIndexArtifactBuildsCompleted)
            emit(.graphIndexArtifactBuildStarted, rootEpoch: rootEpoch)
            emit(.graphIndexArtifactBuildCompleted, rootEpoch: rootEpoch)
        }
    }

    private struct GraphIndexChangeGroup {
        let entries: [WorkspaceCodemapGraphIndexEntry]
        let byteCount: UInt64
    }

    private enum GraphIndexChangeGroupingResult {
        case groups([GraphIndexChangeGroup])
        case budget(WorkspaceCodemapGraphIndexBudget)
    }

    private func graphIndexChangeGroups(
        _ entries: [WorkspaceCodemapGraphIndexEntry]
    ) -> GraphIndexChangeGroupingResult {
        var groups: [GraphIndexChangeGroup] = []
        var currentEntries: [WorkspaceCodemapGraphIndexEntry] = []
        var currentBytes: UInt64 = 0
        for entry in entries {
            let proposedEntries = currentEntries + [entry]
            let proposedBytes: UInt64
            switch WorkspaceCodemapGraphIndexByteAccounting.normalizedByteCount(
                entries: proposedEntries
            ) {
            case let .success(value): proposedBytes = value
            case let .failure(error): return .budget(graphIndexOverflowBudget(error))
            }
            if !currentEntries.isEmpty,
               proposedBytes > policy.maximumGraphIndexChangeByteCount
            {
                groups.append(GraphIndexChangeGroup(entries: currentEntries, byteCount: currentBytes))
                currentEntries = [entry]
                let singleEntryBytes: UInt64
                switch WorkspaceCodemapGraphIndexByteAccounting.normalizedByteCount(
                    entries: currentEntries
                ) {
                case let .success(value): singleEntryBytes = value
                case let .failure(error): return .budget(graphIndexOverflowBudget(error))
                }
                guard singleEntryBytes <= policy.maximumGraphIndexChangeByteCount else {
                    return .budget(WorkspaceCodemapGraphIndexBudget(
                        dimension: .retainedGraphIndexBytes,
                        attempted: singleEntryBytes,
                        limit: policy.maximumGraphIndexChangeByteCount
                    ))
                }
                currentBytes = singleEntryBytes
            } else {
                guard proposedBytes <= policy.maximumGraphIndexChangeByteCount else {
                    return .budget(WorkspaceCodemapGraphIndexBudget(
                        dimension: .retainedGraphIndexBytes,
                        attempted: proposedBytes,
                        limit: policy.maximumGraphIndexChangeByteCount
                    ))
                }
                currentEntries = proposedEntries
                currentBytes = proposedBytes
            }
        }
        if !currentEntries.isEmpty {
            groups.append(GraphIndexChangeGroup(entries: currentEntries, byteCount: currentBytes))
        }
        return .groups(groups)
    }

    private static func graphSlot(
        _ entry: WorkspaceCodemapGraphIndexEntry
    ) -> WorkspaceCodemapGraphSlot? {
        let state: WorkspaceCodemapGraphSlotState = switch entry.outcome {
        case let .contributed(contribution): .contributed(contribution)
        case let .empty(contribution): .empty(contribution)
        case let .terminalArtifact(reason): .terminalArtifact(reason)
        case let .terminalExcluded(reason): .terminalExcluded(reason)
        }
        let contribution: CodeMapSelectionGraphContribution? = switch entry.outcome {
        case let .contributed(value), let .empty(value): value
        case .terminalArtifact, .terminalExcluded: nil
        }
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: entry.identity.rootID,
            rootLifetimeID: entry.identity.rootLifetimeID
        )
        return try? WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: entry.identity,
            requestGeneration: entry.requestGeneration,
            pathGeneration: entry.pathGeneration,
            pipelineIdentity: entry.pipelineIdentity,
            state: state,
            diagnostics: WorkspaceCodemapGraphSlotDiagnostics(
                contributionDigest: contribution?.contributionDigest,
                source: .graphIndex
            )
        ).get()
    }

    private func graphIndexCounts(
        _ entries: [WorkspaceCodemapGraphIndexEntry]
    ) -> WorkspaceCodemapGraphIndexCounts {
        var contributed: UInt64 = 0
        var empty: UInt64 = 0
        var terminalArtifact: UInt64 = 0
        var terminalExcluded: UInt64 = 0
        for entry in entries {
            switch entry.outcome {
            case .contributed: contributed = addingSaturating(contributed, 1)
            case .empty: empty = addingSaturating(empty, 1)
            case .terminalArtifact: terminalArtifact = addingSaturating(terminalArtifact, 1)
            case .terminalExcluded: terminalExcluded = addingSaturating(terminalExcluded, 1)
            }
        }
        return WorkspaceCodemapGraphIndexCounts(
            supportedCandidateCount: UInt64(entries.count),
            processedCandidateCount: UInt64(entries.count),
            contributedCount: contributed,
            emptyCount: empty,
            terminalArtifactCount: terminalArtifact,
            terminalExcludedCount: terminalExcluded,
            transientCount: 0
        )
    }

    private func publishGraphIndexSlots(
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogToken: WorkspaceCodemapGraphIndexCatalogToken,
        slots: [WorkspaceCodemapGraphSlot],
        enumerationFinished: Bool
    ) async -> Bool {
        guard let graph = selectionGraphsByRootEpoch[rootEpoch] else { return false }
        return await overlay.publishGraphIndexSlots(
            rootEpoch: rootEpoch,
            catalogToken: catalogToken,
            slots: slots,
            enumerationFinished: enumerationFinished,
            reconciliationFence: { fileIDs, reason in
                await graph.fenceFiles(fileIDs: fileIDs, reason: reason)
            }
        )
    }

    private func publishGraphIndexEntries(
        _ entries: [WorkspaceCodemapGraphIndexEntry],
        progress: WorkspaceCodemapGraphIndexProgress,
        enumerationFinished: Bool,
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        markerReadinessUnavailableFileIDs: Set<UUID> = []
    ) async -> GraphIndexPublicationDisposition {
        guard updateGraphIndexPhase(
            jobID: jobID,
            rootEpoch: rootEpoch,
            phase: .publishingGraphChanges
        ), let job = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
        let generation = job.generation
        else { return .superseded }
        let slots = entries.compactMap(Self.graphSlot)
        guard slots.count == entries.count,
              await publishGraphIndexSlots(
                  rootEpoch: rootEpoch,
                  catalogToken: generation.catalogToken,
                  slots: slots,
                  enumerationFinished: enumerationFinished
              ),
              let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch),
              var currentJob = graphIndexJobs[rootEpoch],
              currentJob.id == jobID,
              currentJob.generation == generation
        else { return .superseded }
        currentJob.generation = WorkspaceCodemapGraphIndexGeneration(
            catalogToken: generation.catalogToken,
            repositoryAuthority: generation.repositoryAuthority,
            contributionGeneration: overlaySnapshot.contributionGeneration,
            schemaVersion: generation.schemaVersion,
            policyVersion: generation.policyVersion
        )
        graphIndexJobs[rootEpoch] = currentJob
        observeOverlayContributionGeneration(
            overlaySnapshot.contributionGeneration,
            rootEpoch: rootEpoch
        )

        let changes = entries.map { entry in
            let state: WorkspaceCodemapMarkerReadinessState = if markerReadinessUnavailableFileIDs
                .contains(entry.identity.fileID)
            {
                .unavailable
            } else {
                switch entry.outcome {
                case .contributed: .ready
                case .terminalExcluded(.securityExcluded): .securityExcluded
                case .empty, .terminalArtifact, .terminalExcluded: .unavailable
                }
            }
            return WorkspaceCodemapMarkerReadinessChange(
                fileID: entry.identity.fileID,
                standardizedRelativePath: entry.identity.standardizedRelativePath,
                requestGeneration: entry.requestGeneration,
                pathGeneration: entry.pathGeneration,
                state: state
            )
        }
        if !changes.isEmpty {
            _ = await catalogClient.publishMarkerReadiness(
                WorkspaceCodemapMarkerReadinessUpdate(rootEpoch: rootEpoch, changes: changes)
            )
        }
        return .accepted(progress)
    }

    /// Waits for bounded graph-index retry eligibility while preserving the overlay as the
    /// only graph publication authority.
    private func waitForGraphIndexRetry(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        overrideMilliseconds: UInt64? = nil
    ) async -> Bool {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID, graphIndexJobIsCurrent(job) else {
            return false
        }
        let attempt = addingChecked(job.retryAttempt, 1) ?? .max
        let shift = min(attempt - 1, 62)
        let multiplier = UInt64(1) << shift
        let (scaled, scaledOverflow) = policy.graphIndexRetryInitialMilliseconds
            .multipliedReportingOverflow(by: multiplier)
        let base = overrideMilliseconds ?? min(
            policy.graphIndexRetryMaximumMilliseconds,
            scaledOverflow ? .max : scaled
        )
        let jitterRange = policy.graphIndexRetryJitterPercent
        let jitterPercent = jitterRange == 0 ? 0 : attempt % (jitterRange + 1)
        let jitter = base.multipliedReportingOverflow(by: jitterPercent).overflow
            ? 0
            : base * jitterPercent / 100
        let delay = min(policy.graphIndexRetryMaximumMilliseconds, addingSaturating(base, jitter))
        let nanoseconds = delay.multipliedReportingOverflow(by: 1_000_000).overflow
            ? UInt64.max
            : delay * 1_000_000
        let now = uptimeNanoseconds()
        let next = addingSaturating(now, nanoseconds)
        job.phase = .suspendedBusy
        job.retryAttempt = attempt
        job.retry = WorkspaceCodemapGraphIndexRetry(
            attempt: attempt,
            retryAfterMilliseconds: delay,
            nextEligibleAdmissionUptimeNanoseconds: next
        )
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
        incrementCounter(\.graphIndexRetries)
        emit(
            .graphIndexRetry,
            rootEpoch: rootEpoch,
            numericValue: attempt,
            graphIndexPhase: .suspendedBusy,
            retryAfterMilliseconds: delay
        )
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        guard var current = graphIndexJobs[rootEpoch],
              current.id == jobID,
              graphIndexJobIsCurrent(current)
        else { return false }
        current.retry = nil
        graphIndexJobs[rootEpoch] = current
        return true
    }

    private func currentGraphIndexJob(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> GraphIndexJob? {
        guard let job = graphIndexJobs[rootEpoch], job.id == jobID, graphIndexJobIsCurrent(job) else {
            return nil
        }
        return job
    }

    private func graphIndexPublicationStalenessResult(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> GraphIndexPublicationStalenessResult {
        guard let initial = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              let generation = initial.generation
        else { return .terminal }
        let tokenDisposition = await catalogClient.revalidateGraphIndexCatalogToken(
            rootEpoch,
            generation.catalogToken
        )
        switch tokenDisposition {
        case .current:
            break
        case .unavailable:
            return .retry
        case .stale:
            return .terminal
        }
        guard let afterToken = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              afterToken.generation == generation
        else { return .terminal }
        guard let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch) else { return .retry }
        guard let current = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              current.generation == generation,
              overlaySnapshot.catalogGeneration == current.catalogGeneration,
              overlaySnapshot.repositoryAuthority == current.repositoryAuthority
        else { return .terminal }
        return overlaySnapshot.contributionGeneration > generation.contributionGeneration
            ? .restartGeneration
            : .terminal
    }

    private func resetGraphIndexForLatestGeneration(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        recordSupersession: Bool
    ) -> Bool {
        guard var job = graphIndexJobs[rootEpoch],
              job.id == jobID,
              graphIndexJobAuthorityIsCurrent(job),
              job.generation != nil
        else { return false }
        job.phase = .waitingForAdmission
        job.generation = nil
        job.cursor = nil
        job.lastProcessedCursor = nil
        job.progress = .notStarted
        job.inBatchProgress = nil
        job.pageStartProcessedCandidateBaseline = nil
        job.nextGraphChangeSequence = 0
        job.pipelineScopes = [:]
        job.resources = .zero
        job.pendingManifestMutationCount = 0
        job.retryAttempt = 0
        job.retry = nil
        job.budget = nil
        job.checkpoint = nil
        job.isQueuedForAdmission = false
        job.isActiveBatch = false
        graphIndexJobs[rootEpoch] = job
        if recordSupersession {
            incrementCounter(\.graphIndexCoveragesSuperseded)
            emit(.graphIndexCoverageSuperseded, rootEpoch: rootEpoch, graphIndexPhase: .superseded)
        }
        return true
    }

    private func graphIndexJobAuthorityIsCurrent(_ job: GraphIndexJob) -> Bool {
        guard case let .eligible(session)? = roots[job.rootEpoch] else { return false }
        return session.id == job.sessionID &&
            session.generation == job.sessionGeneration &&
            session.invalidationGeneration == job.invalidationGeneration &&
            session.registration.catalogGeneration == job.catalogGeneration &&
            session.registration.ingressGeneration == job.ingressGeneration &&
            session.capability.repositoryAuthority == job.repositoryAuthority &&
            job.generation.map { generation in
                generation.rootEpoch == job.rootEpoch &&
                    generation.catalogGeneration == job.catalogGeneration &&
                    generation.repositoryAuthority == job.repositoryAuthority
            } ?? true
    }

    private func graphIndexJobIsCurrent(_ job: GraphIndexJob) -> Bool {
        graphIndexJobAuthorityIsCurrent(job)
    }

    private func observeOverlayContributionGeneration(
        _ generation: WorkspaceCodemapSelectionGraphContributionGeneration,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        if let current = latestOverlayContributionGenerationByRootEpoch[rootEpoch],
           current >= generation
        {
            return
        }
        latestOverlayContributionGenerationByRootEpoch[rootEpoch] = generation
    }

    private func graphIndexCandidateIsCurrent(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        candidate: WorkspaceCodemapGraphIndexCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity
    ) -> Bool {
        guard let job = currentGraphIndexJob(jobID: jobID, rootEpoch: rootEpoch),
              case let .eligible(session)? = roots[rootEpoch],
              session.pipelines[pipelineIdentity] != nil,
              candidate.identity.rootID == rootEpoch.rootID,
              candidate.identity.rootLifetimeID == rootEpoch.rootLifetimeID,
              candidate.identity.standardizedRootPath ==
              session.registration.capabilityRequest.loadedRootURL.path,
              candidate.requestGeneration > 0,
              candidate.requestGeneration == candidate.pathGeneration,
              (
                  session.pathGenerations[candidate.identity.standardizedRelativePath]
                      ?? job.ingressGeneration
              ) == candidate.pathGeneration
        else { return false }
        return true
    }

    @discardableResult
    private func updateGraphIndexPhase(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        phase: WorkspaceCodemapGraphIndexPhase
    ) -> Bool {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID, graphIndexJobIsCurrent(job) else {
            return false
        }
        job.phase = phase
        job.progress = graphIndexProgress(job.progress, phase: phase)
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
        return true
    }

    private func graphIndexProgress(
        _ progress: WorkspaceCodemapGraphIndexProgress,
        phase: WorkspaceCodemapGraphIndexPhase
    ) -> WorkspaceCodemapGraphIndexProgress {
        switch progress.advancing(to: phase, by: .zero) {
        case let .success(value): value
        case .failure: progress
        }
    }

    private func updateGraphIndexProgress(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        progress: WorkspaceCodemapGraphIndexProgress
    ) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        job.progress = progress
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
    }

    private func updateGraphIndexPipelineScope(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        manifestGeneration: UInt64?
    ) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        job.pipelineScopes[pipelineIdentity] = WorkspaceCodemapGraphIndexPipelineScope(
            pipelineIdentity: pipelineIdentity,
            manifestGeneration: manifestGeneration
        )
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
    }

    private func makeGraphIndexCheckpoint(
        _ job: GraphIndexJob
    ) -> WorkspaceCodemapGraphIndexCheckpoint? {
        guard let generation = job.generation else { return nil }
        return WorkspaceCodemapGraphIndexCheckpoint(
            generation: generation,
            engineSessionID: job.sessionID,
            phase: job.phase,
            cursor: job.cursor,
            progress: job.progress,
            nextGraphChangeSequence: job.nextGraphChangeSequence,
            pipelineScopes: job.pipelineScopes.values.sorted {
                $0.pipelineIdentity.canonicalBytes.lexicographicallyPrecedes(
                    $1.pipelineIdentity.canonicalBytes
                )
            },
            resources: job.resources,
            pendingManifestMutationCount: job.pendingManifestMutationCount,
            retry: job.retry,
            budget: job.budget
        )
    }

    private func reserveGraphIndexResources(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        retainedPathBytes: UInt64 = 0,
        retainedSourceBytes: UInt64 = 0,
        retainedGraphIndexBytes: UInt64 = 0,
        stagedGraphBytes: UInt64 = 0,
        queuedManifestMutationBytes: UInt64 = 0,
        preserveForegroundSourceAllowance: Bool = false
    ) -> GraphIndexResourceReservationResult {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return .retry }
        let addition = WorkspaceCodemapGraphIndexResourceAccounting(
            retainedPathBytes: retainedPathBytes,
            retainedSourceBytes: retainedSourceBytes,
            retainedGraphIndexBytes: retainedGraphIndexBytes,
            stagedGraphBytes: stagedGraphBytes,
            residentGraphBytes: 0,
            queuedManifestMutationBytes: queuedManifestMutationBytes
        )
        let jobResources: WorkspaceCodemapGraphIndexResourceAccounting
        switch job.resources.adding(addition) {
        case let .success(value):
            jobResources = value
        case let .failure(error):
            return .budget(graphIndexOverflowBudget(error))
        }

        if let budget = fixedGraphIndexResourceBudget(jobResources, preserveForegroundSourceAllowance) {
            return .budget(budget)
        }

        var sameRootOthers = WorkspaceCodemapGraphIndexResourceAccounting.zero
        var globalOthers = WorkspaceCodemapGraphIndexResourceAccounting.zero
        for other in graphIndexJobs.values where other.id != jobID {
            switch globalOthers.adding(other.resources) {
            case let .success(value): globalOthers = value
            case let .failure(error): return .budget(graphIndexOverflowBudget(error))
            }
            if other.rootEpoch == rootEpoch {
                switch sameRootOthers.adding(other.resources) {
                case let .success(value): sameRootOthers = value
                case let .failure(error): return .budget(graphIndexOverflowBudget(error))
                }
            }
        }
        for (drainingJobID, resources) in drainingGraphIndexResources {
            switch globalOthers.adding(resources) {
            case let .success(value): globalOthers = value
            case let .failure(error): return .budget(graphIndexOverflowBudget(error))
            }
            if drainingGraphIndexRootEpochs[drainingJobID] == rootEpoch {
                switch sameRootOthers.adding(resources) {
                case let .success(value): sameRootOthers = value
                case let .failure(error): return .budget(graphIndexOverflowBudget(error))
                }
            }
        }
        let rootResources: WorkspaceCodemapGraphIndexResourceAccounting
        switch sameRootOthers.adding(jobResources) {
        case let .success(value): rootResources = value
        case let .failure(error): return .budget(graphIndexOverflowBudget(error))
        }
        let globalResources: WorkspaceCodemapGraphIndexResourceAccounting
        switch globalOthers.adding(jobResources) {
        case let .success(value): globalResources = value
        case let .failure(error): return .budget(graphIndexOverflowBudget(error))
        }
        let foregroundAllowance = preserveForegroundSourceAllowance
            ? UInt64(policy.maximumValidatedWorktreeByteCount)
            : 0
        let activeDemandSourceBytes = activeRequests.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let rootDemandSourceBytes = activeRequests.values.reduce(UInt64(0)) { partial, request in
            request.rootEpoch == rootEpoch
                ? addingSaturating(partial, request.reservedSourceBytes)
                : partial
        }
        let startsMaterialization = retainedSourceBytes > 0 && job.resources.retainedSourceBytes == 0
        let graphIndexUsage = graphIndexSourceUsage(rootEpoch: rootEpoch)
        if startsMaterialization,
           addingSaturating(
               activeRequests.count,
               addingSaturating(graphIndexUsage.globalMaterializationCount, 1)
           ) >
           policy.maximumConcurrentMaterializationCount
        {
            return .retry
        }
        if startsMaterialization,
           addingSaturating(
               activeRequests.values.count(where: { $0.rootEpoch == rootEpoch }),
               addingSaturating(graphIndexUsage.rootMaterializationCount, 1)
           ) > policy.maximumConcurrentMaterializationCountPerRoot
        {
            return .retry
        }
        guard rootResources.retainedGraphIndexBytes <= policy.maximumRetainedGraphIndexByteCountPerRoot,
              globalResources.retainedGraphIndexBytes <= policy.maximumRetainedGraphIndexByteCount,
              rootResources.stagedGraphBytes <= policy.maximumStagedGraphIndexGraphByteCountPerRoot,
              globalResources.stagedGraphBytes <= policy.maximumStagedGraphIndexGraphByteCount,
              rootResources.queuedManifestMutationBytes <=
              policy.maximumQueuedGraphIndexManifestMutationByteCountPerRoot,
              globalResources.queuedManifestMutationBytes <=
              policy.maximumQueuedGraphIndexManifestMutationByteCount,
              addingSaturating(rootResources.retainedSourceBytes, rootDemandSourceBytes) <=
              policy.maximumRetainedSourceByteCountPerRoot,
              addingSaturating(
                  addingSaturating(globalResources.retainedSourceBytes, activeDemandSourceBytes),
                  foregroundAllowance
              ) <= policy.maximumRetainedSourceByteCount
        else { return .retry }
        job.resources = jobResources
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
        return .reserved
    }

    private func fixedGraphIndexResourceBudget(
        _ resources: WorkspaceCodemapGraphIndexResourceAccounting,
        _ preserveForegroundSourceAllowance: Bool
    ) -> WorkspaceCodemapGraphIndexBudget? {
        let checks: [(WorkspaceCodemapGraphIndexBudgetDimension, UInt64, UInt64)] = [
            (
                .retainedGraphIndexBytes,
                resources.retainedGraphIndexBytes,
                policy.maximumRetainedGraphIndexByteCountPerRoot
            ),
            (.retainedGraphIndexBytes, resources.retainedGraphIndexBytes, policy.maximumRetainedGraphIndexByteCount),
            (.stagedGraphBytes, resources.stagedGraphBytes, policy.maximumStagedGraphIndexGraphByteCountPerRoot),
            (.stagedGraphBytes, resources.stagedGraphBytes, policy.maximumStagedGraphIndexGraphByteCount),
            (
                .queuedManifestMutationBytes,
                resources.queuedManifestMutationBytes,
                policy.maximumQueuedGraphIndexManifestMutationByteCountPerRoot
            ),
            (
                .queuedManifestMutationBytes,
                resources.queuedManifestMutationBytes,
                policy.maximumQueuedGraphIndexManifestMutationByteCount
            ),
            (.retainedSourceBytes, resources.retainedSourceBytes, policy.maximumRetainedSourceByteCountPerRoot),
            (
                .retainedSourceBytes,
                addingSaturating(
                    resources.retainedSourceBytes,
                    preserveForegroundSourceAllowance ? UInt64(policy.maximumValidatedWorktreeByteCount) : 0
                ),
                policy.maximumRetainedSourceByteCount
            )
        ]
        guard let failure = checks.first(where: { $0.1 > $0.2 }) else { return nil }
        return WorkspaceCodemapGraphIndexBudget(
            dimension: failure.0,
            attempted: failure.1,
            limit: failure.2
        )
    }

    private func graphIndexOverflowBudget(
        _ error: WorkspaceCodemapGraphIndexAccountingError
    ) -> WorkspaceCodemapGraphIndexBudget {
        let field: WorkspaceCodemapGraphIndexAccountingField = switch error {
        case let .overflow(value), let .underflow(value): value
        }
        let dimension: WorkspaceCodemapGraphIndexBudgetDimension = switch field {
        case .catalogPathBytes, .retainedPathBytes:
            .catalogPathBytes
        case .retainedSourceBytes:
            .retainedSourceBytes
        case .stagedGraphBytes:
            .stagedGraphBytes
        case .residentGraphBytes:
            .residentGraph(.bytes)
        case .queuedManifestMutationBytes:
            .queuedManifestMutationBytes
        case .retainedGraphIndexBytes, .publishedGraphChangeBytes, .publishedGraphChanges:
            .retainedGraphIndexBytes
        case .supportedCandidates, .processedCandidates, .contributed, .empty,
             .terminalArtifacts, .terminalExcluded, .transient, .catalogPages:
            .catalogEntries
        }
        return WorkspaceCodemapGraphIndexBudget(dimension: dimension, attempted: .max, limit: .max - 1)
    }

    private func clearGraphIndexBatchResources(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        job.resources = WorkspaceCodemapGraphIndexResourceAccounting(
            retainedPathBytes: 0,
            retainedSourceBytes: 0,
            retainedGraphIndexBytes: 0,
            stagedGraphBytes: 0,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
    }

    private func releaseGraphIndexSourceBytes(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        byteCount: UInt64
    ) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        let value = job.resources.retainedSourceBytes >= byteCount
            ? job.resources.retainedSourceBytes - byteCount
            : 0
        job.resources = WorkspaceCodemapGraphIndexResourceAccounting(
            retainedPathBytes: job.resources.retainedPathBytes,
            retainedSourceBytes: value,
            retainedGraphIndexBytes: job.resources.retainedGraphIndexBytes,
            stagedGraphBytes: job.resources.stagedGraphBytes,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        graphIndexJobs[rootEpoch] = job
    }

    private func releaseStagedGraphIndexBytes(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        byteCount: UInt64
    ) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        job.resources = WorkspaceCodemapGraphIndexResourceAccounting(
            retainedPathBytes: job.resources.retainedPathBytes,
            retainedSourceBytes: job.resources.retainedSourceBytes,
            retainedGraphIndexBytes: job.resources.retainedGraphIndexBytes,
            stagedGraphBytes: job.resources.stagedGraphBytes >= byteCount
                ? job.resources.stagedGraphBytes - byteCount
                : 0,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        graphIndexJobs[rootEpoch] = job
    }

    private func finishGraphIndexForBudget(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        budget: WorkspaceCodemapGraphIndexBudget
    ) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        incrementCounter(\.graphIndexBudgetRejections)
        job.phase = .budgetLimited
        job.progress = graphIndexProgress(job.progress, phase: .budgetLimited)
        job.inBatchProgress = nil
        job.pageStartProcessedCandidateBaseline = nil
        job.retry = nil
        job.budget = budget
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
        emit(
            .graphIndexBudget,
            rootEpoch: rootEpoch,
            numericValue: budget.attempted,
            graphIndexPhase: .budgetLimited
        )
    }

    private func supersedeGraphIndexJob(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return }
        job.phase = .superseded
        job.progress = graphIndexProgress(job.progress, phase: .superseded)
        job.inBatchProgress = nil
        job.pageStartProcessedCandidateBaseline = nil
        job.checkpoint = makeGraphIndexCheckpoint(job)
        graphIndexJobs[rootEpoch] = job
        incrementCounter(\.graphIndexCoveragesSuperseded)
        emit(.graphIndexCoverageSuperseded, rootEpoch: rootEpoch, graphIndexPhase: .superseded)
    }

    private func finishGraphIndexWorker(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        activeGraphIndexJobIDs.remove(jobID)
        cancelGraphIndexAdmission(jobID: jobID)
        drainingGraphIndexTasks.removeValue(forKey: jobID)
        drainingGraphIndexResources.removeValue(forKey: jobID)
        drainingGraphIndexRootEpochs.removeValue(forKey: jobID)
        if var job = graphIndexJobs[rootEpoch], job.id == jobID {
            job.task = nil
            job.isQueuedForAdmission = false
            job.isActiveBatch = false
            job.resources = .zero
            job.checkpoint = makeGraphIndexCheckpoint(job)
            graphIndexJobs[rootEpoch] = job
        }
        scheduleQueuedRequests()
        scheduleGraphIndexAdmissions()
    }

    @discardableResult
    private func cancelGraphIndexJob(
        rootEpoch: WorkspaceCodemapRootEpoch,
        terminalPhase: WorkspaceCodemapGraphIndexPhase
    ) -> Task<Void, Never>? {
        guard var job = graphIndexJobs.removeValue(forKey: rootEpoch) else { return nil }
        let wasComplete = job.phase == .complete
        let wasActive = activeGraphIndexJobIDs.contains(job.id)
        job.phase = terminalPhase
        // An admitted graphIndex transaction is non-preemptive. Revocation removes publication
        // authority immediately, but the worker reaches its existing currentness boundary without
        // task cancellation. A queued worker owns no admitted transaction and may be cancelled.
        if !wasActive, job.resources.retainedSourceBytes == 0 {
            job.task?.cancel()
        }
        let detached = graphIndexAdmissionQueue.filter { $0.jobID == job.id }
        graphIndexAdmissionQueue.removeAll { $0.jobID == job.id }
        for waiter in detached {
            waiter.continuation.resume(returning: false)
        }
        if wasActive {
            incrementCounter(\.graphIndexCancelledBatches)
            emit(.graphIndexBatchCancelled, rootEpoch: rootEpoch, graphIndexPhase: terminalPhase)
        }
        graphIndexRootLastAdmission.removeValue(forKey: rootEpoch)
        if terminalPhase == .cancelled, !wasComplete {
            incrementCounter(\.graphIndexCoveragesCancelled)
            emit(.graphIndexCoverageCancelled, rootEpoch: rootEpoch, graphIndexPhase: .cancelled)
        }
        if let task = job.task, wasActive {
            drainingGraphIndexTasks[job.id] = task
            drainingGraphIndexResources[job.id] = job.resources
            drainingGraphIndexRootEpochs[job.id] = rootEpoch
        }
        if !wasActive {
            scheduleGraphIndexAdmissions()
        }
        return job.task
    }

    private func loadAndAdoptManifest(
        rootEpoch: WorkspaceCodemapRootEpoch,
        attempt: ManifestAdoptionAttempt
    ) async -> ManifestAdoptionOutcome {
        let pipelineIdentity = attempt.scope.pipelineIdentity
        guard attempt.scope.rootEpoch == rootEpoch,
              manifestAdoptionOperations[attempt.scope]?.attempt.operationID == attempt.operationID,
              case let .eligible(initial)? = roots[rootEpoch],
              initial.id == attempt.sessionID,
              initial.generation == attempt.sessionGeneration,
              initial.invalidationGeneration == attempt.invalidationGeneration,
              initial.registration.catalogGeneration == attempt.catalogGeneration,
              initial.capability.repositoryAuthority == attempt.repositoryAuthority,
              let initialPipeline = initial.pipelines[pipelineIdentity],
              initialPipeline.id == attempt.pipelineSessionID,
              initialPipeline.namespace == attempt.namespace,
              initialPipeline.authority == attempt.authority,
              initialPipeline.manifestRevision == attempt.manifestRevision
        else { return .superseded }
        let pipelineScope = attempt.scope
        guard let ticket = await overlay.beginManifestAdoption(
            rootEpoch: rootEpoch,
            namespace: attempt.namespace
        ),
            case let .eligible(afterTicket)? = roots[rootEpoch],
            afterTicket.id == attempt.sessionID,
            afterTicket.pipelines[pipelineIdentity]?.id == attempt.pipelineSessionID,
            afterTicket.generation == attempt.sessionGeneration,
            afterTicket.invalidationGeneration == attempt.invalidationGeneration
        else { return .retryable }
        let context = ManifestAdoptionContext(
            operationID: attempt.operationID,
            sessionID: attempt.sessionID,
            sessionGeneration: attempt.sessionGeneration,
            invalidationGeneration: attempt.invalidationGeneration,
            pipelineIdentity: pipelineIdentity,
            pipelineSessionID: attempt.pipelineSessionID,
            catalogGeneration: attempt.catalogGeneration,
            repositoryAuthority: attempt.repositoryAuthority,
            namespace: attempt.namespace,
            authority: attempt.authority,
            manifestRevision: attempt.manifestRevision,
            ticket: ticket
        )
        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
        incrementCounter(\.manifestLoads)
        let load: CodeMapRootManifestLoadResult
        do {
            load = try await runtime.manifestStore.loadCurrentManifest(
                namespace: initialPipeline.namespace,
                currentAuthority: initialPipeline.authority
            )
        } catch {
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
            updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            incrementCounter(\.manifestFailures)
            emit(.manifestFailure, rootEpoch: rootEpoch)
            return .retryable
        }
        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else { return .superseded }
        switch load {
        case .miss:
            updatePreviouslyObservedManifestAuthority(nil, context: context, rootEpoch: rootEpoch)
        case let .stale(existingAuthority):
            updatePreviouslyObservedManifestAuthority(
                existingAuthority,
                context: context,
                rootEpoch: rootEpoch
            )
        case let .hit(snapshot):
            updatePreviouslyObservedManifestAuthority(
                snapshot.authority,
                context: context,
                rootEpoch: rootEpoch
            )
        }
        guard case let .hit(snapshot) = load,
              snapshot.records.count <= policy.maximumManifestAdoptionRecordCount
        else {
            updateManifestState(.miss, context: context, rootEpoch: rootEpoch)
            emit(.manifestLoadMiss, rootEpoch: rootEpoch)
            return .terminal(adoptedReadyCount: 0)
        }
        guard let adoptionID = reserveAdoptionRecords(
            snapshot.records.count,
            scope: pipelineScope
        ) else {
            recordBusy(rootEpoch)
            return .retryable
        }
        emit(.manifestLoadHit, rootEpoch: rootEpoch, numericValue: UInt64(snapshot.records.count))

        var prepared: [PreparedManifestAdoption] = []
        var automaticSelectionCandidateRecords: [String: CodeMapRootManifestRecord] = [:]
        for record in snapshot.records {
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard record.locatorIdentity.repositoryNamespace == initial.capability.repositoryNamespace,
                  record.locatorIdentity.blobOID.objectFormat == initial.capability.objectFormat,
                  record.locatorIdentity.pipelineIdentity == initialPipeline.pipelineIdentity,
                  let loadedPath = loadedRootPath(
                      repositoryRelativePath: record.repositoryRelativePath,
                      prefix: initial.capability.repositoryRelativeLoadedRootPrefix
                  ), !loadedPath.isEmpty
            else { continue }
            let candidate = await catalogClient.resolveManifestBinding(rootEpoch, loadedPath)
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard let candidate,
                  candidate.identity.rootID == rootEpoch.rootID,
                  candidate.identity.rootLifetimeID == rootEpoch.rootLifetimeID,
                  candidate.identity.standardizedRootPath ==
                  initial.registration.capabilityRequest.loadedRootURL.path,
                  candidate.identity.standardizedRelativePath == loadedPath,
                  candidate.ingressGeneration == initial.registration.ingressGeneration,
                  candidate.requestGeneration == candidate.pathGeneration,
                  candidate.pathGeneration == record.bindingGeneration
            else { continue }

            let classificationBatch = await identityService.classify(
                workspaceRoot: initial.registration.capabilityRequest.loadedRootURL,
                relativePaths: [loadedPath]
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard classificationBatch.failure == nil,
                  classificationBatch.classifications.count == 1,
                  let classification = classificationBatch.classifications.first,
                  manifestClassificationMatches(
                      classification,
                      record: record,
                      candidate: candidate,
                      session: initial
                  )
            else { continue }

            let sourceAuthority = await capabilityService.makeSourceAuthority(
                capability: initial.capability,
                observedRootEpoch: rootEpoch,
                observedRepositoryAuthority: initial.capability.repositoryAuthority,
                candidateRepositoryRelativePath: record.repositoryRelativePath,
                observedPathGeneration: candidate.pathGeneration,
                currentPathGeneration: candidate.pathGeneration,
                observedIngressGeneration: candidate.ingressGeneration,
                currentIngressGeneration: initial.registration.ingressGeneration
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard let sourceAuthority else { continue }
            automaticSelectionCandidateRecords[record.repositoryRelativePath] = record

            let coordinatorResult = try? await runtime.coordinator.resolve(
                CodeMapArtifactBuildRequest(
                    ownerID: rootEpoch.rootLifetimeID,
                    priority: .explicit,
                    target: .artifactKey(record.artifactKey)
                )
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            guard case let .ready(resolution) = coordinatorResult,
                  let association = try? VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                      identity: record.locatorIdentity,
                      artifactKey: record.artifactKey,
                      casHandle: resolution.handle
                  ), let verifiedRecord = try? makeManifestRecord(
                      session: initial,
                      pipeline: initialPipeline,
                      repositoryRelativePath: record.repositoryRelativePath,
                      gitMode: record.gitMode,
                      association: association,
                      bindingGeneration: record.bindingGeneration
                  )
            else { continue }

            guard record.outcome == .ready || record.outcome == .readyNoSymbols else {
                prepared.append(PreparedManifestAdoption(
                    record: verifiedRecord,
                    candidate: candidate,
                    sourceAuthority: sourceAuthority,
                    association: association,
                    lease: nil
                ))
                continue
            }
            guard reserveAdoptionLease(
                relativePath: candidate.identity.standardizedRelativePath,
                bytes: resolution.handle.estimatedResidentByteCount,
                scope: pipelineScope,
                adoptionID: adoptionID
            ) else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                recordBusy(rootEpoch)
                return .retryable
            }
            guard let lease = try? await runtime.coordinator.acquireLease(for: resolution) else {
                releaseAdoptionLeaseReservation(
                    relativePath: candidate.identity.standardizedRelativePath,
                    scope: pipelineScope,
                    adoptionID: adoptionID
                )
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .retryable
            }
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
                await lease.close()
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            prepared.append(PreparedManifestAdoption(
                record: verifiedRecord,
                candidate: candidate,
                sourceAuthority: sourceAuthority,
                association: association,
                lease: lease
            ))
        }

        guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch) else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            return .superseded
        }

        for item in prepared {
            let refreshed = await catalogClient.resolveManifestBinding(
                rootEpoch,
                item.candidate.identity.standardizedRelativePath
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch),
                  let refreshed,
                  manifestBindingCandidateMatches(refreshed, item.candidate)
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                    updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                }
                return .retryable
            }
        }

        if !prepared.isEmpty {
            let finalClassification = await identityService.classify(
                workspaceRoot: initial.registration.capabilityRequest.loadedRootURL,
                relativePaths: prepared.map(\.candidate.identity.standardizedRelativePath)
            )
            guard await manifestAdoptionIsCurrent(context, rootEpoch: rootEpoch),
                  finalClassification.failure == nil,
                  finalClassification.classifications.count == prepared.count,
                  zip(finalClassification.classifications, prepared).allSatisfy({
                      manifestClassificationMatches(
                          $0.0,
                          record: $0.1.record,
                          candidate: $0.1.candidate,
                          session: initial
                      )
                  })
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                    updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                }
                return .retryable
            }
        }

        let authoritiesAreCurrent = await capabilityService.revalidateSourceAuthorities(
            capability: initial.capability,
            tokens: prepared.map(\.sourceAuthority)
        )
        guard authoritiesAreCurrent,
              adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
        else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            if adoptionContextIsCurrent(context, rootEpoch: rootEpoch) {
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            }
            return .retryable
        }

        guard finalizeAdoptionRecordReservation(
            prepared.count,
            scope: pipelineScope,
            adoptionID: adoptionID
        ) else {
            await closePreparedManifestAdoptions(prepared)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            recordBusy(rootEpoch)
            return .retryable
        }

        var verifiedRecords: [String: CodeMapRootManifestRecord] = [:]
        var pathGenerations: [String: UInt64] = [:]
        var entries: [WorkspaceCodemapLiveManifestAdoptionEntry] = []
        for item in prepared {
            verifiedRecords[item.record.repositoryRelativePath] = item.record
            pathGenerations[item.candidate.identity.standardizedRelativePath] = item.candidate.pathGeneration
            guard let lease = item.lease else { continue }
            guard let expectation = WorkspaceCodemapSourceExpectation.cleanGitBlob(
                bindingIdentity: item.candidate.identity,
                locatorIdentity: item.record.locatorIdentity,
                sourceAuthority: item.sourceAuthority
            ), let token = WorkspaceCodemapArtifactRequestToken.issue(
                identity: item.candidate.identity,
                requestGeneration: item.candidate.requestGeneration,
                catalogGeneration: initial.registration.catalogGeneration,
                sourceExpectation: expectation
            ), let completion = WorkspaceCodemapArtifactCompletion.cleanGitBlob(
                token: token,
                language: initialPipeline.language,
                association: item.association
            ), var binding = WorkspaceCodemapArtifactBinding(pending: token),
            binding.apply(completion) == .accepted
            else {
                await closePreparedManifestAdoptions(prepared)
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
                return .retryable
            }
            entries.append(WorkspaceCodemapLiveManifestAdoptionEntry(
                record: item.record,
                binding: binding,
                lease: lease
            ))
        }
        let disposition = await overlay.adoptManifest(
            ticket: ticket,
            snapshot: snapshot,
            readyEntries: entries
        )
        let stillCurrent = adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
        switch disposition {
        case let .adopted(count):
            guard stillCurrent,
                  case var .eligible(session)? = roots[rootEpoch],
                  var pipeline = session.pipelines[pipelineIdentity],
                  adoptionReservations[pipelineScope]?.id == adoptionID,
                  let reservation = adoptionReservations.removeValue(forKey: pipelineScope)
            else {
                _ = await overlay.rollbackManifestAdoption(
                    ticket: ticket,
                    manifestGeneration: snapshot.manifestGeneration
                )
                releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
                return .superseded
            }
            pipeline.manifestRecords = verifiedRecords
            pipeline.automaticSelectionCandidateRecords = automaticSelectionCandidateRecords
            for (path, generation) in pathGenerations {
                session.pathGenerations[path] = generation
            }
            pipeline.manifestState = .clean(generation: snapshot.manifestGeneration)
            pipeline.persistedManifestRevision = pipeline.manifestRevision
            session.pipelines[pipelineIdentity] = pipeline
            roots[rootEpoch] = .eligible(session)
            retainedAdoptions[pipelineScope] = reservation
            pruneAdmissionHistory()
            incrementCounter(\.manifestAdoptions)
            emit(.manifestAdopted, rootEpoch: rootEpoch, numericValue: UInt64(count))
            return .terminal(adoptedReadyCount: count)
        case .exactDuplicate:
            await closeAdoptionEntries(entries)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            if stillCurrent,
               case var .eligible(session)? = roots[rootEpoch],
               var pipeline = session.pipelines[pipelineIdentity]
            {
                pipeline.automaticSelectionCandidateRecords = automaticSelectionCandidateRecords
                session.pipelines[pipelineIdentity] = pipeline
                roots[rootEpoch] = .eligible(session)
            }
            return .terminal(adoptedReadyCount: 0)
        case .busy, .rejected:
            await closeAdoptionEntries(entries)
            releaseAdoptionReservation(scope: pipelineScope, adoptionID: adoptionID)
            if stillCurrent {
                updateManifestState(.dirtyRetryRequired, context: context, rootEpoch: rootEpoch)
            }
            return .retryable
        }
    }

    private func ensureManifestAdoption(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity
    ) async {
        let scope = PipelineScope(rootEpoch: rootEpoch, pipelineIdentity: pipelineIdentity)
        guard case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[pipelineIdentity]
        else { return }
        if pipeline.manifestLoadFinished {
            return
        }
        if let operation = manifestAdoptionOperations[scope] {
            await waitForManifestAdoption(
                scope: scope,
                operationID: operation.attempt.operationID
            )
            return
        }
        let attempt = ManifestAdoptionAttempt(
            operationID: UUID(),
            scope: scope,
            sessionID: session.id,
            sessionGeneration: session.generation,
            invalidationGeneration: session.invalidationGeneration,
            pipelineSessionID: pipeline.id,
            catalogGeneration: session.registration.catalogGeneration,
            repositoryAuthority: session.capability.repositoryAuthority,
            namespace: pipeline.namespace,
            authority: pipeline.authority,
            manifestRevision: pipeline.manifestRevision
        )
        pipeline.manifestLoadStarted = true
        session.pipelines[pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
        let task = Task {
            await self.loadAndAdoptManifest(rootEpoch: rootEpoch, attempt: attempt)
        }
        manifestAdoptionOperations[scope] = ManifestAdoptionOperation(
            attempt: attempt,
            task: task,
            waiters: [:]
        )
        Task { [weak self] in
            let outcome = await task.value
            await self?.completeManifestAdoption(
                scope: scope,
                operationID: attempt.operationID,
                outcome: outcome
            )
        }
        await waitForManifestAdoption(scope: scope, operationID: attempt.operationID)
    }

    private func waitForManifestAdoption(
        scope: PipelineScope,
        operationID: UUID
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var operation = manifestAdoptionOperations[scope],
                      operation.attempt.operationID == operationID
                else {
                    continuation.resume()
                    return
                }
                operation.waiters[waiterID] = continuation
                manifestAdoptionOperations[scope] = operation
            }
        } onCancel: {
            Task {
                await self.detachManifestAdoptionWaiter(
                    scope: scope,
                    operationID: operationID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func detachManifestAdoptionWaiter(
        scope: PipelineScope,
        operationID: UUID,
        waiterID: UUID
    ) {
        guard var operation = manifestAdoptionOperations[scope],
              operation.attempt.operationID == operationID,
              let waiter = operation.waiters.removeValue(forKey: waiterID)
        else { return }
        manifestAdoptionOperations[scope] = operation
        waiter.resume()
    }

    private func completeManifestAdoption(
        scope: PipelineScope,
        operationID: UUID,
        outcome: ManifestAdoptionOutcome
    ) {
        drainingManifestAdoptionTasks.removeValue(forKey: operationID)
        guard let operation = manifestAdoptionOperations[scope],
              operation.attempt.operationID == operationID
        else { return }
        manifestAdoptionOperations.removeValue(forKey: scope)
        let attempt = operation.attempt
        if case var .eligible(current)? = roots[scope.rootEpoch],
           current.id == attempt.sessionID,
           current.generation == attempt.sessionGeneration,
           current.invalidationGeneration == attempt.invalidationGeneration,
           var currentPipeline = current.pipelines[scope.pipelineIdentity],
           currentPipeline.id == attempt.pipelineSessionID,
           currentPipeline.manifestRevision == attempt.manifestRevision
        {
            switch outcome {
            case .terminal:
                currentPipeline.manifestLoadFinished = true
            case .retryable:
                currentPipeline.manifestLoadStarted = false
                currentPipeline.manifestLoadFinished = false
                currentPipeline.manifestState = .dirtyRetryRequired
            case .superseded:
                break
            }
            current.pipelines[scope.pipelineIdentity] = currentPipeline
            roots[scope.rootEpoch] = .eligible(current)
        }
        for waiter in operation.waiters.values {
            waiter.resume()
        }
    }

    private func manifestClassificationMatches(
        _ classification: GitBlobIdentityClassification,
        record: CodeMapRootManifestRecord,
        candidate: WorkspaceCodemapManifestBindingCandidate,
        session: Session
    ) -> Bool {
        guard classification.relativePath == candidate.identity.standardizedRelativePath,
              classification.repositoryRelativePath == record.repositoryRelativePath,
              classification.objectFormat == session.capability.objectFormat,
              classification.porcelainRecord == nil,
              !classification.intentToAdd,
              !classification.hasConflictStages,
              !classification.skipWorktree,
              !classification.assumeUnchanged,
              classification.checkoutMaterialization == .bytePreserving,
              gitMode(classification) == record.gitMode,
              case let .oidEligible(currentOID) = classification.outcome,
              currentOID == record.locatorIdentity.blobOID
        else { return false }
        return true
    }

    private func manifestBindingCandidateMatches(
        _ lhs: WorkspaceCodemapManifestBindingCandidate,
        _ rhs: WorkspaceCodemapManifestBindingCandidate
    ) -> Bool {
        lhs.identity == rhs.identity &&
            lhs.requestGeneration == rhs.requestGeneration &&
            lhs.pathGeneration == rhs.pathGeneration &&
            lhs.ingressGeneration == rhs.ingressGeneration
    }

    private func manifestAdoptionIsCurrent(
        _ context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch) else { return false }
        guard await overlay.isManifestAdoptionTicketCurrent(context.ticket) else { return false }
        return adoptionContextIsCurrent(context, rootEpoch: rootEpoch)
    }

    private func adoptionContextIsCurrent(
        _ context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let scope = PipelineScope(
            rootEpoch: rootEpoch,
            pipelineIdentity: context.pipelineIdentity
        )
        guard manifestAdoptionOperations[scope]?.attempt.operationID == context.operationID,
              case let .eligible(session)? = roots[rootEpoch],
              let pipeline = session.pipelines[context.pipelineIdentity]
        else { return false }
        return session.id == context.sessionID &&
            session.generation == context.sessionGeneration &&
            session.invalidationGeneration == context.invalidationGeneration &&
            pipeline.id == context.pipelineSessionID &&
            session.registration.catalogGeneration == context.catalogGeneration &&
            session.capability.repositoryAuthority == context.repositoryAuthority &&
            pipeline.namespace == context.namespace &&
            pipeline.authority == context.authority &&
            pipeline.manifestRevision == context.manifestRevision
    }

    private func updateManifestState(
        _ state: WorkspaceCodemapBindingManifestState,
        context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch),
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[context.pipelineIdentity]
        else { return }
        pipeline.manifestState = state
        session.pipelines[context.pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
    }

    private func updatePreviouslyObservedManifestAuthority(
        _ authority: CodeMapRootManifestAuthority?,
        context: ManifestAdoptionContext,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard adoptionContextIsCurrent(context, rootEpoch: rootEpoch),
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[context.pipelineIdentity]
        else { return }
        pipeline.previouslyObservedManifestAuthority = authority
        session.pipelines[context.pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
    }

    private func reserveAdoptionRecords(
        _ count: Int,
        scope: PipelineScope
    ) -> UUID? {
        let currentRootRecordCount: Int
        let replacedRecordCount: Int
        if case let .eligible(session)? = roots[scope.rootEpoch] {
            currentRootRecordCount = session.pipelines.values.reduce(0) {
                addingSaturating($0, $1.manifestRecords.count)
            }
            replacedRecordCount = session.pipelines[scope.pipelineIdentity]?.manifestRecords.count ?? 0
        } else {
            currentRootRecordCount = 0
            replacedRecordCount = 0
        }
        let pendingRootCount = adoptionReservations.reduce(0) { partial, item in
            guard item.key.rootEpoch == scope.rootEpoch, item.key != scope else { return partial }
            return addingSaturating(partial, item.value.recordCount)
        }
        let pendingCount = adoptionReservations.values.reduce(0) {
            addingSaturating($0, $1.recordCount)
        }
        guard let projectedRootCount = addingChecked(
            max(0, currentRootRecordCount - replacedRecordCount),
            addingSaturating(pendingRootCount, count)
        ),
            projectedRootCount <= policy.maximumRetainedManifestRecordCountPerRoot,
            adoptionReservations[scope] == nil,
            let reservedCount = addingChecked(
                max(0, retainedManifestRecordCount(excluding: nil) - replacedRecordCount),
                pendingCount
            ),
            let projectedCount = addingChecked(reservedCount, count),
            projectedCount <= policy.maximumRetainedManifestRecordCount
        else { return nil }
        let adoptionID = UUID()
        adoptionReservations[scope] = AdoptionReservation(
            id: adoptionID,
            recordCount: count,
            leaseBytesByRelativePath: [:]
        )
        return adoptionID
    }

    private func finalizeAdoptionRecordReservation(
        _ count: Int,
        scope: PipelineScope,
        adoptionID: UUID
    ) -> Bool {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID,
              count <= reservation.recordCount,
              count <= policy.maximumRetainedManifestRecordCountPerRoot
        else { return false }
        reservation.recordCount = count
        adoptionReservations[scope] = reservation
        return true
    }

    private func reserveAdoptionLease(
        relativePath: String,
        bytes: UInt64,
        scope: PipelineScope,
        adoptionID: UUID
    ) -> Bool {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID,
              reservation.leaseBytesByRelativePath[relativePath] == nil,
              let usage = adoptionLeaseUsage(),
              let rootUsage = adoptionLeaseUsage(rootEpoch: scope.rootEpoch),
              let projectedRootCount = addingChecked(rootUsage.count, 1),
              let projectedGlobalCount = addingChecked(usage.count, 1),
              let projectedRootBytes = addingChecked(rootUsage.bytes, bytes),
              let projectedGlobalBytes = addingChecked(usage.bytes, bytes),
              projectedRootCount <= policy.maximumManifestAdoptionLeaseCountPerRoot,
              projectedGlobalCount <= policy.maximumManifestAdoptionLeaseCount,
              projectedRootBytes <= policy.maximumManifestAdoptionLeaseByteCountPerRoot,
              projectedGlobalBytes <= policy.maximumManifestAdoptionLeaseByteCount
        else { return false }
        reservation.leaseBytesByRelativePath[relativePath] = bytes
        adoptionReservations[scope] = reservation
        return true
    }

    private func releaseAdoptionLeaseReservation(
        relativePath: String,
        scope: PipelineScope,
        adoptionID: UUID
    ) {
        guard var reservation = adoptionReservations[scope],
              reservation.id == adoptionID
        else { return }
        reservation.leaseBytesByRelativePath.removeValue(forKey: relativePath)
        adoptionReservations[scope] = reservation
    }

    private func adoptionLeaseUsage() -> (count: Int, bytes: UInt64)? {
        let reservations = Array(adoptionReservations.values) + Array(retainedAdoptions.values)
        var count = 0
        var bytes: UInt64 = 0
        for reservation in reservations {
            guard let nextCount = addingChecked(count, reservation.leaseCount),
                  let nextBytes = addingChecked(bytes, reservation.leaseBytes)
            else { return nil }
            count = nextCount
            bytes = nextBytes
        }
        return (count, bytes)
    }

    private func adoptionLeaseUsage(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (count: Int, bytes: UInt64)? {
        let reservations = adoptionReservations.filter { $0.key.rootEpoch == rootEpoch }.map(\.value) +
            retainedAdoptions.filter { $0.key.rootEpoch == rootEpoch }.map(\.value)
        var count = 0
        var bytes: UInt64 = 0
        for reservation in reservations {
            guard let nextCount = addingChecked(count, reservation.leaseCount),
                  let nextBytes = addingChecked(bytes, reservation.leaseBytes)
            else { return nil }
            count = nextCount
            bytes = nextBytes
        }
        return (count, bytes)
    }

    private func releaseAdoptionReservation(
        scope: PipelineScope,
        adoptionID: UUID
    ) {
        guard adoptionReservations[scope]?.id == adoptionID else { return }
        adoptionReservations.removeValue(forKey: scope)
        pruneAdmissionHistory()
    }

    private func releaseRetainedAdoptionPaths(
        _ relativePaths: Set<String>,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        for scope in retainedAdoptions.keys where scope.rootEpoch == rootEpoch {
            guard var retained = retainedAdoptions[scope] else { continue }
            var removedRecordCount = 0
            for relativePath in relativePaths {
                if retained.leaseBytesByRelativePath.removeValue(forKey: relativePath) != nil {
                    removedRecordCount += 1
                }
            }
            retained.recordCount = max(0, retained.recordCount - removedRecordCount)
            if retained.leaseBytesByRelativePath.isEmpty, retained.recordCount == 0 {
                retainedAdoptions.removeValue(forKey: scope)
            } else {
                retainedAdoptions[scope] = retained
            }
        }
    }

    private func closePreparedManifestAdoptions(
        _ prepared: [PreparedManifestAdoption]
    ) async {
        for item in prepared {
            await item.lease?.close()
        }
    }

    private func closeAdoptionEntries(
        _ entries: [WorkspaceCodemapLiveManifestAdoptionEntry]
    ) async {
        for entry in entries {
            await entry.lease.close()
        }
    }

    private func retainedManifestRecordCount(excluding rootEpoch: WorkspaceCodemapRootEpoch?) -> Int {
        roots.reduce(0) { partial, item in
            if item.key == rootEpoch {
                return partial
            }
            guard case let .eligible(session) = item.value else { return partial }
            return session.pipelines.values.reduce(partial) {
                addingSaturating($0, $1.manifestRecords.count)
            }
        }
    }

    private func admitOrQueue(
        requestID: UUID,
        demand: WorkspaceCodemapBindingDemand,
        cancellation: DemandCancellationState,
        continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>
    ) {
        guard !cancellation.isCancelled else {
            continuation.resume(returning: .cancelled)
            return
        }
        switch validateDemand(demand) {
        case let .result(result):
            continuation.resume(returning: result)
        case let .valid(context):
            if canAdmit(demand, rootEpoch: context.rootEpoch) {
                startRequest(
                    requestID: requestID,
                    demand: demand,
                    context: context,
                    continuation: continuation
                )
            } else if canQueue(demand, rootEpoch: context.rootEpoch) {
                ensureQueueOrdinalCapacity()
                guard let next = addingChecked(nextQueueOrdinal, 1) else {
                    recordBusy(context.rootEpoch)
                    continuation.resume(returning: .busy(retryAfterMilliseconds: nil))
                    return
                }
                let ordinal = nextQueueOrdinal
                nextQueueOrdinal = next
                queuedRequests[requestID] = QueuedRequest(
                    id: requestID,
                    rootEpoch: context.rootEpoch,
                    demand: demand,
                    enqueueOrdinal: ordinal,
                    continuation: continuation
                )
                queueOrder.append(requestID)
            } else {
                recordBusy(context.rootEpoch)
                continuation.resume(returning: .busy(retryAfterMilliseconds: nil))
            }
        }
    }

    private func validateDemand(_ demand: WorkspaceCodemapBindingDemand) -> DemandValidation {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: demand.identity.rootID,
            rootLifetimeID: demand.identity.rootLifetimeID
        )
        guard let root = roots[rootEpoch] else { return .result(.rejected(.rootNotRegistered)) }
        guard case let .eligible(session) = root else {
            return .result(.rejected(.capabilityUnavailable))
        }
        guard demand.identity.rootID == session.capability.rootEpoch.rootID,
              demand.identity.rootLifetimeID == session.capability.rootEpoch.rootLifetimeID
        else { return .result(.rejected(.rootEpochMismatch)) }
        guard demand.identity.standardizedRootPath ==
            session.registration.capabilityRequest.loadedRootURL.path
        else { return .result(.rejected(.rootPathMismatch)) }
        guard WorkspaceCodemapArtifactBindingIdentity(
            rootID: demand.identity.rootID,
            rootLifetimeID: demand.identity.rootLifetimeID,
            fileID: demand.identity.fileID,
            standardizedRootPath: demand.identity.standardizedRootPath,
            standardizedRelativePath: demand.identity.standardizedRelativePath,
            standardizedFullPath: demand.identity.standardizedFullPath
        ) == demand.identity
        else { return .result(.rejected(.invalidIdentity)) }
        guard demand.catalogGeneration == session.registration.catalogGeneration else {
            return .result(.rejected(.catalogGenerationMismatch))
        }
        guard demand.requestGeneration > 0 else {
            return .result(.rejected(.requestGenerationInvalid))
        }
        let fileExtension = (demand.identity.standardizedRelativePath as NSString).pathExtension
        guard SyntaxManager.shared.language(forFileExtension: fileExtension) == demand.language else {
            return .result(.unavailable(.unsupportedFileType))
        }
        let pipelineIdentity: CodeMapPipelineIdentity
        do {
            pipelineIdentity = try ensurePipeline(
                rootEpoch: rootEpoch,
                language: demand.language
            )
        } catch {
            return .result(.unavailable(.unsupportedFileType))
        }
        guard case let .eligible(updatedSession)? = roots[rootEpoch] else {
            return .result(.rejected(.staleCompletion))
        }
        let currentPathGeneration = session.pathGenerations[demand.identity.standardizedRelativePath]
            ?? demand.pathGeneration
        guard currentPathGeneration == demand.pathGeneration else {
            return .result(.rejected(.stalePathGeneration))
        }
        guard demand.ingressGeneration == session.registration.ingressGeneration else {
            return .result(.rejected(.staleIngressGeneration))
        }
        return .valid(ValidatedDemandContext(
            rootEpoch: rootEpoch,
            session: updatedSession,
            pipelineIdentity: pipelineIdentity,
            pathGeneration: currentPathGeneration
        ))
    }

    private func publishedArtifactLookupContext(
        _ request: WorkspaceCodemapPublishedArtifactLookupRequest
    ) -> Result<PublishedArtifactLookupContext, WorkspaceCodemapPublishedArtifactLookupMissReason> {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: request.identity.rootID,
            rootLifetimeID: request.identity.rootLifetimeID
        )
        guard case let .eligible(session)? = roots[rootEpoch] else {
            return .failure(.rootUnavailable)
        }
        guard request.identity.standardizedRootPath ==
            session.registration.capabilityRequest.loadedRootURL.path,
            request.catalogGeneration == session.registration.catalogGeneration,
            request.ingressGeneration == session.registration.ingressGeneration,
            request.requestGeneration == request.pathGeneration,
            request.requestGeneration > 0
        else {
            return .failure(.currentnessMismatch)
        }
        let fileExtension = (request.identity.standardizedRelativePath as NSString).pathExtension
        guard SyntaxManager.shared.language(forFileExtension: fileExtension) == request.language,
              let pipelineIdentity = try? SyntaxManager.shared.pipelineIdentity(
                  for: request.language,
                  decoderPolicy: .workspaceAutomaticV1
              ),
              let pipeline = session.pipelines[pipelineIdentity]
        else {
            return .failure(.unsupportedFileType)
        }
        let pathGeneration = session.pathGenerations[request.identity.standardizedRelativePath]
            ?? request.pathGeneration
        guard pathGeneration == request.pathGeneration,
              let repositoryRelativePath = repositoryPath(
                  loadedRootRelativePath: request.identity.standardizedRelativePath,
                  prefix: session.capability.repositoryRelativeLoadedRootPrefix
              ),
              let record = pipeline.manifestRecords[repositoryRelativePath]
        else {
            return .failure(.graphIndexMissing)
        }
        guard record.bindingGeneration == request.pathGeneration,
              record.locatorIdentity.repositoryNamespace == session.capability.repositoryNamespace,
              record.locatorIdentity.pipelineIdentity == pipelineIdentity,
              record.locatorIdentity.blobOID.objectFormat == session.capability.objectFormat
        else {
            return .failure(.currentnessMismatch)
        }
        return .success(PublishedArtifactLookupContext(
            rootEpoch: rootEpoch,
            sessionID: session.id,
            sessionGeneration: session.generation,
            invalidationGeneration: session.invalidationGeneration,
            pipelineSessionID: pipeline.id,
            pipelineIdentity: pipelineIdentity,
            repositoryRelativePath: repositoryRelativePath,
            pathGeneration: pathGeneration,
            record: record
        ))
    }

    private func publishedArtifactLookupIsCurrent(
        _ context: PublishedArtifactLookupContext,
        request: WorkspaceCodemapPublishedArtifactLookupRequest
    ) -> Bool {
        guard case let .eligible(session)? = roots[context.rootEpoch],
              session.id == context.sessionID,
              session.generation == context.sessionGeneration,
              session.invalidationGeneration == context.invalidationGeneration,
              session.registration.catalogGeneration == request.catalogGeneration,
              session.registration.ingressGeneration == request.ingressGeneration,
              let pipeline = session.pipelines[context.pipelineIdentity],
              pipeline.id == context.pipelineSessionID,
              pipeline.manifestRecords[context.repositoryRelativePath] == context.record
        else { return false }
        let pathGeneration = session.pathGenerations[request.identity.standardizedRelativePath]
            ?? request.pathGeneration
        return pathGeneration == context.pathGeneration &&
            pathGeneration == request.pathGeneration
    }

    private func publishedArtifactOutcomeMatches(
        _ outcome: CodeMapSyntaxArtifactOutcome,
        manifestOutcome: CodeMapRootManifestOutcome
    ) -> Bool {
        switch (outcome, manifestOutcome) {
        case (.ready, .ready),
             (.readyNoSymbols, .readyNoSymbols),
             (.oversize, .terminalOversize),
             (.decodeFailed, .terminalDecodeFailure),
             (.parseFailed, .terminalParseFailure):
            true
        default:
            false
        }
    }

    private func recordPublishedArtifactLookupMiss(
        request: WorkspaceCodemapPublishedArtifactLookupRequest,
        reason: WorkspaceCodemapPublishedArtifactLookupMissReason
    ) {
        incrementCounter(\.publishedArtifactLookupMisses)
        emit(
            .publishedArtifactLookupMiss,
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: request.identity.rootID,
                rootLifetimeID: request.identity.rootLifetimeID
            ),
            publishedArtifactLookupMissReason: reason
        )
    }

    private func ensurePipeline(
        rootEpoch: WorkspaceCodemapRootEpoch,
        language: LanguageType
    ) throws -> CodeMapPipelineIdentity {
        guard case var .eligible(session)? = roots[rootEpoch] else {
            throw WorkspaceCodemapBindingEngineProviderError.unconfigured
        }
        let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
            for: language,
            decoderPolicy: .workspaceAutomaticV1
        )
        if let existing = session.pipelines[pipelineIdentity] {
            guard existing.language == language else {
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            }
            return pipelineIdentity
        }
        let namespace = try CodeMapRootManifestNamespace(
            capability: session.capability,
            pipelineIdentity: pipelineIdentity
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: session.capability.repositoryAuthority
        )
        session.pipelines[pipelineIdentity] = PipelineSession(
            id: UUID(),
            language: language,
            pipelineIdentity: pipelineIdentity,
            namespace: namespace,
            authority: authority,
            previouslyObservedManifestAuthority: nil,
            manifestRecords: [:],
            automaticSelectionCandidateRecords: [:],
            manifestState: .miss,
            manifestLoadStarted: false,
            manifestLoadFinished: false,
            manifestRevision: 0,
            persistedManifestRevision: 0,
            pendingManifestChanges: [:]
        )
        roots[rootEpoch] = .eligible(session)
        return pipelineIdentity
    }

    private func canAdmit(
        _ demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let rootRequests = activeRequests.values.filter { $0.rootEpoch == rootEpoch }
        let ownerRequests = rootRequests.filter { $0.publicOwner == demand.owner }
        let owners = Set(rootRequests.map(\.publicOwner))
        let sourceBytes = UInt64(policy.maximumValidatedWorktreeByteCount)
        let graphIndexUsage = graphIndexSourceUsage(rootEpoch: rootEpoch)
        let rootSourceBytes = rootRequests.reduce(graphIndexUsage.rootBytes) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let ownerSourceBytes = ownerRequests.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let globalSourceBytes = activeRequests.values.reduce(graphIndexUsage.globalBytes) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        return activeRequests.count < policy.maximumActiveRequestCount &&
            rootRequests.count < policy.maximumActiveRequestCountPerRoot &&
            ownerRequests.count < policy.maximumActiveRequestCountPerOwner &&
            activeRequests.count < policy.maximumActiveTaskCount &&
            rootRequests.count < policy.maximumActiveTaskCountPerRoot &&
            ownerRequests.count < policy.maximumActiveTaskCountPerOwner &&
            addingSaturating(activeRequests.count, graphIndexUsage.globalMaterializationCount) <
            policy.maximumConcurrentMaterializationCount &&
            addingSaturating(rootRequests.count, graphIndexUsage.rootMaterializationCount) <
            policy.maximumConcurrentMaterializationCountPerRoot &&
            ownerRequests.count < policy.maximumConcurrentMaterializationCountPerOwner &&
            (owners.contains(demand.owner) || owners.count < policy.maximumOwnerCountPerRoot) &&
            addingSaturating(globalSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCount &&
            addingSaturating(rootSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerRoot &&
            addingSaturating(ownerSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerOwner
    }

    private func graphIndexSourceUsage(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (
        rootBytes: UInt64,
        globalBytes: UInt64,
        rootMaterializationCount: Int,
        globalMaterializationCount: Int
    ) {
        var rootBytes: UInt64 = 0
        var globalBytes: UInt64 = 0
        var rootMaterializationCount = 0
        var globalMaterializationCount = 0
        for job in graphIndexJobs.values where job.resources.retainedSourceBytes > 0 {
            globalBytes = addingSaturating(globalBytes, job.resources.retainedSourceBytes)
            globalMaterializationCount = addingSaturating(globalMaterializationCount, 1)
            if job.rootEpoch == rootEpoch {
                rootBytes = addingSaturating(rootBytes, job.resources.retainedSourceBytes)
                rootMaterializationCount = addingSaturating(rootMaterializationCount, 1)
            }
        }
        for (jobID, resources) in drainingGraphIndexResources where resources.retainedSourceBytes > 0 {
            globalBytes = addingSaturating(globalBytes, resources.retainedSourceBytes)
            globalMaterializationCount = addingSaturating(globalMaterializationCount, 1)
            if drainingGraphIndexRootEpochs[jobID] == rootEpoch {
                rootBytes = addingSaturating(rootBytes, resources.retainedSourceBytes)
                rootMaterializationCount = addingSaturating(rootMaterializationCount, 1)
            }
        }
        return (rootBytes, globalBytes, rootMaterializationCount, globalMaterializationCount)
    }

    private func canQueue(
        _ demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        let rootCount = queuedRequests.values.count(where: { $0.rootEpoch == rootEpoch })
        let ownerCount = queuedRequests.values.count(where: {
            $0.rootEpoch == rootEpoch && $0.demand.owner == demand.owner
        })
        return queuedRequests.count < policy.maximumQueuedRequestCount &&
            rootCount < policy.maximumQueuedRequestCountPerRoot &&
            ownerCount < policy.maximumQueuedRequestCountPerOwner
    }

    private func startRequest(
        requestID: UUID,
        demand: WorkspaceCodemapBindingDemand,
        context: ValidatedDemandContext,
        continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult, Never>?
    ) {
        guard let pipeline = context.session.pipelines[context.pipelineIdentity] else {
            continuation?.resume(returning: .rejected(.staleCompletion))
            return
        }
        let sourceBytes = UInt64(policy.maximumValidatedWorktreeByteCount)
        activeRequests[requestID] = ActiveRequest(
            id: requestID,
            rootEpoch: context.rootEpoch,
            demand: demand,
            publicOwner: demand.owner,
            relativePath: demand.identity.standardizedRelativePath,
            sessionID: context.session.id,
            sessionGeneration: context.session.generation,
            pipelineIdentity: context.pipelineIdentity,
            pipelineSessionID: pipeline.id,
            repositoryAuthority: context.session.capability.repositoryAuthority,
            reservedSourceBytes: sourceBytes,
            overlayOwner: nil,
            preflight: nil,
            ticket: nil,
            task: nil,
            continuation: continuation,
            cancelled: false
        )
        recordAdmission(demand: demand, rootEpoch: context.rootEpoch)
        let task = Task { await self.executeRequest(requestID: requestID) }
        guard var request = activeRequests[requestID] else {
            task.cancel()
            return
        }
        request.task = task
        activeRequests[requestID] = request
    }

    private func recordAdmission(
        demand: WorkspaceCodemapBindingDemand,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        ensureAdmissionOrdinalCapacity()
        if let next = addingChecked(nextAdmissionOrdinal, 1) {
            let ordinal = nextAdmissionOrdinal
            nextAdmissionOrdinal = next
            rootLastAdmission[rootEpoch] = ordinal
            ownerLastAdmission[OwnerKey(rootEpoch: rootEpoch, owner: demand.owner)] = ordinal
        }
        switch demand.priority {
        case .demand, .explicit:
            if consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions {
                consecutiveDemandAdmissions += 1
            }
        case .background:
            consecutiveDemandAdmissions = 0
        }
    }

    private func scheduleQueuedRequests() {
        defer { pruneAdmissionHistory() }
        while true {
            var madeProgress = false
            for requestID in queueOrder {
                guard let queued = queuedRequests[requestID] else { continue }
                switch validateDemand(queued.demand) {
                case let .result(result):
                    queuedRequests.removeValue(forKey: requestID)
                    queueOrder.removeAll { $0 == requestID }
                    queued.continuation?.resume(returning: result)
                    madeProgress = true
                case .valid:
                    continue
                }
            }
            if madeProgress {
                continue
            }
            guard let requestID = selectQueuedRequest(),
                  let queued = queuedRequests.removeValue(forKey: requestID)
            else { return }
            queueOrder.removeAll { $0 == requestID }
            guard case let .valid(context) = validateDemand(queued.demand) else {
                queued.continuation?.resume(returning: .rejected(.staleCompletion))
                continue
            }
            startRequest(
                requestID: requestID,
                demand: queued.demand,
                context: context,
                continuation: queued.continuation
            )
        }
    }

    private func selectQueuedRequest() -> UUID? {
        let eligible = queueOrder.compactMap { queuedRequests[$0] }.filter {
            canAdmit($0.demand, rootEpoch: $0.rootEpoch)
        }
        guard !eligible.isEmpty else { return nil }
        let hasDemand = eligible.contains { $0.demand.priority == .demand }
        let hasExplicit = eligible.contains { $0.demand.priority == .explicit }
        let preferredPriority: CodeMapArtifactBuildPriority = if hasDemand {
            .demand
        } else if hasExplicit {
            .explicit
        } else {
            .background
        }
        return eligible.filter { $0.demand.priority == preferredPriority }.min { lhs, rhs in
            let leftRoot = rootLastAdmission[lhs.rootEpoch] ?? 0
            let rightRoot = rootLastAdmission[rhs.rootEpoch] ?? 0
            if leftRoot != rightRoot {
                return leftRoot < rightRoot
            }
            let leftOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: lhs.rootEpoch, owner: lhs.demand.owner)
            ] ?? 0
            let rightOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: rhs.rootEpoch, owner: rhs.demand.owner)
            ] ?? 0
            if leftOwner != rightOwner {
                return leftOwner < rightOwner
            }
            return lhs.enqueueOrdinal < rhs.enqueueOrdinal
        }?.id
    }

    private func ensureQueueOrdinalCapacity() {
        guard nextQueueOrdinal == .max else { return }
        var ordinal: UInt64 = 1
        for requestID in queueOrder {
            guard var request = queuedRequests[requestID] else { continue }
            request.enqueueOrdinal = ordinal
            queuedRequests[requestID] = request
            guard let next = addingChecked(ordinal, 1) else { return }
            ordinal = next
        }
        nextQueueOrdinal = ordinal
    }

    private func ensureAdmissionOrdinalCapacity() {
        guard nextAdmissionOrdinal == .max else { return }
        pruneAdmissionHistory()
        var rootOrdinal: UInt64 = 1
        for (key, _) in rootLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            let left = lhs.key.rootID.uuidString + lhs.key.rootLifetimeID.uuidString
            let right = rhs.key.rootID.uuidString + rhs.key.rootLifetimeID.uuidString
            return left < right
        }) {
            rootLastAdmission[key] = rootOrdinal
            guard let next = addingChecked(rootOrdinal, 1) else { return }
            rootOrdinal = next
        }
        var ownerOrdinal: UInt64 = 1
        for (key, _) in ownerLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            let left = lhs.key.rootEpoch.rootID.uuidString +
                lhs.key.rootEpoch.rootLifetimeID.uuidString + lhs.key.owner.rawValue.uuidString
            let right = rhs.key.rootEpoch.rootID.uuidString +
                rhs.key.rootEpoch.rootLifetimeID.uuidString + rhs.key.owner.rawValue.uuidString
            return left < right
        }) {
            ownerLastAdmission[key] = ownerOrdinal
            guard let next = addingChecked(ownerOrdinal, 1) else { return }
            ownerOrdinal = next
        }
        var graphIndexOrdinal: UInt64 = 1
        for (key, _) in graphIndexRootLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            let left = lhs.key.rootID.uuidString + lhs.key.rootLifetimeID.uuidString
            let right = rhs.key.rootID.uuidString + rhs.key.rootLifetimeID.uuidString
            return left < right
        }) {
            graphIndexRootLastAdmission[key] = graphIndexOrdinal
            graphIndexOrdinal = addingChecked(graphIndexOrdinal, 1) ?? .max
        }
        nextAdmissionOrdinal = max(rootOrdinal, max(ownerOrdinal, graphIndexOrdinal))
    }

    private func pruneAdmissionHistory() {
        var retainedRoots = Set(activeRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(queuedRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(adoptionReservations.keys.map(\.rootEpoch))
        retainedRoots.formUnion(retainedAdoptions.keys.map(\.rootEpoch))
        rootLastAdmission = rootLastAdmission.filter { retainedRoots.contains($0.key) }

        var retainedOwners = Set(activeRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.publicOwner)
        })
        retainedOwners.formUnion(queuedRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.demand.owner)
        })
        ownerLastAdmission = ownerLastAdmission.filter { retainedOwners.contains($0.key) }
        if activeRequests.isEmpty, queuedRequests.isEmpty {
            consecutiveDemandAdmissions = 0
        }
    }

    private func executeRequest(requestID: UUID) async {
        let result: WorkspaceCodemapBindingDemandResult
        do {
            result = try await processRequest(requestID: requestID)
        } catch is CancellationError {
            result = .cancelled
        } catch GitBlobSourceMaterializationError.oversized {
            result = .unavailable(.oversized)
        } catch let error as CodeMapArtifactBuildCoordinatorError {
            if case let .busy(retryAfterMilliseconds) = error {
                if let request = activeRequests[requestID] {
                    recordBusy(request.rootEpoch)
                }
                result = .busy(retryAfterMilliseconds: retryAfterMilliseconds)
            } else {
                if let request = activeRequests[requestID] {
                    recordFailure(request.rootEpoch)
                }
                result = .unavailable(.transient)
            }
        } catch {
            if let request = activeRequests[requestID] {
                recordFailure(request.rootEpoch)
            }
            result = .unavailable(.transient)
        }
        await finishRequest(requestID: requestID, result: result, cancelOverlay: true)
    }

    private func processRequest(
        requestID: UUID
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let initialRequest = currentRequest(requestID) else { throw CancellationError() }
        await prepareManifestForRequest(initialRequest)
        guard let request = currentRequest(requestID),
              case let .eligible(session)? = roots[request.rootEpoch],
              session.pipelines[request.pipelineIdentity]?.id == request.pipelineSessionID
        else { throw CancellationError() }
        try Task.checkCancellation()
        incrementCounter(\.classifications)
        let batch = await identityService.classify(
            workspaceRoot: session.registration.capabilityRequest.loadedRootURL,
            relativePaths: [request.relativePath]
        )
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        guard batch.failure == nil,
              batch.classifications.count == 1,
              let classification = batch.classifications.first,
              classification.relativePath == current.relativePath,
              let repositoryRelativePath = classification.repositoryRelativePath,
              repositoryRelativePath == repositoryPath(
                  loadedRootRelativePath: current.relativePath,
                  prefix: session.capability.repositoryRelativeLoadedRootPrefix
              )
        else {
            emit(.classificationUnavailable, rootEpoch: current.rootEpoch)
            return .rejected(.classificationMismatch)
        }
        switch classification.outcome {
        case .unavailable:
            return .unavailable(.missing)
        case .securityExcluded:
            return .unavailable(.securityExcluded)
        case .unsupported:
            return .unavailable(.nonRegular)
        case .oidEligible, .requiresValidatedWorktreeBytes:
            break
        }

        let sourceAuthority = await capabilityService.makeSourceAuthority(
            capability: session.capability,
            observedRootEpoch: current.rootEpoch,
            observedRepositoryAuthority: session.capability.repositoryAuthority,
            candidateRepositoryRelativePath: repositoryRelativePath,
            observedPathGeneration: current.demand.pathGeneration,
            currentPathGeneration: current.demand.pathGeneration,
            observedIngressGeneration: current.demand.ingressGeneration,
            currentIngressGeneration: session.registration.ingressGeneration
        )
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        guard let sourceAuthority else { return .rejected(.sourceAuthorityUnavailable) }
        guard case var .eligible(latest)? = roots[current.rootEpoch], latest.id == current.sessionID else {
            return .rejected(.staleCompletion)
        }
        latest.pathGenerations[current.relativePath] = current.demand.pathGeneration
        roots[current.rootEpoch] = .eligible(latest)

        let preflightDisposition = await preflightOverlayDemand(requestID: requestID)
        let preflight: WorkspaceCodemapLiveDemandPreflightTicket
        switch preflightDisposition {
        case let .reserved(ticket):
            preflight = ticket
        case let .result(result):
            return result
        }

        switch classification.outcome {
        case let .oidEligible(blobOID):
            guard let pipeline = latest.pipelines[current.pipelineIdentity] else {
                return .rejected(.staleCompletion)
            }
            incrementCounter(\.cleanClassifications)
            emit(.classificationClean, rootEpoch: current.rootEpoch)
            return try await processCleanRequest(
                requestID: requestID,
                session: latest,
                pipeline: pipeline,
                classification: classification,
                repositoryRelativePath: repositoryRelativePath,
                blobOID: blobOID,
                sourceAuthority: sourceAuthority,
                preflight: preflight
            )
        case let .requiresValidatedWorktreeBytes(reason):
            incrementCounter(\.worktreeClassifications)
            emit(.classificationWorktree, rootEpoch: current.rootEpoch)
            return try await processWorktreeRequest(
                requestID: requestID,
                reason: reason,
                sourceAuthority: sourceAuthority,
                preflight: preflight
            )
        case .unavailable, .securityExcluded, .unsupported:
            preconditionFailure("Unavailable classifications return before source authority capture.")
        }
    }

    private func prepareManifestForRequest(_ request: ActiveRequest) async {
        guard case let .eligible(session)? = roots[request.rootEpoch],
              let pipeline = session.pipelines[request.pipelineIdentity],
              pipeline.id == request.pipelineSessionID,
              !pipeline.manifestLoadFinished
        else { return }

        switch request.demand.priority {
        case .demand:
            incrementCounter(\.demandManifestAdoptionBypasses)
        case .explicit, .background:
            incrementCounter(\.demandManifestAdoptionWaits)
            await ensureManifestAdoption(
                rootEpoch: request.rootEpoch,
                pipelineIdentity: request.pipelineIdentity
            )
        }
    }

    private func processCleanRequest(
        requestID: UUID,
        session: Session,
        pipeline: PipelineSession,
        classification: GitBlobIdentityClassification,
        repositoryRelativePath: String,
        blobOID: GitBlobOID,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: session.capability.repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline.pipelineIdentity
        )
        guard let expectation = WorkspaceCodemapSourceExpectation.cleanGitBlob(
            bindingIdentity: request.demand.identity,
            locatorIdentity: locator,
            sourceAuthority: sourceAuthority
        ), let token = WorkspaceCodemapArtifactRequestToken.issue(
            identity: request.demand.identity,
            requestGeneration: request.demand.requestGeneration,
            catalogGeneration: request.demand.catalogGeneration,
            sourceExpectation: expectation
        ) else { return .rejected(.sourceAuthorityUnavailable) }
        let admission = await beginOverlayDemand(
            requestID: requestID,
            token: token,
            preflight: preflight
        )
        switch admission {
        case let .result(result): return result
        case let .ticket(ticket):
            guard let current = currentRequest(requestID) else { throw CancellationError() }
            let manifestRecord = pipeline.manifestRecords[repositoryRelativePath].flatMap {
                $0.locatorIdentity == locator ? $0 : nil
            }
            let resolved = try await Self.resolveClean(
                runtime: runtime,
                materializationService: materializationService,
                capability: session.capability,
                language: current.demand.language,
                locator: locator,
                manifestRecord: manifestRecord,
                ownerID: current.demand.owner.rawValue,
                priority: current.demand.priority
            )
            return try await publishResolution(
                requestID: requestID,
                ticket: ticket,
                token: token,
                resolved: resolved,
                repositoryRelativePath: repositoryRelativePath,
                gitMode: gitMode(classification),
                isClean: true
            )
        }
    }

    private func processWorktreeRequest(
        requestID: UUID,
        reason: GitBlobValidatedWorktreeReason,
        sourceAuthority: WorkspaceCodemapSourceAuthorityToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        let validated: ValidatedRawFileContentSnapshot
        do {
            validated = try await sourceReader.read(
                request.demand.identity,
                sourceAuthority.acceptedPostPathFingerprint,
                policy.maximumValidatedWorktreeByteCount,
                request.demand.owner.rawValue
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch FileSystemError.fileTooLarge {
            return .unavailable(.oversized)
        } catch {
            return .unavailable(.transient)
        }
        try Task.checkCancellation()
        guard let current = currentRequest(requestID) else { throw CancellationError() }
        incrementCounter(\.validatedWorktreeReads)
        addToCounter(\.validatedWorktreeBytes, UInt64(validated.data.count))
        let source = CodeMapSourceSnapshot(validatedContent: validated)
        let input: CodeMapArtifactBuildInput
        do {
            input = try CodeMapArtifactBuildInput(source: source, language: current.demand.language)
        } catch {
            recordFailure(current.rootEpoch)
            return .unavailable(.transient)
        }
        guard let expectation = WorkspaceCodemapSourceExpectation.validatedWorktree(
            bindingIdentity: current.demand.identity,
            source: source,
            expectedArtifactKey: input.artifactKey,
            classificationReason: reason,
            sourceAuthority: sourceAuthority
        ), let token = WorkspaceCodemapArtifactRequestToken.issue(
            identity: current.demand.identity,
            requestGeneration: current.demand.requestGeneration,
            catalogGeneration: current.demand.catalogGeneration,
            sourceExpectation: expectation
        ) else { return .rejected(.sourceAuthorityUnavailable) }
        let admission = await beginOverlayDemand(
            requestID: requestID,
            token: token,
            preflight: preflight
        )
        switch admission {
        case let .result(result): return result
        case let .ticket(ticket):
            guard let latest = currentRequest(requestID) else { throw CancellationError() }
            let coordinatorResult = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
                ownerID: latest.demand.owner.rawValue,
                priority: latest.demand.priority,
                target: .source(input)
            ))
            guard case let .ready(resolution) = coordinatorResult else {
                throw CodeMapArtifactBuildCoordinatorError.casVerificationFailed
            }
            return try await publishResolution(
                requestID: requestID,
                ticket: ticket,
                token: token,
                resolved: ResolvedArtifact(
                    resolution: resolution,
                    association: nil,
                    materializedByteCount: 0,
                    performedBuild: resolution.buildProvenance != .notNeeded,
                    locatorFastPath: false,
                    casFastPath: resolution.buildProvenance == .notNeeded
                ),
                repositoryRelativePath: nil,
                gitMode: nil,
                isClean: false
            )
        }
    }

    private enum OverlayPreflight {
        case reserved(WorkspaceCodemapLiveDemandPreflightTicket)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private func preflightOverlayDemand(requestID: UUID) async -> OverlayPreflight {
        guard var request = currentRequest(requestID) else { return .result(.cancelled) }
        let overlayOwner = WorkspaceCodemapLiveDemandOwner(rawValue: requestID)
        request.overlayOwner = overlayOwner
        activeRequests[requestID] = request
        let disposition = await overlay.preflightDemand(
            owner: overlayOwner,
            identity: request.demand.identity,
            pipelineIdentity: request.pipelineIdentity,
            requestGeneration: request.demand.requestGeneration,
            catalogGeneration: request.demand.catalogGeneration
        )
        guard var current = currentRequest(requestID) else {
            if case let .reserved(ticket) = disposition {
                _ = await overlay.cancelDemandPreflight(ticket)
            }
            return .result(.cancelled)
        }
        switch disposition {
        case let .reserved(ticket):
            current.preflight = ticket
            activeRequests[requestID] = current
            return .reserved(ticket)
        case let .ready(snapshot):
            return .result(.alreadyReady(snapshot))
        case .busy:
            recordBusy(current.rootEpoch)
            return .result(.busy(retryAfterMilliseconds: nil))
        case .rejected:
            return .result(.rejected(.overlayRejected))
        }
    }

    private enum OverlayAdmission {
        case ticket(WorkspaceCodemapLiveDemandTicket)
        case result(WorkspaceCodemapBindingDemandResult)
    }

    private func beginOverlayDemand(
        requestID: UUID,
        token: WorkspaceCodemapArtifactRequestToken,
        preflight: WorkspaceCodemapLiveDemandPreflightTicket
    ) async -> OverlayAdmission {
        guard var request = currentRequest(requestID) else { return .result(.cancelled) }
        let overlayOwner = WorkspaceCodemapLiveDemandOwner(rawValue: requestID)
        request.overlayOwner = overlayOwner
        activeRequests[requestID] = request
        var disposition = await overlay.beginDemand(
            owner: overlayOwner,
            token: token,
            preflight: preflight
        )
        if var afterAdmission = activeRequests[requestID] {
            afterAdmission.preflight = nil
            activeRequests[requestID] = afterAdmission
        }
        if case let .queued(reservation) = disposition {
            guard currentRequest(requestID) != nil else {
                _ = await overlay.cancelDemandReservation(owner: overlayOwner, reservation: reservation)
                return .result(.cancelled)
            }
            disposition = await overlay.resumeDemand(owner: overlayOwner, reservation: reservation)
            if case .queued = disposition {
                _ = await overlay.cancelDemandReservation(owner: overlayOwner, reservation: reservation)
            }
        }
        guard var current = currentRequest(requestID) else {
            switch disposition {
            case let .started(ticket), let .joined(ticket):
                _ = await overlay.cancelDemand(owner: overlayOwner, ticket: ticket)
            default:
                break
            }
            return .result(.cancelled)
        }
        switch disposition {
        case let .started(ticket), let .joined(ticket):
            current.ticket = ticket
            activeRequests[requestID] = current
            return .ticket(ticket)
        case let .ready(snapshot):
            return .result(.alreadyReady(snapshot))
        case .queued, .busy:
            recordBusy(current.rootEpoch)
            return .result(.busy(retryAfterMilliseconds: nil))
        case .rejected:
            return .result(.rejected(.overlayRejected))
        }
    }

    private func publishResolution(
        requestID: UUID,
        ticket: WorkspaceCodemapLiveDemandTicket,
        token: WorkspaceCodemapArtifactRequestToken,
        resolved: ResolvedArtifact,
        repositoryRelativePath: String?,
        gitMode: CodeMapRootManifestGitMode?,
        isClean: Bool
    ) async throws -> WorkspaceCodemapBindingDemandResult {
        try Task.checkCancellation()
        guard let request = currentRequest(requestID) else { throw CancellationError() }
        if resolved.performedBuild {
            incrementCounter(\.builds)
            emit(.build, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.locatorFastPath {
            incrementCounter(\.locatorFastPaths)
            emit(.locatorFastPath, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.casFastPath {
            incrementCounter(\.casFastPaths)
            emit(.casFastPath, rootEpoch: request.rootEpoch, artifact: resolved.resolution.handle.key)
        }
        if resolved.materializedByteCount > 0 {
            incrementCounter(\.materializations)
            addToCounter(\.materializedBytes, resolved.materializedByteCount)
            emit(.materialization, rootEpoch: request.rootEpoch, numericValue: resolved.materializedByteCount)
        }
        let completion: WorkspaceCodemapArtifactCompletion? = if isClean, let association = resolved.association {
            WorkspaceCodemapArtifactCompletion.cleanGitBlob(
                token: token,
                language: request.demand.language,
                association: association
            )
        } else {
            WorkspaceCodemapArtifactCompletion.validatedWorktree(
                token: token,
                language: request.demand.language,
                outcome: resolved.resolution.handle.outcome
            )
        }
        guard let completion else { return .rejected(.staleCompletion) }
        let lease = try await runtime.coordinator.acquireLease(for: resolved.resolution)
        try Task.checkCancellation()
        guard currentRequest(requestID) != nil else {
            await lease.close()
            throw CancellationError()
        }
        let accepted = await overlay.acceptCompletion(ticket: ticket, completion: completion, lease: lease)
        guard var latest = currentRequest(requestID) else {
            switch accepted {
            case .busy, .rejected:
                await lease.close()
            case .accepted, .acceptedUnavailable, .exactDuplicate:
                break
            }
            throw CancellationError()
        }
        switch accepted {
        case let .accepted(snapshot):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayReadyPublications)
            emit(.overlayReady, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            if let repositoryRelativePath, let gitMode, let association = resolved.association {
                await persistCleanCompletionAfterOverlayPublication(
                    rootEpoch: request.rootEpoch,
                    pipelineIdentity: request.pipelineIdentity,
                    identity: request.demand.identity,
                    repositoryRelativePath: repositoryRelativePath,
                    gitMode: gitMode,
                    association: association,
                    bindingGeneration: request.demand.requestGeneration,
                    pathGeneration: request.demand.pathGeneration
                )
            }
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .ready(snapshot)
        case let .exactDuplicate(snapshot):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayExactDuplicateCompletions)
            emit(.overlayExactDuplicate, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .alreadyReady(snapshot)
        case let .acceptedUnavailable(outcome):
            latest.ticket = nil
            activeRequests[requestID] = latest
            incrementCounter(\.overlayUnavailablePublications)
            emit(.overlayUnavailable, rootEpoch: request.rootEpoch, artifact: completion.artifactKey)
            if let repositoryRelativePath, let gitMode, let association = resolved.association {
                await persistCleanCompletionAfterOverlayPublication(
                    rootEpoch: request.rootEpoch,
                    pipelineIdentity: request.pipelineIdentity,
                    identity: request.demand.identity,
                    repositoryRelativePath: repositoryRelativePath,
                    gitMode: gitMode,
                    association: association,
                    bindingGeneration: request.demand.requestGeneration,
                    pathGeneration: request.demand.pathGeneration
                )
            }
            guard currentRequest(requestID) != nil else { throw CancellationError() }
            return .unavailable(.terminalArtifact(outcome))
        case .busy:
            await lease.close()
            recordBusy(request.rootEpoch)
            return .busy(retryAfterMilliseconds: nil)
        case .rejected:
            await lease.close()
            incrementCounter(\.staleCompletionDrops)
            emit(.staleDrop, rootEpoch: request.rootEpoch)
            return .rejected(.staleCompletion)
        }
    }

    private func currentRequest(_ requestID: UUID) -> ActiveRequest? {
        guard let request = activeRequests[requestID], !request.cancelled,
              case let .eligible(session)? = roots[request.rootEpoch],
              session.id == request.sessionID,
              session.generation == request.sessionGeneration,
              session.pipelines[request.pipelineIdentity]?.id == request.pipelineSessionID,
              session.registration.catalogGeneration == request.demand.catalogGeneration,
              session.capability.repositoryAuthority == request.repositoryAuthority
        else { return nil }
        let pathGeneration = session.pathGenerations[request.relativePath]
            ?? request.demand.pathGeneration
        guard pathGeneration == request.demand.pathGeneration,
              session.registration.ingressGeneration == request.demand.ingressGeneration
        else { return nil }
        return request
    }

    private func finishRequest(
        requestID: UUID,
        result: WorkspaceCodemapBindingDemandResult,
        cancelOverlay: Bool
    ) async {
        guard let request = activeRequests.removeValue(forKey: requestID) else {
            if drainingRequestTasks.removeValue(forKey: requestID) != nil {
                scheduleQueuedRequests()
            }
            return
        }
        if let preflight = request.preflight {
            _ = await overlay.cancelDemandPreflight(preflight)
        }
        if cancelOverlay, let owner = request.overlayOwner, let ticket = request.ticket {
            _ = await overlay.cancelDemand(owner: owner, ticket: ticket)
        }
        request.continuation?.resume(returning: request.cancelled ? .cancelled : result)
        scheduleQueuedRequests()
        scheduleGraphIndexAdmissions()
    }

    private static func resolveClean(
        runtime: CodeMapArtifactRuntime,
        materializationService: GitBlobSourceMaterializationService,
        capability: GitCodemapRootCapability,
        language: LanguageType,
        locator: GitBlobCodeMapLocatorIdentity,
        manifestRecord: CodeMapRootManifestRecord?,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) async throws -> ResolvedArtifact {
        switch try await resolveCleanFastPath(
            runtime: runtime,
            locator: locator,
            manifestRecord: manifestRecord,
            ownerID: ownerID,
            priority: priority
        ) {
        case let .ready(resolved):
            resolved
        case .miss:
            try await materializeAndResolveClean(
                runtime: runtime,
                materializationService: materializationService,
                capability: capability,
                language: language,
                locator: locator,
                ownerID: ownerID,
                priority: priority
            )
        }
    }

    private static func resolveCleanFastPath(
        runtime: CodeMapArtifactRuntime,
        locator: GitBlobCodeMapLocatorIdentity,
        manifestRecord: CodeMapRootManifestRecord?,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) async throws -> CleanArtifactFastPathResult {
        if let manifestRecord,
           case let .ready(resolution) = try await runtime.coordinator.resolve(
               CodeMapArtifactBuildRequest(
                   ownerID: ownerID,
                   priority: priority,
                   target: .artifactKey(manifestRecord.artifactKey)
               )
           )
        {
            let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: locator,
                artifactKey: manifestRecord.artifactKey,
                casHandle: resolution.handle
            )
            return .ready(ResolvedArtifact(
                resolution: resolution,
                association: association,
                materializedByteCount: 0,
                performedBuild: false,
                locatorFastPath: false,
                casFastPath: true
            ))
        }
        switch try await runtime.coordinator.resolve(
            CodeMapArtifactBuildRequest(ownerID: ownerID, priority: priority, target: .locator(locator))
        ) {
        case let .ready(resolution):
            let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
                identity: locator,
                artifactKey: resolution.handle.key,
                casHandle: resolution.handle
            )
            return .ready(ResolvedArtifact(
                resolution: resolution,
                association: association,
                materializedByteCount: 0,
                performedBuild: false,
                locatorFastPath: true,
                casFastPath: true
            ))
        case let .miss(miss):
            return .miss(miss)
        }
    }

    private static func materializeAndResolveClean(
        runtime: CodeMapArtifactRuntime,
        materializationService: GitBlobSourceMaterializationService,
        capability: GitCodemapRootCapability,
        language: LanguageType,
        locator: GitBlobCodeMapLocatorIdentity,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) async throws -> ResolvedArtifact {
        let validated = try await materializationService.materialize(
            capability: capability,
            blobOID: locator.blobOID
        )
        let byteCount = UInt64(validated.rawBytes.count)
        let source = CodeMapSourceSnapshot(validatedGitBlob: validated)
        let input = try CodeMapArtifactBuildInput(
            source: source,
            language: language,
            locatorIdentity: locator
        )
        let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
            ownerID: ownerID,
            priority: priority,
            target: .source(input)
        ))
        guard case let .ready(resolution) = result else {
            throw CodeMapArtifactBuildCoordinatorError.casVerificationFailed
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
            source: source,
            identity: locator,
            artifactKey: input.artifactKey,
            casHandle: resolution.handle
        )
        return ResolvedArtifact(
            resolution: resolution,
            association: association,
            materializedByteCount: byteCount,
            performedBuild: resolution.buildProvenance != .notNeeded,
            locatorFastPath: false,
            casFastPath: resolution.buildProvenance == .notNeeded
        )
    }

    private func persistCleanCompletionAfterOverlayPublication(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        identity: WorkspaceCodemapArtifactBindingIdentity,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        bindingGeneration: UInt64,
        pathGeneration: UInt64
    ) async {
        await persistCleanCompletion(
            rootEpoch: rootEpoch,
            pipelineIdentity: pipelineIdentity,
            identity: identity,
            repositoryRelativePath: repositoryRelativePath,
            gitMode: gitMode,
            association: association,
            bindingGeneration: bindingGeneration,
            pathGeneration: pathGeneration
        )
    }

    private func persistCleanCompletion(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        identity: WorkspaceCodemapArtifactBindingIdentity,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        bindingGeneration: UInt64,
        pathGeneration: UInt64
    ) async {
        guard case let .eligible(session)? = roots[rootEpoch],
              let pipeline = session.pipelines[pipelineIdentity],
              let record = try? makeManifestRecord(
                  session: session,
                  pipeline: pipeline,
                  repositoryRelativePath: repositoryRelativePath,
                  gitMode: gitMode,
                  association: association,
                  bindingGeneration: bindingGeneration
              )
        else { return }
        let submission = await submitManifestMutations(
            rootEpoch: rootEpoch,
            pipelineIdentity: pipelineIdentity,
            mutations: [.upsert(record)],
            proof: .session(invalidationGeneration: session.invalidationGeneration),
            retainRecordsInMemory: true
        )
        if case .persisted = submission {
            emit(.manifestWrite, rootEpoch: rootEpoch, artifact: association.artifactKey)
            _ = await catalogClient.publishMarkerReadiness(
                WorkspaceCodemapMarkerReadinessUpdate(
                    rootEpoch: rootEpoch,
                    changes: [
                        WorkspaceCodemapMarkerReadinessChange(
                            fileID: identity.fileID,
                            standardizedRelativePath: identity.standardizedRelativePath,
                            requestGeneration: bindingGeneration,
                            pathGeneration: pathGeneration,
                            state: record.outcome == .ready ? .ready : .unavailable
                        )
                    ]
                )
            )
        }
    }

    private func submitManifestMutations(
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        mutations: [ManifestMutation],
        proof: ManifestMutationAuthority,
        retainRecordsInMemory: Bool
    ) async -> ManifestMutationSubmissionResult {
        guard !mutations.isEmpty,
              case var .eligible(session)? = roots[rootEpoch],
              var pipeline = session.pipelines[pipelineIdentity],
              manifestMutationProofIsCurrent(
                  proof,
                  rootEpoch: rootEpoch,
                  session: session,
                  pipeline: pipeline
              ),
              pipeline.manifestRevision < UInt64.max
        else { return .durabilityFailure }
        let workItemID = UUID()
        let revision = pipeline.manifestRevision + 1
        let byteCount = mutations.reduce(UInt64(0)) {
            addingSaturating($0, manifestMutationByteCount($1))
        }
        if case let .graphIndex(jobID, _) = proof {
            guard let nextPendingCount = graphIndexJobs[rootEpoch].flatMap({ job in
                job.id == jobID
                    ? addingChecked(job.pendingManifestMutationCount, UInt64(mutations.count))
                    : nil
            }) else {
                return .budget(WorkspaceCodemapGraphIndexBudget(
                    dimension: .queuedManifestMutationBytes,
                    attempted: .max,
                    limit: .max - 1
                ))
            }
            switch reserveGraphIndexResources(
                jobID: jobID,
                rootEpoch: rootEpoch,
                queuedManifestMutationBytes: byteCount
            ) {
            case .reserved:
                break
            case .retry:
                return .retry
            case let .budget(budget):
                return .budget(budget)
            }
            guard var job = graphIndexJobs[rootEpoch], job.id == jobID else { return .retry }
            job.pendingManifestMutationCount = nextPendingCount
            job.checkpoint = makeGraphIndexCheckpoint(job)
            graphIndexJobs[rootEpoch] = job
        }

        if retainRecordsInMemory {
            let currentRootCount = session.pipelines.values.reduce(0) {
                addingSaturating($0, $1.manifestRecords.count)
            }
            let currentGlobalCount = addingSaturating(
                retainedManifestRecordCount(excluding: rootEpoch),
                currentRootCount
            )
            let pendingAdoptionCount = adoptionReservations.values.reduce(0) {
                addingSaturating($0, $1.recordCount)
            }
            var retainAllowance = min(
                max(0, policy.maximumRetainedManifestRecordCountPerRoot - currentRootCount),
                max(
                    0,
                    policy.maximumRetainedManifestRecordCount -
                        addingSaturating(currentGlobalCount, pendingAdoptionCount)
                )
            )
            for mutation in mutations {
                switch mutation {
                case let .upsert(record):
                    if pipeline.manifestRecords[record.repositoryRelativePath] != nil ||
                        retainAllowance > 0
                    {
                        if pipeline.manifestRecords[record.repositoryRelativePath] == nil {
                            retainAllowance -= 1
                        }
                        pipeline.manifestRecords[record.repositoryRelativePath] = record
                        if record.contributionEnvelope != nil {
                            pipeline.automaticSelectionCandidateRecords[record.repositoryRelativePath] = record
                        }
                    }
                case let .remove(repositoryRelativePath):
                    pipeline.manifestRecords.removeValue(forKey: repositoryRelativePath)
                    pipeline.automaticSelectionCandidateRecords.removeValue(forKey: repositoryRelativePath)
                }
            }
        }
        pipeline.manifestRevision = revision
        pipeline.manifestState = .dirtyRetryRequired
        for mutation in mutations {
            pipeline.pendingManifestChanges[mutation.repositoryRelativePath] = PendingManifestChange(
                revision: revision,
                workItemID: workItemID,
                record: mutation.record
            )
        }
        session.pipelines[pipelineIdentity] = pipeline
        roots[rootEpoch] = .eligible(session)
        let scope = PipelineScope(rootEpoch: rootEpoch, pipelineIdentity: pipelineIdentity)
        let workKey = ManifestWriterWorkKey(
            scope: scope,
            sessionID: session.id,
            pipelineSessionID: pipeline.id
        )
        let item = ManifestMutationWorkItem(
            id: workItemID,
            workKey: workKey,
            revision: revision,
            proof: proof,
            mutations: mutations,
            byteCount: byteCount
        )
        enqueueManifestWorkItem(item, namespace: pipeline.namespace)
        emit(.manifestRevisionQueued, rootEpoch: rootEpoch, numericValue: revision)
        await hooks.afterManifestRevisionQueuedBeforeWaiterInstall(rootEpoch, revision)
        let succeeded = await waitForManifestRevision(
            scope: scope,
            revision: revision,
            workKey: workKey,
            namespace: pipeline.namespace
        )
        if case let .graphIndex(jobID, _) = proof,
           var job = graphIndexJobs[rootEpoch], job.id == jobID
        {
            job.resources = WorkspaceCodemapGraphIndexResourceAccounting(
                retainedPathBytes: job.resources.retainedPathBytes,
                retainedSourceBytes: job.resources.retainedSourceBytes,
                retainedGraphIndexBytes: job.resources.retainedGraphIndexBytes,
                stagedGraphBytes: job.resources.stagedGraphBytes,
                residentGraphBytes: job.resources.residentGraphBytes,
                queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes >= byteCount
                    ? job.resources.queuedManifestMutationBytes - byteCount
                    : 0
            )
            job.pendingManifestMutationCount = job.pendingManifestMutationCount >= UInt64(mutations.count)
                ? job.pendingManifestMutationCount - UInt64(mutations.count)
                : 0
            job.checkpoint = makeGraphIndexCheckpoint(job)
            graphIndexJobs[rootEpoch] = job
        }
        return succeeded ? .persisted : .durabilityFailure
    }

    private func enqueueManifestWorkItem(
        _ item: ManifestMutationWorkItem,
        namespace: CodeMapRootManifestNamespace
    ) {
        var state = manifestWriters[namespace] ?? ManifestWriterState()
        // Admission order is the priority policy: a later session mutation must not overtake
        // an earlier graphIndex mutation. Batch compatibility may only group adjacent work.
        state.queuedWork.append(item)
        recordManifestWriterPeakQueuedItems(in: state)
        guard state.writerID == nil else {
            manifestWriters[namespace] = state
            return
        }
        // A live retry owns the next writer start. New admissions stay queued behind the
        // deferred head and tail instead of shortening the failure backoff.
        guard state.retryTask == nil else {
            manifestWriters[namespace] = state
            return
        }
        if state.deferredHeadBatch != nil || !state.deferredWork.isEmpty {
            scheduleDeferredManifestRetry(in: &state, namespace: namespace)
        } else {
            startManifestWriter(in: &state, namespace: namespace)
        }
        manifestWriters[namespace] = state
    }

    private func recordManifestWriterPeakQueuedItems(in state: ManifestWriterState) {
        let queuedItemCount = state.queuedWork.count +
            state.deferredWork.count +
            (state.deferredHeadBatch?.items.count ?? 0)
        counters.manifestWriterPeakQueuedItems = max(
            counters.manifestWriterPeakQueuedItems,
            UInt64(queuedItemCount)
        )
    }

    private func startManifestWriter(
        in state: inout ManifestWriterState,
        namespace: CodeMapRootManifestNamespace
    ) {
        let writerID = UUID()
        state.writerID = writerID
        state.task = Task {
            await self.runManifestWriter(namespace: namespace, writerID: writerID)
        }
    }

    private func scheduleDeferredManifestRetry(
        in state: inout ManifestWriterState,
        namespace: CodeMapRootManifestNamespace
    ) {
        guard state.retryTask == nil else { return }
        let retryID = UUID()
        state.retryID = retryID
        state.retryTask = Task {
            await self.retryDeferredManifestWriter(namespace: namespace, retryID: retryID)
        }
    }

    private func dequeueManifestBatch(from writer: inout ManifestWriterState) -> ManifestMutationBatch? {
        if let deferredHeadBatch = writer.deferredHeadBatch {
            return deferredHeadBatch
        }
        let maximumByteCount = policy.maximumQueuedGraphIndexManifestMutationByteCountPerRoot
        let items = writer.queuedWork.popBatch(
            maximumItemCount: Self.maximumManifestWriterBatchItemCount,
            maximumByteCount: maximumByteCount,
            byteCount: { $0.byteCount },
            canAppend: { first, previous, next in
                previous.revision < .max &&
                    next.revision == previous.revision + 1 &&
                    next.workKey == first.workKey &&
                    next.proof == first.proof
            }
        )
        guard let first = items.first else { return nil }
        let byteCount = items.reduce(0) { addingSaturating($0, $1.byteCount) }

        var changesByPath: [String: PendingManifestChange] = [:]
        for item in items {
            for mutation in item.mutations {
                changesByPath[mutation.repositoryRelativePath] = PendingManifestChange(
                    revision: item.revision,
                    workItemID: item.id,
                    record: mutation.record
                )
            }
        }
        return ManifestMutationBatch(
            id: UUID(),
            workKey: first.workKey,
            proof: first.proof,
            items: items,
            highestRevision: items.last?.revision ?? first.revision,
            changesByPath: changesByPath,
            byteCount: byteCount,
            absorbedWorkItemCount: items.count
        )
    }

    private func runManifestWriter(
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID
    ) async {
        while !Task.isCancelled {
            let batch: ManifestMutationBatch
            do {
                guard var writer = manifestWriters[namespace], writer.writerID == writerID else { return }
                guard let nextBatch = dequeueManifestBatch(from: &writer) else {
                    let orphaned = Array(writer.waitersByWorkKey.values.joined())
                    writer.waitersByWorkKey.removeAll()
                    writer.waiterWorkKeyByID.removeAll()
                    writer.writerID = nil
                    writer.task = nil
                    writer.inFlightBatch = nil
                    storeManifestWriterState(writer, namespace: namespace)
                    for waiter in orphaned {
                        waiter.continuation.resume(returning: false)
                    }
                    return
                }
                batch = nextBatch
                writer.inFlightBatch = batch
                manifestWriters[namespace] = writer
                incrementCounter(\.manifestWriteBatches)
                addToCounter(\.manifestWriteItems, UInt64(batch.absorbedWorkItemCount))
                addToCounter(\.manifestWriteBatchBytes, batch.byteCount)
                if batch.absorbedWorkItemCount > 1 {
                    addToCounter(\.manifestWriteCoalescedItems, UInt64(batch.absorbedWorkItemCount - 1))
                }
            }
            let workKey = batch.workKey
            let scope = workKey.scope
            guard case let .eligible(initialSession)? = roots[scope.rootEpoch],
                  initialSession.id == workKey.sessionID,
                  let initialPipeline = initialSession.pipelines[scope.pipelineIdentity],
                  initialPipeline.id == workKey.pipelineSessionID,
                  initialPipeline.namespace == namespace,
                  manifestMutationProofIsCurrent(
                      batch.proof,
                      rootEpoch: scope.rootEpoch,
                      session: initialSession,
                      pipeline: initialPipeline
                  )
            else {
                discardManifestBatch(batch, namespace: namespace, writerID: writerID)
                continue
            }
            var session = initialSession
            var pipeline = initialPipeline
            if batch.highestRevision <= pipeline.persistedManifestRevision {
                guard var currentWriter = currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) else { return }
                currentWriter.inFlightBatch = nil
                if currentWriter.deferredHeadBatch?.id == batch.id {
                    currentWriter.deferredHeadBatch = nil
                    currentWriter.deferredFailureCount = 0
                }
                let completed = detachManifestWaiters(
                    from: &currentWriter,
                    workKey: workKey,
                    revision: batch.highestRevision
                )
                storeManifestWriterState(currentWriter, namespace: namespace)
                for waiter in completed {
                    waiter.continuation.resume(returning: true)
                }
                continue
            }
            if case let .graphIndex(_, generation) = batch.proof {
                let tokenDisposition = await catalogClient.revalidateGraphIndexCatalogToken(
                    scope.rootEpoch,
                    generation.catalogToken
                )
                guard currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) != nil else { return }
                guard tokenDisposition == .current,
                      case let .eligible(revalidated)? = roots[scope.rootEpoch],
                      revalidated.id == session.id,
                      let revalidatedPipeline = revalidated.pipelines[scope.pipelineIdentity],
                      revalidatedPipeline.id == pipeline.id,
                      manifestMutationProofIsCurrent(
                          batch.proof,
                          rootEpoch: scope.rootEpoch,
                          session: revalidated,
                          pipeline: revalidatedPipeline
                      )
                else {
                    discardManifestBatch(batch, namespace: namespace, writerID: writerID)
                    continue
                }
                session = revalidated
                pipeline = revalidatedPipeline
            }
            let sessionID = session.id
            let pipelineSessionID = pipeline.id
            let revision = batch.highestRevision
            var changes = batch.changesByPath
            for (path, change) in pipeline.pendingManifestChanges where change.revision <= revision {
                if (changes[path]?.revision ?? 0) <= change.revision {
                    changes[path] = change
                }
            }
            let upserts = changes.values.compactMap(\.record)
            let removals = Set(changes.compactMap { path, change in
                change.record == nil ? path : nil
            })
            do {
                let claimedWriterAuthority = await runtime.manifestStore.claimManifestWriterAuthority(
                    namespace: namespace,
                    authority: pipeline.authority,
                    writerSession: session.manifestWriterSession
                )
                guard currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) != nil else { return }
                guard let writerAuthority = claimedWriterAuthority else {
                    throw CodeMapRootManifestStoreError.staleWriterAuthority
                }
                guard case let .eligible(afterAuthority)? = roots[scope.rootEpoch],
                      afterAuthority.id == sessionID,
                      let afterAuthorityPipeline = afterAuthority.pipelines[scope.pipelineIdentity],
                      afterAuthorityPipeline.id == pipelineSessionID,
                      manifestMutationProofIsCurrent(
                          batch.proof,
                          rootEpoch: scope.rootEpoch,
                          session: afterAuthority,
                          pipeline: afterAuthorityPipeline
                      )
                else {
                    discardManifestBatch(batch, namespace: namespace, writerID: writerID)
                    continue
                }
                let result = try await mergeManifestChanges(
                    namespace: namespace,
                    authority: pipeline.authority,
                    writerAuthority: writerAuthority,
                    previouslyObservedAuthority: pipeline.previouslyObservedManifestAuthority,
                    upserts: upserts,
                    removals: removals
                )
                guard currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) != nil else { return }
                await hooks.afterManifestStoreWriteBeforeCompletion(scope.rootEpoch)
                guard var currentWriter = currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) else { return }
                currentWriter.inFlightBatch = nil
                if currentWriter.deferredHeadBatch?.id == batch.id {
                    currentWriter.deferredHeadBatch = nil
                    currentWriter.deferredFailureCount = 0
                }
                let completed = detachManifestWaiters(
                    from: &currentWriter,
                    workKey: workKey,
                    revision: revision
                )
                if case var .eligible(current)? = roots[scope.rootEpoch],
                   current.id == sessionID,
                   var currentPipeline = current.pipelines[scope.pipelineIdentity],
                   currentPipeline.id == pipelineSessionID,
                   currentPipeline.namespace == namespace
                {
                    currentPipeline.previouslyObservedManifestAuthority = currentPipeline.authority
                    for (path, change) in changes
                        where currentPipeline.pendingManifestChanges[path]?.revision == change.revision
                    {
                        currentPipeline.pendingManifestChanges.removeValue(forKey: path)
                    }
                    currentPipeline.persistedManifestRevision = max(
                        currentPipeline.persistedManifestRevision,
                        revision
                    )
                    if currentPipeline.pendingManifestChanges.isEmpty,
                       currentPipeline.manifestRevision == revision
                    {
                        currentPipeline.manifestState = .clean(generation: manifestGeneration(result))
                    } else {
                        currentPipeline.manifestState = .dirtyRetryRequired
                    }
                    current.pipelines[scope.pipelineIdentity] = currentPipeline
                    roots[scope.rootEpoch] = .eligible(current)
                }
                storeManifestWriterState(currentWriter, namespace: namespace)
                incrementCounter(\.manifestWrites)
                for waiter in completed {
                    waiter.continuation.resume(returning: true)
                }
            } catch {
                guard var currentWriter = currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    batchID: batch.id
                ) else { return }
                currentWriter.inFlightBatch = nil
                if currentWriter.deferredHeadBatch?.id == batch.id {
                    currentWriter.deferredFailureCount += 1
                } else {
                    currentWriter.deferredHeadBatch = batch
                    currentWriter.deferredFailureCount = 1
                }
                currentWriter.deferredWork.append(contentsOf: currentWriter.queuedWork.drain())
                recordManifestWriterPeakQueuedItems(in: currentWriter)
                if currentWriter.deferredFailureCount >= Self.maximumManifestWriterDeferredAttempts,
                   let exhaustedHead = currentWriter.deferredHeadBatch
                {
                    currentWriter.deferredHeadBatch = nil
                    currentWriter.deferredFailureCount = 0
                    discardManifestWorkItems(
                        exhaustedHead.items,
                        from: &currentWriter,
                        terminalWaiterRevision: exhaustedHead.highestRevision
                    )
                }
                shedNewestDeferredManifestWorkIfNeeded(from: &currentWriter)
                currentWriter.writerID = nil
                currentWriter.task = nil
                if currentWriter.deferredHeadBatch != nil ||
                    !currentWriter.deferredWork.isEmpty ||
                    !currentWriter.queuedWork.isEmpty
                {
                    scheduleDeferredManifestRetry(in: &currentWriter, namespace: namespace)
                }
                storeManifestWriterState(currentWriter, namespace: namespace)
                incrementCounter(\.manifestFailures)
                emit(.manifestFailure, rootEpoch: scope.rootEpoch)
                return
            }
        }
    }

    private func retryDeferredManifestWriter(
        namespace: CodeMapRootManifestNamespace,
        retryID: UUID
    ) async {
        do {
            try await manifestWriterRetryWaiter.sleep(
                .milliseconds(policy.manifestWriterDeferredRetryMilliseconds)
            )
        } catch {
            // Production Task.sleep cancellation is paired with writer teardown. An injected
            // waiter may fail independently; only actual task cancellation suppresses resume.
            guard !Task.isCancelled else { return }
        }
        guard !Task.isCancelled else { return }
        resumeDeferredManifestWriter(namespace: namespace, retryID: retryID)
    }

    private func resumeDeferredManifestWriter(
        namespace: CodeMapRootManifestNamespace,
        retryID: UUID
    ) {
        guard var state = manifestWriters[namespace],
              state.writerID == nil,
              state.retryID == retryID
        else { return }
        state.retryTask = nil
        state.retryID = nil
        if !state.deferredWork.isEmpty {
            state.queuedWork.prepend(contentsOf: state.deferredWork)
            state.deferredWork.removeAll(keepingCapacity: false)
            recordManifestWriterPeakQueuedItems(in: state)
        }
        guard state.deferredHeadBatch != nil || !state.queuedWork.isEmpty else {
            storeManifestWriterState(state, namespace: namespace)
            return
        }
        startManifestWriter(in: &state, namespace: namespace)
        manifestWriters[namespace] = state
    }

    private func discardManifestBatch(
        _ batch: ManifestMutationBatch,
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID
    ) {
        guard var writer = manifestWriters[namespace], writer.writerID == writerID else { return }
        let workKey = batch.workKey
        let workItemIDs = Set(batch.items.map(\.id))
        let detached = detachManifestWaiters(
            from: &writer,
            workKey: workKey,
            revision: batch.highestRevision
        )
        if writer.inFlightBatch?.id == batch.id {
            writer.inFlightBatch = nil
        }
        if writer.deferredHeadBatch?.id == batch.id {
            writer.deferredHeadBatch = nil
            writer.deferredFailureCount = 0
        }
        if case var .eligible(session)? = roots[workKey.scope.rootEpoch],
           session.id == workKey.sessionID,
           var pipeline = session.pipelines[workKey.scope.pipelineIdentity],
           pipeline.id == workKey.pipelineSessionID
        {
            for (path, change) in pipeline.pendingManifestChanges
                where workItemIDs.contains(change.workItemID)
            {
                pipeline.pendingManifestChanges.removeValue(forKey: path)
            }
            pipeline.manifestState = pipeline.pendingManifestChanges.isEmpty
                ? pipeline.manifestState
                : .dirtyRetryRequired
            session.pipelines[workKey.scope.pipelineIdentity] = pipeline
            roots[workKey.scope.rootEpoch] = .eligible(session)
        }
        storeManifestWriterState(writer, namespace: namespace)
        for waiter in detached {
            waiter.continuation.resume(returning: false)
        }
    }

    private func shedNewestDeferredManifestWorkIfNeeded(
        from state: inout ManifestWriterState
    ) {
        let protectedHeadCount = state.deferredHeadBatch?.items.count ?? 0
        let maximumTailCount = max(
            0,
            policy.maximumManifestWriterDeferredItemCount - protectedHeadCount
        )
        guard state.deferredWork.count > maximumTailCount else { return }
        // Preserve the stable failed batch and the oldest admitted tail. The head is already
        // bounded by the batch limit, so a policy cap below that limit may be exceeded only
        // by that single contiguous batch.
        let excess = state.deferredWork.count - maximumTailCount
        let shed = Array(state.deferredWork.suffix(excess))
        state.deferredWork.removeLast(excess)
        discardManifestWorkItems(shed, from: &state)
    }

    private func discardManifestWorkItems(
        _ workItems: [ManifestMutationWorkItem],
        from state: inout ManifestWriterState,
        terminalWaiterRevision: UInt64? = nil
    ) {
        guard !workItems.isEmpty else { return }
        var byWorkKey: [
            ManifestWriterWorkKey: (revisions: Set<UInt64>, workItemIDs: Set<UUID>)
        ] = [:]
        for item in workItems {
            let entry = byWorkKey[
                item.workKey,
                default: (revisions: Set<UInt64>(), workItemIDs: Set<UUID>())
            ]
            byWorkKey[item.workKey] = (
                revisions: entry.revisions.union([item.revision]),
                workItemIDs: entry.workItemIDs.union([item.id])
            )
        }
        for (workKey, entry) in byWorkKey {
            let detached: [ManifestWriteWaiter] = if let terminalWaiterRevision {
                detachManifestWaiters(
                    from: &state,
                    workKey: workKey,
                    revision: terminalWaiterRevision
                )
            } else {
                // Capacity shedding rejects only the newest exact revisions. A through-revision
                // sweep here would incorrectly fail retained older admissions.
                detachManifestWaiters(
                    from: &state,
                    workKey: workKey,
                    revisions: entry.revisions
                )
            }
            for waiter in detached {
                waiter.continuation.resume(returning: false)
            }
            guard case var .eligible(session)? = roots[workKey.scope.rootEpoch],
                  session.id == workKey.sessionID,
                  var pipeline = session.pipelines[workKey.scope.pipelineIdentity],
                  pipeline.id == workKey.pipelineSessionID
            else { continue }
            var didRemove = false
            for item in workItems where item.workKey == workKey {
                for mutation in item.mutations {
                    if pipeline.pendingManifestChanges[mutation.repositoryRelativePath]?.workItemID == item.id {
                        pipeline.pendingManifestChanges.removeValue(forKey: mutation.repositoryRelativePath)
                        didRemove = true
                    }
                }
            }
            if didRemove {
                // Abandonment is never equivalent to durability. Keep the live session dirty
                // even when the discarded newest mutation owned the only pending path entry.
                pipeline.manifestState = .dirtyRetryRequired
            }
            session.pipelines[workKey.scope.pipelineIdentity] = pipeline
            roots[workKey.scope.rootEpoch] = .eligible(session)
        }
    }

    private func currentManifestWriterState(
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID,
        batchID: UUID
    ) -> ManifestWriterState? {
        guard let state = manifestWriters[namespace],
              state.writerID == writerID,
              state.inFlightBatch?.id == batchID
        else { return nil }
        return state
    }

    private func detachManifestWaiters(
        from writer: inout ManifestWriterState,
        workKey: ManifestWriterWorkKey,
        revision: UInt64
    ) -> [ManifestWriteWaiter] {
        guard let waiters = writer.waitersByWorkKey[workKey] else { return [] }
        var detached: [ManifestWriteWaiter] = []
        var retained: [ManifestWriteWaiter] = []
        detached.reserveCapacity(waiters.count)
        retained.reserveCapacity(waiters.count)
        for waiter in waiters {
            if waiter.revision <= revision {
                detached.append(waiter)
            } else {
                retained.append(waiter)
            }
        }
        if retained.isEmpty {
            writer.waitersByWorkKey.removeValue(forKey: workKey)
        } else {
            writer.waitersByWorkKey[workKey] = retained
        }
        for waiter in detached {
            writer.waiterWorkKeyByID.removeValue(forKey: waiter.id)
        }
        return detached
    }

    private func detachManifestWaiters(
        from writer: inout ManifestWriterState,
        workKey: ManifestWriterWorkKey,
        revisions: Set<UInt64>
    ) -> [ManifestWriteWaiter] {
        guard !revisions.isEmpty,
              let waiters = writer.waitersByWorkKey[workKey]
        else { return [] }
        var detached: [ManifestWriteWaiter] = []
        var retained: [ManifestWriteWaiter] = []
        detached.reserveCapacity(waiters.count)
        retained.reserveCapacity(waiters.count)
        for waiter in waiters {
            if revisions.contains(waiter.revision) {
                detached.append(waiter)
            } else {
                retained.append(waiter)
            }
        }
        if retained.isEmpty {
            writer.waitersByWorkKey.removeValue(forKey: workKey)
        } else {
            writer.waitersByWorkKey[workKey] = retained
        }
        for waiter in detached {
            writer.waiterWorkKeyByID.removeValue(forKey: waiter.id)
        }
        return detached
    }

    private func storeManifestWriterState(
        _ state: ManifestWriterState,
        namespace: CodeMapRootManifestNamespace
    ) {
        if state.writerID == nil,
           state.task == nil,
           state.retryTask == nil,
           state.retryID == nil,
           state.queuedWork.isEmpty,
           state.deferredHeadBatch == nil,
           state.deferredWork.isEmpty,
           state.inFlightBatch == nil,
           state.waitersByWorkKey.isEmpty,
           state.waiterWorkKeyByID.isEmpty
        {
            manifestWriters.removeValue(forKey: namespace)
        } else {
            manifestWriters[namespace] = state
        }
    }

    private func manifestMutationProofIsCurrent(
        _ proof: ManifestMutationAuthority,
        rootEpoch: WorkspaceCodemapRootEpoch,
        session: Session,
        pipeline: PipelineSession
    ) -> Bool {
        switch proof {
        case let .session(invalidationGeneration):
            return session.capability.rootEpoch == rootEpoch &&
                session.invalidationGeneration == invalidationGeneration
        case let .graphIndex(jobID, generation):
            guard let job = graphIndexJobs[rootEpoch],
                  job.id == jobID,
                  graphIndexJobIsCurrent(job),
                  job.generation == generation,
                  pipeline.pipelineIdentity == pipeline.namespace.pipelineIdentity
            else { return false }
            return true
        }
    }

    private func manifestMutationByteCount(_ mutation: ManifestMutation) -> UInt64 {
        switch mutation {
        case let .remove(repositoryRelativePath):
            return addingSaturating(64, UInt64(repositoryRelativePath.utf8.count))
        case let .upsert(record):
            var bytes = addingSaturating(256, UInt64(record.repositoryRelativePath.utf8.count))
            bytes = addingSaturating(bytes, UInt64(record.locatorIdentity.canonicalBytes.count))
            bytes = addingSaturating(bytes, UInt64(record.artifactKey.canonicalBytes.count))
            if let envelope = record.contributionEnvelope {
                for name in envelope.sortedUniqueDefinitions {
                    bytes = addingSaturating(bytes, UInt64(name.utf8.count + 8))
                }
                for name in envelope.sortedUniqueReferences {
                    bytes = addingSaturating(bytes, UInt64(name.utf8.count + 8))
                }
            }
            return bytes
        }
    }

    private func boundedManifestMutationBatches(
        _ mutations: [ManifestMutation]
    ) -> [[ManifestMutation]] {
        var batches: [[ManifestMutation]] = []
        var batch: [ManifestMutation] = []
        var batchBytes: UInt64 = 0
        let limit = policy.maximumQueuedGraphIndexManifestMutationByteCountPerRoot
        for mutation in mutations {
            let bytes = manifestMutationByteCount(mutation)
            if !batch.isEmpty, addingSaturating(batchBytes, bytes) > limit {
                batches.append(batch)
                batch = []
                batchBytes = 0
            }
            batch.append(mutation)
            batchBytes = addingSaturating(batchBytes, bytes)
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private func mergeManifestChanges(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        writerAuthority: CodeMapRootManifestWriterAuthorityToken,
        previouslyObservedAuthority: CodeMapRootManifestAuthority?,
        upserts: [CodeMapRootManifestRecord],
        removals: Set<String>
    ) async throws -> CodeMapRootManifestWriteResult {
        var predecessor = previouslyObservedAuthority
        for attempt in 0 ... 1 {
            do {
                return try await runtime.manifestStore.mergeCurrentManifest(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    replacingPreviouslyObservedAuthority: predecessor,
                    upserting: upserts,
                    removing: removals,
                    lastAccessEpochSeconds: accessEpochSeconds()
                )
            } catch CodeMapRootManifestStoreError.quotaExceeded {
                return try await mergeManifestRetainingBoundedSubset(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    previouslyObservedAuthority: predecessor,
                    upserts: upserts,
                    removals: removals
                )
            } catch CodeMapRootManifestModelError.inputTooLarge {
                return try await mergeManifestRetainingBoundedSubset(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    previouslyObservedAuthority: predecessor,
                    upserts: upserts,
                    removals: removals
                )
            } catch CodeMapRootManifestModelError.invalidContribution {
                return try await mergeManifestRetainingBoundedSubset(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    previouslyObservedAuthority: predecessor,
                    upserts: upserts,
                    removals: removals
                )
            } catch CodeMapRootManifestModelError.staleAuthority where attempt == 0 {
                guard await runtime.manifestStore.manifestWriterAuthorityIsCurrent(writerAuthority) else {
                    throw CodeMapRootManifestStoreError.staleWriterAuthority
                }
                let load = try await runtime.manifestStore.loadCurrentManifest(
                    namespace: namespace,
                    currentAuthority: authority
                )
                predecessor = switch load {
                case .miss:
                    nil
                case let .stale(existingAuthority):
                    existingAuthority
                case let .hit(snapshot):
                    snapshot.authority
                }
                if let predecessor, predecessor != authority,
                   predecessor.authorityGeneration >= authority.authorityGeneration
                {
                    throw CodeMapRootManifestModelError.staleAuthority
                }
            }
        }
        throw CodeMapRootManifestModelError.staleAuthority
    }

    private func mergeManifestRetainingBoundedSubset(
        namespace: CodeMapRootManifestNamespace,
        authority: CodeMapRootManifestAuthority,
        writerAuthority: CodeMapRootManifestWriterAuthorityToken,
        previouslyObservedAuthority: CodeMapRootManifestAuthority?,
        upserts: [CodeMapRootManifestRecord],
        removals: Set<String>
    ) async throws -> CodeMapRootManifestWriteResult {
        guard await runtime.manifestStore.manifestWriterAuthorityIsCurrent(writerAuthority) else {
            throw CodeMapRootManifestStoreError.staleWriterAuthority
        }
        let load = try await runtime.manifestStore.loadCurrentManifest(
            namespace: namespace,
            currentAuthority: authority
        )
        var recordsByPath: [String: CodeMapRootManifestRecord] = [:]
        switch load {
        case .miss:
            break
        case let .stale(existingAuthority):
            guard existingAuthority == previouslyObservedAuthority,
                  existingAuthority.authorityGeneration < authority.authorityGeneration
            else { throw CodeMapRootManifestModelError.staleAuthority }
        case let .hit(snapshot):
            recordsByPath = Dictionary(
                uniqueKeysWithValues: snapshot.records.map { ($0.repositoryRelativePath, $0) }
            )
        }
        for path in removals {
            recordsByPath.removeValue(forKey: path)
        }
        for record in upserts {
            recordsByPath[record.repositoryRelativePath] = record
        }
        let ordered = recordsByPath.values.filter { record in
            switch record.outcome {
            case .ready, .readyNoSymbols:
                record.contributionEnvelope != nil
            case .terminalOversize, .terminalDecodeFailure, .terminalParseFailure:
                true
            }
        }.sorted {
            $0.repositoryRelativePath.utf8.lexicographicallyPrecedes($1.repositoryRelativePath.utf8)
        }
        var retainedCount = min(ordered.count, CodeMapRootManifestCodec.maximumRecordCount)
        while true {
            let retained = Array(ordered.prefix(retainedCount))
            let retainedPaths = Set(retained.map(\.repositoryRelativePath))
            let evictedPaths = Set(ordered.lazy.map(\.repositoryRelativePath)).subtracting(retainedPaths)
            do {
                return try await runtime.manifestStore.mergeCurrentManifest(
                    namespace: namespace,
                    authority: authority,
                    writerAuthority: writerAuthority,
                    replacingPreviouslyObservedAuthority: previouslyObservedAuthority,
                    upserting: retained,
                    removing: removals.union(evictedPaths),
                    lastAccessEpochSeconds: accessEpochSeconds()
                )
            } catch CodeMapRootManifestStoreError.quotaExceeded where retainedCount > 0 {
                retainedCount /= 2
            } catch CodeMapRootManifestModelError.inputTooLarge where retainedCount > 0 {
                retainedCount /= 2
            }
        }
    }

    private func waitForManifestRevision(
        scope: PipelineScope,
        revision: UInt64,
        workKey: ManifestWriterWorkKey,
        namespace: CodeMapRootManifestNamespace
    ) async -> Bool {
        guard case let .eligible(session)? = roots[scope.rootEpoch],
              let pipeline = session.pipelines[scope.pipelineIdentity]
        else { return false }
        if pipeline.persistedManifestRevision >= revision {
            return true
        }
        let waiterID = UUID()
        guard workKey.sessionID == session.id,
              workKey.pipelineSessionID == pipeline.id,
              pipeline.namespace == namespace
        else { return false }
        pendingManifestWaiterInstalls.insert(waiterID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingManifestWaiterInstalls.remove(waiterID)
                if cancelledManifestWaiterInstalls.remove(waiterID) != nil {
                    continuation.resume(returning: false)
                    return
                }
                guard !Task.isCancelled,
                      case let .eligible(currentSession)? = roots[scope.rootEpoch],
                      currentSession.id == workKey.sessionID,
                      let currentPipeline = currentSession.pipelines[scope.pipelineIdentity],
                      currentPipeline.id == workKey.pipelineSessionID,
                      currentPipeline.namespace == namespace
                else {
                    continuation.resume(returning: false)
                    return
                }
                if currentPipeline.persistedManifestRevision >= revision {
                    continuation.resume(returning: true)
                    return
                }
                var state = manifestWriters[namespace] ?? ManifestWriterState()
                let hasRelevantWork = state.queuedWork.contains {
                    $0.workKey == workKey && $0.revision >= revision
                } || state.deferredWork.contains {
                    $0.workKey == workKey && $0.revision >= revision
                } || (
                    state.deferredHeadBatch?.workKey == workKey &&
                        (state.deferredHeadBatch?.highestRevision ?? 0) >= revision
                ) || (
                    state.inFlightBatch?.workKey == workKey &&
                        (state.inFlightBatch?.highestRevision ?? 0) >= revision
                )
                guard hasRelevantWork else {
                    continuation.resume(returning: false)
                    return
                }
                state.waitersByWorkKey[workKey, default: []].append(ManifestWriteWaiter(
                    id: waiterID,
                    revision: revision,
                    continuation: continuation
                ))
                state.waiterWorkKeyByID[waiterID] = workKey
                manifestWriters[namespace] = state
                emit(.manifestWaiterInstalled, rootEpoch: scope.rootEpoch, numericValue: revision)
            }
        } onCancel: {
            Task { await self.cancelManifestWaiter(namespace: namespace, waiterID: waiterID) }
        }
    }

    private func cancelManifestWaiter(
        namespace: CodeMapRootManifestNamespace,
        waiterID: UUID
    ) {
        guard var state = manifestWriters[namespace],
              let workKey = state.waiterWorkKeyByID[waiterID],
              var waiters = state.waitersByWorkKey[workKey],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            if pendingManifestWaiterInstalls.contains(waiterID) {
                cancelledManifestWaiterInstalls.insert(waiterID)
            }
            return
        }
        state.waiterWorkKeyByID.removeValue(forKey: waiterID)
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            state.waitersByWorkKey.removeValue(forKey: workKey)
        } else {
            state.waitersByWorkKey[workKey] = waiters
        }
        storeManifestWriterState(state, namespace: namespace)
        waiter.continuation.resume(returning: false)
    }

    private func detachManifestWriters(rootEpoch: WorkspaceCodemapRootEpoch) {
        for namespace in Array(manifestWriters.keys) {
            guard var state = manifestWriters[namespace] else { continue }
            state.queuedWork.removeAll { $0.workKey.scope.rootEpoch == rootEpoch }
            state.deferredWork.removeAll { $0.workKey.scope.rootEpoch == rootEpoch }
            if state.deferredHeadBatch?.workKey.scope.rootEpoch == rootEpoch {
                state.deferredHeadBatch = nil
                state.deferredFailureCount = 0
            }
            let detachedKeys = state.waitersByWorkKey.keys.filter { $0.scope.rootEpoch == rootEpoch }
            let detached = detachedKeys.flatMap { state.waitersByWorkKey.removeValue(forKey: $0) ?? [] }
            for waiter in detached {
                state.waiterWorkKeyByID.removeValue(forKey: waiter.id)
            }
            if state.writerID == nil {
                if state.deferredHeadBatch == nil,
                   state.deferredWork.isEmpty,
                   state.queuedWork.isEmpty
                {
                    state.retryTask?.cancel()
                    state.retryTask = nil
                    state.retryID = nil
                } else if state.retryTask == nil {
                    if state.deferredHeadBatch != nil || !state.deferredWork.isEmpty {
                        scheduleDeferredManifestRetry(in: &state, namespace: namespace)
                    } else {
                        startManifestWriter(in: &state, namespace: namespace)
                    }
                }
            }
            storeManifestWriterState(state, namespace: namespace)
            for waiter in detached {
                waiter.continuation.resume(returning: false)
            }
        }
    }

    private func cancelAllManifestWriters() -> [Task<Void, Never>] {
        let states = Array(manifestWriters.values)
        manifestWriters.removeAll()
        pendingManifestWaiterInstalls.removeAll()
        cancelledManifestWaiterInstalls.removeAll()
        for state in states {
            state.task?.cancel()
            state.retryTask?.cancel()
            for waiter in state.waitersByWorkKey.values.joined() {
                waiter.continuation.resume(returning: false)
            }
        }
        return states.compactMap(\.task)
    }

    private func detachManifestAdoptionOperations(rootEpoch: WorkspaceCodemapRootEpoch) {
        for scope in Array(manifestAdoptionOperations.keys) where scope.rootEpoch == rootEpoch {
            guard let operation = manifestAdoptionOperations.removeValue(forKey: scope) else { continue }
            operation.task.cancel()
            drainingManifestAdoptionTasks[operation.attempt.operationID] = operation.task
            for waiter in operation.waiters.values {
                waiter.resume()
            }
        }
    }

    private func invalidatePaths(
        _ rootEpoch: WorkspaceCodemapRootEpoch,
        paths: Set<String>,
        reason: WorkspaceCodemapLiveOverlayInvalidationReason
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        let safePaths = Set(paths.compactMap(safeRelativePath))
        guard !safePaths.isEmpty else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.invalidation, rootEpoch: rootEpoch, invalidationReason: reason)
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard case var .eligible(session)? = roots[rootEpoch] else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard session.invalidationGeneration < UInt64.max,
              session.pipelines.values.allSatisfy({ $0.manifestRevision < UInt64.max }),
              safePaths.allSatisfy({ (session.pathGenerations[$0] ?? 0) < UInt64.max })
        else {
            return await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .authorityChanged)
        }

        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)

        session.invalidationGeneration += 1
        for path in safePaths {
            session.pathGenerations[path] = (
                session.pathGenerations[path] ?? session.registration.ingressGeneration
            ) + 1
        }
        var manifestRemovals: [CodeMapPipelineIdentity: [ManifestMutation]] = [:]
        for identity in session.pipelines.keys {
            for path in safePaths {
                if let repositoryPath = repositoryPath(
                    loadedRootRelativePath: path,
                    prefix: session.capability.repositoryRelativeLoadedRootPrefix
                ) {
                    manifestRemovals[identity, default: []].append(
                        .remove(repositoryRelativePath: repositoryPath)
                    )
                }
            }
        }
        roots[rootEpoch] = .eligible(session)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let requestIDs = activeRequests.values.filter {
            $0.rootEpoch == rootEpoch && safePaths.contains($0.relativePath)
        }.map(\.id)
        let queuedIDs = queuedRequests.values.filter {
            $0.rootEpoch == rootEpoch && safePaths.contains($0.demand.identity.standardizedRelativePath)
        }.map(\.id)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs + queuedIDs)

        let revoked = await overlay.invalidatePaths(
            rootEpoch: rootEpoch,
            standardizedRelativePaths: safePaths,
            reason: reason
        )
        releaseRetainedAdoptionPaths(safePaths, rootEpoch: rootEpoch)
        pruneAdmissionHistory()
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        var failed = false
        for (pipelineIdentity, mutations) in manifestRemovals where !mutations.isEmpty {
            for batch in boundedManifestMutationBatches(mutations) {
                let submission = await submitManifestMutations(
                    rootEpoch: rootEpoch,
                    pipelineIdentity: pipelineIdentity,
                    mutations: batch,
                    proof: .session(invalidationGeneration: session.invalidationGeneration),
                    retainRecordsInMemory: true
                )
                if case .persisted = submission {
                    continue
                } else {
                    failed = true
                }
            }
        }
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        emit(
            .invalidation,
            rootEpoch: rootEpoch,
            numericValue: UInt64(revoked),
            invalidationReason: reason
        )
        return WorkspaceCodemapBindingInvalidationResult(
            revokedOverlayCount: revoked,
            cancelledRequestCount: cancellationBatch.cancelledRequestCount,
            manifestWriteFailed: failed
        )
    }

    private func invalidateRootAuthority(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapLiveOverlayInvalidationReason
    ) async -> WorkspaceCodemapBindingInvalidationResult {
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
            await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .rootUnloaded)
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            emit(.invalidation, rootEpoch: rootEpoch, invalidationReason: reason)
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        guard case let .eligible(session)? = roots[rootEpoch] else {
            return WorkspaceCodemapBindingInvalidationResult(
                revokedOverlayCount: 0,
                cancelledRequestCount: 0,
                manifestWriteFailed: false
            )
        }
        _ = cancelGraphIndexJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        let requestIDs = activeRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        let queuedIDs = queuedRequests.values.filter { $0.rootEpoch == rootEpoch }.map(\.id)
        roots[rootEpoch] = .unavailable(UnavailableRoot(
            registration: session.registration,
            state: .unresolved
        ))
        detachManifestWriters(rootEpoch: rootEpoch)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs + queuedIDs)
        await runtime.manifestStore.endManifestWriterSession(session.manifestWriterSession)

        let revoked = await overlay.invalidateRootAuthority(
            rootEpoch: rootEpoch,
            expectedAuthority: session.capability.repositoryAuthority,
            reason: reason
        )
        await shutdownGraphRoot(rootEpoch: rootEpoch, reason: .repositoryAuthorityChanged)
        adoptionReservations = adoptionReservations.filter { $0.key.rootEpoch != rootEpoch }
        retainedAdoptions = retainedAdoptions.filter { $0.key.rootEpoch != rootEpoch }
        pruneAdmissionHistory()
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        emit(.invalidation, rootEpoch: rootEpoch, invalidationReason: reason)
        return WorkspaceCodemapBindingInvalidationResult(
            revokedOverlayCount: revoked ? 1 : 0,
            cancelledRequestCount: cancellationBatch.cancelledRequestCount,
            manifestWriteFailed: false
        )
    }

    private func synchronouslyCancelRequests(
        _ requestIDs: [UUID]
    ) -> SynchronousCancellationBatch {
        var overlayCancellations: [OverlayCancellation] = []
        var cancelledRequestCount = 0
        for requestID in requestIDs {
            if let queued = queuedRequests.removeValue(forKey: requestID) {
                queueOrder.removeAll { $0 == requestID }
                queued.continuation?.resume(returning: .cancelled)
                cancelledRequestCount += 1
                continue
            }
            guard var request = activeRequests.removeValue(forKey: requestID), !request.cancelled else { continue }
            request.cancelled = true
            request.task?.cancel()
            if request.ticket != nil || request.preflight != nil {
                overlayCancellations.append(OverlayCancellation(
                    owner: request.overlayOwner,
                    ticket: request.ticket,
                    preflight: request.preflight
                ))
            }
            request.ticket = nil
            request.preflight = nil
            request.continuation?.resume(returning: .cancelled)
            request.continuation = nil
            if let task = request.task {
                drainingRequestTasks[requestID] = task
            }
            cancelledRequestCount += 1
        }
        scheduleQueuedRequests()
        scheduleGraphIndexAdmissions()
        return SynchronousCancellationBatch(
            overlayCancellations: overlayCancellations,
            cancelledRequestCount: cancelledRequestCount
        )
    }

    private func cancelOverlayAssociations(
        _ associations: [OverlayCancellation]
    ) async {
        for association in associations {
            if let owner = association.owner, let ticket = association.ticket {
                _ = await overlay.cancelDemand(owner: owner, ticket: ticket)
            }
            if let preflight = association.preflight {
                _ = await overlay.cancelDemandPreflight(preflight)
            }
        }
    }

    private func makeManifestRecord(
        session: Session,
        pipeline: PipelineSession,
        repositoryRelativePath: String,
        gitMode: CodeMapRootManifestGitMode,
        association: VerifiedGitBlobCodeMapLocatorAssociation,
        bindingGeneration: UInt64
    ) throws -> CodeMapRootManifestRecord {
        let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [] as [String],
                references: [] as [String]
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        return try CodeMapRootManifestRecord.verifiedClean(
            namespace: pipeline.namespace,
            repositoryRelativePath: repositoryRelativePath,
            gitMode: gitMode,
            association: association,
            contribution: contribution,
            authority: pipeline.authority,
            bindingGeneration: bindingGeneration
        )
    }

    private func gitMode(_ classification: GitBlobIdentityClassification) -> CodeMapRootManifestGitMode? {
        guard let mode = classification.indexEntries.first(where: { $0.stage == 0 })?.mode else {
            return nil
        }
        return try? CodeMapRootManifestGitMode(gitValue: mode)
    }

    private func manifestGeneration(_ result: CodeMapRootManifestWriteResult) -> UInt64 {
        switch result {
        case let .inserted(value), let .replaced(value), let .unchanged(value): value
        }
    }

    private func repositoryPath(loadedRootRelativePath: String, prefix: String) -> String? {
        guard let path = safeRelativePath(loadedRootRelativePath) else { return nil }
        return prefix.isEmpty ? path : prefix + "/" + path
    }

    private func loadedRootPath(repositoryRelativePath: String, prefix: String) -> String? {
        guard let path = safeRelativePath(repositoryRelativePath) else { return nil }
        if prefix.isEmpty {
            return path
        }
        guard path.hasPrefix(prefix + "/") else { return nil }
        return String(path.dropFirst(prefix.count + 1))
    }

    private func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let standardized = StandardizedPath.relative(path)
        guard standardized == path,
              standardized != ".",
              standardized != "..",
              !standardized.hasPrefix("../")
        else { return nil }
        return standardized
    }

    private func rootEpochPrecedes(_ lhs: WorkspaceCodemapRootEpoch, _ rhs: WorkspaceCodemapRootEpoch) -> Bool {
        let left = lhs.rootID.uuidString + lhs.rootLifetimeID.uuidString
        let right = rhs.rootID.uuidString + rhs.rootLifetimeID.uuidString
        return left < right
    }

    private func finishRegistrationOperation(_ operationID: UUID) {
        registrationOperations.remove(operationID)
        guard registrationOperations.isEmpty else { return }
        let waiters = registrationDrainWaiters
        registrationDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForRegistrationOperationsToDrain() async {
        guard !registrationOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            registrationDrainWaiters.append(continuation)
        }
    }

    private func waitForShutdownCompletion() async {
        guard !shutdownComplete else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func releaseCapabilityAfterRegistrationFailure(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async {
        if replacementCancelledRegistrationAttemptIDs.remove(attempt.id) != nil {
            return
        }
        await capabilityService.release(rootEpoch: rootEpoch)
    }

    private func registrationAttemptIsCurrent(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> Bool {
        guard case let .registering(current)? = roots[rootEpoch] else { return false }
        return current.id == attempt.id &&
            current.registration == attempt.registration &&
            !current.cancelled
    }

    private func finishRegistrationAttempt(
        _ attempt: RegistrationAttempt,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        guard case let .registering(current)? = roots[rootEpoch], current.id == attempt.id else {
            return
        }
        roots.removeValue(forKey: rootEpoch)
    }

    private func addingChecked(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingChecked(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func incrementCounter(
        _ keyPath: WritableKeyPath<WorkspaceCodemapBindingEngineCounters, UInt64>
    ) {
        addToCounter(keyPath, 1)
    }

    private func addToCounter(
        _ keyPath: WritableKeyPath<WorkspaceCodemapBindingEngineCounters, UInt64>,
        _ amount: UInt64
    ) {
        counters[keyPath: keyPath] = addingSaturating(counters[keyPath: keyPath], amount)
    }

    /// Bulk cancellation transitions emit one path-free aggregate event whose value matches the counter delta.
    private func recordCancellationTelemetry(_ count: Int) {
        guard count > 0 else { return }
        addToCounter(\.cancellations, UInt64(count))
        emit(.cancellation, numericValue: UInt64(count))
    }

    private func recordBusy(_ rootEpoch: WorkspaceCodemapRootEpoch?) {
        incrementCounter(\.busyRejections)
        emit(.busy, rootEpoch: rootEpoch)
    }

    private func recordFailure(_ rootEpoch: WorkspaceCodemapRootEpoch?) {
        incrementCounter(\.failures)
        emit(.failure, rootEpoch: rootEpoch)
    }

    private func emit(
        _ kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch? = nil,
        artifact: CodeMapArtifactKey? = nil,
        numericValue: UInt64 = 0,
        graphIndexPhase: WorkspaceCodemapGraphIndexPhase? = nil,
        retryAfterMilliseconds: UInt64? = nil,
        publishedArtifactLookupSource: WorkspaceCodemapPublishedArtifactLookupSource? = nil,
        publishedArtifactLookupMissReason: WorkspaceCodemapPublishedArtifactLookupMissReason? = nil,
        invalidationReason: WorkspaceCodemapLiveOverlayInvalidationReason? = nil
    ) {
        hooks.event(WorkspaceCodemapBindingEngineHookEvent(
            kind: kind,
            rootEpoch: rootEpoch,
            artifactStorageDigest: artifact?.storageDigestHex,
            numericValue: numericValue,
            graphIndexPhase: graphIndexPhase,
            retryAfterMilliseconds: retryAfterMilliseconds,
            publishedArtifactLookupSource: publishedArtifactLookupSource,
            publishedArtifactLookupMissReason: publishedArtifactLookupMissReason,
            invalidationReason: invalidationReason
        ))
    }
}
