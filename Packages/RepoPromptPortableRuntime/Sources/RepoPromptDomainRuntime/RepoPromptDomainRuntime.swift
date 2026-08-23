import Foundation
import Logging
import MCP

public enum DomainRuntimeMode: String, CaseIterable, Sendable {
    case app
    case standalone
}

public struct DomainRuntimeConfiguration: Sendable {
    public let mode: DomainRuntimeMode
    public let profileIdentifier: String
    public let storageDirectory: URL
    public let workspaceStorageDirectory: URL
    public let eventDirectory: URL
    public let temporaryDirectory: URL
    public let legacyRuntimeDefaults: [String: Data]
    public let externalReloadInterval: Duration?
    public let externalReloadMaximumInterval: Duration
    public let metrics: DomainRuntimeMetricsSink
    public let hostDrainTimeout: Duration

    public init(
        mode: DomainRuntimeMode,
        profileIdentifier: String,
        storageDirectory: URL,
        workspaceStorageDirectory: URL? = nil,
        eventDirectory: URL,
        temporaryDirectory: URL,
        legacyRuntimeDefaults: [String: Data] = [:],
        externalReloadInterval: Duration? = .seconds(1),
        externalReloadMaximumInterval: Duration = .seconds(30),
        metrics: DomainRuntimeMetricsSink = .disabled,
        hostDrainTimeout: Duration = .seconds(5)
    ) {
        self.mode = mode
        self.profileIdentifier = profileIdentifier
        self.storageDirectory = storageDirectory
        self.workspaceStorageDirectory = workspaceStorageDirectory
            ?? storageDirectory.appendingPathComponent("Workspaces", isDirectory: true)
        self.eventDirectory = eventDirectory
        self.temporaryDirectory = temporaryDirectory
        self.legacyRuntimeDefaults = legacyRuntimeDefaults
        self.externalReloadInterval = externalReloadInterval
        self.externalReloadMaximumInterval = externalReloadMaximumInterval
        self.metrics = metrics
        self.hostDrainTimeout = hostDrainTimeout
    }
}

public struct DomainRuntimeIdentity: Hashable, Sendable {
    public let runtimeID: UUID
    public let lifecycleGeneration: UInt64
    public let processID: Int32
    public let mode: DomainRuntimeMode
    public let createdAt: Date

    public init(
        runtimeID: UUID,
        lifecycleGeneration: UInt64,
        processID: Int32,
        mode: DomainRuntimeMode,
        createdAt: Date
    ) {
        self.runtimeID = runtimeID
        self.lifecycleGeneration = lifecycleGeneration
        self.processID = processID
        self.mode = mode
        self.createdAt = createdAt
    }
}

public enum DomainRuntimeLifecycle: String, CaseIterable, Sendable {
    case created
    case starting
    case ready
    case draining
    case stopped
    case degraded
}

public struct DomainRuntimeSnapshot: Sendable {
    public let identity: DomainRuntimeIdentity
    public let lifecycle: DomainRuntimeLifecycle
    public let publicationSequence: UInt64
    public let catalogRevision: UInt64
    public let workspacePublicationSequence: UInt64
    public let workspaceCatalogRevision: UInt64
    public let workspaceHealth: DomainAuthorityHealth
    public let routingRevision: UInt64
    public let agentSessionPersistenceHealth: DomainAgentSessionPersistenceHealth
    public let activityPublicationSequence: UInt64
    public let activeActivityCount: Int
    public let recentTerminalActivityCount: Int
    public let hostLifecycle: MCPDomainHostLifecycle
    public let activeHostInvocationCount: Int
}

public struct DomainShutdownResult: Sendable {
    public let identity: DomainRuntimeIdentity
    public let previousLifecycle: DomainRuntimeLifecycle
    public let finalLifecycle: DomainRuntimeLifecycle
}

public enum DomainRuntimeLifecycleError: Error, Equatable, Sendable {
    case stoppedRuntimeCannotRestart
}

