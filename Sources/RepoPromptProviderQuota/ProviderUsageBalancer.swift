import Foundation

/// Provider-neutral description of one routable model option, sufficient for usage balancing.
/// Callers adapt their own routing candidates into this shape; no app routing types leak in.
package struct ProviderUsageModelOption: Equatable {
    /// Key used to attribute quota snapshots (for example the agent provider raw value).
    package var provider: String
    /// Options sharing a peer class are considered comparable; `nil` never balances.
    package var peerClass: String?
    /// Native model aliases whose model-scoped quota buckets apply to this option.
    package var modelAliases: Set<String>
    /// Paid "Fast" options are never chosen by balancing.
    package var isPaidFast: Bool

    package init(provider: String, peerClass: String?, modelAliases: Set<String>, isPaidFast: Bool) {
        self.provider = provider
        self.peerClass = peerClass
        self.modelAliases = modelAliases
        self.isPaidFast = isPaidFast
    }
}

/// Attributed memory cache over `ProviderUsageBalancePolicy`. No provider IO, timer, or external disclosure.
@MainActor
package final class ProviderUsageBalancer {
    private var snapshots: [String: ProviderQuotaSnapshot] = [:]
    /// Invoked only when a balanceable peer exists, so callers can schedule a bounded refresh.
    package var onRoutingActivity: (() -> Void)?

    package init() {}

    package func update(_ snapshot: ProviderQuotaSnapshot?, provider: String) {
        snapshots[provider] = snapshot
    }

    package func clear() {
        snapshots.removeAll()
    }

    /// Returns the index in `options` of the comparable peer to use instead of `selected`, or `nil` to keep it.
    /// Identical inputs always yield the same answer.
    package func preferredPeerIndex(
        selected: ProviderUsageModelOption,
        options: [ProviderUsageModelOption],
        strategy: ProviderUsageBalancePolicy.Strategy,
        now: Date = Date()
    ) -> Int? {
        guard let peerClass = selected.peerClass,
              let index = options.firstIndex(where: {
                  $0.peerClass == peerClass && $0.provider != selected.provider && !$0.isPaidFast
              }) else { return nil }
        // Only a balanceable decision justifies refreshing usage readings.
        onRoutingActivity?()
        let preferPeer = ProviderUsageBalancePolicy.preferPeer(
            base: reading(for: selected, now: now),
            peer: reading(for: options[index], now: now),
            strategy: strategy
        )
        return preferPeer ? index : nil
    }

    private func reading(for option: ProviderUsageModelOption, now: Date) -> ProviderUsageBalancePolicy.Reading {
        ProviderUsageBalancePolicy.reading(snapshots[option.provider], now: now, modelAliases: option.modelAliases)
    }
}
