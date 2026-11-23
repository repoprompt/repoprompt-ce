import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptSettingsCore

extension AgentSessionRuntimeHost {
    /// Install the route's catalog independently of session startup. An activation contributes
    /// its exact root lease; two activations sharing a route can reuse the same catalog, never
    /// each other's lease or run adapter.
    func registerHostCatalog(service: MCPService) async throws {
        guard let activation = workspaceActivation, activation.owns(scope: scope, route: route),
              let workspaceID = activation.key.owner.workspaceID, activation.catalogFileLease?.rootsAreCurrent == true
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        try await route.registerHostCapabilities(service: service, workspaceID: workspaceID)
        guard activation.owns(scope: scope, route: route), !Task.isCancelled else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
    }
}

extension MCPHostRouteResources {
    struct HostInvocation {
        let host: AgentSessionRuntimeHost
        let command: AgentSessionRuntimeStore.Command
    }

    /// A connection's immutable writer receipt, not the presentation or a tab-only lookup,
    /// identifies the activation. A same-ID replacement cannot use the old registration.
    func canonicalHostInvocation(_ metadata: MCPRequestMetadata) -> HostInvocation? {
        guard let (host, connection) = canonicalHostConnection(metadata),
              let command = host.hostFileCommand(connection) else { return nil }
        return .init(host: host, command: command)
    }

    private func canonicalHostConnection(_ metadata: MCPRequestMetadata) -> (AgentSessionRuntimeHost, FileReadConnection)? {
        guard identity.kind == .independent, let connection = try? fileReadConnection(metadata: metadata),
              let original = connection.writerAtBinding,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
                  sessionID: original.sessionID, expectedWorkspaceID: original.workspaceID
              ), writer.identity == original,
              let host = writer.scope.executableHost, host.route === self
        else { return nil }
        return (host, connection)
    }

    fileprivate func registerHostCapabilities(service: MCPService, workspaceID: UUID) async throws {
        guard identity.kind == .independent,
              await ensureRegistered(workspaceID: workspaceID, contextID: nil, revision: 0) != nil
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        if usesHostCapabilities, await hasActiveCatalog() {
            guard hasHostTransport(service) else { throw RegistrationFailure.differentCatalog }
            return
        }
        let history = MCPHistoryToolProvider(workspaceLocations: historyWorkspaceLocations)
        let hostTools: Set<String> = [
            MCPWindowToolName.askUser, MCPWindowToolName.manageSelection, MCPWindowToolName.agentSessionLink,
            MCPWindowToolName.agentManage, MCPWindowToolName.manageWorktree, MCPWindowToolName.sessionAdmin,
            MCPWindowToolName.becomeOverseer, MCPWindowToolName.applyEdits, MCPWindowToolName.git,
            MCPWindowToolName.agentSelf, MCPWindowToolName.selfNoop
        ]
        let fileTools = MCPFileReadResources.contentToolNames.union(MCPFileReadResources.toolNames)
        let binder = makeToolBinder(
            service: service,
            validateInvocation: { invocation, routeID, owner in
                await ServerNetworkManager.shared.validateToolInvocationContext(
                    invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: owner
                )
            }, independentFileReads: fileTools, independentHostTools: hostTools,
            captureIndependentOrigin: { [weak self] invocation in
                guard let origin = self?.canonicalHostInvocation(invocation.metadata) else { return nil }
                let session = origin.command.writer.session
                guard let endpoint = origin.host.scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: session.tabID),
                      let runID = session.runID, let attemptID = session.activeRunAttemptID else { return nil }
                return .init(endpoint: endpoint, runID: runID, runAttemptID: attemptID)
            }, windowExecution: { _, _, _, _ in throw MCPError.invalidRequest("This Agent route has no presenter") }
        )
        let worktrees = MCPWorktreeToolProvider(runtime: binder, canonicalCommand: { [weak self] invocation in
            self?.canonicalHostInvocation(invocation.metadata)?.command
        })
        let definitions = try MCPAppToolGroup.orderedToolNames.map { name in
            guard let definition = MCPDomainCanonicalToolDefinitions.definition(named: name) else {
                throw MCPAppToolCatalogMaterializationError.missingCanonicalTools([name])
            }
            return definition
        }
        let bindings = definitions.map { definition in
            MCPDomainToolBinding(definition: definition) { [weak self] args in
                let name = definition.name
                guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                let invocation = try MCPInvocationContextBridge.require(toolName: name, expectedWindowID: identity.routeID)
                if name == MCPWindowToolName.history { return try await history.execute(args: args) }
                guard let origin = await canonicalHostInvocation(invocation.metadata) else { throw MCPFileToolAuthorityFailure.superseded }
                let host = origin.host
                if name == MCPWindowToolName.manageSelection {
                    return try await host.executeHostSelection(args: args, invocation: invocation)
                }
                if fileTools.contains(name) {
                    guard let lease = await host.workspaceActivation?.catalogFileLease else { throw MCPFileToolAuthorityFailure.superseded }
                    guard let binding = await host.makeHostFileReadResources(lease).binding(named: name, route: self) else {
                        throw MCPFileToolAuthorityFailure.unavailable
                    }
                    return try await binding(args)
                }
                switch name {
                case MCPWindowToolName.git:
                    return try await host.executeHostGit(args, invocation: invocation)
                case MCPWindowToolName.applyEdits:
                    return try await host.executeHostApplyEdits(args, invocation: invocation)
                case MCPWindowToolName.askUser:
                    return try await host.executeHostAskUser(args, invocation: invocation)
                case MCPWindowToolName.agentSelf:
                    return try await host.executeHostSelf(args, invocation: invocation)
                case MCPWindowToolName.selfNoop:
                    return await host.executeHostSelfNoop(args, invocation: invocation)
                case MCPWindowToolName.agentSessionLink:
                    return try await host.executeHostSessionLink(args, invocation: invocation)
                case MCPWindowToolName.becomeOverseer:
                    return try await host.executeHostBecomeOverseer(args, invocation: invocation)
                case MCPWindowToolName.agentManage:
                    return try await host.executeHostAgentManage(args, invocation: invocation)
                case MCPWindowToolName.manageWorktree:
                    return try await Value(worktrees.executeManageWorktree(args: args, invocationContext: invocation))
                case MCPWindowToolName.sessionAdmin:
                    return try await host.executeHostSessionAdmin(args, invocation: invocation)
                default:
                    throw MCPError.invalidRequest("Tool \(name) is not available through this independent Agent route")
                }
            }
        }
        let interactions = DomainLongRunningInteractionAdapter(
            isAvailable: { [weak self] request in
                guard let invocation = try? MCPInvocationContextBridge.require(toolName: MCPWindowToolName.askUser),
                      let connectionID = invocation.connectionID, request.clientID == connectionID else { return false }
                return await self?.hostQuestionIsAvailable(invocation.metadata) == true
            }, resolveDefaultTimeoutSeconds: { [weak self] request in
                let invocation = try MCPInvocationContextBridge.require(toolName: MCPWindowToolName.askUser)
                guard let connectionID = invocation.connectionID, request.clientID == connectionID,
                      await self?.hostQuestionIsAvailable(invocation.metadata) == true
                else {
                    throw MCPError.invalidParams("The originating Agent question owner is unavailable")
                }
                return await AgentSessionRuntimeHost.hostQuestionTimeout()
            }, cancel: { requestID in
                await MCPAskUserPresentationCoordinator.shared.cancel(requestID: requestID)
            }
        )
        do {
            _ = try await registerCatalog(MCPAppToolCatalogRegistration(
                windowID: identity.routeID, providers: [], sharedBindings: bindings, runtime: binder,
                hostInteractionAdapter: interactions, hostTransport: service, hostModelEndpoint: { [weak self] metadata in
                    guard let (host, connection) = self?.canonicalHostConnection(metadata) else { return nil }
                    return host.hostCatalogObserver(connection)
                }
            ))
        } catch RegistrationFailure.differentCatalog {
            guard usesHostCapabilities, await hasActiveCatalog(), hasHostTransport(service) else {
                throw RegistrationFailure.differentCatalog
            }
        }
    }

    private func hostQuestionIsAvailable(_ metadata: MCPRequestMetadata) async -> Bool {
        guard let origin = canonicalHostInvocation(metadata) else { return false }
        return await origin.host.hostInteractionCommand(metadata) != nil
    }
}

