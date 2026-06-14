import Foundation

enum AgentModelCatalog {
    struct AvailabilityContext: Equatable {
        let claudeCodeAvailable: Bool
        let codexAvailable: Bool
        let openCodeAvailable: Bool
        let cursorAvailable: Bool
        let zaiConfigured: Bool
        let kimiConfigured: Bool
        let customClaudeCompatibleConfigured: Bool

        static let none = AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        func filteredForRecommendationProviders(_ providers: Set<RecommendationProviderKind>) -> AvailabilityContext {
            AvailabilityContext(
                claudeCodeAvailable: claudeCodeAvailable && providers.contains(.claudeCode),
                codexAvailable: codexAvailable && providers.contains(.codex),
                openCodeAvailable: false,
                cursorAvailable: cursorAvailable && providers.contains(.cursor),
                zaiConfigured: zaiConfigured && providers.contains(.claudeCode),
                kimiConfigured: kimiConfigured && providers.contains(.claudeCode),
                customClaudeCompatibleConfigured: customClaudeCompatibleConfigured && providers.contains(.claudeCode)
            )
        }

        static var current: AvailabilityContext {
            let store = ClaudeCodeCompatibleBackendStore.shared
            return AvailabilityContext(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false,
                zaiConfigured: backendIsAvailable(.glmZAI, store: store),
                kimiConfigured: backendIsAvailable(.kimi, store: store),
                customClaudeCompatibleConfigured: backendIsAvailable(.custom, store: store)
            )
        }

        init(
            claudeCodeAvailable: Bool = true,
            codexAvailable: Bool = true,
            openCodeAvailable: Bool = true,
            cursorAvailable: Bool = false,
            zaiConfigured: Bool = false,
            kimiConfigured: Bool = false,
            customClaudeCompatibleConfigured: Bool = false
        ) {
            self.claudeCodeAvailable = claudeCodeAvailable
            self.codexAvailable = codexAvailable
            self.openCodeAvailable = openCodeAvailable
            self.cursorAvailable = cursorAvailable
            self.zaiConfigured = zaiConfigured
            self.kimiConfigured = kimiConfigured
            self.customClaudeCompatibleConfigured = customClaudeCompatibleConfigured
        }

        func isCompatibleBackendConfigured(_ id: ClaudeCodeCompatibleBackendID) -> Bool {
            switch id {
            case .glmZAI:
                zaiConfigured
            case .kimi:
                kimiConfigured
            case .custom:
                customClaudeCompatibleConfigured
            }
        }

        func assumingAvailable(_ agentKind: AgentProviderKind) -> AvailabilityContext {
            AvailabilityContext(
                claudeCodeAvailable: claudeCodeAvailable || agentKind == .claudeCode,
                codexAvailable: codexAvailable || agentKind == .codexExec,
                openCodeAvailable: openCodeAvailable || agentKind == .openCode,
                cursorAvailable: cursorAvailable || agentKind == .cursor,
                zaiConfigured: zaiConfigured || agentKind == .claudeCodeGLM,
                kimiConfigured: kimiConfigured || agentKind == .kimiCode,
                customClaudeCompatibleConfigured: customClaudeCompatibleConfigured || agentKind == .customClaudeCompatible
            )
        }
    }

    enum AgentSelectionSurface: Equatable {
        case general

        func allows(_ agentKind: AgentProviderKind) -> Bool {
            true
        }
    }

    struct NormalizedAgentSelection: Equatable {
        let agent: AgentProviderKind
        let modelRaw: String
    }

    struct CodexMenuGroup: Identifiable, Hashable {
        let baseModelID: String
        let displayName: String
        let options: [AgentModelOption]

        var id: String {
            baseModelID.lowercased()
        }
    }

    struct CodexMenu: Hashable {
        let defaultOption: AgentModelOption?
        let groups: [CodexMenuGroup]
    }

    struct ClaudeMenuGroup: Identifiable, Hashable {
        let baseModelRaw: String
        let displayName: String
        let options: [AgentModelOption]
        let rendersAsSubmenu: Bool

        var id: String {
            baseModelRaw.lowercased()
        }
    }

    struct ClaudeMenu: Hashable {
        let defaultOption: AgentModelOption?
        let groups: [ClaudeMenuGroup]
    }

    struct OpenCodeMenuOption: Identifiable, Hashable {
        let option: AgentModelOption
        let displayName: String
        let variantDisplayName: String?
        let isBaseOption: Bool

        var id: String {
            option.rawValue
        }
    }

    struct OpenCodeMenuGroup: Identifiable, Hashable {
        let providerID: String?
        let providerDisplayName: String?
        let baseModelID: String
        let displayName: String
        let modelDisplayName: String
        let options: [OpenCodeMenuOption]
        let rendersAsSubmenu: Bool
        let sortIndex: Int

        var id: String {
            let providerKey = providerID?.lowercased() ?? "_root"
            return "\(providerKey)/\(baseModelID.lowercased())"
        }
    }

    struct OpenCodeProviderMenuGroup: Identifiable, Hashable {
        let providerID: String?
        let displayName: String
        let groups: [OpenCodeMenuGroup]
        let rendersAsSubmenu: Bool
        let sortIndex: Int

        var id: String {
            providerID?.lowercased() ?? "_root"
        }
    }

    struct OpenCodeMenu: Hashable {
        let providerGroups: [OpenCodeProviderMenuGroup]
        let groups: [OpenCodeMenuGroup]
    }

    static let supportedCLIProviderAgents: [AgentProviderKind] = [
        .codexExec,
        .claudeCode,
        .openCode,
        .cursor
    ]

    static func selectableAgents(
        availability: AvailabilityContext = .current,
        surface: AgentSelectionSurface = .general
    ) -> [AgentProviderKind] {
        [.codexExec, .claudeCode, .openCode, .cursor, .claudeCodeGLM, .kimiCode, .customClaudeCompatible]
            .filter { surface.allows($0) && isAgentAvailable($0, availability: availability) }
    }

    static func hasUnconfiguredSupportedCLIProviders(
        availableAgents: [AgentProviderKind]
    ) -> Bool {
        let available = Set(availableAgents)
        return supportedCLIProviderAgents.contains { !available.contains($0) }
    }

    static func isAgentAvailable(
        _ agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current
    ) -> Bool {
        switch agentKind {
        case .claudeCodeGLM:
            availability.zaiConfigured
        case .kimiCode:
            availability.kimiConfigured
        case .customClaudeCompatible:
            availability.customClaudeCompatibleConfigured
        case .claudeCode:
            availability.claudeCodeAvailable
        case .codexExec:
            availability.codexAvailable
        case .openCode:
            availability.openCodeAvailable
        case .cursor:
            availability.cursorAvailable
        }
    }

