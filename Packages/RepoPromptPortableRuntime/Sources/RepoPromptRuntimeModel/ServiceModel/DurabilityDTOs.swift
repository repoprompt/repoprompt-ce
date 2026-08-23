import Foundation

public enum OwnedResourceKind: String, Codable, CaseIterable, Sendable {
    case worktree
    case artifact
    case artifactTemporary = "artifact_temporary"
    case mergeConflict = "merge_conflict"
    case providerHome = "provider_home"
    case providerCredentialCopy = "provider_credential_copy"
    case providerOutput = "provider_output"
    case cloneStaging = "clone_staging"
    case indexGeneration = "index_generation"
}

public enum OwnedResourceLifecycleState: String, Codable, CaseIterable, Sendable {
    case preparing
    case prepared
    case active
    case cleanupPending = "cleanup_pending"
    case quarantined
    case missing
    case corrupt
    case conflicted
    case released
    case deleted
    case failed

    public var isTerminal: Bool {
        switch self {
        case .released, .deleted, .failed: true
        default: false
        }
    }
}

public struct OwnedResourceRecord: Codable, Hashable, Sendable {
    public let resourceID: UUID
    public let kind: OwnedResourceKind
    public let projectID: UUID?
    public let sessionID: UUID?
    public let runID: UUID?
    public let externalID: UUID?
    public let internalPathIdentity: String
    public let temporaryPathIdentity: String?
    public let lifecycleState: OwnedResourceLifecycleState
    public let observedBytes: Int64?
    public let contentDigest: String?
    public let metadata: [String: String]
    public let retentionDeadline: Date?
    public let cleanupAttempts: Int
    public let cleanupError: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        resourceID: UUID = UUID(),
        kind: OwnedResourceKind,
        projectID: UUID? = nil,
        sessionID: UUID? = nil,
        runID: UUID? = nil,
        externalID: UUID? = nil,
        internalPathIdentity: String,
        temporaryPathIdentity: String? = nil,
        lifecycleState: OwnedResourceLifecycleState = .preparing,
        observedBytes: Int64? = nil,
        contentDigest: String? = nil,
        metadata: [String: String] = [:],
        retentionDeadline: Date? = nil,
        cleanupAttempts: Int = 0,
        cleanupError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.resourceID = resourceID
        self.kind = kind
        self.projectID = projectID
        self.sessionID = sessionID
        self.runID = runID
        self.externalID = externalID
        self.internalPathIdentity = internalPathIdentity
        self.temporaryPathIdentity = temporaryPathIdentity
        self.lifecycleState = lifecycleState
        self.observedBytes = observedBytes
        self.contentDigest = contentDigest
        self.metadata = metadata
        self.retentionDeadline = retentionDeadline
        self.cleanupAttempts = cleanupAttempts
        self.cleanupError = cleanupError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func replacing(
        lifecycleState: OwnedResourceLifecycleState,
        observedBytes: Int64? = nil,
        contentDigest: String? = nil,
        cleanupError: String? = nil,
        updatedAt: Date = Date()
    ) -> Self {
        Self(
            resourceID: resourceID,
            kind: kind,
            projectID: projectID,
            sessionID: sessionID,
            runID: runID,
            externalID: externalID,
            internalPathIdentity: internalPathIdentity,
            temporaryPathIdentity: temporaryPathIdentity,
            lifecycleState: lifecycleState,
            observedBytes: observedBytes ?? self.observedBytes,
            contentDigest: contentDigest ?? self.contentDigest,
            metadata: metadata,
            retentionDeadline: retentionDeadline,
            cleanupAttempts: cleanupError == nil ? cleanupAttempts : cleanupAttempts + 1,
            cleanupError: cleanupError,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID = "resourceId"
        case kind
        case projectID = "projectId"
        case sessionID = "sessionId"
        case runID = "runId"
        case externalID = "externalId"
        case internalPathIdentity
        case temporaryPathIdentity
        case lifecycleState
        case observedBytes
        case contentDigest
        case metadata
        case retentionDeadline
        case cleanupAttempts
        case cleanupError
        case createdAt
        case updatedAt
    }
}

public enum WorktreeMergeLeaseState: String, Codable, CaseIterable, Sendable {
    case preparing
    case running
    case prepared
    case conflicted
    case aborted
    case committed
    case failed

    public var isTerminal: Bool {
        switch self {
        case .aborted, .committed, .failed: true
        default: false
        }
    }
}

public struct WorktreeMergeLeaseRecord: Codable, Hashable, Sendable {
    public let leaseID: UUID
    public let bindingID: UUID
    public let expectedBindingRevision: Int64
    public let strategy: String
    public let targetPath: String
    public let preMergeHead: String
    public let state: WorktreeMergeLeaseState
    public let ownerInstanceID: UUID
    public let conflictArtifactPath: String?
    public let errorCode: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let expiresAt: Date

