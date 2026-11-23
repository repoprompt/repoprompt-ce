import Foundation
import RepoPromptDomainRuntime

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
                  readTargetIsCurrent(target, operation: operation) else { return .expired(sessionID: sessionID) }
            let stored = await AgentRunSessionStore.snapshot(for: registration)
            guard readTargetIsCurrent(target, operation: operation) else { return .expired(sessionID: sessionID) }
            if let stored, stored.status.isTerminal { return stored }
            return target.runtime.mcpReadSnapshot(for: target.command.writer.session) ?? stored ?? .expired(sessionID: sessionID)
        }, unavailable: { _ in nil })
    }
}
