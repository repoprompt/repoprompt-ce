import SwiftUI

// MARK: - Recommendation Wizard Popover View

/// Main popover container for the recommendation wizard.
struct RecommendationWizardPopoverView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel
    var onDismiss: (() -> Void)?

    var body: some View {
        if viewModel.isLoading {
            // Loading state
            VStack(spacing: 0) {
                simpleHeader(title: "Setup Wizard", icon: "wand.and.stars")
                Divider()
                loadingView
            }
            .padding(16)
        } else if !viewModel.hasActiveRecommendations, !viewModel.hasWizardContentSteps, viewModel.currentStep == .intro {
            // No recommendations and no content steps - show simple status view
            statusOnlyView
        } else {
            // Has recommendations - show full wizard
            VStack(spacing: 0) {
                wizardHeader
                Divider()
                stepContent
                Divider()
                wizardFooter
            }
            .padding(16)
        }
    }

    // MARK: - Status Only View (when no recommendations)

    private var statusOnlyView: some View {
        VStack(spacing: 0) {
            simpleHeader(title: "Setup Status", icon: "checkmark.seal.fill")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Provider status summary
                    if let status = viewModel.providerStatus {
                        providerStatusGrid(status)
                    }

                    // Best models reference table
                    BestPracticesTableView(viewModel: viewModel)

                    // All good message
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Your setup looks good! All recommended settings are configured.")
                            .font(.subheadline)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)

                    // Show dismissed recommendations if any
                    if viewModel.recommendations.hasMutedDifferences {
                        dismissedRecommendationsSection
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 400)
            .frame(width: 400)
        }
        .padding(16)
    }

    // MARK: - Dismissed Recommendations Section

    private var dismissedRecommendationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dismissed Recommendations")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                if let chatRec = viewModel.recommendations.chatModel, chatRec.isMuted, !chatRec.alreadySatisfied {
                    dismissedRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Chat Model",
                        detail: "Recommended: \(chatRec.defaultBackend.displayName)",
                        kind: .chatModel
                    )
                }

                if let cbRec = viewModel.recommendations.contextBuilder, cbRec.isMuted, !cbRec.alreadySatisfied {
                    dismissedRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Context Builder",
                        detail: "Recommended: \(cbRec.recommendedAgent.displayName)",
                        kind: .contextBuilderAgent
                    )
                }

                if let mcpRec = viewModel.recommendations.mcpPresetExposure, mcpRec.isMuted, !mcpRec.alreadySatisfied {
                    dismissedRow(
                        icon: "slider.horizontal.3",
                        title: "MCP Presets",
                        detail: mcpRec.shouldTemporarilyDisablePresets ? "Recommended: Hide" : "Recommended: Show",
                        kind: .mcpPresetExposure
                    )
                }

                if let agentRec = viewModel.recommendations.mcpAgentDefaults, agentRec.isMuted, !agentRec.alreadySatisfied {
                    dismissedRow(
                        icon: "person.3.fill",
                        title: "Agent Role Defaults",
                        detail: roleDefaultsSummary(agentRec.recommendedRoleDefaults),
                        kind: .mcpAgentDefaults
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private func dismissedRow(icon: String, title: String, detail: String, kind: RecommendationKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer()

            Button(action: {
                viewModel.unmute(kind)
            }) {
                Text("Restore")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func simpleHeader(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)

            Text(title)
                .font(.headline)

            Spacer()

            RecommendationProviderFilterMenu(viewModel: viewModel)

            Button(action: { onDismiss?() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    private func providerStatusGrid(_ status: ProviderStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Status")
                .font(.subheadline.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                providerRow("Claude Code", status: status.claudeCodeCLI)
                providerRow("Codex CLI", status: status.codexCLI)
                providerRow("Cursor CLI", status: status.cursorCLI)
                providerRow("OpenAI API", status: status.openAI)
            }
        }
    }

    private func providerRow(_ name: String, status: ProviderStatusSnapshot.Availability) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status == .ready ? Color.green : (status == .configured ? Color.orange : Color.gray.opacity(0.5)))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption)
            Spacer()
        }
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack {
            if let step = viewModel.currentStep {
                Image(systemName: step.systemImage)
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.headline)
                    Text(viewModel.progressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            RecommendationProviderFilterMenu(viewModel: viewModel)

            Button(action: { onDismiss?() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Analyzing your setup...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(minHeight: 200)
    }

    // MARK: - Step Content

    private var stepContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch viewModel.currentStep {
                    case .intro:
                        IntroStepView(viewModel: viewModel)
                    case .chatModel:
                        ChatModelStepView(viewModel: viewModel)
                    case .contextBuilder:
                        ContextBuilderStepView(viewModel: viewModel)
                    case .presets:
                        PresetsStepView(viewModel: viewModel)
                    case .mcpAgentDefaults:
                        MCPAgentDefaultsStepView(viewModel: viewModel)
                    case .summary:
                        SummaryStepView(viewModel: viewModel)
                    case .none:
                        EmptyView()
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.currentStepIndex) { _ in
                // Scroll to the recommendation content when step changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("recommendationContent", anchor: .top)
                    }
                }
            }
        }
        .frame(minHeight: 350, maxHeight: 550)
        .frame(width: 448)
    }

    // MARK: - Footer

    private var wizardFooter: some View {
        HStack {
            // Back button
            if viewModel.canGoBack {
                Button("Back") {
                    viewModel.previousStep()
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Action buttons based on current step
            footerActions
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var footerActions: some View {
        switch viewModel.currentStep {
        case .intro:
            if viewModel.hasActiveRecommendations {
                Button("Quick Apply All") {
                    viewModel.applyAllRecommendations()
                    // Don't dismiss - applyAllRecommendations navigates to Summary
                }
                .buttonStyle(.plain)

                Button("Start Wizard") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Close") {
                    onDismiss?()
                }
                .buttonStyle(.borderedProminent)
            }

        case .chatModel, .contextBuilder, .presets:
            Button("Skip") {
                viewModel.skipCurrentStep()
            }
            .buttonStyle(.plain)

            Menu {
                Button("Mute this recommendation") {
                    viewModel.muteCurrentStep()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)

            Button("Apply & Next") {
                viewModel.applyCurrentStep()
            }
            .buttonStyle(.borderedProminent)

        case .mcpAgentDefaults:
            if let rec = viewModel.recommendations.mcpAgentDefaults, !rec.alreadySatisfied {
                Button("Skip") {
                    viewModel.skipCurrentStep()
                }
                .buttonStyle(.plain)

                Button("Configure…") {
                    viewModel.openAgentModeSettings()
                }
                .buttonStyle(.plain)

                Button("Apply Recommended & Next") {
                    viewModel.applyCurrentStep()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Configure…") {
                    viewModel.openAgentModeSettings()
                }
                .buttonStyle(.plain)

                Button("Next") {
                    viewModel.nextStep()
                }
                .buttonStyle(.borderedProminent)
            }

        case .summary:
            Button("Done") {
                viewModel.markCompleted()
                viewModel.resetToIntro()
            }
            .buttonStyle(.borderedProminent)

        case .none:
            EmptyView()
        }
    }
}

// MARK: - Intro Step View

private struct IntroStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Optimize your RepoPrompt setup based on your available providers and best practices.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if viewModel.isProviderFilterActive {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.accentColor)
                    Text("Recommendations limited to: \(viewModel.providerFilterSummary)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(8)
            }

            // Show recommendations first (most important)
            if viewModel.hasActiveRecommendations {
                recommendationsPreviewSection
                    .id("recommendationContent")
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Your setup looks good! No recommendations at this time.")
                        .font(.subheadline)
                }
                .padding(8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            // Provider status summary
            if let status = viewModel.providerStatus {
                providerStatusSection(status)

                // Show upgrade hint if missing key providers
                if status.codexCLI != .ready, status.openAI != .ready {
                    upgradeHintSection(status)
                }
            }

            // Best practices table (reference info, shown last)
            BestPracticesTableView(viewModel: viewModel)
        }
    }

    // MARK: - Recommendations Preview Section

    private var recommendationsPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("\(viewModel.actionableRecommendationCount) recommendations available")
                    .font(.subheadline.bold())
                Spacer()
            }

            // Show preview of each recommendation (only unsatisfied ones)
            VStack(alignment: .leading, spacing: 8) {
                if let chatRec = viewModel.recommendations.chatModel, viewModel.shouldShowChatModelRecommendation(chatRec) {
                    let recommendedOption = chatRec.option(for: chatRec.defaultBackend)
                    recommendationPreviewRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Oracle",
                        detail: recommendedOption?.description ?? chatRec.defaultBackend.displayName,
                        kind: .chatModel,
                        isMuted: chatRec.isMuted
                    )
                }

                if let cbRec = viewModel.recommendations.contextBuilder, !cbRec.alreadySatisfied {
                    recommendationPreviewRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Context Builder",
                        detail: "\(cbRec.recommendedAgent.displayName) + \(cbRec.recommendedModel.displayName)",
                        kind: .contextBuilderAgent,
                        isMuted: cbRec.isMuted
                    )
                }

                if let mcpRec = viewModel.recommendations.mcpPresetExposure, !mcpRec.alreadySatisfied {
                    recommendationPreviewRow(
                        icon: "slider.horizontal.3",
                        title: "MCP Presets",
                        detail: "Temporarily disable for wizard",
                        kind: .mcpPresetExposure,
                        isMuted: mcpRec.isMuted
                    )
                }

                if let agentRec = viewModel.recommendations.mcpAgentDefaults, !agentRec.alreadySatisfied {
                    recommendationPreviewRow(
                        icon: "person.3.fill",
                        title: "Agent Role Defaults",
                        detail: roleDefaultsSummary(agentRec.recommendedRoleDefaults),
                        kind: .mcpAgentDefaults,
                        isMuted: agentRec.isMuted
                    )
                }
            }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.08))
        .cornerRadius(8)
    }

    private func recommendationPreviewRow(icon: String, title: String, detail: String, kind: RecommendationKind, isMuted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(isMuted ? .secondary.opacity(0.5) : .accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(isMuted ? .secondary : .primary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(isMuted ? 0.6 : 1))
            }

            Spacer()

            if isMuted {
                Button(action: {
                    viewModel.unmute(kind)
                }) {
                    Text("Unmute")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: {
                    viewModel.muteAndSkip(kind)
                }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Dismiss this recommendation")
                .accessibilityLabel("Dismiss this recommendation")
            }
        }
        .opacity(isMuted ? 0.7 : 1)
    }

    private func providerStatusSection(_ status: ProviderStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Status")
                .font(.subheadline.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                providerStatusRow("Claude Code", status: status.claudeCodeCLI)
                providerStatusRow("Codex CLI", status: status.codexCLI)
                providerStatusRow("Cursor CLI", status: status.cursorCLI)
                providerStatusRow("OpenAI API", status: status.openAI)
            }
        }
    }

    private func providerStatusRow(_ name: String, status: ProviderStatusSnapshot.Availability) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption)
            Spacer()
        }
    }

    private func statusColor(_ status: ProviderStatusSnapshot.Availability) -> Color {
        switch status {
        case .ready: .green
        case .configured: .orange
        case .notConfigured: .gray.opacity(0.5)
        }
    }

    private func upgradeHintSection(_ status: ProviderStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.orange)
                Text("Unlock Best Experience")
                    .font(.caption.bold())
            }

            Text("For optimal results, connect Codex CLI for GPT-5.6 Sol recommendations. Add an OpenAI API key when you need an API-backed fallback for planning, context building, and review.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: {
                NotificationCenter.default.post(name: .showCLIProvidersTab, object: nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text("Open CLI Providers")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - Provider Filter Menu

private struct RecommendationProviderFilterMenu: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel
    @State private var showProviderPopover = false

    var body: some View {
        Button {
            showProviderPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isProviderFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(viewModel.providerFilterButtonTitle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption)
            .foregroundColor(viewModel.isProviderFilterActive ? .accentColor : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .hoverTooltip("Choose which providers the recommendation wizard can suggest")
        .popover(isPresented: $showProviderPopover, arrowEdge: .bottom) {
            RecommendationProviderFilterPopover(viewModel: viewModel)
        }
    }
}

private struct RecommendationProviderFilterPopover: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    private var allSelected: Bool {
        viewModel.enabledRecommendationProviders == Set(RecommendationProviderKind.allCases)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Providers for Recommendations")
                    .font(.subheadline.bold())
                Text("Unchecked providers will be excluded from model and agent recommendations.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(RecommendationProviderKind.allCases) { provider in
                    Toggle(
                        provider.displayName,
                        isOn: Binding(
                            get: { viewModel.isRecommendationProviderEnabled(provider) },
                            set: { _ in viewModel.toggleRecommendationProvider(provider) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                }
            }

            Divider()

            HStack {
                Button("Reset") {
                    viewModel.resetProviderFilterToAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(allSelected ? .secondary : .accentColor)
                .disabled(allSelected)

                Spacer()

                if viewModel.hasUnappliedProviderChanges {
                    Button("Apply") {
                        viewModel.applyProviderFilter()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Text("Apply")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Role Defaults Summary Helper

/// Produces a compact summary string for role defaults: "Explore → Codex GPT-5.6 Sol Low · ..."
private func roleDefaultsSummary(_ defaults: [MCPAgentRoleDefault]) -> String {
    defaults.map { "\($0.roleLabel.capitalized) → \($0.modelDisplayName)" }.joined(separator: " · ")
}

// MARK: - Best Practices Table View (Shared)

private struct BestPracticesTableView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.bestPracticesTitle)
                    .font(.subheadline.bold())
                Spacer()
                Link("See docs", destination: URL(string: "https://repoprompt.com/docs#s=workflows&ss=model-recommendations")!)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }

            ForEach(viewModel.bestPracticesUseCases, id: \.id) { useCase in
                HStack {
                    Text(useCase.title)
                        .font(.caption)
                        .frame(width: 120, alignment: .leading)
                    Text(useCase.modelLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(useCase.accessLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Chat Model Step View

private struct ChatModelStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your Oracle")
                .font(.headline)

            Text("Pick the model that handles planning, review, and follow-up conversations via ask_oracle and oracle_send.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let rec = viewModel.recommendations.chatModel {
                // Backend selection cards
                VStack(spacing: 12) {
                    if rec.claudeCodeOption != nil {
                        backendCard(.claudeCode, option: rec.claudeCodeOption!)
                    }
                    if rec.codexOption != nil {
                        backendCard(.codex, option: rec.codexOption!)
                    }
                    if rec.openAIOption != nil {
                        backendCard(.openAI, option: rec.openAIOption!)
                    }
                }
                .id("recommendationContent")

                // Explanation text - only show Codex vs OpenAI comparison when both are available
                if rec.openAIOption != nil, rec.codexOption != nil {
                    explanationSection
                }

                // Upgrade hint if not using the best option
                if let hint = rec.upgradeHint {
                    upgradeHintSection(hint)
                }
            }
        }
    }

    private func upgradeHintSection(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Want better results?")
                    .font(.caption.bold())
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    private func backendCard(_ backend: ChatBackendKind, option: ChatBackendOption) -> some View {
        Button {
            viewModel.userDidSelectBackend(backend)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(option.displayName)
                        .font(.headline)
                    Spacer()
                    if viewModel.selectedChatBackend == backend {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }

                Text(option.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ForEach(option.tradeoffs, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        viewModel.selectedChatBackend == backend
                            ? Color.accentColor.opacity(0.08)
                            : Color.primary.opacity(0.03)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        viewModel.selectedChatBackend == backend
                            ? Color.accentColor
                            : Color.primary.opacity(0.1),
                        lineWidth: viewModel.selectedChatBackend == backend ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which should I use?")
                .font(.subheadline.bold())
            Text(viewModel.codexVsOpenAIExplanation)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Context Builder Step View

private struct ContextBuilderStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Context Building")
                .font(.headline)

            Text("The context builder agent explores your codebase and selects relevant files for chat context.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let rec = viewModel.recommendations.contextBuilder {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text("Recommended Agent")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(rec.recommendedAgent.displayName)
                                .font(.headline)
                        }
                    }

                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text("Recommended Model")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(rec.recommendedModel.displayName)
                                .font(.headline)
                        }
                    }

                    Text(rec.rationale)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(8)

                    // Upgrade hint if not using the best option
                    if let hint = rec.upgradeHint {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Want better results?")
                                    .font(.caption.bold())
                                Text(hint)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(8)
                    }
                }
                .id("recommendationContent")
            }
        }
    }
}

// MARK: - Presets Step View

private struct PresetsStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP Chat Model")
                .font(.headline)

            Text("Configure which model handles MCP chat operations. The MCP chat model dropdown gives you direct control over model selection.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let rec = viewModel.recommendations.mcpPresetExposure {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.title)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(rec.shouldTemporarilyDisablePresets ? "Use MCP Chat Model Dropdown" : "Enable MCP Chat Model")
                                .font(.headline)
                            Text(rec.rationale)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(10)

                    Text("Your presets remain available in Settings and can be re-enabled anytime.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .id("recommendationContent")
            }
        }
    }
}

// MARK: - MCP Agent Defaults Step View

private struct MCPAgentDefaultsStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Role Defaults")
                .font(.headline)

            Text("When MCP clients start agents without specifying a model, these defaults are used based on the task role.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let rec = viewModel.recommendations.mcpAgentDefaults {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(zip(rec.currentRoleDefaults, rec.recommendedRoleDefaults)), id: \.0.roleLabel) { current, recommended in
                        roleDefaultRow(current: current, recommended: recommended, isMatch: current.selectionIDRaw == recommended.selectionIDRaw)
                    }
                }
                .id("recommendationContent")

                if let hint = rec.upgradeHint {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Want better defaults?")
                                .font(.caption.bold())
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                }
            }
        }
    }

    private func roleDefaultRow(current: MCPAgentRoleDefault, recommended: MCPAgentRoleDefault, isMatch: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconForRole(current.role))
                .font(.title3)
                .foregroundColor(colorForRole(current.role))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(current.roleLabel.uppercased())
                    .font(.caption.bold())
                Text(current.modelDisplayName)
                    .font(.subheadline)
                if !isMatch {
                    Text("Recommended: \(recommended.modelDisplayName)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text(current.roleDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isMatch {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(isMatch ? Color.primary.opacity(0.03) : Color.orange.opacity(0.06))
        .cornerRadius(8)
    }

    private func iconForRole(_ role: AgentModelCatalog.TaskLabelKind) -> String {
        switch role {
        case .explore: "magnifyingglass"
        case .engineer: "hammer.fill"
        case .pair: "person.2.fill"
        case .design: "paintbrush.fill"
        }
    }

    private func colorForRole(_ role: AgentModelCatalog.TaskLabelKind) -> Color {
        switch role {
        case .explore: .teal
        case .engineer: .blue
        case .pair: .purple
        case .design: .orange
        }
    }
}

// MARK: - Summary Step View

private struct SummaryStepView: View {
    @ObservedObject var viewModel: RecommendationWizardViewModel

    private var applied: RecommendationSet {
        viewModel.appliedRecommendations
    }

    private var hasAppliedAnything: Bool {
        applied.hasAny
    }

    /// Recommendations that were already satisfied before the wizard ran.
    private var alreadySatisfied: RecommendationSet {
        var result = RecommendationSet()
        let recs = viewModel.recommendations
        if let chat = recs.chatModel, chat.alreadySatisfied, !viewModel.shouldShowChatModelRecommendation(chat) {
            result.chatModel = chat
        }
        if let cb = recs.contextBuilder, cb.alreadySatisfied {
            result.contextBuilder = cb
        }
        if let mcp = recs.mcpPresetExposure, mcp.alreadySatisfied {
            result.mcpPresetExposure = mcp
        }
        if let agentDefaults = recs.mcpAgentDefaults, agentDefaults.alreadySatisfied {
            result.mcpAgentDefaults = agentDefaults
        }
        return result
    }

    private var hasAlreadySatisfied: Bool {
        alreadySatisfied.hasAny
    }

    /// Recommendations that are muted but differ from recommended.
    private var mutedDifferences: RecommendationSet {
        var result = RecommendationSet()
        let recs = viewModel.recommendations
        if let chat = recs.chatModel, chat.isMuted, !chat.alreadySatisfied {
            result.chatModel = chat
        }
        if let cb = recs.contextBuilder, cb.isMuted, !cb.alreadySatisfied {
            result.contextBuilder = cb
        }
        if let mcp = recs.mcpPresetExposure, mcp.isMuted, !mcp.alreadySatisfied {
            result.mcpPresetExposure = mcp
        }
        if let agentDefaults = recs.mcpAgentDefaults, agentDefaults.isMuted, !agentDefaults.alreadySatisfied {
            result.mcpAgentDefaults = agentDefaults
        }
        return result
    }

    private var hasMutedDifferences: Bool {
        mutedDifferences.hasAny
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
                Text(hasAppliedAnything ? "Setup Complete" : "All Set!")
                    .font(.headline)
                Spacer()
            }

            if hasAppliedAnything {
                Text("The following settings have been configured:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                appliedRecommendationsList
            }

            if hasAlreadySatisfied {
                Text(hasAppliedAnything ? "Already configured:" : "Your settings already match the recommended configuration:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                alreadySatisfiedList
            }

            if !hasAppliedAnything, !hasAlreadySatisfied, !hasMutedDifferences {
                Text("No recommendations available for your current setup.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Show muted recommendations that differ from recommended
            if hasMutedDifferences {
                Text("Muted recommendations (differ from suggested):")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                mutedDifferencesList
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What's Next?")
                    .font(.subheadline.bold())

                nextStepRow("Try the Context Builder", description: "Use the Context Builder in Compose view to auto-select relevant files")
                nextStepRow("Connect via MCP", description: "MCP agents can use context_builder to build smart file selections")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appliedRecommendationsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if applied.chatModel != nil {
                appliedRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Oracle",
                    detail: "Set to \(viewModel.selectedChatBackend.displayName)"
                )
            }

            if let cbRec = applied.contextBuilder {
                appliedRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Context Builder",
                    detail: "\(cbRec.recommendedAgent.displayName) + \(cbRec.recommendedModel.displayName)"
                )
            }

            if let mcpRec = applied.mcpPresetExposure {
                appliedRow(
                    icon: "slider.horizontal.3",
                    title: "MCP Presets",
                    detail: mcpRec.shouldTemporarilyDisablePresets ? "Temporarily hidden" : "Visible"
                )
            }

            if let agentRec = applied.mcpAgentDefaults {
                appliedRow(
                    icon: "person.3.fill",
                    title: "Agent Role Defaults",
                    detail: roleDefaultsSummary(agentRec.recommendedRoleDefaults)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .cornerRadius(10)
    }

    private var alreadySatisfiedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chatRec = alreadySatisfied.chatModel {
                satisfiedRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Oracle",
                    detail: chatRec.defaultBackend.displayName
                )
            }

            if let cbRec = alreadySatisfied.contextBuilder {
                satisfiedRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Context Builder",
                    detail: "\(cbRec.recommendedAgent.displayName) + \(cbRec.recommendedModel.displayName)"
                )
            }

            if let mcpRec = alreadySatisfied.mcpPresetExposure {
                satisfiedRow(
                    icon: "slider.horizontal.3",
                    title: "MCP Presets",
                    detail: mcpRec.shouldTemporarilyDisablePresets ? "Hidden" : "Visible"
                )
            }

            if let agentRec = alreadySatisfied.mcpAgentDefaults {
                satisfiedRow(
                    icon: "person.3.fill",
                    title: "Agent Role Defaults",
                    detail: roleDefaultsSummary(agentRec.currentRoleDefaults)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(10)
    }

    private func satisfiedRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark")
                .foregroundColor(.blue)
                .font(.caption)
        }
    }

    private var mutedDifferencesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chatRec = mutedDifferences.chatModel {
                mutedRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Oracle",
                    detail: "Recommended: \(chatRec.defaultBackend.displayName)",
                    kind: .chatModel
                )
            }

            if let cbRec = mutedDifferences.contextBuilder {
                mutedRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Context Builder",
                    detail: "Recommended: \(cbRec.recommendedAgent.displayName)",
                    kind: .contextBuilderAgent
                )
            }

            if let mcpRec = mutedDifferences.mcpPresetExposure {
                mutedRow(
                    icon: "slider.horizontal.3",
                    title: "MCP Presets",
                    detail: mcpRec.shouldTemporarilyDisablePresets ? "Recommended: Hide" : "Recommended: Show",
                    kind: .mcpPresetExposure
                )
            }

            if let agentRec = mutedDifferences.mcpAgentDefaults {
                mutedRow(
                    icon: "person.3.fill",
                    title: "Agent Role Defaults",
                    detail: roleDefaultsSummary(agentRec.recommendedRoleDefaults),
                    kind: .mcpAgentDefaults
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
        .cornerRadius(10)
    }

    private func mutedRow(icon: String, title: String, detail: String, kind: RecommendationKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: {
                viewModel.unmute(kind)
            }) {
                Text("Unmute")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func appliedRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func nextStepRow(_ title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.right.circle")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct RecommendationWizardPopoverView_Previews: PreviewProvider {
        static var previews: some View {
            // Preview requires full app context - use in-app testing instead
            Text("RecommendationWizardPopoverView")
                .frame(width: 440, height: 400)
        }
    }
#endif
