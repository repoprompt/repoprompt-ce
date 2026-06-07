import Combine
import SwiftUI

/// Consolidated settings view for Agent Mode — the "Overview" tab.
///
/// Model choices (Oracle, Context Builder Agent, Agent Role Defaults) are now
/// canonical in Agent Models. Sub-agent permissions (Safe Managed / Inherit /
/// Custom) are canonical in Agent Permissions. Context Builder budgets,
/// question timeout, and clarifying-question toggles live on the Context
/// Builder page. This page keeps compact summary/link rows that deep-link to
/// the canonical pages, and surfaces at-a-glance CLI provider connection
/// status so users can spot missing configuration without leaving Overview.
///
/// SEARCH-HELPER: Agent Mode Overview, Agent Mode Behavior, Safe Managed summary,
/// Oracle Model summary, Context Builder summary, Agent Role Defaults summary,
/// CLI provider status, Direct-Agent Permissions deep link, Sub-Agent Permissions deep link
///
/// Related:
/// - Agent Models:      /RepoPrompt/Views/Settings/AgentModelsSettingsView.swift
/// - Agent Permissions: /RepoPrompt/Views/Settings/AgentPermissionsSettingsView.swift
/// - Context Builder:   /RepoPrompt/Views/Settings/ContextBuilderSettingsView.swift
/// - CLI Providers:     /RepoPrompt/Views/Settings/CLIProvidersSettingsView.swift
/// - Plan:              /docs/plans/settings-ui-agent-mode-progressive-disclosure-plan-2026-04-17.md
struct AgentModeGeneralSettingsView: View {
    @ObservedObject var promptVM: PromptViewModel
    @ObservedObject var apiSettingsVM: APISettingsViewModel
    var onNavigate: ((SettingsTab) -> Void)?

    /// Observe secure permission-store changes so the read-only summary rebuilds
    /// without relying on @AppStorage for sensitive policy keys.
    @State private var subagentPolicyRevision = 0

