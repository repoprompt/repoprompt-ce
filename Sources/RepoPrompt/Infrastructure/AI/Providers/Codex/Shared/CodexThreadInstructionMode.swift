/// How RepoPrompt chose a Codex thread's base instructions when it started the thread.
///
/// `thread/resume` never resends base instructions: the app-server keeps the ones the thread
/// started with. Later binds therefore follow this recorded mode rather than the session's
/// current role, parent, or runtime version, so a native thread keeps its RepoPrompt developer
/// note after compaction and a legacy thread does not receive duplicated guidance.
enum CodexThreadInstructionMode: String, Codable, Equatable {
    /// Codex resolved the base instructions; RepoPrompt guidance travels only in `developerInstructions`.
    case native
    /// RepoPrompt supplied `baseInstructions`.
    case legacy
}

/// Per-bind RepoPrompt developer instructions, resolved by the Agent Mode coordinator.
struct CodexDeveloperInstructionPlan: Equatable {
    /// Offered to `thread/start`. The controller uses it, and omits `baseInstructions`, only when the
    /// runtime supports native model instructions.
    let newThread: String?
    /// Sent with `thread/resume` for the session's current conversation.
    let resume: String?

    static let none = CodexDeveloperInstructionPlan(newThread: nil, resume: nil)

    /// - Parameters:
    ///   - note: The RepoPrompt native developer note.
    ///   - eligibleForNativeStart: Whether a new thread for this session may use Codex's own base
    ///     instructions (currently: top-level, unlabeled sessions).
    ///   - conversationMode: The recorded mode of the conversation a resume would bind, if known.
    static func resolve(
        note: String,
        eligibleForNativeStart: Bool,
        conversationMode: CodexThreadInstructionMode?
    ) -> CodexDeveloperInstructionPlan {
        let newThread = eligibleForNativeStart ? note : nil
        let resume: String? = switch conversationMode {
        case .native:
            // The thread has no RepoPrompt base; dropping the note would leave it without
            // RepoPrompt guidance once compaction rebuilds context.
            note
        case .legacy:
            // The RepoPrompt base already carries this guidance.
            nil
        case nil:
            // Conversations saved before the mode was recorded: keep the #1833 behavior.
            newThread
        }
        return CodexDeveloperInstructionPlan(newThread: newThread, resume: resume)
    }
}
