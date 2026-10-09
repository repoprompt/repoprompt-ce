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
        case .evenPace: "Shift work toward the plan using less of its weekly allowance relative to time until reset."
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
}

/// Thin app adapter: maps routing candidates onto the provider-neutral `ProviderUsageBalancer`.
@MainActor
final class AgentUsageBalancer {
    struct Decision {
        let candidate: AgentTaskRoutingCandidateBuilder.Candidate
        let reason: String?
    }

    private let core = ProviderUsageBalancer()

    var onRoutingActivity: (() -> Void)? {
        get { core.onRoutingActivity }
        set { core.onRoutingActivity = newValue }
    }

    func update(_ snapshot: ProviderQuotaSnapshot?, provider: String) {
        core.update(snapshot, provider: provider)
    }

    func clear() {
        core.clear()
    }

    func choose(
        selected: AgentTaskRoutingCandidateBuilder.Candidate,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        evidence _: AgentTaskRoutingDecisionEvidence?,
        configuration: AgentTaskRouterConfiguration,
        now: Date = Date()
    ) -> Decision {
        let settings = configuration.usageBalancing
        guard settings.enabled,
              let index = core.preferredPeerIndex(
                  selected: Self.option(selected),
                  options: candidates.map(Self.option),
                  strategy: settings.preset.strategy,
                  now: now
              ) else { return Decision(candidate: selected, reason: nil) }
        return Decision(candidate: candidates[index], reason: "usage_balance_\(settings.preset.rawValue)")
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
