import SwiftUI

enum AgentModelSelectionWarningVisuals {
    static let iconSystemName = "bolt.fill"
    static let warningTooltip = "Fast Codex model selected: uses your usage limits about 2× faster."
    static let warningColor = Color.orange

    static func showsWarning(agent: AgentProviderKind, rawModel: String?) -> Bool {
        agent == .codexExec && CodexServiceTierVariantCatalog.isFastVariant(rawModel: rawModel)
    }

    static func stableMenuImageSystemName(agent: AgentProviderKind, rawModel: String?) -> String? {
        showsWarning(agent: agent, rawModel: rawModel) ? iconSystemName : nil
    }

    static func stableMenuStyle(agent: AgentProviderKind, rawModel: String?) -> StableMenuItemStyle {
        showsWarning(agent: agent, rawModel: rawModel) ? .warning : .normal
    }

    static func codexGroupShowsWarning(_ group: AgentModelCatalog.CodexMenuGroup) -> Bool {
        showsWarning(agent: .codexExec, rawModel: group.baseModelID) ||
            group.options.contains { showsWarning(agent: .codexExec, rawModel: $0.rawValue) }
    }
}

struct AgentModelSelectionSummaryLabel: View {
    let agentKind: AgentProviderKind
    let rawModel: String
    let title: String
    var iconFont: Font = .caption

    var body: some View {
        let showsWarning = AgentModelSelectionWarningVisuals.showsWarning(agent: agentKind, rawModel: rawModel)
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                    .font(iconFont)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            }
            if showsWarning {
                Text(title)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            } else {
                Text(title)
            }
        }
    }
}

/// Reusable menu content for agent model selection.
/// For Codex and OpenCode, renders nested groups: base model -> variant/reasoning level.
struct AgentModelOptionsMenuContent: View {
    let agentKind: AgentProviderKind
    let options: [AgentModelOption]
    let selectedAgent: AgentProviderKind
    let selectedModelRaw: String
    let onSelect: (AgentProviderKind, AgentModelOption) -> Void

    var body: some View {
        if agentKind == .codexExec {
            let codexMenu = AgentModelCatalog.codexMenu(for: options)
            if let defaultOption = codexMenu.defaultOption {
                modelOptionButton(defaultOption)
            }
            ForEach(codexMenu.groups) { group in
                Menu {
                    ForEach(group.options, id: \.rawValue) { option in
                        modelOptionButton(option)
                    }
                } label: {
                    warningAwareMenuLabel(
                        title: group.displayName,
                        showsWarning: AgentModelSelectionWarningVisuals.codexGroupShowsWarning(group)
                    )
                }
            }
        } else if agentKind.usesClaudeTooling {
            let claudeMenu = AgentModelCatalog.claudeMenu(for: options, agentKind: agentKind)
            if let defaultOption = claudeMenu.defaultOption {
                modelOptionButton(defaultOption)
            }
            ForEach(claudeMenu.groups) { group in
                if group.rendersAsSubmenu {
                    Menu(group.displayName) {
                        ForEach(group.options, id: \.rawValue) { option in
                            modelOptionButton(option, title: claudeEffortMenuTitle(for: option))
                        }
                    }
                } else if let option = group.options.first {
                    modelOptionButton(option)
                }
            }
        } else if agentKind == .devin {
            ForEach(AgentModelCatalog.devinModelGroups(for: options)) { group in
                if let family = group.family {
                    Menu(family.displayName) {
                        ForEach(group.options, id: \.rawValue) { option in modelOptionButton(option) }
                    }
                } else {
                    ForEach(group.options, id: \.rawValue) { option in modelOptionButton(option) }
                }
            }
        } else if agentKind == .omp {
            ForEach(AgentModelCatalog.ompModelGroups(for: options)) { group in
                if let provider = group.providerID {
                    Menu(provider) {
                        ForEach(group.options, id: \.rawValue) { option in
                            modelOptionButton(option)
                        }
                    }
                } else {
                    ForEach(group.options, id: \.rawValue) { option in
                        modelOptionButton(option)
                    }
                }
            }
        } else if agentKind == .openCode {
            ForEach(AgentModelCatalog.openCodeMenu(for: options).providerGroups) { providerGroup in
                if providerGroup.rendersAsSubmenu {
                    Menu(providerGroup.displayName) {
                        openCodeModelGroupContent(providerGroup.groups)
                    }
                } else {
                    openCodeModelGroupContent(providerGroup.groups)
                }
            }
        } else {
            ForEach(options, id: \.rawValue) { option in
                modelOptionButton(option)
            }
        }
    }

