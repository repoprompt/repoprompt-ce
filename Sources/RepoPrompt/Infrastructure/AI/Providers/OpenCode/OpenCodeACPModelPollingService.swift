import Foundation

protocol OpenCodeACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?, modelRaw: String?) async throws -> OpenCodeACPModelDiscoveryResult?
}

struct OpenCodeACPControllerModelDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .openCode {
                return OpenCodeACPAgentProvider(
                    config: OpenCodeAgentConfig(
                        modelString: modelString,
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        includeRepoPromptMCPServer: false,
                        includeManagedConfigOverlay: true,
                        cleanupLegacyPersistentConfig: true,
                        toolProfile: .noTools
                    )
                )
            }
            return try await ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    /// Bootstraps a disposable OpenCode ACP session and returns the bootstrap catalog plus,
    /// when `modelRaw` is non-nil, the parameter outcome for that model.
    ///
    /// The bootstrap catalog is the one published. OpenCode only advertises the
    /// model-scoped `effort` selector *after* a model set, so the parameter probe mutates the
    /// session's current model; substituting that probe session's model list would confuse
    /// "the model we interrogated" with "the provider default" and could lose the model list.
    /// The probe therefore runs in a disposable controller and only its *parameter outcome*
    /// is extracted; the published catalog retains the bootstrap options and bootstrap current.
    func discoverModels(workspacePath: String?, modelRaw: String?) async throws -> OpenCodeACPModelDiscoveryResult? {
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = try await providerFactory(.openCode, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "OpenCode ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        // The disposable controller is shut down on success, failure, and cancellation.
        do {
            _ = try await controller.bootstrap()
            guard let catalog = await controller.currentDiscoveredSessionModels() else {
                await controller.shutdown()
                return nil
            }

            var parameterState: OpenCodeACPModelParameterState?
            if let modelRaw {
                parameterState = await Self.probeParameters(for: modelRaw, controller: controller)
            }
            await controller.shutdown()
            return OpenCodeACPModelDiscoveryResult(catalog: catalog, parameterState: parameterState)
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    /// Drives the model-selector probe and reduces the verified snapshot to a terminal
    /// parameter state for the requested model. A probe failure never throws here: the
    /// catalog must survive a failed probe, so the outcome is `.failed(detail:)` instead.
    private static func probeParameters(
        for modelRaw: String,
        controller: ACPAgentSessionController
    ) async -> OpenCodeACPModelParameterState {
        await classifyParameterOutcome(modelRaw: modelRaw) {
            try await controller.discoverSessionModelParameters(for: $0)
        }
    }

    /// The terminal classification, extracted from the transport so it is directly testable
    /// via a scripted closure (no protocol conformance / Python subprocess needed).
    static func classifyParameterOutcome(
        modelRaw: String,
        discover: (String) async throws -> ACPDiscoveredSessionModels
    ) async -> OpenCodeACPModelParameterState {
        let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(detail: "Model parameter discovery requires a non-empty model.")
        }
        let requestedIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            trimmed,
            providerID: .openCode
        )
        do {
            let verified = try await discover(trimmed)
            // Never fall back to another model's metadata when the requested identity is
            // missing or ambiguous in the verified post-mutation snapshot.
            let matchingSets = verified.modelParameterSets.filter {
                ACPModelParameterIdentity.canonicalBaseModelRaw($0.baseModelRaw, providerID: .openCode)
                    == requestedIdentity
            }
            switch matchingSets.count {
            case 0:
                // A verified, matching model that legitimately advertises no selector is
                // `.noUsableParameters` (a successful outcome: no parameter set exists).
                return .noUsableParameters
            case 1:
                let parameterSet = matchingSets[0]
                guard parameterSet.parameters.contains(where: { !$0.choices.isEmpty }) else {
                    return .noUsableParameters
                }
                return .available(parameterSet)
            default:
                return .failed(
                    detail: "Model parameter discovery for '\(trimmed)' was ambiguous: matched \(matchingSets.count) parameter sets; expected exactly one."
                )
            }
        } catch is CancellationError {
            return .failed(detail: "Model parameter discovery for '\(trimmed)' was cancelled.")
        } catch {
            return .failed(detail: "Model parameter discovery for '\(trimmed)' failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Demand-scoped model-parameter observation value types

/// Identity of a demand-scoped OpenCode model-parameter observation. A `nil` workspace is a
/// distinct context, never a wildcard for "any workspace".
struct OpenCodeACPModelParameterKey: Hashable {
    let workspacePath: String?
    let canonicalBaseModelRaw: String

    init(workspacePath: String?, modelRaw: String) {
        self.workspacePath = Self.normalizedWorkspacePath(workspacePath)
        canonicalBaseModelRaw = ACPModelParameterIdentity.canonicalBaseModelRaw(
            modelRaw,
            providerID: .openCode
        )
    }

    /// The single workspace normalization every (service, resolver, composer) key comparison
    /// uses, so logically identical paths (`/a/child/..` vs `/a`) always produce the same key.
    /// A nil/empty workspace is a distinct context, never a wildcard.
    static func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

/// Model-parameter observation states. `.loading` appears only as a transient observation
/// while a probe is in flight; the discovery client reports terminal outcomes only.
enum OpenCodeACPModelParameterState: Equatable {
    case loading
    case available(ACPModelParameterSet)
    case noUsableParameters
    case failed(detail: String)

    var isTerminal: Bool {
        switch self {
        case .loading: false
        case .available, .noUsableParameters, .failed: true
        }
    }
}

struct OpenCodeACPModelParameterSnapshot: Equatable {
    let key: OpenCodeACPModelParameterKey
    let state: OpenCodeACPModelParameterState
    let updatedAt: Date
}

/// The outcome of one OpenCode model discovery pass: the bootstrap catalog (always, when the
/// pass succeeds) plus the parameter outcome for a single requested model (when a probe was
/// requested). `parameterState == nil` means "catalog-only; no probe requested" and never
/// means `.loading`.
struct OpenCodeACPModelDiscoveryResult: Equatable {
    let catalog: ACPDiscoveredSessionModels
    let parameterState: OpenCodeACPModelParameterState?
}

// SEARCH-HELPER: OpenCode ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for OpenCode ACP dynamic model options and demand-scoped
/// model-parameter observations.
///
/// Catalog observations keep their existing registry-facing path: this actor owns the
/// discovery loop and writes normalized catalog options through `AgentACPModelRegistry` at
/// job completion, so every successful job (foreground, subscriber-triggered, or periodic)
/// publishes exactly once. `subscribe` callers receive the published catalog stream.
///
/// Model-parameter observations are separate and demand-scoped: they are keyed by
/// `(workspacePath, canonicalModel)`, exist only while a subscriber or one-shot waiter owns
/// them, and travel directly to matching subscribers — never through the global registry
/// (whose per-provider snapshot replacement would let the last single-model probe win).
///
/// Both share one serialized discovery-job runner so at most one disposable ACP controller
/// exists at a time; identical jobs coalesce on a single queue entry per key and never join a
/// different key's result. The queue is FIFO.
actor OpenCodeACPModelPollingService {
    static let shared = OpenCodeACPModelPollingService(
        client: OpenCodeACPControllerModelDiscoveryClient()
    )

    struct Snapshot: Equatable {
        let models: ACPDiscoveredSessionModels
        let fetchedAt: Date
        let isLiveDiscovery: Bool
    }

    private let client: any OpenCodeACPModelDiscoveryClient
    private let intervalNanos: UInt64

    // Catalog broadcast state.
    private var catalogContinuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var latest: Snapshot?

    /// Demand-scoped parameter observations, keyed by (workspace, canonical model).
    private var observations: [OpenCodeACPModelParameterKey: Observation] = [:]

    // MARK: Job runner state (FIFO queue + single active + per-key coalescing)

    private var queuedKeys: [JobKey] = []
    private var jobsByKey: [JobKey: JobEntry] = [:]
    private var activeKey: JobKey?
    private var activeTask: Task<Void, Never>?

    /// Periodic refresh: ticks at `intervalNanos` while any catalog subscriber exists (the
    /// sole periodic-refresh driver) and coalesces due catalog refreshes through the shared
    /// job runner. Owned parameter observations are NOT periodically refreshed: a one-shot
    /// waiter needs one terminal result, and a subscriber-facing re-probe would replace a
    /// `.available` control with `.loading` on each tick, visibly dropping the effort control.
    private var refreshTask: Task<Void, Never>?

    private var preferredWorkspacePath: String?
    private var isShutdown = false

    init(
        client: any OpenCodeACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
    }

    // MARK: Catalog-facing API (signatures preserved for Settings / AgentMode / ContextBuilder)

    func latestSnapshot() async -> Snapshot? {
        if let latest {
            return latest
        }
        return await registrySnapshotAfterWarmingStore()
    }

    /// Force a foreground OpenCode ACP model discovery and return the published snapshot.
    ///
    /// Settings uses this for connection/preflight so model options are written to
    /// `AgentACPModelRegistry` before the first agent session starts. The job owns catalog
    /// publication and subscriber broadcast; the caller receives that same published snapshot
    /// and returns `nil` when the client obtained nothing.
    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        let workspace = OpenCodeACPModelParameterKey.normalizedWorkspacePath(workspacePath)
        preferredWorkspacePath = workspace
        return try await awaitCatalogJob(workspace: workspace)
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in continuation.finish() }
        }

        preferredWorkspacePath = OpenCodeACPModelParameterKey.normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        catalogContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeCatalogSubscriber(id) }
        }

        if let latest {
            continuation.yield(latest)
        } else if let cached = await registrySnapshotAfterWarmingStore() {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if latest == nil {
                latest = cached
            }
            if let latest {
                continuation.yield(latest)
            }
        }

        guard !isShutdown else { return stream }
        // New catalog interest -> enqueue a catalog refresh for the preferred workspace and
        // ensure the periodic refresh loop is running while interest exists. Publication of
        // that refresh's result is owned by job completion, not by this caller.
        enqueueJob(.catalog(workspacePath: preferredWorkspacePath))
        updateRefreshLoop()
        return stream
    }

    @discardableResult
    func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        let workspace = OpenCodeACPModelParameterKey.normalizedWorkspacePath(workspacePath)
        preferredWorkspacePath = workspace
        do {
            // Both the Boolean and the dependent parameter re-probe require a non-nil published
            // snapshot: when the client returned nil nothing was obtained or published, so this
            // must report failure rather than falsely refreshing downstream parameter state.
            guard let snapshot = try await awaitCatalogJob(workspace: workspace) else {
                return false
            }
            _ = snapshot
            refreshParameterObservations(for: workspace)
            return true
        } catch {
            return false
        }
    }

    // MARK: Demand-scoped parameter API

    /// Own an observation for `(workspacePath, model)` while the stream is consumed. Yields
    /// the retained observation for the key, `.loading` when no prior observation exists, and
    /// the terminal outcome as it resolves. The observation is retained while an owner exists
    /// and evicted once the last one leaves.
    ///
    /// A second subscriber joining an already-`available` key replays that retained observation
    /// instead of starting a fresh probe, so existing subscribers keep their controls. Only a
    /// key with no retained observation (first subscriber, or after eviction) enqueues a probe.
    func subscribeModelParameters(
        workspacePath: String?,
        modelRaw: String
    ) async -> AsyncStream<OpenCodeACPModelParameterSnapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in continuation.finish() }
        }
        let key = OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: modelRaw)
        let id = UUID()
        let (stream, continuation) = AsyncStream<OpenCodeACPModelParameterSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var observation = observations[key] ?? Observation()
        let hadPriorObservation = observation.latest != nil
        observation.subscribers[id] = continuation
        observations[key] = observation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeParameterSubscriber(key: key, id: id) }
        }

        if let latest = observation.latest {
            continuation.yield(latest)
        }
        if !hadPriorObservation {
            probeObservationIfNeeded(key: key)
        }
        return stream
    }

    /// One-shot parameter observation. Resolves only to a terminal state (`.available`,
    /// `.noUsableParameters`, or `.failed`); cancellation and shutdown throw. `forceRefresh`
    /// bypasses a retained completed observation, but joins an existing identical acquisition.
    ///
    /// Same-key in-flight reuse policy: a concurrent identical job (queued or in flight) is a
    /// probe in progress, so both forced and non-forced one-shots coalesce into it rather than
    /// starting a duplicate probe. There is deliberately no observation-generation check: an
    /// evicted-then-recreated key may join the old in-flight job. This is the demand-scoped
    /// coalescing policy (one disposable controller at a time), not a freshness guarantee — an
    /// in-flight result is not claimed "still-fresh".
    func discoverModelParametersOnce(
        workspacePath: String?,
        modelRaw: String,
        forceRefresh: Bool = false
    ) async throws -> OpenCodeACPModelParameterSnapshot {
        try Task.checkCancellation()
        guard !isShutdown else { throw CancellationError() }
        let key = OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: modelRaw)

        // Fast path: a retained terminal observation for this exact key answers without a new
        // probe, unless a refresh is forced. Forced and non-forced one-shots alike join an
        // identical already-queued/in-flight acquisition through the waiter path (identical
        // jobs coalesce; the in-flight result itself guarantees nothing about freshness).
        if let existing = observations[key], let latest = existing.latest, latest.state.isTerminal, !forceRefresh {
            return latest
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OpenCodeACPModelParameterSnapshot, Error>) in
                // Register the waiter SYNCHRONOUSLY inside the continuation closure. Task
                // closure identity is isolated to this actor, so the closure runs on the actor
                // Registration is atomic on the actor: the continuation installs the waiter
                // synchronously, before the cancellation handler or `finishJob` can interleave.
                if isShutdown {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var observation = observations[key] ?? Observation()
                observation.oneShotWaiters[waiterID] = continuation
                observations[key] = observation
                probeObservationIfNeeded(key: key)
            }
        } onCancel: {
            Task { await self.cancelOneShotWaiter(key: key, id: waiterID) }
        }
    }

    private func cancelOneShotWaiter(key: OpenCodeACPModelParameterKey, id: UUID) {
        guard var observation = observations[key] else { return }
        if let continuation = observation.oneShotWaiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
        observations[key] = observation
        evictObservationIfIdle(key: key)
    }

    // MARK: Shutdown

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        refreshTask?.cancel()
        refreshTask = nil
        // Cancel the active probe task but do NOT reap it here (its `finishJob` reaps); do
        // NOT clear `activeKey` (a post-shutdown late completion still sees `activeKey == key`
        // and correctly drops its outcome). Queued jobs below get their catalog waiters
        // cancelled; every other terminal exit is settled by `finishJob`.
        activeTask?.cancel()
        activeTask = nil
        let queued = jobsByKey
        jobsByKey.removeAll()
        queuedKeys.removeAll()
        for entry in queued.values {
            for waiter in entry.catalogWaiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        if finishSubscribers {
            let catalogues = catalogContinuations
            catalogContinuations.removeAll()
            for continuation in catalogues.values {
                continuation.finish()
            }
        }
        let active = observations
        observations.removeAll()
        for var observation in active.values {
            for waiter in observation.oneShotWaiters.values {
                waiter.resume(throwing: CancellationError())
            }
            observation.oneShotWaiters.removeAll()
            for continuation in observation.subscribers.values {
                continuation.finish()
            }
            observation.subscribers.removeAll()
        }
    }

    // MARK: - Catalog internals

    private func removeCatalogSubscriber(_ id: UUID) {
        catalogContinuations.removeValue(forKey: id)
        updateRefreshLoop()
    }

    /// Writes the catalog to the registry and broadcasts the fresh snapshot to catalog
    /// subscribers. Called only from job completion, so every successful discovery — including
    /// subscriber-triggered and periodic refreshes — publishes exactly once even when no
    /// foreground caller is waiting. Returns `nil` after shutdown (no publication).
    @discardableResult
    private func publishCatalog(_ discovered: ACPDiscoveredSessionModels) -> Snapshot? {
        guard !isShutdown else { return nil }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .openCode)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .openCode) else { return nil }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        // The registry was updated unconditionally above; the model-equality guard only avoids
        // redundant subscriber spam. The fresh snapshot is still recorded in `latest`.
        let shouldBroadcast = latest?.models != snapshot.models || latest?.isLiveDiscovery == false
        latest = snapshot
        if shouldBroadcast {
            for continuation in catalogContinuations.values {
                continuation.yield(snapshot)
            }
        }
        return snapshot
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .openCode) else {
            return nil
        }
        return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    // MARK: - Parameter probe internals

    /// Publish `.loading` and enqueue a probe for the key, unless a job for this exact key is
    /// already queued (a queued identical probe is a valid forthcoming result, so an owner
    /// simply joins it without forcing a duplicate probe).
    private func probeObservationIfNeeded(key: OpenCodeACPModelParameterKey) {
        guard !isShutdown, var observation = observations[key] else { return }
        let jobKey = JobKey.parameter(key)
        guard jobsByKey[jobKey] == nil else { return } // identical probe already queued/active
        let loading = OpenCodeACPModelParameterSnapshot(key: key, state: .loading, updatedAt: Date())
        observation.latest = loading
        observations[key] = observation
        for continuation in observation.subscribers.values {
            continuation.yield(loading)
        }
        enqueueJob(jobKey)
    }

    /// Probe parameter observations for a workspace (invoked by `refreshNow`, an explicit
    /// one-shot user request). Owned keys re-probe; unowned keys are pruned instead.
    private func refreshParameterObservations(for workspace: String?) {
        guard !isShutdown else { return }
        for (key, observation) in observations where key.workspacePath == workspace {
            pruneJobIfUnowned(key: key, observation: observation)
            guard observation.subscribers.isEmpty == false || observation.oneShotWaiters.isEmpty == false else { continue }
            probeObservationIfNeeded(key: key)
        }
    }

    private func removeParameterSubscriber(key: OpenCodeACPModelParameterKey, id: UUID) {
        guard var observation = observations[key] else { return }
        observation.subscribers.removeValue(forKey: id)
        observations[key] = observation
        evictObservationIfIdle(key: key)
    }

    /// Evict an observation once it has no owners. Late completions must not resurrect a
    /// removed interest: eviction removes the entry, so the runner's completion-time lookup
    /// `observations[key]` becomes nil and the outcome is dropped. A queued job nobody still
    /// owns is pruned before it can start (see `pruneJobIfUnowned`).
    private func evictObservationIfIdle(key: OpenCodeACPModelParameterKey) {
        guard let observation = observations[key] else { return }
        guard observation.subscribers.isEmpty, observation.oneShotWaiters.isEmpty else { return }
        observations.removeValue(forKey: key)
        pruneJobIfUnowned(key: key, observation: observation)
    }

    /// Remove a queued-but-not-yet-started parameter job whose observation has lost its
    /// last owner, so it never launches a disposable controller nobody wants. A job already
    /// running is left to finish (its controller is cleaned up by the client); its completed
    /// outcome is dropped by the nil `observations[key]` lookup. In-flight state is derived
    /// from the job entry itself, so there is no second owner of "in flight" to go inconsistent.
    private func pruneJobIfUnowned(key: OpenCodeACPModelParameterKey, observation: Observation) {
        guard observation.subscribers.isEmpty, observation.oneShotWaiters.isEmpty else { return }
        let jobKey = JobKey.parameter(key)
        guard jobKey != activeKey, jobsByKey.removeValue(forKey: jobKey) != nil else { return }
        queuedKeys.removeAll { $0 == jobKey }
    }

    /// Start the periodic refresh loop while any catalog subscriber exists; stop it when
    /// demand drops to zero. Ticks at `intervalNanos` and refreshes the catalog for the
    /// preferred workspace.
    private func updateRefreshLoop() {
        guard !isShutdown else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        guard !catalogContinuations.isEmpty else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await performPeriodicRefresh()
            }
        }
    }

    /// One periodic tick: enqueue the catalog refresh. Owned parameter observations are not
    /// periodically re-probed (see `refreshTask`).
    private func performPeriodicRefresh() {
        guard !isShutdown, !catalogContinuations.isEmpty else { return }
        enqueueJob(.catalog(workspacePath: preferredWorkspacePath))
    }

    // MARK: - Parameter outcome delivery (runner, on-actor)

    private func deliverParameterOutcome(
        _ key: OpenCodeACPModelParameterKey,
        state: OpenCodeACPModelParameterState
    ) {
        // Reject late completions for evicted observations (nil after eviction).
        guard var observation = observations[key], !isShutdown else { return }
        let snapshot = OpenCodeACPModelParameterSnapshot(key: key, state: state, updatedAt: Date())
        // The probe published `.loading` at trigger time; this terminal outcome replaces it.
        // The last success is not retained during a probe, and historical choice sets are
        // never merged.
        observation.latest = snapshot
        observations[key] = observation
        for continuation in observation.subscribers.values {
            continuation.yield(snapshot)
        }
        let waiters = observation.oneShotWaiters
        observation.oneShotWaiters.removeAll()
        observations[key] = observation
        for waiter in waiters.values {
            waiter.resume(returning: snapshot)
        }
        evictObservationIfIdle(key: key)
    }

    // MARK: - Discovery job mechanism (FIFO queue; one disposable controller at a time)

    private enum JobKey: Hashable {
        case catalog(workspacePath: String?)
        case parameter(OpenCodeACPModelParameterKey)

        var parameterKey: OpenCodeACPModelParameterKey? {
            switch self {
            case .catalog: nil
            case let .parameter(key): key
            }
        }

        var wireModelRaw: String? {
            parameterKey?.canonicalBaseModelRaw
        }

        var workspacePath: String? {
            switch self {
            case let .catalog(workspace): workspace
            case let .parameter(key): key.workspacePath
            }
        }
    }

    private struct CatalogWaiter {
        let id: UUID
        let continuation: CheckedContinuation<OpenCodeACPModelPollingService.Snapshot?, Error>
    }

    /// One coalesced job per key. Catalog joiners register a waiter and receive this job's own
    /// result/error. Jobs are run one at a time from the FIFO queue.
    private struct JobEntry {
        var catalogWaiters: [CatalogWaiter] = []
    }

    private func enqueueJob(_ key: JobKey) {
        guard !isShutdown else { return }
        guard jobsByKey[key] == nil else { return } // identical job coalesces
        jobsByKey[key] = JobEntry()
        queuedKeys.append(key)
        pumpRunner()
    }

    /// Start the next queued job if none is active. Serializes discovery so at most one
    /// disposable ACP controller exists at a time across catalog and parameter work. An
    /// unowned queued key that survived pruning is skipped here as a backstop.
    private func pumpRunner() {
        guard !isShutdown, activeKey == nil, !queuedKeys.isEmpty else { return }
        guard let key = queuedKeys.first, jobsByKey[key] != nil else {
            // The key was dropped from jobsByKey while queued (e.g. pruned); skip it.
            queuedKeys.removeFirst()
            pumpRunner()
            return
        }
        queuedKeys.removeFirst()
        activeKey = key
        let client = client
        let wireModel = key.wireModelRaw
        let workspace = key.workspacePath
        activeTask = Task { [weak self] in
            // Run the disposable controller to completion or failure, always through the
            // client, which shuts that controller down on success, failure, and cancellation.
            // The single-controller slot (`activeKey`) is released only from `finishJob`,
            // which runs strictly after the client's shutdown `await` above.
            let result: Result<OpenCodeACPModelDiscoveryResult?, Error>
            do {
                let value = try await client.discoverModels(workspacePath: workspace, modelRaw: wireModel)
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            await finishJob(key: key, result: result)
        }
    }

    /// Resolve a finished job: publish its catalog result (even with no foreground waiter),
    /// deliver its parameter outcome, resume catalog waiters with the *same* published snapshot
    /// (not the raw discovery result), settle every terminal exit's in-flight state, and start
    /// the next queued job. Runs on the actor.
    private func finishJob(key: JobKey, result: Result<OpenCodeACPModelDiscoveryResult?, Error>) {
        guard activeKey == key else { return } // shutdown/cancel already reaped this job
        let entry = jobsByKey.removeValue(forKey: key)
        activeKey = nil
        activeTask = nil

        switch result {
        case let .success(value):
            // Publication must own the snapshot foreground callers receive: `publishCatalog`
            // builds the single normalized/timestamped snapshot, and catalog waiters all resume
            // with that same value rather than `awaitCatalogJob` reconstructing a second one.
            let published: Snapshot? = if let catalog = value?.catalog {
                publishCatalog(catalog)
            } else {
                nil
            }
            if case let .parameter(parameterKey) = key {
                let state = value?.parameterState
                    ?? .failed(detail: "Model parameter discovery produced no result.")
                deliverParameterOutcome(parameterKey, state: state)
            }
            for waiter in entry?.catalogWaiters ?? [] {
                waiter.continuation.resume(returning: published)
            }
        case let .failure(error):
            if case let .parameter(parameterKey) = key {
                // A client `CancellationError` takes this terminal path (the job result maps a
                // thrown error to `.failure`), so waiters are settled rather than stranded
                // suspended in the client's probe-outcome mapping. Two cancellation events are
                // deliberately distinct here: each waiter owns its cancellation independently.
                // The caller's own cancellation (handled by `cancelOneShotWaiter`/`shutdown`)
                // throws `CancellationError` to that caller alone; a client-side thrown
                // cancellation is the shared job's event, not any uncancelled caller's, so those
                // callers are settled by VALUE with a terminal `.failed` rather than being told
                // they were cancelled. Removing only the cancelled owner keeps the shared job
                // alive for the surviving owners.
                deliverParameterOutcome(
                    parameterKey,
                    state: .failed(detail: error.localizedDescription)
                )
            }
            for waiter in entry?.catalogWaiters ?? [] {
                waiter.continuation.resume(throwing: error)
            }
        }
        pumpRunner()
    }

    /// Join (or start) the catalog job for a workspace. Foreground callers receive this job's
    /// real result/error. Cancellation withdraws only this caller's waiter; the shared job keeps
    /// running for other owners.
    private func awaitCatalogJob(workspace: String?) async throws -> Snapshot? {
        try Task.checkCancellation()
        guard !isShutdown else { throw CancellationError() }
        let key = JobKey.catalog(workspacePath: workspace)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Snapshot?, Error>) in
                // Register the waiter synchronously inside the continuation closure so ordering
                // against the cancellation handler cannot strand a cancelled caller.
                if isShutdown {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Enqueue first so the entry exists, then append the waiter. Registration is
                // atomic on the actor: `finishJob` runs on the actor too, so it cannot drop
                // this waiter between enqueue and append.
                enqueueJob(key)
                jobsByKey[key]?.catalogWaiters.append(CatalogWaiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelCatalogWaiter(key: key, id: waiterID) }
        }
        // Publication already happened in `finishJob`; the waiter resumed with that published
        // snapshot, so there is no second snapshot to construct here.
    }

    private func cancelCatalogWaiter(key: JobKey, id: UUID) {
        guard var entry = jobsByKey[key] else { return }
        guard let index = entry.catalogWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = entry.catalogWaiters.remove(at: index)
        jobsByKey[key] = entry
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private extension OpenCodeACPModelPollingService {
    struct Observation {
        var subscribers: [UUID: AsyncStream<OpenCodeACPModelParameterSnapshot>.Continuation] = [:]
        var oneShotWaiters: [UUID: CheckedContinuation<OpenCodeACPModelParameterSnapshot, Error>] = [:]
        var latest: OpenCodeACPModelParameterSnapshot?
    }
}
