import Foundation

/// Adapts SDK subscription telemetry, not tokens/costs or undocumented OAuth APIs.
/// One event names one bucket. It cannot prove complete account coverage or identity.
package enum ClaudeProviderQuotaMapper {
    package static func delta(from info: ClaudeProviderQuotaObservation, observedAt: Date) -> ProviderQuotaSnapshotDelta? {
        guard let role = info.rateLimitType else { return nil }
        let duration: TimeInterval?
        let alias: String?
        let label: String
        switch role {
        case "five_hour":
            duration = 5 * 60 * 60
            alias = nil
            label = "Claude 5-hour plan limit"
        case "seven_day":
            duration = 7 * 24 * 60 * 60
            alias = nil
            label = "Claude weekly plan limit"
        case "seven_day_opus", "seven_day_sonnet":
            duration = 7 * 24 * 60 * 60
            alias = role == "seven_day_opus" ? "opus" : "sonnet"
            label = role == "seven_day_opus" ? "Claude Opus" : "Claude Sonnet"
        case "seven_day_overage_included":
            duration = 7 * 24 * 60 * 60
            alias = nil
            label = "Included overage"
        case "overage":
            duration = nil
            alias = nil
            label = "Overage"
        default:
            // Do not attribute future provider vocabulary to an account/model by guessing.
            return nil
        }
        let bucketID = ProviderQuotaBucketID(rawValue: role)
        let percent = info.utilization.flatMap { value -> ProviderQuotaPercent? in
            guard value.isFinite, (0 ... 1).contains(value) else { return nil }
            return ProviderQuotaPercent(rawValue: value * 100, sense: .used, declaredUpperBound: 100)
        }
        let reset = info.resetsAt.flatMap { value -> Date? in
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        return ProviderQuotaSnapshotDelta(
            accountKey: ProviderAccountKey(lineage: .anthropicFirstParty, opaqueAccountID: nil),
            buckets: [ProviderQuotaBucketDelta(
                bucketID: bucketID,
                displayLabel: label,
                nativeModelAlias: alias,
                reachedType: role,
                isReached: info.status == .rejected,
                windows: [ProviderQuotaWindowDelta(
                    key: ProviderQuotaWindowKey(bucketID: bucketID, nativeRole: role),
                    percent: percent,
                    windowDuration: duration,
                    resetsAt: reset,
                    observedAt: observedAt,
                    replacesMissingValues: true,
                    isReached: info.status == .rejected
                )]
            )],
            ordinaryUsageAllowed: nil,
            source: .claudeSDKEvent,
            observedAt: observedAt,
            coverage: .reportedBucketsOnly
        )
    }
}
