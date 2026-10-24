import Combine
import Foundation
import RepoPromptProviderQuota

/// Tiny equality-gated projection. Percent is rounded before publication; reset and
/// observation times are rounded to a minute. Model-scoped and anonymous readings never
/// become a plan pill.
///
/// Freshness is explicit state, not absence: an aged or reset-passed reading keeps its last
/// figure (dimmed by the pill) instead of disappearing, and a cleared snapshot after a value
/// was shown becomes the neutral `.unavailable` state rather than removing the pill.
package struct ProviderQuotaIndicatorState: Equatable {
    package enum Freshness: Equatable {
        /// At least one account-wide value is within its window's horizon.
        case fresh
        /// Every account-wide value aged past its window's horizon.
        case stale
        /// A window's declared reset passed and nothing newer has been read.
        case resetPassed
        /// A value was shown before, but there is no snapshot for the current account now
        /// (account change, sign-out, consent/sign-in required, read failed with no prior
        /// value). Rendered as a neutral "—".
        case unavailable
    }

    /// The account-wide (longest declared) window. This is the pill's printed figure.
    package let usedPercent: Int?
    package let isReached: Bool
    package let resetAt: Date?
    /// A shorter rolling window (e.g. Claude's 5-hour limit) shown as a secondary marker.
    /// Nil when the provider declares only one window.
    package let shortWindowPercent: Int?
    package let shortWindowIsReached: Bool
    package let shortWindowResetAt: Date?
    /// Newest contributing observation, rounded down to the minute.
    package let observedAt: Date?
    package let freshness: Freshness
    /// A read (automatic or user-initiated) is in flight; the value stays in place.
    package var isUpdating: Bool
    /// The latest read failed; the figure is the previous snapshot's.
    package var refreshFailed: Bool

    package init(
        usedPercent: Int?,
        isReached: Bool,
        resetAt: Date?,
        shortWindowPercent: Int? = nil,
        shortWindowIsReached: Bool = false,
        shortWindowResetAt: Date? = nil,
        observedAt: Date? = nil,
        freshness: Freshness = .fresh,
        isUpdating: Bool = false,
        refreshFailed: Bool = false
    ) {
        self.usedPercent = usedPercent
        self.isReached = isReached
        self.resetAt = resetAt
        self.shortWindowPercent = shortWindowPercent
        self.shortWindowIsReached = shortWindowIsReached
        self.shortWindowResetAt = shortWindowResetAt
        self.observedAt = observedAt
        self.freshness = freshness
        self.isUpdating = isUpdating
        self.refreshFailed = refreshFailed
    }

    package static let unavailable = Self(usedPercent: nil, isReached: false, resetAt: nil, freshness: .unavailable)

    /// Fresh account-wide values win. Only when none is fresh does the projection fall back to
    /// the aged/reset-passed values, marked as such, so the pill never vanishes for age alone.
    package static func project(_ snapshot: ProviderQuotaSnapshot, now: Date) -> Self? {
        let valued = ProviderUsageSignal.readings(from: snapshot, now: now, maximumObservationAge: nil).filter {
            $0.scope == .accountWide && $0.headroom != .unknown
        }
        let fresh = valued.filter(\.availability.isFresh)
        let signals = fresh.isEmpty ? valued : fresh
        let reached = signals.first { $0.headroom == .reached }
        let readings = signals.compactMap { signal -> WindowReading? in
            switch signal.headroom {
            case .reached:
                return WindowReading(used: nil, reached: true, reset: signal.resetsAt, duration: signal.windowDuration)
            case let .remainingPercent(remaining):
                let used = 100 - remaining
                guard used.isFinite, used > Double(Int.min), used < Double(Int.max) else { return nil }
                return WindowReading(used: used, reached: false, reset: signal.resetsAt, duration: signal.windowDuration)
            case .unknown:
                return nil
            }
        }
        // Primary = the longest declared window (account-wide budget). Without durations we
        // cannot tell windows apart, so fall back to the most-used one.
        let withDuration = readings.filter { $0.duration != nil }
        let primaryDuration = withDuration.compactMap(\.duration).max()
        let primaryPool = primaryDuration.map { d in readings.filter { $0.duration == d } } ?? readings
        let numeric = primaryPool.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) }
            ?? readings.filter { $0.used != nil }.max { ($0.used ?? 0) < ($1.used ?? 0) }
        let short: WindowReading? = primaryDuration.flatMap { primary in
            let shorter = withDuration.filter { ($0.duration ?? primary) < primary }
            guard let shortest = shorter.compactMap(\.duration).min() else { return nil }
            let pool = shorter.filter { $0.duration == shortest }
            return pool.first(where: \.reached) ?? pool.max { ($0.used ?? 0) < ($1.used ?? 0) }
        }
        guard reached != nil || numeric != nil else { return nil }
        let reset = reached?.resetsAt ?? numeric?.reset
        let freshness: Freshness = if !fresh.isEmpty {
            .fresh
        } else if signals.contains(where: { if case .stale(_, .resetElapsed) = $0.availability { true } else { false } }) {
            .resetPassed
        } else {
            .stale
        }
        return Self(
            usedPercent: numeric?.used.map { Int($0.rounded()) },
            isReached: reached != nil,
            resetAt: reset.map(minute),
            shortWindowPercent: short?.used.map { Int($0.rounded()) },
            shortWindowIsReached: short?.reached ?? false,
            shortWindowResetAt: short?.reset.map(minute),
            observedAt: signals.compactMap(\.availability.observedAt).max().map(minute),
            freshness: freshness
        )
    }

    private struct WindowReading {
        let used: Double?
        let reached: Bool
        let reset: Date?
        let duration: TimeInterval?
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}

/// The parent status row does not observe quota. Only its child pill observes this object.
/// All surfaces reuse the provider UI store's single subscription/freshness task.
///
/// Hide reasons — the pill renders nothing only when:
///  (a) the user turned usage display off, or the usage source is disabled / not set up
///      (the UI store applies `.disabled`, which clears the indicator), or
///  (b) the selected agent has no usage target (`ProviderQuotaSettingsTarget(agent:)` is nil,
///      decided by the status row before this store is consulted), or
///  (c) no value has ever been observed (nothing to keep yet).
/// Once shown, staleness, passed resets, in-flight refreshes, failed reads, and account
/// changes only change `state`'s freshness/flags; they never make it nil.
@MainActor
package final class ProviderQuotaIndicatorStore: ObservableObject {
    @Published package private(set) var state: ProviderQuotaIndicatorState?
    private let store: ProviderQuotaUIStore
    private var observation: AnyCancellable?
    package init(store: ProviderQuotaUIStore) {
        self.store = store
        state = store.indicatorState
        observation = store.$indicatorState.removeDuplicates().sink { [weak self] value in
            guard self?.state != value else { return }
            self?.state = value
        }
    }

    package func activate(surfaceID: UUID) {
        store.activate(surfaceID: surfaceID)
    }

    package func deactivate(surfaceID: UUID) {
        store.deactivate(surfaceID: surfaceID)
    }

    /// The pill's "Refresh usage" action: the same user-initiated path as Settings → Refresh.
    package func refresh() {
        store.refresh()
    }
}
