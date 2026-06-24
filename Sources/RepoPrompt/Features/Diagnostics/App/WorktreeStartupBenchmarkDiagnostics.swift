#if DEBUG
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
        case startIdentityMismatch

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
            case .startIdentityMismatch: "start_identity_mismatch"
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
        static let requiredWorkspaceNamePrefix = "RPCE 8E Bench "
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
            var agentSessionID: UUID?
            var startAttemptID: UUID?
            var metricTag: WorktreeStartupInstrumentation.BenchmarkMetricTag?

            var scope: DebugWorktreeStartupBenchmarkScope {
                expectedStart.rootIdentity.scope
            }
        }

        private let lock = NSLock()
        private var currentControlIDByScope: [DebugWorktreeStartupBenchmarkScope: UUID] = [:]
        private var controlsByID: [UUID: ControlLease] = [:]
        private var tokensByID: [UUID: TokenLease] = [:]
        private var samplesByCorrelationID: [UUID: SampleState] = [:]

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
            expiresSeconds: Int
        ) throws -> ControlResult {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                let expires = Self.deadline(now: now, seconds: expiresSeconds)
                let route = RouteControl(observe: observe, serve: serve, forceFullCrawl: forceFullCrawl)
                lock.lock()
                purgeExpiredLocked(now: now)
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

        func mark(
            scope: DebugWorktreeStartupBenchmarkScope,
            correlationID: UUID,
            phase: WorktreeStartupPhase
        ) throws {
            try WorktreeStartupBenchmarkGate.shared.requireEnabled { _ in
                let context: WorktreeStartupContext
                lock.lock()
                let sample = samplesByCorrelationID[correlationID]
                let instrumentation = WorktreeStartupInstrumentation.snapshot()
                guard let sample, sample.scope == scope, let sessionID = sample.agentSessionID else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.sampleNotFound
                }
                let phases = Set(
                    instrumentation.events.lazy
                        .filter { $0.correlationID == correlationID }
                        .map(\.phase)
                )
                let valid = switch phase {
                case .firstBenchmarkSearchStarted:
                    !phases.contains(.firstBenchmarkSearchStarted)
                case .firstBenchmarkSearchCompleted:
                    phases.contains(.firstBenchmarkSearchStarted) && !phases.contains(.firstBenchmarkSearchCompleted)
                case .firstBenchmarkReadStarted:
                    phases.contains(.firstBenchmarkSearchCompleted) && !phases.contains(.firstBenchmarkReadStarted)
                case .firstBenchmarkReadCompleted:
                    phases.contains(.firstBenchmarkReadStarted) && !phases.contains(.firstBenchmarkReadCompleted)
                default:
                    false
                }
                guard valid else {
                    lock.unlock()
                    throw DebugWorktreeStartupBenchmarkError.invalidTransition
                }
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
                let metrics = sample.metricTag.map(WorktreeStartupInstrumentation.benchmarkMetricSnapshot)
                let git = metrics?.gitCommands ?? []
                let gitFamilies = Dictionary(grouping: git, by: { $0.family.rawValue }).mapValues(\.count)
                let gitPriorities = Dictionary(grouping: git, by: { String(describing: $0.priority) }).mapValues(\.count)

                var payload: [String: Any] = [
                    "ok": true,
                    "schema_version": 2,
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
                        "root_ready": eventTimes[.rootReady] != nil,
                        "first_search_complete": eventTimes[.firstBenchmarkSearchCompleted] != nil,
                        "first_read_complete": eventTimes[.firstBenchmarkReadCompleted] != nil,
                        "route_counts": routeCounts,
                        "fallback_counts": fallbackCounts,
                        "milestones_us": Self.milestonePayload(eventTimes, baseline: sample.armedAtNanoseconds),
                        "durations_us": Self.durationPayload(eventTimes),
                        "event_buffer_evicted": eventEvicted,
                        "valid": !eventEvicted && sample.metricTag != nil
                    ],
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
                controlIDs.forEach { controlsByID.removeValue(forKey: $0) }
                tokenIDs.forEach { tokensByID.removeValue(forKey: $0) }
                for sample in samples {
                    samplesByCorrelationID.removeValue(forKey: sample.correlationID)
                    WorktreeStartupInstrumentation.resetBenchmarkMetrics(correlationID: sample.correlationID)
                }
                currentControlIDByScope.removeValue(forKey: scope)
                return [
                    "control_count": controlIDs.count,
                    "token_count": tokenIDs.count,
                    "sample_count": samples.count
                ]
            }
        }

        func revokeAll() {
            lock.lock()
            currentControlIDByScope.removeAll(keepingCapacity: true)
            controlsByID.removeAll(keepingCapacity: true)
            tokensByID.removeAll(keepingCapacity: true)
            samplesByCorrelationID.removeAll(keepingCapacity: true)
            lock.unlock()
            WorktreeStartupInstrumentation.resetBenchmarkMetrics()
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
                    "codemap": ["available": false]
                ]
            }
            let codemapAvailable = metrics.codemapAttribution == .exact
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
                ]
            ]
        }

        private static func deadline(now: UInt64, seconds: Int) -> UInt64 {
            let delta = UInt64(max(1, seconds)) * 1_000_000_000
            return now > UInt64.max - delta ? UInt64.max : now + delta
        }

        private static func isPath(_ path: String, inside container: String) -> Bool {
            path == container || path.hasPrefix(container.hasSuffix("/") ? container : container + "/")
        }

        private static func milestonePayload(
            _ events: [WorktreeStartupPhase: UInt64],
            baseline: UInt64
        ) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: events.map { phase, timestamp in
                (phase.rawValue, timestamp >= baseline ? (timestamp - baseline) / 1000 : 0)
            })
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
            return values
        }
    }
#endif
