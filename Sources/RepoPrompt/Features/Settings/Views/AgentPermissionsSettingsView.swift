//
//  AgentPermissionsSettingsView.swift
//  RepoPrompt
//
//  Unified Agent Permissions settings page.
//
//  Hosts two in-pane scopes under a single Settings sidebar tab:
//   • Direct Agents — top-level CLI provider permissions (edits through
//     `AgentProviderPermissionsSettingsViewModel`).
//   • Sub-Agents  — sandbox override policy for agents launched through MCP
//     (edits through `AgentSubagentPermissionsSettingsViewModel`).
//
//  A shared `AgentPermissionStorageDiagnosticsViewModel` drives the degraded
//  secure-storage banner so both scopes reflect the same safety signal. This page
//  does not control MCP tool ACLs (MCP Tools) or RepoPrompt workspace operation
//  approvals (Workspace Approvals) — those stay separate Settings surfaces.
//
//  SEARCH-HELPER: Agent Permissions, Direct Agents scope, Sub-Agents scope,
//  Safe Managed, Sub-agent Permissions, Claude Bash, Codex Sandbox, ACP session mode,
//  MCP strict mode, tri-state policy, Provider-native controls,
//  Editable provider rows, Agent Permissions scope shell
//
//  Related:
//  - Provider VM: /RepoPrompt/ViewModels/AgentModeUI/AgentProviderPermissionsSettingsViewModel.swift
//  - Subagent VM: /RepoPrompt/ViewModels/AgentModeUI/AgentSubagentPermissionsSettingsViewModel.swift
//  - Diagnostics: /RepoPrompt/ViewModels/AgentModeUI/AgentPermissionStorageDiagnosticsViewModel.swift
//  - Direct view: /RepoPrompt/Views/Settings/AgentDirectProviderPermissionsView.swift
//  - Sub view:    /RepoPrompt/Views/Settings/AgentSubagentPolicySettingsView.swift
//  - Components:  /RepoPrompt/Views/Settings/AgentPermissionSettingsComponents.swift
//

import SwiftUI

/// Settings page that shows top-level CLI provider permissions and the sub-agent
/// sandbox override policy, split into two in-pane scopes. The page does NOT claim to
/// enforce MCP tool ACLs or RepoPrompt workspace operation approvals.
struct AgentPermissionsSettingsView: View {
    @StateObject private var providerVM: AgentProviderPermissionsSettingsViewModel
    @StateObject private var subagentVM: AgentSubagentPermissionsSettingsViewModel
    @StateObject private var diagnosticsVM: AgentPermissionStorageDiagnosticsViewModel
    @ObservedObject var apiSettingsVM: APISettingsViewModel
    var onNavigate: ((SettingsTab) -> Void)?

    @State private var scope: AgentPermissionSettingsScope = .directAgents
    @AppStorage(DelegationScopeRuntime.autoApproveAllRequestsKey) private var autoApproveDelegationRequests = false

    init(
        apiSettingsVM: APISettingsViewModel,
        providerViewModel: AgentProviderPermissionsSettingsViewModel? = nil,
        subagentViewModel: AgentSubagentPermissionsSettingsViewModel? = nil,
        diagnosticsViewModel: AgentPermissionStorageDiagnosticsViewModel? = nil,
        onNavigate: ((SettingsTab) -> Void)? = nil
    ) {
        self.apiSettingsVM = apiSettingsVM
        self.onNavigate = onNavigate

        // Resolve diagnostics first so both focused VMs can share the same subscription.
        let resolvedDiagnostics = diagnosticsViewModel
            ?? providerViewModel?.diagnostics
            ?? subagentViewModel?.diagnostics
            ?? AgentPermissionStorageDiagnosticsViewModel(
                securePermissions: AgentPermissionSecureStore.shared
            )
        _diagnosticsVM = StateObject(wrappedValue: resolvedDiagnostics)

        // Keep defaults and secure storage aligned across any default-constructed focused
        // VMs so they observe the same secure store as the diagnostics banner. Prefer any
        // injected focused VM's `defaults`, and always prefer the diagnostics VM's
        // `securePermissions` over `AgentPermissionSecureStore.shared` (which the focused
        // VMs would otherwise resolve independently when `defaults === .standard`).
        let resolvedDefaults = providerViewModel?.defaults
            ?? subagentViewModel?.defaults
            ?? .standard
        let resolvedSecurePermissions = resolvedDiagnostics.securePermissions

        let resolvedProvider = providerViewModel
            ?? AgentProviderPermissionsSettingsViewModel(
                defaults: resolvedDefaults,
                securePermissions: resolvedSecurePermissions,
                diagnostics: resolvedDiagnostics
            )
        _providerVM = StateObject(wrappedValue: resolvedProvider)

        let resolvedSubagent = subagentViewModel
            ?? AgentSubagentPermissionsSettingsViewModel(
                defaults: resolvedDefaults,
                securePermissions: resolvedSecurePermissions,
                diagnostics: resolvedDiagnostics
            )
        _subagentVM = StateObject(wrappedValue: resolvedSubagent)
    }

