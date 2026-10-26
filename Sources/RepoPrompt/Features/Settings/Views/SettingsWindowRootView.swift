import SwiftUI

struct SettingsWindowRootView: View {
    @ObservedObject var model: SettingsWindowModel
    let windowState: WindowState
    @ObservedObject private var fontScale = FontScaleManager.shared

    var body: some View {
        SettingsView(
            fileManager: windowState.workspaceFilesViewModel,
            promptViewModel: windowState.promptManager,
            apiSettingsViewModel: windowState.apiSettingsViewModel,
            windowState: windowState,
            onAPIKeyUpdated: {
                Task {
                    await windowState.promptManager.refreshAvailableModels()
                }
            },
            selectedTab: $model.selectedTab,
            closeAction: nil
        )
        .safeAreaInset(edge: .top) { GlobalSettingsPersistenceBlockBanner(allowsSessionDismissal: false) }
        .environmentObject(windowState)
        .environmentObject(windowState.workspaceManager)
        .environmentObject(WindowStatesManager.shared)
        .environmentObject(SparkleUpdaterManager.shared)
        .environmentObject(FontScaleManager.shared)
        .environment(\.font, fontScale.preset.font)
        .environment(\.repoPromptFontScalePreset, fontScale.preset)
    }
}
