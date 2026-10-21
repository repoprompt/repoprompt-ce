import Foundation
import RepoPromptProviderQuota

/// Three local policies; no Jev score, plan-size declaration, or task/token-cost inference.
enum AgentUsageBalancingPreset: String, CaseIterable, Identifiable {
    case nearLimits, evenPace, expiringQuota
    var id: String {
        rawValue
    }

    var strategy: ProviderUsageBalancePolicy.Strategy {
        switch self {
        case .nearLimits: .nearLimits
        case .evenPace: .evenPace
        case .expiringQuota: .expiringQuota
        }
    }

    var title: String {
        switch self {
        case .nearLimits: "Only near limits"
        case .evenPace: "Even pace"
        case .expiringQuota: "Use expiring quota first"
        }
    }

    var explanation: String {
        switch self {
        case .nearLimits: "Keep the starting model unless its plan is at least 90% used."
        case .evenPace: "Shift work toward the plan with more unused weekly allowance relative to time until it resets."
        case .expiringQuota: "Use spare weekly allowance that resets within a day; otherwise balance the weekly pace."
        }
    }

    static func stored(_ raw: String?) -> Self? {
        guard let raw else { return .evenPace }
        // Preserve intent from the locally tested prototype, without requiring a plan-size input.
        switch raw {
        case "qualityFirst": return .nearLimits
        case "balanced": return .evenPace
        case "favorLargerPlan": return .expiringQuota
        default: return Self(rawValue: raw)
        }
    }
}

struct AgentUsageBalancingConfiguration: Equatable {
    var enabled = false
    var preset: AgentUsageBalancingPreset = .evenPace
    /// When one plan's usage is critical, route only to that provider instead of mixing with Model Router.
    var overrideRouter = false

    var overridesRouter: Bool {
        enabled && overrideRouter
    }
}

/// Thin app adapter: maps routing candidates onto the provider-neutral `ProviderUsageBalancer`.
@MainActor
final class AgentUsageBalancer {
    struct Decision {
        let candidate: AgentTaskRoutingCandidateBuilder.Candidate
        let reason: String?
    }

    private let core = ProviderUsageBalancer()
    private(set) var revision: UInt64 = 0

    var onRoutingActivity: (() -> Void)? {
        get { core.onRoutingActivity }
        set { core.onRoutingActivity = newValue }
    }

    func update(_ snapshot: ProviderQuotaSnapshot?, provider: String) {
        if core.update(snapshot, provider: provider) { revision &+= 1 }
    }

    func clear() {
        if core.clear() { revision &+= 1 }
    }

    /// Critical usage replaces mixed routing: only the dominant provider's usable candidates remain,
    /// so Model Router chooses within it (or is skipped when one candidate remains).
    func routerOverride(
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        configuration: AgentTaskRouterConfiguration,
        scope: AgentTaskRoutingScope,
        now: Date = Date()
    ) -> (candidates: [AgentTaskRoutingCandidateBuilder.Candidate], reason: String)? {
        guard configuration.usageBalancing.overridesRouter,
              let forced = core.usageOverride(options: candidates.map(Self.option), now: now) else { return nil }
        let usable = forced.indices.map { candidates[$0] }
        // Narrowing the provider must not lower the main session's tier: a single-provider list
        // lets the router pick Haiku or Sonnet where mixed routing would choose Opus or Sol.
        // With no strong/frontier model available, mixed routing stays in charge rather than downgrading.
        let floored = scope == .primarySession ? usable.filter { Self.mainSessionPeerClasses.contains($0.usagePeerClass ?? "") } : usable
        return floored.isEmpty ? nil : (floored, Self.overrideReason(forced.reason))
    }

    /// Tiers a usage override may choose for a primary session.
    static let mainSessionPeerClasses: Set<String> = ["strong", "frontier"]

    func choose(
        selected: AgentTaskRoutingCandidateBuilder.Candidate,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        evidence _: DecisionEvidence?,
        configuration: AgentTaskRouterConfiguration,
        now: Date = Date()
    ) -> Decision {
        let settings = configuration.usageBalancing
        if settings.overridesRouter,
           let forced = core.usageOverride(options: candidates.map(Self.option), now: now)
        {
            let usable = forced.indices.map { candidates[$0] }
            if usable.contains(selected) { return Decision(candidate: selected, reason: nil) }
            if let peer = usable.first(where: { $0.usagePeerClass == selected.usagePeerClass }) {
                return Decision(candidate: peer, reason: Self.overrideReason(forced.reason))
            }
        }
        guard settings.enabled,
              let index = core.preferredPeerIndex(
                  selected: Self.option(selected),
                  options: candidates.map(Self.option),
                  strategy: settings.preset.strategy,
                  now: now
              ) else { return Decision(candidate: selected, reason: nil) }
        return Decision(candidate: candidates[index], reason: "usage_balance_\(settings.preset.rawValue)")
    }

    private static func overrideReason(_ reason: ProviderUsageBalancePolicy.OverrideReason) -> String {
        "usage_override_\(reason.rawValue)"
    }

    private static func option(_ candidate: AgentTaskRoutingCandidateBuilder.Candidate) -> ProviderUsageModelOption {
        ProviderUsageModelOption(
            provider: candidate.target.agentRaw,
            peerClass: candidate.usagePeerClass,
            modelAliases: candidate.usageModelAliases.union([candidate.target.modelRaw]),
            isPaidFast: AgentTaskRoutingCandidateBuilder.isPaidFast(candidate.target)
        )
    }
}
