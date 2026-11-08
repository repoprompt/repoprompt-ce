import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptCodexProvider
import RepoPromptDomainRuntime

struct AgentMCPInteractionResponsePayload: Equatable {
    enum ResponseArgument: Equatable {
        case missing
        case scalar(String)
        case nonScalar
    }

    enum AnswerValueShape: Equatable {
        case scalarString
        case stringArray
        case structuredObject
    }

    let suppliedArgumentNames: Set<String>
    let text: String?
    let skip: Bool
    let explicitSkip: Bool
    let responseArgument: ResponseArgument
    let amendment: String?
    let answerValueShapesByQuestionID: [String: AnswerValueShape]
    let hasNormalizedAnswerFieldNames: Bool
    let answersByQuestionID: [String: [String]]
    let askUserAnswersByQuestionID: [String: AgentAskUserAnswer]
    let hasStructuredAnswerObjects: Bool
    let elicitationActionRaw: String?
    let elicitationContent: [String: AgentJSONValue]
    let elicitationMeta: [String: AgentJSONValue]

    init(
        suppliedArgumentNames: Set<String> = [],
        text: String?,
        skip: Bool,
        explicitSkip: Bool = false,
        responseArgument: ResponseArgument,
        amendment: String?,
        answerValueShapesByQuestionID: [String: AnswerValueShape] = [:],
        hasNormalizedAnswerFieldNames: Bool = false,
        answersByQuestionID: [String: [String]],
        askUserAnswersByQuestionID: [String: AgentAskUserAnswer] = [:],
        hasStructuredAnswerObjects: Bool = false,
        elicitationActionRaw: String? = nil,
        elicitationContent: [String: AgentJSONValue] = [:],
        elicitationMeta: [String: AgentJSONValue] = [:]
    ) {
        self.suppliedArgumentNames = suppliedArgumentNames
        self.text = text
        self.skip = skip
        self.explicitSkip = explicitSkip
        self.responseArgument = responseArgument
        self.amendment = amendment
        self.answerValueShapesByQuestionID = answerValueShapesByQuestionID
        self.hasNormalizedAnswerFieldNames = hasNormalizedAnswerFieldNames
        self.answersByQuestionID = answersByQuestionID
        self.askUserAnswersByQuestionID = askUserAnswersByQuestionID
        self.hasStructuredAnswerObjects = hasStructuredAnswerObjects
        self.elicitationActionRaw = elicitationActionRaw
        self.elicitationContent = elicitationContent
        self.elicitationMeta = elicitationMeta
    }

    func containsArgument(_ name: String) -> Bool {
        suppliedArgumentNames.contains(name)
    }
}

/// Validated request-scoped response; never persisted and not itself authorization.
enum AgentPendingInteractionResolution {
    case askUserSkip(interactionID: UUID)
    case askUser(interactionID: UUID, drafts: [String: AgentAskUserDraft])
    case mcpElicitation(request: AgentMCPElicitationRequest, response: AgentMCPElicitationResponse)
    case userInput(request: AgentRequestUserInputRequest, response: AgentRequestUserInputResponse)
    case worktreeMerge(reviewID: UUID, decision: WorktreeMergeReviewDecision)
    case permissions(request: AgentPermissionsRequest, decision: AgentApprovalDecision)
    case approval(request: AgentApprovalRequest, decision: AgentApprovalDecision)
}

@MainActor
extension AgentSessionInteractionRuntime {
    func owns(_ session: AgentTabSession) -> Bool {
        scope?.sessions[session.tabID] === session && scope?.hasReleasedWriterClaims == false
    }

    private func requireCodexCoordinator() throws -> CodexAgentModeCoordinator {
        guard let codexCommands else { throw MCPError.invalidParams("The provider response route is unavailable. No response was applied.") }
        return codexCommands
    }

    private func mcpApprovalDecisionLabels(for approval: AgentApprovalRequest, session: AgentTabSession, includeAliases: Bool) -> [String] {
        scope?.mcp.mcpApprovalDecisionLabels(for: approval, session: session, includeAliases: includeAliases) ?? []
    }

