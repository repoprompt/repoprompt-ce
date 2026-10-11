import RepoPromptFileSystem

//
//  AgentSubagentPolicySettingsView.swift
//  RepoPrompt
//
//  Sub-Agents scope of the Agent Permissions settings tab.
//
//  Controls the sub-agent sandbox override policy that applies when another agent
//  launches a sub-agent through MCP. Does **not** control MCP tool advertisement or
//  RepoPrompt workspace operation approvals — those remain separate Settings surfaces.
//
//  SEARCH-HELPER: Agent Permissions Sub-Agents scope, sub-agent sandbox policy,
//  sub-agent launch policy, Safe Managed, Inherit provider settings,
//  Custom per-provider, AgentSubagentPermissionsSettingsViewModel
//
//  Related:
//  - Shell:   /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
//  - VM:      /RepoPrompt/ViewModels/AgentModeUI/AgentSubagentPermissionsSettingsViewModel.swift
//  - Direct:  /RepoPrompt/Views/Settings/AgentDirectProviderPermissionsView.swift
//

import SwiftUI

/// Sub-agent sandbox override policy pane. Applies when another agent launches a
/// sub-agent through MCP.
struct AgentSubagentPolicySettingsView: View {
    @ObservedObject var viewModel: AgentSubagentPermissionsSettingsViewModel
    let availability: AgentModelCatalog.AvailabilityContext
    /// Reserved for parity with `AgentDirectProviderPermissionsView` and for future
    /// related deep-links (e.g. linking out to Workspace Approvals from the sub-agent
    /// pane). Currently unused.
    var onNavigate: ((SettingsTab) -> Void)?

