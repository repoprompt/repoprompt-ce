//
//  PermissionsSettingsView.swift
//  RepoPrompt
//
//  Settings view for managing workspace operation permissions.
//

import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject private var approvalManager = WorkspaceApprovalManager.shared
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Global Settings
                globalSettingsSection

                // Per-Operation Settings
                operationSettingsSection

                // Trusted Clients
                trustedClientsSection
            }
            .padding()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Workspace Approvals")
                    .font(.title2.weight(.semibold))
            }

            Text("Approvals for RepoPrompt workspace operations (creating folders, deleting workspaces, etc.). CLI agent and sub-agent permissions are configured in Agent Permissions.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Global Settings Section

    private var globalSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Global Settings")
                .font(.headline)

            // Master toggle
            PermissionToggleRow(
                title: "Auto-approve All Operations",
                subtitle: "Skip approval prompts for all workspace operations from all clients",
                icon: "checkmark.shield.fill",
                iconColor: .green,
                isOn: Binding(
                    get: { approvalManager.settings.autoApproveAll },
                    set: { approvalManager.setAutoApproveAll($0) }
                ),
                riskLevel: .high
            )

            if approvalManager.settings.autoApproveAll {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("All workspace operations will be automatically approved without confirmation.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    // MARK: - Per-Operation Settings Section

    private var operationSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Operation Permissions")
                    .font(.headline)
                Spacer()
                Text("Auto-approve specific operations globally")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(WorkspaceApprovalOperation.allCases, id: \.self) { operation in
                    OperationPermissionRow(
                        operation: operation,
                        isEnabled: approvalManager.settings.autoApproveOperations.contains(operation),
                        isDisabled: approvalManager.settings.autoApproveAll,
                        onToggle: { enabled in
                            approvalManager.setAutoApproveOperation(operation, enabled: enabled)
                        }
                    )
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
        .opacity(approvalManager.settings.autoApproveAll ? 0.6 : 1.0)
    }

    // MARK: - Trusted Clients Section

    private var trustedClientsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Trusted Clients")
                    .font(.headline)

                Spacer()

                if !approvalManager.trustedClients.isEmpty {
                    Button(action: { showResetConfirmation = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.caption)
                            Text("Reset All")
                                .font(.caption)
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .alert("Reset All Trusted Clients?", isPresented: $showResetConfirmation) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            for client in approvalManager.trustedClients {
                                approvalManager.removeAllAutoApprovals(for: client.clientID)
                            }
                        }
                    } message: {
                        Text("This will remove all per-client auto-approve settings. You'll be prompted for approval on future operations.")
                    }
                }
            }

            if approvalManager.trustedClients.isEmpty {
                emptyTrustedClientsView
            } else {
                VStack(spacing: 8) {
                    ForEach(approvalManager.trustedClients) { policy in
                        TrustedClientRow(
                            policy: policy,
                            onRemoveOperation: { operation in
                                approvalManager.removeAutoApproval(clientID: policy.clientID, operation: operation)
                            },
                            onRemoveAll: {
                                approvalManager.removeAllAutoApprovals(for: policy.clientID)
                            }
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private var emptyTrustedClientsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Trusted Clients")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)

            Text("When you approve operations with \"Always Allow\", clients will appear here.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Permission Toggle Row

private struct PermissionToggleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    @Binding var isOn: Bool
    let riskLevel: WorkspaceApprovalRiskLevel

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(iconColor)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Toggle
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: riskColor))
                .labelsHidden()
        }
    }

    private var riskColor: Color {
        switch riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}

// MARK: - Operation Permission Row

private struct OperationPermissionRow: View {
    let operation: WorkspaceApprovalOperation
    let isEnabled: Bool
    let isDisabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Operation icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(riskColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: operation.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(riskColor)
            }

            // Operation details
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(operation.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)

                    RiskBadge(riskLevel: operation.riskLevel)
                }

                Text(operationDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(SwitchToggleStyle(tint: riskColor))
            .labelsHidden()
            .disabled(isDisabled)
        }
        .padding(.vertical, 4)
    }

    private var riskColor: Color {
        switch operation.riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private var operationDescription: String {
        switch operation {
        case .createWorkspace:
            "Allow creating new workspaces"
        case .deleteWorkspace:
            "Allow deleting existing workspaces"
        case .addFolder:
            "Allow adding folders to workspaces"
        case .removeFolder:
            "Allow removing folders from workspaces"
        }
    }
}

// MARK: - Risk Badge

private struct RiskBadge: View {
    let riskLevel: WorkspaceApprovalRiskLevel

    var body: some View {
        Text(riskLevel.rawValue.capitalized)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(riskColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(riskColor.opacity(0.15))
            .cornerRadius(4)
    }

    private var riskColor: Color {
        switch riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}

// MARK: - Trusted Client Row

private struct TrustedClientRow: View {
    let policy: WorkspaceApprovalClientPolicy
    let onRemoveOperation: (WorkspaceApprovalOperation) -> Void
    let onRemoveAll: () -> Void

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Client header. The entire header area (icon, client info, chevron) is
            // wrapped in a single Button so clicking anywhere in the row toggles
            // expansion — not just the chevron. The "Remove all" button stays a
            // sibling so it retains its own click target and doesn't accidentally
            // collapse the row.
            HStack(spacing: 12) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack(spacing: 12) {
                        // Client icon
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: clientIcon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.accentColor)
                        }

                        // Client info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.clientID)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text("\(policy.allowedOperations.count) permission\(policy.allowedOperations.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if let lastUsed = policy.lastUsedAt {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(.secondary.opacity(0.5))
                                    Text("Last used \(lastUsed, style: .relative) ago")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                // Remove all button (independent action, kept outside the toggle button)
                Button(action: onRemoveAll) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(isHovering ? 1 : 0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .hoverTooltip("Remove all permissions for this client")
                .accessibilityLabel("Remove all permissions for this client")
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .onHover { isHovering = $0 }

            // Expanded operations list
            if isExpanded {
                VStack(spacing: 0) {
                    Divider()

                    ForEach(Array(policy.allowedOperations).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { operation in
                        HStack(spacing: 12) {
                            Image(systemName: operation.iconName)
                                .font(.system(size: 14))
                                .foregroundColor(operationColor(operation))
                                .frame(width: 20)

                            Text(operation.displayName)
                                .font(.caption)
                                .foregroundColor(.primary)

                            RiskBadge(riskLevel: operation.riskLevel)

                            Spacer()

                            Button(action: { onRemoveOperation(operation) }) {
                                Text("Revoke")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        if operation != policy.allowedOperations.sorted(by: { $0.rawValue < $1.rawValue }).last {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(Color.primary.opacity(0.02))
            }
        }
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var clientIcon: String {
        let lowercased = policy.clientID.lowercased()
        if lowercased.contains("claude") {
            return "brain"
        } else if lowercased.contains("cursor") {
            return "cursorarrow.rays"
        } else if lowercased.contains("vscode") || lowercased.contains("code") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lowercased.contains("codex") {
            return "terminal"
        } else if lowercased.contains("gemini") {
            return "sparkles"
        } else {
            return "app.connected.to.app.below.fill"
        }
    }

    private func operationColor(_ operation: WorkspaceApprovalOperation) -> Color {
        switch operation.riskLevel {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct PermissionsSettingsView_Previews: PreviewProvider {
        static var previews: some View {
            PermissionsSettingsView()
                .frame(width: 500, height: 600)
        }
    }
#endif
