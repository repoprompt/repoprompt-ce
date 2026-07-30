import SwiftUI

struct ModelOverridesSettingsView: View {
    @ObservedObject var overrides = ModelOverridesSettings.shared
    @ObservedObject var apiSettingsViewModel: APISettingsViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    // 1️⃣  Add right after existing @ObservedObject declarations
    @State private var providerSections: [(provider: AIProviderType, models: [AIModel])] = []
    @State private var recomputeTask: Task<Void, Never>?

    /// Track which rows are expanded
    @State private var expandedModels: Set<String> = []

    // MARK: - Pre-computed caches to keep type-checker happy

    private var groupedModels: [AIProviderType: [AIModel]] {
        Dictionary(
            grouping: apiSettingsViewModel.availableModels
                .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() },
            by: \.providerType
        )
    }

    private var sortedProviders: [AIProviderType] {
        groupedModels.keys.sorted {
            AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }
    }

    private func sortedModels(for provider: AIProviderType) -> [AIModel] {
        (groupedModels[provider] ?? []).sorted {
            $0.displayName.lowercased() < $1.displayName.lowercased()
        }
    }

    /// 2️⃣  Helper to compute grouped & sorted data only once
    private nonisolated static func computeSections(from models: [AIModel]) -> [(provider: AIProviderType, models: [AIModel])] {
        let grouped = Dictionary(
            grouping: models.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() },
            by: \.providerType
        )
        let providers = grouped.keys.sorted {
            AIProviderType.displayName(for: $0) < AIProviderType.displayName(for: $1)
        }
        return providers.map { provider in
            (provider, (grouped[provider] ?? []).sorted { $0.displayName.lowercased() < $1.displayName.lowercased() })
        }
    }

    private func scheduleRecomputeSections(updateExpanded: Bool, immediate: Bool = false) {
        recomputeTask?.cancel()
        let models = apiSettingsViewModel.availableModels
        recomputeTask = Task.detached(priority: .utility) { [models] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            let sections = Self.computeSections(from: models)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                providerSections = sections
                guard updateExpanded else { return }
                let withOverrides = models.filter { hasAnyOverride($0) }.map(\.rawValue)
                expandedModels = Set(withOverrides)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                introSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                ForEach(providerSections, id: \.provider) { section in
                    Section(
                        header: sectionHeader(for: section.provider)
                    ) {
                        VStack(spacing: 0) {
                            ForEach(section.models, id: \.rawValue) { model in
                                ModelOverrideDisclosureGroup(
                                    model: model,
                                    isExpanded: expandedModels.contains(model.rawValue),
                                    hasOverride: hasAnyOverride(model),
                                    fontPreset: fontPreset,
                                    overrides: overrides,
                                    onToggle: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if expandedModels.contains(model.rawValue) {
                                                expandedModels.remove(model.rawValue)
                                            } else {
                                                expandedModels.insert(model.rawValue)
                                            }
                                        }
                                    }
                                )

                                if model != section.models.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            scheduleRecomputeSections(updateExpanded: true, immediate: true)
        }
        .onReceive(apiSettingsViewModel.$availableModels) { _ in
            scheduleRecomputeSections(updateExpanded: false)
        }
    }

    // MARK: - Subviews

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Override app defaults for model settings. Useful with custom providers where optimal settings may not be configured.")
                    .font(.body)
            }
        }
    }

    private func hasAnyOverride(_ model: AIModel) -> Bool {
        let raw = model.rawValue
        return overrides.diffOverride(for: raw) != nil ||
            overrides.streamOverride(for: raw) != nil ||
            overrides.temperatureOverride(for: raw) != nil ||
            overrides.responsesOverride(for: raw) != nil
    }

    private func sectionHeader(for provider: AIProviderType) -> some View {
        Text(AIProviderType.displayName(for: provider))
            .font(.headline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.9))
    }

    /// Helper replicating the default diff logic for a given model.
    static func defaultDiff(for model: AIModel) -> Bool {
        model.isModelCapableOfDiff
    }
}