    private var availability: AgentModelCatalog.AvailabilityContext {
        apiSettingsVM.agentModeAvailabilityContext
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AgentPermissionSettingsLayout.sectionSpacing) {
                header
                AgentPermissionSecureStorageDegradedBanner(diagnostics: diagnosticsVM)
                scopePicker
                scopeContent
                delegationApprovalSection
                relatedSection
                Spacer(minLength: 0)
            }
            .frame(
                maxWidth: AgentPermissionSettingsLayout.contentMaxWidth,
                alignment: .leading
            )
            .padding(AgentPermissionSettingsLayout.outerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            subagentVM.refreshFromStorage()
            diagnosticsVM.refresh()
            // Consume any cross-window pending scope request set by popover or
            // external deep-link callers before this view mounted. Settings
            // opens from other windows race the `.setAgentPermissionsScope`
            // notification; the router gives us a synchronous handoff instead.
            if let pending = AgentPermissionsScopeRouter.shared.consumePendingScope() {
                scope = pending
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .setAgentPermissionsScope)
                .receive(on: RunLoop.main)
        ) { note in
            // Deep-link target: another settings surface (e.g. the Agent Mode
            // Overview page) asked us to pre-select a scope. Accept any valid
            // `AgentPermissionSettingsScope` rawValue from `userInfo["scope"]`.
            guard
                let raw = note.userInfo?["scope"] as? String,
                let requested = AgentPermissionSettingsScope(rawValue: raw)
            else { return }
            scope = requested
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("Agent Permissions")
                    .font(.title).bold()
            }
            Text("Configure direct-agent permissions and sub-agent sandbox policy.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Scope picker

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(AgentPermissionSettingsScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Agent Permissions scope")
    }

    // MARK: - Scope content

    @ViewBuilder
    private var scopeContent: some View {
        switch scope {
        case .directAgents:
            AgentDirectProviderPermissionsView(
                viewModel: providerVM,
                availability: availability,
                onNavigate: onNavigate
            )
        case .subagents:
            AgentSubagentPolicySettingsView(
                viewModel: subagentVM,
                availability: availability,
                onNavigate: onNavigate
            )
        }
    }

    // MARK: - Delegation approvals

    /// Global standing consent for agent oversight requests. Off by default; user-only (not exposed
    /// through MCP app_settings). When on, Active delegations shows it and every grant stays revocable.
    private var delegationApprovalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overseer")
                .font(.headline)
            Toggle(isOn: $autoApproveDelegationRequests) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overseer full access (no approvals)")
                    Text("An Overseer can do everything to every session without asking: observe, organize, control, restructure, spawn, worktrees, retire, and delete sessions. No approval or confirmation cards appear. Its access shows in Active delegations. Turn this off to revoke it immediately.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("agent-permissions-auto-approve-delegation")
            .onChange(of: autoApproveDelegationRequests) { _, isOn in
                // Off means off: withdraw every global grant now, not on the next agent call.
                if !isOn { AgentSessionLinkRuntimeBridge.shared.delegationScopes.reconcileGlobalAutoApprove() }
            }
        }
    }

    // MARK: - Related / cross-links

    /// Compact "Related Settings" footer. Kept deliberately low-contrast and one line
    /// per entry so users know MCP Tools and Workspace Approvals stay distinct without
    /// the footer competing with the main scope content.
    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related Settings")
                .font(.headline)
                .foregroundColor(.secondary)

            AgentPermissionRelatedLinkRow(
                icon: "terminal",
                title: "CLI Providers",
                detail: "Connect providers and configure non-permission options.",
                tab: .cliProviders,
                onNavigate: onNavigate
            )
            AgentPermissionRelatedLinkRow(
                icon: "shield.checkered",
                title: "Workspace Approvals",
                detail: "Approvals for RepoPrompt workspace operations.",
                tab: .permissions,
                onNavigate: onNavigate
            )
            AgentPermissionRelatedLinkRow(
                icon: "wrench.and.screwdriver",
                title: "MCP Tools",
                detail: "Which RepoPrompt MCP tools are advertised and enabled.",
                tab: .mcpTools,
                onNavigate: onNavigate
            )
            AgentPermissionRelatedLinkRow(
                icon: "brain",
                title: "Agent Models",
                detail: "Models and CLI agents used by Oracle and Context Builder.",
                tab: .agentModels,
                onNavigate: onNavigate
            )
            AgentPermissionRelatedLinkRow(
                icon: "brain.head.profile",
                title: "Agent Mode Overview",
                detail: "At-a-glance summary of Agent Mode configuration with links to each canonical page.",
                tab: .agentMode,
                onNavigate: onNavigate
            )
        }
        .padding(.top, 8)
    }
}

// Preview intentionally omitted: APISettingsViewModel requires injected services
// (aiQueriesService, keyManager) that are only available through WindowState.
