import Foundation

/// Speed capabilities published by the signed-in Codex model catalog.
struct CodexModelServiceTier: Codable, Hashable {
    let id: String
    let name: String
    let description: String
}

enum CodexServiceTierVariantCatalog {
    static let ultrafastServiceTier = "ultrafast"
    static let knownServiceTiers = [fastServiceTier, ultrafastServiceTier]
    static let fastServiceTier = "fast"
    static let fastCostWarningText = "Fast service tier uses your usage limits about 2× faster."

    /// An explicitly empty structured list wins over deprecated tier IDs.
    static func advertisedTiers(from entry: [String: Any]) -> [CodexModelServiceTier] {
        if let tiers = entry["serviceTiers"] as? [[String: Any]] {
            return tiers.compactMap { tier in
                guard let id = tier["id"] as? String, !id.isEmpty else { return nil }
                return CodexModelServiceTier(
                    id: id, name: tier["name"] as? String ?? id.capitalized,
                    description: tier["description"] as? String ?? ""
                )
            }
        }
        return (entry["additionalSpeedTiers"] as? [String] ?? []).map {
            CodexModelServiceTier(id: $0, name: $0.capitalized, description: "")
        }
    }

    static func isFastEligible(baseModelID: String) -> Bool {
        guard let version = gptVersion(from: baseModelID) else { return false }
        return version.major > 5 || (version.major == 5 && version.minor >= 3)
    }

    private static func gptVersion(from baseModelID: String) -> (major: Int, minor: Int)? {
        let normalized = CodexModelIdentity.key(baseModelID)
        guard normalized.hasPrefix("gpt-") else { return nil }

        let versionStart = normalized.index(normalized.startIndex, offsetBy: 4)
        var versionEnd = versionStart
        while versionEnd < normalized.endIndex {
            let character = normalized[versionEnd]
            guard character.isNumber || character == "." else { break }
            versionEnd = normalized.index(after: versionEnd)
        }

        let versionString = String(normalized[versionStart ..< versionEnd])
        let components = versionString.split(separator: ".", omittingEmptySubsequences: false)
        guard let majorString = components.first,
              let major = Int(majorString) else { return nil }
        let minor: Int
        if components.count > 1 {
            guard let parsedMinor = Int(components[1]) else { return nil }
            minor = parsedMinor
        } else {
            minor = 0
        }
        return (major, minor)
    }

    static func isFastVariant(rawModel: String?) -> Bool {
        let specifier = CodexModelSpecifier(raw: rawModel)
        guard let baseModel = specifier.baseModel else { return false }
        return supportedServiceTier(
            baseModelID: baseModel,
            serviceTier: specifier.serviceTier
        ) == fastServiceTier
    }

    static func serviceTierAwareBaseID(for rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let specifier = CodexModelSpecifier(raw: trimmed)
        var baseID = (specifier.baseModel ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tier = supportedServiceTier(
            baseModelID: baseID,
            serviceTier: specifier.serviceTier
        ) {
            baseID += "-\(tier)"
        }
        return baseID
    }

    static func supportedServiceTier(baseModelID: String, serviceTier: String?) -> String? {
        guard let serviceTier else { return nil }
        let normalizedTier = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedTier == ultrafastServiceTier {
            return baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : normalizedTier
        }
        guard normalizedTier == fastServiceTier,
              isFastEligible(baseModelID: baseModelID) else { return nil }
        return normalizedTier
    }

    static func fastVariantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?,
        discoveredRecords: @autoclosure () -> [CodexDynamicModelRecord] = CodexDynamicModelStore.load()
    ) -> String? {
        let baseModelID = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModelID.isEmpty, isFastEligible(baseModelID: baseModelID) else { return nil }
        if let reasoningEffort {
            let variantID = "\(baseModelID)-\(fastServiceTier)-\(reasoningEffort.rawValue)"
            // Exact discovered model IDs take precedence during extended-effort parsing.
            if [CodexReasoningEffort.max, .ultra].contains(reasoningEffort),
               discoveredRecords().contains(where: { CodexModelIdentity.key($0.id) == CodexModelIdentity.key(variantID) })
            {
                return nil
            }
            return variantID
        }
        return "\(baseModelID)-\(fastServiceTier)"
    }
}
