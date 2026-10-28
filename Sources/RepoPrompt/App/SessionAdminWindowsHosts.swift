import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptVCS
import RepoPromptWorkspaceCore

/// Production hosts over every open window. Each effect routes to the window that owns the target
/// session and to the existing owner of that state; nothing here authorizes.
@MainActor
enum SessionAdminWindows {
    static func runtimeOwner(for sessionID: UUID) -> AgentSessionCarrierResolver.RuntimeOwner? {
        AgentSessionCarrierResolver.capture(
            windows: WindowStatesManager.shared.sessionRuntimeWindows, sessionIDs: [sessionID], includeRuntimeOwners: true
        ).uniqueRuntimeOwners[sessionID]
    }

    static func isCurrent(_ owner: AgentSessionCarrierResolver.RuntimeOwner) -> Bool {
        guard let current = runtimeOwner(for: owner.location.sessionID) else { return false }
        return owner.matches(current)
    }

    static func owningViewModel(for sessionID: UUID) -> AgentModeViewModel? {
        let capture = AgentSessionCarrierResolver.capture(
            windows: WindowStatesManager.shared.sessionRuntimeWindows, sessionIDs: [sessionID], includeRuntimeOwners: true
        )
        guard !capture.ambiguousSessionIDs.contains(sessionID) else { return nil }
        if let owner = capture.uniqueRuntimeOwners[sessionID] { return owner.location.window.agentModeViewModel }
        guard !capture.replicatedSessionIDs.contains(sessionID) else { return nil }
        return capture.uniqueLocations[sessionID]?.window.agentModeViewModel
            ?? capture.metadata[sessionID]?.only?.window.agentModeViewModel
    }

    static func liveSession(_ sessionID: UUID) -> (AgentModeViewModel, AgentTabSession)? {
        guard let owner = runtimeOwner(for: sessionID) else { return nil }
        return (owner.location.window.agentModeViewModel, owner.session)
    }
}

/// A saved carrier witness, not a permission. Preparation borrows its workspace/tab in a private
/// runtime composition; the real tab, stash and active workspace are never edited.
@MainActor
struct SavedOversightSessionLocation {
    weak var window: WindowState?
    let workspace: WorkspaceModel
    let tab: ComposeTabState
    let stashedTabID: UUID?
    let entry: AgentSessionIndexEntry

    var isCurrent: Bool {
        guard let window,
              let current = window.workspaceManager.workspace(withID: workspace.id) else { return false }
        if window.workspaceManager.activeWorkspaceID == workspace.id,
           let latest = window.agentModeViewModel.ownerValidatedSessionIndex[entry.id],
           latest.tabID != entry.tabID || latest.parentSessionID != entry.parentSessionID
           || latest.createdByOverseerSessionID != entry.createdByOverseerSessionID
           || latest.organizationalParentID != entry.organizationalParentID
           || latest.delegationScopeID != entry.delegationScopeID { return false }
        let tabs = current.composeTabs.filter { $0.id == tab.id }
        let stashes = current.stashedTabs.filter { $0.tab.id == tab.id }
        // The target's carrier and provenance matter, not the other chat currently displayed
        // in it. Stashing/unstashing is UI placement, not withdrawal of managed-task consent.
        return tabs.count + stashes.count == 1
    }

    func agreesOnCarrierAndProvenance(with other: Self) -> Bool {
        workspace.id == other.workspace.id && tab.id == other.tab.id
            && entry.parentSessionID == other.entry.parentSessionID
            && entry.createdByOverseerSessionID == other.entry.createdByOverseerSessionID
            && entry.organizationalParentID == other.entry.organizationalParentID
            && entry.delegationScopeID == other.entry.delegationScopeID
    }

    var runtimeWorkspace: WorkspaceModel {
        var copy = workspace
        var carrier = tab
        carrier.name = entry.name
        carrier.activeAgentSessionID = entry.id
        copy.composeTabs = [carrier]
        copy.stashedTabs = []
        copy.activeComposeTabID = carrier.id
        return copy
    }
}

@MainActor
final class SessionAdminWindowsStructureHost: SessionAdminStructureHost {
    /// Outcome of preparing a saved or never-visited session without opening its tab.
    enum ForkPreparation: Equatable {
        case ready, missing, ambiguous, changed, unreadable
    }

    typealias Preparation = @MainActor (UUID, @escaping @MainActor () -> Bool) async -> ForkPreparation

    private let bridge: () -> AgentSessionLinkRuntimeBridge
    private let preparation: Preparation?

    /// Production preparation: the targeted-oversight path (point read, no tab focus, no provider run).
    static let savedTargetPreparation: Preparation = { target, isStillAuthorized in
        switch await WindowStatesManager.shared.prepareSavedOversightTarget(target, isStillAuthorized: isStillAuthorized) {
        case .success: .ready
        case .failure(.missing): .missing
        case .failure(.ambiguous): .ambiguous
        case .failure(.changed): .changed
        case .failure(.unreadable): .unreadable
        }
    }

