import Foundation

struct CodeMapArtifactStorePolicy: Equatable {
    static let `default` = CodeMapArtifactStorePolicy()

    let residentPositiveEntryLimit: Int
    let residentPositiveByteLimit: UInt64
    let residentNegativeEntryLimit: Int
    let residentNegativeByteLimit: UInt64
    let softQuotaBytes: UInt64
    let hardQuotaBytes: UInt64
    let unreferencedGraceSeconds: UInt64
    let quarantineDelaySeconds: UInt64
    let negativeQuotaBytes: UInt64
    let negativeMaximumAgeSeconds: UInt64
    let maximumCatalogRecordCount: Int
    let maximumCatalogScanByteCount: Int
    let maximumArtifactScanCount: Int
    let maximumArtifactReconciliationByteCount: UInt64
    let maximumMaintenanceWriteByteCount: UInt64
    let maximumQuarantineEpochCount: Int
    let maximumMetadataRecordByteCount: Int
    let maximumGCStepBudget: Int
    let maximumActiveLeaseCount: Int
    let maximumActiveLeaseBytes: UInt64
    let containerPolicy: CodeMapArtifactContainerPolicy

    init(
        residentPositiveEntryLimit: Int = 512,
        residentPositiveByteLimit: UInt64 = 64 * 1024 * 1024,
        residentNegativeEntryLimit: Int = 1024,
        residentNegativeByteLimit: UInt64 = 4 * 1024 * 1024,
        softQuotaBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        hardQuotaBytes: UInt64 = 3 * 1024 * 1024 * 1024,
        unreferencedGraceSeconds: UInt64 = 30 * 24 * 60 * 60,
        quarantineDelaySeconds: UInt64 = 24 * 60 * 60,
        negativeQuotaBytes: UInt64 = 64 * 1024 * 1024,
        negativeMaximumAgeSeconds: UInt64 = 30 * 24 * 60 * 60,
        maximumCatalogRecordCount: Int = 65536,
        maximumCatalogScanByteCount: Int = 64 * 1024 * 1024,
        maximumArtifactScanCount: Int = 65536,
        maximumArtifactReconciliationByteCount: UInt64 = 128 * 1024 * 1024,
        maximumMaintenanceWriteByteCount: UInt64 = 8 * 1024 * 1024,
        maximumQuarantineEpochCount: Int = 4096,
        maximumMetadataRecordByteCount: Int = 64 * 1024,
        maximumGCStepBudget: Int = 4096,
        maximumActiveLeaseCount: Int = 128,
        maximumActiveLeaseBytes: UInt64 = 512 * 1024 * 1024,
        containerPolicy: CodeMapArtifactContainerPolicy = .default
    ) {
        precondition(residentPositiveEntryLimit >= 0)
        precondition(residentNegativeEntryLimit >= 0)
        precondition(softQuotaBytes <= hardQuotaBytes)
        precondition(maximumCatalogRecordCount > 0)
        precondition(maximumCatalogScanByteCount > 0)
        precondition(maximumArtifactScanCount > 0)
        precondition(maximumArtifactReconciliationByteCount > 0)
        precondition(maximumMaintenanceWriteByteCount > 0)
        precondition(maximumQuarantineEpochCount > 0)
        precondition(maximumMetadataRecordByteCount > 0)
        precondition(maximumMaintenanceWriteByteCount >= UInt64(maximumMetadataRecordByteCount) * 2)
        precondition(maximumGCStepBudget > 0)
        precondition(maximumActiveLeaseCount > 0)
        precondition(maximumActiveLeaseBytes > 0)
        self.residentPositiveEntryLimit = residentPositiveEntryLimit
        self.residentPositiveByteLimit = residentPositiveByteLimit
        self.residentNegativeEntryLimit = residentNegativeEntryLimit
        self.residentNegativeByteLimit = residentNegativeByteLimit
        self.softQuotaBytes = softQuotaBytes
        self.hardQuotaBytes = hardQuotaBytes
        self.unreferencedGraceSeconds = unreferencedGraceSeconds
        self.quarantineDelaySeconds = quarantineDelaySeconds
        self.negativeQuotaBytes = negativeQuotaBytes
        self.negativeMaximumAgeSeconds = negativeMaximumAgeSeconds
        self.maximumCatalogRecordCount = maximumCatalogRecordCount
        self.maximumCatalogScanByteCount = maximumCatalogScanByteCount
        self.maximumArtifactScanCount = maximumArtifactScanCount
        self.maximumArtifactReconciliationByteCount = maximumArtifactReconciliationByteCount
        self.maximumMaintenanceWriteByteCount = maximumMaintenanceWriteByteCount
        self.maximumQuarantineEpochCount = maximumQuarantineEpochCount
        self.maximumMetadataRecordByteCount = maximumMetadataRecordByteCount
        self.maximumGCStepBudget = maximumGCStepBudget
        self.maximumActiveLeaseCount = maximumActiveLeaseCount
        self.maximumActiveLeaseBytes = maximumActiveLeaseBytes
        self.containerPolicy = containerPolicy
    }
}

struct CodeMapArtifactStoreClock {
    private let nowProvider: @Sendable () -> UInt64

    static let system = CodeMapArtifactStoreClock {
        UInt64(max(0, Date().timeIntervalSince1970))
    }

    init(now: @escaping @Sendable () -> UInt64) {
        nowProvider = now
    }

    func nowEpochSeconds() -> UInt64 {
        nowProvider()
    }
}

struct CodeMapArtifactLeaseHooks {
    static let none = CodeMapArtifactLeaseHooks()

    let beforeDescriptorOpen: @Sendable () throws -> Void
    let afterDescriptorOpen: @Sendable () -> Void

    init(
        beforeDescriptorOpen: @escaping @Sendable () throws -> Void = {},
        afterDescriptorOpen: @escaping @Sendable () -> Void = {}
    ) {
        self.beforeDescriptorOpen = beforeDescriptorOpen
        self.afterDescriptorOpen = afterDescriptorOpen
    }
}

enum CodeMapArtifactHitSource: Equatable {
    case memory
    case disk
}

final class CodeMapArtifactHandle: Sendable {
    let key: CodeMapArtifactKey
    let outcome: CodeMapSyntaxArtifactOutcome
    let payloadByteCount: UInt64
    let containerByteCount: UInt64
    let estimatedResidentByteCount: UInt64
    fileprivate let storeIdentity: UUID

    fileprivate init(
        key: CodeMapArtifactKey,
        verified: CodeMapArtifactVerifiedFile,
        storeIdentity: UUID
    ) {
        self.key = key
        outcome = verified.outcome
        payloadByteCount = UInt64(verified.payloadByteCount)
        containerByteCount = UInt64(verified.containerByteCount)
        estimatedResidentByteCount = UInt64(verified.containerByteCount)
        self.storeIdentity = storeIdentity
    }
}

enum CodeMapArtifactLookupResult {
    case miss
    case hit(source: CodeMapArtifactHitSource, handle: CodeMapArtifactHandle)
}

enum CodeMapArtifactInsertResult: Equatable {
    case inserted
    case alreadyPresent
}

struct CodeMapArtifactStoreAccounting: Equatable {
    let livePositiveCount: Int
    let livePositiveBytes: UInt64
    let liveNegativeCount: Int
    let liveNegativeBytes: UInt64
    let quarantinedCount: Int
    let quarantinedBytes: UInt64
    let residentPositiveCount: Int
    let residentPositiveBytes: UInt64
    let residentNegativeCount: Int
    let residentNegativeBytes: UInt64
    let activeLeaseCount: Int
    let activeLeaseBytes: UInt64
    let pendingAccessTouchCount: Int
    let corruptMetadataCount: Int
    let corruptPayloadCount: Int
    let missingPayloadCount: Int
    let repairedOrphanArtifactCount: Int
    let observedOrphanArtifactCount: Int
    let ignoredTemporaryCount: Int
    let removedTemporaryCount: Int
    let retainedPrivateDeletionCount: Int
    let retainedPrivateDeletionBytes: UInt64
    let recoveredPrivateDeletionCount: Int
    let recoveredPrivateDeletionBytes: UInt64
    let quarantineOrphanCount: Int
    let liveReconciliationComplete: Bool
    let quarantineInventoryComplete: Bool
}

enum CodeMapArtifactGCPhase: String, Equatable {
    case flushTouches
    case reconcileCatalog
    case reconcileArtifacts
    case reconcileMissingMetadata
    case reconcileCleanup
    case select
    case quarantine
    case quarantineCatalog
    case selectSweep
    case quarantineArtifacts
    case repairQuarantine
    case sweep
}

struct CodeMapArtifactGCContinuation: Equatable {
    let cycle: UInt64
    let phase: CodeMapArtifactGCPhase
    let nextOffset: Int
}

struct CodeMapArtifactGCProgress: Equatable {
    let cycle: UInt64
    let examinedCount: Int
    let quarantinedCount: Int
    let quarantinedBytes: UInt64
    let sweptCount: Int
    let sweptBytes: UInt64
    let leasedSkipCount: Int
    let changedSkipCount: Int
    let visitedEntryCount: Int
    let readByteCount: UInt64
    let writtenByteCount: UInt64
    let selectionCount: Int
    let repairedCount: Int
    let tombstoneCount: Int
    let sweptDigests: [String]
    let continuation: CodeMapArtifactGCContinuation?

    var isComplete: Bool {
        continuation == nil
    }
}

struct CodeMapArtifactStoreMaintenanceIndexAccounting: Equatable {
    let recordOrderCount: Int
    let recordSetCount: Int
    let mutationGenerationCount: Int
}

struct CodeMapArtifactReconciliationProgress: Equatable {
    let accounting: CodeMapArtifactStoreAccounting
    let visitedEntryCount: Int
    let readByteCount: UInt64
    let writtenByteCount: UInt64
    let repairedCount: Int
    let continuation: CodeMapArtifactGCContinuation?

    var isComplete: Bool {
        continuation == nil
    }
}

enum CodeMapArtifactLeaseBusyReason: Equatable {
    case activeLeaseCountLimit
    case activeLeaseByteLimit
    case catalogLock
    case fileDescriptorLimit
}

