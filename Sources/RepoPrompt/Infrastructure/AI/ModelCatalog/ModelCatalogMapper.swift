import Foundation

/// Shared record interpretation; catalog lookup is supplied by the consumer, never global here.
enum CodexDynamicModelMapper {
    private struct EffortEntry {
        let effort: CodexReasoningEffort
        let description: String
        let isDefault: Bool
    }

    static func options(from records: [CodexDynamicModelRecord], catalogRecords: () -> [CodexDynamicModelRecord]) -> [CodexDynamicModelOption] {
        var options: [CodexDynamicModelOption] = []
        var seen = Set<String>()
        let advertisedIDs = Set(records.map { CodexModelIdentity.key($0.id) }.filter { !$0.isEmpty })

        // Capability changes participate in the registry signature and are persisted.
        // A future model can gain Ultrafast on refresh without a model-version allowlist.
        let speedRecords = records.compactMap { record -> CodexDynamicModelRecord? in
            guard !normalizeID(record.id).isEmpty,
                  CodexModelSpecifier(raw: record.id, catalogRecords: catalogRecords).serviceTier == nil,
                  let tier = record.serviceTiers.first(where: {
                      $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                          == CodexServiceTierVariantCatalog.ultrafastServiceTier
                  }) else { return nil }
            let id = "\(normalizeID(record.id))-\(CodexServiceTierVariantCatalog.ultrafastServiceTier)"
            guard !advertisedIDs.contains(CodexModelIdentity.key(id)) else { return nil }
            let name = tier.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? "Ultrafast" : name
            return CodexDynamicModelRecord(
                id: id, model: record.model, displayName: "\(record.displayName) \(label)",
                description: [record.description, tier.description].filter { !$0.isEmpty }.joined(separator: " "),
                isDefault: false, supportedReasoningEfforts: record.supportedReasoningEfforts,
                defaultReasoningEffort: record.defaultReasoningEffort
            )
        }
        for record in records + speedRecords {
            let baseID = normalizeID(record.id)
            guard !baseID.isEmpty else { continue }

            let baseName = formatBaseDisplayName(
                record.displayName,
                fallbackModel: record.model,
                fallbackID: baseID,
                catalogRecords: catalogRecords
            )
            let baseDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawEfforts = record.supportedReasoningEfforts.map(\.reasoningEffort)
                + [record.defaultReasoningEffort].compactMap(\.self)
            // Extended effort parsing preserves exact model identities. Do not offer a
            // synthetic option that would resolve to another advertised model instead.
            let effortEntries = normalizedEfforts(for: record, fallbackDescription: baseDescription).filter { entry in
                ![CodexReasoningEffort.max, .ultra].contains(entry.effort)
                    || !advertisedIDs.contains(CodexModelIdentity.key("\(baseID)-\(entry.effort.rawValue)"))
            }

            if effortEntries.isEmpty {
                appendOption(
                    CodexDynamicModelOption(
                        id: baseID,
                        displayName: baseName,
                        description: baseDescription,
                        isDefault: record.isDefault,
                        baseID: baseID,
                        reasoningEffort: nil,
                        supportedReasoningEffortRawValues: rawEfforts,
                        defaultReasoningEffortRawValue: record.defaultReasoningEffort,
                        defaultReasoningEffort: CodexReasoningEffort.parse(record.defaultReasoningEffort)
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
                        reasoningEffort: effortEntry.effort,
                        supportedReasoningEffortRawValues: rawEfforts,
                        defaultReasoningEffortRawValue: record.defaultReasoningEffort,
                        defaultReasoningEffort: CodexReasoningEffort.parse(record.defaultReasoningEffort)
                    ),
                    seen: &seen,
                    into: &options
                )
            }
        }

        return options.sorted { optionPrecedes($0, $1, catalogRecords: catalogRecords) }
    }

