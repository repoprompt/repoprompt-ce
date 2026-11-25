import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts

extension AgentModeViewModel {
    typealias GlobalModelRoutingError = AgentTaskRoutingPolicy.GlobalModelRoutingError

    private struct RoutedSelectionRollback {
        let target: AgentRoutingExecutableTarget
    }

    func modelRouterPillProps(tabID: UUID? = nil) -> AgentModelRouterPillProps {
        let currentTabID = tabID ?? currentTabID
        let activeSession = currentTabID.flatMap { sessions[$0] }
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

    func autoEffortPillProps(tabID: UUID? = nil) -> AgentAutoEffortPillProps {
        let session = (tabID ?? currentTabID).flatMap { sessions[$0] }
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
        ui.statusPills.update(makeStatusPillsSnapshot())
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
            allowedProviders: AgentTaskRoutingCandidateBuilder.providers(
                for: .primarySession, configuration: configuration, availability: modelRouterAvailabilityContext, surface: .general
            ),
            availability: modelRouterAvailabilityContext
        )) != nil else { return }
        modelRouterSettingsStore.setModelRouterEnabled(true)
        syncAllActiveUIState()
    }

    func cancelFreshTaskRouting(tabID: UUID) async {
        guard let runtime = modelRouterRuntime,
              let owned = freshTaskRoutingByTabID[tabID]
        else { return }
        // Withdraw ownership before backend cancellation suspends, so a cancelled route cannot
        // dispatch or block a fresh local send while the coordinator settles.
        owned.task.cancel()
        clearFreshTaskRoutingOwnership(owned)
        await runtime.coordinator.cancel(requestID: owned.cancellationRequestID ?? owned.requestID)
    }

    func isGlobalModelRouterControllingFreshTask(_ session: TabSession) -> Bool {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        return configuration.enabled
            && modelRouterCanRoutePrimarySession(configuration)
            && freshTaskRoutingEligibility(session: session, text: nil)
    }

    /// Scheduled attachment admission must remain joined to the composer claim, just like
    /// provider-switch admission; `.submitted` from the synchronous ingress is only scheduling.
    private func submitClaimedOrdinaryUserTurn(
        text: String, tabID: UUID, claim: AgentComposerSubmitClaim, rawDraftText: String,
        composerOrigin: AgentUserInputOrigin,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        autoEffortAudit: AgentAutomationTurnAudit.Feature? = nil,
        routerAudit: AgentAutomationTurnAudit.Feature? = nil,
        autoWorkflow: AutoWorkflowTurnSelection? = nil,
        repromptedText: String? = nil,
        repromptAudit: AgentAutomationTurnAudit.Reprompt? = nil
    ) async -> UserTurnSubmissionResult {
        var pending: Task<UserTurnSubmissionResult, Never>?
        let immediate = submitUserTurn(
            text: text, tabID: tabID, rawDraftText: rawDraftText, composerOrigin: composerOrigin,
            autoEffortSelection: autoEffortSelection, autoEffortAudit: autoEffortAudit,
            routerAudit: routerAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText,
            repromptAudit: repromptAudit, providerSwitchClaim: claim,
            scheduledProviderSwitchSubmission: { pending = $0 }
        )
        if let pending {
            return await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
        }
        return immediate
    }

    func submitUserTurnAfterFreshTaskRouting(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        autoWorkflow: AutoWorkflowTurnSelection? = nil,
        repromptedText: String? = nil,
        precomputedRouting: RepromptSpeculation? = nil
    ) async -> UserTurnSubmissionResult {
        guard composerSubmitRuntime.isCurrent(claim), sessions[destinationTabID] === session else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID, autoWorkflow: autoWorkflow, repromptedText: repromptedText
            )
        }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable), autoWorkflow: autoWorkflow, repromptedText: repromptedText
            )
        }

        let providers = AgentTaskRoutingCandidateBuilder.providers(
            for: .primarySession, configuration: configuration, availability: modelRouterAvailabilityContext, surface: .general
        )
        let reusable = reusableRepromptRouting(precomputedRouting, approved: repromptedText, configuration: configuration, backendID: backendID, runtime: runtime)
        let routeTask = reusable?.routingTask ?? Task {
            await routeModelThenEffort(
                requestID: claim.attempt.id,
                text: repromptedText ?? text,
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
                task: routeTask,
                cancellationRequestID: reusable?.requestID
            )
            guard freshTaskRoutingByTabID[ownership.sourceTabID] == nil,
                  freshTaskRoutingByTabID[ownership.destinationTabID] == nil
            else {
                routeTask.cancel()
                await runtime.coordinator.cancel(requestID: reusable?.requestID ?? claim.attempt.id)
                return .blocked(message: "Model routing is already in progress for this task.")
            }
            freshTaskRoutingByTabID[ownership.sourceTabID] = ownership
            freshTaskRoutingByTabID[ownership.destinationTabID] = ownership
            syncComposerUIState()
            ui.statusPills.update(makeStatusPillsSnapshot())
            stagedResult = await routeTask.value
            guard ownsFreshTaskRouting(ownership) else {
                return .blocked(message: "Model routing was cancelled.")
            }
            clearFreshTaskRoutingOwnership(ownership)
        }
        if let reusable, reusableRepromptRouting(reusable, approved: repromptedText, configuration: configuration, backendID: backendID, runtime: runtime) == nil {
            return await submitUserTurnAfterFreshTaskRouting(text: text, claim: claim, session: session, destinationTabID: destinationTabID, autoWorkflow: autoWorkflow, repromptedText: repromptedText)
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
        guard composerSubmitRuntime.isCurrent(claim),
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
                    routerAudit: fallbackAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText
                )
            }
            let baseline = RoutedSelectionRollback(target: executableTarget(for: session))
            guard applyRoutingTarget(selected, to: session) else {
                return await submitUserTurnAfterAutoEffort(
                    text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                    routerAudit: fallbackAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText
                )
            }
            routedAudit.chosenModelRaw = selected.target.modelRaw
            routedAudit.chosenEffortRaw = selected.target.reasoningEffortRaw
            guard composerSubmitRuntime.isCurrent(claim),
                  sessions[destinationTabID] === session,
                  modelRouterSettingsStore.modelRouterConfiguration().revision == configuration.revision,
                  freshTaskRoutingEligibility(session: session, text: text)
            else {
                restoreRoutingSelection(baseline, on: session)
                return .blocked(message: "The routing request became stale before submission.")
            }
            let result = await submitClaimedOrdinaryUserTurn(
                text: text,
                tabID: destinationTabID, claim: claim,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                composerOrigin: .localComposer,
                routerAudit: routedAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText,
                repromptAudit: repromptAuditForClaim(claim, judgedText: stagedResult.judgmentRequested ? (repromptedText == nil ? .originalFallback : .approved) : nil)
            )
            if result != .submitted {
                restoreRoutingSelection(baseline, on: session)
            } else {
                session.isDirty = true
                persistenceRuntime.scheduleSave(for: session.tabID)
                if currentTabID == session.tabID {
                    ui.statusPills.update(makeStatusPillsSnapshot())
                }
            }
            return result
        case .abstained, .failed:
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: fallbackAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText
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
        routerAudit: AgentAutomationTurnAudit.Feature? = nil,
        autoWorkflow: AutoWorkflowTurnSelection? = nil,
        repromptedText: String? = nil
    ) async -> UserTurnSubmissionResult {
        guard composerSubmitRuntime.isCurrent(claim), sessions[destinationTabID] === session else {
            return .blocked(message: Self.staleComposerSubmitTargetMessage)
        }
        guard modelRouterSettingsStore.autoEffortEnabled() else {
            return await submitClaimedOrdinaryUserTurn(
                text: text,
                tabID: destinationTabID, claim: claim,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                composerOrigin: .localComposer,
                routerAudit: routerAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText,
                repromptAudit: repromptAuditForClaim(claim, judgedText: routerAudit?.judgmentRequested == true ? (repromptedText == nil ? .originalFallback : .approved) : nil)
            )
        }
        let judgingText = Self.automationJudgingText(original: repromptDispatchOriginals[claim.attempt.id] ?? claim.attempt.rawDraftSnapshot, reprompted: repromptedText)
        let judgedWorkflow = effectiveWorkflow(session: session, autoWorkflow: autoWorkflow)
        let choice: (selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature)
        if let speculation = reusableRepromptEffort(claim: claim, approved: repromptedText, session: session, autoWorkflow: autoWorkflow),
           let task = speculation.effortTask
        {
            let staged = await task.value
            if let staged, reusableRepromptEffort(claim: claim, approved: repromptedText, session: session, autoWorkflow: autoWorkflow) != nil {
                choice = staged
            } else {
                choice = await chooseAutoEffortForUserTurn(text: judgingText, session: session, workflow: judgedWorkflow, isRepromptReplacement: repromptedText != nil, isCurrent: {
                    composerSubmitRuntime.isCurrent(claim) && sessions[destinationTabID] === session
                })
            }
        } else {
            choice = await chooseAutoEffortForUserTurn(text: judgingText, session: session, workflow: judgedWorkflow, isRepromptReplacement: repromptedText != nil, isCurrent: {
                composerSubmitRuntime.isCurrent(claim) && sessions[destinationTabID] === session
            })
        }
        var selection = choice.selection
        var effortAudit = choice.audit
        if judgedWorkflow != effectiveWorkflow(session: session, autoWorkflow: autoWorkflow) {
            selection = nil
            if effortAudit.judgmentRequested {
                effortAudit.decision = .fallback
                effortAudit.fallbackApplied = true
            }
        }
        guard composerSubmitRuntime.isCurrent(claim), sessions[destinationTabID] === session
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
        let result = await submitClaimedOrdinaryUserTurn(
            text: text,
            tabID: destinationTabID, claim: claim,
            rawDraftText: claim.attempt.rawDraftSnapshot,
            composerOrigin: .localComposer,
            autoEffortSelection: selection,
            autoEffortAudit: effortAudit,
            routerAudit: routerAudit, autoWorkflow: autoWorkflow, repromptedText: repromptedText,
            repromptAudit: repromptAuditForClaim(
                claim,
                judgedText: choice.audit.judgmentRequested
                    ? (repromptedText.map { $0.count <= 4000 } == true ? .approved : .originalFallback)
                    : (routerAudit?.judgmentRequested == true ? (repromptedText == nil ? .originalFallback : .approved) : nil)
            )
        )
        if result == .submitted, let selection {
            recordSubmittedAutoEffort(selection, for: session)
        }
        return result
    }

    func chooseAutoEffortForUserTurn(
        text: String, session: TabSession, workflow: AgentWorkflowDefinition?,
        requestID: UUID = UUID(), isSpeculative: Bool = false, isRepromptReplacement: Bool = false,
        isCurrent: @MainActor () -> Bool
    ) async -> (selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature) {
        await autoEffortTurnPolicy.chooseAutoEffortForUserTurn(
            text: text, session: session, workflow: workflow, requestID: requestID,
            isSpeculative: isSpeculative, isRepromptReplacement: isRepromptReplacement, isCurrent: isCurrent
        )
    }

    func recordSubmittedAutoEffort(_ selection: AutoEffortTurnSelection, for session: TabSession) {
        autoEffortTurnPolicy.recordSubmittedAutoEffort(selection, for: session)
    }

    private var autoEffortTurnPolicy: AgentAutoEffortTurnPolicy {
        .init(
            modelRouterSettingsStore: modelRouterSettingsStore, modelRouterRuntime: modelRouterRuntime,
            codexCoordinator: codexCoordinator, claudeCoordinator: claudeCoordinator,
            ownsSession: { self.sessions[$0.tabID] === $0 }, didChange: { session in
                if self.currentTabID == session.tabID { self.ui.statusPills.update(self.makeStatusPillsSnapshot()) }
            }
        )
    }

    var taskRoutingPolicy: AgentTaskRoutingPolicy {
        .init(
            modelRouterSettingsStore: modelRouterSettingsStore, modelRouterRuntime: modelRouterRuntime,
            availability: { self.modelRouterAvailabilityContext },
            workspaceID: { self.workspaceManager?.activeWorkspaceID }
        )
    }

    func routeSubagentTargetIfEnabled(
        task: String,
        surface: AgentModelCatalog.AgentSelectionSurface,
        baseline: AgentRoutingExecutableTarget? = nil,
        allowUsageBalance: Bool = true
    ) async throws -> AgentRoutingExecutableTarget? {
        try await taskRoutingPolicy.routeSubagentTargetIfEnabled(
            task: task, surface: surface, baseline: baseline, allowUsageBalance: allowUsageBalance
        )
    }

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
        await taskRoutingPolicy.routeModelThenEffort(
            requestID: requestID, text: text, scope: scope, surface: surface, providers: providers,
            configuration: configuration, backendID: backendID, runtime: runtime,
            allowUsageBalance: allowUsageBalance, capturedSnapshot: capturedSnapshot,
            capturedRoleDefaults: capturedRoleDefaults, balanceObserver: balanceObserver
        )
    }

    private func modelRouterConfigurationIsCurrent(
        _ configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID
    ) -> Bool {
        taskRoutingPolicy.modelRouterConfigurationIsCurrent(configuration, backendID: backendID)
    }

    func agentModelRoleDefaultReferences() -> [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] {
        taskRoutingPolicy.agentModelRoleDefaultReferences()
    }

    func freshTaskRoutingEligibility(session: TabSession, text: String?) -> Bool {
        guard session.isEmptyFirstSendDestination,
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
    private func modelRouterCanRoutePrimarySession(_ configuration: AgentTaskRouterConfiguration) -> Bool {
        guard let backendID = configuration.selectedBackendID,
              modelRouterRuntime?.isBackendReady(backendID) == true
        else { return false }
        return AgentTaskRoutingCandidateBuilder().hasAvailableTarget(
            allowedProviders: AgentTaskRoutingCandidateBuilder.providers(
                for: .primarySession, configuration: configuration, availability: modelRouterAvailabilityContext, surface: .general
            ),
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
        taskRoutingPolicy.routingCandidateIsCurrent(candidate)
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
        ui.statusPills.update(makeStatusPillsSnapshot())
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