enum CodeMapArtifactLeaseError: Error, Equatable {
    case busy(CodeMapArtifactLeaseBusyReason)
    case foreignHandle
    case artifactMissing
    case artifactCorrupt
    case artifactChanged
    case accountingOverflow
}

struct CodeMapArtifactLeaseReservation: Equatable {
    let token: UUID
    let scope: UUID
    let digest: String
    let byteCount: UInt64
}

/// All mutable admission state is protected by `lock`. Reservations are made
/// before any descriptor is opened and are released exactly once by the lease's
/// synchronous claim path, including deinitialization.
final class CodeMapArtifactLeaseAdmission: @unchecked Sendable {
    private struct ScopedDigest: Hashable {
        let scope: UUID
        let digest: String
    }

    static let processWide = CodeMapArtifactLeaseAdmission(
        maximumCount: CodeMapArtifactStorePolicy.default.maximumActiveLeaseCount,
        maximumBytes: CodeMapArtifactStorePolicy.default.maximumActiveLeaseBytes
    )

    struct Snapshot: Equatable {
        let activeCount: Int
        let activeBytes: UInt64
    }

    private let lock = NSLock()
    private let maximumCount: Int
    private let maximumBytes: UInt64
    private var reservations: [UUID: CodeMapArtifactLeaseReservation] = [:]
    private var countByDigest: [ScopedDigest: Int] = [:]
    private var activeBytes: UInt64 = 0
    private var accountingFailedClosed = false

    init(maximumCount: Int, maximumBytes: UInt64) {
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
    }

    func reserve(
        scope: UUID,
        digest: String,
        byteCount: UInt64
    ) throws -> CodeMapArtifactLeaseReservation {
        try lock.withLock {
            guard !accountingFailedClosed else {
                throw CodeMapArtifactLeaseError.accountingOverflow
            }
            guard reservations.count < maximumCount else {
                throw CodeMapArtifactLeaseError.busy(.activeLeaseCountLimit)
            }
            let (nextBytes, byteOverflow) = activeBytes.addingReportingOverflow(byteCount)
            guard !byteOverflow, nextBytes <= maximumBytes else {
                throw CodeMapArtifactLeaseError.busy(.activeLeaseByteLimit)
            }
            let scopedDigest = ScopedDigest(scope: scope, digest: digest)
            let currentDigestCount = countByDigest[scopedDigest, default: 0]
            let (nextDigestCount, countOverflow) = currentDigestCount.addingReportingOverflow(1)
            guard !countOverflow else {
                accountingFailedClosed = true
                throw CodeMapArtifactLeaseError.accountingOverflow
            }
            let reservation = CodeMapArtifactLeaseReservation(
                token: UUID(),
                scope: scope,
                digest: digest,
                byteCount: byteCount
            )
            guard reservations[reservation.token] == nil else {
                accountingFailedClosed = true
                throw CodeMapArtifactLeaseError.accountingOverflow
            }
            reservations[reservation.token] = reservation
            countByDigest[scopedDigest] = nextDigestCount
            activeBytes = nextBytes
            return reservation
        }
    }

    func release(_ reservation: CodeMapArtifactLeaseReservation) {
        lock.withLock {
            guard reservations.removeValue(forKey: reservation.token) == reservation else { return }
            guard activeBytes >= reservation.byteCount,
                  let currentDigestCount = countByDigest[
                      ScopedDigest(scope: reservation.scope, digest: reservation.digest)
                  ],
                  currentDigestCount > 0
            else {
                accountingFailedClosed = true
                activeBytes = maximumBytes
                return
            }
            activeBytes -= reservation.byteCount
            let scopedDigest = ScopedDigest(scope: reservation.scope, digest: reservation.digest)
            if currentDigestCount == 1 {
                countByDigest.removeValue(forKey: scopedDigest)
            } else {
                countByDigest[scopedDigest] = currentDigestCount - 1
            }
        }
    }

    func containsLease(scope: UUID, digest: String) -> Bool {
        lock.withLock { countByDigest[ScopedDigest(scope: scope, digest: digest), default: 0] > 0 }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeCount: reservations.count,
                activeBytes: accountingFailedClosed ? maximumBytes : activeBytes
            )
        }
    }
}

/// Mutable ownership is confined to `state` and every close/deinit races through
/// the same lock-protected claim, which returns each descriptor/reservation once.
final class CodeMapArtifactLease: @unchecked Sendable {
    private struct State {
        var diskLease: CodeMapArtifactDiskLease?
        var admission: CodeMapArtifactLeaseAdmission?
        var reservation: CodeMapArtifactLeaseReservation?
    }

    let handle: CodeMapArtifactHandle
    private let lock = NSLock()
    private var state: State

    fileprivate init(
        handle: CodeMapArtifactHandle,
        diskLease: CodeMapArtifactDiskLease,
        admission: CodeMapArtifactLeaseAdmission,
        reservation: CodeMapArtifactLeaseReservation
    ) {
        self.handle = handle
        state = State(diskLease: diskLease, admission: admission, reservation: reservation)
    }

    func close() async {
        closeSynchronously()
    }

    func closeSynchronously() {
        guard let claimed = claim() else { return }
        claimed.diskLease.close()
        claimed.admission.release(claimed.reservation)
    }

    deinit {
        closeSynchronously()
    }

    private func claim() -> (
        diskLease: CodeMapArtifactDiskLease,
        admission: CodeMapArtifactLeaseAdmission,
        reservation: CodeMapArtifactLeaseReservation
    )? {
        lock.withLock {
            guard let diskLease = state.diskLease,
                  let admission = state.admission,
                  let reservation = state.reservation
            else { return nil }
            state = State()
            return (diskLease, admission, reservation)
        }
    }
}