    static func optionPrecedes(_ lhs: CodexDynamicModelOption, _ rhs: CodexDynamicModelOption, catalogRecords: () -> [CodexDynamicModelRecord]) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault && !rhs.isDefault
        }

        let leftBase = CodexModelIdentity.key(lhs.baseID)
        let rightBase = CodexModelIdentity.key(rhs.baseID)
        if leftBase == rightBase {
            let leftRank = effortRank(lhs.reasoningEffort)
            let rightRank = effortRank(rhs.reasoningEffort)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
        } else {
            if ModelCatalogSemantics.codexBaseModelPrecedes(leftBase, rightBase, catalogRecords: catalogRecords) { return true }
            if ModelCatalogSemantics.codexBaseModelPrecedes(rightBase, leftBase, catalogRecords: catalogRecords) { return false }
        }

        let displayComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }
        return normalizedOptionID(lhs.id) < normalizedOptionID(rhs.id)
    }

    static func displayName(forModelID id: String, records: [CodexDynamicModelRecord], catalogRecords: () -> [CodexDynamicModelRecord]) -> String? {
        let lookupID = CodexModelIdentity.key(id)
        guard !lookupID.isEmpty else { return nil }

        // An exact advertised ID is a real model identity, not a synthetic effort variant.
        if let exactRecord = records.first(where: { CodexModelIdentity.key($0.id) == lookupID }) {
            let exactID = normalizeID(exactRecord.id)
            guard !exactID.isEmpty else { return nil }
            return formatBaseDisplayName(
                exactRecord.displayName,
                fallbackModel: exactRecord.model,
                fallbackID: exactID,
                catalogRecords: catalogRecords
            )
        }

        for record in records {
            let baseID = normalizeID(record.id)
            guard !baseID.isEmpty else { continue }
            let baseLookupID = CodexModelIdentity.key(baseID)
            guard lookupID == baseLookupID || lookupID.hasPrefix("\(baseLookupID)-") else { continue }

            let baseDescription = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let effortEntries = normalizedEfforts(for: record, fallbackDescription: baseDescription)
            if effortEntries.isEmpty {
                guard lookupID == baseLookupID else { continue }
                return formatBaseDisplayName(
                    record.displayName,
                    fallbackModel: record.model,
                    fallbackID: baseID,
                    catalogRecords: catalogRecords
                )
            }

            for effortEntry in effortEntries {
                let optionID = CodexModelIdentity.key("\(baseID)-\(effortEntry.effort.rawValue)")
                guard lookupID == optionID else { continue }
                let baseName = formatBaseDisplayName(
                    record.displayName,
                    fallbackModel: record.model,
                    fallbackID: baseID,
                    catalogRecords: catalogRecords
                )
                return "\(baseName) \(effortEntry.effort.displayName)"
            }
        }

        return nil
    }

    private static func appendOption(_ option: CodexDynamicModelOption, seen: inout Set<String>, into output: inout [CodexDynamicModelOption]) {
        let key = CodexModelIdentity.key(option.id)
        guard seen.insert(key).inserted else { return }
        output.append(option)
    }

    private static func normalizedOptionID(_ id: String) -> String {
        CodexModelIdentity.key(id)
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

    private static func formatBaseDisplayName(_ preferred: String, fallbackModel: String, fallbackID: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String {
        let preferredTrimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredTrimmed.isEmpty {
            return humanizeLabel(preferredTrimmed, catalogRecords: catalogRecords)
        }
        let fallbackModelTrimmed = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallbackModelTrimmed.isEmpty {
            return humanizeLabel(fallbackModelTrimmed, catalogRecords: catalogRecords)
        }
        return humanizeLabel(fallbackID, catalogRecords: catalogRecords)
    }

    private static func humanizeLabel(_ raw: String, catalogRecords: () -> [CodexDynamicModelRecord]) -> String {
        if let alias = ModelCatalogSemantics.codexPreviewDisplayAlias(for: raw, catalogRecords: catalogRecords) {
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
