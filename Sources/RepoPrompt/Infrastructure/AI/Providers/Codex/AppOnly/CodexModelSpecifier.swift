import Foundation

struct CodexModelSpecifier: Equatable {
    typealias ReasoningEffort = CodexReasoningEffort

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

        // First strip any reasoning effort suffix. Legacy efforts remain broadly decoded for
        // stored selections such as `gpt-5.5-xhigh` and `gpt-5.1-codex-max-low`.
        // Extended efforts are gated to known GPT-5.6 families so the legitimate base ID
        // `gpt-5.1-codex-max` is not misread as `gpt-5.1-codex` + max effort.
        let suffixes: [(suffix: String, effort: ReasoningEffort, requiresKnownFamilySupport: Bool)] = [
            ("-xhigh", .xhigh, false),
            ("-maximum", .max, true),
            ("-ultra", .ultra, true),
            ("-max", .max, true),
            ("-medium", .medium, false),
            ("-minimal", .minimal, false),
            ("-high", .high, false),
            ("-none", .none, false),
            ("-low", .low, false)
        ]
        var base = raw
        var effort: ReasoningEffort? = nil
        let lowered = raw.lowercased()
        for (suffix, candidateEffort, requiresKnownFamilySupport) in suffixes where lowered.hasSuffix(suffix) {
            let candidate = String(raw.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { break }
            if !requiresKnownFamilySupport || Self.supportsExtendedEffort(candidateEffort, forBaseCandidate: candidate) {
                base = candidate
                effort = candidateEffort
            }
            break
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

    private static func supportsExtendedEffort(_ effort: ReasoningEffort, forBaseCandidate candidate: String) -> Bool {
        let supportBase = serviceTierStrippedBase(candidate).lowercased()
        let supported: Set<ReasoningEffort>
        switch supportBase {
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra":
            supported = [.max, .ultra]
        case "gpt-5.6-luna":
            supported = [.max]
        default:
            return false
        }
        return supported.contains(effort)
    }

    private static func serviceTierStrippedBase(_ candidate: String) -> String {
        var base = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseLowered = base.lowercased()
        for knownTier in [CodexServiceTierVariantCatalog.fastServiceTier] {
            let tierSuffix = "-\(knownTier)"
            if baseLowered.hasSuffix(tierSuffix) {
                let stripped = String(base.dropLast(tierSuffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    base = stripped
                    break
                }
            }
        }
        return base
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
