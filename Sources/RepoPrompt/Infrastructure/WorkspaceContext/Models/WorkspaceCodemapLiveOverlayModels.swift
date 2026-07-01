import Foundation

// Explicit checked conformances are intentional actor-boundary contracts.
// swiftformat:disable redundantSendable

struct WorkspaceCodemapLiveOverlayPolicy: Equatable, Sendable {
    static let `default` = WorkspaceCodemapLiveOverlayPolicy()

    let maximumRootCount: Int
    let maximumEntryCountPerRoot: Int
    let maximumEntryCount: Int
    let maximumWaiterCountPerEntry: Int
    let maximumWaiterCountPerRoot: Int
    let maximumWaiterCount: Int
    let maximumLeaseCountPerRoot: Int
    let maximumLeaseCount: Int
    let maximumArtifactByteCountPerRoot: UInt64
    let maximumArtifactByteCount: UInt64
    let maximumManifestRecordCount: Int
    let maximumManifestEstimatedByteCount: UInt64
    let maximumAdmissionReservationCountPerRoot: Int
    let maximumAdmissionReservationCount: Int

    init(
        maximumRootCount: Int = 64,
        maximumEntryCountPerRoot: Int = 8192,
        maximumEntryCount: Int = 32768,
        maximumWaiterCountPerEntry: Int = 64,
        maximumWaiterCountPerRoot: Int = 4096,
        maximumWaiterCount: Int = 16384,
        maximumLeaseCountPerRoot: Int = 4096,
        maximumLeaseCount: Int = 16384,
        maximumArtifactByteCountPerRoot: UInt64 = 256 * 1024 * 1024,
        maximumArtifactByteCount: UInt64 = 1024 * 1024 * 1024,
        maximumManifestRecordCount: Int = 8192,
        maximumManifestEstimatedByteCount: UInt64 = 16 * 1024 * 1024,
        maximumAdmissionReservationCountPerRoot: Int = 1024,
        maximumAdmissionReservationCount: Int = 4096
    ) {
        self.maximumRootCount = max(1, maximumRootCount)
        self.maximumEntryCountPerRoot = max(1, maximumEntryCountPerRoot)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumWaiterCountPerEntry = max(1, maximumWaiterCountPerEntry)
        self.maximumWaiterCountPerRoot = max(1, maximumWaiterCountPerRoot)
        self.maximumWaiterCount = max(1, maximumWaiterCount)
        self.maximumLeaseCountPerRoot = max(1, maximumLeaseCountPerRoot)
        self.maximumLeaseCount = max(1, maximumLeaseCount)
        self.maximumArtifactByteCountPerRoot = max(1, maximumArtifactByteCountPerRoot)
        self.maximumArtifactByteCount = max(1, maximumArtifactByteCount)
        self.maximumManifestRecordCount = max(1, maximumManifestRecordCount)
        self.maximumManifestEstimatedByteCount = max(1, maximumManifestEstimatedByteCount)
        self.maximumAdmissionReservationCountPerRoot = max(1, maximumAdmissionReservationCountPerRoot)
        self.maximumAdmissionReservationCount = max(1, maximumAdmissionReservationCount)
    }
}

enum WorkspaceCodemapLiveOverlayBusyReason: Equatable, Sendable {
    case rootLimit
    case entryLimit
    case waiterLimit
    case leaseLimit
    case artifactByteLimit
    case manifestLimit
    case admissionQueueLimit
}

enum WorkspaceCodemapLiveOverlayRegistrationRejection: Equatable, Sendable {
    case capabilityUnavailable
    case rootEpochMismatch
    case staleNamespace
    case namespaceMismatch
    case authorityMismatch
    case catalogGenerationInvalid
    case rootEpochAlreadyBound
}

enum WorkspaceCodemapLiveOverlayRegistrationDisposition: Equatable, Sendable {
    case registered
    case exactDuplicate
    case busy(WorkspaceCodemapLiveOverlayBusyReason)
    case rejected(WorkspaceCodemapLiveOverlayRegistrationRejection)
}

