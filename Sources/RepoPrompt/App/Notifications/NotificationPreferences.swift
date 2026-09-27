import Foundation

/// Immutable snapshot of the user's notification preferences, consumed by notification policy code.
///
/// Defaults are the product defaults; the persisted `scalarPreferences.notifications` group stores
/// only explicit overrides (every field optional) so missing keys keep these values.
struct NotificationPreferences: Equatable {
    var enabled = true
    var agentInteractions = true
    var agentInstructionWaits = true
    var agentTurnComplete = true
    var agentTurnFailed = true
    var chatComplete = true
    var contextBuilderComplete = true
    var approveFromNotifications = true
    var answerFromNotifications = true
    var replyFromCompletion = false
    var showDetails = true
    var notifyWhileActive = true
    var completionsWhileActive = false
    var includeAgentDrivenSessions = false
    var dockBadge = true
    /// Opt-in: window-level MCP `ask_user` prompts post a notification instead of pulling the app
    /// to the front when RepoPrompt is not active.
    var mcpAskUserNotifyInsteadOfActivate = false

    static let defaults = NotificationPreferences()
}

@MainActor
protocol NotificationPreferencesProviding: AnyObject {
    var currentNotificationPreferences: NotificationPreferences { get }
}

extension GlobalSettingsStore: NotificationPreferencesProviding {
    var currentNotificationPreferences: NotificationPreferences {
        notificationPreferences()
    }
}
