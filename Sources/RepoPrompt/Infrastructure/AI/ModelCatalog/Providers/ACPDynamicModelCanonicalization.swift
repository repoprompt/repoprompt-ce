import Foundation
import RepoPromptAIContracts

struct ACPDynamicModelRecord: Codable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?
    let isPlaceholderDefault: Bool
    let isProviderDefault: Bool
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?
    /// Variant provenance for synthesized effort options. Optional so records persisted
    /// before effort support decode unchanged.
    var effortVariant: AgentModelEffortVariant? = nil
    var contextWindowTokens: Int? = nil
}

struct ACPDynamicProviderRecord: Codable, Hashable {
    let providerID: String
    let currentModelRaw: String?
    /// Active reasoning effort for providers with direct effort authority (e.g. Grok).
    /// Optional so records persisted before effort support decode unchanged.
    var currentEffortRaw: String? = nil
    let options: [ACPDynamicModelRecord]
    /// Optional for backward-compatible decode of model-only registry records.
    var modelParameterSets: [ACPModelParameterSet]? = nil

    init(
        providerID: String,
        currentModelRaw: String?,
        currentEffortRaw: String? = nil,
        options: [ACPDynamicModelRecord],
        modelParameterSets: [ACPModelParameterSet]? = []
    ) {
        self.providerID = providerID
        self.currentModelRaw = currentModelRaw
        self.currentEffortRaw = currentEffortRaw
        self.options = options
        self.modelParameterSets = modelParameterSets
    }
}

enum ACPDynamicModelCanonicalization {
    static func canonicalProviderRecord(
        from snapshot: ACPDiscoveredSessionModels,
        providerID: ACPProviderID
    ) -> ACPDynamicProviderRecord? {
        let options = canonicalModelRecords(from: snapshot.options)
        guard !options.isEmpty else { return nil }
        return ACPDynamicProviderRecord(
            providerID: providerID.rawValue,
            currentModelRaw: normalizedCurrentModelRaw(snapshot.currentModelRaw, options: options),
            currentEffortRaw: snapshot.currentEffortRaw,
            options: options,
            modelParameterSets: snapshot.hasModelParameterMetadata
                ? canonicalParameterSets(snapshot.modelParameterSets, options: options) : nil
        )
    }

    static func snapshot(from record: ACPDynamicProviderRecord) -> ACPDiscoveredSessionModels? {
        let options = record.options.compactMap(modelOption(from:))
        guard !options.isEmpty else { return nil }
        let currentModelRaw = normalizedCurrentModelRaw(record.currentModelRaw, options: record.options)
        return ACPDiscoveredSessionModels(
            options: options,
            currentModelRaw: currentModelRaw,
            currentEffortRaw: record.currentEffortRaw,
            modelParameterSets: canonicalParameterSets(record.modelParameterSets ?? [], options: record.options),
            hasModelParameterMetadata: record.modelParameterSets != nil
        )
    }

    private static func canonicalParameterSets(
        _ sets: [ACPModelParameterSet],
        options: [ACPDynamicModelRecord]
    ) -> [ACPModelParameterSet] {
        var result: [ACPModelParameterSet] = []
        for set in sets {
            let modelMatches = options.filter {
                $0.rawValue.caseInsensitiveCompare(set.baseModelRaw) == .orderedSame
            }
            guard modelMatches.count == 1, let canonicalModel = modelMatches.first?.rawValue else { continue }
            var seenIDs = Set<String>()
            let parameters = set.parameters.compactMap { definition -> ACPModelParameterDefinition? in
                guard !definition.configID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seenIDs.insert(definition.configID).inserted
                else { return nil }
                var seenValues = Set<String>()
                let choices = definition.choices.filter {
                    !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && seenValues.insert($0.rawValue).inserted
                }
                guard !choices.isEmpty else { return nil }
                let canonical = ACPModelParameterDefinition(
                    kind: definition.kind,
                    configID: definition.configID,
                    displayName: definition.displayName,
                    choices: choices,
                    currentValueRaw: definition.currentValueRaw
                )
                guard let current = canonical.choice(matching: definition.currentValueRaw) else { return nil }
                return ACPModelParameterDefinition(
                    kind: canonical.kind,
                    configID: canonical.configID,
                    displayName: canonical.displayName,
                    choices: canonical.choices,
                    currentValueRaw: current.rawValue
                )
            }.sorted {
                if $0.kind.sortOrder != $1.kind.sortOrder {
                    return $0.kind.sortOrder < $1.kind.sortOrder
                }
                return $0.configID < $1.configID
            }
            guard !parameters.isEmpty else { continue }
            result.append(.init(baseModelRaw: canonicalModel, parameters: parameters))
        }
        return result.sorted { $0.baseModelRaw.lowercased() < $1.baseModelRaw.lowercased() }
    }

