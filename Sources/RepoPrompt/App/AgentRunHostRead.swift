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
        let targets = try await captureReadTargets(sessionIDs, operation: operation)
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
        try await requireReadTargets(targets, operation: operation)
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
