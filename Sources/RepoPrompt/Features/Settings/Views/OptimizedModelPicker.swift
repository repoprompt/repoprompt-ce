import SwiftUI

/// An optimized model picker that caches grouped models and only updates when the model list changes.
/// Uses a nested Menu structure: Provider → Models for better navigation with large model lists.
struct OptimizedModelPicker: View {
    /// The destination where model selection is applied
    let destination: ModelDestination
    let availableModels: [AIModel]
    let font: Font
    let widthStyle: WidthStyle

    @State private var cachedGroups: [AIProviderType: [AIModel]] = [:]
    @State private var cachedProviders: [AIProviderType] = []
    @State private var lastModelsSignature: Int = 0

    private struct ClaudeCodeTopLevelMenu: Identifiable {
        let id: String
        let displayName: String
        let models: [AIModel]
        let isCompatibleBackend: Bool
    }

    enum WidthStyle {
        case fixed(width: CGFloat, alignment: Alignment = .trailing)
        case flexible(minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, alignment: Alignment = .leading)
    }

    private var selectedLabel: String {
        let currentValue = destination.currentRawValue
        // 1. Try to find in available models
        if let match = availableModels.first(where: { $0.rawValue == currentValue }) {
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: match) {
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
            return match.displayName
        }
        // 2. Try parsing (handles tier variants not in current list)
        if let parsed = AIModel.fromModelName(currentValue) {
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: parsed) {
                return compatibleClaudeBackendOptionDisplayName(for: descriptor)
            }
            return parsed.displayName
        }
        // 3. Fallback
        return currentValue.isEmpty ? "Select a model" : currentValue
    }

    // MARK: - Initializers

    /// Primary initializer with explicit destination
    init(destination: ModelDestination, availableModels: [AIModel], font: Font, widthStyle: WidthStyle = .fixed(width: 220, alignment: .trailing)) {
        self.destination = destination
        self.availableModels = availableModels
        self.font = font
        self.widthStyle = widthStyle
    }

    /// Convenience initializer with binding (creates a binding-backed destination)
    init(selection: Binding<String>, availableModels: [AIModel], font: Font, widthStyle: WidthStyle = .fixed(width: 220, alignment: .trailing)) {
        destination = .binding(selection, id: "optimizedModelPicker")
        self.availableModels = availableModels
        self.font = font
        self.widthStyle = widthStyle
    }

    var body: some View {
        Menu {
            ForEach(cachedProviders, id: \.self) { provider in
                if provider == .claudeCode,
                   let models = cachedGroups[provider]
                {
                    ForEach(claudeCodeTopLevelMenus(for: models)) { section in
                        Menu(section.displayName) {
                            if section.isCompatibleBackend {
                                compatibleClaudeBackendMenuContent(section.models)
                            } else {
                                providerModelMenuContent(provider: provider, models: section.models)
                            }
                        }
                    }
                } else {
                    Menu(AIProviderType.displayName(for: provider)) {
                        if let models = cachedGroups[provider] {
                            providerModelMenuContent(provider: provider, models: models)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLabel)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .modifier(ControlWidthModifier(style: widthStyle))
        .onAppear {
            updateCacheIfNeeded()
        }
        .onChange(of: modelsSignature) { _, _ in
            updateCacheIfNeeded()
        }
    }

    private func claudeCodeTopLevelMenus(for models: [AIModel]) -> [ClaudeCodeTopLevelMenu] {
        var sections: [ClaudeCodeTopLevelMenu] = []
        let nativeModels = models.filter { ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: $0) == nil }
        if !nativeModels.isEmpty {
            sections.append(ClaudeCodeTopLevelMenu(
                id: "claude-code",
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
                    compatibleClaudeBackendOptionRank(lhs.1.requestedModelRaw) < compatibleClaudeBackendOptionRank(rhs.1.requestedModelRaw)
                }
                .map(\.0)
            sections.append(ClaudeCodeTopLevelMenu(
                id: "compatible-\(backendID.rawValue)",
                displayName: compatibleClaudeBackendTopLevelDisplayName(for: backendID),
                models: sortedModels,
                isCompatibleBackend: true
            ))
        }
        return sections
    }

    @ViewBuilder
    private func providerModelMenuContent(provider: AIProviderType, models: [AIModel]) -> some View {
        if provider == .claudeCode {
            let menu = AIModel.claudeCodeMenu(for: models)
            ForEach(menu.groups) { group in
                if group.rendersAsSubmenu {
                    Menu(group.displayName) {
                        ForEach(group.options) { option in
                            modelButton(option.model, title: option.displayName)
                        }
                    }
                } else if let option = group.options.first {
                    modelButton(option.model, title: option.displayName)
                }
            }
        } else if provider == .openCode {
            ForEach(AIModel.openCodeMenu(for: models).providerGroups) { providerGroup in
                if providerGroup.rendersAsSubmenu {
                    Menu(providerGroup.displayName) {
                        openCodeModelGroupContent(providerGroup.groups)
                    }
                } else {
                    openCodeModelGroupContent(providerGroup.groups)
                }
            }
        } else {
            ForEach(models, id: \.rawValue) { model in
                modelButton(model)
            }
        }
    }

    private func compatibleClaudeBackendMenuContent(_ models: [AIModel]) -> some View {
        ForEach(models, id: \.rawValue) { model in
            if let descriptor = ClaudeCodeAIModelCatalog.compatibleBackendDescriptor(for: model) {
                modelButton(model, title: compatibleClaudeBackendOptionDisplayName(for: descriptor))
            }
        }
    }

    private func compatibleClaudeBackendTopLevelDisplayName(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        ClaudeCodeCompatibleBackendStore.shared.config(for: backendID).normalized.normalizedDisplayName
    }

    private func compatibleClaudeBackendOptionDisplayName(
        for descriptor: ClaudeCodeAIModelCatalog.CompatibleBackendModelDescriptor
    ) -> String {
        let config = ClaudeCodeCompatibleBackendStore.shared.config(for: descriptor.backendID).normalized
        switch config.modelBehavior {
        case .noModel:
            return descriptor.optionDisplayName
        case let .claudeSlotMapping(mapping):
            let normalized = mapping.normalized
            let backendModelID: String? = switch descriptor.requestedModelRaw {
            case .some(AgentModel.claudeHaiku.rawValue):
                normalized.haiku
            case .some(AgentModel.claudeOpus.rawValue):
                normalized.opus
            case .some(AgentModel.claudeSonnet.rawValue), nil:
                normalized.sonnet
            default:
                nil
            }
            guard let backendModelID, !backendModelID.isEmpty else { return descriptor.optionDisplayName }
            return AgentModel(rawValue: backendModelID)?.displayName ?? backendModelID
        }
    }

    private func compatibleClaudeBackendOptionRank(_ rawModel: String?) -> Int {
        switch rawModel {
        case .some(AgentModel.claudeHaiku.rawValue): 0
        case .some(AgentModel.claudeSonnet.rawValue): 1
        case .some(AgentModel.claudeOpus.rawValue): 2
        default: 0
        }
    }

    private func openCodeModelGroupContent(_ groups: [AIModel.OpenCodePickerMenuGroup]) -> some View {
        ForEach(groups) { group in
            if group.rendersAsSubmenu {
                Menu(group.modelDisplayName) {
                    ForEach(group.options) { option in
                        modelButton(option.model, title: option.displayName)
                    }
                }
            } else if let option = group.options.first {
                modelButton(option.model, title: option.displayName)
            }
        }
    }

    private func modelButton(_ model: AIModel, title: String? = nil) -> some View {
        Button {
            destination.apply(model.rawValue)
        } label: {
            HStack {
                Text(title ?? model.displayName)
                    .font(font)
                Spacer()
                if destination.currentRawValue == model.rawValue {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Lightweight signature to detect model list changes (not just count)
    private var modelsSignature: Int {
        var hasher = Hasher()
        for model in availableModels {
            hasher.combine(model.rawValue)
        }
        return hasher.finalize()
    }

    private struct ControlWidthModifier: ViewModifier {
        let style: WidthStyle

        func body(content: Content) -> some View {
            switch style {
            case let .fixed(width, alignment):
                content.frame(width: width, alignment: alignment)
            case let .flexible(minWidth, maxWidth, alignment):
                content.frame(minWidth: minWidth, maxWidth: maxWidth, alignment: alignment)
            }
        }
    }

    private func updateCacheIfNeeded() {
        let currentSignature = modelsSignature
        guard currentSignature != lastModelsSignature else { return }

        lastModelsSignature = currentSignature

        // Group models by provider
        let grouped = Dictionary(grouping: availableModels, by: { $0.providerType })

        // Sort providers alphabetically
        let sortedProviders = grouped.keys.sorted {
            AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }

        // Sort models within each provider
        var sortedGroups: [AIProviderType: [AIModel]] = [:]
        for (provider, models) in grouped {
            sortedGroups[provider] = AIModel.sortedForPicker(models)
        }

        cachedGroups = sortedGroups
        cachedProviders = sortedProviders
    }
}