    public init(
        leaseID: UUID = UUID(),
        bindingID: UUID,
        expectedBindingRevision: Int64,
        strategy: String,
        targetPath: String,
        preMergeHead: String,
        state: WorktreeMergeLeaseState = .preparing,
        ownerInstanceID: UUID,
        conflictArtifactPath: String? = nil,
        errorCode: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.leaseID = leaseID
        self.bindingID = bindingID
        self.expectedBindingRevision = expectedBindingRevision
        self.strategy = strategy
        self.targetPath = targetPath
        self.preMergeHead = preMergeHead
        self.state = state
        self.ownerInstanceID = ownerInstanceID
        self.conflictArtifactPath = conflictArtifactPath
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case leaseID = "leaseId"
        case bindingID = "bindingId"
        case expectedBindingRevision
        case strategy
        case targetPath
        case preMergeHead
        case state
        case ownerInstanceID = "ownerInstanceId"
        case conflictArtifactPath
        case errorCode
        case startedAt
        case updatedAt
        case expiresAt
    }
}

public struct OwnedResourceAggregate: Codable, Hashable, Sendable {
    public let kind: OwnedResourceKind
    public let state: OwnedResourceLifecycleState
    public let count: Int
    public let bytes: Int64
    public let oldestAgeSeconds: Double

    public init(
        kind: OwnedResourceKind,
        state: OwnedResourceLifecycleState,
        count: Int,
        bytes: Int64,
        oldestAgeSeconds: Double
    ) {
        self.kind = kind
        self.state = state
        self.count = count
        self.bytes = bytes
        self.oldestAgeSeconds = oldestAgeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case state
        case count
        case bytes
        case oldestAgeSeconds
    }
}

public struct OwnedResourceHealthSnapshot: Codable, Hashable, Sendable {
    public let aggregates: [OwnedResourceAggregate]
    public let cleanupFailures: Int
    public let missingCommittedArtifacts: Int
    public let unhealthyCommittedResources: Int
    public let abandonedReservations: Int
    public let conflictedMergeLeases: Int
    public let expiredMergeLeases: Int

    public init(
        aggregates: [OwnedResourceAggregate] = [],
        cleanupFailures: Int = 0,
        missingCommittedArtifacts: Int = 0,
        unhealthyCommittedResources: Int = 0,
        abandonedReservations: Int = 0,
        conflictedMergeLeases: Int = 0,
        expiredMergeLeases: Int = 0
    ) {
        self.aggregates = aggregates
        self.cleanupFailures = cleanupFailures
        self.missingCommittedArtifacts = missingCommittedArtifacts
        self.unhealthyCommittedResources = unhealthyCommittedResources
        self.abandonedReservations = abandonedReservations
        self.conflictedMergeLeases = conflictedMergeLeases
        self.expiredMergeLeases = expiredMergeLeases
    }

    public var ready: Bool {
        cleanupFailures == 0 && missingCommittedArtifacts == 0 && unhealthyCommittedResources == 0 && abandonedReservations == 0 && conflictedMergeLeases == 0 && expiredMergeLeases == 0
    }

    private enum CodingKeys: String, CodingKey {
        case aggregates
        case cleanupFailures
        case missingCommittedArtifacts
        case unhealthyCommittedResources
        case abandonedReservations
        case conflictedMergeLeases
        case expiredMergeLeases
    }
}

public struct ActiveOwnedWorktreeSnapshot: Hashable, Sendable {
    public let bindingID: UUID
    public let projectID: UUID
    public let rootID: UUID
    public let sessionID: UUID
    public let physicalPath: String
    public let sourceRoot: String
    public let branch: String

    public init(bindingID: UUID, projectID: UUID, rootID: UUID, sessionID: UUID, physicalPath: String, sourceRoot: String, branch: String) {
        self.bindingID = bindingID
        self.projectID = projectID
        self.rootID = rootID
        self.sessionID = sessionID
        self.physicalPath = physicalPath
        self.sourceRoot = sourceRoot
        self.branch = branch
    }
}

public protocol OwnedResourceRepository: Sendable {
    func reserveOwnedResource(_ record: OwnedResourceRecord) async throws
    func ownedResource(externalID: UUID, kind: OwnedResourceKind) async throws -> OwnedResourceRecord?
    func ownedResources(states: Set<OwnedResourceLifecycleState>?) async throws -> [OwnedResourceRecord]
    func activeOwnedWorktree(bindingID: UUID) async throws -> ActiveOwnedWorktreeSnapshot?
    func backfillActiveWorktreeContentDigest(
        resourceID: UUID,
        authority: ActiveOwnedWorktreeSnapshot,
        contentDigest: String
    ) async throws -> OwnedResourceRecord
    func transitionOwnedResource(
        resourceID: UUID,
        expectedStates: Set<OwnedResourceLifecycleState>,
        to state: OwnedResourceLifecycleState,
        observedBytes: Int64?,
        contentDigest: String?,
        cleanupError: String?
    ) async throws -> OwnedResourceRecord
    func acquireWorktreeMergeLease(_ lease: WorktreeMergeLeaseRecord) async throws
    func renewWorktreeMergeLease(leaseID: UUID, ownerInstanceID: UUID, expiresAt: Date) async throws
    func transitionWorktreeMergeLease(
        leaseID: UUID,
        expectedStates: Set<WorktreeMergeLeaseState>,
        to state: WorktreeMergeLeaseState,
        conflictArtifactPath: String?,
        errorCode: String?
    ) async throws -> WorktreeMergeLeaseRecord
    func worktreeMergeLeases(nonterminalOnly: Bool) async throws -> [WorktreeMergeLeaseRecord]
    func ownedResourceHealth(now: Date) async throws -> OwnedResourceHealthSnapshot
}
