import Foundation

/// Commands over the canonical session writer. Composition supplies the existing destination
/// creation owner, not a window/session selector. The runtime never manufactures a writer.
@MainActor
final class AgentSessionAdministrationRuntime {
    struct ForkRequest {
        let source: AgentTabSession
        let cutoff: UUID
        let workspaceID: UUID
        let isStillAuthorized: @MainActor () -> Bool
    }

    /// Captured at the destination creation owner's configured durable-save boundary. Completion
    /// never rediscovers a tab's later occupant after an await.
    struct ForkReceipt {
        let identity: AgentSessionRuntimeStore.WriterIdentity
    }

    /// A committed-but-incomplete destination must throw SessionAdminPartialForkError unchanged.
    typealias PrepareForkDestination = @MainActor (ForkRequest) async throws -> ForkReceipt

    private weak var scope: AgentSessionRuntimeStore.Scope?
    var prepareForkDestination: PrepareForkDestination?

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func fork(
        command: AgentSessionRuntimeStore.Command,
        upToItemID: UUID?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> UUID {
        guard command.writer.scope === scope, command.isCurrent else {
            throw SessionAdminHostError.sessionUnavailable
        }
        guard isStillAuthorized(), !Task.isCancelled else { throw SessionAdminHostError.authorityEnded }
        let source = command.writer.session
        guard let cutoff = upToItemID ?? source.items.last?.id else {
            throw SessionAdminHostError.invalid("The target session has no transcript to fork.")
        }
        guard let prepareForkDestination else { throw SessionAdminHostError.sessionUnavailable }
        let receipt = try await prepareForkDestination(.init(
            source: source, cutoff: cutoff, workspaceID: command.identity.workspaceID,
            isStillAuthorized: { command.isCurrent && isStillAuthorized() && !Task.isCancelled }
        ))
        // The destination creation owner, not source authority, decides completion after the tab
        // commit. Late source revocation/cancellation cannot discard a durably configured fork.
        guard receipt.identity.scopeID == command.identity.scopeID,
              receipt.identity.workspaceID == command.identity.workspaceID,
              receipt.identity.sessionID != command.identity.sessionID
        else {
            throw SessionAdminPartialForkError(
                sessionID: receipt.identity.sessionID, code: "target_changed",
                detail: "The fork was saved, but its acknowledged destination does not match the requested workspace. Inspect it before retrying."
            )
        }
        return receipt.identity.sessionID
    }
}
