import SwiftUI

struct RouterSettingsView: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    var onNavigate: ((SettingsTab) -> Void)?
    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @State private var candidateSecret = ""
    @State private var customInstructionsDraft = ""
    @State private var customInstructionsFeedback: String?
    @State private var showClaudeRefreshConsent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                usageBalancingCard
                automaticFastCard
                statusCard
                autoEffortCard
                backendCard
                routingPolicyCard
                candidatesCard
                privacyNotice
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
            .frame(maxWidth: 740, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await viewModel.refresh()
            customInstructionsDraft = viewModel.configuration.customInstructions
        }
        .onChange(of: viewModel.selectedBackendID) { _, _ in candidateSecret = "" }
        .alert("Refresh Claude usage in the background?", isPresented: $showClaudeRefreshConsent) {
            Button("Enable") { viewModel.setClaudeBackgroundRefreshEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("While RepoPrompt is active and usage balancing is on, routing activity can refresh plan usage through Claude Code’s /usage command and status line. No model prompt is sent. Claude may retain normal session bookkeeping. Background checks are limited to once per 30 minutes and 12 per rolling day for this profile; there is no idle polling. Connected usage also retains its one-time startup check and manual Refresh. This CLI integration is not an official third-party usage API. You can turn it off at any time.")
        }
    }

    private var usageBalancingCard: some View {
        card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Usage balancing", systemImage: "scale.3d").font(.headline)
                    Text(viewModel.usageBalancingStatus).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Usage balancing", isOn: Binding(get: { viewModel.configuration.usageBalancing.enabled }, set: viewModel.setUsageBalancingEnabled))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("Usage balancing")
            }
            Picker("Strategy", selection: Binding(get: { viewModel.configuration.usageBalancing.preset }, set: viewModel.setUsageBalancingPreset)) {
                ForEach(AgentUsageBalancingPreset.allCases) { preset in Text(preset.title).tag(preset) }
            }.pickerStyle(.segmented)
            Text(viewModel.configuration.usageBalancing.preset.explanation).foregroundStyle(.secondary)
            Text("Compares each plan’s own allowance and reset time—not token capacities. Only comparable models are substituted. Explicit MCP model pins and existing sessions are unchanged; usage stays on this Mac.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
            Button("Manage plan usage…") { onNavigate?(.cliProviders) }.buttonStyle(.bordered)
            Toggle("Refresh Claude usage in the background", isOn: Binding(get: { viewModel.claudeBackgroundRefreshEnabled }, set: { enabled in
                if enabled { showClaudeRefreshConsent = true } else { viewModel.setClaudeBackgroundRefreshEnabled(false) }
            }))
            .disabled(!viewModel.claudeUsageConnected)
            Text("After task activity while the app is active: Claude at most once per 30 minutes and 12 times per day; Codex at most once per 10 minutes. No idle polling or waiting for a refresh.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
        }
    }

    private var automaticFastCard: some View {
        card {
            Toggle("Allow paid Fast tiers in automatic routing", isOn: Binding(get: { viewModel.configuration.allowPaidFastRouting }, set: viewModel.setAllowPaidFastRouting))
            Text("Off by default. Fast can consume allowance or credits more quickly. Models you explicitly pick yourself are unaffected.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11)).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Routing", systemImage: "arrow.triangle.branch")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .bold))
            Text("Balance plan usage locally, let Jev choose models, or use both.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: readinessIcon)
                    .font(.title3)
                    .foregroundStyle(viewModel.canEnable ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(readinessTitle).font(.headline)
                    Text(readinessDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Enable Model Router", isOn: Binding(
                    get: { viewModel.configuration.enabled },
                    set: viewModel.setEnabled
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!viewModel.canEnable && !viewModel.configuration.enabled)
                .accessibilityLabel("Enable Model Router")
            }
            if viewModel.canEnable || viewModel.configuration.enabled {
                Text("When enabled, Router chooses the target for every new primary session and RepoPrompt-managed subagent. Existing sessions keep their established target.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                Text("TypeSafe Jev receives task text to choose a model and effort. For long tasks, RepoPrompt sends only a short, best-effort masked excerpt from the beginning and end; the full task goes only to the selected agent. Masking can miss sensitive prose. If routing is unavailable or returns no valid choice, the task continues with the current selection or role default.")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var autoEffortCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Auto effort", systemImage: "brain.head.profile").font(.headline)
                    Text("Let Jev choose reasoning effort for the model you already selected, before an eligible user turn. Includes first MCP starts and settled follow-ups; starts already routed by Model Router and active steering keep their chosen effort. Model Router does not need to be on.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Auto effort", isOn: Binding(
                    get: { viewModel.autoEffortEnabled },
                    set: viewModel.setAutoEffortEnabled
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!viewModel.canEnableAutoEffort && !viewModel.autoEffortEnabled)
                .accessibilityLabel("Auto effort")
            }
            if viewModel.autoEffortEnabled, !viewModel.canEnableAutoEffort {
                Text("Paused until the Jev key is validated. Turns use your manual effort in the meantime.")
                    .foregroundStyle(.orange)
            }
            Text("Only explicitly selected supported models with multiple advertised effort levels are eligible. Default and alias selections keep manual effort.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
            Text("For each eligible composer or MCP user turn, TypeSafe Jev receives a short, best-effort masked excerpt of the message, the selected model ID, available effort choices, and the category of any selected built-in workflow. Workflow templates, attached files, tool results, and earlier conversation are not added. Custom workflows keep manual effort. Masking can miss secrets or sensitive prose; turn this off for private tasks.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If Jev is unavailable, your manual effort is used. Effort changes may affect provider caching; savings are not guaranteed.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
            Link("TypeSafe privacy policy", destination: URL(string: "https://typesafe.ai/legal/privacy-policy")!)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        }
    }

    private var routingPolicyCard: some View {
        card {
            Label("Routing behavior", systemImage: "slider.horizontal.3").font(.headline)
            Text("Optionally prefer one provider for a session type. Router uses that provider while it is authenticated, falls back to another connected provider when needed, and resumes the preference after it reconnects.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            providerLimitPicker("Primary sessions", scope: .primarySession)
            providerLimitPicker("Subagents", scope: .subagent)
            Divider()
            Text("Custom guidance").font(.headline)
            Text("Give Jev model preferences, such as “Prefer Claude Opus for execution.” Guidance shapes Jev’s starting choice. If usage balancing is also on, it can choose a comparable model on the other plan; provider restrictions remain enforced.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $customInstructionsDraft)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .frame(minHeight: 70, maxHeight: 110)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Text("\(customInstructionsDraft.count)/1000")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(customInstructionsDraft.count > 1000 ? Color.red : Color.secondary)
                Spacer()
                if let customInstructionsFeedback {
                    Text(customInstructionsFeedback)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundStyle(.secondary)
                }
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
        }
    }

    private func providerLimitPicker(
        _ title: String,
        scope: AgentTaskRoutingScope
    ) -> some View {
        Picker(title, selection: Binding(
            get: { viewModel.providerLimit(for: scope) },
            set: { viewModel.setProviderLimit($0, scope: scope) }
        )) {
            Text("Automatic (all connected)").tag(AgentProviderKind?.none)
            ForEach(viewModel.visibleProviders, id: \.rawValue) { provider in
                Text(
                    viewModel.providerIsAvailable(provider)
                        ? provider.displayName
                        : "\(provider.displayName) (authentication needed)"
                )
                .tag(Optional(provider))
            }
        }
        .pickerStyle(.menu)
    }

    private var backendCard: some View {
        card {
            Label("Routing service", systemImage: "network").font(.headline)
            if viewModel.backendOptions.count == 1, let service = viewModel.backendOptions.first {
                LabeledContent("Service") {
                    Text(service.displayName).fontWeight(.medium)
                }
            } else {
                Picker("Service", selection: selectedBackendBinding) {
                    if viewModel.selectedBackendID == nil {
                        Text("Choose a service…").tag(AgentTaskRouterBackendID?.none)
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
                .disabled(viewModel.isPerformingBackendOperation)
            }
            if let presentation = viewModel.backendSettingsPresentation {
                backendSettings(presentation)
            }
        }
    }

    private var candidatesCard: some View {
        card {
            HStack {
                Label("Automatic model selection", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Text("\(viewModel.distinctTargetCount) current targets")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Router builds an audited quality-and-cost set from the connected Claude Code and Codex catalogs. It chooses the base model first, then chooses that model's reasoning effort separately. Agent Models role settings are included as reference signals without limiting the choices or forcing a default.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if viewModel.availableProviders.isEmpty {
                Text("Connect Claude Code or Codex CLI to make automatic targets available.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connected providers: \(viewModel.availableProviders.sorted { $0.displayName < $1.displayName }.map(\.displayName).joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.unavailableProviderPreferences) { preference in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(preference.provider.displayName) needs authentication for \(preference.scopeDescription). Router will use another connected provider until it reconnects.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if onNavigate != nil {
                        Button("Authenticate") { onNavigate?(.cliProviders) }
                    }
                }
            }
            Text("Pricing and capability evidence is versioned and sent with each candidate. Provider preferences constrain routing; guidance shapes Jev’s recommendation. Usage balancing can then adjust that recommendation locally.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("What gets shared").fontWeight(.medium)
                Text("For each new routed session, the service receives your task text, custom guidance, Agent Models role references, and candidate provider/model/effort descriptions. Attached files, workspace context, chat history, and provider credentials are excluded. Anything you type in the task or guidance is shared.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func backendSettings(_ presentation: AgentTaskRouterBackendSettingsPresentation) -> some View {
        Divider()
        Text(presentation.title).fontWeight(.medium)
        Text(presentation.configurationDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let label = presentation.secretFieldLabel {
            SecureField(label, text: $candidateSecret)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isPerformingBackendOperation)
                .accessibilityLabel(label)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { credentialActions }
                VStack(alignment: .leading, spacing: 10) { credentialActions }
            }
        }
        if let message = viewModel.backendOperationFeedback.message {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                backendOperationFeedbackIcon
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
            .foregroundStyle(backendOperationFeedbackColor)
        }
        ForEach(presentation.links) { link in
            Link(link.title, destination: link.url)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
        }
    }

    @ViewBuilder
    private var credentialActions: some View {
        Button("Validate & Save") {
            let secret = candidateSecret
            Task {
                if await viewModel.performBackendAction(.validateAndSaveSecret(secret)) {
                    candidateSecret = ""
                }
            }
        }
        .disabled(candidateSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPerformingBackendOperation)
        Button("Verify Saved Key") {
            Task { await viewModel.performBackendAction(.revalidateStoredSecret) }
        }
        .disabled(viewModel.isPerformingBackendOperation)
        Button("Remove Key", role: .destructive) {
            Task { await viewModel.performBackendAction(.removeStoredSecret) }
        }
        .disabled(viewModel.isPerformingBackendOperation)
        if viewModel.isPerformingBackendOperation {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var backendOperationFeedbackIcon: some View {
        switch viewModel.backendOperationFeedback {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var backendOperationFeedbackColor: Color {
        switch viewModel.backendOperationFeedback {
        case .idle, .running: .secondary
        case .succeeded: .green
        case .failed: .red
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var selectedBackendBinding: Binding<AgentTaskRouterBackendID?> {
        Binding(get: { viewModel.selectedBackendID }, set: { id in
            if let id {
                viewModel.selectBackend(id)
            }
        })
    }

    private var readinessTitle: String {
        switch viewModel.readiness {
        case .ready:
            if !viewModel.policyCanBuildCandidates {
                return "Connect a supported provider"
            }
            return viewModel.configuration.enabled ? "Model Router is on" : "Ready to enable"
        case .validating: return "Checking your API key…"
        case .needsConfiguration: return "Set up a routing service"
        case .policyUnavailable: return "Task routing is not available yet"
        case .temporarilyUnavailable: return "Routing service unavailable"
        }
    }

    private var readinessDetail: String {
        switch viewModel.readiness {
        case .ready:
            viewModel.policyCanBuildCandidates
                ? "Enable Router here or from the Agent Mode toolbar. It stays enabled across sessions until you turn it off."
                : "Connect Claude Code or Codex CLI, or clear a provider requirement that is unavailable."
        case .validating: "The routing service is validating your configuration."
        case let .needsConfiguration(_, reason),
             let .policyUnavailable(_, reason),
             let .temporarilyUnavailable(_, reason): reason
        }
    }

    private var readinessIcon: String {
        switch viewModel.readiness {
        case .ready: viewModel.policyCanBuildCandidates ? "checkmark.circle.fill" : "info.circle"
        case .validating: "hourglass"
        case .needsConfiguration: "slider.horizontal.3"
        case .policyUnavailable: "info.circle"
        case .temporarilyUnavailable: "exclamationmark.triangle"
        }
    }
}