    private static func canonicalModelRecords(from options: [AgentModelOption]) -> [ACPDynamicModelRecord] {
        var recordsByRaw: [String: ACPDynamicModelRecord] = [:]
        for option in options {
            guard let record = modelRecord(from: option) else { continue }
            let key = record.rawValue.lowercased()
            if let existing = recordsByRaw[key] {
                recordsByRaw[key] = mergedCanonicalModelRecord(existing, record)
            } else {
                recordsByRaw[key] = record
            }
        }
        return recordsByRaw.values.sorted(by: canonicalModelRecordSort)
    }

    private static func modelRecord(from option: AgentModelOption) -> ACPDynamicModelRecord? {
        let rawValue = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        let displayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = normalizedOptionalString(option.description)
        let supportedReasoningEfforts = normalizedRawEffortValues(
            option.supportedReasoningEffortRawValues
                + normalizedReasoningEffortRaws(option.supportedReasoningEfforts)
        )
        return ACPDynamicModelRecord(
            rawValue: rawValue,
            displayName: displayName.isEmpty ? rawValue : displayName,
            description: description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: option.defaultReasoningEffortRawValue ?? option.defaultReasoningEffort?.rawValue,
            effortVariant: option.effortVariant,
            contextWindowTokens: option.contextWindowTokens
        )
    }

    private static func modelOption(from record: ACPDynamicModelRecord) -> AgentModelOption? {
        let rawValue = record.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        let displayName = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = normalizedOptionalString(record.description)
        let supportedReasoningEfforts = normalizedReasoningEfforts(record.supportedReasoningEfforts)
        return AgentModelOption(
            rawValue: rawValue,
            displayName: displayName.isEmpty ? rawValue : displayName,
            description: description,
            isPlaceholderDefault: record.isPlaceholderDefault,
            isProviderDefault: record.isProviderDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            supportedReasoningEffortRawValues: normalizedRawEffortValues(
                record.supportedReasoningEfforts + [record.defaultReasoningEffort].compactMap(\.self)
            ),
            defaultReasoningEffort: CodexReasoningEffort.parse(record.defaultReasoningEffort),
            defaultReasoningEffortRawValue: record.defaultReasoningEffort,
            effortVariant: record.effortVariant,
            contextWindowTokens: record.contextWindowTokens
        )
    }

    private static func canonicalModelRecordSort(
        _ lhs: ACPDynamicModelRecord,
        _ rhs: ACPDynamicModelRecord
    ) -> Bool {
        let lhsRaw = lhs.rawValue.lowercased()
        let rhsRaw = rhs.rawValue.lowercased()
        if lhsRaw != rhsRaw {
            return lhsRaw < rhsRaw
        }
        let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayNameOrder != .orderedSame {
            return displayNameOrder == .orderedAscending
        }
        let descriptionOrder = (lhs.description ?? "").localizedCaseInsensitiveCompare(rhs.description ?? "")
        if descriptionOrder != .orderedSame {
            return descriptionOrder == .orderedAscending
        }
        if lhs.isPlaceholderDefault != rhs.isPlaceholderDefault {
            return lhs.isPlaceholderDefault && !rhs.isPlaceholderDefault
        }
        if lhs.isProviderDefault != rhs.isProviderDefault {
            return lhs.isProviderDefault && !rhs.isProviderDefault
        }
        let defaultReasoningOrder = (lhs.defaultReasoningEffort ?? "").lowercased()
            .localizedCompare((rhs.defaultReasoningEffort ?? "").lowercased())
        if defaultReasoningOrder != .orderedSame {
            return defaultReasoningOrder == .orderedAscending
        }
        return preferredRawValue(lhs.rawValue, rhs.rawValue) == lhs.rawValue
    }

