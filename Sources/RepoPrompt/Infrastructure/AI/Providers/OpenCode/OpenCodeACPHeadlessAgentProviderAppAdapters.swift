import Foundation
import RepoPromptACPProviders

extension OpenCodeACPHeadlessAgentProvider {
    convenience init(
        config: OpenCodeAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        let resolvedProviderFactory = providerFactory ?? { config in
            OpenCodeACPAgentProvider(config: config)
        }
        self.init(
            config: config,
            workspacePath: workspacePath,
            providerFactory: resolvedProviderFactory,
            controllerFactory: controllerFactory,
            selectedModel: Self.selectedModelToApply
        )
    }

    private static func selectedModelToApply(config: OpenCodeAgentConfig) -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        return model
    }
}
