import RepoPromptACPProviders
import RepoPromptDomainRuntime

extension OpenCodeACPAgentProvider {
    init(
        config: OpenCodeAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: OpenCodeACPLaunchResolver = OpenCodeACPLaunchResolver()
    ) {
        self.init(
            config: config,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            launchResolver: launchResolver,
            toolNames: ACPAppToolNameResolution.current,
            prepareManagedOverlay: { config, mcpConfiguration, workingDirectory in
                if config.cleanupLegacyPersistentConfig {
                    OpenCodeIntegrationConfiguration.cleanupLegacyACPConfigIfNeeded(
                        preserveExplicitMCPInstall: MCPIntegrationHelper.isMCPServerInstalled
                    )
                }
                if config.includeRepoPromptMCPServer {
                    try mcpConfiguration.validateACPLaunchCommand(workingDirectory: workingDirectory)
                }
                return try OpenCodeIntegrationConfiguration.ephemeralACPConfigJSON(
                    includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                    repoPromptMCPConfiguration: mcpConfiguration
                )
            }
        )
    }
}
