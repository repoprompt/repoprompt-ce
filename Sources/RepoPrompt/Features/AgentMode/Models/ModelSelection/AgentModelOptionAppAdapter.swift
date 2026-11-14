import Foundation
import RepoPromptAIContracts

extension AgentModelOption {
    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        supportedReasoningEffortRawValues: [String] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        defaultReasoningEffortRawValue: String? = nil,
        effortVariant: AgentModelEffortVariant? = nil,
        contextWindowTokens: Int? = nil
    ) {
        let isPlaceholder =
            rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        self.init(
            rawValue: rawValue,
            displayName: displayName,
            description: description,
            isPlaceholderDefault: isPlaceholder && isDefault,
            isProviderDefault: !isPlaceholder && isDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            supportedReasoningEffortRawValues: supportedReasoningEffortRawValues,
            defaultReasoningEffort: defaultReasoningEffort,
            defaultReasoningEffortRawValue: defaultReasoningEffortRawValue,
            effortVariant: effortVariant,
            contextWindowTokens: contextWindowTokens
        )
    }
}
