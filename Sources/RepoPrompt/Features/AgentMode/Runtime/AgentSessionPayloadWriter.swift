import Foundation
import RepoPromptDomainRuntime

/// The exact source revision whose immutable payload is offered to storage. Presentation
/// selection is deliberately absent; storage placement is supplied by the workspace owner.
struct AgentSessionSaveCommitToken: Equatable {
    let tabID: UUID
    let sessionIdentity: ObjectIdentifier
    let workspaceID: UUID
    let workspaceDirectoryPath: String
    let binding: AgentPersistentSessionBindingIdentity
    let bindingTransitionGeneration: UInt64
    let sourceItemsRevision: Int
    let persistenceMutationGeneration: UInt64
    let saveRequestGeneration: UInt64

    @MainActor
    func matches(_ session: AgentTabSession, creationHandle: AgentSessionCreationHandle? = nil) -> Bool {
        ObjectIdentifier(session) == sessionIdentity
            && session.tabID == tabID
            && session.persistentSessionBindingIdentity == binding
            && session.bindingTransitionGeneration == bindingTransitionGeneration
            && !session.bindingTransitionInProgress
            && session.sourceItemsRevision == sourceItemsRevision
            && session.persistenceMutationGeneration == persistenceMutationGeneration
            && session.saveRequestGeneration == saveRequestGeneration
            // A transient refusal of new operations does not revoke an admitted writer's IO.
            // Binding/revision/claim/storage fences still qualify this exact originating save.
            && (session.qualifiedRestorationReadiness.permitsBoundOperationAndSave || creationHandle.map { session.creationHandleIsCurrent($0) } == true)
    }
}

/// Request-local effect evidence. A thrown saver or a stale owner after suspension is not
/// proof of no write. Only the existing configured-save/terminal authorities acknowledge it.
enum AgentSessionRequiredSavePhase: Equatable {
    case beforeWrite
    case writeMayHaveCommitted
    case writeReturned
    case durablySaved(AgentSessionRestorationBindingToken)
}

/// Performs the durable effect for an admitted runtime writer, without a view model, window,
/// selected tab, or provider factory. Transcript preparation and configured-creation readiness
/// stay with their existing authorities. A returned URL alone is never a durable acknowledgment.
@MainActor
enum AgentSessionPayloadWriter {
    typealias Saver = @MainActor (AgentSession, WorkspaceModel, Int) async throws -> URL

    enum Outcome {
        case rejectedBeforeWrite
        case supersededAfterWrite(URL)
        case written(URL)
    }

    static func write(
        _ payload: AgentSession,
        workspace: WorkspaceModel,
        canonicalItemCount: Int,
        writer: AgentSessionRuntimeStore.Writer,
        token: AgentSessionSaveCommitToken,
        creationHandle: AgentSessionCreationHandle? = nil,
        storageIsCurrent: () -> Bool,
        observingPhase: ((AgentSessionRequiredSavePhase) -> Void)? = nil,
        saver: Saver
    ) async throws -> Outcome {
        // Validate payload placement as well as the capability. A valid capability cannot be
        // repurposed to write another session, tab, or workspace's frozen payload.
        guard payload.id == writer.binding.sessionID,
              payload.workspaceID == workspace.id,
              payload.composeTabID == writer.binding.tabID,
              writer.binding.workspaceID == workspace.id,
              token.workspaceID == workspace.id,
              token.workspaceDirectoryPath == WorkspaceSessionSidecarMigration.workspaceDirectory(
                  for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL()
              ).standardizedFileURL.path,
              token.binding == writer.binding,
              writer.isCurrent,
              token.matches(writer.session, creationHandle: creationHandle),
              storageIsCurrent()
        else { return .rejectedBeforeWrite }

        observingPhase?(.writeMayHaveCommitted)
        let fileURL = try await saver(payload, workspace, canonicalItemCount)
        observingPhase?(.writeReturned)
        guard writer.isCurrent,
              token.matches(writer.session, creationHandle: creationHandle),
              storageIsCurrent()
        else { return .supersededAfterWrite(fileURL) }
        return .written(fileURL)
    }
}