actor CodeMapArtifactStore {
    private struct ResidentEntry {
        let handle: CodeMapArtifactHandle
        var accessSequence: UInt64
    }

    private struct ReconciliationDiagnostics {
        var scan = CodeMapArtifactCatalogScanDiagnostics()
        var missingPayloadCount = 0
        var corruptPayloadCount = 0
        var repairedOrphanArtifactCount = 0
    }

    private struct ReconciliationState {
        var catalogScan: CodeMapArtifactCatalogScanSession?
        var artifactScan: CodeMapArtifactCatalogScanSession?
        var candidates: [String: CodeMapArtifactCatalogRecord] = [:]
        var candidateOrder: [String] = []
        var unmatchedOffset = 0
        var cleanupOffset = 0
        var cleanupLimit = 0
        var seenDigests: Set<String> = []
        var selectionOrder: [String] = []
        var compactedOrder: [String] = []
        var compactedSet: Set<String> = []
        var compactedMutationGenerations: [String: UInt64] = [:]
        let startMutationGeneration: UInt64
    }

    private struct RecordHeap {
        var values: [CodeMapArtifactCatalogRecord] = []

        var minimum: CodeMapArtifactCatalogRecord? {
            values.first
        }

        mutating func insert(_ record: CodeMapArtifactCatalogRecord) {
            values.append(record)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard CodeMapArtifactStore.gcOrder(values[index], values[parent]) else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func popMinimum() -> CodeMapArtifactCatalogRecord? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < values.count else { break }
                let right = left + 1
                var child = left
                if right < values.count, CodeMapArtifactStore.gcOrder(values[right], values[left]) {
                    child = right
                }
                guard CodeMapArtifactStore.gcOrder(values[child], values[index]) else { break }
                values.swapAt(child, index)
                index = child
            }
            return result
        }
    }

    private struct PendingSweep {
        let candidate: CodeMapArtifactQuarantineCandidate
        let metadataByteCount: UInt64
    }

    private struct PendingQuarantineRepair {
        let epochSeconds: UInt64
        let shard: String
        let artifactName: String
        let byteCount: UInt64
    }

    private struct SweepHeap {
        var values: [PendingSweep] = []

        var minimum: PendingSweep? {
            values.first
        }

        mutating func insert(_ value: PendingSweep) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.less(values[index], values[parent]) else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func popMinimum() -> PendingSweep? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < values.count else { break }
                let right = left + 1
                var child = left
                if right < values.count, Self.less(values[right], values[left]) { child = right }
                guard Self.less(values[child], values[index]) else { break }
                values.swapAt(child, index)
                index = child
            }
            return result
        }

        private static func less(_ lhs: PendingSweep, _ rhs: PendingSweep) -> Bool {
            let left = lhs.candidate.tombstone
            let right = rhs.candidate.tombstone
            return (left.epochSeconds, left.digest, left.token) <
                (right.epochSeconds, right.digest, right.token)
        }
    }

    private struct MaintenanceCycle {
        let id: UInt64
        let now: UInt64
        var collect: Bool
        var phase: CodeMapArtifactGCPhase = .flushTouches
        var reconciliation: ReconciliationState
        var selectionOffset = 0
        var selectionLimit = 0
        var heap = RecordHeap()
        var quarantineCatalogScan: CodeMapArtifactCatalogScanSession?
        var quarantineArtifactScan: CodeMapArtifactCatalogScanSession?
        var expectedQuarantineArtifacts: Set<String> = []
        var quarantineCount = 0
        var quarantineBytes: UInt64 = 0
        var recoveredQuarantineOrphanCount = 0
        var pendingSweepSelection: PendingSweep?
        var sweepHeap = SweepHeap()
        var presentQuarantineArtifacts: Set<String> = []
        var quarantineArtifactBytes: [String: UInt64] = [:]
        var pendingRepair: PendingQuarantineRepair?
        var retainedLivePrivateDeletionCount = 0
        var retainedLivePrivateDeletionBytes: UInt64 = 0
        var retainedQuarantinePrivateDeletionCount = 0
        var retainedQuarantinePrivateDeletionBytes: UInt64 = 0
        var workSequence = 0
    }

    private struct CallProgress {
        var examined = 0
        var quarantined = 0
        var quarantinedBytes: UInt64 = 0
        var swept = 0
        var sweptBytes: UInt64 = 0
        var leased = 0
        var changed = 0
        var visited = 0
        var readBytes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var selected = 0
        var repaired = 0
        var tombstones = 0
        var sweptDigests: [String] = []
    }

    private struct MaintenanceIOMetrics {
        var additionalReadByteCount: UInt64 = 0
        var metadataReadByteCount: UInt64 = 0
        var writtenByteCount: UInt64 = 0
        var failed = false
    }

    private let policy: CodeMapArtifactStorePolicy
    private let clock: CodeMapArtifactStoreClock
    private let storeIdentity = UUID()
    private let leaseAdmission: CodeMapArtifactLeaseAdmission
    private let leaseHooks: CodeMapArtifactLeaseHooks
    private let fileStore: CodeMapArtifactFileStore
    private let catalog: CodeMapArtifactCatalog
    private var records: [String: CodeMapArtifactCatalogRecord] = [:]
    private var recordOrder: [String] = []
    private var recordOrderSet: Set<String> = []
    private var residentPositive: [String: ResidentEntry] = [:]
    private var residentNegative: [String: ResidentEntry] = [:]
    private var pendingTouchSet: Set<String> = []
    private var pendingTouchOrder: [String] = []
    private var pendingTouchOffset = 0
    private var nextAccessSequence: UInt64 = 1
    private var nextMaintenanceCycle: UInt64 = 1
    private var maintenanceCycle: MaintenanceCycle?
    private var reconciliation = ReconciliationDiagnostics()
    private var mutationGeneration: UInt64 = 1
    private var mutationGenerationByDigest: [String: UInt64] = [:]
    private var livePositiveCount = 0
    private var livePositiveBytes: UInt64 = 0
    private var liveNegativeCount = 0
    private var liveNegativeBytes: UInt64 = 0
    private var liveReconciliationComplete = false
    private var quarantineInventoryComplete = false
    private var retainedLivePrivateDeletionCount = 0
    private var retainedLivePrivateDeletionBytes: UInt64 = 0
    private var retainedQuarantinePrivateDeletionCount = 0
    private var retainedQuarantinePrivateDeletionBytes: UInt64 = 0

    private var compoundMetadataWriteReservation: UInt64 {
        UInt64(policy.maximumMetadataRecordByteCount) * 2
    }

    private var compoundMetadataReadReservation: UInt64 {
        UInt64(policy.maximumMetadataRecordByteCount) * 2
    }

    init(
        rootURL: URL,
        policy: CodeMapArtifactStorePolicy = .default,
        clock: CodeMapArtifactStoreClock = .system,
        removalHooks: CodeMapSecureFileRemovalHooks? = nil,
        leaseAdmission: CodeMapArtifactLeaseAdmission = CodeMapArtifactLeaseAdmission(
            maximumCount: CodeMapArtifactStorePolicy.default.maximumActiveLeaseCount,
            maximumBytes: CodeMapArtifactStorePolicy.default.maximumActiveLeaseBytes
        ),
        leaseHooks: CodeMapArtifactLeaseHooks = .none
    ) throws {
        self.policy = policy
        self.clock = clock
        self.leaseAdmission = leaseAdmission
        self.leaseHooks = leaseHooks
        fileStore = try CodeMapArtifactFileStore(
            rootURL: rootURL,
            containerPolicy: policy.containerPolicy,
            removalHooks: removalHooks
        )
        catalog = try CodeMapArtifactCatalog(rootURL: rootURL, policy: policy, removalHooks: removalHooks)
    }

    func lookup(key: CodeMapArtifactKey) throws -> CodeMapArtifactLookupResult {
        let digest = key.storageDigestHex
        if var entry = residentPositive[digest] {
            touch(digest: digest)
            entry.accessSequence = currentSequence(for: digest)
            residentPositive[digest] = entry
            return .hit(source: .memory, handle: entry.handle)
        }
        if var entry = residentNegative[digest] {
            touch(digest: digest)
            entry.accessSequence = currentSequence(for: digest)
            residentNegative[digest] = entry
            return .hit(source: .memory, handle: entry.handle)
        }

        let now = clock.nowEpochSeconds()
        switch try fileStore.readVerified(key: key, quarantineCorruption: false) {
        case .corrupt:
            switch try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
            case let .record(record):
                if try catalog.quarantineCorruptPayload(
                    expectedRecord: record,
                    fileStore: fileStore,
                    epochSeconds: now
                ) == .completed {
                    incrementSaturating(&reconciliation.corruptPayloadCount)
                }
            case .missing, .corrupt:
                if try catalog.quarantineOrphanArtifact(
                    CodeMapArtifactOrphanCandidate(shard: key.shard, digest: digest),
                    fileStore: fileStore,
                    epochSeconds: now
                ) == .completed {
                    incrementSaturating(&reconciliation.corruptPayloadCount)
                }
            }
            removeRecord(digest: digest, localMutation: true)
            quarantineInventoryComplete = false
            return .miss

        case .miss:
            if case let .record(record) = try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
                if try catalog.quarantineMissingPayload(expectedRecord: record, epochSeconds: now) == .completed {
                    incrementSaturating(&reconciliation.missingPayloadCount)
                }
            }
            removeRecord(digest: digest, localMutation: true)
            quarantineInventoryComplete = false
            return .miss

        case let .hit(verified):
            let recordResult = try catalog.liveRecord(key: key, quarantineCorruptionAt: now)
            let record: CodeMapArtifactCatalogRecord
            if case let .record(existing) = recordResult,
               recordMatches(existing, key: key, verified: verified)
            {
                record = existing
            } else {
                if case let .record(existing) = recordResult {
                    _ = try catalog.quarantineMissingPayload(expectedRecord: existing, epochSeconds: now)
                }
                let repaired = makeRecord(key: key, verified: verified, now: now)
                record = try catalog.writeLiveRecord(repaired)
                incrementSaturating(&reconciliation.repairedOrphanArtifactCount)
                quarantineInventoryComplete = false
            }
            setRecord(record, localMutation: true)
            let handle = CodeMapArtifactHandle(
                key: key,
                verified: verified,
                storeIdentity: storeIdentity
            )
            cache(handle)
            touch(digest: digest)
            return .hit(source: .disk, handle: handle)
        }
    }

    func insert(
        key: CodeMapArtifactKey,
        deterministicOutcome outcome: CodeMapSyntaxArtifactOutcome
    ) throws -> CodeMapArtifactInsertResult {
        let encodedContainer = try CodeMapArtifactContainer.encode(
            key: key,
            outcome: outcome,
            policy: policy.containerPolicy
        )
        let now = clock.nowEpochSeconds()
        let digest = key.storageDigestHex
        guard records[digest] != nil || records.count < policy.maximumCatalogRecordCount else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        if case .corrupt = try fileStore.readVerified(key: key, quarantineCorruption: false) {
            switch try catalog.liveRecord(key: key, quarantineCorruptionAt: now) {
            case let .record(record):
                _ = try catalog.quarantineCorruptPayload(
                    expectedRecord: record,
                    fileStore: fileStore,
                    epochSeconds: now
                )
            case .missing, .corrupt:
                _ = try catalog.quarantineOrphanArtifact(
                    CodeMapArtifactOrphanCandidate(shard: key.shard, digest: digest),
                    fileStore: fileStore,
                    epochSeconds: now
                )
            }
            removeRecord(digest: digest, localMutation: true)
            incrementSaturating(&reconciliation.corruptPayloadCount)
            quarantineInventoryComplete = false
        }

        let result: (CodeMapArtifactFileWriteResult, CodeMapArtifactVerifiedFile, CodeMapArtifactCatalogRecord) =
            try catalog.withInsertLocks(key: key) {
                let writeResult = try fileStore.writeAssumingMaintenanceLock(
                    key: key,
                    encodedContainer: encodedContainer,
                    quarantineEpochSeconds: now
                )
                guard case let .hit(verified) = try fileStore.readVerified(
                    key: key,
                    quarantineCorruption: false
                ) else { throw CodeMapArtifactCatalogError.invalidMetadata }
                let existing = records[digest]
                let incoming = CodeMapArtifactCatalogRecord(
                    key: key,
                    containerByteCount: UInt64(verified.containerByteCount),
                    payloadByteCount: UInt64(verified.payloadByteCount),
                    outcomeClass: CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome),
                    creationEpochSeconds: existing?.creationEpochSeconds ?? now,
                    lastAccessEpochSeconds: max(existing?.lastAccessEpochSeconds ?? now, now),
                    lastAccessSequence: takeSequence(),
                    state: .live
                )
                let merged = try catalog.writeLiveRecordAssumingMaintenanceLock(incoming)
                return (writeResult, verified, merged)
            }
        setRecord(result.2, localMutation: true)
        pendingTouchSet.remove(digest)
        cache(CodeMapArtifactHandle(
            key: key,
            verified: result.1,
            storeIdentity: storeIdentity
        ))
        return result.0 == .inserted ? .inserted : .alreadyPresent
    }

    func lease(handle: CodeMapArtifactHandle) throws -> CodeMapArtifactLease {
        guard !Task.isCancelled else { throw CancellationError() }
        guard handle.storeIdentity == storeIdentity else {
            throw CodeMapArtifactLeaseError.foreignHandle
        }

        let reservation = try leaseAdmission.reserve(
            scope: storeIdentity,
            digest: handle.key.storageDigestHex,
            byteCount: handle.containerByteCount
        )
        do {
            guard !Task.isCancelled else { throw CancellationError() }
            try leaseHooks.beforeDescriptorOpen()
            let diskLease: CodeMapArtifactDiskLease
            do {
                diskLease = try catalog.acquireSharedLease(key: handle.key)
            } catch let error as CodeMapArtifactCatalogError
                where error == .ioFailure(operation: "lease-busy", code: EWOULDBLOCK)
            {
                throw CodeMapArtifactLeaseError.busy(.catalogLock)
            }
            do {
                leaseHooks.afterDescriptorOpen()
                guard !Task.isCancelled else { throw CancellationError() }
                try validateLeasePresence(handle: handle)
                guard !Task.isCancelled else { throw CancellationError() }
                return CodeMapArtifactLease(
                    handle: handle,
                    diskLease: diskLease,
                    admission: leaseAdmission,
                    reservation: reservation
                )
            } catch {
                diskLease.close()
                throw error
            }
        } catch {
            leaseAdmission.release(reservation)
            throw mapLeaseAcquisitionError(error)
        }
    }

    private func mapLeaseAcquisitionError(_ error: Error) -> Error {
        let code: Int32? = switch error {
        case let CodeMapArtifactCatalogError.ioFailure(_, code): code
        case let CodeMapArtifactFileStoreError.ioFailure(_, code): code
        default: nil
        }
        guard code == EMFILE || code == ENFILE else { return error }
        return CodeMapArtifactLeaseError.busy(.fileDescriptorLimit)
    }

    private func validateLeasePresence(handle: CodeMapArtifactHandle) throws {
        let verified: CodeMapArtifactVerifiedFile
        switch try fileStore.readVerified(key: handle.key, quarantineCorruption: false) {
        case .miss:
            throw CodeMapArtifactLeaseError.artifactMissing
        case .corrupt:
            throw CodeMapArtifactLeaseError.artifactCorrupt
        case let .hit(current):
            verified = current
        }
        guard verified.outcome == handle.outcome,
              UInt64(verified.payloadByteCount) == handle.payloadByteCount,
              UInt64(verified.containerByteCount) == handle.containerByteCount
        else {
            throw CodeMapArtifactLeaseError.artifactChanged
        }
        switch try catalog.liveRecord(key: handle.key, quarantineCorruptionAt: clock.nowEpochSeconds()) {
        case .missing:
            throw CodeMapArtifactLeaseError.artifactMissing
        case .corrupt:
            throw CodeMapArtifactLeaseError.artifactCorrupt
        case let .record(record):
            guard recordMatches(record, key: handle.key, verified: verified) else {
                throw CodeMapArtifactLeaseError.artifactChanged
            }
        }
    }

    @discardableResult
    func flushAccessMetadata(stepBudget: Int) throws -> Int {
        guard stepBudget > 0, stepBudget <= policy.maximumGCStepBudget else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        var completed = 0
        var remainingWriteBytes = policy.maximumMaintenanceWriteByteCount
        var remainingReadBytes = UInt64(policy.maximumCatalogScanByteCount)
        while completed < stepBudget, let digest = dequeueTouch() {
            guard remainingWriteBytes >= UInt64(policy.maximumMetadataRecordByteCount),
                  remainingReadBytes >= UInt64(policy.maximumMetadataRecordByteCount)
            else {
                if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
                break
            }
            let metrics = flushTouch(digest)
            remainingWriteBytes = subtractingFloor(remainingWriteBytes, metrics.writtenByteCount)
            remainingReadBytes = subtractingFloor(remainingReadBytes, metrics.metadataReadByteCount)
            completed += 1
            if metrics.failed { break }
        }
        return completed
    }

    func accounting() -> CodeMapArtifactStoreAccounting {
        let leaseAccounting = leaseAdmission.snapshot()
        return CodeMapArtifactStoreAccounting(
            livePositiveCount: livePositiveCount,
            livePositiveBytes: livePositiveBytes,
            liveNegativeCount: liveNegativeCount,
            liveNegativeBytes: liveNegativeBytes,
            quarantinedCount: reconciliation.scan.quarantineRecordCount,
            quarantinedBytes: reconciliation.scan.quarantineContainerBytes,
            residentPositiveCount: residentPositive.count,
            residentPositiveBytes: residentPositive.values.reduce(UInt64(0)) {
                addingSaturating($0, $1.handle.estimatedResidentByteCount)
            },
            residentNegativeCount: residentNegative.count,
            residentNegativeBytes: residentNegative.values.reduce(UInt64(0)) {
                addingSaturating($0, $1.handle.estimatedResidentByteCount)
            },
            activeLeaseCount: leaseAccounting.activeCount,
            activeLeaseBytes: leaseAccounting.activeBytes,
            pendingAccessTouchCount: pendingTouchSet.count,
            corruptMetadataCount: reconciliation.scan.corruptMetadataCount,
            corruptPayloadCount: reconciliation.corruptPayloadCount,
            missingPayloadCount: reconciliation.missingPayloadCount,
            repairedOrphanArtifactCount: reconciliation.repairedOrphanArtifactCount,
            observedOrphanArtifactCount: reconciliation.scan.orphanArtifactCount,
            ignoredTemporaryCount: reconciliation.scan.ignoredTemporaryCount,
            removedTemporaryCount: reconciliation.scan.removedTemporaryCount,
            retainedPrivateDeletionCount: addingSaturating(
                retainedLivePrivateDeletionCount,
                retainedQuarantinePrivateDeletionCount
            ),
            retainedPrivateDeletionBytes: addingSaturating(
                retainedLivePrivateDeletionBytes,
                retainedQuarantinePrivateDeletionBytes
            ),
            recoveredPrivateDeletionCount: reconciliation.scan.recoveredPrivateDeletionCount,
            recoveredPrivateDeletionBytes: reconciliation.scan.recoveredPrivateDeletionBytes,
            quarantineOrphanCount: reconciliation.scan.quarantineOrphanCount,
            liveReconciliationComplete: liveReconciliationComplete,
            quarantineInventoryComplete: quarantineInventoryComplete
        )
    }

    func maintenanceIndexAccounting() -> CodeMapArtifactStoreMaintenanceIndexAccounting {
        CodeMapArtifactStoreMaintenanceIndexAccounting(
            recordOrderCount: recordOrder.count,
            recordSetCount: recordOrderSet.count,
            mutationGenerationCount: mutationGenerationByDigest.count
        )
    }

    func refreshAccounting(stepBudget: Int) throws -> CodeMapArtifactReconciliationProgress {
        let progress = try advanceMaintenance(stepBudget: stepBudget, collect: false)
        return CodeMapArtifactReconciliationProgress(
            accounting: accounting(),
            visitedEntryCount: progress.visitedEntryCount,
            readByteCount: progress.readByteCount,
            writtenByteCount: progress.writtenByteCount,
            repairedCount: progress.repairedCount,
            continuation: progress.continuation
        )
    }

    func runGC(stepBudget: Int) throws -> CodeMapArtifactGCProgress {
        try advanceMaintenance(stepBudget: stepBudget, collect: true)
    }

    private func advanceMaintenance(stepBudget: Int, collect: Bool) throws -> CodeMapArtifactGCProgress {
        guard stepBudget > 0, stepBudget <= policy.maximumGCStepBudget else {
            throw CodeMapArtifactCatalogError.boundedScanExceeded
        }
        if maintenanceCycle == nil { maintenanceCycle = makeMaintenanceCycle(collect: collect) }
        if collect { maintenanceCycle?.collect = true }
        guard var cycle = maintenanceCycle else { throw CodeMapArtifactCatalogError.invalidMetadata }
        var remaining = stepBudget
        var metadataBytesRemaining = UInt64(policy.maximumCatalogScanByteCount)
        var artifactBytesRemaining = policy.maximumArtifactReconciliationByteCount
        var writeBytesRemaining = policy.maximumMaintenanceWriteByteCount
        var progress = CallProgress()

        maintenanceLoop: while remaining > 0 {
            switch cycle.phase {
            case .flushTouches:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount),
                      metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount)
                else {
                    break maintenanceLoop
                }
                guard let digest = dequeueTouch() else {
                    cycle.phase = .reconcileCatalog
                    continue
                }
                let metrics = flushTouch(digest)
                writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                metadataBytesRemaining = subtractingFloor(
                    metadataBytesRemaining,
                    metrics.metadataReadByteCount
                )
                progress.writtenBytes = addingSaturating(
                    progress.writtenBytes,
                    metrics.writtenByteCount
                )
                progress.readBytes = addingSaturating(
                    progress.readBytes,
                    metrics.metadataReadByteCount
                )
                charge(&cycle, &remaining, &progress)
                if metrics.failed { break maintenanceLoop }

            case .reconcileCatalog:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                    break maintenanceLoop
                }
                if cycle.reconciliation.catalogScan == nil {
                    cycle.reconciliation.catalogScan = try catalog.beginScan(.liveCatalog)
                }
                guard let scan = cycle.reconciliation.catalogScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: metadataBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .reconcileArtifacts
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    metadataBytesRemaining -= min(metadataBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .liveRecord(record, _):
                        cycle.reconciliation.candidates[record.digest] = record
                        cycle.reconciliation.candidateOrder.append(record.digest)
                        nextAccessSequence = max(nextAccessSequence, successor(record.lastAccessSequence))
                    case let .corruptLiveMetadata(_, _, _, writtenBytes):
                        incrementSaturating(&reconciliation.scan.corruptMetadataCount)
                        quarantineInventoryComplete = false
                        incrementSaturating(&progress.tombstones)
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                        progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                    case let .temporary(removed):
                        incrementSaturating(&reconciliation.scan.ignoredTemporaryCount)
                        if removed { incrementSaturating(&reconciliation.scan.removedTemporaryCount) }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: false,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .reconcileArtifacts:
                guard writeBytesRemaining >= compoundMetadataWriteReservation,
                      metadataBytesRemaining >= compoundMetadataReadReservation
                else {
                    break maintenanceLoop
                }
                if cycle.reconciliation.artifactScan == nil {
                    cycle.reconciliation.artifactScan = try catalog.beginScan(.liveArtifacts)
                }
                guard let scan = cycle.reconciliation.artifactScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: artifactBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .reconcileMissingMetadata
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    artifactBytesRemaining -= min(artifactBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .liveArtifact(candidate, containerBytes, _):
                        let metrics = try reconcileArtifact(
                            candidate,
                            containerByteCount: containerBytes,
                            cycle: &cycle,
                            progress: &progress
                        )
                        artifactBytesRemaining = subtractingFloor(
                            artifactBytesRemaining,
                            metrics.additionalReadByteCount
                        )
                        progress.readBytes = addingSaturating(
                            progress.readBytes,
                            metrics.additionalReadByteCount
                        )
                        metadataBytesRemaining = subtractingFloor(
                            metadataBytesRemaining,
                            metrics.metadataReadByteCount
                        )
                        progress.readBytes = addingSaturating(
                            progress.readBytes,
                            metrics.metadataReadByteCount
                        )
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                        progress.writtenBytes = addingSaturating(
                            progress.writtenBytes,
                            metrics.writtenByteCount
                        )
                    case let .temporary(removed):
                        incrementSaturating(&reconciliation.scan.ignoredTemporaryCount)
                        if removed { incrementSaturating(&reconciliation.scan.removedTemporaryCount) }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: false,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .reconcileMissingMetadata:
                guard cycle.reconciliation.unmatchedOffset < cycle.reconciliation.candidateOrder.count else {
                    cycle.reconciliation.cleanupLimit = recordOrder.count
                    cycle.phase = .reconcileCleanup
                    continue
                }
                let digest = cycle.reconciliation.candidateOrder[cycle.reconciliation.unmatchedOffset]
                var verificationReadBytes: UInt64 = 0
                guard writeBytesRemaining >= compoundMetadataWriteReservation,
                      metadataBytesRemaining >= compoundMetadataReadReservation
                else {
                    break maintenanceLoop
                }
                if let record = cycle.reconciliation.candidates[digest] {
                    verificationReadBytes = try fileStore.maintenanceVerificationReadByteCount(key: record.key) ?? 0
                    let (worstCaseRead, overflow) = verificationReadBytes.multipliedReportingOverflow(by: 2)
                    let requiredRead = overflow ? UInt64.max : worstCaseRead
                    guard requiredRead <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard requiredRead <= artifactBytesRemaining else { break maintenanceLoop }
                    artifactBytesRemaining -= verificationReadBytes
                    progress.readBytes = addingSaturating(progress.readBytes, verificationReadBytes)
                }
                cycle.reconciliation.unmatchedOffset += 1
                if let record = cycle.reconciliation.candidates.removeValue(forKey: digest) {
                    let metrics = try reconcileUnmatched(
                        record,
                        verificationReadByteCount: verificationReadBytes,
                        cycle: &cycle,
                        progress: &progress
                    )
                    artifactBytesRemaining = subtractingFloor(
                        artifactBytesRemaining,
                        metrics.additionalReadByteCount
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        metrics.additionalReadByteCount
                    )
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        metrics.metadataReadByteCount
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        metrics.metadataReadByteCount
                    )
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, metrics.writtenByteCount)
                    progress.writtenBytes = addingSaturating(
                        progress.writtenBytes,
                        metrics.writtenByteCount
                    )
                }
                charge(&cycle, &remaining, &progress)

            case .reconcileCleanup:
                if cycle.reconciliation.cleanupLimit < recordOrder.count {
                    cycle.reconciliation.cleanupLimit = recordOrder.count
                }
                guard cycle.reconciliation.cleanupOffset < cycle.reconciliation.cleanupLimit else {
                    recordOrder = cycle.reconciliation.compactedOrder
                    recordOrderSet = cycle.reconciliation.compactedSet
                    mutationGenerationByDigest = cycle.reconciliation.compactedMutationGenerations
                    liveReconciliationComplete = true
                    cycle.reconciliation.selectionOrder = recordOrder
                    cycle.selectionLimit = cycle.reconciliation.selectionOrder.count
                    cycle.phase = cycle.collect ? .select : .quarantineCatalog
                    continue
                }
                let digest = recordOrder[cycle.reconciliation.cleanupOffset]
                cycle.reconciliation.cleanupOffset += 1
                if !cycle.reconciliation.seenDigests.contains(digest),
                   mutationGenerationByDigest[digest, default: 0] <= cycle.reconciliation.startMutationGeneration
                {
                    removeRecord(digest: digest, localMutation: false)
                }
                if records[digest] != nil, cycle.reconciliation.compactedSet.insert(digest).inserted {
                    cycle.reconciliation.compactedOrder.append(digest)
                    if let generation = mutationGenerationByDigest[digest] {
                        cycle.reconciliation.compactedMutationGenerations[digest] = generation
                    }
                }
                charge(&cycle, &remaining, &progress)

            case .select:
                guard cycle.selectionOffset < cycle.selectionLimit else {
                    cycle.phase = .quarantine
                    continue
                }
                let digest = cycle.reconciliation.selectionOrder[cycle.selectionOffset]
                cycle.selectionOffset += 1
                if let record = records[digest] { cycle.heap.insert(record) }
                incrementSaturating(&progress.selected)
                charge(&cycle, &remaining, &progress)

            case .quarantine:
                var quarantineVerificationBytes: UInt64 = 0
                var quarantineMetadataBytes: UInt64 = 0
                let privateDeletionBytes = addingSaturating(
                    cycle.retainedLivePrivateDeletionBytes,
                    retainedQuarantinePrivateDeletionBytes
                )
                if let next = cycle.heap.minimum,
                   records[next.digest] == next,
                   shouldCollect(
                       record: next,
                       now: cycle.now,
                       privateDeletionBytes: privateDeletionBytes
                   ),
                   !leaseAdmission.containsLease(scope: storeIdentity, digest: next.digest)
                {
                    guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                        break maintenanceLoop
                    }
                    guard metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                        break maintenanceLoop
                    }
                    quarantineMetadataBytes = try UInt64(CodeMapArtifactCatalog.encodeRecord(next).count)
                    quarantineVerificationBytes = try fileStore.maintenanceVerificationReadByteCount(key: next.key) ?? 0
                    guard quarantineVerificationBytes <= policy.maximumArtifactReconciliationByteCount else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard quarantineVerificationBytes <= artifactBytesRemaining else { break maintenanceLoop }
                    artifactBytesRemaining -= quarantineVerificationBytes
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineVerificationBytes)
                }
                guard let expected = cycle.heap.popMinimum() else {
                    cycle.phase = .quarantineCatalog
                    continue
                }
                let digest = expected.digest
                defer { charge(&cycle, &remaining, &progress) }
                guard records[digest] == expected,
                      shouldCollect(
                          record: expected,
                          now: cycle.now,
                          privateDeletionBytes: privateDeletionBytes
                      )
                else { continue }
                guard !leaseAdmission.containsLease(scope: storeIdentity, digest: digest) else {
                    incrementSaturating(&progress.leased)
                    continue
                }
                let reason = collectionReason(
                    record: expected,
                    now: cycle.now,
                    privateDeletionBytes: privateDeletionBytes
                )
                switch try catalog.quarantine(
                    expectedRecord: expected,
                    fileStore: fileStore,
                    epochSeconds: cycle.now,
                    reason: reason
                ) {
                case .completed:
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        quarantineMetadataBytes
                    )
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineMetadataBytes)
                    incrementSaturating(&progress.quarantined)
                    progress.quarantinedBytes = addingSaturating(
                        progress.quarantinedBytes,
                        expected.containerByteCount
                    )
                    incrementSaturating(&progress.tombstones)
                    let written = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: expected,
                        digest: expected.digest,
                        reason: reason,
                        containerByteCount: expected.containerByteCount,
                        hasArtifact: true
                    )
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, written)
                    progress.writtenBytes = addingSaturating(progress.writtenBytes, written)
                    removeRecord(digest: digest, localMutation: false)
                    residentPositive.removeValue(forKey: digest)
                    residentNegative.removeValue(forKey: digest)
                    pendingTouchSet.remove(digest)
                    quarantineInventoryComplete = false
                case .leased:
                    artifactBytesRemaining = addingSaturating(
                        artifactBytesRemaining,
                        quarantineVerificationBytes
                    )
                    progress.readBytes = subtractingFloor(
                        progress.readBytes,
                        quarantineVerificationBytes
                    )
                    incrementSaturating(&progress.leased)
                case .missingOrChanged:
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        quarantineMetadataBytes
                    )
                    progress.readBytes = addingSaturating(progress.readBytes, quarantineMetadataBytes)
                    incrementSaturating(&progress.changed)
                }

            case .quarantineCatalog:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount) else {
                    break maintenanceLoop
                }
                if cycle.quarantineCatalogScan == nil {
                    cycle.quarantineCatalogScan = try catalog.beginScan(.quarantineCatalog)
                    cycle.quarantineCount = 0
                    cycle.quarantineBytes = 0
                    cycle.expectedQuarantineArtifacts.removeAll(keepingCapacity: true)
                    quarantineInventoryComplete = false
                }
                guard let scan = cycle.quarantineCatalogScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: metadataBytesRemaining,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    cycle.phase = .quarantineArtifacts
                case let .needsMoreBytes(required, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    guard required <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    break maintenanceLoop
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    metadataBytesRemaining -= min(metadataBytesRemaining, visit.readByteCount)
                    switch visit {
                    case let .quarantineTombstone(candidate, metadataBytes, _, writtenBytes):
                        writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                        progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                        incrementSaturating(&cycle.quarantineCount)
                        cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, metadataBytes)
                        if let artifactName = candidate.artifactName {
                            cycle.expectedQuarantineArtifacts.insert(quarantineIdentity(
                                epoch: candidate.epochSeconds,
                                shard: candidate.shard,
                                name: artifactName
                            ))
                        }
                        if cycle.collect, isSweepEligible(candidate, now: cycle.now) {
                            cycle.pendingSweepSelection = PendingSweep(
                                candidate: candidate,
                                metadataByteCount: metadataBytes
                            )
                            cycle.phase = .selectSweep
                        }
                    case .corruptQuarantineMetadata:
                        incrementSaturating(&reconciliation.scan.quarantineOrphanCount)
                    case let .temporary(removed):
                        incrementSaturating(&reconciliation.scan.ignoredTemporaryCount)
                        if removed { incrementSaturating(&reconciliation.scan.removedTemporaryCount) }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: true,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .selectSweep:
                guard let pending = cycle.pendingSweepSelection else {
                    cycle.phase = .quarantineCatalog
                    continue
                }
                cycle.pendingSweepSelection = nil
                cycle.sweepHeap.insert(pending)
                incrementSaturating(&progress.selected)
                charge(&cycle, &remaining, &progress)
                cycle.phase = .quarantineCatalog

            case .sweep:
                if let next = cycle.sweepHeap.minimum {
                    guard next.metadataByteCount <= UInt64(policy.maximumCatalogScanByteCount) else {
                        throw CodeMapArtifactCatalogError.boundedScanExceeded
                    }
                    guard next.metadataByteCount <= metadataBytesRemaining else { break maintenanceLoop }
                }
                guard let pending = cycle.sweepHeap.popMinimum() else {
                    reconciliation.scan.quarantineRecordCount = cycle.quarantineCount
                    reconciliation.scan.quarantineContainerBytes = cycle.quarantineBytes
                    reconciliation.scan.quarantineOrphanCount =
                        addingSaturating(
                            cycle.recoveredQuarantineOrphanCount,
                            cycle.expectedQuarantineArtifacts.count
                        )
                    quarantineInventoryComplete = true
                    finishPrivateDeletionAccounting(cycle)
                    maintenanceCycle = nil
                    return makeProgress(cycle: cycle, progress: progress, continuation: nil)
                }
                metadataBytesRemaining -= pending.metadataByteCount
                progress.readBytes = addingSaturating(progress.readBytes, pending.metadataByteCount)
                switch try catalog.sweep(pending.candidate) {
                case .completed:
                    incrementSaturating(&progress.swept)
                    progress.sweptDigests.append(pending.candidate.tombstone.digest)
                    progress.sweptBytes = addingSaturating(
                        progress.sweptBytes,
                        pending.candidate.tombstone.containerByteCount
                    )
                    cycle.quarantineCount = max(0, cycle.quarantineCount - 1)
                    var removedBytes = pending.metadataByteCount
                    if let artifactName = pending.candidate.artifactName {
                        let identity = quarantineIdentity(
                            epoch: pending.candidate.epochSeconds,
                            shard: pending.candidate.shard,
                            name: artifactName
                        )
                        cycle.expectedQuarantineArtifacts.remove(identity)
                        if cycle.presentQuarantineArtifacts.remove(identity) != nil {
                            removedBytes = addingSaturating(
                                removedBytes,
                                cycle.quarantineArtifactBytes.removeValue(forKey: identity) ?? 0
                            )
                        }
                    }
                    cycle.quarantineBytes = subtractingFloor(cycle.quarantineBytes, removedBytes)
                case .leased:
                    metadataBytesRemaining = addingSaturating(metadataBytesRemaining, pending.metadataByteCount)
                    progress.readBytes = subtractingFloor(progress.readBytes, pending.metadataByteCount)
                    incrementSaturating(&progress.leased)
                case .missingOrChanged:
                    incrementSaturating(&progress.changed)
                }
                charge(&cycle, &remaining, &progress)

            case .quarantineArtifacts:
                if cycle.quarantineArtifactScan == nil {
                    cycle.quarantineArtifactScan = try catalog.beginScan(.quarantineArtifacts)
                }
                guard let scan = cycle.quarantineArtifactScan else { continue }
                switch try catalog.nextScanStep(
                    scan,
                    maximumReadByteCount: 0,
                    epochSeconds: cycle.now
                ) {
                case .complete:
                    if cycle.collect, !cycle.sweepHeap.values.isEmpty {
                        cycle.phase = .sweep
                        continue
                    }
                    reconciliation.scan.quarantineRecordCount = cycle.quarantineCount
                    reconciliation.scan.quarantineContainerBytes = cycle.quarantineBytes
                    reconciliation.scan.quarantineOrphanCount =
                        addingSaturating(
                            cycle.recoveredQuarantineOrphanCount,
                            cycle.expectedQuarantineArtifacts.count
                        )
                    quarantineInventoryComplete = true
                    finishPrivateDeletionAccounting(cycle)
                    maintenanceCycle = nil
                    return makeProgress(cycle: cycle, progress: progress, continuation: nil)
                case let .needsMoreBytes(_, chargeEntry):
                    if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
                    throw CodeMapArtifactCatalogError.boundedScanExceeded
                case let .visit(visit, chargeEntry):
                    chargeVisit(
                        visit,
                        chargeEntry: chargeEntry,
                        cycle: &cycle,
                        remaining: &remaining,
                        progress: &progress
                    )
                    switch visit {
                    case let .quarantineArtifact(epoch, shard, name, storedBytes):
                        cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, storedBytes)
                        let identity = quarantineIdentity(epoch: epoch, shard: shard, name: name)
                        cycle.quarantineArtifactBytes[identity] = storedBytes
                        if cycle.expectedQuarantineArtifacts.remove(identity) != nil {
                            cycle.presentQuarantineArtifacts.insert(identity)
                        } else {
                            cycle.pendingRepair = PendingQuarantineRepair(
                                epochSeconds: epoch,
                                shard: shard,
                                artifactName: name,
                                byteCount: storedBytes
                            )
                            cycle.phase = .repairQuarantine
                        }
                    case let .temporary(removed):
                        incrementSaturating(&reconciliation.scan.ignoredTemporaryCount)
                        if removed { incrementSaturating(&reconciliation.scan.removedTemporaryCount) }
                    case let .privateDeletion(removed, storedByteCount):
                        recordPrivateDeletion(
                            removed: removed,
                            storedByteCount: storedByteCount,
                            quarantine: true,
                            cycle: &cycle
                        )
                    case .boundary, .junk:
                        break
                    default:
                        break
                    }
                }

            case .repairQuarantine:
                guard writeBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount),
                      metadataBytesRemaining >= UInt64(policy.maximumMetadataRecordByteCount)
                else {
                    break maintenanceLoop
                }
                guard let pending = cycle.pendingRepair else {
                    cycle.phase = .quarantineArtifacts
                    continue
                }
                cycle.pendingRepair = nil
                switch try catalog.recoverArtifactOnlyTombstone(
                    epochSeconds: pending.epochSeconds,
                    shard: pending.shard,
                    artifactName: pending.artifactName,
                    byteCount: pending.byteCount
                ) {
                case let .written(metadataByteCount, writtenByteCount, readByteCount):
                    let metadataBytes = UInt64(metadataByteCount)
                    let writtenBytes = UInt64(writtenByteCount)
                    let readBytes = UInt64(readByteCount)
                    writeBytesRemaining = subtractingFloor(writeBytesRemaining, writtenBytes)
                    metadataBytesRemaining = subtractingFloor(metadataBytesRemaining, readBytes)
                    progress.writtenBytes = addingSaturating(progress.writtenBytes, writtenBytes)
                    progress.readBytes = addingSaturating(progress.readBytes, readBytes)
                    incrementSaturating(&cycle.quarantineCount)
                    cycle.quarantineBytes = addingSaturating(cycle.quarantineBytes, metadataBytes)
                    incrementSaturating(&progress.tombstones)
                    incrementSaturating(&cycle.recoveredQuarantineOrphanCount)
                case let .existing(metadataByteCount):
                    metadataBytesRemaining = subtractingFloor(
                        metadataBytesRemaining,
                        UInt64(metadataByteCount)
                    )
                    progress.readBytes = addingSaturating(
                        progress.readBytes,
                        UInt64(metadataByteCount)
                    )
                    incrementSaturating(&cycle.quarantineCount)
                    cycle.quarantineBytes = addingSaturating(
                        cycle.quarantineBytes,
                        UInt64(metadataByteCount)
                    )
                case .leased:
                    incrementSaturating(&progress.leased)
                    incrementSaturating(&cycle.recoveredQuarantineOrphanCount)
                case .missingOrChanged:
                    let identity = quarantineIdentity(
                        epoch: pending.epochSeconds,
                        shard: pending.shard,
                        name: pending.artifactName
                    )
                    cycle.quarantineBytes = subtractingFloor(cycle.quarantineBytes, pending.byteCount)
                    cycle.quarantineArtifactBytes.removeValue(forKey: identity)
                    cycle.presentQuarantineArtifacts.remove(identity)
                    incrementSaturating(&progress.changed)
                }
                charge(&cycle, &remaining, &progress)
                cycle.phase = .quarantineArtifacts
            }
        }

        maintenanceCycle = cycle
        let continuation = CodeMapArtifactGCContinuation(
            cycle: cycle.id,
            phase: cycle.phase,
            nextOffset: cycle.workSequence
        )
        return makeProgress(cycle: cycle, progress: progress, continuation: continuation)
    }

    private func makeMaintenanceCycle(collect: Bool) -> MaintenanceCycle {
        let id = nextMaintenanceCycle
        nextMaintenanceCycle = successor(nextMaintenanceCycle)
        liveReconciliationComplete = false
        quarantineInventoryComplete = false
        return MaintenanceCycle(
            id: id,
            now: clock.nowEpochSeconds(),
            collect: collect,
            reconciliation: ReconciliationState(startMutationGeneration: mutationGeneration)
        )
    }

    private func reconcileArtifact(
        _ candidate: CodeMapArtifactOrphanCandidate,
        containerByteCount: UInt64,
        cycle: inout MaintenanceCycle,
        progress: inout CallProgress
    ) throws -> MaintenanceIOMetrics {
        var metrics = MaintenanceIOMetrics()
        let expected = cycle.reconciliation.candidates[candidate.digest]
        if mutationGenerationByDigest[candidate.digest, default: 0] >
            cycle.reconciliation.startMutationGeneration
        {
            cycle.reconciliation.seenDigests.insert(candidate.digest)
            cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            return metrics
        }
        switch try fileStore.reconcileOrphan(candidate, quarantineCorruption: false, epochSeconds: cycle.now) {
        case .miss:
            return metrics

        case .corrupt:
            if let expected {
                metrics.additionalReadByteCount = CodeMapArtifactFileStore.maintenanceVerificationReadByteCount(
                    containerByteCount: containerByteCount
                )
                metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(expected).count)
                let mutation = try catalog.quarantineCorruptPayload(
                    expectedRecord: expected,
                    fileStore: fileStore,
                    epochSeconds: cycle.now
                )
                if mutation == .completed {
                    incrementSaturating(&reconciliation.corruptPayloadCount)
                    incrementSaturating(&progress.tombstones)
                    metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: expected,
                        digest: expected.digest,
                        reason: .corruptPayload,
                        containerByteCount: expected.containerByteCount,
                        hasArtifact: true
                    )
                }
                if mutation == .completed { removeRecord(digest: candidate.digest, localMutation: false) }
            } else if try catalog.quarantineOrphanArtifact(
                candidate,
                fileStore: fileStore,
                epochSeconds: cycle.now
            ) == .completed {
                incrementSaturating(&reconciliation.corruptPayloadCount)
                incrementSaturating(&progress.tombstones)
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: nil,
                    digest: candidate.digest,
                    reason: .orphanArtifact,
                    containerByteCount: containerByteCount,
                    hasArtifact: true
                )
                removeRecord(digest: candidate.digest, localMutation: false)
            }
            cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            quarantineInventoryComplete = false

        case let .verified(key, file):
            if let expected, recordMatches(expected, key: key, verified: file) {
                installReconciled(expected, cycle: &cycle)
                cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
            } else {
                if let expected {
                    metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(expected).count)
                    let mutation = try catalog.quarantineMissingPayload(
                        expectedRecord: expected,
                        epochSeconds: cycle.now
                    )
                    if mutation == .completed {
                        incrementSaturating(&progress.tombstones)
                        metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                            epochSeconds: cycle.now,
                            record: expected,
                            digest: expected.digest,
                            reason: .missingPayload,
                            containerByteCount: 0,
                            hasArtifact: false
                        )
                    } else {
                        cycle.reconciliation.seenDigests.insert(candidate.digest)
                        cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
                        return metrics
                    }
                } else {
                    incrementSaturating(&reconciliation.scan.orphanArtifactCount)
                }
                let repaired = try catalog.writeLiveRecord(makeRecord(key: key, verified: file, now: cycle.now))
                metrics.metadataReadByteCount = addingSaturating(
                    metrics.metadataReadByteCount,
                    UInt64(policy.maximumMetadataRecordByteCount)
                )
                metrics.writtenByteCount = try addingSaturating(
                    metrics.writtenByteCount,
                    UInt64(CodeMapArtifactCatalog.encodeRecord(repaired).count)
                )
                installReconciled(repaired, cycle: &cycle)
                cycle.reconciliation.candidates.removeValue(forKey: candidate.digest)
                incrementSaturating(&reconciliation.repairedOrphanArtifactCount)
                incrementSaturating(&progress.repaired)
                quarantineInventoryComplete = false
            }
        }
        return metrics
    }

    private func reconcileUnmatched(
        _ record: CodeMapArtifactCatalogRecord,
        verificationReadByteCount: UInt64,
        cycle: inout MaintenanceCycle,
        progress: inout CallProgress
    ) throws -> MaintenanceIOMetrics {
        var metrics = MaintenanceIOMetrics()
        if mutationGenerationByDigest[record.digest, default: 0] >
            cycle.reconciliation.startMutationGeneration
        {
            cycle.reconciliation.seenDigests.insert(record.digest)
            return metrics
        }
        switch try fileStore.readVerified(key: record.key, quarantineCorruption: false) {
        case .miss:
            metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
            let mutation = try catalog.quarantineMissingPayload(expectedRecord: record, epochSeconds: cycle.now)
            if mutation == .completed {
                incrementSaturating(&reconciliation.missingPayloadCount)
                incrementSaturating(&progress.tombstones)
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: record,
                    digest: record.digest,
                    reason: .missingPayload,
                    containerByteCount: 0,
                    hasArtifact: false
                )
                removeRecord(digest: record.digest, localMutation: false)
            } else {
                cycle.reconciliation.seenDigests.insert(record.digest)
            }
            quarantineInventoryComplete = false
        case .corrupt:
            metrics.additionalReadByteCount = verificationReadByteCount
            metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
            let mutation = try catalog.quarantineCorruptPayload(
                expectedRecord: record,
                fileStore: fileStore,
                epochSeconds: cycle.now
            )
            if mutation == .completed {
                incrementSaturating(&reconciliation.corruptPayloadCount)
                incrementSaturating(&progress.tombstones)
                metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                    epochSeconds: cycle.now,
                    record: record,
                    digest: record.digest,
                    reason: .corruptPayload,
                    containerByteCount: record.containerByteCount,
                    hasArtifact: true
                )
                removeRecord(digest: record.digest, localMutation: false)
            } else {
                cycle.reconciliation.seenDigests.insert(record.digest)
            }
            quarantineInventoryComplete = false
        case let .hit(file):
            if recordMatches(record, key: record.key, verified: file) {
                installReconciled(record, cycle: &cycle)
            } else {
                metrics.metadataReadByteCount = try UInt64(CodeMapArtifactCatalog.encodeRecord(record).count)
                let mutation = try catalog.quarantineMissingPayload(
                    expectedRecord: record,
                    epochSeconds: cycle.now
                )
                if mutation == .completed {
                    metrics.writtenByteCount = try CodeMapArtifactCatalog.tombstoneByteCount(
                        epochSeconds: cycle.now,
                        record: record,
                        digest: record.digest,
                        reason: .missingPayload,
                        containerByteCount: 0,
                        hasArtifact: false
                    )
                } else {
                    cycle.reconciliation.seenDigests.insert(record.digest)
                    return metrics
                }
                let repaired = try catalog.writeLiveRecord(makeRecord(key: record.key, verified: file, now: cycle.now))
                metrics.metadataReadByteCount = addingSaturating(
                    metrics.metadataReadByteCount,
                    UInt64(policy.maximumMetadataRecordByteCount)
                )
                metrics.writtenByteCount = try addingSaturating(
                    metrics.writtenByteCount,
                    UInt64(CodeMapArtifactCatalog.encodeRecord(repaired).count)
                )
                installReconciled(repaired, cycle: &cycle)
                incrementSaturating(&reconciliation.repairedOrphanArtifactCount)
                incrementSaturating(&progress.repaired)
                incrementSaturating(&progress.tombstones)
                quarantineInventoryComplete = false
            }
        }
        return metrics
    }

    private func installReconciled(
        _ record: CodeMapArtifactCatalogRecord,
        cycle: inout MaintenanceCycle
    ) {
        cycle.reconciliation.seenDigests.insert(record.digest)
        guard mutationGenerationByDigest[record.digest, default: 0] <=
            cycle.reconciliation.startMutationGeneration
        else { return }
        setRecord(record, localMutation: false)
    }

    private func makeRecord(
        key: CodeMapArtifactKey,
        verified: CodeMapArtifactVerifiedFile,
        now: UInt64
    ) -> CodeMapArtifactCatalogRecord {
        CodeMapArtifactCatalogRecord(
            key: key,
            containerByteCount: UInt64(verified.containerByteCount),
            payloadByteCount: UInt64(verified.payloadByteCount),
            outcomeClass: CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome),
            creationEpochSeconds: now,
            lastAccessEpochSeconds: now,
            lastAccessSequence: takeSequence(),
            state: .live
        )
    }

    private func recordMatches(
        _ record: CodeMapArtifactCatalogRecord,
        key: CodeMapArtifactKey,
        verified: CodeMapArtifactVerifiedFile
    ) -> Bool {
        record.key == key &&
            record.containerByteCount == UInt64(verified.containerByteCount) &&
            record.payloadByteCount == UInt64(verified.payloadByteCount) &&
            record.outcomeClass == CodeMapArtifactCatalogOutcomeClass(outcome: verified.outcome)
    }

    private func setRecord(_ record: CodeMapArtifactCatalogRecord, localMutation: Bool) {
        let digest = record.digest
        guard records[digest] != nil || records.count < policy.maximumCatalogRecordCount else { return }
        if let old = records[digest] { removeAccounting(old) }
        records[digest] = record
        addAccounting(record)
        if recordOrderSet.insert(digest).inserted {
            compactMaintenanceIndexesIfNeeded()
            recordOrder.append(digest)
        }
        if localMutation { markMutation(digest) }
    }

    private func removeRecord(digest: String, localMutation: Bool) {
        let removed = records.removeValue(forKey: digest)
        if let removed { removeAccounting(removed) }
        recordOrderSet.remove(digest)
        if localMutation, removed != nil { markMutation(digest) }
        compactMaintenanceIndexesIfNeeded()
    }

    private func addAccounting(_ record: CodeMapArtifactCatalogRecord) {
        if record.outcomeClass == .positive {
            incrementSaturating(&livePositiveCount)
            livePositiveBytes = addingSaturating(livePositiveBytes, record.containerByteCount)
        } else {
            incrementSaturating(&liveNegativeCount)
            liveNegativeBytes = addingSaturating(liveNegativeBytes, record.containerByteCount)
        }
    }

    private func removeAccounting(_ record: CodeMapArtifactCatalogRecord) {
        if record.outcomeClass == .positive {
            livePositiveCount = max(0, livePositiveCount - 1)
            livePositiveBytes = subtractingFloor(livePositiveBytes, record.containerByteCount)
        } else {
            liveNegativeCount = max(0, liveNegativeCount - 1)
            liveNegativeBytes = subtractingFloor(liveNegativeBytes, record.containerByteCount)
        }
    }

    private func markMutation(_ digest: String) {
        if mutationGenerationByDigest[digest] == nil,
           mutationGenerationByDigest.count >= policy.maximumCatalogRecordCount
        {
            abortMaintenanceAndCompactIndexes()
        }
        mutationGeneration = successor(mutationGeneration)
        mutationGenerationByDigest[digest] = mutationGeneration
    }

    private func compactMaintenanceIndexesIfNeeded() {
        let limit = policy.maximumCatalogRecordCount > Int.max / 2
            ? Int.max
            : policy.maximumCatalogRecordCount * 2
        guard recordOrder.count >= limit else { return }
        abortMaintenanceAndCompactIndexes()
    }

    private func abortMaintenanceAndCompactIndexes() {
        maintenanceCycle = nil
        recordOrder = recordOrder.filter { recordOrderSet.contains($0) }
        if recordOrder.count != recordOrderSet.count {
            recordOrder = records.keys.sorted()
            recordOrderSet = Set(recordOrder)
        }
        mutationGenerationByDigest = mutationGenerationByDigest.filter { records[$0.key] != nil }
        if mutationGenerationByDigest.count >= policy.maximumCatalogRecordCount {
            mutationGenerationByDigest.removeAll(keepingCapacity: true)
        }
        liveReconciliationComplete = false
        quarantineInventoryComplete = false
    }

    private func recordPrivateDeletion(
        removed: Bool,
        storedByteCount: UInt64?,
        quarantine: Bool,
        cycle: inout MaintenanceCycle
    ) {
        incrementSaturating(&reconciliation.scan.ignoredTemporaryCount)
        guard let storedByteCount else { return }
        if removed {
            incrementSaturating(&reconciliation.scan.removedTemporaryCount)
            incrementSaturating(&reconciliation.scan.recoveredPrivateDeletionCount)
            reconciliation.scan.recoveredPrivateDeletionBytes = addingSaturating(
                reconciliation.scan.recoveredPrivateDeletionBytes,
                storedByteCount
            )
        } else if quarantine {
            incrementSaturating(&cycle.retainedQuarantinePrivateDeletionCount)
            cycle.retainedQuarantinePrivateDeletionBytes = addingSaturating(
                cycle.retainedQuarantinePrivateDeletionBytes,
                storedByteCount
            )
        } else {
            incrementSaturating(&cycle.retainedLivePrivateDeletionCount)
            cycle.retainedLivePrivateDeletionBytes = addingSaturating(
                cycle.retainedLivePrivateDeletionBytes,
                storedByteCount
            )
        }
    }

    private func finishPrivateDeletionAccounting(_ cycle: MaintenanceCycle) {
        retainedLivePrivateDeletionCount = cycle.retainedLivePrivateDeletionCount
        retainedLivePrivateDeletionBytes = cycle.retainedLivePrivateDeletionBytes
        retainedQuarantinePrivateDeletionCount = cycle.retainedQuarantinePrivateDeletionCount
        retainedQuarantinePrivateDeletionBytes = cycle.retainedQuarantinePrivateDeletionBytes
    }

    private func shouldCollect(
        record: CodeMapArtifactCatalogRecord,
        now: UInt64,
        privateDeletionBytes: UInt64
    ) -> Bool {
        if record.outcomeClass == .positive {
            let quotaBytes = addingSaturating(livePositiveBytes, privateDeletionBytes)
            if quotaBytes >= policy.hardQuotaBytes { return true }
            guard quotaBytes > policy.softQuotaBytes,
                  now >= policy.unreferencedGraceSeconds
            else { return false }
            return record.lastAccessEpochSeconds <= now - policy.unreferencedGraceSeconds
        }
        if liveNegativeBytes > policy.negativeQuotaBytes { return true }
        guard now >= policy.negativeMaximumAgeSeconds else { return false }
        return record.lastAccessEpochSeconds <= now - policy.negativeMaximumAgeSeconds
    }

    private func collectionReason(
        record: CodeMapArtifactCatalogRecord,
        now: UInt64,
        privateDeletionBytes: UInt64
    ) -> CodeMapArtifactQuarantineReason {
        if record.outcomeClass == .positive {
            return addingSaturating(livePositiveBytes, privateDeletionBytes) >= policy.hardQuotaBytes
                ? .quota
                : .age
        }
        return liveNegativeBytes > policy.negativeQuotaBytes ? .quota : .age
    }

    private func isSweepEligible(_ candidate: CodeMapArtifactQuarantineCandidate, now: UInt64) -> Bool {
        now >= policy.quarantineDelaySeconds &&
            candidate.epochSeconds <= now - policy.quarantineDelaySeconds
    }

    private static func gcOrder(
        _ lhs: CodeMapArtifactCatalogRecord,
        _ rhs: CodeMapArtifactCatalogRecord
    ) -> Bool {
        (lhs.lastAccessEpochSeconds, lhs.lastAccessSequence, lhs.creationEpochSeconds, lhs.digest) <
            (rhs.lastAccessEpochSeconds, rhs.lastAccessSequence, rhs.creationEpochSeconds, rhs.digest)
    }

    private func cache(_ handle: CodeMapArtifactHandle) {
        let digest = handle.key.storageDigestHex
        let entry = ResidentEntry(handle: handle, accessSequence: takeSequence())
        if CodeMapArtifactCatalogOutcomeClass(outcome: handle.outcome) == .positive {
            residentPositive[digest] = entry
            residentNegative.removeValue(forKey: digest)
            enforceResidentLimit(
                entries: &residentPositive,
                countLimit: policy.residentPositiveEntryLimit,
                byteLimit: policy.residentPositiveByteLimit
            )
        } else {
            residentNegative[digest] = entry
            residentPositive.removeValue(forKey: digest)
            enforceResidentLimit(
                entries: &residentNegative,
                countLimit: policy.residentNegativeEntryLimit,
                byteLimit: policy.residentNegativeByteLimit
            )
        }
    }

    private func enforceResidentLimit(
        entries: inout [String: ResidentEntry],
        countLimit: Int,
        byteLimit: UInt64
    ) {
        while entries.count > countLimit ||
            entries.values.reduce(UInt64(0), {
                addingSaturating($0, $1.handle.estimatedResidentByteCount)
            }) > byteLimit
        {
            guard let victim = entries.min(by: {
                ($0.value.accessSequence, $0.key) < ($1.value.accessSequence, $1.key)
            }) else { return }
            entries.removeValue(forKey: victim.key)
        }
    }

    private func touch(digest: String) {
        guard var record = records[digest] else { return }
        record.lastAccessEpochSeconds = max(record.creationEpochSeconds, clock.nowEpochSeconds())
        record.lastAccessSequence = takeSequence()
        setRecord(record, localMutation: true)
        if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
    }

    private func dequeueTouch() -> String? {
        while pendingTouchOffset < pendingTouchOrder.count {
            let digest = pendingTouchOrder[pendingTouchOffset]
            pendingTouchOffset += 1
            guard pendingTouchSet.remove(digest) != nil else { continue }
            if pendingTouchOffset > 1024, pendingTouchOffset * 2 > pendingTouchOrder.count {
                pendingTouchOrder.removeFirst(pendingTouchOffset)
                pendingTouchOffset = 0
            }
            return digest
        }
        pendingTouchOrder.removeAll(keepingCapacity: true)
        pendingTouchOffset = 0
        return nil
    }

    private func flushTouch(_ digest: String) -> MaintenanceIOMetrics {
        guard let record = records[digest] else { return MaintenanceIOMetrics() }
        var metrics = MaintenanceIOMetrics()
        do {
            if let merged = try catalog.updateLiveRecordIfPresent(record) {
                setRecord(merged, localMutation: false)
                let bytes = try UInt64(CodeMapArtifactCatalog.encodeRecord(merged).count)
                metrics.metadataReadByteCount = bytes
                metrics.writtenByteCount = bytes
                return metrics
            } else {
                removeRecord(digest: digest, localMutation: false)
                residentPositive.removeValue(forKey: digest)
                residentNegative.removeValue(forKey: digest)
            }
        } catch {
            metrics.metadataReadByteCount = UInt64(policy.maximumMetadataRecordByteCount)
            metrics.writtenByteCount = UInt64(policy.maximumMetadataRecordByteCount)
            metrics.failed = true
            if pendingTouchSet.insert(digest).inserted { pendingTouchOrder.append(digest) }
        }
        return metrics
    }

    private func currentSequence(for digest: String) -> UInt64 {
        records[digest]?.lastAccessSequence ?? 0
    }

    private func takeSequence() -> UInt64 {
        let result = nextAccessSequence
        nextAccessSequence = successor(nextAccessSequence)
        return result
    }

    private func successor(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private func charge(
        _ cycle: inout MaintenanceCycle,
        _ remaining: inout Int,
        _ progress: inout CallProgress
    ) {
        remaining -= 1
        cycle.workSequence = addingSaturating(cycle.workSequence, 1)
        incrementSaturating(&progress.examined)
    }

    private func chargeVisit(
        _ visit: CodeMapArtifactCatalogScanVisit,
        chargeEntry: Bool,
        cycle: inout MaintenanceCycle,
        remaining: inout Int,
        progress: inout CallProgress
    ) {
        if chargeEntry { chargeDeferredVisit(cycle: &cycle, remaining: &remaining, progress: &progress) }
        progress.readBytes = addingSaturating(progress.readBytes, visit.readByteCount)
    }

    private func chargeDeferredVisit(
        cycle: inout MaintenanceCycle,
        remaining: inout Int,
        progress: inout CallProgress
    ) {
        charge(&cycle, &remaining, &progress)
        incrementSaturating(&progress.visited)
    }

    private func makeProgress(
        cycle: MaintenanceCycle,
        progress: CallProgress,
        continuation: CodeMapArtifactGCContinuation?
    ) -> CodeMapArtifactGCProgress {
        CodeMapArtifactGCProgress(
            cycle: cycle.id,
            examinedCount: progress.examined,
            quarantinedCount: progress.quarantined,
            quarantinedBytes: progress.quarantinedBytes,
            sweptCount: progress.swept,
            sweptBytes: progress.sweptBytes,
            leasedSkipCount: progress.leased,
            changedSkipCount: progress.changed,
            visitedEntryCount: progress.visited,
            readByteCount: progress.readBytes,
            writtenByteCount: progress.writtenBytes,
            selectionCount: progress.selected,
            repairedCount: progress.repaired,
            tombstoneCount: progress.tombstones,
            sweptDigests: progress.sweptDigests,
            continuation: continuation
        )
    }

    private func quarantineIdentity(epoch: UInt64, shard: String, name: String) -> String {
        "\(epoch)/\(shard)/\(name)"
    }

    private func incrementSaturating(_ value: inout Int) {
        value = addingSaturating(value, 1)
    }

    private func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : result
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }

    private func subtractingFloor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}
