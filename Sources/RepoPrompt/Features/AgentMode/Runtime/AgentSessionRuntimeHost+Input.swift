import Foundation
import RepoPromptInstrumentation
import RepoPromptSettingsCore

extension AgentSessionRuntimeHost {
    /// Input may be captured by the originating creation command before its first save. This
    /// does not authorize startup, which still requires restored admission and its own resources.
    func captureCanonicalInput(
        session: AgentTabSession, command: AgentSessionRuntimeStore.Command?
    ) async throws -> AgentSessionProviderInputRuntime.InitialThreadInput {
        guard let command, command.writer.scope === scope, command.writer.session === session,
              let activation = workspaceActivation, activation.isCurrent, !route.isClosing
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        try command.requireCurrent()
        let rootIDs = try await activation.loadedRootIDs(for: command, route: route)
        try command.requireCurrent()
        guard activation.isCurrent, !route.isClosing else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let input = try await activation.captureInput(command: command, rootIDs: rootIDs, route: route)
        try command.requireCurrent()
        guard input.workspace.isCurrent() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        return input
    }

    /// Compose the actual link/input/start owners before adding any sessions. No required command
    /// calls a presenter; attachment later consumes the already-installed scope runtime.
    @discardableResult
    func installCanonicalLinkExecution(
        skillCatalog: AgentSkillCatalog, perfRecorder: any AgentModePerfRecording,
        diagnostics: any AgentSessionLinkCatalogEventSink
    ) throws -> AgentSessionLinkExecutionRuntime {
        guard let activation = workspaceActivation, activation.isCurrent, !route.isClosing,
              scope.sessions.isEmpty, scope.linkExecution == nil
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let input = scope.providerInput(skillCatalog: skillCatalog, perfRecorder: perfRecorder)
        let runtime = scope.makeLinkExecution(routeID: routeID, commands: .init(
            isAvailable: { [route] in activation.isCurrent && !route.isClosing },
            modelAvailability: { activation.modelAvailability },
            workspaceID: { [weak scope] session in
                guard scope?.sessions[session.tabID] === session, activation.isCurrent else { return nil }
                return activation.key.owner.workspaceID
            },
            input: input,
            // Canonical WorkspaceSource supplies request-local roots, including slash-skill input.
            // This compatibility projection is never used to resolve a canonical workspace.
            workspacePaths: { [] },
            inputWorkspace: { [weak self] session, command in
                guard let self else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
                return try await captureCanonicalInput(session: session, command: command).workspace
            },
            initialThreadInput: { [weak self] session, command in
                guard let self else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
                return try await captureCanonicalInput(session: session, command: command)
            },
            modelDisplayName: { session in
                guard let availability = activation.modelAvailability else { return session.selectedModelRaw }
                return AgentModelCatalog.displayName(
                    for: session.selectedModelRaw, agentKind: session.selectedAgent,
                    availability: availability, includeEffortSuffix: false
                )
            },
            start: { [weak self] command, text, options, outcome, preparation in
                guard let self else {
                    outcome?.recordStartFailure(message: "The originating execution host is unavailable.")
                    return nil
                }
                return await startCanonicalRequest(
                    command: command, message: text, options: options, outcome: outcome,
                    providerSwitchPreparation: preparation
                )
            },
            settleSelfCompact: { [weak scope] session in scope?.linkExecution?.agentSelfCompactSettleStaleParkedNote(session) },
            selfCompactBlocksWake: { [weak scope] session in scope?.linkExecution?.agentSelfCompactBlocksNotificationWake(session) ?? true },
            selfCompactHoldsWakeAcquisition: { [weak scope] session in scope?.linkExecution?.agentSelfCompactHoldsWakeAcquisition(session) ?? true },
            workspaceCaptureOrder: .beforeSkillExpansion
        ), diagnostics: diagnostics)
        runtime.codexCoordinator = codexCoordinator
        runtime.perfRecorder = perfRecorder
        runtime.activeMCPToolProbe = { [tools = route.toolExecutionRuntime] in tools.hasActiveToolExecutions(runID: $0) }
        installCanonicalContinuationLauncher()
        return runtime
    }

    func makeCanonicalInputEnvironment() -> @MainActor (AgentTabSession) -> AgentSessionLinkExecutionRuntime.ManagedInputEnvironment {
        { [weak self, tools = route.toolExecutionRuntime] session in
            guard let self else {
                return .init(workspaceID: nil, resourcesAreCurrent: { false }, settings: .shared, tools: tools)
            }
            return canonicalInputEnvironment(for: session)
        }
    }

    func canonicalInputEnvironment(for session: AgentTabSession) -> AgentSessionLinkExecutionRuntime.ManagedInputEnvironment {
        .init(
            workspaceID: workspaceActivation?.key.owner.workspaceID,
            resourcesAreCurrent: { [weak self] in
                guard let self else { return false }
                return workspaceActivation?.isCurrent == true && !route.isClosing && scope.sessions[session.tabID] === session
            }, settings: .shared, tools: route.toolExecutionRuntime,
            validateResources: { [weak self] command in
                guard let self else { return false }
                do {
                    let input = try await captureCanonicalInput(session: session, command: command)
                    return await input.workspace.validate()
                } catch { return false }
            },
            captureProviderLaunchInput: { [weak self] command in
                guard let self, command.writer.session === session, let activation = workspaceActivation else {
                    throw AgentHostWorkspaceResources.Failure.authorityUnavailable
                }
                let rootIDs = try await activation.loadedRootIDs(for: command, route: route)
                let resources = try await captureStartupResources(for: command, rootIDs: rootIDs)
                return try await resources.captureProviderLaunchInput(for: command)
            }
        )
    }
}
