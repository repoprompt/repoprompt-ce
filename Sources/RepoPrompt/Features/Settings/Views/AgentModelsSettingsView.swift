//
//  AgentModelsSettingsView.swift
//  RepoPrompt
//
//  Unified Agent Models settings page (Extension B, phases 1–3 of the 2026-04-17
//  Settings UI plan). This is the single home for every agent-mode model choice:
//  Oracle, Built-in Chat, Context Builder agent, and MCP agent role defaults.
//
//  SEARCH-HELPER: Agent Models, Oracle Model, Built-in Chat Model,
//  Context Builder Agent, Sub-Agent Role Defaults, Agent Role Defaults,
//  Apply Recommended Setup, Planning Model, MCP Model Presets
//
//  Related:
//  - VM:            /RepoPrompt/ViewModels/AgentModeUI/AgentModelsSettingsViewModel.swift
//  - Engine:        /RepoPrompt/Services/Recommendations/AutoRecommendationEngine.swift
//  - Role defaults: /RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift
//  - Oracle picker: /RepoPrompt/Views/Settings/AIModelDropDown.swift
//

import SwiftUI

/// Single source of truth for agent-mode model configuration: Oracle model,
/// Context Builder agent, MCP role defaults, and the Built-in Chat model
/// override. Recommendations from `AutoRecommendationEngine` are shown
/// inline with row-level and bulk Apply controls.
struct AgentModelsSettingsView: View {
    @ObservedObject var promptVM: PromptViewModel
    @ObservedObject var apiSettingsVM: APISettingsViewModel
    let windowID: Int
    let workspaceID: UUID?
    let workspaceName: String?
    var onNavigate: ((SettingsTab) -> Void)?

    @StateObject private var viewModel: AgentModelsSettingsViewModel
    @State private var showAdvanced: Bool = false
    @State private var showSettingsPopover: Bool = false
    @State private var showCopyWorkspaceToGlobalConfirmation: Bool = false