extension AgentSessionRuntimeHost {
    /// Preserve managed-lane forwarding without carrying child-only arguments or picking a window.
    func forwardHostAgentRunSteer(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        try Task.checkCancellation()
        try AgentRunMCPToolService.requireOversightSteerArguments(args)
        guard ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.agentSessionLink) else {
            throw MCPError.invalidParams("Oversight steering is disabled. Enable agent_session_link in tool settings, then use its steer operation under a Manage link.")
        }
        var forwarded: [String: Value] = [
            "op": .string("steer"),
            "idempotency_key": args["idempotency_key"] ?? .string(UUID().uuidString)
        ]
        forwarded["session_id"] = args["session_id"]
        forwarded["message"] = args["message"]
        return try await executeHostSessionLink(forwarded, invocation: invocation)
    }
}

private extension AgentSessionRuntimeHost {
    static func hostQuestionTimeout() -> TimeInterval {
        GlobalSettingsStore.shared.contextBuilderBehaviorSettings().questionTimeoutSeconds
    }

    func hostInteractionCommand(_ metadata: MCPRequestMetadata) async -> AgentSessionRuntimeStore.Command? {
        guard let connectionID = metadata.connectionID,
              let connection = try? route.fileReadConnection(metadata: metadata),
              let original = hostFileCommand(connection),
              await ServerNetworkManager.shared.runPurpose(for: connectionID) == .agentModeRun,
              hostFileCommand(connection)?.identity == original.identity else { return nil }
        return original
    }

