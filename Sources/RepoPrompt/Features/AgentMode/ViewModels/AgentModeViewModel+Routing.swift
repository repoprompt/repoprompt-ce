import Foundation

extension AgentModeViewModel {
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

    private struct RoutedSelectionRollback {
        let target: AgentRoutingExecutableTarget
    }

    func modelRouterPillProps() -> AgentModelRouterPillProps {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let available = modelRouterCanRoutePrimarySession(configuration)
        let isRouting = currentTabID.map { freshTaskRoutingByTabID[$0] != nil } ?? false
        let disabledReason: String? = if configuration.enabled, !available {
            "Router is enabled but paused until its routing service and provider targets are available. Click to turn it off."
        } else if !available {
            "Configure a routing service and targets in Model Router Settings."
        } else {
            nil
        }
        let routedModelDisplayName: String? = if configuration.enabled,
                                                 let session = activeSession,
                                                 let audit = session.automationTurnAudit.last(where: { $0.router.eligible }),
                                                 audit.router.decision == .selected,
                                                 !audit.router.fallbackApplied,
                                                 let modelRaw = audit.router.chosenModelRaw,
                                                 modelRaw == session.selectedModelRaw,
                                                 audit.acceptedProviderRaw == session.selectedAgent.rawValue,
                                                 audit.router.application != .fallbackToManual,
                                                 audit.router.application != .failed
        {
            routedModelDisplayName(
                rawModel: modelRaw,
                reasoningEffortRaw: session.selectedAgent.usesClaudeTooling
                    ? session.selectedClaudeEffortRaw
                    : session.selectedReasoningEffortRaw,
                agentKind: session.selectedAgent,
                showsEffort: !modelRouterSettingsStore.autoEffortEnabled()
            )
        } else {
            nil
        }
        return AgentModelRouterPillProps(
            isOn: configuration.enabled,
            isAvailable: available || configuration.enabled,
            isRouting: isRouting,
            disabledReason: disabledReason,
            routedModelDisplayName: routedModelDisplayName,
            usageBalancing: configuration.usageBalancing.enabled
        )
    }

    private func routedModelDisplayName(
        rawModel: String,
        reasoningEffortRaw: String?,
        agentKind: AgentProviderKind,
        showsEffort: Bool
    ) -> String {
        let modelName = inputBarModelDisplayName(rawModel: rawModel, agentKind: agentKind)
        guard showsEffort,
              let reasoningEffortRaw
        else { return modelName }

        let effortName: String? = if agentKind == .codexExec {
            CodexReasoningEffort.parse(reasoningEffortRaw)?.displayName
        } else if agentKind.usesClaudeTooling {
            ClaudeCodeEffortLevel.parse(reasoningEffortRaw)?.displayName
        } else {
            reasoningEffortRaw
        }
        return effortName.map { "\(modelName) \($0)" } ?? modelName
    }

    func autoEffortPillProps() -> AgentAutoEffortPillProps {
        let session = activeSession
        let feedback = session?.autoEffortFeedback.flatMap { feedback in
            feedback.provider == session?.selectedAgent && feedback.selectedModelRaw == session?.selectedModelRaw
                ? feedback : nil
        }
        return AgentAutoEffortPillProps(
            isOn: modelRouterSettingsStore.autoEffortEnabled(),
            isAvailable: modelRouterSettingsStore.autoEffortConfiguration().selectedBackendID.map {
                modelRouterRuntime?.isBackendReady($0) == true
            } ?? false,
            isJudging: session?.autoEffortJudgmentID != nil,
            feedback: feedback
        )
    }

    func toggleAutoEffort() {
        let configuration = modelRouterSettingsStore.autoEffortConfiguration()
        let enabled = configuration.enabled
        guard enabled || configuration.selectedBackendID.map({ modelRouterRuntime?.isBackendReady($0) == true }) == true else { return }
        modelRouterSettingsStore.setAutoEffortEnabled(!enabled)
        syncStatusPillsUIState()
    }

