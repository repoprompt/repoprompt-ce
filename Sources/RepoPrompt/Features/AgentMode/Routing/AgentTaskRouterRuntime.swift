import Combine
import Foundation
import RepoPromptSecureStorage
import RepoPromptSettingsCore

/// App-global composition owner for bundled router adapters and their credential/readiness state.
final class AgentTaskRouterRuntime: ObservableObject {
    let registry: DecisionServiceRegistry
    let serviceDisplayNamesByID: [DecisionServiceID: String]
    let coordinator: DecisionCoordinator
    let defaultBackendID: DecisionServiceID?
    let objectWillChange = ObservableObjectPublisher()
    @MainActor var usageBalancer: AgentUsageBalancer?

    private let readinessLock = NSLock()
    private var readinessByBackendID: [DecisionServiceID: DecisionReadiness] = [:]
    private let activation: AgentTaskRouterActivation
    private var activationTask: Task<Void, Never>?

    init(
        registrations: [DecisionServiceRegistration],
        demandSource: (any AgentTaskRouterDemandSource)? = nil,
        defaultBackendID: DecisionServiceID? = nil
    ) throws {
        let registry = try DecisionServiceRegistry(registrations: registrations)
        self.registry = registry
        serviceDisplayNamesByID = Dictionary(uniqueKeysWithValues: registrations.map { ($0.id, $0.displayName) })
        self.defaultBackendID = defaultBackendID
        let coordinator = DecisionCoordinator(registry: registry)
        self.coordinator = coordinator
        activation = AgentTaskRouterActivation(registry: registry, coordinator: coordinator, source: demandSource)
        activationTask = Task { [activation] in
            await activation.start { [weak self] readiness, id in
                self?.publishReadiness(readiness, backendID: id)
            }
        }
    }

    @MainActor
    convenience init(
        secureKeys: SecureKeysService = SecureKeysService(),
        jevClient: any JevRoutingClientProtocol = JevRoutingClient(),
        settingsStore: GlobalSettingsStore? = nil,
        decisionsClient: OpenAIDecisionsRoutingClient = OpenAIDecisionsRoutingClient()
    ) {
        let settingsStore = settingsStore ?? .shared
        let jev = JevRouterCredentialService(secureKeys: secureKeys, client: jevClient)
        let decisions = OpenAIDecisionsRouterCredentialService(secureKeys: secureKeys, decide: { request, key in
            try await decisionsClient.decide(request, apiKey: key)
        })
        settingsStore.materializeModelRouterDefaultIfAbsent(.jev)
        do {
            try self.init(registrations: [
                .init(
                    service: JevDecisionService(credentialService: jev),
                    configuration: JevDecisionService.settingsRegistration(controller: jev),
                    displayOrder: 100
                ),
                .init(
                    service: OpenAIDecisionsDecisionService(credentialService: decisions),
                    configuration: OpenAIDecisionsDecisionService.settingsRegistration(controller: decisions),
                    displayOrder: 200
                )
            ], demandSource: settingsStore, defaultBackendID: .jev)
        } catch {
            preconditionFailure("Invalid bundled model-router registry: \(error)")
        }
    }

    deinit {
        activationTask?.cancel()
        Task { [activation] in await activation.stop() }
    }

    /// Explicit lifetime boundary, including owned streams and bootstrap work.
    func teardown() async {
        activationTask?.cancel()
        await activation.stop()
        await coordinator.cancelAll()
    }

    /// Wait for current demand admission and task-free bootstrap completion.
    func reconcileDemand(waitForBootstrap: Bool = true) async {
        await activation.reconcileAndWait(waitForBootstrap: waitForBootstrap)
    }

    func isBackendReady(_ id: DecisionServiceID) -> Bool {
        backendReadiness(id)?.isReady == true
    }

    func backendReadiness(_ id: DecisionServiceID) -> DecisionReadiness? {
        readinessLock.lock()
        defer { readinessLock.unlock() }
        return readinessByBackendID[id]
    }

    /// Passive, keyed readiness projection for Settings and other observers.
    var decisionServiceReadinessByID: [DecisionServiceID: DecisionReadiness] {
        readinessLock.lock()
        defer { readinessLock.unlock() }
        return readinessByBackendID
    }

