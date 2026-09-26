import Foundation

// SEARCH-HELPER: provider quota sparse merge, rate limit delta, retain previous value
//
// Sparse-update merge for account quota.
//
// The Codex app-server `account/rateLimits/updated` notification is a *delta*, not a
// replacement, and upstream states the contract explicitly: clients should merge available
// values into the most recent response, and nullable metadata that is unavailable in a
// rolling update **does not clear a previously observed value**.
//
// Consequences encoded here:
//  - Merge per `ProviderQuotaWindowKey` — `(bucketID, nativeRole)` — never positionally and
//    never per bucket, so `primary` and `secondary` cannot overwrite each other.
//  - A bucket absent from a delta retains its prior value.
//  - A field absent from a present bucket means unchanged, never `nil`.
//  - Absence and explicit JSON `null` are treated alike (retain), because the generated
//    schema marks these fields nullable and upstream documents `null` as "unavailable",
//    not "recovered".

/// A sparse window update. `nil` on a field means "unchanged" — never "cleared".
struct ProviderQuotaWindowDelta: Equatable {
    let key: ProviderQuotaWindowKey
    let percent: ProviderQuotaPercent?
    let windowDuration: TimeInterval?
    let resetsAt: Date?
    let observedAt: Date
}

/// A sparse bucket update. `nil` on a field means "unchanged" — never "cleared".
struct ProviderQuotaBucketDelta: Equatable {
    let bucketID: ProviderQuotaBucketID
    let displayLabel: String?
    let nativeModelAlias: String?
    let reachedType: String?
    let isReached: Bool?
    let planType: String?
    let credits: ProviderQuotaCredits?
    let spendControl: ProviderQuotaSpendControl?
    let windows: [ProviderQuotaWindowDelta]

    init(
        bucketID: ProviderQuotaBucketID,
        displayLabel: String? = nil,
        nativeModelAlias: String? = nil,
        reachedType: String? = nil,
        isReached: Bool? = nil,
        planType: String? = nil,
        credits: ProviderQuotaCredits? = nil,
        spendControl: ProviderQuotaSpendControl? = nil,
        windows: [ProviderQuotaWindowDelta] = []
    ) {
        self.bucketID = bucketID
        self.displayLabel = displayLabel
        self.nativeModelAlias = nativeModelAlias
        self.reachedType = reachedType
        self.isReached = isReached
        self.planType = planType
        self.credits = credits
        self.spendControl = spendControl
        self.windows = windows
    }
}

/// A sparse snapshot update produced by a provider adapter.
struct ProviderQuotaSnapshotDelta: Equatable {
    let accountKey: ProviderAccountKey
    let buckets: [ProviderQuotaBucketDelta]
    /// `nil` means unchanged, not "disallowed".
    let ordinaryUsageAllowed: Bool?
    let source: ProviderQuotaSource
    let observedAt: Date
    /// Coverage the adapter can vouch for. Snapshot coverage is only ever narrowed by a
    /// delta when the delta genuinely knows more; it is never silently widened.
    let coverage: ProviderQuotaCoverage
}

enum ProviderQuotaMerge {
    /// Result of applying a delta to the previous snapshot.
    enum Outcome: Equatable {
        case merged(ProviderQuotaSnapshot)
        /// The delta belongs to a different account. The caller must discard, not merge.
        case accountMismatch
    }

    /// Applies a sparse delta to the previous snapshot.
    ///
    /// - Parameter previous: the most recent merged snapshot, or `nil` when none has been
    ///   observed yet (the delta then becomes the initial snapshot).
    static func apply(
        _ delta: ProviderQuotaSnapshotDelta,
        to previous: ProviderQuotaSnapshot?
    ) -> Outcome {
        if let previous, !previous.accountKey.refersToSameAccount(as: delta.accountKey) {
            return .accountMismatch
        }

        let previousBuckets = previous?.buckets ?? []
        var mergedByID: [ProviderQuotaBucketID: ProviderQuotaBucket] = [:]
        for bucket in previousBuckets {
            mergedByID[bucket.bucketID] = bucket
        }

        // Provider order: previous buckets keep their positions; genuinely new buckets are
        // appended in the order the provider delivered them.
        var order = previousBuckets.map(\.bucketID)
        for bucketDelta in delta.buckets where mergedByID[bucketDelta.bucketID] == nil {
            order.append(bucketDelta.bucketID)
        }

        for bucketDelta in delta.buckets {
            mergedByID[bucketDelta.bucketID] = merge(bucketDelta, into: mergedByID[bucketDelta.bucketID])
        }

        let buckets = order.compactMap { mergedByID[$0] }

        // An identified account ID always wins over an unidentified one, in either direction.
        let accountKey = delta.accountKey.isIdentified ? delta.accountKey : (previous?.accountKey ?? delta.accountKey)

        let facets = ProviderQuotaFacets(
            ordinaryUsageAllowed: delta.ordinaryUsageAllowed ?? previous?.facets.ordinaryUsageAllowed
        )

        let snapshot = ProviderQuotaSnapshot(
            accountKey: accountKey,
            buckets: buckets,
            facets: facets,
            source: delta.source,
            coverage: mergeCoverage(previous: previous?.coverage, delta: delta.coverage),
            observedAt: max(delta.observedAt, previous?.observedAt ?? delta.observedAt)
        )
        return .merged(snapshot)
    }