    func handleModelRouterRuntimeChanged() {
        reconcileModelRouterEnabledState()
    }

    func handleModelRouterAvailabilityChanged() {
        reconcileModelRouterEnabledState()
    }

    private func reconcileModelRouterEnabledState() {
        // Readiness and target availability are transient runtime observations, not
        // authorities for the user's persisted enablement intent. Keeping the intent
        // enabled lets startup and provider discovery recover automatically.
        syncAllActiveUIState()
    }

    func toggleGlobalModelRouter() {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        if configuration.enabled {
            modelRouterSettingsStore.setModelRouterEnabled(false)
            modelRouterRuntime?.cancelRoutingRequests()
            syncAllActiveUIState()
            return
        }
        guard let backendID = configuration.selectedBackendID,
              modelRouterRuntime?.isBackendReady(backendID) == true
        else { return }
        guard (try? AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: providers(for: .primarySession, configuration: configuration),
            availability: modelRouterAvailabilityContext
        )) != nil else { return }
        modelRouterSettingsStore.setModelRouterEnabled(true)
        syncAllActiveUIState()
    }

    func cancelFreshTaskRouting(tabID: UUID) async {
        guard let runtime = modelRouterRuntime,
              let owned = freshTaskRoutingByTabID[tabID]
        else { return }
        await runtime.coordinator.cancel(requestID: owned.requestID)
        owned.task.cancel()
        clearFreshTaskRoutingOwnership(owned)
    }

    func isGlobalModelRouterControllingFreshTask(_ session: TabSession) -> Bool {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        return configuration.enabled
            && modelRouterCanRoutePrimarySession(configuration)
            && freshTaskRoutingEligibility(session: session, text: nil)
    }

    func submitUserTurnAfterFreshTaskRouting(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID
    ) async -> UserTurnSubmissionResult {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID
            )
        }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable)
            )
        }

        let providers = providers(for: .primarySession, configuration: configuration)
        let routeTask = Task {
            await routeModelThenEffort(
                requestID: claim.attempt.id,
                text: text,
                scope: .primarySession,
                surface: .general,
                providers: providers,
                configuration: configuration,
                backendID: backendID,
                runtime: runtime
            )
        }
        let stagedResult: StagedTaskRoutingResult
        do {
            let ownership = FreshTaskRoutingOwnership(
                requestID: claim.attempt.id,
                sourceTabID: claim.attempt.sourceTabID,
                destinationTabID: destinationTabID,
                task: routeTask
            )
            guard freshTaskRoutingByTabID[ownership.sourceTabID] == nil,
                  freshTaskRoutingByTabID[ownership.destinationTabID] == nil
            else {
                routeTask.cancel()
                await runtime.coordinator.cancel(requestID: claim.attempt.id)
                return .blocked(message: "Model routing is already in progress for this task.")
            }
            freshTaskRoutingByTabID[ownership.sourceTabID] = ownership
            freshTaskRoutingByTabID[ownership.destinationTabID] = ownership
            syncComposerUIState()
            syncStatusPillsUIState()
            stagedResult = await routeTask.value
            guard ownsFreshTaskRouting(ownership) else {
                return .blocked(message: "Model routing was cancelled.")
            }
            clearFreshTaskRoutingOwnership(ownership)
        }
        let candidates = stagedResult.candidates
        let outcome = stagedResult.outcome
        var routedAudit = AgentAutomationTurnAudit.Feature(
            configured: true,
            eligible: true,
            judgmentRequested: stagedResult.judgmentRequested,
            decision: .selected,
            fallbackApplied: stagedResult.effortFallback,
            usageBalancingReason: stagedResult.usageBalancingReason
        )
        let fallbackAudit = AgentAutomationTurnAudit.Feature(
            configured: true,
            eligible: true,
            judgmentRequested: stagedResult.judgmentRequested,
            decision: .fallback,
            fallbackApplied: true
        )

        let currentConfiguration = modelRouterSettingsStore.modelRouterConfiguration()
        guard composerSubmitClaimIsCurrent(claim),
              sessions[destinationTabID] === session,
              currentConfiguration.revision == configuration.revision,
              currentConfiguration.selectedBackendID == backendID,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return .blocked(message: "The routing request became stale before submission.")
        }

        switch outcome {
        case let .selected(opaqueKey, _):
            guard let selected = candidates.only(where: { $0.opaqueKey == opaqueKey }) else {
                return await submitUserTurnAfterAutoEffort(
                    text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                    routerAudit: fallbackAudit
                )
            }
            let baseline = RoutedSelectionRollback(target: executableTarget(for: session))
            guard applyRoutingTarget(selected, to: session) else {
                return await submitUserTurnAfterAutoEffort(
                    text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                    routerAudit: fallbackAudit
                )
            }
            routedAudit.chosenModelRaw = selected.target.modelRaw
            routedAudit.chosenEffortRaw = selected.target.reasoningEffortRaw
            guard composerSubmitClaimIsCurrent(claim),
                  sessions[destinationTabID] === session,
                  modelRouterSettingsStore.modelRouterConfiguration().revision == configuration.revision,
                  freshTaskRoutingEligibility(session: session, text: text)
            else {
                restoreRoutingSelection(baseline, on: session)
                return .blocked(message: "The routing request became stale before submission.")
            }
            let result = submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                composerOrigin: .localComposer,
                routerAudit: routedAudit
            )
            if result != .submitted {
                restoreRoutingSelection(baseline, on: session)
            } else {
                session.isDirty = true
                scheduleSave(for: session.tabID)
                if currentTabID == session.tabID { syncStatusPillsUIState() }
            }
            return result
        case .abstained, .failed:
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: fallbackAudit
            )
        case .cancelled:
            return .blocked(message: "Model routing was cancelled.")
        }
    }

    /// A routed fresh task already received its initial effort from Model Router. All other
    /// eligible user turns use the same decision path, whether sent by the composer or MCP.
    func submitUserTurnAfterAutoEffort(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        routerAudit: AgentAutomationTurnAudit.Feature? = nil
    ) async -> UserTurnSubmissionResult {
        guard modelRouterSettingsStore.autoEffortEnabled() else {
            return submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                composerOrigin: .localComposer,
                routerAudit: routerAudit
            )
        }
        let choice = await chooseAutoEffortForUserTurn(
            text: claim.attempt.rawDraftSnapshot,
            session: session,
            workflow: session.selectedWorkflow
        )
        let selection = choice.selection
        guard composerSubmitClaimIsCurrent(claim), sessions[destinationTabID] === session
        else { return .blocked(message: Self.staleComposerSubmitTargetMessage) }
        if let routerAudit, routerAudit.usageBalancingReason != nil {
            guard modelRouterSettingsStore.modelRouterConfiguration().usageBalancing.enabled,
                  routerAudit.chosenModelRaw == session.selectedModelRaw,
                  routerAudit.usageBalancingProviderRaw == session.selectedAgent.rawValue,
                  routerAudit.chosenEffortRaw == session.selectedReasoningEffortRaw
            else {
                return .blocked(message: "The usage-balanced selection changed before submission. Send again with the current selection.")
            }
        }
        let result = submitUserTurn(
            text: text,
            tabID: destinationTabID,
            rawDraftText: claim.attempt.rawDraftSnapshot,
            composerOrigin: .localComposer,
            autoEffortSelection: selection,
            autoEffortAudit: choice.audit,
            routerAudit: routerAudit
        )
        if result == .submitted, let selection {
            recordSubmittedAutoEffort(selection, for: session)
        }
        return result
    }

    /// Shared pre-turn judgment. MCP calls this only before an inactive run starts, never to
    /// change effort in the middle of an active provider turn or override an initial routed start.
    func chooseAutoEffortForUserTurn(
        text: String,
        session: TabSession,
        workflow: AgentWorkflowDefinition?
    ) async -> (selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature) {
        let autoEffortConfiguration = modelRouterSettingsStore.autoEffortConfiguration()
        guard autoEffortConfiguration.enabled else {
            return (nil, .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled))
        }
        guard !session.runState.isActive,
              AutoEffortModelPolicy.shouldJudgeWorkflow(workflow),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
              let maskedExcerpt = AutoEffortTaskSummary.make(from: text)
        else {
            return (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
        }
        guard let runtime = modelRouterRuntime,
              let backendID = autoEffortConfiguration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable))
        }

        let provider = session.selectedAgent
        let modelRaw = session.selectedModelRaw
        let selectedWorkflow = session.selectedWorkflow
        let workflowMutationGeneration = session.userWorkflowSelectionMutationGeneration
        let modelID: String
        let efforts: [String]
        let manualEffortRaw: String?
        switch provider {
        case .codexExec:
            guard let base = CodexModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            let option = codexCoordinator.modelOptions(for: .codexExec).first {
                CodexModelSpecifier(raw: $0.rawValue).baseModel?.caseInsensitiveCompare(base) == .orderedSame
            }
            modelID = base
            efforts = AutoEffortModelPolicy.codexEfforts(
                modelRaw: modelRaw,
                advertised: option?.supportedReasoningEfforts ?? []
            )
            manualEffortRaw = codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode:
            guard let base = ClaudeModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            modelID = base
            efforts = AutoEffortModelPolicy.claudeEfforts(
                modelRaw: modelRaw,
                advertised: AgentModelCatalog.supportedClaudeEfforts(
                    forSelectedModelRaw: modelRaw,
                    agentKind: provider
                )
            )
            manualEffortRaw = claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default:
            return ineligibleAutoEffortChoice()
        }
        guard efforts.count >= 2 else { return ineligibleAutoEffortChoice() }
        let judgmentID = UUID()
        session.autoEffortJudgmentID = judgmentID
        if currentTabID == session.tabID { syncStatusPillsUIState() }
        defer {
            if session.autoEffortJudgmentID == judgmentID {
                session.autoEffortJudgmentID = nil
                if currentTabID == session.tabID { syncStatusPillsUIState() }
            }
        }
        guard let registration = await runtime.registry.registration(for: backendID),
              let prepared = try? AutoEffortDecisionPolicy().build(
                  requestID: judgmentID,
                  maskedTaskExcerpt: maskedExcerpt,
                  selectedModelID: modelID,
                  builtInWorkflow: workflow?.builtInWorkflow,
                  efforts: efforts,
                  capabilities: registration.capabilities
              )
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: false, decision: .fallback, fallbackApplied: true))
        }
        let outcome = await runtime.coordinator.decide(
            serviceID: backendID, request: prepared.request, consumerRevision: autoEffortConfiguration.revision
        )
        let chosen = prepared.effort(for: outcome)
        let currentAutoEffortConfiguration = modelRouterSettingsStore.autoEffortConfiguration()
        guard currentAutoEffortConfiguration.enabled,
              currentAutoEffortConfiguration.revision == autoEffortConfiguration.revision,
              currentAutoEffortConfiguration.selectedBackendRawValue == autoEffortConfiguration.selectedBackendRawValue,
              currentAutoEffortConfiguration.selectedBackendID == backendID,
              sessions[session.tabID] === session,
              session.autoEffortJudgmentID == judgmentID,
              session.selectedWorkflow == selectedWorkflow,
              session.userWorkflowSelectionMutationGeneration == workflowMutationGeneration,
              session.selectedAgent == provider,
              session.selectedModelRaw == modelRaw,
              !session.runState.isActive,
              let chosen, efforts.contains(chosen)
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        let currentManualEffortRaw: String? = switch provider {
        case .codexExec: codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode: claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default: nil
        }
        guard currentManualEffortRaw == manualEffortRaw else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        return (
            AutoEffortTurnSelection(
                provider: provider,
                selectedModelRaw: modelRaw,
                manualEffortRaw: manualEffortRaw,
                effortRaw: chosen,
                backendID: backendID,
                autoEffortRevision: autoEffortConfiguration.revision
            ),
            .init(
                configured: true, eligible: true, judgmentRequested: true, decision: .selected,
                chosenModelRaw: modelRaw, chosenEffortRaw: chosen
            )
        )
    }

    private func ineligibleAutoEffortChoice() -> (
        selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature
    ) {
        (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
    }

    func recordSubmittedAutoEffort(_ selection: AutoEffortTurnSelection, for session: TabSession) {
        guard sessions[session.tabID] === session else { return }
        session.autoEffortFeedback = AutoEffortTurnFeedback(
            selection: selection,
            previous: session.autoEffortFeedback
        )
        if currentTabID == session.tabID { syncStatusPillsUIState() }
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
            providers: providers(for: .subagent, configuration: configuration),
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

    private func routeModelThenEffort(
        requestID: UUID,
        text: String,
        scope: AgentTaskRoutingScope,
        surface: AgentModelCatalog.AgentSelectionSurface,
        providers: Set<AgentProviderKind>,
        configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID,
        runtime: AgentTaskRouterRuntime,
        allowUsageBalance: Bool = true
    ) async -> StagedTaskRoutingResult {
        let builder = AgentTaskRoutingCandidateBuilder()
        let snapshot = builder.capture(
            allowedProviders: providers,
            availability: modelRouterAvailabilityContext,
            surface: surface
        )
        guard let registration = await runtime.registry.registration(for: backendID),
              let models = try? builder.build(
                  snapshot: snapshot,
                  roleDefaults: agentModelRoleDefaultReferences(),
                  maximumChoices: registration.capabilities.finiteChoice.maximumChoices
              ), let firstModel = models.first
        else {
            return StagedTaskRoutingResult(
                candidates: [],
                outcome: .failed(category: .invalidRequest, retryable: false, evidence: nil)
            )
        }

        var selectedModel: AgentTaskRoutingCandidateBuilder.Candidate
        var usageBalancingReason: String?
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
            selectedModel = match
            modelEvidence = evidence
            if allowUsageBalance, configuration.usageBalancing.enabled, !Task.isCancelled,
               modelRouterConfigurationIsCurrent(configuration, backendID: backendID), let advisor = runtime.usageBalancer
            {
                let decision = advisor.choose(selected: match, candidates: models, evidence: evidence, configuration: configuration)
                selectedModel = decision.candidate
                usageBalancingReason = decision.reason
            }
        }

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

    private func modelRouterConfigurationIsCurrent(
        _ configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID
    ) -> Bool {
        let current = modelRouterSettingsStore.modelRouterConfiguration()
        return current.enabled
            && current.revision == configuration.revision
            && current.selectedBackendID == backendID
    }

    private func providers(for scope: AgentTaskRoutingScope, configuration: AgentTaskRouterConfiguration) -> Set<AgentProviderKind> {
        AgentTaskRoutingCandidateBuilder.providers(
            for: scope,
            configuration: configuration,
            availability: modelRouterAvailabilityContext,
            surface: scope == .subagent ? .headless : .general
        )
    }

    private func agentModelRoleDefaultReferences() -> [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] {
        MCPAgentRoleDefaultsService.resolutions(
            availability: modelRouterAvailabilityContext,
            workspaceID: workspaceManager?.activeWorkspaceID
        ).map { resolution in
            AgentTaskRoutingCandidateBuilder.RoleDefaultReference(
                roleLabel: resolution.roleLabel,
                provider: resolution.effective.agent,
                modelRaw: resolution.effective.modelRaw,
                isUserOverride: resolution.hasStoredOverride
            )
        }
    }

    func freshTaskRoutingEligibility(session: TabSession, text: String?) -> Bool {
        guard isModelRouterEligibleFirstSendDestination(session),
              session.providerSessionID == nil,
              session.codexConversationID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated,
              session.parentSessionID == nil,
              !session.pendingHandoff.hasPayload
        else { return false }
        guard let text else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/")
    }

    /// Selected prompt workflows still create a brand-new provider session and therefore remain
    /// Router-owned. The broader first-send helper excludes workflows because it also guards tab
    /// creation and cleanup, where an empty destination must not yet carry copied pending state.
    private func isModelRouterEligibleFirstSendDestination(_ session: TabSession) -> Bool {
        !session.runState.isActive
            && !session.hasSentFirstMessage
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
            && session.pendingImageAttachments.isEmpty
            && session.pendingTaggedFileAttachments.isEmpty
    }

    private func modelRouterCanRoutePrimarySession(_ configuration: AgentTaskRouterConfiguration) -> Bool {
        guard let backendID = configuration.selectedBackendID,
              modelRouterRuntime?.isBackendReady(backendID) == true
        else { return false }
        return AgentTaskRoutingCandidateBuilder().hasAvailableTarget(
            allowedProviders: providers(for: .primarySession, configuration: configuration),
            availability: modelRouterAvailabilityContext
        )
    }

    func executableTarget(for session: TabSession) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameters: session.acpModelParameterSelections
        )
    }

    private func routingCandidateIsCurrent(_ candidate: AgentTaskRoutingCandidateBuilder.Candidate) -> Bool {
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

    func applyRoutingTarget(_ candidate: AgentTaskRoutingCandidateBuilder.Candidate, to session: TabSession) -> Bool {
        let target = candidate.target
        guard routingCandidateIsCurrent(candidate),
              let agent = AgentProviderKind(rawValue: target.agentRaw),
              AgentModelCatalog.isAgentAvailable(agent, availability: modelRouterAvailabilityContext)
        else { return false }
        session.selectedAgent = agent
        session.selectedModelRaw = target.modelRaw
        session.selectedReasoningEffortRaw = target.reasoningEffortRaw
        session.acpModelParameterSelections = target.modelParameters
        if session.tabID == currentTabID {
            applySessionToBindings(session)
        }
        return executableTarget(for: session) == target
    }

    private func restoreRoutingSelection(_ rollback: RoutedSelectionRollback, on session: TabSession) {
        restoreUsageStartingTarget(rollback.target, on: session)
    }

    func restoreUsageStartingTarget(_ target: AgentRoutingExecutableTarget, on session: TabSession) {
        guard let agent = AgentProviderKind(rawValue: target.agentRaw) else { return }
        session.selectedAgent = agent
        session.selectedModelRaw = target.modelRaw
        session.selectedReasoningEffortRaw = target.reasoningEffortRaw
        session.acpModelParameterSelections = target.modelParameters
        if session.tabID == currentTabID {
            applySessionToBindings(session)
        }
    }

    private func ownsFreshTaskRouting(_ ownership: FreshTaskRoutingOwnership) -> Bool {
        freshTaskRoutingByTabID[ownership.sourceTabID]?.requestID == ownership.requestID
            && freshTaskRoutingByTabID[ownership.destinationTabID]?.requestID == ownership.requestID
    }

    private func clearFreshTaskRoutingOwnership(_ ownership: FreshTaskRoutingOwnership) {
        if freshTaskRoutingByTabID[ownership.sourceTabID]?.requestID == ownership.requestID {
            freshTaskRoutingByTabID.removeValue(forKey: ownership.sourceTabID)
        }
        if freshTaskRoutingByTabID[ownership.destinationTabID]?.requestID == ownership.requestID {
            freshTaskRoutingByTabID.removeValue(forKey: ownership.destinationTabID)
        }
        syncComposerUIState()
        syncStatusPillsUIState()
        requestUIRefresh(tabID: ownership.sourceTabID, urgent: true)
        if ownership.destinationTabID != ownership.sourceTabID {
            requestUIRefresh(tabID: ownership.destinationTabID, urgent: true)
        }
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
