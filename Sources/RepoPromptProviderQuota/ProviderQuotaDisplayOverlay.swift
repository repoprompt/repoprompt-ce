import Foundation

// SEARCH-HELPER: Claude SDK rate_limit_event overlay, display-only usage merge, newest observation wins
//
// Display-only overlay of passive Claude SDK `rate_limit_event` telemetry onto the account
// snapshot a usage surface already shows, so the Agent Mode pill stays current during runs
// without launching another CLI read.
//
// This is deliberately NOT a service merge. Provider services, `ProviderUsageHub`, routing
// observation, and `ProviderUsageBalancePolicy` never see the overlaid snapshot: balancing keeps
// ignoring `.claudeSDKEvent` data and keeps its own freshness caps. Only the MainActor UI
// projection calls this.
//
// Merge rule, per account-wide plan window (`five_hour`, `seven_day`):
//  - Only first-party Claude telemetry overlays a first-party Claude CLI/account snapshot,
//    and only when both carry the same non-nil credential profile (Claude config directory).
//    SDK events have no account identity, so the profile is the only safe discriminator.
//  - Newest observation wins, per window. An overlay reading older than (or as old as) the
//    displayed window never replaces it.
//  - A missing percent never erases a value. An overlay without a percent may still mark a
//    window reached, but never advances its observation time (which would make an old
//    figure look fresh).
//  - Model-scoped and overage buckets are ignored; they are not plan-pill evidence.

package enum ProviderQuotaDisplayOverlay {
    /// Account-wide plan windows a passive SDK event may refresh for display.
    package static let planWindowRoles: Set<String> = ["five_hour", "seven_day"]

    package static func merge(_ overlay: ProviderQuotaSnapshot?, onto base: ProviderQuotaSnapshot) -> ProviderQuotaSnapshot {
        guard let overlay,
              overlay.source == .claudeSDKEvent,
              base.source != .claudeSDKEvent,
              overlay.accountKey.lineage == .anthropicFirstParty,
              base.accountKey.lineage == .anthropicFirstParty,
              let profileID = base.accountKey.credentialProfileID,
              overlay.accountKey.credentialProfileID == profileID
        else { return base }

        var updates: [String: ProviderQuotaWindow] = [:]
        for bucket in overlay.buckets where bucket.scope == .accountWide {
            for window in bucket.windows where planWindowRoles.contains(window.nativeRole) {
                if let existing = updates[window.nativeRole], existing.observedAt >= window.observedAt { continue }
                updates[window.nativeRole] = window
            }
        }
        guard !updates.isEmpty else { return base }

        var newest = base.observedAt
        var changed = false
        let buckets = base.buckets.map { bucket -> ProviderQuotaBucket in
            guard bucket.scope == .accountWide else { return bucket }
            let windows = bucket.windows.map { window -> ProviderQuotaWindow in
                guard let update = updates[window.nativeRole], update.observedAt > window.observedAt else { return window }
                if let percent = update.percent {
                    changed = true
                    newest = max(newest, update.observedAt)
                    return ProviderQuotaWindow(
                        key: window.key,
                        percent: percent,
                        windowDuration: window.windowDuration ?? update.windowDuration,
                        resetsAt: update.resetsAt ?? window.resetsAt,
                        observedAt: update.observedAt,
                        isReached: update.isReached ?? window.isReached
                    )
                }
                guard update.isReached == true, window.isReached != true else { return window }
                changed = true
                var reached = window
                reached.isReached = true
                return reached
            }
            return ProviderQuotaBucket(
                bucketID: bucket.bucketID,
                displayLabel: bucket.displayLabel,
                nativeModelAlias: bucket.nativeModelAlias,
                scope: bucket.scope,
                reachedType: bucket.reachedType,
                isReached: bucket.isReached,
                planType: bucket.planType,
                credits: bucket.credits,
                spendControl: bucket.spendControl,
                windows: windows
            )
        }
        guard changed else { return base }
        return ProviderQuotaSnapshot(
            accountKey: base.accountKey,
            buckets: buckets,
            facets: base.facets,
            source: base.source,
            coverage: base.coverage,
            observedAt: newest
        )
    }
}
