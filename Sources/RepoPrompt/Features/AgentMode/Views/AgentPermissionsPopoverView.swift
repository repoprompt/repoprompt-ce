import SwiftUI

/// Quick-access popover for sub-agent permission policy in Agent Mode.
///
/// Exposes the global sub-agent sandbox policy (Safe Managed / Inherit /
/// Custom) as a segmented picker with a short explainer, plus deep-links to
/// the full Agent Permissions settings page for direct-agent permissions and
/// per-provider overrides.
///
/// SEARCH-HELPER: Agent Mode permissions popover, Sub-agent Permissions popover,
/// Safe Managed popover, AgentWorkspaceRootsSectionView permissions button,
/// tri-state sub-agent policy, quick permissions
///
/// Related:
/// - Bottom bar host:  /RepoPrompt/Views/AgentMode/Components/AgentWorkspaceRootsSectionView.swift
/// - Full settings:    /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
/// - Focused VM:       /RepoPrompt/ViewModels/AgentModeUI/AgentSubagentPermissionsSettingsViewModel.swift
/// - Scope router:     /RepoPrompt/ViewModels/AgentModeUI/AgentPermissionsScopeRouter.swift
struct AgentPermissionsPopoverView: View {
    let windowID: Int

    @StateObject private var subagentVM = AgentSubagentPermissionsSettingsViewModel()
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            subagentPolicySection

            Divider()

            relatedLinks
        }
        .padding(14)
        .frame(width: fontPreset.scaledClamped(320, max: 440), alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("Permissions")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Sub-agent policy

    private var subagentPolicySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sub-Agent Sandbox Policy")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundColor(.secondary)

            Picker(
                "Sub-agent policy",
                selection: Binding(
                    get: { subagentVM.globalPolicy },
                    set: { subagentVM.setGlobalPolicy($0) }
                )
            ) {
                ForEach(AgentSubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(shortLabel(for: policy)).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Sub-agent sandbox policy")

            // Description + deep-link block. All three descriptions are sized
            // to roughly the same two-line footprint and the deep-link row is
            // always present so switching Safe / Inherit / Custom does not
            // bounce the popover height.
            VStack(alignment: .leading, spacing: 6) {
                Text(summaryDetail(for: subagentVM.globalPolicy))
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openPermissionsSettings(scope: .subagents)
                } label: {
                    HStack(spacing: 4) {
                        Text(deepLinkTitle(for: subagentVM.globalPolicy))
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                        Image(systemName: "arrow.up.forward")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                    }
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTooltip("Open Agent Permissions → Sub-Agents")
                .accessibilityLabel(
                    "\(deepLinkTitle(for: subagentVM.globalPolicy)) in Agent Permissions settings"
                )
            }

            if subagentVM.isSecurePermissionStorageDegraded {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundColor(.orange)
                    Text("Secure permission storage is degraded. Policy may not persist.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
    }

    private func shortLabel(for policy: AgentSubagentPermissionPolicy) -> String {
        switch policy {
        case .safeManaged: "Safe"
        case .inheritProviderSettings: "Inherit"
        case .custom: "Custom"
        }
    }

    /// One-sentence description of each policy. Kept to a similar length so
    /// switching between policies does not shift the popover vertically.
    private func summaryDetail(for policy: AgentSubagentPermissionPolicy) -> String {
        switch policy {
        case .safeManaged:
            "Sub-agents run with Safe Managed sandbox overrides. Recommended."
        case .inheritProviderSettings:
            "Sub-agents inherit your provider permissions, including permissive modes."
        case .custom:
            "Sub-agents use the per-provider modes configured for each CLI."
        }
    }

    /// Deep-link label that adapts to the selected policy so the Custom case
    /// has a clear "Edit per-provider modes" call-to-action without making the
    /// link row disappear for the other policies.
    private func deepLinkTitle(for policy: AgentSubagentPermissionPolicy) -> String {
        switch policy {
        case .safeManaged:
            "Review Safe Managed profile"
        case .inheritProviderSettings:
            "Open Sub-Agent Overrides"
        case .custom:
            "Edit per-provider modes"
        }
    }

    // MARK: - Related links

    private var relatedLinks: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSidebarPopoverLinkRow(
                icon: "person.crop.circle.badge.checkmark",
                title: "Direct Agents",
                detail: "Claude Bash, Codex sandbox, ACP session mode, and MCP strict mode for agents you run directly."
            ) {
                openPermissionsSettings(scope: .directAgents)
            }
            AgentSidebarPopoverLinkRow(
                icon: "lock.shield",
                title: "Sub-Agent Overrides",
                detail: "Per-provider policies, safe-managed summary, and secure-storage diagnostics."
            ) {
                openPermissionsSettings(scope: .subagents)
            }
            AgentSidebarPopoverLinkRow(
                icon: "shield.checkered",
                title: "Workspace Approvals",
                detail: "Approvals for RepoPrompt workspace operations (creating folders, deleting workspaces, etc.)."
            ) {
                NotificationCenter.default.post(
                    name: .showWorkspaceApprovalsSettingsTab,
                    object: nil,
                    userInfo: ["windowID": windowID]
                )
            }
        }
    }

    /// Record the requested scope via the shared router *before* posting the
    /// tab-open notification so the Agent Permissions view applies it whether
    /// it is already mounted (consumed on next `onAppear` / notification) or
    /// just about to mount (consumed on first `onAppear`).
    private func openPermissionsSettings(scope: AgentPermissionSettingsScope) {
        AgentPermissionsScopeRouter.shared.requestScope(scope)
        NotificationCenter.default.post(
            name: .showAgentPermissionsSettingsTab,
            object: nil,
            userInfo: ["windowID": windowID]
        )
        // Also post the legacy in-settings-window notification so an already
        // open settings window that is already on the Agent Permissions tab
        // picks up the scope immediately (router consumption happens on
        // `onAppear`, which does not fire when the view is already visible).
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .setAgentPermissionsScope,
                object: nil,
                userInfo: ["scope": scope.rawValue]
            )
        }
    }
}
