import Foundation
import RepoPromptAIContracts
import RepoPromptCodexProvider
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptShared

/// The executable composition owns the live scope and provider coordinators. Presentation
/// consumes these same objects; it cannot create a second writer or provider lifecycle.
@MainActor
final class AgentSessionRuntimeHost {
    typealias RunRoutingCleaner = (_ runID: UUID, _ routeID: Int, _ reason: String) async -> Void
    typealias RunToolCanceller = (_ runID: UUID, _ reason: String?) -> Int

    let routeID: Int
    let runRoutingCleaner: RunRoutingCleaner
    let runToolCanceller: RunToolCanceller
    let scope = AgentSessionRuntimeStore.shared.makeScope()
    let codexCoordinator: CodexAgentModeCoordinator
    let claudeCoordinator: ClaudeAgentModeCoordinator
    let providerBindingService: AgentModeProviderBindingService
    let providerResources: AgentRunProviderComposition

    init(
        routeID: Int,
        tools: MCPToolExecutionRuntime,
        workspacePath: @escaping (AgentTabSession) throws -> String?,
        runtimeWorkspacePaths: @escaping (AgentTabSession) throws -> CodexRuntimeWorkspacePaths,
        connectionPolicyInstaller: @escaping AgentRunExecutionContracts.ConnectionPolicyInstaller,
        modelRouterSettingsStore: GlobalSettingsStore,
        catalogDiagnosticsSink: any AgentSessionLinkCatalogEventSink,
        perfRecorder: any AgentModePerfRecording
    ) {
        self.routeID = routeID
        runRoutingCleaner = Self.cleanRunRouting
        runToolCanceller = { tools.cancelActiveToolsForRun(runID: $0, reason: $1) }
        let providerBindingService = AgentModeProviderBindingService()
        self.providerBindingService = providerBindingService
        providerResources = .live()
        codexCoordinator = CodexAgentModeCoordinator(
            windowID: routeID,
            runtimeWorkspacePathsProvider: runtimeWorkspacePaths,
            codexControllerFactory: { runID, tabID, routeID, workspacePaths, permissionProfile, _, computerUseEnabled, capabilities, contextWindowSelection in
                let client = CodexAppServerClient(provisionsRepoPromptMCPOnStart: false)
                let options = CodexNativeSessionController.Options.agentModeDefault(
                    approvalPolicyProvider: { permissionProfile.codexApprovalPolicy },
                    sandboxModeProvider: { permissionProfile.codexSandboxMode },
                    approvalReviewerProvider: { permissionProfile.codexApprovalReviewer },
                    shellToolEnabled: permissionProfile.codexBashToolEnabled(),
                    suppressThirdPartyMCPServers: permissionProfile.codexSuppressesThirdPartyMCPServers,
                    capabilitiesProvider: { capabilities },
                    goalSupportEnabledProvider: { CodexGoalSupport.isEnabled },
                    reasoningSummariesEnabledProvider: { CodexReasoningSummaries.isEnabled },
                    memoriesEnabledProvider: { CodexMemories.isEnabled },
                    computerUseEnabledProvider: { computerUseEnabled },
                    contextWindowSelection: contextWindowSelection
                )
                return CodexNativeSessionController(
                    client: client,
                    runID: runID,
                    tabID: tabID,
                    windowID: routeID,
                    workspacePaths: workspacePaths,
                    options: options,
                    clientShutdownBehavior: .stopOnShutdown,
                    expectedMCPClientName: AgentProviderKind.codexExec.mcpClientNameHint,
                    perfRecorder: perfRecorder
                )
            },
            connectionPolicyInstaller: connectionPolicyInstaller,
            shouldManageCodexTooling: true,
            codexCapabilitiesForLaunch: { isMCPRelated in
                providerBindingService.codexCapabilitiesForLaunch(isMCPRelated: isMCPRelated)
            },
            codexHookApprovalSettings: GlobalSettingsStore.shared,
            activeToolQuery: { runID in tools.hasActiveToolExecutions(runID: runID) },
            activeAgentRunWaitQuery: { runID in tools.hasActiveChildAgentRunWaits(runID: runID) },
            stallWatchdogProbeThreshold: 90,
            stallWatchdogRecoveryThreshold: 300,
            catalogDiagnosticsSink: catalogDiagnosticsSink,
            perfRecorder: perfRecorder,
            initialLastUsedReasoningEffort: CodexAgentToolPreferences.lastUsedReasoningEffort(),
            initialLastUsedReasoningEffortsByModelSlug: CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug()
        )
        claudeCoordinator = ClaudeAgentModeCoordinator(
            windowID: routeID,
            workspacePathProvider: workspacePath,
            awaitNoActiveMCPTools: { runID in try await tools.awaitNoActiveToolExecutions(runID: runID) },
            toolEndedCount: { runID in tools.toolEndedCount(runID: runID) },
            hasActiveMCPTools: { runID in tools.hasActiveToolExecutions(runID: runID) },
            hasActiveChildAgentRunWaits: { runID in tools.hasActiveChildAgentRunWaits(runID: runID) },
            autoEffortConfigurationProvider: { modelRouterSettingsStore.autoEffortConfiguration() }
        )
    }

