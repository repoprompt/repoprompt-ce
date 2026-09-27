import Foundation

/// A background response chosen from a notification, before it is validated against live state.
struct AgentNotificationActionRequest: Equatable {
    let notificationKind: AppNotificationKind
    let tabID: UUID
    let sessionID: UUID?
    let interaction: AppNotificationPayload.InteractionReference?
    let action: AgentNotificationActionIdentity
    let userText: String?
    /// For turn-complete notifications: the turn the notification described.
    var turnMarker: String?
}

/// Identity of an agent session's latest turn: transcript turn count plus the latest user row.
/// Any newer turn (user-sent or system-initiated) changes it.
enum AgentNotificationTurnMarker {
    @MainActor
    static func make(from session: AgentTabSession) -> String {
        let lastUserItemID = session.items.last(where: { $0.kind == .user })?.id.uuidString ?? "-"
        return "\(session.transcript.turns.count):\(lastUserItemID)"
    }
}

enum AgentNotificationActionOutcome: Equatable {
    case applied
    /// The interaction was already resolved, replaced, or its content changed.
    case stale
    /// The action is not allowed for the live interaction under current preferences.
    case ineligible
    case invalidInput
    case windowUnavailable
}

/// Capability surface the resolver uses. `AgentModeViewModel` conforms by forwarding to the same
/// id-checked APIs its interaction cards use, so a notification answer is indistinguishable from an
/// in-app one.
@MainActor
protocol AgentNotificationActionTarget: AnyObject {
    func notificationSession(tabID: UUID) -> AgentTabSession?
    func notificationSessionIsMCPControlled(tabID: UUID) -> Bool
    func notificationSubmitApproval(tabID: UUID, requestID: UUID, decision: AgentApprovalDecision) -> Bool
    func notificationDeclinePermissions(tabID: UUID, requestID: UUID) -> Bool
    func notificationSubmitAskUser(
        tabID: UUID,
        interactionID: UUID,
        draftsByQuestionID: [String: AgentAskUserDraft]
    ) throws -> Bool
    func notificationSkipAskUser(tabID: UUID, interactionID: UUID) -> Bool
    func notificationSubmitUserInput(tabID: UUID, requestID: UUID, answers: [String: [String]]) -> Bool
    func notificationSubmitInstruction(tabID: UUID, text: String) -> Bool
}

/// Validates a notification action against the *live* session and applies it.
///
/// Everything happens synchronously on the main actor, so there is no suspension point between the
/// staleness checks and the submit: an interaction resolved in-app, by `agent_run respond`, or by a
/// timeout can never receive a decision meant for a previous one.
enum AgentNotificationActionResolver {
    static let emptyReplyMessage = "Reply was empty — nothing was sent."

