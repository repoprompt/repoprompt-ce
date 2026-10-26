import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

/// Immutable registration-time caller evidence. A delayed tool body may not borrow a later turn's
/// run attempt or a rebound tab even if its connection still resolves to the same session UUID.
struct AgentSelfMCPCallOrigin: Equatable {
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    let runID: UUID
    let runAttemptID: UUID

    // Boxed: runtime-sized payloads must not use `@TaskLocal` directly (#1039).
    static let currentTaskLocal = BoxedTaskLocal<AgentSelfMCPCallOrigin?>(nil)
    static var current: AgentSelfMCPCallOrigin? {
        currentTaskLocal.get()
    }
}
