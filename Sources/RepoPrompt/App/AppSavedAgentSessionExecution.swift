import Foundation
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptShared
import RepoPromptWorkspaceContext

/// App composition for a saved Agent carrier. Dependencies describe app authority, not an
/// active presenter. Runtime publication still happens only through the canonical store.
@MainActor
enum AppSavedAgentSessionExecution {
    typealias Target = AgentSavedSessionTargetLoader.Target
    typealias InstallRoute = (AgentSessionRuntimeHost) async throws -> Void

    struct ApprovedLinkOrigin {
        let observer: DomainAgentSessionLinkEndpointIdentity
        let target: AgentSessionRuntimeStore.WriterIdentity
        let canonicalWriters: [AgentSessionRuntimeStore.WriterIdentity]
    }

    /// Retain both admitted incarnations across the asynchronous administration call.
    static let approvedLinkOrigin = BoxedTaskLocal<ApprovedLinkOrigin?>(nil)

    /// The admission continuation can read canonical bytes asynchronously; the membership
    /// projector stays synchronous and joins this proof to the still-current exact writer.
    static func captureApprovedLinkOrigin(
        observer: DomainAgentSessionLinkEndpointIdentity, writer: AgentSessionRuntimeStore.Writer
    ) async -> ApprovedLinkOrigin {
        let candidates = [writer] + [exactLinkObserverWriter(observer)].compactMap(\.self)
        let allowed = await canonicalLinkWriters(candidates, expectedObserver: observer)
        return .init(observer: observer, target: writer.identity, canonicalWriters: allowed)
    }

    static func revalidateApprovedLinkOrigin(_ origin: ApprovedLinkOrigin, writer: AgentSessionRuntimeStore.Writer) async -> Bool {
        guard origin.target == writer.identity else { return false }
        let candidates = [writer] + [exactLinkObserverWriter(origin.observer)].compactMap(\.self)
        let expected = origin.canonicalWriters
        guard !expected.isEmpty else { return true } // This transaction did not use a canonical fallback.
        let current = await canonicalLinkWriters(candidates.filter { expected.contains($0.identity) }, expectedObserver: origin.observer)
        return expected.allSatisfy { current.contains($0) }
    }

