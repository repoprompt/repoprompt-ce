import SwiftUI

struct AIModelDropdown: View {
    @ObservedObject var promptViewModel: PromptViewModel
    @Binding var showSettingsPopover: Bool
    var windowID: Int?
    var useBorderlessStyle: Bool = true
    var isInGeneralSettings: Bool = false

    /// The destination where model selection is applied.
    /// Defaults to `.chatModel(promptVM:)` if not specified.
    let destination: ModelDestination

    private let maxModelNameLength = 40

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var menuModelSnapshot: [AIModel]? = nil
    @State private var menuSnapshotReleaseTask: Task<Void, Never>? = nil

    private struct ClaudeCodeTopLevelMenu {
        let displayName: String
        let models: [AIModel]
        let isCompatibleBackend: Bool
    }

    // MARK: - Initializers

    /// Primary initializer with explicit destination
    init(
        promptViewModel: PromptViewModel,
        showSettingsPopover: Binding<Bool>,
        windowID: Int? = nil,
        useBorderlessStyle: Bool = true,
        isInGeneralSettings: Bool = false,
        destination: ModelDestination
    ) {
        self.promptViewModel = promptViewModel
        _showSettingsPopover = showSettingsPopover
        self.windowID = windowID
        self.useBorderlessStyle = useBorderlessStyle
        self.isInGeneralSettings = isInGeneralSettings
        self.destination = destination
    }

    /// Convenience initializer that defaults to chat model destination
    init(
        promptViewModel: PromptViewModel,
        showSettingsPopover: Binding<Bool>,
        windowID: Int? = nil,
        useBorderlessStyle: Bool = true,
        isInGeneralSettings: Bool = false
    ) {
        self.promptViewModel = promptViewModel
        _showSettingsPopover = showSettingsPopover
        self.windowID = windowID
        self.useBorderlessStyle = useBorderlessStyle
        self.isInGeneralSettings = isInGeneralSettings
        destination = .chatModel(promptVM: promptViewModel)
    }

    var body: some View {
        Group {
            if useBorderlessStyle {
                borderlessStyleMenu
            } else {
                standardStyleMenu
            }
        }
        .onDisappear {
            menuSnapshotReleaseTask?.cancel()
            menuSnapshotReleaseTask = nil
            menuModelSnapshot = nil
        }
    }

    // MARK: - Borderless Style (nested submenus)

