import SwiftUI

/// Popover for picking every sub-agent / role model choice in Agent Mode:
///
/// - Oracle / Plan model
/// - Context Builder agent + model (the MCP-facing selection)
/// - Sub-agent role defaults (explore / engineer / pair / design)
///
/// The popover intentionally stops at model selection. Token budgets,
/// clarifying-question timeouts, and other Context Builder tunables live on
/// the full Context Builder settings page. A small "More Context Builder
/// options" link deep-links there so advanced knobs are never more than one
/// click away.
///
/// SEARCH-HELPER: Agent Mode models popover, Oracle Plan model popover,
/// Context Builder agent popover, Sub-Agent Role Defaults popover,
/// explore engineer pair design role defaults, AgentWorkspaceRootsSectionView models button
///
/// Related:
/// - Bottom bar host:     /RepoPrompt/Views/AgentMode/Components/AgentWorkspaceRootsSectionView.swift
/// - Settings equivalent: /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
/// - Role defaults:       /RepoPrompt/Services/MCP/Agent/MCPAgentRoleDefaultsService.swift
struct AgentModelsPopoverView: View {
    @ObservedObject var promptViewModel: PromptViewModel
    /// Not `@ObservedObject` — this popover only reads the derived
    /// `agentModeAvailabilityContext` when building role-default menus. Treating
    /// it as plain state avoids invalidating the popover on unrelated API
    /// settings changes.
    let apiSettingsVM: APISettingsViewModel
    let windowID: Int

    @State private var showSettingsPopover = false
    /// Bumps whenever role-default overrides change, whether from this popover
    /// or an external source (recommendations, settings page, MCP). Observes
    /// `.recommendationsShouldRefresh` so the popover never shows stale
    /// effective selections while it is open.
    @State private var roleDefaultsRevision = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var popoverWidth: CGFloat {
        fontPreset.scaledClamped(360, max: 520)
    }

    private var popoverMaxHeight: CGFloat {
        fontPreset.scaledClamped(680, max: 820)
    }

    private var roleLabelWidth: CGFloat {
        fontPreset.scaledClamped(64, max: 86)
    }

    private var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    private var roleResolutions: [MCPAgentRoleDefaultsService.RoleDefaultResolution] {
        _ = roleDefaultsRevision
        return MCPAgentRoleDefaultsService.resolutions(availability: availability, workspaceID: promptViewModel.currentWorkspaceID)
    }

    private var hasRoleOverrides: Bool {
        _ = roleDefaultsRevision
        return MCPAgentRoleDefaultsService.hasStoredOverrides(
            workspaceID: promptViewModel.currentWorkspaceID
        )
    }

    private var currentOperationIdentity: AgentModelsOperationIdentity? {
        guard let workspaceID = promptViewModel.currentWorkspaceID else { return nil }
        let inheritanceMode = GlobalSettingsStore.shared
            .workspaceAgentModelsSettings(for: workspaceID)
            .inheritanceMode
        return AgentModelsOperationIdentity(
            sourceWorkspaceID: workspaceID,
            inheritanceMode: inheritanceMode
        )
    }

    private var editingScope: AgentModelsEditingScope {
        currentOperationIdentity?.scope ?? .global
    }