    // Observes GlobalSettingsStore so the workflow summary reflects cleanup-guidance
    // changes made on the Agent Workflows page or through the `app_settings` MCP tool.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var currentSubagentPolicy: AgentSubagentPermissionPolicy {
        _ = subagentPolicyRevision
        return AgentModePermissionPreferences.subagentPermissionPolicy()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(16, max: 24)) {
                headerSection

                configurationSummarySection
            }
            .padding(fontPreset.scaledClamped(20, max: 28))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentPermissionSecureStoreDidChange)
                .receive(on: RunLoop.main)
        ) { notification in
            guard notification.userInfo?[AgentPermissionSecureStoreNotificationKey.domain] as? String == AgentPermissionSecureDomain.subagent.rawValue else {
                return
            }
            subagentPolicyRevision += 1
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(4, max: 7)) {
            Text("Overview")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .bold))

            Text("Oracle reasons, Context Builder gathers files, and sub-agents do the work. Each row below links to the canonical page that owns those settings.")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Summary / link rows

    private var configurationSummarySection: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(8, max: 14)) {
            linkRow(
                icon: "brain",
                title: "Oracle Model",
                detail: "The analysis model for planning and review. Reasons over your current file selection and chat history — no tools, no file edits. Currently: \(promptVM.planningModel.displayName).",
                tab: .agentModels
            )

            linkRow(
                icon: "sparkles",
                title: "Context Builder Agent",
                detail: "Curates Oracle's file selection. Explores your codebase and aggregates the most relevant files so Oracle can reason efficiently when producing plans. Currently: \(promptVM.contextBuilderAgent.displayName) · \(promptVM.contextBuilderAgentModelDisplayName).",
                tab: .agentModels
            )

            linkRow(
                icon: "person.3",
                title: "Sub-Agent Role Defaults",
                detail: "Preset models per orchestration role. Pair is the primary worker — pick your smartest model here. Design handles UI and copy work. Explore and Engineer fill out the rest of the lineup.",
                tab: .agentModels
            )

            providersLinkRow

            agentComputerUseLinkRow

            agentPermissionsCard

            linkRow(
                icon: "doc.text.magnifyingglass",
                title: "Context Builder Budgets & Timeouts",
                detail: "Token budgets, enhancement mode, and clarifying-question behavior for the Context Builder agent.",
                tab: .contextBuilder
            )

            agentWorkflowsLinkRow
        }
    }

    // MARK: - Computer Use row

    private var agentComputerUseLinkRow: some View {
        let status = CodexComputerUseWorkflow.availability
        let detail = status.isReady
            ? "Ready for explicit /computer-use turns. Codex app access, sensitive actions, and RepoPrompt sandbox approvals still remain separate."
            : status.primaryUnavailableMessage
        return linkRow(
            icon: "display",
            title: "Computer Use",
            detail: detail,
            tab: .agentComputerUse
        )
    }

    // MARK: - Agent Workflows row

    /// Link row for the canonical Agent Workflows settings page. The cleanup-guidance
    /// toggle used to live inline on Overview; it now belongs to Agent Workflows so
    /// workflow-related settings have one owner.
    ///
    /// SEARCH-HELPER: Agent Workflows overview link, cleanup guidance summary,
    /// built-in workflow visibility, featured workflows, custom workflow markdown
    private var agentWorkflowsLinkRow: some View {
        let cleanupStatus = globalSettings.showBuiltInWorkflowCleanupGuidance() ? "On" : "Off"
        return linkRow(
            icon: "bolt.fill",
            title: "Agent Workflows",
            detail: "Manage built-in workflow visibility, featured workflows, custom markdown workflows, and cleanup guidance. Cleanup guidance is currently \(cleanupStatus).",
            tab: .agentWorkflows
        )
    }

    // MARK: - Providers row (CLI Providers + inline status lights)

    /// Row for the CLI Providers page with a compact horizontal strip of status
    /// lights — one per CLI provider binding — so users can tell at a glance
    /// which providers are connected without opening the CLI Providers tab.
    ///
    /// The lights are driven by `APISettingsViewModel.is*Connected`, the same
    /// @Published booleans the full CLI Providers page uses. No async work, no
    /// network — just UserDefaults-backed connection flags already in memory.
    private var providersLinkRow: some View {
        Button {
            onNavigate?(.cliProviders)
        } label: {
            HStack(alignment: .top, spacing: fontPreset.scaledClamped(12, max: 18)) {
                Image(systemName: "terminal")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 17))
                    .frame(width: fontPreset.scaledClamped(22, max: 30), alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: fontPreset.scaledClamped(6, max: 10)) {
                    Text("CLI Providers")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(providersSummaryDetail)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    providerStatusStrip
                        .padding(.top, fontPreset.scaledClamped(2, max: 4))
                }
                Spacer(minLength: fontPreset.scaledClamped(10, max: 14))
                Image(systemName: "chevron.right")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, fontPreset.scaledClamped(6, max: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }

    private var providersSummaryDetail: String {
        let providers = cliStatusProviders
        let connected = providers.filter(isProviderConnected).count
        let total = providers.count
        if connected == 0 {
            return "Connect a CLI agent (Claude Code, Codex, OpenCode, Cursor) to run anything in Agent Mode."
        }
        return "\(connected) of \(total) CLI providers connected. Manage auth, installs, and models in CLI Providers."
    }

    /// Compact horizontal strip of per-provider status "lights". Uses the same
    /// green-dot / dim-dot vocabulary as `CLIProvidersSettingsView.connectionBadge`.
    private var cliStatusProviders: [AgentProviderBindingID] {
        AgentProviderBindingID.allCases
    }

    private var providerStatusStrip: some View {
        HStack(spacing: fontPreset.scaledClamped(10, max: 14)) {
            ForEach(cliStatusProviders, id: \.self) { provider in
                providerStatusChip(for: provider)
            }
        }
    }

    @ViewBuilder
    private func providerStatusChip(for provider: AgentProviderBindingID) -> some View {
        let connected = isProviderConnected(provider)
        HStack(spacing: fontPreset.scaledClamped(5, max: 8)) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: fontPreset.scaledClamped(7, max: 10), height: fontPreset.scaledClamped(7, max: 10))
            Text(provider.displayName)
                .font(fontPreset.captionFont)
                .foregroundColor(connected ? .primary : .secondary)
        }
        .padding(.horizontal, fontPreset.scaledClamped(8, max: 12))
        .padding(.vertical, fontPreset.scaledClamped(3, max: 5))
        .background(
            Capsule()
                .fill(connected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .help(
            connected
                ? "\(provider.displayName) is connected. Open CLI Providers to review auth, installs, or models."
                : "\(provider.displayName) is not connected. Open CLI Providers to configure it."
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(provider.displayName): \(connected ? "connected" : "not connected")"))
    }

    private func isProviderConnected(_ provider: AgentProviderBindingID) -> Bool {
        switch provider {
        case .claude: apiSettingsVM.isClaudeCodeConnected
        case .codex: apiSettingsVM.isCodexConnected
        case .openCode: apiSettingsVM.isOpenCodeConnected
        case .cursor: apiSettingsVM.isCursorConnected
        }
    }

    // MARK: - Sub-agent sandbox policy summary

    private var subagentPolicyShortLabel: String {
        switch currentSubagentPolicy {
        case .safeManaged:
            "Safe Managed"
        case .inheritProviderSettings:
            "Inherit Provider"
        case .custom:
            "Custom"
        }
    }

    private var subagentPolicyIconName: String {
        switch currentSubagentPolicy {
        case .safeManaged:
            "checkmark.shield"
        case .inheritProviderSettings:
            "exclamationmark.shield"
        case .custom:
            "slider.horizontal.below.rectangle"
        }
    }

    private var safeManagedSummaryDetail: String {
        switch currentSubagentPolicy {
        case .safeManaged:
            "Sub-agents launched through MCP run with Safe Managed overrides by default."
        case .inheritProviderSettings:
            "Sub-agents inherit your provider-configured permissions, including permissive modes."
        case .custom:
            "Per-provider overrides are active for sub-agents launched through MCP."
        }
    }

    // MARK: - Permissions card (grouped)

    /// Grouped "Agent Permissions" card that combines both scopes — Direct Agents and
    /// Sub-Agents — into a single Overview slot with two sub-links. Replaces the
    /// previous pair of sibling `linkRow`s so the Overview communicates that the
    /// two scopes live under a single Agent Permissions tab while still letting
    /// users deep-link straight into the scope they care about.
    ///
    /// SEARCH-HELPER: Agent Permissions card, Direct Agents sub-link,
    /// Sub-Agents sub-link, grouped permissions overview, Overview permissions card,
    /// two sub links, nested permissions card
    private var agentPermissionsCard: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(8, max: 12)) {
            HStack(alignment: .top, spacing: fontPreset.scaledClamped(12, max: 18)) {
                Image(systemName: "lock.shield")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 17))
                    .frame(width: fontPreset.scaledClamped(22, max: 30), alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: fontPreset.scaledClamped(2, max: 5)) {
                    Text("Agent Permissions")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Permission controls for agents you run directly, plus the sandbox policy for sub-agents launched through MCP.")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: fontPreset.scaledClamped(10, max: 14))
            }

            // Sub-links. Indented beneath the parent icon column so the
            // hierarchy reads at a glance, with a subtle divider between
            // the two scopes to emphasize "two links, one parent".
            VStack(spacing: 0) {
                permissionsSubLinkRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Direct Agents",
                    detail: "Claude Bash, Codex sandbox, ACP session mode, and MCP strict mode for agents you run directly from RepoPrompt.",
                    scope: .directAgents
                )
                Divider()
                    .padding(.leading, fontPreset.scaledClamped(24, max: 34))
                permissionsSubLinkRow(
                    icon: subagentPolicyIconName,
                    title: "Sub-Agents (\(subagentPolicyShortLabel))",
                    detail: safeManagedSummaryDetail,
                    scope: .subagents
                )
            }
            .padding(.leading, fontPreset.scaledClamped(34, max: 48))
        }
        .padding(.vertical, fontPreset.scaledClamped(6, max: 10))
    }

    /// Single sub-link row inside the grouped Agent Permissions card. Behaves like
    /// `linkRow` — navigates to the Agent Permissions tab and posts the scope
    /// notification on the next main-queue tick so the destination view's
    /// `.onReceive` subscriber is listening when we deliver the scope.
    private func permissionsSubLinkRow(
        icon: String,
        title: String,
        detail: String,
        scope: AgentPermissionSettingsScope
    ) -> some View {
        Button {
            onNavigate?(.agentPermissions)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .setAgentPermissionsScope,
                    object: nil,
                    userInfo: ["scope": scope.rawValue]
                )
            }
        } label: {
            HStack(alignment: .top, spacing: fontPreset.scaledClamped(10, max: 14)) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .frame(width: fontPreset.scaledClamped(18, max: 24), alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: fontPreset.scaledClamped(2, max: 4)) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: fontPreset.scaledClamped(6, max: 10))
                Image(systemName: "chevron.right")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, fontPreset.scaledClamped(5, max: 9))
            .padding(.horizontal, fontPreset.scaledClamped(2, max: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }

    // MARK: - Link row helper

    /// Single "card" row that deep-links to a settings tab. Permission-scope
    /// deep-linking lives in `permissionsSubLinkRow` inside the grouped Agent
    /// Permissions card — keeping that logic in one place avoids two slightly
    /// different routing paths drifting if the notification pattern changes.
    private func linkRow(
        icon: String,
        title: String,
        detail: String,
        tab: SettingsTab
    ) -> some View {
        Button {
            onNavigate?(tab)
        } label: {
            HStack(alignment: .top, spacing: fontPreset.scaledClamped(12, max: 18)) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 17))
                    .frame(width: fontPreset.scaledClamped(22, max: 30), alignment: .center)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: fontPreset.scaledClamped(2, max: 5)) {
                    Text(title)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: fontPreset.scaledClamped(10, max: 14))
                Image(systemName: "chevron.right")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, fontPreset.scaledClamped(6, max: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }
}