enum WorkspaceCodemapLiveOverlaySource: Equatable, Sendable {
    case cleanManifest
    case live
}

enum WorkspaceCodemapLiveOverlayInvalidationReason: Equatable, Sendable {
    case modified
    case deleted
    case renamed
    case watcherGap
    case checkoutChanged
    case authorityChanged
    case catalogChanged
    case evicted
}

enum WorkspaceCodemapLiveOverlayUnavailableReason: Equatable, Sendable {
    case unsupportedFileType
    case transient
    case securityExcluded
    case terminalArtifact(WorkspaceCodemapLiveArtifactOutcome)
    case invalidated(WorkspaceCodemapLiveOverlayInvalidationReason)
}

enum WorkspaceCodemapLiveArtifactOutcome: Equatable, Sendable {
    case ready
    case readyNoSymbols
    case oversize
    case decodeFailed
    case parseFailed

    init(_ outcome: CodeMapSyntaxArtifactOutcome) {
        self = switch outcome {
        case .ready: .ready
        case .readyNoSymbols: .readyNoSymbols
        case .oversize: .oversize
        case .decodeFailed: .decodeFailed
        case .parseFailed: .parseFailed
        }
    }
}

struct WorkspaceCodemapLiveDemandOwner: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct WorkspaceCodemapLiveDemandTicket: Hashable, Sendable {
    let token: WorkspaceCodemapArtifactRequestToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let requestID: UUID
}

struct WorkspaceCodemapLiveDemandReservation: Hashable, Sendable {
    let owner: WorkspaceCodemapLiveDemandOwner
    let token: WorkspaceCodemapArtifactRequestToken
    let reservationID: UUID
}

struct WorkspaceCodemapLiveDemandPreflightTicket: Hashable, Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let owner: WorkspaceCodemapLiveDemandOwner
    let reservationID: UUID
}

enum WorkspaceCodemapLiveDemandPreflightDisposition: Sendable {
    case reserved(WorkspaceCodemapLiveDemandPreflightTicket)
    case ready(WorkspaceCodemapLiveReadySnapshot)
    case busy(WorkspaceCodemapLiveOverlayBusyReason)
    case rejected(WorkspaceCodemapLiveDemandRejection)
}

enum WorkspaceCodemapLiveDemandRejection: Equatable, Sendable {
    case rootNotRegistered
    case rootAuthorityInvalid
    case rootEpochMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case invalidToken
    case pathOutsideRoot
    case staleRequestGeneration
    case requestGenerationConflict
    case admissionReservationInvalid
}

enum WorkspaceCodemapLiveDemandDisposition: Sendable {
    case queued(WorkspaceCodemapLiveDemandReservation)
    case started(WorkspaceCodemapLiveDemandTicket)
    case joined(WorkspaceCodemapLiveDemandTicket)
    case ready(WorkspaceCodemapLiveReadySnapshot)
    case busy(WorkspaceCodemapLiveOverlayBusyReason)
    case rejected(WorkspaceCodemapLiveDemandRejection)
}

enum WorkspaceCodemapLiveCompletionRejection: Equatable, Sendable {
    case rootNotRegistered
    case rootAuthorityInvalid
    case pendingRequestMissing
    case staleTicket
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case binding(WorkspaceCodemapArtifactCompletionDisposition)
    case artifactHandleMismatch
    case contributionGenerationMismatch
}

enum WorkspaceCodemapLiveCompletionDisposition: Sendable {
    case accepted(WorkspaceCodemapLiveReadySnapshot)
    case acceptedUnavailable(WorkspaceCodemapLiveArtifactOutcome)
    case exactDuplicate(WorkspaceCodemapLiveReadySnapshot)
    case busy(WorkspaceCodemapLiveOverlayBusyReason)
    case rejected(WorkspaceCodemapLiveCompletionRejection)
}

enum WorkspaceCodemapLiveUnavailableRejection: Equatable, Sendable {
    case rootNotRegistered
    case rootAuthorityInvalid
    case pendingRequestMissing
    case staleTicket
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case contributionGenerationMismatch
    case invalidReason
}