    static func defaultModelRaw(
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> String {
        _ = codexDynamicModels
        if agentKind == .cursor {
            return AgentModel.cursorAuto.rawValue
        }
        if isAgentAvailable(agentKind, availability: availability),
           let preferredModelRaw = resolvedACPDiscoveredModels(for: agentKind)?.preferredModelRaw
        {
            return preferredModelRaw
        }
        switch agentKind {
        case .cursor:
            return AgentModel.cursorAuto.rawValue
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            return ClaudeCompatibleModelCatalogAdapter.defaultModelRaw(for: agentKind, availability: availability)
                ?? AgentModel.defaultModel.rawValue
        case .codexExec, .openCode:
            return AgentModel.defaultModel.rawValue
        }
    }

    static func normalizeSelection(
        agentRaw: String?,
        modelRaw: String?,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        preserveUnavailableAgent: Bool = false,
        surface: AgentSelectionSurface = .general
    ) -> NormalizedAgentSelection {
        let parsedAgent = normalizedAgentKind(agentRaw)
        var agent = parsedAgent ?? .claudeCode
        var candidateModelRaw = normalizedRawModel(modelRaw)
        var effectiveAvailability = availability

        if agent == .claudeCodeGLM {
            candidateModelRaw = ClaudeCompatibleModelCatalogAdapter.canonicalClaudeGLMModelRaw(candidateModelRaw)
        } else if isCompatibleBackendAgent(agent) {
            candidateModelRaw = ClaudeCompatibleModelCatalogAdapter.canonicalCompatibleBackendModelRaw(candidateModelRaw, for: agent)
        }

        if !surface.allows(agent) || !isAgentAvailable(agent, availability: availability) {
            if preserveUnavailableAgent, parsedAgent != nil, surface.allows(agent) {
                effectiveAvailability = availability.assumingAvailable(agent)
            } else {
                agent = selectableAgents(availability: availability, surface: surface).first ?? .claudeCode
                candidateModelRaw = nil
            }
        }

        let fallbackModelRaw = defaultModelRaw(
            for: agent,
            availability: effectiveAvailability,
            codexDynamicModels: codexDynamicModels
        )
        let resolvedModelRaw = canonicalModelRaw(candidateModelRaw ?? fallbackModelRaw, for: agent)
        let finalModelRaw = isValid(
            rawModel: resolvedModelRaw,
            for: agent,
            availability: effectiveAvailability,
            codexDynamicModels: codexDynamicModels
        )
            ? resolvedModelRaw
            : fallbackModelRaw

        return NormalizedAgentSelection(agent: agent, modelRaw: finalModelRaw)
    }

    static func normalizePersistedSelection(
        agentRaw: String?,
        modelRaw: String?,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        surface: AgentSelectionSurface = .general
    ) -> NormalizedAgentSelection {
        normalizeSelection(
            agentRaw: agentRaw,
            modelRaw: modelRaw,
            availability: availability,
            codexDynamicModels: codexDynamicModels,
            preserveUnavailableAgent: true,
            surface: surface
        )
    }

    static func options(
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        includeClaudeEffortVariants: Bool = true
    ) -> [AgentModelOption] {
        guard isAgentAvailable(agentKind, availability: availability) else { return [] }
        if agentKind == .cursor {
            let fallbacks = [
                staticOption(.cursorAuto, for: .cursor),
                staticOption(.cursorComposer2, for: .cursor)
            ]
            if let discoveredOptions = resolvedACPDiscoveredModels(for: agentKind)?.options,
               !discoveredOptions.isEmpty
            {
                let discoveredWithoutFallbacks = discoveredOptions.filter {
                    !isCursorAutoOption($0) && !isCursorComposer2Option($0)
                }
                return fallbacks + discoveredWithoutFallbacks
            }
            return fallbacks
        }
        if let discoveredOptions = resolvedACPDiscoveredModels(for: agentKind)?.options,
           !discoveredOptions.isEmpty
        {
            return discoveredOptions
        }
        switch agentKind {
        case .codexExec:
            let staticOptions = AgentModel.modelsForAgent(agentKind).map { staticOption($0, for: agentKind) }
            return AgentCodexModelRegistry.shared.resolvedOptions(
                staticOptions: staticOptions,
                preferredLiveModels: codexDynamicModels
            )
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            return ClaudeCompatibleModelCatalogAdapter.options(
                for: agentKind,
                availability: availability,
                includeClaudeEffortVariants: includeClaudeEffortVariants
            ) ?? []
        case .openCode, .cursor:
            return AgentModel.modelsForAgent(agentKind)
                .filter { isAvailable($0, for: agentKind, availability: availability) }
                .map { staticOption($0, for: agentKind) }
        }
    }

    static func isValid(
        rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> Bool {
        _ = codexDynamicModels
        guard isAgentAvailable(agentKind, availability: availability) else { return false }
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if agentKind == .cursor,
           normalized.caseInsensitiveCompare(AgentModel.cursorAuto.rawValue) == .orderedSame
        {
            return true
        }
        if agentKind == .cursor,
           normalized.caseInsensitiveCompare(AgentModel.cursorComposer2.rawValue) == .orderedSame
        {
            return true
        }
        if let discoveredModels = resolvedACPDiscoveredModels(for: agentKind) {
            if agentKind == .cursor {
                return cursorSnapshotContains(rawModel: normalized, snapshot: discoveredModels)
            }
            return discoveredModels.contains(rawModel: normalized)
        }
        if agentKind.usesClaudeTooling,
           let isValid = ClaudeCompatibleModelCatalogAdapter.isValid(
               rawModel: normalized,
               for: agentKind,
               availability: availability
           )
        {
            return isValid
        }
        if agentKind == .codexExec {
            return true
        }
        guard let known = AgentModel.resolvedModel(forRaw: normalized, agentKind: agentKind) else { return false }
        guard known.isValidFor(agentKind) else { return false }
        return isAvailable(known, for: agentKind, availability: availability)
    }

    static func displayName(
        for rawModel: String,
        agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil,
        defaults: UserDefaults = .standard,
        includeEffortSuffix: Bool = true
    ) -> String {
        let normalized = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRaw = normalized.isEmpty
            ? defaultModelRaw(for: agentKind, availability: availability, codexDynamicModels: codexDynamicModels)
            : normalized

        func baseDisplayName(for raw: String) -> String {
            if let compatibleDisplayName = ClaudeCompatibleModelCatalogAdapter.compatibleBackendDisplayName(forRequestedModelRaw: raw, agentKind: agentKind) {
                return compatibleDisplayName
            }
            if let discoveredOption = resolvedACPDiscoveredModels(for: agentKind)?.option(matching: raw) {
                return discoveredOption.displayName
            }
            if let option = options(for: agentKind, availability: availability, codexDynamicModels: codexDynamicModels)
                .first(where: { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame })
            {
                return option.displayName
            }
            if let resolved = AgentModel.resolvedModel(forRaw: raw, agentKind: agentKind) {
                return resolved.displayName
            }
            if let known = AgentModel(rawValue: raw) {
                return known.displayName
            }
            return raw
        }

        if agentKind.usesClaudeTooling {
            let specifier = ClaudeModelSpecifier(raw: effectiveRaw)
            let baseRaw = specifier.baseModel ?? AgentModel.defaultModel.rawValue
            let baseName = baseDisplayName(for: baseRaw)
            if ClaudeCompatibleModelCatalogAdapter.compatibleBackendModelBehavior(for: agentKind) == .noModel {
                return baseName
            }
            guard includeEffortSuffix else { return baseName }
            if let effort = specifier.effortLevel {
                return "\(baseName) \(effort.displayName)"
            }
            let defaultRaw = defaultModelRaw(for: agentKind, availability: availability, codexDynamicModels: codexDynamicModels)
            let isStandardDefaultDisplay = defaults === UserDefaults.standard
                && effectiveRaw.caseInsensitiveCompare(defaultRaw) == .orderedSame
            guard !isStandardDefaultDisplay else { return baseName }
            if let storedEffort = ClaudeAgentToolPreferences.storedEffortLevel(
                forModelRaw: effectiveRaw,
                agentKind: agentKind,
                defaults: defaults,
                includeLegacyFallback: false
            ) {
                return "\(baseName) \(storedEffort.displayName)"
            }
            return baseName
        }

        if agentKind == .codexExec {
            let specifier = CodexModelSpecifier(raw: effectiveRaw)
            let baseSlug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: effectiveRaw)
            let baseName = codexBaseDisplayName(
                forModelSlug: baseSlug,
                rawModel: effectiveRaw,
                availability: availability,
                codexDynamicModels: codexDynamicModels
            )
            guard includeEffortSuffix else { return baseName }
            if let effort = specifier.reasoningEffort {
                return "\(baseName) \(effort.displayName)"
            }
            if let storedEffort = CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)[baseSlug],
               codexEffort(storedEffort, isSupportedForModelRaw: effectiveRaw, availability: availability, codexDynamicModels: codexDynamicModels)
            {
                return "\(baseName) \(storedEffort.displayName)"
            }
            return baseName
        }

        return baseDisplayName(for: effectiveRaw)
    }

