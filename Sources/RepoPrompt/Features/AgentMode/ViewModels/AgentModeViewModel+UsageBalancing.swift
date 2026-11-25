import Foundation
import RepoPromptAIContracts

extension AgentModeViewModel {
    /// A fresh task uses the visible model as its starting choice when Jev is disabled/unavailable.
    /// Runs entirely on attributed memory; acquisition is scheduled independently by the advisor.
    func localUsageDecision(
        basedOn target: AgentRoutingExecutableTarget,
        scope: AgentTaskRoutingScope,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> AgentUsageBalancer.Decision? {
        taskRoutingPolicy.localUsageDecision(basedOn: target, scope: scope, surface: surface)
    }

    func submitUserTurnAfterUsageBalancing(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        routerAudit: AgentAutomationTurnAudit.Feature? = nil,
        autoWorkflow: AutoWorkflowTurnSelection? = nil,
        repromptedText: String? = nil
    ) async -> UserTurnSubmissionResult {
        let baseline = executableTarget(for: session)
        let effectiveEffort: String? = switch session.selectedAgent {
        case .codexExec: codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode: claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default: baseline.reasoningEffortRaw
        }
        let balancingBaseline = AgentRoutingExecutableTarget(agentRaw: baseline.agentRaw, modelRaw: baseline.modelRaw, reasoningEffortRaw: effectiveEffort, modelParameters: baseline.modelParameters)
        guard freshTaskRoutingEligibility(session: session, text: text),
              composerSubmitRuntime.isCurrent(claim),
              let decision = localUsageDecision(basedOn: balancingBaseline, scope: .primarySession, surface: .general),
              applyRoutingTarget(decision.candidate, to: session)
        else {
            return await submitUserTurnAfterAutoEffort(text: text, claim: claim, session: session, destinationTabID: destinationTabID, routerAudit: routerAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText)
        }
        var audit = routerAudit ?? AgentAutomationTurnAudit.Feature(configured: false, eligible: true, judgmentRequested: false, decision: .selected)
        audit.chosenModelRaw = decision.candidate.target.modelRaw
        audit.chosenEffortRaw = decision.candidate.target.reasoningEffortRaw
        audit.usageBalancingReason = decision.reason
        audit.usageBalancingProviderRaw = decision.candidate.target.agentRaw
        let result = await submitUserTurnAfterAutoEffort(text: text, claim: claim, session: session, destinationTabID: destinationTabID, routerAudit: audit, autoWorkflow: autoWorkflow, repromptedText: repromptedText)
        if result != .submitted, executableTarget(for: session) == decision.candidate.target {
            restoreUsageStartingTarget(baseline, on: session)
        } else if result == .submitted {
            session.isDirty = true
            persistenceRuntime.scheduleSave(for: session.tabID)
        }
        return result
    }
}
