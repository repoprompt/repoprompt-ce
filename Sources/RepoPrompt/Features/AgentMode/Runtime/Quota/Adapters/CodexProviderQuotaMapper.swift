import Foundation

// SEARCH-HELPER: codex rate limits mapping, account/rateLimits/read, rateLimitsByLimitId
//
// Maps Codex app-server account rate-limit payloads into the provider-neutral quota domain.
//
// Wire shape is taken from the generated schema of the pinned Codex CLI
// (`codex app-server generate-json-schema --experimental`), not from upstream Rust field
// names: the JSON contract is camelCase (`limitId`, `usedPercent`, `normalModelSlug`).
//
// Floor notes for the pinned `minimumCodexVersion` (0.153.4):
//  - `ordinaryUsageAllowed` and `normalModelSlug` were added in 0.155.1 and are absent at the
//    floor. Both decode as `nil` there, which the domain already treats as "unknown".
//
// Shapes:
//   GetAccountRateLimitsResponse    { accountId?, ordinaryUsageAllowed?, rateLimits,
//                                     rateLimitsByLimitId? }
//   AccountRateLimitsUpdatedNotification { rateLimits }   // a SINGLE bucket, not a map
//   RateLimitSnapshot               { limitId?, limitName?, normalModelSlug?, planType?,
//                                     primary?, secondary?, credits?, individualLimit?,
//                                     rateLimitReachedType?, spendControlReached? }
//   RateLimitWindow                 { usedPercent, windowDurationMins?, resetsAt? }

enum CodexProviderQuotaMapper {
    static let readMethod = "account/rateLimits/read"
    static let updatedNotificationMethod = "account/rateLimits/updated"

    private static let primaryRole = "primary"
    private static let secondaryRole = "secondary"

    /// Maps a `account/rateLimits/read` response.
    ///
    /// - Parameter fallbackAccountID: the account identity RPCE already believes is signed in.
    ///   Used only when the payload omits `accountId`; it never overrides a supplied one.
    static func mapReadResponse(
        _ response: [String: Any],
        fallbackAccountID: String?,
        observedAt: Date
    ) -> ProviderQuotaSnapshotDelta? {
        let object = response.compactMapValues { CodexJSONValue.from($0) }
        return mapReadResponse(object: object, fallbackAccountID: fallbackAccountID, observedAt: observedAt)
    }

    static func mapReadResponse(
        object: [String: CodexJSONValue],
        fallbackAccountID: String?,
        observedAt: Date
    ) -> ProviderQuotaSnapshotDelta? {
        guard let topLevel = object["rateLimits"]?.objectValue else { return nil }

        let byLimitID = object["rateLimitsByLimitId"]?.objectValue ?? [:]
        var buckets: [ProviderQuotaBucketDelta] = []

        // Provider order is not defined for a JSON object, so map buckets are ordered by
        // their key to keep rendering stable across reads. RPCE never ranks them.
        for key in byLimitID.keys.sorted() {
            guard let bucketObject = byLimitID[key]?.objectValue else { continue }
            let bucketID = ProviderQuotaBucketID(rawValue: bucketObject["limitId"]?.stringValue ?? key)
            buckets.append(mapBucket(bucketObject, bucketID: bucketID, observedAt: observedAt))
        }

        // De-duplicate the backward-compatible top-level `rateLimits` against the map. It is
        // not inherently an account-wide bucket: it may be the same bucket that also appears
        // in the map, and admitting both would double-count it and let the two copies
        // disagree after a later sparse merge.
        let topLevelLimitID = topLevel["limitId"]?.stringValue
        let admitTopLevel: Bool = if let topLevelLimitID {
            // Identified: admit only when it names a bucket the map does not already carry.
            !(
                byLimitID.keys.contains(topLevelLimitID)
                    || buckets.contains { $0.bucketID.rawValue == topLevelLimitID }
            )
        } else {
            // Unidentified: the schema calls this the "backward-compatible single-bucket
            // view; mirrors the historical payload". When the map is non-empty it is a
            // restatement of one of those buckets, and RPCE cannot tell which. Synthesizing
            // an ID for it would double-count real usage and create a second bucket that
            // drifts from its twin across sparse merges. It is only a bucket in its own
            // right when the map is absent or empty.
            buckets.isEmpty
        }

        if admitTopLevel {
            let bucketID = topLevelLimitID.map { ProviderQuotaBucketID(rawValue: $0) }
                ?? ProviderQuotaBucketID.synthesizedDefault
            buckets.insert(mapBucket(topLevel, bucketID: bucketID, observedAt: observedAt), at: 0)
        }

        guard !buckets.isEmpty else { return nil }

        let accountID = object["accountId"]?.stringValue ?? fallbackAccountID
        return ProviderQuotaSnapshotDelta(
            accountKey: .codex(accountID: accountID),
            buckets: buckets,
            ordinaryUsageAllowed: object["ordinaryUsageAllowed"]?.boolValue,
            source: .codexAppServerRead,
            observedAt: observedAt,
            coverage: coverage(for: buckets)
        )
    }

