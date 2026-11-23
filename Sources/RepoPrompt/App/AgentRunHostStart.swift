import Foundation
import MCP

extension AgentRunHostAdmission {
    @MainActor
    private final class BoundStart {
        var child: AgentRunHostChildCreation?
    }

    /// Start a new child (or bind an exact empty tab) without selecting a presenter. The
    /// common service still owns parsing, the setup deadline, and the initial wait result.
    func executeCanonicalNewChild(
        _ args: [String: Value], bindingEmptyTabID: UUID? = nil
    ) async throws -> Value {
        let tools = makeHostToolService()
        let request = try tools.parseStartRequest(args)
        let preparation = BoundStart()
        return try await tools.executeResolvedStart(request, operation: { expiry in
            try await performCanonicalNewChild(
                args, request: request, bindingEmptyTabID: bindingEmptyTabID, expiry: expiry
            ) { child in
                preparation.child = child
            }
        }, expiredResult: { sessionID in
            let child = preparation.child
            let session = child?.command.writer.session
            let live: AgentRunMCPSnapshot? = if let child, let session,
                                                child.command.identity.sessionID == sessionID, sourceIsCurrent,
                                                child.command.writer.ownsPersistentClaim,
                                                child.host.scope.mcp.controlledWriter(sessionID: sessionID)?.session === session
            {
                child.host.scope.mcp.mcpReadSnapshot(for: session)
            } else {
                nil
            }
            let snapshot = AgentRunMCPToolService.startExpirySnapshot(sessionID: sessionID, live: live, ownerSession: session)
            return .init(
                value: AgentRunMCPToolService.startExpiryValue(snapshot), sessionID: sessionID,
                metadata: invocation.metadata, delivery: .startedRun, running: false
            )
        }, awaitStartedRun: { result in
            let targets = try await captureReadTargets([result.sessionID], operation: .runWait)
            let read = readAccess(for: targets, operation: .runWait)
            let value = try await makeHostToolService(waitTargets: targets).waitForStartedRun(request, result: result, read: read)
            try await requireReadTargets(targets, operation: .runWait)
            return value
        })
    }

    private func performCanonicalNewChild(
        _ args: [String: Value], request: AgentRunMCPToolService.StartRequest,
        bindingEmptyTabID: UUID?, expiry: AgentRunStartExpiry, didPublish: (AgentRunHostChildCreation) -> Void
    ) async throws -> AgentRunMCPToolService.StartResult {
        try expiry.throwIfExpired()
        try requireSpawnSource()
        _ = try await canonicalSnapshot()
        // Freeze the exact caller before resolving models or allocating a carrier.
        let review = await captureOracleReviewSource()
        let selection = try await resolveStartSelection(
            arguments: args, resolvedTabID: bindingEmptyTabID, message: request.message
        )
        try expiry.throwIfExpired()
        _ = try await canonicalSnapshot()
        try requireSpawnSource()
        let admission = try DelegationSpawnAdmission.admitOrThrow(creatorSessionID: source.identity.sessionID)
        defer { DelegationSpawnAdmission.finish(admission) }
        let child = try await AgentRunHostChildCreation.publish(
            from: self, name: AgentMCPToolHelpers.normalizedString(args["session_name"]),
            bindingEmptyTabID: bindingEmptyTabID
        )
        didPublish(child)
        do {
            let workspacePath = try await child.prepareWorktree(request.worktree, from: self, expiry: expiry)
            let parameters = try await selection.resolveParameters(args["model_parameters"], workspacePath: workspacePath)
            try expiry.throwIfExpired()
            try await requireCurrent()
            try DelegationSpawnAdmission.stageOnCanonicalCreation(admission, command: child.command, creation: child.creation)
            let outcome = try await child.start(
                from: self, message: request.message, selection: selection, parameters: parameters,
                workflow: request.workflow, reviewSource: review, expiry: expiry
            )
            return .init(
                value: makeHostToolService().decoratedRunValue(snapshot: outcome.snapshot, workflow: request.workflow, delivery: outcome.delivery),
                sessionID: outcome.snapshot.sessionID, metadata: invocation.metadata, delivery: outcome.delivery,
                running: outcome.snapshot.status == .running
            )
        } catch {
            await child.discardIfProvisional()
            throw error
        }
    }
}
