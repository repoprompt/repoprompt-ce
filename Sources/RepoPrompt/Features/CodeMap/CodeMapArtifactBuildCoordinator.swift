import Foundation

enum CodeMapArtifactBuildPriority: Equatable {
    case demand
    case explicit
    case background

    fileprivate var taskPriority: TaskPriority {
        switch self {
        case .demand: .userInitiated
        case .explicit, .background: .utility
        }
    }
}

enum CodeMapArtifactBuildInputError: Error, Equatable {
    case pipelineMismatch
    case artifactKeyMismatch
    case locatorRequiresCleanGitBlob
    case repositoryNamespaceMismatch
    case objectFormatMismatch
    case gitBlobOIDMismatch
}

enum CodeMapArtifactBuildCoordinatorError: Error, Equatable {
    case busy(retryAfterMilliseconds: Int)
    case conflictingBuildInput
    case invalidRequest(CodeMapArtifactBuildInputError)
    case locatorStoreReadFailed
    case casVerificationFailed
}

struct CodeMapArtifactBuildInput: @unchecked Sendable {
    let source: CodeMapSourceSnapshot
    let language: LanguageType
    let pipelineIdentity: CodeMapPipelineIdentity
    let artifactKey: CodeMapArtifactKey
    let locatorIdentity: GitBlobCodeMapLocatorIdentity?

    init(
        source: CodeMapSourceSnapshot,
        language: LanguageType,
        locatorIdentity: GitBlobCodeMapLocatorIdentity? = nil
    ) throws {
        let pipelineIdentity = try SyntaxManager.shared.pipelineIdentity(
            for: language,
            decoderPolicy: source.decoderPolicy
        )
        try self.init(
            source: source,
            language: language,
            pipelineIdentity: pipelineIdentity,
            artifactKey: CodeMapArtifactKey(source: source, pipelineIdentity: pipelineIdentity),
            locatorIdentity: locatorIdentity
        )
    }

    init(
        source: CodeMapSourceSnapshot,
        language: LanguageType,
        pipelineIdentity: CodeMapPipelineIdentity,
        artifactKey: CodeMapArtifactKey,
        locatorIdentity: GitBlobCodeMapLocatorIdentity? = nil
    ) throws {
        let expectedPipeline = try SyntaxManager.shared.pipelineIdentity(
            for: language,
            decoderPolicy: source.decoderPolicy
        )
        guard pipelineIdentity == expectedPipeline else {
            throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.pipelineMismatch)
        }
        guard try artifactKey == CodeMapArtifactKey(source: source, pipelineIdentity: pipelineIdentity) else {
            throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.artifactKeyMismatch)
        }
        if let locatorIdentity {
            guard locatorIdentity.pipelineIdentity == pipelineIdentity else {
                throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.pipelineMismatch)
            }
            guard case let .cleanGitBlob(repositoryNamespace, blobOID) = source.provenance else {
                throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.locatorRequiresCleanGitBlob)
            }
            guard repositoryNamespace == locatorIdentity.repositoryNamespace else {
                throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.repositoryNamespaceMismatch)
            }
            guard blobOID.objectFormat == locatorIdentity.objectFormat else {
                throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.objectFormatMismatch)
            }
            guard blobOID == locatorIdentity.blobOID else {
                throw CodeMapArtifactBuildCoordinatorError.invalidRequest(.gitBlobOIDMismatch)
            }
        }
        self.source = source
        self.language = language
        self.pipelineIdentity = pipelineIdentity
        self.artifactKey = artifactKey
        self.locatorIdentity = locatorIdentity
    }
}

enum CodeMapArtifactBuildTarget: @unchecked Sendable {
    case artifactKey(CodeMapArtifactKey)
    case source(CodeMapArtifactBuildInput)
    case locator(GitBlobCodeMapLocatorIdentity)
}

struct CodeMapArtifactBuildRequest: @unchecked Sendable {
    let ownerID: UUID
    let priority: CodeMapArtifactBuildPriority
    let target: CodeMapArtifactBuildTarget
}

enum CodeMapArtifactCoordinatorCASProvenance: Equatable {
    case memoryHit
    case diskHit
    case missBuilt
}

enum CodeMapArtifactCoordinatorLocatorLookup: Equatable {
    case notRequested
    case hit
    case miss
    case corrupt
    case stale
    case hitButArtifactMissing
}

enum CodeMapArtifactCoordinatorBuildProvenance: Equatable {
    case notNeeded
    case performed
    case joinedSharedBuild
}

enum CodeMapArtifactCoordinatorCASPublication: Equatable {
    case notNeeded
    case inserted
    case alreadyPresent
}

enum CodeMapArtifactCoordinatorLocatorPublication: Equatable {
    case notRequested
    case notNeededExistingAssociation
    case inserted
    case alreadyPresent
    case failed
}

struct CodeMapArtifactCoordinatorDurations: Equatable {
    let buildQueueNanoseconds: UInt64
    let buildPermitNanoseconds: UInt64
    let deterministicBuildNanoseconds: UInt64
    let casPersistenceAndVerificationNanoseconds: UInt64
    let locatorPublicationNanoseconds: UInt64

    static let zero = CodeMapArtifactCoordinatorDurations(
        buildQueueNanoseconds: 0,
        buildPermitNanoseconds: 0,
        deterministicBuildNanoseconds: 0,
        casPersistenceAndVerificationNanoseconds: 0,
        locatorPublicationNanoseconds: 0
    )
}

struct CodeMapArtifactCoordinatorResolution: @unchecked Sendable {
    let handle: CodeMapArtifactHandle
    let casProvenance: CodeMapArtifactCoordinatorCASProvenance
    let locatorLookup: CodeMapArtifactCoordinatorLocatorLookup
    let buildProvenance: CodeMapArtifactCoordinatorBuildProvenance
    let casPublication: CodeMapArtifactCoordinatorCASPublication
    let locatorPublication: CodeMapArtifactCoordinatorLocatorPublication
    let joinedExistingFlight: Bool
    let durations: CodeMapArtifactCoordinatorDurations
}

enum CodeMapArtifactCoordinatorMiss: Equatable {
    case artifactKeyNotFound
    case locatorNotFound
    case corruptLocator
    case locatorHitWithMissingArtifact
}

enum CodeMapArtifactBuildCoordinatorResult: @unchecked Sendable {
    case ready(CodeMapArtifactCoordinatorResolution)
    case miss(CodeMapArtifactCoordinatorMiss)
}

enum CodeMapArtifactBuildFlightPhase: String, Equatable {
    case casLookup
    case awaitingBuildAdmission
    case buildingNonPreemptive
    case persistingArtifact
    case verifyingArtifact
    case publishingLocators
    case finishing
}

struct CodeMapArtifactBuildCoordinatorPolicy: Equatable {
    static let `default` = CodeMapArtifactBuildCoordinatorPolicy()

    let maximumFlightCount: Int
    let maximumTotalWaiterCount: Int
    let maximumWaitersPerFlight: Int
    let maximumQueuedBuildCount: Int
    let maximumConcurrentBuildCount: Int
    let maximumLocatorIdentitiesPerFlight: Int
    let maximumRetainedInputByteCount: Int
    let maximumPendingHookEventCount: Int
    let maximumConsecutiveDemandAdmissions: Int
    let agePromotionNanoseconds: UInt64
    let backgroundAgePromotionNanoseconds: UInt64
    let maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: Int
    let retryAfterMilliseconds: Int

