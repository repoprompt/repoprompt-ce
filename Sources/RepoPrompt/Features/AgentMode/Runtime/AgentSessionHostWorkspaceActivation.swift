import Foundation
import RepoPromptDomainRuntime
import RepoPromptWorkspaceContext

/// Exact resource ownership for one visible activation. This retains existing authorities and
/// their leases; it does not mirror the workspace catalog or elect a session writer.
@MainActor
final class AgentSessionHostWorkspaceActivation {
    let gitArtifactAdvertisements = MCPGitArtifactAdvertisementRegistry()
    struct Key: Equatable {
        let windowID: Int
        let owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner
    }

    let key: Key
    let authority: DomainWorkspaceAuthorityClient
    let activations: AgentWorkspaceSessionIndexStore
    private let resources: AgentHostWorkspaceResources
    private let settings: APISettingsRuntimeLease
    private let savedTarget: AgentSavedSessionTargetLoader.Target?
    private let retainedChildSessionID: UUID?
    var retainedCarrierSessionID: UUID? {
        savedCarrierSessionID ?? retainedChildSessionID
    }

    var savedCarrierSessionID: UUID? {
        savedTarget?.entry.id
    }

    private var savedSelection: StoredSelection?
    private var rootLeases: [Set<UUID>: AgentHostWorkspaceResources.Lease] = [:]
    private(set) var catalogFileLease: AgentHostWorkspaceResources.Lease?
    private var retainedRoots: [AgentHostWorkspaceResources.Lease] = []
    private(set) var isReleased = false
    private(set) weak var lifecycleProjectionOwner: AgentWorkspaceSessionIndexStore?
    private struct HostBinding {
        weak var scope: AgentSessionRuntimeStore.Scope?
        let hostIdentity: ObjectIdentifier
    }

    private var hostBinding: HostBinding?

    init(
        windowID: Int, authority: DomainWorkspaceAuthorityClient,
        activations: AgentWorkspaceSessionIndexStore,
        resources: AgentHostWorkspaceResources, settings: APISettingsRuntimeLease,
        savedTarget: AgentSavedSessionTargetLoader.Target? = nil, retainedChildSessionID: UUID? = nil
    ) throws {
        guard let owner = activations.latestSessionIndexOwner, owner.workspaceID != nil,
              !settings.isReleased, resources.contexts != nil,
              savedTarget.map({ $0.workspace.id == owner.workspaceID }) ?? true
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        key = .init(windowID: windowID, owner: owner)
        self.authority = authority
        self.activations = activations
        self.resources = resources
        self.settings = settings
        self.savedTarget = savedTarget
        self.retainedChildSessionID = retainedChildSessionID
        savedSelection = savedTarget?.tab.selection
    }

    /// A child owns its own activation and settings lease. It borrows the exact parent's file
    /// store and authority, not a presenter or the parent's saved-carrier proof.
    func makeChildActivation(routeID: Int, workspace: WorkspaceModel, childSessionID: UUID) throws -> AgentSessionHostWorkspaceActivation {
        guard isCurrent, catalogFileLease?.rootsAreCurrent == true,
              workspace.id == key.owner.workspaceID, routeID != authority.windowID,
              let childSettings = APISettingsRuntimeLease.acquire(from: settings.settings)
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let index = AgentWorkspaceSessionIndexStore()
        index.receiveWorkspaceSwitchNotification(workspace)
        do {
            return try .init(
                windowID: routeID,
                authority: .init(store: authority.store, windowID: routeID, metadataPathPolicy: authority.metadataPathPolicy),
                activations: index, resources: resources, settings: childSettings, retainedChildSessionID: childSessionID
            )
        } catch {
            childSettings.release()
            throw error
        }
    }

    /// For saved execution the loader establishes the session-to-carrier relationship. The
    /// canonical document proves placement; the original writer proves execution authority.
    /// Project the saved session ID only into request-local bytes, never into a visible tab.
    func executionTab(in snapshot: DomainWorkspaceSnapshot, command: AgentSessionRuntimeStore.Command) -> ComposeTabState? {
        executionTab(in: snapshot, workspaceID: command.identity.workspaceID, tabID: command.writer.session.tabID, sessionID: command.identity.sessionID)
    }

