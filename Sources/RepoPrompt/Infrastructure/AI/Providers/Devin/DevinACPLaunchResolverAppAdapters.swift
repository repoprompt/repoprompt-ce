import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptProcess

extension DevinAgentConfig {
    /// App-owned path defaults; explicit path hints use the immutable provider initializer.
    init(
        commandName: String = "devin",
        enableDebugLogging: Bool = false,
        includeRepoPromptMCPServer: Bool = true,
        modelString: String? = nil
    ) {
        self.init(
            commandName: commandName,
            additionalPathHints: CLIPathHints.devin,
            enableDebugLogging: enableDebugLogging,
            includeRepoPromptMCPServer: includeRepoPromptMCPServer,
            modelString: modelString
        )
    }
}

extension DevinACPLaunchResolver {
    convenience init() {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.devin.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        })
    }

    convenience init(launchEnvironmentProvider: @escaping EnvironmentProvider) {
        self.init(
            launchEnvironmentProvider: launchEnvironmentProvider,
            supplementalPathProvider: {
                CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
            },
            environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: .devin),
            failureRecorder: { source, candidateCount in
                AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                    providerKind: .devin,
                    shellEnvironmentSource: source,
                    candidateCount: candidateCount
                )
            }
        )
    }
}
