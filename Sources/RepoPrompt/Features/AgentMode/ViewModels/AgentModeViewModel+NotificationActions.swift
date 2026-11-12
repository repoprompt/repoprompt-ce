import Foundation
import RepoPromptDomainRuntime

/// Notification-action capability surface. Every mutator re-checks the exact pending id and reports
/// whether *that* interaction was consumed, and every path forwards to the same API the in-app card
/// uses.
@MainActor
extension AgentModeViewModel: AgentNotificationActionTarget {
    func notificationSession(tabID: UUID) -> AgentTabSession? {
        sessions[tabID]
    }

    func notificationSessionIsMCPControlled(tabID: UUID) -> Bool {
        isMCPControlled(tabID: tabID)
    }

    func notificationSubmitApproval(tabID: UUID, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        guard let session = sessions[tabID], let sessionID = session.activeAgentSessionID,
              let command = try? runtimeCommand(sessionID: sessionID), command.writer.session === session else { return false }
        return interactionRuntime.submitApprovalDecision(command: command, requestID: requestID, decision: decision)
    }

    func notificationDeclinePermissions(tabID: UUID, requestID: UUID) -> Bool {
        guard let session = sessions[tabID],
              let request = session.pendingPermissionsRequest,
              request.id == requestID
        else {
            return false
        }
        guard let sessionID = session.activeAgentSessionID,
              let command = try? runtimeCommand(sessionID: sessionID), command.writer.session === session else { return false }
        return interactionRuntime.submitPermissionsDecision(command: command, requestID: request.id, decision: .decline)
    }

    func notificationSubmitAskUser(
        tabID: UUID,
        interactionID: UUID,
        draftsByQuestionID: [String: AgentAskUserDraft]
    ) throws -> Bool {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else {
            return false
        }
        guard let sessionID = session.activeAgentSessionID,
              let command = try runtimeCommand(sessionID: sessionID), command.writer.session === session else { return false }
        return try interactionRuntime.submitAskUserResponse(command: command, interactionID: interactionID, draftsByQuestionID: draftsByQuestionID)
    }

    func notificationSkipAskUser(tabID: UUID, interactionID: UUID) -> Bool {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else {
            return false
        }
        guard let sessionID = session.activeAgentSessionID,
              let command = try? runtimeCommand(sessionID: sessionID), command.writer.session === session else { return false }
        return interactionRuntime.skipAskUser(command: command, interactionID: interactionID)
    }

    func notificationSubmitUserInput(tabID: UUID, requestID: UUID, answers: [String: [String]]) -> Bool {
        guard let session = sessions[tabID],
              let request = session.pendingUserInputRequest,
              request.id == requestID
        else {
            return false
        }
        guard let sessionID = session.activeAgentSessionID,
              let command = try? runtimeCommand(sessionID: sessionID), command.writer.session === session else { return false }
        return interactionRuntime.submitUserInputResponse(
            command: command,
            requestID: request.id,
            response: AgentRequestUserInputResponse(answersByQuestionID: answers)
        )
    }

    /// Sends `text` through the composer submission path, including the waiting-instruction resume.
    func notificationSubmitInstruction(tabID: UUID, text: String) -> Bool {
        submitUserTurn(text: text, tabID: tabID) == .submitted
    }
}
