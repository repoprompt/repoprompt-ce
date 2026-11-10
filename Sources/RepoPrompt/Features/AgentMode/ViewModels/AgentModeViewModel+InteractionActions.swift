import Foundation
import RepoPromptDomainRuntime

@MainActor
extension AgentModeViewModel {
    func isCodexHookApprovalStrictModeEnabled() -> Bool {
        guard let session = activeSession else { return true }
        return interactionRuntime.isCodexHookApprovalStrictModeEnabled(for: session)
    }

    func codexRememberedApprovalAllowed(for tabID: UUID?) -> Bool {
        guard let tabID else { return true }
        return sessions[tabID]?.codexControllerFeatureState?.computerUseEnabled != true
    }
}
