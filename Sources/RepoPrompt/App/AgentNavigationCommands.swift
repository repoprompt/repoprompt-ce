import SwiftUI

/// Menu-bar entries for the Agent Session Switcher. The global Carbon shortcuts
/// still handle customized bindings; these commands make the feature discoverable
/// and satisfy the HIG expectation that keyboard actions are represented in menus.
struct AgentNavigationCommands: Commands {
    @ObservedObject var windowStatesManager: WindowStatesManager

    private var focusedWindow: WindowState? {
        windowStatesManager.allWindows.first { $0.isCurrentlyFocused }
            ?? windowStatesManager.latestWindowState
    }

    var body: some Commands {
        CommandMenu("Agents") {
            Button("Go to Agent Session…") {
                showAgentNavigationHUD(mode: .currentWindow)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(focusedWindow == nil)

            Button("Search All Agent Sessions…") {
                showAgentNavigationHUD(mode: .allAgents)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(focusedWindow == nil)
        }
    }

    private func showAgentNavigationHUD(mode: AgentNavigationHUDMode) {
        guard let win = focusedWindow else { return }
        NotificationCenter.default.post(
            name: .showAgentNavigationHUD,
            object: nil,
            userInfo: [
                AgentNavigationHUDNotificationUserInfoKey.windowID: win.windowID,
                AgentNavigationHUDNotificationUserInfoKey.mode: mode.rawValue
            ]
        )
    }
}
