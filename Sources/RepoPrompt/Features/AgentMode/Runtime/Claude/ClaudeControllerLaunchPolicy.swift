import Foundation

struct ClaudeControllerLaunchPolicy: Equatable {
    let permissionMode: String?
    let allowNativeBashTool: Bool?
    let mcpStrictMode: Bool?
    let mcpCatalogScope: MCPServerCatalogAuthority.Scope

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
                mcpStrictMode: true,
                mcpCatalogScope: .repoPromptOnly
            )
        case .userConfigured:
            ClaudeControllerLaunchPolicy(
                permissionMode: permissionMode,
                allowNativeBashTool: ClaudeAgentToolPreferences.bashToolEnabled(
                    defaults: defaults,
                    secureStore: securePermissions
                ),
                mcpStrictMode: true,
                mcpCatalogScope: .directSelected
            )
        case .providerOverride:
            ClaudeControllerLaunchPolicy(
                permissionMode: permissionMode,
                allowNativeBashTool: ClaudeAgentToolPreferences.bashToolEnabled(
                    defaults: defaults,
                    secureStore: securePermissions
                ),
                mcpStrictMode: true,
                mcpCatalogScope: .repoPromptOnly
            )
        }
    }
}
