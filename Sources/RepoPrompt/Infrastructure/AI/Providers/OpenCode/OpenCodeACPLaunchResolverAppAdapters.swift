import Foundation
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptProcess

extension OpenCodeACPLaunchResolver {
    convenience init() {
        self.init(launchEnvironmentProvider: { enableDebugLogging in
            let result = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(
                    purpose: .acpAgent(providerID: ACPProviderID.openCode.rawValue),
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
            probeRunner: { launch, config in
                let processConfig = CLIProcessConfiguration(
                    command: launch.command,
                    environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: .openCode),
                    additionalPaths: [],
                    enableDebugLogging: config.enableDebugLogging,
                    shellLookupMode: .fallbackOnly
                )
                return try await CLIProcessRunner(config: processConfig).run(
                    args: ["acp", "--help"],
                    stdin: nil,
                    outputMode: .none,
                    timeout: 10,
                    cancelChildOnTaskCancellation: true
                )
            },
            recordFailure: { source, candidateCount in
                AgentCLILaunchDiagnostics.recordPathResolutionFailure(
                    providerKind: .openCode,
                    shellEnvironmentSource: source,
                    candidateCount: candidateCount
                )
            }
        )
    }
}
