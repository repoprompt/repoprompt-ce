import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptVCS
import RepoPromptWorkspaceCore

/// Production hosts over every open window. Each effect routes to the window that owns the target
/// session and to the existing owner of that state; nothing here authorizes.
@MainActor
enum SessionAdminWindows {
    static func owningViewModel(for sessionID: UUID) -> AgentModeViewModel? {
        WindowStatesManager.shared.allWindows
            .first { !$0.isClosing && $0.agentModeViewModel.ownerValidatedSessionIndex[sessionID] != nil }?
            .agentModeViewModel
    }

    static func liveSession(_ sessionID: UUID) -> (AgentModeViewModel, AgentTabSession)? {
        guard let viewModel = owningViewModel(for: sessionID),
              let session = try? viewModel.authoritativeLiveSession(for: sessionID)
        else { return nil }
        return (viewModel, session)
    }
}

@MainActor
final class SessionAdminWindowsStructureHost: SessionAdminStructureHost {
    private let bridge: () -> AgentSessionLinkRuntimeBridge

    init(bridge: @escaping () -> AgentSessionLinkRuntimeBridge = { AgentSessionLinkRuntimeBridge.shared }) {
        self.bridge = bridge
    }

    func commitOrganizationalPlacement(
        sessionID: UUID,
        parentID: UUID,
        delegationScopeID: UUID?
    ) throws -> DelegationPlacementCommit? {
        guard let viewModel = SessionAdminWindows.owningViewModel(for: sessionID) else { return nil }
        let scopeID = delegationScopeID ?? viewModel.ownerValidatedSessionIndex[sessionID]?.delegationScopeID
        return try viewModel.commitDelegationPlacement(
            sessionID: sessionID, organizationalParentID: parentID, delegationScopeID: scopeID
        )
    }

    var mintedLinkCapabilities: Set<DomainAgentSessionLinkCapability> {
        // The bridge's durable Add always reserves the default managed set, and durable intent
        // restores it as such; a scope that cannot hold it may not create the link at all.
        DomainAgentSessionLinkCapability.managed
    }

    func activeLinkCapabilities(observer: UUID, target: UUID) async -> Set<DomainAgentSessionLinkCapability>? {
        await bridge().delegationActiveLink(observerSessionID: observer, targetSessionID: target)?.capabilities
    }

    func addLink(observer: UUID, target: UUID) async -> SessionAdminLinkOutcome {
        let outcome = await bridge().addMonitorLink(
            pair: AgentSessionOversightIntent(observerSessionID: observer, targetSessionID: target)
        )
        switch outcome {
        case .added: return .linked
        case .alreadyLinked: return .alreadyLinked
        case .failed, .rejected: return .failed(outcome.failureMessage ?? "The link could not be created.")
        }
    }

