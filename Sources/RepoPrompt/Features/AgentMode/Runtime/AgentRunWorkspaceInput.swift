import Foundation

/// The logical launch root supplied by the command's composition, not a later UI selection.
/// Resolving a bound worktree remains a live filesystem/identity check at execution time.
struct AgentRunWorkspaceInput {
    let fallbackWorkspacePath: String?

    func resolve(bindings: [AgentSessionWorktreeBinding]) throws -> String? {
        try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )
    }
}

/// Transient input attached to the existing ACP attempt. This grants no writer or run authority;
/// queued steering must still prove its controller, run ID, Stop fence and exact attempt.
struct AgentACPWorkspaceAdmission {
    let input: AgentRunWorkspaceInput
    let ownership: AgentRunOwnership
    let binding: AgentSessionRestorationBindingToken?
    private let sessionIdentity: ObjectIdentifier
    private let transitionGeneration: UInt64

    @MainActor
    init(input: AgentRunWorkspaceInput, ownership: AgentRunOwnership, session: AgentTabSession) {
        self.input = input
        self.ownership = ownership
        binding = session.currentRestorationBindingToken
        sessionIdentity = ObjectIdentifier(session)
        transitionGeneration = session.bindingTransitionGeneration
    }

    @MainActor
    func isCurrent(for session: AgentTabSession) -> Bool {
        ObjectIdentifier(session) == sessionIdentity
            && !session.bindingTransitionInProgress
            && session.bindingTransitionGeneration == transitionGeneration
            && session.currentRestorationBindingToken == binding
            && session.activeRunOwnership == ownership
    }
}