    private static func mergedCanonicalModelRecord(
        _ existing: ACPDynamicModelRecord,
        _ candidate: ACPDynamicModelRecord
    ) -> ACPDynamicModelRecord {
        let metadataRecord = preferredMetadataRecord(existing, candidate)
        let fallbackRecord = metadataRecord == existing ? candidate : existing
        let supportedReasoningEfforts = normalizedRawEffortValues(
            existing.supportedReasoningEfforts + candidate.supportedReasoningEfforts
        )
        return ACPDynamicModelRecord(
            rawValue: preferredRawValue(existing.rawValue, candidate.rawValue),
            displayName: metadataRecord.displayName,
            description: metadataRecord.description ?? fallbackRecord.description,
            isPlaceholderDefault: existing.isPlaceholderDefault || candidate.isPlaceholderDefault,
            isProviderDefault: existing.isProviderDefault || candidate.isProviderDefault,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: metadataRecord.defaultReasoningEffort ?? fallbackRecord.defaultReasoningEffort,
            // Variant provenance is semantic identity, not metadata: keep it only when both
            // records agree, so a real base (nil) never inherits stale variant provenance.
            effortVariant: existing.effortVariant == candidate.effortVariant ? existing.effortVariant : nil,
            contextWindowTokens: metadataRecord.contextWindowTokens ?? fallbackRecord.contextWindowTokens
        )
    }

    private static func preferredMetadataRecord(
        _ lhs: ACPDynamicModelRecord,
        _ rhs: ACPDynamicModelRecord
    ) -> ACPDynamicModelRecord {
        if lhs.isProviderDefault != rhs.isProviderDefault {
            return lhs.isProviderDefault ? lhs : rhs
        }
        if lhs.isPlaceholderDefault != rhs.isPlaceholderDefault {
            return lhs.isPlaceholderDefault ? lhs : rhs
        }
        let lhsDescription = lhs.description ?? ""
        let rhsDescription = rhs.description ?? ""
        let displayNameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayNameOrder != .orderedSame {
            return displayNameOrder == .orderedAscending ? lhs : rhs
        }
        let descriptionOrder = lhsDescription.localizedCaseInsensitiveCompare(rhsDescription)
        if descriptionOrder != .orderedSame {
            return descriptionOrder == .orderedAscending ? lhs : rhs
        }
        if lhs.defaultReasoningEffort != rhs.defaultReasoningEffort {
            return lhs.defaultReasoningEffort != nil ? lhs : rhs
        }
        return preferredRawValue(lhs.rawValue, rhs.rawValue) == lhs.rawValue ? lhs : rhs
    }

    private static func preferredRawValue(_ lhs: String, _ rhs: String) -> String {
        let lhsTrimmed = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTrimmed = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let lhsIsLowercased = lhsTrimmed == lhsTrimmed.lowercased()
        let rhsIsLowercased = rhsTrimmed == rhsTrimmed.lowercased()
        if lhsIsLowercased != rhsIsLowercased {
            return lhsIsLowercased ? lhsTrimmed : rhsTrimmed
        }
        let caseInsensitiveOrder = lhsTrimmed.localizedCaseInsensitiveCompare(rhsTrimmed)
        if caseInsensitiveOrder != .orderedSame {
            return caseInsensitiveOrder == .orderedAscending ? lhsTrimmed : rhsTrimmed
        }
        return lhsTrimmed <= rhsTrimmed ? lhsTrimmed : rhsTrimmed
    }

    private static func normalizedCurrentModelRaw(
        _ raw: String?,
        options: [ACPDynamicModelRecord]
    ) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        if let matched = options.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched.rawValue
        }
        return trimmed
    }

    private static func normalizedRawEffortValues(_ efforts: [String]) -> [String] {
        var seen: Set<String> = []
        return efforts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }

    private static func normalizedReasoningEffortRaws(_ efforts: [CodexReasoningEffort]) -> [String] {
        let unique = Set(efforts)
        return CodexReasoningEffort.displayOrder
            .filter { unique.contains($0) }
            .map(\.rawValue)
    }

    private static func normalizedReasoningEfforts(_ efforts: [String]) -> [CodexReasoningEffort] {
        var seen = Set<CodexReasoningEffort>()
        let parsed = efforts.compactMap(CodexReasoningEffort.parse)
            .filter { seen.insert($0).inserted }
        return CodexReasoningEffort.displayOrder.filter { parsed.contains($0) }
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
