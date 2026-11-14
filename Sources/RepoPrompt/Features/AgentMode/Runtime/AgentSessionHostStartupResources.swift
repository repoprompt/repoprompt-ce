import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptWorkspaceContext

/// A request's existing authorities, not a new workspace, writer or activation owner. Visible
/// edits must already be published to the canonical context before acquiring the supplied lease.
/// The composing host owns release of both leases after joining their users.
@MainActor
final class AgentSessionHostStartupResources {
    let origin: AgentSessionRuntimeStore.Command
    let context: DomainContextIdentity
    let carrierSessionID: UUID?
    let workspace: AgentRunWorkspaceInput
    let workspacePaths: [String]
    private let lease: AgentHostWorkspaceResources.Lease
    private let settings: APISettingsRuntimeLease
    private let route: MCPHostRouteResources?
    private let activations: AgentWorkspaceSessionIndexStore
    private let activation: AgentWorkspaceSessionIndexStore.SessionIndexOwner
    private let hostActivation: AgentSessionHostWorkspaceActivation?
    private let selection: StoredSelection
    private let worktreeBindings: [AgentSessionWorktreeBinding]
    private let promptText: String

    convenience init(
        scope: AgentSessionRuntimeStore.Scope, session: AgentTabSession,
        lease: AgentHostWorkspaceResources.Lease, settings: APISettingsRuntimeLease,
        activations: AgentWorkspaceSessionIndexStore
    ) throws {
        let origin = try scope.admit(session: session, expectedWorkspaceID: lease.snapshot.document.workspaceID)
        try self.init(origin: origin, lease: lease, settings: settings, activations: activations)
    }

    init(
        origin: AgentSessionRuntimeStore.Command, lease: AgentHostWorkspaceResources.Lease,
        settings: APISettingsRuntimeLease, activations: AgentWorkspaceSessionIndexStore,
        route: MCPHostRouteResources? = nil,
        hostActivation: AgentSessionHostWorkspaceActivation? = nil
    ) throws {
        try origin.requireCurrent()
        let workspaceID = lease.snapshot.document.workspaceID
        guard case .restored = origin.requirement, origin.writer.identity.workspaceID == workspaceID else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        self.origin = origin
        let session = origin.writer.session
        let context = DomainContextIdentity(workspaceID: workspaceID, contextID: session.tabID)
        self.context = context
        let capturedActivation: AgentWorkspaceSessionIndexStore.SessionIndexOwner?
        if let hostActivation {
            guard let route, hostActivation.activations === activations,
                  hostActivation.owns(scope: origin.writer.scope, route: route)
            else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            capturedActivation = hostActivation.key.owner
        } else {
            capturedActivation = activations.latestSessionIndexOwner
        }
        guard !lease.isReleased, !settings.isReleased,
              let activation = capturedActivation, activation.workspaceID == workspaceID,
              lease.snapshot.contexts.contains(where: { $0.metadata.identity == context && $0.health != .removed })
        else { throw AgentHostWorkspaceResources.Failure.contextUnavailable }
        // Decode the exact canonical bytes, not the currently selected tab or a later projection.
        let document = try JSONDecoder().decode(WorkspaceModel.self, from: lease.snapshot.document.documentBytes)
        let tabs = document.composeTabs.filter { $0.id == session.tabID }
        guard document.id == workspaceID, tabs.count == 1, let tab = tabs.first else {
            throw AgentHostWorkspaceResources.Failure.contextUnavailable
        }
        carrierSessionID = tab.activeAgentSessionID
        self.lease = lease
        self.settings = settings
        self.route = route
        self.activations = activations
        self.activation = activation
        self.hostActivation = hostActivation
        selection = tab.selection
        worktreeBindings = session.worktreeBindings
        promptText = tab.promptText
        workspacePaths = lease.snapshot.document.metadata.repoPaths
        workspace = AgentRunWorkspaceInput(fallbackWorkspacePath: workspacePaths.first)
    }

    /// Command admission never substitutes for the independent activation/resource receipt.
    var isCurrent: Bool {
        !Task.isCancelled && lease.rootsAreCurrent && !settings.isReleased && route?.isClosing != true
            && activationResourcesAreCurrent
            && !origin.writer.session.worktreeBindingTransitionInProgress
            && origin.writer.session.worktreeBindings == worktreeBindings
            && (try? origin.requireCurrent()) != nil
    }

    private var activationResourcesAreCurrent: Bool {
        if let hostActivation {
            guard let route else { return false }
            return hostActivation.key.owner == activation
                && hostActivation.owns(scope: origin.writer.scope, route: route)
        }
        return activations.latestSessionIndexOwner == activation
    }

    func validate() async -> Bool {
        guard isCurrent else { return false }
        #if DEBUG
            await test_beforeValidation?()
        #endif
        guard await lease.isCurrent() else { return false }
        return isCurrent
    }

    func inputWorkspace(for session: AgentTabSession) async throws -> AgentSessionProviderInputRuntime.WorkspaceSource? {
        guard origin.writer.session === session, await validate(), isCurrent else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        return .init(store: lease.resources.files, lookupSource: .init(
            activeAgentSessionID: origin.writer.identity.sessionID, worktreeBindings: worktreeBindings
        ), workspacePaths: workspacePaths, isCurrent: { self.isCurrent }, validate: { await self.validate() })
    }

    func initialThreadInput(for session: AgentTabSession) async throws -> AgentSessionProviderInputRuntime.InitialThreadInput? {
        guard let workspace = try await inputWorkspace(for: session), isCurrent else {
            throw AgentHostWorkspaceResources.Failure.contextUnavailable
        }
        return .init(workspace: workspace, selection: selection, promptText: promptText)
    }

    func captureProviderLaunchInput(for command: AgentSessionRuntimeStore.Command) async throws -> AgentProviderLaunchInput {
        try command.requireCurrent()
        guard command.writer.scope === origin.writer.scope, command.writer.session === origin.writer.session,
              command.writer.identity == origin.writer.identity, isCurrent
        else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        guard await validate() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        try command.requireCurrent()
        guard isCurrent else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        return try .init(
            origin: command, workspace: workspace, bindings: worktreeBindings,
            resourcesAreCurrent: { self.isCurrent }, validateResources: { await self.validate() }
        )
    }

    func availabilityFailure(_ agent: AgentProviderKind) -> String? {
        guard AgentModelCatalog.isAgentAvailable(agent, availability: settings.settings.agentModeAvailabilityContext) else {
            return "\(agent.displayName) is not connected. Connect it in Settings before starting a run."
        }
        return nil
    }

    #if DEBUG
        /// Holds the real authority check; it cannot bypass or supply its result.
        var test_beforeValidation: (() async -> Void)?
    #endif
}
