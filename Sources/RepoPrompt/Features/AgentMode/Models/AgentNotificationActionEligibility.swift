import Foundation

/// A response a user can pick directly from an Agent Mode notification.
enum AgentNotificationAction: Hashable {
    case approve
    case decline
    case choice(index: Int, label: String)
    case reply
    case skip
    case review
    case open

    var identifier: String {
        switch self {
        case .approve: AppNotificationActionID.approve
        case .decline: AppNotificationActionID.decline
        case let .choice(index, _): AppNotificationActionID.choice(index)
        case .reply: AppNotificationActionID.reply
        case .skip: AppNotificationActionID.skip
        case .review: AppNotificationActionID.review
        case .open: AppNotificationActionID.open
        }
    }

    /// Actions that open the app instead of resolving anything in the background.
    var opensApp: Bool {
        self == .review || self == .open
    }

    var spec: NotificationActionSpec {
        switch self {
        case .approve:
            // No `.foreground`: resolved in the background. `.authenticationRequired` documents intent.
            NotificationActionSpec(identifier: identifier, title: "Approve", authenticationRequired: true)
        case .decline:
            NotificationActionSpec(identifier: identifier, title: "Decline", destructive: true)
        case let .choice(_, label):
            NotificationActionSpec(identifier: identifier, title: label)
        case .reply:
            NotificationActionSpec(
                identifier: identifier,
                title: "Reply…",
                style: .textInput(buttonTitle: "Send", placeholder: "Reply to agent…")
            )
        case .skip:
            NotificationActionSpec(identifier: identifier, title: "Skip")
        case .review:
            NotificationActionSpec(identifier: identifier, title: "Review…", foreground: true)
        case .open:
            NotificationActionSpec(identifier: identifier, title: "Open", foreground: true)
        }
    }

    /// Category for an ordered action list. Choice lists need a per-interaction category because
    /// `UNNotificationAction` titles are fixed per category; everything else maps onto a small,
    /// deterministic set that is registered at launch.
    static func category(for actions: [AgentNotificationAction], interactionID: UUID?) -> NotificationCategorySpec? {
        guard !actions.isEmpty else { return nil }
        let hasChoices = actions.contains { if case .choice = $0 { true } else { false } }
        let identifier: String = if hasChoices, let interactionID {
            AppNotificationCategoryID.choicePrefix + interactionID.uuidString
        } else {
            AppNotificationCategoryID.actionsPrefix + actions.map(\.shortName).joined(separator: "+")
        }
        return NotificationCategorySpec(identifier: identifier, actions: actions.map(\.spec))
    }

    /// Every non-choice action list the eligibility policy can produce; registered at launch so the
    /// common notifications never wait on a category round-trip.
    static let staticActionLists: [[AgentNotificationAction]] = [
        [.review],
        [.decline, .review],
        [.approve, .decline, .review],
        [.reply, .review],
        [.reply, .skip, .review],
        [.reply, .open]
    ]

    static var staticCategories: Set<NotificationCategorySpec> {
        Set(staticActionLists.compactMap { category(for: $0, interactionID: nil) })
    }

    private var shortName: String {
        switch self {
        case .approve: "approve"
        case .decline: "decline"
        case let .choice(index, _): "choice\(index)"
        case .reply: "reply"
        case .skip: "skip"
        case .review: "review"
        case .open: "open"
        }
    }
}

/// Parsed identity of an incoming `UNNotificationResponse.actionIdentifier`.
enum AgentNotificationActionIdentity: Equatable {
    case defaultClick
    case dismiss
    case approve
    case decline
    case choice(index: Int)
    case reply
    case skip
    case review
    case open
    case unknown

