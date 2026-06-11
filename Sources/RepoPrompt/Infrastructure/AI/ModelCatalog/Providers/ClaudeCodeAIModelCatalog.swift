import Foundation

enum ClaudeCodeAIModelCatalog {
    static let rawPrefix = "claude_code__"
    static let compatibleBackendSpecifierPrefix = "compatible:"

    struct CompatibleBackendModelDescriptor: Hashable {
        let backendID: ClaudeCodeCompatibleBackendID
        let requestedModelRaw: String?
        let groupDisplayName: String
        let optionDisplayName: String
        let modelDisplayName: String
    }

    private struct ModelDefinition: Hashable {
        let runtimeModelRaw: String
        let displayName: String
        let supportedEfforts: [ClaudeCodeEffortLevel]
    }

    private static let pickerEffortOrder: [ClaudeCodeEffortLevel] = [
        .low, .medium, .high, .max, .xhigh
    ]

    private static let modelDefinitions: [ModelDefinition] = [
        ModelDefinition(runtimeModelRaw: "claude-fable-5", displayName: "Fable 5", supportedEfforts: [.low, .medium, .high, .max, .xhigh]),
        ModelDefinition(runtimeModelRaw: "opus[1m]", displayName: "Opus Latest (1M)", supportedEfforts: [.low, .medium, .high, .max, .xhigh]),
        ModelDefinition(runtimeModelRaw: "opus", displayName: "Opus Latest", supportedEfforts: [.low, .medium, .high, .max, .xhigh]),
        ModelDefinition(runtimeModelRaw: "claude-opus-4-7", displayName: "Opus 4.7", supportedEfforts: [.low, .medium, .high, .max, .xhigh]),
        ModelDefinition(runtimeModelRaw: "claude-opus-4-6", displayName: "Opus 4.6", supportedEfforts: [.low, .medium, .high, .max, .xhigh]),
        ModelDefinition(runtimeModelRaw: "claude-opus-4-5-20251101", displayName: "Opus 4.5", supportedEfforts: []),
        ModelDefinition(runtimeModelRaw: "sonnet[1m]", displayName: "Sonnet Latest (1M)", supportedEfforts: [.low, .medium, .high]),
        ModelDefinition(runtimeModelRaw: "sonnet", displayName: "Sonnet Latest", supportedEfforts: [.low, .medium, .high]),
        ModelDefinition(runtimeModelRaw: "claude-sonnet-4-6", displayName: "Sonnet 4.6", supportedEfforts: [.low, .medium, .high]),
        ModelDefinition(runtimeModelRaw: "claude-sonnet-4-5-20250929", displayName: "Sonnet 4.5", supportedEfforts: []),
        ModelDefinition(runtimeModelRaw: "haiku", displayName: "Haiku Latest", supportedEfforts: []),
        ModelDefinition(runtimeModelRaw: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", supportedEfforts: [])
    ]

    static func normalizedSpecifier(_ specifier: String) -> String {
        specifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func runtimeSpecifierRaw(for model: AIModel) -> String? {
        switch model {
        case .claudeCode:
            nil
        case .claudeCodeSonnet:
            "sonnet"
        case .claudeCodeHaiku:
            "haiku"
        case .claudeCodeOpus:
            "opus"
        case let .claudeCodeModel(specifier):
            normalizedSpecifier(specifier)
        default:
            nil
        }
    }

    static func validatedModel(specifier rawSpecifier: String) -> AIModel? {
        let normalized = normalizedSpecifier(rawSpecifier)
        if compatibleBackendDescriptor(specifier: normalized) != nil {
            return .claudeCodeModel(specifier: normalized)
        }
        let parsed = ClaudeModelSpecifier(raw: normalized)
        if normalized.contains(":"), parsed.explicitEffortLevel == nil {
            return nil
        }
        guard let baseModel = parsed.baseModel else {
            return nil
        }
        guard let definition = definition(forBaseModelRaw: baseModel) else {
            return validatedAgentCatalogEffortModel(specifier: normalized)
        }
        if let effort = parsed.explicitEffortLevel {
            if definition.supportedEfforts.contains(effort) {
                return .claudeCodeModel(specifier: encodedSpecifier(baseModelRaw: definition.runtimeModelRaw, effort: effort))
            }
            return validatedAgentCatalogEffortModel(specifier: normalized)
        }
        return legacyModel(forBaseModelRaw: definition.runtimeModelRaw)
            ?? .claudeCodeModel(specifier: definition.runtimeModelRaw)
    }

    static func validatedAgentCatalogEffortModel(specifier rawSpecifier: String) -> AIModel? {
        guard let canonical = canonicalAgentCatalogEffortSpecifier(rawSpecifier) else {
            return nil
        }
        guard AgentModelCatalog.isValid(
            rawModel: canonical,
            for: .claudeCode,
            availability: agentCatalogValidationAvailability
        ) else {
            return nil
        }
        return .claudeCodeModel(specifier: canonical)
    }

    static func displayName(for specifier: String) -> String {
        if let descriptor = compatibleBackendDescriptor(specifier: specifier) {
            return descriptor.modelDisplayName
        }
        let parsed = ClaudeModelSpecifier(raw: specifier)
        guard let definition = definition(forBaseModelRaw: parsed.baseModel) else {
            if let canonical = canonicalAgentCatalogEffortSpecifier(specifier),
               validatedAgentCatalogEffortModel(specifier: canonical) != nil
            {
                let catalogDisplayName = AgentModelCatalog.displayName(
                    for: canonical,
                    agentKind: .claudeCode,
                    availability: agentCatalogValidationAvailability
                )
                return "Claude Code \(catalogDisplayName)"
            }
            let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Claude Code" : "Claude Code \(trimmed)"
        }
        if let effort = parsed.explicitEffortLevel {
            return "Claude Code \(definition.displayName) \(effort.displayName)"
        }
        return "Claude Code \(definition.displayName)"
    }

    static func modelsForPicker() -> [AIModel] {
        var models: [AIModel] = [.claudeCode]
        for definition in modelDefinitions {
            if let legacyModel = legacyModel(forBaseModelRaw: definition.runtimeModelRaw) {
                models.append(legacyModel)
            } else {
                models.append(.claudeCodeModel(specifier: definition.runtimeModelRaw))
            }
            models.append(contentsOf: definition.supportedEfforts.map {
                .claudeCodeModel(specifier: encodedSpecifier(baseModelRaw: definition.runtimeModelRaw, effort: $0))
            })
        }
        return models
    }

    static func compatibleBackendModelsForPicker(_ backendID: ClaudeCodeCompatibleBackendID) -> [AIModel] {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized
        switch config.modelBehavior {
        case .noModel:
            return [.claudeCodeModel(specifier: compatibleBackendSpecifier(backendID: backendID, requestedModelRaw: nil))]
        case .claudeSlotMapping:
            return [
                .claudeCodeModel(specifier: compatibleBackendSpecifier(backendID: backendID, requestedModelRaw: AgentModel.claudeHaiku.rawValue)),
                .claudeCodeModel(specifier: compatibleBackendSpecifier(backendID: backendID, requestedModelRaw: AgentModel.claudeSonnet.rawValue)),
                .claudeCodeModel(specifier: compatibleBackendSpecifier(backendID: backendID, requestedModelRaw: AgentModel.claudeOpus.rawValue))
            ]
        }
    }

    static func compatibleBackendDescriptor(for model: AIModel) -> CompatibleBackendModelDescriptor? {
        guard case let .claudeCodeModel(specifier) = model else { return nil }
        return compatibleBackendDescriptor(specifier: specifier)
    }

    static func compatibleBackendID(for model: AIModel) -> ClaudeCodeCompatibleBackendID? {
        compatibleBackendDescriptor(for: model)?.backendID
    }

    static func menu(for models: [AIModel]) -> AIModel.ClaudeCodePickerMenu {
        let sortedModels = AIModel.sortedForPicker(models.filter { $0.providerType == .claudeCode })

        struct Entry {
            let model: AIModel
            let baseModelRaw: String
            let groupDisplayName: String
            let optionDisplayName: String
            let index: Int
            let effort: ClaudeCodeEffortLevel?
        }

        let entries = sortedModels.compactMap { model -> Entry? in
            if compatibleBackendDescriptor(for: model) != nil {
                return nil
            }
            guard model != .claudeCode,
                  let rawSpecifier = model.claudeCodeRuntimeSpecifierRaw
            else {
                return nil
            }
            let specifier = ClaudeModelSpecifier(raw: rawSpecifier)
            guard let definition = definition(forBaseModelRaw: specifier.baseModel),
                  let index = modelDefinitions.firstIndex(of: definition)
            else {
                return nil
            }
            return Entry(
                model: model,
                baseModelRaw: definition.runtimeModelRaw,
                groupDisplayName: definition.displayName,
                optionDisplayName: specifier.explicitEffortLevel?.displayName ?? "Default",
                index: index,
                effort: specifier.explicitEffortLevel
            )
        }

        let groupedEntries = Dictionary(grouping: entries, by: { $0.baseModelRaw.lowercased() })
        let groups = groupedEntries.compactMap { _, groupEntries -> AIModel.ClaudeCodePickerMenuGroup? in
            guard let representative = groupEntries.min(by: { $0.index < $1.index }) else { return nil }
            var seenRawValues: Set<String> = []
            let hasEffortVariants = groupEntries.contains { $0.effort != nil }
            let visibleEntries = hasEffortVariants
                ? groupEntries.filter { $0.effort != nil }
                : groupEntries
            let options = visibleEntries
                .sorted { lhs, rhs in
                    let leftRank = effortSortRank(lhs.effort)
                    let rightRank = effortSortRank(rhs.effort)
                    if leftRank != rightRank {
                        return leftRank < rightRank
                    }
                    return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
                }
                .compactMap { entry -> AIModel.ClaudeCodePickerMenuOption? in
                    guard seenRawValues.insert(entry.model.rawValue.lowercased()).inserted else { return nil }
                    let displayName = entry.effort == nil ? entry.groupDisplayName : entry.optionDisplayName
                    return AIModel.ClaudeCodePickerMenuOption(model: entry.model, displayName: displayName)
                }
            guard !options.isEmpty else { return nil }
            return AIModel.ClaudeCodePickerMenuGroup(
                baseModelRaw: representative.baseModelRaw,
                displayName: representative.groupDisplayName,
                options: options,
                rendersAsSubmenu: hasEffortVariants
            )
        }.sorted { lhs, rhs in
            let leftRank = baseSortRank(lhs.baseModelRaw)
            let rightRank = baseSortRank(rhs.baseModelRaw)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let compatibleGroups = compatibleBackendMenuGroups(for: sortedModels)
        return AIModel.ClaudeCodePickerMenu(defaultOption: nil, groups: groups + compatibleGroups)
    }

    static func modelPrecedes(_ lhs: AIModel, _ rhs: AIModel) -> Bool {
        let lhsCompatible = compatibleBackendDescriptor(for: lhs)
        let rhsCompatible = compatibleBackendDescriptor(for: rhs)
        if lhsCompatible != nil || rhsCompatible != nil {
            if lhsCompatible == nil { return true }
            if rhsCompatible == nil { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        let leftBaseRank = baseSortRank(baseModelRaw(for: lhs))
        let rightBaseRank = baseSortRank(baseModelRaw(for: rhs))
        if leftBaseRank != rightBaseRank {
            return leftBaseRank < rightBaseRank
        }

        let leftEffortRank = effortSortRank(explicitEffort(for: lhs))
        let rightEffortRank = effortSortRank(explicitEffort(for: rhs))
        if leftEffortRank != rightEffortRank {
            return leftEffortRank < rightEffortRank
        }

        let displayComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }
        return lhs.rawValue.localizedCaseInsensitiveCompare(rhs.rawValue) == .orderedAscending
    }

    private static func definition(forBaseModelRaw raw: String?) -> ModelDefinition? {
        guard let raw else { return nil }
        let normalized = normalizedSpecifier(raw)
        guard !normalized.isEmpty else { return nil }
        return modelDefinitions.first {
            $0.runtimeModelRaw.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private static func legacyModel(forBaseModelRaw raw: String) -> AIModel? {
        switch normalizedSpecifier(raw) {
        case "opus": .claudeCodeOpus
        case "sonnet": .claudeCodeSonnet
        case "haiku": .claudeCodeHaiku
        default: nil
        }
    }

    private static func encodedSpecifier(baseModelRaw: String, effort: ClaudeCodeEffortLevel) -> String {
        "\(normalizedSpecifier(baseModelRaw)):\(effort.rawValue)"
    }

    private static func compatibleBackendSpecifier(
        backendID: ClaudeCodeCompatibleBackendID,
        requestedModelRaw: String?
    ) -> String {
        let alias = compatibleBackendAlias(for: backendID)
        guard let requestedModelRaw, !requestedModelRaw.isEmpty else {
            return "\(compatibleBackendSpecifierPrefix)\(alias)"
        }
        return "\(compatibleBackendSpecifierPrefix)\(alias):\(normalizedSpecifier(requestedModelRaw))"
    }

    private static func compatibleBackendDescriptor(specifier rawSpecifier: String) -> CompatibleBackendModelDescriptor? {
        let normalized = normalizedSpecifier(rawSpecifier)
        guard normalized.hasPrefix(compatibleBackendSpecifierPrefix) else { return nil }
        let rest = normalized.dropFirst(compatibleBackendSpecifierPrefix.count)
        let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
        guard let alias = parts.first,
              let backendID = compatibleBackendID(forAlias: alias) else { return nil }
        let requestedModelRaw = parts.count > 1 ? parts[1] : nil
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized

        switch config.modelBehavior {
        case .noModel:
            guard requestedModelRaw == nil || requestedModelRaw == noModelRawValue(for: backendID) else { return nil }
            let name = noModelDisplayName(for: backendID, config: config)
            return CompatibleBackendModelDescriptor(
                backendID: backendID,
                requestedModelRaw: nil,
                groupDisplayName: name,
                optionDisplayName: name,
                modelDisplayName: name
            )
        case let .claudeSlotMapping(mapping):
            let normalizedMapping = mapping.normalized
            let slot = requestedModelRaw ?? AgentModel.claudeSonnet.rawValue
            let optionName: String
            let backendModelID: String
            switch slot {
            case AgentModel.claudeHaiku.rawValue:
                optionName = "Haiku"
                backendModelID = normalizedMapping.haiku
            case AgentModel.claudeSonnet.rawValue:
                optionName = "Sonnet"
                backendModelID = normalizedMapping.sonnet
            case AgentModel.claudeOpus.rawValue:
                optionName = "Opus"
                backendModelID = normalizedMapping.opus
            default:
                return nil
            }
            let backendDisplayName = displayName(forBackendModelID: backendModelID)
            let groupName = config.normalizedDisplayName
            return CompatibleBackendModelDescriptor(
                backendID: backendID,
                requestedModelRaw: slot,
                groupDisplayName: groupName,
                optionDisplayName: "\(optionName) - \(backendDisplayName)",
                modelDisplayName: "\(groupName) \(optionName)"
            )
        }
    }

    private static func compatibleBackendMenuGroups(for models: [AIModel]) -> [AIModel.ClaudeCodePickerMenuGroup] {
        let compatibleModels = models.compactMap { model -> (AIModel, CompatibleBackendModelDescriptor)? in
            guard let descriptor = compatibleBackendDescriptor(for: model) else { return nil }
            return (model, descriptor)
        }
        let grouped = Dictionary(grouping: compatibleModels, by: { $0.1.backendID })
        return grouped.compactMap { backendID, entries -> AIModel.ClaudeCodePickerMenuGroup? in
            guard let first = entries.first else { return nil }
            let options = entries
                .sorted { lhs, rhs in
                    compatibleBackendOptionRank(lhs.1.requestedModelRaw) < compatibleBackendOptionRank(rhs.1.requestedModelRaw)
                }
                .map { model, descriptor in
                    AIModel.ClaudeCodePickerMenuOption(model: model, displayName: descriptor.optionDisplayName)
                }
            guard !options.isEmpty else { return nil }
            return AIModel.ClaudeCodePickerMenuGroup(
                baseModelRaw: "compatible:\(compatibleBackendAlias(for: backendID))",
                displayName: first.1.groupDisplayName,
                options: options,
                rendersAsSubmenu: options.count > 1
            )
        }.sorted {
            compatibleBackendSortRank($0.baseModelRaw) < compatibleBackendSortRank($1.baseModelRaw)
        }
    }

    private static func compatibleBackendOptionRank(_ rawModel: String?) -> Int {
        switch rawModel {
        case .some(AgentModel.claudeHaiku.rawValue): 0
        case .some(AgentModel.claudeSonnet.rawValue): 1
        case .some(AgentModel.claudeOpus.rawValue): 2
        default: 0
        }
    }

    private static func compatibleBackendSortRank(_ raw: String) -> Int {
        if raw.contains(compatibleBackendAlias(for: .glmZAI)) { return 0 }
        if raw.contains(compatibleBackendAlias(for: .kimi)) { return 1 }
        if raw.contains(compatibleBackendAlias(for: .custom)) { return 2 }
        return 99
    }

    private static func compatibleBackendAlias(for id: ClaudeCodeCompatibleBackendID) -> String {
        switch id {
        case .glmZAI: "glmzai"
        case .kimi: "kimi"
        case .custom: "custom"
        }
    }

    private static func compatibleBackendID(forAlias alias: String) -> ClaudeCodeCompatibleBackendID? {
        switch alias.lowercased() {
        case compatibleBackendAlias(for: .glmZAI): .glmZAI
        case compatibleBackendAlias(for: .kimi): .kimi
        case compatibleBackendAlias(for: .custom): .custom
        default: nil
        }
    }

    private static func noModelRawValue(for id: ClaudeCodeCompatibleBackendID) -> String {
        switch id {
        case .glmZAI:
            AgentModel.claudeSonnet.rawValue
        case .kimi:
            AgentModel.kimiCode.rawValue
        case .custom:
            AgentModel.customClaudeCompatible.rawValue
        }
    }

    private static func noModelDisplayName(
        for id: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String {
        switch id {
        case .kimi:
            "Kimi Code"
        case .glmZAI, .custom:
            config.normalizedDisplayName
        }
    }

    private static func displayName(forBackendModelID modelID: String) -> String {
        if let model = AgentModel(rawValue: modelID) {
            return model.displayName
        }
        return modelID
    }

    private static var agentCatalogValidationAvailability: AgentModelCatalog.AvailabilityContext {
        AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false
        )
    }

    private static func canonicalAgentCatalogEffortSpecifier(_ rawSpecifier: String) -> String? {
        let normalized = normalizedSpecifier(rawSpecifier)
        let parsed = ClaudeModelSpecifier(raw: normalized)
        guard let baseModel = parsed.baseModel,
              let effort = parsed.explicitEffortLevel
        else {
            return nil
        }
        return encodedSpecifier(baseModelRaw: baseModel, effort: effort)
    }

    private static func baseModelRaw(for model: AIModel) -> String? {
        guard let rawSpecifier = runtimeSpecifierRaw(for: model) else { return nil }
        return ClaudeModelSpecifier(raw: rawSpecifier).baseModel
    }

    private static func explicitEffort(for model: AIModel) -> ClaudeCodeEffortLevel? {
        guard let rawSpecifier = runtimeSpecifierRaw(for: model) else { return nil }
        return ClaudeModelSpecifier(raw: rawSpecifier).explicitEffortLevel
    }

    private static func baseSortRank(_ raw: String?) -> Int {
        guard let raw else { return -1 }
        let normalized = normalizedSpecifier(raw)
        return modelDefinitions.firstIndex {
            $0.runtimeModelRaw.caseInsensitiveCompare(normalized) == .orderedSame
        } ?? Int.max
    }

    private static func effortSortRank(_ effort: ClaudeCodeEffortLevel?) -> Int {
        guard let effort else { return 0 }
        guard let index = pickerEffortOrder.firstIndex(of: effort) else {
            return Int.max
        }
        return index + 1
    }
}
