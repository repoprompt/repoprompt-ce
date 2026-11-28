import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptSettingsCore

/// Exact settings and availability inputs for the existing model/effort decision policy.
/// Presentation and independent Agent hosts can both use it without a selected tab.
@MainActor
struct AgentTaskRoutingPolicy {
    let modelRouterSettingsStore: GlobalSettingsStore
    let modelRouterRuntime: AgentTaskRouterRuntime?
    let availability: @MainActor () -> AgentModelCatalog.AvailabilityContext
    let workspaceID: @MainActor () -> UUID?

    private var modelRouterAvailabilityContext: AgentModelCatalog.AvailabilityContext {
        availability()
    }

    enum GlobalModelRoutingError: LocalizedError {
        case unavailable
        case noTargets
        case failed
        case cancelled
        case stale

        var errorDescription: String? {
            switch self {
            case .unavailable: "Model Router is enabled but its routing service is unavailable."
            case .noTargets: "Model Router has no available targets for this session type."
            case .failed: "Model Router could not choose a target."
            case .cancelled: "Model routing was cancelled."
            case .stale: "The Model Router policy changed while the request was in progress."
            }
        }
    }

    struct StagedTaskRoutingResult {
        let candidates: [AgentTaskRoutingCandidateBuilder.Candidate]
        let outcome: DecisionOutcome
        var judgmentRequested = false
        var effortFallback = false
        var usageBalancingReason: String?
    }

    func routeSubagentTargetIfEnabled(
        task: String,
        surface: AgentModelCatalog.AgentSelectionSurface,
        baseline: AgentRoutingExecutableTarget? = nil,
        allowUsageBalance: Bool = true
    ) async throws -> AgentRoutingExecutableTarget? {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let fallback = { [self] in
            baseline.flatMap { allowUsageBalance ? localUsageDecision(basedOn: $0, scope: .subagent, surface: surface)?.candidate.target : nil }
        }
        guard configuration.enabled else { return fallback() }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else { return fallback() }
        let result = await routeModelThenEffort(
            requestID: UUID(),
            text: task,
            scope: .subagent,
            surface: surface,
            providers: AgentTaskRoutingCandidateBuilder.providers(
                for: .subagent, configuration: configuration, availability: modelRouterAvailabilityContext, surface: .headless
            ),
            configuration: configuration,
            backendID: backendID,
            runtime: runtime,
            allowUsageBalance: allowUsageBalance
        )
        guard modelRouterConfigurationIsCurrent(configuration, backendID: backendID) else {
            throw GlobalModelRoutingError.stale
        }
        switch result.outcome {
        case let .selected(opaqueKey, _):
            guard let selected = result.candidates.only(where: { $0.opaqueKey == opaqueKey }),
                  routingCandidateIsCurrent(selected)
            else { return nil }
            return selected.target
        case .cancelled:
            throw GlobalModelRoutingError.cancelled
        case .abstained, .failed:
            return fallback()
        }
    }

    /// Model-stage picks below this service-reported confidence fall back locally.
    static let minimumModelRouteConfidence = 0.4