    init(actionIdentifier: String) {
        switch actionIdentifier {
        case AppNotificationActionID.defaultAction: self = .defaultClick
        case AppNotificationActionID.dismissAction: self = .dismiss
        case AppNotificationActionID.approve: self = .approve
        case AppNotificationActionID.decline: self = .decline
        case AppNotificationActionID.reply: self = .reply
        case AppNotificationActionID.skip: self = .skip
        case AppNotificationActionID.review: self = .review
        case AppNotificationActionID.open: self = .open
        default:
            if actionIdentifier.hasPrefix(AppNotificationActionID.choicePrefix),
               let index = Int(actionIdentifier.dropFirst(AppNotificationActionID.choicePrefix.count)),
               index >= 0
            {
                self = .choice(index: index)
            } else {
                self = .unknown
            }
        }
    }

    var opensApp: Bool {
        switch self {
        case .defaultClick, .review, .open, .unknown: true
        case .dismiss, .approve, .decline, .choice, .reply, .skip: false
        }
    }

    func matches(_ action: AgentNotificationAction) -> Bool {
        switch (self, action) {
        case (.approve, .approve), (.decline, .decline), (.reply, .reply), (.skip, .skip),
             (.review, .review), (.open, .open):
            true
        case let (.choice(index), .choice(actionIndex, _)):
            index == actionIndex
        default:
            false
        }
    }
}

/// Decides which responses a notification may offer for a pending interaction.
///
/// The notification path is at least as strict as the in-app card and stricter where visibility is
/// reduced: Approve requires the complete command to be displayed verbatim, standing-policy decisions
/// ("always allow", session grants, amendments, hook trust) are never offered, and sessions driven by
/// an orchestrating agent (`agent_run`) are Open-only so a user never races the orchestrator.
enum AgentNotificationActionEligibility {
    static let maximumApprovalCommandLength = 160
    static let maximumChoiceCount = 4
    static let maximumChoiceLabelLength = 40
    /// Claude-style tool names whose `command` is the literal shell command being approved.
    static let shellToolNames: Set<String> = ["bash", "shell", "exec_command", "local_shell"]

    static func actions(
        for descriptor: AgentPendingInteractionDescriptor,
        isMCPControlled: Bool,
        preferences: NotificationPreferences
    ) -> [AgentNotificationAction] {
        guard preferences.enabled, !isMCPControlled else { return [.review] }
        let canAnswer = preferences.answerFromNotifications
        let canDecide = preferences.answerFromNotifications || preferences.approveFromNotifications

        switch descriptor.kind {
        case .approval:
            if isApprovable(descriptor, preferences: preferences) {
                return [.approve, .decline, .review]
            }
            return canDecide ? [.decline, .review] : [.review]
        case .permissions:
            return canDecide ? [.decline, .review] : [.review]
        case .askUser:
            guard canAnswer, descriptor.questionCount == 1, !descriptor.allowsMultiple else { return [.review] }
            if descriptor.optionLabels.isEmpty {
                return descriptor.allowsCustom ? [.reply, .skip, .review] : [.review]
            }
            guard let choices = choiceActions(for: descriptor.optionLabels) else { return [.review] }
            return choices + (descriptor.allowsCustom ? [.reply] : []) + [.skip, .review]
        case .userInput:
            guard canAnswer, descriptor.questionCount == 1, !descriptor.isSecret else { return [.review] }
            if descriptor.optionLabels.isEmpty {
                return descriptor.allowsCustom ? [.reply, .review] : [.review]
            }
            guard let choices = choiceActions(for: descriptor.optionLabels) else { return [.review] }
            return choices + (descriptor.allowsCustom ? [.reply] : []) + [.review]
        case .instruction:
            return canAnswer ? [.reply, .review] : [.review]
        case .hookReview, .applyEditsReview, .worktreeMergeReview, .mcpElicitation:
            return [.review]
        }
    }

    static func turnCompleteActions(isMCPControlled: Bool, preferences: NotificationPreferences) -> [AgentNotificationAction] {
        guard preferences.enabled, preferences.replyFromCompletion, !isMCPControlled else { return [] }
        return [.reply, .open]
    }

