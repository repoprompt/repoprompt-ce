import Foundation

/// Centralizes context builder budget selection so UI and MCP paths resolve
/// clarify/omitted runs and follow-up-generation runs consistently.
enum ContextBuilderBudgetResolver {
    static func resolveUIBudget(
        behaviorSettings: ContextBuilderBehaviorSettings
    ) -> Int {
        behaviorSettings.followUpAnalysisEnabled
            ? behaviorSettings.analysisTokenBudget
            : behaviorSettings.contextTokenBudget
    }

    static func resolveMCPBudget(
        wantsResponse: Bool,
        behaviorSettings: ContextBuilderBehaviorSettings
    ) -> Int {
        wantsResponse
            ? behaviorSettings.analysisTokenBudget
            : behaviorSettings.contextTokenBudget
    }
}
