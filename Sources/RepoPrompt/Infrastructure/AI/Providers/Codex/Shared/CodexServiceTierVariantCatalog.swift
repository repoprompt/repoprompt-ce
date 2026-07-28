import Foundation

enum CodexServiceTierVariantCatalog {
    static let fastServiceTier = "fast"
    static let ultrafastServiceTier = "ultrafast"
    static let ultrafastDisplayName = "Ultrafast — Public Beta"
    static let fastCostWarningText = "Fast service tier uses your usage limits about 2× faster."
    static let knownServiceTiers = [fastServiceTier, ultrafastServiceTier]

    static func displayName(for serviceTier: String) -> String {
        switch serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case fastServiceTier:
            "Fast"
        case ultrafastServiceTier:
            ultrafastDisplayName
        default:
            serviceTier.capitalized
        }
    }

    static func isFastEligible(baseModelID: String) -> Bool {
        guard let version = gptVersion(from: baseModelID) else { return false }
        return version.major > 5 || (version.major == 5 && version.minor >= 3)
    }

    private static func gptVersion(from baseModelID: String) -> (major: Int, minor: Int)? {
        let normalized = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        switch normalizedTier {
        case fastServiceTier:
            return isFastEligible(baseModelID: baseModelID) ? normalizedTier : nil
        case ultrafastServiceTier:
            return baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : normalizedTier
        default:
            return nil
        }
    }

    static func variantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?,
        serviceTier: String
    ) -> String? {
        let baseModelID = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModelID.isEmpty,
              let serviceTier = supportedServiceTier(
                  baseModelID: baseModelID,
                  serviceTier: serviceTier
              )
        else {
            return nil
        }
        if let reasoningEffort {
            return "\(baseModelID)-\(serviceTier)-\(reasoningEffort.rawValue)"
        }
        return "\(baseModelID)-\(serviceTier)"
    }

    static func fastVariantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?
    ) -> String? {
        variantID(
            baseModelID: baseModelID,
            reasoningEffort: reasoningEffort,
            serviceTier: fastServiceTier
        )
    }
}
