import Foundation

enum OracleModelSlot: String {
    case primary
    case secondary

    var label: String {
        switch self {
        case .primary: "Primary Oracle Model"
        case .secondary: "Secondary Oracle Model"
        }
    }
}

enum OracleModelCandidateResolution: Equatable {
    case absent
    case resolved(AIModel)
    case invalid(rawValue: String)
    case unavailable(AIModel)
}

@MainActor
struct OraclePairModelSelectionPolicy {
    private let promptVM: PromptViewModel

    init(promptVM: PromptViewModel) {
        self.promptVM = promptVM
    }

    nonisolated static func resolveCandidate(
        raw: String?,
        isAvailable: (AIModel) -> Bool
    ) -> OracleModelCandidateResolution {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .absent }
        guard let model = AIModel.fromModelName(trimmed) else {
            return .invalid(rawValue: trimmed)
        }
        guard isAvailable(model) else { return .unavailable(model) }
        return .resolved(model)
    }

    nonisolated static func isExactCatalogMatch(_ model: AIModel, in availableModels: [AIModel]) -> Bool {
        availableModels.contains {
            $0.rawValue == model.rawValue && $0.providerType == model.providerType
        }
    }

    nonisolated static func validatedCandidate(
        slot: OracleModelSlot,
        raw: String?,
        isAvailable: (AIModel) -> Bool
    ) throws -> String? {
        switch resolveCandidate(raw: raw, isAvailable: isAvailable) {
        case .absent:
            return nil
        case let .resolved(model):
            return model.rawValue
        case let .invalid(rawValue):
            throw ChatToolError.invalidParams(
                "\(slot.label) '\(rawValue)' is not a recognized Oracle model ID."
            )
        case let .unavailable(model):
            throw ChatToolError.invalidParams(
                "\(slot.label) '\(model.displayName)' is not available."
            )
        }
    }

    func validatedCandidate(slot: OracleModelSlot, raw: String?) throws -> String? {
        try Self.validatedCandidate(
            slot: slot,
            raw: raw,
            isAvailable: promptVM.isOracleModelInHydratedCatalog
        )
    }

    func resolveOptionalSecondary(raw: String?) throws -> AIModel? {
        guard let canonicalRaw = try validatedCandidate(slot: .secondary, raw: raw) else {
            return nil
        }
        return AIModel.fromModelName(canonicalRaw)
    }

    func requireAvailable(_ model: AIModel, slot: OracleModelSlot = .primary) throws -> AIModel {
        guard promptVM.isOracleModelInHydratedCatalog(model) else {
            throw ChatToolError.invalidParams(
                "\(slot.label) '\(model.displayName)' is not available."
            )
        }
        return model
    }
}
