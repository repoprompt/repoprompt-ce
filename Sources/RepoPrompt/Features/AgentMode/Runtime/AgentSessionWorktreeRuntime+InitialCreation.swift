import Foundation
import RepoPromptSettingsCore
import RepoPromptVCS
import RepoPromptWorkspaceContext

extension AgentSessionWorktreeRuntime {
    enum InitialPreparationError: LocalizedError {
        case unavailable(String)
        case failed(String)
        case retainedWorktree(path: String, underlying: String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message), let .failed(message): message
            case let .retainedWorktree(path, underlying):
                "The new worktree was created at \(path), but could not be bound to this thread. It was not removed; use worktree management to inspect or remove it. Error: \(underlying)"
            }
        }
    }

    static func isReadyForInitialWorktreeCommit(_ session: AgentTabSession) -> Bool {
        session.isPreparingInitialWorktree
            && session.hasEmptyIdleExecutionLocation
            && session.mcpControlContext == nil
            && !session.isMCPOriginated
            && session.parentSessionID == nil
            && !session.pendingHandoff.hasPayload
    }

    /// Actual initial-location effects use the supplied creation/restored command. Canonical
    /// callers also revalidate the originating resource lease; presentation only supplies a label.
    func prepareInitialExecutionLocation(
        _ choice: AgentModeViewModel.InitialStartLocation,
        admission: Admission, sessionName: String,
        operationIsCurrent: @escaping @MainActor () -> Bool,
        revalidateResources: @escaping @MainActor () async throws -> Void
    ) async throws {
        let session = admission.session
        let stale = AgentModeViewModel.staleComposerSubmitTargetMessage
        func requireOrigin() throws {
            try admission.requireCurrent()
            guard operationIsCurrent(), Self.isReadyForInitialWorktreeCommit(session) else {
                throw InitialPreparationError.unavailable(stale)
            }
        }
        func validateOrigin() async throws {
            try requireOrigin()
            try await revalidateResources()
            try requireOrigin()
        }
        try requireOrigin()
        guard let primaryRoot = admission.resources.declaredRepoPaths.first,
              let store = admission.resources.store
        else {
            throw InitialPreparationError.unavailable("Execution location requires an active Git-backed project workspace. Select Work locally or open a Git workspace.")
        }
        let primaryPath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath((primaryRoot as NSString).expandingTildeInPath) ?? primaryRoot
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        try await validateOrigin()
        guard let logicalRoot = visibleRoots.first(where: {
            (AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0.standardizedFullPath) ?? $0.standardizedFullPath) == primaryPath
        }) else {
            throw InitialPreparationError.unavailable("Execution location requires the primary workspace root to be loaded before starting this thread. Select Work locally or reload the workspace.")
        }
        guard let resolvedRepo = await VCSService.shared.resolveRepo(from: URL(fileURLWithPath: primaryPath)), resolvedRepo.backendKind == .git else {
            throw InitialPreparationError.unavailable("Execution location requires a Git-backed primary workspace root. Select Work locally or open a Git workspace.")
        }
        try await validateOrigin()
        let repo = GitRepoDescriptor(rootURL: resolvedRepo.rootURL)
        var createdWorktree: GitWorktreeDescriptor?
        do {
            let existingWorktrees = try await VCSService.shared.listGitWorktrees(at: repo.rootURL)
            try await validateOrigin()
            let worktree: GitWorktreeDescriptor
            let bindingSource: String
            switch choice {
            case .local: return
            case .newWorktree:
                let plan = try GitWorktreeDefaultPathPlanner.planAgentStart(
                    repoRoot: repo.rootPath, worktrees: existingWorktrees, sessionID: admission.command.identity.sessionID
                )
                worktree = try await VCSService.shared.createGitWorktree(
                    request: plan.createRequest, at: repo.rootURL,
                    beforeCommit: { @MainActor in try await validateOrigin() }
                )
                createdWorktree = worktree
                bindingSource = "agent_ui.initial_send"
            case let .existingWorktree(selection):
                guard let selected = existingWorktrees.first(where: {
                    $0.repository.repositoryID == selection.repositoryID && $0.worktreeID == selection.worktreeID
                }), !selected.isPrunable else {
                    throw InitialPreparationError.failed("The selected existing worktree is no longer available. Choose another execution location.")
                }
                worktree = selected
                bindingSource = "agent_ui.initial_send_existing"
            }
            func locationBindingFailure(_ message: String) -> InitialPreparationError {
                if let createdWorktree { return .retainedWorktree(path: createdWorktree.path, underlying: message) }
                return .failed("Could not bind the selected existing worktree: \(message)")
            }
            do { try await validateOrigin() }
            catch { throw locationBindingFailure(error.localizedDescription) }
            let label = GitWorktreeDisplayLabelHumanizer.seededVisualIdentityLabel(
                sessionName: sessionName, worktreeName: worktree.name, branch: worktree.branch, isMain: worktree.isMain
            )
            let identity = try GlobalSettingsStore.shared.ensureWorktreeVisualIdentity(
                repositoryID: worktree.repository.repositoryID, worktreeID: worktree.worktreeID, label: label
            )
            let binding = AgentSessionWorktreeBinding(
                id: UUID().uuidString, worktree: worktree, logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name, visualLabel: identity.label, visualColorHex: identity.colorHex, source: bindingSource
            )
            do {
                try requireOrigin()
                _ = try await transition([binding], admission: admission, intent: .initialSend, revalidateAuthority: validateOrigin)
            } catch {
                throw locationBindingFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        } catch let error as InitialPreparationError {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let createdWorktree { throw InitialPreparationError.retainedWorktree(path: createdWorktree.path, underlying: message) }
            throw InitialPreparationError.failed("Could not prepare the selected execution location: \(message)")
        }
    }
}
