import AppKit
import SwiftUI

/// Popover content for agent handoff configuration.
/// Lets the user pick destination agent/model, copy the handoff payload, or execute handoff.
struct AgentHandoffPopover: View {
    let config: AgentHandoffConfig
    let dismiss: () -> Void

    @State private var selectedAgent: AgentProviderKind
    @State private var selectedModelRaw: String
    @State private var selectedReasoningEffortRaw: String?
    @State private var isLoading = false
    @State private var isCopying = false
    @State private var showCopied = false
    @State private var errorMessage: String?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(340, max: 460)
    }

    init(config: AgentHandoffConfig, dismiss: @escaping () -> Void) {
        self.config = config
        self.dismiss = dismiss
        let initialSelection = Self.initialSelection(for: config)
        _selectedAgent = State(initialValue: initialSelection.agent)
        _selectedModelRaw = State(initialValue: initialSelection.modelRaw)
        _selectedReasoningEffortRaw = State(initialValue: initialSelection.reasoningEffortRaw)
    }

    private var availableAgents: [AgentProviderKind] {
        config.availableAgentsProvider()
    }

    private var allCurrentOptions: [AgentModelOption] {
        config.modelOptionsProvider(selectedAgent)
    }

    private var selectedModelOption: AgentModelOption? {
        Self.option(matching: selectedModelRaw, in: allCurrentOptions)
    }

    private var reasoningEffortOptions: [CodexReasoningEffort] {
        selectedModelOption?.supportedReasoningEfforts ?? []
    }

    private var showReasoningEffort: Bool {
        selectedAgent == .codexExec && !reasoningEffortOptions.isEmpty
    }

    private var chipColor: Color {
        Color.secondary.opacity(0.1)
    }

    private var selectedModelDisplayName: String {
        selectedModelOption?.displayName ?? selectedModelRaw
    }

    private var canPerformHandoff: Bool {
        availableAgents.contains(selectedAgent) && !allCurrentOptions.isEmpty
    }

    private var providerChipTitle: String {
        guard availableAgents.contains(selectedAgent) else {
            return availableAgents.isEmpty ? "No connected CLI providers" : "Choose agent"
        }
        return "\(selectedAgent.displayName) \u{00B7} \(selectedModelDisplayName)"
    }

    private var isSelectedCodexSpeedTier: Bool {
        AgentModelSelectionWarningVisuals.showsWarning(agent: selectedAgent, rawModel: selectedModelRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handoff to New Chat")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))

            Text("Migrates this session's context and Oracle chats to a new agent. The agent will pick up where it left off.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("New Chat Agent")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Menu {
                        if availableAgents.isEmpty {
                            Button("No connected CLI providers") {}
                                .disabled(true)
                        } else {
                            ForEach(availableAgents, id: \.self) { agent in
                                Menu(agent.displayName) {
                                    handoffModelMenuContent(for: agent)
                                }
                            }
                        }
                        AgentProviderSettingsMenuSection(availableAgents: availableAgents, windowID: config.windowID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: selectedAgent.iconName)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            if isSelectedCodexSpeedTier {
                                AgentModelSpeedIcon(
                                    agent: selectedAgent, rawModel: selectedModelRaw,
                                    font: fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold)
                                )
                            }
                            Text(providerChipTitle)
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(isSelectedCodexSpeedTier ? AgentModelSelectionWarningVisuals.color(agent: selectedAgent, rawModel: selectedModelRaw) : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chipColor)
                        .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)

                    if showReasoningEffort {
                        Menu {
                            ForEach(reasoningEffortOptions, id: \.rawValue) { effort in
                                Button {
                                    selectedReasoningEffortRaw = effort.rawValue
                                } label: {
                                    HStack {
                                        Text(effort.rawValue.capitalized)
                                        if selectedReasoningEffortRaw == effort.rawValue {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedReasoningEffortRaw?.capitalized ?? "Default")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(chipColor)
                            .cornerRadius(4)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                if availableAgents.isEmpty {
                    Text("Connect a CLI provider in Settings before handing off to a new agent.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.red)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task {
                        isCopying = true
                        let payload = await config.buildPayloadForClipboard()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload, forType: .string)
                        isCopying = false
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isCopying {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        }
                        Text(showCopied ? "Copied!" : "Copy Payload")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(showCopied ? .green : .accentColor)
                .disabled(isLoading || isCopying)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .disabled(isLoading)

                Button {
                    Task {
                        isLoading = true
                        errorMessage = nil
                        let selection = AgentHandoffSelection(
                            agent: selectedAgent,
                            modelRaw: selectedModelRaw,
                            reasoningEffortRaw: showReasoningEffort ? selectedReasoningEffortRaw : nil
                        )
                        do {
                            try await config.performHandoff(selection)
                            dismiss()
                        } catch {
                            errorMessage = "Handoff failed: \(error.localizedDescription)"
                            isLoading = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text("Handoff")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(canPerformHandoff ? Color.accentColor : Color.secondary.opacity(0.25))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isLoading || !canPerformHandoff)
            }
        }
        .padding(16)
        .frame(width: popoverWidth)
        .onAppear {
            reconcileSelectionWithAvailability()
        }
        .onChange(of: availableAgents) { _, _ in
            reconcileSelectionWithAvailability()
        }
    }

    @ViewBuilder
    private func handoffModelMenuContent(for agent: AgentProviderKind) -> some View {
        let options = Self.visibleModelOptions(config.modelOptionsProvider(agent))
        if options.isEmpty {
            Button("No models available") {}
                .disabled(true)
        } else {
            AgentModelOptionsMenuContent(
                agentKind: agent,
                options: options,
                selectedAgent: selectedAgent,
                selectedModelRaw: selectedModelRaw
            ) { agent, model in
                selectHandoffModel(model, for: agent)
            }
        }
    }

    private func selectHandoffModel(_ model: AgentModelOption, for agent: AgentProviderKind) {
        selectedAgent = agent
        selectedModelRaw = model.rawValue
        selectedReasoningEffortRaw = agent == .codexExec
            ? Self.codexReasoningEffortRaw(
                modelRaw: model.rawValue,
                preferredReasoningEffortRaw: nil,
                option: model
            )
            : nil
    }

    private func reconcileSelectionWithAvailability() {
        let agents = availableAgents
        guard let agent = agents.contains(selectedAgent) ? selectedAgent : agents.first else { return }
        if selectedAgent != agent {
            selectedAgent = agent
        }

        let options = config.modelOptionsProvider(agent)
        guard !options.isEmpty else { return }
        guard Self.option(matching: selectedModelRaw, in: options) == nil else { return }

        let fallbackModelRaw = Self.initialModelRaw(
            for: agent,
            preferredModelRaw: agent == config.defaultDestinationAgent ? config.defaultModelRaw : nil,
            config: config
        )
        selectedModelRaw = fallbackModelRaw
        selectedReasoningEffortRaw = Self.initialReasoningEffortRaw(
            for: agent,
            modelRaw: fallbackModelRaw,
            preferredReasoningEffortRaw: agent == config.defaultDestinationAgent ? config.defaultReasoningEffortRaw : nil,
            config: config
        )
    }

    private static func initialSelection(for config: AgentHandoffConfig) -> AgentHandoffSelection {
        let agents = config.availableAgentsProvider()
        let agent = agents.contains(config.defaultDestinationAgent)
            ? config.defaultDestinationAgent
            : (agents.first ?? config.defaultDestinationAgent)
        let modelRaw = initialModelRaw(
            for: agent,
            preferredModelRaw: agent == config.defaultDestinationAgent ? config.defaultModelRaw : nil,
            config: config
        )
        let reasoningEffortRaw = initialReasoningEffortRaw(
            for: agent,
            modelRaw: modelRaw,
            preferredReasoningEffortRaw: agent == config.defaultDestinationAgent ? config.defaultReasoningEffortRaw : nil,
            config: config
        )
        return AgentHandoffSelection(agent: agent, modelRaw: modelRaw, reasoningEffortRaw: reasoningEffortRaw)
    }

    private static func initialModelRaw(
        for agent: AgentProviderKind,
        preferredModelRaw: String?,
        config: AgentHandoffConfig
    ) -> String {
        let options = config.modelOptionsProvider(agent)
        if let preferredModelRaw,
           let option = option(matching: preferredModelRaw, in: options)
        {
            return option.rawValue
        }
        return visibleModelOptions(options).first?.rawValue
            ?? options.first?.rawValue
            ?? preferredModelRaw
            ?? config.defaultModelRaw
    }

    private static func initialReasoningEffortRaw(
        for agent: AgentProviderKind,
        modelRaw: String,
        preferredReasoningEffortRaw: String?,
        config: AgentHandoffConfig
    ) -> String? {
        guard agent == .codexExec else { return nil }
        let option = option(matching: modelRaw, in: config.modelOptionsProvider(agent))
        return codexReasoningEffortRaw(
            modelRaw: modelRaw,
            preferredReasoningEffortRaw: preferredReasoningEffortRaw,
            option: option
        )
    }

    private static func codexReasoningEffortRaw(
        modelRaw: String,
        preferredReasoningEffortRaw: String?,
        option: AgentModelOption?
    ) -> String {
        let supportedEfforts = option?.supportedReasoningEfforts ?? []
        func acceptedRaw(_ effort: CodexReasoningEffort?) -> String? {
            guard let effort else { return nil }
            guard supportedEfforts.isEmpty || supportedEfforts.contains(effort) else { return nil }
            return effort.rawValue
        }

        return acceptedRaw(CodexReasoningEffort.parse(preferredReasoningEffortRaw))
            ?? acceptedRaw(option?.defaultReasoningEffort)
            ?? acceptedRaw(CodexAgentToolPreferences.lastUsedReasoningEffort(forModelRaw: modelRaw))
            ?? acceptedRaw(.medium)
            ?? supportedEfforts.first?.rawValue
            ?? CodexReasoningEffort.medium.rawValue
    }

    private static func visibleModelOptions(_ options: [AgentModelOption]) -> [AgentModelOption] {
        let filtered = options.filter { !$0.isPlaceholderDefault }
        return filtered.isEmpty ? options : filtered
    }

    private static func option(matching rawValue: String, in options: [AgentModelOption]) -> AgentModelOption? {
        options.first { $0.rawValue.caseInsensitiveCompare(rawValue) == .orderedSame }
    }
}
