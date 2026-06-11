import Foundation

@MainActor
struct WindowStateComposition {
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
    static func make(
        windowID: Int,
        deferredInitialAgentSystemWorkspaceRefresh: Bool,
        sharedMCPService: MCPService,
        contextBuilderProviderFactory: ContextBuilderAgentViewModel.ProviderFactory? = nil,
        workspaceFileContextStore injectedWorkspaceFileContextStore: WorkspaceFileContextStore? = nil,
        workspaceSwitchTimingPolicy: WorkspaceSwitchTimingPolicy = .production
    ) -> WindowStateComposition {
        // 1) Workspace file context store + visible file-tree UI adapter
        let workspaceFileContextStore = injectedWorkspaceFileContextStore ?? WorkspaceFileContextStore()
        let workspaceSearchService = WorkspaceSearchService()
        let workspaceFilesViewModel = WorkspaceFilesViewModel(workspaceFileContextStore: workspaceFileContextStore)

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

        // 7) Create the workspace manager
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: workspaceFilesViewModel,
            promptViewModel: promptManager,
            workspaceSearchService: workspaceSearchService,
            switchTimingPolicy: workspaceSwitchTimingPolicy
        )
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
            oracleViewModel: oracleViewModel,
            providerFactory: contextBuilderProviderFactory
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
}
