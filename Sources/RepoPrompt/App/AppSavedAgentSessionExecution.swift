import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext

/// App composition for a saved Agent carrier. Dependencies describe app authority, not an
/// active presenter. Runtime publication still happens only through the canonical store.
@MainActor
enum AppSavedAgentSessionExecution {
    typealias Target = AgentSavedSessionTargetLoader.Target
    typealias InstallRoute = (AgentSessionRuntimeHost, MCPFileReadResources) async throws -> Void

    struct Lookup {
        let target: Target
        let catalog: AgentSavedSessionTargetLoader.Catalog
    }

    static func resolve(
        _ sessionID: UUID, domain: MCPDomainRuntime,
        isStillAuthorized: @MainActor () -> Bool
    ) async throws -> Lookup {
        let snapshot = await domain.workspaceStore.snapshot()
        guard snapshot.isBootstrapped, snapshot.unavailableWorkspaceIDs.isEmpty,
              !Task.isCancelled, isStillAuthorized() else { throw AgentSavedSessionTargetLoader.Failure.changed }
        let workspaces = try snapshot.workspaces.filter { $0.health != .removed }.map {
            try JSONDecoder().decode(WorkspaceModel.self, from: $0.document.documentBytes)
        }
        func workspace(_ id: UUID) -> WorkspaceModel? {
            workspaces.first { $0.id == id }
        }
        let target = try await AgentSavedSessionTargetLoader.load(
            sessionID: sessionID, workspaces: workspaces,
            readRecord: { try await AgentSessionDataService.shared.metadataRecordForSessionID($0, for: $1) },
            currentMetadata: { _ in nil }, currentWorkspace: workspace,
            isAvailable: { !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID) },
            isCurrent: { _ in isStillAuthorized() }
        ).get()
        let validate: (Target) async -> Bool = { candidate in
            let latest = await domain.workspaceStore.snapshot()
            guard latest.catalogRevision == snapshot.catalogRevision, latest.unavailableWorkspaceIDs.isEmpty,
                  let current = await domain.workspaceStore.canonicalWorkspaceSnapshot(candidate.workspace.id), current.health != .removed,
                  let decoded = try? JSONDecoder().decode(WorkspaceModel.self, from: current.document.documentBytes) else { return false }
            return candidate.carrier(in: decoded) != nil
        }
        guard await validate(target), !Task.isCancelled, isStillAuthorized() else {
            throw AgentSavedSessionTargetLoader.Failure.changed
        }
        return Lookup(target: target, catalog: .init(
            workspaces: { workspaces }, currentWorkspace: workspace, currentMetadata: { _, _ in nil },
            isCurrent: { candidate in workspace(candidate.workspace.id).flatMap { candidate.carrier(in: $0) } != nil },
            validateCanonicalTarget: validate
        ))
    }

    static func compose(
        target: Target, catalog: AgentSavedSessionTargetLoader.Catalog,
        domain: MCPDomainRuntime, installRoute: InstallRoute,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> AgentSavedSessionTargetLoader.RuntimeLoad {
        try Task.checkCancellation()
        guard isStillAuthorized(), !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }

        let owner = MCPHostRouteResources.LeaseOwner(
            identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: domain.routingCoordinator, runtime: domain
        )
        guard let routeLease = owner.acquire(.execution) else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let route = owner.route
        let settings = GlobalSettingsStore.shared
        let diagnostics = AppAgentSessionLinkCatalogEventSink()
        let perf = AppAgentModePerfRecorder()
        let workspace = target.workspace
        let paths = AgentSessionRuntimeHost.makeSessionWorkspaceProviders { workspace.repoPaths.first }
        let host = AgentSessionRuntimeHost(
            route: route, executionRouteLease: routeLease,
            workspacePath: paths.sessionWorkspacePath, runtimeWorkspacePaths: paths.codexRuntimeWorkspacePaths,
            connectionPolicyInstaller: AgentSessionRuntimeHost.defaultConnectionPolicyInstaller,
            modelRouterSettingsStore: settings, catalogDiagnosticsSink: diagnostics, perfRecorder: perf
        )
        // A saved carrier does not attach a presenter to this physical route. Disposal is
        // requested exactly once, and waits for the transferred execution lease's release.
        await owner.requestTerminalDisposal()
        let authority = DomainWorkspaceAuthorityClient(
            store: domain.workspaceStore, windowID: route.identity.routeID, metadataPathPolicy: domain.configuration.metadataPathPolicy
        )
        let canonicalStorage = AgentSessionPersistenceRuntime.CanonicalStorage(workspaceID: workspace.id) { id in
            guard let snapshot = await authority.canonicalWorkspaceSnapshot(id), snapshot.health != .removed else { return nil }
            return try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
        }
        let storage = AgentSessionStorageInputs(
            workspaceID: workspace.id, workspaceWithID: { $0 == workspace.id ? workspace : nil },
            displayName: { _ in target.entry.name }, isSuppressed: { AppLaunchConfiguration.current.suppressesAgentSessionPersistence },
            attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
        )
        host.scope.persistence.composition = storage.persistenceComposition(scope: host.scope, canonicalStorage: canonicalStorage)
        let files = AgentHostWorkspaceResources.makeFiles(settingsStore: settings)
        let resources = AgentHostWorkspaceResources(files: files, contexts: domain.contextStore)
        let index = AgentWorkspaceSessionIndexStore()
        index.receiveWorkspaceSwitchNotification(workspace)
        let keys = KeyManager()
        let providerSettings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys)
        let loaded: AgentSavedSessionTargetLoader.RuntimeLoad
        do {
            guard let settingsLease = APISettingsRuntimeLease.acquire(from: providerSettings) else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            do {
                try await host.installWorkspaceActivation(.init(
                    windowID: route.identity.routeID, authority: authority, activations: index,
                    resources: resources, settings: settingsLease, savedTarget: target
                ), attachmentWorkspaceDirectory: FileManager.default.temporaryDirectory, suppressesAttachmentPersistence: false)
            } catch {
                settingsLease.release()
                throw error
            }
            var rootIDs: [UUID] = []
            for path in workspace.repoPaths {
                try Task.checkCancellation()
                guard isStillAuthorized() else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
                let root = try await files.loadRoot(path: path, cancelUnderlyingLoadOnCallerCancellation: true)
                rootIDs.append(root.id)
            }
            guard let activation = host.workspaceActivation, isStillAuthorized() else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            let rootLease = try await activation.retainSavedFileResources(rootIDs: rootIDs)
            try host.installSavedRunExecution(sessionTitle: target.entry.name, settings: settings, perf: perf, diagnostics: diagnostics)
            try await installRoute(host, host.makeSavedFileReadResources(rootLease))
            var catalog = catalog
            let validateCatalog = catalog.validateCanonicalTarget
            catalog.validateCanonicalTarget = { candidate in
                if let validateCatalog, !(await validateCatalog(candidate)) { return false }
                guard candidate.workspace.id == workspace.id, candidate.entry.id == target.entry.id,
                      candidate.tab.id == target.tab.id, candidate.stashedTabID == target.stashedTabID,
                      let current = await canonicalStorage.readWorkspace(workspace.id)
                else { return false }
                return target.carrier(in: current) != nil
            }
            loaded = try await AgentSavedSessionTargetLoader.loadRuntime(
                sessionID: target.entry.id, scope: host.scope, catalog: catalog, storage: storage,
                selection: { payload in
                    AgentSessionHydrationRuntime.selection(for: payload, availability: activation.modelAvailability ?? .none, codexDynamicModels: nil)
                }, codexPolicy: { host.codexCoordinator.selectionPolicy(forModelRaw: $0.modelRaw, includeGlobalFallback: true) },
                isStillAuthorized: isStillAuthorized
            ).get()
        } catch {
            host.beginRetirement().startIfNeeded()
            throw error
        }
        guard loaded.writer.scope === host.scope else {
            host.beginRetirement().startIfNeeded()
            return loaded
        }
        host.scope.retainExecutableHost()
        return loaded
    }
}