    private func openCodeModelGroupContent(_ groups: [AgentModelCatalog.OpenCodeMenuGroup]) -> some View {
        ForEach(groups) { group in
            if group.rendersAsSubmenu {
                Menu(group.modelDisplayName) {
                    ForEach(group.options) { menuOption in
                        modelOptionButton(menuOption.option, title: menuOption.displayName)
                    }
                }
            } else if let menuOption = group.options.first {
                modelOptionButton(menuOption.option, title: menuOption.displayName)
            }
        }
    }

    private func modelOptionButton(_ option: AgentModelOption, title: String? = nil) -> some View {
        Button {
            AgentModelCatalog.updateLastUsedEffortIfEncoded(
                agentKind: agentKind,
                rawModel: option.rawValue
            )
            onSelect(agentKind, option)
        } label: {
            let showsWarning = AgentModelSelectionWarningVisuals.showsWarning(agent: agentKind, rawModel: option.rawValue)
            HStack {
                warningAwareMenuLabel(title: title ?? option.displayName, showsWarning: showsWarning)
                if selectedAgent == agentKind, AgentModelCatalog.modelOptionIsSelected(
                    optionRaw: option.rawValue,
                    selectedRaw: selectedModelRaw,
                    agentKind: agentKind
                ) {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func claudeEffortMenuTitle(for option: AgentModelOption) -> String {
        ClaudeModelSpecifier(raw: option.rawValue).effortLevel?.displayName ?? option.displayName
    }

    private func warningAwareMenuLabel(title: String, showsWarning: Bool) -> some View {
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: AgentModelSelectionWarningVisuals.iconSystemName)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            }
            if showsWarning {
                Text(title)
                    .foregroundStyle(AgentModelSelectionWarningVisuals.warningColor)
            } else {
                Text(title)
            }
        }
    }
}

/// Reusable AppKit-backed menu item builder for agent model selection.
/// Mirrors `AgentModelOptionsMenuContent`, but produces `StableMenuItem`s for
/// long-lived pickers where SwiftUI `Menu` tracking can be interrupted by view updates.
enum AgentModelStableMenuItems {
    static func agentSubmenu(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        StableMenuItem.submenu(
            agentKind.displayName,
            items: modelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleCodexGroups: flattenSingleCodexGroups,
                groupOpenCode: groupOpenCode,
                onSelect: onSelect
            )
        )
    }

    static func modelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool = true,
        flattenSingleCodexGroups: Bool = false,
        groupOpenCode: Bool = true,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        if agentKind == .codexExec {
            return codexModelItems(
                agentKind: agentKind,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                includePlaceholderDefault: includePlaceholderDefault,
                flattenSingleGroups: flattenSingleCodexGroups,
                onSelect: onSelect
            )
        }

