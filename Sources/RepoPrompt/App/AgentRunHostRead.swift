import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer

extension AgentRunHostAdmission {
    /// One read's exact target. Epochs can advance within the captured registration, but a
    /// new registration, writer, or carrier must never inherit an in-flight read.
    @MainActor
    struct ReadTarget {
        fileprivate let command: AgentSessionRuntimeStore.Command
        fileprivate let activation: AgentSessionHostWorkspaceActivation
        fileprivate let registration: AgentRunSessionStore.Registration?
        fileprivate let controlActivationID: UUID?

        var sessionID: UUID {
            command.identity.sessionID
        }

        fileprivate var runtime: AgentSessionMCPRuntime {
            command.writer.scope.mcp
        }

        fileprivate var controlIsCurrent: Bool {
            let session = command.writer.session
            let context = session.mcpControlContext
            guard context?.registration == registration, context?.activationID == controlActivationID else { return false }
            guard let registration else { return true }
            return runtime.controlRead(sessionID: sessionID, registration: registration).session === session
        }
    }

    func captureReadTargets(_ sessionIDs: [UUID], operation: DomainAgentSessionTargetOperation) async throws -> [ReadTarget] {
        let snapshot = try await canonicalSnapshot()
        return try sessionIDs.map { sessionID in
            let command = try target(sessionID, for: operation)
            let scope = command.writer.scope
            guard let host = scope.executableHost, let activation = host.workspaceActivation,
                  activation.owns(scope: scope, route: host.route), activation.executionTab(in: snapshot, command: command) != nil
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
            let context = command.writer.session.mcpControlContext
            let read = ReadTarget(
                command: command, activation: activation,
                registration: context?.registration, controlActivationID: context?.activationID
            )
            guard read.controlIsCurrent else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
            return read
        }
    }

    func requireReadTargets(_ targets: [ReadTarget], operation: DomainAgentSessionTargetOperation) async throws {
        let snapshot = try await canonicalSnapshot()
        try validateReadTargets(targets, operation: operation, snapshot: snapshot)
    }

