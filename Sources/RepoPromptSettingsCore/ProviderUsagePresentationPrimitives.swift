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

    package static func claude(grant: ClaudeAccountUsageGrant?, currentProfileID: String?) -> Self {
        if let grant, let currentProfileID, grant.applies(toProfileID: currentProfileID) { return .active(deactivateTitle: "Disconnect") }
        let explanation = grant == nil ? "Connect to read plan limits using your Claude Code login."
            : "Connected for a different Claude profile. Connect again to use this profile."
        return .inactive(activateTitle: "Connect Claude usage…", explanation: explanation, requiresConsent: true)
    }
}

package struct AgentUsageLimitsPillPresentation: Equatable {
    package let label: String
    package let ringFraction: Double?
    package let isReached: Bool
    package let tooltip: String
    package init?(usedPercent: Int?, isReached: Bool, resetAt: Date?, providerName: String, now: Date) {
        guard usedPercent != nil || isReached else { return nil }
        self.isReached = isReached
        label = isReached ? "Limit" : usedPercent.map { "\($0)%" } ?? ""
        ringFraction = usedPercent.map { min(max(Double($0), 0), 100) / 100 }
        var parts: [String] = []
        if isReached { parts.append("\(providerName) plan limit reached") }
        else if let usedPercent { parts.append("\(providerName) plan usage: \(usedPercent)% used") }
        if let resetAt, resetAt > now { parts.append("resets \(ProviderQuotaPresenter.resetText(resetAt, now: now))") }
        tooltip = parts.joined(separator: " · ")
    }
}
