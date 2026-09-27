import Foundation

/// Single source of truth for notification preference keys, labels, and descriptions, shared by the
/// Settings pane and the `app_settings` MCP `notifications` group.
struct NotificationSettingDescriptor {
    enum Section: String, CaseIterable {
        case general = "General"
        case agentSessions = "Agent Sessions"
        case responding = "Responding from Notifications"
        case chat = "Chat & Context Builder"
    }

    /// `app_settings` key suffix (`notifications.<key>`).
    let key: String
    let section: Section
    let label: String
    let description: String
    let preference: WritableKeyPath<NotificationPreferences, Bool>
    let setting: WritableKeyPath<GlobalScalarPreferences.NotificationSettings, Bool?>

    var appSettingsKey: String {
        "notifications.\(key)"
    }

    static let all: [NotificationSettingDescriptor] = [
        .init(
            key: "enabled",
            section: .general,
            label: "Enable Notifications",
            description: "Master switch for RepoPrompt notifications. When off, no notifications are posted.",
            preference: \.enabled,
            setting: \.enabled
        ),
        .init(
            key: "show_details",
            section: .general,
            label: "Show Details in Notifications",
            description: "Include commands, questions, and message previews in notification text. When off, notifications use generic text and Approve is never offered.",
            preference: \.showDetails,
            setting: \.showDetails
        ),
        .init(
            key: "notify_while_active",
            section: .general,
            label: "Notify While RepoPrompt Is Active",
            description: "Show banners for sessions that need input even while RepoPrompt is frontmost, unless that session is on screen.",
            preference: \.notifyWhileActive,
            setting: \.notifyWhileActive
        ),
        .init(
            key: "dock_badge",
            section: .general,
            label: "Show Pending Count on Dock Icon",
            description: "Badge the Dock icon with the number of sessions waiting for you.",
            preference: \.dockBadge,
            setting: \.dockBadge
        ),
        .init(
            key: "agent_interactions",
            section: .agentSessions,
            label: "Approvals & Questions",
            description: "Notify when an agent session needs an approval, an answer, or a review.",
            preference: \.agentInteractions,
            setting: \.agentInteractions
        ),
        .init(
            key: "agent_instruction_waits",
            section: .agentSessions,
            label: "Waiting for Instruction",
            description: "Notify when an agent session is waiting for your next instruction.",
            preference: \.agentInstructionWaits,
            setting: \.agentInstructionWaits
        ),
        .init(
            key: "agent_turn_complete",
            section: .agentSessions,
            label: "Turn Complete",
            description: "Notify when an agent turn finishes while you are elsewhere.",
            preference: \.agentTurnComplete,
            setting: \.agentTurnComplete
        ),
        .init(
            key: "agent_turn_failed",
            section: .agentSessions,
            label: "Run Failed",
            description: "Notify when an agent run fails.",
            preference: \.agentTurnFailed,
            setting: \.agentTurnFailed
        ),
        .init(
            key: "completions_while_active",
            section: .agentSessions,
            label: "Completions While RepoPrompt Is Active",
            description: "Also show turn-complete and failure banners while RepoPrompt is frontmost.",
            preference: \.completionsWhileActive,
            setting: \.completionsWhileActive
        ),
        .init(
            key: "include_agent_driven_sessions",
            section: .agentSessions,
            label: "Include Agent-Driven Sessions",
            description: "Also notify for sessions controlled by another agent through agent_run. Their interactions stay Open-only because the orchestrating agent answers them.",
            preference: \.includeAgentDrivenSessions,
            setting: \.includeAgentDrivenSessions
        ),
        .init(
            key: "mcp_ask_user_notify_instead_of_activate",
            section: .agentSessions,
            label: "Notify Instead of Activating for MCP Questions",
            description: "When an external MCP client asks a question in an Agent Mode tab while RepoPrompt is in the background, post a notification instead of bringing RepoPrompt to the front.",
            preference: \.mcpAskUserNotifyInsteadOfActivate,
            setting: \.mcpAskUserNotifyInsteadOfActivate
        ),
        .init(
            key: "approve_from_notifications",
            section: .responding,
            label: "Approve from Notifications",
            description: "Offer Approve for short, single-line, low-risk shell commands shown in full in the notification. File changes, permission grants, reviews, and \"always allow\" always open RepoPrompt.",
            preference: \.approveFromNotifications,
            setting: \.approveFromNotifications
        ),
        .init(
            key: "answer_from_notifications",
            section: .responding,
            label: "Answer from Notifications",
            description: "Offer option buttons, Skip, Decline, and Reply for simple questions and instruction waits.",
            preference: \.answerFromNotifications,
            setting: \.answerFromNotifications
        ),
        .init(
            key: "reply_from_completion",
            section: .responding,
            label: "Reply from Turn-Complete Notifications",
            description: "Add a Reply action to turn-complete notifications that sends your text as the next message.",
            preference: \.replyFromCompletion,
            setting: \.replyFromCompletion
        ),
        .init(
            key: "chat_complete",
            section: .chat,
            label: "Chat Complete",
            description: "Notify when a chat response finishes while RepoPrompt is in the background.",
            preference: \.chatComplete,
            setting: \.chatComplete
        ),
        .init(
            key: "context_builder_complete",
            section: .chat,
            label: "Context Builder Complete",
            description: "Notify when Context Builder finishes while RepoPrompt is in the background.",
            preference: \.contextBuilderComplete,
            setting: \.contextBuilderComplete
        )
    ]
}

extension GlobalSettingsStore {
    func notificationSetting(_ descriptor: NotificationSettingDescriptor) -> Bool {
        notificationPreferences()[keyPath: descriptor.preference]
    }

    func setNotificationSetting(_ descriptor: NotificationSettingDescriptor, _ enabled: Bool) {
        updateNotificationSettings { settings in
            settings[keyPath: descriptor.setting] = enabled
        }
    }
}
