import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptPersistence
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext

extension CodeMapArtifactRuntime {
    static let processWideProvider: CodeMapArtifactRuntimeProvider = {
        let identity = WorkspaceContextFilesystemIdentity.identity
        return makeProcessWideProvider(
            identity: identity,
            applicationSupportRootURL: identity.applicationSupportRootURL(),
            postSuccessfulInitialization: {
                #if !DEBUG
                    CodeMapV6CacheDeletionScheduler.schedule()
                #endif
            },
            globalCodeMapsDisabled: {
                await MainActor.run { GlobalSettingsStore.shared.globalCodeMapsDisabled() }
            },
            bindingEngineDidInitialize: { engine in
                Task { @MainActor in
                    CodeMapGlobalDisableObservation.processWide = CodeMapGlobalDisableObservation(engine: engine)
                    await engine.refreshGlobalCodeMapsDisabled()
                }
            }
        )
    }()
}

/// Production composition retains settings observation; isolated runtimes have no user-settings dependency.
@MainActor
final class CodeMapGlobalDisableObservation {
    static var processWide: CodeMapGlobalDisableObservation?
    private var subscription: AnyCancellable?

    init(engine: WorkspaceCodemapBindingEngine) {
        subscription = GlobalSettingsStore.shared.$codeMapsGloballyDisabled
            .removeDuplicates()
            .sink { [weak engine] _ in
                Task { await engine?.refreshGlobalCodeMapsDisabled() }
            }
    }
}

@MainActor
struct WindowStateComposition {
    let workspaceResources: AgentHostWorkspaceResources
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let workspaceFilesViewModel: WorkspaceFilesViewModel
    let settingsManager: WindowSettingsManager
    let promptManager: PromptViewModel
    let oracleViewModel: OracleViewModel
    let apiSettingsViewModel: APISettingsViewModel
    let routerSettingsViewModel: RouterSettingsViewModel
    let contextBuilderAgentViewModel: ContextBuilderAgentViewModel
    let agentModeViewModel: AgentModeViewModel
    #if DEBUG
        let agentChatStressHarness: AgentChatStressHarness?
    #endif
    let mcpServer: MCPServerViewModel
    let closeCoordinator: WindowCloseCoordinator
    let keyManager: KeyManager
    let aiQueriesService: AIQueriesService
    let chatDataService: ChatDataService
    let workspaceManager: WorkspaceManagerViewModel
    let domainWorkspacePresentationBridge: DomainWorkspacePresentationBridge?
}

@MainActor
enum WindowStateCompositionFactory {
    typealias AgentModeViewModelFactory = (Int, PromptViewModel, WorkspaceManagerViewModel, MCPServerViewModel) -> AgentModeViewModel
    typealias VisibleAgentInstaller = @MainActor (AgentSessionRuntimeHost, AgentHostWorkspaceResources.Lease) async throws -> Void

