import Foundation
import RepoPromptAIContracts

enum CodexDynamicModelStore {
    private static let storageKey = "CodexDynamicModelRecords"
    private static let cacheLock = NSLock()
    private static var cachedData: Data?
    private static var cachedRecords: [CodexDynamicModelRecord] = []

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
        cacheLock.lock()
        defer { cacheLock.unlock() }
        // Parsing and picker ordering share this store. Decode only when the persisted
        // payload changes, including writes from other windows or defaults suites.
        let data = defaults.data(forKey: storageKey)
        if data != cachedData {
            cachedData = data
            cachedRecords = data.flatMap { try? JSONDecoder().decode([CodexDynamicModelRecord].self, from: $0) } ?? []
        }
        return cachedRecords
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
        let defaultReasoningEffort = model.defaultReasoningEffort.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        var reasoningDescriptionsByEffort: [String: String] = [:]
        for entry in model.supportedReasoningEfforts {
            let effort = entry.reasoningEffort
            guard !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let effortDescription = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = reasoningDescriptionsByEffort[effort] {
                if effortDescription.localizedCaseInsensitiveCompare(existing) == .orderedAscending {
                    reasoningDescriptionsByEffort[effort] = effortDescription
                }
            } else {
                reasoningDescriptionsByEffort[effort] = effortDescription
            }
        }
        if let defaultReasoningEffort, reasoningDescriptionsByEffort[defaultReasoningEffort] == nil {
            reasoningDescriptionsByEffort[defaultReasoningEffort] = description
        }
        let knownOrder = Dictionary(uniqueKeysWithValues: CodexReasoningEffort.displayOrder.enumerated().map {
            ($0.element.rawValue, $0.offset)
        })
        let reasoningEfforts = reasoningDescriptionsByEffort.keys.sorted { left, right in
            let leftOrder = knownOrder[left] ?? Int.max
            let rightOrder = knownOrder[right] ?? Int.max
            return leftOrder == rightOrder ? left < right : leftOrder < rightOrder
        }.map { effort in
            CodexDynamicReasoningRecord(
                reasoningEffort: effort,
                description: reasoningDescriptionsByEffort[effort]!
            )
        }

        return CodexDynamicModelRecord(
            id: id,
            model: canonicalModel.isEmpty ? id : canonicalModel,
            displayName: displayName,
            description: description,
            isDefault: model.isDefault,
            supportedReasoningEfforts: reasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort,
            serviceTiers: model.serviceTiers.sorted {
                if $0.id != $1.id { return $0.id < $1.id }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.description < $1.description
            }
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
        // GPT-6.1 Sol is the recommended default (Codex CLI 0.159.0+). Older live catalogs are
        // backfilled with the static recommended entries so role defaults stay selectable.
        let requiredIdentityGroups: [[String]] = [
            ["gpt-6.1-sol-low"],
            ["gpt-6.1-sol-medium"],
            ["gpt-6.1-sol-high"],
            ["gpt-6-luna-low"],
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
