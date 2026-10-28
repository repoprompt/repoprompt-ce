import Foundation
import RepoPromptAIContracts

package protocol CursorACPModelDiscoveryClient: Sendable {
    func discoverModels(workspacePath: String?) async throws -> ACPDiscoveredSessionModels?
}

// SEARCH-HELPER: Cursor ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Cursor ACP dynamic model options.
///
/// Cursor can expose model metadata through ACP session bootstrap responses. This mirrors the
/// OpenCode model discovery path while preserving Cursor's static Auto fallback when no
/// dynamic model metadata is available yet.
package actor CursorACPModelPollingService {
    package struct Registry {
        let update: (ACPDiscoveredSessionModels) -> Bool
        let snapshot: () -> ACPDiscoveredSessionModels?
        let snapshotAfterWarm: () async -> ACPDiscoveredSessionModels?

        package init(
            update: @escaping (ACPDiscoveredSessionModels) -> Bool,
            snapshot: @escaping () -> ACPDiscoveredSessionModels?,
            snapshotAfterWarm: @escaping () async -> ACPDiscoveredSessionModels?
        ) {
            self.update = update
            self.snapshot = snapshot
            self.snapshotAfterWarm = snapshotAfterWarm
        }
    }

    package struct Snapshot: Equatable {
        package let models: ACPDiscoveredSessionModels
        package let fetchedAt: Date
        package let isLiveDiscovery: Bool
    }

    private let client: any CursorACPModelDiscoveryClient
    private let registry: Registry
    private let intervalNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    package struct RefreshResult {
        package let isReady: Bool
        package let advertisedCount: Int?
        package let errorMessage: String?
    }

    private var inFlightRefresh: Task<RefreshResult, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    #if DEBUG
        private var testRefreshNowInFlightJoinObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var preferredWorkspacePath: String?
    private var isShutdown = false

    package init(
        client: any CursorACPModelDiscoveryClient,
        registry: Registry,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.registry = registry
        self.intervalNanos = intervalNanos
    }

    package func latestSnapshot() async -> Snapshot? {
        if let latest {
            return latest
        }
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

    @discardableResult
    package func refreshNow(workspacePath: String?) async -> Bool {
        await refreshCatalog(workspacePath: workspacePath).isReady
    }

    package func refreshCatalog(workspacePath: String?) async -> RefreshResult {
        guard !isShutdown else { return .init(isReady: false, advertisedCount: nil, errorMessage: "Cursor discovery is stopped.") }
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

    private func performRefresh() async -> RefreshResult {
        guard !isShutdown else { return .init(isReady: false, advertisedCount: nil, errorMessage: "Cursor discovery is stopped.") }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let task = Task<RefreshResult, Never> { [weak self, workspacePath] in
            guard let self else { return .init(isReady: false, advertisedCount: nil, errorMessage: nil) }
            do {
                let discovered = try await client.discoverModels(workspacePath: workspacePath)
                guard !Task.isCancelled else { return .init(isReady: false, advertisedCount: nil, errorMessage: nil) }
                if let discovered {
                    await applyRefreshResult(discovered)
                    return .init(isReady: true, advertisedCount: discovered.options.count, errorMessage: nil)
                }
                await publishLiveReadinessWithoutModels()
                return .init(isReady: true, advertisedCount: nil, errorMessage: "Cursor returned no model metadata. Previous models were kept.")
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                return .init(isReady: false, advertisedCount: nil, errorMessage: error.localizedDescription)
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func publishLiveReadinessWithoutModels() {
        guard !isShutdown else { return }
        let models = latest?.models
            ?? registry.snapshot()
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
        _ = registry.update(discovered)
        guard let normalized = registry.snapshot() else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await registry.snapshotAfterWarm() else {
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
