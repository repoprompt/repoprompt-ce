import Foundation

/// Attention snapshot for one live Agent Mode session, published by its window's view model.
struct AgentAttentionState: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID?
    let sessionName: String
    let isMCPControlled: Bool
    /// The session's single top-priority pending interaction, if any.
    let interaction: AgentPendingInteractionDescriptor?
    /// Identity of the session's latest turn (see `AgentNotificationTurnMarker`).
    var turnMarker: String?

    var route: AgentSessionDeepLinkRoute {
        AgentSessionDeepLinkRoute(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            interactionID: interaction?.id
        )
    }

    var threadIdentifier: String {
        AppNotificationIdentifier.sessionThread(tabID: tabID, sessionID: sessionID)
    }
}

/// A delivered interaction notification the coordinator is tracking.
struct AgentPostedInteraction: Equatable {
    let requestIdentifier: String
    let interactionID: UUID
    let tabID: UUID
    let contentKey: String
    let categoryIdentifier: String?
}

struct AgentInteractionPost: Equatable {
    let interactionID: UUID
    let tabID: UUID
    let request: NotificationRequestSpec
    let category: NotificationCategorySpec?
    let contentKey: String
}

struct AgentNotificationPlanInput {
    var states: [AgentAttentionState]
    var visibleTabIDs: Set<UUID>
    var appIsActive: Bool
    var preferences: NotificationPreferences
    var firstSeenAt: [UUID: Date]
    var announcedInteractionIDs: Set<UUID>
    var posted: [String: AgentPostedInteraction]
    var now: Date
    var gracePeriod: TimeInterval
}

struct AgentNotificationPlan: Equatable {
    var posts: [AgentInteractionPost] = []
    var removals: [String] = []
    /// Tabs whose completion/failure notifications should be retracted (the tab is visible or now
    /// asks for input, which supersedes "done").
    var retractTurnNotificationsForTabs: Set<UUID> = []
    var badgeCount = 0
    var nextGraceDeadline: Date?
    var firstSeenAt: [UUID: Date] = [:]
    var announcedInteractionIDs: Set<UUID> = []
}

/// Pure planner: diffs desired interaction notifications (derived from live state, visibility, and
/// preferences) against tracked delivered ones. Level-triggered, so resolving an interaction anywhere
/// retracts its notification on the next pass.
enum AgentNotificationPlanner {
    static func plan(_ input: AgentNotificationPlanInput) -> AgentNotificationPlan {
        var plan = AgentNotificationPlan()
        let preferences = input.preferences
        var desired: [String: AgentInteractionPost] = [:]
        var liveInteractionIDs = Set<UUID>()

        for state in input.states {
            guard let descriptor = state.interaction else {
                if input.visibleTabIDs.contains(state.tabID) {
                    plan.retractTurnNotificationsForTabs.insert(state.tabID)
                }
                continue
            }
            liveInteractionIDs.insert(descriptor.id)
            let firstSeen = input.firstSeenAt[descriptor.id] ?? input.now
            plan.firstSeenAt[descriptor.id] = firstSeen

            let includesSession = !state.isMCPControlled || preferences.includeAgentDrivenSessions
            if preferences.enabled, preferences.dockBadge, includesSession {
                plan.badgeCount += 1
            }

            if input.visibleTabIDs.contains(state.tabID) {
                // The user is looking at it: never notify, and a later re-post must be silent.
                plan.retractTurnNotificationsForTabs.insert(state.tabID)
                plan.announcedInteractionIDs.insert(descriptor.id)
                continue
            }
            guard isEnabled(descriptor.kind, preferences: preferences), includesSession else { continue }
            if input.appIsActive, !preferences.notifyWhileActive { continue }

            let deadline = firstSeen.addingTimeInterval(input.gracePeriod)
            if deadline > input.now {
                plan.nextGraceDeadline = min(plan.nextGraceDeadline ?? deadline, deadline)
                continue
            }

            let silent = input.announcedInteractionIDs.contains(descriptor.id)
            let post = interactionPost(
                state: state,
                descriptor: descriptor,
                preferences: preferences,
                silent: silent,
                now: input.now
            )
            desired[post.request.identifier] = post
            plan.retractTurnNotificationsForTabs.insert(state.tabID)
        }

        plan.announcedInteractionIDs.formUnion(input.announcedInteractionIDs.intersection(liveInteractionIDs))
        for (identifier, post) in desired.sorted(by: { $0.key < $1.key }) {
            plan.announcedInteractionIDs.insert(post.interactionID)
            if input.posted[identifier]?.contentKey != post.contentKey {
                plan.posts.append(post)
            }
        }
        plan.removals = input.posted.keys.filter { desired[$0] == nil }.sorted()
        return plan
    }

