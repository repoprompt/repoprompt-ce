#if DEBUG
    import Foundation
    import MCP
    import RepoPromptShared

    /// MCP routing adapter over the same durable experiment service used by native cards.
    /// An external owner is scoped to an authorized workspace, not a fabricated Agent session.
    @MainActor
    enum PromptExperimentMCPControl {
        static func execute(
            args: [String: Value],
            dependencies: MCPAppPhysicalCapabilityAdapters.Execution
        ) async throws -> Value {
            let command = try MCPAgentSessionControlToolProvider.promptExperimentCommand(args: args)
            guard let connectionID = ServerNetworkManager.currentConnectionID else {
                throw MCPError.invalidParams("prompt_experiment requires an active MCP connection.")
            }
            let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
            let targetWindow = try dependencies.requireTargetWindow()
            let owner: PromptExperimentAgentOwner
            let workspaceID: UUID
            let validateScope: @MainActor () async throws -> Void
            switch purpose {
            case .agentModeRun:
                let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .promptExperiment)
                guard let identity = target.identity, let sessionID = identity.sessionID,
                      identity.persistentBindingGeneration != nil,
                      let activeWorkspaceID = targetWindow.workspaceManager.activeWorkspace?.id
                else { throw MCPError.invalidParams("prompt_experiment requires a durably bound Agent session identity.") }
                try targetWindow.agentModeViewModel.validatePromptExperimentTarget(target)
                workspaceID = activeWorkspaceID
                owner = PromptExperimentAgentOwner(
                    controllerSessionID: sessionID, sourceTabID: target.tabID,
                    authorizedSourceRoots: targetWindow.workspaceManager.activeWorkspace?.repoPaths ?? []
                )
                validateScope = {
                    try targetWindow.agentModeViewModel.validatePromptExperimentTarget(target)
                    guard targetWindow.workspaceManager.activeWorkspace?.id == activeWorkspaceID else {
                        throw MCPError.invalidParams("Experiment workspace changed; retry in its original workspace.")
                    }
                }
            case .unknown:
                let context = try await dependencies.requireCurrentTabContext(MCPWindowToolName.promptExperiment)
                guard let id = context.workspaceID,
                      let workspace = targetWindow.workspaceManager.activeWorkspace, workspace.id == id
                else { throw MCPError.invalidParams("Bind a loaded workspace context before using the experiment lab.") }
                if case .capabilities = command {
                    // Read-only discovery returns the exact workspace ID needed by subsequent calls.
                } else {
                    guard args["workspace_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == id else {
                        throw MCPError.invalidParams("External lab operations require workspace_id matching the bound workspace. Call capabilities first.")
                    }
                }
                workspaceID = id
                owner = .workspace(id, tabID: context.tabID, roots: workspace.repoPaths)
                validateScope = {
                    let current = try await dependencies.requireCurrentTabContext(MCPWindowToolName.promptExperiment)
                    guard current.workspaceID == id, current.tabID == context.tabID,
                          targetWindow.workspaceManager.activeWorkspace?.id == id,
                          targetWindow.workspaceManager.activeWorkspace?.repoPaths == workspace.repoPaths
                    else { throw MCPError.invalidParams("Experiment workspace/context changed; no authorization was transferred.") }
                }
            case .discoverRun:
                throw MCPError.invalidParams("Discovery and evaluated callbacks cannot control the experiment lab.")
            }
            let service = try PromptExperimentService.live(windowState: targetWindow)
            await service.load()
            try await validateScope()
            let response: PromptExperimentAgentResponse
            if case let .run(experimentID, digest) = command,
               purpose == .unknown || args["approval_mode"]?.stringValue == "mcp"
            {
                let record = try await service.requestRunUsingMCPApproval(
                    experimentID: experimentID, expectedPlanDigest: digest, owner: owner,
                    validateAuthority: {
                        guard targetWindow.workspaceManager.activeWorkspace?.id == workspaceID,
                              targetWindow.workspaceManager.activeWorkspace?.repoPaths == owner.authorizedSourceRoots
                        else { throw MCPError.invalidParams("Experiment workspace authority changed before approval.") }
                    }
                ) { plan in
                    let connection = try await ServerNetworkManager.shared.promptExperimentElicitationConnection(connectionID)
                    let accepted = try await PromptExperimentMCPElicitation.approve(plan, connection: connection)
                    try await validateScope()
                    return accepted
                }
                response = try await .record(record, artifactTextBySHA256: service.readableArtifactText(for: record))
            } else {
                response = try await PromptExperimentAgentInterface(service: service).execute(command, owner: owner)
            }
            var result = try MCPAgentSessionControlToolProvider.responseValue(
                response, usesMCPApproval: purpose == .unknown || args["approval_mode"]?.stringValue == "mcp"
            ).objectValue ?? [:]
            result["workspace_id"] = .string(workspaceID.uuidString)
            result["controller_scope"] = .string(purpose == .unknown ? "workspace" : "agent_session")
            result["approval_mode"] = .string(purpose == .unknown ? "mcp" : "native_or_mcp")
            return .object(result)
        }
    }
#endif