    /// Coverage never silently widens: an aggregate-only reading cannot be upgraded to
    /// account-wide by a later delta that simply failed to mention model families.
    private static func mergeCoverage(
        previous: ProviderQuotaCoverage?,
        delta: ProviderQuotaCoverage
    ) -> ProviderQuotaCoverage {
        guard let previous else { return delta }
        if previous == .accountWideAggregateOnly || delta == .accountWideAggregateOnly {
            return .accountWideAggregateOnly
        }
        if case let .modelFamilies(previousFamilies) = previous,
           case let .modelFamilies(deltaFamilies) = delta
        {
            return .modelFamilies(previousFamilies.union(deltaFamilies))
        }
        if case .modelFamilies = previous, delta == .accountWide {
            // A sparse notification with no family attribution does not prove that the
            // previously observed model-specific limits cover the entire account.
            return previous
        }
        return delta
    }

    private static func merge(
        _ delta: ProviderQuotaBucketDelta,
        into previous: ProviderQuotaBucket?
    ) -> ProviderQuotaBucket {
        let nativeModelAlias = delta.nativeModelAlias ?? previous?.nativeModelAlias
        return ProviderQuotaBucket(
            bucketID: delta.bucketID,
            displayLabel: delta.displayLabel ?? previous?.displayLabel,
            nativeModelAlias: nativeModelAlias,
            // Scope is derived from the model attribution, never from which payload field the
            // bucket arrived in.
            scope: scope(forNativeModelAlias: nativeModelAlias, bucketID: delta.bucketID),
            reachedType: delta.reachedType ?? previous?.reachedType,
            isReached: delta.isReached ?? previous?.isReached,
            planType: delta.planType ?? previous?.planType,
            credits: delta.credits ?? previous?.credits,
            spendControl: delta.spendControl ?? previous?.spendControl,
            windows: mergeWindows(delta.windows, into: previous?.windows ?? [])
        )
    }

    /// Scope is a function of model attribution only — never of which payload field the
    /// bucket arrived in, and never of whether RPCE had to synthesize its ID.
    ///
    /// A bucket carrying a model alias is `.nativeModelAlias(alias)`; a bucket that genuinely
    /// has no model attribution is `.accountWide`.
    static func scope(
        forNativeModelAlias alias: String?,
        bucketID _: ProviderQuotaBucketID
    ) -> ProviderQuotaBucketScope {
        guard let alias, !alias.isEmpty else { return .accountWide }
        return .nativeModelAlias(alias)
    }

    private static func mergeWindows(
        _ deltas: [ProviderQuotaWindowDelta],
        into previous: [ProviderQuotaWindow]
    ) -> [ProviderQuotaWindow] {
        guard !deltas.isEmpty else { return previous }

        var mergedByKey: [ProviderQuotaWindowKey: ProviderQuotaWindow] = [:]
        for window in previous {
            mergedByKey[window.key] = window
        }
        var order = previous.map(\.key)
        for delta in deltas where mergedByKey[delta.key] == nil {
            order.append(delta.key)
        }

        for delta in deltas {
            let existing = mergedByKey[delta.key]
            mergedByKey[delta.key] = ProviderQuotaWindow(
                key: delta.key,
                percent: delta.percent ?? existing?.percent,
                windowDuration: delta.windowDuration ?? existing?.windowDuration,
                resetsAt: delta.resetsAt ?? existing?.resetsAt,
                // Only a window actually mentioned by the delta advances its observation time.
                observedAt: delta.observedAt
            )
        }

        return order.compactMap { mergedByKey[$0] }
    }
}
