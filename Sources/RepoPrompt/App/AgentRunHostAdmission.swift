import Foundation
import MCP
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptMCPServer

/// Admission for commands from an executable Agent route. A transport receipt proves the
/// caller, not access to a named child; target provenance is checked separately.
@MainActor
struct AgentRunHostAdmission {
    let host: AgentSessionRuntimeHost
    let source: AgentSessionRuntimeStore.Command
    let invocation: ToolInvocationContext
    let connection: MCPHostRouteResources.FileReadConnection
    let activation: AgentSessionHostWorkspaceActivation
    let rootLease: AgentHostWorkspaceResources.Lease

    init(host: AgentSessionRuntimeHost, invocation: ToolInvocationContext) async throws {
        let connection = try host.route.fileReadConnection(metadata: invocation.metadata)
        guard let source = host.hostFileCommand(connection), let activation = host.workspaceActivation,
              let lease = activation.catalogFileLease, lease.rootsAreCurrent,
              await ServerNetworkManager.shared.runPurpose(for: connection.connectionID) == .agentModeRun
        else { throw MCPFileToolAuthorityFailure.unavailable }
        self.host = host
        self.source = source
        self.invocation = invocation
        self.connection = connection
        self.activation = activation
        rootLease = lease
        try await requireCurrent()
    }

    var caller: DomainAgentSessionCallerIdentity {
        .agentSession(source.identity.sessionID)
    }

    var workspaceID: UUID {
        source.identity.workspaceID
    }

    var sourceIsCurrent: Bool {
        !Task.isCancelled && rootLease.rootsAreCurrent && host.workspaceActivation === activation
            && activation.owns(scope: host.scope, route: host.route)
            && host.hostFileCommand(connection)?.identity == source.identity
    }

    func requireCurrent() async throws {
        try Task.checkCancellation()
        guard sourceIsCurrent, await ServerNetworkManager.shared.validateToolInvocationContext(
            invocation, expectedWindowID: host.routeID, expectedServerViewModelIdentity: ObjectIdentifier(host.route)
        ), sourceIsCurrent else { throw MCPFileToolAuthorityFailure.superseded }
    }

