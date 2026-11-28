import RepoPromptSettingsCore
import RepoPromptWorkspaceContext

extension AgentHostWorkspaceResources {
    static func makeFiles(settingsStore: GlobalSettingsStore) -> WorkspaceFileContextStore {
        #if DEBUG
            WorkspaceFileContextStore(
                startupFeatureFlags: .current(), enableCatalogShardShadowValidation: false,
                nonGitCodeMapsEnabled: settingsStore.nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: settingsStore.globalCodeMapsDisabled(),
                restorePerfRecorder: AppWorkspaceRestorePerfRecorder(), perfRecorder: AppAgentModePerfRecorder()
            )
        #else
            WorkspaceFileContextStore(
                startupFeatureFlags: .current(), nonGitCodeMapsEnabled: settingsStore.nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: settingsStore.globalCodeMapsDisabled(),
                restorePerfRecorder: AppWorkspaceRestorePerfRecorder(), perfRecorder: AppAgentModePerfRecorder()
            )
        #endif
    }
}