    private var borderlessStyleMenu: some View {
        StableMenuButton(
            items: aiModelMenuItems,
            triggerStyle: .plain,
            onOpen: beginMenuPresentationSnapshot
        ) {
            HStack(spacing: 5) {
                Text(truncateHeadIfNeeded(displayedModelName))
                    .truncationMode(.head)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .fixedSize()
    }

    // MARK: - Standard Style (nested submenus via stable AppKit menu)

    private var standardStyleMenu: some View {
        StableMenuButton(
            items: aiModelMenuItems,
            onOpen: beginMenuPresentationSnapshot
        ) {
            HStack(spacing: 5) {
                Text(truncateHeadIfNeeded(displayedModelName))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AppKit Menu Content (Provider → Models)

    private func aiModelMenuItems() -> [StableMenuItem] {
        let allModels = menuModelSnapshot ?? promptViewModel.availableModels
        guard !allModels.isEmpty else {
            return [.action("Configure API Settings", handleConfigureAction)]
        }

        let groupedModels = Dictionary(grouping: allModels, by: { $0.providerType })
        let sortedProviders = groupedModels.keys.sorted {
            AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }

        return sortedProviders.flatMap { provider -> [StableMenuItem] in
            let models = AIModel.sortedForPicker(groupedModels[provider] ?? [])
            if provider == .claudeCode {
                return aiModelClaudeCodeTopLevelMenuItems(for: models)
            }

            let providerItems: [StableMenuItem] = if provider == .codex {
                AIModel.codexMenuGroups(for: models).map { group in
                    StableMenuItem.submenu(
                        group.displayName,
                        items: group.models.map(aiModelMenuItem)
                    )
                }
            } else if provider == .openCode {
                AIModel.openCodeMenu(for: models).providerGroups.flatMap { providerGroup -> [StableMenuItem] in
                    let modelItems = providerGroup.groups.map(aiModelOpenCodeMenuItem)
                    guard providerGroup.rendersAsSubmenu else { return modelItems }
                    return [.submenu(providerGroup.displayName, items: modelItems)]
                }
            } else {
                models.map(aiModelMenuItem)
            }
            return [.submenu(AIProviderType.displayName(for: provider), items: providerItems)]
        }
    }

    private func aiModelClaudeCodeTopLevelMenuItems(for models: [AIModel]) -> [StableMenuItem] {
        claudeCodeTopLevelMenus(for: models).map { section in
            let items = section.isCompatibleBackend
                ? section.models.compactMap(aiModelCompatibleClaudeBackendMenuItem)
                : aiModelClaudeCodeMenuItems(for: section.models)
            return .submenu(section.displayName, items: items)
        }
    }

    private func claudeCodeTopLevelMenus(for models: [AIModel]) -> [ClaudeCodeTopLevelMenu] {
        var sections: [ClaudeCodeTopLevelMenu] = []
        let nativeModels = models.filter { ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) == nil }
        if !nativeModels.isEmpty {
            sections.append(ClaudeCodeTopLevelMenu(
                displayName: AIProviderType.displayName(for: .claudeCode),
                models: nativeModels,
                isCompatibleBackend: false
            ))
        }

        let compatibleModels = models.compactMap { model -> (AIModel, ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor)? in
            guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
            return (model, descriptor)
        }
        let grouped = Dictionary(grouping: compatibleModels, by: { $0.1.backendID })
        let backendSortOrder = Dictionary(uniqueKeysWithValues: ClaudeCodeCompatibleBackendID.allCases.enumerated().map { ($0.element, $0.offset) })
        for backendID in grouped.keys.sorted(by: {
            let lhsRank = backendSortOrder[$0] ?? Int.max
            let rhsRank = backendSortOrder[$1] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return compatibleClaudeBackendTopLevelDisplayName(for: $0).localizedCaseInsensitiveCompare(
                compatibleClaudeBackendTopLevelDisplayName(for: $1)
            ) == .orderedAscending
        }) {
            let entries = grouped[backendID] ?? []
            let sortedModels = entries
                .sorted { lhs, rhs in
                    let lhsRank = compatibleClaudeBackendOptionRank(lhs.1.requestedModelRaw)
                    let rhsRank = compatibleClaudeBackendOptionRank(rhs.1.requestedModelRaw)
                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }
                    return lhs.1.optionDisplayName.localizedCaseInsensitiveCompare(rhs.1.optionDisplayName) == .orderedAscending
                }
                .map(\.0)
            sections.append(ClaudeCodeTopLevelMenu(
                displayName: compatibleClaudeBackendTopLevelDisplayName(for: backendID),
                models: sortedModels,
                isCompatibleBackend: true
            ))
        }
        return sections
    }

    private func aiModelClaudeCodeMenuItems(for models: [AIModel]) -> [StableMenuItem] {
        let menu = AIModel.claudeCodeMenu(for: models)
        var items: [StableMenuItem] = []
        if let defaultOption = menu.defaultOption {
            items.append(aiModelMenuItem(defaultOption))
        }
        if !items.isEmpty, !menu.groups.isEmpty {
            items.append(.separator)
        }
        items.append(contentsOf: menu.groups.compactMap(aiModelClaudeCodeMenuItem))
        return items
    }

    private func aiModelCompatibleClaudeBackendMenuItem(_ model: AIModel) -> StableMenuItem? {
        guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
        return StableMenuItem.action(
            truncateHeadIfNeeded(compatibleClaudeBackendOptionDisplayName(for: descriptor)),
            isSelected: model.rawValue == destination.currentRawValue
        ) {
            destination.apply(model.rawValue)
        }
    }

    private func compatibleClaudeBackendTopLevelDisplayName(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized.normalizedDisplayName
    }

    private func compatibleClaudeBackendOptionDisplayName(
        for descriptor: ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor
    ) -> String {
        descriptor.optionDisplayName
    }

    private func compatibleClaudeBackendOptionRank(_ rawModel: String?) -> Int {
        switch rawModel {
        case .some(AgentModel.claudeHaiku.rawValue): return 0
        case .some(AgentModel.claudeSonnet.rawValue): return 1
        case .some(AgentModel.claudeOpus.rawValue): return 2
        case let .some(raw):
            if let index = ClaudeCompatibleProviderRuntimeBridge.directSelectableGLMModelRawValues.firstIndex(of: raw) {
                return 10 + index
            }
            return 99
        case nil:
            return 99
        }
    }

    private func aiModelClaudeCodeMenuItem(_ group: AIModel.ClaudeCodePickerMenuGroup) -> StableMenuItem? {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.displayName,
                items: group.options.map(aiModelMenuItem)
            )
        }
        if let option = group.options.first {
            return aiModelMenuItem(option)
        }
        return nil
    }

    private func aiModelOpenCodeMenuItem(_ group: AIModel.OpenCodePickerMenuGroup) -> StableMenuItem {
        if group.rendersAsSubmenu {
            return StableMenuItem.submenu(
                group.modelDisplayName,
                items: group.options.map(aiModelMenuItem)
            )
        }
        if let option = group.options.first {
            return aiModelMenuItem(option)
        }
        return .separator
    }

    private func aiModelMenuItem(_ model: AIModel) -> StableMenuItem {
        StableMenuItem.action(
            truncateHeadIfNeeded(model.displayName),
            isSelected: model.rawValue == destination.currentRawValue
        ) {
            destination.apply(model.rawValue)
        }
    }

    private func aiModelMenuItem(_ option: AIModel.OpenCodePickerMenuOption) -> StableMenuItem {
        StableMenuItem.action(
            truncateHeadIfNeeded(option.displayName),
            isSelected: option.model.rawValue == destination.currentRawValue
        ) {
            destination.apply(option.model.rawValue)
        }
    }

    private func aiModelMenuItem(_ option: AIModel.ClaudeCodePickerMenuOption) -> StableMenuItem {
        StableMenuItem.action(
            truncateHeadIfNeeded(option.displayName),
            isSelected: option.model.rawValue == destination.currentRawValue
        ) {
            destination.apply(option.model.rawValue)
        }
    }

    // MARK: - Display Name

    private var displayedModelName: String {
        Self.displayName(
            forRawValue: destination.currentRawValue,
            destinationID: destination.id,
            availableModels: promptViewModel.availableModels,
            customOpenRouterModels: promptViewModel.apiSettingsViewModel?.customOpenRouterModels ?? [],
            compatibleClaudeBackendDisplayName: { model in
                guard let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) else { return nil }
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
        )
    }

    @MainActor
    static func displayName(
        forRawValue currentModel: String,
        destinationID: String,
        availableModels: [AIModel],
        customOpenRouterModels: [String],
        compatibleClaudeBackendDisplayName: (AIModel) -> String? = { _ in nil }
    ) -> String {
        if availableModels.isEmpty {
            return "No models available"
        }

        // Check custom OpenRouter models
        if let customModel = customOpenRouterModels.first(where: { currentModel == "openrouter_custom_\($0)" }) {
            return "oRouter/\(customModel)"
        }

        // Check available models
        if let selectedModel = availableModels.first(where: { $0.rawValue == currentModel }) {
            return compatibleClaudeBackendDisplayName(selectedModel) ?? selectedModel.displayName
        }

        // Try parsing (handles tier variants not in current list)
        if let parsed = AIModel.fromModelName(currentModel) {
            return compatibleClaudeBackendDisplayName(parsed) ?? parsed.displayName
        }

        if destinationID == "planningModel" {
            let trimmedRawValue = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedRawValue.isEmpty ? "Select an Oracle model" : "Invalid Oracle model"
        }

        // Fallback to first available for non-Oracle destinations.
        return availableModels.first?.displayName ?? "Select a model"
    }

    // MARK: - Helpers

    private func truncateHeadIfNeeded(_ text: String) -> String {
        if text.count <= maxModelNameLength {
            return text
        }

        if let lastSlashIndex = text.lastIndex(of: "/") {
            let trimmedText = String(text[lastSlashIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmedText.count <= maxModelNameLength {
                return trimmedText
            }
            let startIndex = trimmedText.index(trimmedText.endIndex, offsetBy: -maxModelNameLength)
            return "…\(trimmedText[startIndex...])"
        }

        let startIndex = text.index(text.endIndex, offsetBy: -maxModelNameLength)
        return "…\(text[startIndex...])"
    }

    private func handleConfigureAction() {
        NotificationCenter.default.post(
            name: .showAPISettingsTab,
            object: nil,
            userInfo: windowID != nil ? ["windowID": windowID!] : nil
        )
    }

    @MainActor
    private func beginMenuPresentationSnapshot() {
        menuSnapshotReleaseTask?.cancel()
        menuModelSnapshot = promptViewModel.availableModels
        menuSnapshotReleaseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            menuModelSnapshot = nil
            menuSnapshotReleaseTask = nil
        }
    }
}