// MARK: - Optimized Disclosure Group

private struct ModelOverrideDisclosureGroup: View {
    let model: AIModel
    let isExpanded: Bool
    let hasOverride: Bool
    let fontPreset: FontScalePreset
    @ObservedObject var overrides: ModelOverridesSettings
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text(model.displayName)
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.primary)

                    Spacer()

                    if hasOverride {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.accentColor)
                            .font(.caption)
                            .imageScale(.small)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // Content
            if isExpanded {
                ModelOverrideRow(model: model, overrides: overrides, fontPreset: fontPreset)
                    .padding(.leading, 32)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Row view

private struct ModelOverrideRow: View {
    let model: AIModel
    @ObservedObject var overrides: ModelOverridesSettings
    let fontPreset: FontScalePreset

    /// Global default temperature now lives in the JSON-backed GlobalSettingsStore.
    /// Observing the store keeps the slider fallback in sync when the global
    /// temperature changes elsewhere in Settings.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    /// Convenience value that already respects model-specific defaults.
    private var fallbackTemperature: Double {
        model.defaultTemperature ?? globalSettings.modelTemperature()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                diffToggle
                streamToggle
                responsesToggle
                Spacer()
            }

            Divider()
                .background(Color.secondary.opacity(0.3))

            temperatureField
        }
        .padding(.vertical, 4)
    }

    private var diffToggle: some View {
        LabeledToggle(
            label: "Allow Diff Editing",
            isOn: Binding(
                get: { overrides.diffOverride(for: model.rawValue) ?? ModelOverridesSettingsView.defaultDiff(for: model) },
                set: { overrides.setDiffOverride(for: model.rawValue, value: $0) }
            ),
            fontPreset: fontPreset
        )
    }

    private var streamToggle: some View {
        LabeledToggle(
            label: "Use Streaming",
            isOn: Binding(
                get: { overrides.streamOverride(for: model.rawValue) ?? (model == .o1Preview ? false : true) },
                set: { overrides.setStreamOverride(for: model.rawValue, value: $0) }
            ),
            fontPreset: fontPreset
        )
    }

    @ViewBuilder
    private var responsesToggle: some View {
        // Only render the toggle for custom provider models
        switch model {
        case .customProvider(_, _, _), .customProviderUser:
            LabeledToggle(
                label: "Use Responses-API",
                isOn: Binding(
                    get: {
                        overrides.responsesOverride(for: model.rawValue) ?? false
                    },
                    set: { overrides.setResponsesOverride(for: model.rawValue, value: $0) }
                ),
                fontPreset: fontPreset
            )
        default:
            EmptyView()
        }
    }

    private var temperatureField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Temperature")
                    .font(fontPreset.subheadlineFont)
                Spacer()
                if let temp = overrides.temperatureOverride(for: model.rawValue) {
                    Text(String(format: "%.1f", temp))
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    Text(String(format: "Default (%.1f)", fallbackTemperature))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            HStack {
                Text("0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 25)

                Slider(
                    value: Binding(
                        get: {
                            overrides.temperatureOverride(for: model.rawValue) ?? fallbackTemperature
                        },
                        set: { newValue in
                            overrides.setTemperatureOverride(for: model.rawValue, value: newValue)
                        }
                    ),
                    in: 0.0 ... 2.0,
                    step: 0.1
                )
                .accentColor(.blue)

                Text("2.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 25)

                Button("Reset") {
                    overrides.setTemperatureOverride(for: model.rawValue, value: nil)
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
        }
    }
}

/// Helper to reduce view depth for toggles
private struct LabeledToggle: View {
    let label: String
    @Binding var isOn: Bool
    let fontPreset: FontScalePreset

    init(label: String, isOn: Binding<Bool>, fontPreset: FontScalePreset) {
        self.label = label
        _isOn = isOn
        self.fontPreset = fontPreset
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .labelsHidden()
                .scaleEffect(0.8)
        }
    }
}