    func submitAskUserResponse(session: AgentTabSession, interactionID: UUID, draftsByQuestionID: [String: AgentAskUserDraft]) throws {
        guard owns(session), var pending = session.pendingAskUser, pending.interaction.id == interactionID else { return }
        pending.draftsByQuestionID = draftsByQuestionID
        session.pendingAskUser = pending
        try resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: false)
    }

    func skipAskUser(session: AgentTabSession, interactionID: UUID) {
        try? resolveAskUserResponse(for: session, interactionID: interactionID, skipAll: true)
    }

    func resolveAskUserResponse(for session: AgentTabSession, interactionID: UUID, skipAll: Bool) throws {
        guard owns(session), let pending = session.pendingAskUser,
              pending.interaction.id == interactionID, let continuation = session.askUserContinuation else { return }
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(pending.interaction.askedAt)))
        let response = if skipAll {
            pending.interaction.buildSkippedResponse(elapsedSeconds: elapsedSeconds)
        } else {
            try pending.interaction.buildSubmittedResponse(drafts: pending.draftsByQuestionID, elapsedSeconds: elapsedSeconds)
        }
        Self.invalidatePendingAskUserTimeout(for: session)
        session.pendingAskUser = nil
        session.askUserContinuation = nil
        Self.reconcileInteractiveRunState(session)
        scope?.presentation.bindingChanged(session)
        continuation.resume(returning: response)
    }

    func submitWorktreeMergeReviewDecision(session: AgentTabSession, reviewID: UUID, decision: WorktreeMergeReviewDecision) {
        guard owns(session), session.pendingWorktreeMergeReview?.id == reviewID,
              let continuation = session.worktreeMergeReviewContinuation else { return }
        finishPendingWorktreeMergeReview(session: session)
        continuation.resume(returning: decision)
    }

    @discardableResult
    func submitUserInputResponse(session: AgentTabSession, requestID: CodexAppServerRequestID, response: AgentRequestUserInputResponse) -> Bool {
        guard owns(session), let request = session.pendingUserInputRequest, request.requestID == requestID,
              codexCommands?.submitUserInputResponse(session: session, requestID: requestID, response: response) == true else { return false }
        session.pendingUserInputRequest = nil
        if !session.queuedUserInputRequests.isEmpty { session.pendingUserInputRequest = session.queuedUserInputRequests.removeFirst() }
        Self.reconcileInteractiveRunState(session)
        publishRunInteractionStateChange(for: session, reason: .userInputResponseSubmitted)
        scope?.presentation.bindingChanged(session)
        scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
        return true
    }

    @discardableResult
    func submitApprovalDecision(session: AgentTabSession, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        guard owns(session), let request = session.pendingApproval, request.id == requestID,
              decision != .accept || request.supportsPlainApprove else { return false }
        switch request.requestID {
        case .codex:
            guard let codexCommands else { return false }
            codexCommands.submitApprovalDecision(session: session, decision: decision)
        case .claudeControl:
            guard let claudeCommands else { return false }
            claudeCommands.submitApprovalDecision(session: session, decision: decision)
        case let .acp(providerRequestID):
            let controller = session.acpController
            session.pendingApproval = nil
            if session.runState == .waitingForApproval { session.runState = .running }
            scope?.presentation.makeRunHooks().requestUIRefresh(session, true)
            performEffect(for: session) {
                await controller?.respondToPermissionRequest(id: providerRequestID, decision: decision)
            }
        }
        return session.pendingApproval?.id != requestID
    }

    static func canonicalApprovalResponse(from payload: AgentMCPInteractionResponsePayload) throws -> String {
        if payload.containsArgument("decision") {
            throw MCPError.invalidParams(
                "decision is not a supported field for agent_run op=respond. For approval interactions, use the top-level scalar response field, for example response=\"accept\". No response was applied."
            )
        }

        switch payload.responseArgument {
        case .missing:
            throw MCPError.invalidParams(
                "response is required for approval interactions. Provide a top-level scalar string, for example response=\"accept\". No response was applied."
            )
        case .nonScalar:
            throw MCPError.invalidParams(
                "response must be a non-empty top-level scalar string for approval interactions, for example response=\"accept\"; nested response objects are not supported. No response was applied."
            )
        case let .scalar(response):
            let canonicalResponse = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !canonicalResponse.isEmpty else {
                throw MCPError.invalidParams(
                    "response must be a non-empty top-level scalar string for approval interactions, for example response=\"accept\"; nested response objects are not supported. No response was applied."
                )
            }
            return canonicalResponse
        }
    }

    /// Parses an answer for a question, MCP elicitation, user-input, or approval interaction.
    ///
    /// Pure with respect to the session: it reads the pending request that matches `interactionID`
    /// and throws `MCPError.invalidParams` when the answer does not fit, but it submits nothing.
    func mcpPendingInteractionResolution(
        for session: AgentTabSession,
        kind: AgentRunMCPSnapshot.Interaction.Kind,
        interactionID: UUID,
        payload: AgentMCPInteractionResponsePayload
    ) throws -> AgentPendingInteractionResolution {
        switch kind {
        case .question:
            guard let pendingAskUser = session.pendingAskUser,
                  pendingAskUser.interaction.id == interactionID
            else {
                throw MCPError.invalidParams("The pending question no longer matches interaction_id.")
            }
            if payload.skip {
                return .askUserSkip(interactionID: interactionID)
            }
            do {
                let drafts: [String: AgentAskUserDraft]
                if !payload.askUserAnswersByQuestionID.isEmpty {
                    drafts = try pendingAskUser.interaction.drafts(from: payload.askUserAnswersByQuestionID)
                } else if !payload.answersByQuestionID.isEmpty {
                    drafts = try pendingAskUser.interaction.drafts(fromFlatAnswers: payload.answersByQuestionID)
                } else {
                    let response = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !response.isEmpty else {
                        throw MCPError.invalidParams("answers are required for ask_user question interactions.")
                    }
                    guard pendingAskUser.interaction.questions.count == 1,
                          let question = pendingAskUser.interaction.questions.first
                    else {
                        throw MCPError.invalidParams("answers are required for multi-question question interactions.")
                    }
                    drafts = try pendingAskUser.interaction.drafts(fromFlatAnswers: [question.id: [response]])
                }
                return .askUser(interactionID: interactionID, drafts: drafts)
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.invalidParams(error.localizedDescription)
            }
        case .mcpElicitation:
            guard let request = session.pendingMCPElicitationRequest,
                  request.id == interactionID
            else {
                throw MCPError.invalidParams("The pending MCP elicitation request no longer matches interaction_id.")
            }
            let rawAction = payload.elicitationActionRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let response: AgentMCPElicitationResponse
            switch rawAction {
            case "accept", "approve", "allow":
                response = AgentMCPElicitationResponse(
                    action: .accept,
                    content: payload.elicitationContent,
                    meta: payload.elicitationMeta
                )
            case "decline", "reject", "deny":
                response = AgentMCPElicitationResponse(action: .decline, meta: payload.elicitationMeta)
            case "cancel":
                response = AgentMCPElicitationResponse(action: .cancel, meta: payload.elicitationMeta)
            case nil, "":
                if !payload.elicitationContent.isEmpty {
                    response = AgentMCPElicitationResponse(
                        action: .accept,
                        content: payload.elicitationContent,
                        meta: payload.elicitationMeta
                    )
                } else {
                    let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else {
                        throw MCPError.invalidParams("response or content is required for MCP elicitation interactions.")
                    }
                    response = AgentMCPElicitationResponse(
                        action: .accept,
                        content: ["response": .string(text)],
                        meta: payload.elicitationMeta
                    )
                }
            default:
                guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw MCPError.invalidParams("response must be one of: accept, decline, cancel, or provide content.")
                }
                response = AgentMCPElicitationResponse(
                    action: .accept,
                    content: ["response": .string(text)],
                    meta: payload.elicitationMeta
                )
            }
            return .mcpElicitation(request: request, response: response)
        case .userInput:
            guard let request = session.pendingUserInputRequest,
                  request.id == interactionID
            else {
                throw MCPError.invalidParams("The pending user input request no longer matches interaction_id.")
            }
            if payload.explicitSkip {
                throw MCPError.invalidParams("skip is not supported for user_input interactions.")
            }
            if payload.hasStructuredAnswerObjects {
                throw MCPError.invalidParams("user_input answers must be strings or arrays of strings.")
            }
            var answers = payload.answersByQuestionID
            if answers.isEmpty,
               let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                guard request.questions.count == 1, let question = request.questions.first else {
                    throw MCPError.invalidParams("answers are required for multi-question user_input interactions.")
                }
                answers[question.id] = [text]
            }
            return .userInput(request: request, response: AgentRequestUserInputResponse(answersByQuestionID: answers))
        case .approval:
            let rawDecision = try Self.canonicalApprovalResponse(from: payload)
            if let review = session.pendingWorktreeMergeReview,
               review.id == interactionID
            {
                let reason = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackReason = reason?.isEmpty == false ? reason! : "Worktree merge review declined."
                let decision: WorktreeMergeReviewDecision
                switch rawDecision {
                case "accept", "approve":
                    decision = .accept
                case "decline", "reject":
                    decision = .reject(reason: fallbackReason)
                case "cancel":
                    decision = .cancelled(reason: reason?.isEmpty == false ? reason! : "Worktree merge review cancelled.")
                default:
                    throw MCPError.invalidParams("response must be one of: accept, decline, cancel.")
                }
                return .worktreeMerge(reviewID: interactionID, decision: decision)
            }
            if let request = session.pendingPermissionsRequest,
               request.id == interactionID
            {
                let decision: AgentApprovalDecision
                switch rawDecision {
                case "accept", "approve":
                    decision = .accept
                case "accept_for_session", "always_allow", "approve_for_session":
                    decision = .acceptForSession
                case "decline":
                    decision = .decline
                case "cancel":
                    decision = .cancel
                case "accept_with_amendment", "amend":
                    throw MCPError.invalidParams("accept_with_amendment is not supported for permission approvals.")
                default:
                    throw MCPError.invalidParams(
                        "response must be one of: accept, accept_for_session, decline, cancel."
                    )
                }
                return .permissions(request: request, decision: decision)
            }
            guard let approval = session.pendingApproval,
                  approval.id == interactionID
            else {
                throw MCPError.invalidParams("The pending approval no longer matches interaction_id.")
            }
            let decision: AgentApprovalDecision
            switch rawDecision {
            case "accept", "approve":
                decision = .accept
            case "accept_for_session", "always_allow", "approve_for_session":
                decision = .acceptForSession
            case "accept_with_amendment", "amend":
                let amendment = payload.amendment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !amendment.isEmpty else {
                    throw MCPError.invalidParams(
                        "amendment is required for accept_with_amendment. response must be one of: \(mcpApprovalDecisionLabels(for: approval, session: session, includeAliases: false).joined(separator: ", ")). No response was applied."
                    )
                }
                decision = .acceptWithExecpolicyAmendment(amendment)
            case "decline", "reject":
                decision = .decline
            case "cancel":
                decision = .cancel
            default:
                throw MCPError.invalidParams(
                    "response must be one of: \(mcpApprovalDecisionLabels(for: approval, session: session, includeAliases: false).joined(separator: ", "))."
                )
            }
            guard CodexAgentModeCoordinator.allowsApprovalDecision(decision, request: approval, session: session) else {
                throw MCPError.invalidParams(
                    "response must be one of: \(mcpApprovalDecisionLabels(for: approval, session: session, includeAliases: false).joined(separator: ", ")). No response was applied."
                )
            }
            return .approval(request: approval, decision: decision)
        case .instruction, .hookApproval:
            throw MCPError.invalidParams(
                "\(kind.rawValue) interactions are not resolved through this path. No response was applied."
            )
        }
    }

    /// Submits a resolution produced by `mcpPendingInteractionResolution` without suspending.
    func applyPendingInteractionResolution(
        _ resolution: AgentPendingInteractionResolution,
        to session: AgentTabSession
    ) throws {
        guard owns(session) else { throw MCPError.invalidParams("The interaction owner is no longer current. No response was applied.") }
        switch resolution {
        case let .askUserSkip(interactionID):
            skipAskUser(session: session, interactionID: interactionID)
        case let .askUser(interactionID, drafts):
            do {
                try submitAskUserResponse(session: session, interactionID: interactionID, draftsByQuestionID: drafts)
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.invalidParams(error.localizedDescription)
            }
        case let .mcpElicitation(request, response):
            try requireCodexCoordinator().submitMCPElicitationResponse(session: session, request: request, response: response)
        case let .userInput(request, response):
            guard submitUserInputResponse(session: session, requestID: request.requestID, response: response) else {
                throw MCPError.invalidParams("The provider response route is unavailable or the user-input request is no longer current. No response was applied.")
            }
        case let .worktreeMerge(reviewID, decision):
            submitWorktreeMergeReviewDecision(session: session, reviewID: reviewID, decision: decision)
        case let .permissions(request, decision):
            try requireCodexCoordinator().submitPermissionsDecision(session: session, request: request, decision: decision)
        case let .approval(request, decision):
            guard submitApprovalDecision(session: session, requestID: request.id, decision: decision) else {
                let current = session.pendingApproval ?? request
                throw MCPError.invalidParams(
                    "The approval is unavailable, unsupported, or no longer matches interaction_id. response must be one of: \(mcpApprovalDecisionLabels(for: current, session: session, includeAliases: false).joined(separator: ", ")). No response was applied."
                )
            }
        }
    }
}
