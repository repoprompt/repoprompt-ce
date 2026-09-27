import Foundation
import MCP
import RepoPromptDomainRuntime

/// Target-side half of the exact-link **Answer prompts** delegation.
///
/// Runs on the *target's* view model. The bridge has already proved the exact outbound grant and the
/// per-link delegation; this layer owns the interaction itself: which kinds and decisions an
/// observer may choose, the interaction-ID compare-and-set, and a synchronous submission after the
/// final authority check. It reuses the exact parser behind `agent_run respond`, so an answer is
/// accepted or refused with the same message on both surfaces.
@MainActor
extension AgentModeViewModel {
    /// Approval decisions an observer may submit. Each one affects only the current request.
    static let overseerApprovalDecisionLabels: Set<String> = ["accept", "decline", "cancel"]

    func agentSessionLinkPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkPendingInteractionInspection {
        guard let session = agentSessionLinkLiveSession(matching: candidate),
              let interaction = mcpPendingInteraction(for: session)
        else { return .none }
        return AgentSessionLinkPendingInteractionInspection(
            interaction: Self.overseerProjection(of: interaction),
            manualOnlyReason: overseerManualOnlyReason(for: interaction, session: session)
        )
    }

    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard let session = agentSessionLinkLiveSession(matching: candidate) else { return .unavailable }
        guard let interaction = mcpPendingInteraction(for: session) else { return .noPendingInteraction }
        guard interaction.id == request.interactionID else {
            return .interactionMismatch(currentInteractionID: interaction.id)
        }
        if let reason = overseerManualOnlyReason(for: interaction, session: session) {
            return .manualOnly(reason)
        }

        let resolution: PendingInteractionResolution
        do {
            resolution = try mcpPendingInteractionResolution(
                for: session,
                kind: interaction.kind,
                interactionID: interaction.id,
                payload: request.payload
            )
        } catch let error as MCPError {
            return .invalid(Self.overseerMessage(for: error))
        } catch {
            return .invalid(error.localizedDescription)
        }
        if Self.resolutionWidensAuthority(resolution) {
            return .manualOnly(.persistentDecision)
        }
        let decision = Self.overseerDecisionLabel(for: resolution)

        // ACP permissions answer through the controller so only genuine one-time options are chosen,
        // with the final authority check running inside the controller right before it sends.
        if case let .approval(approval, approvalDecision) = resolution,
           case let .acp(requestID) = approval.requestID
        {
            return await respondToOverseenACPPermission(
                candidate: candidate,
                session: session,
                approval: approval,
                requestID: requestID,
                decision: approvalDecision,
                authorize: authorize,
                decisionLabel: decision
            )
        }

