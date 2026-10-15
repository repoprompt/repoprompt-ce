import Foundation

extension Notification.Name {
    /// Projection invalidation only. Carries no permission, scope, message, or session identity.
    static let agentOverseerContinuityDidChange = Notification.Name("RepoPrompt.agentOverseerContinuityDidChange")
}