public actor MCPDomainRuntime {
    public nonisolated let identity: DomainRuntimeIdentity
    public nonisolated let configuration: DomainRuntimeConfiguration
    public nonisolated let toolRegistry: MCPDomainToolRegistry
    public nonisolated let domainHost: MCPDomainHost
    public nonisolated let persistenceCoordinator: DomainPersistenceCoordinator
    public nonisolated let workspaceStore: DomainWorkspaceStore
    public nonisolated let contextStore: DomainContextStore
    public nonisolated let routingCoordinator: DomainRoutingCoordinator
    public nonisolated let standaloneScopeCoordinator: DomainStandaloneScopeCoordinator
    public nonisolated let readSideEffectCoordinator: DomainReadSideEffectCoordinator
    public nonisolated let mutationPolicyStore: DomainMutationPolicyStore
    public nonisolated let mutationApprovalBroker: DomainMutationApprovalBroker
    public nonisolated let mutationJournal: DomainMutationJournal
    public nonisolated let protectedMutationProvider: MCPDomainProtectedMutationToolProvider
    public nonisolated let agentSessionStore: DomainAgentRunSessionStore
    public nonisolated let agentWorktreeBindingStore: DomainAgentWorktreeBindingStore
    public nonisolated let interactionBroker: DomainInteractionBroker
    public nonisolated let activityCenter: DomainActivityCenter
    public nonisolated let credentialEnvelopeStore: DomainCredentialEnvelopeStore
    public nonisolated let longRunningToolProvider: MCPDomainLongRunningToolProvider

    private let workspaceAuthority: DomainWorkspaceContextAuthority
    private var lifecycle: DomainRuntimeLifecycle = .created
    private var publicationSequence: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var externalReloadTask: Task<Void, Never>?

    public init(
        configuration: DomainRuntimeConfiguration,
        runtimeID: UUID = UUID(),
        lifecycleGeneration: UInt64 = 1,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        createdAt: Date = Date(),
        registryID: UUID = UUID(),
        prepareChildLaunch: @escaping MCPDomainLongRunningToolProvider.PrepareChildLaunch = { _, _, _ in nil }
    ) {
        self.configuration = configuration
        let runtimeIdentity = DomainRuntimeIdentity(
            runtimeID: runtimeID,
            lifecycleGeneration: lifecycleGeneration,
            processID: processID,
            mode: configuration.mode,
            createdAt: createdAt
        )
        identity = runtimeIdentity
        toolRegistry = MCPDomainToolRegistry(registryID: registryID)

        let persistence = DomainPersistenceCoordinator(
            configuration: configuration,
            identity: runtimeIdentity
        )
        persistenceCoordinator = persistence
        let authority = DomainWorkspaceContextAuthority(
            identity: runtimeIdentity,
            persistence: persistence,
            metrics: configuration.metrics
        )
        workspaceAuthority = authority
        let workspaceStore = DomainWorkspaceStore(authority: authority)
        let contextStore = DomainContextStore(authority: authority)
        self.workspaceStore = workspaceStore
        self.contextStore = contextStore
        let routingCoordinator = DomainRoutingCoordinator(
            identity: runtimeIdentity,
            contextStore: contextStore,
            metrics: configuration.metrics
        )
        self.routingCoordinator = routingCoordinator
        standaloneScopeCoordinator = DomainStandaloneScopeCoordinator(
            identity: runtimeIdentity,
            workspaceStore: workspaceStore,
            contextStore: contextStore,
            routingCoordinator: routingCoordinator
        )
        domainHost = MCPDomainHost(
            identity: runtimeIdentity,
            registry: toolRegistry,
            routingCoordinator: routingCoordinator,
            metrics: configuration.metrics
        )
        readSideEffectCoordinator = DomainReadSideEffectCoordinator(identity: runtimeIdentity)
        let mutationPolicyStore = DomainMutationPolicyStore(
            persistence: persistence,
            identity: runtimeIdentity,
            profileIdentifier: configuration.profileIdentifier
        )
        self.mutationPolicyStore = mutationPolicyStore
        mutationApprovalBroker = DomainMutationApprovalBroker()
        let mutationJournal = DomainMutationJournal(
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier,
            createdAt: createdAt
        )
        self.mutationJournal = mutationJournal
        protectedMutationProvider = MCPDomainProtectedMutationToolProvider(
            policyStore: mutationPolicyStore,
            journal: mutationJournal
        )
        agentSessionStore = DomainAgentRunSessionStore(
            identity: runtimeIdentity,
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier
        )
        agentWorktreeBindingStore = DomainAgentWorktreeBindingStore(
            persistence: persistence,
            profileIdentifier: configuration.profileIdentifier
        )
        let interactionBroker = DomainInteractionBroker()
        let activityCenter = DomainActivityCenter(identity: runtimeIdentity)
        let credentialEnvelopeStore = DomainCredentialEnvelopeStore(identity: runtimeIdentity)
        self.interactionBroker = interactionBroker
        self.activityCenter = activityCenter
        self.credentialEnvelopeStore = credentialEnvelopeStore
        longRunningToolProvider = MCPDomainLongRunningToolProvider(
            identity: runtimeIdentity,
            policyStore: mutationPolicyStore,
            interactionBroker: interactionBroker,
            activityCenter: activityCenter,
            prepareChildLaunch: prepareChildLaunch
        )
    }

    public func start() async throws {
        switch lifecycle {
        case .created:
            lifecycle = .starting
            publishSnapshot()
            let authority = workspaceAuthority
            startTask = Task { await authority.bootstrap() }
        case .starting:
            break
        case .ready, .degraded:
            return
        case .draining, .stopped:
            throw DomainRuntimeLifecycleError.stoppedRuntimeCannotRestart
        }
        await startTask?.value
        await mutationPolicyStore.bootstrap()
        await agentSessionStore.bootstrap()
        await agentWorktreeBindingStore.bootstrap()
        guard lifecycle == .starting else { return }
        startTask = nil
        let workspaceSnapshot = await workspaceAuthority.snapshot()
        let agentSessions = await agentSessionStore.snapshot()
        lifecycle = workspaceSnapshot.health.acceptsMutations && agentSessions.persistenceHealth == .ready
            ? .ready
            : .degraded
        publishSnapshot()
        startExternalReloadPollingIfNeeded()
    }

    public func shutdown() async -> DomainShutdownResult {
        let previousLifecycle = lifecycle
        guard lifecycle != .stopped else {
            return DomainShutdownResult(
                identity: identity,
                previousLifecycle: previousLifecycle,
                finalLifecycle: .stopped
            )
        }
        lifecycle = .draining
        startTask?.cancel()
        startTask = nil
        publishSnapshot()
        externalReloadTask?.cancel()
        externalReloadTask = nil
        _ = await domainHost.drain(timeout: configuration.hostDrainTimeout)
        await mutationApprovalBroker.shutdown()
        await interactionBroker.shutdown()
        _ = await agentSessionStore.shutdown()
        await activityCenter.shutdown()
        await credentialEnvelopeStore.shutdown()
        await readSideEffectCoordinator.shutdown()
        await routingCoordinator.shutdown()
        lifecycle = .stopped
        publishSnapshot()
        return DomainShutdownResult(
            identity: identity,
            previousLifecycle: previousLifecycle,
            finalLifecycle: .stopped
        )
    }

    public func snapshot() async -> DomainRuntimeSnapshot {
        let catalog = await toolRegistry.snapshot()
        let workspaces = await workspaceAuthority.snapshot()
        let routing = await routingCoordinator.snapshot()
        let agentSessions = await agentSessionStore.snapshot()
        let activities = await activityCenter.snapshot()
        let host = await domainHost.snapshot()
        return DomainRuntimeSnapshot(
            identity: identity,
            lifecycle: lifecycle,
            publicationSequence: publicationSequence,
            catalogRevision: catalog.revision,
            workspacePublicationSequence: workspaces.publicationSequence,
            workspaceCatalogRevision: workspaces.catalogRevision,
            workspaceHealth: workspaces.health,
            routingRevision: routing.revision,
            agentSessionPersistenceHealth: agentSessions.persistenceHealth,
            activityPublicationSequence: activities.publicationSequence,
            activeActivityCount: activities.active.count,
            recentTerminalActivityCount: activities.recentTerminal.count,
            hostLifecycle: host.lifecycle,
            activeHostInvocationCount: host.activeInvocationCount
        )
    }

    private func startExternalReloadPollingIfNeeded() {
        guard externalReloadTask == nil,
              let minimumInterval = configuration.externalReloadInterval
        else { return }
        let maximumInterval = max(
            minimumInterval,
            configuration.externalReloadMaximumInterval
        )
        externalReloadTask = Task { [weak self] in
            var interval = minimumInterval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                let activity = await workspaceStore.reloadExternalChanges()
                await synchronizeLifecycleWithWorkspaceHealth()
                interval = switch activity {
                case .changed:
                    minimumInterval
                case .unchanged, .recoveryPending:
                    min(interval * 2, maximumInterval)
                }
            }
        }
    }

    private func synchronizeLifecycleWithWorkspaceHealth() async {
        guard lifecycle == .ready || lifecycle == .degraded else { return }
        let snapshot = await workspaceAuthority.snapshot()
        let next: DomainRuntimeLifecycle = snapshot.health.acceptsMutations ? .ready : .degraded
        guard next != lifecycle else { return }
        lifecycle = next
        publishSnapshot()
    }

    private func publishSnapshot() {
        publicationSequence &+= 1
    }
}
