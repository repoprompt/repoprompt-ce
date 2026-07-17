import Foundation

enum RecommendationWizardScopePresentation {
    static let mcpPresetsScopeLabel = "MCP Presets: Global settings"

    static func agentModelsScopeLabel(
        for target: AgentModelsOperationIdentity,
        workspaceName: String?
    ) -> String {
        switch target.scope {
        case .global:
            return "Agent Models: Global settings"
        case .workspace:
            let trimmedName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = if let trimmedName, !trimmedName.isEmpty {
                trimmedName
            } else {
                "Unnamed Workspace"
            }
            return "Agent Models: Workspace — \(displayName)"
        }
    }
}