    init(
        bridge: @escaping () -> AgentSessionLinkRuntimeBridge = { AgentSessionLinkRuntimeBridge.shared },
        preparation: Preparation? = SessionAdminWindowsStructureHost.savedTargetPreparation
    ) {
        self.bridge = bridge
        self.preparation = preparation
    }

    /// Prepares a saved or never-visited target (no tab focus, no provider run). nil when the
    /// target is live or ready; otherwise the refusal to report.
    private func prepareIfUnloaded(
        _ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome? {
        guard SessionAdminWindows.liveSession(sessionID) == nil, let preparation else { return nil }
        let outcome = await preparation(sessionID, isStillAuthorized)
        guard isStillAuthorized() else { return .blocked("Delegated authority ended while preparing the target.") }
        return outcome == .ready ? nil : .invalid(Self.preparationDetail(outcome))
    }

    static func preparationRefusal(_ reason: ForkPreparation) -> SessionAdminHostError {
        let code = switch reason {
        case .ready, .changed: "target_changed"
        case .missing: "target_missing"
        case .ambiguous: "target_ambiguous"
        case .unreadable: "target_unreadable"
        }
        let next: Value? = reason == .missing
            ? .object(["tool": .string("session_admin"), "arguments": .object(["op": .string("inventory")])])
            : nil
        return .refused(code: code, detail: preparationDetail(reason), nextCall: next)
    }

    static func preparationDetail(_ reason: ForkPreparation) -> String {
        switch reason {
        case .ready: "The source session is ready."
        case .missing: "The source session was not found in any loaded workspace. Check its ID with session_admin inventory."
        case .ambiguous: "The source session is open in more than one place. Close the duplicate tab, then retry."
        case .changed: "The source session moved or changed while being prepared. Retry fork."
        case .unreadable: "The source session's saved transcript could not be read, so it cannot be forked."
        }
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

    func addLink(
        observer: UUID,
        target: UUID,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome {
        await addLink(observer: observer, target: target, sourceScopeID: nil, isStillAuthorized: isStillAuthorized)
    }

    func addLink(
        observer: UUID, target: UUID, sourceScopeID: UUID?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLinkOutcome {
        guard !Task.isCancelled, isStillAuthorized() else { return .revoked }
        let manager = WindowStatesManager.shared
        let initialObservers = WindowStatesManager.shared.agentSessionLinkCandidates(forSessionIDs: [observer], includeLocation: false)
        guard let initialObserver = initialObservers[observer]?.only?.domainEndpoint else {
            return .failed("observer_changed: The requesting session has no exact current binding; nothing was linked.")
        }
        manager.beginPreparedOversightPreparation(target)
        defer { manager.endPreparedOversightPreparation(target) }
        let prepared = await manager.prepareSavedOversightTarget(target, isStillAuthorized: isStillAuthorized)
        guard isStillAuthorized(), !Task.isCancelled else { return .revoked }
        guard case let .success(owner) = prepared,
              let location = manager.preparedOversightLocations[target], location.isCurrent
        else {
            let code = if case let .failure(reason) = prepared { reason.rawValue } else { "target_binding_changed" }
            return .failed("\(code): The exact saved target could not be prepared. Ask the user to check whether it was deleted, moved or has conflicting saved copies; nothing was linked.")
        }
        guard !owner.isClosing else { return .revoked }
        // Re-read after hydration: no captured endpoint, deletion state or ambiguity claim earns a link.
        let current = AgentSessionCarrierResolver.capture(windows: WindowStatesManager.shared.allWindows, sessionIDs: [target])
        guard !current.ambiguousSessionIDs.contains(target), !current.replicatedSessionIDs.contains(target) else {
            return .failed("target_ambiguous: Target ownership changed during preparation. Use session_admin inventory; nothing was linked.")
        }
        let candidates = WindowStatesManager.shared.agentSessionLinkCandidates(
            forSessionIDs: [observer, target], includeLocation: false
        )
        guard let observerEndpoint = candidates[observer]?.only?.domainEndpoint, observerEndpoint == initialObserver else {
            return .failed("observer_changed: The requesting session's exact binding changed; nothing was linked.")
        }
        guard let targetEndpoint = candidates[target]?.only?.domainEndpoint,
              targetEndpoint.windowID == owner.windowID,
              targetEndpoint.workspaceID == location.workspace.id, targetEndpoint.tabID == location.tab.id,
              location.isCurrent,
              !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: target),
              !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: target)
        else { return .failed("target_unloaded_unpreparable: The exact target binding changed during preparation. Use session_admin inventory; nothing was linked.") }
        let outcome = await bridge().addDelegatedMonitorLink(
            observerEndpoint: observerEndpoint,
            targetEndpoint: targetEndpoint,
            authorization: AgentSessionLinkDelegatedAddAuthorization(sourceScopeID: sourceScopeID, isCurrent: isStillAuthorized)
        )
        switch outcome {
        case .added, .alreadyLinked:
            if manager.hasPreparedRuntime(target) {
                manager.preparedOversightConsentPairs[target, default: []].update(with: .init(observerSessionID: observer, targetSessionID: target, sourceScopeID: sourceScopeID))
            }
            if case .added = outcome { return .linked }
            return .alreadyLinked
        case let .failed(failure):
            return .refused(failure)
        case .rejected:
            let message = outcome.failureMessage ?? "The link could not be created."
            // `.revoked` promises nothing was left behind; a compensation that could not be written
            // left a row queued for **Retry saving**, so it is reported as the failure it is.
            if !isStillAuthorized(), message != AgentSessionOversightPersistenceCopy.addCompensationFailed {
                return .revoked
            }
            return .failed(message)
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
            observerSessionID: observer, targetSessionID: target, linkID: link.linkID, generation: link.generation,
            isStillAuthorized: isStillAuthorized
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
        if let refusal = await prepareIfUnloaded(sessionID, isStillAuthorized: isStillAuthorized) { return refusal }
        let windows = WindowStatesManager.shared
        guard let owner = SessionAdminWindows.runtimeOwner(for: sessionID),
              let candidate = windows.agentSessionLinkCandidates(forSessionIDs: [sessionID], includeLocation: false)[sessionID]?.only,
              candidate.windowID == owner.location.window.windowID,
              let modelCandidate = windows.agentSessionLinkModelCandidate(for: candidate.domainEndpoint)
        else { return .blocked("The target session is not live.") }
        let endpoint = candidate.domainEndpoint
        // Same commit seam as `agent_session_link set_model`; the scope lease is the final fence.
        let outcome = await windows.agentSessionLinkPerformSetModel(
            to: modelCandidate,
            modelID: modelID,
            liveness: {
                let live = SessionAdminWindows.isCurrent(owner) && windows.agentSessionLinkModelCandidate(for: endpoint) != nil
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
        case let .refused(_, detail, _):
            return .invalid(detail)
        case let .invalid(message):
            return .invalid(message)
        }
    }

    func setEffort(
        sessionID: UUID,
        effort: String,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> SessionAdminLifecycleOutcome {
        if let refusal = await prepareIfUnloaded(sessionID, isStillAuthorized: isStillAuthorized) { return refusal }
        guard let owner = SessionAdminWindows.runtimeOwner(for: sessionID) else {
            return .blocked("The target session is not live.")
        }
        return owner.location.window.agentModeViewModel.delegationSetReasoningEffort(
            sessionID: sessionID, effort: effort,
            isStillAuthorized: { isStillAuthorized() && SessionAdminWindows.isCurrent(owner) }
        )
    }

    func fork(
        sessionID: UUID, upToItemID: UUID?, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> UUID {
        // A saved or never-visited source is prepared the same way targeted oversight prepares
        // one: point read, no tab focus, no provider run. Authority is re-checked throughout.
        if SessionAdminWindows.liveSession(sessionID) == nil, let preparation {
            let outcome = await preparation(sessionID, isStillAuthorized)
            guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
            guard outcome == .ready else { throw Self.preparationRefusal(outcome) }
        }
        guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
        guard let viewModel = SessionAdminWindows.owningViewModel(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        return try await viewModel.delegationFork(
            sessionID: sessionID, upToItemID: upToItemID, isStillAuthorized: isStillAuthorized
        )
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

    /// The target's placement, canonical discovery, and binding authority, captured before discovery suspends.
    /// Capture elects nothing and requires no hydrated bindings: merge apply needs only its admission roots.
    @MainActor
    private struct TargetCapture {
        let owner: AgentSessionCarrierResolver.RuntimeOwner
        let workspaceID: UUID
        let repoPaths: [String]
        /// Canonical (logical) roots of the target's workspace.
        let roots: [WorkspaceRootRef]
        /// Repositories resolved from exactly those roots, deduplicated by checkout path.
        let repos: [GitRepoDescriptor]
        let repoByRootPath: [String: GitRepoDescriptor]
        /// Read synchronously with placement, so a binding change during discovery is detected.
        let bindingSource: AgentWorkspaceLookupContextSource

        var viewModel: AgentModeViewModel {
            owner.location.window.agentModeViewModel
        }

        var session: AgentTabSession {
            owner.session
        }

        /// Runtime owner, workspace, and declared root order (PRIMARY moves on reorder).
        var isPlacementCurrent: Bool {
            SessionAdminWindows.isCurrent(owner)
                && viewModel.workspaceManager?.activeWorkspace?.id == workspaceID
                && viewModel.workspaceManager?.activeWorkspace?.repoPaths == repoPaths
        }

        /// The target's hydration and binding set still match the capture.
        var isBindingCurrent: Bool {
            Self.bindingSource(viewModel, sessionID: owner.location.sessionID).identity == bindingSource.identity
        }

        static func bindingSource(_ viewModel: AgentModeViewModel, sessionID: UUID) -> AgentWorkspaceLookupContextSource {
            AgentWorkspaceLookupContextSource(
                activeAgentSessionID: sessionID,
                worktreeBindingState: viewModel.worktreeBindingState(forAgentSessionID: sessionID)
            )
        }
    }

    /// Create/bind authority: the capture's hydrated target bindings and the validated lookup they project to.
    @MainActor
    private struct TargetAuthority {
        let capture: TargetCapture
        let bindings: [AgentSessionWorktreeBinding]
        let election: WorkspaceDefaultGitRepositoryElection.Snapshot

        /// Checked only before a commit fence: a transition's own publication is not supersession.
        var isCurrent: Bool {
            capture.isPlacementCurrent && capture.isBindingCurrent
        }
    }

    /// A real selected repository where Git executes. `logicalRoot` is set when election chose it, so binding
    /// attribution never rediscovers it by load order; explicit selections use the existing first-match rule.
    private struct TargetRepository {
        let repo: GitRepoDescriptor
        let logicalRoot: WorkspaceRootRef?
        /// The elected checkout itself, already validated against the target's binding identity.
        let electedCheckout: GitRepoDescriptor?
    }

    /// A saved or never-visited target is prepared (no tab focus, no provider run) before an
    /// on-behalf worktree change, instead of being refused as unavailable.
    private func prepareIfUnloaded(_ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool) async throws {
        guard SessionAdminWindows.liveSession(sessionID) == nil else { return }
        let outcome = await SessionAdminWindowsStructureHost.savedTargetPreparation(sessionID, isStillAuthorized)
        guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
        guard outcome == .ready else { throw SessionAdminWindowsStructureHost.preparationRefusal(outcome) }
    }

    /// Roots and repositories come from the target's own workspace, never the caller's routing.
    private func captureTarget(_ sessionID: UUID) async throws -> TargetCapture {
        guard let owner = SessionAdminWindows.runtimeOwner(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        let viewModel = owner.location.window.agentModeViewModel
        guard let workspace = viewModel.workspaceManager?.activeWorkspace,
              let store = viewModel.promptManager?.workspaceFileContextStore
        else { throw SessionAdminHostError.sessionUnavailable }
        let bindingSource = TargetCapture.bindingSource(viewModel, sessionID: sessionID)
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        var repos: [GitRepoDescriptor] = []
        var repoByRootPath: [String: GitRepoDescriptor] = [:]
        var seen: Set<String> = []
        for root in roots {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: root.standardizedFullPath)) {
                let descriptor = GitRepoDescriptor(rootURL: resolved.rootURL)
                repoByRootPath[root.standardizedFullPath] = descriptor
                if seen.insert(descriptor.rootPath.lowercased()).inserted { repos.append(descriptor) }
            }
        }
        let capture = TargetCapture(
            owner: owner, workspaceID: workspace.id, repoPaths: workspace.repoPaths,
            roots: roots, repos: repos, repoByRootPath: repoByRootPath, bindingSource: bindingSource
        )
        guard capture.isPlacementCurrent else { throw SessionAdminHostError.authorityEnded }
        return capture
    }

    /// Create/bind require the target's authoritative, hydrated bindings and their validated projection
    /// (`requiredLookupContext`), even when the selector is explicit; only default election is optional.
    private func resolveTargetAuthority(_ sessionID: UUID) async throws -> TargetAuthority {
        let capture = try await captureTarget(sessionID)
        guard !capture.repos.isEmpty else {
            throw SessionAdminHostError.invalid("The target session's workspace has no Git repository.")
        }
        guard capture.session.permitsBoundOperationAndSave else { throw SessionAdminHostError.sessionUnavailable }
        guard case let .hydrated(bindings) = capture.bindingSource.worktreeBindingState else {
            throw SessionAdminHostError.invalid(WorkspaceLookupContextResolutionError.unknownBindingState.localizedDescription)
        }
        guard let store = capture.viewModel.promptManager?.workspaceFileContextStore else {
            throw SessionAdminHostError.sessionUnavailable
        }
        let lookupContext: WorkspaceLookupContext
        do {
            lookupContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: capture.bindingSource, visibleRoots: capture.roots, store: store
            )
        } catch let error as WorkspaceLookupContextResolutionError {
            guard capture.isPlacementCurrent, capture.isBindingCurrent else { throw SessionAdminHostError.authorityEnded }
            throw SessionAdminHostError.invalid(error.localizedDescription)
        }
        let lookupRoots = await store.rootRefs(scope: lookupContext.rootScope)
        try Task.checkCancellation()
        guard capture.isPlacementCurrent, capture.isBindingCurrent else { throw SessionAdminHostError.authorityEnded }
        return TargetAuthority(
            capture: capture,
            bindings: bindings,
            election: .init(
                workspaceID: capture.workspaceID,
                declaredRepoPaths: capture.repoPaths,
                bindingSource: capture.bindingSource,
                lookupContext: lookupContext,
                lookupRoots: lookupRoots
            )
        )
    }

    /// The target's default repository: its sole binding's checkout, or declared PRIMARY with no bindings.
    /// A superseded attempt fails rather than retargeting.
    private func electDefaultRepository(_ authority: TargetAuthority) async throws -> WorkspaceDefaultGitRepositoryElection.Selection {
        let selection: WorkspaceDefaultGitRepositoryElection.Selection
        do {
            selection = try await WorkspaceDefaultGitRepositoryElection(vcsService: vcsService).elect(in: authority.election)
        } catch let failure as WorkspaceDefaultGitRepositoryElection.Failure {
            guard authority.isCurrent else { throw SessionAdminHostError.authorityEnded }
            throw SessionAdminHostError.invalid(failure.localizedDescription)
        } catch let error as WorkspaceLookupContextResolutionError {
            guard authority.isCurrent else { throw SessionAdminHostError.authorityEnded }
            throw SessionAdminHostError.invalid(error.localizedDescription)
        }
        guard authority.isCurrent else { throw SessionAdminHostError.authorityEnded }
        return selection
    }

    /// The repository `repo_root` names, else the elected default. Explicit tokens keep the host's canonical
    /// roots and raw selector semantics (a canonical path is never replaced by its bound checkout); only an
    /// omitted or relative token (bare `@main`, `@current`, `@wt`) elects.
    private func resolveRepository(_ repoRoot: String?, authority: TargetAuthority) async throws -> TargetRepository {
        let capture = authority.capture
        guard let repoRoot else {
            let selection = try await electDefaultRepository(authority)
            return TargetRepository(repo: selection.repository, logicalRoot: selection.logicalRoot, electedCheckout: selection.repository)
        }
        do {
            do {
                let repo = try await resolver.resolveRepoRootToken(
                    repoRoot, allRepos: capture.repos, visibleRoots: capture.roots, defaultRepo: nil
                )
                return TargetRepository(repo: repo, logicalRoot: nil, electedCheckout: nil)
            } catch is GitRepoTargetResolver.DefaultRepositoryRequired {
                let selection = try await electDefaultRepository(authority)
                let repo = try await resolver.resolveRepoRootToken(
                    repoRoot, allRepos: capture.repos, visibleRoots: capture.roots, defaultRepo: selection.repository
                )
                return TargetRepository(repo: repo, logicalRoot: selection.logicalRoot, electedCheckout: selection.repository)
            }
        } catch let error as GitRepoTargetResolverError {
            throw SessionAdminHostError.invalid(error.message)
        }
    }

    /// Resolves `worktree` against the `repo_root` repository when one was named. Otherwise an identifying
    /// selector (`@id:`, `@branch:`, name, branch, or path) searches the target's repositories and is attributed
    /// to the worktree's own repository; a relative one (`@current`, `@main[:<branch>]`, `@wt`) uses the elected
    /// default and its logical root.
    private func resolveWorktree(
        _ selector: String,
        repository: TargetRepository?,
        authority: TargetAuthority
    ) async throws -> (worktree: GitWorktreeDescriptor, target: TargetRepository) {
        let capture = authority.capture
        do {
            if let repository {
                let worktree = try await resolver.resolveWorktree(
                    selector: selector, repo: repository.repo, allRepos: capture.repos, authorizedRoots: capture.roots
                )
                guard repository.logicalRoot == nil else { return (worktree, repository) }
                let repo = capture.repos.first { $0.repoKey == worktree.repository.repoKey } ?? repository.repo
                return (worktree, TargetRepository(repo: repo, logicalRoot: nil, electedCheckout: nil))
            }
            do {
                let worktree = try await resolver.resolveWorktree(
                    selector: selector, repo: nil, allRepos: capture.repos, authorizedRoots: capture.roots
                )
                return try (worktree, owningRepository(of: worktree, in: capture))
            } catch is GitRepoTargetResolver.DefaultRepositoryRequired {
                let selection = try await electDefaultRepository(authority)
                let worktree = try await resolver.resolveWorktree(
                    selector: selector, repo: selection.repository, allRepos: capture.repos, authorizedRoots: capture.roots
                )
                return (worktree, TargetRepository(
                    repo: selection.repository, logicalRoot: selection.logicalRoot, electedCheckout: selection.repository
                ))
            }
        } catch let error as GitRepoTargetResolverError {
            throw SessionAdminHostError.invalid(error.message)
        }
    }

    /// The workspace repository an identified worktree belongs to, by identity rather than discovery order: the
    /// repository that is the worktree itself, else the one sharing its repository identity. Several loaded
    /// checkouts of that repository are ambiguous; never pick one by load order.
    private func owningRepository(of worktree: GitWorktreeDescriptor, in capture: TargetCapture) throws -> TargetRepository {
        let worktreePath = GitRepoRootAuthorization.canonicalPath(worktree.path)
        if let exact = capture.repos.first(where: { GitRepoRootAuthorization.canonicalPath($0.rootPath) == worktreePath }) {
            return TargetRepository(repo: exact, logicalRoot: nil, electedCheckout: nil)
        }
        let owners = capture.repos.filter { $0.worktreeIdentity?.repository.repositoryID == worktree.repository.repositoryID }
        guard let owner = owners.first else {
            throw SessionAdminHostError.invalid("The repository is not attached to the target's workspace.")
        }
        guard owners.count == 1 else {
            throw SessionAdminHostError.invalid(
                "Worktree \(worktree.path) belongs to a repository with \(owners.count) checkouts in the target's workspace (\(owners.map(\.rootPath).joined(separator: ", "))). Pass repo_root to choose the workspace root it binds under."
            )
        }
        return TargetRepository(repo: owner, logicalRoot: nil, electedCheckout: nil)
    }

    /// First workspace root, in installation order, whose repository is `repo` (the existing explicit rule).
    private func logicalRoot(for repo: GitRepoDescriptor, in capture: TargetCapture) throws -> WorkspaceRootRef {
        let repoPath = GitRepoRootAuthorization.canonicalPath(repo.rootPath)
        for root in capture.roots {
            if let resolved = capture.repoByRootPath[root.standardizedFullPath],
               GitRepoRootAuthorization.canonicalPath(resolved.rootPath) == repoPath
            {
                return root
            }
        }
        throw SessionAdminHostError.invalid("The repository is not attached to the target's workspace.")
    }

    /// The repository reported to callers and replayed by `next_call`: the executing repository when it is a
    /// workspace repository, else the canonical repository of the elected logical root (never a bound checkout
    /// that an explicit `repo_root` could not name).
    private func reportedRepositoryRoot(_ target: TargetRepository, in capture: TargetCapture) -> String {
        let executing = GitRepoRootAuthorization.canonicalPath(target.repo.rootPath)
        if capture.repos.contains(where: { GitRepoRootAuthorization.canonicalPath($0.rootPath) == executing }) {
            return target.repo.rootPath
        }
        if let logicalRoot = target.logicalRoot, let canonical = capture.repoByRootPath[logicalRoot.standardizedFullPath] {
            return canonical.rootPath
        }
        return target.repo.rootPath
    }

    // MARK: - Create

    func createWorktree(
        forSession sessionID: UUID,
        repoRoot: String?,
        branch: String?,
        baseRef: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> SessionAdminWorktreeInfo {
        try await prepareIfUnloaded(sessionID, isStillAuthorized: isStillAuthorized)
        let authority = try await resolveTargetAuthority(sessionID)
        let capture = authority.capture
        let target = try await resolveRepository(repoRoot, authority: authority)
        // Placement and the target's bindings must hold until the Git commit fence. A committed worktree is
        // returned even if authority changes afterwards, so the handler can record its ownership.
        let authorize: @MainActor () throws -> Void = {
            guard isStillAuthorized(), authority.isCurrent
            else { throw SessionAdminHostError.authorityEnded }
        }
        try authorize()
        let existing = try await vcsService.listGitWorktrees(at: target.repo.rootURL)
        try authorize()
        let mainRoot = existing.first(where: \.isMain)?.path ?? target.repo.rootPath
        // Refusals name the checkout Git runs in, plus the workspace root it serves when that differs.
        let executionRepository = target.repo.rootURL.standardizedFileURL.path
        let servedWorkspaceRoot = target.logicalRoot.map(\.standardizedFullPath).flatMap { root in
            GitRepoRootAuthorization.canonicalPath(root) == GitRepoRootAuthorization.canonicalPath(executionRepository) ? nil : root
        }
        if let branch, let holder = existing.first(where: { $0.branch.map(Self.shortBranch) == Self.shortBranch(branch) }) {
            throw SessionAdminHostError.refused(
                code: "branch_exists",
                detail: Self.branchExistsDetail(
                    branch, repository: executionRepository, workspaceRoot: servedWorkspaceRoot,
                    checkedOutAt: holder.path, provenBeforeCreation: true
                ),
                nextCall: .object(["tool": .string("session_admin"), "arguments": .object([
                    "op": .string("worktree_bind"), "session_id": .string(sessionID.uuidString), "worktree": .string(holder.path)
                ])])
            )
        }
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
        // those roots (a root may sit inside its repository), plus an elected checkout the target is bound
        // to, then the app-managed container. This is the on-behalf admission only; `manage_worktree` keeps
        // its own policy unchanged.
        var workspaceRoots = Set(capture.roots.map(\.standardizedFullPath) + capture.repos.map(\.rootURL.standardizedFileURL.path))
        if let electedCheckout = target.electedCheckout {
            workspaceRoots.insert(electedCheckout.rootURL.standardizedFileURL.path)
        }
        // Step 1: the source repository must be admitted before anything is created on disk.
        _ = try await DomainMutationPathFence.admit(
            requestedPaths: [target.repo.rootURL.standardizedFileURL.path],
            authorizedRoots: workspaceRoots
        )
        // Step 2: the container is derived from that admitted repository (never from arguments), so it
        // is created only now, then the destination is admitted under it.
        try authorize()
        try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [target.repo.rootURL.standardizedFileURL.path, plan.path.standardizedFileURL.path],
            authorizedRoots: workspaceRoots.union([plan.appManagedContainer.standardizedFileURL.path])
        )
        let physicalGuard = DomainMutationPhysicalCommitGuard(snapshot: snapshot)
        let controller = DomainMutationCommitController(physicalMutationGuard: { physicalGuard }, willCommit: {})
        let vcsService = vcsService
        let repoURL = target.repo.rootURL
        let result: GitWorktreeCreateResult
        do {
            result = try await MCPDomainMutationCommitContext.controllerTaskLocal.withValue(controller) {
                try await vcsService.createGitWorktreeWithResult(
                    request: plan.createRequest, at: repoURL, beforeCommit: { try await authorize() }
                )
            }
        } catch let error as GitService.GitError where error.worktreeCreateFailure != nil {
            // The Git service classifies its creation failures where the evidence is. Only its preflight refusal
            // proves nothing was created; Git's own failure past the commit fence does not.
            if let branch, let failure = error.worktreeCreateFailure, failure.branchExists {
                throw SessionAdminHostError.refused(
                    code: "branch_exists",
                    detail: Self.branchExistsDetail(
                        branch, repository: executionRepository, workspaceRoot: servedWorkspaceRoot,
                        checkedOutAt: nil, provenBeforeCreation: failure.refusedBeforeCreation
                    ),
                    nextCall: nil
                )
            }
            throw servedWorkspaceRoot.map { error.naming(workspaceRoot: $0, servedBy: executionRepository) } ?? error
        }
        let created = result.descriptor
        return SessionAdminWorktreeInfo(
            worktreeID: created.worktreeID,
            repositoryID: created.repository.repositoryID,
            repoRootPath: reportedRepositoryRoot(target, in: capture),
            path: created.path,
            branch: created.branch,
            isPrunable: created.isPrunable
        )
    }

    static func shortBranch(_ name: String) -> String {
        name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
    }

    /// `repository` is the checkout Git runs in; `workspaceRoot` is the root it serves, given only when it differs.
    /// "Nothing was created" is claimed only for a refusal proven before creation.
    static func branchExistsDetail(
        _ branch: String,
        repository: String,
        workspaceRoot: String?,
        checkedOutAt path: String?,
        provenBeforeCreation: Bool
    ) -> String {
        let location = workspaceRoot.map { "repository \(repository) (for workspace root \($0))" } ?? "repository \(repository)"
        let outcome = provenBeforeCreation
            ? "Nothing was created."
            : "Git reported this while adding the worktree, after the pre-creation checks passed; inspect that repository's worktrees before retrying."
        if let path {
            return "Branch '\(branch)' already exists in \(location) and is checked out at \(path). Bind that worktree with worktree_bind {worktree: \"\(path)\"}, or pass a new branch name. \(outcome)"
        }
        return "Branch '\(branch)' already exists in \(location). Pass a new branch name, or omit branch to get a generated one. \(outcome)"
    }

    // MARK: - Bind / unbind

    func bindWorktree(
        sessionID: UUID,
        worktree selector: String,
        repoRoot: String?,
        isStillAuthorized: @escaping @MainActor () -> Bool,
        admitBindings: @escaping @MainActor (Set<String>) throws -> Void,
        bindingsCommitted: @escaping @MainActor (Set<String>) -> Void
    ) async throws -> SessionAdminWorktreeInfo {
        try await prepareIfUnloaded(sessionID, isStillAuthorized: isStillAuthorized)
        let authority = try await resolveTargetAuthority(sessionID)
        let capture = authority.capture
        guard isIdle(capture.viewModel, capture.session) else { throw SessionAdminHostError.notIdle }
        let repository: TargetRepository? = if let repoRoot {
            try await resolveRepository(repoRoot, authority: authority)
        } else {
            nil
        }
        let (worktree, target) = try await resolveWorktree(selector, repository: repository, authority: authority)
        let logicalRoot = try target.logicalRoot ?? logicalRoot(for: target.repo, in: capture)
        guard isStillAuthorized(), authority.isCurrent else { throw SessionAdminHostError.authorityEnded }
        // Desired bindings come from the validated, hydrated capture, preserving unrelated rows.
        let existing = authority.bindings
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
        let desiredIDs = Set(desired.map(\.worktreeID))
        let admit: @MainActor () throws -> Void = { try admitBindings(desiredIDs) }
        let committed: @MainActor () -> Void = { bindingsCommitted(desiredIDs) }
        // The transition's exact no-op path has no beforeCommit callback. A released ownership row
        // may still be reactivated by that bind, so even this path receives identity admission.
        if existing == desired {
            guard isStillAuthorized(), authority.isCurrent else { throw SessionAdminHostError.authorityEnded }
            try admit()
            committed()
        }
        // Placement and target bindings are re-checked at entry and at `beforeCommit`; the transition's own
        // publication afterwards never counts as supersession.
        try await transition(
            desired, owner: capture.owner,
            isStillAuthorized: { isStillAuthorized() && authority.isCurrent },
            admitBindings: admit, bindingsCommitted: committed
        )
        return SessionAdminWorktreeInfo(
            worktreeID: worktree.worktreeID,
            repositoryID: worktree.repository.repositoryID,
            repoRootPath: reportedRepositoryRoot(target, in: capture),
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
        guard let owner = SessionAdminWindows.runtimeOwner(for: sessionID) else {
            throw SessionAdminHostError.sessionUnavailable
        }
        let viewModel = owner.location.window.agentModeViewModel
        let session = owner.session
        let repoPaths = viewModel.workspaceManager?.activeWorkspace?.repoPaths
        let existing = viewModel.worktreeBindings(forAgentSessionID: sessionID)
        let removed = existing.filter { worktreeID == nil || $0.worktreeID == worktreeID }
        guard !removed.isEmpty else { return [] }
        guard isIdle(viewModel, session) else { throw SessionAdminHostError.notIdle }
        let remaining = existing.filter { worktreeID != nil && $0.worktreeID != worktreeID }
        try await transition(remaining, owner: owner, isStillAuthorized: {
            isStillAuthorized() && viewModel.workspaceManager?.activeWorkspace?.repoPaths == repoPaths
        })
        return removed.map(\.worktreeID)
    }

    /// Scope authority stays live through every preparation/retirement suspension, including root
    /// ownership installation, until the binding is published. Admission still runs once, at the
    /// original pre-commit fence; post-publication persistence does not reauthorize a committed bind.
    private func transition(
        _ desired: [AgentSessionWorktreeBinding],
        owner: AgentSessionCarrierResolver.RuntimeOwner,
        isStillAuthorized: @escaping @MainActor () -> Bool,
        admitBindings: @escaping @MainActor () throws -> Void = {},
        bindingsCommitted: @escaping @MainActor () -> Void = {}
    ) async throws {
        try await transition(
            desired, sessionID: owner.location.sessionID, viewModel: owner.location.window.agentModeViewModel,
            isStillAuthorized: { isStillAuthorized() && SessionAdminWindows.isCurrent(owner) },
            admitBindings: admitBindings, bindingsCommitted: bindingsCommitted
        )
    }

    /// Shared production transition seam: scope and exact carrier checks remain one live predicate.
    func transition(
        _ desired: [AgentSessionWorktreeBinding],
        sessionID: UUID,
        viewModel: AgentModeViewModel,
        isStillAuthorized: @escaping @MainActor () -> Bool,
        admitBindings: @escaping @MainActor () throws -> Void = {},
        bindingsCommitted: @escaping @MainActor () -> Void = {}
    ) async throws {
        guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
        do {
            _ = try await viewModel.transitionWorktreeBindings(
                desired, forSessionID: sessionID, intent: .externalManagement,
                beforeCommit: {
                    guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
                    try admitBindings()
                },
                revalidateAuthority: {
                    guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
                },
                commitAuthority: {
                    guard isStillAuthorized() else { throw SessionAdminHostError.authorityEnded }
                    try $0()
                },
                afterCommit: bindingsCommitted
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

    func retainedWorktreeIDsAfterReplacingBinding(sessionID: UUID) -> Set<String> {
        let selected = SessionAdminWindows.owningViewModel(for: sessionID)
        var retained: Set<String> = []
        for window in WindowStatesManager.shared.allWindows where !window.isClosing {
            let viewModel = window.agentModeViewModel
            guard viewModel !== selected,
                  let entry = viewModel.ownerValidatedSessionIndex[sessionID]
            else { continue }
            retained.formUnion(entry.worktreeBindingSummaries.map(\.worktreeID))
        }
        return retained
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
        // Capture only: the saved operation owns its endpoints, so no default repository is elected.
        let operation = try viewModel.statusWorktreeMerge(sessionID: sessionID, operationID: operationID)
        let capture = try await captureTarget(sessionID)
        guard !capture.repos.isEmpty else {
            throw SessionAdminHostError.invalid("The target session's workspace has no Git repository.")
        }
        var authorizedRoots = Set(capture.roots.map(\.standardizedFullPath) + capture.repos.map(\.rootURL.standardizedFileURL.path))
        for endpoint in [operation.source, operation.target] {
            if let resolved = await vcsService.resolveRepo(from: URL(fileURLWithPath: endpoint.path)),
               capture.repos.contains(where: {
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
