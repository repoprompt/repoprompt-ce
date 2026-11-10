import Foundation

/// Provenance for a synthesized reasoning-effort variant option: the base model raw and the
/// effort it encodes. Present only on variant options — bases and plain models leave it nil,
/// so no layer ever re-parses compound raw strings to recover the decomposition.
package struct AgentModelEffortVariant: Hashable, Codable {
    package let baseModelRaw: String
    package let reasoningEffort: CodexReasoningEffort

    package init(baseModelRaw: String, reasoningEffort: CodexReasoningEffort) {
        self.baseModelRaw = baseModelRaw
        self.reasoningEffort = reasoningEffort
    }
}

package struct AgentModelOption: Identifiable, Hashable {
    package let rawValue: String
    package let displayName: String
    package let description: String?
    package let isPlaceholderDefault: Bool
    package let isProviderDefault: Bool
    package let supportedReasoningEfforts: [CodexReasoningEffort]
    /// Exact provider-advertised values, including values this app cannot yet execute.
    package let supportedReasoningEffortRawValues: [String]
    package let defaultReasoningEffort: CodexReasoningEffort?
    package let defaultReasoningEffortRawValue: String?
    package let effortVariant: AgentModelEffortVariant?
    /// Provider-reported model capacity, when advertised (not a local fallback).
    package let contextWindowTokens: Int?

    package init(
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

    package var isDefault: Bool {
        isPlaceholderDefault || isProviderDefault
    }

    package var id: String {
        rawValue
    }
}