    private func validateReadTargets(
        _ targets: [ReadTarget], operation: DomainAgentSessionTargetOperation, snapshot: DomainWorkspaceSnapshot
    ) throws {
        for target in targets {
            guard readTargetIsCurrent(target, operation: operation),
                  target.activation.executionTab(in: snapshot, command: target.command) != nil
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: target.sessionID) }
        }
    }

    private func readTargetIsCurrent(_ target: ReadTarget, operation: DomainAgentSessionTargetOperation) -> Bool {
        let scope = target.command.writer.scope
        guard (try? requireTarget(target.command, for: operation)) != nil,
              let host = scope.executableHost, host.workspaceActivation === target.activation,
              target.activation.owns(scope: scope, route: host.route) else { return false }
        return target.controlIsCurrent
    }

    func beginReadWait(for targets: [ReadTarget], timeoutSeconds: TimeInterval) -> AgentRunWaitScopeRegistration? {
        guard sourceIsCurrent, let parentRunID = connection.runID else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.sessionID, $0) })
        return host.route.toolExecutionRuntime.beginAgentRunWaitScope(
            parentRunID: parentRunID, metadata: invocation.metadata, sessionIDs: Set(byID.keys),
            timeoutSeconds: timeoutSeconds, exactPublication: { sessionID in
                guard let target = byID[sessionID], readTargetIsCurrent(target, operation: .runWait),
                      let publication = target.runtime.waitPublication(sessionID: sessionID),
                      publication.cursor.registration == target.registration else { return nil }
                return publication
            }
        )
    }

    func readAccess(for targets: [ReadTarget], operation: DomainAgentSessionTargetOperation) -> AgentRunMCPToolService.RunReadAccess {
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.sessionID, $0) })
        return .init(waitCursor: { sessionID in
            guard let target = byID[sessionID], readTargetIsCurrent(target, operation: operation),
                  let cursor = target.runtime.waitCursor(sessionID: sessionID), cursor.registration == target.registration
            else { return nil }
            return cursor
        }, snapshot: { sessionID in
            guard let target = byID[sessionID], let registration = target.registration,
                  readTargetIsCurrent(target, operation: operation) else { return AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID) }
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            guard readTargetIsCurrent(target, operation: operation) else { return AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID) }
            if let stored, stored.status.isTerminal { return stored }
            return target.runtime.mcpReadSnapshot(for: target.command.writer.session) ?? stored ?? AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)
        }, unavailable: { _ in nil })
    }

    /// No writer is installed for a read. A verified durable carrier without a live control
    /// registration can report only the expired run handle, never a saved transcript preview.
    private func captureExpiredRead(
        sessionID: UUID, operation: DomainAgentSessionTargetOperation
    ) async throws -> AgentSavedSessionTargetLoader.Target {
        let denial = AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        func absent() -> Bool {
            guard sourceIsCurrent,
                  case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID)
            else { return false }
            return true
        }
        guard absent(),
              let lookup = try? await AppSavedAgentSessionExecution.resolve(
                  sessionID, store: activation.authority.store, isStillAuthorized: absent
              ), lookup.target.workspace.id == workspaceID else { throw denial }
        let target = lookup.target
        let workspace = try await canonicalWorkspace()
        guard absent(), target.carrier(in: workspace) != nil else { throw denial }
        try authorizeExpiredRead(target, operation: operation)
        return target
    }

    private func authorizeExpiredRead(
        _ target: AgentSavedSessionTargetLoader.Target, operation: DomainAgentSessionTargetOperation
    ) throws {
        let sessionID = target.entry.id
        guard !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID),
              case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: sessionID)
        else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        try AgentSessionTargetOperationGuard.require(
            operation: operation, caller: caller,
            provenance: .known(targetSessionID: sessionID, parentSessionID: target.entry.parentSessionID),
            reference: sessionID.uuidString
        )
    }

    /// Reuse the exact single/multi wait policies without an adapter that can select a window.
    func executeControlRead(_ args: [String: Value], poll: Bool) async throws -> Value {
        let usesArray = args["session_ids"] != nil
        let references: [String] = if usesArray {
            try AgentRunMCPToolService.parseSessionIDArray(args)
        } else {
            try [Self.requireControlSessionReference(args)]
        }
        var seen: Set<UUID> = []
        let sessionIDs = try references.compactMap { reference -> UUID? in
            let id = try Self.controlSessionID(reference)
            return seen.insert(id).inserted ? id : nil
        }
        let operation: DomainAgentSessionTargetOperation = poll ? .runPoll : .runWait
        var liveIDs: [UUID] = []
        var expired: [AgentSavedSessionTargetLoader.Target] = []
        for id in sessionIDs {
            if case .unavailable(.absent) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: id) {
                try await expired.append(captureExpiredRead(sessionID: id, operation: operation))
            } else {
                liveIDs.append(id)
            }
        }
        let targets = try await captureReadTargets(liveIDs, operation: operation)
        let read = readAccess(for: targets, operation: operation)
        let tools = makeHostToolService(waitTargets: targets)
        let timeout = try poll ? 0 : AgentRunMCPToolService.resolvedWaitTimeoutSeconds(
            args["timeout"], capturedDefaultWaitSeconds: AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds()
        )
        let value: Value = if poll, usesArray {
            await tools.executeResolvedPollMany(sessionIDs: sessionIDs, read: read)
        } else if sessionIDs.count == 1 {
            try await tools.executeResolvedWait(
                sessionID: sessionIDs[0], read: read, metadata: invocation.metadata, timeoutSeconds: timeout
            )
        } else {
            try await tools.executeResolvedWaitAny(
                sessionIDs: sessionIDs, read: read, metadata: invocation.metadata, timeoutSeconds: timeout
            )
        }
        for target in expired {
            let current = try await captureExpiredRead(sessionID: target.entry.id, operation: operation)
            guard current.tab.id == target.tab.id, current.stashedTabID == target.stashedTabID,
                  current.entry.parentSessionID == target.entry.parentSessionID,
                  current.workspace.customStoragePath == target.workspace.customStoragePath
            else { throw AgentSessionTargetOperationGuard.denialError(sessionID: target.entry.id) }
        }
        // Qualify every carrier against the same final authority snapshot. A prior sidecar
        // read alone does not authorize using an ID whose tab changed during another read.
        let finalSnapshot = try await canonicalSnapshot()
        try validateReadTargets(targets, operation: operation, snapshot: finalSnapshot)
        if !expired.isEmpty {
            let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: finalSnapshot.document.documentBytes)
            for target in expired {
                guard target.carrier(in: workspace) != nil else {
                    throw AgentSessionTargetOperationGuard.denialError(sessionID: target.entry.id)
                }
                try authorizeExpiredRead(target, operation: operation)
            }
        }
        return value
    }

    func executeControlCancellation(_ args: [String: Value]) async throws -> Value {
        let sessionID = try Self.controlSessionID(Self.requireControlSessionReference(args))
        let targets = try await captureReadTargets([sessionID], operation: .runCancel)
        guard let target = targets.first, let executor = target.command.writer.scope.linkExecution,
              let cancellation = AgentRunCapturedCancellation(
                  sessionID: sessionID, session: target.command.writer.session,
                  runtime: target.runtime, executor: executor, requireOrigin: {
                      guard readTargetIsCurrent(target, operation: .runCancel) else {
                          throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
                      }
                  }
              ) else { throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID) }
        let read = readAccess(for: targets, operation: .runCancel)
        return try await makeHostToolService().executeResolvedCancellation(
            cancellation, metadata: invocation.metadata, snapshot: { await read.snapshot(sessionID) },
            revalidateOrigin: { try await requireReadTargets(targets, operation: .runCancel) }
        )
    }

    func executeControlResponse(_ args: [String: Value]) async throws -> Value {
        let sessionID = try Self.controlSessionID(Self.requireControlSessionReference(args))
        let targets = try await captureReadTargets([sessionID], operation: .runRespond)
        guard let target = targets.first, let interactions = target.command.writer.scope.installedInteractions else {
            throw AgentSessionTargetOperationGuard.denialError(sessionID: sessionID)
        }
        let tools = makeHostToolService()
        let interactionID = try tools.requireUUID(args["interaction_id"], name: "interaction_id")
        let workflow = try tools.resolveWorkflow(args: args)
        let payload = try AgentRunMCPToolService.parseResponsePayload(args: args)
        try await requireReadTargets(targets, operation: .runRespond)
        let delivery = try await interactions.resolveMCPResponse(command: target.command, interactionID: interactionID, payload: payload) { text in
            try await submitExactActiveControlInput(target, text: text, workflow: workflow, operation: .runRespond, expectedInstructionID: interactionID)
        }
        await Task.yield()
        let candidate = await readAccess(for: targets, operation: .runRespond).snapshot(sessionID)
        let snapshot: AgentRunMCPSnapshot = if await (try? requireReadTargets(targets, operation: .runRespond)) != nil {
            candidate
        } else {
            // The response already settled on the exact interaction. Do not project a successor,
            // and do not misreport the accepted effect as a refusal to answer.
            AgentRunMCPToolService.agentRunExpiredSnapshot(sessionID: sessionID)
        }
        return tools.decoratedRunValue(snapshot: snapshot, workflow: workflow, delivery: delivery)
    }

    func submitExactActiveControlInput(
        _ target: ReadTarget, text: String, workflow: AgentWorkflowDefinition?,
        operation: DomainAgentSessionTargetOperation, expectedInstructionID: UUID? = nil
    ) async throws -> AgentMCPInstructionDispatch {
        try await requireReadTargets([target], operation: operation)
        let scope = target.command.writer.scope
        let session = target.command.writer.session
        guard let targetHost = scope.executableHost, let executor = scope.linkExecution,
              let endpoint = executor.agentSessionLinkObserverEndpoint(tabID: session.tabID),
              endpoint.sessionID == target.sessionID,
              let route = executor.agentSessionLinkManagedSteerRoute(for: session)
        else { throw MCPError.invalidParams("The requested agent run cannot receive active input.") }
        let currentInteraction = target.runtime.mcpPendingInteraction(for: session)
        if let currentInteraction, currentInteraction.kind != .instruction {
            throw MCPError.invalidParams("The run is waiting on \(currentInteraction.kind.rawValue). Use agent_run.respond instead.")
        }
        if let expectedInstructionID {
            guard currentInteraction?.id == expectedInstructionID, route == .waitingInstruction else {
                throw MCPError.invalidParams("The pending instruction prompt no longer matches interaction_id.")
            }
        }
        guard session.pendingApplyEditsReview == nil, session.pendingWorktreeMergeReview == nil else {
            throw MCPError.invalidParams("Resolve the protected review before submitting task input.")
        }
        let origin = targetHost.canonicalInputEnvironment(for: session)
        func inputIsCurrent() -> Bool {
            guard origin.resourcesAreCurrent(), readTargetIsCurrent(target, operation: operation),
                  session.pendingApplyEditsReview == nil, session.pendingWorktreeMergeReview == nil else { return false }
            let pending = target.runtime.mcpPendingInteraction(for: session)
            if let expectedInstructionID {
                return pending?.kind == .instruction && pending?.id == expectedInstructionID
                    && executor.agentSessionLinkManagedSteerRoute(for: session) == .waitingInstruction
            }
            return pending == nil || pending?.kind == .instruction
        }
        let environment = AgentSessionLinkExecutionRuntime.ManagedInputEnvironment(
            workspaceID: origin.workspaceID, resourcesAreCurrent: inputIsCurrent,
            settings: origin.settings, tools: origin.tools, validateResources: { command in
                guard await origin.validateResources(command),
                      await (try? requireReadTargets([target], operation: operation)) != nil else { return false }
                return inputIsCurrent()
            }, captureProviderLaunchInput: origin.captureProviderLaunchInput
        )
        let sink = AgentSessionLinkManagedSteerSink()
        let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: text, sink: sink)
        guard executor.submitNoncomposerSteer(
            tabID: session.tabID, session: session, displayText: text, turn: turn,
            route: route, workflow: workflow, environment: environment, originatingCommand: target.command
        ) else { throw MCPError.invalidParams("The requested agent run changed before input could be submitted.") }
        let result = await sink.awaitOutcome(timeoutSeconds: AgentSessionLinkExecutionRuntime.agentSessionLinkManagedSteerOutcomeTimeoutSeconds)
        switch result {
        case let .delivered(state):
            switch state {
            case .deliveredToWaitingInstruction: return .deliveredIntoWaitingContinuation
            case .queuedFollowUp: return .queuedFollowUp
            case .queuedInterrupt: return route == .claudeInterrupt ? .queuedClaudeInterrupt : .queuedACPInterrupt
            default: return .dispatchedCodexTurn
            }
        case let .notAccepted(message), let .unconfirmed(message):
            throw MCPError.invalidParams(message)
        }
    }

    static func requireControlSessionReference(_ args: [String: Value]) throws -> String {
        guard let reference = AgentMCPToolHelpers.normalizedString(args["session_id"]) else {
            throw MCPError.invalidParams("session_id is required for agent_run control operations.")
        }
        return reference
    }

    static func controlSessionID(_ reference: String) throws -> UUID {
        // The existing session resolver accepts UUIDs, not name or prefix searches.
        guard let id = UUID(uuidString: reference) else {
            throw MCPError.invalidParams("Session '\(reference)' was not found. Provide a full UUID.")
        }
        return id
    }

    func makeHostToolService(waitTargets: [ReadTarget] = []) -> AgentRunMCPToolService {
        let metadata = invocation.metadata
        return AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { metadata },
            requireTargetWindow: { throw MCPError.invalidRequest("This Agent route has no presenter") },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in source.writer.session.tabID },
            resolveSpawnParentSessionID: { _, _ in source.identity.sessionID },
            withHeartbeat: { connectionID, tool, stage, message, operation in
                try await MCPToolHeartbeat.runProgress(
                    connectionID: connectionID, tool: tool, stage: stage, message: message,
                    invocation: invocation, operation: operation
                )
            },
            beginAgentRunWait: { _, sessionIDs, timeout in
                beginReadWait(for: waitTargets.filter { sessionIDs.contains($0.sessionID) }, timeoutSeconds: timeout)
            },
            endAgentRunWait: { token, completion in
                host.route.toolExecutionRuntime.endAgentRunWaitScope(token, completion: completion)
            },
            startRun: { _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("The presenter start adapter is not installed on this host")
            }
        )
    }
}