    init(
        promptVM: PromptViewModel,
        apiSettingsVM: APISettingsViewModel,
        windowID: Int,
        workspaceID: UUID? = nil,
        workspaceName: String? = nil,
        settingsManager: (any SettingsManaging)? = nil,
        onNavigate: ((SettingsTab) -> Void)? = nil,
        viewModel: AgentModelsSettingsViewModel? = nil
    ) {
        self.promptVM = promptVM
        self.apiSettingsVM = apiSettingsVM
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.onNavigate = onNavigate
        _viewModel = StateObject(wrappedValue: viewModel ?? AgentModelsSettingsViewModel(
            apiSettingsVM: apiSettingsVM,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            settingsManager: settingsManager
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                scopeRoutingSection
                if viewModel.showsRecommendationActions {
                    recommendationBanner
                }
                oracleSection
                contextBuilderSection
                roleDefaultsSection
                advancedSection
                relatedSettingsSection
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .onAppear {
            viewModel.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: workspaceName)
            viewModel.refresh()
        }
        .onChange(of: workspaceID) { _, newWorkspaceID in
            viewModel.updateWorkspaceContext(workspaceID: newWorkspaceID, workspaceName: workspaceName)
        }
        .onChange(of: workspaceName) { _, newWorkspaceName in
            viewModel.updateWorkspaceContext(workspaceID: workspaceID, workspaceName: newWorkspaceName)
        }
        .confirmationDialog(
            "Copy workspace settings to global?",
            isPresented: $showCopyWorkspaceToGlobalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Copy to Global", role: .destructive) {
                viewModel.copyWorkspaceSettingsToGlobal()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites the global Agent Models profile used by all workspaces that inherit global settings.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Agent Models")
                    .font(.title2).bold()
            }
            Text("Pick the models and CLI agents used by Oracle, Context Builder, and MCP-launched agent roles. Recommendations come from the same engine as the setup wizard.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                scopeChip(
                    label: viewModel.effectiveScopeDescription,
                    systemImage: viewModel.isEditingWorkspaceSettings ? "rectangle.stack.badge.person.crop" : "globe"
                )
                if let workspaceName = viewModel.workspaceDisplayName {
                    scopeChip(label: "Workspace: \(workspaceName)", systemImage: "rectangle.stack")
                }
            }
        }
    }

    private func scopeChip(label: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(label)
                .font(.caption)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(4)
    }

    // MARK: - Scope routing

    private var scopeRoutingSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(viewModel.workspaceAgentModelsTitle)
                        .font(.headline)
                    Spacer(minLength: 0)
                }

                if viewModel.hasWorkspace {
                    Picker("Agent Models scope", selection: Binding(
                        get: { viewModel.inheritanceMode },
                        set: { viewModel.setInheritanceMode($0) }
                    )) {
                        Text("Use global settings").tag(AgentModelsInheritanceMode.useGlobalSettings)
                        Text("Use workspace overrides").tag(AgentModelsInheritanceMode.useWorkspaceOverrides)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Agent Models inheritance mode")

                    Text(scopeRoutingExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    scopeCopySettingsFooter
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text(viewModel.noWorkspaceExplanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(6)
                }
            }
        }
    }

    private var scopeRoutingExplanation: String {
        switch viewModel.inheritanceMode {
        case .useGlobalSettings:
            "This workspace will use global Agent Models settings. Changes below edit global settings."
        case .useWorkspaceOverrides:
            "This workspace will use workspace-specific Agent Models overrides. Changes below edit this workspace only."
        }
    }

    private var scopeCopySettingsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.top, 2)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scopeCopySettingsTitle)
                        .font(.callout).bold()
                    Text(scopeCopySettingsDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(scopeCopySettingsButtonTitle) {
                    if viewModel.isEditingWorkspaceSettings {
                        showCopyWorkspaceToGlobalConfirmation = true
                    } else {
                        viewModel.copyGlobalSettingsToWorkspaceOverrides()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var scopeCopySettingsTitle: String {
        viewModel.isEditingWorkspaceSettings
            ? "Copy workspace settings to global"
            : "Copy global settings to workspace"
    }

    private var scopeCopySettingsDescription: String {
        viewModel.isEditingWorkspaceSettings
            ? "Overwrite global Agent Models settings with this workspace’s current overrides."
            : "Create workspace overrides from the current global Agent Models settings and switch this workspace to Use workspace overrides."
    }

    private var scopeCopySettingsButtonTitle: String {
        viewModel.isEditingWorkspaceSettings ? "Copy to Global" : "Copy to Workspace"
    }

    // MARK: - Recommendation Banner

    @ViewBuilder
    private var recommendationBanner: some View {
        if viewModel.hasUnsatisfiedRecommendations {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                    Text("Recommended setup available")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.applyAllRecommendations()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text("Apply Recommended Setup")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isApplyingAll)
                }

                previewLines
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.yellow.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent models are up to date")
                        .font(.callout).bold()
                    Text("Oracle, Context Builder, and role defaults match the current recommendations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.green.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var previewLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let oracle = viewModel.recommendedOracleModelName,
               !viewModel.isOracleRecommendationSatisfied
            {
                previewLine(icon: "sparkle.magnifyingglass", text: "Oracle: \(oracle)")
            }
            if let cb = viewModel.recommendedContextBuilderDescription,
               !viewModel.isContextBuilderRecommendationSatisfied
            {
                previewLine(icon: "doc.text.magnifyingglass", text: "Context Builder: \(cb)")
            }
            if let agentDefaults = viewModel.recommendations.mcpAgentDefaults,
               !agentDefaults.alreadySatisfied
            {
                let differingCount = roleDefaultDiffCount(for: agentDefaults)
                previewLine(icon: "person.3", text: "Role defaults: \(differingCount) of \(agentDefaults.recommendedRoleDefaults.count) differ")
            }
        }
    }

    private func previewLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleDefaultDiffCount(for rec: MCPAgentDefaultsRecommendation) -> Int {
        zip(rec.currentRoleDefaults, rec.recommendedRoleDefaults).reduce(0) { acc, pair in
            pair.0.selectionIDRaw != pair.1.selectionIDRaw ? acc + 1 : acc
        }
    }

    // MARK: - Oracle Row

    private var oracleSection: some View {
        settingsCard {
            sectionHeader(title: "Oracle Model", subtitle: "Used by ask_oracle, oracle_send, plan/review, and Context Builder analysis.")

            HStack(alignment: .center, spacing: 12) {
                AIModelDropdown(
                    promptViewModel: promptVM,
                    showSettingsPopover: $showSettingsPopover,
                    windowID: windowID,
                    useBorderlessStyle: false,
                    isInGeneralSettings: true,
                    destination: viewModel.oracleModelDestination
                )

                Spacer(minLength: 0)

                if viewModel.showsRecommendationActions,
                   let recommendedName = viewModel.recommendedOracleModelName,
                   !viewModel.isOracleRecommendationSatisfied
                {
                    Text("Recommended: \(recommendedName)")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Button("Apply") {
                        viewModel.applyOracleRecommendation()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("Using: \(viewModel.currentOracleModelName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Context Builder Row

    private var contextBuilderSection: some View {
        settingsCard {
            sectionHeader(title: "Context Builder Agent", subtitle: "Used to discover files and build optimized context for Oracle, plans, and reviews.")

            if !viewModel.hasConnectedCLIProvider {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Connect a CLI agent to configure Context Builder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        onNavigate?(.cliProviders)
                    } label: {
                        Label("Connect in CLI Providers", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    StableMenuButton(
                        items: { viewModel.contextBuilderAgentModelMenuItems(windowID: windowID) },
                        triggerStyle: .plain
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            AgentModelSelectionSummaryLabel(
                                agentKind: viewModel.selectedContextBuilderAgent,
                                rawModel: viewModel.selectedContextBuilderModelRaw,
                                title: "\(viewModel.selectedContextBuilderAgent.displayName) · \(viewModel.selectedContextBuilderDisplayName)",
                                iconFont: .caption
                            )
                            .font(.callout)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                    }

                    Spacer(minLength: 0)

                    if viewModel.showsRecommendationActions,
                       let recommendedCB = viewModel.recommendedContextBuilderDescription,
                       !viewModel.isContextBuilderRecommendationSatisfied
                    {
                        Text("Recommended: \(recommendedCB)")
                            .font(.caption)
                            .foregroundColor(.orange)

                        Button("Apply") {
                            viewModel.applyContextBuilderRecommendation()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Role Defaults

    private var roleDefaultsSection: some View {
        settingsCard {
            sectionHeader(title: "Sub-Agent Role Defaults", subtitle: "Used when MCP clients launch sub-agents with task labels (explore, engineer, pair, design).")

            roleLabelDiscoveryRestrictionToggle

            if !viewModel.hasConnectedCLIProvider {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Connect Claude Code, Codex, OpenCode, or Cursor to configure role defaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        onNavigate?(.cliProviders)
                    } label: {
                        Label("Connect in CLI Providers", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
            } else {
                ForEach(viewModel.roleDefaultsResolutions, id: \.role) { resolution in
                    roleDefaultRow(resolution)
                }
                if viewModel.roleDefaultsHasOverrides {
                    HStack {
                        Spacer()
                        Button("Reset All to Recommended") {
                            viewModel.resetAllRoleDefaults()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.caption)
                    }
                }
            }
        }
    }

    /// Toggle that controls whether MCP `agent_manage list_agents` advertises
    /// the extra per-agent compound model catalog in addition to the four
    /// sub-agent role labels and their concrete mappings. Lives directly under
    /// the section header so it's visually tied to the role default rows it
    /// governs.
    ///
    /// SEARCH-HELPER: hide non-role MCP models, restrict MCP discovery toggle,
    /// list_agents model catalog UI
    private var roleLabelDiscoveryRestrictionToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.restrictMCPAgentDiscoveryToRoleLabels },
            set: { viewModel.restrictMCPAgentDiscoveryToRoleLabels = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide non-role models from MCP agents")
                    .font(.callout)
                Text("When on, agent_manage list_agents still shows explore, engineer, pair, and design with their model mappings, but hides the extra per-agent model catalog so agents don’t browse unrelated model IDs. Manually supplied compound IDs are still accepted, so this is a discovery filter — not an access-control boundary.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    private func roleDefaultRow(_ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: iconForRole(resolution.role))
                    .font(.callout)
                    .foregroundColor(colorForRole(resolution.role))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(resolution.roleLabel.uppercased())
                        .font(.caption.bold())
                    Text(resolution.roleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                StableMenuButton(
                    items: { viewModel.roleDefaultMenuItems(for: resolution) },
                    triggerStyle: .plain
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: resolution.effective.agent.iconName)
                            .font(.system(size: 11))
                        AgentModelSelectionSummaryLabel(
                            agentKind: resolution.effective.agent,
                            rawModel: resolution.effective.modelRaw,
                            title: resolution.effectiveDisplayName,
                            iconFont: .system(size: 9, weight: .semibold)
                        )
                        .font(.system(size: 11))
                        .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                }
                .fixedSize()
            }

            let pinState = resolution.pinState
            if let message = pinState.message,
               let actionTitle = pinState.actionTitle
            {
                HStack(spacing: 6) {
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(pinState.usesWarningStyle ? .orange : .secondary)
                    Button(actionTitle) {
                        viewModel.applyRoleDefault(resolution)
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(.leading, 30)
            }
        }
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

    // MARK: - Advanced

    private var advancedSection: some View {
        // Custom expandable section (not SwiftUI's DisclosureGroup) so the entire
        // "Advanced" label is tappable — DisclosureGroup on macOS only reliably
        // toggles from the small chevron, which users routinely miss.
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showAdvanced.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: showAdvanced)
                    Text("Advanced")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    syncToggleRow
                    if !viewModel.syncChatWithOracle {
                        builtinChatRow
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Related Settings

    /// Visible by default. Previously these link rows were hidden inside the
    /// "Advanced" disclosure. "Advanced" now owns only real tunables
    /// (Sync toggle, Built-in Chat override) so related-settings navigation
    /// no longer requires a click to uncover.
    ///
    /// SEARCH-HELPER: Agent Models related settings, Oracle Model Presets link,
    /// Benchmark Model link, related-settings footer
    private var relatedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related Settings")
                .font(.headline)
                .foregroundColor(.secondary)

            linkRow(
                icon: "cpu",
                title: "Oracle Model Presets",
                detail: "Named Oracle model choices exposed to MCP clients.",
                tab: .modelPresets
            )
            linkRow(
                icon: "gauge",
                title: "Benchmark Model",
                detail: "Head-to-head model benchmarks.",
                tab: .benchmark
            )
        }
        .padding(.top, 8)
    }

    private var syncToggleRow: some View {
        Toggle(isOn: Binding(
            get: { viewModel.syncChatWithOracle },
            set: { viewModel.syncChatWithOracle = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep Built-in Chat Model synced with Oracle Model")
                    .font(.callout)
                Text("When on, picking an Oracle model updates the Built-in Chat model to match. Turn off to override chat independently.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    private var builtinChatRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title: "Built-in Chat Model", subtitle: "Used by RepoPrompt's built-in chat UI (not Agent Mode). Defaults to the Oracle Model unless overridden here.")

            HStack(alignment: .center, spacing: 12) {
                AIModelDropdown(
                    promptViewModel: promptVM,
                    showSettingsPopover: $showSettingsPopover,
                    windowID: windowID,
                    useBorderlessStyle: false,
                    isInGeneralSettings: true,
                    destination: viewModel.builtinChatModelDestination
                )
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("Using: \(viewModel.currentBuiltinChatModelName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func settingsCard(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkRow(icon: String, title: String, detail: String, tab: SettingsTab) -> some View {
        Button {
            onNavigate?(tab)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.callout)
                    .frame(width: 18, alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout).bold()
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }
}

// Preview intentionally omitted: the view requires full PromptViewModel /
// ContextBuilderAgentViewModel / APISettingsViewModel instances that are only
// available through a live `WindowState`.