    @MainActor
    static func resolve(
        _ request: AgentNotificationActionRequest,
        target: AgentNotificationActionTarget,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome {
        guard let session = target.notificationSession(tabID: request.tabID) else { return .stale }
        guard session.activeAgentSessionID == request.sessionID else { return .stale }
        let isMCPControlled = target.notificationSessionIsMCPControlled(tabID: request.tabID)

        switch request.notificationKind {
        case .turnComplete:
            return resolveTurnCompleteReply(
                request,
                session: session,
                isMCPControlled: isMCPControlled,
                target: target,
                preferences: preferences
            )
        case .interaction:
            break
        case .turnFailed, .chatComplete, .contextBuilderComplete, .feedback:
            return .ineligible
        }

        guard let reference = request.interaction,
              let live = AgentPendingInteractionDescriptor.make(from: session),
              live.id == reference.id,
              live.kind == reference.kind,
              live.fingerprint == reference.fingerprint
        else {
            return .stale
        }

        let allowed = AgentNotificationActionEligibility.actions(
            for: live,
            isMCPControlled: isMCPControlled,
            preferences: preferences
        )
        guard let action = allowed.first(where: { request.action.matches($0) }), !action.opensApp else {
            return .ineligible
        }
        return apply(action, live: live, request: request, session: session, target: target)
    }

    @MainActor
    private static func apply(
        _ action: AgentNotificationAction,
        live: AgentPendingInteractionDescriptor,
        request: AgentNotificationActionRequest,
        session: AgentTabSession,
        target: AgentNotificationActionTarget
    ) -> AgentNotificationActionOutcome {
        let tabID = request.tabID
        switch (live.kind, action) {
        case (.approval, .approve):
            return target.notificationSubmitApproval(tabID: tabID, requestID: live.id, decision: .accept) ? .applied : .stale
        case (.approval, .decline):
            return target.notificationSubmitApproval(tabID: tabID, requestID: live.id, decision: .decline) ? .applied : .stale
        case (.permissions, .decline):
            return target.notificationDeclinePermissions(tabID: tabID, requestID: live.id) ? .applied : .stale
        case (.askUser, .skip):
            return target.notificationSkipAskUser(tabID: tabID, interactionID: live.id) ? .applied : .stale
        case let (.askUser, .choice(_, label)):
            guard let questionID = live.questionID else { return .stale }
            return submitAskUser(
                tabID: tabID,
                interactionID: live.id,
                drafts: [questionID: AgentAskUserDraft(selectedOptionLabels: [label])],
                target: target
            )
        case (.askUser, .reply):
            guard let questionID = live.questionID else { return .stale }
            guard let text = trimmedText(request.userText) else { return .invalidInput }
            // Mirror the in-app legacy single-question path: an exact option label selects the option.
            let draft = live.optionLabels.contains(text)
                ? AgentAskUserDraft(selectedOptionLabels: [text])
                : AgentAskUserDraft(customResponse: text)
            return submitAskUser(tabID: tabID, interactionID: live.id, drafts: [questionID: draft], target: target)
        case let (.userInput, .choice(_, label)):
            guard let questionID = live.questionID else { return .stale }
            return target.notificationSubmitUserInput(tabID: tabID, requestID: live.id, answers: [questionID: [label]])
                ? .applied : .stale
        case (.userInput, .reply):
            guard let questionID = live.questionID,
                  let question = session.pendingUserInputRequest?.questions.first(where: { $0.id == questionID })
            else {
                return .stale
            }
            guard let text = trimmedText(request.userText) else { return .invalidInput }
            // Same answer shape `AgentRequestUserInputRequest.buildResponse` produces for "Other" + note.
            var answers: [String] = []
            if question.isOtherOptionEnabled {
                answers.append(AgentRequestUserInputQuestion.otherOptionLabel)
            }
            answers.append("user_note: \(text)")
            return target.notificationSubmitUserInput(tabID: tabID, requestID: live.id, answers: [questionID: answers])
                ? .applied : .stale
        case (.instruction, .reply):
            guard let text = trimmedText(request.userText) else { return .invalidInput }
            return target.notificationSubmitInstruction(tabID: tabID, text: text) ? .applied : .stale
        default:
            return .ineligible
        }
    }

    @MainActor
    private static func resolveTurnCompleteReply(
        _ request: AgentNotificationActionRequest,
        session: AgentTabSession,
        isMCPControlled: Bool,
        target: AgentNotificationActionTarget,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome {
        let allowed = AgentNotificationActionEligibility.turnCompleteActions(
            isMCPControlled: isMCPControlled,
            preferences: preferences
        )
        guard request.action == .reply, allowed.contains(.reply) else { return .ineligible }
        // A newer turn or a pending interaction supersedes "reply to the finished turn".
        guard let turnMarker = request.turnMarker,
              turnMarker == AgentNotificationTurnMarker.make(from: session),
              !session.runState.isActive,
              AgentPendingInteractionDescriptor.make(from: session) == nil
        else {
            return .stale
        }
        guard let text = trimmedText(request.userText) else { return .invalidInput }
        return target.notificationSubmitInstruction(tabID: request.tabID, text: text) ? .applied : .stale
    }

    @MainActor
    private static func submitAskUser(
        tabID: UUID,
        interactionID: UUID,
        drafts: [String: AgentAskUserDraft],
        target: AgentNotificationActionTarget
    ) -> AgentNotificationActionOutcome {
        do {
            return try target.notificationSubmitAskUser(
                tabID: tabID,
                interactionID: interactionID,
                draftsByQuestionID: drafts
            ) ? .applied : .stale
        } catch {
            return .invalidInput
        }
    }

    private static func trimmedText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
