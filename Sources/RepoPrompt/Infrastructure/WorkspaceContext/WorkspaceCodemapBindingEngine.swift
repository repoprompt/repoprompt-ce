import Foundation

/// Inert orchestration for Git-only, artifact-backed workspace codemap bindings.
///
/// One injected instance can own bounded sessions for many roots. It deliberately owns no source
/// catalog and no artifact cache: those remain with the caller and the process-wide artifact runtime.
actor WorkspaceCodemapBindingEngine {
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

    private enum ManifestMutationProof {
        case session(invalidationGeneration: UInt64)
        case projection(jobID: UUID, generation: WorkspaceCodemapProjectionGeneration)
    }

    private enum ManifestMutationSubmissionResult {
        case persisted
        case durabilityFailure
        case retry
        case budget(WorkspaceCodemapProjectionBudget)
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
        let proof: ManifestMutationProof
        let mutations: [ManifestMutation]
        let byteCount: UInt64
    }

    private struct ManifestWriteWaiter {
        let id: UUID
        let workKey: ManifestWriterWorkKey
        let revision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ManifestWriterState {
        var writerID: UUID?
        var task: Task<Void, Never>?
        var queuedWork: [ManifestMutationWorkItem] = []
        var inFlightWork: ManifestMutationWorkItem?
        var inFlightRevision: UInt64?
        var waiters: [ManifestWriteWaiter] = []
    }

    private struct ProjectionAdmissionWaiter {
        let jobID: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        var enqueueOrdinal: UInt64
        var demandOvertakeRecorded: Bool
        var explicitOvertakeRecorded: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct ProjectionDemandRecord {
        let ticket: WorkspaceCodemapProjectionDemandTicket
        let owner: WorkspaceCodemapLiveDemandOwner
        let fileIDs: [UUID]
        let deadlineUptimeNanoseconds: UInt64
        var enqueueOrdinal: UInt64
        let metadataByteCount: UInt64
    }

    private struct TerminalProjectionDemandRecord {
        let ticket: WorkspaceCodemapProjectionDemandTicket
        let status: WorkspaceCodemapProjectionDemandStatus
        let terminalOrdinal: UInt64
    }

    private struct ProjectionPreloadJob {
        let id: UUID
        let rootEpoch: WorkspaceCodemapRootEpoch
        let sessionID: UUID
        let sessionGeneration: UInt64
        let invalidationGeneration: UInt64
        let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
        let catalogGeneration: UInt64
        let ingressGeneration: UInt64
        var phase: WorkspaceCodemapProjectionPreloadPhase
        var generation: WorkspaceCodemapProjectionGeneration?
        var cursor: WorkspaceCodemapProjectionCatalogCursor?
        var lastProcessedCursor: WorkspaceCodemapProjectionCatalogCursor?
        var progress: WorkspaceCodemapProjectionProgress
        var nextSegmentSequence: UInt64
        var pipelineScopes: [CodeMapPipelineIdentity: WorkspaceCodemapProjectionPipelineScope]
        var resources: WorkspaceCodemapProjectionResourceAccounting
        var pendingManifestMutationCount: UInt64
        var retryAttempt: UInt64
        var retry: WorkspaceCodemapProjectionRetry?
        var budget: WorkspaceCodemapProjectionBudget?
        var checkpoint: WorkspaceCodemapProjectionPreloadCheckpoint?
        var coverageProof: WorkspaceCodemapProjectionCoverageProof?
        var coverageCompletedUptimeNanoseconds: UInt64?
        var task: Task<Void, Never>?
        var isQueuedForAdmission: Bool
        var isActiveBatch: Bool
    }

    private enum ProjectionCandidateResolution {
        case entry(WorkspaceCodemapProjectionEntry, manifestRecord: CodeMapRootManifestRecord?)
        case transient
        case budget(WorkspaceCodemapProjectionBudget)
    }

    private enum ProjectionBatchResult {
        case checkpointed
        case complete
        case retry
        case restartGeneration
        case restartPage
        case budgetLimited
        case cancelled
        case superseded
    }

    private enum ProjectionResourceReservationResult {
        case reserved
        case retry
        case budget(WorkspaceCodemapProjectionBudget)
    }

    private enum ProjectionPublicationStalenessResult {
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
    private let policy: WorkspaceCodemapBindingEnginePolicy
    private let hooks: WorkspaceCodemapBindingEngineHooks
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
    private var projectionJobs: [WorkspaceCodemapRootEpoch: ProjectionPreloadJob] = [:]
    private var latestOverlayContributionGenerationByRootEpoch: [
        WorkspaceCodemapRootEpoch: WorkspaceCodemapSelectionGraphContributionGeneration
    ] = [:]
    private var projectionAdmissionQueue: [ProjectionAdmissionWaiter] = []
    private var activeProjectionJobIDs: Set<UUID> = []
    private var drainingProjectionTasks: [UUID: Task<Void, Never>] = [:]
    private var drainingProjectionResources: [UUID: WorkspaceCodemapProjectionResourceAccounting] = [:]
    private var drainingProjectionRootEpochs: [UUID: WorkspaceCodemapRootEpoch] = [:]
    private var nextProjectionQueueOrdinal: UInt64 = 1
    private var projectionRootLastAdmission: [WorkspaceCodemapRootEpoch: UInt64] = [:]
    private var projectionDemands: [UUID: ProjectionDemandRecord] = [:]
    private var terminalProjectionDemands: [UUID: TerminalProjectionDemandRecord] = [:]
    private var nextProjectionDemandOrdinal: UInt64 = 1
    private var nextTerminalProjectionDemandOrdinal: UInt64 = 1
    private var registrationOperations: Set<UUID> = []
    private var replacementCancelledRegistrationAttemptIDs: Set<UUID> = []
    private var registrationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false
    private var shutdownComplete = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var counters = WorkspaceCodemapBindingEngineCounters()
    #if DEBUG
        private struct DebugProjectionAdmissionHold {
            let rootEpoch: WorkspaceCodemapRootEpoch
            let expiryTask: Task<Void, Never>
        }

        private var debugProjectionAdmissionHolds: [UUID: DebugProjectionAdmissionHold] = [:]
        private var debugProjectionAdmissionEnqueuedAtNanoseconds: [UUID: UInt64] = [:]
        private var debugProjectionQueueWaitMillisecondsByRootEpoch: [
            WorkspaceCodemapRootEpoch: [UInt64]
        ] = [:]
        private var debugProjectionQueueWaitSampleOrdinalByRootEpoch: [
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
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
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
        self.policy = policy
        self.hooks = hooks
        nextQueueOrdinal = max(1, initialQueueOrdinal)
        nextAdmissionOrdinal = max(1, initialAdmissionOrdinal)
        counters = WorkspaceCodemapBindingEngineCounters(initialValue: initialCounterValue)
        self.uptimeNanoseconds = uptimeNanoseconds
        self.accessEpochSeconds = accessEpochSeconds
    }

    func registerRoot(
        _ registration: WorkspaceCodemapBindingRootRegistration
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
            revokeProjectionDemands(
                rootEpoch: rootEpoch,
                status: .unavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil)
            )
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
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await releaseCapabilityAfterRegistrationFailure(attempt, rootEpoch: rootEpoch)
            finishRegistrationAttempt(attempt, rootEpoch: rootEpoch)
            recordFailure(rootEpoch)
            return .failed
        }
        guard !Task.isCancelled, registrationAttemptIsCurrent(attempt, rootEpoch: rootEpoch) else {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
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
        activateProjectionDemands(rootEpoch: rootEpoch)
        emit(.capabilityEligible, rootEpoch: rootEpoch)
        return .registered(adoptedReadyCount: 0)
    }

    /// Hands an already-public, Git-eligible root to the projection preloader.
    ///
    /// Root readiness scheduling remains owned by `WorkspaceFileContextStore`; this method is
    /// deliberately idempotent and never performs catalog, manifest, CAS, or source work inline.
    @discardableResult
    func scheduleProjectionPreload(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapProjectionPreloadLaunchPhase {
        guard !isShuttingDown else { return .cancelled }
        guard case let .eligible(session)? = roots[rootEpoch] else { return .superseded }
        if let existing = projectionJobs[rootEpoch] {
            if existing.phase == .superseded { return .superseded }
            if existing.phase == .cancelled { return .cancelled }
            return projectionJobIsCurrent(existing) ? .handedOff : .superseded
        }

        let jobID = UUID()
        projectionJobs[rootEpoch] = ProjectionPreloadJob(
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
            nextSegmentSequence: 0,
            pipelineScopes: [:],
            resources: .zero,
            pendingManifestMutationCount: 0,
            retryAttempt: 0,
            retry: nil,
            budget: nil,
            checkpoint: nil,
            coverageProof: nil,
            coverageCompletedUptimeNanoseconds: nil,
            task: nil,
            isQueuedForAdmission: false,
            isActiveBatch: false
        )
        incrementCounter(\.projectionPreloadsScheduled)
        emit(.projectionPreloadScheduled, rootEpoch: rootEpoch, projectionPhase: .scheduled)
        let task = Task(priority: .background) {
            await self.runProjectionPreload(jobID: jobID, rootEpoch: rootEpoch)
        }
        guard var job = projectionJobs[rootEpoch], job.id == jobID else {
            task.cancel()
            return .superseded
        }
        job.task = task
        projectionJobs[rootEpoch] = job
        return .handedOff
    }

    func acquireProjectionDemand(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileIDs: [UUID],
        catalogGeneration: UInt64,
        ingressGeneration: UInt64,
        deadlineUptimeNanoseconds: UInt64,
        owner: WorkspaceCodemapLiveDemandOwner
    ) -> WorkspaceCodemapProjectionDemandAcquisition {
        expireProjectionDemands()
        guard !isShuttingDown else {
            return .unavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil)
        }
        let registration: WorkspaceCodemapBindingRootRegistration
        switch roots[rootEpoch] {
        case let .registering(attempt):
            registration = attempt.registration
        case let .eligible(session):
            registration = session.registration
        case .unavailable:
            return .unavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil)
        case nil:
            return .unavailable(reason: .rootNotRegistered, retryAfterMilliseconds: nil)
        }
        guard registration.catalogGeneration == catalogGeneration,
              registration.ingressGeneration == ingressGeneration
        else {
            return .unavailable(reason: .generationMismatch, retryAfterMilliseconds: nil)
        }

        let uniqueFileIDs = Array(Set(fileIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueFileIDs.isEmpty else {
            return .unavailable(reason: .generationMismatch, retryAfterMilliseconds: nil)
        }
        guard uniqueFileIDs.count <= policy.maximumProjectionDemandFileIDCount else {
            recordProjectionDemandBusy(rootEpoch: rootEpoch)
            return .busy(
                reason: .fileIDLimit(
                    attempted: uniqueFileIDs.count,
                    limit: policy.maximumProjectionDemandFileIDCount
                ),
                retryAfterMilliseconds: policy.projectionDemandRetryMilliseconds
            )
        }
        let metadataByteCount: UInt64
        guard let fileIDCount = UInt64(exactly: uniqueFileIDs.count) else {
            recordProjectionDemandBusy(rootEpoch: rootEpoch)
            return .busy(
                reason: .metadataByteLimit(attempted: .max, limit: policy.maximumProjectionDemandMetadataByteCount),
                retryAfterMilliseconds: policy.projectionDemandRetryMilliseconds
            )
        }
        let (fileIDBytes, fileIDBytesOverflow) = fileIDCount.multipliedReportingOverflow(by: 16)
        guard !fileIDBytesOverflow, let retainedBytes = addingChecked(fileIDBytes, 192) else {
            recordProjectionDemandBusy(rootEpoch: rootEpoch)
            return .busy(
                reason: .metadataByteLimit(attempted: .max, limit: policy.maximumProjectionDemandMetadataByteCount),
                retryAfterMilliseconds: policy.projectionDemandRetryMilliseconds
            )
        }
        metadataByteCount = retainedBytes
        let rootRecords = projectionDemands.values.filter { $0.ticket.rootEpoch == rootEpoch }
        guard projectionDemands.count < policy.maximumProjectionDemandCount,
              rootRecords.count < policy.maximumProjectionDemandCountPerRoot
        else {
            recordProjectionDemandBusy(rootEpoch: rootEpoch)
            return .busy(
                reason: .requestLimit,
                retryAfterMilliseconds: policy.projectionDemandRetryMilliseconds
            )
        }
        let rootMetadataBytes = rootRecords.reduce(UInt64(0)) {
            addingSaturating($0, $1.metadataByteCount)
        }
        let globalMetadataBytes = projectionDemands.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.metadataByteCount)
        }
        let attemptedRootBytes = addingSaturating(rootMetadataBytes, metadataByteCount)
        let attemptedGlobalBytes = addingSaturating(globalMetadataBytes, metadataByteCount)
        guard attemptedRootBytes <= policy.maximumProjectionDemandMetadataByteCountPerRoot,
              attemptedGlobalBytes <= policy.maximumProjectionDemandMetadataByteCount
        else {
            recordProjectionDemandBusy(rootEpoch: rootEpoch)
            let attempted = max(attemptedRootBytes, attemptedGlobalBytes)
            let limit = attemptedRootBytes > policy.maximumProjectionDemandMetadataByteCountPerRoot
                ? policy.maximumProjectionDemandMetadataByteCountPerRoot
                : policy.maximumProjectionDemandMetadataByteCount
            return .busy(
                reason: .metadataByteLimit(attempted: attempted, limit: limit),
                retryAfterMilliseconds: policy.projectionDemandRetryMilliseconds
            )
        }
        ensureProjectionDemandOrdinalCapacity()
        let ticket = WorkspaceCodemapProjectionDemandTicket(
            rootEpoch: rootEpoch,
            catalogGeneration: catalogGeneration,
            ingressGeneration: ingressGeneration
        )
        let ordinal = nextProjectionDemandOrdinal
        nextProjectionDemandOrdinal = addingChecked(nextProjectionDemandOrdinal, 1) ?? .max
        let joinedExistingFlight = projectionJobs[rootEpoch] != nil
        projectionDemands[ticket.id] = ProjectionDemandRecord(
            ticket: ticket,
            owner: owner,
            fileIDs: uniqueFileIDs,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            enqueueOrdinal: ordinal,
            metadataByteCount: metadataByteCount
        )
        incrementCounter(\.projectionDemandsAcquired)
        if joinedExistingFlight {
            incrementCounter(\.projectionDemandsJoined)
        }
        let status = projectionDemandStatusValue(ticket)
        scheduleQueuedRequests()
        scheduleProjectionAdmissions()
        return .acquired(ticket: ticket, status: status)
    }

    func projectionDemandStatus(
        _ ticket: WorkspaceCodemapProjectionDemandTicket
    ) -> WorkspaceCodemapProjectionDemandStatus {
        projectionDemandStatusValue(ticket)
    }

    func releaseProjectionDemand(_ ticket: WorkspaceCodemapProjectionDemandTicket) {
        guard let record = projectionDemands[ticket.id], record.ticket == ticket else {
            terminalProjectionDemands.removeValue(forKey: ticket.id)
            return
        }
        projectionDemands.removeValue(forKey: ticket.id)
        incrementCounter(\.projectionDemandsReleased)
        pruneAdmissionHistory()
        scheduleProjectionAdmissions()
    }

    func demand(_ demand: WorkspaceCodemapBindingDemand) async -> WorkspaceCodemapBindingDemandResult {
        let requestID = UUID()
        let cancellation = DemandCancellationState()
        return await withTaskCancellationHandler {
            if Task.isCancelled || cancellation.isCancelled { return .cancelled }
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
    /// Targeted invalidation removes the path projection or changes its generation, so the
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
                source = .projectionCAS
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
        case .projectionCAS:
            incrementCounter(\.publishedArtifactProjectionCASHits)
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
        await invalidateRootAuthority(rootEpoch: rootEpoch, reason: .watcherGap)
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
        revokeProjectionDemands(rootEpoch: rootEpoch, status: .cancelled)
        if case .registering? = roots[rootEpoch] {
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.release(rootEpoch: rootEpoch)
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
        _ = cancelProjectionJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        let projectionTasks = drainingProjectionTasks.compactMap { jobID, task in
            drainingProjectionRootEpochs[jobID] == rootEpoch ? task : nil
        }
        roots.removeValue(forKey: rootEpoch)
        detachManifestWriters(rootEpoch: rootEpoch)
        detachManifestAdoptionOperations(rootEpoch: rootEpoch)
        let cancellationBatch = synchronouslyCancelRequests(requestIDs)
        if let manifestWriterSession {
            await runtime.manifestStore.endManifestWriterSession(manifestWriterSession)
        }
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        _ = await overlay.unregister(rootEpoch: rootEpoch)
        adoptionReservations = adoptionReservations.filter { $0.key.rootEpoch != rootEpoch }
        retainedAdoptions = retainedAdoptions.filter { $0.key.rootEpoch != rootEpoch }
        pruneAdmissionHistory()
        recordCancellationTelemetry(cancellationBatch.cancelledRequestCount)
        for task in projectionTasks {
            await task.value
        }
        await capabilityService.release(rootEpoch: rootEpoch)
        emit(.rootUnload, rootEpoch: rootEpoch)
    }

    func shutdown() async {
        if shutdownComplete { return }
        if isShuttingDown {
            await waitForShutdownCompletion()
            return
        }

        isShuttingDown = true
        #if DEBUG
            for hold in debugProjectionAdmissionHolds.values {
                hold.expiryTask.cancel()
            }
            debugProjectionAdmissionHolds.removeAll()
            debugProjectionAdmissionEnqueuedAtNanoseconds.removeAll()
        #endif
        let rootEpochs = Array(roots.keys)
        for rootEpoch in rootEpochs {
            revokeProjectionDemands(rootEpoch: rootEpoch, status: .cancelled)
            _ = cancelProjectionJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
        }
        let projectionTasks = Array(drainingProjectionTasks.values)
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

        for writerSession in manifestWriterSessions {
            await runtime.manifestStore.endManifestWriterSession(writerSession)
        }
        await cancelOverlayAssociations(cancellationBatch.overlayCancellations)
        for rootEpoch in rootEpochs {
            _ = await overlay.unregister(rootEpoch: rootEpoch)
            await capabilityService.release(rootEpoch: rootEpoch)
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
        for task in projectionTasks {
            await task.value
        }
        await waitForRegistrationOperationsToDrain()
        await capabilityService.drain()

        adoptionReservations.removeAll()
        retainedAdoptions.removeAll()
        drainingManifestAdoptionTasks.removeAll()
        drainingRequestTasks.removeAll()
        drainingProjectionTasks.removeAll()
        drainingProjectionResources.removeAll()
        drainingProjectionRootEpochs.removeAll()
        projectionAdmissionQueue.removeAll()
        activeProjectionJobIDs.removeAll()
        projectionRootLastAdmission.removeAll()
        projectionDemands.removeAll()
        terminalProjectionDemands.removeAll()
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

    func prepareCompletedProjectionSuccessor(
        rootEpoch: WorkspaceCodemapRootEpoch,
        liveSnapshot: WorkspaceCodemapLiveGraphSnapshot
    ) async -> WorkspaceCodemapProjectionSuccessorSeal? {
        guard liveSnapshot.rootEpoch == rootEpoch else { return nil }
        observeOverlayContributionGeneration(
            liveSnapshot.contributionGeneration,
            rootEpoch: rootEpoch
        )
        guard let job = projectionJobs[rootEpoch],
              job.phase == .complete,
              let predecessorProof = job.coverageProof,
              projectionJobAuthorityIsCurrent(job),
              predecessorProof.generation == job.generation,
              liveSnapshot.rootEpoch == rootEpoch,
              liveSnapshot.catalogGeneration == job.catalogGeneration,
              liveSnapshot.repositoryAuthority == job.repositoryAuthority,
              let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch),
              overlaySnapshot.authorityIsCurrent,
              overlaySnapshot.catalogGeneration == liveSnapshot.catalogGeneration,
              overlaySnapshot.repositoryAuthority == liveSnapshot.repositoryAuthority,
              overlaySnapshot.contributionGeneration == liveSnapshot.contributionGeneration,
              let currentJob = projectionJobs[rootEpoch],
              currentJob.id == job.id,
              currentJob.phase == .complete,
              currentJob.coverageProof == predecessorProof,
              projectionJobAuthorityIsCurrent(currentJob),
              let successorProof = predecessorProof.successor(
                  contributionGeneration: liveSnapshot.contributionGeneration
              )
        else { return nil }
        return WorkspaceCodemapProjectionSuccessorSeal(
            predecessorProof: predecessorProof,
            successorProof: successorProof
        )
    }

    func commitCompletedProjectionSuccessor(
        _ seal: WorkspaceCodemapProjectionSuccessorSeal
    ) -> Bool {
        let rootEpoch = seal.predecessorProof.generation.rootEpoch
        guard var job = projectionJobs[rootEpoch],
              job.phase == .complete,
              job.generation == seal.predecessorProof.generation,
              job.coverageProof == seal.predecessorProof,
              projectionJobAuthorityIsCurrent(job),
              latestOverlayContributionGenerationByRootEpoch[rootEpoch] ==
              seal.successorProof.generation.contributionGeneration,
              seal.predecessorProof.successor(
                  contributionGeneration: seal.successorProof.generation.contributionGeneration
              ) == seal.successorProof
        else { return false }
        job.generation = seal.successorProof.generation
        job.coverageProof = seal.successorProof
        job.coverageCompletedUptimeNanoseconds = uptimeNanoseconds()
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
        activateProjectionDemands(rootEpoch: rootEpoch)
        return true
    }

    @discardableResult
    func restartCompletedProjectionForOverlayAdvance(
        rootEpoch: WorkspaceCodemapRootEpoch,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    ) -> Bool {
        observeOverlayContributionGeneration(contributionGeneration, rootEpoch: rootEpoch)
        guard let job = projectionJobs[rootEpoch],
              job.phase == .complete,
              job.task == nil,
              let proof = job.coverageProof,
              proof.generation.contributionGeneration < contributionGeneration,
              resetProjectionForLatestGeneration(
                  jobID: job.id,
                  rootEpoch: rootEpoch,
                  recordSupersession: true
              )
        else { return false }
        incrementCounter(\.projectionPreloadsScheduled)
        emit(.projectionPreloadScheduled, rootEpoch: rootEpoch, projectionPhase: .scheduled)
        let task = Task(priority: .background) {
            await self.runProjectionPreload(jobID: job.id, rootEpoch: rootEpoch)
        }
        guard var current = projectionJobs[rootEpoch], current.id == job.id else {
            task.cancel()
            return false
        }
        current.task = task
        projectionJobs[rootEpoch] = current
        return true
    }

    func waitForCurrentProjectionCoverage(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        var remainingTaskBoundaries = 2
        while !Task.isCancelled, remainingTaskBoundaries > 0 {
            guard let job = projectionJobs[rootEpoch],
                  projectionJobAuthorityIsCurrent(job)
            else { return false }
            guard let task = job.task else {
                return job.phase == .complete && projectionJobIsCurrent(job)
            }
            remainingTaskBoundaries -= 1
            await task.value
        }
        guard !Task.isCancelled,
              let job = projectionJobs[rootEpoch],
              job.task == nil
        else { return false }
        return job.phase == .complete && projectionJobIsCurrent(job)
    }

    func planAutomaticSelectionCandidates(
        _ request: WorkspaceCodemapBindingAutomaticSelectionPlanRequest
    ) async -> WorkspaceCodemapBindingAutomaticSelectionPlanDisposition {
        guard request.maximumMatchedCandidateCount >= 0 else {
            return .budget(
                dimension: .catalogEntries,
                attempted: 0,
                limit: 0
            )
        }
        guard case let .eligible(initial)? = roots[request.rootEpoch],
              initial.registration.catalogGeneration > 0,
              initial.registration.ingressGeneration > 0
        else { return .unavailable(.rootUnloaded) }
        guard let preload = projectionJobs[request.rootEpoch] else {
            return .incomplete(
                progress: .notStarted,
                remainingCount: UInt64(request.candidates.count),
                retry: nil
            )
        }
        guard preload.phase == .complete, let coverageProof = preload.coverageProof else {
            if let budget = preload.budget {
                return .budget(
                    dimension: budget.dimension,
                    attempted: budget.attempted,
                    limit: budget.limit
                )
            }
            let processed = preload.progress.counts.processedCandidateCount
            let supported = preload.progress.counts.supportedCandidateCount
            let remaining = supported >= processed ? supported - processed : nil
            if let provisional = await provisionalAutomaticSelectionPlan(
                request,
                progress: preload.progress,
                remainingCount: remaining,
                retry: preload.retry
            ) {
                return provisional
            }
            if preload.phase == .suspendedBusy {
                return .busy(
                    progress: preload.progress,
                    retryAfterMilliseconds: preload.retry?.retryAfterMilliseconds
                )
            }
            return .incomplete(
                progress: preload.progress,
                remainingCount: remaining,
                retry: preload.retry
            )
        }
        guard request.sourceTickets.allSatisfy({ ticket in
            ticket.rootEpoch == request.rootEpoch &&
                ticket.catalogGeneration == initial.registration.catalogGeneration &&
                ticket.ingressGeneration == initial.registration.ingressGeneration
        }), request.candidates.allSatisfy({ candidate in
            candidate.identity.rootID == request.rootEpoch.rootID &&
                candidate.identity.rootLifetimeID == request.rootEpoch.rootLifetimeID &&
                candidate.identity.standardizedRootPath == initial.registration.capabilityRequest.loadedRootURL.path &&
                candidate.catalogGeneration == initial.registration.catalogGeneration &&
                candidate.ingressGeneration == initial.registration.ingressGeneration
        }) else { return .stale }
        let uniqueCandidateFileIDs = Set(request.candidates.map(\.identity.fileID))
        guard uniqueCandidateFileIDs.count == request.candidates.count,
              UInt64(request.candidates.count) == coverageProof.candidateCount
        else { return .stale }

        var pipelineIdentitiesByLanguage: [LanguageType: CodeMapPipelineIdentity] = [:]
        do {
            for language in Set(request.candidates.map(\.language)) {
                let pipelineIdentity = try ensurePipeline(
                    rootEpoch: request.rootEpoch,
                    language: language
                )
                pipelineIdentitiesByLanguage[language] = pipelineIdentity
            }
        } catch {
            return .unavailable(.notBuilt)
        }
        guard case let .eligible(session)? = roots[request.rootEpoch],
              session.registration == initial.registration
        else { return .stale }

        guard let bundle = await overlay.freeze(rootEpoch: request.rootEpoch) else {
            return .incomplete(
                progress: preload.progress,
                remainingCount: nil,
                retry: preload.retry
            )
        }
        defer { bundle.close() }
        guard let graphSnapshot = try? bundle.graphSnapshot() else { return .stale }
        guard coverageProof.generation.contributionGeneration == graphSnapshot.contributionGeneration else {
            return .incomplete(
                progress: preload.progress,
                remainingCount: 0,
                retry: preload.retry
            )
        }
        var sourceReferences = Set<String>()
        for ticket in request.sourceTickets {
            guard let binding = graphSnapshot.bindings.first(where: { binding in
                guard case let .resolved(completion) = binding.availability else { return false }
                return completion.token.identity.fileID == ticket.fileID &&
                    completion.token.requestGeneration == ticket.requestGeneration
            }), case let .resolved(completion) = binding.availability
            else {
                return .incomplete(
                    progress: preload.progress,
                    remainingCount: nil,
                    retry: preload.retry
                )
            }
            switch completion.outcome {
            case let .ready(artifact):
                sourceReferences.formUnion(CodeMapSelectionGraphContribution(
                    artifactKey: completion.artifactKey,
                    artifact: artifact
                ).sortedUniqueReferences)
            case .readyNoSymbols:
                break
            case .oversize, .decodeFailed, .parseFailed:
                return .unavailable(.corrupt)
            }
        }

        var necessary: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var necessaryByteCount: UInt64 = 0
        var indexedCandidateCount = 0
        var hasMissingOrStaleContribution = false
        let orderedCandidates = request.candidates.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return $0.identity.standardizedRelativePath < $1.identity.standardizedRelativePath
            }
            return $0.identity.fileID.uuidString < $1.identity.fileID.uuidString
        }
        for candidate in orderedCandidates {
            guard let pipelineIdentity = pipelineIdentitiesByLanguage[candidate.language],
                  let pipeline = session.pipelines[pipelineIdentity]
            else {
                hasMissingOrStaleContribution = true
                continue
            }
            let currentPathGeneration = session.pathGenerations[
                candidate.identity.standardizedRelativePath
            ] ?? session.registration.ingressGeneration
            guard candidate.requestGeneration == candidate.pathGeneration,
                  candidate.pathGeneration == currentPathGeneration
            else {
                hasMissingOrStaleContribution = true
                continue
            }
            let repositoryRelativePath = repositoryPath(
                loadedRootRelativePath: candidate.identity.standardizedRelativePath,
                prefix: session.capability.repositoryRelativeLoadedRootPrefix
            )
            guard let repositoryRelativePath,
                  let record = pipeline.automaticSelectionCandidateRecords[repositoryRelativePath],
                  record.bindingGeneration == candidate.requestGeneration,
                  let envelope = record.contributionEnvelope
            else {
                hasMissingOrStaleContribution = true
                continue
            }
            guard envelope.identity.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion,
                  envelope.identity.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion
            else {
                hasMissingOrStaleContribution = true
                continue
            }
            guard let nextIndexedCandidateCount = addingChecked(indexedCandidateCount, 1) else {
                return .budget(dimension: .catalogEntries, attempted: .max, limit: .max - 1)
            }
            indexedCandidateCount = nextIndexedCandidateCount
            if !sourceReferences.isDisjoint(with: envelope.sortedUniqueDefinitions) {
                guard necessary.count < request.maximumMatchedCandidateCount else {
                    return .budget(
                        dimension: .catalogEntries,
                        attempted: UInt64(necessary.count + 1),
                        limit: UInt64(request.maximumMatchedCandidateCount)
                    )
                }
                let candidateByteCount = automaticSelectionCandidateByteCount(candidate)
                let attemptedByteCount = addingSaturating(
                    necessaryByteCount,
                    candidateByteCount
                )
                guard attemptedByteCount >= necessaryByteCount,
                      attemptedByteCount <= policy.maximumAutomaticSelectionMatchedCandidateByteCount
                else {
                    return .budget(
                        dimension: .retainedProjectionBytes,
                        attempted: attemptedByteCount,
                        limit: policy.maximumAutomaticSelectionMatchedCandidateByteCount
                    )
                }
                necessaryByteCount = attemptedByteCount
                necessary.append(candidate)
            }
        }
        guard !hasMissingOrStaleContribution,
              projectionJobs[request.rootEpoch]?.coverageProof == coverageProof,
              coverageProof.generation.contributionGeneration == graphSnapshot.contributionGeneration
        else { return .stale }
        return .ready(WorkspaceCodemapBindingAutomaticSelectionPlan(
            necessaryCandidates: necessary,
            indexedCandidateCount: indexedCandidateCount,
            coverageProof: coverageProof
        ))
    }

    private func automaticSelectionCandidateByteCount(
        _ candidate: WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate
    ) -> UInt64 {
        var bytes: UInt64 = 160
        bytes = addingSaturating(bytes, UInt64(candidate.identity.standardizedRootPath.utf8.count))
        bytes = addingSaturating(bytes, UInt64(candidate.identity.standardizedRelativePath.utf8.count))
        bytes = addingSaturating(bytes, UInt64(candidate.identity.standardizedFullPath.utf8.count))
        return bytes
    }

    private func provisionalAutomaticSelectionPlan(
        _ request: WorkspaceCodemapBindingAutomaticSelectionPlanRequest,
        progress: WorkspaceCodemapProjectionProgress,
        remainingCount: UInt64?,
        retry: WorkspaceCodemapProjectionRetry?
    ) async -> WorkspaceCodemapBindingAutomaticSelectionPlanDisposition? {
        guard case let .eligible(initial)? = roots[request.rootEpoch],
              request.sourceTickets.allSatisfy({ ticket in
                  ticket.rootEpoch == request.rootEpoch &&
                      ticket.catalogGeneration == initial.registration.catalogGeneration &&
                      ticket.ingressGeneration == initial.registration.ingressGeneration
              }),
              request.candidates.allSatisfy({ candidate in
                  candidate.identity.rootID == request.rootEpoch.rootID &&
                      candidate.identity.rootLifetimeID == request.rootEpoch.rootLifetimeID &&
                      candidate.identity.standardizedRootPath ==
                      initial.registration.capabilityRequest.loadedRootURL.path &&
                      candidate.catalogGeneration == initial.registration.catalogGeneration &&
                      candidate.ingressGeneration == initial.registration.ingressGeneration
              }),
              Set(request.candidates.map(\.identity.fileID)).count == request.candidates.count
        else { return nil }

        var pipelineIdentitiesByLanguage: [LanguageType: CodeMapPipelineIdentity] = [:]
        do {
            for language in Set(request.candidates.map(\.language)) {
                pipelineIdentitiesByLanguage[language] = try ensurePipeline(
                    rootEpoch: request.rootEpoch,
                    language: language
                )
            }
        } catch {
            return nil
        }
        guard case let .eligible(session)? = roots[request.rootEpoch],
              session.registration == initial.registration,
              let bundle = await overlay.freeze(rootEpoch: request.rootEpoch)
        else { return nil }
        defer { bundle.close() }
        guard let graphSnapshot = try? bundle.graphSnapshot() else { return nil }
        var sourceReferences = Set<String>()
        for ticket in request.sourceTickets {
            guard let binding = graphSnapshot.bindings.first(where: { binding in
                guard case let .resolved(completion) = binding.availability else { return false }
                return completion.token.identity.fileID == ticket.fileID &&
                    completion.token.requestGeneration == ticket.requestGeneration
            }), case let .resolved(completion) = binding.availability
            else { return nil }
            switch completion.outcome {
            case let .ready(artifact):
                sourceReferences.formUnion(CodeMapSelectionGraphContribution(
                    artifactKey: completion.artifactKey,
                    artifact: artifact
                ).sortedUniqueReferences)
            case .readyNoSymbols:
                break
            case .oversize, .decodeFailed, .parseFailed:
                return nil
            }
        }

        var necessary: [WorkspaceCodemapBindingAutomaticSelectionCatalogCandidate] = []
        var necessaryByteCount: UInt64 = 0
        var indexedCandidateCount = 0
        let orderedCandidates = request.candidates.sorted {
            if $0.identity.standardizedRelativePath != $1.identity.standardizedRelativePath {
                return $0.identity.standardizedRelativePath < $1.identity.standardizedRelativePath
            }
            return $0.identity.fileID.uuidString < $1.identity.fileID.uuidString
        }
        for candidate in orderedCandidates {
            guard let pipelineIdentity = pipelineIdentitiesByLanguage[candidate.language],
                  let pipeline = session.pipelines[pipelineIdentity]
            else { continue }
            let currentPathGeneration = session.pathGenerations[
                candidate.identity.standardizedRelativePath
            ] ?? session.registration.ingressGeneration
            guard candidate.requestGeneration == candidate.pathGeneration,
                  candidate.pathGeneration == currentPathGeneration,
                  let repositoryRelativePath = repositoryPath(
                      loadedRootRelativePath: candidate.identity.standardizedRelativePath,
                      prefix: session.capability.repositoryRelativeLoadedRootPrefix
                  ),
                  let record = pipeline.automaticSelectionCandidateRecords[repositoryRelativePath],
                  record.bindingGeneration == candidate.requestGeneration,
                  let envelope = record.contributionEnvelope,
                  envelope.identity.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion,
                  envelope.identity.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion
            else { continue }
            guard let nextIndexedCandidateCount = addingChecked(indexedCandidateCount, 1) else {
                return .budget(dimension: .catalogEntries, attempted: .max, limit: .max - 1)
            }
            indexedCandidateCount = nextIndexedCandidateCount
            guard !sourceReferences.isDisjoint(with: envelope.sortedUniqueDefinitions) else { continue }
            guard necessary.count < request.maximumMatchedCandidateCount else {
                return .budget(
                    dimension: .catalogEntries,
                    attempted: UInt64(necessary.count + 1),
                    limit: UInt64(request.maximumMatchedCandidateCount)
                )
            }
            let candidateByteCount = automaticSelectionCandidateByteCount(candidate)
            let attemptedByteCount = addingSaturating(necessaryByteCount, candidateByteCount)
            guard attemptedByteCount >= necessaryByteCount,
                  attemptedByteCount <= policy.maximumAutomaticSelectionMatchedCandidateByteCount
            else {
                return .budget(
                    dimension: .retainedProjectionBytes,
                    attempted: attemptedByteCount,
                    limit: policy.maximumAutomaticSelectionMatchedCandidateByteCount
                )
            }
            necessaryByteCount = attemptedByteCount
            necessary.append(candidate)
        }
        return .provisional(
            necessaryCandidates: necessary,
            indexedCandidateCount: indexedCandidateCount,
            progress: progress,
            remainingCount: remainingCount,
            retry: retry
        )
    }

    func accounting() -> WorkspaceCodemapBindingEngineAccounting {
        expireProjectionDemands()
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
        owners.formUnion(projectionDemands.values.map(\.owner))
        let reservedSourceBytes = activeRequests.values.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let adoptionUsage = adoptionLeaseUsage()
        let projectionRoots: [WorkspaceCodemapBindingEngineProjectionRootAccounting] = projectionJobs.values.sorted {
            rootEpochPrecedes($0.rootEpoch, $1.rootEpoch)
        }.map { job -> WorkspaceCodemapBindingEngineProjectionRootAccounting in
            let drainingResources = drainingProjectionResources.reduce(
                WorkspaceCodemapProjectionResourceAccounting.zero
            ) { partial, element in
                guard drainingProjectionRootEpochs[element.key] == job.rootEpoch else { return partial }
                switch partial.adding(element.value) {
                case let .success(value):
                    return value
                case .failure:
                    return WorkspaceCodemapProjectionResourceAccounting(
                        retainedPathBytes: .max,
                        retainedSourceBytes: .max,
                        retainedProjectionBytes: .max,
                        stagedGraphBytes: .max,
                        residentGraphBytes: .max,
                        queuedManifestMutationBytes: .max
                    )
                }
            }
            let rootResources = switch job.resources.adding(drainingResources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapProjectionResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedProjectionBytes: .max,
                    stagedGraphBytes: .max,
                    residentGraphBytes: .max,
                    queuedManifestMutationBytes: .max
                )
            }
            return WorkspaceCodemapBindingEngineProjectionRootAccounting(
                rootEpoch: job.rootEpoch,
                phase: job.phase,
                progress: job.progress,
                queuedBatchCount: job.isQueuedForAdmission ? 1 : 0,
                activeBatchCount: activeProjectionBatchCount(rootEpoch: job.rootEpoch),
                drainingBatchCount: drainingProjectionRootEpochs.values.count(where: {
                    $0 == job.rootEpoch
                }),
                resources: rootResources,
                retry: job.retry,
                budget: job.budget,
                retainedDemandCount: projectionDemands.values.count(where: {
                    $0.ticket.rootEpoch == job.rootEpoch
                }),
                retainedDemandMetadataByteCount: projectionDemands.values.reduce(UInt64(0)) {
                    guard $1.ticket.rootEpoch == job.rootEpoch else { return $0 }
                    return addingSaturating($0, $1.metadataByteCount)
                }
            )
        }
        let liveProjectionResources = projectionJobs.values.reduce(
            WorkspaceCodemapProjectionResourceAccounting.zero
        ) { partial, job in
            switch partial.adding(job.resources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapProjectionResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedProjectionBytes: .max,
                    stagedGraphBytes: .max,
                    residentGraphBytes: .max,
                    queuedManifestMutationBytes: .max
                )
            }
        }
        let projectionResources = drainingProjectionResources.values.reduce(
            liveProjectionResources
        ) { partial, resources in
            switch partial.adding(resources) {
            case let .success(value): value
            case .failure:
                WorkspaceCodemapProjectionResourceAccounting(
                    retainedPathBytes: .max,
                    retainedSourceBytes: .max,
                    retainedProjectionBytes: .max,
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
            projectionJobCount: projectionJobs.count,
            suspendedProjectionJobCount: projectionJobs.values.count(where: {
                $0.phase == .suspendedBusy
            }),
            queuedProjectionBatchCount: projectionAdmissionQueue.count,
            activeProjectionBatchCount: activeProjectionJobIDs.count,
            drainingProjectionTaskCount: drainingProjectionTasks.count,
            retainedProjectionDemandCount: projectionDemands.count,
            retainedProjectionDemandMetadataByteCount: projectionDemands.values.reduce(UInt64(0)) {
                addingSaturating($0, $1.metadataByteCount)
            },
            terminalProjectionDemandStatusCount: terminalProjectionDemands.count,
            projectionResources: projectionResources,
            projectionRoots: projectionRoots
        )
    }

    #if DEBUG
        func debugAcquireProjectionAdmissionHold(
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
                _ = await self?.debugReleaseProjectionAdmissionHold(
                    holdID,
                    rootEpoch: rootEpoch
                )
            }
            debugProjectionAdmissionHolds[holdID] = DebugProjectionAdmissionHold(
                rootEpoch: rootEpoch,
                expiryTask: expiryTask
            )
            let snapshot = debugProjectionAdmissionSnapshot(rootEpoch: rootEpoch)
            return (holdID, snapshot.metrics, snapshot.queueWaitMilliseconds)
        }

        func debugReleaseProjectionAdmissionHold(
            _ holdID: UUID,
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (
            released: Bool,
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        ) {
            let owned = debugProjectionAdmissionHolds[holdID]
            let released = owned?.rootEpoch == rootEpoch
            if released, let hold = debugProjectionAdmissionHolds.removeValue(forKey: holdID) {
                hold.expiryTask.cancel()
                scheduleProjectionAdmissions()
            }
            let snapshot = debugProjectionAdmissionSnapshot(rootEpoch: rootEpoch)
            return (released, snapshot.metrics, snapshot.queueWaitMilliseconds)
        }

        func debugProjectionAdmissionSnapshot(
            rootEpoch: WorkspaceCodemapRootEpoch
        ) -> (
            metrics: [String: UInt64],
            queueWaitMilliseconds: [UInt64]
        ) {
            let current = accounting()
            let queueWaitMilliseconds = debugProjectionQueueWaitMillisecondsByRootEpoch[
                rootEpoch
            ] ?? []
            return (
                [
                    "hold_count": UInt64(debugProjectionAdmissionHolds.values.count(where: {
                        $0.rootEpoch == rootEpoch
                    })),
                    "queue_wait_sample_ordinal":
                        debugProjectionQueueWaitSampleOrdinalByRootEpoch[rootEpoch] ?? 0,
                    "queued_projection_batch_count": UInt64(current.queuedProjectionBatchCount),
                    "active_projection_batch_count": UInt64(current.activeProjectionBatchCount),
                    "builds": current.counters.builds,
                    "materializations": current.counters.materializations,
                    "manifest_writes": current.counters.manifestWrites,
                    "failures": current.counters.failures,
                    "manifest_failures": current.counters.manifestFailures,
                    "busy_rejections": current.counters.busyRejections,
                    "projection_demand_busy_rejections":
                        current.counters.projectionDemandBusyRejections,
                    "projection_batches_started": current.counters.projectionBatchesStarted,
                    "projection_batches_queued": current.counters.projectionBatchesQueued,
                    "projection_demands_acquired": current.counters.projectionDemandsAcquired,
                    "projection_builds_started": current.counters.projectionBuildsStarted,
                    "projection_segments_published": current.counters.projectionSegmentsPublished,
                    "projection_catalog_pages": current.counters.projectionCatalogPages,
                    "projection_catalog_candidates": current.counters.projectionCatalogCandidates,
                    "projection_budget_rejections": current.counters.projectionBudgetRejections,
                    "retained_path_bytes": current.projectionResources.retainedPathBytes,
                    "retained_source_bytes": current.projectionResources.retainedSourceBytes,
                    "retained_projection_bytes": current.projectionResources.retainedProjectionBytes,
                    "staged_graph_bytes": current.projectionResources.stagedGraphBytes,
                    "resident_graph_bytes": current.projectionResources.residentGraphBytes,
                    "queued_manifest_mutation_bytes": current.projectionResources.queuedManifestMutationBytes,
                    "limit_retained_path_bytes":
                        policy.maximumProjectionCatalogPagePathByteCount *
                        UInt64(policy.maximumActiveProjectionBatchCount),
                    "limit_retained_source_bytes": policy.maximumRetainedSourceByteCount,
                    "limit_retained_projection_bytes": policy.maximumRetainedProjectionByteCount,
                    "limit_staged_graph_bytes": policy.maximumStagedProjectionGraphByteCount,
                    "limit_resident_graph_bytes": WorkspaceCodemapSelectionGraphSizePolicy.initial.maxBytes,
                    "limit_queued_manifest_mutation_bytes":
                        policy.maximumQueuedProjectionManifestMutationByteCount
                ],
                queueWaitMilliseconds
            )
        }
    #endif

    // MARK: - Projection preload

    private func activateProjectionDemands(rootEpoch: WorkspaceCodemapRootEpoch) {
        guard projectionDemands.values.contains(where: { $0.ticket.rootEpoch == rootEpoch }),
              case .eligible? = roots[rootEpoch]
        else { return }
        _ = scheduleProjectionPreload(rootEpoch: rootEpoch)
    }

    private func projectionDemandStatusValue(
        _ ticket: WorkspaceCodemapProjectionDemandTicket
    ) -> WorkspaceCodemapProjectionDemandStatus {
        if let terminal = terminalProjectionDemands[ticket.id], terminal.ticket == ticket {
            return terminal.status
        }
        guard let record = projectionDemands[ticket.id], record.ticket == ticket else {
            return .cancelled
        }
        let retry = policy.projectionDemandRetryMilliseconds
        switch roots[ticket.rootEpoch] {
        case let .registering(attempt):
            guard attempt.registration.catalogGeneration == ticket.catalogGeneration,
                  attempt.registration.ingressGeneration == ticket.ingressGeneration
            else { return terminalizeProjectionDemand(ticket.id, status: .stale) }
            if record.deadlineUptimeNanoseconds <= uptimeNanoseconds() {
                return terminalizeProjectionDemand(ticket.id, status: .expired)
            }
            return .waitingForSetup(retryAfterMilliseconds: retry)
        case let .eligible(session):
            guard session.registration.catalogGeneration == ticket.catalogGeneration,
                  session.registration.ingressGeneration == ticket.ingressGeneration
            else { return terminalizeProjectionDemand(ticket.id, status: .stale) }
        case .unavailable:
            return terminalizeProjectionDemand(
                ticket.id,
                status: .unavailable(reason: .capabilityUnavailable, retryAfterMilliseconds: nil)
            )
        case nil:
            return terminalizeProjectionDemand(ticket.id, status: .stale)
        }
        guard let job = projectionJobs[ticket.rootEpoch] else {
            if record.deadlineUptimeNanoseconds <= uptimeNanoseconds() {
                return terminalizeProjectionDemand(ticket.id, status: .expired)
            }
            activateProjectionDemands(rootEpoch: ticket.rootEpoch)
            return .queued(progress: .notStarted, retryAfterMilliseconds: retry)
        }
        if job.phase == .complete,
           let proof = job.coverageProof,
           let completedAt = job.coverageCompletedUptimeNanoseconds,
           projectionJobIsCurrent(job)
        {
            if completedAt > record.deadlineUptimeNanoseconds {
                return terminalizeProjectionDemand(ticket.id, status: .expired)
            }
            if record.deadlineUptimeNanoseconds <= uptimeNanoseconds() {
                return terminalizeProjectionDemand(ticket.id, status: .ready(proof))
            }
            return .ready(proof)
        }
        if let budget = job.budget {
            return terminalizeProjectionDemand(
                ticket.id,
                status: .unavailable(reason: .projectionBudget(budget), retryAfterMilliseconds: nil)
            )
        }
        if job.phase == .cancelled || job.phase == .superseded || !projectionJobIsCurrent(job) {
            return terminalizeProjectionDemand(ticket.id, status: .stale)
        }
        if record.deadlineUptimeNanoseconds <= uptimeNanoseconds() {
            return terminalizeProjectionDemand(ticket.id, status: .expired)
        }
        if job.phase == .suspendedBusy {
            let suggestedRetry = job.retry?.retryAfterMilliseconds ?? retry
            return .suspendedBusy(
                progress: job.progress,
                retryAfterMilliseconds: min(1000, max(25, suggestedRetry))
            )
        }
        if job.isActiveBatch {
            return .activeBatch(progress: job.progress, retryAfterMilliseconds: retry)
        }
        if job.isQueuedForAdmission {
            if !activeProjectionJobIDs.isEmpty {
                return .waitingForBatchBoundary(progress: job.progress, retryAfterMilliseconds: retry)
            }
            return .queued(progress: job.progress, retryAfterMilliseconds: retry)
        }
        return .joined(progress: job.progress, retryAfterMilliseconds: retry)
    }

    @discardableResult
    private func terminalizeProjectionDemand(
        _ ticketID: UUID,
        status: WorkspaceCodemapProjectionDemandStatus
    ) -> WorkspaceCodemapProjectionDemandStatus {
        guard let record = projectionDemands.removeValue(forKey: ticketID) else {
            return terminalProjectionDemands[ticketID]?.status ?? status
        }
        ensureTerminalProjectionDemandOrdinalCapacity()
        let ordinal = nextTerminalProjectionDemandOrdinal
        nextTerminalProjectionDemandOrdinal = addingChecked(nextTerminalProjectionDemandOrdinal, 1) ?? .max
        terminalProjectionDemands[ticketID] = TerminalProjectionDemandRecord(
            ticket: record.ticket,
            status: status,
            terminalOrdinal: ordinal
        )
        trimTerminalProjectionDemands()
        switch status {
        case .expired:
            incrementCounter(\.projectionDemandsExpired)
        case .stale:
            incrementCounter(\.projectionDemandsRevoked)
        default:
            break
        }
        pruneAdmissionHistory()
        return status
    }

    private func expireProjectionDemands() {
        let now = uptimeNanoseconds()
        let terminal = projectionDemands.values.compactMap {
            record -> (UUID, WorkspaceCodemapProjectionDemandStatus)? in
            guard record.deadlineUptimeNanoseconds <= now else { return nil }
            if let job = projectionJobs[record.ticket.rootEpoch],
               job.phase == .complete,
               let proof = job.coverageProof,
               let completedAt = job.coverageCompletedUptimeNanoseconds,
               completedAt <= record.deadlineUptimeNanoseconds,
               projectionJobIsCurrent(job)
            {
                return (record.ticket.id, .ready(proof))
            }
            return (record.ticket.id, .expired)
        }
        for (ticketID, status) in terminal {
            terminalizeProjectionDemand(ticketID, status: status)
        }
    }

    private func revokeProjectionDemands(
        rootEpoch: WorkspaceCodemapRootEpoch,
        status: WorkspaceCodemapProjectionDemandStatus
    ) {
        let ticketIDs = projectionDemands.values.filter {
            $0.ticket.rootEpoch == rootEpoch
        }.map(\.ticket.id)
        for ticketID in ticketIDs {
            terminalizeProjectionDemand(ticketID, status: status)
        }
    }

    private func projectionDemandPriority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (deadline: UInt64, enqueueOrdinal: UInt64)? {
        projectionDemands.values.filter {
            $0.ticket.rootEpoch == rootEpoch
        }.map {
            ($0.deadlineUptimeNanoseconds, $0.enqueueOrdinal)
        }.min { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
    }

    private func projectionArtifactPriority(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> CodeMapArtifactBuildPriority {
        projectionDemandPriority(rootEpoch: rootEpoch) == nil ? .background : .demand
    }

    private func recordProjectionDemandBusy(rootEpoch: WorkspaceCodemapRootEpoch) {
        incrementCounter(\.projectionDemandBusyRejections)
        recordBusy(rootEpoch)
    }

    private func ensureProjectionDemandOrdinalCapacity() {
        guard nextProjectionDemandOrdinal == .max else { return }
        var ordinal: UInt64 = 1
        for record in projectionDemands.values.sorted(by: {
            $0.enqueueOrdinal < $1.enqueueOrdinal
        }) {
            var updated = record
            updated.enqueueOrdinal = ordinal
            projectionDemands[record.ticket.id] = updated
            ordinal = addingChecked(ordinal, 1) ?? .max
        }
        nextProjectionDemandOrdinal = ordinal
    }

    private func ensureTerminalProjectionDemandOrdinalCapacity() {
        guard nextTerminalProjectionDemandOrdinal == .max else { return }
        var ordinal: UInt64 = 1
        for record in terminalProjectionDemands.values.sorted(by: {
            $0.terminalOrdinal < $1.terminalOrdinal
        }) {
            terminalProjectionDemands[record.ticket.id] = TerminalProjectionDemandRecord(
                ticket: record.ticket,
                status: record.status,
                terminalOrdinal: ordinal
            )
            ordinal = addingChecked(ordinal, 1) ?? .max
        }
        nextTerminalProjectionDemandOrdinal = ordinal
    }

    private func trimTerminalProjectionDemands() {
        let overflow = terminalProjectionDemands.count - policy.maximumProjectionDemandCount
        guard overflow > 0 else { return }
        let evicted = terminalProjectionDemands.values.sorted {
            $0.terminalOrdinal < $1.terminalOrdinal
        }.prefix(overflow)
        for record in evicted {
            terminalProjectionDemands.removeValue(forKey: record.ticket.id)
        }
    }

    private func runProjectionPreload(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async {
        defer { finishProjectionWorker(jobID: jobID, rootEpoch: rootEpoch) }
        guard updateProjectionPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .waitingForAdmission) else {
            return
        }
        incrementCounter(\.projectionPreloadsStarted)
        emit(.projectionPreloadStarted, rootEpoch: rootEpoch, projectionPhase: .waitingForAdmission)

        while !Task.isCancelled {
            guard await awaitProjectionAdmission(jobID: jobID, rootEpoch: rootEpoch) else { return }
            let result = await processProjectionBatch(jobID: jobID, rootEpoch: rootEpoch)
            releaseProjectionAdmission(jobID: jobID, rootEpoch: rootEpoch)
            switch result {
            case .checkpointed:
                guard updateProjectionPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else { return }
            case .restartGeneration:
                guard resetProjectionForLatestGeneration(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    recordSupersession: true
                ) else {
                    return
                }
            case .restartPage:
                guard resetProjectionForLatestGeneration(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    recordSupersession: false
                ), await waitForProjectionRetry(jobID: jobID, rootEpoch: rootEpoch),
                updateProjectionPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else {
                    return
                }
            case .complete, .budgetLimited, .cancelled, .superseded:
                return
            case .retry:
                guard await waitForProjectionRetry(jobID: jobID, rootEpoch: rootEpoch) else {
                    return
                }
                guard updateProjectionPhase(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    phase: .waitingForAdmission
                ) else { return }
            }
        }
    }

    private func awaitProjectionAdmission(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> Bool {
        guard var job = projectionJobs[rootEpoch], job.id == jobID, projectionJobIsCurrent(job) else {
            return false
        }
        if job.isActiveBatch { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      var current = projectionJobs[rootEpoch],
                      current.id == jobID,
                      projectionJobIsCurrent(current)
                else {
                    continuation.resume(returning: false)
                    return
                }
                if current.isQueuedForAdmission {
                    continuation.resume(returning: false)
                    return
                }
                if nextProjectionQueueOrdinal == .max {
                    renumberProjectionAdmissionQueue()
                }
                let ordinal = nextProjectionQueueOrdinal
                nextProjectionQueueOrdinal = addingChecked(nextProjectionQueueOrdinal, 1) ?? .max
                current.isQueuedForAdmission = true
                current.phase = .waitingForAdmission
                projectionJobs[rootEpoch] = current
                projectionAdmissionQueue.append(ProjectionAdmissionWaiter(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    enqueueOrdinal: ordinal,
                    demandOvertakeRecorded: false,
                    explicitOvertakeRecorded: false,
                    continuation: continuation
                ))
                #if DEBUG
                    debugProjectionAdmissionEnqueuedAtNanoseconds[jobID] = DispatchTime.now().uptimeNanoseconds
                #endif
                incrementCounter(\.projectionBatchesQueued)
                emit(.projectionBatchQueued, rootEpoch: rootEpoch, projectionPhase: .waitingForAdmission)
                scheduleProjectionAdmissions()
            }
        } onCancel: {
            Task { await self.cancelProjectionAdmission(jobID: jobID) }
        }
    }

    private func scheduleProjectionAdmissions() {
        guard !isShuttingDown, !projectionAdmissionQueue.isEmpty else { return }
        expireProjectionDemands()
        let demandForeground = activeRequests.values.contains { $0.demand.priority == .demand } ||
            queuedRequests.values.contains { $0.demand.priority == .demand }
        let explicitForeground = activeRequests.values.contains { $0.demand.priority == .explicit } ||
            queuedRequests.values.contains { $0.demand.priority == .explicit }
        if demandForeground || explicitForeground {
            for index in projectionAdmissionQueue.indices {
                let rootEpoch = projectionAdmissionQueue[index].rootEpoch
                if demandForeground, !projectionAdmissionQueue[index].demandOvertakeRecorded {
                    projectionAdmissionQueue[index].demandOvertakeRecorded = true
                    incrementCounter(\.projectionDemandOvertakes)
                    emit(.projectionDemandOvertake, rootEpoch: rootEpoch, projectionPhase: .waitingForAdmission)
                }
                if explicitForeground, !projectionAdmissionQueue[index].explicitOvertakeRecorded {
                    projectionAdmissionQueue[index].explicitOvertakeRecorded = true
                    incrementCounter(\.projectionExplicitOvertakes)
                    emit(.projectionExplicitOvertake, rootEpoch: rootEpoch, projectionPhase: .waitingForAdmission)
                }
            }
        }

        while activeProjectionJobIDs.count < policy.maximumActiveProjectionBatchCount,
              !projectionAdmissionQueue.isEmpty
        {
            let eligible = projectionAdmissionQueue.indices.filter { index in
                let waiter = projectionAdmissionQueue[index]
                #if DEBUG
                    if debugProjectionAdmissionHolds.values.contains(where: {
                        $0.rootEpoch == waiter.rootEpoch
                    }) {
                        return false
                    }
                #endif
                guard let job = projectionJobs[waiter.rootEpoch],
                      job.id == waiter.jobID,
                      projectionJobIsCurrent(job),
                      !job.isActiveBatch,
                      activeProjectionBatchCount(rootEpoch: waiter.rootEpoch) <
                      policy.maximumActiveProjectionBatchCountPerRoot
                else { return false }
                return activeProjectionJobIDs.count < policy.maximumActiveProjectionBatchCount
            }
            guard !eligible.isEmpty else { return }
            let demanded = eligible.filter {
                projectionDemandPriority(rootEpoch: projectionAdmissionQueue[$0].rootEpoch) != nil
            }
            let ordinary = eligible.filter { !demanded.contains($0) }
            let selectedIndex: Int
            let selectedDemandedProjection: Bool
            // Projection demand participates in the shared foreground quantum, but the mere
            // presence of foreground file work must not idle spare projection capacity.
            if !demanded.isEmpty,
               consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions || ordinary.isEmpty
            {
                selectedIndex = demanded.min(by: { lhs, rhs in
                    let left = projectionAdmissionQueue[lhs]
                    let right = projectionAdmissionQueue[rhs]
                    let leftDemand = projectionDemandPriority(rootEpoch: left.rootEpoch)!
                    let rightDemand = projectionDemandPriority(rootEpoch: right.rootEpoch)!
                    if leftDemand.deadline != rightDemand.deadline {
                        return leftDemand.deadline < rightDemand.deadline
                    }
                    let leftAdmission = projectionRootLastAdmission[left.rootEpoch] ?? 0
                    let rightAdmission = projectionRootLastAdmission[right.rootEpoch] ?? 0
                    if leftAdmission != rightAdmission { return leftAdmission < rightAdmission }
                    if leftDemand.enqueueOrdinal != rightDemand.enqueueOrdinal {
                        return leftDemand.enqueueOrdinal < rightDemand.enqueueOrdinal
                    }
                    return left.enqueueOrdinal < right.enqueueOrdinal
                })!
                selectedDemandedProjection = true
            } else if let oldestOrdinary = ordinary.min(by: { lhs, rhs in
                let left = projectionAdmissionQueue[lhs].enqueueOrdinal
                let right = projectionAdmissionQueue[rhs].enqueueOrdinal
                return left < right
            }) {
                selectedIndex = oldestOrdinary
                selectedDemandedProjection = false
            } else {
                return
            }
            let waiter = projectionAdmissionQueue.remove(at: selectedIndex)
            guard var job = projectionJobs[waiter.rootEpoch],
                  job.id == waiter.jobID,
                  projectionJobIsCurrent(job)
            else {
                #if DEBUG
                    debugProjectionAdmissionEnqueuedAtNanoseconds.removeValue(forKey: waiter.jobID)
                #endif
                waiter.continuation.resume(returning: false)
                continue
            }
            #if DEBUG
                if let enqueued = debugProjectionAdmissionEnqueuedAtNanoseconds.removeValue(
                    forKey: waiter.jobID
                ) {
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- enqueued
                    var samples = debugProjectionQueueWaitMillisecondsByRootEpoch[
                        waiter.rootEpoch,
                        default: []
                    ]
                    samples.append(elapsed / 1_000_000)
                    if samples.count > 1024 {
                        samples.removeFirst(
                            samples.count - 1024
                        )
                    }
                    debugProjectionQueueWaitMillisecondsByRootEpoch[waiter.rootEpoch] = samples
                    debugProjectionQueueWaitSampleOrdinalByRootEpoch[waiter.rootEpoch, default: 0] &+= 1
                }
            #endif
            job.isQueuedForAdmission = false
            job.isActiveBatch = true
            job.phase = .readingCatalogPage
            job.retry = nil
            projectionJobs[waiter.rootEpoch] = job
            activeProjectionJobIDs.insert(waiter.jobID)
            ensureAdmissionOrdinalCapacity()
            projectionRootLastAdmission[waiter.rootEpoch] = nextAdmissionOrdinal
            nextAdmissionOrdinal = addingChecked(nextAdmissionOrdinal, 1) ?? .max
            if selectedDemandedProjection {
                consecutiveDemandAdmissions = min(
                    policy.maximumConsecutiveDemandAdmissions,
                    consecutiveDemandAdmissions + 1
                )
            } else {
                consecutiveDemandAdmissions = 0
            }
            incrementCounter(\.projectionBatchesStarted)
            emit(.projectionBatchStarted, rootEpoch: waiter.rootEpoch, projectionPhase: .readingCatalogPage)
            waiter.continuation.resume(returning: true)
        }
    }

    private func activeProjectionBatchCount(rootEpoch: WorkspaceCodemapRootEpoch) -> Int {
        activeProjectionJobIDs.count { jobID in
            if drainingProjectionRootEpochs[jobID] == rootEpoch { return true }
            return projectionJobs[rootEpoch]?.id == jobID
        }
    }

    private func releaseProjectionAdmission(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        activeProjectionJobIDs.remove(jobID)
        job.isActiveBatch = false
        projectionJobs[rootEpoch] = job
        incrementCounter(\.projectionBatchesCompleted)
        emit(.projectionBatchCompleted, rootEpoch: rootEpoch)
        scheduleQueuedRequests()
        scheduleProjectionAdmissions()
    }

    private func cancelProjectionAdmission(jobID: UUID) {
        let detached = projectionAdmissionQueue.filter { $0.jobID == jobID }
        projectionAdmissionQueue.removeAll { $0.jobID == jobID }
        #if DEBUG
            debugProjectionAdmissionEnqueuedAtNanoseconds.removeValue(forKey: jobID)
        #endif
        for waiter in detached {
            waiter.continuation.resume(returning: false)
        }
    }

    private func renumberProjectionAdmissionQueue() {
        var ordinal: UInt64 = 1
        for index in projectionAdmissionQueue.indices {
            projectionAdmissionQueue[index].enqueueOrdinal = ordinal
            ordinal = addingChecked(ordinal, 1) ?? .max
        }
        nextProjectionQueueOrdinal = ordinal
    }

    private func processProjectionBatch(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> ProjectionBatchResult {
        defer { clearProjectionBatchResources(jobID: jobID, rootEpoch: rootEpoch) }
        guard let initial = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) else {
            return .cancelled
        }
        let request = WorkspaceCodemapProjectionCatalogPageRequest(
            rootEpoch: rootEpoch,
            token: initial.generation?.catalogToken,
            cursor: initial.cursor,
            maximumEntryCount: min(
                policy.maximumProjectionCatalogPageEntryCount,
                policy.maximumProjectionBatchCandidateCount
            ),
            maximumPathByteCount: policy.maximumProjectionCatalogPagePathByteCount
        )
        let pageDisposition = await catalogClient.readProjectionCatalogPage(request)
        guard !Task.isCancelled,
              let afterPageRead = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
        else { return .cancelled }
        let page: WorkspaceCodemapProjectionCatalogPage
        switch pageDisposition {
        case let .page(value):
            page = value
        case .stale:
            supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        case let .unavailable(reason):
            if reason == .rootNotCurrent {
                supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            }
            return .retry
        }
        guard page.token.rootEpoch == rootEpoch,
              page.token.catalogGeneration == afterPageRead.catalogGeneration,
              page.token.ingressGeneration == afterPageRead.ingressGeneration,
              request.token == nil || request.token == page.token
        else {
            supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        }
        switch reserveProjectionResources(
            jobID: jobID,
            rootEpoch: rootEpoch,
            retainedPathBytes: page.pathByteCount
        ) {
        case .reserved:
            break
        case .retry:
            return .retry
        case let .budget(budget):
            finishProjectionForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
            return .budgetLimited
        }

        if afterPageRead.generation == nil {
            guard let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch),
                  var job = projectionJobs[rootEpoch],
                  job.id == jobID,
                  projectionJobIsCurrent(job),
                  overlaySnapshot.catalogGeneration == job.catalogGeneration,
                  overlaySnapshot.repositoryAuthority == job.repositoryAuthority
            else { return .retry }
            job.generation = WorkspaceCodemapProjectionGeneration(
                catalogToken: page.token,
                repositoryAuthority: job.repositoryAuthority,
                contributionGeneration: overlaySnapshot.contributionGeneration
            )
            projectionJobs[rootEpoch] = job
        }
        guard let generation = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch)?.generation,
              generation.catalogToken == page.token
        else { return .superseded }
        incrementCounter(\.projectionCatalogPages)
        addToCounter(\.projectionCatalogCandidates, UInt64(page.entries.count))
        addToCounter(\.projectionCatalogPathBytes, page.pathByteCount)
        emit(.projectionCatalogPage, rootEpoch: rootEpoch, numericValue: 1, projectionPhase: .readingCatalogPage)
        emit(
            .projectionCatalogCandidates,
            rootEpoch: rootEpoch,
            numericValue: UInt64(page.entries.count),
            projectionPhase: .readingCatalogPage
        )
        emit(
            .projectionCatalogPathBytes,
            rootEpoch: rootEpoch,
            numericValue: page.pathByteCount,
            projectionPhase: .readingCatalogPage
        )

        guard updateProjectionPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .loadingEnvelopes) else {
            return .cancelled
        }
        var pipelineByFileID: [UUID: CodeMapPipelineIdentity] = [:]
        var candidatesByPipeline: [CodeMapPipelineIdentity: [WorkspaceCodemapProjectionCatalogCandidate]] = [:]
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
        guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
            return .cancelled
        }

        var manifestRecordsByPipeline: [CodeMapPipelineIdentity: [String: CodeMapRootManifestRecord]] = [:]
        for (pipelineIdentity, candidates) in candidatesByPipeline {
            guard let records = await loadProjectionManifestRecords(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                candidatePaths: Set(candidates.compactMap { candidate in
                    guard let job = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
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

        var resolvedByFileID: [UUID: ProjectionCandidateResolution] = [:]
        var misses: [WorkspaceCodemapProjectionCatalogCandidate] = []
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
               let entry = projectionEntry(
                   candidate: candidate,
                   pipelineIdentity: pipelineIdentity,
                   repositoryRelativePath: repositoryRelativePath,
                   record: record
               )
            {
                retainProjectionAutomaticSelectionRecord(
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
            guard updateProjectionPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .classifyingBatch),
                  case let .eligible(session)? = roots[rootEpoch]
            else { return .cancelled }
            incrementCounter(\.classifications)
            let classifications = await identityService.classify(
                workspaceRoot: session.registration.capabilityRequest.loadedRootURL,
                relativePaths: misses.map(\.identity.standardizedRelativePath)
            )
            guard !Task.isCancelled,
                  currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil
            else { return .cancelled }
            guard classifications.failure == nil,
                  classifications.classifications.count == misses.count
            else { return .retry }
            let classificationsByPath = Dictionary(
                uniqueKeysWithValues: classifications.classifications.map { ($0.relativePath, $0) }
            )
            guard updateProjectionPhase(jobID: jobID, rootEpoch: rootEpoch, phase: .resolvingArtifacts) else {
                return .cancelled
            }
            for candidate in misses {
                guard let pipelineIdentity = pipelineByFileID[candidate.identity.fileID],
                      let classification = classificationsByPath[
                          candidate.identity.standardizedRelativePath
                      ]
                else { return .retry }
                let resolution = await resolveProjectionCandidate(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    candidate: candidate,
                    pipelineIdentity: pipelineIdentity,
                    classification: classification
                )
                guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                    return .cancelled
                }
                switch resolution {
                case let .entry(entry, manifestRecord):
                    resolvedByFileID[candidate.identity.fileID] = .entry(
                        entry,
                        manifestRecord: manifestRecord
                    )
                case .transient:
                    return .retry
                case let .budget(budget):
                    finishProjectionForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
                    return .budgetLimited
                }
            }
        }

        let orderedResolutions = page.entries.compactMap { candidate in
            resolvedByFileID[candidate.identity.fileID]
        }
        guard orderedResolutions.count == page.entries.count else { return .retry }
        let entries = orderedResolutions.compactMap { resolution -> WorkspaceCodemapProjectionEntry? in
            guard case let .entry(entry, _) = resolution else { return nil }
            return entry
        }
        guard entries.count == page.entries.count else { return .retry }

        if page.isEnd {
            let tokenDisposition = await catalogClient.revalidateProjectionCatalogToken(
                rootEpoch,
                page.token
            )
            guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                return .cancelled
            }
            switch tokenDisposition {
            case .current:
                break
            case .stale:
                supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            case .unavailable:
                return .retry
            }
        }

        let pageLastCursor = page.entries.last.map {
            WorkspaceCodemapProjectionCatalogCursor(
                standardizedRelativePath: $0.identity.standardizedRelativePath,
                fileID: $0.identity.fileID
            )
        } ?? currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch)?.lastProcessedCursor
        let catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion? = page.isEnd
            ? WorkspaceCodemapProjectionCatalogCompletion(
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
            guard updateProjectionPhase(
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
                        proof: .projection(jobID: jobID, generation: generation),
                        retainRecordsInMemory: true
                    )
                    guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
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
                        finishProjectionForBudget(
                            jobID: jobID,
                            rootEpoch: rootEpoch,
                            budget: budget
                        )
                        return .budgetLimited
                    }
                }
            }
        }

        let segmentGroups: [ProjectionSegmentGroup]
        switch projectionSegmentGroups(entries) {
        case let .groups(groups):
            segmentGroups = groups
        case let .budget(budget):
            finishProjectionForBudget(
                jobID: jobID,
                rootEpoch: rootEpoch,
                budget: budget
            )
            return .budgetLimited
        }
        let retainedProjectionBytes = segmentGroups.reduce(0) {
            addingSaturating($0, $1.byteCount)
        }
        switch reserveProjectionResources(
            jobID: jobID,
            rootEpoch: rootEpoch,
            retainedProjectionBytes: retainedProjectionBytes
        ) {
        case .reserved:
            break
        case .retry:
            return .retry
        case let .budget(budget):
            finishProjectionForBudget(jobID: jobID, rootEpoch: rootEpoch, budget: budget)
            return .budgetLimited
        }

        var progress = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch)?.progress ?? .notStarted
        if segmentGroups.isEmpty {
            let delta = WorkspaceCodemapProjectionProgressDelta(
                counts: .zero,
                catalogPageCount: 1,
                catalogPathByteCount: page.pathByteCount,
                publishedSegmentCount: 0,
                publishedSegmentByteCount: 0
            )
            let advance = progress.advancing(
                to: .checkpointed,
                by: delta,
                catalogCompletion: catalogCompletion
            )
            guard case let .success(advanced) = advance else {
                let budget = switch advance {
                case let .failure(error): projectionOverflowBudget(error)
                case .success: preconditionFailure("Expected projection accounting failure.")
                }
                finishProjectionForBudget(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    budget: budget
                )
                return .budgetLimited
            }
            progress = advanced
            updateProjectionProgress(jobID: jobID, rootEpoch: rootEpoch, progress: progress)
        } else {
            var publishedSegmentThisPage = false
            for (index, group) in segmentGroups.enumerated() {
                guard var job = projectionJobs[rootEpoch], job.id == jobID,
                      job.nextSegmentSequence < UInt64.max
                else {
                    finishProjectionForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: WorkspaceCodemapProjectionBudget(
                            dimension: .catalogEntries,
                            attempted: .max,
                            limit: .max - 1
                        )
                    )
                    return .budgetLimited
                }
                let counts = projectionCounts(group.entries)
                let isLast = index == segmentGroups.count - 1
                let delta = WorkspaceCodemapProjectionProgressDelta(
                    counts: counts,
                    catalogPageCount: isLast ? 1 : 0,
                    catalogPathByteCount: isLast ? page.pathByteCount : 0,
                    publishedSegmentCount: 1,
                    publishedSegmentByteCount: group.byteCount
                )
                guard case let .success(advanced) = progress.advancing(
                    to: .publishingProjectionSegment,
                    by: delta,
                    catalogCompletion: isLast ? catalogCompletion : nil
                ), case let .success(segment) = WorkspaceCodemapProjectionSegment.validated(
                    generation: generation,
                    sequence: job.nextSegmentSequence,
                    entries: group.entries,
                    progress: advanced,
                    byteCount: group.byteCount
                ) else {
                    return publishedSegmentThisPage ? .restartPage : .retry
                }
                switch reserveProjectionResources(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    stagedGraphBytes: group.byteCount
                ) {
                case .reserved:
                    break
                case .retry:
                    return publishedSegmentThisPage ? .restartPage : .retry
                case let .budget(budget):
                    finishProjectionForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: budget
                    )
                    return .budgetLimited
                }
                let disposition = await publishProjectionSnapshot(
                    .segment(segment),
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    markerReadinessUnavailableFileIDs: markerReadinessUnavailableFileIDs
                )
                releaseStagedProjectionBytes(
                    jobID: jobID,
                    rootEpoch: rootEpoch,
                    byteCount: group.byteCount
                )
                guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else {
                    return .cancelled
                }
                switch disposition {
                case let .accepted(accepted), let .exactDuplicate(accepted):
                    progress = accepted
                    publishedSegmentThisPage = true
                    job = projectionJobs[rootEpoch]!
                    job.progress = accepted
                    job.nextSegmentSequence += 1
                    job.retry = nil
                    projectionJobs[rootEpoch] = job
                    incrementCounter(\.projectionSegmentsPublished)
                    addToCounter(\.projectionSegmentBytes, group.byteCount)
                    if job.nextSegmentSequence == 1 {
                        incrementCounter(\.projectionFirstSegments)
                        emit(
                            .projectionFirstSegment,
                            rootEpoch: rootEpoch,
                            numericValue: group.byteCount,
                            projectionPhase: .publishingProjectionSegment
                        )
                    }
                    emit(
                        .projectionSegmentPublished,
                        rootEpoch: rootEpoch,
                        numericValue: group.byteCount,
                        projectionPhase: .publishingProjectionSegment
                    )
                case .stale, .superseded:
                    switch await projectionPublicationStalenessResult(
                        jobID: jobID,
                        rootEpoch: rootEpoch
                    ) {
                    case .restartGeneration:
                        return .restartGeneration
                    case .retry:
                        return publishedSegmentThisPage ? .restartPage : .retry
                    case .terminal:
                        supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
                        return .superseded
                    }
                case let .budget(dimension, attempted, limit):
                    finishProjectionForBudget(
                        jobID: jobID,
                        rootEpoch: rootEpoch,
                        budget: WorkspaceCodemapProjectionBudget(
                            dimension: dimension,
                            attempted: attempted,
                            limit: limit
                        )
                    )
                    return .budgetLimited
                case .unavailable:
                    return publishedSegmentThisPage ? .restartPage : .retry
                case .busy:
                    return .retry
                }
            }
        }

        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return .cancelled }
        // Segment progress already includes this page. For an empty page it was advanced above.
        guard job.progress.counts.supportedCandidateCount == page.supportedCandidateCountThroughPage
        else {
            supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
            return .superseded
        }
        job.cursor = page.nextCursor
        job.lastProcessedCursor = pageLastCursor
        progress = projectionProgress(progress, phase: .checkpointed)
        job.phase = .checkpointed
        job.progress = progress
        job.retryAttempt = 0
        job.retry = nil
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job

        guard page.isEnd else { return .checkpointed }
        guard let completion = catalogCompletion,
              progress.catalogCompletion == completion,
              case let .success(proof) = WorkspaceCodemapProjectionCoverageProof.validated(
                  generation: generation,
                  catalogCompletion: completion,
                  counts: progress.counts,
                  lastSegmentSequence: job.nextSegmentSequence == 0 ? nil : job.nextSegmentSequence - 1
              ) else { return .retry }
        let sealDisposition = await publishProjectionSnapshot(
            .seal(proof),
            jobID: jobID,
            rootEpoch: rootEpoch
        )
        guard var completedJob = projectionJobs[rootEpoch], completedJob.id == jobID else {
            return .cancelled
        }
        switch sealDisposition {
        case let .accepted(accepted), let .exactDuplicate(accepted):
            completedJob.phase = .complete
            completedJob.progress = accepted
            completedJob.coverageProof = proof
            completedJob.coverageCompletedUptimeNanoseconds = uptimeNanoseconds()
            completedJob.retry = nil
            completedJob.checkpoint = makeProjectionCheckpoint(completedJob)
            projectionJobs[rootEpoch] = completedJob
            incrementCounter(\.projectionCoveragesCompleted)
            emit(.projectionCoverageComplete, rootEpoch: rootEpoch, projectionPhase: .complete)
            return .complete
        case .stale, .superseded:
            switch await projectionPublicationStalenessResult(
                jobID: jobID,
                rootEpoch: rootEpoch
            ) {
            case .restartGeneration:
                return .restartGeneration
            case .retry:
                return .restartPage
            case .terminal:
                supersedeProjectionJob(jobID: jobID, rootEpoch: rootEpoch)
                return .superseded
            }
        case let .budget(dimension, attempted, limit):
            finishProjectionForBudget(
                jobID: jobID,
                rootEpoch: rootEpoch,
                budget: WorkspaceCodemapProjectionBudget(
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

    private func loadProjectionManifestRecords(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        candidatePaths: Set<String>
    ) async -> [String: CodeMapRootManifestRecord]? {
        guard let job = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
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
            guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil else { return nil }
            incrementCounter(\.projectionEnvelopeInvalid)
            emit(.projectionEnvelopeInvalid, rootEpoch: rootEpoch, projectionPhase: .loadingEnvelopes)
            return [:]
        }
        guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil,
              job.sessionID == session.id
        else { return nil }
        switch load {
        case .miss:
            emit(.manifestLoadMiss, rootEpoch: rootEpoch)
            updateProjectionPipelineScope(
                jobID: jobID,
                rootEpoch: rootEpoch,
                pipelineIdentity: pipelineIdentity,
                manifestGeneration: nil
            )
            return [:]
        case .stale:
            incrementCounter(\.projectionEnvelopeStale)
            emit(.projectionEnvelopeStale, rootEpoch: rootEpoch, projectionPhase: .loadingEnvelopes)
            updateProjectionPipelineScope(
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
                incrementCounter(\.projectionEnvelopeStale)
                return [:]
            }
            emit(.manifestLoadHit, rootEpoch: rootEpoch, numericValue: UInt64(snapshot.records.count))
            updateProjectionPipelineScope(
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

    private func projectionEntry(
        candidate: WorkspaceCodemapProjectionCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        repositoryRelativePath: String,
        record: CodeMapRootManifestRecord
    ) -> WorkspaceCodemapProjectionEntry? {
        guard record.repositoryRelativePath == repositoryRelativePath,
              record.bindingGeneration == candidate.requestGeneration,
              record.locatorIdentity.pipelineIdentity == pipelineIdentity,
              record.artifactKey.pipelineIdentity == pipelineIdentity
        else {
            incrementCounter(\.projectionEnvelopeStale)
            emit(.projectionEnvelopeStale, projectionPhase: .loadingEnvelopes)
            return nil
        }
        let outcome: WorkspaceCodemapProjectionEntryOutcome
        switch record.outcome {
        case .ready, .readyNoSymbols:
            guard let envelope = record.contributionEnvelope,
                  envelope.identity.schemaVersion == CodeMapSelectionGraphContribution.currentSchemaVersion,
                  envelope.identity.policyVersion == CodeMapSelectionGraphContribution.currentPolicyVersion
            else {
                incrementCounter(\.projectionEnvelopeStale)
                emit(.projectionEnvelopeStale, projectionPhase: .loadingEnvelopes)
                return nil
            }
            let contribution = CodeMapSelectionGraphContribution(
                artifactKey: record.artifactKey,
                definitions: envelope.sortedUniqueDefinitions,
                references: envelope.sortedUniqueReferences
            )
            guard CodeMapRootManifestContributionIdentity(contribution) == envelope.identity else {
                incrementCounter(\.projectionEnvelopeInvalid)
                emit(.projectionEnvelopeInvalid, projectionPhase: .loadingEnvelopes)
                return nil
            }
            outcome = envelope.sortedUniqueDefinitions.isEmpty && envelope.sortedUniqueReferences.isEmpty
                ? .empty(contribution)
                : .contributed(contribution)
            incrementCounter(\.projectionEnvelopeHits)
            emit(.projectionEnvelopeHit, projectionPhase: .loadingEnvelopes)
        case .terminalOversize:
            outcome = .terminalArtifact(.oversize)
            incrementCounter(\.projectionTerminalRecordHits)
            emit(.projectionTerminalRecordHit, projectionPhase: .loadingEnvelopes)
        case .terminalDecodeFailure:
            outcome = .terminalArtifact(.decodeFailed)
            incrementCounter(\.projectionTerminalRecordHits)
            emit(.projectionTerminalRecordHit, projectionPhase: .loadingEnvelopes)
        case .terminalParseFailure:
            outcome = .terminalArtifact(.parseFailed)
            incrementCounter(\.projectionTerminalRecordHits)
            emit(.projectionTerminalRecordHit, projectionPhase: .loadingEnvelopes)
        }
        return WorkspaceCodemapProjectionEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: outcome
        )
    }

    private func retainProjectionAutomaticSelectionRecord(
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

    private func resolveProjectionCandidate(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        candidate: WorkspaceCodemapProjectionCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        classification: GitBlobIdentityClassification
    ) async -> ProjectionCandidateResolution {
        guard let job = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
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
            return .entry(WorkspaceCodemapProjectionEntry(
                identity: candidate.identity,
                requestGeneration: candidate.requestGeneration,
                pathGeneration: candidate.pathGeneration,
                pipelineIdentity: pipelineIdentity,
                outcome: .terminalExcluded(.securityExcluded)
            ), manifestRecord: nil)
        case let .unsupported(reason):
            let exclusion: WorkspaceCodemapProjectionTerminalExclusionReason
            switch reason {
            case .gitlink: exclusion = .gitlink
            case .nonRegularFile: exclusion = .nonRegular
            case .unsupportedGit, .invalidObjectFormat, .invalidPath, .unknownIndexMode:
                return .transient
            }
            return .entry(WorkspaceCodemapProjectionEntry(
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
              projectionCandidateIsCurrent(
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
                    releaseProjectionSourceBytes(
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
                    priority: projectionArtifactPriority(rootEpoch: rootEpoch)
                ) {
                case let .ready(fastPath):
                    resolved = fastPath
                case let .miss(miss):
                    recordProjectionFastPathMiss(miss, rootEpoch: rootEpoch)
                    let reservation = UInt64(policy.maximumValidatedWorktreeByteCount)
                    switch reserveProjectionResources(
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
                        priority: projectionArtifactPriority(rootEpoch: rootEpoch)
                    )
                }
            } catch GitBlobSourceMaterializationError.oversized {
                guard !Task.isCancelled,
                      projectionCandidateIsCurrent(
                          jobID: jobID,
                          rootEpoch: rootEpoch,
                          candidate: candidate,
                          pipelineIdentity: pipelineIdentity
                      )
                else { return .transient }
                return .entry(
                    terminalOversizeProjectionEntry(
                        candidate: candidate,
                        pipelineIdentity: pipelineIdentity
                    ),
                    manifestRecord: nil
                )
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  projectionCandidateIsCurrent(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity
                  ), let association = resolved.association,
                  let mode = gitMode(classification)
            else { return .transient }
            recordProjectionResolutionTelemetry(
                resolved,
                rootEpoch: rootEpoch,
                locatorMissAlreadyRecorded: sourceReservation > 0
            )
            guard let entry = projectionEntry(
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
            switch reserveProjectionResources(
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
                releaseProjectionSourceBytes(
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
                      projectionCandidateIsCurrent(
                          jobID: jobID,
                          rootEpoch: rootEpoch,
                          candidate: candidate,
                          pipelineIdentity: pipelineIdentity
                      )
                else { return .transient }
                return .entry(
                    terminalOversizeProjectionEntry(
                        candidate: candidate,
                        pipelineIdentity: pipelineIdentity
                    ),
                    manifestRecord: nil
                )
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  projectionCandidateIsCurrent(
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
                    priority: projectionArtifactPriority(rootEpoch: rootEpoch),
                    target: .source(input)
                ))
            } catch {
                return .transient
            }
            guard !Task.isCancelled,
                  projectionCandidateIsCurrent(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity
                  ), case let .ready(resolution) = result,
                  let entry = projectionEntry(
                      candidate: candidate,
                      pipelineIdentity: pipelineIdentity,
                      artifactKey: resolution.handle.key,
                      outcome: resolution.handle.outcome
                  )
            else { return .transient }
            recordProjectionBuildTelemetry(resolution, rootEpoch: rootEpoch)
            _ = reason
            return .entry(entry, manifestRecord: nil)

        case .unavailable, .securityExcluded, .unsupported:
            return .transient
        }
    }

    private func projectionEntry(
        candidate: WorkspaceCodemapProjectionCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity,
        artifactKey: CodeMapArtifactKey,
        outcome: CodeMapSyntaxArtifactOutcome
    ) -> WorkspaceCodemapProjectionEntry? {
        let projectionOutcome: WorkspaceCodemapProjectionEntryOutcome = switch outcome {
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
        return WorkspaceCodemapProjectionEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: projectionOutcome
        )
    }

    private func terminalOversizeProjectionEntry(
        candidate: WorkspaceCodemapProjectionCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity
    ) -> WorkspaceCodemapProjectionEntry {
        WorkspaceCodemapProjectionEntry(
            identity: candidate.identity,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            pipelineIdentity: pipelineIdentity,
            outcome: .terminalArtifact(.oversize)
        )
    }

    private func recordProjectionFastPathMiss(
        _ miss: CodeMapArtifactCoordinatorMiss,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        switch miss {
        case .locatorNotFound:
            incrementCounter(\.projectionLocatorMisses)
            emit(.projectionLocatorMiss, rootEpoch: rootEpoch)
        case .corruptLocator:
            incrementCounter(\.projectionLocatorCorruptions)
            emit(.projectionLocatorCorrupt, rootEpoch: rootEpoch)
        case .locatorHitWithMissingArtifact:
            incrementCounter(\.projectionLocatorMisses)
            incrementCounter(\.projectionCASMisses)
            emit(.projectionLocatorMiss, rootEpoch: rootEpoch)
            emit(.projectionCASMiss, rootEpoch: rootEpoch)
        case .artifactKeyNotFound:
            incrementCounter(\.projectionCASMisses)
            emit(.projectionCASMiss, rootEpoch: rootEpoch)
        }
    }

    private func recordProjectionResolutionTelemetry(
        _ resolved: ResolvedArtifact,
        rootEpoch: WorkspaceCodemapRootEpoch,
        locatorMissAlreadyRecorded: Bool = false
    ) {
        if !locatorMissAlreadyRecorded {
            switch resolved.resolution.locatorLookup {
            case .miss, .hitButArtifactMissing:
                incrementCounter(\.projectionLocatorMisses)
                emit(.projectionLocatorMiss, rootEpoch: rootEpoch)
            case .corrupt:
                incrementCounter(\.projectionLocatorCorruptions)
                emit(.projectionLocatorCorrupt, rootEpoch: rootEpoch)
            case .hit, .stale, .notRequested:
                break
            }
            if resolved.resolution.locatorLookup == .hitButArtifactMissing {
                incrementCounter(\.projectionCASMisses)
                emit(.projectionCASMiss, rootEpoch: rootEpoch)
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
        recordProjectionBuildTelemetry(resolved.resolution, rootEpoch: rootEpoch)
    }

    private func recordProjectionBuildTelemetry(
        _ resolution: CodeMapArtifactCoordinatorResolution,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) {
        switch resolution.buildProvenance {
        case .notNeeded:
            break
        case .joinedSharedBuild:
            incrementCounter(\.projectionBuildsJoined)
            incrementCounter(\.projectionBuildsCompleted)
            emit(.projectionBuildJoined, rootEpoch: rootEpoch)
            emit(.projectionBuildCompleted, rootEpoch: rootEpoch)
        case .performed:
            incrementCounter(\.projectionBuildsStarted)
            incrementCounter(\.projectionBuildsCompleted)
            emit(.projectionBuildStarted, rootEpoch: rootEpoch)
            emit(.projectionBuildCompleted, rootEpoch: rootEpoch)
        }
    }

    private struct ProjectionSegmentGroup {
        let entries: [WorkspaceCodemapProjectionEntry]
        let byteCount: UInt64
    }

    private enum ProjectionSegmentGroupingResult {
        case groups([ProjectionSegmentGroup])
        case budget(WorkspaceCodemapProjectionBudget)
    }

    private func projectionSegmentGroups(
        _ entries: [WorkspaceCodemapProjectionEntry]
    ) -> ProjectionSegmentGroupingResult {
        var groups: [ProjectionSegmentGroup] = []
        var currentEntries: [WorkspaceCodemapProjectionEntry] = []
        var currentBytes: UInt64 = 0
        for entry in entries {
            let proposedEntries = currentEntries + [entry]
            let proposedBytes: UInt64
            switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
                entries: proposedEntries
            ) {
            case let .success(value): proposedBytes = value
            case let .failure(error): return .budget(projectionOverflowBudget(error))
            }
            if !currentEntries.isEmpty,
               proposedBytes > policy.maximumRetainedProjectionByteCountPerSegment
            {
                groups.append(ProjectionSegmentGroup(entries: currentEntries, byteCount: currentBytes))
                currentEntries = [entry]
                let singleEntryBytes: UInt64
                switch WorkspaceCodemapSelectionGraphProjectionByteAccounting.normalizedByteCount(
                    entries: currentEntries
                ) {
                case let .success(value): singleEntryBytes = value
                case let .failure(error): return .budget(projectionOverflowBudget(error))
                }
                guard singleEntryBytes <= policy.maximumRetainedProjectionByteCountPerSegment else {
                    return .budget(WorkspaceCodemapProjectionBudget(
                        dimension: .retainedProjectionBytes,
                        attempted: singleEntryBytes,
                        limit: policy.maximumRetainedProjectionByteCountPerSegment
                    ))
                }
                currentBytes = singleEntryBytes
            } else {
                guard proposedBytes <= policy.maximumRetainedProjectionByteCountPerSegment else {
                    return .budget(WorkspaceCodemapProjectionBudget(
                        dimension: .retainedProjectionBytes,
                        attempted: proposedBytes,
                        limit: policy.maximumRetainedProjectionByteCountPerSegment
                    ))
                }
                currentEntries = proposedEntries
                currentBytes = proposedBytes
            }
        }
        if !currentEntries.isEmpty {
            groups.append(ProjectionSegmentGroup(entries: currentEntries, byteCount: currentBytes))
        }
        return .groups(groups)
    }

    private func projectionCounts(
        _ entries: [WorkspaceCodemapProjectionEntry]
    ) -> WorkspaceCodemapProjectionCounts {
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
        return WorkspaceCodemapProjectionCounts(
            supportedCandidateCount: UInt64(entries.count),
            processedCandidateCount: UInt64(entries.count),
            contributedCount: contributed,
            emptyCount: empty,
            terminalArtifactCount: terminalArtifact,
            terminalExcludedCount: terminalExcluded,
            transientCount: 0
        )
    }

    private func publishProjectionSnapshot(
        _ snapshot: WorkspaceCodemapProjectionSnapshot,
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        markerReadinessUnavailableFileIDs: Set<UUID> = []
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        guard updateProjectionPhase(
            jobID: jobID,
            rootEpoch: rootEpoch,
            phase: .publishingProjectionSegment
        ) else { return .superseded }
        var disposition = await catalogClient.publishProjection(snapshot)
        while case let .busy(retryAfterMilliseconds) = disposition {
            guard currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch) != nil,
                  await waitForProjectionRetry(
                      jobID: jobID,
                      rootEpoch: rootEpoch,
                      overrideMilliseconds: retryAfterMilliseconds
                  )
            else { return .superseded }
            disposition = await catalogClient.publishProjection(snapshot)
        }
        switch disposition {
        case .accepted, .exactDuplicate:
            if case let .segment(segment) = snapshot {
                let changes = segment.entries.map { entry in
                    let state: WorkspaceCodemapMarkerReadinessState = if markerReadinessUnavailableFileIDs
                        .contains(entry.identity.fileID)
                    {
                        .unavailable
                    } else {
                        switch entry.outcome {
                        case .contributed: .ready
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
                        WorkspaceCodemapMarkerReadinessUpdate(
                            rootEpoch: rootEpoch,
                            changes: changes
                        )
                    )
                }
            }
        case .stale, .superseded, .budget, .unavailable, .busy:
            break
        }
        return disposition
    }

    private func waitForProjectionRetry(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        overrideMilliseconds: UInt64? = nil
    ) async -> Bool {
        guard var job = projectionJobs[rootEpoch], job.id == jobID, projectionJobIsCurrent(job) else {
            return false
        }
        let attempt = addingChecked(job.retryAttempt, 1) ?? .max
        let shift = min(attempt - 1, 62)
        let multiplier = UInt64(1) << shift
        let (scaled, scaledOverflow) = policy.projectionRetryInitialMilliseconds
            .multipliedReportingOverflow(by: multiplier)
        let base = overrideMilliseconds ?? min(
            policy.projectionRetryMaximumMilliseconds,
            scaledOverflow ? .max : scaled
        )
        let jitterRange = policy.projectionRetryJitterPercent
        let jitterPercent = jitterRange == 0 ? 0 : attempt % (jitterRange + 1)
        let jitter = base.multipliedReportingOverflow(by: jitterPercent).overflow
            ? 0
            : base * jitterPercent / 100
        let delay = min(policy.projectionRetryMaximumMilliseconds, addingSaturating(base, jitter))
        let nanoseconds = delay.multipliedReportingOverflow(by: 1_000_000).overflow
            ? UInt64.max
            : delay * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let next = addingSaturating(now, nanoseconds)
        job.phase = .suspendedBusy
        job.retryAttempt = attempt
        job.retry = WorkspaceCodemapProjectionRetry(
            attempt: attempt,
            retryAfterMilliseconds: delay,
            nextEligibleAdmissionUptimeNanoseconds: next
        )
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
        incrementCounter(\.projectionRetries)
        emit(
            .projectionRetry,
            rootEpoch: rootEpoch,
            numericValue: attempt,
            projectionPhase: .suspendedBusy,
            retryAfterMilliseconds: delay
        )
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        guard var current = projectionJobs[rootEpoch],
              current.id == jobID,
              projectionJobIsCurrent(current)
        else { return false }
        current.retry = nil
        projectionJobs[rootEpoch] = current
        return true
    }

    private func currentProjectionJob(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> ProjectionPreloadJob? {
        guard let job = projectionJobs[rootEpoch], job.id == jobID, projectionJobIsCurrent(job) else {
            return nil
        }
        return job
    }

    private func projectionPublicationStalenessResult(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> ProjectionPublicationStalenessResult {
        guard let initial = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
              let generation = initial.generation
        else { return .terminal }
        let tokenDisposition = await catalogClient.revalidateProjectionCatalogToken(
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
        guard let afterToken = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
              afterToken.generation == generation
        else { return .terminal }
        guard let overlaySnapshot = await overlay.snapshot(rootEpoch: rootEpoch) else { return .retry }
        guard let current = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
              current.generation == generation,
              overlaySnapshot.catalogGeneration == current.catalogGeneration,
              overlaySnapshot.repositoryAuthority == current.repositoryAuthority
        else { return .terminal }
        return overlaySnapshot.contributionGeneration > generation.contributionGeneration
            ? .restartGeneration
            : .terminal
    }

    private func resetProjectionForLatestGeneration(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        recordSupersession: Bool
    ) -> Bool {
        guard var job = projectionJobs[rootEpoch],
              job.id == jobID,
              projectionJobAuthorityIsCurrent(job),
              job.generation != nil
        else { return false }
        job.phase = .waitingForAdmission
        job.generation = nil
        job.cursor = nil
        job.lastProcessedCursor = nil
        job.progress = .notStarted
        job.nextSegmentSequence = 0
        job.pipelineScopes = [:]
        job.resources = .zero
        job.pendingManifestMutationCount = 0
        job.retryAttempt = 0
        job.retry = nil
        job.budget = nil
        job.checkpoint = nil
        job.coverageProof = nil
        job.coverageCompletedUptimeNanoseconds = nil
        job.isQueuedForAdmission = false
        job.isActiveBatch = false
        projectionJobs[rootEpoch] = job
        if recordSupersession {
            incrementCounter(\.projectionCoveragesSuperseded)
            emit(.projectionCoverageSuperseded, rootEpoch: rootEpoch, projectionPhase: .superseded)
        }
        return true
    }

    private func projectionJobAuthorityIsCurrent(_ job: ProjectionPreloadJob) -> Bool {
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

    private func projectionJobIsCurrent(_ job: ProjectionPreloadJob) -> Bool {
        guard projectionJobAuthorityIsCurrent(job) else { return false }
        guard job.phase == .complete, let proof = job.coverageProof else { return true }
        let contributionGeneration = proof.generation.contributionGeneration
        guard job.generation?.contributionGeneration == contributionGeneration else { return false }
        return latestOverlayContributionGenerationByRootEpoch[job.rootEpoch]
            .map { $0 == contributionGeneration } ?? true
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

    private func projectionCandidateIsCurrent(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        candidate: WorkspaceCodemapProjectionCatalogCandidate,
        pipelineIdentity: CodeMapPipelineIdentity
    ) -> Bool {
        guard let job = currentProjectionJob(jobID: jobID, rootEpoch: rootEpoch),
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
    private func updateProjectionPhase(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        phase: WorkspaceCodemapProjectionPreloadPhase
    ) -> Bool {
        guard var job = projectionJobs[rootEpoch], job.id == jobID, projectionJobIsCurrent(job) else {
            return false
        }
        job.phase = phase
        job.progress = projectionProgress(job.progress, phase: phase)
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
        return true
    }

    private func projectionProgress(
        _ progress: WorkspaceCodemapProjectionProgress,
        phase: WorkspaceCodemapProjectionPreloadPhase
    ) -> WorkspaceCodemapProjectionProgress {
        switch progress.advancing(to: phase, by: .zero) {
        case let .success(value): value
        case .failure: progress
        }
    }

    private func updateProjectionProgress(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        progress: WorkspaceCodemapProjectionProgress
    ) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        job.progress = progress
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
    }

    private func updateProjectionPipelineScope(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        pipelineIdentity: CodeMapPipelineIdentity,
        manifestGeneration: UInt64?
    ) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        job.pipelineScopes[pipelineIdentity] = WorkspaceCodemapProjectionPipelineScope(
            pipelineIdentity: pipelineIdentity,
            manifestGeneration: manifestGeneration
        )
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
    }

    private func makeProjectionCheckpoint(
        _ job: ProjectionPreloadJob
    ) -> WorkspaceCodemapProjectionPreloadCheckpoint? {
        guard let generation = job.generation else { return nil }
        return WorkspaceCodemapProjectionPreloadCheckpoint(
            generation: generation,
            engineSessionID: job.sessionID,
            phase: job.phase,
            cursor: job.cursor,
            progress: job.progress,
            nextSegmentSequence: job.nextSegmentSequence,
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

    private func reserveProjectionResources(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        retainedPathBytes: UInt64 = 0,
        retainedSourceBytes: UInt64 = 0,
        retainedProjectionBytes: UInt64 = 0,
        stagedGraphBytes: UInt64 = 0,
        queuedManifestMutationBytes: UInt64 = 0,
        preserveForegroundSourceAllowance: Bool = false
    ) -> ProjectionResourceReservationResult {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return .retry }
        let addition = WorkspaceCodemapProjectionResourceAccounting(
            retainedPathBytes: retainedPathBytes,
            retainedSourceBytes: retainedSourceBytes,
            retainedProjectionBytes: retainedProjectionBytes,
            stagedGraphBytes: stagedGraphBytes,
            residentGraphBytes: 0,
            queuedManifestMutationBytes: queuedManifestMutationBytes
        )
        let jobResources: WorkspaceCodemapProjectionResourceAccounting
        switch job.resources.adding(addition) {
        case let .success(value):
            jobResources = value
        case let .failure(error):
            return .budget(projectionOverflowBudget(error))
        }

        if let budget = fixedProjectionResourceBudget(jobResources, preserveForegroundSourceAllowance) {
            return .budget(budget)
        }

        var sameRootOthers = WorkspaceCodemapProjectionResourceAccounting.zero
        var globalOthers = WorkspaceCodemapProjectionResourceAccounting.zero
        for other in projectionJobs.values where other.id != jobID {
            switch globalOthers.adding(other.resources) {
            case let .success(value): globalOthers = value
            case let .failure(error): return .budget(projectionOverflowBudget(error))
            }
            if other.rootEpoch == rootEpoch {
                switch sameRootOthers.adding(other.resources) {
                case let .success(value): sameRootOthers = value
                case let .failure(error): return .budget(projectionOverflowBudget(error))
                }
            }
        }
        for (drainingJobID, resources) in drainingProjectionResources {
            switch globalOthers.adding(resources) {
            case let .success(value): globalOthers = value
            case let .failure(error): return .budget(projectionOverflowBudget(error))
            }
            if drainingProjectionRootEpochs[drainingJobID] == rootEpoch {
                switch sameRootOthers.adding(resources) {
                case let .success(value): sameRootOthers = value
                case let .failure(error): return .budget(projectionOverflowBudget(error))
                }
            }
        }
        let rootResources: WorkspaceCodemapProjectionResourceAccounting
        switch sameRootOthers.adding(jobResources) {
        case let .success(value): rootResources = value
        case let .failure(error): return .budget(projectionOverflowBudget(error))
        }
        let globalResources: WorkspaceCodemapProjectionResourceAccounting
        switch globalOthers.adding(jobResources) {
        case let .success(value): globalResources = value
        case let .failure(error): return .budget(projectionOverflowBudget(error))
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
        let projectionUsage = projectionSourceUsage(rootEpoch: rootEpoch)
        if startsMaterialization,
           addingSaturating(
               activeRequests.count,
               addingSaturating(projectionUsage.globalMaterializationCount, 1)
           ) >
           policy.maximumConcurrentMaterializationCount
        {
            return .retry
        }
        if startsMaterialization,
           addingSaturating(
               activeRequests.values.count(where: { $0.rootEpoch == rootEpoch }),
               addingSaturating(projectionUsage.rootMaterializationCount, 1)
           ) > policy.maximumConcurrentMaterializationCountPerRoot
        {
            return .retry
        }
        guard rootResources.retainedProjectionBytes <= policy.maximumRetainedProjectionByteCountPerRoot,
              globalResources.retainedProjectionBytes <= policy.maximumRetainedProjectionByteCount,
              rootResources.stagedGraphBytes <= policy.maximumStagedProjectionGraphByteCountPerRoot,
              globalResources.stagedGraphBytes <= policy.maximumStagedProjectionGraphByteCount,
              rootResources.queuedManifestMutationBytes <=
              policy.maximumQueuedProjectionManifestMutationByteCountPerRoot,
              globalResources.queuedManifestMutationBytes <=
              policy.maximumQueuedProjectionManifestMutationByteCount,
              addingSaturating(rootResources.retainedSourceBytes, rootDemandSourceBytes) <=
              policy.maximumRetainedSourceByteCountPerRoot,
              addingSaturating(
                  addingSaturating(globalResources.retainedSourceBytes, activeDemandSourceBytes),
                  foregroundAllowance
              ) <= policy.maximumRetainedSourceByteCount
        else { return .retry }
        job.resources = jobResources
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
        return .reserved
    }

    private func fixedProjectionResourceBudget(
        _ resources: WorkspaceCodemapProjectionResourceAccounting,
        _ preserveForegroundSourceAllowance: Bool
    ) -> WorkspaceCodemapProjectionBudget? {
        let checks: [(WorkspaceCodemapProjectionBudgetDimension, UInt64, UInt64)] = [
            (
                .retainedProjectionBytes,
                resources.retainedProjectionBytes,
                policy.maximumRetainedProjectionByteCountPerRoot
            ),
            (.retainedProjectionBytes, resources.retainedProjectionBytes, policy.maximumRetainedProjectionByteCount),
            (.stagedGraphBytes, resources.stagedGraphBytes, policy.maximumStagedProjectionGraphByteCountPerRoot),
            (.stagedGraphBytes, resources.stagedGraphBytes, policy.maximumStagedProjectionGraphByteCount),
            (
                .queuedManifestMutationBytes,
                resources.queuedManifestMutationBytes,
                policy.maximumQueuedProjectionManifestMutationByteCountPerRoot
            ),
            (
                .queuedManifestMutationBytes,
                resources.queuedManifestMutationBytes,
                policy.maximumQueuedProjectionManifestMutationByteCount
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
        return WorkspaceCodemapProjectionBudget(
            dimension: failure.0,
            attempted: failure.1,
            limit: failure.2
        )
    }

    private func projectionOverflowBudget(
        _ error: WorkspaceCodemapProjectionAccountingError
    ) -> WorkspaceCodemapProjectionBudget {
        let field: WorkspaceCodemapProjectionAccountingField = switch error {
        case let .overflow(value), let .underflow(value): value
        }
        let dimension: WorkspaceCodemapProjectionBudgetDimension = switch field {
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
        case .retainedProjectionBytes, .publishedSegmentBytes, .publishedSegments:
            .retainedProjectionBytes
        case .supportedCandidates, .processedCandidates, .contributed, .empty,
             .terminalArtifacts, .terminalExcluded, .transient, .catalogPages:
            .catalogEntries
        }
        return WorkspaceCodemapProjectionBudget(dimension: dimension, attempted: .max, limit: .max - 1)
    }

    private func clearProjectionBatchResources(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        job.resources = WorkspaceCodemapProjectionResourceAccounting(
            retainedPathBytes: 0,
            retainedSourceBytes: 0,
            retainedProjectionBytes: 0,
            stagedGraphBytes: 0,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
    }

    private func releaseProjectionSourceBytes(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        byteCount: UInt64
    ) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        let value = job.resources.retainedSourceBytes >= byteCount
            ? job.resources.retainedSourceBytes - byteCount
            : 0
        job.resources = WorkspaceCodemapProjectionResourceAccounting(
            retainedPathBytes: job.resources.retainedPathBytes,
            retainedSourceBytes: value,
            retainedProjectionBytes: job.resources.retainedProjectionBytes,
            stagedGraphBytes: job.resources.stagedGraphBytes,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        projectionJobs[rootEpoch] = job
    }

    private func releaseStagedProjectionBytes(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        byteCount: UInt64
    ) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        job.resources = WorkspaceCodemapProjectionResourceAccounting(
            retainedPathBytes: job.resources.retainedPathBytes,
            retainedSourceBytes: job.resources.retainedSourceBytes,
            retainedProjectionBytes: job.resources.retainedProjectionBytes,
            stagedGraphBytes: job.resources.stagedGraphBytes >= byteCount
                ? job.resources.stagedGraphBytes - byteCount
                : 0,
            residentGraphBytes: job.resources.residentGraphBytes,
            queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes
        )
        projectionJobs[rootEpoch] = job
    }

    private func finishProjectionForBudget(
        jobID: UUID,
        rootEpoch: WorkspaceCodemapRootEpoch,
        budget: WorkspaceCodemapProjectionBudget
    ) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        incrementCounter(\.projectionBudgetRejections)
        emit(
            .projectionBudget,
            rootEpoch: rootEpoch,
            numericValue: budget.attempted,
            projectionPhase: .budgetLimited
        )
        job.phase = .budgetLimited
        job.progress = projectionProgress(job.progress, phase: .budgetLimited)
        job.retry = nil
        job.budget = budget
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
    }

    private func supersedeProjectionJob(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        guard var job = projectionJobs[rootEpoch], job.id == jobID else { return }
        job.phase = .superseded
        job.progress = projectionProgress(job.progress, phase: .superseded)
        job.checkpoint = makeProjectionCheckpoint(job)
        projectionJobs[rootEpoch] = job
        incrementCounter(\.projectionCoveragesSuperseded)
        emit(.projectionCoverageSuperseded, rootEpoch: rootEpoch, projectionPhase: .superseded)
    }

    private func finishProjectionWorker(jobID: UUID, rootEpoch: WorkspaceCodemapRootEpoch) {
        activeProjectionJobIDs.remove(jobID)
        cancelProjectionAdmission(jobID: jobID)
        drainingProjectionTasks.removeValue(forKey: jobID)
        drainingProjectionResources.removeValue(forKey: jobID)
        drainingProjectionRootEpochs.removeValue(forKey: jobID)
        if var job = projectionJobs[rootEpoch], job.id == jobID {
            job.task = nil
            job.isQueuedForAdmission = false
            job.isActiveBatch = false
            job.resources = .zero
            job.checkpoint = makeProjectionCheckpoint(job)
            projectionJobs[rootEpoch] = job
        }
        if let job = projectionJobs[rootEpoch],
           job.id == jobID,
           job.phase == .complete,
           let proofGeneration = job.coverageProof?.generation.contributionGeneration,
           let latestGeneration = latestOverlayContributionGenerationByRootEpoch[rootEpoch],
           proofGeneration < latestGeneration
        {
            _ = restartCompletedProjectionForOverlayAdvance(
                rootEpoch: rootEpoch,
                contributionGeneration: latestGeneration
            )
        }
        scheduleQueuedRequests()
        scheduleProjectionAdmissions()
    }

    @discardableResult
    private func cancelProjectionJob(
        rootEpoch: WorkspaceCodemapRootEpoch,
        terminalPhase: WorkspaceCodemapProjectionPreloadPhase
    ) -> Task<Void, Never>? {
        guard var job = projectionJobs.removeValue(forKey: rootEpoch) else { return nil }
        let wasComplete = job.phase == .complete
        let wasActive = activeProjectionJobIDs.contains(job.id)
        job.phase = terminalPhase
        // An admitted projection transaction is non-preemptive. Revocation removes publication
        // authority immediately, but the worker reaches its existing currentness boundary without
        // task cancellation. A queued worker owns no admitted transaction and may be cancelled.
        if !wasActive, job.resources.retainedSourceBytes == 0 {
            job.task?.cancel()
        }
        let detached = projectionAdmissionQueue.filter { $0.jobID == job.id }
        projectionAdmissionQueue.removeAll { $0.jobID == job.id }
        for waiter in detached {
            waiter.continuation.resume(returning: false)
        }
        if wasActive {
            incrementCounter(\.projectionCancelledBatches)
            emit(.projectionBatchCancelled, rootEpoch: rootEpoch, projectionPhase: terminalPhase)
        }
        projectionRootLastAdmission.removeValue(forKey: rootEpoch)
        if terminalPhase == .cancelled, !wasComplete {
            incrementCounter(\.projectionCoveragesCancelled)
            emit(.projectionCoverageCancelled, rootEpoch: rootEpoch, projectionPhase: .cancelled)
        }
        if let task = job.task, wasActive {
            drainingProjectionTasks[job.id] = task
            drainingProjectionResources[job.id] = job.resources
            drainingProjectionRootEpochs[job.id] = rootEpoch
        }
        if !wasActive { scheduleProjectionAdmissions() }
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
        if pipeline.manifestLoadFinished { return }
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
            if item.key == rootEpoch { return partial }
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
            return .failure(.projectionMissing)
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
        let projectionUsage = projectionSourceUsage(rootEpoch: rootEpoch)
        let rootSourceBytes = rootRequests.reduce(projectionUsage.rootBytes) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let ownerSourceBytes = ownerRequests.reduce(UInt64(0)) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        let globalSourceBytes = activeRequests.values.reduce(projectionUsage.globalBytes) {
            addingSaturating($0, $1.reservedSourceBytes)
        }
        return activeRequests.count < policy.maximumActiveRequestCount &&
            rootRequests.count < policy.maximumActiveRequestCountPerRoot &&
            ownerRequests.count < policy.maximumActiveRequestCountPerOwner &&
            activeRequests.count < policy.maximumActiveTaskCount &&
            rootRequests.count < policy.maximumActiveTaskCountPerRoot &&
            ownerRequests.count < policy.maximumActiveTaskCountPerOwner &&
            addingSaturating(activeRequests.count, projectionUsage.globalMaterializationCount) <
            policy.maximumConcurrentMaterializationCount &&
            addingSaturating(rootRequests.count, projectionUsage.rootMaterializationCount) <
            policy.maximumConcurrentMaterializationCountPerRoot &&
            ownerRequests.count < policy.maximumConcurrentMaterializationCountPerOwner &&
            (owners.contains(demand.owner) || owners.count < policy.maximumOwnerCountPerRoot) &&
            addingSaturating(globalSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCount &&
            addingSaturating(rootSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerRoot &&
            addingSaturating(ownerSourceBytes, sourceBytes) <= policy.maximumRetainedSourceByteCountPerOwner
    }

    private func projectionSourceUsage(
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
        for job in projectionJobs.values where job.resources.retainedSourceBytes > 0 {
            globalBytes = addingSaturating(globalBytes, job.resources.retainedSourceBytes)
            globalMaterializationCount = addingSaturating(globalMaterializationCount, 1)
            if job.rootEpoch == rootEpoch {
                rootBytes = addingSaturating(rootBytes, job.resources.retainedSourceBytes)
                rootMaterializationCount = addingSaturating(rootMaterializationCount, 1)
            }
        }
        for (jobID, resources) in drainingProjectionResources where resources.retainedSourceBytes > 0 {
            globalBytes = addingSaturating(globalBytes, resources.retainedSourceBytes)
            globalMaterializationCount = addingSaturating(globalMaterializationCount, 1)
            if drainingProjectionRootEpochs[jobID] == rootEpoch {
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
            if madeProgress { continue }
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
            if leftRoot != rightRoot { return leftRoot < rightRoot }
            let leftOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: lhs.rootEpoch, owner: lhs.demand.owner)
            ] ?? 0
            let rightOwner = ownerLastAdmission[
                OwnerKey(rootEpoch: rhs.rootEpoch, owner: rhs.demand.owner)
            ] ?? 0
            if leftOwner != rightOwner { return leftOwner < rightOwner }
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
            if lhs.value != rhs.value { return lhs.value < rhs.value }
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
            if lhs.value != rhs.value { return lhs.value < rhs.value }
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
        var projectionOrdinal: UInt64 = 1
        for (key, _) in projectionRootLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let left = lhs.key.rootID.uuidString + lhs.key.rootLifetimeID.uuidString
            let right = rhs.key.rootID.uuidString + rhs.key.rootLifetimeID.uuidString
            return left < right
        }) {
            projectionRootLastAdmission[key] = projectionOrdinal
            projectionOrdinal = addingChecked(projectionOrdinal, 1) ?? .max
        }
        nextAdmissionOrdinal = max(rootOrdinal, max(ownerOrdinal, projectionOrdinal))
    }

    private func pruneAdmissionHistory() {
        var retainedRoots = Set(activeRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(queuedRequests.values.map(\.rootEpoch))
        retainedRoots.formUnion(adoptionReservations.keys.map(\.rootEpoch))
        retainedRoots.formUnion(retainedAdoptions.keys.map(\.rootEpoch))
        retainedRoots.formUnion(projectionDemands.values.map(\.ticket.rootEpoch))
        rootLastAdmission = rootLastAdmission.filter { retainedRoots.contains($0.key) }

        var retainedOwners = Set(activeRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.publicOwner)
        })
        retainedOwners.formUnion(queuedRequests.values.map {
            OwnerKey(rootEpoch: $0.rootEpoch, owner: $0.demand.owner)
        })
        ownerLastAdmission = ownerLastAdmission.filter { retainedOwners.contains($0.key) }
        if activeRequests.isEmpty, queuedRequests.isEmpty, projectionDemands.isEmpty {
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
                if let request = activeRequests[requestID] { recordBusy(request.rootEpoch) }
                result = .busy(retryAfterMilliseconds: retryAfterMilliseconds)
            } else {
                if let request = activeRequests[requestID] { recordFailure(request.rootEpoch) }
                result = .unavailable(.transient)
            }
        } catch {
            if let request = activeRequests[requestID] { recordFailure(request.rootEpoch) }
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
        scheduleProjectionAdmissions()
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
        proof: ManifestMutationProof,
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
        if case let .projection(jobID, _) = proof {
            guard let nextPendingCount = projectionJobs[rootEpoch].flatMap({ job in
                job.id == jobID
                    ? addingChecked(job.pendingManifestMutationCount, UInt64(mutations.count))
                    : nil
            }) else {
                return .budget(WorkspaceCodemapProjectionBudget(
                    dimension: .queuedManifestMutationBytes,
                    attempted: .max,
                    limit: .max - 1
                ))
            }
            switch reserveProjectionResources(
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
            guard var job = projectionJobs[rootEpoch], job.id == jobID else { return .retry }
            job.pendingManifestMutationCount = nextPendingCount
            job.checkpoint = makeProjectionCheckpoint(job)
            projectionJobs[rootEpoch] = job
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
        let succeeded = await waitForManifestRevision(
            scope: scope,
            revision: revision,
            workKey: workKey,
            namespace: pipeline.namespace
        )
        if case let .projection(jobID, _) = proof,
           var job = projectionJobs[rootEpoch], job.id == jobID
        {
            job.resources = WorkspaceCodemapProjectionResourceAccounting(
                retainedPathBytes: job.resources.retainedPathBytes,
                retainedSourceBytes: job.resources.retainedSourceBytes,
                retainedProjectionBytes: job.resources.retainedProjectionBytes,
                stagedGraphBytes: job.resources.stagedGraphBytes,
                residentGraphBytes: job.resources.residentGraphBytes,
                queuedManifestMutationBytes: job.resources.queuedManifestMutationBytes >= byteCount
                    ? job.resources.queuedManifestMutationBytes - byteCount
                    : 0
            )
            job.pendingManifestMutationCount = job.pendingManifestMutationCount >= UInt64(mutations.count)
                ? job.pendingManifestMutationCount - UInt64(mutations.count)
                : 0
            job.checkpoint = makeProjectionCheckpoint(job)
            projectionJobs[rootEpoch] = job
        }
        return succeeded ? .persisted : .durabilityFailure
    }

    private func enqueueManifestWorkItem(
        _ item: ManifestMutationWorkItem,
        namespace: CodeMapRootManifestNamespace
    ) {
        var state = manifestWriters[namespace] ?? ManifestWriterState()
        switch item.proof {
        case .session:
            let insertionIndex = state.queuedWork.firstIndex {
                if case .projection = $0.proof { return true }
                return false
            } ?? state.queuedWork.endIndex
            state.queuedWork.insert(item, at: insertionIndex)
        case .projection:
            state.queuedWork.append(item)
        }
        guard state.writerID == nil else {
            manifestWriters[namespace] = state
            return
        }
        let writerID = UUID()
        state.writerID = writerID
        manifestWriters[namespace] = state
        let task = Task { await self.runManifestWriter(namespace: namespace, writerID: writerID) }
        guard var current = manifestWriters[namespace], current.writerID == writerID else {
            task.cancel()
            return
        }
        current.task = task
        manifestWriters[namespace] = current
    }

    private func runManifestWriter(
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID
    ) async {
        while !Task.isCancelled {
            let item: ManifestMutationWorkItem
            do {
                guard var writer = manifestWriters[namespace], writer.writerID == writerID else { return }
                guard !writer.queuedWork.isEmpty else {
                    let orphaned = writer.waiters
                    writer.waiters.removeAll()
                    writer.writerID = nil
                    writer.task = nil
                    writer.inFlightWork = nil
                    writer.inFlightRevision = nil
                    storeManifestWriterState(writer, namespace: namespace)
                    for waiter in orphaned {
                        waiter.continuation.resume(returning: false)
                    }
                    return
                }
                item = writer.queuedWork.removeFirst()
                writer.inFlightWork = item
                writer.inFlightRevision = item.revision
                manifestWriters[namespace] = writer
            }
            let workKey = item.workKey
            let scope = workKey.scope
            guard case let .eligible(initialSession)? = roots[scope.rootEpoch],
                  initialSession.id == workKey.sessionID,
                  let initialPipeline = initialSession.pipelines[scope.pipelineIdentity],
                  initialPipeline.id == workKey.pipelineSessionID,
                  initialPipeline.namespace == namespace,
                  manifestMutationProofIsCurrent(
                      item.proof,
                      rootEpoch: scope.rootEpoch,
                      session: initialSession,
                      pipeline: initialPipeline
                  )
            else {
                discardManifestWorkItem(item, namespace: namespace, writerID: writerID)
                continue
            }
            var session = initialSession
            var pipeline = initialPipeline
            if item.revision <= pipeline.persistedManifestRevision {
                guard var currentWriter = currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    itemID: item.id
                ) else { return }
                currentWriter.inFlightWork = nil
                currentWriter.inFlightRevision = nil
                let completed = detachManifestWaiters(
                    from: &currentWriter,
                    workKey: workKey,
                    revision: item.revision
                )
                storeManifestWriterState(currentWriter, namespace: namespace)
                for waiter in completed {
                    waiter.continuation.resume(returning: true)
                }
                continue
            }
            if case let .projection(_, generation) = item.proof {
                let tokenDisposition = await catalogClient.revalidateProjectionCatalogToken(
                    scope.rootEpoch,
                    generation.catalogToken
                )
                guard currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    itemID: item.id
                ) != nil else { return }
                guard tokenDisposition == .current,
                      case let .eligible(revalidated)? = roots[scope.rootEpoch],
                      revalidated.id == session.id,
                      let revalidatedPipeline = revalidated.pipelines[scope.pipelineIdentity],
                      revalidatedPipeline.id == pipeline.id,
                      manifestMutationProofIsCurrent(
                          item.proof,
                          rootEpoch: scope.rootEpoch,
                          session: revalidated,
                          pipeline: revalidatedPipeline
                      )
                else {
                    discardManifestWorkItem(item, namespace: namespace, writerID: writerID)
                    continue
                }
                session = revalidated
                pipeline = revalidatedPipeline
            }
            let sessionID = session.id
            let pipelineSessionID = pipeline.id
            let revision = item.revision
            var changes: [String: PendingManifestChange] = Dictionary(
                uniqueKeysWithValues: item.mutations.map { mutation in
                    (
                        mutation.repositoryRelativePath,
                        PendingManifestChange(
                            revision: item.revision,
                            workItemID: item.id,
                            record: mutation.record
                        )
                    )
                }
            )
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
                    itemID: item.id
                ) != nil else { return }
                guard let writerAuthority = claimedWriterAuthority else {
                    throw CodeMapRootManifestStoreError.staleWriterAuthority
                }
                guard case let .eligible(afterAuthority)? = roots[scope.rootEpoch],
                      afterAuthority.id == sessionID,
                      let afterAuthorityPipeline = afterAuthority.pipelines[scope.pipelineIdentity],
                      afterAuthorityPipeline.id == pipelineSessionID,
                      manifestMutationProofIsCurrent(
                          item.proof,
                          rootEpoch: scope.rootEpoch,
                          session: afterAuthority,
                          pipeline: afterAuthorityPipeline
                      )
                else {
                    discardManifestWorkItem(item, namespace: namespace, writerID: writerID)
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
                    itemID: item.id
                ) != nil else { return }
                await hooks.afterManifestStoreWriteBeforeCompletion(scope.rootEpoch)
                guard var currentWriter = currentManifestWriterState(
                    namespace: namespace,
                    writerID: writerID,
                    itemID: item.id
                ) else { return }
                currentWriter.inFlightWork = nil
                currentWriter.inFlightRevision = nil
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
                    itemID: item.id
                ) else { return }
                currentWriter.inFlightWork = nil
                currentWriter.inFlightRevision = nil
                let failed = detachManifestWaiters(
                    from: &currentWriter,
                    workKey: workKey,
                    revision: revision
                )
                storeManifestWriterState(currentWriter, namespace: namespace)
                if case var .eligible(current)? = roots[scope.rootEpoch],
                   current.id == sessionID,
                   var currentPipeline = current.pipelines[scope.pipelineIdentity],
                   currentPipeline.id == pipelineSessionID
                {
                    currentPipeline.manifestState = .dirtyRetryRequired
                    current.pipelines[scope.pipelineIdentity] = currentPipeline
                    roots[scope.rootEpoch] = .eligible(current)
                }
                for waiter in failed {
                    waiter.continuation.resume(returning: false)
                }
                incrementCounter(\.manifestFailures)
                emit(.manifestFailure, rootEpoch: scope.rootEpoch)
            }
        }
    }

    private func discardManifestWorkItem(
        _ item: ManifestMutationWorkItem,
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID
    ) {
        guard var writer = manifestWriters[namespace], writer.writerID == writerID else { return }
        let workKey = item.workKey
        let detached = writer.waiters.filter {
            $0.workKey == workKey && $0.revision <= item.revision
        }
        writer.waiters.removeAll {
            $0.workKey == workKey && $0.revision <= item.revision
        }
        writer.queuedWork.removeAll { $0.id == item.id }
        if writer.inFlightWork?.id == item.id {
            writer.inFlightWork = nil
            writer.inFlightRevision = nil
        }
        if case var .eligible(session)? = roots[workKey.scope.rootEpoch],
           session.id == workKey.sessionID,
           var pipeline = session.pipelines[workKey.scope.pipelineIdentity],
           pipeline.id == workKey.pipelineSessionID
        {
            for (path, change) in pipeline.pendingManifestChanges where change.workItemID == item.id {
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

    private func currentManifestWriterState(
        namespace: CodeMapRootManifestNamespace,
        writerID: UUID,
        itemID: UUID
    ) -> ManifestWriterState? {
        guard let state = manifestWriters[namespace],
              state.writerID == writerID,
              state.inFlightWork?.id == itemID
        else { return nil }
        return state
    }

    private func detachManifestWaiters(
        from writer: inout ManifestWriterState,
        workKey: ManifestWriterWorkKey,
        revision: UInt64
    ) -> [ManifestWriteWaiter] {
        let detached = writer.waiters.filter {
            $0.workKey == workKey && $0.revision <= revision
        }
        writer.waiters.removeAll {
            $0.workKey == workKey && $0.revision <= revision
        }
        return detached
    }

    private func storeManifestWriterState(
        _ state: ManifestWriterState,
        namespace: CodeMapRootManifestNamespace
    ) {
        if state.writerID == nil,
           state.task == nil,
           state.queuedWork.isEmpty,
           state.inFlightWork == nil,
           state.inFlightRevision == nil,
           state.waiters.isEmpty
        {
            manifestWriters.removeValue(forKey: namespace)
        } else {
            manifestWriters[namespace] = state
        }
    }

    private func manifestMutationProofIsCurrent(
        _ proof: ManifestMutationProof,
        rootEpoch: WorkspaceCodemapRootEpoch,
        session: Session,
        pipeline: PipelineSession
    ) -> Bool {
        switch proof {
        case let .session(invalidationGeneration):
            return session.capability.rootEpoch == rootEpoch &&
                session.invalidationGeneration == invalidationGeneration
        case let .projection(jobID, generation):
            guard let job = projectionJobs[rootEpoch],
                  job.id == jobID,
                  projectionJobIsCurrent(job),
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
        let limit = policy.maximumQueuedProjectionManifestMutationByteCountPerRoot
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
        if !batch.isEmpty { batches.append(batch) }
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
        if pipeline.persistedManifestRevision >= revision { return true }
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
                } || (state.inFlightWork?.workKey == workKey && (state.inFlightRevision ?? 0) >= revision)
                guard hasRelevantWork else {
                    continuation.resume(returning: false)
                    return
                }
                state.waiters.append(ManifestWriteWaiter(
                    id: waiterID,
                    workKey: workKey,
                    revision: revision,
                    continuation: continuation
                ))
                manifestWriters[namespace] = state
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
              let index = state.waiters.firstIndex(where: { $0.id == waiterID })
        else {
            if pendingManifestWaiterInstalls.contains(waiterID) {
                cancelledManifestWaiterInstalls.insert(waiterID)
            }
            return
        }
        let waiter = state.waiters.remove(at: index)
        storeManifestWriterState(state, namespace: namespace)
        waiter.continuation.resume(returning: false)
    }

    private func detachManifestWriters(rootEpoch: WorkspaceCodemapRootEpoch) {
        for namespace in Array(manifestWriters.keys) {
            guard var state = manifestWriters[namespace] else { continue }
            state.queuedWork.removeAll { $0.workKey.scope.rootEpoch == rootEpoch }
            let detached = state.waiters.filter { $0.workKey.scope.rootEpoch == rootEpoch }
            state.waiters.removeAll { $0.workKey.scope.rootEpoch == rootEpoch }
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
            for waiter in state.waiters {
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
        revokeProjectionDemands(rootEpoch: rootEpoch, status: .stale)
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
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

        _ = cancelProjectionJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)

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
        revokeProjectionDemands(rootEpoch: rootEpoch, status: .stale)
        if case let .registering(attempt)? = roots[rootEpoch] {
            replacementCancelledRegistrationAttemptIDs.insert(attempt.id)
            roots.removeValue(forKey: rootEpoch)
            pruneAdmissionHistory()
            await capabilityService.invalidateForAuthorityReplacement(rootEpoch: rootEpoch)
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
        _ = cancelProjectionJob(rootEpoch: rootEpoch, terminalPhase: .cancelled)
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
        scheduleProjectionAdmissions()
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
        if prefix.isEmpty { return path }
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
        projectionPhase: WorkspaceCodemapProjectionPreloadPhase? = nil,
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
            projectionPhase: projectionPhase,
            retryAfterMilliseconds: retryAfterMilliseconds,
            publishedArtifactLookupSource: publishedArtifactLookupSource,
            publishedArtifactLookupMissReason: publishedArtifactLookupMissReason,
            invalidationReason: invalidationReason
        ))
    }
}