    private var hasConnectedCLIProvider: Bool {
        !AgentModelCatalog.selectableAgents(availability: availability).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                recommendationBanner

                Divider()

                oraclePlanModelSection

                Divider()

                contextBuilderSection

                Divider()

                roleDefaultsSection

                Divider()

                moreOptionsLinks
            }
            .padding(16)
            .frame(width: popoverWidth, alignment: .leading)
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
        .onReceive(
            NotificationCenter.default
                .publisher(for: .recommendationsShouldRefresh)
                .receive(on: RunLoop.main)
        ) { _ in
            // Bumps the revision so `roleResolutions` recomputes when role
            // defaults are mutated elsewhere (settings page, recommendation
            // wizard, or external MCP callers).
            roleDefaultsRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .recommendationsDidApply)
                .receive(on: RunLoop.main)
        ) { _ in
            roleDefaultsRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentModelsSettingsDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            let scopeRaw = notification.userInfo?[AgentModelsSettingsNotification.scopeKey] as? String
            let workspaceID = notification.userInfo?[AgentModelsSettingsNotification.workspaceIDKey] as? UUID
            if scopeRaw == AgentModelsSettingsNotification.Scope.workspace.rawValue,
               workspaceID != promptViewModel.currentWorkspaceID
            {
                return
            }
            roleDefaultsRevision &+= 1
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("Models")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Oracle Plan Model

    private var oraclePlanModelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Oracle / Plan Model")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.secondary)

            AIModelDropdown(
                promptViewModel: promptViewModel,
                showSettingsPopover: $showSettingsPopover,
                windowID: windowID,
                useBorderlessStyle: false,
                isInGeneralSettings: false,
                destination: .planningModel(promptVM: promptViewModel)
            )

            Text("Used by ask_oracle, oracle_send, and context_builder plan/review.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Context Builder

    private var contextBuilderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context Builder Agent")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.secondary)

            contextBuilderPicker

            Text("Agent and model used for the context_builder MCP tool.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextBuilderPicker: some View {
        StableMenuButton(
            items: contextBuilderAgentModelMenuItems,
            triggerStyle: .plain
        ) {
            HStack(spacing: 6) {
                Image(systemName: promptViewModel.contextBuilderAgent.iconName)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    .foregroundColor(.secondary)
                AgentModelSelectionSummaryLabel(
                    agentKind: promptViewModel.contextBuilderAgent,
                    rawModel: promptViewModel.contextBuilderAgentModelRaw,
                    title: "\(promptViewModel.contextBuilderAgent.displayName) · \(promptViewModel.contextBuilderAgentModelDisplayName)",
                    iconFont: fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold)
                )
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, fontPreset.scaledClamped(8, max: 11))
            .padding(.vertical, fontPreset.scaledClamped(5, max: 8))
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
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
                let identity = currentOperationIdentity
                promptViewModel.contextBuilderAgent = selectedAgent
                promptViewModel.selectContextBuilderAgentModel(rawModel: selectedOption.rawValue)
                promptViewModel.commitContextBuilderSettings()
                DispatchQueue.main.async {
                    guard let identity else { return }
                    RecommendationApplyNotification.post(
                        sourceWorkspaceID: identity.sourceWorkspaceID,
                        agentModelsScope: identity.scope,
                        includesPresetExposure: false
                    )
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

    // MARK: - Role Defaults

    private var roleDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Sub-Agent Role Defaults")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if hasRoleOverrides {
                    Button("Reset") {
                        MCPAgentRoleDefaultsService.clearAllOverrides(
                            scope: editingScope
                        )
                        bumpRoleDefaults()
                    }
                    .buttonStyle(.plain)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.accentColor)
                }
            }

            if !hasConnectedCLIProvider {
                roleDefaultsEmptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(roleResolutions, id: \.role) { resolution in
                        roleDefaultRow(resolution)
                    }
                }

                Text("Used when MCP clients launch sub-agents by task label (explore, engineer, pair, design).")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var roleDefaultsEmptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
            Text("Connect a CLI agent to configure role defaults.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func roleDefaultRow(
        _ resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: iconForRole(resolution.role))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                    .foregroundColor(colorForRole(resolution.role))
                    .frame(width: fontPreset.scaledClamped(14, max: 20))

                Text(resolution.roleLabel)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                    .frame(width: roleLabelWidth, alignment: .leading)

                Spacer(minLength: 4)

                StableMenuButton(
                    items: { roleDefaultMenuItems(for: resolution) },
                    triggerStyle: .plain
                ) {
                    HStack(spacing: 4) {
                        Image(systemName: resolution.effective.agent.iconName)
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        // No `.fixedSize()` on the row — long model display names
                        // truncate instead of overflowing the 340pt popover.
                        AgentModelSelectionSummaryLabel(
                            agentKind: resolution.effective.agent,
                            rawModel: resolution.effective.modelRaw,
                            title: resolution.effectiveDisplayName,
                            iconFont: fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold)
                        )
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, fontPreset.scaledClamped(6, max: 9))
                    .padding(.vertical, fontPreset.scaledClamped(3, max: 5))
                    .background(
                        RoundedRectangle(cornerRadius: fontPreset.scaledClamped(4, max: 6))
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .layoutPriority(1)
            }

            roleDefaultPinState(for: resolution)
        }
    }

    @ViewBuilder
    private func roleDefaultPinState(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> some View {
        let pinState = resolution.pinState
        if let message = pinState.message,
           let actionTitle = pinState.actionTitle
        {
            HStack(spacing: 6) {
                Text(message)
                    .foregroundColor(pinState.usesWarningStyle ? .orange : .secondary)
                clearRoleDefaultButton(for: resolution.role, title: actionTitle)
            }
            .font(fontPreset.swiftUIFont(sizeAtNormal: 9))
            .padding(.leading, fontPreset.scaledClamped(22, max: 30))
        }
    }

    private func clearRoleDefaultButton(
        for role: AgentModelCatalog.TaskLabelKind,
        title: String
    ) -> some View {
        Button(title) {
            MCPAgentRoleDefaultsService.clearOverride(
                for: role,
                scope: editingScope
            )
            bumpRoleDefaults()
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    private func roleDefaultMenuItems(
        for resolution: MCPAgentRoleDefaultsService.RoleDefaultResolution
    ) -> [StableMenuItem] {
        var items = AgentModelCatalog.selectableAgents(availability: availability).map { agent in
            AgentModelStableMenuItems.agentSubmenu(
                agentKind: agent,
                options: AgentModelCatalog.options(for: agent, availability: availability),
                selectedAgent: resolution.effective.agent,
                selectedModelRaw: resolution.effective.modelRaw,
                includePlaceholderDefault: false,
                flattenSingleCodexGroups: true,
                groupOpenCode: false
            ) { selectedAgent, selectedOption in
                let selection = AgentModelCatalog.NormalizedAgentSelection(
                    agent: selectedAgent,
                    modelRaw: selectedOption.rawValue
                )
                _ = MCPAgentRoleDefaultsService.setSelection(
                    selection,
                    for: resolution.role,
                    availability: availability,
                    scope: editingScope
                )
                bumpRoleDefaults()
            }
        }
        if resolution.hasStoredOverride {
            items.insert(.separator, at: 0)
            items.insert(StableMenuItem.action("Use Recommended", imageSystemName: "arrow.counterclockwise") {
                MCPAgentRoleDefaultsService.clearOverride(
                    for: resolution.role,
                    scope: editingScope
                )
                bumpRoleDefaults()
            }, at: 0)
        }
        return items
    }

    private func bumpRoleDefaults() {
        roleDefaultsRevision &+= 1
        DispatchQueue.main.async {
            var userInfo: [String: Any] = ["reason": "agentRoleDefaultsChanged"]
            if let workspaceID = promptViewModel.currentWorkspaceID,
               GlobalSettingsStore.shared.workspaceAgentModelsSettings(for: workspaceID).inheritanceMode == .useWorkspaceOverrides
            {
                userInfo["workspaceID"] = workspaceID
            }
            NotificationCenter.default.post(
                name: .recommendationsShouldRefresh,
                object: nil,
                userInfo: userInfo
            )
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

    // MARK: - More options links

    private var moreOptionsLinks: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSidebarPopoverLinkRow(
                icon: "sparkles",
                title: "Context Builder Options",
                detail: "Token budgets, enhancement mode, and clarifying-question timeouts."
            ) {
                NotificationCenter.default.post(
                    name: .showContextBuilderSettingsTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
            AgentSidebarPopoverLinkRow(
                icon: "brain",
                title: "All Agent Models",
                detail: "Full Agent Models settings page with recommendations and advanced options."
            ) {
                NotificationCenter.default.post(
                    name: .showAgentModelsSettingsTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
        }
    }

    // MARK: - Recommendation Banner

    private var recommendationBanner: some View {
        Button(action: {
            NotificationCenter.default.post(
                name: .showRecommendationWizard,
                object: nil,
                userInfo: ["windowID": windowID]
            )
        }) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundColor(.blue)

                Text("Set recommended models")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
