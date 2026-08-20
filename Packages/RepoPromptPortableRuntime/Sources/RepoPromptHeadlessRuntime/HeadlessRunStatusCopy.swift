import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Desktop-owned live-status sentences. The browser is a viewer of this copy.
enum HeadlessRunStatusCopy {
    static let initializing = "Initializing…"
    static let preparing = "Preparing…"
    static let thinking = "Thinking…"
    static let sending = "Sending message…"
    static let waitingForInput = "Waiting for input"
    static let waitingForApproval = "Waiting for approval…"
    static let cancelling = "Cancelling…"
    static let interrupting = "Interrupting…"
    static let compacting = "Compacting context…"
    static let waitingForConnection = "Waiting for connection…"
    static let reasoningTitleCode = "reasoning_title"
    static let thinkingCode = "thinking"

    static func interaction(kind: ProviderInteractionKind, provider: ProviderKind) -> String {
        if provider == .codex {
            return kind == .question
                ? "Codex reports it is waiting for user input…"
                : "Codex reports it is waiting for approval…"
        }
        return kind == .question ? waitingForInput : waitingForApproval
    }

    static func preservedOrThinking(current: RunPresentationSnapshot?) -> (code: String, text: String) {
        if current?.runningStatusCode == reasoningTitleCode,
           let text = current?.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            return (reasoningTitleCode, text)
        }
        return (thinkingCode, thinking)
    }
}
