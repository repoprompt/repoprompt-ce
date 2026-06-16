import Foundation

protocol OpenCodeACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

struct OpenCodeACPControllerModelDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) -> (any ACPAgentProvider)?
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
            return ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels? {
        let request = ACPRunRequest(
            agentKind: .openCode,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = providerFactory(.openCode, nil) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "OpenCode ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            let snapshot = AgentACPModelRegistry.shared.currentSnapshot(for: .openCode)
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

// SEARCH-HELPER: OpenCode ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for OpenCode ACP dynamic model options.
///
/// OpenCode exposes model metadata through ACP session bootstrap responses. This service owns
/// the lightweight discovery loop and writes normalized options through `AgentACPModelRegistry`,
/// keeping Agent Mode and Discover UI paths as registry consumers rather than duplicate parsers.
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

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Bool, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false

    init(
        client: any OpenCodeACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
    }

    func latestSnapshot() async -> Snapshot? {
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    /// Force a foreground OpenCode ACP model discovery and return the normalized snapshot.
    ///
    /// Settings uses this for connection/preflight so model options are written to
    /// `AgentACPModelRegistry` before the first agent session starts. Unlike the
    /// background polling loop, errors are surfaced to the caller for user-facing state.
    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            await existing.value
            return await latestSnapshot()
        }
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

    private func performRefresh() async -> Bool {
        guard !isShutdown else { return false }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let task = Task<Bool, Never> { [weak self, workspacePath] in
            guard let self else { return false }
            do {
                guard let discovered = try await client.discoverModels(workspacePath: workspacePath) else { return false }
                guard !Task.isCancelled else { return false }
                await applyRefreshResult(discovered)
                return true
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                return false
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func applyRefreshResult(_ discovered: ACPDiscoveredSessionModels) {
        guard !isShutdown else { return }
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(discovered, for: .openCode)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .openCode) else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .openCode) else {
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
