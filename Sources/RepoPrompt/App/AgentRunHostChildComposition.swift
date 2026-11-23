import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptVCS
import RepoPromptWorkspaceContext

/// App wiring only. This creates a child route and empty scope; publishing a carrier and
/// admitting a provider still belong to the exact workspace and session transactions.
@MainActor
enum AgentRunHostChildComposition {
    static func compose(
        from parent: AgentRunHostAdmission,
        displayName: @escaping @MainActor (UUID) -> String
    ) async throws -> AgentSessionRuntimeHost {
        let workspace = try await parent.canonicalWorkspace()
        guard !workspace.isSystemWorkspace, !AppLaunchConfiguration.current.suppressesAgentSessionPersistence,
              parent.sourceIsCurrent,
              let routeResources = parent.host.route.makeChildExecutionRoute(),
              let execution = routeResources.owner.acquire(.execution)
        else { throw MCPFileToolAuthorityFailure.unavailable }
        let route = routeResources.owner.route
        let source = parent.host
        let settings = source.modelRouterSettingsStore
        let diagnostics = AppAgentSessionLinkCatalogEventSink()
        let perf = AppAgentModePerfRecorder()
        let paths = AgentSessionRuntimeHost.makeSessionWorkspaceProviders { workspace.repoPaths.first }
        let child = AgentSessionRuntimeHost(
            route: route, executionRouteLease: execution, workspacePath: paths.sessionWorkspacePath,
            runtimeWorkspacePaths: paths.codexRuntimeWorkspacePaths,
            connectionPolicyInstaller: AgentSessionRuntimeHost.defaultConnectionPolicyInstaller,
            modelRouterSettingsStore: settings, catalogDiagnosticsSink: diagnostics, perfRecorder: perf,
            providerResources: source.providerResources, claudeControllerFactory: source.claudeControllerFactory
        )
        await routeResources.owner.requestTerminalDisposal()
        do {
            try await parent.requireCurrent()
            let activation = try parent.activation.makeChildActivation(routeID: child.routeID, workspace: workspace)
            let storage = AgentSessionStorageInputs(
                workspaceID: workspace.id, workspaceWithID: { $0 == workspace.id ? workspace : nil },
                displayName: { displayName($0) }, isSuppressed: { AppLaunchConfiguration.current.suppressesAgentSessionPersistence },
                attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
            )
            let canonical = AgentSessionPersistenceRuntime.CanonicalStorage(workspaceID: workspace.id) { id in
                guard let snapshot = await activation.authority.canonicalWorkspaceSnapshot(id),
                      snapshot.document.workspaceID == id, snapshot.health != .removed else { return nil }
                return try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
            }
            child.scope.persistence.composition = storage.persistenceComposition(scope: child.scope, canonicalStorage: canonical)
            do {
                try await child.installWorkspaceActivation(
                    activation, attachmentWorkspaceDirectory: FileManager.default.temporaryDirectory,
                    suppressesAttachmentPersistence: false
                )
            } catch {
                await activation.release()
                throw error
            }
            try await parent.requireCurrent()
            try await activation.retainHostFileResources(rootIDs: parent.rootLease.roots.map(\.id))
            try child.installHostRunExecution(
                sessionTitle: { displayName($0.tabID) }, settings: settings, perf: perf, diagnostics: diagnostics
            )
            try await child.registerHostCatalog(service: routeResources.transport)
            try await parent.requireCurrent()
            child.scope.retainExecutableHost()
            return child
        } catch {
            child.beginRetirement().startIfNeeded()
            throw error
        }
    }
}

/// Exact receipts for the two stages of a new child: durable carrier, then configured first
/// save on the same writer. Neither the carrier alone nor tab presentation admits execution.
@MainActor
final class AgentRunHostChildCreation {
    private final class PendingWriter {
        var command: AgentSessionRuntimeStore.Command?
        var stopFence: AgentRunStartStopFence?
    }

    private final class CarrierTitle {
        var value = "Agent Session"
    }

    let host: AgentSessionRuntimeHost
    let command: AgentSessionRuntimeStore.Command
    let creation: AgentSessionCreationHandle
    let stopFence: AgentRunStartStopFence
    private let publication: WorkspaceAgentCanonicalFreshAdmission
    private let claim: AgentProvisionalAdmissionClaim
    private var attemptedConfiguredSave = false
    private var configuredSaveWaiters: [CheckedContinuation<Void, Never>]?

    private init(
        host: AgentSessionRuntimeHost, command: AgentSessionRuntimeStore.Command, creation: AgentSessionCreationHandle,
        stopFence: AgentRunStartStopFence, publication: WorkspaceAgentCanonicalFreshAdmission, claim: AgentProvisionalAdmissionClaim
    ) {
        self.host = host
        self.command = command
        self.creation = creation
        self.stopFence = stopFence
        self.publication = publication
        self.claim = claim
    }

