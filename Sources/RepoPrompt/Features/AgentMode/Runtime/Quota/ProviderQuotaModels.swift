import Foundation

// SEARCH-HELPER: provider quota, account usage, rate limits, buckets, windows, observe-only
//
// Provider-neutral, account-scoped usage quota domain.
//
// Deliberately separate from `Runtime/Usage/`, which models per-session *context window*
// consumption. Quota is an account-scoped, cross-session fact and the two must not blur.
//
// This domain is observe-only. Nothing here participates in routing, candidate admission,
// or model selection, and it must stay that way until a separate opt-in policy layer exists.
//
// Modelling rules (load-bearing — see docs/designs/provider-usage-quota-architecture-2026-09-21.md):
//  1. Buckets are not windows. A bucket owns >= 1 windows, addressed by `ProviderQuotaWindowKey`.
//  2. No invented values. An omitted field is `nil`, never a computed estimate.
//  3. `unknown` != `full`. Distinct states in every consumer.
//  4. `isReached` is independent of any percentage. Trust the explicit provider flag.
//  5. Percentages carry their sense and bounds and are never clamped for decisions.
//  6. Provider order is preserved. RPCE never sorts or elects a "main" bucket.
//  7. Account-linked values are never logged; identity mirrors expose booleans only.

/// Provider lineage. Part of account identity: two snapshots with equal account
/// discriminators but different lineage are different accounts and must never merge.
enum ProviderQuotaLineage: Hashable {
    case codexFirstParty
    case anthropicFirstParty
    /// Claude-compatible backend (z.ai, Moonshot/Kimi, user custom) — not Anthropic.
    case claudeCompatible(backendID: String)

    var displayName: String {
        switch self {
        case .codexFirstParty: "Codex"
        case .anthropicFirstParty: "Claude"
        case .claudeCompatible: "Claude-compatible"
        }
    }
}

/// Account identity for a quota snapshot.
///
/// Redaction: adopts the boolean-only `CustomReflectable` mirror used by `CodexManagedAccount`
/// so the identifier cannot leak through debug output, diagnostics dumps, or crash reports.
struct ProviderAccountKey: Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let lineage: ProviderQuotaLineage
    /// Provider-assigned account identifier. Never logged, never rendered.
    let opaqueAccountID: String?

    init(lineage: ProviderQuotaLineage, opaqueAccountID: String?) {
        self.lineage = lineage
        let trimmed = opaqueAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.opaqueAccountID = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    static func codex(accountID: String?) -> Self {
        ProviderAccountKey(lineage: .codexFirstParty, opaqueAccountID: accountID)
    }

    /// An unidentified key cannot be used for cross-session attribution.
    var isIdentified: Bool {
        opaqueAccountID != nil
    }

    /// Two keys refer to the same account only when lineage matches and neither side is
    /// contradicted by a known identifier. An unidentified key never claims equality with an
    /// identified one from a different account.
    func refersToSameAccount(as other: ProviderAccountKey) -> Bool {
        guard lineage == other.lineage else { return false }
        switch (opaqueAccountID, other.opaqueAccountID) {
        case let (lhs?, rhs?): return lhs == rhs
        default: return true
        }
    }

    var description: String {
        "ProviderAccountKey(\(lineage.displayName), identified: \(isIdentified))"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "lineage": lineage.displayName,
                "hasAccountID": isIdentified
            ],
            displayStyle: .struct
        )
    }
}

/// Where a snapshot came from. Provenance is required before any number is rendered.
enum ProviderQuotaSource: Equatable {
    case codexAppServerRead
    case codexAppServerNotification

    var isPushUpdate: Bool {
        self == .codexAppServerNotification
    }
}

/// Opaque, provider-assigned bucket identity. Never parsed and never ordered by RPCE.
struct ProviderQuotaBucketID: Hashable {
    let rawValue: String
    /// True when RPCE minted this ID because the provider supplied none. A synthesized ID is
    /// never presented as, or compared against, a provider identifier.
    let isSynthesized: Bool

    init(rawValue: String, isSynthesized: Bool = false) {
        self.rawValue = rawValue
        self.isSynthesized = isSynthesized
    }

    /// Stable local identity for a provider bucket that arrived without a `limitId`.
    static let synthesizedDefault = ProviderQuotaBucketID(
        rawValue: "rpce.synthesized.default",
        isSynthesized: true
    )
}

/// Stable identity for one window *within* a bucket.
///
/// A window is NOT identified by the bucket's ID: a bucket has several windows and they must
/// stay distinguishable across sparse merges, so `(bucketID, nativeRole)` is the merge key.
struct ProviderQuotaWindowKey: Hashable {
    let bucketID: ProviderQuotaBucketID
    /// The provider's own role for this window within the bucket — Codex `primary` /
    /// `secondary`. Preserved verbatim so merges and ordering stay provider-faithful.
    let nativeRole: String
}