    func executeHostSelfNoop(_ args: [String: Value], invocation: ToolInvocationContext) async -> Value {
        if let origin = AgentSelfMCPCallOrigin.current, let links = scope.linkExecution {
            links.enterSelfNoopBody(origin: origin, invocationID: invocation.invocationID, argumentsAreEmpty: args.isEmpty)
            let endpoint = await hostObserverEndpoint(invocation.metadata)
            links.acceptSelfNoopBody(origin: origin, endpoint: endpoint, invocationID: invocation.invocationID)
        }
        return AgentSelfNoopTool.acknowledgement
    }

    func executeHostSelf(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        try await AgentSelfMCPToolService.execute(
            args: args, isEnabled: { ToolAvailabilityStore.shared.isEnabled(MCPWindowToolName.agentSelf) }
        ) {
            guard let origin = AgentSelfMCPCallOrigin.current,
                  let endpoint = await hostObserverEndpoint(invocation.metadata), endpoint == origin.endpoint,
                  endpoint.hasResolvedPersistentBinding, let links = scope.linkExecution
            else { throw AgentSelfMCPToolService.unavailableError }
            return .init(
                read: { links.agentSelfContextSnapshot(endpoint: endpoint, origin: origin) },
                compact: { await links.agentSelfCompactMCPAdmission(endpoint: endpoint, origin: origin, note: $0, idempotencyKey: $1) }
            )
        }
    }

    func executeHostAskUser(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        guard let command = await hostInteractionCommand(invocation.metadata), let interactions = scope.installedInteractions else {
            throw MCPError.invalidParams("The originating Agent question owner is unavailable")
        }
        let parsed = try MCPAskUserToolProvider.parseAskUserInteraction(
            args: args, defaultTimeout: DomainInteractionPresentationContext.deadline?.originalTimeoutSeconds ?? Self.hostQuestionTimeout()
        )
        let result = try await MCPAskUserToolProvider.withAgentQuestionPresentation(
            requestID: DomainInteractionPresentationContext.requestID
        ) { [weak self] in
            guard let self, await hostInteractionCommand(invocation.metadata)?.identity == command.identity,
                  await ServerNetworkManager.shared.validateToolInvocationContext(
                      invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: ObjectIdentifier(route)
                  ) else { throw MCPFileToolAuthorityFailure.superseded }
            return try await interactions.askUser(command: command, interaction: parsed.interaction)
        }
        return MCPAskUserToolProvider.askUserResponseValue(result, includeLegacyResponse: parsed.includeLegacyResponse)
    }

    func executeHostAgentManage(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        guard AgentMCPToolHelpers.normalizedString(args["op"])?.lowercased() == "list_agents" else {
            throw MCPError.invalidRequest("This route supports model discovery through agent_manage list_agents, but cannot manage presentation sessions")
        }
        let rolesOnly: Bool
        if let value = args["roles_only"] {
            guard let parsed = AgentMCPToolHelpers.parseBool(value) else { throw MCPError.invalidParams("roles_only must be a boolean value.") }
            rolesOnly = parsed
        } else { rolesOnly = false }
        guard let command = await hostInteractionCommand(invocation.metadata), let activation = workspaceActivation,
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
        guard await captured.validate(), await hostInteractionCommand(invocation.metadata)?.identity == command.identity else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        return reply
    }

    func executeHostSessionAdmin(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        let bridge = AgentSessionLinkRuntimeBridge.shared
        return try await SessionAdminMCPToolService(
            captureRequestMetadata: { invocation.metadata },
            requireTargetWindow: { throw SessionAdminMCPToolService.unavailableError },
            resolveObserverEndpoint: { _, _ in nil }, scopes: { bridge.delegationScopes },
            administration: { bridge.sessionAdministrationFrontDoor },
            resolveCanonicalObserverEndpoint: { [weak self] in await self?.hostObserverEndpoint($0) }
        ).execute(args: args)
    }

    private func hostObserverEndpoint(_ metadata: MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity? {
        guard let command = await hostInteractionCommand(metadata) else { return nil }
        return scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: command.writer.session.tabID)
    }

    func executeHostBecomeOverseer(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        try await BecomeOverseerMCPToolService(
            captureRequestMetadata: { invocation.metadata },
            resolveObserverEndpoint: { [weak self] in await self?.hostObserverEndpoint($0) }
        ).execute(args: args)
    }

    func executeHostSessionLink(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        let resolve: (MCPRequestMetadata) async -> DomainAgentSessionLinkEndpointIdentity? = { [weak self] in await self?.hostObserverEndpoint($0) }
        return try await AgentSessionLinkMCPToolService(
            toolName: MCPWindowToolName.agentSessionLink, captureRequestMetadata: { invocation.metadata },
            requireTargetWindow: { throw MCPError.invalidRequest("This Agent route has no presenter") },
            resolveObserverEndpoint: { _, _ in nil }, withHeartbeat: { connectionID, tool, stage, message, operation in
                try await MCPToolHeartbeat.runProgress(
                    connectionID: connectionID, tool: tool, stage: stage, message: message,
                    invocation: invocation, operation: operation
                )
            }, resolveCanonicalObserverEndpoint: resolve, resolveModelObserverEndpoint: resolve
        ).execute(args: args)
    }
}