    init(
        maximumFlightCount: Int = 128,
        maximumTotalWaiterCount: Int = 512,
        maximumWaitersPerFlight: Int = 64,
        maximumQueuedBuildCount: Int = 128,
        maximumConcurrentBuildCount: Int = 1,
        maximumLocatorIdentitiesPerFlight: Int = 16,
        maximumRetainedInputByteCount: Int = 128 * 1024 * 1024,
        maximumPendingHookEventCount: Int = 256,
        maximumConsecutiveDemandAdmissions: Int = 4,
        agePromotionNanoseconds: UInt64 = 1_000_000_000,
        backgroundAgePromotionNanoseconds: UInt64 = 1_000_000_000,
        maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged: Int = 4,
        retryAfterMilliseconds: Int = 1000
    ) {
        precondition(maximumFlightCount > 0)
        precondition(maximumTotalWaiterCount > 0)
        precondition(maximumWaitersPerFlight > 0)
        precondition(maximumQueuedBuildCount > 0)
        precondition(maximumConcurrentBuildCount > 0)
        precondition(maximumLocatorIdentitiesPerFlight > 0)
        precondition(maximumRetainedInputByteCount >= 0)
        precondition(maximumPendingHookEventCount > 0)
        precondition(maximumConsecutiveDemandAdmissions > 0)
        precondition(maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged >= 0)
        precondition(retryAfterMilliseconds > 0)
        self.maximumFlightCount = maximumFlightCount
        self.maximumTotalWaiterCount = maximumTotalWaiterCount
        self.maximumWaitersPerFlight = maximumWaitersPerFlight
        self.maximumQueuedBuildCount = maximumQueuedBuildCount
        self.maximumConcurrentBuildCount = maximumConcurrentBuildCount
        self.maximumLocatorIdentitiesPerFlight = maximumLocatorIdentitiesPerFlight
        self.maximumRetainedInputByteCount = maximumRetainedInputByteCount
        self.maximumPendingHookEventCount = maximumPendingHookEventCount
        self.maximumConsecutiveDemandAdmissions = maximumConsecutiveDemandAdmissions
        self.agePromotionNanoseconds = agePromotionNanoseconds
        self.backgroundAgePromotionNanoseconds = backgroundAgePromotionNanoseconds
        self.maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged =
            maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

struct CodeMapArtifactBuilderExecution: @unchecked Sendable {
    let outcome: CodeMapSyntaxArtifactOutcome
    let permitWaitNanoseconds: UInt64
    let buildNanoseconds: UInt64
}

struct CodeMapArtifactBuildCoordinatorClock: @unchecked Sendable {
    static let continuous = CodeMapArtifactBuildCoordinatorClock {
        DispatchTime.now().uptimeNanoseconds
    }

    private let nowProvider: @Sendable () -> UInt64

    init(nowNanoseconds: @escaping @Sendable () -> UInt64) {
        nowProvider = nowNanoseconds
    }

    func nowNanoseconds() -> UInt64 {
        nowProvider()
    }
}

struct CodeMapArtifactStoreClient: @unchecked Sendable {
    let lookup: @Sendable (CodeMapArtifactKey) async throws -> CodeMapArtifactLookupResult
    let insert: @Sendable (CodeMapArtifactKey, CodeMapSyntaxArtifactOutcome) async throws -> CodeMapArtifactInsertResult
    let lease: @Sendable (CodeMapArtifactHandle) async throws -> CodeMapArtifactLease
    let accounting: @Sendable () async -> CodeMapArtifactStoreAccounting

    init(store: CodeMapArtifactStore) {
        lookup = { try await store.lookup(key: $0) }
        insert = { try await store.insert(key: $0, deterministicOutcome: $1) }
        lease = { try await store.lease(handle: $0) }
        accounting = { await store.accounting() }
    }

    init(
        lookup: @escaping @Sendable (CodeMapArtifactKey) async throws -> CodeMapArtifactLookupResult,
        insert: @escaping @Sendable (CodeMapArtifactKey, CodeMapSyntaxArtifactOutcome) async throws
            -> CodeMapArtifactInsertResult,
        lease: @escaping @Sendable (CodeMapArtifactHandle) async throws -> CodeMapArtifactLease,
        accounting: @escaping @Sendable () async -> CodeMapArtifactStoreAccounting
    ) {
        self.lookup = lookup
        self.insert = insert
        self.lease = lease
        self.accounting = accounting
    }
}

struct GitBlobCodeMapLocatorStoreClient: @unchecked Sendable {
    let read: @Sendable (GitBlobCodeMapLocatorIdentity) async throws -> GitBlobCodeMapLocatorReadResult
    let write: @Sendable (VerifiedGitBlobCodeMapLocatorAssociation) async throws
        -> GitBlobCodeMapLocatorWriteResult

    init(store: GitBlobCodeMapLocatorStore) {
        read = { try await store.read(identity: $0) }
        write = { try await store.write(association: $0) }
    }

    init(
        read: @escaping @Sendable (GitBlobCodeMapLocatorIdentity) async throws
            -> GitBlobCodeMapLocatorReadResult,
        write: @escaping @Sendable (VerifiedGitBlobCodeMapLocatorAssociation) async throws
            -> GitBlobCodeMapLocatorWriteResult
    ) {
        self.read = read
        self.write = write
    }
}

struct CodeMapArtifactBuilderClient: @unchecked Sendable {
    let execute: @Sendable (
        CodeMapArtifactBuildInput,
        UUID,
        CodeMapArtifactBuildPriority
    ) async throws -> CodeMapArtifactBuilderExecution

    init(
        clock: CodeMapArtifactBuildCoordinatorClock = .continuous,
        withPermit: @escaping @Sendable (
            UUID,
            TaskPriority,
            @escaping @Sendable () async throws -> CodeMapArtifactBuilderExecution
        ) async throws -> CodeMapArtifactBuilderExecution = { ownerID, priority, operation in
            try await FileSystemService.withCodeMapArtifactBuildPermit(
                ownerID: ownerID,
                priority: priority,
                operation: operation
            )
        }
    ) {
        execute = { input, ownerID, priority in
            let permitStart = clock.nowNanoseconds()
            return try await withPermit(ownerID, priority.taskPriority) {
                let buildStart = clock.nowNanoseconds()
                let permitWait = Self.duration(from: permitStart, to: buildStart)
                try Task.checkCancellation()
                let outcome = try CodeMapSyntaxArtifactBuilder.build(
                    source: input.source,
                    language: input.language
                )
                let buildEnd = clock.nowNanoseconds()
                try Task.checkCancellation()
                return CodeMapArtifactBuilderExecution(
                    outcome: outcome,
                    permitWaitNanoseconds: permitWait,
                    buildNanoseconds: Self.duration(from: buildStart, to: buildEnd)
                )
            }
        }
    }

    init(
        execute: @escaping @Sendable (
            CodeMapArtifactBuildInput,
            UUID,
            CodeMapArtifactBuildPriority
        ) async throws -> CodeMapArtifactBuilderExecution
    ) {
        self.execute = execute
    }

    init(
        build: @escaping @Sendable (
            CodeMapArtifactBuildInput,
            UUID,
            CodeMapArtifactBuildPriority
        ) async throws -> CodeMapSyntaxArtifactOutcome
    ) {
        execute = { input, ownerID, priority in
            try await CodeMapArtifactBuilderExecution(
                outcome: build(input, ownerID, priority),
                permitWaitNanoseconds: 0,
                buildNanoseconds: 0
            )
        }
    }

    private static func duration(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

enum CodeMapArtifactBuildCoordinatorHookKind: String {
    case flightCreated
    case flightJoined
    case phaseChanged
    case buildEnqueued
    case buildAdmitted
    case buildExecutionStarted
    case buildExecutionReturned
    case casPersistenceStarting
    case casPersistenceFinished
    case locatorPublicationStarting
    case locatorPublicationFinished
    case flightCompleted
    case flightFailed
    case flightCancelled
}

struct CodeMapArtifactBuildCoordinatorHookEvent {
    let kind: CodeMapArtifactBuildCoordinatorHookKind
    let artifactStorageDigest: String
    let phase: CodeMapArtifactBuildFlightPhase
    let waiterCount: Int
    let numericValue: UInt64
}

struct CodeMapArtifactBuildCoordinatorHooks {
    static let none = CodeMapArtifactBuildCoordinatorHooks { _ in }

    let event: @Sendable (CodeMapArtifactBuildCoordinatorHookEvent) async -> Void
}

private final class CodeMapArtifactBuildCoordinatorHookDispatcher: @unchecked Sendable {
    struct Accounting {
        let pendingEventCount: Int
        let isDraining: Bool
        let droppedEventCount: UInt64
    }

    private let maximumPendingEventCount: Int
    private let lock = NSLock()
    private let handler: @Sendable (CodeMapArtifactBuildCoordinatorHookEvent) async -> Void
    private var pending: [CodeMapArtifactBuildCoordinatorHookEvent] = []
    private var isDraining = false
    private var droppedEventCount: UInt64 = 0

    init(hooks: CodeMapArtifactBuildCoordinatorHooks, maximumPendingEventCount: Int) {
        handler = hooks.event
        self.maximumPendingEventCount = maximumPendingEventCount
    }

    func submit(_ event: CodeMapArtifactBuildCoordinatorHookEvent) {
        lock.lock()
        // Overflow deterministically drops the newest submission. Already accepted events remain
        // bounded by `maximumPendingEventCount` and are delivered in FIFO order.
        guard pending.count < maximumPendingEventCount else {
            if droppedEventCount < UInt64.max { droppedEventCount += 1 }
            lock.unlock()
            return
        }
        pending.append(event)
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    func accounting() -> Accounting {
        lock.lock()
        defer { lock.unlock() }
        return Accounting(
            pendingEventCount: pending.count,
            isDraining: isDraining,
            droppedEventCount: droppedEventCount
        )
    }

    private func drain() async {
        while let event = next() {
            await handler(event)
        }
    }

    private func next() -> CodeMapArtifactBuildCoordinatorHookEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            isDraining = false
            return nil
        }
        return pending.removeFirst()
    }
}

struct CodeMapArtifactBuildCoordinatorCounters: Equatable {
    /// Requests count calls entering `resolve`. Ready and miss counts are delivered waiters, while
    /// busy rejections and failures count rejection sites or failed shared flights. An early
    /// non-cancellation failure before flight creation increments `failures` exactly once. Typed
    /// input validation occurs before `resolve`, so it changes none of these counters.
    let requests: UInt64
    let readyResults: UInt64
    let misses: UInt64
    let busyRejections: UInt64
    let joins: UInt64
    let waiterCancellations: UInt64
    let lastWaiterCancellations: UInt64
    let sharedTaskCancellations: UInt64
    let retainedInputReservations: UInt64
    let retainedInputReleases: UInt64
    let casMemoryHits: UInt64
    let casDiskHits: UInt64
    let casMisses: UInt64
    let locatorHits: UInt64
    let locatorMisses: UInt64
    let locatorCorruptResults: UInt64
    let locatorHitCASMisses: UInt64
    let buildsStarted: UInt64
    let buildsSucceeded: UInt64
    let buildsFailed: UInt64
    let casInserted: UInt64
    let casAlreadyPresent: UInt64
    let casFailures: UInt64
    let locatorInserted: UInt64
    let locatorAlreadyPresent: UInt64
    let locatorFailed: UInt64
    let duplicateBuilds: UInt64
    let staleCompletionDrops: UInt64
    let demandAdmissions: UInt64
    let explicitAdmissions: UInt64
    let backgroundAdmissions: UInt64
    let agedBackgroundAdmissions: UInt64
    let nonBackgroundAdmissionsWhileBackgroundAged: UInt64
    let droppedHookEvents: UInt64
    let failures: UInt64
}

struct CodeMapArtifactBuildCoordinatorTimingAccounting: Equatable {
    let totalBuildQueueNanoseconds: UInt64
    let maximumBuildQueueNanoseconds: UInt64
    let totalBuildPermitNanoseconds: UInt64
    let maximumBuildPermitNanoseconds: UInt64
    let totalDeterministicBuildNanoseconds: UInt64
    let maximumDeterministicBuildNanoseconds: UInt64
    let totalCASPersistenceNanoseconds: UInt64
    let maximumCASPersistenceNanoseconds: UInt64
    let totalLocatorPublicationNanoseconds: UInt64
    let maximumLocatorPublicationNanoseconds: UInt64
}

struct CodeMapArtifactBuildCoordinatorAccounting: Equatable {
    let activeFlightCount: Int
    let queuedBuildCount: Int
    let activeBuildCount: Int
    let waiterCount: Int
    let retainedInputByteCount: Int
    let ownerAdmissionHistoryCount: Int
    let consecutiveNonBackgroundAdmissionsWhileBackgroundAged: Int
    let pendingHookEventCount: Int
    let hookDispatcherIsDraining: Bool
    let policy: CodeMapArtifactBuildCoordinatorPolicy
    let counters: CodeMapArtifactBuildCoordinatorCounters
    let timings: CodeMapArtifactBuildCoordinatorTimingAccounting
    let artifactStore: CodeMapArtifactStoreAccounting
}

actor CodeMapArtifactBuildCoordinator {
    private enum LocatorIntent: Hashable {
        case existing
        case missing
        case corrupt
        case stale
    }

    private enum WaiterMissKind {
        case direct
        case locator
    }

    private struct LocatorIntentOwnership {
        private var waiterCounts: [LocatorIntent: Int]

        init(intent: LocatorIntent) {
            waiterCounts = [intent: 1]
        }

        var intent: LocatorIntent? {
            if waiterCounts[.corrupt, default: 0] > 0 { return .corrupt }
            if waiterCounts[.stale, default: 0] > 0 { return .stale }
            if waiterCounts[.missing, default: 0] > 0 { return .missing }
            if waiterCounts[.existing, default: 0] > 0 { return .existing }
            return nil
        }

        var isEmpty: Bool {
            waiterCounts.isEmpty
        }

        mutating func add(_ intent: LocatorIntent) {
            waiterCounts[intent, default: 0] += 1
        }

        mutating func remove(_ intent: LocatorIntent) {
            guard let count = waiterCounts[intent] else { return }
            if count == 1 {
                waiterCounts.removeValue(forKey: intent)
            } else {
                waiterCounts[intent] = count - 1
            }
        }
    }

    private struct Waiter {
        let id: UUID
        let ownerID: UUID
        let priority: CodeMapArtifactBuildPriority
        var ordinal: UInt64
        let joinedExistingFlight: Bool
        let locatorIdentity: GitBlobCodeMapLocatorIdentity?
        let locatorIntent: LocatorIntent?
        var proofInput: CodeMapArtifactBuildInput?
        var locatorLookup: CodeMapArtifactCoordinatorLocatorLookup
        let missKind: WaiterMissKind
        #if DEBUG
            let benchmarkMetricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
        #endif
        let continuation: CheckedContinuation<CodeMapArtifactBuildCoordinatorResult, Error>
    }

    private final class Flight {
        let id = UUID()
        let key: CodeMapArtifactKey
        var phase = CodeMapArtifactBuildFlightPhase.casLookup
        var input: CodeMapArtifactBuildInput?
        var retainedInputByteCount = 0
        var hasRetainedInputReservation = false
        var locatorIntents: [GitBlobCodeMapLocatorIdentity: LocatorIntentOwnership] = [:]
        var locatorProofInputs: [GitBlobCodeMapLocatorIdentity: CodeMapArtifactBuildInput] = [:]
        var locatorPublications: [GitBlobCodeMapLocatorIdentity: CodeMapArtifactCoordinatorLocatorPublication] = [:]
        var locatorWriteInProgress: GitBlobCodeMapLocatorIdentity?
        var locatorPublicationHasBegun = false
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        var enqueueNanoseconds: UInt64?
        var enqueueOrdinal: UInt64 = 0
        var acceptsNewWaiters = true
        var casMissObserved = false
        var handle: CodeMapArtifactHandle?
        var casProvenance: CodeMapArtifactCoordinatorCASProvenance?
        var casPublication = CodeMapArtifactCoordinatorCASPublication.notNeeded
        var buildPerformed = false
        var durations = CodeMapArtifactCoordinatorDurations.zero

        init(key: CodeMapArtifactKey, input: CodeMapArtifactBuildInput?) {
            self.key = key
            self.input = input
        }
    }

    private final class BuildInputBox: @unchecked Sendable {
        private var input: CodeMapArtifactBuildInput?

        init(_ input: CodeMapArtifactBuildInput) {
            self.input = input
        }

        func execute(
            builder: CodeMapArtifactBuilderClient,
            ownerID: UUID,
            priority: CodeMapArtifactBuildPriority
        ) async throws -> CodeMapArtifactBuilderExecution {
            guard let input else { preconditionFailure("Build input was consumed more than once") }
            defer { self.input = nil }
            return try await builder.execute(input, ownerID, priority)
        }
    }

    private struct MutableCounters {
        var requests: UInt64 = 0
        var readyResults: UInt64 = 0
        var misses: UInt64 = 0
        var busyRejections: UInt64 = 0
        var joins: UInt64 = 0
        var waiterCancellations: UInt64 = 0
        var lastWaiterCancellations: UInt64 = 0
        var sharedTaskCancellations: UInt64 = 0
        var retainedInputReservations: UInt64 = 0
        var retainedInputReleases: UInt64 = 0
        var casMemoryHits: UInt64 = 0
        var casDiskHits: UInt64 = 0
        var casMisses: UInt64 = 0
        var locatorHits: UInt64 = 0
        var locatorMisses: UInt64 = 0
        var locatorCorruptResults: UInt64 = 0
        var locatorHitCASMisses: UInt64 = 0
        var buildsStarted: UInt64 = 0
        var buildsSucceeded: UInt64 = 0
        var buildsFailed: UInt64 = 0
        var casInserted: UInt64 = 0
        var casAlreadyPresent: UInt64 = 0
        var casFailures: UInt64 = 0
        var locatorInserted: UInt64 = 0
        var locatorAlreadyPresent: UInt64 = 0
        var locatorFailed: UInt64 = 0
        var duplicateBuilds: UInt64 = 0
        var staleCompletionDrops: UInt64 = 0
        var demandAdmissions: UInt64 = 0
        var explicitAdmissions: UInt64 = 0
        var backgroundAdmissions: UInt64 = 0
        var agedBackgroundAdmissions: UInt64 = 0
        var nonBackgroundAdmissionsWhileBackgroundAged: UInt64 = 0
        var failures: UInt64 = 0
    }

    private struct MutableTimings {
        var totalBuildQueue: UInt64 = 0
        var maximumBuildQueue: UInt64 = 0
        var totalBuildPermit: UInt64 = 0
        var maximumBuildPermit: UInt64 = 0
        var totalBuild: UInt64 = 0
        var maximumBuild: UInt64 = 0
        var totalCAS: UInt64 = 0
        var maximumCAS: UInt64 = 0
        var totalLocator: UInt64 = 0
        var maximumLocator: UInt64 = 0
    }

    private let artifactStore: CodeMapArtifactStoreClient
    private let locatorStore: GitBlobCodeMapLocatorStoreClient
    private let builder: CodeMapArtifactBuilderClient
    private let policy: CodeMapArtifactBuildCoordinatorPolicy
    private let clock: CodeMapArtifactBuildCoordinatorClock
    private let hookDispatcher: CodeMapArtifactBuildCoordinatorHookDispatcher

    private var flights: [CodeMapArtifactKey: Flight] = [:]
    private var queuedBuildKeys: [CodeMapArtifactKey] = []
    private var activeBuildCount = 0
    private var waiterCount = 0
    private var retainedInputByteCount = 0
    private var consecutiveDemandAdmissions = 0
    private var consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
    private var nextOrdinal: UInt64 = 1
    private var ownerLastAdmission: [UUID: UInt64] = [:]
    private var buildingKeys: Set<CodeMapArtifactKey> = []
    private var counters = MutableCounters()
    private var timings = MutableTimings()

    init(
        artifactStore: CodeMapArtifactStoreClient,
        locatorStore: GitBlobCodeMapLocatorStoreClient,
        builder: CodeMapArtifactBuilderClient = CodeMapArtifactBuilderClient(),
        policy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        clock: CodeMapArtifactBuildCoordinatorClock = .continuous,
        hooks: CodeMapArtifactBuildCoordinatorHooks = .none,
        initialOrdinal: UInt64 = 1
    ) {
        self.artifactStore = artifactStore
        self.locatorStore = locatorStore
        self.builder = builder
        self.policy = policy
        self.clock = clock
        nextOrdinal = max(1, initialOrdinal)
        hookDispatcher = CodeMapArtifactBuildCoordinatorHookDispatcher(
            hooks: hooks,
            maximumPendingEventCount: policy.maximumPendingHookEventCount
        )
    }

    func resolve(_ request: CodeMapArtifactBuildRequest) async throws -> CodeMapArtifactBuildCoordinatorResult {
        increment(&counters.requests)
        do {
            return try await resolveRequest(request)
        } catch is CancellationError {
            increment(&counters.waiterCancellations)
            throw CancellationError()
        }
    }

    private func resolveRequest(
        _ request: CodeMapArtifactBuildRequest
    ) async throws -> CodeMapArtifactBuildCoordinatorResult {
        try Task.checkCancellation()

        switch request.target {
        case let .artifactKey(key):
            return try await waitForFlight(
                key: key,
                input: nil,
                locatorIdentity: nil,
                locatorLookup: .notRequested,
                locatorIntent: nil,
                missKind: .direct,
                request: request
            )

        case let .source(input):
            guard let locatorIdentity = input.locatorIdentity else {
                return try await waitForFlight(
                    key: input.artifactKey,
                    input: input,
                    locatorIdentity: nil,
                    locatorLookup: .notRequested,
                    locatorIntent: nil,
                    missKind: .direct,
                    request: request
                )
            }
            let locatorResult = try await readLocator(locatorIdentity)
            try Task.checkCancellation()
            switch locatorResult {
            case let .hit(locatedKey):
                increment(&counters.locatorHits)
                if locatedKey != input.artifactKey {
                    return try await waitForFlight(
                        key: input.artifactKey,
                        input: input,
                        locatorIdentity: locatorIdentity,
                        locatorLookup: .stale,
                        locatorIntent: .stale,
                        missKind: .direct,
                        request: request
                    )
                }
                return try await waitForFlight(
                    key: input.artifactKey,
                    input: input,
                    locatorIdentity: locatorIdentity,
                    locatorLookup: .hit,
                    locatorIntent: .existing,
                    missKind: .direct,
                    request: request
                )
            case .miss:
                increment(&counters.locatorMisses)
                return try await waitForFlight(
                    key: input.artifactKey,
                    input: input,
                    locatorIdentity: locatorIdentity,
                    locatorLookup: .miss,
                    locatorIntent: .missing,
                    missKind: .direct,
                    request: request
                )
            case .corrupt:
                increment(&counters.locatorCorruptResults)
                return try await waitForFlight(
                    key: input.artifactKey,
                    input: input,
                    locatorIdentity: locatorIdentity,
                    locatorLookup: .corrupt,
                    locatorIntent: .corrupt,
                    missKind: .direct,
                    request: request
                )
            }

        case let .locator(identity):
            let locatorResult = try await readLocator(identity)
            try Task.checkCancellation()
            switch locatorResult {
            case let .hit(key):
                increment(&counters.locatorHits)
                return try await waitForFlight(
                    key: key,
                    input: nil,
                    locatorIdentity: identity,
                    locatorLookup: .hit,
                    locatorIntent: .existing,
                    missKind: .locator,
                    request: request
                )
            case .miss:
                increment(&counters.locatorMisses)
                increment(&counters.misses)
                return .miss(.locatorNotFound)
            case .corrupt:
                increment(&counters.locatorCorruptResults)
                increment(&counters.misses)
                return .miss(.corruptLocator)
            }
        }
    }

    func acquireLease(for resolution: CodeMapArtifactCoordinatorResolution) async throws -> CodeMapArtifactLease {
        try await artifactStore.lease(resolution.handle)
    }

    func accounting() async -> CodeMapArtifactBuildCoordinatorAccounting {
        let storeAccounting = await artifactStore.accounting()
        resetBackgroundAgingCountIfNeeded()
        let hookAccounting = hookDispatcher.accounting()
        return CodeMapArtifactBuildCoordinatorAccounting(
            activeFlightCount: flights.count,
            queuedBuildCount: queuedBuildKeys.count,
            activeBuildCount: activeBuildCount,
            waiterCount: waiterCount,
            retainedInputByteCount: retainedInputByteCount,
            ownerAdmissionHistoryCount: ownerLastAdmission.count,
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged:
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged,
            pendingHookEventCount: hookAccounting.pendingEventCount,
            hookDispatcherIsDraining: hookAccounting.isDraining,
            policy: policy,
            counters: counterSnapshot(droppedHookEvents: hookAccounting.droppedEventCount),
            timings: timingSnapshot,
            artifactStore: storeAccounting
        )
    }

    private func readLocator(
        _ identity: GitBlobCodeMapLocatorIdentity
    ) async throws -> GitBlobCodeMapLocatorReadResult {
        do {
            return try await locatorStore.read(identity)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            increment(&counters.failures)
            throw CodeMapArtifactBuildCoordinatorError.locatorStoreReadFailed
        }
    }

    private func waitForFlight(
        key: CodeMapArtifactKey,
        input: CodeMapArtifactBuildInput?,
        locatorIdentity: GitBlobCodeMapLocatorIdentity?,
        locatorLookup: CodeMapArtifactCoordinatorLocatorLookup,
        locatorIntent: LocatorIntent?,
        missKind: WaiterMissKind,
        request: CodeMapArtifactBuildRequest
    ) async throws -> CodeMapArtifactBuildCoordinatorResult {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try registerWaiter(
                        id: waiterID,
                        key: key,
                        input: input,
                        locatorIdentity: locatorIdentity,
                        locatorLookup: locatorLookup,
                        locatorIntent: locatorIntent,
                        missKind: missKind,
                        request: request,
                        continuation: continuation
                    )
                    if Task.isCancelled {
                        cancelWaiter(id: waiterID, key: key)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: waiterID, key: key)
            }
        }
    }

    private func registerWaiter(
        id: UUID,
        key: CodeMapArtifactKey,
        input: CodeMapArtifactBuildInput?,
        locatorIdentity: GitBlobCodeMapLocatorIdentity?,
        locatorLookup: CodeMapArtifactCoordinatorLocatorLookup,
        locatorIntent: LocatorIntent?,
        missKind: WaiterMissKind,
        request: CodeMapArtifactBuildRequest,
        continuation: CheckedContinuation<CodeMapArtifactBuildCoordinatorResult, Error>
    ) throws {
        let joined = flights[key] != nil
        let flight: Flight
        if let existing = flights[key] {
            guard existing.acceptsNewWaiters else { throw busyError() }
            flight = existing
        } else {
            guard flights.count < policy.maximumFlightCount else { throw busyError() }
            flight = Flight(key: key, input: nil)
            flights[key] = flight
        }

        guard waiterCount < policy.maximumTotalWaiterCount,
              flight.waiters.count < policy.maximumWaitersPerFlight
        else {
            if !joined { flights.removeValue(forKey: key) }
            throw busyError()
        }
        if let locatorIdentity,
           locatorIntent != nil,
           flight.locatorIntents[locatorIdentity] == nil
        {
            guard flight.locatorIntents.count < policy.maximumLocatorIdentitiesPerFlight else {
                if !joined { flights.removeValue(forKey: key) }
                throw busyError()
            }
        }
        if let input {
            if let existing = flight.input {
                guard existing.artifactKey == input.artifactKey,
                      existing.language == input.language,
                      existing.pipelineIdentity == input.pipelineIdentity
                else {
                    if !joined { flights.removeValue(forKey: key) }
                    increment(&counters.failures)
                    throw CodeMapArtifactBuildCoordinatorError.conflictingBuildInput
                }
            } else {
                do {
                    try reserveRetainedInput(for: flight, byteCount: input.source.rawByteCount)
                } catch {
                    if !joined { flights.removeValue(forKey: key) }
                    throw error
                }
                flight.input = input
            }
        }

        var effectiveLocatorLookup = locatorLookup
        if flight.casMissObserved, locatorLookup == .hit {
            effectiveLocatorLookup = .hitButArtifactMissing
        }
        if let locatorIdentity, let locatorIntent {
            if var ownership = flight.locatorIntents[locatorIdentity] {
                ownership.add(locatorIntent)
                flight.locatorIntents[locatorIdentity] = ownership
            } else {
                flight.locatorIntents[locatorIdentity] = LocatorIntentOwnership(intent: locatorIntent)
            }
        }
        let ordinal = takeOrdinal()
        let proofInput: CodeMapArtifactBuildInput? = switch locatorIntent {
        case .missing?, .corrupt?, .stale?: input
        case .existing?, nil: nil
        }
        if let locatorIdentity, let proofInput,
           flight.locatorProofInputs[locatorIdentity] == nil
        {
            flight.locatorProofInputs[locatorIdentity] = proofInput
        }
        #if DEBUG
            flight.waiters[id] = Waiter(
                id: id,
                ownerID: request.ownerID,
                priority: request.priority,
                ordinal: ordinal,
                joinedExistingFlight: joined,
                locatorIdentity: locatorIdentity,
                locatorIntent: locatorIntent,
                proofInput: proofInput,
                locatorLookup: effectiveLocatorLookup,
                missKind: missKind,
                benchmarkMetricTag: WorktreeStartupInstrumentation.currentBenchmarkMetricTag,
                continuation: continuation
            )
        #else
            flight.waiters[id] = Waiter(
                id: id,
                ownerID: request.ownerID,
                priority: request.priority,
                ordinal: ordinal,
                joinedExistingFlight: joined,
                locatorIdentity: locatorIdentity,
                locatorIntent: locatorIntent,
                proofInput: proofInput,
                locatorLookup: effectiveLocatorLookup,
                missKind: missKind,
                continuation: continuation
            )
        #endif
        waiterCount += 1
        resetBackgroundAgingCountIfNeeded()

        if joined {
            increment(&counters.joins)
            emit(.flightJoined, flight: flight)
        } else {
            emit(.flightCreated, flight: flight)
            startLookup(for: flight)
        }
    }

    private func startLookup(for flight: Flight) {
        let key = flight.key
        let flightID = flight.id
        let client = artifactStore
        flight.task = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await client.lookup(key)
                await self?.lookupCompleted(key: key, flightID: flightID, result: result)
            } catch {
                await self?.flightFailed(key: key, flightID: flightID, error: error)
            }
        }
    }

    private func lookupCompleted(
        key: CodeMapArtifactKey,
        flightID: UUID,
        result: CodeMapArtifactLookupResult
    ) {
        guard let flight = currentFlight(key: key, id: flightID) else { return }
        flight.task = nil
        switch result {
        case let .hit(source, handle):
            switch source {
            case .memory:
                increment(&counters.casMemoryHits)
                flight.casProvenance = .memoryHit
            case .disk:
                increment(&counters.casDiskHits)
                flight.casProvenance = .diskHit
            }
            flight.handle = handle
            if hasPendingLocatorPublication(flight) {
                flight.acceptsNewWaiters = false
                transition(flight, to: .publishingLocators)
                startLocatorPublication(for: flight)
            } else {
                completeReady(flight)
            }

        case .miss:
            increment(&counters.casMisses)
            flight.casMissObserved = true
            for id in flight.waiters.keys where flight.waiters[id]?.locatorLookup == .hit {
                flight.waiters[id]?.locatorLookup = .hitButArtifactMissing
                increment(&counters.locatorHitCASMisses)
            }
            guard flight.input != nil else {
                completeMisses(flight)
                return
            }
            guard queuedBuildKeys.count < policy.maximumQueuedBuildCount else {
                flightFailed(key: key, flightID: flightID, error: busyError())
                return
            }
            flight.enqueueNanoseconds = clock.nowNanoseconds()
            flight.enqueueOrdinal = takeOrdinal()
            transition(flight, to: .awaitingBuildAdmission)
            queuedBuildKeys.append(key)
            emit(.buildEnqueued, flight: flight)
            scheduleBuilds()
        }
    }

    private func scheduleBuilds() {
        resetBackgroundAgingCountIfNeeded()
        while activeBuildCount < policy.maximumConcurrentBuildCount,
              let key = selectNextBuildKey(),
              let flight = flights[key],
              let input = flight.input,
              !flight.waiters.isEmpty
        {
            let now = clock.nowNanoseconds()
            let backgroundAged = hasAgedBackground(now: now)
            queuedBuildKeys.removeAll { $0 == key }
            let descriptor = schedulingDescriptor(for: flight, now: now)
            ownerLastAdmission[descriptor.ownerID] = takeOrdinal()
            if descriptor.isDemand {
                if consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions {
                    consecutiveDemandAdmissions += 1
                }
            } else {
                consecutiveDemandAdmissions = 0
            }
            recordAdmission(descriptor, backgroundAged: backgroundAged)
            let queueDuration = duration(
                from: flight.enqueueNanoseconds ?? clock.nowNanoseconds(),
                to: clock.nowNanoseconds()
            )
            flight.durations = CodeMapArtifactCoordinatorDurations(
                buildQueueNanoseconds: queueDuration,
                buildPermitNanoseconds: 0,
                deterministicBuildNanoseconds: 0,
                casPersistenceAndVerificationNanoseconds: 0,
                locatorPublicationNanoseconds: 0
            )
            recordQueueTiming(queueDuration)
            activeBuildCount += 1
            if !buildingKeys.insert(key).inserted { increment(&counters.duplicateBuilds) }
            increment(&counters.buildsStarted)
            transition(flight, to: .buildingNonPreemptive)
            emit(.buildAdmitted, flight: flight)
            emit(.buildExecutionStarted, flight: flight)
            startBuild(
                flight: flight,
                input: input,
                ownerID: descriptor.ownerID,
                priority: descriptor.priority
            )
        }
        pruneOwnerHistory()
    }

    private func startBuild(
        flight: Flight,
        input: CodeMapArtifactBuildInput,
        ownerID: UUID,
        priority: CodeMapArtifactBuildPriority
    ) {
        let key = flight.key
        let flightID = flight.id
        let builder = builder
        let artifactStore = artifactStore
        let clock = clock
        let inputBox = BuildInputBox(input)
        flight.task = Task.detached(priority: priority.taskPriority) { [weak self] in
            do {
                let execution = try await inputBox.execute(
                    builder: builder,
                    ownerID: ownerID,
                    priority: priority
                )
                guard await self?.buildReturned(
                    key: key,
                    flightID: flightID,
                    execution: execution
                ) == true else { return }

                let persistenceStart = clock.nowNanoseconds()
                let insertResult: CodeMapArtifactInsertResult
                do {
                    insertResult = try await artifactStore.insert(key, execution.outcome)
                } catch {
                    await self?.persistenceFailed(key: key, flightID: flightID, error: error)
                    return
                }
                await self?.beginVerification(key: key, flightID: flightID)
                let verification: CodeMapArtifactLookupResult
                do {
                    verification = try await artifactStore.lookup(key)
                } catch {
                    await self?.persistenceFailed(key: key, flightID: flightID, error: error)
                    return
                }
                let persistenceEnd = clock.nowNanoseconds()
                guard case let .hit(_, handle) = verification,
                      handle.key == key,
                      handle.outcome == execution.outcome
                else {
                    await self?.persistenceFailed(
                        key: key,
                        flightID: flightID,
                        error: CodeMapArtifactBuildCoordinatorError.casVerificationFailed
                    )
                    return
                }
                await self?.persistenceVerified(
                    key: key,
                    flightID: flightID,
                    handle: handle,
                    insertResult: insertResult,
                    durationNanoseconds: Self.duration(from: persistenceStart, to: persistenceEnd)
                )
            } catch {
                await self?.buildFailed(key: key, flightID: flightID, error: error)
            }
        }
    }

    private func buildReturned(
        key: CodeMapArtifactKey,
        flightID: UUID,
        execution: CodeMapArtifactBuilderExecution
    ) -> Bool {
        guard let flight = currentFlight(key: key, id: flightID) else { return false }
        finishActiveBuild(key)
        increment(&counters.buildsSucceeded)
        recordBuildTiming(execution)
        flight.buildPerformed = true
        flight.durations = CodeMapArtifactCoordinatorDurations(
            buildQueueNanoseconds: flight.durations.buildQueueNanoseconds,
            buildPermitNanoseconds: execution.permitWaitNanoseconds,
            deterministicBuildNanoseconds: execution.buildNanoseconds,
            casPersistenceAndVerificationNanoseconds: 0,
            locatorPublicationNanoseconds: 0
        )
        emit(.buildExecutionReturned, flight: flight)
        scheduleBuilds()
        transition(flight, to: .persistingArtifact)
        emit(.casPersistenceStarting, flight: flight)
        return true
    }

    private func buildFailed(key: CodeMapArtifactKey, flightID: UUID, error: Error) {
        guard currentFlight(key: key, id: flightID) != nil else { return }
        finishActiveBuild(key)
        if let schedulerError = error as? ContentReadSchedulerError {
            increment(&counters.busyRejections)
            scheduleBuilds()
            flightFailed(
                key: key,
                flightID: flightID,
                error: CodeMapArtifactBuildCoordinatorError.busy(
                    retryAfterMilliseconds: schedulerError.retryAfterMilliseconds
                )
            )
            return
        }
        increment(&counters.buildsFailed)
        scheduleBuilds()
        flightFailed(key: key, flightID: flightID, error: error)
    }

    private func beginVerification(key: CodeMapArtifactKey, flightID: UUID) {
        guard let flight = currentFlight(key: key, id: flightID) else { return }
        transition(flight, to: .verifyingArtifact)
    }

    private func persistenceVerified(
        key: CodeMapArtifactKey,
        flightID: UUID,
        handle: CodeMapArtifactHandle,
        insertResult: CodeMapArtifactInsertResult,
        durationNanoseconds: UInt64
    ) {
        guard let flight = currentFlight(key: key, id: flightID) else { return }
        switch insertResult {
        case .inserted:
            increment(&counters.casInserted)
            flight.casPublication = .inserted
        case .alreadyPresent:
            increment(&counters.casAlreadyPresent)
            flight.casPublication = .alreadyPresent
        }
        flight.handle = handle
        flight.casProvenance = .missBuilt
        flight.durations = CodeMapArtifactCoordinatorDurations(
            buildQueueNanoseconds: flight.durations.buildQueueNanoseconds,
            buildPermitNanoseconds: flight.durations.buildPermitNanoseconds,
            deterministicBuildNanoseconds: flight.durations.deterministicBuildNanoseconds,
            casPersistenceAndVerificationNanoseconds: durationNanoseconds,
            locatorPublicationNanoseconds: 0
        )
        recordCASTiming(durationNanoseconds)
        emit(.casPersistenceFinished, flight: flight)
        if hasPendingLocatorPublication(flight) {
            flight.acceptsNewWaiters = false
            transition(flight, to: .publishingLocators)
            startLocatorPublication(for: flight)
        } else {
            completeReady(flight)
        }
    }

    private func persistenceFailed(key: CodeMapArtifactKey, flightID: UUID, error: Error) {
        guard currentFlight(key: key, id: flightID) != nil else { return }
        increment(&counters.casFailures)
        flightFailed(key: key, flightID: flightID, error: error)
    }

    private func startLocatorPublication(for flight: Flight) {
        let key = flight.key
        let flightID = flight.id
        let locatorStore = locatorStore
        let clock = clock
        flight.task = Task.detached(priority: .utility) { [weak self] in
            while let association = await self?.beginNextLocatorPublication(key: key, flightID: flightID) {
                let identity = association.identity
                let start = clock.nowNanoseconds()
                let publication: CodeMapArtifactCoordinatorLocatorPublication
                do {
                    switch try await locatorStore.write(association) {
                    case .inserted: publication = .inserted
                    case .alreadyPresent: publication = .alreadyPresent
                    }
                } catch {
                    publication = .failed
                }
                await self?.locatorPublicationCompleted(
                    key: key,
                    flightID: flightID,
                    identity: identity,
                    publication: publication,
                    durationNanoseconds: Self.duration(from: start, to: clock.nowNanoseconds())
                )
            }
            await self?.locatorPublishingFinished(key: key, flightID: flightID)
        }
    }

    private func beginNextLocatorPublication(
        key: CodeMapArtifactKey,
        flightID: UUID
    ) -> VerifiedGitBlobCodeMapLocatorAssociation? {
        guard let flight = currentFlight(key: key, id: flightID),
              flight.locatorWriteInProgress == nil,
              let handle = flight.handle
        else { return nil }
        let identity = flight.locatorIntents
            .filter { $0.value.intent != .existing && flight.locatorPublications[$0.key] == nil }
            .map(\.key)
            .sorted { $0.storageDigestHex < $1.storageDigestHex }
            .first
        guard let identity else { return nil }
        guard let proofInput = flight.locatorProofInputs[identity] else {
            flight.locatorPublications[identity] = .failed
            increment(&counters.locatorFailed)
            return beginNextLocatorPublication(key: key, flightID: flightID)
        }
        let association: VerifiedGitBlobCodeMapLocatorAssociation
        do {
            association = try VerifiedGitBlobCodeMapLocatorAssociation.verify(
                source: proofInput.source,
                identity: identity,
                artifactKey: key,
                casHandle: handle
            )
        } catch {
            flight.locatorPublications[identity] = .failed
            increment(&counters.locatorFailed)
            return beginNextLocatorPublication(key: key, flightID: flightID)
        }
        flight.locatorPublicationHasBegun = true
        flight.locatorWriteInProgress = identity
        emit(.locatorPublicationStarting, flight: flight)
        return association
    }

    private func locatorPublicationCompleted(
        key: CodeMapArtifactKey,
        flightID: UUID,
        identity: GitBlobCodeMapLocatorIdentity,
        publication: CodeMapArtifactCoordinatorLocatorPublication,
        durationNanoseconds: UInt64
    ) {
        guard let flight = currentFlight(key: key, id: flightID),
              flight.locatorWriteInProgress == identity
        else { return }
        flight.locatorWriteInProgress = nil
        flight.locatorProofInputs.removeValue(forKey: identity)
        flight.locatorPublications[identity] = publication
        switch publication {
        case .inserted: increment(&counters.locatorInserted)
        case .alreadyPresent: increment(&counters.locatorAlreadyPresent)
        case .failed: increment(&counters.locatorFailed)
        default: break
        }
        let locatorDuration = addingSaturating(
            flight.durations.locatorPublicationNanoseconds,
            durationNanoseconds
        )
        flight.durations = CodeMapArtifactCoordinatorDurations(
            buildQueueNanoseconds: flight.durations.buildQueueNanoseconds,
            buildPermitNanoseconds: flight.durations.buildPermitNanoseconds,
            deterministicBuildNanoseconds: flight.durations.deterministicBuildNanoseconds,
            casPersistenceAndVerificationNanoseconds: flight.durations.casPersistenceAndVerificationNanoseconds,
            locatorPublicationNanoseconds: locatorDuration
        )
        recordLocatorTiming(durationNanoseconds)
        emit(.locatorPublicationFinished, flight: flight)
    }

    private func locatorPublishingFinished(key: CodeMapArtifactKey, flightID: UUID) {
        guard let flight = currentFlight(key: key, id: flightID) else { return }
        completeReady(flight)
    }

    private func completeReady(_ flight: Flight) {
        guard let handle = flight.handle, let casProvenance = flight.casProvenance else {
            flightFailed(
                key: flight.key,
                flightID: flight.id,
                error: CodeMapArtifactBuildCoordinatorError.casVerificationFailed
            )
            return
        }
        transition(flight, to: .finishing)
        let waiters = Array(flight.waiters.values)
        #if DEBUG
            recordBenchmarkMetrics(waiters: waiters, flight: flight)
        #endif
        removeFlight(flight, hook: .flightCompleted)
        add(&counters.readyResults, UInt64(waiters.count))
        for waiter in waiters {
            let buildProvenance: CodeMapArtifactCoordinatorBuildProvenance = if flight.buildPerformed {
                waiter.joinedExistingFlight ? .joinedSharedBuild : .performed
            } else {
                .notNeeded
            }
            waiter.continuation.resume(returning: .ready(
                CodeMapArtifactCoordinatorResolution(
                    handle: handle,
                    casProvenance: casProvenance,
                    locatorLookup: waiter.locatorLookup,
                    buildProvenance: buildProvenance,
                    casPublication: flight.casPublication,
                    locatorPublication: locatorPublication(for: waiter, flight: flight),
                    joinedExistingFlight: waiter.joinedExistingFlight,
                    durations: flight.durations
                )
            ))
        }
    }

    private func completeMisses(_ flight: Flight) {
        transition(flight, to: .finishing)
        let waiters = Array(flight.waiters.values)
        #if DEBUG
            recordBenchmarkMetrics(waiters: waiters, flight: flight)
        #endif
        removeFlight(flight, hook: .flightCompleted)
        add(&counters.misses, UInt64(waiters.count))
        for waiter in waiters {
            let miss: CodeMapArtifactCoordinatorMiss = switch waiter.missKind {
            case .direct: .artifactKeyNotFound
            case .locator: .locatorHitWithMissingArtifact
            }
            waiter.continuation.resume(returning: .miss(miss))
        }
    }

    private func flightFailed(key: CodeMapArtifactKey, flightID: UUID, error: Error) {
        guard let flight = currentFlight(key: key, id: flightID) else { return }
        if case CodeMapArtifactBuildCoordinatorError.busy = error {
            // `busyError()` accounts at the rejection point.
        } else {
            increment(&counters.failures)
        }
        let waiters = Array(flight.waiters.values)
        #if DEBUG
            recordBenchmarkMetrics(waiters: waiters, flight: flight)
        #endif
        removeFlight(flight, hook: .flightFailed)
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    #if DEBUG
        private func recordBenchmarkMetrics(waiters: [Waiter], flight: Flight) {
            let tags = waiters.compactMap(\.benchmarkMetricTag)
            let uniqueTags = Set(tags)
            let exact = tags.count == waiters.count && uniqueTags.count == 1
            var recordedBuild = false
            for tag in tags {
                WorktreeStartupInstrumentation.recordBenchmarkCodemapWork(
                    tag: tag,
                    durations: exact && !recordedBuild ? flight.durations : nil,
                    buildPerformed: exact && !recordedBuild && flight.buildPerformed,
                    exactlyAttributed: exact
                )
                recordedBuild = true
            }
        }
    #endif

    private func cancelWaiter(id: UUID, key: CodeMapArtifactKey) {
        guard let flight = flights[key], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        switch (flight.waiters.isEmpty, flight.phase) {
        case (true, .buildingNonPreemptive),
             (true, .persistingArtifact),
             (true, .verifyingArtifact),
             (true, .publishingLocators),
             (true, .finishing):
            // Locator publication is part of the admitted non-preemptive transaction. The
            // final waiter may detach, but its durable publication intent must finish.
            break
        case (false, _),
             (true, .casLookup),
             (true, .awaitingBuildAdmission):
            releaseLocatorIntent(for: waiter, from: flight)
        }
        waiterCount -= 1
        waiter.continuation.resume(throwing: CancellationError())
        guard flight.waiters.isEmpty else { return }
        increment(&counters.lastWaiterCancellations)

        switch flight.phase {
        case .casLookup:
            flight.task?.cancel()
            increment(&counters.sharedTaskCancellations)
            removeFlight(flight, hook: .flightCancelled)
        case .awaitingBuildAdmission:
            queuedBuildKeys.removeAll { $0 == key }
            flight.task?.cancel()
            removeFlight(flight, hook: .flightCancelled)
            scheduleBuilds()
        case .buildingNonPreemptive:
            // Admission is the non-preemptive boundary. Let the shared transaction
            // finish even when its final retainer is released; a later matching
            // request may still join the same flight while it drains.
            break
        case .persistingArtifact, .verifyingArtifact, .publishingLocators, .finishing:
            break
        }
    }

    private func removeFlight(_ flight: Flight, hook: CodeMapArtifactBuildCoordinatorHookKind) {
        guard flights[flight.key]?.id == flight.id else { return }
        queuedBuildKeys.removeAll { $0 == flight.key }
        if buildingKeys.contains(flight.key) { finishActiveBuild(flight.key) }
        waiterCount -= flight.waiters.count
        releaseRetainedInputReservation(for: flight)
        flight.task = nil
        flights.removeValue(forKey: flight.key)
        emit(hook, flight: flight)
        pruneOwnerHistory()
    }

    private func currentFlight(key: CodeMapArtifactKey, id: UUID) -> Flight? {
        guard let flight = flights[key], flight.id == id else {
            increment(&counters.staleCompletionDrops)
            return nil
        }
        return flight
    }

    private func finishActiveBuild(_ key: CodeMapArtifactKey) {
        if buildingKeys.remove(key) != nil {
            activeBuildCount -= 1
        }
    }

    private func reserveRetainedInput(for flight: Flight, byteCount: Int) throws {
        guard !flight.hasRetainedInputReservation else { return }
        guard byteCount <= policy.maximumRetainedInputByteCount - retainedInputByteCount else {
            throw busyError()
        }
        retainedInputByteCount += byteCount
        flight.retainedInputByteCount = byteCount
        flight.hasRetainedInputReservation = true
        increment(&counters.retainedInputReservations)
    }

    private func releaseRetainedInputReservation(for flight: Flight) {
        flight.input = nil
        flight.locatorProofInputs.removeAll()
        for id in flight.waiters.keys {
            flight.waiters[id]?.proofInput = nil
        }
        guard flight.hasRetainedInputReservation else { return }
        retainedInputByteCount -= flight.retainedInputByteCount
        flight.retainedInputByteCount = 0
        flight.hasRetainedInputReservation = false
        increment(&counters.retainedInputReleases)
    }

    private func hasPendingLocatorPublication(_ flight: Flight) -> Bool {
        flight.locatorIntents.values.contains { $0.intent != .existing }
    }

    private func releaseLocatorIntent(for waiter: Waiter, from flight: Flight) {
        guard !flight.locatorPublicationHasBegun,
              let intent = waiter.locatorIntent,
              let identity = waiter.locatorIdentity,
              var ownership = flight.locatorIntents[identity]
        else { return }
        ownership.remove(intent)
        if ownership.isEmpty {
            flight.locatorIntents.removeValue(forKey: identity)
            flight.locatorProofInputs.removeValue(forKey: identity)
        } else {
            flight.locatorIntents[identity] = ownership
        }
    }

    private func locatorPublication(
        for waiter: Waiter,
        flight: Flight
    ) -> CodeMapArtifactCoordinatorLocatorPublication {
        guard let identity = waiter.locatorIdentity else { return .notRequested }
        switch waiter.locatorLookup {
        case .notRequested:
            return .notRequested
        case .hit, .hitButArtifactMissing:
            return .notNeededExistingAssociation
        case .corrupt, .miss, .stale:
            return flight.locatorPublications[identity] ?? .failed
        }
    }

    private func selectNextBuildKey() -> CodeMapArtifactKey? {
        let now = clock.nowNanoseconds()
        let candidates = queuedBuildKeys.compactMap { key -> (CodeMapArtifactKey, Flight, SchedulingDescriptor)? in
            guard let flight = flights[key], !flight.waiters.isEmpty else { return nil }
            return (key, flight, schedulingDescriptor(for: flight, now: now))
        }
        let demand = candidates.filter { $0.2.tier == .demand }
        let agedExplicit = candidates.filter { $0.2.tier == .agedExplicit }
        let explicit = candidates.filter { $0.2.tier == .explicit }
        let agedBackground = candidates.filter { $0.2.tier == .agedBackground }
        let background = candidates.filter { $0.2.tier == .background }
        if agedBackground.isEmpty {
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
        }
        let backgroundDue = !agedBackground.isEmpty
            && consecutiveNonBackgroundAdmissionsWhileBackgroundAged
            >= policy.maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged
        let pool: [(CodeMapArtifactKey, Flight, SchedulingDescriptor)] = if backgroundDue {
            agedBackground
        } else if !agedExplicit.isEmpty {
            agedExplicit
        } else if !demand.isEmpty,
                  explicit.isEmpty || consecutiveDemandAdmissions < policy.maximumConsecutiveDemandAdmissions
        {
            demand
        } else if !explicit.isEmpty {
            explicit
        } else if !agedBackground.isEmpty {
            agedBackground
        } else {
            background
        }
        return pool.min { lhs, rhs in
            let lhsGrant = ownerLastAdmission[lhs.2.ownerID] ?? 0
            let rhsGrant = ownerLastAdmission[rhs.2.ownerID] ?? 0
            if lhsGrant != rhsGrant { return lhsGrant < rhsGrant }
            return lhs.1.enqueueOrdinal < rhs.1.enqueueOrdinal
        }?.0
    }

    private struct SchedulingDescriptor {
        let ownerID: UUID
        let priority: CodeMapArtifactBuildPriority
        let tier: SchedulingTier

        var isDemand: Bool {
            tier == .demand
        }
    }

    private enum SchedulingTier {
        case demand
        case agedExplicit
        case explicit
        case agedBackground
        case background
    }

    private func schedulingDescriptor(
        for flight: Flight,
        now: UInt64? = nil
    ) -> SchedulingDescriptor {
        let demandWaiters = flight.waiters.values.filter { $0.priority == .demand }
        let explicitWaiters = flight.waiters.values.filter { $0.priority == .explicit }
        let selected = (
            !demandWaiters.isEmpty
                ? demandWaiters
                : (!explicitWaiters.isEmpty ? explicitWaiters : Array(flight.waiters.values))
        )
        .min { $0.ordinal < $1.ordinal }!
        let current = now ?? clock.nowNanoseconds()
        let aged = selected.priority == .explicit && duration(
            from: flight.enqueueNanoseconds ?? current,
            to: current
        ) >= policy.agePromotionNanoseconds
        let backgroundAged = selected.priority == .background && duration(
            from: flight.enqueueNanoseconds ?? current,
            to: current
        ) >= policy.backgroundAgePromotionNanoseconds
        let tier: SchedulingTier = if selected.priority == .demand {
            .demand
        } else if aged {
            .agedExplicit
        } else if selected.priority == .explicit {
            .explicit
        } else if backgroundAged {
            .agedBackground
        } else {
            .background
        }
        return SchedulingDescriptor(
            ownerID: selected.ownerID,
            priority: selected.priority,
            tier: tier
        )
    }

    private func hasAgedBackground(now: UInt64) -> Bool {
        queuedBuildKeys.contains { key in
            guard let flight = flights[key], !flight.waiters.isEmpty else { return false }
            return schedulingDescriptor(for: flight, now: now).tier == .agedBackground
        }
    }

    private func resetBackgroundAgingCountIfNeeded() {
        guard consecutiveNonBackgroundAdmissionsWhileBackgroundAged > 0 else { return }
        if !hasAgedBackground(now: clock.nowNanoseconds()) {
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
        }
    }

    private func recordAdmission(
        _ descriptor: SchedulingDescriptor,
        backgroundAged: Bool
    ) {
        switch descriptor.priority {
        case .demand:
            increment(&counters.demandAdmissions)
        case .explicit:
            increment(&counters.explicitAdmissions)
        case .background:
            increment(&counters.backgroundAdmissions)
            if descriptor.tier == .agedBackground {
                increment(&counters.agedBackgroundAdmissions)
            }
        }

        if descriptor.priority == .background {
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
        } else if backgroundAged {
            if consecutiveNonBackgroundAdmissionsWhileBackgroundAged
                < policy.maximumConsecutiveNonBackgroundAdmissionsWhileBackgroundAged
            {
                consecutiveNonBackgroundAdmissionsWhileBackgroundAged += 1
            }
            increment(&counters.nonBackgroundAdmissionsWhileBackgroundAged)
        } else {
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
        }
    }

    private func transition(_ flight: Flight, to phase: CodeMapArtifactBuildFlightPhase) {
        flight.phase = phase
        emit(.phaseChanged, flight: flight)
    }

    private func emit(_ kind: CodeMapArtifactBuildCoordinatorHookKind, flight: Flight) {
        let event = CodeMapArtifactBuildCoordinatorHookEvent(
            kind: kind,
            artifactStorageDigest: flight.key.storageDigestHex,
            phase: flight.phase,
            waiterCount: flight.waiters.count,
            numericValue: nextOrdinal
        )
        hookDispatcher.submit(event)
    }

    private func busyError() -> CodeMapArtifactBuildCoordinatorError {
        increment(&counters.busyRejections)
        return .busy(retryAfterMilliseconds: policy.retryAfterMilliseconds)
    }

    private func takeOrdinal() -> UInt64 {
        ensureOrdinalCapacity()
        let value = nextOrdinal
        if let next = addingChecked(nextOrdinal, 1) {
            nextOrdinal = next
        }
        return value
    }

    private func ensureOrdinalCapacity() {
        guard nextOrdinal == .max else { return }
        pruneOwnerHistory()

        var waiterOrdinal: UInt64 = 1
        let waiterOrder = flights.values.flatMap { flight in
            flight.waiters.values.map { (flight, $0) }
        }.sorted { lhs, rhs in
            if lhs.1.ordinal != rhs.1.ordinal { return lhs.1.ordinal < rhs.1.ordinal }
            return lhs.1.id.uuidString < rhs.1.id.uuidString
        }
        for (flight, waiter) in waiterOrder {
            guard var current = flight.waiters[waiter.id] else { continue }
            current.ordinal = waiterOrdinal
            flight.waiters[waiter.id] = current
            guard let next = addingChecked(waiterOrdinal, 1) else { return }
            waiterOrdinal = next
        }

        var flightOrdinal: UInt64 = 1
        for flight in flights.values.sorted(by: { lhs, rhs in
            if lhs.enqueueOrdinal != rhs.enqueueOrdinal { return lhs.enqueueOrdinal < rhs.enqueueOrdinal }
            return lhs.key.storageDigestHex < rhs.key.storageDigestHex
        }) {
            flight.enqueueOrdinal = flightOrdinal
            guard let next = addingChecked(flightOrdinal, 1) else { return }
            flightOrdinal = next
        }

        var ownerOrdinal: UInt64 = 1
        for (owner, _) in ownerLastAdmission.sorted(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.uuidString < rhs.key.uuidString
        }) {
            ownerLastAdmission[owner] = ownerOrdinal
            guard let next = addingChecked(ownerOrdinal, 1) else { return }
            ownerOrdinal = next
        }
        nextOrdinal = max(waiterOrdinal, max(flightOrdinal, ownerOrdinal))
    }

    private func pruneOwnerHistory() {
        let activeOwners = Set(flights.values.flatMap { $0.waiters.values.map(\.ownerID) })
        ownerLastAdmission = ownerLastAdmission.filter { activeOwners.contains($0.key) }
        if flights.isEmpty, queuedBuildKeys.isEmpty {
            consecutiveDemandAdmissions = 0
            consecutiveNonBackgroundAdmissionsWhileBackgroundAged = 0
        }
    }

    private func recordQueueTiming(_ value: UInt64) {
        timings.totalBuildQueue = addingSaturating(timings.totalBuildQueue, value)
        timings.maximumBuildQueue = max(timings.maximumBuildQueue, value)
    }

    private func recordBuildTiming(_ execution: CodeMapArtifactBuilderExecution) {
        timings.totalBuildPermit = addingSaturating(timings.totalBuildPermit, execution.permitWaitNanoseconds)
        timings.maximumBuildPermit = max(timings.maximumBuildPermit, execution.permitWaitNanoseconds)
        timings.totalBuild = addingSaturating(timings.totalBuild, execution.buildNanoseconds)
        timings.maximumBuild = max(timings.maximumBuild, execution.buildNanoseconds)
    }

    private func recordCASTiming(_ value: UInt64) {
        timings.totalCAS = addingSaturating(timings.totalCAS, value)
        timings.maximumCAS = max(timings.maximumCAS, value)
    }

    private func recordLocatorTiming(_ value: UInt64) {
        timings.totalLocator = addingSaturating(timings.totalLocator, value)
        timings.maximumLocator = max(timings.maximumLocator, value)
    }

    private func counterSnapshot(droppedHookEvents: UInt64) -> CodeMapArtifactBuildCoordinatorCounters {
        CodeMapArtifactBuildCoordinatorCounters(
            requests: counters.requests,
            readyResults: counters.readyResults,
            misses: counters.misses,
            busyRejections: counters.busyRejections,
            joins: counters.joins,
            waiterCancellations: counters.waiterCancellations,
            lastWaiterCancellations: counters.lastWaiterCancellations,
            sharedTaskCancellations: counters.sharedTaskCancellations,
            retainedInputReservations: counters.retainedInputReservations,
            retainedInputReleases: counters.retainedInputReleases,
            casMemoryHits: counters.casMemoryHits,
            casDiskHits: counters.casDiskHits,
            casMisses: counters.casMisses,
            locatorHits: counters.locatorHits,
            locatorMisses: counters.locatorMisses,
            locatorCorruptResults: counters.locatorCorruptResults,
            locatorHitCASMisses: counters.locatorHitCASMisses,
            buildsStarted: counters.buildsStarted,
            buildsSucceeded: counters.buildsSucceeded,
            buildsFailed: counters.buildsFailed,
            casInserted: counters.casInserted,
            casAlreadyPresent: counters.casAlreadyPresent,
            casFailures: counters.casFailures,
            locatorInserted: counters.locatorInserted,
            locatorAlreadyPresent: counters.locatorAlreadyPresent,
            locatorFailed: counters.locatorFailed,
            duplicateBuilds: counters.duplicateBuilds,
            staleCompletionDrops: counters.staleCompletionDrops,
            demandAdmissions: counters.demandAdmissions,
            explicitAdmissions: counters.explicitAdmissions,
            backgroundAdmissions: counters.backgroundAdmissions,
            agedBackgroundAdmissions: counters.agedBackgroundAdmissions,
            nonBackgroundAdmissionsWhileBackgroundAged: counters.nonBackgroundAdmissionsWhileBackgroundAged,
            droppedHookEvents: droppedHookEvents,
            failures: counters.failures
        )
    }

    private var timingSnapshot: CodeMapArtifactBuildCoordinatorTimingAccounting {
        CodeMapArtifactBuildCoordinatorTimingAccounting(
            totalBuildQueueNanoseconds: timings.totalBuildQueue,
            maximumBuildQueueNanoseconds: timings.maximumBuildQueue,
            totalBuildPermitNanoseconds: timings.totalBuildPermit,
            maximumBuildPermitNanoseconds: timings.maximumBuildPermit,
            totalDeterministicBuildNanoseconds: timings.totalBuild,
            maximumDeterministicBuildNanoseconds: timings.maximumBuild,
            totalCASPersistenceNanoseconds: timings.totalCAS,
            maximumCASPersistenceNanoseconds: timings.maximumCAS,
            totalLocatorPublicationNanoseconds: timings.totalLocator,
            maximumLocatorPublicationNanoseconds: timings.maximumLocator
        )
    }

    private func duration(from start: UInt64, to end: UInt64) -> UInt64 {
        Self.duration(from: start, to: end)
    }

    private static func duration(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    private func addingChecked(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func increment(_ value: inout UInt64) {
        value = addingSaturating(value, 1)
    }

    private func add(_ value: inout UInt64, _ amount: UInt64) {
        value = addingSaturating(value, amount)
    }
}
