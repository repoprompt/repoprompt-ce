import Foundation
import RepoPromptACPProviders
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptProcess

/// Original App initializers retain synchronous policy composition; request-time
/// capabilities below consult the same key/config/catalog owners at the old sites.
extension GrokBuildCLIProvider {
    convenience init() {
        self.init(host: GrokBuildCLIAppHost())
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> GrokBuildAgentConfig {
            test_makeHeadlessConfig(modelName: modelName, host: GrokBuildCLIAppHost())
        }
    #endif
}

struct GrokBuildCLIAppHost: GrokBuildCLIHost {
    func makeHeadlessConfig(modelName: String?) -> GrokBuildAgentConfig {
        GrokBuildAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false,
            alwaysApproveTools: false
        )
    }

    func modelName(for model: AIModel) -> String? {
        guard model.providerType == .grokBuild else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func makeOneShotProvider(config: GrokBuildAgentConfig) -> GrokBuildOneShotHeadlessAgentProvider {
        GrokBuildOneShotHeadlessAgentProvider(config: config)
    }
}

extension GrokBuildACPHeadlessAgentProvider {
    convenience init(
        config: GrokBuildAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: diagnosticSink)
        }
    ) {
        let resolvedProviderFactory = providerFactory ?? { config in
            // Resolve the stored Grok key here (async) — `AgentRuntimeProviderService.makeProvider`
            // is synchronous and cannot read the keychain, so headless configs arrive without it.
            try await GrokBuildACPAgentProvider(
                config: GrokBuildAgentConfig(
                    commandName: config.commandName,
                    additionalPathHints: config.additionalPathHints,
                    enableDebugLogging: config.enableDebugLogging,
                    modelString: config.modelString,
                    includeRepoPromptMCPServer: config.includeRepoPromptMCPServer,
                    alwaysApproveTools: config.alwaysApproveTools,
                    discoveryMode: config.discoveryMode,
                    apiKey: KeyManager().getAPIKey(for: .grok),
                    backgroundFeatureEnvironment: config.backgroundFeatureEnvironment
                )
            )
        }
        self.init(
            host: GrokBuildACPHeadlessAppHost(),
            config: config,
            workspacePath: workspacePath,
            providerFactory: resolvedProviderFactory,
            controllerFactory: controllerFactory
        )
    }
}

struct GrokBuildACPHeadlessAppHost: GrokBuildACPHeadlessHost {
    func selectedModel(config: GrokBuildAgentConfig) throws -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        // No silent substitution: a concrete model must exist in the current Grok registry
        // snapshot; anything else fails before the prompt instead of running a stale model.
        guard AgentModelCatalogRuntime.shared.acpRegistry.resolvedSnapshot(for: .grokBuild)?.contains(rawModel: model) == true else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(model)` is not in the discovered model set. Refresh Grok Build models and retry."
            )
        }
        return model
    }
}

extension GrokBuildOneShotHeadlessAgentProvider {
    convenience init(
        config: GrokBuildAgentConfig,
        launchResolver: GrokBuildACPLaunchResolver = GrokBuildACPLaunchResolver(),
        requestTimeout: TimeInterval = 6000,
        apiKeyProvider: @escaping APIKeyProvider = {
            try await KeyManager().getAPIKey(for: .grok)
        },
        removedNamesProvider: ProviderEnvironmentFiltering.RemovedNamesProvider? = nil
    ) {
        self.init(
            host: GrokBuildOneShotAppHost(),
            config: config,
            launchResolver: launchResolver,
            requestTimeout: requestTimeout,
            apiKeyProvider: apiKeyProvider,
            removedNamesProvider: removedNamesProvider
        )
    }
}

struct GrokBuildOneShotAppHost: GrokBuildOneShotHost {
    func resolveModelSelection(modelString: String?) async throws -> (model: String?, effort: String?) {
        try await Self.resolveModelSelection(
            modelString: modelString,
            snapshot: AgentModelCatalogRuntime.shared.acpRegistry.resolvedSnapshotAfterWarmingStandardStore(for: .grokBuild)
        )
    }

    private static func resolveModelSelection(
        modelString: String?,
        snapshot: ACPDiscoveredSessionModels?
    ) throws -> (model: String?, effort: String?) {
        guard let modelString = modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelString.isEmpty,
              modelString.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return (nil, nil)
        }
        guard let snapshot, snapshot.contains(rawModel: modelString) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(modelString)` is not in the discovered model set. Refresh Grok Build models and retry."
            )
        }
        guard let decomposed = GrokBuildModelSpecifier.decompose(
            raw: modelString,
            options: snapshot.options
        ) else {
            throw AIProviderError.invalidConfiguration(
                detail: "Grok Build model `\(modelString)` could not be resolved from the discovered model set. Refresh Grok Build models and retry."
            )
        }
        return (decomposed.base.rawValue, decomposed.explicitEffort?.rawValue)
    }

    func filterEnvironment(
        _ environment: [String: String],
        explicitOverrides: [String: String],
        removedNamesProvider: ProviderRemovedEnvironmentNames?
    ) async -> [String: String] {
        await ProviderEnvironmentFiltering.filter(
            environment,
            for: .grokBuild,
            explicitOverrides: explicitOverrides,
            removedNamesProvider: removedNamesProvider
        )
    }
}