    func stopLink(
        observer: UUID,
        target: UUID,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome {
        let bridge = bridge()
        guard let link = await bridge.delegationActiveLink(observerSessionID: observer, targetSessionID: target) else {
            return .notLinked
        }
        // The lookup suspended: authority is re-checked right before the ordinary Stop.
        guard isStillAuthorized() else { return .failed("Delegated authority ended before the unlink.") }
        switch await bridge.stopMonitorLink(
            observerSessionID: observer, targetSessionID: target, linkID: link.linkID, generation: link.generation
        ) {
        case .stopped: return .stopped
        case .alreadyStopped: return .notLinked
        case let .failed(message): return .failed(message)
        }
    }

    func setModel(
        sessionID: UUID,
        modelID: String,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome {
        let windows = WindowStatesManager.shared
        guard let candidate = windows.agentSessionLinkCandidates(forSessionIDs: [sessionID], includeLocation: false)[sessionID]?.only,
              let modelCandidate = windows.agentSessionLinkModelCandidate(for: candidate.domainEndpoint)
        else { return .blocked("The target session is not live.") }
        let endpoint = candidate.domainEndpoint
        // Same commit seam as `agent_session_link set_model`; the scope lease is the final fence.
        let outcome = await windows.agentSessionLinkPerformSetModel(
            to: modelCandidate,
            modelID: modelID,
            liveness: {
                let live = windows.agentSessionLinkModelCandidate(for: endpoint) != nil
                return AgentSessionLinkSendLiveness(
                    observerEndpointIsLive: isStillAuthorized(), targetEndpointIsLive: live, targetWindowIsClosing: false
                )
            },
            reauthorize: { isStillAuthorized() ? .committed : .linkRevoked }
        )
        switch outcome {
        case let .accepted(receipt):
            var fields = ["model_id": receipt.modelID, "model": receipt.modelRaw]
            fields["effort"] = receipt.reasoningEffortRaw
            return .applied(changed: receipt.changed, fields: fields)
        case let .blocked(failure):
            return .blocked(failure.rawValue)
        case let .invalid(message):
            return .invalid(message)
        }
    }

    func setEffort(
        sessionID: UUID,
        effort: String,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome {
        guard let viewModel = SessionAdminWindows.owningViewModel(for: sessionID) else {
            return .blocked("The target session is not live.")
        }
        return viewModel.delegationSetReasoningEffort(sessionID: sessionID, effort: effort, isStillAuthorized: isStillAuthorized)
    }

    func fork(sessionID: UUID, upToItemID: UUID?) async throws -> UUID {
        guard let viewModel = SessionAdminWindows.owningViewModel(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        return try await viewModel.delegationFork(sessionID: sessionID, upToItemID: upToItemID)
    }
}

@MainActor
final class SessionAdminWindowsWorktreeHost: SessionAdminWorktreeHost {
    /// Upper bound on one idle-boundary wait; the handler retries a bounded number of times.
    static let maxIdleWait: Duration = .seconds(3600)
    static let idlePollInterval: Duration = .seconds(1)

    private let vcsService: VCSService
    private let resolver: GitRepoTargetResolver

    init(vcsService: VCSService = .shared, resolver: GitRepoTargetResolver = GitRepoTargetResolver()) {
        self.vcsService = vcsService
        self.resolver = resolver
    }

    // MARK: - Repository context of the TARGET session

    private struct TargetContext {
        let viewModel: AgentModeViewModel
        let session: AgentTabSession
        let roots: [WorkspaceRootRef]
        let repos: [GitRepoDescriptor]
        let repo: GitRepoDescriptor
    }

    /// Repositories and roots come from the target's own workspace, never the caller's routing.
    private func targetContext(_ sessionID: UUID, repoRoot: String?) async throws -> TargetContext {
        guard let (viewModel, session) = SessionAdminWindows.liveSession(sessionID),
              let store = viewModel.promptManager?.workspaceFileContextStore
        else { throw SessionAdminHostError.sessionUnavailable }
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        var repos: [GitRepoDescriptor] = []
        var seen: Set<String> = []
        for root in roots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
                if seen.insert(descriptor.rootPath.lowercased()).inserted { repos.append(descriptor) }
            }
        }
        guard let defaultRepo = repos.first else {
            throw SessionAdminHostError.invalid("The target session's workspace has no Git repository.")
        }
        let repo: GitRepoDescriptor
        if let repoRoot {
            do {
                repo = try await resolver.resolveRepoRootToken(repoRoot, allRepos: repos, visibleRoots: roots, defaultRepo: defaultRepo)
            } catch let error as GitRepoTargetResolverError {
                throw SessionAdminHostError.invalid(error.message)
            }
        } else {
            repo = defaultRepo
        }
        return TargetContext(viewModel: viewModel, session: session, roots: roots, repos: repos, repo: repo)
    }

    private func logicalRoot(for repo: GitRepoDescriptor, in context: TargetContext) async throws -> WorkspaceRootRef {
        for root in context.roots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)),
               GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path) == GitRepoRootAuthorization.canonicalPath(repo.rootPath)
            {
                return root
            }
        }
        throw SessionAdminHostError.invalid("The repository is not attached to the target's workspace.")
    }

    // MARK: - Create

    func createWorktree(
        forSession sessionID: UUID,
        repoRoot: String?,
        branch: String?,
        baseRef: String?
    ) async throws -> SessionAdminWorktreeInfo {
        let context = try await targetContext(sessionID, repoRoot: repoRoot)
        let existing = try await vcsService.listGitWorktrees(at: context.repo.rootURL)
        let mainRoot = existing.first(where: \.isMain)?.path ?? context.repo.rootPath
        // On-behalf creation is app-managed only: no explicit or external destination.
        let plan = try GitWorktreeDefaultPathPlanner.plan(GitWorktreeDefaultPathPlanner.Request(
            mainWorktreeRoot: URL(fileURLWithPath: mainRoot),
            existingWorktreeRoots: existing.map { URL(fileURLWithPath: $0.path) },
            explicitPath: nil,
            branch: branch,
            baseRef: baseRef,
            detach: false,
            force: false,
            allowExternalPath: false,
            cloneTrackedCheckout: true,
            copyWorktreeIncludeUntrackedFiles: false,
            purpose: .standaloneCreate(now: Date())
        ))
        // Authorized roots: the target workspace's roots and the repositories resolved from exactly
        // those roots (a root may sit inside its repository), then the app-managed container. This is
        // the on-behalf admission only; `manage_worktree` keeps its own policy unchanged.
        let workspaceRoots = Set(context.roots.map(\.standardizedFullPath) + context.repos.map(\.rootURL.standardizedFileURL.path))
        // Step 1: the source repository must be admitted before anything is created on disk.
        _ = try await DomainMutationPathFence.admit(
            requestedPaths: [context.repo.rootURL.standardizedFileURL.path],
            authorizedRoots: workspaceRoots
        )
        // Step 2: the container is derived from that admitted repository (never from arguments), so it
        // is created only now, then the destination is admitted under it.
        try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [context.repo.rootURL.standardizedFileURL.path, plan.path.standardizedFileURL.path],
            authorizedRoots: workspaceRoots.union([plan.appManagedContainer.standardizedFileURL.path])
        )
        let physicalGuard = DomainMutationPhysicalCommitGuard(snapshot: snapshot)
        let controller = DomainMutationCommitController(physicalMutationGuard: { physicalGuard }, willCommit: {})
        let vcsService = vcsService
        let repoURL = context.repo.rootURL
        let result = try await MCPDomainMutationCommitContext.controllerTaskLocal.withValue(controller) {
            try await vcsService.createGitWorktreeWithResult(request: plan.createRequest, at: repoURL)
        }
        let created = result.descriptor
        return SessionAdminWorktreeInfo(
            worktreeID: created.worktreeID,
            repositoryID: created.repository.repositoryID,
            repoRootPath: context.repo.rootPath,
            path: created.path,
            branch: created.branch,
            isPrunable: created.isPrunable
        )
    }

    // MARK: - Bind / unbind

    func bindWorktree(
        sessionID: UUID,
        worktree selector: String,
        repoRoot: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> SessionAdminWorktreeInfo {
        let context = try await targetContext(sessionID, repoRoot: repoRoot)
        guard isIdle(context.viewModel, context.session) else { throw SessionAdminHostError.notIdle }
        let worktree: GitWorktreeDescriptor
        do {
            worktree = try await resolver.resolveWorktree(
                selector: selector, repo: context.repo, allRepos: context.repos, authorizedRoots: context.roots
            )
        } catch let error as GitRepoTargetResolverError {
            throw SessionAdminHostError.invalid(error.message)
        }
        let repoForWorktree = context.repos.first { $0.repoKey == worktree.repository.repoKey } ?? context.repo
        let logicalRoot = try await logicalRoot(for: repoForWorktree, in: context)
        let existing = context.viewModel.worktreeBindings(forAgentSessionID: sessionID)
        let normalizedRoot = GitRepoRootAuthorization.canonicalPath(logicalRoot.standardizedFullPath)
        let previous = existing.first { GitRepoRootAuthorization.canonicalPath($0.logicalRootPath) == normalizedRoot }
        var desired = existing.filter { GitRepoRootAuthorization.canonicalPath($0.logicalRootPath) != normalizedRoot }
        if !(worktree.isMain && GitRepoRootAuthorization.canonicalPath(worktree.path) == normalizedRoot) {
            desired.append(AgentSessionWorktreeBinding(
                id: previous?.id ?? UUID().uuidString,
                repositoryID: worktree.repository.repositoryID,
                repoKey: worktree.repository.repoKey,
                logicalRootPath: logicalRoot.standardizedFullPath,
                logicalRootName: logicalRoot.name,
                worktreeID: worktree.worktreeID,
                worktreeRootPath: worktree.path,
                commonGitDir: worktree.repository.commonGitDir,
                isMainWorktree: worktree.isMain,
                worktreeName: worktree.name,
                branch: worktree.branch,
                head: worktree.head,
                visualLabel: nil,
                visualColorHex: nil,
                boundAt: previous?.worktreeID == worktree.worktreeID ? previous?.boundAt ?? Date() : Date(),
                source: "session_admin.worktree_bind"
            ))
        }
        try await transition(desired, sessionID: sessionID, viewModel: context.viewModel, isStillAuthorized: isStillAuthorized)
        return SessionAdminWorktreeInfo(
            worktreeID: worktree.worktreeID,
            repositoryID: worktree.repository.repositoryID,
            repoRootPath: repoForWorktree.rootPath,
            path: worktree.path,
            branch: worktree.branch,
            isPrunable: worktree.isPrunable
        )
    }

    func unbindWorktrees(
        sessionID: UUID,
        worktreeID: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> [String] {
        guard let (viewModel, session) = SessionAdminWindows.liveSession(sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        let existing = viewModel.worktreeBindings(forAgentSessionID: sessionID)
        let removed = existing.filter { worktreeID == nil || $0.worktreeID == worktreeID }
        guard !removed.isEmpty else { return [] }
        guard isIdle(viewModel, session) else { throw SessionAdminHostError.notIdle }
        let remaining = existing.filter { worktreeID != nil && $0.worktreeID != worktreeID }
        try await transition(remaining, sessionID: sessionID, viewModel: viewModel, isStillAuthorized: isStillAuthorized)
        return removed.map(\.worktreeID)
    }

    /// Authority is evaluated synchronously right before the transition and again at its
    /// `beforeCommit` fence, after its preparation suspensions, so a revocation or a membership change
    /// that lands before the fence aborts it. As with `manage_worktree`, the transition may still await
    /// recovery handoff and provider-context invalidation after the fence, before it publishes.
    private func transition(
        _ desired: [AgentSessionWorktreeBinding],
        sessionID: UUID,
        viewModel: AgentModeViewModel,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws {
        guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                desired, forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: { guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded } }
            )
        } catch SessionAdminHostError.authorityEnded {
            throw SessionAdminHostError.authorityEnded
        } catch {
            // A run that started during preparation refuses the transition; that is "not idle".
            if let session = try? viewModel.authoritativeLiveSession(for: sessionID), !isIdle(viewModel, session) {
                throw SessionAdminHostError.notIdle
            }
            throw error
        }
    }

    func boundWorktrees(sessionID: UUID) -> [AgentSessionWorktreeBindingSummary] {
        if let (viewModel, _) = SessionAdminWindows.liveSession(sessionID) {
            return viewModel.worktreeBindings(forAgentSessionID: sessionID).worktreeBindingSummaries
        }
        return SessionAdminWindows.owningViewModel(for: sessionID)?
            .ownerValidatedSessionIndex[sessionID]?.worktreeBindingSummaries ?? []
    }

    func isIdleForWorktreeTransition(sessionID: UUID) -> Bool {
        guard let (viewModel, session) = SessionAdminWindows.liveSession(sessionID) else { return false }
        return isIdle(viewModel, session)
    }

    private func isIdle(_ viewModel: AgentModeViewModel, _ session: AgentTabSession) -> Bool {
        (try? viewModel.requireIdleWorktreeBindingTransition(session)) != nil
    }

    /// Observation only: samples the exact gate the binding transition uses until it would admit,
    /// the session disappears, or the bounded wait elapses. It never touches session state.
    func waitForIdleBoundary(sessionID: UUID) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.maxIdleWait)
        while clock.now < deadline, !Task.isCancelled {
            guard let (viewModel, session) = SessionAdminWindows.liveSession(sessionID) else { return }
            if isIdle(viewModel, session) { return }
            try? await Task.sleep(for: Self.idlePollInterval)
        }
    }

    func allBoundWorktrees() -> [String: Set<UUID>] {
        var result: [String: Set<UUID>] = [:]
        for window in WindowStatesManager.shared.allWindows where !window.isClosing {
            for entry in window.agentModeViewModel.ownerValidatedSessionIndex.values {
                for summary in entry.worktreeBindingSummaries {
                    result[summary.worktreeID, default: []].insert(entry.id)
                }
            }
        }
        return result
    }

    /// Git's own prunable status (the same `git worktree list` the `manage_worktree list` op reads).
    /// A worktree git no longer lists at all is reported prunable.
    func isWorktreePrunable(path: String, repoRoot: String?) async -> Bool {
        guard let repoRoot,
              let worktrees = try? await vcsService.listGitWorktrees(at: URL(fileURLWithPath: repoRoot))
        else { return !FileManager.default.fileExists(atPath: path) }
        let target = GitRepoRootAuthorization.canonicalPath(path)
        guard let match = worktrees.first(where: { GitRepoRootAuthorization.canonicalPath($0.path) == target }) else {
            return true
        }
        return match.isPrunable
    }

    // MARK: - Merge

    func previewMerge(sessionID: UUID, repoRoot: String?, mergeTarget: String?) async throws -> Value {
        guard let (viewModel, _) = SessionAdminWindows.liveSession(sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        let preview = try await viewModel.previewWorktreeMerge(
            sessionID: sessionID, repoRoot: repoRoot, target: mergeTarget ?? "@main"
        )
        return try SessionAdminReply.encoded(preview)
    }

    func applyMerge(sessionID: UUID, operationID: String) async throws -> Value {
        guard let (viewModel, _) = SessionAdminWindows.liveSession(sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        // Fence the merge's source and target worktrees to the target session's workspace roots and
        // their repositories, as `createWorktree` does; the user still decides in the review prompt.
        let operation = try viewModel.statusWorktreeMerge(sessionID: sessionID, operationID: operationID)
        let context = try await targetContext(sessionID, repoRoot: nil)
        var authorizedRoots = Set(context.roots.map(\.standardizedFullPath) + context.repos.map(\.rootURL.standardizedFileURL.path))
        for endpoint in [operation.source, operation.target] {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: endpoint.path)),
               context.repos.contains(where: {
                   GitRepoRootAuthorization.canonicalPath($0.rootPath) == GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path)
               })
            {
                // A linked worktree of an admitted repository lives outside the workspace roots.
                authorizedRoots.insert(URL(fileURLWithPath: endpoint.path).standardizedFileURL.path)
            }
        }
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [operation.source.path, operation.target.path],
            authorizedRoots: authorizedRoots
        )
        let physicalGuard = DomainMutationPhysicalCommitGuard(snapshot: snapshot)
        let controller = DomainMutationCommitController(physicalMutationGuard: { physicalGuard }, willCommit: {})
        let result = try await MCPDomainMutationCommitContext.controllerTaskLocal.withValue(controller) {
            try await viewModel.requestWorktreeMergeReviewAndApply(sessionID: sessionID, operationID: operationID)
        }
        return try SessionAdminReply.encoded(result)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
