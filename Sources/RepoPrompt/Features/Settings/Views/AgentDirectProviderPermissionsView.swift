//
//  AgentDirectProviderPermissionsView.swift
//  RepoPrompt
//
//  Direct-agent scope of the Agent Permissions settings tab.
//
//  Renders editable provider-native controls for agents that are launched directly in
//  RepoPrompt (not through MCP sub-agent launches). Backed by
//  `AgentProviderPermissionsSettingsViewModel` so mutations route through the binding
//  service and active sessions refresh via the existing path.
//
//  SEARCH-HELPER: Agent Permissions Direct Agents scope, top-level provider permissions,
//  editable provider rows, AgentProviderPermissionsSettingsViewModel,
//  Codex tools section, Claude tools section
//
//  Related:
//  - Shell:  /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
//  - VM:     /RepoPrompt/ViewModels/AgentModeUI/AgentProviderPermissionsSettingsViewModel.swift
//  - Sub:    /RepoPrompt/Views/Settings/AgentSubagentPolicySettingsView.swift
//

import SwiftUI

/// Direct/top-level CLI provider permissions pane. This does **not** control MCP tool
/// ACLs (see MCP Tools) or RepoPrompt workspace operation approvals (see Workspace
/// Approvals) — those remain separate Settings surfaces.
struct AgentDirectProviderPermissionsView: View {
    @ObservedObject var viewModel: AgentProviderPermissionsSettingsViewModel
    let availability: AgentModelCatalog.AvailabilityContext
    var onNavigate: ((SettingsTab) -> Void)?

    @State private var expandedProviderIDs: Set<AgentProviderBindingID> = []
    @State private var toolsDisclosedProviderIDs: Set<AgentProviderBindingID> = []

    var body: some View {
        let summaries = viewModel.summaries(availability: availability)
        let connected = summaries.filter(\.isAvailable)
        let disconnected = summaries.filter { !$0.isAvailable }

        AgentPermissionSettingsGroupBox(
            title: "Provider Permissions",
            subtitle: "Applies to agents launched directly from RepoPrompt.",
            accent: .secondary,
            contentSpacing: AgentPermissionSettingsLayout.controlSpacing
        ) {
            if connected.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("No CLI providers connected. Connect one in CLI Providers to configure its permissions here.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            } else {
                VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
                    ForEach(connected) { summary in
                        providerCapabilityRow(summary: summary, editable: true)
                    }
                }
            }

            if !disconnected.isEmpty {
                // Disconnected providers are surfaced inline (not hidden behind a
                // disclosure) so users can see which CLIs are missing at a glance and
                // connect them without an extra click. When a provider becomes
                // connected it promotes into the main list above automatically.
                VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
                    Text("Not connected")
                        .font(.footnote).bold()
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                    ForEach(disconnected) { summary in
                        providerCapabilityRow(summary: summary, editable: false)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    onNavigate?(.cliProviders)
                } label: {
                    Label("Open CLI Providers", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Capability row

    @ViewBuilder
    private func providerCapabilityRow(
        summary: AgentPermissionCapabilitySummary,
        editable: Bool
    ) -> some View {
        let providerID = summary.providerID
        let isExpanded = expandedProviderIDs.contains(providerID)
        let canExpand = editable && summary.isAvailable

        AgentPermissionCapabilityRow(
            summary: summary,
            canExpand: canExpand,
            isExpanded: isExpanded,
            onToggleExpansion: { toggleExpansion(providerID) },
            expansion: { providerControls(for: providerID) }
        )
    }

    private func toggleExpansion(_ providerID: AgentProviderBindingID) {
        if expandedProviderIDs.contains(providerID) {
            expandedProviderIDs.remove(providerID)
        } else {
            expandedProviderIDs.insert(providerID)
        }
    }

    private func toggleToolsDisclosure(_ providerID: AgentProviderBindingID) {
        if toolsDisclosedProviderIDs.contains(providerID) {
            toolsDisclosedProviderIDs.remove(providerID)
        } else {
            toolsDisclosedProviderIDs.insert(providerID)
        }
    }

    // MARK: - Provider-native control panels

    @ViewBuilder
    private func providerControls(for providerID: AgentProviderBindingID) -> some View {
        if let binding = viewModel.controlsBinding(for: providerID) {
            VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
                AgentProviderPermissionLevelSection(
                    binding: binding.permission,
                    onSelectPermissionLevel: { viewModel.setPermissionLevel($0) }
                )

                AgentProviderToolsRuntimeDisclosure(
                    providerID: providerID,
                    binding: binding,
                    title: "Tools & Runtime Options",
                    isExpanded: toolsDisclosedProviderIDs.contains(providerID),
                    onToggle: { toggleToolsDisclosure(providerID) },
                    onApplyCodexToolSettingMutation: { viewModel.applyCodexToolSettingMutation($0) },
                    onApplyClaudeToolSettingMutation: { viewModel.applyClaudeToolSettingMutation($0) }
                )
            }
        } else {
            Text("Provider-native controls are not available in this context.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
