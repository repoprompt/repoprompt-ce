import Foundation
import RepoPromptAIContracts
import RepoPromptCodexProvider

/// Frozen model policy, shared by interactive selection and saved-session hydration.
/// Preference lookup belongs to composition; resolving a selection never reads a VM.
struct AgentCodexSelectionPolicy {
    let options: [CodexReasoningEffort]
    let defaultEffort: CodexReasoningEffort?
    let lastUsed: CodexReasoningEffort?

    static func normalizedModelRaw(from raw: String?) -> String {
        let specifier = CodexModelSpecifier(raw: raw)
        guard let baseModel = specifier.baseModel else { return AgentModel.defaultModel.rawValue }
        if let serviceTier = CodexServiceTierVariantCatalog.supportedServiceTier(
            baseModelID: baseModel, serviceTier: specifier.serviceTier
        ) {
            return "\(baseModel)-\(serviceTier)"
        }
        return baseModel
    }

    func reasoningEffort(modelRaw: String, explicitRaw: String?) -> CodexReasoningEffort? {
        guard !options.isEmpty else { return nil }
        let candidates = [
            CodexReasoningEffort.parse(explicitRaw),
            CodexModelSpecifier(raw: modelRaw).reasoningEffort,
            lastUsed,
            defaultEffort,
            .medium
        ]
        return candidates.compactMap(\.self).first(where: options.contains) ?? options.first
    }
}
