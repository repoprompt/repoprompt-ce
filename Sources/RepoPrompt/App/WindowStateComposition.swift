import Foundation
import MCP
import RepoPromptCore

@MainActor
private final class WorkspaceRuntimePublicationFence {
    private(set) var isClosing = false

    func beginClosing() {
        isClosing = true
    }
}

@MainActor
struct WindowStateComposition {
    let workspaceSessionID: WorkspaceSessionID
    let workspaceRuntimeID: WorkspaceRuntimeID?
    let runtimeAdapter: MCPWindowRuntimeAdapter?
    let workspaceRuntimeBeginClose: @MainActor () -> Void
    let workspaceSessionCommandClient: WorkspaceSessionCommandClient?
    let workspaceSessionQuery: WorkspaceSessionQueryCapability?
    let workspaceSessionObservationBridge: WorkspaceSessionObservationBridge?
    let workspaceSessionActivationTask: Task<Void, Never>?
    let workspaceSessionShutdown: @Sendable () async -> Void
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let workspaceFilesViewModel: WorkspaceFilesViewModel
    let settingsManager: WindowSettingsManager
    let promptManager: PromptViewModel
    let oracleViewModel: OracleViewModel
    let apiSettingsViewModel: APISettingsViewModel
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
}

@MainActor
enum WindowStateCompositionFactory {
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func make(
        windowID: Int,
        deferredInitialAgentSystemWorkspaceRefresh: Bool,
        sharedMCPService: MCPService,
        appCoreContainer injectedAppCoreContainer: RepoPromptAppCoreContainer? = nil,
        contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil,
        aiQueriesServiceFactory: ((_ keyManager: KeyManager) -> AIQueriesService)? = nil,
        workspaceFileContextStore injectedWorkspaceFileContextStore: WorkspaceFileContextStore? = nil,
        workspaceSwitchTimingPolicy: WorkspaceSwitchTimingPolicy = .production,
        loadStoredAPISettingsDataOnInit: Bool = true,
        codexModelPollingService: CodexModelPollingService = .shared
    ) -> WindowStateComposition {
        let appCoreContainer = injectedAppCoreContainer ?? .shared
        let useSelectedSessionComposition = injectedAppCoreContainer != nil || !isRunningUnitTests
        // 1) Workspace file context store + visible file-tree UI adapter
        LegacyWorkspaceGlobalIgnoreDefaults.shared.update(GlobalSettingsStore.shared.globalIgnoreDefaults())
        let storageRoot = resolvedWorkspaceStorageRoot()
        let workspaceFileContextStore: WorkspaceFileContextStore = if let injectedWorkspaceFileContextStore {
            injectedWorkspaceFileContextStore
        } else {
            #if DEBUG
                WorkspaceFileContextStore(enableCatalogShardShadowValidation: false)
            #else
                WorkspaceFileContextStore()
            #endif
        }
        let workspaceSessionLifecycleOwner = useSelectedSessionComposition
            ? WorkspaceSessionStoreLifecycleFactory.make(
                store: workspaceFileContextStore,
                configuration: {
                    let settings = await MainActor.run {
                        GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
                    }
                    return WorkspaceSessionRootLoadConfiguration(
                        respectGitignore: settings.respectGitignore,
                        respectRepoIgnore: settings.respectRepoIgnore,
                        respectCursorignore: settings.respectCursorignore,
                        skipSymlinks: settings.skipSymlinks,
                        enableHierarchicalIgnores: settings.enableHierarchicalIgnores
                    )
                }
            )
            : nil
        let runtimeBootstrap = useSelectedSessionComposition ? appCoreContainer.beginRuntime(
            windowID: windowID,
            coreDependencies: {
                RepoPromptCoreSessionDependencies(
                    load: { try loadWorkspaceHydrationInput(storageRoot: storageRoot) },
                    lifecycleOwner: workspaceSessionLifecycleOwner!,
                    workspaceURL: { workspace in
                        workspace.customStoragePath?.appendingPathComponent("workspace.json")
                            ?? storageRoot
                            .appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
                            .appendingPathComponent("workspace.json")
                    },
                    indexURL: { storageRoot.appendingPathComponent("workspacesIndex.json") }
                )
            },
            legacyFactory: { sessionID in
                let backend = LegacyWorkspaceSessionBackend(
                    sessionID: sessionID,
                    load: { try loadWorkspaceHydrationInput(storageRoot: storageRoot) },
                    lifecycleOwner: workspaceSessionLifecycleOwner!,
                    workspaceURL: { workspace in
                        workspace.customStoragePath?.appendingPathComponent("workspace.json")
                            ?? storageRoot
                            .appendingPathComponent("Workspace-\(workspace.name)-\(workspace.id.uuidString)")
                            .appendingPathComponent("workspace.json")
                    },
                    indexURL: { storageRoot.appendingPathComponent("workspacesIndex.json") }
                )
                return WorkspaceSessionRuntimeBundle(
                    sessionID: sessionID,
                    commandIngress: backend,
                    runtimeQuery: workspaceSessionLifecycleOwner!.makeQueryCapability(),
                    hydrate: { await backend.hydrate() },
                    activateAfterApplyingFirstSnapshot: { sequence in
                        await backend.activate(appliedSnapshotSequence: sequence)
                    },
                    factualProvider: LegacyPromptFactualContextProvider(backend: backend),
                    shutdown: { await backend.shutdown() }
                )
            }
        ) : nil
        let workspaceSessionID = runtimeBootstrap?.sessionID ?? WorkspaceSessionID()
        let workspaceRuntimeID = runtimeBootstrap?.runtimeID
        let mcpCatalogRuntimeID = workspaceRuntimeID
            ?? WorkspaceRuntimeID(rawValue: workspaceSessionID.rawValue)
        let workspaceSessionCommandClient = runtimeBootstrap.map {
            WorkspaceSessionCommandClient(sessionID: $0.sessionID, ingress: $0.commandIngress)
        }
        let workspaceSessionQuery = workspaceSessionLifecycleOwner?.makeQueryCapability()
        let workspaceSearchService = WorkspaceSearchService()
        let workspaceFilesViewModel = WorkspaceFilesViewModel(workspaceFileContextStore: workspaceFileContextStore)

        // 2) AI queries
        let keyManager = KeyManager()
        let aiQueriesService = aiQueriesServiceFactory?(keyManager)
            ?? AIQueriesService(keyManager: keyManager)

        // 3) API Settings
        let apiSettingsViewModel = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: loadStoredAPISettingsDataOnInit,
            codexModelPollingService: codexModelPollingService
        )

