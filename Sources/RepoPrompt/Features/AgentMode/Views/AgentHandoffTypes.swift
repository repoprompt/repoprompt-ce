import Foundation
import RepoPromptAIContracts

/// Configuration for the handoff button in message footers.
/// Provides the data and callbacks needed for the handoff popover.
struct AgentHandoffConfig {
    let itemID: UUID
    let defaultDestinationAgent: AgentProviderKind
    let defaultModelRaw: String
    let defaultReasoningEffortRaw: String?
    let availableAgentsProvider: () -> [AgentProviderKind]
    let modelOptionsProvider: (AgentProviderKind) -> [AgentModelOption]
    let windowID: Int
    let buildPayloadForClipboard: @MainActor () async -> String
    let performHandoff: @MainActor (_ selection: AgentHandoffSelection) async throws -> Void
}

/// The user's selection in the handoff popover.
struct AgentHandoffSelection {
    let agent: AgentProviderKind
    let modelRaw: String
    let reasoningEffortRaw: String?
}
