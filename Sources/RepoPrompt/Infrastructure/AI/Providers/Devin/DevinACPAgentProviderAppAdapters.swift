import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime

extension DevinACPAgentProvider {
    init(
        config: DevinAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: DevinACPLaunchResolver = DevinACPLaunchResolver(),
        isolateForeignMCPImports: Bool = false
    ) {
        self.init(
            config: config,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            launchResolver: launchResolver,
            isolateForeignMCPImports: isolateForeignMCPImports,
            toolNames: ACPAppToolNameResolution.current,
            permissionArguments: { mode in
                guard DevinAgentToolPreferences.PermissionLevel.isRecognizedCLIPermissionMode(mode) else {
                    throw AIProviderError.invalidConfiguration(
                        detail: "Unsupported Devin permission mode `\(mode ?? "")`."
                    )
                }
                return DevinAgentToolPreferences.PermissionLevel.from(cliPermissionMode: mode).launchArguments
            },
            prepareIntegration: { workingDirectory, policy, sourceEnvironment, isolateForeignMCPImports in
                let mcpServers: DevinIntegrationConfiguration.MCPServersPolicy = switch policy {
                case let .mergeRepoPrompt(configuration): .mergeRepoPrompt(configuration)
                case .disableAll: .disableAll
                }
                let integration = try DevinIntegrationConfiguration.prepare(
                    workingDirectory: workingDirectory,
                    mcpServers: mcpServers,
                    sourceEnvironment: sourceEnvironment,
                    isolateForeignMCPImports: isolateForeignMCPImports
                )
                return PreparedIntegration(environment: integration.environment, cleanupArtifact: integration.cleanupArtifact)
            },
            cleanupIntegration: { artifact in
                DevinIntegrationConfiguration.cleanupReportingFailures(artifact: artifact)
            }
        )
    }
}
