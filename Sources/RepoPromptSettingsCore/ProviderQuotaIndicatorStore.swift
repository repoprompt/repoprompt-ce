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

    package let usedPercent: Int?
    package let isReached: Bool
    package let resetAt: Date?
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
        observedAt: Date? = nil,
        freshness: Freshness = .fresh,
        isUpdating: Bool = false,
        refreshFailed: Bool = false
    ) {
        self.usedPercent = usedPercent
        self.isReached = isReached
        self.resetAt = resetAt
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
        let numeric = signals.compactMap { signal -> (Double, Date?)? in
            guard case let .remainingPercent(remaining) = signal.headroom else { return nil }
            let used = 100 - remaining
            guard used.isFinite, used > Double(Int.min), used < Double(Int.max) else { return nil }
            return (used, signal.resetsAt)
        }.max { $0.0 < $1.0 }
        guard reached != nil || numeric != nil else { return nil }
        let reset = reached?.resetsAt ?? numeric?.1
        let freshness: Freshness = if !fresh.isEmpty {
            .fresh
        } else if signals.contains(where: { if case .stale(_, .resetElapsed) = $0.availability { true } else { false } }) {
            .resetPassed
        } else {
            .stale
        }
        return Self(
            usedPercent: numeric.map { Int($0.0.rounded()) },
            isReached: reached != nil,
            resetAt: reset.map(minute),
            observedAt: signals.compactMap(\.availability.observedAt).max().map(minute),
            freshness: freshness
        )
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
