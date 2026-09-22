import Foundation

/// Audited, dated evidence supplied to semantic routers alongside each configured target.
///
/// This is product routing policy rather than a provider catalog: the runtime catalog remains
/// authoritative for model availability, while this snapshot gives the router comparable clues
/// about capability and API list price. Refresh the snapshot when recommended model families,
/// aliases, published evaluations, or prices change.
enum AgentTaskRoutingModelProfileCatalog {
    static let evidenceVersion = "rpce.model-routing-evidence.2026-09-19"
    static let rubricVersion = "rpce.automatic-utility-frontier.v1-evidence-2026-09-19"

    static func description(for target: AgentRoutingExecutableTarget) -> String {
        let modelIdentity = normalizedModelIdentity(for: target)
        let evidence = profile(for: modelIdentity)
        let effort = effortDescription(for: target)
        return "Evidence snapshot 2026-09-19 (provider-published; API list price is a comparison proxy and CLI or subscription billing may differ): \(evidence) \(effort)"
    }

    static func modelDescription(for target: AgentRoutingExecutableTarget) -> String {
        let modelIdentity = normalizedModelIdentity(for: target)
        return "Evidence snapshot 2026-09-19 (provider-published; API list price is a comparison proxy and CLI or subscription billing may differ): \(profile(for: modelIdentity))"
    }

    private static func profile(for modelIdentity: String) -> String {
        switch modelIdentity {
        case "gpt-5.6-luna":
            "GPT-5.6 Luna is the nano-tier, fastest GPT-5.6 option for cost-sensitive, high-volume work; OpenAI reports 74.6 on Artificial Analysis Coding Agent Index v1.1 and 84.7% on Terminal-Bench 2.1. API list price: $0.20 input / $1.20 output per 1M tokens."
        case "gpt-5.6-terra":
            "GPT-5.6 Terra is the balanced intelligence-and-cost tier for everyday agentic work; OpenAI reports 77.4 on Artificial Analysis Coding Agent Index v1.1 and 87.4% on Terminal-Bench 2.1. API list price: $2 input / $12 output per 1M tokens."
        case "gpt-5.6-sol", "gpt-5.6":
            "GPT-5.6 Sol is the flagship tier for complex professional work; OpenAI reports 80.0 on Artificial Analysis Coding Agent Index v1.1 and 88.8% on Terminal-Bench 2.1. API list price: $4 input / $20 output per 1M tokens."
        case "gpt-6-astra":
            "GPT-6 Astra is OpenAI's most capable tier for the hardest end-to-end reasoning, coding, research, and computer-use work. API list price: $10 input / $50 output per 1M tokens. No directly comparable coding score is included in this snapshot."
        case "haiku", "claude-haiku-4-5", "claude-haiku-4-5-20251001":
            "Claude Haiku 4.5 is the fast, economical Claude tier for responsive and bounded work; Anthropic reports similar coding performance to Sonnet 4 and 90% of Sonnet 4.5 on Augment's agentic coding evaluation. API list price: $1 input / $5 output per 1M tokens."
        case "sonnet", "sonnet[1m]", "claude-sonnet-5":
            "Claude Sonnet 5 is the balanced Claude tier for sustained everyday coding, tool use, and debugging; Anthropic reports that high effort can match Opus 4.8 on some agentic search and computer-use tasks. API list price: $2 input / $10 output per 1M tokens."
        case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929":
            "This is an older Claude Sonnet tier for balanced coding and analysis. API list price: $3 input / $15 output per 1M tokens. No current comparable coding score is included in this snapshot."
        case "opus", "opus[1m]", "claude-opus-5":
            "Claude Opus 5 is a premium tier for production-ready code, long-running agents, difficult debugging, and complex knowledge work; Anthropic reports frontier performance on Frontier-Bench and near-Fable coding capability at about half Fable's token price. API list price: $5 input / $25 output per 1M tokens."
        case "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-opus-4-5-20251101":
            "This is an older premium Claude Opus tier for complex coding and agentic work. API list price: $5 input / $25 output per 1M tokens. No current comparable coding score is included in this snapshot."
        case "fable", "claude-fable-5-1":
            "Claude Fable 5.1 is Anthropic's most capable generally available tier for ambitious, long-running, cross-codebase work; Anthropic reports 55.8% on Terminal-Bench 4.0 versus 52.3% for Opus 5 and 37.3% for GPT-5.6 Sol in its harness. API list price: $10 input / $50 output per 1M tokens."
        case "claude-fable-5":
            "Claude Fable 5 is a frontier tier for ambitious, long-running work; Anthropic reports 42.0% on Terminal-Bench 4.0 in its later comparison. API list price: $10 input / $50 output per 1M tokens."
        default:
            "No audited benchmark or pricing profile is available for this exact model identity. Treat capability and cost as uncertain and rely on its configured role rubric rather than assuming it is cheap or strong."
        }
    }

    private static func normalizedModelIdentity(for target: AgentRoutingExecutableTarget) -> String {
        let raw = target.modelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if target.agentRaw == AgentProviderKind.codexExec.rawValue {
            return CodexModelSpecifier(raw: raw).baseModel?.lowercased() ?? raw
        }
        if target.agentRaw == AgentProviderKind.claudeCode.rawValue {
            return ClaudeModelSpecifier(raw: raw).baseModel?.lowercased() ?? raw
        }
        return raw
    }

    static func effortDescription(for target: AgentRoutingExecutableTarget) -> String {
        let codexEffort = target.reasoningEffortRaw?.lowercased()
        let claudeEffort = target.agentRaw == AgentProviderKind.claudeCode.rawValue
            ? ClaudeModelSpecifier(raw: target.modelRaw).effortLevel?.rawValue
            : nil
        let parameterEffort = target.modelParameters.first(where: { $0.kind == .thinking })?.valueRaw.lowercased()
        guard let effort = codexEffort ?? claudeEffort ?? parameterEffort else {
            return "Effort is provider-default or unspecified, so total task cost and quality are less predictable."
        }

        switch effort {
        case "none", "minimal", "low":
            return "Effort: \(effort); lower test-time compute favors latency and cost, so use it only when the task has a clear reliability margin."
        case "medium":
            return "Effort: medium; balanced test-time compute for routine execution."
        case "high", "xhigh", "x-high":
            return "Effort: \(effort); deeper test-time reasoning can improve difficult-task reliability but may increase tokens, latency, and total cost."
        case "max", "maximum", "ultra":
            return "Effort: \(effort); reserve this highest-compute setting for exceptional complexity because tokens, latency, and total cost can rise substantially."
        default:
            return "Effort: \(effort); its cost-quality effect is not audited in this snapshot."
        }
    }
}