    static func isEnabled(_ kind: AgentPendingInteractionKind, preferences: NotificationPreferences) -> Bool {
        guard preferences.enabled else { return false }
        return kind == .instruction ? preferences.agentInstructionWaits : preferences.agentInteractions
    }

    static func interactionPost(
        state: AgentAttentionState,
        descriptor: AgentPendingInteractionDescriptor,
        preferences: NotificationPreferences,
        silent: Bool,
        now: Date
    ) -> AgentInteractionPost {
        let actions = AgentNotificationActionEligibility.actions(
            for: descriptor,
            isMCPControlled: state.isMCPControlled,
            preferences: preferences
        )
        let category = AgentNotificationAction.category(for: actions, interactionID: descriptor.id)
        let choiceCount = actions.count { if case .choice = $0 { true } else { false } }
        let body = interactionBody(descriptor: descriptor, actions: actions, preferences: preferences)
        let payload = AppNotificationPayload(
            kind: .interaction,
            route: state.route,
            interaction: .init(
                id: descriptor.id,
                kind: descriptor.kind,
                fingerprint: descriptor.fingerprint,
                choiceCount: choiceCount
            ),
            postedAt: now
        )
        let request = NotificationRequestSpec(
            identifier: AppNotificationIdentifier.interaction(descriptor.id),
            title: state.sessionName,
            subtitle: descriptor.title,
            body: body,
            threadIdentifier: state.threadIdentifier,
            categoryIdentifier: category?.identifier,
            playsSound: !silent,
            relevanceScore: 1.0,
            payload: payload
        )
        let contentKey = [
            descriptor.fingerprint,
            category?.identifier ?? "",
            state.sessionName,
            descriptor.title,
            body
        ].joined(separator: "\u{1F}")
        return AgentInteractionPost(
            interactionID: descriptor.id,
            tabID: state.tabID,
            request: request,
            category: category,
            contentKey: contentKey
        )
    }

    static func interactionBody(
        descriptor: AgentPendingInteractionDescriptor,
        actions: [AgentNotificationAction],
        preferences: NotificationPreferences
    ) -> String {
        guard preferences.showDetails else { return genericBody(for: descriptor.kind) }
        if actions.contains(.approve), let command = descriptor.command {
            // Approve is only offered when this exact text fits verbatim; never preview-truncate it.
            return command
        }
        return NotificationTextPreview.make(from: descriptor.detail) ?? genericBody(for: descriptor.kind)
    }

    static func genericBody(for kind: AgentPendingInteractionKind) -> String {
        switch kind {
        case .approval, .permissions, .hookReview:
            "Needs your approval"
        case .applyEditsReview, .worktreeMergeReview:
            "Needs your review"
        case .askUser, .userInput, .mcpElicitation:
            "Has a question for you"
        case .instruction:
            "Waiting for your next instruction"
        }
    }
}

/// Short multi-line preview used for notification bodies (at most 3 non-empty lines, 220 characters).
enum NotificationTextPreview {
    static func make(from text: String?, maxLines: Int = 3, maxCharacters: Int = 220) -> String? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lines: [String] = []
        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count >= maxLines {
                break
            }
        }
        guard !lines.isEmpty else { return nil }
        var preview = lines.joined(separator: "\n")
        if preview.count > maxCharacters {
            let index = preview.index(preview.startIndex, offsetBy: maxCharacters)
            preview = String(preview[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return preview
    }
}