    /// Maps an `account/rateLimits/updated` notification. The payload carries a single
    /// `rateLimits` bucket, so the resulting delta touches exactly that bucket and leaves
    /// every other previously observed bucket untouched.
    static func mapUpdatedNotification(
        params: [String: CodexJSONValue],
        fallbackAccountID: String?,
        observedAt: Date
    ) -> ProviderQuotaSnapshotDelta? {
        guard let bucketObject = params["rateLimits"]?.objectValue else { return nil }
        let bucketID = bucketObject["limitId"].flatMap(\.stringValue)
            .map { ProviderQuotaBucketID(rawValue: $0) }
            ?? ProviderQuotaBucketID.synthesizedDefault
        let bucket = mapBucket(bucketObject, bucketID: bucketID, observedAt: observedAt)
        return ProviderQuotaSnapshotDelta(
            accountKey: .codex(accountID: fallbackAccountID),
            buckets: [bucket],
            // The notification carries no account-level facet; absent means unchanged.
            ordinaryUsageAllowed: nil,
            source: .codexAppServerNotification,
            observedAt: observedAt,
            coverage: coverage(for: [bucket])
        )
    }

    private static func coverage(for buckets: [ProviderQuotaBucketDelta]) -> ProviderQuotaCoverage {
        let families = Set(buckets.compactMap(\.nativeModelAlias).filter { !$0.isEmpty })
        return families.isEmpty ? .accountWide : .modelFamilies(families)
    }

    private static func mapBucket(
        _ object: [String: CodexJSONValue],
        bucketID: ProviderQuotaBucketID,
        observedAt: Date
    ) -> ProviderQuotaBucketDelta {
        var windows: [ProviderQuotaWindowDelta] = []
        for role in [primaryRole, secondaryRole] {
            guard let windowObject = object[role]?.objectValue else { continue }
            guard let window = mapWindow(
                windowObject,
                key: ProviderQuotaWindowKey(bucketID: bucketID, nativeRole: role),
                observedAt: observedAt
            ) else { continue }
            windows.append(window)
        }

        let reachedType = object["rateLimitReachedType"]?.stringValue
        return ProviderQuotaBucketDelta(
            bucketID: bucketID,
            displayLabel: object["limitName"]?.stringValue,
            nativeModelAlias: object["normalModelSlug"]?.stringValue,
            reachedType: reachedType,
            // The provider reports a reached *type* only when the bucket is exhausted. Absence
            // is "unknown", never "not reached", so it stays `nil`.
            isReached: reachedType == nil ? nil : true,
            planType: object["planType"]?.stringValue,
            credits: mapCredits(object["credits"]?.objectValue),
            spendControl: mapSpendControl(
                object["individualLimit"]?.objectValue,
                isReached: object["spendControlReached"]?.boolValue,
                observedAt: observedAt
            ),
            windows: windows
        )
    }

    private static func mapWindow(
        _ object: [String: CodexJSONValue],
        key: ProviderQuotaWindowKey,
        observedAt: Date
    ) -> ProviderQuotaWindowDelta? {
        // `usedPercent` is required by the generated schema. A window without it is not a
        // window RPCE can describe, and nothing is synthesized in its place.
        guard let usedPercent = object["usedPercent"]?.doubleValue else { return nil }
        return ProviderQuotaWindowDelta(
            key: key,
            percent: ProviderQuotaPercent(rawValue: usedPercent, sense: .used),
            windowDuration: object["windowDurationMins"]?.doubleValue.map { $0 * 60 },
            resetsAt: object["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            observedAt: observedAt
        )
    }

    private static func mapCredits(_ object: [String: CodexJSONValue]?) -> ProviderQuotaCredits? {
        guard let object,
              let hasCredits = object["hasCredits"]?.boolValue,
              let unlimited = object["unlimited"]?.boolValue
        else { return nil }
        return ProviderQuotaCredits(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balanceRaw: object["balance"]?.stringValue
        )
    }

    private static func mapSpendControl(
        _ object: [String: CodexJSONValue]?,
        isReached: Bool?,
        observedAt: Date
    ) -> ProviderQuotaSpendControl? {
        guard let object,
              let limit = object["limit"]?.stringValue,
              let used = object["used"]?.stringValue,
              let remainingPercent = object["remainingPercent"]?.doubleValue
        else { return nil }
        return ProviderQuotaSpendControl(
            limitRaw: limit,
            usedRaw: used,
            // Codex spend control reports REMAINING percent. The sense is recorded so no
            // consumer can silently read it as "used".
            percent: ProviderQuotaPercent(
                rawValue: remainingPercent,
                sense: .remaining,
                declaredUpperBound: 100
            ),
            resetsAt: object["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            isReached: isReached,
            observedAt: observedAt
        )
    }
}

private extension CodexJSONValue {
    var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}
