import Foundation

extension AgentModeViewModel {
    @MainActor
    final class RepromptSpeculation {
        typealias Reuse = AgentAutomationTurnAudit.Reprompt.Speculation
        let requestID: UUID
        let text: String
        let routerConfiguration: AgentTaskRouterConfiguration
        let effortConfiguration: AutoEffortConfiguration
        let metadata: RoutingExecutionMetadataSnapshot
        let roleDefaults: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference]
        let usageRevision: UInt64
        let target: AgentRoutingExecutableTarget
        let workflow: AgentWorkflowDefinition?
        let workflowGeneration: UInt64
        var routingTask: Task<StagedTaskRoutingResult, Never>?
        var effortTask: Task<(selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature), Never>?
        var reuse: Reuse = .none
        var balanceIsCurrent: (() -> Bool)?

        init(
            operationID: UUID, text: String, routerConfiguration: AgentTaskRouterConfiguration,
            effortConfiguration: AutoEffortConfiguration, metadata: RoutingExecutionMetadataSnapshot,
            roleDefaults: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference], usageRevision: UInt64,
            target: AgentRoutingExecutableTarget, workflow: AgentWorkflowDefinition?, workflowGeneration: UInt64
        ) {
            requestID = StableUserInteractionIdentity.uuid(from: "reprompt-spec-\(operationID.uuidString)")
            self.text = text
            self.routerConfiguration = routerConfiguration
            self.effortConfiguration = effortConfiguration
            self.metadata = metadata
            self.roleDefaults = roleDefaults
            self.usageRevision = usageRevision
            self.target = target
            self.workflow = workflow
            self.workflowGeneration = workflowGeneration
        }

        func matchesText(_ approved: String) -> Bool {
            // Swift String equality is Unicode-canonical equality, not byte identity.
            text.utf8.elementsEqual(approved.utf8)
        }

        func cancel(runtime: AgentTaskRouterRuntime?) {
            routingTask?.cancel()
            effortTask?.cancel()
            if let runtime {
                Task { await runtime.coordinator.cancel(requestID: requestID) }
            }
        }
    }

    func startRepromptSpeculation(session: TabSession, operationID: UUID, text: String, originalText: String) {
        cancelRepromptSpeculation(claimID: operationID)
        guard let runtime = modelRouterRuntime, sessions[session.tabID] === session else { return }
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let allowed = providers(for: .primarySession, configuration: configuration)
        let routesFresh = configuration.enabled && configuration.validity == .valid
            && configuration.selectedBackendID.map { runtime.isBackendReady($0) } == true
            && freshTaskRoutingEligibility(session: session, text: text)
        let metadata = AgentTaskRoutingCandidateBuilder().capture(allowedProviders: routesFresh ? allowed : [session.selectedAgent], availability: modelRouterAvailabilityContext)
        let roles = agentModelRoleDefaultReferences()
        let speculation = RepromptSpeculation(
            operationID: operationID, text: text, routerConfiguration: configuration,
            effortConfiguration: modelRouterSettingsStore.autoEffortConfiguration(), metadata: metadata,
            roleDefaults: roles, usageRevision: runtime.usageBalancer?.revision ?? 0,
            target: executableTarget(for: session), workflow: session.selectedWorkflow,
            workflowGeneration: session.userWorkflowSelectionMutationGeneration
        )
        if routesFresh, let backendID = configuration.selectedBackendID {
            speculation.routingTask = Task {
                await routeModelThenEffort(
                    requestID: speculation.requestID, text: text, scope: .primarySession, surface: .general,
                    providers: allowed, configuration: configuration, backendID: backendID, runtime: runtime,
                    capturedSnapshot: metadata, capturedRoleDefaults: roles,
                    balanceObserver: { [weak speculation, weak runtime] original, candidates, balanced in
                        speculation?.balanceIsCurrent = { [weak runtime] in
                            let live = runtime?.usageBalancer?.choose(selected: original, candidates: candidates, evidence: nil, configuration: configuration).candidate.target ?? original.target
                            return live == balanced
                        }
                    }
                )
            }
        } else if speculation.effortConfiguration.enabled, !session.runState.isActive,
                  let effortBackend = speculation.effortConfiguration.selectedBackendID, runtime.isBackendReady(effortBackend)
        {
            speculation.effortTask = Task {
                await chooseAutoEffortForUserTurn(
                    text: Self.automationJudgingText(original: originalText, reprompted: text),
                    session: session, workflow: session.selectedWorkflow,
                    requestID: speculation.requestID, isSpeculative: true, isRepromptReplacement: true
                )
            }
        } else {
            return
        }
        repromptSpeculations[operationID] = speculation
    }

    func reusableRepromptRouting(
        _ speculation: RepromptSpeculation?, approved: String?, configuration: AgentTaskRouterConfiguration,
        backendID: DecisionServiceID, runtime: AgentTaskRouterRuntime
    ) -> RepromptSpeculation? {
        guard let speculation, let approved, speculation.routingTask != nil else { return nil }
        guard speculation.matchesText(approved) else {
            speculation.reuse = .discardedEdited
            speculation.cancel(runtime: runtime)
            return nil
        }
        let liveMetadata = AgentTaskRoutingCandidateBuilder().capture(
            allowedProviders: providers(for: .primarySession, configuration: configuration), availability: modelRouterAvailabilityContext
        )
        guard runtime.isBackendReady(backendID),
              configuration.revision == speculation.routerConfiguration.revision,
              backendID == speculation.routerConfiguration.selectedBackendID,
              liveMetadata == speculation.metadata,
              agentModelRoleDefaultReferences() == speculation.roleDefaults,
              (runtime.usageBalancer?.revision ?? 0) == speculation.usageRevision,
              speculation.balanceIsCurrent?() != false
        else {
            speculation.reuse = .discardedStale
            speculation.cancel(runtime: runtime)
            return nil
        }
        speculation.reuse = .reused
        return speculation
    }

    func reusableRepromptEffort(claim: AgentComposerSubmitClaim, approved: String?, session: TabSession) -> RepromptSpeculation? {
        guard let speculation = repromptSpeculations[claim.attempt.id], let approved, speculation.effortTask != nil else { return nil }
        guard speculation.matchesText(approved) else {
            speculation.reuse = .discardedEdited
            speculation.cancel(runtime: modelRouterRuntime)
            return nil
        }
        let liveMetadata = AgentTaskRoutingCandidateBuilder().capture(allowedProviders: [session.selectedAgent], availability: modelRouterAvailabilityContext)
        let backendReady = speculation.effortConfiguration.selectedBackendID.map { modelRouterRuntime?.isBackendReady($0) == true } == true
        guard liveMetadata == speculation.metadata,
              backendReady,
              modelRouterSettingsStore.autoEffortConfiguration() == speculation.effortConfiguration,
              executableTarget(for: session) == speculation.target,
              session.selectedWorkflow == speculation.workflow,
              session !== claim.sourceSession || session.userWorkflowSelectionMutationGeneration == speculation.workflowGeneration,
              (modelRouterRuntime?.usageBalancer?.revision ?? 0) == speculation.usageRevision,
              !session.runState.isActive
        else {
            speculation.reuse = .discardedStale
            speculation.cancel(runtime: modelRouterRuntime)
            return nil
        }
        speculation.reuse = .reused
        return speculation
    }

    func repromptAuditForClaim(_ claim: AgentComposerSubmitClaim, judgedText: AgentAutomationTurnAudit.Reprompt.JudgedText? = nil) -> AgentAutomationTurnAudit.Reprompt? {
        guard var audit = repromptAudits[claim.attempt.id] else { return nil }
        audit.automationJudgedText = judgedText
        audit.routerSpeculation = repromptSpeculations[claim.attempt.id]?.reuse ?? .none
        return audit
    }

    func cancelRepromptSpeculation(claimID: UUID) {
        repromptSpeculations.removeValue(forKey: claimID)?.cancel(runtime: modelRouterRuntime)
    }
}
