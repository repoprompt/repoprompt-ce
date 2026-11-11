import Combine
import Foundation
import RepoPromptDomainRuntime

/// Independent scheduling; the existing Auto-wake slot owns provider execution.
@MainActor
extension AgentModeViewModel {
    static var periodicWakeMessage: String {
        AgentSessionLinkExecutionRuntime.periodicWakeMessage
    }

    static func agentSessionLinkPeriodicWakeSessionIsIdle(_ session: TabSession) -> Bool {
        AgentSessionLinkExecutionRuntime.agentSessionLinkPeriodicWakeSessionIsIdle(session)
    }
}