    @State private var isPreviewExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.sectionSpacing) {
            policySection
        }
    }

    // MARK: - Policy section

    private var policySection: some View {
        AgentPermissionSettingsGroupBox(
            title: "Sub-agent sandbox policy",
            subtitle: "Applies to agents launched by another agent through MCP.",
            accent: sectionAccent,
            contentSpacing: AgentPermissionSettingsLayout.controlSpacing
        ) {
            statusRow

            Picker(
                "Sub-agent launch policy",
                selection: Binding(
                    get: { viewModel.globalPolicy },
                    set: { viewModel.setGlobalPolicy($0) }
                )
            ) {
                Text("Safe Managed").tag(AgentSubagentPermissionPolicy.safeManaged)
                Text("Inherit Provider").tag(AgentSubagentPermissionPolicy.inheritProviderSettings)
                Text("Custom").tag(AgentSubagentPermissionPolicy.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch viewModel.globalPolicy {
            case .safeManaged:
                safeManagedBody
            case .inheritProviderSettings:
                inheritWarningBanner
            case .custom:
                customPerProviderPanel
            }
        }
    }

    // MARK: - Status row

    private var statusRow: some View {
        let info = statusInfo
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: info.iconName)
                .font(.title3)
                .foregroundColor(info.tint)
            Text(info.statusText)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private struct StatusInfo {
        let statusText: String
        let iconName: String
        let tint: Color
    }

    private var statusInfo: StatusInfo {
        switch viewModel.globalPolicy {
        case .safeManaged:
            StatusInfo(
                statusText: "Sub-agents launch with Safe Managed defaults.",
                iconName: "checkmark.shield.fill",
                tint: .green
            )
        case .inheritProviderSettings:
            StatusInfo(
                statusText: "Sub-agents inherit your provider permissions, including permissive modes.",
                iconName: "exclamationmark.shield",
                tint: .orange
            )
        case .custom:
            StatusInfo(
                statusText: "Custom — per-provider sub-agent modes apply below.",
                iconName: "slider.horizontal.below.rectangle",
                tint: .accentColor
            )
        }
    }

    private var sectionAccent: Color {
        switch viewModel.globalPolicy {
        case .safeManaged: .green
        case .inheritProviderSettings: .orange
        case .custom: .accentColor
        }
    }

    // MARK: - Safe Managed body (progressive disclosure)

    private var safeManagedBody: some View {
        VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
            DisclosureGroup(isExpanded: $isPreviewExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    safeManagedBullets
                    Divider()
                    safeManagedPreview
                }
                .padding(.top, 8)
            } label: {
                // Wrap the label in a Button so the whole "Preview Safe
                // Managed profile" hit area toggles the disclosure group,
                // not just the chevron. `.plain` keeps the existing
                // secondary-bold-callout styling; `contentShape(Rectangle())`
                // expands the hit area to the full label width.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isPreviewExpanded.toggle()
                    }
                } label: {
                    Text("Preview Safe Managed profile")
                        .font(.callout).bold()
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview Safe Managed profile")
                .accessibilityHint(isPreviewExpanded ? "Collapses the Safe Managed preview." : "Expands the Safe Managed preview.")
            }
        }
    }

    private var safeManagedBullets: some View {
        VStack(alignment: .leading, spacing: 6) {
            bullet("File writes require approval or stay sandboxed to the workspace, except as noted for Grok Build.")
            bullet("Grok Build launched through MCP runs at Default. Its own permission rules, including rules from Claude Code `defaultMode`, can allow many requests (`bypassPermissions`) or edit tools such as `write` (`acceptEdits`) without asking RepoPrompt.")
            bullet("Bash/shell tools are disabled for Claude; Codex Bash is enabled.")
            bullet("Claude is forced to strict MCP; Codex user-toggled MCP servers are suppressed.")
            bullet("ACP providers use non-auto-accept session modes.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var safeManagedPreview: some View {
        let summaries = viewModel.safeManagedSummaries(availability: availability)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Effective per-provider profile")
                .font(.callout).bold()
                .foregroundColor(.secondary)
            ForEach(summaries) { summary in
                AgentPermissionCapabilityRow(summary: summary)
            }
        }
    }

    // MARK: - Inherit warning

    private var inheritWarningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sub-agents inherit provider permissions")
                    .font(.body).bold()
                    .foregroundColor(.orange)
                Text("If any provider is set to Full Access, sub-agents launched through MCP will inherit it. Use only in trusted environments.")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Custom per-provider

    private var customPerProviderPanel: some View {
        VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Per-provider sub-agent modes")
                    .font(.callout).bold()
                    .foregroundColor(.secondary)
                Text("Choose the concrete permission mode sub-agents use for each provider. These settings are independent of Direct Agents permissions.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(AgentProviderBindingID.allCases, id: \.self) { providerID in
                    customProviderRow(providerID: providerID)
                }
            }

            Text("Custom modes affect provider-native sandbox/permission behavior for future sub-agent launches. Direct-agent permission settings are unchanged.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Width used for the provider identity column in the Custom grid. Fixed so
    /// the picker column starts at the same x-position regardless of whether the
    /// label is "Claude Code", "Codex CLI", or a wider future name.
    private static let customProviderColumnWidth: CGFloat = 150

    /// Horizontal spacing between the provider column, picker column, and
    /// warning slot. Kept as a constant so the detail-text indent below the row
    /// can be computed from the same values.
    private static let customProviderColumnSpacing: CGFloat = 12

    /// Width used for the picker column in the Custom grid. Fixed so the
    /// warning glyph that follows sits at the same x-position on every row
    /// whether the selected mode is "Default" or "Auto-approve Edits".
    private static let customPickerColumnWidth: CGFloat = 280

    /// Width reserved for the warning triangle slot. The glyph is always laid
    /// out, just hidden when the selected mode is not warning-level, so rows
    /// line up vertically.
    private static let customWarningSlotWidth: CGFloat = 18

    @ViewBuilder
    private func customProviderRow(providerID: AgentProviderBindingID) -> some View {
        let selected = viewModel.providerPermissionLevelsByID[providerID]
            ?? AgentProviderPermissionLevelID.subagentDefault(for: providerID)
        let binding = Binding<AgentProviderPermissionLevelID>(
            get: {
                viewModel.providerPermissionLevelsByID[providerID]
                    ?? AgentProviderPermissionLevelID.subagentDefault(for: providerID)
            },
            set: { viewModel.setProviderPermissionLevel($0, for: providerID) }
        )
        let isAvailable = AgentPermissionCapabilitySummaryBuilder.isAvailable(
            providerID: providerID,
            availability: availability
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: Self.customProviderColumnSpacing) {
                // Provider identity column — fixed width so the picker column
                // lines up across rows regardless of display-name length.
                HStack(spacing: 8) {
                    Image(systemName: isAvailable ? "circle.fill" : "circle.dashed")
                        .font(.system(size: 10))
                        .foregroundColor(isAvailable ? .green : .secondary)
                    Text(providerID.displayName)
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: Self.customProviderColumnWidth, alignment: .leading)

                // Picker column — fixed width so the warning glyph slot that
                // follows stays at a consistent x-position instead of drifting
                // with the selected option's label width.
                Picker("", selection: binding) {
                    ForEach(AgentProviderPermissionLevelID.options(for: providerID), id: \.self) { level in
                        Label(level.displayName, systemImage: level.iconName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: Self.customPickerColumnWidth, alignment: .leading)

                // Reserved warning slot. Always laid out so rows line up
                // vertically, visually hidden when the selection is not
                // warning-level.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .opacity(selected.isWarning ? 1 : 0)
                    .accessibilityHidden(!selected.isWarning)
                    .frame(width: Self.customWarningSlotWidth, alignment: .leading)

                Spacer(minLength: 0)
            }

            if let detail = selected.detailText {
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(selected.isWarning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Indent under the picker column, not the provider column,
                    // so the detail reads as metadata for the selected mode.
                    .padding(.leading, Self.customProviderColumnWidth + Self.customProviderColumnSpacing)
            }
        }
        .padding(.vertical, 4)
    }
}
