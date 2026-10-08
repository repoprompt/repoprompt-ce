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

/// Attributed memory cache over a pure policy. No provider IO, timer, or external disclosure.
@MainActor
final class AgentUsageBalancer {
    struct Decision {
        let candidate: AgentTaskRoutingCandidateBuilder.Candidate
        let reason: String?
    }

    private var snapshots: [String: ProviderQuotaSnapshot] = [:]
    var onRoutingActivity: (() -> Void)?

    func update(_ snapshot: ProviderQuotaSnapshot?, provider: String) {
        snapshots[provider] = snapshot
    }

    func clear() {
        snapshots.removeAll()
    }

    func choose(
        selected: AgentTaskRoutingCandidateBuilder.Candidate,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        evidence _: AgentTaskRoutingDecisionEvidence?,
        configuration: AgentTaskRouterConfiguration,
        now: Date = Date()
    ) -> Decision {
        let unchanged = Decision(candidate: selected, reason: nil)
        guard configuration.usageBalancing.enabled else { return unchanged }
        onRoutingActivity?()
        guard let peerClass = selected.usagePeerClass,
              let peer = candidates.first(where: {
                  $0.usagePeerClass == peerClass && $0.target.agentRaw != selected.target.agentRaw
                      && !AgentTaskRoutingCandidateBuilder.isPaidFast($0.target)
              }) else { return unchanged }
        let base = reading(for: selected, now: now)
        let other = reading(for: peer, now: now)
        guard ProviderUsageBalancePolicy.preferPeer(base: base, peer: other, strategy: configuration.usageBalancing.preset.strategy) else { return unchanged }
        return Decision(candidate: peer, reason: "usage_balance_\(configuration.usageBalancing.preset.rawValue)")
    }

    private func reading(for candidate: AgentTaskRoutingCandidateBuilder.Candidate, now: Date) -> ProviderUsageBalancePolicy.Reading {
        ProviderUsageBalancePolicy.reading(
            snapshots[candidate.target.agentRaw],
            now: now,
            modelAliases: candidate.usageModelAliases.union([candidate.target.modelRaw])
        )
    }
}