enum WorkspaceCodemapLiveUnavailableDisposition: Equatable, Sendable {
    case accepted
    case exactDuplicate
    case rejected(WorkspaceCodemapLiveUnavailableRejection)
}

struct WorkspaceCodemapLiveManifestAdoptionTicket: Hashable, Sendable {
    let operationID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let pipelineIdentity: CodeMapPipelineIdentity
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let invalidationGeneration: UInt64
}

enum WorkspaceCodemapLiveManifestAdoptionRejection: Equatable, Sendable {
    case rootNotRegistered
    case rootAuthorityInvalid
    case namespaceMismatch
    case authorityMismatch
    case recordMissing
    case duplicateEntry
    case bindingMismatch
    case artifactHandleMismatch
    case contributionMismatch
    case staleLoad
    case staleManifestGeneration
    case manifestGenerationConflict
}

enum WorkspaceCodemapLiveManifestAdoptionDisposition: Equatable, Sendable {
    case adopted(readyEntryCount: Int)
    case exactDuplicate(readyEntryCount: Int)
    case busy(WorkspaceCodemapLiveOverlayBusyReason)
    case rejected(WorkspaceCodemapLiveManifestAdoptionRejection)
}

struct WorkspaceCodemapLiveManifestAdoptionEntry: Sendable {
    let record: CodeMapRootManifestRecord
    let binding: WorkspaceCodemapArtifactBinding
    let lease: CodeMapArtifactLease
}

enum WorkspaceCodemapLiveEntryStateSnapshot: Equatable, Sendable {
    case ready(
        source: WorkspaceCodemapLiveOverlaySource,
        artifactKey: CodeMapArtifactKey,
        outcome: WorkspaceCodemapLiveArtifactOutcome
    )
    case pending(waiterCount: Int)
    case unavailable(WorkspaceCodemapLiveOverlayUnavailableReason)
    case shadowed(WorkspaceCodemapLiveOverlayInvalidationReason)
}

struct WorkspaceCodemapLiveEntrySnapshot: Equatable, Sendable {
    let fileID: UUID?
    let standardizedRelativePath: String
    let requestGeneration: UInt64?
    let state: WorkspaceCodemapLiveEntryStateSnapshot
}

struct WorkspaceCodemapLiveRootSnapshot: Equatable, Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let authorityIsCurrent: Bool
    let manifestGeneration: UInt64?
    let entries: [WorkspaceCodemapLiveEntrySnapshot]
}

struct WorkspaceCodemapLiveReadySnapshot: Equatable, Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let standardizedRelativePath: String
    let requestGeneration: UInt64
    let source: WorkspaceCodemapLiveOverlaySource
    let artifactKey: CodeMapArtifactKey
    let outcome: WorkspaceCodemapLiveArtifactOutcome
}

enum WorkspaceCodemapLiveOverlayBundleAccessError: Error, Equatable, Sendable {
    case closed
    case entryUnavailable
}

private struct WorkspaceCodemapLiveOverlayBundleEntry {
    let snapshot: WorkspaceCodemapLiveReadySnapshot
    let binding: WorkspaceCodemapArtifactBinding
    let leaseOwner: WorkspaceCodemapSharedArtifactLease
}

