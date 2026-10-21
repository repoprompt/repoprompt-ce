import Foundation
import RepoPromptSettingsCore

/// Re-prompt selects a billing route once, before starting. Failures never re-resolve it.
enum AgentRepromptModelPolicy {
    static let preferredClaude = AIModel.claudeCodeModel(specifier: "claude-sonnet-5-5:low")
    static let preferredCodex = AIModel.codexCliGpt61SolLow

    static func supportsSideCall(_ model: AIModel) -> Bool {
        switch model.providerType {
        case .cursor, .openCode, .devin, .grokBuild: false
        default: true
        }
    }

    static func resolve(selection: String?, currentProvider: AgentProviderKind?, configured: [AIModel]) -> AIModel? {
        let models = configured.filter(supportsSideCall)
        if let selection, !selection.isEmpty {
            // An explicit disconnected or unknown model is an error, never an automatic fallback.
            return AIModel.fromModelName(selection).flatMap { models.contains($0) ? $0 : nil }
        }
        let subscriptions = currentProvider == .codexExec
            ? [preferredCodex, preferredClaude] : [preferredClaude, preferredCodex]
        for model in subscriptions where models.contains(model) {
            return model
        }
        // A bounded fast-tier allowlist, never arbitrary catalog order or the Oracle roster.
        // Unavailable subscription IDs are not replaced with another tier on that subscription.
        for model in [AIModel.claudeSonnet55, .gpt61SolLow, .gemini3FlashPreview] where models.contains(model) {
            return model
        }
        return nil
    }

    static func manifest(rootNames: [String], selectedPaths: [String]) -> String {
        var lines: [String] = []
        for line in rootNames.map({ "Root: \($0)" }) + selectedPaths.prefix(50) {
            guard (lines + [line]).joined(separator: "\n").utf8.count <= 4 * 1024 - 64 else { break }
            lines.append(line)
        }
        if selectedPaths.count > 50 { lines.append("+\(selectedPaths.count - 50) more") }
        return lines.joined(separator: "\n")
    }
}
