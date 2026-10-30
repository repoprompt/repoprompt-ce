import Foundation
import RepoPromptAIContracts
import RepoPromptClaudeProvider
import RepoPromptDomainRuntime
import RepoPromptProcess

enum ClaudeCLIAppPromptPolicy {
    static func delivery(_ mode: ClaudeAgentToolPreferences.AgentModePromptDelivery) -> ClaudeCLIPromptDelivery {
        ClaudeCLIPromptDelivery(
            sendsRepoPromptAsUserMessage: { mode.sendsRepoPromptAsUserMessage },
            nativeSystemPromptOverride: { mode.nativeSystemPromptOverride(instructions: $0) }
        )
    }

    static func current() -> ClaudeCLIPromptDelivery {
        delivery(ClaudeAgentToolPreferences.agentModePromptDelivery())
    }

    static func decorate(_ prompt: String, _ instructions: String) -> String {
        ClaudeCodePromptDelivery.decoratedUserMessage(prompt, instructions: instructions)
    }
}

enum ClaudeCLIAppModelPolicy {
    static func runtimeVariant(for backendID: ClaudeCodeCompatibleBackendID) -> ClaudeCodeRuntimeVariant {
        switch backendID {
        case .glmZAI: .glm
        case .kimi: .kimi
        case .custom: .customCompatible
        }
    }

    static func compatibleDescriptor(_ model: AIModel) -> ClaudeCLICompatibleDescriptor? {
        guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
        return ClaudeCLICompatibleDescriptor(
            variant: runtimeVariant(for: descriptor.backendID),
            requestedModel: descriptor.requestedModelRaw
        )
    }

    static func compatibleBackendTestRequestedModel(for backendID: ClaudeCodeCompatibleBackendID) -> String? {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized
        switch config.modelBehavior {
        case .noModel: return nil
        case .claudeSlotMapping: return AgentModel.claudeSonnet.rawValue
        }
    }

    static func resolveModelSelection(_ model: AIModel) throws -> ClaudeCodeCLIModelSelection {
        guard model.providerType == .claudeCode else {
            throw AIProviderError.invalidModel
        }
        if case .claudeCodeModel = model,
           AIModel.fromModelName(model.rawValue) != model
        {
            throw AIProviderError.invalidModel
        }
        guard let rawSpecifier = model.claudeCodeRuntimeSpecifierRaw else {
            return ClaudeCodeCLIModelSelection(modelArgument: nil, effortLevel: nil)
        }
        let specifier = ClaudeModelSpecifier(raw: rawSpecifier)
        guard let runtimeModel = specifier.runtimeModelParam else {
            throw AIProviderError.invalidModel
        }
        return ClaudeCodeCLIModelSelection(
            modelArgument: runtimeModel,
            effortLevel: specifier.explicitEffortLevel
        )
    }
}

extension ClaudeCodeProvider {
    #if DEBUG
        static func test_parseStreamJSONCompletionPayload(_ data: Data) throws -> AICompletionResult {
            let provider = ClaudeCodeProvider()
            return try provider.parseCompletionPayload(data, isStreamJSON: true)
        }

        static func test_extractStreamJSONErrorDetail(from data: Data) -> String? {
            let provider = ClaudeCodeProvider()
            return provider.extractCLIErrorDetail(fromStdout: data, isStreamJSON: true)
        }
    #endif

    /// An injected runner owns process configuration; otherwise the normal CLI configuration is built.
    convenience init(
        workingDirectory: String? = nil,
        enableDebugLogging: Bool = false,
        defaultRequestTimeout: TimeInterval? = nil,
        testRequestTimeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        logCollector: CLIProcessLogCollector? = nil,
        runner: CLIProcessRunner? = nil,
        configService: any ClaudeCLIConfigPreparing = MCPConfigExportService.shared,
        resolveModelSelection: @escaping (AIModel) throws -> ClaudeCodeCLIModelSelection = ClaudeCLIAppModelPolicy.resolveModelSelection,
        environmentFilter: @escaping (AgentProviderKind) -> CLIProcessConfiguration.EnvironmentFilter = { ProviderEnvironmentFiltering.cliFilter(for: $0) },
        currentPromptDelivery: @escaping () -> ClaudeCLIPromptDelivery = ClaudeCLIAppPromptPolicy.current,
        decorateUserMessage: @escaping (String, String) -> String = ClaudeCLIAppPromptPolicy.decorate,
        compatibleDescriptor: @escaping (AIModel) -> ClaudeCLICompatibleDescriptor? = ClaudeCLIAppModelPolicy.compatibleDescriptor,
        makeLaunchResolver: @escaping () -> any ClaudeCodeLaunchEnvironmentResolving = { ClaudeCodeLaunchEnvironmentResolver() },
        livenessHeartbeatInterval: TimeInterval = ProviderTransportActivity.pendingCompletionHeartbeatInterval
    ) {
        var config = CLIProcessConfiguration(
            workingDirectory: workingDirectory,
            environmentFilter: environmentFilter(.claudeCode),
            captureStdoutTailBytes: 128 * 1024,
            captureStderrTailBytes: 256 * 1024
        )
        config.enableDebugLogging = enableDebugLogging
        config.logCollector = logCollector
        config.ensureAdditionalPaths(CLIPathHints.claudeCode)
        self.init(
            composedRunner: runner ?? CLIProcessRunner(config: config),
            configService: configService,
            resolveModelSelection: resolveModelSelection,
            environmentFilter: environmentFilter,
            currentPromptDelivery: currentPromptDelivery,
            decorateUserMessage: decorateUserMessage,
            compatibleDescriptor: compatibleDescriptor,
            makeLaunchResolver: makeLaunchResolver,
            defaultRequestTimeout: defaultRequestTimeout ?? 6000,
            testRequestTimeout: testRequestTimeout ?? 30,
            maxRetries: maxRetries ?? 2,
            livenessHeartbeatInterval: livenessHeartbeatInterval
        )
    }
}

/// Keeps the canonical launch lease alive without introducing cleanup state.
private struct ClaudeCLIConfigLeaseAdapter: ClaudeCLIConfigLease {
    let lease: MCPConfigLease

    var url: URL {
        lease.url
    }

    func release() {
        lease.release()
    }
}

extension MCPConfigExportService: ClaudeCLIConfigPreparing {
    package func prepareClaudeEmptyLaunchConfig() throws -> any ClaudeCLIConfigLease {
        try ClaudeCLIConfigLeaseAdapter(lease: prepareEmptyLaunchConfig())
    }
}
