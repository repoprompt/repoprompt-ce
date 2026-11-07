import RepoPromptACPProviders
import RepoPromptDomainRuntime

extension GrokBuildACPAgentProvider {
    init(
        config: GrokBuildAgentConfig,
        repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt,
        launchResolver: GrokBuildACPLaunchResolver = GrokBuildACPLaunchResolver()
    ) {
        self.init(
            config: config,
            repoPromptMCPConfiguration: repoPromptMCPConfiguration,
            launchResolver: launchResolver,
            toolNames: ACPAppToolNameResolution.current
        )
    }
}

extension GrokBuildACPEventNormalizer {
    static func normalize(_ payload: [String: Any]) -> [NormalizedAgentRuntimeEvent] {
        normalize(payload, toolNames: ACPAppToolNameResolution.current)
    }
}
