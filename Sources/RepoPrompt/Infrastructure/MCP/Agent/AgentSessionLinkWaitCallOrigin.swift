import RepoPromptDomainRuntime
import RepoPromptShared

/// Route-snapshot evidence captured before later request awaits; never caller-supplied.
enum AgentSessionLinkWaitCallOrigin {
    // Boxed: runtime-sized payloads must not use `@TaskLocal` directly (#1039).
    static let currentTaskLocal = BoxedTaskLocal<DomainAgentSessionLinkWaitInput?>(nil)
    static var current: DomainAgentSessionLinkWaitInput? {
        currentTaskLocal.get()
    }
}
