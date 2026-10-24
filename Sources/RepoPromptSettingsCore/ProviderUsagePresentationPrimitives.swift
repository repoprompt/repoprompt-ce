import Foundation
import RepoPromptProviderQuota

/// UI value semantics belong to the reusable Settings owner, not the app composition target.
package enum ProviderUsageSourceState: Equatable {
    case active(deactivateTitle: String)
    case inactive(activateTitle: String, explanation: String, requiresConsent: Bool)
    package var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    package static func codex(enabled: Bool) -> Self {
        enabled ? .active(deactivateTitle: "Turn off") : .inactive(
            activateTitle: "Turn on Codex usage",
            explanation: "Reads plan limits from the Codex app server only while usage is on screen.",
            requiresConsent: false
        )
    }

    package static func claude(grant: ClaudeCLIUsageGrant?, currentProfileID: String?) -> Self {
        if let grant, let currentProfileID, grant.applies(toProfileID: currentProfileID) { return .active(deactivateTitle: "Disconnect") }
        let explanation = grant == nil ? "Connect to read plan limits through Claude Code’s /usage command."
            : "Connected for a different Claude profile. Connect again to use this profile."
        return .inactive(activateTitle: "Connect Claude usage…", explanation: explanation, requiresConsent: true)
    }
}

package struct AgentUsageLimitsPillPresentation: Equatable {
    package let label: String
    package let ringFraction: Double?
    /// Position of the short-window (e.g. 5-hour) bead on the same track, 0...1.
    package let sessionFraction: Double?
    /// The short window is near (>= 80%) or at its limit; the bead turns warm.
    package let sessionIsHot: Bool
    package let isReached: Bool
    /// Not current: stale, reset-passed, unavailable, or updating. The pill dims in place.
    package let isDimmed: Bool
    package let tooltip: String

    package init(state: ProviderQuotaIndicatorState, providerName: String, now: Date) {
        if let value = Self(
            usedPercent: state.usedPercent,
            isReached: state.isReached,
            resetAt: state.resetAt,
            providerName: providerName,
            now: now,
            shortWindowPercent: state.shortWindowPercent,
            shortWindowIsReached: state.shortWindowIsReached,
            shortWindowResetAt: state.shortWindowResetAt,
            freshness: state.freshness,
            observedAt: state.observedAt,
            isUpdating: state.isUpdating,
            refreshFailed: state.refreshFailed
        ) {
            self = value
        } else {
            self.init(unavailableFor: providerName, isUpdating: state.isUpdating)
        }
    }

    package init?(
        usedPercent: Int?,
        isReached: Bool,
        resetAt: Date?,
        providerName: String,
        now: Date,
        shortWindowPercent: Int? = nil,
        shortWindowIsReached: Bool = false,
        shortWindowResetAt: Date? = nil,
        freshness: ProviderQuotaIndicatorState.Freshness = .fresh,
        observedAt: Date? = nil,
        isUpdating: Bool = false,
        refreshFailed: Bool = false
    ) {
        if freshness == .unavailable {
            self.init(unavailableFor: providerName, isUpdating: isUpdating)
            return
        }
        guard usedPercent != nil || isReached else { return nil }
        var parts: [String] = []
        if isReached { parts.append("\(providerName) plan limit reached") }
        else if let usedPercent { parts.append("\(providerName) plan usage: \(usedPercent)% used") }
        if let resetAt, resetAt > now { parts.append("resets \(ProviderQuotaPresenter.resetText(resetAt, now: now))") }
        if shortWindowIsReached {
            parts.append("5-hour limit reached")
        } else if let shortWindowPercent {
            var session = "5-hour: \(shortWindowPercent)%"
            if let shortWindowResetAt, shortWindowResetAt > now {
                session += ", resets \(ProviderQuotaPresenter.resetText(shortWindowResetAt, now: now))"
            }
            parts.append(session)
        }
        if refreshFailed { parts.append("Couldn't refresh") }
        switch freshness {
        case .stale:
            if let observedAt { parts.append("Updated \(ProviderQuotaPresenter.relativeAge(from: observedAt, to: now))") }
        case .resetPassed:
            parts.append("Reset passed")
        case .fresh, .unavailable:
            break
        }
        if isUpdating { parts.append("updating…") }
        self.init(
            label: isReached ? "Limit" : usedPercent.map { "\($0)%" } ?? "",
            ringFraction: usedPercent.map { min(max(Double($0), 0), 100) / 100 },
            sessionFraction: shortWindowIsReached ? 1 : shortWindowPercent.map { min(max(Double($0), 0), 100) / 100 },
            sessionIsHot: shortWindowIsReached || (shortWindowPercent ?? 0) >= 80,
            isReached: isReached,
            isDimmed: freshness != .fresh || isUpdating,
            tooltip: parts.joined(separator: " · ")
        )
    }

    /// Neutral placeholder kept in place after the snapshot was cleared.
    private init(unavailableFor providerName: String, isUpdating: Bool) {
        var parts = ["\(providerName) plan usage unavailable — sign in or reconnect in Settings"]
        if isUpdating { parts.append("updating…") }
        self.init(label: "—", ringFraction: nil, sessionFraction: nil, sessionIsHot: false, isReached: false, isDimmed: true, tooltip: parts.joined(separator: " · "))
    }

    private init(label: String, ringFraction: Double?, sessionFraction: Double?, sessionIsHot: Bool, isReached: Bool, isDimmed: Bool, tooltip: String) {
        self.label = label
        self.ringFraction = ringFraction
        self.sessionFraction = sessionFraction
        self.sessionIsHot = sessionIsHot
        self.isReached = isReached
        self.isDimmed = isDimmed
        self.tooltip = tooltip
    }
}