    static func publish(
        from source: AgentRunHostAdmission, name: String? = nil, bindingEmptyTabID: UUID? = nil
    ) async throws -> AgentRunHostChildCreation {
        try source.requireSpawnSource()
        let allocation = AgentSessionCreationClaim(workspaceID: source.workspaceID)
        let pending = PendingWriter()
        let title = CarrierTitle()
        let host = try await AgentRunHostChildComposition.compose(from: source) { _ in title.value }
        guard let activation = host.workspaceActivation else {
            host.beginRetirement().startIfNeeded()
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let publisher = WorkspaceAgentCanonicalFreshAdmission(
            authority: activation.authority, connectionID: source.connection.connectionID, bindingEmptyTabID: bindingEmptyTabID
        )
        let onRecovery: @MainActor (AgentAdmissionRecoveryOutcome) async -> Void = { outcome in
            switch outcome {
            case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
                await retireProvisionalHost(host, writer: pending.command?.writer)
            default: break
            }
        }
        do {
            let result = try await publisher.publish(workspaceID: source.workspaceID, sessionID: allocation.sessionID, adapters: .init(
                makeTab: { workspace in
                    ComposeTabState(
                        name: name ?? ComposeTabState.nextDefaultName(in: workspace.composeTabs), activeAgentSessionID: allocation.sessionID
                    )
                }, prepareWriter: { tab in
                    title.value = tab.name
                    let scope = host.scope
                    guard scope.sessions.isEmpty, activation.isCurrent else { return false }
                    let session = scope.makeSession(tabID: tab.id)
                    guard scope.permitsBinding(allocation.sessionID, on: session) else { return false }
                    session.beginPersistentBindingTransition()
                    session.installPersistentSessionBinding(.init(tabID: tab.id, sessionID: allocation.sessionID, workspaceID: source.workspaceID))
                    guard let creation = session.acceptFreshCreation(allocation, workspaceID: source.workspaceID) else { return false }
                    session.parentSessionID = source.source.identity.sessionID
                    pending.stopFence = AgentRunStartStopFence(session: session)
                    scope.replaceSessions([tab.id: session])
                    guard let command = try? scope.admit(session: session, expectedWorkspaceID: source.workspaceID, requirement: .creation(creation)) else {
                        scope.replaceSessions([:])
                        return false
                    }
                    pending.command = command
                    return true
                }, ownsWriter: { pending.command?.writer.ownsPersistentClaim == true },
                validateSource: { await (try? source.canonicalWorkspace()) != nil },
                sourceIsCurrent: { source.sourceIsCurrent }, provesSourceInSnapshot: source.provesCanonicalCarrier(in:),
                retainedRecoveryDidSettle: onRecovery
            ))
            guard case let .created(_, _, claim) = result, let command = pending.command,
                  let creation = allocation.creationHandle, let stopFence = pending.stopFence
            else {
                throw MCPError.invalidParams("The child carrier could not be saved by the originating workspace authority.")
            }
            return .init(host: host, command: command, creation: creation, stopFence: stopFence, publication: publisher, claim: claim)
        } catch {
            if !publisher.hasRetainedRecovery {
                await retireProvisionalHost(host, writer: pending.command?.writer)
            }
            throw error
        }
    }

    /// Reuse the tool's existing worktree planner and binding transition, but read from the
    /// originating parent's pinned roots. The child cannot be rebound to a presented workspace.
    func prepareWorktree(
        _ request: AgentMCPStartWorktreeCoordinator.Request, from source: AgentRunHostAdmission,
        expiry: AgentRunStartExpiry? = nil
    ) async throws -> String? {
        let workspace = try await source.canonicalWorkspace()
        guard let activation = host.workspaceActivation, let lease = activation.catalogFileLease,
              source.workspaceID == command.identity.workspaceID, lease.roots == source.rootLease.roots
        else { throw MCPFileToolAuthorityFailure.superseded }
        let writer = command.writer
        let session = writer.session
        let fallbackPath = workspace.repoPaths.first
        func requireCurrent() async throws {
            try expiry?.throwIfExpired()
            let snapshot = try await source.canonicalSnapshot()
            try command.requireCurrent()
            guard claim.state == .provisional, stopFence.permitsStart(of: session),
                  source.sourceIsCurrent, lease.rootsAreCurrent, host.workspaceActivation === activation,
                  activation.owns(scope: host.scope, route: host.route),
                  snapshot.document.metadata.repoPaths == workspace.repoPaths,
                  activation.executionTab(in: snapshot, command: command) != nil
            else { throw MCPFileToolAuthorityFailure.superseded }
        }
        try await requireCurrent()
        if !request.hasExplicitWorktreeArgs, request.inheritParentWorktreeBindings {
            let inherited = source.connection.lookupSource.worktreeBindings
            _ = try await host.scope.worktrees.transition(
                inherited, command: command, intent: .initialSend,
                revalidateAuthority: requireCurrent
            )
        }
        let coordinator = AgentMCPStartWorktreeCoordinator(
            operationName: "agent_run.start", vcsService: .shared, gitTargetResolver: .init(),
            startupPhaseEventSink: AppWorktreeStartupPhaseEventSink()
        )
        try await coordinator.prepare(request: request, authority: .init(
            sessionID: command.identity.sessionID, files: lease.resources.files,
            requireCurrent: requireCurrent, roots: { (fallbackPath, lease.roots) }, primaryRoot: { fallbackPath },
            bindings: { session.worktreeBindings }, transition: { bindings, context, hints in
                _ = try await self.host.scope.worktrees.transition(
                    bindings, command: self.command, intent: .initialSend, startupContext: context,
                    initializationHintsByBindingID: hints, revalidateAuthority: requireCurrent
                )
            },
            // Canonical transitions publish the root projection with the binding. If those
            // exact roots did not survive, refuse rather than installing an unfenced fallback.
            materialize: { _ in false }
        ))
        try await requireCurrent()
        return try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: session.worktreeBindings, fallbackWorkspacePath: fallbackPath
        )
    }

