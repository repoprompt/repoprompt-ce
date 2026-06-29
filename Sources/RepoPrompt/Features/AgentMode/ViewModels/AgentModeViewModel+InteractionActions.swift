import Foundation

@MainActor
extension AgentModeViewModel {
    func submitApprovalDecision(tabID: UUID, decision: AgentApprovalDecision) {
        guard let session = sessions[tabID],
              let request = session.pendingApproval
        else {
            return
        }
        AgentRunSentryTelemetry.recordApprovalDecision(
            session: session,
            kind: telemetryApprovalKind(for: request.kind),
            outcome: telemetryApprovalOutcome(for: decision),
            cancellationReason: telemetryCancellationReason(for: decision)
        )
        switch request.requestID {
        case .codex:
            codexCoordinator.submitApprovalDecision(session: session, decision: decision)
        case .claudeControl:
            claudeCoordinator.submitApprovalDecision(session: session, decision: decision)
        case let .acp(requestID):
            session.pendingApproval = nil
            if session.runState == .waitingForApproval {
                session.runState = .running
            }
            requestUIRefresh(tabID: tabID, urgent: true)
            Task { [controller = session.acpController] in
                await controller?.respondToPermissionRequest(id: requestID, decision: decision)
            }
        }
    }

    func submitMCPElicitationResponse(
        tabID: UUID,
        requestID: UUID,
        response: AgentMCPElicitationResponse
    ) {
        guard let session = sessions[tabID],
              let request = session.pendingMCPElicitationRequest,
              request.id == requestID
        else {
            return
        }
        codexCoordinator.submitMCPElicitationResponse(session: session, request: request, response: response)
    }

    func submitApplyEditsReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: ApplyEditsReviewDecision
    ) {
        if let session = sessions[tabID], session.pendingApplyEditsReview?.id == reviewID {
            AgentRunSentryTelemetry.recordApprovalDecision(
                session: session,
                kind: .applyEdits,
                outcome: telemetryApprovalOutcome(for: decision),
                cancellationReason: telemetryCancellationReason(for: decision)
            )
        }
        let scope = applyEditsScope(for: tabID)
        Task { [applyEditsApprovalStore] in
            await applyEditsApprovalStore.resolveReview(
                scope: scope,
                reviewID: reviewID,
                decision: decision
            )
        }
    }

    func telemetryApprovalKind(for kind: AgentApprovalKind) -> SentryTelemetryBootstrap.ApprovalKind {
        switch kind {
        case .commandExecution:
            .commandExecution
        case .fileChange:
            .fileChange
        }
    }

    func telemetryApprovalOutcome(for decision: AgentApprovalDecision) -> SentryTelemetryBootstrap.ApprovalOutcome {
        switch decision {
        case .accept, .acceptForSession, .acceptWithExecpolicyAmendment:
            .approved
        case .decline, .cancel:
            .denied
        }
    }

    func telemetryCancellationReason(for decision: AgentApprovalDecision) -> SentryTelemetryBootstrap.CancellationReason? {
        switch decision {
        case .cancel:
            .user
        case .accept, .acceptForSession, .acceptWithExecpolicyAmendment, .decline:
            nil
        }
    }

    func telemetryApprovalOutcome(for decision: ApplyEditsReviewDecision) -> SentryTelemetryBootstrap.ApprovalOutcome {
        switch decision {
        case .accept:
            .approved
        case .reject, .timeout, .cancelled:
            .denied
        }
    }

    func telemetryCancellationReason(for decision: ApplyEditsReviewDecision) -> SentryTelemetryBootstrap.CancellationReason? {
        switch decision {
        case .timeout:
            .timeout
        case .cancelled:
            .user
        case .accept, .reject:
            nil
        }
    }

    func telemetryApprovalOutcome(for decision: WorktreeMergeReviewDecision) -> SentryTelemetryBootstrap.ApprovalOutcome {
        switch decision {
        case .accept:
            .approved
        case .reject, .timeout, .cancelled:
            .denied
        }
    }

    func telemetryCancellationReason(for decision: WorktreeMergeReviewDecision) -> SentryTelemetryBootstrap.CancellationReason? {
        switch decision {
        case .timeout:
            .timeout
        case .cancelled:
            .user
        case .accept, .reject:
            nil
        }
    }

    func telemetryCancellationReason(forApprovalCancellationReason reason: String) -> SentryTelemetryBootstrap.CancellationReason {
        let normalized = reason.lowercased()
        if normalized.contains("replaced") || normalized.contains("newer") || normalized.contains("superseded") {
            return .superseded
        }
        if normalized.contains("timed out") || normalized.contains("timeout") {
            return .timeout
        }
        return .user
    }
}
