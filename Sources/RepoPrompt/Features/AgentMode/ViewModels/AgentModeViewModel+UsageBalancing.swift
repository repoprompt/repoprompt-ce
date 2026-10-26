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
        let builder = AgentTaskRoutingCandidateBuilder()
        // Critical usage is not limited to a same-tier, same-effort peer of the starting model:
        // when the dominant provider has no such peer (for example Luna-low vs Haiku), the task
        // still moves to that provider's comparable tier, falling back to its strong tier.
        // Same starting-target exclusions as ordinary balancing: explicit paid Fast, parameterized
        // targets, and providers outside Claude/Codex are never replaced.
        if configuration.usageBalancing.overridesRouter,
           target.modelParameters.isEmpty, !AgentTaskRoutingCandidateBuilder.isPaidFast(target),
           [AgentProviderKind.claudeCode.rawValue, AgentProviderKind.codexExec.rawValue].contains(target.agentRaw),
           let models = try? builder.build(allowedProviders: allowed, availability: availability, surface: surface),
           let forced = advisor.routerOverride(candidates: models, configuration: configuration, scope: scope)
        {
            let startingClass = models.first { $0.target.agentRaw == target.agentRaw && $0.target.modelRaw == target.modelRaw }?.usagePeerClass
                ?? builder.usageCandidates(basedOn: target, allowedProviders: allowed, availability: availability, surface: surface)?.selected.usagePeerClass
            // Keep the starting model only when it is already an allowed tier of the dominant provider;
            // a Luna start with OpenAI dominant still moves up to Sol, just as it would move to Opus.
            if forced.candidates.contains(where: { $0.target.agentRaw == target.agentRaw && $0.usagePeerClass == startingClass }) { return nil }
            // The primary-session floor already removed light/balanced tiers of either provider.
            if let choice = forced.candidates.first(where: { startingClass != nil && $0.usagePeerClass == startingClass })
                ?? forced.candidates.first(where: { $0.usagePeerClass == "strong" })
                ?? forced.candidates.first
            {
                return AgentUsageBalancer.Decision(candidate: choice, reason: forced.reason)
            }
        }
        guard let input = builder.usageCandidates(basedOn: target, allowedProviders: allowed, availability: availability, surface: surface) else { return nil }
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
