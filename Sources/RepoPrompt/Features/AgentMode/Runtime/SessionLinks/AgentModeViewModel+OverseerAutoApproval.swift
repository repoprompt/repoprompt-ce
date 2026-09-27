import Foundation

/// Tracks only requests first observed after subscription; an existing pending prompt is the baseline.
struct OverseerPermissionRequestDelta {
    private var previousRequestIDs: Set<UUID>?
    private(set) var newRequestIDs: Set<UUID> = []

    mutating func observe(_ requestIDs: Set<UUID>) {
        newRequestIDs = requestIDs.subtracting(previousRequestIDs ?? requestIDs)
        previousRequestIDs = requestIDs
    }
}

@MainActor
extension AgentModeViewModel {
    /// One-time provider permission response, never a provider-wide or app-wide permission mode.
    /// The observer's opt-in is checked against the current exact grant by the bridge; this target
    /// session and request are checked again after that actor hop before any response is submitted.
    func autoApproveOverseenProviderPermissions(
        for session: AgentTabSession,
        requestIDs: Set<UUID>
    ) async {
        guard sessions[session.tabID] === session,
              let targetEndpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              await AgentSessionLinkRuntimeBridge.shared.autoApprovalIsAuthorized(for: targetEndpoint),
              sessions[session.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == targetEndpoint
        else { return }

        if let request = session.pendingApproval, requestIDs.contains(request.id) {
            switch request.requestID {
            case .codex where session.codexController != nil,
                 .claudeControl where session.claudeController != nil:
                submitApprovalDecision(tabID: session.tabID, decision: .accept)
            case let .acp(requestID):
                if let controller = session.acpController {
                    let accepted = await controller.respondToPermissionRequestOnceForOverseer(id: requestID) { [weak self, weak session] in
                        guard let self, let session,
                              sessions[session.tabID] === session,
                              session.pendingApproval?.id == request.id,
                              agentSessionLinkObserverEndpoint(tabID: session.tabID) == targetEndpoint,
                              await AgentSessionLinkRuntimeBridge.shared.autoApprovalIsAuthorized(for: targetEndpoint),
                              sessions[session.tabID] === session,
                              session.pendingApproval?.id == request.id,
                              agentSessionLinkObserverEndpoint(tabID: session.tabID) == targetEndpoint
                        else { return false }
                        return true
                    }
                    if accepted,
                       sessions[session.tabID] === session,
                       session.pendingApproval?.id == request.id
                    {
                        session.pendingApproval = nil
                        if session.runState == .waitingForApproval {
                            session.runState = .running
                        }
                        requestUIRefresh(tabID: session.tabID, urgent: true)
                    }
                }
            default:
                break
            }
        }
        guard sessions[session.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == targetEndpoint,
              await AgentSessionLinkRuntimeBridge.shared.autoApprovalIsAuthorized(for: targetEndpoint)
        else { return }
        if let request = session.pendingPermissionsRequest, requestIDs.contains(request.id) {
            codexCoordinator.submitPermissionsDecision(session: session, request: request, decision: .accept)
        }
    }
}
