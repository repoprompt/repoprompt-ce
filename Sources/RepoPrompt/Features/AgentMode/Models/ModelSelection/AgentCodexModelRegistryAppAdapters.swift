import Foundation
import RepoPromptAIContracts
import RepoPromptCodexProvider

extension AgentCodexModelRegistry {
    convenience init(invalidate: @escaping () -> Void) {
        self.init(
            dependencies: Dependencies(
                canonicalRecords: { CodexDynamicModelStore.canonicalRecords(from: $0) },
                save: { CodexDynamicModelStore.save($0) },
                load: { CodexDynamicModelStore.load() },
                storedOptions: { records in
                    AgentCodexModelPolicy.codexDynamicOptions(
                        from: CodexDynamicModelMapper.options(from: records, catalogRecords: { records })
                    )
                },
                resolveOptions: { dynamicOptions, staticOptions, records in
                    AgentCodexModelPolicy.resolvedOptions(
                        dynamicOptions: dynamicOptions,
                        staticOptions: staticOptions,
                        records: records
                    )
                }
            ),
            invalidate: invalidate
        )
    }

    convenience init() {
        self.init(invalidate: { AgentModelCatalogRuntime.shared.invalidate(.codexExec) })
    }
}

/// The existing App picker/recommendation policy, without registry state or a second catalog.
/// Every operation consumes the one records snapshot the registry resolved for the projection.
private enum AgentCodexModelPolicy {
    static func resolvedOptions(
        dynamicOptions: [AgentModelOption],
        staticOptions: [AgentModelOption],
        records: [CodexDynamicModelRecord]
    ) -> [AgentModelOption] {
        let staticOptionsWithFastVariants = codexOptionsByAddingFastVariants(staticOptions, records: records)
        guard !dynamicOptions.isEmpty else { return staticOptionsWithFastVariants }
        let dynamicOptionsWithFastVariants = codexOptionsByAddingFastVariants(dynamicOptions, records: records)
        if shouldBackfillRecommendedDefaults(dynamicOptionsWithFastVariants, records: records) {
            return mergeCodexOptions(primary: dynamicOptionsWithFastVariants, fallback: staticOptionsWithFastVariants, records: records)
        }
        return dynamicOptionsWithFastVariants
    }

    static func codexOptionsByAddingFastVariants(_ options: [AgentModelOption], records: [CodexDynamicModelRecord]) -> [AgentModelOption] {
        options + synthesizedFastAgentOptions(from: options, records: records)
    }

    private static func synthesizedFastAgentOptions(from options: [AgentModelOption], records: [CodexDynamicModelRecord]) -> [AgentModelOption] {
        var synthesized: [AgentModelOption] = []
        var seen = Set(options.map { $0.rawValue.lowercased() })

        for option in options where !option.isPlaceholderDefault {
            let specifier = CodexModelSpecifier(raw: option.rawValue, discoveredRecords: records)
            guard specifier.serviceTier == nil,
                  let baseModel = specifier.baseModel,
                  let fastID = CodexServiceTierVariantCatalog.fastVariantID(
                      baseModelID: baseModel,
                      reasoningEffort: specifier.reasoningEffort,
                      discoveredRecords: records
                  ) else { continue }
            guard seen.insert(fastID.lowercased()).inserted else { continue }

            synthesized.append(AgentModelOption(
                rawValue: fastID,
                displayName: fastDisplayName(for: option, reasoningEffort: specifier.reasoningEffort, records: records),
                description: fastDescription(for: option.description),
                isPlaceholderDefault: false,
                isProviderDefault: false,
                supportedReasoningEfforts: specifier.reasoningEffort == nil ? option.supportedReasoningEfforts : [],
                supportedReasoningEffortRawValues: specifier.reasoningEffort == nil ? option.supportedReasoningEffortRawValues : [],
                defaultReasoningEffort: specifier.reasoningEffort == nil ? option.defaultReasoningEffort : nil,
                defaultReasoningEffortRawValue: specifier.reasoningEffort == nil ? option.defaultReasoningEffortRawValue : nil,
                effortVariant: specifier.reasoningEffort.flatMap { effort in
                    CodexServiceTierVariantCatalog.fastVariantID(
                        baseModelID: baseModel,
                        reasoningEffort: nil,
                        discoveredRecords: records
                    ).map { AgentModelEffortVariant(baseModelRaw: $0, reasoningEffort: effort) }
                }
            ))
        }

        return synthesized
    }