extension AgentSessionRuntimeHost {
    fileprivate func installSavedRunExecution(
        sessionTitle title: String, settings: GlobalSettingsStore,
        perf: AppAgentModePerfRecorder, diagnostics: AppAgentSessionLinkCatalogEventSink
    ) throws {
        let links = try installCanonicalLinkExecution(skillCatalog: AgentSkillCatalog(), perfRecorder: perf, diagnostics: diagnostics)
        let enable: AgentRunExecutionContracts.MCPServerEnabler = { [route] in await route.hasActiveCatalog() }
        installCodexRuntime(codexCoordinator, routeID: routeID, approvalStore: .shared, links: links, mcpServerEnabler: enable, modelRouterSettingsStore: settings)
        let input = makeCanonicalInputEnvironment()
        claudeCoordinator.installHostCapabilities(
            makeClaudeCapabilities(links: links, inputEnvironmentForSession: input, sessionTitle: { _ in title }),
            providerBindingService: providerBindingService
        )
        let tools = route.toolExecutionRuntime
        let publication = scope.mcp
        let dependencies = AgentModeRunService.Dependencies(
            windowID: routeID, connectionPolicyInstaller: Self.defaultConnectionPolicyInstaller,
            expectedPIDPolicyArmer: { _ in false }, mcpServerEnabler: enable,
            codexCoordinator: codexCoordinator, claudeCoordinator: claudeCoordinator, shouldManageCodexTooling: true,
            providerRuntimePermissionResolver: { [providerBindingService] in providerBindingService.runtimePermission(for: $0, profile: $1) },
            bindPendingOracleReviewContext: { publication.mcpBindPendingAgentRunOracleReviewContext(tabID: $0, runID: $1) },
            cancelMCPToolsForRun: { _ = tools.cancelActiveToolsForRun(runID: $0, reason: $1) },
            awaitNoActiveMCPTools: { try await tools.awaitNoActiveToolExecutions(runID: $0) },
            activeAgentRunWaitQuery: { tools.hasActiveChildAgentRunWaits(runID: $0) },
            childAgentRunWaitDrainTimeoutSeconds: Self.childAgentRunWaitDrainTimeoutSeconds
        )
        scope.installExecution(makeExecution(
            dependencies: dependencies, inputEnvironmentForSession: input,
            sessionTitle: { _ in title }, prepareLaunch: { nil }, perfRecorder: perf
        ))
    }
}
