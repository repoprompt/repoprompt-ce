import Foundation
import RepoPromptRuntimeModel

/// Portable projection of the stable provider choices RepoPrompt Desktop keeps
/// available while account-scoped discovery is starting or temporarily unavailable.
/// Live and persisted provider catalogs remain authoritative when they exist.
public enum DesktopProviderModelFallbackCatalog {
    public static func candidates(for providerID: ProviderSettingsID) -> [AgentCatalogModelCandidate] {
        switch providerID {
        case .codex:
            codexCandidates
        case .claudeCompatible:
            claudeCandidates
        case .cursorACP:
            cursorCandidates
        case .claudeGLM, .claudeKimi, .claudeCustom, .openCodeACP, .grokBuildACP,
             .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            []
        }
    }

    private static let codexCandidates = withFastVariants([
        codex(
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            description: "RepoPrompt Desktop's primary Codex model for agentic work.",
            efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultEffort: "medium",
            isDefault: true
        ),
        codex(
            id: "gpt-5.6-terra",
            name: "GPT-5.6 Terra",
            description: "Cost-conscious GPT-5.6 model for routine agentic work.",
            efforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.6-luna",
            name: "GPT-5.6 Luna",
            description: "Cost-sensitive GPT-5.6 model for lighter tasks.",
            efforts: ["low", "medium", "high", "xhigh", "max"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.3-codex",
            name: "GPT-5.3 Codex",
            description: "Codex model retained by Desktop as a stable engineering fallback.",
            efforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.4",
            name: "GPT-5.4",
            description: "General-purpose GPT-5.4 model exposed by RepoPrompt Desktop.",
            efforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.4-mini",
            name: "GPT-5.4 Mini",
            description: "Fast model for exploration and lightweight work.",
            efforts: ["low", "medium", "high"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.2",
            name: "GPT-5.2",
            description: "General-purpose GPT-5.2 model retained by RepoPrompt Desktop.",
            efforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: "medium"
        ),
        codex(
            id: "gpt-5.1-codex-mini",
            name: "GPT-5.1 Codex Mini",
            description: "Ultra-fast model for quick lookups and simple edits.",
            efforts: [],
            defaultEffort: nil
        )
    ])

    private static let claudeCandidates: [AgentCatalogModelCandidate] = [
        .init(
            modelID: "sonnet",
            rawValue: "sonnet",
            displayName: "Sonnet Latest",
            description: "RepoPrompt Desktop's balanced Claude Code choice.",
            isProviderDefault: true,
            capabilities: .init(nativeImages: true)
        ),
        .init(
            modelID: "opus",
            rawValue: "opus",
            displayName: "Opus Latest",
            description: "Claude Code choice for complex reasoning and architecture.",
            capabilities: .init(nativeImages: true)
        ),
        .init(
            modelID: "haiku",
            rawValue: "haiku",
            displayName: "Haiku Latest",
            description: "Claude Code choice for fast, lightweight work.",
            capabilities: .init(nativeImages: true)
        )
    ]

    private static let cursorCandidates: [AgentCatalogModelCandidate] = [
        .init(
            modelID: "auto",
            rawValue: "auto",
            displayName: "Auto",
            description: "Let Cursor choose the best model automatically.",
            isProviderDefault: true
        ),
        .init(
            modelID: "composer-2",
            rawValue: "composer-2",
            displayName: "Composer 2",
            description: "Cursor's Composer 2 model."
        )
    ]

    private static func codex(
        id: String,
        name: String,
        description: String,
        efforts: [String],
        defaultEffort: String?,
        isDefault: Bool = false
    ) -> AgentCatalogModelCandidate {
        .init(
            modelID: id,
            rawValue: id,
            displayName: name,
            description: description,
            supportedEffortIDs: efforts,
            defaultEffortID: defaultEffort,
            isProviderDefault: isDefault,
            capabilities: .init(nativeImages: true, steering: true)
        )
    }

    private static func withFastVariants(_ candidates: [AgentCatalogModelCandidate]) -> [AgentCatalogModelCandidate] {
        candidates + candidates.compactMap { candidate in
            guard CodexServiceTierAvailability.isFastEligible(baseModelID: candidate.modelID) else { return nil }
            let detail = candidate.description.map { "\($0) \(CodexServiceTierAvailability.fastCostWarningText)" }
                ?? CodexServiceTierAvailability.fastCostWarningText
            return .init(
                modelID: "\(candidate.modelID)-fast",
                rawValue: candidate.rawValue,
                displayName: "\(candidate.displayName) Fast",
                description: detail,
                supportedEffortIDs: candidate.supportedEffortIDs,
                defaultEffortID: candidate.defaultEffortID,
                serviceTier: CodexServiceTierAvailability.fastServiceTier,
                capabilities: candidate.capabilities
            )
        }
    }
}