    /// "What you see is what you approve": the command must fit in the notification body untruncated.
    static func isApprovable(_ descriptor: AgentPendingInteractionDescriptor, preferences: NotificationPreferences) -> Bool {
        guard preferences.enabled,
              preferences.approveFromNotifications,
              preferences.showDetails,
              descriptor.kind == .approval,
              descriptor.approvalKind == .commandExecution,
              let command = descriptor.command
        else {
            return false
        }
        if let toolName = descriptor.toolName?.lowercased(), !shellToolNames.contains(toolName) {
            return false
        }
        guard isDisplayableVerbatim(command, maximumLength: maximumApprovalCommandLength) else { return false }
        return !AgentNotificationCommandRiskClassifier.isHighRisk(command)
    }

    static func choiceActions(for labels: [String]) -> [AgentNotificationAction]? {
        guard (1 ... maximumChoiceCount).contains(labels.count) else { return nil }
        var seen = Set<String>()
        var actions: [AgentNotificationAction] = []
        for (index, label) in labels.enumerated() {
            guard isDisplayableVerbatim(label, maximumLength: maximumChoiceLabelLength),
                  seen.insert(label).inserted
            else {
                return nil
            }
            actions.append(.choice(index: index, label: label))
        }
        return actions
    }

    /// Single line, non-blank, no control characters, not padded, and within `maximumLength`.
    static func isDisplayableVerbatim(_ text: String, maximumLength: Int) -> Bool {
        guard !text.isEmpty, text.count <= maximumLength else { return false }
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Demote-only heuristic: a command that matches is never approvable from a notification. It can only
/// remove Approve, never add it, so false positives cost one click and false negatives still pass
/// through every other gate.
enum AgentNotificationCommandRiskClassifier {
    private static let chainingTokens = [";", "&&", "||", "|", "`", "$(", ">", "<", "&", "\\"]

    /// `NSRegularExpression` is immutable and documented thread-safe for matching.
    private nonisolated(unsafe) static let riskyPatterns: [NSRegularExpression] = [
        #"\b(sudo|su|doas)\b"#,
        #"\b(rm|rmdir|unlink|shred|srm|trash)\b"#,
        #"\bgit\s+push\b.*(\s-f\b|--force|--mirror|--delete|\s-d\b|\s\+)"#,
        #"\bgit\s+reset\b.*--hard"#,
        #"\bgit\s+clean\b"#,
        #"\bgit\s+(checkout|restore)\b.*(\s--\s|\s\.$|--staged|--worktree)"#,
        #"\bgit\s+branch\b.*\s-(D|d)\b"#,
        #"\bgit\s+stash\s+(drop|clear)\b"#,
        #"\bgit\s+(filter-branch|filter-repo|update-ref|reflog\s+expire|gc\b.*--prune)"#,
        #"\b(dd|mkfs(\.\w+)?|diskutil|fdisk|newfs\w*|asr)\b"#,
        #"\b(chmod|chown|chgrp|chflags)\b"#,
        #"\b(eval|exec|xargs|source)\b"#,
        #"\b(sh|bash|zsh|fish|dash|ksh|python\d*(\.\d+)?|node|ruby|perl|php|osascript)\s+-\w*[ce]\b"#,
        #"\b(curl|wget)\b.*\s-(o|O)\b"#,
        #"\b(launchctl|security|defaults|csrutil|nvram|spctl|systemsetup|pmset|crontab|tccutil)\b"#,
        #"\b(kill|killall|pkill|shutdown|reboot|halt)\b"#,
        #"\bfind\b.*\s-(delete|exec|execdir|ok)\b"#,
        #"\b(npm|pnpm|yarn|cargo|gem|twine|pod)\s+(publish|yank|unpublish|owner)\b"#,
        #"\bgh\s+\S+\s+(delete|merge|close)\b"#,
        #"\bdocker\s+(system\s+prune|rm|rmi|volume\s+rm)\b"#,
        #"\bmv\b.*\s/(\s|$)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isHighRisk(_ command: String) -> Bool {
        if chainingTokens.contains(where: { command.contains($0) }) {
            return true
        }
        let range = NSRange(command.startIndex ..< command.endIndex, in: command)
        return riskyPatterns.contains { $0.firstMatch(in: command, options: [], range: range) != nil }
    }
}
