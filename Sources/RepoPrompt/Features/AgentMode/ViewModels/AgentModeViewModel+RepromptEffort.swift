import Foundation

extension AgentModeViewModel {
    /// Uses the same masked summary, decision policy, backend and coordinator as turn Auto Effort.
    /// It never borrows/mutates an implementing session's model, effort or judgment spinner.
    func chooseRepromptEffort(model: AIModel, text: String, requestID: UUID) async -> AIModel {
        let variants = AIModel.allModels().filter { $0.providerType == model.providerType }.map { candidate in
            model.openAIServiceTierOverride.map { AIModel.openAIServiceTierVariant(base: candidate, tier: $0) } ?? candidate
        }.filter {
            $0.modelName == model.modelName && $0.defaultReasoningEffort != nil
                && $0.codexServiceTier == model.codexServiceTier && $0.openAIServiceTierOverride == model.openAIServiceTierOverride
        }
        let low = variants.first { $0.defaultReasoningEffort == "low" } ?? model
        let configuration = modelRouterSettingsStore.autoEffortConfiguration()
        guard configuration.enabled, let runtime = modelRouterRuntime,
              let backend = configuration.selectedBackendID, runtime.isBackendReady(backend),
              let excerpt = AutoEffortTaskSummary.make(from: text),
              let registration = await runtime.registry.registration(for: backend) else { return low }
        let efforts = Array(Set(variants.compactMap(\.defaultReasoningEffort))).sorted()
        guard efforts.count >= 2,
              let prepared = try? AutoEffortDecisionPolicy().build(
                  requestID: requestID, maskedTaskExcerpt: excerpt, selectedModelID: model.modelName,
                  builtInWorkflow: nil, efforts: efforts, capabilities: registration.capabilities
              ) else { return low }
        let outcome = await runtime.coordinator.decide(serviceID: backend, request: prepared.request, consumerRevision: configuration.revision)
        guard !Task.isCancelled, modelRouterSettingsStore.autoEffortConfiguration() == configuration,
              let effort = prepared.effort(for: outcome) else { return low }
        return variants.first { $0.defaultReasoningEffort == effort } ?? low
    }
}
