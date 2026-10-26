import AppKit
import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    @ObservedObject private var settingsWindowCoordinator = SettingsWindowCoordinator.shared
    @StateObject private var viewState = RouterSettingsViewState()
    var onNavigate: ((SettingsTab) -> Void)?

    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedServiceHeaderID: DecisionServiceID?
    @AccessibilityFocusState private var accessibilityFocusedServiceHeaderID: DecisionServiceID?
    @FocusState private var focusedServiceConfigurationInputID: DecisionServiceID?
    @AccessibilityFocusState private var accessibilityFocusedServiceConfigurationInputID: DecisionServiceID?
    @State private var customInstructionsDraft = ""
    @State private var customInstructionsFeedback: String?
    @State private var sectionNavigationRequest: SectionNavigationRequest?

    private struct SectionNavigationRequest: Equatable {
        let section: SettingsWindowCoordinator.AgentDecisionsSection
        let token = UUID()
    }

    private static func configurationInputAnchorID(for backendID: DecisionServiceID) -> String {
        "router-service-\(backendID.rawValue)-configuration-input"
    }

    init(viewModel: RouterSettingsViewModel, onNavigate: ((SettingsTab) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onNavigate = onNavigate
    }

    @State private var showClaudeRefreshConsent = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    pageHeader
                    modelRouterSection
                        .id(SettingsWindowCoordinator.AgentDecisionsSection.modelRouter)
                    autoEffortSection
                        .id(SettingsWindowCoordinator.AgentDecisionsSection.autoEffort)
                    usageBalancingCard
                    routingServicesSection
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .task(id: sectionNavigationRequest?.token) {
                guard let request = sectionNavigationRequest else { return }
                await Task.yield()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(request.section, anchor: .top)
                }
            }
            .onChange(of: viewState.configureRequest) { _, request in
                guard let request else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard viewState.configureRequest?.token == request.token else { return }
                    withAnimation(
                        reduceMotion ? nil : .easeInOut(duration: 0.2),
                        completionCriteria: .logicallyComplete
                    ) {
                        proxy.scrollTo(Self.configurationInputAnchorID(for: request.backendID), anchor: .center)
                    } completion: {
                        guard viewState.configureRequest?.token == request.token else { return }
                        focusedServiceConfigurationInputID = request.backendID
                        accessibilityFocusedServiceConfigurationInputID = request.backendID
                    }
                }
            }
        }
        .task(id: settingsWindowCoordinator.pendingAgentDecisionsSectionRequest?.token) {
            acceptPendingSectionNavigation()
        }
        .task {
            await viewModel.refresh()
            customInstructionsDraft = viewModel.configuration.customInstructions
        }
        .alert("Refresh Claude usage in the background?", isPresented: $showClaudeRefreshConsent) {
            Button("Enable") { viewModel.setClaudeBackgroundRefreshEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While RepoPrompt is active and usage balancing is on, routing activity can refresh plan usage through Claude Code’s /usage command and status line. No model prompt is sent. Claude may retain normal session bookkeeping. Background checks are limited to once per 30 minutes and 12 per rolling day for this profile; there is no idle polling. Connected usage also retains its one-time startup check and manual Refresh. This CLI integration is not an official third-party usage API. You can turn it off at any time.")
        }
        .onDisappear {
            viewState.clearAllSecretDrafts()
        }
    }

    private func acceptPendingSectionNavigation() {
        guard let request = settingsWindowCoordinator.pendingAgentDecisionsSectionRequest,
              let section = settingsWindowCoordinator.consumeAgentDecisionsSectionRequest(token: request.token)
        else { return }
        sectionNavigationRequest = SectionNavigationRequest(section: section)
    }

    private var usageBalancingCard: some View {
        card {
            HStack(alignment: .top, spacing: 16) {
                sectionHeader(
                    title: "Usage Balancing",
                    systemImage: "scale.3d",
                    description: viewModel.usageBalancingStatus
                )
                .layoutPriority(1)
                Spacer(minLength: 12)
                Toggle("Usage balancing", isOn: Binding(get: { viewModel.configuration.usageBalancing.enabled }, set: viewModel.setUsageBalancingEnabled))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("Usage balancing")
                    .fixedSize()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Strategy")
                    .font(.headline)
                Picker("Strategy", selection: Binding(get: { viewModel.configuration.usageBalancing.preset }, set: viewModel.setUsageBalancingPreset)) {
                    ForEach(AgentUsageBalancingPreset.allCases) { preset in Text(preset.title).tag(preset) }
                }.pickerStyle(.segmented)
                Text(viewModel.configuration.usageBalancing.preset.explanation).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Model Router when usage is critical", isOn: Binding(get: { viewModel.configuration.usageBalancing.overrideRouter }, set: viewModel.setUsageBalancingOverride))
                    .disabled(!viewModel.configuration.usageBalancing.enabled)
                Text("Critical means one plan has at least 25% of its weekly allowance resetting within 48 hours, has 1.75× the other plan’s unused allowance for its remaining time, or the other plan is 90% used. New tasks then go only to that provider; Model Router picks the model and effort within it, and is skipped when only one model qualifies. Otherwise Model Router and the strategy above are mixed.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Manage plan usage…") { onNavigate?(.cliProviders) }.buttonStyle(.bordered)
            Divider()
            settingsDisclosure("What Usage Balancing shares", systemImage: "hand.raised", id: "usage-balancing:refresh-privacy", prominent: true) {
                Text("Usage stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            settingsDisclosure("How Usage Balancing Works", id: "usage-balancing:details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compares each plan’s own allowance and reset time—not token capacities. Only comparable models are substituted. Explicit MCP model pins and existing sessions are unchanged.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                    Toggle("Refresh Claude usage in the background", isOn: Binding(get: { viewModel.claudeBackgroundRefreshEnabled }, set: { enabled in
                        if enabled { showClaudeRefreshConsent = true } else { viewModel.setClaudeBackgroundRefreshEnabled(false) }
                    }))
                    .disabled(!viewModel.claudeUsageConnected)
                    Text("After task activity while the app is active: Claude at most once per 30 minutes and 12 times per day; Codex at most once per 10 minutes. No idle polling or waiting for a refresh.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }

    private var automaticFastControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow paid Fast tiers in automatic routing", isOn: Binding(get: { viewModel.configuration.allowPaidFastRouting }, set: viewModel.setAllowPaidFastRouting))
            Text("Off by default. Fast can consume allowance or credits more quickly. Models you explicitly pick yourself are unaffected.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Agent Decisions")
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundColor(.accentColor)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .bold))
            Text("Configure model routing, local usage balancing, automatic effort, and decision services.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelRouterSection: some View {
        card {
            sectionHeader(
                title: "Model Router",
                systemImage: "arrow.triangle.branch",
                description: "Let the selected decision service choose the best available model and provider for each new task."
            )
            Divider()
            modelRouterFeatureHeader
            routingServiceControl
            automaticFastControl
            routingBehaviorDisclosure
            Divider()
            routerSharingSummary
            routerFallbackDisclosure
        }
    }

    private var modelRouterFeatureHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            modelRouterStatus
                .layoutPriority(1)
            Spacer(minLength: 12)
            modelRouterToggle
        }
    }

    private var modelRouterStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: readinessIcon)
                .font(.title3)
                .foregroundStyle(modelRouterStatusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(modelRouterStatusTitle)
                    .font(.headline)
                Text(modelRouterStatusDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model Router status")
        .accessibilityValue("\(modelRouterStatusTitle). \(modelRouterStatusDetail)")
    }

    private var modelRouterToggle: some View {
        Toggle("Enable Model Router", isOn: Binding(
            get: { viewModel.configuration.enabled },
            set: viewModel.setEnabled
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("Enable Model Router")
        .disabled(!viewModel.canEnable && !viewModel.configuration.enabled)
        .fixedSize()
        .modifier(ConfigurationRequiredCursor(readiness: viewModel.readiness))
    }

    private struct ConfigurationRequiredCursor: ViewModifier {
        let readiness: DecisionReadiness
        @State private var isHovering = false
        @State private var ownsCursor = false

        private var needsConfiguration: Bool {
            if case .needsConfiguration = readiness { return true }
            return false
        }

        func body(content: Content) -> some View {
            content
                .onHover { hovering in
                    isHovering = hovering
                    updateCursor()
                }
                .onChange(of: needsConfiguration) { _, _ in updateCursor() }
                .onDisappear {
                    if ownsCursor {
                        NSCursor.arrow.set()
                        ownsCursor = false
                    }
                }
        }

        private func updateCursor() {
            if isHovering, needsConfiguration {
                NSCursor.operationNotAllowed.set()
                ownsCursor = true
            } else if ownsCursor {
                NSCursor.arrow.set()
                ownsCursor = false
            }
        }
    }

    private var routingServiceControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decision service")
                .font(.headline)
            responsiveServiceControls(
                picker: { routingServicePicker },
                configure: {
                    if selectedServiceNeedsConfiguration {
                        configureSelectedServiceButton
                    }
                }
            )
            if selectedConfigurableServiceRow == nil {
                Text(selectedServiceUnavailableDetail)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func responsiveServiceControls(
        @ViewBuilder picker: () -> some View,
        @ViewBuilder configure: () -> some View
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                picker()
                configure()
            }
            VStack(alignment: .leading, spacing: 8) {
                picker()
                configure()
            }
        }
    }

    private var routingServicePicker: some View {
        Picker("Decision service", selection: selectedBackendBinding) {
            if viewModel.selectedBackendID == nil {
                Text("Choose a service…").tag(DecisionServiceID?.none)
            }
            if let selected = viewModel.selectedBackendID,
               !viewModel.backendOptions.contains(where: { $0.id == selected })
            {
                Text("\(selected.rawValue) (unavailable)").tag(Optional(selected))
            }
            ForEach(viewModel.backendOptions) { option in
                Text(option.displayName).tag(Optional(option.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityHint("Selects the decision service used by Model Router")
    }

    private var configureSelectedServiceButton: some View {
        Button("Configure") {
            guard let row = selectedConfigurableServiceRow else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                viewState.requestConfigure(row.id)
            }
        }
        .disabled(selectedConfigurableServiceRow == nil)
        .accessibilityLabel(
            selectedConfigurableServiceRow.map { "Configure \($0.displayName)" }
                ?? "Configure selected decision service"
        )
    }

    private var targetAvailability: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Router chooses from the available models below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Available models")
                .font(.headline)
            modelTags
            if viewModel.availableProviders.isEmpty {
                Text("No curated execution targets are currently available. Check the Codex or Claude CLI setup and model availability.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !viewModel.unavailableTargetPreviews.isEmpty {
                Text("Unavailable models")
                    .font(.headline)
                    .padding(.top, 4)
                unavailableModelTags
            }
        }
    }

    private func routingTagRow(@ViewBuilder content: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                content()
            }
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelTags: some View {
        routingTagRow {
            ForEach(viewModel.modelTagPreviews) { preview in
                Text(Self.modelTagLabel(for: preview))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.modelTagLabel(for: preview)) model")
                    .accessibilityValue(Self.modelTagAccessibilityValue(for: preview))
                    .hoverTooltip(Self.modelTagHelp(for: preview))
            }
        }
    }

    private var unavailableModelTags: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(unavailableModelReasons, id: \.self) { reason in
                Text(reason)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
                    .foregroundStyle(.secondary)
                routingTagRow {
                    ForEach(viewModel.unavailableTargetPreviews.filter { $0.reason == reason }) { preview in
                        Text(preview.displayName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                            .opacity(0.65)
                            .fixedSize()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(preview.displayName) model unavailable")
                            .accessibilityValue(preview.reason)
                            .hoverTooltip("\(preview.displayName) is unavailable. \(preview.reason)")
                    }
                }
            }
        }
    }

    private var unavailableModelReasons: [String] {
        var seen: Set<String> = []
        return viewModel.unavailableTargetPreviews.compactMap { preview in
            seen.insert(preview.reason).inserted ? preview.reason : nil
        }
    }

    private var routingBehaviorDisclosure: some View {
        settingsDisclosure("Routing configuration", systemImage: "slider.horizontal.3", id: "model-router:routing-behavior", prominent: true) {
            VStack(alignment: .leading, spacing: 12) {
                targetAvailability
                Divider()
                Text("Custom guidance")
                    .font(.headline)
                Text("Use this for routing directives such as “Prefer Claude Opus for execution, use GPT Astra sparingly, consult Fable for hard decisions.” Saved guidance shapes the selected decision service’s recommendation among the curated models. When usage balancing is enabled, it may then select a comparable model on the other plan.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $customInstructionsDraft)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .frame(minHeight: 70, maxHeight: 110)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .accessibilityLabel("Custom routing guidance")
                ViewThatFits(in: .horizontal) {
                    HStack {
                        customGuidanceCount
                        Spacer()
                        customGuidanceFeedback
                        saveGuidanceButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            customGuidanceCount
                            Spacer()
                            customGuidanceFeedback
                        }
                        saveGuidanceButton
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    static func modelTagLabel(for preview: RouterSettingsViewModel.TargetPreview) -> String {
        preview.familyDisplayName ?? preview.displayName
    }

    static func modelTagAccessibilityValue(for preview: RouterSettingsViewModel.TargetPreview) -> String {
        let effort = preview.target.reasoningEffortRaw ?? "model default effort"
        return "\(preview.provider.displayName) target \(preview.target.modelRaw), \(effort)"
    }

    static func modelTagHelp(for preview: RouterSettingsViewModel.TargetPreview) -> String {
        let explicitEffort = preview.target.reasoningEffortRaw.map(humanReadableEffort)
        let targetLabel = explicitEffort.map { targetName(preview.displayName, removingEffortSuffix: $0) }
            ?? preview.displayName
        let effort = explicitEffort ?? "model default effort"
        return "Default target: \(targetLabel) — \(effort). Model Router chooses the model; Auto Effort may later adjust effort without changing model/cache identity."
    }

    private static func targetName(_ name: String, removingEffortSuffix effort: String) -> String {
        guard let suffixRange = name.range(of: effort, options: [.caseInsensitive, .backwards]),
              suffixRange.upperBound == name.endIndex,
              suffixRange.lowerBound > name.startIndex
        else { return name }

        let prefix = name[..<suffixRange.lowerBound]
        guard prefix.last?.isWhitespace == true || prefix.last.map("—–-:".contains) == true else { return name }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-:"))
        let trimmed = String(prefix).trimmingCharacters(in: separators)
        return trimmed.isEmpty ? name : trimmed
    }

    private static func humanReadableEffort(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "xhigh": "Extra high"
        case "model_default", "provider-default": "model default effort"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var customGuidanceCount: some View {
        Text("\(customInstructionsDraft.count)/1000")
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundStyle(customInstructionsDraft.count > 1000 ? Color.red : Color.secondary)
    }

    @ViewBuilder
    private var customGuidanceFeedback: some View {
        if let customInstructionsFeedback {
            Text(customInstructionsFeedback)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var saveGuidanceButton: some View {
        Button("Save Guidance") {
            if viewModel.setCustomInstructions(customInstructionsDraft) {
                customInstructionsDraft = viewModel.configuration.customInstructions
                customInstructionsFeedback = "Saved"
            } else {
                customInstructionsFeedback = "Guidance is too long"
            }
        }
        .disabled(
            customInstructionsDraft == viewModel.configuration.customInstructions
                || customInstructionsDraft.count > 1000
        )
    }

    private var routerSharingSummary: some View {
        settingsDisclosure("What Router shares", systemImage: "hand.raised", id: "model-router:sharing", prominent: true) {
            VStack(alignment: .leading, spacing: 8) {
                Text("For each new routed session, the selected decision service receives a short, best-effort-masked task excerpt, saved guidance, Agent Models role references, and candidate provider, model, and effort descriptions.")
                Text("Attached files, workspace context, file paths, chat history, tool results, and provider credentials are not included. Text entered directly in the task or saved guidance is shared, and masking can miss sensitive information.")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
    }

    private var routerFallbackDisclosure: some View {
        settingsDisclosure("How Model Router Works", id: "model-router:routing-fallback") {
            Text("Model Router chooses a provider, model, and initial effort level for each new routed task—even when Auto Effort is off. If Auto Effort is enabled, it can adjust effort for eligible follow-up messages. If routing is unavailable or no valid option is returned, your task uses the current selection or its agent-role default.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var autoEffortSection: some View {
        card {
            sectionHeader(
                title: "Auto Effort",
                systemImage: "gauge.open.with.lines.needle.33percent",
                iconWeight: .regular,
                description: "Let the selected decision service choose the best available model effort. Independent of Model Router."
            )
            Divider()
            autoEffortFeatureHeader
            autoEffortServiceControl
            Divider()
            settingsDisclosure("What Auto Effort shares", systemImage: "hand.raised", id: "auto-effort:sharing", prominent: true) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For each eligible message, the selected decision service receives a message excerpt, the selected model ID, available effort levels, and the category of any selected built-in workflow. RepoPrompt tries to mask sensitive information in the excerpt before sending it.")
                    Text("Workflow templates, attached files, tool results, and earlier conversation are not included. Masking can miss secrets or sensitive text; turn Auto Effort off for private tasks.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            }
            settingsDisclosure("How Auto Effort Works", id: "auto-effort:details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto Effort chooses a reasoning level for a supported model you explicitly select. The model must offer multiple effort levels. Default selections, model aliases, and custom workflows keep your manual effort setting.")
                    Text("It can run when a session starts through MCP or when you send a follow-up after a turn finishes. Sessions already routed by Model Router and messages sent while a turn is running keep their chosen effort.")
                    Text("Auto Effort has its own service selection. Changing Model Router’s service does not change it. If the decision service is unavailable or cannot choose a valid option, your manual effort setting is used. Changing effort may affect how the provider reuses cached work; savings are not guaranteed.")
                }
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }

    private var autoEffortFeatureHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            autoEffortStatus
                .layoutPriority(1)
            Spacer(minLength: 12)
            autoEffortToggle
        }
    }

    private var autoEffortStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: autoEffortReadinessIcon)
                .font(.title3)
                .foregroundStyle(autoEffortReadinessColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(autoEffortStatusTitle)
                    .font(.headline)
                Text(autoEffortStatusDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Auto Effort status")
        .accessibilityValue("\(autoEffortStatusTitle). \(autoEffortStatusDetail)")
    }

    private var autoEffortToggle: some View {
        Toggle("Enable Auto Effort", isOn: Binding(
            get: { viewModel.autoEffortEnabled },
            set: viewModel.setAutoEffortEnabled
        ))
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel("Enable Auto Effort")
        .disabled(!viewModel.canEnableAutoEffort && !viewModel.autoEffortEnabled)
        .fixedSize()
        .modifier(ConfigurationRequiredCursor(readiness: viewModel.autoEffortReadiness))
    }

    private var autoEffortServiceControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decision service")
                .font(.headline)
            responsiveServiceControls(
                picker: { autoEffortServicePicker },
                configure: {
                    if selectedAutoEffortServiceNeedsConfiguration {
                        configureAutoEffortServiceButton
                    }
                }
            )
            if selectedConfigurableAutoEffortRow == nil {
                Text("The selected decision service cannot be configured in this build. Keep the saved selection or choose an available service.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var autoEffortServicePicker: some View {
        Picker("Auto Effort decision service", selection: Binding(
            get: { viewModel.selectedAutoEffortBackendID },
            set: { if let id = $0 { viewModel.selectAutoEffortBackend(id) } }
        )) {
            if let selected = viewModel.selectedAutoEffortBackendID,
               !viewModel.autoEffortBackendOptions.contains(where: { $0.id == selected })
            {
                Text("\(selected.rawValue) (unavailable)").tag(Optional(selected))
            }
            if viewModel.selectedAutoEffortBackendID == nil {
                Text("\(viewModel.autoEffortConfiguration.selectedBackendRawValue ?? "Unknown") (unavailable)")
                    .tag(DecisionServiceID?.none)
            }
            ForEach(viewModel.autoEffortBackendOptions) { option in
                Text(option.displayName).tag(Optional(option.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityHint("Selects the decision service used by Auto Effort without changing Model Router")
    }

    private var configureAutoEffortServiceButton: some View {
        Button("Configure") {
            guard let row = selectedConfigurableAutoEffortRow else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                viewState.requestConfigure(row.id)
            }
        }
        .disabled(selectedConfigurableAutoEffortRow == nil)
        .accessibilityLabel(
            selectedConfigurableAutoEffortRow.map { "Configure \($0.displayName) for Auto Effort" }
                ?? "Configure selected decision service for Auto Effort"
        )
        .accessibilityHint("Expands the selected service card and moves focus to it")
    }

    private var routingServicesSection: some View {
        card {
            sectionHeader(
                title: "Decision Services",
                systemImage: "network",
                description: "Connect decision services to help RepoPrompt CE make supported choices."
            )
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.isPerformingBackendOperation {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Credential operation in progress")
                    }
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                ForEach(viewModel.serviceRows) { row in
                    if row.id == .openAIDecisions {
                        OpenAIDecisionsRouterServiceSettingsCard(
                            expansionState: viewState.openAIServiceExpansion,
                            viewModel: viewModel,
                            viewState: viewState,
                            secretDraftState: viewState.secretDraftState(for: row.id),
                            row: row,
                            usageLabels: usageLabels(for: row.id),
                            configurationInputAnchorID: Self.configurationInputAnchorID(for: row.id),
                            serviceHeaderFocus: $focusedServiceHeaderID,
                            serviceHeaderAccessibilityFocus: $accessibilityFocusedServiceHeaderID,
                            configurationInputFocus: $focusedServiceConfigurationInputID,
                            configurationInputAccessibilityFocus: $accessibilityFocusedServiceConfigurationInputID
                        )
                        .id(row.id)
                    } else {
                        RouterServiceSettingsCard(
                            viewModel: viewModel,
                            viewState: viewState,
                            secretDraftState: viewState.secretDraftState(for: row.id),
                            isExpanded: viewState.isServiceExpanded(row.id),
                            row: row,
                            usageLabels: usageLabels(for: row.id),
                            configurationInputAnchorID: Self.configurationInputAnchorID(for: row.id),
                            serviceHeaderFocus: $focusedServiceHeaderID,
                            serviceHeaderAccessibilityFocus: $accessibilityFocusedServiceHeaderID,
                            configurationInputFocus: $focusedServiceConfigurationInputID,
                            configurationInputAccessibilityFocus: $accessibilityFocusedServiceConfigurationInputID
                        )
                        .id(row.id)
                    }
                }
            }
        }
    }

    private func sectionHeader(
        title: String,
        systemImage: String,
        iconWeight: Font.Weight = .bold,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 18, weight: iconWeight))
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 18, weight: .bold))
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func settingsDisclosure(
        _ title: String,
        systemImage: String? = nil,
        id: String,
        prominent: Bool = false,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        let isExpanded = viewState.isDisclosureExpanded(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    viewState.setDisclosureExpanded(!isExpanded, disclosureID: id)
                }
            } label: {
                HStack(spacing: 8) {
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(prominent ? .headline : fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")

            RouterSettingsAccordionContent(isExpanded: isExpanded) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedBackendBinding: Binding<DecisionServiceID?> {
        Binding(get: { viewModel.selectedBackendID }, set: { id in
            if let id {
                viewModel.selectBackend(id)
            }
        })
    }

    private var selectedConfigurableServiceRow: RouterSettingsViewModel.ServiceRow? {
        guard let selectedBackendID = viewModel.selectedBackendID else { return nil }
        return viewModel.serviceRows.first {
            $0.id == selectedBackendID && $0.isModelRouterEligible && $0.presentation != nil
        }
    }

    private var selectedServiceNeedsConfiguration: Bool {
        selectedConfigurableServiceRow.map(serviceNeedsConfiguration) ?? false
    }

    private var selectedAutoEffortServiceNeedsConfiguration: Bool {
        selectedConfigurableAutoEffortRow.map(serviceNeedsConfiguration) ?? false
    }

    private func serviceNeedsConfiguration(_ row: RouterSettingsViewModel.ServiceRow) -> Bool {
        guard let state = viewModel.serviceState(for: row.id), case .needsConfiguration = state.readiness else { return false }
        return true
    }

    private var selectedConfigurableAutoEffortRow: RouterSettingsViewModel.ServiceRow? {
        guard let id = viewModel.selectedAutoEffortBackendID else { return nil }
        return viewModel.serviceRows.first {
            $0.id == id && $0.isAutoEffortEligible && $0.presentation != nil
        }
    }

    private var selectedServiceUnavailableDetail: String {
        if let raw = viewModel.configuration.selectedBackendRawValue, !raw.isEmpty {
            return "The selected decision service cannot be configured in this build. Choose an available service or keep the saved selection unchanged."
        }
        return "Choose a decision service before configuring it."
    }

    private func usageLabels(for backendID: DecisionServiceID) -> [String] {
        var labels: [String] = []
        if backendID == viewModel.selectedBackendID {
            labels.append(viewModel.configuration.enabled ? "Used by Model Router" : "Selected for Model Router")
        }
        if viewModel.selectedAutoEffortBackendID == backendID {
            labels.append(viewModel.autoEffortEnabled ? "Used by Auto Effort" : "Selected for Auto Effort")
        }
        return labels
    }

    private var modelRouterStatusTitle: String {
        let prefix = viewModel.configuration.enabled ? "ON" : "OFF"
        switch viewModel.readiness {
        case .ready where viewModel.policyCanBuildCandidates:
            return viewModel.configuration.enabled ? "ON" : "READY — Ready to enable"
        case .ready:
            return viewModel.configuration.enabled
                ? "Paused — connect a supported execution provider"
                : "OFF — connect a supported execution provider"
        case .validating:
            return viewModel.configuration.enabled
                ? "Paused — checking decision service"
                : "OFF — checking decision service"
        case .needsConfiguration:
            return viewModel.configuration.enabled
                ? "Paused — decision service needs configuration"
                : "OFF — Needs configuration"
        case .policyUnavailable, .temporarilyUnavailable:
            return viewModel.configuration.enabled
                ? "Paused — decision service unavailable"
                : "\(prefix) — decision service unavailable"
        }
    }

    private var modelRouterStatusDetail: String {
        switch viewModel.readiness {
        case .ready where viewModel.policyCanBuildCandidates:
            viewModel.configuration.enabled
                ? "New sessions will now use Model Router. Existing sessions keep their current targets."
                : "The selected Decision Service is ready. Turn on switch to use."
        case .ready:
            "Connect a CLI provider to use Model Router."
        case .validating:
            "The selected decision service is validating its configuration."
        case let .needsConfiguration(_, reason):
            viewModel.configuration.enabled
                ? reason
                : configurationInstruction(for: viewModel.selectedBackendID)
        case let .policyUnavailable(_, reason),
             let .temporarilyUnavailable(_, reason):
            reason
        }
    }

    private var modelRouterStatusColor: Color {
        switch viewModel.readiness {
        case .ready where viewModel.policyCanBuildCandidates:
            viewModel.configuration.enabled ? .green : .secondary
        case .validating: .secondary
        case .ready, .needsConfiguration, .policyUnavailable: .orange
        case .temporarilyUnavailable: .red
        }
    }

    private var readinessIcon: String {
        if case .ready = viewModel.readiness, !viewModel.policyCanBuildCandidates {
            return "info.circle"
        }
        return viewModel.readiness.settingsSymbolName
    }

    private var autoEffortStatusTitle: String {
        let name = viewModel.selectedAutoEffortBackendID.flatMap { id in
            viewModel.serviceRows.first(where: { $0.id == id })?.displayName
        } ?? "Decision service"
        if viewModel.autoEffortEnabled {
            return viewModel.canEnableAutoEffort ? "ON" : "Paused — \(name) unavailable"
        }
        if case .needsConfiguration = viewModel.autoEffortReadiness {
            return "OFF — Needs configuration"
        }
        return viewModel.canEnableAutoEffort ? "READY — Ready to enable" : "OFF — configure \(name) to enable"
    }

    private var autoEffortStatusDetail: String {
        if !viewModel.autoEffortEnabled,
           case .needsConfiguration = viewModel.autoEffortReadiness
        {
            return configurationInstruction(for: viewModel.selectedAutoEffortBackendID)
        }
        if viewModel.autoEffortEnabled, !viewModel.canEnableAutoEffort {
            return "Eligible turns use manual effort until the selected service is ready."
        }
        if !viewModel.autoEffortEnabled, viewModel.canEnableAutoEffort {
            return "The selected Decision Service is ready. Turn on switch to use."
        }
        if viewModel.autoEffortEnabled {
            return "The selected Decision Service now chooses reasoning effort for eligible turns. Model selection remains unchanged."
        }
        return "The selected decision service chooses only reasoning effort for eligible turns; model selection remains unchanged."
    }

    private func configurationInstruction(for serviceID: DecisionServiceID?) -> String {
        guard let serviceID,
              let row = viewModel.serviceRows.first(where: { $0.id == serviceID })
        else { return "Choose and configure a Decision Service first." }
        let serviceName = row.displayName.replacingOccurrences(of: " by ", with: " ")
        return "Validate a \(serviceName) API key first."
    }

    private var autoEffortReadinessIcon: String {
        viewModel.autoEffortReadiness.settingsSymbolName
    }

    private var autoEffortReadinessColor: Color {
        switch viewModel.autoEffortReadiness {
        case .ready: viewModel.autoEffortEnabled ? .green : .secondary
        case .validating: .secondary
        case .needsConfiguration, .policyUnavailable: .orange
        case .temporarilyUnavailable: .red
        }
    }
}
