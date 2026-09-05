import Foundation

extension Notification.Name {
    /// Presentation-only invalidation for exact Agent session oversight projections.
    ///
    /// The owning `AgentModeViewModel` is posted as `object`; consumers re-read current exact
    /// projection state after storage has finished mutating. No authority or status payload travels
    /// through this notification.
    static let agentSessionLinkOverseerProjectionDidChange = Notification.Name(
        "RepoPrompt.agentSessionLinkOverseerProjectionDidChange"
    )
}
