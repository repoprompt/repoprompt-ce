import Foundation

struct CodexModelSpecifier: Equatable {
    typealias ReasoningEffort = CodexReasoningEffort

    private static let knownBaseModelIDsEndingInEffortToken: Set<String> = [
        "gpt-5.1-codex-max"
    ]

    let baseModel: String?
    let reasoningEffort: ReasoningEffort?
    let serviceTier: String?

    init(baseModel: String?, reasoningEffort: ReasoningEffort?, serviceTier: String? = nil) {
        let normalizedBase = baseModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedBase, !normalizedBase.isEmpty, normalizedBase.lowercased() != "default" {
            self.baseModel = normalizedBase
        } else {
            self.baseModel = nil
        }
        self.reasoningEffort = self.baseModel == nil ? nil : reasoningEffort
        self.serviceTier = self.baseModel == nil ? nil : serviceTier
    }

    init(raw: String?) {
        let parts = Self.splitLegacyModelID(raw)
        self.init(baseModel: parts.baseModel, reasoningEffort: parts.reasoningEffort, serviceTier: parts.serviceTier)
    }

    static func splitLegacyModelID(_ raw: String?) -> (baseModel: String?, reasoningEffort: ReasoningEffort?, serviceTier: String?) {
        guard
            let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            raw.lowercased() != "default"
        else {
            return (nil, nil, nil)
        }

        // First strip any reasoning effort suffix
        let suffixes: [(suffix: String, effort: ReasoningEffort)] = [
            ("-max", .max),
            ("-xhigh", .xhigh),
            ("-medium", .medium),
            ("-minimal", .minimal),
            ("-high", .high),
            ("-none", .none),
            ("-low", .low)
        ]
        var base = raw
        var effort: ReasoningEffort? = nil
        let lowered = raw.lowercased()
        if !knownBaseModelIDsEndingInEffortToken.contains(lowered) {
            for (suffix, e) in suffixes where lowered.hasSuffix(suffix) {
                let candidate = String(raw.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    base = candidate
                    effort = e
                }
                break
            }
        }

        // Then check for a service tier infix (e.g. "gpt-5.4-fast" → base "gpt-5.4", tier "fast")
        let knownTiers = [CodexServiceTierVariantCatalog.fastServiceTier]
        var tier: String? = nil
        let baseLowered = base.lowercased()
        for knownTier in knownTiers {
            let tierSuffix = "-\(knownTier)"
            if baseLowered.hasSuffix(tierSuffix) {
                let strippedBase = String(base.dropLast(tierSuffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !strippedBase.isEmpty {
                    base = strippedBase
                    tier = knownTier
                    break
                }
            }
        }

        return (base, effort, tier)
    }

    var cliModelArgs: [String] {
        guard let baseModel else { return [] }
        return ["--model", baseModel]
    }

    var cliReasoningConfigArgs: [String] {
        guard let reasoningEffort else { return [] }
        return ["-c", "model_reasoning_effort=\(reasoningEffort.rawValue)"]
    }

    var cliServiceTierConfigArgs: [String] {
        guard let supportedServiceTier else { return [] }
        return ["-c", "service_tier=\(supportedServiceTier)"]
    }

    var appServerModelParam: String? {
        baseModel
    }

    var appServerEffortParam: String? {
        reasoningEffort?.rawValue
    }

    var appServerServiceTierParam: String? {
        supportedServiceTier
    }

    private var supportedServiceTier: String? {
        guard let baseModel else { return nil }
        return CodexServiceTierVariantCatalog.supportedServiceTier(
            baseModelID: baseModel,
            serviceTier: serviceTier
        )
    }
}
