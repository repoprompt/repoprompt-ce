import Foundation

package struct ProviderUsageProviderID: RawRepresentable, Hashable {
    package let rawValue: String
    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let codex = Self(rawValue: "codex")
    package static let claude = Self(rawValue: "claude")
}

package enum ProviderUsageConsumer { case settingsPanel, agentIndicator, routerAdvisory }

/// An account/window-scoped fact, not a routing decision or a provider-wide capacity guess.
package struct ProviderUsageSignal: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package enum Headroom: Equatable {
        case unknown
        case remainingPercent(Double)
        case reached
    }

    package let account: ProviderAccountKey
    package let windowKey: ProviderQuotaWindowKey
    package let scope: ProviderQuotaBucketScope
    package let coverage: ProviderQuotaCoverage
    package let source: ProviderQuotaSource
    package let headroom: Headroom
    package let resetsAt: Date?
    package let availability: ProviderQuotaAvailability
    package var description: String {
        "ProviderUsageSignal(identified: \(account.isIdentified), fresh: \(availability.isFresh))"
    }

    package var debugDescription: String {
        description
    }

    package var customMirror: Mirror {
        Mirror(self, children: ["identified": account.isIdentified, "fresh": availability.isFresh], displayStyle: .struct)
    }

    package static func readings(from snapshot: ProviderQuotaSnapshot, now: Date, maximumObservationAge: TimeInterval? = 900) -> [Self] {
        // Anonymous run events are explicitly not account quota data.
        guard snapshot.source != .claudeSDKEvent else { return [] }
        return snapshot.buckets.flatMap { bucket in
            bucket.windows.map { window in
                var availability = ProviderQuotaSnapshot.availability(for: window, now: now)
                // A week-long limit is not permission to treat a days-old value as routing evidence.
                if availability.isFresh, let maximumObservationAge, now.timeIntervalSince(window.observedAt) > maximumObservationAge {
                    availability = .stale(observedAt: window.observedAt, reason: .observationAged)
                }
                let headroom: Headroom = if window.isReached == true || bucket.isReached == true {
                    .reached
                } else if let percent = window.percent, let bound = percent.declaredUpperBound,
                          bound == 100, let used = percent.usedPercentIfDerivable, used.isFinite
                {
                    // Raw fact, never clamped or silently interpreted as candidate eligibility.
                    .remainingPercent(bound - used)
                } else { .unknown }
                return Self(
                    account: snapshot.accountKey,
                    windowKey: window.key,
                    scope: bucket.scope,
                    coverage: snapshot.coverage,
                    source: snapshot.source,
                    headroom: headroom,
                    resetsAt: window.resetsAt,
                    availability: availability
                )
            }
        }
    }
}

/// Consumer-neutral access over the single owned source caches. Cached lookup never subscribes,
/// reads credentials, spawns processes, or performs network IO. Future router code must supply
/// an exact identified account key; ambiguous/stale facts are not admission policy.
package actor ProviderUsageHub {
    private let sources: [ProviderUsageProviderID: any ProviderQuotaObserving]
    private let routerAdvisoryAuthorized: Bool
    package init(sources: [ProviderUsageProviderID: any ProviderQuotaObserving], routerAdvisoryAuthorized: Bool = false) {
        self.sources = sources
        self.routerAdvisoryAuthorized = routerAdvisoryAuthorized
    }

    package func latest(_ provider: ProviderUsageProviderID) async -> ProviderQuotaSnapshot? {
        await sources[provider]?.latestSnapshot()
    }

    package func signals(for account: ProviderAccountKey, now: Date) async -> [ProviderUsageSignal] {
        guard account.isIdentified else { return [] }
        let provider: ProviderUsageProviderID = switch account.lineage {
        case .codexFirstParty: .codex
        case .anthropicFirstParty: .claude
        case let .provider(id): id
        case let .claudeCompatible(backendID): ProviderUsageProviderID(rawValue: "claude-compatible." + backendID)
        }
        guard let snapshot = await latest(provider), snapshot.accountKey == account else { return [] }
        return ProviderUsageSignal.readings(from: snapshot, now: now)
    }

    /// Explicit demand is acquisition, unlike latest/signals. Terminating the stream releases
    /// the source's observer lease; the last lease tears down its IO. Router demand remains off.
    package func updates(_ provider: ProviderUsageProviderID, consumer: ProviderUsageConsumer) async -> AsyncStream<ProviderQuotaStatus>? {
        if case .routerAdvisory = consumer, !routerAdvisoryAuthorized { return nil }
        return await sources[provider]?.subscribe()
    }
}
