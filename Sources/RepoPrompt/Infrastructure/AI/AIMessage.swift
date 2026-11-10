import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptFileSystem

typealias ConversationEntry = RepoPromptDomainRuntime.ConversationEntry
typealias AIMessage = RepoPromptDomainRuntime.AIMessage

extension AIMessage {
    // MARK: - Temperature helpers

    /// Returns the final temperature to send for a specific model,
    /// respecting global on/off and per-model overrides.
    func effectiveTemperature(for model: AIModel) -> Double? {
        // 1) Explicit per-model override stored by the user.
        if let override = ModelOverridesSettings.shared
            .temperatureOverride(for: model.rawValue)
        {
            return override
        }

        // 2) Global temperature selected by the user.
        if let global = temperature, global != 0.0 {
            return global
        }

        // 3) Built-in per-model default (if any).  If `nil`, omit the field.
        return model.defaultTemperature
    }
}

struct OverallSummary: Codable {
    let overall_summary: String
}

struct AIResponse: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let relativePath: String
    var fileContent: [String]
    var changes: [FileChange]
    var appliedChanges: Set<UUID> = []
    var rejectedChanges: Set<UUID> = []
}
