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
    enum RunRoutingCleanup {
        case registered([MCPRunRoutingCleanupReceipt])
        /// Compatibility adapter only; an independent host may never construct this fallback.
        case legacyWindow(runID: UUID)
    }

    typealias RunRoutingCleaner = (_ cleanup: RunRoutingCleanup, _ routeID: Int, _ reason: String) async -> Void
    typealias RunToolCanceller = (_ runID: UUID, _ reason: String?) -> Int
    typealias CodexAgentRunWaitDrain = @MainActor (
        _ runID: UUID, _ runAttemptID: UUID?, _ source: String, _ steeringMessage: String?
    ) async -> Bool
    nonisolated static let childAgentRunWaitDrainTimeoutSeconds: TimeInterval = 2.0

    let route: MCPHostRouteResources
    var routeID: Int {
        route.identity.routeID
    }

    let runRoutingCleaner: RunRoutingCleaner
    let runToolCanceller: RunToolCanceller
    let scope = AgentSessionRuntimeStore.shared.makeScope()
    let codexCoordinator: CodexAgentModeCoordinator
    let claudeCoordinator: ClaudeAgentModeCoordinator
    let providerBindingService: AgentModeProviderBindingService
    let providerResources: AgentRunProviderComposition
    private(set) var workspaceActivation: AgentSessionHostWorkspaceActivation?

    /// Install immutable activation/resource ownership before making any visible session. A
    /// later activation must compose another host; it cannot retarget this host's old requests.
    func installWorkspaceActivation(
        _ activation: AgentSessionHostWorkspaceActivation,
        attachmentWorkspaceDirectory: URL, suppressesAttachmentPersistence: Bool
    ) async throws {
        guard workspaceActivation == nil, scope.sessions.isEmpty, scope.attachments.configuration == nil,
              activation.isPresenterCurrent, activation.authority.windowID == routeID, !route.isClosing,
              let workspaceID = activation.key.owner.workspaceID
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let storage = AgentSessionPersistenceRuntime.CanonicalStorage(workspaceID: workspaceID) { id in
            guard let snapshot = await activation.authority.canonicalWorkspaceSnapshot(id), snapshot.health != .removed,
                  let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes),
                  workspace.id == id else { return nil }
            return workspace
        }
        let attachments = try await AgentSessionStorageInputs.canonicalAttachmentConfiguration(
            storage: storage, workspaceDirectory: attachmentWorkspaceDirectory,
            isSuppressed: suppressesAttachmentPersistence,
            resourcesAreCurrent: { [route] in activation.isCurrent && !route.isClosing }
        )
        try Task.checkCancellation()
        guard workspaceActivation == nil, scope.sessions.isEmpty, scope.attachments.configuration == nil,
              activation.isPresenterCurrent, !route.isClosing
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        workspaceActivation = activation
        do {
            try activation.bind(to: self)
        } catch {
            workspaceActivation = nil
            throw error
        }
        scope.attachments.configuration = attachments
        installCanonicalContinuationLauncher()
    }

    func captureStartupResources(
        for command: AgentSessionRuntimeStore.Command, rootIDs: [UUID]
    ) async throws -> AgentSessionHostStartupResources {
        try command.requireCurrent()
        guard command.writer.scope === scope, let activation = workspaceActivation,
              activation.isCurrent, !route.isClosing
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let captured = try await activation.capture(command: command, rootIDs: rootIDs, route: route)
        try Task.checkCancellation()
        try command.requireCurrent()
        guard activation.isCurrent, !route.isClosing else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        return captured
    }

    /// Lifetime policy stays with the caller. This composes explicit resource release onto the
    /// existing exact drain, never onto presentation detach or Stop.
    func beginRetirement(adapters: AgentSessionHostDrainRuntime.Adapters) -> AgentSessionHostDrainRuntime {
        AgentSessionHostDrainRuntime.begin(scope: scope, owner: self, adapters: adapters, releaseResources: { [self] in
            await route.close()
            await workspaceActivation?.release()
        })
    }

    /// The legacy launch projection is shared by the app composition root and injected fixtures.
    /// Canonical request-local launch inputs replace its fallback at executable-host activation.
    static func makeSessionWorkspaceProviders(
        fallbackWorkspacePath: @escaping () -> String?
    ) -> (
        sessionWorkspacePath: (AgentTabSession) throws -> String?,
        codexRuntimeWorkspacePaths: (AgentTabSession) throws -> CodexRuntimeWorkspacePaths
    ) {
        (
            sessionWorkspacePath: { session in
                try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                    bindings: session.worktreeBindings, fallbackWorkspacePath: fallbackWorkspacePath()
                )
            },
            codexRuntimeWorkspacePaths: { session in
                try AgentWorktreeRuntimeWorkspaceResolver.codexRuntimeWorkspacePaths(
                    bindings: session.worktreeBindings, fallbackWorkspacePath: fallbackWorkspacePath()
                )
            }
        )
    }

    nonisolated static func defaultConnectionPolicyInstaller(
        clientName: String, windowID: Int, restrictedTools: Set<String>, oneShot: Bool,
        reason: String?, ttl: TimeInterval, tabID: UUID?, runID: UUID?, additionalTools: Set<String>?,
        purpose: MCPRunPurpose, taskLabelKind: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false, requiresExpectedAgentPID: Bool = false
    ) async {
        await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: clientName, windowID: windowID, restrictedTools: restrictedTools, oneShot: oneShot,
            reason: reason, ttl: ttl, tabID: tabID, runID: runID, additionalTools: additionalTools,
            purpose: purpose, taskLabelKind: taskLabelKind,
            allowsAgentExternalControlTools: allowsAgentExternalControlTools,
            requiresExpectedAgentPID: requiresExpectedAgentPID
        )
    }

    init(
        route: MCPHostRouteResources,
        workspacePath: @escaping (AgentTabSession) throws -> String?,
        runtimeWorkspacePaths: @escaping (AgentTabSession) throws -> CodexRuntimeWorkspacePaths,
        connectionPolicyInstaller: @escaping AgentRunExecutionContracts.ConnectionPolicyInstaller,
        modelRouterSettingsStore: GlobalSettingsStore,
        catalogDiagnosticsSink: any AgentSessionLinkCatalogEventSink,
        perfRecorder: any AgentModePerfRecording
    ) {
        self.route = route
        let routeID = route.identity.routeID
        let tools = route.toolExecutionRuntime
        runRoutingCleaner = Self.cleanRunRouting
        runToolCanceller = { tools.cancelActiveToolsForRun(runID: $0, reason: $1) }
        let providerBindingService = AgentModeProviderBindingService()
        self.providerBindingService = providerBindingService
        providerResources = .live()
        codexCoordinator = CodexAgentModeCoordinator(
            windowID: routeID,
            routingOwner: route.identity.kind == .independent ? route : nil,
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
        scope.installExecutableHost(self)
        codexCoordinator.setActiveAgentRunWaitDrain(makeChildAgentRunWaitDrain())
    }

    /// Retain the execution owner, not its presenter. A missing presentation is neither a
    /// drained child wait nor authority to attribute steering to a replacement run attempt.
    func makeChildAgentRunWaitDrain(timeoutSeconds: TimeInterval = childAgentRunWaitDrainTimeoutSeconds) -> CodexAgentRunWaitDrain {
        { [weak scope, tools = route.toolExecutionRuntime] runID, runAttemptID, source, steeringMessage in
            // A coordinator belongs to scope.execution. Retain scope only while this drain
            // actually runs, rather than forming an installed coordinator/execution cycle.
            let scope = scope
            return await tools.wakeAndDrainAgentRunWaitersOwnedByActiveRun(
                runID: runID, source: source, steeringMessage: steeringMessage,
                timeoutSeconds: timeoutSeconds,
                steeringOriginRunID: {
                    guard scope?.sessions.values.contains(where: {
                        $0.runID == runID && $0.activeRunAttemptID == runAttemptID && $0.runState.isActive
                    }) == true else { return nil }
                    return runID
                },
                publicationForSessionID: { scope?.mcp.waitPublication(sessionID: $0) }
            )
        }
    }

    func makeClaudeCapabilities(
        links: AgentSessionLinkExecutionRuntime,
        inputEnvironmentForSession: @escaping @MainActor (AgentTabSession) -> AgentSessionLinkExecutionRuntime.ManagedInputEnvironment,
        sessionTitle: @escaping @MainActor (AgentTabSession) -> String
    ) -> ClaudeAgentModeCoordinator.HostCapabilities {
        let inputEnvironmentForSession = workspaceActivation == nil ? inputEnvironmentForSession : makeCanonicalInputEnvironment()
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
            stageClaudeResumeRecoveryHandoff: { session in
                await links.prepareResumeRecoveryHandoff(
                    for: session, sourceTitle: sessionTitle(session), environment: inputEnvironmentForSession(session)
                ).permitsFreshSession
            },
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
        capabilities.legacyRunRoutingCleanup = { [route] runID in
            route.identity.kind == .independent ? nil : .legacyWindow(runID: runID)
        }
        capabilities.cleanupProviderRun = { [route, runToolCanceller, runRoutingCleaner] cleanup in
            await Self.performRunRoutingCleanup(
                cleanup, route: route, reason: "claudeNative.providerInitiated",
                cancelLegacyTools: runToolCanceller, cleaner: runRoutingCleaner
            )
        }
        return capabilities
    }

    nonisolated static func cleanRunRouting(_ cleanup: RunRoutingCleanup, routeID: Int, reason: String) async {
        _ = reason
        switch cleanup {
        case let .registered(receipts):
            for receipt in receipts {
                await ServerNetworkManager.shared.cleanupRunRoutingState(ownedBy: receipt)
            }
        case let .legacyWindow(runID):
            await ServerNetworkManager.shared.cleanupRunRoutingState(for: runID, windowID: routeID, includingObserversAndWaiter: true)
        }
    }

    private static func performRunRoutingCleanup(
        _ cleanup: RunRoutingCleanup, route: MCPHostRouteResources, reason: String,
        cancelLegacyTools: RunToolCanceller, cleaner: RunRoutingCleaner
    ) async {
        switch cleanup {
        case let .registered(receipts):
            precondition(!receipts.isEmpty && receipts.allSatisfy { $0.routeOwner === route }, "Cleanup must retain this exact route's registrations")
        case let .legacyWindow(runID):
            precondition(route.identity.kind != .independent, "Independent routing requires originating cleanup receipts")
            _ = cancelLegacyTools(runID, reason)
        }
        await cleaner(cleanup, route.identity.routeID, reason)
    }

    func cleanupRunRouting(_ cleanup: RunRoutingCleanup, reason: String) async {
        await Self.performRunRoutingCleanup(cleanup, route: route, reason: reason, cancelLegacyTools: runToolCanceller, cleaner: runRoutingCleaner)
    }

    /// Bound/restored startup only. Fresh allocation and cold hydration keep their existing
    /// preparation owners; this path never obtains either authority from a presentation.
    func makeStartupEnvironment(resources: AgentSessionHostStartupResources) throws -> AgentSessionRunStartRuntime.Environment {
        guard resources.origin.writer.scope === scope, resources.isCurrent,
              let execution = scope.execution, let links = scope.linkExecution, links.routeID == routeID
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let composition = AgentModeRunComposition(execution: execution, resources: providerResources, workspace: resources.workspace)
        return .init(
            currentWorkspaceID: { resources.context.workspaceID },
            prepareSession: { _ in }, // Already-restored command required by resource construction and every admission.
            availabilityFailure: resources.availabilityFailure,
            bindSession: { session in
                guard resources.origin.writer.session === session, resources.isCurrent else { return nil }
                return .init(sessionID: resources.origin.writer.identity.sessionID, creation: nil)
            },
            providerSwitchRefusal: { AgentSessionLinkExecutionRuntime.providerSwitchStartRefusal($0).message },
            input: links.commands.input,
            workspacePaths: { resources.workspacePaths },
            inputWorkspace: resources.inputWorkspace,
            initialThreadInput: resources.initialThreadInput,
            composition: { composition }, hostResources: resources
        )
    }

    func makeStartupLaunch(resources: AgentSessionHostStartupResources) throws -> AgentSessionRunContinuationRuntime.Launch {
        let environment = try makeStartupEnvironment(resources: resources)
        guard let links = scope.linkExecution else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        return .init { [startup = scope.startup, claudeCoordinator] session, instruction, outcome in
            _ = await startup.start(
                session: session, initialMessage: instruction.providerText,
                directStartOptions: .init(skipsSlashExpansion: instruction.skipsSlashExpansion, stopFence: instruction.stopFence),
                startOutcome: outcome, claudeCoordinator: claudeCoordinator, links: links, environment: environment
            )
        }
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
        inputEnvironmentForSession: @escaping @MainActor (AgentTabSession) -> AgentSessionLinkExecutionRuntime.ManagedInputEnvironment,
        sessionTitle: @escaping @MainActor (AgentTabSession) -> String,
        providerSwitchGenerationSettled: @escaping @MainActor (AgentTabSession) -> Void = { _ in },
        prepareLaunch: @escaping @MainActor () -> AgentSessionRunContinuationRuntime.Launch?,
        perfRecorder: any AgentModePerfRecording
    ) -> AgentModeRunService {
        let inputEnvironmentForSession = workspaceActivation == nil ? inputEnvironmentForSession : makeCanonicalInputEnvironment()
        guard let interactions = scope.installedInteractions, let links = scope.linkExecution else {
            preconditionFailure("Compose interaction and link runtimes before run execution")
        }
        links.codexCoordinator = codexCoordinator
        links.activeMCPToolProbe = { [tools = route.toolExecutionRuntime] in tools.hasActiveToolExecutions(runID: $0) }
        let persistence = scope.persistence
        let publication = scope.mcp
        let observation = scope.observation
        let prepareContinuation: @MainActor (AgentTabSession) -> AgentSessionRunContinuationRuntime.Launch? = if workspaceActivation != nil {
            { [weak self] in self?.makeCanonicalContinuationLaunch(for: $0) }
        } else {
            { _ in prepareLaunch() }
        }
        let hooks = AgentModeRunService.Hooks(
            usage: scope.usage.makeRunHooks(scheduleSave: { persistence.scheduleSave(for: $0) }),
            attachments: scope.attachments.makeRunHooks(),
            presentation: scope.presentation.makeRunHooks(),
            bindingObservation: publication.makeBindingObservationHooks(),
            queuedWorkRecovery: scope.drafts.makeRunHooks(),
            persistence: persistence.makeRunHooks(),
            transcript: scope.stream.makeRunHooks(),
            providerInput: links.makeProviderInputHooks(environmentForSession: inputEnvironmentForSession, sessionTitle: sessionTitle),
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
                onSelfCompactTerminalSettled: { [worktrees = scope.worktrees] session, revision, result, teardownSettled in
                    links.agentSelfCompactTerminalSettled(
                        session: session, revision: revision, publication: result, teardownSettled: teardownSettled
                    )
                    links.providerSwitchRunSettled(session, revision: revision, publication: result)
                    providerSwitchGenerationSettled(session)
                    worktrees.selfWorktreeRelocationTerminalSettled(
                        session: session, revision: revision, publication: result, teardownSettled: teardownSettled
                    )
                }
            ),
            continuation: scope.continuation.makeRunHooks(prepareSessionLaunch: prepareContinuation),
            prepareForCancellation: { session, intent, origin in
                interactions.prepareRunCancellation(session: session, intent: intent, origin: origin, links: links)
            },
            oracleCancellationDrain: { $0.oracleBackgroundDrain }
        )
        let toolTrackingHooks = scope.stream.makeToolTrackingHooks()
        claudeCoordinator.toolTrackingHooks = toolTrackingHooks
        scope.stream.codexCoordinator = codexCoordinator
        precondition(dependencies.windowID == routeID, "Execution must use the composed host route")
        var dependencies = dependencies
        dependencies.routingOwner = route.identity.kind == .independent ? route : nil
        let execution = AgentModeRunService(
            dependencies: dependencies,
            hooks: hooks,
            toolTrackingHooks: toolTrackingHooks,
            perfRecorder: perfRecorder
        )
        installWorktreeEffects(
            execution: execution, links: links, interactions: interactions,
            environment: inputEnvironmentForSession, sessionTitle: sessionTitle
        )
        installCanonicalContinuationLauncher()
        return execution
    }

    #if DEBUG
        /// Existing fixtures keep their injected provider controllers, but use the same scope owner.
        init(
            route: MCPHostRouteResources,
            codexCoordinator: CodexAgentModeCoordinator, claudeCoordinator: ClaudeAgentModeCoordinator,
            providerResources: AgentRunProviderComposition,
            runRoutingCleaner: @escaping RunRoutingCleaner, runToolCanceller: @escaping RunToolCanceller,
            activeAgentRunWaitDrain: CodexAgentRunWaitDrain? = nil
        ) {
            self.route = route
            self.runRoutingCleaner = runRoutingCleaner
            self.runToolCanceller = runToolCanceller
            self.codexCoordinator = codexCoordinator
            self.claudeCoordinator = claudeCoordinator
            self.providerResources = providerResources
            providerBindingService = AgentModeProviderBindingService()
            scope.installExecutableHost(self)
            codexCoordinator.setActiveAgentRunWaitDrain(activeAgentRunWaitDrain ?? makeChildAgentRunWaitDrain())
        }
    #endif
}