extension DevinCLIProvider {
    convenience init(
        config: DevinAgentConfig = DevinAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false
        ),
        launchResolver: DevinACPLaunchResolver = DevinACPLaunchResolver(),
        requestTimeout: TimeInterval = 6000,
        headlessProviderFactory: @escaping HeadlessProviderFactory = { config, workspacePath in
            DevinACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        }
    ) {
        self.init(
            host: DevinCLIAppHost(),
            config: config,
            launchResolver: launchResolver,
            requestTimeout: requestTimeout,
            headlessProviderFactory: headlessProviderFactory
        )
    }

    #if DEBUG
        static func test_arguments(modelName: String?, promptFilePath: String) -> [String] {
            test_arguments(modelName: modelName, promptFilePath: promptFilePath, isDefaultModel: DevinCLIAppHost().isDefaultModel)
        }
    #endif
}

struct DevinCLIAppHost: DevinCLIHost {
    func modelName(for model: AIModel) -> String? {
        guard model.providerType == .devin else { return nil }
        let value = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }
        return value
    }

    func isDefaultModel(_ modelName: String) -> Bool {
        modelName.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
    }

    func prepareIsolatedIntegration(
        workingDirectory: String,
        sourceEnvironment: [String: String]
    ) throws -> (environment: [String: String], cleanupArtifact: ACPLaunchCleanupArtifact) {
        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: workingDirectory,
            mcpServers: .disableAll,
            sourceEnvironment: sourceEnvironment
        )
        return (prepared.environment, prepared.cleanupArtifact)
    }

    func cleanupIntegration(artifact: ACPLaunchCleanupArtifact) {
        DevinIntegrationConfiguration.cleanupReportingFailures(artifact: artifact)
    }

    func environmentFilter(explicitOverrides: [String: String]) -> CLIProcessConfiguration.EnvironmentFilter {
        ProviderEnvironmentFiltering.cliFilter(for: .devin, explicitOverrides: explicitOverrides)
    }
}

extension DevinACPHeadlessAgentProvider {
    convenience init(
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(provider: provider, runRequest: request, diagnosticSink: diagnosticSink)
        }
    ) {
        let resolvedProviderFactory = providerFactory ?? { config in
            DevinACPAgentProvider(config: config, isolateForeignMCPImports: true)
        }
        self.init(
            isDefaultModel: { model in DevinCLIAppHost().isDefaultModel(model) },
            config: config,
            workspacePath: workspacePath,
            providerFactory: resolvedProviderFactory,
            controllerFactory: controllerFactory
        )
    }
}