/// A percentage exactly as the provider expressed it.
///
/// RPCE stores the raw value plus its semantics; it never rescales, inverts, or clamps for
/// decision logic. Codex windows report *used*; Codex spend control reports *remaining*.
struct ProviderQuotaPercent: Equatable {
    enum Sense: Equatable {
        case used
        case remaining
    }

    /// Exactly as reported. May exceed 100 or be negative. Never clamped.
    let rawValue: Double
    let sense: Sense
    /// Provider-declared bounds when known. `nil` means "bounds not specified" and must NOT
    /// be read as `0...100`.
    let declaredUpperBound: Double?

    init(rawValue: Double, sense: Sense, declaredUpperBound: Double? = nil) {
        self.rawValue = rawValue
        self.sense = sense
        self.declaredUpperBound = declaredUpperBound
    }

    /// Display-only. Clamping is permitted for a progress bar and nowhere else.
    func clampedForDisplay() -> Double {
        min(max(rawValue, 0), declaredUpperBound ?? 100)
    }

    /// The *used* reading, converting only when the provider's own bound makes the
    /// conversion well defined. Returns `nil` rather than guessing.
    var usedPercentIfDerivable: Double? {
        switch sense {
        case .used:
            return rawValue
        case .remaining:
            guard let bound = declaredUpperBound else { return nil }
            return bound - rawValue
        }
    }
}

/// One provider-declared window. RPCE never synthesizes one.
struct ProviderQuotaWindow: Equatable {
    let key: ProviderQuotaWindowKey
    let percent: ProviderQuotaPercent?
    let windowDuration: TimeInterval?
    let resetsAt: Date?
    /// When this specific window was last observed. A snapshot can be partially fresh.
    let observedAt: Date

    var nativeRole: String {
        key.nativeRole
    }
}

/// Codex `CreditsSnapshot`.
struct ProviderQuotaCredits: Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    /// Kept as the provider's own string; never parsed into a currency number.
    let balanceRaw: String?
}

/// Codex `SpendControlLimitSnapshot`. Note the provider reports REMAINING percent.
struct ProviderQuotaSpendControl: Equatable {
    let limitRaw: String
    let usedRaw: String
    /// `sense == .remaining` for Codex.
    let percent: ProviderQuotaPercent
    let resetsAt: Date?
    /// Codex `spendControlReached`.
    let isReached: Bool?
    /// When this spend-control value was last present in a provider payload. Sparse updates
    /// that omit it retain this timestamp rather than making old data look newly observed.
    let observedAt: Date
}

/// How a bucket is attributed to models.
enum ProviderQuotaBucketScope: Equatable {
    /// Applies to the whole account regardless of model.
    case accountWide
    /// Applies to the models the provider associated with this bucket.
    case nativeModelAlias(String)
    /// Provider gave a bucket RPCE cannot attribute. Never used to exclude anything.
    case unattributed
}

/// A provider-declared limit bucket (Codex `RateLimitSnapshot`).
///
/// `credits`, `spendControl`, and `planType` are modelled here rather than at account level
/// because that is where the generated Codex schema places them.
struct ProviderQuotaBucket: Equatable {
    let bucketID: ProviderQuotaBucketID
    /// Codex `limitName`. Provider-supplied only — never invented.
    let displayLabel: String?
    /// Codex `normalModelSlug`. The only sanctioned basis for scoping a bucket to models.
    let nativeModelAlias: String?
    let scope: ProviderQuotaBucketScope
    /// Codex `rateLimitReachedType`, retained as a raw string.
    let reachedType: String?
    /// Provider says this bucket is exhausted. Independent of any percentage.
    let isReached: Bool?
    let planType: String?
    let credits: ProviderQuotaCredits?
    let spendControl: ProviderQuotaSpendControl?
    /// Provider order preserved; never sorted by RPCE.
    let windows: [ProviderQuotaWindow]

    func window(role: String) -> ProviderQuotaWindow? {
        windows.first { $0.nativeRole == role }
    }
}

/// Account-level facts that are not windows.
struct ProviderQuotaFacets: Equatable {
    /// Codex `ordinaryUsageAllowed`. A hard, provider-explicit capability signal, independent
    /// of any percentage. Available only on Codex CLI >= 0.155.1; `nil` below that floor.
    let ordinaryUsageAllowed: Bool?

    static let empty = ProviderQuotaFacets(ordinaryUsageAllowed: nil)
}

/// What a snapshot is actually able to speak about.
enum ProviderQuotaCoverage: Equatable {
    case accountWide
    case modelFamilies(Set<String>)
    /// Aggregate that provably cannot resolve per-family eligibility.
    case accountWideAggregateOnly
}

/// Why a reading is no longer considered fresh.
enum ProviderQuotaStaleReason: Equatable {
    /// The observation aged past this window's own horizon.
    case observationAged
    /// The window's declared reset time has passed; the value describes a finished window.
    case resetElapsed
}

