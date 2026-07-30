#if DEBUG
    import CryptoKit
    import Foundation

    enum DebugWorktreeStartupBenchmarkError: Error, Equatable {
        case disabled
        case invalidScope
        case invalidControl
        case invalidToken
        case expired
        case alreadyConsumed
        case invalidTransition
        case sampleNotFound
        case invalidPreparation
        case preparationCapacityExceeded
        case recoveryCapacityExceeded
        case invalidRecovery
        case startAborted
        case startIdentityMismatch
        case baseSnapshotUnavailable(BaseSnapshotFailure)

        struct BaseSnapshotFailure: Equatable {
            enum Reason: String, Equatable {
                case nonGit = "non_git"
                case unsupportedRoot = "unsupported_root"
                case authorityUnavailable = "authority_unavailable"
                case catalogMismatch = "catalog_mismatch"
                case failed
            }

            let reason: Reason
            let stage: WorkspaceRootReusableSnapshotCoordinator.ObservationFailureStage?
            let cause: String?
        }

        var code: String {
            switch self {
            case .disabled: "disabled"
            case .invalidScope: "scope_mismatch"
            case .invalidControl: "invalid_control"
            case .invalidToken: "invalid_token"
            case .expired: "expired"
            case .alreadyConsumed: "already_consumed"
            case .invalidTransition: "invalid_transition"
            case .sampleNotFound: "sample_not_found"
            case .invalidPreparation: "invalid_preparation"
            case .preparationCapacityExceeded: "preparation_capacity_exceeded"
            case .recoveryCapacityExceeded: "recovery_capacity_exceeded"
            case .invalidRecovery: "invalid_recovery"
            case .startAborted: "start_aborted"
            case .startIdentityMismatch: "start_identity_mismatch"
            case .baseSnapshotUnavailable: "base_snapshot_unavailable"
            }
        }
    }

    final class WorktreeStartupBenchmarkGate: @unchecked Sendable {
        static let shared = WorktreeStartupBenchmarkGate()

        private let lock = NSLock()
        private var enabled = false
        private var generation: UInt64 = 0

        @discardableResult
        func setEnabled(_ value: Bool) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            guard enabled != value else { return generation }
            enabled = value
            generation &+= 1
            return generation
        }

        func requireEnabled<T>(_ body: (UInt64) throws -> T) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { throw DebugWorktreeStartupBenchmarkError.disabled }
            return try body(generation)
        }

        func isCurrentEnabledGeneration(_ expected: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return enabled && generation == expected
        }

        func snapshot() -> (enabled: Bool, generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            return (enabled, generation)
        }
    }

    struct DebugWorktreeStartupBenchmarkScope: Hashable {
        let windowID: Int
        let workspaceID: UUID
        let contextID: UUID
        let rootID: UUID
    }

    struct DebugWorktreeStartupBenchmarkRootIdentity: Hashable {
        let scope: DebugWorktreeStartupBenchmarkScope
        let standardizedLogicalRootPath: String
        let repositoryID: String
        let repositoryKey: GitWorkspaceAuthorityRepositoryKey
    }

    struct DebugWorktreeStartupBenchmarkExpectedStart: Hashable {
        let rootIdentity: DebugWorktreeStartupBenchmarkRootIdentity
        let requestedBranch: String?
        let requestedBaseRef: String?
    }

    struct DebugWorktreeStartupBenchmarkValidatedStart: Hashable {
        let scope: DebugWorktreeStartupBenchmarkScope
        let logicalRootID: UUID
        let standardizedLogicalRootPath: String
        let repositoryID: String
        let repositoryKey: GitWorkspaceAuthorityRepositoryKey
        let requestedBranch: String?
        let requestedBaseRef: String?
        let standardizedDestinationPath: String
        let standardizedAppManagedContainerPath: String
        let destinationID: String
        let agentSessionID: UUID
        let startAttemptID: UUID
    }

    struct DebugWorktreeStartupBenchmarkPendingStart: Hashable {
        let token: UUID
        let startAttemptID: UUID
    }

    enum DebugRecoverableStartPhase: String, CaseIterable {
        case armed
        case targetRegistered = "target_registered"
        case worktreeCreated = "worktree_created"
        case bindingConstructed = "binding_constructed"
        case ownershipCommitted = "ownership_committed"
        case providerStart = "provider_start"
        case responsePrepared = "response_prepared"
        case failed
        case discardRequested = "discard_requested"
        case discardCompleted = "discard_completed"

        var rank: Int {
            Self.allCases.firstIndex(of: self) ?? 0
        }
    }

    struct DebugWorktreeStartupBenchmarkRoutingProvenance: Equatable {
        let connectionID: UUID
        let boundWindowID: Int
        let boundWorkspaceID: UUID
        let boundContextID: UUID

        func authorize(
            connectionID: UUID,
            windowID: Int,
            hiddenWindowID: Int,
            workspaceID: UUID,
            contextID: UUID,
            benchmarkContextID: UUID
        ) throws {
            guard self.connectionID == connectionID,
                  boundWindowID == windowID,
                  boundWindowID == hiddenWindowID,
                  boundWorkspaceID == workspaceID,
                  boundContextID == contextID,
                  boundContextID == benchmarkContextID
            else { throw DebugWorktreeStartupBenchmarkError.invalidScope }
        }
    }

    final class WorktreeStartupBenchmarkDiagnostics: @unchecked Sendable {
        static let shared = WorktreeStartupBenchmarkDiagnostics()
        static let enabledDefaultsKey = "enableWorktreeStartupBenchmarkDiagnostics"
        static let requiredWorkspaceNamePrefixes = ["RPCE 8E Bench ", "RPCE Search Bench "]
        @TaskLocal static var currentPendingStart: DebugWorktreeStartupBenchmarkPendingStart?

        struct RouteControl: Equatable {
            let observe: Bool
            let serve: Bool
            let forceFullCrawl: Bool

            init(observe: Bool, serve: Bool, forceFullCrawl: Bool) {
                self.observe = observe || serve
                self.serve = serve
                self.forceFullCrawl = forceFullCrawl
            }

            var flags: WorktreeStartupFeatureFlags {
                WorktreeStartupFeatureFlags(
                    observeDiffSeededWorktreeStartup: observe,
                    serveDiffSeededWorktreeStartup: serve
                )
            }

            var servingControl: WorktreeStartupServingControl {
                forceFullCrawl ? .forceFullCrawl : .automatic
            }

            var name: String {
                if forceFullCrawl { return "forcedFullCrawl" }
                if serve { return "diffSeedServing" }
                if observe { return "diffSeedObservation" }
                return "fullCrawl"
            }
        }

        struct ControlResult: Equatable {
            let controlID: UUID
            let expiresAtNanoseconds: UInt64
            let previousControlID: UUID?
            let route: RouteControl
        }

        struct PreparedControlResult: Equatable {
            let control: ControlResult
            let baseSnapshotPrepared: Bool
            let baseSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity?
            let preparation: WorktreeStartupPreparationInstrumentation.Snapshot
        }

        struct ArmResult: Equatable {
            let token: UUID
            let correlationID: UUID
            let expiresAtNanoseconds: UInt64
            let route: RouteControl
        }

        struct Consumption: Equatable {
            let correlationID: UUID
            let flags: WorktreeStartupFeatureFlags
            let servingControl: WorktreeStartupServingControl
            let routeName: String
            let metricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag
        }

        struct Preflight: Equatable {
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let correlationID: UUID
            let flags: WorktreeStartupFeatureFlags
            let servingControl: WorktreeStartupServingControl
        }

        struct RecoverableStartSnapshot: Equatable {
            let correlationID: UUID
            let controlID: UUID
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let phase: DebugRecoverableStartPhase
            let abortRequested: Bool
            let agentSessionID: UUID?
            let targetTabID: UUID?
            let targetOrigin: String?
            let worktreeID: String?
            let repositoryID: String?
            let repositoryKey: String?
            let branch: String?
            let head: String?
            let worktreePathDigest: String?
            let ownedPhysicalPathDigests: [String]
            let bindingID: String?
            let providerDispatchStarted: Bool
            let providerRunActive: Bool
            let errorCategory: String?
            let expiresAtNanoseconds: UInt64
        }

        struct RecoverableStartAbortDecision {
            let snapshot: RecoverableStartSnapshot
            let target: AgentModeViewModel.MCPSessionTarget?
            let requiresAgentCancel: Bool
        }

        private struct ControlLease {
            let id: UUID
            let scope: DebugWorktreeStartupBenchmarkScope
            let route: RouteControl
            let expiresAtNanoseconds: UInt64
            let previousID: UUID?
        }

        private struct TokenLease {
            let token: UUID
            let correlationID: UUID
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let route: RouteControl
            let scenario: String
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let expiresAtNanoseconds: UInt64
            let gateGeneration: UInt64
            var consumed: Bool
        }

        private struct RecoverableStartRecord {
            let correlationID: UUID
            let controlID: UUID
            let scope: DebugWorktreeStartupBenchmarkScope
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let expiresAtNanoseconds: UInt64
            var phase: DebugRecoverableStartPhase = .armed
            var abortRequested = false
            var agentSessionID: UUID?
            var targetTabID: UUID?
            var targetOrigin: AgentModeViewModel.MCPSessionTarget.Origin?
            var worktreeID: String?
            var repositoryID: String?
            var repositoryKey: String?
            var branch: String?
            var head: String?
            var worktreePathDigest: String?
            var ownedPhysicalPathDigests: [String] = []
            var bindingID: String?
            var providerDispatchStarted = false
            var providerRunActive = false
            var errorCategory: String?
        }

        private struct SampleState {
            let correlationID: UUID
            let expectedStart: DebugWorktreeStartupBenchmarkExpectedStart
            let route: RouteControl
            let scenario: String
            let invocation: Int
            let ordinal: Int
            let warmup: Bool
            let armedAtNanoseconds: UInt64
            let baselineEventEvictionCount: Int
            let baselineReceiptDecisionEvictionCount: Int
            let baselineDeltaCompatibilityEvaluationEvictionCount: Int
            var agentSessionID: UUID?
            var startAttemptID: UUID?
            var metricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?
            var activeBenchmarkPhases: Set<WorktreeStartupPhase> = []

            var scope: DebugWorktreeStartupBenchmarkScope {
                expectedStart.rootIdentity.scope
            }
        }

        private struct PreparationRecord {
            let scope: DebugWorktreeStartupBenchmarkScope
            let recorder: WorktreeStartupPreparationInstrumentation.Recorder
            let createdOrdinal: UInt64
            var routeControlID: UUID?
            var completedAtNanoseconds: UInt64?
        }

        private let lock = NSLock()
        private let maximumPreparationRecordCount: Int
        private let maximumRecoverableStartRecordCount: Int
        private let completedPreparationTTLNanoseconds: UInt64
        private let afterControlLeaseForTesting: (@Sendable () async -> Void)?
        private var currentControlIDByScope: [DebugWorktreeStartupBenchmarkScope: UUID] = [:]
        private var controlsByID: [UUID: ControlLease] = [:]
        private var tokensByID: [UUID: TokenLease] = [:]
        private var samplesByCorrelationID: [UUID: SampleState] = [:]
        private var recoverableStartsByCorrelationID: [UUID: RecoverableStartRecord] = [:]
        private var preparationsByID: [UUID: PreparationRecord] = [:]
        private var nextPreparationOrdinal: UInt64 = 0

        init(
            maximumPreparationRecordCount: Int = 32,
            maximumRecoverableStartRecordCount: Int = 32,
            completedPreparationTTLNanoseconds: UInt64 = 15 * 60 * 1_000_000_000,
            afterControlLeaseForTesting: (@Sendable () async -> Void)? = nil
        ) {
            self.maximumPreparationRecordCount = max(1, maximumPreparationRecordCount)
            self.maximumRecoverableStartRecordCount = max(1, maximumRecoverableStartRecordCount)
            self.completedPreparationTTLNanoseconds = completedPreparationTTLNanoseconds
            self.afterControlLeaseForTesting = afterControlLeaseForTesting
        }

        static func synchronizeGateFromDefaults(_ defaults: UserDefaults = .standard) {
            setGateEnabled(defaults.bool(forKey: enabledDefaultsKey))
        }

        static func setGateEnabled(_ enabled: Bool) {
            WorktreeStartupBenchmarkGate.shared.setEnabled(enabled)
            guard !enabled else { return }
            shared.revokeAll()
        }

        func setFlags(
            scope: DebugWorktreeStartupBenchmarkScope,
            observe: Bool,
            serve: Bool,
            forceFullCrawl: Bool,
            expiresSeconds: Int,
            preparationID: UUID? = nil
        ) throws -> ControlResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                let expires = Self.deadline(now: now, seconds: expiresSeconds)
                let route = RouteControl(observe: observe, serve: serve, forceFullCrawl: forceFullCrawl)
                lock.lock()
                purgeExpiredLocked(now: now)
                var preparationRecord: PreparationRecord?
                if let preparationID {
                    guard let record = preparationsByID[preparationID],
                          record.scope == scope,
                          record.routeControlID == nil
                    else {
                        lock.unlock()
                        throw DebugWorktreeStartupBenchmarkError.invalidPreparation
                    }
                    preparationRecord = record
                }
                let previous = currentControlIDByScope[scope].flatMap { controlsByID[$0] }
                let lease = ControlLease(
                    id: UUID(),
                    scope: scope,
                    route: route,
                    expiresAtNanoseconds: expires,
                    previousID: previous?.id
                )
                controlsByID[lease.id] = lease
                currentControlIDByScope[scope] = lease.id
                if let preparationID, var preparationRecord {
                    preparationRecord.routeControlID = lease.id
                    preparationRecord.recorder.recordRouteControlOwnership(controlID: lease.id, scope: scope)
                    preparationsByID[preparationID] = preparationRecord
                }
                lock.unlock()
                scheduleControlExpiry(lease.id, expiresAtNanoseconds: expires)
                return ControlResult(
                    controlID: lease.id,
                    expiresAtNanoseconds: expires,
                    previousControlID: previous?.id,
                    route: route
                )
            }
        }

        func setFlagsPreparingBaseSnapshot(
            scope: DebugWorktreeStartupBenchmarkScope,
            observe: Bool,
            serve: Bool,
            forceFullCrawl: Bool,
            expiresSeconds: Int,
            store: WorkspaceFileContextStore,
            expectedStandardizedRootPath: String,
            preparationID: UUID = UUID(),
            prefixControlEvidenceCacheMode: GitPrefixControlEvidenceCacheMode = .automatic,
            scopeResolutionDurationNanoseconds: UInt64 = 0
        ) async throws -> PreparedControlResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in }
            let recorder = try beginPreparation(preparationID: preparationID, scope: scope)
            recorder.recordCompleted(.scopeResolution, durationNanoseconds: scopeResolutionDurationNanoseconds)
            return try await withTaskCancellationHandler {
                try await WorktreeStartupPreparationInstrumentation.$currentRecorder.withValue(recorder) {
                    let totalSpan = recorder.begin(.setFlagsTotal)
                    do {
                        let shouldPrepareBaseSnapshot = (observe || serve) && !forceFullCrawl
                        var baseSnapshotIdentity: WorkspaceRootReusableSnapshotIdentity?
                        if shouldPrepareBaseSnapshot {
                            let observation = try await store.admitReusableSnapshotForLoadedRoot(
                                rootID: scope.rootID,
                                expectedStandardizedPath: expectedStandardizedRootPath,
                                prefixControlEvidenceCacheMode: prefixControlEvidenceCacheMode
                            )
                            switch observation {
                            case let .admitted(identity):
                                baseSnapshotIdentity = identity
                            case .nonGit:
                                throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                                    reason: .nonGit,
                                    stage: nil,
                                    cause: nil
                                ))
                            case .unsupportedRoot:
                                throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                                    reason: .unsupportedRoot,
                                    stage: nil,
                                    cause: nil
                                ))
                            case let .authorityUnavailable(stage, reason):
                                throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                                    reason: .authorityUnavailable,
                                    stage: stage,
                                    cause: reason.benchmarkDiagnosticCode
                                ))
                            case .catalogMismatch:
                                throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                                    reason: .catalogMismatch,
                                    stage: nil,
                                    cause: nil
                                ))
                            case let .failed(failure):
                                throw DebugWorktreeStartupBenchmarkError.baseSnapshotUnavailable(.init(
                                    reason: .failed,
                                    stage: failure.stage,
                                    cause: failure.cause.code
                                ))
                            }
                        }
                        try Task.checkCancellation()
                        let control = try setFlags(
                            scope: scope,
                            observe: observe,
                            serve: serve,
                            forceFullCrawl: forceFullCrawl,
                            expiresSeconds: expiresSeconds,
                            preparationID: preparationID
                        )
                        if let afterControlLeaseForTesting {
                            await afterControlLeaseForTesting()
                        }
                        try Task.checkCancellation()
                        totalSpan.end()
                        terminalizePreparation(preparationID, state: .admitted)
                        return PreparedControlResult(
                            control: control,
                            baseSnapshotPrepared: shouldPrepareBaseSnapshot,
                            baseSnapshotIdentity: baseSnapshotIdentity,
                            preparation: recorder.snapshot()
                        )
                    } catch is CancellationError {
                        revokePreparationOwnedControl(preparationID: preparationID, scope: scope)
                        totalSpan.end()
                        recorder.recordReason(.cancellation)
                        terminalizePreparation(preparationID, state: .cancelled)
                        throw CancellationError()
                    } catch {
                        totalSpan.end()
                        recorder.recordReason(.failure)
                        terminalizePreparation(preparationID, state: .failed)
                        throw error
                    }
                }
            } onCancel: {
                self.revokePreparationOwnedControl(preparationID: preparationID, scope: scope)
            }
        }

        func preparationSnapshot(
            scope: DebugWorktreeStartupBenchmarkScope,
            preparationID: UUID
        ) throws -> WorktreeStartupPreparationInstrumentation.Snapshot {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                purgeExpiredPreparationsLocked(now: DispatchTime.now().uptimeNanoseconds)
                guard let record = preparationsByID[preparationID], record.scope == scope else {
                    throw DebugWorktreeStartupBenchmarkError.invalidPreparation
                }
                return record.recorder.snapshot()
            }
        }

        func beginPreparationForTesting(
            preparationID: UUID,
            scope: DebugWorktreeStartupBenchmarkScope
        ) throws -> WorktreeStartupPreparationInstrumentation.Recorder {
            try beginPreparation(preparationID: preparationID, scope: scope)
        }

        func terminalizePreparationForTesting(
            preparationID: UUID,
            state: WorktreeStartupPreparationInstrumentation.TerminalState
        ) {
            terminalizePreparation(preparationID, state: state)
        }

        @discardableResult
        func restoreFlags(scope: DebugWorktreeStartupBenchmarkScope, controlID: UUID) throws -> UUID? {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let lease = controlsByID[controlID], lease.scope == scope,
                      currentControlIDByScope[scope] == controlID
                else { throw DebugWorktreeStartupBenchmarkError.invalidControl }
                controlsByID.removeValue(forKey: controlID)
                return restorePreviousLocked(for: lease, now: now)
            }
        }

        func arm(
            expectedStart: DebugWorktreeStartupBenchmarkExpectedStart,
            controlID: UUID,
            scenario: String,
            invocation: Int,
            ordinal: Int,
            warmup: Bool,
            expiresSeconds: Int
        ) throws -> ArmResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                let now = DispatchTime.now().uptimeNanoseconds
                lock.lock()
                purgeExpiredLocked(now: now)
                let scope = expectedStart.rootIdentity.scope
                guard let control = controlsByID[controlID],
                      control.scope == scope,
                      currentControlIDByScope[scope] == controlID
                else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.invalidControl
                }
                let expires = min(
                    control.expiresAtNanoseconds,
                    Self.deadline(now: now, seconds: expiresSeconds)
                )
                guard recoverableStartsByCorrelationID.count < maximumRecoverableStartRecordCount else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.recoveryCapacityExceeded
                }
                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                let token = UUID()
                let correlationID = UUID()
                tokensByID[token] = TokenLease(
                    token: token,
                    correlationID: correlationID,
                    expectedStart: expectedStart,
                    route: control.route,
                    scenario: scenario,
                    invocation: invocation,
                    ordinal: ordinal,
                    warmup: warmup,
                    expiresAtNanoseconds: expires,
                    gateGeneration: gateGeneration,
                    consumed: false
                )
                recoverableStartsByCorrelationID[correlationID] = RecoverableStartRecord(
                    correlationID: correlationID,
                    controlID: controlID,
                    scope: scope,
                    invocation: invocation,
                    ordinal: ordinal,
                    warmup: warmup,
                    expiresAtNanoseconds: expires
                )
                samplesByCorrelationID[correlationID] = SampleState(
                    correlationID: correlationID,
                    expectedStart: expectedStart,
                    route: control.route,
                    scenario: scenario,
                    invocation: invocation,
                    ordinal: ordinal,
                    warmup: warmup,
                    armedAtNanoseconds: now,
                    baselineEventEvictionCount: instrumentation.eventEvictionCount,
                    baselineReceiptDecisionEvictionCount: instrumentation.receiptDecisionEvictionCount,
                    baselineDeltaCompatibilityEvaluationEvictionCount: instrumentation
                        .deltaCompatibilityEvaluationEvictionCount,
                    agentSessionID: nil,
                    startAttemptID: nil,
                    metricTag: nil
                )
                lock.unlock()
                scheduleTokenExpiry(token, expiresAtNanoseconds: expires)
                return ArmResult(
                    token: token,
                    correlationID: correlationID,
                    expiresAtNanoseconds: expires,
                    route: control.route
                )
            }
        }

        func preflight(token: UUID) throws -> Preflight {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let lease = tokensByID[token] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidToken
                }
                guard !lease.consumed else { throw DebugWorktreeStartupBenchmarkError.alreadyConsumed }
                guard lease.expiresAtNanoseconds > now, lease.gateGeneration == gateGeneration else {
                    throw DebugWorktreeStartupBenchmarkError.expired
                }
                return Preflight(
                    expectedStart: lease.expectedStart,
                    correlationID: lease.correlationID,
                    flags: lease.route.flags,
                    servingControl: lease.route.servingControl
                )
            }
        }

        func consume(
            token: UUID,
            validatedStart: DebugWorktreeStartupBenchmarkValidatedStart
        ) throws -> Consumption {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { gateGeneration in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard var lease = tokensByID[token] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidToken
                }
                guard !lease.consumed else { throw DebugWorktreeStartupBenchmarkError.alreadyConsumed }
                guard lease.expiresAtNanoseconds > now, lease.gateGeneration == gateGeneration else {
                    throw DebugWorktreeStartupBenchmarkError.expired
                }
                let expected = lease.expectedStart
                let actualContainer = validatedStart.standardizedAppManagedContainerPath
                let actualDestination = validatedStart.standardizedDestinationPath
                guard expected.rootIdentity.scope == validatedStart.scope,
                      expected.rootIdentity.scope.contextID == validatedStart.scope.contextID,
                      expected.rootIdentity.scope.rootID == validatedStart.logicalRootID,
                      expected.rootIdentity.standardizedLogicalRootPath == validatedStart.standardizedLogicalRootPath,
                      expected.rootIdentity.repositoryID == validatedStart.repositoryID,
                      expected.rootIdentity.repositoryKey == validatedStart.repositoryKey,
                      expected.requestedBranch == validatedStart.requestedBranch,
                      expected.requestedBaseRef == validatedStart.requestedBaseRef,
                      Self.isPath(actualDestination, inside: actualContainer)
                else { throw DebugWorktreeStartupBenchmarkError.startIdentityMismatch }
                let tag = WorktreeStartupInstrumentation.BenchmarkMetricTag(
                    correlationID: lease.correlationID,
                    contextID: validatedStart.scope.contextID,
                    agentSessionID: validatedStart.agentSessionID,
                    logicalRootID: validatedStart.logicalRootID,
                    repositoryID: validatedStart.repositoryID,
                    destinationID: validatedStart.destinationID
                )
                lease.consumed = true
                tokensByID[token] = lease
                guard var sample = samplesByCorrelationID[lease.correlationID], sample.metricTag == nil else {
                    throw DebugWorktreeStartupBenchmarkError.invalidTransition
                }
                sample.agentSessionID = validatedStart.agentSessionID
                sample.startAttemptID = validatedStart.startAttemptID
                sample.metricTag = tag
                samplesByCorrelationID[lease.correlationID] = sample
                return Consumption(
                    correlationID: lease.correlationID,
                    flags: lease.route.flags,
                    servingControl: lease.route.servingControl,
                    routeName: lease.route.name,
                    metricTag: tag
                )
            }
        }

        func registerRecoverableStartTarget(
            correlationID: UUID,
            agentSessionID: UUID,
            targetTabID: UUID,
            targetOrigin: AgentModeViewModel.MCPSessionTarget.Origin
        ) throws {
            try mutateRecoverableStart(correlationID: correlationID) { record in
                guard record.agentSessionID == nil || record.agentSessionID == agentSessionID,
                      record.targetTabID == nil || record.targetTabID == targetTabID
                else { throw DebugWorktreeStartupBenchmarkError.invalidRecovery }
                record.agentSessionID = agentSessionID
                record.targetTabID = targetTabID
                record.targetOrigin = targetOrigin
                Self.advanceRecoverableStart(&record, to: .targetRegistered)
            }
        }

        func recordRecoverableStartWorktree(
            correlationID: UUID,
            worktreeID: String,
            repositoryID: String,
            repositoryKey: String,
            branch: String?,
            head: String,
            physicalPath: String
        ) throws {
            try mutateRecoverableStart(correlationID: correlationID) { record in
                let digest = Self.physicalPathDigest(physicalPath)
                guard record.worktreeID == nil || record.worktreeID == worktreeID,
                      record.repositoryID == nil || record.repositoryID == repositoryID,
                      record.worktreePathDigest == nil || record.worktreePathDigest == digest
                else { throw DebugWorktreeStartupBenchmarkError.invalidRecovery }
                record.worktreeID = worktreeID
                record.repositoryID = repositoryID
                record.repositoryKey = repositoryKey
                record.branch = branch
                record.head = head
                record.worktreePathDigest = digest
                Self.advanceRecoverableStart(&record, to: .worktreeCreated)
            }
        }

        func recordRecoverableStartBinding(
            correlationID: UUID,
            bindingID: String,
            physicalRootPath: String
        ) throws {
            try mutateRecoverableStart(correlationID: correlationID) { record in
                let digest = Self.physicalPathDigest(physicalRootPath)
                guard record.bindingID == nil || record.bindingID == bindingID,
                      record.ownedPhysicalPathDigests.isEmpty
                      || record.ownedPhysicalPathDigests.contains(digest),
                      record.ownedPhysicalPathDigests.count < 16
                else {
                    throw DebugWorktreeStartupBenchmarkError.invalidRecovery
                }
                record.bindingID = bindingID
                if !record.ownedPhysicalPathDigests.contains(digest) {
                    record.ownedPhysicalPathDigests.append(digest)
                }
                Self.advanceRecoverableStart(&record, to: .bindingConstructed)
            }
        }

        func beginRecoverableProviderDispatch(correlationID: UUID) throws {
            try mutateRecoverableStart(correlationID: correlationID) { record in
                guard !record.abortRequested else {
                    throw DebugWorktreeStartupBenchmarkError.startAborted
                }
                record.providerDispatchStarted = true
                record.providerRunActive = true
                Self.advanceRecoverableStart(&record, to: .providerStart)
            }
        }

        func recoverableStartAbortRequested(correlationID: UUID) -> Bool? {
            guard WorktreeStartupBenchmarkGate.shared.snapshot().enabled else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let record = recoverableStartsByCorrelationID[correlationID] else { return nil }
            return record.abortRequested
        }

        func recordRecoverableStartPhase(
            correlationID: UUID,
            phase: DebugRecoverableStartPhase,
            providerRunActive: Bool? = nil,
            errorCategory: String? = nil
        ) throws {
            try mutateRecoverableStart(correlationID: correlationID) { record in
                Self.advanceRecoverableStart(&record, to: phase)
                if let providerRunActive {
                    record.providerRunActive = providerRunActive
                }
                if let errorCategory {
                    record.errorCategory = errorCategory
                }
            }
        }

        func requireRecoverableStartNotAborted(correlationID: UUID) throws {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let record = recoverableStartsByCorrelationID[correlationID] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidRecovery
                }
                guard !record.abortRequested else {
                    throw DebugWorktreeStartupBenchmarkError.startAborted
                }
            }
        }

        func recoverableStartSnapshot(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            controlID: UUID
        ) throws -> RecoverableStartSnapshot {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let record = recoverableStartsByCorrelationID[correlationID],
                      record.scope == scope,
                      record.controlID == controlID
                else { throw DebugWorktreeStartupBenchmarkError.invalidRecovery }
                return Self.recoverableStartSnapshot(record)
            }
        }

        func requestRecoverableStartAbort(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            controlID: UUID
        ) throws -> RecoverableStartAbortDecision {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard var record = recoverableStartsByCorrelationID[correlationID],
                      record.scope == scope,
                      record.controlID == controlID
                else { throw DebugWorktreeStartupBenchmarkError.invalidRecovery }
                record.abortRequested = true
                recoverableStartsByCorrelationID[correlationID] = record
                let target: AgentModeViewModel.MCPSessionTarget? = if let tabID = record.targetTabID,
                                                                      let origin = record.targetOrigin
                {
                    AgentModeViewModel.MCPSessionTarget(
                        tabID: tabID,
                        sessionID: record.agentSessionID,
                        origin: origin
                    )
                } else {
                    nil
                }
                return RecoverableStartAbortDecision(
                    snapshot: Self.recoverableStartSnapshot(record),
                    target: target,
                    requiresAgentCancel: record.providerDispatchStarted
                        && record.phase != .discardCompleted
                )
            }
        }

        func mark(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            phase: WorktreeStartupPhase
        ) throws {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let context: WorktreeStartupContext
                lock.lock()
                let storedSample = samplesByCorrelationID[correlationID]
                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                guard var sample = storedSample,
                      sample.scope == scope,
                      let sessionID = sample.agentSessionID
                else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.sampleNotFound
                }
                let phases = Set(
                    instrumentation.events.lazy
                        .filter { $0.correlationID == correlationID }
                        .map(\.phase)
                )
                let valid: Bool = if phases.contains(.failed) {
                    false
                } else {
                    switch phase {
                    case .firstBenchmarkSearchStarted:
                        !phases.contains(.firstBenchmarkSearchStarted)
                    case .firstBenchmarkSearchCompleted:
                        phases.contains(.firstBenchmarkSearchStarted) && !phases.contains(.firstBenchmarkSearchCompleted)
                    case .firstBenchmarkReadStarted:
                        !phases.contains(.firstBenchmarkReadStarted)
                    case .firstBenchmarkReadCompleted:
                        phases.contains(.firstBenchmarkReadStarted) && !phases.contains(.firstBenchmarkReadCompleted)
                    case .firstBenchmarkCodemapStarted:
                        !phases.contains(.firstBenchmarkCodemapStarted)
                    case .firstBenchmarkCodemapCompleted:
                        phases.contains(.firstBenchmarkCodemapStarted) && !phases.contains(.firstBenchmarkCodemapCompleted)
                    case .warmBenchmarkCodemapStarted:
                        !phases.contains(.warmBenchmarkCodemapStarted)
                    case .warmBenchmarkCodemapCompleted:
                        phases.contains(.warmBenchmarkCodemapStarted) && !phases.contains(.warmBenchmarkCodemapCompleted)
                    case .passiveBenchmarkTreeStarted:
                        !phases.contains(.passiveBenchmarkTreeStarted)
                    case .passiveBenchmarkTreeCompleted:
                        phases.contains(.passiveBenchmarkTreeStarted) && !phases.contains(.passiveBenchmarkTreeCompleted)
                    case .benchmarkSelectionStarted:
                        !phases.contains(.benchmarkSelectionStarted)
                    case .benchmarkSelectionCompleted:
                        phases.contains(.benchmarkSelectionStarted) && !phases.contains(.benchmarkSelectionCompleted)
                    default:
                        false
                    }
                }
                guard valid else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.invalidTransition
                }
                switch phase {
                case .firstBenchmarkSearchStarted, .firstBenchmarkReadStarted,
                     .firstBenchmarkCodemapStarted, .warmBenchmarkCodemapStarted,
                     .passiveBenchmarkTreeStarted, .benchmarkSelectionStarted:
                    sample.activeBenchmarkPhases.insert(phase)
                case .firstBenchmarkSearchCompleted:
                    sample.activeBenchmarkPhases.remove(.firstBenchmarkSearchStarted)
                case .firstBenchmarkReadCompleted:
                    sample.activeBenchmarkPhases.remove(.firstBenchmarkReadStarted)
                case .firstBenchmarkCodemapCompleted:
                    sample.activeBenchmarkPhases.remove(.firstBenchmarkCodemapStarted)
                case .warmBenchmarkCodemapCompleted:
                    sample.activeBenchmarkPhases.remove(.warmBenchmarkCodemapStarted)
                case .passiveBenchmarkTreeCompleted:
                    sample.activeBenchmarkPhases.remove(.passiveBenchmarkTreeStarted)
                case .benchmarkSelectionCompleted:
                    sample.activeBenchmarkPhases.remove(.benchmarkSelectionStarted)
                default:
                    break
                }
                samplesByCorrelationID[correlationID] = sample
                context = WorktreeStartupContext(
                    agentSessionID: sessionID,
                    correlationID: correlationID,
                    flags: sample.route.flags,
                    servingControl: sample.route.servingControl
                )
                lock.unlock()
                WorktreeStartupInstrumentation.record(phase, context: context)
            }
        }

        func activeBenchmarkMetricTag(
            agentSessionID: UUID
        ) -> WorktreeStartupInstrumentation.BenchmarkMetricTag? {
            lock.lock()
            defer { lock.unlock() }
            let matches = samplesByCorrelationID.values.compactMap { sample -> WorktreeStartupInstrumentation.BenchmarkMetricTag? in
                guard sample.agentSessionID == agentSessionID,
                      !sample.activeBenchmarkPhases.isEmpty
                else { return nil }
                return sample.metricTag
            }
            return matches.count == 1 ? matches[0] : nil
        }

        func snapshotPayload(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            export: Bool
        ) throws -> [String: Any] {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard let sample = samplesByCorrelationID[correlationID], sample.scope == scope else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.sampleNotFound
                }
                lock.unlock()

                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                let events = instrumentation.events.filter { $0.correlationID == correlationID }
                let eventTimes = Dictionary(grouping: events, by: \.phase).compactMapValues {
                    $0.first?.timestampNanoseconds
                }
                let routeCounts = Dictionary(grouping: events.compactMap(\.route), by: { $0.rawValue })
                    .mapValues(\.count)
                let fallbackCounts = Dictionary(grouping: events.compactMap(\.fallback), by: { $0.rawValue })
                    .mapValues(\.count)
                let eventEvicted = instrumentation.eventEvictionCount > sample.baselineEventEvictionCount
                let receiptDecisions = instrumentation.receiptDecisions.filter { $0.correlationID == correlationID }
                let terminalReceiptDecisionCount = receiptDecisions.count(where: { $0.terminalStage != nil })
                let receiptDecisionEvicted = instrumentation.receiptDecisionEvictionCount
                    > sample.baselineReceiptDecisionEvictionCount
                let receiptDecisionAmbiguous = receiptDecisions.contains {
                    $0.ambiguousOrDuplicate || $0.creationAttemptCount > 1
                }
                let deltaCompatibilityEvaluations = instrumentation.deltaCompatibilityEvaluations.filter {
                    $0.correlationID == correlationID
                }
                let deltaCompatibilityEvaluationEvicted = instrumentation
                    .deltaCompatibilityEvaluationEvictionCount
                    > sample.baselineDeltaCompatibilityEvaluationEvictionCount
                let deltaCompatibilityEvaluationAmbiguous = deltaCompatibilityEvaluations.contains { $0.duplicate }
                let deltaCompatibilityEvaluationContradictory = deltaCompatibilityEvaluations
                    .contains { $0.contradictory }
                let deltaCompatibilityEvaluationValid = !deltaCompatibilityEvaluationEvicted
                    && !deltaCompatibilityEvaluationAmbiguous
                    && !deltaCompatibilityEvaluationContradictory
                let rootReady = eventTimes[.rootReady] != nil
                let receiptDecisionValid = !receiptDecisionEvicted
                    && receiptDecisions.count <= 1
                    && !receiptDecisionAmbiguous
                    && (!rootReady || terminalReceiptDecisionCount == 1)
                let metrics = sample.metricTag.map(WorktreeStartupInstrumentation.benchmarkMetricSnapshot)
                let git = metrics?.gitCommands ?? []
                let gitFamilies = Dictionary(grouping: git, by: { $0.family.rawValue }).mapValues(\.count)
                let gitPriorities = Dictionary(grouping: git, by: { String(describing: $0.priority) }).mapValues(\.count)
                let boundaryEvidence = Self.boundaryEvidence(
                    eventTimes,
                    baseline: sample.armedAtNanoseconds
                )
                let milestones = boundaryEvidence.milestones
                let durations = Self.durationPayload(eventTimes)
                let interactiveReadiness = Self.interactiveReadinessMicroseconds(eventTimes)

                var payload: [String: Any] = [
                    "ok": true,
                    "schema_version": 6,
                    "action": export ? "export" : "snapshot",
                    "scope": [
                        "window_id": scope.windowID,
                        "workspace_id": scope.workspaceID.uuidString,
                        "context_id": scope.contextID.uuidString,
                        "root_id": scope.rootID.uuidString
                    ],
                    "sample": [
                        "correlation_id": correlationID.uuidString,
                        "agent_session_id": sample.agentSessionID.map { $0.uuidString as Any } ?? NSNull(),
                        "start_attempt_id": sample.startAttemptID.map { $0.uuidString as Any } ?? NSNull(),
                        "configured_route": sample.route.name,
                        "scenario": sample.scenario,
                        "invocation": sample.invocation,
                        "ordinal": sample.ordinal,
                        "warmup": sample.warmup,
                        "root_ready": rootReady,
                        "first_search_complete": eventTimes[.firstBenchmarkSearchCompleted] != nil,
                        "first_read_complete": eventTimes[.firstBenchmarkReadCompleted] != nil,
                        "route_counts": routeCounts,
                        "fallback_counts": fallbackCounts,
                        "milestones_us": milestones,
                        "operation_boundaries_us": milestones,
                        "boundary_evidence_available": boundaryEvidence.valid,
                        "boundary_invalid_reasons": boundaryEvidence.invalidReasons,
                        "durations_us": durations,
                        "interactive_readiness_us": interactiveReadiness.map { $0 as Any } ?? NSNull(),
                        "event_buffer_evicted": eventEvicted,
                        "valid": !eventEvicted && sample.metricTag != nil
                            && receiptDecisionValid && deltaCompatibilityEvaluationValid
                            && boundaryEvidence.valid
                    ],
                    "receipt_decision_count": receiptDecisions.count,
                    "terminal_receipt_decision_count": terminalReceiptDecisionCount,
                    "receipt_decision_buffer_evicted": receiptDecisionEvicted,
                    "receipt_decision_ambiguous": receiptDecisionAmbiguous,
                    "receipt_decisions": receiptDecisions.map(Self.receiptDecisionPayload),
                    "delta_compatibility_evaluation_count": deltaCompatibilityEvaluations.count,
                    "delta_compatibility_evaluation_buffer_evicted": deltaCompatibilityEvaluationEvicted,
                    "delta_compatibility_evaluation_ambiguous": deltaCompatibilityEvaluationAmbiguous,
                    "delta_compatibility_evaluation_contradictory": deltaCompatibilityEvaluationContradictory,
                    "delta_compatibility_evaluations": deltaCompatibilityEvaluations.map(
                        Self.deltaCompatibilityEvaluationPayload
                    ),
                    "git": Self.gitPayload(git, families: gitFamilies, priorities: gitPriorities),
                    "work": Self.workPayload(metrics)
                ]
                if export {
                    payload["bounded"] = true
                    payload["contains_paths"] = false
                }
                return payload
            }
        }

        func reset(scope: DebugWorktreeStartupBenchmarkScope) throws -> [String: Int] {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let controlIDs = controlsByID.values.filter { $0.scope == scope }.map(\.id)
                let tokenIDs = tokensByID.values.filter { $0.expectedStart.rootIdentity.scope == scope }.map(\.token)
                let samples = samplesByCorrelationID.values.filter { $0.scope == scope }
                let preparationIDs = preparationsByID.compactMap { id, record in
                    record.scope == scope ? id : nil
                }
                let recoveryIDs = recoverableStartsByCorrelationID.compactMap { id, record in
                    record.scope == scope ? id : nil
                }
                controlIDs.forEach { controlsByID.removeValue(forKey: $0) }
                tokenIDs.forEach { tokensByID.removeValue(forKey: $0) }
                for sample in samples {
                    samplesByCorrelationID.removeValue(forKey: sample.correlationID)
                    WorktreeStartupInstrumentation.resetBenchmarkMetrics(correlationID: sample.correlationID)
                }
                currentControlIDByScope.removeValue(forKey: scope)
                preparationIDs.forEach { preparationsByID.removeValue(forKey: $0) }
                recoveryIDs.forEach { recoverableStartsByCorrelationID.removeValue(forKey: $0) }
                return [
                    "control_count": controlIDs.count,
                    "token_count": tokenIDs.count,
                    "sample_count": samples.count,
                    "preparation_count": preparationIDs.count,
                    "recovery_count": recoveryIDs.count
                ]
            }
        }

        func revokeAll() {
            lock.lock()
            currentControlIDByScope.removeAll(keepingCapacity: true)
            controlsByID.removeAll(keepingCapacity: true)
            tokensByID.removeAll(keepingCapacity: true)
            samplesByCorrelationID.removeAll(keepingCapacity: true)
            recoverableStartsByCorrelationID.removeAll(keepingCapacity: true)
            preparationsByID.removeAll(keepingCapacity: true)
            lock.unlock()
            WorktreeStartupInstrumentation.resetBenchmarkMetrics()
        }

        private func mutateRecoverableStart(
            correlationID: UUID,
            _ mutation: (inout RecoverableStartRecord) throws -> Void
        ) throws {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                lock.lock()
                defer { lock.unlock() }
                let now = DispatchTime.now().uptimeNanoseconds
                purgeExpiredLocked(now: now)
                guard var record = recoverableStartsByCorrelationID[correlationID] else {
                    throw DebugWorktreeStartupBenchmarkError.invalidRecovery
                }
                try mutation(&record)
                recoverableStartsByCorrelationID[correlationID] = record
            }
        }

        private static func advanceRecoverableStart(
            _ record: inout RecoverableStartRecord,
            to phase: DebugRecoverableStartPhase
        ) {
            if phase.rank >= record.phase.rank {
                record.phase = phase
            }
        }

        private static func recoverableStartSnapshot(
            _ record: RecoverableStartRecord
        ) -> RecoverableStartSnapshot {
            let origin: String? = switch record.targetOrigin {
            case .existingSession?: "existing_session"
            case .existingTab?: "existing_tab"
            case .createdForSessionResume?: "created_for_session_resume"
            case .createdNewTab?: "created_new_tab"
            case nil: nil
            }
            return RecoverableStartSnapshot(
                correlationID: record.correlationID,
                controlID: record.controlID,
                invocation: record.invocation,
                ordinal: record.ordinal,
                warmup: record.warmup,
                phase: record.phase,
                abortRequested: record.abortRequested,
                agentSessionID: record.agentSessionID,
                targetTabID: record.targetTabID,
                targetOrigin: origin,
                worktreeID: record.worktreeID,
                repositoryID: record.repositoryID,
                repositoryKey: record.repositoryKey,
                branch: record.branch,
                head: record.head,
                worktreePathDigest: record.worktreePathDigest,
                ownedPhysicalPathDigests: record.ownedPhysicalPathDigests.sorted(),
                bindingID: record.bindingID,
                providerDispatchStarted: record.providerDispatchStarted,
                providerRunActive: record.providerRunActive,
                errorCategory: record.errorCategory,
                expiresAtNanoseconds: record.expiresAtNanoseconds
            )
        }

        private static func physicalPathDigest(_ path: String) -> String {
            let standardized = StandardizedPath.absolute((path as NSString).expandingTildeInPath)
            return SHA256.hash(data: Data(standardized.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        private func beginPreparation(
            preparationID: UUID,
            scope: DebugWorktreeStartupBenchmarkScope
        ) throws -> WorktreeStartupPreparationInstrumentation.Recorder {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            defer { lock.unlock() }
            purgeExpiredPreparationsLocked(now: now)
            guard preparationsByID[preparationID] == nil else {
                throw DebugWorktreeStartupBenchmarkError.invalidPreparation
            }
            if preparationsByID.count >= maximumPreparationRecordCount {
                guard let eviction = preparationsByID.min(by: { lhs, rhs in
                    switch (lhs.value.completedAtNanoseconds, rhs.value.completedAtNanoseconds) {
                    case let (left?, right?):
                        left == right ? lhs.value.createdOrdinal < rhs.value.createdOrdinal : left < right
                    case (.some, .none): true
                    case (.none, .some): false
                    case (.none, .none): lhs.value.createdOrdinal < rhs.value.createdOrdinal
                    }
                }), eviction.value.completedAtNanoseconds != nil else {
                    throw DebugWorktreeStartupBenchmarkError.preparationCapacityExceeded
                }
                preparationsByID.removeValue(forKey: eviction.key)
            }
            nextPreparationOrdinal = nextPreparationOrdinal == UInt64.max ? UInt64.max : nextPreparationOrdinal + 1
            let recorder = WorktreeStartupPreparationInstrumentation.Recorder(
                preparationID: preparationID,
                startedAtNanoseconds: now
            )
            preparationsByID[preparationID] = PreparationRecord(
                scope: scope,
                recorder: recorder,
                createdOrdinal: nextPreparationOrdinal,
                routeControlID: nil,
                completedAtNanoseconds: nil
            )
            return recorder
        }

        private func revokePreparationOwnedControl(
            preparationID: UUID,
            scope: DebugWorktreeStartupBenchmarkScope
        ) {
            lock.lock()
            guard let record = preparationsByID[preparationID],
                  record.scope == scope,
                  let controlID = record.routeControlID
            else {
                lock.unlock()
                return
            }
            if let lease = controlsByID.removeValue(forKey: controlID),
               lease.scope == scope,
               currentControlIDByScope[scope] == controlID
            {
                _ = restorePreviousLocked(for: lease, now: DispatchTime.now().uptimeNanoseconds)
            }
            record.recorder.recordRouteControlRevoked(controlID: controlID)
            lock.unlock()
        }

        private func terminalizePreparation(
            _ preparationID: UUID,
            state: WorktreeStartupPreparationInstrumentation.TerminalState
        ) {
            lock.lock()
            guard var record = preparationsByID[preparationID] else {
                lock.unlock()
                return
            }
            let changed = record.recorder.terminalize(state)
            if changed {
                record.completedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
                preparationsByID[preparationID] = record
            }
            lock.unlock()
        }

        private func purgeExpiredPreparationsLocked(now: UInt64) {
            preparationsByID = preparationsByID.filter { _, record in
                guard let completedAt = record.completedAtNanoseconds else { return true }
                guard now >= completedAt else { return true }
                return now - completedAt < completedPreparationTTLNanoseconds
            }
        }

        private func scheduleControlExpiry(_ id: UUID, expiresAtNanoseconds: UInt64) {
            Task { [weak self] in
                let now = DispatchTime.now().uptimeNanoseconds
                if expiresAtNanoseconds > now {
                    try? await Task.sleep(nanoseconds: expiresAtNanoseconds - now)
                }
                self?.expireControl(id)
            }
        }

        private func scheduleTokenExpiry(_ token: UUID, expiresAtNanoseconds: UInt64) {
            Task { [weak self] in
                let now = DispatchTime.now().uptimeNanoseconds
                if expiresAtNanoseconds > now {
                    try? await Task.sleep(nanoseconds: expiresAtNanoseconds - now)
                }
                self?.expireToken(token)
            }
        }

        private func expireControl(_ id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let lease = controlsByID[id], lease.expiresAtNanoseconds <= DispatchTime.now().uptimeNanoseconds else {
                return
            }
            controlsByID.removeValue(forKey: id)
            if currentControlIDByScope[lease.scope] == id {
                _ = restorePreviousLocked(for: lease, now: DispatchTime.now().uptimeNanoseconds)
            }
        }

        private func expireToken(_ token: UUID) {
            lock.lock()
            defer { lock.unlock() }
            guard let lease = tokensByID[token],
                  !lease.consumed,
                  lease.expiresAtNanoseconds <= DispatchTime.now().uptimeNanoseconds
            else { return }
            tokensByID.removeValue(forKey: token)
        }

        private func purgeExpiredLocked(now: UInt64) {
            let expiredTokenIDs = tokensByID.values
                .filter { !$0.consumed && $0.expiresAtNanoseconds <= now }
                .map(\.token)
            for tokenID in expiredTokenIDs {
                tokensByID.removeValue(forKey: tokenID)
            }
            recoverableStartsByCorrelationID = recoverableStartsByCorrelationID.filter {
                $0.value.expiresAtNanoseconds > now
            }
            let expiredControls = controlsByID.values.filter { $0.expiresAtNanoseconds <= now }
            for lease in expiredControls {
                controlsByID.removeValue(forKey: lease.id)
                if currentControlIDByScope[lease.scope] == lease.id {
                    _ = restorePreviousLocked(for: lease, now: now)
                }
            }
        }

        private func restorePreviousLocked(for lease: ControlLease, now: UInt64) -> UUID? {
            if let previousID = lease.previousID,
               let previous = controlsByID[previousID],
               previous.expiresAtNanoseconds > now
            {
                currentControlIDByScope[lease.scope] = previous.id
                return previous.id
            }
            currentControlIDByScope.removeValue(forKey: lease.scope)
            return nil
        }

        private static func receiptDecisionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptDecision
        ) -> [String: Any] {
            var payload: [String: Any] = [
                "correlation_id": decision.correlationID.uuidString,
                "terminal_stage": optionalRawValue(decision.terminalStage),
                "ambiguous_or_duplicate": decision.ambiguousOrDuplicate,
                "creation_attempt_count": decision.creationAttemptCount
            ]
            payload["creation"] = decision.creation.map(receiptCreationPayload) ?? NSNull()
            payload["coordinator"] = decision.coordinator.map(receiptCoordinatorPayload) ?? NSNull()
            payload["projection"] = decision.projection.map(receiptProjectionPayload) ?? NSNull()
            payload["consumption"] = decision.consumption.map(receiptConsumptionPayload) ?? NSNull()
            return payload
        }

        private static func deltaCompatibilityEvaluationPayload(
            _ record: WorktreeStartupInstrumentation.DeltaCompatibilityEvaluationRecord
        ) -> [String: Any] {
            let evaluation = record.evaluation
            return [
                "correlation_id": record.correlationID.uuidString,
                "source": evaluation.source.rawValue,
                "decision": evaluation.decision.rawValue,
                "policy_canonicalization_comparison": record.policyCanonicalizationComparison.map(
                    policyCanonicalizationComparisonPayload
                ) ?? NSNull(),
                "field_evaluations": evaluation.fieldEvaluations.map {
                    [
                        "field": $0.field.rawValue,
                        "decision": $0.decision.rawValue,
                        "base_digest": $0.baseDigest,
                        "target_digest": $0.targetDigest
                    ]
                },
                "mismatched_fields": evaluation.mismatchedFields.map(\.rawValue),
                "correction_rule_applied": evaluation.correctionRuleApplied.rawValue,
                "tree_relation": evaluation.treeRelation.rawValue,
                "exact_snapshot_lookup_reached": record.exactSnapshotLookupReached,
                "exact_snapshot_lookup_passed": record.exactSnapshotLookupPassed,
                "target_authority_comparison_reached": record.targetAuthorityComparisonReached,
                "target_authority_comparison_passed": record.targetAuthorityComparisonPassed,
                "current_search_abi_reached": record.currentSearchABIReached,
                "current_search_abi_matched": optional(record.currentSearchABIMatched),
                "catalog_policy_comparison_reached": record.catalogPolicyComparisonReached,
                "catalog_policy_matched": optional(record.catalogPolicyMatched),
                "terminal_fallback": optionalRawValue(record.terminalFallback),
                "duplicate": record.duplicate,
                "contradictory": record.contradictory
            ]
        }

        private static func policyCanonicalizationComparisonPayload(
            _ comparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison
        ) -> [String: Any] {
            [
                "classification": comparison.classification.rawValue,
                "constituent_comparisons": comparison.constituentComparisons.map {
                    [
                        "constituent": $0.constituent.rawValue,
                        "matched": $0.matched
                    ]
                },
                "base": comparison.base.map(policyCanonicalizationDiagnosticsPayload) ?? NSNull(),
                "target": comparison.target.map(policyCanonicalizationDiagnosticsPayload) ?? NSNull()
            ]
        }

        private static func policyCanonicalizationDiagnosticsPayload(
            _ diagnostics: GitWorkspacePolicyCanonicalizationDiagnostics
        ) -> [String: Any] {
            [
                "constituents": GitWorkspacePolicyCanonicalizationDiagnostics.Constituent.allCases.map {
                    policyCanonicalizationConstituentPayload($0, diagnostics: diagnostics)
                }
            ]
        }

        private static func policyCanonicalizationConstituentPayload(
            _ constituent: GitWorkspacePolicyCanonicalizationDiagnostics.Constituent,
            diagnostics: GitWorkspacePolicyCanonicalizationDiagnostics
        ) -> [String: Any] {
            switch constituent {
            case .rootNeutralPolicyConfig:
                [
                    "constituent": constituent.rawValue,
                    "byte_count": diagnostics.rootNeutralPolicyConfigByteCount,
                    "sha256": diagnostics.rootNeutralPolicyConfigSHA256
                ]
            case .commonInfoExclude:
                [
                    "constituent": constituent.rawValue,
                    "state": diagnostics.commonInfoExclude.state.rawValue,
                    "digest": diagnostics.commonInfoExclude.digest
                ]
            case .canonicalIgnoreFooter:
                [
                    "constituent": constituent.rawValue,
                    "digest": diagnostics.canonicalIgnoreFooter.digest,
                    "record_count": diagnostics.canonicalIgnoreFooter.recordCount
                ]
            case .externalExcludes:
                [
                    "constituent": constituent.rawValue,
                    "state": diagnostics.externalExcludes.state.rawValue,
                    "identity_digest": diagnostics.externalExcludes.identityDigest,
                    "byte_count": diagnostics.externalExcludes.byteCount
                ]
            case .configuredIgnorePolicy:
                [
                    "constituent": constituent.rawValue,
                    "digest": diagnostics.configuredIgnorePolicyDigest
                ]
            case .commonInfoAttributes:
                [
                    "constituent": constituent.rawValue,
                    "state": diagnostics.commonInfoAttributes.state.rawValue,
                    "digest": diagnostics.commonInfoAttributes.digest
                ]
            case .canonicalAttributeFooter:
                [
                    "constituent": constituent.rawValue,
                    "digest": diagnostics.canonicalAttributeFooter.digest,
                    "record_count": diagnostics.canonicalAttributeFooter.recordCount
                ]
            case .externalAttributes:
                [
                    "constituent": constituent.rawValue,
                    "state": diagnostics.externalAttributes.state.rawValue,
                    "identity_digest": diagnostics.externalAttributes.identityDigest,
                    "byte_count": diagnostics.externalAttributes.byteCount
                ]
            case .attributePolicy:
                [
                    "constituent": constituent.rawValue,
                    "digest": diagnostics.attributePolicyDigest
                ]
            case .sparsePolicy:
                [
                    "constituent": constituent.rawValue,
                    "digest": diagnostics.sparsePolicyDigest
                ]
            case .canonicalization:
                [
                    "constituent": constituent.rawValue,
                    "policy_version": diagnostics.canonicalizationPolicyVersion,
                    "pruned_root_count": diagnostics.prunedRootCount,
                    "pruned_root_summary_sha256": diagnostics.prunedRootSummarySHA256,
                    "completeness": diagnostics.completeness.rawValue
                ]
            case .committedControls:
                [
                    "constituent": constituent.rawValue,
                    "record_count": diagnostics.committedControlCount,
                    "summary_sha256": diagnostics.committedControlSummarySHA256
                ]
            }
        }

        private static func receiptCreationPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptCreationDecision
        ) -> [String: Any] {
            [
                "source_layout_state": decision.sourceLayoutState.rawValue,
                "destination_eligibility": decision.destinationEligibility.rawValue,
                "source_authority_key_digest": optional(decision.sourceAuthorityKeyDigest),
                "source_common_directory_digest": optional(decision.sourceCommonDirectoryDigest),
                "repository_id_digest": optional(decision.repositoryIDDigest),
                "repository_namespace_digest": optional(decision.repositoryNamespaceDigest),
                "requested_prefix_digest": optional(decision.requestedPrefixDigest),
                "current_lease_present": optional(decision.currentLeasePresent),
                "current_lease_current_at_snapshot_lookup": optional(decision.currentLeaseCurrentAtSnapshotLookup),
                "current_snapshot_present": optional(decision.currentSnapshotPresent),
                "current_snapshot_content_address_valid": optional(decision.currentSnapshotContentAddressValid),
                "current_snapshot_sha256": optional(decision.currentSnapshotSHA256),
                "parent_lookup_route": decision.parentLookupRoute.rawValue,
                "parent_lookup_failure": decision.parentLookupFailure.rawValue,
                "parent_authority_key_match": decision.parentAuthorityKeyMatch.rawValue,
                "parent_prefix_match": decision.parentPrefixMatch.rawValue,
                "target_tree_resolution": decision.targetTreeResolution.rawValue,
                "witness_requested": optional(decision.witnessRequested),
                "witness_started": optional(decision.witnessStarted),
                "witness_finished": optional(decision.witnessFinished),
                "witness_start_event_id": optional(decision.witnessStartEventID),
                "witness_end_event_id": optional(decision.witnessEndEventID),
                "witness_start_event_id_valid": optional(decision.witnessStartEventIDValid),
                "witness_end_event_id_valid": optional(decision.witnessEndEventIDValid),
                "witness_stable_root_available_before_mutation": optional(
                    decision.witnessStableRootAvailableBeforeMutation
                ),
                "witness_destination_absent_before_mutation": optional(
                    decision.witnessDestinationAbsentBeforeMutation
                ),
                "witness_destination_strict_descendant": optional(
                    decision.witnessDestinationStrictDescendant
                ),
                "witness_stable_root_unchanged_after_initialization": optional(
                    decision.witnessStableRootUnchangedAfterInitialization
                ),
                "witness_stream_creation_succeeded": optional(decision.witnessStreamCreationSucceeded),
                "witness_activation_flush_completed": optional(decision.witnessActivationFlushCompleted),
                "witness_activation_callback_barrier_completed": optional(
                    decision.witnessActivationCallbackBarrierCompleted
                ),
                "witness_ending_flush_completed": optional(decision.witnessEndingFlushCompleted),
                "witness_ending_callback_barrier_completed": optional(
                    decision.witnessEndingCallbackBarrierCompleted
                ),
                "witness_start_accepted_callback_watermark": optional(
                    decision.witnessStartAcceptedCallbackWatermark
                ),
                "witness_end_accepted_callback_watermark": optional(
                    decision.witnessEndAcceptedCallbackWatermark
                ),
                "witness_accepted_callback_count": optional(decision.witnessAcceptedCallbackCount),
                "witness_accepted_event_count": optional(decision.witnessAcceptedEventCount),
                "witness_accepted_destination_event_count": optional(
                    decision.witnessAcceptedDestinationEventCount
                ),
                "witness_accepted_non_destination_event_count": optional(
                    decision.witnessAcceptedNonDestinationEventCount
                ),
                "witness_must_scan_sub_dirs": optional(decision.witnessMustScanSubDirs),
                "witness_root_changed": optional(decision.witnessRootChanged),
                "witness_user_dropped": optional(decision.witnessUserDropped),
                "witness_kernel_dropped": optional(decision.witnessKernelDropped),
                "witness_event_ids_wrapped": optional(decision.witnessEventIDsWrapped),
                "witness_event_id_regressed": optional(decision.witnessEventIDRegressed),
                "witness_lifetime_exceeded": optional(decision.witnessLifetimeExceeded),
                "witness_gap": optional(decision.witnessGap),
                "witness_drop": optional(decision.witnessDrop),
                "witness_overflow": optional(decision.witnessOverflow),
                "witness_proves_interval": optional(decision.witnessProvesInterval),
                "include_copy_requested": optional(decision.includeCopyRequested),
                "include_copy_result_present": optional(decision.includeCopyResultPresent),
                "include_copy_complete": optional(decision.includeCopyComplete),
                "include_copy_had_failures": optional(decision.includeCopyHadFailures),
                "target_layout_present": optional(decision.targetLayoutPresent),
                "target_layout_linked": optional(decision.targetLayoutLinked),
                "target_authority_capture": decision.targetAuthorityCapture.rawValue,
                "common_directory_match": decision.commonDirectoryMatch.rawValue,
                "repository_id_match": decision.repositoryIDMatch.rawValue,
                "repository_namespace_match": decision.repositoryNamespaceMatch.rawValue,
                "target_prefix_match": decision.targetPrefixMatch.rawValue,
                "target_tree_authority_match": decision.targetTreeAuthorityMatch.rawValue,
                "receipt_emitted": decision.receiptEmitted,
                "receipt_fallback_reason": optionalRawValue(decision.receiptFallbackReason),
                "initialization_fallback_reason": optionalRawValue(decision.initializationFallbackReason),
                "outcome": decision.outcome.rawValue
            ]
        }

        private static func receiptCoordinatorPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptCoordinatorDecision
        ) -> [String: Any] {
            [
                "create_result_receipt_count": decision.createResultReceiptCount,
                "hint_count": decision.hintCount,
                "binding_count": decision.bindingCount,
                "hint_keyed_by_created_binding": decision.hintKeyedByCreatedBinding.rawValue,
                "creation_fallback_observed": optionalRawValue(decision.creationFallbackObserved)
            ]
        }

        private static func receiptProjectionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptProjectionDecision
        ) -> [String: Any] {
            [
                "supplied_hint_count": decision.suppliedHintCount,
                "matched_hint_count": decision.matchedHintCount,
                "all_hint_keys_matched_bindings": optional(decision.allHintKeysMatchedBindings),
                "validation_fallback": optionalRawValue(decision.validationFallback)
            ]
        }

        private static func receiptConsumptionPayload(
            _ decision: WorktreeStartupInstrumentation.ReceiptConsumptionDecision
        ) -> [String: Any] {
            [
                "owner_generation_match": decision.ownerGenerationMatch.rawValue,
                "hint_session_match": decision.hintSessionMatch.rawValue,
                "hint_correlation_match": decision.hintCorrelationMatch.rawValue,
                "hint_owner_match": decision.hintOwnerMatch.rawValue,
                "ownership_reused": optional(decision.ownershipReused),
                "initial_hint_observation": receiptObservationPayload(decision.initialHintObservation),
                "pending_seeded_preparation_result": receiptObservationPayload(
                    decision.pendingSeededPreparationResult
                ),
                "full_crawl_performed": optional(decision.fullCrawlPerformed),
                "final_observation": receiptObservationPayload(decision.finalObservation),
                "selected_route": optionalRawValue(decision.selectedRoute)
            ]
        }

        private static func receiptObservationPayload(
            _ observation: WorktreeStartupInstrumentation.ReceiptFinalObservation?
        ) -> Any {
            guard let observation else { return NSNull() }
            switch observation {
            case .eligible:
                return ["state": "eligible"]
            case .disabled:
                return ["state": "disabled"]
            case let .fallback(reason):
                return ["state": "fallback", "fallback_reason": reason.rawValue]
            }
        }

        private static func optional(_ value: (some Any)?) -> Any {
            guard let value else { return NSNull() }
            return value
        }

        private static func optionalRawValue<T: RawRepresentable>(_ value: T?) -> Any where T.RawValue == String {
            guard let value else { return NSNull() }
            return value.rawValue
        }

        private static func gitPayload(
            _ git: [WorktreeStartupInstrumentation.GitCommandMetric],
            families: [String: Int],
            priorities: [String: Int]
        ) -> [String: Any] {
            [
                "available": true,
                "command_count": git.count,
                "families": families,
                "priorities": priorities,
                "queue_wait_us": git.reduce(0) { $0 + $1.queueWaitMicroseconds },
                "duration_us": git.reduce(0) { $0 + $1.durationMicroseconds },
                "output_bytes": git.reduce(0) { $0 + $1.outputByteCount },
                "cancelled_count": git.count(where: \.cancelled)
            ]
        }

        private static func workPayload(
            _ metrics: WorktreeStartupInstrumentation.BenchmarkMetricSnapshot?
        ) -> [String: Any] {
            guard let metrics else {
                return [
                    "filesystem": ["available": false],
                    "content_read_admission": ["available": false],
                    "codemap": ["available": false],
                    "planner": [:],
                    "mutation_lock": ["available": false],
                    "passive_tree": ["available": false],
                    "marker_publications": []
                ]
            }
            let codemapAvailable = metrics.codemapAttribution == .exact
            let planner = Dictionary(uniqueKeysWithValues: metrics.plannerPhases.map { phase, metric in
                (
                    phase.rawValue,
                    [
                        "count": metric.count,
                        "duration_us": metric.durationMicroseconds,
                        "item_count": metric.itemCount
                    ] as [String: Any]
                )
            })
            return [
                "filesystem": [
                    "available": metrics.filesystemOperationCount > 0,
                    "operation_count": metrics.filesystemOperationCount,
                    "duration_us": metrics.filesystemDurationMicroseconds,
                    "item_count": metrics.filesystemItemCount
                ],
                "content_read_admission": [
                    "available": metrics.contentReadGrantCount + metrics.contentReadOverloadCount > 0,
                    "grant_count": metrics.contentReadGrantCount,
                    "overload_count": metrics.contentReadOverloadCount,
                    "wait_us": metrics.contentReadWaitMicroseconds,
                    "execution_us": metrics.contentReadExecutionMicroseconds
                ],
                "codemap": [
                    "available": codemapAvailable,
                    "attribution": metrics.codemapAttribution.rawValue,
                    "request_count": metrics.codemapRequestCount,
                    "build_count": codemapAvailable ? metrics.codemapBuildCount as Any : NSNull(),
                    "queue_us": codemapAvailable ? metrics.codemapQueueMicroseconds as Any : NSNull(),
                    "permit_wait_us": codemapAvailable ? metrics.codemapPermitWaitMicroseconds as Any : NSNull()
                ],
                "planner": planner,
                "mutation_lock": [
                    "available": metrics.mutationLockCount > 0,
                    "count": metrics.mutationLockCount,
                    "queue_wait_us": metrics.mutationLockQueueMicroseconds,
                    "held_us": metrics.mutationLockHeldMicroseconds,
                    "mutation_us": metrics.mutationDurationMicroseconds,
                    "post_mutation_finalization_us": metrics.postMutationFinalizationMicroseconds
                ],
                "passive_tree": [
                    "available": metrics.passiveTreeCount > 0,
                    "operation_count": metrics.passiveTreeCount,
                    "duration_us": metrics.passiveTreeDurationMicroseconds
                ],
                "marker_publications": metrics.markerPublications.map {
                    [
                        "root_id": $0.rootID.uuidString,
                        "root_lifetime_id": $0.rootLifetimeID.uuidString,
                        "revision": $0.revision,
                        "effective_change_count": $0.effectiveChangeCount,
                        "source": $0.source.rawValue,
                        "timestamp_us": $0.timestampNanoseconds / 1000
                    ] as [String: Any]
                }
            ]
        }

        private static func deadline(now: UInt64, seconds: Int) -> UInt64 {
            let delta = UInt64(max(1, seconds)) * 1_000_000_000
            return now > UInt64.max - delta ? UInt64.max : now + delta
        }

        private static func isPath(_ path: String, inside container: String) -> Bool {
            path == container || path.hasPrefix(container.hasSuffix("/") ? container : container + "/")
        }

        private static let requiredBoundaryPhases: [WorktreeStartupPhase] = [
            .bindingTransitionStarted,
            .rootReady,
            .firstBenchmarkSearchStarted,
            .firstBenchmarkSearchCompleted,
            .firstBenchmarkReadStarted,
            .firstBenchmarkReadCompleted,
            .firstBenchmarkCodemapStarted,
            .firstBenchmarkCodemapCompleted,
            .warmBenchmarkCodemapStarted,
            .warmBenchmarkCodemapCompleted,
            .passiveBenchmarkTreeStarted,
            .passiveBenchmarkTreeCompleted,
            .benchmarkSelectionStarted,
            .benchmarkSelectionCompleted
        ]

        private struct BoundaryEvidence {
            let milestones: [String: Any]
            let valid: Bool
            let invalidReasons: [String]
        }

        private static func boundaryEvidence(
            _ events: [WorktreeStartupPhase: UInt64],
            baseline: UInt64
        ) -> BoundaryEvidence {
            var milestones: [String: Any] = [:]
            var invalidReasons: [String] = []
            for phase in Set(events.keys).union(requiredBoundaryPhases) {
                guard let timestamp = events[phase] else {
                    milestones[phase.rawValue] = NSNull()
                    invalidReasons.append("missing_\(phase.rawValue)")
                    continue
                }
                guard timestamp >= baseline else {
                    milestones[phase.rawValue] = NSNull()
                    invalidReasons.append("pre_baseline_\(phase.rawValue)")
                    continue
                }
                milestones[phase.rawValue] = (timestamp - baseline) / 1000
            }

            func requireOrder(_ before: WorktreeStartupPhase, _ after: WorktreeStartupPhase) {
                guard let beforeTime = events[before], let afterTime = events[after] else { return }
                if beforeTime > afterTime {
                    invalidReasons.append("non_monotonic_\(before.rawValue)_\(after.rawValue)")
                }
            }
            let requiredOrdering: [(WorktreeStartupPhase, WorktreeStartupPhase)] = [
                (WorktreeStartupPhase.bindingTransitionStarted, .rootReady),
                (.rootReady, .firstBenchmarkSearchStarted),
                (.rootReady, .firstBenchmarkReadStarted),
                (.firstBenchmarkSearchStarted, .firstBenchmarkSearchCompleted),
                (.firstBenchmarkReadStarted, .firstBenchmarkReadCompleted),
                (.firstBenchmarkSearchCompleted, .firstBenchmarkCodemapStarted),
                (.firstBenchmarkReadCompleted, .firstBenchmarkCodemapStarted),
                (.firstBenchmarkCodemapStarted, .firstBenchmarkCodemapCompleted),
                (.firstBenchmarkCodemapCompleted, .warmBenchmarkCodemapStarted),
                (.warmBenchmarkCodemapStarted, .warmBenchmarkCodemapCompleted),
                (.warmBenchmarkCodemapCompleted, .passiveBenchmarkTreeStarted),
                (.passiveBenchmarkTreeStarted, .passiveBenchmarkTreeCompleted),
                (.passiveBenchmarkTreeCompleted, .benchmarkSelectionStarted),
                (.benchmarkSelectionStarted, .benchmarkSelectionCompleted)
            ]
            for pair in requiredOrdering {
                requireOrder(pair.0, pair.1)
            }
            return BoundaryEvidence(
                milestones: milestones,
                valid: invalidReasons.isEmpty,
                invalidReasons: invalidReasons.sorted()
            )
        }

        static func boundaryEvidenceForTesting(
            _ events: [WorktreeStartupPhase: UInt64],
            baseline: UInt64
        ) -> (milestones: [String: Any], valid: Bool, invalidReasons: [String]) {
            let evidence = boundaryEvidence(events, baseline: baseline)
            return (evidence.milestones, evidence.valid, evidence.invalidReasons)
        }

        static var requiredBoundaryPhasesForTesting: [WorktreeStartupPhase] {
            requiredBoundaryPhases
        }

        private static func durationPayload(_ events: [WorktreeStartupPhase: UInt64]) -> [String: UInt64] {
            var values: [String: UInt64] = [:]
            func add(_ name: String, _ start: WorktreeStartupPhase, _ end: WorktreeStartupPhase) {
                guard let startTime = events[start], let endTime = events[end], endTime >= startTime else { return }
                values[name] = (endTime - startTime) / 1000
            }
            add("materialize_to_root_ready", .bindingTransitionStarted, .rootReady)
            add("materialize_to_provider_start", .bindingTransitionStarted, .providerStart)
            add("materialize_to_first_search", .bindingTransitionStarted, .firstBenchmarkSearchCompleted)
            add("materialize_to_first_read", .bindingTransitionStarted, .firstBenchmarkReadCompleted)
            add("root_ready_to_first_search", .rootReady, .firstBenchmarkSearchCompleted)
            add("first_search", .firstBenchmarkSearchStarted, .firstBenchmarkSearchCompleted)
            add("first_read", .firstBenchmarkReadStarted, .firstBenchmarkReadCompleted)
            add("materialize_to_first_codemap", .bindingTransitionStarted, .firstBenchmarkCodemapCompleted)
            add("first_codemap", .firstBenchmarkCodemapStarted, .firstBenchmarkCodemapCompleted)
            add("warm_codemap", .warmBenchmarkCodemapStarted, .warmBenchmarkCodemapCompleted)
            add("passive_tree", .passiveBenchmarkTreeStarted, .passiveBenchmarkTreeCompleted)
            add("selection", .benchmarkSelectionStarted, .benchmarkSelectionCompleted)
            add("seed_watcher_attach_to_replay_fence", .seedWatcherAttached, .seedReplayFenced)
            add("seed_replay_fence_to_ready", .seedReplayFenced, .seedReadyForCommit)
            add("seed_ready_to_publish", .seedReadyForCommit, .seedPublished)
            return values
        }

        private static func interactiveReadinessMicroseconds(
            _ events: [WorktreeStartupPhase: UInt64]
        ) -> UInt64? {
            guard let start = events[.bindingTransitionStarted],
                  let search = events[.firstBenchmarkSearchCompleted],
                  let read = events[.firstBenchmarkReadCompleted]
            else { return nil }
            let completed = max(search, read)
            guard completed >= start else { return nil }
            return (completed - start) / 1000
        }
    }

    private extension GitWorkspaceAuthorityUnavailableReason {
        var benchmarkDiagnosticCode: String {
            switch self {
            case .noSnapshot: "no_snapshot"
            case .mutationInProgress: "mutation_in_progress"
            case .metadataEventPending: "metadata_event_pending"
            case .monitorCoverageUnavailable: "monitor_coverage_unavailable"
            case .superseded: "superseded"
            case .invalidatedDuringCollection: "invalidated_during_collection"
            case .collectionScopeMismatch: "collection_scope_mismatch"
            }
        }
    }
#endif
