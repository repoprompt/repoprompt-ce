import Foundation

struct CodexDynamicReasoningRecord: Codable, Hashable {
    let reasoningEffort: String
    let description: String
}

struct CodexDynamicModelRecord: Codable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let supportedReasoningEfforts: [CodexDynamicReasoningRecord]
    let defaultReasoningEffort: String?

    init(
        id: String,
        model: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexDynamicReasoningRecord] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case description
        case isDefault
        case supportedReasoningEfforts
        case defaultReasoningEffort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        supportedReasoningEfforts = try container.decodeIfPresent([CodexDynamicReasoningRecord].self, forKey: .supportedReasoningEfforts) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
    }
}

struct CodexDynamicModelOption: Hashable {
    let id: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let baseID: String
    let reasoningEffort: CodexReasoningEffort?
}

enum CodexDynamicModelMapper {
    private struct EffortEntry {
        let effort: CodexReasoningEffort
        let description: String
        let isDefault: Bool
    }

    static func options(from remoteModels: [CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelOption] {
        let records = remoteModels.map { model in
            CodexDynamicModelRecord(
                id: model.id,
                model: model.model,
                displayName: model.displayName,
                description: model.description,
                isDefault: model.isDefault,
                supportedReasoningEfforts: model.supportedReasoningEfforts.map {
                    CodexDynamicReasoningRecord(reasoningEffort: $0.reasoningEffort, description: $0.description)
                },
                defaultReasoningEffort: model.defaultReasoningEffort
            )
        }
        return options(from: records)
    }

    static func options(from records: [CodexDynamicModelRecord]) -> [CodexDynamicModelOption] {
        var options: [CodexDynamicModelOption] = []
        var seen = Set<String>()

        for record in records {
            let baseID = normalizeID(record.id)
            guard !baseID.isEmpty else { continue }

            let baseName = formatBaseDisplayName(
                record.displayName,
                fallbackModel: record.model,
                fallbackID: baseID
            )
            let baseDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let effortEntries = normalizedEfforts(for: record, fallbackDescription: baseDescription)

            if effortEntries.isEmpty {
                appendOption(
                    CodexDynamicModelOption(
                        id: baseID,
                        displayName: baseName,
                        description: baseDescription,
                        isDefault: record.isDefault,
                        baseID: baseID,
                        reasoningEffort: nil
                    ),
                    seen: &seen,
                    into: &options
                )
                continue
            }

            for effortEntry in effortEntries {
                let optionID = "\(baseID)-\(effortEntry.effort.rawValue)"
                let optionDescription = effortEntry.description.isEmpty ? baseDescription : effortEntry.description
                appendOption(
                    CodexDynamicModelOption(
                        id: optionID,
                        displayName: "\(baseName) \(effortEntry.effort.displayName)",
                        description: optionDescription,
                        isDefault: record.isDefault && effortEntry.isDefault,
                        baseID: baseID,
                        reasoningEffort: effortEntry.effort
                    ),
                    seen: &seen,
                    into: &options
                )
            }
        }

        return options.sorted { lhs, rhs in
            let leftBase = lhs.baseID.lowercased()
            let rightBase = rhs.baseID.lowercased()
            if leftBase == rightBase {
                let leftRank = effortRank(lhs.reasoningEffort)
                let rightRank = effortRank(rhs.reasoningEffort)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            if AIModel.codexBaseModelPrecedes(leftBase, rightBase) { return true }
            if AIModel.codexBaseModelPrecedes(rightBase, leftBase) { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func displayName(forModelID id: String, records: [CodexDynamicModelRecord]) -> String? {
        let normalizedID = normalizeID(id)
        let lookupID = normalizedID.lowercased()
        guard !lookupID.isEmpty else { return nil }

        for record in records {
            let baseID = normalizeID(record.id)
            guard !baseID.isEmpty else { continue }
            let baseLookupID = baseID.lowercased()
            guard lookupID == baseLookupID || lookupID.hasPrefix("\(baseLookupID)-") else { continue }

            let baseDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let effortEntries = normalizedEfforts(for: record, fallbackDescription: baseDescription)
            if effortEntries.isEmpty {
                guard lookupID == baseLookupID else { continue }
                return formatBaseDisplayName(
                    record.displayName,
                    fallbackModel: record.model,
                    fallbackID: baseID
                )
            }

            for effortEntry in effortEntries {
                let optionID = "\(baseID)-\(effortEntry.effort.rawValue)".lowercased()
                guard lookupID == optionID else { continue }
                let baseName = formatBaseDisplayName(
                    record.displayName,
                    fallbackModel: record.model,
                    fallbackID: baseID
                )
                return "\(baseName) \(effortEntry.effort.displayName)"
            }
        }

        return nil
    }

    private static func appendOption(_ option: CodexDynamicModelOption, seen: inout Set<String>, into output: inout [CodexDynamicModelOption]) {
        let key = option.id.lowercased()
        guard seen.insert(key).inserted else { return }
        output.append(option)
    }

    private static func normalizedEfforts(for record: CodexDynamicModelRecord, fallbackDescription: String) -> [EffortEntry] {
        var descriptionsByEffort: [CodexReasoningEffort: String] = [:]
        for entry in record.supportedReasoningEfforts {
            guard let effort = CodexReasoningEffort.parse(entry.reasoningEffort),
                  descriptionsByEffort[effort] == nil else { continue }
            descriptionsByEffort[effort] = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let defaultEffort = CodexReasoningEffort.parse(record.defaultReasoningEffort)
        if let defaultEffort, descriptionsByEffort[defaultEffort] == nil {
            descriptionsByEffort[defaultEffort] = fallbackDescription
        }

        guard !descriptionsByEffort.isEmpty else { return [] }

        let effectiveDefault = defaultEffort
            ?? CodexReasoningEffort.displayOrder.first(where: { descriptionsByEffort[$0] != nil })
            ?? descriptionsByEffort.keys.first

        var output: [EffortEntry] = []
        for effort in CodexReasoningEffort.displayOrder {
            guard let description = descriptionsByEffort[effort] else { continue }
            output.append(
                EffortEntry(
                    effort: effort,
                    description: description,
                    isDefault: effectiveDefault == effort
                )
            )
        }
        return output
    }

    private static func effortRank(_ effort: CodexReasoningEffort?) -> Int {
        guard let effort else { return -1 }
        return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
    }

    private static func normalizeID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatBaseDisplayName(_ preferred: String, fallbackModel: String, fallbackID: String) -> String {
        let preferredTrimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredTrimmed.isEmpty {
            return humanizeLabel(preferredTrimmed)
        }
        let fallbackModelTrimmed = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallbackModelTrimmed.isEmpty {
            return humanizeLabel(fallbackModelTrimmed)
        }
        return humanizeLabel(fallbackID)
    }

    private static func humanizeLabel(_ raw: String) -> String {
        if let alias = AIModel.codexPreviewDisplayAlias(for: raw) {
            return alias
        }

        let tokens = raw.split { character in
            character == "_" || character == "-" || character == "/" || character.isWhitespace
        }
        guard !tokens.isEmpty else { return raw }

        var formatted: [String] = []
        formatted.reserveCapacity(tokens.count)
        for token in tokens {
            let value = String(token)
            let formattedToken = formatLabelToken(value)
            if isVersionToken(value), formatted.last == "GPT" {
                formatted[formatted.count - 1] = "GPT-\(formattedToken)"
            } else {
                formatted.append(formattedToken)
            }
        }
        return formatted.joined(separator: " ")
    }

    private static func formatLabelToken(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "gpt" { return "GPT" }
        if lower == "cli" { return "CLI" }
        if lower == "codex" { return "Codex" }
        if lower == "openai" { return "OpenAI" }
        if lower == "xhigh" { return "XHigh" }
        if lower == "ultra" { return "Ultra" }
        if lower == "low" { return "Low" }
        if lower == "medium" { return "Medium" }
        if lower == "high" { return "High" }
        if lower == "minimal" { return "Minimal" }
        if lower == "none" { return "None" }
        if isONumberToken(lower) { return lower.uppercased() }
        if isVersionToken(value) { return value }
        return lower.capitalized
    }

    private static func isONumberToken(_ lower: String) -> Bool {
        guard lower.first == "o", lower.count > 1 else { return false }
        return lower.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isVersionToken(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }
}

enum CodexDynamicModelStore {
    private static let storageKey = "CodexDynamicModelRecords"

    static func canonicalRecords(from models: [CodexAppServerClient.RemoteModel]) -> [CodexDynamicModelRecord] {
        models
            .compactMap { canonicalRecord(from: $0) }
            .sorted(by: canonicalRecordSort)
    }

    static func save(_ models: [CodexAppServerClient.RemoteModel], defaults: UserDefaults = .standard) {
        let records = canonicalRecords(from: models)
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func load(defaults: UserDefaults = .standard) -> [CodexDynamicModelRecord] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([CodexDynamicModelRecord].self, from: data)) ?? []
    }

    static func modelOptions(defaults: UserDefaults = .standard) -> [CodexDynamicModelOption] {
        CodexDynamicModelMapper.options(from: load(defaults: defaults))
    }

    static func displayName(forModelID id: String, defaults: UserDefaults = .standard) -> String? {
        CodexDynamicModelMapper.displayName(forModelID: id, records: load(defaults: defaults))
    }

    private static func canonicalRecord(from model: CodexAppServerClient.RemoteModel) -> CodexDynamicModelRecord? {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let canonicalModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = model.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultReasoningEffort = CodexReasoningEffort.parse(model.defaultReasoningEffort)?.rawValue
        var reasoningDescriptionsByEffort: [CodexReasoningEffort: String] = [:]
        for entry in model.supportedReasoningEfforts {
            guard let effort = CodexReasoningEffort.parse(entry.reasoningEffort) else { continue }
            let effortDescription = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = reasoningDescriptionsByEffort[effort] {
                if effortDescription.localizedCaseInsensitiveCompare(existing) == .orderedAscending {
                    reasoningDescriptionsByEffort[effort] = effortDescription
                }
            } else {
                reasoningDescriptionsByEffort[effort] = effortDescription
            }
        }
        if let defaultReasoningEffort,
           let defaultEffort = CodexReasoningEffort(rawValue: defaultReasoningEffort),
           reasoningDescriptionsByEffort[defaultEffort] == nil
        {
            reasoningDescriptionsByEffort[defaultEffort] = description
        }
        let reasoningEfforts: [CodexDynamicReasoningRecord] = CodexReasoningEffort.displayOrder.compactMap {
            effort -> CodexDynamicReasoningRecord? in
            guard let effortDescription = reasoningDescriptionsByEffort[effort] else { return nil }
            return CodexDynamicReasoningRecord(
                reasoningEffort: effort.rawValue,
                description: effortDescription
            )
        }

        return CodexDynamicModelRecord(
            id: id,
            model: canonicalModel.isEmpty ? id : canonicalModel,
            displayName: displayName,
            description: description,
            isDefault: model.isDefault,
            supportedReasoningEfforts: reasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort
        )
    }

    private static func canonicalRecordSort(_ lhs: CodexDynamicModelRecord, _ rhs: CodexDynamicModelRecord) -> Bool {
        let lhsID = lhs.id.lowercased()
        let rhsID = rhs.id.lowercased()
        if lhsID != rhsID {
            return lhsID < rhsID
        }
        let lhsModel = lhs.model.lowercased()
        let rhsModel = rhs.model.lowercased()
        if lhsModel != rhsModel {
            return lhsModel < rhsModel
        }
        let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayNameOrder != .orderedSame {
            return displayNameOrder == .orderedAscending
        }
        let descriptionOrder = lhs.description.localizedCaseInsensitiveCompare(rhs.description)
        if descriptionOrder != .orderedSame {
            return descriptionOrder == .orderedAscending
        }
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault && !rhs.isDefault
        }
        return (lhs.defaultReasoningEffort ?? "").lowercased() < (rhs.defaultReasoningEffort ?? "").lowercased()
    }
}

enum CodexAIModelCatalog {
    static func modelsForPicker(staticModels: [AIModel]) -> [AIModel] {
        let dynamicModels = dynamicModelsFromStore()
        if !dynamicModels.isEmpty {
            let dynamicWithFastVariants = dynamicModels + synthesizedFastAIModels(from: dynamicModels)
            return backfilledRecommendedModels(primary: dynamicWithFastVariants, fallback: staticModels)
        }
        return staticModels
    }

    private static func dynamicModelsFromStore() -> [AIModel] {
        CodexDynamicModelStore.modelOptions().map { .codexCustom(name: $0.id) }
    }

    private static func backfilledRecommendedModels(primary: [AIModel], fallback: [AIModel]) -> [AIModel] {
        guard shouldBackfillRecommendedModels(primary) else { return primary }

        var merged = primary
        var seen = Set(primary.compactMap { codexOptionIdentity(for: $0) })
        for model in fallback {
            guard let identity = codexOptionIdentity(for: model) else { continue }
            if seen.insert(identity).inserted {
                merged.append(model)
            }
        }
        return merged
    }

    private static func shouldBackfillRecommendedModels(_ models: [AIModel]) -> Bool {
        let identities = Set(models.compactMap { codexOptionIdentity(for: $0) })
        let requiredIdentityGroups: [[String]] = [
            ["gpt-5.6-sol-low"],
            ["gpt-5.6-sol-medium"],
            ["gpt-5.6-sol-high"],
            ["gpt-5.3-codex", "gpt-5.3-codex-medium"]
        ]
        return requiredIdentityGroups.contains { group in
            !group.contains { identities.contains($0) }
        }
    }

    private static func codexOptionIdentity(for model: AIModel) -> String? {
        switch model {
        case let .codexCustom(name):
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : canonicalCodexOptionIdentity(normalized)
        default:
            let rawValue = model.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "codex_cli_"
            guard rawValue.lowercased().hasPrefix(prefix) else { return nil }
            let identity = String(rawValue.dropFirst(prefix.count)).lowercased()
            return identity.isEmpty ? nil : canonicalCodexOptionIdentity(identity)
        }
    }

    private static func canonicalCodexOptionIdentity(_ raw: String) -> String {
        let specifier = CodexModelSpecifier(raw: raw)
        guard let base = specifier.baseModel?.lowercased(), base == "gpt-5.6" else {
            return raw
        }
        guard let effort = specifier.reasoningEffort else { return "gpt-5.6-sol" }
        return "gpt-5.6-sol-\(effort.rawValue)"
    }

    private static func synthesizedFastAIModels(from models: [AIModel]) -> [AIModel] {
        var synthesized: [AIModel] = []
        var seen = Set(models.map { $0.modelName.lowercased() })

        for model in models {
            guard case let .codexCustom(name) = model else { continue }
            let specifier = CodexModelSpecifier(raw: name)
            guard specifier.serviceTier == nil,
                  let baseModel = specifier.baseModel,
                  let fastID = CodexServiceTierVariantCatalog.fastVariantID(
                      baseModelID: baseModel,
                      reasoningEffort: specifier.reasoningEffort
                  ) else { continue }
            guard seen.insert(fastID.lowercased()).inserted else { continue }
            synthesized.append(.codexCustom(name: fastID))
        }

        return synthesized
    }
}
