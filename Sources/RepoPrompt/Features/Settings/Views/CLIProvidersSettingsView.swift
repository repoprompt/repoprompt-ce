import AppKit
import SwiftUI

struct CLIProvidersSettingsView: View {
    @ObservedObject var viewModel: APISettingsViewModel
    @ObservedObject var promptViewModel: PromptViewModel
    let windowID: Int
    var onAPIKeyUpdated: (() -> Void)?
    var closeAction: (() -> Void)?
    /// Optional navigation callback so provider cards can deep-link into Agent Permissions
    /// (or any other settings tab). When absent the link row is hidden.
    ///
    /// SEARCH-HELPER: Open Agent Permissions, Configure in Agent Permissions, A4 progressive disclosure
    var onNavigate: ((SettingsTab) -> Void)?

    @StateObject private var providerPermissionsVM: AgentProviderPermissionsSettingsViewModel

    init(
        viewModel: APISettingsViewModel,
        promptViewModel: PromptViewModel,
        windowID: Int,
        providerPermissionsViewModel: @MainActor @escaping () -> AgentProviderPermissionsSettingsViewModel,
        onAPIKeyUpdated: (() -> Void)? = nil,
        closeAction: (() -> Void)? = nil,
        onNavigate: ((SettingsTab) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.promptViewModel = promptViewModel
        self.windowID = windowID
        self.onAPIKeyUpdated = onAPIKeyUpdated
        self.closeAction = closeAction
        self.onNavigate = onNavigate
        _providerPermissionsVM = StateObject(wrappedValue: providerPermissionsViewModel())
    }

    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isLoadingClaudeCode = false
    @State private var isLoadingCodex = false
    @State private var isLoggingIntoCodex = false
    @State private var isLoadingOpenCode = false
    @State private var isLoadingCursor = false
    @State private var isLoadingZAI = false
    @State private var showClaudeCodeTraceDump = false
    @State private var showCodexTraceDump = false
    @State private var showOpenCodeTraceDump = false
    @State private var showCursorTraceDump = false
    @State private var isClaudePromptSettingsExpanded = false
    @State private var claudeNativePromptMode = ClaudeAgentToolPreferences.agentModePromptDelivery()

    // Progressive disclosure state stays user-controlled. Async provider refreshes must not
    // expand or collapse cards after the user starts interacting with this view.
    @State private var isClaudeCodeExpanded: Bool = false
    @State private var isClaudeCodeGLMExpanded: Bool = false
    @State private var isKimiCodeExpanded: Bool = false
    @State private var isCustomCompatibleExpanded: Bool = false
    @State private var isCodexExpanded: Bool = false
    @State private var isOpenCodeExpanded: Bool = false
    @State private var isCursorExpanded: Bool = false

    // Per-backend secret text entry buffers (GLM uses viewModel.zaiApiKey directly).
    // SEARCH-HELPER: Claude-Compatible Backends settings, Kimi API key entry, Custom backend key entry
    @State private var kimiSecretInput: String = ""
    @State private var customSecretInput: String = ""
    @State private var isSavingKimiSecret: Bool = false
    @State private var isSavingCustomSecret: Bool = false
    @State private var testingCompatibleBackends: Set<ClaudeCodeCompatibleBackendID> = []

    // Per-backend "Advanced" disclosure state.
    @State private var isGLMAdvancedExpanded: Bool = false
    @State private var isKimiAdvancedExpanded: Bool = false

    private var shouldShowStatusBanner: Bool {
        viewModel.isClaudeCodeConnected
            || viewModel.isCodexConnected
            || viewModel.isOpenCodeConnected
            || viewModel.isCursorConnected
    }

    private var codexStatusText: String? {
        switch viewModel.codexConnectionPhase {
        case .resolvingExecutable:
            "Looking for Codex CLI in your login-shell PATH…"
        case .refreshingAuth:
            "Checking Codex authentication…"
        case .testingAppServer:
            "Testing Codex app-server…"
        case .loggingIn:
            "Waiting for ChatGPT login to complete…"
        case .authRequired:
            "Codex authentication needs attention. Use Login with ChatGPT, then retry."
        case let .failed(message):
            message.isEmpty ? nil : message
        case .idle, .executableUnavailable, .connected:
            nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header — CLI Providers is the primary way to add agent-mode model support.
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLI Providers")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Primary way to add Agent Mode model support. Connect Claude Code, Codex, OpenCode, or Cursor to leverage your existing subscriptions — OpenCode can also proxy any API key.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)

                // Recommendation banner
                if shouldShowStatusBanner {
                    RecommendationSetupBanner(
                        windowID: windowID,
                        message: "CLI providers connected. Check recommendations to optimize your setup.",
                        closeAction: closeAction
                    )
                }

                AgentPermissionSecureStorageDegradedBanner(diagnostics: providerPermissionsVM.diagnostics)

                // Provider cards
                // Codex leads the list (default model for most users); Claude Code and its
                // Claude-compatible backends are grouped together, followed by the remaining
                // CLI providers.
                codexCard
                claudeCodeCard
                claudeCompatibleBackendsSection
                openCodeCard
                cursorCard
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                await viewModel.loadCompatibleBackendState()
                await viewModel.refreshClaudeCodeBinaryStatus()
            }
        }
        .alert(isPresented: $showAlert) {
            if showClaudeCodeTraceDump, viewModel.hasClaudeCodeTrace() {
                Alert(
                    title: Text("CLI Provider Management"),
                    message: Text(alertMessage),
                    primaryButton: .default(Text("Save Trace to Downloads"), action: dumpClaudeTrace),
                    secondaryButton: .cancel(Text("OK"), action: { showClaudeCodeTraceDump = false })
                )
            } else if showCodexTraceDump, viewModel.hasCodexTrace() {
                Alert(
                    title: Text("CLI Provider Management"),
                    message: Text(alertMessage),
                    primaryButton: .default(Text("Save Trace to Downloads"), action: dumpCodexTrace),
                    secondaryButton: .cancel(Text("OK"), action: { showCodexTraceDump = false })
                )
            } else if showOpenCodeTraceDump, viewModel.hasOpenCodeTrace() {
                Alert(
                    title: Text("CLI Provider Management"),
                    message: Text(alertMessage),
                    primaryButton: .default(Text("Save Trace to Downloads"), action: dumpOpenCodeTrace),
                    secondaryButton: .cancel(Text("OK"), action: { showOpenCodeTraceDump = false })
                )
            } else if showCursorTraceDump, viewModel.hasCursorTrace() {
                Alert(
                    title: Text("CLI Provider Management"),
                    message: Text(alertMessage),
                    primaryButton: .default(Text("Save Trace to Downloads"), action: dumpCursorTrace),
                    secondaryButton: .cancel(Text("OK"), action: { showCursorTraceDump = false })
                )
            } else {
                Alert(
                    title: Text("CLI Provider Management"),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .onChange(of: showAlert) { newValue in
            if !newValue {
                showClaudeCodeTraceDump = false
                showCodexTraceDump = false
                showOpenCodeTraceDump = false
                showCursorTraceDump = false
            }
        }
    }

    private func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private var claudeCodeCLIUnavailableDetail: String {
        if case let .binaryMissing(message) = viewModel.claudeCodeCLIStatus {
            return "\(message) This backend uses the `claude` command as its launcher, but not your Claude account."
        }
        return "Claude CLI isn't installed. Install Claude Code first — this backend uses the `claude` command as its launcher, but not your Claude account."
    }

    // MARK: - Provider Card Shell

    private func providerCard(
        title: String,
        subtitle: String,
        infoURL: String,
        isConnected: Bool,
        connectedLabel: String = "Connected",
        disconnectedLabel: String = "Not Connected",
        isExpanded: Binding<Bool>,
        @ViewBuilder expandedContent: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header — always visible
            HStack(spacing: 10) {
                // Provider name
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                // Info link (separate button, not nested)
                Button(action: { openURL(infoURL) }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // Status badge
                connectionBadge(
                    isConnected: isConnected,
                    connectedLabel: connectedLabel,
                    disconnectedLabel: disconnectedLabel
                )

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            }

            // Expanded detail
            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.horizontal, 12)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)

                    expandedContent()
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private func connectionBadge(
        isConnected: Bool,
        connectedLabel: String = "Connected",
        disconnectedLabel: String = "Not Connected"
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(isConnected ? connectedLabel : disconnectedLabel)
                .font(.caption)
                .foregroundColor(isConnected ? .green : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isConnected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Permission Summary Link

    /// Compact read-only permission summary shown inside each connected CLI provider card,
    /// with a button that deep-links into Agent Permissions where the editable controls
    /// live (A4). Keeps CLI Providers focused on connection/auth/model discovery/trace
    /// without duplicating provider-native permission editors.
    ///
    /// SEARCH-HELPER: Open Agent Permissions, Configure in Agent Permissions, A4 progressive disclosure,
    /// CLI Providers permission summary
    @ViewBuilder
    private func permissionSummaryLinkRow(for providerID: AgentProviderBindingID) -> some View {
        let summary = permissionSummaryText(for: providerID)
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Permissions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if onNavigate != nil {
                Button {
                    onNavigate?(.agentPermissions)
                } label: {
                    Label("Open Agent Permissions", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    /// Short summary of the provider-native permission level, read through the same
    /// defaults/secure-store context as the injected Agent Permissions VM.
    private func permissionSummaryText(for providerID: AgentProviderBindingID) -> String {
        let defaults = providerPermissionsVM.defaults
        let secureStore = providerPermissionsVM.securePermissions
        switch providerID {
        case .codex:
            let level = CodexAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore)
            let sandbox = CodexAgentToolPreferences.sandboxMode(defaults: defaults, secureStore: secureStore)
            return "\(level.displayName) · Sandbox \(sandbox.displayName)"
        case .claude:
            let level = ClaudeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore)
            let strict = ClaudeAgentToolPreferences.mcpStrictModeEnabled(defaults: defaults, secureStore: secureStore)
            return strict
                ? "\(level.displayName) · Strict MCP (RepoPrompt only)"
                : "\(level.displayName) · External MCP allowed"
        case .openCode:
            let level = OpenCodeAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore)
            return "ACP session mode: \(level.displayName)"
        case .cursor:
            let level = CursorAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore)
            return level.autoApprovesACPToolPermissions
                ? "ACP auto-approve: on"
                : "ACP auto-approve: off"
        }
    }

    // MARK: - Inline Direct-Provider Permissions

    @ViewBuilder
    private func directProviderInlineControls(for providerID: AgentProviderBindingID) -> some View {
        switch providerID {
        case .codex, .claude:
            if let binding = providerPermissionsVM.controlsBinding(for: providerID) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permissions & Runtime")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Direct Agent settings. Sub-agent policy remains in Agent Permissions.")
                                .font(.caption)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if onNavigate != nil {
                            Button {
                                onNavigate?(.agentPermissions)
                            } label: {
                                Label("Open Agent Permissions", systemImage: "arrow.up.forward.app")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    AgentProviderPermissionLevelSection(
                        binding: binding.permission,
                        onSelectPermissionLevel: { providerPermissionsVM.setPermissionLevel($0) }
                    )

                    AgentProviderToolsRuntimeControls(
                        providerID: providerID,
                        binding: binding,
                        onSetCodexBashToolEnabled: { providerPermissionsVM.setCodexBashToolEnabled($0) },
                        onSetCodexSearchToolEnabled: { providerPermissionsVM.setCodexSearchToolEnabled($0) },
                        onSetCodexGoalSupportEnabled: { providerPermissionsVM.setCodexGoalSupportEnabled($0) },
                        onSetCodexMCPServerEnabled: { normalizedName, enabled in
                            providerPermissionsVM.setCodexMCPServerEnabled(
                                normalizedName: normalizedName,
                                enabled: enabled
                            )
                        },
                        onSetClaudeBashToolEnabled: { providerPermissionsVM.setClaudeBashToolEnabled($0) },
                        onSetClaudeMCPStrictModeEnabled: { providerPermissionsVM.setClaudeMCPStrictModeEnabled($0) },
                        onSetClaudeToolSearchEnabled: { providerPermissionsVM.setClaudeToolSearchEnabled($0) }
                    )
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            } else {
                permissionControlsUnavailableRow()
            }
        case .openCode, .cursor:
            EmptyView()
        }
    }

    private func permissionControlsUnavailableRow() -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Provider-native controls are unavailable in this context.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            if onNavigate != nil {
                Button {
                    onNavigate?(.agentPermissions)
                } label: {
                    Label("Open Agent Permissions", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Claude Code Card

    private var claudeCodeCard: some View {
        providerCard(
            title: "Claude Code CLI",
            subtitle: "Uses your Claude Code CLI login for Anthropic models. Compatible backends below only need the `claude` binary and their own API keys.",
            infoURL: "https://docs.claude.com/en/docs/claude-code/setup",
            isConnected: viewModel.isClaudeCodeConnected,
            isExpanded: $isClaudeCodeExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isClaudeCodeConnected {
                    // Actions
                    HStack(spacing: 8) {
                        Button(action: { testClaudeCodeConnection() }) {
                            if isLoadingClaudeCode {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isLoadingClaudeCode)
                        .buttonStyle(CustomButtonStyle())

                        Spacer()

                        Button(action: { signOutFromClaudeCode() }) {
                            Text("Sign Out")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(CustomButtonStyle())
                    }

                    directProviderInlineControls(for: .claude)

                    Text("Routing GLM models through claude? See CC Zai below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Advanced prompt settings — tucked away
                    claudeCodePromptSettingsDisclosure
                } else {
                    Text("Permissions and runtime controls appear here after Claude Code is connected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Not connected — show connect action
                    HStack(spacing: 10) {
                        Button(action: { testClaudeCodeConnection() }) {
                            if isLoadingClaudeCode {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Connect", systemImage: "link")
                            }
                        }
                        .disabled(isLoadingClaudeCode)
                        .buttonStyle(CustomButtonStyle())

                        if let error = viewModel.claudeCodeError, !error.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(error)
                                    .foregroundColor(.red)
                                Text("This only affects Anthropic Claude models. Compatible backends below use their own API keys when `claude` is installed.")
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    viewModel.claudeCodeCLIStatus.isKnownMissing
                                        ? "Claude Code CLI isn't installed or isn't on PATH. Install it to use Claude-based backends."
                                        : "Run `claude login` in your terminal to authenticate Anthropic Claude models."
                                )
                                Text("CC Zai, CC Moonshot, and CC Custom below use their own API keys and work independently when `claude` is installed.")
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                            .foregroundColor(viewModel.claudeCodeCLIStatus.isKnownMissing ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Claude Code-Compatible Backends Section

    // SEARCH-HELPER: Claude Code-Compatible Backends, GLM/Z.ai, Kimi Code, Custom Claude-Compatible,
    // Claude-compatible backend presets, editable slot mappings, no-model backend

    /// Grouped section containing preset-backed cards for GLM/Z.ai and Kimi, plus a single
    /// Custom Claude-compatible backend card. All three share the `claude` binary launcher
    /// prerequisite but use their own backend API keys rather than the Claude account login.
    ///
    /// Visual treatment: wrapped in a subtle container with a left accent bar so the three
    /// nested cards clearly read as sub-providers that hang off the Claude Code CLI card
    /// immediately above. The header shows a compact summary badge (active count, or a
    /// prerequisite warning when the Claude CLI binary is missing).
    private var claudeCompatibleBackendsSection: some View {
        let backends: [ClaudeCodeCompatibleBackendID] = [.glmZAI, .kimi, .custom]
        let activeCount = backends.count(where: { viewModel.compatibleBackendIsActive($0) })
        let claudeBinaryPresent = viewModel.isClaudeCodeBinaryPresent || !viewModel.claudeCodeCLIStatus.isKnownMissing

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Claude Code–Compatible Backends")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                claudeCompatibleBackendsStatusBadge(
                    activeCount: activeCount,
                    claudeBinaryPresent: claudeBinaryPresent
                )
            }

            Text("Alternate providers that launch through the `claude` command with their own base URLs and API keys. A Claude account login is not required for these backends.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                claudeCompatibleBackendCard(for: .glmZAI, isExpanded: $isClaudeCodeGLMExpanded)
                claudeCompatibleBackendCard(for: .kimi, isExpanded: $isKimiCodeExpanded)
                claudeCompatibleBackendCard(for: .custom, isExpanded: $isCustomCompatibleExpanded)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(alignment: .leading) {
            // Left accent bar signals that these cards are a sub-group dependent on
            // the Claude Code card above.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(claudeBinaryPresent ? 0.55 : 0.25))
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func claudeCompatibleBackendsStatusBadge(
        activeCount: Int,
        claudeBinaryPresent: Bool
    ) -> some View {
        if !claudeBinaryPresent {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("Claude CLI missing")
                    .font(.caption)
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
        } else if activeCount > 0 {
            Text("\(activeCount) active")
                .font(.caption)
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        } else {
            Text("None configured")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))
        }
    }

    // MARK: - Compatible Backend Card (shared)

    @ViewBuilder
    private func claudeCompatibleBackendCard(
        for backendID: ClaudeCodeCompatibleBackendID,
        isExpanded: Binding<Bool>
    ) -> some View {
        let config = viewModel.compatibleBackendConfig(for: backendID)
        let testResult = viewModel.compatibleBackendLastTestResult[backendID]
        let active = testResult?.isSuccess == true
        let disconnectedLabel = viewModel.compatibleBackendStatusLabel(for: backendID)

        providerCard(
            title: claudeCompatibleBackendTitle(for: backendID, config: config),
            subtitle: claudeCompatibleBackendSubtitle(for: backendID, config: config),
            infoURL: claudeCompatibleBackendInfoURL(for: backendID),
            isConnected: active,
            connectedLabel: "Active · Tested",
            disconnectedLabel: disconnectedLabel,
            isExpanded: isExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                claudeCompatibleBackendPrerequisiteRow()

                claudeCompatibleBackendKeySection(for: backendID, config: config)

                claudeCompatibleBackendBehaviorSection(for: backendID, config: config)

                claudeCompatibleBackendTestSection(for: backendID, config: config)

                claudeCompatibleBackendAdvancedDisclosure(for: backendID, config: config)
            }
        }
    }

    private func claudeCompatibleBackendTitle(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String {
        // Titles follow the configured display name so edits in Advanced are reflected
        // in the card header. Preset cards get a "(via Z.ai)" suffix only when their
        // display name is still the default.
        let name = config.normalizedDisplayName
        switch backendID {
        case .glmZAI:
            return name
        case .kimi:
            return name
        case .custom:
            return name
        }
    }

    private func claudeCompatibleBackendSubtitle(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> String {
        switch backendID {
        case .glmZAI:
            if case let .claudeSlotMapping(mapping) = config.modelBehavior {
                let m = mapping.normalized
                return "Claude Code routed through Z.ai's Anthropic-compatible backend. Haiku → \(m.haiku) · Sonnet → \(m.sonnet) · Opus → \(m.opus)."
            }
            return "Claude Code routed through Z.ai's Anthropic-compatible backend."
        case .kimi:
            return "Claude Code routed through Kimi's coding backend. Kimi manages model selection — RepoPrompt does not pass `--model`."
        case .custom:
            switch config.modelBehavior {
            case .noModel:
                return "Your own Claude-compatible endpoint. No model flag is passed to `claude`."
            case .claudeSlotMapping:
                return "Your own Claude-compatible endpoint, using Claude slot mappings for Haiku / Sonnet / Opus."
            }
        }
    }

    private func claudeCompatibleBackendInfoURL(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        switch backendID {
        case .glmZAI:
            "https://z.ai/manage-apikey/apikey-list"
        case .kimi:
            "https://www.kimi.com/code/console"
        case .custom:
            "https://docs.claude.com/en/docs/claude-code/setup"
        }
    }

    private func claudeCompatibleBackendPrerequisiteRow() -> some View {
        if viewModel.claudeCodeCLIStatus.isKnownMissing {
            claudeCompatibleBackendPrerequisiteRowContent(
                title: "Claude CLI",
                detail: claudeCodeCLIUnavailableDetail,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                actionTitle: "Install Claude Code"
            ) {
                openURL("https://docs.claude.com/en/docs/claude-code/setup")
            }
        } else if viewModel.isClaudeCodeAccountAuthorized {
            claudeCompatibleBackendPrerequisiteRowContent(
                title: "Claude CLI",
                detail: "Claude CLI ready. Both this backend and Anthropic Claude models are available.",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else if viewModel.isClaudeCodeBinaryPresent {
            claudeCompatibleBackendPrerequisiteRowContent(
                title: "Claude CLI",
                detail: "Claude CLI is installed. This backend will run through `claude` with its own API key — a Claude account isn't required.",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            claudeCompatibleBackendPrerequisiteRowContent(
                title: "Claude CLI",
                detail: "Checking for the `claude` command. Compatible backends only require the binary, not a Claude account login.",
                systemImage: "clock.arrow.circlepath",
                tint: .secondary
            )
        }
    }

    private func claudeCompatibleBackendPrerequisiteRowContent(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func claudeCompatibleBackendTestSection(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> some View {
        let isTesting = testingCompatibleBackends.contains(backendID)
        let result = viewModel.compatibleBackendLastTestResult[backendID]
        let canAttempt = viewModel.canTestCompatibleBackend(backendID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { testCompatibleBackend(backendID) }) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(height: 16)
                    } else {
                        Label("Test Backend", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(isTesting || !canAttempt)
                .buttonStyle(CustomButtonStyle())

                Spacer()
            }

            if isTesting {
                Text("Routing a minimal message through \(config.normalizedDisplayName)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let result {
                Label(result.displayMessage, systemImage: resultIcon(for: result))
                    .font(.caption)
                    .foregroundColor(resultTint(for: result))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    canAttempt
                        ? "Tests this backend with the same environment overrides Agent Mode uses. Claude account login is not required."
                        : compatibleBackendTestDisabledReason(for: backendID)
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private func compatibleBackendTestDisabledReason(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        let config = viewModel.compatibleBackendConfig(for: backendID)
        if backendID == .custom, !config.isEnabled { return "Enable this backend before testing." }
        if viewModel.claudeCodeCLIStatus.isKnownMissing { return "Install Claude Code CLI before testing this backend." }
        if !config.isValid { return "Complete the backend configuration before testing." }
        if !viewModel.compatibleBackendHasSecret(backendID) { return "Save an API key before testing this backend." }
        return "Complete setup before testing this backend."
    }

    private func resultIcon(for result: ClaudeCompatibleBackendTestResult) -> String {
        result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func resultTint(for result: ClaudeCompatibleBackendTestResult) -> Color {
        result.isSuccess ? .green : .red
    }

    // MARK: Key entry section

    @ViewBuilder
    private func claudeCompatibleBackendKeySection(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> some View {
        switch backendID {
        case .glmZAI:
            glmKeySection(config: config)
        case .kimi:
            kimiKeySection(config: config)
        case .custom:
            customKeySection(config: config)
        }
    }

    private func glmKeySection(config: ClaudeCodeCompatibleBackendConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isZaiKeyValid ? "checkmark.circle.fill" : "key.fill")
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.isZaiKeyValid ? .green : .secondary)
                Text("Z.ai API Key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingZAI {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 16)
                } else if viewModel.isZaiKeyValid {
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Text(
                viewModel.isZaiKeyValid
                    ? "Saved — CC Zai is active in Agent Mode pickers."
                    : "Enter your Z.ai API key to activate CC Zai in Agent Mode."
            )
            .font(.caption)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("Enter Z.ai API key", text: $viewModel.zaiApiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 10) {
                Button(action: validateAndSaveZAIKey) {
                    Text(viewModel.isZaiKeyValid ? "Change" : "Validate & Save")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.zaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingZAI)
                .buttonStyle(CustomButtonStyle())

                Button(action: deleteZAIKey) {
                    Text("Delete")
                        .frame(maxWidth: .infinity)
                }
                // Enabled whenever a stored key exists, regardless of the current editable text buffer.
                .disabled(!viewModel.isZaiKeyValid || isLoadingZAI)
                .buttonStyle(CustomButtonStyle())
            }

            Text("Editing this key also updates the Z.AI API key in API Providers — it's the same secret.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            codingPlanFootnote(
                provider: "Z.ai",
                url: "https://z.ai/subscribe",
                linkLabel: "View Z.ai plans"
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private func kimiKeySection(config: ClaudeCodeCompatibleBackendConfig) -> some View {
        let hasSecret = viewModel.compatibleBackendHasSecret(.kimi)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: hasSecret ? "checkmark.circle.fill" : "key.fill")
                    .font(.system(size: 12))
                    .foregroundColor(hasSecret ? .green : .secondary)
                Text(keyFieldLabel(for: config.auth))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Button(action: { openURL("https://www.kimi.com/code/console") }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .hoverTooltip("Open the Kimi Code console to create or manage a Kimi API key")
                .accessibilityLabel("Open the Kimi Code console to create or manage a Kimi API key")
                Spacer()
                if isSavingKimiSecret {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 16)
                } else if hasSecret {
                    Text("Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Text(
                hasSecret
                    ? "Saved — CC Moonshot is active in Agent Mode pickers."
                    : "Enter your Kimi API key to activate CC Moonshot in Agent Mode."
            )
            .font(.caption)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)

            SecureField("Enter Kimi API key", text: $kimiSecretInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 10) {
                Button(action: { saveCompatibleBackendSecret(for: .kimi) }) {
                    Text(hasSecret ? "Change" : "Save")
                        .frame(maxWidth: .infinity)
                }
                .disabled(kimiSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKimiSecret)
                .buttonStyle(CustomButtonStyle())

                Button(action: { deleteCompatibleBackendSecret(for: .kimi) }) {
                    Text("Delete")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!hasSecret || isSavingKimiSecret)
                .buttonStyle(CustomButtonStyle())
            }

            codingPlanFootnote(
                provider: "Kimi",
                url: "https://www.kimi.com/membership/pricing?from=kfc_membership_topbar",
                linkLabel: "View Kimi plans"
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    /// Compact footnote showing that the Claude-compatible backend works with the provider's
    /// coding-plan subscription, with a pricing link. Rendered below the API-key entry row
    /// in both the Kimi and GLM sections.
    ///
    /// SEARCH-HELPER: Kimi coding plan pricing link, Z.ai coding plan pricing link,
    /// Claude-compatible backend subscription footnote
    private func codingPlanFootnote(
        provider: String,
        url: String,
        linkLabel: String
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Works with your \(provider) coding-plan subscription.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(action: { openURL(url) }) {
                HStack(spacing: 3) {
                    Text(linkLabel)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                }
                .font(.caption)
                .foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .hoverTooltip("Open \(provider)'s pricing page")
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func customKeySection(config: ClaudeCodeCompatibleBackendConfig) -> some View {
        let hasSecret = viewModel.compatibleBackendHasSecret(.custom)
        return VStack(alignment: .leading, spacing: 8) {
            // Enable toggle
            Toggle(isOn: Binding(
                get: { viewModel.compatibleBackendConfig(for: .custom).isEnabled },
                set: { newValue in
                    var updated = viewModel.compatibleBackendConfig(for: .custom)
                    updated.isEnabled = newValue
                    viewModel.saveCompatibleBackendConfig(updated)
                }
            )) {
                Text("Enable custom backend")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Display name
            VStack(alignment: .leading, spacing: 4) {
                Text("Display name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("CC Custom", text: Binding(
                    get: { viewModel.compatibleBackendConfig(for: .custom).displayName },
                    set: { newValue in
                        var updated = viewModel.compatibleBackendConfig(for: .custom)
                        updated.displayName = newValue
                        viewModel.saveCompatibleBackendConfig(updated)
                    }
                ))
                .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            // Base URL
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://api.example.com/anthropic", text: Binding(
                    get: { viewModel.compatibleBackendConfig(for: .custom).baseURL },
                    set: { newValue in
                        var updated = viewModel.compatibleBackendConfig(for: .custom)
                        updated.baseURL = newValue
                        viewModel.saveCompatibleBackendConfig(updated)
                    }
                ))
                .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            // Auth style picker
            HStack(spacing: 8) {
                Text("Auth header")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { viewModel.compatibleBackendConfig(for: .custom).auth },
                    set: { newValue in
                        var updated = viewModel.compatibleBackendConfig(for: .custom)
                        updated.auth = newValue
                        viewModel.saveCompatibleBackendConfig(updated)
                    }
                )) {
                    Text("ANTHROPIC_API_KEY").tag(ClaudeCodeCompatibleBackendConfig.Auth.anthropicAPIKey)
                    Text("ANTHROPIC_AUTH_TOKEN").tag(ClaudeCodeCompatibleBackendConfig.Auth.anthropicAuthToken)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }

            // API key field
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: hasSecret ? "checkmark.circle.fill" : "key.fill")
                        .font(.system(size: 12))
                        .foregroundColor(hasSecret ? .green : .secondary)
                    Text(keyFieldLabel(for: config.auth))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isSavingCustomSecret {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(height: 16)
                    } else if hasSecret {
                        Text("Saved")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                SecureField("Enter API key", text: $customSecretInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                HStack(spacing: 10) {
                    Button(action: { saveCompatibleBackendSecret(for: .custom) }) {
                        Text(hasSecret ? "Change" : "Save")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(customSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingCustomSecret)
                    .buttonStyle(CustomButtonStyle())

                    Button(action: { deleteCompatibleBackendSecret(for: .custom) }) {
                        Text("Delete")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!hasSecret || isSavingCustomSecret)
                    .buttonStyle(CustomButtonStyle())
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private func keyFieldLabel(for auth: ClaudeCodeCompatibleBackendConfig.Auth) -> String {
        switch auth {
        case .anthropicAPIKey:
            "API Key"
        case .anthropicAuthToken:
            "Auth Token"
        }
    }

    // MARK: Model behavior section

    @ViewBuilder
    private func claudeCompatibleBackendBehaviorSection(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> some View {
        switch backendID {
        case .glmZAI:
            claudeCompatibleSlotMappingEditor(
                backendID: .glmZAI,
                config: config,
                resetTitle: "Reset to GLM defaults"
            )
        case .kimi:
            claudeCompatibleNoModelRow()
        case .custom:
            customBehaviorSection(config: config)
        }
    }

    private func claudeCompatibleNoModelRow() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Model behavior: No `--model` flag")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Backend manages model selection. RepoPrompt does not pass a Claude slot or Claude Code effort level.")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private func customBehaviorSection(config: ClaudeCodeCompatibleBackendConfig) -> some View {
        let behaviorBinding = Binding<CustomBehaviorChoice>(
            get: {
                switch viewModel.compatibleBackendConfig(for: .custom).modelBehavior {
                case .noModel:
                    .noModel
                case .claudeSlotMapping:
                    .claudeSlotMapping
                }
            },
            set: { newValue in
                var updated = viewModel.compatibleBackendConfig(for: .custom)
                switch newValue {
                case .noModel:
                    updated.modelBehavior = .noModel
                case .claudeSlotMapping:
                    if case .claudeSlotMapping = updated.modelBehavior {
                        // keep existing mapping
                    } else {
                        if case let .claudeSlotMapping(preset) = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior {
                            updated.modelBehavior = .claudeSlotMapping(preset)
                        } else {
                            updated.modelBehavior = .claudeSlotMapping(
                                .init(haiku: "", sonnet: "", opus: "")
                            )
                        }
                    }
                }
                viewModel.saveCompatibleBackendConfig(updated)
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Model behavior")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: behaviorBinding) {
                    Text("No model flag").tag(CustomBehaviorChoice.noModel)
                    Text("Claude slot mappings").tag(CustomBehaviorChoice.claudeSlotMapping)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
            }

            switch config.modelBehavior {
            case .noModel:
                claudeCompatibleNoModelRow()
            case .claudeSlotMapping:
                claudeCompatibleSlotMappingEditor(
                    backendID: .custom,
                    config: config,
                    resetTitle: "Reset custom backend"
                )
            }
        }
    }

    private enum CustomBehaviorChoice: Hashable {
        case noModel
        case claudeSlotMapping
    }

    private func claudeCompatibleSlotMappingEditor(
        backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig,
        resetTitle: String
    ) -> some View {
        let mapping: ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping = {
            if case let .claudeSlotMapping(existing) = config.modelBehavior {
                return existing
            }
            if case let .claudeSlotMapping(preset) = ClaudeCodeCompatibleBackendID.glmZAI.defaultPreset.modelBehavior {
                return preset
            }
            return .init(haiku: "", sonnet: "", opus: "")
        }()

        func updateSlot(_ slot: ClaudeSlot, value: String) {
            var updated = viewModel.compatibleBackendConfig(for: backendID)
            var editableMapping: ClaudeCodeCompatibleBackendConfig.ClaudeSlotMapping = {
                if case let .claudeSlotMapping(current) = updated.modelBehavior { return current }
                return mapping
            }()
            switch slot {
            case .haiku: editableMapping.haiku = value
            case .sonnet: editableMapping.sonnet = value
            case .opus: editableMapping.opus = value
            }
            updated.modelBehavior = .claudeSlotMapping(editableMapping)
            viewModel.saveCompatibleBackendConfig(updated)
        }

        let haikuEmpty = mapping.haiku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sonnetEmpty = mapping.sonnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let opusEmpty = mapping.opus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Claude slot → Backend model ID")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            slotEditorRow(label: "Haiku", value: Binding(
                get: { mapping.haiku },
                set: { updateSlot(.haiku, value: $0) }
            ), isEmpty: haikuEmpty, placeholder: "e.g. glm-4.7")

            slotEditorRow(label: "Sonnet", value: Binding(
                get: { mapping.sonnet },
                set: { updateSlot(.sonnet, value: $0) }
            ), isEmpty: sonnetEmpty, placeholder: "e.g. glm-5-turbo")

            slotEditorRow(label: "Opus", value: Binding(
                get: { mapping.opus },
                set: { updateSlot(.opus, value: $0) }
            ), isEmpty: opusEmpty, placeholder: "e.g. glm-5.1")

            if haikuEmpty || sonnetEmpty || opusEmpty {
                Text("All three slots must be filled for the backend to launch.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button(action: { viewModel.resetCompatibleBackendPreset(backendID) }) {
                    Text(resetTitle)
                }
                .buttonStyle(CustomButtonStyle())
                Spacer()
            }

            Text("RepoPrompt passes the selected Claude slot to `claude`; these env vars tell the backend which model each slot should use.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    private enum ClaudeSlot {
        case haiku, sonnet, opus
    }

    private func slotEditorRow(
        label: String,
        value: Binding<String>,
        isEmpty: Bool,
        placeholder: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
                .foregroundColor(.primary)
            TextField(placeholder, text: value)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            if isEmpty {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: Advanced disclosure (base URL + auth style) for presets

    @ViewBuilder
    private func claudeCompatibleBackendAdvancedDisclosure(
        for backendID: ClaudeCodeCompatibleBackendID,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> some View {
        switch backendID {
        case .glmZAI:
            claudeCompatibleAdvancedBlock(
                backendID: .glmZAI,
                isExpanded: $isGLMAdvancedExpanded,
                config: config
            )
        case .kimi:
            claudeCompatibleAdvancedBlock(
                backendID: .kimi,
                isExpanded: $isKimiAdvancedExpanded,
                config: config
            )
        case .custom:
            EmptyView() // custom backend already exposes base URL and auth style up top.
        }
    }

    private func claudeCompatibleAdvancedBlock(
        backendID: ClaudeCodeCompatibleBackendID,
        isExpanded: Binding<Bool>,
        config: ClaudeCodeCompatibleBackendConfig
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text("Advanced")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(backendID.defaultDisplayName, text: Binding(
                            get: { viewModel.compatibleBackendConfig(for: backendID).displayName },
                            set: { newValue in
                                var updated = viewModel.compatibleBackendConfig(for: backendID)
                                updated.displayName = newValue
                                viewModel.saveCompatibleBackendConfig(updated)
                            }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(backendID.defaultPreset.baseURL, text: Binding(
                            get: { viewModel.compatibleBackendConfig(for: backendID).baseURL },
                            set: { newValue in
                                var updated = viewModel.compatibleBackendConfig(for: backendID)
                                updated.baseURL = newValue
                                viewModel.saveCompatibleBackendConfig(updated)
                            }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    HStack(spacing: 8) {
                        Text("Auth header")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { viewModel.compatibleBackendConfig(for: backendID).auth },
                            set: { newValue in
                                var updated = viewModel.compatibleBackendConfig(for: backendID)
                                updated.auth = newValue
                                viewModel.saveCompatibleBackendConfig(updated)
                            }
                        )) {
                            Text("ANTHROPIC_API_KEY").tag(ClaudeCodeCompatibleBackendConfig.Auth.anthropicAPIKey)
                            Text("ANTHROPIC_AUTH_TOKEN").tag(ClaudeCodeCompatibleBackendConfig.Auth.anthropicAuthToken)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        Spacer()
                    }

                    HStack {
                        Button(action: { viewModel.resetCompatibleBackendPreset(backendID) }) {
                            Text("Reset to defaults")
                        }
                        .buttonStyle(CustomButtonStyle())
                        Spacer()
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var claudeCodePromptSettingsDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tappable header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isClaudePromptSettingsExpanded.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isClaudePromptSettingsExpanded ? 90 : 0))
                    Text("Advanced")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isClaudePromptSettingsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sys Prompt Packaging")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { claudeNativePromptMode },
                            set: { newValue in
                                claudeNativePromptMode = newValue
                                ClaudeAgentToolPreferences.setAgentModePromptDelivery(newValue)
                            }
                        )) {
                            ForEach(ClaudeAgentToolPreferences.AgentModePromptDelivery.allCases, id: \.rawValue) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()

                        Spacer()
                    }

                    Text(claudeNativePromptMode.detailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Codex Card

    private var codexCard: some View {
        providerCard(
            title: "Codex CLI",
            subtitle: "Runs the Codex CLI through RepoPrompt, honoring your existing login and configuration.",
            infoURL: "https://developers.openai.com/codex/cli/",
            isConnected: viewModel.isCodexConnected,
            isExpanded: $isCodexExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                // KYC note
                HStack(spacing: 4) {
                    Text("ChatGPT may require identity verification (KYC) to access Codex.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { openURL("https://chatgpt.com/cyber") }) {
                        Text("Learn more")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if viewModel.isCodexConnected {
                    Divider()

                    HStack(spacing: 8) {
                        Button(action: { testCodexConnection() }) {
                            if isLoadingCodex {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isLoadingCodex)
                        .buttonStyle(CustomButtonStyle())

                        Spacer()

                        Button(action: { signOutFromCodex() }) {
                            Text("Sign Out")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(CustomButtonStyle())
                    }

                    if case let .connected(resolvedExecutable) = viewModel.codexConnectionPhase,
                       let resolvedExecutable,
                       !resolvedExecutable.isEmpty
                    {
                        Text("Using `\(resolvedExecutable)`")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    directProviderInlineControls(for: .codex)
                } else {
                    Text("Permissions and runtime controls appear here after Codex is connected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button(action: { testCodexConnection() }) {
                            if isLoadingCodex {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Connect", systemImage: "link")
                            }
                        }
                        .disabled(isLoadingCodex || isLoggingIntoCodex)
                        .buttonStyle(CustomButtonStyle())

                        Button(action: { startCodexManagedChatgptLogin() }) {
                            if isLoggingIntoCodex {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Text(CodexManagedAuthRecoveryClassifier.loginActionTitle)
                            }
                        }
                        .disabled(isLoadingCodex || isLoggingIntoCodex || !viewModel.canAttemptCodexManagedLogin)
                        .buttonStyle(CustomButtonStyle())
                    }

                    if let error = viewModel.codexError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if viewModel.isCodexExecutableUnavailable {
                            Text("After installing Codex or fixing PATH, click Connect to check again.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let codexStatusText {
                        Text(codexStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Run `codex login` in your terminal, or use Login with ChatGPT.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - OpenCode Card

    private var openCodeCard: some View {
        providerCard(
            title: "OpenCode CLI",
            subtitle: "Uses OpenCode's ACP runtime for Agent Mode; headless OpenCode runs use a managed no-native-tools mode.",
            infoURL: "https://opencode.ai/",
            isConnected: viewModel.isOpenCodeConnected,
            isExpanded: $isOpenCodeExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isOpenCodeConnected {
                    HStack(spacing: 8) {
                        Button(action: { testOpenCodeConnection() }) {
                            if isLoadingOpenCode {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isLoadingOpenCode)
                        .buttonStyle(CustomButtonStyle())

                        Spacer()

                        Button(action: { signOutFromOpenCode() }) {
                            Text("Sign Out")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(CustomButtonStyle())
                    }

                    Text(openCodeModelSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    permissionSummaryLinkRow(for: .openCode)
                } else {
                    HStack(spacing: 10) {
                        Button(action: { testOpenCodeConnection() }) {
                            if isLoadingOpenCode {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Connect", systemImage: "link")
                            }
                        }
                        .disabled(isLoadingOpenCode)
                        .buttonStyle(CustomButtonStyle())

                        if let error = viewModel.openCodeError, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Run `opencode auth login` in your terminal to authenticate.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var openCodeModelSummary: String {
        let options = viewModel.availableOpenCodeModelOptions
        let count = options.count
        if count == 0 {
            return "Model discovery will refresh in the background."
        }
        let groupedBaseCount = AgentModelCatalog.openCodeMenu(for: options).groups.count
        if groupedBaseCount > 0, groupedBaseCount < count {
            return "\(count) models discovered across \(groupedBaseCount) base models."
        }
        return count == 1 ? "1 model discovered." : "\(count) models discovered."
    }

    // MARK: - Cursor Card

    private var cursorCard: some View {
        providerCard(
            title: "Cursor CLI",
            subtitle: "Uses Cursor's ACP runtime for Agent Mode, headless tasks, and chat. RepoPrompt MCP tools are added only for agent/headless runs.",
            infoURL: "https://cursor.com/cli",
            isConnected: viewModel.isCursorConnected,
            isExpanded: $isCursorExpanded
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isCursorConnected {
                    HStack(spacing: 8) {
                        Button(action: { testCursorConnection() }) {
                            if isLoadingCursor {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isLoadingCursor)
                        .buttonStyle(CustomButtonStyle())

                        Spacer()

                        Button(action: { signOutFromCursor() }) {
                            Text("Sign Out")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(CustomButtonStyle())
                    }

                    Text(cursorModelSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    permissionSummaryLinkRow(for: .cursor)
                } else {
                    HStack(spacing: 10) {
                        Button(action: { testCursorConnection() }) {
                            if isLoadingCursor {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 16)
                            } else {
                                Label("Connect", systemImage: "link")
                            }
                        }
                        .disabled(isLoadingCursor)
                        .buttonStyle(CustomButtonStyle())

                        if let error = viewModel.cursorError, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Uses Auto by default for Agent Mode and chat. Set CURSOR_API_KEY/CURSOR_AUTH_TOKEN or complete Cursor login if prompted.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var cursorModelSummary: String {
        let options = viewModel.availableCursorModelOptions
        let count = options.count
        if count == 0 {
            return "Using Auto fallback; dynamic model discovery will refresh in the background."
        }
        func normalizedCursorModelAlias(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let base = trimmed.firstIndex(of: "[").map { String(trimmed[..<$0]) } ?? trimmed
            return base.replacingOccurrences(of: " ", with: "-")
        }
        let hasComposer2 = options.contains { option in
            normalizedCursorModelAlias(option.rawValue) == AgentModel.cursorComposer2.rawValue
                || normalizedCursorModelAlias(option.displayName) == AgentModel.cursorComposer2.rawValue
        }
        let base = count == 1 ? "1 model available." : "\(count) models available."
        return hasComposer2 ? "\(base) Composer 2 is available when selected." : "\(base) Auto is the built-in fallback."
    }

    // MARK: - Actions

    private func validateAndSaveZAIKey() {
        isLoadingZAI = true
        Task {
            do {
                let isValid = try await viewModel.validateZAICodingPlanKey()
                await MainActor.run {
                    isLoadingZAI = false
                    if isValid {
                        onAPIKeyUpdated?()
                    } else {
                        alertMessage = "Unable to validate Z.ai Coding Plan. Please check that your key is correct and that your GLM Coding Plan subscription is active."
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingZAI = false
                    alertMessage = "Error validating Z.ai Coding Plan: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    private func deleteZAIKey() {
        isLoadingZAI = true
        Task {
            do {
                try await viewModel.deleteKey(for: .zAI)
                await MainActor.run {
                    isLoadingZAI = false
                    alertMessage = "Z.ai API key deleted"
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingZAI = false
                    alertMessage = "Error deleting Z.ai API key: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    // MARK: - Compatible backend secret actions

    private func saveCompatibleBackendSecret(for backendID: ClaudeCodeCompatibleBackendID) {
        let input: String
        switch backendID {
        case .kimi:
            input = kimiSecretInput
        case .custom:
            input = customSecretInput
        case .glmZAI:
            return
        }
        setSavingSpinner(for: backendID, value: true)
        Task {
            do {
                try await viewModel.saveCompatibleBackendSecret(input, for: backendID)
                await MainActor.run {
                    setSavingSpinner(for: backendID, value: false)
                    clearSecretInput(for: backendID)
                    alertMessage = backendSavedAlertMessage(for: backendID)
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    setSavingSpinner(for: backendID, value: false)
                    alertMessage = "Error saving API key: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    private func deleteCompatibleBackendSecret(for backendID: ClaudeCodeCompatibleBackendID) {
        setSavingSpinner(for: backendID, value: true)
        Task {
            do {
                try await viewModel.deleteCompatibleBackendSecret(for: backendID)
                await MainActor.run {
                    setSavingSpinner(for: backendID, value: false)
                    clearSecretInput(for: backendID)
                    alertMessage = backendDeletedAlertMessage(for: backendID)
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    setSavingSpinner(for: backendID, value: false)
                    alertMessage = "Error deleting API key: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    private func setSavingSpinner(for backendID: ClaudeCodeCompatibleBackendID, value: Bool) {
        switch backendID {
        case .kimi: isSavingKimiSecret = value
        case .custom: isSavingCustomSecret = value
        case .glmZAI: break
        }
    }

    private func clearSecretInput(for backendID: ClaudeCodeCompatibleBackendID) {
        switch backendID {
        case .kimi: kimiSecretInput = ""
        case .custom: customSecretInput = ""
        case .glmZAI: break
        }
    }

    private func backendSavedAlertMessage(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        switch backendID {
        case .kimi: "Kimi API key saved. CC Moonshot is now available in Agent Mode."
        case .custom: "Custom backend API key saved."
        case .glmZAI: ""
        }
    }

    private func backendDeletedAlertMessage(for backendID: ClaudeCodeCompatibleBackendID) -> String {
        switch backendID {
        case .kimi: "Kimi API key deleted."
        case .custom: "Custom backend API key deleted."
        case .glmZAI: ""
        }
    }

    private func testCompatibleBackend(_ backendID: ClaudeCodeCompatibleBackendID) {
        guard !testingCompatibleBackends.contains(backendID) else { return }
        testingCompatibleBackends.insert(backendID)
        Task {
            _ = await viewModel.testCompatibleBackendConnection(backendID)
            await MainActor.run {
                testingCompatibleBackends.remove(backendID)
            }
        }
    }

    private func testClaudeCodeConnection() {
        isLoadingClaudeCode = true
        Task {
            do {
                let isConnected = try await viewModel.testClaudeCodeConnection()
                await MainActor.run {
                    if isConnected {
                        alertMessage = "Claude Code CLI is connected and ready to use!"
                        showClaudeCodeTraceDump = false
                    } else {
                        alertMessage = "Claude Code CLI is not connected. Please run 'claude login' in your terminal."
                        showClaudeCodeTraceDump = viewModel.hasClaudeCodeTrace()
                    }
                    showAlert = true
                    isLoadingClaudeCode = false
                }
            } catch {
                await MainActor.run {
                    alertMessage = "Error connecting to Claude Code CLI: \(error.asFriendlyString())"
                    showClaudeCodeTraceDump = viewModel.hasClaudeCodeTrace()
                    showAlert = true
                    isLoadingClaudeCode = false
                }
            }
        }
    }

    private func dumpClaudeTrace() {
        do {
            let url = try viewModel.dumpClaudeCodeTrace()
            alertMessage = "Trace saved to Downloads/\(url.lastPathComponent)."
        } catch let error as CLIProcessLogCollectorError {
            switch error {
            case .noEntries:
                alertMessage = "No trace data is available to export yet."
            case .downloadsDirectoryUnavailable:
                alertMessage = "Unable to locate the Downloads folder."
            }
        } catch {
            alertMessage = "Failed to export trace: \(error.localizedDescription)"
        }
        showClaudeCodeTraceDump = false
        showAlert = true
    }

    private func dumpCodexTrace() {
        do {
            let url = try viewModel.dumpCodexTrace()
            alertMessage = "Trace saved to Downloads/\(url.lastPathComponent)."
        } catch let error as CLIProcessLogCollectorError {
            switch error {
            case .noEntries:
                alertMessage = "No trace data is available to export yet."
            case .downloadsDirectoryUnavailable:
                alertMessage = "Unable to locate the Downloads folder."
            }
        } catch {
            alertMessage = "Failed to export trace: \(error.localizedDescription)"
        }
        showCodexTraceDump = false
        showAlert = true
    }

    private func signOutFromClaudeCode() {
        viewModel.isClaudeCodeConnected = false
        viewModel.claudeCodeError = nil
        UserDefaults.standard.set(false, forKey: "ClaudeCodeConnected")
        NotificationCenter.default.post(name: .claudeCodeConnectionChanged, object: nil, userInfo: ["windowID": windowID])
        alertMessage = "Signed out from Claude Code CLI"
        showClaudeCodeTraceDump = false
        showAlert = true
        onAPIKeyUpdated?()
    }

    private func testCodexConnection() {
        isLoadingCodex = true
        Task {
            do {
                let ok = try await viewModel.testCodexConnection()
                await MainActor.run {
                    isLoadingCodex = false
                    if ok {
                        alertMessage = "Codex CLI connected."
                        showCodexTraceDump = false
                    }
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingCodex = false
                    alertMessage = viewModel.codexError ?? error.asFriendlyString()
                    showCodexTraceDump = viewModel.shouldOfferCodexTraceDump()
                    showAlert = true
                }
            }
        }
    }

    private func startCodexManagedChatgptLogin() {
        isLoggingIntoCodex = true
        Task {
            do {
                let ok = try await viewModel.startCodexManagedChatgptLogin { url in
                    NSWorkspace.shared.open(url)
                }
                await MainActor.run {
                    isLoggingIntoCodex = false
                    if ok {
                        alertMessage = "Codex ChatGPT login completed."
                        showCodexTraceDump = false
                        showAlert = true
                        onAPIKeyUpdated?()
                    }
                }
            } catch {
                await MainActor.run {
                    isLoggingIntoCodex = false
                    alertMessage = viewModel.codexError ?? error.asFriendlyString()
                    showCodexTraceDump = false
                    showAlert = true
                }
            }
        }
    }

    private func signOutFromCodex() {
        Task {
            await viewModel.resetCodexConnectionForSignOut(windowID: windowID)
            await MainActor.run {
                alertMessage = "Signed out from Codex CLI"
                showAlert = true
                onAPIKeyUpdated?()
            }
        }
    }

    private func testOpenCodeConnection() {
        isLoadingOpenCode = true
        Task {
            do {
                let ok = try await viewModel.testOpenCodeConnection()
                await MainActor.run {
                    isLoadingOpenCode = false
                    if ok {
                        let modelSummary = openCodeModelSummary.lowercased()
                        alertMessage = "OpenCode CLI connected. \(modelSummary)"
                        showOpenCodeTraceDump = false
                    }
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingOpenCode = false
                    alertMessage = viewModel.openCodeError ?? error.asFriendlyString()
                    showOpenCodeTraceDump = viewModel.hasOpenCodeTrace()
                    showAlert = true
                }
            }
        }
    }

    private func dumpOpenCodeTrace() {
        do {
            let url = try viewModel.dumpOpenCodeTrace()
            alertMessage = "Trace saved to Downloads/\(url.lastPathComponent)."
        } catch let error as CLIProcessLogCollectorError {
            switch error {
            case .noEntries:
                alertMessage = "No trace data is available to export yet."
            case .downloadsDirectoryUnavailable:
                alertMessage = "Unable to locate the Downloads folder."
            }
        } catch {
            alertMessage = "Failed to export trace: \(error.localizedDescription)"
        }
        showOpenCodeTraceDump = false
        showAlert = true
    }

    private func signOutFromOpenCode() {
        viewModel.disconnectOpenCode()
        alertMessage = "Signed out from OpenCode CLI"
        showOpenCodeTraceDump = false
        showAlert = true
        onAPIKeyUpdated?()
    }

    private func testCursorConnection() {
        isLoadingCursor = true
        Task {
            do {
                let ok = try await viewModel.testCursorConnection()
                await MainActor.run {
                    isLoadingCursor = false
                    if ok {
                        let modelSummary = cursorModelSummary.lowercased()
                        alertMessage = "Cursor CLI connected. \(modelSummary)"
                        showCursorTraceDump = false
                    }
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingCursor = false
                    alertMessage = viewModel.cursorError ?? error.asFriendlyString()
                    showCursorTraceDump = viewModel.hasCursorTrace()
                    showAlert = true
                }
            }
        }
    }

    private func dumpCursorTrace() {
        do {
            let url = try viewModel.dumpCursorTrace()
            alertMessage = "Trace saved to Downloads/\(url.lastPathComponent)."
        } catch let error as CLIProcessLogCollectorError {
            switch error {
            case .noEntries:
                alertMessage = "No trace data is available to export yet."
            case .downloadsDirectoryUnavailable:
                alertMessage = "Unable to locate the Downloads folder."
            }
        } catch {
            alertMessage = "Failed to export trace: \(error.localizedDescription)"
        }
        showCursorTraceDump = false
        showAlert = true
    }

    private func signOutFromCursor() {
        viewModel.disconnectCursor()
        alertMessage = "Signed out from Cursor CLI"
        showCursorTraceDump = false
        showAlert = true
        onAPIKeyUpdated?()
    }
}
