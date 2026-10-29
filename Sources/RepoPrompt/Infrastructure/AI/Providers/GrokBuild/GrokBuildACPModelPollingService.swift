import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts

package protocol GrokBuildACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

// SEARCH-HELPER: Grok Build ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Grok Build ACP dynamic model options. Mirrors the Cursor
/// polling behavior: poll only while subscribed, coalesce refreshes, keep the last good
/// snapshot on failure, and warm the persisted registry before live discovery completes.
package actor GrokBuildACPModelPollingService {
    package enum RefreshOutcome: Equatable {
        case updated
        case unchanged
        case noModelsAdvertised
        case skipped
        case failed
        case cancelled
    }

    package struct Snapshot: Equatable {
        package let models: ACPDiscoveredSessionModels
        package let fetchedAt: Date
        package let isLiveDiscovery: Bool
    }

    private let client: any GrokBuildACPModelDiscoveryClient
    private let registry: AgentACPModelRegistry
    private let logFailure: (String) -> Void
    private let intervalNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<RefreshOutcome, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    #if DEBUG
        private var testRefreshNowInFlightJoinObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false

    package init(
        client: any GrokBuildACPModelDiscoveryClient,
        registry: AgentACPModelRegistry,
        logFailure: @escaping (String) -> Void,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.registry = registry
        self.logFailure = logFailure
        self.intervalNanos = intervalNanos
    }

    package func latestSnapshot() async -> Snapshot? {
        if let latest { return latest }
        return await registrySnapshotAfterWarmingStore()
    }

    #if DEBUG
        package func test_refreshNowInFlightJoinEvents() -> AsyncStream<Void> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testRefreshNowInFlightJoinObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestRefreshNowInFlightJoinObserver(id) }
            }
            return stream
        }
    #endif

    package func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        guard let discovered = try await client.discoverModels(workspacePath: preferredWorkspacePath) else {
            return nil
        }
        applyRefreshResult(discovered)
        return await latestSnapshot()
    }

    package func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
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

    package func refreshNow(workspacePath: String?) async -> RefreshOutcome {
        guard !isShutdown else { return .skipped }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            #if DEBUG
                publishTestRefreshNowInFlightJoin()
            #endif
            return await existing.value
        }
        return await performRefresh()
    }

    package func shutdown(finishSubscribers: Bool = true) async {
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

    private func performRefresh() async -> RefreshOutcome {
        guard !isShutdown else { return .skipped }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let previous = registry.resolvedSnapshot(for: .grokBuild)
        let task = Task<RefreshOutcome, Never> { [weak self, workspacePath] in
            guard let self else { return .cancelled }
            do {
                let discovered = try await client.discoverModels(workspacePath: workspacePath)
                guard !Task.isCancelled else { return .cancelled }
                guard let discovered, !discovered.options.isEmpty else {
                    await publishLiveReadinessWithoutModels()
                    return .noModelsAdvertised
                }
                let didChange = await applyRefreshResult(discovered)
                guard !Task.isCancelled else { return .cancelled }
                guard didChange else { return .unchanged }
                return previous == registry.resolvedSnapshot(for: .grokBuild)
                    ? .unchanged
                    : .updated
            } catch is CancellationError {
                return .cancelled
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                logFailure(error.localizedDescription)
                return Task.isCancelled ? .cancelled : .failed
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func publishLiveReadinessWithoutModels() {
        guard !isShutdown else { return }
        let models = latest?.models
            ?? registry.resolvedSnapshot(for: .grokBuild)
            ?? ACPDiscoveredSessionModels(options: [], currentModelRaw: nil)
        let snapshot = Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func applyRefreshResult(_ discovered: ACPDiscoveredSessionModels) -> Bool {
        guard !isShutdown else { return false }
        // A discovery response with no usable models publishes readiness but never writes a
        // fake snapshot; the static "default" option comes from the catalog, not the registry.
        guard !discovered.options.isEmpty else {
            publishLiveReadinessWithoutModels()
            return false
        }
        let didChange = registry.updateDiscoveredModels(discovered, for: .grokBuild)
        guard let normalized = registry.resolvedSnapshot(for: .grokBuild) else { return false }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return didChange }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
        return didChange
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await registry.resolvedSnapshotAfterWarmingStandardStore(for: .grokBuild) else {
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
