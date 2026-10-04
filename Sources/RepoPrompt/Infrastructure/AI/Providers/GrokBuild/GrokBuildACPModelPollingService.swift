import Foundation

protocol GrokBuildACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

/// Discovery client that reuses one verified Grok session in a neutral directory so
/// 5-minute polling does not accumulate persistent sessions under `~/.grok/sessions`.
/// `session/load` returns fresh `models` metadata on grok 1.0.3, so load-based discovery
/// observes remote catalog changes.
actor GrokBuildACPControllerModelDiscoveryClient: GrokBuildACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ config: GrokBuildAgentConfig) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory
    private var retainedSessionID: String?

    init(
        providerFactory: @escaping ProviderFactory = { config in
            // Keep credential lookup inside the default factory so injected factories
            // can observe discovery routing without touching secure storage.
            try await GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: config.commandName,
                    additionalPathHints: config.additionalPathHints,
                    enableDebugLogging: config.enableDebugLogging,
                    modelString: config.modelString,
                    includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                    alwaysApproveTools: config.alwaysApproveTools,
                    apiKey: KeyManager().getAPIKey(for: .grok),
                    launchPurpose: config.launchPurpose
                )
            )
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        // Catalog discovery does not need the user's project. Keep project .mcp.json and
        // project-local Cursor imports out of polling, without changing HOME/GROK_HOME.
        let request = ACPRunRequest(
            agentKind: .grokBuild,
            modelString: nil,
            workspacePath: Self.stableDiscoveryWorkspacePath(),
            resumeSessionID: retainedSessionID,
            attachments: [],
            taskLabelKind: nil
        )
        // Polling every 300s must not spawn tool servers for nothing.
        let config = GrokBuildAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false,
            launchPurpose: .modelDiscovery
        )
        guard let provider = try await providerFactory(config) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Grok Build ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            await retainVerifiedIdentity(controller.currentProviderSessionIdentity())
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .grokBuild)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func retainVerifiedIdentity(_ identity: ACPProviderSessionIdentity) {
        // Only verified load IDs may be retained; a candidate ID would defeat the
        // controller's load→new recovery contract.
        guard identity.loadSessionIDConfidence == .verified,
              let loadID = identity.loadSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loadID.isEmpty
        else {
            return
        }
        // On a load→new recovery the verified identity is the fresh session, so this
        // assignment also replaces an invalidated retained ID.
        retainedSessionID = loadID
    }

    /// One stable provider-specific directory for discovery so repeated
    /// polls reuse the same retained session instead of leaking `~/.grok/sessions` entries.
    private static func stableDiscoveryWorkspacePath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrokBuildACPDiscovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url.standardizedFileURL.path
    }
}

// SEARCH-HELPER: Grok Build ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Grok Build ACP dynamic model options. Mirrors the Cursor
/// polling behavior: poll only while subscribed, coalesce refreshes, keep the last good
/// snapshot on failure, and warm the persisted registry before live discovery completes.
actor GrokBuildACPModelPollingService {
    static let shared = GrokBuildACPModelPollingService(
        client: GrokBuildACPControllerModelDiscoveryClient()
    )

    struct Snapshot: Equatable {
        let models: ACPDiscoveredSessionModels
        let fetchedAt: Date
        let isLiveDiscovery: Bool
    }

    private let client: any GrokBuildACPModelDiscoveryClient
    private let intervalNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Bool, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    #if DEBUG
        private var testRefreshNowInFlightJoinObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false

    init(
        client: any GrokBuildACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
    }

    func latestSnapshot() async -> Snapshot? {
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    #if DEBUG
        func test_refreshNowInFlightJoinEvents() -> AsyncStream<Void> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testRefreshNowInFlightJoinObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestRefreshNowInFlightJoinObserver(id) }
            }
            return stream
        }
    #endif

    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        guard let discovered = try await client.discoverModels(workspacePath: preferredWorkspacePath) else {
            return nil
        }
        applyRefreshResult(discovered)
        return await latestSnapshot()
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        if latest == nil, let cached = await registrySnapshotAfterWarmingStore() {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if latest == nil {
                latest = cached
            }
        }
        if let latest {
            continuation.yield(latest)
        }

        guard !isShutdown else { return stream }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            #if DEBUG
                publishTestRefreshNowInFlightJoin()
            #endif
            return await existing.value
        }
        return await performRefresh()
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        #if DEBUG
            let activeTestJoinObservers = testRefreshNowInFlightJoinObservers
            testRefreshNowInFlightJoinObservers.removeAll()
            for continuation in activeTestJoinObservers.values {
                continuation.finish()
            }
        #endif
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            for continuation in activeContinuations.values {
                continuation.finish()
            }
        }
    }

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        stopPollingIfIdle()
    }

    #if DEBUG
        private func publishTestRefreshNowInFlightJoin() {
            for continuation in testRefreshNowInFlightJoinObservers.values {
                continuation.yield(())
            }
        }

        private func removeTestRefreshNowInFlightJoinObserver(_ id: UUID) {
            testRefreshNowInFlightJoinObservers.removeValue(forKey: id)
        }
    #endif

    private func performRefresh() async -> Bool {
        guard !isShutdown else { return false }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let task = Task<Bool, Never> { [weak self, workspacePath] in
            guard let self else { return false }
            do {
                let discovered = try await client.discoverModels(workspacePath: workspacePath)
                guard !Task.isCancelled else { return false }
                if let discovered {
                    await applyRefreshResult(discovered)
                } else {
                    await publishLiveReadinessWithoutModels()
                }
                return true
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                if AgentRuntimeProviderService.enableDebugLogging {
                    print("[GrokBuildACPModelPolling] refresh failed: \(error.localizedDescription)")
                }
                return false
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func publishLiveReadinessWithoutModels() {
        guard !isShutdown else { return }
        let models = latest?.models
            ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild)
            ?? ACPDiscoveredSessionModels(options: [], currentModelRaw: nil)
        let snapshot = Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func applyRefreshResult(_ discovered: ACPDiscoveredSessionModels) {
        guard !isShutdown else { return }
        // A discovery response with no usable models publishes readiness but never writes a
        // fake snapshot; the static "default" option comes from the catalog, not the registry.
        guard !discovered.options.isEmpty else {
            publishLiveReadinessWithoutModels()
            return
        }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .grokBuild)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .grokBuild) else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .grokBuild) else {
            return nil
        }
        return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