    func executionTab(in snapshot: DomainWorkspaceSnapshot, workspaceID: UUID, tabID: UUID, sessionID: UUID) -> ComposeTabState? {
        guard snapshot.document.workspaceID == workspaceID, snapshot.health != .removed else { return nil }
        if let savedTarget {
            guard savedTarget.entry.id == sessionID, savedTarget.tab.id == tabID,
                  !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID),
                  let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes),
                  var tab = savedTarget.carrier(in: workspace) else { return nil }
            tab.activeAgentSessionID = sessionID
            if let savedSelection { tab.selection = savedSelection }
            return tab
        }
        let matches = snapshot.contexts.filter { $0.metadata.identity.contextID == tabID && $0.health != .removed }
        guard matches.count == 1, let carrier = matches.first,
              let tab = try? JSONDecoder().decode(ComposeTabState.self, from: carrier.metadata.documentBytes),
              tab.id == tabID, tab.activeAgentSessionID == sessionID else { return nil }
        return tab
    }

    /// Only pre-installation and presenter attachment follow the window's latest epoch. Once
    /// bound, this exact host keeps its resources across unrelated presentation changes. Losing
    /// that binding never falls back to a newly selected presenter or host.
    var isCurrent: Bool {
        guard !isReleased, !settings.isReleased else { return false }
        guard let binding = hostBinding else { return activations.latestSessionIndexOwner == key.owner }
        guard let scope = binding.scope, !scope.hasReleasedWriterClaims,
              let host = scope.executableHost, ObjectIdentifier(host) == binding.hostIdentity,
              host.workspaceActivation === self, host.routeID == authority.windowID, !host.route.isClosing
        else { return false }
        return true
    }

    var isPresenterCurrent: Bool {
        isCurrent && activations.latestSessionIndexOwner == key.owner
    }

    /// Called once by composition while the original presenter epoch is still current, before
    /// any session is visible. This is resource ownership, not writer or provider admission.
    func bind(to host: AgentSessionRuntimeHost) throws {
        guard hostBinding == nil, isPresenterCurrent, host.workspaceActivation === self,
              host.scope.executableHost === host, host.scope.sessions.isEmpty,
              !host.scope.isRetiring, !host.scope.hasReleasedWriterClaims,
              host.routeID == authority.windowID, !host.route.isClosing
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        hostBinding = HostBinding(scope: host.scope, hostIdentity: ObjectIdentifier(host))
    }

    /// Assign local projection repair to the last qualified presenter. A passive mirror may
    /// observe this writer, but cannot use it to republish that mirror's old carrier fields.
    func recordLifecycleProjectionOwner(
        _ presenter: AgentWorkspaceSessionIndexStore, owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner
    ) {
        guard isCurrent, savedTarget == nil, owner.workspaceID == key.owner.workspaceID,
              presenter.isOwnerCurrent(owner) else { return }
        lifecycleProjectionOwner = presenter
    }

    func owns(scope: AgentSessionRuntimeStore.Scope, route: MCPHostRouteResources) -> Bool {
        guard isCurrent, hostBinding?.scope === scope,
              let host = scope.executableHost, host.route === route else { return false }
        return true
    }

    /// A visible activation pins the originating workspace roots before registering its route.
    /// No compose tab or saved carrier is required until a request captures its writer receipt.
    func retainVisibleFileResources() async throws -> AgentHostWorkspaceResources.Lease {
        guard savedTarget == nil, isPresenterCurrent, retainedRoots.isEmpty,
              let workspaceID = key.owner.workspaceID,
              let original = await authority.canonicalWorkspaceSnapshot(workspaceID), original.health != .removed,
              isPresenterCurrent
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        var rootIDs: [UUID] = []
        for path in original.document.metadata.repoPaths {
            try Task.checkCancellation()
            guard isPresenterCurrent else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            // Join the file store's existing load. Abandoning this candidate must not cancel
            // a root producer which also belongs to the workspace's visible file projection.
            let root = try await resources.files.loadRoot(path: path, cancelUnderlyingLoadOnCallerCancellation: false)
            rootIDs.append(root.id)
        }
        guard isPresenterCurrent else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let lease = try await retainHostFileResources(rootIDs: rootIDs)
        guard lease.snapshot.document.metadata.repoPaths == original.document.metadata.repoPaths,
              isPresenterCurrent, lease.rootsAreCurrent, !Task.isCancelled
        else { throw AgentHostWorkspaceResources.Failure.contextChanged }
        return lease
    }

    /// Lease the exact activation's workspace roots, before any tab or writer is selected.
    /// A saved activation additionally proves its historical carrier against canonical bytes.
    @discardableResult
    func retainHostFileResources(rootIDs: [UUID]) async throws -> AgentHostWorkspaceResources.Lease {
        guard let workspaceID = key.owner.workspaceID, isCurrent, catalogFileLease == nil else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let lease = try await resources.acquire(workspaceID: workspaceID, rootIDs: rootIDs) { snapshot in
            guard let savedTarget else { return true }
            guard let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes) else { return false }
            return savedTarget.carrier(in: workspace) != nil
        }
        guard let current = await authority.canonicalWorkspaceSnapshot(workspaceID),
              current.isInSameExecutionLineage(as: lease.snapshot), isCurrent,
              !Task.isCancelled, catalogFileLease == nil
        else {
            await lease.release()
            throw AgentHostWorkspaceResources.Failure.contextChanged
        }
        catalogFileLease = lease
        rootLeases[Set(rootIDs)] = lease
        retainedRoots.append(lease)
        return lease
    }

    func commitHostSelection(
        _ selection: StoredSelection, replacing previous: StoredSelection,
        in snapshot: DomainWorkspaceSnapshot, command: AgentSessionRuntimeStore.Command,
        connectionID: UUID, validatesOrigin: @escaping @MainActor @Sendable () async -> Bool
    ) async throws -> DomainWorkspaceSnapshot? {
        guard await authority.canonicalWorkspaceSnapshot(command.identity.workspaceID) == snapshot,
              await validatesOrigin() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        try command.requireCurrent()
        guard !Task.isCancelled, isCurrent, hostBinding?.scope === command.writer.scope,
              executionTab(in: snapshot, command: command)?.selection == previous
        else { throw AgentHostWorkspaceResources.Failure.contextChanged }
        guard selection != previous else { return nil }
        if savedTarget != nil {
            // Historical execution cannot publish a selection into a different displayed chat.
            savedSelection = selection
            return nil
        }
        let tabID = command.writer.session.tabID
        guard let context = snapshot.contexts.first(where: { $0.metadata.identity.contextID == tabID }),
              var workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes),
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tabID && $0.activeAgentSessionID == command.identity.sessionID })
        else { throw AgentHostWorkspaceResources.Failure.contextChanged }
        workspace.composeTabs[index].selection = selection
        let document = try DomainWorkspaceDocument.decode(documentBytes: JSONEncoder().encode(workspace), fileURL: snapshot.document.fileURL)
        let outcome = await authority.store.replaceWorkingContext(
            document: document, workspaceRevision: snapshot.revisions.workingRevision, contextRevision: context.revisions.workingRevision,
            connectionID: connectionID, validatesOrigin: validatesOrigin
        )
        // Report the actual commit receipt. A rebind after durable IO cannot roll it back.
        guard outcome.errorCode == nil, let after = outcome.workspace,
              after.document.contentDigest == document.contentDigest else { throw AgentHostWorkspaceResources.Failure.contextChanged }
        return after
    }

    var modelAvailability: AgentModelCatalog.AvailabilityContext? {
        providerSettings?.agentModeAvailabilityContext
    }

    var providerSettings: APISettingsViewModel? {
        isCurrent ? settings.settings : nil
    }

    #if DEBUG
        func test_hasSettingsLease(from owner: APISettingsViewModel) -> Bool {
            !settings.isReleased && settings.settings === owner
        }
    #endif

    func capture(
        command: AgentSessionRuntimeStore.Command, rootIDs: [UUID], route: MCPHostRouteResources
    ) async throws -> AgentSessionHostStartupResources {
        try command.requireCurrent()
        guard case .restored = command.requirement, isCurrent, command.identity.workspaceID == key.owner.workspaceID,
              !route.isClosing, authority.windowID == route.identity.routeID
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let lease = try await captureLease(command: command, rootIDs: rootIDs, route: route)
        do {
            let captured = try AgentSessionHostStartupResources(
                origin: command, lease: lease, settings: settings, activations: activations,
                route: route, hostActivation: self
            )
            guard captured.carrierSessionID == command.identity.sessionID else {
                throw AgentHostWorkspaceResources.Failure.contextUnavailable
            }
            return captured
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Input capture is not provider-start admission. Initial worktree recovery may hold the
    /// original creation command while a transition is in progress; it must not fabricate a
    /// restored command or replace its captured document when validating rendered input.
    func captureInput(
        command: AgentSessionRuntimeStore.Command, rootIDs: [UUID], route: MCPHostRouteResources
    ) async throws -> AgentSessionProviderInputRuntime.InitialThreadInput {
        let lease = try await captureLease(command: command, rootIDs: rootIDs, route: route)
        let session = command.writer.session
        guard let tab = executionTab(in: lease.snapshot, command: command)
        else {
            throw AgentHostWorkspaceResources.Failure.contextUnavailable
        }
        let bindings = session.worktreeBindings
        let current: @MainActor () -> Bool = {
            !Task.isCancelled && command.isCurrent && self.isCurrent && !route.isClosing
                && lease.rootsAreCurrent && session.worktreeBindings == bindings
        }
        guard current() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        return .init(workspace: .init(
            store: resources.files,
            lookupSource: .init(activeAgentSessionID: command.identity.sessionID, worktreeBindings: bindings),
            workspacePaths: lease.snapshot.document.metadata.repoPaths, isCurrent: current,
            validate: {
                guard current(), await lease.isCurrent() else { return false }
                return current()
            }
        ), selection: tab.selection, promptText: tab.promptText)
    }

    /// Resolve loaded roots from this request's canonical workspace, not the selected window.
    /// The subsequent lease acquisition proves coverage and rechecks the document/root receipts.
    func loadedRootIDs(for command: AgentSessionRuntimeStore.Command, route: MCPHostRouteResources) async throws -> [UUID] {
        try command.requireCurrent()
        guard owns(scope: command.writer.scope, route: route), command.identity.workspaceID == key.owner.workspaceID,
              !route.isClosing, authority.windowID == route.identity.routeID,
              let snapshot = await authority.canonicalWorkspaceSnapshot(command.identity.workspaceID)
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        try Task.checkCancellation()
        try command.requireCurrent()
        guard isCurrent, !route.isClosing else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let roots = await resources.files.rootRefs()
        try Task.checkCancellation()
        try command.requireCurrent()
        guard isCurrent, !route.isClosing else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let paths = Set(snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
        let selected = roots.filter { paths.contains(($0.fullPath as NSString).standardizingPath) }
        guard Set(selected.map { ($0.fullPath as NSString).standardizingPath }) == paths else {
            throw AgentHostWorkspaceResources.Failure.rootsChanged
        }
        return selected.map(\.id)
    }

    func captureWorktreeAdmission(
        command: AgentSessionRuntimeStore.Command, rootIDs: [UUID], route: MCPHostRouteResources
    ) async throws -> AgentSessionWorktreeRuntime.Admission {
        let bindings = command.writer.session.worktreeBindings
        let lease = try await captureLease(command: command, rootIDs: rootIDs, route: route)
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: lease.snapshot.document.documentBytes)
        guard !workspace.isSystemWorkspace, executionTab(in: lease.snapshot, command: command) != nil
        else { throw AgentHostWorkspaceResources.Failure.contextUnavailable }
        let current: @MainActor () -> Bool = {
            self.isCurrent && !route.isClosing && lease.rootsAreCurrent
        }
        let validatePlacement: @MainActor () async throws -> Void = {
            try Task.checkCancellation()
            try command.requireCurrent()
            guard current() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            let refreshed: AgentHostWorkspaceResources.Lease
            do {
                refreshed = try await lease.capture(workspaceID: command.identity.workspaceID) { _ in true }
            } catch AgentHostWorkspaceResources.Failure.contextUnavailable {
                try command.requireCurrent()
                guard current() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
                throw AgentSessionWorktreeRuntime.TransitionError.stale
            }
            let document = try JSONDecoder().decode(WorkspaceModel.self, from: refreshed.snapshot.document.documentBytes)
            guard current(), self.executionTab(in: refreshed.snapshot, command: command) != nil,
                  document.id == workspace.id, !document.isSystemWorkspace,
                  document.repoPaths == workspace.repoPaths, document.customStoragePath == workspace.customStoragePath
            else { throw AgentSessionWorktreeRuntime.TransitionError.stale }
            try command.requireCurrent()
        }
        try await validatePlacement()
        let admission = AgentSessionWorktreeRuntime.Admission(command: command, resources: .init(
            store: resources.files, fallbackWorkspacePath: workspace.repoPaths.first,
            declaredRepoPaths: workspace.repoPaths, storageDirectory: workspace.customStoragePath,
            awaitRootReadiness: validatePlacement, validatePlacement: validatePlacement, isCurrent: current
        ), bindings: bindings)
        try admission.requireCurrent()
        return admission
    }

    private func captureLease(
        command: AgentSessionRuntimeStore.Command, rootIDs: [UUID], route: MCPHostRouteResources
    ) async throws -> AgentHostWorkspaceResources.Lease {
        try command.requireCurrent()
        guard owns(scope: command.writer.scope, route: route), command.identity.workspaceID == key.owner.workspaceID,
              !route.isClosing, authority.windowID == route.identity.routeID
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let workspaceID = command.identity.workspaceID
        let admits: (DomainWorkspaceSnapshot) -> Bool = { self.executionTab(in: $0, command: command) != nil }
        let roots = Set(rootIDs)
        let existing = rootLeases[roots].flatMap { $0.rootsAreCurrent ? $0 : nil }
        let lease: AgentHostWorkspaceResources.Lease = if let existing {
            try await existing.capture(workspaceID: workspaceID, admits: admits)
        } else {
            try await resources.acquire(workspaceID: workspaceID, rootIDs: rootIDs, admits: admits)
        }
        do {
            if savedTarget != nil {
                guard let current = await authority.canonicalWorkspaceSnapshot(workspaceID),
                      current.isInSameExecutionLineage(as: lease.snapshot)
                else {
                    throw AgentHostWorkspaceResources.Failure.contextChanged
                }
            }
            try Task.checkCancellation()
            try command.requireCurrent()
            guard isCurrent, !route.isClosing else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            if existing == nil {
                rootLeases[roots] = lease
                retainedRoots.append(lease)
            }
            return lease
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Only the host's acknowledged drain calls this; neither presentation detach nor a failed
    /// request releases resources still captured by another originating request.
    func release() async {
        guard !isReleased else { return }
        isReleased = true
        let retained = retainedRoots
        catalogFileLease = nil
        rootLeases.removeAll()
        retainedRoots.removeAll()
        for lease in retained {
            await lease.release()
        }
        if savedTarget != nil {
            // Saved composition created this private store, including roots loaded before a failed lease acquisition.
            let rootIDs = await resources.files.rootRefs().map(\.id)
            await resources.files.unloadRoots(ids: rootIDs)
        }
        settings.release()
    }
}
