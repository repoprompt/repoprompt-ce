import Combine
import Foundation
import RepoPromptProviderQuota

// SEARCH-HELPER: provider quota UI store, observable quota state, equality gated publication
//
// MainActor projection of provider quota status.
//
// Transport, decoding, merging, and reconciliation happen inside provider services;
// this main-actor store
// receives an already-merged immutable snapshot, projects it to compact view state, and
// assigns only when that view state actually changed.
//
// The equality gate is what keeps a chatty provider from invalidating the settings view on
// every notification: identical projected state performs no assignment and therefore
// publishes no `objectWillChange`.

@MainActor
package final class ProviderQuotaUIStore: ObservableObject {
    @Published package private(set) var state: ProviderQuotaViewState = .hidden
    @Published package private(set) var isRefreshing = false
    @Published package private(set) var indicatorState: ProviderQuotaIndicatorState?

    /// How often the surface re-projects existing data so relative wording can age.
    /// This performs no provider read and exists only while the surface is on screen.
    ///
    /// `nonisolated` so it can be read from the nonisolated default argument below.
    package nonisolated static let freshnessRevalidationInterval: TimeInterval = 60

    private let service: any ProviderQuotaObserving
    private let settingsProvider: @MainActor () -> Bool
    private let presentationProvider: @MainActor () -> Bool
    private var presentationEnabled: Bool?
    private let now: @Sendable () -> Date
    private let freshnessInterval: TimeInterval
    private var observationTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var latestStatus: ProviderQuotaStatus = .disabled
    /// Surface lifetime is distinct from the persisted opt-in. MCP may enable the feature
    /// while Settings is closed; that must not create an observer or app-server process.
    private let defaultSurfaceID = UUID()
    private var activeSurfaceIDs: Set<UUID> = []
    private var isActive: Bool {
        !activeSurfaceIDs.isEmpty
    }

    package init(
        service: any ProviderQuotaObserving,
        settingsProvider: @escaping @MainActor () -> Bool,
        presentationProvider: @escaping @MainActor () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date() },
        freshnessInterval: TimeInterval = ProviderQuotaUIStore.freshnessRevalidationInterval
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
        self.presentationProvider = presentationProvider
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    deinit {
        observationTask?.cancel()
        freshnessTask?.cancel()
        refreshTask?.cancel()
    }

    /// Called when the surface appears. Applies the current opt-in setting and starts
    /// observing only when enabled — a disabled feature starts no transport at all.
    package func activate(surfaceID: UUID? = nil) {
        activeSurfaceIDs.insert(surfaceID ?? defaultSurfaceID)
        let enabled = settingsProvider()
        Task { [service] in
            await service.setEnabled(enabled)
        }
        guard enabled, presentationEnabled ?? presentationProvider() else {
            stopObserving()
            apply(.disabled)
            return
        }
        startObservingIfNeeded()
        startFreshnessRevalidationIfNeeded()
    }

    /// Called when the surface disappears. Dropping the subscription lets the service tear
    /// down its transport once nothing is observing, and stops all view-lifetime work.
    package func deactivate(surfaceID: UUID? = nil) {
        activeSurfaceIDs.remove(surfaceID ?? defaultSurfaceID)
        // The shared projection may be visible in several windows. One disappearing
        // surface must not retire the remaining surface's observation/freshness tasks.
        guard !isActive else { return }
        stopObserving()
    }

    /// Cancels every view-lifetime task and releases the refresh latch, so a surface that
    /// disappears mid-refresh does not reappear stuck in a spinner.
    private func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        freshnessTask?.cancel()
        freshnessTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    /// Reflects a settings toggle without requiring the view to be rebuilt.
    package func setEnabled(_ enabled: Bool) {
        Task { [service] in
            await service.setEnabled(enabled)
        }
        if enabled, isActive, presentationEnabled ?? presentationProvider() {
            startObservingIfNeeded()
            startFreshnessRevalidationIfNeeded()
        } else {
            stopObserving()
            apply(.disabled)
        }
    }

    /// Presentation never changes acquisition consent. Hiding releases observation without
    /// clearing the provider's cache or granting/revoking credentials.
    package func setPresentationEnabled(_ enabled: Bool) {
        presentationEnabled = enabled
        if enabled, isActive, settingsProvider() {
            startObservingIfNeeded()
            startFreshnessRevalidationIfNeeded()
        } else {
            stopObserving()
            apply(.disabled)
        }
    }

    /// Manual refresh. A hidden (disabled) surface never spends a read.
    package func refresh() {
        guard state != .hidden, !isRefreshing, observationTask != nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self, service] in
            await service.refreshNow()
            guard !Task.isCancelled else { return }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }

    package func refreshOnForeground() {
        guard isActive, observationTask != nil else { return }
        Task { [service] in
            await service.refreshOnForeground()
        }
    }

    /// Re-projects existing data on a slow cadence so "last seen 3 hours ago" can age while
    /// the surface is open.
    ///
    /// Deliberately not a poll: it never touches the service, issues no provider read, and
    /// its only effect is an equality-gated re-projection. When nothing changed — the common
    /// case — `publish` performs no assignment, so this cannot fan out view invalidation.
    private func startFreshnessRevalidationIfNeeded() {
        guard freshnessTask == nil, freshnessInterval > 0 else { return }
        freshnessTask = Task { [weak self, freshnessInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(freshnessInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                revalidateFreshness()
            }
        }
    }

    private func startObservingIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, service] in
            let stream = await service.subscribe()
            for await status in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                apply(status)
            }
        }
    }

    private func apply(_ status: ProviderQuotaStatus) {
        latestStatus = status
        publish(ProviderQuotaPresenter.viewState(for: status, now: now()))
        publishIndicator()
    }

    /// Re-projects the latest status against the current time so relative wording
    /// ("last seen 3 hours ago") can age without a new provider event.
    package func revalidateFreshness() {
        publish(ProviderQuotaPresenter.viewState(for: latestStatus, now: now()))
        publishIndicator()
    }

    private func publishIndicator() {
        let projected: ProviderQuotaIndicatorState? = if case let .loaded(snapshot) = latestStatus {
            ProviderQuotaIndicatorState.project(snapshot, now: now())
        } else { nil }
        if projected != indicatorState { indicatorState = projected }
    }

    /// Equality gate: assigning an identical value would still emit `objectWillChange`,
    /// so the comparison happens before the assignment.
    private func publish(_ newState: ProviderQuotaViewState) {
        guard newState != state else { return }
        state = newState
    }
}
