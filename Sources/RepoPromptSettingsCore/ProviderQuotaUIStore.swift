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
//
// Indicator stickiness: once `indicatorState` is non-nil it only becomes nil again through
// `.disabled` (display off, or the usage source disabled / not set up). Aging, passed
// resets, refreshes, failed reads, and cleared snapshots change its freshness and flags.
//
// Stale refresh: the existing freshness tick (one per provider, only while a surface is
// leased) asks the service for an *automatic* refresh when the displayed account-wide
// windows are stale or reset-passed, or the last read failed with a previous value. The
// service owns admission (gap between automatic attempts, failure backoff, single flight);
// this store only adds its own one-request-in-flight guard.
//
// Display overlay: passive Claude SDK telemetry may refresh the *displayed* snapshot via
// `applyDisplayOverlay`. It is projection-only; the service snapshot, routing observation,
// and balancing policy never see it.

@MainActor
package final class ProviderQuotaUIStore: ObservableObject {
    @Published package private(set) var state: ProviderQuotaViewState = .hidden
    @Published package private(set) var isRefreshing = false
    @Published package private(set) var indicatorState: ProviderQuotaIndicatorState?

    /// How often the surface re-projects existing data so relative wording can age, and checks
    /// whether the displayed reading has aged enough to request an automatic refresh (which
    /// the service admission-gates). Exists only while a surface is on screen.
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
    private var automaticRefreshTask: Task<Void, Never>?
    private var automaticRefreshID: UUID?
    /// True only after the service admitted an automatic read (not for a rejected request).
    private var automaticReadInFlight = false
    private var latestStatus: ProviderQuotaStatus = .disabled
    private var displayOverlay: ProviderQuotaSnapshot?
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
        automaticRefreshTask?.cancel()
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
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        automaticRefreshID = nil
        automaticReadInFlight = false
        publishIndicator()
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

    /// Manual refresh (Settings → Refresh, pill → Refresh usage). A hidden (disabled) surface
    /// never spends a read. Stale, failed, and unavailable states are not hidden, so the user
    /// can always retry; the service still applies its manual interval and single flight.
    package func refresh() {
        guard state != .hidden, !isRefreshing, observationTask != nil else { return }
        isRefreshing = true
        publishIndicator()
        refreshTask = Task { [weak self, service] in
            await service.refreshNow()
            guard !Task.isCancelled else { return }
            self?.isRefreshing = false
            self?.refreshTask = nil
            self?.publishIndicator()
        }
    }

    /// App foreground. A stale display goes through the same automatic gate as the freshness
    /// tick (so a one-shot source is no longer a no-op here); a fresh one keeps the source's
    /// own bounded foreground behavior.
    package func refreshOnForeground() {
        guard isActive, observationTask != nil else { return }
        if Self.needsAutomaticRefresh(displayStatus, now: now()) {
            requestAutomaticRefreshIfNeeded()
            return
        }
        Task { [service] in
            await service.refreshOnForeground()
        }
    }

    /// Passive telemetry for display only (see file header). `nil` clears it.
    package func applyDisplayOverlay(_ overlay: ProviderQuotaSnapshot?) {
        guard overlay != displayOverlay else { return }
        displayOverlay = overlay
        publish(ProviderQuotaPresenter.viewState(for: displayStatus, now: now()))
        publishIndicator()
    }

    /// Re-projects existing data on a slow cadence so "last seen 3 hours ago" can age while
    /// the surface is open.
    ///
    /// Not a poll: a tick with a fresh reading never touches the service; its only effect is
    /// an equality-gated re-projection. When nothing changed — the common case — `publish`
    /// performs no assignment, so this cannot fan out view invalidation. Only an aged or
    /// failed reading turns a tick into an automatic refresh request, which the service
    /// gates (15-minute gap for Claude, 5 minutes for Codex, backoff, single flight).
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
        // A cleared snapshot (account change, sign-out, disable) retires any overlay with it.
        if Self.snapshot(of: status) == nil { displayOverlay = nil }
        publish(ProviderQuotaPresenter.viewState(for: displayStatus, now: now()))
        publishIndicator()
    }

    /// Re-projects the latest status against the current time so relative wording
    /// ("last seen 3 hours ago") can age without a new provider event, then asks for an
    /// automatic refresh if the displayed reading has aged. The projection itself never
    /// touches the service; the refresh request is admission-gated by the service.
    package func revalidateFreshness() {
        publish(ProviderQuotaPresenter.viewState(for: displayStatus, now: now()))
        publishIndicator()
        requestAutomaticRefreshIfNeeded()
    }

    /// The provider status with any display overlay applied.
    private var displayStatus: ProviderQuotaStatus {
        guard let displayOverlay else { return latestStatus }
        switch latestStatus {
        case let .loaded(snapshot):
            return .loaded(ProviderQuotaDisplayOverlay.merge(displayOverlay, onto: snapshot))
        case let .failed(reason, previous?):
            return .failed(reason: reason, previous: ProviderQuotaDisplayOverlay.merge(displayOverlay, onto: previous))
        default:
            return latestStatus
        }
    }

    private func requestAutomaticRefreshIfNeeded() {
        guard isActive, observationTask != nil, automaticRefreshTask == nil, !isRefreshing,
              Self.needsAutomaticRefresh(displayStatus, now: now()) else { return }
        let id = UUID()
        automaticRefreshID = id
        automaticRefreshTask = Task { [weak self, service] in
            await service.refreshAutomatically(didStart: { [weak self] in
                await self?.automaticReadStarted(id)
            })
            self?.automaticRefreshFinished(id)
        }
    }

    private func automaticReadStarted(_ id: UUID) {
        guard automaticRefreshID == id else { return }
        automaticReadInFlight = true
        publishIndicator()
    }

    private func automaticRefreshFinished(_ id: UUID) {
        guard automaticRefreshID == id else { return }
        automaticRefreshID = nil
        automaticRefreshTask = nil
        automaticReadInFlight = false
        publishIndicator()
    }

    /// Stale or reset-passed account-wide windows, or a failed read that still has a value.
    package static func needsAutomaticRefresh(_ status: ProviderQuotaStatus, now: Date) -> Bool {
        switch status {
        case let .loaded(snapshot):
            ProviderUsageSignal.readings(from: snapshot, now: now, maximumObservationAge: nil).contains {
                $0.scope == .accountWide && !$0.availability.isFresh
            }
        case .failed(_, .some):
            true
        default:
            false
        }
    }

    private static func snapshot(of status: ProviderQuotaStatus) -> ProviderQuotaSnapshot? {
        switch status {
        case let .loaded(snapshot): snapshot
        case let .failed(_, previous): previous
        default: nil
        }
    }

    /// Sticky projection. See `ProviderQuotaIndicatorStore` for the hide reasons; only
    /// `.disabled` clears a shown indicator.
    private func publishIndicator() {
        let status = displayStatus
        let wasShown = indicatorState != nil
        var projected: ProviderQuotaIndicatorState?
        switch status {
        case .disabled:
            projected = nil
        case let .loaded(snapshot):
            projected = ProviderQuotaIndicatorState.project(snapshot, now: now()) ?? (wasShown ? .unavailable : nil)
        case let .failed(_, previous?):
            projected = ProviderQuotaIndicatorState.project(previous, now: now()) ?? (wasShown ? .unavailable : nil)
            projected?.refreshFailed = true
        case .idle, .loading, .unavailable, .failed(_, .none):
            projected = wasShown ? .unavailable : nil
        }
        projected?.isUpdating = isRefreshing || automaticReadInFlight || status == .loading
        if projected != indicatorState { indicatorState = projected }
    }

    /// Equality gate: assigning an identical value would still emit `objectWillChange`,
    /// so the comparison happens before the assignment.
    private func publish(_ newState: ProviderQuotaViewState) {
        guard newState != state else { return }
        state = newState
    }
}
