import Foundation
import RepoPromptACPProviders

extension CursorACPHeadlessAgentProvider {
    convenience init(
        config: CursorAgentConfig,
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
            CursorACPAgentProvider(config: config)
        }
        let baseModel = config.modelString.map { raw in (try? CursorAIModelCatalog.ModelSpecifier(raw: raw).baseModelRaw) ?? raw }
        self.init(
            config: config,
            workspacePath: workspacePath,
            baseModel: baseModel,
            providerFactory: resolvedProviderFactory,
            controllerFactory: controllerFactory,
            applySelectedModel: { controller, config in
                if let model = Self.selectedModelToApply(config: config) {
                    try await controller.applyCursorModelSelection(model, overrides: config.modelOverrides)
                }
            }
        )
    }

    private static func selectedModelToApply(config: CursorAgentConfig) -> String? {
        guard let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        if model.caseInsensitiveCompare(AgentModel.cursorAuto.rawValue) == .orderedSame {
            return model
        }
        return model
    }
}
