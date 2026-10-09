import Foundation

/// Shared observation seam. Acquisition remains provider-owned; consumers never need a
/// conversation, token counter, routing policy, or concrete provider transport.
package protocol ProviderQuotaObserving: Sendable {
    func subscribe() async -> AsyncStream<ProviderQuotaStatus>
    func setEnabled(_ enabled: Bool) async
    func refreshNow() async
    func refreshOnForeground() async
    /// Cached, non-acquiring lookup. Implementations must never start IO here.
    func latestSnapshot() async -> ProviderQuotaSnapshot?
}

package extension ProviderQuotaObserving {
    func latestSnapshot() async -> ProviderQuotaSnapshot? {
        nil
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
