import Foundation

@MainActor
struct WindowStateComposition {
    let coreSessionHandle: RepoPromptCoreSessionHandle
    let workspaceFileContextStore: WorkspaceFileContextStore
    let workspaceSearchService: WorkspaceSearchService
    let selectionCoordinator: WorkspaceSelectionCoordinator
    let workspaceObservation: WorkspaceSessionObservationBridge
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
    static func make(
        windowID: Int,
        deferredInitialAgentSystemWorkspaceRefresh: Bool,
        coreContainer: RepoPromptAppCoreContainer
    ) -> WindowStateComposition {
        // 1) Reusable session graph + visible file-tree UI adapter
        let coreSessionHandle = coreContainer.coreHost.makeEmbeddedSession(
            routingSessionID: MCPRoutingSessionID(rawValue: windowID)
        )
        let coreSession = coreSessionHandle.session
        let workspaceFileContextStore = coreSession.workspaceFileContextStore
        let workspaceSearchService = coreSession.workspaceSearchService
        let workspaceFilesViewModel = WorkspaceFilesViewModel(
            workspaceFileContextStore: workspaceFileContextStore,
            selectionSliceCoordinator: coreSession.selectionSliceCoordinator
        )

        // 2) AI queries
        let keyManager = KeyManager()
        let aiQueriesService = AIQueriesService(keyManager: keyManager)

        // 3) API Settings
        let apiSettingsViewModel = APISettingsViewModel(aiQueriesService: aiQueriesService, keyManager: keyManager)

        // 5) Settings Manager (per-window overlay)
        let settingsManager = WindowSettingsManager(windowID: windowID)

        // 6) Prompt
        let promptManager = PromptViewModel(
            fileManager: workspaceFilesViewModel,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettingsViewModel,
            windowID: windowID,
            settingsManager: settingsManager
        )

        // 7) Create the workspace adapter over the authoritative Core session controller.
        let workspaceObservation = WorkspaceSessionObservationBridge(
            controller: coreSession.workspaceSessionController
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: workspaceFilesViewModel,
            promptViewModel: promptManager,
            workspaceSearchService: workspaceSearchService,
            workspaceRepository: coreContainer.workspaceRepository,
            sessionController: coreSession.workspaceSessionController,
            workspaceObservation: workspaceObservation
        )
        let searchReadinessSource = WorkspaceManagerSearchReadinessSource(workspaceManager)
        let selectionCoordinator = coreSession.selectionCoordinator
        selectionCoordinator.attachWorkspaceManager(workspaceManager)
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
            service: coreContainer.mcpService,
            promptVM: promptManager,
            oracleVM: oracleViewModel,
            workspaceManager: workspaceManager,
            selectionCoordinator: selectionCoordinator,
            coreSessionHandle: coreSessionHandle,
            appSessionAdapters: coreContainer.appSessionAdapters,
            windowID: windowID,
            workspaceSearch: { [store = workspaceFileContextStore, searchService = workspaceSearchService, searchReadinessSource] pattern, mode, isRegex, caseInsensitive, maxPaths, maxMatches, paths, includeExtensions, excludePatterns, contextLines, wholeWord, countOnly, fuzzySpaceMatching, rootScope in
                try await withEmbeddedWorkspaceRuntimeDiagnostics {
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
                        searchService: searchService,
                        readinessSource: searchReadinessSource
                    )
                }
            },
            ensureGitDataRootLoaded: { [fileManager = workspaceFilesViewModel] workspace, workspaceManager in
                guard let workspace, let workspaceManager else { return }
                await fileManager.ensureGitDataRootLoaded(workspace: workspace, workspaceManager: workspaceManager)
            },
            applyEditsApprovalStore: applyEditsApprovalStore
        )
        let closeCoordinator = WindowCloseCoordinator()

        // 12) Context Builder agent (needs mcpServer reference)
        let contextBuilderAgentViewModel = ContextBuilderAgentViewModel(
            promptManager: promptManager,
            workspaceManager: workspaceManager,
            mcpServer: mcpServer,
            oracleViewModel: oracleViewModel
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
                coreSessionHandle: coreSessionHandle,
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceObservation: workspaceObservation,
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
                coreSessionHandle: coreSessionHandle,
                workspaceFileContextStore: workspaceFileContextStore,
                workspaceSearchService: workspaceSearchService,
                selectionCoordinator: selectionCoordinator,
                workspaceObservation: workspaceObservation,
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
}
