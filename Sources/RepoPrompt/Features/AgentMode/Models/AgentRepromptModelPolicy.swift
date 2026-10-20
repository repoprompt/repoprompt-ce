import Foundation
import RepoPromptSettingsCore

/// Re-prompt selects a billing route once, before starting. Failures never re-resolve it.
enum AgentRepromptModelPolicy {
    static let primaryOracle = AgentRepromptModelPreference.primaryOracle
    static let preferredClaude = AIModel.claudeCodeModel(specifier: "claude-sonnet-5-5:low")
    static let preferredCodex = AIModel.codexCliGpt61SolLow

    static func supportsSideCall(_ model: AIModel) -> Bool {
        switch model.providerType {
        case .cursor, .openCode, .devin, .grokBuild: false
        default: true
        }
    }

    static func resolve(selection: String?, primary: AIModel?, currentProvider: AgentProviderKind?, configured: [AIModel]) -> AIModel? {
        let models = configured.filter(supportsSideCall)
        if selection == primaryOracle {
            return primary.flatMap { models.contains($0) ? $0 : nil }
        }
        if let selection, !selection.isEmpty {
            // An explicit disconnected or unknown model is an error, never an automatic fallback.
            return AIModel.fromModelName(selection).flatMap { models.contains($0) ? $0 : nil }
        }
        let subscriptions = currentProvider == .codexExec
            ? [preferredCodex, preferredClaude] : [preferredClaude, preferredCodex]
        for model in subscriptions where models.contains(model) {
            return model
        }
        for provider in currentProvider == .codexExec ? [AIProviderType.codex, .claudeCode] : [.claudeCode, .codex] {
            if let model = models.first(where: {
                $0.providerType == provider && ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) == nil
                    && ($0.defaultReasoningEffort == "low" || $0.claudeCodeRuntimeSpecifierRaw?.hasSuffix(":low") == true)
            }) { return model }
        }
        for model in [AIModel.claudeSonnet55, .gpt61SolLow, .gemini3FlashPreview] where models.contains(model) && model != primary {
            return model
        }
        if let model = models.first(where: {
            $0 != primary && $0.providerType != .codex
                && ($0.providerType != .claudeCode || ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) != nil)
        }) { return model }
        return primary.flatMap { models.contains($0) ? $0 : nil }
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
