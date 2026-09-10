import Foundation

/// Provenance for a synthesized reasoning-effort variant option: the base model raw and the
/// effort it encodes. Present only on variant options — bases and plain models leave it nil,
/// so no layer ever re-parses compound raw strings to recover the decomposition.
struct AgentModelEffortVariant: Hashable, Codable {
    let baseModelRaw: String
    let reasoningEffort: CodexReasoningEffort
}

/// Native grouping a provider advertises for a model (Devin's account catalog families).
/// Presentation only: it never adds or removes a selectable model.
struct AgentModelFamily: Hashable, Codable {
    let id: String
    let displayName: String
}

struct AgentModelOption: Identifiable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?
    let isPlaceholderDefault: Bool
    let isProviderDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let defaultReasoningEffort: CodexReasoningEffort?
    let effortVariant: AgentModelEffortVariant?
    let modelFamily: AgentModelFamily?

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isPlaceholderDefault: Bool,
        isProviderDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        effortVariant: AgentModelEffortVariant? = nil,
        modelFamily: AgentModelFamily? = nil
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        self.isPlaceholderDefault = isPlaceholderDefault
        self.isProviderDefault = isProviderDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.effortVariant = effortVariant
        self.modelFamily = modelFamily
    }

    init(
        rawValue: String,
        displayName: String,
        description: String?,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = [],
        defaultReasoningEffort: CodexReasoningEffort? = nil,
        effortVariant: AgentModelEffortVariant? = nil,
        modelFamily: AgentModelFamily? = nil
    ) {
        let isPlaceholder =
            rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
        isPlaceholderDefault = isPlaceholder && isDefault
        isProviderDefault = !isPlaceholder && isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.effortVariant = effortVariant
        self.modelFamily = modelFamily
    }

    var isDefault: Bool {
        isPlaceholderDefault || isProviderDefault
    }

    var id: String {
        rawValue
    }
}
