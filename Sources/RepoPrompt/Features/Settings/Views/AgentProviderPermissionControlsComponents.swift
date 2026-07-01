//
//  AgentProviderPermissionControlsComponents.swift
//  RepoPrompt
//
//  Shared provider-native permission/tool controls used by Agent Permissions and
//  CLI Providers. These views are intentionally stateless: callers own view models,
//  storage diagnostics, expansion state, and mutation closures.
//
//  SEARCH-HELPER: Shared provider permission controls, Codex tools runtime section,
//  Claude tools runtime section, CLI Providers inline permissions
//

import SwiftUI

struct AgentProviderPermissionLevelSection: View {
    let binding: AgentPermissionChromeBinding
    let onSelectPermissionLevel: (AgentProviderPermissionLevelID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(permissionLevelLabel(for: binding.providerID))
                    .font(.callout).bold()
                    .foregroundColor(.secondary)
                if binding.isWarning {
                    AgentPermissionRiskBadge(level: .caution)
                }
                Spacer(minLength: 0)
            }

            if let reason = binding.externallyManagedReason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text(reason)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)
            }

            if let selected = selectedPermissionOption(in: binding) {
                let pickerBinding = Binding<AgentProviderPermissionLevelID>(
                    get: { selected.id },
                    set: { onSelectPermissionLevel($0) }
                )

                Picker("", selection: pickerBinding) {
                    ForEach(binding.options) { option in
                        HStack(spacing: 6) {
                            Image(systemName: option.iconName)
                            Text(option.title)
                        }
                        .tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(binding.externallyManagedReason != nil)
                .frame(idealWidth: 320, maxWidth: 420, alignment: .leading)

                if let detail = selected.detailText,
                   !detail.isEmpty
                {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(binding.isWarning ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No permission options available for this provider.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Falls back to the first option when no option is flagged `isSelected`. Returns
    /// `nil` only when the binding has no options at all, keeping the UI crash-free.
    private func selectedPermissionOption(in binding: AgentPermissionChromeBinding) -> AgentPermissionOptionBinding? {
        binding.options.first(where: { $0.isSelected }) ?? binding.options.first
    }

    private func permissionLevelLabel(for providerID: AgentProviderBindingID) -> String {
        switch providerID {
        case .codex, .claude: "Permission Level"
        case .openCode: "ACP Session Mode"
        case .cursor: "ACP Auto-Approve"
        }
    }
}

struct AgentProviderToolsRuntimeDisclosure: View {
    let providerID: AgentProviderBindingID
    let binding: AgentProviderControlsBinding
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let onApplyCodexToolSettingMutation: (CodexToolSettingMutation) -> Void
    let onApplyClaudeToolSettingMutation: (ClaudeToolSettingMutation) -> Void

    var body: some View {
        if hasToolOptions {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        Text(title)
                            .font(.callout).bold()
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    AgentProviderToolsRuntimeControls(
                        providerID: providerID,
                        binding: binding,
                        onApplyCodexToolSettingMutation: onApplyCodexToolSettingMutation,
                        onApplyClaudeToolSettingMutation: onApplyClaudeToolSettingMutation
                    )
                    .padding(.top, 6)
                    .transition(.opacity)
                }
            }
        }
    }

    private var hasToolOptions: Bool {
        switch providerID {
        case .codex: binding.codexTools != nil
        case .claude: binding.claudeTools != nil
        case .openCode, .cursor: false
        }
    }
}

struct AgentProviderToolsRuntimeControls: View {
    let providerID: AgentProviderBindingID
    let binding: AgentProviderControlsBinding
    let onApplyCodexToolSettingMutation: (CodexToolSettingMutation) -> Void
    let onApplyClaudeToolSettingMutation: (ClaudeToolSettingMutation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
            switch providerID {
            case .codex:
                if let codexTools = binding.codexTools {
                    CodexProviderToolsRuntimeSection(
                        tools: codexTools,
                        onApplyMutation: onApplyCodexToolSettingMutation
                    )
                }
            case .claude:
                if let claudeTools = binding.claudeTools {
                    ClaudeProviderToolsRuntimeSection(
                        tools: claudeTools,
                        onApplyMutation: onApplyClaudeToolSettingMutation
                    )
                }
            case .openCode, .cursor:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodexProviderToolsRuntimeSection: View {
    let tools: CodexToolSettingsBinding
    let onApplyMutation: (CodexToolSettingMutation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderRuntimeSubsection(
                title: "Core tools",
                subtitle: "Choose which built-in Codex tools are available in direct sessions."
            ) {
                ProviderRuntimeToggleRow(
                    title: "Bash",
                    description: "Allow Codex to run shell commands when your permission level allows it.",
                    isOn: tools.bashToolEnabled,
                    onChange: { onApplyMutation(.bashTool(enabled: $0)) }
                )

                ProviderRuntimeToggleRow(
                    title: "Search",
                    description: "Allow Codex to search the project while it works through a task.",
                    isOn: tools.searchToolEnabled,
                    onChange: { onApplyMutation(.searchTool(enabled: $0)) }
                )
            }

            ProviderRuntimeToggleRow(
                title: "Goals",
                description: "Codex /goal support is enabled by default so long-running tasks can continue between turns. Turn it off if you do not want RepoPrompt to start Codex with goal support.",
                isOn: tools.goalSupportEnabled,
                onChange: { onApplyMutation(.goalSupport(enabled: $0)) }
            )
            .hoverTooltip("Controls Codex features.goals for app-server launch and thread config; enabled by default until turned off.")

            ProviderRuntimeToggleRow(
                title: "Reasoning Summaries",
                description: "Show Codex app-server reasoning summaries in Agent Mode threads. Off by default; this does not change model reasoning effort or Chat/Oracle behavior.",
                isOn: tools.reasoningSummariesEnabled,
                onChange: { onApplyMutation(.reasoningSummaries(enabled: $0)) }
            )
            .hoverTooltip("Controls model_reasoning_summary for Codex Agent Mode app-server thread start/resume. Off sends none; on sends auto.")

            ProviderRuntimeSubsection(
                title: "MCP servers",
                subtitle: "Choose which configured MCP servers Codex can use. RepoPrompt is required for app integration."
            ) {
                if !tools.mcpServerEntries.isEmpty {
                    ForEach(tools.mcpServerEntries, id: \.normalizedName) { entry in
                        let isRepoPromptServer = entry.normalizedName.compare(
                            MCPIntegrationHelper.repoPromptMCPServerName,
                            options: .caseInsensitive
                        ) == .orderedSame
                        let normalizedName = entry.normalizedName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        ProviderRuntimeToggleRow(
                            title: entry.normalizedName,
                            description: nil,
                            badge: isRepoPromptServer ? "Required" : nil,
                            isOn: tools.mcpServerStatesByNormalizedName[normalizedName] ?? isRepoPromptServer,
                            isDisabled: isRepoPromptServer,
                            onChange: {
                                onApplyMutation(.mcpServer(normalizedName: entry.normalizedName, enabled: $0))
                            }
                        )
                    }
                } else {
                    Text("No MCP servers found in ~/.codex/config.toml.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct ProviderRuntimeSubsection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout).bold()
                    .foregroundColor(.secondary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }
}

private struct ProviderRuntimeToggleRow: View {
    let title: String
    let description: String?
    var badge: String?
    let isOn: Bool
    var isDisabled: Bool = false
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isDisabled)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClaudeProviderToolsRuntimeSection: View {
    let tools: ClaudeToolSettingsBinding
    let onApplyMutation: (ClaudeToolSettingMutation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.controlSpacing) {
            Text("Claude Tools")
                .font(.callout).bold()
                .foregroundColor(.secondary)

            Toggle("Bash", isOn: Binding(
                get: { tools.bashToolEnabled },
                set: { onApplyMutation(.bashTool(enabled: $0)) }
            ))
            .toggleStyle(.switch)

            Toggle("RepoPrompt Only (Strict MCP)", isOn: Binding(
                get: { tools.mcpStrictModeEnabled },
                set: { onApplyMutation(.mcpStrictMode(enabled: $0)) }
            ))
            .toggleStyle(.switch)

            Text(
                tools.mcpStrictModeEnabled
                    ? "Only RepoPrompt MCP is active. Other MCP servers are ignored."
                    : "Other MCP servers from your Claude config will also be loaded."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Lazy Tool Loading", isOn: Binding(
                get: { tools.toolSearchEnabled },
                set: { onApplyMutation(.toolSearch(enabled: $0)) }
            ))
            .toggleStyle(.switch)

            Text(
                tools.toolSearchEnabled
                    ? "Claude searches for each tool before using it. Uses less context but adds latency."
                    : "All tools are preloaded into context. Faster but uses more tokens."
            )
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
