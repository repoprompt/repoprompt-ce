import Foundation

enum CodexServiceTierVariantCatalog {
    static let fastServiceTier = "fast"
    static let fastCostWarningText = "Fast service tier uses your usage limits about 2× faster."

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
