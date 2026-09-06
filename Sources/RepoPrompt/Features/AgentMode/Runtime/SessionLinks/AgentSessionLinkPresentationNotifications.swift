import Foundation

// The single presentation-only invalidation the exact overseer projection publishes.
//
// Posted once per logical projection batch by `agentSessionLinkMutateProjectionStorage` in
// `AgentModeViewModel+SessionLinks`, and consumed by `AgentSessionsSidebarView` and `WindowState`,
// which re-read current exact state on their own schedulers. Invariant: it carries no authority,
// sample, or status payload, so its consumers cannot cross into prompt inventory, the passive
// queue, or Auto-wake admission.

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
