import Foundation
import RepoPromptDomainRuntime

@MainActor
extension AgentSessionInteractionRuntime {
    /// Consume consent synchronously from the captured writer. A true result acknowledges local
    /// consumption and tracked dispatch, not provider delivery. The captured controller preserves
    /// existing response routing; transport-generation fencing remains a separate M9.2b obligation.
    @discardableResult
    func submitApprovalDecision(command: AgentSessionRuntimeStore.Command, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              let request = session.pendingApproval, request.id == requestID,
              decision != .accept || request.supportsPlainApprove else { return false }
        switch request.requestID {
        case let .codex(providerRequestID):
            guard let controller = session.codexController,
                  CodexAgentModeCoordinator.allowsApprovalDecision(decision, request: request, session: session),
                  let result = CodexAgentModeCoordinator.buildApprovalResult(decision: decision, request: request) else { return false }
            session.pendingApproval = nil
            Self.reconcileInteractiveRunState(session)
            publishRunInteractionStateChange(for: session, reason: .approvalResponseSubmitted)
            performEffect(for: session) {
                await controller.respondToServerRequest(id: providerRequestID, result: result)
            }
        case let .claudeControl(providerRequestID):
            guard let controller = session.claudeController else { return false }
            session.pendingApproval = nil
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus("Thinking…", source: .transport)
            session.runState = .running
            performEffect(for: session) {
                await controller.respondToPermissionRequest(id: providerRequestID, decision: decision)
            }
        case let .acp(providerRequestID):
            let controller = session.acpController
            session.pendingApproval = nil
            if session.runState == .waitingForApproval { session.runState = .running }
            performEffect(for: session) {
                await controller?.respondToPermissionRequest(id: providerRequestID, decision: decision)
            }
        }
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
        return true
    }

    /// Match the existing authoritative turn tuple before capturing a cancel follow-up. The
    /// controller's expected-turn API remains the final fence after the response suspension.
    private func responseTurnID(for session: AgentTabSession) -> String? {
        guard let controller = session.codexController,
              let identity = session.codexAuthoritativeActiveTurn,
              identity.controllerInstanceID == ObjectIdentifier(controller),
              identity.controllerGeneration == session.codexControllerGeneration,
              identity.threadID == session.codexConversationID,
              identity.runID == session.runID,
              identity.runAttemptID == session.activeRunAttemptID else { return nil }
        return identity.turnID
    }

    @discardableResult
    func submitPermissionsDecision(command: AgentSessionRuntimeStore.Command, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              let request = session.pendingPermissionsRequest, request.id == requestID,
              let controller = session.codexController,
              CodexAgentModeCoordinator.computerUseAllowsDecision(decision, session: session) else { return false }
        let result = CodexAgentModeCoordinator.buildPermissionsResult(decision: decision, request: request)
        let turnID = responseTurnID(for: session)
        session.pendingPermissionsRequest = nil
        Self.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .permissionsResponseSubmitted)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
        performEffect(for: session) {
            await controller.respondToServerRequest(id: request.requestID, result: result)
            // Never discover a new current turn after the response suspension. Without an
            // originating authoritative turn, cancellation only settles the permission request.
            if case .cancel = decision, let turnID {
                _ = try? await controller.interruptUserTurn(expectedTurnID: turnID)
            }
        }
        return true
    }

    @discardableResult
    func submitMCPElicitationResponse(command: AgentSessionRuntimeStore.Command, requestID: UUID, response: AgentMCPElicitationResponse) -> Bool {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              let request = session.pendingMCPElicitationRequest, request.id == requestID,
              let controller = session.codexController else { return false }
        let turnID = responseTurnID(for: session)
        session.pendingMCPElicitationRequest = nil
        if !session.queuedMCPElicitationRequests.isEmpty {
            session.pendingMCPElicitationRequest = session.queuedMCPElicitationRequests.removeFirst()
        }
        Self.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .mcpElicitationResponseSubmitted)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
        scope?.mcp.handleObservedMCPStateChange(for: session)
        performEffect(for: session) {
            await controller.respondToServerRequest(id: request.requestID, result: response.jsonObject)
            if response.action == .cancel, let turnID {
                _ = try? await controller.interruptUserTurn(expectedTurnID: turnID)
            }
        }
        return true
    }

    @discardableResult
    func submitUserInputResponse(command: AgentSessionRuntimeStore.Command, requestID: UUID, response: AgentRequestUserInputResponse) -> Bool {
        let session = command.writer.session
        guard command.writer.scope === scope, command.isCurrent,
              let request = session.pendingUserInputRequest, request.id == requestID else { return false }
        if session.codexControllerFeatureState?.computerUseEnabled == true,
           !request.allowsComputerUseResponse(response) { return false }
        // Preserve ordinary callers' existing local settlement even without a controller.
        let controller = session.codexController
        session.pendingUserInputRequest = nil
        if !session.queuedUserInputRequests.isEmpty { session.pendingUserInputRequest = session.queuedUserInputRequests.removeFirst() }
        Self.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .userInputResponseSubmitted)
        scope?.presentation.bindingChanged(session)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
        performEffect(for: session) {
            await controller?.respondToServerRequest(id: request.requestID, result: response.jsonObject)
        }
        return true
    }
}