    /// Prepare one unpublished visible activation. Execution and the catalog live on its
    /// independent route; the physical window route remains for non-Agent tools.
    static func prepareVisibleAgentHost(
        workspace: WorkspaceModel,
        owner: AgentWorkspaceSessionIndexStore.SessionIndexOwner,
        activations: AgentWorkspaceSessionIndexStore,
        resources: AgentHostWorkspaceResources,
        apiSettings: APISettingsViewModel,
        settingsStore: GlobalSettingsStore,
        runtime: MCPDomainRuntime,
        providerResources: AgentRunProviderComposition? = nil,
        installExecutionAndCatalog: VisibleAgentInstaller
    ) async throws -> AgentSessionRuntimeHost {
        guard !Task.isCancelled, owner.workspaceID == workspace.id, activations.latestSessionIndexOwner == owner,
              let settings = APISettingsRuntimeLease.acquire(from: apiSettings)
        else {
            AgentModeViewModel.workspaceActivationLog.error(
                "Host admission refused. epoch=\(owner.activationEpoch) cancelled=\(Task.isCancelled) ownerMatchesWorkspace=\(owner.workspaceID == workspace.id) ownerIsLatest=\(activations.latestSessionIndexOwner == owner)"
            )
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let leases = MCPHostRouteResources.LeaseOwner(
            identity: MCPRouteIdentityAllocator.allocateHost(), coordinator: runtime.routingCoordinator, runtime: runtime
        )
        guard let executionLease = leases.acquire(.execution) else {
            AgentModeViewModel.workspaceActivationLog.error("Execution route lease refused. epoch=\(owner.activationEpoch)")
            settings.release()
            throw AgentHostWorkspaceResources.Failure.authorityUnavailable
        }
        let route = leases.route
        let authority = DomainWorkspaceAuthorityClient(
            store: runtime.workspaceStore, windowID: route.identity.routeID,
            metadataPathPolicy: runtime.configuration.metadataPathPolicy
        )
        let paths = AgentSessionRuntimeHost.makeSessionWorkspaceProviders { workspace.repoPaths.first }
        let host = AgentSessionRuntimeHost(
            route: route, executionRouteLease: executionLease,
            workspacePath: paths.sessionWorkspacePath, runtimeWorkspacePaths: paths.codexRuntimeWorkspacePaths,
            connectionPolicyInstaller: AgentSessionRuntimeHost.defaultConnectionPolicyInstaller,
            modelRouterSettingsStore: settingsStore, catalogDiagnosticsSink: AppAgentSessionLinkCatalogEventSink(),
            perfRecorder: AppAgentModePerfRecorder(), providerResources: providerResources
        )
        // This physical route is exclusive to the activation; the UI attaches to the scope,
        // not the route. Disposal now waits for the one execution lease's acknowledgement.
        await leases.requestTerminalDisposal()
        var stage = "check presenter epoch"
        do {
            try Task.checkCancellation()
            guard activations.latestSessionIndexOwner == owner else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            stage = "compose workspace activation"
            let activation = try AgentSessionHostWorkspaceActivation(
                windowID: host.routeID, authority: authority, activations: activations,
                resources: AgentHostWorkspaceResources(files: resources.files, contexts: runtime.contextStore), settings: settings
            )
            stage = "install workspace activation"
            try await host.installWorkspaceActivation(
                activation, attachmentWorkspaceDirectory: FileManager.default.temporaryDirectory,
                suppressesAttachmentPersistence: AppLaunchConfiguration.current.suppressesAgentSessionPersistence
            )
            try Task.checkCancellation()
            stage = "check installed presenter currency"
            guard activation.isPresenterCurrent else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            stage = "retain visible file resources"
            let originalRoots = try await activation.retainVisibleFileResources()
            stage = "install execution and model catalog"
            try await installExecutionAndCatalog(host, originalRoots)
            stage = "validate composed host"
            let current = await authority.canonicalWorkspaceSnapshot(workspace.id)
            try Task.checkCancellation()
            let checks = [
                ("workspace present", current.map { $0.health != .removed } == true),
                ("workspace paths match", current?.document.metadata.repoPaths == originalRoots.snapshot.document.metadata.repoPaths),
                ("presenter current", activation.isPresenterCurrent),
                ("roots current", originalRoots.rootsAreCurrent),
                ("no sessions admitted", host.scope.sessions.isEmpty),
                ("execution installed", host.scope.execution != nil),
                ("link execution installed", host.scope.linkExecution != nil),
                ("interactions installed", host.scope.installedInteractions != nil),
                ("persistence installed", host.scope.persistence.composition != nil),
                ("model catalog route current", route.hasCurrentModelCatalogRoute)
            ]
            let failedChecks = checks.filter { !$0.1 }.map(\.0)
            guard failedChecks.isEmpty else {
                stage = "validate composed host: \(failedChecks.joined(separator: ", "))"
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            return host
        } catch {
            let failure = (error as? AgentHostWorkspaceResources.Failure).map { String(describing: $0) }
                ?? String(describing: type(of: error))
            AgentModeViewModel.workspaceActivationLog.error(
                "Host preparation failed. route=\(host.routeID) epoch=\(owner.activationEpoch) stage=\(stage, privacy: .public) failure=\(failure, privacy: .public)"
            )
            await host.discardUnpublishedVisibleCandidate()
            if host.workspaceActivation == nil { settings.release() }
            throw error
        }
    }

    private static func installVisibleExecution(
        _ host: AgentSessionRuntimeHost, roots: AgentHostWorkspaceResources.Lease,
        settings: GlobalSettingsStore, service: MCPService
    ) async throws {
        guard let activation = host.workspaceActivation, activation.catalogFileLease === roots,
              let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: roots.snapshot.document.documentBytes)
        else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
        let storage = AgentSessionStorageInputs(
            workspaceID: workspace.id, workspaceWithID: { $0 == workspace.id ? workspace : nil },
            displayName: { _ in AgentSessionRestoreSupport.normalizedSessionTitle(nil) }, isSuppressed: { AppLaunchConfiguration.current.suppressesAgentSessionPersistence },
            attachmentWorkspaceDirectory: { FileManager.default.temporaryDirectory }
        )
        var persistence = storage.persistenceComposition(
            scope: host.scope, canonicalStorage: .init(workspaceID: workspace.id) { id in
                guard let snapshot = await activation.authority.canonicalWorkspaceSnapshot(id), snapshot.health != .removed else { return nil }
                return try? JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
            }
        )
        persistence.canonicalDisplayName = { workspace, tabID in
            let tab = workspace.composeTabs.first { $0.id == tabID }
                ?? workspace.stashedTabs.first { $0.tab.id == tabID }?.tab
            return tab.map { AgentSessionRestoreSupport.normalizedSessionTitle($0.name) }
        }
        host.scope.persistence.composition = persistence
        host.scope.persistence.observeRetainedVisibleDrain = { drain in
            WindowStatesManager.shared.observeAgentHostDrainRecovery(drain)
        }
        let perf = AppAgentModePerfRecorder()
        host.scope.persistence.perfRecorder = perf
        try host.installHostRunExecution(
            sessionTitle: { persistence.displayName(for: $0.tabID, in: workspace) }, settings: settings,
            perf: perf, diagnostics: AppAgentSessionLinkCatalogEventSink()
        )
        host.scope.mcp.installRunRoute(id: host.routeID, bindings: host.route.runRouteBindings)
        host.scope.mcp.codexCoordinator = host.codexCoordinator
        host.scope.mcp.claudeCoordinator = host.claudeCoordinator
        _ = host.scope.interactions(routeID: host.routeID, approvalStore: .shared)
        try await host.registerHostCatalog(service: service)
    }

    static func make(
        windowID: Int,
        deferredInitialAgentSystemWorkspaceRefresh: Bool,
        sharedMCPService: MCPService,
        settingsStore: GlobalSettingsStore = .shared,
        domainRuntime: MCPDomainRuntime? = nil,
        contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil,
        keyManager injectedKeyManager: KeyManager? = nil,
        aiQueriesServiceFactory: ((_ keyManager: KeyManager) -> AIQueriesService)? = nil,
        workspaceFileContextStore injectedWorkspaceFileContextStore: WorkspaceFileContextStore? = nil,
        workspaceSearchService injectedWorkspaceSearchService: WorkspaceSearchService? = nil,
        storedPromptPersistence: (any StoredPromptPersistenceServing)? = nil,
        workspaceSwitchTimingPolicy: WorkspaceSwitchTimingPolicy = .production,
        loadStoredAPISettingsDataOnInit: Bool = true,
        automaticProviderModelDiscoveryEnabled: Bool = true,
        codexModelPollingService: CodexModelPollingService = .shared,
        modelRouterRuntime injectedModelRouterRuntime: AgentTaskRouterRuntime? = nil,
        agentModeViewModelFactory: AgentModeViewModelFactory? = nil,
        visibleAgentProviderResources: AgentRunProviderComposition? = nil
    ) -> WindowStateComposition {
        WorkspaceContextStartupInstrumentation.install(AppWorkspaceStartupEventRecorder())
        WorkspaceExternalReadWorkHooks.install(AppWorkspaceExternalReadWorkRecorder())
        #if DEBUG
            WorkspacePreparationInstrumentation.install(AppWorkspacePreparationRecorderProvider())
            WorkspaceRootLoadFieldHooks.install(AppWorkspaceRootLoadFieldProvider())
            WorkspaceApplyEditsRebaseProbeHooks.install(AppWorkspaceApplyEditsRebaseProbeRecorder())
        #endif
        let modelRouterRuntime = injectedModelRouterRuntime ?? WindowStatesManager.shared.modelRouterRuntime
        // 1) Workspace file context store + visible file-tree UI adapter
        let workspaceResources = AgentHostWorkspaceResources(
            files: injectedWorkspaceFileContextStore ?? AgentHostWorkspaceResources.makeFiles(settingsStore: settingsStore),
            contexts: domainRuntime?.contextStore
        )
        let workspaceFileContextStore = workspaceResources.files
        let workspaceSearchService = injectedWorkspaceSearchService ?? WorkspaceSearchService()
        let workspaceFilesViewModel = WorkspaceFilesViewModel(
            workspaceFileContextStore: workspaceFileContextStore,
            restorePerfRecorder: AppWorkspaceRestorePerfRecorder()
        )
        if injectedWorkspaceFileContextStore == nil {
            workspaceFilesViewModel.bindNonGitCodeMapsSetting(settingsStore)
            workspaceFilesViewModel.bindGlobalCodeMapsSetting(settingsStore)
        }

        // 2) AI queries
        let keyManager = injectedKeyManager ?? KeyManager()
        let aiQueriesService = aiQueriesServiceFactory?(keyManager)
            ?? AIQueriesService(keyManager: keyManager)

        // 3) API Settings
        let apiSettingsViewModel = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: loadStoredAPISettingsDataOnInit && automaticProviderModelDiscoveryEnabled,
            codexModelPollingService: codexModelPollingService
        )

        // 5) Settings Manager (per-window overlay)
        let settingsManager = WindowSettingsManager(windowID: windowID, store: settingsStore)

        // 6) Prompt
        let promptManager = PromptViewModel(
            fileManager: workspaceFilesViewModel,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettingsViewModel,
            windowID: windowID,
            settingsManager: settingsManager,
            storedPromptPersistence: storedPromptPersistence,
            refreshAvailableModelsOnInit: loadStoredAPISettingsDataOnInit && automaticProviderModelDiscoveryEnabled,
            perfRecorder: AppAgentModePerfRecorder()
        )

        // 7) The workspace manager projects the domain's workspace authority into this presenter.
        let domainWorkspaceClient = domainRuntime.map {
            DomainWorkspaceAuthorityClient(store: $0.workspaceStore, windowID: windowID, metadataPathPolicy: $0.configuration.metadataPathPolicy)
        }
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: workspaceFilesViewModel,
            promptViewModel: promptManager,
            workspaceSearchService: workspaceSearchService,
            domainWorkspaceAuthorityClient: domainWorkspaceClient,
            switchTimingPolicy: workspaceSwitchTimingPolicy,
            restorePerfRecorder: AppWorkspaceRestorePerfRecorder()
        )
        let routerSettingsViewModel = RouterSettingsViewModel(
            settingsStore: settingsStore,
            runtime: modelRouterRuntime,
            apiSettingsViewModel: apiSettingsViewModel,
            workspaceManager: workspaceManager
        )
        let domainWorkspacePresentationBridge = domainWorkspaceClient.map {
            DomainWorkspacePresentationBridge(workspaceManager: workspaceManager, client: $0)
        }
        if let bridge = domainWorkspacePresentationBridge {
            // Weak captures: the Bridge already holds the manager weakly; no retain cycle or new owner.
            workspaceManager.installDomainCatalogRefresh(
                request: { [weak bridge] isRetry in bridge?.requestCatalogRefresh(isRetry: isRetry) },
                cancel: { [weak bridge] in bridge?.cancelCatalogRefresh() },
                awaitRefresh: { [weak bridge] in await bridge?.refreshForAgentAdmission() ?? false }
            )
        }
        domainWorkspacePresentationBridge?.start()
        let selectionCoordinator = WorkspaceSelectionCoordinator(
            workspaceManager: workspaceManager,
            store: workspaceFileContextStore
        )
        workspaceFilesViewModel.attachSelectionCoordinator(selectionCoordinator)
        workspaceManager.attachSelectionCoordinator(selectionCoordinator)
        promptManager.attachSelectionCoordinator(selectionCoordinator)

