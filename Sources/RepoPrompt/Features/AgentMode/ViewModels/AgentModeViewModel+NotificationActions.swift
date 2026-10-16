import Foundation

/// Notification-action capability surface. Every mutator re-checks the exact pending id and reports
/// whether *that* interaction was consumed, and every path forwards to the same API the in-app card
/// uses.
@MainActor
extension AgentModeViewModel: AgentNotificationActionTarget {
    func resolveNotificationAction(
        _ request: AgentNotificationActionRequest,
        preferences: NotificationPreferences
    ) -> AgentNotificationActionOutcome {
        AgentNotificationActionResolver.resolve(request, target: self, preferences: preferences)
    }

    func notificationSession(tabID: UUID) -> AgentTabSession? {
        sessions[tabID]
    }

    func notificationSessionIsMCPControlled(tabID: UUID) -> Bool {
        isMCPControlled(tabID: tabID)
    }

    func notificationSubmitApproval(tabID: UUID, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        submitApprovalDecision(tabID: tabID, requestID: requestID, decision: decision)
    }

    func notificationDeclinePermissions(tabID: UUID, requestID: UUID) -> Bool {
        guard let session = sessions[tabID],
              let request = session.pendingPermissionsRequest,
              request.id == requestID
        else {
            return false
        }
        codexCoordinator.submitPermissionsDecision(session: session, request: request, decision: .decline)
        return session.pendingPermissionsRequest?.id != requestID
    }

    func notificationSubmitAskUser(
        tabID: UUID,
        interactionID: UUID,
        draftsByQuestionID: [String: AgentAskUserDraft]
    ) throws -> Bool {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else {
            return false
        }
        try submitAskUserResponse(tabID: tabID, interactionID: interactionID, draftsByQuestionID: draftsByQuestionID)
        return session.pendingAskUser?.interaction.id != interactionID
    }

    func notificationSkipAskUser(tabID: UUID, interactionID: UUID) -> Bool {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else {
            return false
        }
        skipAskUser(tabID: tabID, interactionID: interactionID)
        return session.pendingAskUser?.interaction.id != interactionID
    }

    func notificationSubmitUserInput(tabID: UUID, requestID: UUID, answers: [String: [String]]) -> Bool {
        guard let session = sessions[tabID],
              let request = session.pendingUserInputRequest,
              request.id == requestID
        else {
            return false
        }
        submitUserInputResponse(
            tabID: tabID,
            requestID: request.requestID,
            response: AgentRequestUserInputResponse(answersByQuestionID: answers)
        )
        return session.pendingUserInputRequest?.id != requestID
    }

    /// Sends `text` through the composer submission path, including the waiting-instruction resume.
    func notificationSubmitInstruction(tabID: UUID, text: String) -> Bool {
        submitUserTurn(text: text, tabID: tabID) == .submitted
    }
}
