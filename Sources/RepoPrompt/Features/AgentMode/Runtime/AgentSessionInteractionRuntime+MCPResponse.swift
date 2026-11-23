import Foundation
import MCP

@MainActor
extension AgentSessionInteractionRuntime {
    /// The exact control writer owns the pending prompt and its response. The caller
    /// supplies the existing instruction-dispatch adapter; other interaction effects
    /// always stay on this runtime.
    func resolveMCPResponse(
        command: AgentSessionRuntimeStore.Command,
        interactionID: UUID,
        payload: AgentMCPInteractionResponsePayload,
        dispatchInstruction: (String) async throws -> AgentMCPInstructionDispatch
    ) async throws -> AgentMCPInstructionDispatch? {
        let session = command.writer.session
        let sessionID = command.identity.sessionID
        guard let scope, command.writer.scope === scope, command.isCurrent,
              scope.mcp.controlledWriter(sessionID: sessionID)?.identity == command.identity
        else {
            throw MCPError.invalidParams("The requested agent run is no longer active.")
        }

        // Infer the interaction kind from the live pending interaction
        guard let currentInteraction = scope.mcp.mcpPendingInteraction(for: session) else {
            throw MCPError.invalidParams("No pending interaction found for the active run.")
        }
        guard currentInteraction.id == interactionID else {
            throw MCPError.invalidParams(
                "interaction_id \"\(interactionID.uuidString)\" does not match the current pending \(currentInteraction.kind.rawValue) interaction_id \"\(currentInteraction.id.uuidString)\". No response was applied. Call agent_run with op=\"poll\" or op=\"wait\" and session_id=\"\(sessionID.uuidString)\" to fetch the latest snapshot before responding."
            )
        }
        let kind = currentInteraction.kind
        switch kind {
        case .instruction:
            let expectedID = session.instructionWaitID ?? session.mcpControlContext?.sessionID
            guard expectedID == interactionID else {
                throw MCPError.invalidParams("The pending instruction prompt no longer matches interaction_id.")
            }
            let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw MCPError.invalidParams("response is required for instruction prompts.")
            }
            return try await dispatchInstruction(text)
        case .question, .mcpElicitation, .userInput, .approval:
            let resolution = try mcpPendingInteractionResolution(
                for: session,
                kind: kind,
                interactionID: interactionID,
                payload: payload
            )
            try applyPendingInteractionResolution(resolution, command: command)
            scope.mcp.handleObservedMCPStateChange(for: session)
            return nil
        case .hookApproval:
            guard let request = session.pendingCodexHookReview,
                  request.id == interactionID
            else {
                throw MCPError.invalidParams("The pending hook approval no longer matches interaction_id.")
            }
            guard !request.phase.isResolving else {
                throw MCPError.invalidParams(AgentCodexHookReviewResolutionError.busy.localizedDescription)
            }
            let rawDecision = try mcpCanonicalCodexHookResponse(from: payload)
            guard let action = MCPCodexHookAction(rawValue: rawDecision) else {
                throw MCPError.invalidParams(
                    "response must use one of the canonical decisions advertised by the current hook_approval interaction."
                )
            }
            var allowedArgumentNames = Set(["response"])
            if action == .approveSelected {
                allowedArgumentNames.insert("answers")
            }
            guard payload.suppliedArgumentNames.isSubset(of: allowedArgumentNames) else {
                throw MCPError.invalidParams(
                    "Hook approval received an unsupported top-level argument. No response was applied."
                )
            }
            let decision: AgentCodexHookReviewDecision
            switch action {
            case .approveSelected:
                guard request.phase.allowsTrustDecision else {
                    throw MCPError.invalidParams(AgentCodexHookReviewResolutionError.invalidDecision.localizedDescription)
                }
                guard payload.containsArgument("answers"),
                      !payload.hasNormalizedAnswerFieldNames,
                      payload.answerValueShapesByQuestionID == ["hook_keys": .stringArray],
                      let hookKeys = payload.answersByQuestionID["hook_keys"],
                      !hookKeys.isEmpty,
                      Set(hookKeys.map(CodexHookUTF8Identity.init)).count == hookKeys.count
                else {
                    throw MCPError.invalidParams(
                        "approve_selected requires exactly answers={\"hook_keys\": [\"<exact key>\", ...]} with one or more unique hook keys."
                    )
                }
                let availableKeys = Set(request.hooks.map { CodexHookUTF8Identity($0.key) })
                guard hookKeys.allSatisfy({ availableKeys.contains(CodexHookUTF8Identity($0)) }) else {
                    throw MCPError.invalidParams(
                        "approve_selected contains a hook key that is not part of the current interaction. Poll for the latest hook approval snapshot."
                    )
                }
                decision = .approveSelected(hookKeys: hookKeys)
            case .trustAll:
                guard request.phase.allowsTrustDecision else {
                    throw MCPError.invalidParams(AgentCodexHookReviewResolutionError.invalidDecision.localizedDescription)
                }
                guard !payload.containsArgument("answers") else {
                    throw MCPError.invalidParams("trust_all requires the answers argument to be absent.")
                }
                decision = .approveAll
            case .continueWithoutHooks:
                guard request.phase.allowsContinueWithoutHooks else {
                    throw MCPError.invalidParams(AgentCodexHookReviewResolutionError.invalidDecision.localizedDescription)
                }
                guard !payload.containsArgument("answers") else {
                    throw MCPError.invalidParams("continue_without_hooks requires the answers argument to be absent.")
                }
                guard !isCodexHookApprovalStrictModeEnabled(for: session) else {
                    throw MCPError.invalidParams(
                        AgentCodexHookReviewResolutionError.strictModeRequiresApproval.localizedDescription
                    )
                }
                decision = .continueWithoutHooks
            case .retry:
                guard request.phase.allowsDiscoveryRetry else {
                    throw MCPError.invalidParams(AgentCodexHookReviewResolutionError.invalidDecision.localizedDescription)
                }
                guard !payload.containsArgument("answers") else {
                    throw MCPError.invalidParams("retry requires the answers argument to be absent.")
                }
                decision = .retryDiscovery
            }
            do {
                try await submitCodexHookReviewDecision(
                    command: command,
                    requestID: request.id,
                    decision: decision
                )
            } catch let error as AgentCodexHookReviewResolutionError {
                throw MCPError.invalidParams(error.localizedDescription)
            } catch {
                throw MCPError.invalidParams("The hook approval operation could not be completed. Review the current interaction and retry.")
            }
            return nil
        }
    }

    private typealias MCPCodexHookAction = AgentSessionMCPRuntime.MCPCodexHookAction

    private func mcpCanonicalCodexHookResponse(from payload: AgentMCPInteractionResponsePayload) throws -> String {
        if payload.containsArgument("decision")
            || payload.containsArgument("skip")
            || payload.containsArgument("amendment")
            || payload.containsArgument("content")
            || payload.containsArgument("meta")
            || payload.containsArgument("_meta")
        {
            throw MCPError.invalidParams(
                "Hook approval accepts only response and flat string-array answers. decision, skip, amendment, content, and _meta are not supported. No response was applied."
            )
        }
        if payload.hasStructuredAnswerObjects {
            throw MCPError.invalidParams(
                "Hook approval answers must use flat string arrays; structured answer objects are not supported. No response was applied."
            )
        }
        switch payload.responseArgument {
        case .missing:
            throw MCPError.invalidParams(
                "response is required for hook approval interactions. No response was applied."
            )
        case .nonScalar:
            throw MCPError.invalidParams(
                "response must be a non-empty top-level scalar string for hook approval interactions. No response was applied."
            )
        case let .scalar(response):
            let canonical = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !canonical.isEmpty else {
                throw MCPError.invalidParams(
                    "response must be a non-empty top-level scalar string for hook approval interactions. No response was applied."
                )
            }
            return canonical
        }
    }
}
