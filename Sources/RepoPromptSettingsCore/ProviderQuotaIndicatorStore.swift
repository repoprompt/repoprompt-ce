import Combine
import Foundation
import RepoPromptProviderQuota

/// Tiny equality-gated projection. Percent is rounded before publication; reset is rounded
/// to a minute. Model-scoped, anonymous, unknown and stale readings never become a plan pill.
package struct ProviderQuotaIndicatorState: Equatable {
    package let usedPercent: Int?
    package let isReached: Bool
    package let resetAt: Date?

    package static func project(_ snapshot: ProviderQuotaSnapshot, now: Date) -> Self? {
        let signals = ProviderUsageSignal.readings(from: snapshot, now: now, maximumObservationAge: nil).filter {
            $0.scope == .accountWide && $0.availability.isFresh
        }
        let reached = signals.first { $0.headroom == .reached }
        let numeric = signals.compactMap { signal -> (Double, Date?)? in
            guard case let .remainingPercent(remaining) = signal.headroom else { return nil }
            let used = 100 - remaining
            guard used.isFinite, used > Double(Int.min), used < Double(Int.max) else { return nil }
            return (used, signal.resetsAt)
        }.max { $0.0 < $1.0 }
        guard reached != nil || numeric != nil else { return nil }
        let reset = reached?.resetsAt ?? numeric?.1
        return Self(
            usedPercent: numeric.map { Int($0.0.rounded()) },
            isReached: reached != nil,
            resetAt: reset.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970 / 60) * 60) }
        )
    }
}

/// The parent status row does not observe quota. Only its child pill observes this object.
/// All surfaces reuse the provider UI store's single subscription/freshness task.
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
}
