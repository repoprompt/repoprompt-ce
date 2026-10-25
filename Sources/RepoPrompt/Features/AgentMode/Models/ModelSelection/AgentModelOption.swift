import Foundation

/// Provenance for a synthesized reasoning-effort variant option: the base model raw and the
/// effort it encodes. Present only on variant options — bases and plain models leave it nil,
/// so no layer ever re-parses compound raw strings to recover the decomposition.
struct AgentModelEffortVariant: Hashable, Codable {
    let baseModelRaw: String
    let reasoningEffort: CodexReasoningEffort
}

struct AgentModelOption: Identifiable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?
    let isPlaceholderDefault: Bool
    let isProviderDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffort]
    /// Exact provider-advertised values, including values this app cannot yet execute.
    let supportedReasoningEffortRawValues: [String]
    let defaultReasoningEffort: CodexReasoningEffort?
    let defaultReasoningEffortRawValue: String?
    let effortVariant: AgentModelEffortVariant?
    /// Provider-reported model capacity, when advertised (not a local fallback).
    let contextWindowTokens: Int?

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        supportedReasoningEffortRawValues: [String] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        defaultReasoningEffortRawValue: String? = nil,
        effortVariant: AgentModelEffortVariant? = nil,
        contextWindowTokens: Int? = nil
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportedReasoningEffortRawValues = supportedReasoningEffortRawValues
        self.defaultReasoningEffort = defaultReasoningEffort
        self.defaultReasoningEffortRawValue = defaultReasoningEffortRawValue
        self.effortVariant = effortVariant
        self.contextWindowTokens = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
    }

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
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        isPlaceholderDefault = isPlaceholder && isDefault
        isProviderDefault = !isPlaceholder && isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportedReasoningEffortRawValues = supportedReasoningEffortRawValues
        self.defaultReasoningEffort = defaultReasoningEffort
        self.defaultReasoningEffortRawValue = defaultReasoningEffortRawValue
        self.effortVariant = effortVariant
        self.contextWindowTokens = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
    }

    var isDefault: Bool {
        isPlaceholderDefault || isProviderDefault
    }

    var id: String {
        rawValue
    }
}