    private static func fastDisplayName(for option: AgentModelOption, reasoningEffort: CodexReasoningEffort?, records: [CodexDynamicModelRecord]) -> String {
        let baseLabel = AIModel.stripCodexReasoningSuffix(from: option.displayName, discoveredRecords: records)
        let fastLabel = baseLabel.range(of: " fast", options: [.caseInsensitive, .backwards]) == nil
            ? "\(baseLabel) Fast"
            : baseLabel
        if let reasoningEffort {
            return "\(fastLabel) \(reasoningEffort.displayName)"
        }
        return fastLabel
    }

    private static func fastDescription(for description: String?) -> String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return CodexServiceTierVariantCatalog.fastCostWarningText }
        return "\(trimmed) \(CodexServiceTierVariantCatalog.fastCostWarningText)"
    }

    static func codexDynamicOptions(
        from dynamicOptions: [CodexDynamicModelOption]
    ) -> [AgentModelOption] {
        var options: [AgentModelOption] = [
            AgentModelOption(
                rawValue: AgentModel.defaultModel.rawValue,
                displayName: AgentModel.defaultModel.displayName,
                description: AgentModel.defaultModel.description,
                isPlaceholderDefault: true,
                isProviderDefault: false
            )
        ]

        let mapped = dynamicOptions.map { model in
            AgentModelOption(
                rawValue: model.id,
                displayName: model.displayName,
                description: model.description,
                isPlaceholderDefault: false,
                isProviderDefault: model.isDefault,
                supportedReasoningEffortRawValues: model.supportedReasoningEffortRawValues,
                defaultReasoningEffort: model.defaultReasoningEffort,
                defaultReasoningEffortRawValue: model.defaultReasoningEffortRawValue,
                effortVariant: model.reasoningEffort.map {
                    AgentModelEffortVariant(baseModelRaw: model.baseID, reasoningEffort: $0)
                }
            )
        }
        options.append(contentsOf: mapped)
        return options
    }

    private static func mergeCodexOptions(
        primary: [AgentModelOption],
        fallback: [AgentModelOption],
        records: [CodexDynamicModelRecord]
    ) -> [AgentModelOption] {
        var merged = primary
        var seen = Set(primary.flatMap { codexEquivalenceKeys(for: $0.rawValue, records: records) })
        for option in fallback {
            let keys = codexEquivalenceKeys(for: option.rawValue, records: records)
            guard !keys.isEmpty, keys.allSatisfy({ !seen.contains($0) }) else { continue }
            seen.formUnion(keys)
            merged.append(option)
        }
        return merged
    }

    private static func shouldBackfillRecommendedDefaults(_ options: [AgentModelOption], records: [CodexDynamicModelRecord]) -> Bool {
        let keys = Set(options.flatMap { codexEquivalenceKeys(for: $0.rawValue, records: records) })
        // Mirrors CodexAIModelCatalog: GPT-6.1 Sol and GPT-6 Luna back the role defaults.
        let requiredKeyGroups: [[String]] = [
            ["gpt-6.1-sol-low"],
            ["gpt-6.1-sol-medium"],
            ["gpt-6.1-sol-high"],
            ["gpt-6-luna-low"],
            ["gpt-5.3-codex"]
        ]
        return requiredKeyGroups.contains { group in
            !group.contains { keys.contains($0) }
        }
    }

    private static func codexEquivalenceKeys(for rawValue: String, records: [CodexDynamicModelRecord]) -> Set<String> {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        var keys: Set<String> = [normalized]
        let specifier = CodexModelSpecifier(raw: normalized, discoveredRecords: records)
        if let base = specifier.baseModel?.lowercased() {
            if base == "gpt-5.3-codex",
               specifier.reasoningEffort == nil || specifier.reasoningEffort == .medium
            {
                keys.insert("gpt-5.3-codex")
            }
            if base == "gpt-5.6" || base == "gpt-5.6-sol" {
                let canonicalBase = "gpt-5.6-sol"
                if let effort = specifier.reasoningEffort {
                    keys.insert("\(canonicalBase)-\(effort.rawValue)")
                    keys.insert("gpt-5.6-\(effort.rawValue)")
                } else {
                    keys.insert(canonicalBase)
                    keys.insert("gpt-5.6")
                    for effort in [CodexReasoningEffort.low, .medium, .high] {
                        keys.insert("\(canonicalBase)-\(effort.rawValue)")
                        keys.insert("gpt-5.6-\(effort.rawValue)")
                    }
                }
            }
        }
        return keys
    }
}
