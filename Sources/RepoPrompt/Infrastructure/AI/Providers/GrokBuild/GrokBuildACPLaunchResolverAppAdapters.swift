import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptProcess

extension GrokBuildAgentConfig {
    /// App-owned path defaults; explicit path hints use the immutable provider initializer.
    init(
        commandName: String = "grok",
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApproveTools: Bool = false,
        discoveryMode: Bool = false,
        apiKey: String? = nil,
        backgroundFeatureEnvironment: [String: String] = [:]
    ) {
        self.init(
            commandName: commandName,
            additionalPathHints: CLIPathHints.grokBuild,
            enableDebugLogging: enableDebugLogging,
            modelString: modelString,
            includeRepoPromptMCPServer: includeRepoPromptMCPServer,
            alwaysApproveTools: alwaysApproveTools,
            discoveryMode: discoveryMode,
            apiKey: apiKey,
            backgroundFeatureEnvironment: backgroundFeatureEnvironment
        )
    }
}

extension GrokBuildACPLaunchResolver {
    convenience init() {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.grokBuild.rawValue),
                    enableDebugLogging: enableDebugLogging
                )
            )
            return ACPLaunchEnvironment(
                environment: result.environment,
                shellEnvironmentSource: result.shellEnvironmentSource
            )
        })
    }

    convenience init(environmentProvider: @escaping @Sendable (_ enableDebugLogging: Bool) async -> [String: String]) {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            await ACPLaunchEnvironment(environment: environmentProvider(enableDebugLogging))
        })
    }

    convenience init(launchEnvironmentProvider: @escaping EnvironmentProvider) {
        self.init(
            launchEnvironmentProvider: launchEnvironmentProvider,
            supplementalPathProvider: {
                CLILaunchProfiles.providerSpecificPathsSupplementedWithNativeDefaults($0)
            },
            environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: .grokBuild),
            failureRecorder: { source, candidateCount in
                AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                    providerKind: .grokBuild,
                    shellEnvironmentSource: source,
                    candidateCount: candidateCount
                )
            }
        )
    }
}
