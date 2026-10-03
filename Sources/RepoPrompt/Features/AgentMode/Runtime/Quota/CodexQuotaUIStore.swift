import Combine
import Foundation

// SEARCH-HELPER: codex quota UI store, observable quota state, equality gated publication
//
// MainActor projection of Codex quota status.
//
// This is the only quota type that touches the main actor. Transport, decoding, sparse
// merging, and reconciliation all happen inside `CodexProviderQuotaService`; this store
// receives an already-merged immutable snapshot, projects it to compact view state, and
// assigns only when that view state actually changed.
//
// The equality gate is what keeps a chatty provider from invalidating the settings view on
// every notification: identical projected state performs no assignment and therefore
// publishes no `objectWillChange`.

/// Applies the persisted opt-in flag to the live runtime.
///
/// Settings writes arrive from two places — the settings pane and `app_settings` over MCP —
/// and persisting the flag is not the same as applying it. This indirection is the single
/// place that turns a written value into a runtime transition, and it exists as a seam so
/// settings-layer tests can observe that transition without constructing a real Codex
/// transport.
@MainActor
enum CodexUsageQuotaRuntimeBridge {
    static var applyEnabled: (Bool) -> Void = { enabled in
        CodexQuotaUIStore.shared.setEnabled(enabled)
    }
}

@MainActor
final class CodexQuotaUIStore: ObservableObject {
    static let shared = CodexQuotaUIStore()

    @Published private(set) var state: CodexQuotaViewState = .hidden
    @Published private(set) var isRefreshing = false

    /// How often the surface re-projects existing data so relative wording can age.
    /// This performs no provider read and exists only while the surface is on screen.
    ///
    /// `nonisolated` so it can be read from the nonisolated default argument below.
    nonisolated static let freshnessRevalidationInterval: TimeInterval = 60

    private let service: CodexProviderQuotaService
    private let settingsProvider: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    private let freshnessInterval: TimeInterval
    private var observationTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var latestStatus: CodexQuotaStatus = .disabled
    /// Surface lifetime is distinct from the persisted opt-in. MCP may enable the feature
    /// while Settings is closed; that must not create an observer or app-server process.
    private var isActive = false

    init(
        service: CodexProviderQuotaService = .shared,
        settingsProvider: @escaping @MainActor () -> Bool = {
            GlobalSettingsStore.shared.codexUsageQuotaEnabled()
        },
        now: @escaping @Sendable () -> Date = { Date() },
        freshnessInterval: TimeInterval = CodexQuotaUIStore.freshnessRevalidationInterval
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
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
    func activate() {
        isActive = true
        let enabled = settingsProvider()
        Task { [service] in
            await service.setEnabled(enabled)
        }
        guard enabled else {
            stopObserving()
            apply(.disabled)
            return
        }
        startObservingIfNeeded()
        startFreshnessRevalidationIfNeeded()
    }

    /// Called when the surface disappears. Dropping the subscription lets the service tear
    /// down its transport once nothing is observing, and stops all view-lifetime work.
    func deactivate() {
        isActive = false
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
    func setEnabled(_ enabled: Bool) {
        Task { [service] in
            await service.setEnabled(enabled)
        }
        if enabled, isActive {
            startObservingIfNeeded()
            startFreshnessRevalidationIfNeeded()
        } else {
            stopObserving()
            apply(.disabled)
        }
    }

    /// Manual refresh. A hidden (disabled) surface never spends a read.
    func refresh() {
        guard state != .hidden, !isRefreshing, observationTask != nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self, service] in
            await service.refreshNow()
            guard !Task.isCancelled else { return }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }

    func refreshOnForeground() {
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

    private func apply(_ status: CodexQuotaStatus) {
        latestStatus = status
        publish(ProviderQuotaPresenter.viewState(for: status, now: now()))
    }

    /// Re-projects the latest status against the current time so relative wording
    /// ("last seen 3 hours ago") can age without a new provider event.
    func revalidateFreshness() {
        publish(ProviderQuotaPresenter.viewState(for: latestStatus, now: now()))
    }

    /// Equality gate: assigning an identical value would still emit `objectWillChange`,
    /// so the comparison happens before the assignment.
    private func publish(_ newState: CodexQuotaViewState) {
        guard newState != state else { return }
        state = newState
    }
}
