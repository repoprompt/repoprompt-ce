import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptSettingsCore

extension AgentSessionRuntimeHost {
    /// Register through the same catalog/dispatch authority used by a physical route. The table
    /// includes canonical definitions even where a tool explicitly requires presentation.
    func registerSavedCatalog(fileReads: MCPFileReadResources, service: MCPService) async throws {
        let route = route
        guard let workspaceID = workspaceActivation?.key.owner.workspaceID,
              await route.ensureRegistered(workspaceID: workspaceID, contextID: nil, revision: 0) != nil else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let history = MCPHistoryToolProvider(workspaceLocations: route.historyWorkspaceLocations)
        let hostTools: Set<String> = [
            MCPWindowToolName.askUser, MCPWindowToolName.manageSelection, MCPWindowToolName.agentSessionLink,
            MCPWindowToolName.agentManage, MCPWindowToolName.manageWorktree, MCPWindowToolName.sessionAdmin
        ]
        let binder = route.makeToolBinder(
            service: service,
            validateInvocation: { invocation, routeID, owner in
                await ServerNetworkManager.shared.validateToolInvocationContext(
                    invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: owner
                )
            }, independentFileReads: fileReads.boundToolNames, independentHostTools: hostTools,
            captureIndependentOrigin: { [weak self] invocation in
                guard let self, let command = savedRoutedCommand(invocation.metadata),
                      let endpoint = scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: command.writer.session.tabID),
                      let runID = command.writer.session.runID, let attemptID = command.writer.session.activeRunAttemptID else { return nil }
                return .init(endpoint: endpoint, runID: runID, runAttemptID: attemptID)
            }, windowExecution: { _, _, _, _ in throw MCPError.invalidRequest("This Agent route has no presenter") }
        )
        let worktrees = MCPWorktreeToolProvider(runtime: binder, canonicalCommand: { [weak self] invocation in
            self?.savedRoutedCommand(invocation.metadata)
        })
        let definitions = try MCPAppToolGroup.orderedToolNames.map { name in
            guard let definition = MCPDomainCanonicalToolDefinitions.definition(named: name) else {
                throw MCPAppToolCatalogMaterializationError.missingCanonicalTools([name])
            }
            return definition
        }
        let bindings = definitions.map { definition in
            fileReads.binding(named: definition.name, route: route) ?? MCPDomainToolBinding(definition: definition) { [weak self] args in
                let invocation = try MCPInvocationContextBridge.require(toolName: definition.name, expectedWindowID: route.identity.routeID)
                switch definition.name {
                case MCPWindowToolName.history:
                    return try await history.execute(args: args)
                case MCPWindowToolName.manageSelection:
                    guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                    return try await executeSavedSelection(args: args, invocation: invocation, lease: fileReads.workspace)
                case MCPWindowToolName.askUser:
                    guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                    return try await executeSavedAskUser(args, invocation: invocation)
                case MCPWindowToolName.agentSessionLink:
                    guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                    return try await executeSavedSessionLink(args, invocation: invocation)
                case MCPWindowToolName.agentManage:
                    guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                    return try await executeSavedAgentManage(args, invocation: invocation)
                case MCPWindowToolName.manageWorktree:
                    return try await Value(worktrees.executeManageWorktree(args: args, invocationContext: invocation))
                case MCPWindowToolName.sessionAdmin:
                    guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                    return try await executeSavedSessionAdmin(args, invocation: invocation)
                default:
                    throw MCPError.invalidRequest("Tool \(definition.name) is not available through this independent Agent route")
                }
            }
        }
        let interactions = DomainLongRunningInteractionAdapter(
            isAvailable: { [weak self] request in
                guard let invocation = try? MCPInvocationContextBridge.require(toolName: MCPWindowToolName.askUser),
                      let connectionID = invocation.connectionID, request.clientID == connectionID else { return false }
                return await self?.savedInteractionCommand(invocation.metadata) != nil
            }, resolveDefaultTimeoutSeconds: { [weak self] request in
                let invocation = try MCPInvocationContextBridge.require(toolName: MCPWindowToolName.askUser)
                guard let connectionID = invocation.connectionID, request.clientID == connectionID,
                      await self?.savedInteractionCommand(invocation.metadata) != nil else {
                    throw MCPError.invalidParams("The originating Agent question owner is unavailable")
                }
                return await Self.savedQuestionTimeout()
            }, cancel: { requestID in
                await MCPAskUserPresentationCoordinator.shared.cancel(requestID: requestID)
            }
        )
        _ = try await route.registerCatalog(MCPAppToolCatalogRegistration(
            windowID: route.identity.routeID, providers: [], sharedBindings: bindings, runtime: binder,
            hostInteractionAdapter: interactions
        ))
    }

    private static func savedQuestionTimeout() -> TimeInterval {
        GlobalSettingsStore.shared.contextBuilderBehaviorSettings().questionTimeoutSeconds
    }

    private func savedRoutedCommand(_ metadata: MCPRequestMetadata) -> AgentSessionRuntimeStore.Command? {
        guard let workspaceID = workspaceActivation?.key.owner.workspaceID,
              let connection = try? route.fileReadConnection(metadata: metadata, workspaceID: workspaceID) else { return nil }
        return savedFileCommand(connection)
    }

    private func savedInteractionCommand(_ metadata: MCPRequestMetadata) async -> AgentSessionRuntimeStore.Command? {
        guard let connectionID = metadata.connectionID, let original = savedRoutedCommand(metadata),
              await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun,
              savedRoutedCommand(metadata)?.identity == original.identity else { return nil }
        return original
    }

    private func executeSavedAskUser(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        guard let command = await savedInteractionCommand(invocation.metadata), let interactions = scope.installedInteractions else {
            throw MCPError.invalidParams("The originating Agent question owner is unavailable")
        }
        let parsed = try MCPAskUserToolProvider.parseAskUserInteraction(
            args: args, defaultTimeout: DomainInteractionPresentationContext.deadline?.originalTimeoutSeconds ?? Self.savedQuestionTimeout()
        )
        let result = try await MCPAskUserToolProvider.withAgentQuestionPresentation(
            requestID: DomainInteractionPresentationContext.requestID
        ) { [weak self] in
            guard let self, await savedInteractionCommand(invocation.metadata)?.identity == command.identity,
                  await ServerNetworkManager.shared.validateToolInvocationContext(
                      invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: ObjectIdentifier(route)
                  ) else { throw MCPFileToolAuthorityFailure.superseded }
            return try await interactions.askUser(command: command, interaction: parsed.interaction)
        }
        return MCPAskUserToolProvider.askUserResponseValue(result, includeLegacyResponse: parsed.includeLegacyResponse)
    }

    private func executeSavedAgentManage(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        guard AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased() == "list_agents" else {
            throw MCPError.invalidRequest("This route supports model discovery through agent_manage list_agents, but cannot manage presentation sessions")
        }
        let rolesOnly: Bool
        if let value = args["roles_only"] {
            guard let parsed = AgentMCPToolHelpers.parseBool(value) else { throw MCPError.invalidParams("roles_only must be a boolean value.") }
            rolesOnly = parsed
        } else { rolesOnly = false }
        guard let command = await savedInteractionCommand(invocation.metadata), let activation = workspaceActivation,
              let availability = activation.modelAvailability else { throw MCPFileToolAuthorityFailure.superseded }
        let rootIDs = try await activation.loadedRootIDs(for: command, route: route)
        let captured = try await captureStartupResources(for: command, rootIDs: rootIDs)
        let workspaceID = command.identity.workspaceID
        let root = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: command.writer.session.worktreeBindings, fallbackWorkspacePath: captured.workspacePaths.first
        )
        let reply = try await AgentManageMCPToolService.listAgents(
            availability: availability, workspaceID: workspaceID, openCodeWorkspacePath: root,
            rolesOnly: rolesOnly, restrictedDiscovery: GlobalSettingsStore.shared.effectiveAgentModelsProfile(workspaceID: workspaceID).restrictMCPAgentDiscoveryToRoleLabels
        )
        guard await captured.validate(), await savedInteractionCommand(invocation.metadata)?.identity == command.identity else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        return reply
    }

    private func executeSavedSessionAdmin(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        let bridge = AgentSessionLinkRuntimeBridge.shared
        return try await SessionAdminMCPToolService(
            captureRequestMetadata: { invocation.metadata },
            requireTargetWindow: { throw SessionAdminMCPToolService.unavailableError },
            resolveObserverEndpoint: { _, _ in nil }, scopes: { bridge.delegationScopes },
            administration: { bridge.sessionAdministrationFrontDoor },
            resolveCanonicalObserverEndpoint: { [weak self] metadata in
                guard let self, let command = await savedInteractionCommand(metadata) else { return nil }
                return scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: command.writer.session.tabID)
            }
        ).execute(args: args)
    }

    private func executeSavedSessionLink(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        let resolve: (MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity? = { [weak self] metadata in
            guard let self, let command = await savedInteractionCommand(metadata) else { return nil }
            return scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: command.writer.session.tabID)
        }
        return try await AgentSessionLinkMCPToolService(
            toolName: MCPWindowToolName.agentSessionLink, captureRequestMetadata: { invocation.metadata },
            requireTargetWindow: { throw MCPError.invalidRequest("This Agent route has no presenter") },
            resolveObserverEndpoint: { _, _ in nil }, withHeartbeat: { _, _, _, _, operation in try await operation() },
            resolveCanonicalObserverEndpoint: resolve, resolveModelObserverEndpoint: resolve
        ).execute(args: args)
    }
}
