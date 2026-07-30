import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject var vm: MCPServerViewModel
    @ObservedObject var promptVM: PromptViewModel
    let windowID: Int
    var onNavigate: ((SettingsTab) -> Void)?
    var closeAction: (() -> Void)?

    /// Scalar MCP preferences flow through GlobalSettingsStore so the JSON
    /// document stays authoritative.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    /// `showModelPresets` and `mcpTemporarilyDisablePresets` back read sites
    /// (onChange, if-checks) in addition to their Toggle bindings below.
    /// `autoStartServer` has no read sites, so we skip a computed accessor for it
    /// and go through the Binding directly.
    private var showModelPresets: Bool {
        globalSettings.mcpShowModelPresets()
    }

    private var mcpTemporarilyDisablePresets: Bool {
        globalSettings.mcpTemporarilyDisablePresets()
    }

    private var autoStartServerBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpAutoStart() },
            set: { globalSettings.setMCPAutoStart($0) }
        )
    }

    private var showModelPresetsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpShowModelPresets() },
            set: { globalSettings.setMCPShowModelPresets($0) }
        )
    }

    private var mcpTemporarilyDisablePresetsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.mcpTemporarilyDisablePresets() },
            set: { globalSettings.setMCPTemporarilyDisablePresets($0) }
        )
    }

    @State private var showSettingsPopover = false
    @State private var showErrorPopover = false
    @State private var showJSONConfig = false

    // CLI Installation state
    @State private var cliInstallStatus: CLIPathInstaller.InstallationStatus = .notInstalled
    @State private var claudeRPInstallStatus: CLIPathInstaller.ClaudeRPInstallationStatus = .notInstalled

    // Inline feedback
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var feedbackDismissTask: Task<Void, Never>?

    @ObservedObject private var toolStore = ToolAvailabilityStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var activeToolCount: Int = 0
    @State private var didCancelTool = false

    private var serverCommand: String {
        CLISymlinkManagerUserSpace.stableCLIPath
    }

    private var hasErrors: Bool {
        vm.lastErrorMessage != nil || vm.recentExternalClientEvent != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                headerSection

                Divider()

                serverControlSection
                Divider()
                modelPresetsSection
                Divider()
                contextBuilderSection
                Divider()
                quickSetupSection
                Divider()
                cliSection
                Divider()
                jsonConfigSection
            }
            .padding(20)
        }
        .animation(nil, value: vm.isRunning)
        .onAppear {
            refreshInstallStatuses()
            updateActiveToolCount()
        }
        .onChange(of: vm.activeToolName) { _, newValue in
            if newValue != nil { didCancelTool = false }
        }
        .onChange(of: toolStore.disabledTools) { updateActiveToolCount() }
        .onChange(of: toolStore.toolSummaries.count) { updateActiveToolCount() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .fixedSize(horizontal: false, vertical: true)

            if let client = vm.pendingClientID {
                Text("Waiting for approval: \(client)")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Pro Lock

    private var proLockSection: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 40 * fontPreset.scaleFactor))
                .foregroundColor(.orange)

            Text("Feature")
                .font(fontPreset.headlineFont)

            Text("MCP Server integration is available in RepoPrompt CE")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("OK") {}
                .buttonStyle(CustomButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Server Control

    private var serverControlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status and Toggle row
            HStack {
                statusIndicator

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

                if vm.activeToolName != nil {
                    Button(didCancelTool ? "Cancelled" : "Cancel") {
                        didCancelTool = true
                        Task { [weak vm] in vm?.cancelActiveTool() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(didCancelTool)
                    .hoverTooltip("Abort the current tool call")
                }

                Toggle("", isOn: $vm.windowToolsEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .hoverTooltip("Enable MCP tools for this window")
            }

            // Auto-start and connections
            HStack {
                Toggle("Auto-Start", isOn: autoStartServerBinding)
                    .font(fontPreset.font)
                    .hoverTooltip("Automatically start the MCP server when RepoPrompt launches")

                Spacer()

                MCPConnectionsCounter(server: vm, windowID: windowID, onDismiss: closeAction)
            }

            // Dashboard and shutdown buttons
            HStack(spacing: 10) {
                Button("Status Dashboard") {
                    closeAction?()
                    NotificationCenter.default.post(
                        name: .showMCPStatusWindow,
                        object: nil,
                        userInfo: ["windowID": windowID]
                    )
                }
                .buttonStyle(CustomButtonStyle())

                Button("Force Stop Listener") {
                    Task { await vm.shutdownListener() }
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Completely shuts down the listener for every window and client")
            }
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((vm.isRunning && vm.windowToolsEnabled) ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                if vm.windowToolsEnabled {
                    Text(vm.isRunning ? "Active" : "Waiting for listener…")
                        .font(fontPreset.font)
                        .foregroundColor(vm.isRunning ? .primary : .secondary)
                    HStack(spacing: 4) {
                        Text("Tools enabled")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                        if let running = vm.activeToolName {
                            Text("• Running \(running)")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.orange)
                        } else if activeToolCount > 0 {
                            Text("• \(activeToolCount) available")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if vm.isRunning {
                    Text("Listener active")
                        .font(fontPreset.font)
                        .foregroundColor(.secondary)
                    Text("Tools disabled for this window")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                } else {
                    Text("Inactive")
                        .font(fontPreset.font)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Model Presets

    private var modelPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Oracle Model Presets")
                    .font(fontPreset.subHeadlineBoldFont)

                Spacer()

                Button(action: {
                    NotificationCenter.default.post(
                        name: .showModelPresetsTab,
                        object: nil,
                        userInfo: ["windowID": windowID]
                    )
                    closeAction?()
                }) {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(CustomButtonStyle())
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
                let effectivePresets = mcpTemporarilyDisablePresets ? [] : ModelPresetsManager.shared.presets

                if effectivePresets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !mcpTemporarilyDisablePresets {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("No presets defined. Choose a model for MCP here.")
                                    .font(fontPreset.captionFont)
                                    .foregroundColor(.secondary)
                            }
                        }

                        AIModelDropdown(
                            promptViewModel: promptVM,
                            showSettingsPopover: $showSettingsPopover,
                            windowID: windowID,
                            useBorderlessStyle: false,
                            isInGeneralSettings: false,
                            destination: .planningModel(promptVM: promptVM)
                        )

                        if mcpTemporarilyDisablePresets {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12))
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
                            Text("When no presets exist, the Oracle Model is used.")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.secondary)
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

    // MARK: - Context Builder

    /// Read-only summary of the Context Builder agent/model choice.
    ///
    /// The canonical picker lives in Agent Models. This section keeps the
    /// MCP Server page oriented around server concerns (install, quick setup,
    /// JSON config) while still telling the user which agent/model will run
    /// when an MCP client invokes `context_builder`.
    private var contextBuilderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Builder")
                .font(fontPreset.subHeadlineBoldFont)

            Button {
                onNavigate?(.agentModels)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "brain")
                        .font(.callout)
                        .frame(width: 18, alignment: .center)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(promptVM.contextBuilderAgent.displayName) · \(promptVM.contextBuilderAgentModelDisplayName)")
                            .font(fontPreset.font).bold()
                            .foregroundColor(.primary)
                        Text("Used by the context_builder MCP tool. Configure in Agent Models.")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onNavigate == nil)
        }
    }

    // MARK: - Quick Setup

    private var quickSetupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick Setup")
                    .font(fontPreset.subHeadlineBoldFont)

                if let feedback = feedbackMessage {
                    Text(feedback)
                        .font(fontPreset.captionFont)
                        .foregroundColor(feedbackIsError ? .orange : .green)
                }
            }

            HStack(spacing: 10) {
                Menu {
                    Section("MCP Server") {
                        Button("Cursor") {
                            MCPIntegrationHelper.installInCursor()
                            showFeedback("Cursor configured")
                        }
                        Button("VS Code") {
                            MCPIntegrationHelper.installInVSCode()
                            showFeedback("VS Code configured")
                        }
                        Button("Codex CLI") {
                            let result = MCPIntegrationHelper.installInCodex()
                            showFeedback(
                                result.success
                                    ? (result.wasAlreadyPresent ? "Codex already configured" : "Codex configured")
                                    : (result.errorMessage ?? "Codex config failed"),
                                isError: !result.success
                            )
                        }
                        Button("OpenCode") {
                            let result = MCPIntegrationHelper.installInOpenCode()
                            showFeedback(result.success ? (result.wasAlreadyPresent ? "OpenCode already configured" : "OpenCode configured") : "OpenCode config failed", isError: !result.success)
                        }
                        Button("Claude Desktop") {
                            let success = MCPIntegrationHelper.installInClaude()
                            showFeedback(success ? "Claude Desktop configured" : "Claude Desktop not found", isError: !success)
                        }
                        Button("Claude Code (per-project)") {
                            let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                            guard !workspacePaths.isEmpty else {
                                showFeedback("Open a folder first", isError: true)
                                return
                            }
                            Task {
                                let result = await MCPIntegrationHelper.installInClaudeCode(workspacePaths: workspacePaths)
                                if result.success {
                                    showFeedback("Claude Code configured")
                                } else {
                                    showFeedback(result.lastErrorMessage ?? "Claude Code install failed", isError: true)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Install MCP…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Install the RepoPrompt MCP server in another application")

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
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: true)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let count = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: true)
                                showFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove", isError: false)
                            }
                        }

                        Menu("Per-project (.agents/skills)") {
                            Button("MCP skills") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                let count = MCPIntegrationHelper.uninstallAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallAgentsSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove", isError: false)
                            }
                        }
                        .disabled(promptVM.fileManager.visibleRootFolders.isEmpty)
                    }

                    Section {
                        Text("Claude Code (.claude/commands)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Menu("Per-project") {
                            Button("MCP skills") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                guard !workspacePaths.isEmpty else {
                                    showFeedback("Open a folder first", isError: true)
                                    return
                                }
                                let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let workspacePaths = promptVM.fileManager.visibleRootFolders.map(\.fullPath)
                                let count = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: workspacePaths, useCLIVariant: true)
                                showFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove", isError: false)
                            }
                        }
                        .disabled(promptVM.fileManager.visibleRootFolders.isEmpty)
                    }

                    Section {
                        Text("RepoPrompt Codex (isolated prompts)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Menu("Global") {
                            Button("MCP skills") {
                                let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: false)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: true)
                                showFeedback(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                            }
                            Divider()
                            Button("Uninstall") {
                                let count = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: false)
                                let cliCount = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: true)
                                showFeedback(count + cliCount > 0 ? "Skills removed" : "Nothing to remove", isError: false)
                            }
                        }
                    }
                } label: {
                    Label("Skills", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Install /rp-investigate and /rp-build slash skills")

                Button(action: {
                    MCPIntegrationHelper.copyConfigToClipboard()
                    showFeedback("Copied to clipboard")
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Copy MCP JSON configuration")
            }

            Text("If the integration doesn't show up right away, restart the client app after installing.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - CLI Section

    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLI Tools")
                .font(fontPreset.subHeadlineBoldFont)

            // RepoPrompt CE CLI
            HStack {
                cliStatusIcon(for: cliInstallStatus)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MCPIntegrationHelper.cliCommandName)
                        .font(.system(size: fontPreset.rawValue, design: .monospaced))
                        .fontWeight(.medium)
                    Text(cliStatusText(for: cliInstallStatus))
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                cliActionButton(for: cliInstallStatus, install: installCLI, uninstall: uninstallCLI)
            }

            // claude-rp
            HStack {
                claudeRPStatusIcon(for: claudeRPInstallStatus)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CLIPathInstaller.claudeRPCommandName)
                        .font(.system(size: fontPreset.rawValue, design: .monospaced))
                        .fontWeight(.medium)
                    Text(claudeRPStatusText(for: claudeRPInstallStatus))
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                Spacer()
                claudeRPActionButton(for: claudeRPInstallStatus, install: installClaudeRP, uninstall: uninstallClaudeRP)
            }

            Text("\(MCPIntegrationHelper.cliCommandName) lets you run MCP commands from your terminal. \(CLIPathInstaller.claudeRPCommandName) is a Claude Code wrapper that uses RepoPrompt's MCP tools.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if DEBUG
                Text("Debug builds install as \(MCPIntegrationHelper.cliCommandName) and \(CLIPathInstaller.claudeRPCommandName).")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.orange)
            #endif
        }
    }

    // MARK: - JSON Config

    private var jsonConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation { showJSONConfig.toggle() } }) {
                HStack {
                    Text("JSON Configuration")
                        .font(fontPreset.subHeadlineBoldFont)
                    Spacer()
                    Image(systemName: showJSONConfig ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showJSONConfig {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add this to your external app's MCP configuration:")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)

                    let configString = """
                    {
                      "mcpServers": {
                        "RepoPrompt": {
                          "command": "\(serverCommand)",
                          "args": []
                        }
                      }
                    }
                    """

                    Text(configString)
                        .font(.system(size: fontPreset.rawValue - 1, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)

                    Text("This path automatically stays valid when the app moves or updates.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Error Popover

    private var errorDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Error Details")
                .font(fontPreset.headlineFont)

            Divider()

            if let message = vm.lastErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server Status")
                        .font(fontPreset.subHeadlineBoldFont)
                    Text(message)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                    Text(vm.diagnostics.listenerStateDescription)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                    Button("Troubleshooting…") {
                        if let url = URL(string: "https://repoprompt.app/docs/mcp-troubleshooting") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(fontPreset.captionFont)
                }
            }

            if let event = vm.recentExternalClientEvent {
                if vm.lastErrorMessage != nil { Divider() }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .imageScale(.small)
                        Text("Client Connection Error")
                            .font(fontPreset.subHeadlineBoldFont)
                        if vm.externalClientErrorCount > 1 {
                            Text("(\(vm.externalClientErrorCount)× in last 5 min)")
                                .font(fontPreset.captionFont)
                                .foregroundColor(.orange)
                        }
                    }
                    Text(vm.contextualErrorDescription ?? event.userFacingDescription)
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

    // MARK: - Helpers

    private func updateActiveToolCount() {
        activeToolCount = toolStore.advertisedTools.count(where: { toolStore.isEnabled($0.name) })
    }

    private func refreshInstallStatuses() {
        cliInstallStatus = MCPIntegrationHelper.cliPathInstallStatus()
        claudeRPInstallStatus = CLIPathInstaller.checkClaudeRPStatus()
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedbackDismissTask?.cancel()
        feedbackMessage = message
        feedbackIsError = isError
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            feedbackMessage = nil
        }
    }

    /// CLI status helpers
    @ViewBuilder
    private func cliStatusIcon(for status: CLIPathInstaller.InstallationStatus) -> some View {
        switch status {
        case .installed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .installedButStale: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .notInstalled: Image(systemName: "circle").foregroundColor(.secondary)
        case .installedByOther: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .directoryMissing: Image(systemName: "folder.badge.questionmark").foregroundColor(.orange)
        }
    }

    private func cliStatusText(for status: CLIPathInstaller.InstallationStatus) -> String {
        switch status {
        case .installed: "Installed"
        case .installedButStale: "Needs update"
        case .notInstalled: "Not installed"
        case .installedByOther: "Exists but not managed"
        case .directoryMissing: "Directory missing"
        }
    }

    @ViewBuilder
    private func cliActionButton(for status: CLIPathInstaller.InstallationStatus, install: @escaping () -> Void, uninstall: @escaping () -> Void) -> some View {
        switch status {
        case .notInstalled, .directoryMissing:
            Button("Install") { install() }.buttonStyle(CustomButtonStyle())
        case .installed:
            Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
        case .installedButStale:
            HStack(spacing: 6) {
                Button("Update") { install() }.buttonStyle(CustomButtonStyle())
                Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
            }
        case .installedByOther:
            EmptyView()
        }
    }

    @ViewBuilder
    private func claudeRPStatusIcon(for status: CLIPathInstaller.ClaudeRPInstallationStatus) -> some View {
        switch status {
        case .installed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .installedButOutdated: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .notInstalled: Image(systemName: "circle").foregroundColor(.secondary)
        case .installedByOther: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .directoryMissing: Image(systemName: "folder.badge.questionmark").foregroundColor(.orange)
        }
    }

    private func claudeRPStatusText(for status: CLIPathInstaller.ClaudeRPInstallationStatus) -> String {
        switch status {
        case .installed: "Installed"
        case .installedButOutdated: "Needs update"
        case .notInstalled: "Not installed"
        case .installedByOther: "Exists but not managed"
        case .directoryMissing: "Directory missing"
        }
    }

    @ViewBuilder
    private func claudeRPActionButton(for status: CLIPathInstaller.ClaudeRPInstallationStatus, install: @escaping () -> Void, uninstall: @escaping () -> Void) -> some View {
        switch status {
        case .notInstalled, .directoryMissing:
            Button("Install") { install() }.buttonStyle(CustomButtonStyle())
        case .installed:
            Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
        case .installedButOutdated:
            HStack(spacing: 6) {
                Button("Update") { install() }.buttonStyle(CustomButtonStyle())
                Button("Uninstall") { uninstall() }.buttonStyle(CustomButtonStyle())
            }
        case .installedByOther:
            EmptyView()
        }
    }

    private func installCLI() {
        Task {
            do {
                try await MCPIntegrationHelper.installCLIToPath()
                refreshInstallStatuses()
                showFeedback("\(MCPIntegrationHelper.cliCommandName) installed")
            } catch {
                showFeedback("Install failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func uninstallCLI() {
        Task {
            do {
                try await MCPIntegrationHelper.uninstallCLIFromPath()
                refreshInstallStatuses()
                showFeedback("\(MCPIntegrationHelper.cliCommandName) removed")
            } catch {
                showFeedback("Uninstall failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func installClaudeRP() {
        Task {
            do {
                try await CLIPathInstaller.installClaudeRP()
                refreshInstallStatuses()
                showFeedback("\(CLIPathInstaller.claudeRPCommandName) installed")
            } catch {
                showFeedback("Install failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func uninstallClaudeRP() {
        Task {
            do {
                try await CLIPathInstaller.uninstallClaudeRP()
                refreshInstallStatuses()
                showFeedback("\(CLIPathInstaller.claudeRPCommandName) removed")
            } catch {
                showFeedback("Uninstall failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
}