    /// After durable acknowledgement recovery may not remove the carrier. A Stop or lost
    /// parent after acknowledgement prevents launch but does not uncommit the saved child.
    func commitConfiguredCreation() async throws -> AgentSessionRuntimeStore.Command {
        try command.requireCurrent()
        let writer = command.writer
        guard claim.state == .provisional, !attemptedConfiguredSave,
              stopFence.permitsStart(of: writer.session), !Task.isCancelled else { throw MCPFileToolAuthorityFailure.superseded }
        attemptedConfiguredSave = true
        configuredSaveWaiters = []
        defer {
            let waiters = configuredSaveWaiters ?? []
            configuredSaveWaiters = nil
            for waiter in waiters {
                waiter.resume()
            }
        }
        guard case .durablySaved = await host.scope.persistence.commitConfiguredCreation(creation, writer: writer),
              publication.acceptConfiguredCreation(claim, writer: writer)
        else { throw MCPFileToolAuthorityFailure.superseded }
        return try writer.admitCommand().get()
    }

    func discardIfProvisional() async {
        // The workspace rollback must never race the sidecar's acknowledgement. Keep the
        // save in its original caller task so cancellation admission is not changed.
        if configuredSaveWaiters != nil {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                guard configuredSaveWaiters != nil else { waiter.resume()
                    return
                }
                configuredSaveWaiters?.append(waiter)
            }
        }
        guard claim.state == .provisional else { return }
        let writer = command.writer
        // A durable acknowledgement can precede requester cancellation. Never compensate that
        // successful save even when the command no longer has authority to start a provider.
        guard writer.session.qualifiedRestorationReadiness != .authoritative(writer.restoration, .freshBindingDurablyCreated) else { return }
        let host = host
        let outcome = await publication.discard(claim, ownsWriter: { writer.ownsPersistentClaim }, retainedRecoveryDidSettle: { outcome in
            switch outcome {
            case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
                await Self.retireProvisionalHost(host, writer: writer)
            default: break
            }
        })
        switch outcome {
        case .recovered, .alreadyRecovered, .localOnly, .ownershipChanged:
            await Self.retireProvisionalHost(host, writer: writer)
        default: break
        }
    }

    private static func retireProvisionalHost(_ host: AgentSessionRuntimeHost, writer: AgentSessionRuntimeStore.Writer?) async {
        if let writer, writer.ownsPersistentClaim {
            let session = writer.session
            guard !session.runState.isActive, session.agentTask == nil,
                  session.qualifiedRestorationReadiness != .authoritative(writer.restoration, .freshBindingDurablyCreated)
            else { return }
            if let context = session.mcpControlContext, let interactions = host.scope.installedInteractions {
                _ = await host.scope.mcp.deactivateControlContext(
                    session: session, expectedContext: context, approvalStore: interactions.approvalStore, cleanupRegistration: true
                )
            }
            // There is no transcript to flush after exact provisional compensation. Only
            // remove the blocked writer after its control registration and effects settled.
            guard writer.ownsPersistentClaim, session.mcpControlContext == nil, !session.runState.isActive,
                  host.scope.saveQueue.inFlightSessionIDs.isEmpty, host.scope.worktrees.pendingTransitions == 0,
                  !host.scope.continuation.hasPendingStarts, host.scope.installedInteractions?.hasPendingEffects != true
            else { return }
            host.scope.replaceSessions([:])
        }
        guard host.scope.sessions.isEmpty else { return }
        host.beginRetirement().startIfNeeded()
    }
}
