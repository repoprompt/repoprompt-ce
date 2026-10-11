import Foundation

/// Passive, observe-only SDK telemetry. Starts no process, request, polling or conversation.
/// SDK events have no account ID, so only the latest reporting run may contribute; never
/// aggregate unrelated sessions/accounts. Disabling invalidates every in-flight producer.
package actor ClaudeRunRateLimitTelemetryService: ProviderQuotaObserving {
    package init() {}

    private var enabled = false
    private var producerLease: UUID?
    /// Claude config-directory identity the current producer run used. Published snapshots
    /// carry it so a display consumer can refuse a run from a different profile.
    private var producerProfileID: String?
    private var snapshot: ProviderQuotaSnapshot?
    private var status: ProviderQuotaStatus = .disabled
    private var subscribers: [UUID: AsyncStream<ProviderQuotaStatus>.Continuation] = [:]

    package func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        producerLease = nil
        producerProfileID = nil
        snapshot = nil
        publish(enabled ? .idle : .disabled)
    }

    /// Called once for an already-authorized first-party Claude run. A replacement run
    /// retires older producers. Compatible backends must never call this seam.
    /// `credentialProfileID` is the run's resolved Claude config directory; `nil` when unknown,
    /// which no display consumer will attribute to a profile.
    package func beginObservation(credentialProfileID: String? = nil) -> UUID? {
        guard enabled else { return nil }
        let lease = UUID()
        producerLease = lease
        producerProfileID = credentialProfileID
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
            publish(.loaded(Self.attributed(merged, profileID: producerProfileID)))
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
        producerProfileID = nil
        snapshot = nil
        publish(enabled ? .idle : .disabled)
    }

    package func shutdown() {
        setEnabled(false)
    }

    /// Merging stays unattributed (SDK deltas carry no profile); only the published copy is
    /// stamped. Still anonymous: no account identifier is ever inferred.
    private static func attributed(_ snapshot: ProviderQuotaSnapshot, profileID: String?) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            accountKey: ProviderAccountKey(
                lineage: snapshot.accountKey.lineage,
                opaqueAccountID: snapshot.accountKey.opaqueAccountID,
                credentialProfileID: profileID
            ),
            buckets: snapshot.buckets,
            facets: snapshot.facets,
            source: snapshot.source,
            coverage: snapshot.coverage,
            observedAt: snapshot.observedAt
        )
    }

    private func publish(_ value: ProviderQuotaStatus) {
        guard value != status else { return }
        status = value
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }
}
