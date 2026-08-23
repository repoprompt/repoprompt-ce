import Foundation
import RepoPromptAuthorityAPI
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct ReadinessCheck: Codable, Hashable, Sendable {
    public let name: String
    public let ready: Bool
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case name, ready, detail
    }
}

public struct ProviderReadiness: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let required: Bool
    public let ready: Bool
    public let version: String?
    public let protocolVersion: String?
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case kind, required, ready, version, protocolVersion, detail
    }
}

public struct RepoPromptReadinessSnapshot: Codable, Sendable {
    public let ready: Bool
    public let checks: [ReadinessCheck]
    public let providers: [ProviderReadiness]
    public let degradedProjectIDs: [UUID]
    public let activeSessionCount: Int
    public let maximumActiveSessions: Int
    public let operational: StoreOperationalSnapshot?
    public let drain: AuthorityMutationGateSnapshot
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case ready, checks, providers
        case degradedProjectIDs = "degradedProjectIds"
        case activeSessionCount, maximumActiveSessions, operational, drain, observedAt
    }
}

public actor RepoPromptReadinessService {
    public struct Volume: Hashable, Sendable {
        public let name: String
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    private let authority: RepoPromptHeadlessAuthority
    private let store: SQLiteServiceStore
    private let volumes: [Volume]
    private let requiredProviders: Set<ProviderKind>
    private let expectedProviderProtocols: [ProviderKind: String]
    private let minimumFreeBytes: Int64
    private let minimumFreeNodes: Int64
    private let maximumActiveSessions: Int
    private let cacheDuration: TimeInterval
    private let mutationGate: AuthorityMutationGate
    private let trustConfigurationValid: Bool
    private let providerSettings: ProviderSettingsService?
    private let eventOutboxDispatcher: OrderedEventOutboxDispatcher?
    private var cached: RepoPromptReadinessSnapshot?

    public init(
        authority: RepoPromptHeadlessAuthority,
        store: SQLiteServiceStore,
        volumes: [Volume] = [],
        requiredProviders: Set<ProviderKind> = [],
        expectedProviderProtocols: [ProviderKind: String] = [:],
        minimumFreeBytes: Int64 = 268_435_456,
        minimumFreeNodes: Int64 = 1024,
        maximumActiveSessions: Int = 64,
        cacheDuration: TimeInterval = 15,
        mutationGate: AuthorityMutationGate = AuthorityMutationGate(),
        trustConfigurationValid: Bool = true,
        providerSettings: ProviderSettingsService? = nil,
        eventOutboxDispatcher: OrderedEventOutboxDispatcher? = nil
    ) {
        self.authority = authority
        self.store = store
        self.volumes = volumes
        self.requiredProviders = requiredProviders
        self.expectedProviderProtocols = expectedProviderProtocols
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumFreeNodes = minimumFreeNodes
        self.maximumActiveSessions = maximumActiveSessions
        self.cacheDuration = cacheDuration
        self.mutationGate = mutationGate
        self.trustConfigurationValid = trustConfigurationValid
        self.providerSettings = providerSettings
        self.eventOutboxDispatcher = eventOutboxDispatcher
    }

    public func snapshot(forceRefresh: Bool = false) async -> RepoPromptReadinessSnapshot {
        let drain = await mutationGate.snapshot()
        if drain.acceptingMutations,
           !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.observedAt) < cacheDuration
        {
            return cached
        }

        var checks = [ReadinessCheck]()
        var operational: StoreOperationalSnapshot?
        do {
            try await authority.reconcileActionableTransitions()
            let snapshot = try await store.operationalSnapshot()
            operational = snapshot
            checks.append(.init(name: "sqlite-integrity", ready: snapshot.integrityValid, detail: snapshot.integrityValid ? "ok" : "failed"))
            checks.append(.init(name: "migrations", ready: snapshot.migrationsValid, detail: snapshot.migrationsValid ? "schema-v9" : "mismatch"))
            checks.append(.init(name: "activation", ready: snapshot.activationState == "active", detail: snapshot.activationState))
            // Startup reconstruction is completed by authority.recover() before this
            // service exists. Families observed here are verified live work, not an
            // unreconciled startup condition, and remain visible in metrics.
            checks.append(.init(name: "supervisor-recovery", ready: true, detail: "active-families=\(snapshot.activeProcessFamilyCount)"))
            checks.append(.init(name: "owned-resources", ready: snapshot.ownedResources.ready, detail: snapshot.ownedResources.ready ? "reconciled" : "degraded"))
            let transitions = try await store.nonfinalAuthorityTransitions()
            checks.append(.init(
                name: "authority-transitions",
                ready: transitions.isEmpty,
                detail: transitions.isEmpty
                    ? "reconciled"
                    : "blocking=\(transitions.count),actionable=\(transitions.count(where: { $0.state == .reconciliationRequired }))"
            ))
        } catch {
            checks.append(.init(name: "sqlite-integrity", ready: false, detail: "unavailable"))
            checks.append(.init(name: "migrations", ready: false, detail: "unavailable"))
            checks.append(.init(name: "activation", ready: false, detail: "unavailable"))
            checks.append(.init(name: "supervisor-recovery", ready: false, detail: "unavailable"))
            checks.append(.init(name: "owned-resources", ready: false, detail: "unavailable"))
            checks.append(.init(name: "authority-transitions", ready: false, detail: "unavailable"))
        }

        if let eventOutboxDispatcher {
            let dispatcher = await eventOutboxDispatcher.snapshot()
            let dispatcherReady = dispatcher.running && dispatcher.consecutiveFailures == 0
            checks.append(.init(
                name: "event-outbox-dispatcher",
                ready: dispatcherReady,
                detail: dispatcherReady
                    ? "pending=\(dispatcher.pendingCount)"
                    : "pending=\(dispatcher.pendingCount),failures=\(dispatcher.consecutiveFailures),diagnostic=\(dispatcher.lastDiagnosticCode ?? "none")"
            ))
        }

        checks.append(.init(name: "trust", ready: trustConfigurationValid, detail: trustConfigurationValid ? "validated" : "invalid"))
        let authorityReady = await authority.isReady()
        let accepting = drain.acceptingMutations && authorityReady
        checks.append(.init(name: "quiesce", ready: accepting, detail: accepting ? "accepting" : "draining"))
        for volume in volumes {
            checks.append(volumeCheck(volume))
        }

        // Provider rows are optional settings and never participate in core
        // readiness. Provider status is served by the settings catalog.
        let completeProviders: [ProviderReadiness] = []

        let sessions: [SessionSnapshot]
        do {
            sessions = try await authority.sessionSnapshots()
        } catch {
            sessions = []
            checks.append(.init(name: "session-authority", ready: false, detail: "persistence-unavailable"))
        }
        let activeStates: Set<SessionLifecycleState> = [.preparing, .running, .waiting]
        let activeSessionCount = sessions.count(where: { activeStates.contains($0.state) })
        let activeRootCount = sessions.count(where: { $0.parentSessionID == nil && activeStates.contains($0.state) })
        // Nested children share the parent's admission slot. Capacity is telemetry,
        // not process liveness: Docker /health/ready must stay true while nested
        // agents run, matching Desktop remaining usable with open subagent tabs.
        let capacityReady = activeRootCount < maximumActiveSessions
        checks.append(.init(name: "session-capacity", ready: capacityReady, detail: "\(activeRootCount)/\(maximumActiveSessions)"))
        let projects = await authority.projectSnapshots()
        let degraded = projects.filter { $0.state == .degraded }.map(\.projectID).sorted { $0.uuidString < $1.uuidString }
        let ready = checks.filter { $0.name != "session-capacity" }.allSatisfy(\.ready)
        let result = RepoPromptReadinessSnapshot(
            ready: ready,
            checks: checks,
            providers: completeProviders,
            degradedProjectIDs: degraded,
            activeSessionCount: activeSessionCount,
            maximumActiveSessions: maximumActiveSessions,
            operational: operational,
            drain: drain,
            observedAt: Date()
        )
        cached = result
        if ready {
            // Startup provider recovery begins only after core readiness has
            // succeeded. Scheduling is non-blocking and never changes readiness.
            await providerSettings?.startConnectedProviderRecovery()
        }
        return result
    }

    private func volumeCheck(_ volume: Volume) -> ReadinessCheck {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: volume.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(name: "volume:\(volume.name)", ready: false, detail: "missing")
        }
        let probe = URL(fileURLWithPath: volume.path, isDirectory: true).appendingPathComponent(".repoprompt-readiness-\(UUID().uuidString)")
        do {
            try Data("ready".utf8).write(to: probe, options: [.atomic])
            try manager.removeItem(at: probe)
            let attributes = try manager.attributesOfFileSystem(forPath: volume.path)
            let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let freeNodes = (attributes[.systemFreeNodes] as? NSNumber)?.int64Value ?? minimumFreeNodes
            let ready = freeBytes >= minimumFreeBytes && freeNodes >= minimumFreeNodes
            return .init(name: "volume:\(volume.name)", ready: ready, detail: ready ? "writable" : "capacity-low")
        } catch {
            return .init(name: "volume:\(volume.name)", ready: false, detail: "not-writable")
        }
    }
}

public struct RepoPromptDiagnostics: Codable {
    public let storeID: UUID
    public let schemaVersion: Int
    public let nextGlobalSequence: Int64
    public let replayFloor: Int64
    public let readiness: RepoPromptReadinessSnapshot
    public let operational: StoreOperationalSnapshot?
    public let drain: AuthorityMutationGateSnapshot
    public let maintenance: DurabilityMaintenanceSnapshot?

    public init(
        storeID: UUID,
        schemaVersion: Int,
        nextGlobalSequence: Int64,
        replayFloor: Int64,
        readiness: RepoPromptReadinessSnapshot,
        operational: StoreOperationalSnapshot?,
        drain: AuthorityMutationGateSnapshot,
        maintenance: DurabilityMaintenanceSnapshot?
    ) {
        self.storeID = storeID
        self.schemaVersion = schemaVersion
        self.nextGlobalSequence = nextGlobalSequence
        self.replayFloor = replayFloor
        self.readiness = readiness
        self.operational = operational
        self.drain = drain
        self.maintenance = maintenance
    }

    private enum CodingKeys: String, CodingKey {
        case storeID = "storeId"
        case schemaVersion, nextGlobalSequence, replayFloor, readiness, operational, drain, maintenance
    }
}
