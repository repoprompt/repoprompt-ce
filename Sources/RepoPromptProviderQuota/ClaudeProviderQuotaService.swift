import Foundation

/// Passive, observe-only SDK telemetry. Starts no process, request, polling or conversation.
/// SDK events have no account ID, so only the latest reporting run may contribute; never
/// aggregate unrelated sessions/accounts. Disabling invalidates every in-flight producer.
package actor ClaudeRunRateLimitTelemetryService: ProviderQuotaObserving {
    package init() {}

    private var enabled = false
    private var producerLease: UUID?
    private var snapshot: ProviderQuotaSnapshot?
    private var status: ProviderQuotaStatus = .disabled
    private var subscribers: [UUID: AsyncStream<ProviderQuotaStatus>.Continuation] = [:]

    package func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        producerLease = nil
        snapshot = nil
        publish(enabled ? .idle : .disabled)
    }

    /// Called once for an already-authorized first-party Claude run. A replacement run
    /// retires older producers. Compatible backends must never call this seam.
    package func beginObservation() -> UUID? {
        guard enabled else { return nil }
        let lease = UUID()
        producerLease = lease
        snapshot = nil
        publish(.idle)
        return lease
    }

    package func observe(_ info: ClaudeProviderQuotaObservation, lease: UUID, observedAt: Date) {
        guard enabled, producerLease == lease,
              let delta = ClaudeProviderQuotaMapper.delta(from: info, observedAt: observedAt)
        else { return }
        if case let .merged(merged) = ProviderQuotaMerge.apply(delta, to: snapshot) {
            snapshot = merged
            publish(.loaded(merged))
        }
    }

    package func subscribe() -> AsyncStream<ProviderQuotaStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ProviderQuotaStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// A headless SDK has no independent quota-read API. Refresh must not spend a turn.
    package func refreshNow() {}
    package func refreshOnForeground() {}

    package func invalidate() {
        producerLease = nil
        snapshot = nil
        publish(enabled ? .idle : .disabled)
    }

    package func shutdown() {
        setEnabled(false)
    }

    private func publish(_ value: ProviderQuotaStatus) {
        guard value != status else { return }
        status = value
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }
}
