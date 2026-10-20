import Foundation

extension AgentModeViewModel {
    /// A fresh task uses the visible model as its starting choice when Jev is disabled/unavailable.
    /// Runs entirely on attributed memory; acquisition is scheduled independently by the advisor.
    func localUsageDecision(
        basedOn target: AgentRoutingExecutableTarget,
        scope: AgentTaskRoutingScope,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> AgentUsageBalancer.Decision? {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.usageBalancing.enabled, let advisor = modelRouterRuntime?.usageBalancer else { return nil }
        let availability = scope == .subagent
            ? modelRouterAvailabilityContext.filteredForRecommendationProviders(modelRouterSettingsStore.globalRecommendationProviderFilter())
            : modelRouterAvailabilityContext
        let allowed = AgentTaskRoutingCandidateBuilder.providers(
            for: scope,
            configuration: configuration,
            availability: availability,
            surface: surface
        )
        guard let input = AgentTaskRoutingCandidateBuilder().usageCandidates(basedOn: target, allowedProviders: allowed, availability: availability, surface: surface) else { return nil }
        let decision = advisor.choose(selected: input.selected, candidates: input.candidates, evidence: nil, configuration: configuration)
        return decision.reason == nil ? nil : decision
    }

    func submitUserTurnAfterUsageBalancing(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        routerAudit: AgentAutomationTurnAudit.Feature? = nil,
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
              composerSubmitClaimIsCurrent(claim),
              let decision = localUsageDecision(basedOn: balancingBaseline, scope: .primarySession, surface: .general),
              applyRoutingTarget(decision.candidate, to: session)
        else {
            return await submitUserTurnAfterAutoEffort(text: text, claim: claim, session: session, destinationTabID: destinationTabID, routerAudit: routerAudit, repromptedText: repromptedText)
        }
        var audit = routerAudit ?? AgentAutomationTurnAudit.Feature(configured: false, eligible: true, judgmentRequested: false, decision: .selected)
        audit.chosenModelRaw = decision.candidate.target.modelRaw
        audit.chosenEffortRaw = decision.candidate.target.reasoningEffortRaw
        audit.usageBalancingReason = decision.reason
        audit.usageBalancingProviderRaw = decision.candidate.target.agentRaw
        let result = await submitUserTurnAfterAutoEffort(text: text, claim: claim, session: session, destinationTabID: destinationTabID, routerAudit: audit, repromptedText: repromptedText)
        if result != .submitted, executableTarget(for: session) == decision.candidate.target {
            restoreUsageStartingTarget(baseline, on: session)
        } else if result == .submitted {
            session.isDirty = true
            scheduleSave(for: session.tabID)
        }
        return result
    }
}
