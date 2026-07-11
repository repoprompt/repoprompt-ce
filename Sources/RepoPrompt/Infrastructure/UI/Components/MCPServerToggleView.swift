import AppKit
import Combine
import SwiftUI

private struct MCPToolbarVisualState: Equatable {
    enum Kind: Equatable {
        case inactive
        case active
        case attention
    }

    let kind: Kind
    let message: String?

    var iconColor: Color {
        switch kind {
        case .inactive:
            Color.gray.opacity(0.65)
        case .active:
            .green
        case .attention:
            .orange
        }
    }

    var helpText: String {
        if let message, !message.isEmpty {
            return message
        }
        switch kind {
        case .inactive:
            return "Enable MCP tools for this window"
        case .active:
            return "MCP tools enabled for this window"
        case .attention:
            return "Review MCP status for this window"
        }
    }
}

@MainActor
private final class MCPToolbarStateObserver: ObservableObject {
    @Published private(set) var visualState: MCPToolbarVisualState

    private var cancellables = Set<AnyCancellable>()

    init(server: MCPServerViewModel) {
        visualState = Self.makeState(
            windowToolsEnabled: server.windowToolsEnabled,
            lastErrorMessage: server.lastErrorMessage
        )

        Publishers.CombineLatest(
            server.$windowToolsEnabled.removeDuplicates(),
            server.$lastErrorMessage.removeDuplicates()
        )
        .map(Self.makeState(windowToolsEnabled:lastErrorMessage:))
        .removeDuplicates()
        .sink { [weak self] in self?.visualState = $0 }
        .store(in: &cancellables)
    }

    private static func makeState(windowToolsEnabled: Bool, lastErrorMessage: String?) -> MCPToolbarVisualState {
        if let lastErrorMessage, !lastErrorMessage.isEmpty {
            return MCPToolbarVisualState(kind: .attention, message: lastErrorMessage)
        }
        return MCPToolbarVisualState(kind: windowToolsEnabled ? .active : .inactive, message: nil)
    }
}

// MARK: - MCPServerToggleView

@MainActor
struct MCPServerToggleView: View {
    private let server: MCPServerViewModel
    private let promptViewModel: PromptViewModel
    private let windowID: Int

    // TOOLBAR POPOVER FIX: Accept binding from parent to survive toolbar re-evaluation
    @Binding var showPopover: Bool
    @State private var isProcessing = false
    @StateObject private var toolbarStateObserver: MCPToolbarStateObserver

    init(windowState: WindowState, showPopover: Binding<Bool>) {
        let server = windowState.mcpServer
        self.server = server
        promptViewModel = windowState.promptManager
        windowID = windowState.windowID
        _showPopover = showPopover
        _toolbarStateObserver = StateObject(wrappedValue: MCPToolbarStateObserver(server: server))
    }

    private var buttonIconColor: Color {
        isProcessing ? .accentColor : toolbarStateObserver.visualState.iconColor
    }

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .imageScale(.medium)
                    .foregroundColor(buttonIconColor)
                Text("MCP Server")
            }
        }
        .buttonStyle(CustomButtonStyle())
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .hoverTooltip(toolbarStateObserver.visualState.helpText, .bottom)
        .accessibilityHint(toolbarStateObserver.visualState.helpText)
        .popover(isPresented: $showPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            popoverContent()
        }
    }

    private func popoverContent() -> some View {
        MCPServerPopoverContent(
            isProcessing: $isProcessing,
            toggleServer: toggleServer,
            promptViewModel: promptViewModel,
            windowID: windowID,
            onDismiss: { showPopover = false }
        )
        .environmentObject(server)
    }

    private func toggleServer() {
        Task {
            await MainActor.run { isProcessing = true }

            await server.toggle()

            await MainActor.run {
                isProcessing = false
            }
        }
    }
}

// MARK: - MCPServerPopoverContent

struct MCPServerPopoverContent: View {
    @Binding var isProcessing: Bool
    let toggleServer: () -> Void
    @ObservedObject var promptViewModel: PromptViewModel
    let windowID: Int
    var onDismiss: (() -> Void)?

    // Access current running-tool indicator
    @EnvironmentObject private var server: MCPServerViewModel
    private var isServerRunning: Bool {
        server.isRunning
    }

