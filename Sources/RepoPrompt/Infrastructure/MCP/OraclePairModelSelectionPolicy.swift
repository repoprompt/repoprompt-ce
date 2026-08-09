import Foundation

enum OraclePairModelSelectionPolicy {
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
}
