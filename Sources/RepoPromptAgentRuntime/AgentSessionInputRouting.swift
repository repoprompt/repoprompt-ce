import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Pure routing policy over a snapshot taken at admission. The original runtime applies
/// the result using the command's own session, run attempt, and Stop fence.
package struct AgentSessionInputRouting {
    package enum ComposerRoute: Equatable {
        case codex, waitingInstruction, restartClaudeForImages, start, followUp
        case steer(ActiveSteeringRoute)
    }

    package enum ActiveSteeringRoute: Equatable {
        case acpPrompt, claudeNativeInterrupt
    }

    package enum ManagedSteerRoute: Equatable {
        case codex, waitingInstruction, claudeInterrupt, acpQueued
    }

    private let provider: AgentProviderKind
    private let state: AgentSessionRunState
    private let hasContinuation: Bool
    private let hasImages: Bool
    private let hasApproval: Bool
    private let acpPromptAvailable: Bool

    package init(
        provider: AgentProviderKind, state: AgentSessionRunState,
        hasContinuation: Bool, hasImages: Bool, hasApproval: Bool, acpPromptAvailable: Bool
    ) {
        self.provider = provider
        self.state = state
        self.hasContinuation = hasContinuation
        self.hasImages = hasImages
        self.hasApproval = hasApproval
        self.acpPromptAvailable = acpPromptAvailable
    }

    package var composer: ComposerRoute {
        if state == .waitingForUser {
            // Claude image references require a fresh prompt through the native controller.
            if provider.usesClaudeNativeRuntime, hasImages { return .restartClaudeForImages }
            if hasContinuation { return .waitingInstruction }
        }
        if provider == .codexExec { return .codex }
        if !state.isActive { return .start }
        if let activeSteering { return .steer(activeSteering) }
        return .followUp
    }

    package var managedSteering: ManagedSteerRoute? {
        if state == .waitingForUser, hasContinuation { return .waitingInstruction }
        guard state.isActive else { return nil }
        if provider == .codexExec { return .codex }
        switch activeSteering {
        case .acpPrompt: return .acpQueued
        case .claudeNativeInterrupt: return .claudeInterrupt
        case nil: return nil
        }
    }

    package var activeSteering: ActiveSteeringRoute? {
        guard state == .running, !hasApproval else { return nil }
        if provider.acpProviderID != nil, acpPromptAvailable, !hasImages { return .acpPrompt }
        return provider.usesClaudeNativeRuntime ? .claudeNativeInterrupt : nil
    }
}