        // 10) Chat
        let chatDataService = ChatDataService()
        let oracleViewModel = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: promptManager,
            workspaceManager: workspaceManager,
            chatData: chatDataService,
            restorePerfRecorder: AppWorkspaceRestorePerfRecorder()
        )

        // 11) MCP server (one listener app-wide, this window may be owner)
        let applyEditsApprovalStore = ApplyEditsApprovalStore.shared
        let routeResources = MCPHostRouteResources(
            identity: .legacyWindow(windowID), coordinator: domainRuntime?.routingCoordinator,
            runtime: domainRuntime ?? AppDomainRuntimeComposition.shared.runtime
        )
        let mcpServer = MCPServerViewModel(
            service: sharedMCPService,
            perfRecorder: AppAgentModePerfRecorder(),
            promptVM: promptManager,
            oracleVM: oracleViewModel,
            workspaceManager: workspaceManager,
            selectionCoordinator: selectionCoordinator,
            windowID: windowID,
            workspaceSearch: { [store = workspaceFileContextStore, workspaceManager] pattern, mode, isRegex, caseInsensitive, maxPaths, maxMatches, paths, includeExtensions, excludePatterns, contextLines, wholeWord, countOnly, fuzzySpaceMatching, rootScope in
                try await StoreBackedWorkspaceSearch.search(
                    pattern: pattern,
                    mode: mode,
                    isRegex: isRegex,
                    caseInsensitive: caseInsensitive,
                    maxPaths: maxPaths,
                    maxMatches: maxMatches,
                    paths: paths,
                    includeExtensions: includeExtensions,
                    excludePatterns: excludePatterns,
                    contextLines: contextLines,
                    wholeWord: wholeWord,
                    countOnly: countOnly,
                    fuzzySpaceMatching: fuzzySpaceMatching,
                    rootScope: rootScope,
                    store: store,
                    workspaceManager: workspaceManager
                )
            },
            ensureGitDataRootLoaded: { [fileManager = workspaceFilesViewModel] workspace, workspaceManager in
                try await fileManager.ensureGitDataRootLoaded(
                    workspace: workspace,
                    workspaceManager: workspaceManager
                )
            },
            domainRoutingCoordinator: domainRuntime?.routingCoordinator,
            routeResources: routeResources,
            domainWorkspaceAuthorityClient: domainWorkspaceClient,
            domainReadSideEffectCoordinator: domainRuntime?.readSideEffectCoordinator,
            domainReadRuntimeIdentity: domainRuntime?.identity,
            applyEditsApprovalStore: applyEditsApprovalStore
        )
        let closeCoordinator = WindowCloseCoordinator()

        // 12) Context Builder agent (needs mcpServer reference)
        let contextBuilderAgentViewModel = ContextBuilderAgentViewModel(
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            mcpServer: mcpServer,
            oracleViewModel: oracleViewModel,
            settingsManager: settingsStore,
            providerFactory: contextBuilderProviderFactory,
            codexModelPollingService: codexModelPollingService,
            automaticModelPollingEnabled: automaticProviderModelDiscoveryEnabled,
            perfRecorder: AppAgentModePerfRecorder()
        )

        // 13) Bootstrap the presenter. A real workspace activation replaces the empty bootstrap
        // scope with an independent canonical host before restoring or creating its sessions.
        let agentModeViewModel: AgentModeViewModel
        if let agentModeViewModelFactory {
            agentModeViewModel = agentModeViewModelFactory(windowID, promptManager, workspaceManager, mcpServer)
        } else {
            let paths = AgentSessionRuntimeHost.makeSessionWorkspaceProviders { [weak workspaceManager] in
                workspaceManager?.activeWorkspace?.repoPaths.first
            }
            let runtimeHost = AgentSessionRuntimeHost(
                route: routeResources,
                workspacePath: paths.sessionWorkspacePath,
                runtimeWorkspacePaths: paths.codexRuntimeWorkspacePaths,
                connectionPolicyInstaller: AgentSessionRuntimeHost.defaultConnectionPolicyInstaller,
                modelRouterSettingsStore: settingsStore,
                catalogDiagnosticsSink: AppAgentSessionLinkCatalogEventSink(),
                perfRecorder: AppAgentModePerfRecorder()
            )
            agentModeViewModel = AgentModeViewModel(
                windowID: windowID,
                runtimeHost: runtimeHost,
                promptManager: promptManager,
                workspaceManager: workspaceManager,
                mcpServer: mcpServer,
                attachmentPersistenceIsSuppressed: { AppLaunchConfiguration.current.suppressesAgentSessionPersistence },
                oracleViewModel: oracleViewModel,
                applyEditsApprovalStore: applyEditsApprovalStore,
                modelRouterSettingsStore: settingsStore,
                modelRouterRuntime: modelRouterRuntime,
                usesProductionAgentDefaultsAndModelPolling: automaticProviderModelDiscoveryEnabled,
                catalogDiagnosticsSink: AppAgentSessionLinkCatalogEventSink(),
                restorePerfRecorder: AppWorkspaceRestorePerfRecorder(),
                perfRecorder: AppAgentModePerfRecorder()
            )
        }
        if agentModeViewModelFactory == nil, let domainRuntime {
            agentModeViewModel.canonicalWorkspaceHostPreparation = { workspace, owner, activations in
                try await prepareVisibleAgentHost(
                    workspace: workspace, owner: owner, activations: activations,
                    resources: workspaceResources, apiSettings: apiSettingsViewModel, settingsStore: settingsStore,
                    runtime: domainRuntime, providerResources: visibleAgentProviderResources
                ) { host, roots in
                    try await installVisibleExecution(host, roots: roots, settings: settingsStore, service: sharedMCPService)
                }
            }
        }
        agentModeViewModel.repromptService = .live(keyManager: keyManager)
        agentModeViewModel.preparedSessionRuntimes = WindowStatesManager.shared
        agentModeViewModel.providerSwitchExactOwnerProbe = { session in
            guard let id = session.activeAgentSessionID else { return false }
            if let binding = session.persistentSessionBindingIdentity,
               case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(sessionID: id, expectedWorkspaceID: binding.workspaceID),
               let host = writer.scope.executableHost, let activation = host.workspaceActivation
            {
                return writer.session === session && writer.isCurrent && activation.owns(scope: writer.scope, route: host.route)
            }
            guard domainRuntime == nil || agentModeViewModelFactory != nil else { return false }
            let census = AgentSessionCarrierResolver.capture(
                windows: WindowStatesManager.shared.allWindows,
                sessionIDs: [id],
                includeRuntimeOwners: true
            )
            return census.isCurrent() && !census.ambiguousSessionIDs.contains(id)
                && !census.placementConflictSessionIDs.contains(id) && census.uniqueRuntimeOwners[id]?.session === session
        }
        workspaceFilesViewModel.setSessionWorktreeBindingStatesProvider { [weak agentModeViewModel] sessionIDs in
            agentModeViewModel?.worktreeBindingStates(forAgentSessionIDs: sessionIDs) ?? [:]
        }
        if deferredInitialAgentSystemWorkspaceRefresh {
            agentModeViewModel.deferInitialSystemWorkspaceSessionListRefresh(reason: "programmaticNewWindowWorkspaceSwitch")
        }

        #if DEBUG
            let agentChatStressHarness: AgentChatStressHarness? = if let stressConfiguration = AppLaunchConfiguration.current.agentChatStress {
                AgentChatStressHarness(
                    configuration: stressConfiguration,
                    agentModeViewModel: agentModeViewModel,
                    promptManager: promptManager,
                    workspaceManager: workspaceManager,
                    windowID: windowID
                )
            } else {
                nil
            }
        #endif

        // 14) Register workspace switch session providers
        workspaceManager.registerSwitchSessionProvider(
            ChatWorkspaceSwitchSessionProvider(
                workspaceManager: workspaceManager,
                oracleViewModel: oracleViewModel
            )
        )
        workspaceManager.registerSwitchSessionProvider(
            ContextBuilderWorkspaceSwitchSessionProvider(
                contextBuilderAgentViewModel: contextBuilderAgentViewModel
            )
        )
        workspaceManager.registerSwitchSessionProvider(
            AgentModeWorkspaceSwitchSessionProvider(
                agentModeViewModel: agentModeViewModel
            )
        )

        #if DEBUG
            return WindowStateComposition(
                workspaceResources: workspaceResources,
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceFilesViewModel: workspaceFilesViewModel,
                settingsManager: settingsManager,
                promptManager: promptManager,
                oracleViewModel: oracleViewModel,
                apiSettingsViewModel: apiSettingsViewModel,
                routerSettingsViewModel: routerSettingsViewModel,
                contextBuilderAgentViewModel: contextBuilderAgentViewModel,
                agentModeViewModel: agentModeViewModel,
                agentChatStressHarness: agentChatStressHarness,
                mcpServer: mcpServer,
                closeCoordinator: closeCoordinator,
                keyManager: keyManager,
                aiQueriesService: aiQueriesService,
                chatDataService: chatDataService,
                workspaceManager: workspaceManager,
                domainWorkspacePresentationBridge: domainWorkspacePresentationBridge
            )
        #else
            return WindowStateComposition(
                workspaceResources: workspaceResources,
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceFilesViewModel: workspaceFilesViewModel,
                settingsManager: settingsManager,
                promptManager: promptManager,
                oracleViewModel: oracleViewModel,
                apiSettingsViewModel: apiSettingsViewModel,
                routerSettingsViewModel: routerSettingsViewModel,
                contextBuilderAgentViewModel: contextBuilderAgentViewModel,
                agentModeViewModel: agentModeViewModel,
                mcpServer: mcpServer,
                closeCoordinator: closeCoordinator,
                keyManager: keyManager,
                aiQueriesService: aiQueriesService,
                chatDataService: chatDataService,
                workspaceManager: workspaceManager,
                domainWorkspacePresentationBridge: domainWorkspacePresentationBridge
            )
        #endif
    }
}
