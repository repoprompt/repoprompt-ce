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
        package var weeklyPace: Double?
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
                guard age >= 0, age <= (weekly ? 3600 : 900), ProviderQuotaSnapshot.availability(for: window, now: now).isFresh else { continue }
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
                let elapsed = 1 - resetIn / duration
                guard elapsed >= 0, elapsed <= 1 else { continue }
                let pace = (used / 100) / max(elapsed, 0.10)
                value.weeklyPace = max(value.weeklyPace ?? 0, pace)
                // Expiry preference uses only the account-wide allowance, not a model restriction.
                if bucket.scope == .accountWide, resetIn < (value.weeklyResetIn ?? .infinity) {
                    value.weeklyResetIn = resetIn
                    value.weeklyHeadroom = 100 - used
                }
            }
        }
        return value
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
            guard let origin = base.weeklyPace, let destination = peer.weeklyPace else { return false }
            return origin - destination >= 0.15
        }
    }
}