    private var windowToolsEnabled: Bool {
        server.windowToolsEnabled
    }

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(380, min: 380, max: 500)
    }

    private var popoverMaxHeight: CGFloat {
        fontPreset.scaledClamped(580, min: 580, max: 760)
    }

    private var contentPadding: CGFloat {
        fontPreset.scaledClamped(20, min: 20, max: 28)
    }

    private var sectionSpacing: CGFloat {
        fontPreset.scaledClamped(16, min: 16, max: 24)
    }

    private var subsectionSpacing: CGFloat {
        fontPreset.scaledClamped(10, min: 10, max: 16)
    }

    private var rowSpacing: CGFloat {
        fontPreset.scaledClamped(12, min: 12, max: 18)
    }

    private var compactRowSpacing: CGFloat {
        fontPreset.scaledClamped(8, min: 8, max: 12)
    }

    private var buttonMinHeight: CGFloat {
        fontPreset.scaledClamped(28, min: 28, max: 38)
    }

    /// Controls the Settings pop-over from the Planning model menu.
    @State private var showSettingsPopover = false

    @State private var showProAlert = false

    /// Track active tool count
    @StateObject private var toolStore = ToolAvailabilityStore.shared

    /// Cache active tool count to avoid frequent recalculation
    @State private var activeToolCount: Int = 0

    @State private var didCancelTool = false
    @State private var showErrorPopover = false

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    private var autoStartServerBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpAutoStart() },
            set: { globalSettings.setMCPAutoStart($0) }
        )
    }

    private var showModelPresets: Bool {
        globalSettings.mcpShowModelPresets()
    }

    private var showModelPresetsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpShowModelPresets() },
            set: { globalSettings.setMCPShowModelPresets($0) }
        )
    }

    private var mcpTemporarilyDisablePresets: Bool {
        globalSettings.mcpTemporarilyDisablePresets()
    }

    private var mcpTemporarilyDisablePresetsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpTemporarilyDisablePresets() },
            set: { globalSettings.setMCPTemporarilyDisablePresets($0) }
        )
    }

    // Inline feedback states (brief visual confirmations)
    @State private var mcpInstallFeedback: String?
    @State private var mcpInstallFeedbackIsError: Bool = false
    @State private var feedbackDismissTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionSpacing) {
                // Header
                headerSection

                Divider()

                serverControlSection
                Divider()
                modelPresetsSection
                Divider()
                contextBuilderAgentSection
                Divider()
                quickActionsSection
                Divider()
                settingsLinkSection
            }
            .padding(contentPadding)
            .frame(width: popoverWidth, alignment: .leading)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
        .onChange(of: server.activeToolName) { _, newValue in
            // reset UI flag when a new tool starts
            if newValue != nil { didCancelTool = false }
        }
        .onAppear {
            server.setDashboardUpdatesVisible(true, consumer: .toolbarPopover)
            updateActiveToolCount()
        }
        .onDisappear {
            server.setDashboardUpdatesVisible(false, consumer: .toolbarPopover)
        }
        .onChange(of: toolStore.disabledTools) {
            updateActiveToolCount()
        }
        .onChange(of: toolStore.toolSummaries.count) {
            updateActiveToolCount()
        }
        .alert("Feature Available", isPresented: $showProAlert) {
            Button("OK") {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MCP Server integration is available in RepoPrompt CE.")
        }
    }

    // MARK: - View Builders

    // localNetworkPermissionWarning view has been retired; Local Network permissions are no longer required

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: compactRowSpacing) {
            HStack {
                Text("MCP Server")
                    .font(fontPreset.headlineFont)

                Spacer()

                Text("Window \(windowID)")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }

            Text("Model-Context-Protocol server enables external tools to interact with your codebase.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let client = server.pendingClientID {
                Text("Waiting for approval: \(client)")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var proLockSection: some View {
        VStack(alignment: .center, spacing: rowSpacing) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 40 * fontPreset.scaleFactor))
                .foregroundColor(.orange)

            Text("Feature")
                .font(fontPreset.headlineFont)

            Text("MCP Server integration is available in RepoPrompt CE")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("OK") {
                showProAlert = true
            }
            .buttonStyle(CustomButtonStyle())
            .frame(minHeight: buttonMinHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var serverControlSection: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Status and Toggle
            HStack {
                statusIndicator

                // Error indicator button
                if hasErrors {
                    Button(action: { showErrorPopover.toggle() }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .hoverTooltip("View error details")
                    .popover(isPresented: $showErrorPopover) {
                        errorDetailsPopover
                            .frame(width: 350)
                            .padding(16)
                    }
                }

                Spacer()

                if server.activeToolName != nil {
                    Button(didCancelTool ? "Cancelled" : "Cancel") {
                        didCancelTool = true
                        Task { [weak server] in server?.cancelActiveTool() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(didCancelTool)
                    .hoverTooltip("Abort the current tool call")
                }

                if isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.7)
                }

                Toggle("", isOn: Binding(
                    get: { windowToolsEnabled },
                    set: { newValue in
                        guard !isProcessing else { return }
                        if newValue != windowToolsEnabled {
                            toggleServer()
                        }
                    }
                ))
                .toggleStyle(SwitchToggleStyle())
                .disabled(isProcessing)
                .hoverTooltip("Enable MCP tools for this window")
            }

            // Auto-start toggle and status
            HStack {
                Toggle("Auto-Start", isOn: autoStartServerBinding)
                    .font(fontPreset.font)
                    .hoverTooltip("Automatically start the MCP server when RepoPrompt launches")

                Spacer()

                MCPConnectionsCounter(server: server, windowID: windowID, onDismiss: onDismiss)
            }
        }
    }

    private var statusIndicator: some View {
        HStack(alignment: .top, spacing: compactRowSpacing) {
            Circle()
                .fill((isServerRunning && windowToolsEnabled) ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .padding(.top, fontPreset.scaledClamped(5, min: 5, max: 7))
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(3, min: 3, max: 6)) {
                if windowToolsEnabled {
                    if isServerRunning {
                        Text("Active")
                            .font(fontPreset.font)
                            .foregroundColor(.primary)
                    } else {
                        Text("Waiting for listener…")
                            .font(fontPreset.font)
                            .foregroundColor(.secondary)
                    }
                    Text(enabledToolsDetailText)
                        .font(fontPreset.captionFont)
                        .foregroundColor(server.activeToolName == nil ? .secondary : .orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isServerRunning {
                    Text("Listener active")
                        .font(fontPreset.font)
                        .foregroundColor(.secondary)
                    Text("Tools disabled for this window")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack {
                        Text("Inactive")
                            .font(fontPreset.font)
                            .foregroundColor(.secondary)
                    }
                    .frame(minHeight: fontPreset.scaledClamped(32, min: 32, max: 44))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Planning model is now shown within the modelPresetsSection when presets are enabled but empty
    /* private var planningModelSection: some View {
     VStack(alignment: .leading, spacing: 10) {
     HStack {
     Text("Planning Model")
     		.font(fontPreset.subHeadlineBoldFont)

     Button(action: { showPlanningModelHelp() }) {
     Image(systemName: "questionmark.circle")
     .foregroundColor(.secondary)
     .imageScale(.small)
     }
     .buttonStyle(.plain)
     .hoverTooltip("Learn about planning models")

     Spacer()
     }

     AIModelDropdown(
     promptViewModel: promptViewModel,
     showSettingsPopover: $showSettingsPopover,
     	windowID: windowID,
     useBorderlessStyle: false,
     isInGeneralSettings: false,
     isContextBuilder: false,
     isPlanningModel: true
     )

     Text("")
     	.font(fontPreset.captionFont)
     .foregroundColor(.secondary)
     .fixedSize(horizontal: false, vertical: true)
     }
     } */

    // MARK: - Model Presets Section

    private var modelPresetsSection: some View {
        VStack(alignment: .leading, spacing: subsectionSpacing) {
            HStack {
                Text("Oracle Model Presets")
                    .font(fontPreset.subHeadlineBoldFont)

                Spacer()

                Button(action: {
                    // Open settings to the Model Presets tab
                    openSettingsToPresets()
                    onDismiss?()
                }) {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(CustomButtonStyle())
                .frame(minHeight: buttonMinHeight)
            }

            Toggle("Use Oracle Model Presets for MCP", isOn: showModelPresetsBinding)
                .font(fontPreset.font)
                .hoverTooltip("When enabled, list_models returns user-defined presets. When disabled, returns only the current oracle model.")
                .onChange(of: showModelPresets) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .recommendationsDidApply, object: nil)
                    }
                }

            if showModelPresets {
                // Effective presets: empty when temporarily disabled by wizard
                let effectivePresets = mcpTemporarilyDisablePresets ? [] : ModelPresetsManager.shared.presets

                if effectivePresets.isEmpty {
                    VStack(alignment: .leading, spacing: compactRowSpacing) {
                        if !mcpTemporarilyDisablePresets {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("No presets defined. Choose a model for MCP here.")
                                    .font(fontPreset.captionFont)
                                    .foregroundColor(.secondary)
                            }
                        }
                        // Inline Planning Model dropdown (used when presets are enabled but empty or disabled)
                        AIModelDropdown(
                            promptViewModel: promptViewModel,
                            showSettingsPopover: $showSettingsPopover,
                            windowID: windowID,
                            useBorderlessStyle: false,
                            isInGeneralSettings: false,
                            destination: .planningModel(promptVM: promptViewModel)
                        )
                        if mcpTemporarilyDisablePresets {
                            // Inline re-enable option with info
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12))
                                    .hoverTooltip("Setup Wizard hid presets so you can use the model dropdown above directly. Click 'Show presets' to restore them.")
                                    .accessibilityLabel("Setup Wizard hid presets so you can use the model dropdown above directly. Click Show presets to restore them.")
                                Text("Presets hidden by Setup Wizard.")
                                    .font(fontPreset.captionFont)
                                    .foregroundColor(.secondary)
                                Button("Show presets") {
                                    mcpTemporarilyDisablePresetsBinding.wrappedValue = false
                                    DispatchQueue.main.async {
                                        NotificationCenter.default.post(name: .recommendationsDidApply, object: nil)
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(fontPreset.captionFont)
                                .foregroundColor(.accentColor)
                            }
                        } else {
                            Text("When no presets exist, MCP chat uses this model.")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(effectivePresets.count) preset\(effectivePresets.count == 1 ? "" : "s") available")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                        Text("Used by 'list_models', 'oracle_send', and 'ask_oracle' MCP tools")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("MCP tools will use the current oracle model only")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Context Builder Agent Section

    private var contextBuilderAgentSection: some View {
        VStack(alignment: .leading, spacing: compactRowSpacing) {
            HStack {
                Text("Context Builder")
                    .font(fontPreset.subHeadlineBoldFont)

                Spacer()

                StableMenuButton(
                    items: contextBuilderAgentModelMenuItems,
                    triggerStyle: .borderless
                ) {
                    AgentModelSelectionSummaryLabel(
                        agentKind: promptViewModel.contextBuilderAgent,
                        rawModel: promptViewModel.contextBuilderAgentModelRaw,
                        title: "\(promptViewModel.contextBuilderAgent.displayName) · \(promptViewModel.contextBuilderAgentModelDisplayName)",
                        iconFont: .caption
                    )
                }
                .hoverTooltip("Agent and model used when MCP clients run context-building operations.")
            }

            Text("Used by context_builder MCP tool.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
        }
    }

    private func contextBuilderAgentModelMenuItems() -> [StableMenuItem] {
        var items = promptViewModel.availableAgentKinds.map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: promptViewModel.contextBuilderModelOptions(for: agent),
                selectedAgent: promptViewModel.contextBuilderAgent,
                selectedModelRaw: promptViewModel.contextBuilderAgentModelRaw
            ) { selectedAgent, selectedOption in
                promptViewModel.contextBuilderAgent = selectedAgent
                promptViewModel.selectContextBuilderAgentModel(rawModel: selectedOption.rawValue)
                // Persist even when the user re-selects the displayed runtime fallback.
                promptViewModel.commitContextBuilderSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .recommendationsDidApply, object: nil)
                }
            }
        }
        AgentProviderSettingsMenuAction.appendStableMenuItem(
            to: &items,
            windowID: windowID,
            availableAgents: promptViewModel.availableAgentKinds
        )
        return items
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: subsectionSpacing) {
            HStack {
                Text("Quick Setup")
                    .font(fontPreset.subHeadlineBoldFont)

                if let feedback = mcpInstallFeedback {
                    Text(feedback)
                        .font(fontPreset.captionFont)
                        .foregroundColor(mcpInstallFeedbackIsError ? .orange : .green)
                }
            }

            HStack(spacing: subsectionSpacing) {
                Menu {
                    Section("MCP Server") {
                        Button("Cursor") {
                            installInCursor()
                            showMCPFeedback("Cursor configured")
                        }
                        Button("VS Code") {
                            MCPIntegrationHelper.installInVSCode()
                            showMCPFeedback("VS Code configured")
                        }
                        Button("Codex CLI") {
                            let result = MCPIntegrationHelper.installInCodex()
                            if result.success {
                                showMCPFeedback(result.wasAlreadyPresent ? "Codex already configured" : "Codex configured")
                            } else {
                                showMCPFeedback("Codex config failed", isError: true)
                            }
                        }
                        Button("OpenCode") {
                            let result = MCPIntegrationHelper.installInOpenCode()
                            if result.success {
                                showMCPFeedback(result.wasAlreadyPresent ? "OpenCode already configured" : "OpenCode configured")
                            } else {
                                showMCPFeedback("OpenCode config failed", isError: true)
                            }
                        }
                        Button("Claude Desktop") {
                            let success = installInClaude()
                            if success {
                                showMCPFeedback("Claude Desktop configured")
                            } else {
                                showMCPFeedback("Claude Desktop not found", isError: true)
                            }
                        }
                        Button("Claude Code (per-project)") {
                            let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                            guard !workspacePaths.isEmpty else {
                                showMCPFeedback("Open a folder first", isError: true)
                                return
                            }
                            Task {
                                let result = await MCPIntegrationHelper.installInClaudeCode(workspacePaths: workspacePaths)
                                if result.success {
                                    showMCPFeedback("Claude Code configured")
                                } else {
                                    showMCPFeedback(result.lastErrorMessage ?? "Claude Code install failed", isError: true)
                                }
                            }
                        }
                    }

                    Section("CLI (\(MCPIntegrationHelper.cliCommandName))") {
                        Button("Install to PATH") {
                            Task {
                                do {
                                    try await MCPIntegrationHelper.installCLIToPath()
                                    showMCPFeedback("\(MCPIntegrationHelper.cliCommandName) installed")
                                } catch {
                                    showMCPFeedback("Install failed", isError: true)
                                }
                            }
                        }
                        Button("Uninstall from PATH") {
                            Task {
                                do {
                                    try await MCPIntegrationHelper.uninstallCLIFromPath()
                                    showMCPFeedback("\(MCPIntegrationHelper.cliCommandName) removed")
                                } catch {
                                    showMCPFeedback("Uninstall failed", isError: true)
                                }
                            }
                        }
                    }

                    Section("\(CLIPathInstaller.claudeRPCommandName) (Claude Code wrapper)") {
                        Button("Install to PATH") {
                            Task {
                                do {
                                    try await CLIPathInstaller.installClaudeRP()
                                    showMCPFeedback("\(CLIPathInstaller.claudeRPCommandName) installed")
                                } catch {
                                    showMCPFeedback("Install failed", isError: true)
                                }
                            }
                        }
                        Button("Uninstall from PATH") {
                            Task {
                                do {
                                    try await CLIPathInstaller.uninstallClaudeRP()
                                    showMCPFeedback("\(CLIPathInstaller.claudeRPCommandName) removed")
                                } catch {
                                    showMCPFeedback("Uninstall failed", isError: true)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Install…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .frame(minHeight: buttonMinHeight)
                .hoverTooltip("Install the RepoPrompt MCP server or CLI")

                // Skills menu
                Menu {
                    Section {
                        Text("Shared (.agents/skills)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Works with Codex and other agents")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Menu("Global (~/.agents/skills)") {
                            Button("MCP skills") {
                                let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: false)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: true)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let count = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: true)
                                showMCPFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                            }
                        }

                        Menu("Per-project (.agents/skills)") {
                            Button("MCP skills") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showMCPFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showMCPFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                let count = MCPIntegrationHelper.uninstallAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showMCPFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                            }
                        }
                        .disabled(promptViewModel.fileManager.visibleRootFolders.isEmpty)
                    }

                    Section {
                        Text("Claude Code (.claude/commands)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Menu("Per-project") {
                            Button("MCP skills") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showMCPFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showMCPFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let workspacePaths = promptViewModel.fileManager.visibleRootFolders.map(\.fullPath)
                                let count = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showMCPFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                            }
                        }
                        .disabled(promptViewModel.fileManager.visibleRootFolders.isEmpty)
                    }

                    Section {
                        Text("Codex CLI (~/.codex/prompts)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Menu("Global") {
                            Button("MCP skills") {
                                let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: false)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: true)
                                showMCPFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let count = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: true)
                                showMCPFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                            }
                        }
                    }
                } label: {
                    Label("Skills", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .frame(minHeight: buttonMinHeight)
                .hoverTooltip("Install /rp-investigate and /rp-build slash skills")

                // Copy JSON (minimal)
                Button(action: {
                    copyMCPConfigToClipboard()
                    showMCPFeedback("Copied to clipboard")
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(CustomButtonStyle())
                .frame(minWidth: buttonMinHeight, minHeight: buttonMinHeight)
                .hoverTooltip("Copy MCP JSON configuration")
            }

            Text("If the integration doesn't show up right away, restart the client app after installing the server.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showMCPFeedback(_ message: String, isError: Bool = false) {
        feedbackDismissTask?.cancel()
        mcpInstallFeedback = message
        mcpInstallFeedbackIsError = isError
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            mcpInstallFeedback = nil
        }
    }

    private var settingsLinkSection: some View {
        HStack {
            Button("Advanced Settings…") {
                NotificationCenter.default.post(
                    name: .showMCPSettingsTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(fontPreset.font)

            Spacer()
        }
    }

    // MARK: - Helpers

    private var enabledToolsDetailText: String {
        if let running = server.activeToolName {
            return "Tools enabled for this window • Running \(running)"
        }
        if activeToolCount > 0 {
            return "Tools enabled for this window • \(activeToolCount) available"
        }
        return "Tools enabled for this window"
    }

    private var hasErrors: Bool {
        server.lastErrorMessage != nil || server.recentExternalClientEvent != nil
    }

    private var errorDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Error Details")
                .font(fontPreset.headlineFont)

            Divider()

            // Internal diagnostics
            if let message = server.lastErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server Status")
                        .font(fontPreset.subHeadlineBoldFont)
                    Text(message)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                    Text(server.diagnostics.listenerStateDescription)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
            }

            // External client errors - only show if recent
            if let event = server.recentExternalClientEvent {
                if server.lastErrorMessage != nil {
                    Divider()
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .imageScale(.small)
                        Text("Client Connection Error")
                            .font(fontPreset.subHeadlineBoldFont)
                        if server.externalClientErrorCount > 1 {
                            Text("(\(server.externalClientErrorCount)× in last 5 min)")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.orange)
                        }
                    }
                    Text(server.contextualErrorDescription ?? event.userFacingDescription)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                    Text("Occurred: \(event.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary.opacity(0.8))
                    if let suggestion = event.troubleshootingSuggestion {
                        Text(suggestion)
                            .font(fontPreset.captionFont)
                            .foregroundColor(.blue)
                    }

                    Button("Dismiss") {
                        MCPExternalEventsMonitor.shared.clearLatestEvent()
                        showErrorPopover = false
                    }
                    .buttonStyle(CustomButtonStyle())
                    .padding(.top, 4)
                }
            }
        }
    }

    private func updateActiveToolCount() {
        activeToolCount = toolStore.advertisedTools.count(where: { toolStore.isEnabled($0.name) })
    }

    private func openSettingsToPresets() {
        NotificationCenter.default.post(
            name: .showModelPresetsTab,
            object: nil,
            userInfo: ["windowID": windowID]
        )
    }

    private func showPlanningModelHelp() {
        let alert = NSAlert()
        alert.messageText = "About Fallback Model"
        alert.informativeText = """
        When Model Presets are enabled but none are configured, MCP chat will use the fallback model you pick here.

        Tips:
        • Choose a model with strong reasoning for planning-oriented workflows.
        • This setting only applies when there are no presets; once presets exist, they control model selection.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: – Clipboard helper

    /// Copies a JSON configuration block that points to the **stable user-space
    /// symlink** (~/Library/Application Support/RepoPrompt/RepoPrompt) so editor
    /// integrations keep working after the app moves or updates.
    private func copyMCPConfigToClipboard() {
        MCPIntegrationHelper.copyConfigToClipboard()
    }

    /// Builds a Cursor deeplink and opens it to install the MCP server
    /// configuration. Uses the stable user-space symlink so future app moves
    /// don't break the integration.
    private func installInCursor() {
        MCPIntegrationHelper.installInCursor()
    }

    /// Attempts to merge RepoPrompt MCP entry into Claude Desktop config.
    /// Returns true on success.  Will NOT create the \"Claude\" directory if missing.
    private func installInClaude() -> Bool {
        MCPIntegrationHelper.installInClaude()
    }
}

private struct StatusButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverableButton(configuration: configuration) { hovering in
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(
                            hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02)
                        )
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(hovering ? 0.15 : 0.08), lineWidth: 1)
                )
                .foregroundColor(.primary.opacity(0.8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}