        let visibleOptions = visibleOptions(options, includePlaceholderDefault: includePlaceholderDefault)
        if agentKind.usesClaudeTooling {
            return claudeModelItems(
                agentKind: agentKind,
                options: visibleOptions,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        if agentKind == .devin {
            return AgentModelCatalog.devinModelGroups(for: visibleOptions).flatMap { group -> [StableMenuItem] in
                let items = group.options.map { option in
                    modelItem(
                        option,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
                guard let family = group.family else { return items }
                return [.submenu(family.displayName, items: items)]
            }
        }
        if agentKind == .omp {
            return AgentModelCatalog.ompModelGroups(for: visibleOptions).flatMap { group -> [StableMenuItem] in
                let items = group.options.map { option in
                    modelItem(
                        option,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
                guard let provider = group.providerID else { return items }
                return [.submenu(provider, items: items)]
            }
        }
        if agentKind == .openCode, groupOpenCode {
            return AgentModelCatalog.openCodeMenu(for: visibleOptions).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
                let modelItems = providerGroup.groups.map { group in
                    openCodeModelItem(
                        agentKind: agentKind,
                        group: group,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
                guard providerGroup.rendersAsSubmenu else { return modelItems }
                return [.submenu(providerGroup.displayName, items: modelItems)]
            }
        }

        return visibleOptions.map { option in
            modelItem(
                option,
                agentKind: agentKind,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
    }

    private static func codexModelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        includePlaceholderDefault: Bool,
        flattenSingleGroups: Bool,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let codexMenu = AgentModelCatalog.codexMenu(for: options)
        var items: [StableMenuItem] = []
        if includePlaceholderDefault, let defaultOption = codexMenu.defaultOption {
            items.append(
                modelItem(
                    defaultOption,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            )
        }
        items.append(contentsOf: codexMenu.groups.map { group in
            if flattenSingleGroups, group.options.count == 1, let only = group.options.first {
                return modelItem(
                    only,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            }
            let showsWarning = AgentModelSelectionWarningVisuals.codexGroupShowsWarning(group)
            return StableMenuItem.submenu(
                group.displayName,
                imageSystemName: showsWarning ? AgentModelSelectionWarningVisuals.iconSystemName : nil,
                style: showsWarning ? .warning : .normal,
                items: group.options.map { option in
                    modelItem(
                        option,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
            )
        })
        return items
    }

    private static func claudeModelItems(
        agentKind: AgentProviderKind,
        options: [AgentModelOption],
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> [StableMenuItem] {
        let claudeMenu = AgentModelCatalog.claudeMenu(for: options, agentKind: agentKind)
        var items: [StableMenuItem] = []
        if let defaultOption = claudeMenu.defaultOption {
            items.append(
                modelItem(
                    defaultOption,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            )
        }
        items.append(contentsOf: claudeMenu.groups.map { group in
            if group.rendersAsSubmenu {
                return StableMenuItem.submenu(
                    group.displayName,
                    items: group.options.map { option in
                        modelItem(
                            option,
                            title: claudeEffortMenuTitle(for: option),
                            agentKind: agentKind,
                            selectedAgent: selectedAgent,
                            selectedModelRaw: selectedModelRaw,
                            onSelect: onSelect
                        )
                    }
                )
            }
            if let option = group.options.first {
                return modelItem(
                    option,
                    agentKind: agentKind,
                    selectedAgent: selectedAgent,
                    selectedModelRaw: selectedModelRaw,
                    onSelect: onSelect
                )
            }
            return .separator
        })
        return items
    }

    private static func openCodeModelItem(
        agentKind: AgentProviderKind,
        group: AgentModelCatalog.OpenCodeMenuGroup,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map { menuOption in
                    modelItem(
                        menuOption.option,
                        title: menuOption.displayName,
                        agentKind: agentKind,
                        selectedAgent: selectedAgent,
                        selectedModelRaw: selectedModelRaw,
                        onSelect: onSelect
                    )
                }
            )
        }
        if let menuOption = group.options.first {
            return modelItem(
                menuOption.option,
                title: menuOption.displayName,
                agentKind: agentKind,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw,
                onSelect: onSelect
            )
        }
        return .separator
    }

    private static func modelItem(
        _ option: AgentModelOption,
        title: String? = nil,
        agentKind: AgentProviderKind,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        onSelect: @escaping (AgentProviderKind, AgentModelOption) -> Void
    ) -> StableMenuItem {
        StableMenuItem.action(
            title ?? option.displayName,
            isSelected: selectedAgent == agentKind && AgentModelCatalog.modelOptionIsSelected(
                optionRaw: option.rawValue,
                selectedRaw: selectedModelRaw,
                agentKind: agentKind
            ),
            imageSystemName: AgentModelSelectionWarningVisuals.stableMenuImageSystemName(agent: agentKind, rawModel: option.rawValue),
            style: AgentModelSelectionWarningVisuals.stableMenuStyle(agent: agentKind, rawModel: option.rawValue)
        ) {
            AgentModelCatalog.updateLastUsedEffortIfEncoded(
                agentKind: agentKind,
                rawModel: option.rawValue
            )
            onSelect(agentKind, option)
        }
    }

    private static func claudeEffortMenuTitle(for option: AgentModelOption) -> String {
        ClaudeModelSpecifier(raw: option.rawValue).effortLevel?.displayName ?? option.displayName
    }

    private static func visibleOptions(
        _ options: [AgentModelOption],
        includePlaceholderDefault: Bool
    ) -> [AgentModelOption] {
        guard !includePlaceholderDefault else { return options }
        let filtered = options.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? options : filtered
    }
}
