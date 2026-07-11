import Foundation

final class AgentCodexModelRegistry {
    static let shared = AgentCodexModelRegistry()

    private let lock = NSLock()
    private var liveModels: [CodexAppServerClient.RemoteModel] = []
    private var liveModelSignature: [CodexDynamicModelRecord] = []

    private init() {}

    @discardableResult
    func updateLiveModels(_ models: [CodexAppServerClient.RemoteModel]) -> Bool {
        let signature = CodexDynamicModelStore.canonicalRecords(from: models)
        let normalized = remoteModels(from: signature)

        lock.lock()
        let didChange = signature != liveModelSignature
        if didChange {
            liveModels = normalized
            liveModelSignature = signature
        }
        lock.unlock()

        guard didChange else { return false }
        CodexDynamicModelStore.save(normalized)
        return true
    }

    func currentLiveModels() -> [CodexAppServerClient.RemoteModel] {
        lock.lock()
        defer { lock.unlock() }
        return liveModels
    }

    func resolvedOptions(
        staticOptions: [AgentModelOption],
        preferredLiveModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> [AgentModelOption] {
        if let preferredLiveModels {
            if !preferredLiveModels.isEmpty {
                return resolvedOptions(
                    dynamicOptions: codexDynamicOptions(from: preferredLiveModels),
                    staticOptions: staticOptions
                )
            }
            let cachedOptions = CodexDynamicModelStore.modelOptions()
            if !cachedOptions.isEmpty {
                return resolvedOptions(
                    dynamicOptions: codexDynamicOptions(from: cachedOptions),
                    staticOptions: staticOptions
                )
            }
            return codexOptionsByAddingFastVariants(staticOptions)
        }

        let knownLiveModels = currentLiveModels()
        if !knownLiveModels.isEmpty {
            return resolvedOptions(
                dynamicOptions: codexDynamicOptions(from: knownLiveModels),
                staticOptions: staticOptions
            )
        }

        let cachedOptions = CodexDynamicModelStore.modelOptions()
        if !cachedOptions.isEmpty {
            return resolvedOptions(
                dynamicOptions: codexDynamicOptions(from: cachedOptions),
                staticOptions: staticOptions
            )
        }

        return codexOptionsByAddingFastVariants(staticOptions)
    }

    private func resolvedOptions(
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

    private func codexOptionsByAddingFastVariants(_ options: [AgentModelOption]) -> [AgentModelOption] {
        options + synthesizedFastAgentOptions(from: options)
    }

    private func synthesizedFastAgentOptions(from options: [AgentModelOption]) -> [AgentModelOption] {
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
                defaultReasoningEffort: specifier.reasoningEffort == nil ? option.defaultReasoningEffort : nil
            ))
        }

        return synthesized
    }

    private func fastDisplayName(for option: AgentModelOption, reasoningEffort: CodexReasoningEffort?) -> String {
        let baseLabel = AIModel.stripCodexReasoningSuffix(from: option.displayName)
        let fastLabel = baseLabel.range(of: " fast", options: [.caseInsensitive, .backwards]) == nil
            ? "\(baseLabel) Fast"
            : baseLabel
        if let reasoningEffort {
            return "\(fastLabel) \(reasoningEffort.displayName)"
        }
        return fastLabel
    }

    private func fastDescription(for description: String?) -> String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return CodexServiceTierVariantCatalog.fastCostWarningText }
        return "\(trimmed) \(CodexServiceTierVariantCatalog.fastCostWarningText)"
    }

    private func codexDynamicOptions(
        from models: [CodexAppServerClient.RemoteModel]
    ) -> [AgentModelOption] {
        codexDynamicOptions(from: CodexDynamicModelMapper.options(from: models))
    }

    private func codexDynamicOptions(
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
                isProviderDefault: model.isDefault
            )
        }
        options.append(contentsOf: mapped)
        return options
    }

    private func mergeCodexOptions(
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

    private func shouldBackfillRecommendedDefaults(_ options: [AgentModelOption]) -> Bool {
        let keys = Set(options.flatMap { codexEquivalenceKeys(for: $0.rawValue) })
        let requiredKeyGroups: [[String]] = [
            ["gpt-5.6-sol-low", "gpt-5.6-low"],
            ["gpt-5.6-sol-medium", "gpt-5.6-medium"],
            ["gpt-5.6-sol-high", "gpt-5.6-high"],
            ["gpt-5.3-codex"]
        ]
        return requiredKeyGroups.contains { group in
            !group.contains { keys.contains($0) }
        }
    }

    private func codexEquivalenceKeys(for rawValue: String) -> Set<String> {
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

    private func remoteModels(
        from records: [CodexDynamicModelRecord]
    ) -> [CodexAppServerClient.RemoteModel] {
        records.map { record in
            CodexAppServerClient.RemoteModel(
                id: record.id,
                model: record.model,
                displayName: record.displayName,
                description: record.description,
                isDefault: record.isDefault,
                supportedReasoningEfforts: record.supportedReasoningEfforts.map {
                    CodexAppServerClient.RemoteReasoningEffort(
                        reasoningEffort: $0.reasoningEffort,
                        description: $0.description
                    )
                },
                defaultReasoningEffort: record.defaultReasoningEffort
            )
        }
    }

    #if DEBUG
        @_spi(TestSupport)
        public func test_mergeCodexOptions(
            primary: [AgentModelOption],
            fallback: [AgentModelOption]
        ) -> [AgentModelOption] {
            mergeCodexOptions(primary: primary, fallback: fallback)
        }
    #endif
}
