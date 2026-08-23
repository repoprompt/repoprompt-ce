import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Desktop-owned live-status sentences. The browser is a viewer of this copy.
public enum HeadlessRunStatusCopy {
    public static let initializing = "Initializing…"
    public static let preparing = "Preparing…"
    public static let thinking = "Thinking…"
    public static let sending = "Sending message…"
    public static let waitingForInput = "Waiting for input"
    public static let waitingForApproval = "Waiting for approval…"
    public static let cancelling = "Cancelling…"
    public static let interrupting = "Interrupting…"
    public static let compacting = "Compacting context…"
    public static let waitingForConnection = "Waiting for connection…"
    public static let reasoningTitleCode = "reasoning_title"
    public static let thinkingCode = "thinking"

    public static func interaction(kind: ProviderInteractionKind, provider: ProviderKind) -> String {
        if provider == .codex {
            return kind == .question
                ? "Codex reports it is waiting for user input…"
                : "Codex reports it is waiting for approval…"
        }
        return kind == .question ? waitingForInput : waitingForApproval
    }

    public static func preservedOrThinking(current: RunPresentationSnapshot?) -> (code: String, text: String) {
        if current?.runningStatusCode == reasoningTitleCode,
           let text = current?.runningStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            return (reasoningTitleCode, text)
        }
        return (thinkingCode, thinking)
    }
}