        // 5) Settings Manager (per-window overlay)
        let settingsManager = WindowSettingsManager(windowID: windowID)

        // 6) Prompt
        let promptManager = PromptViewModel(
            fileManager: workspaceFilesViewModel,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettingsViewModel,
            windowID: windowID,
            settingsManager: settingsManager,
            workspaceSessionQuery: workspaceSessionQuery
        )
        promptManager.attachPromptFactualContextProvider(
            runtimeBootstrap?.factualProvider ?? UnavailablePromptFactualContextProvider()
        )

        // 7) Create the workspace manager
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: workspaceFilesViewModel,
            promptViewModel: promptManager,
            workspaceSearchService: workspaceSearchService,
            switchTimingPolicy: workspaceSwitchTimingPolicy,
            performInitialWorkspaceActivation: runtimeBootstrap == nil,
            workspaceSessionClient: workspaceSessionCommandClient,
            deferSelectedSessionInitialization: runtimeBootstrap != nil
        )
        let workspaceSessionObservationBridge = runtimeBootstrap.map { bootstrap in
            WorkspaceSessionObservationBridge(
                snapshotProvider: { await bootstrap.commandIngress.currentSnapshot() },
                observationProvider: { sequence in
                    await bootstrap.commandIngress.observations(after: sequence)
                },
                applySnapshot: { [weak workspaceManager] snapshot in
                    workspaceManager?.applyAuthoritativeSessionSnapshot(snapshot)
                    if let runtimeID = runtimeBootstrap?.runtimeID,
                       let adapterRegistry = appCoreContainer.runtimeAdapterRegistry
                    {
                        _ = adapterRegistry.updateSnapshot(
                            runtimeID: runtimeID,
                            sessionID: snapshot.sessionID,
                            authoritativeSnapshot: snapshot
                        )
                    }
                    guard let workspaceManager else { return }
                    let roots = await workspaceSessionQuery?.roots() ?? []
                    await workspaceFilesViewModel.applySessionRootProjection(
                        roots,
                        workspaceID: snapshot.activeWorkspaceID,
                        orderedPrimaryPaths: snapshot.workspaces.first(where: {
                            $0.id == snapshot.activeWorkspaceID
                        })?.repoPaths ?? []
                    )
                }
            )
        }
        if let workspaceSessionCommandClient, let workspaceSessionObservationBridge {
            workspaceSessionCommandClient.bindProjectionWaiter { sequence in
                await workspaceSessionObservationBridge.waitUntilApplied(sequence: sequence)
            }
        }
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
            chatData: chatDataService
        )

        // 11) MCP server (one listener app-wide, this window may be owner)
        let applyEditsApprovalStore = ApplyEditsApprovalStore.shared
        let mcpServer = MCPServerViewModel(
            service: sharedMCPService,
            promptVM: promptManager,
            oracleVM: oracleViewModel,
            workspaceManager: workspaceManager,
            selectionCoordinator: selectionCoordinator,
            windowID: windowID,
            runtimeID: mcpCatalogRuntimeID,
            runtimePublicationInitiallyReady: workspaceRuntimeID == nil,
            workspaceSessionQuery: workspaceSessionQuery,
            workspaceSearch: { [store = workspaceFileContextStore, weak workspaceManager] pattern, mode, isRegex, caseInsensitive, maxPaths, maxMatches, paths, includeExtensions, excludePatterns, contextLines, wholeWord, countOnly, fuzzySpaceMatching, rootScope in
                guard let workspaceManager else {
                    throw MCPError.internalError("The original window UI is no longer available for file_search; the request was not retargeted.")
                }
                return try await StoreBackedWorkspaceSearch.search(
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
            applyEditsApprovalStore: applyEditsApprovalStore
        )
        let runtimeAdapter = workspaceRuntimeID.map { _ in
            MCPWindowRuntimeAdapter(windowState: nil, serverViewModel: mcpServer)
        }
        let runtimePublicationFence = WorkspaceRuntimePublicationFence()
        let closeCoordinator = WindowCloseCoordinator()

        // 12) Context Builder agent (needs mcpServer reference)
        let contextBuilderAgentViewModel = ContextBuilderAgentViewModel(
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            mcpServer: mcpServer,
            oracleViewModel: oracleViewModel,
            providerFactory: contextBuilderProviderFactory,
            codexModelPollingService: codexModelPollingService
        )

        // 13) Agent mode (for minimal agent UI)
        let agentModeViewModel = AgentModeViewModel(
            windowID: windowID,
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            mcpServer: mcpServer,
            oracleViewModel: oracleViewModel,
            applyEditsApprovalStore: applyEditsApprovalStore
        )
        workspaceFilesViewModel.setSessionWorktreeBindingsProvider { [weak agentModeViewModel] sessionID in
            agentModeViewModel?.worktreeBindings(forAgentSessionID: sessionID) ?? []
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

        let publishActivatedRuntime: @MainActor @Sendable (
            WorkspaceSessionRuntimeBundle,
            WorkspaceSessionAdmissionToken,
            WorkspaceSessionSnapshot
        ) async -> Bool = { runtime, initialAdmission, fallbackSnapshot in
            guard !runtimePublicationFence.isClosing else { return false }
            guard let runtimeID = runtime.runtimeID else { return true }
            guard let lifecycle = runtime.runtimeLifecycle,
                  let adapterRegistry = appCoreContainer.runtimeAdapterRegistry,
                  let runtimeAdapter
            else { return false }
            switch await lifecycle.activate(initialAdmission: initialAdmission) {
            case .activated, .alreadyActive:
                break
            case .runtimeNotFound, .sessionMismatch, .activationMismatch, .invalidState:
                return false
            }
            guard !runtimePublicationFence.isClosing else {
                _ = await lifecycle.beginDraining()
                return false
            }
            let routingSnapshot = await runtime.commandIngress.currentSnapshot() ?? fallbackSnapshot
            guard !runtimePublicationFence.isClosing else {
                _ = await lifecycle.beginDraining()
                return false
            }
            let ticket: MCPRuntimeAdapterTicket
            switch adapterRegistry.stage(
                windowID: windowID,
                runtimeID: runtimeID,
                sessionID: runtime.sessionID,
                authoritativeSnapshot: routingSnapshot,
                adapter: runtimeAdapter
            ) {
            case let .staged(stagedTicket):
                ticket = stagedTicket
            case .duplicateRuntimeID, .windowOccupied, .predecessorNotDraining, .sessionMismatch:
                return false
            }
            switch adapterRegistry.activate(ticket: ticket) {
            case let .activated(activeTicket), let .alreadyActive(activeTicket):
                await mcpServer.markRuntimePublicationReady(ticket: activeTicket)
                return true
            case .notFound, .staleTicket, .adapterUnavailable, .invalidState:
                return false
            }
        }

        let workspaceSessionActivationTask: Task<Void, Never>? = if let runtimeBootstrap,
                                                                    let workspaceSessionObservationBridge,
                                                                    let workspaceSessionCommandClient
        {
            Task { @MainActor in
                do {
                    let runtime = try await runtimeBootstrap.runtimeTask.value
                    switch await runtime.hydrate() {
                    case let .awaitingFirstSnapshotApplication(firstSnapshot):
                        await workspaceSessionObservationBridge.applyFirstAuthoritativeSnapshot(firstSnapshot)
                        workspaceSessionObservationBridge.startObserving()
                        let activation = await runtime.activateAfterApplyingFirstSnapshot(
                            firstSnapshot.snapshotSequence
                        )
                        guard case .activated = activation else {
                            workspaceSessionObservationBridge.stop()
                            await runtime.shutdown()
                            appCoreContainer.releaseRuntime(windowID: windowID)
                            return
                        }
                        guard case let .admitted(initialAdmission) = await workspaceSessionCommandClient.acquireAdmission(),
                              await publishActivatedRuntime(runtime, initialAdmission, firstSnapshot)
                        else {
                            workspaceSessionObservationBridge.stop()
                            await runtime.shutdown()
                            appCoreContainer.releaseRuntime(windowID: windowID)
                            return
                        }
                        workspaceManager.completeSelectedSessionInitialization()
                    case let .alreadyHydrated(snapshot):
                        guard let snapshot else {
                            await runtime.shutdown()
                            appCoreContainer.releaseRuntime(windowID: windowID)
                            return
                        }
                        await workspaceSessionObservationBridge.applyFirstAuthoritativeSnapshot(snapshot)
                        workspaceSessionObservationBridge.startObserving()
                        guard case let .admitted(initialAdmission) = await workspaceSessionCommandClient.acquireAdmission(),
                              await publishActivatedRuntime(runtime, initialAdmission, snapshot)
                        else {
                            workspaceSessionObservationBridge.stop()
                            await runtime.shutdown()
                            appCoreContainer.releaseRuntime(windowID: windowID)
                            return
                        }
                        workspaceManager.completeSelectedSessionInitialization()
                    case .failed:
                        await runtime.shutdown()
                        appCoreContainer.releaseRuntime(windowID: windowID)
                        return
                    }
                } catch {
                    appCoreContainer.releaseRuntime(windowID: windowID)
                    return
                }
            }
        } else {
            nil
        }
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
                workspaceSessionID: workspaceSessionID,
                workspaceRuntimeID: workspaceRuntimeID,
                runtimeAdapter: runtimeAdapter,
                workspaceRuntimeBeginClose: {
                    runtimePublicationFence.beginClosing()
                    mcpServer.beginRuntimeClose()
                    if let workspaceRuntimeID {
                        _ = appCoreContainer.runtimeAdapterRegistry?.beginClosing(runtimeID: workspaceRuntimeID)
                    }
                },
                workspaceSessionCommandClient: workspaceSessionCommandClient,
                workspaceSessionQuery: workspaceSessionQuery,
                workspaceSessionObservationBridge: workspaceSessionObservationBridge,
                workspaceSessionActivationTask: workspaceSessionActivationTask,
                workspaceSessionShutdown: {
                    if let runtimeBootstrap, let runtime = try? await runtimeBootstrap.runtimeTask.value {
                        await runtime.shutdown()
                        await MainActor.run {
                            if let workspaceRuntimeID {
                                _ = appCoreContainer.runtimeAdapterRegistry?.markRemoved(runtimeID: workspaceRuntimeID)
                                _ = appCoreContainer.runtimeAdapterRegistry?.purgeRemoved(runtimeID: workspaceRuntimeID)
                            }
                            appCoreContainer.releaseRuntime(windowID: windowID)
                        }
                    }
                },
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceFilesViewModel: workspaceFilesViewModel,
                settingsManager: settingsManager,
                promptManager: promptManager,
                oracleViewModel: oracleViewModel,
                apiSettingsViewModel: apiSettingsViewModel,
                contextBuilderAgentViewModel: contextBuilderAgentViewModel,
                agentModeViewModel: agentModeViewModel,
                agentChatStressHarness: agentChatStressHarness,
                mcpServer: mcpServer,
                closeCoordinator: closeCoordinator,
                keyManager: keyManager,
                aiQueriesService: aiQueriesService,
                chatDataService: chatDataService,
                workspaceManager: workspaceManager
            )
        #else
            return WindowStateComposition(
                workspaceSessionID: workspaceSessionID,
                workspaceRuntimeID: workspaceRuntimeID,
                runtimeAdapter: runtimeAdapter,
                workspaceRuntimeBeginClose: {
                    runtimePublicationFence.beginClosing()
                    mcpServer.beginRuntimeClose()
                    if let workspaceRuntimeID {
                        _ = appCoreContainer.runtimeAdapterRegistry?.beginClosing(runtimeID: workspaceRuntimeID)
                    }
                },
                workspaceSessionCommandClient: workspaceSessionCommandClient,
                workspaceSessionQuery: workspaceSessionQuery,
                workspaceSessionObservationBridge: workspaceSessionObservationBridge,
                workspaceSessionActivationTask: workspaceSessionActivationTask,
                workspaceSessionShutdown: {
                    if let runtimeBootstrap, let runtime = try? await runtimeBootstrap.runtimeTask.value {
                        await runtime.shutdown()
                        await MainActor.run {
                            if let workspaceRuntimeID {
                                _ = appCoreContainer.runtimeAdapterRegistry?.markRemoved(runtimeID: workspaceRuntimeID)
                                _ = appCoreContainer.runtimeAdapterRegistry?.purgeRemoved(runtimeID: workspaceRuntimeID)
                            }
                            appCoreContainer.releaseRuntime(windowID: windowID)
                        }
                    }
                },
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceFilesViewModel: workspaceFilesViewModel,
                settingsManager: settingsManager,
                promptManager: promptManager,
                oracleViewModel: oracleViewModel,
                apiSettingsViewModel: apiSettingsViewModel,
                contextBuilderAgentViewModel: contextBuilderAgentViewModel,
                agentModeViewModel: agentModeViewModel,
                mcpServer: mcpServer,
                closeCoordinator: closeCoordinator,
                keyManager: keyManager,
                aiQueriesService: aiQueriesService,
                chatDataService: chatDataService,
                workspaceManager: workspaceManager
            )
        #endif
    }

    private static func resolvedWorkspaceStorageRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL") {
            return URL(fileURLWithPath: path)
        }
        return WorkspaceStoragePaths.defaultRoot
    }

    private nonisolated static func loadWorkspaceHydrationInput(
        storageRoot: URL
    ) throws -> WorkspaceSessionHydrationInput {
        let indexURL = storageRoot.appendingPathComponent("workspacesIndex.json")
        let entries: [WorkspaceIndexEntry] = if FileManager.default.fileExists(atPath: indexURL.path) {
            (try? JSONDecoder().decode([WorkspaceIndexEntry].self, from: Data(contentsOf: indexURL))) ?? []
        } else {
            []
        }
        var workspaces: [WorkspaceModel] = []
        for entry in entries {
            let url = entry.customStoragePath?.appendingPathComponent("workspace.json")
                ?? storageRoot
                .appendingPathComponent("Workspace-\(entry.name)-\(entry.id.uuidString)")
                .appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let workspace = try? JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: url))
            else { continue }
            workspaces.append(workspace)
        }
        if workspaces.isEmpty {
            workspaces = [WorkspaceModel(name: "Default", repoPaths: [], isSystemWorkspace: true)]
        }
        let activeID = workspaces.first(where: \.isSystemWorkspace)?.id ?? workspaces.first?.id
        return WorkspaceSessionHydrationInput(workspaces: workspaces, activeWorkspaceID: activeID)
    }
}
