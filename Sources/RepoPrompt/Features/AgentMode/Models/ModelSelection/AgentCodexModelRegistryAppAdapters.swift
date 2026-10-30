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
                remoteOptions: { AgentCodexModelPolicy.codexDynamicOptions(from: CodexDynamicModelMapper.options(from: $0)) },
                storedOptions: { AgentCodexModelPolicy.codexDynamicOptions(from: CodexDynamicModelMapper.options(from: $0)) },
                resolveOptions: { AgentCodexModelPolicy.resolvedOptions(dynamicOptions: $0, staticOptions: $1) },
                addingFastVariants: { AgentCodexModelPolicy.codexOptionsByAddingFastVariants($0) }
            ),
            invalidate: invalidate
        )
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_mergeCodexOptions(
            primary: [AgentModelOption],
            fallback: [AgentModelOption]
        ) -> [AgentModelOption] {
            AgentCodexModelPolicy.mergeCodexOptions(primary: primary, fallback: fallback)
        }
    #endif
}

/// The existing App picker/recommendation policy, without registry state or a second catalog.
private enum AgentCodexModelPolicy {
    static func resolvedOptions(
        dynamicOptions: [AgentModelOption],
        staticOptions: [AgentModelOption]
    ) -> [AgentModelOption] {
        let dynamicOptionsWithFastVariants = codexOptionsByAddingFastVariants(dynamicOptions)
        let staticOptionsWithFastVariants = codexOptionsByAddingFastVariants(staticOptions)
        if shouldBackfillRecommendedDefaults(dynamicOptionsWithFastVariants) {
            return mergeCodexOptions(primary: dynamicOptionsWithFastVariants, fallback: staticOptionsWithFastVariants)
        }
        return dynamicOptionsWithFastVariants
    }

    static func codexOptionsByAddingFastVariants(_ options: [AgentModelOption]) -> [AgentModelOption] {
        options + synthesizedFastAgentOptions(from: options)
    }

    private static func synthesizedFastAgentOptions(from options: [AgentModelOption]) -> [AgentModelOption] {
        var synthesized: [AgentModelOption] = []
        var seen = Set(options.map { $0.rawValue.lowercased() })

        for option in options where !option.isPlaceholderDefault {
            let specifier = CodexModelSpecifier(raw: option.rawValue)
            guard specifier.serviceTier == nil,
                  let baseModel = specifier.baseModel,
                  let fastID = CodexServiceTierVariantCatalog.fastVariantID(
                      baseModelID: baseModel,
                      reasoningEffort: specifier.reasoningEffort
                  ) else { continue }
            guard seen.insert(fastID.lowercased()).inserted else { continue }

            synthesized.append(AgentModelOption(
                rawValue: fastID,
                displayName: fastDisplayName(for: option, reasoningEffort: specifier.reasoningEffort),
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
                        reasoningEffort: nil
                    ).map { AgentModelEffortVariant(baseModelRaw: $0, reasoningEffort: effort) }
                }
            ))
        }

        return synthesized
    }

    private static func fastDisplayName(for option: AgentModelOption, reasoningEffort: CodexReasoningEffort?) -> String {
        let baseLabel = AIModel.stripCodexReasoningSuffix(from: option.displayName)
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

    static func mergeCodexOptions(
        primary: [AgentModelOption],
        fallback: [AgentModelOption]
    ) -> [AgentModelOption] {
        var merged = primary
        var seen = Set(primary.flatMap { codexEquivalenceKeys(for: $0.rawValue) })
        for option in fallback {
            let keys = codexEquivalenceKeys(for: option.rawValue)
            guard !keys.isEmpty, keys.allSatisfy({ !seen.contains($0) }) else { continue }
            seen.formUnion(keys)
            merged.append(option)
        }
        return merged
    }

    private static func shouldBackfillRecommendedDefaults(_ options: [AgentModelOption]) -> Bool {
        let keys = Set(options.flatMap { codexEquivalenceKeys(for: $0.rawValue) })
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

    private static func codexEquivalenceKeys(for rawValue: String) -> Set<String> {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        var keys: Set<String> = [normalized]
        let specifier = CodexModelSpecifier(raw: normalized)
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
