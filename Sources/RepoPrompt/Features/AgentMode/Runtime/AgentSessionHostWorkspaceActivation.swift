import Foundation
import RepoPromptDomainRuntime

/// Exact resource ownership for one visible activation. This retains existing authorities and
/// their leases; it does not mirror the workspace catalog or elect a session writer.
@MainActor
final class AgentSessionHostWorkspaceActivation {
    struct Key: Equatable {
        let windowID: Int
        let owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner
    }

    let key: Key
    let authority: DomainWorkspaceAuthorityClient
    let activations: AgentWorkspaceSessionIndexStore
    private let resources: AgentHostWorkspaceResources
    private let settings: APISettingsRuntimeLease
    private var rootLeases: [Set<UUID>: AgentHostWorkspaceResources.Lease] = [:]
    private var retainedRoots: [AgentHostWorkspaceResources.Lease] = []
    private(set) var isReleased = false
    private struct HostBinding {
        weak var scope: AgentSessionRuntimeStore.Scope?
        let hostIdentity: ObjectIdentifier
    }

    private var hostBinding: HostBinding?

    init(
        windowID: Int, authority: DomainWorkspaceAuthorityClient,
        activations: AgentWorkspaceSessionIndexStore,
        resources: AgentHostWorkspaceResources, settings: APISettingsRuntimeLease
    ) throws {
        guard let owner = activations.latestSessionIndexOwner, owner.workspaceID != nil,
              !settings.isReleased, resources.contexts != nil
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        key = .init(windowID: windowID, owner: owner)
        self.authority = authority
        self.activations = activations
        self.resources = resources
        self.settings = settings
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

    func owns(scope: AgentSessionRuntimeStore.Scope, route: MCPHostRouteResources) -> Bool {
        guard isCurrent, hostBinding?.scope === scope,
              let host = scope.executableHost, host.route === route else { return false }
        return true
    }

    var modelAvailability: AgentModelCatalog.AvailabilityContext? {
        isCurrent ? settings.settings.agentModeAvailabilityContext : nil
    }

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
        let document = try JSONDecoder().decode(WorkspaceModel.self, from: lease.snapshot.document.documentBytes)
        let session = command.writer.session
        let tabs = document.composeTabs.filter { $0.id == session.tabID }
        guard document.id == command.identity.workspaceID, tabs.count == 1, let tab = tabs.first,
              tab.activeAgentSessionID == command.identity.sessionID
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

    func captureCreationWorktreeAdmission(
        command: AgentSessionRuntimeStore.Command, rootIDs: [UUID], route: MCPHostRouteResources
    ) async throws -> AgentSessionWorktreeRuntime.Admission {
        guard case .creation = command.requirement else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let lease = try await captureLease(command: command, rootIDs: rootIDs, route: route)
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: lease.snapshot.document.documentBytes)
        guard !workspace.isSystemWorkspace,
              workspace.composeTabs.count(where: { $0.id == command.writer.session.tabID && $0.activeAgentSessionID == command.identity.sessionID }) == 1
        else { throw AgentHostWorkspaceResources.Failure.contextUnavailable }
        let current: @MainActor () -> Bool = {
            self.isCurrent && !route.isClosing && lease.rootsAreCurrent && command.isCurrent
        }
        return .init(command: command, resources: .init(
            store: resources.files, fallbackWorkspacePath: workspace.repoPaths.first,
            declaredRepoPaths: workspace.repoPaths, storageDirectory: workspace.customStoragePath,
            awaitRootReadiness: {
                try command.requireCurrent()
                guard current(), await lease.isCurrent() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
                try command.requireCurrent()
                guard current() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            }, isCurrent: current
        ), bindings: command.writer.session.worktreeBindings)
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
        let context = DomainContextIdentity(workspaceID: command.identity.workspaceID, contextID: command.writer.session.tabID)
        let roots = Set(rootIDs)
        let existing = rootLeases[roots].flatMap { $0.rootsAreCurrent ? $0 : nil }
        let lease: AgentHostWorkspaceResources.Lease = if let existing {
            try await existing.capture(context: context)
        } else {
            try await resources.acquire(context: context, rootIDs: rootIDs)
        }
        do {
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
        rootLeases.removeAll()
        retainedRoots.removeAll()
        for lease in retained {
            await lease.release()
        }
        settings.release()
    }
}
