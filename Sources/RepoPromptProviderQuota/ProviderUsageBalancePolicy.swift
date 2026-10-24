import Foundation

/// Normalized plan depletion, never an estimate of remaining tokens or cross-provider capacity.
package enum ProviderUsageBalancePolicy {
    package enum Strategy: String, CaseIterable {
        case nearLimits, evenPace, expiringQuota
    }

    package struct Reading: Equatable {
        package var known = false
        package var blocked = false
        package var nearLimit = false
        /// Unused weekly allowance divided by the share of the week left before reset, using the
        /// tightest applicable weekly window. 1.0 means an even rate spends the plan exactly by reset;
        /// higher values mean allowance will expire unused unless this plan absorbs more work.
        package var weeklySparePace: Double?
        package var weeklyResetIn: TimeInterval?
        package var weeklyHeadroom: Double?
    }

    package static func reading(_ snapshot: ProviderQuotaSnapshot?, now: Date, modelAliases: Set<String> = []) -> Reading {
        guard let snapshot, snapshot.source != .claudeSDKEvent else { return Reading() }
        var value = Reading()
        for bucket in snapshot.buckets {
            switch bucket.scope {
            case .accountWide: break
            case let .nativeModelAlias(alias): guard modelAliases.contains(alias) else { continue }
            case .unattributed: continue
            }
            for window in bucket.windows {
                let duration = window.windowDuration ?? (window.nativeRole == "five_hour" ? 18000 : window.nativeRole == "seven_day" ? 604_800 : nil)
                let weekly = (duration ?? 0) >= 6 * 86400
                let age = now.timeIntervalSince(window.observedAt)
                // Weekly allowance and its reset time move slowly; a few hours' age still describes it.
                guard age >= 0, age <= (weekly ? 6 * 3600 : 900), ProviderQuotaSnapshot.availability(for: window, now: now).isFresh else { continue }
                if window.isReached == true || bucket.isReached == true {
                    value.known = true
                    value.blocked = true
                    value.nearLimit = true
                }
                guard window.percent?.declaredUpperBound == 100,
                      let used = window.percent?.usedPercentIfDerivable, used.isFinite, (0 ... 100).contains(used) else { continue }
                value.known = true
                value.blocked = value.blocked || used == 100
                value.nearLimit = value.nearLimit || used >= 90
                guard weekly, let duration, let reset = window.resetsAt else { continue }
                let resetIn = reset.timeIntervalSince(now)
                let remaining = resetIn / duration
                guard remaining >= 0, remaining <= 1 else { continue }
                // Forward-looking: a plan that just reset is not behind, while spare allowance that
                // expires soon is. The floor bounds urgency in the final hours of a window.
                let sparePace = (1 - used / 100) / max(remaining, 0.10)
                value.weeklySparePace = min(value.weeklySparePace ?? .infinity, sparePace)
                // Expiry preference uses only the account-wide allowance, not a model restriction.
                if bucket.scope == .accountWide, resetIn < (value.weeklyResetIn ?? .infinity) {
                    value.weeklyResetIn = resetIn
                    value.weeklyHeadroom = 100 - used
                }
            }
        }
        return value
    }

    /// Why one plan is critical enough to bypass mixed routing.
    package enum OverrideReason: String {
        /// The other plan is exhausted or at least 90% used.
        case limit
        /// Significant unused weekly allowance resets soon.
        case expiring
        /// Unused allowance per remaining time is far higher than the other plan's.
        case lopsided
    }

    package struct OverrideThresholds: Equatable {
        package var expiringWithin: TimeInterval = 48 * 3600
        /// Percent of the weekly allowance still unused.
        package var expiringMinimumUnused: Double = 25
        package var lopsidedRatio: Double = 1.75
        package var lopsidedMinimumGap: Double = 0.5
        package static let standard = Self()
    }

    /// Whether `candidate` should receive all work instead of `other`. The candidate's own reading must
    /// be known. Significant allowance about to expire wins even when the other plan's usage is unknown:
    /// unknown usage is never a reason to let known allowance expire unused.
    package static func overrideReason(
        _ candidate: Reading,
        over other: Reading,
        thresholds: OverrideThresholds = .standard
    ) -> OverrideReason? {
        guard candidate.known, !candidate.blocked, !candidate.nearLimit else { return nil }
        if other.blocked || (other.known && other.nearLimit) { return .limit }
        let expiringSoon = (candidate.weeklyResetIn ?? .infinity) <= thresholds.expiringWithin
            && (candidate.weeklyHeadroom ?? 0) >= thresholds.expiringMinimumUnused
        guard other.known, let spare = candidate.weeklySparePace, let otherSpare = other.weeklySparePace else {
            return expiringSoon ? .expiring : nil
        }
        if expiringSoon, spare - otherSpare >= 0.15 { return .expiring }
        if spare >= otherSpare * thresholds.lopsidedRatio, spare - otherSpare >= thresholds.lopsidedMinimumGap { return .lopsided }
        return nil
    }

    /// Identical inputs always yield the same decision. Unknown/stale readings do not attract work.
    package static func preferPeer(base: Reading, peer: Reading, strategy: Strategy) -> Bool {
        guard !peer.nearLimit, !peer.blocked else { return false }
        if base.blocked { return true }
        guard base.known, peer.known else { return false }
        if base.nearLimit { return true }
        switch strategy {
        case .nearLimits: return false
        case .expiringQuota:
            if let reset = peer.weeklyResetIn, reset <= 86400,
               (peer.weeklyHeadroom ?? 0) >= 20, reset < (base.weeklyResetIn ?? .infinity) { return true }
            fallthrough
        case .evenPace:
            guard let origin = base.weeklySparePace, let destination = peer.weeklySparePace else { return false }
            return destination - origin >= 0.15
        }
    }
}