    /// Wait only for initial observation, without admitting or bootstrapping demand.
    func waitForReadinessObservation() async {
        await activation.waitUntilInitialized()
    }

    func cancelAll() {
        Task {
            await coordinator.cancelAll()
            for registration in await registry.registrations() {
                await registration.configuration?.controller.cancelAndAdvanceGeneration()
            }
        }
    }

    func cancelRoutingRequests() {
        Task { await coordinator.cancelAll(consumerID: .modelRouter) }
    }

    private func publishReadiness(_ readiness: DecisionReadiness, backendID: DecisionServiceID) {
        readinessLock.lock()
        let changed = readinessByBackendID[backendID] != readiness
        readinessByBackendID[backendID] = readiness
        readinessLock.unlock()
        guard changed else { return }
        Task { @MainActor [weak self] in self?.objectWillChange.send() }
    }
}

/// One serialized owner. Selection changes cancel route reservations, never credentials.
/// A task-free bootstrap already admitted may finish after demand exits.
private actor AgentTaskRouterActivation {
    private let registry: DecisionServiceRegistry
    private let coordinator: DecisionCoordinator
    private let source: (any AgentTaskRouterDemandSource)?
    private var observations: [DecisionServiceID: Task<Void, Never>] = [:]
    private var bootstraps: [DecisionServiceID: Task<Void, Never>] = [:]
    private var controllers: [DecisionServiceID: any DecisionServiceConfigurationController] = [:]
    private var routeCancellation: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var attemptedGenerations: [DecisionServiceID: UInt64] = [:]
    private var readiness: [DecisionServiceID: DecisionReadiness] = [:]
    private var readinessStreamVersions: [DecisionServiceID: UInt64] = [:]
    private var lastSnapshot: AgentTaskRouterDemandSnapshot?
    private var epoch: UInt64 = 0
    private var stopped = false
    private var initialized = false
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []
    private var publish: (@Sendable (DecisionReadiness, DecisionServiceID) -> Void)?

    init(registry: DecisionServiceRegistry, coordinator: DecisionCoordinator, source: (any AgentTaskRouterDemandSource)?) {
        self.registry = registry
        self.coordinator = coordinator
        self.source = source
    }

    func start(publish: @escaping @Sendable (DecisionReadiness, DecisionServiceID) -> Void) async {
        guard !stopped else { return }
        self.publish = publish
        for registration in await registry.registrations() {
            guard !stopped, !Task.isCancelled else { return }
            let initial = if let controller = registration.configuration?.controller {
                await controller.readinessSnapshot()
            } else {
                await registration.service.readinessSnapshot()
            }
            guard !stopped else { return }
            readiness[registration.id] = initial
            publish(initial, registration.id)
            if let controller = registration.configuration?.controller {
                controllers[registration.id] = controller
                observations[registration.id] = Task { [weak self] in
                    for await snapshot in await controller.readinessUpdates() {
                        guard !Task.isCancelled else { return }
                        await self?.receiveStream(snapshot, id: registration.id)
                    }
                }
            }
        }
        initialized = true
        initializationWaiters.forEach { $0.resume() }
        initializationWaiters.removeAll()
        guard let source else { return }
        for await _ in await source.routerDemandUpdates() {
            guard !stopped, !Task.isCancelled else { return }
            await reconcileLatest()
        }
    }

    private func receiveStream(_ snapshot: DecisionReadiness, id: DecisionServiceID) {
        readinessStreamVersions[id, default: 0] &+= 1
        receive(snapshot, id: id)
    }

    private func receiveSnapshot(_ snapshot: DecisionReadiness, id: DecisionServiceID, streamVersion: UInt64) {
        guard readinessStreamVersions[id, default: 0] == streamVersion else { return }
        receive(snapshot, id: id)
    }

    private func receive(_ snapshot: DecisionReadiness, id: DecisionServiceID) {
        guard !stopped, snapshot.generation >= (readiness[id]?.generation ?? 0) else { return }
        readiness[id] = snapshot
        publish?(snapshot, id)
    }

    private func reconcileLatest() async {
        let previous = reconcileTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.readAndApplyLatest()
        }
        reconcileTask = task
        await task.value
    }

    private func readAndApplyLatest() async {
        guard !stopped, let source else { return }
        let snapshot = await source.routerDemandSnapshot()
        guard !stopped else { return }
        applyDemand(snapshot)
        await routeCancellation?.value
    }

    /// Install intent and reserve every bootstrap without suspension. Actor isolation
    /// alone would not serialize a partially installed demand across an await.
    private func applyDemand(_ snapshot: AgentTaskRouterDemandSnapshot, retryAdmission: Bool = false) {
        guard !stopped else { return }
        let demandChanged = lastSnapshot?.key != snapshot.key
        if demandChanged { epoch &+= 1 }
        let cancelRouter = lastSnapshot.map { $0.routerRevision != snapshot.routerRevision } ?? false
        let cancelAutoEffort = lastSnapshot.map { $0.autoEffortRevision != snapshot.autoEffortRevision } ?? false
        lastSnapshot = snapshot
        if cancelRouter || cancelAutoEffort {
            let previous = routeCancellation
            routeCancellation = Task { [coordinator] in
                await previous?.value
                if cancelRouter {
                    await coordinator.advanceConsumerRevision(consumerID: .modelRouter, revision: snapshot.routerRevision)
                }
                if cancelAutoEffort {
                    await coordinator.advanceConsumerRevision(consumerID: .autoEffort, revision: snapshot.autoEffortRevision)
                }
            }
        }
        // Readiness and guidance-only revisions are not demand transitions. In particular,
        // explicit credential invalidation/removal must not immediately validate again.
        guard demandChanged || retryAdmission else { return }
        let capturedEpoch = epoch
        for id in snapshot.requiredBackendIDs {
            guard !stopped, capturedEpoch == epoch, bootstraps[id] == nil,
                  let state = readiness[id], !state.isReady else { continue }
            if case .validating = state { continue }
            guard attemptedGenerations[id] != state.generation,
                  let controller = controllers[id] else { continue }
            guard !stopped, capturedEpoch == epoch, bootstraps[id] == nil else { continue }
            bootstraps[id] = Task { [weak self] in
                await self?.bootstrap(id: id, controller: controller, epoch: capturedEpoch)
            }
        }
    }

    private func bootstrap(id: DecisionServiceID, controller: any DecisionServiceConfigurationController, epoch admittedEpoch: UInt64) async {
        let streamVersion = readinessStreamVersions[id, default: 0]
        let state = await controller.readinessSnapshot()
        receiveSnapshot(state, id: id, streamVersion: streamVersion)
        guard let source else { return }
        let latest = await source.routerDemandSnapshot()
        guard !stopped, !Task.isCancelled, admittedEpoch == epoch,
              latest.key == lastSnapshot?.key, latest.requiredBackendIDs.contains(id),
              readinessStreamVersions[id, default: 0] == streamVersion,
              !state.isReady, attemptedGenerations[id] != state.generation
        else {
            bootstraps[id] = nil
            applyDemand(latest, retryAdmission: true)
            return
        }
        if case .validating = state {
            bootstraps[id] = nil
            return
        }
        attemptedGenerations[id] = state.generation
        await controller.bootstrapStoredConfigurationIfNeeded()
        guard !stopped else { return }
        let finalStreamVersion = readinessStreamVersions[id, default: 0]
        let final = await controller.readinessSnapshot()
        attemptedGenerations[id] = max(attemptedGenerations[id] ?? 0, final.generation)
        bootstraps[id] = nil
        receiveSnapshot(final, id: id, streamVersion: finalStreamVersion)
    }

    func waitUntilInitialized() async {
        if !initialized, !stopped {
            await withCheckedContinuation { initializationWaiters.append($0) }
        }
    }

    func reconcileAndWait(waitForBootstrap: Bool) async {
        await waitUntilInitialized()
        await reconcileLatest()
        if waitForBootstrap {
            while let task = bootstraps.values.first {
                await task.value
            }
        }
    }

    func stop() async {
        stopped = true
        initializationWaiters.forEach { $0.resume() }
        initializationWaiters.removeAll()
        epoch &+= 1
        let tasks = Array(observations.values) + Array(bootstraps.values) + [routeCancellation, reconcileTask].compactMap(\.self)
        tasks.forEach { $0.cancel() }
        observations.removeAll()
        bootstraps.removeAll()
        reconcileTask = nil
        publish = nil
        // Controllers may ignore cancellation while reading secure storage or validating.
        // Late results are fenced by stopped/epoch; teardown must not await those tasks.
    }
}
