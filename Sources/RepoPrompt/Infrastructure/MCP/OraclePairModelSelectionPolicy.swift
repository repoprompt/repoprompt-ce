import Foundation

enum OraclePairModelSelectionPolicy {
    static let maximumOracleCount = 5
    static let maximumAdditionalOracleCount = maximumOracleCount - 1

    static func canonicalSecondaryRaw(_ raw: String?) throws -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let model = AIModel.fromModelName(trimmed) else {
            throw ChatToolError.invalidParams(
                "Secondary Oracle Model '\(trimmed)' is not a recognized Oracle model ID."
            )
        }
        return model.rawValue
    }

    static func resolveSecondary(raw: String?) throws -> AIModel? {
        guard let canonicalRaw = try canonicalSecondaryRaw(raw) else { return nil }
        return AIModel.fromModelName(canonicalRaw)
    }

    static func canonicalAdditionalRaws(_ raws: [String]) throws -> [String] {
        guard raws.count <= maximumAdditionalOracleCount else {
            throw ChatToolError.invalidParams(
                "At most \(maximumOracleCount) Oracle models can be configured."
            )
        }
        return try raws.enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let model = AIModel.fromModelName(trimmed) else {
                throw ChatToolError.invalidParams(
                    "Oracle \(index + 2) Model '\(trimmed)' is not a recognized Oracle model ID."
                )
            }
            return model.rawValue
        }
    }

    static func resolveAdditional(raws: [String]) throws -> [AIModel] {
        try canonicalAdditionalRaws(raws).compactMap(AIModel.fromModelName)
    }
}