    func routeModelThenEffort(
        requestID: UUID,
        text: String,
        scope: AgentTaskRoutingScope,
        surface: AgentModelCatalog.AgentSelectionSurface,
        providers: Set<AgentProviderKind>,
        configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID,
        runtime: AgentTaskRouterRuntime,
        allowUsageBalance: Bool = true,
        capturedSnapshot: RoutingExecutionMetadataSnapshot? = nil,
        capturedRoleDefaults: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference]? = nil,
        balanceObserver: ((AgentTaskRoutingCandidateBuilder.Candidate, [AgentTaskRoutingCandidateBuilder.Candidate], AgentRoutingExecutableTarget) -> Void)? = nil
    ) async -> StagedTaskRoutingResult {
        let builder = AgentTaskRoutingCandidateBuilder()
        let snapshot = capturedSnapshot ?? builder.capture(
            allowedProviders: providers,
            availability: modelRouterAvailabilityContext,
            surface: surface
        )
        guard let registration = await runtime.registry.registration(for: backendID),
              let builtModels = try? builder.build(
                  snapshot: snapshot,
                  roleDefaults: capturedRoleDefaults ?? agentModelRoleDefaultReferences(),
                  maximumChoices: registration.capabilities.finiteChoice.maximumChoices,
                  usagePeerClasses: scope == .primarySession ? AgentTaskRoutingCandidateBuilder.primarySessionUsagePeerClasses : nil
              ), !builtModels.isEmpty
        else {
            return StagedTaskRoutingResult(
                candidates: [],
                outcome: .failed(category: .invalidRequest, retryable: false, evidence: nil)
            )
        }

        var models = builtModels
        var unbalancedModel: AgentTaskRoutingCandidateBuilder.Candidate?
        var usageBalancingReason: String?
        // Critical usage decides the provider outright: the other provider is never offered, and a
        // single remaining model skips the decision service entirely.
        let usageOverride = allowUsageBalance ? runtime.usageBalancer?.routerOverride(candidates: builtModels, configuration: configuration, scope: scope) : nil
        if let usageOverride {
            models = usageOverride.candidates
            usageBalancingReason = usageOverride.reason
        }
        let firstModel = models[0]
        var selectedModel: AgentTaskRoutingCandidateBuilder.Candidate
        var modelEvidence: DecisionEvidence?
        var judgmentRequested = false
        if models.count == 1 {
            selectedModel = firstModel
        } else {
            guard let modelRequest = try? ModelRouterDecisionPolicy().build(
                requestID: requestID,
                task: text,
                scope: scope,
                stage: .model,
                directive: configuration.customInstructions,
                candidates: models,
                capabilities: registration.capabilities
            ) else {
                return StagedTaskRoutingResult(
                    candidates: models,
                    outcome: .failed(category: .invalidRequest, retryable: false, evidence: nil)
                )
            }
            judgmentRequested = true
            let modelOutcome = await runtime.coordinator.decide(
                serviceID: backendID, request: modelRequest, consumerRevision: configuration.revision
            )
            guard case let .selected(modelKey, evidence) = modelOutcome,
                  let match = models.only(where: { $0.opaqueKey == modelKey })
            else { return StagedTaskRoutingResult(candidates: models, outcome: modelOutcome, judgmentRequested: true) }
            // A low-confidence advisory pick is not trusted; keep the local selection instead.
            if let confidence = evidence?.confidence, confidence < Self.minimumModelRouteConfidence {
                return StagedTaskRoutingResult(
                    candidates: models,
                    outcome: .abstained(reasonCode: "low_confidence", evidence: evidence),
                    judgmentRequested: true
                )
            }
            selectedModel = match
            unbalancedModel = match
            modelEvidence = evidence
            if usageOverride == nil, allowUsageBalance, configuration.usageBalancing.enabled, !Task.isCancelled,
               modelRouterConfigurationIsCurrent(configuration, backendID: backendID), let advisor = runtime.usageBalancer
            {
                let decision = advisor.choose(selected: match, candidates: models, evidence: evidence, configuration: configuration)
                selectedModel = decision.candidate
                usageBalancingReason = decision.reason
            }
        }

        balanceObserver?(unbalancedModel ?? selectedModel, models, selectedModel.target)
        guard !Task.isCancelled else {
            return StagedTaskRoutingResult(candidates: models, outcome: .cancelled, judgmentRequested: judgmentRequested)
        }
        let modelFallback = StagedTaskRoutingResult(
            candidates: models,
            outcome: .selected(opaqueKey: selectedModel.opaqueKey, evidence: modelEvidence),
            judgmentRequested: judgmentRequested,
            effortFallback: true,
            usageBalancingReason: usageBalancingReason
        )
        guard let efforts = try? builder.buildEfforts(
            for: selectedModel,
            snapshot: snapshot,
            allowPaidFast: configuration.allowPaidFastRouting,
            maximumChoices: registration.capabilities.finiteChoice.maximumChoices
        ), let firstEffort = efforts.first else {
            return modelFallback
        }
        guard efforts.count > 1 else {
            return StagedTaskRoutingResult(
                candidates: efforts,
                outcome: .selected(opaqueKey: firstEffort.opaqueKey, evidence: nil),
                judgmentRequested: judgmentRequested,
                usageBalancingReason: usageBalancingReason
            )
        }
        guard let effortRequest = try? ModelRouterDecisionPolicy().build(
            requestID: requestID,
            task: text,
            scope: scope,
            stage: .effort,
            directive: configuration.customInstructions,
            candidates: efforts,
            capabilities: registration.capabilities
        ) else {
            return modelFallback
        }
        judgmentRequested = true
        let effortOutcome = await runtime.coordinator.decide(
            serviceID: backendID, request: effortRequest, consumerRevision: configuration.revision
        )
        switch effortOutcome {
        case let .selected(key, _):
            guard let target = efforts.only(where: { $0.opaqueKey == key })?.target,
                  configuration.allowPaidFastRouting || !AgentTaskRoutingCandidateBuilder.isPaidFast(target) else { return modelFallback }
            return StagedTaskRoutingResult(candidates: efforts, outcome: effortOutcome, judgmentRequested: true, usageBalancingReason: usageBalancingReason)
        case .cancelled:
            return StagedTaskRoutingResult(candidates: models, outcome: .cancelled, judgmentRequested: judgmentRequested)
        case .abstained, .failed:
            return StagedTaskRoutingResult(
                candidates: modelFallback.candidates,
                outcome: modelFallback.outcome,
                judgmentRequested: true,
                effortFallback: true,
                usageBalancingReason: usageBalancingReason
            )
        }
    }

    func modelRouterConfigurationIsCurrent(
        _ configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID
    ) -> Bool {
        let current = modelRouterSettingsStore.modelRouterConfiguration()
        return current.enabled
            && current.revision == configuration.revision
            && current.selectedBackendID == backendID
    }

    func agentModelRoleDefaultReferences() -> [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] {
        MCPAgentRoleDefaultsService.resolutions(
            availability: modelRouterAvailabilityContext,
            workspaceID: workspaceID()
        ).map { resolution in
            AgentTaskRoutingCandidateBuilder.RoleDefaultReference(
                roleLabel: resolution.roleLabel,
                provider: resolution.effective.agent,
                modelRaw: resolution.effective.modelRaw,
                isUserOverride: resolution.hasStoredOverride
            )
        }
    }

    func routingCandidateIsCurrent(_ candidate: AgentTaskRoutingCandidateBuilder.Candidate) -> Bool {
        guard let scope = candidate.snapshotScope,
              candidate.profileIdentity == RoutingModelProfileSnapshot.bundled.identity
        else { return false }
        let current = AgentTaskRoutingCandidateBuilder().capture(
            allowedProviders: scope.allowedProviders,
            availability: modelRouterAvailabilityContext,
            surface: scope.surface
        )
        return current.scope == scope && current.contains(candidate.target)
    }

    /// A fresh task uses the original model as its starting choice when Jev is disabled/unavailable.
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
}

private extension Collection {
    func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        var match: Element?
        for element in self where try predicate(element) {
            guard match == nil else { return nil }
            match = element
        }
        return match
    }
}
