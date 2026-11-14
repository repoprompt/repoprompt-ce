import Foundation

/// Borrowed storage inputs; composition may use canonical async point reads for persistence.
/// Synchronous reads remain the legacy/attachment adapter, not a cached replacement catalog.
/// This value owns no catalog, selected tab, binding map or lifetime; reads must remain current.
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
        saveAdmission: @escaping (AgentTabSession) -> String? = { _ in nil },
        canonicalStorage: AgentSessionPersistenceRuntime.CanonicalStorage? = nil
    ) -> AgentSessionPersistenceRuntime.Composition {
        precondition(canonicalStorage == nil || canonicalStorage?.workspaceID == workspaceID)
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
                guard canonicalStorage != nil || workspace != nil, let writer = currentWriter(handle.session) else { return false }
                guard writer.restoration == handle.bindingToken else { return false }
                return (try? writer.admitCommand(.creation(handle)).get()) != nil
                    || handle.session.qualifiedRestorationReadiness == .authoritative(handle.bindingToken, .freshBindingDurablyCreated)
            },
            admitBinding: { session in
                // Originating final saves remain valid during retirement. Command admission is
                // deliberately not substituted for the save owner's restoration/creation checks.
                guard canonicalStorage != nil || workspace != nil, let writer = currentWriter(session) else { return nil }
                return .init(sessionID: writer.identity.sessionID, creation: nil)
            }, canonicalStorage: canonicalStorage
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

    /// Capture only an immutable storage location, not a replacement workspace catalog. Every
    /// retention/repair validates the original location against the canonical authority before
    /// disk work and before publication. A later storage move requires explicit recomposition.
    static func canonicalAttachmentConfiguration(
        storage: AgentSessionPersistenceRuntime.CanonicalStorage,
        workspaceDirectory: URL, isSuppressed: Bool,
        resourcesAreCurrent: @escaping () -> Bool
    ) async throws -> AgentSessionAttachmentRuntime.Configuration {
        guard resourcesAreCurrent(),
              let workspace = await storage.readWorkspace(storage.workspaceID), workspace.id == storage.workspaceID,
              resourcesAreCurrent(), !Task.isCancelled
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let location = AgentSessionAttachmentLocation(
            workspaceDirectory: workspaceDirectory,
            retainedRoot: retainedAttachmentsRoot(workspace: workspace, isSuppressed: isSuppressed)
        )
        return .init(location: { session in
            guard resourcesAreCurrent(),
                  session.persistentSessionBindingIdentity?.workspaceID == storage.workspaceID
            else { return nil }
            return location
        }, locationIsCurrent: { captured, session in
            guard resourcesAreCurrent(), captured == location,
                  session.persistentSessionBindingIdentity?.workspaceID == storage.workspaceID,
                  let current = await storage.readWorkspace(storage.workspaceID), current.id == storage.workspaceID
            else { return false }
            return resourcesAreCurrent()
                && session.persistentSessionBindingIdentity?.workspaceID == storage.workspaceID
                && AgentSessionAttachmentLocation(
                    workspaceDirectory: workspaceDirectory,
                    retainedRoot: retainedAttachmentsRoot(workspace: current, isSuppressed: isSuppressed)
                ) == location
        }, requiresCurrentLocationBeforeIO: true)
    }

    static func retainedAttachmentsRoot(workspace: WorkspaceModel?, isSuppressed: Bool) -> URL? {
        guard !isSuppressed, let workspace else { return nil }
        let folder = WorkspaceSessionSidecarMigration
            .workspaceDirectory(for: workspace, root: AgentSessionDataService.defaultWorkspaceRootURL())
            .appendingPathComponent("AgentSessions", isDirectory: true)
        return AgentSessionAttachmentStore.rootURL(forAgentSessionsFolder: folder)
    }
}