/// `entries` is the only mutable field and every read, close, and handle access
/// is linearized by `lock`. Closing replaces the entry array with `nil`, so
/// retained frozen handles cannot recover a raw CAS handle after revocation.
private final class WorkspaceCodemapLiveOverlayBundleState: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WorkspaceCodemapLiveOverlayBundleEntry]?

    init(entries: [WorkspaceCodemapLiveOverlayBundleEntry]) {
        self.entries = entries
    }

    var isClosed: Bool {
        lock.withLock { entries == nil }
    }

    func snapshotsOrEmpty() -> [WorkspaceCodemapLiveReadySnapshot] {
        lock.withLock { entries?.map(\.snapshot) ?? [] }
    }

    func snapshots() throws -> [WorkspaceCodemapLiveReadySnapshot] {
        try lock.withLock {
            guard let entries else { throw WorkspaceCodemapLiveOverlayBundleAccessError.closed }
            return entries.map(\.snapshot)
        }
    }

    func bindings() throws -> [WorkspaceCodemapArtifactBinding] {
        try lock.withLock {
            guard let entries else { throw WorkspaceCodemapLiveOverlayBundleAccessError.closed }
            return entries.map(\.binding)
        }
    }

    func contains(fileID: UUID) throws -> Bool {
        try lock.withLock {
            guard let entries else { throw WorkspaceCodemapLiveOverlayBundleAccessError.closed }
            return entries.contains { $0.snapshot.fileID == fileID }
        }
    }

    func retainingLeaseOwner(fileID: UUID) throws -> WorkspaceCodemapSharedArtifactLease? {
        try lock.withLock {
            guard let entries else { throw WorkspaceCodemapLiveOverlayBundleAccessError.closed }
            return entries.first(where: { $0.snapshot.fileID == fileID })?.leaseOwner
        }
    }

    func withHandle<T>(
        fileID: UUID,
        retainedLeaseOwner: WorkspaceCodemapSharedArtifactLease? = nil,
        _ body: (CodeMapArtifactHandle) throws -> T
    ) throws -> T? {
        try lock.withLock {
            guard let entries else { throw WorkspaceCodemapLiveOverlayBundleAccessError.closed }
            guard let entry = entries.first(where: { $0.snapshot.fileID == fileID }) else { return nil }
            return try body((retainedLeaseOwner ?? entry.leaseOwner).lease.handle)
        }
    }

    func close() {
        lock.withLock { entries = nil }
    }
}

struct WorkspaceCodemapLiveFrozenArtifactHandle: Sendable {
    private let fileID: UUID
    private let state: WorkspaceCodemapLiveOverlayBundleState
    private let retainedLeaseOwner: WorkspaceCodemapSharedArtifactLease?

    fileprivate init(
        fileID: UUID,
        state: WorkspaceCodemapLiveOverlayBundleState,
        retainedLeaseOwner: WorkspaceCodemapSharedArtifactLease? = nil
    ) {
        self.fileID = fileID
        self.state = state
        self.retainedLeaseOwner = retainedLeaseOwner
    }

    func retainingLease() throws -> WorkspaceCodemapLiveFrozenArtifactHandle {
        guard let leaseOwner = try state.retainingLeaseOwner(fileID: fileID) else {
            throw WorkspaceCodemapLiveOverlayBundleAccessError.entryUnavailable
        }
        return WorkspaceCodemapLiveFrozenArtifactHandle(
            fileID: fileID,
            state: state,
            retainedLeaseOwner: leaseOwner
        )
    }

    func artifactKey() throws -> CodeMapArtifactKey {
        guard let key = try state.withHandle(
            fileID: fileID,
            retainedLeaseOwner: retainedLeaseOwner,
            { $0.key }
        ) else {
            throw WorkspaceCodemapLiveOverlayBundleAccessError.entryUnavailable
        }
        return key
    }

    func outcome() throws -> WorkspaceCodemapLiveArtifactOutcome {
        guard let outcome = try state.withHandle(
            fileID: fileID,
            retainedLeaseOwner: retainedLeaseOwner,
            { WorkspaceCodemapLiveArtifactOutcome($0.outcome) }
        ) else {
            throw WorkspaceCodemapLiveOverlayBundleAccessError.entryUnavailable
        }
        return outcome
    }

    func renderedCodemap(displayPath: String) throws -> WorkspaceCodemapArtifactRenderedCodemap? {
        try state.withHandle(
            fileID: fileID,
            retainedLeaseOwner: retainedLeaseOwner
        ) { handle in
            guard case let .ready(artifact) = handle.outcome else { return nil }
            let text = CodeMapAPIContentFormatter.pathAndImportsBlock(
                displayPath: displayPath,
                imports: artifact.imports
            ) + artifact.apiDescription
            return WorkspaceCodemapArtifactRenderedCodemap(
                text: text,
                tokenCount: TokenCalculationService.estimateTokens(for: text)
            )
        } ?? nil
    }
}

