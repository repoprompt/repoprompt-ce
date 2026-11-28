import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptDomainRuntime

extension ClaudeTurnSizeFailure {
    var failureReason: DomainAgentRunSnapshot.FailureReason {
        switch kind {
        case .inputContextRejected, .generationContextLimit: .contextExhausted
        case .requestTooLarge, .unknownSizeLimit: .requestTooLarge
        case .outputLimit: .outputLimitReached
        }
    }

    @MainActor
    func terminalMessage(session: AgentTabSession, pausesAutoWake: Bool) -> String {
        var message: String
        switch kind {
        case .inputContextRejected:
            message = "Claude rejected the input because it exceeded the context limit."
            if let inputTokens, let limitTokens {
                message += " Claude reported \(inputTokens.formatted()) input tokens (limit \(limitTokens.formatted()))."
            } else if let count = session.vouchedContextCount?.tokens,
                      let window = session.vouchedContextWindow?.tokens
            {
                message += " Last known context usage: \(count.formatted()) of \(window.formatted()) tokens."
            }
            message += " Try a smaller input, compact the conversation, or start a fresh one."
        case .generationContextLimit:
            message = "Claude hit its context limit while responding. Any partial answer is kept. Compact the conversation or start a fresh one before continuing."
        case .outputLimit:
            message = "Claude reached its output limit, not necessarily its context limit. Any partial answer is kept. Ask it to continue or request a shorter answer."
        case .requestTooLarge:
            message = "Claude rejected the request as too large. Try a smaller input or remove large files or images."
        case .unknownSizeLimit:
            message = "Claude rejected the input as too large but did not report which limit it exceeded. Try a smaller input or remove large files or images."
        }
        if pausesAutoWake { message += " Auto-wake is paused for this conversation." }
        return message
    }
}
