import Foundation

/// Borrowed, synchronous reads from the host's canonical workspace/catalog authority. This value
/// owns no catalog, selected tab, binding map or lifetime. The host must keep these reads current
/// across IO; an immutable stale snapshot is not a replacement for the catalog's currency fence.
@MainActor
struct AgentSessionStorageInputs {
    let workspaceID: UUID
    let workspaceWithID: (UUID) -> WorkspaceModel?
    let displayName: (UUID) -> String
    let isSuppressed: () -> Bool
    let attachmentWorkspaceDirectory: () -> URL?

    var workspace: WorkspaceModel? {
        guard let workspace = workspaceWithID(workspaceID), workspace.id == workspaceID else { return nil }
        return workspace
    }

    /// A saved host never manufactures a fresh binding while saving. Fresh creation is admitted
    /// only with an already-issued exact creation handle, through the same durable transaction.
    /// Hosts must explicitly call saveSessionCore(.configured(handle)) before ordinary required
    /// flushes. A required flush must not silently qualify an unconfigured new session.
    func persistenceComposition(
        scope: AgentSessionRuntimeStore.Scope,
        saveAdmission: @escaping (AgentTabSession) -> String? = { _ in nil }
    ) -> AgentSessionPersistenceRuntime.Composition {
        let currentWriter: (AgentTabSession) -> AgentSessionRuntimeStore.Writer? = { [weak scope] session in
            guard let scope, scope.sessions[session.tabID] === session,
                  let id = session.activeAgentSessionID,
                  case let .unique(writer) = scope.resolveWriter(sessionID: id, expectedWorkspaceID: workspaceID),
                  writer.scope === scope, writer.session === session else { return nil }
            return writer
        }
        return .init(
            workspace: { workspace }, workspaceWithID: workspaceWithID, displayName: displayName,
            isSuppressed: isSuppressed, bypassesSuppression: { false }, isPreparedSavedHost: { true },
            saveAdmission: saveAdmission,
            creationIsCurrent: { handle in
                guard workspace != nil, let writer = currentWriter(handle.session) else { return false }
                return (try? writer.admitCommand(.creation(handle)).get()) != nil
            },
            admitBinding: { session in
                // Originating final saves remain valid during retirement. Command admission is
                // deliberately not substituted for the save owner's restoration/creation checks.
                guard workspace != nil, let writer = currentWriter(session) else { return nil }
                return .init(sessionID: writer.identity.sessionID, creation: nil)
            }
        )
    }

    func attachmentConfiguration() -> AgentSessionAttachmentRuntime.Configuration {
        .canonical { session in
            guard let directory = attachmentWorkspaceDirectory() else { return nil }
            if let binding = session.persistentSessionBindingIdentity, binding.workspaceID != workspaceID { return nil }
            return .init(
                workspaceDirectory: directory,
                retainedRoot: Self.retainedAttachmentsRoot(workspace: workspace, isSuppressed: isSuppressed())
            )
        }
    }

    static func retainedAttachmentsRoot(workspace: WorkspaceModel?, isSuppressed: Bool) -> URL? {
        guard !isSuppressed, let workspace else { return nil }
        let folder = WorkspaceSessionSidecarMigration
            .workspaceDirectory(for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL())
            .appendingPathComponent("AgentSessions", isDirectory: true)
        return AgentSessionAttachmentStore.rootURL(forAgentSessionsFolder: folder)
    }
}