/// Freshness of a reading. `unknown` is never rendered as a zero or a full bar.
enum ProviderQuotaAvailability: Equatable {
    /// Never observed.
    case unknown
    case fresh(observedAt: Date)
    case stale(observedAt: Date, reason: ProviderQuotaStaleReason)
    /// Provider says it cannot report.
    case unsupported(reason: String)

    var observedAt: Date? {
        switch self {
        case let .fresh(observedAt): observedAt
        case let .stale(observedAt, _): observedAt
        case .unknown, .unsupported: nil
        }
    }

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

/// A merged, account-scoped quota snapshot.
///
/// Redaction: `description` and the debug mirror are shape-only. No percentage, reset time,
/// plan type, or account identifier is ever exposed through reflection or logging.
struct ProviderQuotaSnapshot: Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let accountKey: ProviderAccountKey
    /// Provider order preserved.
    let buckets: [ProviderQuotaBucket]
    let facets: ProviderQuotaFacets
    let source: ProviderQuotaSource
    let coverage: ProviderQuotaCoverage
    /// When the most recent contributing observation landed.
    let observedAt: Date

    /// Staleness horizon when the provider declares no window duration. Conservative by
    /// design: mark stale early rather than late.
    static let defaultStaleHorizon: TimeInterval = 15 * 60

    /// Fraction of a declared window duration after which a reading is treated as stale.
    /// A 5-hour window and a 7-day window have very different half-lives, so the horizon is
    /// derived per window rather than from a single global constant.
    static let windowStaleFraction: Double = 0.25

    /// Freshness for one window, derived from that window's own duration.
    static func availability(for window: ProviderQuotaWindow, now: Date) -> ProviderQuotaAvailability {
        if let resetsAt = window.resetsAt, resetsAt <= now {
            return .stale(observedAt: window.observedAt, reason: .resetElapsed)
        }
        let horizon = window.windowDuration.map { max($0 * windowStaleFraction, 60) } ?? defaultStaleHorizon
        if now.timeIntervalSince(window.observedAt) > horizon {
            return .stale(observedAt: window.observedAt, reason: .observationAged)
        }
        return .fresh(observedAt: window.observedAt)
    }

    /// Freshness for spend-control metadata, which has no declared window duration. Its
    /// reset time is authoritative when present; otherwise use the conservative default
    /// horizon rather than presenting a retained balance as current indefinitely.
    static func availability(
        for spendControl: ProviderQuotaSpendControl,
        now: Date
    ) -> ProviderQuotaAvailability {
        if let resetsAt = spendControl.resetsAt, resetsAt <= now {
            return .stale(observedAt: spendControl.observedAt, reason: .resetElapsed)
        }
        if now.timeIntervalSince(spendControl.observedAt) > defaultStaleHorizon {
            return .stale(observedAt: spendControl.observedAt, reason: .observationAged)
        }
        return .fresh(observedAt: spendControl.observedAt)
    }

    /// Snapshot-level freshness is the *oldest* contributing reading's freshness, never the
    /// newest, so retained metadata cannot make a partially fresh snapshot look fully fresh.
    func availability(now: Date) -> ProviderQuotaAvailability {
        let allWindows = buckets.flatMap(\.windows)
        let allSpendControls = buckets.compactMap(\.spendControl)
        guard !allWindows.isEmpty || !allSpendControls.isEmpty else { return .unknown }
        var result: ProviderQuotaAvailability = .fresh(observedAt: observedAt)
        var oldestObservedAt: Date?
        for window in allWindows {
            let windowAvailability = Self.availability(for: window, now: now)
            let isOlder = oldestObservedAt.map { window.observedAt < $0 } ?? true
            if case .stale = windowAvailability {
                // Any stale contributor makes the snapshot stale.
                if case .stale = result, !isOlder { continue }
                result = windowAvailability
                oldestObservedAt = window.observedAt
                continue
            }
            if case .stale = result { continue }
            if isOlder {
                result = windowAvailability
                oldestObservedAt = window.observedAt
            }
        }
        for spendControl in allSpendControls {
            let spendAvailability = Self.availability(for: spendControl, now: now)
            let isOlder = oldestObservedAt.map { spendControl.observedAt < $0 } ?? true
            if case .stale = spendAvailability {
                // Any stale contributor makes the snapshot stale.
                if case .stale = result, !isOlder { continue }
                result = spendAvailability
                oldestObservedAt = spendControl.observedAt
                continue
            }
            if case .stale = result { continue }
            if isOlder {
                result = spendAvailability
                oldestObservedAt = spendControl.observedAt
            }
        }
        return result
    }

    var description: String {
        let windowCount = buckets.reduce(0) { $0 + $1.windows.count }
        return "ProviderQuotaSnapshot(\(buckets.count) buckets, \(windowCount) windows)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "lineage": accountKey.lineage.displayName,
                "bucketCount": buckets.count,
                "windowCount": buckets.reduce(0) { $0 + $1.windows.count },
                "hasFacets": facets != .empty
            ],
            displayStyle: .struct
        )
    }
}
