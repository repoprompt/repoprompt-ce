import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRuntimeHost {
    /// Complete a creation claim through canonical carrier publication, initial worktree effects and
    /// the persistence owner's configured first save. The caller installs its pending-start
    /// cancellation before entering this operation; neither a carrier CAS nor its snapshot
    /// grants provider admission. A committed carrier is never rolled back or replayed on refusal.
    func prepareFreshCreation(
        submission: AgentSessionComposerSubmitClaim, rootIDs: [UUID]
    ) async throws -> (command: AgentSessionRuntimeStore.Command, stopFence: AgentRunStartStopFence) {
        let session = submission.sourceSession
        // A new local composer binding is still a presenter-origin action. Retained restored
        // commands use host currency; they do not authorize a new binding in a later UI epoch.
        guard let resources = workspaceActivation, resources.isPresenterCurrent else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let authority = resources.authority
        let activations = resources.activations
        guard submission.scope === scope, submission.command == nil,
              let initialLocation = submission.attempt.target.expectedInitialStartLocation,
              session.pendingInitialStartLocation == initialLocation,
              scope.submissions.isCurrent(submission), session.activeAgentSessionID == nil,
              session.persistentSessionBindingIdentity == nil,
              let membership = scope.membership(of: session), membership.permitsBindingPreparation,
              let activation = activations.latestSessionIndexOwner,
              let workspaceID = activation.workspaceID,
              scope.persistence.composition?.canonicalStorage?.workspaceID == workspaceID,
              authority.windowID == routeID, !route.isClosing, resources.isCurrent, !Task.isCancelled
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        submission.cancellation.retainProducer()
        if initialLocation != .local {
            submission.cancellation.ownsInitialPreparation(on: session)
            session.isPreparingInitialWorktree = true
        }
        defer {
            if session.composerStartCancellation === submission.cancellation { session.isPreparingInitialWorktree = false }
            submission.cancellation.releaseProducer()
        }
        let unboundStop = AgentRunStartStopFence(session: session)
        let snapshot = await authority.canonicalWorkspaceSnapshot(workspaceID)
        guard !Task.isCancelled, !route.isClosing,
              activations.latestSessionIndexOwner == activation,
              membership.permitsBindingPreparation, scope.submissions.isCurrent(submission),
              unboundStop.permitsStart(of: session), session.activeAgentSessionID == nil,
              session.runID == nil, session.activeRunOwnership == nil, !session.runState.isActive,
              let snapshot, snapshot.health != .removed,
              snapshot.document.workspaceID == workspaceID,
              snapshot.contexts.contains(where: {
                  $0.metadata.identity == .init(workspaceID: workspaceID, contextID: session.tabID) && $0.health != .removed
              })
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        var workspace = try JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
        let indices = workspace.composeTabs.indices.filter { workspace.composeTabs[$0].id == session.tabID }
        guard workspace.id == workspaceID, indices.count == 1, let index = indices.first,
              workspace.composeTabs[index].activeAgentSessionID == nil,
              !workspace.stashedTabs.contains(where: { $0.tab.id == session.tabID })
        else { throw AgentHostWorkspaceResources.Failure.contextUnavailable }

        // No suspension between allocation, binding installation, and creation admission. The
        // existing submission cancellation is already installed and follows this first binding.
        let allocation = AgentSessionCreationClaim(workspaceID: workspaceID)
        session.beginPersistentBindingTransition()
        session.installPersistentSessionBinding(.init(
            tabID: session.tabID, sessionID: allocation.sessionID, workspaceID: workspaceID
        ))
        guard let creation = session.acceptFreshCreation(allocation, workspaceID: workspaceID) else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let command = try scope.admit(session: session, expectedWorkspaceID: workspaceID, requirement: .creation(creation))
        let stop = AgentRunStartStopFence(session: session)
        func requireOrigin() throws {
            try command.requireCurrent()
            guard !Task.isCancelled, !route.isClosing, resources.isCurrent, activations.latestSessionIndexOwner == activation,
                  scope.submissions.isCurrent(submission), stop.permitsStart(of: session)
            else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        }
        do {
            workspace.composeTabs[index].activeAgentSessionID = allocation.sessionID
            workspace.composeTabs[index].lastModified = Date()
            let document = try await WorkspaceFileDecodeCache.shared.documentPreparation.document(
                for: workspace, fileURL: snapshot.document.fileURL
            )
            try requireOrigin()
            let publication = try await authority.replaceWorkingFailClosed(
                document, expectedWorkspaceRevision: snapshot.revisions.workingRevision
            )
            try requireOrigin()
            guard publication.disposition == .applied || publication.disposition == .unchanged || publication.disposition == .deduplicated else {
                throw AgentHostWorkspaceResources.Failure.contextUnavailable
            }
            if initialLocation != .local {
                let admission = try await resources.captureCreationWorktreeAdmission(command: command, rootIDs: rootIDs, route: route)
                try requireOrigin()
                try await scope.worktrees.prepareInitialExecutionLocation(
                    initialLocation, admission: admission,
                    sessionName: scope.persistence.composition?.displayName(session.tabID) ?? "Agent",
                    operationIsCurrent: { (try? requireOrigin()) != nil },
                    revalidateResources: admission.resources.awaitRootReadiness
                )
                try requireOrigin()
                try await admission.resources.awaitRootReadiness()
                try requireOrigin()
                session.pendingInitialStartLocation = .local
            }
            // This is the actual configured payload/save acknowledgement, not a carrier receipt.
            guard case .durablySaved = await scope.persistence.commitConfiguredCreation(creation, writer: command.writer) else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            // The creation capability is intentionally consumed by the durable acknowledgement.
            // Admit restored execution ONLY on that same writer, never by resolving today's owner.
            let restored = try command.writer.admitCommand().get()
            try restored.requireCurrent()
            guard !Task.isCancelled, !route.isClosing, resources.isCurrent, activations.latestSessionIndexOwner == activation,
                  scope.submissions.isCurrent(submission), stop.permitsStart(of: session)
            else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            // The caller forwards this original pending-start fence into RunStart options;
            // recreating it after capture would adopt a Stop that arrived during preparation.
            return (restored, stop)
        } catch {
            // Originating cleanup may record a failed preparation, but cannot follow a successor
            // writer or undo a possibly committed carrier/sidecar. An acknowledged save is retained.
            if command.writer.ownsPersistentClaim {
                session.failCreationPreparation(creation, message: "The new session could not finish its canonical preparation.")
            }
            throw error
        }
    }
}