        guard await authorize() else { return .unavailable }
        // Final compare-and-set. No suspension between here and submission.
        guard sessions[session.tabID] === session,
              agentSessionLinkLiveSession(matching: candidate) === session
        else { return .unavailable }
        guard let current = mcpPendingInteraction(for: session) else { return .noPendingInteraction }
        guard current.id == request.interactionID else {
            return .interactionMismatch(currentInteractionID: current.id)
        }
        do {
            try applyPendingInteractionResolution(resolution, to: session)
        } catch let error as MCPError {
            return .invalid(Self.overseerMessage(for: error))
        } catch {
            return .invalid(error.localizedDescription)
        }
        requestUIRefresh(tabID: session.tabID, urgent: true)
        return .submitted(kind: interaction.kind, decision: decision)
    }

    // MARK: - Policy

    /// Interactions that exist but must stay with the target's own user.
    func overseerManualOnlyReason(
        for interaction: AgentRunMCPSnapshot.Interaction,
        session: TabSession
    ) -> AgentSessionLinkInteractionManualOnlyReason? {
        switch interaction.kind {
        case .instruction:
            return .instructionPrompt
        case .hookApproval:
            return .hookApproval
        case .approval:
            if session.pendingWorktreeMergeReview?.id == interaction.id {
                return .worktreeMergeReview
            }
            return nil
        case .userInput:
            return interaction.fields.contains(where: \.isSecret) ? .secretInput : nil
        case .question, .mcpElicitation:
            return nil
        }
    }

    /// Session-wide and policy-amending approvals reach beyond the one request being answered.
    static func resolutionWidensAuthority(_ resolution: PendingInteractionResolution) -> Bool {
        switch resolution {
        case let .approval(_, decision), let .permissions(_, decision):
            switch decision {
            case .accept, .decline, .cancel:
                false
            case .acceptForSession, .acceptWithExecpolicyAmendment:
                true
            }
        case .askUserSkip, .askUser, .mcpElicitation, .userInput, .worktreeMerge:
            false
        }
    }

    static func overseerDecisionLabel(for resolution: PendingInteractionResolution) -> String? {
        switch resolution {
        case .askUserSkip:
            "skip"
        case .askUser, .userInput:
            "answered"
        case let .mcpElicitation(_, response):
            switch response.action {
            case .accept: "accept"
            case .decline: "decline"
            case .cancel: "cancel"
            }
        case .worktreeMerge:
            nil
        case let .approval(_, decision), let .permissions(_, decision):
            switch decision {
            case .accept: "accept"
            case .decline: "decline"
            case .cancel: "cancel"
            case .acceptForSession, .acceptWithExecpolicyAmendment: nil
            }
        }
    }

    /// Redacted copy of the interaction restricted to what an observer may choose.
    ///
    /// Option labels stay verbatim because they are the values an answer must name; free text
    /// (titles, prompts, context, descriptions, details) passes through the oversight redactor.
    static func overseerProjection(
        of interaction: AgentRunMCPSnapshot.Interaction
    ) -> AgentRunMCPSnapshot.Interaction {
        typealias Interaction = AgentRunMCPSnapshot.Interaction
        let redact = { (text: String?) in text.map { AgentSessionLinkTextRedactor.redact($0) } }
        let options = interaction.options
            .filter { option in
                interaction.kind != .approval || overseerApprovalDecisionLabels.contains(option.label)
            }
            .map { Interaction.Option(label: $0.label, description: redact($0.description)) }
        let fields = interaction.fields.map { field in
            Interaction.Field(
                id: field.id,
                header: redact(field.header),
                prompt: AgentSessionLinkTextRedactor.redact(field.prompt),
                context: redact(field.context),
                isSecret: field.isSecret,
                allowsOther: field.allowsOther,
                allowsMultiple: field.allowsMultiple,
                allowsCustom: field.allowsCustom,
                emitAllowsOther: field.emitAllowsOther,
                options: field.options.map {
                    Interaction.Option(label: $0.label, description: redact($0.description))
                }
            )
        }
        return Interaction(
            id: interaction.id,
            kind: interaction.kind,
            responseType: interaction.responseType,
            title: redact(interaction.title),
            prompt: redact(interaction.prompt),
            context: redact(interaction.context),
            allowsMultiple: interaction.allowsMultiple,
            options: options,
            fields: fields,
            details: interaction.details.map {
                Interaction.Detail(
                    label: $0.label,
                    value: AgentSessionLinkTextRedactor.redact($0.value),
                    isCode: $0.isCode
                )
            }
        )
    }

    // MARK: - Helpers

    private func respondToOverseenACPPermission(
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        approval: AgentApprovalRequest,
        requestID: String,
        decision: AgentApprovalDecision,
        authorize: @escaping @MainActor @Sendable () async -> Bool,
        decisionLabel: String?
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard let controller = session.acpController else { return .unavailable }
        let approvalID = approval.id
        let result = await controller.respondToPermissionRequestForOverseer(
            id: requestID,
            decision: decision
        ) { [weak self, weak session] in
            guard await authorize(),
                  let self, let session,
                  agentSessionLinkLiveSession(matching: candidate) === session,
                  session.pendingApproval?.id == approvalID
            else { return false }
            return true
        }
        switch result {
        case .submitted:
            if sessions[session.tabID] === session, session.pendingApproval?.id == approvalID {
                session.pendingApproval = nil
                // Mirrors the manual ACP path in `submitApprovalDecision`.
                if session.runState == .waitingForApproval {
                    session.runState = .running
                }
                requestUIRefresh(tabID: session.tabID, urgent: true)
            }
            return .submitted(kind: .approval, decision: decisionLabel)
        case .noOneTimeOption:
            return .manualOnly(.noOneTimeAllowOption)
        case .notSubmitted:
            if let current = mcpPendingInteraction(for: session), current.id != approvalID {
                return .interactionMismatch(currentInteractionID: current.id)
            }
            return mcpPendingInteraction(for: session) == nil ? .noPendingInteraction : .unavailable
        case .failed:
            return .invalid("The provider rejected the permission response. No response was applied.")
        }
    }

    private static func overseerMessage(for error: MCPError) -> String {
        if case let .invalidParams(message) = error, let message {
            return message
        }
        return error.localizedDescription
    }
}