    static func openCodeMenu(for options: [AgentModelOption]) -> OpenCodeMenu {
        struct Entry {
            let option: AgentModelOption
            let providerID: String?
            let providerDisplayName: String?
            let baseModelID: String
            let groupDisplayName: String
            let modelDisplayName: String
            let variant: OpenCodeVariant?
            let index: Int
        }

        let entries = options.enumerated().map { index, option -> Entry in
            let normalized = normalizedOpenCodeVariant(option: option)
            return Entry(
                option: option,
                providerID: normalized.providerID,
                providerDisplayName: normalized.providerDisplayName,
                baseModelID: normalized.baseModelID,
                groupDisplayName: normalized.baseDisplayName,
                modelDisplayName: normalized.modelDisplayName,
                variant: normalized.variant,
                index: index
            )
        }

        let groupedEntries = Dictionary(grouping: entries, by: { entry in
            let providerKey = entry.providerID?.lowercased() ?? "_root"
            return "\(providerKey)/\(entry.baseModelID.lowercased())"
        })
        let groups = groupedEntries.values.compactMap { groupEntries -> OpenCodeMenuGroup? in
            guard let representative = groupEntries.min(by: { $0.index < $1.index }) else { return nil }
            let containsVariant = groupEntries.contains { $0.variant != nil }
            let rendersAsSubmenu = containsVariant || groupEntries.count > 1
            let sortedEntries = groupEntries.sorted { lhs, rhs in
                let leftRank = openCodeVariantSortRank(lhs.variant)
                let rightRank = openCodeVariantSortRank(rhs.variant)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                if lhs.option.isProviderDefault != rhs.option.isProviderDefault {
                    return lhs.option.isProviderDefault && !rhs.option.isProviderDefault
                }
                return lhs.index < rhs.index
            }
            let menuOptions = sortedEntries.map { entry in
                let variantDisplayName = entry.variant?.displayName
                let displayName: String = if rendersAsSubmenu {
                    variantDisplayName ?? "Default"
                } else {
                    entry.providerID == nil ? entry.option.displayName : entry.modelDisplayName
                }
                return OpenCodeMenuOption(
                    option: entry.option,
                    displayName: displayName,
                    variantDisplayName: variantDisplayName,
                    isBaseOption: entry.variant == nil
                )
            }
            return OpenCodeMenuGroup(
                providerID: representative.providerID,
                providerDisplayName: representative.providerDisplayName,
                baseModelID: representative.baseModelID,
                displayName: representative.groupDisplayName,
                modelDisplayName: representative.modelDisplayName,
                options: menuOptions,
                rendersAsSubmenu: rendersAsSubmenu,
                sortIndex: representative.index
            )
        }.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let groupedProviderGroups = Dictionary(grouping: groups, by: { $0.providerID?.lowercased() ?? "_root" })
        let providerGroups = groupedProviderGroups.values.compactMap { groups -> OpenCodeProviderMenuGroup? in
            guard let representative = groups.min(by: { $0.sortIndex < $1.sortIndex }) else { return nil }
            let sortedGroups = groups.sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex {
                    return lhs.sortIndex < rhs.sortIndex
                }
                return lhs.modelDisplayName.localizedCaseInsensitiveCompare(rhs.modelDisplayName) == .orderedAscending
            }
            return OpenCodeProviderMenuGroup(
                providerID: representative.providerID,
                displayName: representative.providerDisplayName ?? "OpenCode",
                groups: sortedGroups,
                rendersAsSubmenu: representative.providerID != nil,
                sortIndex: representative.sortIndex
            )
        }.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return OpenCodeMenu(providerGroups: providerGroups, groups: groups)
    }

    static func codexMenu(for options: [AgentModelOption]) -> CodexMenu {
        let defaultOption = options.first { $0.isPlaceholderDefault }
        let modelOptions = options.filter { !$0.isPlaceholderDefault }
        guard !modelOptions.isEmpty else {
            return CodexMenu(defaultOption: defaultOption, groups: [])
        }

        struct Entry {
            let option: AgentModelOption
            let baseModelID: String
            let groupDisplayName: String
            let reasoningEffort: CodexReasoningEffort?
        }

        func effortFromDisplayName(_ displayName: String) -> CodexReasoningEffort? {
            guard let suffix = displayName.split(separator: " ").last else { return nil }
            return CodexReasoningEffort.parse(String(suffix))
        }

        func stripEffortSuffix(_ label: String) -> String {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }
            var tokens = trimmed.split(separator: " ").map(String.init)
            guard let last = tokens.last,
                  CodexReasoningEffort.parse(last) != nil
            else {
                return trimmed
            }
            tokens.removeLast()
            return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func humanizeCodexBaseModel(_ raw: String) -> String {
            let normalized = raw
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "/", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return raw }

            var output = normalized
                .split(separator: " ")
                .map { token -> String in
                    let lower = token.lowercased()
                    if lower == "gpt" { return "GPT" }
                    if lower == "codex" { return "Codex" }
                    if lower == "xhigh" { return "XHigh" }
                    if lower.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil {
                        return String(token)
                    }
                    return lower.capitalized
                }
                .joined(separator: " ")
            output = output.replacingOccurrences(
                of: "(?i)\\bGPT ([0-9]+(?:\\.[0-9]+)*)\\b",
                with: "GPT-$1",
                options: .regularExpression
            )
            return output
        }

        func rank(for effort: CodexReasoningEffort?) -> Int {
            guard let effort else { return -1 }
            return CodexReasoningEffort.displayOrder.firstIndex(of: effort) ?? Int.max
        }

        func displayNameForBaseModel(
            baseModelID: String,
            fallbackDisplayName: String
        ) -> String {
            let specifier = CodexModelSpecifier(raw: baseModelID)
            guard let serviceTier = specifier.serviceTier,
                  let baseModel = specifier.baseModel
            else {
                let fallbackBaseDisplayName = stripEffortSuffix(fallbackDisplayName)
                return AIModel.codexBaseDisplayName(
                    for: baseModelID,
                    fallbackDisplayName: fallbackBaseDisplayName
                )
            }

            let fallbackBaseDisplayName = stripEffortSuffix(fallbackDisplayName)
            let loweredFallback = fallbackBaseDisplayName.lowercased()
            if loweredFallback.hasSuffix(" \(serviceTier)") || loweredFallback.hasSuffix("-\(serviceTier)") {
                return fallbackBaseDisplayName
            }

            let baseDisplayName = AIModel.codexBaseDisplayName(
                for: baseModel,
                fallbackDisplayName: fallbackBaseDisplayName
            )
            if serviceTier == CodexServiceTierVariantCatalog.fastServiceTier {
                return "\(baseDisplayName) Fast"
            }
            return "\(baseDisplayName) \(serviceTier.capitalized)"
        }

        let entries = modelOptions.map { option -> Entry in
            let specifier = CodexModelSpecifier(raw: option.rawValue)
            let normalizedRaw = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseModelID = CodexServiceTierVariantCatalog.serviceTierAwareBaseID(for: normalizedRaw)
            let reasoningEffort = specifier.reasoningEffort ?? effortFromDisplayName(option.displayName)
            let groupDisplayName = displayNameForBaseModel(
                baseModelID: baseModelID,
                fallbackDisplayName: option.displayName
            )
            return Entry(
                option: option,
                baseModelID: baseModelID,
                groupDisplayName: groupDisplayName,
                reasoningEffort: reasoningEffort
            )
        }

        let groupedEntries = Dictionary(grouping: entries, by: { $0.baseModelID.lowercased() })

        let groups = groupedEntries.compactMap { _, groupEntries -> CodexMenuGroup? in
            guard let representative = groupEntries.first else { return nil }
            let sortedOptions = groupEntries.sorted { lhs, rhs in
                let leftRank = rank(for: lhs.reasoningEffort)
                let rightRank = rank(for: rhs.reasoningEffort)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                if lhs.option.isProviderDefault != rhs.option.isProviderDefault {
                    return lhs.option.isProviderDefault && !rhs.option.isProviderDefault
                }
                let displayComparison = ModelPickerStringOrdering.compare(
                    lhs.option.displayName,
                    rhs.option.displayName,
                    caseInsensitiveASCII: true
                )
                if displayComparison != .orderedSame {
                    return displayComparison == .orderedAscending
                }
                return ModelPickerStringOrdering.precedes(lhs.option.rawValue, rhs.option.rawValue)
            }

            return CodexMenuGroup(
                baseModelID: representative.baseModelID,
                displayName: representative.groupDisplayName,
                options: sortedOptions.map(\.option)
            )
        }.sorted { lhs, rhs in
            if AIModel.codexBaseModelPrecedes(lhs.baseModelID, rhs.baseModelID) { return true }
            if AIModel.codexBaseModelPrecedes(rhs.baseModelID, lhs.baseModelID) { return false }
            let displayComparison = ModelPickerStringOrdering.compare(
                lhs.displayName,
                rhs.displayName,
                caseInsensitiveASCII: true
            )
            if displayComparison != .orderedSame {
                return displayComparison == .orderedAscending
            }
            return ModelPickerStringOrdering.precedes(lhs.baseModelID, rhs.baseModelID)
        }

        return CodexMenu(defaultOption: defaultOption, groups: groups)
    }

    static func claudeMenu(for options: [AgentModelOption], agentKind: AgentProviderKind? = nil) -> ClaudeMenu {
        let defaultOption = options.first { $0.isPlaceholderDefault }
        let modelOptions = options.filter { !$0.isPlaceholderDefault }
        guard !modelOptions.isEmpty else {
            return ClaudeMenu(defaultOption: defaultOption, groups: [])
        }

        struct Entry {
            let option: AgentModelOption
            let baseModelRaw: String
            let groupDisplayName: String
            let effort: ClaudeCodeEffortLevel
            let index: Int
        }

        var entries: [Entry] = []
        for (index, option) in modelOptions.enumerated() {
            let specifier = ClaudeModelSpecifier(raw: option.rawValue)
            guard let baseModel = specifier.baseModel else { continue }
            if let effort = specifier.effortLevel {
                guard claudeEffort(effort, isSupportedForBaseModelRaw: baseModel, agentKind: agentKind) else { continue }
                entries.append(Entry(
                    option: option,
                    baseModelRaw: baseModel,
                    groupDisplayName: strippedClaudeEffortSuffix(from: option.displayName),
                    effort: effort,
                    index: index
                ))
            } else {
                let supportedEfforts = supportedClaudeEfforts(forBaseModelRaw: baseModel, agentKind: agentKind)
                guard !supportedEfforts.isEmpty else {
                    entries.append(Entry(
                        option: option,
                        baseModelRaw: baseModel,
                        groupDisplayName: option.displayName,
                        effort: .high,
                        index: index
                    ))
                    continue
                }
                for effort in supportedEfforts {
                    let synthesizedOption = AgentModelOption(
                        rawValue: ClaudeModelSpecifier.encodedRaw(baseModelRaw: baseModel, effort: effort),
                        displayName: "\(option.displayName) \(effort.displayName)",
                        description: option.description,
                        isPlaceholderDefault: false,
                        isProviderDefault: false
                    )
                    entries.append(Entry(
                        option: synthesizedOption,
                        baseModelRaw: baseModel,
                        groupDisplayName: option.displayName,
                        effort: effort,
                        index: index
                    ))
                }
            }
        }

        let groupedEntries = Dictionary(grouping: entries, by: { $0.baseModelRaw.lowercased() })
        let groups = groupedEntries.compactMap { _, groupEntries -> ClaudeMenuGroup? in
            guard let representative = groupEntries.min(by: { $0.index < $1.index }) else { return nil }
            var seenRawValues: Set<String> = []
            let sortedOptions = groupEntries
                .sorted { lhs, rhs in
                    let leftRank = claudeEffortSortRank(lhs.effort)
                    let rightRank = claudeEffortSortRank(rhs.effort)
                    if leftRank != rightRank {
                        return leftRank < rightRank
                    }
                    return lhs.index < rhs.index
                }
                .compactMap { entry -> AgentModelOption? in
                    let key = entry.option.rawValue.lowercased()
                    guard seenRawValues.insert(key).inserted else { return nil }
                    return entry.option
                }

            return ClaudeMenuGroup(
                baseModelRaw: representative.baseModelRaw,
                displayName: representative.groupDisplayName,
                options: sortedOptions,
                rendersAsSubmenu: shouldRenderClaudeGroupAsSubmenu(sortedOptions)
            )
        }.sorted { lhs, rhs in
            let leftIndex = entries.first { $0.baseModelRaw.caseInsensitiveCompare(lhs.baseModelRaw) == .orderedSame }?.index ?? Int.max
            let rightIndex = entries.first { $0.baseModelRaw.caseInsensitiveCompare(rhs.baseModelRaw) == .orderedSame }?.index ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return ClaudeMenu(defaultOption: defaultOption, groups: groups)
    }

    private static func shouldRenderClaudeGroupAsSubmenu(_ options: [AgentModelOption]) -> Bool {
        guard options.count == 1,
              let only = options.first else { return true }
        return ClaudeModelSpecifier(raw: only.rawValue).effortLevel != nil
    }

    static func modelOptionIsSelected(
        optionRaw: String,
        selectedRaw: String,
        agentKind: AgentProviderKind,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let option = optionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selectedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !option.isEmpty, !selected.isEmpty else { return false }
        if option.caseInsensitiveCompare(selected) == .orderedSame {
            return true
        }

        if agentKind == .codexExec {
            let optionSlug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: option)
            let selectedSlug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: selected)
            guard optionSlug.caseInsensitiveCompare(selectedSlug) == .orderedSame else { return false }
            let optionEffort = CodexModelSpecifier(raw: option).reasoningEffort
            let selectedEffort = CodexModelSpecifier(raw: selected).reasoningEffort
                ?? CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: selected, defaults: defaults)
            if let optionEffort {
                return optionEffort == selectedEffort
            }
            return selectedEffort == nil
        }

        guard agentKind.usesClaudeTooling else { return false }

        let optionSpecifier = ClaudeModelSpecifier(raw: option)
        let selectedSpecifier = ClaudeModelSpecifier(raw: selected)
        guard let selectedBase = selectedSpecifier.baseModel else {
            return optionSpecifier.baseModel == nil
                && selectedSpecifier.effortLevel == optionSpecifier.effortLevel
        }
        guard let optionBase = optionSpecifier.baseModel else { return false }
        let selectedBaseKey = claudeBaseModelKey(selectedBase, agentKind: agentKind)
        let optionBaseKey = claudeBaseModelKey(optionBase, agentKind: agentKind)
        guard selectedBaseKey.caseInsensitiveCompare(optionBaseKey) == .orderedSame else { return false }
        if optionSpecifier.effortLevel == nil,
           selectedSpecifier.effortLevel != nil
        {
            return true
        }
        guard selectedSpecifier.effortLevel == nil,
              let optionEffort = optionSpecifier.effortLevel
        else {
            return false
        }
        return optionEffort == ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: selected,
            agentKind: agentKind,
            defaults: defaults
        )
    }

    @discardableResult
    static func updateLastUsedEffortIfEncoded(
        agentKind: AgentProviderKind,
        rawModel: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if agentKind.usesClaudeTooling {
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            guard let effort = specifier.effortLevel,
                  claudeEffort(effort, isSupportedForBaseModelRaw: specifier.baseModel, agentKind: agentKind)
            else {
                return false
            }
            ClaudeAgentToolPreferences.setEffortLevel(
                effort,
                forModelRaw: rawModel,
                agentKind: agentKind,
                defaults: defaults
            )
            return true
        }

        if agentKind == .codexExec {
            let specifier = CodexModelSpecifier(raw: rawModel)
            guard let effort = specifier.reasoningEffort else { return false }
            CodexAgentToolPreferences.setLastUsedReasoningEffort(
                effort,
                forModelRaw: rawModel,
                defaults: defaults
            )
            return true
        }

        return false
    }

    @discardableResult
    static func updateClaudeLastUsedEffortIfEncoded(
        agentKind: AgentProviderKind,
        rawModel: String,
        defaults: UserDefaults = .standard
    ) -> ClaudeCodeEffortLevel? {
        guard agentKind.usesClaudeTooling else { return nil }
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let effort = specifier.effortLevel,
              claudeEffort(effort, isSupportedForBaseModelRaw: specifier.baseModel, agentKind: agentKind),
              updateLastUsedEffortIfEncoded(agentKind: agentKind, rawModel: rawModel, defaults: defaults)
        else {
            return nil
        }
        return effort
    }

    private static func expandedClaudeOptions(from baseOptions: [AgentModelOption], agentKind: AgentProviderKind) -> [AgentModelOption] {
        baseOptions.flatMap { option -> [AgentModelOption] in
            if option.isPlaceholderDefault {
                return [option]
            }
            let efforts = supportedClaudeEfforts(forBaseModelRaw: option.rawValue, agentKind: agentKind)
            guard !efforts.isEmpty else { return [option] }
            return efforts.map { effort in
                AgentModelOption(
                    rawValue: ClaudeModelSpecifier.encodedRaw(baseModelRaw: option.rawValue, effort: effort),
                    displayName: "\(option.displayName) \(effort.displayName)",
                    description: option.description,
                    isPlaceholderDefault: false,
                    isProviderDefault: false
                )
            }
        }
    }

    private static let claudeMenuEffortOrder: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .max, .xhigh]

    private static func supportedClaudeEfforts(forBaseModelRaw baseModelRaw: String, agentKind: AgentProviderKind?) -> [ClaudeCodeEffortLevel] {
        claudeMenuEffortOrder.filter {
            claudeEffort($0, isSupportedForBaseModelRaw: baseModelRaw, agentKind: agentKind)
        }
    }

    /// Returns the effort levels that should appear in the Claude effort
    /// picker for a given model selection. The `modelRaw` may be an encoded
    /// `base:effort` string or a bare base model; the effort suffix is
    /// stripped before evaluating support.
    ///
    /// SEARCH-HELPER: Claude effort picker, XHigh filter, Opus eligibility
    static func supportedClaudeEfforts(
        forSelectedModelRaw modelRaw: String,
        agentKind: AgentProviderKind
    ) -> [ClaudeCodeEffortLevel] {
        let baseModelRaw = ClaudeModelSpecifier(raw: modelRaw).baseModel
        return claudeMenuEffortOrder.filter {
            claudeEffort($0, isSupportedForBaseModelRaw: baseModelRaw, agentKind: agentKind)
        }
    }

    private static func claudeEffort(
        _ effort: ClaudeCodeEffortLevel,
        isSupportedForBaseModelRaw baseModelRaw: String?,
        agentKind: AgentProviderKind?
    ) -> Bool {
        ClaudeCompatibleModelCatalogAdapter.claudeEffort(
            effort,
            isSupportedForBaseModelRaw: baseModelRaw,
            agentKind: agentKind
        )
    }

    private static func strippedClaudeEffortSuffix(from label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens = trimmed.split(separator: " ").map(String.init)
        guard let last = tokens.last,
              ClaudeCodeEffortLevel.parse(last) != nil
        else {
            return trimmed
        }
        tokens.removeLast()
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func claudeEffortSortRank(_ effort: ClaudeCodeEffortLevel) -> Int {
        claudeMenuEffortOrder.firstIndex(of: effort) ?? Int.max
    }

    private static func claudeBaseModelKey(_ rawModel: String, agentKind: AgentProviderKind) -> String {
        if let normalized = ClaudeCompatibleModelCatalogAdapter.canonicalCompatibleBackendModelRaw(rawModel, for: agentKind) {
            return ClaudeModelSpecifier(raw: normalized).baseModel ?? normalized
        }
        return rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func codexBaseDisplayName(
        forModelSlug modelSlug: String,
        rawModel: String,
        availability: AvailabilityContext,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]?
    ) -> String {
        let options = options(for: .codexExec, availability: availability, codexDynamicModels: codexDynamicModels)
        if let option = options.first(where: {
            CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: $0.rawValue)
                .caseInsensitiveCompare(modelSlug) == .orderedSame
        }) {
            return AIModel.stripCodexReasoningSuffix(from: option.displayName)
        }
        return AIModel.codexBaseDisplayName(for: modelSlug, fallbackDisplayName: rawModel)
    }

    private static func codexEffort(
        _ effort: CodexReasoningEffort,
        isSupportedForModelRaw modelRaw: String,
        availability: AvailabilityContext,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]?
    ) -> Bool {
        let selectedSlug = CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: modelRaw)
        let matchingOptions = options(for: .codexExec, availability: availability, codexDynamicModels: codexDynamicModels)
            .filter {
                CodexAgentToolPreferences.reasoningEffortPreferenceSlug(forModelRaw: $0.rawValue)
                    .caseInsensitiveCompare(selectedSlug) == .orderedSame
            }
        if !matchingOptions.isEmpty {
            let supportedEfforts = Set(matchingOptions.flatMap { option -> [CodexReasoningEffort] in
                var efforts = option.supportedReasoningEfforts
                if let defaultReasoningEffort = option.defaultReasoningEffort {
                    efforts.append(defaultReasoningEffort)
                }
                if let optionEffort = CodexModelSpecifier(raw: option.rawValue).reasoningEffort {
                    efforts.append(optionEffort)
                }
                return efforts
            })
            return supportedEfforts.contains(effort)
        }
        return CodexModelSpecifier(raw: modelRaw).baseModel != nil
    }

    private enum OpenCodeVariant: String {
        case none
        case minimal
        case low
        case medium
        case high
        case max
        case xhigh

        init?(rawToken: String) {
            let normalized = rawToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { return nil }
            switch normalized {
            case "none":
                self = .none
            case "minimal", "min":
                self = .minimal
            case "low":
                self = .low
            case "medium", "med":
                self = .medium
            case "high":
                self = .high
            case "max", "maximum":
                self = .max
            case "xhigh", "x-high", "x high":
                self = .xhigh
            default:
                return nil
            }
        }

        var displayName: String {
            switch self {
            case .none: "None"
            case .minimal: "Minimal"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .max: "Max"
            case .xhigh: "XHigh"
            }
        }
    }

    private static func normalizedOpenCodeVariant(
        option: AgentModelOption
    ) -> (
        providerID: String?,
        providerDisplayName: String?,
        baseModelID: String,
        baseDisplayName: String,
        modelDisplayName: String,
        variant: OpenCodeVariant?
    ) {
        let rawValue = option.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayAnalysis = stripOpenCodeParenthesizedVariant(from: displayName)
        let rawSlashAnalysis = stripOpenCodeSlashVariant(from: rawValue)
        let rawParenAnalysis = stripOpenCodeParenthesizedVariant(from: rawValue)

        let rawVariant = rawSlashAnalysis?.variant ?? rawParenAnalysis?.variant
        let trailingDisplayAnalysis = rawVariant.flatMap { stripOpenCodeTrailingVariantWord(from: displayName, expected: $0) }
        let variant = displayAnalysis?.variant ?? rawVariant ?? trailingDisplayAnalysis?.variant
        let rawBase = normalizedOpenCodeBaseLabel(
            rawSlashAnalysis?.base ?? rawParenAnalysis?.base ?? rawValue,
            fallback: rawValue
        )
        let baseDisplayName = normalizedOpenCodeBaseLabel(
            displayAnalysis?.base ?? trailingDisplayAnalysis?.base ?? displayName,
            fallback: rawBase
        )
        let rawProviderComponents = openCodeRawProviderComponents(from: rawBase)
        let displayProviderComponents = openCodeDisplayProviderComponents(from: baseDisplayName)
        let providerID = rawProviderComponents.map { normalizedOpenCodeGroupingKey($0.providerID) }
            ?? displayProviderComponents.map { normalizedOpenCodeGroupingKey($0.providerDisplayName) }
        let providerDisplayName = displayProviderComponents?.providerDisplayName
            ?? rawProviderComponents.map { humanizedOpenCodePathComponent($0.providerID) }
        let modelDisplayName = displayProviderComponents?.modelDisplayName ?? baseDisplayName
        let baseModelID = normalizedOpenCodeGroupingKey(rawBase)

        return (providerID, providerDisplayName, baseModelID, baseDisplayName, modelDisplayName, variant)
    }

    private static func openCodeRawProviderComponents(
        from value: String
    ) -> (providerID: String, modelID: String)? {
        let parts = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let providerIndex: Int
        if parts[0].caseInsensitiveCompare("opencode") == .orderedSame {
            guard parts.count >= 3 else { return nil }
            providerIndex = 1
        } else {
            providerIndex = 0
        }

        let modelIndex = providerIndex + 1
        guard modelIndex < parts.count else { return nil }
        let providerID = parts[providerIndex]
        let modelID = parts[modelIndex...].joined(separator: "/")
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return (providerID, modelID)
    }

    private static func openCodeDisplayProviderComponents(
        from value: String
    ) -> (providerDisplayName: String, modelDisplayName: String)? {
        let parts = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let providerIndex: Int
        if parts[0].caseInsensitiveCompare("opencode") == .orderedSame {
            guard parts.count >= 3 else { return nil }
            providerIndex = 1
        } else {
            providerIndex = 0
        }

        let modelIndex = providerIndex + 1
        guard modelIndex < parts.count else { return nil }
        let providerDisplayName = strippedOpenCodeProviderPrefix(from: parts[providerIndex])
        let modelDisplayName = parts[modelIndex...]
            .joined(separator: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerDisplayName.isEmpty, !modelDisplayName.isEmpty else { return nil }
        return (providerDisplayName, modelDisplayName)
    }

    private static func strippedOpenCodeProviderPrefix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = ["opencode ", "open code "]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func humanizedOpenCodePathComponent(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return value }
        return normalized
            .split(separator: " ")
            .map { token -> String in
                let lower = token.lowercased()
                switch lower {
                case "ai": return "AI"
                case "api": return "API"
                case "gpt": return "GPT"
                case "openai": return "OpenAI"
                case "xai": return "xAI"
                default: return lower.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func stripOpenCodeParenthesizedVariant(
        from value: String
    ) -> (base: String, variant: OpenCodeVariant)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let openIndex = trimmed.lastIndex(of: "(") else { return nil }
        let suffixStart = trimmed.index(after: openIndex)
        let suffix = String(trimmed[suffixStart ..< trimmed.index(before: trimmed.endIndex)])
        guard let variant = OpenCodeVariant(rawToken: suffix) else { return nil }
        let base = String(trimmed[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return (base, variant)
    }

    private static func stripOpenCodeSlashVariant(
        from value: String
    ) -> (base: String, variant: OpenCodeVariant)? {
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        guard let slashIndex = trimmed.lastIndex(of: "/") else { return nil }
        let suffix = String(trimmed[trimmed.index(after: slashIndex)...])
        guard let variant = OpenCodeVariant(rawToken: suffix) else { return nil }
        let base = String(trimmed[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return (base, variant)
    }

    private static func stripOpenCodeTrailingVariantWord(
        from value: String,
        expected: OpenCodeVariant
    ) -> (base: String, variant: OpenCodeVariant)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = trimmed.split(separator: " ").map(String.init)
        guard let last = parts.last,
              let variant = OpenCodeVariant(rawToken: last),
              variant == expected else { return nil }
        parts.removeLast()
        let base = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return (base, variant)
    }

    private static func normalizedOpenCodeBaseLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOpenCodeGroupingKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openCodeVariantSortRank(_ variant: OpenCodeVariant?) -> Int {
        guard let variant else { return -1 }
        switch variant {
        case .none: return 0
        case .minimal: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .max: return 5
        case .xhigh: return 6
        }
    }

    private static func resolvedACPDiscoveredModels(
        for agentKind: AgentProviderKind
    ) -> ACPDiscoveredSessionModels? {
        guard let providerID = agentKind.acpProviderID,
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID),
              !snapshot.options.isEmpty
        else {
            return nil
        }
        return snapshot
    }

    private static func normalizedAgentKind(_ rawValue: String?) -> AgentProviderKind? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AgentProviderKind(rawValue: trimmed)
    }

    private static func normalizedRawModel(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func backendIsAvailable(
        _ id: ClaudeCodeCompatibleBackendID,
        store: ClaudeCodeCompatibleBackendStore = .shared
    ) -> Bool {
        let config = store.config(for: id)
        return store.isConfigured(id) && config.isEnabled && config.isValid
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

    private static func isCompatibleBackendAgent(_ agentKind: AgentProviderKind) -> Bool {
        compatibleBackendID(for: agentKind) != nil
    }

    private static func compatibleBackendConfig(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendConfig? {
        compatibleBackendID(for: agentKind).map { ClaudeCodeCompatibleBackendStore.shared.config(for: $0).normalized }
    }

    private static func compatibleBackendModelBehavior(for agentKind: AgentProviderKind) -> ClaudeCodeCompatibleBackendConfig.ModelBehavior? {
        compatibleBackendConfig(for: agentKind)?.modelBehavior
    }

    private static func noModelRawValue(for id: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCompatibleProviderRuntimeBridge.noModelRawValue(for: id)
    }

    private static func defaultCompatibleBackendModelRaw(for agentKind: AgentProviderKind) -> String {
        ClaudeCompatibleModelCatalogAdapter.defaultModelRaw(for: agentKind) ?? AgentModel.defaultModel.rawValue
    }

    private static func compatibleBackendOptions(for agentKind: AgentProviderKind) -> [AgentModelOption] {
        guard let id = compatibleBackendID(for: agentKind),
              let config = compatibleBackendConfig(for: agentKind) else { return [] }
        switch config.modelBehavior {
        case .noModel:
            return [AgentModelOption(
                rawValue: noModelRawValue(for: id),
                displayName: noModelDisplayName(for: id, config: config),
                description: "No model flag. RepoPrompt does not pass --model or Claude effort settings for this backend.",
                isPlaceholderDefault: false,
                isProviderDefault: true
            )]
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            return [
                compatibleSlotOption(slotRaw: AgentModel.claudeHaiku.rawValue, backendModelID: normalized.haiku, slotName: "Haiku"),
                compatibleSlotOption(slotRaw: AgentModel.claudeSonnet.rawValue, backendModelID: normalized.sonnet, slotName: "Sonnet", isProviderDefault: true),
                compatibleSlotOption(slotRaw: AgentModel.claudeOpus.rawValue, backendModelID: normalized.opus, slotName: "Opus")
            ]
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

    private static func compatibleSlotOption(
        slotRaw: String,
        backendModelID: String,
        slotName: String,
        isProviderDefault: Bool = false
    ) -> AgentModelOption {
        AgentModelOption(
            rawValue: slotRaw,
            displayName: displayName(forBackendModelID: backendModelID),
            description: "Routes Claude Code's \(slotName) model slot to \(backendModelID).",
            isPlaceholderDefault: false,
            isProviderDefault: isProviderDefault
        )
    }

    private static func displayName(forBackendModelID modelID: String) -> String {
        if let model = AgentModel(rawValue: modelID) {
            return model.displayName
        }
        return modelID
    }

    private static func compatibleBackendDisplayName(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        guard let id = compatibleBackendID(for: agentKind),
              let config = compatibleBackendConfig(for: agentKind) else { return nil }
        switch config.modelBehavior {
        case .noModel:
            let specifier = ClaudeModelSpecifier(raw: rawModel)
            guard specifier.effortLevel == nil else { return nil }
            let base = specifier.baseModel ?? noModelRawValue(for: id)
            return base.caseInsensitiveCompare(noModelRawValue(for: id)) == .orderedSame
                ? noModelDisplayName(for: id, config: config)
                : nil
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            guard let slot = canonicalCompatibleBackendBaseRaw(rawModel, for: agentKind) else { return nil }
            switch slot {
            case AgentModel.claudeHaiku.rawValue:
                return displayName(forBackendModelID: normalized.haiku)
            case AgentModel.claudeSonnet.rawValue:
                return displayName(forBackendModelID: normalized.sonnet)
            case AgentModel.claudeOpus.rawValue:
                return displayName(forBackendModelID: normalized.opus)
            default:
                return nil
            }
        }
    }

    private static func compatibleBackendDescription(
        forRequestedModelRaw rawModel: String?,
        agentKind: AgentProviderKind
    ) -> String? {
        guard let config = compatibleBackendConfig(for: agentKind) else { return nil }
        switch config.modelBehavior {
        case .noModel:
            return "No model flag. RepoPrompt does not pass --model or Claude effort settings for this backend."
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            guard let slot = canonicalCompatibleBackendBaseRaw(rawModel, for: agentKind) else { return nil }
            switch slot {
            case AgentModel.claudeHaiku.rawValue:
                return "Routes Claude Code's Haiku model slot to \(normalized.haiku)."
            case AgentModel.claudeSonnet.rawValue:
                return "Routes Claude Code's Sonnet model slot to \(normalized.sonnet)."
            case AgentModel.claudeOpus.rawValue:
                return "Routes Claude Code's Opus model slot to \(normalized.opus)."
            default:
                return nil
            }
        }
    }

    private static func canonicalCompatibleBackendBaseRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
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

    private static func canonicalCompatibleBackendModelRaw(_ rawModel: String?, for agentKind: AgentProviderKind) -> String? {
        let specifier = ClaudeModelSpecifier(raw: rawModel)
        guard let base = canonicalCompatibleBackendBaseRaw(specifier.baseModel, for: agentKind) else { return rawModel }
        if let effort = specifier.effortLevel {
            return ClaudeModelSpecifier.encodedRaw(baseModelRaw: base, effort: effort)
        }
        return base
    }

    private static func isValidCompatibleBackendModel(
        _ rawModel: String,
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext
    ) -> Bool {
        guard isAgentAvailable(agentKind, availability: availability) else { return false }
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

    private static func isAvailable(
        _ model: AgentModel,
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext
    ) -> Bool {
        switch agentKind {
        case .claudeCodeGLM:
            availability.zaiConfigured
        case .kimiCode:
            availability.kimiConfigured
        case .customClaudeCompatible:
            availability.customClaudeCompatibleConfigured
        case .claudeCode, .codexExec, .openCode, .cursor:
            true
        }
    }

    private static func canonicalModelRaw(_ rawModel: String, for agentKind: AgentProviderKind) -> String {
        guard agentKind == .cursor else { return rawModel }
        if rawModel.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(AgentModel.cursorAuto.rawValue) == .orderedSame {
            return AgentModel.cursorAuto.rawValue
        }
        guard let discoveredOption = resolvedACPDiscoveredModels(for: .cursor)?.option(matching: rawModel),
              isCursorAutoOption(discoveredOption)
        else {
            return rawModel
        }
        return AgentModel.cursorAuto.rawValue
    }

    private static func canonicalClaudeGLMModelRaw(_ rawModel: String?) -> String? {
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

    private static func isCursorAutoOption(_ option: AgentModelOption) -> Bool {
        let normalizedRaw = normalizedCursorModelAlias(option.rawValue)
        let normalizedDisplayName = normalizedCursorModelAlias(option.displayName)
        return normalizedRaw == AgentModel.cursorAuto.rawValue
            || normalizedDisplayName == AgentModel.cursorAuto.rawValue
    }

    private static func isCursorComposer2Option(_ option: AgentModelOption) -> Bool {
        let normalizedRaw = normalizedCursorModelAlias(option.rawValue)
        let normalizedDisplayName = normalizedCursorModelAlias(option.displayName)
        return normalizedRaw == AgentModel.cursorComposer2.rawValue
            || normalizedDisplayName == AgentModel.cursorComposer2.rawValue
    }

    private static func cursorSnapshotContains(
        rawModel: String,
        snapshot: ACPDiscoveredSessionModels
    ) -> Bool {
        if snapshot.contains(rawModel: rawModel) {
            return true
        }
        let normalized = normalizedCursorModelAlias(rawModel)
        guard !normalized.isEmpty else { return false }
        return snapshot.options.contains { option in
            normalizedCursorModelAlias(option.rawValue) == normalized
                || normalizedCursorModelAlias(option.displayName) == normalized
        }
    }

    private static func normalizedCursorModelAlias(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: Substring = if let bracketIndex = trimmed.firstIndex(of: "[") {
            trimmed[..<bracketIndex]
        } else {
            trimmed[...]
        }
        return String(base).replacingOccurrences(of: " ", with: "-")
    }

    private static func staticOption(_ model: AgentModel, for agentKind: AgentProviderKind) -> AgentModelOption {
        let displayName: String
        let description: String?
        if let compatibleDisplayName = ClaudeCompatibleModelCatalogAdapter.compatibleBackendDisplayName(forRequestedModelRaw: model.rawValue, agentKind: agentKind) {
            displayName = compatibleDisplayName
            description = ClaudeCompatibleModelCatalogAdapter.compatibleBackendDescription(forRequestedModelRaw: model.rawValue, agentKind: agentKind)
        } else {
            displayName = model.displayName
            description = model.description
        }
        return AgentModelOption(
            rawValue: model.rawValue,
            displayName: displayName,
            description: description,
            isPlaceholderDefault: model == .defaultModel,
            isProviderDefault: false
        )
    }

    // MARK: - MCP Exact Lookup Helpers

    /// Case-insensitive exact lookup of an agent kind by its raw id string.
    /// Returns `nil` for unknown or empty strings.
    static func selectableAgent(
        matching raw: String,
        availability: AvailabilityContext = .current
    ) -> AgentProviderKind? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let match = AgentProviderKind.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        guard isAgentAvailable(match, availability: availability) else { return nil }
        return match
    }

    /// Case-insensitive exact lookup of a model option by its raw id string
    /// within the options available for a specific agent kind.
    static func modelOption(
        matching raw: String,
        for agentKind: AgentProviderKind,
        availability: AvailabilityContext = .current,
        codexDynamicModels: [CodexAppServerClient.RemoteModel]? = nil
    ) -> AgentModelOption? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return options(for: agentKind, availability: availability, codexDynamicModels: codexDynamicModels)
            .first { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Human-readable label for an exact agent+model combination,
    /// suitable for MCP `start_targets` display.
    static func startTargetLabel(
        agentKind: AgentProviderKind,
        option: AgentModelOption
    ) -> String {
        if option.isPlaceholderDefault {
            return "\(agentKind.displayName) Default"
        }
        return "\(agentKind.displayName) \(option.displayName)"
    }

    // MARK: - Discovery DTOs

    /// A stable start target within a model entry — represents one exact runnable combination.
    struct DiscoveryStartTarget {
        let selectionID: AgentModelSelectionID
        let modelRaw: String
        let name: String
        let description: String?
        let reasoningEffort: CodexReasoningEffort?
        let available: Bool
        let isDefault: Bool
        let contextWindowTokens: Int?
    }

    /// A model entry for MCP discovery, optionally containing multiple start targets.
    struct DiscoveryModel {
        let id: String
        let name: String
        let description: String?
        let available: Bool
        let tags: [AgentModelDiscoveryTag]
        let contextWindowTokens: Int?
        let supportedReasoningEfforts: [CodexReasoningEffort]
        let defaultReasoningEffort: CodexReasoningEffort?
        let startTargets: [DiscoveryStartTarget]

        /// The primary model_id for this model — the default target's ID, or the only one.
        var modelID: String? {
            let defaultTarget = startTargets.first(where: \.isDefault) ?? startTargets.first
            return defaultTarget?.selectionID.rawValue
        }

        /// Whether to expose the start_targets array (only when multiple exist).
        var hasMultipleTargets: Bool {
            startTargets.count > 1
        }
    }

    /// Default selection metadata for an agent.
    struct DiscoveryDefaults {
        let modelRaw: String?
        let reasoningEffort: CodexReasoningEffort?
        let selectionID: AgentModelSelectionID?
    }

    /// Full agent entry for MCP discovery response.
    struct DiscoveryAgent {
        let agent: AgentProviderKind
        let description: String
        let available: Bool
        let runtime: String
        let capabilities: [String]
        let defaults: DiscoveryDefaults
        let models: [DiscoveryModel]
    }

    // MARK: - Task Labels

    /// Known task label kinds for MCP agent role defaults.
    enum TaskLabelKind: String, CaseIterable {
        case explore
        case engineer
        case pair
        case design
    }

    /// Metadata for a task label.
    struct TaskLabel {
        let kind: TaskLabelKind
        let label: String
        let description: String
    }

    /// Selection candidate for explicit role-default resolution.
    private struct SelectionCandidate {
        let agent: AgentProviderKind
        let modelRaw: String
    }

    /// Resolved task label with display metadata for MCP discovery.
    struct DiscoveryTaskLabel {
        let label: String
        let description: String
        let resolvedSelection: NormalizedAgentSelection
        let resolvedDisplayName: String
    }

    /// Look up a single task label by kind.
    static func taskLabel(for kind: TaskLabelKind) -> TaskLabel? {
        taskLabels.first { $0.kind == kind }
    }

    /// Known task labels that resolve to a preferred agent+model automatically.
    /// Callers can pass these as `model_id` instead of a full compound identifier.
    static let taskLabels: [TaskLabel] = [
        TaskLabel(kind: .explore, label: "explore", description: "Fast exploration and codebase mapping"),
        TaskLabel(kind: .engineer, label: "engineer", description: "Balanced engineering work"),
        TaskLabel(kind: .pair, label: "pair", description: "Interactive pair programming with highest-tier models"),
        TaskLabel(kind: .design, label: "design", description: "Architecture, design discussions, and creative problem solving")
    ]

    /// Explicit candidate chains per role. Order matters: first available wins.
    private static func candidateChain(for kind: TaskLabelKind) -> [SelectionCandidate] {
        switch kind {
        case .explore:
            [
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt55CodexLow.rawValue),
                SelectionCandidate(agent: .claudeCode, modelRaw: ClaudeModelSpecifier.encodedRaw(baseModelRaw: AgentModel.claudeSonnet.rawValue, effort: .high)),
                SelectionCandidate(agent: .claudeCode, modelRaw: AgentModel.claudeHaiku.rawValue),
                SelectionCandidate(agent: .claudeCodeGLM, modelRaw: AgentModel.claudeHaiku.rawValue),
                SelectionCandidate(agent: .kimiCode, modelRaw: AgentModel.kimiCode.rawValue),
                SelectionCandidate(agent: .customClaudeCompatible, modelRaw: defaultCompatibleBackendModelRaw(for: .customClaudeCompatible)),
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt54MiniMedium.rawValue),
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.codexMini.rawValue),
                SelectionCandidate(agent: .cursor, modelRaw: AgentModel.cursorAuto.rawValue)
            ]
        case .engineer:
            [
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt55CodexLow.rawValue),
                SelectionCandidate(agent: .claudeCode, modelRaw: AgentModel.claudeSonnet.rawValue),
                SelectionCandidate(agent: .claudeCodeGLM, modelRaw: AgentModel.claudeSonnet.rawValue),
                SelectionCandidate(agent: .kimiCode, modelRaw: AgentModel.kimiCode.rawValue),
                SelectionCandidate(agent: .customClaudeCompatible, modelRaw: defaultCompatibleBackendModelRaw(for: .customClaudeCompatible)),
                SelectionCandidate(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
            ]
        case .pair:
            [
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt55CodexHigh.rawValue),
                SelectionCandidate(agent: .claudeCode, modelRaw: AgentModel.claudeOpus.rawValue),
                SelectionCandidate(agent: .claudeCodeGLM, modelRaw: AgentModel.claudeOpus.rawValue),
                SelectionCandidate(agent: .kimiCode, modelRaw: AgentModel.kimiCode.rawValue),
                SelectionCandidate(agent: .customClaudeCompatible, modelRaw: defaultCompatibleBackendModelRaw(for: .customClaudeCompatible)),
                SelectionCandidate(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue)
            ]
        case .design:
            [
                SelectionCandidate(agent: .claudeCode, modelRaw: AgentModel.claudeOpus.rawValue),
                SelectionCandidate(agent: .claudeCodeGLM, modelRaw: AgentModel.claudeOpus.rawValue),
                SelectionCandidate(agent: .kimiCode, modelRaw: AgentModel.kimiCode.rawValue),
                SelectionCandidate(agent: .customClaudeCompatible, modelRaw: defaultCompatibleBackendModelRaw(for: .customClaudeCompatible)),
                SelectionCandidate(agent: .cursor, modelRaw: AgentModel.cursorComposer2.rawValue),
                SelectionCandidate(agent: .codexExec, modelRaw: AgentModel.gpt55CodexMedium.rawValue)
            ]
        }
    }

    /// Checks if a candidate agent+model is currently available.
    private static func isCandidateAvailable(
        _ candidate: SelectionCandidate,
        availability: AvailabilityContext
    ) -> Bool {
        guard isAgentAvailable(candidate.agent, availability: availability) else { return false }
        // For non-Codex agents, validate the model is known and available
        if candidate.agent != .codexExec {
            return isValid(rawModel: candidate.modelRaw, for: candidate.agent, availability: availability)
        }
        // For Codex, check exact option match for availability-sensitive defaults
        if modelOption(matching: candidate.modelRaw, for: candidate.agent, availability: availability) != nil {
            return true
        }
        // If no dynamic models loaded yet, allow static fallback
        let allOptions = options(for: candidate.agent, availability: availability)
        let hasDynamicModels = allOptions.contains(where: \.isProviderDefault)
        if !hasDynamicModels {
            return AgentModel(rawValue: candidate.modelRaw)?.isValidFor(candidate.agent) == true
        }
        return false
    }

    /// Resolves a task label to the best available agent+model using explicit candidate chains.
    static func resolveTaskLabel(
        _ label: String,
        availability: AvailabilityContext = .current
    ) -> NormalizedAgentSelection? {
        let lowered = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = taskLabels.first(where: { $0.label == lowered }) else { return nil }
        return resolveTaskLabelKind(entry.kind, availability: availability)
    }

    /// Resolves a task label kind to the best available agent+model.
    static func resolveTaskLabelKind(
        _ kind: TaskLabelKind,
        availability: AvailabilityContext = .current
    ) -> NormalizedAgentSelection? {
        let chain = candidateChain(for: kind)
        for candidate in chain {
            if isCandidateAvailable(candidate, availability: availability) {
                return NormalizedAgentSelection(agent: candidate.agent, modelRaw: candidate.modelRaw)
            }
        }
        return nil
    }

    /// Builds discovery task labels with resolved selections for MCP list_agents output.
    static func discoveryTaskLabels(
        availability: AvailabilityContext = .current
    ) -> [DiscoveryTaskLabel] {
        taskLabels.compactMap { entry in
            guard let resolved = resolveTaskLabelKind(entry.kind, availability: availability) else { return nil }
            let selectionID = AgentModelSelectionID(agentRaw: resolved.agent.rawValue, modelRaw: resolved.modelRaw)
            let name = displayName(for: resolved.modelRaw, agentKind: resolved.agent, availability: availability)
            return DiscoveryTaskLabel(
                label: entry.label,
                description: entry.description,
                resolvedSelection: resolved,
                resolvedDisplayName: "\(resolved.agent.displayName) \(name)"
            )
        }
    }

    // MARK: - Discovery APIs

    /// Builds a comprehensive discovery payload for all agents, suitable for `list_agents`.
    static func discoveryAgents(
        availability: AvailabilityContext = .current
    ) -> [DiscoveryAgent] {
        AgentProviderKind.allCases.map { agent in
            discoveryAgent(agent, availability: availability)
        }
    }

    /// Resolves a selection ID string to an agent + modelRaw pair.
    /// Returns `nil` if the selection ID is malformed or the agent is unknown.
    static func resolveSelectionID(
        _ raw: String,
        availability: AvailabilityContext = .current
    ) -> NormalizedAgentSelection? {
        guard let parsed = AgentModelSelectionID.parse(raw) else { return nil }
        guard let agent = AgentProviderKind(rawValue: parsed.agentRaw) else { return nil }
        // For non-Codex agents, validate the model is known
        if agent != .codexExec {
            guard isValid(rawModel: parsed.modelRaw, for: agent, availability: availability) else {
                return nil
            }
        }
        return NormalizedAgentSelection(agent: agent, modelRaw: parsed.modelRaw)
    }

    // MARK: - Discovery Internals

    private static func discoveryAgent(
        _ agent: AgentProviderKind,
        availability: AvailabilityContext
    ) -> DiscoveryAgent {
        let available = isAgentAvailable(agent, availability: availability)
        let agentOptions = options(for: agent, availability: availability)
        let defaultRaw = available ? defaultModelRaw(for: agent, availability: availability) : nil

        let models: [DiscoveryModel] = if agent == .codexExec {
            codexDiscoveryModels(
                from: agentOptions,
                agent: agent,
                defaultModelRaw: defaultRaw ?? ""
            )
        } else if agent.usesClaudeTooling {
            claudeDiscoveryModels(
                from: agentOptions,
                agent: agent,
                defaultModelRaw: defaultRaw ?? ""
            )
        } else {
            agentOptions.map { option in
                discoveryModel(option, agent: agent, defaultModelRaw: defaultRaw ?? "")
            }
        }

        // Only emit default selection_id for available agents
        let defaultSelectionID: AgentModelSelectionID? = {
            guard available, let defaultRaw, !defaultRaw.isEmpty else { return nil }
            return AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: defaultRaw)
        }()

        return DiscoveryAgent(
            agent: agent,
            description: agent.agentDescription,
            available: available,
            runtime: agent.runtimeKind,
            capabilities: discoveryCapabilities(for: agent),
            defaults: DiscoveryDefaults(
                modelRaw: defaultRaw,
                reasoningEffort: nil,
                selectionID: defaultSelectionID
            ),
            models: models
        )
    }

    /// Builds Codex discovery models using the existing family-collapsing logic
    /// from `codexMenu(for:)`, so MCP discovery stays in sync with the UI grouping.
    /// Each collapsed family becomes one DiscoveryModel with multiple start_targets.
    private static func codexDiscoveryModels(
        from options: [AgentModelOption],
        agent: AgentProviderKind,
        defaultModelRaw: String
    ) -> [DiscoveryModel] {
        let menu = codexMenu(for: options)
        var models: [DiscoveryModel] = []

        // Include the placeholder "default" entry if present
        if let defaultOption = menu.defaultOption {
            models.append(discoveryModel(
                defaultOption, agent: agent, defaultModelRaw: defaultModelRaw
            ))
        }

        // Each grouped family becomes a model with nested start_targets
        for group in menu.groups {
            let targets = group.options.map { option -> DiscoveryStartTarget in
                let selectionID = AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: option.rawValue)
                let specifier = CodexModelSpecifier(raw: option.rawValue)
                let contextWindow: Int? = AgentModel(rawValue: option.rawValue)?.contextWindowTokens
                return DiscoveryStartTarget(
                    selectionID: selectionID,
                    modelRaw: option.rawValue,
                    name: "\(agent.displayName) \(option.displayName)",
                    description: option.description,
                    reasoningEffort: specifier.reasoningEffort,
                    available: true,
                    isDefault: option.isProviderDefault || option.rawValue.caseInsensitiveCompare(defaultModelRaw) == .orderedSame,
                    contextWindowTokens: contextWindow
                )
            }
            // Use the first option's metadata for family-level fields
            let representative = group.options.first
            let allEfforts = group.options.compactMap { CodexModelSpecifier(raw: $0.rawValue).reasoningEffort }
            let defaultEffort = representative?.defaultReasoningEffort
                ?? group.options.first(where: \.isProviderDefault)
                .flatMap { CodexModelSpecifier(raw: $0.rawValue).reasoningEffort }
            let familyDescription = representative?.description

            // Union child tags, de-duplicated, in fixed display order
            let allTags: [AgentModelDiscoveryTag] = {
                let childTags = Set(group.options.flatMap { option -> [AgentModelDiscoveryTag] in
                    AgentModel(rawValue: option.rawValue)?.discoveryTags
                        ?? AgentModelDiscoveryTag.infer(from: option.rawValue)
                })
                return AgentModelDiscoveryTag.displayOrder.filter(childTags.contains)
            }()

            models.append(DiscoveryModel(
                id: group.baseModelID,
                name: group.displayName,
                description: familyDescription,
                available: true,
                tags: allTags,
                contextWindowTokens: nil,
                supportedReasoningEfforts: allEfforts.isEmpty ? [] : CodexReasoningEffort.displayOrder.filter(allEfforts.contains),
                defaultReasoningEffort: defaultEffort,
                startTargets: targets
            ))
        }

        return models
    }

    private static func claudeDiscoveryModels(
        from options: [AgentModelOption],
        agent: AgentProviderKind,
        defaultModelRaw: String
    ) -> [DiscoveryModel] {
        let menu = claudeMenu(for: options, agentKind: agent)
        var models: [DiscoveryModel] = []

        if let defaultOption = menu.defaultOption {
            models.append(discoveryModel(defaultOption, agent: agent, defaultModelRaw: defaultModelRaw))
        }

        for group in menu.groups {
            let targets = group.options.map { option -> DiscoveryStartTarget in
                let selectionID = AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: option.rawValue)
                let specifier = ClaudeModelSpecifier(raw: option.rawValue)
                let effortDisplayName = specifier.effortLevel?.displayName
                let targetNameSuffix = effortDisplayName.map { "\(group.displayName) \($0)" } ?? option.displayName
                let contextWindow = AgentModel.resolvedModel(forRaw: option.rawValue, agentKind: agent)?.contextWindowTokens
                return DiscoveryStartTarget(
                    selectionID: selectionID,
                    modelRaw: option.rawValue,
                    name: "\(agent.displayName) \(targetNameSuffix)",
                    description: option.description,
                    reasoningEffort: nil,
                    available: true,
                    isDefault: option.rawValue.caseInsensitiveCompare(defaultModelRaw) == .orderedSame,
                    contextWindowTokens: contextWindow
                )
            }

            let representative = group.options.first
            let representativeModel = AgentModel.resolvedModel(forRaw: group.baseModelRaw, agentKind: agent)
            let childTags = Set(group.options.flatMap { option -> [AgentModelDiscoveryTag] in
                AgentModel.resolvedModel(forRaw: option.rawValue, agentKind: agent)?.discoveryTags
                    ?? AgentModelDiscoveryTag.infer(from: option.rawValue)
            })
            let tags = AgentModelDiscoveryTag.displayOrder.filter(childTags.contains)

            models.append(DiscoveryModel(
                id: group.baseModelRaw,
                name: group.displayName,
                description: representative?.description,
                available: true,
                tags: tags,
                contextWindowTokens: representativeModel?.contextWindowTokens,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil,
                startTargets: targets
            ))
        }

        return models
    }

    private static func discoveryModel(
        _ option: AgentModelOption,
        agent: AgentProviderKind,
        defaultModelRaw: String
    ) -> DiscoveryModel {
        let selectionID = AgentModelSelectionID(agentRaw: agent.rawValue, modelRaw: option.rawValue)
        let staticModel = AgentModel(rawValue: option.rawValue)
        let contextWindow = staticModel?.contextWindowTokens
        let tags = staticModel?.discoveryTags ?? AgentModelDiscoveryTag.infer(from: option.rawValue)

        let target = DiscoveryStartTarget(
            selectionID: selectionID,
            modelRaw: option.rawValue,
            name: startTargetLabel(agentKind: agent, option: option),
            description: option.description,
            reasoningEffort: option.defaultReasoningEffort,
            available: true,
            isDefault: option.rawValue.caseInsensitiveCompare(defaultModelRaw) == .orderedSame,
            contextWindowTokens: contextWindow
        )

        return DiscoveryModel(
            id: option.rawValue,
            name: option.displayName,
            description: option.description,
            available: true,
            tags: tags,
            contextWindowTokens: contextWindow,
            supportedReasoningEfforts: option.supportedReasoningEfforts,
            defaultReasoningEffort: option.defaultReasoningEffort,
            startTargets: [target]
        )
    }

    private static func discoveryCapabilities(for agent: AgentProviderKind) -> [String] {
        // Resolve granted tools directly from policy to avoid @MainActor dependency
        // on AgentModeMCPPolicyInstaller.
        let grantedTools = AgentModeMCPToolPolicy.grantedTools(forAgent: agent)
        let grantedCaps = grantedTools.reduce(into: Set<MCPToolCapability>()) { result, tool in
            result.formUnion(MCPToolCapabilities.capabilities(for: tool))
        }
        return grantedCaps.map(\.externalName).sorted()
    }

    #if DEBUG
        @_spi(TestSupport)
        public static func test_mergeCodexOptions(
            primary: [AgentModelOption],
            fallback: [AgentModelOption]
        ) -> [AgentModelOption] {
            AgentCodexModelRegistry.shared.test_mergeCodexOptions(primary: primary, fallback: fallback)
        }
    #endif
}
