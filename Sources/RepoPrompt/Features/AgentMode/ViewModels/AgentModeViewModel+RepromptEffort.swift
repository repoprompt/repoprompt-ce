import Foundation

extension AgentModeViewModel {
    /// A bounded wording pass should not wait for a separate Auto Effort model call.
    /// Keep provider/tier identity and use low effort when that variant is available.
    func chooseRepromptEffort(model: AIModel, text: String, requestID: UUID) async -> AIModel {
        let variants = AIModel.allModels().filter { $0.providerType == model.providerType }.map { candidate in
            model.openAIServiceTierOverride.map { AIModel.openAIServiceTierVariant(base: candidate, tier: $0) } ?? candidate
        }.filter {
            $0.modelName == model.modelName && $0.defaultReasoningEffort != nil
                && $0.codexServiceTier == model.codexServiceTier && $0.openAIServiceTierOverride == model.openAIServiceTierOverride
        }
        return variants.first { $0.defaultReasoningEffort == "low" } ?? model
    }
}