    func makeClaudeCapabilities(
        links: AgentSessionLinkExecutionRuntime,
        stageRecovery: @escaping @MainActor (AgentTabSession) async -> Bool
    ) -> ClaudeAgentModeCoordinator.HostCapabilities {
        let persistence = scope.persistence
        let handoff = scope.handoff
        var capabilities = ClaudeAgentModeCoordinator.HostCapabilities(
            isSessionCurrent: { [weak scope] session in scope?.sessions[session.tabID] === session },
            requestUIRefresh: { [weak scope] session, urgent in
                guard let scope, scope.sessions[session.tabID] === session else { return }
                session.noteMonitorObservationInputsChanged()
                scope.mcp.handleObservedMCPStateChange(for: session)
                scope.presentation.makeRunHooks().requestUIRefresh(session, urgent)
            },
            scheduleSave: { persistence.scheduleSave(for: $0) },
            stageClaudeResumeRecoveryHandoff: stageRecovery,
            prependPendingHandoff: { handoff.prependPendingHandoffIfNeeded($0, session: $1) },
            qualifyAgentSessionLinkProviderInputRoute: { session, routeWait in
                await links.qualifyProviderInputRoute(for: session, routeWait: routeWait)
            },
            hasCurrentAgentSessionLinkProviderInputRoute: { session, qualification in
                links.agentSessionLinkHasCurrentProviderInputRoute(for: session, qualification: qualification)
            },
            decorateAgentSessionLinkPrompt: { text, session, dispatchID in
                links.agentSessionLinkDecoratedProviderText(text, session: session, dispatchID: dispatchID)
            },
            acquireAgentSessionLinkPhysicalDispatch: { session, dispatchID in
                links.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: dispatchID)
            },
            recordAgentSessionLinkPhysicalDispatchNotAttempted: { session, dispatchID in
                links.agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatchID)
            },
            recordAgentSessionLinkPhysicalDispatchFailure: { session, dispatchID in
                links.agentSessionLinkRecordPhysicalDispatchFailure(for: session, dispatchID: dispatchID)
            },
            proveLocalInput: { session, claim in
                await links.agentSessionLinkProveProviderInput(for: session, claim: claim)
            },
            handoffLocalInput: { session, dispatchID, claim, proof in
                links.agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatchID, claim: claim, proof: proof)
            },
            acceptAgentSessionLinkPromptClaim: { session, context, claim in
                links.acceptAgentSessionLinkDispatch(session: session, context: context, claim: claim)
            }
        )
        capabilities.sessionRuntime = scope
        capabilities.cleanupProviderRun = { [runToolCanceller, runRoutingCleaner, routeID] _, runID in
            let reason = "claudeNative.providerInitiated"
            _ = runToolCanceller(runID, reason)
            await runRoutingCleaner(runID, routeID, reason)
        }
        return capabilities
    }

    nonisolated static func cleanRunRouting(runID: UUID, routeID: Int, reason: String) async {
        _ = reason
        await ServerNetworkManager.shared.unregisterToolObservers(for: runID)
        await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: routeID)
        await AgentRunCoordinator.shared.cleanupRouting(runID: runID)
    }

    func cleanupRunRouting(runID: UUID, reason: String) async {
        _ = runToolCanceller(runID, reason)
        await runRoutingCleaner(runID, routeID, reason)
    }

    func installCodexRuntime(
        _ coordinator: CodexAgentModeCoordinator,
        routeID: Int,
        approvalStore: ApplyEditsApprovalStore,
        links: AgentSessionLinkExecutionRuntime,
        mcpServerEnabler: @escaping AgentRunExecutionContracts.MCPServerEnabler,
        modelRouterSettingsStore: GlobalSettingsStore
    ) {
        let interactions = scope.interactions(routeID: routeID, approvalStore: approvalStore)
        coordinator.installInteractionRuntime(interactions)
        interactions.observer = coordinator
        coordinator.installPersistenceRuntime(scope.persistence)
        coordinator.installAttachmentRuntime(scope.attachments)
        coordinator.installMCPRuntime(scope.mcp)
        coordinator.installUsageRuntime(scope.usage)
        coordinator.installPresentationRuntime(scope.presentation)
        coordinator.installLinkExecutionRuntime(links)
        coordinator.installExecutionServices(
            drafts: scope.drafts, mcpServerEnabler: mcpServerEnabler,
            modelRouterSettingsStore: modelRouterSettingsStore
        )
    }

    func makeExecution(
        dependencies: AgentModeRunService.Dependencies,
        providerInput: AgentModeRunService.ProviderInputAssemblyHooks,
        onTerminalSettled: @escaping @MainActor (AgentTabSession, AgentRunTerminalCommitRevision, AgentRunTerminalPublicationResult, @escaping @MainActor () -> Bool) -> Void,
        prepareLaunch: @escaping @MainActor () -> AgentSessionRunContinuationRuntime.Launch?,
        perfRecorder: any AgentModePerfRecording
    ) -> AgentModeRunService {
        guard let interactions = scope.installedInteractions, let links = scope.linkExecution else {
            preconditionFailure("Compose interaction and link runtimes before run execution")
        }
        let persistence = scope.persistence
        let publication = scope.mcp
        let observation = scope.observation
        let hooks = AgentModeRunService.Hooks(
            usage: scope.usage.makeRunHooks(scheduleSave: { persistence.scheduleSave(for: $0) }),
            attachments: scope.attachments.makeRunHooks(),
            presentation: scope.presentation.makeRunHooks(),
            bindingObservation: publication.makeBindingObservationHooks(),
            queuedWorkRecovery: scope.drafts.makeRunHooks(),
            persistence: persistence.makeRunHooks(),
            transcript: scope.stream.makeRunHooks(),
            providerInput: providerInput,
            interactions: interactions.makeRunHooks(),
            terminalSettlement: .init(
                prepareTerminalPublication: { observation.prepareTerminalPublication(for: $0) },
                makeTerminalPublicationEnvelope: { session, ownership, terminalState, providerRunID, failureReason in
                    publication.makeTerminalPublicationEnvelope(
                        for: session, ownership: ownership, terminalState: terminalState,
                        providerRunID: providerRunID, failureReason: failureReason
                    )
                },
                publishTerminalCommit: { session, revision, successorKind in
                    await links.drainPendingSendEffects(for: session)
                    return await publication.publishTerminalCommit(revision, successorKind: successorKind, for: session)
                },
                onSelfCompactTerminalSettled: onTerminalSettled
            ),
            continuation: scope.continuation.makeRunHooks(prepareLaunch: prepareLaunch),
            prepareForCancellation: { session, intent, origin in
                interactions.prepareRunCancellation(session: session, intent: intent, origin: origin, links: links)
            },
            oracleCancellationDrain: { $0.oracleBackgroundDrain }
        )
        let toolTrackingHooks = scope.stream.makeToolTrackingHooks()
        claudeCoordinator.toolTrackingHooks = toolTrackingHooks
        scope.stream.codexCoordinator = codexCoordinator
        return AgentModeRunService(
            dependencies: dependencies,
            hooks: hooks,
            toolTrackingHooks: toolTrackingHooks,
            perfRecorder: perfRecorder
        )
    }

    #if DEBUG
        /// Existing fixtures keep their injected provider controllers, but use the same scope owner.
        init(
            routeID: Int, codexCoordinator: CodexAgentModeCoordinator, claudeCoordinator: ClaudeAgentModeCoordinator,
            providerResources: AgentRunProviderComposition,
            runRoutingCleaner: @escaping RunRoutingCleaner, runToolCanceller: @escaping RunToolCanceller
        ) {
            self.routeID = routeID
            self.runRoutingCleaner = runRoutingCleaner
            self.runToolCanceller = runToolCanceller
            self.codexCoordinator = codexCoordinator
            self.claudeCoordinator = claudeCoordinator
            self.providerResources = providerResources
            providerBindingService = AgentModeProviderBindingService()
        }
    #endif
}
