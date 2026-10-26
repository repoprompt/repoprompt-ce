import Foundation

/// Shared observation seam. Acquisition remains provider-owned; consumers never need a
/// conversation, token counter, routing policy, or concrete provider transport.
package protocol ProviderQuotaObserving: Sendable {
    func subscribe() async -> AsyncStream<ProviderQuotaStatus>
    func setEnabled(_ enabled: Bool) async
    func refreshNow() async
    func refreshOnForeground() async
    /// Display-driven refresh for a reading the caller has already judged stale.
    ///
    /// Not a user action: implementations apply their automatic admission (minimum gap
    /// between automatic attempts, failure backoff, single flight) and never bypass it.
    /// `didStart` runs only when a read is actually admitted, after it is registered as in
    /// flight, so a surface shows "updating" only for real work and never for a rejected tick.
    func refreshAutomatically(didStart: (@Sendable () async -> Void)?) async
    /// Cached, non-acquiring lookup. Implementations must never start IO here.
    func latestSnapshot() async -> ProviderQuotaSnapshot?
}

package extension ProviderQuotaObserving {
    func latestSnapshot() async -> ProviderQuotaSnapshot? {
        nil
    }

    /// Default: a source without its own automatic gate treats a stale-driven refresh as a
    /// foreground trigger, which is already bounded by that source's own admission.
    func refreshAutomatically(didStart _: (@Sendable () async -> Void)?) async {
        await refreshOnForeground()
    }
}

/// Equality-gated, in-memory status for any quota provider.
package enum ProviderQuotaStatus: Equatable {
    case disabled
    case idle
    case loading
    case loaded(ProviderQuotaSnapshot)
    case unavailable(reason: String)
    case failed(reason: String, previous: ProviderQuotaSnapshot?)
}
