import Foundation

/// Model-catalog seam for the Claude-compatible plugin path.
///
/// The provider package owns Claude-compatible catalog strings/DTO metadata. This
/// adapter maps those DTOs back onto RepoPrompt's stable `AgentModel` raw values,
/// option DTOs, defaults, and validation semantics.
enum ClaudeCompatibleModelCatalogAdapter {
    static func catalogSnapshot(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        includeClaudeEffortVariants: Bool = true
    ) -> ClaudeCompatiblePluginModelCatalogSnapshot? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind) else { return nil }
        let snapshot = pluginCatalogSnapshot(
            pluginID: pluginID,
            agentKind: agentKind,
            includeClaudeEffortVariants: includeClaudeEffortVariants
        )
        let mappedOptions = AgentModelCatalog.isAgentAvailable(agentKind, availability: availability)
            ? snapshot.options.map { canonicalPluginModelOption($0, for: agentKind) }
            : []
        return ClaudeCompatiblePluginModelCatalogSnapshot(
            pluginID: snapshot.pluginID,
            defaultModelRaw: canonicalModelRaw(snapshot.defaultModelRaw, for: agentKind),
            options: mappedOptions
        )
    }

    static func defaultModelRaw(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current
    ) -> String? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind) else { return nil }
        return canonicalModelRaw(
            pluginCatalogSnapshot(
                pluginID: pluginID,
                agentKind: agentKind,
                includeClaudeEffortVariants: false
            ).defaultModelRaw,
            for: agentKind
        )
    }

    static func options(
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        includeClaudeEffortVariants: Bool = true
    ) -> [AgentModelOption]? {
        catalogSnapshot(
            for: agentKind,
            availability: availability,
            includeClaudeEffortVariants: includeClaudeEffortVariants
        ).map { modelOptions(from: $0.options, for: agentKind) }
    }

    static func modelOptions(
        from pluginOptions: [ClaudeCompatiblePluginModelOption],
        for agentKind: AgentProviderKind
    ) -> [AgentModelOption] {
        pluginOptions.map { modelOption(from: $0, for: agentKind) }
    }

    static func pluginModelOption(from option: AgentModelOption) -> ClaudeCompatiblePluginModelOption {
        ClaudeCompatiblePluginModelOption(
            rawValue: option.rawValue,
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedEffortLevels: []
        )
    }

    static func compatibleBackendModelBehavior(
        for agentKind: AgentProviderKind
    ) -> ClaudeCodeCompatibleBackendConfig.ModelBehavior? {
        compatibleBackendConfig(for: agentKind)?.modelBehavior
    }

    static func compatibleBackendDisplayName(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        optionMetadata(forRequestedModelRaw: rawModel, agentKind: agentKind)?.displayName
    }

    static func compatibleBackendDescription(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        optionMetadata(forRequestedModelRaw: rawModel, agentKind: agentKind)?.description
    }

    static func canonicalCompatibleBackendBaseRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
        guard let id = compatibleBackendID(for: agentKind),
              let config = compatibleBackendConfig(for: agentKind) else { return nil }
        switch config.modelBehavior {
        case .noModel:
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            guard specifier.effortLevel == nil else { return nil }
            let base = specifier.baseModel ?? noModelRawValue(for: id)
            return base.caseInsensitiveCompare(noModelRawValue(for: id)) == .orderedSame ? noModelRawValue(for: id) : nil
        case .claudeSlotMapping:
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            let base = specifier.baseModel
            return ClaudeCodeGLMIntegration.normalizedSlotModel(
                base,
                config: config
            )
        }
    }

    static func canonicalCompatibleBackendModelRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let base = canonicalCompatibleBackendBaseRaw(specifier.baseModel, for: agentKind) else { return rawModel }
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: base, effort: effort)
        }
        return base
    }

    static func canonicalClaudeGLMModelRaw(_ rawModel: String?) -> String? {
        guard let rawModel = normalizedRawModel(rawModel) else {
            return ClaudeCodeGLMIntegration.normalizedGLMModel(nil)
        }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let baseModel = specifier.baseModel else {
            return rawModel
        }
        guard let mappedBaseModel = ClaudeCodeGLMIntegration.normalizedGLMModel(baseModel) else {
            return rawModel
        }
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: mappedBaseModel, effort: effort)
        }
        return mappedBaseModel
    }

    static func isValid(
        rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> Bool? {
        guard ClaudeCompatiblePluginBridge.pluginID(for: agentKind) != nil else { return nil }
        guard AgentModelCatalog.isAgentAvailable(agentKind, availability: availability) else { return false }
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if compatibleBackendID(for: agentKind) != nil {
            return isValidCompatibleBackendModel(normalized, for: agentKind, availability: availability)
        }

        let specifier = ClaudeModelSpecifier(raw: normalized)
        guard let baseModel = specifier.baseModel else {
            if let effort = specifier.effortLevel {
                return claudeEffort(effort, isSupportedForBaseModelRaw: nil, agentKind: agentKind)
            }
            return agentKind == .claudeCode
        }
        if let effort = specifier.effortLevel,
           !claudeEffort(effort, isSupportedForBaseModelRaw: baseModel, agentKind: agentKind)
        {
            return false
        }
        guard let known = AgentModel.resolvedModel(forRaw: baseModel, agentKind: agentKind) else { return false }
        guard known.isValidFor(agentKind) else { return false }
        return known.isAvailable
    }

    static func claudeEffort(
        _ effort: ClaudeCodeEffortLevel,
        isSupportedForBaseModelRaw baseModelRaw: String?,
        agentKind: AgentProviderKind?
    ) -> Bool {
        if let agentKind, compatibleBackendModelBehavior(for: agentKind) == .noModel {
            return false
        }
        guard effort == .xhigh else { return true }
        if let agentKind, compatibleBackendID(for: agentKind) != nil {
            return false
        }
        guard let baseModelRaw else { return false }
        let normalized = baseModelRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return claudeXHighEligibleBaseRaws.contains(normalized)
    }

    private static func pluginCatalogSnapshot(
        pluginID: ClaudeCompatiblePluginID,
        agentKind: AgentProviderKind,
        includeClaudeEffortVariants: Bool
    ) -> ClaudeCompatiblePluginModelCatalogSnapshot {
        ClaudeCompatibleProviderRuntimeBridge.modelCatalogSnapshot(
            pluginID: pluginID,
            backendConfig: compatibleBackendConfig(for: agentKind),
            includeEffortVariants: includeClaudeEffortVariants
        )
    }

    private static func canonicalPluginModelOption(
        _ option: ClaudeCompatiblePluginModelOption,
        for agentKind: AgentProviderKind
    ) -> ClaudeCompatiblePluginModelOption {
        ClaudeCompatiblePluginModelOption(
            rawValue: canonicalModelRaw(option.rawValue, for: agentKind),
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault,
            supportedEffortLevels: option.supportedEffortLevels
        )
    }

    private static func modelOption(from option: ClaudeCompatiblePluginModelOption, for agentKind: AgentProviderKind) -> AgentModelOption {
        AgentModelOption(
            rawValue: canonicalModelRaw(option.rawValue, for: agentKind),
            displayName: option.displayName,
            description: option.description,
            isPlaceholderDefault: option.isPlaceholderDefault,
            isProviderDefault: option.isProviderDefault
        )
    }

    private static func optionMetadata(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> ClaudeCompatiblePluginModelOption? {
        guard let pluginID = ClaudeCompatiblePluginBridge.pluginID(for: agentKind),
              let canonical = canonicalCompatibleBackendBaseRaw(rawModel, for: agentKind) else { return nil }
        let snapshot = pluginCatalogSnapshot(
            pluginID: pluginID,
            agentKind: agentKind,
            includeClaudeEffortVariants: false
        )
        return snapshot.options.first {
            canonicalModelRaw($0.rawValue, for: agentKind).caseInsensitiveCompare(canonical) == .orderedSame
        }
    }

    private static func canonicalModelRaw(_ rawValue: String, for agentKind: AgentProviderKind) -> String {
        let specifier = ClaudeModelSpecifier(raw: rawValue)
        guard let baseModel = specifier.baseModel else {
            return AgentModel.defaultModel.rawValue
        }
        let canonicalBase = canonicalBaseModelRaw(baseModel, for: agentKind) ?? baseModel
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: canonicalBase, effort: effort)
        }
        return canonicalBase
    }

    private static func canonicalBaseModelRaw(_ rawValue: String, for agentKind: AgentProviderKind) -> String? {
        if let compatible = canonicalCompatibleBackendBaseRaw(rawValue, for: agentKind) {
            return compatible
        }
        if rawValue.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            return AgentModel.defaultModel.rawValue
        }
        if let known = AgentModel(rawValue: rawValue) {
            return known.rawValue
        }
        if agentKind == .claudeCodeGLM,
           let mapped = ClaudeCodeGLMIntegration.normalizedGLMModel(rawValue)
        {
            return mapped
        }
        return nil
    }

    private static func isValidCompatibleBackendModel(
        _ rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> Bool {
        guard AgentModelCatalog.isAgentAvailable(agentKind, availability: availability) else { return false }
        guard let config = compatibleBackendConfig(for: agentKind) else { return false }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        switch config.modelBehavior {
        case .noModel:
            guard specifier.effortLevel == nil,
                  let base = specifier.baseModel else { return false }
            return compatibleBackendID(for: agentKind).map { base.caseInsensitiveCompare(noModelRawValue(for: $0)) == .orderedSame } ?? false
        case .claudeSlotMapping:
            guard let canonical = canonicalCompatibleBackendModelRaw(rawModel, for: agentKind) else { return false }
            let canonicalSpecifier = ClaudeModelSpecifier(raw: canonical)
            guard let base = canonicalSpecifier.baseModel,
                  [AgentModel.claudeHaiku.rawValue, AgentModel.claudeSonnet.rawValue, AgentModel.claudeOpus.rawValue].contains(base)
            else {
                return false
            }
            if let effort = canonicalSpecifier.effortLevel {
                return claudeEffort(effort, isSupportedForBaseModelRaw: base, agentKind: agentKind)
            }
            return true
        }
    }

    private static func compatibleBackendID(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendID? {
        switch agentKind {
        case .claudeCodeGLM:
            .glmZAI
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .custom
        case .claudeCode, .codexExec, .openCode, .cursor:
            nil
        }
    }

    private static func compatibleBackendConfig(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendConfig? {
        compatibleBackendID(for: agentKind).map { ClaudeCodeCompatibleBackendStore.shared.config(for: $0).normalized }
    }

    private static func noModelRawValue(for id: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: id)
    }

    private static func normalizedRawModel(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Base model raw values (lowercased) that support the XHigh effort tier.
    private static let claudeXHighEligibleBaseRaws: Set<String> = [
        AgentModel.claudeFable5.rawValue.lowercased(),
        AgentModel.claudeOpus.rawValue.lowercased(),
        AgentModel.claudeOpus1m.rawValue.lowercased(),
        AgentModel.claudeOpus47.rawValue.lowercased(),
        AgentModel.claudeOpus46.rawValue.lowercased(),
        AgentModel.claudeOpus45.rawValue.lowercased()
    ]
}
