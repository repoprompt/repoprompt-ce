import Foundation

struct ClaudeControllerLaunchPolicy: Equatable {
    let permissionMode: String?
    let allowNativeBashTool: Bool?
    let mcpStrictMode: Bool?

    @MainActor
    static func resolve(
        permissionMode: String?,
        profile: AgentProviderPermissionProfile,
        defaults: UserDefaults,
        securePermissions: AgentPermissionSecureStore?
    ) -> ClaudeControllerLaunchPolicy {
        switch profile {
        case .mcpSafeDefaults:
            ClaudeControllerLaunchPolicy(
                permissionMode: permissionMode,
                allowNativeBashTool: false,
                mcpStrictMode: true
            )
        case .userConfigured, .providerOverride:
            ClaudeControllerLaunchPolicy(
                permissionMode: permissionMode,
                allowNativeBashTool: ClaudeAgentToolPreferences.bashToolEnabled(
                    defaults: defaults,
                    secureStore: securePermissions
                ),
                mcpStrictMode: ClaudeAgentToolPreferences.mcpStrictModeEnabled(
                    defaults: defaults,
                    secureStore: securePermissions
                )
            )
        }
    }
}