/// The lock-backed state is the sole mutable member; immutable bundle identity
/// is safe to share and all revocable content access is delegated to that state.
final class WorkspaceCodemapLiveOverlayBundle: @unchecked Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration

    private let state: WorkspaceCodemapLiveOverlayBundleState

    var entries: [WorkspaceCodemapLiveReadySnapshot] {
        state.snapshotsOrEmpty()
    }

    var isClosed: Bool {
        state.isClosed
    }

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogGeneration: UInt64,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        entries: [WorkspaceCodemapLiveReadySnapshot],
        bindings: [WorkspaceCodemapArtifactBinding],
        leaseOwners: [WorkspaceCodemapSharedArtifactLease]
    ) {
        precondition(entries.count == bindings.count && entries.count == leaseOwners.count)
        self.rootEpoch = rootEpoch
        self.catalogGeneration = catalogGeneration
        self.repositoryAuthority = repositoryAuthority
        self.contributionGeneration = contributionGeneration
        state = WorkspaceCodemapLiveOverlayBundleState(entries: zip(entries.indices, entries).map { index, snapshot in
            WorkspaceCodemapLiveOverlayBundleEntry(
                snapshot: snapshot,
                binding: bindings[index],
                leaseOwner: leaseOwners[index]
            )
        })
    }

    func snapshot() throws -> [WorkspaceCodemapLiveReadySnapshot] {
        try state.snapshots()
    }

    func graphSnapshot() throws -> WorkspaceCodemapLiveGraphSnapshot {
        try WorkspaceCodemapLiveGraphSnapshot(
            rootEpoch: rootEpoch,
            catalogGeneration: catalogGeneration,
            repositoryAuthority: repositoryAuthority,
            contributionGeneration: contributionGeneration,
            bindings: state.bindings()
        )
    }

    func handle(for fileID: UUID) throws -> WorkspaceCodemapLiveFrozenArtifactHandle? {
        guard try state.contains(fileID: fileID) else { return nil }
        return WorkspaceCodemapLiveFrozenArtifactHandle(fileID: fileID, state: state)
    }

    func renderedCodemap(
        for fileID: UUID,
        displayPath: String
    ) throws -> WorkspaceCodemapArtifactRenderedCodemap? {
        guard let handle = try handle(for: fileID) else { return nil }
        return try handle.renderedCodemap(displayPath: displayPath)
    }

    func close() {
        state.close()
    }

    deinit {
        close()
    }
}

struct WorkspaceCodemapLiveGraphSnapshot: Equatable, Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let bindings: [WorkspaceCodemapArtifactBinding]
}

struct WorkspaceCodemapLiveOverlayRootAccounting: Equatable, Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let entryCount: Int
    let readyEntryCount: Int
    let pendingEntryCount: Int
    let unavailableEntryCount: Int
    let shadowEntryCount: Int
    let waiterCount: Int
    let leaseCount: Int
    let artifactByteCount: UInt64
    let admissionReservationCount: Int
}

struct WorkspaceCodemapLiveOverlayAccounting: Equatable, Sendable {
    let rootCount: Int
    let entryCount: Int
    let readyEntryCount: Int
    let pendingEntryCount: Int
    let unavailableEntryCount: Int
    let shadowEntryCount: Int
    let waiterCount: Int
    let leaseCount: Int
    let artifactByteCount: UInt64
    let admissionReservationCount: Int
    let evictionCount: UInt64
    let busyDropCount: UInt64
    let staleCompletionDropCount: UInt64
    let roots: [WorkspaceCodemapLiveOverlayRootAccounting]
}

final class WorkspaceCodemapSharedArtifactLease: Sendable {
    let lease: CodeMapArtifactLease

    init(_ lease: CodeMapArtifactLease) {
        self.lease = lease
    }

    deinit {
        lease.closeSynchronously()
    }
}