    private static func exactLinkObserverWriter(_ observer: DomainAgentSessionLinkEndpointIdentity) -> AgentSessionRuntimeStore.Writer? {
        guard case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
            sessionID: observer.sessionID, expectedWorkspaceID: observer.workspaceID
        ), writer.scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: observer.tabID) == observer else { return nil }
        return writer
    }

    private static func canonicalLinkWriters(
        _ writers: [AgentSessionRuntimeStore.Writer], expectedObserver: DomainAgentSessionLinkEndpointIdentity
    ) async -> [AgentSessionRuntimeStore.WriterIdentity] {
        let receipts = writers.compactMap { writer in
            writer.scope.executableHost.map { (writer: writer, host: $0, activation: $0.workspaceActivation) }
        }
        guard let runtime = receipts.first?.host.route,
              receipts.allSatisfy({ $0.host.route.domainRuntimeIdentity == runtime.domainRuntimeIdentity })
        else { return [] }
        let snapshots = await runtime.canonicalWorkspaceSnapshots(Set(receipts.map(\.writer.identity.workspaceID)))
        guard !Task.isCancelled else { return [] }
        return receipts.compactMap { receipt -> AgentSessionRuntimeStore.WriterIdentity? in
            let identity = receipt.writer.identity
            let host = receipt.host
            let tabID = receipt.writer.session.tabID
            guard let snapshot = snapshots[identity.workspaceID], snapshot.health != .removed,
                  !host.route.isClosing, host.workspaceActivation === receipt.activation,
                  (try? receipt.writer.admitCommand().get()) != nil,
                  identity.sessionID != expectedObserver.sessionID
                  || receipt.writer.scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: tabID) == expectedObserver
            else { return nil }
            if let activation = receipt.activation {
                guard activation.owns(scope: receipt.writer.scope, route: host.route),
                      activation.executionTab(in: snapshot, workspaceID: identity.workspaceID, tabID: tabID, sessionID: identity.sessionID) != nil
                else { return nil }
            } else {
                let matches = snapshot.contexts.filter { $0.metadata.identity.contextID == tabID && $0.health != .removed }
                let tab = matches.first.flatMap { try? JSONDecoder().decode(ComposeTabState.self, from: $0.metadata.documentBytes) }
                guard matches.count == 1, tab?.id == tabID, tab?.activeAgentSessionID == identity.sessionID else { return nil }
            }
            return identity
        }
    }

    struct ProviderEnvironment {
        let resources: AgentRunProviderComposition
        let settings: APISettingsViewModel
        var claudeControllerFactory: ClaudeAgentModeCoordinator.ClaudeControllerFactory?
        var mcpTransport: MCPService?
    }

    struct Lookup {
        let target: Target
        let catalog: AgentSavedSessionTargetLoader.Catalog
    }

    static func resolve(
        _ sessionID: UUID, domain: MCPDomainRuntime,
        isStillAuthorized: @MainActor () -> Bool
    ) async throws -> Lookup {
        try await resolve(sessionID, store: domain.workspaceStore, isStillAuthorized: isStillAuthorized)
    }

    static func resolve(
        _ sessionID: UUID, store: DomainWorkspaceStore,
        isStillAuthorized: @MainActor () -> Bool
    ) async throws -> Lookup {
        let snapshot = await store.snapshot()
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
            let latest = await store.snapshot()
            guard latest.catalogRevision == snapshot.catalogRevision, latest.unavailableWorkspaceIDs.isEmpty,
                  let current = await store.canonicalWorkspaceSnapshot(candidate.workspace.id), current.health != .removed,
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

    static func hydrateOriginal(
        _ writer: AgentSessionRuntimeStore.Writer, lookup: Lookup,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> AgentSavedSessionTargetLoader.RuntimeLoad {
        guard let host = writer.scope.executableHost, !host.route.isClosing,
              writer.identity.workspaceID == lookup.target.workspace.id else { throw AgentSavedSessionTargetLoader.Failure.changed }
        let workspace = lookup.target.workspace
        let storage = AgentSessionStorageInputs(
            workspaceID: workspace.id, workspaceWithID: { $0 == workspace.id ? workspace : nil },
            displayName: { _ in lookup.target.entry.name }, isSuppressed: { AppLaunchConfiguration.current.suppressesAgentSessionPersistence },
            attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
        )
        let availability = if let available = host.workspaceActivation?.modelAvailability {
            available
        } else {
            try await makeProviderSettings().agentModeAvailabilityContext
        }
        try Task.checkCancellation()
        guard isStillAuthorized(), writer.isCurrent, !host.route.isClosing else {
            throw AgentSavedSessionTargetLoader.Failure.changed
        }
        return try await AgentSavedSessionTargetLoader.loadRuntime(
            sessionID: writer.identity.sessionID, scope: writer.scope, catalog: lookup.catalog, storage: storage,
            selection: { AgentSessionHydrationRuntime.selection(for: $0, availability: availability, codexDynamicModels: nil) },
            codexPolicy: { host.codexCoordinator.selectionPolicy(forModelRaw: $0.modelRaw, includeGlobalFallback: true) },
            isStillAuthorized: { isStillAuthorized() && !host.route.isClosing }, originalColdWriter: writer
        ).get()
    }

    static func compose(
        target: Target, catalog: AgentSavedSessionTargetLoader.Catalog,
        domain: MCPDomainRuntime, installRoute: InstallRoute, providerEnvironment: ProviderEnvironment?,
        rootProbeCheckpoint: WorkspaceRootDirectoryProbe.Checkpoint?, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async throws -> AgentSavedSessionTargetLoader.RuntimeLoad {
        try Task.checkCancellation()
        guard isStillAuthorized(), !AppLaunchConfiguration.current.suppressesAgentSessionPersistence else {
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }

        let workspace = target.workspace
        if !workspace.repoPaths.isEmpty {
            let failure = try await WorkspaceRootDirectoryProbe().run(paths: workspace.repoPaths, attemptID: UUID(), checkpoint: rootProbeCheckpoint)
            try Task.checkCancellation()
            guard isStillAuthorized() else { throw AgentSavedSessionTargetLoader.Failure.changed }
            if let failure { throw AgentSavedSessionTargetLoader.Failure.rootsUnavailable(failure) }
        }
        let providerSettings = if let providerEnvironment { providerEnvironment.settings } else { try await makeProviderSettings() }
        try Task.checkCancellation()
        guard isStillAuthorized() else { throw AgentSavedSessionTargetLoader.Failure.changed }
        let owner = MCPHostRouteResources.LeaseOwner(
            identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: domain.routingCoordinator, runtime: domain
        )
        guard let routeLease = owner.acquire(.execution) else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let route = owner.route
        let settings = GlobalSettingsStore.shared
        let diagnostics = AppAgentSessionLinkCatalogEventSink()
        let perf = AppAgentModePerfRecorder()
        let paths = AgentSessionRuntimeHost.makeSessionWorkspaceProviders { workspace.repoPaths.first }
        let host = AgentSessionRuntimeHost(
            route: route, executionRouteLease: routeLease,
            workspacePath: paths.sessionWorkspacePath, runtimeWorkspacePaths: paths.codexRuntimeWorkspacePaths,
            connectionPolicyInstaller: AgentSessionRuntimeHost.defaultConnectionPolicyInstaller,
            modelRouterSettingsStore: settings, catalogDiagnosticsSink: diagnostics, perfRecorder: perf,
            providerResources: providerEnvironment?.resources, claudeControllerFactory: providerEnvironment?.claudeControllerFactory
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
                do {
                    let root = try await files.loadRoot(path: path, cancelUnderlyingLoadOnCallerCancellation: true)
                    rootIDs.append(root.id)
                } catch {
                    guard isStillAuthorized(), !Task.isCancelled else { throw AgentSavedSessionTargetLoader.Failure.changed }
                    throw AgentSavedSessionTargetLoader.Failure.rootsUnavailable(.loadFailed)
                }
            }
            guard let activation = host.workspaceActivation, isStillAuthorized() else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            try await activation.retainHostFileResources(rootIDs: rootIDs)
            try host.installHostRunExecution(sessionTitle: { _ in target.entry.name }, settings: settings, perf: perf, diagnostics: diagnostics)
            try await installRoute(host)
            var catalog = catalog
            let validateCatalog = catalog.validateCanonicalTarget
            catalog.validateCanonicalTarget = { candidate in
                if let validateCatalog, await !validateCatalog(candidate) { return false }
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

    private static func makeProviderSettings() async throws -> APISettingsViewModel {
        let keys = KeyManager()
        let settings = APISettingsViewModel(aiQueriesService: AIQueriesService(keyManager: keys), keyManager: keys)
        // An approved delivery can dispatch as soon as the writer is published. Ready the app
        // settings before then; a stuck load must not hold the requester, route or writer.
        let ready = await settings.awaitInitialAgentProviderSettings(until: .now.advanced(by: .seconds(8)))
        try Task.checkCancellation()
        guard ready else { throw AgentSavedSessionTargetLoader.Failure.providerSettingsUnavailable }
        return settings
    }
}

extension AgentSessionRuntimeHost {
    /// Shared execution composition for app-resident canonical hosts. Installation needs no
    /// session, window, or presenter; each request supplies its original host resources.
    func installHostRunExecution(
        sessionTitle: @escaping @MainActor (AgentTabSession) -> String, settings: GlobalSettingsStore,
        perf: any AgentModePerfRecording, diagnostics: any AgentSessionLinkCatalogEventSink
    ) throws {
        let links = try installCanonicalLinkExecution(skillCatalog: AgentSkillCatalog(), perfRecorder: perf, diagnostics: diagnostics)
        let enable: AgentRunExecutionContracts.MCPServerEnabler = { [route] in await route.ensureHostProviderTransport() }
        installCodexRuntime(codexCoordinator, routeID: routeID, approvalStore: .shared, links: links, mcpServerEnabler: enable, modelRouterSettingsStore: settings)
        let input = makeCanonicalInputEnvironment()
        claudeCoordinator.installHostCapabilities(
            makeClaudeCapabilities(links: links, inputEnvironmentForSession: input, sessionTitle: sessionTitle),
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
            sessionTitle: sessionTitle, prepareLaunch: { nil }, perfRecorder: perf
        ))
    }
}