    /// New child publication advances the workspace revision. Recheck the originating carrier
    /// and roots, rather than requiring the entire pre-publication document to remain unchanged.
    func canonicalWorkspace() async throws -> WorkspaceModel {
        let current = try await canonicalSnapshot()
        guard let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: current.document.documentBytes),
              workspace.id == workspaceID, !workspace.isEphemeral
        else { throw MCPFileToolAuthorityFailure.superseded }
        return workspace
    }

    func canonicalSnapshot() async throws -> DomainWorkspaceSnapshot {
        try await requireCurrent()
        guard let current = await activation.authority.canonicalWorkspaceSnapshot(workspaceID),
              provesCanonicalCarrier(in: current) else { throw MCPFileToolAuthorityFailure.superseded }
        return current
    }

    func provesCanonicalCarrier(in snapshot: DomainWorkspaceSnapshot) -> Bool {
        sourceIsCurrent && snapshot.document.workspaceID == workspaceID && snapshot.health.acceptsMutations
            && activation.executionTab(in: snapshot, command: source) != nil
            && Set(snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
            == Set(rootLease.roots.map { ($0.fullPath as NSString).standardizingPath })
    }

    func resolveStartSelection(
        arguments: [String: Value], resolvedTabID: UUID?, message: String
    ) async throws -> AgentRunMCPToolService.StartSelection {
        try await requireCurrent()
        guard let initialAvailability = activation.modelAvailability else { throw MCPFileToolAuthorityFailure.superseded }
        let selection = try await AgentRunMCPToolService.resolveStartSelection(
            requestedModelID: AgentMCPToolHelpers.normalizedString(arguments["model_id"]),
            hasExplicitModelParameters: arguments["model_parameters"] != nil,
            resolvedTabID: resolvedTabID,
            message: message,
            workspaceID: workspaceID,
            availability: { activation.modelAvailability ?? initialAvailability },
            usageBalancingEnabled: { host.modelRouterSettingsStore.modelRouterConfiguration().usageBalancing.enabled }
        ) { task, baseline, allowUsageBalance in
            try await routeSubagentTargetIfEnabled(task: task, baseline: baseline, allowUsageBalance: allowUsageBalance)
        }
        try await requireCurrent()
        return selection
    }

    private func routeSubagentTargetIfEnabled(
        task: String, baseline: AgentRoutingExecutableTarget?, allowUsageBalance: Bool
    ) async throws -> AgentRoutingExecutableTarget? {
        try await requireCurrent()
        guard let initialAvailability = activation.modelAvailability else { throw MCPFileToolAuthorityFailure.superseded }
        let policy = AgentTaskRoutingPolicy(
            modelRouterSettingsStore: host.modelRouterSettingsStore,
            modelRouterRuntime: WindowStatesManager.shared.modelRouterRuntime,
            availability: { activation.modelAvailability ?? initialAvailability },
            workspaceID: { workspaceID }
        )
        let selection = try await policy.routeSubagentTargetIfEnabled(
            task: task, surface: .general, baseline: baseline, allowUsageBalance: allowUsageBalance
        )
        try await requireCurrent()
        return selection
    }

    /// Capture from the admitted carrier before child publication or routing can suspend.
    /// A review-source failure is recorded with the true parent, never the child or a presenter.
    func captureOracleReviewSource() async -> AgentRunOracleReviewSource {
        let sessionID = source.identity.sessionID
        let tabID = source.writer.session.tabID
        let runID = connection.runID
        do {
            let origin = try await host.captureHostFileInvocation(invocation)
            guard origin.command.identity == source.identity else { throw MCPFileToolAuthorityFailure.superseded }
            let snapshot = origin.lease.snapshot
            let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
            let directory = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: host.route.workspaceStorageDirectory)
            let bindings = connection.lookupSource.worktreeBindings
            let reviewGitContext = await FrozenPromptGitReviewContext.make(
                workspaceID: workspaceID, workspaceDirectoryPath: directory.path,
                workspaceRootPaths: snapshot.document.metadata.repoPaths, tabID: tabID, sessionID: sessionID,
                bindings: bindings, base: "HEAD", store: origin.lease.resources.files
            )
            try await origin.requireCurrent()
            return .captured(.init(
                sourceTabID: tabID, workspaceID: workspaceID,
                sourceSelectionRevision: snapshot.contexts.first(where: { $0.metadata.identity.contextID == tabID })?.revisions.workingRevision
                    ?? snapshot.revisions.workingRevision,
                promptText: origin.tab.promptText, selection: origin.tab.selection,
                lookupContext: origin.lookup, reviewGitContext: reviewGitContext,
                sourceAgentSessionID: sessionID, sourceAgentRunID: runID, sourceWorktreeBindings: bindings
            ))
        } catch {
            return .unavailable(.init(
                delegationID: UUID(), sourceTabID: tabID, workspaceID: workspaceID,
                sourceAgentSessionID: sessionID, sourceAgentRunID: runID, reason: .sourceCaptureFailed(error.localizedDescription)
            ))
        }
    }

    func requireSpawnSource() throws {
        try Task.checkCancellation()
        guard sourceIsCurrent else { throw MCPFileToolAuthorityFailure.superseded }
        let session = source.writer.session
        if let failure = session.operationAdmissionFailureMessage { throw MCPError.invalidParams(failure) }
        guard session.mcpControlContext == nil || session.parentSessionID == nil else {
            throw MCPError.invalidParams("Sub-agents cannot start additional agent runs. Only top-level MCP-started agent sessions may spawn sub-agents; sub-agents with an engineer, pair, or design task role may start read-only explore children with agent_explore.")
        }
    }

    func target(_ sessionID: UUID, for operation: DomainAgentSessionTargetOperation) throws -> AgentSessionRuntimeStore.Command {
        guard sourceIsCurrent else { throw MCPFileToolAuthorityFailure.superseded }
        guard case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID, expectedWorkspaceID: workspaceID),
              let command = try? writer.admitCommand().get(), writer.session.hasLoadedPersistedState
        else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
        try requireTarget(command, for: operation)
        return command
    }

    func requireTarget(_ command: AgentSessionRuntimeStore.Command, for operation: DomainAgentSessionTargetOperation) throws {
        let sessionID = command.identity.sessionID
        guard sourceIsCurrent, command.isCurrent, command.identity.workspaceID == workspaceID else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
        try AgentSessionTargetOperationGuard.require(
            operation: operation, caller: caller,
            provenance: .known(targetSessionID: sessionID, parentSessionID: command.writer.session.parentSessionID),
            reference: sessionID.uuidString
        )
    }
}
