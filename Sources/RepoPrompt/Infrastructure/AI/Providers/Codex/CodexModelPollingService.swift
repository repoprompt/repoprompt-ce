import Foundation

protocol CodexModelListingClient: Sendable {
    func listModels(limit: Int) async throws -> [CodexAppServerClient.RemoteModel]
    func stop() async
    func currentProcessSnapshot() async -> CodexAppServerClient.ProcessSnapshot?
}

extension CodexAppServerClient: CodexModelListingClient {}

// SEARCH-HELPER: Codex model polling, centralized, shared client, model list, subscribe
/// Centralized polling service for Codex dynamic models.
///
/// Replaces duplicated polling logic previously spread across:
/// - `CodexAgentModeCoordinator`
/// - `ContextBuilderAgentViewModel`
/// - `APISettingsViewModel` (one-shot refresh)
///
/// Owns:
/// - A single polling loop using a dedicated `CodexAppServerClient`
/// - Broadcasting model snapshots to subscribers via `AsyncStream`
/// - Updating `AgentCodexModelRegistry` as the single canonical writer
///
/// Related:
/// - CodexProviderHelpers.makeOwnedNonAgentAppServerClient() (dedicated polling transport)
/// - AgentCodexModelRegistry (canonical registry updated by this service)
/// - AgentModelCatalog (consumes registry for model option resolution)
actor CodexModelPollingService {
    static let shared = CodexModelPollingService(
        client: CodexProviderHelpers.makeOwnedNonAgentAppServerClient(),
        stopClientOnShutdown: true,
        stopClientWhenIdle: true,
        stopClientAfterRefresh: true
    )

    struct Snapshot: Equatable {
        let models: [CodexAppServerClient.RemoteModel]
        let fetchedAt: Date
    }

    struct RuntimeSnapshot: Equatable {
        let subscriberCount: Int
        let isPolling: Bool
        let hasInFlightRefresh: Bool
        let isShutdown: Bool
        let latestFetchedAt: Date?
        let processSnapshot: CodexAppServerClient.ProcessSnapshot?
    }

    private let client: any CodexModelListingClient
    private let intervalNanos: UInt64
    private let stopClientOnShutdown: Bool
    private let stopClientWhenIdle: Bool
    private let stopClientAfterRefresh: Bool

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    #if DEBUG
        private var testSubscriberCountObservers: [UUID: AsyncStream<Int>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var isShutdown = false
    private var isStoppingClientForIdle = false
    private var inFlightRefreshNeedsInterrupt = false

    init(
        client: any CodexModelListingClient,
        intervalNanos: UInt64 = 60_000_000_000,
        stopClientOnShutdown: Bool = false,
        stopClientWhenIdle: Bool = false,
        stopClientAfterRefresh: Bool = false
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
        self.stopClientOnShutdown = stopClientOnShutdown
        self.stopClientWhenIdle = stopClientWhenIdle
        self.stopClientAfterRefresh = stopClientAfterRefresh
    }

    /// Returns the most recent snapshot if available (non-blocking).
    func latestSnapshot() -> Snapshot? {
        latest
    }

    func runtimeSnapshot() async -> RuntimeSnapshot {
        await RuntimeSnapshot(
            subscriberCount: continuations.count,
            isPolling: pollingTask != nil,
            hasInFlightRefresh: inFlightRefresh != nil,
            isShutdown: isShutdown,
            latestFetchedAt: latest?.fetchedAt,
            processSnapshot: client.currentProcessSnapshot()
        )
    }

    #if DEBUG
        func test_subscriberCount() -> Int {
            continuations.count
        }

        func test_subscriberCountUpdates() -> AsyncStream<Int> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testSubscriberCountObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestSubscriberCountObserver(id) }
            }
            continuation.yield(continuations.count)
            return stream
        }
    #endif

    /// Subscribe to model snapshot updates.
    ///
    /// - Immediately yields the latest snapshot if one exists.
    /// - Starts the polling loop if not already running.
    /// - When the last subscriber detaches, the polling loop is cancelled.
    func subscribe() -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        #if DEBUG
            publishTestSubscriberCount()
        #endif

        // Yield latest immediately so UI populates without waiting for the first tick.
        if let latest {
            continuation.yield(latest)
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        startPollingIfNeeded()
        return stream
    }

    /// Force an immediate model refresh (e.g. after connectivity test succeeds).
    /// Updates the registry and only broadcasts when the normalized model payload changes.
    /// Coalesces with any in-flight refresh to avoid overlapping network/process calls.
    func refreshNow() async {
        guard !isShutdown else { return }
        if let existing = inFlightRefresh {
            await existing.value
            return
        }
        await performRefresh()
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        let shouldInterruptRefresh = inFlightRefresh != nil
            && inFlightRefreshNeedsInterrupt
            && stopClientOnShutdown
        if shouldInterruptRefresh {
            await stopClientWithoutInheritingCancellation()
        }
        if let inFlightRefresh {
            await inFlightRefresh.value
        }
        inFlightRefresh = nil
        inFlightRefreshNeedsInterrupt = false
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            #if DEBUG
                publishTestSubscriberCount()
            #endif
            for continuation in activeContinuations.values {
                continuation.finish()
            }
        }
        if stopClientOnShutdown, !shouldInterruptRefresh {
            await stopClientWithoutInheritingCancellation()
        }
    }

    // MARK: - Internal

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard !isStoppingClientForIdle else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() async {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
        guard stopClientWhenIdle else { return }
        guard !isStoppingClientForIdle else { return }

        isStoppingClientForIdle = true
        let shouldInterruptRefresh = inFlightRefresh != nil && inFlightRefreshNeedsInterrupt
        if shouldInterruptRefresh {
            await stopClientWithoutInheritingCancellation()
        }
        if let inFlightRefresh {
            await inFlightRefresh.value
        }
        if !stopClientAfterRefresh, !shouldInterruptRefresh {
            await stopClientWithoutInheritingCancellation()
        }
        isStoppingClientForIdle = false

        if !isShutdown, !continuations.isEmpty {
            startPollingIfNeeded()
        }
    }

    private func removeSubscriber(_ id: UUID) async {
        continuations.removeValue(forKey: id)
        #if DEBUG
            publishTestSubscriberCount()
        #endif
        await stopPollingIfIdle()
    }

    #if DEBUG
        private func publishTestSubscriberCount() {
            for continuation in testSubscriberCountObservers.values {
                continuation.yield(continuations.count)
            }
        }

        private func removeTestSubscriberCountObserver(_ id: UUID) {
            testSubscriberCountObservers.removeValue(forKey: id)
        }
    #endif

    private func performRefresh() async {
        guard !isShutdown else { return }
        // Single-flight: if a refresh is already running, await it instead of starting another.
        if let existing = inFlightRefresh {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await client.listModels(limit: 100)
                let snapshot = Snapshot(models: models, fetchedAt: Date())
                await applyRefreshResult(snapshot)
            } catch {
                // Keep existing cache when refresh fails; callers fall back to static list when empty.
            }
            let shouldStopClient = await finishRefreshRequest()
            // Refresh and transport shutdown are one lifecycle operation. Keeping the stop in
            // this task prevents refreshNow(), subscriber removal, and the next polling tick from
            // observing a completed refresh while the app-server is still being stopped.
            if shouldStopClient {
                await client.stop()
            }
        }
        inFlightRefreshNeedsInterrupt = true
        inFlightRefresh = task
        defer {
            inFlightRefresh = nil
            inFlightRefreshNeedsInterrupt = false
        }
        await task.value
    }

    private func stopClientWithoutInheritingCancellation() async {
        let stopTask = Task { [client] in
            await client.stop()
        }
        await stopTask.value
    }

    private func finishRefreshRequest() -> Bool {
        inFlightRefreshNeedsInterrupt = false
        return stopClientAfterRefresh && !isStoppingClientForIdle && !isShutdown
    }

    private func applyRefreshResult(_ snapshot: Snapshot) {
        guard !isShutdown else { return }

        // Single canonical registry update — no other call site should write to the registry.
        let didChange = AgentCodexModelRegistry.shared.updateLiveModels(snapshot.models)
        guard didChange else { return }
        latest = snapshot

        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
